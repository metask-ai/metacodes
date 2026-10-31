//! WebServer —— 最小 HTTP/1.1 + SSE 服务器(`--web`、`serve`、`serve --sessions/--uds` 的 HTTP 面)。
//!
//! 职责:把 web 前端的 HTTP 动词翻成协议层动作,自身不懂任何业务语义:
//!   GET  /health      → {"status":"ok","version":"<v>","sessions":N}(进程存活探针,#251)
//!   GET  /            → 内嵌 index.html(单页,自包含)
//!   GET  /events      → SSE:重放 journal(?since=N / Last-Event-ID)+ condvar 推新事件
//!   POST /message     → 入 inbox 队列(session driver 消费;user_message 由 driver 在该轮开跑时回显)
//!   POST /respond     → 回填 WebBackend 挂起的 UiRequest({"id":N,...})
//!   POST /capabilities → 前端能力帧(doc/WIRE_PROTOCOL.md §2):200 capabilities_accepted,
//!                       400 capabilities_refused(什么都不变)
//!   POST /command     → 斜杠命令入队(driver 线程执行)
//!   POST /interrupt   → 打 AbortSignal(与 TUI esc 同通道)
//!   GET  /state       → session 状态快照(经回调,server 不依赖 App)
//! 多 session(`Deps.resolver`)下,`/` 与 `/health` 之外的路径都在 `/s/<id>/` 之下。
//! The multi-session daemon also hands over `Deps.lifecycle` (#254): `GET
//! /sessions`, `POST /sessions/create`, `POST /sessions/<id>/resume` and
//! `POST /sessions/<id>/destroy` sit at the top level. This file only parses
//! the request and maps the callback's typed result to a status; what a
//! session is, and when one may be created or destroyed, is the daemon's.
//!
//! Admission is decided from the request head, before a byte of body is read:
//!   1. `GET /health` answers at once: no token, no Host check, no session,
//!      no journal, no heap. `version` is what `metacodes --version` prints;
//!      `sessions` is 1, or the resolver's session count.
//!   2. With a token (`Surface.token`, #252) every other request needs
//!      `Authorization: Bearer <token>`. A GET may carry `?token=` instead:
//!      EventSource cannot set headers, and a browser opens the SPA that way.
//!      A POST never authenticates by query. Missing or wrong → 401 with
//!      `WWW-Authenticate: Bearer`. Compared in constant time.
//!   3. Host, against DNS rebinding: without a token, a Host header must name
//!      the server by a loopback name (`localhost`, `127.0.0.1`, `[::1]`, with
//!      the listening port or none) — or, on a non-loopback bind allowed by
//!      `--web-allow-unauth`, by an IP literal, which no DNS answer can rebind.
//!      With a token, Host is free: the token is the guard. No Host at all is
//!      not a browser and passes.
//!   4. CSRF: a POST's Origin, when present, must be the origin of the Host it
//!      was sent to (`http://` or, behind a TLS-terminating proxy, `https://`).
//!
//! 线程模型:accept 循环一个线程;每连接一个 detached 线程(SSE 长连接阻塞在
//! journal.waitSince,普通请求即答即关)。allocator 必须线程安全(c_allocator)。
//!
//! Trust model: by default the server binds 127.0.0.1 without a token, the
//! same trust level as the TUI on this machine (single user). Any other bind
//! address (#253) needs a token or the operator's explicit
//! `--web-allow-unauth` (`checkExposure`): main refuses to start otherwise,
//! and `WebServer.start` refuses again before it opens a socket.
//! The daemon's UDS transport (daemon/uds.zig) keeps file-mode 0600 as its
//! only access control and takes no token.

const std = @import("std");
const time = @import("../util/time.zig");
const journal_mod = @import("../core/event_journal.zig");
const backend_mod = @import("backend.zig");
const submission_mod = @import("submission.zig");
const abort_mod = @import("../util/abort.zig");
const log = @import("../util/log.zig");
const net = @import("platform").net;
const http = @import("../util/http.zig");
const util_json = @import("../util/json.zig");
const SessionId = @import("../core/session_id.zig").SessionId;
const wire = @import("../core/protocol/wire.zig");

const EventJournal = journal_mod.EventJournal;
const WebBackend = backend_mod.WebBackend;
const SubmissionQueue = submission_mod.SubmissionQueue;

fn stringifyJson(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    const raw = try std.json.Stringify.valueAlloc(allocator, value, .{});
    defer allocator.free(raw);
    return util_json.repairJsonUtf8(allocator, raw);
}

pub const INDEX_HTML: []const u8 = @embedFile("index.html");

/// GET /state 的快照回调:返回 owned JSON(caller free)。server 不依赖 App,
/// 由 session driver 闭合状态来源(model/mode/usage/phase/pending_request)。
pub const StateFn = *const fn (ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8;

/// POST /command 的处理回调(最小 SessionService):cmd = "/compact" / "/mode" / "/model x" …
/// 返回 owned JSON 结果 `{"ok":bool,"message":"…"}`(caller free)。session 闭合 App 状态。
/// **线程**:在 HTTP 连接线程调——session 实现自行判 generating 拒绝会撞 driver 的操作。
pub const CommandFn = *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, cmd: []const u8) anyerror![]u8;

