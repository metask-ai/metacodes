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

// #330: keys reach only an interactive phase, and the state they act on lives
// in that phase's payload. These build the phase a test is about.
fn reading() UiState {
    return UiState.in(.{ .input = .{} });
}
fn replying() UiState {
    return UiState.in(.{ .generating = .{} });
}
fn readingWith(view: []const u8, cursor: usize) UiState {
    var s = reading();
    s.interaction().?.editor = .{ .view = view, .cursor = cursor };
    return s;
}
fn readingWithHelp() UiState {
    var s = reading();
    s.interaction().?.help_open = true;
    return s;
}
fn ix(s: *UiState) *ui_state.Interaction {
    return s.interaction().?;
}
fn inp(s: *UiState) *ui_state.InputPhase {
    return s.inputPhase().?;
}

test "dispatch: 空 editor 按 ? → help_open(非模态)" {
    var s = reading();
    const eff = ui.dispatch(&s, keyChar('?'));
    try testing.expect(ix(&s).help_open);
    try testing.expect(eff.redraw_region);
}

test "dispatch: 非空 editor 按 ? → 不开 help,透传编辑器" {
    var s = readingWith("foo", 3);
    const eff = ui.dispatch(&s, keyChar('?'));
    try testing.expect(!ix(&s).help_open);
    try testing.expectEqual(event.LoopAction.pass_to_editor, eff.action);
}

test "dispatch: help 开着再按 ? → toggle 关闭" {
    var s = readingWithHelp();
    const eff = ui.dispatch(&s, keyChar('?'));
    try testing.expect(!ix(&s).help_open);
    try testing.expect(eff.redraw_region);
}

test "dispatch: help 开着打其它字符 → 关 help 且该键透传编辑器(非模态)" {
    var s = readingWithHelp();
    const eff = ui.dispatch(&s, keyChar('x'));
    try testing.expect(!ix(&s).help_open);
    try testing.expectEqual(event.LoopAction.pass_to_editor, eff.action);
}

test "dispatch: Ctrl+O 开 model picker,Ctrl+X Ctrl+O 仍开 transcript(issue #16 改绑)" {
    // issue #16:Ctrl+O 让给跨 UI model picker(对齐 Hermes),transcript 查看器改绑
    // `Ctrl+X Ctrl+O`——复用已有的 Ctrl+X 前缀、同一个字母。两条路都必须可达:
    // 改绑不能让任何一个动作变成 no-op。两者都仍只上抛 LoopAction,dispatch 不碰 IO。
    var s = reading();
    try testing.expectEqual(event.LoopAction.open_model_picker, ui.dispatch(&s, keyTag(.ctrl_o)).action);

    _ = ui.dispatch(&s, keyTag(.ctrl_x));
    try testing.expectEqual(event.LoopAction.open_transcript, ui.dispatch(&s, keyTag(.ctrl_o)).action);

    // Ctrl+X 前缀原本的绑定不受影响。
    _ = ui.dispatch(&s, keyTag(.ctrl_x));
    try testing.expectEqual(event.LoopAction.kill_background, ui.dispatch(&s, keyTag(.ctrl_k)).action);
}

test "dispatch: Ctrl+T 切 task 面板显隐(toggle panel.task_list_visible,dispatch 内消费)" {
    var s = reading();
    try testing.expect(s.panel.task_list_visible); // 默认显示
    const e1 = ui.dispatch(&s, keyTag(.ctrl_t));
    try testing.expect(!s.panel.task_list_visible); // 第一次 → 隐藏
    try testing.expect(e1.redraw_region);
    try testing.expectEqual(event.LoopAction.none, e1.action); // dispatch 内消费,不上抛/不透传
    _ = ui.dispatch(&s, keyTag(.ctrl_t));
    try testing.expect(s.panel.task_list_visible); // 第二次 → 恢复
}

test "dispatch: Ctrl+T 在生成期也生效(两期共用一份语义)" {
    var s = replying();
    _ = ui.dispatch(&s, keyTag(.ctrl_t));
    try testing.expect(!s.panel.task_list_visible);
}

