//! A provider credential that a live Session can replace (issue #336).
//!
//! Every client used to borrow its owner's `api_key` slice and read it at each
//! request, so the bytes could never change under a live client. A `Cell` is
//! the Session-owned replaceable credential, and a client authenticates
//! through a `Credential`: fixed borrowed bytes, or a cell. A client never
//! keeps cell bytes past `header`, which copies them into the request's own
//! header value under the cell's lock. Therefore:
//!
//! - `Replacement.publish` swapping the bytes is an update's linearization
//!   point. A header materialized after it carries the new credential; one
//!   materialized before it keeps the old one for that request alone, and its
//!   connection is never touched. The transports materialize a request's
//!   header as they send it, once they hold its connection slot.
//! - Once the swap is done, nothing references the previous bytes, so publish
//!   erases and frees them at once.
//! - The lock is a leaf: while it is held, nothing is acquired except the
//!   allocator that copies the header.
//!
//! The bytes never leave this file except as a header value; the caller
//! erases that copy once the request is set up (`auth_header.Header`).
//!
//! `validate` is the one rule for credential bytes. A cell refuses anything
//! else at creation (a Session's create and restore) and at replacement, and
//! a fixed credential is checked before every header is built, so no
//! credential the HTTP client would reject (it asserts on CR LF) or that a
//! header cannot carry ever reaches it.

const std = @import("std");
const sync = @import("platform").sync;
const auth_header = @import("auth_header.zig");
const secure = @import("metacodes-base").util.secure;

/// The longest credential accepted. It is above any request header a
/// provider accepts, so nothing usable is refused.
pub const MAX_CREDENTIAL_BYTES: usize = 16 * 1024;

pub const ValidationError = error{
    EmptyCredential,
    /// A byte outside printable ASCII (0x21-0x7E). A control byte would split
    /// the header (the HTTP client asserts on CR LF), and no provider issues a
    /// key or token with a space or a non-ASCII byte.
    InvalidCredentialByte,
    CredentialTooLong,
};

pub const ReplacementError = ValidationError || error{OutOfMemory};
pub const CreateError = ValidationError || error{OutOfMemory};
pub const HeaderError = ValidationError || auth_header.Error;

/// The error a transport returns when it cannot build a request's header:
/// `InvalidCredential` when the credential broke `validate` (nothing was
/// sent, and retrying cannot help), `RequestFailed` otherwise.
pub fn requestError(err: HeaderError) error{ InvalidCredential, RequestFailed } {
    return switch (err) {
        error.EmptyCredential, error.InvalidCredentialByte, error.CredentialTooLong => error.InvalidCredential,
        error.SignedAdapterRequired, error.EmptyCredentialMaterial, error.OutOfMemory => error.RequestFailed,
    };
}

/// Whether `candidate` can be a credential: 1 to `MAX_CREDENTIAL_BYTES`
/// bytes, each printable ASCII (0x21-0x7E).
pub fn validate(candidate: []const u8) ValidationError!void {
    if (candidate.len == 0) return error.EmptyCredential;
    if (candidate.len > MAX_CREDENTIAL_BYTES) return error.CredentialTooLong;
    for (candidate) |byte| {
        if (byte < 0x21 or byte > 0x7e) return error.InvalidCredentialByte;
    }
}

/// What a client authenticates with.
pub const Credential = union(enum) {
    /// Borrowed bytes the owner keeps alive and unchanged for the client's
    /// lifetime (the CLI's clients, tests, a refreshed OAuth token the client
    /// installs itself).
    fixed: []const u8,
    /// A Session's credential, read under the cell's lock at every request.
    replaceable: *Cell,

    /// The request header for this credential under `scheme`, as
    /// `auth_header.build` renders it. The value is the caller's to erase.
    /// Fixed bytes come from wherever the owner got them (a flag, the
    /// environment, a key file, a token response), so they are validated
    /// here, before anything is sent; a cell's bytes already were.
    pub fn header(
        self: Credential,
        allocator: std.mem.Allocator,
        scheme: ?auth_header.AuthScheme,
    ) HeaderError!auth_header.Header {
        return switch (self) {
            .fixed => |bytes| {
                try validate(bytes);
                return auth_header.build(allocator, scheme, bytes);
            },
            .replaceable => |cell| cell.header(allocator, scheme),
        };
    }

    /// Bytes that may be borrowed past this call: a fixed credential's. A
    /// replaceable credential is never lent, because an update erases the
    /// bytes a borrower would still hold.
    pub fn lendable(self: Credential) ?[]const u8 {
        return switch (self) {
            .fixed => |bytes| bytes,
            .replaceable => null,
        };
    }
};

