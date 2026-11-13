//! 死连接 L2:一个已经证明"流中途沉默时会按节奏发 keepalive"的端点,某条连接连 keepalive 都不来了
//! ——按学到的节奏判连接已死,而不是等满正文进展上限(生产里是 30 分钟)。
//!
//! 2026-10-24 的真实故障:glm-5.3-flash 经 napi,一个请求只收到 TLS 握手 + 响应头 + message_start
//! (6.5 KB),之后 1801 s 一个字节都没有,FIN/RST 也没有;同一网关健康时每 ≤15 s 必发一次 ping。
//! 客户端按 max_tokens 放大的正文上限盲等了 30 分钟,run 以 api_error 收口,用户手动 /retry,
//! 同一请求 18.7 s 完成。修法两层,本文件用真 HTTP 链路 + 真 client + 真 agent loop 逐层证明:
//!   ⑪ 三个 provider client(anthropic / openai chat / gemini)都学到保活节奏,随后的沉默连接在
//!     学到的上限附近被判"连接已断",远早于正文进展上限,文案点名 keepalive 也没来(读于
//!     `retry_notice` 之时:请求自带的那次重发(#461)随后成功,会清掉现场);
//!   ⑫ 反例:从未在流中途发过 keepalive 的端点,沉默连接仍只按正文进展上限判(旧行为不变);
//!   ⑬ 反例:已学到节奏的端点,keepalive 一直在到的慢流(进展沉默 > 死连接上限)不被误杀;
//!   ⑭ 事故原形:message_start 之后连接死掉,判死后零可见输出 → 同轮自动重发一次 → end_turn。
//! 时间尺度用 `KeepaliveTuning` 缩小(生产:2 s 最小间隔 / 3 个样本 / 4 倍 / 2 分钟下限)。

const std = @import("std");
const harness = @import("harness");
const cc = @import("cc");

const Registry = cc.api_provider.RequestAbortRegistry;

const Wire = enum { anthropic, openai_chat, gemini };

/// 滴流间隔:每条 keepalive 前的真实沉默(≥ TUNING.min_gap_ms 才算样本)。
const TRICKLE_MS: u32 = 150;
/// 死连接上限 = max(学到的间隔 × 4, floor)。间隔 ~150 ms → 600 ms,被 floor 抬到 1000 ms;
/// 满载 CI 上间隔漂到 250 ms 以内,上限仍是 floor,断言稳定。
const TUNING = Registry.KeepaliveTuning{ .min_gap_ms = 50, .min_samples = 3, .multiplier = 4, .floor_ms = 1_000 };
/// 正文进展上限故意远大于死连接上限:⑪⑭ 若在它之前结束,就只能是死连接规则判的。
const BODY_MS: u64 = 20_000;
/// ⑫ 用的正文上限:未武装的端点必须等满它。
const SHORT_BODY_MS: u64 = 2_500;
const HEAD_MS: u64 = 5_000;
/// 单用例墙钟上限(真挂死会远超)。
const BOUND_MS: i64 = 10_000;

// ── cassettes ────────────────────────────────────────────────────────────────

const ANTHROPIC_PING = "event: ping\ndata: {\"type\": \"ping\"}\n\n";
const ANTHROPIC_START =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"m\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n";
const ANTHROPIC_TEXT_A = "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"a\"}}\n\n";
const ANTHROPIC_END =
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"b\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":2}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const CHAT_TEXT_A = "data: {\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"a\"},\"finish_reason\":null}]}\n\n";
const CHAT_END =
    "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"b\"},\"finish_reason\":null}]}\n\n" ++
    "data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n" ++
    "data: [DONE]\n\n";

const GEMINI_TEXT_A = "data: {\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"text\":\"a\"}]}}]}\n\n";
const GEMINI_END = "data: {\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"text\":\"b\"}]},\"finishReason\":\"STOP\"}],\"usageMetadata\":{\"promptTokenCount\":1,\"candidatesTokenCount\":2}}\n\n";

/// SSE 注释行:OpenAI 兼容代理与 Gemini 网关常见的 keepalive 形状。
const COMMENT_KEEPALIVE = ": keepalive\n\n";

