//! Streamable HTTP MCP client against tests/_harness/mock_mcp_http_server.py:
//! the Classic session/SSE flow (a mid-stream server ping answered on its own
//! POST), the 2026-07-28 routing headers, pagination and `x-mcp-header`, and
//! 401 as an authentication error.

const std = @import("std");
const builtin = @import("builtin");
const cc = @import("cc");
const process = @import("platform").process;

const MOCK = "tests/_harness/mock_mcp_http_server.py";

const Mock = struct {
    child: process.PipeChild,
    port: u16,

    fn start() !?Mock {
        if (builtin.os.tag == .windows) return null; // POSIX: shebang script
        if (std.c.access(MOCK, 1) != 0) return null;
        const argv = [_]?[*:0]const u8{ MOCK, null };
        const child = process.spawnPipes(&argv, true, null) catch return null;
        var buffer: [16]u8 = undefined;
        var length: usize = 0;
        while (length < buffer.len) {
            var byte: [1]u8 = undefined;
            if (!child.pollReadable(5000)) break;
            if (child.read(&byte) != 1) break;
            if (byte[0] == '\n') break;
            buffer[length] = byte[0];
            length += 1;
        }
        const port = std.fmt.parseInt(u16, buffer[0..length], 10) catch {
            child.closeStdin();
            child.closeStdout();
            child.terminate();
            return null;
        };
        return .{ .child = child, .port = port };
    }

    fn stop(self: *Mock) void {
        self.child.closeStdin();
        self.child.closeStdout();
        self.child.terminate();
    }

    fn url(self: *const Mock, buffer: []u8, path: []const u8) ![]const u8 {
        return std.fmt.bufPrint(buffer, "http://127.0.0.1:{d}/{s}", .{ self.port, path });
    }

    fn log(self: *const Mock, allocator: std.mem.Allocator) ![]u8 {
        var client: std.http.Client = .{ .allocator = allocator, .io = std.testing.io };
        defer client.deinit();
        var buffer: [128]u8 = undefined;
        const target = try self.url(&buffer, "log");
        var body: std.Io.Writer.Allocating = .init(allocator);
        defer body.deinit();
        _ = try client.fetch(.{ .location = .{ .url = target }, .response_writer = &body.writer });
        return body.toOwnedSlice();
    }
};

test "MCP HTTP: Classic session, SSE with a server ping, and DELETE on close" {
    var mock = (try Mock.start()) orelse return error.SkipZigTest;
    defer mock.stop();
    const a = std.testing.allocator;
    var buffer: [128]u8 = undefined;
    {
        var client = try cc.mcp_client.McpClient.connectHttp(a, .{
            .io = std.testing.io,
            .url = try mock.url(&buffer, "classic"),
            .headers = &.{ .{ .name = "X-Team", .value = "t1" }, .{ .name = "Authorization", .value = "Bearer tok" } },
        }, .{ .spawn = undefined, .startup_timeout_ms = 10_000 });
        defer client.close();
        try std.testing.expect(!client.modern);
        try std.testing.expectEqualStrings("2025-06-18", client.protocol_version);
        client.transport.setDeadline(cc.util_time.nowMs() + 10_000);
        const tools = try client.listTools();
        defer a.free(tools);
        try std.testing.expect(std.mem.indexOf(u8, tools, "\"sse_tool\"") != null);
        client.transport.setDeadline(null);
        const called = try client.callTool("sse_tool", "{}");
        defer a.free(called);
        try std.testing.expect(std.mem.indexOf(u8, called, "classic:sse_tool") != null);
    }
    const log = try mock.log(a);
    defer a.free(log);
    try std.testing.expect(std.mem.indexOf(u8, log, "\"ping_answered\": true") != null);
    try std.testing.expect(std.mem.indexOf(u8, log, "\"authorization\": \"Bearer tok\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, log, "\"x-team\": \"t1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, log, "\"method\": \"DELETE\", \"session\": \"session-1\"") != null);
}

