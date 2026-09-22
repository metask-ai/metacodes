//! W5 可移植路径/环境（跨平台移植 roadmap，tinykg node 8870）。
//!
//! POSIX 特有的路径/环境常量在 Windows 上不同：
//! - null 设备：`/dev/null` → `NUL`
//! - home：`$HOME` → `$USERPROFILE`（Windows 不设 HOME）
//! - 临时目录：`$TMPDIR` or `/tmp` → `$TEMP` / `$TMP`
//!
//! `std.c.getenv` 本身在 windows-gnu(MSVCRT getenv)可编译，故直接 getenv("HOME") 不是**编译**
//! 阻塞，但在 Windows 上返回 null（HOME 未设）= 运行时行为错误。本模块提供带正确回退的中立入口。

const std = @import("std");
const builtin = @import("builtin");

const is_windows = builtin.os.tag == .windows;

/// null 设备路径（丢弃写入的目标，如子进程 stderr 重定向）。
pub const null_device: [*:0]const u8 = if (is_windows) "NUL" else "/dev/null";

// shell 选择已移到 core/shell.zig(复刻 codex 三层策略:Windows 用系统自带 PowerShell/cmd,
// 零 git-bash)。此前的 shell_path="sh" 依赖 git-bash,已退役。

fn envNonEmpty(name: [*:0]const u8) ?[]const u8 {
    const v = std.c.getenv(name) orelse return null;
    const s = std.mem.span(v);
    return if (s.len > 0) s else null;
}

// Windows 环境块是 UTF-16;窄字符 `getenv` 给的是按进程 ANSI 代码页转过的字节,中文用户名下
// (`C:\Users\张三`)不是 UTF-8——喂给 platform/fs 的宽字符入口会被当成非法 UTF-8 拒掉,而
// 从前的窄字符 `_open`/`_mkdir` 恰好用同一个代码页解回去,所以"看起来能用"。这里改从
// `GetEnvironmentVariableW` 读、转成 UTF-8 写进**每个公开函数自己的静态缓冲**(#121 输入侧)。
// 静态缓冲:homeDir/tempDir 的返回值被调用方长期持有(App 配置),不能借用栈;每次调用都重新
// 读环境(测试会 setEnv 后再调),并发调用写入同样的字节,无害。
var home_utf8: if (is_windows) [std.fs.max_path_bytes]u8 else void = undefined;
var temp_utf8: if (is_windows) [std.fs.max_path_bytes]u8 else void = undefined;

fn envNonEmptyW(name: [*:0]const u16, out: []u8) ?[]const u8 {
    var wbuf: [std.os.windows.PATH_MAX_WIDE + 1]u16 = undefined;
    const n = GetEnvironmentVariableW(name, &wbuf, wbuf.len);
    if (n == 0 or n >= wbuf.len) return null;
    if (out.len < @as(usize, n) * 3) return null; // utf16LeToUtf8 不做输出边界检查
    const len = std.unicode.utf16LeToUtf8(out, wbuf[0..n]) catch return null;
    return if (len > 0) out[0..len] else null;
}
extern "kernel32" fn GetEnvironmentVariableW(lpName: [*:0]const u16, lpBuffer: [*]u16, nSize: u32) callconv(.winapi) u32;

/// 用户 home 目录。POSIX=$HOME;Windows=$HOME 优先(少见但尊重)否则 $USERPROFILE,UTF-8。
/// 返回 null=均未设(调用方决定 error.NoHome / 兜底)。
pub fn homeDir() ?[]const u8 {
    if (is_windows) {
        if (envNonEmptyW(std.unicode.utf8ToUtf16LeStringLiteral("HOME"), &home_utf8)) |h| return h;
        if (envNonEmptyW(std.unicode.utf8ToUtf16LeStringLiteral("USERPROFILE"), &home_utf8)) |u| return u;
        return null;
    }
    return envNonEmpty("HOME");
}

