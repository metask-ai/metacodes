//! The goal checkpoint section (#277): the Session's goal, so a restored
//! Session keeps working toward it with the usage already charged.
//!
//! Layout, little-endian: magic (8), status (u8: the `goal.Status` index),
//! flags (u8: bit 0 = has a token budget), reserved zero (2 bytes), objective
//! length (u32), id (24), token budget (u64, zero without one), tokens used
//! (u64), time used ms (u64), created at ms (i64), updated at ms (i64), then
//! the objective. Every field but the objective is fixed-width, so charging
//! a goal during a Run never changes the section's size: only `set` and an
//! objective edit do, and those are admitted against the durable budget while
//! the Session is idle. A Session without a goal has no section (empty bytes).

const std = @import("std");
const core = @import("metacodes-core");
const goal_mod = core.goal;

const magic = "R23GOAL\x00";
pub const fixed_bytes = magic.len + 1 + 1 + 2 + 4 + 24 + 8 * 5;
const flag_has_budget: u8 = 1 << 0;

pub const DecodeError = error{ OutOfMemory, Corrupt };

/// The section's size for a goal with `objective`, without encoding it.
pub fn encodedLen(objective: []const u8) usize {
    return fixed_bytes + objective.len;
}

/// Empty without a goal.
pub fn encode(allocator: std.mem.Allocator, goal: ?*const goal_mod.Goal) ![]u8 {
    const g = goal orelse return allocator.alloc(u8, 0);
    const out = try allocator.alloc(u8, encodedLen(g.objective));
    @memcpy(out[0..magic.len], magic);
    var at: usize = magic.len;
    out[at] = @intCast(@intFromEnum(g.status));
    out[at + 1] = if (g.token_budget != null) flag_has_budget else 0;
    out[at + 2] = 0;
    out[at + 3] = 0;
    at += 4;
    std.mem.writeInt(u32, out[at..][0..4], @intCast(g.objective.len), .little);
    at += 4;
    @memcpy(out[at..][0..24], &g.id);
    at += 24;
    std.mem.writeInt(u64, out[at..][0..8], g.token_budget orelse 0, .little);
    std.mem.writeInt(u64, out[at + 8 ..][0..8], g.tokens_used, .little);
    std.mem.writeInt(u64, out[at + 16 ..][0..8], g.time_used_ms, .little);
    std.mem.writeInt(i64, out[at + 24 ..][0..8], g.created_at_ms, .little);
    std.mem.writeInt(i64, out[at + 32 ..][0..8], g.updated_at_ms, .little);
    at += 40;
    @memcpy(out[at..], g.objective);
    return out;
}

/// Null for an empty section. A non-empty one must be a goal `encode` could
/// have written: a known status, a budget flag that agrees with the budget,
/// a valid id, and an objective already in its stored form.
pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) DecodeError!?goal_mod.Goal {
    if (bytes.len == 0) return null;
    if (bytes.len < fixed_bytes or !std.mem.eql(u8, bytes[0..magic.len], magic)) return error.Corrupt;
    var at: usize = magic.len;
    const status_index = bytes[at];
    const flags = bytes[at + 1];
    if (bytes[at + 2] != 0 or bytes[at + 3] != 0 or (flags & ~flag_has_budget) != 0) return error.Corrupt;
    if (status_index >= @typeInfo(goal_mod.Status).@"enum".fields.len) return error.Corrupt;
    at += 4;
    const objective_len = std.mem.readInt(u32, bytes[at..][0..4], .little);
    at += 4;
    if (bytes.len != fixed_bytes + @as(usize, objective_len)) return error.Corrupt;
    const id = bytes[at..][0..24];
    if (core.session_id.SessionId.fromSlice(id) == null) return error.Corrupt;
    at += 24;
    const token_budget = std.mem.readInt(u64, bytes[at..][0..8], .little);
    if ((token_budget != 0) != ((flags & flag_has_budget) != 0)) return error.Corrupt;
    const tokens_used = std.mem.readInt(u64, bytes[at + 8 ..][0..8], .little);
    const time_used_ms = std.mem.readInt(u64, bytes[at + 16 ..][0..8], .little);
    const created_at_ms = std.mem.readInt(i64, bytes[at + 24 ..][0..8], .little);
    const updated_at_ms = std.mem.readInt(i64, bytes[at + 32 ..][0..8], .little);
    at += 40;
    const stored = bytes[at..];
    const normalized = goal_mod.normalizeObjective(stored) catch return error.Corrupt;
    if (normalized.len != stored.len) return error.Corrupt;
    return .{
        .id = id.*,
        .objective = try allocator.dupe(u8, stored),
        .status = @enumFromInt(status_index),
        .token_budget = if (token_budget == 0) null else token_budget,
        .tokens_used = tokens_used,
        .time_used_ms = time_used_ms,
        .created_at_ms = created_at_ms,
        .updated_at_ms = updated_at_ms,
    };
}

