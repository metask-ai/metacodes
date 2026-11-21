const std = @import("std");
const cc = @import("cc");
const platform = @import("platform");

const net = platform.net;
const psync = platform.sync;
const http_connection = cc.api_http_connection;

const HOLD_MS: i64 = 5_000;
const PROMPT_MS: i64 = 1_000;
const CONTROL_HOLD_MS: i64 = 1_000;

const NO_CONTENT = "HTTP/1.1 204 No Content\r\n\r\n";

const Stopwatch = struct {
    begun: std.Io.Timestamp,

    fn start() Stopwatch {
        return .{ .begun = std.Io.Timestamp.now(clock(), .awake) };
    }

    fn ms(self: Stopwatch) i64 {
        return self.begun.durationTo(std.Io.Timestamp.now(clock(), .awake)).toMilliseconds();
    }

    fn clock() std.Io {
        return std.Io.Threaded.global_single_threaded.io();
    }
};

const Answer = struct {
    bytes: []const u8,
    hold: bool = true,
};

const Route = *const fn (request: []const u8) Answer;

fn answerNoContent(_: []const u8) Answer {
    return .{ .bytes = NO_CONTENT };
}

const HeldServer = struct {
    const MAX_REQUESTS = 16;
    const MAX_REQUEST_BYTES = 256 * 1024;

    const AfterAnswer = union(enum) { closed_ms: i64, next_request, hold_expired, stopped };

    const Held = struct {
        after: AfterAnswer,
        next: ?usize = null,
    };

    listen_sock: net.Socket,
    port: u16,
    route: Route,
    hold_ms: i64,
    thread: std.Thread = undefined,
    stopping: std.atomic.Value(bool) = .init(false),
    handlers: std.atomic.Value(u32) = .init(0),
    mutex: psync.Mutex = .{},
    requests: [MAX_REQUESTS][]u8 = undefined,
    after: [MAX_REQUESTS]?AfterAnswer = @splat(null),
    request_count: usize = 0,

    fn start(route: Route) !*HeldServer {
        return startHolding(route, HOLD_MS);
    }

    fn startHolding(route: Route, hold_ms: i64) !*HeldServer {
        const listener = try net.listenLoopback(0, 16);
        errdefer net.closeSocket(listener.sock);
        const self = try std.heap.page_allocator.create(HeldServer);
        errdefer std.heap.page_allocator.destroy(self);
        self.* = .{ .listen_sock = listener.sock, .port = listener.port, .route = route, .hold_ms = hold_ms };
        self.thread = try std.Thread.spawn(.{}, serve, .{self});
        return self;
    }

    fn stop(self: *HeldServer) void {
        self.stopping.store(true, .release);
        if (net.connectLoopback(self.port)) |wake| net.closeSocket(wake) else |_| {}
        net.closeSocket(self.listen_sock);
        self.thread.join();
        while (self.handlers.load(.acquire) != 0) psync.sleepMs(5);
        for (self.requests[0..self.request_count]) |raw| std.heap.page_allocator.free(raw);
        std.heap.page_allocator.destroy(self);
    }

    fn url(self: *const HeldServer, buf: []u8, path: []const u8) []const u8 {
        return std.fmt.bufPrint(buf, "http://127.0.0.1:{d}{s}", .{ self.port, path }) catch unreachable;
    }

    fn requestCount(self: *HeldServer) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.request_count;
    }

    fn requestAt(self: *HeldServer, index: usize) ?[]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (index >= self.request_count) return null;
        return self.requests[index];
    }

    fn afterAnswer(self: *HeldServer, index: usize, timeout_ms: i64) ?AfterAnswer {
        const watch = Stopwatch.start();
        while (true) {
            self.mutex.lock();
            const result = if (index < MAX_REQUESTS) self.after[index] else null;
            self.mutex.unlock();
            if (result != null) return result;
            if (watch.ms() >= timeout_ms) return null;
            psync.sleepMs(5);
        }
    }

    fn expectClientClosed(self: *HeldServer, index: usize) !void {
        const result = self.afterAnswer(index, 2 * PROMPT_MS) orelse return error.TestExpectedClientClose;
        switch (result) {
            .closed_ms => |ms| try std.testing.expect(ms < PROMPT_MS),
            else => {
                std.debug.print("request {d}: {s} instead of a client close\n", .{ index, @tagName(result) });
                return error.TestExpectedClientClose;
            },
        }
    }

    fn serve(self: *HeldServer) void {
        while (true) {
            const conn = net.acceptConn(self.listen_sock) orelse return;
            if (self.stopping.load(.acquire)) {
                net.closeSocket(conn);
                return;
            }
            _ = self.handlers.fetchAdd(1, .acq_rel);
            const handler = std.Thread.spawn(.{}, serveConnection, .{ self, conn }) catch {
                _ = self.handlers.fetchSub(1, .acq_rel);
                net.closeSocket(conn);
                continue;
            };
            handler.detach();
        }
    }

    fn serveConnection(self: *HeldServer, conn: net.Socket) void {
        defer _ = self.handlers.fetchSub(1, .acq_rel);
        defer net.closeSocket(conn);
        const buf = std.heap.page_allocator.alloc(u8, MAX_REQUEST_BYTES) catch return;
        defer std.heap.page_allocator.free(buf);
        net.setRecvTimeoutMs(conn, 10_000);
        var have: usize = 0;
        while (!self.stopping.load(.acquire)) {
            const total = readRequest(conn, buf, have);
            if (total == 0) return;
            const index = self.record(buf[0..total]) orelse return;
            const answer = self.route(buf[0..total]);
            writeAll(conn, answer.bytes) catch return;
            if (!answer.hold) return;
            const held = self.hold(conn, buf);
            self.note(index, held.after);
            have = held.next orelse return;
        }
    }

    fn hold(self: *HeldServer, conn: net.Socket, buf: []u8) Held {
        const watch = Stopwatch.start();
        while (!self.stopping.load(.acquire)) {
            if (watch.ms() >= self.hold_ms) return .{ .after = .hold_expired };
            if (!net.pollReadable(conn, 20)) continue;
            const n = net.recv(conn, buf);
            if (n > 0) return .{ .after = .next_request, .next = @intCast(n) };
            if (n < 0 and net.lastSocketFailure() == .interrupted) continue;
            return .{ .after = .{ .closed_ms = watch.ms() } };
        }
        return .{ .after = .stopped };
    }

    fn record(self: *HeldServer, raw: []const u8) ?usize {
        const owned = std.heap.page_allocator.dupe(u8, raw) catch return null;
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.request_count == MAX_REQUESTS) {
            std.heap.page_allocator.free(owned);
            return null;
        }
        self.requests[self.request_count] = owned;
        self.request_count += 1;
        return self.request_count - 1;
    }

    fn note(self: *HeldServer, index: usize, after: AfterAnswer) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.after[index] = after;
    }

    fn readRequest(conn: net.Socket, buf: []u8, have: usize) usize {
        var total = have;
        const head_end = while (true) {
            if (std.mem.indexOf(u8, buf[0..total], "\r\n\r\n")) |at| break at + 4;
            if (total == buf.len) return 0;
            const n = net.recv(conn, buf[total..]);
            if (n <= 0) return 0;
            total += @intCast(n);
        };
        const end = @min(buf.len, head_end + contentLength(buf[0..head_end]));
        while (total < end) {
            const n = net.recv(conn, buf[total..end]);
            if (n <= 0) break;
            total += @intCast(n);
        }
        return total;
    }
};

