//! Event + Effect —— TUI 事件驱动架构的事件定义。
//!
//! 设计见 doc/TUI_STATE_ARCHITECTURE.md。硬边界:不 import std.c、不碰 fd。
//! 各事件源(键盘/工具/tick/resize/usage)产生 Event;ui.dispatch(state, event) → Effect。

const std = @import("std");
const types = @import("../../types.zig");
const input = @import("../input.zig");
const ui_state = @import("ui_state.zig");

/// 非渲染语义动作:dispatch 无法在 UiState 内消化的,上抛主循环处理。
pub const LoopAction = enum {
    none,
    /// 当前按键应交给 LineEditor 处理(编辑操作),处理后主循环回发 editor_view 事件。
    pass_to_editor,
    /// 提交输入(回车)。
    commit,
    /// 中断/取消当前任务(esc)。
    cancel,
    /// 退出 REPL。
    exit,
};

pub const KeyEvent = struct { key: input.Key };
pub const ResizeEvent = struct { cols: u16, rows: u16 };
pub const UsageEvent = struct {
    input_tokens: u64,
    output_tokens: u64,
    cost_usd: f64 = 0,
    bg_count: usize = 0,
    cron_count: usize = 0,
    mode: types.PermissionMode = .default,
};
pub const TextChunkEvent = struct { text: []const u8 };
pub const SetToolEvent = struct { name: []const u8, start_ms: i64 };
pub const ToolCardEvent = struct { id: []const u8, name: []const u8, start_ms: i64 };
pub const ClearCardEvent = struct { id: []const u8 };
pub const ToolProgressEvent = struct { id: []const u8, text: []const u8 };
pub const PhaseChangeEvent = struct { to: ui_state.Phase };
pub const EditorViewEvent = struct { view: []const u8, cursor: usize };

/// 所有 UI 事件。闭合 union → dispatch 的 switch 漏分支编译报错(漏接线编译失败,非运行时静默)。
pub const Event = union(enum) {
    key: KeyEvent,
    tool_progress: ToolProgressEvent,
    text_chunk: TextChunkEvent,
    spinner_tick,
    resize: ResizeEvent,
    usage: UsageEvent,
    job_progress, // agent_job 进度变了 → 触发重画面板(数据在 registry,事件只触发)
    set_current_tool: SetToolEvent,
    clear_current_tool,
    add_tool_card: ToolCardEvent,
    clear_tool_card: ClearCardEvent,
    phase_change: PhaseChangeEvent,
    editor_view: EditorViewEvent,
};

/// dispatch 返回:描述需要什么副作用(由 Renderer 执行)。dispatch 本身只改 state,不碰 IO。
pub const Effect = struct {
    /// 固定区需要重画(erase 旧帧 + draw 新帧)。
    redraw_region: bool = false,
    /// 有文本进 scrollback(text_chunk);Renderer 负责 erase→print→redraw。
    emit_scroll: ?[]const u8 = null,
    /// 立即重画(不被 tick/队列延迟)——工具进度快速路径。
    immediate: bool = false,
    /// 非渲染语义动作,交主循环处理。
    action: LoopAction = .none,
};
