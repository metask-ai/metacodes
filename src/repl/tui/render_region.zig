//! RenderRegion —— 底部锚定固定重绘区(复刻 Claude Code 观感,不进 alt-screen)。
//!
//! 见 doc/UI_LAYER_DESIGN.md。核心:屏幕底部维护固定高度的几行(StatusBar +
//! InputBox + 占位),只在变化时光标上移+逐行清+重画那几行,**绝不碰 scrollback**
//! (绝不用 \x1b[2J)。上方消息正常流入终端原生 scrollback。
//!
//! 阶段 1:
//! - 输入期:StatusBar(idle) + InputBox(单行) 两行区。
//! - 生成期:单行 spinner 形态(StatusBar generating),消息穿过协议简化为 1 行。
//! - 切换:enterGenerating / leaveGenerating。
//!
//! 关键约束(双锁陷阱):所有 fd=2 输出统一走 std.debug.print(间接拿 lockStdErr),
//! mutex 只管"擦/画"这组动作的逻辑原子性,不用裸 writeAll(2) 绕过。

const std = @import("std");
const app_mod = @import("../../app.zig");
const types = @import("../../types.zig");
const ansi = @import("ansi.zig");
const term = @import("term.zig");
const theme_mod = @import("theme.zig");
const verbs = @import("verbs.zig");
const StatusBar = @import("widget/status_bar.zig").StatusBar;
const util_time = @import("../../util/time.zig");
const complete = @import("../complete.zig");
const msg_queue = @import("../msg_queue.zig");
const agent_tree = @import("widget/agent_tree.zig");
const agent_job_registry = @import("../../core/agent_job_registry.zig");
const ui_mod = @import("ui.zig");
const event_mod = @import("event.zig");
const input = @import("../input.zig");
const ui_state_mod = @import("ui_state.zig");
const transcript_viewer = @import("../transcript_viewer.zig");
const Conversation = @import("../../core/conversation.zig").Conversation;

const Theme = theme_mod.Theme;
const ColorCapability = term.ColorCapability;

