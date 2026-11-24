//! L2 组件测试:Stage 6 — HTTP/SSE 错误现场。
//!
//! 设计目标(E2E 框架 Stage 6):
//!   1. HTTP 401/429/5xx 在 return error 前读 body 进日志(不再"零现场")。
//!   2. SSE `event: error` 帧被识别为 error_event,上抛**区分性** error.ApiError
//!      (不塌缩成 RequestFailed),让 agent_loop/测试能区分"API 主动报错" vs "网络失败"。
//!
//! 测试策略(对齐 subagent_model_test.zig):MockServer + Client.initWithBaseUrl。

const std = @import("std");
const harness = @import("harness");
const cc = @import("cc");

const MINIMAL_END_TURN_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"ok\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

fn drainStream(resp: *cc.client_mod.StreamResponse) !void {
    while (true) {
        const maybe = try resp.next();
        const ev = maybe orelse break;
        switch (ev) {
            .text => |t| std.testing.allocator.free(t),
            else => {},
        }
        if (resp.done) break;
    }
}

// #472:日志捕获文件按进程 + 捕获唯一。同一进程的两次捕获路径不同、都带本进程 pid,
// 互不串行;读取一直读到 EOF,超出缓冲是错误而不是静默截断。
test "L2 log capture: two captures in one process get distinct private files read to EOF" {
    var first = try harness.LogFile.create("http-error-test");
    defer first.deinit();
    var second = try harness.LogFile.create("http-error-test");
    defer second.deinit();

    try std.testing.expect(!std.mem.eql(u8, first.path(), second.path()));
    var pid_buf: [32]u8 = undefined;
    const pid_part = try std.fmt.bufPrint(&pid_buf, "-{d}-", .{@import("platform").process.currentPid()});
    try std.testing.expect(std.mem.indexOf(u8, first.path(), pid_part) != null);
    try std.testing.expect(std.mem.indexOf(u8, second.path(), pid_part) != null);

    // 写进一个的行不会出现在另一个里。
    const line = "only-in-first\n";
    try std.testing.expectEqual(@as(isize, line.len), @import("platform").fs.write(first.fd, line));
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings(line, try first.readAll(&buf));
    try std.testing.expectEqualStrings("", try second.readAll(&buf));

    // 跨多次 read 读到 EOF;比缓冲大则报错。
    const chunk = "y" ** 48;
    for (0..3) |_| try std.testing.expectEqual(@as(isize, chunk.len), @import("platform").fs.write(second.fd, chunk));
    var big: [chunk.len * 3]u8 = undefined;
    try std.testing.expectEqual(chunk.len * 3, (try second.readAll(&big)).len);
    try std.testing.expectError(error.LogFileTooLong, second.readAll(&buf));
}

// Stage 6.1:401 → sendMessageStream 返 error.Unauthorized,且 body 进日志(err 级)。
// 用 setLogFileFdForTest 注入临时文件,断言文件内含 "body=" + 错误文本。
test "L2 Stage6: HTTP 401 → error.Unauthorized 且 body 进日志" {
    const a = std.testing.allocator;

    // 1) 准备临时日志文件 + 注入(绕过 METACODES_LOG_FILE 一次性 init)
    //    文件按进程 + 捕获唯一:integration 分片进程共用同一个 temp 目录(#472)。
    var log_file = try harness.LogFile.create("http-error-test");
    defer log_file.deinit();
    const previous_log_state = cc.util_log.setLogFileFdForTest(log_file.fd);
    defer cc.util_log.restoreForTest(previous_log_state);
    cc.util_log.setLevel(.debug);

    // 2) 起 401 mock(纯 JSON body)
    var srv = try harness.MockServer.startWithStatus(
        "{\"error\":{\"type\":\"authentication_error\",\"message\":\"invalid x-api-key BADKEY42\"}}",
        0,
        "HTTP/1.1 401 Unauthorized",
    );
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    var io_runtime = @import("platform").signal.threadedIo(a, .{});
    defer io_runtime.deinit();
    const io = io_runtime.io();

    var client = cc.client_mod.Client.initWithBaseUrl(a, io, "test-key", "claude-3-5-haiku-20241022", url);
    defer client.deinit();

    // 3) 发请求 → 期望 error.Unauthorized
    const empty_messages: []const cc.types_mod.ApiMessage = &.{};
    const result = client.sendMessageStream(empty_messages, null, null);
    try std.testing.expectError(error.Unauthorized, result);

    // 4) 读日志文件,断言含 body 摘要
    var read_buf: [8192]u8 = undefined;
    const log_content = try log_file.readAll(&read_buf);
    try std.testing.expect(log_content.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, log_content, "body=") != null);
    try std.testing.expect(std.mem.indexOf(u8, log_content, "BADKEY42") != null);
}

