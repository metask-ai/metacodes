//! **daemon serve-multi(U10-C 消费者,静态 N-session)** —— `metacodes serve --sessions N [port]`:
//! 常驻进程宿主 **N 个独立 session**,经**已测的 WebServer resolver**(server.zig)按路径 `/s/<id>/*`
//! 路由到对应 session。**证明点**:N 个 session 各自 App/journal/driver,消息路由隔离、driver 真并发。
//!
//! **静态 N(MVP)**:启动即建 N 个 session,**无 dynamic create/destroy/idle-reap**——见
//! doc/U9_U10_DAEMON_TIER_DESIGN.md §4:resolver 返回 SessionView 是 borrow 快照(裸指针),host 中途
//! destroy 会重现 U10-A 删掉的 borrow-UAF。静态 session 活满 daemon 生命周期 → 无并发销毁 → 安全。
//!
//! **每 App 独立 arena + 独立 io_runtime**(设计 §5):
//! - arena:App agent_loop 在 app.allocator 上分配,各 driver 线程独占 → arena 非线程安全但单线程独占
//!   不竞争。**绝不共享 arena**。
//! - io_runtime:对齐 agent_job_registry「每 job 独立 Client + 独立 std.Io.Threaded」的**已证并发模式**
//!   (共享 App io_runtime 跨线程是 agent_job_registry:401 标注的未证风险)。
//!
//! **slot[0] 复用 main 预建 app**(已 probe + SIGINT 已装):其 arena=main、io=main;但 **app.deinit
//! 由 serveMulti 做**(owns_app=true)——main 在 serveMulti 返回后走 `std.process.exit` **跳过**其
//! `defer app.deinit()`(Linus L-low),不 deinit 会漏 reap slot[0] 的 MCP/LSP 子进程(孤儿)。arena/io
//! 不释放(main 的,OS 退出回收)。slot[1..N] 全新建(own arena+io,serveMulti 全释放)。slot[0] 的 main
//! arena/io 在 serve 期**仅** slot[0] driver 用(主线程只 poll shutdown)→ 无共享竞争。
//!
//! **关停顺序(关键正确性,踩 App.deinit 线程 join 雷)**:App.deinit join 后台 subagent/swarm/LSP/MCP
//! + 关 api_client → **必在该 session driver join 之后**(否则 driver 还用 client=UAF),又**必在
//! arena.deinit 之前**。故:① 每 slot journal.close ② srv.stop(transport 不再碰 host)③ reg.shutdownAll
//! (join 所有 driver)④ 每 slot teardown(reset app 钩子 → wb.deinit → owns_app 则 app.deinit → io/arena)。

const std = @import("std");
const app_mod = @import("../app.zig");
const time = @import("../util/time.zig");
const log = @import("../util/log.zig");
const registry = @import("registry.zig");
const app_driver = @import("app_driver.zig");
const shutdown = @import("../core/shutdown.zig");
const web_session = @import("../web/session.zig");
const server_mod = @import("../web/server.zig");
const WebBackend = @import("../web/backend.zig").WebBackend;
const WebServer = server_mod.WebServer;
const SessionView = server_mod.SessionView;
const UdsServer = @import("uds.zig").UdsServer;

const SessionRegistry = registry.SessionRegistry;
const SessionHost = registry.SessionHost;

/// 一个 session 的全部宿主资源。存于 MultiDaemon.slots 固定数组(alloc 一次不 grow)→ 地址稳:
/// &slot.wb / &slot.dctx 被 WebServer/host 跨线程引用,绝不可搬。
const SessionSlot = struct {
    /// null = slot[0](用 main arena,serveMulti 不释放)。
    arena: ?*std.heap.ArenaAllocator,
    /// null = slot[0](用 main io)。
    io_rt: ?*std.Io.Threaded,
    app: *app_mod.App,
    /// true = serveMulti 负责 `app.deinit()`(join 后台线程 + reap MCP/LSP 子进程 + 关 client)。
    /// **全 slot 均 true**——含 slot[0]:main.zig 在 serveMulti 返回后走 `std.process.exit`,**跳过**其
    /// `defer app.deinit()`(Linus L-low),故 slot[0] 的子进程 reap 也须由 serveMulti 做,否则孤儿。
    /// arena/io 是否释放另由 arena/io_rt 是否 null 决定(slot[0] 均 null=main 的,OS 退出回收)。
    owns_app: bool,
    /// wireSlot 成功后为 true;失败/未建时 false(teardown 据此跳过 wb/host)。
    wired: bool = false,
    host: *SessionHost,
    wb: WebBackend,
    config_sink: web_session.WebConfigSink,
    dctx: app_driver.DriverCtx,
    /// U11:per-session rich /state + /command 数据源(地址稳:slots 固定数组)。
    state_src: web_session.StateSource,
};

