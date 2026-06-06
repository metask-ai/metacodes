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

    // 瞬时提示(对齐 CC:"再按 Ctrl+C 退出" / "agent finished" 等)
    hint: ?[]const u8 = null,
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
