//! TuiBackend:把 UiBackend vtable 接到现有 RenderRegion。
//!
//! 阶段 B 定位:agent_loop 只发语义 CoreEvent,**所有表达(ANSI 颜色 + 工具卡渲染)
//! 在此 backend 完成**。TuiBackend 持 theme+alloc,emit(.tool_start/.tool_result) 内部
//! 调 tool_card.renderStart/renderResult 渲染到 scrollback;颜色括号由 stream_begin/
//! stream_done 决定。字节序与旧 agent_loop 直 print 逐字节一致(pty 测试守)。
//!
//! emit 映射(CoreEvent → RenderRegion/tool_card):
//!   .stream_begin       → colorize ? writeGenText("\x1b[32m")
//!   .text_chunk         → region.writeGenText(纯文本)
//!   .tool_start{card=t} → region.addToolCard(WebSearch 进度卡)
//!   .tool_start{card=f} → [verbose] + tool_card.renderStart → writeGenText
//!   .set_current_tool   → region.setCurrentTool(spinner 喂)
//!   .tool_progress      → region.setToolProgress
//!   .clear_current_tool → region.clearCurrentTool
//!   .tool_result{card=t}→ region.clearToolCard
//!   .tool_result{card=f}→ tool_card.renderResult → writeGenText
//!   .usage              → 累加进 usage_acc(主路径置 null,走 usage_sink)
//!   .phase_change       → no-op(enter/leaveGenerating 由 loop 编排)
//!   .auto_compact       → writeGenText(格式化提示行)
//!   .retry_notice       → [门控] writeGenText("Retrying in Ns…")
//!   .stream_done        → writeGenText(colorize ? "\x1b[0m\n" : "\n")
//!
//! poll 映射(UiEvent ← MsgQueue/AbortSignal):
//!   AbortSignal.isAborted() → .interrupt(reason)
//!   MsgQueue.popFront()     → .queue_message(所有权转移给 poll 调用方,须 free)
//! 优先返回 interrupt(打断比入队紧急)。
//!
//! emit 同步消费 borrow slice:RenderRegion 方法内部立即拷进定长卡/写 scrollback;
//! 卡渲染用 alloc(堆),渲染完即 free,TuiBackend 不持有跨调用。

const std = @import("std");
const render_region = @import("render_region.zig");
const ui_backend = @import("../ui_backend.zig");
const ui_event = @import("../ui_event.zig");
const msg_queue = @import("../msg_queue.zig");
const abort = @import("../../util/abort.zig");
const util_time = @import("../../util/time.zig");
const api_stream = @import("../../api/stream.zig");
const tool_card = @import("widget/tool_card.zig");
const theme_mod = @import("theme.zig");
const input = @import("../input.zig");
const app_mod = @import("../../app.zig");

const RenderRegion = render_region.RenderRegion;
const Theme = theme_mod.Theme;
const CoreEvent = ui_event.CoreEvent;
const UiEvent = ui_event.UiEvent;
const UiBackend = ui_backend.UiBackend;

