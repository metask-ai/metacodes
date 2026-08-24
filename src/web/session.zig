//! Web 会话驱动 —— `metacodes --web [port]` 的主循环。
//!
//! 角色对照:repl/loop.zig 的 web 等价物,但**只做编排不做表达**:
//!   等 inbox 消息(POST /message 入队)→ append conversation → agent_loop.run
//!   (WebBackend 做 emit,WebBackend.requester 做 UiRequest)→ persistTranscript
//!   → journal 通告 run_done → 回到等待。
//!
//! 生成期入队的消息天然排队(inbox 是 MsgQueue,线程安全),本轮结束逐条续跑——
//! 对齐 TUI 的 commandQueue 语义,但不需要 watcher 线程:HTTP 线程就是输入线程。
//!
//! 退出:空闲期收到 AbortSignal(终端 Ctrl+C / SIGINT)→ 优雅收尾(close journal →
//! SSE 连接收到 session_closed → stop server)。生成期的 abort 只中断当前 run(对齐 TUI)。
//!
//! 有意不做(MVP 边界,见 doc 结论):slash 命令(/model /compact…)——它们长在
//! repl/loop.zig 里与 TTY 耦合,是"会话编排层未分离"的存量债,不在本次 scope。

const std = @import("std");
const time = @import("../util/time.zig");
const app_mod = @import("../app.zig");
const agent_loop = @import("../core/agent_loop.zig");
const project_activation = @import("../core/project_rule_activation.zig");
const journal_mod = @import("journal.zig");
const backend_mod = @import("backend.zig");
const server_mod = @import("server.zig");
const msg_queue_mod = @import("../repl/msg_queue.zig");
const log = @import("../util/log.zig");

const EventJournal = journal_mod.EventJournal;
const WebBackend = backend_mod.WebBackend;
const WebServer = server_mod.WebServer;
const MsgQueue = msg_queue_mod.MsgQueue;
const ui_event = @import("../core/protocol/ui_event.zig");

/// **U4 A4:web 配置变更 sink**。config 变更(model/mode/dirs/reasoning 任一 UI/工具触发)→
/// journal.append 一条 `{"config_changed":{...}}` → 浏览器 SSE 收到更新状态。与 command_result
/// 分开(config_changed 是状态广播,任何来源都发;command_result 只是命令 ack)。
/// **借用契约**:emit 在 driver 线程同步序列化 ev(含 borrow .model/.dirs)→ journal.append **dup**
/// 进 journal 串,SSE 线程后读的是 dup,borrow 释放安全(dup 发生在 emit 调用内,早于下一次 mutation)。
pub const WebConfigSink = struct { // U10-D:daemon app_driver 复用
    journal: *EventJournal,
    alloc: std.mem.Allocator,
    fn emitThunk(ctx: *anyopaque, ev: ui_event.ConfigChange) void {
        const self: *WebConfigSink = @ptrCast(@alignCast(ctx));
        const line = std.json.Stringify.valueAlloc(self.alloc, .{ .config_changed = ev }, .{}) catch return;
        defer self.alloc.free(line);
        self.journal.append(line); // journal dup → borrow 同步序列化后即可释放
    }
    pub fn sink(self: *WebConfigSink) ui_event.ConfigEventSink { // U10-D 复用
        return .{ .ctx = @ptrCast(self), .emitFn = &emitThunk };
    }
};

/// U5 B2:把一条 session_lifecycle 事件序列化进 journal（进 seq 流，附着重放可见 session 边界）。
/// created 挂 journal init 后（seq 0），closed 挂 journal.close 前。best-effort（OOM 静默丢）。
pub fn journalSessionLifecycle(journal: *EventJournal, alloc: std.mem.Allocator, ev: ui_event.SessionLifecycle) void { // U10-D 复用
    const line = std.json.Stringify.valueAlloc(alloc, .{ .session_lifecycle = ev }, .{}) catch return;
    defer alloc.free(line);
    journal.append(line);
}

