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
//! Not thread-safe: the runtime serializes charges.

const std = @import("std");
const pfs = @import("platform").fs;
const types = @import("types.zig");

pub const Source = enum {
    /// metacodes' own estimate from provider usage.
    provider_estimate,
    /// The cost an external harness reported in its result.
    harness_reported,
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
    wallclock_only,

    pub fn usd(self: Cost) ?f64 {
        return switch (self) {
            .provider_estimate, .harness_reported => |amount| amount,
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
    cap_usd: f64,
    spent_usd: f64 = 0,
    wallclock_ms: u64 = 0,
    entries: usize = 0,

    /// Open the ledger at `path` with the run's cap, summing every entry
    /// already on disk. A missing file is an empty ledger.
    pub fn load(gpa: std.mem.Allocator, path: []const u8, cap_usd: f64) LoadError!Ledger {
        if (!std.math.isFinite(cap_usd) or cap_usd <= 0) return error.InvalidCap;
        if (path.len >= std.fs.max_path_bytes) return error.PathTooLong;
        const path_z = try gpa.dupeZ(u8, path);
        errdefer gpa.free(path_z);
        var self: Ledger = .{ .path = path_z, .cap_usd = cap_usd };

        const bytes = (try readAll(gpa, path_z)) orelse return self;
        defer gpa.free(bytes);
        const complete_len = if (std.mem.lastIndexOfScalar(u8, bytes, '\n')) |nl| nl + 1 else 0;
        var lines = std.mem.splitScalar(u8, bytes[0..complete_len], '\n');
        while (lines.next()) |line| {
            if (std.mem.trim(u8, line, " \t\r").len == 0) continue;
            self.add(try parseEntry(gpa, line));
        }
        if (complete_len != bytes.len) try truncate(path_z, complete_len);
        return self;
    }

    pub fn deinit(self: *Ledger, gpa: std.mem.Allocator) void {
        gpa.free(self.path);
        self.* = undefined;
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
        if (self.isExhausted()) return error.BudgetExhausted;
    }

    pub fn isExhausted(self: *const Ledger) bool {
        return self.spent_usd >= self.cap_usd;
    }

    /// What is left of the cap, never negative. A metacodes seat receives
    /// this as its subagent `cost_budget_usd`.
    pub fn remainingUsd(self: *const Ledger) f64 {
        return @max(self.cap_usd - self.spent_usd, 0);
    }

    fn add(self: *Ledger, entry: Entry) void {
        self.spent_usd += entry.cost.usd() orelse 0;
        self.wallclock_ms +|= entry.wallclock_ms;
        self.entries += 1;
    }
};

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
    try ledger.charge(.{ .seat_id = seat("implementer-1"), .harness = .metacodes, .wallclock_ms = 10, .cost = .{ .provider_estimate = 0.3 } });
    try testing.expectError(error.BudgetExhausted, ledger.charge(.{ .seat_id = seat("implementer-1"), .harness = .claude_code, .wallclock_ms = 10, .cost = .{ .harness_reported = 0.3 } }));
    try testing.expect(ledger.isExhausted());
    try testing.expectEqual(@as(f64, 0), ledger.remainingUsd());
    // Every later charge reports exhaustion too.
    try testing.expectError(error.BudgetExhausted, ledger.charge(.{ .seat_id = seat("verifier-1"), .harness = .metacodes, .wallclock_ms = 10, .cost = .wallclock_only }));

    var reloaded = try Ledger.load(testing.allocator, path, 0.5);
    defer reloaded.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 3), reloaded.entries);
    try testing.expect(reloaded.isExhausted());
    try testing.expectError(error.InvalidCap, Ledger.load(testing.allocator, path, 0));
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
