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
const complete = @import("../complete.zig");
const agent_job_registry = @import("../../core/agent_job_registry.zig");

const UiState = ui_state.UiState;
const Event = event.Event;
const Effect = event.Effect;

/// agent viewing 视口 PageUp/Dn 翻页步长(dispatch 无几何 → 固定行数,render 层按真实 view_rows clamp)。
const VIEW_PAGE_STEP: usize = 10;

/// render 的只读输入:state + 注入的时间/主题 + 大数据只读借用(测试传空/mock)。
pub const RenderInputs = struct {
    state: *const UiState,
    now_ms: i64 = 0,
    theme: Theme,
    use_unicode: bool = true,
    agent_snaps: []const agent_job_registry.AgentJobRegistry.JobSnapshot = &.{},
    queue_preview: []const []const u8 = &.{},
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
            ui_state.addCard(state, c.id, c.name, c.input, c.start_ms);
            return .{ .redraw_region = true };
        },
        .clear_tool_card => |c| {
            ui_state.clearCard(state, c.id);
            return .{ .redraw_region = true };
        },
        .phase_change => |p| {
            state.phase = p.to;
            if (p.to == .generating) state.spinner.frame = 0;
            // 切换到生成期关闭非模态 help(生成期不弹)。
            if (p.to == .generating) {
                state.help_open = false;
            }
            return .{ .redraw_region = true };
        },
        .editor_view => |e| {
            state.editor = .{ .view = e.view, .cursor = e.cursor };
            // slash 菜单选中项随 buffer 变化归位:菜单关 → 重置 0;过滤变窄 → 钳到末项。
            // (打字改前缀会重排匹配列表,选中项不归位会指向错命令。)
            const n = complete.slashFilterCount(e.view);
            if (n == 0) {
                state.slash_sel = 0;
            } else if (state.slash_sel >= n) {
                state.slash_sel = n - 1;
            }
            return .{ .redraw_region = true };
        },
        .job_progress => return .{ .redraw_region = true },
    }
}

