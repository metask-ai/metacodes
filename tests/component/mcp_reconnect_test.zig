const std = @import("std");
const builtin = @import("builtin");
const harness = @import("harness");
const cc = @import("cc");
const pfs = @import("platform").fs;
const ppaths = @import("platform").paths;
const psync = @import("platform").sync;

const REPLY_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"done\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const MOCK_MCP = "zig-out/bin/mock_mcp_server";
const GATE_TOOL = "mcp__gate__echo";

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
    guards: [4]EnvGuard,

    fn init(self: *Workspace) !void {
        self.tmp = std.testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        const len = try self.tmp.dir.realPath(std.testing.io, &self.root_buffer);
        self.root = self.root_buffer[0..len];
        try self.tmp.dir.createDirPath(std.testing.io, ".metacodes");
        const home_z = try std.testing.allocator.dupeZ(u8, self.root);
        defer std.testing.allocator.free(home_z);
        self.guards = .{
            try EnvGuard.set("HOME", home_z.ptr),
            try EnvGuard.set("METACODES_NO_PROBE", "1"),
            try EnvGuard.set("METACODES_KG_AUTOSTART", "0"),
            try EnvGuard.set("CODEX_HOME", null),
        };
    }

    fn deinit(self: *Workspace) void {
        var i = self.guards.len;
        while (i > 0) {
            i -= 1;
            self.guards[i].restore();
        }
        self.tmp.cleanup();
    }

    fn path(self: *const Workspace, a: std.mem.Allocator, name: []const u8) ![:0]u8 {
        return std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ self.root, name }, 0);
    }

    fn writeConfig(self: *Workspace, servers_json: []const u8) !void {
        const a = std.testing.allocator;
        const config = try std.fmt.allocPrint(a, "{{\"mcpServers\":{s}}}", .{servers_json});
        defer a.free(config);
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".metacodes/config.json", .data = config });
    }

    fn gateEntry(self: *const Workspace, a: std.mem.Allocator, name: []const u8) ![]u8 {
        var cwd_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const cwd = pfs.getCwd(&cwd_buffer) orelse return error.NoCwd;
        return std.fmt.allocPrint(
            a,
            "\"{s}\":{{\"command\":\"/bin/sh\",\"args\":[\"-c\",\"echo $$ > '{s}/server.pid'; while [ ! -e '{s}/gate' ]; do sleep 0.01; done; exec '{s}/{s}'\"]}}",
            .{ name, self.root, self.root, cwd, MOCK_MCP },
        );
    }

    fn writeGateServer(self: *Workspace, name: []const u8) !void {
        const a = std.testing.allocator;
        const entry = try self.gateEntry(a, name);
        defer a.free(entry);
        const servers = try std.fmt.allocPrint(a, "{{{s}}}", .{entry});
        defer a.free(servers);
        try self.writeConfig(servers);
    }

    fn openGate(self: *Workspace) !void {
        try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "gate", .data = "" });
    }

    fn readPid(self: *Workspace) ?i32 {
        var buffer: [32]u8 = undefined;
        const bytes = self.tmp.dir.readFile(std.testing.io, "server.pid", &buffer) catch return null;
        return std.fmt.parseInt(i32, std.mem.trim(u8, bytes, " \n"), 10) catch null;
    }

    fn clearPid(self: *Workspace) void {
        self.tmp.dir.deleteFile(std.testing.io, "server.pid") catch {};
    }
};

