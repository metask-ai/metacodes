//! L2 组件测试:headless --json NDJSON 输出格式 + 退出码(原零覆盖盲区)。
//!
//! emitJson 直写 fd 1 难捕获 → 抽出 buildResultLine(纯函数返字符串)+ exitCodeFor。
//! 验证 result 事件 NDJSON 是合法 JSON、字段完整(stop_reason/turns/tool_calls/
//! input_tokens/output_tokens/cost_usd/text)、退出码逻辑正确。

const std = @import("std");
const cc = @import("cc");

const headless = cc.repl_headless;
const RunResult = cc.agent_loop.RunResult;
const UsageTotals = cc.app_module.UsageTotals;

test "L2 headless --json: result 行字段完整 + 合法 JSON + text 转义" {
    const a = std.testing.allocator;
    const usage = UsageTotals{
        .input_tokens = 120,
        .output_tokens = 45,
        .cache_read_input_tokens = 80,
        .cache_creation_input_tokens = 20,
    };
    const result = RunResult{ .stop_reason = .end_turn, .turns = 3, .tool_calls = 2 };

    const line = try headless.buildResultLine(a, "hi \"there\"\nline2", result, &usage, "claude-sonnet-4-20250514");
    defer a.free(line);

    // 尾部换行(NDJSON)
    try std.testing.expect(std.mem.endsWith(u8, line, "}\n"));
    // 字段存在
    for ([_][]const u8{
        "\"type\":\"result\"",  "\"stop_reason\":\"end_turn\"",
        "\"turns\":3",          "\"tool_calls\":2",
        "\"input_tokens\":120", "\"output_tokens\":45",
        "\"cache_read_input_tokens\":80",
        "\"cache_creation_input_tokens\":20",
        "\"cost_usd\":",
    }) |needle| {
        try std.testing.expect(std.mem.indexOf(u8, line, needle) != null);
    }
    // 整行是合法 JSON(text 含引号/换行须被正确转义)
    const parsed = try std.json.parseFromSlice(std.json.Value, a, std.mem.trimEnd(u8, line, "\n"), .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    try std.testing.expectEqualStrings("hi \"there\"\nline2", obj.get("text").?.string);
    try std.testing.expectEqual(@as(i64, 3), obj.get("turns").?.integer);
}

test "L2 headless --json: stop_reason 各值都能序列化(含 tool_loop)" {
    const a = std.testing.allocator;
    const usage = UsageTotals{};
    for ([_]cc.agent_loop.StopReason{ .end_turn, .max_turns, .aborted, .api_error, .tool_error, .tool_loop }) |sr| {
        const line = try headless.buildResultLine(a, "", .{ .stop_reason = sr, .turns = 1, .tool_calls = 0 }, &usage, "m");
        defer a.free(line);
        const parsed = try std.json.parseFromSlice(std.json.Value, a, std.mem.trimEnd(u8, line, "\n"), .{});
        defer parsed.deinit();
        try std.testing.expectEqualStrings(@tagName(sr), parsed.value.object.get("stop_reason").?.string);
    }
}

test "L2 headless 退出码:受控停止含 tool_loop → 0,硬错误 → 1" {
    try std.testing.expectEqual(@as(u8, 0), headless.exitCodeFor(.end_turn));
    try std.testing.expectEqual(@as(u8, 0), headless.exitCodeFor(.max_turns));
    try std.testing.expectEqual(@as(u8, 0), headless.exitCodeFor(.budget));
    try std.testing.expectEqual(@as(u8, 0), headless.exitCodeFor(.tool_loop));
    try std.testing.expectEqual(@as(u8, 1), headless.exitCodeFor(.tool_error));
    try std.testing.expectEqual(@as(u8, 1), headless.exitCodeFor(.aborted));
    try std.testing.expectEqual(@as(u8, 1), headless.exitCodeFor(.api_error));
}

test "L2 headless breaker fallback:跳过只有 tool_use 的尾消息" {
    const a = std.testing.allocator;
    var conv = cc.conversation.Conversation.init(a);
    defer conv.deinit();
    try conv.appendText(.assistant, "work completed before breaker");
    const blocks = try a.alloc(cc.message.Block, 1);
    blocks[0] = .{ .tool_use = .{
        .id = try a.dupe(u8, "tu-final"),
        .name = try a.dupe(u8, "Read"),
        .input = try a.dupe(u8, "{}"),
    } };
    try conv.append(.{ .role = .assistant, .blocks = blocks });

    const text = try headless.lastAssistantText(&conv, a);
    defer a.free(text);
    try std.testing.expectEqualStrings("work completed before breaker", text);
}