fn dispatchKey(state: *UiState, key: input.Key) Effect {
    // Ctrl+X Ctrl+K 序列(Emacs 双键前缀,杀后台任务)。arming 在 UiState,dispatch 统一处理。
    // 进入即消费上次的 armed(每键清一次,除非本键是 Ctrl+X 重新设)→ 防粘连。
    const was_x_armed = state.ctrl_x_armed;
    state.ctrl_x_armed = false;
    if (key == .ctrl_x) {
        state.ctrl_x_armed = true; // 等下一个键
        return .{ .redraw_region = false }; // Ctrl+X 单独无视觉变化
    }
    if (was_x_armed and key == .ctrl_k) {
        return .{ .action = .kill_background }; // Ctrl+X Ctrl+K → 杀后台(两期共用)
    }
    // (was_x_armed 但下个键非 Ctrl+K:armed 已清,该键照常走下面分发,如 Ctrl+K 单按=kill-line)

    // `?` 帮助(非模态,对齐 cc onChange):空 editor 打 `?` → toggle help_open,`?` 不进 editor。
    if (key == .char and key.char == '?' and state.editor.view.len == 0) {
        state.help_open = !state.help_open;
        return .{ .redraw_region = true };
    }
    // help 开着时按键:Esc 仅关闭 help(消费,不透传——对齐 cc:Esc 是 help dismiss 键,
    // 不顺带清 draft/中断);其它键关 help 并继续正常处理(非模态,该键照常生效)。
    var help_closed = false;
    if (state.help_open) {
        state.help_open = false;
        if (key == .esc) {
            // Esc 消费:只关 help + 重画,不透传给编辑器。
            return .{ .redraw_region = true };
        }
        help_closed = true; // 标记:末尾 pass_to_editor 要带 redraw_region(让 help 菜单消屏)。
    }

    // Ctrl+O → 打开 transcript 全屏查看器(alt-screen)。dispatch 不碰 fd/raw-mode,
    // 上抛 .open_transcript,IO 体留调用方(输入期 loop.zig / 生成期 tui_backend.zig
    // 进 alt-screen 调 transcript_viewer.runWithTheme)。两期共用。
    if (key == .ctrl_o) {
        return .{ .action = .open_transcript };
    }
    // Ctrl+B → 生成期把主对话转后台续跑(对齐 cc task:background)。仅生成期有意义
    // (输入期没有正在跑的 run,返 redraw no-op 消费掉)。IO 体(深拷贝 conversation +
    // spawnBackground + reset 前台)留调用方 tui_backend/loop。MVP 单击即转(agent_tree 已有
    // 常驻 hint "(ctrl+b to run in background)" 作发现性;双击防抖留后续增强)。
    if (key == .ctrl_b) {
        if (state.phase == .generating) return .{ .action = .background_main };
        return .{ .redraw_region = false };
    }
    // Ctrl+T → 切 task 面板显隐(对齐 cc app:toggleTodos)。纯内存 toggle,两期共用。
    // drawPanel/drawTaskList 读 panel.task_list_visible 门控。
    if (key == .ctrl_t) {
        state.panel.task_list_visible = !state.panel.task_list_visible;
        return .{ .redraw_region = true };
    }

    // ── /models 两级账号 API key / model 菜单导航。必须先于普通 slash 菜单。
    {
        const gen_models = state.phase == .generating;
        if (!gen_models and complete.modelsMenuOpen(state.editor.view)) {
            switch (key) {
                .down => return .{ .action = .models_nav, .at_nav_dir = true },
                .up => return .{ .action = .models_nav, .at_nav_dir = false },
                .enter => return .{ .action = .models_select },
                else => {},
            }
        }
    }

    // ── /model 服务端 catalog 菜单导航。必须先于普通 slash 菜单,否则 `/model`
    // 会被当成单个 slash command,方向键无法选择模型。
    {
        const gen0 = state.phase == .generating;
        if (!gen0 and complete.modelMenuOpen(state.editor.view)) {
            switch (key) {
                .down => return .{ .action = .model_nav, .at_nav_dir = true },
                .up => return .{ .action = .model_nav, .at_nav_dir = false },
                .enter => return .{ .action = .model_select },
                .tab => return .{ .action = .model_complete },
                else => {},
            }
        }
    }

    // ── slash 菜单导航(对齐 cc DIFF#4:`/` 菜单 ↑↓ 移高亮 + Enter 选中 + Tab 补全)──────
    // 仅输入期 + 菜单开(`/` 前缀无空格且有匹配)时介入,抢 ↑↓/Enter/Tab 语义;
    // 否则这些键照常走历史导航/提交/补全。菜单关时 slash_sel 恒 0(下方非 `/` 态会重置)。
    {
        const gen0 = state.phase == .generating;
        const view = state.editor.view;
        if (!gen0 and complete.slashMenuOpen(view)) {
            const n = complete.slashFilterCount(view);
            if (state.slash_sel >= n) state.slash_sel = if (n == 0) 0 else n - 1;
            switch (key) {
                .down => {
                    state.slash_sel = (state.slash_sel + 1) % n; // 循环(对齐 cc 列表滚动)
                    return .{ .redraw_region = true };
                },
                .up => {
                    state.slash_sel = if (state.slash_sel == 0) n - 1 else state.slash_sel - 1;
                    return .{ .redraw_region = true };
                },
                .enter => return .{ .action = .slash_select }, // 填命令 + 提交
                .tab => return .{ .action = .slash_complete }, // 仅补全(不提交)
                else => {},
            }
        }
    }

    // ── @-mention 菜单导航(对齐 cc DIFF#5)──────────────────────────────────────
    // dispatch 无 allocator → 不能算文件候选数,只能检测 @ 激活并上抛动作;
    // 候选数/slash_sel 钳位 + 插入由 loop.zig(有 allocator)处理。
    {
        const gen1 = state.phase == .generating;
        if (!gen1 and complete.atMenuActive(state.editor.view, state.editor.cursor)) {
            switch (key) {
                .down => return .{ .action = .at_nav, .at_nav_dir = true },
                .up => return .{ .action = .at_nav, .at_nav_dir = false },
                .enter => return .{ .action = .at_select },
                .tab => return .{ .action = .at_select },
                else => {},
            }
        }
    }

    // ── Agent switcher(区域2,对齐 cc v2.1.168)──────────────────────────────────
    // 已在 list 态:↑/↓ 移动选择、enter 查看/关、esc 关、x 停。抢这些键(优先于历史/编辑)。
    // 打开入口:`←`(输入期 editor 空 + 有 agent) / `↓`(生成期 + 有 running agent)。
    // 严格 gate 防破坏光标移动/历史导航。
    {
        const gen2 = state.phase == .generating;
        if (state.agents.view == .list) {
            switch (key) {
                .up => {
                    state.agents.selectUp();
                    return .{ .redraw_region = true };
                },
                .down => {
                    state.agents.selectDown(state.agent_count);
                    return .{ .redraw_region = true };
                },
                .enter => {
                    // sel==0(main)→ 关闭回 main;否则进**持久 viewing**(分隔 label 变被查看 agent
                    // 的 desc + switcher marker ⏺)。viewing_id 在 render 层落定(committed=false 触发)。
                    if (state.agents.sel == 0) {
                        state.agents.close();
                        return .{ .redraw_region = true };
                    }
                    state.agents.view = .viewing;
                    state.agents.viewing_committed = false; // render 下一帧把 sel 对应 id 落定
                    return .{ .redraw_region = true };
                },
                .esc => {
                    state.agents.close();
                    return .{ .redraw_region = true };
                },
                .char => {
                    if (key.char == 'x' and state.agents.selection_active and state.agents.sel > 0) {
                        return .{ .action = .agents_stop };
                    }
                },
                else => {},
            }
            // list 态吞掉其它键(不透传编辑器),避免误打字。
            return .{ .redraw_region = false };
        }
        // viewing 态:↑/↓ **只移 ❯ 高亮**(不切被查看对象——对齐真 cc:Enter 才提交);
        // Enter on sel>0 → 重新落定 viewing_id(切到新选中 agent);esc 退回 list。
        if (state.agents.view == .viewing) {
            switch (key) {
                .up => {
                    state.agents.selectUp();
                    // sel 回到 0(main)→ 退出 viewing 回 list(main 无可查看对象)。
                    if (state.agents.sel == 0) state.agents.view = .list;
                    return .{ .redraw_region = true };
                },
                .down => {
                    state.agents.selectDown(state.agent_count);
                    return .{ .redraw_region = true };
                },
                .enter => {
                    // 在 viewing 态对当前高亮的 agent 再按 Enter → 切换被查看对象(render 落定新 id)。
                    if (state.agents.sel > 0) state.agents.viewing_committed = false;
                    return .{ .redraw_region = true };
                },
                .page_up => {
                    // 视口上翻(dispatch 无几何 → 用固定 step,render 层按真实 view_rows clamp)。
                    state.agents.viewPageUp(VIEW_PAGE_STEP);
                    return .{ .redraw_region = true };
                },
                .page_down => {
                    state.agents.viewPageDown(VIEW_PAGE_STEP);
                    return .{ .redraw_region = true };
                },
                .esc => {
                    state.agents.view = .list; // 退回列表(再 esc 关闭)
                    return .{ .redraw_region = true };
                },
                .char => {
                    if (key.char == 'x' and state.agents.sel > 0) return .{ .action = .agents_stop };
                },
                else => {},
            }
            return .{ .redraw_region = false };
        }
        // 未打开:检测入口键。
        if (state.agents.view == .closed and state.agent_count > 0) {
            if (!gen2 and key == .left and state.editor.view.len == 0) {
                // 空闲 + editor 空 + 有 agent → 进 list(对齐实拍 `← for agents`)。
                state.agents.view = .list;
                state.agents.selection_active = false;
                state.agents.sel = 0;
                return .{ .redraw_region = true };
            }
            if (gen2 and key == .down) {
                // 生成期 `↓ to manage` → 进 list + 立即激活选择(实拍 ↓ 直接出 ❯)。
                state.agents.view = .list;
                state.agents.selectDown(state.agent_count);
                return .{ .redraw_region = true };
            }
        }
    }

    // ── 全局快捷键:dispatch 识别 → 上抛 LoopAction,IO 体留调用方(两期共用解析)──────
    // 按 UiState gate:生成期对无意义的键(history/complete/reverse_search/external_edit)
    // 直接吞掉(无补全器/无搜索 UI/不起 $EDITOR),不上抛、不透传。
    const gen = state.phase == .generating;
    switch (key) {
        // 两期都激活的全局键。
        .shift_tab => return .{ .action = .cycle_perm_mode },
        .ctrl_l => return .{ .action = .redraw_screen },
        // 仅输入期激活:生成期无对应子系统 → 吞掉(redraw_region=false,不透传不上抛)。
        // up/down 上抛 cursor_up/down(非直接 history):loop 经 RenderRegion 判可视行边界,
        // 多行/软折缓冲里竖移,仅首/末可视行才回退历史。dispatch 无宽度看不到软折,故不在此决断。
        .up => return if (gen) .{} else .{ .action = .cursor_up },
        .down => return if (gen) .{} else .{ .action = .cursor_down },
        .tab => return if (gen) .{} else .{ .action = .complete },
        .ctrl_r => return if (gen) .{} else .{ .action = .reverse_search },
        .ctrl_g => return if (gen) .{} else .{ .action = .external_edit },
        else => {},
    }

    // 其余按键:交 LineEditor 处理。若刚关了 help,带上 redraw_region 让 help 菜单从屏消失。
    return .{ .redraw_region = help_closed, .action = .pass_to_editor };
}

