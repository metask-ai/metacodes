//! HTTP+SSE transport, Streamable HTTP resumption and MCP OAuth against
//! tests/_harness/mock_mcp_auth_server.py:
//!
//! - `type: "sse"` opens the event stream, POSTs to the `endpoint` it names
//!   and reads every answer from the stream; an endpoint on another origin
//!   is refused, and a URL that is not an event stream says so.
//! - A Streamable HTTP SSE response that drops before its answer is resumed
//!   with `Last-Event-ID`.
//! - `mcp_oauth.login` discovers (WWW-Authenticate → RFC 9728 → RFC 8414),
//!   registers (RFC 7591), authorizes with PKCE S256 and `resource`, and
//!   stores the token; a session sends it, and after the server stops
//!   accepting it the transport refreshes (rotating the stored refresh
//!   token) and retries the call.
//! - The configuration reaches the wire: MCP startup from a `config.json`
//!   with an `sse` server and an HTTP server with a stored login connects
//!   both.

const std = @import("std");
const builtin = @import("builtin");
const cc = @import("cc");
const process = @import("platform").process;

const MOCK = "tests/_harness/mock_mcp_auth_server.py";

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

    fn get(self: *const Mock, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
        var client: std.http.Client = .{ .allocator = allocator, .io = std.testing.io };
        defer client.deinit();
        var buffer: [128]u8 = undefined;
        const target = try self.url(&buffer, path);
        var body: std.Io.Writer.Allocating = .init(allocator);
        defer body.deinit();
        _ = try client.fetch(.{ .location = .{ .url = target }, .response_writer = &body.writer });
        return body.toOwnedSlice();
    }

    fn post(self: *const Mock, path: []const u8) !void {
        var client: std.http.Client = .{ .allocator = std.testing.allocator, .io = std.testing.io };
        defer client.deinit();
        var buffer: [128]u8 = undefined;
        _ = try client.fetch(.{ .location = .{ .url = try self.url(&buffer, path) }, .method = .POST, .payload = "" });
    }

    /// The observations whose `path` is `path`, parsed.
    fn seen(self: *const Mock, arena: std.mem.Allocator, path: []const u8) ![]std.json.ObjectMap {
        const log = try self.get(arena, "log");
        var out: std.ArrayList(std.json.ObjectMap) = .empty;
        var lines = std.mem.splitScalar(u8, log, '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            const value = try std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{});
            if (value != .object) continue;
            const entry_path = value.object.get("path") orelse continue;
            if (entry_path == .string and std.mem.eql(u8, entry_path.string, path)) try out.append(arena, value.object);
        }
        return out.toOwnedSlice(arena);
    }
};

fn field(object: std.json.ObjectMap, comptime path: []const []const u8) ?[]const u8 {
    var current: std.json.Value = .{ .object = object };
    inline for (path) |key| {
        if (current != .object) return null;
        current = current.object.get(key) orelse return null;
    }
    return if (current == .string) current.string else null;
}

test "MCP SSE: the endpoint event names where to POST; answers arrive on the stream" {
    var mock = (try Mock.start()) orelse return error.SkipZigTest;
    defer mock.stop();
    const a = std.testing.allocator;
    var buffer: [128]u8 = undefined;
    {
        var client = try cc.mcp_client.McpClient.connectHttp(a, .{
            .io = std.testing.io,
            .url = try mock.url(&buffer, "sse"),
            .headers = &.{.{ .name = "X-Team", .value = "t1" }},
            .wire = .legacy_sse,
        }, .{ .spawn = undefined, .startup_timeout_ms = 10_000 });
        defer client.close();
        try std.testing.expectEqualStrings("2024-11-05", client.protocol_version);
        const tools = try client.listTools();
        defer a.free(tools);
        try std.testing.expect(std.mem.indexOf(u8, tools, "\"whoami\"") != null);
        const called = try client.callTool("whoami", "{}");
        defer a.free(called);
        try std.testing.expect(std.mem.indexOf(u8, called, "called:whoami") != null);
    }
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const posts = try mock.seen(arena.allocator(), "/sse/messages");
    // initialize, notifications/initialized, tools/list, tools/call — every
    // one on the endpoint, with the configured header and, after the
    // handshake, the negotiated revision.
    try std.testing.expectEqual(@as(usize, 4), posts.len);
    for (posts) |entry| try std.testing.expectEqualStrings("t1", field(entry, &.{ "headers", "x-team" }).?);
    try std.testing.expectEqualStrings("2024-11-05", field(posts[3], &.{ "headers", "mcp-protocol-version" }).?);
}

