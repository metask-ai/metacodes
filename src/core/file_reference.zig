//! Host-neutral file references projected from successful built-in file tools.
//! The strings in this DTO are owned by the caller allocator; no host UI or
//! authorization decision is made here.

const std = @import("std");
const builtin = @import("builtin");
const ToolContext = @import("../tools/context.zig").ToolContext;
const common = @import("../tools/common.zig");
const json_util = @import("../util/json.zig");
const path_mod = @import("../util/path.zig");

pub const MAX_FILE_REFS_PER_TOOL_RESULT_V1: usize = 32;
pub const MAX_FILE_REF_PATH_BYTES_V1: usize = 4096;
pub const MAX_FILE_REF_URI_BYTES_V1: usize = 8192;
pub const MAX_FILE_REF_TITLE_BYTES_V1: usize = 256;
pub const MAX_FILE_REF_KIND_BYTES_V1: usize = 64;

pub const Locator = union(enum) {
    workspace_path: []const u8,
    absolute_path: []const u8,
    uri: []const u8,
};

pub const Range = struct {
    start: Position,
    end: Position,
};

pub const Position = struct {
    line: u32,
    column: u32,
};

pub const FileReference = struct {
    locator: Locator,
    title: []const u8,
    kind: []const u8,
    range: ?Range = null,

    pub fn deinit(self: *FileReference, allocator: std.mem.Allocator) void {
        switch (self.locator) {
            inline else => |value| allocator.free(value),
        }
        allocator.free(self.title);
        allocator.free(self.kind);
        self.* = undefined;
    }
};

pub const LocatorKind = enum { workspace_path, absolute_path, uri };

/// Execution-context output. It is resolved and classified at the dispatch
/// seam; the projection below accepts only this value and performs no path
/// normalization or policy lookup.
pub const ResolvedFileTarget = struct {
    path: []const u8,
    locator_kind: LocatorKind,
    state: @import("../tools/observation.zig").FileTargetState = .unobserved,
};

pub fn isBuiltinFileTool(name: []const u8) bool {
    return std.mem.eql(u8, name, "Read") or
        std.mem.eql(u8, name, "Write") or
        std.mem.eql(u8, name, "Edit") or
        std.mem.eql(u8, name, "NotebookEdit");
}

pub fn pathField(name: []const u8) []const u8 {
    if (std.mem.eql(u8, name, "NotebookEdit")) return "notebook_path";
    if (std.mem.eql(u8, name, "Read") or std.mem.eql(u8, name, "Write") or std.mem.eql(u8, name, "Edit"))
        return "file_path";
    return "";
}

/// Resolve the exact path argument through the same normalization policy used
/// by the native tools. A URI is preserved as a URI and is never interpreted
/// as a local filesystem path.
pub fn resolveFileTarget(
    allocator: std.mem.Allocator,
    ctx: *const ToolContext,
    name: []const u8,
    input: []const u8,
    state: @import("../tools/observation.zig").FileTargetState,
) !?ResolvedFileTarget {
    if (!isBuiltinFileTool(name)) return null;
    const escaped = common.extractJsonArg(input, pathField(name)) orelse
        common.extractJsonArg(input, "path") orelse return null;
    const raw = try json_util.unescapeString(escaped, allocator);
    defer allocator.free(raw);
    if (raw.len == 0) return null;

    if (std.mem.indexOf(u8, raw, "://")) |_| {
        if (raw.len > MAX_FILE_REF_URI_BYTES_V1) return null;
        return .{ .path = try allocator.dupe(u8, raw), .locator_kind = .uri, .state = state };
    }

    const normalized = path_mod.normalizeChecked(allocator, raw, .{
        .home = ctx.home_dir,
        .base_dir = ctx.cwd_abs,
        .resolve_relative = ctx.resolve_relative_paths,
    }) catch return null;
    defer allocator.free(normalized);
    if (normalized.len > MAX_FILE_REF_PATH_BYTES_V1) return null;

    var normalized_cwd: ?[]u8 = null;
    defer if (normalized_cwd) |cwd| allocator.free(cwd);
    if (ctx.cwd_abs.len != 0) {
        normalized_cwd = path_mod.normalizeChecked(allocator, ctx.cwd_abs, .{
            .home = ctx.home_dir,
            .resolve_relative = false,
        }) catch null;
    }
    const cwd = if (normalized_cwd) |value| value else ctx.cwd_abs;
    if (workspaceRelative(cwd, normalized)) |relative| {
        return .{ .path = try allocator.dupe(u8, relative), .locator_kind = .workspace_path, .state = state };
    }
    return .{ .path = try allocator.dupe(u8, normalized), .locator_kind = .absolute_path, .state = state };
}