/// `GET /spans`: the session's recorded spans as one OTLP/JSON
/// `ExportTraceServiceRequest` (owned, caller frees). ctx = `state_ctx`.
/// Called on the HTTP connection thread: the implementation must not borrow
/// driver-owned state.
pub const SpansFn = *const fn (ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8;

/// The trace waterfall page served at `GET /trace` (reads `GET /spans`).
pub const TRACE_HTML: []const u8 = @embedFile("trace.html");

/// Longest bearer token accepted (#252). A token travels in a header and, on
/// a GET, in the query; 4 KiB leaves room for a JWT.
pub const MAX_TOKEN_LEN: usize = 4096;

pub const TokenError = error{ EmptyToken, TokenTooLong, TokenCharset };

/// A token is 1..MAX_TOKEN_LEN visible ASCII bytes (0x21-0x7e): it has to
/// cross an HTTP header unchanged, and a space or control byte would not.
pub fn validateToken(token: []const u8) TokenError!void {
    if (token.len == 0) return error.EmptyToken;
    if (token.len > MAX_TOKEN_LEN) return error.TokenTooLong;
    for (token) |byte| if (byte < 0x21 or byte > 0x7e) return error.TokenCharset;
}

/// How the process exposes this surface, resolved by main from flags and
/// environment (#251-#253) and handed to every host unchanged. Borrowed for
/// the server's lifetime.
pub const Surface = struct {
    /// IP literal to bind; its port is the requested one (0 = kernel-assigned).
    address: net.IpAddress = net.loopback(0),
    /// Bearer token every route but `GET /health` requires; null = none, which
    /// `start` accepts only on a loopback address unless `allow_unauth`.
    token: ?[]const u8 = null,
    /// `--web-allow-unauth`: the operator accepts a non-loopback address
    /// without a token.
    allow_unauth: bool = false,
    /// What `metacodes --version` prints (semver, plus `+commit` on dev
    /// builds), reported by `GET /health` so an orchestrator can check the
    /// running release.
    version: []const u8,
};

pub const ExposureError = error{UnauthenticatedNonLoopback};

/// #253: a non-loopback bind hands the session (shell, files, permission
/// answers) to whoever reaches the port, so it needs a token, or the
/// operator's explicit `--web-allow-unauth`.
pub fn checkExposure(address: net.IpAddress, token: ?[]const u8, allow_unauth: bool) ExposureError!void {
    if (net.isLoopbackAddress(address) or token != null or allow_unauth) return;
    return error.UnauthenticatedNonLoopback;
}

/// Which Host headers a request may carry (DNS-rebinding guard, see the header).
pub const HostPolicy = enum {
    /// A token is set: it is the guard, Host is not restricted.
    any,
    /// No token, loopback bind: only loopback names.
    loopback,
    /// No token, non-loopback bind (`--web-allow-unauth`): loopback names or
    /// IP literals; a client on the network reaches the server by its address.
    loopback_or_ip_literal,

    pub fn of(address: net.IpAddress, token: ?[]const u8) HostPolicy {
        if (token != null) return .any;
        return if (net.isLoopbackAddress(address)) .loopback else .loopback_or_ip_literal;
    }
};

/// What admission checks a request against; fixed when the server starts.
pub const Access = struct {
    token: ?[]const u8,
    host: HostPolicy,
    /// The listening port: the port a Host header may name.
    port: u16,
};

/// The verdict on a request head, reached before any body byte is read.
pub const Admission = enum { health, unauthorized, host_rejected, cross_origin, admitted };

/// server 的借用依赖(session driver 拥有,生命周期须覆盖 server)。
/// **U10-C:一个 session 的 per-request 视图**(handler 用它,而非直接 self.deps)。单 session 模式
/// 从 Deps 直取(singleView);多 session 模式经 resolver 按 /s/<id>/ 的 id 解析。
pub const SessionView = struct {
    journal: *EventJournal,
    web_backend: *WebBackend,
    inbox: *SubmissionQueue,
    abort: *abort_mod.AbortSignal,
    generating: ?*const std.atomic.Value(bool) = null,
    state_ctx: *anyopaque,
    state_fn: StateFn,
    command_fn: ?CommandFn = null,
    spans_fn: ?SpansFn = null,
};

/// One resolved session, held for one request — for `GET /events` the whole
/// SSE stream, for a UDS `attach` the whole attachment (#254).
///
/// Lifetime contract: everything `view` points at (journal, backend, queues,
/// the App behind `state_ctx`, the abort signal) stays valid until `release`.
/// The holder calls `release` exactly once, by `defer` right after a
/// successful `resolve`. Destroying a session never waits for leases: the
/// host stops the session's driver and background work, appends `session_lifecycle.closed` and
/// closes the journal (which ends every SSE stream and attachment, so their
/// leases come back), and frees the session's memory only once the last lease
/// is released. A session that is being destroyed is never resolved again.
pub const Lease = struct {
    view: SessionView,
    ctx: *anyopaque,
    release_fn: *const fn (ctx: *anyopaque) void,

    /// Give the session back; exactly once per lease.
    pub fn release(self: Lease) void {
        self.release_fn(self.ctx);
    }
};

/// Multi-session routing (`Deps.resolver`).
pub const Resolver = struct {
    /// id → a leased session (see `Lease`); null = unknown, or being
    /// destroyed (404).
    resolve: *const fn (ctx: *anyopaque, id: []const u8) ?Lease,
    ctx: *anyopaque,
    /// How many sessions `resolve` answers for. `GET /health` reads this and
    /// never calls `resolve` (#251): a probe must not touch session state.
    sessions: *const std.atomic.Value(usize),
};

/// `POST /sessions/create`, parsed (#254). A restore always names its id, so
/// "resume without an id" cannot be expressed.
pub const CreateRequest = union(enum) {
    /// A new conversation, under the caller's id or a generated one.
    fresh: ?SessionId,
    /// The conversation persisted under this id (`"resume":true`).
    restore: SessionId,
};

pub const Created = struct {
    id: SessionId,
    /// Messages restored from the transcript; 0 for a fresh session.
    messages: usize,
};

/// Why a create was refused; each maps to one status in `serveLifecycle`.
pub const CreateError = error{
    /// The id names a live session (409).
    SessionLive,
    /// The id names a destroyed session that is not reaped yet: its App still
    /// owns the session directory (409, normally for milliseconds after the
    /// last request using it ends).
    SessionClosing,
    /// A fresh create names an id whose transcript is persisted; it would
    /// overwrite that conversation (409; `"resume":true` restores it).
    TranscriptExists,
    /// `"resume":true` names an id with no persisted transcript (404).
    TranscriptNotFound,
    /// The live-session cap is reached (429).
    SessionLimit,
    /// The daemon is shutting down (503).
    ShuttingDown,
    /// The transcript exists but could not be loaded (500).
    RestoreFailed,
    /// Building the session failed (500).
    CreateFailed,
};

pub const DestroyError = error{
    /// Not a live session: unknown, or already being destroyed (404).
    UnknownSession,
};

/// Dynamic session lifecycle (#254), present only for the multi-session
/// daemon. Every callback runs on an HTTP connection thread.
pub const Lifecycle = struct {
    ctx: *anyopaque,
    /// The cap `create` enforces, reported with a 429.
    max_sessions: usize,
    create: *const fn (ctx: *anyopaque, request: CreateRequest) CreateError!Created,
    /// Whether `id` names a live session; loads nothing.
    is_live: *const fn (ctx: *anyopaque, id: SessionId) bool,
    /// Returns once the session's driver and background work have stopped
    /// and been joined.
    destroy: *const fn (ctx: *anyopaque, id: SessionId) DestroyError!void,
    /// `{"sessions":[...]}` (owned by `allocator`).
    list: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8,
};

pub const Deps = struct {
    journal: *EventJournal,
    web_backend: *WebBackend,
    inbox: *SubmissionQueue,
    /// 中断信号。**语义 = 中断当前生成**,不是退出进程——/interrupt 只在 generating
    /// 时打它(见 route);进程退出属于宿主(SIGINT/driver),不给浏览器这个权力。
    abort: *abort_mod.AbortSignal,
    /// 生成期标志(driver 维护)。null = 无门(单测直连 abort 的场景)。
    generating: ?*const std.atomic.Value(bool) = null,
    state_ctx: *anyopaque,
    state_fn: StateFn,
    /// 斜杠命令处理(可空:单测不接)。ctx 复用 state_ctx。
    command_fn: ?CommandFn = null,
    /// `GET /spans` (null: 404). ctx reuses state_ctx.
    spans_fn: ?SpansFn = null,
    /// **U10-C:多 session 解析器**。非 null 时,路径 `/s/<id>/rest` 按 id 租用 session(`Lease`,未知
    /// 或正在销毁→404);无 /s/ 前缀的非 `/`、非 `/health`、非 `/sessions` 路径→404。null=单 session
    /// 模式(--web,直用上面字段)。
    resolver: ?Resolver = null,
    /// #254: the `/sessions` routes. Null (`--web`, single-session `serve`)
    /// makes them 404 like any unknown path.
    lifecycle: ?Lifecycle = null,
    /// **U10-C:`GET /` 落地页覆盖**。非 null → `GET /` 调它取 HTML(caller-allocated,route 用完 free);
    /// null → 返内嵌单 session SPA(INDEX_HTML)。多 session(resolver≠null)下 SPA 的 fetch 全走无前缀
    /// 路径会 404(PM M1),故 serve-multi 用它回一张**诚实落地页**(列 session id + API 端点,不假装 SPA 可用)。
    root_fn: ?*const fn (ctx: *anyopaque, allocator: std.mem.Allocator) ?[]u8 = null,
    root_ctx: *anyopaque = undefined,
};

/// 并发连接硬上限(HTTP+UDS 各自计):每连接 1 detached 线程 + 1MB 缓冲,无界即 slow-loris DoS。
pub const MAX_CONNS: usize = 64;

pub const WebServer = struct {
    /// 必须线程安全(连接线程并发分配)。
    allocator: std.mem.Allocator,
    listen_fd: net.Socket,
    port: u16,
    /// The bound address, with the port the kernel picked when 0 was asked for.
    address: net.IpAddress,
    access: Access,
    /// `Surface.version` (borrowed).
    version: []const u8,
    accept_thread: std.Thread = undefined,
    /// 活跃连接线程数(detached)。stop() 等它归零再释放 self——否则连接线程
    /// 还在摸 self.deps 时资源已被 deinit(UAF)。
    live_conns: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    /// stop() 已发起:acceptLoop 唯一的退出依据。stop 先置它再 shutdown+close(listen_fd),
    /// accept 返 -1 时据它区分"主动关闭(退出)"vs"瞬时错误 EINTR/ECONNABORTED/
    /// EMFILE(continue 重试)"——否则一次瞬时错误就让 server 永久哑掉。
    closing: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    deps: Deps,

    /// 绑 surface.address(端口 0 = 内核分配,读回真实端口)并起 accept 线程。
    /// Main refuses an unauthenticated non-loopback surface before anything
    /// starts; `start` refuses it again, before any socket exists, so no other
    /// host of this server can expose a session by mistake. A malformed token
    /// is refused here too.
    pub fn start(allocator: std.mem.Allocator, surface: Surface, deps: Deps) !*WebServer {
        if (surface.token) |token| try validateToken(token);
        try checkExposure(surface.address, surface.token, surface.allow_unauth);
        // 可移植 listen(POSIX socket/Windows WSAStartup+ws2_32),内部含 REUSEADDR+getsockname。
        const l = try net.listenAddress(surface.address, 16);
        errdefer net.closeSocket(l.sock);
        var address = surface.address;
        address.setPort(l.port);

        const self = try allocator.create(WebServer);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .listen_fd = l.sock,
            .port = l.port,
            .address = address,
            .access = .{ .token = surface.token, .host = .of(surface.address, surface.token), .port = l.port },
            .version = surface.version,
            .deps = deps,
        };
        self.accept_thread = try std.Thread.spawn(.{}, acceptLoop, .{self});
        return self;
    }

    /// `http://<bound address>`, e.g. `http://127.0.0.1:7777` or
    /// `http://[::1]:7777`. Never carries the token.
    pub fn url(self: *const WebServer, buffer: []u8) []const u8 {
        return std.fmt.bufPrint(buffer, "http://{f}", .{self.address}) catch "http://?";
    }

    /// The startup line every host prints, `<label>: <url>  (Ctrl+C to quit)`,
    /// and, with a token, how to present it. The token itself is never printed
    /// or logged.
    pub fn announce(self: *const WebServer, label: []const u8) void {
        var buffer: [80]u8 = undefined;
        const where = self.url(&buffer);
        std.debug.print("{s}: {s}  (Ctrl+C to quit)\n", .{ label, where });
        if (self.access.token != null) {
            std.debug.print("bearer-token auth is on (token not shown): send 'Authorization: Bearer <token>', or open {s}/?token=<token> in a browser\n", .{where});
        }
        log.info("web", "{s} listening on {s} (token auth {s})", .{ label, where, if (self.access.token != null) "on" else "off" });
    }

    /// Sessions `GET /health` reports: the resolver's count, else the one
    /// session this server was started for.
    pub fn sessionCount(self: *const WebServer) usize {
        return if (self.deps.resolver) |r| r.sessions.load(.acquire) else 1;
    }

    /// shutdown+关 listen fd(accept 返负退出)+ join + 等连接线程归零。SSE 连接线程靠
    /// journal.close() 醒来收尾——调用方(session driver)须**先 close journal 再 stop**。
    pub fn stop(self: *WebServer) void {
        _ = self.stopDrained();
    }

    /// `stop`, reporting whether every connection thread finished. False: one
    /// was still running after 12 s, and the server leaked itself rather than
    /// free memory that thread reads; the caller must then keep what `Deps`
    /// points at alive as well (the multi-session daemon leaks itself, #254).
    pub fn stopDrained(self: *WebServer) bool {
        self.closing.store(true, .release); // 先标记再 close:accept 醒来据它判定主动退出
        net.shutdownSocket(self.listen_fd); // Linux:跨线程 close 不保证唤醒已阻塞的 accept
        net.closeSocket(self.listen_fd);
        self.accept_thread.join();
        // 等 detached 连接线程退净。**上限须 > socket 超时(SO_RCVTIMEO/SNDTIMEO=10s)**:
        // 卡在读/写的连接线程最长被超时唤醒需 10s;SSE 阻塞线程由 journal.close 立即唤醒。
        // 12s 覆盖最坏情况 → 正常关停连接线程必然退净,调用方(run())随后 deinit
        // journal/inbox/cmdbox/wb 才安全(它们在 run() 栈上、无条件释放,连接线程还活着
        // 会 UAF)。3s 旧上限 < 10s socket 超时 = 有漏网窗口,已修。
        var waited_ms: u64 = 0;
        while (self.live_conns.load(.acquire) > 0 and waited_ms < 12_000) {
            time.sleepMs(10);
            waited_ms += 10;
        }
        if (self.live_conns.load(.acquire) > 0) {
            // 兜底:socket 超时可醒的线程 12s 内必退。宁泄漏 self 不 UAF。A thread
            // still here is hung, or inside a long daemon callback (a create whose
            // App.init is slow); `stopDrained` tells the caller so.
            log.warn("web", "stop: {d} connection thread(s) still live after 12s, leaking WebServer", .{self.live_conns.load(.acquire)});
            return false;
        }
        self.allocator.destroy(self);
        return true;
    }

    fn acceptLoop(self: *WebServer) void {
        while (true) {
            const conn_fd = net.acceptConn(self.listen_fd) orelse {
                if (self.closing.load(.acquire)) return; // 主动 stop:listen_fd 已关,退出
                // 瞬时错误(EINTR/ECONNABORTED/EMFILE 等):短憩后重试,绝不让 server 哑掉。
                // 10ms 兜底防万一 EBADF-但-未标记-closing 忙循环烧满 CPU。
                time.sleepMs(10);
                continue;
            };
            // 连接数上限:防 slow-loris 打满线程(每连接 1 线程 + 1MB 请求缓冲,无界即 DoS)。
            // 上限要容 SSE 长连接(每浏览器标签常驻一条)+ 突发短请求;64 对本机单用户富余。
            // 直接 close 拒绝(不回 503:写响应也要占线程,极端场景反成放大器)。
            if (self.live_conns.load(.acquire) >= MAX_CONNS) {
                log.warn("web", "connection limit reached ({d}), rejecting", .{@as(usize, MAX_CONNS)});
                net.closeSocket(conn_fd);
                continue;
            }
            // 计数在 spawn 前加(accept 线程侧):避免"已 accept 未及计数"时 stop 误判 0。
            _ = self.live_conns.fetchAdd(1, .acq_rel);
            const t = std.Thread.spawn(.{}, handleConn, .{ self, conn_fd }) catch {
                _ = self.live_conns.fetchSub(1, .acq_rel);
                net.closeSocket(conn_fd);
                continue;
            };
            t.detach();
        }
    }

    fn handleConn(self: *WebServer, fd: net.Socket) void {
        defer _ = self.live_conns.fetchSub(1, .acq_rel); // 配对 acceptLoop 的 fetchAdd
        defer net.closeSocket(fd);
        // 读超时 10s:半截请求(slow-loris)不许无限占线程+buffer。
        net.setRecvTimeoutMs(fd, 10_000);
        // 写超时 10s:SSE 是持续写,卡死的客户端(TCP 接收窗口满、不读)会让 writeAll
        // **永久阻塞**,钉住连接线程 → live_conns 永不归零 → stop() 无法干净退出。
        // 写超时 → writeAll 返 false → 线程退出。SSE 空闲(无事件不写)不受影响。
        net.setSendTimeoutMs(fd, 10_000);
        // 读请求(headers + Content-Length body)。1MB 上限(消息/应答都是小 JSON)。
        const cap: usize = 1024 * 1024;
        const buf = self.allocator.alloc(u8, cap) catch return;
        defer self.allocator.free(buf);

        var total: usize = 0;
        var headers_end: ?usize = null;
        var content_length: usize = 0;
        while (total < cap and headers_end == null) {
            const n = net.recv(fd, buf[total..cap]);
            if (n <= 0) return;
            total += @intCast(n);
            if (std.mem.indexOf(u8, buf[0..total], "\r\n\r\n")) |i| {
                headers_end = i + 4;
                content_length = parseContentLength(buf[0..i]) orelse 0;
            }
        }
        const he = headers_end orelse return;
        const head = buf[0..(he - 4)];
        const line = parseRequestLine(head) orelse {
            writeSimple(fd, "400 Bad Request", "application/json", "{\"error\":\"bad request line\"}");
            return;
        };

        // Admission on the head alone: a peer that has not proved it may talk
        // to us never gets the server to wait for, or buffer, its body.
        const body_received = total - he;
        switch (admit(line, head, self.access)) {
            .health => return self.serveHealth(fd),
            .unauthorized => {
                writeResponse(fd, "401 Unauthorized", "application/json", "WWW-Authenticate: Bearer\r\n", "{\"error\":\"unauthorized\"}");
                return discardDeclaredBody(fd, body_received, content_length);
            },
            .host_rejected => {
                writeSimple(fd, "403 Forbidden", "application/json", "{\"error\":\"host not allowed\"}");
                return discardDeclaredBody(fd, body_received, content_length);
            },
            .cross_origin => {
                writeSimple(fd, "403 Forbidden", "application/json", "{\"error\":\"cross-origin POST rejected\"}");
                return discardDeclaredBody(fd, body_received, content_length);
            },
            .admitted => {},
        }

        // 减法侧比较:`he + content_length` 在恶意 Content-Length(接近 usize max)下会
        // 溢出(safe 模式 panic=DoS,fast 模式绕过检查=堆溢出)。cap-he 恒 ≥0,永不溢出。
        if (content_length > cap - he) {
            writeSimple(fd, "413 Payload Too Large", "application/json", "{\"error\":\"too large\"}");
            return;
        }
        while ((total - he) < content_length) {
            const n = net.recv(fd, buf[total .. he + content_length]);
            if (n <= 0) return;
            total += @intCast(n);
        }
        const body = buf[he..total];

        self.route(fd, line, head, body);
    }

    /// `GET /health` (#251): fixed-size, on the stack; touches neither the
    /// resolver nor any session, journal or lock.
    fn serveHealth(self: *WebServer, fd: net.Socket) void {
        var buffer: [256]u8 = undefined;
        var writer = std.Io.Writer.fixed(&buffer);
        std.json.Stringify.value(.{
            .status = "ok",
            .version = self.version,
            .sessions = self.sessionCount(),
        }, .{}, &writer) catch {
            writeSimple(fd, "500 Internal Server Error", "application/json", "{\"status\":\"error\"}");
            return;
        };
        writeResponse(fd, "200 OK", "application/json", "Cache-Control: no-store\r\n", writer.buffered());
    }

    fn route(self: *WebServer, fd: net.Socket, line: RequestLine, head: []const u8, body: []const u8) void {
        // Token, Host and the CSRF Origin check were settled by `admit` before
        // the body was read; see the module header.
        if (std.mem.eql(u8, line.method, "GET") and std.mem.eql(u8, line.path, "/")) {
            // 落地页:root_fn 覆盖(多 session 诚实落地页)优先,否则内嵌单 session SPA。
            if (self.deps.root_fn) |rf| {
                if (rf(self.deps.root_ctx, self.allocator)) |html| {
                    defer self.allocator.free(html);
                    writeSimple(fd, "200 OK", "text/html; charset=utf-8", html);
                    return;
                }
            }
            writeSimple(fd, "200 OK", "text/html; charset=utf-8", INDEX_HTML);
            return;
        }
        if (self.deps.lifecycle) |lifecycle| {
            if (parseLifecyclePath(line.path)) |target| {
                serveLifecycle(fd, self.allocator, line.method, target, body, lifecycle);
                return;
            }
        }
        // U10-C:解析 session view + 有效路径。单 session(resolver=null)直取 self.deps(向后兼容
        // --web);多 session 路径 /s/<id>/rest 经 resolver 按 id 租用(未知/销毁中→404),rest 作有效
        // 路径。The lease covers the whole request, the SSE stream included,
        // and goes back exactly once here (#254).
        var eff_path = line.path;
        var lease: ?Lease = null;
        defer if (lease) |held| held.release();
        const sv: SessionView = if (self.deps.resolver) |r| leased: {
            const sp = parseSessionPrefix(line.path) orelse {
                writeSimple(fd, "404 Not Found", "application/json", "{\"error\":\"session path required (/s/<id>/...)\"}");
                return;
            };
            lease = r.resolve(r.ctx, sp.id) orelse {
                writeSimple(fd, "404 Not Found", "application/json", "{\"error\":\"unknown session\"}");
                return;
            };
            eff_path = sp.rest;
            break :leased lease.?.view;
        } else self.singleView();

        if (std.mem.eql(u8, line.method, "GET") and std.mem.eql(u8, eff_path, "/events")) {
            self.serveSse(fd, line, head, sv);
            return;
        }
        if (std.mem.eql(u8, line.method, "POST") and std.mem.eql(u8, eff_path, "/message")) {
            // {"text", "model"?, "permission_mode"?}: a bad field is refused here, before
            // anything is queued. The model is checked by the driver (it needs the App), and
            // the driver journals user_message when the turn starts — not here, where the
            // message may wait behind a running turn (web/session.zig startSubmission).
            var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
            defer arena.deinit();
            const request = submission_mod.parseHttpBody(arena.allocator(), body) catch |err| {
                var reply_buf: [192]u8 = undefined;
                const reply = std.fmt.bufPrint(&reply_buf, "{{\"error\":\"{s}\"}}", .{submission_mod.reason(err)}) catch "{}";
                if (err == error.OutOfMemory) {
                    writeSimple(fd, "500 Internal Server Error", "application/json", reply);
                } else {
                    writeSimple(fd, "400 Bad Request", "application/json", reply);
                }
                return;
            };
            if (!sv.inbox.push(request)) {
                writeSimple(fd, "500 Internal Server Error", "application/json", "{\"error\":\"queue push failed\"}");
                return;
            }
            writeSimple(fd, "200 OK", "application/json", "{\"ok\":true}");
            return;
        }
        if (std.mem.eql(u8, line.method, "POST") and std.mem.eql(u8, eff_path, "/respond")) {
            const id = extractRespondId(body) orelse {
                writeSimple(fd, "400 Bad Request", "application/json", "{\"error\":\"missing id\"}");
                return;
            };
            if (sv.web_backend.respond(id, body)) {
                writeSimple(fd, "200 OK", "application/json", "{\"ok\":true}");
            } else {
                writeSimple(fd, "409 Conflict", "application/json", "{\"error\":\"no pending request with this id\"}");
            }
            return;
        }
        if (std.mem.eql(u8, line.method, "POST") and std.mem.eql(u8, eff_path, "/capabilities")) {
            const wb = sv.web_backend;
            const accepted = wb.declareCapabilities(body) catch |err| switch (err) {
                error.OutOfMemory => {
                    writeSimple(fd, "500 Internal Server Error", "application/json", "{\"error\":\"out of memory\"}");
                    return;
                },
                else => |refusal| {
                    const refused = wire.writeCapabilitiesRefused(self.allocator, refusal) catch {
                        writeSimple(fd, "500 Internal Server Error", "application/json", "{\"error\":\"out of memory\"}");
                        return;
                    };
                    defer self.allocator.free(refused);
                    writeSimple(fd, "400 Bad Request", "application/json", refused);
                    return;
                },
            };
            defer wb.allocator.free(accepted);
            writeSimple(fd, "200 OK", "application/json", accepted);
            return;
        }
        if (std.mem.eql(u8, line.method, "POST") and std.mem.eql(u8, eff_path, "/command")) {
            const cmd = extractStringKey(self.allocator, body, "cmd") orelse {
                writeSimple(fd, "400 Bad Request", "application/json", "{\"error\":\"missing cmd\"}");
                return;
            };
            defer self.allocator.free(cmd);
            const cf = sv.command_fn orelse {
                writeSimple(fd, "501 Not Implemented", "application/json", "{\"error\":\"commands unavailable\"}");
                return;
            };
            const res = cf(sv.state_ctx, self.allocator, cmd) catch {
                writeSimple(fd, "500 Internal Server Error", "application/json", "{\"ok\":false,\"message\":\"command failed\"}");
                return;
            };
            defer self.allocator.free(res);
            writeSimple(fd, "200 OK", "application/json", res);
            return;
        }
        if (std.mem.eql(u8, line.method, "POST") and std.mem.eql(u8, eff_path, "/interrupt")) {
            // 只在生成期放行:/interrupt 的语义是"停止当前生成",不是"退出进程"。
            // 空闲期误打 abort 会被 driver 的空闲循环当 SIGINT 优雅退出信号 → 浏览器
            // Stop 按钮击杀整个 daemon(Round 1 review P0)。有门用门;无门(单测)直打。
            if (sv.generating) |g| {
                if (!g.load(.acquire)) {
                    writeSimple(fd, "409 Conflict", "application/json", "{\"error\":\"not generating\"}");
                    return;
                }
            }
            // user_interrupt(非 user_ctrl_c):driver 据此只中断当前 run、不退出进程。
            // 真进程退出是 SIGINT 专属(user_ctrl_c),浏览器无权触发。
            sv.abort.abort(.user_interrupt);
            writeSimple(fd, "200 OK", "application/json", "{\"ok\":true}");
            return;
        }
        if (std.mem.eql(u8, line.method, "GET") and std.mem.eql(u8, eff_path, "/trace")) {
            writeResponse(fd, "200 OK", "text/html; charset=utf-8", "Cache-Control: no-store\r\n", TRACE_HTML);
            return;
        }
        if (std.mem.eql(u8, line.method, "GET") and std.mem.eql(u8, eff_path, "/spans")) {
            const sf = sv.spans_fn orelse {
                writeSimple(fd, "404 Not Found", "application/json", "{\"error\":\"span recording unavailable\"}");
                return;
            };
            const json = sf(sv.state_ctx, self.allocator) catch {
                writeSimple(fd, "500 Internal Server Error", "application/json", "{\"error\":\"span read failed\"}");
                return;
            };
            defer self.allocator.free(json);
            writeResponse(fd, "200 OK", "application/json", "Cache-Control: no-store\r\n", json);
            return;
        }
        if (std.mem.eql(u8, line.method, "GET") and std.mem.eql(u8, eff_path, "/state")) {
            const json = sv.state_fn(sv.state_ctx, self.allocator) catch {
                writeSimple(fd, "500 Internal Server Error", "application/json", "{\"error\":\"state snapshot failed\"}");
                return;
            };
            defer self.allocator.free(json);
            writeSimple(fd, "200 OK", "application/json", json);
            return;
        }
        writeSimple(fd, "404 Not Found", "application/json", "{\"error\":\"not found\"}");
    }

    /// U10-C:从 self.deps 单 session 字段构 SessionView(resolver=null 时用)。
    fn singleView(self: *WebServer) SessionView {
        // With a resolver every session path is leased; these fields are placeholders.
        std.debug.assert(self.deps.resolver == null);
        return .{
            .journal = self.deps.journal,
            .web_backend = self.deps.web_backend,
            .inbox = self.deps.inbox,
            .abort = self.deps.abort,
            .generating = self.deps.generating,
            .state_ctx = self.deps.state_ctx,
            .state_fn = self.deps.state_fn,
            .command_fn = self.deps.command_fn,
            .spans_fn = self.deps.spans_fn,
        };
    }

    /// SSE 长连接:从游标重放 + 阻塞推新。游标来源优先级:?since=N(&epoch=E) > Last-Event-ID 头 > 0。
    /// id 语义:`<journal epoch hex>-<seq>`(seq 0-based);浏览器重连带 Last-Event-ID → 从 seq+1 续。
    /// 游标属于另一份 journal(宿主重启、会话重建)或超出本 journal 末尾,都无法续接:从最老保留行
    /// 整体重放,并先发 `resync` 说明原因,客户端据此清空视图(否则静默等到 seq 追上,漏掉之间的事件)。
    fn serveSse(self: *WebServer, fd: net.Socket, line: RequestLine, head: []const u8, sv: SessionView) void {
        const plan = sv.journal.planResume(resolveCursor(line.query, head));
        const epoch = sv.journal.epochHex();
        var since = plan.from;

        if (!writeAll(fd, "HTTP/1.1 200 OK\r\n" ++
            "Content-Type: text/event-stream\r\n" ++
            "Cache-Control: no-cache\r\n" ++
            "Connection: keep-alive\r\n\r\n" ++
            "retry: 1000\n\n")) return;

        if (plan.restart) |reason| {
            const rsx = std.fmt.allocPrint(self.allocator, "event: resync\ndata: {{\"reason\":\"{s}\",\"epoch\":\"{s}\",\"from\":{d}}}\n\n", .{ @tagName(reason), &epoch, since }) catch return;
            defer self.allocator.free(rsx);
            if (!writeAll(fd, rsx)) return;
        }

        while (true) {
            // U7:waitSinceFrom 报出 effective start(批次首行逻辑 seq)。若 > since,说明
            // [since, start) 已被环形淘汰(客户端落后保留窗)→ 发 resync 让客户端重拉 /state
            // (config/roster 幂等可重建;丢的是瞬态渲染事件)。frame id 用 start+i(逻辑 seq)。
            var eff_start: usize = since;
            const batch = sv.journal.waitSinceFrom(self.allocator, since, 15_000, &eff_start) catch return;
            if (eff_start > since) {
                const rsx = std.fmt.allocPrint(self.allocator, "event: resync\ndata: {{\"reason\":\"evicted\",\"epoch\":\"{s}\",\"from\":{d},\"dropped_to\":{d}}}\n\n", .{ &epoch, eff_start, eff_start }) catch return;
                defer self.allocator.free(rsx);
                if (!writeAll(fd, rsx)) return;
                since = eff_start; // 跳到保留窗起点,后续 frame id 与 since 一致
            }
            if (batch) |lines| {
                defer {
                    for (lines) |l| self.allocator.free(l);
                    self.allocator.free(lines);
                }
                for (lines, 0..) |l, i| {
                    var id_buffer: [40]u8 = undefined;
                    const frame = std.fmt.allocPrint(self.allocator, "id: {s}\ndata: {s}\n\n", .{ sv.journal.eventId(&id_buffer, since + i), l }) catch return;
                    defer self.allocator.free(frame);
                    if (!writeAll(fd, frame)) return;
                }
                since += lines.len;
            } else {
                if (sv.journal.isClosed()) {
                    _ = writeAll(fd, "event: session_closed\ndata: {}\n\n");
                    return;
                }
                // 空闲心跳:探测死连接(浏览器关页后 write 失败 → 线程退出)
                if (!writeAll(fd, ": keepalive\n\n")) return;
            }
        }
    }
};

