const std = @import("std");
const ReasoningEffort = @import("metacodes-internal").types.ReasoningEffort;
const ModelOffer = @import("metacodes-internal").provider.offer.ModelOffer;

pub const Route = struct {
    provider: ?[]const u8 = null,
    channel: ?[]const u8 = null,
    model: []const u8 = "",
    reasoning_effort: ?ReasoningEffort = null,

    pub fn ofOffer(offer: *const ModelOffer, reasoning_effort: ?ReasoningEffort) Route {
        return .{
            .provider = offer.provider_id.slice(),
            .channel = offer.channel_id.slice(),
            .model = offer.request_model_id,
            .reasoning_effort = reasoning_effort,
        };
    }
};

pub fn appendArgs(out: *std.ArrayList([]const u8), arena: std.mem.Allocator, route: Route) error{OutOfMemory}!void {
    if (route.provider) |provider| {
        if (provider.len > 0) try appendPair(out, arena, "--provider", provider);
    }
    if (route.channel) |channel| {
        if (channel.len > 0) try appendPair(out, arena, "--channel", channel);
    }
    if (route.model.len > 0) try appendPair(out, arena, "--model", route.model);
    if (route.reasoning_effort) |level| try appendPair(out, arena, "--reasoning-effort", level.name());
}

fn appendPair(out: *std.ArrayList([]const u8), arena: std.mem.Allocator, flag: []const u8, value: []const u8) error{OutOfMemory}!void {
    try out.appendSlice(arena, &.{ flag, try arena.dupe(u8, value) });
}

const testing = std.testing;

fn argsOf(arena: std.mem.Allocator, route: Route) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    try appendArgs(&out, arena, route);
    return out.items;
}

test "a route on a provider's channel becomes the flags a start names it with, effort included" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const args = try argsOf(arena_state.allocator(), .{ .provider = "prov-a", .channel = "primary", .model = "a-model", .reasoning_effort = .high });
    const expected = [_][]const u8{ "--provider", "prov-a", "--channel", "primary", "--model", "a-model", "--reasoning-effort", "high" };
    try testing.expectEqual(expected.len, args.len);
    for (expected, args) |want, got| try testing.expectEqualStrings(want, got);
}

test "what a route does not name is left out, and values are copies the caller's arena owns" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var model = "m-1".*;
    const args = try argsOf(arena_state.allocator(), .{ .provider = "", .model = &model });
    try testing.expectEqual(@as(usize, 2), args.len);
    try testing.expectEqualStrings("--model", args[0]);
    model[0] = 'x';
    try testing.expectEqualStrings("m-1", args[1]);
    try testing.expectEqual(@as(usize, 0), (try argsOf(arena_state.allocator(), .{})).len);
}