pub const RenderRegion = struct {
    fd: std.c.fd_t,
    cols: u16 = 80,
    rows: u16 = 24,
    prev_rows: u16 = 0, // 上一帧固定区总行数;0=未画。eraseRegion 用它擦旧区。
    input_cursor_row: u16 = 0, // 【仅输入期】上帧结束光标在区内第几行(从区顶 0 算)——输入期回顶支点。
    // 生成期:drawGenRegion 末尾把光标停在 editor 编辑点(供 IME),并记 cursor_in_region_row
    // (光标距区顶行数);writeGenText 擦区前先 UP(cursor_in_region_row)+\r 回区顶再 erase。
    cursor_in_region_row: u16 = 0,
    visible: bool = false,
    theme: Theme,
    color_cap: ColorCapability,
    use_unicode: bool,
    scratch: std.Io.Writer.Allocating,
    allocator: std.mem.Allocator, // queued buffer 用

    // 输入期状态(由 loop 在每次按键后更新 view/cursor 再调 render)
    input_view: []const u8 = "",
    input_cursor: usize = 0,
    prompt: []const u8 = "> ",

    // 生成期状态
    generating: bool = false,
    // spinner/verb/工具/进度卡的真相源 = self.ui(UiState);drawGenRegion 读它。
    // 旧的 spinner_frame/verb/gen_start_ms/current_tool*/tool_cards* 字段已删(单一真相源)。
    text_pending_newline: bool = false,
    pending_col: u16 = 0, // 半行 chunk 累计显示列(消息穿过续接用)
    region_drawn: bool = false, // 生成期固定区当前是否画在屏上(true ⟹ 光标钉区顶行首)
    // 画区时对续接点的快照:eraseRegion 必须按"画区那一刻"的半行状态还原,
    // 而非用 live 的 text_pending_newline/pending_col——后者会被 writeGenText.updatePendingTail
    // 在一对 draw/erase 之间改掉,导致 erase 选错分支 → 光标错位一行 → print 落到 scrollback。
    region_drawn_pending_nl: bool = false,
    region_drawn_pending_col: u16 = 0,
    // 生成期 app 指针(enterGenerating 存),供 writeGenText 在 print 后重画区(无需经 RegionWriter 传)。
    gen_app: ?*const app_mod.App = null,
    // 生成期输入框内容(watcher 线程的 LineEditor 视图,每次按键后由 watcher 经 setGenInput 更新)。
    gen_view: []const u8 = "",
    gen_cursor: usize = 0,
    // 生成期待发送队列指针(渲染预览用;watcher 入队后重画)。
    gen_queue: ?*msg_queue.MsgQueue = null,
    // 生成期行缓冲:LLM 文本逐 token 来,攒到遇 \n 才整行输出(避免逐字闪烁)。
    // 末尾残行在 leaveGenerating 时 flush。
    line_buf: std.ArrayList(u8) = .empty,

    // 助手文本(text_chunk)专用流式缓冲 + markdown 跨行状态。与 line_buf(裸 writeGenText,
    // 工具卡用)分开:助手文本要逐行过 markdown + 缩进 + 段首 ⏺,工具卡不能动。
    md_buf: std.ArrayList(u8) = .empty,
    md_state: @import("../render.zig").StreamState = .{},
    md_at_segment_start: bool = true, // 段首行用 ⏺ 前缀,续行用缩进

    // 阶段1:overlay 逻辑态(help/transcript)由 UiState 承载;机制态(prev_rows 等)仍在上面。
    ui: ui_state_mod.UiState = .{},
    // transcript overlay 期间持有的 owned lines(开 overlay 时生成,关时 freeLines)。
    transcript_lines: ?[][]u8 = null,

    mutex: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,

    fn lock(self: *RenderRegion) void {
        _ = std.c.pthread_mutex_lock(&self.mutex);
    }
    fn unlock(self: *RenderRegion) void {
        _ = std.c.pthread_mutex_unlock(&self.mutex);
    }

    /// 设置当前执行中的工具(普通工具,spinner 段 `⚒ <tool>`)。持锁。
    pub fn setCurrentTool(self: *RenderRegion, name: []const u8, start_ms: i64) void {
        self.lock();
        defer self.unlock();
        ui_state_mod.setCurrentTool(&self.ui, name, start_ms);
    }

    /// 清除当前工具(普通工具 spinner 段)。持锁。
    pub fn clearCurrentTool(self: *RenderRegion) void {
        self.lock();
        defer self.unlock();
        ui_state_mod.clearCurrentTool(&self.ui);
    }

    /// 新增一张 per-toolUse 进度卡(hasProgressCard 工具如 WebSearch 执行前调)。
    /// 按 id 去重;满则丢弃(MAX_TOOL_CARDS 够并发批)。持锁。
    pub fn addToolCard(self: *RenderRegion, id: []const u8, name: []const u8, start_ms: i64) void {
        self.lock();
        defer self.unlock();
        ui_state_mod.addCard(&self.ui, id, name, start_ms);
    }

    /// 移除一张 per-toolUse 卡(工具完成调)。持锁。数组紧凑(前移补位)。
    pub fn clearToolCard(self: *RenderRegion, id: []const u8) void {
        self.lock();
        defer self.unlock();
        ui_state_mod.clearCard(&self.ui, id);
    }

    /// 设置某张 per-toolUse 卡的进度第二行(对齐 cc onProgress→renderToolUseProgressMessage)。
    /// 工具执行线程经 progress 回调按 id 调用 → 写对应卡 + **立即重画一帧**(不等下个 tick,
    /// 否则 Found N 会被 Did N 秒覆盖渲不出)。持锁:与 spinner 线程读/画互斥。
    pub fn setToolProgress(self: *RenderRegion, id: []const u8, text: []const u8) void {
        self.lock();
        defer self.unlock();
        ui_state_mod.setCardProgress(&self.ui, id, text);
        // 立即重画(用 enterGenerating 存的 gen_app),让进度行至少渲染一帧。
        if (self.generating) {
            if (self.gen_app) |app| {
                if (self.region_drawn) self.eraseRegion();
                self.drawGenRegion(app);
            }
        }
    }

    pub fn init(allocator: std.mem.Allocator, fd: std.c.fd_t, theme: Theme, cap: ColorCapability) RenderRegion {
        const sz = term.getSize(fd) orelse term.TermSize{ .rows = 24, .cols = 80 };
        return .{
            .fd = fd,
            .cols = sz.cols,
            .rows = sz.rows,
            .theme = theme,
            .color_cap = cap,
            .use_unicode = cap != .none,
            .scratch = std.Io.Writer.Allocating.init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *RenderRegion) void {
        self.freeTranscriptLines();
        self.scratch.deinit();
        self.line_buf.deinit(self.allocator);
        self.md_buf.deinit(self.allocator);
    }

    fn freeTranscriptLines(self: *RenderRegion) void {
        if (self.transcript_lines) |ls| {
            transcript_viewer.freeLines(self.allocator, ls);
            self.transcript_lines = null;
        }
    }

    /// 设置输入态(loop 每次按键后调,再调 render)。
    pub fn setInput(self: *RenderRegion, view: []const u8, cursor: usize) void {
        self.input_view = view;
        self.input_cursor = cursor;
    }

    fn resetScratch(self: *RenderRegion) void {
        self.scratch.writer.end = 0;
    }

    /// 把 scratch 已写字节一次性输出(走 std.debug.print → lockStdErr)。
    fn flush(self: *RenderRegion) void {
        const bytes = self.scratch.written();
        if (bytes.len == 0) return;
        std.debug.print("{s}", .{bytes});
    }

    fn measureSize(self: *RenderRegion) void {
        if (term.getSize(self.fd)) |sz| {
            self.cols = sz.cols;
            self.rows = sz.rows;
        }
    }

    // =====================================================================
    // 输入期:cc 形态多行输入框(上边框 + ❯ 多行内容 + 下边框 + footer)
    // =====================================================================

    /// 重画固定区(输入期形态,复刻 Claude Code):
    ///   ╭──────────────────────────────╮   ← 上边框(round,mode 决定色)
    ///    ❯ 用户输入(可多行)                 ← 内容行,无左右竖线
    ///   ╰──────────────────────────────╯   ← 下边框
    ///    ? for shortcuts · shift+tab to cycle (mode)        N tokens   ← footer(dim)
    /// 不持锁版本(内部用);公开 render 持锁。输入期 wrapper。
    fn renderInner(self: *RenderRegion, app: *const app_mod.App) void {
        self.renderFrameInner(app, self.input_view, self.input_cursor);
    }

    /// 【仅输入期】重画输入框:上边框 + ❯content(多行)+ 下边框 + [slash 菜单] + footer。
    /// 输入期无 print(text) 滚动,故可安全用 input_cursor_row(光标实际所在区内行)回顶。
    /// 末尾把光标停在 content 供编辑,并记 input_cursor_row。
    /// TaskTab:输入框上方显示首个 in_progress 任务的 active_form(无则 subject)。
    /// 无 in_progress 任务 → 不画,返回 0 行。画一行返回 1。`◐ <text>`(截断到 cols)。
    /// 对齐 UI_LAYER_DESIGN 阶段 4。另:有运行中后台 subagent 时,即便无 todo 也画一行
    /// `◐ N subagents running`(用户曾反馈看不到并发 subagent 进度)。
    fn drawTaskTab(self: *RenderRegion, w: *std.Io.Writer, app: *const app_mod.App) u16 {
        return self.drawPanel(w, app);
    }

    /// 输入框上方的多行面板(对齐 cc):agent 进度树(上)+ Task 清单(下)。
    /// 返回画出的行数。无内容 → 0 行。height_budget 限制总行数,绝不挤掉输入框。
    fn drawPanel(self: *RenderRegion, w: *std.Io.Writer, app: *const app_mod.App) u16 {
        // 行预算:终端高度留给 spinner/队列/边框/输入/footer(~8 行)后剩余给面板。
        const reserved: u16 = 8;
        const budget: u16 = if (self.rows > reserved) @min(self.rows - reserved, 12) else 0;
        if (budget == 0) return 0;
        var used: u16 = 0;

        // ---- agent 进度树 ----
        // 用 App.agentJobsPtr()(指向 App 字段本身),不要 `if (app.agent_jobs) |reg|`
        // 捕获——那是值拷贝,listLock 会锁栈副本的 mutex 而非真 registry 的(race)。
        if (app.agentJobsPtr()) |reg| {
            const snaps = reg.snapshotJobs(self.allocator) catch null;
            if (snaps) |s| {
                defer agent_job_registry.AgentJobRegistry.freeSnapshots(self.allocator, s);
                if (s.len > 0) {
                    const tree = agent_tree.render(self.allocator, self.theme, s) catch null;
                    if (tree) |t| {
                        defer self.allocator.free(t);
                        used += self.writePanelLines(w, t, budget - used);
                    }
                }
            }
        }

        // ---- Task 清单 ----
        if (used < budget) {
            used += self.drawTaskList(w, app, budget - used);
        }
        return used;
    }

    /// 把多行文本(已含 ANSI)逐行写入区,每行前 clear.line + \r\n。最多 max_lines 行。
    fn writePanelLines(self: *RenderRegion, w: *std.Io.Writer, text: []const u8, max_lines: u16) u16 {
        _ = self;
        var n: u16 = 0;
        var pos: usize = 0;
        while (pos < text.len and n < max_lines) {
            const eol = std.mem.indexOfScalarPos(u8, text, pos, '\n') orelse text.len;
            w.writeAll(ansi.clear.line) catch {};
            w.writeAll(text[pos..eol]) catch {};
            w.writeAll("\r\n") catch {};
            n += 1;
            pos = eol + 1;
        }
        return n;
    }

    /// Task 清单(◼ in_progress / ◻ pending / ● completed,completed 过 TTL 不显)。
    /// 超预算折叠为 `… +N more`。返回行数。
    fn drawTaskList(self: *RenderRegion, w: *std.Io.Writer, app: *const app_mod.App, max_lines: u16) u16 {
        if (max_lines == 0) return 0;
        if (!self.ui.panel.task_list_visible) return 0; // Ctrl+T 隐藏:不画 task 清单
        const tasks = app.tasks.tasks.items;
        const now = util_time.nowMs();
        const TTL_MS: i64 = 30_000;

        // 先数可显条目(active + TTL 内 completed)。
        var visible: usize = 0;
        for (tasks) |t| {
            if (t.status == .completed) {
                if (t.completed_ms != 0 and now - t.completed_ms <= TTL_MS) visible += 1;
            } else if (t.status == .pending or t.status == .in_progress) {
                visible += 1;
            }
        }
        if (visible == 0) return 0;

        // 行预算分配:可全显则全显(无省略号);否则留 1 行给省略号显 max_lines-1 条。
        // 边界:max_lines==1 且溢出 → 不留省略号行,直接显 1 条真任务(省略号吃掉唯一一行
        // 却 0 任务是信息量为零的退化,不可取)。
        const overflow = visible > max_lines;
        const cap: usize = if (!overflow) visible else if (max_lines >= 2) max_lines - 1 else 1;

        var n: u16 = 0;
        var shown: usize = 0;
        const max_w: usize = if (self.cols > 6) self.cols - 6 else 8;
        for (tasks) |t| {
            const show = switch (t.status) {
                .completed => t.completed_ms != 0 and now - t.completed_ms <= TTL_MS,
                .pending, .in_progress => true,
                .deleted => false,
            };
            if (!show) continue;
            if (shown >= cap) break;
            const icon: []const u8 = switch (t.status) {
                .in_progress => if (self.use_unicode) "◼" else "[*]",
                .pending => if (self.use_unicode) "◻" else "[ ]",
                .completed => if (self.use_unicode) "●" else "[x]",
                .deleted => "",
            };
            const color: []const u8 = switch (t.status) {
                .in_progress => self.theme.warn,
                .pending => self.theme.dim,
                .completed => self.theme.success,
                .deleted => self.theme.dim,
            };
            const label = t.active_form orelse t.subject;
            const end = truncateToWidth(label, max_w);
            w.writeAll(ansi.clear.line) catch {};
            w.print("  {s}{s}{s} {s}", .{ color, icon, self.theme.reset, label[0..end] }) catch {};
            if (end < label.len) w.writeAll("…") catch {};
            w.writeAll("\r\n") catch {};
            n += 1;
            shown += 1;
        }
        // 折叠提示:仅当还有预算行(n < max_lines)且确有未显条目时才画,
        // 否则会超预算(max_lines==1 时已显 1 条真任务,不再挤省略号行)。
        if (visible > shown and n < max_lines) {
            w.writeAll(ansi.clear.line) catch {};
            w.print("  {s}… +{d} more{s}", .{ self.theme.dim, visible - shown, self.theme.reset }) catch {};
            w.writeAll("\r\n") catch {};
            n += 1;
        }
        return n;
    }

    fn renderFrameInner(self: *RenderRegion, app: *const app_mod.App, content: []const u8, cursor: usize) void {
        self.measureSize();
        const w = &self.scratch.writer;
        self.resetScratch();
        var nbuf: [16]u8 = undefined;

        // 1. hide + 回区顶 + 行首
        w.writeAll(ansi.cursor.hide) catch {};
        if (self.input_cursor_row > 0) w.writeAll(ansi.cursor.up(self.input_cursor_row, &nbuf)) catch {};
        w.writeAll(ansi.cursor.column(1, &nbuf)) catch {};

        const inner_w: usize = if (self.cols > 4) self.cols - 1 else 40;
        const border_color = self.borderColor(app.config.permission_mode);

        var vlines = VisualLines.init();
        layoutInput(content, &vlines, inner_w);

        var new_rows: u16 = 0;

        // -- TaskTab(可选,输入框上方 1 行)--
        const task_tab_rows = self.drawTaskTab(w, app);
        new_rows += task_tab_rows;

        // -- 上边框 --
        w.writeAll(ansi.clear.line) catch {};
        self.drawBorderLine(w, border_color, true, inner_w);
        new_rows += 1;
        w.writeAll("\r\n") catch {};

        // -- 内容行(至少 1 行)--
        const content_rows = if (vlines.count == 0) 1 else vlines.count;
        var li: usize = 0;
        while (li < content_rows) : (li += 1) {
            w.writeAll(ansi.clear.line) catch {};
            if (li == 0) {
                w.print("{s}{s} {s}", .{ self.theme.accent, PROMPT_POINTER, self.theme.reset }) catch {};
            } else {
                w.writeAll("  ") catch {};
            }
            if (li < vlines.count) {
                const seg = vlines.slices[li];
                w.writeAll(content[seg.start..seg.end]) catch {};
            }
            new_rows += 1;
            w.writeAll("\r\n") catch {};
        }

        // -- 下边框 --
        w.writeAll(ansi.clear.line) catch {};
        self.drawBorderLine(w, border_color, false, inner_w);
        new_rows += 1;
        w.writeAll("\r\n") catch {};

        // -- slash 命令菜单(`/` 前缀,在下边框与 footer 之间垂直列出)--
        new_rows += self.drawSlashMenu(w, content);

        // -- footer 区:help_open 时原地展开快捷键菜单(非模态,对齐 cc);否则正常 footer 行 --
        if (self.ui.help_open) {
            // renderHelpLines 每行末尾 \r\n;行首 clear.line 由下方 RegionLineWriter 注入。
            var hlw = RegionLineWriter{ .inner = w };
            const hrows = ui_mod.renderHelpLines(&hlw, self.theme, self.cols) catch 0;
            new_rows += hrows;
            // renderHelpLines 末行也带 \r\n → 光标停在末行下一行行首,比 footer 分支多下移 1 行。
            // 补 up(1) 把光标拉回区内最后一行,与 footer 分支"光标停在区内最后一行"约定一致——
            // 否则下方 footer_row/input_cursor_row 全部偏移 1,下一帧回区顶少 1 行 → 顶边框残留。
            if (hrows > 0) w.writeAll(ansi.cursor.up(1, &nbuf)) catch {};
        } else {
            w.writeAll(ansi.clear.line) catch {};
            self.drawFooter(w, app);
            new_rows += 1;
        }

        // 此刻光标在 footer 行末 = 区内最后一行(行号 new_rows-1)。

        // 3. 收缩残留擦除
        if (new_rows < self.prev_rows) {
            const diff = self.prev_rows - new_rows;
            var k: u16 = 0;
            while (k < diff) : (k += 1) {
                w.writeAll("\r\n") catch {};
                w.writeAll(ansi.clear.line) catch {};
            }
            w.writeAll(ansi.cursor.up(diff, &nbuf)) catch {};
        }

        // 4. 光标移到内容行(区内行号:TaskTab(0/1) + 上边框(1) + loc.vline)。
        const loc = RenderRegion.locateCursor(content, cursor, &vlines);
        const target_row: u16 = task_tab_rows + 1 + @as(u16, @intCast(loc.vline));
        const footer_row: u16 = new_rows - 1;
        if (footer_row > target_row) {
            w.writeAll(ansi.cursor.up(footer_row - target_row, &nbuf)) catch {};
        }
        w.writeAll(ansi.cursor.column(1, &nbuf)) catch {};
        const prefix_w: u32 = 2;
        w.writeAll(ansi.cursor.forward(prefix_w + @as(u32, @intCast(loc.vcol)), &nbuf)) catch {};

        // 5. show + 记不变式
        w.writeAll(ansi.cursor.show) catch {};

        self.prev_rows = new_rows;
        self.input_cursor_row = target_row;
        self.visible = true;
        self.flush();
    }

    /// 边框色:plan→warn(黄),bash(留待)→danger,其它→accent。
    fn borderColor(self: *RenderRegion, mode: types.PermissionMode) []const u8 {
        // cc 输入框边框色恒为 promptBorder,不随 permission mode 变(仅 bash 模式例外,cc-zig 暂无)。
        // mode 的视觉区分全交给 footer 的 mode part(drawFooter + status_bar.modeColor)。
        _ = mode;
        return self.theme.accent;
    }

    /// 画一条横边框线(top=true 用 ╭─╮,否则 ╰─╯)。无左右竖线之外的填充。
    fn drawBorderLine(self: *RenderRegion, w: *std.Io.Writer, color: []const u8, top: bool, inner_w: usize) void {
        const th = self.theme;
        const left = if (top) th.box_tl else th.box_bl;
        const right = if (top) th.box_tr else th.box_br;
        w.writeAll(color) catch {};
        w.writeAll(left) catch {};
        var i: usize = 0;
        // 中间填充 box_h,留出 left+right 两端(各占 1 显示列)
        const fill = if (inner_w >= 2) inner_w - 2 else 0;
        while (i < fill) : (i += 1) w.writeAll(th.box_h) catch {};
        w.writeAll(right) catch {};
        w.writeAll(th.reset) catch {};
    }

    /// 画 slash 命令菜单(`/` 前缀且无空格时)。每行 ` /cmd   描述`,匹配项列出。
    /// 返回新增行数(每行末尾 \r\n,光标停下一行行首供 footer 续画)。调用前光标停下边框下一行行首。
    fn drawSlashMenu(self: *RenderRegion, w: *std.Io.Writer, content: []const u8) u16 {
        const trimmed = std.mem.trimStart(u8, content, " \t");
        if (!std.mem.startsWith(u8, trimmed, "/")) return 0;
        if (std.mem.indexOfScalar(u8, trimmed, ' ') != null) return 0; // 已带参数 → 不弹菜单

        const th = self.theme;
        var rows: u16 = 0;
        const MAX_ROWS: u16 = 10; // 菜单最多列 10 项,防撑爆终端
        for (complete.SLASH_COMMAND_TABLE) |cmd| {
            if (!std.mem.startsWith(u8, cmd.name, trimmed)) continue;
            if (rows >= MAX_ROWS) break;
            w.writeAll(ansi.clear.line) catch {};
            w.print("  {s}{s}{s}", .{ th.accent, cmd.name, th.reset }) catch {};
            const pad = if (cmd.name.len < 14) 14 - cmd.name.len else 1;
            var p: usize = 0;
            while (p < pad) : (p += 1) w.writeAll(" ") catch {};
            w.print("{s}{s}{s}", .{ th.dim, cmd.desc, th.reset }) catch {};
            w.writeAll("\r\n") catch {};
            rows += 1;
        }
        return rows;
    }

    /// footer:左 "[{symbol} {title} on · ]shift+tab to cycle · ? for shortcuts"(对齐 CC)
    /// 右 "{tok} tokens"。mode part 用 modeColor 单独着色(plan→cyan/acceptEdits→magenta/
    /// bypass·dontAsk→red/auto→yellow);default 不显 mode part(对齐 cc isDefaultMode)。
    /// 其余文字 dim。
    fn drawFooter(self: *RenderRegion, w: *std.Io.Writer, app: *const app_mod.App) void {
        const th = self.theme;
        const sb = @import("widget/status_bar.zig");
        // mode 真相源 = app.permission_ctx.mode(live):输入期与 config 同步,生成期工具
        // (EnterPlanMode/ExitPlanMode)直接写它 → spinner tick 重画即反映(修 #11 生成期不联动)。
        // self.ui.footer.mode 仅当 ctx 为 default 但 footer 被 .usage 喂过非默认值时兜底(罕见)。
        const live = app.permission_ctx.mode;
        const mode_pm = if (live != .default) live else self.ui.footer.mode;
        const sym = sb.modeSymbol(mode_pm);
        const title = sb.modeTitle(mode_pm);
        const show_mode = title.len != 0; // default/prompt → 不显 mode part

        // mode part 纯文本(用于宽度计算,不含 SGR)。cc 格式:非 default → `{sym} {title} on (shift+tab to cycle)`;
        // default → 无 mode part(下方 hint 显 `? for shortcuts`)。对齐 cc 真实 footer。
        var mode_buf: [96]u8 = undefined;
        const mode_plain = if (show_mode)
            (std.fmt.bufPrint(&mode_buf, " {s} {s} on (shift+tab to cycle)", .{ sym, title }) catch "")
        else
            "";
        // default 态显 `? for shortcuts`;非 default 已在 mode part 含 cycle 提示,hint 留空。
        const hint = if (show_mode) "" else " ? for shortcuts";

        const total = blk: {
            const ft = self.ui.footer.totalTokens();
            if (ft > 0) break :blk ft;
            const u = app.usage;
            break :blk u.input_tokens + u.output_tokens;
        };
        var tok_buf: [16]u8 = undefined;
        const tok_str = sb.formatTokens(&tok_buf, total);
        var right_buf: [48]u8 = undefined;
        const right = std.fmt.bufPrint(&right_buf, "{s} tokens ", .{tok_str}) catch "";

        // 宽度按纯文本算(displayWidth 不跳 SGR,故 SGR 不能进被测字符串)。
        const left_w = displayWidth(mode_plain) + displayWidth(hint);
        const right_w = displayWidth(right);

        // 写:mode part 用 modeColor 着色,其余 dim。
        if (show_mode) {
            w.writeAll(sb.modeColor(th, mode_pm)) catch {};
            w.writeAll(mode_plain) catch {};
            w.writeAll(th.reset) catch {};
        }
        w.writeAll(th.dim) catch {};
        w.writeAll(hint) catch {};
        // 两端对齐:中间填空格
        if (self.cols > left_w + right_w) {
            const gap = self.cols - left_w - right_w;
            var i: usize = 0;
            while (i < gap) : (i += 1) w.writeAll(" ") catch {};
            w.writeAll(right) catch {};
        }
        w.writeAll(th.reset) catch {};
    }

    /// 把 view 切成 visual lines(逻辑行按 \n,再按 inner_w 软折行)。纯函数(不读 self 字段)。
    fn layoutInput(view: []const u8, out: *VisualLines, inner_w: usize) void {
        const avail: usize = if (inner_w > 3) inner_w - 3 else 1; // 减去 "❯ " 前缀宽 + 余量
        var line_start: usize = 0;
        var col: usize = 0;
        var i: usize = 0;
        while (i < view.len) {
            if (view[i] == '\n') {
                out.push(line_start, i);
                i += 1;
                line_start = i;
                col = 0;
                continue;
            }
            const nb = nextCharBytes(view, i);
            const cw = displayWidth(view[i .. i + nb]);
            if (col + cw > avail and i > line_start) {
                out.push(line_start, i);
                line_start = i;
                col = 0;
            }
            col += cw;
            i += nb;
        }
        out.push(line_start, view.len);
    }

    const CursorLoc = struct { vline: usize, vcol: usize };

    /// 算光标(byte offset)落在第几 visual line、该行第几显示列。纯函数。
    fn locateCursor(view: []const u8, cursor: usize, vlines: *const VisualLines) CursorLoc {
        const cur = cursor;
        var vi: usize = 0;
        while (vi < vlines.count) : (vi += 1) {
            const seg = vlines.slices[vi];
            // 光标在本段内(含段末;最后一段含 view.len)
            const seg_end_incl = if (vi == vlines.count - 1) seg.end + 1 else seg.end;
            if (cur >= seg.start and cur < seg_end_incl) {
                const vcol = displayWidth(view[seg.start..@min(cur, seg.end)]);
                return .{ .vline = vi, .vcol = vcol };
            }
        }
        return .{ .vline = 0, .vcol = 0 };
    }

    /// 公开重画(持锁)。输入期调用。
    pub fn render(self: *RenderRegion, app: *const app_mod.App) void {
        self.lock();
        defer self.unlock();
        if (self.generating) return; // 生成期不画多行区
        if (self.ui.overlay != .none) {
            self.renderOverlayInner(app);
        } else {
            self.renderInner(app);
        }
    }

    /// 阶段1:输入期按键先经 dispatch(锁内改 UiState + 据 Effect 重画)。
    /// 调用方(readLineRaw)在调用前应同步 self.ui.editor(供 dispatch 判断"空 buffer + ?")。
    /// conv 供 transcript overlay 生成 lines。返回 Effect.action 供主循环决定是否喂 LineEditor。
    pub fn applyEvent(
        self: *RenderRegion,
        app: *const app_mod.App,
        conv: *const Conversation,
        ev: event_mod.Event,
    ) event_mod.Effect {
        self.lock();
        defer self.unlock();
        const was = self.ui.overlay;
        const eff = ui_mod.dispatch(&self.ui, ev);
        const now = self.ui.overlay;
        // transcript overlay 跳变:进入时生成 lines(借 conv),退出时释放。
        if (now == .transcript and was != .transcript) {
            self.freeTranscriptLines();
            self.transcript_lines = transcript_viewer.renderToLinesWithTheme(self.allocator, conv, self.theme) catch null;
        } else if (now != .transcript and was == .transcript) {
            self.freeTranscriptLines();
            // transcript 退出再锚定:transcript 可能比输入框高、顶动了终端,直接 renderInner
            // 会让输入框停在 transcript 旧区顶(漂到屏上方,下方留空)。修:擦掉 transcript 区
            // → 用绝对定位把光标移到屏底输入框应在的行 → renderInner 从那里画 → 输入框落回底部。
            self.reanchorBottomAfterOverlay();
        }
        if (eff.redraw_region and !self.generating) {
            if (self.ui.overlay != .none) {
                self.renderOverlayInner(app);
            } else {
                self.renderInner(app);
            }
        }
        return eff;
    }

    /// 生成期按键分流(对应输入期 applyEvent,持锁)。watcher 线程调:同步 editor 投影 →
    /// dispatch(复用输入期同一份 `?`/help/Ctrl+O/transcript 滚动语义)→ 处理 overlay 快照
    /// 跳变 → 重画走 drawGenRegion(非 renderInner)。返回 Effect 供 watcher 决定是否喂 LineEditor。
    /// conv 供 transcript overlay 生成 lines(renderToLinesWithTheme 内部持 snapshot 锁防 append UAF)。
    pub fn applyGenKey(
        self: *RenderRegion,
        app: *const app_mod.App,
        conv: *const Conversation,
        key: input.Key,
        ed_view: []const u8,
        ed_cursor: usize,
    ) event_mod.Effect {
        self.lock();
        defer self.unlock();
        if (!self.generating) return .{};
        // dispatch 判"空 buffer + ?"依赖 editor 投影,调前同步 watcher 的 LineEditor 视图。
        self.ui.editor = .{ .view = ed_view, .cursor = ed_cursor };
        const was = self.ui.overlay;
        const eff = ui_mod.dispatch(&self.ui, .{ .key = .{ .key = key } });
        const now = self.ui.overlay;
        // transcript overlay 跳变:进入生成快照(借 conv),退出释放。生成期**不** reanchor
        // (输入期才需,生成区靠 prev_rows 收缩擦除维持锚位)。
        if (now == .transcript and was != .transcript) {
            self.freeTranscriptLines();
            self.transcript_lines = transcript_viewer.renderToLinesWithTheme(self.allocator, conv, self.theme) catch null;
        } else if (now != .transcript and was == .transcript) {
            self.freeTranscriptLines();
        }
        if (eff.redraw_region and self.generating) {
            if (self.region_drawn) self.eraseRegion();
            self.drawGenRegion(app);
        }
        return eff;
    }

    /// 否则收缩时新帧短行会留旧帧残字。薄 writer 适配 ui.render 的 anytype 接口。
    const RegionLineWriter = struct {
        inner: *std.Io.Writer,
        at_line_start: bool = true,
        pub fn writeAll(self: *RegionLineWriter, bytes: []const u8) !void {
            if (self.at_line_start and bytes.len > 0) {
                try self.inner.writeAll(ansi.clear.line);
                self.at_line_start = false;
            }
            try self.inner.writeAll(bytes);
            if (bytes.len > 0 and bytes[bytes.len - 1] == '\n') self.at_line_start = true;
        }
        pub fn print(self: *RegionLineWriter, comptime fmt: []const u8, args: anytype) !void {
            var buf: [4096]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, fmt, args) catch buf[0..];
            try self.writeAll(s);
        }
    };

    /// overlay 帧渲染:复用 renderFrameInner 的 erase/prev_rows 骨架,中段换成 ui.render 输出。
    /// 与正常输入框共用 prev_rows/input_cursor_row 不变式 → 切换时自动收缩擦除。
    fn renderOverlayInner(self: *RenderRegion, app: *const app_mod.App) void {
        _ = app;
        self.measureSize();
        const w = &self.scratch.writer;
        self.resetScratch();
        var nbuf: [16]u8 = undefined;

        // 1. hide + 回区顶 + 行首(同 renderFrameInner)。
        w.writeAll(ansi.cursor.hide) catch {};
        if (self.input_cursor_row > 0) w.writeAll(ansi.cursor.up(self.input_cursor_row, &nbuf)) catch {};
        w.writeAll(ansi.cursor.column(1, &nbuf)) catch {};

        // 2. 几何注入 UiState(renderTranscript 用 state.rows 算窗口)。
        self.ui.cols = self.cols;
        self.ui.rows = self.rows;

        // 3. ui.render 写中段(经 RegionLineWriter 注入 clear.line)。
        var lw = RegionLineWriter{ .inner = w };
        const frame = ui_mod.render(&lw, .{
            .state = &self.ui,
            .now_ms = util_time.nowMs(),
            .theme = self.theme,
            .use_unicode = self.use_unicode,
            .transcript_lines = if (self.transcript_lines) |ls| ls else &.{},
        }) catch ui_mod.Frame{};
        const new_rows: u16 = frame.rows;

        // ui.render 末行带 \r\n → 光标在区下方。先 up(1) 回到区最后一行,对齐
        // renderFrameInner 的"光标停在最后一行"约定,使下方收缩擦除/回顶逻辑一致。
        if (new_rows > 0) w.writeAll(ansi.cursor.up(1, &nbuf)) catch {};

        // 4. 收缩残留擦除(同 renderFrameInner:443-451)。
        if (new_rows < self.prev_rows) {
            const diff = self.prev_rows - new_rows;
            var k: u16 = 0;
            while (k < diff) : (k += 1) {
                w.writeAll("\r\n") catch {};
                w.writeAll(ansi.clear.line) catch {};
            }
            w.writeAll(ansi.cursor.up(diff, &nbuf)) catch {};
        }

        // 5. overlay 无编辑光标:回区顶(下一帧 renderFrameInner 从 input_cursor_row=0 起)。
        if (new_rows > 1) w.writeAll(ansi.cursor.up(new_rows - 1, &nbuf)) catch {};
        w.writeAll(ansi.cursor.column(1, &nbuf)) catch {};
        w.writeAll(ansi.cursor.show) catch {};

        self.prev_rows = new_rows;
        self.input_cursor_row = 0;
        self.visible = true;
        self.flush();
    }

    /// 擦掉固定区,光标回区顶第一行行首,prev_rows=0。
    /// 供"消息穿过协议"的 beginMessage 及退出清理用。
    pub fn clear(self: *RenderRegion) void {
        self.lock();
        defer self.unlock();
        self.clearInner();
    }

    fn clearInner(self: *RenderRegion) void {
        if (self.prev_rows == 0 and !self.visible) return;
        const w = &self.scratch.writer;
        self.resetScratch();
        var nbuf: [16]u8 = undefined;

        w.writeAll(ansi.cursor.hide) catch {};
        // 回区顶:光标当前在区内第 input_cursor_row 行(不一定最后一行)。
        if (self.input_cursor_row > 0) {
            w.writeAll(ansi.cursor.up(self.input_cursor_row, &nbuf)) catch {};
        }
        w.writeAll(ansi.cursor.column(1, &nbuf)) catch {};
        // 逐行清掉整个区(向下走 prev_rows 行)。
        var i: u16 = 0;
        while (i < self.prev_rows) : (i += 1) {
            w.writeAll(ansi.clear.line) catch {};
            if (i < self.prev_rows - 1) w.writeAll("\r\n") catch {};
        }
        // 抬回区顶第一行行首——后续消息从这里打(消息往上长,区往下退)。
        if (self.prev_rows > 1) {
            w.writeAll(ansi.cursor.up(self.prev_rows - 1, &nbuf)) catch {};
        }
        w.writeAll(ansi.cursor.column(1, &nbuf)) catch {};
        w.writeAll(ansi.cursor.show) catch {};

        self.prev_rows = 0;
        self.input_cursor_row = 0;
        self.visible = false;
        self.flush();
    }

    /// transcript 退出后把输入框重锚到屏底:先擦 transcript 区(clearInner),再用绝对定位
    /// 把光标移到屏底输入框应在的首行(self.rows - 估算框高),renderInner 从那里画 → 框落底部。
    /// 不进 alt-screen;绝对定位作用于可视屏(scrollback 模式合法)。
    fn reanchorBottomAfterOverlay(self: *RenderRegion) void {
        self.clearInner(); // 擦 transcript 区 + 回区顶,prev_rows=0/visible=false
        self.measureSize();
        // 估算输入框高:上下边框(2)+ 至少 1 内容行 + footer(1) = 4(无 TaskTab/slash 时)。
        // 多估几行无害:renderInner 的 shrink-erase 会清掉框下方多余空行。
        const box_h: u16 = 4;
        const w = &self.scratch.writer;
        self.resetScratch();
        var nbuf: [16]u8 = undefined;
        const target_row: u16 = if (self.rows > box_h) self.rows - box_h + 1 else 1;
        w.writeAll(ansi.cursor.move(target_row, 1, &nbuf)) catch {};
        self.flush();
        // 此后 input_cursor_row=0/prev_rows=0,renderInner 在 target_row 起画输入框(屏底)。
    }

    // =====================================================================
    // 生成期:文本零重绘 + 区(spinner+输入框+footer)按事件节流重画
    // =====================================================================

    /// 进入生成期:擦掉输入期框,选 verb,绑定待发送队列。不立即画(等首个 tick / 文本)。
    pub fn enterGenerating(self: *RenderRegion, app: *const app_mod.App, queue: ?*msg_queue.MsgQueue) void {
        self.lock();
        defer self.unlock();
        self.clearInner(); // 擦掉输入期框,光标回区顶行首(文本续接点)
        self.gen_app = app; // 供 writeGenText print 后重画区
        self.gen_queue = queue;
        self.gen_view = "";
        self.gen_cursor = 0;
        self.line_buf.clearRetainingCapacity(); // 新一轮:清行缓冲
        self.generating = true;
        self.region_drawn = false; // 区不在屏:首个 tick 才画区
        self.prev_rows = 0; // 生成期 prev_rows = 上次 drawGenRegion 画的 R(eraseRegion 用)
        self.cursor_in_region_row = 0;
        self.text_pending_newline = false;
        self.pending_col = 0;
        // 生成期状态单一真相源 = self.ui(drawGenRegion 读它)。overlay 强制关闭。
        self.ui.phase = .generating;
        self.ui.overlay = .none;
        self.ui.spinner = .{ .frame = 0, .verb = verbs.pick(@intCast(util_time.nowMs() & 0xffff)), .start_ms = util_time.nowMs() };
        self.ui.tools.current_len = 0;
        self.ui.tools.cards_len = 0;
    }

    /// 离开生成期:擦掉固定区(若在)+ 补半行换行 + 收尾。不再返回 carryover
    /// (待发送队列由主循环消费,见 loop.zig)。
    pub fn leaveGenerating(self: *RenderRegion, app: *const app_mod.App) void {
        _ = app;
        self.lock();
        defer self.unlock();
        self.flushGenAssistantLocked(); // 助手文本残行(markdown)先 flush
        self.flushLineBuf(); // 再把行缓冲残行(无尾随 \n 的末行)输出,别丢
        self.eraseRegion(); // 擦掉固定区(若在),光标回文本续接点
        if (self.text_pending_newline) {
            const w = &self.scratch.writer;
            self.resetScratch();
            w.writeAll("\n") catch {}; // 半行文本尾补换行,下一轮从干净行起
            self.flush();
            self.text_pending_newline = false;
            self.pending_col = 0;
        }
        self.generating = false;
        self.ui.phase = .input; // 同步:退生成期 → 输入期(双写过渡)
        self.region_drawn = false;
        self.gen_app = null;
        self.gen_queue = null;
        self.gen_view = "";
        self.gen_cursor = 0;
        self.prev_rows = 0;
        self.input_cursor_row = 0;
        self.cursor_in_region_row = 0;
        self.visible = false;
    }

    /// 设置生成期输入框内容(watcher 线程每次按键后调,再 redrawGen)。view 借用 watcher 的 editor.buf。
    pub fn setGenInput(self: *RenderRegion, view: []const u8, cursor: usize) void {
        self.lock();
        defer self.unlock();
        self.gen_view = view;
        self.gen_cursor = cursor;
    }

    /// 生成期重画(watcher 按键 / 入队后调):擦旧区(若在)+ 画新区。持锁。
    pub fn redrawGen(self: *RenderRegion, app: *const app_mod.App) void {
        self.lock();
        defer self.unlock();
        if (!self.generating) return;
        if (self.region_drawn) self.eraseRegion();
        self.drawGenRegion(app);
    }

    /// spinner tick(watcher 每 ~100ms)——推进帧 + 擦旧区(若在)+ 重画区。
    pub fn tickSpinner(self: *RenderRegion, app: *const app_mod.App) void {
        self.lock();
        defer self.unlock();
        if (!self.generating) return;
        self.ui.spinner.frame +%= 1;
        if (self.region_drawn) self.eraseRegion();
        self.drawGenRegion(app);
    }

    /// 生成期文本输出(RegionWriter 经此):**按行缓冲**——逐 token 攒进 line_buf,
    /// 每遇 `\n` 把"到该 \n 为止"的整段一次性输出(整行出现,不逐字闪烁);末尾残行
    /// 留在 line_buf,由 leaveGenerating(或 flushLineBuf)在轮末输出。
    pub fn writeGenText(self: *RenderRegion, text: []const u8) void {
        self.lock();
        defer self.unlock();
        if (text.len == 0) return;
        self.line_buf.appendSlice(self.allocator, text) catch {
            // OOM 兜底:缓冲失败就直接发,别丢字。
            self.emitToScroll(text);
            return;
        };
        // 找最后一个 \n:把 [0, last_nl] 整段(含末尾 \n)一次发,残余留缓冲。
        const items = self.line_buf.items;
        var last_nl: ?usize = null;
        var i: usize = items.len;
        while (i > 0) {
            i -= 1;
            if (items[i] == '\n') {
                last_nl = i;
                break;
            }
        }
        if (last_nl) |p| {
            self.emitToScroll(items[0 .. p + 1]);
            // 删掉已发部分,残行前移到缓冲头。
            const rest_len = items.len - (p + 1);
            std.mem.copyForwards(u8, self.line_buf.items[0..rest_len], items[p + 1 ..]);
            self.line_buf.shrinkRetainingCapacity(rest_len);
        }
    }

    /// flush 行缓冲里的残行(无尾随 \n 的最后一行)。leaveGenerating 调,确保末行不丢。
    fn flushLineBuf(self: *RenderRegion) void {
        if (self.line_buf.items.len == 0) return;
        self.emitToScroll(self.line_buf.items);
        self.line_buf.clearRetainingCapacity();
    }

    /// 助手文本段开始(stream_begin):重置 markdown 流式状态 + 标记段首(下一行用 ⏺ 前缀)。
    pub fn beginGenAssistant(self: *RenderRegion) void {
        self.lock();
        defer self.unlock();
        self.md_buf.clearRetainingCapacity();
        self.md_state = .{};
        self.md_at_segment_start = true;
    }

    /// 写助手文本(text_chunk):逐行过 markdown(render.renderLineStreaming)+ 段首 ⏺ / 续行
    /// 2 空格缩进,对齐 cc。残行留缓冲,下个 chunk 续接;stream_done 时 flushGenAssistant。
    pub fn writeGenAssistantText(self: *RenderRegion, text: []const u8) void {
        self.lock();
        defer self.unlock();
        if (text.len == 0) return;
        self.md_buf.appendSlice(self.allocator, text) catch {
            self.emitToScroll(text); // OOM 兜底裸发
            return;
        };
        // 逐个完整行(到 \n)渲染输出;残行留缓冲。
        while (std.mem.indexOfScalar(u8, self.md_buf.items, '\n')) |nl| {
            const line = self.md_buf.items[0..nl];
            self.emitAssistantLine(line, true);
            // 删已发行(含 \n)
            const rest = self.md_buf.items.len - (nl + 1);
            std.mem.copyForwards(u8, self.md_buf.items[0..rest], self.md_buf.items[nl + 1 ..]);
            self.md_buf.shrinkRetainingCapacity(rest);
        }
    }

    /// flush 助手文本残行(stream_done / leaveGenerating)。public:持锁。
    pub fn flushGenAssistant(self: *RenderRegion) void {
        self.lock();
        defer self.unlock();
        self.flushGenAssistantLocked();
    }

    /// flush 助手文本残行(内部,调用方已持锁)。
    fn flushGenAssistantLocked(self: *RenderRegion) void {
        if (self.md_buf.items.len == 0) return;
        self.emitAssistantLine(self.md_buf.items, false);
        self.md_buf.clearRetainingCapacity();
    }

    /// 渲染一行助手文本(markdown + 前缀)到 scrollback。with_nl=true 行尾加 \n。
    fn emitAssistantLine(self: *RenderRegion, line: []const u8, with_nl: bool) void {
        const md_render = @import("../render.zig");
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);
        // 前缀:段首行 `⏺ `(accent),续行 `  `(2 空格缩进,对齐 cc)。
        if (self.md_at_segment_start) {
            buf.appendSlice(self.allocator, self.theme.accent) catch {};
            buf.appendSlice(self.allocator, self.theme.icon_act) catch {};
            buf.appendSlice(self.allocator, self.theme.reset) catch {};
            buf.append(self.allocator, ' ') catch {};
            self.md_at_segment_start = false;
        } else {
            buf.appendSlice(self.allocator, "  ") catch {};
        }
        md_render.renderLineStreaming(line, &self.md_state, &buf, self.allocator) catch {
            // 渲染失败:裸发原行(带前缀已在 buf)。
            buf.appendSlice(self.allocator, line) catch {};
        };
        if (with_nl) buf.append(self.allocator, '\n') catch {};
        self.emitToScroll(buf.items);
    }

    /// 实际把一段文本输出到 scrollback:擦区(若在)→ print → 若刚才区在屏则重画区。
    /// print 仅在 region_drawn==false 时发生(eraseRegion 后),draw/erase 成对、续接点用画区快照还原。
    fn emitToScroll(self: *RenderRegion, text: []const u8) void {
        if (text.len == 0) return;
        const was_drawn = self.region_drawn;
        if (self.region_drawn) self.eraseRegion(); // 擦掉固定区 + 回文本续接点(半行末尾/新行首)
        const w = &self.scratch.writer;
        self.resetScratch();
        w.writeAll(text) catch {}; // 文本直接流入 scrollback
        self.flush();
        self.updatePendingTail(text);
        if (was_drawn) {
            if (self.gen_app) |a| self.drawGenRegion(a); // 区本在屏 → print 后立即重画(持续可见)
        }
    }

    /// 擦掉固定区(R 行),光标回"文本续接点"。
    /// **不变式**:drawGenRegion 末尾把光标停在 editor 编辑点,并记 cursor_in_region_row(距区顶行数);
    /// 此处先 UP(cursor_in_region_row)+\r 回区顶,再逐行下擦 R 行回顶。draw/erase 之间无 print 滚动
    /// → cursor_in_region_row 不失效(只 writeGenText 的 print 滚动,且发生在 erase 之后,区已不在屏)。
    fn eraseRegion(self: *RenderRegion) void {
        if (!self.region_drawn) return;
        const R = self.prev_rows;
        if (R == 0) {
            self.region_drawn = false;
            return;
        }
        const w = &self.scratch.writer;
        self.resetScratch();
        var nb: [16]u8 = undefined;
        w.writeAll(ansi.cursor.hide) catch {};
        // 光标当前在区内 cursor_in_region_row 行(编辑点)→ 先回区顶行首。
        if (self.cursor_in_region_row > 0) w.writeAll(ansi.cursor.up(self.cursor_in_region_row, &nb)) catch {};
        w.writeAll("\r") catch {};
        // 逐行清 R 行;行间 \r\n 下移。
        var i: u16 = 0;
        while (i < R) : (i += 1) {
            w.writeAll(ansi.clear.line) catch {};
            if (i < R - 1) w.writeAll("\r\n") catch {};
        }
        // 回区顶行首(= 文本末尾的下一行)。
        if (R > 1) w.writeAll(ansi.cursor.up(R - 1, &nb)) catch {};
        w.writeAll("\r") catch {};
        // 半行续接:按"画区那一刻"的快照还原(不读 live flag)。区顶上一行是文本末尾半行,回其末尾列。
        if (self.region_drawn_pending_nl) {
            w.writeAll(ansi.cursor.up(1, &nb)) catch {};
            w.writeAll("\r") catch {};
            if (self.region_drawn_pending_col > 0) w.writeAll(ansi.cursor.forward(self.region_drawn_pending_col, &nb)) catch {};
        }
        w.writeAll(ansi.cursor.show) catch {};
        self.flush();
        self.region_drawn = false;
    }

    /// 画生成期固定区(spinner + 队列预览 + 上框 + ❯editor(多行) + 下框 + footer),文本流末尾下方。
    /// 前置 region_drawn=false;后置 region_drawn=true,**光标停在 editor 编辑点**(供 IME 候选窗对齐),
    /// 并记 cursor_in_region_row(距区顶行数)供 eraseRegion 回顶。半行文本尾先 \n 封口让区独占整行。
    fn drawGenRegion(self: *RenderRegion, app: *const app_mod.App) void {
        self.measureSize();
        const w = &self.scratch.writer;
        self.resetScratch();
        var nb: [16]u8 = undefined;

        w.writeAll(ansi.cursor.hide) catch {};
        // 封口 + 快照续接点(供 eraseRegion 精确还原,不读 live flag)。
        self.region_drawn_pending_nl = self.text_pending_newline;
        self.region_drawn_pending_col = self.pending_col;
        if (self.text_pending_newline) {
            w.writeAll("\n") catch {};
        } else {
            w.writeAll("\r") catch {};
        }

        // overlay==.transcript:模态覆盖整个生成区,画 transcript 后直接返回
        // (跳过 spinner/cards/queue/panel/border/editor/footer 全套及末尾 editor 光标定位)。
        if (self.ui.overlay == .transcript) {
            self.drawGenTranscript(w, &nb);
            return;
        }

        const inner_w: usize = if (self.cols > 4) self.cols - 1 else 40;
        const border_color = self.borderColor(app.config.permission_mode);
        const content = self.gen_view;

        var vlines = VisualLines.init();
        layoutInput(content, &vlines, inner_w);

        var R: u16 = 0;

        // -- spinner 行 --(读 self.ui.spinner/tools 单一真相源,不再读旧双写字段)
        w.writeAll(ansi.clear.line) catch {};
        const elapsed: u64 = @intCast(@max(util_time.nowMs() - self.ui.spinner.start_ms, 0));
        const cur_tool = self.ui.tools.currentSlice();
        const tool_ms: u64 = if (self.ui.tools.current_len > 0)
            @intCast(@max(util_time.nowMs() - self.ui.tools.current_start_ms, 0))
        else
            0;
        // spinner 行只显普通工具段 `⚒ <tool>`(current)。hasProgressCard 工具(WebSearch)
        // 不进 current、改走下方 per-toolUse 多卡 → spinner 不显它们(对齐 cc)。
        _ = StatusBar.renderGenerating(w, app, self.theme, self.use_unicode, self.ui.spinner.frame, self.ui.spinner.verb, elapsed, cur_tool, tool_ms, inner_w) catch {};
        R += 1;
        w.writeAll("\r\n") catch {};

        // -- 执行中 per-toolUse 进度卡(读 self.ui.tools.cards 单一真相源)--
        {
            var ci: usize = 0;
            while (ci < self.ui.tools.cards_len) : (ci += 1) {
                R += self.drawToolProgressCard(w, &self.ui.tools.cards[ci]);
            }
        }

        // -- 待发送队列预览(每条 dim 灰,最多 3 条 + "+N more")--
        R += self.drawQueuePreview(w);

        // -- agent 进度树 + Task 清单面板(输入框上方)--
        R += self.drawPanel(w, app);

        // -- 上边框 --
        w.writeAll(ansi.clear.line) catch {};
        self.drawBorderLine(w, border_color, true, inner_w);
        const top_border_rownum = R; // 上边框在区内的行号(0-based)
        R += 1;
        w.writeAll("\r\n") catch {};

        // -- 内容行(❯ editor view;至少 1 行)--
        const content_rows = if (vlines.count == 0) 1 else vlines.count;
        var li: usize = 0;
        while (li < content_rows) : (li += 1) {
            w.writeAll(ansi.clear.line) catch {};
            if (li == 0) {
                w.print("{s}{s} {s}", .{ self.theme.accent, PROMPT_POINTER, self.theme.reset }) catch {};
            } else {
                w.writeAll("  ") catch {};
            }
            if (li < vlines.count) {
                const seg = vlines.slices[li];
                w.writeAll(content[seg.start..seg.end]) catch {};
            }
            R += 1;
            w.writeAll("\r\n") catch {};
        }

        // -- 下边框 --
        w.writeAll(ansi.clear.line) catch {};
        self.drawBorderLine(w, border_color, false, inner_w);
        R += 1;
        w.writeAll("\r\n") catch {};

        // -- footer(末行不 \r\n)或 help 菜单(help_open 时原地展开,对齐输入期 renderFrameInner)--
        if (self.ui.help_open) {
            // renderHelpLines 末行也带 \r\n → 光标多下移 1 行,补 up(1) 与 footer 分支对齐
            // (否则 footer_rownum 偏移 1 → 下帧回区顶少 1 行 → 顶边框残留;本会话输入期已踩过)。
            var hlw = RegionLineWriter{ .inner = w };
            const hrows = ui_mod.renderHelpLines(&hlw, self.theme, self.cols) catch 0;
            R += hrows;
            if (hrows > 0) w.writeAll(ansi.cursor.up(1, &nb)) catch {};
        } else {
            w.writeAll(ansi.clear.line) catch {};
            self.drawFooter(w, app);
            R += 1;
        }

        // 光标在 footer 行末 = 区最后一行(第 R-1 行)。
        // 收缩残留擦除:若新 R < 上次画的 prev_rows,清掉多余尾行。
        if (R < self.prev_rows) {
            const diff = self.prev_rows - R;
            var k: u16 = 0;
            while (k < diff) : (k += 1) {
                w.writeAll("\r\n") catch {};
                w.writeAll(ansi.clear.line) catch {};
            }
            w.writeAll(ansi.cursor.up(diff, &nb)) catch {};
        }

        // -- 光标落在 editor 编辑点(供 IME 候选窗对齐)--
        // 编辑点区内行号 = 上边框行号 + 1(❯ 行)+ loc.vline;列 = 2(prefix)+ loc.vcol。
        const loc = RenderRegion.locateCursor(content, self.gen_cursor, &vlines);
        const edit_row: u16 = top_border_rownum + 1 + @as(u16, @intCast(loc.vline));
        const footer_rownum: u16 = R - 1;
        if (footer_rownum > edit_row) {
            w.writeAll(ansi.cursor.up(footer_rownum - edit_row, &nb)) catch {};
        }
        w.writeAll(ansi.cursor.column(1, &nb)) catch {};
        const prefix_w: u32 = 2;
        w.writeAll(ansi.cursor.forward(prefix_w + @as(u32, @intCast(loc.vcol)), &nb)) catch {};

        w.writeAll(ansi.cursor.show) catch {};

        self.prev_rows = R;
        self.cursor_in_region_row = edit_row;
        self.region_drawn = true;
        self.flush();
    }

    /// 生成期 transcript 模态帧(对应输入期 renderOverlayInner,但记 cursor_in_region_row 而非
    /// input_cursor_row——生成期 eraseRegion 读前者)。调用前 drawGenRegion 已 hide+封口,
    /// 光标在区顶续接点。这里画 transcript → 收缩擦除 → 回区顶。w/nb 由 drawGenRegion 传入。
    fn drawGenTranscript(self: *RenderRegion, w: *std.Io.Writer, nb: []u8) void {
        // 几何注入(renderTranscript 用 state.rows 算窗口高 rows-3,天然限高不撑爆)。
        self.ui.cols = self.cols;
        self.ui.rows = self.rows;

        var lw = RegionLineWriter{ .inner = w };
        const frame = ui_mod.render(&lw, .{
            .state = &self.ui,
            .now_ms = util_time.nowMs(),
            .theme = self.theme,
            .use_unicode = self.use_unicode,
            .transcript_lines = if (self.transcript_lines) |ls| ls else &.{},
        }) catch ui_mod.Frame{};
        const new_rows: u16 = frame.rows;

        // renderTranscript 末行带 \r\n → 光标在区下方一行,up(1) 回区最后一行(同 renderOverlayInner)。
        if (new_rows > 0) w.writeAll(ansi.cursor.up(1, nb)) catch {};

        // 收缩残留擦除(transcript 关闭/变矮时清旧区尾行)。
        if (new_rows < self.prev_rows) {
            const diff = self.prev_rows - new_rows;
            var k: u16 = 0;
            while (k < diff) : (k += 1) {
                w.writeAll("\r\n") catch {};
                w.writeAll(ansi.clear.line) catch {};
            }
            w.writeAll(ansi.cursor.up(diff, nb)) catch {};
        }

        // 模态无编辑光标:回区顶行首。记 cursor_in_region_row=0 → eraseRegion 的 up(0) 自洽。
        if (new_rows > 1) w.writeAll(ansi.cursor.up(new_rows - 1, nb)) catch {};
        w.writeAll(ansi.cursor.column(1, nb)) catch {};
        w.writeAll(ansi.cursor.show) catch {};

        self.prev_rows = new_rows;
        self.cursor_in_region_row = 0;
        self.region_drawn = true;
        self.flush();
    }

    /// 最多 MAX 条,超出补一行 ` +N more`。
    /// 执行中 per-toolUse 进度卡(动态区,可刷新):⏺ <Tool> / ⎿ <progress>。对齐 cc 双段卡。
    /// 随每次 tickSpinner 重画。card 是某张 tool_cards 条目。
    fn drawToolProgressCard(self: *RenderRegion, w: *std.Io.Writer, card: *const ui_state_mod.ToolCardState) u16 {
        const th = self.theme;
        const tool_card = @import("widget/tool_card.zig");
        const inner_w: usize = if (self.cols > 8) self.cols - 8 else 30;
        var rows: u16 = 0;
        // 第 1 行:⏺ <display name>(WebSearch→"Web Search")。
        w.writeAll(ansi.clear.line) catch {};
        w.print("{s}{s}{s} {s}", .{ th.accent, th.icon_act, th.reset, tool_card.displayName(card.name[0..card.name_len]) }) catch {};
        rows += 1;
        w.writeAll("\r\n") catch {};
        // 第 2 行:  ⎿ <progress>(Searching: q / Found N results;随 tick 刷新)。
        // progress 未到(刚开始搜索)→ 用 "Searching…" 占位,对齐 cc 执行中即显第二行。
        w.writeAll(ansi.clear.line) catch {};
        const prog: []const u8 = if (card.progress_len > 0)
            card.progress[0..card.progress_len]
        else
            "Searching…";
        w.print("  {s}{s}{s} ", .{ th.dim, th.gutter, th.reset }) catch {};
        writeTruncatedWidth(w, prog, inner_w);
        w.writeAll(th.reset) catch {};
        rows += 1;
        w.writeAll("\r\n") catch {};
        return rows;
    }

    fn drawQueuePreview(self: *RenderRegion, w: *std.Io.Writer) u16 {
        const q = self.gen_queue orelse return 0;
        const MAX = 3;
        var buf: [MAX][]const u8 = undefined;
        const total = q.len();
        if (total == 0) return 0;
        const shown = q.snapshot(&buf);
        var rows: u16 = 0;
        const th = self.theme;
        const inner_w: usize = if (self.cols > 6) self.cols - 6 else 30;
        var i: usize = 0;
        while (i < shown) : (i += 1) {
            w.writeAll(ansi.clear.line) catch {};
            // 取首行(\n 前)+ 按 inner_w 截断(显示宽)。
            const msg = buf[i];
            const first_line = if (std.mem.indexOfScalar(u8, msg, '\n')) |p| msg[0..p] else msg;
            w.print("{s} ⏳ ", .{th.dim}) catch {};
            writeTruncatedWidth(w, first_line, inner_w);
            w.writeAll(th.reset) catch {};
            rows += 1;
            w.writeAll("\r\n") catch {};
        }
        if (total > shown) {
            w.writeAll(ansi.clear.line) catch {};
            w.print("{s}    +{d} more{s}", .{ th.dim, total - shown, th.reset }) catch {};
            rows += 1;
            w.writeAll("\r\n") catch {};
        }
        return rows;
    }

    /// 更新 text_pending_newline / pending_col(半行 chunk 续接用)。
    fn updatePendingTail(self: *RenderRegion, text: []const u8) void {
        if (text.len == 0) return;
        if (text[text.len - 1] == '\n') {
            self.text_pending_newline = false;
            self.pending_col = 0;
            return;
        }
        var last_nl: ?usize = null;
        var i: usize = text.len;
        while (i > 0) {
            i -= 1;
            if (text[i] == '\n') {
                last_nl = i;
                break;
            }
        }
        const tail = if (last_nl) |p| text[p + 1 ..] else text;
        const tail_w: u16 = @intCast(@min(displayWidth(tail), 65535));
        if (last_nl != null) {
            self.pending_col = tail_w; // 本 chunk 内换行了 → 重置为换行后部分
        } else {
            self.pending_col +%= tail_w; // 接续上一半行
        }
        self.text_pending_newline = true;
    }
};

