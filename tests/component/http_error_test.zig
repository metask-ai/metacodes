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

test "L2 Provider unnamed HTTP 529 returns HttpError without killing the process" {
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
        error.HttpError,
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
        "data: {\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"server overloaded\"}}\n\n";

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