pub fn project(
    allocator: std.mem.Allocator,
    target: ResolvedFileTarget,
    name: []const u8,
) !FileReference {
    const locator = switch (target.locator_kind) {
        .workspace_path => Locator{ .workspace_path = try allocator.dupe(u8, target.path) },
        .absolute_path => Locator{ .absolute_path = try allocator.dupe(u8, target.path) },
        .uri => Locator{ .uri = try allocator.dupe(u8, target.path) },
    };
    errdefer switch (locator) {
        inline else => |value| allocator.free(value),
    };
    const title = if (target.locator_kind == .uri)
        try allocator.dupe(u8, "")
        else
        try allocator.dupe(u8, std.fs.path.basename(target.path));
    if (title.len > MAX_FILE_REF_TITLE_BYTES_V1) {
        allocator.free(title);
        return error.FileReferenceTitleTooLong;
    }
    errdefer allocator.free(title);
    const kind = try allocator.dupe(u8, kindFor(name, target.state));
    return .{ .locator = locator, .title = title, .kind = kind };
}

fn kindFor(name: []const u8, state: @import("../tools/observation.zig").FileTargetState) []const u8 {
    if (std.mem.eql(u8, name, "Read")) return "read";
    if (std.mem.eql(u8, name, "NotebookEdit")) return "notebook";
    if (state == .missing) return "created";
    if (state == .regular_existing) return "modified";
    return "file";
}

fn workspaceRelative(cwd: []const u8, path: []const u8) ?[]const u8 {
    if (cwd.len == 0) return if (!std.fs.path.isAbsolute(path)) path else null;
    if (samePath(cwd, path)) return ".";
    if (path.len <= cwd.len or !isPathSep(path[cwd.len])) return null;
    if (!samePrefix(cwd, path[0..cwd.len])) return null;
    return path[cwd.len + 1 ..];
}

fn isPathSep(c: u8) bool {
    return c == '/' or c == '\\';
}

fn samePath(a: []const u8, b: []const u8) bool {
    return samePrefix(a, b) and a.len == b.len;
}

fn samePrefix(a: []const u8, b: []const u8) bool {
    if (builtin.os.tag == .windows) return std.ascii.eqlIgnoreCase(a, b);
    return std.mem.eql(u8, a, b);
}

test "file reference resolves workspace and absolute locators" {
    const a = std.testing.allocator;
    var ctx = ToolContext{ .allocator = a, .cwd_abs = "/work", .resolve_relative_paths = true };
    const inside = (try resolveFileTarget(a, &ctx, "Read", "{\"file_path\":\"src/main.zig\"}", .unobserved)).?;
    defer {
        a.free(inside.path);
    }
    try std.testing.expectEqual(LocatorKind.workspace_path, inside.locator_kind);

    const outside = (try resolveFileTarget(a, &ctx, "Read", "{\"file_path\":\"/tmp/x\"}", .unobserved)).?;
    defer {
        a.free(outside.path);
    }
    try std.testing.expectEqual(LocatorKind.absolute_path, outside.locator_kind);
}

test "NotebookEdit uses notebook_path and owns projected metadata" {
    const a = std.testing.allocator;
    var ctx = ToolContext{ .allocator = a, .cwd_abs = "/work", .resolve_relative_paths = true };
    const target = (try resolveFileTarget(
        a,
        &ctx,
        "NotebookEdit",
        "{\"notebook_path\":\"notebooks/demo.ipynb\"}",
        .regular_existing,
    )).?;
    defer a.free(target.path);
    try std.testing.expectEqual(LocatorKind.workspace_path, target.locator_kind);

    var ref = try project(a, target, "NotebookEdit");
    defer ref.deinit(a);
    try std.testing.expectEqualStrings("notebooks/demo.ipynb", ref.locator.workspace_path);
    try std.testing.expectEqualStrings("demo.ipynb", ref.title);
    try std.testing.expectEqualStrings("notebook", ref.kind);
}

test "file reference projection rejects an oversized title before emission" {
    const a = std.testing.allocator;
    var path: [MAX_FILE_REF_TITLE_BYTES_V1 + 1]u8 = undefined;
    @memset(&path, 'x');
    try std.testing.expectError(error.FileReferenceTitleTooLong, project(a, .{
        .path = &path,
        .locator_kind = .workspace_path,
        .state = .regular_existing,
    }, "Edit"));
}
