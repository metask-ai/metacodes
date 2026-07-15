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
const journal_mod = @import("journal.zig");
const backend_mod = @import("backend.zig");
const server_mod = @import("server.zig");
const msg_queue_mod = @import("../repl/msg_queue.zig");
const log = @import("../util/log.zig");

const EventJournal = journal_mod.EventJournal;
const WebBackend = backend_mod.WebBackend;
const WebServer = server_mod.WebServer;
const MsgQueue = msg_queue_mod.MsgQueue;

/// /state 快照的数据源:driver 拥有,server 经回调读。
const StateSource = struct {
    app: *app_mod.App,
    wb: *WebBackend,
    cmdbox: *MsgQueue, // 斜杠命令队列(HTTP 入队,driver 执行)
    generating: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    fn snapshot(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
        const self: *StateSource = @ptrCast(@alignCast(ctx));
        // usage 是 u64 无锁读:与生成线程有良性竞态(至多读到相差一个 delta 的旧值),
        // 展示用途可接受;不为状态条引入跨线程锁。
        const u = &self.app.usage;
        return std.json.Stringify.valueAlloc(allocator, .{
            .model = self.app.config.model,
            .permission_mode = @tagName(self.app.config.permission_mode),
            .input_tokens = u.input_tokens,
            .output_tokens = u.output_tokens,
            .cost_usd = u.costUsd(self.app.config.model),
            .generating = self.generating.load(.acquire),
            .pending_request_id = self.wb.pendingId(),
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
fn execCommand(app: *app_mod.App, journal: *EventJournal, web_alloc: std.mem.Allocator, cmd: []const u8) void {
    const trimmed = std.mem.trim(u8, cmd, " \t\r\n");
    var ok = true;
    var buf: [256]u8 = undefined;
    const msg: []const u8 = blk: {
        if (std.mem.eql(u8, trimmed, "/mode")) {
            app.cyclePermMode();
            break :blk std.fmt.bufPrint(&buf, "permission mode → {s}", .{@tagName(app.config.permission_mode)}) catch "mode changed";
        }
        if (std.mem.eql(u8, trimmed, "/compact")) {
            // 投影:len() 不变,收缩的是活跃窗口 → 显示活跃计数(否则 N→N 误导)。
            const before = app.conversation.activeMessages().len;
            const dropped = app.conversation.compact(100_000) catch 0;
            break :blk std.fmt.bufPrint(&buf, "compacted {d} messages ({d} → {d} active)", .{ dropped, before, app.conversation.activeMessages().len }) catch "compacted";
        }
        if (std.mem.eql(u8, trimmed, "/model")) {
            break :blk std.fmt.bufPrint(&buf, "model: {s}", .{app.config.model}) catch "model";
        }
        if (std.mem.startsWith(u8, trimmed, "/model ")) {
            const name = std.mem.trim(u8, trimmed[7..], " \t");
            if (name.len == 0) { ok = false; break :blk "usage: /model <name>"; }
            const owned = app.allocator.dupe(u8, name) catch { ok = false; break :blk "out of memory"; };
            if (app.model_switch_owned) |old| app.allocator.free(old);
            app.model_switch_owned = owned;
            app.config.model = owned;
            break :blk std.fmt.bufPrint(&buf, "model → {s}", .{owned}) catch "model changed";
        }
        ok = false;
        break :blk std.fmt.bufPrint(&buf, "unknown command: {s}", .{trimmed}) catch "unknown command";
    };
    const line = std.json.Stringify.valueAlloc(web_alloc, .{ .command_result = .{ .ok = ok, .message = msg } }, .{}) catch return;
    defer web_alloc.free(line);
    journal.append(line);
}

/// 跑 web 会话直到退出(空闲期 SIGINT)。返回进程退出码。
pub fn run(app: *app_mod.App, allocator: std.mem.Allocator, port: u16) !u8 {
    // web 侧资源统一 c_allocator:emit/journal/HTTP 连接线程并发分配,必须线程安全
    // (App 的 arena allocator 不是)。生命周期 = 本函数,deinit 成对。
    const web_alloc = std.heap.c_allocator;

    var journal = EventJournal.init(web_alloc);
    defer journal.deinit();
    var wb = WebBackend.init(web_alloc, &journal);
    defer wb.deinit();
    wb.abort = &app.abort;
    wb.usage_totals = &app.usage; // /state 的 token/cost 数据源(backend 累计,全仓惯例)
    var inbox = MsgQueue.init(web_alloc);
    defer inbox.deinit();
    var cmdbox = MsgQueue.init(web_alloc);
    defer cmdbox.deinit();
    var state_src = StateSource{ .app = app, .wb = &wb, .cmdbox = &cmdbox };

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

        // scoped 自动召回(对齐 headless.zig:按请求装配相关记忆,cache-safe 尾注入)
        const scoped_recall = if (app.kg) |*k| (@import("../kg/scoped_recall.zig").build(allocator, k, &app.conversation, &app.abort) catch null) else null;
        defer if (scoped_recall) |s| allocator.free(s);

        const jobs_ptr = if (app.jobs) |*j| j else null;
        const result = agent_loop.run(
            &app.conversation,
            app.provider(),
            app.tool_defs,
            &app.permission_ctx,
            .{
                .session = app.session_id,
                .verbose = app.config.verbose,
                .abort = &app.abort,
                .read_state = &app.read_state,
                .edit_hl_cache = &app.edit_hl_cache,
                .jobs = jobs_ptr,
                .agent_jobs = if (app.agent_jobs) |*aj| aj else null,
                .plan_prev_mode = &app.plan_prev_mode,
                .tasks = &app.tasks,
                .kg = if (app.kg) |*k| k else null,
                .kg_projects_dir = app.kg_projects_dir,
                .memdir_abs = app.memdir_abs,
                .api_client = &app.api_client,
                .tool_defs = app.tool_defs,
                .system_prompt = app.system_prompt,
                .inject_user_context = app.user_context,
                .synthetic_user_input = scoped_recall,
                .dyn_registry = &app.dyn_registry,
                .host_services = app.hostServices(),
                .activated_tools = &app.activated_tools,
                .project_dir = app.project_dir_or_empty(),
                .sandbox = app.sandboxPtr(),
                .cwd_abs = app.cwdAbs(), .additional_dirs = app.additionalDirs(),
                .home_dir = app.homeDir(),
                .agents = &app.agents,
                .parent_model = app.config.model,
                .model_switch_compact = app.pendingModelSwitchCompact(),
                .skills_set = &app.skills,
                .ui_requester = wb.requester(),
                .mcp_sessions = &app.mcp_sessions.items,
                .cron_registry = &app.cron_registry,
                .plan_file_path = app.plan_file_path,
                .emit_tool_cards = true,
            },
            &be,
            allocator,
        ) catch |err| {
            log.err("web", "agent_loop failed: {s}", .{@errorName(err)});
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

fn announceRunDone(journal: *EventJournal, allocator: std.mem.Allocator, stop_reason: []const u8, err_name: ?[]const u8) void {
    const line = std.json.Stringify.valueAlloc(allocator, .{
        .run_done = .{ .stop_reason = stop_reason, .err = err_name },
    }, .{}) catch return;
    defer allocator.free(line);
    journal.append(line);
}

test {
    std.testing.refAllDecls(@This());
}