/// 临时目录。POSIX=$TMPDIR or /tmp;Windows=$TEMP or $TMP or C:\Windows\Temp,UTF-8。
pub fn tempDir() []const u8 {
    if (is_windows) {
        return envNonEmptyW(std.unicode.utf8ToUtf16LeStringLiteral("TEMP"), &temp_utf8) orelse
            envNonEmptyW(std.unicode.utf8ToUtf16LeStringLiteral("TMP"), &temp_utf8) orelse
            "C:\\Windows\\Temp";
    }
    return envNonEmpty("TMPDIR") orelse "/tmp";
}

test "homeDir 在 POSIX 返回 $HOME（测试环境设了 HOME）" {
    if (is_windows) return;
    // CI/本地测试环境 HOME 一般有值；若无则跳过断言（不制造假失败）。
    if (homeDir()) |h| {
        try std.testing.expect(h.len > 0);
    }
}

// 进程环境变量写入(主要测试用:设/清一个 env 再验行为)。POSIX setenv/unsetenv;
// Windows msvcrt _putenv_s(name,value)(空 value = 删除)。
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;
extern "c" fn _putenv_s(name: [*:0]const u8, value: [*:0]const u8) c_int;

pub fn setEnv(name: [*:0]const u8, value: [*:0]const u8) void {
    if (is_windows) {
        _ = _putenv_s(name, value);
    } else {
        _ = setenv(name, value, 1);
    }
}

pub fn unsetEnv(name: [*:0]const u8) void {
    _ = unsetEnvChecked(name);
}

/// 删除一个环境变量并报告 libc/MSVCRT 是否接受了操作。
///
/// 凭证等安全边界不能沿用 `unsetEnv` 的 best-effort 语义：若删除失败，调用方必须
/// fail closed，而不是继续启动会继承父环境的工具子进程。
pub fn unsetEnvChecked(name: [*:0]const u8) bool {
    if (is_windows) {
        return _putenv_s(name, "") == 0; // 空值 = 删除
    } else {
        return unsetenv(name) == 0;
    }
}

/// 测试 seam(仅测试构建存在;生产构建为 void,不可误用):把 `selfExePath` 观测到的
/// **被调用路径**替换成任意值,用来在进程内复现"经别处 symlink 启动"——macOS 的
/// `_NSGetExecutablePath` 返回的就是 symlink 自身,而 zig 测试二进制永远从真路径起。
/// 串行 test runner 内设置后必须 defer 复位为 null。
pub var test_self_exe_override: if (builtin.is_test) ?[]const u8 else void =
    if (builtin.is_test) null else {};

/// 本进程可执行文件的**被调用路径**(**不依赖 argv[0]**,PATH 裸名启动也可靠)。写进 buf,
/// 返回 slice;失败/不支持平台 → null。macOS `_NSGetExecutablePath` / Linux `/proc/self/exe` /
/// Windows `GetModuleFileNameW`。
///
/// **不解 symlink**:`ln -s <prefix>/bin/metacodes ~/bin/metacodes` 安装后,macOS 返回的是
/// `~/bin/metacodes`(Linux 的 /proc/self/exe 已由内核解好)。凡是要从自身位置推导相邻
/// 产物(bin/rg、libexec/metacodes/<kernel>、vendor/tinykg)的,必须用 `selfExeRealPath`;
/// 本函数只给"再次执行自己"这类不关心物理位置的消费方(swarm teammate fork-exec)。
pub fn selfExePath(buf: []u8) ?[]const u8 {
    if (comptime builtin.is_test) {
        if (test_self_exe_override) |forced| {
            if (forced.len >= buf.len) return null;
            @memcpy(buf[0..forced.len], forced);
            return buf[0..forced.len];
        }
    }
    switch (builtin.os.tag) {
        .macos, .ios => {
            var size: u32 = @intCast(buf.len);
            if (_NSGetExecutablePath(buf.ptr, &size) != 0) return null;
            const len = std.mem.indexOfScalar(u8, buf[0..@min(buf.len, size + 1)], 0) orelse return null;
            return buf[0..len];
        },
        .linux => {
            const n = std.c.readlink("/proc/self/exe", buf.ptr, buf.len);
            if (n <= 0) return null;
            // 恰好塞满 = 可能被截断(readlink 不补 NUL 也不报错)→ 拒绝,勿返回截断路径。
            if (@as(usize, @intCast(n)) >= buf.len) return null;
            return buf[0..@intCast(n)];
        },
        .windows => {
            var wbuf: [4096]u16 = undefined;
            const n = GetModuleFileNameW(null, &wbuf, wbuf.len);
            if (n == 0 or n >= wbuf.len) return null;
            // utf16LeToUtf8 不做输出边界检查(见 platform/dir.zig 同款注释):先保证最坏 3x 放得下。
            if (buf.len < @as(usize, n) * 3) return null;
            const len = std.unicode.utf16LeToUtf8(buf, wbuf[0..n]) catch return null;
            return buf[0..len];
        },
        else => return null,
    }
}
extern "c" fn _NSGetExecutablePath(buf: [*]u8, size: *u32) c_int;

