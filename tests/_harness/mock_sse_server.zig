//! Mock SSE server：起一个 127.0.0.1 监听、accept 一次、写 HTTP 200 + 固定 SSE body，关闭。
//!
//! 用途：M1.8 的集成测试。单元测试（api/stream.zig）用 Reader.fixed 就够；这里只为
//! 真正从 TCP → std.http.Client 通过整条链路验证 abort / large stream。
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

    pub fn start(body: []const u8, chunk_delay_ms: u32) !*MockServer {
        const fd = std.c.socket(std.c.AF.INET, std.c.SOCK.STREAM, 0);
        if (fd < 0) return error.SocketFailed;
        errdefer _ = std.c.close(fd);

        // SO_REUSEADDR
        const yes: c_int = 1;
        _ = std.c.setsockopt(fd, std.c.SOL.SOCKET, std.c.SO.REUSEADDR, &yes, @sizeOf(c_int));

        var addr = std.c.sockaddr.in{
            .family = std.c.AF.INET,
            .port = 0, // 0 = OS 分配
            .addr = 0x0100007f, // 127.0.0.1 (little-endian)
            .zero = [_]u8{0} ** 8,
        };
        if (std.c.bind(fd, @ptrCast(&addr), @sizeOf(@TypeOf(addr))) < 0) return error.BindFailed;
        if (std.c.listen(fd, 1) < 0) return error.ListenFailed;

        // 查询实际分配的端口
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
        std.heap.page_allocator.destroy(self);
    }

    fn serveOne(self: *MockServer) void {
        var client_addr: std.c.sockaddr = undefined;
        var alen: std.c.socklen_t = @sizeOf(@TypeOf(client_addr));
        const conn_fd = std.c.accept(self.listen_fd, &client_addr, &alen);
        if (conn_fd < 0) return;
        defer _ = std.c.close(conn_fd);

        // 读掉请求头（不解析，随便丢）
        var req_buf: [8192]u8 = undefined;
        _ = std.c.read(conn_fd, &req_buf, req_buf.len);

        // 写 HTTP 响应头
        const header =
            "HTTP/1.1 200 OK\r\n" ++
            "content-type: text/event-stream\r\n" ++
            "cache-control: no-cache\r\n" ++
            "transfer-encoding: chunked\r\n\r\n";
        _ = std.c.write(conn_fd, header.ptr, header.len);

        // body 按 "\n\n" 切分为 events，逐个写 chunk（chunked encoding：size\r\n data \r\n）
        var cursor: usize = 0;
        while (cursor < self.body.len) {
            const end = std.mem.indexOfPos(u8, self.body, cursor, "\n\n") orelse self.body.len;
            // 含分隔符 \n\n（最后一段可能没有）
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
        // 结束 chunk
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

    /// 返回形如 "http://127.0.0.1:<port>/v1/messages" 的 URL（allocator-owned）
    pub fn urlOwned(self: *const MockServer, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/v1/messages", .{self.port});
    }
};

// --------------------------------------------------------------------------
// Self-tests（起 server + 用 socket client 拉一遍）
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

    // 用裸 socket 去拉
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

    // 发最小请求
    const req = "GET / HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n";
    _ = std.c.write(sock, req.ptr, req.len);

    // 读整个响应（可能分多次 read 到达）
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
