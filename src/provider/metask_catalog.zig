//! Parser for the Metask `/v1/models` response.
//!
//! The gateway intentionally leaves some limits/capabilities out for models
//! that cannot state them.  This parser preserves that distinction as null /
//! `offer.Tri.unknown` instead of inventing conservative-but-wrong support.

const std = @import("std");
const offer = @import("offer.zig");

pub const Model = struct {
    id: []const u8,
    display_name: []const u8,
    max_input_tokens: ?u32,
    max_tokens: ?u32,
    reasoning: offer.Tri,
    vision: offer.Tri,
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
        const display = jsonString(item.object.get("display_name")) orelse id;
        try result.models.append(arena, .{
            .id = id,
            .display_name = display,
            .max_input_tokens = positiveU32(item.object.get("max_input_tokens")),
            .max_tokens = positiveU32(item.object.get("max_tokens")),
            .reasoning = capability(item, "thinking"),
            .vision = capability(item, "image_input"),
        });
    }
    return result;
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
