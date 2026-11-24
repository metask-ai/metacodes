//! L2 evidence: a connection whose request failed while sending is never used
//! for another request.
//!
//! std's `Request.deinit` (Zig 0.16) returns a connection to the client's
//! pool unless it is marked `closing`, and only a failed `receiveHead` marks
//! it; a failed send does not. A connection the peer reset in the middle of a
//! large request body went back to the pool, and every later request to that
//! host took it again and failed on its first write. On 2026-10-29 a TUI with
//! a 2.5 MB context failed every request in 4 ms for twenty minutes, ten
//! retries a message, without opening a single TCP connection, while a fresh
//! process worked. `api/http_connection.zig` closes such a connection; the
//! source guard below keeps every send in `src/` going through it.
//!
//! The server reads each reset request's head and closes with the body
//! unread, which resets the connection while the client is still writing.

const std = @import("std");
const builtin = @import("builtin");
const harness = @import("harness");
const cc = @import("cc");

const http_connection = cc.api_http_connection;

/// Far more than loopback socket buffers hold, so the reset lands mid-send.
const LARGE_BODY_BYTES: usize = 16 * 1024 * 1024;

/// The behaviour cases need a send that fails partway through its body.
/// Windows does not produce one: there a large loopback send completes once
/// it is queued, and on CI (runs 40867836680 and 40870213906) the 16 MB send
/// returned without error, even against an 8 KB receive window, and the
/// reset surfaced in `receiveHead`, where std closes the connection itself.
/// The wrapper and the source guard do not depend on the platform; the guard
/// runs everywhere.
fn requireSendFailingMidBody() !void {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
}

const ANTHROPIC_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":0,\"output_tokens\":0}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"ok\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":0}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const OPENAI_SSE =
    "data: {\"choices\":[{\"delta\":{\"role\":\"assistant\",\"content\":\"ok\"}}]}\n\n" ++
    "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n" ++
    "data: [DONE]\n\n";

const GEMINI_SSE =
    "data: {\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"text\":\"ok\"}]},\"finishReason\":\"STOP\"}]}\n\n";

const REQUEST_OPTIONS: std.http.Client.RequestOptions = .{
    .keep_alive = false,
    .redirect_behavior = .unhandled,
};

fn largeBody(allocator: std.mem.Allocator) ![]u8 {
    const body = try allocator.alloc(u8, LARGE_BODY_BYTES);
    @memset(body, 'x');
    return body;
}

/// A small request on `client` that must reach the server and get its 200.
fn expectServed(client: *std.http.Client, uri: std.Uri) !void {
    var request = try client.request(.POST, uri, REQUEST_OPTIONS);
    defer request.deinit();
    try http_connection.sendBodyComplete(&request, @constCast("{}"));
    var redirect: [1024]u8 = undefined;
    const response = try request.receiveHead(&redirect);
    try std.testing.expectEqual(@as(u16, 200), cc.api_http_status.ResponseStatus.capture(&response).code);
}

// The control: what std does without the helper. If this starts failing, std
// closes such a connection itself and the helper is no longer needed.
// The second half shows the helper's bodiless send recovering a pool that a
// raw send left poisoned.
test "L2 send failure: std pools the connection a failed send leaves behind; sendBodiless drops it" {
    try requireSendFailingMidBody();
    const a = std.testing.allocator;
    var srv = try harness.MockServer.startResetDuringUpload(ANTHROPIC_SSE, 1);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);
    const uri = try std.Uri.parse(url);
    const body = try largeBody(a);
    defer a.free(body);

    var io_runtime = @import("platform").signal.threadedIo(a, .{});
    defer io_runtime.deinit();
    var client: std.http.Client = .{ .allocator = a, .io = io_runtime.io() };
    defer client.deinit();

    {
        var request = try client.request(.POST, uri, REQUEST_OPTIONS);
        defer request.deinit();
        try std.testing.expectError(error.WriteFailed, request.sendBodyComplete(body));
    }
    try std.testing.expectEqual(@as(usize, 1), client.connection_pool.free_len);

    // The next request to the host takes the reset connection out of the pool.
    {
        var request = try client.request(.GET, uri, REQUEST_OPTIONS);
        defer request.deinit();
        try std.testing.expectError(error.WriteFailed, http_connection.sendBodiless(&request));
    }
    try std.testing.expectEqual(@as(usize, 0), client.connection_pool.free_len);

    try expectServed(&client, uri);
    try std.testing.expectEqual(@as(u32, 1), srv.uploadResets());
    try std.testing.expectEqual(@as(usize, 1), srv.requestCount());
}

