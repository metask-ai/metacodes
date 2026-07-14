//! LSP workspace 门(对齐 hermes workspace.py):git worktree 检测 + per-server nearest_root。
//!
//! **门策略**:cwd 不在 git 仓 → 整个 LSP 子系统不启动(hermes 模式,避免在临时目录/无项目上下文
//! 里瞎跑 language server)。找 workspace root = 从 start 向上 walk ≤64 层找 `.git`(文件**或**目录
//! ——worktree 的 .git 是文件)。路径规范化**不解析 symlink**(保守,避免跨 symlink 误判归属)。
const std = @import("std");
const pfs = @import("platform").fs;

const MAX_WALK = 64;

/// 文件/目录是否存在(F_OK)。path 须 null 结尾。
fn exists(path_z: [*:0]const u8) bool {
    return std.c.access(path_z, std.c.F_OK) == 0;
}

/// 从 start 向上找含 `.git` 的最近祖先目录(git worktree root)。找到 → 写进 out_buf 返回 slice;
/// 无 → null。start 须是绝对路径。out_buf 至少 max_path_bytes。
pub fn findGitWorktree(start: []const u8, out_buf: []u8) ?[]const u8 {
    var dir = std.mem.trimEnd(u8, start, "/");
    if (dir.len == 0) dir = "/";
    var level: usize = 0;
    while (level < MAX_WALK) : (level += 1) {
        // 拼 <dir>/.git\x00 到临时栈 buf 检测。
        var gbuf: [std.fs.max_path_bytes + 8]u8 = undefined;
        const gpath = std.fmt.bufPrintZ(&gbuf, "{s}/.git", .{dir}) catch return null;
        if (exists(gpath.ptr)) {
            if (dir.len > out_buf.len) return null;
            @memcpy(out_buf[0..dir.len], dir);
            return out_buf[0..dir.len];
        }
        if (std.mem.eql(u8, dir, "/")) break;
        dir = std.fs.path.dirname(dir) orelse break;
        if (dir.len == 0) dir = "/";
    }
    return null;
}

/// 解析某文件的 workspace:优先 cwd 的 git 仓(且文件在其内),否则文件自身所在的 git 仓。
/// 返回 {root, gated_in}:root=null 表示不在任何 git 仓(LSP 不启动)。
pub const Resolved = struct { root: ?[]const u8, gated_in: bool };

pub fn resolveWorkspaceForFile(file_path: []const u8, cwd: ?[]const u8, out_buf: []u8) Resolved {
    // 先试 cwd 的 git,且文件在其内。
    if (cwd) |c| {
        var cwd_git_buf: [std.fs.max_path_bytes]u8 = undefined;
        if (findGitWorktree(c, &cwd_git_buf)) |cwd_root| {
            if (isInsideWorkspace(file_path, cwd_root)) {
                if (cwd_root.len <= out_buf.len) {
                    @memcpy(out_buf[0..cwd_root.len], cwd_root);
                    return .{ .root = out_buf[0..cwd_root.len], .gated_in = true };
                }
            }
        }
    }
    // 回退:文件自身所在 git 仓。
    if (findGitWorktree(std.fs.path.dirname(file_path) orelse file_path, out_buf)) |root| {
        return .{ .root = root, .gated_in = true };
    }
    return .{ .root = null, .gated_in = false };
}

/// path 是否在 workspace root 之内(commonpath 包含判断,不解析 symlink)。
/// root 须是 path 的祖先(逐段前缀 + 边界在 `/`)。
pub fn isInsideWorkspace(path: []const u8, root: []const u8) bool {
    const r = std.mem.trimEnd(u8, root, "/");
    if (r.len == 0) return true; // root="/" 包含一切
    if (!std.mem.startsWith(u8, path, r)) return false;
    // 边界:path[r.len] 必须是 '/' 或 path 恰好等于 root(避免 /foo 匹配 /foobar)。
    return path.len == r.len or path[r.len] == '/';
}

