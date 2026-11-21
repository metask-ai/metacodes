//! The run's budget ledger (#520): `budget.jsonl` in the run directory, one
//! JSON object per line, append-only, written only by the runtime.
//!
//! ```
//! {"seat_id":"implementer-1","harness":"claude_code","usd":0.42,"wallclock_ms":61000,"source":"harness_reported"}
//! ```
//!
//! Every charge is appended and fsynced before the running totals change, so
//! the file is the truth and `load` rebuilds the totals from it after a crash.
//! A crash mid-append leaves at most one torn last line (no newline); `load`
//! drops it and truncates the file back to the last complete line so the next
//! append starts clean. A complete line that does not parse is not a crash
//! artifact, and `load` fails closed with `CorruptLedger`.
//!
//! Admission receipts are fsynced in `budget.jsonl.pending.tmp` and installed
//! at `budget.jsonl.pending` without replacing an existing receipt. Recovery
//! ignores unfinished temp files: no paid work starts before installation.
//!
//! Not thread-safe: the runtime serializes charges.

const std = @import("std");
const pfs = @import("platform").fs;
const types = @import("types.zig");

pub const Source = enum {
    /// metacodes' own estimate from provider usage.
    provider_estimate,
    /// The cost an external harness reported in its result.
    harness_reported,
    /// Conservative cap consumption when a cost-bounded harness exits
    /// without a usable cost report. This is not a measured bill.
    reserved,
    /// No cost is known; the seat is bounded by wallclock only.
    wallclock_only,

    pub fn parse(text: []const u8) ?Source {
        return std.meta.stringToEnum(Source, text);
    }
};

/// What a charge cost. A dollar amount exists exactly when the source has one.
pub const Cost = union(Source) {
    provider_estimate: f64,
    harness_reported: f64,
    reserved: f64,
    wallclock_only,

    pub fn usd(self: Cost) ?f64 {
        return switch (self) {
            .provider_estimate, .harness_reported, .reserved => |amount| amount,
            .wallclock_only => null,
        };
    }
};

pub const Entry = struct {
    seat_id: types.SeatId,
    harness: types.Harness,
    wallclock_ms: u64,
    cost: Cost,
};

pub const LoadError = error{
    /// The cap is not a finite number greater than zero.
    InvalidCap,
    /// A complete line is not a valid entry.
    CorruptLedger,
    ReadFailed,
    /// The torn tail could not be truncated away.
    RepairFailed,
    PathTooLong,
    OutOfMemory,
};

pub const ChargeError = error{
    /// The entry was recorded and the run's total has reached the cap.
    BudgetExhausted,
    /// A negative, NaN or infinite dollar amount; nothing was recorded.
    InvalidAmount,
    WriteFailed,
};