/// 进展之后三条 keepalive(各自前面一个 TRICKLE_MS 的沉默)再收尾:恰好够武装。
fn learnBody(comptime wire: Wire) []const u8 {
    return switch (wire) {
        .anthropic => ANTHROPIC_START ++ ANTHROPIC_TEXT_A ++ ANTHROPIC_PING ++ ANTHROPIC_PING ++ ANTHROPIC_PING ++ ANTHROPIC_END,
        .openai_chat => CHAT_TEXT_A ++ COMMENT_KEEPALIVE ++ COMMENT_KEEPALIVE ++ COMMENT_KEEPALIVE ++ CHAT_END,
        .gemini => GEMINI_TEXT_A ++ COMMENT_KEEPALIVE ++ COMMENT_KEEPALIVE ++ COMMENT_KEEPALIVE ++ GEMINI_END,
    };
}

/// 同样的回答,但从不发 keepalive(⑫:端点没有证明过自己会 ping)。
fn quietBody(comptime wire: Wire) []const u8 {
    return switch (wire) {
        .anthropic => ANTHROPIC_START ++ ANTHROPIC_TEXT_A ++ ANTHROPIC_END,
        .openai_chat => CHAT_TEXT_A ++ CHAT_END,
        .gemini => GEMINI_TEXT_A ++ GEMINI_END,
    };
}

/// 沉默响应:先发 `silentPrefix` 里的可见文本,然后连接死掉不关(尾部永远不发)。
fn silentPrefix(comptime wire: Wire) []const u8 {
    return switch (wire) {
        .anthropic => ANTHROPIC_START ++ ANTHROPIC_TEXT_A,
        .openai_chat => CHAT_TEXT_A,
        .gemini => GEMINI_TEXT_A,
    };
}

fn silentBody(comptime wire: Wire) []const u8 {
    return comptime silentPrefix(wire) ++ switch (wire) {
        .anthropic => ANTHROPIC_END,
        .openai_chat => CHAT_END,
        .gemini => GEMINI_END,
    };
}

// ── driver ───────────────────────────────────────────────────────────────────

/// last_error 是进程级单例:同一测试二进制里其它用例可能留下现场,用例开头先清场。
fn clearLastError() void {
    var buf: [cc.api_last_error.SUMMARY_BUF_LEN]u8 = undefined;
    _ = cc.api_last_error.take(&buf);
}

/// What the TUI would print when a request is re-issued: the stall's
/// `last_error` record, read when `retry_notice` arrives (a re-issue that then
/// succeeds clears it).
const RetryCapture = struct {
    buf: [cc.api_last_error.SUMMARY_BUF_LEN]u8 = undefined,
    detail: ?[]const u8 = null,
    notices: u32 = 0,

    fn emit(ctx: *anyopaque, _: cc.session_id.SessionId, ev: cc.ui_event.CoreEvent) void {
        const self: *RetryCapture = @ptrCast(@alignCast(ctx));
        if (ev != .retry_notice) return;
        self.notices += 1;
        self.detail = cc.api_last_error.take(&self.buf);
    }

    fn poll(_: *anyopaque, _: cc.session_id.SessionId) ?cc.ui_event.UiEvent {
        return null;
    }
};

fn runOneTurn(a: std.mem.Allocator, provider: cc.api_provider.Provider) !cc.agent_loop.RunResult {
    var capture = RetryCapture{};
    return runOneTurnCapturing(a, provider, &capture);
}

fn runOneTurnCapturing(a: std.mem.Allocator, provider: cc.api_provider.Provider, capture: *RetryCapture) !cc.agent_loop.RunResult {
    var conv = cc.conversation.Conversation.init(a);
    defer conv.deinit();
    try conv.appendText(.user, "hi");
    var perm = cc.permission.createContext(.bypass_permissions, a);
    perm.no_interactive_prompt = true;
    const defs: []const cc.json_mod.ToolDefinition = &.{};
    const be = cc.ui_backend.UiBackend{ .ctx = @ptrCast(capture), .emit = RetryCapture.emit, .poll = RetryCapture.poll };
    // TUI 默认:max_stream_turn_retries = 0(每个请求只有自带的那一次重发)。
    return cc.agent_loop.run(&conv, provider, defs, &perm, .{
        .max_turns = 1,
        .auto_compact_threshold = std.math.maxInt(usize),
    }, &be, a);
}

