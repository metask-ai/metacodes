//! UiState —— cc-zig TUI 的集中 UI 逻辑状态(状态驱动架构核心)。
//!
//! 设计见 doc/TUI_STATE_ARCHITECTURE.md。硬边界:本文件**不 import std.c、不碰 fd、不持 mutex**
//! ——纯数据 + 纯逻辑,保证可在内存里被 dispatch/render 测试。
//!
//! UiState 只描述"应该长什么样"(逻辑状态);"上一帧物理痕迹"(prev_rows/region_drawn/光标行)
//! 属于 Renderer(render_region.zig),不在这里。

const std = @import("std");
const types = @import("../../types.zig");

/// 决策面:输入期 vs 生成期。
pub const Phase = enum { input, generating };

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
    viewing_id: [16]u8 = undefined,
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

/// 集中 UI 逻辑状态。机制态(prev_rows 等)不在此(属 Renderer)。
pub const UiState = struct {
    // 几何(resize 改)
    cols: u16 = 80,
    rows: u16 = 24,

    // 决策面
    phase: Phase = .input,
    /// `?` 快捷键帮助:**非模态**——footer 区原地展开多列快捷键,输入框仍在、可继续打字
    /// (对齐 cc helpOpen,见 PromptInputFooter.tsx)。transcript 走 alt-screen viewer,非 overlay。
    help_open: bool = false,

    // 编辑器投影
    editor: EditorState = .{},
    prompt: []const u8 = "> ",

    // 生成期
    spinner: SpinnerState = .{},
    tools: ToolsState = .{},

    // footer / 面板
    footer: FooterState = .{},
    panel: PanelState = .{},

    // Ctrl+X Ctrl+K 序列 arming(Emacs 风格双键前缀):Ctrl+X 后置 true,下个键消费。
    // 从 LineEditor 迁来 → dispatch 统一处理序列,两期一致(生成期也能 Ctrl+X-K 杀后台)。
    ctrl_x_armed: bool = false,

    // slash 菜单选中项(对齐 cc:`/` 菜单 ↑↓ 移高亮 + Enter 选中)。menu 开时 ↑↓ 改它而非历史导航。
    // 渲染按它高亮(accent 色);菜单关(非 `/` 态)恒重置为 0。范围由 complete.slashFilterCount 钳制。
    slash_sel: usize = 0,

    // Ctrl+U/K/W 杀行后显 `Ctrl+Y to paste deleted text` 提示(对齐 cc,框上方右对齐)。
    // 杀行键置 true,下次打字(char)清 false。
    paste_hint: bool = false,

    // 瞬时提示(对齐 CC:"再按 Ctrl+C 退出" / "agent finished" 等)
    hint: ?[]const u8 = null,

    // Agent switcher(区域2):footer 下方 agent 列表 + agent transcript 查看。
    agents: AgentSwitcherState = .{},
    /// agent 数量镜像(由 render/usage 时回写,dispatch 用于 ↓ 选择钳制)。
    /// dispatch 是纯函数无 registry 访问,靠此镜像知道选择上界。
    agent_count: usize = 0,

    /// issue #16: the cross-UI model picker is on screen. Modal for keys —
    /// while it is open every keystroke belongs to it, including plain
    /// characters, which are its filter. It is *not* modal for the session:
    /// the draft in the editor is untouched and a reply keeps streaming.
    picker_open: bool = false,
};

// ---- 状态操作 helper(纯逻辑,dispatch 调用)----

/// 设置当前工具(定长拷贝)。
pub fn setCurrentTool(s: *UiState, name: []const u8, start_ms: i64) void {
    const n = @min(name.len, s.tools.current.len);
    @memcpy(s.tools.current[0..n], name[0..n]);
    s.tools.current_len = @intCast(n);
    s.tools.current_start_ms = start_ms;
}

pub fn clearCurrentTool(s: *UiState) void {
    s.tools.current_len = 0;
}

/// 找卡片 index(按 id)。
pub fn findCard(s: *const UiState, id: []const u8) ?usize {
    var i: usize = 0;
    while (i < s.tools.cards_len) : (i += 1) {
        if (std.mem.eql(u8, s.tools.cards[i].idSlice(), id)) return i;
    }
    return null;
}

/// 追加进度卡(定长拷贝;满或重复 id 则忽略/更新)。
pub fn addCard(s: *UiState, id: []const u8, name: []const u8, input: []const u8, start_ms: i64) void {
    if (findCard(s, id) != null) return;
    if (s.tools.cards_len >= MAX_TOOL_CARDS) return;
    var c = &s.tools.cards[s.tools.cards_len];
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
    s.tools.cards_len += 1;
}

/// 更新卡片进度(定长拷贝)。
pub fn setCardProgress(s: *UiState, id: []const u8, text: []const u8) void {
    const idx = findCard(s, id) orelse return;
    var c = &s.tools.cards[idx];
    const n = @min(text.len, c.progress.len);
    @memcpy(c.progress[0..n], text[0..n]);
    c.progress_len = @intCast(n);
}

/// 移除卡片(按 id;后续前移保持紧凑)。
pub fn clearCard(s: *UiState, id: []const u8) void {
    const idx = findCard(s, id) orelse return;
    var i = idx;
    while (i + 1 < s.tools.cards_len) : (i += 1) {
        s.tools.cards[i] = s.tools.cards[i + 1];
    }
    s.tools.cards_len -= 1;
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
