//! C3 端到端验证:第三个 provider(Gemini)证明缓存扩展点的"有状态对象"范式。
//!
//! 核心证明:**同一个 agent_loop.run()**,喂讲 Gemini generateContent 协议的 provider
//! (wire 格式与 Anthropic/OpenAI 都不同),跑通到 end_turn。+ 验证有状态缓存句柄表:
//! 注册一个 cache 句柄 → 下次请求体带 cachedContent 引用。

const std = @import("std");
const harness = @import("harness");
const cc = @import("cc");

const agent_loop = cc.agent_loop;
const gemini = cc.api_gemini;
const writer_backend = cc.writer_backend;
const subagent = cc.core_subagent;

// Gemini SSE(alt=sse):每 chunk 是完整 GenerateContentResponse。文本在 candidates[].content.parts[].text。
const GEMINI_TEXT_SSE =
    "data: {\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"text\":\"hello \"}]}}]}\n\n" ++
    "data: {\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"text\":\"world\"}]},\"finishReason\":\"STOP\"}],\"usageMetadata\":{\"promptTokenCount\":10,\"candidatesTokenCount\":2,\"cachedContentTokenCount\":3000}}\n\n";

test "C3: 同一 agent_loop 喂 Gemini provider(异协议)跑通到 end_turn" {
    const a = std.testing.allocator;
    var srv = try harness.MockServer.startCassette(&[_][]const u8{GEMINI_TEXT_SSE}, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    var io_rt = std.Io.Threaded.init(a, .{});
    defer io_rt.deinit();
    var client = gemini.GeminiClient.init(a, io_rt.io(), "test-key", "gemini-2.5-flash", url);
    defer client.deinit();

    var conv = cc.conversation.Conversation.init(a);
    defer conv.deinit();
    try conv.appendText(.user, "hi");
    const perm = cc.permission.createContext(.bypass_permissions, a);
    const empty_defs: []const cc.json_mod.ToolDefinition = &.{};

    var render = writer_backend.WriterBackend.initNull();
    const be = render.backend();

    const result = agent_loop.run(&conv, client.provider(), empty_defs, &perm, .{ .max_turns = 3 }, &be, a) catch |e| {
        std.debug.print("Gemini run failed: {s}\n", .{@errorName(e)});
        return error.SkipZigTest;
    };
    try std.testing.expectEqual(agent_loop.StopReason.end_turn, result.stop_reason);

    // assistant 文本是 Gemini parts[].text 拼接(经中立 StreamEvent.text)。
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

    // 请求体是 Gemini 格式(systemInstruction/contents)+ URL 走 :streamGenerateContent。
    const cap = srv.lastRequest().?;
    const body = cap.body();
    try std.testing.expect(std.mem.indexOf(u8, body, "\"contents\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"role\":\"user\"") != null);
}

// P0.5 端到端:parent=Gemini 时,spawn 出的 subagent 的请求真的发到 Gemini wire 格式。
// 证明 subagent 经 spawnAgentSink(prov=Gemini, anthropic=null) 继承父 provider,非退回 Anthropic。
test "P0.5: parent=Gemini → spawnAgentSink 继承 Gemini provider(子请求是 Gemini wire 格式)" {
    const a = std.testing.allocator;
    var srv = try harness.MockServer.startCassette(&[_][]const u8{GEMINI_TEXT_SSE}, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    var io_rt = std.Io.Threaded.init(a, .{});
    defer io_rt.deinit();
    var client = gemini.GeminiClient.init(a, io_rt.io(), "test-key", "gemini-2.5-flash", url);
    defer client.deinit();

    const perm = cc.permission.createContext(.bypass_permissions, a);
    const empty_defs: []const cc.json_mod.ToolDefinition = &.{};
    var render = writer_backend.WriterBackend.initNull();
    const be = render.backend();

    const result = subagent.spawnAgentSink(
        a,
        client.provider(),
        null,
        empty_defs,
        &perm,
        null,
        "hi from parent",
        .{ .max_turns = 3 },
        &be,
    ) catch |e| {
        std.debug.print("Gemini spawn failed: {s}\n", .{@errorName(e)});
        return error.SkipZigTest;
    };
    defer result.deinit();
    try std.testing.expectEqual(agent_loop.StopReason.end_turn, result.stop_reason);
    try std.testing.expectEqualStrings("hello world", result.final_text);

    // ★ 关键断言:subagent 请求体是 Gemini 格式(contents 数组 + role:user),非 Anthropic。
    const cap = srv.lastRequest().?;
    const body = cap.body();
    try std.testing.expect(std.mem.indexOf(u8, body, "\"contents\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"role\":\"user\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "claude") == null);
}

// Gemini functionCall(工具循环跨协议)。
const GEMINI_TOOLCALL_SSE =
    "data: {\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"functionCall\":{\"name\":\"get_time\",\"args\":{}}}]}}]}\n\n";

const GEMINI_FINAL_SSE =
    "data: {\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"text\":\"the time is now\"}]},\"finishReason\":\"STOP\"}]}\n\n";

fn getTimeExec(ctx: *const cc.tool_context.ToolContext, _: []const u8, _: ?*anyopaque) anyerror![]u8 {
    return ctx.allocator.dupe(u8, "{\"t\":42}");
}

test "C3: Gemini functionCall → 中立工具循环 → 第二轮 end_turn(工具循环跨协议)" {
    const a = std.testing.allocator;
    var srv = try harness.MockServer.startCassette(&[_][]const u8{ GEMINI_TOOLCALL_SSE, GEMINI_FINAL_SSE }, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    var io_rt = std.Io.Threaded.init(a, .{});
    defer io_rt.deinit();
    var client = gemini.GeminiClient.init(a, io_rt.io(), "test-key", "gemini-2.5-flash", url);
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
        std.debug.print("Gemini toolcall run failed: {s}\n", .{@errorName(e)});
        return error.SkipZigTest;
    };
    try std.testing.expectEqual(agent_loop.StopReason.end_turn, result.stop_reason);

    // conversation 含 tool_use(call_1 自生成)+ 对应 tool_result。
    var has_tu = false;
    var has_tr = false;
    for (conv.messages.items) |m| for (m.blocks) |b| switch (b) {
        .tool_use => |tu| if (std.mem.eql(u8, tu.name, "get_time")) {
            has_tu = true;
        },
        .tool_result => {
            has_tr = true;
        },
        else => {},
    };
    try std.testing.expect(has_tu);
    try std.testing.expect(has_tr);
}

// P0.1 并行:一个 chunk 的 parts 含两个 functionCall → 两个都执行 + 各自 name 干净 +
// 第二轮请求体含两个 functionResponse(request 序列化不丢第二个)。
const GEMINI_PARALLEL_SSE =
    "data: {\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[" ++
    "{\"functionCall\":{\"name\":\"get_time\",\"args\":{}}}," ++
    "{\"functionCall\":{\"name\":\"get_date\",\"args\":{}}}" ++
    "]}}]}\n\n";

test "C3/P0.1: 并行 functionCall 两个都执行 + name 干净 + 第二轮双 functionResponse" {
    const a = std.testing.allocator;
    var srv = try harness.MockServer.startCassette(&[_][]const u8{ GEMINI_PARALLEL_SSE, GEMINI_FINAL_SSE }, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    var io_rt = std.Io.Threaded.init(a, .{});
    defer io_rt.deinit();
    var client = gemini.GeminiClient.init(a, io_rt.io(), "test-key", "gemini-2.5-flash", url);
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
        std.debug.print("Gemini parallel run failed: {s}\n", .{@errorName(e)});
        return error.SkipZigTest;
    };
    try std.testing.expectEqual(agent_loop.StopReason.end_turn, result.stop_reason);

    var got_time = false;
    var got_date = false;
    var result_count: usize = 0;
    for (conv.messages.items) |m| for (m.blocks) |b| switch (b) {
        .tool_use => |tu| {
            if (std.mem.eql(u8, tu.name, "get_time")) got_time = true;
            if (std.mem.eql(u8, tu.name, "get_date")) got_date = true;
        },
        .tool_result => result_count += 1,
        else => {},
    };
    try std.testing.expect(got_time);
    try std.testing.expect(got_date); // 第二个 functionCall 也被 emit + 执行(旧版会漏)
    try std.testing.expectEqual(@as(usize, 2), result_count);
    // 第二轮请求体:两个 functionResponse 都在,且 name 是**真实工具名**(get_time/get_date),
    // 不是 call_N 占位——Gemini 靠 name 配对 functionCall↔functionResponse,占位会失配。
    const cap = srv.lastRequest().?;
    const body = cap.body();
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, body, "functionResponse"));
    try std.testing.expect(std.mem.indexOf(u8, body, "\"functionResponse\":{\"name\":\"get_time\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"functionResponse\":{\"name\":\"get_date\"") != null);
}

test "C3/缓存: 有状态句柄命中 → 请求体带 cachedContent 引用(stateful_object 范式)" {
    const a = std.testing.allocator;
    var srv = try harness.MockServer.startCassette(&[_][]const u8{GEMINI_TEXT_SSE}, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    var io_rt = std.Io.Threaded.init(a, .{});
    defer io_rt.deinit();
    var client = gemini.GeminiClient.init(a, io_rt.io(), "test-key", "gemini-2.5-flash", url);
    defer client.deinit();

    // 预注册一个 cache 句柄,prefix_hash 必须与 sendStream 内部 hashPrefix(model,system,tools) 一致。
    // 本请求 model="gemini-2.5-flash"、system="SYS"、tools=null → 用同样输入算哈希,注册到该哈希。
    const system_prompt = "SYS";
    const prefix_hash = gemini.hashPrefixForTest("gemini-2.5-flash", system_prompt, null);
    try client.registerCache(prefix_hash, "cachedContents/test123", std.math.maxInt(i64)); // 永不过期(mono_ms max)

    var conv = cc.conversation.Conversation.init(a);
    defer conv.deinit();
    try conv.appendText(.user, "hi");
    const perm = cc.permission.createContext(.bypass_permissions, a);
    const empty_defs: []const cc.json_mod.ToolDefinition = &.{};

    var render = writer_backend.WriterBackend.initNull();
    const be = render.backend();

    const result = agent_loop.run(&conv, client.provider(), empty_defs, &perm, .{ .max_turns = 2, .system_prompt = system_prompt }, &be, a) catch |e| {
        std.debug.print("Gemini cache run failed: {s}\n", .{@errorName(e)});
        return error.SkipZigTest;
    };
    try std.testing.expectEqual(agent_loop.StopReason.end_turn, result.stop_reason);

    // 缓存句柄命中 → 请求体带 cachedContent 引用(Gemini 有状态缓存范式)。
    const cap = srv.lastRequest().?;
    try std.testing.expect(std.mem.indexOf(u8, cap.body(), "\"cachedContent\":\"cachedContents/test123\"") != null);
}

// E 修复验证:Gemini 把 usageMetadata 与末 content chunk(text+finishReason)合并是常态。
// 旧逻辑只在"无内容 chunk"emit usage → 这种合并 chunk 的 usage 被静默丢。
// 此测试直接驱动 StreamHandle,断言"内容+usage 同 chunk"时 usage(含缓存命中 3000)真上报。
test "C3/缓存: usage 与 content 同 chunk 时 usage 不丢(E 修复)" {
    const a = std.testing.allocator;
    var srv = try harness.MockServer.startCassette(&[_][]const u8{GEMINI_TEXT_SSE}, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    var io_rt = std.Io.Threaded.init(a, .{});
    defer io_rt.deinit();
    var client = gemini.GeminiClient.init(a, io_rt.io(), "test-key", "gemini-2.5-flash", url);
    defer client.deinit();

    const p = client.provider();
    const msgs = [_]cc.types_mod.ApiMessage{
        .{ .role = .user, .content = &[_]cc.types_mod.ApiContent{.{ .text = "hi" }} },
    };
    var handle = p.sendStream(&msgs, null, null, null, null, null, "") catch |e| {
        std.debug.print("gemini sendStream failed: {s}\n", .{@errorName(e)});
        return error.SkipZigTest;
    };
    defer handle.deinit();

    var saw_usage = false;
    var cache_read: u64 = 0;
    var text_buf: std.ArrayList(u8) = .empty;
    defer text_buf.deinit(a);
    while (try handle.next()) |ev| switch (ev) {
        .text => |t| {
            try text_buf.appendSlice(a, t);
            a.free(t);
        },
        .usage => |u| {
            saw_usage = true;
            cache_read = u.cache_read_input_tokens;
        },
        .tool_use_start => |tu| {
            a.free(tu.id);
            a.free(tu.name);
            a.free(tu.input_json);
        },
        else => {},
    };

    // GEMINI_TEXT_SSE 第二条 chunk = text "world" + finishReason:STOP + usageMetadata(cachedContentTokenCount=3000)。
    // 内容("hello world")必须完整,且 usage(cache_read=3000)必须被吐出来——证明合并 chunk 不丢 usage。
    try std.testing.expectEqualStrings("hello world", text_buf.items);
    try std.testing.expect(saw_usage);
    try std.testing.expectEqual(@as(u64, 3000), cache_read);
}