/// /state 快照的数据源:driver 拥有,server 经回调读(HTTP 线程)。
const StateSource = struct {
    app: *app_mod.App,
    wb: *WebBackend,
    cmdbox: *MsgQueue, // 斜杠命令队列(HTTP 入队,driver 执行)
    journal: *EventJournal, // U5 B1:快照带 seq(锁内 count())供附着握手
    generating: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// **U5 B1:附着快照**（HTTP 线程调）。核心：
    /// - **seq = journal.count()（锁内，Linus ① 定死）**：语义=下界，客户端订阅 `?since=seq` 严格续接。
    /// - **slice 字段(model/dirs) 经 app.snapshotSlices 锁内 dup 读**：避免撞 driver free 的 UAF(§1.4)。
    /// - 标量(mode/usage/generating)直读(值语义良性 skew)。
    fn snapshot(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
        const self: *StateSource = @ptrCast(@alignCast(ctx));
        const seq = self.journal.count(); // 锁内取（Linus ①：seq 定序 + 跨线程可见性）
        // slice-safe 读（cache mutex 内 dup）：model + dirs。
        const slices = try self.app.snapshotSlices(allocator);
        defer {
            allocator.free(slices.model);
            for (slices.dirs) |d| allocator.free(d);
            allocator.free(slices.dirs);
        }
        // **U6 A4:附着 agent roster**。attach 客户端据此见 attach 前已 spawn 的 agent(之后靠
        // agent_lifecycle SSE 增量)。snapshotJobs **线程安全**(registry mutex 内 dup 值语义),
        // 比 U5 model/dirs 更省心(JobSnapshot 本就是 owned 值拷贝,非裸跨线程 slice)。
        // **task#19 已修**:TaskStore 加 mutex 后,task 列表进快照(下方 snapshotTasks 锁内 dup 读)。
        // attach 客户端由此见 mid-session 已有 task(完整 attach),不再只靠 tasks_changed 增量近似。
        const AgentView = struct {
            id: []const u8,
            agent_type: []const u8,
            state: []const u8,
            turns: u32,
            tool_calls: u32,
            foreground: bool,
        };
        const RegT = @import("../core/agent_job_registry.zig").AgentJobRegistry;
        var job_snaps: []RegT.JobSnapshot = &.{};
        var agent_views: []AgentView = &.{};
        if (self.app.agentJobsPtr()) |reg| {
            job_snaps = reg.snapshotJobs(allocator) catch &.{};
            agent_views = allocator.alloc(AgentView, job_snaps.len) catch &.{};
            for (job_snaps, 0..) |js, i| {
                if (i >= agent_views.len) break; // alloc 失败降级(agent_views 空)
                agent_views[i] = .{
                    .id = js.id,
                    .agent_type = js.agent_type,
                    .state = @tagName(js.status), // JobStatus tagName(静态串)
                    .turns = js.turns,
                    .tool_calls = js.tool_calls,
                    .foreground = js.foreground,
                };
            }
        }
        defer {
            if (agent_views.len > 0) allocator.free(agent_views);
            if (job_snaps.len > 0) RegT.freeSnapshots(allocator, job_snaps);
        }
        // **task#19:附着快照带 task 列表**。TaskStore 加 mutex 后 HTTP 线程可安全读(snapshotTasks
        // 锁内 dup 值语义)。attach 客户端由此见 attach 前 mid-session 已有 task,不再只靠 tasks_changed 增量。
        const TaskView = struct { id: []const u8, subject: []const u8, state: []const u8 };
        const raw_tasks = self.app.tasks.snapshotTasks(allocator) catch &.{};
        defer {
            for (raw_tasks) |t| {
                allocator.free(t.id);
                allocator.free(t.subject);
            }
            if (raw_tasks.len > 0) allocator.free(raw_tasks);
        }
        var task_views: []TaskView = &.{};
        if (raw_tasks.len > 0) task_views = allocator.alloc(TaskView, raw_tasks.len) catch &.{};
        defer if (task_views.len > 0) allocator.free(task_views);
        for (raw_tasks, 0..) |t, i| {
            if (i >= task_views.len) break;
            task_views[i] = .{ .id = t.id, .subject = t.subject, .state = t.status.toString() };
        }

        const plugin_inventory_json = try self.app.describePlugins(allocator);
        defer allocator.free(plugin_inventory_json);
        var plugin_inventory = try std.json.parseFromSlice(
            std.json.Value,
            allocator,
            plugin_inventory_json,
            .{},
        );
        defer plugin_inventory.deinit();

        const u = &self.app.usage; // u64 无锁读，良性 skew（poll-based）
        return std.json.Stringify.valueAlloc(allocator, .{
            .seq = seq,
            .session_id = self.app.session_id.asSlice(),
            .model = slices.model,
            .additional_dirs = slices.dirs,
            .permission_mode = @tagName(self.app.permMode()),
            .input_tokens = u.input_tokens,
            .output_tokens = u.output_tokens,
            .cost_usd = u.costUsd(slices.model),
            .generating = self.generating.load(.acquire),
            .pending_request_id = self.wb.pendingId(),
            .agents = agent_views, // U6 A4:附着 roster
            .tasks = task_views, // task#19:mid-session task 列表进快照
            .plugin_inventory = plugin_inventory.value,
        }, .{});
    }

    /// 斜杠命令入口(HTTP 连接线程调)。**只入队,绝不碰 App**:命令要改 conversation/
    /// config/allocator,而这些非线程安全,唯一安全 toucher 是 driver 线程。commandFn 把
    /// 命令 push 进 cmdbox,driver 在空闲点(它独占 conversation/allocator 时)执行 execCommand,
    /// 结果经 journal command_result 事件异步回浏览器。返回 202 ack。
    ///
    /// **为什么不在 HTTP 线程执行**:generating flag 只保护 agent_loop.run,不保护 driver
    /// 空闲循环里的 appendText/allocator——那些在 flag 窗口外照样改 App。HTTP 线程直接
    /// 改 conversation 会与 driver 的 appendText 并发 mutate 同一 ArrayList(堆损坏)。
    fn command(ctx: *anyopaque, allocator: std.mem.Allocator, cmd: []const u8) anyerror![]u8 {
        const self: *StateSource = @ptrCast(@alignCast(ctx));
        if (!self.cmdbox.push(cmd)) return reply(allocator, false, "command queue full");
        return reply(allocator, true, "queued");
    }
};

