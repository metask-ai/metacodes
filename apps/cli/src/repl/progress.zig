//! TUI 工具执行进度显示(子进程长命令"仍在运行"心跳)。
//!
//! **2026-06-10 修(bug#2 根因)**:原版每 2s `std.debug.print` 裸写 stderr 一行
//! `... cmd running (Ns)`——**绕过 render_region 锁**。生成期(尤其多 agent + 长命令如
//! Bash sleep)与固定区 spinner 渲染交错,把 spinner 行推进 scrollback(实测残留 15 行)。
//! 改 no-op:工具运行反馈归固定区(spinner verb + elapsed 持续涨已是心跳;长命令心跳的
//! 命令名显示是后续增强——让 StatusBar.renderGenerating 显 current_tool,对齐 cc 固定区动作行)。
//! 实测:no-op 后 spinner 残留 15→1(正常当前帧),scrollback 不再被污染。
//!
//! 非 TTY 环境本就不接此回调(Options.spawn_tick_fn 保持 null)。

const std = @import("std");

/// 子进程"仍在运行"心跳回调。**no-op**(见模块头注:原裸 print 绕锁污染 scrollback = bug#2)。
/// 保留函数 + 接线(loop.zig spawn_tick),供将来改成走 render_region 锁的区内心跳。
pub fn progressCb(elapsed_ms: u64, argv0: []const u8) void {
    _ = elapsed_ms;
    _ = argv0;
}
