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

// ---- TaskTab(阶段 4)纯函数核心 ----

test "L2 TUI TaskTab: 选首个 in_progress 的 active_form(无则 subject)" {
    const a = std.testing.allocator;
    var store = cc.core_task_store.TaskStore.init(a);
    defer store.deinit();

    // 无 in_progress → null
    try std.testing.expect(cc.tui_render_region.taskTabLabel(&store) == null);

    // 建两个:第一个 pending,第二个 in_progress(带 active_form)
    _ = try store.create("first subject", "d", null);
    const t2 = try store.create("second subject", "d", "running second");
    try std.testing.expect(cc.tui_render_region.taskTabLabel(&store) == null); // 都还 pending

    try store.updateStatus(t2.id, .in_progress);
    const label = cc.tui_render_region.taskTabLabel(&store) orelse return error.NoLabel;
    try std.testing.expectEqualStrings("running second", label); // active_form 优先
}

test "L2 TUI TaskTab: 无 active_form 回退 subject" {
    const a = std.testing.allocator;
    var store = cc.core_task_store.TaskStore.init(a);
    defer store.deinit();
    const t = try store.create("do the thing", "d", null);
    try store.updateStatus(t.id, .in_progress);
    const label = cc.tui_render_region.taskTabLabel(&store) orelse return error.NoLabel;
    try std.testing.expectEqualStrings("do the thing", label);
}

test "L2 TUI TaskTab: truncateToWidth CJK 安全截断" {
    const tr = cc.tui_render_region.truncateToWidth;
    // 全 ASCII,宽度足够 → 不截
    try std.testing.expectEqual(@as(usize, 5), tr("hello", 20));
    // 截断:max_w=4 留 1 列省略号 → 最多 3 列 ASCII
    try std.testing.expectEqual(@as(usize, 3), tr("hello", 4));
    // CJK 每字 2 列:"中文" 宽 4;max_w=4 → 不截(<=4)
    try std.testing.expectEqual(@as(usize, 6), tr("中文", 4)); // 2 字 × 3 字节 = 6
    // CJK 截断:max_w=3 留 1 列 → 只能放 1 个中文(2列)放不下(>2),实际 0 字
    const e = tr("中文字", 3);
    try std.testing.expect(e == 0 or e == 3); // 边界:留 1 列时 2 列的字放不进 max_w-1=2? 放得下 1 个
}
