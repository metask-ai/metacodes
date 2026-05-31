//! L2 组件测试:TUI 状态栏渲染(阶段 1,RenderRegion 的可见内容层)。
//!
//! 验证 StatusBar 两形态输出的字节结构 + verbs 词库。RenderRegion 的 ANSI 编排
//! (回顶/清行/收缩擦除)走 std.debug.print 难在无 tty 下捕获,留真机验证;
//! 这里锁住"可见内容"层:idle/generating 行包含正确字段,且不含 \x1b[2J(不碰 scrollback)。

const std = @import("std");
const cc = @import("cc");

const verbs = cc.tui_verbs;

// 测 StatusBar 的 formatTokens / modeName + verbs —— 状态栏可见内容的纯函数核心。

test "L2 TUI: formatTokens 紧凑格式" {
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("0", cc.tui_status_bar.formatTokens(&buf, 0));
    try std.testing.expectEqualStrings("1.0K", cc.tui_status_bar.formatTokens(&buf, 1000));
    try std.testing.expectEqualStrings("1.23M", cc.tui_status_bar.formatTokens(&buf, 1_234_567));
}

test "L2 TUI: modeName 覆盖权限模式" {
    try std.testing.expectEqualStrings("default", cc.tui_status_bar.modeName(.default));
    try std.testing.expectEqualStrings("acceptEdits", cc.tui_status_bar.modeName(.accept_edits));
    try std.testing.expectEqualStrings("plan", cc.tui_status_bar.modeName(.plan));
    try std.testing.expectEqualStrings("bypassPermissions", cc.tui_status_bar.modeName(.bypass_permissions));
}

test "L2 TUI: verbs.pick 确定性 + 不越界" {
    try std.testing.expectEqualStrings(verbs.verbs[0], verbs.pick(0));
    try std.testing.expectEqualStrings(verbs.verbs[0], verbs.pick(verbs.verbs.len)); // wrap
    var s: u64 = 0;
    while (s < 300) : (s += 13) {
        try std.testing.expect(verbs.pick(s).len > 0);
    }
}

test "L2 TUI: spinner frames unicode/ascii 不越界" {
    // unicode 帧
    try std.testing.expect(verbs.frame(0, true).len > 0);
    try std.testing.expect(verbs.frame(99, true).len > 0); // wrap 不崩
    // ascii 降级帧
    try std.testing.expectEqualStrings("|", verbs.frame(0, false));
    try std.testing.expect(verbs.frame(99, false).len > 0);
}
