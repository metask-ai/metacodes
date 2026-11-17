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
        .integer => |seconds| if (seconds > 0) seconds else null,
        else => null,
    } else null;
    return .{ .limit_reached = .{ .resets_at = resets_at } };
}

/// Milliseconds until the window opens, from `now_unix`; null when the server
/// named no time or one already past.
pub fn waitMs(refusal: Refusal, now_unix: i64) ?u64 {
    const limit = switch (refusal) {
        .limit_reached => |value| value,
        .not_included => return null,
    };
    const at = limit.resets_at orelse return null;
    if (at <= now_unix) return null;
    return @as(u64, @intCast(at - now_unix)) * std.time.ms_per_s;
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
            const at = limit.resets_at orelse
                return .{ .kind = kind, .detail = "the plan's Codex quota is used up; the server did not say when it resets" };
            var wait_buffer: [64]u8 = undefined;
            const wait = waitText(&wait_buffer, if (at > now_unix) @intCast(at - now_unix) else 0);
            var offset_buffer: [9]u8 = undefined;
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
    const minutes = (seconds + 59) / 60;
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
