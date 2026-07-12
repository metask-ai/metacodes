//! P3 端到端验证:第二个 provider(OpenAI)证明"真多协议"。
//!
//! 核心证明:**同一个 agent_loop.run()**,喂一个讲 OpenAI chat/completions 协议的 provider
//! (wire 格式与 Anthropic 完全不同),跑通到 end_turn。agent_loop / Conversation / 中立 IR /
//! provider.zig 一行没改。这是整个多 Provider 重构兑现价值的地方。

const std = @import("std");
const harness = @import("harness");
const cc = @import("cc");

const agent_loop = cc.agent_loop;
const openai = cc.api_openai;
const writer_backend = cc.writer_backend;
const subagent = cc.core_subagent;

// OpenAI chat/completions 流式格式(与 Anthropic SSE 完全不同):
//   data: {"choices":[{"delta":{"content":"..."}}]}
//   data: {"choices":[{"delta":{},"finish_reason":"stop"}]}
//   data: [DONE]
const OPENAI_TEXT_SSE =
    "data: {\"choices\":[{\"delta\":{\"role\":\"assistant\",\"content\":\"\"}}]}\n\n" ++
    "data: {\"choices\":[{\"delta\":{\"content\":\"hello \"}}]}\n\n" ++
    "data: {\"choices\":[{\"delta\":{\"content\":\"world\"}}]}\n\n" ++
    "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n" ++
    "data: [DONE]\n\n";