/// 本进程可执行文件的**物理路径**:`selfExePath` 再经 `fs.finalPath` 解 symlink/junction 与 `.`/`..`
/// (Windows 走 CreateFileW + GetFinalPathNameByHandleW,#140;`fs.realpath` 在 Windows 是词法的,解不开)。
/// 相邻产物定位(toolchain 的 rg / Lean kernel、KgClient 的 vendored tinykg)的唯一入口——
/// 三处解析器共用此函数,不再各自决定要不要解 symlink(2026-09-21 实测:经 ~/bin symlink
/// 启动的 release 布局,rg 与两个 kernel 落到 ~/bin 找不到,只有已 realpath 的 tinykg 命中)。
///
/// 被调用路径必须是**绝对路径**,否则直接返回 null、连 realpath 都不做:相对路径在进程 chdir
/// 之后(swarm `--teammate` 进 worktree)会被按新 cwd 解释——POSIX realpath 失败、Windows
/// `_fullpath` 则"成功"地补全成一个错误的绝对路径——相邻查找就可能捡到别的目录里的 rg /
/// kernel,那比 unresolved 更糟(Codex review 2026-09-21;Windows CI 抓到 `_fullpath` 那一半)。
/// 三个 OS 的 selfExePath 生产实现都返回绝对路径,这条只防测试注入与未来的实现漂移。
///
/// finalPath 失败(路径被删、权限)时**回退到被调用路径**而不是返回 null:退化成旧行为,不让
/// 一次解析故障把所有相邻产物变成 unresolved。selfExePath 本身失败也返回 null。
/// 写进 buf,返回 slice。
pub fn selfExeRealPath(buf: []u8) ?[]const u8 {
    var invoked: [std.fs.max_path_bytes + 1]u8 = undefined;
    const invoked_slice = selfExePath(invoked[0 .. invoked.len - 1]) orelse return null;
    if (!std.fs.path.isAbsolute(invoked_slice)) return null;
    invoked[invoked_slice.len] = 0;
    var resolved_buf: [std.fs.max_path_bytes]u8 = undefined;
    const resolved: []const u8 = if (@import("fs.zig").finalPath(invoked[0..invoked_slice.len :0], &resolved_buf)) |r|
        std.mem.span(r)
    else
        invoked_slice;
    if (resolved.len >= buf.len) return null;
    @memcpy(buf[0..resolved.len], resolved);
    return buf[0..resolved.len];
}
extern "kernel32" fn GetModuleFileNameW(hModule: ?*anyopaque, lpFilename: [*]u16, nSize: u32) callconv(.winapi) u32;

