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

var dir_made: bool = false;

/// 返回 `<tempdir>/cc-zig-test-<pid>/<name>`(NUL 结尾,写进 buf)。首调时建 per-pid 目录。
/// **可移植**:tempDir POSIX=/tmp、Windows=TEMP(不再硬编码 /tmp);mkdirParents 建目录树。
/// buf 须够大(建议 512)。返回不含 NUL 的 slice;`ptr` 可直接喂 pfs.open。
pub fn path(buf: []u8, name: []const u8) [:0]const u8 {
    const pid = pprocess.currentPid();
    // 根的平台规则(POSIX /tmp、Windows %TEMP% 正斜杠)只在 util/fs.zig testing.tmpRoot 一处。
    var tmpbuf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp = @import("../util/fs.zig").testing.tmpRoot(&tmpbuf);
    if (!dir_made) {
        var dirbuf: [std.fs.max_path_bytes]u8 = undefined;
        const dpath = std.fmt.bufPrint(&dirbuf, "{s}/cc-zig-test-{d}", .{ tmp, pid }) catch return "";
        @import("../util/fs.zig").mkdirParents(dpath) catch {}; // 已存在/建成都无害
        dir_made = true;
    }
    return std.fmt.bufPrintZ(buf, "{s}/cc-zig-test-{d}/{s}", .{ tmp, pid, name }) catch unreachable;
}

/// 返回 per-pid 临时目录 `<tempdir>/cc-zig-test-<pid>`(NUL 结尾,写进 buf,可移植正斜杠)。
/// 供需要"目录本身"的测试用(如 Read ~ 展开把 home 设成它)。首调建目录。
pub fn dir(buf: []u8) [:0]const u8 {
    var b: [512]u8 = undefined;
    _ = path(&b, "."); // 触发建目录
    const pid = pprocess.currentPid();
    var tmpbuf: [std.fs.max_path_bytes]u8 = undefined;
    const tmp = @import("../util/fs.zig").testing.tmpRoot(&tmpbuf);
    return std.fmt.bufPrintZ(buf, "{s}/cc-zig-test-{d}", .{ tmp, pid }) catch unreachable;
}

/// 反斜杠 → 正斜杠(原地改写,返回同一 slice)。
///
/// 用 `std.testing.tmpDir` + `realPath` 取 fixture 根的测试拿到的是原生路径,Windows 上
/// 含反斜杠。照原样插进 JSON 字符串字面量时,\t / \p 会被当成 JSON 转义序列,解析
/// 出来的 file_path 被破坏 → 写入失败或 stat 落空。Windows API 同样接受正斜杠,所以归一
/// 后既能嵌 JSON 也照常访问文件——与本模块 `path()` 对 TEMP 的处理是同一条纪律。
pub fn normalizeSlashes(s: []u8) []const u8 {
    for (s) |*c| {
        if (c.* == '\\') c.* = '/';
    }
    return s;
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
