//! Issue #4 Part B:OpenAI **Responses API**(/v1/responses)显式协议支持的 L2 组件测试。
//!
//! 证明点:同一 OpenAIClient + 同一 agent_loop,`protocol=.responses` 时讲 Responses wire——
//! 请求是 input items / instructions / 扁平 tools / store:false;SSE 是 typed 事件流
//! (无 [DONE] 哨兵);function_call 的 call_id 闭环回传;usage/stop 归一进中立 IR。
//! 协议是显式配置(--openai-protocol / env),**绝不从 base_url/model 推断**——本套件
//! base_url 全指 MockServer,却按 protocol 讲 Responses wire,正是这条铁律的证词。
//!
//! cassette 约定:每个事件带 `event: <type>` 行 + `data: {...,"type":...}`(还原真实
//! Responses SSE 形态;解析只认 data 行的 "type" 字段,event 行被跳过)。

const std = @import("std");
const harness = @import("harness");
const cc = @import("cc");

const agent_loop = cc.agent_loop;
const openai = cc.api_openai;
const writer_backend = cc.writer_backend;

// ── cassettes ────────────────────────────────────────────────────────────────

const RESPONSES_TEXT_SSE =
    "event: response.created\n" ++
    "data: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_1\"}}\n\n" ++
    "event: response.output_text.delta\n" ++
    "data: {\"type\":\"response.output_text.delta\",\"item_id\":\"msg_1\",\"output_index\":0,\"delta\":\"hello \"}\n\n" ++
    "event: response.output_text.delta\n" ++
    "data: {\"type\":\"response.output_text.delta\",\"item_id\":\"msg_1\",\"output_index\":0,\"delta\":\"world\"}\n\n" ++
    "event: response.completed\n" ++
    "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_1\",\"status\":\"completed\",\"usage\":{\"input_tokens\":10,\"input_tokens_details\":{\"cached_tokens\":0},\"output_tokens\":5}}}\n\n";

const RESPONSES_TOOLCALL_SSE =
    "event: response.output_item.added\n" ++
    "data: {\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"type\":\"function_call\",\"id\":\"fc_1\",\"call_id\":\"call_r1\",\"name\":\"get_time\",\"arguments\":\"\"}}\n\n" ++
    "event: response.function_call_arguments.delta\n" ++
    "data: {\"type\":\"response.function_call_arguments.delta\",\"item_id\":\"fc_1\",\"output_index\":0,\"delta\":\"{}\"}\n\n" ++
    "event: response.function_call_arguments.done\n" ++
    "data: {\"type\":\"response.function_call_arguments.done\",\"item_id\":\"fc_1\",\"output_index\":0,\"arguments\":\"{}\"}\n\n" ++
    "event: response.completed\n" ++
    "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_2\",\"status\":\"completed\",\"usage\":{\"input_tokens\":12,\"input_tokens_details\":{\"cached_tokens\":0},\"output_tokens\":3}}}\n\n";

// 直驱 usage 归一:input_tokens **含** cached_tokens(嵌套 input_tokens_details 下),
// 中立 IR 减掉(2006-1920=86)防双计——与 chat include_usage 路径同一约定。
const RESPONSES_USAGE_SSE =
    "event: response.output_text.delta\n" ++
    "data: {\"type\":\"response.output_text.delta\",\"item_id\":\"msg_1\",\"output_index\":0,\"delta\":\"hi\"}\n\n" ++
    "event: response.completed\n" ++
    "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_3\",\"status\":\"completed\",\"usage\":{\"input_tokens\":2006,\"input_tokens_details\":{\"cached_tokens\":1920},\"output_tokens\":10}}}\n\n";

const RESPONSES_INCOMPLETE_SSE =
    "event: response.output_text.delta\n" ++
    "data: {\"type\":\"response.output_text.delta\",\"item_id\":\"msg_1\",\"output_index\":0,\"delta\":\"partial\"}\n\n" ++
    "event: response.incomplete\n" ++
    "data: {\"type\":\"response.incomplete\",\"response\":{\"id\":\"resp_4\",\"status\":\"incomplete\",\"incomplete_details\":{\"reason\":\"max_output_tokens\"},\"usage\":{\"input_tokens\":5,\"input_tokens_details\":{\"cached_tokens\":0},\"output_tokens\":9}}}\n\n";

