//! L2 组件测试:Stage(功能补缺)— subagent/agent_loop 工具错误熔断器。
//!
//! 背景(doc/E2E_FRAMEWORK_DESIGN.md §8 后记 "未做" 项):
//!   MiniMax 端点常对 Task/TaskCreate 反复发空参 {} → 触发同一 MissingField 错误,
//!   从 ~46 turn 烧到 max_turns=50 才停。原先 agent_loop 只有 max_turns 粗保护。
//!
//! 本轮补:同一工具连续返回同样错误码达 MAX_SAME_TOOL_ERROR(3)次 → 熔断,
//!   再借一个无工具采样轮收尾，stop_reason=.tool_loop。任意工具成功 / 换工具 /
//!   换错误码 → 重置。
//!
//! 测试策略(对齐 subagent_model_test.zig):MockServer.startCassette 喂 N 个"调用未知
//!   工具"的 tool_use 响应 → dispatch 每轮返回 error.UnknownTool(同签名) → 第 3 轮熔断。
//!   断言:stop_reason==.tool_loop 且 turns==MAX_SAME_TOOL_ERROR(证明早停,非烧到 max_turns)。

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

// 旧 SilentWriter 已由 WriterBackend null-sink 取代(见各 test)。

test "L2 熔断器: 同工具同错 3 轮后仅借一轮无工具收尾" {
    const a = std.testing.allocator;

    // 三个同错轮后必须只再请求一个无工具收尾轮。
    const bodies = [_][]const u8{
        TOOL_USE_NOPE_SSE, TOOL_USE_NOPE_SSE, TOOL_USE_NOPE_SSE,
        BREAKER_FINAL_SSE,
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

    var wb = writer_backend.WriterBackend.initNull();
    const be = wb.backend();
    const result = agent_loop.run(
        &conv,
        client.provider(),
        empty_defs,
        &perm,
        .{ .max_turns = agent_loop.MAX_SAME_TOOL_ERROR }, // 收尾必须借到帽外第 1 轮
        &be,
        a,
    ) catch |e| {
        std.debug.print("agent_loop.run failed: {s}\n", .{@errorName(e)});
        return error.SkipZigTest;
    };

    try std.testing.expectEqual(agent_loop.StopReason.tool_loop, result.stop_reason);
    try std.testing.expectEqual(@as(u32, agent_loop.MAX_SAME_TOOL_ERROR + 1), result.turns);
    try std.testing.expectEqual(@as(u32, agent_loop.MAX_SAME_TOOL_ERROR), result.tool_calls);
    try std.testing.expectEqual(@as(usize, agent_loop.MAX_SAME_TOOL_ERROR + 1), srv.requestCount());
    const final_request = srv.lastRequest() orelse return error.NoRequestCaptured;
    try std.testing.expect(final_request.jsonField("tools") == null);
    try std.testing.expect(std.mem.indexOf(u8, final_request.body(), "loop-breaker") != null);
    const final_text = try cc.repl_headless.lastAssistantText(&conv, a);
    defer a.free(final_text);
    try std.testing.expectEqualStrings("finalized from existing evidence", final_text);
    const result_line = try cc.repl_headless.buildResultLine(
        a,
        final_text,
        result,
        &cc.app_module.UsageTotals{},
        "fixture-model",
    );
    defer a.free(result_line);
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        a,
        std.mem.trimEnd(u8, result_line, "\n"),
        .{},
    );
    defer parsed.deinit();
    try std.testing.expectEqualStrings(
        "finalized from existing evidence",
        parsed.value.object.get("text").?.string,
    );
    try std.testing.expectEqual(@as(u8, 0), cc.repl_headless.exitCodeFor(result.stop_reason));
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

const BREAKER_FINAL_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"m-final\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"finalized from existing evidence\"}}\n\n" ++
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

const CHANGING_TAIL_BASH_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"m-tail\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"bash_tail\",\"name\":\"Bash\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"command\\\":\\\"python3 -c 'import time;print(chr(120)*31000+str(time.time_ns()))'\\\"}\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const ONE_BASH_TRUE_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"m-one\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"bash_true\",\"name\":\"Bash\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"command\\\":\\\"true\\\"}\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const BASH_TRUE_WITH_PROGRESS_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"m-progress\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"bash_repeat\",\"name\":\"Bash\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"command\\\":\\\"true\\\"}\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"bash_progress\",\"name\":\"Bash\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"command\\\":\\\"printf progress\\\"}\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":1}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
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
    var wb = writer_backend.WriterBackend.initNull();
    const be = wb.backend();
    const result = agent_loop.run(&conv, client.provider(), empty_defs, &perm, .{ .max_turns = 20 }, &be, a) catch |e| {
        std.debug.print("run failed: {s}\n", .{@errorName(e)});
        return error.SkipZigTest;
    };

    // 不应熔断:单轮 2 个同错只算 1 个"同错轮",未达 MAX_SAME_TOOL_ERROR=3。
    try std.testing.expect(result.stop_reason != .tool_loop);
    try std.testing.expectEqual(agent_loop.StopReason.end_turn, result.stop_reason);
}

test "L2 零增益熔断: 单轮三个相同并发成功调用只计一次" {
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

test "L2 零增益熔断: 30KB 以后变化的 Bash 输出不碰撞" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const bodies = [_][]const u8{
        CHANGING_TAIL_BASH_SSE,
        CHANGING_TAIL_BASH_SSE,
        CHANGING_TAIL_BASH_SSE,
        END_TURN_SSE,
    };
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
    try std.testing.expectEqual(@as(usize, 4), srv.requestCount());
    try std.testing.expectEqual(@as(u32, 3), result.tool_calls);
}

test "L2 零增益熔断: 同轮新的成功动作重置旧重复窗口" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const bodies = [_][]const u8{
        ONE_BASH_TRUE_SSE,
        ONE_BASH_TRUE_SSE,
        BASH_TRUE_WITH_PROGRESS_SSE,
        ONE_BASH_TRUE_SSE,
        END_TURN_SSE,
    };
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
    try std.testing.expectEqual(@as(usize, 5), srv.requestCount());
    try std.testing.expectEqual(@as(u32, 5), result.tool_calls);
}