/// 当前用户 id。POSIX getuid;Windows 无 uid 概念 → 用 GetCurrentProcessId 做进程私有目录
/// 区分符(job 落盘目录仅需一个每进程/每用户稳定隔离前缀,非安全边界)。
pub fn uid() u32 {
    if (is_windows) return GetCurrentProcessId();
    return std.c.getuid();
}
extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;

test "null_device 平台正确" {
    const nd = std.mem.span(null_device);
    if (is_windows) {
        try std.testing.expectEqualStrings("NUL", nd);
    } else {
        try std.testing.expectEqualStrings("/dev/null", nd);
    }
}

test "tempDir 非空" {
    try std.testing.expect(tempDir().len > 0);
}

test "Windows: homeDir/tempDir come back as UTF-8 for a CJK environment value" {
    // #121 输入侧:环境值经 SetEnvironmentVariableW 以 UTF-16 写入(绕开窄字符 _putenv 的
    // 代码页转换),读回必须是 UTF-8 的精确字节,而不是 ANSI 代码页字节。
    if (!is_windows) return error.SkipZigTest;
    const name_w = std.unicode.utf8ToUtf16LeStringLiteral("HOME");
    var saved: [std.os.windows.PATH_MAX_WIDE + 1]u16 = undefined;
    const saved_len = GetEnvironmentVariableW(name_w, &saved, saved.len);
    if (saved_len < saved.len) saved[saved_len] = 0;
    defer _ = SetEnvironmentVariableW(name_w, if (saved_len == 0) null else @ptrCast(&saved));

    const value = "C:\\Users\\张三";
    try std.testing.expect(SetEnvironmentVariableW(name_w, std.unicode.utf8ToUtf16LeStringLiteral(value)) != 0);
    try std.testing.expectEqualStrings(value, homeDir().?);

    const temp_w = std.unicode.utf8ToUtf16LeStringLiteral("TEMP");
    var saved_temp: [std.os.windows.PATH_MAX_WIDE + 1]u16 = undefined;
    const saved_temp_len = GetEnvironmentVariableW(temp_w, &saved_temp, saved_temp.len);
    if (saved_temp_len < saved_temp.len) saved_temp[saved_temp_len] = 0;
    defer _ = SetEnvironmentVariableW(temp_w, if (saved_temp_len == 0) null else @ptrCast(&saved_temp));
    try std.testing.expect(SetEnvironmentVariableW(temp_w, std.unicode.utf8ToUtf16LeStringLiteral("C:\\Users\\张三\\临时")) != 0);
    try std.testing.expectEqualStrings("C:\\Users\\张三\\临时", tempDir());
}
extern "kernel32" fn SetEnvironmentVariableW(lpName: [*:0]const u16, lpValue: ?[*:0]const u16) callconv(.winapi) c_int;

test "selfExeRealPath resolves a symlinked invocation to the physical executable" {
    // Windows 也跑:realpath 现在经句柄解析 symlink/junction(#140)。runner 没有 symlink 特权时
    // 由 symlinkOrSkip 标成 skip;junction 形态由下一个用例覆盖(不需特权)。
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "prefix/bin");
    try tmp.dir.createDirPath(io, "elsewhere");
    try tmp.dir.writeFile(io, .{ .sub_path = "prefix/bin/metacodes", .data = "#!/bin/sh\n" });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(io, &root_buf)];
    // 物理路径的期望值来自 std(Windows 走 NT 宽字符 API + GetFinalPathNameByHandle),不是被测函数自己。
    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
    const real = real_buf[0..try tmp.dir.realPathFile(io, "prefix/bin/metacodes", &real_buf)];
    try @import("test_support.zig").symlinkOrSkip(tmp.dir, io, real, "elsewhere/metacodes", .{});
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    const link = try std.fmt.bufPrint(&link_buf, "{s}/elsewhere/metacodes", .{root});

    test_self_exe_override = link;
    defer test_self_exe_override = null;
    var raw_buf: [std.fs.max_path_bytes]u8 = undefined;
    try std.testing.expectEqualStrings(link, selfExePath(&raw_buf).?);
    var out: [std.fs.max_path_bytes]u8 = undefined;
    try std.testing.expectEqualStrings(real, selfExeRealPath(&out).?);
}

