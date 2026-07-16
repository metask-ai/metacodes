//! Mock SSE server：起一个 127.0.0.1 监听、accept 一次、写 HTTP 200 + 固定 SSE body，关闭。
//!
//! 用途：
//!   L3 集成测试（http_stream_e2e_test 等）已用 — 发响应,不验证请求体。
//!   L2 组件测试（doc/E2E_TESTING.md）— 用 lastRequest()/CapturedRequest 断言请求体字段贯穿。
//!
//! 设计：同步，在调用线程起个辅助 std.Thread 跑 accept 循环；调用方拿到 port 后连接它。
//! 本期最小可用——不支持多连接、不支持请求路由（所有请求返回同一 body）、不支持 keep-alive。
//!
//! socket 层走 `platform/net`(POSIX + Winsock 双后端,keystone 真机测过)——不要在这里
//! 裸调 std.c socket API:std.c 的 fd_t/sockaddr 在 Windows 类型不同,直接用会编不过。

const std = @import("std");
const net = @import("platform").net;
const psync = @import("platform").sync;

pub const MockServer = struct {
    listen_sock: net.Socket,
    port: u16,
    thread: std.Thread,
    body: []const u8,
    /// 每个 SSE event（\n\n 分隔）之间的 sleep，用于模拟慢流
    chunk_delay_ms: u32 = 0,
    /// HTTP 状态行。默认 200 OK(走 chunked SSE)。非 200 时 sendResponse 发纯 body
    /// (application/json,非 chunked)——用于 Stage 6 HTTP 错误现场 L2(401/429/5xx)。
    status_line: []const u8 = "HTTP/1.1 200 OK",
    /// 捕获的请求 raw bytes(headers + body,完整 HTTP 请求)。serveOne 写入,lastRequest 读取。
    /// page_allocator 分配,stop 释放。
    captured_buf: ?[]u8 = null,
    captured_len: usize = 0,
    /// captured_buf 是否已写完(serveOne 写完后置 1)。读端用 .acquire 确保看到完整 buf。
    captured_ready: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    /// cassette 模式:多轮 SSE bodies(每个连接回一条,按序)。null = 单 body 模式。
    cassette: ?[]const []const u8 = null,
    /// cassette 当前轮游标(serveLoop 递增)。
    cassette_pos: usize = 0,
    /// flaky 模式:前 N 个连接读完请求后直接 close 不写响应(模拟服务端建连阶段断连,
    /// 客户端 receiveHead 拿到 ConnectionClosing/EOF)。serveLoop 每断一次递减,归 0 后正常服务。
    flaky_close_remaining: usize = 0,
    /// 停机标志:stop() 先置位、再自连唤醒 accept。Windows 上 closesocket **不可靠唤醒**
    /// 已阻塞的 accept(实测 join 永挂,竞态:线程先进 accept 则挂);POSIX close 同样无保证。
    /// 自连是跨平台确定性唤醒;accept 线程醒来见标志立即退出。
    closing: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn start(body: []const u8, chunk_delay_ms: u32) !*MockServer {
        return startWithStatus(body, chunk_delay_ms, "HTTP/1.1 200 OK");
    }

    /// 起 server 并指定 HTTP 状态行。status_line 非 "...200 OK" 时,sendResponse 发纯 body
    /// (application/json,非 chunked SSE),让客户端的错误分支读到 body。
    /// 用于 Stage 6 L2:`startWithStatus("{\"error\":...}", 0, "HTTP/1.1 401 Unauthorized")`。
    pub fn startWithStatus(body: []const u8, chunk_delay_ms: u32, status_line: []const u8) !*MockServer {
        const listener = try net.listenLoopback(0, 1);
        errdefer net.closeSocket(listener.sock);

        const self = try std.heap.page_allocator.create(MockServer);
        self.* = .{
            .listen_sock = listener.sock,
            .port = listener.port,
            .thread = undefined,
            .body = body,
            .chunk_delay_ms = chunk_delay_ms,
            .status_line = status_line,
        };
        self.thread = try std.Thread.spawn(.{}, serveOne, .{self});
        return self;
    }

    /// cassette 模式:多轮回放。每个进来的连接回 bodies[i](i 递增),耗尽后回最后一条。
    /// 用于 record/replay(Stage 7):agent loop 多轮 tool-use,每轮一个 HTTP 请求。
    /// backlog 设大些以容纳并发连接。bodies 借用 caller(server 存活期间必须有效)。
    pub fn startCassette(bodies: []const []const u8, chunk_delay_ms: u32) !*MockServer {
        const listener = try net.listenLoopback(0, 16);
        errdefer net.closeSocket(listener.sock);

        const self = try std.heap.page_allocator.create(MockServer);
        self.* = .{
            .listen_sock = listener.sock,
            .port = listener.port,
            .thread = undefined,
            .body = if (bodies.len > 0) bodies[bodies.len - 1] else "",
            .chunk_delay_ms = chunk_delay_ms,
            .cassette = bodies,
        };
        self.thread = try std.Thread.spawn(.{}, serveLoop, .{self});
        return self;
    }

    /// flaky 模式:前 close_first_n 个连接读完请求后直接断开(不写响应),之后正常回 body。
    /// 用于测试网络瞬态错误重试:客户端前 N 次 receiveHead 失败、第 N+1 次成功。
    /// close_first_n 很大(如 99)= 永远断,测重试耗尽。body 借用 caller(server 存活期间有效)。
    pub fn startFlaky(body: []const u8, close_first_n: usize) !*MockServer {
        const listener = try net.listenLoopback(0, 16);
        errdefer net.closeSocket(listener.sock);

        const self = try std.heap.page_allocator.create(MockServer);
        self.* = .{
            .listen_sock = listener.sock,
            .port = listener.port,
            .thread = undefined,
            .body = body,
            .flaky_close_remaining = close_first_n,
        };
        self.thread = try std.Thread.spawn(.{}, serveLoop, .{self});
        return self;
    }

    pub fn stop(self: *MockServer) void {
        // 停机三步:置 closing → **自连唤醒**可能阻塞在 accept 的服务线程 → 关 listen socket → join。
        // 只靠 closeSocket 唤醒阻塞中的 accept 在 Windows/POSIX 都无保证(Windows 实测竞态挂死),
        // 自连是跨平台确定性唤醒;线程醒来见 closing 标志立即退出。
        self.closing.store(true, .release);
        // 有限重试自连(review-2 F11):backlog 满等病态下单次 connect 可能失败,而 fallback
        // 的裸 closeSocket 恰是"不可靠唤醒"那条路——重试三次把确定性兜住;全失败仍走 close
        // (此时线程极大概率已不在 accept 上)。
        var wake_try: u8 = 0;
        while (wake_try < 3) : (wake_try += 1) {
            if (net.connectLoopback(self.port)) |wake| {
                net.closeSocket(wake);
                break;
            } else |_| {}
        }
        net.closeSocket(self.listen_sock);
        self.thread.join();
        if (self.captured_buf) |buf| std.heap.page_allocator.free(buf);
        std.heap.page_allocator.destroy(self);
    }

    /// 取最近一次收到的请求(raw HTTP)。返回的 slice 借用 self,server 存活期间有效。
    /// 调用前应确保 serveOne 已完成(即客户端已读完响应)。返回 null = 还没收到请求。
    pub fn lastRequest(self: *MockServer) ?CapturedRequest {
        if (self.captured_ready.load(.acquire) == 0) return null;
        const buf = self.captured_buf orelse return null;
        const raw = buf[0..self.captured_len];
        return CapturedRequest{ .raw = raw };
    }

    /// 返回形如 "http://127.0.0.1:<port>/v1/messages" 的 URL（allocator-owned）
    pub fn urlOwned(self: *const MockServer, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/v1/messages", .{self.port});
    }

    fn serveOne(self: *MockServer) void {
        const conn = net.acceptConn(self.listen_sock) orelse return;
        defer net.closeSocket(conn);
        if (self.closing.load(.acquire)) return; // stop() 的自连唤醒,不是真请求

        // 读完整请求(headers + body)到 captured_buf。
        // 算法:recv 直到看见 \r\n\r\n,然后根据 Content-Length 读余下 body。
        const cap: usize = 64 * 1024;
        const buf = std.heap.page_allocator.alloc(u8, cap) catch {
            sendResponse(conn, self);
            return;
        };

        const total = readRequest(conn, buf);

        self.captured_buf = buf;
        self.captured_len = total;
        self.captured_ready.store(1, .release);

        sendResponse(conn, self);
    }

    /// cassette 多轮:循环 accept,每个连接读请求 + 回 cassette[pos](pos 递增,
    /// 耗尽用最后一条)。listen_sock 关闭时 accept 失败,循环退出。
    fn serveLoop(self: *MockServer) void {
        while (true) {
            const conn = net.acceptConn(self.listen_sock) orelse return; // listen_sock 已关闭(stop)
            if (self.closing.load(.acquire)) {
                net.closeSocket(conn); // stop() 的自连唤醒,不是真请求
                return;
            }
            // 选本轮 body
            const bodies = self.cassette orelse &[_][]const u8{self.body};
            const idx = @min(self.cassette_pos, bodies.len - 1);
            self.body = bodies[idx];
            self.cassette_pos += 1;

            // 读请求(同 serveOne)
            const cap: usize = 64 * 1024;
            const buf = std.heap.page_allocator.alloc(u8, cap) catch {
                sendResponse(conn, self);
                net.closeSocket(conn);
                continue;
            };
            const total = readRequest(conn, buf);

            // 记录最近一次请求(覆盖式;cassette 模式主要关心回放,捕获取最后一轮)
            if (self.captured_buf) |old| std.heap.page_allocator.free(old);
            self.captured_buf = buf;
            self.captured_len = total;
            self.captured_ready.store(1, .release);

            // flaky:前 N 个连接读完请求后直接断开(不写响应)→ 客户端 receiveHead 失败。
            if (self.flaky_close_remaining > 0) {
                self.flaky_close_remaining -= 1;
                net.closeSocket(conn);
                continue;
            }

            sendResponse(conn, self);
            net.closeSocket(conn);
        }
    }

    /// 读一个完整 HTTP 请求(headers + Content-Length body)进 buf,返回读到的总字节数。
    /// serveOne/serveLoop 原本各自一份,收敛成一份。
    fn readRequest(conn: net.Socket, buf: []u8) usize {
        const cap = buf.len;
        var total: usize = 0;
        var headers_end: ?usize = null;
        var content_length: usize = 0;
        while (total < cap and headers_end == null) {
            const n = net.recv(conn, buf[total..]);
            if (n <= 0) break;
            total += @intCast(n);
            if (std.mem.indexOf(u8, buf[0..total], "\r\n\r\n")) |i| {
                headers_end = i + 4;
                content_length = parseContentLength(buf[0..i]);
            }
        }
        if (headers_end) |he| {
            while (total < cap and (total - he) < content_length) {
                const need = content_length - (total - he);
                const want = @min(need, cap - total);
                if (want == 0) break;
                const n = net.recv(conn, buf[total..][0..want]);
                if (n <= 0) break;
                total += @intCast(n);
            }
        }
        return total;
    }

    fn sendResponse(conn: net.Socket, self: *MockServer) void {
        // 非 200:发纯 body(application/json,Content-Length),不走 chunked SSE。
        // 让客户端的 HTTP 错误分支(logErrorBody)能读到 body。
        if (std.mem.indexOf(u8, self.status_line, "200") == null) {
            var hdr_buf: [256]u8 = undefined;
            const hdr = std.fmt.bufPrint(&hdr_buf, "{s}\r\ncontent-type: application/json\r\ncontent-length: {d}\r\nconnection: close\r\n\r\n", .{ self.status_line, self.body.len }) catch return;
            sendAll(conn, hdr);
            sendAll(conn, self.body);
            return;
        }

        const header =
            "HTTP/1.1 200 OK\r\n" ++
            "content-type: text/event-stream\r\n" ++
            "cache-control: no-cache\r\n" ++
            "transfer-encoding: chunked\r\n" ++
            "connection: close\r\n\r\n";
        sendAll(conn, header);

        var cursor: usize = 0;
        while (cursor < self.body.len) {
            const end = std.mem.indexOfPos(u8, self.body, cursor, "\n\n") orelse self.body.len;
            const chunk_end = @min(end + 2, self.body.len);
            const chunk = self.body[cursor..chunk_end];
            writeChunk(conn, chunk);
            cursor = chunk_end;
            if (self.chunk_delay_ms > 0) {
                psync.sleepMs(self.chunk_delay_ms);
            }
        }
        sendAll(conn, "0\r\n\r\n");
    }

    fn writeChunk(conn: net.Socket, bytes: []const u8) void {
        var hex_buf: [32]u8 = undefined;
        const hdr = std.fmt.bufPrint(&hex_buf, "{x}\r\n", .{bytes.len}) catch return;
        sendAll(conn, hdr);
        sendAll(conn, bytes);
        sendAll(conn, "\r\n");
    }

    fn parseContentLength(headers: []const u8) usize {
        const targets = [_][]const u8{ "Content-Length:", "content-length:", "CONTENT-LENGTH:" };
        for (targets) |t| {
            if (std.mem.indexOf(u8, headers, t)) |idx| {
                var p = idx + t.len;
                while (p < headers.len and (headers[p] == ' ' or headers[p] == '\t')) : (p += 1) {}
                var e = p;
                while (e < headers.len and headers[e] >= '0' and headers[e] <= '9') : (e += 1) {}
                if (e > p) return std.fmt.parseInt(usize, headers[p..e], 10) catch 0;
            }
        }
        return 0;
    }
};

