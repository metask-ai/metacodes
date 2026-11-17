//! 流中途错误的名字约定 L2(api/stream.zig `midStreamReadError`):四条 wire 上
//!   - `RequestFailed` **只**表示连接在流中途断了;
//!   - 服务端在流里声明的失败一律是 `ApiError`(Anthropic 错误帧、OpenAI chat 兼容端与 Gemini 的
//!     顶层 `error` 对象、Responses 的 `response.failed`),并写"API 错误帧"现场;
//! 以及它对 agent_loop 每个请求自带的那次重发(`STREAM_RETRIES_PER_REQUEST`,#461)的后果,TUI 默认(不配重试):
//!   ① 服务端报错、零可见输出 → 不重发,api_error(答复不能被重发盖掉);
//!   ② 断连、零可见输出 → 句柄上是 RequestFailed;run 同轮重发一次 → end_turn;
//!   ③ 断连、已流出可见文本 → 同样重发一次(半截以 discarded 撤回)→ end_turn。
//!
//! 2026-10-24 之前:Responses 的 `response.failed` 也报 RequestFailed,与 Anthropic 的断连同名,
//! 所以零产出重发只敢覆盖 stall 与没收尾的流;OpenAI chat / Gemini 的错误 chunk 被当空 chunk
//! 跳过,随后变成"没收尾",服务端的答复反而会被重发。MockServer 的 mid-stream cut 发正文的
//! 前一半后断开连接,不发终止 chunk——两种 cassette 的切点位置由 comptime 断言钉住。

const std = @import("std");
const harness = @import("harness");
const cc = @import("cc");

const Wire = enum { anthropic, openai_chat, openai_responses, gemini };
const ALL_WIRES = [_]Wire{ .anthropic, .openai_chat, .openai_responses, .gemini };

// ── cassettes ────────────────────────────────────────────────────────────────

const ANTHROPIC_START = "data: {\"type\":\"message_start\",\"message\":{\"id\":\"m\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n";
const ANTHROPIC_PING = "event: ping\ndata: {\"type\": \"ping\"}\n\n";
const ANTHROPIC_TEXT =
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"answer\"}}\n\n";
const ANTHROPIC_END =
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":2}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";
const ANTHROPIC_ERROR = "event: error\ndata: {\"type\":\"error\",\"error\":{\"type\":\"invalid_request_error\",\"message\":\"model not found\"}}\n\n";

const CHAT_TEXT = "data: {\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"answer\"},\"finish_reason\":null}]}\n\n";
const CHAT_END = "data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n" ++ "data: [DONE]\n\n";
/// OpenRouter 等兼容端在流中途报错的形状。
const CHAT_ERROR = "data: {\"error\":{\"message\":\"model not found\",\"code\":404}}\n\n";

const RESPONSES_TEXT =
    "event: response.output_text.delta\n" ++
    "data: {\"type\":\"response.output_text.delta\",\"item_id\":\"msg_1\",\"output_index\":0,\"delta\":\"answer\"}\n\n";
const RESPONSES_END =
    "event: response.completed\n" ++
    "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_1\",\"status\":\"completed\",\"usage\":{\"input_tokens\":1,\"input_tokens_details\":{\"cached_tokens\":0},\"output_tokens\":2}}}\n\n";
const RESPONSES_ERROR =
    "event: response.failed\n" ++
    "data: {\"type\":\"response.failed\",\"response\":{\"id\":\"resp_2\",\"status\":\"failed\",\"error\":{\"code\":\"model_not_found\",\"message\":\"model not found\"}}}\n\n";

const GEMINI_TEXT = "data: {\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"text\":\"answer\"}]}}]}\n\n";
const GEMINI_END = "data: {\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"text\":\".\"}]},\"finishReason\":\"STOP\"}],\"usageMetadata\":{\"promptTokenCount\":1,\"candidatesTokenCount\":2}}\n\n";
const GEMINI_ERROR = "data: {\"error\":{\"code\":404,\"message\":\"model not found\",\"status\":\"NOT_FOUND\"}}\n\n";

const COMMENT = ": keepalive\n\n";

fn repeat(comptime s: []const u8, comptime n: usize) []const u8 {
    comptime var out: []const u8 = "";
    inline for (0..n) |_| out = out ++ s;
    return out;
}