/// per-server root walk:从 start 向上找含任一 marker 的目录;每层**先查 excludes**(命中即整个
/// server gate off 返 null),再查 markers。到 ceiling(git root)或 MAX_WALK 停。
/// markers/excludes 是文件/目录名(如 "package.json"、"deno.json")。找到 → out_buf,否则 null。
pub fn nearestRoot(
    start: []const u8,
    markers: []const []const u8,
    excludes: []const []const u8,
    ceiling: ?[]const u8,
    out_buf: []u8,
) ?[]const u8 {
    var dir = std.mem.trimEnd(u8, start, "/");
    if (dir.len == 0) dir = "/";
    var level: usize = 0;
    while (level < MAX_WALK) : (level += 1) {
        // 先 excludes:任一存在 → 该 server 在此不启动。
        for (excludes) |ex| {
            if (childExists(dir, ex)) return null;
        }
        for (markers) |mk| {
            if (childExists(dir, mk)) {
                if (dir.len <= out_buf.len) {
                    @memcpy(out_buf[0..dir.len], dir);
                    return out_buf[0..dir.len];
                }
                return null;
            }
        }
        if (ceiling) |c| {
            if (std.mem.eql(u8, dir, std.mem.trimEnd(u8, c, "/"))) break;
        }
        if (std.mem.eql(u8, dir, "/")) break;
        dir = std.fs.path.dirname(dir) orelse break;
        if (dir.len == 0) dir = "/";
    }
    return null;
}

fn childExists(dir: []const u8, name: []const u8) bool {
    var buf: [std.fs.max_path_bytes + 8]u8 = undefined;
    const p = std.fmt.bufPrintZ(&buf, "{s}/{s}", .{ dir, name }) catch return false;
    return exists(p.ptr);
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "isInsideWorkspace: 边界正确(不误配前缀)" {
    try testing.expect(isInsideWorkspace("/proj/src/x.zig", "/proj"));
    try testing.expect(isInsideWorkspace("/proj", "/proj"));
    try testing.expect(isInsideWorkspace("/proj/a", "/proj/"));
    try testing.expect(!isInsideWorkspace("/project/x", "/proj")); // /project 不属于 /proj
    try testing.expect(!isInsideWorkspace("/other/x", "/proj"));
    try testing.expect(isInsideWorkspace("/anything", "/")); // root 含一切
}

fn mkd(path: []const u8) void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const z = std.fmt.bufPrintZ(&buf, "{s}", .{path}) catch return;
    _ = std.c.mkdir(z.ptr, 0o755);
}
fn touch(path: []const u8) void {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const z = std.fmt.bufPrintZ(&buf, "{s}", .{path}) catch return;
    const fd = pfs.open(z.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    if (fd >= 0) _ = pfs.close(fd);
}

test "findGitWorktree + nearestRoot: 真临时目录树(std.c FS)" {
    const a = testing.allocator;
    // 建 /tmp/cc_ws_test_<pid>/repo/{.git, pkg/sub, pkg/package.json}
    const base = try std.fmt.allocPrint(a, "/tmp/cc_ws_test_{d}", .{std.c.getpid()});
    defer a.free(base);
    const repo = try std.fmt.allocPrint(a, "{s}/repo", .{base});
    defer a.free(repo);
    const pkg = try std.fmt.allocPrint(a, "{s}/pkg", .{repo});
    defer a.free(pkg);
    const sub = try std.fmt.allocPrint(a, "{s}/sub", .{pkg});
    defer a.free(sub);
    const gitdir = try std.fmt.allocPrint(a, "{s}/.git", .{repo});
    defer a.free(gitdir);
    mkd(base);
    mkd(repo);
    mkd(gitdir);
    mkd(pkg);
    mkd(sub);
    const pkgjson = try std.fmt.allocPrint(a, "{s}/package.json", .{pkg});
    defer a.free(pkgjson);
    touch(pkgjson);

    // findGitWorktree(sub) → repo
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const found = findGitWorktree(sub, &buf);
    try testing.expect(found != null);
    try testing.expectEqualStrings(repo, found.?);

    // nearestRoot(sub, ["package.json"], [], repo) → pkg
    var buf2: [std.fs.max_path_bytes]u8 = undefined;
    const nr = nearestRoot(sub, &.{"package.json"}, &.{}, repo, &buf2);
    try testing.expect(nr != null);
    try testing.expectEqualStrings(pkg, nr.?);

    // exclude 命中 → null(pkg 下放 deno.json 当 exclude)
    const deno = try std.fmt.allocPrint(a, "{s}/deno.json", .{pkg});
    defer a.free(deno);
    touch(deno);
    var buf3: [std.fs.max_path_bytes]u8 = undefined;
    try testing.expect(nearestRoot(sub, &.{"package.json"}, &.{"deno.json"}, repo, &buf3) == null);
    // /tmp 测试目录留存无碍(临时);不做递归清理(std.c 递归 rmdir 繁琐)。
}

test "resolveWorkspaceForFile: 无 git → root=null,gated_in=false" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    // /tmp 通常不在 git 仓(若在则此测试跳过语义)——用一个几乎不可能在 git 的路径。
    const r = resolveWorkspaceForFile("/nonexistent_xyz/file.py", "/nonexistent_xyz", &buf);
    try testing.expect(r.root == null);
    try testing.expect(!r.gated_in);
}