test "MCP SSE: an endpoint on another origin is refused; a non-stream URL says so" {
    var mock = (try Mock.start()) orelse return error.SkipZigTest;
    defer mock.stop();
    var buffer: [128]u8 = undefined;
    try std.testing.expectError(error.McpEndpointOriginMismatch, cc.mcp_client.McpClient.connectHttp(std.testing.allocator, .{
        .io = std.testing.io,
        .url = try mock.url(&buffer, "sse-foreign"),
        .wire = .legacy_sse,
    }, .{ .spawn = undefined, .startup_timeout_ms = 5_000 }));
    try std.testing.expectError(error.McpNotEventStream, cc.mcp_client.McpClient.connectHttp(std.testing.allocator, .{
        .io = std.testing.io,
        .url = try mock.url(&buffer, "resume"),
        .wire = .legacy_sse,
    }, .{ .spawn = undefined, .startup_timeout_ms = 5_000 }));
}

test "MCP HTTP: an SSE response dropped before its answer resumes with Last-Event-ID" {
    var mock = (try Mock.start()) orelse return error.SkipZigTest;
    defer mock.stop();
    const a = std.testing.allocator;
    var buffer: [128]u8 = undefined;
    {
        var client = try cc.mcp_client.McpClient.connectHttp(a, .{
            .io = std.testing.io,
            .url = try mock.url(&buffer, "resume"),
        }, .{ .spawn = undefined, .startup_timeout_ms = 10_000 });
        defer client.close();
        client.transport.setDeadline(cc.util_time.nowMs() + 10_000);
        const called = try client.callTool("whoami", "{}");
        defer a.free(called);
        try std.testing.expect(std.mem.indexOf(u8, called, "called:whoami") != null);
    }
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var resumed: usize = 0;
    for (try mock.seen(arena.allocator(), "/resume")) |entry| {
        if (!std.mem.eql(u8, field(entry, &.{"method"}) orelse "", "GET")) continue;
        resumed += 1;
        try std.testing.expectEqualStrings("e1", field(entry, &.{"last_event_id"}).?);
        try std.testing.expectEqualStrings("resume-1", field(entry, &.{"session"}).?);
    }
    try std.testing.expectEqual(@as(usize, 1), resumed);
}

/// Plays the browser: follows the authorization redirect to the loopback
/// callback on a thread of its own (the login is waiting for it).
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
        // The callback listens on 127.0.0.1; "localhost" is what the
        // authorization server was told.
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

fn tmpRoot(tmp: *std.testing.TmpDir, buffer: []u8) ![]const u8 {
    const len = try tmp.dir.realPath(std.testing.io, buffer);
    return buffer[0..len];
}

test "MCP OAuth: login discovers, registers, authorizes with PKCE; sessions send and refresh the token" {
    var mock = (try Mock.start()) orelse return error.SkipZigTest;
    defer mock.stop();
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const state_root = try tmpRoot(&tmp, &root_buffer);
    var url_buffer: [128]u8 = undefined;
    const url = try mock.url(&url_buffer, "oauth-mcp");

    // Without a login the server's 401 is an authorization error.
    try std.testing.expectError(error.McpAuthRequired, cc.mcp_client.McpClient.connectHttp(a, .{
        .io = std.testing.io,
        .url = url,
    }, .{ .spawn = undefined, .startup_timeout_ms = 5_000 }));

    var browser: Browser = .{};
    var result = cc.mcp_oauth.login(a, std.testing.io, state_root, .{
        .name = "authd",
        .target = .{ .url = url, .wire = .streamable },
    }, .{ .open_browser = false, .open_url = browser.opener() }) catch |err| {
        browser.finish();
        return err;
    };
    browser.finish();
    defer result.deinit(a);
    var base_buffer: [64]u8 = undefined;
    const base = try std.fmt.bufPrint(&base_buffer, "http://127.0.0.1:{d}", .{mock.port});
    try std.testing.expect(std.mem.startsWith(u8, result.issuer, base) and std.mem.endsWith(u8, result.issuer, "/as"));

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    // Dynamic registration of a loopback redirect on Claude Code's path.
    const register = (try mock.seen(aa, "/as/register"))[0];
    const redirect_uris = register.get("body").?.object.get("redirect_uris").?.array.items;
    try std.testing.expect(std.mem.startsWith(u8, redirect_uris[0].string, "http://localhost:"));
    try std.testing.expect(std.mem.endsWith(u8, redirect_uris[0].string, "/callback"));
    // The scope the challenge named, the RFC 8707 resource, PKCE S256.
    const authorize = (try mock.seen(aa, "/as/authorize"))[0];
    try std.testing.expectEqualStrings("mcp:tools", field(authorize, &.{ "query", "scope" }).?);
    try std.testing.expectEqualStrings(url, field(authorize, &.{ "query", "resource" }).?);
    try std.testing.expectEqualStrings("S256", field(authorize, &.{ "query", "code_challenge_method" }).?);
    // The mock checked code_verifier against the challenge and the resource.
    const token_requests = try mock.seen(aa, "/as/token");
    try std.testing.expectEqualStrings("authorization_code", field(token_requests[0], &.{ "form", "grant_type" }).?);

    {
        // Two sessions share the stored login.
        var client = try cc.mcp_client.McpClient.connectHttp(a, .{
            .io = std.testing.io,
            .url = url,
            .auth = (try cc.mcp_oauth.TokenSource.load(a, std.testing.io, state_root, "authd", url)).?,
        }, .{ .spawn = undefined, .startup_timeout_ms = 10_000 });
        defer client.close();
        var other = try cc.mcp_client.McpClient.connectHttp(a, .{
            .io = std.testing.io,
            .url = url,
            .auth = (try cc.mcp_oauth.TokenSource.load(a, std.testing.io, state_root, "authd", url)).?,
        }, .{ .spawn = undefined, .startup_timeout_ms = 10_000 });
        defer other.close();
        const first = try client.callTool("whoami", "{}");
        defer a.free(first);
        try std.testing.expect(std.mem.indexOf(u8, first, "token:at-1") != null);

        // The server stops accepting the token: the 401 is answered with one
        // refresh and the call is retried with the new token.
        try mock.post("control/revoke");
        const second = try client.callTool("whoami", "{}");
        defer a.free(second);
        try std.testing.expect(std.mem.indexOf(u8, second, "token:at-2") != null);

        // The other session's 401 adopts the token the first one stored
        // instead of spending the refresh token that rotation killed.
        const third = try other.callTool("whoami", "{}");
        defer a.free(third);
        try std.testing.expect(std.mem.indexOf(u8, third, "token:at-2") != null);
    }
    const refreshes = try mock.seen(aa, "/as/token");
    try std.testing.expectEqual(@as(usize, 2), refreshes.len);
    try std.testing.expectEqualStrings("refresh_token", field(refreshes[1], &.{ "form", "grant_type" }).?);
    try std.testing.expectEqualStrings("rt-1", field(refreshes[1], &.{ "form", "refresh_token" }).?);
    try std.testing.expectEqualStrings(url, field(refreshes[1], &.{ "form", "resource" }).?);
    // The rotated refresh token is what the store holds now.
    var record = (try cc.mcp_oauth.loadRecord(a, result.path, url)).?;
    defer record.deinit(a);
    try std.testing.expectEqualStrings("rt-2", record.refresh_token.?);
    try std.testing.expectEqualStrings("at-2", record.access_token);
}

