//! Parser for the Metask `/v1/models` response.
//!
//! The gateway intentionally leaves some limits/capabilities out for models
//! that cannot state them.  This parser preserves that distinction as null /
//! `offer.Tri.unknown` instead of inventing conservative-but-wrong support.
//!
//! The gateway at `www.metask-ai.com` (#527) also lists image and video
//! models, and says per endpoint what each one serves
//! (`capabilities.endpoints.messages.supported`). A session runs on
//! `/v1/messages`, so a model that says it is not served there is left out:
//! picked, it would fail at its first turn. One that says nothing stays. The
//! levels a model reasons at are a list there
//! (`capabilities.reasoning.efforts`), read in the gateway's own words.

const std = @import("std");
const offer = @import("offer.zig");
const types = @import("../types.zig");

pub const Model = struct {
    id: []const u8,
    display_name: []const u8,
    max_input_tokens: ?u32,
    max_tokens: ?u32,
    reasoning: offer.Tri,
    vision: offer.Tri,
    /// The reasoning levels the gateway names for the model, in its own
    /// words and order (`low`, `medium`, `high`, `max`, …), with `none` first
    /// when thinking can be switched off. Only words metacodes can send
    /// (`types.ReasoningEffort.parse`); empty when it names none.
    efforts: []const []const u8 = &.{},
};

pub const Catalog = struct {
    arena: std.heap.ArenaAllocator,
    models: std.ArrayList(Model),

    pub fn deinit(self: *Catalog) void {
        self.models.deinit(self.arena.allocator());
        self.arena.deinit();
        self.* = undefined;
    }
};

pub fn parseModels(allocator: std.mem.Allocator, body: []const u8) !Catalog {
    var result = Catalog{ .arena = std.heap.ArenaAllocator.init(allocator), .models = .empty };
    errdefer result.deinit();
    const arena = result.arena.allocator();
    const root = std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{}) catch return error.InvalidJson;
    if (root != .object) return error.InvalidJson;
    const list = root.object.get("data") orelse return error.InvalidJson;
    if (list != .array) return error.InvalidJson;
    for (list.array.items) |item| {
        if (item != .object) continue;
        const id = jsonString(item.object.get("id")) orelse continue;
        if (messagesEndpoint(item) == .unsupported) continue;
        const display = jsonString(item.object.get("display_name")) orelse id;
        const thinking = capability(item, "thinking");
        try result.models.append(arena, .{
            .id = id,
            .display_name = display,
            .max_input_tokens = positiveU32(item.object.get("max_input_tokens")),
            .max_tokens = positiveU32(item.object.get("max_tokens")),
            .reasoning = if (thinking != .unknown) thinking else capability(item, "reasoning"),
            .vision = capability(item, "image_input"),
            .efforts = try reasoningEfforts(arena, item),
        });
    }
    return result;
}

/// `capabilities.endpoints.messages.supported`: whether the gateway serves
/// the model on `/v1/messages`.
fn messagesEndpoint(model: std.json.Value) offer.Tri {
    const caps = model.object.get("capabilities") orelse return .unknown;
    if (caps != .object) return .unknown;
    const endpoints = caps.object.get("endpoints") orelse return .unknown;
    if (endpoints != .object) return .unknown;
    const messages = endpoints.object.get("messages") orelse return .unknown;
    if (messages != .object) return .unknown;
    const supported = messages.object.get("supported") orelse return .unknown;
    return switch (supported) {
        .bool => |yes| if (yes) .supported else .unsupported,
        else => .unknown,
    };
}

/// `capabilities.reasoning.efforts`, kept in the gateway's words and order,
/// with `none` first when `reasoning.disable.supported` says thinking can be
/// switched off. A word metacodes cannot send is left out; a word named twice
/// is kept once.
fn reasoningEfforts(arena: std.mem.Allocator, model: std.json.Value) ![]const []const u8 {
    const caps = model.object.get("capabilities") orelse return &.{};
    if (caps != .object) return &.{};
    const reasoning = caps.object.get("reasoning") orelse return &.{};
    if (reasoning != .object) return &.{};
    const efforts = reasoning.object.get("efforts") orelse return &.{};
    if (efforts != .array) return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    if (reasoning.object.get("disable")) |disable| {
        if (disable == .object) if (disable.object.get("supported")) |yes| {
            if (yes == .bool and yes.bool) try out.append(arena, "none");
        };
    }
    for (efforts.array.items) |value| {
        const word = jsonString(value) orelse continue;
        const effort = types.ReasoningEffort.parse(word) orelse continue;
        if (effort == .none) continue; // `disable` decides that one
        const name = effort.name();
        const seen = for (out.items) |kept| {
            if (std.mem.eql(u8, kept, name)) break true;
        } else false;
        if (!seen) try out.append(arena, name);
    }
    return out.toOwnedSlice(arena);
}

