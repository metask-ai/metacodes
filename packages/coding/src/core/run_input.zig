//! Host input submitted to a Run while it is active (issue #270).
//!
//! A Host may hand a running Run more user text. The text is **accepted** when
//! it enters this queue and **adopted** when the agent loop appends it to the
//! Conversation as a user record at a turn boundary — the same boundary that
//! drains `UiEvent.queue_message` (never during a provider stream, never at a
//! max_tokens continuation boundary). Adoption does not mean a provider has
//! seen it: the request that carries it may still fail.
//!
//! Inputs are adopted strictly in acceptance order and a boundary adopts every
//! input pending at that moment, so the adopted inputs are always a prefix of
//! the accepted ones. Reconciliation is therefore two counts: inputs with a
//! sequence (1-based acceptance position) at most `adopted` were adopted,
//! the rest were not and never will be. The counts are the authority; an
//! adoption event that a Host failed to receive proves nothing either way.
//!
//! Lifecycle per Run, all transitions owned by `AgentSession`:
//!   open (admission) → [refusing (isolated Run)] → closed (Run ends).
//! A closed window keeps the counts of the Run it served until the next
//! `open`, so the embedding layer can report them after the Run returned.
//!
//! Locking: the queue has its own mutex. `AgentSession` calls `submit`,
//! `open`, `refuse` and `close` while holding its lifecycle mutex, so the
//! order is session.mutex → queue.mutex → admission (the AgentCore budget
//! controller's mutex). The agent loop calls `next`/`adopt` holding none of
//! those, and never holds the queue mutex while it emits events.

const std = @import("std");
const sync = @import("platform").sync;

/// Per-Run limits. Defaults serve source-level hosts; AgentCore passes its
/// published ABI limits.
pub const Limits = struct {
    /// Accepted inputs per Run, adopted or not.
    max_inputs: u32 = 64,
    /// Text bytes of every accepted input of one Run together.
    max_total_bytes: u64 = 16 * 1024 * 1024,
};

/// Durable-state admission for accepted inputs. AgentCore reserves the bytes
/// an input will occupy in a checkpoint when it is accepted, commits them when
/// it is adopted and releases them when the Run ends without adopting it, so
/// an input can never push the Session past its durable budget after the
/// fact. A refusal refuses only that submission; it never ends the Run.
pub const Admission = struct {
    ctx: *anyopaque,
    /// Returns the reserved byte count passed back to commit/release.
    reserveFn: *const fn (ctx: *anyopaque, text: []const u8) error{BudgetRequired}!u64,
    commitFn: *const fn (ctx: *anyopaque, reserved_bytes: u64) void,
    releaseFn: *const fn (ctx: *anyopaque, reserved_bytes: u64) void,
};

pub const SubmitError = error{
    /// `input_id` is zero, or the text is empty, all whitespace or not UTF-8.
    InvalidInput,
    /// This Run already accepted an input with the same `input_id`.
    DuplicateInputId,
    /// Accepting it would exceed the Run's input count or byte limit.
    InputLimitExceeded,
    /// The durable budget cannot hold the input.
    BudgetRequired,
    /// The Run's input window has closed (the Run ended).
    InputClosed,
    /// The Run is active but never adopts Host input (an isolated Run).
    InputNotAccepted,
    OutOfMemory,
};

/// One input waiting for adoption. `text` is owned by the queue and stays
/// valid until `adopt` or `close`; both happen on the Run's own thread.
pub const Pending = struct {
    input_id: u64,
    sequence: u32,
    text: []const u8,
};

pub const Reconciliation = struct {
    accepted: u32 = 0,
    adopted: u32 = 0,
};

const Window = enum { closed, open, refusing };

const Entry = struct {
    input_id: u64,
    /// Owned; freed (and replaced by an empty slice) once adopted or closed.
    text: []u8,
    reserved_bytes: u64,
};

