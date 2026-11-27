//! UiState —— cc-zig TUI 的集中 UI 逻辑状态(状态驱动架构核心)。
//!
//! 设计见 doc/TUI_STATE_ARCHITECTURE.md。硬边界:本文件**不 import std.c、不碰 fd、不持 mutex**
//! ——纯数据 + 纯逻辑,保证可在内存里被 dispatch/render 测试。
//!
//! UiState 只描述"应该长什么样"(逻辑状态);"上一帧物理痕迹"(prev_rows/region_drawn/光标行)
//! 属于 Renderer(render_region.zig),不在这里。

const std = @import("std");
const builtin = @import("builtin");
const complete = @import("../complete.zig");
const types = @import("metacodes-internal").types;

/// 回合阶段(#330:widget 生命周期的唯一驱动)。一个阶段实例 = 一次输入读取(`input`)
/// 或一次回复/等待(`generating`);两次之间是 `idle`(固定区不在屏上,没有任何 widget)。
/// 阶段只经 `.phase_change` 事件切换(`UiState.enter`),合法边只有 idle↔input、idle↔generating:
/// 每个交互阶段都先回到 idle 再开下一个,teardown 点就是这几次 enter。
pub const Phase = enum { idle, input, generating };

/// 编辑器投影:borrow LineEditor.buf.items(渲染瞬时有效)。LineEditor 本体不并入 UiState。
pub const EditorState = struct {
    view: []const u8 = "",
    cursor: usize = 0,
};

/// 生成期 spinner。elapsed = now_ms - start_ms(now 在 render 时注入,保证纯函数)。
pub const SpinnerState = struct {
    frame: u8 = 0,
    verb: []const u8 = "",
    start_ms: i64 = 0,
};

pub const MAX_TOOL_CARDS = 6;

/// per-toolUse 进度卡(并发 WebSearch 各一张)。定长拷贝——跨线程安全,无借用悬挂。
pub const ToolCardState = struct {
    id: [40]u8 = [_]u8{0} ** 40,
    id_len: u8 = 0,
    name: [32]u8 = [_]u8{0} ** 32,
    name_len: u8 = 0,
    progress: [192]u8 = [_]u8{0} ** 192,
    progress_len: u8 = 0,
    /// 工具入参 JSON(类A 动态卡每帧重画第二行 `$ cmd`/`📄 path` 预览需要;与 progress 正交:
    /// progress 是 WebSearch 运行时回调写入,input 是 tool_start 时一次性存)。
    input: [256]u8 = [_]u8{0} ** 256,
    input_len: u16 = 0,
    start_ms: i64 = 0,

    pub fn idSlice(self: *const ToolCardState) []const u8 {
        return self.id[0..self.id_len];
    }
    pub fn nameSlice(self: *const ToolCardState) []const u8 {
        return self.name[0..self.name_len];
    }
    pub fn progressSlice(self: *const ToolCardState) []const u8 {
        return self.progress[0..self.progress_len];
    }
    pub fn inputSlice(self: *const ToolCardState) []const u8 {
        return self.input[0..self.input_len];
    }
};

/// 当前工具 + 进度卡集合。
pub const ToolsState = struct {
    current: [48]u8 = [_]u8{0} ** 48,
    current_len: u8 = 0,
    current_start_ms: i64 = 0,
    cards: [MAX_TOOL_CARDS]ToolCardState = [_]ToolCardState{.{}} ** MAX_TOOL_CARDS,
    cards_len: u8 = 0,

    pub fn currentSlice(self: *const ToolsState) []const u8 {
        return self.current[0..self.current_len];
    }
};

/// footer 数据快照(收口跨线程裸读:usage/mode 经 .usage 事件进这里,footer 投影只读本字段)。
pub const FooterState = struct {
    mode: types.PermissionMode = .default,
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    cost_usd: f64 = 0,
    bg_count: usize = 0,
    cron_count: usize = 0,

    pub fn totalTokens(self: *const FooterState) u64 {
        return self.input_tokens + self.output_tokens;
    }
};