const Session = struct {
    arena: std.heap.ArenaAllocator,
    io_rt: std.Io.Threaded,
    app: *cc.app_module.App,

    fn init(self: *Session, base_url: []const u8) !void {
        self.arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        errdefer self.arena.deinit();
        const a = self.arena.allocator();
        const url = try a.dupeZ(u8, base_url);
        var config = cc.parseArgsForTest(&.{ "metacodes", "--permission", "bypassPermissions", "--base-url", url.ptr }, a);
        try std.testing.expect(config.parse_error == null);
        config.mcp_connect = .first_request;
        self.io_rt = @import("platform").signal.threadedIo(a, .{});
        errdefer self.io_rt.deinit();
        self.app = try cc.app_module.App.init(a, self.io_rt.io(), config, "test-key");
    }

    fn deinit(self: *Session) void {
        self.app.deinit();
        self.io_rt.deinit();
        self.arena.deinit();
    }

    fn repl(self: *Session, ws: *Workspace, text: []const u8) !void {
        const a = self.arena.allocator();
        const input_path = try ws.path(a, "repl-input");
        {
            const fd = pfs.open(input_path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o600));
            if (fd < 0) return error.InputFile;
            defer _ = pfs.close(fd);
            if (pfs.write(fd, text) != @as(isize, @intCast(text.len))) return error.InputFile;
        }
        const fd = pfs.open(input_path.ptr, .{ .ACCMODE = .RDONLY }, 0);
        if (fd < 0) return error.InputFile;
        defer _ = pfs.close(fd);
        try cc.repl_loop.run(self.app, a, .{ .input_fd = fd });
    }

    fn waitSettled(self: *Session) !void {
        var waited: usize = 0;
        while (!self.app.mcpStartupSettled() and waited < 1000) : (waited += 1) psync.sleepMs(10);
        try std.testing.expect(self.app.mcpStartupSettled());
    }
};

fn surface(a: std.mem.Allocator, body: []const u8) ![2][]u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, a, body, .{});
    defer parsed.deinit();
    var out: [2][]u8 = undefined;
    for ([_][]const u8{ "system", "tools" }, 0..) |key, i| {
        const value = parsed.value.object.get(key) orelse return error.MissingField;
        out[i] = try std.json.Stringify.valueAlloc(a, value, .{});
    }
    return out;
}

fn waitForPid(ws: *Workspace) !i32 {
    var waited: usize = 0;
    while (waited < 500) : (waited += 1) {
        if (ws.readPid()) |pid| return pid;
        psync.sleepMs(10);
    }
    return error.ServerNeverStarted;
}

test "L2 a server added mid-session inside the working directories waits for /mcp reconnect: the request before it has no such tool, the one after has it" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    if (!pfs.exists(MOCK_MCP)) return error.SkipZigTest;
    var ws: Workspace = undefined;
    try ws.init();
    defer ws.deinit();
    try ws.writeConfig("{}");
    try ws.openGate();

    var srv = try harness.MockServer.startCassette(&.{ REPLY_SSE, REPLY_SSE }, 0);
    defer srv.stop();
    const url = try srv.urlOwned(std.testing.allocator);
    defer std.testing.allocator.free(url);
    var session: Session = undefined;
    try session.init(url);
    defer session.deinit();
    const app = session.app;
    try std.testing.expectEqual(@as(usize, 0), app.mcp_report.servers.len);

    try ws.writeGateServer("gate");
    try session.repl(&ws, "hello\n/mcp reconnect\nhello again\n");

    try std.testing.expectEqual(@as(usize, 2), srv.requestCount());
    try std.testing.expect(std.mem.indexOf(u8, srv.requestAt(0).?.body(), GATE_TOOL) == null);
    try std.testing.expect(std.mem.indexOf(u8, srv.requestAt(1).?.body(), GATE_TOOL) != null);
    try std.testing.expect(app.toolSurfaceReady());
    try std.testing.expectEqual(@as(usize, 1), app.mcp_report.servers.len);
    try std.testing.expectEqual(.connected, app.mcp_report.servers[0].state);
    try std.testing.expectEqual(@as(usize, 1), app.mcp_sessions.items.len);
}

