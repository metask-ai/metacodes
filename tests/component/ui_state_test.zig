//! L2 组件测试:UI 状态机 dispatch(纯状态转移)。
//!
//! 验证 doc/TUI_STATE_ARCHITECTURE.md 的核心:事件 → dispatch → state 变更 + Effect。
//! 全内存级,不起终端、不连模型。Ctrl+O/`?` 这些现状只能 pty 测的,在此变纯单测。

const std = @import("std");
const testing = std.testing;
const cc = @import("cc");

const ui = cc.tui_ui;
const ui_state = cc.tui_ui_state;
const event = cc.tui_event;
const input = cc.repl_input;

const UiState = ui_state.UiState;

fn keyChar(c: u8) event.Event {
    return .{ .key = .{ .key = .{ .char = c } } };
}
fn keyTag(k: input.Key) event.Event {
    return .{ .key = .{ .key = k } };
}

test "dispatch: 空 editor 按 ? → help_open(非模态)" {
    var s = UiState{};
    const eff = ui.dispatch(&s, keyChar('?'));
    try testing.expect(s.help_open);
    try testing.expect(eff.redraw_region);
}

test "dispatch: 非空 editor 按 ? → 不开 help,透传编辑器" {
    var s = UiState{ .editor = .{ .view = "foo", .cursor = 3 } };
    const eff = ui.dispatch(&s, keyChar('?'));
    try testing.expect(!s.help_open);
    try testing.expectEqual(event.LoopAction.pass_to_editor, eff.action);
}

test "dispatch: help 开着再按 ? → toggle 关闭" {
    var s = UiState{ .help_open = true };
    const eff = ui.dispatch(&s, keyChar('?'));
    try testing.expect(!s.help_open);
    try testing.expect(eff.redraw_region);
}

test "dispatch: help 开着打其它字符 → 关 help 且该键透传编辑器(非模态)" {
    var s = UiState{ .help_open = true };
    const eff = ui.dispatch(&s, keyChar('x'));
    try testing.expect(!s.help_open);
    try testing.expectEqual(event.LoopAction.pass_to_editor, eff.action);
}

test "dispatch: Ctrl+O 开 model picker,Ctrl+X Ctrl+O 仍开 transcript(issue #16 改绑)" {
    // issue #16:Ctrl+O 让给跨 UI model picker(对齐 Hermes),transcript 查看器改绑
    // `Ctrl+X Ctrl+O`——复用已有的 Ctrl+X 前缀、同一个字母。两条路都必须可达:
    // 改绑不能让任何一个动作变成 no-op。两者都仍只上抛 LoopAction,dispatch 不碰 IO。
    var s = UiState{};
    try testing.expectEqual(event.LoopAction.open_model_picker, ui.dispatch(&s, keyTag(.ctrl_o)).action);

    _ = ui.dispatch(&s, keyTag(.ctrl_x));
    try testing.expectEqual(event.LoopAction.open_transcript, ui.dispatch(&s, keyTag(.ctrl_o)).action);

    // Ctrl+X 前缀原本的绑定不受影响。
    _ = ui.dispatch(&s, keyTag(.ctrl_x));
    try testing.expectEqual(event.LoopAction.kill_background, ui.dispatch(&s, keyTag(.ctrl_k)).action);
}

test "dispatch: Ctrl+T 切 task 面板显隐(toggle panel.task_list_visible,dispatch 内消费)" {
    var s = UiState{};
    try testing.expect(s.panel.task_list_visible); // 默认显示
    const e1 = ui.dispatch(&s, keyTag(.ctrl_t));
    try testing.expect(!s.panel.task_list_visible); // 第一次 → 隐藏
    try testing.expect(e1.redraw_region);
    try testing.expectEqual(event.LoopAction.none, e1.action); // dispatch 内消费,不上抛/不透传
    _ = ui.dispatch(&s, keyTag(.ctrl_t));
    try testing.expect(s.panel.task_list_visible); // 第二次 → 恢复
}

test "dispatch: Ctrl+T 在生成期也生效(两期共用一份语义)" {
    var s = UiState{ .phase = .generating };
    _ = ui.dispatch(&s, keyTag(.ctrl_t));
    try testing.expect(!s.panel.task_list_visible);
}

