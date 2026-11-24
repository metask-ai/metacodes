const std = @import("std");
const util_time = @import("../util/time.zig");
const utf8 = @import("../util/utf8.zig");

pub const LINE_MAX_BYTES: usize = 500;
pub const EVENT_MAX_BYTES: usize = 3000;
pub const BUCKET_CAPACITY: u8 = 10;
pub const REFILL_MS: util_time.Millis = 2_000;
pub const OVER_BUDGET_STOP_MS: util_time.Millis = 30_000;
pub const READ_MAX_BYTES: usize = 64 * 1024;
pub const DEFAULT_TIMEOUT_MS: u64 = 300_000;
pub const MIN_TIMEOUT_MS: u64 = 1_000;
pub const MAX_TIMEOUT_MS: u64 = 3_600_000;

pub const Stop = enum { expired, too_much_output };

pub const State = struct {
    description: []const u8,
    timeout_ms: ?u64,
    stdout_cursor: u64 = 0,
    tokens: u8 = BUCKET_CAPACITY,
    refilled_ms: util_time.Millis,
    suppressed: u32 = 0,
    over_budget_since_ms: ?util_time.Millis = null,
    events_delivered: u32 = 0,
    stop: ?Stop = null,

    pub fn init(description: []const u8, timeout_ms: ?u64, now: util_time.Millis) State {
        return .{ .description = description, .timeout_ms = timeout_ms, .refilled_ms = now };
    }

    pub fn overdue(self: *const State, started_ms: util_time.Millis, now: util_time.Millis) ?Stop {
        if (self.timeout_ms) |limit| {
            if (now - started_ms >= @as(util_time.Millis, @intCast(limit))) return .expired;
        }
        if (self.over_budget_since_ms) |since| {
            if (now - since >= OVER_BUDGET_STOP_MS) return .too_much_output;
        }
        return null;
    }

    fn refill(self: *State, now: util_time.Millis) void {
        if (now <= self.refilled_ms) return;
        const earned = @divFloor(now - self.refilled_ms, REFILL_MS);
        if (earned <= 0) return;
        const room: util_time.Millis = BUCKET_CAPACITY - self.tokens;
        if (earned >= room) {
            self.tokens = BUCKET_CAPACITY;
            self.refilled_ms = now;
            return;
        }
        self.tokens += @intCast(earned);
        self.refilled_ms += earned * REFILL_MS;
    }
};

pub fn clampTimeout(requested: ?u64) u64 {
    const value = requested orelse return DEFAULT_TIMEOUT_MS;
    return std.math.clamp(value, MIN_TIMEOUT_MS, MAX_TIMEOUT_MS);
}

pub const End = union(enum) {
    stream_ended,
    script_failed: i32,
    killed,
    expired: struct { after_ms: u64, events_delivered: u32 },
    too_much_output,
};

pub const Notice = struct {
    id: [12]u8,
    description: []u8,
    event: []u8,
    end: ?End,

    pub fn deinit(self: *Notice, allocator: std.mem.Allocator) void {
        allocator.free(self.description);
        allocator.free(self.event);
        self.* = undefined;
    }
};

pub fn freeNotices(allocator: std.mem.Allocator, notices: []Notice) void {
    for (notices) |*notice| notice.deinit(allocator);
    allocator.free(notices);
}

pub const Batch = struct {
    consumed: usize,
    event: []u8,
};

pub const Mode = enum { streaming, final };

pub fn take(allocator: std.mem.Allocator, state: *State, chunk: []const u8, mode: Mode, now: util_time.Millis) !Batch {
    state.refill(now);
    const consumed = completeLength(chunk, mode);
    var lines = std.ArrayList([]const u8).empty;
    defer lines.deinit(allocator);
    var it = std.mem.splitScalar(u8, chunk[0..consumed], '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) continue;
        try lines.append(allocator, line);
    }
    const count: u32 = @intCast(lines.items.len);

    if (count == 0) {
        state.over_budget_since_ms = null;
        if (mode == .final and state.suppressed > 0) return .{ .consumed = consumed, .event = try renderEvent(allocator, state, &.{}) };
        return .{ .consumed = consumed, .event = &.{} };
    }
    if (mode == .streaming and state.tokens == 0) {
        state.suppressed +|= count;
        if (state.over_budget_since_ms == null) state.over_budget_since_ms = now;
        return .{ .consumed = consumed, .event = &.{} };
    }
    if (state.tokens > 0) state.tokens -= 1;
    if (state.suppressed == 0) state.over_budget_since_ms = null;
    const event = try renderEvent(allocator, state, lines.items);
    state.events_delivered +|= count;
    return .{ .consumed = consumed, .event = event };
}

fn completeLength(chunk: []const u8, mode: Mode) usize {
    if (mode == .final) return chunk.len;
    if (std.mem.lastIndexOfScalar(u8, chunk, '\n')) |at| return at + 1;
    if (chunk.len >= READ_MAX_BYTES) return chunk.len;
    return 0;
}

fn renderEvent(allocator: std.mem.Allocator, state: *State, lines: []const []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var first = true;
    if (state.suppressed > 0) {
        try out.writer.print("[{d} events suppressed — output rate too high]", .{state.suppressed});
        first = false;
    }
    for (lines) |line| {
        if (!first) try out.writer.writeByte('\n');
        first = false;
        try out.writer.writeAll(line[0..utf8.prefixEnd(line, LINE_MAX_BYTES)]);
    }
    const written = out.written();
    const kept = utf8.prefixEnd(written, EVENT_MAX_BYTES);
    out.shrinkRetainingCapacity(kept);
    state.suppressed = 0;
    return try out.toOwnedSlice();
}

