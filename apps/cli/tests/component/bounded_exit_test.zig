const std = @import("std");
const builtin = @import("builtin");
const cc = @import("cc");
const platform = @import("platform");

const net = platform.net;
const psync = platform.sync;
const ppaths = platform.paths;

const HOLD_MS: i64 = 8_000;
const EXIT_BOUND_MS: i64 = 3_000;

const Stopwatch = struct {
    begun: i64,

    fn start() Stopwatch {
        return .{ .begun = cc.util_time.nowMs() };
    }

    fn ms(self: Stopwatch) i64 {
        return cc.util_time.nowMs() - self.begun;
    }
};

const EnvGuard = struct {
    name: [*:0]const u8,
    previous: ?[:0]u8,

    fn set(name: [*:0]const u8, value: ?[*:0]const u8) !EnvGuard {
        const previous = if (std.c.getenv(name)) |raw| try std.testing.allocator.dupeZ(u8, std.mem.span(raw)) else null;
        if (value) |v| ppaths.setEnv(name, v) else ppaths.unsetEnv(name);
        return .{ .name = name, .previous = previous };
    }

    fn restore(self: *EnvGuard) void {
        if (self.previous) |previous| {
            ppaths.setEnv(self.name, previous.ptr);
            std.testing.allocator.free(previous);
        } else ppaths.unsetEnv(self.name);
    }
};

const Workspace = struct {
    tmp: std.testing.TmpDir,
    root_buffer: [std.fs.max_path_bytes]u8,
    root: []const u8,
    guards: [10]EnvGuard,
    guard_count: usize,

    fn init(self: *Workspace, otlp_endpoint: ?[*:0]const u8) !void {
        self.tmp = std.testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        const len = try self.tmp.dir.realPath(std.testing.io, &self.root_buffer);
        self.root = self.root_buffer[0..len];
        try self.tmp.dir.createDirPath(std.testing.io, ".metacodes");
        const home_z = try std.testing.allocator.dupeZ(u8, self.root);
        defer std.testing.allocator.free(home_z);
        const settings = [_]struct { [*:0]const u8, ?[*:0]const u8 }{
            .{ "HOME", home_z.ptr },
            .{ "METACODES_NO_PROBE", "1" },
            .{ "METACODES_KG_AUTOSTART", "0" },
            .{ "CODEX_HOME", null },
            .{ "OTEL_SDK_DISABLED", null },
            .{ "OTEL_TRACES_EXPORTER", null },
            .{ "OTEL_EXPORTER_OTLP_TRACES_ENDPOINT", null },
            .{ "OTEL_EXPORTER_OTLP_TRACES_TIMEOUT", null },
            .{ "OTEL_EXPORTER_OTLP_TIMEOUT", null },
            .{ "OTEL_EXPORTER_OTLP_ENDPOINT", otlp_endpoint },
        };
        self.guard_count = 0;
        errdefer self.restoreGuards();
        for (settings) |setting| {
            self.guards[self.guard_count] = try EnvGuard.set(setting[0], setting[1]);
            self.guard_count += 1;
        }
    }

    fn restoreGuards(self: *Workspace) void {
        while (self.guard_count > 0) {
            self.guard_count -= 1;
            self.guards[self.guard_count].restore();
        }
    }

    fn deinit(self: *Workspace) void {
        self.restoreGuards();
        self.tmp.cleanup();
    }

    fn writeConfig(self: *Workspace, servers_json: []const u8) !void {
        const a = std.testing.allocator;
        const config = try std.fmt.allocPrint(a, "{{\"mcpServers\":{s}}}", .{servers_json});
        defer a.free(config);
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".metacodes/config.json", .data = config });
    }
};

