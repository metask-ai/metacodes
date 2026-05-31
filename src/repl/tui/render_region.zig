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
    spinner_frame: u8 = 0,
    verb: []const u8 = "",
    gen_start_ms: i64 = 0,
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

    mutex: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,

    fn lock(self: *RenderRegion) void {
        _ = std.c.pthread_mutex_lock(&self.mutex);
    }
    fn unlock(self: *RenderRegion) void {
        _ = std.c.pthread_mutex_unlock(&self.mutex);
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
        self.scratch.deinit();
        self.line_buf.deinit(self.allocator);
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

        // -- footer --
        w.writeAll(ansi.clear.line) catch {};
        self.drawFooter(w, app);
        new_rows += 1;

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

        // 4. 光标移到内容行(区内行号:上边框(1) + loc.vline)。
        const loc = RenderRegion.locateCursor(content, cursor, &vlines);
        const target_row: u16 = 1 + @as(u16, @intCast(loc.vline));
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
        return switch (mode) {
            .plan => self.theme.warn,
            else => self.theme.accent,
        };
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

    /// footer:左 "? for shortcuts · shift+tab to cycle (mode)" 右 "{tok} tokens",dim。
    fn drawFooter(self: *RenderRegion, w: *std.Io.Writer, app: *const app_mod.App) void {
        const th = self.theme;
        const mode_str = @import("widget/status_bar.zig").modeName(app.config.permission_mode);
        var left_buf: [160]u8 = undefined;
        const left = std.fmt.bufPrint(&left_buf, " ? for shortcuts · shift+tab to cycle ({s})", .{mode_str}) catch " ? for shortcuts";

        const u = app.usage;
        const total = u.input_tokens + u.output_tokens;
        var tok_buf: [16]u8 = undefined;
        const tok_str = @import("widget/status_bar.zig").formatTokens(&tok_buf, total);
        var right_buf: [48]u8 = undefined;
        const right = std.fmt.bufPrint(&right_buf, "{s} tokens ", .{tok_str}) catch "";

        const left_w = displayWidth(left);
        const right_w = displayWidth(right);
        w.writeAll(th.dim) catch {};
        w.writeAll(left) catch {};
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
        self.renderInner(app);
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
        self.spinner_frame = 0;
        self.region_drawn = false; // 区不在屏:首个 tick 才画区
        self.prev_rows = 0; // 生成期 prev_rows = 上次 drawGenRegion 画的 R(eraseRegion 用)
        self.cursor_in_region_row = 0;
        self.gen_start_ms = util_time.nowMs();
        self.verb = verbs.pick(@intCast(util_time.nowMs() & 0xffff));
        self.text_pending_newline = false;
        self.pending_col = 0;
    }

    /// 离开生成期:擦掉固定区(若在)+ 补半行换行 + 收尾。不再返回 carryover
    /// (待发送队列由主循环消费,见 loop.zig)。
    pub fn leaveGenerating(self: *RenderRegion, app: *const app_mod.App) void {
        _ = app;
        self.lock();
        defer self.unlock();
        self.flushLineBuf(); // 先把行缓冲残行(无尾随 \n 的末行)输出,别丢
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
        self.spinner_frame +%= 1;
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

        const inner_w: usize = if (self.cols > 4) self.cols - 1 else 40;
        const border_color = self.borderColor(app.config.permission_mode);
        const content = self.gen_view;

        var vlines = VisualLines.init();
        layoutInput(content, &vlines, inner_w);

        var R: u16 = 0;

        // -- spinner 行 --
        w.writeAll(ansi.clear.line) catch {};
        const elapsed: u64 = @intCast(@max(util_time.nowMs() - self.gen_start_ms, 0));
        _ = StatusBar.renderGenerating(w, app, self.theme, self.use_unicode, self.spinner_frame, self.verb, elapsed, inner_w) catch {};
        R += 1;
        w.writeAll("\r\n") catch {};

        // -- 待发送队列预览(每条 dim 灰,最多 3 条 + "+N more")--
        R += self.drawQueuePreview(w);

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

        // -- footer(末行不 \r\n)--
        w.writeAll(ansi.clear.line) catch {};
        self.drawFooter(w, app);
        R += 1;

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

    /// 画待发送队列预览(spinner 与上边框之间,每条 dim 灰 ` ⏳ <msg 首行,截断>`)。返回行数。
    /// 最多 MAX 条,超出补一行 ` +N more`。
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