/// The admission order of the module header: `/health`, token, Host, then
/// the CSRF Origin check for POST. Pure over the head, so the server can call
/// it before reading a body and tests can call it without a socket.
pub fn admit(line: RequestLine, head: []const u8, access: Access) Admission {
    if (std.mem.eql(u8, line.method, "GET") and std.mem.eql(u8, line.path, "/health")) return .health;
    if (access.token) |token| {
        if (!authorized(line, head, token)) return .unauthorized;
    }
    if (!hostAllowed(head, access.host, access.port)) return .host_rejected;
    if (std.mem.eql(u8, line.method, "POST") and !originAllowed(head, access.port)) return .cross_origin;
    return .admitted;
}

/// Whether the request presents `token`: `Authorization: Bearer <token>` on
/// any method, or `?token=<token>` (percent-encoded) on a GET. A POST cannot
/// authenticate by query, so a token never needs to sit in a form or a link
/// that changes state.
pub fn authorized(line: RequestLine, head: []const u8, token: []const u8) bool {
    if (headerValue(head, "authorization")) |value| {
        if (bearerCredential(value)) |credential| {
            if (http.constantTimeEql(credential, token)) return true;
        }
    }
    if (!std.mem.eql(u8, line.method, "GET")) return false;
    const encoded = queryParam(line.query, "token") orelse return false;
    var buffer: [MAX_TOKEN_LEN]u8 = undefined;
    const presented = http.percentDecode(encoded, &buffer) orelse return false;
    return http.constantTimeEql(presented, token);
}