pub const TuiBackend = struct {
    region: *RenderRegion,
    /// 工具卡渲染所需(renderStart/renderResult)。null → 卡渲染跳过(等价无 theme)。
    theme: ?*const Theme = null,
    alloc: ?std.mem.Allocator = null,
    /// 颜色括号(stream_begin/stream_done)+ retry 着色。
    colorize: bool = false,
    /// verbose:tool_start 前打 `[Tool: name]` 行(对齐旧 agent_loop:387)。
    verbose: bool = false,
    /// retry 提示是否显示(前台 agent_depth==0 才 true;门控见 .retry_notice)。
    show_retry: bool = false,
    /// usage 累加目标(可选)。主路径置 null,usage 走 opts.usage_sink 避免双计。
    usage_acc: ?*api_stream.UsageDelta = null,
    /// poll 输入源(可选)。
    queue: ?*msg_queue.MsgQueue = null,
    abort_signal: ?*const abort.AbortSignal = null,

    // ── 生成期输入子系统(阶段 C:watcher 归属 backend)──────────────────────
    // 旧 loop.zig 硬编码的 stdinAbortWatcher 线程移到这里。TuiBackend owns 键盘输入:
    // 生成期边等边打字 / 回车入队(queue) / esc 中断(直戳 AbortSignal)/ 超时 tickSpinner。
    // AbortSignal 机制不变(SIGINT handler 仍直戳;stream.next 仍 throwIfAborted)。
    //
    // 阶段 D(定期激活归 UI 后端)由此**一并满足**:spinner tick 在 watcherMain 的 poll
    // 超时分支驱动(单线程 poll-timeout 模式,无需第二个 tick 线程——避免双线程争
    // RenderRegion 锁)。agent_loop 完全不管 tick。GUI/语音后端各自实现 startInput 时
    // 自决动画驱动(GUI=requestAnimationFrame,语音=无 tick),不依赖 stdin poll。
    /// 输入线程的 fd / app / allocator(startInput 注入)。
    input_fd: std.c.fd_t = 0,
    input_app: ?*const app_mod.App = null,
    input_alloc: ?std.mem.Allocator = null,
    /// 写入端的 AbortSignal(watcher esc 调 .abort)。与只读的 abort_signal 同一对象。
    input_abort: ?*abort.AbortSignal = null,
    /// 线程停止标志 + 句柄。
    input_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    input_thread: ?std.Thread = null,

    pub fn init(region: *RenderRegion) TuiBackend {
        return .{ .region = region };
    }

    /// 包成 vtable。返回值持有 *TuiBackend——self 必须比 backend 活得久。
    pub fn backend(self: *TuiBackend) UiBackend {
        return .{
            .ctx = @ptrCast(self),
            .emit = emitThunk,
            .poll = pollThunk,
        };
    }

    fn emitThunk(ctx: *anyopaque, ev: CoreEvent) void {
        const self: *TuiBackend = @ptrCast(@alignCast(ctx));
        self.emitImpl(ev);
    }

    fn pollThunk(ctx: *anyopaque) ?UiEvent {
        const self: *TuiBackend = @ptrCast(@alignCast(ctx));
        return self.pollImpl();
    }

    fn emitImpl(self: *TuiBackend, ev: CoreEvent) void {
        switch (ev) {
            .stream_begin => {
                // 助手文本走 markdown 渲染路径(beginGenAssistant 重置状态 + 标记段首)。
                // markdown 渲染器自带颜色,故不再裹 colorize 绿色括号。
                self.region.beginGenAssistant();
            },
            .text_chunk => |t| self.region.writeGenAssistantText(t),
            .tool_start => |s| {
                if (s.card) {
                    self.region.addToolCard(s.id, s.name, util_time.nowMs());
                } else {
                    // verbose:旧 agent_loop:387 的 `\n\x1b[35m[Tool: name]\x1b[0m`。
                    if (self.verbose) {
                        var buf: [256]u8 = undefined;
                        const v = std.fmt.bufPrint(&buf, "\n\x1b[35m[Tool: {s}]\x1b[0m", .{s.name}) catch null;
                        if (v) |line| self.region.writeGenText(line);
                    }
                    // 滚动历史起始卡(renderStart)。需 theme+alloc。
                    self.renderCardStart(s.name, s.input);
                }
            },
            .set_current_tool => |s| self.region.setCurrentTool(s.name, util_time.nowMs()),
            .tool_progress => |p| self.region.setToolProgress(p.id, p.text),
            .clear_current_tool => self.region.clearCurrentTool(),
            .tool_result => |r| {
                if (r.card) {
                    self.region.clearToolCard(r.id);
                } else {
                    self.renderCardResult(r);
                }
            },
            .usage => |u| {
                if (self.usage_acc) |acc| {
                    acc.input_tokens += u.input_tokens;
                    acc.output_tokens += u.output_tokens;
                    acc.cache_read_input_tokens += u.cache_read_input_tokens;
                    acc.cache_creation_input_tokens += u.cache_creation_input_tokens;
                }
            },
            .phase_change => {
                // enter/leaveGenerating 仍由 loop 编排(需 *App)。此处 no-op。
            },
            .auto_compact => |c| {
                var buf: [256]u8 = undefined;
                const s = std.fmt.bufPrint(
                    &buf,
                    "\x1b[33m[auto-compacted {d} old messages, kept last {d}]\x1b[0m\n",
                    .{ c.dropped, c.kept },
                ) catch return;
                self.region.writeGenText(s);
            },
            .retry_notice => |r| {
                // 门控对齐旧 RetryUi(agent_loop:312-314):仅前台显示、前 3 次隐藏。
                if (!self.show_retry) return;
                if (r.attempt < 3) return;
                const secs = (r.delay_ms + 999) / 1000;
                var buf: [256]u8 = undefined;
                const s = if (self.colorize)
                    std.fmt.bufPrint(&buf, "\x1b[2mRetrying in {d}s… (attempt {d}/{d})\x1b[0m\n", .{ secs, r.attempt, r.max }) catch return
                else
                    std.fmt.bufPrint(&buf, "Retrying in {d}s… (attempt {d}/{d})\n", .{ secs, r.attempt, r.max }) catch return;
                self.region.writeGenText(s);
            },
            .stream_done => {
                // 先 flush 助手文本残行(markdown 渲染),再补段尾换行。
                self.region.flushGenAssistant();
                self.region.writeGenText("\n");
            },
        }
    }

    /// 渲染起始卡到滚动历史(tool_card.renderStart)。需 theme+alloc;缺则跳过。
    fn renderCardStart(self: *TuiBackend, name: []const u8, input_json: []const u8) void {
        const th = self.theme orelse return;
        const a = self.alloc orelse return;
        const card = tool_card.renderStart(a, th.*, name, input_json) catch return;
        defer a.free(card);
        self.region.writeGenText(card); // 空串(hidden) → writeGenText no-op
    }

    /// 渲染结果卡到滚动历史(tool_card.renderResult)。需 theme+alloc;缺则跳过。
    fn renderCardResult(self: *TuiBackend, r: anytype) void {
        const th = self.theme orelse return;
        const a = self.alloc orelse return;
        const kind: tool_card.ResultKind = if (r.is_error) .err else .ok;
        const card = tool_card.renderResult(a, th.*, r.name, r.input, r.content, kind, r.elapsed_ms, .{}) catch return;
        defer a.free(card);
        self.region.writeGenText(card); // 空串(hidden 成功结果) → writeGenText no-op
    }

    fn pollImpl(self: *TuiBackend) ?UiEvent {
        // interrupt 优先于 queue_message(打断更紧急)。
        if (self.abort_signal) |sig| {
            if (sig.isAborted()) return .{ .interrupt = sig.reason() };
        }
        if (self.queue) |q| {
            // popFront 转移所有权 → 调用方须 free(见 ui_event.zig queue_message 注)。
            if (q.popFront()) |msg| return .{ .queue_message = msg };
        }
        return null;
    }

    // ── 生成期输入子系统 ────────────────────────────────────────────────────

    /// 启动生成期键盘监听线程(loop.zig 在 agent_loop.run 前调)。
    /// fd=stdin;app 供 spinner 重画;queue/input_abort 须已在 backend 上设好。
    /// 非 tty / 无 region 时不应调用(loop.zig 已门控)。
    pub fn startInput(self: *TuiBackend, fd: std.c.fd_t, app: *const app_mod.App, allocator: std.mem.Allocator) !void {
        self.input_fd = fd;
        self.input_app = app;
        self.input_alloc = allocator;
        self.input_stop.store(false, .release);
        self.input_thread = try std.Thread.spawn(.{}, watcherMain, .{self});
    }

    /// 停止并 join 输入线程(loop.zig 在 agent_loop.run 返回后调,成功/错误路径都要)。
    pub fn stopInput(self: *TuiBackend) void {
        if (self.input_thread) |t| {
            self.input_stop.store(true, .release);
            t.join();
            self.input_thread = null;
        }
    }

    /// 生成期 stdin 监听主循环(从旧 loop.zig stdinAbortWatcher 原样搬入)。
    /// 行为不变:回车→入队(queue);esc→已打字先入队再 abort(直戳 AbortSignal);
    /// 超时→孤立 ESC 兑现 or tickSpinner。AbortSignal 机制完全不动。
    fn watcherMain(self: *TuiBackend) void {
        const allocator = self.input_alloc orelse return;
        const fd = self.input_fd;
        var parser = input.KeyParser{}; // 本线程独占,不持锁
        var editor = input.LineEditor.init(allocator);
        defer editor.deinit();

        while (!self.input_stop.load(.acquire)) {
            // ESC 待决时用短超时(40ms)→ 孤立 ESC 快速兑现为中断;否则常规 100ms tick。
            const timeout_ms: i32 = if (parser.pendingEsc()) 40 else 100;
            var pfd = [_]std.c.pollfd{.{ .fd = fd, .events = std.c.POLL.IN, .revents = 0 }};
            const rc = std.c.poll(&pfd, 1, timeout_ms);
            if (rc <= 0) {
                // 超时:孤立 ESC 兑现 → 处理(可能中断);否则推进 spinner。
                if (parser.flushEsc()) |k| {
                    self.handleKey(k, &editor);
                } else {
                    self.region.tickSpinner(self.input_app.?);
                }
                continue;
            }
            if ((pfd[0].revents & std.c.POLL.IN) == 0) continue;

            var b: [1]u8 = undefined;
            const n = std.c.read(fd, &b, 1);
            if (n <= 0) continue;

            const key = parser.feed(b[0]) orelse continue; // 多字节(UTF-8/CSI)攒够再出 Key
            self.handleKey(key, &editor);
            // ESC + 普通字符:feed 吐 .esc 后第二个键在 pending,排空(否则字符被吞)。
            while (parser.drain()) |k2| self.handleKey(k2, &editor);
        }
    }

    /// 处理一个已解析出的 Key(feed 出的 or flushEsc 出的孤立 ESC)。
    fn handleKey(self: *TuiBackend, key: input.Key, ed: *input.LineEditor) void {
        switch (key) {
            .enter, .shift_enter, .ctrl_enter => {
                // 回车 → 入待发送队列(非空才入),清空输入框。不立即发。
                const v = ed.view();
                const trimmed = std.mem.trim(u8, v, " \t\r\n");
                if (trimmed.len > 0) {
                    if (self.queue) |qq| _ = qq.push(v);
                }
                ed.clear();
            },
            .esc => {
                // 单 esc 直接中断当前推理(对齐 CC chat:cancel)。框里已打的字先入队
                // (不丢用户输入,中断后自动续发);再 abort(直戳 AbortSignal,机制不变)。
                const v = ed.view();
                const trimmed = std.mem.trim(u8, v, " \t\r\n");
                if (trimmed.len > 0) {
                    if (self.queue) |qq| _ = qq.push(v);
                }
                ed.clear();
                if (self.input_abort) |ab| ab.abort(.user_ctrl_c);
                return; // 中断不重画(主线程很快收尾)
            },
            else => {
                _ = ed.handle(key) catch {};
            },
        }
        if (self.input_app) |a| {
            self.region.setGenInput(ed.view(), ed.cursor);
            self.region.redrawGen(a);
        }
    }
};

test {
    std.testing.refAllDecls(@This());
}