/// 输入框上方面板的 toggle 位(agent 树/task 列表数据量大,不进 UiState,render 经 RenderInputs 借用)。
pub const PanelState = struct {
    task_list_visible: bool = true,
};

/// Agent switcher(区域2,对齐 cc v2.1.168 footer 下方 agent 列表)。
/// 状态机:closed → list(↓/← 进)→ viewing(Enter)。selection_active 决定是否显 ❯ 光标。
pub const AgentView = enum { closed, list, viewing };
pub const AgentSwitcherState = struct {
    view: AgentView = .closed,
    /// 进 list 后是否已用 ↑/↓ 激活选择(显 ❯ 光标)。首次进 list 未选 → false(无光标)。
    selection_active: bool = false,
    /// 当前选中行:0 = "main",1..=N = agent index(对应 snapshotJobs 顺序)。
    sel: usize = 0,
    /// viewing 态正在查看的 agent id(idSlice 拷贝定长)。**Enter 提交时落定**,↑↓ 不动它
    /// (对齐真 cc:↑↓ 只移 ❯ 高亮,Enter 才切换被查看对象 → 分隔 label + ⏺ marker)。
    viewing_id: [16]u8 = [_]u8{0} ** 16,
    viewing_id_len: u8 = 0,
    /// viewing_id 是否已落定。dispatch(纯状态层,无 registry)进 viewing / 再 Enter 时置 false,
    /// 由 render(能访问 snapshot)在下一帧把 sel 对应 agent 的 id 拷进 viewing_id 并置 true。
    viewing_committed: bool = false,
    /// viewing 主区视口滚动位置(0=顶部行,top..top+view_rows)。PageUp/Dn 在 dispatch 饱和加减,
    /// render 层每帧用真实 max_top clamp 回写(dispatch 拿不到总行数/几何)。
    view_top: usize = 0,
    /// 切被查看对象(Enter 提交新 viewing_id)时置 true → render 层落定 view_top=max_top(定位底部/最新,
    /// 对齐 cc 打开 transcript 定位底部)。落定后置 false。
    view_top_at_bottom: bool = false,

    pub fn viewingIdSlice(self: *const AgentSwitcherState) []const u8 {
        return self.viewing_id[0..self.viewing_id_len];
    }
    /// render 层落定 viewing_id(从 snapshot 取 id)。id 长度截到 16。切被查看对象 → 视口复位到底部。
    pub fn commitViewingId(self: *AgentSwitcherState, id: []const u8) void {
        const n = @min(id.len, self.viewing_id.len);
        @memcpy(self.viewing_id[0..n], id[0..n]);
        self.viewing_id_len = @intCast(n);
        self.viewing_committed = true;
        self.view_top_at_bottom = true; // 切换被查看对象 → 视口定位底部(最新)
    }
    /// PageUp:视口上翻一页(饱和减,不越界 0)。render 层再 clamp。step=view_rows 由调用方传。
    pub fn viewPageUp(self: *AgentSwitcherState, step: usize) void {
        self.view_top = if (self.view_top > step) self.view_top - step else 0;
        self.view_top_at_bottom = false; // 手动滚动 → 不再自动钉底
    }
    /// PageDown:视口下翻一页(render 层 clamp 到 max_top)。
    pub fn viewPageDown(self: *AgentSwitcherState, step: usize) void {
        self.view_top +%= step;
        self.view_top_at_bottom = false;
    }
    /// 选择上移(钳制到 0)。首次只激活停当前 sel(对称 selectDown)。
    pub fn selectUp(self: *AgentSwitcherState) void {
        if (!self.selection_active) {
            self.selection_active = true;
            return;
        }
        if (self.sel > 0) self.sel -= 1;
    }
    /// 选择下移(钳制到 agent_count;sel 0=main,1..N=agent)。
    /// 首次激活(selection_active 从 false→true)只激活、停在当前 sel(对齐实拍:← 进入后
    /// 首个 ↓ 选中 main 显 ❯);已激活则真正下移。
    pub fn selectDown(self: *AgentSwitcherState, agent_count: usize) void {
        if (!self.selection_active) {
            self.selection_active = true;
            return;
        }
        if (self.sel < agent_count) self.sel += 1;
    }
    /// 关闭 switcher,回 main 视图。
    pub fn close(self: *AgentSwitcherState) void {
        self.view = .closed;
        self.selection_active = false;
        self.sel = 0;
        self.viewing_id_len = 0;
        self.viewing_committed = false;
        self.view_top = 0;
        self.view_top_at_bottom = false;
    }
};