pub const Ledger = struct {
    /// Owned, NUL-terminated.
    path: [:0]u8,
    pending_path: [:0]u8,
    pending_seat: ?types.SeatId = null,
    hold_seat: ?types.SeatId = null,
    held_usd: f64 = 0,
    cap_usd: f64,
    spent_usd: f64 = 0,
    wallclock_ms: u64 = 0,
    entries: usize = 0,
    /// Tripped by the charge that reaches the cap (#520): the runtime hands
    /// every live seat this signal, so they all stop at once instead of when
    /// each next looks at the ledger. Borrowed; null = no signal.
    abort_on_exhaustion: ?*types.AbortSignal = null,

    /// Open the ledger at `path` with the run's cap, summing every entry
    /// already on disk. A missing file is an empty ledger.
    pub fn load(gpa: std.mem.Allocator, path: []const u8, cap_usd: f64) LoadError!Ledger {
        if (!std.math.isFinite(cap_usd) or cap_usd <= 0) return error.InvalidCap;
        if (path.len + ".pending.tmp".len >= std.fs.max_path_bytes) return error.PathTooLong;
        const path_z = try gpa.dupeZ(u8, path);
        errdefer gpa.free(path_z);
        const pending_path = try std.fmt.allocPrintSentinel(gpa, "{s}.pending", .{path}, 0);
        errdefer gpa.free(pending_path);
        var self: Ledger = .{ .path = path_z, .pending_path = pending_path, .cap_usd = cap_usd };

        var hold_buf: PathBuf = undefined;
        const hold_path = try holdPath(&hold_buf, path_z);
        const pending = try Receipt.read(gpa, pending_path);
        const held = try Receipt.read(gpa, hold_path);
        if (pending) |receipt| self.pending_seat = receipt.entry.seat_id;
        if (held) |receipt| {
            self.hold_seat = receipt.entry.seat_id;
            self.held_usd = receipt.entry.cost.usd().?;
        }
        var pending_settled = false;
        var hold_settled = false;

        if (try readAll(gpa, path_z)) |bytes| {
            defer gpa.free(bytes);
            const complete_len = if (std.mem.lastIndexOfScalar(u8, bytes, '\n')) |nl| nl + 1 else 0;
            var lines = std.mem.splitScalar(u8, bytes[0..complete_len], '\n');
            while (lines.next()) |line| {
                if (std.mem.trim(u8, line, " \t\r").len == 0) continue;
                const entry = try parseEntry(gpa, line);
                self.add(entry);
                if (pending) |receipt| pending_settled = pending_settled or receipt.settledBy(entry, self.entries);
                if (held) |receipt| hold_settled = hold_settled or receipt.settledBy(entry, self.entries);
            }
            if (complete_len != bytes.len) try truncate(path_z, complete_len);
        }
        if (pending) |receipt| try self.recover(receipt, pending_settled, pending_path);
        if (held) |receipt| try self.recover(receipt, hold_settled, hold_path);
        return self;
    }

    pub fn deinit(self: *Ledger, gpa: std.mem.Allocator) void {
        gpa.free(self.path);
        gpa.free(self.pending_path);
        self.* = undefined;
    }

    /// The controller died after admission but before a durable result.
    /// Never give a fresh dollar allowance to that seat.
    fn recover(self: *Ledger, receipt: Receipt, settled: bool, receipt_path: [:0]const u8) LoadError!void {
        if (receipt.entries_before > self.entries) return error.CorruptLedger;
        if (settled) {
            pfs.unlinkPath(receipt_path.ptr) catch return error.RepairFailed;
            if (self.pending_seat) |id| if (id.eql(receipt.entry.seat_id)) {
                self.pending_seat = null;
            };
            if (self.hold_seat) |id| if (id.eql(receipt.entry.seat_id)) {
                self.hold_seat = null;
                self.held_usd = 0;
            };
            return;
        }
        self.charge(receipt.entry) catch |err| switch (err) {
            error.BudgetExhausted => {},
            else => return error.RepairFailed,
        };
    }

    /// Persist admission before any paid work. An interrupted controller
    /// consumes this allowance on reopen; a durable charge settles it.
    /// The live seat still receives the full remaining cap.
    pub fn reserve(self: *Ledger, seat_id: types.SeatId, harness: types.Harness) ChargeError!void {
        if (self.isExhausted()) return error.BudgetExhausted;
        if (self.pending_seat != null) return error.WriteFailed;
        try install(self.pending_path, .{ .seat_id = seat_id, .harness = harness, .wallclock_ms = 0, .cost = .{ .reserved = self.remainingUsd() } }, self.entries);
        self.pending_seat = seat_id;
    }

    pub fn hold(self: *Ledger, seat_id: types.SeatId, harness: types.Harness, usd: f64) ChargeError!void {
        if (!std.math.isFinite(usd) or usd <= 0) return error.InvalidAmount;
        if (usd >= self.remainingUsd()) return error.BudgetExhausted;
        if (self.hold_seat != null) return error.WriteFailed;
        var hold_buf: PathBuf = undefined;
        const hold_path = holdPath(&hold_buf, self.path) catch return error.WriteFailed;
        try install(hold_path, .{ .seat_id = seat_id, .harness = harness, .wallclock_ms = 0, .cost = .{ .reserved = usd } }, self.entries);
        self.hold_seat = seat_id;
        self.held_usd = usd;
    }

    /// Append `entry` durably, then add it to the totals. Returns
    /// `BudgetExhausted` when the total has reached the cap, this charge
    /// included; the entry is recorded either way, since the money is spent.
    pub fn charge(self: *Ledger, entry: Entry) ChargeError!void {
        if (entry.cost.usd()) |amount| {
            if (!std.math.isFinite(amount) or amount < 0) return error.InvalidAmount;
        }
        // `{d}` spells an f64 out in full: up to ~330 digits at the extremes.
        var line_buf: [1024]u8 = undefined;
        const line = formatEntry(&line_buf, entry);
        const fd = pfs.open(self.path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, 0o600);
        if (fd < 0) return error.WriteFailed;
        defer pfs.close(fd);
        if (!pfs.writeAll(fd, line)) return error.WriteFailed;
        pfs.fsyncChecked(fd) catch return error.WriteFailed;
        self.add(entry);
        if (self.pending_seat) |pending_id| if (pending_id.eql(entry.seat_id)) {
            pfs.unlinkPath(self.pending_path.ptr) catch return error.WriteFailed;
            self.pending_seat = null;
        };
        if (self.hold_seat) |hold_id| if (hold_id.eql(entry.seat_id)) {
            var hold_buf: PathBuf = undefined;
            const hold_path = holdPath(&hold_buf, self.path) catch return error.WriteFailed;
            pfs.unlinkPath(hold_path.ptr) catch return error.WriteFailed;
            self.hold_seat = null;
            self.held_usd = 0;
        };
        if (self.isExhausted()) {
            // `host_failure`: a host-side stop, not a user cancellation.
            if (self.abort_on_exhaustion) |signal| signal.abort(.host_failure);
            return error.BudgetExhausted;
        }
    }

    pub fn isExhausted(self: *const Ledger) bool {
        return self.spent_usd + self.held_usd >= self.cap_usd;
    }

    /// What is left of the cap after the spend and the hold, never
    /// negative. A metacodes seat receives this as its subagent
    /// `cost_budget_usd`.
    pub fn remainingUsd(self: *const Ledger) f64 {
        return @max(self.cap_usd - self.spent_usd - self.held_usd, 0);
    }

    fn add(self: *Ledger, entry: Entry) void {
        self.spent_usd += entry.cost.usd() orelse 0;
        self.wallclock_ms +|= entry.wallclock_ms;
        self.entries += 1;
    }
};

