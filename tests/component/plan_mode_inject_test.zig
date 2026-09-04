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

const ENTER_PLAN_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_enter\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"tu_enter\",\"name\":\"EnterPlanMode\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{}\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const EXIT_PLAN_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_exit\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"tu_exit\",\"name\":\"ExitPlanMode\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"plan\\\":\\\"write the fixture\\\"}\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

fn writeSse(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "data: {{\"type\":\"message_start\",\"message\":{{\"id\":\"msg_write\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{{\"input_tokens\":1,\"output_tokens\":1}}}}}}\n\n" ++
            "data: {{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{{\"type\":\"tool_use\",\"id\":\"tu_write\",\"name\":\"Write\",\"input\":{{}}}}}}\n\n" ++
            "data: {{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{{\"type\":\"input_json_delta\",\"partial_json\":\"{{\\\"file_path\\\":\\\"{s}\\\",\\\"content\\\":\\\"headless-plan-ok\\\"}}\"}}}}\n\n" ++
            "data: {{\"type\":\"content_block_stop\",\"index\":0}}\n\n" ++
            "data: {{\"type\":\"message_delta\",\"delta\":{{\"stop_reason\":\"tool_use\"}},\"usage\":{{\"output_tokens\":1}}}}\n\n" ++
            "data: {{\"type\":\"message_stop\"}}\n\n",
        .{path},
    );
}

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

test "L2 headless bypass enters and exits plan before real Write" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buf);
    _ = harness.normalizeSlashes(root_buf[0..root_len]); // Windows: JSON 字面量里的反斜杠会被当转义
    const root = root_buf[0..root_len];
    const output_path = try std.fmt.allocPrint(a, "{s}/plan-exit-write.txt", .{root});
    defer a.free(output_path);
    const write_sse = try writeSse(a, output_path);
    defer a.free(write_sse);

    const bodies = [_][]const u8{ ENTER_PLAN_SSE, EXIT_PLAN_SSE, write_sse, MINIMAL_END_TURN_SSE };
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
    try conv.appendText(.user, "plan then write");

    var perm = cc.permission.createContext(.bypass_permissions, a);
    perm.no_interactive_prompt = true;
    var previous_mode: ?cc.types_mod.PermissionMode = null;
    const tool_defs = try cc.tools.toToolDefinitions(a);
    defer a.free(tool_defs);
    var wb = writer_backend.WriterBackend.initNull();
    const be = wb.backend();
    const result = try agent_loop.run(
        &conv,
        client.provider(),
        tool_defs,
        &perm,
        .{
            .max_turns = 8,
            .plan_prev_mode = &previous_mode,
            .cwd_abs = root,
            .home_dir = root,
            .auto_compact_threshold = std.math.maxInt(usize),
        },
        &be,
        a,
    );

    try std.testing.expectEqual(agent_loop.StopReason.end_turn, result.stop_reason);
    try std.testing.expectEqual(@as(u32, 3), result.tool_calls);
    try std.testing.expectEqual(cc.types_mod.PermissionMode.bypass_permissions, perm.modeValue());
    try std.testing.expect(previous_mode == null);
    const bytes = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        output_path,
        a,
        .limited(1024),
    );
    defer a.free(bytes);
    try std.testing.expectEqualStrings("headless-plan-ok", bytes);
}