test "dispatch: 全局键上抛 LoopAction(输入期)——shift_tab/ctrl_l/up/down/tab/ctrl_r/ctrl_g" {
    var s = UiState{}; // phase=.input
    try testing.expectEqual(event.LoopAction.cycle_perm_mode, ui.dispatch(&s, keyTag(.shift_tab)).action);
    try testing.expectEqual(event.LoopAction.redraw_screen, ui.dispatch(&s, keyTag(.ctrl_l)).action);
    try testing.expectEqual(event.LoopAction.cursor_up, ui.dispatch(&s, keyTag(.up)).action);
    try testing.expectEqual(event.LoopAction.cursor_down, ui.dispatch(&s, keyTag(.down)).action);
    try testing.expectEqual(event.LoopAction.complete, ui.dispatch(&s, keyTag(.tab)).action);
    try testing.expectEqual(event.LoopAction.reverse_search, ui.dispatch(&s, keyTag(.ctrl_r)).action);
    try testing.expectEqual(event.LoopAction.external_edit, ui.dispatch(&s, keyTag(.ctrl_g)).action);
}

test "dispatch: 生成期 gate——shift_tab/ctrl_l 仍激活,history/complete/search/edit 被吞" {
    var s = UiState{ .phase = .generating };
    try testing.expectEqual(event.LoopAction.cycle_perm_mode, ui.dispatch(&s, keyTag(.shift_tab)).action);
    try testing.expectEqual(event.LoopAction.redraw_screen, ui.dispatch(&s, keyTag(.ctrl_l)).action);
    try testing.expectEqual(event.LoopAction.none, ui.dispatch(&s, keyTag(.up)).action);
    try testing.expectEqual(event.LoopAction.none, ui.dispatch(&s, keyTag(.tab)).action);
    try testing.expectEqual(event.LoopAction.none, ui.dispatch(&s, keyTag(.ctrl_r)).action);
    try testing.expectEqual(event.LoopAction.none, ui.dispatch(&s, keyTag(.ctrl_g)).action);
}

test "dispatch: Ctrl+X Ctrl+K 序列 → kill_background(arming 在 UiState)" {
    var s = UiState{};
    const e1 = ui.dispatch(&s, keyTag(.ctrl_x));
    try testing.expect(s.ctrl_x_armed); // Ctrl+X 置 armed
    try testing.expectEqual(event.LoopAction.none, e1.action); // Ctrl+X 单独不上抛
    const e2 = ui.dispatch(&s, keyTag(.ctrl_k));
    try testing.expectEqual(event.LoopAction.kill_background, e2.action); // 序列 → 杀后台
    try testing.expect(!s.ctrl_x_armed); // 消费后清 armed
}

test "dispatch: Ctrl+X 后非 Ctrl+K → armed 清除,该键照常(防粘连)" {
    var s = UiState{};
    _ = ui.dispatch(&s, keyTag(.ctrl_x));
    try testing.expect(s.ctrl_x_armed);
    // 跟一个普通字符 → armed 清除,字符透传编辑器(不触发 kill)。
    const e = ui.dispatch(&s, keyChar('a'));
    try testing.expect(!s.ctrl_x_armed);
    try testing.expectEqual(event.LoopAction.pass_to_editor, e.action);
}

test "dispatch: Ctrl+X 在生成期也能序列杀后台(两期一致)" {
    var s = UiState{ .phase = .generating };
    _ = ui.dispatch(&s, keyTag(.ctrl_x));
    try testing.expectEqual(event.LoopAction.kill_background, ui.dispatch(&s, keyTag(.ctrl_k)).action);
}

test "dispatch: 单 Ctrl+K(无 arming)→ pass_to_editor(kill-line 归 editor)" {
    var s = UiState{};
    const e = ui.dispatch(&s, keyTag(.ctrl_k));
    try testing.expectEqual(event.LoopAction.pass_to_editor, e.action); // editor 当 kill-line
}

test "dispatch: 裸 esc(无 help/overlay)→ pass_to_editor(输入期 clear_draft 归 editor)" {
    var s = UiState{};
    const e = ui.dispatch(&s, keyTag(.esc));
    try testing.expectEqual(event.LoopAction.pass_to_editor, e.action);
}

test "dispatch: help 开时 esc → 只关 help,不透传(先关弹层)" {
    var s = UiState{ .help_open = true };
    const e = ui.dispatch(&s, keyTag(.esc));
    try testing.expect(!s.help_open); // help 关闭
    try testing.expectEqual(event.LoopAction.none, e.action); // 不透传(不触发 editor clear_draft)
    try testing.expect(e.redraw_region);
}

test "dispatch: spinner_tick 推进帧 + 要求重画" {
    var s = UiState{ .phase = .generating };
    const eff = ui.dispatch(&s, .spinner_tick);
    try testing.expectEqual(@as(u8, 1), s.spinner.frame);
    try testing.expect(eff.redraw_region);
}

test "dispatch: resize 更新几何" {
    var s = UiState{};
    _ = ui.dispatch(&s, .{ .resize = .{ .cols = 120, .rows = 40 } });
    try testing.expectEqual(@as(u16, 120), s.cols);
    try testing.expectEqual(@as(u16, 40), s.rows);
}

