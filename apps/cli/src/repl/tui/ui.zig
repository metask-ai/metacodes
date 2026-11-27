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
const agent_job_registry = @import("metacodes-internal").core.agent_job_registry;

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
        .key => |k| return dispatchKey(state, k.key, k.now_ms),
        .spinner_tick => {
            const g = state.generatingPhase() orelse return .{};
            g.spinner.frame +%= 1;
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
        // 工具状态归生成期所有:回复结束后才到的事件没有可更新的卡片,也不触发重画。
        // 重画走哪条通道由渲染器按事件来源定(#328):tool progress 走合并窗口,孤立的当场画。
        .tool_progress => |p| {
            if (state.phase != .generating) return .{};
            ui_state.setCardProgress(state, p.id, p.text);
            return .{ .redraw_region = true };
        },
        .set_current_tool => |s| {
            if (state.phase != .generating) return .{};
            ui_state.setCurrentTool(state, s.name, s.start_ms);
            return .{ .redraw_region = true };
        },
        .clear_current_tool => {
            if (state.phase != .generating) return .{};
            ui_state.clearCurrentTool(state);
            return .{ .redraw_region = true };
        },
        .add_tool_card => |c| {
            if (state.phase != .generating) return .{};
            ui_state.addCard(state, c.id, c.name, c.input, c.start_ms);
            return .{ .redraw_region = true };
        },
        .clear_tool_card => |c| {
            if (state.phase != .generating) return .{};
            ui_state.clearCard(state, c.id);
            return .{ .redraw_region = true };
        },
        // 唯一的 teardown 点:旧阶段打开的 help/agent 列表/菜单高亮/双击窗口/工具卡……随 payload
        // 一起消失(#330,取代散在各边界的 resetPhaseUi)。
        .phase_change => |entry| {
            state.enter(entry);
            return .{ .redraw_region = true };
        },
        .editor_view => |e| {
            const ix = state.interaction() orelse return .{};
            ix.editor = .{ .view = e.view, .cursor = e.cursor };
            // slash 菜单选中项随 buffer 变化归位:菜单关 → 重置 0;过滤变窄 → 钳到末项。
            // (打字改前缀会重排匹配列表,选中项不归位会指向错命令。)
            if (state.inputPhase()) |p| {
                const n = complete.slashFilterCount(p.slash_catalog, e.view);
                if (n == 0) {
                    p.slash_sel = 0;
                } else if (p.slash_sel >= n) {
                    p.slash_sel = n - 1;
                }
            }
            return .{ .redraw_region = true };
        },
        .job_progress => return .{ .redraw_region = true },
    }
}

