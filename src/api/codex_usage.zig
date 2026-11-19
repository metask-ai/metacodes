//! The Codex backend's usage refusals (`chatgpt-codex`, plan appendix B §6).
//!
//! A ChatGPT plan's Codex quota is a window that opens again at a stated time.
//! When it is used up the backend answers 429 with
//! `{"error":{"type":"usage_limit_reached","plan_type":…,"resets_at":<unix s>}}`,
//! and a plan without Codex at all answers 429 with `"type":"usage_not_included"`
//! (as the Codex CLI reads them, `codex-rs/codex-api/src/api_bridge.rs`).
//! Neither is a burst limit: a retry a few seconds later only spends attempts.
//! The user needs to know when the window opens, or that it never will on
//! this plan.
//!
//! The text goes where every failed request's does: the TUI's failure line
//! (`last_error.zig`), and the Run's failure detail (`model_error.zig`), whose
//! `retry_after_ms` carries the wait the way a `Retry-After` header would.

const std = @import("std");
const time_context = @import("../core/time_context.zig");

pub const Refusal = union(enum) {
    /// The plan's Codex quota is used up. `resets_at` is when it opens again
    /// (unix seconds), when the server said.
    limit_reached: LimitReached,
    /// The plan does not include Codex.
    not_included,

    pub const LimitReached = struct {
        resets_at: ?i64 = null,
    };
};

/// The latest reset time taken from a server: 9999-12-31 23:59:59 UTC. A
/// window opens again hours or days on, so a later time is not one the
/// server meant: `resetTime` reads it as none, and the failure line says the
/// server did not say when. Inside the bound, the time plus any zone offset
/// stays far inside i64 seconds and an i32 year, which
/// `time_context.localDate` needs.
const latest_reset: i64 = 253_402_300_799;

/// `seconds` when it is a reset time to say and wait for: after 1970 and no
/// later than `latest_reset`. Null otherwise.
fn resetTime(seconds: ?i64) ?i64 {
    const at = seconds orelse return null;
    return if (at > 0 and at <= latest_reset) at else null;
}

/// The refusal a Codex backend answer is, or null for any other failure.
pub fn parse(scratch: std.mem.Allocator, status: u16, body: []const u8) ?Refusal {
    if (status != 429) return null;
    const root = std.json.parseFromSliceLeaky(std.json.Value, scratch, body, .{}) catch return null;
    if (root != .object) return null;
    const err = root.object.get("error") orelse return null;
    if (err != .object) return null;
    const kind = stringField(err.object, "type") orelse stringField(err.object, "code") orelse return null;
    if (std.mem.eql(u8, kind, "usage_not_included")) return .not_included;
    if (!std.mem.eql(u8, kind, "usage_limit_reached")) return null;
    const resets_at: ?i64 = if (err.object.get("resets_at")) |value| switch (value) {
        .integer => |seconds| resetTime(seconds),
        else => null,
    } else null;
    return .{ .limit_reached = .{ .resets_at = resets_at } };
}

/// Milliseconds until the window opens, from `now_unix`; null when the server
/// named no time, one already past, or one `resetTime` does not take. Null is
/// no wait known, not a wait of zero: the caller passes nothing on.
pub fn waitMs(refusal: Refusal, now_unix: i64) ?u64 {
    const limit = switch (refusal) {
        .limit_reached => |value| value,
        .not_included => return null,
    };
    const at = resetTime(limit.resets_at) orelse return null;
    if (at <= now_unix) return null;
    // Too long for u64 milliseconds only on a clock hundreds of millions of
    // years off; such a wait is not known either.
    return std.math.mul(u64, secondsUntil(at, now_unix), std.time.ms_per_s) catch null;
}

/// Seconds from `now_unix` until `at`, 0 when `at` is not later. Two i64
/// times are less than 2^64 seconds apart, so the difference is a u64.
fn secondsUntil(at: i64, now_unix: i64) u64 {
    if (at <= now_unix) return 0;
    return @intCast(@as(i128, at) - now_unix);
}

/// The failure line's two parts (`last_error.recordNamed`).
pub const Summary = struct {
    kind: []const u8,
    detail: []const u8,
};

/// The failure in words, the reset time in the zone `offset_minutes` east of
/// UTC. `buffer` holds the detail.
pub fn summarize(refusal: Refusal, now_unix: i64, offset_minutes: i32, buffer: []u8) Summary {
    switch (refusal) {
        .not_included => return .{
            .kind = "ChatGPT plan",
            .detail = "this ChatGPT plan does not include Codex",
        },
        .limit_reached => |limit| {
            const kind = "ChatGPT usage limit";
            const at = resetTime(limit.resets_at) orelse
                return .{ .kind = kind, .detail = "the plan's Codex quota is used up; the server did not say when it resets" };
            var wait_buffer: [64]u8 = undefined;
            const wait = waitText(&wait_buffer, secondsUntil(at, now_unix));
            var offset_buffer: [9]u8 = undefined;
            // `at` is no later than `latest_reset`: no zone offset takes the
            // local time out of range.
            const date = time_context.localDate(at, offset_minutes);
            const local = at + @as(i64, offset_minutes) * 60;
            const minute_of_day: u64 = @intCast(@mod(@divFloor(local, 60), 24 * 60));
            const detail = std.fmt.bufPrint(buffer, "the plan's Codex quota is used up; it resets at {d}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2} ({s}), {s}", .{
                date.year,
                date.month,
                date.day,
                minute_of_day / 60,
                minute_of_day % 60,
                time_context.formatOffset(&offset_buffer, offset_minutes),
                wait,
            }) catch "the plan's Codex quota is used up";
            return .{ .kind = kind, .detail = detail };
        },
    }
}