test "MCP HTTP: 2026-07-28 headers, empty-cursor pagination and x-mcp-header" {
    var mock = (try Mock.start()) orelse return error.SkipZigTest;
    defer mock.stop();
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var buffer: [128]u8 = undefined;
    var client = try cc.mcp_client.McpClient.connectHttp(a, .{
        .io = std.testing.io,
        .url = try mock.url(&buffer, "modern"),
    }, .{ .spawn = undefined, .startup_timeout_ms = 10_000 });
    defer client.close();
    try std.testing.expect(client.modern);

    var registry = cc.tools_dynamic.DynRegistry.init(a);
    defer registry.deinit();
    var session = cc.mcp_registry_bridge.McpSession.init(a, &client);
    defer session.deinit();
    try session.registerToolsFiltered(&registry, "m", .{ .http_param_headers = true });
    // The tool with an invalid annotation is excluded; the second page is listed.
    try std.testing.expect(registry.find("mcp__m__regional") != null);
    try std.testing.expect(registry.find("mcp__m__badannot") == null);
    try std.testing.expect(registry.find("mcp__m__second_page") != null);

    var ctx = cc.tools.ToolContext.simple(a);
    ctx.artifact_root = root;
    const entry = registry.find("mcp__m__regional").?;
    var body = try entry.execute(&ctx, "{\"region\":\"eu-west\",\"q\":\"x\"}");
    defer body.deinit(a);
    const text = body.@"inline".bytes;
    try std.testing.expect(std.mem.indexOf(u8, text, "name-header:regional") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "region-header:eu-west") != null);
}

test "MCP HTTP: 401 is an authentication error, not a protocol fallback" {
    var mock = (try Mock.start()) orelse return error.SkipZigTest;
    defer mock.stop();
    var buffer: [128]u8 = undefined;
    try std.testing.expectError(error.McpAuthRequired, cc.mcp_client.McpClient.connectHttp(std.testing.allocator, .{
        .io = std.testing.io,
        .url = try mock.url(&buffer, "auth"),
    }, .{ .spawn = undefined, .startup_timeout_ms = 5_000 }));
}

/// The requests the mock saw on `path`, in order: method (or "" for a reply),
/// client port (one per TCP connection) and the `Connection` header.
const Seen = struct {
    method: []const u8,
    conn: i64,
    connection: ?[]const u8,
};

fn seenOn(arena: std.mem.Allocator, log: []const u8, path: []const u8) ![]Seen {
    var out: std.ArrayList(Seen) = .empty;
    var lines = std.mem.splitScalar(u8, log, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const value = try std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{});
        if (value != .object) continue;
        const entry_path = value.object.get("path") orelse continue;
        if (entry_path != .string or !std.mem.eql(u8, entry_path.string, path)) continue;
        const method = value.object.get("method") orelse continue;
        const conn = value.object.get("conn") orelse continue;
        const connection = value.object.get("connection");
        try out.append(arena, .{
            .method = if (method == .string) method.string else "",
            .conn = conn.integer,
            .connection = if (connection) |c| (if (c == .string) c.string else null) else null,
        });
    }
    return out.toOwnedSlice(arena);
}

test "MCP HTTP: one kept-alive connection carries the handshake and later calls" {
    var mock = (try Mock.start()) orelse return error.SkipZigTest;
    defer mock.stop();
    const a = std.testing.allocator;
    var buffer: [128]u8 = undefined;
    {
        // The mock drops any request that asks for `Connection: close`, as
        // developers.openai.com does intermittently.
        var client = try cc.mcp_client.McpClient.connectHttp(a, .{
            .io = std.testing.io,
            .url = try mock.url(&buffer, "keepalive"),
        }, .{ .spawn = undefined, .startup_timeout_ms = 10_000 });
        defer client.close();
        try std.testing.expectEqualStrings("2025-11-25", client.protocol_version);
        const tools = try client.listTools();
        defer a.free(tools);
        try std.testing.expect(std.mem.indexOf(u8, tools, "\"kept\"") != null);
        const called = try client.callTool("kept", "{}");
        defer a.free(called);
        try std.testing.expect(std.mem.indexOf(u8, called, "kept-call") != null);
    }
    const log = try mock.log(a);
    defer a.free(log);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const seen = try seenOn(arena.allocator(), log, "/keepalive");
    // server/discover (400 JSON), initialize (SSE), notifications/initialized
    // (202), tools/list (SSE), tools/call (JSON): one TCP connection.
    try std.testing.expectEqual(@as(usize, 5), seen.len);
    for (seen) |request| {
        try std.testing.expectEqual(seen[0].conn, request.conn);
        if (request.connection) |value| try std.testing.expect(!std.ascii.eqlIgnoreCase(value, "close"));
    }
}

