//! L2 回归(review round 1 / D1):**遗留(无 dispatcher)分支的权限分类必须看
//! 将被执行的真名**。
//!
//! 缺陷形态:CLI 真实 run 无 tool_dispatcher;弱模型发小写 "bash" → 旧分类按原始名
//! 走 unknown→.read 兜底 → plan 模式 allow;随后 executeOne 的 P0.6 归一化把
//! "bash"→"Bash" **真执行**——分类与执行看的不是同一个名字,plan(只读探索)被穿透。
//! 修复:分类/规则匹配前用同一把 resolveToolNameExact 归一化;真未知名保持遗留
//! read 兜底 + dispatch UnknownTool。
//!
//! 跨模块:agent_loop 分类点 + tools.resolveToolNameExact + permission 判定(≥3,合 L2)。

const std = @import("std");
const harness = @import("harness");
const cc = @import("cc");

/// 模型发**小写 bash** 的 tool_use(P0.6 会把它归一化到 Bash 真执行)。
const LOWERCASE_BASH_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_lc\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"tu_lc\",\"name\":\"bash\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"command\\\":\\\"echo PLAN_ESCAPE_MARKER\\\"}\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const FINAL_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_end\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"done\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const ToolResultCapture = struct {
    allocator: std.mem.Allocator,
    content: ?[]u8 = null,

    fn deinit(self: *ToolResultCapture) void {
        if (self.content) |bytes| self.allocator.free(bytes);
        self.* = undefined;
    }

    fn backend(self: *ToolResultCapture) cc.ui_backend.UiBackend {
        return .{ .ctx = @ptrCast(self), .emit = emit, .poll = poll };
    }

    fn emit(raw: *anyopaque, _: cc.session_id.SessionId, event: cc.ui_event.CoreEvent) void {
        const self: *ToolResultCapture = @ptrCast(@alignCast(raw));
        switch (event) {
            .tool_result => |result| if (self.content == null) {
                self.content = self.allocator.dupe(u8, result.content) catch null;
            },
            else => {},
        }
    }

    fn poll(_: *anyopaque, _: cc.session_id.SessionId) ?cc.ui_event.UiEvent {
        return null;
    }
};

fn runLowercaseBash(mode: cc.types_mod.PermissionMode) !struct { content: []u8, allocator: std.mem.Allocator } {
    const a = std.testing.allocator;
    const responses = [_][]const u8{ LOWERCASE_BASH_SSE, FINAL_SSE };
    var server = try harness.MockServer.startCassette(&responses, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);

    var io_runtime = std.Io.Threaded.init(a, .{});
    defer io_runtime.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(a, io_runtime.io(), "test-key", "claude-sonnet-4-20250514", url);
    defer client.deinit();
    var conversation = cc.conversation.Conversation.init(a);
    defer conversation.deinit();
    try conversation.appendText(.user, "run the lowercase tool");

    var permission = cc.permission.createContext(mode, a);
    permission.no_interactive_prompt = true; // 无 UI 的 ask 必须 fail-closed,不读 fd 0
    var capture = ToolResultCapture{ .allocator = a };
    errdefer capture.deinit();
    const backend = capture.backend();
    // 关键:**不传 tool_dispatcher / dyn_registry** —— 走遗留分支(CLI 形态)。
    const result = try cc.agent_loop.run(
        &conversation,
        client.provider(),
        &.{},
        &permission,
        .{ .max_turns = 4, .emit_tool_cards = true, .colorize = false },
        &backend,
        a,
    );
    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, result.stop_reason);
    const content = capture.content orelse return error.MissingToolResult;
    capture.content = null;
    return .{ .content = content, .allocator = a };
}

test "L2 D1回归: 遗留分支小写 bash 在 plan 模式被 deny(不再经 read 兜底穿透执行)" {
    var run = try runLowercaseBash(.plan);
    defer run.allocator.free(run.content);
    // 分类看归一化真名 Bash → .execute → plan deny。旧缺陷:按 "bash" 归 .read →
    // allow → P0.6 归一化后真执行(tool_result 会含 echo 的 PLAN_ESCAPE_MARKER)。
    try std.testing.expect(std.mem.indexOf(u8, run.content, "permission_denied") != null);
    try std.testing.expect(std.mem.indexOf(u8, run.content, "PLAN_ESCAPE_MARKER") == null);
}

test "L2 D1回归: 真未知名(typo)保持遗留 read 兜底 → plan 下仍 UnknownTool 引导" {
    // 归一化解析不中的名字不改行为:分类仍 read 兜底,dispatch UnknownTool 供模型自纠。
    const a = std.testing.allocator;
    const TYPO_SSE =
        "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_ty\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
        "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"tu_ty\",\"name\":\"Basj\",\"input\":{}}}\n\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{}\"}}\n\n" ++
        "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
        "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
        "data: {\"type\":\"message_stop\"}\n\n";
    const responses = [_][]const u8{ TYPO_SSE, FINAL_SSE };
    var server = try harness.MockServer.startCassette(&responses, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);
    var io_runtime = std.Io.Threaded.init(a, .{});
    defer io_runtime.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(a, io_runtime.io(), "test-key", "claude-sonnet-4-20250514", url);
    defer client.deinit();
    var conversation = cc.conversation.Conversation.init(a);
    defer conversation.deinit();
    try conversation.appendText(.user, "call the typo tool");
    var permission = cc.permission.createContext(.plan, a);
    permission.no_interactive_prompt = true;
    var capture = ToolResultCapture{ .allocator = a };
    errdefer capture.deinit();
    const backend = capture.backend();
    const result = try cc.agent_loop.run(
        &conversation,
        client.provider(),
        &.{},
        &permission,
        .{ .max_turns = 4, .emit_tool_cards = true, .colorize = false },
        &backend,
        a,
    );
    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, result.stop_reason);
    const content = capture.content orelse return error.MissingToolResult;
    defer a.free(content);
    capture.content = null;
    try std.testing.expect(std.mem.indexOf(u8, content, "does not exist") != null);
}