/// 不可见的填充:保活行。放在可见文本前面,前一半的切点落在它里面;放在后面,切点落在文本之后。
fn padding(comptime wire: Wire) []const u8 {
    return switch (wire) {
        .anthropic => repeat(ANTHROPIC_PING, 24),
        .openai_chat, .openai_responses, .gemini => repeat(COMMENT, 48),
    };
}

/// 流的开头:Anthropic 的 message_start 不可见,其余 wire 没有。
fn opening(comptime wire: Wire) []const u8 {
    return if (wire == .anthropic) ANTHROPIC_START else "";
}

fn visibleText(comptime wire: Wire) []const u8 {
    return switch (wire) {
        .anthropic => ANTHROPIC_TEXT,
        .openai_chat => CHAT_TEXT,
        .openai_responses => RESPONSES_TEXT,
        .gemini => GEMINI_TEXT,
    };
}

fn ending(comptime wire: Wire) []const u8 {
    return switch (wire) {
        .anthropic => ANTHROPIC_END,
        .openai_chat => CHAT_END,
        .openai_responses => RESPONSES_END,
        .gemini => GEMINI_END,
    };
}

fn serverError(comptime wire: Wire) []const u8 {
    return switch (wire) {
        .anthropic => ANTHROPIC_ERROR,
        .openai_chat => CHAT_ERROR,
        .openai_responses => RESPONSES_ERROR,
        .gemini => GEMINI_ERROR,
    };
}

fn complete(comptime wire: Wire) []const u8 {
    return comptime opening(wire) ++ visibleText(wire) ++ ending(wire);
}

/// 服务端报错之前没有任何可见输出。
fn errorBeforeText(comptime wire: Wire) []const u8 {
    return comptime opening(wire) ++ serverError(wire);
}

/// 前一半全是不可见内容:切点落在填充里,文本从未到达。
fn dropBeforeText(comptime wire: Wire) []const u8 {
    const body = comptime opening(wire) ++ padding(wire) ++ visibleText(wire) ++ ending(wire);
    comptime {
        @setEvalBranchQuota(200_000);
        const text_at = std.mem.indexOf(u8, body, visibleText(wire)).?;
        if (text_at < body.len / 2) @compileError("dropBeforeText: the cut must land before the visible text");
    }
    return body;
}

/// 文本在前一半里流完,切点落在其后的填充里,停止报告从未到达。
fn dropAfterText(comptime wire: Wire) []const u8 {
    const body = comptime opening(wire) ++ visibleText(wire) ++ padding(wire) ++ ending(wire);
    comptime {
        @setEvalBranchQuota(200_000);
        const text_end = std.mem.indexOf(u8, body, visibleText(wire)).? + visibleText(wire).len;
        if (text_end > body.len / 2) @compileError("dropAfterText: the cut must land after the visible text");
        if (std.mem.indexOf(u8, body, ending(wire)).? < body.len / 2) @compileError("dropAfterText: the stop report must be cut off");
    }
    return body;
}

// ── driver ───────────────────────────────────────────────────────────────────

fn clearLastError() void {
    var buf: [cc.api_last_error.SUMMARY_BUF_LEN]u8 = undefined;
    _ = cc.api_last_error.take(&buf);
}

fn withProvider(
    comptime wire: Wire,
    a: std.mem.Allocator,
    url: []const u8,
    comptime body: fn (std.mem.Allocator, cc.api_provider.Provider) anyerror!void,
) !void {
    var io_rt = @import("platform").signal.threadedIo(a, .{});
    defer io_rt.deinit();
    const io = io_rt.io();
    switch (wire) {
        .anthropic => {
            var client = cc.client_mod.Client.initWithBaseUrl(a, io, "k", "claude-3-5-haiku-20241022", url);
            defer client.deinit();
            try body(a, client.provider());
        },
        .openai_chat, .openai_responses => {
            var client = cc.api_openai.OpenAIClient.init(a, io, "k", "model", url);
            defer client.deinit();
            if (wire == .openai_responses) client.protocol = .responses;
            try body(a, client.provider());
        },
        .gemini => {
            var client = cc.api_gemini.GeminiClient.init(a, io, "k", "gemini-2.5-flash", url);
            defer client.deinit();
            try body(a, client.provider());
        },
    }
}