const MultiDaemon = struct {
    slots: []SessionSlot,
    dummy: u8 = 0, // trivialState 的 state_ctx 占位(MVP 无 rich attach)
};

/// trivial /state:仅作 Deps 必填占位(resolver 存在时单 session 分支永不被读)。
fn trivialState(_: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
    return allocator.dupe(u8, "{}");
}

/// **诚实落地页(PM M1)**:多 session 下内嵌单 session SPA 的无前缀 fetch 全 404,故 `GET /` 不返 SPA,
/// 而返一张列出各 session id + API 端点的说明页(明说浏览器 SPA 仅 --web 单 session,此处为 API 级路由)。
/// 失败(OOM)返 null → route 兜底返 SPA(至少不炸)。
fn rootPage(ctx: *anyopaque, allocator: std.mem.Allocator) ?[]u8 {
    const md: *MultiDaemon = @ptrCast(@alignCast(ctx));
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    buf.appendSlice(allocator, "<!doctype html><meta charset=utf-8><title>metacodes daemon</title>" ++
        "<body style=\"font-family:system-ui;max-width:52rem;margin:2rem auto;padding:0 1rem\">" ++
        "<h1>metacodes daemon — multi-session</h1>" ++
        "<p><b>注意</b>:内嵌浏览器 SPA 仅在单 session <code>--web</code> 模式可用。此处为多 session " ++
        "<b>API 级路由</b>,浏览器 SPA(<code>/events</code>、<code>/message</code> 等无前缀端点)在本模式不工作。</p>" ++
        "<h2>Sessions</h2><ul>") catch return null;
    for (md.slots) |*slot| {
        if (!slot.wired) continue;
        buf.appendSlice(allocator, "<li><code>") catch return null;
        buf.appendSlice(allocator, slot.app.session_id.asSlice()) catch return null; // 24 hex,无需转义
        buf.appendSlice(allocator, "</code></li>") catch return null;
    }
    buf.appendSlice(allocator, "</ul><h2>API</h2><pre>" ++
        "POST /s/&lt;id&gt;/message   {\"text\":\"...\"}\n" ++
        "GET  /s/&lt;id&gt;/events    (SSE)\n" ++
        "POST /s/&lt;id&gt;/interrupt\n" ++
        "GET  /s/&lt;id&gt;/state     (MVP: {})\n" ++
        "</pre></body>") catch return null;
    return buf.toOwnedSlice(allocator) catch null;
}

/// **resolver(已测机制)**:线性扫 slots 匹配 session_id → 建 SessionView(裸指针指向 slot 的
/// host.journal/wb/inbox + app.abort)。未匹配 → null(WebServer 回 404)。
/// slots 静态不 destroy → SessionView 指针满 §4 生命周期契约。
fn resolveSession(ctx: *anyopaque, id: []const u8) ?SessionView {
    const md: *MultiDaemon = @ptrCast(@alignCast(ctx));
    for (md.slots) |*slot| {
        if (!slot.wired) continue;
        if (std.mem.eql(u8, slot.app.session_id.asSlice(), id)) {
            return SessionView{
                .journal = &slot.host.journal,
                .web_backend = &slot.wb,
                .inbox = &slot.host.inbox,
                .abort = &slot.app.abort,
                .generating = &slot.host.generating, // S1:/interrupt 生成期门(driver 维护)
                // U11:rich /state + /command(per-slot StateSource,与 --web 同一份实现;
                // 命令 HTTP 线程只入 host.cmdbox,driver 独占执行 → 旧 501 已废)。
                .state_ctx = @ptrCast(&slot.state_src),
                .state_fn = &web_session.StateSource.snapshot,
                .command_fn = &web_session.StateSource.command,
            };
        }
    }
    return null;
}