test "selfExeRealPath resolves an invocation through an NTFS junction to the physical executable" {
    // #140 的常见安装形态:`mklink /J`(目录挂载点,不需要特权)。`_fullpath` 是纯词法的,解不开它。
    if (!is_windows) return error.SkipZigTest;
    const io = std.testing.io;
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "prefix/bin");
    try tmp.dir.writeFile(io, .{ .sub_path = "prefix/bin/metacodes.exe", .data = "MZ" });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(io, &root_buf)];
    var real_buf: [std.fs.max_path_bytes]u8 = undefined;
    const real = real_buf[0..try tmp.dir.realPathFile(io, "prefix/bin/metacodes.exe", &real_buf)];
    const junction = try std.fmt.allocPrint(a, "{s}\\elsewhere_j", .{root});
    defer a.free(junction);
    const target = try std.fmt.allocPrint(a, "{s}\\prefix", .{root});
    defer a.free(target);
    try @import("test_support.zig").junction(a, junction, target);
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    const link = try std.fmt.bufPrint(&link_buf, "{s}\\elsewhere_j\\bin\\metacodes.exe", .{root});

    test_self_exe_override = link;
    defer test_self_exe_override = null;
    var out: [std.fs.max_path_bytes]u8 = undefined;
    const resolved = selfExeRealPath(&out).?;
    try std.testing.expectEqualStrings(real, resolved);
    try std.testing.expect(std.mem.indexOf(u8, resolved, "elsewhere_j") == null);
}

test "selfExeRealPath falls back to the invoked path when realpath fails" {
    // 被调用路径已不存在(安装被删/权限)→ finalPath 失败 → 退回原值,而不是 null。
    const ghost = if (is_windows) "C:\\definitely-missing-metacodes-xyzzy\\bin\\metacodes.exe" else "/definitely-missing-metacodes-xyzzy/bin/metacodes";
    test_self_exe_override = ghost;
    defer test_self_exe_override = null;
    var out: [std.fs.max_path_bytes]u8 = undefined;
    try std.testing.expectEqualStrings(ghost, selfExeRealPath(&out).?);
}

test "selfExeRealPath refuses a relative invoked path before consulting realpath" {
    // 相对路径 = 会随 cwd 漂移的基准 → null。**不能**靠解析失败来拒:Windows 词法 `_wfullpath`
    // 对相对路径会成功补全(CI 2026-09-21 实证),所以先看 isAbsolute。存在的相对路径也一样拒。
    const ghost = if (is_windows) "bin\\definitely-missing-metacodes-xyzzy.exe" else "bin/definitely-missing-metacodes-xyzzy";
    test_self_exe_override = ghost;
    defer test_self_exe_override = null;
    var out: [std.fs.max_path_bytes]u8 = undefined;
    try std.testing.expect(selfExeRealPath(&out) == null);
    // 存在的相对路径(build.zig 在仓库根;测试 cwd = 构建根)同样拒绝,证明拒的是"相对",不是"缺席"。
    test_self_exe_override = "build.zig";
    try std.testing.expect(selfExeRealPath(&out) == null);
}

test "selfExeRealPath of the real test binary is an existing absolute path" {
    var out: [std.fs.max_path_bytes]u8 = undefined;
    const p = selfExeRealPath(&out) orelse return error.SkipZigTest;
    try std.testing.expect(std.fs.path.isAbsolute(p));
    var z: [std.fs.max_path_bytes + 1]u8 = undefined;
    @memcpy(z[0..p.len], p);
    z[p.len] = 0;
    try std.testing.expect(@import("fs.zig").exists(z[0..p.len :0]));
}
