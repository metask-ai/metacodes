//! **daemon 真 App driver(U10-D)** —— SessionHost 的 driver_fn:跑真 agent_loop,消费 host.inbox
//! → host.journal。**复用 web/session.zig 的 buildWebOptions**(与 web run() 同一份 Options,不漂移)。
//!
//! **职责边界(与 serve 分工)**:driver **只跑循环**(消息→run→journal)。per-session 资源
//! (wb/config_sink/ui_requester/lifecycle)由 **serve 建**——因为 wb 是 driver↔transport **共享**
//! 资源(transport 的 StateSource 要 wb.pendingId() + /respond 路由回本 wb),必须 serve 建、经
//! DriverCtx.wb 传给 driver + 同时给 WebServer。setup/teardown 顺序对齐 web run() 的 defer 契约,
//! 集中在 serve(见 serve.zig)。
//!
//! **allocator 分裂(与 web run() 一致,'allocator 一致铁律')**:
//! - **app.allocator**(App arena,与 app.conversation 同源)→ agent_loop.run + scoped_recall。
//! - **host.allocator**(serve 建 host 时的 web_alloc/c_allocator,线程安全)→ msg free / announceRunDone。
//!
//! **线程**:driver_fn 在 SessionHost 线程跑。App arena 单线程(每 session 一个 App,本 driver 唯一
//! toucher);host.journal/wb 线程安全(c_alloc)。

const std = @import("std");
const app_mod = @import("../app.zig");
const agent_loop = @import("../core/agent_loop.zig");
const project_activation = @import("../core/project_rule_activation.zig");
const web_session = @import("../web/session.zig");
const WebBackend = @import("../web/backend.zig").WebBackend;
const registry = @import("registry.zig");
const SessionHost = registry.SessionHost;
const abort = @import("../util/abort.zig");
const time = @import("../util/time.zig");
const log = @import("../util/log.zig");

/// driver 注入上下文:该 session 的 App + 共享 wb(serve 建)。
pub const DriverCtx = struct {
    app: *app_mod.App,
    wb: *WebBackend, // serve 建、绑 host.journal,driver 取 backend() 喂 agent_loop
};

/// SessionHost.abort_fn:中断该 session 的 in-flight run(戳 app.abort)。requestStop 调它 → agent_loop
/// 的网络 IO 阻塞立即返回,join 不挂(见 registry.SessionHost.destroy)。
pub fn abortFn(ctx: *anyopaque, reason: abort.Reason) void {
    const dctx: *DriverCtx = @ptrCast(@alignCast(ctx));
    dctx.app.abort.abort(reason);
}

/// SessionHost.driver_fn:真 App 驱动循环(mirror web/session.zig run() 的 outer 循环,用 host 资源)。
/// 退出:host.stopRequested()。**wb/config_sink/lifecycle 由 serve 建/拆,不在此**。
/// **task#18:driver 线程 reap 后台 job 的 done 事件**。job 线程只置 e.status(不能安全用父栈
/// trampoline reporter,后台续跑时早失效)。driver(session 线程)周期排出新终态 job,发
/// agent_lifecycle.done 到 session journal → attach/SSE 客户端实时见后台 agent 完成(不必再轮询 roster)。
fn reapAgentDone(app: *app_mod.App, be: *const @import("../core/protocol/ui_backend.zig").UiBackend, session: @import("../core/session_id.zig").SessionId, infra: std.mem.Allocator) void {
    const aj = if (app.agent_jobs) |*a| a else return;
    const infos = aj.drainNewlyDone(infra) catch return;
    defer @import("../core/agent_job_registry.zig").AgentJobRegistry.freeDoneInfos(infra, infos);
    for (infos) |d| {
        be.emitEvent(session, .{ .agent_lifecycle = .{ .done = .{
            .id = d.id,
            .state = @tagName(d.status),
            .turns = d.turns,
            .tool_calls = d.tool_calls,
            .tokens = d.tokens,
        } } });
    }
}

pub fn driverFn(host: *SessionHost, ctx: *anyopaque) void {
    const dctx: *DriverCtx = @ptrCast(@alignCast(ctx));
    const app = dctx.app;
    const app_alloc = app.allocator; // agent_loop + scoped_recall(与 conversation 同源)
    const infra = host.allocator; // msg free / announceRunDone(线程安全 c_alloc)
    const be = dctx.wb.backend();

    while (!host.stopRequested()) {
        const msg = host.inbox.popFront() orelse {
            reapAgentDone(app, &be, host.id, infra); // 空闲期也 reap:后台 job 可能在无新消息时完成
            time.sleepMs(50);
            continue;
        };
        defer infra.free(msg); // msg 来自 host.inbox(infra alloc)

        app.conversation.appendText(.user, msg) catch |e| {
            log.warn("daemon", "appendText failed: {s}", .{@errorName(e)});
            continue;
        };

        const run_control: ?*project_activation.RunControl = if (app.sessionDir()) |dir|
            project_activation.RunControl.init(
                app_alloc,
                dir,
                app.session_id,
                if (app.project_dir_or_empty().len > 0) app.project_dir_or_empty() else app.cwdAbs(),
                &app.abort,
            ) catch |err| {
                log.err("daemon", "run control failed closed: {s}", .{@errorName(err)});
                web_session.announceRunDone(&host.journal, infra, "error", @errorName(err));
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
            log.err("daemon", "project rules rejected detached workers: {s}", .{@errorName(err)});
            web_session.announceRunDone(&host.journal, infra, "error", @errorName(err));
            continue;
        };

        const scoped_recall = if (app.kg) |*k| (@import("../kg/scoped_recall.zig").build(app_alloc, k, &app.conversation, &app.abort) catch null) else null;
        defer if (scoped_recall) |s| app_alloc.free(s);

        // 生成期门(S1):transport 的 /interrupt 只在此窗口打 abort。true→run→false(defer 保证异常也复位)。
        host.generating.store(true, .seq_cst);
        defer host.generating.store(false, .seq_cst);

        var options = web_session.buildWebOptions(app, dctx.wb, scoped_recall);
        options.tool_observer = if (run_control) |control| control.observer() else null;
        options.project_rule_gate = if (run_control) |control| control.formalGate() else null;
        const result = agent_loop.run(
            &app.conversation,
            app.provider(),
            app.tool_defs,
            &app.permission_ctx,
            options,
            &be,
            app_alloc, // 与 conversation 同源
        ) catch |err| {
            if (run_control) |control| control.finishRun(@errorName(err)) catch |finish_err| {
                log.err("daemon", "run control finish failed: {s}", .{@errorName(finish_err)});
            };
            log.err("daemon", "agent_loop failed: {s}", .{@errorName(err)});
            web_session.announceRunDone(&host.journal, infra, "error", @errorName(err));
            continue;
        };
        if (run_control) |control| control.finishRun(@tagName(result.stop_reason)) catch |err| {
            log.err("daemon", "run control finish failed: {s}", .{@errorName(err)});
            web_session.announceRunDone(&host.journal, infra, "error", @errorName(err));
            continue;
        };

        app.persistTranscript();
        web_session.announceRunDone(&host.journal, infra, @tagName(result.stop_reason), null);
        reapAgentDone(app, &be, host.id, infra); // 本轮内完成的后台 job → 发 done

        // abort 复位:user_interrupt(前端 Stop)复位继续下一条;user_ctrl_c(host 停)由循环条件
        // stopRequested() 处理(serve 关停时 requestStop 置 stop_flag),不在此复位。
        if (result.stop_reason == .aborted and app.abort.reason() == .user_interrupt) {
            app.abort.resetForTesting();
        }
    }
}