/// 三个 provider client 的流活性旋钮是同一套字段;按线格式建 client,交给 `body` 跑。
fn withClient(
    comptime wire: Wire,
    a: std.mem.Allocator,
    url: []const u8,
    body_ms: u64,
    comptime body: fn (std.mem.Allocator, cc.api_provider.Provider, *Registry) anyerror!void,
) !void {
    var io_rt = @import("platform").signal.threadedIo(a, .{});
    defer io_rt.deinit();
    const io = io_rt.io();
    switch (wire) {
        .anthropic => {
            var client = cc.client_mod.Client.initWithBaseUrl(a, io, "k", "claude-3-5-haiku-20241022", url);
            defer client.deinit();
            client.stream_idle_timeout_ms = HEAD_MS;
            client.stream_body_idle_timeout_ms = body_ms;
            client.abort_registry.keepalive_tuning = TUNING;
            try body(a, client.provider(), &client.abort_registry);
        },
        .openai_chat => {
            var client = cc.api_openai.OpenAIClient.init(a, io, "k", "model", url);
            defer client.deinit();
            client.stream_idle_timeout_ms = HEAD_MS;
            client.stream_body_idle_timeout_ms = body_ms;
            client.abort_registry.keepalive_tuning = TUNING;
            try body(a, client.provider(), &client.abort_registry);
        },
        .gemini => {
            var client = cc.api_gemini.GeminiClient.init(a, io, "k", "gemini-2.5-flash", url);
            defer client.deinit();
            client.stream_idle_timeout_ms = HEAD_MS;
            client.stream_body_idle_timeout_ms = body_ms;
            client.abort_registry.keepalive_tuning = TUNING;
            try body(a, client.provider(), &client.abort_registry);
        },
    }
}

/// The decimal number right after `label` in `text` (e.g. "上限 1000 ms" → 1000).
fn numberAfter(text: []const u8, label: []const u8) !u64 {
    const start = (std.mem.indexOf(u8, text, label) orelse return error.TestExpectedLabel) + label.len;
    var end = start;
    while (end < text.len and std.ascii.isDigit(text[end])) end += 1;
    return std.fmt.parseInt(u64, text[start..end], 10);
}

fn keepaliveSamples(registry: *Registry) u32 {
    registry.mutex.lock();
    defer registry.mutex.unlock();
    return registry.keepalive.samples;
}

// ── ⑪ learned cadence → a dead connection is judged dead early, on every wire ──

const ArmedThenDead = struct {
    fn run(a: std.mem.Allocator, provider: cc.api_provider.Provider, registry: *Registry) anyerror!void {
        // Turn 1: the endpoint shows its cadence (three keepalives after real silences).
        const learn = try runOneTurn(a, provider);
        try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, learn.stop_reason);
        try std.testing.expectEqual(@as(u32, 3), keepaliveSamples(registry));

        // Turn 2: visible text, then the connection dies without closing.
        clearLastError();
        var capture = RetryCapture{};
        const t0 = cc.util_time.nowMs();
        const dead = try runOneTurnCapturing(a, provider, &capture);
        const elapsed = cc.util_time.nowMs() - t0;
        // Text had streamed; the request's own re-issue (#461) answers.
        try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, dead.stop_reason);
        try std.testing.expectEqual(@as(u32, 1), capture.notices);
        try std.testing.expect(elapsed >= @as(i64, @intCast(TUNING.floor_ms)));
        // Judged by the learned limit, not by the progress limit (20 s).
        try std.testing.expect(elapsed < BOUND_MS);
        try std.testing.expect(elapsed < @as(i64, @intCast(BODY_MS)));
        const detail = capture.detail orelse return error.TestExpectedLastError;
        try std.testing.expect(std.mem.startsWith(u8, detail, "连接已断: "));
        try std.testing.expect(std.mem.indexOf(u8, detail, "连 keepalive 也没有") != null);
        // The printed limit is the learned one (floor 1 s, more only if the cadence drifted),
        // never the 20 s progress limit.
        const limit = try numberAfter(detail, "上限 ");
        try std.testing.expect(limit >= TUNING.floor_ms);
        try std.testing.expect(limit < BODY_MS);
        // The verdict spent the evidence.
        try std.testing.expectEqual(@as(u32, 0), keepaliveSamples(registry));
    }
};