const testing = std.testing;

fn testState() State {
    return State.init("watch", DEFAULT_TIMEOUT_MS, 0);
}

test "monitor stream keeps a trailing partial line for the next poll and drops empty lines" {
    var state = testState();
    const first = try take(testing.allocator, &state, "one\n\r\n\ntwo\r\nthr", .streaming, 0);
    defer testing.allocator.free(first.event);
    try testing.expectEqualStrings("one\ntwo", first.event);
    try testing.expectEqual(@as(usize, "one\n\r\n\ntwo\r\n".len), first.consumed);
    const rest = try take(testing.allocator, &state, "three\n", .streaming, 0);
    defer testing.allocator.free(rest.event);
    try testing.expectEqualStrings("three", rest.event);
    try testing.expectEqual(@as(u32, 3), state.events_delivered);
}

test "monitor stream flushes the partial line when the stream is final" {
    var state = testState();
    const waiting = try take(testing.allocator, &state, "tail", .streaming, 0);
    try testing.expectEqual(@as(usize, 0), waiting.consumed);
    try testing.expectEqual(@as(usize, 0), waiting.event.len);
    const final = try take(testing.allocator, &state, "tail", .final, 0);
    defer testing.allocator.free(final.event);
    try testing.expectEqualStrings("tail", final.event);
    try testing.expectEqual(@as(usize, 4), final.consumed);
}

test "monitor stream truncates lines and events without splitting UTF-8" {
    var state = testState();
    var chunk = std.ArrayList(u8).empty;
    defer chunk.deinit(testing.allocator);
    try chunk.append(testing.allocator, 'x');
    for (0..300) |_| try chunk.appendSlice(testing.allocator, "中");
    try chunk.append(testing.allocator, '\n');
    const batch = try take(testing.allocator, &state, chunk.items, .streaming, 0);
    defer testing.allocator.free(batch.event);
    try testing.expectEqual(@as(usize, 499), batch.event.len);
    try testing.expect(std.unicode.utf8ValidateSlice(batch.event));

    var many = std.ArrayList(u8).empty;
    defer many.deinit(testing.allocator);
    for (0..20) |_| {
        for (0..400) |_| try many.append(testing.allocator, 'a');
        try many.append(testing.allocator, '\n');
    }
    const big = try take(testing.allocator, &state, many.items, .streaming, 0);
    defer testing.allocator.free(big.event);
    try testing.expectEqual(EVENT_MAX_BYTES, big.event.len);
}

test "monitor stream token bucket suppresses batches and reports the count later" {
    var state = testState();
    for (0..BUCKET_CAPACITY) |_| {
        const batch = try take(testing.allocator, &state, "tick\n", .streaming, 0);
        testing.allocator.free(batch.event);
    }
    const dropped = try take(testing.allocator, &state, "a\nb\nc\n", .streaming, 100);
    try testing.expectEqual(@as(usize, 0), dropped.event.len);
    try testing.expectEqual(@as(u32, 3), state.suppressed);
    try testing.expectEqual(@as(?util_time.Millis, 100), state.over_budget_since_ms);
    const after = try take(testing.allocator, &state, "d\n", .streaming, REFILL_MS);
    defer testing.allocator.free(after.event);
    try testing.expectEqualStrings("[3 events suppressed — output rate too high]\nd", after.event);
    try testing.expectEqual(@as(u32, 0), state.suppressed);
    try testing.expectEqual(@as(?util_time.Millis, 100), state.over_budget_since_ms);
}

test "monitor stream stops a source that stays over budget and forgives one that quiets down" {
    var state = testState();
    state.tokens = 0;
    var now: util_time.Millis = 0;
    while (now < OVER_BUDGET_STOP_MS) : (now += 200) {
        const batch = try take(testing.allocator, &state, "spam\n", .streaming, now);
        testing.allocator.free(batch.event);
    }
    try testing.expectEqual(@as(?Stop, .too_much_output), state.overdue(0, now));

    var calm = testState();
    calm.tokens = 0;
    const dropped = try take(testing.allocator, &calm, "spam\n", .streaming, 0);
    try testing.expectEqual(@as(usize, 0), dropped.event.len);
    const quiet = try take(testing.allocator, &calm, "", .streaming, 200);
    try testing.expectEqual(@as(usize, 0), quiet.event.len);
    try testing.expectEqual(@as(?Stop, null), calm.overdue(0, OVER_BUDGET_STOP_MS + 1_000));
}

test "monitor stream final batch bypasses the bucket and reports leftover suppression" {
    var state = testState();
    state.tokens = 0;
    state.suppressed = 4;
    const final = try take(testing.allocator, &state, "", .final, 0);
    defer testing.allocator.free(final.event);
    try testing.expectEqualStrings("[4 events suppressed — output rate too high]", final.event);
}

test "monitor stream expiry follows the timeout and persistent monitors never expire" {
    const state = State.init("watch", 1_000, 0);
    try testing.expectEqual(@as(?Stop, null), state.overdue(500, 1_499));
    try testing.expectEqual(@as(?Stop, .expired), state.overdue(500, 1_500));
    const persistent = State.init("watch", null, 0);
    try testing.expectEqual(@as(?Stop, null), persistent.overdue(0, std.math.maxInt(i32)));
    try testing.expectEqual(DEFAULT_TIMEOUT_MS, clampTimeout(null));
    try testing.expectEqual(MIN_TIMEOUT_MS, clampTimeout(1));
    try testing.expectEqual(MAX_TIMEOUT_MS, clampTimeout(99_999_999));
}
