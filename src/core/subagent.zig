//! Subagent：父 agent 启动的子 agent 实例。
//!
//! 设计：
//! - 独立 Conversation（起点为空 + system prompt）
//! - 共享：api_client、tool_defs、permission_ctx、abort
//! - 有自己的 max_turns 上限（默认 20，避免子 agent 失控）
//! - 返回：final text（assistant 最后的文本）+ stop_reason + tool_calls 次数
//!
//! 父 agent 通过一个内建 "Task" 工具调起 subagent（M6.2 暂不实现 Task tool——只
//! 提供 spawn API 供未来调用）。

const std = @import("std");
const client_mod = @import("../client.zig");
const json_mod = @import("../json.zig");
const permission_mod = @import("../permission.zig");
const agent_loop = @import("agent_loop.zig");
const Conversation = @import("conversation.zig").Conversation;
const msg = @import("message.zig");
const AbortSignal = @import("../util/abort.zig").AbortSignal;

pub const SubagentResult = struct {
    allocator: std.mem.Allocator,
    final_text: []u8, // owned
    stop_reason: agent_loop.StopReason,
    turns: u32,
    tool_calls: u32,

    pub fn deinit(self: SubagentResult) void {
        self.allocator.free(self.final_text);
    }
};

pub const SpawnOptions = struct {
    max_turns: u32 = 20,
    system_prompt: ?[]const u8 = null,
    /// 嵌套深度。Agent 工具 spawn 时传 parent_depth+1。
    agent_depth: u8 = 1,
    /// 父 agent 的 dyn_registry，子 agent 共享同一套 Skill/MCP 工具。
    dyn_registry: ?*const @import("../tools/dynamic.zig").DynRegistry = null,
};

pub fn spawnAgent(
    allocator: std.mem.Allocator,
    api_client: *client_mod.Client,
    tool_defs: []const json_mod.ToolDefinition,
    permission_ctx: *const permission_mod.PermissionContext,
    abort: ?*const AbortSignal,
    prompt: []const u8,
    opts: SpawnOptions,
) !SubagentResult {
    var conv = Conversation.init(allocator);
    defer conv.deinit();

    try conv.appendText(.user, prompt);

    var sink = NullWriter{};
    const result = try agent_loop.run(
        &conv,
        api_client,
        tool_defs,
        permission_ctx,
        .{
            .max_turns = opts.max_turns,
            .system_prompt = opts.system_prompt,
            .abort = abort,
            .api_client = api_client,
            .tool_defs = tool_defs,
            .agent_depth = opts.agent_depth,
            .dyn_registry = opts.dyn_registry,
        },
        &sink,
        allocator,
    );

    // 提取最后一条 assistant 消息的 text block 拼接
    var final = std.ArrayList(u8).empty;
    errdefer final.deinit(allocator);

    for (conv.messages.items) |m| {
        if (m.role != .assistant) continue;
        for (m.blocks) |b| switch (b) {
            .text => |t| try final.appendSlice(allocator, t),
            else => {},
        };
    }

    return .{
        .allocator = allocator,
        .final_text = try final.toOwnedSlice(allocator),
        .stop_reason = result.stop_reason,
        .turns = result.turns,
        .tool_calls = result.tool_calls,
    };
}

/// 忽略所有输出的 writer——subagent 的 text 不应进入父 stdout。
const NullWriter = struct {
    pub fn print(_: *@This(), comptime fmt: []const u8, args: anytype) !void {
        _ = fmt;
        _ = args;
    }
};

// ============================================================================
// Tests（纯签名/接口测试——真 API 调用需要集成）
// ============================================================================

const testing = std.testing;

test "SubagentResult roundtrip allocation" {
    const r = SubagentResult{
        .allocator = testing.allocator,
        .final_text = try testing.allocator.dupe(u8, "test"),
        .stop_reason = .end_turn,
        .turns = 1,
        .tool_calls = 0,
    };
    defer r.deinit();
    try testing.expectEqualStrings("test", r.final_text);
}

test "SpawnOptions defaults" {
    const o = SpawnOptions{};
    try testing.expect(o.max_turns == 20);
    try testing.expect(o.system_prompt == null);
}