fn runOneTurn(a: std.mem.Allocator, provider: cc.api_provider.Provider) !cc.agent_loop.RunResult {
    var conv = cc.conversation.Conversation.init(a);
    defer conv.deinit();
    try conv.appendText(.user, "hi");
    var perm = cc.permission.createContext(.bypass_permissions, a);
    perm.no_interactive_prompt = true;
    const defs: []const cc.json_mod.ToolDefinition = &.{};
    var render = cc.writer_backend.WriterBackend.initNull();
    const be = render.backend();
    // TUI 默认:max_stream_turn_retries = 0。
    return cc.agent_loop.run(&conv, provider, defs, &perm, .{
        .max_turns = 1,
        .auto_compact_threshold = std.math.maxInt(usize),
    }, &be, a);
}

/// 只读句柄,直到它报错或结束;返回它报的错(null = 正常结束)。
fn drainError(provider: cc.api_provider.Provider) !?anyerror {
    const msgs = [_]cc.types_mod.ApiMessage{
        .{ .role = .user, .content = &[_]cc.types_mod.ApiContent{.{ .text = "hi" }} },
    };
    var handle = try provider.sendStream(&msgs, null, null, null, null, null, "");
    defer handle.deinit();
    while (true) {
        // As a value, not as this function's error: the test compares it.
        const ev = handle.next() catch |err| return @as(?anyerror, err);
        const event = ev orelse return null;
        freeEvent(std.testing.allocator, event);
    }
}

/// Owned payloads go back to the allocator the client used (same contract as agent_loop).
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

// ── ① server-declared error before any output: ApiError, not re-sent ─────────

const ServerError = struct {
    fn run(a: std.mem.Allocator, provider: cc.api_provider.Provider) anyerror!void {
        clearLastError();
        const result = try runOneTurn(a, provider);
        try std.testing.expectEqual(cc.agent_loop.StopReason.api_error, result.stop_reason);
        var buf: [cc.api_last_error.SUMMARY_BUF_LEN]u8 = undefined;
        const detail = cc.api_last_error.take(&buf) orelse return error.TestExpectedLastError;
        try std.testing.expect(std.mem.startsWith(u8, detail, "API 错误帧: "));
        try std.testing.expect(std.mem.indexOf(u8, detail, "model not found") != null);
    }
    fn handle(_: std.mem.Allocator, provider: cc.api_provider.Provider) anyerror!void {
        try std.testing.expectEqual(@as(?anyerror, error.ApiError), try drainError(provider));
        clearLastError();
    }
};

fn serverErrorNotResent(comptime wire: Wire) !void {
    const a = std.testing.allocator;
    // If it were re-sent, the second response would answer and the Run would end end_turn.
    const bodies = [_][]const u8{ errorBeforeText(wire), complete(wire) };
    var srv = try harness.MockServer.startCassette(&bodies, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);
    try withProvider(wire, a, url, ServerError.run);
    try std.testing.expectEqual(@as(usize, 1), srv.requestCount());

    var srv_handle = try harness.MockServer.startCassette(&[_][]const u8{errorBeforeText(wire)}, 0);
    defer srv_handle.stop();
    const url_handle = try srv_handle.urlOwned(a);
    defer a.free(url_handle);
    try withProvider(wire, a, url_handle, ServerError.handle);
}

test "L2 stream errors ①: a server-declared error before any output is ApiError on every wire and is not re-sent" {
    inline for (ALL_WIRES) |wire| serverErrorNotResent(wire) catch |err| {
        std.debug.print("wire {s} failed\n", .{@tagName(wire)});
        return err;
    };
}

// ── ② dropped connection before any output: RequestFailed, re-sent once ──────

const DropBefore = struct {
    fn handle(_: std.mem.Allocator, provider: cc.api_provider.Provider) anyerror!void {
        try std.testing.expectEqual(@as(?anyerror, error.RequestFailed), try drainError(provider));
        clearLastError();
    }
    fn run(a: std.mem.Allocator, provider: cc.api_provider.Provider) anyerror!void {
        clearLastError();
        const result = try runOneTurn(a, provider);
        try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, result.stop_reason);
        clearLastError();
    }
};

