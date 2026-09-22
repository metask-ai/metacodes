//! 测试专用:文件系统链接的跨平台夹具。
//!
//! - `symlinkOrSkip`:Windows 上创建 symlink 需要 SeCreateSymbolicLinkPrivilege(或开发者模式);
//!   runner 拿不到就把用例标成 skip,而不是把"没特权"报成回归。其余平台照常创建。
//! - `junction`:NTFS junction(目录挂载点)不需要任何特权,是 Windows 安装最常见的链接形态
//!   (`mklink /J`),也是 #140 里 `_fullpath` 解不开的那种重解析点。
//!
//! 只从 `test` 块 `@import`,生产代码不得引用。

const std = @import("std");
const builtin = @import("builtin");

pub fn symlinkOrSkip(
    dir: std.Io.Dir,
    io: std.Io,
    target_path: []const u8,
    sym_link_path: []const u8,
    flags: std.Io.Dir.SymLinkFlags,
) !void {
    dir.symLink(io, target_path, sym_link_path, flags) catch |err| switch (err) {
        error.PermissionDenied, error.AccessDenied => return error.SkipZigTest,
        else => return err,
    };
}

/// `cmd.exe /c mklink /J <link> <target>`(cmd 内建;两个参数都改成反斜杠,mklink 不认正斜杠)。
/// 非 Windows 直接 skip——调用方通常已按平台门控。
pub fn junction(allocator: std.mem.Allocator, link: []const u8, target: []const u8) !void {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const process = @import("process.zig");
    const link_z = try allocator.dupeZ(u8, link);
    defer allocator.free(link_z);
    const target_z = try allocator.dupeZ(u8, target);
    defer allocator.free(target_z);
    for (link_z) |*c| if (c.* == '/') {
        c.* = '\\';
    };
    for (target_z) |*c| if (c.* == '/') {
        c.* = '\\';
    };
    const comspec: [*:0]const u8 = std.c.getenv("COMSPEC") orelse "cmd.exe";
    const argv = [_]?[*:0]const u8{ comspec, "/c", "mklink", "/J", link_z.ptr, target_z.ptr, null };
    const captured = try process.captureStdout(argv[0..], allocator, 30_000, 1 << 16);
    defer allocator.free(captured.stdout);
    defer allocator.free(captured.stderr);
    if (captured.exit_code != 0) return error.JunctionCreateFailed;
}