const Session = struct {
    arena: std.heap.ArenaAllocator,
    io_rt: std.Io.Threaded,
    app: *cc.app_module.App,

    fn init(self: *Session, mode: cc.types_mod.McpConnect) !void {
        self.arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        errdefer self.arena.deinit();
        const a = self.arena.allocator();
        const argv = [_][*:0]const u8{ "metacodes", "--permission", "bypassPermissions", "--base-url", "http://127.0.0.1:1/v1/messages" };
        var config = cc.parseArgsForTest(&argv, a);
        try std.testing.expect(config.parse_error == null);
        config.mcp_connect = mode;
        self.io_rt = platform.signal.threadedIo(a, .{});
        errdefer self.io_rt.deinit();
        self.app = try cc.app_module.App.init(a, self.io_rt.io(), config, "test-key");
    }

    fn deinit(self: *Session) void {
        self.app.deinit();
        self.io_rt.deinit();
        self.arena.deinit();
    }
};

const SilentListener = struct {
    const MAX_HELD = 16;

    listener: net.Listener,
    thread: std.Thread = undefined,
    stopping: std.atomic.Value(bool) = .init(false),
    accepted: std.atomic.Value(u32) = .init(0),
    held: [MAX_HELD]net.Socket = undefined,
    held_count: usize = 0,

    fn start(self: *SilentListener) !void {
        self.* = .{ .listener = try net.listenLoopback(0, 16) };
        errdefer net.closeSocket(self.listener.sock);
        self.thread = try std.Thread.spawn(.{}, serve, .{self});
    }

    fn stop(self: *SilentListener) void {
        self.stopping.store(true, .release);
        self.thread.join();
        self.release();
        net.closeSocket(self.listener.sock);
    }

    fn release(self: *SilentListener) void {
        for (self.held[0..self.held_count]) |sock| net.closeSocket(sock);
        self.held_count = 0;
    }

    fn waitAccepted(self: *SilentListener, timeout_ms: i64) !void {
        const watch = Stopwatch.start();
        while (self.accepted.load(.acquire) == 0) {
            if (watch.ms() >= timeout_ms) return error.NeverConnected;
            psync.sleepMs(5);
        }
    }

    fn serve(self: *SilentListener) void {
        var first_ms: ?i64 = null;
        while (!self.stopping.load(.acquire)) {
            if (first_ms) |first| if (cc.util_time.nowMs() - first >= HOLD_MS) self.release();
            if (!net.pollReadable(self.listener.sock, 20)) continue;
            const sock = net.acceptConn(self.listener.sock) orelse continue;
            if (self.held_count == MAX_HELD) {
                net.closeSocket(sock);
                continue;
            }
            self.held[self.held_count] = sock;
            self.held_count += 1;
            if (first_ms == null) first_ms = cc.util_time.nowMs();
            _ = self.accepted.fetchAdd(1, .acq_rel);
        }
    }
};