test "dispatch: 全局键上抛 LoopAction(输入期)——shift_tab/ctrl_l/up/down/tab/ctrl_r/ctrl_g" {
    var s = reading();
    try testing.expectEqual(event.LoopAction.cycle_perm_mode, ui.dispatch(&s, keyTag(.shift_tab)).action);
    try testing.expectEqual(event.LoopAction.redraw_screen, ui.dispatch(&s, keyTag(.ctrl_l)).action);
    try testing.expectEqual(event.LoopAction.cursor_up, ui.dispatch(&s, keyTag(.up)).action);
    try testing.expectEqual(event.LoopAction.cursor_down, ui.dispatch(&s, keyTag(.down)).action);
    try testing.expectEqual(event.LoopAction.complete, ui.dispatch(&s, keyTag(.tab)).action);
    try testing.expectEqual(event.LoopAction.reverse_search, ui.dispatch(&s, keyTag(.ctrl_r)).action);
    try testing.expectEqual(event.LoopAction.external_edit, ui.dispatch(&s, keyTag(.ctrl_g)).action);
}

test "dispatch: 生成期 gate——shift_tab/ctrl_l 仍激活,history/complete/search/edit 被吞" {
    var s = replying();
    try testing.expectEqual(event.LoopAction.cycle_perm_mode, ui.dispatch(&s, keyTag(.shift_tab)).action);
    try testing.expectEqual(event.LoopAction.redraw_screen, ui.dispatch(&s, keyTag(.ctrl_l)).action);
    try testing.expectEqual(event.LoopAction.none, ui.dispatch(&s, keyTag(.up)).action);
    try testing.expectEqual(event.LoopAction.none, ui.dispatch(&s, keyTag(.tab)).action);
    try testing.expectEqual(event.LoopAction.none, ui.dispatch(&s, keyTag(.ctrl_r)).action);
    try testing.expectEqual(event.LoopAction.none, ui.dispatch(&s, keyTag(.ctrl_g)).action);
}

test "dispatch: Ctrl+X Ctrl+K 序列 → kill_background(arming 在 UiState)" {
    var s = reading();
    const e1 = ui.dispatch(&s, keyTag(.ctrl_x));
    try testing.expect(ix(&s).ctrl_x_armed); // Ctrl+X 置 armed
    try testing.expectEqual(event.LoopAction.none, e1.action); // Ctrl+X 单独不上抛
    const e2 = ui.dispatch(&s, keyTag(.ctrl_k));
    try testing.expectEqual(event.LoopAction.kill_background, e2.action); // 序列 → 杀后台
    try testing.expect(!ix(&s).ctrl_x_armed); // 消费后清 armed
}

test "dispatch: Ctrl+X 后非 Ctrl+K → armed 清除,该键照常(防粘连)" {
    var s = reading();
    _ = ui.dispatch(&s, keyTag(.ctrl_x));
    try testing.expect(ix(&s).ctrl_x_armed);
    // 跟一个普通字符 → armed 清除,字符透传编辑器(不触发 kill)。
    const e = ui.dispatch(&s, keyChar('a'));
    try testing.expect(!ix(&s).ctrl_x_armed);
    try testing.expectEqual(event.LoopAction.pass_to_editor, e.action);
}

test "dispatch: Ctrl+X 在生成期也能序列杀后台(两期一致)" {
    var s = replying();
    _ = ui.dispatch(&s, keyTag(.ctrl_x));
    try testing.expectEqual(event.LoopAction.kill_background, ui.dispatch(&s, keyTag(.ctrl_k)).action);
}

test "dispatch: 单 Ctrl+K(无 arming)→ pass_to_editor(kill-line 归 editor)" {
    var s = reading();
    const e = ui.dispatch(&s, keyTag(.ctrl_k));
    try testing.expectEqual(event.LoopAction.pass_to_editor, e.action); // editor 当 kill-line
}

fn keyAt(k: input.Key, now_ms: i64) event.Event {
    return .{ .key = .{ .key = k, .now_ms = now_ms } };
}