/// Window inside which a second press confirms (Claude Code's `useDoublePress`,
/// 800 ms). The prompt's idle tick expires an armed press after it.
pub const DOUBLE_PRESS_MS: i64 = 800;

/// A key that acts only when pressed twice within `DOUBLE_PRESS_MS`: Ctrl+C and
/// Ctrl+D on the idle prompt exit, Esc clears the draft. The first press arms it
/// and shows its hint; the state is purely time-based, as in Claude Code, so
/// typing in between neither confirms nor cancels it.
pub const DoublePress = struct {
    pub const Kind = enum { none, exit_ctrl_c, exit_ctrl_d, clear_input };

    kind: Kind = .none,
    deadline_ms: i64 = 0,

    /// Record a press of `k` at `now_ms`. True when it confirms an armed press
    /// of the same kind; otherwise `k` becomes the armed press.
    pub fn press(self: *DoublePress, k: Kind, now_ms: i64) bool {
        if (self.kind == k and now_ms <= self.deadline_ms) {
            self.* = .{};
            return true;
        }
        self.* = .{ .kind = k, .deadline_ms = now_ms + DOUBLE_PRESS_MS };
        return false;
    }

    /// Drop an armed press whose window has passed. True when the hint it
    /// showed must disappear.
    pub fn expire(self: *DoublePress, now_ms: i64) bool {
        if (self.kind == .none or now_ms <= self.deadline_ms) return false;
        self.* = .{};
        return true;
    }
};

/// Esc closes the `/` and `@` suggestion menus without touching the draft
/// (Claude Code). The menus are derived from the draft, so the dismissal is
/// remembered against the draft it closed: any edit reopens them.
pub const MenuDismissal = struct {
    active: bool = false,
    len: usize = 0,
    hash: u64 = 0,

    pub fn dismiss(self: *MenuDismissal, view: []const u8) void {
        self.* = .{ .active = true, .len = view.len, .hash = std.hash.Wyhash.hash(0, view) };
    }

    pub fn covers(self: *const MenuDismissal, view: []const u8) bool {
        return self.active and self.len == view.len and self.hash == std.hash.Wyhash.hash(0, view);
    }
};

/// 每个交互阶段(input 与 generating)各自拥有一份、进入阶段时重建的交互状态。
/// 键盘分发两期共用这一份语义,所以它是两个阶段 payload 的公共部分,而不是会话状态。
pub const Interaction = struct {
    /// 编辑器投影:输入期借用 readLineRaw 的 LineEditor 缓冲;生成期借用 region 自有的副本
    /// `gen_editor`(草稿本体是这一轮 TuiBackend 的 `draft`,跨对话框重启 watcher 存活)。
    /// 阶段结束时那块缓冲随之释放或清空,所以投影只能活在阶段里。
    editor: EditorState = .{},
    /// `?` 快捷键帮助:**非模态**——footer 区原地展开多列快捷键,输入框仍在、可继续打字
    /// (对齐 cc helpOpen,见 PromptInputFooter.tsx)。transcript 走 alt-screen viewer,非 overlay。
    help_open: bool = false,
    /// Ctrl+X Ctrl+K / Ctrl+X Ctrl+O 序列 arming(Emacs 风格双键前缀):Ctrl+X 后置 true,下个键消费。
    ctrl_x_armed: bool = false,
    /// Agent switcher(区域2):footer 下方 agent 列表 + agent transcript 查看。
    agents: AgentSwitcherState = .{},
    /// issue #16: the cross-UI model picker is on screen. Modal for keys —
    /// while it is open every keystroke belongs to it, including plain
    /// characters, which are its filter. It is *not* modal for the session:
    /// the draft in the editor is untouched and a reply keeps streaming.
    /// Like every widget it dies with its phase; it reaches the next phase
    /// only through the explicit `app.pending_overlay` hand-off (#220).
    picker_open: bool = false,
};