fn writeAll(conn: net.Socket, bytes: []const u8) error{WriteFailed}!void {
    var sent: usize = 0;
    while (sent < bytes.len) {
        const n = net.send(conn, bytes[sent..]);
        if (n < 0 and net.lastSocketFailure() == .interrupted) continue;
        if (n <= 0) return error.WriteFailed;
        sent += @intCast(n);
    }
}

fn headerValue(raw: []const u8, name: []const u8) ?[]const u8 {
    const head_end = std.mem.indexOf(u8, raw, "\r\n\r\n") orelse raw.len;
    var lines = std.mem.splitSequence(u8, raw[0..head_end], "\r\n");
    _ = lines.next();
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " \t"), name)) continue;
        return std.mem.trim(u8, line[colon + 1 ..], " \t");
    }
    return null;
}

fn contentLength(head: []const u8) usize {
    const value = headerValue(head, "content-length") orelse return 0;
    return std.fmt.parseInt(usize, value, 10) catch 0;
}

fn expectPrompt(watch: Stopwatch) !void {
    const ms = watch.ms();
    if (ms >= PROMPT_MS) {
        std.debug.print("took {d} ms; the server held the connection for {d} ms\n", .{ ms, HOLD_MS });
        return error.TestExpectedPromptReturn;
    }
}