test "L2 send failure: http_connection.sendBodyComplete closes the connection and the next request opens a new one" {
    try requireSendFailingMidBody();
    const a = std.testing.allocator;
    var srv = try harness.MockServer.startResetDuringUpload(ANTHROPIC_SSE, 1);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);
    const uri = try std.Uri.parse(url);
    const body = try largeBody(a);
    defer a.free(body);

    var io_runtime = @import("platform").signal.threadedIo(a, .{});
    defer io_runtime.deinit();
    var client: std.http.Client = .{ .allocator = a, .io = io_runtime.io() };
    defer client.deinit();

    {
        var request = try client.request(.POST, uri, REQUEST_OPTIONS);
        defer request.deinit();
        try std.testing.expectError(error.WriteFailed, http_connection.sendBodyComplete(&request, body));
    }
    try std.testing.expectEqual(@as(usize, 0), client.connection_pool.free_len);

    try expectServed(&client, uri);
    try std.testing.expectEqual(@as(u32, 1), srv.uploadResets());
    try std.testing.expectEqual(@as(usize, 1), srv.requestCount());
}

/// One provider's reset request, then a small one that must open a stream.
/// Before the fix the second request failed on the reset connection without
/// reaching the server.
fn expectProviderRecovers(provider: cc.api_provider.Provider, srv: *harness.MockServer, large: []const u8) !void {
    const large_messages = [_]cc.types_mod.ApiMessage{
        .{ .role = .user, .content = &[_]cc.types_mod.ApiContent{.{ .text = large }} },
    };
    if (provider.sendStream(&large_messages, null, null, null, null, null, "")) |handle| {
        var opened = handle;
        opened.deinit();
        return error.TestExpectedSendFailure;
    } else |_| {}
    try std.testing.expectEqual(@as(u32, 1), srv.uploadResets());

    const small_messages = [_]cc.types_mod.ApiMessage{
        .{ .role = .user, .content = &[_]cc.types_mod.ApiContent{.{ .text = "hi" }} },
    };
    var handle = try provider.sendStream(&small_messages, null, null, null, null, null, "");
    handle.deinit();
    try std.testing.expectEqual(@as(usize, 1), srv.requestCount());
}

test "L2 send failure: each provider client opens a new connection after an upload is reset" {
    try requireSendFailingMidBody();
    const a = std.testing.allocator;
    var io_runtime = @import("platform").signal.threadedIo(a, .{});
    defer io_runtime.deinit();
    const large = try largeBody(a);
    defer a.free(large);
    var summary: [cc.api_last_error.SUMMARY_BUF_LEN]u8 = undefined;

    {
        var srv = try harness.MockServer.startResetDuringUpload(ANTHROPIC_SSE, 1);
        defer srv.stop();
        const url = try srv.urlOwned(a);
        defer a.free(url);
        var client = cc.client_mod.Client.initWithBaseUrl(a, io_runtime.io(), "test-key", "claude-sonnet-4-20250514", url);
        defer client.deinit();
        _ = cc.api_last_error.take(&summary);
        const large_messages = [_]cc.types_mod.ApiMessage{
            .{ .role = .user, .content = &[_]cc.types_mod.ApiContent{.{ .text = large }} },
        };
        // The Messages client names the failed step: the send, not the head.
        if (client.sendMessageStream(&large_messages, null, null)) |response| {
            var opened = response;
            opened.deinit();
            return error.TestExpectedSendFailure;
        } else |err| try std.testing.expectEqual(error.TransientNetwork, err);
        const said = cc.api_last_error.take(&summary) orelse return error.TestExpectedLastError;
        try std.testing.expect(std.mem.indexOf(u8, said, "WriteFailed") != null);

        const small_messages = [_]cc.types_mod.ApiMessage{
            .{ .role = .user, .content = &[_]cc.types_mod.ApiContent{.{ .text = "hi" }} },
        };
        var response = try client.sendMessageStream(&small_messages, null, null);
        response.deinit();
        try std.testing.expectEqual(@as(u32, 1), srv.uploadResets());
        try std.testing.expectEqual(@as(usize, 1), srv.requestCount());
    }
    {
        var srv = try harness.MockServer.startResetDuringUpload(OPENAI_SSE, 1);
        defer srv.stop();
        const url = try srv.urlOwned(a);
        defer a.free(url);
        var client = cc.api_openai.OpenAIClient.init(a, io_runtime.io(), "test-key", "gpt-4o", url);
        defer client.deinit();
        try expectProviderRecovers(client.provider(), srv, large);
    }
    {
        var srv = try harness.MockServer.startResetDuringUpload(GEMINI_SSE, 1);
        defer srv.stop();
        const url = try srv.urlOwned(a);
        defer a.free(url);
        var client = cc.api_gemini.GeminiClient.init(a, io_runtime.io(), "test-key", "gemini-2.5-flash", url);
        defer client.deinit();
        try expectProviderRecovers(client.provider(), srv, large);
    }
}

