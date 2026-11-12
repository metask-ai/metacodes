//! L2: the request lifecycle `Provider` promises is the same on every wire
//! (issue #434) - Anthropic Messages, OpenAI Chat Completions, OpenAI
//! Responses, Gemini, and Amazon Bedrock Converse.
//!
//!   ① A transient connect failure, a 429 and a 503 on the first attempt are
//!     retried: the retry is the same request (same path, so the same protocol
//!     and model URL, same credential, same body, so the same model), the
//!     reporter hears of it with the local backoff delay, and the next stream
//!     is read to its end.
//!   ② The attempt limit holds: a 503 that never ends is sent exactly
//!     max_retries times and ends as ServiceUnavailable.
//!   ③ A cancel during the backoff ends the request as Aborted and no further
//!     request is sent.
//!   ④ A cancel while the response head is awaited is Aborted from the
//!     Provider (not HttpConnectionClosing), and a direct AgentLoop caller ends
//!     the Run `aborted`, not `api_error`.
//!   ⑤ An HTTP context-limit rejection is ContextWindowExceeded, is not
//!     retried, and keeps its structured detail (`context_window`, the status,
//!     the server's numbers); in a Run it reaches the loop's existing recovery,
//!     which shrinks the request and sends it again.
//!   ⑥ In a Run, the retry is the existing `retry_notice` event, honours
//!     Retry-After, and the execution boundary journals two physical attempts
//!     of one request (the same request_sha256).
//!   ⑦ A stream that ends cleanly before it reports how it stopped fails the
//!     Run with the detail `stream_interrupted` / `retryable`, carrying that
//!     response's status and request id (issue #451).
//!
//! Before #434 the OpenAI and Gemini clients made one attempt whatever
//! max_retries said, answered a 429/503/overflow with RequestFailed, and
//! answered a cancel during the head wait with HttpConnectionClosing; the
//! Bedrock client, added beside #434, did the same until it joined it.

const std = @import("std");
const harness = @import("harness");
const cc = @import("cc");

const Wire = enum { anthropic, openai_chat, openai_responses, gemini, bedrock };
const ALL_WIRES = [_]Wire{ .anthropic, .openai_chat, .openai_responses, .gemini, .bedrock };

const DEFAULT_MODEL = "lifecycle-model-a";
/// Every request below names this model per call: a retry must keep it.
const BOUND_MODEL = "lifecycle-model-b";
const KEY = "lifecycle-test-key";

// ── cassettes ────────────────────────────────────────────────────────────────

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
        .gemini => "data: {\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"text\":\"answer\"}]},\"finishReason\":\"STOP\"}],\"usageMetadata\":{\"promptTokenCount\":1,\"candidatesTokenCount\":2}}\n\n",
        .bedrock => &BEDROCK_COMPLETE,
    };
}

/// A container-level constant, so the slice `complete` returns points at
/// static bytes rather than at a concatenation's temporary.
const BEDROCK_COMPLETE = awsEvent("messageStart", "{\"role\":\"assistant\"}").* ++
    awsEvent("contentBlockDelta", "{\"contentBlockIndex\":0,\"delta\":{\"text\":\"answer\"}}").* ++
    awsEvent("contentBlockStop", "{\"contentBlockIndex\":0}").* ++
    awsEvent("messageStop", "{\"stopReason\":\"end_turn\"}").* ++
    awsEvent("metadata", "{\"usage\":{\"inputTokens\":1,\"outputTokens\":2}}").*;

/// One Bedrock event frame (AWS event-stream framing, both CRCs), built at
/// compile time so the cassette is a constant like the SSE ones;
/// `aws_event_stream.encodeEvent` is its runtime twin.
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

/// A string-valued header: name length, name, type 7, value length, value.
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

test "the compile-time Bedrock cassette decodes with the client's own decoder" {
    const a = std.testing.allocator;
    var reader: std.Io.Reader = .fixed(complete(.bedrock));
    var events: usize = 0;
    while (try cc.api_aws_event_stream.readFrame(&reader, a)) |frame| {
        defer a.free(frame);
        var headers: [cc.api_aws_event_stream.MAX_HEADERS]cc.api_aws_event_stream.Header = undefined;
        const message = try cc.api_aws_event_stream.decode(frame, &headers);
        try std.testing.expectEqualStrings("event", message.header(":message-type").?);
        events += 1;
    }
    try std.testing.expectEqual(@as(usize, 5), events);
}