/// 一次输入读取拥有的状态。
pub const InputPhase = struct {
    interaction: Interaction = .{},
    /// `/` 菜单的命令源(内建 + 可由用户调用的 skill)。借用 readLineRaw 本次读取的 arena,
    /// 由 `PhaseEntry.input` 带入——读取结束(回 idle)它随 payload 一起消失,不会悬挂。
    slash_catalog: complete.SlashCatalog = .builtin,
    /// slash 菜单选中项(对齐 cc:`/` 菜单 ↑↓ 移高亮 + Enter 选中)。menu 开时 ↑↓ 改它而非历史导航。
    /// 渲染按它高亮(accent 色);菜单关(非 `/` 态)恒重置为 0。范围由 complete.slashFilterCount 钳制。
    slash_sel: usize = 0,
    /// Ctrl+U/K/W 杀行后显 `Ctrl+Y to paste deleted text` 提示(对齐 cc,框上方右对齐)。
    /// 杀行键置 true,下次打字(char)清 false。
    paste_hint: bool = false,
    copied: bool = false,
    /// Idle-prompt double-press confirmation (Ctrl+C / Ctrl+D exit, Esc clear).
    press: DoublePress = .{},
    /// Suggestion menus closed with Esc for the current draft.
    menu_dismissal: MenuDismissal = .{},
};

pub const ThinkingLive = struct {
    pub const capacity = 2048;

    start_ms: i64,
    bytes: [capacity]u8 = undefined,
    len: u16 = 0,

    pub fn text(self: *const ThinkingLive) []const u8 {
        return self.bytes[0..self.len];
    }

    pub fn append(self: *ThinkingLive, more: []const u8) void {
        const take = more[more.len -| capacity..];
        const keep = @min(self.len, capacity - take.len);
        std.mem.copyForwards(u8, self.bytes[0..keep], self.bytes[self.len - keep .. self.len]);
        @memcpy(self.bytes[keep..][0..take.len], take);
        var len = keep + take.len;
        var cut: usize = 0;
        while (cut < len and self.bytes[cut] & 0xC0 == 0x80) cut += 1;
        if (cut > 0) {
            std.mem.copyForwards(u8, self.bytes[0 .. len - cut], self.bytes[cut..len]);
            len -= cut;
        }
        self.len = @intCast(len);
    }
};

/// 一次回复(或回复前的等待)拥有的状态。
pub const GeneratingPhase = struct {
    interaction: Interaction = .{},
    /// 由 `PhaseEntry.generating` 带入 verb/start_ms。
    spinner: SpinnerState = .{},
    tools: ToolsState = .{},
    thinking: ?ThinkingLive = null,
};

/// 阶段及其拥有的全部状态。payload 在 `enter` 时整体替换:旧阶段打开的东西没有任何
/// 一条路能活过边界,新加进 payload 的字段也不用登记到哪个 reset 列表里。
pub const PhaseState = union(Phase) {
    idle,
    input: InputPhase,
    generating: GeneratingPhase,
};

/// 进入阶段时边界上合法知道的参数——只有这些,没有旧阶段的任何东西。
pub const PhaseEntry = union(Phase) {
    idle,
    input: struct { slash_catalog: complete.SlashCatalog = .builtin },
    generating: struct { verb: []const u8 = "", start_ms: i64 = 0 },
};