// ============================ render ============================

/// 纯投影:state → 帧字节写入 w。按 phase 渲染输入/生成帧。
/// transcript 现走 alt-screen viewer(transcript_viewer.zig),不再嵌入式渲染。
/// `?` help 非模态——在 renderInputFrame 内把 footer 区换成快捷键菜单(输入框仍在)。
pub fn render(w: anytype, in: RenderInputs) !Frame {
    const s = in.state;
    return switch (s.phase) {
        .input => try renderInputFrame(w, in),
        .generating => try renderGenFrame(w, in),
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

/// help_open 时画在 footer 区的快捷键菜单(**非模态**,输入框在上方仍可打字)。
/// 对齐 cc PromptInputHelpMenu:多列紧凑布局,占据 footer 行位置。返回写出的行数。
/// pub + 泛型 writer/theme/cols:render_region(真 tty 输入帧)复用同一份,避免第三处重复。
/// 注:行首不写 clear.line(调用方按需注入,如 render_region 自带 ansi.clear.line)。
pub fn renderHelpLines(w: anytype, th: Theme, cols: u16) !u16 {
    // 每项宽度预算(key 12 + desc ~18 + 间隔)。窄终端 1 列,够宽 2 列。
    const per_item: u16 = 34;
    const ncol: usize = if (cols >= per_item * 2) 2 else 1;
    var rows: u16 = 0;
    var i: usize = 0;
    while (i < SHORTCUTS.len) : (i += ncol) {
        try w.writeAll(th.dim);
        var c: usize = 0;
        while (c < ncol and i + c < SHORTCUTS.len) : (c += 1) {
            const sc = SHORTCUTS[i + c];
            try w.print("  {s}", .{sc[0]});
            const kw = term.displayWidth(sc[0]);
            var pad: usize = if (kw < 12) 12 - kw else 1;
            while (pad > 0) : (pad -= 1) try w.writeAll(" ");
            try w.writeAll(sc[1]);
            // 列间补到 per_item 宽(末列不补)。
            if (c + 1 < ncol and i + c + 1 < SHORTCUTS.len) {
                const used = 2 + 12 + term.displayWidth(sc[1]);
                var gap: usize = if (used < per_item) per_item - used else 1;
                while (gap > 0) : (gap -= 1) try w.writeAll(" ");
            }
        }
        try w.writeAll(th.reset);
        try w.writeAll("\r\n");
        rows += 1;
    }
    return rows;
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
    // footer 区:help_open 时原地展开快捷键菜单(非模态,输入框仍在);否则正常 footer 行。
    if (s.help_open) {
        rows += try renderHelpLines(w, in.theme, s.cols);
    } else {
        rows += try renderFooterLine(w, in);
    }
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

/// footer 行(cc 风格,纯左对齐,**无右侧 token**):
///   非 default → `{symbol} {title} on (shift+tab to cycle)`;default → `? for shortcuts`。
/// 读 UiState.footer(数据由 .usage 事件喂)。mode part 按 status_bar.modeColor 单独着色。
/// pub:render_region 委托复用。cols 从 in.state.cols 取。
pub fn renderFooterLine(w: anytype, in: RenderInputs) !u16 {
    const th = in.theme;
    const s = in.state;
    const sb = @import("widget/status_bar.zig");
    const mode_pm = s.footer.mode;
    const sym = sb.modeSymbol(mode_pm);
    const title = sb.modeTitle(mode_pm);
    const show_mode = title.len != 0;

    var mode_buf: [96]u8 = undefined;
    const mode_plain = if (show_mode)
        (std.fmt.bufPrint(&mode_buf, " {s} {s} on (shift+tab to cycle)", .{ sym, title }) catch "")
    else
        "";
    // cc 对齐:非 default mode part 含括号 cycle 提示,hint 留空;default 显 `? for shortcuts`。
    const hint = if (show_mode) "" else " ? for shortcuts";

    // cc footer 纯左对齐快捷键,无右侧 token。
    if (show_mode) {
        try w.writeAll(sb.modeColor(th, mode_pm));
        try w.writeAll(mode_plain);
        try w.writeAll(th.reset);
    }
    try w.writeAll(th.dim);
    try w.writeAll(hint);
    try w.writeAll(th.reset);
    try w.writeAll("\r\n");
    return 1;
}