const RATE_LIMITED_BODY = "{\"error\":{\"type\":\"rate_limit_error\",\"message\":\"slow down\"}}";
const OVERLOADED_BODY = "{\"error\":{\"type\":\"overloaded_error\",\"message\":\"try later\"}}";
/// OpenAI's wording, with numbers the loop can learn from; the same body on
/// every wire, since the classification of a body does not depend on the wire.
const OVERFLOW_BODY = "{\"error\":{\"message\":\"This model's maximum context length is 128000 tokens. However, you requested 130000 tokens (129000 in the messages, 1000 in the completion).\",\"type\":\"invalid_request_error\",\"code\":\"context_length_exceeded\"}}";

// ── driver ───────────────────────────────────────────────────────────────────

const Endpoint = struct {
    /// `MockServer.urlOwned`: the full endpoint for Messages and OpenAI.
    url: []const u8,
    /// The same server's origin: Gemini and Bedrock append their own model path.
    origin: []const u8,

    fn of(url: []const u8) Endpoint {
        return .{ .url = url, .origin = url[0 .. url.len - "/v1/messages".len] };
    }
};

/// Runs `body.run(provider)` on a fresh client of `wire` pointed at `endpoint`.
fn withProvider(comptime wire: Wire, endpoint: Endpoint, body: anytype) !void {
    const a = std.testing.allocator;
    var io_rt = @import("platform").signal.threadedIo(a, .{});
    defer io_rt.deinit();
    const io = io_rt.io();
    switch (wire) {
        .anthropic => {
            var client = cc.client_mod.Client.initWithBaseUrl(a, io, KEY, DEFAULT_MODEL, endpoint.url);
            defer client.deinit();
            try body.run(client.provider());
        },
        .openai_chat, .openai_responses => {
            var client = cc.api_openai.OpenAIClient.init(a, io, KEY, DEFAULT_MODEL, endpoint.url);
            defer client.deinit();
            if (wire == .openai_responses) client.protocol = .responses;
            try body.run(client.provider());
        },
        .gemini => {
            var client = cc.api_gemini.GeminiClient.init(a, io, KEY, DEFAULT_MODEL, endpoint.origin);
            defer client.deinit();
            try body.run(client.provider());
        },
        .bedrock => {
            var client = cc.api_bedrock.BedrockClient.init(a, io, KEY, DEFAULT_MODEL, endpoint.origin);
            defer client.deinit();
            try body.run(client.provider());
        },
    }
}

const MESSAGES = [_]cc.types_mod.ApiMessage{
    .{ .role = .user, .content = &[_]cc.types_mod.ApiContent{.{ .text = "hi" }} },
};

/// What the reporter was told, in order.
const Reports = struct {
    failed: [8]struct { attempt: u32, max: u32, delay_ms: u64 } = undefined,
    failed_len: usize = 0,
    before: [8]u32 = undefined,
    before_len: usize = 0,
    /// Set from `failed`: the cancel lands while the backoff is pending.
    cancel_in_backoff: ?*cc.util_abort.AbortSignal = null,

    fn reporter(self: *Reports) cc.client_mod.RetryReporter {
        return .{ .state = @ptrCast(self), .failedFn = failedFn, .beforeAttemptFn = beforeFn };
    }
    fn failedFn(raw: *anyopaque, attempt: u32, max: u32, delay_ms: u64) bool {
        const self: *Reports = @ptrCast(@alignCast(raw));
        if (self.failed_len < self.failed.len) {
            self.failed[self.failed_len] = .{ .attempt = attempt, .max = max, .delay_ms = delay_ms };
            self.failed_len += 1;
        }
        if (self.cancel_in_backoff) |signal| signal.abort(.user_interrupt);
        return true;
    }
    fn beforeFn(raw: *anyopaque, attempt: u32, _: u32) bool {
        const self: *Reports = @ptrCast(@alignCast(raw));
        if (self.before_len < self.before.len) {
            self.before[self.before_len] = attempt;
            self.before_len += 1;
        }
        return true;
    }
};

fn sendRetry(provider: cc.api_provider.Provider, abort: ?*const cc.util_abort.AbortSignal, max_retries: u32, base_ms: u64, reports: *Reports) anyerror!cc.api_provider.StreamHandle {
    return provider.sendStreamRetry(&MESSAGES, null, null, abort, BOUND_MODEL, null, max_retries, base_ms, reports.reporter(), "");
}

/// Reads an accepted stream to its end, as the agent loop would.
fn drain(handle: *cc.api_provider.StreamHandle) !void {
    const a = std.testing.allocator;
    var text_seen = false;
    while (try handle.next()) |event| switch (event) {
        .text => |bytes| {
            text_seen = true;
            a.free(bytes);
        },
        .thinking, .web_search_query, .reasoning_item => |bytes| a.free(bytes),
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
    };
    try std.testing.expect(text_seen);
}

fn requestLine(raw: []const u8) []const u8 {
    return raw[0 .. std.mem.indexOf(u8, raw, "\r\n") orelse raw.len];
}

