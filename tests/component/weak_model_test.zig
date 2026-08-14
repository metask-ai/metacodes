//! P0.6 弱模型健壮性层 端到端(L2)。用讲 OpenAI 协议的 MockServer 喂**畸形**工具调用,证明
//! agent_loop 的健壮性层真的在生产路径上生效(不是孤立单测):
//!  1. 幻觉/走样工具名 → resolveToolName 修复 → 真工具执行(不 UnknownTool)。
//!  2. 畸形 JSON 参数(trailing comma / markdown 围栏)→ repairToolArgs 修复 → 工具收到合法参数。
//!
//! 手法对齐 openai_provider_test:MockServer.startCassette 喂两轮(① tool_call ② final text),
//! 驱动同一个 agent_loop.run,再检查 conversation 里的 tool_use/tool_result。

const std = @import("std");
const harness = @import("harness");
const cc = @import("cc");

const agent_loop = cc.agent_loop;
const openai = cc.api_openai;
const writer_backend = cc.writer_backend;

const FINAL_SSE =
    "data: {\"choices\":[{\"delta\":{\"content\":\"done\"}}]}\n\n" ++
    "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n" ++
    "data: [DONE]\n\n";

// echo 工具:回显**实际执行**收到的 input(用来断言 repair 后的参数)。
fn echoExec(ctx: *const cc.tool_context.ToolContext, input: []const u8, _: ?*anyopaque) anyerror![]u8 {
    return ctx.allocator.dupe(u8, input);
}

// ── 1a. 确定性归一化工具名 → 自动改派真执行 ──────────────────────────────────
// 模型调 "echo-tool"(真名 "echo_tool" 的分隔符走样,无损归一化)→ resolveToolNameExact → 真执行。
const NORMALIZED_NAME_SSE =
    "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"c1\",\"type\":\"function\",\"function\":{\"name\":\"echo-tool\",\"arguments\":\"{}\"}}]}}]}\n\n" ++
    "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}]}\n\n" ++
    "data: [DONE]\n\n";