test "dispatch: Esc on an empty idle prompt does nothing" {
    var s = reading();
    const e = ui.dispatch(&s, keyAt(.esc, 0));
    try testing.expectEqual(event.LoopAction.none, e.action);
    try testing.expect(!e.redraw_region);
    try testing.expectEqual(ui_state.DoublePress.Kind.none, inp(&s).press.kind);
}

test "dispatch: Esc Esc clears the draft; the first press only shows the hint" {
    var s = readingWith("hello", 5);
    const first = ui.dispatch(&s, keyAt(.esc, 1000));
    try testing.expectEqual(event.LoopAction.none, first.action);
    try testing.expect(first.redraw_region);
    try testing.expectEqualStrings("Esc again to clear", ui.aboveBoxNotice(&s).?);
    const second = ui.dispatch(&s, keyAt(.esc, 1500));
    try testing.expectEqual(event.LoopAction.clear_draft, second.action);
    try testing.expect(ui.aboveBoxNotice(&s) == null);
}

test "dispatch: an Esc after the window re-arms instead of clearing" {
    var s = readingWith("hello", 5);
    _ = ui.dispatch(&s, keyAt(.esc, 0));
    const late = ui.dispatch(&s, keyAt(.esc, ui_state.DOUBLE_PRESS_MS + 1));
    try testing.expectEqual(event.LoopAction.none, late.action);
    try testing.expectEqualStrings("Esc again to clear", ui.aboveBoxNotice(&s).?);
}

test "dispatch: Esc during a reply is the watcher's interrupt, not a clear" {
    var s = replying();
    ix(&s).editor = .{ .view = "queued", .cursor = 6 };
    try testing.expectEqual(event.LoopAction.pass_to_editor, ui.dispatch(&s, keyAt(.esc, 0)).action);
    try testing.expectEqual(event.LoopAction.pass_to_editor, ui.dispatch(&s, keyAt(.esc, 1)).action);
}

test "dispatch: Ctrl+C twice inside the window exits; the first discards the draft" {
    var s = readingWith("draft", 5);
    const first = ui.dispatch(&s, keyAt(.ctrl_c, 0));
    try testing.expectEqual(event.LoopAction.discard_draft, first.action);
    try testing.expectEqualStrings("Press Ctrl-C again to exit", ui.exitHint(&s).?);
    ix(&s).editor = .{}; // the loop discarded it
    try testing.expectEqual(event.LoopAction.exit_prompt, ui.dispatch(&s, keyAt(.ctrl_c, 700)).action);
}

test "dispatch: a lone Ctrl+C expires and the next one only re-arms" {
    var s = reading();
    try testing.expectEqual(event.LoopAction.none, ui.dispatch(&s, keyAt(.ctrl_c, 0)).action);
    try testing.expect(inp(&s).press.expire(ui_state.DOUBLE_PRESS_MS + 1));
    try testing.expect(ui.exitHint(&s) == null);
    try testing.expectEqual(event.LoopAction.none, ui.dispatch(&s, keyAt(.ctrl_c, 2000)).action);
    try testing.expectEqualStrings("Press Ctrl-C again to exit", ui.exitHint(&s).?);
}

test "dispatch: Ctrl+D exits on an empty prompt only, and deletes forward otherwise" {
    var s = reading();
    try testing.expectEqual(event.LoopAction.none, ui.dispatch(&s, keyAt(.ctrl_d, 0)).action);
    try testing.expectEqualStrings("Press Ctrl-D again to exit", ui.exitHint(&s).?);
    try testing.expectEqual(event.LoopAction.exit_prompt, ui.dispatch(&s, keyAt(.ctrl_d, 100)).action);

    var typed = readingWith("abc", 0);
    try testing.expectEqual(event.LoopAction.pass_to_editor, ui.dispatch(&typed, keyAt(.ctrl_d, 0)).action);
    try testing.expectEqual(event.LoopAction.pass_to_editor, ui.dispatch(&typed, keyAt(.ctrl_d, 1)).action);
}