/// `in about 2 h 5 min`, `in about 45 min`, `in under a minute`.
pub fn waitText(buffer: []u8, seconds: u64) []const u8 {
    if (seconds < 60) return "in under a minute";
    // Rounded up; `(seconds + 59) / 60` would overflow near the u64 limit.
    const minutes = seconds / 60 + @intFromBool(seconds % 60 != 0);
    if (minutes < 60) return std.fmt.bufPrint(buffer, "in about {d} min", .{minutes}) catch "later";
    const hours = minutes / 60;
    const rest = minutes % 60;
    if (rest == 0) return std.fmt.bufPrint(buffer, "in about {d} h", .{hours}) catch "later";
    return std.fmt.bufPrint(buffer, "in about {d} h {d} min", .{ hours, rest }) catch "later";
}

fn stringField(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    return switch (value) {
        .string => |text| if (text.len == 0) null else text,
        else => null,
    };
}

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "a used-up plan and a plan without Codex are told apart from other 429s" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const limit = parse(arena, 429, "{\"error\":{\"type\":\"usage_limit_reached\",\"message\":\"The usage limit has been reached\",\"plan_type\":\"plus\",\"resets_at\":1795000000}}").?;
    try testing.expectEqual(@as(i64, 1795000000), limit.limit_reached.resets_at.?);
    try testing.expect(parse(arena, 429, "{\"error\":{\"type\":\"usage_not_included\"}}").? == .not_included);
    // Without a time it is still the plan's limit.
    try testing.expect(parse(arena, 429, "{\"error\":{\"type\":\"usage_limit_reached\"}}").?.limit_reached.resets_at == null);
    // A burst limit, another status, or no JSON is not one of these.
    try testing.expect(parse(arena, 429, "{\"error\":{\"type\":\"rate_limit_exceeded\"}}") == null);
    try testing.expect(parse(arena, 403, "{\"error\":{\"type\":\"usage_limit_reached\"}}") == null);
    try testing.expect(parse(arena, 429, "Too Many Requests") == null);
}

test "the reset time is said in the local zone, with the wait" {
    var buffer: [256]u8 = undefined;
    // 2026-11-17 13:30 UTC is 21:30 at UTC+08:00, two hours and five minutes on.
    const resets_at: i64 = 1_794_922_200;
    const summary = summarize(.{ .limit_reached = .{ .resets_at = resets_at } }, resets_at - (2 * 3600 + 5 * 60), 8 * 60, &buffer);
    try testing.expectEqualStrings("ChatGPT usage limit", summary.kind);
    try testing.expectEqualStrings("the plan's Codex quota is used up; it resets at 2026-11-17 21:30 (UTC+08:00), in about 2 h 5 min", summary.detail);
    try testing.expectEqual(@as(?u64, (2 * 3600 + 5 * 60) * 1000), waitMs(.{ .limit_reached = .{ .resets_at = resets_at } }, resets_at - (2 * 3600 + 5 * 60)));
    try testing.expect(waitMs(.{ .limit_reached = .{ .resets_at = resets_at } }, resets_at + 1) == null);
    try testing.expect(waitMs(.not_included, 0) == null);
    try testing.expectEqualStrings("this ChatGPT plan does not include Codex", summarize(.not_included, 0, 0, &buffer).detail);
}

test "the wait reads in minutes, then hours and minutes" {
    var buffer: [64]u8 = undefined;
    try testing.expectEqualStrings("in under a minute", waitText(&buffer, 30));
    try testing.expectEqualStrings("in about 45 min", waitText(&buffer, 45 * 60));
    try testing.expectEqualStrings("in about 1 h", waitText(&buffer, 3600));
    try testing.expectEqualStrings("in about 5 h 1 min", waitText(&buffer, 5 * 3600 + 30));
}

const unknown_reset = "the plan's Codex quota is used up; the server did not say when it resets";

test "a reset time near the i64 limit is no wait, not an overflow" {
    const now: i64 = 1_700_000_000;
    try testing.expect(waitMs(.{ .limit_reached = .{ .resets_at = std.math.maxInt(i64) } }, now) == null);
    try testing.expect(waitMs(.{ .limit_reached = .{ .resets_at = std.math.minInt(i64) } }, now) == null);
    // From the wire it is no time at all, and past i64 it never was one.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expect(parse(arena, 429, "{\"error\":{\"type\":\"usage_limit_reached\",\"resets_at\":9223372036854775807}}").?.limit_reached.resets_at == null);
    try testing.expect(parse(arena, 429, "{\"error\":{\"type\":\"usage_limit_reached\",\"resets_at\":9223372036854775808}}").?.limit_reached.resets_at == null);
}