/// The credential of an `Authorization: Bearer <credential>` value (scheme
/// case-insensitive, RFC 6750); null for any other scheme or an empty one.
fn bearerCredential(value: []const u8) ?[]const u8 {
    const scheme = "bearer";
    if (value.len <= scheme.len or !std.ascii.eqlIgnoreCase(value[0..scheme.len], scheme)) return null;
    if (value[scheme.len] != ' ' and value[scheme.len] != '\t') return null;
    const credential = std.mem.trim(u8, value[scheme.len..], " \t");
    return if (credential.len == 0) null else credential;
}

/// DNS-rebinding gate (module header, step 3). `port` is the listening port.
pub fn hostAllowed(head: []const u8, policy: HostPolicy, port: u16) bool {
    if (policy == .any) return true;
    // Every browser sends Host; a request without one is not a browser, and
    // so not a page that a rebound DNS name pointed here.
    const host = headerValue(head, "host") orelse return true;
    const authority = splitAuthority(host) orelse return false;
    if (authority.port) |named| {
        if (named != port) return false;
    }
    if (std.ascii.eqlIgnoreCase(authority.name, "localhost")) return true;
    const literal = net.parseIpLiteral(authority.name, 0) catch return false;
    if (net.isLoopbackAddress(literal)) return true;
    return policy == .loopback_or_ip_literal;
}

/// `name[:port]` or `[v6]:port` → name (brackets kept) and port. Null when
/// malformed: an empty name, a non-numeric port, an unbracketed IPv6 literal.
fn splitAuthority(host: []const u8) ?struct { name: []const u8, port: ?u16 } {
    var name = host;
    var port_text: ?[]const u8 = null;
    if (std.mem.startsWith(u8, host, "[")) {
        const close = std.mem.indexOfScalar(u8, host, ']') orelse return null;
        name = host[0 .. close + 1];
        const rest = host[close + 1 ..];
        if (rest.len > 0) {
            if (rest[0] != ':') return null;
            port_text = rest[1..];
        }
    } else if (std.mem.indexOfScalar(u8, host, ':')) |colon| {
        name = host[0..colon];
        port_text = host[colon + 1 ..];
    }
    if (name.len == 0) return null;
    const port: ?u16 = if (port_text) |text| (std.fmt.parseInt(u16, text, 10) catch return null) else null;
    return .{ .name = name, .port = port };
}