test "L2 #579: a 204 on a connection the server keeps open reads as an empty body at once" {
    const a = std.testing.allocator;
    var server = try HeldServer.start(answerNoContent);
    defer server.stop();
    var io_runtime = platform.signal.threadedIo(a, .{});
    defer io_runtime.deinit();
    var client: std.http.Client = .{ .allocator = a, .io = io_runtime.io() };
    defer client.deinit();
    var url_buf: [64]u8 = undefined;
    const uri = try std.Uri.parse(server.url(&url_buf, "/no-content"));

    var request = try client.request(.GET, uri, .{ .keep_alive = false, .redirect_behavior = .unhandled });
    defer request.deinit();
    http_connection.keepServerOpen(&request);
    try http_connection.sendBodiless(&request);
    var redirect: [1024]u8 = undefined;
    const response = try http_connection.receiveHead(&request, &redirect);
    var transfer: [1024]u8 = undefined;
    const watch = Stopwatch.start();
    const body = try http_connection.bodyReader(&response, &transfer).allocRemaining(a, .unlimited);
    defer a.free(body);
    try expectPrompt(watch);
    try std.testing.expectEqual(@as(usize, 0), body.len);
    try std.testing.expectEqualStrings("keep-alive", headerValue(server.requestAt(0).?, "connection").?);
}

test "L2 #579: a DELETE answered 204 on a kept-alive connection is closed by deinit, not drained" {
    const a = std.testing.allocator;
    var server = try HeldServer.start(answerNoContent);
    defer server.stop();
    var io_runtime = platform.signal.threadedIo(a, .{});
    defer io_runtime.deinit();
    var client: std.http.Client = .{ .allocator = a, .io = io_runtime.io() };
    defer client.deinit();
    var url_buf: [64]u8 = undefined;
    const uri = try std.Uri.parse(server.url(&url_buf, "/session"));

    var request = try client.request(.DELETE, uri, .{ .redirect_behavior = .unhandled });
    {
        errdefer request.deinit();
        try http_connection.sendBodiless(&request);
        var redirect: [1024]u8 = undefined;
        _ = try http_connection.receiveHead(&request, &redirect);
    }
    const watch = Stopwatch.start();
    request.deinit();
    try expectPrompt(watch);
    try server.expectClientClosed(0);
}

const NOT_MODIFIED_WITH_LENGTH = "HTTP/1.1 304 Not Modified\r\nContent-Length: 1234\r\n\r\n";
const HEAD_ANSWER_WITH_LENGTH = "HTTP/1.1 200 OK\r\nContent-Length: 1234\r\n\r\n";

fn answerNotModifiedOrHead(request: []const u8) Answer {
    if (std.mem.startsWith(u8, request, "HEAD ")) return .{ .bytes = HEAD_ANSWER_WITH_LENGTH };
    return .{ .bytes = NOT_MODIFIED_WITH_LENGTH };
}