/// RegionWriter —— 包装给 agent_loop 的 stdout_writer。
/// 实现 `print(fmt,args) !void`(与 DebugWriter 同签名),把文本经
/// RenderRegion.writeGenText 输出(生成期单行协议)。用 `&region_writer` 传入。
pub const RegionWriter = struct {
    region: *RenderRegion,

    pub fn print(self: *RegionWriter, comptime fmt: []const u8, args: anytype) !void {
        // 用栈 buffer 格式化(避免 alloc);超长截断。
        var buf: [4096]u8 = undefined;
        const s = std.fmt.bufPrint(&buf, fmt, args) catch buf[0..buf.len];
        self.region.writeGenText(s);
    }

    /// agent_loop 经 comptime 探测调用:把当前工具喂给底部 spinner(普通工具)。
    pub fn setCurrentTool(self: *RegionWriter, name: []const u8, start_ms: i64) void {
        self.region.setCurrentTool(name, start_ms);
    }
    pub fn clearCurrentTool(self: *RegionWriter) void {
        self.region.clearCurrentTool();
    }
    /// per-toolUse 进度卡(WebSearch):建/删/刷新进度,按 tool_use id 路由。
    pub fn addToolCard(self: *RegionWriter, id: []const u8, name: []const u8, start_ms: i64) void {
        self.region.addToolCard(id, name, start_ms);
    }
    pub fn clearToolCard(self: *RegionWriter, id: []const u8) void {
        self.region.clearToolCard(id);
    }
    pub fn setToolProgress(self: *RegionWriter, id: []const u8, text: []const u8) void {
        self.region.setToolProgress(id, text);
    }
};

