//! W4 可移植信号/中断（跨平台移植 roadmap，tinykg node 8869）。
//!
//! POSIX 用 `std.posix.sigaction`；Windows 无 POSIX 信号，改用：
//! - broken-pipe：Windows 无 SIGPIPE（socket 写返 WSAECONNRESET，各处 n<=0 分支已处理）→ no-op。
//! - Ctrl+C：`SetConsoleCtrlHandler`（CTRL_C_EVENT / CTRL_BREAK_EVENT）。
//! - 窗口 resize：Windows 无 SIGWINCH；resize 走 ConsoleInput 的 WINDOW_BUFFER_SIZE_EVENT
//!   （归 W4 终端模块）→ 此处 no-op（登记）。
//!
//! 中立 API 收 async-signal-safe 无副作用回调（只做 atomic store / abort）。POSIX 的
//! `std.posix.SIG` 签名细节锁在本模块的 comptime 分支内（comptime-known `is_windows` 使
//! Zig 惰性只分析选中分支，未选分支的 `std.c.*`/`std.posix.*` 不会在异平台被分析——已由
//! platform/fs.zig 交叉编译证实）。

const std = @import("std");
const builtin = @import("builtin");

const is_windows = builtin.os.tag == .windows;
const win = std.os.windows;

/// 忽略 broken-pipe（向已关闭 pipe/socket 写不杀进程）。Windows no-op。
pub fn ignoreBrokenPipe() void {
    if (is_windows) return;
    var act: std.posix.Sigaction = .{
        .handler = .{ .handler = std.posix.SIG.IGN },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.PIPE, &act, null);
}

// ── Windows console ctrl handler（kernel32 未在 std 绑定，自 extern）─────────────
const CTRL_C_EVENT: win.DWORD = 0;
const CTRL_BREAK_EVENT: win.DWORD = 1;
extern "kernel32" fn SetConsoleCtrlHandler(
    HandlerRoutine: ?*const fn (win.DWORD) callconv(.winapi) win.BOOL,
    Add: win.BOOL,
) callconv(.winapi) win.BOOL;

/// 安装 Ctrl+C（中断）回调。POSIX=SIGINT sigaction；Windows=SetConsoleCtrlHandler。
/// `callback` 必须 async-signal-safe（POSIX 在信号上下文调用；Windows 在独立 handler 线程）。
pub fn installInterrupt(comptime callback: fn () void) void {
    if (is_windows) {
        const W = struct {
            fn ctrl(ctrl_type: win.DWORD) callconv(.winapi) win.BOOL {
                if (ctrl_type == CTRL_C_EVENT or ctrl_type == CTRL_BREAK_EVENT) {
                    callback();
                    return win.TRUE;
                }
                return win.FALSE;
            }
        };
        _ = SetConsoleCtrlHandler(W.ctrl, win.TRUE);
    } else {
        const P = struct {
            fn h(_: std.posix.SIG) callconv(.c) void {
                callback();
            }
        };
        var act: std.posix.Sigaction = .{
            .handler = .{ .handler = P.h },
            .mask = std.posix.sigemptyset(),
            .flags = 0,
        };
        std.posix.sigaction(std.posix.SIG.INT, &act, null);
    }
}

/// 安装窗口 resize 回调。POSIX=SIGWINCH sigaction；Windows no-op（resize 归 W4 终端 ConsoleInput）。
pub fn installResize(comptime callback: fn () void) void {
    if (is_windows) return; // TODO(W4)：WINDOW_BUFFER_SIZE_EVENT via ReadConsoleInput
    const P = struct {
        fn h(_: std.posix.SIG) callconv(.c) void {
            callback();
        }
    };
    var act: std.posix.Sigaction = .{
        .handler = .{ .handler = P.h },
        .mask = std.posix.sigemptyset(),
        .flags = 0,
    };
    std.posix.sigaction(std.posix.SIG.WINCH, &act, null);
}