test "L2 #579: a 304 that names a content-length, and the answer to a HEAD, read as empty at once" {
    const a = std.testing.allocator;
    var server = try HeldServer.start(answerNotModifiedOrHead);
    defer server.stop();
    var io_runtime = platform.signal.threadedIo(a, .{});
    defer io_runtime.deinit();
    var client: std.http.Client = .{ .allocator = a, .io = io_runtime.io() };
    defer client.deinit();
    var url_buf: [64]u8 = undefined;
    const uri = try std.Uri.parse(server.url(&url_buf, "/document"));

    for ([_]std.http.Method{ .GET, .HEAD }) |method| {
        var request = try client.request(method, uri, .{ .redirect_behavior = .unhandled });
        defer request.deinit();
        try http_connection.sendBodiless(&request);
        var redirect: [1024]u8 = undefined;
        const response = try http_connection.receiveHead(&request, &redirect);
        var transfer: [1024]u8 = undefined;
        const watch = Stopwatch.start();
        const body = try http_connection.bodyReader(&response, &transfer).allocRemaining(a, .unlimited);
        defer a.free(body);
        try expectPrompt(watch);
        try std.testing.expectEqual(@as(usize, 0), body.len);
    }
    try server.expectClientClosed(0);
}

fn answerNoContentOrHead(request: []const u8) Answer {
    if (std.mem.startsWith(u8, request, "HEAD ")) return .{ .bytes = HEAD_ANSWER_WITH_LENGTH };
    return .{ .bytes = NO_CONTENT };
}

test "L2 #579: each body-less answer is read through a reader of its own, never std's shared read-only ending reader" {
    const a = std.testing.allocator;
    var server = try HeldServer.start(answerNoContentOrHead);
    defer server.stop();
    var io_runtime = platform.signal.threadedIo(a, .{});
    defer io_runtime.deinit();
    var client: std.http.Client = .{ .allocator = a, .io = io_runtime.io() };
    defer client.deinit();
    var url_buf: [64]u8 = undefined;
    const uri = try std.Uri.parse(server.url(&url_buf, "/no-content"));
    var redirect: [1024]u8 = undefined;
    var transfer: [3][256]u8 = undefined;

    var first = try client.request(.GET, uri, .{ .redirect_behavior = .unhandled });
    defer first.deinit();
    try http_connection.sendBodiless(&first);
    const first_response = try http_connection.receiveHead(&first, &redirect);
    const first_reader = http_connection.bodyReader(&first_response, &transfer[0]);

    var second = try client.request(.GET, uri, .{ .redirect_behavior = .unhandled });
    defer second.deinit();
    try http_connection.sendBodiless(&second);
    const second_response = try http_connection.receiveHead(&second, &redirect);
    const second_reader = http_connection.bodyReader(&second_response, &transfer[1]);

    var head = try client.request(.HEAD, uri, .{ .redirect_behavior = .unhandled });
    defer head.deinit();
    try http_connection.sendBodiless(&head);
    const head_response = try http_connection.receiveHead(&head, &redirect);
    const head_reader = http_connection.bodyReader(&head_response, &transfer[2]);

    for ([_]*std.Io.Reader{ first_reader, second_reader, head_reader }) |reader| {
        try std.testing.expect(reader != std.Io.Reader.ending);
    }
    try std.testing.expect(first_reader != second_reader);
    try std.testing.expectEqual(@as(usize, 0), try first_reader.discardRemaining());
    var dest: [16]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 0), try second_reader.readSliceShort(&dest));
    try std.testing.expectEqual(@as(usize, 0), try head_reader.discardRemaining());
}