test "dispatch: Ctrl+C then Ctrl+D do not confirm each other" {
    var s = reading();
    _ = ui.dispatch(&s, keyAt(.ctrl_c, 0));
    try testing.expectEqual(event.LoopAction.none, ui.dispatch(&s, keyAt(.ctrl_d, 10)).action);
    try testing.expectEqualStrings("Press Ctrl-D again to exit", ui.exitHint(&s).?);
}

test "dispatch: Esc closes the slash menu and keeps the draft; an edit reopens it" {
    var s = readingWith("/he", 3);
    try testing.expect(ui.suggestionMenuOpen(&s));
    const close = ui.dispatch(&s, keyAt(.esc, 0));
    try testing.expectEqual(event.LoopAction.none, close.action);
    try testing.expect(close.redraw_region);
    try testing.expect(inp(&s).menu_dismissal.covers("/he"));
    // The menu no longer takes Enter: it submits the draft as typed.
    try testing.expectEqual(event.LoopAction.pass_to_editor, ui.dispatch(&s, keyAt(.enter, 10)).action);
    // Closing the menu did not arm the clear: Esc now starts the draft's double press.
    _ = ui.dispatch(&s, keyAt(.esc, 20));
    try testing.expectEqualStrings("Esc again to clear", ui.aboveBoxNotice(&s).?);
    try testing.expectEqual(event.LoopAction.clear_draft, ui.dispatch(&s, keyAt(.esc, 30)).action);
    // A changed draft is a different menu.
    ix(&s).editor = .{ .view = "/hel", .cursor = 4 };
    try testing.expect(!inp(&s).menu_dismissal.covers("/hel"));
    try testing.expectEqual(event.LoopAction.slash_select, ui.dispatch(&s, keyAt(.enter, 40)).action);
}

test "dispatch: help 开时 esc → 只关 help,不透传(先关弹层)" {
    var s = readingWithHelp();
    const e = ui.dispatch(&s, keyTag(.esc));
    try testing.expect(!ix(&s).help_open); // help 关闭
    try testing.expectEqual(event.LoopAction.none, e.action); // 不透传(不武装 Esc 的清空)
    try testing.expectEqual(ui_state.DoublePress.Kind.none, inp(&s).press.kind);
    try testing.expect(e.redraw_region);
}

test "dispatch: spinner_tick 推进帧 + 要求重画" {
    var s = replying();
    const eff = ui.dispatch(&s, .spinner_tick);
    try testing.expectEqual(@as(u8, 1), s.phase.generating.spinner.frame);
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
    _ = ui.dispatch(&s, .{ .usage = .{ .input_tokens = 100, .output_tokens = 50, .mode = .auto } });
    try testing.expectEqual(@as(u64, 150), s.footer.totalTokens());
    try testing.expectEqual(@import("cc").types_mod.PermissionMode.auto, s.footer.mode);
}

test "dispatch: text_chunk → emit_scroll(不改固定区)" {
    var s = UiState{};
    const eff = ui.dispatch(&s, .{ .text_chunk = .{ .text = "hello" } });
    try testing.expect(eff.emit_scroll != null);
    try testing.expectEqualStrings("hello", eff.emit_scroll.?);
    try testing.expect(!eff.redraw_region);
}

test "dispatch: tool_progress 更新卡片并要求重画(通道由渲染器定,#328)" {
    var s = replying();
    ui_state.addCard(&s, "id_a", "WebSearch", "", 0);
    const eff = ui.dispatch(&s, .{ .tool_progress = .{ .id = "id_a", .text = "Found 5 results" } });
    try testing.expect(eff.redraw_region);
    try testing.expectEqualStrings("Found 5 results", s.phase.generating.tools.cards[0].progressSlice());
}

test "dispatch: add/clear tool card" {
    var s = replying();
    ui_state.addCard(&s, "a", "WebSearch", "", 0);
    ui_state.addCard(&s, "b", "WebSearch", "", 0);
    try testing.expectEqual(@as(u8, 2), s.phase.generating.tools.cards_len);
    ui_state.clearCard(&s, "a");
    try testing.expectEqual(@as(u8, 1), s.phase.generating.tools.cards_len);
    try testing.expectEqualStrings("b", s.phase.generating.tools.cards[0].idSlice()); // 前移紧凑
}