pub const Queue = struct {
    allocator: std.mem.Allocator,
    limits: Limits,
    mutex: sync.Mutex = .{},
    window: Window = .closed,
    /// The Run this window serves; 0 before the first `open`.
    run_id: u64 = 0,
    entries: std.ArrayList(Entry) = .empty,
    adopted: u32 = 0,
    total_bytes: u64 = 0,
    admission: ?Admission = null,

    pub fn init(allocator: std.mem.Allocator, limits: Limits) Queue {
        return .{ .allocator = allocator, .limits = limits };
    }

    /// Frees what is left. Reservations are not released here: a queue that
    /// still holds an admission at deinit outlived its Run, which `close`
    /// prevents on every path.
    pub fn deinit(self: *Queue) void {
        std.debug.assert(self.admission == null);
        self.freeTexts();
        self.entries.deinit(self.allocator);
    }

    /// Start a Run's input window, discarding the previous Run's record.
    pub fn open(self: *Queue, run_id: u64, admission: ?Admission) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        std.debug.assert(self.window == .closed);
        std.debug.assert(run_id != 0);
        self.freeTexts();
        self.entries.clearRetainingCapacity();
        self.window = .open;
        self.run_id = run_id;
        self.adopted = 0;
        self.total_bytes = 0;
        self.admission = admission;
    }

    /// The Run continues but will never adopt Host input: later submissions
    /// are refused. Inputs accepted before stay pending and close unadopted.
    pub fn refuse(self: *Queue) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.window == .open) self.window = .refusing;
    }

    /// Accept one input. Returns its 1-based acceptance sequence. On any error
    /// nothing was accepted and nothing was reserved.
    pub fn submit(self: *Queue, input_id: u64, text: []const u8) SubmitError!u32 {
        self.mutex.lock();
        defer self.mutex.unlock();
        switch (self.window) {
            .open => {},
            .closed => return error.InputClosed,
            .refusing => return error.InputNotAccepted,
        }
        if (input_id == 0 or !hasVisibleText(text) or !std.unicode.utf8ValidateSlice(text))
            return error.InvalidInput;
        for (self.entries.items) |entry| {
            if (entry.input_id == input_id) return error.DuplicateInputId;
        }
        if (self.entries.items.len >= self.limits.max_inputs) return error.InputLimitExceeded;
        const total = std.math.add(u64, self.total_bytes, text.len) catch return error.InputLimitExceeded;
        if (total > self.limits.max_total_bytes) return error.InputLimitExceeded;

        const owned = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(owned);
        try self.entries.ensureUnusedCapacity(self.allocator, 1);
        const reserved: u64 = if (self.admission) |admission|
            try admission.reserveFn(admission.ctx, text)
        else
            0;
        // Infallible from here: capacity was reserved above.
        self.entries.appendAssumeCapacity(.{ .input_id = input_id, .text = owned, .reserved_bytes = reserved });
        self.total_bytes = total;
        return @intCast(self.entries.items.len);
    }

    /// The oldest input not yet adopted, or null. The agent loop appends its
    /// text and then calls `adopt` with its sequence.
    pub fn next(self: *Queue) ?Pending {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.window == .closed or self.adopted >= self.entries.items.len) return null;
        const entry = self.entries.items[self.adopted];
        return .{ .input_id = entry.input_id, .sequence = self.adopted + 1, .text = entry.text };
    }

    /// Record that the input `next` returned is now in the Conversation.
    pub fn adopt(self: *Queue, sequence: u32) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        std.debug.assert(self.window != .closed);
        std.debug.assert(sequence == self.adopted + 1 and self.adopted < self.entries.items.len);
        const entry = &self.entries.items[self.adopted];
        if (self.admission) |admission| admission.commitFn(admission.ctx, entry.reserved_bytes);
        entry.reserved_bytes = 0;
        self.allocator.free(entry.text);
        entry.text = &.{};
        self.adopted += 1;
    }

    /// End the Run's window: release every unadopted reservation, drop the
    /// admission, and return the final counts. Idempotent.
    pub fn close(self: *Queue) Reconciliation {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.window != .closed) {
            for (self.entries.items[self.adopted..]) |*entry| {
                if (self.admission) |admission| admission.releaseFn(admission.ctx, entry.reserved_bytes);
                entry.reserved_bytes = 0;
            }
            self.freeTexts();
            self.window = .closed;
            self.admission = null;
        }
        return self.countsLocked();
    }

    /// The final counts of `run_id` once its window has closed; null while it
    /// is still open or when the queue last served another Run.
    pub fn reconciliation(self: *Queue, run_id: u64) ?Reconciliation {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (run_id == 0 or self.run_id != run_id or self.window != .closed) return null;
        return self.countsLocked();
    }

    fn countsLocked(self: *const Queue) Reconciliation {
        return .{ .accepted = @intCast(self.entries.items.len), .adopted = self.adopted };
    }

    fn freeTexts(self: *Queue) void {
        for (self.entries.items) |*entry| {
            if (entry.text.len != 0) self.allocator.free(entry.text);
            entry.text = &.{};
        }
    }
};

