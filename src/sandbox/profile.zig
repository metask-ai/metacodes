//! macOS Seatbelt 沙箱 profile 生成器。
//!
//! 生成 SBPL(Sandbox Profile Language)字符串,喂给 `sandbox-exec -p '<profile>' <cmd>`。
//!
//! 模型(对齐 Claude Code doc/PERMISSION_DESIGN.md 第 9 节):
//!   - (allow default)         先全放行(读 / exec / 网络 / sysctl 不限)
//!   - (deny file-write*)      然后禁止所有写
//!   - (allow file-write* ...) 再 allow 回工作目录 + 标准设备 + TMPDIR + allowWrite 列表
//!   - denyRead 路径单独 (deny file-read* ...)
//!
//! 即:**写默认拒、读默认放**,与官方默认隔离边界一致。
//!
//! 路径前缀语义(沙箱配置,标准 Unix 约定,**与 permission rules 的 // 写法不同**):
//!   /        绝对
//!   ~/       home
//!   ./ 或无  project root 相对
//!
//! macOS 注意:/tmp /var 是软链到 /private/*,SBPL subpath 必须用真实路径。
//! 本模块在生成时对每个路径做 realpath(失败则原样保留)。

const std = @import("std");
const pfs = @import("platform").fs;

pub const SandboxConfig = struct {
    /// 工作目录(绝对,必可写)
    cwd: []const u8,
    /// 额外可写路径(已解析为绝对)
    allow_write: []const []const u8 = &.{},
    /// 额外禁止写路径(优先于 allow_write)
    deny_write: []const []const u8 = &.{},
    /// 额外可读路径(默认全可读,通常无需设)
    allow_read: []const []const u8 = &.{},
    /// 禁止读路径(从默认全可读里挖洞)
    deny_read: []const []const u8 = &.{},
    /// HOME(用于 ~/ 前缀展开)
    home: []const u8 = "",
    /// 主 repo .git 路径(worktree 场景:允许写主 repo 的 .git 以便 git commit)
    main_git_dir: ?[]const u8 = null,
};

/// 标准可写设备/路径(无论何时都 allow,否则普通命令跑不起来)。
const STANDARD_WRITABLE = [_][]const u8{
    "/dev/null",
    "/dev/zero",
    "/dev/tty",
    "/dev/stdin",
    "/dev/stdout",
    "/dev/stderr",
    "/dev/random",
    "/dev/urandom",
};

/// 生成 SBPL profile 字符串。caller free。
pub fn generate(alloc: std.mem.Allocator, cfg: SandboxConfig) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(alloc);

    try buf.appendSlice(alloc, "(version 1)\n");
    try buf.appendSlice(alloc, "(allow default)\n");
    try buf.appendSlice(alloc, "(deny file-write*)\n");

    // ---- 可写白名单 ----
    try buf.appendSlice(alloc, "(allow file-write*\n");

    // 工作目录(realpath)
    try emitSubpath(alloc, &buf, cfg.cwd);

    // worktree:主 repo .git
    if (cfg.main_git_dir) |g| try emitSubpath(alloc, &buf, g);

    // 标准设备节点(literal,realpath 可能软链)
    for (STANDARD_WRITABLE) |dev| {
        try emitSubpathRealOrLiteral(alloc, &buf, dev, true);
    }
    // /dev/fd/*(regex)
    try buf.appendSlice(alloc, "  (regex #\"^/dev/fd/\")\n");

    // TMPDIR / 系统临时
    if (std.c.getenv("TMPDIR")) |t| {
        try emitSubpath(alloc, &buf, std.mem.span(t));
    }
    try emitSubpathRealOrLiteral(alloc, &buf, "/private/tmp", false);
    try emitSubpathRealOrLiteral(alloc, &buf, "/private/var/folders", false);

    // 用户配置的 allowWrite(已是绝对/展开过)
    for (cfg.allow_write) |p| {
        const expanded = try expandTilde(alloc, p, cfg.home);
        defer alloc.free(expanded);
        try emitSubpath(alloc, &buf, expanded);
    }

    try buf.appendSlice(alloc, ")\n");

    // ---- denyWrite(优先于上面的 allow,放在后面覆盖)----
    if (cfg.deny_write.len > 0) {
        try buf.appendSlice(alloc, "(deny file-write*\n");
        for (cfg.deny_write) |p| {
            const expanded = try expandTilde(alloc, p, cfg.home);
            defer alloc.free(expanded);
            try emitSubpath(alloc, &buf, expanded);
        }
        try buf.appendSlice(alloc, ")\n");
    }

    // ---- denyRead(从默认全可读挖洞)----
    if (cfg.deny_read.len > 0) {
        try buf.appendSlice(alloc, "(deny file-read*\n");
        for (cfg.deny_read) |p| {
            const expanded = try expandTilde(alloc, p, cfg.home);
            defer alloc.free(expanded);
            try emitSubpath(alloc, &buf, expanded);
        }
        try buf.appendSlice(alloc, ")\n");
    }

    return try buf.toOwnedSlice(alloc);
}