test "dispatch: add 重复 id 忽略" {
    var s = replying();
    ui_state.addCard(&s, "a", "WebSearch", "", 0);
    ui_state.addCard(&s, "a", "WebSearch", "", 0);
    try testing.expectEqual(@as(u8, 1), s.phase.generating.tools.cards_len);
}

test "dispatch: phase_change 拆掉旧阶段拥有的一切,新阶段只带 entry 参数(#330)" {
    var s = replying();
    s.phase.generating.spinner.frame = 9;
    ix(&s).help_open = true;
    ix(&s).ctrl_x_armed = true;
    ix(&s).picker_open = true;
    ix(&s).agents.view = .list;
    ix(&s).editor = .{ .view = "draft", .cursor = 5 };
    ui_state.addCard(&s, "a", "WebSearch", "", 0);

    try testing.expect(ui.dispatch(&s, .{ .phase_change = .idle }).redraw_region);
    try testing.expectEqual(ui_state.Phase.idle, @as(ui_state.Phase, s.phase));
    try testing.expect(s.interaction() == null);

    _ = ui.dispatch(&s, .{ .phase_change = .{ .generating = .{ .verb = "Thinking", .start_ms = 42 } } });
    const g = s.generatingPhase().?;
    try testing.expectEqual(@as(u8, 0), g.spinner.frame);
    try testing.expectEqualStrings("Thinking", g.spinner.verb);
    try testing.expectEqual(@as(i64, 42), g.spinner.start_ms);
    try testing.expectEqual(@as(u8, 0), g.tools.cards_len);
    try testing.expect(std.meta.eql(g.interaction, ui_state.Interaction{}));
}

test "phase: 会话拥有的状态跨阶段保留,阶段拥有的不保留" {
    var s = reading();
    _ = ui.dispatch(&s, .{ .resize = .{ .cols = 132, .rows = 50 } });
    _ = ui.dispatch(&s, .{ .usage = .{ .input_tokens = 7, .output_tokens = 3, .mode = .accept_edits } });
    _ = ui.dispatch(&s, keyTag(.ctrl_t)); // hide the task list
    s.agent_count = 4;
    inp(&s).slash_sel = 2;
    _ = ui.dispatch(&s, .{ .phase_change = .idle });
    _ = ui.dispatch(&s, .{ .phase_change = .{ .generating = .{} } });
    try testing.expectEqual(@as(u16, 132), s.cols);
    try testing.expectEqual(@as(u16, 50), s.rows);
    try testing.expectEqual(@as(u64, 10), s.footer.totalTokens());
    try testing.expect(!s.panel.task_list_visible);
    try testing.expectEqual(@as(usize, 4), s.agent_count);
    try testing.expect(s.inputPhase() == null); // slash_sel 随输入期一起没了
}

test "phase: 合法的边都经过 idle" {
    const P = ui_state.Phase;
    try testing.expect(ui_state.transitionAllowed(P.idle, P.input));
    try testing.expect(ui_state.transitionAllowed(P.idle, P.generating));
    try testing.expect(ui_state.transitionAllowed(P.input, P.idle));
    try testing.expect(ui_state.transitionAllowed(P.generating, P.idle));
    try testing.expect(ui_state.transitionAllowed(P.idle, P.idle)); // 幂等收尾
    // 一个阶段没关就开下一个:Debug 构建在 enter 处 panic。
    try testing.expect(!ui_state.transitionAllowed(P.input, P.generating));
    try testing.expect(!ui_state.transitionAllowed(P.generating, P.input));
    try testing.expect(!ui_state.transitionAllowed(P.input, P.input));
    try testing.expect(!ui_state.transitionAllowed(P.generating, P.generating));
}

