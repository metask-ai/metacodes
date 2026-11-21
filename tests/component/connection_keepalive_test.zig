//! L2 #573: the model clients ask the server to keep the connection open,
//! and close it themselves.
//!
//! Every provider request used to say `connection: close`: the clients set
//! `keep_alive = false`, and at `.default` std writes `close` for that. A
//! server told so closes right after the last byte, and behind a transparent
//! proxy that close overtook bytes the proxy had not forwarded yet. The end of
//! the answer was lost; on the Responses wire the end is the terminal event,
//! over 100 KB there, so the stream counted as incomplete and the turn was
//! sent again and charged again (2026-11-18: 3% to 23% of real streams; 74% of
//! a large page on the same route). `harness.LossyProxy` is that server and
//! proxy: an answer to a request that asks to close is cut inside its last
//! event, and any other answer goes out whole on a connection the server
//! keeps open.
//!
//! On each wire (Messages, Chat Completions, Responses, Gemini, Bedrock):
//!   - the Run ends `end_turn` on one request; before, both attempts were cut
//!     and it ended `api_error`;
//!   - the request has one `connection` line, `keep-alive`, and no `close`;
//!   - the client closes the connection itself once it has the answer;
//!   - the next request opens a new connection: `keep_alive = false` still
//!     keeps every connection out of the pool.
//! Also: a stream cut inside the event that reports its stop still fails,
//! whatever the request asked for; the models list is read whole; a 204 answer
//! is not read to the end of a connection the server keeps open.

const std = @import("std");
const harness = @import("harness");
const cc = @import("cc");

const LossyProxy = harness.LossyProxy;

const Wire = enum { anthropic, openai_chat, openai_responses, gemini, bedrock };
const ALL_WIRES = [_]Wire{ .anthropic, .openai_chat, .openai_responses, .gemini, .bedrock };

const MODEL = "keepalive-model";
const KEY = "keepalive-test-key";

/// How long a test waits for the server to see the client close.
const CLOSE_WAIT_MS: i64 = LossyProxy.HOLD_MS + 1_000;
/// The client must let go well within the server's hold: it closes when the
/// stream is released, not when the server gives up.
const CLOSE_WITHIN_MS: i64 = 2_000;

// ── answers ──────────────────────────────────────────────────────────────────

/// What a Responses `response.completed` echoes back: the request's
/// instructions and tools, over 100 KB on the backend that dropped them.
const RESPONSES_ECHO_BYTES: usize = 120_000;

/// An answer, with where its last event starts and where the event that
/// reports how it stopped lies (the same event on Responses and Gemini).
const Answer = struct {
    bytes: []u8,
    last_event_at: usize,
    stop_event_at: usize,
    stop_event_end: usize,

    /// Halfway into the last event: what a proxy drops at the server's close.
    fn cutInLastEvent(self: Answer) usize {
        return self.last_event_at + (self.bytes.len - self.last_event_at) / 2;
    }

    /// Halfway into the stop report: the stream never said it was done.
    fn cutInStopEvent(self: Answer) usize {
        return self.stop_event_at + (self.stop_event_end - self.stop_event_at) / 2;
    }

    fn deinit(self: Answer, a: std.mem.Allocator) void {
        a.free(self.bytes);
    }
};

