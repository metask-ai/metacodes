//! The file a built-in file-mutating tool call acts on, derived exactly as the
//! tool derives it. Write and Edit read their path argument through `rawPath`,
//! and AgentCore's per-file Permission grant (`file_target`) keys on `resolve`,
//! so a grant always names the file the tool would write.
//!
//! `rawPath` keeps the tools' own reading: `common.extractJsonArg` takes the
//! first textual occurrence of the key, which a nested object or an escaped
//! key can supply. A caller that also parses the JSON must compare the two
//! readings itself before trusting either (see
//! `agentcore/session_permission.deriveFileTarget`).

const std = @import("std");
const common = @import("common.zig");
const path_mod = @import("../util/path.zig");
const util_json = @import("../util/json.zig");

pub const Tool = enum {
    write,
    edit,

    pub fn fromName(name: []const u8) ?Tool {
        if (std.mem.eql(u8, name, "Write")) return .write;
        if (std.mem.eql(u8, name, "Edit")) return .edit;
        return null;
    }

    /// The top-level argument a JSON parser must find for the call to be
    /// unambiguous: Write reads `file_path` and falls back to the historical
    /// `path`; Edit reads only `file_path`.
    pub fn pathKey(self: Tool, has_file_path: bool) []const u8 {
        return switch (self) {
            .write => if (has_file_path) "file_path" else "path",
            .edit => "file_path",
        };
    }
};

/// The still JSON-escaped path argument exactly as the tool reads it.
pub fn rawPath(tool: Tool, input: []const u8) ?[]const u8 {
    return switch (tool) {
        .write => common.extractJsonArg(input, "file_path") orelse
            common.extractJsonArg(input, "path"),
        .edit => common.extractJsonArg(input, "file_path"),
    };
}

/// `rawPath` JSON-unescaped, as the tool decodes it before normalizing. Null
/// when the argument is missing or empty, which the tool refuses before
/// touching the filesystem.
pub fn unescapedPath(
    allocator: std.mem.Allocator,
    tool: Tool,
    input: []const u8,
) error{OutOfMemory}!?[]u8 {
    const raw = rawPath(tool, input) orelse return null;
    const unescaped = try util_json.unescapeString(raw, allocator);
    if (unescaped.len == 0) {
        allocator.free(unescaped);
        return null;
    }
    return unescaped;
}

pub const Context = struct {
    home: []const u8,
    base_dir: []const u8,
    resolve_relative: bool,
};

/// The normalized path the tool would open, or null whenever the tool itself
/// would refuse the argument (missing, empty, traversal, `~` without a home,
/// embedded NUL, too long).
pub fn resolve(
    allocator: std.mem.Allocator,
    tool: Tool,
    input: []const u8,
    context: Context,
) error{OutOfMemory}!?[]u8 {
    const unescaped = (try unescapedPath(allocator, tool, input)) orelse return null;
    defer allocator.free(unescaped);
    return path_mod.normalizeChecked(allocator, unescaped, .{
        .home = context.home,
        .base_dir = context.base_dir,
        .resolve_relative = context.resolve_relative,
    }) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => null,
    };
}

const testing = std.testing;

test "Write falls back to path and Edit reads only file_path" {
    try testing.expectEqualStrings("/w/a", rawPath(.write, "{\"path\":\"/w/a\",\"content\":\"x\"}").?);
    try testing.expectEqualStrings("/w/b", rawPath(.write, "{\"path\":\"/w/a\",\"file_path\":\"/w/b\"}").?);
    try testing.expect(rawPath(.edit, "{\"path\":\"/w/a\",\"old_string\":\"x\",\"new_string\":\"y\"}") == null);
    try testing.expectEqualStrings("file_path", Tool.write.pathKey(true));
    try testing.expectEqualStrings("path", Tool.write.pathKey(false));
    try testing.expectEqualStrings("file_path", Tool.edit.pathKey(false));
}

test "resolve normalizes like the tools and refuses what they refuse" {
    const context = Context{ .home = "/home/u", .base_dir = "/w", .resolve_relative = true };
    const cases = [_]struct { input: []const u8, expected: ?[]const u8 }{
        .{ .input = "{\"file_path\":\"/w/src/a.txt\",\"content\":\"1\"}", .expected = "/w/src/a.txt" },
        .{ .input = "{\"file_path\":\"src/./a.txt\",\"content\":\"2\"}", .expected = "/w/src/a.txt" },
        .{ .input = "{\"file_path\":\"~/notes.md\",\"content\":\"3\"}", .expected = "/home/u/notes.md" },
        .{ .input = "{\"file_path\":\"\",\"content\":\"4\"}", .expected = null },
        .{ .input = "{\"content\":\"5\"}", .expected = null },
        .{ .input = "{\"file_path\":\"/w/a\\u0000b\",\"content\":\"6\"}", .expected = null },
    };
    for (cases) |case| {
        const got = try resolve(testing.allocator, .write, case.input, context);
        defer if (got) |path| testing.allocator.free(path);
        if (case.expected) |expected| {
            try testing.expectEqualStrings(expected, got orelse return error.TestExpectedEqual);
        } else try testing.expect(got == null);
    }
}