test "MCP HTTP: a pooled connection the server closed is replaced, the request sent once" {
    var mock = (try Mock.start()) orelse return error.SkipZigTest;
    defer mock.stop();
    const a = std.testing.allocator;
    var buffer: [128]u8 = undefined;
    {
        var client = try cc.mcp_client.McpClient.connectHttp(a, .{
            .io = std.testing.io,
            .url = try mock.url(&buffer, "idleclose"),
        }, .{ .spawn = undefined, .startup_timeout_ms = 10_000 });
        defer client.close();
        // The server closes each connection 50 ms after answering; the pooled
        // one is dead by now.
        cc.util_time.sleepMs(300);
        const tools = try client.listTools();
        defer a.free(tools);
        try std.testing.expect(std.mem.indexOf(u8, tools, "\"kept\"") != null);
    }
    const log = try mock.log(a);
    defer a.free(log);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const seen = try seenOn(arena.allocator(), log, "/idleclose");
    var lists: usize = 0;
    for (seen) |request| lists += @intFromBool(std.mem.eql(u8, request.method, "tools/list"));
    try std.testing.expectEqual(@as(usize, 1), lists);
}

test "MCP HTTP: a connection idle past the reuse window is not reused" {
    var mock = (try Mock.start()) orelse return error.SkipZigTest;
    defer mock.stop();
    const a = std.testing.allocator;
    var buffer: [128]u8 = undefined;
    {
        var client = try cc.mcp_client.McpClient.connectHttp(a, .{
            .io = std.testing.io,
            .url = try mock.url(&buffer, "keepalive"),
        }, .{ .spawn = undefined, .startup_timeout_ms = 10_000 });
        defer client.close();
        client.transport.http.reuse_idle_ms = 100;
        const tools = try client.listTools();
        defer a.free(tools);
        cc.util_time.sleepMs(300);
        const called = try client.callTool("kept", "{}");
        defer a.free(called);
    }
    const log = try mock.log(a);
    defer a.free(log);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const seen = try seenOn(arena.allocator(), log, "/keepalive");
    try std.testing.expectEqualStrings("tools/list", seen[seen.len - 2].method);
    try std.testing.expectEqualStrings("tools/call", seen[seen.len - 1].method);
    try std.testing.expect(seen[seen.len - 2].conn != seen[seen.len - 1].conn);
}

test "MCP HTTP: a tools/call whose connection dies unanswered is indeterminate, and never sent twice" {
    var mock = (try Mock.start()) orelse return error.SkipZigTest;
    defer mock.stop();
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var buffer: [128]u8 = undefined;
    {
        var client = try cc.mcp_client.McpClient.connectHttp(a, .{
            .io = std.testing.io,
            .url = try mock.url(&buffer, "dropcall"),
        }, .{ .spawn = undefined, .startup_timeout_ms = 10_000 });
        defer client.close();
        const tools = try client.listTools();
        defer a.free(tools);

        // On the connection the handshake kept alive: the same failure a dead
        // pooled connection gives a repeatable method, which is retried.
        try std.testing.expectError(error.McpOutcomeIndeterminate, client.callTool("kept", "{}"));

        // Through the registry, as the model reaches it: the failure says the
        // call may have run. The next call is the model's decision.
        var registry = cc.tools_dynamic.DynRegistry.init(a);
        defer registry.deinit();
        var session = cc.mcp_registry_bridge.McpSession.init(a, &client);
        defer session.deinit();
        try session.registerToolsFiltered(&registry, "d", .{ .http_param_headers = true });
        var detail: ?[]const u8 = null;
        defer if (detail) |text| a.free(text);
        var ctx = cc.tools.ToolContext.simple(a);
        ctx.artifact_root = root;
        ctx.error_detail = &detail;
        try std.testing.expectError(
            error.McpOutcomeIndeterminate,
            registry.find("mcp__d__kept").?.execute(&ctx, "{}"),
        );
        try std.testing.expect(std.mem.indexOf(u8, detail.?, "may have executed") != null);
    }
    const log = try mock.log(a);
    defer a.free(log);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const seen = try seenOn(arena.allocator(), log, "/dropcall");
    var calls: usize = 0;
    for (seen) |request| calls += @intFromBool(std.mem.eql(u8, request.method, "tools/call"));
    // One each from the two attempts this test made, and no more.
    try std.testing.expectEqual(@as(usize, 2), calls);
}