/// CSRF 门(POST)。浏览器跨域 POST 强制带 Origin 头——恶意网页
/// fetch('http://127.0.0.1:<port>/message',{method:'POST'}) 是简单请求、能发出(读不到响应但
/// 副作用已生效:让模型跑命令、抢答权限对话框)。同源 = Origin 正是请求所发往的 Host 的源
/// (`http://<Host>`,或 TLS 终结代理后的 `https://<Host>`);Host 已由 `hostAllowed` 把关。
/// 无 Origin(curl/非浏览器 CLI)放行——浏览器一定带,缺失即非浏览器。无 Host 却带 Origin
/// (HTTP/1.0 客户端)只认监听端口的回环源。读端点(GET /events /state)靠浏览器 CORS 挡:
/// 不发 CORS 头 → 跨域读不到响应。返回 true=放行。
pub fn originAllowed(head: []const u8, port: u16) bool {
    const origin = headerValue(head, "origin") orelse return true;
    if (headerValue(head, "host")) |host| {
        if (host.len == 0) return false;
        inline for (.{ "http://", "https://" }) |scheme| {
            if (origin.len == scheme.len + host.len and
                std.ascii.startsWithIgnoreCase(origin, scheme) and
                std.ascii.eqlIgnoreCase(origin[scheme.len..], host)) return true;
        }
        return false;
    }
    inline for (.{ "127.0.0.1", "localhost", "[::1]" }) |name| {
        var buffer: [64]u8 = undefined;
        const loopback_origin = std.fmt.bufPrint(&buffer, "http://" ++ name ++ ":{d}", .{port}) catch return false;
        if (std.mem.eql(u8, origin, loopback_origin)) return true;
    }
    return false;
}

/// U10-C:从 `/s/<id>/rest` 解析 {id, rest}(rest 含前导 /)。非此前缀 / id 空 / 无 rest → null。
pub fn parseSessionPrefix(path: []const u8) ?struct { id: []const u8, rest: []const u8 } {
    const pfx = "/s/";
    if (!std.mem.startsWith(u8, path, pfx)) return null;
    const after = path[pfx.len..];
    const slash = std.mem.indexOfScalar(u8, after, '/') orelse return null; // 必须有 id 后的 /rest
    if (slash == 0) return null; // 空 id
    return .{ .id = after[0..slash], .rest = after[slash..] };
}

/// A `/sessions` route (#254). Ids are taken as written; the handler
/// validates them.
pub const LifecyclePath = union(enum) {
    /// `/sessions`
    list,
    /// `/sessions/create`
    create,
    /// `/sessions/<id>/resume`
    @"resume": []const u8,
    /// `/sessions/<id>/destroy`
    destroy: []const u8,
    /// Any other path under `/sessions/`: 404.
    unknown,
};

/// `/sessions` and the paths below it; null for any other path.
pub fn parseLifecyclePath(path: []const u8) ?LifecyclePath {
    const root = "/sessions";
    if (!std.mem.startsWith(u8, path, root)) return null;
    const rest = path[root.len..];
    if (rest.len == 0) return .list;
    if (rest[0] != '/') return null; // "/sessionsX" is not under /sessions
    const tail = rest[1..];
    if (std.mem.eql(u8, tail, "create")) return .create;
    const slash = std.mem.indexOfScalar(u8, tail, '/') orelse return .unknown;
    const id = tail[0..slash];
    const verb = tail[slash + 1 ..];
    if (std.mem.eql(u8, verb, "resume")) return .{ .@"resume" = id };
    if (std.mem.eql(u8, verb, "destroy")) return .{ .destroy = id };
    return .unknown;
}

pub const CreateParse = union(enum) {
    ok: CreateRequest,
    /// Why the body was refused (400); a fixed ASCII message.
    invalid: []const u8,
};

/// The body of `POST /sessions/create`: empty, or a JSON object with an
/// optional `"session_id"` (a valid session id) and `"resume"` (a boolean,
/// which needs the id). Unknown keys are ignored; `null` counts as absent.
pub fn parseCreateRequest(body: []const u8) CreateParse {
    if (std.mem.trim(u8, body, " \t\r\n").len == 0) return .{ .ok = .{ .fresh = null } };
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const value = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), body, .{}) catch
        return .{ .invalid = "body is not JSON" };
    if (value != .object) return .{ .invalid = "body must be a JSON object" };
    var id: ?SessionId = null;
    if (value.object.get("session_id")) |field| switch (field) {
        .null => {},
        .string => |text| id = SessionId.fromSlice(text) orelse
            return .{ .invalid = "session_id must be 24 lowercase hex characters" },
        else => return .{ .invalid = "session_id must be a string" },
    };
    var restore = false;
    if (value.object.get("resume")) |field| switch (field) {
        .null => {},
        .bool => |flag| restore = flag,
        else => return .{ .invalid = "resume must be a boolean" },
    };
    if (!restore) return .{ .ok = .{ .fresh = id } };
    return .{ .ok = .{ .restore = id orelse return .{ .invalid = "resume requires session_id" } } };
}

/// One `/sessions` request (#254): parse, call the daemon, map its typed
/// answer to a status. A method the route does not take is 404, as anywhere
/// else on this server.
fn serveLifecycle(fd: net.Socket, allocator: std.mem.Allocator, method: []const u8, target: LifecyclePath, body: []const u8, lifecycle: Lifecycle) void {
    const is_get = std.mem.eql(u8, method, "GET");
    const is_post = std.mem.eql(u8, method, "POST");
    switch (target) {
        .list => {
            if (!is_get) return writeError(fd, "404 Not Found", "not found");
            const json = lifecycle.list(lifecycle.ctx, allocator) catch
                return writeError(fd, "500 Internal Server Error", "session list failed");
            defer allocator.free(json);
            writeSimple(fd, "200 OK", "application/json", json);
        },
        .create => {
            if (!is_post) return writeError(fd, "404 Not Found", "not found");
            const request = switch (parseCreateRequest(body)) {
                .ok => |request| request,
                .invalid => |why| return writeError(fd, "400 Bad Request", why),
            };
            const created = lifecycle.create(lifecycle.ctx, request) catch |err| return writeCreateError(fd, err, lifecycle.max_sessions);
            var buffer: [96]u8 = undefined;
            const json = std.fmt.bufPrint(&buffer, "{{\"session_id\":\"{s}\",\"messages\":{d}}}", .{ created.id.asSlice(), created.messages }) catch unreachable;
            writeSimple(fd, "201 Created", "application/json", json);
        },
        .@"resume" => |text| {
            if (!is_post) return writeError(fd, "404 Not Found", "not found");
            const id = SessionId.fromSlice(text) orelse return writeError(fd, "404 Not Found", "session not live");
            if (!lifecycle.is_live(lifecycle.ctx, id)) return writeError(fd, "404 Not Found", "session not live");
            var buffer: [64]u8 = undefined;
            const json = std.fmt.bufPrint(&buffer, "{{\"session_id\":\"{s}\",\"live\":true}}", .{id.asSlice()}) catch unreachable;
            writeSimple(fd, "200 OK", "application/json", json);
        },
        .destroy => |text| {
            if (!is_post) return writeError(fd, "404 Not Found", "not found");
            const id = SessionId.fromSlice(text) orelse return writeError(fd, "404 Not Found", "unknown session");
            lifecycle.destroy(lifecycle.ctx, id) catch |err| switch (err) {
                error.UnknownSession => return writeError(fd, "404 Not Found", "unknown session"),
            };
            var buffer: [64]u8 = undefined;
            const json = std.fmt.bufPrint(&buffer, "{{\"ok\":true,\"session_id\":\"{s}\"}}", .{id.asSlice()}) catch unreachable;
            writeSimple(fd, "200 OK", "application/json", json);
        },
        .unknown => writeError(fd, "404 Not Found", "not found"),
    }
}

fn writeCreateError(fd: net.Socket, err: CreateError, max_sessions: usize) void {
    switch (err) {
        error.SessionLive => writeError(fd, "409 Conflict", "session already live"),
        error.SessionClosing => writeError(fd, "409 Conflict", "session is still closing"),
        error.TranscriptExists => writeError(fd, "409 Conflict", "a transcript is persisted under this session_id; create with resume true to restore it"),
        error.TranscriptNotFound => writeError(fd, "404 Not Found", "no persisted transcript for this session_id"),
        error.SessionLimit => {
            var buffer: [80]u8 = undefined;
            const json = std.fmt.bufPrint(&buffer, "{{\"error\":\"session limit reached\",\"max_sessions\":{d}}}", .{max_sessions}) catch unreachable;
            writeSimple(fd, "429 Too Many Requests", "application/json", json);
        },
        error.ShuttingDown => writeError(fd, "503 Service Unavailable", "daemon is shutting down"),
        error.RestoreFailed => writeError(fd, "500 Internal Server Error", "the persisted transcript could not be restored"),
        error.CreateFailed => writeError(fd, "500 Internal Server Error", "session could not be created"),
    }
}

/// `{"error":"<message>"}` with `status`.
fn writeError(fd: net.Socket, comptime status: []const u8, message: []const u8) void {
    var buffer: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    std.json.Stringify.value(.{ .@"error" = message }, .{}, &writer) catch
        return writeSimple(fd, status, "application/json", "{\"error\":\"?\"}");
    writeSimple(fd, status, "application/json", writer.buffered());
}

/// SSE 游标来源优先级:?since=N(&epoch=E) > Last-Event-ID 头 > 0。解析与续接判定在
/// core/event_journal.zig(`Cursor`、`EventJournal.planResume`),任何宿主共用同一规则。
pub fn resolveCursor(query: []const u8, head: []const u8) journal_mod.Cursor {
    if (queryParam(query, "since")) |since| return journal_mod.Cursor.fromSince(since, queryParam(query, "epoch"));
    if (headerValue(head, "last-event-id")) |raw| return journal_mod.Cursor.fromLastEventId(raw);
    return .{};
}

// ── 纯函数(可单测)─────────────────────────────────────────────────────────

// Head parsing lives in util/http.zig so the `kgd` supervisor parses requests
// exactly the way this server does. Re-exported: existing callers and tests
// keep using `server.parseRequestLine` and friends.
pub const RequestLine = http.RequestLine;
pub const parseRequestLine = http.parseRequestLine;
pub const queryParam = http.queryParam;
pub const headerValue = http.headerValue;
pub const parseContentLength = http.parseContentLength;