fn jsonString(value: ?std.json.Value) ?[]const u8 {
    return switch (value orelse return null) {
        .string => |s| if (s.len > 0) s else null,
        else => null,
    };
}

fn positiveU32(value: ?std.json.Value) ?u32 {
    const n: i64 = switch (value orelse return null) {
        .integer => |v| v,
        else => return null,
    };
    if (n <= 0) return null;
    // The host limit type is u32; an out-of-range provider value is unknown,
    // not a license to silently clamp it to a made-up maximum.
    return std.math.cast(u32, n);
}

fn capability(model: std.json.Value, name: []const u8) offer.Tri {
    const caps = model.object.get("capabilities") orelse return .unknown;
    if (caps != .object) return .unknown;
    const cap = caps.object.get(name) orelse return .unknown;
    if (cap != .object) return .unknown;
    const supported = cap.object.get("supported") orelse return .unknown;
    return switch (supported) {
        .bool => |yes| if (yes) .supported else .unsupported,
        else => .unknown,
    };
}

test "Metask model catalog maps limits and capabilities without guessing unknowns" {
    var parsed = try parseModels(std.testing.allocator, "{\"object\":\"list\",\"data\":[{" ++
        "\"id\":\"m1\",\"display_name\":\"Model One\",\"max_input_tokens\":128000,\"max_tokens\":4096," ++
        "\"capabilities\":{\"thinking\":{\"supported\":true},\"image_input\":{\"supported\":false}}},{" ++
        "\"id\":\"m2\"}]}");
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed.models.items.len);
    try std.testing.expectEqualStrings("Model One", parsed.models.items[0].display_name);
    try std.testing.expectEqual(@as(?u32, 128000), parsed.models.items[0].max_input_tokens);
    try std.testing.expectEqual(offer.Tri.supported, parsed.models.items[0].reasoning);
    try std.testing.expectEqual(offer.Tri.unsupported, parsed.models.items[0].vision);
    try std.testing.expectEqual(offer.Tri.unknown, parsed.models.items[1].vision);
}

test "the www gateway's catalog: models it does not serve on /v1/messages are left out, levels read in its words" {
    var parsed = try parseModels(std.testing.allocator,
        \\{"object":"list","data":[
        \\ {"id":"glm-5.3","max_input_tokens":200000,"capabilities":{"endpoints":{"messages":{"supported":true},"chat_completions":{"supported":true}},
        \\   "reasoning":{"supported":true,"disable":{"supported":false},"efforts":["low","medium","high","max"],"translated":true}}},
        \\ {"id":"seedance-2.0","capabilities":{"endpoints":{"messages":{"supported":false},"videos":{"supported":true}},
        \\   "reasoning":{"supported":false,"efforts":[]}}},
        \\ {"id":"hy4","capabilities":{"endpoints":{"messages":{"supported":true}},
        \\   "reasoning":{"supported":true,"disable":{"supported":true},"efforts":["low","high","high","ultra"]}}},
        \\ {"id":"says-nothing"}
        \\]}
    );
    defer parsed.deinit();
    const models = parsed.models.items;
    // The video model is gone; the one that says nothing stays.
    try std.testing.expectEqual(@as(usize, 3), models.len);
    try std.testing.expectEqualStrings("glm-5.3", models[0].id);
    try std.testing.expectEqualStrings("hy4", models[1].id);
    try std.testing.expectEqualStrings("says-nothing", models[2].id);
    // `reasoning.supported`, without a `thinking` field.
    try std.testing.expectEqual(offer.Tri.supported, models[0].reasoning);
    try std.testing.expectEqual(@as(usize, 4), models[0].efforts.len);
    try std.testing.expectEqualStrings("low", models[0].efforts[0]);
    try std.testing.expectEqualStrings("max", models[0].efforts[3]);
    // `none` first when thinking can be switched off; a repeat and a word
    // metacodes cannot send are dropped.
    try std.testing.expectEqual(@as(usize, 3), models[1].efforts.len);
    try std.testing.expectEqualStrings("none", models[1].efforts[0]);
    try std.testing.expectEqualStrings("low", models[1].efforts[1]);
    try std.testing.expectEqualStrings("high", models[1].efforts[2]);
    try std.testing.expectEqual(offer.Tri.unknown, models[2].reasoning);
    try std.testing.expectEqual(@as(usize, 0), models[2].efforts.len);
}
