//! Order-preserving JSON object merge.
//!
//! Several independent writers own different parts of `<state root>/config.json`
//! (theme, MCP servers, permission rules, model tiers, and now the provider
//! control plane). A writer that serializes only the fields it knows about
//! silently deletes every other writer's data. This helper exists so a writer
//! can replace exactly its own keys and leave the rest of the document byte-
//! faithful, including the order a human arranged it in.

const std = @import("std");

pub const Field = struct {
    key: []const u8,
    /// Raw JSON text for the new value, or null to delete the key.
    json: ?[]const u8,
};

pub const MergeError = error{
    NotAnObject,
    InvalidJson,
    InvalidFieldJson,
    OutOfMemory,
};

/// One member of an object that is itself a top-level value:
/// `object_key.member_key` (`custom_providers.my-relay`). A writer that owns
/// one member, not the whole object, replaces exactly that member.
pub const MemberField = struct {
    object_key: []const u8,
    member_key: []const u8,
    /// Raw JSON text for the member's new value, or null to delete it.
    json: ?[]const u8,
};

/// Return `original` with `fields` applied.
///
/// Existing keys keep their position; new keys are appended in the order given.
/// An empty or blank original is treated as `{}` so first-time writes work.
pub fn mergeObjectFields(
    allocator: std.mem.Allocator,
    original: []const u8,
    fields: []const Field,
) MergeError![]u8 {
    return mergeFields(allocator, original, fields, &.{});
}

/// `mergeObjectFields`, then each of `members` inside its object, in the
/// same pass. A member keeps its position when replaced and is appended when
/// new; the object is created for a member put into one that is absent, and a
/// delete from an absent object is a no-op. An `object_key` that holds
/// anything but an object is `NotAnObject`: replacing it would destroy data
/// this call was never asked about.
pub fn mergeFields(
    allocator: std.mem.Allocator,
    original: []const u8,
    fields: []const Field,
    members: []const MemberField,
) MergeError![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const trimmed = std.mem.trim(u8, original, " \t\r\n");
    const source = if (trimmed.len == 0) "{}" else trimmed;

    var parsed = std.json.parseFromSliceLeaky(
        std.json.Value,
        scratch,
        source,
        .{},
    ) catch return error.InvalidJson;
    if (parsed != .object) return error.NotAnObject;

    for (fields) |field| {
        if (field.json) |raw| {
            const value = std.json.parseFromSliceLeaky(
                std.json.Value,
                scratch,
                raw,
                .{},
            ) catch return error.InvalidFieldJson;
            try parsed.object.put(scratch, field.key, value);
        } else {
            _ = parsed.object.orderedRemove(field.key);
        }
    }

    for (members) |member| {
        const holder = parsed.object.getPtr(member.object_key) orelse holder: {
            if (member.json == null) continue;
            try parsed.object.put(scratch, member.object_key, .{ .object = .empty });
            break :holder parsed.object.getPtr(member.object_key).?;
        };
        if (holder.* != .object) return error.NotAnObject;
        if (member.json) |raw| {
            const value = std.json.parseFromSliceLeaky(
                std.json.Value,
                scratch,
                raw,
                .{},
            ) catch return error.InvalidFieldJson;
            try holder.object.put(scratch, member.member_key, value);
        } else {
            _ = holder.object.orderedRemove(member.member_key);
        }
    }

    return std.json.Stringify.valueAlloc(allocator, parsed, .{ .whitespace = .indent_2 });
}

// ── tests ────────────────────────────────────────────────────────────────────

