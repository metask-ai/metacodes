const std = @import("std");
const builtin = @import("builtin");
const ReasoningEffort = @import("metacodes-internal").types.ReasoningEffort;
const ModelOffer = @import("metacodes-internal").provider.offer.ModelOffer;
const pfs = @import("metacodes-internal").platform.fs;
const max_handed_key_bytes = @import("metacodes-internal").swarm.teammate_process.max_handed_key_bytes;

pub const Route = struct {
    provider: ?[]const u8 = null,
    channel: ?[]const u8 = null,
    model: []const u8 = "",
    reasoning_effort: ?ReasoningEffort = null,
    base_url: ?[]const u8 = null,

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
    if (route.base_url) |url| {
        if (url.len > 0) try appendPair(out, arena, "--base-url", url);
    }
}

fn appendPair(out: *std.ArrayList([]const u8), arena: std.mem.Allocator, flag: []const u8, value: []const u8) error{OutOfMemory}!void {
    try out.appendSlice(arena, &.{ flag, try arena.dupe(u8, value) });
}

pub const HandedKeyError = error{ InvalidHandedKeyFd, HandedKeyReadFailed, HandedKeyTooLong, MissingHandedKey, OutOfMemory };

pub fn takeHandedKey(allocator: std.mem.Allocator, fd: c_int) HandedKeyError![]u8 {
    if (fd < 3) return error.InvalidHandedKeyFd;
    defer pfs.close(fd);
    var bytes: [max_handed_key_bytes + 1]u8 = undefined;
    defer std.crypto.secureZero(u8, &bytes);
    var len: usize = 0;
    while (len < bytes.len) {
        const n = pfs.read(fd, bytes[len..]);
        if (n < 0) {
            if (pfs.lastErrnoIs(.INTR)) continue;
            return error.HandedKeyReadFailed;
        }
        if (n == 0) break;
        len += @intCast(n);
    }
    if (len > max_handed_key_bytes) return error.HandedKeyTooLong;
    if (len == 0) return error.MissingHandedKey;
    return allocator.dupe(u8, bytes[0..len]);
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

test "the endpoint the lead was started with on the command line goes to the teammate as --base-url" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const args = try argsOf(arena_state.allocator(), .{ .model = "a-model", .base_url = "http://127.0.0.1:9/v1" });
    const expected = [_][]const u8{ "--model", "a-model", "--base-url", "http://127.0.0.1:9/v1" };
    try testing.expectEqual(expected.len, args.len);
    for (expected, args) |want, got| try testing.expectEqualStrings(want, got);
    try testing.expectEqual(@as(usize, 2), (try argsOf(arena_state.allocator(), .{ .model = "a-model", .base_url = "" })).len);
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

fn pipeHolding(bytes: []const u8) ![2]c_int {
    var fds: [2]c_int = undefined;
    if (std.c.pipe(&fds) != 0) return error.PipeFailed;
    defer _ = std.c.close(fds[1]);
    var rest = bytes;
    while (rest.len > 0) {
        const n = std.c.write(fds[1], rest.ptr, rest.len);
        if (n <= 0) return error.PipeFailed;
        rest = rest[@intCast(n)..];
    }
    return fds;
}

fn isOpen(fd: c_int) bool {
    return std.c.fcntl(fd, std.c.F.GETFD) >= 0;
}

test "takeHandedKey: the key its descriptor holds, with the descriptor closed once it is read" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const fds = try pipeHolding("sk-handed-key");
    const key = try takeHandedKey(testing.allocator, fds[0]);
    defer testing.allocator.free(key);
    try testing.expect(!isOpen(fds[0]));
    try testing.expectEqualStrings("sk-handed-key", key);
}

test "takeHandedKey: an empty or oversized descriptor is refused and still closed, and stdio is never taken" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const empty = try pipeHolding("");
    try testing.expectError(error.MissingHandedKey, takeHandedKey(testing.allocator, empty[0]));
    try testing.expect(!isOpen(empty[0]));
    const long = [_]u8{'k'} ** (max_handed_key_bytes + 1);
    const oversized = try pipeHolding(&long);
    try testing.expectError(error.HandedKeyTooLong, takeHandedKey(testing.allocator, oversized[0]));
    try testing.expect(!isOpen(oversized[0]));
    try testing.expectError(error.InvalidHandedKeyFd, takeHandedKey(testing.allocator, 2));
    try testing.expect(isOpen(2));
}