const PathBuf = [std.fs.max_path_bytes]u8;

pub const hold_suffix = ".hold";

fn holdPath(buf: *PathBuf, path: []const u8) error{PathTooLong}![:0]const u8 {
    return std.fmt.bufPrintZ(buf, "{s}" ++ hold_suffix, .{path}) catch error.PathTooLong;
}

const Receipt = struct {
    entry: Entry,
    entries_before: usize,

    fn read(gpa: std.mem.Allocator, path: [:0]const u8) LoadError!?Receipt {
        const bytes = try readAll(gpa, path) orelse return null;
        defer gpa.free(bytes);
        const entry = try parseEntry(gpa, bytes);
        if (entry.cost != .reserved) return error.CorruptLedger;
        return .{ .entry = entry, .entries_before = try pendingBefore(gpa, bytes) };
    }

    /// Only a charge after the receipt settles it: a retried seat keeps its
    /// logical id, so an older charge of the same id does not count.
    fn settledBy(self: Receipt, entry: Entry, entries: usize) bool {
        return entries > self.entries_before and self.entry.seat_id.eql(entry.seat_id);
    }
};

fn install(receipt_path: [:0]const u8, entry: Entry, entries_before: usize) ChargeError!void {
    var tmp_buf: PathBuf = undefined;
    const tmp = std.fmt.bufPrintZ(&tmp_buf, "{s}.tmp", .{receipt_path}) catch return error.WriteFailed;
    // Installation can leave both names hard-linked after a crash. Never
    // truncate the stale temp: it may still be the admitted receipt.
    pfs.unlinkPath(tmp.ptr) catch |err| switch (err) {
        error.NotFound => {},
        error.UnlinkFailed => return error.WriteFailed,
    };
    defer pfs.unlinkPath(tmp.ptr) catch {};
    var buf: [1024]u8 = undefined;
    const bytes = formatEntry(&buf, entry);
    const suffix = std.fmt.bufPrint(buf[bytes.len - 2 ..], ",\"entries_before\":{d}}}\n", .{entries_before}) catch unreachable;
    {
        const fd = pfs.open(tmp.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true, .NOFOLLOW = true }, 0o600);
        if (fd < 0) return error.WriteFailed;
        defer pfs.close(fd);
        if (!pfs.writeAll(fd, buf[0 .. bytes.len - 2 + suffix.len])) return error.WriteFailed;
        pfs.fsyncChecked(fd) catch return error.WriteFailed;
    }
    switch (pfs.installNoReplace(tmp.ptr, receipt_path.ptr) catch return error.WriteFailed) {
        .moved, .linked => {},
        .already_exists => return error.WriteFailed,
    }
}

