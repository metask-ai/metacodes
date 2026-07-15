//! WebServer —— 最小 HTTP/1.1 + SSE 服务器(std.c socket,127.0.0.1 only)。
//!
//! 职责:把 web 前端的 HTTP 动词翻成协议层动作,自身不懂任何业务语义:
//!   GET  /            → 内嵌 index.html(单页,自包含)
//!   GET  /events      → SSE:重放 journal(?since=N / Last-Event-ID)+ condvar 推新事件
//!   POST /message     → 入 inbox 队列(session driver 消费)+ journal 回显 user_message
//!   POST /respond     → 回填 WebBackend 挂起的 UiRequest({"id":N,...})
//!   POST /interrupt   → 打 AbortSignal(与 TUI esc 同通道)
//!   GET  /state       → session 状态快照(经回调,server 不依赖 App)
//!
//! 线程模型:accept 循环一个线程;每连接一个 detached 线程(SSE 长连接阻塞在
//! journal.waitSince,普通请求即答即关)。allocator 必须线程安全(c_allocator)。
//!
//! 安全边界:只绑 127.0.0.1;无鉴权(本机单用户 MVP,与 TUI 同信任级)。

const std = @import("std");
const time = @import("../util/time.zig");
const journal_mod = @import("journal.zig");
const backend_mod = @import("backend.zig");
const msg_queue_mod = @import("../repl/msg_queue.zig");
const abort_mod = @import("../util/abort.zig");
const log = @import("../util/log.zig");
const net = @import("platform").net;

const EventJournal = journal_mod.EventJournal;
const WebBackend = backend_mod.WebBackend;
const MsgQueue = msg_queue_mod.MsgQueue;

pub const INDEX_HTML: []const u8 = @embedFile("index.html");

/// GET /state 的快照回调:返回 owned JSON(caller free)。server 不依赖 App,
/// 由 session driver 闭合状态来源(model/mode/usage/phase/pending_request)。
pub const StateFn = *const fn (ctx: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8;

/// POST /command 的处理回调(最小 SessionService):cmd = "/compact" / "/mode" / "/model x" …
/// 返回 owned JSON 结果 `{"ok":bool,"message":"…"}`(caller free)。session 闭合 App 状态。
/// **线程**:在 HTTP 连接线程调——session 实现自行判 generating 拒绝会撞 driver 的操作。
pub const CommandFn = *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, cmd: []const u8) anyerror![]u8;

/// server 的借用依赖(session driver 拥有,生命周期须覆盖 server)。
/// **U10-C:一个 session 的 per-request 视图**(handler 用它,而非直接 self.deps)。单 session 模式
/// 从 Deps 直取(singleView);多 session 模式经 resolver 按 /s/<id>/ 的 id 解析。
pub const SessionView = struct {
    journal: *EventJournal,
    web_backend: *WebBackend,
    inbox: *MsgQueue,
    abort: *abort_mod.AbortSignal,
    generating: ?*const std.atomic.Value(bool) = null,
    state_ctx: *anyopaque,
    state_fn: StateFn,
    command_fn: ?CommandFn = null,
};