/// 合法的阶段边:每个交互阶段都经 idle 结束。idle→idle 是幂等的收尾(leave 兜底)。
pub fn transitionAllowed(from: Phase, to: Phase) bool {
    return from == .idle or to == .idle;
}

/// 集中 UI 逻辑状态。机制态(prev_rows 等)不在此(属 Renderer)。
/// 顶层字段都是**会话**拥有的(跨阶段存活),各自在 `session_owned` 里写明原因;
/// 其余一切状态都在 `phase` 的 payload 里,归某个阶段拥有。
pub const UiState = struct {
    // 几何(resize 改)
    cols: u16 = 80,
    rows: u16 = 24,

    /// 当前阶段 + 它拥有的全部 widget 状态。只有 `enter` 写它。
    phase: PhaseState = .idle,

    // footer / 面板
    footer: FooterState = .{},
    panel: PanelState = .{},

    /// agent 数量镜像(由 render/usage 时回写,dispatch 用于 ↓ 选择钳制)。
    /// dispatch 是纯函数无 registry 访问,靠此镜像知道选择上界。
    agent_count: usize = 0,

    /// 每个顶层字段的拥有者声明。新加顶层字段而不在这里写明它为什么跨阶段存活 → 编译失败
    /// (见文件末 comptime 块):阶段内的状态应该放进阶段 payload。
    pub const session_owned = .{
        .cols = "terminal geometry",
        .rows = "terminal geometry",
        .phase = "the phase itself; everything it owns lives in its payload",
        .footer = "usage/mode snapshot, fed by .usage between and across phases",
        .panel = "Ctrl+T task-list preference, kept for the whole session",
        .agent_count = "mirror of the agent registry the renderer writes back",
    };

    /// 一个处于 `entry` 阶段的新状态(测试与只关心单个阶段的调用方用)。
    pub fn in(entry: PhaseEntry) UiState {
        var s: UiState = .{};
        s.enter(entry);
        return s;
    }

    /// 唯一的阶段写入点:旧阶段的 payload(它打开的每个 widget)被整体替换。
    /// Debug 构建拒绝不经 idle 的边——那意味着有一个阶段没有被关闭就开了下一个。
    pub fn enter(self: *UiState, entry: PhaseEntry) void {
        if (builtin.mode == .Debug and !transitionAllowed(self.phase, entry)) {
            std.debug.panic("UiState: phase {t} -> {t} skips idle; the old phase was never closed", .{ @as(Phase, self.phase), @as(Phase, entry) });
        }
        self.phase = switch (entry) {
            .idle => .idle,
            .input => |e| .{ .input = .{ .slash_catalog = e.slash_catalog } },
            .generating => |e| .{ .generating = .{ .spinner = .{ .verb = e.verb, .start_ms = e.start_ms } } },
        };
    }

    /// 当前交互阶段的交互状态;idle 时没有。
    pub fn interaction(self: *UiState) ?*Interaction {
        return switch (self.phase) {
            .idle => null,
            .input => |*p| &p.interaction,
            .generating => |*p| &p.interaction,
        };
    }

    pub fn interactionConst(self: *const UiState) ?*const Interaction {
        return switch (self.phase) {
            .idle => null,
            .input => |*p| &p.interaction,
            .generating => |*p| &p.interaction,
        };
    }

    pub fn inputPhase(self: *UiState) ?*InputPhase {
        return switch (self.phase) {
            .input => |*p| p,
            else => null,
        };
    }

    pub fn inputPhaseConst(self: *const UiState) ?*const InputPhase {
        return switch (self.phase) {
            .input => |*p| p,
            else => null,
        };
    }

    pub fn generatingPhase(self: *UiState) ?*GeneratingPhase {
        return switch (self.phase) {
            .generating => |*p| p,
            else => null,
        };
    }

    pub fn generatingPhaseConst(self: *const UiState) ?*const GeneratingPhase {
        return switch (self.phase) {
            .generating => |*p| p,
            else => null,
        };
    }
};

