//! L2 组件测试:Stage(功能补缺)— subagent/agent_loop 工具错误熔断器。
//!
//! 背景(doc/E2E_FRAMEWORK_DESIGN.md §8 后记 "未做" 项):
//!   MiniMax 端点常对 Task/TaskCreate 反复发空参 {} → 触发同一 MissingField 错误,
//!   从 ~46 turn 烧到 max_turns=50 才停。原先 agent_loop 只有 max_turns 粗保护。
//!
//! 本轮补:同一工具连续返回同样错误码达 MAX_SAME_TOOL_ERROR(3)次 → 熔断,
//!   stop_reason=.tool_loop,远早于 max_turns 停。任意工具成功 / 换工具 / 换错误码 → 重置。
//!
//! 测试策略(对齐 subagent_model_test.zig):MockServer.startCassette 喂 N 个"调用未知
//!   工具"的 tool_use 响应 → dispatch 每轮返回 error.UnknownTool(同签名) → 第 3 轮熔断。
//!   断言:stop_reason==.tool_loop 且 turns==MAX_SAME_TOOL_ERROR(证明早停,非烧到 max_turns)。

const std = @import("std");
const harness = @import("harness");
const cc = @import("cc");

const agent_loop = cc.agent_loop;

/// 一个"调用未知工具 __nope__"的完整 SSE 响应(单 turn)。dispatch 必返 UnknownTool。
const TOOL_USE_NOPE_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"tu_1\",\"name\":\"__nope__\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{}\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const SilentWriter = struct {
    pub fn print(_: *@This(), comptime fmt: []const u8, args: anytype) !void {
        _ = fmt;
        _ = args;
    }
};

test "L2 熔断器: 同工具同错连续 3 次 → stop_reason=.tool_loop 且 turns==3(不烧到 max_turns)" {
    const a = std.testing.allocator;

    // 6 个相同响应:若无熔断,循环会跑满 6 轮(或受 cassette 限制);有熔断应在第 3 轮停。
    const bodies = [_][]const u8{
        TOOL_USE_NOPE_SSE, TOOL_USE_NOPE_SSE, TOOL_USE_NOPE_SSE,
        TOOL_USE_NOPE_SSE, TOOL_USE_NOPE_SSE, TOOL_USE_NOPE_SSE,
    };
    var srv = try harness.MockServer.startCassette(&bodies, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    var io_runtime = std.Io.Threaded.init(a, .{});
    defer io_runtime.deinit();
    const io = io_runtime.io();

    var client = cc.client_mod.Client.initWithBaseUrl(a, io, "test-key", "claude-sonnet-4-20250514", url);
    defer client.deinit();

    var conv = cc.conversation.Conversation.init(a);
    defer conv.deinit();
    try conv.appendText(.user, "go");

    const perm = cc.permission.createContext(.bypass_permissions, a);
    const empty_defs: []const cc.json_mod.ToolDefinition = &.{};

    var writer = SilentWriter{};
    const result = agent_loop.run(
        &conv,
        &client,
        empty_defs,
        &perm,
        .{ .max_turns = 20 }, // 远高于 3:证明是熔断而非 max_turns 停的
        &writer,
        a,
    ) catch |e| {
        std.debug.print("agent_loop.run failed: {s}\n", .{@errorName(e)});
        return error.SkipZigTest;
    };

    try std.testing.expectEqual(agent_loop.StopReason.tool_loop, result.stop_reason);
    try std.testing.expectEqual(@as(u32, agent_loop.MAX_SAME_TOOL_ERROR), result.turns);
}

/// 单轮内 **两个** tool_use(都调 __nope__),同轮同错。回归:修复前内层循环会把
/// same_err_count 在一轮内累加,2 个还不够 3、3 个就误熔断;修复后单轮同错只算一轮,
/// 不应熔断。喂 1 个"双工具失败轮" + 1 个 end_turn 轮 → 应正常 end_turn 结束(turns=2)。
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

test "L2 熔断器回归: 单轮内多工具同错 不应熔断(turns 继续到 end_turn)" {
    const a = std.testing.allocator;
    // 第 1 轮:双 __nope__(同错);第 2 轮:end_turn。修复前 6d 内层累加会在第 1 轮把
    // count 推进(2 个不够 3,但若是 3 个就误熔断);修复后单轮同错只算 1 轮 → 不熔断。
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
    var writer = SilentWriter{};
    const result = agent_loop.run(&conv, &client, empty_defs, &perm, .{ .max_turns = 20 }, &writer, a) catch |e| {
        std.debug.print("run failed: {s}\n", .{@errorName(e)});
        return error.SkipZigTest;
    };

    // 不应熔断:单轮 2 个同错只算 1 个"同错轮",未达 MAX_SAME_TOOL_ERROR=3。
    try std.testing.expect(result.stop_reason != .tool_loop);
    try std.testing.expectEqual(agent_loop.StopReason.end_turn, result.stop_reason);
}