test "dispatch: usage 更新 footer 快照" {
    var s = UiState{};
    _ = ui.dispatch(&s, .{ .usage = .{ .input_tokens = 100, .output_tokens = 50, .mode = .plan } });
    try testing.expectEqual(@as(u64, 150), s.footer.totalTokens());
    try testing.expectEqual(@import("cc").types_mod.PermissionMode.plan, s.footer.mode);
}

test "dispatch: text_chunk → emit_scroll(不改固定区)" {
    var s = UiState{};
    const eff = ui.dispatch(&s, .{ .text_chunk = .{ .text = "hello" } });
    try testing.expect(eff.emit_scroll != null);
    try testing.expectEqualStrings("hello", eff.emit_scroll.?);
    try testing.expect(!eff.redraw_region);
}

test "dispatch: tool_progress 走 immediate 快速路径" {
    var s = UiState{ .phase = .generating };
    ui_state.addCard(&s, "id_a", "WebSearch", "", 0);
    const eff = ui.dispatch(&s, .{ .tool_progress = .{ .id = "id_a", .text = "Found 5 results" } });
    try testing.expect(eff.immediate and eff.redraw_region);
    try testing.expectEqualStrings("Found 5 results", s.tools.cards[0].progressSlice());
}

test "dispatch: add/clear tool card" {
    var s = UiState{};
    ui_state.addCard(&s, "a", "WebSearch", "", 0);
    ui_state.addCard(&s, "b", "WebSearch", "", 0);
    try testing.expectEqual(@as(u8, 2), s.tools.cards_len);
    ui_state.clearCard(&s, "a");
    try testing.expectEqual(@as(u8, 1), s.tools.cards_len);
    try testing.expectEqualStrings("b", s.tools.cards[0].idSlice()); // 前移紧凑
}

test "dispatch: add 重复 id 忽略" {
    var s = UiState{};
    ui_state.addCard(&s, "a", "WebSearch", "", 0);
    ui_state.addCard(&s, "a", "WebSearch", "", 0);
    try testing.expectEqual(@as(u8, 1), s.tools.cards_len);
}

test "dispatch: phase_change → generating 重置 spinner + 关 help" {
    var s = UiState{ .help_open = true, .spinner = .{ .frame = 9 } };
    _ = ui.dispatch(&s, .{ .phase_change = .{ .to = .generating } });
    try testing.expectEqual(ui_state.Phase.generating, s.phase);
    try testing.expectEqual(@as(u8, 0), s.spinner.frame);
    try testing.expect(!s.help_open); // 生成期关闭 help
}

test "dispatch: editor_view 更新投影" {
    var s = UiState{};
    _ = ui.dispatch(&s, .{ .editor_view = .{ .view = "abc", .cursor = 2 } });
    try testing.expectEqualStrings("abc", s.editor.view);
    try testing.expectEqual(@as(usize, 2), s.editor.cursor);
}

test "dispatch: set/clear current tool" {
    var s = UiState{};
    _ = ui.dispatch(&s, .{ .set_current_tool = .{ .name = "Bash", .start_ms = 100 } });
    try testing.expectEqualStrings("Bash", s.tools.currentSlice());
    _ = ui.dispatch(&s, .clear_current_tool);
    try testing.expectEqual(@as(u8, 0), s.tools.current_len);
}

// ── DIFF#4: slash 菜单导航(↑↓ 移高亮 + Enter 选中 + Tab 补全)──────────────────
const complete = cc.repl_complete;

test "dispatch: slash 菜单开 → Down 移选中(slash_sel++, 不上抛 history)" {
    var s = UiState{};
    _ = ui.dispatch(&s, .{ .editor_view = .{ .view = "/", .cursor = 1 } });
    try testing.expectEqual(@as(usize, 0), s.slash_sel);
    const e = ui.dispatch(&s, keyTag(.down));
    try testing.expectEqual(@as(usize, 1), s.slash_sel);
    try testing.expect(e.redraw_region);
    try testing.expectEqual(event.LoopAction.none, e.action); // 不是 history_next
}

test "dispatch: slash 菜单开 → Up 在 0 处回绕到末项" {
    var s = UiState{};
    _ = ui.dispatch(&s, .{ .editor_view = .{ .view = "/", .cursor = 1 } });
    const n = complete.slashFilterCount("/");
    const e = ui.dispatch(&s, keyTag(.up));
    try testing.expectEqual(n - 1, s.slash_sel); // 0 → 末项
    try testing.expectEqual(event.LoopAction.none, e.action);
}

test "dispatch: slash 菜单开 → Enter 上抛 slash_select" {
    var s = UiState{};
    _ = ui.dispatch(&s, .{ .editor_view = .{ .view = "/", .cursor = 1 } });
    const e = ui.dispatch(&s, keyTag(.enter));
    try testing.expectEqual(event.LoopAction.slash_select, e.action);
}

