//! L2:流式请求网络瞬态错误重试(复刻 CC withRetry)。
//!
//! 覆盖(DoD):
//!   ① TransientNetwork 分类:receiveHead 断连 → error.TransientNetwork(不塌缩 RequestFailed)
//!   ② 建连重试成功:startFlaky(1) 断一次,重试包装第 2 连接成功拿到完整流
//!   ③ 退避公式:retryDelayMs(n) = min(base*2^(n-1),32000)+jitter
//!   ④ 不可重试不重试:401 → Unauthorized 立即返回(0 重试)
//!   ⑤ 重试耗尽:永远断 → max_retries 次后返 TransientNetwork,不无限循环
//!   ⑥ Retry-After 响应头覆盖本地退避
//!   ⑦ TLS request-setup 具体错误穿透分类并被真实 retry wrapper 重试
//!
//! 测试策略:MockServer.startFlaky(断连模拟) + Client.initWithBaseUrl + 短退避(base_ms=1)。

const std = @import("std");
const harness = @import("harness");
const cc = @import("cc");

const OK_SSE =
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

fn mkClient(a: std.mem.Allocator, io: std.Io, url: []const u8) cc.client_mod.Client {
    return cc.client_mod.Client.initWithBaseUrl(a, io, "test-key", "claude-3-5-haiku-20241022", url);
}

// ① TransientNetwork 分类:receiveHead 断连 → error.TransientNetwork(不再塌缩 RequestFailed)。
test "L2: receiveHead 断连分类为 TransientNetwork(可重试,不塌缩)" {
    const a = std.testing.allocator;
    var srv = try harness.MockServer.startFlaky(OK_SSE, 99); // 永远断
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    var io_runtime = std.Io.Threaded.init(a, .{});
    defer io_runtime.deinit();
    var client = mkClient(a, io_runtime.io(), url);
    defer client.deinit();

    const empty: []const cc.types_mod.ApiMessage = &.{};
    const result = client.sendMessageStream(empty, null, null);
    try std.testing.expectError(error.TransientNetwork, result);
    // 回归守卫:TransientNetwork 必须被判为可重试。
    try std.testing.expect(cc.client_mod.isRetriableError(error.TransientNetwork));
    try std.testing.expect(cc.client_mod.isTransientNetworkError(error.HttpConnectionClosing));
}

// 回归:std.Io.Writer/Reader 把 broken-pipe 包装成通用 WriteFailed/ReadFailed,必须归瞬态。
// 病根:web 长驻 daemon 复用 std.http.Client 连接池,空闲后服务端关连接,首个 sendBody
// 返 WriteFailed;旧分类漏它 → "1 attempt" 放弃 → 用户见 api_error(headless 每次新进程无恙)。
test "L2: WriteFailed/ReadFailed 归瞬态可重试(失效 keep-alive 重连,不塌缩 api_error)" {
    try std.testing.expect(cc.client_mod.isTransientNetworkError(error.WriteFailed));
    try std.testing.expect(cc.client_mod.isTransientNetworkError(error.ReadFailed));
    try std.testing.expect(cc.client_mod.isRetriableError(error.WriteFailed));
    try std.testing.expect(cc.client_mod.isRetriableError(error.ReadFailed));
    // 反向守卫:真·非瞬态(如 Unauthorized)仍不可重试,别把修复扩大成"什么都重试"。
    try std.testing.expect(!cc.client_mod.isTransientNetworkError(error.Unauthorized));
}

// ② 建连重试成功:断一次,sendMessageStreamFullRetry 第 2 连接成功拿到完整流。
test "L2: 建连断一次 → 重试包装第2次成功(短退避)" {
    const a = std.testing.allocator;
    var srv = try harness.MockServer.startFlaky(OK_SSE, 1); // 第1连接断,第2成功
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    var io_runtime = std.Io.Threaded.init(a, .{});
    defer io_runtime.deinit();
    var client = mkClient(a, io_runtime.io(), url);
    defer client.deinit();

    const empty: []const cc.types_mod.ApiMessage = &.{};
    // max_retries=5, base_ms=1(短退避避免真 sleep), reporter=null。
    var resp = try client.sendMessageStreamFullRetry(empty, null, null, null, null, null, 5, 1, null);
    defer resp.deinit();
    // 拿到流且能 drain 到 message_stop(说明第 2 连接成功回了完整 SSE)。
    try drainStream(&resp);
    try std.testing.expect(resp.done);
}