// ---------------------------------------------------------------------------
// 显示宽度 helpers(收敛自 loop.zig / term.zig)
// ---------------------------------------------------------------------------

/// 输入框 prompt 指针(复刻 Claude Code 的 figures.pointer)。
const PROMPT_POINTER = "❯";

/// visual line 切分结果(逻辑行 \n + 软折行后的各段 byte 区间)。
/// 固定上限避免 alloc;超出上限的行不再记录(极长输入降级)。
const VisualLines = struct {
    const MAX = 256;
    const Seg = struct { start: usize, end: usize };
    slices: [MAX]Seg = undefined,
    count: usize = 0,

    fn init() VisualLines {
        return .{};
    }
    fn push(self: *VisualLines, start: usize, end: usize) void {
        if (self.count >= MAX) return;
        self.slices[self.count] = .{ .start = start, .end = end };
        self.count += 1;
    }
};

/// 一个 UTF-8 字符占几字节(首字节决定)。非法/截断 → 1。
fn nextCharBytes(s: []const u8, i: usize) usize {
    if (i >= s.len) return 1;
    const b = s[i];
    const n: usize = if (b < 0x80) 1 else if (b >= 0xF0) 4 else if (b >= 0xE0) 3 else if (b >= 0xC0) 2 else 1;
    return if (i + n <= s.len) n else 1;
}

