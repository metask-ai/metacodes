//! L2 #573: a stream read that fails names what failed beneath `ReadFailed`.
//!
//! std folds every transport failure into `ReadFailed`, and the clients'
//! "stream read failed" lines named only that. On 2026-11-18 the stream drops
//! behind a proxy could only be explained with a diagnostic build: both were
//! `TlsConnectionTruncated` with no close_notify, in a response whose head
//! said it would close. `client.ReadFailure` now goes into that line on every
//! wire: the body's, the TLS layer's and the socket's errors, the framing and
//! whether the server meant to keep the connection open.
//!
//! The mock here is plain HTTP: it cuts a chunked body short and closes, so
//! the body's error is `HttpChunkTruncated` and there is no TLS layer.

const std = @import("std");
const harness = @import("harness");
const cc = @import("cc");

const Wire = enum { anthropic, openai_chat, openai_responses, gemini, bedrock };
const ALL_WIRES = [_]Wire{ .anthropic, .openai_chat, .openai_responses, .gemini, .bedrock };

const MODEL = "read-failure-model";
const KEY = "read-failure-test-key";

/// What the cut leaves in the log: the body ended before its last chunk,
/// over a plain connection, and the server had said it would close.
const EXPECTED = "(body HttpChunkTruncated, plain, socket none; chunked, keep-alive no)";

fn complete(comptime wire: Wire) []const u8 {
    return switch (wire) {
        .anthropic => "data: {\"type\":\"message_start\",\"message\":{\"id\":\"m\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
            "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
            "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"answer\"}}\n\n" ++
            "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
            "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":2}}\n\n" ++
            "data: {\"type\":\"message_stop\"}\n\n",
        .openai_chat => "data: {\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"answer\"},\"finish_reason\":null}]}\n\n" ++
            "data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n" ++
            "data: [DONE]\n\n",
        .openai_responses => "event: response.output_text.delta\n" ++
            "data: {\"type\":\"response.output_text.delta\",\"item_id\":\"msg_1\",\"output_index\":0,\"delta\":\"answer\"}\n\n" ++
            "event: response.completed\n" ++
            "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_1\",\"status\":\"completed\",\"usage\":{\"input_tokens\":1,\"input_tokens_details\":{\"cached_tokens\":0},\"output_tokens\":2}}}\n\n",
        .gemini => "data: {\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"text\":\"answer\"}]}}]}\n\n" ++
            "data: {\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"text\":\".\"}]},\"finishReason\":\"STOP\"}],\"usageMetadata\":{\"promptTokenCount\":1,\"candidatesTokenCount\":2}}\n\n",
        .bedrock => &BEDROCK_COMPLETE,
    };
}

/// The log line each client writes for a failed read.
fn failureLine(comptime wire: Wire) []const u8 {
    return switch (wire) {
        .anthropic => "event_iter.next failed: ReadFailed ",
        .openai_chat, .openai_responses, .gemini => "stream read failed: ReadFailed ",
        .bedrock => "event stream read failed: ReadFailed ",
    };
}

const BEDROCK_COMPLETE = awsEvent("messageStart", "{\"role\":\"assistant\"}").* ++
    awsEvent("contentBlockDelta", "{\"contentBlockIndex\":0,\"delta\":{\"text\":\"answer\"}}").* ++
    awsEvent("contentBlockStop", "{\"contentBlockIndex\":0}").* ++
    awsEvent("messageStop", "{\"stopReason\":\"end_turn\"}").* ++
    awsEvent("metadata", "{\"usage\":{\"inputTokens\":1,\"outputTokens\":2}}").*;

/// One Bedrock event frame (AWS event-stream framing, both CRCs), built at
/// compile time; the same construction as tests/component/provider_lifecycle_test.zig.
fn awsEvent(comptime event_type: []const u8, comptime json: []const u8) *const [awsEventLen(event_type, json)]u8 {
    const frame = comptime blk: {
        @setEvalBranchQuota(200_000);
        const headers = awsHeader(":event-type", event_type) ++ awsHeader(":content-type", "application/json") ++ awsHeader(":message-type", "event");
        const total = awsEventLen(event_type, json);
        const lengths = be32(total) ++ be32(headers.len);
        const head = lengths ++ be32(std.hash.Crc32.hash(&lengths)) ++ headers ++ json[0..json.len].*;
        break :blk head ++ be32(std.hash.Crc32.hash(&head));
    };
    return &frame;
}

fn awsEventLen(comptime event_type: []const u8, comptime json: []const u8) usize {
    return 16 + awsHeader(":event-type", event_type).len + awsHeader(":content-type", "application/json").len + awsHeader(":message-type", "event").len + json.len;
}

