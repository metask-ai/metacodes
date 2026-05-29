//! Mock SSE server：起一个 127.0.0.1 监听、accept 一次、写 HTTP 200 + 固定 SSE body，关闭。
//!
//! 用途：
//!   L3 集成测试（http_stream_e2e_test 等）已用 — 发响应,不验证请求体。
//!   L2 组件测试（doc/E2E_TESTING.md）— 用 lastRequest()/CapturedRequest 断言请求体字段贯穿。
//!
//! 设计：同步，在调用线程起个辅助 std.Thread 跑 accept 循环；调用方拿到 port 后连接它。
//! 本期最小可用——不支持多连接、不支持请求路由（所有请求返回同一 body）、不支持 keep-alive。

const std = @import("std");

pub const MockServer = struct {
    listen_fd: std.c.fd_t,
    port: u16,
    thread: std.Thread,
    body: []const u8,
    /// 每个 SSE event（\n\n 分隔）之间的 sleep，用于模拟慢流
    chunk_delay_ms: u32 = 0,
    /// 捕获的请求 raw bytes(headers + body,完整 HTTP 请求)。serveOne 写入,lastRequest 读取。
    /// page_allocator 分配,stop 释放。
    captured_buf: ?[]u8 = null,
    captured_len: usize = 0,
    /// captured_buf 是否已写完(serveOne 写完后置 1)。读端用 .acquire 确保看到完整 buf。
    captured_ready: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),

    pub fn start(body: []const u8, chunk_delay_ms: u32) !*MockServer {
        const fd = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
        if (fd < 0) return error.SocketFailed;
        errdefer _ = std.c.close(fd);

        const yes: c_int = 1;
        _ = std.c.setsockopt(fd, std.c.SOL.SOCKET, std.c.SO.REUSEADDR, &yes, @sizeOf(c_int));

        var addr = std.c.sockaddr.in{
            .family = std.c.AF.INET,
            .port = 0,
            .addr = 0x0100007f,
            .zero = [_]u8{0} ** 8,
        };
        if (std.c.bind(fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr))) < 0) return error.BindFailed;
        if (std.c.listen(fd, 1) < 0) return error.ListenFailed;

        var bound: std.c.sockaddr.in = undefined;
        var blen: std.c.socklen_t = @sizeOf(@TypeOf(bound));
        if (std.c.getsockname(fd, @ptrCast(&bound), &blen) < 0) return error.GetSocknameFailed;
        const port = std.mem.bigToNative(u16, bound.port);

        const self = try std.heap.page_allocator.create(MockServer);
        self.* = .{
            .listen_fd = fd,
            .port = port,
            .thread = undefined,
            .body = body,
            .chunk_delay_ms = chunk_delay_ms,
        };
        self.thread = try std.Thread.spawn(.{}, serveOne, .{self});
        return self;
    }

    pub fn stop(self: *MockServer) void {
        _ = std.c.close(self.listen_fd);
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
        var client_addr: std.c.sockaddr = undefined;
        var alen: std.c.socklen_t = @sizeOf(@TypeOf(client_addr));
        const conn_fd = std.c.accept(self.listen_fd, &client_addr, &alen);
        if (conn_fd < 0) return;
        defer _ = std.c.close(conn_fd);

        // 读完整请求(headers + body)到 captured_buf。
        // 算法:read 直到看见 \r\n\r\n,然后根据 Content-Length 读余下 body。
        const cap: usize = 64 * 1024;
        const buf = std.heap.page_allocator.alloc(u8, cap) catch {
            sendResponse(conn_fd, self);
            return;
        };

        var total: usize = 0;
        var headers_end: ?usize = null;
        var content_length: usize = 0;
        while (total < cap and headers_end == null) {
            const n = std.c.read(conn_fd, buf.ptr + total, cap - total);
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
                const n = std.c.read(conn_fd, buf.ptr + total, want);
                if (n <= 0) break;
                total += @intCast(n);
            }
        }

        self.captured_buf = buf;
        self.captured_len = total;
        self.captured_ready.store(1, .release);

        sendResponse(conn_fd, self);
    }

    fn sendResponse(conn_fd: std.c.fd_t, self: *MockServer) void {
        const header =
            "HTTP/1.1 200 OK\r\n" ++
            "content-type: text/event-stream\r\n" ++
            "cache-control: no-cache\r\n" ++
            "transfer-encoding: chunked\r\n\r\n";
        _ = std.c.write(conn_fd, header.ptr, header.len);

        var cursor: usize = 0;
        while (cursor < self.body.len) {
            const end = std.mem.indexOfPos(u8, self.body, cursor, "\n\n") orelse self.body.len;
            const chunk_end = @min(end + 2, self.body.len);
            const chunk = self.body[cursor..chunk_end];
            writeChunk(conn_fd, chunk);
            cursor = chunk_end;
            if (self.chunk_delay_ms > 0) {
                const req = std.c.timespec{ .sec = 0, .nsec = @as(i64, self.chunk_delay_ms) * 1_000_000 };
                var rem: std.c.timespec = undefined;
                _ = std.c.nanosleep(&req, &rem);
            }
        }
        const end_chunk = "0\r\n\r\n";
        _ = std.c.write(conn_fd, end_chunk.ptr, end_chunk.len);
    }

    fn writeChunk(fd: std.c.fd_t, bytes: []const u8) void {
        var hex_buf: [32]u8 = undefined;
        const hdr = std.fmt.bufPrint(&hex_buf, "{x}\r\n", .{bytes.len}) catch return;
        _ = std.c.write(fd, hdr.ptr, hdr.len);
        _ = std.c.write(fd, bytes.ptr, bytes.len);
        _ = std.c.write(fd, "\r\n", 2);
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
                if (b[p] == '\\') { p += 1; continue; }
                if (b[p] == '"') { p += 1; break; }
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
                    if (ch == '\\') { p += 1; continue; }
                    if (ch == '"') in_str = false;
                    continue;
                }
                if (ch == '"') { in_str = true; continue; }
                if (ch == open) depth += 1;
                if (ch == close) {
                    depth -= 1;
                    if (depth == 0) { p += 1; break; }
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

    const sock = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
    try std.testing.expect(sock >= 0);
    defer _ = std.c.close(sock);

    var addr = std.c.sockaddr.in{
        .family = std.c.AF.INET,
        .port = std.mem.nativeToBig(u16, srv.port),
        .addr = 0x0100007f,
        .zero = [_]u8{0} ** 8,
    };
    const connect_rc = std.c.connect(sock, @ptrCast(&addr), @sizeOf(@TypeOf(addr)));
    try std.testing.expect(connect_rc == 0);

    const req = "GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n";
    _ = std.c.write(sock, req.ptr, req.len);

    var full = std.ArrayList(u8).empty;
    defer full.deinit(std.testing.allocator);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = std.c.read(sock, &buf, buf.len);
        if (n <= 0) break;
        try full.appendSlice(std.testing.allocator, buf[0..@as(usize, @intCast(n))]);
    }
    const resp = full.items;
    try std.testing.expect(std.mem.indexOf(u8, resp, "200 OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "message_stop") != null);
}

test "MockServer: captures request body + jsonField extracts fields" {
    const body = "data: {\"type\":\"message_stop\"}\n\n";
    var srv = try MockServer.start(body, 0);
    defer srv.stop();

    const sock = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
    try std.testing.expect(sock >= 0);
    defer _ = std.c.close(sock);
    var addr = std.c.sockaddr.in{
        .family = std.c.AF.INET,
        .port = std.mem.nativeToBig(u16, srv.port),
        .addr = 0x0100007f,
        .zero = [_]u8{0} ** 8,
    };
    try std.testing.expect(std.c.connect(sock, @ptrCast(&addr), @sizeOf(@TypeOf(addr))) == 0);

    const req_body = "{\"model\":\"claude-3-5-haiku-20241022\",\"max_tokens\":100,\"stream\":true,\"messages\":[]}";
    var hdr_buf: [256]u8 = undefined;
    const hdr = try std.fmt.bufPrint(&hdr_buf,
        "POST /v1/messages HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Length: {d}\r\n\r\n",
        .{req_body.len});
    _ = std.c.write(sock, hdr.ptr, hdr.len);
    _ = std.c.write(sock, req_body.ptr, req_body.len);

    var rb: [4096]u8 = undefined;
    while (true) {
        const n = std.c.read(sock, &rb, rb.len);
        if (n <= 0) break;
    }

    const cap = srv.lastRequest().?;
    try std.testing.expectEqualStrings(req_body, cap.body());
    try std.testing.expectEqualStrings("\"claude-3-5-haiku-20241022\"", cap.jsonField("model").?);
    try std.testing.expectEqualStrings("100", cap.jsonField("max_tokens").?);
    try std.testing.expectEqualStrings("true", cap.jsonField("stream").?);
    try std.testing.expectEqualStrings("[]", cap.jsonField("messages").?);
    try std.testing.expect(cap.jsonField("nonexistent") == null);
}
