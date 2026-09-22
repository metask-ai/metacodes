//! RenderRegion —— 底部锚定固定重绘区(复刻 Claude Code 观感,不进 alt-screen)。
//!
//! 见 doc/TUI_STATE_ARCHITECTURE.md。核心:屏幕底部维护固定高度的几行(StatusBar +
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
const sync = @import("platform").sync;
const app_mod = @import("../../app.zig");
const types = @import("../../types.zig");
const ansi = @import("ansi.zig");
const term = @import("term.zig");
const theme_mod = @import("theme.zig");
const verbs = @import("verbs.zig");
const StatusBar = @import("widget/status_bar.zig").StatusBar;
const util_time = @import("../../util/time.zig");
const complete = @import("../complete.zig");
const model_command = @import("../model_command.zig");
const msg_queue = @import("../msg_queue.zig");
const agent_tree = @import("widget/agent_tree.zig");
const agent_job_registry = @import("../../core/agent_job_registry.zig");
const ui_mod = @import("ui.zig");
const model_picker_view = @import("../model_picker_view.zig");
const event_mod = @import("event.zig");
const input = @import("../input.zig");
const ui_state_mod = @import("ui_state.zig");
const transcript_viewer = @import("../transcript_viewer.zig");
const Conversation = @import("../../core/conversation.zig").Conversation;

const Theme = theme_mod.Theme;
const ColorCapability = term.ColorCapability;