pub const Cell = struct {
    allocator: std.mem.Allocator,
    mutex: sync.Mutex = .{},
    /// Owned by the cell; replaced only by `Replacement.publish`.
    bytes: []u8,
    /// 1 at creation, plus one per published replacement.
    generation: u64 = 1,

    /// Validate `initial` and copy it into a new cell.
    pub fn create(allocator: std.mem.Allocator, initial: []const u8) CreateError!*Cell {
        try validate(initial);
        const self = try allocator.create(Cell);
        errdefer allocator.destroy(self);
        self.* = .{ .allocator = allocator, .bytes = try allocator.dupe(u8, initial) };
        return self;
    }

    /// Erase and free the bytes. Every client reading the cell must be gone.
    pub fn destroy(self: *Cell) void {
        const allocator = self.allocator;
        secure.free(allocator, self.bytes);
        self.* = undefined;
        allocator.destroy(self);
    }

    /// Validate and copy `candidate` for this cell. Nothing is locked or
    /// changed: a refusal, including OutOfMemory, leaves the cell as it was.
    pub fn prepare(self: *Cell, candidate: []const u8) ReplacementError!Replacement {
        try validate(candidate);
        return .{ .cell = self, .bytes = try self.allocator.dupe(u8, candidate) };
    }

    /// The header for the current bytes, copied under the lock.
    pub fn header(
        self: *Cell,
        allocator: std.mem.Allocator,
        scheme: ?auth_header.AuthScheme,
    ) auth_header.Error!auth_header.Header {
        self.mutex.lock();
        defer self.mutex.unlock();
        return auth_header.build(allocator, scheme, self.bytes);
    }

    pub fn currentGeneration(self: *Cell) u64 {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.generation;
    }

    /// Whether the current bytes equal `candidate`, compared without an
    /// early exit on the first differing byte. For tests and diagnostics that
    /// must not print the credential.
    pub fn matches(self: *Cell, candidate: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (candidate.len != self.bytes.len) return false;
        var diff: u8 = 0;
        for (candidate, self.bytes) |a, b| diff |= a ^ b;
        return diff == 0;
    }
};

/// A validated copy waiting to replace its cell's bytes. Linear: exactly one
/// of `publish` or `discard` consumes it.
pub const Replacement = struct {
    cell: *Cell,
    bytes: []u8,

    /// Install the bytes and return the new generation. The previous bytes
    /// are erased and freed before this returns. Cannot fail.
    pub fn publish(self: *Replacement) u64 {
        const cell = self.cell;
        cell.mutex.lock();
        const previous = cell.bytes;
        cell.bytes = self.bytes;
        cell.generation += 1;
        const generation = cell.generation;
        cell.mutex.unlock();
        self.* = undefined;
        secure.free(cell.allocator, previous);
        return generation;
    }

    /// Erase and free a replacement that will not be published.
    pub fn discard(self: *Replacement) void {
        secure.free(self.cell.allocator, self.bytes);
        self.* = undefined;
    }
};

/// Records whether each freed block that once held `secret` was erased.
const EraseProbe = struct {
    backing: std.mem.Allocator,
    secret: []const u8,
    /// Blocks freed with the secret still in them.
    leaked: usize = 0,
    /// Blocks of the secret's length freed as zeros.
    erased: usize = 0,

    fn allocator(self: *EraseProbe) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = std.mem.Allocator.noResize,
            .remap = std.mem.Allocator.noRemap,
            .free = free,
        } };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *EraseProbe = @ptrCast(@alignCast(ctx));
        return self.backing.rawAlloc(len, alignment, ret_addr);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *EraseProbe = @ptrCast(@alignCast(ctx));
        if (std.mem.indexOf(u8, memory, self.secret) != null) self.leaked += 1;
        if (memory.len == self.secret.len and std.mem.allEqual(u8, memory, 0)) self.erased += 1;
        self.backing.rawFree(memory, alignment, ret_addr);
    }
};

