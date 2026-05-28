//! Agent 工具：让父 agent spawn 一个子 agent 去做独立子任务。
//!
//! 场景：
//! - 主 agent 专注高层规划；把"搜索代码""跑测试并归纳"等子任务委托给 sub。
//! - Sub 有独立 Conversation（不污染父上下文），有自己的 max_turns 上限。
//! - Sub 共享 api_client + tool_defs + permission_ctx，所以能用到相同的工具集。
//!
//! 输入：
//! - prompt（必须）：给子 agent 的任务描述
//! - description（可选）：人类友好的单行任务标签（回显用）
//! - max_turns（可选，默认 20）：子 agent 最大轮次，防止失控
//!
//! 输出 JSON：
//! - { "final_text": "...", "stop_reason": "end_turn|max_turns|aborted", "turns": N, "tool_calls": M }
//!
//! 注意：本工具不"嵌套 spawn"——子 agent 可以再调 Agent 工具继续 spawn，但每级
//! 都独立计 max_turns，所以不会无限递归。

const std = @import("std");
const ToolContext = @import("context.zig").ToolContext;
const subagent = @import("../core/subagent.zig");
const util_json = @import("../util/json.zig");

/// 最深嵌套层数。parent=0, 孙=2；>= 这个值就拒绝 spawn。
/// 理由：子 agent 里的 Conversation + recursive agent_loop 都在 C 栈，
/// 无限递归会吃满默认 8MB 栈；3 层足够覆盖正常用例。
const MAX_AGENT_DEPTH: u8 = 3;

pub fn execute(ctx: *const ToolContext, args: []const u8) anyerror![]u8 {
    // Precondition: depth guard 要在任何依赖解包前——保证 test 可用"未初始化"的占位
    // api_client/tool_defs 触发它，不会误踩指针。
    if (ctx.agent_depth >= MAX_AGENT_DEPTH) return error.AgentDepthExceeded;

    const api_client = ctx.api_client orelse return error.AgentUnavailable;
    const tool_defs = ctx.tool_defs orelse return error.AgentUnavailable;
    const perm = ctx.permission_ctx orelse return error.AgentUnavailable;

    const prompt_raw = util_json.extractStringField(args, "prompt") orelse return error.MissingField;
    // unescape（处理 \n \"等）
    const prompt = try util_json.unescapeString(prompt_raw, ctx.allocator);
    defer ctx.allocator.free(prompt);

    const max_turns = parseUintField(args, "max_turns") orelse 20;

    const result = try subagent.spawnAgent(
        ctx.allocator,
        api_client,
        tool_defs,
        perm,
        ctx.abort,
        prompt,
        .{
            .max_turns = @intCast(max_turns),
            .agent_depth = ctx.agent_depth + 1,
            .dyn_registry = ctx.dyn_registry,
        },
    );
    defer result.deinit();

    // 组 JSON 输出
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(ctx.allocator);
    try out.appendSlice(ctx.allocator, "{\"final_text\":");
    try util_json.serializeString(result.final_text, &out, ctx.allocator);
    try out.appendSlice(ctx.allocator, ",\"stop_reason\":\"");
    try out.appendSlice(ctx.allocator, @tagName(result.stop_reason));
    const tail = try std.fmt.allocPrint(
        ctx.allocator,
        "\",\"turns\":{d},\"tool_calls\":{d}}}",
        .{ result.turns, result.tool_calls },
    );
    defer ctx.allocator.free(tail);
    try out.appendSlice(ctx.allocator, tail);
    return try out.toOwnedSlice(ctx.allocator);
}

fn parseUintField(data: []const u8, field: []const u8) ?u64 {
    var buf: [128]u8 = undefined;
    if (field.len > 100) return null;
    buf[0] = '"';
    @memcpy(buf[1..][0..field.len], field);
    buf[1 + field.len] = '"';
    buf[2 + field.len] = ':';
    const pat = buf[0 .. 3 + field.len];
    const idx = std.mem.indexOf(u8, data, pat) orelse return null;
    var p = idx + pat.len;
    while (p < data.len and (data[p] == ' ' or data[p] == '\t')) : (p += 1) {}
    var e = p;
    while (e < data.len and data[e] >= '0' and data[e] <= '9') : (e += 1) {}
    if (e == p) return null;
    return std.fmt.parseInt(u64, data[p..e], 10) catch null;
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "Agent without deps returns AgentUnavailable" {
    const ctx = ToolContext{ .allocator = testing.allocator };
    try testing.expectError(error.AgentUnavailable, execute(&ctx, "{\"prompt\":\"hi\"}"));
}

test "Agent depth guard rejects at MAX" {
    // depth check 是 precondition，先于任何指针解包执行——无需构造 fake deps。
    const ctx = ToolContext{
        .allocator = testing.allocator,
        .agent_depth = MAX_AGENT_DEPTH,
    };
    try testing.expectError(error.AgentDepthExceeded, execute(&ctx, "{\"prompt\":\"hi\"}"));
}

test "parseUintField extracts max_turns" {
    try testing.expect(parseUintField("{\"max_turns\":42}", "max_turns").? == 42);
    try testing.expect(parseUintField("{\"max_turns\": 7 }", "max_turns").? == 7);
    try testing.expect(parseUintField("{}", "max_turns") == null);
}