/// The request reached `wire`'s endpoint for `BOUND_MODEL` with this test's key.
fn expectBoundRequest(comptime wire: Wire, request: harness.CapturedRequest) !void {
    const line = requestLine(request.raw);
    const body = request.body();
    try std.testing.expect(std.mem.indexOf(u8, request.raw, KEY) != null);
    switch (wire) {
        .anthropic => {
            try std.testing.expect(std.mem.indexOf(u8, request.raw, "anthropic-version") != null);
            try std.testing.expectEqualStrings("\"" ++ BOUND_MODEL ++ "\"", request.jsonField("model") orelse "");
        },
        .openai_chat => {
            try std.testing.expect(request.jsonField("messages") != null);
            try std.testing.expect(request.jsonField("input") == null);
            try std.testing.expectEqualStrings("\"" ++ BOUND_MODEL ++ "\"", request.jsonField("model") orelse "");
        },
        .openai_responses => {
            try std.testing.expect(request.jsonField("input") != null);
            try std.testing.expectEqualStrings("\"" ++ BOUND_MODEL ++ "\"", request.jsonField("model") orelse "");
        },
        .gemini => {
            try std.testing.expect(std.mem.indexOf(u8, line, "/v1beta/models/" ++ BOUND_MODEL ++ ":streamGenerateContent") != null);
            try std.testing.expect(std.mem.indexOf(u8, body, "\"contents\"") != null);
        },
        .bedrock => {
            try std.testing.expect(std.mem.indexOf(u8, line, "/model/" ++ BOUND_MODEL ++ "/converse-stream") != null);
            try std.testing.expect(std.mem.indexOf(u8, body, "\"messages\"") != null);
        },
    }
}

/// Every captured request is byte for byte the first one, which went where
/// `wire` sends `BOUND_MODEL`.
fn expectSameRequestEachTime(comptime wire: Wire, srv: *harness.MockServer, expected_count: usize) !void {
    try std.testing.expectEqual(expected_count, srv.requestCount());
    const first = srv.requestAt(0) orelse return error.NoRequestCaptured;
    try expectBoundRequest(wire, first);
    for (1..expected_count) |i| {
        const again = srv.requestAt(i) orelse return error.NoRequestCaptured;
        try std.testing.expectEqualStrings(first.raw, again.raw);
    }
}

fn clearLastError() void {
    var buf: [cc.api_last_error.SUMMARY_BUF_LEN]u8 = undefined;
    _ = cc.api_last_error.take(&buf);
}

fn eachWire(comptime f: fn (comptime Wire) anyerror!void) !void {
    inline for (ALL_WIRES) |wire| {
        f(wire) catch |err| {
            std.debug.print("wire {s} failed: {s}\n", .{ @tagName(wire), @errorName(err) });
            return err;
        };
        clearLastError();
    }
}

// ── ① transient connect failure, 429, 503: retried, same request ─────────────

const BASE_MS: u64 = 20;
const MAX_ATTEMPTS: u32 = 3;

const RetriedOnce = struct {
    fn run(_: @This(), provider: cc.api_provider.Provider) !void {
        var reports = Reports{};
        var handle = try sendRetry(provider, null, MAX_ATTEMPTS, BASE_MS, &reports);
        defer handle.deinit();
        try drain(&handle);
        // One failure reported, with the local backoff (base · 2⁰ + ≤25% jitter).
        try std.testing.expectEqual(@as(usize, 1), reports.failed_len);
        try std.testing.expectEqual(@as(u32, 1), reports.failed[0].attempt);
        try std.testing.expectEqual(MAX_ATTEMPTS, reports.failed[0].max);
        try std.testing.expect(reports.failed[0].delay_ms >= BASE_MS and reports.failed[0].delay_ms <= BASE_MS + BASE_MS / 4);
        try std.testing.expectEqual(@as(usize, 1), reports.before_len);
        try std.testing.expectEqual(@as(u32, 2), reports.before[0]);
    }
};

fn transientConnectRetried(comptime wire: Wire) !void {
    const a = std.testing.allocator;
    // The first connection is closed once its request is read: no head.
    var srv = try harness.MockServer.startFlaky(complete(wire), 1);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);
    try withProvider(wire, Endpoint.of(url), RetriedOnce{});
    try expectSameRequestEachTime(wire, srv, 2);
}

fn statusRetried(comptime wire: Wire, comptime status_line: []const u8, comptime error_body: []const u8) !void {
    const a = std.testing.allocator;
    var srv = try harness.MockServer.startHttpCassette(
        &[_][]const u8{ error_body, complete(wire) },
        &[_][]const u8{ status_line, "HTTP/1.1 200 OK" },
    );
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);
    try withProvider(wire, Endpoint.of(url), RetriedOnce{});
    try expectSameRequestEachTime(wire, srv, 2);
}