fn dispatchKey(state: *UiState, key: input.Key, now_ms: i64) Effect {
    // 按键只属于交互阶段:idle 时没有输入框,也没有能接收它的 widget。
    const ix = state.interaction() orelse return .{};
    // Ctrl+X Ctrl+K 序列(Emacs 双键前缀,杀后台任务)。arming 在 UiState,dispatch 统一处理。
    // 进入即消费上次的 armed(每键清一次,除非本键是 Ctrl+X 重新设)→ 防粘连。
    const was_x_armed = ix.ctrl_x_armed;
    ix.ctrl_x_armed = false;
    if (key == .ctrl_x) {
        ix.ctrl_x_armed = true; // 等下一个键
        return .{ .redraw_region = false }; // Ctrl+X 单独无视觉变化
    }
    if (was_x_armed and key == .ctrl_k) {
        return .{ .action = .kill_background }; // Ctrl+X Ctrl+K → 杀后台(两期共用)
    }
    // issue #16:Ctrl+O 让给 model picker(对齐 Hermes),transcript 查看器改绑
    // `Ctrl+X Ctrl+O`——同一个字母、复用已有的 Ctrl+X 前缀,肌肉记忆不丢;
    // `/transcript` 是等价的可发现入口。两条路都在 TTY 回归里锁住。
    if (was_x_armed and key == .ctrl_o) {
        return .{ .action = .open_transcript };
    }
    if (key == .ctrl_z) return .{ .action = .suspend_process };
    // (was_x_armed 但下个键非 Ctrl+K:armed 已清,该键照常走下面分发,如 Ctrl+K 单按=kill-line)

    // ── issue #16: model picker 开着时,键盘属于它 ──────────────────────────
    // 对键模态(普通字符是它的过滤器),对会话不模态:草稿不动、生成不停。
    // 输入期的 Ctrl+C 不管 picker 停在哪一步都直接关掉它(#607),再按才回到提示符的双击退出;
    // Ctrl+D 和生成期的 Ctrl+C 不拦——用户永远有一条不依赖本状态机的退出路径。
    if (ix.picker_open and key == .ctrl_c and state.phase == .input) {
        return .{ .action = .picker_key, .picker_key = .cancel };
    }
    if (ix.picker_open and key != .ctrl_c and key != .ctrl_d) {
        const mapped: ?@import("../model_picker.zig").Key = switch (key) {
            .up => .up,
            .down => .down,
            .page_up => .page_up,
            .page_down => .page_down,
            .home => .home,
            .end => .end,
            .left => .left,
            .right => .right,
            .enter => .enter,
            .esc => .escape,
            .backspace => .backspace,
            // Tab cycles scope. It cannot be a filter character, so it is the
            // one key that can carry an explicit choice without stealing input.
            .tab => .cycle_scope,
            .ctrl_r => .retry,
            .char => |byte| .{ .char = byte },
            else => null,
        };
        if (mapped) |picker_key| return .{ .action = .picker_key, .picker_key = picker_key };
        return .{ .redraw_region = false };
    }
    if (ix.picker_open and key == .ctrl_d and ix.editor.view.len > 0) return .{ .redraw_region = false };

    // `?` 帮助(非模态,对齐 cc onChange):空 editor 打 `?` → toggle help_open,`?` 不进 editor。
    if (key == .char and key.char == '?' and ix.editor.view.len == 0) {
        ix.help_open = !ix.help_open;
        return .{ .redraw_region = true };
    }
    // help 开着时按键:Esc 仅关闭 help(消费,不透传——对齐 cc:Esc 是 help dismiss 键,
    // 不顺带清 draft/中断);其它键关 help 并继续正常处理(非模态,该键照常生效)。
    var help_closed = false;
    if (ix.help_open) {
        ix.help_open = false;
        if (key == .esc) {
            // Esc 消费:只关 help + 重画,不透传给编辑器。
            return .{ .redraw_region = true };
        }
        help_closed = true; // 标记:末尾 pass_to_editor 要带 redraw_region(让 help 菜单消屏)。
    }

    // Idle prompt: Ctrl+C and an empty prompt's Ctrl+D exit on a second press
    // inside the window (Claude Code `useExitOnCtrlCD`); the first press shows
    // `Press Ctrl-C again to exit` in the footer. Ctrl+C also discards the
    // draft. Nothing reaches the scrollback. A reply in flight owns these keys
    // (the watcher interrupts it), so this is input-phase only.
    if (state.inputPhase()) |p| switch (key) {
        .ctrl_c => {
            if (p.press.press(.exit_ctrl_c, now_ms)) return .{ .action = .exit_prompt };
            if (ix.editor.view.len > 0) return .{ .redraw_region = true, .action = .discard_draft };
            return .{ .redraw_region = true };
        },
        .ctrl_d => if (ix.editor.view.len == 0) {
            if (p.press.press(.exit_ctrl_d, now_ms)) return .{ .action = .exit_prompt };
            return .{ .redraw_region = true };
        },
        else => {},
    };

    // Ctrl+O → 打开 model picker(issue #16;transcript 查看器移到 Ctrl+X Ctrl+O)。
    // dispatch 不碰 fd/registry/网络,上抛 .open_model_picker,快照刷新与渲染留调用方。
    // 两期共用:生成中也能开,改动只影响下一轮。
    if (key == .ctrl_o) {
        return .{ .action = .open_model_picker };
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

    // 建议菜单(`/models`、`/model`、`/`、`@`)都从输入期草稿派生,只在输入期存在。
    if (state.inputPhase()) |p| {
        const view = ix.editor.view;
        // Esc closes whichever suggestion menu the draft opened and keeps the
        // draft (Claude Code); the next Esc is the draft's own double press.
        // While dismissed the menus neither render nor take ↑/↓/Enter/Tab.
        const menus_dismissed = p.menu_dismissal.covers(view);
        if (key == .esc and !menus_dismissed and suggestionMenuOpen(state)) {
            p.menu_dismissal.dismiss(view);
            return .{ .redraw_region = true };
        }
        if (!menus_dismissed) {
            // ── /models 两级账号 API key / model 菜单导航。必须先于普通 slash 菜单。
            if (complete.modelsMenuOpen(view)) {
                switch (key) {
                    .down => return .{ .action = .models_nav, .menu_step = .next },
                    .up => return .{ .action = .models_nav, .menu_step = .previous },
                    .page_down => return .{ .action = .models_nav, .menu_step = .page_down },
                    .page_up => return .{ .action = .models_nav, .menu_step = .page_up },
                    .home => return .{ .action = .models_nav, .menu_step = .first },
                    .end => return .{ .action = .models_nav, .menu_step = .last },
                    .enter => return .{ .action = .models_select },
                    else => {},
                }
            }

            // ── /model 服务端 catalog 菜单导航。必须先于普通 slash 菜单,否则 `/model`
            // 会被当成单个 slash command,方向键无法选择模型。
            if (complete.modelMenuOpen(view)) {
                switch (key) {
                    .down => return .{ .action = .model_nav, .at_nav_dir = true },
                    .up => return .{ .action = .model_nav, .at_nav_dir = false },
                    .enter => return .{ .action = .model_select },
                    .tab => return .{ .action = .model_complete },
                    else => {},
                }
            }

            // ── slash 菜单导航(对齐 cc DIFF#4:`/` 菜单 ↑↓ 移高亮 + Enter 选中 + Tab 补全)──────
            // 菜单开(`/` 前缀无空格且有匹配)时介入,抢 ↑↓/Enter/Tab 语义;
            // 否则这些键照常走历史导航/提交/补全。菜单关时 slash_sel 恒 0(editor_view 会重置)。
            if (complete.slashMenuOpen(p.slash_catalog, view)) {
                const n = complete.slashFilterCount(p.slash_catalog, view);
                if (p.slash_sel >= n) p.slash_sel = if (n == 0) 0 else n - 1;
                switch (key) {
                    .down => {
                        p.slash_sel = (p.slash_sel + 1) % n; // 循环(对齐 cc 列表滚动)
                        return .{ .redraw_region = true };
                    },
                    .up => {
                        p.slash_sel = if (p.slash_sel == 0) n - 1 else p.slash_sel - 1;
                        return .{ .redraw_region = true };
                    },
                    .enter => return .{ .action = .slash_select }, // 填命令 + 提交
                    .tab => return .{ .action = .slash_complete }, // 仅补全(不提交)
                    else => {},
                }
            }

            // ── @-mention 菜单导航(对齐 cc DIFF#5)──────────────────────────────────────
            // dispatch 无 allocator → 不能算文件候选数,只能检测 @ 激活并上抛动作;
            // 候选数/slash_sel 钳位 + 插入由 loop.zig(有 allocator)处理。
            if (complete.atMenuActive(view, ix.editor.cursor)) {
                switch (key) {
                    .down => return .{ .action = .at_nav, .at_nav_dir = true },
                    .up => return .{ .action = .at_nav, .at_nav_dir = false },
                    .enter => return .{ .action = .at_select },
                    .tab => return .{ .action = .at_select },
                    else => {},
                }
            }
        }
    }

    // ── Agent switcher(区域2,对齐 cc v2.1.168)──────────────────────────────────
    // 已在 list 态:↑/↓ 移动选择、enter 查看/关、esc 关、x 停。抢这些键(优先于历史/编辑)。
    // 打开入口:`←`(输入期 editor 空 + 有 agent) / `↓`(生成期 + 有 running agent)。
    // 严格 gate 防破坏光标移动/历史导航。
    {
        const gen2 = state.phase == .generating;
        if (ix.agents.view == .list) {
            switch (key) {
                .up => {
                    ix.agents.selectUp();
                    return .{ .redraw_region = true };
                },
                .down => {
                    ix.agents.selectDown(state.agent_count);
                    return .{ .redraw_region = true };
                },
                .enter => {
                    // sel==0(main)→ 关闭回 main;否则进**持久 viewing**(分隔 label 变被查看 agent
                    // 的 desc + switcher marker ⏺)。viewing_id 在 render 层落定(committed=false 触发)。
                    if (ix.agents.sel == 0) {
                        ix.agents.close();
                        return .{ .redraw_region = true };
                    }
                    ix.agents.view = .viewing;
                    ix.agents.viewing_committed = false; // render 下一帧把 sel 对应 id 落定
                    return .{ .redraw_region = true };
                },
                .esc => {
                    ix.agents.close();
                    return .{ .redraw_region = true };
                },
                .char => {
                    if (key.char == 'x' and ix.agents.selection_active and ix.agents.sel > 0) {
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
        if (ix.agents.view == .viewing) {
            switch (key) {
                .up => {
                    ix.agents.selectUp();
                    // sel 回到 0(main)→ 退出 viewing 回 list(main 无可查看对象)。
                    if (ix.agents.sel == 0) ix.agents.view = .list;
                    return .{ .redraw_region = true };
                },
                .down => {
                    ix.agents.selectDown(state.agent_count);
                    return .{ .redraw_region = true };
                },
                .enter => {
                    // 在 viewing 态对当前高亮的 agent 再按 Enter → 切换被查看对象(render 落定新 id)。
                    if (ix.agents.sel > 0) ix.agents.viewing_committed = false;
                    return .{ .redraw_region = true };
                },
                .page_up => {
                    // 视口上翻(dispatch 无几何 → 用固定 step,render 层按真实 view_rows clamp)。
                    ix.agents.viewPageUp(VIEW_PAGE_STEP);
                    return .{ .redraw_region = true };
                },
                .page_down => {
                    ix.agents.viewPageDown(VIEW_PAGE_STEP);
                    return .{ .redraw_region = true };
                },
                .esc => {
                    ix.agents.view = .list; // 退回列表(再 esc 关闭)
                    return .{ .redraw_region = true };
                },
                .char => {
                    if (key.char == 'x' and ix.agents.sel > 0) return .{ .action = .agents_stop };
                },
                else => {},
            }
            return .{ .redraw_region = false };
        }
        // 未打开:检测入口键。
        if (ix.agents.view == .closed and state.agent_count > 0) {
            if (!gen2 and key == .left and ix.editor.view.len == 0) {
                // 空闲 + editor 空 + 有 agent → 进 list(对齐实拍 `← for agents`)。
                ix.agents.view = .list;
                ix.agents.selection_active = false;
                ix.agents.sel = 0;
                return .{ .redraw_region = true };
            }
            if (gen2 and key == .down) {
                // 生成期 `↓ to manage` → 进 list + 立即激活选择(实拍 ↓ 直接出 ❯)。
                ix.agents.view = .list;
                ix.agents.selectDown(state.agent_count);
                return .{ .redraw_region = true };
            }
        }
    }

    // Idle prompt Esc: a second press inside the window clears the draft and
    // keeps it in history; the first shows `Esc again to clear` (Claude Code
    // `useTextInput`). An empty prompt has nothing to clear. During a reply
    // Esc interrupts, which the watcher owns.
    if (state.inputPhase()) |p| if (key == .esc) {
        if (ix.editor.view.len == 0) return .{};
        if (p.press.press(.clear_input, now_ms)) return .{ .redraw_region = true, .action = .clear_draft };
        return .{ .redraw_region = true };
    };

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

/// The footer line while an exit press is armed (it replaces the whole line).
/// The presses belong to the input phase; no other phase has one armed.
pub fn exitHint(state: *const UiState) ?[]const u8 {
    const p = state.inputPhaseConst() orelse return null;
    return switch (p.press.kind) {
        .exit_ctrl_c => "Press Ctrl-C again to exit",
        .exit_ctrl_d => "Press Ctrl-D again to exit",
        .none, .clear_input => null,
    };
}

/// The one-line notice right-aligned above the input box: the Esc double
/// press outranks the yank hint.
pub fn aboveBoxNotice(state: *const UiState) ?[]const u8 {
    const p = state.inputPhaseConst() orelse return null;
    if (p.press.kind == .clear_input) return "Esc again to clear";
    if (p.copied) |notice| return switch (notice) {
        .system_clipboard => "Copied to clipboard",
        .terminal_clipboard => "Sent to the terminal's clipboard",
        .tmux_dropped => "tmux did not pass it on: set-clipboard on",
    };
    if (p.paste_hint) return "Ctrl+Y to paste deleted text";
    return null;
}

/// A suggestion menu the draft opens on its own: `/models`, `/model`, the `/`
/// command menu, or an `@` file mention under the cursor. Only an input
/// phase has a draft that opens them.
pub fn suggestionMenuOpen(state: *const UiState) bool {
    const p = state.inputPhaseConst() orelse return false;
    const view = p.interaction.editor.view;
    return complete.modelsMenuOpen(view) or complete.modelMenuOpen(view) or
        complete.slashMenuOpen(p.slash_catalog, view) or
        complete.atMenuActive(view, p.interaction.editor.cursor);
}

// ============================ render ============================

/// 纯投影:state → 帧字节写入 w。按 phase 渲染输入/生成帧。
/// transcript 现走 alt-screen viewer(transcript_viewer.zig),不再嵌入式渲染。
/// `?` help 非模态——在 renderInputFrame 内把 footer 区换成快捷键菜单(输入框仍在)。
pub fn render(w: anytype, in: RenderInputs) !Frame {
    return switch (in.state.phase) {
        .idle => .{}, // 两次交互之间固定区不在屏上
        .input => |*p| try renderInputFrame(w, in, p),
        .generating => |*p| try renderGenFrame(w, in, p),
    };
}

/// The `?` shortcut panel and the Shortcuts block of `/help`, phrased and laid
/// out like Claude Code's (`! for shell mode`, column-major, three columns
/// when the terminal is wide enough). Every entry names a key this REPL
/// actually binds.
pub const SHORTCUTS = [_][]const u8{
    "! for shell mode",
    "/ for commands",
    "@ for file paths",
    "/btw for side question",
    "double tap esc to clear input",
    "shift + tab to cycle modes",
    "ctrl + o to choose a model",
    "ctrl + t to toggle tasks",
    "\\ + return for newline",
    "ctrl + _ to undo",
    "ctrl + r to search history",
    "ctrl + g to edit in $EDITOR",
    "ctrl + x ctrl + o for transcript",
    "ctrl + b to run a reply in background",
};

const SHORTCUT_GAP: usize = 2;

/// Columns the grid uses at `cols`: as many of three as fit, at least one.
pub fn shortcutColumns(cols: usize) usize {
    var n: usize = 3;
    while (n > 1) : (n -= 1) {
        if (shortcutGridWidth(n) <= cols) return n;
    }
    return 1;
}

fn shortcutRowsFor(ncol: usize) usize {
    return (SHORTCUTS.len + ncol - 1) / ncol;
}

fn shortcutColumnWidth(ncol: usize, col: usize) usize {
    const rows = shortcutRowsFor(ncol);
    var widest: usize = 0;
    var r: usize = 0;
    while (r < rows) : (r += 1) {
        const i = col * rows + r;
        if (i < SHORTCUTS.len) widest = @max(widest, term.displayWidth(SHORTCUTS[i]));
    }
    return widest;
}

fn shortcutGridWidth(ncol: usize) usize {
    var total: usize = 2; // indent
    var c: usize = 0;
    while (c < ncol) : (c += 1) total += shortcutColumnWidth(ncol, c) + (if (c + 1 < ncol) SHORTCUT_GAP else 0);
    return total;
}

/// help_open 时画在 footer 区的快捷键菜单(**非模态**,输入框在上方仍可打字)。
/// 对齐 cc PromptInputHelpMenu:多列紧凑布局,占据 footer 行位置。返回写出的行数。
/// pub + 泛型 writer/theme/cols:render_region(真 tty 输入帧)复用同一份,避免第三处重复。
/// 注:行首不写 clear.line(调用方按需注入,如 render_region 自带 ansi.clear.line)。
pub fn renderHelpLines(w: anytype, th: Theme, cols: u16) !u16 {
    const ncol = shortcutColumns(cols);
    const rows = shortcutRowsFor(ncol);
    var r: usize = 0;
    while (r < rows) : (r += 1) {
        try w.writeAll(th.dim);
        try w.writeAll("  ");
        var c: usize = 0;
        while (c < ncol) : (c += 1) {
            const i = c * rows + r;
            const entry = if (i < SHORTCUTS.len) SHORTCUTS[i] else "";
            try w.writeAll(entry);
            // Pad to the column (the last column is not padded).
            if (c + 1 < ncol and (c + 1) * rows + r < SHORTCUTS.len) {
                var pad = shortcutColumnWidth(ncol, c) + SHORTCUT_GAP - term.displayWidth(entry);
                while (pad > 0) : (pad -= 1) try w.writeAll(" ");
            }
        }
        try w.writeAll(th.reset);
        try w.writeAll("\r\n");
    }
    return @intCast(rows);
}

/// 输入期帧(阶段 0 最简版:❯ + editor view + footer 行)。
/// 后续阶段接入完整边框/多行/panel。
fn renderInputFrame(w: anytype, in: RenderInputs, p: *const ui_state.InputPhase) !Frame {
    const th = in.theme;
    const s = in.state;
    const ed = p.interaction.editor;
    var rows: u16 = 0;
    // ❯ 行 + editor view。
    try w.writeAll(th.accent);
    try w.writeAll("❯ ");
    try w.writeAll(th.reset);
    try w.writeAll(ed.view);
    try w.writeAll("\r\n");
    rows += 1;
    // footer 区:help_open 时原地展开快捷键菜单(非模态,输入框仍在);否则正常 footer 行。
    if (p.interaction.help_open) {
        rows += try renderHelpLines(w, in.theme, s.cols);
    } else {
        rows += try renderFooterLine(w, in);
    }
    const cursor_col: u16 = @intCast(2 + term.displayWidth(ed.view[0..@min(ed.cursor, ed.view.len)]));
    return .{ .rows = rows, .cursor_row = 0, .cursor_col = cursor_col };
}

/// 生成期帧(阶段 0 占位:spinner 行 + footer;阶段 3 接入完整)。
fn renderGenFrame(w: anytype, in: RenderInputs, p: *const ui_state.GeneratingPhase) !Frame {
    const th = in.theme;
    var rows: u16 = 0;
    const elapsed = @divTrunc(@max(in.now_ms - p.spinner.start_ms, 0), 1000);
    const glyph: []const u8 = if (in.use_unicode) "*" else "*";
    try w.writeAll(th.accent);
    try w.print("{s} {s}… ({d}s · esc to interrupt)", .{ glyph, p.spinner.verb, elapsed });
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
    if (exitHint(s)) |text| {
        try w.print("{s} {s}{s}\r\n", .{ th.dim, text, th.reset });
        return 1;
    }
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

// ── tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn press(state: *UiState, k: input.Key) Effect {
    return dispatch(state, .{ .key = .{ .key = k } });
}

test "issue #16: Ctrl+O opens the picker and Ctrl+X Ctrl+O still opens the transcript" {
    var state = UiState.in(.{ .input = .{} });
    try testing.expectEqual(event.LoopAction.open_model_picker, press(&state, .ctrl_o).action);

    // The rebinding must not make transcript viewing unreachable: the prefix
    // form keeps the same letter and the same muscle memory.
    _ = press(&state, .ctrl_x);
    try testing.expectEqual(event.LoopAction.open_transcript, press(&state, .ctrl_o).action);

    // And the prefix's original binding is untouched.
    _ = press(&state, .ctrl_x);
    try testing.expectEqual(event.LoopAction.kill_background, press(&state, .ctrl_k).action);
}

test "issue #16: an open picker owns the keyboard without touching the draft" {
    var state = UiState.in(.{ .input = .{} });
    const ix = state.interaction().?;
    ix.editor = .{ .view = "explain this function", .cursor = 4 };
    ix.picker_open = true;

    const typed = press(&state, .{ .char = 'g' });
    try testing.expectEqual(event.LoopAction.picker_key, typed.action);
    try testing.expect(typed.picker_key == .char and typed.picker_key.char == 'g');
    // A plain character while the picker is open is its filter, not editor
    // input — and the draft the user was writing stays exactly as it was.
    try testing.expectEqualStrings("explain this function", ix.editor.view);
    try testing.expectEqual(@as(usize, 4), ix.editor.cursor);

    try testing.expect(press(&state, .enter).picker_key == .enter);
    try testing.expect(press(&state, .esc).picker_key == .escape);
    try testing.expect(press(&state, .up).picker_key == .up);
    try testing.expect(press(&state, .down).picker_key == .down);
    // Tab cannot be a filter character, which is what makes it usable for the
    // one explicit choice the picker needs.
    try testing.expect(press(&state, .tab).picker_key == .cycle_scope);
}

test "Ctrl+R in an open picker is the picker's: it fetches again a list that did not come (#572)" {
    var state = UiState.in(.{ .input = .{} });
    const ix = state.interaction().?;
    ix.editor = .{ .view = "explain this function", .cursor = 4 };
    try testing.expect(press(&state, .ctrl_r).action != .picker_key);
    ix.picker_open = true;
    const retried = press(&state, .ctrl_r);
    try testing.expectEqual(event.LoopAction.picker_key, retried.action);
    try testing.expect(retried.picker_key == .retry);
    try testing.expectEqualStrings("explain this function", ix.editor.view);
    try testing.expectEqual(@as(usize, 4), ix.editor.cursor);
}

test "issue #16: an open picker never traps the session" {
    var state = UiState.in(.{ .input = .{} });
    state.interaction().?.picker_open = true;
    // Ctrl+D, and Ctrl+C during a reply, keep their normal meaning, so there
    // is always a way out that does not depend on the picker's own state machine.
    try testing.expect(press(&state, .ctrl_d).action != .picker_key);
    var replying = UiState.in(.{ .generating = .{} });
    replying.interaction().?.picker_open = true;
    try testing.expect(press(&replying, .ctrl_c).action != .picker_key);
    try testing.expect(press(&replying, .ctrl_d).action != .picker_key);
}

test "Ctrl+C at the prompt closes an open picker and keeps the draft; the next Ctrl+C arms the exit (#607)" {
    var state = UiState.in(.{ .input = .{} });
    const ix = state.interaction().?;
    ix.editor = .{ .view = "explain this function", .cursor = 4 };
    ix.picker_open = true;

    const cancelled = press(&state, .ctrl_c);
    try testing.expectEqual(event.LoopAction.picker_key, cancelled.action);
    try testing.expect(cancelled.picker_key == .cancel);
    try testing.expectEqualStrings("explain this function", ix.editor.view);
    try testing.expectEqual(@as(usize, 4), ix.editor.cursor);
    try testing.expect(exitHint(&state) == null);

    ix.picker_open = false;
    try testing.expectEqual(event.LoopAction.discard_draft, press(&state, .ctrl_c).action);
    try testing.expectEqualStrings("Press Ctrl-C again to exit", exitHint(&state).?);
    try testing.expectEqual(event.LoopAction.exit_prompt, press(&state, .ctrl_c).action);
}

test "Ctrl+D over an open picker leaves a non-empty draft alone, at the prompt and during a reply (#649)" {
    var state = UiState.in(.{ .input = .{} });
    const ix = state.interaction().?;
    ix.editor = .{ .view = "explain this", .cursor = 8 };
    ix.picker_open = true;
    const prompt = press(&state, .ctrl_d);
    try testing.expectEqual(event.LoopAction.none, prompt.action);
    try testing.expect(exitHint(&state) == null);

    var replying = UiState.in(.{ .generating = .{} });
    const gen = replying.interaction().?;
    gen.editor = .{ .view = "queued draft", .cursor = 7 };
    gen.picker_open = true;
    try testing.expectEqual(event.LoopAction.none, press(&replying, .ctrl_d).action);
}

test "Ctrl+D over an open picker on an empty prompt still arms the double-press exit (#649)" {
    var state = UiState.in(.{ .input = .{} });
    state.interaction().?.picker_open = true;
    try testing.expectEqual(event.LoopAction.none, press(&state, .ctrl_d).action);
    try testing.expect(exitHint(&state) != null);
    try testing.expectEqual(event.LoopAction.exit_prompt, press(&state, .ctrl_d).action);
}

test "issue #16: `?` help lists both the picker and its replacement binding" {
    var found_picker = false;
    var found_transcript = false;
    for (SHORTCUTS) |entry| {
        if (std.mem.eql(u8, entry, "ctrl + o to choose a model")) found_picker = true;
        if (std.mem.eql(u8, entry, "ctrl + x ctrl + o for transcript")) found_transcript = true;
    }
    // A moved binding that is not documented is a binding users lose.
    try testing.expect(found_picker);
    try testing.expect(found_transcript);
}

test "shortcut grid: three columns when they fit, fewer on a narrow terminal" {
    try testing.expectEqual(@as(usize, 3), shortcutColumns(120));
    try testing.expectEqual(@as(usize, 2), shortcutColumns(80));
    try testing.expectEqual(@as(usize, 1), shortcutColumns(40));
    // Every row fits the width it was laid out for.
    for ([_]u16{ 40, 80, 120 }) |cols| {
        var buf: [4096]u8 = undefined;
        var w: std.Io.Writer = .fixed(&buf);
        const rows = try renderHelpLines(&w, @import("theme.zig").monochrome, cols);
        try testing.expectEqual(@as(u16, @intCast((SHORTCUTS.len + shortcutColumns(cols) - 1) / shortcutColumns(cols))), rows);
        var it = std.mem.splitSequence(u8, w.buffered(), "\r\n");
        while (it.next()) |line| try testing.expect(term.displayWidth(line) <= cols);
    }
}

test "the notice above the box after a copy says where the text went" {
    var state = UiState.in(.{ .input = .{} });
    const p = state.inputPhase().?;
    try testing.expect(aboveBoxNotice(&state) == null);
    p.copied = .system_clipboard;
    try testing.expectEqualStrings("Copied to clipboard", aboveBoxNotice(&state).?);
    p.copied = .terminal_clipboard;
    try testing.expectEqualStrings("Sent to the terminal's clipboard", aboveBoxNotice(&state).?);
    p.copied = .tmux_dropped;
    try testing.expectEqualStrings("tmux did not pass it on: set-clipboard on", aboveBoxNotice(&state).?);
}

test "Ctrl+Z asks to suspend the process at the prompt, during a reply and over an open picker" {
    var prompt = UiState.in(.{ .input = .{} });
    try testing.expectEqual(event.LoopAction.suspend_process, press(&prompt, .ctrl_z).action);
    prompt.interaction().?.picker_open = true;
    try testing.expectEqual(event.LoopAction.suspend_process, press(&prompt, .ctrl_z).action);
    var replying = UiState.in(.{ .generating = .{} });
    try testing.expectEqual(event.LoopAction.suspend_process, press(&replying, .ctrl_z).action);
}