/// 发完整 buffer(send 可能部分写,循环补齐)。失败(对端断开)静默返回——mock 语境
/// 下客户端提前断开是合法场景,server 不需要区分。
fn sendAll(conn: net.Socket, bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = net.send(conn, bytes[off..]);
        if (n <= 0) return;
        off += @intCast(n);
    }
}

/// 测试客户端:连 127.0.0.1:port,发 raw bytes,读响应直到 until 出现(null = 读到对端关闭)。
/// 返回 allocator-owned 响应字节。recv 设 5s 超时,server 不 close 也不会挂死测试。
/// auth_test / web_ui_test / 本文件自测共用——不要在测试里再手写裸 socket 客户端。
pub fn clientRoundtrip(a: std.mem.Allocator, port: u16, raw: []const u8, until: ?[]const u8) ![]u8 {
    const conn = net.connectLoopback(port) catch return error.ConnectFailed;
    defer net.closeSocket(conn);
    net.setRecvTimeoutMs(conn, 5000);

    var pos: usize = 0;
    while (pos < raw.len) {
        const n = net.send(conn, raw[pos..]);
        if (n <= 0) return error.WriteFailed;
        pos += @intCast(n);
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var chunk: [4096]u8 = undefined;
    while (true) {
        const n = net.recv(conn, &chunk);
        if (n <= 0) break;
        try out.appendSlice(a, chunk[0..@intCast(n)]);
        if (until) |u| {
            if (std.mem.indexOf(u8, out.items, u) != null) break;
        }
    }
    return out.toOwnedSlice(a);
}

/// 捕获到的 HTTP 请求(raw bytes,含 headers + body)。
pub const CapturedRequest = struct {
    /// 整段 HTTP 请求(borrowed from MockServer)。
    raw: []const u8,

    /// 提取 body(headers 后的 "\r\n\r\n" 之后)。返回 borrowed slice。
    pub fn body(self: *const CapturedRequest) []const u8 {
        const sep = "\r\n\r\n";
        const idx = std.mem.indexOf(u8, self.raw, sep) orelse return "";
        return self.raw[idx + sep.len ..];
    }

    /// 简易顶层 JSON 字段提取:body 必须是 `{...}`,key 必须在顶层。
    /// 仅供 L2 测试断言用,不是通用 JSON parser。返回 borrowed slice(包含引号 / 数字 / 布尔)。
    /// 找不到返 null。
    pub fn jsonField(self: *const CapturedRequest, key: []const u8) ?[]const u8 {
        const b = self.body();
        var pat_buf: [128]u8 = undefined;
        if (key.len + 4 > pat_buf.len) return null;
        pat_buf[0] = '"';
        @memcpy(pat_buf[1..][0..key.len], key);
        pat_buf[1 + key.len] = '"';
        pat_buf[2 + key.len] = ':';
        const pat = pat_buf[0 .. 3 + key.len];
        const idx = std.mem.indexOf(u8, b, pat) orelse return null;
        var p = idx + pat.len;
        while (p < b.len and (b[p] == ' ' or b[p] == '\t')) : (p += 1) {}
        if (p >= b.len) return null;
        const start = p;
        const c = b[p];
        if (c == '"') {
            p += 1;
            while (p < b.len) : (p += 1) {
                if (b[p] == '\\') {
                    p += 1;
                    continue;
                }
                if (b[p] == '"') {
                    p += 1;
                    break;
                }
            }
            return b[start..p];
        }
        if (c == '{' or c == '[') {
            const open = c;
            const close: u8 = if (c == '{') '}' else ']';
            var depth: usize = 1;
            p += 1;
            var in_str = false;
            while (p < b.len) : (p += 1) {
                const ch = b[p];
                if (in_str) {
                    if (ch == '\\') {
                        p += 1;
                        continue;
                    }
                    if (ch == '"') in_str = false;
                    continue;
                }
                if (ch == '"') {
                    in_str = true;
                    continue;
                }
                if (ch == open) depth += 1;
                if (ch == close) {
                    depth -= 1;
                    if (depth == 0) {
                        p += 1;
                        break;
                    }
                }
            }
            return b[start..p];
        }
        // 数字 / 布尔 / null:吃到逗号 / } / 空白
        while (p < b.len and b[p] != ',' and b[p] != '}' and b[p] != ' ' and b[p] != '\n' and b[p] != '\r' and b[p] != '\t') : (p += 1) {}
        return b[start..p];
    }
};

// --------------------------------------------------------------------------
// Self-tests
// --------------------------------------------------------------------------

test "MockServer: start/stop does not leak" {
    const body = "data: {\"type\":\"message_stop\"}\n\n";
    var srv = try MockServer.start(body, 0);
    srv.stop();
}

test "MockServer: simple fetch returns body" {
    const body =
        "data: {\"type\":\"message_start\"}\n\n" ++
        "data: {\"type\":\"message_stop\"}\n\n";
    var srv = try MockServer.start(body, 0);
    defer srv.stop();

    const req = "GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n";
    const resp = try clientRoundtrip(std.testing.allocator, srv.port, req, null);
    defer std.testing.allocator.free(resp);

    try std.testing.expect(std.mem.indexOf(u8, resp, "200 OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "message_stop") != null);
}

test "MockServer: captures request body + jsonField extracts fields" {
    const body = "data: {\"type\":\"message_stop\"}\n\n";
    var srv = try MockServer.start(body, 0);
    defer srv.stop();

    const req_body = "{\"model\":\"claude-3-5-haiku-20241022\",\"max_tokens\":100,\"stream\":true,\"messages\":[]}";
    var req_buf: [512]u8 = undefined;
    const req = try std.fmt.bufPrint(&req_buf, "POST /v1/messages HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: {d}\r\n\r\n{s}", .{ req_body.len, req_body });
    const resp = try clientRoundtrip(std.testing.allocator, srv.port, req, null);
    std.testing.allocator.free(resp);

    const cap = srv.lastRequest().?;
    try std.testing.expectEqualStrings(req_body, cap.body());
    try std.testing.expectEqualStrings("\"claude-3-5-haiku-20241022\"", cap.jsonField("model").?);
    try std.testing.expectEqualStrings("100", cap.jsonField("max_tokens").?);
    try std.testing.expectEqualStrings("true", cap.jsonField("stream").?);
    try std.testing.expectEqualStrings("[]", cap.jsonField("messages").?);
    try std.testing.expect(cap.jsonField("nonexistent") == null);
}