/// 命令结果信封 `{"ok":bool,"message":"…"}`(owned)。
fn reply(allocator: std.mem.Allocator, ok: bool, msg: []const u8) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, .{ .ok = ok, .message = msg }, .{});
}

/// driver 线程执行一个命令(独占 conversation/config/app.allocator,无并发)。
/// 结果经 journal `{"command_result":{ok,message}}` 事件发回浏览器(异步)。
///
/// U2 S3:**不再有独立命令实现**——全走共享 SessionService.exec(与 loop.zig 同一命令面)。
/// 旧版手抄的 /mode /compact /model 4 条已废(逐字重复的存量债)。web 由此还白捡了
/// /add-dir /theme /vim + /model 的 provider 守卫(旧 web /model 漏守卫)。
fn execCommand(app: *app_mod.App, journal: *EventJournal, web_alloc: std.mem.Allocator, cmd: []const u8) void {
    const session_service = @import("../session_service.zig");
    const trimmed = std.mem.trim(u8, cmd, " \t\r\n");
    // 拆 verb / args:去前导 `/`,首个空格分界。
    const body = if (std.mem.startsWith(u8, trimmed, "/")) trimmed[1..] else trimmed;
    const sp = std.mem.indexOfScalar(u8, body, ' ');
    const verb = if (sp) |i| body[0..i] else body;
    const args = if (sp) |i| std.mem.trim(u8, body[i + 1 ..], " \t") else "";

    var svc = session_service.SessionService.init(app);
    const outcome = svc.exec(app.allocator, verb, args);
    var buf: [256]u8 = undefined;
    const msg: []const u8 = switch (outcome.kind) {
        .unhandled => std.fmt.bufPrint(&buf, "unknown command: {s}", .{trimmed}) catch "unknown command",
        else => outcome.render(&buf),
    };
    const ok = outcome.ok and outcome.kind != .unhandled;
    const line = std.json.Stringify.valueAlloc(web_alloc, .{ .command_result = .{ .ok = ok, .message = msg } }, .{}) catch return;
    defer web_alloc.free(line);
    journal.append(line);
}