fn answerFor(a: std.mem.Allocator, comptime wire: Wire) !Answer {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var stop_event_at: usize = 0;
    var stop_event_end: usize = 0;
    var last_event_at: usize = 0;
    switch (wire) {
        .anthropic => {
            try out.appendSlice(a, "data: {\"type\":\"message_start\",\"message\":{\"id\":\"m\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
                "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
                "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"answer\"}}\n\n" ++
                "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n");
            stop_event_at = out.items.len;
            try out.appendSlice(a, "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":2}}\n\n");
            stop_event_end = out.items.len;
            last_event_at = out.items.len;
            try out.appendSlice(a, "data: {\"type\":\"message_stop\"}\n\n");
        },
        .openai_chat => {
            try out.appendSlice(a, "data: {\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"answer\"},\"finish_reason\":null}]}\n\n");
            stop_event_at = out.items.len;
            try out.appendSlice(a, "data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n");
            stop_event_end = out.items.len;
            last_event_at = out.items.len;
            try out.appendSlice(a, "data: [DONE]\n\n");
        },
        .openai_responses => {
            try out.appendSlice(a, "event: response.output_text.delta\n" ++
                "data: {\"type\":\"response.output_text.delta\",\"item_id\":\"msg_1\",\"output_index\":0,\"delta\":\"answer\"}\n\n");
            stop_event_at = out.items.len;
            last_event_at = out.items.len;
            try out.appendSlice(a, "event: response.completed\n" ++
                "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_1\",\"status\":\"completed\",\"instructions\":\"");
            try out.appendNTimes(a, 'x', RESPONSES_ECHO_BYTES);
            try out.appendSlice(a, "\",\"usage\":{\"input_tokens\":1,\"input_tokens_details\":{\"cached_tokens\":0},\"output_tokens\":2}}}\n\n");
            stop_event_end = out.items.len;
        },
        .gemini => {
            try out.appendSlice(a, "data: {\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"text\":\"answer\"}]}}]}\n\n");
            stop_event_at = out.items.len;
            last_event_at = out.items.len;
            try out.appendSlice(a, "data: {\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"text\":\".\"}]},\"finishReason\":\"STOP\"}],\"usageMetadata\":{\"promptTokenCount\":1,\"candidatesTokenCount\":2}}\n\n");
            stop_event_end = out.items.len;
        },
        .bedrock => {
            try out.appendSlice(a, awsEvent("messageStart", "{\"role\":\"assistant\"}"));
            try out.appendSlice(a, awsEvent("contentBlockDelta", "{\"contentBlockIndex\":0,\"delta\":{\"text\":\"answer\"}}"));
            try out.appendSlice(a, awsEvent("contentBlockStop", "{\"contentBlockIndex\":0}"));
            stop_event_at = out.items.len;
            try out.appendSlice(a, awsEvent("messageStop", "{\"stopReason\":\"end_turn\"}"));
            stop_event_end = out.items.len;
            last_event_at = out.items.len;
            try out.appendSlice(a, awsEvent("metadata", "{\"usage\":{\"inputTokens\":1,\"outputTokens\":2}}"));
        },
    }
    return .{
        .bytes = try out.toOwnedSlice(a),
        .last_event_at = last_event_at,
        .stop_event_at = stop_event_at,
        .stop_event_end = stop_event_end,
    };
}

fn contentType(comptime wire: Wire) []const u8 {
    return if (wire == .bedrock) "application/vnd.amazon.eventstream" else "text/event-stream";
}

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

// ── driver ───────────────────────────────────────────────────────────────────

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

fn clearLastError() void {
    var buf: [cc.api_last_error.SUMMARY_BUF_LEN]u8 = undefined;
    _ = cc.api_last_error.take(&buf);
}

/// One turn of the real loop with the TUI's defaults: a stream that fails
/// without an answer is re-sent once (`STREAM_RETRIES_PER_REQUEST`).
fn runOneTurn(provider: cc.api_provider.Provider) !cc.agent_loop.RunResult {
    const a = std.testing.allocator;
    var conv = cc.conversation.Conversation.init(a);
    defer conv.deinit();
    try conv.appendText(.user, "hi");
    var perm = cc.permission.createContext(.bypass_permissions, a);
    perm.no_interactive_prompt = true;
    const defs: []const cc.json_mod.ToolDefinition = &.{};
    var render = cc.writer_backend.WriterBackend.initNull();
    const be = render.backend();
    return cc.agent_loop.run(&conv, provider, defs, &perm, .{
        .max_turns = 1,
        .auto_compact_threshold = std.math.maxInt(usize),
    }, &be, a);
}

/// The request asked the server to keep the connection open, on its one
/// `connection` line.
fn expectAsksKeepAlive(raw: []const u8) !void {
    try std.testing.expectEqual(@as(usize, 0), LossyProxy.connectionHeaders(raw, "close"));
    try std.testing.expectEqual(@as(usize, 1), LossyProxy.connectionHeaders(raw, null));
    try std.testing.expectEqual(@as(usize, 1), LossyProxy.connectionHeaders(raw, "keep-alive"));
}

/// The client let go of the `index`th connection the server held open, soon
/// after the answer, without waiting for the server.
fn expectClientClosed(proxy: *LossyProxy, index: usize) !void {
    try std.testing.expect(proxy.waitForCloses(index + 1, CLOSE_WAIT_MS));
    const ms = try proxy.closeLatencyMs(index);
    try std.testing.expect(ms < CLOSE_WITHIN_MS);
}

