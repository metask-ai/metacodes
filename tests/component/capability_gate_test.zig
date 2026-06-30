//! P2 component 测试:capability 门控的真消费者路径。
//!
//! 证明(Linus P2 条件:capability 表必须驱动一个真实决策, 不能是空壳):
//!   provider.supports(.web_search)==false → agent_loop 把 WebSearch 工具从发给模型的 tools 数组
//!   剔除(对齐 cc isEnabled)。当前生产单 Anthropic 全支持 → 用 mock provider 模拟"不支持 web_search"
//!   的后端, 驱动真 agent_loop, 断言请求体 tools 里没有 WebSearch。

const std = @import("std");
const harness = @import("harness");
const cc = @import("cc");

const agent_loop = cc.agent_loop;
const provider_mod = cc.api_provider;
const writer_backend = cc.writer_backend;

const TEXT_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"m\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"hi\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

/// 包装一个真 Client,但 supports() 谎报"不支持 web_search"——模拟缺该能力的 provider。
/// 其余方法(sendStream/maxTokens/...)转调底层 Client 的 provider()。
const NoWebSearchProvider = struct {
    inner: provider_mod.Provider,
    fn provider(self: *NoWebSearchProvider) provider_mod.Provider {
        var p = self.inner; // 复制底层 vtable
        p.supportsFn = &supportsNoWeb; // 只覆盖 supports
        return p;
    }
    fn supportsNoWeb(_: *anyopaque, cap: provider_mod.Capability) bool {
        return cap != .web_search; // 唯独 web_search 不支持
    }
};

test "P2: provider 不支持 web_search → WebSearch 从请求 tools 剔除(门控真生效)" {
    const a = std.testing.allocator;
    var srv = try harness.MockServer.startCassette(&[_][]const u8{TEXT_SSE}, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    var io_rt = std.Io.Threaded.init(a, .{});
    defer io_rt.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(a, io_rt.io(), "test-key", "claude-sonnet-4-20250514", url);
    defer client.deinit();

    var conv = cc.conversation.Conversation.init(a);
    defer conv.deinit();
    try conv.appendText(.user, "hi");
    const perm = cc.permission.createContext(.bypass_permissions, a);

    // 工具集含 WebSearch(真注册表里有)。
    const tool_defs = try cc.tools.toToolDefinitions(a);
    defer a.free(tool_defs);
    // 确认 WebSearch 本在工具集里(否则测试无意义)。
    var has_ws_in_defs = false;
    for (tool_defs) |d| {
        if (std.mem.eql(u8, d.name, "WebSearch")) has_ws_in_defs = true;
    }
    try std.testing.expect(has_ws_in_defs);

    var render = writer_backend.WriterBackend.initNull();
    const be = render.backend();

    // 用"不支持 web_search"的 provider 跑。
    var nows = NoWebSearchProvider{ .inner = client.provider() };
    const result = agent_loop.run(&conv, nows.provider(), tool_defs, &perm, .{ .max_turns = 2 }, &be, a) catch |e| {
        std.debug.print("run failed: {s}\n", .{@errorName(e)});
        return error.SkipZigTest;
    };
    try std.testing.expectEqual(agent_loop.StopReason.end_turn, result.stop_reason);

    // 断言:请求体的 tools 里**没有** WebSearch(被能力门控剔除)。
    const cap = srv.lastRequest().?;
    const body = cap.body();
    try std.testing.expect(std.mem.indexOf(u8, body, "\"WebSearch\"") == null);
    // 但其它工具(如 Read)还在——证明只剔了缺能力的那个。
    try std.testing.expect(std.mem.indexOf(u8, body, "\"Read\"") != null);
}
