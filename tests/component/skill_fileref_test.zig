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

const render = cc.skills_render;

fn writeTmp(path: [*:0]const u8, content: []const u8) void {
    const fd = std.c.open(path, std.c.O{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    if (fd < 0) return;
    defer _ = std.c.close(fd);
    _ = std.c.write(fd, content.ptr, content.len);
}

test "L2 fileref: @relative inlines content anchored to skill_dir" {
    const a = std.testing.allocator;
    _ = std.c.mkdir("/tmp/cc-zig-fr-l2", 0o755);
    writeTmp("/tmp/cc-zig-fr-l2/note.md", "NOTE BODY");
    defer _ = std.c.unlink("/tmp/cc-zig-fr-l2/note.md");

    const out = try render.renderBody(a, "see @note.md here", .{ .skill_dir = "/tmp/cc-zig-fr-l2" });
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "see NOTE BODY here") != null);
}

test "L2 fileref: @\"quoted\" with spaces" {
    const a = std.testing.allocator;
    _ = std.c.mkdir("/tmp/cc-zig-fr-l2", 0o755);
    writeTmp("/tmp/cc-zig-fr-l2/a b.txt", "SPACED");
    defer _ = std.c.unlink("/tmp/cc-zig-fr-l2/a b.txt");

    const out = try render.renderBody(a, "x @\"a b.txt\" y", .{ .skill_dir = "/tmp/cc-zig-fr-l2" });
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "x SPACED y") != null);
}

test "L2 fileref: missing file keeps literal" {
    const a = std.testing.allocator;
    const out = try render.renderBody(a, "ref @nope.md done", .{ .skill_dir = "/tmp/cc-zig-fr-l2" });
    defer a.free(out);
    try std.testing.expectEqualStrings("ref @nope.md done", out);
}

test "L2 fileref: @/absolute outside boundary refused" {
    const a = std.testing.allocator;
    const out = try render.renderBody(a, "leak @/etc/hosts end", .{ .skill_dir = "/tmp/cc-zig-fr-l2", .project_dir = "/tmp/cc-zig-fr-l2" });
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "@/etc/hosts") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "localhost") == null);
}

test "L2 fileref: @../ escape refused" {
    const a = std.testing.allocator;
    _ = std.c.mkdir("/tmp/cc-zig-fr-l2", 0o755);
    _ = std.c.mkdir("/tmp/cc-zig-fr-l2/sub", 0o755);
    writeTmp("/tmp/cc-zig-fr-l2/secret.md", "SECRET");
    defer _ = std.c.unlink("/tmp/cc-zig-fr-l2/secret.md");

    const out = try render.renderBody(a, "x @../secret.md y", .{ .skill_dir = "/tmp/cc-zig-fr-l2/sub" });
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "@../secret.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "SECRET") == null);
}

test "L2 fileref: email-like mid-line @ not recognized" {
    const a = std.testing.allocator;
    const out = try render.renderBody(a, "mail foo@bar.com please", .{ .skill_dir = "/tmp/cc-zig-fr-l2" });
    defer a.free(out);
    try std.testing.expectEqualStrings("mail foo@bar.com please", out);
}