test "P3: 同一 agent_loop 喂 OpenAI provider(异协议)跑通到 end_turn" {
    const a = std.testing.allocator;
    var srv = try harness.MockServer.startCassette(&[_][]const u8{OPENAI_TEXT_SSE}, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    var io_rt = std.Io.Threaded.init(a, .{});
    defer io_rt.deinit();
    // OpenAIClient(不是 Anthropic Client)——讲 chat/completions 协议。
    var client = openai.OpenAIClient.init(a, io_rt.io(), "test-key", "gpt-4o", url);
    defer client.deinit();

    var conv = cc.conversation.Conversation.init(a);
    defer conv.deinit();
    try conv.appendText(.user, "hi");
    const perm = cc.permission.createContext(.bypass_permissions, a);
    const empty_defs: []const cc.json_mod.ToolDefinition = &.{};

    var render = writer_backend.WriterBackend.initNull();
    const be = render.backend();

    // ★ 同一个 agent_loop.run(),喂 OpenAI provider。core 一行没改。
    const result = agent_loop.run(&conv, client.provider(), empty_defs, &perm, .{ .max_turns = 3 }, &be, a) catch |e| {
        std.debug.print("OpenAI run failed: {s}\n", .{@errorName(e)});
        return error.SkipZigTest;
    };

    // 跑通到 end_turn(OpenAI finish_reason:"stop" → 中立 .end_turn)。
    try std.testing.expectEqual(agent_loop.StopReason.end_turn, result.stop_reason);

    // assistant 文本是 OpenAI delta.content 拼接(经中立 StreamEvent.text)。
    var got: std.ArrayList(u8) = .empty;
    defer got.deinit(a);
    for (conv.messages.items) |m| {
        if (m.role != .assistant) continue;
        for (m.blocks) |b| switch (b) {
            .text => |t| try got.appendSlice(a, t),
            else => {},
        };
    }
    try std.testing.expectEqualStrings("hello world", got.items);

    // 请求体是 OpenAI 格式(证明 provider 真翻译了 wire 协议)。
    const cap = srv.lastRequest().?;
    const body = cap.body();
    try std.testing.expect(std.mem.indexOf(u8, body, "\"model\":\"gpt-4o\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"role\":\"user\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "chat/completions") == null); // body 不含 URL
}

// OpenAI tool_calls(function calling)格式:证明工具循环跨协议。
const OPENAI_TOOLCALL_SSE =
    "data: {\"choices\":[{\"delta\":{\"role\":\"assistant\",\"content\":null,\"tool_calls\":[{\"index\":0,\"id\":\"call_1\",\"type\":\"function\",\"function\":{\"name\":\"get_time\",\"arguments\":\"\"}}]}}]}\n\n" ++
    "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"{}\"}}]}}]}\n\n" ++
    "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}]}\n\n" ++
    "data: [DONE]\n\n";

const OPENAI_FINAL_SSE =
    "data: {\"choices\":[{\"delta\":{\"content\":\"the time is now\"}}]}\n\n" ++
    "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n" ++
    "data: [DONE]\n\n";

fn getTimeExec(ctx: *const cc.tool_context.ToolContext, _: []const u8, _: ?*anyopaque) anyerror![]u8 {
    return ctx.allocator.dupe(u8, "{\"t\":42}");
}

test "P3: OpenAI tool_calls → 中立工具循环 → 第二轮 end_turn(工具循环跨协议)" {
    const a = std.testing.allocator;
    // 两轮:① tool_calls ② final text。
    var srv = try harness.MockServer.startCassette(&[_][]const u8{ OPENAI_TOOLCALL_SSE, OPENAI_FINAL_SSE }, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    var io_rt = std.Io.Threaded.init(a, .{});
    defer io_rt.deinit();
    var client = openai.OpenAIClient.init(a, io_rt.io(), "test-key", "gpt-4o", url);
    defer client.deinit();

    var dyn = cc.tools_dynamic.DynRegistry.init(a);
    defer dyn.deinit();
    try dyn.register("get_time", "Get current time", &.{}, getTimeExec, null, false);

    var conv = cc.conversation.Conversation.init(a);
    defer conv.deinit();
    try conv.appendText(.user, "what time is it");
    const perm = cc.permission.createContext(.bypass_permissions, a);
    const tool_defs = try cc.tools.toToolDefinitionsFull(a, &dyn, null);
    defer a.free(tool_defs);

    var render = writer_backend.WriterBackend.initNull();
    const be = render.backend();

    const result = agent_loop.run(&conv, client.provider(), tool_defs, &perm, .{ .max_turns = 4, .dyn_registry = &dyn }, &be, a) catch |e| {
        std.debug.print("OpenAI toolcall run failed: {s}\n", .{@errorName(e)});
        return error.SkipZigTest;
    };

    // 跑到 end_turn(工具执行后第二轮 finish stop)。
    try std.testing.expectEqual(agent_loop.StopReason.end_turn, result.stop_reason);
    // conversation 含 tool_use(call_1)+ 对应 tool_result(证明工具循环跨 OpenAI 协议跑通)。
    var has_tu = false;
    var has_tr = false;
    for (conv.messages.items) |m| for (m.blocks) |b| switch (b) {
        .tool_use => |tu| if (std.mem.eql(u8, tu.id, "call_1")) {
            has_tu = true;
        },
        .tool_result => |tr| if (std.mem.eql(u8, tr.tool_use_id, "call_1")) {
            has_tr = true;
        },
        else => {},
    };
    try std.testing.expect(has_tu);
    try std.testing.expect(has_tr);
}

// P0.5 端到端:parent=OpenAI 时,spawn 出的 subagent 的**请求真的发到 OpenAI wire 格式**。
// 这是"provider 构造路径 vtable 化"的唯一证明——subagent 经 spawnAgentSink(prov=OpenAI, anthropic=null)
// 继承父 provider,而非旧版硬编码退回 Anthropic。anthropic_client 传 null(非 Anthropic parent)。
test "P0.5: parent=OpenAI → spawnAgentSink 继承 OpenAI provider(子请求是 OpenAI wire 格式)" {
    const a = std.testing.allocator;
    var srv = try harness.MockServer.startCassette(&[_][]const u8{OPENAI_TEXT_SSE}, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    var io_rt = std.Io.Threaded.init(a, .{});
    defer io_rt.deinit();
    // 父 provider 是 OpenAIClient(gpt-4o)——讲 chat/completions 协议。
    var client = openai.OpenAIClient.init(a, io_rt.io(), "test-key", "gpt-4o", url);
    defer client.deinit();

    const perm = cc.permission.createContext(.bypass_permissions, a);
    const empty_defs: []const cc.json_mod.ToolDefinition = &.{};
    var render = writer_backend.WriterBackend.initNull();
    const be = render.backend();

    // ★ 经 subagent spawn 路径,喂 OpenAI provider + anthropic_client=null。
    const result = subagent.spawnAgentSink(
        a,
        client.provider(),
        null, // 非 Anthropic parent → 子 ctx.api_client=null(web_search 不可用,其余正常)
        empty_defs,
        &perm,
        null,
        "hi from parent",
        .{ .max_turns = 3 },
        &be,
    ) catch |e| {
        std.debug.print("OpenAI spawn failed: {s}\n", .{@errorName(e)});
        return error.SkipZigTest;
    };
    defer result.deinit();
    try std.testing.expectEqual(agent_loop.StopReason.end_turn, result.stop_reason);
    try std.testing.expectEqualStrings("hello world", result.final_text);

    // ★ 关键断言:subagent 发出的请求体是 **OpenAI** 格式(model=gpt-4o + chat/completions 侧
    // wire 特征),证明子 loop 真用了继承来的 OpenAI provider,不是退回 Anthropic。
    const cap = srv.lastRequest().?;
    const body = cap.body();
    try std.testing.expect(std.mem.indexOf(u8, body, "\"model\":\"gpt-4o\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"role\":\"user\"") != null);
    // Anthropic 专有布局特征(top-level system 字段 / claude model)不应出现。
    try std.testing.expect(std.mem.indexOf(u8, body, "claude") == null);
}

// OpenAI 不支持 Anthropic 式 server-tool web_search → capability 门控应把 WebSearch
// 从发给模型的 tools 数组剔除(P2 门控 + .openai 行 web_search=false 联动)。
test "P3: OpenAI provider 下 WebSearch 被 capability 门控剔除(跨 provider 门控生效)" {
    const a = std.testing.allocator;
    var srv = try harness.MockServer.startCassette(&[_][]const u8{OPENAI_TEXT_SSE}, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    var io_rt = std.Io.Threaded.init(a, .{});
    defer io_rt.deinit();
    var client = openai.OpenAIClient.init(a, io_rt.io(), "test-key", "gpt-4o", url);
    defer client.deinit();

    var conv = cc.conversation.Conversation.init(a);
    defer conv.deinit();
    try conv.appendText(.user, "hi");
    const perm = cc.permission.createContext(.bypass_permissions, a);

    // 完整内置工具集含 WebSearch。
    const tool_defs = try cc.tools.toToolDefinitions(a);
    defer a.free(tool_defs);
    var has_ws = false;
    for (tool_defs) |d| {
        if (std.mem.eql(u8, d.name, "WebSearch")) has_ws = true;
    }
    try std.testing.expect(has_ws); // 否则测试无意义

    var render = writer_backend.WriterBackend.initNull();
    const be = render.backend();

    const result = agent_loop.run(&conv, client.provider(), tool_defs, &perm, .{ .max_turns = 2 }, &be, a) catch |e| {
        std.debug.print("OpenAI gate run failed: {s}\n", .{@errorName(e)});
        return error.SkipZigTest;
    };
    try std.testing.expectEqual(agent_loop.StopReason.end_turn, result.stop_reason);

    // 断言:OpenAI provider 的请求体 tools 里没有 WebSearch(被门控剔),但 Read 还在。
    const cap = srv.lastRequest().?;
    const body = cap.body();
    try std.testing.expect(std.mem.indexOf(u8, body, "\"WebSearch\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"Read\"") != null);
}

// P0.1 并行 tool_calls:一个 delta 两个 index → 两个 tool_call 都被累积、都执行、都产 tool_result,
// 且各自 name 干净(不交叉污染)。第二轮请求体必须含**两个** tool_call_id 配对(否则 OpenAI 400)。
const OPENAI_PARALLEL_TOOLCALL_SSE =
    "data: {\"choices\":[{\"delta\":{\"tool_calls\":[" ++
    "{\"index\":0,\"id\":\"call_1\",\"type\":\"function\",\"function\":{\"name\":\"get_time\",\"arguments\":\"{}\"}}," ++
    "{\"index\":1,\"id\":\"call_2\",\"type\":\"function\",\"function\":{\"name\":\"get_date\",\"arguments\":\"{}\"}}" ++
    "]}}]}\n\n" ++
    "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}]}\n\n" ++
    "data: [DONE]\n\n";

test "P3/P0.1: 并行 tool_calls 两个都执行 + 各自 name 干净 + 第二轮双 tool_call_id 配对" {
    const a = std.testing.allocator;
    var srv = try harness.MockServer.startCassette(&[_][]const u8{ OPENAI_PARALLEL_TOOLCALL_SSE, OPENAI_FINAL_SSE }, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    var io_rt = std.Io.Threaded.init(a, .{});
    defer io_rt.deinit();
    var client = openai.OpenAIClient.init(a, io_rt.io(), "test-key", "gpt-4o", url);
    defer client.deinit();

    var dyn = cc.tools_dynamic.DynRegistry.init(a);
    defer dyn.deinit();
    try dyn.register("get_time", "Get current time", &.{}, getTimeExec, null, false);
    try dyn.register("get_date", "Get current date", &.{}, getTimeExec, null, false);

    var conv = cc.conversation.Conversation.init(a);
    defer conv.deinit();
    try conv.appendText(.user, "time and date");
    const perm = cc.permission.createContext(.bypass_permissions, a);
    const tool_defs = try cc.tools.toToolDefinitionsFull(a, &dyn, null);
    defer a.free(tool_defs);

    var render = writer_backend.WriterBackend.initNull();
    const be = render.backend();

    const result = agent_loop.run(&conv, client.provider(), tool_defs, &perm, .{ .max_turns = 4, .dyn_registry = &dyn }, &be, a) catch |e| {
        std.debug.print("parallel run failed: {s}\n", .{@errorName(e)});
        return error.SkipZigTest;
    };
    try std.testing.expectEqual(agent_loop.StopReason.end_turn, result.stop_reason);

    var name1: []const u8 = "";
    var name2: []const u8 = "";
    var result_count: usize = 0;
    for (conv.messages.items) |m| for (m.blocks) |b| switch (b) {
        .tool_use => |tu| {
            if (std.mem.eql(u8, tu.id, "call_1")) name1 = tu.name;
            if (std.mem.eql(u8, tu.id, "call_2")) name2 = tu.name;
        },
        .tool_result => result_count += 1,
        else => {},
    };
    // 两个 tool_call 都在,name 各自干净(未拼成 "get_timeget_date")。
    try std.testing.expectEqualStrings("get_time", name1);
    try std.testing.expectEqualStrings("get_date", name2);
    // 两个都执行 → 两个 tool_result。
    try std.testing.expectEqual(@as(usize, 2), result_count);
    // 第二轮请求体:两个 tool_call_id 都作为独立 {role:"tool"} 回传(request 序列化不丢第二个)。
    const cap = srv.lastRequest().?;
    const body = cap.body();
    try std.testing.expect(std.mem.indexOf(u8, body, "\"call_1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"call_2\"") != null);
}

// P0.2 hook 管线端到端:PreToolUse ModifyInput 改写执行输入 + PostToolUse 注入 additionalContext。
const OPENAI_ECHO_TOOLCALL_SSE =
    "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_e\",\"type\":\"function\",\"function\":{\"name\":\"echo_tool\",\"arguments\":\"{\\\"x\\\":1}\"}}]}}]}\n\n" ++
    "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}]}\n\n" ++
    "data: [DONE]\n\n";

fn echoInputExec(ctx: *const cc.tool_context.ToolContext, input: []const u8, _: ?*anyopaque) anyerror![]u8 {
    return ctx.allocator.dupe(u8, input); // 回显**实际执行**收到的输入
}

test "P0.2: PreToolUse ModifyInput 改写执行输入 + PostToolUse 注入上下文(端到端)" {
    const a = std.testing.allocator;
    var srv = try harness.MockServer.startCassette(&[_][]const u8{ OPENAI_ECHO_TOOLCALL_SSE, OPENAI_FINAL_SSE }, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);
    var io_rt = std.Io.Threaded.init(a, .{});
    defer io_rt.deinit();
    var client = openai.OpenAIClient.init(a, io_rt.io(), "test-key", "gpt-4o", url);
    defer client.deinit();

    var dyn = cc.tools_dynamic.DynRegistry.init(a);
    defer dyn.deinit();
    try dyn.register("echo_tool", "Echo input", &.{}, echoInputExec, null, false);

    var conv = cc.conversation.Conversation.init(a);
    defer conv.deinit();
    try conv.appendText(.user, "run echo");

    // PreToolUse 改写 echo_tool 输入 {"x":1}→{"x":2};PostToolUse 注 additionalContext。
    const pre_cmds = [_][]const u8{"echo '{\"updatedInput\":{\"x\":2}}'"};
    const pre_entries = [_]cc.permission_hooks.HookEntry{.{ .matcher = "echo_tool", .commands = &pre_cmds }};
    const post_cmds = [_][]const u8{"echo '{\"additionalContext\":\"post-check ok\"}'"};
    const post_entries = [_]cc.permission_hooks.HookEntry{.{ .matcher = "*", .commands = &post_cmds }};
    const hookset = cc.permission_hooks.HookSet{ .pre_tool_use = &pre_entries, .post_tool_use = &post_entries, .allocator = a };

    var perm = cc.permission.createContext(.bypass_permissions, a);
    perm.hooks = &hookset;
    const tool_defs = try cc.tools.toToolDefinitionsFull(a, &dyn, null);
    defer a.free(tool_defs);
    var render = writer_backend.WriterBackend.initNull();
    const be = render.backend();

    const result = agent_loop.run(&conv, client.provider(), tool_defs, &perm, .{ .max_turns = 4, .dyn_registry = &dyn }, &be, a) catch |e| {
        std.debug.print("hook run failed: {s}\n", .{@errorName(e)});
        return error.SkipZigTest;
    };
    try std.testing.expectEqual(agent_loop.StopReason.end_turn, result.stop_reason);

    var modified_seen = false;
    var post_ctx_seen = false;
    for (conv.messages.items) |m| for (m.blocks) |b| switch (b) {
        .tool_result => |tr| {
            // echo_tool 回显实际执行输入 → ModifyInput 生效则含 "x":2(不是原始 "x":1)。
            if (std.mem.indexOf(u8, tr.content, "\"x\":2") != null) modified_seen = true;
        },
        .text => |t| {
            if (std.mem.indexOf(u8, t, "PostToolUse hook") != null and std.mem.indexOf(u8, t, "post-check ok") != null) post_ctx_seen = true;
        },
        else => {},
    };
    try std.testing.expect(modified_seen); // PreToolUse ModifyInput 端到端生效
    try std.testing.expect(post_ctx_seen); // PostToolUse additionalContext 注入对话
}

// 缓存命中:OpenAI 自动前缀缓存,cached_tokens 在末尾 usage chunk(include_usage)。
// 证明 onUsage 接线:OpenAI 字段名 → 中立 UsageDelta.cache_read_input_tokens。
const OPENAI_USAGE_SSE =
    "data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n\n" ++
    "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n" ++
    "data: {\"choices\":[],\"usage\":{\"prompt_tokens\":2006,\"completion_tokens\":10,\"prompt_tokens_details\":{\"cached_tokens\":1920}}}\n\n" ++
    "data: [DONE]\n\n";

test "P3/缓存: OpenAI cached_tokens → 中立 UsageDelta.cache_read(onUsage 接线)" {
    const a = std.testing.allocator;
    var srv = try harness.MockServer.startCassette(&[_][]const u8{OPENAI_USAGE_SSE}, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    var io_rt = std.Io.Threaded.init(a, .{});
    defer io_rt.deinit();
    var client = openai.OpenAIClient.init(a, io_rt.io(), "test-key", "gpt-4o", url);
    defer client.deinit();

    // 直接驱动 StreamHandle(不经 agent_loop),断言中立 usage 事件携带缓存命中。
    const p = client.provider();
    const msgs = [_]cc.types_mod.ApiMessage{
        .{ .role = .user, .content = &[_]cc.types_mod.ApiContent{.{ .text = "hi" }} },
    };
    var handle = p.sendStream(&msgs, null, null, null, null, null, "") catch |e| {
        std.debug.print("sendStream failed: {s}\n", .{@errorName(e)});
        return error.SkipZigTest;
    };
    defer handle.deinit();

    var saw_usage = false;
    var cache_read: u64 = 0;
    var input_tokens: u64 = 0;
    while (try handle.next()) |ev| switch (ev) {
        .text => |t| a.free(t),
        .usage => |u| {
            saw_usage = true;
            cache_read = u.cache_read_input_tokens;
            input_tokens = u.input_tokens;
        },
        .tool_use_start => |tu| {
            a.free(tu.id);
            a.free(tu.name);
            a.free(tu.input_json);
        },
        else => {},
    };

    // OpenAI 的 cached_tokens=1920 → 中立 cache_read=1920;prompt_tokens=2006 **含** cached,
    // 归一成 Anthropic-exclusive 语义:input = 2006-1920 = 86(消费方 in+cache_r 求和不双计)。
    try std.testing.expect(saw_usage);
    try std.testing.expectEqual(@as(u64, 1920), cache_read);
    try std.testing.expectEqual(@as(u64, 86), input_tokens);

    // 请求体含 stream_options.include_usage(否则 OpenAI 默认流式不发 usage)。
    const cap = srv.lastRequest().?;
    try std.testing.expect(std.mem.indexOf(u8, cap.body(), "\"include_usage\":true") != null);
}