fn armedThenDead(comptime wire: Wire) !void {
    const a = std.testing.allocator;
    const bodies = [_][]const u8{ learnBody(wire), silentBody(wire) };
    var srv = try harness.MockServer.startCassetteTrickleSilent(&bodies, TRICKLE_MS, 1, silentPrefix(wire).len);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);
    try withClient(wire, a, url, BODY_MS, ArmedThenDead.run);
    // The learning turn, the dead attempt, its re-issue.
    try std.testing.expectEqual(@as(usize, 3), srv.requestCount());
}

test "L2 dead connection ⑪ anthropic: learned keepalive cadence → a silent connection is judged dead at the learned limit, not the 20 s progress limit" {
    try armedThenDead(.anthropic);
}

test "L2 dead connection ⑪ openai chat: SSE comment keepalives arm the rule through the OpenAI client" {
    try armedThenDead(.openai_chat);
}

test "L2 dead connection ⑪ gemini: SSE comment keepalives arm the rule through the Gemini client" {
    try armedThenDead(.gemini);
}

// ── ⑫ an endpoint that never pinged mid-stream keeps the old behaviour ──────

const NeverPinged = struct {
    fn run(a: std.mem.Allocator, provider: cc.api_provider.Provider, registry: *Registry) anyerror!void {
        const first = try runOneTurn(a, provider);
        try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, first.stop_reason);
        try std.testing.expectEqual(@as(u32, 0), keepaliveSamples(registry));

        clearLastError();
        var capture = RetryCapture{};
        const t0 = cc.util_time.nowMs();
        const stalled = try runOneTurnCapturing(a, provider, &capture);
        const elapsed = cc.util_time.nowMs() - t0;
        // The request's own re-issue (#461) answers after the stall.
        try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, stalled.stop_reason);
        try std.testing.expectEqual(@as(u32, 1), capture.notices);
        // Total silence, but no evidence: only the progress limit may end it.
        try std.testing.expect(elapsed >= @as(i64, @intCast(SHORT_BODY_MS)));
        try std.testing.expect(elapsed < BOUND_MS);
        const detail = capture.detail orelse return error.TestExpectedLastError;
        try std.testing.expect(std.mem.startsWith(u8, detail, "正文空闲超时: "));
        try std.testing.expect(std.mem.indexOf(u8, detail, "内无任何字节(上限 2500 ms)") != null);
    }
};

fn neverPinged(comptime wire: Wire) !void {
    const a = std.testing.allocator;
    const bodies = [_][]const u8{ quietBody(wire), silentBody(wire) };
    var srv = try harness.MockServer.startCassetteTrickleSilent(&bodies, TRICKLE_MS, 1, silentPrefix(wire).len);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);
    try withClient(wire, a, url, SHORT_BODY_MS, NeverPinged.run);
    try std.testing.expectEqual(@as(usize, 3), srv.requestCount());
}

test "L2 dead connection ⑫ anthropic: no mid-stream keepalive ever seen → a silent connection waits for the progress limit" {
    try neverPinged(.anthropic);
}

test "L2 dead connection ⑫ openai chat: no mid-stream keepalive ever seen → progress limit only" {
    try neverPinged(.openai_chat);
}

test "L2 dead connection ⑫ gemini: no mid-stream keepalive ever seen → progress limit only" {
    try neverPinged(.gemini);
}

// ── ⑬ an armed endpoint whose keepalives keep arriving is never killed by transport ──