test "a reset time near the i64 limit is said as unknown east of UTC" {
    var buffer: [256]u8 = undefined;
    for ([_]i32{ 8 * 60, 14 * 60 }) |offset| {
        const summary = summarize(.{ .limit_reached = .{ .resets_at = std.math.maxInt(i64) } }, 1_700_000_000, offset, &buffer);
        try testing.expectEqualStrings("ChatGPT usage limit", summary.kind);
        try testing.expectEqualStrings(unknown_reset, summary.detail);
    }
}

test "a reset time near the i64 limit is said as unknown in UTC and west of it" {
    var buffer: [256]u8 = undefined;
    for ([_]i64{ std.math.maxInt(i64), std.math.minInt(i64) }) |resets_at| {
        for ([_]i32{ 0, -12 * 60 }) |offset| {
            try testing.expectEqualStrings(unknown_reset, summarize(.{ .limit_reached = .{ .resets_at = resets_at } }, 1_700_000_000, offset, &buffer).detail);
        }
    }
}

test "the last second of 9999 is the latest reset time taken" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var buffer: [256]u8 = undefined;
    const now: i64 = 1_700_000_000;
    const last: Refusal = .{ .limit_reached = .{ .resets_at = 253_402_300_799 } }; // 9999-12-31 23:59:59 UTC
    try testing.expectEqual(@as(?i64, 253_402_300_799), parse(arena, 429, "{\"error\":{\"type\":\"usage_limit_reached\",\"resets_at\":253402300799}}").?.limit_reached.resets_at);
    try testing.expectEqual(@as(?u64, 251_702_300_799_000), waitMs(last, now));
    try testing.expectEqualStrings("the plan's Codex quota is used up; it resets at 9999-12-31 23:59 (UTC+00:00), in about 69917305 h 47 min", summarize(last, now, 0, &buffer).detail);
    // East of UTC the local time is already in the year 10000.
    try testing.expectEqualStrings("the plan's Codex quota is used up; it resets at 10000-01-01 13:59 (UTC+14:00), in about 69917305 h 47 min", summarize(last, now, 14 * 60, &buffer).detail);
    // A second later is no time at all.
    const later: Refusal = .{ .limit_reached = .{ .resets_at = 253_402_300_800 } };
    try testing.expect(parse(arena, 429, "{\"error\":{\"type\":\"usage_limit_reached\",\"resets_at\":253402300800}}").?.limit_reached.resets_at == null);
    try testing.expect(waitMs(later, now) == null);
    try testing.expectEqualStrings(unknown_reset, summarize(later, now, 14 * 60, &buffer).detail);
}

test "a wait too long for u64 milliseconds is no wait, not an overflow" {
    var buffer: [256]u8 = undefined;
    // 2001-09-09 01:46:40 UTC, read on clocks far behind it.
    const at: i64 = 1_000_000_000;
    const longest: i64 = std.math.maxInt(u64) / std.time.ms_per_s; // whole seconds that fit
    try testing.expectEqual(@as(?u64, 18_446_744_073_709_551_000), waitMs(.{ .limit_reached = .{ .resets_at = at } }, at - longest));
    try testing.expect(waitMs(.{ .limit_reached = .{ .resets_at = at } }, at - longest - 1) == null);
    // Further apart than any i64 difference.
    const last: Refusal = .{ .limit_reached = .{ .resets_at = 253_402_300_799 } };
    try testing.expect(waitMs(last, std.math.minInt(i64)) == null);
    try testing.expectEqualStrings("the plan's Codex quota is used up; it resets at 9999-12-31 23:59 (UTC+00:00), in about 2562047858404743 h 31 min", summarize(last, std.math.minInt(i64), 0, &buffer).detail);
}

test "the wait text holds any u64 of seconds" {
    var buffer: [64]u8 = undefined;
    try testing.expectEqualStrings("in about 5124095576030431 h 1 min", waitText(&buffer, std.math.maxInt(u64)));
}

test "a reset time already past, or none, reads as before" {
    var buffer: [256]u8 = undefined;
    const resets_at: i64 = 1_794_922_200; // 2026-11-17 13:30 UTC
    const past: Refusal = .{ .limit_reached = .{ .resets_at = resets_at } };
    try testing.expect(waitMs(past, resets_at + 3600) == null);
    try testing.expectEqualStrings("the plan's Codex quota is used up; it resets at 2026-11-17 21:30 (UTC+08:00), in under a minute", summarize(past, resets_at + 3600, 8 * 60, &buffer).detail);
    const none: Refusal = .{ .limit_reached = .{} };
    try testing.expect(waitMs(none, resets_at) == null);
    try testing.expectEqualStrings(unknown_reset, summarize(none, resets_at, 8 * 60, &buffer).detail);
}