test "merge replaces one key and preserves every other writer's data" {
    const a = std.testing.allocator;
    const original =
        \\{"model":"claude-sonnet-4-6","mcp_servers":[{"name":"kg"}],"theme":"dark"}
    ;
    const merged = try mergeObjectFields(a, original, &.{
        .{ .key = "model", .json = "\"glm-4.6\"" },
    });
    defer a.free(merged);
    try std.testing.expect(std.mem.indexOf(u8, merged, "\"glm-4.6\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, merged, "mcp_servers") != null);
    try std.testing.expect(std.mem.indexOf(u8, merged, "\"kg\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, merged, "\"dark\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, merged, "claude-sonnet-4-6") == null);
}

test "merge preserves key order and appends new keys at the end" {
    const a = std.testing.allocator;
    const merged = try mergeObjectFields(a, "{\"b\":1,\"a\":2}", &.{
        .{ .key = "c", .json = "3" },
    });
    defer a.free(merged);
    const b_at = std.mem.indexOf(u8, merged, "\"b\"").?;
    const a_at = std.mem.indexOf(u8, merged, "\"a\"").?;
    const c_at = std.mem.indexOf(u8, merged, "\"c\"").?;
    try std.testing.expect(b_at < a_at);
    try std.testing.expect(a_at < c_at);
}

test "merge treats an empty document as an empty object" {
    const a = std.testing.allocator;
    const merged = try mergeObjectFields(a, "", &.{
        .{ .key = "schema_version", .json = "1" },
    });
    defer a.free(merged);
    try std.testing.expect(std.mem.indexOf(u8, merged, "schema_version") != null);
}

test "merge can delete a key" {
    const a = std.testing.allocator;
    const merged = try mergeObjectFields(a, "{\"keep\":1,\"drop\":2}", &.{
        .{ .key = "drop", .json = null },
    });
    defer a.free(merged);
    try std.testing.expect(std.mem.indexOf(u8, merged, "drop") == null);
    try std.testing.expect(std.mem.indexOf(u8, merged, "keep") != null);
}

test "merge rejects malformed input instead of overwriting it" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.InvalidJson, mergeObjectFields(a, "{not json", &.{}));
    try std.testing.expectError(error.NotAnObject, mergeObjectFields(a, "[1,2]", &.{}));
    try std.testing.expectError(error.InvalidFieldJson, mergeObjectFields(a, "{}", &.{
        .{ .key = "x", .json = "{oops" },
    }));
}

fn expectKeys(expected: []const []const u8, actual: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |want, got| try std.testing.expectEqualStrings(want, got);
}

test "a member edit replaces one member in place and leaves its siblings and the rest alone" {
    const a = std.testing.allocator;
    const original =
        \\{"theme":"dark","custom_providers":{"a":{"x":1},"b":{"y":2},"c":{"z":3}},"tail":true}
    ;
    const merged = try mergeFields(a, original, &.{}, &.{
        .{ .object_key = "custom_providers", .member_key = "b", .json = "{\"y\":20}" },
        .{ .object_key = "custom_providers", .member_key = "d", .json = "{\"w\":4}" },
    });
    defer a.free(merged);
    var parsed = try std.json.parseFromSlice(std.json.Value, a, merged, .{});
    defer parsed.deinit();
    const section = parsed.value.object.get("custom_providers").?.object;
    // Replaced in place, appended at the end, the others untouched.
    try expectKeys(&.{ "a", "b", "c", "d" }, section.keys());
    try std.testing.expectEqual(@as(i64, 20), section.get("b").?.object.get("y").?.integer);
    try std.testing.expectEqual(@as(i64, 1), section.get("a").?.object.get("x").?.integer);
    try expectKeys(&.{ "theme", "custom_providers", "tail" }, parsed.value.object.keys());
}

test "a member edit deletes one member, creates the object it needs, and refuses a non-object" {
    const a = std.testing.allocator;
    const removed = try mergeFields(a, "{\"custom_providers\":{\"a\":{},\"b\":{}}}", &.{}, &.{
        .{ .object_key = "custom_providers", .member_key = "a", .json = null },
    });
    defer a.free(removed);
    try std.testing.expect(std.mem.indexOf(u8, removed, "\"a\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, removed, "\"b\"") != null);

    // Deleting from an absent object changes nothing and adds nothing.
    const untouched = try mergeFields(a, "{\"k\":1}", &.{}, &.{
        .{ .object_key = "custom_providers", .member_key = "a", .json = null },
    });
    defer a.free(untouched);
    try std.testing.expect(std.mem.indexOf(u8, untouched, "custom_providers") == null);

    const created = try mergeFields(a, "", &.{}, &.{
        .{ .object_key = "custom_providers", .member_key = "a", .json = "{\"x\":1}" },
    });
    defer a.free(created);
    try std.testing.expect(std.mem.indexOf(u8, created, "\"custom_providers\"") != null);

    // A section that is not an object is not overwritten.
    try std.testing.expectError(error.NotAnObject, mergeFields(a, "{\"custom_providers\":[1]}", &.{}, &.{
        .{ .object_key = "custom_providers", .member_key = "a", .json = "{}" },
    }));
    try std.testing.expectError(error.InvalidFieldJson, mergeFields(a, "{}", &.{}, &.{
        .{ .object_key = "custom_providers", .member_key = "a", .json = "{oops" },
    }));
}

test "merged output round-trips through a parser" {
    const a = std.testing.allocator;
    const merged = try mergeObjectFields(
        a,
        "{\"nested\":{\"deep\":[1,2,{\"k\":\"v\"}]}}",
        &.{.{ .key = "added", .json = "{\"x\":true}" }},
    );
    defer a.free(merged);
    var parsed = try std.json.parseFromSlice(std.json.Value, a, merged, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("nested") != null);
    try std.testing.expect(parsed.value.object.get("added").?.object.get("x").?.bool);
}