test "L2 #579 control: without http_connection, std reads a 204 to the end of the connection and deinit drains one" {
    const a = std.testing.allocator;
    var server = try HeldServer.startHolding(answerNoContent, CONTROL_HOLD_MS);
    defer server.stop();
    var io_runtime = platform.signal.threadedIo(a, .{});
    defer io_runtime.deinit();
    var client: std.http.Client = .{ .allocator = a, .io = io_runtime.io() };
    defer client.deinit();
    var url_buf: [64]u8 = undefined;
    const uri = try std.Uri.parse(server.url(&url_buf, "/no-content"));

    {
        var request = try client.request(.GET, uri, .{ .keep_alive = false, .redirect_behavior = .unhandled });
        defer request.deinit();
        http_connection.keepServerOpen(&request);
        try http_connection.sendBodiless(&request);
        var redirect: [1024]u8 = undefined;
        var response = try request.receiveHead(&redirect);
        var transfer: [1024]u8 = undefined;
        const watch = Stopwatch.start();
        const read = response.reader(&transfer).discardRemaining() catch 0;
        try std.testing.expect(watch.ms() >= CONTROL_HOLD_MS / 2);
        try std.testing.expectEqual(@as(usize, 0), read);
    }
    {
        var request = try client.request(.DELETE, uri, .{ .redirect_behavior = .unhandled });
        {
            errdefer request.deinit();
            try http_connection.sendBodiless(&request);
            var redirect: [1024]u8 = undefined;
            _ = try request.receiveHead(&redirect);
        }
        const watch = Stopwatch.start();
        request.deinit();
        try std.testing.expect(watch.ms() >= CONTROL_HOLD_MS / 2);
    }
}

const MCP_INITIALIZE_RESULT = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{},\"serverInfo\":{\"name\":\"held\",\"version\":\"1\"}}}";
const MCP_INITIALIZE_ANSWER = std.fmt.comptimePrint(
    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nMcp-Session-Id: session-579\r\nContent-Length: {d}\r\n\r\n{s}",
    .{ MCP_INITIALIZE_RESULT.len, MCP_INITIALIZE_RESULT },
);

fn answerMcpSession(request: []const u8) Answer {
    if (std.mem.startsWith(u8, request, "DELETE ")) return .{ .bytes = NO_CONTENT };
    return .{ .bytes = MCP_INITIALIZE_ANSWER };
}

test "L2 #579 MCP Streamable HTTP: closing a session the server ends with a 204, on a kept-alive connection, returns at once" {
    const a = std.testing.allocator;
    var server = try HeldServer.start(answerMcpSession);
    defer server.stop();
    var io_runtime = platform.signal.threadedIo(a, .{});
    defer io_runtime.deinit();
    var url_buf: [64]u8 = undefined;
    const transport = try cc.mcp_transport_http.HttpTransport.create(a, io_runtime.io(), server.url(&url_buf, "/mcp"), &.{});
    {
        errdefer transport.close();
        try transport.send("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{}}", .{ .method = "initialize" });
        const answer = try transport.recvLine();
        a.free(answer);
    }
    const watch = Stopwatch.start();
    transport.close();
    try expectPrompt(watch);
    try std.testing.expectEqual(@as(usize, 2), server.requestCount());
    const delete = server.requestAt(1).?;
    try std.testing.expect(std.mem.startsWith(u8, delete, "DELETE /mcp HTTP/1.1\r\n"));
    try std.testing.expectEqualStrings("session-579", headerValue(delete, "mcp-session-id").?);
    try server.expectClientClosed(1);
}

const MCP_UNANSWERED_EVENTS = "retry: 10\nid: e1\ndata:\n\n";
const MCP_UNANSWERED_STREAM = std.fmt.comptimePrint(
    "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n{x}\r\n{s}\r\n0\r\n\r\n",
    .{ MCP_UNANSWERED_EVENTS.len, MCP_UNANSWERED_EVENTS },
);

fn answerMcpResume(request: []const u8) Answer {
    if (std.mem.startsWith(u8, request, "GET ")) return .{ .bytes = NO_CONTENT };
    return .{ .bytes = MCP_UNANSWERED_STREAM };
}

