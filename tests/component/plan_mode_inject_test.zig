//! L2:plan 模式每轮把 plan 指令注入 system prompt(对齐 mecode developer_instructions)。
//!
//! 背景:plan 协议指令(<proposed_plan> 格式等)曾只在 EnterPlanMode 返回的 tool_result 里
//! 下发一次 → 模型多轮后"忘了"格式。修法:agent_loop 发请求时若 mode==plan 就把指令追加到
//! system prompt。本测试用 MockServer 捕获真请求体,断言 system 字段含 plan 指令。

const std = @import("std");
const harness = @import("harness");
const cc = @import("cc");

const agent_loop = cc.agent_loop;
const writer_backend = cc.writer_backend;

const MINIMAL_END_TURN_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"ok\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

test "L2: plan 模式 → system prompt 含 plan 指令(每轮注入,根治多轮忘协议)" {
    const a = std.heap.page_allocator;
    var srv = try harness.MockServer.start(MINIMAL_END_TURN_SSE, 0);
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
    try conv.appendText(.user, "plan something");

    const perm = cc.permission.createContext(.plan, a);
    const empty_defs: []const cc.json_mod.ToolDefinition = &.{};
    var wb = writer_backend.WriterBackend.initNull();
    const be = wb.backend();
    _ = agent_loop.run(&conv, client.provider(), empty_defs, &perm, .{ .max_turns = 1, .system_prompt = "BASE_PROMPT_MARKER" }, &be, a) catch return error.SkipZigTest;

    const cap = srv.lastRequest() orelse return error.NoRequestCaptured;
    const sys = cap.jsonField("system") orelse return error.SystemFieldMissing;
    // 原 base prompt 仍在 + 追加了 plan 指令的关键串(<proposed_plan> + PLAN MODE)。
    try std.testing.expect(std.mem.indexOf(u8, sys, "BASE_PROMPT_MARKER") != null);
    try std.testing.expect(std.mem.indexOf(u8, sys, "proposed_plan") != null);
    try std.testing.expect(std.mem.indexOf(u8, sys, "PLAN MODE") != null);
}

test "L2: 非 plan 模式 → system prompt 不含 plan 指令(零开销)" {
    const a = std.heap.page_allocator;
    var srv = try harness.MockServer.start(MINIMAL_END_TURN_SSE, 0);
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
    try conv.appendText(.user, "do something");

    const perm = cc.permission.createContext(.bypass_permissions, a);
    const empty_defs: []const cc.json_mod.ToolDefinition = &.{};
    var wb = writer_backend.WriterBackend.initNull();
    const be = wb.backend();
    _ = agent_loop.run(&conv, client.provider(), empty_defs, &perm, .{ .max_turns = 1, .system_prompt = "BASE_ONLY" }, &be, a) catch return error.SkipZigTest;

    const cap = srv.lastRequest() orelse return error.NoRequestCaptured;
    const sys = cap.jsonField("system") orelse return error.SystemFieldMissing;
    try std.testing.expect(std.mem.indexOf(u8, sys, "BASE_ONLY") != null);
    try std.testing.expect(std.mem.indexOf(u8, sys, "proposed_plan") == null); // 不该注入
}
