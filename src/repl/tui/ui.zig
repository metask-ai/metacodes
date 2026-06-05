//! dispatch + render —— TUI 状态驱动架构的纯逻辑核心。
//!
//! 设计见 doc/TUI_STATE_ARCHITECTURE.md。硬边界:本文件**不 import std.c、不碰 fd、不持 mutex**。
//!   dispatch(state, event) → Effect:纯状态转移 + 副作用描述(不执行 IO)。
//!   render(w, RenderInputs) → Frame:纯投影(state → 帧字节写入 w),时间/大数据靠注入。
//! Renderer(render_region.zig)是唯一执行 Effect/碰 fd 的地方。

const std = @import("std");
const input = @import("../input.zig");
const term = @import("term.zig");
const Theme = @import("theme.zig").Theme;
const ui_state = @import("ui_state.zig");
const event = @import("event.zig");
const agent_job_registry = @import("../../core/agent_job_registry.zig");

const UiState = ui_state.UiState;
const Event = event.Event;
const Effect = event.Effect;

/// render 的只读输入:state + 注入的时间/主题 + 大数据只读借用(测试传空/mock)。
pub const RenderInputs = struct {
    state: *const UiState,
    now_ms: i64 = 0,
    theme: Theme,
    use_unicode: bool = true,
    agent_snaps: []const agent_job_registry.AgentJobRegistry.JobSnapshot = &.{},
    queue_preview: []const []const u8 = &.{},
    transcript_lines: []const []const u8 = &.{},
};

/// 一帧的几何描述(Renderer 据此做光标定位/收缩擦除)。字节已写入 render 的 w。
pub const Frame = struct {
    rows: u16 = 0,
    cursor_row: u16 = 0,
    cursor_col: u16 = 0,
};

// ============================ dispatch ============================

/// 纯状态转移。改 state + 返回 Effect(副作用描述)。绝不碰 IO。
pub fn dispatch(state: *UiState, ev: Event) Effect {
    switch (ev) {
        .key => |k| return dispatchKey(state, k.key),
        .spinner_tick => {
            state.spinner.frame +%= 1;
            return .{ .redraw_region = true };
        },
        .resize => |r| {
            state.cols = r.cols;
            state.rows = r.rows;
            return .{ .redraw_region = true };
        },
        .usage => |u| {
            state.footer = .{
                .mode = u.mode,
                .input_tokens = u.input_tokens,
                .output_tokens = u.output_tokens,
                .cost_usd = u.cost_usd,
                .bg_count = u.bg_count,
                .cron_count = u.cron_count,
            };
            return .{ .redraw_region = true };
        },
        .text_chunk => |t| return .{ .emit_scroll = t.text },
        .tool_progress => |p| {
            ui_state.setCardProgress(state, p.id, p.text);
            return .{ .redraw_region = true, .immediate = true };
        },
        .set_current_tool => |s| {
            ui_state.setCurrentTool(state, s.name, s.start_ms);
            return .{ .redraw_region = true };
        },
        .clear_current_tool => {
            ui_state.clearCurrentTool(state);
            return .{ .redraw_region = true };
        },
        .add_tool_card => |c| {
            ui_state.addCard(state, c.id, c.name, c.start_ms);
            return .{ .redraw_region = true };
        },
        .clear_tool_card => |c| {
            ui_state.clearCard(state, c.id);
            return .{ .redraw_region = true };
        },
        .phase_change => |p| {
            state.phase = p.to;
            if (p.to == .generating) state.spinner.frame = 0;
            // 切换阶段关闭任何 overlay(生成期不弹 help/transcript)。
            if (p.to == .generating) state.overlay = .none;
            return .{ .redraw_region = true };
        },
        .editor_view => |e| {
            state.editor = .{ .view = e.view, .cursor = e.cursor };
            return .{ .redraw_region = true };
        },
        .job_progress => return .{ .redraw_region = true },
    }
}

fn dispatchKey(state: *UiState, key: input.Key) Effect {
    // overlay 优先消费按键(模态视图)。
    if (state.overlay == .transcript) return dispatchTranscriptKey(state, key);
    if (state.overlay == .help) {
        // help 下任意键关闭(对齐 CC `?` toggle)。
        state.overlay = .none;
        return .{ .redraw_region = true };
    }
    // 空 editor + '?' → 打开 help overlay(真 UI 视图,不进 editor、不需回车)。
    if (key == .char and key.char == '?' and state.editor.view.len == 0) {
        state.overlay = .help;
        return .{ .redraw_region = true };
    }
    // Ctrl+O → 切 transcript 视图态(不退 raw mode)。
    if (key == .ctrl_o) {
        state.overlay = if (state.overlay == .transcript) .none else .transcript;
        state.transcript_top = 0;
        return .{ .redraw_region = true };
    }
    // 其余按键:交 LineEditor 处理(编辑/历史/等),处理后回发 editor_view 事件。
    return .{ .action = .pass_to_editor };
}