/// 14 个 ping(14 × 150 ms = 2.1 s 的进展沉默,超过 1 s 的死连接上限)之后才有正文。
const SLOW_ALIVE =
    ANTHROPIC_START ++
    ANTHROPIC_PING ++ ANTHROPIC_PING ++ ANTHROPIC_PING ++ ANTHROPIC_PING ++ ANTHROPIC_PING ++ ANTHROPIC_PING ++ ANTHROPIC_PING ++
    ANTHROPIC_PING ++ ANTHROPIC_PING ++ ANTHROPIC_PING ++ ANTHROPIC_PING ++ ANTHROPIC_PING ++ ANTHROPIC_PING ++ ANTHROPIC_PING ++
    ANTHROPIC_TEXT_A ++ ANTHROPIC_END;

const SlowButAlive = struct {
    fn run(a: std.mem.Allocator, provider: cc.api_provider.Provider, registry: *Registry) anyerror!void {
        const learn = try runOneTurn(a, provider);
        try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, learn.stop_reason);
        try std.testing.expectEqual(@as(u32, 3), keepaliveSamples(registry));
        clearLastError();
        const t0 = cc.util_time.nowMs();
        const slow = try runOneTurn(a, provider);
        const elapsed = cc.util_time.nowMs() - t0;
        try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, slow.stop_reason);
        // It really was silent in progress terms for longer than the dead limit.
        try std.testing.expect(elapsed >= @as(i64, @intCast(14 * TRICKLE_MS)));
        var buf: [cc.api_last_error.SUMMARY_BUF_LEN]u8 = undefined;
        try std.testing.expect(cc.api_last_error.take(&buf) == null);
        // Still armed: a progress-silent but alive stream spends nothing and adds samples.
        try std.testing.expect(keepaliveSamples(registry) > 3);
    }
};

test "L2 dead connection ⑬: an armed endpoint's slow stream with keepalives (progress silence > dead limit) completes" {
    const a = std.testing.allocator;
    const bodies = [_][]const u8{ learnBody(.anthropic), SLOW_ALIVE };
    var srv = try harness.MockServer.startCassette(&bodies, TRICKLE_MS);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);
    try withClient(.anthropic, a, url, BODY_MS, SlowButAlive.run);
    try std.testing.expectEqual(@as(usize, 2), srv.requestCount());
}

// ── ⑭ the incident: message_start, then a dead connection → judged dead → silent retry ──

const IncidentShape = struct {
    fn run(a: std.mem.Allocator, provider: cc.api_provider.Provider, registry: *Registry) anyerror!void {
        const learn = try runOneTurn(a, provider);
        try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, learn.stop_reason);
        try std.testing.expectEqual(@as(u32, 3), keepaliveSamples(registry));
        clearLastError();
        const t0 = cc.util_time.nowMs();
        const result = try runOneTurn(a, provider);
        const elapsed = cc.util_time.nowMs() - t0;
        // Nothing visible had streamed, so the same turn is re-issued once and completes.
        try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, result.stop_reason);
        try std.testing.expect(elapsed >= @as(i64, @intCast(TUNING.floor_ms)));
        try std.testing.expect(elapsed < @as(i64, @intCast(BODY_MS)));
        try std.testing.expect(elapsed < BOUND_MS);
        // The successful retry's HTTP 200 cleared the stall's record.
        var buf: [cc.api_last_error.SUMMARY_BUF_LEN]u8 = undefined;
        try std.testing.expect(cc.api_last_error.take(&buf) == null);
    }
};

test "L2 dead connection ⑭: message_start then a dead connection → judged dead early → zero visible output → one same-turn retry → end_turn" {
    const a = std.testing.allocator;
    // Response 1 sends only message_start + content_block_start (what the incident received),
    // response 2 is the retry and answers normally.
    const bodies = [_][]const u8{ learnBody(.anthropic), quietBody(.anthropic), quietBody(.anthropic) };
    var srv = try harness.MockServer.startCassetteTrickleSilent(&bodies, TRICKLE_MS, 1, ANTHROPIC_START.len);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);
    try withClient(.anthropic, a, url, BODY_MS, IncidentShape.run);
    try std.testing.expectEqual(@as(usize, 3), srv.requestCount());
}