test "MCP OAuth: configuration reaches the wire — startup connects an sse server and a logged-in http server" {
    var mock = (try Mock.start()) orelse return error.SkipZigTest;
    defer mock.stop();
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const state_root = try tmpRoot(&tmp, &root_buffer);
    var sse_buffer: [128]u8 = undefined;
    const sse_url = try mock.url(&sse_buffer, "sse-oauth");
    var http_buffer: [128]u8 = undefined;
    const http_url = try mock.url(&http_buffer, "oauth-mcp");

    // Log in to both: the SSE server discovers through a GET probe of its
    // stream.
    for ([_]struct { name: []const u8, url: []const u8, wire: cc.mcp_config.HttpWire }{
        .{ .name = "linear", .url = sse_url, .wire = .legacy_sse },
        .{ .name = "authd", .url = http_url, .wire = .streamable },
    }) |server| {
        var browser: Browser = .{};
        var result = cc.mcp_oauth.login(a, std.testing.io, state_root, .{
            .name = server.name,
            .target = .{ .url = server.url, .wire = server.wire },
        }, .{ .open_browser = false, .open_url = browser.opener() }) catch |err| {
            browser.finish();
            return err;
        };
        browser.finish();
        result.deinit(a);
    }

    const config = try std.fmt.allocPrint(a,
        \\{{"mcpServers":{{"linear":{{"type":"sse","url":"{s}"}},"authd":{{"type":"http","url":"{s}"}}}}}}
    , .{ sse_url, http_url });
    defer a.free(config);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "config.json", .data = config });

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    var status: cc.app_mcp_startup.Status = .{};
    const startup = try cc.app_mcp_startup.Startup.begin(arena.allocator(), &status, .{
        .io = std.testing.io,
        .state_root = state_root,
        .home = state_root,
        .cwd = state_root,
        .workspace_root = "",
        .codex_home = state_root,
    });
    startup.join();
    defer startup.cancelAndJoin();
    try std.testing.expectEqual(@as(usize, 2), startup.jobs.len);
    for (startup.jobs) |*job| {
        switch (job.result) {
            .connected => |connected| try std.testing.expect(std.mem.indexOf(u8, connected.tools_json, "\"whoami\"") != null),
            .failed => |err| {
                std.debug.print("server {s} failed: {s}\n", .{ job.server.name, @errorName(err) });
                return error.TestUnexpectedResult;
            },
            .pending => unreachable,
        }
    }
    for (startup.jobs) |*job| {
        const wire: std.meta.Tag(cc.mcp_transport.Transport) = if (std.mem.eql(u8, job.server.name, "linear")) .sse else .http;
        try std.testing.expectEqual(wire, std.meta.activeTag(job.result.connected.client.transport));
    }
    // The stream GET carried the stored token.
    const streams = try mock.seen(arena.allocator(), "/sse-oauth");
    const last = streams[streams.len - 1];
    try std.testing.expect(std.mem.startsWith(u8, field(last, &.{ "headers", "authorization" }).?, "Bearer at-"));
}