test "a published replacement changes the next header and erases the previous bytes" {
    var probe = EraseProbe{ .backing = std.testing.allocator, .secret = "sk-old-credential" };
    const a = probe.allocator();
    const cell = try Cell.create(a, "sk-old-credential");
    const before = try (Credential{ .replaceable = cell }).header(std.testing.allocator, null);
    defer std.testing.allocator.free(before.value);
    try std.testing.expectEqualStrings("Bearer sk-old-credential", before.value);

    var replacement = try cell.prepare("sk-new-credential");
    try std.testing.expectEqual(@as(u64, 2), replacement.publish());
    try std.testing.expectEqual(@as(usize, 0), probe.leaked);
    try std.testing.expectEqual(@as(usize, 1), probe.erased);

    // A header materialized before the swap keeps the old bytes; the next one
    // carries the new bytes, under the same scheme.
    try std.testing.expectEqualStrings("Bearer sk-old-credential", before.value);
    const after = try cell.header(std.testing.allocator, .{ .api_key_header = "x-api-key" });
    defer std.testing.allocator.free(after.value);
    try std.testing.expectEqualStrings("x-api-key", after.name);
    try std.testing.expectEqualStrings("sk-new-credential", after.value);
    try std.testing.expect(cell.matches("sk-new-credential"));
    try std.testing.expect(!cell.matches("sk-old-credential"));

    probe.secret = "sk-new-credential";
    cell.destroy();
    try std.testing.expectEqual(@as(usize, 0), probe.leaked);
    try std.testing.expectEqual(@as(usize, 2), probe.erased);
}

test "refused replacements leave the cell and its generation unchanged" {
    var probe = EraseProbe{ .backing = std.testing.allocator, .secret = "sk-discarded-candidate" };
    const a = probe.allocator();
    const cell = try Cell.create(a, "sk-current");
    defer cell.destroy();

    try std.testing.expectError(error.EmptyCredential, cell.prepare(""));
    try std.testing.expectError(error.InvalidCredentialByte, cell.prepare("sk-a\r\nx-injected: 1"));
    try std.testing.expectError(error.InvalidCredentialByte, cell.prepare("sk a"));
    try std.testing.expectError(error.InvalidCredentialByte, cell.prepare("sk-\x00"));
    try std.testing.expectError(error.InvalidCredentialByte, cell.prepare("sk-\x7f"));
    try std.testing.expectError(error.InvalidCredentialByte, cell.prepare("sk-\xc3\xa9"));
    const long = "k" ** (MAX_CREDENTIAL_BYTES + 1);
    try std.testing.expectError(error.CredentialTooLong, cell.prepare(long));
    var longest = try cell.prepare("k" ** MAX_CREDENTIAL_BYTES);
    longest.discard();

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const oom_cell = try Cell.create(failing.allocator(), "sk-current");
    defer oom_cell.destroy();
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, oom_cell.prepare("sk-unreachable"));
    try std.testing.expect(oom_cell.matches("sk-current"));
    try std.testing.expectEqual(@as(u64, 1), oom_cell.currentGeneration());

    var discarded = try cell.prepare("sk-discarded-candidate");
    discarded.discard();
    try std.testing.expectEqual(@as(usize, 0), probe.leaked);
    try std.testing.expectEqual(@as(usize, 1), probe.erased);
    try std.testing.expect(cell.matches("sk-current"));
    try std.testing.expectEqual(@as(u64, 1), cell.currentGeneration());
}

test "a fixed credential renders the historical header and lends its bytes" {
    const fixed = Credential{ .fixed = "sk-fixed" };
    const header_value = try fixed.header(std.testing.allocator, null);
    defer std.testing.allocator.free(header_value.value);
    try std.testing.expectEqualStrings("authorization", header_value.name);
    try std.testing.expectEqualStrings("Bearer sk-fixed", header_value.value);
    try std.testing.expectEqualStrings("sk-fixed", fixed.lendable().?);

    const cell = try Cell.create(std.testing.allocator, "sk-cell");
    defer cell.destroy();
    try std.testing.expect((Credential{ .replaceable = cell }).lendable() == null);
}