pub const Deps = struct {
    journal: *EventJournal,
    web_backend: *WebBackend,
    inbox: *MsgQueue,
    /// 中断信号。**语义 = 中断当前生成**,不是退出进程——/interrupt 只在 generating
    /// 时打它(见 route);进程退出属于宿主(SIGINT/driver),不给浏览器这个权力。
    abort: *abort_mod.AbortSignal,
    /// 生成期标志(driver 维护)。null = 无门(单测直连 abort 的场景)。
    generating: ?*const std.atomic.Value(bool) = null,
    state_ctx: *anyopaque,
    state_fn: StateFn,
    /// 斜杠命令处理(可空:单测不接)。ctx 复用 state_ctx。
    command_fn: ?CommandFn = null,
    /// **U10-C:多 session 解析器**。非 null 时,路径 `/s/<id>/rest` 按 id 解析 SessionView(null=未知
    /// session→404);无 /s/ 前缀的非 `/` 路径→404。null=单 session 模式(--web,直用上面字段,向后兼容)。
    ///
    /// **⚠️ 生命周期契约(PM/Linus review,必守)**:返回的 SessionView 是 **borrow 快照**(裸指针指向
    /// 该 session 的 journal/inbox/wb/abort)。handler 在**整个请求期**持这些指针——**尤其 serveSse 阻塞
    /// waitSinceFrom 最多 15s**。故 resolver **必须保证:被解析的 session 活过所有在飞请求**,即 host
    /// 绝不可在某连接持其指针时被 destroy。**MVP 满足此约束靠 session 静态**(fixed-N at startup,无
    /// per-session destroy);引入 dynamic destroy / idle-reap 前**必须**先把签名改成 refcount handle /
    /// lock-hold(见 doc/U9_U10_DAEMON_TIER_DESIGN.md §4)。否则 = 重现 U10-A 删掉的 borrow-UAF。
    resolver: ?*const fn (ctx: *anyopaque, id: []const u8) ?SessionView = null,
    resolver_ctx: *anyopaque = undefined,
};