test "L2 #579 MCP Streamable HTTP: a resumption the server answers 204, on a kept-alive connection, fails at once" {
    const a = std.testing.allocator;
    var server = try HeldServer.start(answerMcpResume);
    defer server.stop();
    var io_runtime = platform.signal.threadedIo(a, .{});
    defer io_runtime.deinit();
    var url_buf: [64]u8 = undefined;
    const transport = try cc.mcp_transport_http.HttpTransport.create(a, io_runtime.io(), server.url(&url_buf, "/mcp"), &.{});
    defer transport.close();
    try transport.send("{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/call\",\"params\":{\"name\":\"probe\"}}", .{ .method = "tools/call" });
    const watch = Stopwatch.start();
    try std.testing.expectError(error.Eof, transport.recvLine());
    try expectPrompt(watch);
    try std.testing.expectEqual(@as(usize, 2), server.requestCount());
    const resumed = server.requestAt(1).?;
    try std.testing.expect(std.mem.startsWith(u8, resumed, "GET /mcp HTTP/1.1\r\n"));
    try std.testing.expectEqualStrings("e1", headerValue(resumed, "last-event-id").?);
    try server.expectClientClosed(1);
}

test "L2 #579 API key list: a 204 is refused at once, not drained from a kept-alive connection" {
    const a = std.testing.allocator;
    var server = try HeldServer.start(answerNoContent);
    defer server.stop();
    var io_runtime = platform.signal.threadedIo(a, .{});
    defer io_runtime.deinit();
    var catalog = cc.api_api_keys.Catalog.init(a);
    defer catalog.deinit();
    var url_buf: [64]u8 = undefined;
    const watch = Stopwatch.start();
    try std.testing.expectError(error.HttpError, cc.api_api_keys.fetchInto(&catalog, a, io_runtime.io(), server.url(&url_buf, "/v1/messages"), "token-579"));
    try expectPrompt(watch);
    try std.testing.expect(std.mem.startsWith(u8, server.requestAt(0).?, "GET /api/v1/keys?"));
    try server.expectClientClosed(0);
}

const JEV_QUESTIONS = [_]cc.jev_question.Named{
    .{ .name = "needs_enumeration", .question = .{ .boolean = .{
        .description = "Does answering this request require counting or listing several matching items?",
        .when_true = "The answer is a count or a complete list.",
        .when_false = "The answer is a single fact or an action.",
    } } },
};

test "L2 #579 System-One advisor: a 204 is refused at once, not read to the end of the connection" {
    const a = std.testing.allocator;
    var server = try HeldServer.start(answerNoContent);
    defer server.stop();
    var io_runtime = platform.signal.threadedIo(a, .{});
    defer io_runtime.deinit();
    var origin_buf: [64]u8 = undefined;
    var client = try cc.jev_client.Client.init(a, io_runtime.io(), .{ .origin = server.url(&origin_buf, ""), .timeout_ms = 10_000 });
    defer client.deinit();
    const watch = Stopwatch.start();
    try std.testing.expectError(error.Rejected, client.ask(a, null, "User request: list the releases", &JEV_QUESTIONS));
    try expectPrompt(watch);
    try server.expectClientClosed(0);
}

test "L2 #579 TinyKG service: a 204 to the readiness probe or to a command is refused at once" {
    const a = std.testing.allocator;
    var server = try HeldServer.start(answerNoContent);
    defer server.stop();
    var io_runtime = platform.signal.threadedIo(a, .{});
    defer io_runtime.deinit();
    var url_buf: [64]u8 = undefined;
    var transport = try cc.kg_transport.WebTransport.init(a, .{
        .io = io_runtime.io(),
        .url = server.url(&url_buf, ""),
        .api_key = "key-579",
        .expected_build_id = "sha256:" ++ "0" ** 64,
        .timeout_ms = 10_000,
    });
    defer transport.deinit();

    var watch = Stopwatch.start();
    try std.testing.expectError(error.InvalidResponse, transport.ready());
    try expectPrompt(watch);
    try std.testing.expect(std.mem.startsWith(u8, server.requestAt(0).?, "GET /api/ready "));
    try server.expectClientClosed(0);

    watch = Stopwatch.start();
    try std.testing.expectError(error.InvalidResponse, transport.run("store-info", &.{}, false));
    try expectPrompt(watch);
    try std.testing.expect(std.mem.startsWith(u8, server.requestAt(1).?, "POST /api/run "));
    try server.expectClientClosed(1);
}

