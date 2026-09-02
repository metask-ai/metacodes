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
    // ── 全局快捷键上抛(dispatch 识别键 → 上抛,调用方按自己能力执行 IO)──────────
    // dispatch 是纯函数不碰 fd/raw-mode/子进程/history,这些动作的 IO 体留在调用方
    // (输入期 loop.zig / 生成期 tui_backend.zig)。生成期对无意义的(history/complete/
    // reverse_search/external_edit)在 dispatch 内就 gate 掉,不会上抛到这。
    /// ↑ 上一条历史(调用方查 history → editor.setLine)。
    history_prev,
    /// ↓ 下一条历史。
    history_next,
    /// ↑ 在多行/软折缓冲里竖移光标(调用方经 RenderRegion.tryVerticalMove 算落点;
    /// 边界=首可视行时回退 history_prev)。详见 INPUT_BEHAVIOR_DIFF_2026-06-11.md。
    cursor_up,
    /// ↓ 同上,边界=末可视行时回退 history_next。
    cursor_down,
    /// Tab 补全(调用方跑补全引擎)。
    complete,
    /// Ctrl+R 反向搜索(调用方进独占 fd 读循环)。
    reverse_search,
    /// 打开 transcript 全屏查看器(调用方进 alt-screen 独占 fd 读循环,
    /// 复用 transcript_viewer.runWithTheme)。两期共用。
    /// issue #16 起绑定 `Ctrl+X Ctrl+O`(Ctrl+O 让给 model picker,对齐 Hermes);
    /// `/transcript` 命令是等价的可发现入口。
    open_transcript,
    /// issue #16: Ctrl+O / `/model` 打开跨 UI model picker。调用方刷新快照后置
    /// `ui.picker_open`。两期共用——生成中改选择只影响下一轮。
    open_model_picker,
    /// picker 开着时的按键已由 dispatch 交给 picker 状态机;调用方按 Outcome
    /// 重画、关闭或提交。key 见 Effect.picker_key。
    picker_key,
    /// Ctrl+G 外部编辑器(调用方暂退 raw mode 起 $EDITOR)。
    external_edit,
    /// Ctrl+L 清屏重画。
    redraw_screen,
    /// Ctrl+X Ctrl+K 杀所有后台任务。
    kill_background,
    /// Ctrl+B 生成期把当前主对话转后台续跑(调用方深拷贝 conversation → spawnBackground →
    /// reset 前台)。仅生成期上抛;输入期无意义,dispatch gate 掉。
    background_main,
    /// Shift+Tab 循环权限模式(调用方 App.cyclePermMode 只写 permission_ctx.mode=单一源;U2 S2)。
    cycle_perm_mode,
    /// slash 菜单选中(Enter):调用方把 editor buffer 换成选中命令名后**提交**。
    /// 选中项 = complete.slashNthMatch(view, state.slash_sel)。
    slash_select,
    /// slash 菜单补全(Tab):把 editor buffer 换成选中命令名但**不提交**(留用户补参数)。
    slash_complete,
    /// /model 服务端模型菜单导航(↑↓):调用方按 catalog 数量移动 slash_sel。
    model_nav,
    /// /model 服务端模型菜单选中(Enter):调用方提交 `/model use <id>`。
    model_select,
    /// /model 服务端模型菜单补全(Tab):调用方填入 `/model use <id>` 但不提交。
    model_complete,
    /// /models 两级菜单导航(账号 API key → 模型)。
    models_nav,
    /// /models 两级菜单选中。
    models_select,
    /// @-mention 菜单导航(↑↓):调用方(有 allocator)算文件候选数、移 slash_sel、重画。
    /// dir 见 Effect.at_nav_dir(true=down/false=up)。dispatch 无 allocator 不能算候选数,故上抛。
    at_nav,
    /// @-mention 选中(Enter/Tab):调用方把 @token 换成选中文件路径。Enter 后不自动提交
    /// (对齐 cc:@ 插入引用后继续编辑);区别仅语义,均插入。
    at_select,
    // ── Agent switcher(区域2,对齐 cc v2.1.168)──────────────────────────────────
    /// Enter 查看选中 agent 的 transcript(调用方读 registry.copyTranscript → alt-screen 显示)。
    /// 选中 agent id 由调用方按 ui.agents.sel 从 snapshotJobs 解析。
    agents_view,
    /// x 停止选中 agent(调用方 registry.kill(id))。
    agents_stop,
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
pub const ToolCardEvent = struct { id: []const u8, name: []const u8, input: []const u8 = "", start_ms: i64 };
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
    /// nav 方向:true=down(下/选下一个),false=up。仅 action==.at_nav/.model_nav/.models_nav 时有意义。
    at_nav_dir: bool = true,
    /// 仅 action==.picker_key 时有意义:要喂给 picker 状态机的键。
    picker_key: @import("../model_picker.zig").Key = .escape,
};
