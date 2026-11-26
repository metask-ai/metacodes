//! Anthropic-style pagination of a `/v1/models` list.
//!
//! The list carries `has_more` and `last_id`; the next page is the same URL
//! with `after_id=<last_id>`. A gateway may serve a key's models over several
//! pages, and a reader that kept only the first silently dropped the rest.
//! A list that does not say `has_more: true` with a `last_id` is complete.

const std = @import("std");

/// Pages read at most. Each continuation asks for `PAGE_LIMIT` entries, so
/// this bounds a list at tens of thousands of models while a server that
/// never stops answering `has_more` cannot loop a reader forever.
pub const MAX_PAGES: usize = 50;
pub const PAGE_LIMIT: u32 = 1000;

/// The `after_id` that fetches the page after `body` (owned by `gpa`), or
/// null when `body` is the last page or not a list document at all.
pub fn nextCursor(gpa: std.mem.Allocator, body: []const u8) error{OutOfMemory}!?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, body, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const more = parsed.value.object.get("has_more") orelse return null;
    if (more != .bool or !more.bool) return null;
    const last = parsed.value.object.get("last_id") orelse return null;
    if (last != .string or last.string.len == 0) return null;
    return try gpa.dupe(u8, last.string);
}

/// `models_url` asking for the page after `after_id` (owned by `gpa`).
pub fn continuationUrl(gpa: std.mem.Allocator, models_url: []const u8, after_id: []const u8) error{OutOfMemory}![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, models_url);
    try out.append(gpa, if (std.mem.indexOfScalar(u8, models_url, '?') == null) '?' else '&');
    try out.appendSlice(gpa, "after_id=");
    for (after_id) |byte| {
        const unreserved = std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == '~';
        if (unreserved) {
            try out.append(gpa, byte);
        } else {
            try out.print(gpa, "%{X:0>2}", .{byte});
        }
    }
    try out.print(gpa, "&limit={d}", .{PAGE_LIMIT});
    return out.toOwnedSlice(gpa);
}

/// One list document holding every page's `data` entries, in page order
/// (owned by `gpa`). Entries keep every field they had; a page that is not a
/// list document contributes nothing.
pub fn merge(gpa: std.mem.Allocator, pages: []const []const u8) error{OutOfMemory}![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    w.writeAll("{\"object\":\"list\",\"data\":[") catch return error.OutOfMemory;
    var first = true;
    for (pages) |page| {
        var parsed = std.json.parseFromSlice(std.json.Value, gpa, page, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };
        defer parsed.deinit();
        if (parsed.value != .object) continue;
        const data = parsed.value.object.get("data") orelse continue;
        if (data != .array) continue;
        for (data.array.items) |entry| {
            if (!first) w.writeByte(',') catch return error.OutOfMemory;
            first = false;
            std.json.Stringify.value(entry, .{}, w) catch return error.OutOfMemory;
        }
    }
    w.writeAll("],\"has_more\":false}") catch return error.OutOfMemory;
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

const testing = std.testing;

test "nextCursor follows has_more with last_id and stops otherwise" {
    const a = testing.allocator;
    const cursor = (try nextCursor(a, "{\"data\":[{\"id\":\"a\"}],\"has_more\":true,\"last_id\":\"a\"}")).?;
    defer a.free(cursor);
    try testing.expectEqualStrings("a", cursor);
    try testing.expect(try nextCursor(a, "{\"data\":[],\"has_more\":false,\"last_id\":\"a\"}") == null);
    try testing.expect(try nextCursor(a, "{\"data\":[{\"id\":\"a\"}]}") == null);
    try testing.expect(try nextCursor(a, "{\"data\":[],\"has_more\":true}") == null);
    try testing.expect(try nextCursor(a, "{\"data\":[],\"has_more\":true,\"last_id\":\"\"}") == null);
    try testing.expect(try nextCursor(a, "not json") == null);
}

test "continuationUrl adds after_id and limit, percent-encoding the id" {
    const a = testing.allocator;
    const plain = try continuationUrl(a, "https://gw.example/v1/models", "glm-5.3");
    defer a.free(plain);
    try testing.expectEqualStrings("https://gw.example/v1/models?after_id=glm-5.3&limit=1000", plain);
    const odd = try continuationUrl(a, "https://gw.example/v1/models?x=1", "a/b c");
    defer a.free(odd);
    try testing.expectEqualStrings("https://gw.example/v1/models?x=1&after_id=a%2Fb%20c&limit=1000", odd);
}

test "merge keeps every entry of every page, with its fields, in order" {
    const a = testing.allocator;
    const merged = try merge(a, &.{
        "{\"object\":\"list\",\"data\":[{\"id\":\"a\",\"max_tokens\":8},{\"id\":\"b\",\"capabilities\":{\"thinking\":{\"supported\":true}}}],\"has_more\":true,\"last_id\":\"b\"}",
        "not a list",
        "{\"data\":[{\"id\":\"c\",\"display_name\":\"C\"}],\"has_more\":false}",
    });
    defer a.free(merged);
    try testing.expectEqualStrings(
        "{\"object\":\"list\",\"data\":[{\"id\":\"a\",\"max_tokens\":8},{\"id\":\"b\",\"capabilities\":{\"thinking\":{\"supported\":true}}},{\"id\":\"c\",\"display_name\":\"C\"}],\"has_more\":false}",
        merged,
    );
}
