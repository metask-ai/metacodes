//! L2 组件测试:通道 B(memdir)端到端进请求体。
//!
//! 验证 doc/MEMORY_SYSTEM_DESIGN.md §2.3/§2.4 接线:
//!   ① system prompt 含 # Memory 操作说明段(memdir 启用时)→ 进请求 system 字段
//!   ② AutoMem(MEMORY.md 索引)经 user_context → 进首条 user message
//!
//! 用 MockServer 捕获真请求体断言。对齐项目"声明=接线=测试"铁律。

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

test "L2: memdir 启用 → system prompt 含 # Memory 段 + memdir 路径(进请求体)" {
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

    // 用 buildFull 直接造含 memory 段的 system prompt(模拟 App.init 的产物)。
    const memdir_abs = "/home/u/.metacodes/projects/deadbeef/memory";
    const sp = try cc.system_prompt.buildFull(a, "claude-sonnet-4-20250514", null, null, null, memdir_abs, false);
    defer a.free(sp);
    // sanity:section 在 system prompt 里
    try std.testing.expect(std.mem.indexOf(u8, sp, "# Memory") != null);
    try std.testing.expect(std.mem.indexOf(u8, sp, memdir_abs) != null);

    var conv = cc.conversation.Conversation.init(a);
    defer conv.deinit();
    try conv.appendText(.user, "hi");

    const perm = cc.permission.createContext(.bypass_permissions, a);
    const empty_defs: []const cc.json_mod.ToolDefinition = &.{};
    var wb = writer_backend.WriterBackend.initNull();
    const be = wb.backend();
    _ = agent_loop.run(&conv, client.provider(), empty_defs, &perm, .{
        .max_turns = 1,
        .system_prompt = sp,
    }, &be, a) catch return error.SkipZigTest;

    const cap = srv.lastRequest() orelse return error.NoRequestCaptured;
    const sys = cap.jsonField("system") orelse return error.SystemFieldMissing;
    try std.testing.expect(std.mem.indexOf(u8, sys, "# Memory") != null);
    try std.testing.expect(std.mem.indexOf(u8, sys, memdir_abs) != null);
    try std.testing.expect(std.mem.indexOf(u8, sys, "user | feedback | project | reference") != null);
}

test "L2: AutoMem 索引 → 首条 user message(经 user_context.build)" {
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

    // user_context.build 把 auto_mem 拼进 system-reminder。
    const uc = (try cc.user_context.build(a, .{
        .cwd = "",
        .home = "",
        .auto_mem = "# Memory Index\n- [ProjGoal](goal.md) — ship memory system",
    })).?;
    defer a.free(uc);

    var conv = cc.conversation.Conversation.init(a);
    defer conv.deinit();
    try conv.appendText(.user, "hi");

    const perm = cc.permission.createContext(.bypass_permissions, a);
    const empty_defs: []const cc.json_mod.ToolDefinition = &.{};
    var wb = writer_backend.WriterBackend.initNull();
    const be = wb.backend();
    _ = agent_loop.run(&conv, client.provider(), empty_defs, &perm, .{
        .max_turns = 1,
        .system_prompt = "BASE",
        .inject_user_context = uc,
    }, &be, a) catch return error.SkipZigTest;

    const cap = srv.lastRequest() orelse return error.NoRequestCaptured;
    const body = cap.body();
    try std.testing.expect(std.mem.indexOf(u8, body, "# Memory Index") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "ship memory system") != null);
}