fn pendingBefore(gpa: std.mem.Allocator, bytes: []const u8) LoadError!usize {
    const Before = struct { entries_before: usize };
    const parsed = std.json.parseFromSlice(Before, gpa, bytes, .{ .ignore_unknown_fields = true }) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.CorruptLedger,
    };
    defer parsed.deinit();
    return parsed.value.entries_before;
}

fn formatEntry(buf: []u8, entry: Entry) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    w.print("{{\"seat_id\":\"{s}\",\"harness\":\"{s}\",\"usd\":", .{ entry.seat_id.slice(), entry.harness.name() }) catch unreachable;
    if (entry.cost.usd()) |amount| {
        w.print("{d}", .{amount}) catch unreachable;
    } else {
        w.writeAll("null") catch unreachable;
    }
    w.print(",\"wallclock_ms\":{d},\"source\":\"{s}\"}}\n", .{ entry.wallclock_ms, @tagName(entry.cost) }) catch unreachable;
    return w.buffered();
}

fn parseEntry(gpa: std.mem.Allocator, line: []const u8) LoadError!Entry {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), line, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.CorruptLedger,
    };
    if (root != .object) return error.CorruptLedger;
    const obj = root.object;
    const seat_id = types.SeatId.parse(stringField(obj, "seat_id") orelse return error.CorruptLedger) catch
        return error.CorruptLedger;
    const harness = types.Harness.parse(stringField(obj, "harness") orelse return error.CorruptLedger) orelse
        return error.CorruptLedger;
    const source = Source.parse(stringField(obj, "source") orelse return error.CorruptLedger) orelse
        return error.CorruptLedger;
    const wallclock_ms: u64 = switch (obj.get("wallclock_ms") orelse return error.CorruptLedger) {
        .integer => |n| std.math.cast(u64, n) orelse return error.CorruptLedger,
        else => return error.CorruptLedger,
    };
    const usd: ?f64 = switch (obj.get("usd") orelse return error.CorruptLedger) {
        .null => null,
        .integer => |n| @floatFromInt(n),
        .float => |f| f,
        else => return error.CorruptLedger,
    };
    const cost: Cost = switch (source) {
        .wallclock_only => if (usd == null) .wallclock_only else return error.CorruptLedger,
        .provider_estimate => .{ .provider_estimate = usd orelse return error.CorruptLedger },
        .harness_reported => .{ .harness_reported = usd orelse return error.CorruptLedger },
        .reserved => .{ .reserved = usd orelse return error.CorruptLedger },
    };
    if (cost.usd()) |amount| if (!std.math.isFinite(amount) or amount < 0) return error.CorruptLedger;
    return .{ .seat_id = seat_id, .harness = harness, .wallclock_ms = wallclock_ms, .cost = cost };
}

fn stringField(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const value = obj.get(key) orelse return null;
    return if (value == .string) value.string else null;
}

/// The whole file, or null when it does not exist.
fn readAll(gpa: std.mem.Allocator, path_z: [:0]const u8) LoadError!?[]u8 {
    const fd = pfs.open(path_z.ptr, .{ .ACCMODE = .RDONLY }, 0);
    if (fd < 0) return if (pfs.lastErrnoIs(.NOENT)) null else error.ReadFailed;
    defer pfs.close(fd);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = pfs.readZ(fd, &chunk) catch return error.ReadFailed;
        if (n == 0) break;
        try out.appendSlice(gpa, chunk[0..n]);
    }
    return try out.toOwnedSlice(gpa);
}

fn truncate(path_z: [:0]const u8, len: usize) LoadError!void {
    const fd = pfs.open(path_z.ptr, .{ .ACCMODE = .RDWR }, 0);
    if (fd < 0) return error.RepairFailed;
    defer pfs.close(fd);
    pfs.setSize(fd, len) catch return error.RepairFailed;
    pfs.fsyncChecked(fd) catch return error.RepairFailed;
}

// ── tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;
const TestRoot = @import("run_dir.zig").test_support.TestRoot;

fn seat(text: []const u8) types.SeatId {
    return types.SeatId.parse(text) catch unreachable;
}

fn ledgerPath(buf: []u8, root: *const TestRoot) []const u8 {
    return std.fmt.bufPrint(buf, "{s}/budget.jsonl", .{root.slice()}) catch unreachable;
}

