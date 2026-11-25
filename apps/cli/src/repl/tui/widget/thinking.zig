//! 思考过程 widget(TUI_COMPONENTS.md §5.3)。
//!
//! 不抢 Ctrl+T(归任务列表)。展开/收起靠 `/thinking` 命令切默认模式。
//!
//! 三种渲染形态:
//! - renderSpinner:进行中(折叠默认),单行 "✻ Thinking (1.2s)"
//! - renderExpanded:完整框,内容 ≤ 屏幕宽度折行
//! - renderCollapsed:完成后默认收起,"✻ Thought for 4.3s [T to expand]"
//!
//! agent_loop 当前不消费 thinking block(见 5/29 功能 check StopReason 等遗漏)。
//! 本组件先做渲染,等 Block union 加 .thinking variant 后再接线。

const std = @import("std");
const theme_mod = @import("../theme.zig");
const layout = @import("../layout.zig");
const Theme = theme_mod.Theme;

/// 进行中(spinner)单行。caller free。
pub fn renderSpinner(alloc: std.mem.Allocator, th: Theme, elapsed_ms: u64) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s}{s} Thinking ({d:.1}s){s}\n", .{
        th.role_thinking,
        th.icon_thinking,
        @as(f64, @floatFromInt(elapsed_ms)) / 1000.0,
        th.reset,
    });
}

/// 完整框:thinking 内容(可换行)+ 顶/底边。caller free。
pub fn renderExpanded(alloc: std.mem.Allocator, th: Theme, content: []const u8, elapsed_ms: u64) ![]u8 {
    var title_buf: [64]u8 = undefined;
    const title = try std.fmt.bufPrint(&title_buf, "{s} Thinking ({d:.1}s)", .{
        th.icon_thinking,
        @as(f64, @floatFromInt(elapsed_ms)) / 1000.0,
    });
    return try layout.drawBox(alloc, th, content, .{
        .title = title,
        .width = 0, // 自适应
        .padding = 1,
    });
}

/// 完成态折叠(单行摘要)。caller free。
pub fn renderCollapsed(alloc: std.mem.Allocator, th: Theme, elapsed_ms: u64) ![]u8 {
    return std.fmt.allocPrint(alloc, "{s}{s} Thought for {d:.1}s{s} {s}[/thinking to expand]{s}\n", .{
        th.role_thinking,
        th.icon_thinking,
        @as(f64, @floatFromInt(elapsed_ms)) / 1000.0,
        th.reset,
        th.dim,
        th.reset,
    });
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;
const capture = @import("../test_capture.zig");

test "renderSpinner: 显示耗时" {
    const th = theme_mod.monochrome;
    const s = try renderSpinner(testing.allocator, th, 1200);
    defer testing.allocator.free(s);
    try capture.expectContains(s, "~ Thinking (1.2s)"); // monochrome icon_thinking="~"
    try capture.expectNoAnsi(s);
}

test "renderSpinner: dark 主题加色" {
    const th = theme_mod.dark;
    const s = try renderSpinner(testing.allocator, th, 800);
    defer testing.allocator.free(s);
    try capture.expectContains(s, "✻ Thinking (0.8s)");
    try testing.expect(std.mem.indexOf(u8, s, "\x1b") != null); // 有 ANSI
}

test "renderCollapsed: 显示总耗时 + 展开提示" {
    const th = theme_mod.monochrome;
    const s = try renderCollapsed(testing.allocator, th, 4300);
    defer testing.allocator.free(s);
    try capture.expectContains(s, "Thought for 4.3s");
    try capture.expectContains(s, "/thinking to expand");
}

test "renderExpanded: drawBox 含 thinking 标题" {
    const th = theme_mod.monochrome;
    const s = try renderExpanded(testing.allocator, th, "Let me think.\nMaybe option A?", 2500);
    defer testing.allocator.free(s);
    try capture.expectContains(s, "Thinking (2.5s)");
    try capture.expectContains(s, "Let me think.");
    try capture.expectContains(s, "Maybe option A?");
}

test "VISUAL demo: thinking 三相(TUI_DEMO=1)" {
    if (std.c.getenv("TUI_DEMO") == null) return error.SkipZigTest;
    const th = theme_mod.dark;
    const s1 = try renderSpinner(testing.allocator, th, 1200);
    defer testing.allocator.free(s1);
    const s2 = try renderExpanded(testing.allocator, th, "Let me think about the user's request.\nThey want to refactor the auth module.\nFirst I need to read the existing code.", 4300);
    defer testing.allocator.free(s2);
    const s3 = try renderCollapsed(testing.allocator, th, 4300);
    defer testing.allocator.free(s3);
    std.debug.print("\n=== Spinner ===\n{s}\n=== Expanded ===\n{s}\n=== Collapsed ===\n{s}\n", .{ s1, s2, s3 });
}
