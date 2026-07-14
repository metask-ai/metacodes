//! 测试用临时路径 helper:每进程唯一目录,避免并发 test artifact 撞同一固定 /tmp 路径。
//!
//! 背景:工具单测(grep/write/edit/...)曾写死 `/tmp/cc-zig-<name>` 固定路径。两个 test
//! 二进制(test:lib + test:new,或同文件被编进多个 artifact)并发跑时,A 的 open(TRUNC)/
//! unlink 与 B 的 read 撞车 → 间歇 flaky(已证 pre-existing:孤立跑 0 失败,并发间歇失败)。
//!
//! 修法:所有 fixture 路径前缀 `/tmp/cc-zig-test-<pid>/`——pid 每 test 进程唯一,并发 artifact
//! 各用各的目录,物理隔离。本 helper 提供 path() 拼路径(首调时 mkdir 该目录)。

const std = @import("std");
const pfs = @import("platform").fs;

var dir_made: bool = false;

/// 返回 `/tmp/cc-zig-test-<pid>/<name>`(NUL 结尾,写进 buf)。首调时建 per-pid 目录。
/// buf 须够大(建议 256)。返回不含 NUL 的 slice;`ptr` 可直接喂 std.c.open。
pub fn path(buf: []u8, name: []const u8) [:0]const u8 {
    const pid = std.c.getpid();
    var dirbuf: [128]u8 = undefined;
    const dir = std.fmt.bufPrintZ(&dirbuf, "/tmp/cc-zig-test-{d}", .{pid}) catch unreachable;
    if (!dir_made) {
        _ = std.c.mkdir(dir.ptr, 0o755); // 已存在则 EEXIST,无害
        dir_made = true;
    }
    return std.fmt.bufPrintZ(buf, "/tmp/cc-zig-test-{d}/{s}", .{ pid, name }) catch unreachable;
}

test "path: per-pid 唯一目录 + 可建文件" {
    var b: [256]u8 = undefined;
    const p = path(&b, "helper-selftest.txt");
    try std.testing.expect(std.mem.indexOf(u8, p, "/tmp/cc-zig-test-") != null);
    const fd = pfs.open(p.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    try std.testing.expect(fd >= 0);
    _ = pfs.close(fd);
    _ = std.c.unlink(p.ptr);
}