// The source guard: every request body or head in `src/` is sent through
// http_connection. A call to the `Request` method directly brings back a
// connection that survives its own failed send.
const SEND_METHODS = [_][]const u8{ ".sendBodyComplete(", ".sendBodiless(", ".sendBodilessUnflushed(", ".sendBody(" };
const HELPER_FILE = "src/api/http_connection.zig";

const SendScan = struct {
    /// Calls through `http_connection`.
    through_helper: usize = 0,
};

/// Append `path:line` for every send method called on anything but
/// `http_connection`. Whole-line comments are skipped.
fn scanSends(allocator: std.mem.Allocator, path: []const u8, text: []const u8, raw: *std.ArrayList(u8), scan: *SendScan) !void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    var number: usize = 0;
    while (lines.next()) |line| {
        number += 1;
        if (std.mem.startsWith(u8, std.mem.trimStart(u8, line, " \t"), "//")) continue;
        for (SEND_METHODS) |method| {
            var at: usize = 0;
            while (std.mem.indexOfPos(u8, line, at, method)) |hit| {
                at = hit + method.len;
                var start = hit;
                while (start > 0 and (std.ascii.isAlphanumeric(line[start - 1]) or line[start - 1] == '_')) start -= 1;
                if (std.mem.eql(u8, line[start..hit], "http_connection")) {
                    scan.through_helper += 1;
                } else {
                    try raw.print(allocator, "{s}:{d}\n", .{ path, number });
                }
            }
        }
    }
}

fn collectZigFiles(allocator: std.mem.Allocator, root: []const u8, out: *std.ArrayList([]u8)) !void {
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, root, .{ .iterate = true });
    defer dir.close(std.testing.io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
        // `/` on every platform: HELPER_FILE is compared as written, and the
        // walker gives Windows paths with backslashes.
        const path = try std.fs.path.join(allocator, &.{ root, entry.path });
        std.mem.replaceScalar(u8, path, '\\', '/');
        try out.append(allocator, path);
    }
}

test "L2 send failure: every HTTP send in src goes through http_connection" {
    const allocator = std.testing.allocator;
    var files: std.ArrayList([]u8) = .empty;
    defer {
        for (files.items) |path| allocator.free(path);
        files.deinit(allocator);
    }
    try collectZigFiles(allocator, "src", &files);
    try collectZigFiles(allocator, "apps", &files);
    try std.testing.expect(files.items.len > 100);

    var scan: SendScan = .{};
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(allocator);
    var saw_helper_file = false;
    for (files.items) |path| {
        if (std.mem.eql(u8, path, HELPER_FILE)) {
            saw_helper_file = true;
            continue;
        }
        const text = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(8 * 1024 * 1024));
        defer allocator.free(text);
        try scanSends(allocator, path, text, &raw, &scan);
    }
    try std.testing.expect(saw_helper_file);
    if (raw.items.len > 0) {
        std.debug.print("HTTP sends that bypass api/http_connection.zig:\n{s}", .{raw.items});
        return error.SendBypassesHttpConnection;
    }
    // Moves with the inventory: fewer means the scan stopped seeing them.
    try std.testing.expect(scan.through_helper >= 17);
}

test "L2 send failure: the source guard reports a direct send and skips comments" {
    const allocator = std.testing.allocator;
    const sample =
        \\    try request.sendBodiless();
        \\    req_ptr.sendBodyComplete(@constCast(body)) catch return;
        \\    // req.sendBodyComplete(body) explains the old way
        \\    try http_connection.sendBodyComplete(&request, body);
        \\    var writer = try self.request.sendBody(&buffer);
        \\    try http_connection.sendBodiless(&req);
    ;
    var scan: SendScan = .{};
    var raw: std.ArrayList(u8) = .empty;
    defer raw.deinit(allocator);
    try scanSends(allocator, "sample.zig", sample, &raw, &scan);
    try std.testing.expectEqualStrings("sample.zig:1\nsample.zig:2\nsample.zig:5\n", raw.items);
    try std.testing.expectEqual(@as(usize, 2), scan.through_helper);
}