comptime {
    // 顶层字段 = 会话状态,必须声明拥有者;phase payload 的字段必须有默认值,
    // 进入阶段时才能整份重建(teardown 是全量的,不靠枚举字段)。
    for (@typeInfo(UiState).@"struct".fields) |f| {
        if (!@hasField(@TypeOf(UiState.session_owned), f.name)) @compileError("UiState." ++ f.name ++
            " has no declared owner: phase-scoped state belongs in a phase payload " ++
            "(Interaction/InputPhase/GeneratingPhase); session state must say why in UiState.session_owned");
    }
    for (@typeInfo(@TypeOf(UiState.session_owned)).@"struct".fields) |f| {
        if (!@hasField(UiState, f.name)) @compileError("UiState.session_owned names a missing field: " ++ f.name);
    }
    for ([_]type{ Interaction, InputPhase, GeneratingPhase }) |T| {
        for (@typeInfo(T).@"struct".fields) |f| {
            if (f.default_value_ptr == null) @compileError(@typeName(T) ++ "." ++ f.name ++
                " needs a default: entering a phase rebuilds its payload from defaults");
        }
    }
}

// ---- 状态操作 helper(纯逻辑,dispatch 调用)----

// 工具状态属于生成期;生成期以外到达的工具事件没有可更新的对象(它的阶段已经结束),丢弃即 teardown。

/// 设置当前工具(定长拷贝)。
pub fn setCurrentTool(s: *UiState, name: []const u8, start_ms: i64) void {
    const g = s.generatingPhase() orelse return;
    const n = @min(name.len, g.tools.current.len);
    @memcpy(g.tools.current[0..n], name[0..n]);
    g.tools.current_len = @intCast(n);
    g.tools.current_start_ms = start_ms;
}

pub fn clearCurrentTool(s: *UiState) void {
    const g = s.generatingPhase() orelse return;
    g.tools.current_len = 0;
}

/// 找卡片 index(按 id)。
pub fn findCard(s: *const UiState, id: []const u8) ?usize {
    const g = s.generatingPhaseConst() orelse return null;
    var i: usize = 0;
    while (i < g.tools.cards_len) : (i += 1) {
        if (std.mem.eql(u8, g.tools.cards[i].idSlice(), id)) return i;
    }
    return null;
}

/// 追加进度卡(定长拷贝;满或重复 id 则忽略/更新)。
pub fn addCard(s: *UiState, id: []const u8, name: []const u8, input: []const u8, start_ms: i64) void {
    if (findCard(s, id) != null) return;
    const g = s.generatingPhase() orelse return;
    if (g.tools.cards_len >= MAX_TOOL_CARDS) return;
    var c = &g.tools.cards[g.tools.cards_len];
    const idn = @min(id.len, c.id.len);
    @memcpy(c.id[0..idn], id[0..idn]);
    c.id_len = @intCast(idn);
    const nn = @min(name.len, c.name.len);
    @memcpy(c.name[0..nn], name[0..nn]);
    c.name_len = @intCast(nn);
    const inn = @min(input.len, c.input.len);
    @memcpy(c.input[0..inn], input[0..inn]);
    c.input_len = @intCast(inn);
    c.progress_len = 0;
    c.start_ms = start_ms;
    g.tools.cards_len += 1;
}

/// 更新卡片进度(定长拷贝)。
pub fn setCardProgress(s: *UiState, id: []const u8, text: []const u8) void {
    const idx = findCard(s, id) orelse return;
    var c = &s.phase.generating.tools.cards[idx];
    const n = @min(text.len, c.progress.len);
    @memcpy(c.progress[0..n], text[0..n]);
    c.progress_len = @intCast(n);
}