test "L2 /mcp reconnect with every server connected changes nothing a provider sees" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    if (!pfs.exists(MOCK_MCP)) return error.SkipZigTest;
    const a = std.testing.allocator;
    var ws: Workspace = undefined;
    try ws.init();
    defer ws.deinit();
    try ws.writeGateServer("gate");
    try ws.openGate();

    var srv = try harness.MockServer.startCassette(&.{ REPLY_SSE, REPLY_SSE }, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);
    var session: Session = undefined;
    try session.init(url);
    defer session.deinit();
    const app = session.app;
    try session.waitSettled();
    try app.publishMcpServers();

    const defs = app.tool_defs.ptr;
    const prompt = app.system_prompt.?.ptr;
    try std.testing.expectEqual(cc.app_module.McpReconnectStart.all_connected, try app.beginMcpReconnect(.unconnected));
    try std.testing.expect(app.toolSurfaceReady());
    try std.testing.expectEqual(defs, app.tool_defs.ptr);
    try std.testing.expectEqual(prompt, app.system_prompt.?.ptr);
    try std.testing.expectEqual(.connected, app.mcp_report.servers[0].state);
    try std.testing.expect(app.mcp_report.servers[0].tool_count != 0);
    try std.testing.expectEqual(@as(usize, 0), app.mcp_unavailable.len);

    try session.repl(&ws, "hello\n/mcp reconnect\nhello again\n");
    try std.testing.expectEqual(@as(usize, 2), srv.requestCount());
    const before = try surface(a, srv.requestAt(0).?.body());
    defer for (before) |part| a.free(part);
    const after = try surface(a, srv.requestAt(1).?.body());
    defer for (after) |part| a.free(part);
    for (before, after) |expected, actual| try std.testing.expectEqualStrings(expected, actual);
    try std.testing.expect(std.mem.indexOf(u8, srv.requestAt(1).?.body(), GATE_TOOL) != null);
}

test "L2 /mcp reconnect <name> restarts a connected server: a new process, the old one reaped, its tools kept; the other server is untouched" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    if (!pfs.exists(MOCK_MCP)) return error.SkipZigTest;
    const a = std.testing.allocator;
    var ws: Workspace = undefined;
    try ws.init();
    defer ws.deinit();
    {
        const gate = try ws.gateEntry(a, "gate");
        defer a.free(gate);
        var cwd_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const cwd = pfs.getCwd(&cwd_buffer) orelse return error.NoCwd;
        const servers = try std.fmt.allocPrint(a, "{{\"other\":{{\"command\":\"{s}/{s}\"}},{s}}}", .{ cwd, MOCK_MCP, gate });
        defer a.free(servers);
        try ws.writeConfig(servers);
    }
    try ws.openGate();

    var srv = try harness.MockServer.startCassette(&.{REPLY_SSE}, 0);
    defer srv.stop();
    const url = try srv.urlOwned(std.testing.allocator);
    defer std.testing.allocator.free(url);
    var session: Session = undefined;
    try session.init(url);
    defer session.deinit();
    const app = session.app;
    try session.waitSettled();
    try app.publishMcpServers();
    const first_pid = try waitForPid(&ws);
    ws.clearPid();
    try std.testing.expectEqualStrings("other", app.mcp_sessions.items[0].name);
    const other_client = app.mcp_sessions.items[0].client;
    const other_status = app.mcp_report.servers[0];

    try session.repl(&ws, "/mcp reconnect gate\nhello\n");

    const second_pid = try waitForPid(&ws);
    try std.testing.expect(second_pid != first_pid);
    try std.testing.expect(std.c.kill(first_pid, @enumFromInt(0)) != 0);
    try std.testing.expectEqual(@as(usize, 2), app.mcp_sessions.items.len);
    try std.testing.expect(app.mcp_sessions.items[0].client == other_client);
    try std.testing.expectEqualStrings("other", app.mcp_report.servers[0].name);
    try std.testing.expectEqual(.connected, app.mcp_report.servers[0].state);
    try std.testing.expectEqual(other_status.tool_count, app.mcp_report.servers[0].tool_count);
    try std.testing.expectEqualStrings("gate", app.mcp_report.servers[1].name);
    try std.testing.expectEqual(.connected, app.mcp_report.servers[1].state);
    try std.testing.expectEqual(@as(usize, 1), srv.requestCount());
    const body = srv.lastRequest().?.body();
    try std.testing.expect(std.mem.indexOf(u8, body, GATE_TOOL) != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "mcp__other__echo") != null);
    var registered: usize = 0;
    var index: usize = 0;
    while (app.dyn_registry.entryAt(index)) |entry| : (index += 1) {
        if (entry.isLive() and std.mem.startsWith(u8, entry.name, "mcp__gate__")) registered += 1;
    }
    try std.testing.expectEqual(app.mcp_report.servers[1].tool_count, registered);
}