fn dropBeforeResent(comptime wire: Wire) !void {
    const a = std.testing.allocator;
    {
        var srv = try harness.MockServer.startCassetteMidStreamCut(&[_][]const u8{dropBeforeText(wire)}, 0);
        defer srv.stop();
        const url = try srv.urlOwned(a);
        defer a.free(url);
        try withProvider(wire, a, url, DropBefore.handle);
    }
    const bodies = [_][]const u8{ dropBeforeText(wire), complete(wire) };
    var srv = try harness.MockServer.startCassetteMidStreamCut(&bodies, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);
    try withProvider(wire, a, url, DropBefore.run);
    try std.testing.expectEqual(@as(usize, 2), srv.requestCount());
}

test "L2 stream errors ②: a connection dropped before any output is RequestFailed on every wire and is re-sent once" {
    inline for (ALL_WIRES) |wire| dropBeforeResent(wire) catch |err| {
        std.debug.print("wire {s} failed\n", .{@tagName(wire)});
        return err;
    };
}

// ── ③ dropped connection after visible text: re-sent once (#461) ─────────────

const DropAfter = struct {
    fn run(a: std.mem.Allocator, provider: cc.api_provider.Provider) anyerror!void {
        clearLastError();
        const result = try runOneTurn(a, provider);
        try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, result.stop_reason);
        clearLastError();
    }
};

fn dropAfterResent(comptime wire: Wire) !void {
    const a = std.testing.allocator;
    const bodies = [_][]const u8{ dropAfterText(wire), complete(wire) };
    var srv = try harness.MockServer.startCassetteMidStreamCut(&bodies, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);
    try withProvider(wire, a, url, DropAfter.run);
    try std.testing.expectEqual(@as(usize, 2), srv.requestCount());
}

test "L2 stream errors ③: a connection dropped after visible text is re-sent once on every wire (#461)" {
    inline for (ALL_WIRES) |wire| dropAfterResent(wire) catch |err| {
        std.debug.print("wire {s} failed\n", .{@tagName(wire)});
        return err;
    };
}

// ── ④ a local failure keeps its name and is not re-sent ──────────────────────

test "L2 stream errors ④: an over-long SSE line is StreamTooLong, not RequestFailed, and is not re-sent" {
    const a = std.testing.allocator;
    // message_start, then one data line past the 16 MiB line cap: the client gives up on it
    // locally. A re-send would hit the same wall; calling it a dropped connection would lie.
    const line_len = cc.api_stream.MAX_SSE_LINE_BYTES + 2;
    const prefix = ANTHROPIC_START ++ "data: ";
    const huge = try a.alloc(u8, prefix.len + line_len + 2);
    defer a.free(huge);
    @memcpy(huge[0..prefix.len], prefix);
    @memset(huge[prefix.len..][0..line_len], 'x');
    @memcpy(huge[huge.len - 2 ..], "\n\n");

    const bodies = [_][]const u8{ huge, complete(.anthropic) };
    var srv = try harness.MockServer.startCassette(&bodies, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    var io_rt = @import("platform").signal.threadedIo(a, .{});
    defer io_rt.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(a, io_rt.io(), "k", "claude-3-5-haiku-20241022", url);
    defer client.deinit();
    try std.testing.expectEqual(@as(?anyerror, error.StreamTooLong), try drainError(client.provider()));
    clearLastError();
    // The cassette repeats its last body once exhausted, so serve the huge line again.
    const bodies_run = [_][]const u8{ huge, complete(.anthropic) };
    var srv_run = try harness.MockServer.startCassette(&bodies_run, 0);
    defer srv_run.stop();
    const url_run = try srv_run.urlOwned(a);
    defer a.free(url_run);
    var client_run = cc.client_mod.Client.initWithBaseUrl(a, io_rt.io(), "k", "claude-3-5-haiku-20241022", url_run);
    defer client_run.deinit();
    const result = try runOneTurn(a, client_run.provider());
    try std.testing.expectEqual(cc.agent_loop.StopReason.api_error, result.stop_reason);
    try std.testing.expectEqual(@as(usize, 1), srv_run.requestCount());
    clearLastError();
}