/// **U10-D**:构造 web/daemon session 的 agent_loop.Options(web run() 与 daemon app_driver 共用
/// 一份,消两份漂移)。wb=该 session 的 WebBackend(ui_requester 用);scoped_recall=本轮尾注入召回。
pub fn buildWebOptions(app: *app_mod.App, wb: *WebBackend, scoped_recall: ?[]const u8) agent_loop.Options {
    return .{
        .session = app.session_id,
        .verbose = app.config.verbose,
        .abort = &app.abort,
        .read_state = &app.read_state,
        .edit_hl_cache = &app.edit_hl_cache,
        .jobs = if (app.jobs) |*j| j else null,
        .agent_jobs = if (app.agent_jobs) |*aj| aj else null,
        .plan_prev_mode = &app.plan_prev_mode,
        .tasks = &app.tasks,
        .kg = if (app.kg) |*k| k else null,
        .kg_projects_dir = app.kg_projects_dir,
        .memdir_abs = app.memdir_abs,
        .api_client = app.anthropicClientOrNull(),
        .tool_defs = app.tool_defs,
        .system_prompt = app.system_prompt,
        .inject_user_context = app.user_context,
        .synthetic_user_input = scoped_recall,
        .dyn_registry = &app.dyn_registry,
        .host_services = app.hostServices(),
        .activated_tools = &app.activated_tools,
        .project_dir = app.project_dir_or_empty(),
        .sandbox = app.sandboxPtr(),
        .cwd_abs = app.cwdAbs(),
        .additional_dirs = app.additionalDirs(),
        .home_dir = app.homeDir(),
        .artifact_root = app.sessionDir() orelse "",
        .tool_result_metrics = &app.tool_result_metrics, .file_change_journal = &app.file_change_journal,
        .agents = &app.agents,
        .parent_model = app.activeModel(),
        .model_switch_compact = app.pendingModelSwitchCompact(),
        .skills_set = &app.skills,
        .ui_requester = wb.requester(),
        .mcp_sessions = &app.mcp_sessions.items,
        .cron_registry = &app.cron_registry,
        .plan_file_path = app.plan_file_path,
        .emit_tool_cards = true,
    };
}