// ── ① the answer arrives whole, once, and the client closes ─────────────────

const TwoTurns = struct {
    proxy: *LossyProxy,

    fn run(self: TwoTurns, provider: cc.api_provider.Provider) !void {
        clearLastError();
        const first = try runOneTurn(provider);
        try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, first.stop_reason);
        // One request: nothing was cut, so nothing was sent again.
        try std.testing.expectEqual(@as(usize, 1), self.proxy.requestCount());
        try std.testing.expectEqual(@as(usize, 0), self.proxy.cutCount());
        try expectAsksKeepAlive(self.proxy.requestAt(0).?);
        try expectClientClosed(self.proxy, 0);

        // The next request opens a new connection: none was pooled.
        const second = try runOneTurn(provider);
        try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, second.stop_reason);
        try std.testing.expectEqual(@as(usize, 2), self.proxy.requestCount());
        try std.testing.expectEqual(@as(usize, 2), self.proxy.acceptedCount());
        try std.testing.expectEqual(@as(usize, 0), self.proxy.reusedCount());
        try expectAsksKeepAlive(self.proxy.requestAt(1).?);
        try expectClientClosed(self.proxy, 1);
        clearLastError();
    }
};

fn wholeOnce(comptime wire: Wire) !void {
    const a = std.testing.allocator;
    const answer = try answerFor(a, wire);
    defer answer.deinit(a);
    var proxy = try LossyProxy.start(answer.bytes, .{ .content_type = contentType(wire), .cut_at = answer.cutInLastEvent() });
    defer proxy.stop();
    const url = try proxy.urlOwned(a);
    defer a.free(url);
    try withProvider(wire, url, TwoTurns{ .proxy = proxy });
}

test "L2 #573 ①: on every wire the request asks to keep the connection open, the answer arrives whole once, and the client closes the connection" {
    inline for (ALL_WIRES) |wire| wholeOnce(wire) catch |err| {
        std.debug.print("wire {s} failed\n", .{@tagName(wire)});
        return err;
    };
}

// ── ② a stream cut inside its stop report is still incomplete ───────────────

const CutRun = struct {
    proxy: *LossyProxy,

    fn run(self: CutRun, provider: cc.api_provider.Provider) !void {
        clearLastError();
        const result = try runOneTurn(provider);
        // The completeness rule is untouched: a stream that never said how it
        // stopped did not finish, and the request's own re-send was cut too.
        try std.testing.expectEqual(cc.agent_loop.StopReason.api_error, result.stop_reason);
        try std.testing.expectEqual(@as(usize, 2), self.proxy.requestCount());
        try std.testing.expectEqual(@as(usize, 2), self.proxy.cutCount());
        clearLastError();
    }
};

fn cutStaysIncomplete(comptime wire: Wire) !void {
    const a = std.testing.allocator;
    const answer = try answerFor(a, wire);
    defer answer.deinit(a);
    var proxy = try LossyProxy.start(answer.bytes, .{ .content_type = contentType(wire), .cut_at = answer.cutInStopEvent(), .cut_always = true });
    defer proxy.stop();
    const url = try proxy.urlOwned(a);
    defer a.free(url);
    try withProvider(wire, url, CutRun{ .proxy = proxy });
}

test "L2 #573 ②: on every wire a stream cut inside its stop report still fails, whatever the request asked for" {
    inline for (ALL_WIRES) |wire| cutStaysIncomplete(wire) catch |err| {
        std.debug.print("wire {s} failed\n", .{@tagName(wire)});
        return err;
    };
}

// ── ③ the models list ────────────────────────────────────────────────────────

test "L2 #573 ③: the models list asks to keep the connection open and is read whole" {
    const a = std.testing.allocator;
    // std does not check a `content-length` body for a cut: a list cut short
    // read as a complete, shorter one, and the catalog took what it got.
    const list = "{\"data\":[{\"id\":\"model-a\",\"max_tokens\":8192},{\"id\":\"model-b\",\"max_tokens\":16384},{\"id\":\"model-c\",\"max_tokens\":32768}],\"has_more\":false}";
    var proxy = try LossyProxy.start(list, .{ .content_type = "application/json", .framing = .content_length, .cut_at = list.len / 2 });
    defer proxy.stop();
    const url = try proxy.urlOwned(a);
    defer a.free(url);

    var io_rt = @import("platform").signal.threadedIo(a, .{});
    defer io_rt.deinit();
    var http_client: std.http.Client = .{ .allocator = a, .io = io_rt.io() };
    defer http_client.deinit();
    var status: u16 = 0;
    const got = try cc.client_mod.getModelsList(a, &http_client, url, .{ .header = .{ .name = "x-api-key", .value = KEY } }, &status);
    defer a.free(got);
    try std.testing.expectEqualStrings(list, got);
    try std.testing.expectEqual(@as(u16, 200), status);
    try std.testing.expectEqual(@as(usize, 1), proxy.requestCount());
    try expectAsksKeepAlive(proxy.requestAt(0).?);
    try expectClientClosed(proxy, 0);
}

