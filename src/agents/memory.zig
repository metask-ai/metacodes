//! AgentDef.memory 的运行时语义：为每个 agent 解析一个受限持久目录，并把操作协议
//! 注入子 agent system prompt。目录只由可信的 home/project root 与清洗后的 agent 名组成。

const std = @import("std");
const pfs = @import("platform").fs;
const MemoryScope = @import("def.zig").MemoryScope;

pub fn resolveDir(
    allocator: std.mem.Allocator,
    agent_name: []const u8,
    scope: MemoryScope,
    home_dir: []const u8,
    project_dir: []const u8,
) !?[]u8 {
    if (scope == .none) return null;

    const base = switch (scope) {
        .none => unreachable,
        .user => home_dir,
        .project, .local => project_dir,
    };
    if (base.len == 0) return error.AgentMemoryBaseUnavailable;

    const base_canon = try realpathAlloc(allocator, base);
    defer allocator.free(base_canon);
    const safe_name = try identityName(allocator, agent_name);
    defer allocator.free(safe_name);
    const rel = switch (scope) {
        .none => unreachable,
        .user => ".metacodes/agent-memory",
        .project => ".metacodes/agent-memory",
        .local => ".metacodes/agent-memory-local",
    };
    const dir = try std.fmt.allocPrint(allocator, "{s}/{s}/{s}", .{ base_canon, rel, safe_name });
    errdefer allocator.free(dir);
    // Reject an existing symlinked parent before mkdir follows it. This makes
    // a project-controlled `.metacodes` link unable to redirect agent memory
    // outside the trusted project/home root.
    const ancestor = try nearestExistingAncestor(allocator, dir);
    defer allocator.free(ancestor);
    const ancestor_canon = try realpathAlloc(allocator, ancestor);
    defer allocator.free(ancestor_canon);
    if (!isWithin(base_canon, ancestor_canon)) return error.AgentMemoryPathEscapesBase;
    try @import("../util/fs.zig").mkdirParents(dir);
    const dir_canon = try realpathAlloc(allocator, dir);
    if (!isWithin(base_canon, dir_canon)) {
        allocator.free(dir_canon);
        return error.AgentMemoryPathEscapesBase;
    }
    allocator.free(dir);
    return dir_canon;
}

pub fn buildPrompt(allocator: std.mem.Allocator, scope: MemoryScope, dir: []const u8) ![]u8 {
    const scope_note = switch (scope) {
        .none => return allocator.dupe(u8, ""),
        .user => "This memory is user-scoped; keep learnings general across projects.",
        .project => "This memory is project-scoped and may be shared; keep it specific to this project.",
        .local => "This memory is local to this project and machine; do not assume teammates can see it.",
    };
    return std.fmt.allocPrint(
        allocator,
        "\n\n# Persistent Agent Memory\n\nYou have a persistent memory directory at `{s}`. {s}\nRead `MEMORY.md` there before relying on prior learnings. Store durable notes as Markdown files and maintain `MEMORY.md` as a concise index. Use only Read, Write, and Edit for this directory; do not write outside it merely for memory.\n",
        .{ dir, scope_note },
    );
}

/// A readable slug alone is not an identity: `plugin:reviewer`,
/// `plugin/reviewer`, and `plugin reviewer` all sanitize to the same bytes, and
/// case-insensitive filesystems add another collision class. Keep a bounded
/// readable prefix but derive the identity suffix from the untouched UTF-8
/// name. The fixed bound also prevents an untrusted AgentDef name from making
/// the memory path exceed filesystem component limits.
fn identityName(allocator: std.mem.Allocator, name: []const u8) ![]u8 {
    if (name.len == 0) return error.InvalidAgentMemoryName;
    var slug_buf: [48]u8 = undefined;
    var slug_len: usize = 0;
    for (name) |c| {
        if (slug_len == slug_buf.len) break;
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.') {
            slug_buf[slug_len] = c;
            slug_len += 1;
        } else if (slug_len > 0 and slug_buf[slug_len - 1] != '-') {
            slug_buf[slug_len] = '-';
            slug_len += 1;
        }
    }
    while (slug_len > 0 and (slug_buf[slug_len - 1] == '-' or slug_buf[slug_len - 1] == '.')) {
        slug_len -= 1;
    }
    const slug = if (slug_len == 0) "agent" else slug_buf[0..slug_len];
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(name, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return std.fmt.allocPrint(allocator, "{s}-{s}", .{ slug, hex[0..32] });
}