fn writeRaw(path: []const u8, bytes: []const u8) !void {
    const path_z = try testing.allocator.dupeZ(u8, path);
    defer testing.allocator.free(path_z);
    const fd = pfs.open(path_z.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true }, 0o600);
    if (fd < 0) return error.OpenFailed;
    defer pfs.close(fd);
    if (!pfs.writeAll(fd, bytes)) return error.WriteFailed;
}

test "ledger: charges persist and load re-sums them" {
    var root = TestRoot.init("cc-zig-teamwork-ledger");
    defer root.deinit();
    var pbuf: [512]u8 = undefined;
    const path = ledgerPath(&pbuf, &root);

    {
        var ledger = try Ledger.load(testing.allocator, path, 1.0);
        defer ledger.deinit(testing.allocator);
        try testing.expectEqual(@as(usize, 0), ledger.entries);
        try ledger.charge(.{ .seat_id = seat("implementer-1"), .harness = .metacodes, .wallclock_ms = 1000, .cost = .{ .provider_estimate = 0.25 } });
        try ledger.charge(.{ .seat_id = seat("reviewer-1"), .harness = .claude_code, .wallclock_ms = 2000, .cost = .{ .harness_reported = 0.5 } });
        try ledger.charge(.{ .seat_id = seat("verifier-1"), .harness = .claude_code, .wallclock_ms = 3000, .cost = .wallclock_only });
        try testing.expectError(error.InvalidAmount, ledger.charge(.{ .seat_id = seat("x"), .harness = .metacodes, .wallclock_ms = 0, .cost = .{ .provider_estimate = -1 } }));
        try testing.expectError(error.InvalidAmount, ledger.charge(.{ .seat_id = seat("x"), .harness = .metacodes, .wallclock_ms = 0, .cost = .{ .provider_estimate = std.math.nan(f64) } }));
        try testing.expectApproxEqAbs(@as(f64, 0.25), ledger.remainingUsd(), 1e-9);
    }

    var reloaded = try Ledger.load(testing.allocator, path, 1.0);
    defer reloaded.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), reloaded.entries);
    try testing.expectApproxEqAbs(@as(f64, 0.75), reloaded.spent_usd, 1e-9);
    try testing.expectEqual(@as(u64, 6000), reloaded.wallclock_ms);
    try testing.expect(!reloaded.isExhausted());
}

test "ledger: crossing the cap is BudgetExhausted, and the charge is still recorded" {
    var root = TestRoot.init("cc-zig-teamwork-cap");
    defer root.deinit();
    var pbuf: [512]u8 = undefined;
    const path = ledgerPath(&pbuf, &root);

    var ledger = try Ledger.load(testing.allocator, path, 0.5);
    defer ledger.deinit(testing.allocator);
    var live_seats = types.AbortSignal.init();
    ledger.abort_on_exhaustion = &live_seats;
    try ledger.charge(.{ .seat_id = seat("implementer-1"), .harness = .metacodes, .wallclock_ms = 10, .cost = .{ .provider_estimate = 0.3 } });
    try testing.expect(!live_seats.isAborted());
    try testing.expectError(error.BudgetExhausted, ledger.charge(.{ .seat_id = seat("implementer-1"), .harness = .claude_code, .wallclock_ms = 10, .cost = .{ .harness_reported = 0.3 } }));
    try testing.expect(ledger.isExhausted());
    // The exhausting charge itself stops every seat sharing the signal.
    try testing.expect(live_seats.isAborted());
    try testing.expectEqual(@as(f64, 0), ledger.remainingUsd());
    // Every later charge reports exhaustion too.
    try testing.expectError(error.BudgetExhausted, ledger.charge(.{ .seat_id = seat("verifier-1"), .harness = .metacodes, .wallclock_ms = 10, .cost = .wallclock_only }));

    var reloaded = try Ledger.load(testing.allocator, path, 0.5);
    defer reloaded.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), reloaded.entries);
    try testing.expect(reloaded.isExhausted());
    try testing.expectError(error.InvalidCap, Ledger.load(testing.allocator, path, 0));
}