fn awsHeader(comptime name: []const u8, comptime value: []const u8) [1 + name.len + 3 + value.len]u8 {
    return [_]u8{name.len} ++ name[0..name.len].* ++ [_]u8{7} ++ be16(value.len) ++ value[0..value.len].*;
}

fn be32(comptime value: u32) [4]u8 {
    var out: [4]u8 = undefined;
    std.mem.writeInt(u32, &out, value, .big);
    return out;
}

fn be16(comptime value: u16) [2]u8 {
    var out: [2]u8 = undefined;
    std.mem.writeInt(u16, &out, value, .big);
    return out;
}

/// Runs `body.run(provider)` on a fresh client of `wire` pointed at `url`
/// (Gemini and Bedrock take the server's origin and add their own path).
fn withProvider(comptime wire: Wire, url: []const u8, body: anytype) !void {
    const a = std.testing.allocator;
    var io_rt = @import("platform").signal.threadedIo(a, .{});
    defer io_rt.deinit();
    const io = io_rt.io();
    const origin = url[0 .. url.len - "/v1/messages".len];
    switch (wire) {
        .anthropic => {
            var client = cc.client_mod.Client.initWithBaseUrl(a, io, KEY, MODEL, url);
            defer client.deinit();
            try body.run(client.provider());
        },
        .openai_chat, .openai_responses => {
            var client = cc.api_openai.OpenAIClient.init(a, io, KEY, MODEL, url);
            defer client.deinit();
            if (wire == .openai_responses) client.protocol = .responses;
            try body.run(client.provider());
        },
        .gemini => {
            var client = cc.api_gemini.GeminiClient.init(a, io, KEY, MODEL, origin);
            defer client.deinit();
            try body.run(client.provider());
        },
        .bedrock => {
            var client = cc.api_bedrock.BedrockClient.init(a, io, KEY, MODEL, origin);
            defer client.deinit();
            try body.run(client.provider());
        },
    }
}

fn freeEvent(a: std.mem.Allocator, event: cc.api_stream.StreamEvent) void {
    switch (event) {
        .text, .thinking, .web_search_query, .reasoning_item => |bytes| a.free(bytes),
        .tool_use_start => |tu| {
            a.free(tu.id);
            a.free(tu.name);
            a.free(tu.input_json);
        },
        .web_search_result => |w| {
            a.free(w.ui_text);
            a.free(w.content_json);
        },
        .usage, .done => {},
    }
}

/// Reads the stream until it fails; the failure is the test's to check.
const DrainToFailure = struct {
    fn run(_: DrainToFailure, provider: cc.api_provider.Provider) !void {
        const a = std.testing.allocator;
        const messages = [_]cc.types_mod.ApiMessage{
            .{ .role = .user, .content = &[_]cc.types_mod.ApiContent{.{ .text = "hi" }} },
        };
        var handle = try provider.sendStream(&messages, null, null, null, null, null, "");
        defer handle.deinit();
        while (true) {
            const event = handle.next() catch |err| {
                try std.testing.expectEqual(@as(anyerror, error.RequestFailed), err);
                return;
            };
            freeEvent(a, event orelse return error.TestExpectedReadFailure);
        }
    }
};

fn clearLastError() void {
    var buf: [cc.api_last_error.SUMMARY_BUF_LEN]u8 = undefined;
    _ = cc.api_last_error.take(&buf);
}

fn namesTheCut(comptime wire: Wire) !void {
    const a = std.testing.allocator;
    var log_file = try harness.LogFile.create("stream-read-failure-log-test");
    defer log_file.deinit();
    const previous_log_state = cc.util_log.setLogFileFdForTest(log_file.fd);
    defer cc.util_log.restoreForTest(previous_log_state);
    cc.util_log.setLevel(.debug);

    var srv = try harness.MockServer.startCassetteMidStreamCut(&[_][]const u8{complete(wire)}, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);
    try withProvider(wire, url, DrainToFailure{});
    clearLastError();

    var buf: [64 * 1024]u8 = undefined;
    const log = try log_file.readAll(&buf);
    const at = std.mem.indexOf(u8, log, failureLine(wire)) orelse {
        std.debug.print("no read-failure line in:\n{s}\n", .{log});
        return error.TestExpectedReadFailureLine;
    };
    const line_end = std.mem.indexOfScalarPos(u8, log, at, '\n') orelse log.len;
    const line = log[at..line_end];
    if (std.mem.indexOf(u8, line, EXPECTED) == null) {
        std.debug.print("read-failure line: {s}\n", .{line});
        return error.TestReadFailureNotNamed;
    }
}

test "L2 #573 diagnostics: on every wire a read cut short names the body's error, the layers beneath it and the framing" {
    inline for (ALL_WIRES) |wire| namesTheCut(wire) catch |err| {
        std.debug.print("wire {s} failed\n", .{@tagName(wire)});
        return err;
    };
}
