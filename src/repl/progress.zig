//! TUI 工具执行进度显示(子进程长命令"仍在运行"心跳)。
//!
//! 触发点:tools/common.zig 的 spawn 循环每 2s 调一次心跳回调(per-session,经
//! ToolContext.spawn_tick_fn ← agent_loop Options.spawn_tick_fn 传入)。
//! 这里的 progressCb 在 stderr 打一行 dim 提示。
//!
//! 非 TTY 环境不接回调(Options.spawn_tick_fn 保持 null),工具静默执行。
//!
//! 颜色用 tui/ansi.zig 的常量(回调无法访问 App 上下文,不走 theme)。

const std = @import("std");
const ansi = @import("tui/ansi.zig");

/// 子进程"仍在运行"心跳回调。loop.zig 在 tty 下把它传给 agent_loop Options.spawn_tick_fn。
/// 重构前经 common.g_progress_cb 进程全局注入;现 per-session 经 Options 传,无全局。
pub fn progressCb(elapsed_ms: u64, argv0: []const u8) void {
    const secs = @as(f64, @floatFromInt(elapsed_ms)) / 1000.0;
    std.debug.print("{s}... {s} running ({d:.1}s){s}\n", .{ ansi.sgr.dim, argv0, secs, ansi.sgr.reset });
}