fn displayWidth(s: []const u8) usize {
    return term.displayWidth(s);
}

/// TaskTab 文本选择(纯函数,可单测):首个 in_progress 任务的 active_form(无则 subject)。
/// 无 in_progress → null。
pub fn taskTabLabel(tasks: *const @import("../../core/task_store.zig").TaskStore) ?[]const u8 {
    for (tasks.tasks.items) |t| {
        if (t.status == .in_progress) return t.active_form orelse t.subject;
    }
    return null;
}

/// 把 text 截断到不超过 max_w 显示列(CJK=2),为省略号留 1 列。返回 byte 终点。
/// 整体宽度 ≤ max_w 时返回 text.len(不截)。纯函数,可单测。
pub fn truncateToWidth(text: []const u8, max_w: usize) usize {
    if (displayWidth(text) <= max_w) return text.len;
    var cur: usize = 0;
    var i: usize = 0;
    var end: usize = 0;
    while (i < text.len) {
        const nb = nextCharBytes(text, i);
        const cw = displayWidth(text[i .. i + nb]);
        if (cur + cw > max_w - 1) break;
        cur += cw;
        i += nb;
        end = i;
    }
    return end;
}

/// 把纯文本(无 SGR)按显示宽 max_w 截断写出(CJK=2);超长尾部省略。
fn writeTruncatedWidth(w: *std.Io.Writer, s: []const u8, max_w: usize) void {
    var vis: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const nb = nextCharBytes(s, i);
        const end = @min(i + nb, s.len);
        const cw = displayWidth(s[i..end]);
        if (vis + cw > max_w) {
            w.writeAll("…") catch {};
            return;
        }
        w.writeAll(s[i..end]) catch {};
        vis += cw;
        i = end;
    }
}

