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

/// 用户 home 目录。POSIX=$HOME；Windows=$HOME 优先（少见但尊重）否则 $USERPROFILE。
/// 返回 null=均未设（调用方决定 error.NoHome / 兜底）。
pub fn homeDir() ?[]const u8 {
    if (envNonEmpty("HOME")) |h| return h;
    if (is_windows) {
        if (envNonEmpty("USERPROFILE")) |u| return u;
    }
    return null;
}

/// 临时目录。POSIX=$TMPDIR or /tmp；Windows=$TEMP or $TMP or C:\Windows\Temp。
pub fn tempDir() []const u8 {
    if (is_windows) {
        return envNonEmpty("TEMP") orelse envNonEmpty("TMP") orelse "C:\\Windows\\Temp";
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

/// 本进程可执行文件绝对路径(**不依赖 argv[0]**,PATH 裸名启动也可靠)。写进 buf,返回 slice;
/// 失败/不支持平台 → null。macOS `_NSGetExecutablePath` / Linux `/proc/self/exe` /
/// Windows `GetModuleFileNameW`。消费方:swarm teammate fork-exec、KgClient vendored 定位。
pub fn selfExePath(buf: []u8) ?[]const u8 {
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
