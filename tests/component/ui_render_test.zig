//! L2 组件测试:UI render(纯投影,state → 帧字符串)。
//!
//! 用 CaptureWriter 收帧字节 + stripAnsi 断言内容。时间靠 now_ms 注入(确定性)。
//! 验证 overlay/phase 投影 + 不碰 scrollback(无 \x1b[2J)。

const std = @import("std");
const testing = std.testing;
const cc = @import("cc");

const ui = cc.tui_ui;
const ui_state = cc.tui_ui_state;
const capture = cc.tui_test_capture;
const theme_mod = cc.tui_theme;

const UiState = ui_state.UiState;

fn mkInputs(s: *const UiState) ui.RenderInputs {
    return .{ .state = s, .now_ms = 0, .theme = theme_mod.monochrome, .use_unicode = false };
}

test "render: overlay=help 投影多列快捷键" {
    var s = UiState{ .overlay = .help, .cols = 80, .rows = 24 };
    var cw = capture.CaptureWriter.init(testing.allocator);
    defer cw.deinit();
    const frame = try ui.render(&cw, mkInputs(&s));
    try capture.expectContains(cw.output(), "Ctrl+O");
    try capture.expectContains(cw.output(), "Open transcript");
    try capture.expectContains(cw.output(), "Shift+Tab");
    try testing.expect(frame.rows > 1);
}

test "render: overlay=transcript 投影注入的对话行" {
    var s = UiState{ .overlay = .transcript, .transcript_top = 0, .rows = 10 };
    const lines = [_][]const u8{ "user: hi", "assistant: hello", "user: bye" };
    var cw = capture.CaptureWriter.init(testing.allocator);
    defer cw.deinit();
    var in = mkInputs(&s);
    in.transcript_lines = &lines;
    _ = try ui.render(&cw, in);
    const stripped = try capture.stripAnsi(testing.allocator, cw.output());
    defer testing.allocator.free(stripped);
    try capture.expectContains(stripped, "hello");
    try capture.expectContains(stripped, "transcript");
}

test "render: transcript 滚动窗口跳过 top 之前的行" {
    var s = UiState{ .overlay = .transcript, .transcript_top = 2, .rows = 10 };
    const lines = [_][]const u8{ "L0", "L1", "L2_visible", "L3_visible" };
    var cw = capture.CaptureWriter.init(testing.allocator);
    defer cw.deinit();
    var in = mkInputs(&s);
    in.transcript_lines = &lines;
    _ = try ui.render(&cw, in);
    const stripped = try capture.stripAnsi(testing.allocator, cw.output());
    defer testing.allocator.free(stripped);
    try capture.expectContains(stripped, "L2_visible");
    try testing.expect(std.mem.indexOf(u8, stripped, "L0") == null); // top 之前不显示
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
    try capture.expectContains(stripped, "plan on"); // footer CC 风格
    try capture.expectContains(stripped, "? for shortcuts");
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
    // dispatch '?' → help
    const e1 = ui.dispatch(&s, .{ .key = .{ .key = .{ .char = '?' } } });
    try testing.expect(e1.redraw_region);
    try testing.expectEqual(ui_state.Overlay.help, s.overlay);
    {
        var cw = capture.CaptureWriter.init(testing.allocator);
        defer cw.deinit();
        _ = try ui.render(&cw, mkInputs(&s));
        try capture.expectContains(cw.output(), "Open transcript"); // help 帧
    }
    // dispatch 任意键 → 关闭
    _ = ui.dispatch(&s, .{ .key = .{ .key = .{ .char = 'x' } } });
    try testing.expectEqual(ui_state.Overlay.none, s.overlay);
    {
        var cw = capture.CaptureWriter.init(testing.allocator);
        defer cw.deinit();
        _ = try ui.render(&cw, mkInputs(&s));
        try testing.expect(std.mem.indexOf(u8, cw.output(), "Open transcript") == null); // 回输入帧
    }
}

test "E2E 内存级: Ctrl+O 开 transcript → render transcript 帧 → 再 Ctrl+O 关" {
    var s = UiState{ .rows = 10 };
    const lines = [_][]const u8{ "conv line A", "conv line B" };
    _ = ui.dispatch(&s, .{ .key = .{ .key = .ctrl_o } });
    try testing.expectEqual(ui_state.Overlay.transcript, s.overlay);
    {
        var cw = capture.CaptureWriter.init(testing.allocator);
        defer cw.deinit();
        var in = mkInputs(&s);
        in.transcript_lines = &lines;
        _ = try ui.render(&cw, in);
        const stripped = try capture.stripAnsi(testing.allocator, cw.output());
        defer testing.allocator.free(stripped);
        try capture.expectContains(stripped, "conv line A");
    }
    _ = ui.dispatch(&s, .{ .key = .{ .key = .ctrl_o } });
    try testing.expectEqual(ui_state.Overlay.none, s.overlay);
}