fn hasVisibleText(text: []const u8) bool {
    return std.mem.trim(u8, text, " \t\r\n").len != 0;
}

// ── tests ────────────────────────────────────────────────────────────────────

const TestBudget = struct {
    capacity: u64,
    reserved: u64 = 0,
    committed: u64 = 0,

    fn admission(self: *TestBudget) Admission {
        return .{ .ctx = self, .reserveFn = reserve, .commitFn = commit, .releaseFn = release };
    }
    fn reserve(ctx: *anyopaque, text: []const u8) error{BudgetRequired}!u64 {
        const self: *TestBudget = @ptrCast(@alignCast(ctx));
        if (self.reserved + self.committed + text.len > self.capacity) return error.BudgetRequired;
        self.reserved += text.len;
        return text.len;
    }
    fn commit(ctx: *anyopaque, bytes: u64) void {
        const self: *TestBudget = @ptrCast(@alignCast(ctx));
        self.reserved -= bytes;
        self.committed += bytes;
    }
    fn release(ctx: *anyopaque, bytes: u64) void {
        const self: *TestBudget = @ptrCast(@alignCast(ctx));
        self.reserved -= bytes;
    }
};

test "run input: accepted inputs are adopted in order and the counts reconcile" {
    var q = Queue.init(std.testing.allocator, .{});
    defer q.deinit();
    q.open(7, null);
    try std.testing.expectEqual(@as(u32, 1), try q.submit(100, "first"));
    try std.testing.expectEqual(@as(u32, 2), try q.submit(50, "second"));
    try std.testing.expectEqual(@as(u32, 3), try q.submit(300, "third"));

    const a = q.next().?;
    try std.testing.expectEqual(@as(u64, 100), a.input_id);
    try std.testing.expectEqual(@as(u32, 1), a.sequence);
    try std.testing.expectEqualStrings("first", a.text);
    q.adopt(a.sequence);
    const b = q.next().?;
    try std.testing.expectEqual(@as(u64, 50), b.input_id);
    q.adopt(b.sequence);

    // Still open: no final counts yet.
    try std.testing.expect(q.reconciliation(7) == null);
    const counts = q.close();
    try std.testing.expectEqual(Reconciliation{ .accepted = 3, .adopted = 2 }, counts);
    try std.testing.expectEqual(counts, q.reconciliation(7).?);
    // Another Run's id never reads this Run's record.
    try std.testing.expect(q.reconciliation(8) == null);
    try std.testing.expect(q.next() == null);
    try std.testing.expectError(error.InputClosed, q.submit(1, "late"));
}

