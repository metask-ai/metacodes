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