fn displayWidthUpTo(s: []const u8, byte_off: usize) usize {
    const end = @min(byte_off, s.len);
    return term.displayWidth(s[0..end]);
}

test "RenderRegion init/deinit no leak" {
    // 非 tty 环境 getSize 返 null → 用默认 24x80
    var r = RenderRegion.init(std.testing.allocator, 2, theme_mod.select(.monochrome, .none), .none);
    defer r.deinit();
    try std.testing.expect(r.cols >= 1);
}

test "setCurrentTool/clearCurrentTool: 存取 + 截断 + 归零(读 ui.tools 真相源)" {
    var r = RenderRegion.init(std.testing.allocator, 2, theme_mod.select(.monochrome, .none), .none);
    defer r.deinit();
    try std.testing.expectEqual(@as(u8, 0), r.ui.tools.current_len);

    r.setCurrentTool("Bash", 1000);
    try std.testing.expectEqualStrings("Bash", r.ui.tools.currentSlice());
    try std.testing.expectEqual(@as(i64, 1000), r.ui.tools.current_start_ms);

    // 超 48B 的工具名应截断到 48,不越界。
    const long = "ThisIsAnAbsurdlyLongToolNameThatExceedsFortyEightBytesForSure";
    r.setCurrentTool(long, 2000);
    try std.testing.expectEqual(@as(u8, 48), r.ui.tools.current_len);
    try std.testing.expectEqualStrings(long[0..48], r.ui.tools.currentSlice());

    r.clearCurrentTool();
    try std.testing.expectEqual(@as(u8, 0), r.ui.tools.current_len);
}