test "ledger: a controller crash after reservation consumes the remaining allowance on reopen" {
    var root = TestRoot.init("cc-zig-teamwork-reservation-crash");
    defer root.deinit();
    var pbuf: [512]u8 = undefined;
    const path = ledgerPath(&pbuf, &root);
    {
        var ledger = try Ledger.load(testing.allocator, path, 5);
        defer ledger.deinit(testing.allocator);
        try ledger.charge(.{ .seat_id = seat("implementer-1"), .harness = .metacodes, .wallclock_ms = 0, .cost = .{ .provider_estimate = 1 } });
        try ledger.reserve(seat("reviewer-1"), .claude_code);
        try testing.expectEqual(@as(f64, 4), ledger.remainingUsd());
        try testing.expectError(error.WriteFailed, ledger.reserve(seat("reviewer-2"), .claude_code));
        // Simulate process loss before a terminal harness event.
    }
    var reopened = try Ledger.load(testing.allocator, path, 5);
    defer reopened.deinit(testing.allocator);
    try testing.expect(reopened.isExhausted());
    try testing.expectEqual(@as(usize, 2), reopened.entries);
    try testing.expect(!pfs.exists(reopened.pending_path.ptr));
    var again = try Ledger.load(testing.allocator, path, 5);
    defer again.deinit(testing.allocator);
    try testing.expectEqual(@as(f64, 5), again.spent_usd);
    try testing.expectEqual(@as(usize, 2), again.entries);
}

test "ledger: interrupted reservation temp writes leave recovery and a new admission usable" {
    for ([_][]const u8{ "", "{\"seat_id\":\"reviewer-1\",\"harness\":" }) |partial| {
        var root = TestRoot.init("cc-zig-teamwork-reservation-temp");
        defer root.deinit();
        var pbuf: [512]u8 = undefined;
        const path = ledgerPath(&pbuf, &root);
        var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
        const tmp = try std.fmt.bufPrintZ(&tmp_buf, "{s}.pending.tmp", .{path});
        {
            var ledger = try Ledger.load(testing.allocator, path, 5);
            defer ledger.deinit(testing.allocator);
            try ledger.charge(.{ .seat_id = seat("implementer-1"), .harness = .metacodes, .wallclock_ms = 1, .cost = .{ .provider_estimate = 1 } });
            // Process loss before the complete, fsynced receipt is installed.
            try writeRaw(tmp, partial);
            try testing.expect(!pfs.exists(ledger.pending_path.ptr));
        }
        {
            var reopened = try Ledger.load(testing.allocator, path, 5);
            defer reopened.deinit(testing.allocator);
            try testing.expectEqual(@as(usize, 1), reopened.entries);
            try testing.expectEqual(@as(f64, 4), reopened.remainingUsd());
            try testing.expect(reopened.pending_seat == null);
            try reopened.reserve(seat("reviewer-1"), .claude_code);
            try testing.expect(!pfs.exists(tmp.ptr));
            const receipt = (try readAll(testing.allocator, reopened.pending_path)).?;
            defer testing.allocator.free(receipt);
            try testing.expectEqual(@as(usize, 1), try pendingBefore(testing.allocator, receipt));
        }
        // Only the installed admission consumes the remaining allowance.
        var recovered = try Ledger.load(testing.allocator, path, 5);
        defer recovered.deinit(testing.allocator);
        try testing.expect(recovered.isExhausted());
        try testing.expectEqual(@as(usize, 2), recovered.entries);
    }
}

test "ledger: a stale writer cannot overwrite an installed admission and cleans its temp" {
    var root = TestRoot.init("cc-zig-teamwork-reservation-immutable");
    defer root.deinit();
    var pbuf: [512]u8 = undefined;
    const path = ledgerPath(&pbuf, &root);
    {
        var stale = try Ledger.load(testing.allocator, path, 5);
        defer stale.deinit(testing.allocator);
        var ledger = try Ledger.load(testing.allocator, path, 5);
        defer ledger.deinit(testing.allocator);
        try ledger.reserve(seat("implementer-1"), .metacodes);
        const original = (try readAll(testing.allocator, ledger.pending_path)).?;
        defer testing.allocator.free(original);
        try testing.expectError(error.WriteFailed, stale.reserve(seat("reviewer-1"), .claude_code));
        try testing.expect(stale.pending_seat == null);
        const preserved = (try readAll(testing.allocator, ledger.pending_path)).?;
        defer testing.allocator.free(preserved);
        try testing.expectEqualStrings(original, preserved);
        var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
        const tmp = try std.fmt.bufPrintZ(&tmp_buf, "{s}.tmp", .{ledger.pending_path});
        try testing.expect(!pfs.exists(tmp.ptr));
    }
    var recovered = try Ledger.load(testing.allocator, path, 5);
    defer recovered.deinit(testing.allocator);
    try testing.expect(recovered.isExhausted());
    try testing.expectEqual(@as(usize, 1), recovered.entries);
}