pub const WebServer = struct {
    /// 必须线程安全(连接线程并发分配)。
    allocator: std.mem.Allocator,
    listen_fd: net.Socket,
    port: u16,
    accept_thread: std.Thread = undefined,
    /// 活跃连接线程数(detached)。stop() 等它归零再释放 self——否则连接线程
    /// 还在摸 self.deps 时资源已被 deinit(UAF)。
    live_conns: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    /// stop() 已发起:acceptLoop 唯一的退出依据。stop 先置它再 close(listen_fd),
    /// accept 返 -1 时据它区分"主动关闭(退出)"vs"瞬时错误 EINTR/ECONNABORTED/
    /// EMFILE(continue 重试)"——否则一次瞬时错误就让 server 永久哑掉。
    closing: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    deps: Deps,

    /// 绑 127.0.0.1:port(0 = 内核分配,读回真实端口)并起 accept 线程。
    pub fn start(allocator: std.mem.Allocator, port: u16, deps: Deps) !*WebServer {
        // 可移植 loopback listen(POSIX socket/Windows WSAStartup+ws2_32),内部含 REUSEADDR+getsockname。
        const l = try net.listenLoopback(port, 16);
        errdefer net.closeSocket(l.sock);

        const self = try allocator.create(WebServer);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .listen_fd = l.sock,
            .port = l.port,
            .deps = deps,
        };
        self.accept_thread = try std.Thread.spawn(.{}, acceptLoop, .{self});
        return self;
    }

    /// 关 listen fd(accept 返负退出)+ join + 等连接线程归零。SSE 连接线程靠
    /// journal.close() 醒来收尾——调用方(session driver)须**先 close journal 再 stop**。
    pub fn stop(self: *WebServer) void {
        self.closing.store(true, .release); // 先标记再 close:accept 醒来据它判定主动退出
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
            // 兜底(理论上不达:12s > socket 超时)。宁泄漏 self 不 UAF——但 deps 仍会被
            // run() 释放,故此路径只应在真·线程 hang(非超时可醒)时触发,已属未定义环境。
            log.warn("web", "stop: {d} connection thread(s) still live after 12s, leaking WebServer", .{self.live_conns.load(.acquire)});
            return;
        }
        self.allocator.destroy(self);
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

        const head = buf[0..(he - 4)];
        const body = buf[he..total];
        const line = parseRequestLine(head) orelse {
            writeSimple(fd, "400 Bad Request", "application/json", "{\"error\":\"bad request line\"}");
            return;
        };

        self.route(fd, line, head, body);
    }

    fn route(self: *WebServer, fd: net.Socket, line: RequestLine, head: []const u8, body: []const u8) void {
        // CSRF 防线:状态变更(POST)必须同源。浏览器跨域 POST 强制带 Origin 头——
        // 恶意网页 fetch('http://127.0.0.1:<port>/message',{method:'POST'}) 是简单请求、
        // 能发出(读不到响应但副作用已生效:让模型跑命令、抢答权限对话框)。检查 Origin
        // 挡掉它;无 Origin(curl/非浏览器 CLI)放行——浏览器一定带,缺失即非浏览器。
        // 读端点(GET /events /state)靠浏览器 CORS 挡:不发 CORS 头 → 跨域读不到响应。
        if (std.mem.eql(u8, line.method, "POST") and !originAllowed(head, self.port)) {
            writeSimple(fd, "403 Forbidden", "application/json", "{\"error\":\"cross-origin POST rejected\"}");
            return;
        }
        if (std.mem.eql(u8, line.method, "GET") and std.mem.eql(u8, line.path, "/")) {
            writeSimple(fd, "200 OK", "text/html; charset=utf-8", INDEX_HTML);
            return;
        }
        // U10-C:解析 session view + 有效路径。单 session(resolver=null)直取 self.deps(向后兼容
        // --web);多 session 路径 /s/<id>/rest 经 resolver 按 id 解析(未知→404),rest 作有效路径。
        var eff_path = line.path;
        var sv: SessionView = undefined;
        if (self.deps.resolver) |r| {
            const sp = parseSessionPrefix(line.path) orelse {
                writeSimple(fd, "404 Not Found", "application/json", "{\"error\":\"session path required (/s/<id>/...)\"}");
                return;
            };
            sv = r(self.deps.resolver_ctx, sp.id) orelse {
                writeSimple(fd, "404 Not Found", "application/json", "{\"error\":\"unknown session\"}");
                return;
            };
            eff_path = sp.rest;
        } else {
            sv = self.singleView();
        }

        if (std.mem.eql(u8, line.method, "GET") and std.mem.eql(u8, eff_path, "/events")) {
            self.serveSse(fd, line, head, sv);
            return;
        }
        if (std.mem.eql(u8, line.method, "POST") and std.mem.eql(u8, eff_path, "/message")) {
            const text = extractMessageText(self.allocator, body) orelse {
                writeSimple(fd, "400 Bad Request", "application/json", "{\"error\":\"empty message\"}");
                return;
            };
            defer self.allocator.free(text);
            // 回显先于入队:浏览器(含其它标签页)立刻看到已提交的消息,即使正在生成期排队。
            const echo = std.json.Stringify.valueAlloc(self.allocator, .{ .user_message = text }, .{}) catch null;
            if (echo) |e| {
                defer self.allocator.free(e);
                sv.journal.append(e);
            }
            if (!sv.inbox.push(text)) {
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
        return .{
            .journal = self.deps.journal,
            .web_backend = self.deps.web_backend,
            .inbox = self.deps.inbox,
            .abort = self.deps.abort,
            .generating = self.deps.generating,
            .state_ctx = self.deps.state_ctx,
            .state_fn = self.deps.state_fn,
            .command_fn = self.deps.command_fn,
        };
    }

    /// SSE 长连接:从 since 重放 + 阻塞推新。since 来源优先级:?since=N > Last-Event-ID 头 > 0。
    /// id 语义:该行的 seq(0-based);浏览器重连带 Last-Event-ID=最后收到的 seq → 从 seq+1 续。
    fn serveSse(self: *WebServer, fd: net.Socket, line: RequestLine, head: []const u8, sv: SessionView) void {
        var since = resolveSince(line.query, head);

        if (!writeAll(fd, "HTTP/1.1 200 OK\r\n" ++
            "Content-Type: text/event-stream\r\n" ++
            "Cache-Control: no-cache\r\n" ++
            "Connection: keep-alive\r\n\r\n" ++
            "retry: 1000\n\n")) return;

        while (true) {
            // U7:waitSinceFrom 报出 effective start(批次首行逻辑 seq)。若 > since,说明
            // [since, start) 已被环形淘汰(客户端落后保留窗)→ 发 resync 让客户端重拉 /state
            // (config/roster 幂等可重建;丢的是瞬态渲染事件)。frame id 用 start+i(逻辑 seq)。
            var eff_start: usize = since;
            const batch = sv.journal.waitSinceFrom(self.allocator, since, 15_000, &eff_start) catch return;
            if (eff_start > since) {
                const rsx = std.fmt.allocPrint(self.allocator, "event: resync\ndata: {{\"dropped_to\":{d}}}\n\n", .{eff_start}) catch return;
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
                    const frame = std.fmt.allocPrint(self.allocator, "id: {d}\ndata: {s}\n\n", .{ since + i, l }) catch return;
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

/// CSRF 门:POST 的 Origin 必须是本机同源(http://127.0.0.1:<port> 或 localhost),
/// 或无 Origin(非浏览器客户端)。返回 true=放行。
/// 只做前缀+端口精确匹配,不解析 URL——Origin 无路径,形如 "scheme://host:port"。
/// U10-C:从 `/s/<id>/rest` 解析 {id, rest}(rest 含前导 /)。非此前缀 / id 空 / 无 rest → null。
pub fn parseSessionPrefix(path: []const u8) ?struct { id: []const u8, rest: []const u8 } {
    const pfx = "/s/";
    if (!std.mem.startsWith(u8, path, pfx)) return null;
    const after = path[pfx.len..];
    const slash = std.mem.indexOfScalar(u8, after, '/') orelse return null; // 必须有 id 后的 /rest
    if (slash == 0) return null; // 空 id
    return .{ .id = after[0..slash], .rest = after[slash..] };
}

pub fn originAllowed(head: []const u8, port: u16) bool {
    const origin = headerValue(head, "origin") orelse return true; // 无 Origin=非浏览器,放行
    var buf: [64]u8 = undefined;
    const o1 = std.fmt.bufPrint(&buf, "http://127.0.0.1:{d}", .{port}) catch return false;
    if (std.mem.eql(u8, origin, o1)) return true;
    var buf2: [64]u8 = undefined;
    const o2 = std.fmt.bufPrint(&buf2, "http://localhost:{d}", .{port}) catch return false;
    return std.mem.eql(u8, origin, o2);
}

/// SSE 起点 seq。优先 ?since=N;否则 Last-Event-ID 头(重连,取该 seq+1);都无 = 0。
/// **saturating +1**:Last-Event-ID 来自客户端(可伪造 usize max),`l+1` 裸加会溢出
/// panic 整个 daemon(与 body 413 溢出同类)。`+|` 饱和到 max → waitSince 恒等待,坏
/// 输入自食其果,不崩进程。
pub fn resolveSince(query: []const u8, head: []const u8) usize {
    if (queryParam(query, "since")) |s| {
        return std.fmt.parseInt(usize, s, 10) catch 0;
    }
    if (headerValue(head, "last-event-id")) |s| {
        const last = std.fmt.parseInt(usize, s, 10) catch return 0;
        return last +| 1;
    }
    return 0;
}

// ── 纯函数(可单测)─────────────────────────────────────────────────────────

pub const RequestLine = struct {
    method: []const u8,
    path: []const u8,
    query: []const u8, // 不含 '?';无 query = ""
};

/// 解析 "METHOD /path?query HTTP/1.1"(head 的第一行)。
pub fn parseRequestLine(head: []const u8) ?RequestLine {
    const eol = std.mem.indexOf(u8, head, "\r\n") orelse head.len;
    const first = head[0..eol];
    var it = std.mem.splitScalar(u8, first, ' ');
    const method = it.next() orelse return null;
    const target = it.next() orelse return null;
    if (method.len == 0 or target.len == 0) return null;
    if (std.mem.indexOfScalar(u8, target, '?')) |q| {
        return .{ .method = method, .path = target[0..q], .query = target[q + 1 ..] };
    }
    return .{ .method = method, .path = target, .query = "" };
}

/// 从 "a=1&b=2" 里取 name 的值(不做 URL decode——本服务 query 只有数字参数)。
pub fn queryParam(query: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.ascii.eqlIgnoreCase(pair[0..eq], name)) return pair[eq + 1 ..];
    }
    return null;
}

/// 大小写不敏感取 header 值(trim 前导空白)。
pub fn headerValue(head: []const u8, name: []const u8) ?[]const u8 {
    var it = std.mem.splitSequence(u8, head, "\r\n");
    _ = it.next(); // 跳请求行
    while (it.next()) |h| {
        const colon = std.mem.indexOfScalar(u8, h, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(h[0..colon], name)) continue;
        return std.mem.trim(u8, h[colon + 1 ..], " \t");
    }
    return null;
}

pub fn parseContentLength(head: []const u8) ?usize {
    const v = headerValue(head, "content-length") orelse return null;
    return std.fmt.parseInt(usize, v, 10) catch null;
}

/// POST /message body → 文本(owned by allocator,caller free)。
/// JSON {"text":"..."} 优先(转义已由 parser 解开,多行消息 OK);非 JSON 时整个 body 当纯文本。
/// 空文本(trim 后)/ JSON object 无 text 字段 → null。
pub fn extractMessageText(allocator: std.mem.Allocator, body: []const u8) ?[]u8 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    if (std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), body, .{})) |v| {
        if (v == .object) {
            if (v.object.get("text")) |t| {
                if (t == .string) return dupeTrimmedOrNull(allocator, t.string);
            }
            return null; // 是 JSON object 但没有 text 字段 → 视为坏请求
        }
    } else |_| {}
    return dupeTrimmedOrNull(allocator, body);
}

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