test "concurrent publishers are linearized: the highest generation's bytes win" {
    const cell = try Cell.create(std.testing.allocator, "sk-initial");
    defer cell.destroy();
    const rounds = 200;
    const Publisher = struct {
        cell: *Cell,
        id: u8,
        /// This publisher's last generation and the bytes it published.
        last_generation: u64 = 0,
        last: [16]u8 = undefined,
        last_len: usize = 0,
        out_of_order: bool = false,

        fn run(self: *@This()) void {
            var name: [16]u8 = undefined;
            for (0..rounds) |round| {
                const candidate = std.fmt.bufPrint(&name, "sk-{d}-{d}", .{ self.id, round }) catch unreachable;
                var replacement = self.cell.prepare(candidate) catch unreachable;
                const generation = replacement.publish();
                // One thread's updates linearize in its own program order.
                if (generation <= self.last_generation) self.out_of_order = true;
                self.last_generation = generation;
                @memcpy(self.last[0..candidate.len], candidate);
                self.last_len = candidate.len;
            }
        }
    };
    const Reader = struct {
        cell: *Cell,
        done: std.atomic.Value(bool) = .init(false),
        torn: usize = 0,

        fn run(self: *@This()) void {
            while (!self.done.load(.acquire)) {
                const h = self.cell.header(std.heap.page_allocator, null) catch unreachable;
                defer std.heap.page_allocator.free(h.value);
                // Always one whole published credential: never torn, never erased.
                if (!std.mem.startsWith(u8, h.value, "Bearer sk-") or
                    std.mem.indexOfScalar(u8, h.value, 0) != null) self.torn += 1;
            }
        }
    };
    var publishers: [4]Publisher = undefined;
    for (&publishers, 0..) |*publisher, i| publisher.* = .{ .cell = cell, .id = @intCast(i) };
    var reader = Reader{ .cell = cell };
    const reader_thread = try std.Thread.spawn(.{}, Reader.run, .{&reader});
    var threads: [publishers.len]std.Thread = undefined;
    for (&threads, &publishers) |*thread, *publisher| thread.* = try std.Thread.spawn(.{}, Publisher.run, .{publisher});
    for (threads) |thread| thread.join();
    reader.done.store(true, .release);
    reader_thread.join();

    try std.testing.expectEqual(@as(usize, 0), reader.torn);
    var last = &publishers[0];
    for (&publishers) |*publisher| {
        try std.testing.expect(!publisher.out_of_order);
        if (publisher.last_generation > last.last_generation) last = publisher;
    }
    // Generations are a total order over every publish, and the bytes the
    // cell holds are the ones published with the highest generation.
    try std.testing.expectEqual(@as(u64, 1 + publishers.len * rounds), cell.currentGeneration());
    try std.testing.expectEqual(cell.currentGeneration(), last.last_generation);
    try std.testing.expect(cell.matches(last.last[0..last.last_len]));
}

test "creation and fixed credentials apply the same rule as a replacement" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.InvalidCredentialByte, Cell.create(a, "sk-a\r\nx-injected: 1"));
    try std.testing.expectError(error.InvalidCredentialByte, Cell.create(a, "sk a"));
    try std.testing.expectError(error.EmptyCredential, Cell.create(a, ""));
    try std.testing.expectError(error.CredentialTooLong, Cell.create(a, "k" ** (MAX_CREDENTIAL_BYTES + 1)));
    const longest = try Cell.create(a, "k" ** MAX_CREDENTIAL_BYTES);
    longest.destroy();

    // A fixed credential is checked before its header is built, so the HTTP
    // client never sees CR LF (it asserts on it) or any other refused byte.
    try std.testing.expectError(error.InvalidCredentialByte, (Credential{ .fixed = "sk-a\r\nx-injected: 1" }).header(a, null));
    try std.testing.expectError(error.InvalidCredentialByte, (Credential{ .fixed = "sk-\x7f" }).header(a, .{ .api_key_header = "x-api-key" }));
    try std.testing.expectError(error.EmptyCredential, (Credential{ .fixed = "" }).header(a, null));
    const accepted = try (Credential{ .fixed = "sk-fine" }).header(a, null);
    defer a.free(accepted.value);
    try std.testing.expectEqualStrings("Bearer sk-fine", accepted.value);
}
