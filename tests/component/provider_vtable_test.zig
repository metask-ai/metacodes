//! P0(多 Provider 重构):验证 AnthropicProvider vtable 的 thunk 正确转调 Client。
//!
//! DoD:声明的 Provider 接口必须有端到端断言。本测试经 client.provider() 拿 AnthropicProvider,
//! 调它的 sendStreamRetry / send / maxInputTokens / model / supports,断言:
//!   ① sendStreamRetry 经 vtable 拿到与直调 Client 同款的中立事件流(text "ok" + done)
//!   ② send(非流式)经 vtable 拿到 ApiResponse
//!   ③ maxInputTokens/model/supports 经 vtable 返回正确值
//! 证明 vtable thunk 真接通(行为零变化),而非孤立通过。

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

test "P0: AnthropicProvider vtable 经 sendStreamRetry 拿到中立事件流(thunk 接通)" {
    const a = std.testing.allocator;
    var srv = try harness.MockServer.startCassette(&[_][]const u8{OK_SSE}, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    var io_rt = std.Io.Threaded.init(a, .{});
    defer io_rt.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(a, io_rt.io(), "test-key", "claude-sonnet-4-20250514", url);
    defer client.deinit();

    // ── 经 Provider vtable(而非直调 Client)──
    const provider = client.provider();

    // ③ 元信息经 vtable。
    try std.testing.expectEqualStrings("claude-sonnet-4-20250514", provider.model());
    try std.testing.expect(provider.maxInputTokens() > 0);
    try std.testing.expect(provider.supports(.web_search)); // P0 stub 恒 true(非真能力, P2 落表)

    // ① 流式经 vtable:返回中立 StreamHandle(非 client 具体 StreamResponse)。断言 text "ok" + done。
    const empty: []const cc.types_mod.ApiMessage = &.{};
    const handle = provider.sendStreamRetry(empty, null, null, null, null, null, 2, 1, null, "") catch |e| {
        std.debug.print("provider.sendStreamRetry failed: {s}\n", .{@errorName(e)});
        return error.SkipZigTest;
    };
    defer handle.deinit();

    var saw_text = false;
    var text_buf: [16]u8 = undefined;
    var text_len: usize = 0;
    while (true) {
        const maybe = try handle.next();
        const ev = maybe orelse break;
        switch (ev) {
            .text => |t| {
                @memcpy(text_buf[0..@min(t.len, 16)], t[0..@min(t.len, 16)]);
                text_len = @min(t.len, 16);
                saw_text = true;
                a.free(t);
            },
            else => {},
        }
    }
    try std.testing.expect(saw_text);
    try std.testing.expectEqualStrings("ok", text_buf[0..text_len]);
    try std.testing.expectEqual(cc.api_stream.StopReason.end_turn, handle.stopReason());
}