test "L2 a server that failed at startup connects on /mcp reconnect once fixed; /mcp and the unavailable list follow" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    if (!pfs.exists(MOCK_MCP)) return error.SkipZigTest;
    const a = std.testing.allocator;
    var ws: Workspace = undefined;
    try ws.init();
    defer ws.deinit();
    try ws.writeConfig("{\"gate\":{\"command\":\"/nonexistent/metacodes-test-mcp-server\"}}");
    try ws.openGate();

    var srv = try harness.MockServer.startCassette(&.{REPLY_SSE}, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);
    var session: Session = undefined;
    try session.init(url);
    defer session.deinit();
    const app = session.app;
    try session.waitSettled();
    try app.publishMcpServers();
    try std.testing.expectEqual(.failed, app.mcp_report.servers[0].state);
    try std.testing.expectEqual(@as(usize, 1), app.mcp_unavailable.len);

    try ws.writeGateServer("gate");
    try session.repl(&ws, "/mcp reconnect\nhello\n");

    try std.testing.expectEqual(@as(usize, 1), app.mcp_report.servers.len);
    try std.testing.expectEqual(.connected, app.mcp_report.servers[0].state);
    try std.testing.expectEqual(@as(usize, 0), app.mcp_unavailable.len);
    try std.testing.expect(std.mem.indexOf(u8, srv.lastRequest().?.body(), GATE_TOOL) != null);
}

test "L2 a stopped reconnect is canceled: the server is reaped and reported, and the tool surface stays as it was" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    if (!pfs.exists(MOCK_MCP)) return error.SkipZigTest;
    var ws: Workspace = undefined;
    try ws.init();
    defer ws.deinit();
    try ws.writeConfig("{}");

    var session: Session = undefined;
    try session.init("http://127.0.0.1:1/v1/messages");
    defer session.deinit();
    const app = session.app;
    try std.testing.expect(app.toolSurfaceReady());
    const defs = app.tool_defs.ptr;
    const prompt = app.system_prompt.?.ptr;

    try ws.writeGateServer("gate");
    const begun = try app.beginMcpReconnect(.unconnected);
    try std.testing.expectEqual(@as(usize, 1), begun.connecting.len);
    try std.testing.expectEqualStrings("gate", begun.connecting[0]);
    try std.testing.expect(app.toolSurfaceReady());
    try std.testing.expectEqual(defs, app.tool_defs.ptr);
    try std.testing.expectEqual(.connecting, app.mcp_report.servers[0].state);
    const pid = try waitForPid(&ws);

    try app.cancelMcpReconnect();
    try std.testing.expect(app.toolSurfaceReady());
    try std.testing.expectEqual(defs, app.tool_defs.ptr);
    try std.testing.expectEqual(prompt, app.system_prompt.?.ptr);
    try std.testing.expectEqual(.failed, app.mcp_report.servers[0].state);
    try std.testing.expectEqualStrings("connection canceled", app.mcp_report.servers[0].detail);
    try std.testing.expect(std.c.kill(pid, @enumFromInt(0)) != 0);
}

test "L2 /mcp reconnect of a name no session connects says why and changes nothing" {
    var ws: Workspace = undefined;
    try ws.init();
    defer ws.deinit();
    try ws.writeConfig("{\"off\":{\"enabled\":false}}");

    var session: Session = undefined;
    try session.init("http://127.0.0.1:1/v1/messages");
    defer session.deinit();
    const app = session.app;
    try std.testing.expect(app.toolSurfaceReady());
    const defs = app.tool_defs.ptr;
    const Start = cc.app_module.McpReconnectStart;
    try std.testing.expectEqual(Start{ .not_configured = .disabled }, try app.beginMcpReconnect(.{ .server = "off" }));
    try std.testing.expectEqual(Start{ .not_configured = .unknown }, try app.beginMcpReconnect(.{ .server = "nobody" }));
    try std.testing.expect(app.toolSurfaceReady());
    try std.testing.expectEqual(defs, app.tool_defs.ptr);
}

