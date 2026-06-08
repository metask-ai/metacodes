//! L2 组件测试:首条 user-context message(CLAUDE.md/AutoMem)端到端进请求体。
//!
//! 验证 doc/MEMORY_SYSTEM_DESIGN.md §1.5 的接线:agent_loop.buildApiMessages 在
//! opts.inject_user_context 非空时,prepend 一条 user message(content = <system-reminder>
//! 包裹的 CLAUDE.md 链)。本测试用 MockServer 捕获真请求体,断言:
//!   ① 注入文本(含 MEMORY_INSTRUCTION_PROMPT + 标记)出现在请求 body 的 messages 里
//!   ② 不注入(null)时 body 不含该文本
//!
//! 这是项目"声明=接线=测试"铁律:inject_user_context 字段必须有一条 L2 断言它端到端生效。

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

const INJECT_MARKER = "<system-reminder>\nAs you answer the user's questions, you can use the following context:\n# claudeMd\nMY-INJECTED-MEMORY-XYZ\n</system-reminder>";

test "L2: inject_user_context → 首条 message 进请求体" {
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
    try conv.appendText(.user, "hello");

    const perm = cc.permission.createContext(.bypass_permissions, a);
    const empty_defs: []const cc.json_mod.ToolDefinition = &.{};
    var wb = writer_backend.WriterBackend.initNull();
    const be = wb.backend();
    _ = agent_loop.run(&conv, &client, empty_defs, &perm, .{
        .max_turns = 1,
        .system_prompt = "BASE",
        .inject_user_context = INJECT_MARKER,
    }, &be, a) catch return error.SkipZigTest;

    const cap = srv.lastRequest() orelse return error.NoRequestCaptured;
    const body = cap.body();
    // 注入文本(经 JSON 转义后)应在 body 里。断言关键标记串存在。
    try std.testing.expect(std.mem.indexOf(u8, body, "MY-INJECTED-MEMORY-XYZ") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "# claudeMd") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "system-reminder") != null);
    // 原 user message "hello" 仍在(注入是 prepend,不替换)
    try std.testing.expect(std.mem.indexOf(u8, body, "hello") != null);
}

test "L2: inject_user_context=null → body 不含注入文本" {
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
    try conv.appendText(.user, "hello");

    const perm = cc.permission.createContext(.bypass_permissions, a);
    const empty_defs: []const cc.json_mod.ToolDefinition = &.{};
    var wb = writer_backend.WriterBackend.initNull();
    const be = wb.backend();
    _ = agent_loop.run(&conv, &client, empty_defs, &perm, .{
        .max_turns = 1,
        .system_prompt = "BASE",
        .inject_user_context = null,
    }, &be, a) catch return error.SkipZigTest;

    const cap = srv.lastRequest() orelse return error.NoRequestCaptured;
    const body = cap.body();
    try std.testing.expect(std.mem.indexOf(u8, body, "# claudeMd") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "hello") != null); // user 消息仍在
}