/// 跑 web 会话直到退出(空闲期 SIGINT)。返回进程退出码。
pub fn run(app: *app_mod.App, allocator: std.mem.Allocator, port: u16) !u8 {
    // web 侧资源统一 c_allocator:emit/journal/HTTP 连接线程并发分配,必须线程安全
    // (App 的 arena allocator 不是)。生命周期 = 本函数,deinit 成对。
    const web_alloc = std.heap.c_allocator;

    var journal = EventJournal.init(web_alloc);
    defer journal.deinit();
    // U5 B2:session_lifecycle.created 作 journal 第一条(seq 0)——事件流建立点，
    // 任何后来 attach 的客户端(since=0/快照重放)都见 session 边界起点。
    journalSessionLifecycle(&journal, web_alloc, .{ .created = app.session_id.asSlice() });
    var wb = WebBackend.init(web_alloc, &journal);
    defer wb.deinit();
    wb.abort = &app.abort;
    wb.usage_totals = &app.usage; // /state 的 token/cost 数据源(backend 累计,全仓惯例)
    var inbox = MsgQueue.init(web_alloc);
    defer inbox.deinit();
    var cmdbox = MsgQueue.init(web_alloc);
    defer cmdbox.deinit();
    var state_src = StateSource{ .app = app, .wb = &wb, .cmdbox = &cmdbox, .journal = &journal };

    // U4 A4:装配 config 变更 sink(model/mode/dirs/reasoning 变更 → journal → SSE)。
    // setConfigEventSink 同步设 App sink + permission_ctx.event_sink(mode),并 **seed snapshot_cache**。
    // **U5 review MINOR#3:必须在 WebServer.start **之前**装配**——否则 [start, setSink) 窗口内 HTTP
    // 线程 snapshot() 撞 null-cache fallback(直读 app.additionalDirs(),driver 若此刻 mutate 则 UAF)。
    // 提前 seed 关死该窗口:server 起来时 cache 必已就位。defer setConfigEventSink(null) 注册在
    // srv.stop 之前 → LIFO 保证它在 server 停后才清(无 HTTP 线程读已清 sink)。
    var config_sink = WebConfigSink{ .journal = &journal, .alloc = web_alloc };
    app.setConfigEventSink(config_sink.sink());
    defer app.setConfigEventSink(null);

    const srv = try WebServer.start(web_alloc, port, .{
        .journal = &journal,
        .web_backend = &wb,
        .inbox = &inbox,
        .abort = &app.abort,
        // /interrupt 只在生成期放行:空闲期的 abort 是本 driver 的"优雅退出"信号
        // (终端 SIGINT 专属),不能让浏览器 Stop 按钮误杀 daemon。
        .generating = &state_src.generating,
        .state_ctx = @ptrCast(&state_src),
        .state_fn = &StateSource.snapshot,
        .command_fn = &StateSource.command,
    });
    // 关停顺序契约(见 WebServer.stop doc):先 close journal 唤醒 SSE,再 stop。
    defer srv.stop();
    defer journal.close();
    // U5 B2:closed 在 journal.close() **之前** emit(LIFO:此 defer 后注册→先运行)——
    // SSE 客户端在 session_closed 传输帧前先收到 journal 里的 lifecycle.closed 事件。
    defer journalSessionLifecycle(&journal, web_alloc, .{ .closed = app.session_id.asSlice() });

    std.debug.print("metacodes web UI: http://127.0.0.1:{d}  (Ctrl+C to quit)\n", .{srv.port});
    log.info("web", "listening on 127.0.0.1:{d}", .{srv.port});

    // 权限询问也走 web 对话框(prompt.ask 读 permission_ctx.ui_requester)。
    app.permission_ctx.ui_requester = wb.requester();
    defer app.permission_ctx.ui_requester = null;

    const be = wb.backend();
    var exit_code: u8 = 0;

    outer: while (true) {
        // ── 斜杠命令:driver 线程独占执行(唯一 conversation/allocator toucher,无并发)。
        // HTTP 线程只入队(见 StateSource.command);此处执行 → journal command_result。
        while (cmdbox.popFront()) |c| {
            defer web_alloc.free(c);
            execCommand(app, &journal, web_alloc, c);
        }

        // ── 空闲期:等消息 ──────────────────────────────────────────────────
        // abort 二义:user_ctrl_c=真 SIGINT(退出进程)vs user_interrupt=浏览器 Stop
        // (只中断 run)。空闲期若 flag 亮:SIGINT → 退出;残留的 interrupt(门 race 漏进
        // 来的)→ 复位丢弃,继续等。
        const msg = inbox.popFront() orelse {
            if (app.abort.isAborted()) {
                if (app.abort.reason() == .user_ctrl_c) break :outer;
                app.abort.resetForTesting(); // 残留 interrupt,不退出
            }
            time.sleepMs(50);
            continue;
        };
        defer web_alloc.free(msg);

        try app.conversation.appendText(.user, msg);
        state_src.generating.store(true, .release);
        defer state_src.generating.store(false, .release);

        const run_control: ?*project_activation.RunControl = if (app.sessionDir()) |dir|
            project_activation.RunControl.init(
                allocator,
                dir,
                app.session_id,
                if (app.project_dir_or_empty().len > 0) app.project_dir_or_empty() else app.cwdAbs(),
                &app.abort,
            ) catch |err| {
                log.err("web", "run control failed closed: {s}", .{@errorName(err)});
                announceRunDone(&journal, web_alloc, "error", @errorName(err));
                exit_code = 1;
                continue;
            }
        else
            null;
        defer if (run_control) |control| control.deinit();
        if (run_control) |control| control.requireDetachedIdle(
            (if (app.jobs) |*jobs| jobs.runningCount() else 0) +|
                (if (app.agent_jobs) |*jobs| jobs.runningCount() else 0),
            app.swarm.hasTeam(),
        ) catch |err| {
            control.finishRun(@errorName(err)) catch {};
            log.err("web", "project rules rejected detached workers: {s}", .{@errorName(err)});
            announceRunDone(&journal, web_alloc, "error", @errorName(err));
            exit_code = 1;
            continue;
        };

        // scoped 自动召回(对齐 headless.zig:按请求装配相关记忆,cache-safe 尾注入)
        const scoped_recall = if (app.kg) |*k| (@import("../kg/scoped_recall.zig").build(allocator, k, &app.conversation, &app.abort) catch null) else null;
        defer if (scoped_recall) |s| allocator.free(s);

        var options = buildWebOptions(app, &wb, scoped_recall);
        options.tool_observer = if (run_control) |control| control.observer() else null;
        options.execution_boundary = if (run_control) |control| control.executionBoundary() else null;
        options.project_rule_gate = if (run_control) |control| control.formalGate() else null;
        const result = agent_loop.run(
            &app.conversation,
            app.provider(),
            app.tool_defs,
            &app.permission_ctx,
            options,
            &be,
            allocator,
        ) catch |err| {
            if (run_control) |control| control.finishRun(@errorName(err)) catch |finish_err| {
                log.err("web", "run control finish failed: {s}", .{@errorName(finish_err)});
            };
            log.err("web", "agent_loop failed: {s}", .{@errorName(err)});
            announceRunDone(&journal, web_alloc, "error", @errorName(err));
            exit_code = 1;
            continue;
        };
        if (run_control) |control| control.finishRun(@tagName(result.stop_reason)) catch |err| {
            log.err("web", "run control finish failed: {s}", .{@errorName(err)});
            announceRunDone(&journal, web_alloc, "error", @errorName(err));
            exit_code = 1;
            continue;
        };

        app.persistTranscript();
        announceRunDone(&journal, web_alloc, @tagName(result.stop_reason), null);

        // run 因 abort 结束:据 reason 决定退出还是继续(复位供下一轮)。
        // user_ctrl_c=生成期真 SIGINT → 退出;user_interrupt=浏览器 Stop → 继续。
        if (result.stop_reason == .aborted) {
            if (app.abort.reason() == .user_ctrl_c) break :outer;
            app.abort.resetForTesting();
        }
    }

    std.debug.print("\nweb session closed.\n", .{});
    return exit_code;
}