// ── ④ a 204 is not read to the end of the connection ────────────────────────

const NoContent = struct {
    fn run(_: NoContent, provider: cc.api_provider.Provider) !void {
        const io = std.Io.Threaded.global_single_threaded.io();
        const begun = std.Io.Timestamp.now(io, .awake);
        const messages = [_]cc.types_mod.ApiMessage{
            .{ .role = .user, .content = &[_]cc.types_mod.ApiContent{.{ .text = "hi" }} },
        };
        if (provider.sendStream(&messages, null, null, null, null, null, "")) |handle| {
            var h = handle;
            h.deinit();
            return error.TestExpectedHttpFailure;
        } else |_| {}
        // The server holds the connection for `LossyProxy.HOLD_MS`: an error
        // body read to its end would take that long.
        const ms = begun.durationTo(std.Io.Timestamp.now(io, .awake)).toMilliseconds();
        try std.testing.expect(ms < 1_000);
        clearLastError();
    }
};

test "L2 #573 ④: a 204 answer is reported at once, not read to the end of a connection the server keeps open" {
    const a = std.testing.allocator;
    var proxy = try LossyProxy.start("", .{ .status_line = "HTTP/1.1 204 No Content", .framing = .none });
    defer proxy.stop();
    const url = try proxy.urlOwned(a);
    defer a.free(url);
    try withProvider(.anthropic, url, NoContent{});
    try withProvider(.openai_chat, url, NoContent{});
    try std.testing.expectEqual(@as(usize, 2), proxy.requestCount());
}

// ── ⑤ every model request asks to keep its connection open ──────────────────

/// The model clients. Each request they open with `keep_alive = false` must
/// ask the server to keep the connection open, or std writes
/// `connection: close` for it.
const MODEL_CLIENT_FILES = [_][]const u8{
    "src/client.zig",
    "src/api/openai_client.zig",
    "src/api/gemini_client.zig",
    "src/api/bedrock_client.zig",
};

/// Occurrences of `needle` outside whole-line comments.
fn countInCode(text: []const u8, needle: []const u8) usize {
    var lines = std.mem.splitScalar(u8, text, '\n');
    var count: usize = 0;
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, std.mem.trimStart(u8, line, " \t"), "//")) continue;
        count += std.mem.count(u8, line, needle);
    }
    return count;
}

test "L2 #573 ⑤: every model request that closes its own connection asks the server to keep it open" {
    const a = std.testing.allocator;
    var total: usize = 0;
    for (MODEL_CLIENT_FILES) |path| {
        const text = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, a, .limited(8 * 1024 * 1024));
        defer a.free(text);
        const closing = countInCode(text, ".keep_alive = false");
        const asking = countInCode(text, "http_connection.keepServerOpen(");
        if (closing != asking) {
            std.debug.print("{s}: {d} requests with keep_alive = false, {d} keepServerOpen calls\n", .{ path, closing, asking });
            return error.ModelRequestSaysConnectionClose;
        }
        total += asking;
    }
    // Moves with the inventory: Messages and its models list, OpenAI, Gemini, Bedrock.
    try std.testing.expectEqual(@as(usize, 5), total);
}

test "L2 #573 ⑤: the guard counts code, not comments" {
    const sample =
        \\    // .keep_alive = false used to say connection: close
        \\        .keep_alive = false,
        \\    http_connection.keepServerOpen(req_ptr);
        \\    // http_connection.keepServerOpen(req_ptr);
    ;
    try std.testing.expectEqual(@as(usize, 1), countInCode(sample, ".keep_alive = false"));
    try std.testing.expectEqual(@as(usize, 1), countInCode(sample, "http_connection.keepServerOpen("));
}