test "dispatch: slash 菜单开 → Tab 上抛 slash_complete" {
    var s = UiState{};
    _ = ui.dispatch(&s, .{ .editor_view = .{ .view = "/", .cursor = 1 } });
    const e = ui.dispatch(&s, keyTag(.tab));
    try testing.expectEqual(event.LoopAction.slash_complete, e.action);
}

test "dispatch: slash 菜单关(普通文本) → Up 落到 cursor_up(不抢键)" {
    var s = UiState{};
    _ = ui.dispatch(&s, .{ .editor_view = .{ .view = "hello", .cursor = 5 } });
    const e = ui.dispatch(&s, keyTag(.up));
    // slash 菜单关时不抢 Up;落到全局 fallthrough = cursor_up(loop 据可视行边界决定竖移/历史)。
    try testing.expectEqual(event.LoopAction.cursor_up, e.action);
    try testing.expectEqual(@as(usize, 0), s.slash_sel);
}

test "dispatch: slash 菜单 → 打字过滤变窄,slash_sel 钳到末项" {
    var s = UiState{};
    _ = ui.dispatch(&s, .{ .editor_view = .{ .view = "/", .cursor = 1 } });
    // 移到一个较大的 index
    var i: usize = 0;
    while (i < 5) : (i += 1) _ = ui.dispatch(&s, keyTag(.down));
    const big = s.slash_sel;
    // 过滤到只剩 /clear(唯一匹配)→ slash_sel 应钳到 0
    _ = ui.dispatch(&s, .{ .editor_view = .{ .view = "/clea", .cursor = 5 } });
    const n2 = complete.slashFilterCount("/clea");
    try testing.expect(s.slash_sel < n2 or s.slash_sel == 0);
    try testing.expect(big >= s.slash_sel);
}

test "slashNthMatch: 顺序与表一致" {
    const c0 = complete.slashNthMatch("/", 0).?;
    try testing.expectEqualStrings("/help", c0.name);
    // /c 前缀:/clear /compact /cost /config /commit(按表顺序)
    const cc0 = complete.slashNthMatch("/c", 0).?;
    try testing.expectEqualStrings("/clear", cc0.name);
}

// ── DIFF#5: @-mention 菜单(dispatch 检测 @ 激活 → 上抛 at_nav/at_select)──────────
test "dispatch: @ 菜单激活 → Down 上抛 at_nav(dir=down)" {
    var s = UiState{};
    _ = ui.dispatch(&s, .{ .editor_view = .{ .view = "@", .cursor = 1 } });
    const e = ui.dispatch(&s, keyTag(.down));
    try testing.expectEqual(event.LoopAction.at_nav, e.action);
    try testing.expect(e.at_nav_dir); // down
}

test "dispatch: @ 菜单激活 → Up 上抛 at_nav(dir=up)" {
    var s = UiState{};
    _ = ui.dispatch(&s, .{ .editor_view = .{ .view = "@src/", .cursor = 5 } });
    const e = ui.dispatch(&s, keyTag(.up));
    try testing.expectEqual(event.LoopAction.at_nav, e.action);
    try testing.expect(!e.at_nav_dir); // up
}

test "dispatch: @ 菜单 → Enter/Tab 上抛 at_select" {
    var s = UiState{};
    _ = ui.dispatch(&s, .{ .editor_view = .{ .view = "@RE", .cursor = 3 } });
    try testing.expectEqual(event.LoopAction.at_select, ui.dispatch(&s, keyTag(.enter)).action);
    try testing.expectEqual(event.LoopAction.at_select, ui.dispatch(&s, keyTag(.tab)).action);
}

test "dispatch: 非 @ token(普通文本)→ Up 落到 cursor_up(不抢键)" {
    var s = UiState{};
    _ = ui.dispatch(&s, .{ .editor_view = .{ .view = "hello @ world", .cursor = 13 } });
    // 光标在 "world" 上,当前 token 非 @ → 不激活 @ 菜单 → 落到全局 cursor_up。
    const e = ui.dispatch(&s, keyTag(.up));
    try testing.expectEqual(event.LoopAction.cursor_up, e.action);
}

test "atMenuActive: 仅当前 token 以 @ 开头才激活" {
    try testing.expect(complete.atMenuActive("@", 1));
    try testing.expect(complete.atMenuActive("@src/foo", 8));
    try testing.expect(complete.atMenuActive("see @RE", 7));
    try testing.expect(!complete.atMenuActive("hello", 5));
    try testing.expect(!complete.atMenuActive("@x done", 7)); // 光标后 token 是 "done"
}