fn rateLimitedRetried(comptime wire: Wire) !void {
    try statusRetried(wire, "HTTP/1.1 429 Too Many Requests", RATE_LIMITED_BODY);
}

fn unavailableRetried(comptime wire: Wire) !void {
    try statusRetried(wire, "HTTP/1.1 503 Service Unavailable", OVERLOADED_BODY);
}

test "L2 provider lifecycle ①: a transient connect failure is retried with the same request on every wire" {
    try eachWire(transientConnectRetried);
}

test "L2 provider lifecycle ①: a 429 is retried with the same request on every wire" {
    try eachWire(rateLimitedRetried);
}

test "L2 provider lifecycle ①: a 503 is retried with the same request on every wire" {
    try eachWire(unavailableRetried);
}

// ── ② attempt limit ──────────────────────────────────────────────────────────

const Exhausted = struct {
    fn run(_: @This(), provider: cc.api_provider.Provider) !void {
        var reports = Reports{};
        try std.testing.expectError(error.ServiceUnavailable, sendRetry(provider, null, MAX_ATTEMPTS, 1, &reports));
        // Told of every failure but the last, which ends the request.
        try std.testing.expectEqual(@as(usize, MAX_ATTEMPTS - 1), reports.failed_len);
        for (reports.failed[0..reports.failed_len], 1..) |report, attempt| {
            try std.testing.expectEqual(@as(u32, @intCast(attempt)), report.attempt);
            try std.testing.expectEqual(MAX_ATTEMPTS, report.max);
        }
    }
};

fn attemptLimitHolds(comptime wire: Wire) !void {
    const a = std.testing.allocator;
    var srv = try harness.MockServer.startRepeatingStatus(OVERLOADED_BODY, "HTTP/1.1 503 Service Unavailable", "");
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);
    try withProvider(wire, Endpoint.of(url), Exhausted{});
    try expectSameRequestEachTime(wire, srv, MAX_ATTEMPTS);
}

test "L2 provider lifecycle ②: a 503 that never ends is sent max_retries times on every wire" {
    try eachWire(attemptLimitHolds);
}

// ── ③ cancel during the backoff ──────────────────────────────────────────────

const CancelledInBackoff = struct {
    fn run(_: @This(), provider: cc.api_provider.Provider) !void {
        var signal = cc.util_abort.AbortSignal.init();
        var reports = Reports{ .cancel_in_backoff = &signal };
        // A backoff long enough that only the cancel can end it in time.
        try std.testing.expectError(error.Aborted, sendRetry(provider, &signal, MAX_ATTEMPTS, 60_000, &reports));
        try std.testing.expectEqual(@as(usize, 1), reports.failed_len);
        try std.testing.expectEqual(@as(usize, 0), reports.before_len);
    }
};

fn cancelInBackoffStopsNextRequest(comptime wire: Wire) !void {
    const a = std.testing.allocator;
    var srv = try harness.MockServer.startRepeatingStatus(OVERLOADED_BODY, "HTTP/1.1 503 Service Unavailable", "");
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);
    try withProvider(wire, Endpoint.of(url), CancelledInBackoff{});
    try std.testing.expectEqual(@as(usize, 1), srv.requestCount());
}

test "L2 provider lifecycle ③: a cancel during the backoff prevents the next request on every wire" {
    try eachWire(cancelInBackoffStopsNextRequest);
}

// ── ④ cancel while the response head is awaited ──────────────────────────────

/// Waits until the server holds the response head, then cancels the way
/// AgentSession does: the signal, then `Provider.cancel`.
const Canceller = struct {
    srv: *harness.MockServer,
    signal: *cc.util_abort.AbortSignal,
    provider: cc.api_provider.Provider,
    gated: bool = false,

    fn main(self: *Canceller) void {
        self.srv.waitUntilResponseGated() catch return;
        self.gated = true;
        self.signal.abort(.user_interrupt);
        self.provider.cancel(self.signal);
    }
};

const CancelledInHead = struct {
    srv: *harness.MockServer,

    fn run(self: @This(), provider: cc.api_provider.Provider) !void {
        var signal = cc.util_abort.AbortSignal.init();
        var canceller = Canceller{ .srv = self.srv, .signal = &signal, .provider = provider };
        const thread = try std.Thread.spawn(.{}, Canceller.main, .{&canceller});
        var reports = Reports{};
        const result = sendRetry(provider, &signal, MAX_ATTEMPTS, 1, &reports);
        thread.join();
        self.srv.releaseGatedResponse();
        try std.testing.expect(canceller.gated);
        if (result) |handle| {
            var opened = handle;
            opened.deinit();
            return error.TestExpectedAborted;
        } else |err| try std.testing.expectEqual(error.Aborted, err);
        // A cancel is not a failure to retry or to report as one.
        try std.testing.expectEqual(@as(usize, 0), reports.failed_len);
    }
};