/// transcript overlay 的滚动/退出键。
fn dispatchTranscriptKey(state: *UiState, key: input.Key) Effect {
    switch (key) {
        .ctrl_o, .esc => {
            state.overlay = .none;
            return .{ .redraw_region = true };
        },
        .char => |c| switch (c) {
            'q' => {
                state.overlay = .none;
                return .{ .redraw_region = true };
            },
            'j' => {
                state.transcript_top +|= 1;
                return .{ .redraw_region = true };
            },
            'k' => {
                state.transcript_top -|= 1;
                return .{ .redraw_region = true };
            },
            'g' => {
                state.transcript_top = 0;
                return .{ .redraw_region = true };
            },
            else => return .{ .redraw_region = false },
        },
        .down => {
            state.transcript_top +|= 1;
            return .{ .redraw_region = true };
        },
        .up => {
            state.transcript_top -|= 1;
            return .{ .redraw_region = true };
        },
        else => return .{ .redraw_region = false },
    }
}

// ============================ render ============================

/// 纯投影:state → 帧字节写入 w。按 overlay → phase 两层。
pub fn render(w: anytype, in: RenderInputs) !Frame {
    const s = in.state;
    return switch (s.overlay) {
        .help => try renderHelp(w, in),
        .transcript => try renderTranscript(w, in),
        .none => switch (s.phase) {
            .input => try renderInputFrame(w, in),
            .generating => try renderGenFrame(w, in),
        },
    };
}

/// 快捷键面板(多列;窄终端降级)。对齐 CC `?` for shortcuts。
const SHORTCUTS = [_][2][]const u8{
    .{ "Ctrl+O", "Open transcript" },
    .{ "Shift+Tab", "Cycle mode" },
    .{ "Esc", "Interrupt task" },
    .{ "Ctrl+C", "Cancel / quit" },
    .{ "Ctrl+R", "History search" },
    .{ "Ctrl+T", "Toggle task list" },
    .{ "Ctrl+G", "Edit in $EDITOR" },
    .{ "Ctrl+A/E", "Line start/end" },
    .{ "Ctrl+U/K", "Kill line" },
    .{ "Ctrl+W", "Kill word" },
    .{ "Ctrl+Y", "Yank" },
    .{ "Ctrl+_", "Undo" },
    .{ "!cmd", "Bash mode" },
    .{ "/help", "Commands" },
};

fn renderHelp(w: anytype, in: RenderInputs) !Frame {
    const th = in.theme;
    var rows: u16 = 0;
    try w.writeAll(th.dim);
    try w.writeAll(" Keyboard shortcuts:");
    try w.writeAll(th.reset);
    try w.writeAll("\r\n");
    rows += 1;
    for (SHORTCUTS) |sc| {
        try w.writeAll(th.dim);
        try w.print("  {s}", .{sc[0]});
        // 简单两列对齐:key 填充到 12 宽。
        const kw = term.displayWidth(sc[0]);
        var pad: usize = if (kw < 12) 12 - kw else 1;
        while (pad > 0) : (pad -= 1) try w.writeAll(" ");
        try w.writeAll(sc[1]);
        try w.writeAll(th.reset);
        try w.writeAll("\r\n");
        rows += 1;
    }
    return .{ .rows = rows, .cursor_row = 0, .cursor_col = 0 };
}

fn renderTranscript(w: anytype, in: RenderInputs) !Frame {
    const th = in.theme;
    const lines = in.transcript_lines;
    // 窗口:从 transcript_top 起,最多 rows-2 行(留标题+提示)。
    const view_rows: usize = if (in.state.rows > 3) in.state.rows - 3 else 1;
    var rows: u16 = 0;
    try w.writeAll(th.dim);
    try w.writeAll(" transcript (Ctrl+O / q to close · j/k scroll)");
    try w.writeAll(th.reset);
    try w.writeAll("\r\n");
    rows += 1;
    const top = @min(in.state.transcript_top, lines.len);
    var i = top;
    var shown: usize = 0;
    while (i < lines.len and shown < view_rows) : (i += 1) {
        try w.writeAll(lines[i]);
        try w.writeAll("\r\n");
        rows += 1;
        shown += 1;
    }
    return .{ .rows = rows, .cursor_row = 0, .cursor_col = 0 };
}