const ClassicServer = struct {
    listener: net.Listener,
    thread: std.Thread = undefined,
    stopping: std.atomic.Value(bool) = .init(false),
    handlers: std.atomic.Value(u32) = .init(0),
    deletes: std.atomic.Value(u32) = .init(0),

    fn start(self: *ClassicServer) !void {
        self.* = .{ .listener = try net.listenLoopback(0, 16) };
        errdefer net.closeSocket(self.listener.sock);
        self.thread = try std.Thread.spawn(.{}, serve, .{self});
    }

    fn stop(self: *ClassicServer) void {
        self.stopping.store(true, .release);
        self.thread.join();
        while (self.handlers.load(.acquire) != 0) psync.sleepMs(5);
        net.closeSocket(self.listener.sock);
    }

    fn serve(self: *ClassicServer) void {
        while (!self.stopping.load(.acquire)) {
            if (!net.pollReadable(self.listener.sock, 20)) continue;
            const sock = net.acceptConn(self.listener.sock) orelse continue;
            _ = self.handlers.fetchAdd(1, .acq_rel);
            const thread = std.Thread.spawn(.{}, handle, .{ self, sock }) catch {
                _ = self.handlers.fetchSub(1, .acq_rel);
                net.closeSocket(sock);
                continue;
            };
            thread.detach();
        }
    }

    fn handle(self: *ClassicServer, sock: net.Socket) void {
        defer _ = self.handlers.fetchSub(1, .acq_rel);
        defer net.closeSocket(sock);
        var buffer: [64 * 1024]u8 = undefined;
        var filled: usize = 0;
        while (!self.stopping.load(.acquire)) {
            const head_end = std.mem.indexOf(u8, buffer[0..filled], "\r\n\r\n") orelse {
                if (filled == buffer.len) return;
                if (!net.pollReadable(sock, 20)) continue;
                const n = net.recv(sock, buffer[filled..]);
                if (n <= 0) return;
                filled += @intCast(n);
                continue;
            };
            const head = buffer[0..head_end];
            const body_len = contentLength(head);
            const total = head_end + 4 + body_len;
            if (total > buffer.len) return;
            if (filled < total) {
                if (!net.pollReadable(sock, 20)) continue;
                const n = net.recv(sock, buffer[filled..]);
                if (n <= 0) return;
                filled += @intCast(n);
                continue;
            }
            if (std.mem.startsWith(u8, head, "DELETE ")) {
                _ = self.deletes.fetchAdd(1, .acq_rel);
                const held = Stopwatch.start();
                while (!self.stopping.load(.acquire) and held.ms() < HOLD_MS) psync.sleepMs(10);
                return;
            }
            self.answer(sock, buffer[head_end + 4 .. total]) catch return;
            std.mem.copyForwards(u8, buffer[0 .. filled - total], buffer[total..filled]);
            filled -= total;
        }
    }

    fn answer(_: *ClassicServer, sock: net.Socket, body: []const u8) !void {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const a = arena.allocator();
        const message = try std.json.parseFromSliceLeaky(std.json.Value, a, body, .{});
        const method = if (message.object.get("method")) |m| m.string else "";
        const id = message.object.get("id");
        const id_json = if (id) |value| try std.json.Stringify.valueAlloc(a, value, .{}) else "null";
        var extra: []const u8 = "";
        var status: []const u8 = "200 OK";
        const payload: []const u8 = if (std.mem.eql(u8, method, "server/discover")) blk: {
            status = "400 Bad Request";
            break :blk try std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{{\"code\":-32000,\"message\":\"not initialized\"}}}}", .{id_json});
        } else if (std.mem.eql(u8, method, "initialize")) blk: {
            extra = "Mcp-Session-Id: s1\r\n";
            break :blk try std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{{\"tools\":{{}}}},\"serverInfo\":{{\"name\":\"s\",\"version\":\"1\"}}}}}}", .{id_json});
        } else if (id == null) blk: {
            status = "202 Accepted";
            break :blk "";
        } else try std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{{\"tools\":[]}}}}", .{id_json});
        const reply = try std.fmt.allocPrint(a, "HTTP/1.1 {s}\r\n{s}Content-Type: application/json\r\nContent-Length: {d}\r\n\r\n{s}", .{ status, extra, payload.len, payload });
        if (net.send(sock, reply) != @as(isize, @intCast(reply.len))) return error.SendFailed;
    }

    fn contentLength(head: []const u8) usize {
        var lines = std.mem.splitSequence(u8, head, "\r\n");
        while (lines.next()) |line| {
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            if (!std.ascii.eqlIgnoreCase(line[0..colon], "content-length")) continue;
            return std.fmt.parseInt(usize, std.mem.trim(u8, line[colon + 1 ..], " "), 10) catch 0;
        }
        return 0;
    }
};

test "L2 #671 /exit: a Classic HTTP MCP server that never answers the session DELETE does not hold the exit" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var server: ClassicServer = undefined;
    try server.start();
    defer server.stop();
    var ws: Workspace = undefined;
    try ws.init(null);
    defer ws.deinit();
    var servers_buffer: [160]u8 = undefined;
    try ws.writeConfig(try std.fmt.bufPrint(&servers_buffer, "{{\"s1\":{{\"type\":\"http\",\"url\":\"http://127.0.0.1:{d}/mcp\"}}}}", .{server.listener.port}));

    var session: Session = undefined;
    try session.init(.app_init);
    {
        errdefer session.deinit();
        try std.testing.expectEqual(@as(usize, 1), session.app.mcp_report.servers.len);
        try std.testing.expectEqual(.connected, session.app.mcp_report.servers[0].state);
    }
    const watch = Stopwatch.start();
    session.deinit();
    const elapsed_ms = watch.ms();
    try std.testing.expectEqual(@as(u32, 1), server.deletes.load(.acquire));
    try std.testing.expect(elapsed_ms < EXIT_BOUND_MS);
}

test "L2 #671 startup: an https MCP server that never completes the TLS handshake fails at its startup timeout" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var listener: SilentListener = undefined;
    try listener.start();
    defer listener.stop();
    var ws: Workspace = undefined;
    try ws.init(null);
    defer ws.deinit();
    var servers_buffer: [200]u8 = undefined;
    try ws.writeConfig(try std.fmt.bufPrint(&servers_buffer, "{{\"s1\":{{\"type\":\"http\",\"url\":\"https://127.0.0.1:{d}/mcp\",\"startupTimeoutMs\":1000}}}}", .{listener.listener.port}));

    const watch = Stopwatch.start();
    var session: Session = undefined;
    try session.init(.app_init);
    const elapsed_ms = watch.ms();
    defer session.deinit();
    try std.testing.expect(listener.accepted.load(.acquire) >= 1);
    try std.testing.expect(elapsed_ms < EXIT_BOUND_MS);
    try std.testing.expectEqual(.failed, session.app.mcp_report.servers[0].state);
    try std.testing.expectEqualStrings("no response before the startup timeout", session.app.mcp_report.servers[0].detail);
}

test "L2 #671 /exit: leaving while an https MCP server stalls the TLS handshake interrupts the connect" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var listener: SilentListener = undefined;
    try listener.start();
    defer listener.stop();
    var ws: Workspace = undefined;
    try ws.init(null);
    defer ws.deinit();
    var servers_buffer: [200]u8 = undefined;
    try ws.writeConfig(try std.fmt.bufPrint(&servers_buffer, "{{\"s1\":{{\"type\":\"http\",\"url\":\"https://127.0.0.1:{d}/mcp\",\"startupTimeoutMs\":60000}}}}", .{listener.listener.port}));

    var session: Session = undefined;
    try session.init(.first_request);
    {
        errdefer session.deinit();
        try listener.waitAccepted(5_000);
        try std.testing.expect(!session.app.mcpStartupSettled());
    }
    const watch = Stopwatch.start();
    session.deinit();
    try std.testing.expect(watch.ms() < EXIT_BOUND_MS);
}

