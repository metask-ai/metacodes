//! L2:流式请求网络瞬态错误重试(复刻 CC withRetry)。
//!
//! 覆盖(DoD):
//!   ① TransientNetwork 分类:receiveHead 断连 → error.TransientNetwork(不塌缩 RequestFailed)
//!   ② 建连重试成功:startFlaky(1) 断一次,重试包装第 2 连接成功拿到完整流
//!   ③ 退避公式:retryDelayMs(n) = min(base*2^(n-1),32000)+jitter
//!   ④ 不可重试不重试:401 → Unauthorized 立即返回(0 重试)
//!   ⑤ 重试耗尽:永远断 → max_retries 次后返 TransientNetwork,不无限循环
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