fn dupeTrimmedOrNull(allocator: std.mem.Allocator, s: []const u8) ?[]u8 {
    const t = std.mem.trim(u8, s, " \t\r\n");
    if (t.len == 0) return null;
    return allocator.dupe(u8, t) catch null;
}

/// 从 JSON body 提取顶层 string 字段 key 的值(owned,trim 后非空;否则 null)。
/// POST /command 的 {"cmd":"…"} 用。转义由 parser 解开。
pub fn extractStringKey(allocator: std.mem.Allocator, body: []const u8, key: []const u8) ?[]u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), body, .{}) catch return null;
    if (v != .object) return null;
    const f = v.object.get(key) orelse return null;
    if (f != .string) return null;
    return dupeTrimmedOrNull(allocator, f.string);
}

/// POST /respond body → id 字段。
pub fn extractRespondId(body: []const u8) ?u64 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), body, .{}) catch return null;
    if (v != .object) return null;
    const id_v = v.object.get("id") orelse return null;
    return switch (id_v) {
        .integer => |i| if (i >= 0) @intCast(i) else null,
        else => null,
    };
}

/// After a refusal sent from the head alone, take in and drop what is left of
/// a small declared body before the connection closes: closing with unread
/// input makes the kernel reset the connection, and the peer could lose the
/// refusal it was about to read. Bounded (64 KiB, 1 s) and never kept, so a
/// peer that has not been admitted still cannot make the server buffer or
/// wait for a body of its choosing.
fn discardDeclaredBody(fd: net.Socket, received: usize, declared: usize) void {
    const max_bytes: usize = 64 * 1024;
    if (declared <= received or declared > max_bytes) return;
    const deadline = time.nowMs() +| 1000;
    net.setRecvTimeoutMs(fd, 1000);
    var scratch: [4096]u8 = undefined;
    var left = declared - received;
    while (left > 0 and time.nowMs() < deadline) {
        const n = net.recv(fd, scratch[0..@min(left, scratch.len)]);
        if (n <= 0) return;
        left -|= @intCast(n);
    }
}

fn writeSimple(fd: net.Socket, comptime status: []const u8, comptime content_type: []const u8, body: []const u8) void {
    writeResponse(fd, status, content_type, "", body);
}

/// `extra_headers`: complete `Name: value\r\n` lines, or "".
fn writeResponse(fd: net.Socket, comptime status: []const u8, comptime content_type: []const u8, comptime extra_headers: []const u8, body: []const u8) void {
    var head_buf: [256]u8 = undefined;
    const head = std.fmt.bufPrint(&head_buf, "HTTP/1.1 " ++ status ++ "\r\n" ++
        "Content-Type: " ++ content_type ++ "\r\n" ++
        extra_headers ++
        "Content-Length: {d}\r\n" ++
        "Connection: close\r\n\r\n", .{body.len}) catch return;
    if (!writeAll(fd, head)) return;
    _ = writeAll(fd, body);
}

