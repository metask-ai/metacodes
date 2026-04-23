//! TUI 工具执行进度显示。
//!
//! 触发点：tools/common.zig 的 spawn 循环每 2s 调一次 g_progress_cb。
//! 这里的 callback 在 stderr 打一行 dim 提示（`\r\x1b[K` 清行覆盖）。
//!
//! 非 TTY 环境不设回调（g_progress_cb 保持 null），工具静默执行。

const std = @import("std");
const common = @import("../tools/common.zig");

/// 开启 progress 显示：把 callback 注入到 tools/common.zig 的全局钩子。
/// 只在 TTY 下调一次（App 启动时）。
pub fn enable() void {
    common.g_progress_cb = progressCb;
}

pub fn disable() void {
    common.g_progress_cb = null;
}

fn progressCb(elapsed_ms: u64, argv0: []const u8) void {
    const secs = @as(f64, @floatFromInt(elapsed_ms)) / 1000.0;
    std.debug.print("\x1b[2m... {s} running ({d:.1}s)\x1b[0m\n", .{ argv0, secs });
}