fn cancelInHeadIsAborted(comptime wire: Wire) !void {
    const a = std.testing.allocator;
    var srv = try harness.MockServer.startCassette(&[_][]const u8{complete(wire)}, 0);
    defer srv.stop();
    srv.gateResponseAt(0);
    const url = try srv.urlOwned(a);
    defer a.free(url);
    try withProvider(wire, Endpoint.of(url), CancelledInHead{ .srv = srv });
    try std.testing.expectEqual(@as(usize, 1), srv.requestCount());
}

test "L2 provider lifecycle ④: a cancel while the head is awaited is Aborted on every wire" {
    try eachWire(cancelInHeadIsAborted);
}

const NullBackend = struct {
    fn emit(_: *anyopaque, _: cc.session_id.SessionId, _: cc.ui_backend.CoreEvent) void {}
    fn poll(_: *anyopaque, _: cc.session_id.SessionId) ?cc.ui_event.UiEvent {
        return null;
    }
};

const RunCancelledInHead = struct {
    srv: *harness.MockServer,

    fn run(self: @This(), provider: cc.api_provider.Provider) !void {
        const a = std.testing.allocator;
        var signal = cc.util_abort.AbortSignal.init();
        var canceller = Canceller{ .srv = self.srv, .signal = &signal, .provider = provider };
        const thread = try std.Thread.spawn(.{}, Canceller.main, .{&canceller});
        var conv = cc.conversation.Conversation.init(a);
        defer conv.deinit();
        try conv.appendText(.user, "hi");
        var perm = cc.permission.createContext(.bypass_permissions, a);
        perm.no_interactive_prompt = true;
        var sink: u8 = 0;
        const backend = cc.ui_backend.UiBackend{ .ctx = @ptrCast(&sink), .emit = NullBackend.emit, .poll = NullBackend.poll };
        const result = cc.agent_loop.run(&conv, provider, &.{}, &perm, .{
            .max_turns = 1,
            .abort = &signal,
            .auto_compact_threshold = std.math.maxInt(usize),
        }, &backend, a);
        thread.join();
        self.srv.releaseGatedResponse();
        try std.testing.expect(canceller.gated);
        try std.testing.expectEqual(cc.agent_loop.StopReason.aborted, (try result).stop_reason);
    }
};

fn runCancelInHeadIsAborted(comptime wire: Wire) !void {
    const a = std.testing.allocator;
    var srv = try harness.MockServer.startCassette(&[_][]const u8{complete(wire)}, 0);
    defer srv.stop();
    srv.gateResponseAt(0);
    const url = try srv.urlOwned(a);
    defer a.free(url);
    try withProvider(wire, Endpoint.of(url), RunCancelledInHead{ .srv = srv });
    try std.testing.expectEqual(@as(usize, 1), srv.requestCount());
}

test "L2 provider lifecycle ④: a direct AgentLoop Run cancelled while the head is awaited ends aborted, not api_error" {
    try eachWire(runCancelInHeadIsAborted);
}

// ── ⑤ context-limit rejection ────────────────────────────────────────────────

const Overflow = struct {
    fn run(_: @This(), provider: cc.api_provider.Provider) !void {
        var capture = cc.api_model_error.Capture{};
        const scope = cc.api_model_error.Scope.enter(&capture);
        defer scope.exit();
        var reports = Reports{};
        try std.testing.expectError(error.ContextWindowExceeded, sendRetry(provider, null, MAX_ATTEMPTS, 1, &reports));
        // Not a failure a resend of the same bytes can fix.
        try std.testing.expectEqual(@as(usize, 0), reports.failed_len);
        // The numbers the recovery learns the wall from.
        const numbers = provider.lastContextWindowNumbers();
        try std.testing.expectEqual(@as(?u64, 128_000), numbers.total_limit);
        // The structured detail every host surface reports.
        var detail: cc.api_model_error.Detail = .{};
        capture.finish(&detail);
        try std.testing.expectEqual(cc.api_model_error.Category.context_window, detail.category);
        try std.testing.expectEqual(cc.api_model_error.Retry.not_retryable, detail.retry);
        try std.testing.expectEqual(@as(?u16, 400), detail.http_status);
        try std.testing.expectEqualStrings("context_length_exceeded", detail.view().code orelse "");
    }
};