fn plainEntry(a: std.mem.Allocator, name: []const u8) ![]u8 {
    var cwd_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = pfs.getCwd(&cwd_buffer) orelse return error.NoCwd;
    return std.fmt.allocPrint(a, "\"{s}\":{{\"command\":\"{s}/{s}\"}}", .{ name, cwd, MOCK_MCP });
}

test "L2 /mcp reconnect disconnects a server whose entry was removed and connects the one added in its place" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    if (!pfs.exists(MOCK_MCP)) return error.SkipZigTest;
    const a = std.testing.allocator;
    var ws: Workspace = undefined;
    try ws.init();
    defer ws.deinit();
    {
        const old = try plainEntry(a, "old");
        defer a.free(old);
        const servers = try std.fmt.allocPrint(a, "{{{s}}}", .{old});
        defer a.free(servers);
        try ws.writeConfig(servers);
    }
    var srv = try harness.MockServer.startCassette(&.{REPLY_SSE}, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);
    var session: Session = undefined;
    try session.init(url);
    defer session.deinit();
    const app = session.app;
    try session.waitSettled();
    try app.publishMcpServers();
    try std.testing.expectEqual(.connected, app.mcp_report.servers[0].state);

    {
        const new = try plainEntry(a, "new");
        defer a.free(new);
        const servers = try std.fmt.allocPrint(a, "{{{s}}}", .{new});
        defer a.free(servers);
        try ws.writeConfig(servers);
    }
    try session.repl(&ws, "/mcp reconnect\nhello\n");

    try std.testing.expectEqual(@as(usize, 1), app.mcp_report.servers.len);
    try std.testing.expectEqualStrings("new", app.mcp_report.servers[0].name);
    try std.testing.expectEqual(.connected, app.mcp_report.servers[0].state);
    try std.testing.expectEqual(@as(usize, 1), app.mcp_sessions.items.len);
    try std.testing.expectEqual(@as(usize, 1), app.mcp_retired.items.len);
    const body = srv.lastRequest().?.body();
    try std.testing.expect(std.mem.indexOf(u8, body, "- mcp__new__echo — echo back input") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "are no longer available") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "- mcp__old__echo\\n") != null);
}

const AUTH_MOCK = "tests/_harness/mock_mcp_auth_server.py";

const AuthMock = struct {
    child: @import("platform").process.PipeChild,
    port: u16,

    fn start() ?AuthMock {
        if (builtin.os.tag == .windows) return null;
        if (std.c.access(AUTH_MOCK, 1) != 0) return null;
        const argv = [_]?[*:0]const u8{ AUTH_MOCK, null };
        const child = @import("platform").process.spawnPipes(&argv, true, null) catch return null;
        var buffer: [16]u8 = undefined;
        var length: usize = 0;
        while (length < buffer.len) {
            var byte: [1]u8 = undefined;
            if (!child.pollReadable(5000) or child.read(&byte) != 1 or byte[0] == '\n') break;
            buffer[length] = byte[0];
            length += 1;
        }
        const port = std.fmt.parseInt(u16, buffer[0..length], 10) catch {
            var dead = child;
            dead.closeStdin();
            dead.closeStdout();
            dead.terminate();
            return null;
        };
        return .{ .child = child, .port = port };
    }

    fn stop(self: *AuthMock) void {
        self.child.closeStdin();
        self.child.closeStdout();
        self.child.terminate();
    }
};