pub fn announceRunDone(journal: *EventJournal, allocator: std.mem.Allocator, stop_reason: []const u8, err_name: ?[]const u8) void { // U10-D 复用
    const line = std.json.Stringify.valueAlloc(allocator, .{
        .run_done = .{ .stop_reason = stop_reason, .err = err_name },
    }, .{}) catch return;
    defer allocator.free(line);
    journal.append(line);
}

test {
    std.testing.refAllDecls(@This());
}

test "U4 A5: web config sink 跨线程留存 dup(emit 后覆写源串,journal 仍旧值不悬挂)" {
    const a = std.testing.allocator;
    var journal = EventJournal.init(a);
    defer journal.deinit();
    var config_sink = WebConfigSink{ .journal = &journal, .alloc = a };
    const sink = config_sink.sink();

    // 可变缓冲当 model 源串(模拟 app.activeModel() 借用会被 switchModel free/覆写)。
    var model_buf: [16]u8 = undefined;
    @memcpy(model_buf[0..7], "model-A");
    sink.emit(.{ .model = model_buf[0..7] });

    // emit 后覆写源串(模拟 switchModel free 旧 model_switch_owned + 指向新串)。
    @memcpy(model_buf[0..7], "ZZZZZZZ");

    // journal 里那条应是 dup 的 "model-A",不是被覆写的 "ZZZZZZZ"(证 dup/序列化在 emit 内)。
    const maybe = try journal.waitSince(a, 0, 0);
    try std.testing.expect(maybe != null);
    const lines = maybe.?;
    defer {
        for (lines) |l| a.free(l);
        a.free(lines);
    }
    try std.testing.expect(lines.len >= 1);
    try std.testing.expect(std.mem.indexOf(u8, lines[0], "model-A") != null);
    try std.testing.expect(std.mem.indexOf(u8, lines[0], "ZZZZZZZ") == null);
    try std.testing.expect(std.mem.indexOf(u8, lines[0], "config_changed") != null);
}