test "per-toolUse 多卡:按 id 各写各卡不互盖 + 增删(读 ui.tools 真相源)" {
    var r = RenderRegion.init(std.testing.allocator, 2, theme_mod.select(.monochrome, .none), .none);
    defer r.deinit();
    try std.testing.expectEqual(@as(u8, 0), r.ui.tools.cards_len);

    // 两个并发 WebSearch:各一张卡。
    r.addToolCard("id_a", "WebSearch", 100);
    r.addToolCard("id_b", "WebSearch", 200);
    try std.testing.expectEqual(@as(u8, 2), r.ui.tools.cards_len);

    // 各写各的 progress,不互盖。
    r.setToolProgress("id_a", "Searching: alpha");
    r.setToolProgress("id_b", "Searching: beta");
    const ia = ui_state_mod.findCard(&r.ui, "id_a").?;
    const ib = ui_state_mod.findCard(&r.ui, "id_b").?;
    try std.testing.expectEqualStrings("Searching: alpha", r.ui.tools.cards[ia].progressSlice());
    try std.testing.expectEqualStrings("Searching: beta", r.ui.tools.cards[ib].progressSlice());

    // 重复 addToolCard 同 id 不新增。
    r.addToolCard("id_a", "WebSearch", 300);
    try std.testing.expectEqual(@as(u8, 2), r.ui.tools.cards_len);

    // 删一张,另一张保留且 progress 不丢。
    r.clearToolCard("id_a");
    try std.testing.expectEqual(@as(u8, 1), r.ui.tools.cards_len);
    try std.testing.expect(ui_state_mod.findCard(&r.ui, "id_a") == null);
    const ib2 = ui_state_mod.findCard(&r.ui, "id_b").?;
    try std.testing.expectEqualStrings("Searching: beta", r.ui.tools.cards[ib2].progressSlice());

    r.clearToolCard("id_b");
    try std.testing.expectEqual(@as(u8, 0), r.ui.tools.cards_len);
}

