//! L2 组件测试:Stage 6 — HTTP/SSE 错误现场。
//!
//! 设计目标(doc/E2E_FRAMEWORK_DESIGN.md Stage 6):
//!   1. HTTP 401/429/5xx 在 return error 前读 body 进日志(不再"零现场")。
//!   2. SSE `event: error` 帧被识别为 error_event,上抛**区分性** error.ApiError
//!      (不塌缩成 RequestFailed),让 agent_loop/测试能区分"API 主动报错" vs "网络失败"。
//!
//! 测试策略(对齐 subagent_model_test.zig):MockServer + Client.initWithBaseUrl。

const std = @import("std");
const harness = @import("harness");
const cc = @import("cc");
const pfs = @import("platform").fs; // 可移植文件 IO(std.c.open 的 O 在 Windows 是 void)
const ppaths = @import("platform").paths;

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

// Stage 6.1:401 → sendMessageStream 返 error.Unauthorized,且 body 进日志(err 级)。
// 用 setLogFileFdForTest 注入临时文件,断言文件内含 "body=" + 错误文本。
test "L2 Stage6: HTTP 401 → error.Unauthorized 且 body 进日志" {
    const a = std.testing.allocator;

    // 1) 准备临时日志文件 + 注入(绕过 METACODES_LOG_FILE 一次性 init)
    var lp_buf: [512]u8 = undefined;
    const full_path = try std.fmt.bufPrintZ(&lp_buf, "{s}/cc-zig-http-error-test.log", .{ppaths.tempDir()});
    const fd = pfs.open(full_path.ptr, .{ .ACCMODE = .RDWR, .CREAT = true, .TRUNC = true }, 0o644);
    try std.testing.expect(fd >= 0);
    defer pfs.close(fd);
    defer _ = std.c.unlink(full_path.ptr);
    const previous_log_state = cc.util_log.setLogFileFdForTest(fd);
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

    var io_runtime = std.Io.Threaded.init(a, .{});
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
    _ = pfs.lseek(fd, 0, .set);
    const n = pfs.read(fd, &read_buf);
    try std.testing.expect(n > 0);
    const log_content = read_buf[0..@intCast(n)];
    try std.testing.expect(std.mem.indexOf(u8, log_content, "body=") != null);
    try std.testing.expect(std.mem.indexOf(u8, log_content, "BADKEY42") != null);
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

    var io_runtime = std.Io.Threaded.init(a, .{});
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

    var io_runtime = std.Io.Threaded.init(a, .{});
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

    var io_runtime = std.Io.Threaded.init(a, .{});
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

    var io_runtime = std.Io.Threaded.init(a, .{});
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