/// 写一条 `(subpath "<realpath>")`,对 path 做 realpath;失败用原样。
fn emitSubpath(alloc: std.mem.Allocator, buf: *std.ArrayList(u8), path: []const u8) !void {
    const real = realpathAlloc(alloc, path) catch null;
    defer if (real) |r| alloc.free(r);
    const use = real orelse path;
    try buf.appendSlice(alloc, "  (subpath ");
    try writeSbplString(alloc, buf, use);
    try buf.appendSlice(alloc, ")\n");
}

/// 设备节点等:realpath 成功用 subpath(real),否则用 literal(原样)。
fn emitSubpathRealOrLiteral(alloc: std.mem.Allocator, buf: *std.ArrayList(u8), path: []const u8, use_literal: bool) !void {
    const real = realpathAlloc(alloc, path) catch null;
    defer if (real) |r| alloc.free(r);
    if (real) |r| {
        try buf.appendSlice(alloc, "  (subpath ");
        try writeSbplString(alloc, buf, r);
        try buf.appendSlice(alloc, ")\n");
    } else if (use_literal) {
        try buf.appendSlice(alloc, "  (literal ");
        try writeSbplString(alloc, buf, path);
        try buf.appendSlice(alloc, ")\n");
    }
    // 路径不存在且非 literal:跳过(无意义)
}

/// SBPL 字符串字面量:双引号包裹,转义 " 和 \。
fn writeSbplString(alloc: std.mem.Allocator, buf: *std.ArrayList(u8), s: []const u8) !void {
    try buf.append(alloc, '"');
    for (s) |c| {
        if (c == '"' or c == '\\') try buf.append(alloc, '\\');
        try buf.append(alloc, c);
    }
    try buf.append(alloc, '"');
}

/// ~/ → home;./ 或无前缀保留(caller 应已转绝对)。返回 owned 拷贝。
fn expandTilde(alloc: std.mem.Allocator, path: []const u8, home: []const u8) ![]u8 {
    if (std.mem.startsWith(u8, path, "~/") and home.len > 0) {
        return std.fmt.allocPrint(alloc, "{s}/{s}", .{ home, path[2..] });
    }
    if (std.mem.eql(u8, path, "~") and home.len > 0) {
        return alloc.dupe(u8, home);
    }
    return alloc.dupe(u8, path);
}

/// realpath via std.c.realpath。失败返 error。
fn realpathAlloc(alloc: std.mem.Allocator, path: []const u8) ![]u8 {
    var path_z: [std.fs.max_path_bytes]u8 = undefined;
    if (path.len + 1 > path_z.len) return error.PathTooLong;
    @memcpy(path_z[0..path.len], path);
    path_z[path.len] = 0;

    var out: [std.fs.max_path_bytes]u8 = undefined;
    const res = pfs.realpath(@ptrCast(&path_z), &out);
    if (res == null) return error.RealpathFailed;
    const resolved = std.mem.span(@as([*:0]u8, @ptrCast(res.?)));
    return alloc.dupe(u8, resolved);
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "generate: basic profile structure" {
    const cfg = SandboxConfig{ .cwd = "/tmp", .home = "/Users/foo" };
    const p = try generate(testing.allocator, cfg);
    defer testing.allocator.free(p);

    try testing.expect(std.mem.indexOf(u8, p, "(version 1)") != null);
    try testing.expect(std.mem.indexOf(u8, p, "(allow default)") != null);
    try testing.expect(std.mem.indexOf(u8, p, "(deny file-write*)") != null);
    try testing.expect(std.mem.indexOf(u8, p, "(allow file-write*") != null);
    // /tmp 应 realpath 成 /private/tmp
    try testing.expect(std.mem.indexOf(u8, p, "/private/tmp") != null);
}

test "generate: allowWrite + denyWrite + denyRead" {
    const cfg = SandboxConfig{
        .cwd = "/private/tmp",
        .home = "/Users/foo",
        .allow_write = &.{ "~/.kube", "/var/build" },
        .deny_write = &.{"/private/tmp/secret"},
        .deny_read = &.{"~/.ssh"},
    };
    const p = try generate(testing.allocator, cfg);
    defer testing.allocator.free(p);

    // ~/.kube 展开成 /Users/foo/.kube
    try testing.expect(std.mem.indexOf(u8, p, "/Users/foo/.kube") != null);
    // denyWrite 段存在
    try testing.expect(std.mem.indexOf(u8, p, "(deny file-write*\n  (subpath \"/private/tmp/secret\")") != null);
    // denyRead 段
    try testing.expect(std.mem.indexOf(u8, p, "(deny file-read*") != null);
    try testing.expect(std.mem.indexOf(u8, p, "/Users/foo/.ssh") != null);
}

test "writeSbplString escapes quotes and backslashes" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    try writeSbplString(testing.allocator, &buf, "a\"b\\c");
    try testing.expectEqualStrings("\"a\\\"b\\\\c\"", buf.items);
}

test "expandTilde" {
    const a = try expandTilde(testing.allocator, "~/.kube", "/home/u");
    defer testing.allocator.free(a);
    try testing.expectEqualStrings("/home/u/.kube", a);

    const b = try expandTilde(testing.allocator, "/abs/path", "/home/u");
    defer testing.allocator.free(b);
    try testing.expectEqualStrings("/abs/path", b);
}