test "U5 B2: session_lifecycle.created 落 journal seq 0；closed 可 journal" {
    const a = std.testing.allocator;
    var journal = EventJournal.init(a);
    defer journal.deinit();

    // created 作第一条 → seq 0。
    journalSessionLifecycle(&journal, a, .{ .created = "abc123session" });
    try std.testing.expectEqual(@as(usize, 1), journal.count()); // 一条，下一 seq=1

    const maybe = try journal.waitSince(a, 0, 0);
    try std.testing.expect(maybe != null);
    const lines = maybe.?;
    defer {
        for (lines) |l| a.free(l);
        a.free(lines);
    }
    try std.testing.expect(lines.len == 1);
    try std.testing.expect(std.mem.indexOf(u8, lines[0], "session_lifecycle") != null);
    try std.testing.expect(std.mem.indexOf(u8, lines[0], "created") != null);
    try std.testing.expect(std.mem.indexOf(u8, lines[0], "abc123session") != null);

    // closed 可 journal（收尾）。
    journalSessionLifecycle(&journal, a, .{ .closed = "abc123session" });
    try std.testing.expectEqual(@as(usize, 2), journal.count());
}

test "U6 A4: /state 快照含 agent roster(attach 见已 spawn 的 agent)" {
    const a = std.testing.allocator;
    const RegT = @import("../core/agent_job_registry.zig").AgentJobRegistry;
    const session_id = @import("../core/session_id.zig");

    var journal = EventJournal.init(a);
    defer journal.deinit();
    var wb = WebBackend.init(a, &journal);
    defer wb.deinit();

    // 最小 App(undefined trick):只初始化 snapshot() 触及的字段。
    var app: app_mod.App = undefined;
    app.allocator = a;
    app.config = @import("../types.zig").Config{}; // provider_kind=.anthropic(activeModel 读它)
    app.snapshot_cache = null; // → snapshotSlices 走 activeModel/additionalDirs 直读
    app.additional_dirs_abs = null;
    app.plugin_snapshot = null;
    app.usage = .{};
    app.session_id = session_id.SessionId.single;
    app.permission_ctx = @import("../permission.zig").createContext(.default, a);
    var io_rt = std.Io.Threaded.init(a, .{});
    defer io_rt.deinit();
    app.api_client = @import("../client.zig").Client.initWithBaseUrl(a, io_rt.io(), "k", "m", null);
    defer app.api_client.deinit();
    // agent_jobs:直接赋值(勿经 copied local——registry 含 mutex/ArrayList,值拷会双释)。
    app.agent_jobs = try RegT.init(a, "k", null, "m", .anthropic);
    defer app.agent_jobs.?.deinit();
    try app.agent_jobs.?.pushTestEntryFull("Explore", "scan files", 3, 100, "Grep", "{}", .running);
    // tasks 必须真 init:snapshot() 走 snapshotTasks 要拿 mutex。undefined 的 mutex 在
    // POSIX 侥幸不崩(pthread 返回错误码被吞),Windows SRW 顺垃圾指针走 → 段错误。
    app.tasks = @import("../core/task_store.zig").TaskStore.init(a);
    defer app.tasks.deinit();

    var cmdbox = MsgQueue.init(a);
    defer cmdbox.deinit();
    var src = StateSource{ .app = &app, .wb = &wb, .cmdbox = &cmdbox, .journal = &journal };

    const json = try StateSource.snapshot(@ptrCast(&src), a);
    defer a.free(json);

    // roster 里那条 Explore agent(agent_type/state 投影)。
    try std.testing.expect(std.mem.indexOf(u8, json, "\"agents\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"agent_type\":\"Explore\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"state\":\"running\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"tool_calls\":3") != null);
    // seq 也在(附着握手)。
    try std.testing.expect(std.mem.indexOf(u8, json, "\"seq\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"plugin_inventory\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "metacodes.plugin-inventory/v1") != null);
}
