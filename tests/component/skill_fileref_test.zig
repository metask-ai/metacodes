//! L2 组件测试:Skill body 的 @path 文件注入(对齐 Claude Code memory @include)。
//!
//! 验证(端到端走 cc.skills_render.renderBody):
//!  - @relative 锚 skill_dir 注入文件内容
//!  - @"quoted path" 含空格
//!  - 不存在 → 字面保留(不破坏渲染)
//!  - 安全边界:@/绝对 或 @../ 逃出 skill/project dir → 拒读保留字面(防 @/etc/passwd 越界)
//!  - 邮箱式 mid-line @(紧跟非空白)不识别
//!
//! 通过 cc 模块导入,跑 `zig build test:new`(绕开主 cc-test 套件已知 integration 挂起)。

const std = @import("std");
const cc = @import("cc");
const pfs = @import("platform").fs; // 可移植文件 IO(std.c.open 的 O 在 Windows 是 void)

const render = cc.skills_render;

// 每进程唯一的 fixture 目录 `<tmp>/cc-zig-fr-l2-<pid>`(util/fs.zig testing.tmpRoot 定平台规则)。
// 8 个分片进程并行跑本文件的不同用例,共用一个固定目录会互相踩。每个建目录的用例
// 自己 `defer rmdir`,不往 /tmp 里留东西。
var base_buf: [512]u8 = undefined;
var base_len: usize = 0;

fn base() [:0]const u8 {
    if (base_len == 0) base_len = cc.util_fs.testing.perPidDir(&base_buf, "cc-zig-fr-l2").len;
    return base_buf[0..base_len :0];
}

/// `<base>/<name>`,NUL 结尾写进 buf。
fn sub(buf: []u8, name: []const u8) [:0]const u8 {
    return std.fmt.bufPrintZ(buf, "{s}/{s}", .{ base(), name }) catch unreachable;
}

fn writeTmp(path: [*:0]const u8, content: []const u8) void {
    const fd = pfs.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, 0o644);
    if (fd < 0) return;
    defer pfs.close(fd);
    _ = pfs.write(fd, content);
}

test "L2 fileref: @relative inlines content anchored to skill_dir" {
    const a = std.testing.allocator;
    _ = std.c.mkdir(base().ptr, 0o755);
    defer _ = std.c.rmdir(base().ptr);
    var nb: [512]u8 = undefined;
    const note = sub(&nb, "note.md");
    writeTmp(note.ptr, "NOTE BODY");
    defer _ = std.c.unlink(note.ptr);

    const out = try render.renderBody(a, "see @note.md here", .{ .skill_dir = base() });
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "see NOTE BODY here") != null);
}

test "L2 fileref: @\"quoted\" with spaces" {
    const a = std.testing.allocator;
    _ = std.c.mkdir(base().ptr, 0o755);
    defer _ = std.c.rmdir(base().ptr);
    var sb: [512]u8 = undefined;
    const spaced = sub(&sb, "a b.txt");
    writeTmp(spaced.ptr, "SPACED");
    defer _ = std.c.unlink(spaced.ptr);

    const out = try render.renderBody(a, "x @\"a b.txt\" y", .{ .skill_dir = base() });
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "x SPACED y") != null);
}

test "L2 fileref: missing file keeps literal" {
    const a = std.testing.allocator;
    const out = try render.renderBody(a, "ref @nope.md done", .{ .skill_dir = base() });
    defer a.free(out);
    try std.testing.expectEqualStrings("ref @nope.md done", out);
}

test "L2 fileref: @/absolute outside boundary refused" {
    const a = std.testing.allocator;
    const out = try render.renderBody(a, "leak @/etc/hosts end", .{ .skill_dir = base(), .project_dir = base() });
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "@/etc/hosts") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "localhost") == null);
}

test "L2 fileref: @../ escape refused" {
    const a = std.testing.allocator;
    _ = std.c.mkdir(base().ptr, 0o755);
    defer _ = std.c.rmdir(base().ptr);
    var subdir_buf: [512]u8 = undefined;
    const subdir = sub(&subdir_buf, "sub");
    _ = std.c.mkdir(subdir.ptr, 0o755);
    defer _ = std.c.rmdir(subdir.ptr);
    var secret_buf: [512]u8 = undefined;
    const secret = sub(&secret_buf, "secret.md");
    writeTmp(secret.ptr, "SECRET");
    defer _ = std.c.unlink(secret.ptr);

    const out = try render.renderBody(a, "x @../secret.md y", .{ .skill_dir = subdir });
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "@../secret.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "SECRET") == null);
}

test "L2 fileref: email-like mid-line @ not recognized" {
    const a = std.testing.allocator;
    const out = try render.renderBody(a, "mail foo@bar.com please", .{ .skill_dir = base() });
    defer a.free(out);
    try std.testing.expectEqualStrings("mail foo@bar.com please", out);
}