fn realpathAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (path.len + 1 > std.fs.max_path_bytes) return error.AgentMemoryPathTooLong;
    var path_z: [std.fs.max_path_bytes]u8 = undefined;
    @memcpy(path_z[0..path.len], path);
    path_z[path.len] = 0;
    var out: [std.fs.max_path_bytes]u8 = undefined;
    const resolved = pfs.realpath(@ptrCast(&path_z), &out) orelse return error.AgentMemoryBaseUnavailable;
    return allocator.dupe(u8, std.mem.span(@as([*:0]u8, @ptrCast(resolved))));
}

fn nearestExistingAncestor(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var current = path;
    while (true) {
        const current_z = try allocator.dupeZ(u8, current);
        const exists = pfs.exists(current_z.ptr);
        allocator.free(current_z);
        if (exists) return allocator.dupe(u8, current);
        current = std.fs.path.dirname(current) orelse return error.AgentMemoryBaseUnavailable;
    }
}

fn isWithin(root: []const u8, candidate: []const u8) bool {
    if (std.mem.eql(u8, root, candidate)) return true;
    return candidate.len > root.len and
        std.mem.startsWith(u8, candidate, root) and
        std.fs.path.isSep(candidate[root.len]);
}

test "resolveDir maps scopes and sanitizes names" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buf);
    const base = root_buf[0..root_len];

    const user = (try resolveDir(a, "plugin:reviewer", .user, base, "/repo")).?;
    defer a.free(user);
    const expected_user = try std.fmt.allocPrint(a, "{s}/.metacodes/agent-memory/plugin-reviewer-7d93a418a742abe5cefae5e0078afe85", .{base});
    defer a.free(expected_user);
    try std.testing.expectEqualStrings(expected_user, user);

    const local = (try resolveDir(a, "reviewer", .local, "/home/u", base)).?;
    defer a.free(local);
    const expected_local = try std.fmt.allocPrint(a, "{s}/.metacodes/agent-memory-local/reviewer-2d70999ae1805e4bcef9b4ab3a4b827f", .{base});
    defer a.free(expected_local);
    try std.testing.expectEqualStrings(expected_local, local);
}

test "memory directory identity survives slug, case, unicode, and path collisions" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buf);
    const base = root_buf[0..root_len];
    const names = [_][]const u8{
        "plugin:reviewer",
        "plugin/reviewer",
        "plugin reviewer",
        "Reviewer",
        "reviewer",
        "审查员",
        "../reviewer",
    };
    var paths: [names.len][]u8 = undefined;
    var initialized: usize = 0;
    defer for (paths[0..initialized]) |path| a.free(path);
    for (names, 0..) |name, index| {
        paths[index] = (try resolveDir(a, name, .project, "/unused", base)).?;
        initialized += 1;
        try std.testing.expect(std.mem.startsWith(u8, paths[index], base));
        for (paths[0..index]) |previous| {
            try std.testing.expect(!std.ascii.eqlIgnoreCase(previous, paths[index]));
        }
    }
}

test "buildPrompt identifies exact memory directory" {
    const out = try buildPrompt(std.testing.allocator, .project, "/repo/.metacodes/agent-memory/reviewer");
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "/repo/.metacodes/agent-memory/reviewer") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "MEMORY.md") != null);
}

test "resolveDir rejects symlinked memory parent outside base" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const fs = @import("../util/fs.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buf);
    const root = root_buf[0..root_len];
    const base = try std.fmt.allocPrint(a, "{s}/base", .{root});
    defer a.free(base);
    const outside = try std.fmt.allocPrint(a, "{s}/outside", .{root});
    defer a.free(outside);
    try fs.mkdirParents(base);
    try fs.mkdirParents(outside);
    const link = try std.fmt.allocPrintSentinel(a, "{s}/.metacodes", .{base}, 0);
    defer a.free(link);
    const target = try a.dupeZ(u8, outside);
    defer a.free(target);
    try std.testing.expectEqual(@as(c_int, 0), std.c.symlink(target.ptr, link.ptr));
    try std.testing.expectError(
        error.AgentMemoryPathEscapesBase,
        resolveDir(a, "reviewer", .project, "/unused", base),
    );
}