fn overflowIsContextWindowExceeded(comptime wire: Wire) !void {
    const a = std.testing.allocator;
    var srv = try harness.MockServer.startRepeatingStatus(OVERFLOW_BODY, "HTTP/1.1 400 Bad Request", "");
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);
    try withProvider(wire, Endpoint.of(url), Overflow{});
    try std.testing.expectEqual(@as(usize, 1), srv.requestCount());
}

test "L2 provider lifecycle ⑤: an HTTP context-limit rejection is ContextWindowExceeded with its detail on every wire" {
    try eachWire(overflowIsContextWindowExceeded);
}

const UnrecoverableRun = struct {
    fn run(_: @This(), provider: cc.api_provider.Provider) !void {
        const a = std.testing.allocator;
        var conv = cc.conversation.Conversation.init(a);
        defer conv.deinit();
        try conv.appendText(.user, "hi");
        var perm = cc.permission.createContext(.bypass_permissions, a);
        perm.no_interactive_prompt = true;
        var sink: u8 = 0;
        const backend = cc.ui_backend.UiBackend{ .ctx = @ptrCast(&sink), .emit = NullBackend.emit, .poll = NullBackend.poll };
        var model_error: ?cc.api_model_error.Detail = null;
        const result = try cc.agent_loop.run(&conv, provider, &.{}, &perm, .{
            .max_turns = 1,
            .auto_compact_threshold = std.math.maxInt(usize),
            .model_error_out = &model_error,
        }, &backend, a);
        // Nothing left to drop: the policy gives up, and the Run says why.
        try std.testing.expectEqual(cc.agent_loop.StopReason.api_error, result.stop_reason);
        const detail = model_error orelse return error.TestExpectedModelError;
        try std.testing.expectEqual(cc.api_model_error.Category.context_window, detail.category);
        try std.testing.expectEqual(@as(?u16, 400), detail.http_status);
        try std.testing.expectEqualStrings("context_length_exceeded", detail.view().code orelse "");
    }
};

fn overflowDetailReachesRun(comptime wire: Wire) !void {
    const a = std.testing.allocator;
    cc.core_context_caps.resetForTest();
    defer cc.core_context_caps.resetForTest();
    var srv = try harness.MockServer.startRepeatingStatus(OVERFLOW_BODY, "HTTP/1.1 400 Bad Request", "");
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);
    try withProvider(wire, Endpoint.of(url), UnrecoverableRun{});
    // Never resent as it was: the recovery found nothing to shrink.
    try std.testing.expectEqual(@as(usize, 1), srv.requestCount());
}

test "L2 provider lifecycle ⑤: a Run whose overflow cannot be recovered keeps the context_window detail on every wire" {
    try eachWire(overflowDetailReachesRun);
}

const RecoveryCapture = struct {
    auto_compacts: u32 = 0,
    fn emit(ctx: *anyopaque, _: cc.session_id.SessionId, ev: cc.ui_backend.CoreEvent) void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        if (ev == .auto_compact) self.auto_compacts += 1;
    }
    fn poll(_: *anyopaque, _: cc.session_id.SessionId) ?cc.ui_event.UiEvent {
        return null;
    }
};

const RecoveredRun = struct {
    fn run(_: @This(), provider: cc.api_provider.Provider) !void {
        const a = std.testing.allocator;
        var conv = cc.conversation.Conversation.init(a);
        defer conv.deinit();
        const filler = "f" ** 20_000;
        try conv.appendText(.user, "first request " ++ filler);
        try conv.appendText(.assistant, "first answer " ++ filler);
        try conv.appendText(.user, "second request " ++ filler);
        try conv.appendText(.assistant, "second answer " ++ filler);
        try conv.appendText(.user, "current request");
        var perm = cc.permission.createContext(.bypass_permissions, a);
        perm.no_interactive_prompt = true;
        var capture = RecoveryCapture{};
        const backend = cc.ui_backend.UiBackend{ .ctx = @ptrCast(&capture), .emit = RecoveryCapture.emit, .poll = RecoveryCapture.poll };
        const result = try cc.agent_loop.run(&conv, provider, &.{}, &perm, .{
            .max_turns = 1,
            .auto_compact_keep_recent = 1,
            .auto_compact_threshold = std.math.maxInt(usize),
        }, &backend, a);
        try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, result.stop_reason);
        // The loop's recovery ran (a compaction or its trim fallback, both
        // reported as auto_compact) before the same turn was sent again.
        try std.testing.expect(capture.auto_compacts >= 1);
    }
};