test "MCP HTTP: a tools/call does not reuse a connection idle past its shorter window" {
    var mock = (try Mock.start()) orelse return error.SkipZigTest;
    defer mock.stop();
    const a = std.testing.allocator;
    var buffer: [128]u8 = undefined;
    {
        var client = try cc.mcp_client.McpClient.connectHttp(a, .{
            .io = std.testing.io,
            .url = try mock.url(&buffer, "keepalive"),
        }, .{ .spawn = undefined, .startup_timeout_ms = 10_000 });
        defer client.close();
        const tools = try client.listTools();
        defer a.free(tools);
        cc.util_time.sleepMs(cc.mcp_transport_http.TOOL_CALL_REUSE_IDLE_MS + 200);
        const called = try client.callTool("kept", "{}");
        defer a.free(called);
    }
    const log = try mock.log(a);
    defer a.free(log);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const seen = try seenOn(arena.allocator(), log, "/keepalive");
    try std.testing.expectEqualStrings("tools/call", seen[seen.len - 1].method);
    try std.testing.expect(seen[seen.len - 2].conn != seen[seen.len - 1].conn);
}

test "MCP HTTP: a stale answer is skipped and tools/list_changed is recorded, on both call paths" {
    var mock = (try Mock.start()) orelse return error.SkipZigTest;
    defer mock.stop();
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var buffer: [128]u8 = undefined;
    var client = try cc.mcp_client.McpClient.connectHttp(a, .{
        .io = std.testing.io,
        .url = try mock.url(&buffer, "noisy"),
    }, .{ .spawn = undefined, .startup_timeout_ms = 10_000 });
    defer client.close();
    try std.testing.expect(!client.tools_changed.load(.acquire));
    const called = try client.callTool("noise", "{}");
    defer a.free(called);
    try std.testing.expect(std.mem.indexOf(u8, called, "noise-done") != null);
    try std.testing.expect(std.mem.indexOf(u8, called, "stale") == null);
    try std.testing.expect(client.tools_changed.load(.acquire));

    client.tools_changed.store(false, .release);
    var body = try client.callToolBodyAbortable("noise", "{}", root, .{}, null);
    defer body.deinit(a);
    try std.testing.expect(std.mem.indexOf(u8, body.@"inline".bytes, "noise-done") != null);
    try std.testing.expect(client.tools_changed.load(.acquire));
}

test "MCP HTTP: a tool's isError reaches the model as a tool error through the registry" {
    var mock = (try Mock.start()) orelse return error.SkipZigTest;
    defer mock.stop();
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buffer[0..try tmp.dir.realPath(std.testing.io, &root_buffer)];
    var buffer: [128]u8 = undefined;
    var client = try cc.mcp_client.McpClient.connectHttp(a, .{
        .io = std.testing.io,
        .url = try mock.url(&buffer, "noisy"),
    }, .{ .spawn = undefined, .startup_timeout_ms = 10_000 });
    defer client.close();
    var registry = cc.tools_dynamic.DynRegistry.init(a);
    defer registry.deinit();
    var session = cc.mcp_registry_bridge.McpSession.init(a, &client);
    defer session.deinit();
    try session.registerToolsFromJson(&registry, "m", "{\"tools\":[{\"name\":\"toolerror\"}]}");
    var ctx = cc.tools.ToolContext.simple(a);
    ctx.artifact_root = root;
    var body = try registry.find("mcp__m__toolerror").?.execute(&ctx, "{}");
    defer body.deinit(a);
    try std.testing.expect(body == .structured_error);
    try std.testing.expect(std.mem.indexOf(u8, body.structured_error.encoded, "tool said no") != null);
}