fn writeAll(fd: net.Socket, bytes: []const u8) bool {
    var pos: usize = 0;
    while (pos < bytes.len) {
        const n = net.send(fd, bytes[pos..]);
        if (n <= 0) return false;
        pos += @intCast(n);
    }
    return true;
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;
const TEST_VERSION = "0.0.0-test";

test "parseRequestLine: 方法/路径/query 拆分" {
    const l = parseRequestLine("GET /events?since=42 HTTP/1.1\r\nHost: x").?;
    try testing.expectEqualStrings("GET", l.method);
    try testing.expectEqualStrings("/events", l.path);
    try testing.expectEqualStrings("since=42", l.query);
    const l2 = parseRequestLine("POST /message HTTP/1.1").?;
    try testing.expectEqualStrings("/message", l2.path);
    try testing.expectEqualStrings("", l2.query);
    try testing.expectEqual(@as(?RequestLine, null), parseRequestLine(""));
}

test "U10-C: parseSessionPrefix 拆 /s/<id>/rest(边界)" {
    // 正常:/s/<id>/rest → {id, rest 含前导 /}(rest 保留后续段 + query 由 RequestLine 另拆)。
    const ok = parseSessionPrefix("/s/abc/events").?;
    try testing.expectEqualStrings("abc", ok.id);
    try testing.expectEqualStrings("/events", ok.rest);
    const nested = parseSessionPrefix("/s/xy/events/state").?; // rest 保留多段
    try testing.expectEqualStrings("xy", nested.id);
    try testing.expectEqualStrings("/events/state", nested.rest);
    // 边界 → null:非 /s/ 前缀 / id 后无 / / 空 id。
    try testing.expectEqual(@as(?@TypeOf(ok), null), parseSessionPrefix("/events")); // 非前缀
    try testing.expectEqual(@as(?@TypeOf(ok), null), parseSessionPrefix("/s/abc")); // id 后无 /rest
    try testing.expectEqual(@as(?@TypeOf(ok), null), parseSessionPrefix("/s/")); // 无 id 无 /
    try testing.expectEqual(@as(?@TypeOf(ok), null), parseSessionPrefix("/s//events")); // 空 id
}

test "#254 parseLifecyclePath: /sessions, create, <id>/resume, <id>/destroy; anything else below is unknown" {
    try testing.expectEqual(LifecyclePath.list, parseLifecyclePath("/sessions").?);
    try testing.expectEqual(LifecyclePath.create, parseLifecyclePath("/sessions/create").?);
    try testing.expectEqualStrings("abc", parseLifecyclePath("/sessions/abc/resume").?.@"resume");
    try testing.expectEqualStrings("abc", parseLifecyclePath("/sessions/abc/destroy").?.destroy);
    for ([_][]const u8{ "/sessions/", "/sessions/abc", "/sessions/abc/", "/sessions/abc/reboot", "/sessions/abc/destroy/x", "/sessions/create/x" }) |path| {
        try testing.expectEqual(LifecyclePath.unknown, parseLifecyclePath(path).?);
    }
    // Not under /sessions at all: the session router's business.
    for ([_][]const u8{ "/", "/session", "/sessionsX", "/s/abc/events", "/health" }) |path| {
        try testing.expectEqual(@as(?LifecyclePath, null), parseLifecyclePath(path));
    }
}

test "#254 parseCreateRequest: empty is fresh; a valid id, resume with an id; every malformed body is refused" {
    const id_text = "0123456789abcdef01234567";
    const id = SessionId.fromSlice(id_text).?;
    try testing.expectEqualDeep(CreateRequest{ .fresh = null }, parseCreateRequest("").ok);
    try testing.expectEqualDeep(CreateRequest{ .fresh = null }, parseCreateRequest(" \r\n").ok);
    try testing.expectEqualDeep(CreateRequest{ .fresh = null }, parseCreateRequest("{}").ok);
    try testing.expectEqualDeep(CreateRequest{ .fresh = null }, parseCreateRequest("{\"session_id\":null,\"resume\":false,\"other\":1}").ok);
    try testing.expectEqualDeep(CreateRequest{ .fresh = id }, parseCreateRequest("{\"session_id\":\"" ++ id_text ++ "\"}").ok);
    try testing.expectEqualDeep(CreateRequest{ .restore = id }, parseCreateRequest("{\"session_id\":\"" ++ id_text ++ "\",\"resume\":true}").ok);
    const refused = [_][]const u8{
        "{\"resume\":true}",
        "{\"resume\":true,\"session_id\":null}",
        "{\"session_id\":\"short\"}",
        "{\"session_id\":\"0123456789ABCDEF01234567\"}",
        "{\"session_id\":\"../../../../../../etc/pwd\"}",
        "{\"session_id\":7}",
        "{\"resume\":1,\"session_id\":\"" ++ id_text ++ "\"}",
        "not json",
        "[]",
        "\"text\"",
    };
    for (refused) |body| {
        testing.expect(parseCreateRequest(body) == .invalid) catch |err| {
            std.debug.print("accepted: {s}\n", .{body});
            return err;
        };
    }
}

test "originAllowed: 同源放行 / 无 Origin 放行(CLI)/ 跨域拒绝(CSRF)" {
    // 无 Origin(curl):放行
    try testing.expect(originAllowed("POST /message HTTP/1.1\r\nHost: x", 7777));
    // 无 Host 时只认监听端口的回环源:127.0.0.1 / localhost / [::1]
    try testing.expect(originAllowed("POST /m HTTP/1.1\r\nOrigin: http://127.0.0.1:7777", 7777));
    try testing.expect(originAllowed("POST /m HTTP/1.1\r\nOrigin: http://localhost:7777", 7777));
    try testing.expect(originAllowed("POST /m HTTP/1.1\r\nOrigin: http://[::1]:7777", 7777));
    // 跨域恶意页:拒绝(CSRF 防线)
    try testing.expect(!originAllowed("POST /m HTTP/1.1\r\nOrigin: http://evil.com", 7777));
    // 同 host 错端口:拒绝(端口精确匹配)
    try testing.expect(!originAllowed("POST /m HTTP/1.1\r\nOrigin: http://127.0.0.1:1234", 7777));
    // 无 Host 时 https 混淆:拒绝(scheme 精确)
    try testing.expect(!originAllowed("POST /m HTTP/1.1\r\nOrigin: https://127.0.0.1:7777", 7777));
}

test "originAllowed with a Host: same origin is Origin == scheme://Host, anything else is cross-origin" {
    // The bound host forms, including IPv6 and a non-loopback bind reached by address.
    try testing.expect(originAllowed("POST /m HTTP/1.1\r\nHost: [::1]:7777\r\nOrigin: http://[::1]:7777", 7777));
    try testing.expect(originAllowed("POST /m HTTP/1.1\r\nHost: 10.0.0.5:7777\r\nOrigin: http://10.0.0.5:7777", 7777));
    try testing.expect(originAllowed("POST /m HTTP/1.1\r\nHost: LOCALHOST:7777\r\nOrigin: http://localhost:7777", 7777));
    // A TLS-terminating proxy: the page is https, the hop to us is not.
    try testing.expect(originAllowed("POST /m HTTP/1.1\r\nHost: gw.example.com\r\nOrigin: https://gw.example.com", 7777));
    // A page elsewhere posting here: Origin names its own host, not ours.
    try testing.expect(!originAllowed("POST /m HTTP/1.1\r\nHost: 127.0.0.1:7777\r\nOrigin: http://evil.com", 7777));
    try testing.expect(!originAllowed("POST /m HTTP/1.1\r\nHost: 127.0.0.1:7777\r\nOrigin: http://127.0.0.1:7778", 7777));
    try testing.expect(!originAllowed("POST /m HTTP/1.1\r\nHost: 127.0.0.1:7777\r\nOrigin: null", 7777));
    try testing.expect(!originAllowed("POST /m HTTP/1.1\r\nHost: 127.0.0.1:7777\r\nOrigin: ftp://127.0.0.1:7777", 7777));
    try testing.expect(!originAllowed("POST /m HTTP/1.1\r\nHost: 127.0.0.1:7777\r\nOrigin: http://127.0.0.1:7777/x", 7777));
    try testing.expect(!originAllowed("POST /m HTTP/1.1\r\nHost: \r\nOrigin: http://", 7777));
}

test "hostAllowed: loopback names only without a token; IP literals on a non-loopback bind; anything with one" {
    const loopback_ok = [_][]const u8{ "127.0.0.1:7777", "127.0.0.1", "localhost:7777", "LocalHost", "[::1]:7777", "[::1]" };
    for (loopback_ok) |host| {
        var buffer: [96]u8 = undefined;
        const head = try std.fmt.bufPrint(&buffer, "GET /state HTTP/1.1\r\nHost: {s}", .{host});
        try testing.expect(hostAllowed(head, .loopback, 7777));
        try testing.expect(hostAllowed(head, .loopback_or_ip_literal, 7777));
    }
    // A rebound DNS name, a wrong port, a non-loopback address, malformed authorities.
    const rejected = [_][]const u8{ "evil.com:7777", "evil.com", "localhost.evil.com:7777", "127.0.0.1:1234", "localhost:", "[::1", "::1:7777", ":7777", "10.0.0.5:7777", "0.0.0.0:7777", "" };
    for (rejected) |host| {
        var buffer: [96]u8 = undefined;
        const head = try std.fmt.bufPrint(&buffer, "GET /state HTTP/1.1\r\nHost: {s}", .{host});
        try testing.expect(!hostAllowed(head, .loopback, 7777));
        try testing.expect(hostAllowed(head, .any, 7777));
    }
    // Reached over the network by address: an IP literal cannot be rebound; a name can.
    try testing.expect(hostAllowed("GET / HTTP/1.1\r\nHost: 10.0.0.5:7777", .loopback_or_ip_literal, 7777));
    try testing.expect(hostAllowed("GET / HTTP/1.1\r\nHost: [2001:db8::1]:7777", .loopback_or_ip_literal, 7777));
    try testing.expect(!hostAllowed("GET / HTTP/1.1\r\nHost: evil.com:7777", .loopback_or_ip_literal, 7777));
    try testing.expect(!hostAllowed("GET / HTTP/1.1\r\nHost: 10.0.0.5:1234", .loopback_or_ip_literal, 7777));
    // No Host header: not a browser.
    try testing.expect(hostAllowed("GET / HTTP/1.1", .loopback, 7777));
}

test "HostPolicy.of: a token frees Host; otherwise the bind decides" {
    try testing.expectEqual(HostPolicy.any, HostPolicy.of(net.loopback(0), "t"));
    try testing.expectEqual(HostPolicy.any, HostPolicy.of(try net.parseIpLiteral("0.0.0.0", 0), "t"));
    try testing.expectEqual(HostPolicy.loopback, HostPolicy.of(net.loopback(0), null));
    try testing.expectEqual(HostPolicy.loopback, HostPolicy.of(try net.parseIpLiteral("::1", 0), null));
    try testing.expectEqual(HostPolicy.loopback_or_ip_literal, HostPolicy.of(try net.parseIpLiteral("::", 0), null));
}

test "checkExposure: a non-loopback bind needs a token or --web-allow-unauth" {
    const lan = try net.parseIpLiteral("192.168.1.5", 0);
    for ([_][]const u8{ "0.0.0.0", "::", "192.168.1.5", "2001:db8::1" }) |text| {
        const address = try net.parseIpLiteral(text, 7777);
        try testing.expectError(error.UnauthenticatedNonLoopback, checkExposure(address, null, false));
        try checkExposure(address, "token", false);
        try checkExposure(address, null, true);
    }
    for ([_][]const u8{ "127.0.0.1", "127.0.0.2", "::1" }) |text| {
        try checkExposure(try net.parseIpLiteral(text, 7777), null, false);
    }
    try checkExposure(lan, "token", true);
}

test "validateToken: 1..MAX visible ASCII bytes" {
    try validateToken("a");
    try validateToken("Zm9vYmFy-_.~!$&'()*+,;=:@/?#[]%");
    try validateToken("x" ** MAX_TOKEN_LEN);
    try testing.expectError(error.EmptyToken, validateToken(""));
    try testing.expectError(error.TokenTooLong, validateToken("x" ** (MAX_TOKEN_LEN + 1)));
    try testing.expectError(error.TokenCharset, validateToken("has space"));
    try testing.expectError(error.TokenCharset, validateToken("tab\there"));
    try testing.expectError(error.TokenCharset, validateToken("line\r\nX-Injected: 1"));
    try testing.expectError(error.TokenCharset, validateToken("caf\xc3\xa9"));
}

test "admit: /health first, then token, Host and the POST Origin check" {
    const open: Access = .{ .token = null, .host = .loopback, .port = 7777 };
    const locked: Access = .{ .token = "s3cret", .host = .any, .port = 7777 };
    const Case = struct { request: []const u8, access: Access, verdict: Admission };
    const cases = [_]Case{
        // /health never asks for anything, not even a sane Host.
        .{ .request = "GET /health HTTP/1.1\r\nHost: evil.com", .access = open, .verdict = .health },
        .{ .request = "GET /health HTTP/1.1", .access = locked, .verdict = .health },
        .{ .request = "GET /health?probe=1 HTTP/1.1", .access = locked, .verdict = .health },
        // Only GET /health is the probe.
        .{ .request = "POST /health HTTP/1.1", .access = locked, .verdict = .unauthorized },
        .{ .request = "GET /s/abc/health HTTP/1.1", .access = locked, .verdict = .unauthorized },
        // Token: header on any method; query on GET only.
        .{ .request = "GET /state HTTP/1.1", .access = locked, .verdict = .unauthorized },
        .{ .request = "GET /state HTTP/1.1\r\nAuthorization: Bearer wrong!", .access = locked, .verdict = .unauthorized },
        .{ .request = "GET /state HTTP/1.1\r\nAuthorization: Bearer s3cret", .access = locked, .verdict = .admitted },
        .{ .request = "GET /state HTTP/1.1\r\nAuthorization: bearer   s3cret ", .access = locked, .verdict = .admitted },
        .{ .request = "GET /state HTTP/1.1\r\nAuthorization: Basic s3cret", .access = locked, .verdict = .unauthorized },
        .{ .request = "GET /state HTTP/1.1\r\nAuthorization: Bearers3cret", .access = locked, .verdict = .unauthorized },
        .{ .request = "GET /state HTTP/1.1\r\nAuthorization: s3cret", .access = locked, .verdict = .unauthorized },
        .{ .request = "GET /events?since=0&token=s3cret HTTP/1.1", .access = locked, .verdict = .admitted },
        .{ .request = "GET /events?token=s3cre%74 HTTP/1.1", .access = locked, .verdict = .admitted },
        .{ .request = "GET /events?token=s3cre HTTP/1.1", .access = locked, .verdict = .unauthorized },
        .{ .request = "GET /events?token=%zz HTTP/1.1", .access = locked, .verdict = .unauthorized },
        .{ .request = "POST /message?token=s3cret HTTP/1.1", .access = locked, .verdict = .unauthorized },
        .{ .request = "POST /message HTTP/1.1\r\nAuthorization: Bearer s3cret", .access = locked, .verdict = .admitted },
        // A valid token does not excuse a cross-origin POST.
        .{ .request = "POST /message HTTP/1.1\r\nHost: 127.0.0.1:7777\r\nAuthorization: Bearer s3cret\r\nOrigin: http://evil.com", .access = locked, .verdict = .cross_origin },
        // With a token Host is free; without one it must be a loopback name.
        .{ .request = "GET /state HTTP/1.1\r\nHost: metacodes.internal:8080\r\nAuthorization: Bearer s3cret", .access = locked, .verdict = .admitted },
        .{ .request = "GET /state HTTP/1.1\r\nHost: evil.com:7777", .access = open, .verdict = .host_rejected },
        .{ .request = "GET /state HTTP/1.1\r\nHost: localhost:7777", .access = open, .verdict = .admitted },
        // No token configured: today's behaviour, a query token is just ignored.
        .{ .request = "GET /state HTTP/1.1", .access = open, .verdict = .admitted },
        .{ .request = "POST /message HTTP/1.1\r\nOrigin: http://evil.com", .access = open, .verdict = .cross_origin },
    };
    for (cases) |case| {
        const line = parseRequestLine(case.request).?;
        testing.expectEqual(case.verdict, admit(line, case.request, case.access)) catch |err| {
            std.debug.print("request: {s}\n", .{case.request});
            return err;
        };
    }
}

test "resolveCursor: ?since 优先于 Last-Event-ID;都无 = 从头" {
    const Cursor = journal_mod.Cursor;
    try testing.expectEqualDeep(Cursor{ .next = 42, .epoch = .{ .named = 0xabc } }, resolveCursor("since=42&epoch=0000000000000abc", "GET /events HTTP/1.1\r\nLast-Event-ID: 00000000000000ff-9"));
    try testing.expectEqualDeep(Cursor{ .next = 10, .epoch = .{ .named = 0xff } }, resolveCursor("", "GET /events HTTP/1.1\r\nLast-Event-ID: 00000000000000ff-9"));
    try testing.expectEqualDeep(Cursor{}, resolveCursor("", "GET /events HTTP/1.1"));
}

test "queryParam / headerValue / parseContentLength" {
    try testing.expectEqualStrings("42", queryParam("a=1&since=42", "since").?);
    try testing.expectEqual(@as(?[]const u8, null), queryParam("a=1", "since"));
    const head = "GET / HTTP/1.1\r\nContent-Length: 17\r\nLast-Event-ID:  9";
    try testing.expectEqual(@as(usize, 17), parseContentLength(head).?);
    try testing.expectEqualStrings("9", headerValue(head, "last-event-id").?);
}

test "extractRespondId" {
    try testing.expectEqual(@as(u64, 7), extractRespondId("{\"id\":7,\"choice\":\"allow_once\"}").?);
    try testing.expectEqual(@as(?u64, null), extractRespondId("{\"choice\":\"x\"}"));
    try testing.expectEqual(@as(?u64, null), extractRespondId("junk"));
}

test "loopback: /message 入队(不回显), /state 快照, 404" {
    var j = EventJournal.init(testing.allocator);
    defer j.deinit();
    var wb = WebBackend.init(testing.allocator, &j);
    defer wb.deinit();
    var inbox = SubmissionQueue.init(testing.allocator);
    defer inbox.deinit();
    var sig = abort_mod.AbortSignal.init();
    const S = struct {
        fn state(_: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
            return allocator.dupe(u8, "{\"model\":\"test\"}");
        }
    };
    var dummy: u8 = 0;
    const srv = try WebServer.start(testing.allocator, .{ .version = TEST_VERSION }, .{
        .journal = &j,
        .web_backend = &wb,
        .inbox = &inbox,
        .abort = &sig,
        .state_ctx = @ptrCast(&dummy),
        .state_fn = &S.state,
    });
    defer srv.stop();

    // POST /message
    {
        const resp = try httpRoundtrip(testing.allocator, srv.port, "POST /message HTTP/1.1\r\nContent-Length: 15\r\n\r\n{\"text\":\"hola\"}");
        defer testing.allocator.free(resp);
        try testing.expect(std.mem.indexOf(u8, resp, "200 OK") != null);
    }
    var msg = inbox.popFront().?;
    defer msg.deinit(testing.allocator);
    try testing.expectEqualStrings("hola", msg.text);
    // user_message is the driver's to journal when the turn starts, not the transport's.
    try testing.expectEqual(@as(usize, 0), j.count());
    // A bad permission_mode is refused before anything is queued.
    {
        const bad = "{\"text\":\"x\",\"permission_mode\":\"plan\"}";
        var req_buf: [160]u8 = undefined;
        const req = try std.fmt.bufPrint(&req_buf, "POST /message HTTP/1.1\r\nContent-Length: {d}\r\n\r\n{s}", .{ bad.len, bad });
        const resp = try httpRoundtrip(testing.allocator, srv.port, req);
        defer testing.allocator.free(resp);
        try testing.expect(std.mem.indexOf(u8, resp, "400 Bad Request") != null);
        try testing.expect(std.mem.indexOf(u8, resp, "invalid permission_mode") != null);
    }
    try testing.expectEqual(@as(usize, 0), inbox.len());

    // GET /state
    {
        const resp = try httpRoundtrip(testing.allocator, srv.port, "GET /state HTTP/1.1\r\n\r\n");
        defer testing.allocator.free(resp);
        try testing.expect(std.mem.indexOf(u8, resp, "\"model\":\"test\"") != null);
    }
    // 404
    {
        const resp = try httpRoundtrip(testing.allocator, srv.port, "GET /nope HTTP/1.1\r\n\r\n");
        defer testing.allocator.free(resp);
        try testing.expect(std.mem.indexOf(u8, resp, "404") != null);
    }
    // GET / 返回内嵌页面
    {
        const resp = try httpRoundtrip(testing.allocator, srv.port, "GET / HTTP/1.1\r\n\r\n");
        defer testing.allocator.free(resp);
        try testing.expect(std.mem.indexOf(u8, resp, "text/html") != null);
    }
}

test "loopback: /spans serves the session span store as OTLP/JSON, /trace serves the viewer" {
    const telemetry = @import("../telemetry/telemetry.zig");
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(testing.io, &dir_buf)];
    {
        var store = try telemetry.store.SessionStore.init(testing.allocator, dir);
        defer store.deinit();
        const s: telemetry.span.Span = .{
            .trace_id = telemetry.span.TraceId.random(),
            .span_id = telemetry.span.SpanId.random(),
            .name = "invoke_agent metacodes",
            .start_unix_nano = 1,
            .end_unix_nano = 2,
        };
        try store.append(&s);
    }

    var j = EventJournal.init(testing.allocator);
    defer j.deinit();
    var wb = WebBackend.init(testing.allocator, &j);
    defer wb.deinit();
    var inbox = SubmissionQueue.init(testing.allocator);
    defer inbox.deinit();
    var sig = abort_mod.AbortSignal.init();
    const S = struct {
        fn state(_: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
            return allocator.dupe(u8, "{}");
        }
        fn spans(ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
            const d: *[]const u8 = @ptrCast(@alignCast(ctx));
            return telemetry.store.readAsRequest(allocator, d.*, "test");
        }
    };
    var dir_ref: []const u8 = dir;
    const base: Deps = .{
        .journal = &j,
        .web_backend = &wb,
        .inbox = &inbox,
        .abort = &sig,
        .state_ctx = @ptrCast(&dir_ref),
        .state_fn = &S.state,
    };
    {
        var deps = base;
        deps.spans_fn = &S.spans;
        const srv = try WebServer.start(testing.allocator, .{ .version = TEST_VERSION }, deps);
        defer srv.stop();
        const resp = try httpRoundtrip(testing.allocator, srv.port, "GET /spans HTTP/1.1\r\n\r\n");
        defer testing.allocator.free(resp);
        try testing.expect(std.mem.indexOf(u8, resp, "200 OK") != null);
        try testing.expect(std.mem.indexOf(u8, resp, "application/json") != null);
        try testing.expect(std.mem.indexOf(u8, resp, "\"resourceSpans\"") != null);
        try testing.expect(std.mem.indexOf(u8, resp, "\"name\":\"invoke_agent metacodes\"") != null);

        const page = try httpRoundtrip(testing.allocator, srv.port, "GET /trace HTTP/1.1\r\n\r\n");
        defer testing.allocator.free(page);
        try testing.expect(std.mem.indexOf(u8, page, "text/html") != null);
        try testing.expect(std.mem.indexOf(u8, page, "metacodes · trace") != null);
    }
    {
        // A host without span recording answers 404, not an empty trace.
        const srv = try WebServer.start(testing.allocator, .{ .version = TEST_VERSION }, base);
        defer srv.stop();
        const resp = try httpRoundtrip(testing.allocator, srv.port, "GET /spans HTTP/1.1\r\n\r\n");
        defer testing.allocator.free(resp);
        try testing.expect(std.mem.indexOf(u8, resp, "404 Not Found") != null);
    }
}

