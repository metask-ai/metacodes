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
const ui_backend = @import("../../core/protocol/ui_backend.zig");
const ui_event = @import("../../core/protocol/ui_event.zig");
const msg_queue = @import("../msg_queue.zig");
const abort = @import("../../util/abort.zig");
const util_time = @import("../../util/time.zig");
const api_stream = @import("../../api/stream.zig");
const tool_card = @import("widget/tool_card.zig");
const theme_mod = @import("theme.zig");
const input = @import("../input.zig");
const app_mod = @import("../../app.zig");
const transcript_viewer = @import("../transcript_viewer.zig");
const term = @import("term.zig");
const ask_dialog = @import("dialog/ask_question.zig");
const perm_dialog = @import("dialog/permission.zig");
const exit_plan_dialog = @import("dialog/exit_plan_mode.zig");
const tool_ctx = @import("../../tools/context.zig");
const ui_request = @import("../../core/protocol/ui_request.zig");

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
    /// Edit/Write diff 的 tree-sitter 高亮缓存(loop.zig 注入 &app.edit_hl_cache)。
    edit_hl_cache: ?*@import("../../core/edit_hl_cache.zig").EditHlCache = null,
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
    input_app: ?*app_mod.App = null,
    input_alloc: ?std.mem.Allocator = null,
    /// 写入端的 AbortSignal(watcher esc 调 .abort)。与只读的 abort_signal 同一对象。
    input_abort: ?*abort.AbortSignal = null,
    /// 线程停止标志 + 句柄。
    input_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    input_thread: ?std.Thread = null,

    /// 本轮 spinner 是否已喂工具(从 tool_start 自决喂第一个普通工具;clear_current_tool 重置)。
    /// agent_loop 不再预算"喂哪个工具"——backend 据 tool_card 分类自决,层泄漏修复。
    spinner_fed: bool = false,

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
                // backend 据 tool_card 分类自决渲染(层泄漏修复:agent_loop 无条件发,不碰 tool_card)。
                if (tool_card.usesDynamicCard(s.name)) {
                    // WebSearch(progress 卡)+ 类A(Bash/Read/Grep/Glob,执行期动态卡):
                    // 整张卡活在动态区。存 input 供动态卡第二行 `$ cmd` 预览。
                    self.region.addToolCard(s.id, s.name, s.input, util_time.nowMs());
                    // 类A 仍喂底部 spinner(卡 + spinner 并存,对齐 cc);WebSearch 不喂(沿用旧)。
                    if (tool_card.usesLiveCard(s.name) and !self.spinner_fed) {
                        self.region.setCurrentTool(s.name, util_time.nowMs());
                        self.spinner_fed = true;
                    }
                } else if (tool_card.showStartCard(s.name)) {
                    if (self.verbose) {
                        var buf: [256]u8 = undefined;
                        const v = std.fmt.bufPrint(&buf, "\n\x1b[35m[Tool: {s}]\x1b[0m", .{s.name}) catch null;
                        if (v) |line| self.region.writeGenText(line);
                    }
                    // 滚动历史起始卡(renderStart)。
                    self.renderCardStart(s.name, s.input);
                    // 本轮第一个普通工具喂底部 spinner(取代旧 agent_loop 预算的 set_current_tool)。
                    if (!self.spinner_fed) {
                        self.region.setCurrentTool(s.name, util_time.nowMs());
                        self.spinner_fed = true;
                    }
                }
                // showStartCard=false(AskUserQuestion/plan/Skill)→ 跳过(走专门 UI)。
            },
            .set_current_tool => |s| self.region.setCurrentTool(s.name, util_time.nowMs()),
            .tool_progress => |p| self.region.setToolProgress(p.id, p.text),
            .clear_current_tool => {
                self.region.clearCurrentTool();
                self.spinner_fed = false; // 本轮结束,重置喂 spinner 标志。
            },
            .tool_result => |r| {
                // backend 自决三分支:
                //  ① 类A(usesLiveCard):commit 动态卡进 scrollback(过去式标题)。
                //     agent_loop 对每工具发两次 tool_result(:632 空 content / :668 真 content)——
                //     只认 content.len>0(:668)做 commit,:632 空事件 no-op,防双 commit。
                //  ② WebSearch(hasProgressCard):完成只移除动态卡(结果走助手文本)。
                //  ③ 其余(类B 等):renderResult 写 scrollback(不变)。
                if (tool_card.usesLiveCard(r.name)) {
                    if (r.content.len > 0) self.commitToolCard(r);
                } else if (tool_card.hasProgressCard(r.name)) {
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

    /// 结果卡 RenderOpts(cols + verbose)。抽成 helper 便于回归测试:
    /// cols 必须来自 region(漏传=0 → diff 背景块不 padEnd → 右缘参差,非矩形)。
    fn cardResultOpts(self: *const TuiBackend) tool_card.RenderOpts {
        return self.cardResultOptsFor("");
    }

    /// 带 tool_id 的 RenderOpts(Edit/Write diff 高亮按 tool_id 查缓存)。
    fn cardResultOptsFor(self: *const TuiBackend, tool_id: []const u8) tool_card.RenderOpts {
        return .{
            .cols = self.region.cols,
            .verbose = self.verbose,
            .edit_hl_cache = self.edit_hl_cache,
            .tool_id = tool_id,
        };
    }

    /// 渲染结果卡到滚动历史(tool_card.renderResult)。需 theme+alloc;缺则跳过。
    fn renderCardResult(self: *TuiBackend, r: anytype) void {
        const th = self.theme orelse return;
        const a = self.alloc orelse return;
        const kind: tool_card.ResultKind = if (r.is_error) .err else .ok;
        const card = tool_card.renderResult(a, th.*, r.name, r.input, r.content, kind, r.elapsed_ms, self.cardResultOptsFor(r.id)) catch return;
        defer a.free(card);
        self.region.writeGenText(card); // 空串(hidden 成功结果) → writeGenText no-op
    }

    /// 类A 工具完成:把动态卡 commit 进 scrollback(过去式标题 + ⎿ 输入预览)。
    /// **先 clearToolCard 从动态区移除,再 writeGenText 写 scrollback**——writeGenText→emitToScroll
    /// 内部 erase→print→redraw,此时卡已不在动态区,故无残影/重影,无需新原子操作。
    fn commitToolCard(self: *TuiBackend, r: anytype) void {
        const th = self.theme orelse return;
        const a = self.alloc orelse return;
        const kind: tool_card.ResultKind = if (r.is_error) .err else .ok;
        const card = tool_card.renderLiveDone(a, th.*, r.name, r.input, r.content, kind, r.elapsed_ms, .{ .cols = self.region.cols }) catch return;
        defer a.free(card);
        self.region.clearToolCard(r.id); // 先移除动态卡
        self.region.writeGenText(card); // 再 commit 进 scrollback
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
    pub fn startInput(self: *TuiBackend, fd: std.c.fd_t, app: *app_mod.App, allocator: std.mem.Allocator) !void {
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

    /// 统一的终端接管骨架(三套 UI 请求曾各写一遍,现合一)。
    /// 顺序铁律:① stopInput(主线程接管 fd0,此刻不持锁)② enterExclusiveOverlay(持渲染锁+擦固定区)
    /// ③ 调 body(独占 fd0 跑对话框,绝不碰 region 渲染方法——非递归 mutex 自死锁)
    /// ④ defer exitExclusiveOverlay(重画固定区+退锁)+ startInput(重启 watcher)。
    /// body 收到 fd(stdin)+ theme + allocator,返回 R。非 tty/无 app → 返回 null(调用方兜底)。
    fn withTerminalTakeover(
        self: *TuiBackend,
        comptime R: type,
        body: *const fn (fd: std.c.fd_t, th: Theme, a: std.mem.Allocator) R,
    ) ?R {
        const fd = self.input_fd;
        if (!term.isatty(fd)) return null;
        const app = self.input_app orelse return null;
        const th = if (self.theme) |t| t.* else theme_mod.dark;
        const a = self.input_alloc orelse return null;

        self.stopInput();
        self.region.enterExclusiveOverlay();
        defer {
            self.region.exitExclusiveOverlay(app);
            self.startInput(fd, app, a) catch {};
        }
        return body(fd, th, a);
    }

    /// 统一 UI 请求入口:按 req tag 分派到对应对话框(终端接管共享)。
    /// 替代旧 askQuestion/promptPermission/exitPlanPrompt 三套独立实现。
    /// 非 tty / 无 app → 安全默认(plan→reject;permission→deny_once;ask→error.NotATty)。
    fn handleUiRequest(
        self: *TuiBackend,
        allocator: std.mem.Allocator,
        req: *const ui_request.UiRequest,
        out: *ui_request.UiResponse,
    ) anyerror!void {
        switch (req.*) {
            .ask_question => |questions| {
                // ask_question 的 answers 挂调用方传入的 allocator;不能用 withTerminalTakeover
                // 的固定签名(它传 self.input_alloc),故就地展开同款接管骨架。
                const fd = self.input_fd;
                if (!term.isatty(fd)) return error.NotATty;
                const app = self.input_app orelse return error.NotATty;
                const th = if (self.theme) |t| t.* else theme_mod.dark;
                self.stopInput();
                self.region.enterExclusiveOverlay();
                defer {
                    self.region.exitExclusiveOverlay(app);
                    if (self.input_alloc) |a| self.startInput(fd, app, a) catch {};
                }
                var answers: std.ArrayList([]const u8) = .empty;
                errdefer {
                    for (answers.items) |it| allocator.free(@constCast(it));
                    answers.deinit(allocator);
                }
                try ask_dialog.run(allocator, th, fd, questions, &answers, self.region.cols);
                out.* = .{ .answers = try answers.toOwnedSlice(allocator) };
            },
            .permission => |p| {
                const Ctx = struct {
                    threadlocal var tool: []const u8 = "";
                    threadlocal var args: []const u8 = "";
                    fn run(fd: std.c.fd_t, th: Theme, a: std.mem.Allocator) perm_dialog.PermissionChoice {
                        return perm_dialog.promptLoop(a, th, fd, 2, tool, args) orelse .deny_once;
                    }
                };
                Ctx.tool = p.tool;
                Ctx.args = p.args;
                const choice = self.withTerminalTakeover(perm_dialog.PermissionChoice, &Ctx.run) orelse .deny_once;
                out.* = .{ .permission = choice };
            },
            .plan_approval => |pa| {
                const Ctx = struct {
                    threadlocal var plan_md: []const u8 = "";
                    fn run(fd: std.c.fd_t, th: Theme, a: std.mem.Allocator) tool_ctx.ToolContext.PlanApproval {
                        return exit_plan_dialog.run(a, th, fd, 2, plan_md) orelse .reject;
                    }
                };
                Ctx.plan_md = pa.plan_md;
                const choice = self.withTerminalTakeover(tool_ctx.ToolContext.PlanApproval, &Ctx.run) orelse .reject;
                out.* = .{ .plan_approval = choice };
            },
        }
    }

    /// trampoline:ToolContext.ui_request_fn 的 *anyopaque state → *TuiBackend。
    pub fn uiRequestTrampoline(
        state: *anyopaque,
        allocator: std.mem.Allocator,
        req: *const ui_request.UiRequest,
        out: *ui_request.UiResponse,
    ) anyerror!void {
        const self: *TuiBackend = @ptrCast(@alignCast(state));
        return self.handleUiRequest(allocator, req, out);
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
    ///
    /// 统一分流:所有键先走 applyGenKey→dispatch(复用输入期 `?`/help/Ctrl+O/transcript 滚动
    /// 全部语义)。watcher 据返回 Effect:
    ///   · action != .pass_to_editor → dispatch 已消费(开关 help/overlay/滚动),内部已重画,不动 editor;
    ///   · action == .pass_to_editor → dispatch 未消费,按键类型决定生成期独有语义:
    ///       - enter 系 → 入待发送队列 + clear(dispatch 无"入队"概念,故落 pass_to_editor 由此接);
    ///       - esc     → 无弹层,中断推理(入队已打的字 + abort);
    ///       - 其余     → 普通编辑键喂 LineEditor。
    /// 关键:enter/esc 也经 dispatch 先过一遍 → overlay/help 开着时它们被 dispatch 路由消费
    /// (transcript 期 enter 被 dispatchTranscriptKey 忽略,不会误入队;help 期 esc 只关 help)。
    /// esc 优先级:overlay 开→关 overlay;help 开→关 help;都关→中断(先关弹层再中断)。
    fn handleKey(self: *TuiBackend, key: input.Key, ed: *input.LineEditor) void {
        const app = self.input_app orelse return;
        const eff = self.region.applyGenKey(app, &app.conversation, key, ed.view(), ed.cursor);

        // dispatch 上抛的全局 LoopAction:生成期能执行的(两期共享:cycle_perm_mode/redraw_screen/
        // kill_background)在此处理,IO 体属生成期调用方。dispatch 已 gate 掉生成期无意义的键
        // (history/complete/reverse_search/external_edit → action=.none,不会到这)。
        switch (eff.action) {
            .pass_to_editor => {}, // 落下面 key switch(生成期编辑/入队/中断)
            .cycle_perm_mode => {
                app.cyclePermMode();
                self.region.redrawGen(app);
                return;
            },
            .redraw_screen => {
                std.debug.print("\x1b[2J\x1b[H", .{});
                self.region.redrawGen(app);
                return;
            },
            .kill_background => {
                _ = app.killAllBackground();
                self.region.redrawGen(app);
                return;
            },
            .open_transcript => {
                // 生成期 Ctrl+O → alt-screen 全屏 transcript viewer。enterExclusiveOverlay 持渲染锁
                // (emit 线程阻塞在锁上不抢 stdout)+ 擦生成期固定区;viewer 进/出 alt-screen(主屏
                // 被冻结保存、退出自动恢复);exitExclusiveOverlay 锁内重画固定区 + 释放锁。
                const a = self.input_alloc orelse return;
                const sz = term.getSize(self.input_fd);
                const rows: usize = if (sz) |s| s.rows else 24;
                const th = if (self.theme) |t| t.* else theme_mod.dark;
                self.region.enterExclusiveOverlay();
                transcript_viewer.runWithTheme(self.input_fd, a, &app.conversation, rows, th) catch {};
                self.region.exitExclusiveOverlay(app);
                return;
            },
            // 其余(none/help/overlay/滚动/生成期被吞的键)→ dispatch/applyGenKey 已消费,不动 editor。
            else => return,
        }

        // 走到这:dispatch 未消费该键(pass_to_editor,无弹层激活)。按键类型决定生成期语义。
        switch (key) {
            .enter, .shift_enter, .ctrl_enter => {
                // 回车 → 入待发送队列(非空才入)+ clear。不立即发。
                const v = ed.view();
                const trimmed = std.mem.trim(u8, v, " \t\r\n");
                if (trimmed.len > 0) {
                    if (self.queue) |qq| _ = qq.push(v);
                }
                ed.clear();
                self.region.setGenInput(ed.view(), ed.cursor);
                self.region.redrawGen(app);
                return;
            },
            .esc => {
                // 无弹层的 esc → 中断推理。框里已打的字先入队(不丢,中断后自动续发),再 abort。
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
                // 普通编辑键 → 喂 LineEditor,重画生成区输入框。
                _ = ed.handle(key) catch {};
                self.region.setGenInput(ed.view(), ed.cursor);
                self.region.redrawGen(app);
            },
        }
    }
};

test {
    std.testing.refAllDecls(@This());
    // 显式收录子模块 test(refAllDecls 非递归):ask_question dialog 的 render/joinChecked 单测。
    _ = ask_dialog;
    _ = exit_plan_dialog; // ExitPlanMode 审批对话框 render/键映射单测
}

test "tool_result(Edit): renderCardResult 用 region.cols(回归:diff 矩形填充)" {
    // 回归:renderCardResult 曾用 `.{}`(cols=0),appendDiffLine 跳过行尾填充 → 背景块
    // 右缘参差(非矩形)。修复后 opts.cols 取自 region.cols → diff 行 padEnd 到列宽成矩形。
    const a = std.testing.allocator;
    // RenderRegion 写 fd=2(std.debug.print),无法经 fd 捕获;故验"opts 携带 region.cols"
    // 这一接线点(真正的 bug 在此),叠加 tool_card 已有的"cols→padEnd 矩形"单测,端到端闭合。
    var region = RenderRegion.init(a, 2, theme_mod.monochrome, .none);
    defer region.deinit();
    region.cols = 123; // 哨兵宽
    var backend = TuiBackend.init(&region);
    backend.verbose = true;

    const opts = backend.cardResultOpts();
    try std.testing.expectEqual(@as(u16, 123), opts.cols); // cols 必须从 region 流入(非 0)
    try std.testing.expectEqual(true, opts.verbose);
}
