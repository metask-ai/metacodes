//! 测试用临时路径 helper:每进程唯一目录,避免并发 test artifact 撞同一固定 /tmp 路径。
//!
//! 背景:工具单测(grep/write/edit/...)曾写死 `/tmp/cc-zig-<name>` 固定路径。两个 test
//! 二进制(test:lib + test:new,或同文件被编进多个 artifact)并发跑时,A 的 open(TRUNC)/
//! unlink 与 B 的 read 撞车 → 间歇 flaky(已证 pre-existing:孤立跑 0 失败,并发间歇失败)。
//!
//! 修法:所有 fixture 路径前缀 `/tmp/cc-zig-test-<pid>/`——pid 每 test 进程唯一,并发 artifact
//! 各用各的目录,物理隔离。本 helper 提供 path() 拼路径(首调时 mkdir 该目录)。

const std = @import("std");
const pprocess = @import("platform").process;
const pfs = @import("platform").fs;
const ppaths = @import("platform").paths;

var dir_made: bool = false;

/// 返回 `<tempdir>/cc-zig-test-<pid>/<name>`(NUL 结尾,写进 buf)。首调时建 per-pid 目录。
/// **可移植**:tempDir POSIX=/tmp、Windows=TEMP(不再硬编码 /tmp);mkdirParents 建目录树。
/// buf 须够大(建议 512)。返回不含 NUL 的 slice;`ptr` 可直接喂 pfs.open。
pub fn path(buf: []u8, name: []const u8) [:0]const u8 {
    const pid = pprocess.currentPid();
    // POSIX 保持 "/tmp" 不变(macOS $TMPDIR≠/tmp,独立拼 /tmp/... 的测试如 read home_dir 会
    // 撞不上);仅 Windows 用 TEMP(无 /tmp)。tempDir 归一正斜杠(Windows 也认 '/',嵌 JSON 免转义)。
    var tmpbuf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp = if (@import("builtin").os.tag == .windows) fwd(&tmpbuf, ppaths.tempDir()) else "/tmp";
    if (!dir_made) {
        var dirbuf: [std.fs.max_path_bytes]u8 = undefined;
        const dir = std.fmt.bufPrint(&dirbuf, "{s}/cc-zig-test-{d}", .{ tmp, pid }) catch return "";
        @import("../util/fs.zig").mkdirParents(dir) catch {}; // 已存在/建成都无害
        dir_made = true;
    }
    return std.fmt.bufPrintZ(buf, "{s}/cc-zig-test-{d}/{s}", .{ tmp, pid, name }) catch unreachable;
}

/// 反斜杠 → 正斜杠(拷进 out,返回 slice)。
fn fwd(out: []u8, s: []const u8) []const u8 {
    const n = @min(s.len, out.len);
    for (s[0..n], 0..) |c, i| out[i] = if (c == '\\') '/' else c;
    return out[0..n];
}

test "path: per-pid 唯一目录 + 可建文件" {
    var b: [512]u8 = undefined;
    const p = path(&b, "helper-selftest.txt");
    try std.testing.expect(std.mem.indexOf(u8, p, "cc-zig-test-") != null);
    const fd = pfs.open(p.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    try std.testing.expect(fd >= 0);
    _ = pfs.close(fd);
    _ = std.c.unlink(p.ptr);
}