fn overflowReachesRecovery(comptime wire: Wire) !void {
    const a = std.testing.allocator;
    cc.core_context_caps.resetForTest();
    defer cc.core_context_caps.resetForTest();
    var srv = try harness.MockServer.startHttpCassette(
        &[_][]const u8{ OVERFLOW_BODY, complete(wire) },
        &[_][]const u8{ "HTTP/1.1 400 Bad Request", "HTTP/1.1 200 OK" },
    );
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);
    try withProvider(wire, Endpoint.of(url), RecoveredRun{});
    // The rejected request, the recovery's own summary request when it makes
    // one (the cassette's last answer repeats), then the same turn again,
    // smaller.
    const count = srv.requestCount();
    try std.testing.expect(count >= 2);
    const rejected = srv.requestAt(0) orelse return error.NoRequestCaptured;
    const recovered = srv.requestAt(count - 1) orelse return error.NoRequestCaptured;
    try std.testing.expect(recovered.body().len < rejected.body().len);
    try std.testing.expect(std.mem.indexOf(u8, recovered.body(), "current request") != null);
}

test "L2 provider lifecycle ⑤: in a Run an HTTP context-limit rejection reaches the loop's recovery on the OpenAI, Gemini and Bedrock wires" {
    // The Messages wire's recovery sends a non-streaming summary request
    // first; context_window_recovery_test.zig covers it. The other wires have
    // no non-streaming send, so their recovery shrinks the request locally.
    inline for (.{ Wire.openai_chat, Wire.openai_responses, Wire.gemini, Wire.bedrock }) |wire| {
        overflowReachesRecovery(wire) catch |err| {
            std.debug.print("wire {s} failed: {s}\n", .{ @tagName(wire), @errorName(err) });
            return err;
        };
        clearLastError();
    }
}

// ── ⑥ in a Run: retry_notice, Retry-After, two journaled physical attempts ──

const NoticeCapture = struct {
    notices: u32 = 0,
    attempt: u32 = 0,
    delay_ms: u64 = std.math.maxInt(u64),
    fn emit(ctx: *anyopaque, _: cc.session_id.SessionId, ev: cc.ui_backend.CoreEvent) void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        switch (ev) {
            .retry_notice => |notice| {
                self.notices += 1;
                self.attempt = notice.attempt;
                self.delay_ms = notice.delay_ms;
            },
            else => {},
        }
    }
    fn poll(_: *anyopaque, _: cc.session_id.SessionId) ?cc.ui_event.UiEvent {
        return null;
    }
};

const JournaledRun = struct {
    fn run(_: @This(), provider: cc.api_provider.Provider) !void {
        const a = std.testing.allocator;
        var conv = cc.conversation.Conversation.init(a);
        defer conv.deinit();
        try conv.appendText(.user, "return ok");
        const perm = cc.permission.createContext(.bypass_permissions, a);
        var capture = NoticeCapture{};
        const backend = cc.ui_backend.UiBackend{ .ctx = @ptrCast(&capture), .emit = NoticeCapture.emit, .poll = NoticeCapture.poll };
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
        const root = root_buffer[0..root_len];
        const sid = cc.session_id.SessionId.fromSlice("4343456789abcdef01234567").?;
        var journal = try cc.tool_observation_journal.Journal.init(root, sid);
        defer journal.deinit();

        const result = try cc.agent_loop.run(&conv, provider, &.{}, &perm, .{
            .max_turns = 1,
            .emit_tool_cards = false,
            .execution_boundary = journal.executionBoundary(),
            .cwd_abs = root,
            .home_dir = root,
            .model_override = BOUND_MODEL,
        }, &backend, a);
        try journal.finishRun(@tagName(result.stop_reason));
        var loaded = try cc.tool_observation_journal.loadRunDispatches(a, root, try journal.runBinding());
        defer loaded.deinit();

        try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, result.stop_reason);
        // The existing notification, with the server's Retry-After (0) as the delay.
        try std.testing.expectEqual(@as(u32, 1), capture.notices);
        try std.testing.expectEqual(@as(u32, 1), capture.attempt);
        try std.testing.expectEqual(@as(u64, 0), capture.delay_ms);
        // Two physical attempts of one request under the execution boundary.
        try std.testing.expectEqual(@as(usize, 2), loaded.provider_attempts.len);
        const first = loaded.provider_attempts[0];
        const second = loaded.provider_attempts[1];
        try std.testing.expectEqual(@as(u32, 1), first.physical_attempt);
        try std.testing.expect(first.outcome == .api_error);
        try std.testing.expectEqual(@as(u32, 2), second.physical_attempt);
        try std.testing.expect(second.outcome == .succeeded);
        try std.testing.expectEqualSlices(u8, &first.request_sha256, &second.request_sha256);
    }
};

