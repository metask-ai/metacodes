//! L2 evidence for #467: a model stream is never requested gzip-encoded.
//!
//! Zig 0.16's `std.http.Client` sends `Accept-Encoding: gzip, deflate` unless
//! a request says otherwise. The provider clients read the response body
//! with `Response.reader`, which hands over the bytes as they arrived, so a
//! server that takes the offer (DeepSeek does) fed gzip bytes to the SSE
//! parser: no event parsed, and the turn failed with `StreamIncomplete`
//! after every retry.
//!
//! The mock server here answers like DeepSeek: a request that offers gzip
//! gets its body gzip-compressed. Each provider must still stream the whole
//! answer, because it no longer offers gzip. The first test proves the mock
//! does compress when asked, so the provider tests cannot pass vacuously.
//! Bedrock's case is in bedrock_converse_test.zig, next to its frame helpers.
//!
//! Not offering gzip is not enough on its own: `receiveHead` checks the
//! answer against the request's `accept_encoding` set, which still allowed
//! gzip and deflate, so a server or gateway that compresses unasked got its
//! bytes to the parser all the same. Every request in `src/` sends through
//! `api/http_connection.zig`, which now makes that set identity only. The
//! last tests here serve gzip unasked: the request is refused at the head,
//! on every model client and on the send path itself.

const std = @import("std");
const harness = @import("harness");
const cc = @import("cc");

const http_connection = cc.api_http_connection;

const ANTHROPIC_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":0,\"output_tokens\":0}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"hello \"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"world\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":2}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const OPENAI_SSE =
    "data: {\"choices\":[{\"delta\":{\"role\":\"assistant\",\"content\":\"hello \"}}]}\n\n" ++
    "data: {\"choices\":[{\"delta\":{\"content\":\"world\"}}]}\n\n" ++
    "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n" ++
    "data: [DONE]\n\n";

const GEMINI_SSE =
    "data: {\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"text\":\"hello \"}]}}]}\n\n" ++
    "data: {\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"text\":\"world\"}]},\"finishReason\":\"STOP\"}]}\n\n";

const HI = [_]cc.types_mod.ApiMessage{
    .{ .role = .user, .content = &[_]cc.types_mod.ApiContent{.{ .text = "hi" }} },
};

fn headerValue(captured: harness.CapturedRequest, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, captured.raw, "\r\n");
    _ = lines.next(); // request line
    while (lines.next()) |line| {
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " "), name)) continue;
        return std.mem.trim(u8, line[colon + 1 ..], " ");
    }
    return null;
}

/// Drain one stream: the whole answer's text and its stop reason.
fn expectWholeAnswer(a: std.mem.Allocator, provider: cc.api_provider.Provider, srv: *harness.MockServer) !void {
    var handle = try provider.sendStream(&HI, null, null, null, null, null, "");
    defer handle.deinit();
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(a);
    while (try handle.next()) |event| switch (event) {
        .text => |bytes| {
            defer a.free(bytes);
            try text.appendSlice(a, bytes);
        },
        .thinking => |bytes| a.free(bytes),
        .reasoning_item => |bytes| a.free(bytes),
        .tool_use_start => |tu| {
            a.free(tu.id);
            a.free(tu.name);
            a.free(tu.input_json);
        },
        else => {},
    };
    try std.testing.expectEqualStrings("hello world", text.items);
    try std.testing.expectEqual(cc.api_stream.StopReason.end_turn, handle.stopReason());

    // The request offered no content coding, so the body came back plain.
    try std.testing.expectEqual(@as(usize, 1), srv.requestCount());
    const captured = srv.lastRequest() orelse return error.NoRequestCaptured;
    try std.testing.expectEqual(@as(?[]const u8, null), headerValue(captured, "accept-encoding"));
    try std.testing.expectEqual(@as(u32, 0), srv.gzipResponses());
}

test "#467 control: the mock compresses the body for a request that offers gzip" {
    const a = std.testing.allocator;
    var srv = try harness.MockServer.startCassetteGzipWhenAccepted(&.{OPENAI_SSE});
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    var io_rt = @import("platform").signal.threadedIo(a, .{});
    defer io_rt.deinit();
    var client: std.http.Client = .{ .allocator = a, .io = io_rt.io() };
    defer client.deinit();
    // std's defaults: this is the offer the provider clients used to make.
    var request = try client.request(.POST, try std.Uri.parse(url), .{ .keep_alive = false });
    defer request.deinit();
    try request.sendBodyComplete(@constCast("{}"));
    var response = try request.receiveHead(&.{});
    try std.testing.expectEqual(std.http.ContentEncoding.gzip, response.head.content_encoding);

    var transfer_buf: [64]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    const decompress_buf = try a.alloc(u8, std.compress.flate.max_window_len);
    defer a.free(decompress_buf);
    const reader = response.readerDecompressing(&transfer_buf, &decompress, decompress_buf);
    const body = try reader.allocRemaining(a, .unlimited);
    defer a.free(body);
    try std.testing.expectEqualStrings(OPENAI_SSE, body);
    try std.testing.expectEqual(@as(u32, 1), srv.gzipResponses());

    const captured = srv.lastRequest() orelse return error.NoRequestCaptured;
    try std.testing.expect(std.mem.indexOf(u8, headerValue(captured, "accept-encoding").?, "gzip") != null);
}

test "#467 L2: the Anthropic Messages stream is requested uncompressed and read whole" {
    const a = std.testing.allocator;
    var srv = try harness.MockServer.startCassetteGzipWhenAccepted(&.{ANTHROPIC_SSE});
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);
    var io_rt = @import("platform").signal.threadedIo(a, .{});
    defer io_rt.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(a, io_rt.io(), "test-key", "claude-sonnet-4-20250514", url);
    defer client.deinit();
    try expectWholeAnswer(a, client.provider(), srv);
}

