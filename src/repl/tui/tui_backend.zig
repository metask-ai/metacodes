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
const SessionId = ui_backend.SessionId;

/// watcher 线程注入态(fd/app/alloc)的持锁聚合。**严格 leaf lock**:
/// - mutex 只罩这三个标量字段的读写,临界区内**绝不**调任何会阻塞/IO/取 RenderRegion 锁的函数;
/// - mutex **绝不**跨 poll/read/handleKey/tickSpinner/enterExclusiveOverlay/viewer/join 持有;
/// - 与 RenderRegion 锁(R)永不嵌套(I 先取先放,再单独取 R)→ 无锁序倒置、无死锁。
/// 读者(watcher / 主线程接管前)统一 `snapshot()` 拷出栈局部后立即放锁,后续全用局部(对齐 L1
/// "syscall 参数先快照")。详见 TuiBackend.input_ctx 字段上的并发不变量 + 半截真相注释。
const InputCtx = struct {
    mutex: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,
    fd: std.c.fd_t = 0,
    app: ?*app_mod.App = null,
    alloc: ?std.mem.Allocator = null,

    const Snapshot = struct { fd: std.c.fd_t, app: ?*app_mod.App, alloc: ?std.mem.Allocator };

    /// 持锁拷出三字段到栈,立即放锁返回。leaf-lock:调用方拿到 Snapshot 后才做 IO/取 R 锁。
    fn snapshot(self: *InputCtx) Snapshot {
        _ = std.c.pthread_mutex_lock(&self.mutex);
        defer _ = std.c.pthread_mutex_unlock(&self.mutex);
        return .{ .fd = self.fd, .app = self.app, .alloc = self.alloc };
    }

    /// 持锁写三字段(startInput 注入)。
    fn set(self: *InputCtx, fd: std.c.fd_t, app: *app_mod.App, alloc: std.mem.Allocator) void {
        _ = std.c.pthread_mutex_lock(&self.mutex);
        defer _ = std.c.pthread_mutex_unlock(&self.mutex);
        self.fd = fd;
        self.app = app;
        self.alloc = alloc;
    }
};

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
    /// usage 累加目标(L1:usage 走 CoreEvent.usage 总线;TuiBackend 累加进 app.usage)。
    /// 指向 &app.usage(core UsageTotals)。null = 不累加(测试/无 App)。
    usage_acc: ?*@import("../../core/usage.zig").UsageTotals = null,
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
    /// 输入线程的 fd / app / allocator(startInput 注入)。收进 InputCtx 持锁访问。
    ///
    /// **并发不变量(当前)**:三字段仅 `startInput` 写,而 `startInput` 仅在 watcher 不存活时调
    /// (初始 / `stopInput` join 之后)→ watcher 存活期 lifetime-immutable,初值经 spawn 的 release
    /// happens-before 对 watcher 可见。今天**无 live data race**。
    ///
    /// `input_ctx.mutex`(I 锁)罩这三字段的读写。今天它真正消除的并发读是**主线程接管前的读**
    /// (`withTerminalTakeover`/`handleUiRequest` 在 `stopInput` 之前 snapshot,此刻 watcher 仍存活
    /// →真并发);watcher 侧入口 snapshot 一次后字段对它 immutable(见 watcherMain),I 锁对 watcher
    /// 而言与 spawn release 等效,取之仅为统一纪律。
    ///
    /// **⚠ 半截真相(多 session 落地前必读)**:I 锁只能保护**指针发布**(谁读到的是完整、最新的 `app`
    /// 指针)。它**不保护指针指向的 App 的 lifetime**——若未来某线程在 watcher 存活期把 `app` 换走 /
    /// 析构旧 App,watcher 仍在 `tickSpinner(app)` / `app.conversation` 解引用旧 App = use-after-free,
    /// 这把锁救不了。且 watcher 现在入口只 snapshot 一次,mid-life swap 它根本看不见(这是有意的:swap 的
    /// lifetime 半边没解,看见反而危险)。真正安全的 app-swap 必须保证"旧 App 活过所有在飞 watcher 解引用"
    /// (refcount,或 stop-swap-restart——后者正是 stopInput/startInput 已提供的)。多 session 真做 swap
    /// 时,连 lifetime 带 publication + 是否每轮重读一并设计,别只看这把锁。
    input_ctx: InputCtx = .{},
    /// 写入端的 AbortSignal(watcher esc 调 .abort)。与只读的 abort_signal 同一对象。
    input_abort: ?*abort.AbortSignal = null,
    /// 线程停止标志 + 句柄。**故意留在 InputCtx 外**:input_stop 是 watcher 循环条件(不能为读它而取
    /// I 锁,会无谓扩大临界区);input_thread 仅主线程 start 写 / stop 读清(无 watcher 读)。
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

    // TuiBackend 是 N=1(单全屏终端),忽略 session——所有事件都归这一个会话视图。
    // GUI 多视图 backend 才需按 session 分流(M6+)。
    fn emitThunk(ctx: *anyopaque, _: SessionId, ev: CoreEvent) void {
        const self: *TuiBackend = @ptrCast(@alignCast(ctx));
        self.emitImpl(ev);
    }

    fn pollThunk(ctx: *anyopaque, _: SessionId) ?UiEvent {
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
                if (self.usage_acc) |acc| acc.apply(u);
            },
            // L1:轮/工具级进度事件——顶层 TUI 进度走 spinner + set_current_tool,不消费 .progress
            // (它是 subagent 进度树用,由 JobEntry 后端消费)。顶层 no-op。
            .progress => {},
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
            .context_warning => |w| {
                var buf: [256]u8 = undefined;
                const s = std.fmt.bufPrint(
                    &buf,
                    "\x1b[33m[context warning: {d}/{d} tokens, auto-compact at {d}, blocking at {d}]\x1b[0m\n",
                    .{ w.current_tokens, w.warning_threshold, w.auto_compact_threshold, w.blocking_limit },
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
                // 结束助手文本行(幂等):半行补 \n,已在行首 no-op。
                // 旧版无条件 writeGenText("\n") 在文本已以 \n 结尾时多吐空行 → 多批次 tool 卡间冒空行。
                self.region.endScrollLine();
            },
            .ui_request_pending => {
                // TUI 是同步前端(走阻塞 requestUi,恒 .answered,从不挂起)→ 此事件不会发给它,no-op。
            },
            // L4 诊断事件:DiagnosticsBackend 专属(经 TeeBackend 旁挂),TUI 不渲染,no-op。
            .diag_turn_begin, .diag_turn_end, .diag_breaker_tripped, .diag_cache_break, .diag_continuation, .diag_run_end => {},
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
        // 护栏:start 前必须已 stop+join 上一个 watcher。**debug-only 安全网**——release 里 assert 蒸发,
        // 不是不变量的真正强制者(真正强制靠 input_thread 这个 optional 的存在性 + 调用纪律)。多 session
        // 若要硬保证,得让 start 在 input_thread!=null 时返回 error 或先内部 stop(Linus #3 认知项)。
        std.debug.assert(self.input_thread == null);
        self.input_ctx.set(fd, app, allocator); // 持 I 锁写;spawn 的 release 另给初值可见性
        self.input_stop.store(false, .release);
        self.input_thread = try std.Thread.spawn(.{}, watcherMain, .{self});
    }

    /// 停止并 join 输入线程(loop.zig 在 agent_loop.run 返回后调,成功/错误路径都要)。
    pub fn stopInput(self: *TuiBackend) void {
        if (self.input_thread) |t| {
            self.input_stop.store(true, .release);
            t.join(); // **绝不持 I 锁跨 join**:否则与阻塞在 I.snapshot 的 watcher 死锁
            self.input_thread = null;
            // 不 clear 三字段:join 后无 watcher 读,stale 值无害(下次 startInput 覆写)。曾加 clear 为
            // 保"字段只在 I 内变"审美,反给 join 后的 self 读刨 null 窗口(ask_question defer 重启被迫绕)
            // → 自找复杂度,删之(Linus #1)。
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
        // 此读在 stopInput(join watcher)**之前** → 与存活 watcher 真并发,必须经 I 锁 snapshot。
        const snap = self.input_ctx.snapshot();
        const fd = snap.fd;
        if (!term.isatty(fd)) return null;
        const app = snap.app orelse return null;
        const th = if (self.theme) |t| t.* else theme_mod.dark;
        const a = snap.alloc orelse return null;

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
                // 的固定签名(它传 input_ctx.alloc),故就地展开同款接管骨架。
                // 读在 stopInput 之前 → 与存活 watcher 真并发,经 I 锁 snapshot;defer 重启沿用 snap(已拷出)。
                const snap = self.input_ctx.snapshot();
                const fd = snap.fd;
                if (!term.isatty(fd)) return error.NotATty;
                const app = snap.app orelse return error.NotATty;
                const th = if (self.theme) |t| t.* else theme_mod.dark;
                self.stopInput();
                self.region.enterExclusiveOverlay();
                defer {
                    self.region.exitExclusiveOverlay(app);
                    if (snap.alloc) |a| self.startInput(fd, app, a) catch {};
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
            .custom => {
                // L2:同步终端 backend 无法渲染任意动态 UI(它只会画固定对话框)。custom 信封
                // 是给未来 GUI/web 后端的——TUI 返 error,工具据此兜底(对齐 ask→NotATty)。
                // 真正的 custom 渲染走异步前端(L3 挂起路径)或带 UI runtime 的 backend。
                return error.CustomUiUnsupported;
            },
        }
    }

    /// trampoline:ToolContext.ui_request_fn 的 *anyopaque state → *TuiBackend。
    pub fn uiRequestTrampoline(
        state: *anyopaque,
        _: SessionId, // TUI N=1:单终端,忽略 session(GUI 多视图 backend 才据它路由)
        allocator: std.mem.Allocator,
        req: *const ui_request.UiRequest,
        out: *ui_request.UiResponse,
    ) anyerror!ui_request.RequestOutcome {
        const self: *TuiBackend = @ptrCast(@alignCast(state));
        try self.handleUiRequest(allocator, req, out);
        // TUI 同步前端:对话框已阻塞收到响应,out 已写 → 恒 .answered(从不挂起)。
        return .answered;
    }

    /// 生成期 stdin 监听主循环(从旧 loop.zig stdinAbortWatcher 原样搬入)。
    /// 行为不变:回车→入队(queue);esc→已打字先入队再 abort(直戳 AbortSignal);
    /// 超时→孤立 ESC 兑现 or tickSpinner。AbortSignal 机制完全不动。
    fn watcherMain(self: *TuiBackend) void {
        // 入口快照一次:三字段在 watcher 生命周期内 immutable(仅 startInput 写,且仅在无 watcher 时调
        // ——见 input_ctx 注释)。故入口经 I 锁拷出 (fd, app, alloc) 即够,无需每轮重读(那是为"未来
        // mid-life swap"加的 speculative 热路径锁,但 swap 的 lifetime 半边本就没解,半截能力不值热路径
        // 开销 → 退回入口一次,Linus #2)。多 session 真做 swap 时连 lifetime 带 publication 一并设计。
        const snap = self.input_ctx.snapshot();
        const app = snap.app orelse return;
        const fd = snap.fd;
        const allocator = snap.alloc orelse return;
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
                    self.handleKey(snap, k, &editor);
                } else {
                    self.region.tickSpinner(app);
                }
                continue;
            }
            if ((pfd[0].revents & std.c.POLL.IN) == 0) continue;

            var b: [1]u8 = undefined;
            const n = std.c.read(fd, &b, 1);
            if (n <= 0) continue;

            const key = parser.feed(b[0]) orelse continue; // 多字节(UTF-8/CSI)攒够再出 Key
            self.handleKey(snap, key, &editor);
            // ESC + 普通字符:feed 吐 .esc 后第二个键在 pending,排空(否则字符被吞)。
            while (parser.drain()) |k2| self.handleKey(snap, k2, &editor);
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
    fn handleKey(self: *TuiBackend, snap: InputCtx.Snapshot, key: input.Key, ed: *input.LineEditor) void {
        const app = snap.app orelse return;
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
            .background_main => {
                // Ctrl+B 生成期:置位转后台请求信号。agent_loop 在下个 turn 边界 load 到 → 返回
                // .backgrounded;loop.zig 据此深拷贝 conversation 转后台 + reset 前台。watcher 这里
                // 只 store 信号(对齐 esc 直戳 abort),不碰 conversation/IO(那是主线程 run 返回后的事)。
                app.background_request.store(true, .release);
                return;
            },
            .open_transcript => {
                // Ctrl+O 去抖:按住("不断 Ctrl+O")的 auto-repeat 连发会高频 toggle alt-screen,
                // 真终端(Warp)跟不上 → footer 多行堆叠 + 退出后框不幂等。抑制紧随的 reopen,
                // 使按住一次只产生一对 open/close(单次 toggle 干净路径)。见 RenderRegion.noteCtrloAndShouldSuppressReopen。
                if (self.region.noteCtrloAndShouldSuppressReopen()) return;
                // 生成期 Ctrl+O → 全屏 transcript viewer(alt-screen,2026-06-13 根治多 agent"显两份")。
                // enterExclusiveOverlay 持渲染锁(emit 线程阻塞在锁上、不抢 stdout);viewer 自己进/出
                // alt-screen 独立缓冲(ESC[?1049h/l)全屏画 transcript,退出由终端**自动恢复主缓冲**;
                // exitExclusiveOverlay 锁内 drawGenRegion 在恢复后的主缓冲上从锚定行重画固定区 + 释放锁。
                const a = snap.alloc orelse return;
                const sz = term.getSize(snap.fd);
                const rows: usize = if (sz) |s| s.rows else 24;
                const th = if (self.theme) |t| t.* else theme_mod.dark;
                self.region.enterExclusiveOverlay();
                // anchor_hint:DEAD since 2026-06-13 alt-screen 切换 —— viewer 已 `_ = anchor_hint;` 丢弃
                // (独立缓冲全屏绝对定位,不需区顶 anchor)。此调用 + overlayAnchorHint/overlay_region_height
                // 整条链路现为死代码,保留仅为遵守"其他保持不变"scope;后续清理时一并删。
                const anchor_hint = self.region.overlayAnchorHint(rows);
                transcript_viewer.runWithThemeAnchor(snap.fd, a, &app.conversation, rows, anchor_hint, th) catch {};
                self.region.exitExclusiveOverlay(app);
                return;
            },
            // 其余(none/help/overlay/滚动/生成期被吞的键)→ dispatch/applyGenKey 已消费,不动 editor。
            else => return,
        }

        // 走到这:dispatch 未消费该键(pass_to_editor,无弹层激活)。按键类型决定生成期语义。
        switch (key) {
            .enter, .shift_enter => {
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
            // Ctrl+Enter:真 cc 实测无效键(不换行/不提交)→ 生成期同样 no-op,不入队不重画。
            .ctrl_enter => return,
            .esc => {
                // 无弹层的 esc → 中断推理。框里已打的字先入队(不丢,中断后自动续发),再 abort。
                const v = ed.view();
                const trimmed = std.mem.trim(u8, v, " \t\r\n");
                if (trimmed.len > 0) {
                    if (self.queue) |qq| _ = qq.push(v);
                }
                ed.clear();
                if (self.input_abort) |ab| ab.abort(.user_ctrl_c);
                // 多 agent:esc 还要 abort 所有 running agent job——前台 Task 的 subagent 走 app.abort
                // 已被打断,但**后台/嵌套** agent job 持自己的 entry.abort,app.abort 不触达,否则 esc 后
                // 它们继续跑(用户实测 bug:启动多 agent 后 esc 不终止)。非阻塞 abort,不 join。
                if (app.agent_jobs) |*reg| {
                    _ = reg.abortAllRunning();
                }
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
