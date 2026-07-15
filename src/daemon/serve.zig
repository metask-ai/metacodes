//! **daemon serve(U10-D,单 session MVP)** —— `metacodes serve [port]`:常驻进程,经
//! SessionRegistry+SessionHost+app_driver 跑一个真 session,HTTP/SSE transport(复用 WebServer),
//! SIGINT 优雅关停。**证明 daemon 机器全链**:message→agent_loop→journal→SSE + shutdown。
//!
//! **多 session(/s/<id>/*)= U10-C**(WebServer 多 session 化 + rich attach StateSource,下一轮);
//! 本 MVP 单 session,state_fn 用 trivial "{}"(rich /state 附着待 U10-C)。
//!
//! **关停顺序(关键正确性,显式非 defer)**:transport 先停(HTTP 线程不再碰 host)→ 再 reg.shutdownAll
//! (driver join + host destroy 释放 journal/inbox)→ 最后 defer 清 wb/config_sink(driver 已 join,安全)。
//! 顺序错则 UAF:wb.deinit 早于 driver join → driver 用已释放 wb。

const std = @import("std");
const app_mod = @import("../app.zig");
const time = @import("../util/time.zig");
const log = @import("../util/log.zig");
const registry = @import("registry.zig");
const app_driver = @import("app_driver.zig");
const shutdown = @import("../core/shutdown.zig");
const web_session = @import("../web/session.zig");
const WebBackend = @import("../web/backend.zig").WebBackend;
const WebServer = @import("../web/server.zig").WebServer;

const SessionRegistry = registry.SessionRegistry;
const SessionHost = registry.SessionHost;

/// trivial /state:rich attach(seq/roster/config)= U10-C。MVP 返回空对象。
fn trivialState(_: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
    return allocator.dupe(u8, "{}");
}

/// 跑 daemon(单 session MVP)直到 SIGINT。返回进程退出码。
pub fn serve(app: *app_mod.App, allocator: std.mem.Allocator, port: u16) !u8 {
    _ = allocator; // agent_loop 用 app.allocator(见 app_driver);web 基建用 c_allocator
    const web_alloc = std.heap.c_allocator; // journal/wb/inbox 跨线程并发,须线程安全

    // SIGINT → shutdown.request() + app.abort(见 app.onSigint)。serve 主循环 poll shutdown.requested()。
    try app.installSigintHandler();

    var reg = SessionRegistry.init(web_alloc);
    defer reg.deinit(); // 最后跑:此时 shutdownAll 已清空 map,只释放(空)map

    // ── 单 session 建立(serve owns per-session 资源) ──────────────────────────
    var dctx: app_driver.DriverCtx = undefined; // wb 定址后填(driver 在 start 后才读,happens-before)
    const host = try SessionHost.create(web_alloc, app.session_id, @ptrCast(&dctx), app_driver.driverFn, null, app_driver.abortFn);
    // host 建后 journal 就位 → 建 wb 绑 host.journal。
    var wb = WebBackend.init(web_alloc, &host.journal);
    defer wb.deinit(); // driver 已 join(下方显式 shutdownAll)后才跑,安全
    wb.abort = &app.abort;
    wb.usage_totals = &app.usage;
    dctx = .{ .app = app, .wb = &wb };

    // config 变更 → host.journal(SSE);setConfigEventSink 也 seed snapshot_cache(须在 server.start 前,
    // 对齐 web run() 的 U5 MINOR#3)。
    var config_sink = web_session.WebConfigSink{ .journal = &host.journal, .alloc = web_alloc };
    app.setConfigEventSink(config_sink.sink());
    defer app.setConfigEventSink(null);
    app.permission_ctx.ui_requester = wb.requester();
    defer app.permission_ctx.ui_requester = null;

    // session_lifecycle.created 作 journal 首帧(serve owns lifecycle;closed 在关停显式发)。
    web_session.journalSessionLifecycle(&host.journal, web_alloc, .{ .created = app.session_id.asSlice() });

    try reg.put(host);
    try host.start(); // driver 线程起,读 dctx(已填)
    // **Linus NIT 修**:driver 已起后,若下方 WebServer.start 失败(如端口占用)→ error 返回,defer LIFO
    // 会先跑 wb.deinit(defer#2)再 reg.deinit(defer#1 join driver)——顺序倒置(happy-path 的显式顺序
    // 只覆盖成功路径)。errdefer 在此(注册于 wb defer 之后)→ 错误路径**先** join driver 再 wb.deinit,
    // 消除潜在 UAF(今天靠 wb 栈分配侥幸无害,不赌运气)。成功路径不触发(走末尾显式 shutdownAll)。
    errdefer reg.shutdownAll();

    // ── transport(复用 WebServer,绑本 session)──────────────────────────────
    // **U10-C 待补**:command_fn(slash 命令 over HTTP,web run 有 StateSource.command,MVP 未接)+
    // rich state_fn(StateSource:seq/roster/config)。MVP 用 trivialState "{}"。见 task#22。
    var dummy: u8 = 0;
    const srv = try WebServer.start(web_alloc, port, .{
        .journal = &host.journal,
        .web_backend = &wb,
        .inbox = &host.inbox, // POST /message → host.inbox(driver 消费)
        .abort = &app.abort,
        .generating = &host.generating, // S1:/interrupt 生成期门(driver 维护),空闲期误打不吞下条消息
        .state_ctx = @ptrCast(&dummy),
        .state_fn = &trivialState,
    });

    std.debug.print("metacodes daemon (1 session): http://127.0.0.1:{d}  (Ctrl+C to quit)\n", .{srv.port});
    log.info("daemon", "serve listening on 127.0.0.1:{d}", .{srv.port});

    // ── 主循环:poll 进程级停机 ────────────────────────────────────────────────
    while (!shutdown.requested()) time.sleepMs(50);

    // ── 关停(显式顺序,非 defer)──────────────────────────────────────────────
    // ① transport 先停:HTTP 线程不再碰 host.journal/inbox(先 close journal 唤醒 SSE,再 stop server)。
    host.journal.close();
    srv.stop();
    // ② lifecycle.closed(journal 已 close,append 仍记入 seq 供已连 SSE 收尾)。
    web_session.journalSessionLifecycle(&host.journal, web_alloc, .{ .closed = app.session_id.asSlice() });
    // ③ driver join + host destroy(释放 journal/inbox)——**必在 wb.deinit(defer)之前**。
    reg.shutdownAll();
    // 返回 → defer:ui_requester=null → setConfigEventSink(null) → wb.deinit → reg.deinit(空 map)。
    std.debug.print("\ndaemon closed.\n", .{});
    return 0;
}