test "ledger: a temp left hard-linked after installation cannot mutate the admitted receipt" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest; // Windows installation moves the temp.
    var root = TestRoot.init("cc-zig-teamwork-reservation-linked-temp");
    defer root.deinit();
    var pbuf: [512]u8 = undefined;
    const path = ledgerPath(&pbuf, &root);
    {
        var stale = try Ledger.load(testing.allocator, path, 5);
        defer stale.deinit(testing.allocator);
        var ledger = try Ledger.load(testing.allocator, path, 5);
        defer ledger.deinit(testing.allocator);
        try ledger.reserve(seat("verifier-1"), .metacodes);
        const original = (try readAll(testing.allocator, ledger.pending_path)).?;
        defer testing.allocator.free(original);
        var tmp_buf: [std.fs.max_path_bytes]u8 = undefined;
        const tmp = try std.fmt.bufPrintZ(&tmp_buf, "{s}.tmp", .{ledger.pending_path});
        // Recreate the two names a crash after link(), before unlink(), leaves.
        try testing.expectEqual(pfs.InstallNoReplaceResult.linked, try pfs.installNoReplace(ledger.pending_path.ptr, tmp.ptr));
        try testing.expectError(error.WriteFailed, stale.reserve(seat("reviewer-1"), .claude_code));
        const preserved = (try readAll(testing.allocator, ledger.pending_path)).?;
        defer testing.allocator.free(preserved);
        try testing.expectEqualStrings(original, preserved);
        try testing.expect(!pfs.exists(tmp.ptr));
    }
    var recovered = try Ledger.load(testing.allocator, path, 5);
    defer recovered.deinit(testing.allocator);
    try testing.expect(recovered.isExhausted());
    try testing.expectEqual(@as(usize, 1), recovered.entries);
}

test "ledger: a durable charge settles its reservation without double billing after a crash" {
    var root = TestRoot.init("cc-zig-teamwork-reservation-settled");
    defer root.deinit();
    var pbuf: [512]u8 = undefined;
    const path = ledgerPath(&pbuf, &root);
    {
        var ledger = try Ledger.load(testing.allocator, path, 5);
        defer ledger.deinit(testing.allocator);
        try ledger.reserve(seat("implementer-1"), .metacodes);
        const receipt = (try readAll(testing.allocator, ledger.pending_path)).?;
        defer testing.allocator.free(receipt);
        try ledger.charge(.{ .seat_id = seat("implementer-1"), .harness = .metacodes, .wallclock_ms = 1, .cost = .{ .provider_estimate = 0.25 } });
        try testing.expect(!pfs.exists(ledger.pending_path.ptr));
        // A crash just before unlink would leave the same receipt behind.
        try writeRaw(ledger.pending_path, receipt);
    }
    var reopened = try Ledger.load(testing.allocator, path, 5);
    defer reopened.deinit(testing.allocator);
    try testing.expectEqual(@as(f64, 0.25), reopened.spent_usd);
    try testing.expectEqual(@as(usize, 1), reopened.entries);
    try testing.expect(!pfs.exists(reopened.pending_path.ptr));
    try reopened.reserve(seat("reviewer-1"), .claude_code);
}

test "ledger: an older charge for a retried seat cannot settle its new admission" {
    var root = TestRoot.init("cc-zig-teamwork-reservation-retry");
    defer root.deinit();
    var pbuf: [512]u8 = undefined;
    const path = ledgerPath(&pbuf, &root);
    {
        var ledger = try Ledger.load(testing.allocator, path, 5);
        defer ledger.deinit(testing.allocator);
        try ledger.reserve(seat("verifier-1"), .metacodes);
        try ledger.charge(.{ .seat_id = seat("verifier-1"), .harness = .metacodes, .wallclock_ms = 1, .cost = .{ .provider_estimate = 0.25 } });
        // Recovery can restart audit attempt 1 if its verdict never landed.
        try ledger.reserve(seat("verifier-1"), .metacodes);
    }
    var reopened = try Ledger.load(testing.allocator, path, 5);
    defer reopened.deinit(testing.allocator);
    try testing.expect(reopened.isExhausted());
    try testing.expectEqual(@as(f64, 5), reopened.spent_usd);
    try testing.expectEqual(@as(usize, 2), reopened.entries);
}