fn writeSimple(fd: net.Socket, comptime status: []const u8, comptime content_type: []const u8, body: []const u8) void {
    var head_buf: [256]u8 = undefined;
    const head = std.fmt.bufPrint(&head_buf, "HTTP/1.1 " ++ status ++ "\r\n" ++
        "Content-Type: " ++ content_type ++ "\r\n" ++
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

test "originAllowed: 同源放行 / 无 Origin 放行(CLI)/ 跨域拒绝(CSRF)" {
    // 无 Origin(curl):放行
    try testing.expect(originAllowed("POST /message HTTP/1.1\r\nHost: x", 7777));
    // 同源 127.0.0.1:放行
    try testing.expect(originAllowed("POST /m HTTP/1.1\r\nOrigin: http://127.0.0.1:7777", 7777));
    // 同源 localhost:放行
    try testing.expect(originAllowed("POST /m HTTP/1.1\r\nOrigin: http://localhost:7777", 7777));
    // 跨域恶意页:拒绝(CSRF 防线)
    try testing.expect(!originAllowed("POST /m HTTP/1.1\r\nOrigin: http://evil.com", 7777));
    // 同 host 错端口:拒绝(端口精确匹配)
    try testing.expect(!originAllowed("POST /m HTTP/1.1\r\nOrigin: http://127.0.0.1:1234", 7777));
    // https 混淆:拒绝(scheme 精确)
    try testing.expect(!originAllowed("POST /m HTTP/1.1\r\nOrigin: https://127.0.0.1:7777", 7777));
}

test "resolveSince: ?since 优先 / Last-Event-ID+1 / 恶意 usize max 饱和不溢出" {
    // ?since 直接用
    try testing.expectEqual(@as(usize, 42), resolveSince("since=42", "GET /events?since=42 HTTP/1.1"));
    // Last-Event-ID → +1(重连续传)
    try testing.expectEqual(@as(usize, 10), resolveSince("", "GET /events HTTP/1.1\r\nLast-Event-ID: 9"));
    // P1-B 回归:恶意 Last-Event-ID = usize max,+| 饱和不 panic
    try testing.expectEqual(std.math.maxInt(usize), resolveSince("", "GET /events HTTP/1.1\r\nLast-Event-ID: 18446744073709551615"));
    // 都无 → 0(全量重放)
    try testing.expectEqual(@as(usize, 0), resolveSince("", "GET /events HTTP/1.1"));
    // 坏 since → 0
    try testing.expectEqual(@as(usize, 0), resolveSince("since=abc", "GET /events HTTP/1.1"));
}

test "queryParam / headerValue / parseContentLength" {
    try testing.expectEqualStrings("42", queryParam("a=1&since=42", "since").?);
    try testing.expectEqual(@as(?[]const u8, null), queryParam("a=1", "since"));
    const head = "GET / HTTP/1.1\r\nContent-Length: 17\r\nLast-Event-ID:  9";
    try testing.expectEqual(@as(usize, 17), parseContentLength(head).?);
    try testing.expectEqualStrings("9", headerValue(head, "last-event-id").?);
}

test "extractMessageText: JSON text 字段(含转义多行)/ 纯文本 / 空拒绝" {
    const a = extractMessageText(testing.allocator, "{\"text\":\"hi there\"}").?;
    defer testing.allocator.free(a);
    try testing.expectEqualStrings("hi there", a);
    const b = extractMessageText(testing.allocator, "{\"text\":\"line1\\nline2\"}").?;
    defer testing.allocator.free(b);
    try testing.expectEqualStrings("line1\nline2", b);
    const c = extractMessageText(testing.allocator, "raw body").?;
    defer testing.allocator.free(c);
    try testing.expectEqualStrings("raw body", c);
    try testing.expectEqual(@as(?[]u8, null), extractMessageText(testing.allocator, "   "));
    try testing.expectEqual(@as(?[]u8, null), extractMessageText(testing.allocator, "{\"nottext\":1}"));
}

test "extractRespondId" {
    try testing.expectEqual(@as(u64, 7), extractRespondId("{\"id\":7,\"choice\":\"allow_once\"}").?);
    try testing.expectEqual(@as(?u64, null), extractRespondId("{\"choice\":\"x\"}"));
    try testing.expectEqual(@as(?u64, null), extractRespondId("junk"));
}

test "loopback: /message 入队+回显, /state 快照, 404" {
    var j = EventJournal.init(testing.allocator);
    defer j.deinit();
    var wb = WebBackend.init(testing.allocator, &j);
    defer wb.deinit();
    var inbox = MsgQueue.init(testing.allocator);
    defer inbox.deinit();
    var sig = abort_mod.AbortSignal.init();
    const S = struct {
        fn state(_: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
            return allocator.dupe(u8, "{\"model\":\"test\"}");
        }
    };
    var dummy: u8 = 0;
    const srv = try WebServer.start(testing.allocator, 0, .{
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
    const msg = inbox.popFront().?;
    defer testing.allocator.free(msg);
    try testing.expectEqualStrings("hola", msg);
    // journal 有 user_message 回显
    const batch = (try j.waitSince(testing.allocator, 0, 100)).?;
    defer {
        for (batch) |l| testing.allocator.free(l);
        testing.allocator.free(batch);
    }
    try testing.expect(std.mem.indexOf(u8, batch[0], "user_message") != null);
    try testing.expect(std.mem.indexOf(u8, batch[0], "hola") != null);

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

test "loopback: /interrupt 打 abort;/respond 无挂起 409" {
    var j = EventJournal.init(testing.allocator);
    defer j.deinit();
    var wb = WebBackend.init(testing.allocator, &j);
    defer wb.deinit();
    var inbox = MsgQueue.init(testing.allocator);
    defer inbox.deinit();
    var sig = abort_mod.AbortSignal.init();
    const S = struct {
        fn state(_: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
            return allocator.dupe(u8, "{}");
        }
    };
    var dummy: u8 = 0;
    const srv = try WebServer.start(testing.allocator, 0, .{
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
    j.append("{\"core_event\":{\"text_chunk\":\"hey\"}}");
    var wb = WebBackend.init(testing.allocator, &j);
    defer wb.deinit();
    var inbox = MsgQueue.init(testing.allocator);
    defer inbox.deinit();
    var sig = abort_mod.AbortSignal.init();
    const S = struct {
        fn state(_: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
            return allocator.dupe(u8, "{}");
        }
    };
    var dummy: u8 = 0;
    const srv = try WebServer.start(testing.allocator, 0, .{
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
    try testing.expect(std.mem.indexOf(u8, resp, "id: 0\ndata: {\"core_event\"") != null);
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
