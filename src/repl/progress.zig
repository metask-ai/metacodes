//! TUI 工具执行进度显示。
//!
//! 触发点:tools/common.zig 的 spawn 循环每 2s 调一次 g_progress_cb。
//! 这里的 callback 在 stderr 打一行 dim 提示。
//!
//! 非 TTY 环境不设回调(g_progress_cb 保持 null),工具静默执行。
//!
//! 颜色用 tui/ansi.zig 的常量(不走 theme:回调无法访问 App 上下文。
//! NO_COLOR 时可手动 disable;详见 §10 statusline 脚本机制)。

const std = @import("std");
const common = @import("../tools/common.zig");
const ansi = @import("tui/ansi.zig");

/// 开启 progress 显示:把 callback 注入到 tools/common.zig 的全局钩子。
/// 只在 TTY 下调一次(App 启动时)。
pub fn enable() void {
    common.g_progress_cb = progressCb;
}

pub fn disable() void {
    common.g_progress_cb = null;
}

fn progressCb(elapsed_ms: u64, argv0: []const u8) void {
    const secs = @as(f64, @floatFromInt(elapsed_ms)) / 1000.0;
    std.debug.print("{s}... {s} running ({d:.1}s){s}\n", .{ ansi.sgr.dim, argv0, secs, ansi.sgr.reset });
}