test "a goal round-trips, and the section keeps its size while it is charged" {
    const a = std.testing.allocator;
    var state = goal_mod.State.init(a);
    defer state.deinit();
    try std.testing.expectEqual(@as(usize, 0), (try encode(a, null)).len);
    try std.testing.expect((try decode(a, "")) == null);

    try state.setNew("ship the \u{4e2d} release", 500);
    const first = try encode(a, &state.current.?);
    defer a.free(first);
    try std.testing.expectEqual(encodedLen(state.current.?.objective), first.len);
    var meter = goal_mod.Meter.init(&state);
    meter.beginRun();
    _ = meter.charge(1_000_000, 7);
    _ = meter.endRun();
    const second = try encode(a, &state.current.?);
    defer a.free(second);
    try std.testing.expectEqual(first.len, second.len);

    var decoded = (try decode(a, second)).?;
    defer decoded.deinit(a);
    try std.testing.expectEqualStrings(state.current.?.objective, decoded.objective);
    try std.testing.expectEqualStrings(&state.current.?.id, &decoded.id);
    try std.testing.expectEqual(goal_mod.Status.budget_limited, decoded.status);
    try std.testing.expectEqual(@as(?u64, 500), decoded.token_budget);
    try std.testing.expectEqual(@as(u64, 1_000_007), decoded.tokens_used);
    try std.testing.expectEqual(state.current.?.updated_at_ms, decoded.updated_at_ms);
}

test "decode refuses a section encode never writes" {
    const a = std.testing.allocator;
    var state = goal_mod.State.init(a);
    defer state.deinit();
    try state.setNew("ship it", null);
    const good = try encode(a, &state.current.?);
    defer a.free(good);
    const bad = try a.dupe(u8, good);
    defer a.free(bad);

    const Mutation = struct { offset: usize, byte: u8 };
    for ([_]Mutation{
        .{ .offset = 0, .byte = 'X' }, // magic
        .{ .offset = magic.len, .byte = 6 }, // status past `complete`
        .{ .offset = magic.len + 1, .byte = 2 }, // unknown flag
        .{ .offset = magic.len + 1, .byte = flag_has_budget }, // flag without a budget
        .{ .offset = magic.len + 2, .byte = 1 }, // reserved
        .{ .offset = magic.len + 4, .byte = 99 }, // objective length
        .{ .offset = magic.len + 8, .byte = '!' }, // id
        .{ .offset = fixed_bytes, .byte = ' ' }, // objective not in stored form
    }) |mutation| {
        @memcpy(bad, good);
        bad[mutation.offset] = mutation.byte;
        try std.testing.expectError(error.Corrupt, decode(a, bad));
    }
    try std.testing.expectError(error.Corrupt, decode(a, good[0 .. good.len - 1]));
    var decoded = (try decode(a, good)).?;
    decoded.deinit(a);
}