const Browser = struct {
    thread: ?std.Thread = null,
    url: ?[]u8 = null,

    fn open(ctx: *anyopaque, url: []const u8) void {
        const self: *Browser = @ptrCast(@alignCast(ctx));
        self.url = std.testing.allocator.dupe(u8, url) catch return;
        self.thread = std.Thread.spawn(.{}, visit, .{self.url.?}) catch null;
    }

    fn visit(url: []const u8) void {
        var client: std.http.Client = .{ .allocator = std.heap.c_allocator, .io = std.testing.io };
        defer client.deinit();
        const uri = std.Uri.parse(url) catch return;
        var request = client.request(.GET, uri, .{ .redirect_behavior = .unhandled }) catch return;
        defer request.deinit();
        request.sendBodiless() catch return;
        var redirect: [4096]u8 = undefined;
        const response = request.receiveHead(&redirect) catch return;
        var location_buffer: [2048]u8 = undefined;
        var headers = response.head.iterateHeaders();
        const location = while (headers.next()) |header| {
            if (std.ascii.eqlIgnoreCase(header.name, "location") and header.value.len <= location_buffer.len) {
                @memcpy(location_buffer[0..header.value.len], header.value);
                break location_buffer[0..header.value.len];
            }
        } else return;
        var callback_buffer: [2048]u8 = undefined;
        const size = std.mem.replacementSize(u8, location, "//localhost:", "//127.0.0.1:");
        _ = std.mem.replace(u8, location, "//localhost:", "//127.0.0.1:", callback_buffer[0..size]);
        var body: std.Io.Writer.Allocating = .init(std.heap.c_allocator);
        defer body.deinit();
        _ = client.fetch(.{ .location = .{ .url = callback_buffer[0..size] }, .response_writer = &body.writer }) catch {};
    }

    fn finish(self: *Browser) void {
        if (self.thread) |thread| thread.join();
        if (self.url) |url| std.testing.allocator.free(url);
        self.* = .{};
    }

    fn opener(self: *Browser) cc.mcp_oauth.OpenUrl {
        return .{ .ctx = self, .open = open };
    }
};

test "L2 a server that needed a login connects on /mcp reconnect once `mcp login` has stored one" {
    var mock = AuthMock.start() orelse return error.SkipZigTest;
    defer mock.stop();
    const a = std.testing.allocator;
    var ws: Workspace = undefined;
    try ws.init();
    defer ws.deinit();
    var url_buffer: [96]u8 = undefined;
    const server_url = try std.fmt.bufPrint(&url_buffer, "http://127.0.0.1:{d}/oauth-mcp", .{mock.port});
    {
        const servers = try std.fmt.allocPrint(a, "{{\"authd\":{{\"type\":\"http\",\"url\":\"{s}\"}}}}", .{server_url});
        defer a.free(servers);
        try ws.writeConfig(servers);
    }
    var srv = try harness.MockServer.startCassette(&.{REPLY_SSE}, 0);
    defer srv.stop();
    const provider_url = try srv.urlOwned(a);
    defer a.free(provider_url);
    var session: Session = undefined;
    try session.init(provider_url);
    defer session.deinit();
    const app = session.app;
    try session.waitSettled();
    try app.publishMcpServers();
    try std.testing.expectEqual(.needs_auth, app.mcp_report.servers[0].state);
    try std.testing.expect(std.mem.indexOf(u8, app.mcp_report.servers[0].detail, "connects automatically once the login is stored") != null);
    try std.testing.expectEqual(@as(usize, 1), app.mcp_unavailable.len);

    {
        var browser: Browser = .{};
        var result = cc.mcp_oauth.login(a, std.testing.io, app.stateRoot(), .{
            .name = "authd",
            .target = .{ .url = server_url, .wire = .streamable },
        }, .{ .open_browser = false, .open_url = browser.opener() }) catch |err| {
            browser.finish();
            return err;
        };
        browser.finish();
        result.deinit(a);
    }
    try session.repl(&ws, "/mcp reconnect authd\nhello\n");

    try std.testing.expectEqual(.connected, app.mcp_report.servers[0].state);
    try std.testing.expectEqual(@as(usize, 0), app.mcp_unavailable.len);
    try std.testing.expect(std.mem.indexOf(u8, srv.lastRequest().?.body(), "mcp__authd__whoami") != null);
}