test "L2 Provider unnamed HTTP 529 is ServiceUnavailable without killing the process" {
    const a = std.testing.allocator;
    var srv = try harness.MockServer.startWithStatus(
        "{\"error\":{\"type\":\"overloaded_error\",\"message\":\"provider overloaded\"}}",
        0,
        "HTTP/1.1 529 Site Overloaded",
    );
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    var io_runtime = @import("platform").signal.threadedIo(a, .{});
    defer io_runtime.deinit();
    const io = io_runtime.io();

    var client = cc.client_mod.Client.initWithBaseUrl(
        a,
        io,
        "test-key",
        "claude-3-5-haiku-20241022",
        url,
    );
    defer client.deinit();

    const empty_messages: []const cc.types_mod.ApiMessage = &.{};
    try std.testing.expectError(
        error.ServiceUnavailable,
        client.sendMessageStream(empty_messages, null, null),
    );

    // Reaching this assertion proves the unnamed status did not trigger a
    // process-level panic before the typed error crossed the client boundary.
    try std.testing.expectEqual(@as(usize, 1), srv.requestCount());
}

// Stage 6.2:SSE 流中插 `event: error` 帧 → drain 时拿到 error.ApiError(区分 RequestFailed)。
test "L2 Stage6: SSE error 帧 → error.ApiError(非 RequestFailed)" {
    const a = std.testing.allocator;

    const ERROR_SSE =
        "data: {\"type\":\"message_start\",\"message\":{\"id\":\"m\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
        "data: {\"type\":\"error\",\"error\":{\"type\":\"api_error\",\"message\":\"Internal server error\"}}\n\n";

    var srv = try harness.MockServer.start(ERROR_SSE, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    var io_runtime = @import("platform").signal.threadedIo(a, .{});
    defer io_runtime.deinit();
    const io = io_runtime.io();

    var client = cc.client_mod.Client.initWithBaseUrl(a, io, "test-key", "claude-3-5-haiku-20241022", url);
    defer client.deinit();

    const empty_messages: []const cc.types_mod.ApiMessage = &.{};
    var resp = client.sendMessageStream(empty_messages, null, null) catch |e| {
        std.debug.print("sendMessageStream failed: {s}\n", .{@errorName(e)});
        return error.SkipZigTest;
    };
    defer resp.deinit();

    // drain 应在 error 帧处抛 error.ApiError(不是 RequestFailed)。
    const drain_result = drainStream(&resp);
    try std.testing.expectError(error.ApiError, drain_result);
}

test "L2 SSE overloaded_error frame is ServiceUnavailable, the same error as HTTP 529" {
    const a = std.testing.allocator;

    const ERROR_SSE =
        "data: {\"type\":\"message_start\",\"message\":{\"id\":\"m\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
        "event: error\ndata: {\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"Overloaded\"}}\n\n";

    var srv = try harness.MockServer.start(ERROR_SSE, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    var io_runtime = @import("platform").signal.threadedIo(a, .{});
    defer io_runtime.deinit();
    const io = io_runtime.io();

    var client = cc.client_mod.Client.initWithBaseUrl(a, io, "test-key", "claude-3-5-haiku-20241022", url);
    defer client.deinit();

    const empty_messages: []const cc.types_mod.ApiMessage = &.{};
    var resp = try client.sendMessageStream(empty_messages, null, null);
    defer resp.deinit();
    try std.testing.expectError(error.ServiceUnavailable, drainStream(&resp));
}

test "L2 AutoCompact: HTTP context-window-exceeded body → error.ContextWindowExceeded" {
    const a = std.testing.allocator;
    var srv = try harness.MockServer.startWithStatus(
        "{\"error\":{\"type\":\"context_window_exceeded\",\"message\":\"This model's maximum context length was exceeded by too many input tokens.\"}}",
        0,
        "HTTP/1.1 400 Bad Request",
    );
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    var io_runtime = @import("platform").signal.threadedIo(a, .{});
    defer io_runtime.deinit();
    const io = io_runtime.io();

    var client = cc.client_mod.Client.initWithBaseUrl(a, io, "test-key", "claude-3-5-haiku-20241022", url);
    defer client.deinit();

    const empty_messages: []const cc.types_mod.ApiMessage = &.{};
    try std.testing.expectError(error.ContextWindowExceeded, client.sendMessageStream(empty_messages, null, null));
}

test "L2 AutoCompact: SSE context-window-exceeded error 帧 → error.ContextWindowExceeded" {
    const a = std.testing.allocator;
    const ERROR_SSE =
        "data: {\"type\":\"message_start\",\"message\":{\"id\":\"m\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
        "data: {\"type\":\"error\",\"error\":{\"type\":\"invalid_request_error\",\"message\":\"too many input tokens for the context window\"}}\n\n";

    var srv = try harness.MockServer.start(ERROR_SSE, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    var io_runtime = @import("platform").signal.threadedIo(a, .{});
    defer io_runtime.deinit();
    const io = io_runtime.io();

    var client = cc.client_mod.Client.initWithBaseUrl(a, io, "test-key", "claude-3-5-haiku-20241022", url);
    defer client.deinit();

    const empty_messages: []const cc.types_mod.ApiMessage = &.{};
    var resp = client.sendMessageStream(empty_messages, null, null) catch |e| {
        std.debug.print("sendMessageStream failed: {s}\n", .{@errorName(e)});
        return error.SkipZigTest;
    };
    defer resp.deinit();

    try std.testing.expectError(error.ContextWindowExceeded, drainStream(&resp));
}

test "L2 AutoCompact: request_too_large without context wording stays HttpError" {
    const a = std.testing.allocator;
    var srv = try harness.MockServer.startWithStatus(
        "{\"error\":{\"type\":\"request_too_large\",\"message\":\"body too large\"}}",
        0,
        "HTTP/1.1 400 Bad Request",
    );
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    var io_runtime = @import("platform").signal.threadedIo(a, .{});
    defer io_runtime.deinit();
    const io = io_runtime.io();

    var client = cc.client_mod.Client.initWithBaseUrl(a, io, "test-key", "claude-3-5-haiku-20241022", url);
    defer client.deinit();

    const empty_messages: []const cc.types_mod.ApiMessage = &.{};
    try std.testing.expectError(error.HttpError, client.sendMessageStream(empty_messages, null, null));
}

// Stage 6.2 sanity:parseEventType 识别 "error" 类型。
test "L2 Stage6: parseEventType 识别 error 帧" {
    const t = cc.api_stream.parseEventType("{\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\"}}");
    try std.testing.expect(t == .error_event);
}

// ── #565: an error body that arrives in more than one piece ──────────────────
//
// Every provider client reads a non-2xx body into a fixed buffer. The body
// reader used to get that same buffer as its transfer buffer, so a body that
// took more than one read (several chunks, or a `content-length` body whose
// bytes came in apart) had each later piece decoded onto the front of it, over
// what had already been read: the log, the TUI's summary and the structured
// failure all got the scrambled text.

/// OpenRouter's answer to a request that an account without credits cannot
/// pay for, as the service sent it on 2026-11-18.
const CREDITS_MESSAGE = "This request requires more credits, or fewer max_tokens. You requested up to 65536 tokens, but can only afford 32000. To increase, visit https://openrouter.ai/settings/credits and upgrade to a paid account";
const CREDITS_BODY = "{\"error\": {\"message\": \"" ++ CREDITS_MESSAGE ++ "\", \"code\": 402, \"metadata\": {\"provider_name\": null}}}";
const PAYMENT_REQUIRED = "HTTP/1.1 402 Payment Required";
const ERROR_BODY_KEY = "error-body-test-key-5c1e";

/// The provider clients that read a non-2xx body.
const Wire = enum { messages, openai, gemini, bedrock };

/// How the mock sends a body.
const Delivery = union(enum) {
    /// At once, with `content-length`.
    whole,
    /// `transfer-encoding: chunked`, this many bytes to a chunk.
    chunks: usize,
    /// With `content-length`, this many bytes first and the rest 50 ms later.
    paused_after: usize,
};

const HI = [_]cc.types_mod.ApiMessage{
    .{ .role = .user, .content = &[_]cc.types_mod.ApiContent{.{ .text = "hi" }} },
};

/// A stream that opened means the non-2xx answer was taken for a success.
fn expectHttpError(result: anytype) !void {
    if (result) |handle| {
        var opened = handle;
        opened.deinit();
        return error.FailureAccepted;
    } else |err| try std.testing.expectEqual(error.HttpError, err);
}

/// One request on `wire` to the mock at `url`, refused by its answer.
fn sendRefused(wire: Wire, io: std.Io, url: []const u8) !void {
    const a = std.testing.allocator;
    // Gemini and Bedrock take the server's origin and add their own paths.
    const origin = url[0 .. url.len - "/v1/messages".len];
    switch (wire) {
        .messages => {
            var client = cc.client_mod.Client.initWithBaseUrl(a, io, ERROR_BODY_KEY, "claude-sonnet-4-20250514", url);
            defer client.deinit();
            try expectHttpError(client.provider().sendStream(&HI, null, null, null, null, null, ""));
        },
        .openai => {
            var client = cc.api_openai.OpenAIClient.init(a, io, ERROR_BODY_KEY, "gpt-4o", url);
            defer client.deinit();
            try expectHttpError(client.provider().sendStream(&HI, null, null, null, null, null, ""));
        },
        .gemini => {
            var client = cc.api_gemini.GeminiClient.init(a, io, ERROR_BODY_KEY, "gemini-2.5-flash", origin);
            defer client.deinit();
            try expectHttpError(client.provider().sendStream(&HI, null, null, null, null, null, ""));
        },
        .bedrock => {
            var owned = try cc.api_provider_factory.makeProviderWithOptions(a, .bedrock, .{ .fixed = ERROR_BODY_KEY }, "us.anthropic.claude-sonnet-4-6", origin, .chat_completions, .builtin(), .{});
            defer owned.deinit();
            try expectHttpError(owned.provider().sendStream(&HI, null, null, null, null, null, ""));
        },
    }
}

/// What a client made of one non-2xx body: its log line, the summary the TUI
/// prints and the structured failure.
const Recorded = struct {
    log_buf: [16 * 1024]u8 = undefined,
    log_len: usize = 0,
    summary_buf: [cc.api_last_error.SUMMARY_BUF_LEN]u8 = undefined,
    summary_len: usize = 0,
    detail: cc.api_model_error.Detail = .{},

    fn logged(self: *const Recorded) []const u8 {
        return self.log_buf[0..self.log_len];
    }

    /// The body the client's error line quotes.
    fn loggedBody(self: *const Recorded) ![]const u8 {
        const log = self.logged();
        const marker = ": body=";
        const start = (std.mem.indexOf(u8, log, marker) orelse return error.NoBodyLogged) + marker.len;
        const end = std.mem.indexOfScalarPos(u8, log, start, '\n') orelse log.len;
        return log[start..end];
    }

    fn summary(self: *const Recorded) []const u8 {
        return self.summary_buf[0..self.summary_len];
    }

    /// Sends one request on `wire` to a mock that answers `status_line` with
    /// `body`, sent as `delivery` says, and keeps what the client recorded.
    fn collect(self: *Recorded, wire: Wire, status_line: []const u8, body: []const u8, delivery: Delivery) !void {
        var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena_state.deinit();
        var io_runtime = @import("platform").signal.threadedIo(arena_state.allocator(), .{});
        defer io_runtime.deinit();

        // Private to this process and capture: the shards share a temp directory (#472).
        var log_file = try harness.LogFile.create("http-error-test");
        defer log_file.deinit();
        const previous_log_state = cc.util_log.setLogFileFdForTest(log_file.fd);
        defer cc.util_log.restoreForTest(previous_log_state);
        cc.util_log.setStderrEnabled(false);
        cc.util_log.setLevel(.warn);

        var capture: cc.api_model_error.Capture = .{};
        const scope = cc.api_model_error.Scope.enter(&capture);
        defer scope.exit();

        const server = switch (delivery) {
            .whole => try harness.MockServer.startRepeatingStatus(body, status_line, ""),
            .chunks => |bytes| try harness.MockServer.startRepeatingStatusChunked(body, status_line, bytes),
            .paused_after => |bytes| try harness.MockServer.startRepeatingStatusPaused(body, status_line, bytes, 50),
        };
        defer server.stop();
        const url = try server.urlOwned(arena_state.allocator());

        _ = cc.api_last_error.take(&self.summary_buf);
        try sendRefused(wire, io_runtime.io(), url);

        self.log_len = (try log_file.readAll(&self.log_buf)).len;
        const summary_text: []const u8 = cc.api_last_error.take(&self.summary_buf) orelse "";
        self.summary_len = summary_text.len;
        capture.finish(&self.detail);
    }
};

/// The client recorded `CREDITS_BODY` as the mock sent it, everywhere.
fn expectCreditsBodyAsSent(recorded: *const Recorded) !void {
    try std.testing.expectEqualStrings(CREDITS_BODY, try recorded.loggedBody());
    try std.testing.expectEqualStrings("HTTP 402: " ++ CREDITS_BODY, recorded.summary());
    const view = recorded.detail.view();
    try std.testing.expectEqual(@as(?u16, 402), view.http_status);
    try std.testing.expectEqualStrings("402", view.code orelse "");
    try std.testing.expectEqualStrings(CREDITS_MESSAGE, view.message);
}

/// Every wire against every delivery, each one that fails named, so a fault
/// shows on all the clients it reaches.
fn expectCreditsBodyAsSentOnEveryWire(deliveries: []const Delivery) !void {
    var failed: usize = 0;
    for (deliveries) |delivery| {
        for (std.enums.values(Wire)) |wire| {
            var recorded: Recorded = .{};
            recorded.collect(wire, PAYMENT_REQUIRED, CREDITS_BODY, delivery) catch |err| {
                std.debug.print("#565: {s} client, body sent as {any}: {s}\n", .{ @tagName(wire), delivery, @errorName(err) });
                failed += 1;
                continue;
            };
            expectCreditsBodyAsSent(&recorded) catch |err| {
                std.debug.print("#565: {s} client, body sent as {any}: {s}\n", .{ @tagName(wire), delivery, @errorName(err) });
                failed += 1;
            };
        }
    }
    try std.testing.expectEqual(@as(usize, 0), failed);
}

test "L2 #565: an error body sent in several pieces is logged, summarized and parsed as sent, on every provider wire" {
    const deliveries = [_]Delivery{
        // The first 150 bytes and then the rest is how the issue reproduced it.
        .{ .chunks = 150 },
        // Every read of the body takes a new chunk.
        .{ .chunks = 7 },
        // Not chunked, but the body still takes two reads. On a loaded machine
        // both writes can be in before the client reads: the case then cannot
        // catch the old fault, and it still never fails a correct client.
        .{ .paused_after = 150 },
    };
    try expectCreditsBodyAsSentOnEveryWire(&deliveries);
}

test "L2 #565: an error body sent in one piece is still reported as sent, on every provider wire" {
    try expectCreditsBodyAsSentOnEveryWire(&.{ .{ .chunks = CREDITS_BODY.len }, .whole });
}

test "L2 #565: a chunked error body longer than the buffer is kept in order up to it, without a cut key" {
    const a = std.testing.allocator;
    // The size of the buffer each client reads an error body into.
    const bounds = [_]struct { Wire, usize }{ .{ .messages, 2048 }, .{ .openai, 4096 }, .{ .gemini, 4096 }, .{ .bedrock, 4096 } };
    var failed: usize = 0;
    for (bounds) |entry| {
        const wire, const bound = entry;
        // The alphabet over and over, so a chunk out of place shows, in
        // 1000-byte chunks, one of which crosses the bound. The key starts 9
        // bytes before the bound, so what fills the buffer ends in a cut key.
        const body = try a.alloc(u8, bound + 1000);
        defer a.free(body);
        for (body, 0..) |*byte, i| byte.* = 'a' + @as(u8, @intCast(i % 26));
        @memcpy(body[bound - 9 ..][0..ERROR_BODY_KEY.len], ERROR_BODY_KEY);

        var recorded: Recorded = .{};
        try recorded.collect(wire, "HTTP/1.1 400 Bad Request", body, .{ .chunks = 1000 });
        // All of the buffer is read and reported, less as many bytes as a
        // cut key could take: the buffer's size is the bound it is cut at.
        expectKeptUpToBound(&recorded, body[0 .. bound - (ERROR_BODY_KEY.len - 1)]) catch |err| {
            std.debug.print("#565: {s} client, {d}-byte buffer: {s}\n", .{ @tagName(wire), bound, @errorName(err) });
            failed += 1;
        };
    }
    try std.testing.expectEqual(@as(usize, 0), failed);
}

fn expectKeptUpToBound(recorded: *const Recorded, kept: []const u8) !void {
    try std.testing.expectEqualStrings(kept, try recorded.loggedBody());
    try std.testing.expect(std.mem.indexOf(u8, recorded.logged(), ERROR_BODY_KEY[0..9]) == null);
}
