//! Order-preserving JSON object merge.
//!
//! Several independent writers own different parts of `~/.metacodes/config.json`
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

/// Return `original` with `fields` applied.
///
/// Existing keys keep their position; new keys are appended in the order given.
/// An empty or blank original is treated as `{}` so first-time writes work.
pub fn mergeObjectFields(
    allocator: std.mem.Allocator,
    original: []const u8,
    fields: []const Field,
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