test "L2 a server that needed a login connects before the next request once `mcp login` has stored one, without /mcp reconnect" {
    var mock = AuthMock.start() orelse return error.SkipZigTest;
    defer mock.stop();
    const a = std.testing.allocator;
    var ws: Workspace = undefined;
    try ws.init();
    defer ws.deinit();
    var url_buffer: [96]u8 = undefined;
    const server_url = try std.fmt.bufPrint(&url_buffer, "http://127.0.0.1:{d}/oauth-mcp", .{mock.port});
    {
        const servers = try std.fmt.allocPrint(a, "{{\"authd\":{{\"type\":\"http\",\"url\":\"{s}\"}}}}", .{server_url});
        defer a.free(servers);
        try ws.writeConfig(servers);
    }
    var srv = try harness.MockServer.startCassette(&.{REPLY_SSE}, 0);
    defer srv.stop();
    const provider_url = try srv.urlOwned(a);
    defer a.free(provider_url);
    var session: Session = undefined;
    try session.init(provider_url);
    defer session.deinit();
    const app = session.app;
    try session.waitSettled();
    try app.publishMcpServers();
    try std.testing.expectEqual(.needs_auth, app.mcp_report.servers[0].state);
    try std.testing.expect(std.mem.indexOf(u8, app.mcp_report.servers[0].detail, "connects automatically once the login is stored") != null);
    try std.testing.expectEqual(@as(usize, 1), app.mcp_unavailable.len);

    {
        var browser: Browser = .{};
        var result = cc.mcp_oauth.login(a, std.testing.io, app.stateRoot(), .{
            .name = "authd",
            .target = .{ .url = server_url, .wire = .streamable },
        }, .{ .open_browser = false, .open_url = browser.opener() }) catch |err| {
            browser.finish();
            return err;
        };
        browser.finish();
        result.deinit(a);
    }
    try session.repl(&ws, "hello\n");

    try std.testing.expectEqual(.connected, app.mcp_report.servers[0].state);
    try std.testing.expectEqual(@as(usize, 0), app.mcp_unavailable.len);
    const body = srv.lastRequest().?.body();
    try std.testing.expect(std.mem.indexOf(u8, body, "- mcp__authd__whoami") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "'authd' connected (") != null);
}

test "L2 a connected server whose entry changes inside the working directories keeps its connection until /mcp reconnect" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    if (!pfs.exists(MOCK_MCP)) return error.SkipZigTest;
    const a = std.testing.allocator;
    var ws: Workspace = undefined;
    try ws.init();
    defer ws.deinit();
    {
        const entry = try plainEntry(a, "kept");
        defer a.free(entry);
        const servers = try std.fmt.allocPrint(a, "{{{s}}}", .{entry});
        defer a.free(servers);
        try ws.writeConfig(servers);
    }
    var srv = try harness.MockServer.startCassette(&.{REPLY_SSE}, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);
    var session: Session = undefined;
    try session.init(url);
    defer session.deinit();
    const app = session.app;
    try session.waitSettled();
    try app.publishMcpServers();
    const client = app.mcp_sessions.items[0].client;
    {
        var cwd_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const cwd = pfs.getCwd(&cwd_buffer) orelse return error.NoCwd;
        const servers = try std.fmt.allocPrint(a, "{{\"kept\":{{\"command\":\"{s}/{s}\",\"args\":[\"--paginate\"]}}}}", .{ cwd, MOCK_MCP });
        defer a.free(servers);
        try ws.writeConfig(servers);
    }

    try session.repl(&ws, "hello\n");

    const body = srv.lastRequest().?.body();
    try std.testing.expect(std.mem.indexOf(u8, body, "'kept' was changed in ") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "the user loads it with `/mcp reconnect kept`") != null);
    try std.testing.expectEqual(@as(usize, 1), app.mcp_sessions.items.len);
    try std.testing.expect(app.mcp_sessions.items[0].client == client);
    try std.testing.expectEqual(.connected, app.mcp_report.servers[0].state);
}