test "L2 evaluation gate retries transient connect failure inside one semantic request" {
    const a = std.testing.allocator;
    var srv = try harness.MockServer.startFlaky(OK_SSE, 1);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    var io_runtime = std.Io.Threaded.init(a, .{});
    defer io_runtime.deinit();
    var client = mkClient(a, io_runtime.io(), url);
    defer client.deinit();

    const empty: []const cc.types_mod.ApiMessage = &.{};
    var response = try client.sendMessageStreamFullRetry(
        empty,
        null,
        null,
        null,
        null,
        null,
        cc.agent_loop.providerAttemptLimit(true),
        1,
        null,
    );
    defer response.deinit();
    try drainStream(&response);
    try std.testing.expectEqual(@as(usize, 2), srv.requestCount());
    try std.testing.expectEqual(
        cc.client_mod.defaultMaxRetries(),
        cc.agent_loop.providerAttemptLimit(false),
    );
}

// ③ 退避公式:min(base*2^(n-1),32000)+jitter(0~25%)。
test "L2: retryDelayMs 指数退避 + cap + jitter 范围" {
    const base: u64 = 500;
    // attempt 1: base*2^0 = 500;jitter 0~125。
    const d1 = cc.client_mod.retryDelayMs(1, base);
    try std.testing.expect(d1 >= 500 and d1 <= 625);
    // attempt 2: 1000;jitter 0~250。
    const d2 = cc.client_mod.retryDelayMs(2, base);
    try std.testing.expect(d2 >= 1000 and d2 <= 1250);
    // attempt 3: 2000。
    const d3 = cc.client_mod.retryDelayMs(3, base);
    try std.testing.expect(d3 >= 2000 and d3 <= 2500);
    // 大 attempt: cap 32000(+jitter ≤ 8000)。
    const dbig = cc.client_mod.retryDelayMs(20, base);
    try std.testing.expect(dbig >= 32000 and dbig <= 40000);
}

test "L2 #6: jitter sample 可注入且不同 sample 不再同步" {
    try std.testing.expectEqual(@as(u64, 500), cc.client_mod.retryDelayMsWithSample(1, 500, 0));
    try std.testing.expectEqual(@as(u64, 625), cc.client_mod.retryDelayMsWithSample(1, 500, 125));
    // 超大 base/attempt 必须饱和，不能 shift overflow。
    const capped = cc.client_mod.retryDelayMsWithSample(99, std.math.maxInt(u64), 8_000);
    try std.testing.expect(capped >= 32_000 and capped <= 40_000);
}

test "L2 #6: Retry-After delta/date 解析且恶意大值有上限" {
    try std.testing.expectEqual(@as(?u64, 2_000), cc.client_mod.parseRetryAfterMsAt(" 2 ", 0));
    try std.testing.expectEqual(@as(?u64, cc.client_mod.MAX_RETRY_AFTER_MS), cc.client_mod.parseRetryAfterMsAt("999999999999999999999", 0));
    try std.testing.expectEqual(@as(?u64, 1_000), cc.client_mod.parseRetryAfterMsAt("Sun, 06 Nov 1994 08:49:37 GMT", 784_111_776));
    try std.testing.expectEqual(@as(?u64, 0), cc.client_mod.parseRetryAfterMsAt("Sun, 06 Nov 1994 08:49:37 GMT", 784_111_777));
    try std.testing.expect(cc.client_mod.parseRetryAfterMsAt("not-a-delay", 0) == null);
}

test "L2 #6: 429 Retry-After header 覆盖本地退避并进入第二次请求" {
    const a = std.testing.allocator;
    var srv = try harness.MockServer.startRepeatingStatus(
        "{\"error\":{\"type\":\"rate_limit_error\",\"message\":\"slow down\"}}",
        "HTTP/1.1 429 Too Many Requests",
        "Retry-After: 0\r\n",
    );
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    var io_runtime = std.Io.Threaded.init(a, .{});
    defer io_runtime.deinit();
    var client = mkClient(a, io_runtime.io(), url);
    defer client.deinit();

    const Report = struct {
        calls: u32 = 0,
        delay_ms: u64 = std.math.maxInt(u64),
        fn report(raw: *anyopaque, _: u32, _: u32, delay_ms: u64) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.calls += 1;
            self.delay_ms = delay_ms;
        }
    };
    var report = Report{};
    const reporter = cc.client_mod.RetryReporter{ .state = @ptrCast(&report), .report = Report.report };
    const empty: []const cc.types_mod.ApiMessage = &.{};
    const result = client.sendMessageStreamFullRetry(empty, null, null, null, null, null, 2, 500, reporter);
    try std.testing.expectError(error.RateLimited, result);
    try std.testing.expectEqual(@as(u32, 1), report.calls);
    try std.testing.expectEqual(@as(u64, 0), report.delay_ms);
    try std.testing.expectEqual(@as(usize, 2), srv.requestCount());
}