test "loopback: /interrupt 打 abort;/respond 无挂起 409" {
    var j = EventJournal.init(testing.allocator);
    defer j.deinit();
    var wb = WebBackend.init(testing.allocator, &j);
    defer wb.deinit();
    var inbox = SubmissionQueue.init(testing.allocator);
    defer inbox.deinit();
    var sig = abort_mod.AbortSignal.init();
    const S = struct {
        fn state(_: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
            return allocator.dupe(u8, "{}");
        }
    };
    var dummy: u8 = 0;
    const srv = try WebServer.start(testing.allocator, .{ .version = TEST_VERSION }, .{
        .journal = &j,
        .web_backend = &wb,
        .inbox = &inbox,
        .abort = &sig,
        .state_ctx = @ptrCast(&dummy),
        .state_fn = &S.state,
    });
    defer srv.stop();

    {
        const resp = try httpRoundtrip(testing.allocator, srv.port, "POST /interrupt HTTP/1.1\r\nContent-Length: 0\r\n\r\n");
        defer testing.allocator.free(resp);
        try testing.expect(std.mem.indexOf(u8, resp, "200 OK") != null);
    }
    try testing.expect(sig.isAborted());

    {
        const resp = try httpRoundtrip(testing.allocator, srv.port, "POST /respond HTTP/1.1\r\nContent-Length: 29\r\n\r\n{\"id\":1,\"choice\":\"allow_once\"}");
        defer testing.allocator.free(resp);
        try testing.expect(std.mem.indexOf(u8, resp, "409") != null);
    }
}

test "loopback: SSE 重放已有事件(带 id 帧)" {
    var j = EventJournal.init(testing.allocator);
    defer j.deinit();
    j.append("{\"v\":1,\"type\":\"text_chunk\",\"data\":\"hey\"}");
    var wb = WebBackend.init(testing.allocator, &j);
    defer wb.deinit();
    var inbox = SubmissionQueue.init(testing.allocator);
    defer inbox.deinit();
    var sig = abort_mod.AbortSignal.init();
    const S = struct {
        fn state(_: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
            return allocator.dupe(u8, "{}");
        }
    };
    var dummy: u8 = 0;
    const srv = try WebServer.start(testing.allocator, .{ .version = TEST_VERSION }, .{
        .journal = &j,
        .web_backend = &wb,
        .inbox = &inbox,
        .abort = &sig,
        .state_ctx = @ptrCast(&dummy),
        .state_fn = &S.state,
    });
    defer srv.stop();

    // SSE 是长连接:读到期望内容即断开(close journal 让 server 侧线程收尾)
    defer j.close();
    const resp = try httpRoundtripPartial(testing.allocator, srv.port, "GET /events HTTP/1.1\r\n\r\n", "text_chunk");
    defer testing.allocator.free(resp);
    var frame_buf: [96]u8 = undefined;
    const frame = try std.fmt.bufPrint(&frame_buf, "id: {s}-0\ndata: {{\"v\":1,\"type\":\"text_chunk\"", .{&j.epochHex()});
    try testing.expect(std.mem.indexOf(u8, resp, frame) != null);
    try testing.expect(std.mem.indexOf(u8, resp, "hey") != null);
}

/// 测试辅助:连 127.0.0.1:port,发 raw 请求,读到对端关闭为止(owned)。
fn httpRoundtrip(allocator: std.mem.Allocator, port: u16, raw: []const u8) ![]u8 {
    return httpRoundtripPartial(allocator, port, raw, null);
}

/// until 非空:读到包含该子串即返回(SSE 长连接不会关);null:读到 EOF。
fn httpRoundtripPartial(allocator: std.mem.Allocator, port: u16, raw: []const u8, until: ?[]const u8) ![]u8 {
    const fd = try net.connectLoopback(port);
    defer net.closeSocket(fd);
    // 2s 读超时:失败测试快速失败而非挂死
    net.setRecvTimeoutMs(fd, 2_000);

    var pos: usize = 0;
    while (pos < raw.len) {
        const n = net.send(fd, raw[pos..]);
        if (n <= 0) return error.WriteFailed;
        pos += @intCast(n);
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = net.recv(fd, &chunk);
        if (n <= 0) break;
        try out.appendSlice(allocator, chunk[0..@intCast(n)]);
        if (until) |u| {
            if (std.mem.indexOf(u8, out.items, u) != null) break;
        }
    }
    return out.toOwnedSlice(allocator);
}