fn runRetriesWithNotice(comptime wire: Wire) !void {
    const a = std.testing.allocator;
    var srv = try harness.MockServer.startHttpCassette(
        &[_][]const u8{ OVERLOADED_BODY, complete(wire) },
        &[_][]const u8{ "HTTP/1.1 503 Service Unavailable", "HTTP/1.1 200 OK" },
    );
    defer srv.stop();
    // Every response says Retry-After: 0, so the Run's default backoff is not waited out.
    srv.extra_response_headers = "retry-after: 0\r\n";
    const url = try srv.urlOwned(a);
    defer a.free(url);
    try withProvider(wire, Endpoint.of(url), JournaledRun{});
    try expectSameRequestEachTime(wire, srv, 2);
}

test "L2 provider lifecycle ⑥: in a Run a 503 is retried with retry_notice and two journaled attempts on every wire" {
    try eachWire(runRetriesWithNotice);
}

// ── ⑦ a stream that ends before its stop report (#451) ───────────────────────

/// Text, then a clean end of body before the wire's stop report: no
/// `message_delta.stop_reason`, no non-null `finish_reason`, no terminal
/// Responses event, no `finishReason`, no `messageStop`.
fn endsBeforeStop(comptime wire: Wire) []const u8 {
    return switch (wire) {
        .anthropic => "data: {\"type\":\"message_start\",\"message\":{\"id\":\"m\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
            "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
            "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"partial\"}}\n\n",
        .openai_chat => "data: {\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"partial\"},\"finish_reason\":null}]}\n\n",
        .openai_responses => "event: response.output_text.delta\n" ++
            "data: {\"type\":\"response.output_text.delta\",\"item_id\":\"msg_1\",\"output_index\":0,\"delta\":\"partial\"}\n\n",
        .gemini => "data: {\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"text\":\"partial\"}]},\"index\":0}]}\n\n",
        .bedrock => &BEDROCK_ENDS_BEFORE_STOP,
    };
}

const BEDROCK_ENDS_BEFORE_STOP = awsEvent("messageStart", "{\"role\":\"assistant\"}").* ++
    awsEvent("contentBlockDelta", "{\"contentBlockIndex\":0,\"delta\":{\"text\":\"partial\"}}").*;

const EARLY_END_REQUEST_ID = "req-ended-early";

const EndedEarlyRun = struct {
    fn run(_: @This(), provider: cc.api_provider.Provider) !void {
        const a = std.testing.allocator;
        var conv = cc.conversation.Conversation.init(a);
        defer conv.deinit();
        try conv.appendText(.user, "hi");
        var perm = cc.permission.createContext(.bypass_permissions, a);
        perm.no_interactive_prompt = true;
        var sink: u8 = 0;
        const backend = cc.ui_backend.UiBackend{ .ctx = @ptrCast(&sink), .emit = NullBackend.emit, .poll = NullBackend.poll };
        var model_error: ?cc.api_model_error.Detail = null;
        const result = try cc.agent_loop.run(&conv, provider, &.{}, &perm, .{
            .max_turns = 1,
            .auto_compact_threshold = std.math.maxInt(usize),
            .model_error_out = &model_error,
        }, &backend, a);
        try std.testing.expectEqual(cc.agent_loop.StopReason.api_error, result.stop_reason);
        // What every Host surface reads (ABI `model_error`, `run_done`).
        const detail = model_error orelse return error.TestExpectedModelError;
        const view = detail.view();
        try std.testing.expectEqual(cc.api_model_error.Category.stream_interrupted, view.category);
        try std.testing.expectEqual(cc.api_model_error.Retry.retryable, view.retry);
        try std.testing.expectEqualStrings("The response stream ended before it reported how it stopped.", view.message);
        try std.testing.expectEqual(@as(?u16, 200), view.http_status);
        try std.testing.expectEqualStrings(EARLY_END_REQUEST_ID, view.request_id orelse "");
        try std.testing.expectEqual(@as(u32, 1), view.attempts);
        try std.testing.expect(view.code == null and view.type == null);
    }
};

fn endedEarlyIsStreamInterrupted(comptime wire: Wire) !void {
    const a = std.testing.allocator;
    var srv = try harness.MockServer.startCassette(&[_][]const u8{endsBeforeStop(wire)}, 0);
    defer srv.stop();
    srv.extra_response_headers = "x-request-id: " ++ EARLY_END_REQUEST_ID ++ "\r\n";
    const url = try srv.urlOwned(a);
    defer a.free(url);
    try withProvider(wire, Endpoint.of(url), EndedEarlyRun{});
    // Text was shown before the end, so the turn was not sent again.
    try std.testing.expectEqual(@as(usize, 1), srv.requestCount());
}

test "L2 provider lifecycle ⑦: a stream that ends before its stop report fails the Run as stream_interrupted on every wire" {
    try eachWire(endedEarlyIsStreamInterrupted);
}