test "L2 #672 /exit: an OTLP collector that never answers costs the exit the shutdown budget, not the export timeout" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var collector: SilentListener = undefined;
    try collector.start();
    defer collector.stop();
    var endpoint_buffer: [64]u8 = undefined;
    const endpoint = try std.fmt.bufPrintZ(&endpoint_buffer, "http://127.0.0.1:{d}", .{collector.listener.port});
    var ws: Workspace = undefined;
    try ws.init(endpoint.ptr);
    defer ws.deinit();

    var session: Session = undefined;
    try session.init(.app_init);
    {
        errdefer session.deinit();
        const exporter = cc.telemetry.processExporter() orelse return error.ExportNotConfigured;
        try std.testing.expectEqual(cc.telemetry.config.DEFAULT_TIMEOUT_MS, exporter.config.timeout_ms);
        const span: cc.telemetry.span.Span = .{
            .trace_id = .random(),
            .span_id = .random(),
            .name = "probe-672",
            .start_unix_nano = 1,
            .end_unix_nano = 2,
        };
        exporter.enqueue(&span);
        try std.testing.expect(!exporter.forceFlush(50));
        try collector.waitAccepted(5_000);
    }
    psync.sleepMs(100);
    const watch = Stopwatch.start();
    session.deinit();
    try std.testing.expect(watch.ms() < EXIT_BOUND_MS);
}