/// 释放 slot 的 App 层资源(**必在其 host 已 destroy=driver join 之后**调):owns 则 app.deinit(全
/// slot 均 owns,含 slot[0])+ io_runtime + arena(slot[0] 的 io/arena=null 跳过,均 main 的 OS 回收)。
fn freeAppResources(slot: *SessionSlot, web_alloc: std.mem.Allocator) void {
    if (slot.owns_app) slot.app.deinit();
    if (slot.io_rt) |rt| {
        rt.deinit();
        web_alloc.destroy(rt);
    }
    if (slot.arena) |ar| {
        ar.deinit();
        web_alloc.destroy(ar);
    }
}

/// 正常关停期单 slot 拆除(**host 已由 reg.shutdownAll destroy=driver 已 join**)。reset app 钩子
/// (slot[0] 的 app 存活到 main defer,须清干净)→ wb.deinit → freeAppResources。
fn teardownSlot(slot: *SessionSlot, web_alloc: std.mem.Allocator) void {
    if (slot.wired) {
        slot.app.permission_ctx.ui_requester = null;
        slot.app.setConfigEventSink(null);
        slot.wb.deinit();
    }
    freeAppResources(slot, web_alloc);
}

/// 接线单 slot 的 host/wb/driver(app 已定)。**原子契约**:成功 → host 入 reg + 起 driver + wb/钩子
/// 就位(slot.wired=true);失败 → host 已 destroy、wb 已 deinit、钩子已 reset(slot 仅剩 app/io/arena
/// 待 caller 经 freeAppResources 收)。**errdefer 顺序**:先注册 wb/钩子清理(LIFO 后跑),后注册
/// host.destroy(LIFO 先跑)→ 保证失败时**先 join driver 再 deinit wb**(反之 = wb UAF)。
///
/// **诚实声明(PM S3)**:此错误路径(host.start/reg.put 失败)由 code review(Linus)+ 上面散文核验,
/// **无测试触发**——这些失败仅在资源耗尽/session_id 碰撞(近乎不可能)时发生,注入困难。happy-path 由
/// tests/e2e/daemon_serve_multi_e2e.sh 覆盖。若日后引入更易失败的 wire 步骤,须补错误注入测试。
fn wireSlot(slot: *SessionSlot, reg: *SessionRegistry, web_alloc: std.mem.Allocator) !void {
    const host = try SessionHost.create(web_alloc, slot.app.session_id, @ptrCast(&slot.dctx), app_driver.driverFn, null, app_driver.abortFn);
    slot.host = host;
    slot.wb = WebBackend.init(web_alloc, &host.journal);
    slot.wb.abort = &slot.app.abort;
    slot.wb.usage_totals = &slot.app.usage;
    slot.dctx = .{ .app = slot.app, .wb = &slot.wb };
    slot.config_sink = .{ .journal = &host.journal, .alloc = web_alloc };
    slot.state_src = .{ .app = slot.app, .wb = &slot.wb, .cmdbox = &host.cmdbox, .journal = &host.journal, .generating = &host.generating };
    slot.app.setConfigEventSink(slot.config_sink.sink());
    slot.app.permission_ctx.ui_requester = slot.wb.requester();
    // (Ewb)先注册 → LIFO 最后跑:host 已 join 后才 deinit wb(顺序对)。
    errdefer {
        slot.app.permission_ctx.ui_requester = null;
        slot.app.setConfigEventSink(null);
        slot.wb.deinit();
    }
    // (Ehost)后注册 → LIFO 先跑:先 requestStop(abort 存活的 app)+ join driver + 释放 host。
    errdefer host.destroy();

    web_session.journalSessionLifecycle(&host.journal, web_alloc, .{ .created = slot.app.session_id.asSlice() });
    try host.start(); // 先起 driver(失败:无 driver,Ehost join noop)
    try reg.put(host); // 再入 reg(失败:Ehost destroy 已起的 driver,Ewb 随后 deinit)
    slot.wired = true; // 成功:host 归 reg,errdefer 不再 fire(无后续 error)
}