test "dispatch: idle 时按键与 editor_view 无处可去" {
    var s = UiState{};
    try testing.expectEqual(ui_state.Phase.idle, @as(ui_state.Phase, s.phase));
    for ([_]event.Event{ keyChar('?'), keyTag(.ctrl_x), keyTag(.down), keyTag(.esc), keyTag(.ctrl_c) }) |ev| {
        const eff = ui.dispatch(&s, ev);
        try testing.expectEqual(event.LoopAction.none, eff.action);
        try testing.expect(!eff.redraw_region);
    }
    try testing.expect(!ui.dispatch(&s, .{ .editor_view = .{ .view = "x", .cursor = 1 } }).redraw_region);
    try testing.expect(s.interaction() == null);
    try testing.expect(ui.exitHint(&s) == null and ui.aboveBoxNotice(&s) == null and !ui.suggestionMenuOpen(&s));
}

test "dispatch: 回复以外到达的工具事件被丢弃,不要求重画" {
    var s = reading();
    try testing.expect(!ui.dispatch(&s, .{ .add_tool_card = .{ .id = "a", .name = "Bash", .start_ms = 0 } }).redraw_region);
    const late = ui.dispatch(&s, .{ .tool_progress = .{ .id = "a", .text = "Found 5" } });
    try testing.expect(!late.redraw_region);
    try testing.expect(!ui.dispatch(&s, .{ .set_current_tool = .{ .name = "Bash", .start_ms = 0 } }).redraw_region);
    try testing.expect(!ui.dispatch(&s, .spinner_tick).redraw_region);
    try testing.expect(ui_state.findCard(&s, "a") == null);
}

test "dispatch: 生成期的建议菜单状态无从产生(只有输入期 payload 有)" {
    var s = replying();
    _ = ui.dispatch(&s, .{ .editor_view = .{ .view = "/he", .cursor = 3 } });
    try testing.expect(!ui.suggestionMenuOpen(&s));
    // Esc during a reply is the watcher's interrupt; it cannot dismiss a menu
    // or arm a clear, because a reply has neither.
    try testing.expectEqual(event.LoopAction.pass_to_editor, ui.dispatch(&s, keyTag(.esc)).action);
    try testing.expect(ui.aboveBoxNotice(&s) == null);
}

test "dispatch: editor_view 更新投影" {
    var s = reading();
    _ = ui.dispatch(&s, .{ .editor_view = .{ .view = "abc", .cursor = 2 } });
    try testing.expectEqualStrings("abc", ix(&s).editor.view);
    try testing.expectEqual(@as(usize, 2), ix(&s).editor.cursor);
}

test "dispatch: set/clear current tool" {
    var s = replying();
    _ = ui.dispatch(&s, .{ .set_current_tool = .{ .name = "Bash", .start_ms = 100 } });
    try testing.expectEqualStrings("Bash", s.phase.generating.tools.currentSlice());
    _ = ui.dispatch(&s, .clear_current_tool);
    try testing.expectEqual(@as(u8, 0), s.phase.generating.tools.current_len);
}

// ── DIFF#4: slash 菜单导航(↑↓ 移高亮 + Enter 选中 + Tab 补全)──────────────────
const complete = cc.repl_complete;

test "dispatch: slash 菜单开 → Down 移选中(slash_sel++, 不上抛 history)" {
    var s = reading();
    _ = ui.dispatch(&s, .{ .editor_view = .{ .view = "/", .cursor = 1 } });
    try testing.expectEqual(@as(usize, 0), inp(&s).slash_sel);
    const e = ui.dispatch(&s, keyTag(.down));
    try testing.expectEqual(@as(usize, 1), inp(&s).slash_sel);
    try testing.expect(e.redraw_region);
    try testing.expectEqual(event.LoopAction.none, e.action); // 不是 history_next
}

test "dispatch: slash 菜单开 → Up 在 0 处回绕到末项" {
    var s = reading();
    _ = ui.dispatch(&s, .{ .editor_view = .{ .view = "/", .cursor = 1 } });
    const n = complete.slashFilterCount(.builtin, "/");
    const e = ui.dispatch(&s, keyTag(.up));
    try testing.expectEqual(n - 1, inp(&s).slash_sel); // 0 → 末项
    try testing.expectEqual(event.LoopAction.none, e.action);
}

test "dispatch: slash 菜单开 → Enter 上抛 slash_select" {
    var s = reading();
    _ = ui.dispatch(&s, .{ .editor_view = .{ .view = "/", .cursor = 1 } });
    const e = ui.dispatch(&s, keyTag(.enter));
    try testing.expectEqual(event.LoopAction.slash_select, e.action);
}