test "ledger: a torn last line is dropped and truncated; a corrupt complete line fails closed" {
    var root = TestRoot.init("cc-zig-teamwork-torn");
    defer root.deinit();
    var pbuf: [512]u8 = undefined;
    const path = ledgerPath(&pbuf, &root);

    {
        var ledger = try Ledger.load(testing.allocator, path, 10);
        defer ledger.deinit(testing.allocator);
        try ledger.charge(.{ .seat_id = seat("implementer-1"), .harness = .metacodes, .wallclock_ms = 5, .cost = .{ .provider_estimate = 1.5 } });
    }
    // A crash in the middle of the next append.
    try writeRaw(path, "{\"seat_id\":\"reviewer-1\",\"harness\":\"claude_code\",\"usd\":2");
    {
        var ledger = try Ledger.load(testing.allocator, path, 10);
        defer ledger.deinit(testing.allocator);
        try testing.expectEqual(@as(usize, 1), ledger.entries);
        try testing.expectApproxEqAbs(@as(f64, 1.5), ledger.spent_usd, 1e-9);
        // The next append starts on a clean line.
        try ledger.charge(.{ .seat_id = seat("reviewer-1"), .harness = .claude_code, .wallclock_ms = 5, .cost = .{ .harness_reported = 2 } });
    }
    {
        var ledger = try Ledger.load(testing.allocator, path, 10);
        defer ledger.deinit(testing.allocator);
        try testing.expectEqual(@as(usize, 2), ledger.entries);
        try testing.expectApproxEqAbs(@as(f64, 3.5), ledger.spent_usd, 1e-9);
    }

    try writeRaw(path, "{\"seat_id\":\"reviewer-1\",\"harness\":\"claude_code\",\"usd\":null,\"wallclock_ms\":1,\"source\":\"harness_reported\"}\n");
    try testing.expectError(error.CorruptLedger, Ledger.load(testing.allocator, path, 10));
}

test "ledger: a manager hold is kept from the other seats, settled by its charge, and consumed once after a crash" {
    var root = TestRoot.init("cc-zig-teamwork-manager-hold");
    defer root.deinit();
    var pbuf: [512]u8 = undefined;
    const path = ledgerPath(&pbuf, &root);
    var hold_buf: PathBuf = undefined;
    const hold_path = try holdPath(&hold_buf, path);
    {
        var ledger = try Ledger.load(testing.allocator, path, 5);
        defer ledger.deinit(testing.allocator);
        try ledger.hold(seat("manager-1"), .claude_code, 2);
        try testing.expectEqual(@as(f64, 3), ledger.remainingUsd());
        try testing.expectError(error.WriteFailed, ledger.hold(seat("manager-2"), .claude_code, 1));
        try ledger.reserve(seat("implementer-1"), .claude_code);
        const receipt = (try readAll(testing.allocator, ledger.pending_path)).?;
        defer testing.allocator.free(receipt);
        try testing.expectEqual(@as(f64, 3), (try parseEntry(testing.allocator, receipt)).cost.usd().?);
        try ledger.charge(.{ .seat_id = seat("implementer-1"), .harness = .claude_code, .wallclock_ms = 1, .cost = .{ .harness_reported = 1 } });
        try testing.expectEqual(@as(f64, 2), ledger.remainingUsd());
        try ledger.charge(.{ .seat_id = seat("manager-1"), .harness = .claude_code, .wallclock_ms = 1, .cost = .{ .harness_reported = 0.5 } });
        try testing.expect(!pfs.exists(hold_path.ptr));
        try testing.expectEqual(@as(f64, 3.5), ledger.remainingUsd());
        try testing.expectError(error.BudgetExhausted, ledger.hold(seat("manager-2"), .claude_code, 3.5));
        try ledger.hold(seat("manager-2"), .claude_code, 2);
    }
    for (0..2) |_| {
        var reopened = try Ledger.load(testing.allocator, path, 5);
        defer reopened.deinit(testing.allocator);
        try testing.expectEqual(@as(f64, 3.5), reopened.spent_usd);
        try testing.expectEqual(@as(usize, 3), reopened.entries);
        try testing.expectEqual(@as(f64, 0), reopened.held_usd);
        try testing.expect(reopened.hold_seat == null);
        try testing.expect(!pfs.exists(hold_path.ptr));
    }
}