/// **UDS `list` op**:NDJSON `{"sessions":["<id>",...]}`(列 wired slot 的 session id)。OOM 返 null。
fn udsList(ctx: *anyopaque, allocator: std.mem.Allocator) ?[]u8 {
    const md: *MultiDaemon = @ptrCast(@alignCast(ctx));
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    buf.appendSlice(allocator, "{\"sessions\":[") catch return null;
    var first = true;
    for (md.slots) |*slot| {
        if (!slot.wired) continue;
        if (!first) buf.appendSlice(allocator, ",") catch return null;
        first = false;
        buf.appendSlice(allocator, "\"") catch return null;
        buf.appendSlice(allocator, slot.app.session_id.asSlice()) catch return null; // 24 hex,无需转义
        buf.appendSlice(allocator, "\"") catch return null;
    }
    buf.appendSlice(allocator, "]}") catch return null;
    return buf.toOwnedSlice(allocator) catch null;
}

/// 跑 daemon(静态 N session)直到 SIGINT。返回进程退出码。app0=main 预建 app(作 slot[0])。
/// config 用 anytype(避免 daemon 层依赖 types.Config 具体形状;App.init 按值接收)。
/// uds_path 非 null → 附加一条 UDS+NDJSON 绑定(U10-B,与 web 并存,同 registry)。
pub fn serveMulti(app0: *app_mod.App, allocator: std.mem.Allocator, config: anytype, api_key: []const u8, port: u16, n: usize, uds_path: ?[]const u8) !u8 {
    _ = allocator; // 每 App 用自己的 arena;daemon 基建用 c_allocator(跨线程)
    std.debug.assert(n >= 1);
    const web_alloc = std.heap.c_allocator;

    // SIGINT handler 已在 main 装(app0.installSigintHandler)→ shutdown.request() + app0.abort。
    // serve 主循环 poll shutdown.requested();各 session driver 的中断走 reg.shutdownAll 的 abort_fn。

    var reg = SessionRegistry.init(web_alloc);
    defer reg.deinit(); // 最后跑:shutdownAll 已清空 map,只释放空 map

    var md = MultiDaemon{ .slots = try web_alloc.alloc(SessionSlot, n) };
    defer web_alloc.free(md.slots);
    for (md.slots) |*s| s.wired = false; // 预置:错误路径/resolver 只碰 wired slot

    // ── 建 N slot ────────────────────────────────────────────────────────────
    var built: usize = 0;
    // 部分失败:回收已建(wired)slot。先 shutdownAll join 全 driver,再逐 slot teardown(顺序同正常关停)。
    errdefer {
        reg.shutdownAll();
        var k: usize = 0;
        while (k < built) : (k += 1) teardownSlot(&md.slots[k], web_alloc);
    }

    var i: usize = 0;
    while (i < n) : (i += 1) {
        const slot = &md.slots[i];
        if (i == 0) {
            // slot[0]:复用 main 预建 app(arena/io=main 的,不释放);但 **owns_app=true**——main 走
            // process.exit 跳过 defer app.deinit,serveMulti 须 deinit 它(reap 子进程,消 slot0 孤儿不对称)。
            slot.* = .{ .arena = null, .io_rt = null, .app = app0, .owns_app = true, .wired = false, .host = undefined, .wb = undefined, .config_sink = undefined, .dctx = undefined, .state_src = undefined };
        } else {
            // 全新 App:独立 arena(page-backed)+ 独立 io_runtime(c_allocator backing,线程安全)。
            const arena = try web_alloc.create(std.heap.ArenaAllocator);
            errdefer web_alloc.destroy(arena);
            arena.* = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            errdefer arena.deinit();
            const io_rt = try web_alloc.create(std.Io.Threaded);
            errdefer web_alloc.destroy(io_rt);
            io_rt.* = std.Io.Threaded.init(web_alloc, .{});
            errdefer io_rt.deinit();
            const app = try app_mod.App.init(arena.allocator(), io_rt.io(), config, api_key);
            // App.init 成功 → app 归本 slot;上面 errdefer 只覆盖 App.init 之前的失败(io_rt/arena)。
            slot.* = .{ .arena = arena, .io_rt = io_rt, .app = app, .owns_app = true, .wired = false, .host = undefined, .wb = undefined, .config_sink = undefined, .dctx = undefined, .state_src = undefined };
        }
        // 接线 host/driver。失败:wireSlot 已 destroy host+deinit wb+reset 钩子 → 只剩 app/io/arena。
        wireSlot(slot, &reg, web_alloc) catch |err| {
            freeAppResources(slot, web_alloc); // 本 slot 未计入 built,外层 errdefer 不覆盖它
            return err;
        };
        built += 1;
        std.debug.print("session {s} ready\n", .{slot.app.session_id.asSlice()});
        log.info("daemon", "session {s} ready", .{slot.app.session_id.asSlice()});
    }

    // ── transport(单 WebServer,resolver 按 /s/<id>/* 路由)──────────────────────
    // Deps 的单 session 字段(journal/wb/inbox/abort/state_*)在 resolver 非 null 时**永不被读**
    // (route 走 resolver 分支,singleView 不调)→ 填 slot[0] 占位满足 struct 必填。
    const s0 = &md.slots[0];
    const srv = try WebServer.start(web_alloc, port, .{
        .journal = &s0.host.journal,
        .web_backend = &s0.wb,
        .inbox = &s0.host.inbox,
        .abort = &s0.app.abort,
        .state_ctx = @ptrCast(&md.dummy),
        .state_fn = &trivialState,
        .resolver = &resolveSession,
        .resolver_ctx = @ptrCast(&md),
        .root_fn = &rootPage, // GET / → 诚实落地页(列 session id + API),非死 SPA(PM M1)
        .root_ctx = @ptrCast(&md),
    });

    std.debug.print("metacodes daemon ({d} sessions): http://127.0.0.1:{d}  (Ctrl+C to quit)\n", .{ n, srv.port });
    log.info("daemon", "serve-multi listening on 127.0.0.1:{d} ({d} sessions)", .{ srv.port, n });

    // ── 可选 UDS+NDJSON 绑定(U10-B,与 web 共享 registry/resolver)────────────────
    const uds: ?*UdsServer = if (uds_path) |p| blk: {
        const u = UdsServer.start(web_alloc, p, .{
            .allocator = web_alloc,
            .resolver = &resolveSession,
            .resolver_ctx = @ptrCast(&md),
            .list_fn = &udsList,
            .list_ctx = @ptrCast(&md),
        }) catch |err| {
            // UDS 起不来(路径太长/权限)不致命:web 仍服务,记 warn 继续。
            log.warn("daemon", "UDS bind {s} failed: {s}; web-only", .{ p, @errorName(err) });
            break :blk null;
        };
        std.debug.print("metacodes daemon UDS: {s}\n", .{p});
        log.info("daemon", "serve-multi UDS listening on {s}", .{p});
        break :blk u;
    } else null;

    // ── 主循环:poll 进程级停机 ────────────────────────────────────────────────
    while (!shutdown.requested()) time.sleepMs(50);

    // ── 关停(显式顺序,非 defer)──────────────────────────────────────────────
    // ① 每 slot journal.close(唤醒该 session 的 SSE waitSince)。
    for (md.slots) |*slot| slot.host.journal.close();
    // ② transport 停(HTTP + UDS 线程不再碰任何 host)。journal 已 close → attach/SSE 流被唤醒收尾。
    srv.stop();
    if (uds) |u| u.stop();
    // ③ 每 slot lifecycle.closed(journal 已 close,append 仍记 seq 供已连 SSE 收尾)。
    for (md.slots) |*slot| web_session.journalSessionLifecycle(&slot.host.journal, web_alloc, .{ .closed = slot.app.session_id.asSlice() });
    // ④ reg.shutdownAll:join 所有 driver(driver 停止用各自 app)+ 释放 host.journal/inbox。
    reg.shutdownAll();
    // ⑤ 每 slot teardown(driver 已 join,安全 app.deinit)。全 slot owns_app=true(含 slot[0]:main
    //    process.exit 跳过其 defer app.deinit,须在此 reap 子进程);slot[0] 的 arena/io=null 不释放(main 的)。
    for (md.slots) |*slot| teardownSlot(slot, web_alloc);

    std.debug.print("\ndaemon closed.\n", .{});
    return 0;
}
