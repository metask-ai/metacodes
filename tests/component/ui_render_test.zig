//! L2 组件测试:UI render(纯投影,state → 帧字符串)。
//!
//! 用 CaptureWriter 收帧字节 + stripAnsi 断言内容。时间靠 now_ms 注入(确定性)。
//! 验证 overlay/phase 投影 + 不碰 scrollback(无 \x1b[2J)。

const std = @import("std");
const testing = std.testing;
const cc = @import("cc");

const ui = cc.tui_ui;
const ui_state = cc.tui_ui_state;
const event = cc.tui_event;
const capture = cc.tui_test_capture;
const theme_mod = cc.tui_theme;

const UiState = ui_state.UiState;

fn mkInputs(s: *const UiState) ui.RenderInputs {
    return .{ .state = s, .now_ms = 0, .theme = theme_mod.monochrome, .use_unicode = false };
}

test "render: help_open 在输入帧 footer 区投影多列快捷键(非模态,输入框仍在)" {
    var s = UiState{ .help_open = true, .cols = 80, .rows = 24, .editor = .{ .view = "", .cursor = 0 } };
    var cw = capture.CaptureWriter.init(testing.allocator);
    defer cw.deinit();
    const frame = try ui.render(&cw, mkInputs(&s));
    const out = cw.output();
    try capture.expectContains(out, "Ctrl+O");
    try capture.expectContains(out, "Open transcript");
    try capture.expectContains(out, "Shift+Tab");
    try capture.expectContains(out, "❯"); // 输入框仍在(非模态)
    try testing.expect(frame.rows > 1);
}

test "render: input 帧含 editor view + footer,绝不含 \\x1b[2J" {
    var s = UiState{ .phase = .input, .editor = .{ .view = "abc", .cursor = 3 }, .footer = .{ .mode = .plan } };
    var cw = capture.CaptureWriter.init(testing.allocator);
    defer cw.deinit();
    _ = try ui.render(&cw, mkInputs(&s));
    try testing.expect(std.mem.indexOf(u8, cw.output(), "\x1b[2J") == null); // 不碰 scrollback
    const stripped = try capture.stripAnsi(testing.allocator, cw.output());
    defer testing.allocator.free(stripped);
    try capture.expectContains(stripped, "abc");
    try capture.expectContains(stripped, "plan mode on"); // footer CC 风格 mode part(symbol+title)
    // 非 default(plan)态 footer 含 cycle 提示;default 态才显 "? for shortcuts"(2026-06-05 对齐 cc)。
    try capture.expectContains(stripped, "shift+tab to cycle");
}

test "render: footer default 态显 '? for shortcuts',不显 cycle 提示(对齐 cc)" {
    // default 态是 cyclePermMode 循环起点;footer 分支与非 default 不同。
    // 此前仅 PTY(test_mode_commit/test_overlay)覆盖;下沉成纯投影单测。
    var s = UiState{ .phase = .input, .editor = .{ .view = "", .cursor = 0 }, .footer = .{ .mode = .default } };
    var cw = capture.CaptureWriter.init(testing.allocator);
    defer cw.deinit();
    _ = try ui.render(&cw, mkInputs(&s));
    const stripped = try capture.stripAnsi(testing.allocator, cw.output());
    defer testing.allocator.free(stripped);
    try capture.expectContains(stripped, "? for shortcuts"); // default 专属
    try testing.expect(std.mem.indexOf(u8, stripped, "shift+tab to cycle") == null); // default 不显 cycle
    try testing.expect(std.mem.indexOf(u8, stripped, "mode on") == null); // 无 mode part
}

test "render: footer accept_edits 态显 mode part(cyclePermMode 中间档)" {
    var s = UiState{ .phase = .input, .editor = .{ .view = "", .cursor = 0 }, .footer = .{ .mode = .accept_edits } };
    var cw = capture.CaptureWriter.init(testing.allocator);
    defer cw.deinit();
    _ = try ui.render(&cw, mkInputs(&s));
    const stripped = try capture.stripAnsi(testing.allocator, cw.output());
    defer testing.allocator.free(stripped);
    try capture.expectContains(stripped, "accept edits on"); // cc 风格 title
    try capture.expectContains(stripped, "shift+tab to cycle"); // 非 default → 显 cycle
}

test "render: generating 帧 spinner 行确定性(注入 now_ms)" {
    var s = UiState{ .phase = .generating, .spinner = .{ .verb = "Thinking", .start_ms = 0 } };
    var cw = capture.CaptureWriter.init(testing.allocator);
    defer cw.deinit();
    var in = mkInputs(&s);
    in.now_ms = 3000; // elapsed = 3s,确定
    _ = try ui.render(&cw, in);
    const stripped = try capture.stripAnsi(testing.allocator, cw.output());
    defer testing.allocator.free(stripped);
    try capture.expectContains(stripped, "Thinking");
    try capture.expectContains(stripped, "(3s");
    try capture.expectContains(stripped, "esc to interrupt");
}

test "E2E 内存级: ? 开 help → render help 帧 → 任意键关 → render 回输入帧" {
    var s = UiState{};
    // 初态:input 帧(无 help)
    {
        var cw = capture.CaptureWriter.init(testing.allocator);
        defer cw.deinit();
        _ = try ui.render(&cw, mkInputs(&s));
        try testing.expect(std.mem.indexOf(u8, cw.output(), "Open transcript") == null);
    }
    // dispatch '?' → help_open(非模态)
    const e1 = ui.dispatch(&s, .{ .key = .{ .key = .{ .char = '?' } } });
    try testing.expect(e1.redraw_region);
    try testing.expect(s.help_open);
    {
        var cw = capture.CaptureWriter.init(testing.allocator);
        defer cw.deinit();
        _ = try ui.render(&cw, mkInputs(&s));
        try capture.expectContains(cw.output(), "Open transcript"); // footer 区展开 help
        try capture.expectContains(cw.output(), "❯"); // 输入框仍在(非模态)
    }
    // dispatch 任意键 → 关闭 help(该键透传编辑器)
    _ = ui.dispatch(&s, .{ .key = .{ .key = .{ .char = 'x' } } });
    try testing.expect(!s.help_open);
    {
        var cw = capture.CaptureWriter.init(testing.allocator);
        defer cw.deinit();
        _ = try ui.render(&cw, mkInputs(&s));
        try testing.expect(std.mem.indexOf(u8, cw.output(), "Open transcript") == null); // 回正常 footer
    }
}

test "dispatch: Ctrl+O 上抛 open_transcript(alt-screen,不改 UiState 渲染态)" {
    // transcript 现走 alt-screen viewer(transcript_viewer.zig),Ctrl+O 只上抛 LoopAction,
    // 不改 UiState、不嵌入式渲染。渲染帧仍是普通输入帧。
    var s = UiState{ .rows = 10 };
    const eff = ui.dispatch(&s, .{ .key = .{ .key = .ctrl_o } });
    try testing.expectEqual(event.LoopAction.open_transcript, eff.action);
    // 渲染仍是输入帧(含 ❯),不含 transcript 标题。
    var cw = capture.CaptureWriter.init(testing.allocator);
    defer cw.deinit();
    _ = try ui.render(&cw, mkInputs(&s));
    try capture.expectContains(cw.output(), "❯");
}