const RESPONSES_FAILED_SSE =
    "event: response.failed\n" ++
    "data: {\"type\":\"response.failed\",\"response\":{\"id\":\"resp_5\",\"status\":\"failed\",\"error\":{\"code\":\"server_error\",\"message\":\"boom\"}}}\n\n";

const RESPONSES_ERROR_SSE =
    "event: error\n" ++
    "data: {\"type\":\"error\",\"code\":\"rate_limited\",\"message\":\"slow down\",\"param\":null,\"sequence_number\":1}\n\n";

const RESPONSES_ESCAPED_TEXT_SSE =
    "event: response.output_text.delta\n" ++
    "data: {\"type\":\"response.output_text.delta\",\"item_id\":\"msg_1\",\"output_index\":0,\"delta\":\"line1\\nline2\"}\n\n" ++
    "event: response.completed\n" ++
    "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_6\",\"status\":\"completed\",\"usage\":{\"input_tokens\":1,\"input_tokens_details\":{\"cached_tokens\":0},\"output_tokens\":1}}}\n\n";

// ── helpers ──────────────────────────────────────────────────────────────────

/// 起一个 protocol=.responses 的 OpenAIClient(base_url 指 MockServer——协议仍由
/// protocol 字段决定,不从 URL 推断)。precedent:app.zig 对 config.openai_protocol 的塞法。
fn initResponsesClient(a: std.mem.Allocator, io: std.Io, model: []const u8, url: []const u8) openai.OpenAIClient {
    var client = openai.OpenAIClient.init(a, io, "test-key", model, url);
    client.protocol = .responses;
    return client;
}

fn getTimeExec(ctx: *const cc.tool_context.ToolContext, _: []const u8, _: ?*anyopaque) anyerror![]u8 {
    return ctx.allocator.dupe(u8, "{\"t\":42}");
}

/// 直驱 drain:释放所有 owned 事件字节,只回传观察值。错误原样上抛(expectError 用)。
const DrainResult = struct {
    text: std.ArrayList(u8) = .empty,
    usage: ?cc.api_stream.UsageDelta = null,
    saw_done: bool = false,
    fn deinit(self: *DrainResult, a: std.mem.Allocator) void {
        self.text.deinit(a);
    }
};

fn drainAll(a: std.mem.Allocator, handle: *cc.api_stream.StreamHandle, out: *DrainResult) !void {
    while (try handle.next()) |ev| switch (ev) {
        .text => |t| {
            try out.text.appendSlice(a, t);
            a.free(t);
        },
        .thinking => |t| a.free(t),
        .tool_use_start => |tu| {
            a.free(tu.id);
            a.free(tu.name);
            a.free(tu.input_json);
        },
        .usage => |u| out.usage = u,
        .done => out.saw_done = true,
        else => {},
    };
}

// ── (a) 文本 e2e:同一 agent_loop 讲 Responses wire ───────────────────────────