pub const RenderRegion = struct {
    /// Ctrl+O 重开去抖窗口(ms)。键盘 auto-repeat 通常 ≤66ms/次(>15/s),故 120ms 能折叠
    /// "按住"连发,又远小于人为"开→关→再开"的有意间隔 → 不误伤故意快速 toggle。见 noteCtrloAndShouldSuppressReopen。
    const OVERLAY_REOPEN_DEBOUNCE_MS: i64 = 120;

    fd: c_int,
    cols: u16 = 80,
    rows: u16 = 24,
    prev_rows: u16 = 0, // 上一帧固定区总行数;0=未画。eraseRegion 用它擦旧区。
    overlay_region_height: u16 = 0, // enterExclusiveOverlay 捕获的 erase 前区高(viewer anchor 兜底用)
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
    /// 帧内标志:true 时 eraseRegion/drawGenRegion 不各自 reset/flush,由外层 frame 统一
    /// 一次 flush(并用 DEC 2026 同步输出包裹)→ 擦除+重画成原子帧,消除 Windows 闪烁。
    frame_active: bool = false,
    // Ctrl+O alt-screen toggle 去抖时戳(单调 ms;0=从未)。见 noteCtrloAndShouldSuppressReopen。
    last_overlay_ctrlo_ms: i64 = 0,
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
    /// plan 模式:位于 <proposed_plan>...</proposed_plan> 块内(块内容不进 scrollback,
    /// 计划由审批框单独展示;对齐 mecode strip_proposed_plan_blocks)。
    in_proposed_plan: bool = false,

    // markdown 表格累积(GFM):流式逐行到达,需缓冲整块再渲染(对齐 cc 框线)。
    tbl_rows: std.ArrayList([]u8) = .empty, // 原始行 owned dup(含分隔行)
    in_table: bool = false,
    tbl_unconfirmed: bool = false, // 表头已缓冲、分隔行未到(暂定,可回滚)

    // 阶段1:overlay 逻辑态(help/transcript)由 UiState 承载;机制态(prev_rows 等)仍在上面。
    ui: ui_state_mod.UiState = .{},

    mutex: sync.Mutex = .{},

    fn lock(self: *RenderRegion) void {
        _ = self.mutex.lock();
    }
    fn unlock(self: *RenderRegion) void {
        _ = self.mutex.unlock();
    }

    /// 生成期 overlay(全屏 transcript viewer,alt-screen)用:持渲染锁,使 agent_loop emit 线程
    /// 阻塞在锁上、不与 viewer 抢 stdout。enter/exit 必须配对。viewer 自身不请求本锁(无死锁)。
    /// viewer 自己进/出 alt-screen 独立缓冲(ESC[?1049h/l)全屏画 transcript,退出由终端**自动恢复主
    /// 缓冲**;exit 持锁 drawGenRegion 在恢复后的主缓冲上重画固定区 → 释放锁。
    /// 注:enter 里的 eraseRegion / overlay_region_height / 半行封口是旧 inline(DECSC)模式遗留,
    /// alt-screen 下不再被 viewer 依赖(独立缓冲全屏绝对定位);保留仅遵守"其他保持不变"scope,
    /// overlay_region_height 已是死量(viewer 丢弃 anchor_hint),后续清理时一并删。
    /// Ctrl+O alt-screen toggle 去抖。键盘 auto-repeat(按住 Ctrl+O / "不断 Ctrl+O")会发一连串
    /// CSI-u(`ESC[111;5u`,白名单终端如 Warp)或裸 0x0f → 每个都 toggle 一次 transcript viewer
    /// 的 alt-screen(`ESC[?1049h`/`l`)。真终端(用户实测 Warp)跟不上这种高频 alt-screen 切换 →
    /// footer 多行堆叠 + 退出后输入框不幂等(偏移/残留)。离线 pty 复现不出(Screen 模型如实
    /// 模拟 alt-screen 存/复原,1049h/l 配对即干净),但真机抖动是确凿的。
    ///
    /// 修法:open 前调本函数,**记下本次 Ctrl+O 时戳**(故名 note...),并返回是否抑制——若距上次
    /// Ctrl+O < 阈值则抑制重开,使"按住一次"只产生一对 open/close(viewer 自身的 close 仍正常,
    /// 只压住紧随其后的 reopen)。每次 Ctrl+O 都刷新时戳,按住期间持续刷新 → 全程不重开;松开后
    /// (间隔 > 阈值)的下次 Ctrl+O 正常开。close 由 viewer 内部消费、不经此门 → 故意打开再关闭恒生效。
    /// 返回 true = 本次应被抑制(调用方不开 viewer)。**有副作用**(写 last_overlay_ctrlo_ms),名字已点明。
    ///
    /// 线程安全:`last_overlay_ctrlo_ms` 只被 Ctrl+O 处理路径碰。生成期由 watcher 线程调(tui_backend),
    /// 输入期由主线程调(loop.zig)——两期**时间互斥**(要么在生成、要么在输入提示符,绝不并发),
    /// 故无并发读写,不需锁。即便退一万步有 torn read:aligned i64 在 arm64/x86-64 上读写本就原子,
    /// 且值是单调时戳,最坏结果只是去抖窗口偏一下,绝不崩。
    pub fn noteCtrloAndShouldSuppressReopen(self: *RenderRegion) bool {
        const now = util_time.nowMs();
        const prev = self.last_overlay_ctrlo_ms;
        self.last_overlay_ctrlo_ms = now;
        return prev != 0 and (now - prev) < OVERLAY_REOPEN_DEBOUNCE_MS;
    }

    pub fn enterExclusiveOverlay(self: *RenderRegion) void {
        self.lock();
        // 半行封口(text_pending_newline 时补 \n):旧 inline 模式为对齐 DECSC 存档点在行首。alt-screen 下
        // 不再用 DECSC,但补 \n 仍无害(保 scrollback 末行干净),保留不动。
        if (self.generating and self.text_pending_newline) {
            const w = &self.scratch.writer;
            self.resetScratch();
            w.writeAll("\n") catch {};
            self.flush();
            self.text_pending_newline = false;
            self.pending_col = 0;
        }
        // overlay_region_height:DEAD(viewer 丢弃 anchor_hint),保留不动,见上注。
        self.overlay_region_height = self.prev_rows;
        if (self.generating and self.region_drawn) self.eraseRegion();
        // 区状态清零:exit 从干净态 drawGenRegion 重画(对话由 alt-screen 退出自动恢复)。
        self.region_drawn = false;
        self.prev_rows = 0;
        self.cursor_in_region_row = 0;
    }

    /// **DEAD since 2026-06-13 alt-screen 切换**:旧 inline 模式的区顶 anchor 兜底(DSR 不可用时用)。
    /// viewer 现已 `_ = anchor_hint;` 丢弃(独立缓冲全屏绝对定位,不需 anchor)。保留仅遵守"其他保持
    /// 不变"scope,后续清理一并删。
    pub fn overlayAnchorHint(self: *const RenderRegion, rows: usize) usize {
        const h: usize = self.overlay_region_height;
        if (h == 0 or h > rows) return 1;
        return rows - h + 1;
    }
    pub fn exitExclusiveOverlay(self: *RenderRegion, app: *const app_mod.App) void {
        if (self.generating) {
            // footer 残影根因(真机 Warp + DSR 诊断坐实):alt-screen 退出 `?1049l` 主缓冲恢复**不精确**
            // (游标列不还原、偶尔行偏 1),旧版"假设恢复干净直接重画"→ 旧固定区行残留。
            // 修复点不在这里特判,而在 drawGenRegion 开头的 `ESC[0J`(每次区重画都把区下方主动清净)——
            // 单一机制、不依赖 ?1049/DECRC 的恢复精度(DSR 证明 Warp 对 DECSC/DECRC 也不还原列,已删那条死路)。
            self.drawGenRegion(app);
        }
        self.unlock();
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
    pub fn addToolCard(self: *RenderRegion, id: []const u8, name: []const u8, input_json: []const u8, start_ms: i64) void {
        self.lock();
        defer self.unlock();
        ui_state_mod.addCard(&self.ui, id, name, input_json, start_ms);
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
                self.redrawFrameLocked(app);
            }
        }
    }

    pub fn init(allocator: std.mem.Allocator, fd: c_int, theme: Theme, cap: ColorCapability) RenderRegion {
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
        self.scratch.deinit();
        self.line_buf.deinit(self.allocator);
        self.md_buf.deinit(self.allocator);
        for (self.tbl_rows.items) |r| self.allocator.free(r);
        self.tbl_rows.deinit(self.allocator);
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
    /// 另:有运行中后台 subagent 时,即便无 todo 也画一行
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

        // ---- Agent viewing(持久查看):view==.viewing 时主区(框上方 panel 位)换被查看 agent 的
        // **完整对话历史(output_buf 视口,可 PageUp/Dn 滚)** + 分隔线,替代进度树/task。
        // 下方 drawAgentSwitcher 列表仍画(共存)。viewing 视口预算独立放宽(不受上面 12 行限制):
        // 扣死 框(3) + footer(1) + switcher(空行1+main1+agent_count) + 分隔头(1) + 余量后,剩给视口。
        if (self.ui.agents.view == .viewing) {
            // viewing 时回写 agent_count(供 dispatch ↑↓ 钳制 + 下面预算计算)。
            if (app.agentJobsPtr()) |reg| {
                const snaps = reg.snapshotJobsForSession(self.allocator, app.session_id) catch null;
                if (snaps) |s| {
                    self.ui.agent_count = s.len;
                    agent_job_registry.AgentJobRegistry.freeSnapshots(self.allocator, s);
                }
            }
            // viewing 视口预算:总行 rows - 框3 - footer1 - switcher(2+agent_count) - 分隔头1 - 余量1。
            const switcher_rows: u16 = 2 + @as(u16, @intCast(@min(self.ui.agent_count, 200)));
            const fixed_below: u16 = 3 + 1 + switcher_rows + 1 + 1; // 框+footer+switcher+分隔头+余量
            const view_budget: u16 = if (self.rows > fixed_below) self.rows - fixed_below else 0;
            used += self.drawAgentViewing(w, app, view_budget);
            return used;
        }

        // ---- agent 进度树 ----
        // 用 App.agentJobsPtr()(指向 App 字段本身),不要 `if (app.agent_jobs) |reg|`
        // 捕获——那是值拷贝,listLock 会锁栈副本的 mutex 而非真 registry 的(race)。
        if (app.agentJobsPtr()) |reg| {
            const snaps = reg.snapshotJobsForSession(self.allocator, app.session_id) catch null;
            if (snaps) |s| {
                defer agent_job_registry.AgentJobRegistry.freeSnapshots(self.allocator, s);
                // agent_count 镜像回写(dispatch ↓/← 入口 + 选择钳制用,switcher 关闭时也更新)。
                self.ui.agent_count = s.len;
                if (s.len > 0) {
                    const tree = agent_tree.render(self.allocator, self.theme, s, util_time.nowMs()) catch null;
                    if (tree) |t| {
                        defer self.allocator.free(t);
                        used += self.writePanelLines(w, t, budget - used);
                    }
                }
            } else {
                self.ui.agent_count = 0;
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

    /// Task 清单(◼ in_progress / ◻ pending / ✓ completed,completed 过 TTL 不显)。
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
                .completed => if (self.use_unicode) "✓" else "[x]", // 勾:完成(对齐用户预期/真 cc todo done)
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

        const inner_w: usize = self.innerWidth();
        const border_color = self.borderColor(app.permMode());

        // shell 模式(对齐 cc DIFF#3):buffer 以 `!` 开头 → 前缀 `!`(替 ❯),内容去掉 `!`、footer
        // 变 `! for shell mode`、placeholder 变。`! ` 与 `❯ ` 同宽(2 列),layout 用 body 不偏移。
        const shell = isShellMode(content);
        const body: []const u8 = if (shell) content[1..] else content;

        var vlines = VisualLines.init();
        layoutInput(body, &vlines, inner_w);

        var new_rows: u16 = 0;

        // -- TaskTab(可选,输入框上方 1 行)--
        const task_tab_rows = self.drawTaskTab(w, app);
        new_rows += task_tab_rows;

        // -- Ctrl+Y paste 提示(对齐 cc DIFF#9:框上方右对齐 `Ctrl+Y to paste deleted text`)--
        if (self.ui.paste_hint) {
            w.writeAll(ansi.clear.line) catch {};
            const hint = "Ctrl+Y to paste deleted text";
            const hw = displayWidth(hint);
            if (self.cols > hw) {
                var g: usize = 0;
                while (g < self.cols - hw) : (g += 1) w.writeAll(" ") catch {};
            }
            w.print("{s}{s}{s}", .{ self.theme.dim, hint, self.theme.reset }) catch {};
            w.writeAll("\r\n") catch {};
            new_rows += 1;
        }

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
                // 前缀:shell 模式 `!`(warn 色,对齐 cc),否则 `❯`(accent)。
                if (shell) {
                    w.print("{s}{s} {s}", .{ self.theme.warn, "!", self.theme.reset }) catch {};
                } else {
                    w.print("{s}{s} {s}", .{ self.theme.accent, PROMPT_POINTER, self.theme.reset }) catch {};
                }
            } else {
                w.writeAll("  ") catch {};
            }
            if (li == 0 and body.len == 0) {
                // 空 body → 灰色 placeholder(对齐 cc:普通 `Try "fix typecheck errors"`,shell `Try "fix lint errors"`)。
                // (layoutInput 对空串也 push 一个 (0,0) 段 → vlines.count==1,故不能靠 li<vlines.count 判空。)
                const ph = if (shell) "Try \"fix lint errors\"" else "Try \"fix typecheck errors\"";
                w.print("{s}{s}{s}", .{ self.theme.dim, ph, self.theme.reset }) catch {};
            } else if (li < vlines.count) {
                const seg = vlines.slices[li];
                w.writeAll(body[seg.start..seg.end]) catch {};
            }
            new_rows += 1;
            w.writeAll("\r\n") catch {};
        }

        // -- 下边框 --
        w.writeAll(ansi.clear.line) catch {};
        self.drawBorderLine(w, border_color, false, inner_w);
        new_rows += 1;
        w.writeAll("\r\n") catch {};

        // -- issue #16 model picker:开着时独占菜单区。旧的 /model 与 /models 菜单
        //    占同一块屏幕位置,同时画会互相盖掉。--
        const picker_rows: u16 = if (self.ui.picker_open)
            model_picker_view.render(&app.model_picker, w, self.theme, self.cols)
        else
            0;
        new_rows += picker_rows;
        // -- /models 两级菜单:账号 API key → 该 key 可用模型 --
        const models_menu_rows = if (picker_rows == 0) self.drawModelsPickerMenu(w, app, content) else 0;
        new_rows += models_menu_rows;
        // -- /model 服务端 catalog 菜单(输入 `/model` 后立即在底部显示候选,不等提交)--
        const model_menu_rows = if (picker_rows == 0 and models_menu_rows == 0)
            self.drawModelCatalogMenu(w, app, content)
        else
            0;
        new_rows += model_menu_rows;
        // -- slash 命令菜单(`/` 前缀,在下边框与 footer 之间垂直列出)--
        if (picker_rows == 0 and models_menu_rows == 0 and model_menu_rows == 0) new_rows += self.drawSlashMenu(w, content);
        // -- @-mention 文件菜单(`@token`,同位置;对齐 cc DIFF#5)--
        if (picker_rows == 0) new_rows += self.drawAtMenu(w, content, self.input_cursor);

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
            if (shell) {
                // shell 模式 footer:`! for bash mode`(对齐 cc PromptInputFooterLeftSide ModeIndicator,
                // mode==='bash' → `! for bash mode`;无 mode part / token)。
                w.print("{s}  ! for bash mode{s}", .{ self.theme.dim, self.theme.reset }) catch {};
            } else {
                self.drawFooter(w, app);
            }
            new_rows += 1;
        }

        // Agent switcher(区域2):footer 下方,占额外行。在收缩擦除前累加进 new_rows。
        new_rows += self.drawAgentSwitcher(w, app);
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

        // 4. 光标移到内容行(区内行号:TaskTab(0/1) + paste提示(0/1) + 上边框(1) + loc.vline)。
        // shell 模式:cursor 是相对完整 content(含 `!`)的;body 去掉了 `!` → body_cursor = cursor-1。
        const body_cursor: usize = if (shell and cursor > 0) cursor - 1 else cursor;
        const loc = RenderRegion.locateCursor(body, body_cursor, &vlines);
        const hint_rows: u16 = if (self.ui.paste_hint) 1 else 0;
        const target_row: u16 = task_tab_rows + hint_rows + 1 + @as(u16, @intCast(loc.vline));
        // 最底行 = new_rows-1(footer + 可能的 agent switcher 行)。光标从最底回输入行。
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

    /// 画一条横边框线。对齐 cc 2.1.x:输入框是上下两条**全宽水平线**(无圆角、无左右竖线),
    /// 内容行 `❯ text` 本就无侧竖线。top 参数保留(两条线视觉相同,语义上区分上/下)。
    fn drawBorderLine(self: *RenderRegion, w: *std.Io.Writer, color: []const u8, top: bool, inner_w: usize) void {
        _ = top;
        const th = self.theme;
        w.writeAll(color) catch {};
        var i: usize = 0;
        while (i < inner_w) : (i += 1) w.writeAll(th.box_h) catch {};
        w.writeAll(th.reset) catch {};
    }

    /// 画 slash 命令菜单(`/` 前缀且无空格时)。每行 ` /cmd   描述`,匹配项列出。
    /// 选中项(self.ui.slash_sel)命令名用 accent 高亮,其余 dim(对齐 cc:↑↓ 移高亮)。
    /// 返回新增行数(每行末尾 \r\n,光标停下一行行首供 footer 续画)。调用前光标停下边框下一行行首。
    fn drawSlashMenu(self: *RenderRegion, w: *std.Io.Writer, content: []const u8) u16 {
        const trimmed = std.mem.trimStart(u8, content, " \t");
        if (!std.mem.startsWith(u8, trimmed, "/")) return 0;
        if (std.mem.indexOfScalar(u8, trimmed, ' ') != null) return 0; // 已带参数 → 不弹菜单

        const th = self.theme;
        var rows: u16 = 0;
        const MAX_ROWS: u16 = 10; // 菜单最多列 10 项,防撑爆终端
        var match_idx: usize = 0; // 第几个匹配项(与 slash_sel 对齐)
        for (complete.SLASH_COMMAND_TABLE) |cmd| {
            if (!std.mem.startsWith(u8, cmd.name, trimmed)) continue;
            if (rows >= MAX_ROWS) break;
            const selected = match_idx == self.ui.slash_sel;
            w.writeAll(ansi.clear.line) catch {};
            // 对齐 cc:固定 2 空格缩进,选中项命令名 accent,非选中 dim gray(仅颜色区分,不移位)。
            const name_color = if (selected) th.accent else th.dim;
            w.print("  {s}{s}{s}", .{ name_color, cmd.name, th.reset }) catch {};
            const pad = if (cmd.name.len < 14) 14 - cmd.name.len else 1;
            var p: usize = 0;
            while (p < pad) : (p += 1) w.writeAll(" ") catch {};
            w.print("{s}{s}{s}", .{ th.dim, cmd.desc, th.reset }) catch {};
            w.writeAll("\r\n") catch {};
            rows += 1;
            match_idx += 1;
        }
        return rows;
    }

    fn drawModelsPickerMenu(self: *RenderRegion, w: *std.Io.Writer, app: *const app_mod.App, content: []const u8) u16 {
        const trimmed = std.mem.trim(u8, content, " \t\r\n");
        if (!std.mem.eql(u8, trimmed, "/models") and !std.mem.eql(u8, trimmed, "/model")) return 0;
        if (app.models_picker_key_index == null) return self.drawApiKeyMenu(w, app);
        if (app.models_picker_model_index != null) return self.drawReasoningMenu(w, app);
        return self.drawModelCatalogMenuForTitle(w, app, "Models for selected API key");
    }

    fn drawReasoningMenu(self: *RenderRegion, w: *std.Io.Writer, app: *const app_mod.App) u16 {
        const th = self.theme;
        const entries = app.api_client.catalog.entries.items;
        const model_idx = app.models_picker_model_index orelse 0;
        const mask = if (model_idx < entries.len) entries[model_idx].reasoning_mask else 0;
        var efforts_buf: [5]types.ReasoningEffort = undefined;
        const efforts = reasoningOptions(mask, &efforts_buf);
        var rows: u16 = 0;

        w.writeAll(ansi.clear.line) catch {};
        w.print("  {s}Reasoning effort{s}", .{ th.accent, th.reset }) catch {};
        if (model_idx < entries.len) {
            w.print(" {s}for {s}{s}", .{ th.dim, entries[model_idx].model_id, th.reset }) catch {};
        }
        w.writeAll("\r\n") catch {};
        rows += 1;

        // 标签用这条路由自己的词汇:目录只声明 max 的(Metask 网关 / GLM)顶档显示 max,
        // 不是内部枚举名 xhigh——用户选的是 provider 的档位。
        const vocabulary = if (model_idx < entries.len) entries[model_idx].effort_vocabulary else .neutral;
        const selected_idx = @min(self.ui.slash_sel, efforts.len - 1);
        for (efforts, 0..) |effort, i| {
            const selected = i == selected_idx;
            const color = if (selected) th.accent else th.dim;
            w.writeAll(ansi.clear.line) catch {};
            w.print("  {s}{s} {s}{s}", .{ color, if (selected) ">" else " ", @import("../../api/catalog.zig").effortLabel(vocabulary, effort), th.reset }) catch {};
            w.writeAll("\r\n") catch {};
            rows += 1;
        }
        return rows;
    }

    fn drawApiKeyMenu(self: *RenderRegion, w: *std.Io.Writer, app: *const app_mod.App) u16 {
        const th = self.theme;
        const entries = app.api_key_catalog.entries.items;
        var rows: u16 = 0;

        w.writeAll(ansi.clear.line) catch {};
        w.print("  {s}API keys for this account{s}", .{ th.accent, th.reset }) catch {};
        if (entries.len > 0) {
            w.print(" {s}({d}){s}", .{ th.dim, entries.len, th.reset }) catch {};
        } else {
            w.print(" {s}(unavailable){s}", .{ th.dim, th.reset }) catch {};
        }
        w.writeAll("\r\n") catch {};
        rows += 1;

        if (entries.len == 0) {
            w.writeAll(ansi.clear.line) catch {};
            w.print("  {s}login with OAuth, or set {s} to the account API-key endpoint{s}", .{ th.dim, @import("../../api/api_keys.zig").API_KEYS_URL_ENV, th.reset }) catch {};
            w.writeAll("\r\n") catch {};
            return rows + 1;
        }

        const MAX_ROWS: u16 = @intCast(complete.MODEL_MENU_MAX_ROWS);
        const selected_idx = @min(self.ui.slash_sel, @min(entries.len, complete.MODEL_MENU_MAX_ROWS) - 1);
        var shown: u16 = 0;
        for (entries, 0..) |entry, i| {
            if (shown >= MAX_ROWS) break;
            const selected = i == selected_idx;
            const color = if (selected) th.accent else th.dim;
            w.writeAll(ansi.clear.line) catch {};
            w.print("  {s}{s} ", .{ color, if (selected) ">" else " " }) catch {};
            const reserve = if (entry.group.len > 0) @as(usize, 34) else @as(usize, 28);
            writeTruncatedWidth(w, entry.label, if (self.cols > reserve) self.cols - reserve else 16);
            if (entry.group.len > 0) {
                w.print("{s} {s}[", .{ th.reset, th.dim }) catch {};
                writeTruncatedWidth(w, entry.group, 24);
                w.writeAll("]") catch {};
            }
            w.print("{s} {s}...{s}{s}", .{ th.reset, th.dim, entry.suffix, th.reset }) catch {};
            w.writeAll("\r\n") catch {};
            rows += 1;
            shown += 1;
            if (shown == MAX_ROWS and i + 1 < entries.len) {
                w.writeAll(ansi.clear.line) catch {};
                w.print("  {s}… +{d} more API keys{s}", .{ th.dim, entries.len - shown, th.reset }) catch {};
                w.writeAll("\r\n") catch {};
                rows += 1;
                break;
            }
        }
        return rows;
    }

    /// 输入框里正好是 `/model` 时,在下边框与 footer 之间显示启动期从服务端 `/v1/models`
    /// probe 到的模型列表。这里故意只读 server catalog,不把内置 fallback 伪装成服务端结果。
    fn drawModelCatalogMenu(self: *RenderRegion, w: *std.Io.Writer, app: *const app_mod.App, content: []const u8) u16 {
        const trimmed = std.mem.trim(u8, content, " \t\r\n");
        if (!std.mem.eql(u8, trimmed, "/model")) return 0;
        return self.drawModelCatalogMenuForTitle(w, app, "Models from server");
    }

    fn drawModelCatalogMenuForTitle(self: *RenderRegion, w: *std.Io.Writer, app: *const app_mod.App, title: []const u8) u16 {
        const th = self.theme;
        const entries = app.api_client.catalog.entries.items;
        var rows: u16 = 0;

        w.writeAll(ansi.clear.line) catch {};
        w.print("  {s}{s}{s}", .{ th.accent, title, th.reset }) catch {};
        if (entries.len > 0) {
            w.print(" {s}({d}){s}", .{ th.dim, entries.len, th.reset }) catch {};
        } else {
            w.print(" {s}(unavailable){s}", .{ th.dim, th.reset }) catch {};
        }
        w.writeAll("\r\n") catch {};
        rows += 1;

        if (entries.len == 0) {
            w.writeAll(ansi.clear.line) catch {};
            w.print("  {s}server model list unavailable; press Enter for local model groups{s}", .{ th.dim, th.reset }) catch {};
            w.writeAll("\r\n") catch {};
            return rows + 1;
        }

        const MAX_ROWS: u16 = @intCast(complete.MODEL_MENU_MAX_ROWS);
        const id_max: usize = if (self.cols > 42) self.cols - 42 else 24;
        const selected_idx = @min(self.ui.slash_sel, @min(entries.len, complete.MODEL_MENU_MAX_ROWS) - 1);
        var shown: u16 = 0;
        for (entries, 0..) |entry, i| {
            if (shown >= MAX_ROWS) break;
            const selected = i == selected_idx;
            const current = std.mem.eql(u8, entry.model_id, app.activeModel());
            const color = if (selected or current) th.accent else th.dim;
            var caps_buf: [96]u8 = undefined;
            const caps = capabilityChips(app.config.provider_kind, entry.model_id, &caps_buf);

            w.writeAll(ansi.clear.line) catch {};
            w.print("  {s}{s}{s} ", .{ color, if (selected) ">" else " ", if (current) "*" else " " }) catch {};
            writeTruncatedWidth(w, entry.model_id, id_max);
            w.print("{s} {s}{s}", .{ th.reset, th.dim, model_command.groupForModel(entry.model_id) }) catch {};
            if (entry.max_input_tokens) |ctx| w.print(" ctx={d}", .{ctx}) catch {};
            if (entry.max_tokens) |out| w.print(" out={d}", .{out}) catch {};
            w.print(" {s}{s}", .{ caps, th.reset }) catch {};
            w.writeAll("\r\n") catch {};
            rows += 1;
            shown += 1;

            if (shown == MAX_ROWS and i + 1 < entries.len) {
                w.writeAll(ansi.clear.line) catch {};
                w.print("  {s}… +{d} more from server{s}", .{ th.dim, entries.len - shown, th.reset }) catch {};
                w.writeAll("\r\n") catch {};
                rows += 1;
                break;
            }
        }
        return rows;
    }

    /// 画 @-mention 文件菜单(`@token`,下边框与 footer 之间)。每行 `+ <path>`(对齐 cc),
    /// 选中项(self.ui.slash_sel)accent 高亮,其余 dim。候选来自 complete.atCandidates(文件路径)。
    /// 返回新增行数。alloc 失败/无候选返回 0(不弹)。
    fn drawAtMenu(self: *RenderRegion, w: *std.Io.Writer, content: []const u8, cursor: usize) u16 {
        if (!complete.atMenuActive(content, cursor)) return 0;
        var r = complete.atCandidates(self.allocator, content, cursor) catch return 0;
        defer r.deinit(self.allocator);
        if (r.candidates.len == 0) return 0;

        const th = self.theme;
        var rows: u16 = 0;
        const MAX_ROWS: u16 = 10;
        for (r.candidates, 0..) |cand, i| {
            if (rows >= MAX_ROWS) break;
            const selected = i == self.ui.slash_sel;
            w.writeAll(ansi.clear.line) catch {};
            // cc 文件项前缀 `+ `;选中 accent,非选中 dim。
            const color = if (selected) th.accent else th.dim;
            w.print("  {s}+ {s}{s}", .{ color, cand, th.reset }) catch {};
            w.writeAll("\r\n") catch {};
            rows += 1;
        }
        return rows;
    }

    /// footer(纯左对齐,对齐 cc:无右侧 token):
    ///   非 default → `{symbol} {title} on (shift+tab to cycle)`[生成期 ` · esc to interrupt`]
    ///   default → 生成期 `esc to interrupt` / 输入期 `? for shortcuts`
    /// mode part 用 modeColor 单独着色(plan→cyan/acceptEdits→magenta/bypass·dontAsk→red/auto→yellow);
    /// 其余文字 dim。token 用量走 /cost,不进 footer。
    fn drawFooter(self: *RenderRegion, w: *std.Io.Writer, app: *const app_mod.App) void {
        const th = self.theme;
        const sb = @import("widget/status_bar.zig");
        // mode 真相源 = app.permission_ctx.mode(live):输入期与 config 同步,生成期工具
        // (EnterPlanMode/ExitPlanMode)直接写它 → spinner tick 重画即反映(修 #11 生成期不联动)。
        // self.ui.footer.mode 仅当 ctx 为 default 但 footer 被 .usage 喂过非默认值时兜底(罕见)。
        const live = app.permission_ctx.modeValue();
        const mode_pm = if (live != .default) live else self.ui.footer.mode;
        const sym = sb.modeSymbol(mode_pm);
        const title = sb.modeTitle(mode_pm);
        // 缓冲含粘贴占位符 `[Pasted text #N +M lines]`(空闲期)→ footer 整条换成
        // `paste again to expand`(对齐真 cc v2.1.172:连 mode part 一起替换),占位符删后自动复原。
        const paste_placeholder = !self.generating and
            std.mem.indexOf(u8, self.input_view, "[Pasted text #") != null;
        const show_mode = title.len != 0 and !paste_placeholder; // default/prompt 或占位符态 → 不显 mode part

        // mode part 纯文本(用于宽度计算,不含 SGR)。cc 格式:非 default → `{sym} {title} on (shift+tab to cycle)`;
        // default → 无 mode part(下方 hint 显 `? for shortcuts`)。对齐 cc 真实 footer。
        var mode_buf: [96]u8 = undefined;
        const mode_plain = if (show_mode)
            (std.fmt.bufPrint(&mode_buf, " {s} {s} on (shift+tab to cycle)", .{ sym, title }) catch "")
        else
            "";
        // default 态显 `? for shortcuts`;非 default 已在 mode part 含 cycle 提示,hint 留空。
        // 生成期(self.generating):右接 `esc to interrupt`(对齐 cc:中断提示在 footer 非 spinner 行)。
        // cc 实测:非 default → `{mode part} · esc to interrupt`(有 `· ` 分隔);default → `esc to interrupt`。
        // agent 区域(对齐实拍 v2.1.168):
        //   生成期 + 有 running agent → 追加 ` · ↓ to manage`(进 switcher 选择)。
        //   空闲期 + 有 agent(running/done 均可查看)→ 追加 ` · ← for agents`。
        var has_running_agents = false;
        var has_any_agents = false;
        if (app.agentJobsPtr()) |reg| {
            has_running_agents = reg.runningCountForSession(app.session_id) > 0;
            has_any_agents = reg.totalCountForSession(app.session_id) > 0;
        }
        var hint_buf: [96]u8 = undefined;
        const hint: []const u8 = blk: {
            if (self.generating) {
                const base = if (show_mode) " · esc to interrupt" else " esc to interrupt";
                if (has_running_agents) {
                    break :blk std.fmt.bufPrint(&hint_buf, "{s} · ↓ to manage", .{base}) catch base;
                }
                break :blk base;
            }
            // 空闲期。
            // 占位符态:整条 footer = `paste again to expand`(show_mode 已被置 false)。
            if (paste_placeholder) break :blk " paste again to expand";
            // 多行编辑中:显示当前终端的换行方式(对齐真 cc getNewlineInstructions,按 cc-zig 实际能力:
            // 白名单终端 shift+⏎,Apple Terminal 等 \+⏎)。提示最有用时=正在组多行。
            const multiline = std.mem.indexOfScalar(u8, self.input_view, '\n') != null;
            if (multiline) {
                break :blk std.fmt.bufPrint(&hint_buf, "  {s}", .{input.newlineHint()}) catch " ? for shortcuts";
            }
            const base = if (show_mode) "" else " ? for shortcuts";
            if (has_any_agents) {
                break :blk std.fmt.bufPrint(&hint_buf, "{s} · ← for agents", .{base}) catch base;
            }
            break :blk base;
        };

        // 写:mode part 用 modeColor 着色,其余 dim。cc footer 纯左对齐快捷键,**无右侧 token**
        // (对齐 cc:footer 行只左对齐文案;token 用量走 /cost)。
        if (show_mode) {
            w.writeAll(sb.modeColor(th, mode_pm)) catch {};
            w.writeAll(mode_plain) catch {};
            w.writeAll(th.reset) catch {};
        }
        w.writeAll(th.dim) catch {};
        w.writeAll(hint) catch {};
        w.writeAll(th.reset) catch {};
    }

    /// Agent viewing 帧(区域2 持久查看):view==.viewing 时画在**输入框上方**(替代 panel 位置)——
    /// 一行右对齐分隔 label `──── <desc> ──` + **被查看 subagent 的完整对话历史视口**(output_buf,
    /// 可 PageUp/Dn 滚)。对齐真 cc v2.1.169/170 实拍金标准:viewing 主区整体换成被查看 subagent
    /// 的对话(prompt + 助手文本 + 工具行)。被查看对象由 viewing_id 解析(Enter 提交,↑↓ 不动)。
    /// viewing_committed=false 时落定 viewing_id;view_top_at_bottom/越界由本函数 clamp。返回画的行数。
    fn drawAgentViewing(self: *RenderRegion, w: *std.Io.Writer, app: *const app_mod.App, budget: u16) u16 {
        if (self.ui.agents.view != .viewing) return 0;
        if (budget == 0) return 0;
        const reg = app.agentJobsPtr() orelse return 0;
        const sel = self.ui.agents.sel;
        const th = self.theme;
        const snaps = reg.snapshotJobsForSession(self.allocator, app.session_id) catch return 0;
        defer agent_job_registry.AgentJobRegistry.freeSnapshots(self.allocator, snaps);

        // viewing_id 落定(Enter 触发的 reconcile):未 committed 时把当前 sel 对应 agent 的 id 拷入。
        if (!self.ui.agents.viewing_committed and sel > 0 and sel - 1 < snaps.len) {
            self.ui.agents.commitViewingId(snaps[sel - 1].id);
        }
        // 按已落定的 viewing_id 找被查看 agent 的 desc + id(非 sel —— ↑↓ 移光标不切被查看对象)。
        const vid = self.ui.agents.viewingIdSlice();
        if (vid.len == 0) return 0;
        var desc: []const u8 = "";
        var found = false;
        for (snaps) |s| {
            if (std.mem.eql(u8, s.id, vid)) {
                desc = s.desc;
                found = true;
                break;
            }
        }
        if (!found) return 0; // 被查看 agent 已消失(完成/停止移除)→ 不画

        const cols: usize = if (self.ui.cols > 4) self.ui.cols else 80;
        // ── 分隔线头:`──────── <desc> ──`(右对齐 desc)。
        w.writeAll(ansi.clear.line) catch {};
        w.writeAll(th.dim) catch {};
        {
            const dw = displayWidth(desc);
            const pad = if (cols > dw + 4) cols - dw - 4 else 0;
            var i: usize = 0;
            while (i < pad) : (i += 1) w.writeAll("─") catch {};
            w.print(" {s} ──", .{desc}) catch {};
        }
        w.writeAll(th.reset) catch {};
        w.writeAll("\r\n") catch {};
        var rows: u16 = 1;

        // ── output_buf 对话视口(budget-1 行,分隔头占 1 行)。
        const view_rows: u16 = if (budget > 1) budget - 1 else 0;
        if (view_rows == 0) return rows;

        const out = (reg.copyOutputBufForSession(vid, self.allocator, app.session_id) catch null) orelse {
            // 无 output_buf(刚起未产出)→ 占位一行。
            w.writeAll(ansi.clear.line) catch {};
            w.print("  {s}(no output yet){s}", .{ th.dim, th.reset }) catch {};
            w.writeAll("\r\n") catch {};
            return rows + 1;
        };
        defer self.allocator.free(out);

        // view_top clamp:max_top = max(0, total_lines - view_rows)。at_bottom 落定到 max_top。
        const total = countOutputLines(out);
        const max_top: usize = if (total > view_rows) total - view_rows else 0;
        if (self.ui.agents.view_top_at_bottom) {
            self.ui.agents.view_top = max_top;
            self.ui.agents.view_top_at_bottom = false;
        } else if (self.ui.agents.view_top > max_top) {
            self.ui.agents.view_top = max_top; // PageDn 越界自愈
        }
        rows += drawOutputWindow(w, out, self.ui.agents.view_top, view_rows, cols, th);
        return rows;
    }

    /// Agent switcher 列表(区域2,footer 下方)。对齐 cc v2.1.168 实拍:
    ///   <空行>
    ///   ⏺ main                              ↑/↓ to select · Enter to view
    ///   ◯ Explore  Summarize mod0.py                                  3s
    /// 仅当 ui.agents.view != .closed 时画。返回画的行数(供 new_rows 累加)。
    /// 每行前置 `\r\n` + clear(承接 footer 行末光标);caller 据返回行数算几何。
    fn drawAgentSwitcher(self: *RenderRegion, w: *std.Io.Writer, app: *const app_mod.App) u16 {
        if (self.ui.agents.view == .closed) return 0;
        const reg = app.agentJobsPtr() orelse return 0;
        const th = self.theme;
        const snaps = reg.snapshotJobsForSession(self.allocator, app.session_id) catch return 0;
        defer agent_job_registry.AgentJobRegistry.freeSnapshots(self.allocator, snaps);

        const cols: usize = if (self.ui.cols > 4) self.ui.cols else 80;
        const ag = &self.ui.agents;
        var rows: u16 = 0;

        // 空行分隔(footer 与 switcher 间)。
        w.writeAll("\r\n") catch {};
        w.writeAll(ansi.clear.line) catch {};
        rows += 1;

        // 行 0:main。marker ⏺(在 main 视图)/◯(在看 agent)。右对齐 hint 随选择目标变。
        const main_selected = ag.selection_active and ag.sel == 0;
        const viewing = ag.view == .viewing;
        {
            w.writeAll("\r\n") catch {};
            w.writeAll(ansi.clear.line) catch {};
            // 选择光标 ❯(选中行左侧)。
            if (main_selected) {
                w.print("{s}❯ {s}", .{ th.accent, th.reset }) catch {};
            } else {
                w.writeAll("  ") catch {};
            }
            const marker = if (viewing) "◯" else "⏺";
            const mc = if (viewing) th.dim else th.accent;
            w.print("{s}{s}{s} main", .{ mc, marker, th.reset }) catch {};
            // 右对齐 hint。
            const hint = if (ag.selection_active and ag.sel > 0)
                "Enter to view · x to stop · ctrl+x ctrl+k to stop all agents"
            else
                "↑/↓ to select · Enter to view";
            const left_w: usize = (if (main_selected) @as(usize, 4) else 2) + 1 + 5; // ❯/space + marker + " main"
            const hint_w = displayWidth(hint);
            if (cols > left_w + hint_w + 1) {
                const pad = cols - left_w - hint_w;
                var i: usize = 0;
                while (i < pad) : (i += 1) w.writeAll(" ") catch {};
            } else {
                w.writeAll(" ") catch {};
            }
            w.print("{s}{s}{s}", .{ th.dim, hint, th.reset }) catch {};
            rows += 1;
        }

        // 行 1..N:每个 agent。marker ◯(普通)/⏺(被查看)。`<Type>  <desc>` + 右对齐 `Ns`。
        const now = util_time.nowMs();
        for (snaps, 0..) |s, idx| {
            const sel_row = idx + 1;
            const is_selected = ag.selection_active and ag.sel == sel_row;
            // viewing 时被查看 agent(marker ⏺)= viewing_id 命中(Enter 提交,非 sel)。
            // ↑↓ 移 ❯(is_selected)不改 ⏺;只有 Enter 重新落定 viewing_id 才切 ⏺。
            const is_viewed = viewing and std.mem.eql(u8, s.id, ag.viewingIdSlice());
            w.writeAll("\r\n") catch {};
            w.writeAll(ansi.clear.line) catch {};
            if (is_selected) {
                w.print("{s}❯ {s}", .{ th.accent, th.reset }) catch {};
            } else {
                w.writeAll("  ") catch {};
            }
            const marker = if (is_viewed) "⏺" else "◯";
            w.print("{s}{s}{s} ", .{ th.dim, marker, th.reset }) catch {};
            // <Type>  <desc>。
            const elapsed_s: i64 = if (s.started_ms != 0) @divTrunc(@max(now - s.started_ms, 0), 1000) else 0;
            var es_buf: [16]u8 = undefined;
            const es = std.fmt.bufPrint(&es_buf, "{d}s", .{elapsed_s}) catch "0s";
            // 左侧文本宽度估算(marker 2 + cursor 2 + type + 2sp + desc)。
            const type_w = displayWidth(s.agent_type);
            const desc_w = displayWidth(s.desc);
            w.print("{s}{s}{s}  {s}", .{ th.accent, s.agent_type, th.reset, s.desc }) catch {};
            const left_w: usize = 2 + 2 + type_w + 2 + desc_w;
            const es_w = displayWidth(es);
            if (cols > left_w + es_w + 1) {
                const pad = cols - left_w - es_w;
                var i: usize = 0;
                while (i < pad) : (i += 1) w.writeAll(" ") catch {};
            } else {
                w.writeAll(" ") catch {};
            }
            w.print("{s}{s}{s}", .{ th.dim, es, th.reset }) catch {};
            rows += 1;
        }

        // agent_count 镜像回写(dispatch ↓ 选择钳制用)。
        self.ui.agent_count = snaps.len;
        return rows;
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
            // 光标在本段内(含段末;最后一段含 view.len)。
            // 非末段:若段末是 \n(逻辑换行),cur==seg.end 归本段(=行尾,光标在 \n 前);
            // 若段末是软折点(无 \n,下段从同 byte 起),cur==seg.end 归下段行首(col 0),故不含。
            const ends_in_nl = seg.end < view.len and view[seg.end] == '\n';
            const seg_end_incl = if (vi == vlines.count - 1 or ends_in_nl) seg.end + 1 else seg.end;
            if (cur >= seg.start and cur < seg_end_incl) {
                const vcol = displayWidth(view[seg.start..@min(cur, seg.end)]);
                return .{ .vline = vi, .vcol = vcol };
            }
        }
        return .{ .vline = 0, .vcol = 0 };
    }

    /// locateCursor 的逆:给定目标 visual line + 目标显示列(goal_vcol),返回落点 byte offset。
    /// 纯函数。竖移(up/down)用——保 goal column,clamp 到目标行宽,返回恒为字符边界。
    /// 约定与 locateCursor 一致:返回「光标所在字符左缘列 >= goal_vcol」的首个字符的 byte index;
    /// 走到段末未达 goal → 返段末(seg.end)= 该可视行尾(\n 前 / 软折点)。
    fn offsetForVisualPos(view: []const u8, vlines: *const VisualLines, target_vline: usize, goal_vcol: usize) usize {
        if (vlines.count == 0) return 0;
        const vi = @min(target_vline, vlines.count - 1);
        const seg = vlines.slices[vi];
        var i = seg.start;
        var col: usize = 0;
        while (i < seg.end) {
            if (col >= goal_vcol) return i;
            const nb = nextCharBytes(view, i);
            col += displayWidth(view[i .. i + nb]);
            i += nb;
        }
        return seg.end; // clamp 到可视行尾
    }

    /// 输入框内宽(单一真相源:与 renderInput/renderGenerating 的 inner_w 完全一致)。
    fn innerWidth(self: *const RenderRegion) usize {
        return if (self.cols > 4) self.cols - 1 else 40;
    }

    pub const VMoveResult = struct { moved: bool, cursor: usize, goal_vcol: usize };

    /// up/down 在多行/软折缓冲里做【可视行】竖移(对齐真 cc v2.1.172)。
    /// moved=false 表示光标已在首/末可视行边界(调用方据此回退历史导航)。
    /// 否则返回新 cursor(byte offset)+ 保留/初始化的 goal_vcol。
    /// 用 self.cols 算 inner_w(故须在 RenderRegion 上而非纯 dispatch);持锁读 cols。
    pub fn tryVerticalMove(self: *RenderRegion, input_view: []const u8, cursor: usize, cur_goal: ?usize, dir_down: bool) VMoveResult {
        self.lock();
        const inner_w = self.innerWidth();
        self.unlock();
        var vlines = VisualLines.init();
        layoutInput(input_view, &vlines, inner_w);
        const loc = locateCursor(input_view, cursor, &vlines);
        // 边界:末行 down / 首行 up → 不动,回退历史。
        if (dir_down and loc.vline + 1 >= vlines.count) return .{ .moved = false, .cursor = cursor, .goal_vcol = loc.vcol };
        if (!dir_down and loc.vline == 0) return .{ .moved = false, .cursor = cursor, .goal_vcol = loc.vcol };
        const goal = cur_goal orelse loc.vcol;
        const target = if (dir_down) loc.vline + 1 else loc.vline - 1;
        const new_cursor = offsetForVisualPos(input_view, &vlines, target, goal);
        return .{ .moved = true, .cursor = new_cursor, .goal_vcol = goal };
    }

    /// 公开重画(持锁)。输入期调用。
    pub fn render(self: *RenderRegion, app: *const app_mod.App) void {
        self.lock();
        defer self.unlock();
        if (self.generating) return; // 生成期不画多行区
        self.renderInner(app);
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
        _ = conv;
        const eff = ui_mod.dispatch(&self.ui, ev);
        // transcript 现走 alt-screen viewer(Ctrl+O → dispatch 上抛 .open_transcript,
        // 调用方进 alt-screen),不再嵌入式渲染。此处只处理输入框固定区重画。
        if (eff.redraw_region and !self.generating) {
            self.renderInner(app);
        }
        return eff;
    }

    /// 生成期按键分流(对应输入期 applyEvent,持锁)。watcher 线程调:同步 editor 投影 →
    /// dispatch(复用输入期同一份 `?`/help/Ctrl+O 语义)→ 重画走 drawGenRegion。
    /// 返回 Effect 供 watcher 决定是否喂 LineEditor / 执行 .open_transcript 等上抛动作。
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
        _ = conv;
        // dispatch 判"空 buffer + ?"依赖 editor 投影,调前同步 watcher 的 LineEditor 视图。
        self.ui.editor = .{ .view = ed_view, .cursor = ed_cursor };
        const eff = ui_mod.dispatch(&self.ui, .{ .key = .{ .key = key } });
        if (eff.redraw_region and self.generating) {
            self.redrawFrameLocked(app);
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
        // 生成期状态单一真相源 = self.ui(drawGenRegion 读它)。
        self.ui.phase = .generating;
        self.ui.spinner = .{ .frame = 0, .verb = verbs.pick(@intCast(util_time.nowMs() & 0xffff)), .start_ms = util_time.nowMs() };
        self.ui.tools.current_len = 0;
        self.ui.tools.cards_len = 0;
    }

    /// 离开生成期:擦掉固定区(若在)+ 提交完成态 spinner 行进 scrollback + 补半行换行 + 收尾。
    /// 完成态(对齐 cc DIFF#2):`✻ <Verb过去式> for Ns · ↓ N tokens`,提交进 scrollback 留痕。
    /// 不再返回 carryover(待发送队列由主循环消费,见 loop.zig)。
    pub fn leaveGenerating(self: *RenderRegion, app: *const app_mod.App) void {
        _ = app; // 完成态 spinner 不再读 usage(去 token);签名保留供 callers 稳定。
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
        // -- 完成态 spinner:**不**提交进 scrollback(产品决策)--
        // spinner 是纯瞬态指示器,生成结束即随固定区一起擦掉(上面 eraseRegion 已抹掉),不留任何
        // `✻ Verb for Ns` 进历史消息区。旧版每轮(≥0.5s)都 commit 一行 → 1~2s 琐碎短轮也堆噪声
        // (用户实测 bug)。注:cc 默认有 turn_duration 系统消息(REPL.tsx:2970,仅 >30s 长轮),
        // 但用户明确要求 cc-zig 不要它 → 此处不对齐 cc,彻底不提交。
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
    /// 原子重画固定区(擦除+重画包成一帧,DEC 2026 同步输出):消除 Windows Terminal 在
    /// erase→draw 两步之间呈现"空白帧"导致的输入框闪烁 + 分隔线分段。所有"擦了立刻重画
    /// 固定区"的路径统一走这里。**须已持锁**。
    fn redrawFrameLocked(self: *RenderRegion, app: *const app_mod.App) void {
        self.resetScratch();
        self.scratch.writer.writeAll(ansi.sync.begin) catch {};
        self.frame_active = true;
        if (self.region_drawn) self.eraseRegion(); // frame 内:不 reset 不 flush
        self.drawGenRegion(app); //                  frame 内:不 reset 不 flush
        self.frame_active = false;
        self.scratch.writer.writeAll(ansi.sync.end) catch {};
        self.flush(); // 整帧一次性呈现
    }

    pub fn redrawGen(self: *RenderRegion, app: *const app_mod.App) void {
        self.lock();
        defer self.unlock();
        if (!self.generating) return;
        self.redrawFrameLocked(app);
    }

    /// spinner tick(watcher 每 ~100ms)——推进帧 + 擦旧区(若在)+ 重画区。
    pub fn tickSpinner(self: *RenderRegion, app: *const app_mod.App) void {
        self.lock();
        defer self.unlock();
        if (!self.generating) return;
        self.ui.spinner.frame +%= 1;
        self.redrawFrameLocked(app);
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

    /// 结束当前 scrollback 行:若末尾是半行(text_pending_newline)补一个 \n;已在行首则 no-op。
    /// 幂等——连调多次只补一次。供 stream_done 用,替代旧的无条件 writeGenText("\n")(后者在
    /// 助手文本已以 \n 结尾时多吐空行 → 多批次 tool 卡间冒空行 bug 的根因)。
    /// 先 flush 两个缓冲(助手 markdown 残行 + 普通行缓冲残行),否则 text_pending_newline 不含缓冲态。
    pub fn endScrollLine(self: *RenderRegion) void {
        self.lock();
        defer self.unlock();
        self.flushGenAssistantLocked();
        self.flushLineBuf();
        if (!self.text_pending_newline) return; // 已在行首 → 幂等 no-op
        const was_drawn = self.region_drawn;
        if (self.region_drawn) self.eraseRegion();
        const w = &self.scratch.writer;
        self.resetScratch();
        w.writeAll("\n") catch {};
        self.flush();
        self.text_pending_newline = false;
        self.pending_col = 0;
        if (was_drawn) {
            if (self.gen_app) |a| self.drawGenRegion(a);
        }
    }

    /// 助手文本段开始(stream_begin):重置 markdown 流式状态 + 标记段首(下一行用 ⏺ 前缀)。
    pub fn beginGenAssistant(self: *RenderRegion) void {
        self.lock();
        defer self.unlock();
        self.md_buf.clearRetainingCapacity();
        self.md_state = .{};
        self.md_at_segment_start = true;
        self.in_proposed_plan = false; // 新一轮助手文本,重置 plan 块状态
        self.resetTableLocked();
    }

    /// 清空表格累积态(free 每行 dup)。调用方持锁。
    fn resetTableLocked(self: *RenderRegion) void {
        for (self.tbl_rows.items) |r| self.allocator.free(r);
        self.tbl_rows.clearRetainingCapacity();
        self.in_table = false;
        self.tbl_unconfirmed = false;
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
            self.handleAssistantLine(line);
            // 删已发行(含 \n)
            const rest = self.md_buf.items.len - (nl + 1);
            std.mem.copyForwards(u8, self.md_buf.items[0..rest], self.md_buf.items[nl + 1 ..]);
            self.md_buf.shrinkRetainingCapacity(rest);
        }
    }

    /// 处理一条完整助手文本行:表格检测/缓冲(对齐 cc 框线),否则普通 emit。
    /// 表格识别须前瞻分隔行,但流式逐行到达 → pipe 行先当暂定表头,下行确认或回滚。
    fn handleAssistantLine(self: *RenderRegion, line: []const u8) void {
        const md_render = @import("../render.zig");

        // <proposed_plan> 块过滤:整行标签开/闭块,块内容不显示(计划走审批框)。
        // 不在 code-block 内才识别(代码块里出现同名行按字面)。对齐 mecode 整行匹配规则。
        if (!self.md_state.in_code_block) {
            const t = std.mem.trim(u8, line, " \t\r");
            if (!self.in_proposed_plan and std.mem.eql(u8, t, "<proposed_plan>")) {
                self.in_proposed_plan = true;
                return; // 吞标签行
            }
            if (self.in_proposed_plan) {
                if (std.mem.eql(u8, t, "</proposed_plan>")) self.in_proposed_plan = false;
                return; // 吞块内容 + 闭标签行
            }
        }

        if (self.in_table) {
            if (self.tbl_unconfirmed) {
                // 等分隔行确认。
                if (md_render.isTableSeparator(line)) {
                    self.appendTableRow(line);
                    self.tbl_unconfirmed = false;
                    return;
                }
                // 回滚:暂定表头其实是普通行。
                const header = self.tbl_rows.items[0];
                self.emitAssistantLine(header, true);
                self.resetTableLocked();
                // 继续把本行当普通行处理(可能又是新表头)。
            } else {
                // 已确认表格:含 pipe 非空行续入,否则块结束。
                const trimmed = std.mem.trim(u8, line, " \t\r");
                if (trimmed.len > 0 and md_render.lineHasPipe(line)) {
                    self.appendTableRow(line);
                    return;
                }
                self.flushTableBlock();
                // 落本行(普通处理)。
            }
        }

        // 非 code-block 且非表格中 且行含 pipe → 暂定表头。
        if (!self.md_state.in_code_block and !self.in_table and md_render.lineHasPipe(line)) {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len > 0) {
                self.appendTableRow(line);
                self.in_table = true;
                self.tbl_unconfirmed = true;
                return;
            }
        }

        self.emitAssistantLine(line, true);
    }

    /// 把一行原始文本 dup 进 tbl_rows;OOM 兜底直接 emit 并清表格态。
    fn appendTableRow(self: *RenderRegion, line: []const u8) void {
        const dup = self.allocator.dupe(u8, line) catch {
            self.emitAssistantLine(line, true);
            return;
        };
        self.tbl_rows.append(self.allocator, dup) catch {
            self.allocator.free(dup);
            self.emitAssistantLine(line, true);
        };
    }

    /// flush 表格块:确认的渲框线整块 emit;未确认的各行 verbatim;空则 noop。
    fn flushTableBlock(self: *RenderRegion) void {
        const md_render = @import("../render.zig");
        if (self.tbl_rows.items.len == 0) {
            self.resetTableLocked();
            return;
        }
        if (self.tbl_unconfirmed) {
            for (self.tbl_rows.items) |r| self.emitAssistantLine(r, true);
            self.resetTableLocked();
            return;
        }
        const avail: usize = if (self.cols > 2) self.cols - 2 else 0;
        if (avail == 0) {
            for (self.tbl_rows.items) |r| self.emitAssistantLine(r, true);
            self.resetTableLocked();
            return;
        }
        const tbl = md_render.renderTable(self.tbl_rows.items, avail, self.allocator) catch {
            for (self.tbl_rows.items) |r| self.emitAssistantLine(r, true);
            self.resetTableLocked();
            return;
        };
        defer self.allocator.free(tbl);
        self.emitTableBlock(tbl);
        self.resetTableLocked();
    }

    /// 把渲好的多行框表 emit 进 scrollback:首物理行用段前缀(⏺/续行),其余全 2 空格。
    /// 整块一次 emitToScroll(含 \n 安全,见 emitToScroll/updatePendingTail)。
    fn emitTableBlock(self: *RenderRegion, tbl: []const u8) void {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);
        var first = true;
        var it = std.mem.splitScalar(u8, tbl, '\n');
        while (it.next()) |pline| {
            if (first) {
                self.appendAssistantPrefix(&buf, self.md_at_segment_start);
                self.md_at_segment_start = false;
                first = false;
            } else {
                buf.appendSlice(self.allocator, "  ") catch {};
            }
            buf.appendSlice(self.allocator, pline) catch {};
            buf.append(self.allocator, '\n') catch {};
        }
        self.emitToScroll(buf.items);
    }

    /// flush 助手文本残行(stream_done / leaveGenerating)。public:持锁。
    pub fn flushGenAssistant(self: *RenderRegion) void {
        self.lock();
        defer self.unlock();
        self.flushGenAssistantLocked();
    }

    /// flush 助手文本残行(内部,调用方已持锁)。
    fn flushGenAssistantLocked(self: *RenderRegion) void {
        // 先 flush 待定表格块(确认的渲框线;未确认/不完整的 verbatim)。
        if (self.in_table) self.flushTableBlock();
        if (self.md_buf.items.len == 0) return;
        // 残行可能本身是表格头(pipe 行无后续分隔)→ handleAssistantLine 暂存,再 flush。
        self.handleAssistantLine(self.md_buf.items);
        if (self.in_table) self.flushTableBlock();
        self.md_buf.clearRetainingCapacity();
    }

    /// 渲染一行助手文本(markdown + 前缀)到 scrollback。with_nl=true 行尾加 \n。
    /// 长行按终端宽 SGR-aware 软折 + 悬挂缩进(对齐 cc:续行缩进 2 列对齐 `⏺ ` 后内容,不回第 0 列)。
    fn emitAssistantLine(self: *RenderRegion, line: []const u8, with_nl: bool) void {
        const md_render = @import("../render.zig");
        // 先把 markdown 渲染到临时 buf(不含前缀),再 SGR-aware 软折到带前缀/缩进的输出。
        var rendered: std.ArrayList(u8) = .empty;
        defer rendered.deinit(self.allocator);
        md_render.renderLineStreaming(line, &self.md_state, &rendered, self.allocator, self.theme.syntax) catch {
            rendered.clearRetainingCapacity();
            rendered.appendSlice(self.allocator, line) catch {};
        };

        const seg_start = self.md_at_segment_start;
        self.md_at_segment_start = false;

        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.allocator);
        // 前缀:段首行 `⏺ `(accent),续行(逻辑续行 + 软折)`  `(2 空格,对齐 cc)。
        const prefix_w: usize = 2; // `⏺ ` 与 `  ` 同显示宽 = 2
        const avail: usize = if (self.cols > prefix_w + 4) self.cols - prefix_w else 0; // 0 = 不折
        self.appendAssistantPrefix(&buf, seg_start);
        if (avail == 0) {
            buf.appendSlice(self.allocator, rendered.items) catch {};
        } else {
            // SGR-aware 软折:转义序列原子零宽,可见字符按显示宽累计;到 avail 换行 + 2 空格缩进。
            var vis_w: usize = 0;
            var i: usize = 0;
            const s = rendered.items;
            while (i < s.len) {
                if (s[i] == 0x1b) {
                    const esc_end = scanEscape(s, i);
                    buf.appendSlice(self.allocator, s[i..esc_end]) catch {};
                    i = esc_end;
                    continue;
                }
                const cp_len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
                const end = @min(i + cp_len, s.len);
                const cw = term.displayWidth(s[i..end]);
                if (vis_w + cw > avail and vis_w > 0) {
                    // 软折:换行 + 2 空格悬挂缩进,重置可见宽。
                    buf.append(self.allocator, '\n') catch {};
                    buf.appendSlice(self.allocator, "  ") catch {};
                    vis_w = 0;
                }
                buf.appendSlice(self.allocator, s[i..end]) catch {};
                vis_w += cw;
                i = end;
            }
        }
        if (with_nl) buf.append(self.allocator, '\n') catch {};
        self.emitToScroll(buf.items);
    }

    /// 助手行前缀:段首 `⏺ `(accent),续行 `  `(2 空格)。
    fn appendAssistantPrefix(self: *RenderRegion, buf: *std.ArrayList(u8), seg_start: bool) void {
        if (seg_start) {
            buf.appendSlice(self.allocator, self.theme.accent) catch {};
            buf.appendSlice(self.allocator, self.theme.icon_act) catch {};
            buf.appendSlice(self.allocator, self.theme.reset) catch {};
            buf.append(self.allocator, ' ') catch {};
        } else {
            buf.appendSlice(self.allocator, "  ") catch {};
        }
    }

    /// 从 s[i]=ESC 起扫完整转义序列,返回其后第一个字节索引(原子透传用)。
    /// CSI(`\x1b[...字母`)到字母结尾;OSC/其它两字节 ESC 序列吃 2 字节兜底。
    fn scanEscape(s: []const u8, i: usize) usize {
        var j = i + 1;
        if (j < s.len and s[j] == '[') {
            j += 1;
            while (j < s.len and !std.ascii.isAlphabetic(s[j])) : (j += 1) {}
            if (j < s.len) j += 1; // 含结尾字母
            return j;
        }
        return @min(i + 2, s.len); // 两字节转义兜底
    }

    /// 实际把一段文本输出到 scrollback:擦区(若在)→ print → 若刚才区在屏则重画区。
    /// print 仅在 region_drawn==false 时发生(eraseRegion 后),draw/erase 成对、续接点用画区快照还原。
    fn emitToScroll(self: *RenderRegion, text: []const u8) void {
        if (text.len == 0) return;
        const was_drawn = self.region_drawn;
        // 区在屏时:擦区 + 文本流入 scrollback + 重画区 三步包成一帧(DEC 2026 同步输出),
        // 否则 Windows 会先呈现"擦掉区的空白"再刷文本再刷区 → 输入框闪。区不在屏时纯输出文本。
        const w = &self.scratch.writer;
        self.resetScratch();
        if (was_drawn) {
            w.writeAll(ansi.sync.begin) catch {};
            self.frame_active = true;
            self.eraseRegion(); // frame 内:不 reset 不 flush,续接 scratch
        }
        w.writeAll(text) catch {}; // 文本直接流入 scrollback
        self.updatePendingTail(text);
        if (was_drawn) {
            if (self.gen_app) |a| self.drawGenRegion(a); // frame 内:不 reset 不 flush
            self.frame_active = false;
            w.writeAll(ansi.sync.end) catch {};
        }
        self.flush(); // 整帧(或纯文本)一次性呈现
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
        if (!self.frame_active) self.resetScratch(); // 帧内:接续 frame 已写的 sync_begin,勿清
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
        if (!self.frame_active) self.flush(); // 帧内:由外层 frame 统一 flush(原子帧)
        self.region_drawn = false;
    }

    /// 画生成期固定区(spinner + 队列预览 + 上框 + ❯editor(多行) + 下框 + footer),文本流末尾下方。
    /// 前置 region_drawn=false;后置 region_drawn=true,**光标停在 editor 编辑点**(供 IME 候选窗对齐),
    /// 并记 cursor_in_region_row(距区顶行数)供 eraseRegion 回顶。半行文本尾先 \n 封口让区独占整行。
    fn drawGenRegion(self: *RenderRegion, app: *const app_mod.App) void {
        self.measureSize();
        const w = &self.scratch.writer;
        if (!self.frame_active) self.resetScratch(); // 帧内:接续 frame(sync_begin + erase),勿清
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
        // 区重画自清:此刻光标在区顶行首,且在已提交文本**下方**(上面 \r/\n 已让过半行文本)。
        // 从这里 `ESC[0J` 清到屏末,吃掉区**下方**的任何陈旧尾行(工具卡完成/队列变化致区收缩遗留),
        // **单一机制**取代旧的 per-shrink 尾行擦除。只清光标下方,绝不碰上方 scrollback、不滚动、
        // 不清 scrollback(区别于禁用的 ESC[2J),offline 区已干净 → 无副作用。
        // (注:曾试图用它修 Warp 的 alt-screen `?1049l` footer 残影,但真机诊断证明那是 Warp 渲染 bug,
        //  ESC[0J 治不了——见 commit message 的根因诊断;此处保留仅因它是正确的区收缩自清单一机制。)
        w.writeAll(ansi.clear.to_end_of_screen) catch {};

        const inner_w: usize = self.innerWidth();
        const border_color = self.borderColor(app.permMode());
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

        // -- issue #16 model picker(生成期也可用:改选择只影响下一轮)--
        if (self.ui.picker_open) {
            R += model_picker_view.render(&app.model_picker, w, self.theme, self.cols);
        }

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

        // Agent switcher(区域2):footer 下方,占额外行(生成期 `↓ to manage` 进入)。
        R += self.drawAgentSwitcher(w, app);

        // 光标在 footer 行末 = 区最后一行(第 R-1 行)。区下方的陈旧尾行已由开头的 ESC[0J 清净
        // (单一机制),不再需要旧的 per-shrink 尾行擦除。

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
        if (!self.frame_active) self.flush(); // 帧内:由外层 frame 统一 flush(原子帧)
    }

    /// 生成期 transcript 模态帧(对应输入期 renderOverlayInner,但记 cursor_in_region_row 而非
    /// input_cursor_row——生成期 eraseRegion 读前者)。调用前 drawGenRegion 已 hide+封口,
    /// 最多 MAX 条,超出补一行 ` +N more`。
    /// 执行中 per-toolUse 进度卡(动态区,可刷新):⏺ <Tool> / ⎿ <progress>。对齐 cc 双段卡。
    /// 随每次 tickSpinner 重画。card 是某张 tool_cards 条目。
    fn drawToolProgressCard(self: *RenderRegion, w: *std.Io.Writer, card: *const ui_state_mod.ToolCardState) u16 {
        const th = self.theme;
        const tool_card = @import("widget/tool_card.zig");
        const inner_w: usize = if (self.cols > 8) self.cols - 8 else 30;
        const name = card.name[0..card.name_len];
        const is_live = tool_card.usesLiveCard(name);
        var rows: u16 = 0;

        // 第 1 行:⏺ <标题>。WebSearch → displayName(旧);类A → 自然语言进行时(Running 1 shell command…)。
        w.writeAll(ansi.clear.line) catch {};
        if (is_live) {
            const title = tool_card.toolRunningTitle(self.allocator, name, card.inputSlice()) catch null;
            defer if (title) |t| self.allocator.free(t);
            w.print("{s}{s}{s} {s}", .{ th.accent, th.icon_act, th.reset, title orelse tool_card.displayName(name) }) catch {};
        } else {
            w.print("{s}{s}{s} {s}", .{ th.accent, th.icon_act, th.reset, tool_card.displayName(name) }) catch {};
        }
        rows += 1;
        w.writeAll("\r\n") catch {};

        // 第 2 行:⎿ <内容>。WebSearch → progress(Found N…)/「Searching…」占位;
        // 类A → 输入预览($ cmd / 📄 path / /pat/),与完成态一致(只标题变)。
        w.writeAll(ansi.clear.line) catch {};
        w.print("  {s}{s}{s} ", .{ th.dim, th.gutter, th.reset }) catch {};
        if (is_live) {
            const preview = tool_card.toolPreviewPub(self.allocator, name, card.inputSlice()) catch null;
            defer if (preview) |p| self.allocator.free(p);
            writeTruncatedWidth(w, preview orelse "", inner_w);
        } else {
            const prog: []const u8 = if (card.progress_len > 0)
                card.progress[0..card.progress_len]
            else
                "Searching…";
            writeTruncatedWidth(w, prog, inner_w);
        }
        w.writeAll(th.reset) catch {};
        rows += 1;
        w.writeAll("\r\n") catch {};
        return rows;
    }

    fn drawQueuePreview(self: *RenderRegion, w: *std.Io.Writer) u16 {
        const q = self.gen_queue orelse return 0;
        const MAX = 3;
        // 持锁画:agent_loop 线程会在 turn 边界 popFront 并释放字节(#115),借用的 slice 只在
        // 守卫期间有效;总数与展示条数也来自同一份视图,不再出现"+1 more"的瞬时错位。
        const held = q.hold();
        defer held.release();
        const items = held.items();
        const total = items.len;
        if (total == 0) return 0;
        const shown = @min(total, MAX);
        var rows: u16 = 0;
        const th = self.theme;
        const inner_w: usize = if (self.cols > 6) self.cols - 6 else 30;
        var i: usize = 0;
        while (i < shown) : (i += 1) {
            w.writeAll(ansi.clear.line) catch {};
            // 取首行(\n 前)+ 按 inner_w 截断(显示宽)。
            const msg = items[i];
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
    pub fn addToolCard(self: *RegionWriter, id: []const u8, name: []const u8, input_json: []const u8, start_ms: i64) void {
        self.region.addToolCard(id, name, input_json, start_ms);
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

/// shell 模式判定(对齐 cc DIFF#3):buffer 以 `!` 开头 → shell 模式。
/// 与 loop.zig 提交期 `!cmd` 执行路径一致(同一 sigil),输入期只改 UI 表达。
fn isShellMode(content: []const u8) bool {
    return content.len > 0 and content[0] == '!';
}

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
    return if (n <= s.len - i) n else 1;
}

fn displayWidth(s: []const u8) usize {
    return term.displayWidth(s);
}

/// 数 output_buf 的行数(\n 分隔;末行无 \n 也计 1)。空 buf = 0 行。
/// agent viewing 视口滚动几何用(max_top = max(0, total - view_rows))。
fn countOutputLines(buf: []const u8) usize {
    if (buf.len == 0) return 0;
    var n: usize = 0;
    var pos: usize = 0;
    while (pos < buf.len) {
        const eol = std.mem.indexOfScalarPos(u8, buf, pos, '\n') orelse {
            n += 1; // 末行无 \n
            break;
        };
        n += 1;
        pos = eol + 1;
        if (pos == buf.len) break; // 末尾恰好 \n,不算额外空行
    }
    return n;
}

/// 画 output_buf 的窗口 [top, top+view_rows):每行前 ESC[2K + 截断到 cols + \r\n。
/// 返回实际画的行数(≤ view_rows;buf 行不够则少画)。agent viewing 主区视口用。
/// 纯渲染(无 self),便于单测。dim 包裹(subagent 对话区视觉弱化,对齐 cc viewing)。
fn drawOutputWindow(w: *std.Io.Writer, buf: []const u8, top: usize, view_rows: u16, cols: usize, th: Theme) u16 {
    if (view_rows == 0) return 0;
    const max_w: usize = if (cols > 2) cols - 1 else 40;
    var line_idx: usize = 0;
    var pos: usize = 0;
    var drawn: u16 = 0;
    while (pos <= buf.len and drawn < view_rows) {
        const eol = std.mem.indexOfScalarPos(u8, buf, pos, '\n') orelse buf.len;
        if (line_idx >= top) {
            w.writeAll(ansi.clear.line) catch {};
            w.writeAll(th.dim) catch {};
            writeTruncatedWidth(w, buf[pos..eol], max_w);
            w.writeAll(th.reset) catch {};
            w.writeAll("\r\n") catch {};
            drawn += 1;
        }
        line_idx += 1;
        if (eol >= buf.len) break;
        pos = eol + 1;
    }
    return drawn;
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

fn capabilityChips(provider: types.ProviderKind, model: []const u8, buf: []u8) []const u8 {
    var len: usize = 0;
    appendCapabilityChip(buf, &len, provider, model, .extended_thinking, "think");
    appendCapabilityChip(buf, &len, provider, model, .structured_output, "json");
    appendCapabilityChip(buf, &len, provider, model, .web_search, "web");
    appendCapabilityChip(buf, &len, provider, model, .prompt_cache, "cache");
    appendCapabilityChip(buf, &len, provider, model, .server_tool, "tool");
    return if (len == 0) "basic" else buf[0..len];
}

fn appendCapabilityChip(
    buf: []u8,
    len: *usize,
    provider: types.ProviderKind,
    model: []const u8,
    cap: model_command.Capability,
    label: []const u8,
) void {
    if (!model_command.supports(provider, model, cap)) return;
    const sep: []const u8 = if (len.* == 0) "" else ",";
    if (len.* + sep.len + label.len > buf.len) return;
    @memcpy(buf[len.*..][0..sep.len], sep);
    len.* += sep.len;
    @memcpy(buf[len.*..][0..label.len], label);
    len.* += label.len;
}

fn reasoningOptions(mask: u8, buf: *[5]types.ReasoningEffort) []const types.ReasoningEffort {
    const catalog = @import("../../api/catalog.zig");
    const ordered = [_]types.ReasoningEffort{ .low, .medium, .high, .xhigh };
    buf[0] = .none;
    var n: usize = 1;
    for (ordered) |effort| {
        if ((mask & catalog.reasoningBit(effort)) != 0) {
            buf[n] = effort;
            n += 1;
        }
    }
    return buf[0..n];
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
    r.addToolCard("id_a", "WebSearch", "{\"query\":\"alpha\"}", 100);
    r.addToolCard("id_b", "WebSearch", "{\"query\":\"beta\"}", 200);
    try std.testing.expectEqual(@as(u8, 2), r.ui.tools.cards_len);

    // 各写各的 progress,不互盖。
    r.setToolProgress("id_a", "Searching: alpha");
    r.setToolProgress("id_b", "Searching: beta");
    const ia = ui_state_mod.findCard(&r.ui, "id_a").?;
    const ib = ui_state_mod.findCard(&r.ui, "id_b").?;
    try std.testing.expectEqualStrings("Searching: alpha", r.ui.tools.cards[ia].progressSlice());
    try std.testing.expectEqualStrings("Searching: beta", r.ui.tools.cards[ib].progressSlice());

    // 重复 addToolCard 同 id 不新增。
    r.addToolCard("id_a", "WebSearch", "{\"query\":\"alpha\"}", 300);
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

test "countOutputLines:空/单行/多行/末尾换行" {
    try std.testing.expectEqual(@as(usize, 0), countOutputLines(""));
    try std.testing.expectEqual(@as(usize, 1), countOutputLines("abc")); // 无 \n
    try std.testing.expectEqual(@as(usize, 2), countOutputLines("a\nb"));
    try std.testing.expectEqual(@as(usize, 2), countOutputLines("a\nb\n")); // 末尾 \n 不算空行
    try std.testing.expectEqual(@as(usize, 3), countOutputLines("a\nb\nc"));
}

test "drawOutputWindow:窗口切片 + 截断 + 行数" {
    const a = std.testing.allocator;
    const buf = "line0\nline1\nline2\nline3";
    // top=1, view_rows=2 → 画 line1, line2。
    var aw: std.Io.Writer.Allocating = .init(a);
    defer aw.deinit();
    const n = drawOutputWindow(&aw.writer, buf, 1, 2, 80, theme_mod.dark);
    try std.testing.expectEqual(@as(u16, 2), n);
    const out = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, out, "line1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "line2") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "line0") == null); // top 之上不画
    try std.testing.expect(std.mem.indexOf(u8, out, "line3") == null); // 超 view_rows 不画
    // 行不够:top=3,view_rows=5 → 只剩 line3 一行。
    var aw2: std.Io.Writer.Allocating = .init(a);
    defer aw2.deinit();
    try std.testing.expectEqual(@as(u16, 1), drawOutputWindow(&aw2.writer, buf, 3, 5, 80, theme_mod.dark));
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

test "offsetForVisualPos:精确列" {
    const view = "aaa\nbb\ncccc";
    var vl = VisualLines.init();
    RenderRegion.layoutInput(view, &vl, 80); // 3 逻辑行
    // 目标 vline=0, goal=2 → "aa|a" offset 2
    try std.testing.expectEqual(@as(usize, 2), RenderRegion.offsetForVisualPos(view, &vl, 0, 2));
}

test "offsetForVisualPos:goal 超行宽 clamp 到行尾" {
    const view = "aaa\nbb\ncccc";
    var vl = VisualLines.init();
    RenderRegion.layoutInput(view, &vl, 80);
    // vline=1 是 "bb"(seg 4..6),goal=99 → clamp 到 seg.end=6(\n 前=行尾)
    try std.testing.expectEqual(@as(usize, 6), RenderRegion.offsetForVisualPos(view, &vl, 1, 99));
}

test "offsetForVisualPos:软折段落点(可视行非逻辑行)" {
    // 24 个 a,inner_w=10 → avail=7 → 软折成多段。
    const view = "a" ** 24;
    var vl = VisualLines.init();
    RenderRegion.layoutInput(view, &vl, 10);
    try std.testing.expect(vl.count >= 2);
    // 第 2 可视行 goal=5 → 该段 start + 5
    const seg1 = vl.slices[1];
    try std.testing.expectEqual(seg1.start + 5, RenderRegion.offsetForVisualPos(view, &vl, 1, 5));
}

test "offsetForVisualPos:UTF-8 不落 mid-char" {
    const view = "你好世界"; // 每字 3 字节,显示宽 2
    var vl = VisualLines.init();
    RenderRegion.layoutInput(view, &vl, 80);
    // goal=3(落在「好」中间显示列):约定取左缘 >= goal 的首字符 → 「世」起点 offset 6
    const off = RenderRegion.offsetForVisualPos(view, &vl, 0, 3);
    try std.testing.expectEqual(@as(usize, 0), off % 3); // 恒为字符边界(3 倍数)
    try std.testing.expectEqual(@as(usize, 6), off);
}

test "offsetForVisualPos:空 vlines 返 0" {
    const view = "";
    var vl = VisualLines.init();
    RenderRegion.layoutInput(view, &vl, 80); // push 一个空段 0..0
    try std.testing.expectEqual(@as(usize, 0), RenderRegion.offsetForVisualPos(view, &vl, 0, 5));
}

test "tryVerticalMove:多行竖移 + 边界回退 + goal 保持" {
    var r = RenderRegion.init(std.testing.allocator, 2, theme_mod.select(.monochrome, .none), .none);
    defer r.deinit();
    r.cols = 80; // 宽够,3 逻辑行各成一可视行
    const view = "aaa\nbb\ncccc"; // seg: aaa(0..3) bb(4..6) cccc(7..11)

    // 末行尾(cursor=11)up → 落 bb 行,goal=4(cccc 末列)clamp 到 bb 行尾(offset 6)
    const up1 = r.tryVerticalMove(view, 11, null, false);
    try std.testing.expect(up1.moved);
    try std.testing.expectEqual(@as(usize, 6), up1.cursor); // bb 行尾(\n 前)
    try std.testing.expectEqual(@as(usize, 4), up1.goal_vcol); // goal=cccc 末列 4

    // 继续 up(带 goal=4)→ 落 aaa 行,clamp 到 aaa 尾(offset 3)
    const up2 = r.tryVerticalMove(view, up1.cursor, up1.goal_vcol, false);
    try std.testing.expect(up2.moved);
    try std.testing.expectEqual(@as(usize, 3), up2.cursor); // aaa 行尾
    try std.testing.expectEqual(@as(usize, 4), up2.goal_vcol); // goal 不变

    // 首行 up → moved=false(回退历史)
    const up3 = r.tryVerticalMove(view, up2.cursor, up2.goal_vcol, false);
    try std.testing.expect(!up3.moved);

    // 末行 down → moved=false
    const down_end = r.tryVerticalMove(view, 11, null, true);
    try std.testing.expect(!down_end.moved);

    // 中间行 down:从 bb 行尾(6)down → cccc 行 clamp goal=2 → offset 7+2=9
    const down1 = r.tryVerticalMove(view, 6, 2, true);
    try std.testing.expect(down1.moved);
    try std.testing.expectEqual(@as(usize, 9), down1.cursor);
}

test "tryVerticalMove:软折单行 up 落软折续行(可视行非逻辑行)" {
    var r = RenderRegion.init(std.testing.allocator, 2, theme_mod.select(.monochrome, .none), .none);
    defer r.deinit();
    r.cols = 11; // inner_w=10 → avail=7 → 长行软折
    // 24 个 a(软折多段)+ \n + short:光标在 short 尾,up 应落到 a 的最后一个软折段
    const view = "a" ** 24 ++ "\nshort";
    const cursor = view.len; // short 尾
    const up1 = r.tryVerticalMove(view, cursor, null, false);
    try std.testing.expect(up1.moved);
    // 落点必须落在 a 行的【最后一个软折段】(21..24)内,即软折续行而非逻辑行首(0),
    // 证明竖移按可视行(软折段)而非逻辑行。goal=width("short")=5 > 3 → clamp 到段尾 24。
    try std.testing.expect(up1.cursor >= 21 and up1.cursor <= 24);
}