test "L2 #7: injected TLS setup failure is retried before a successful real request" {
    const a = std.testing.allocator;
    var srv = try harness.MockServer.start(OK_SSE, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    var io_runtime = std.Io.Threaded.init(a, .{});
    defer io_runtime.deinit();
    var client = mkClient(a, io_runtime.io(), url);
    defer client.deinit();
    var injector = cc.client_mod.RequestSetupFailureInjector{
        .remaining = 1,
        .failure = error.TlsInitializationFailed,
    };
    client.request_setup_failure_injector = &injector;

    try std.testing.expect(cc.client_mod.isTransientNetworkError(error.TlsInitializationFailed));
    const empty: []const cc.types_mod.ApiMessage = &.{};
    var resp = try client.sendMessageStreamFullRetry(empty, null, null, null, null, null, 3, 1, null);
    defer resp.deinit();
    try drainStream(&resp);
    try std.testing.expect(resp.done);
    try std.testing.expectEqual(@as(u32, 0), injector.remaining);
    try std.testing.expectEqual(@as(usize, 1), srv.requestCount());
}

test "L2 #7: persistent TLS setup failure preserves concrete error and stops at bound" {
    const a = std.testing.allocator;
    var srv = try harness.MockServer.start(OK_SSE, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    var io_runtime = std.Io.Threaded.init(a, .{});
    defer io_runtime.deinit();
    var client = mkClient(a, io_runtime.io(), url);
    defer client.deinit();
    var injector = cc.client_mod.RequestSetupFailureInjector{
        .remaining = 99,
        .failure = error.TlsInitializationFailed,
    };
    client.request_setup_failure_injector = &injector;

    const empty: []const cc.types_mod.ApiMessage = &.{};
    // Generic policy allows 10, but TLS setup has a dedicated safety cap of 3 attempts.
    const result = client.sendMessageStreamFullRetry(empty, null, null, null, null, null, 10, 1, null);
    try std.testing.expectError(error.TlsInitializationFailed, result);
    try std.testing.expectEqual(@as(u32, 96), injector.remaining); // exactly three attempts
    try std.testing.expectEqual(@as(usize, 0), srv.requestCount()); // failed before network I/O
}

// ④ 不可重试不重试:401 → Unauthorized 立即返回(retry 包装不重试 4xx)。
test "L2: 401 不可重试 → 立即 Unauthorized(重试包装不吞)" {
    const a = std.testing.allocator;
    var srv = try harness.MockServer.startWithStatus(
        "{\"error\":{\"type\":\"authentication_error\",\"message\":\"bad key\"}}",
        0,
        "HTTP/1.1 401 Unauthorized",
    );
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    var io_runtime = std.Io.Threaded.init(a, .{});
    defer io_runtime.deinit();
    var client = mkClient(a, io_runtime.io(), url);
    defer client.deinit();

    const empty: []const cc.types_mod.ApiMessage = &.{};
    // 401 不在可重试集 → 重试包装应立即返回 Unauthorized(不重试)。
    const result = client.sendMessageStreamFullRetry(empty, null, null, null, null, null, 5, 1, null);
    try std.testing.expectError(error.Unauthorized, result);
    try std.testing.expect(!cc.client_mod.isRetriableError(error.Unauthorized));
}

// ⑤ 重试耗尽:永远断 → max_retries 次后返 TransientNetwork,不无限循环。
test "L2: 永远断 → max_retries 后返 TransientNetwork(不无限循环)" {
    const a = std.testing.allocator;
    var srv = try harness.MockServer.startFlaky(OK_SSE, 99); // 永远断
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    var io_runtime = std.Io.Threaded.init(a, .{});
    defer io_runtime.deinit();
    var client = mkClient(a, io_runtime.io(), url);
    defer client.deinit();

    const empty: []const cc.types_mod.ApiMessage = &.{};
    // max_retries=3, base_ms=1。3 次全断 → 返回最后一次的 TransientNetwork。
    const result = client.sendMessageStreamFullRetry(empty, null, null, null, null, null, 3, 1, null);
    try std.testing.expectError(error.TransientNetwork, result);
}

// 退避边界:attempt=1 不下溢(attempt-|1=0,shift=0)。
test "L2: retryDelayMs attempt=1 不下溢" {
    const d = cc.client_mod.retryDelayMs(1, 500);
    try std.testing.expect(d >= 500);
}