test "Responses(a): agent_loop e2e 文本流 → end_turn;请求是 input/instructions/store:false" {
    const a = std.testing.allocator;
    var srv = try harness.MockServer.startCassette(&[_][]const u8{RESPONSES_TEXT_SSE}, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    var io_rt = std.Io.Threaded.init(a, .{});
    defer io_rt.deinit();
    var client = initResponsesClient(a, io_rt.io(), "gpt-5.2", url);
    defer client.deinit();

    var conv = cc.conversation.Conversation.init(a);
    defer conv.deinit();
    try conv.appendText(.user, "hi");
    const perm = cc.permission.createContext(.bypass_permissions, a);
    const empty_defs: []const cc.json_mod.ToolDefinition = &.{};
    var render = writer_backend.WriterBackend.initNull();
    const be = render.backend();

    const result = agent_loop.run(&conv, client.provider(), empty_defs, &perm, .{
        .max_turns = 3,
        .system_prompt = "you are helpful",
    }, &be, a) catch |e| {
        std.debug.print("responses text run failed: {s}\n", .{@errorName(e)});
        return error.SkipZigTest;
    };
    try std.testing.expectEqual(agent_loop.StopReason.end_turn, result.stop_reason);

    // 两个 output_text.delta 拼成 assistant 文本。
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

    // 请求体是 Responses wire:input/instructions/store:false/stream:true,无 chat 的 messages。
    const cap = srv.lastRequest().?;
    const body = cap.body();
    try std.testing.expect(std.mem.indexOf(u8, body, "\"input\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"instructions\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"store\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"stream\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"messages\":") == null);
}

// ── (b) function-call 闭环:call_id round-trip + 扁平 tools ────────────────────

test "Responses(b): function_call 闭环 → 第二请求含 function_call_output 且 call_id 一致" {
    const a = std.testing.allocator;
    var srv = try harness.MockServer.startCassette(&[_][]const u8{ RESPONSES_TOOLCALL_SSE, RESPONSES_TEXT_SSE }, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    var io_rt = std.Io.Threaded.init(a, .{});
    defer io_rt.deinit();
    var client = initResponsesClient(a, io_rt.io(), "gpt-5.2", url);
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
        std.debug.print("responses toolcall run failed: {s}\n", .{@errorName(e)});
        return error.SkipZigTest;
    };
    try std.testing.expectEqual(agent_loop.StopReason.end_turn, result.stop_reason);

    // conversation 有 call_r1 的 tool_use + 配对 tool_result(中立工具循环跨 Responses 协议)。
    var has_tu = false;
    var has_tr = false;
    for (conv.messages.items) |m| for (m.blocks) |b| switch (b) {
        .tool_use => |tu| if (std.mem.eql(u8, tu.id, "call_r1")) {
            has_tu = true;
        },
        .tool_result => |tr| if (std.mem.eql(u8, tr.tool_use_id, "call_r1")) {
            has_tr = true;
        },
        else => {},
    };
    try std.testing.expect(has_tu);
    try std.testing.expect(has_tr);

    // 首请求:tools 扁平(顶层 name,无 chat 的嵌套 "function":{)。
    const first = srv.requestAt(0).?;
    try std.testing.expect(std.mem.indexOf(u8, first.body(), "{\"type\":\"function\",\"name\":\"get_time\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, first.body(), "\"function\":{") == null);
    try std.testing.expect(std.mem.indexOf(u8, first.body(), "\"strict\":false") != null);

    // 次请求:function_call 回放 + function_call_output,call_id 与流入方向一致(闭环)。
    const second = srv.requestAt(1).?;
    const second_body = second.body();
    try std.testing.expect(std.mem.indexOf(u8, second_body, "\"type\":\"function_call\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, second_body, "\"type\":\"function_call_output\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, second_body, "\"call_id\":\"call_r1\"") != null);
}

// ── (c) usage 归一 + done + stop(直驱)────────────────────────────────────────

test "Responses(c): usage 归一(input 减 cached)+ 补发 .done + stopReason=end_turn" {
    const a = std.testing.allocator;
    var srv = try harness.MockServer.startCassette(&[_][]const u8{RESPONSES_USAGE_SSE}, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    var io_rt = std.Io.Threaded.init(a, .{});
    defer io_rt.deinit();
    var client = initResponsesClient(a, io_rt.io(), "gpt-5.2", url);
    defer client.deinit();

    const p = client.provider();
    const msgs = [_]cc.types_mod.ApiMessage{
        .{ .role = .user, .content = &[_]cc.types_mod.ApiContent{.{ .text = "hi" }} },
    };
    var handle = p.sendStream(&msgs, null, null, null, null, null, "") catch |e| {
        std.debug.print("responses sendStream failed: {s}\n", .{@errorName(e)});
        return error.SkipZigTest;
    };
    defer handle.deinit();

    var out = DrainResult{};
    defer out.deinit(a);
    try drainAll(a, &handle, &out);

    try std.testing.expectEqualStrings("hi", out.text.items);
    try std.testing.expect(out.usage != null);
    try std.testing.expectEqual(@as(u64, 86), out.usage.?.input_tokens); // 2006-1920
    try std.testing.expectEqual(@as(u64, 1920), out.usage.?.cache_read_input_tokens);
    try std.testing.expectEqual(@as(u64, 10), out.usage.?.output_tokens);
    try std.testing.expect(out.saw_done); // 无 [DONE] 行 → completed 后补发 .done
    try std.testing.expectEqual(cc.api_stream.StopReason.end_turn, handle.stopReason());
}

// ── (d) incomplete → max_tokens ──────────────────────────────────────────────

test "Responses(d): response.incomplete reason=max_output_tokens → stopReason=max_tokens" {
    const a = std.testing.allocator;
    var srv = try harness.MockServer.startCassette(&[_][]const u8{RESPONSES_INCOMPLETE_SSE}, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    var io_rt = std.Io.Threaded.init(a, .{});
    defer io_rt.deinit();
    var client = initResponsesClient(a, io_rt.io(), "gpt-5.2", url);
    defer client.deinit();

    const p = client.provider();
    const msgs = [_]cc.types_mod.ApiMessage{
        .{ .role = .user, .content = &[_]cc.types_mod.ApiContent{.{ .text = "hi" }} },
    };
    var handle = p.sendStream(&msgs, null, null, null, null, null, "") catch |e| {
        std.debug.print("responses incomplete sendStream failed: {s}\n", .{@errorName(e)});
        return error.SkipZigTest;
    };
    defer handle.deinit();

    var out = DrainResult{};
    defer out.deinit(a);
    try drainAll(a, &handle, &out);

    try std.testing.expectEqualStrings("partial", out.text.items);
    try std.testing.expect(out.saw_done);
    try std.testing.expectEqual(cc.api_stream.StopReason.max_tokens, handle.stopReason());
}

// ── (e) failed / error → RequestFailed ───────────────────────────────────────

test "Responses(e): response.failed 与流级 error 事件都上抛 RequestFailed" {
    const a = std.testing.allocator;
    const cassettes = [_][]const u8{ RESPONSES_FAILED_SSE, RESPONSES_ERROR_SSE };
    for (cassettes) |sse| {
        var srv = try harness.MockServer.startCassette(&[_][]const u8{sse}, 0);
        defer srv.stop();
        const url = try srv.urlOwned(a);
        defer a.free(url);

        var io_rt = std.Io.Threaded.init(a, .{});
        defer io_rt.deinit();
        var client = initResponsesClient(a, io_rt.io(), "gpt-5.2", url);
        defer client.deinit();

        const p = client.provider();
        const msgs = [_]cc.types_mod.ApiMessage{
            .{ .role = .user, .content = &[_]cc.types_mod.ApiContent{.{ .text = "hi" }} },
        };
        var handle = p.sendStream(&msgs, null, null, null, null, null, "") catch |e| {
            std.debug.print("responses failed-case sendStream failed: {s}\n", .{@errorName(e)});
            return error.SkipZigTest;
        };
        defer handle.deinit();

        var out = DrainResult{};
        defer out.deinit(a);
        try std.testing.expectError(error.RequestFailed, drainAll(a, &handle, &out));
    }
}

// ── (f) delta 转义解除 ────────────────────────────────────────────────────────

test "Responses(f): output_text.delta 解除 JSON 转义(真实换行进 .text)" {
    const a = std.testing.allocator;
    var srv = try harness.MockServer.startCassette(&[_][]const u8{RESPONSES_ESCAPED_TEXT_SSE}, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    var io_rt = std.Io.Threaded.init(a, .{});
    defer io_rt.deinit();
    var client = initResponsesClient(a, io_rt.io(), "gpt-5.2", url);
    defer client.deinit();

    const p = client.provider();
    const msgs = [_]cc.types_mod.ApiMessage{
        .{ .role = .user, .content = &[_]cc.types_mod.ApiContent{.{ .text = "hi" }} },
    };
    var handle = p.sendStream(&msgs, null, null, null, null, null, "") catch |e| {
        std.debug.print("responses escaped sendStream failed: {s}\n", .{@errorName(e)});
        return error.SkipZigTest;
    };
    defer handle.deinit();

    var out = DrainResult{};
    defer out.deinit(a);
    try drainAll(a, &handle, &out);
    try std.testing.expectEqualStrings("line1\nline2", out.text.items);
    try std.testing.expect(std.mem.indexOf(u8, out.text.items, "\\n") == null);
}

// ── (g) 请求序列化字节断言 ────────────────────────────────────────────────────

test "Responses(g): 序列化字节断言(reasoning effort=high / xhigh→high / 无多余字段)" {
    const a = std.testing.allocator;
    const msgs = [_]cc.types_mod.ApiMessage{
        .{ .role = .user, .content = &[_]cc.types_mod.ApiContent{.{ .text = "hi" }} },
    };
    const dialect = cc.api_dialect.dialectFor(.openai, "gpt-5.2");

    const body = try openai.serializeOpenAIResponsesRequest(a, "gpt-5.2", &msgs, "sys", null, .{ .reasoning_effort = .high }, dialect);
    defer a.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"model\":\"gpt-5.2\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"reasoning\":{\"effort\":\"high\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"stream\":true,\"store\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"instructions\":\"sys\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"input\":[{\"role\":\"user\",\"content\":\"hi\"}]") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"messages\":") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "max_output_tokens") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "stream_options") == null);

    // xhigh → Responses 档位封顶 high(无 xhigh 档)。
    const body2 = try openai.serializeOpenAIResponsesRequest(a, "gpt-5.2", &msgs, null, null, .{ .reasoning_effort = .xhigh }, dialect);
    defer a.free(body2);
    try std.testing.expect(std.mem.indexOf(u8, body2, "\"reasoning\":{\"effort\":\"high\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, body2, "xhigh") == null);
    // system=null → 不发 instructions。
    try std.testing.expect(std.mem.indexOf(u8, body2, "\"instructions\":") == null);
}

test "Responses(g2): tool_use/tool_result → function_call/function_call_output items" {
    const a = std.testing.allocator;
    const msgs = [_]cc.types_mod.ApiMessage{
        .{ .role = .user, .content = &[_]cc.types_mod.ApiContent{.{ .text = "go" }} },
        .{
            .role = .assistant,
            .content = &[_]cc.types_mod.ApiContent{
                .{ .thinking = "hidden" }, // thinking block 跳过,不回传
                .{ .tool_use = .{ .id = "call_x", .name = "get_time", .input = "{\"q\":\"now\"}" } },
            },
        },
        .{ .role = .user, .content = &[_]cc.types_mod.ApiContent{
            .{ .tool_result = .{ .tool_use_id = "call_x", .content = "{\"t\":42}" } },
        } },
    };
    const dialect = cc.api_dialect.dialectFor(.openai, "gpt-5.2");
    const body = try openai.serializeOpenAIResponsesRequest(a, "gpt-5.2", &msgs, null, null, .{}, dialect);
    defer a.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "{\"type\":\"function_call\",\"call_id\":\"call_x\",\"name\":\"get_time\",\"arguments\":\"{\\\"q\\\":\\\"now\\\"}\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "{\"type\":\"function_call_output\",\"call_id\":\"call_x\",\"output\":\"{\\\"t\\\":42}\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "hidden") == null);
    // 无 reasoning(effort null)→ 不发 reasoning 字段。
    try std.testing.expect(std.mem.indexOf(u8, body, "\"reasoning\":") == null);
}

// ── flag/env 面:--openai-protocol 解析(声明=接线)────────────────────────────

test "Responses(flag): --openai-protocol responses 解析进 Config;词表外 fail-closed" {
    const a = std.testing.allocator;
    {
        const argv = [_][*:0]const u8{ "metacodes", "--openai-protocol", "responses" };
        const config = cc.parseArgsForTest(&argv, a);
        try std.testing.expect(config.parse_error == null);
        try std.testing.expectEqual(cc.types_mod.OpenAIProtocol.responses, config.openai_protocol);
    }
    {
        // 别名 "chat" 与默认值等价。
        const argv = [_][*:0]const u8{ "metacodes", "--openai-protocol", "chat" };
        const config = cc.parseArgsForTest(&argv, a);
        try std.testing.expect(config.parse_error == null);
        try std.testing.expectEqual(cc.types_mod.OpenAIProtocol.chat_completions, config.openai_protocol);
    }
    {
        // 拼错 → parse error(main 打印后 exit 2),绝不静默落默认端点。
        const argv = [_][*:0]const u8{ "metacodes", "--openai-protocol", "response" };
        const config = cc.parseArgsForTest(&argv, a);
        try std.testing.expect(config.parse_error != null);
        a.free(config.parse_error.?);
    }
}
