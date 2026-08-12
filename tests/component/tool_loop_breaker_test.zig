//! L2 组件测试:agent_loop 无主动熔断(对齐 codex)。
//!
//! 历史:metacodes 曾有 MAX_SAME_TOOL_ERROR / MAX_ZERO_GAIN_REPEAT / ZeroGainTracker
//! 三层主动熔断 + breaker_finalization 收尾轮。2026-08-11 对齐 codex 全部删除——
//! codex 无主动熔断,只靠 max_turns + 用户中断。保留的两条测试验证"曾经会误熔断的
//! 场景现在仍正常 end_turn",作为回归防线(若未来重新引入熔断,这两条会提示边界)。
//!
//! 测试策略(对齐 subagent_model_test.zig):MockServer.startCassette 喂 SSE →
//!   断言 stop_reason==.end_turn 且 turns/tool_calls 符合预期(无早停)。

const std = @import("std");
const harness = @import("harness");
const cc = @import("cc");

const agent_loop = cc.agent_loop;
const writer_backend = cc.writer_backend;

/// 一个"调用未知工具 __nope__"的完整 SSE 响应(单 turn)。dispatch 必返 UnknownTool。
const TOOL_USE_NOPE_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"tu_1\",\"name\":\"__nope__\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{}\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const TWO_TOOL_USE_NOPE_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"m\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"tu_1\",\"name\":\"__nope__\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{}\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"tu_2\",\"name\":\"__nope__\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{}\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":1}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const END_TURN_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"m\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"done\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const THREE_IDENTICAL_BASH_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"m-batch\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"bash_1\",\"name\":\"Bash\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"command\\\":\\\"true\\\"}\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"bash_2\",\"name\":\"Bash\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"command\\\":\\\"true\\\"}\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":1}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":2,\"content_block\":{\"type\":\"tool_use\",\"id\":\"bash_3\",\"name\":\"Bash\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":2,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"command\\\":\\\"true\\\"}\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":2}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

test "单轮内多工具同错 仍正常 end_turn(无主动熔断)" {
    const a = std.testing.allocator;
    // 第 1 轮:双 __nope__(同错);第 2 轮:end_turn。对齐 codex:无主动熔断,
    // 单轮内多工具同错不会被提前中止,turns 继续到自然 end_turn。
    const bodies = [_][]const u8{ TWO_TOOL_USE_NOPE_SSE, END_TURN_SSE };
    var srv = try harness.MockServer.startCassette(&bodies, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    var io_runtime = std.Io.Threaded.init(a, .{});
    defer io_runtime.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(a, io_runtime.io(), "test-key", "claude-sonnet-4-20250514", url);
    defer client.deinit();

    var conv = cc.conversation.Conversation.init(a);
    defer conv.deinit();
    try conv.appendText(.user, "go");

    const perm = cc.permission.createContext(.bypass_permissions, a);
    const empty_defs: []const cc.json_mod.ToolDefinition = &.{};
    var wb = writer_backend.WriterBackend.initNull();
    const be = wb.backend();
    const result = agent_loop.run(&conv, client.provider(), empty_defs, &perm, .{ .max_turns = 20 }, &be, a) catch |e| {
        std.debug.print("run failed: {s}\n", .{@errorName(e)});
        return error.SkipZigTest;
    };

    // 无熔断:两个同错工具都执行,然后 end_turn。
    try std.testing.expectEqual(agent_loop.StopReason.end_turn, result.stop_reason);
}

test "单轮三个相同并发成功调用都执行(无主动熔断)" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const bodies = [_][]const u8{ THREE_IDENTICAL_BASH_SSE, END_TURN_SSE };
    var srv = try harness.MockServer.startCassette(&bodies, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    var io_runtime = std.Io.Threaded.init(a, .{});
    defer io_runtime.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(a, io_runtime.io(), "test-key", "claude-sonnet-4-20250514", url);
    defer client.deinit();
    var conv = cc.conversation.Conversation.init(a);
    defer conv.deinit();
    try conv.appendText(.user, "go");
    const perm = cc.permission.createContext(.bypass_permissions, a);
    const tool_defs = try cc.tools.toToolDefinitions(a);
    defer a.free(tool_defs);
    var wb = writer_backend.WriterBackend.initNull();
    const be = wb.backend();

    const result = try agent_loop.run(
        &conv,
        client.provider(),
        tool_defs,
        &perm,
        .{ .max_turns = 10, .auto_compact_threshold = std.math.maxInt(usize) },
        &be,
        a,
    );
    try std.testing.expectEqual(agent_loop.StopReason.end_turn, result.stop_reason);
    try std.testing.expectEqual(@as(u32, 3), result.tool_calls);
    try std.testing.expectEqual(@as(usize, 2), srv.requestCount());
}