test "nextCharBytes UTF-8 宽度" {
    try std.testing.expectEqual(@as(usize, 1), nextCharBytes("a", 0));
    try std.testing.expectEqual(@as(usize, 3), nextCharBytes("中", 0)); // 中文 3 字节
    try std.testing.expectEqual(@as(usize, 1), nextCharBytes("", 0)); // 越界保底
}

test "layoutInput:逻辑行 \\n 切分" {
    const view = "abc\ndef";
    var vl = VisualLines.init();
    RenderRegion.layoutInput(view, &vl, 80);
    try std.testing.expectEqual(@as(usize, 2), vl.count);
    try std.testing.expectEqualStrings("abc", view[vl.slices[0].start..vl.slices[0].end]);
    try std.testing.expectEqualStrings("def", view[vl.slices[1].start..vl.slices[1].end]);
}

test "layoutInput:软折行(窄宽)" {
    const view = "aaaaaaaa"; // 8 个 a
    var vl = VisualLines.init();
    RenderRegion.layoutInput(view, &vl, 6); // inner_w=6 → avail=3 → 应折成多行
    try std.testing.expect(vl.count >= 2);
}

test "locateCursor:多行光标定位" {
    const view = "abc\ndef";
    var vl = VisualLines.init();
    RenderRegion.layoutInput(view, &vl, 80);
    // 光标在第二逻辑行的 'e' 后(byte offset 5 = "abc\nd|ef")
    const loc = RenderRegion.locateCursor(view, 5, &vl);
    try std.testing.expectEqual(@as(usize, 1), loc.vline); // 第 2 行
    try std.testing.expectEqual(@as(usize, 1), loc.vcol); // 'd' 后 1 列
}

test "locateCursor:中文显示列宽" {
    const view = "中文x"; // 中(2)文(2)x(1)
    var vl = VisualLines.init();
    RenderRegion.layoutInput(view, &vl, 80);
    // "中文|x" → 6 字节(2 个中文各 3 字节)
    const loc = RenderRegion.locateCursor(view, 6, &vl);
    try std.testing.expectEqual(@as(usize, 0), loc.vline);
    try std.testing.expectEqual(@as(usize, 4), loc.vcol); // 2+2 列
}