/// 输入期帧(阶段 0 最简版:❯ + editor view + footer 行)。
/// 后续阶段接入完整边框/多行/panel。
fn renderInputFrame(w: anytype, in: RenderInputs) !Frame {
    const th = in.theme;
    const s = in.state;
    var rows: u16 = 0;
    // ❯ 行 + editor view。
    try w.writeAll(th.accent);
    try w.writeAll("❯ ");
    try w.writeAll(th.reset);
    try w.writeAll(s.editor.view);
    try w.writeAll("\r\n");
    rows += 1;
    // footer 行(阶段 2 接入完整投影;阶段 0 先拼 mode + tokens)。
    rows += try renderFooterLine(w, in);
    const cursor_col: u16 = @intCast(2 + term.displayWidth(s.editor.view[0..@min(s.editor.cursor, s.editor.view.len)]));
    return .{ .rows = rows, .cursor_row = 0, .cursor_col = cursor_col };
}

/// 生成期帧(阶段 0 占位:spinner 行 + footer;阶段 3 接入完整)。
fn renderGenFrame(w: anytype, in: RenderInputs) !Frame {
    const th = in.theme;
    const s = in.state;
    var rows: u16 = 0;
    const elapsed = @divTrunc(@max(in.now_ms - s.spinner.start_ms, 0), 1000);
    const glyph: []const u8 = if (in.use_unicode) "*" else "*";
    try w.writeAll(th.accent);
    try w.print("{s} {s}… ({d}s · esc to interrupt)", .{ glyph, s.spinner.verb, elapsed });
    try w.writeAll(th.reset);
    try w.writeAll("\r\n");
    rows += 1;
    rows += try renderFooterLine(w, in);
    return .{ .rows = rows, .cursor_row = 0, .cursor_col = 0 };
}

/// footer 行(CC 风格:左 `{mode} on · shift+tab to cycle · ? for shortcuts` + 右 `{tok} tokens`,
/// 两端对齐)。读 UiState.footer(数据由 .usage 事件喂)。pub:render_region 委托复用(单一真相源)。
/// cols 从 in.state.cols 取。返回行数(1)。
pub fn renderFooterLine(w: anytype, in: RenderInputs) !u16 {
    const th = in.theme;
    const s = in.state;
    const mode_str = modeName(s.footer.mode);
    var left_buf: [192]u8 = undefined;
    const left = std.fmt.bufPrint(&left_buf, " {s} on · shift+tab to cycle · ? for shortcuts", .{mode_str}) catch " ? for shortcuts";
    var tok_buf: [16]u8 = undefined;
    const tok_str = formatTokens(&tok_buf, s.footer.totalTokens());
    var right_buf: [48]u8 = undefined;
    const right = std.fmt.bufPrint(&right_buf, "{s} tokens ", .{tok_str}) catch "";

    const left_w = term.displayWidth(left);
    const right_w = term.displayWidth(right);
    try w.writeAll(th.dim);
    try w.writeAll(left);
    if (s.cols > left_w + right_w) {
        const gap = s.cols - left_w - right_w;
        var i: usize = 0;
        while (i < gap) : (i += 1) try w.writeAll(" ");
        try w.writeAll(right);
    }
    try w.writeAll(th.reset);
    try w.writeAll("\r\n");
    return 1;
}

/// token 紧凑格式(<1K 原样;<1M "1.2K";>=1M "1.23M")。从 status_bar 收敛。
fn formatTokens(buf: []u8, n: u64) []const u8 {
    if (n < 1000) return std.fmt.bufPrint(buf, "{d}", .{n}) catch "0";
    if (n < 1_000_000) {
        const k = @as(f64, @floatFromInt(n)) / 1000.0;
        return std.fmt.bufPrint(buf, "{d:.1}K", .{k}) catch "0";
    }
    const m = @as(f64, @floatFromInt(n)) / 1_000_000.0;
    return std.fmt.bufPrint(buf, "{d:.2}M", .{m}) catch "0";
}

fn modeName(m: @import("../../types.zig").PermissionMode) []const u8 {
    return switch (m) {
        .default => "default",
        .accept_edits => "acceptEdits",
        .plan => "plan",
        .auto => "auto",
        .dont_ask => "dontAsk",
        .bypass_permissions => "bypassPermissions",
        .prompt => "prompt",
        .bypass => "bypass",
    };
}