test "dispatch: slash 菜单开 → Tab 上抛 slash_complete" {
    var s = reading();
    _ = ui.dispatch(&s, .{ .editor_view = .{ .view = "/", .cursor = 1 } });
    const e = ui.dispatch(&s, keyTag(.tab));
    try testing.expectEqual(event.LoopAction.slash_complete, e.action);
}

test "dispatch: slash 菜单关(普通文本) → Up 落到 cursor_up(不抢键)" {
    var s = reading();
    _ = ui.dispatch(&s, .{ .editor_view = .{ .view = "hello", .cursor = 5 } });
    const e = ui.dispatch(&s, keyTag(.up));
    // slash 菜单关时不抢 Up;落到全局 fallthrough = cursor_up(loop 据可视行边界决定竖移/历史)。
    try testing.expectEqual(event.LoopAction.cursor_up, e.action);
    try testing.expectEqual(@as(usize, 0), inp(&s).slash_sel);
}

test "dispatch: slash 菜单 → 打字过滤变窄,slash_sel 钳到末项" {
    var s = reading();
    _ = ui.dispatch(&s, .{ .editor_view = .{ .view = "/", .cursor = 1 } });
    // 移到一个较大的 index
    var i: usize = 0;
    while (i < 5) : (i += 1) _ = ui.dispatch(&s, keyTag(.down));
    const big = inp(&s).slash_sel;
    // 过滤到只剩 /clear(唯一匹配)→ slash_sel 应钳到 0
    _ = ui.dispatch(&s, .{ .editor_view = .{ .view = "/clea", .cursor = 5 } });
    const n2 = complete.slashFilterCount(.builtin, "/clea");
    try testing.expect(inp(&s).slash_sel < n2 or inp(&s).slash_sel == 0);
    try testing.expect(big >= inp(&s).slash_sel);
}

test "slashNthMatch: 顺序与表一致" {
    // The table is alphabetical (Claude Code's menu order).
    const c0 = complete.slashNthMatch(.builtin, "/", 0).?;
    try testing.expectEqualStrings("/add-dir", c0.name);
    // /c 前缀:/clear /commit /compact /config /cost(按表顺序)
    const cc0 = complete.slashNthMatch(.builtin, "/c", 0).?;
    try testing.expectEqualStrings("/clear", cc0.name);
    try testing.expectEqualStrings("/commit", complete.slashNthMatch(.builtin, "/c", 1).?.name);
}

// ── DIFF#5: @-mention 菜单(dispatch 检测 @ 激活 → 上抛 at_nav/at_select)──────────
test "dispatch: @ 菜单激活 → Down 上抛 at_nav(dir=down)" {
    var s = reading();
    _ = ui.dispatch(&s, .{ .editor_view = .{ .view = "@", .cursor = 1 } });
    const e = ui.dispatch(&s, keyTag(.down));
    try testing.expectEqual(event.LoopAction.at_nav, e.action);
    try testing.expect(e.at_nav_dir); // down
}

test "dispatch: @ 菜单激活 → Up 上抛 at_nav(dir=up)" {
    var s = reading();
    _ = ui.dispatch(&s, .{ .editor_view = .{ .view = "@src/", .cursor = 5 } });
    const e = ui.dispatch(&s, keyTag(.up));
    try testing.expectEqual(event.LoopAction.at_nav, e.action);
    try testing.expect(!e.at_nav_dir); // up
}

test "dispatch: @ 菜单 → Enter/Tab 上抛 at_select" {
    var s = reading();
    _ = ui.dispatch(&s, .{ .editor_view = .{ .view = "@RE", .cursor = 3 } });
    try testing.expectEqual(event.LoopAction.at_select, ui.dispatch(&s, keyTag(.enter)).action);
    try testing.expectEqual(event.LoopAction.at_select, ui.dispatch(&s, keyTag(.tab)).action);
}

test "dispatch: 非 @ token(普通文本)→ Up 落到 cursor_up(不抢键)" {
    var s = reading();
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