test "run input: invalid, duplicate and over-limit submissions change nothing" {
    var q = Queue.init(std.testing.allocator, .{ .max_inputs = 2, .max_total_bytes = 8 });
    defer q.deinit();
    q.open(1, null);
    try std.testing.expectError(error.InvalidInput, q.submit(0, "x"));
    try std.testing.expectError(error.InvalidInput, q.submit(1, ""));
    try std.testing.expectError(error.InvalidInput, q.submit(1, " \t\r\n"));
    try std.testing.expectError(error.InvalidInput, q.submit(1, "\xff\xfe"));
    try std.testing.expectEqual(@as(u32, 1), try q.submit(1, "abcd"));
    try std.testing.expectError(error.DuplicateInputId, q.submit(1, "zz"));
    try std.testing.expectError(error.InputLimitExceeded, q.submit(2, "abcde")); // 4+5 > 8 bytes
    try std.testing.expectEqual(@as(u32, 2), try q.submit(2, "abcd"));
    try std.testing.expectError(error.InputLimitExceeded, q.submit(3, "a")); // count
    try std.testing.expectEqual(Reconciliation{ .accepted = 2, .adopted = 0 }, q.close());
}

test "run input: budget is reserved at acceptance, committed at adoption, released at close" {
    var budget = TestBudget{ .capacity = 10 };
    var q = Queue.init(std.testing.allocator, .{});
    defer q.deinit();
    q.open(1, budget.admission());
    _ = try q.submit(1, "1234");
    _ = try q.submit(2, "5678");
    // A refusal refuses only this submission.
    try std.testing.expectError(error.BudgetRequired, q.submit(3, "abc"));
    try std.testing.expectEqual(@as(u64, 8), budget.reserved);

    const first = q.next().?;
    q.adopt(first.sequence);
    try std.testing.expectEqual(@as(u64, 4), budget.reserved);
    try std.testing.expectEqual(@as(u64, 4), budget.committed);

    try std.testing.expectEqual(Reconciliation{ .accepted = 2, .adopted = 1 }, q.close());
    try std.testing.expectEqual(@as(u64, 0), budget.reserved);
    try std.testing.expectEqual(@as(u64, 4), budget.committed);
    // A second close releases nothing twice.
    _ = q.close();
    try std.testing.expectEqual(@as(u64, 0), budget.reserved);
}

test "run input: a refusing window keeps earlier inputs pending and refuses new ones" {
    var q = Queue.init(std.testing.allocator, .{});
    defer q.deinit();
    q.open(1, null);
    _ = try q.submit(1, "early");
    q.refuse();
    try std.testing.expectError(error.InputNotAccepted, q.submit(2, "later"));
    try std.testing.expectEqual(Reconciliation{ .accepted = 1, .adopted = 0 }, q.close());
}

test "run input: open starts a fresh record for the next Run" {
    var q = Queue.init(std.testing.allocator, .{});
    defer q.deinit();
    q.open(1, null);
    _ = try q.submit(5, "a");
    _ = q.close();
    q.open(2, null);
    // The previous Run's id is free again in the new Run.
    try std.testing.expectEqual(@as(u32, 1), try q.submit(5, "b"));
    try std.testing.expect(q.reconciliation(1) == null);
    try std.testing.expectEqual(Reconciliation{ .accepted = 1, .adopted = 0 }, q.close());
}

test "run input: submissions from many threads get distinct sequences" {
    var q = Queue.init(std.testing.allocator, .{ .max_inputs = 64 });
    defer q.deinit();
    q.open(1, null);
    const Worker = struct {
        fn run(queue: *Queue, base: u64, seen: *[16]u32) void {
            for (0..16) |i| seen[i] = queue.submit(base + i, "x") catch 0;
        }
    };
    var seen: [4][16]u32 = undefined;
    var threads: [4]std.Thread = undefined;
    for (&threads, 0..) |*t, i| t.* = try std.Thread.spawn(.{}, Worker.run, .{ &q, 1 + i * 100, &seen[i] });
    for (threads) |t| t.join();
    var hit = [_]bool{false} ** 65;
    for (seen) |row| for (row) |sequence| {
        try std.testing.expect(sequence >= 1 and sequence <= 64);
        try std.testing.expect(!hit[sequence]);
        hit[sequence] = true;
    };
    try std.testing.expectEqual(Reconciliation{ .accepted = 64, .adopted = 0 }, q.close());
}