test "#467 L2: the OpenAI chat stream is requested uncompressed and read whole" {
    const a = std.testing.allocator;
    var srv = try harness.MockServer.startCassetteGzipWhenAccepted(&.{OPENAI_SSE});
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);
    var io_rt = @import("platform").signal.threadedIo(a, .{});
    defer io_rt.deinit();
    var client = cc.api_openai.OpenAIClient.init(a, io_rt.io(), "test-key", "deepseek-chat", url);
    defer client.deinit();
    try expectWholeAnswer(a, client.provider(), srv);
}

test "#467 L2: the Gemini stream is requested uncompressed and read whole" {
    const a = std.testing.allocator;
    var srv = try harness.MockServer.startCassetteGzipWhenAccepted(&.{GEMINI_SSE});
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);
    var io_rt = @import("platform").signal.threadedIo(a, .{});
    defer io_rt.deinit();
    var client = cc.api_gemini.GeminiClient.init(a, io_rt.io(), "test-key", "gemini-2.5-flash", url);
    defer client.deinit();
    try expectWholeAnswer(a, client.provider(), srv);
}

/// A provider's stream request, answered with gzip it did not offer, must
/// fail at the response head: no stream opens, so no parser sees the bytes.
fn expectRefusedAtHead(provider: cc.api_provider.Provider, srv: *harness.MockServer) !void {
    if (provider.sendStream(&HI, null, null, null, null, null, "")) |opened| {
        var handle = opened;
        handle.deinit();
        return error.CompressedAnswerReachedTheParser;
    } else |err| try std.testing.expectEqual(error.RequestFailed, err);
    // The server did compress, and the one attempt was not re-sent.
    try std.testing.expectEqual(@as(u32, 1), srv.gzipResponses());
    try std.testing.expectEqual(@as(usize, 1), srv.requestCount());
}

test "#467 L2: a request sent through http_connection accepts only an uncompressed answer" {
    const a = std.testing.allocator;
    var srv = try harness.MockServer.startCassetteGzipUnasked(&.{OPENAI_SSE});
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);
    const uri = try std.Uri.parse(url);
    var io_rt = @import("platform").signal.threadedIo(a, .{});
    defer io_rt.deinit();
    var client: std.http.Client = .{ .allocator = a, .io = io_rt.io() };
    defer client.deinit();

    // A send with a body and std's default header, as the OAuth, telemetry
    // and catalog requests make: it says identity, and gzip is refused.
    {
        var request = try client.request(.POST, uri, .{ .keep_alive = false });
        defer request.deinit();
        try http_connection.sendBodyComplete(&request, @constCast("{}"));
        try std.testing.expectError(error.HttpContentEncodingUnsupported, request.receiveHead(&.{}));
    }
    const first = srv.requestAt(0) orelse return error.NoRequestCaptured;
    try std.testing.expectEqualStrings("identity", headerValue(first, "accept-encoding") orelse "");

    // A bodiless send that omits the header, as the model clients and MCP
    // transports do: no header goes out, and gzip is refused all the same.
    {
        var request = try client.request(.GET, uri, .{ .keep_alive = false, .headers = .{ .accept_encoding = .omit } });
        defer request.deinit();
        try http_connection.sendBodiless(&request);
        try std.testing.expectError(error.HttpContentEncodingUnsupported, request.receiveHead(&.{}));
    }
    const second = srv.requestAt(1) orelse return error.NoRequestCaptured;
    try std.testing.expectEqual(@as(?[]const u8, null), headerValue(second, "accept-encoding"));
    try std.testing.expectEqual(@as(u32, 2), srv.gzipResponses());
}

test "#467 L2: the Anthropic Messages stream refuses gzip it did not offer" {
    const a = std.testing.allocator;
    var srv = try harness.MockServer.startCassetteGzipUnasked(&.{ANTHROPIC_SSE});
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);
    var io_rt = @import("platform").signal.threadedIo(a, .{});
    defer io_rt.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(a, io_rt.io(), "test-key", "claude-sonnet-4-20250514", url);
    defer client.deinit();
    try expectRefusedAtHead(client.provider(), srv);
}

test "#467 L2: the OpenAI chat and Responses streams refuse gzip they did not offer" {
    const a = std.testing.allocator;
    for ([_]cc.types_mod.OpenAIProtocol{ .chat_completions, .responses }) |protocol| {
        errdefer std.debug.print("protocol={s}\n", .{@tagName(protocol)});
        var srv = try harness.MockServer.startCassetteGzipUnasked(&.{OPENAI_SSE});
        defer srv.stop();
        const url = try srv.urlOwned(a);
        defer a.free(url);
        var io_rt = @import("platform").signal.threadedIo(a, .{});
        defer io_rt.deinit();
        var client = cc.api_openai.OpenAIClient.init(a, io_rt.io(), "test-key", "deepseek-chat", url);
        defer client.deinit();
        client.protocol = protocol;
        try expectRefusedAtHead(client.provider(), srv);
    }
}

test "#467 L2: the Gemini stream refuses gzip it did not offer" {
    const a = std.testing.allocator;
    var srv = try harness.MockServer.startCassetteGzipUnasked(&.{GEMINI_SSE});
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);
    var io_rt = @import("platform").signal.threadedIo(a, .{});
    defer io_rt.deinit();
    var client = cc.api_gemini.GeminiClient.init(a, io_rt.io(), "test-key", "gemini-2.5-flash", url);
    defer client.deinit();
    try expectRefusedAtHead(client.provider(), srv);
}