test "L2 #579 sealed skills gateway: a 204 is refused at once, not read to the end of the connection" {
    const a = std.testing.allocator;
    var server = try HeldServer.start(answerNoContent);
    defer server.stop();
    var io_runtime = platform.signal.threadedIo(a, .{});
    defer io_runtime.deinit();
    var url_buf: [64]u8 = undefined;
    var client = try cc.skills_sealed_transport.Client.init(a, io_runtime.io(), server.url(&url_buf, "/ssp"), "");
    defer client.deinit();
    const watch = Stopwatch.start();
    try std.testing.expectError(error.InvalidResponse, client.call(.discover, "{}", null));
    try expectPrompt(watch);
    try std.testing.expectEqual(@as(u16, 204), client.last_http_status);
    try server.expectClientClosed(0);
}

test "L2 #579 OTLP export: a collector's 204 is an export done at once, not one read until the export deadline" {
    const a = std.testing.allocator;
    var server = try HeldServer.start(answerNoContent);
    defer server.stop();
    var arena = std.heap.ArenaAllocator.init(a);
    var url_buf: [64]u8 = undefined;
    const endpoint = arena.allocator().dupe(u8, server.url(&url_buf, "/v1/traces")) catch |err| {
        arena.deinit();
        return err;
    };
    const exporter = try cc.telemetry.Exporter.start(a, arena, .{
        .endpoint = endpoint,
        .protocol = .http_json,
        .timeout_ms = 3_000,
        .schedule_delay_ms = 60_000,
        .resource = &.{},
    }, "0.0.0-test");
    defer exporter.shutdown();
    const span: cc.telemetry.span.Span = .{
        .trace_id = .random(),
        .span_id = .random(),
        .name = "probe",
        .start_unix_nano = 1,
        .end_unix_nano = 2,
    };
    exporter.enqueue(&span);
    const watch = Stopwatch.start();
    try std.testing.expect(exporter.forceFlush(5_000));
    try expectPrompt(watch);
    const stats = exporter.snapshotStats();
    try std.testing.expectEqual(@as(u64, 1), stats.exported);
    try std.testing.expectEqual(@as(u64, 0), stats.failed_batches);
    try server.expectClientClosed(0);
}

test "L2 #579 catalog download: a 204 on a kept-alive connection answers at once with an empty body" {
    const a = std.testing.allocator;
    var server = try HeldServer.start(answerNoContent);
    defer server.stop();
    var io_runtime = platform.signal.threadedIo(a, .{});
    defer io_runtime.deinit();
    var url_buf: [64]u8 = undefined;
    const watch = Stopwatch.start();
    const answer = try cc.api_catalog_fetch.fetchAnswer(a, io_runtime.io(), .{ .url = server.url(&url_buf, "/catalog.json") });
    defer a.free(answer.body);
    try expectPrompt(watch);
    try std.testing.expectEqual(@as(u16, 204), answer.status);
    try std.testing.expectEqual(@as(usize, 0), answer.body.len);
    try server.expectClientClosed(0);
}

test "L2 #579 OAuth refresh: a token endpoint's 204 on a kept-alive connection fails at once" {
    const a = std.testing.allocator;
    var server = try HeldServer.start(answerNoContent);
    defer server.stop();
    var io_runtime = platform.signal.threadedIo(a, .{});
    defer io_runtime.deinit();
    var url_buf: [64]u8 = undefined;
    var http_exchange: cc.api_oauth_exchange.HttpExchange = .{
        .allocator = a,
        .io = io_runtime.io(),
        .endpoint = .{ .token_url = server.url(&url_buf, "/oauth/token"), .client_id = "client-579" },
    };
    const exchange = http_exchange.exchange();
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const watch = Stopwatch.start();
    try std.testing.expectError(
        error.MalformedTokenResponse,
        exchange.run(exchange.ctx, cc.api_oauth_exchange.Slug.lit("held"), "refresh-579", arena.allocator()),
    );
    try expectPrompt(watch);
    try server.expectClientClosed(0);
}