test "P0.6 e2e: 确定性归一化工具名(echo-tool→echo_tool)自动改派真执行" {
    const a = std.testing.allocator;
    var srv = try harness.MockServer.startCassette(&[_][]const u8{ NORMALIZED_NAME_SSE, FINAL_SSE }, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    var io_rt = std.Io.Threaded.init(a, .{});
    defer io_rt.deinit();
    var client = openai.OpenAIClient.init(a, io_rt.io(), "k", "gpt-4o", url);
    defer client.deinit();

    var dyn = cc.tools_dynamic.DynRegistry.init(a);
    defer dyn.deinit();
    try dyn.register("echo_tool", "Echo", &.{}, echoExec, null, false);

    var conv = cc.conversation.Conversation.init(a);
    defer conv.deinit();
    try conv.appendText(.user, "call echo");
    const perm = cc.permission.createContext(.bypass_permissions, a);
    const tool_defs = try cc.tools.toToolDefinitionsFull(a, &dyn, null);
    defer a.free(tool_defs);

    var render = writer_backend.WriterBackend.initNull();
    const be = render.backend();
    const result = agent_loop.run(&conv, client.provider(), tool_defs, &perm, .{ .max_turns = 4, .dyn_registry = &dyn }, &be, a) catch |e| {
        std.debug.print("run failed: {s}\n", .{@errorName(e)});
        return error.SkipZigTest;
    };
    try std.testing.expectEqual(agent_loop.StopReason.end_turn, result.stop_reason);

    // conversation 有 c1 的 tool_result,且**不是** UnknownTool 错误 → 归一化名被改派且真执行。
    var found_result = false;
    for (conv.messages.items) |m| for (m.blocks) |b| switch (b) {
        .tool_result => |tr| if (std.mem.eql(u8, tr.tool_use_id, "c1")) {
            found_result = true;
            try std.testing.expect(std.mem.indexOf(u8, tr.content, "unknown_tool") == null);
            try std.testing.expect(!tr.is_error); // echo 成功
        },
        else => {},
    };
    try std.testing.expect(found_result);
}

// ── 1b. 模糊近似工具名 → **不**自动执行,返 UnknownTool + "Did you mean X?" 建议 ────────────
// 模型调 "echo_tol"(typo,编辑距离建议 echo_tool)→ resolveToolNameExact 不中 → UnknownTool,
// 错误里带模糊建议供模型自纠,**绝不**静默路由到 echo_tool 真跑。
const FUZZY_NAME_SSE =
    "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"c1\",\"type\":\"function\",\"function\":{\"name\":\"echo_tol\",\"arguments\":\"{}\"}}]}}]}\n\n" ++
    "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}]}\n\n" ++
    "data: [DONE]\n\n";

test "P0.6 e2e: 模糊近似名不自动执行,返 UnknownTool + 建议(诚实报错留给模型自纠)" {
    const a = std.testing.allocator;
    var srv = try harness.MockServer.startCassette(&[_][]const u8{ FUZZY_NAME_SSE, FINAL_SSE }, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    var io_rt = std.Io.Threaded.init(a, .{});
    defer io_rt.deinit();
    var client = openai.OpenAIClient.init(a, io_rt.io(), "k", "gpt-4o", url);
    defer client.deinit();

    var dyn = cc.tools_dynamic.DynRegistry.init(a);
    defer dyn.deinit();
    try dyn.register("echo_tool", "Echo", &.{}, echoExec, null, false);

    var conv = cc.conversation.Conversation.init(a);
    defer conv.deinit();
    try conv.appendText(.user, "call echo");
    const perm = cc.permission.createContext(.bypass_permissions, a);
    const tool_defs = try cc.tools.toToolDefinitionsFull(a, &dyn, null);
    defer a.free(tool_defs);

    var render = writer_backend.WriterBackend.initNull();
    const be = render.backend();
    const result = agent_loop.run(&conv, client.provider(), tool_defs, &perm, .{ .max_turns = 4, .dyn_registry = &dyn }, &be, a) catch |e| {
        std.debug.print("run failed: {s}\n", .{@errorName(e)});
        return error.SkipZigTest;
    };
    try std.testing.expectEqual(agent_loop.StopReason.end_turn, result.stop_reason);

    // c1 的 tool_result 是 UnknownTool 错误,含 "Did you mean 'echo_tool'" 建议(未静默执行)。
    var found = false;
    for (conv.messages.items) |m| for (m.blocks) |b| switch (b) {
        .tool_result => |tr| if (std.mem.eql(u8, tr.tool_use_id, "c1")) {
            found = true;
            try std.testing.expect(tr.is_error);
            try std.testing.expect(std.mem.indexOf(u8, tr.content, "does not exist") != null);
            try std.testing.expect(std.mem.indexOf(u8, tr.content, "echo_tool") != null); // 建议名
        },
        else => {},
    };
    try std.testing.expect(found);
}

// ── 2. 畸形 JSON 参数修复 ──────────────────────────────────────────────────
// 走 Anthropic partial_json(累积干净,不受 OpenAI arg 提取转义 quirk 影响):
// partial_json = {"path":"a.txt",}(trailing comma)→ agent_loop repairToolArgs → {"path":"a.txt"}。
// echo 工具回显实际执行输入 → tool_result/tool_use 里都应是合法 JSON(无 ",}",内容没丢)。
const BAD_ARGS_ANTHROPIC_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"m\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"c2\",\"name\":\"echo_tool\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"path\\\":\\\"a.txt\\\",}\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const FINAL_ANTHROPIC_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"m2\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"done\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

// Exact malformed shape observed from a paid GLM-5.2 KgRecall: all fields are
// present, but one extra `}` appears before the variants array closes.
const GLM_BAD_NESTED_ARGS_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"m3\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":0,\"output_tokens\":0}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"c3\",\"name\":\"echo_tool\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"lexical_plan\\\":{\\\"intent\\\":\\\"fact_lookup\\\",\\\"schema_version\\\":\\\"lexical-query-plan-v2\\\",\\\"stage\\\":\\\"semantic_expansion\\\",\\\"variant_index\\\":0,\\\"variants\\\":[{\\\"kind\\\":\\\"synonym\\\",\\\"text\\\":\\\"commencement\\\"},{\\\"kind\\\":\\\"synonym\\\",\\\"text\\\":\\\"convocation\\\"}}]},\\\"query\\\":\\\"commencement\\\"}\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"input_tokens\":100,\"output_tokens\":10}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

test "P0.6 e2e: 畸形 JSON 参数(trailing comma)经修复,工具收到合法参数" {
    const a = std.testing.allocator;
    var srv = try harness.MockServer.startCassette(&[_][]const u8{ BAD_ARGS_ANTHROPIC_SSE, FINAL_ANTHROPIC_SSE }, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    var io_rt = std.Io.Threaded.init(a, .{});
    defer io_rt.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(a, io_rt.io(), "k", "claude-3-5-haiku-20241022", url);
    defer client.deinit();

    var dyn = cc.tools_dynamic.DynRegistry.init(a);
    defer dyn.deinit();
    try dyn.register("echo_tool", "Echo", &.{}, echoExec, null, false);

    var conv = cc.conversation.Conversation.init(a);
    defer conv.deinit();
    try conv.appendText(.user, "echo path");
    const perm = cc.permission.createContext(.bypass_permissions, a);
    const tool_defs = try cc.tools.toToolDefinitionsFull(a, &dyn, null);
    defer a.free(tool_defs);

    var render = writer_backend.WriterBackend.initNull();
    const be = render.backend();
    const result = agent_loop.run(&conv, client.provider(), tool_defs, &perm, .{ .max_turns = 4, .dyn_registry = &dyn }, &be, a) catch |e| {
        std.debug.print("run failed: {s}\n", .{@errorName(e)});
        return error.SkipZigTest;
    };
    try std.testing.expectEqual(agent_loop.StopReason.end_turn, result.stop_reason);

    var checked = false;
    for (conv.messages.items) |m| for (m.blocks) |b| switch (b) {
        // tool_use 存的 input 应已被修复成合法 JSON(无 trailing comma)。
        .tool_use => |tu| if (std.mem.eql(u8, tu.id, "c2")) {
            try std.testing.expect(cc.message_repair.isValidJson(tu.input));
            try std.testing.expect(std.mem.indexOf(u8, tu.input, ",}") == null);
            try std.testing.expect(std.mem.indexOf(u8, tu.input, "a.txt") != null); // 内容没丢
        },
        // echo 回显的执行输入也应是合法 JSON。
        .tool_result => |tr| if (std.mem.eql(u8, tr.tool_use_id, "c2")) {
            try std.testing.expect(cc.message_repair.isValidJson(tr.content));
            checked = true;
        },
        else => {},
    };
    try std.testing.expect(checked);
}

test "P0.6 e2e: GLM extra nested closer preserves complete tool input" {
    const a = std.testing.allocator;
    var srv = try harness.MockServer.startCassette(&[_][]const u8{ GLM_BAD_NESTED_ARGS_SSE, FINAL_ANTHROPIC_SSE }, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    var io_rt = std.Io.Threaded.init(a, .{});
    defer io_rt.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(a, io_rt.io(), "k", "glm-5.2", url);
    defer client.deinit();
    var dyn = cc.tools_dynamic.DynRegistry.init(a);
    defer dyn.deinit();
    try dyn.register("echo_tool", "Echo", &.{}, echoExec, null, false);

    var conv = cc.conversation.Conversation.init(a);
    defer conv.deinit();
    try conv.appendText(.user, "echo lexical plan");
    const perm = cc.permission.createContext(.bypass_permissions, a);
    const tool_defs = try cc.tools.toToolDefinitionsFull(a, &dyn, null);
    defer a.free(tool_defs);
    var render = writer_backend.WriterBackend.initNull();
    const be = render.backend();
    const result = try agent_loop.run(&conv, client.provider(), tool_defs, &perm, .{ .max_turns = 4, .dyn_registry = &dyn }, &be, a);
    try std.testing.expectEqual(agent_loop.StopReason.end_turn, result.stop_reason);

    var saw_use = false;
    var saw_result = false;
    for (conv.messages.items) |m| for (m.blocks) |b| switch (b) {
        .tool_use => |tu| if (std.mem.eql(u8, tu.id, "c3")) {
            saw_use = true;
            try std.testing.expect(cc.message_repair.isValidJson(tu.input));
            try std.testing.expect(std.mem.indexOf(u8, tu.input, "commencement") != null);
            try std.testing.expect(std.mem.indexOf(u8, tu.input, "convocation") != null);
            try std.testing.expect(!std.mem.eql(u8, tu.input, "{}"));
        },
        .tool_result => |tr| if (std.mem.eql(u8, tr.tool_use_id, "c3")) {
            saw_result = true;
            try std.testing.expect(!tr.is_error);
            try std.testing.expect(cc.message_repair.isValidJson(tr.content));
        },
        else => {},
    };
    try std.testing.expect(saw_use and saw_result);
}

// ── 3. 消息序列规范化在**真请求体**里生效(证明 normalizeApiMessages 跑在生产路径) ──────
// normalizeApiMessages 只作用于 buildApiMessages 内的 ephemeral api_messages(永不进 conversation),
// 故必须查 srv.lastRequest().body() 才能证明它生效——conversation 断言看不到它。
// 预置一个含**孤儿 tool_result**(无对应 tool_use)的对话,跑一轮,断言发出的请求体已剥掉孤儿。
fn orphanUserMessage(a: std.mem.Allocator, ghost_id: []const u8) !cc.message.Message {
    const blocks = try a.alloc(cc.message.Block, 1);
    blocks[0] = .{ .tool_result = .{
        .tool_use_id = try a.dupe(u8, ghost_id),
        .content = try a.dupe(u8, "ORPHAN_MARKER_CONTENT"),
        .is_error = false,
    } };
    return cc.message.Message{ .role = .user, .blocks = blocks };
}

test "P0.6 e2e: 孤儿 tool_result 在发出的请求体里被剥离(normalize 跑在生产路径)" {
    const a = std.testing.allocator;
    var srv = try harness.MockServer.startCassette(&[_][]const u8{FINAL_ANTHROPIC_SSE}, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    var io_rt = std.Io.Threaded.init(a, .{});
    defer io_rt.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(a, io_rt.io(), "k", "claude-3-5-haiku-20241022", url);
    defer client.deinit();

    var conv = cc.conversation.Conversation.init(a);
    defer conv.deinit();
    try conv.appendText(.user, "REAL_USER_TEXT");
    // 孤儿 tool_result(ghost_777 无对应 tool_use)——normalize 应在发请求前剥掉。
    try conv.append(try orphanUserMessage(a, "ghost_777"));

    const perm = cc.permission.createContext(.bypass_permissions, a);
    const empty_defs: []const cc.json_mod.ToolDefinition = &.{};
    var render = writer_backend.WriterBackend.initNull();
    const be = render.backend();
    const result = agent_loop.run(&conv, client.provider(), empty_defs, &perm, .{ .max_turns = 1 }, &be, a) catch |e| {
        std.debug.print("run failed: {s}\n", .{@errorName(e)});
        return error.SkipZigTest;
    };
    try std.testing.expectEqual(agent_loop.StopReason.end_turn, result.stop_reason);

    // ★ 请求体断言:孤儿的 marker/id 被剥离,但真实用户文本仍在。
    const body = srv.lastRequest().?.body();
    try std.testing.expect(std.mem.indexOf(u8, body, "REAL_USER_TEXT") != null); // 真内容保留
    try std.testing.expect(std.mem.indexOf(u8, body, "ghost_777") == null); // 孤儿被剥
    try std.testing.expect(std.mem.indexOf(u8, body, "ORPHAN_MARKER_CONTENT") == null);
}

// 连续同角色合并在真请求体里生效:inject_user_context(合成首条 user)+ 首条真 user → 合并成一条。
// 断言两段文本都在请求体(合并不丢内容),且是同一个 user 消息(text+text 安全合并)。
test "P0.6 e2e: 连续 user(inject_context + user)在请求体里合并且不丢内容" {
    const a = std.testing.allocator;
    var srv = try harness.MockServer.startCassette(&[_][]const u8{FINAL_ANTHROPIC_SSE}, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    var io_rt = std.Io.Threaded.init(a, .{});
    defer io_rt.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(a, io_rt.io(), "k", "claude-3-5-haiku-20241022", url);
    defer client.deinit();

    var conv = cc.conversation.Conversation.init(a);
    defer conv.deinit();
    try conv.appendText(.user, "USER_QUESTION_TEXT");

    const perm = cc.permission.createContext(.bypass_permissions, a);
    const empty_defs: []const cc.json_mod.ToolDefinition = &.{};
    var render = writer_backend.WriterBackend.initNull();
    const be = render.backend();
    // inject_user_context 会在最前面合成一条 user 消息 → 与首条真 user 连续同角色 → 合并。
    const result = agent_loop.run(&conv, client.provider(), empty_defs, &perm, .{ .max_turns = 1, .inject_user_context = "INJECTED_CONTEXT_TEXT" }, &be, a) catch |e| {
        std.debug.print("run failed: {s}\n", .{@errorName(e)});
        return error.SkipZigTest;
    };
    try std.testing.expectEqual(agent_loop.StopReason.end_turn, result.stop_reason);

    // 两段文本都在请求体(合并不丢内容)。
    const body = srv.lastRequest().?.body();
    try std.testing.expect(std.mem.indexOf(u8, body, "INJECTED_CONTEXT_TEXT") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "USER_QUESTION_TEXT") != null);
}