/// 移除卡片(按 id;后续前移保持紧凑)。
pub fn clearCard(s: *UiState, id: []const u8) void {
    const idx = findCard(s, id) orelse return;
    const tools = &s.phase.generating.tools;
    var i = idx;
    while (i + 1 < tools.cards_len) : (i += 1) {
        tools.cards[i] = tools.cards[i + 1];
    }
    tools.cards_len -= 1;
}

// ── 测试 ──────────────────────────────────────────────────────────────────────
const testing = std.testing;

test "AgentSwitcherState: viewPageUp/Down 改 view_top + 取消钉底" {
    var a: AgentSwitcherState = .{};
    a.view_top = 20;
    a.view_top_at_bottom = true;
    a.viewPageUp(10);
    try testing.expectEqual(@as(usize, 10), a.view_top);
    try testing.expect(!a.view_top_at_bottom); // 手动滚动 → 取消钉底
    a.viewPageUp(100); // 饱和到 0,不下溢
    try testing.expectEqual(@as(usize, 0), a.view_top);
    a.viewPageDown(5);
    try testing.expectEqual(@as(usize, 5), a.view_top); // render 层再 clamp 到 max_top
}

test "AgentSwitcherState: commitViewingId 落定 id + 视口钉底" {
    var a: AgentSwitcherState = .{};
    a.view_top = 99;
    a.commitViewingId("agent_abc");
    try testing.expectEqualStrings("agent_abc", a.viewingIdSlice());
    try testing.expect(a.viewing_committed);
    try testing.expect(a.view_top_at_bottom); // 切被查看对象 → 钉底(render 落定 max_top)
}

test "AgentSwitcherState: close 复位 view_top" {
    var a: AgentSwitcherState = .{};
    a.view = .viewing;
    a.view_top = 50;
    a.view_top_at_bottom = true;
    a.close();
    try testing.expectEqual(@as(usize, 0), a.view_top);
    try testing.expect(!a.view_top_at_bottom);
}

test "DoublePress: a second press inside the window confirms" {
    var p: DoublePress = .{};
    try testing.expect(!p.press(.exit_ctrl_c, 1000));
    try testing.expectEqual(DoublePress.Kind.exit_ctrl_c, p.kind);
    try testing.expect(p.press(.exit_ctrl_c, 1000 + DOUBLE_PRESS_MS));
    try testing.expectEqual(DoublePress.Kind.none, p.kind);
}

test "DoublePress: a late second press re-arms instead of confirming" {
    var p: DoublePress = .{};
    try testing.expect(!p.press(.clear_input, 0));
    try testing.expect(!p.press(.clear_input, DOUBLE_PRESS_MS + 1));
    try testing.expectEqual(DoublePress.Kind.clear_input, p.kind);
    try testing.expectEqual(2 * DOUBLE_PRESS_MS + 1, p.deadline_ms);
}

test "DoublePress: another key's press replaces, never confirms" {
    var p: DoublePress = .{};
    try testing.expect(!p.press(.clear_input, 0));
    try testing.expect(!p.press(.exit_ctrl_c, 10));
    try testing.expectEqual(DoublePress.Kind.exit_ctrl_c, p.kind);
    try testing.expect(!p.press(.clear_input, 20));
}

test "DoublePress: expire clears only after the deadline" {
    var p: DoublePress = .{};
    try testing.expect(!p.expire(5));
    _ = p.press(.exit_ctrl_d, 100);
    try testing.expect(!p.expire(100 + DOUBLE_PRESS_MS));
    try testing.expect(p.expire(101 + DOUBLE_PRESS_MS));
    try testing.expectEqual(DoublePress.Kind.none, p.kind);
    try testing.expect(!p.expire(10_000));
}

test "MenuDismissal: covers the dismissed draft and nothing else" {
    var d: MenuDismissal = .{};
    try testing.expect(!d.covers("/sk"));
    d.dismiss("/sk");
    try testing.expect(d.covers("/sk"));
    try testing.expect(!d.covers("/ski"));
    try testing.expect(!d.covers("/s"));
    try testing.expect(!d.covers("/ks"));
}
