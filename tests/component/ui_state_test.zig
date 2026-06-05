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
    try testing.expectEqual(ui_state.Overlay.none, s.overlay); // help 不再是 overlay
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

test "dispatch: Ctrl+O 在 none/transcript 间切换(真视图态)" {
    var s = UiState{};
    _ = ui.dispatch(&s, keyTag(.ctrl_o));
    try testing.expectEqual(ui_state.Overlay.transcript, s.overlay);
    _ = ui.dispatch(&s, keyTag(.ctrl_o));
    try testing.expectEqual(ui_state.Overlay.none, s.overlay);
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

test "dispatch: transcript overlay 下 Ctrl+T 被 overlay 拦截(面板不变)" {
    var s = UiState{ .overlay = .transcript };
    _ = ui.dispatch(&s, keyTag(.ctrl_t));
    try testing.expect(s.panel.task_list_visible); // 模态吞掉,默认 true 不变
}

test "dispatch: 全局键上抛 LoopAction(输入期)——shift_tab/ctrl_l/up/down/tab/ctrl_r/ctrl_g" {
    var s = UiState{}; // phase=.input
    try testing.expectEqual(event.LoopAction.cycle_perm_mode, ui.dispatch(&s, keyTag(.shift_tab)).action);
    try testing.expectEqual(event.LoopAction.redraw_screen, ui.dispatch(&s, keyTag(.ctrl_l)).action);
    try testing.expectEqual(event.LoopAction.history_prev, ui.dispatch(&s, keyTag(.up)).action);
    try testing.expectEqual(event.LoopAction.history_next, ui.dispatch(&s, keyTag(.down)).action);
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

test "dispatch: transcript overlay 下全局键不上抛(被 overlay 拦截)" {
    var s = UiState{ .overlay = .transcript };
    try testing.expectEqual(event.LoopAction.none, ui.dispatch(&s, keyTag(.shift_tab)).action);
    try testing.expectEqual(event.LoopAction.none, ui.dispatch(&s, keyTag(.ctrl_l)).action);
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

test "dispatch: transcript 下 j/k 滚动,q 关闭" {
    var s = UiState{ .overlay = .transcript, .transcript_top = 0 };
    _ = ui.dispatch(&s, keyChar('j'));
    try testing.expectEqual(@as(usize, 1), s.transcript_top);
    _ = ui.dispatch(&s, keyChar('j'));
    try testing.expectEqual(@as(usize, 2), s.transcript_top);
    _ = ui.dispatch(&s, keyChar('k'));
    try testing.expectEqual(@as(usize, 1), s.transcript_top);
    _ = ui.dispatch(&s, keyChar('q'));
    try testing.expectEqual(ui_state.Overlay.none, s.overlay);
}

test "dispatch: transcript_top k 在 0 处不下溢" {
    var s = UiState{ .overlay = .transcript, .transcript_top = 0 };
    _ = ui.dispatch(&s, keyChar('k'));
    try testing.expectEqual(@as(usize, 0), s.transcript_top); // saturating
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
    ui_state.addCard(&s, "id_a", "WebSearch", 0);
    const eff = ui.dispatch(&s, .{ .tool_progress = .{ .id = "id_a", .text = "Found 5 results" } });
    try testing.expect(eff.immediate and eff.redraw_region);
    try testing.expectEqualStrings("Found 5 results", s.tools.cards[0].progressSlice());
}

test "dispatch: add/clear tool card" {
    var s = UiState{};
    ui_state.addCard(&s, "a", "WebSearch", 0);
    ui_state.addCard(&s, "b", "WebSearch", 0);
    try testing.expectEqual(@as(u8, 2), s.tools.cards_len);
    ui_state.clearCard(&s, "a");
    try testing.expectEqual(@as(u8, 1), s.tools.cards_len);
    try testing.expectEqualStrings("b", s.tools.cards[0].idSlice()); // 前移紧凑
}

test "dispatch: add 重复 id 忽略" {
    var s = UiState{};
    ui_state.addCard(&s, "a", "WebSearch", 0);
    ui_state.addCard(&s, "a", "WebSearch", 0);
    try testing.expectEqual(@as(u8, 1), s.tools.cards_len);
}

test "dispatch: phase_change → generating 重置 spinner + 关 help/overlay" {
    var s = UiState{ .help_open = true, .spinner = .{ .frame = 9 } };
    _ = ui.dispatch(&s, .{ .phase_change = .{ .to = .generating } });
    try testing.expectEqual(ui_state.Phase.generating, s.phase);
    try testing.expectEqual(@as(u8, 0), s.spinner.frame);
    try testing.expectEqual(ui_state.Overlay.none, s.overlay);
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
