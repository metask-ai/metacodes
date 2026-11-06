//! 方言评估矩阵:L2 端到端断言方言三原则。
//!
//! 原则 1(不影响已有通用特性):通用模型(gpt-4o/claude/gemini)请求体不含方言字段。
//! 原则 2(模型支持时自然启用,无副作用):方言模型(glm/kimi/deepseek/mistral)请求体含方言字段;
//!   通用模型不发方言字段(无副作用)。
//! 原则 3:基于 1+2,mock + 评估矩阵覆盖。
//!
//! 方法:直接调 serializeOpenAIRequest / serializeGeminiRequest / serializeMessagesRequest,
//! 断言 body 含/不含方言字段。不需 MockServer(序列化是纯函数,无网络)。

const std = @import("std");
const cc = @import("cc");

const openai = cc.api_openai;
const gemini = cc.api_gemini;
const dialect_mod = cc.api_dialect;
const request = cc.api_request;
const adapter = cc.model_adapter;
const types = cc.types_mod;
const json_mod = cc.json_mod;

// ── 原则 1:通用模型不发方言字段(不影响已有通用特性)─────────────────────────────

test "原则1: gpt-4o 不发 thinking 字段(通用模型,thinking_mode=none)" {
    const a = std.testing.allocator;
    const msgs = [_]types.ApiMessage{
        .{ .role = .user, .content = &[_]types.ApiContent{.{ .text = "hi" }} },
    };
    // reasoning_effort=null → dialect.serializeThinking no-op
    const body = try openai.serializeOpenAIRequest(a, "gpt-4o", &msgs, "sys", null, null, null);
    defer a.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "reasoning_effort") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "thinking") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "enable_thinking") == null);
}

test "原则1: gpt-4o reasoning_effort=high 发 effort(OpenAI 原生通用字段,非方言)" {
    // reasoning_effort 是 OpenAI 原生通用字段(所有 OpenAI-compatible 都认),非方言扩展。
    // 但 GLM/Kimi/DeepSeek 的 thinking:{type,...} 是方言扩展。gpt-4o 只发通用 effort。
    const a = std.testing.allocator;
    const msgs = [_]types.ApiMessage{
        .{ .role = .user, .content = &[_]types.ApiContent{.{ .text = "hi" }} },
    };
    const body = try openai.serializeOpenAIRequest(a, "gpt-4o", &msgs, "sys", null, .high, null);
    defer a.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"reasoning_effort\":\"high\"") != null);
    // gpt-4o 不该发方言字段 thinking:{type,...}(那是 GLM/DeepSeek 的)
    try std.testing.expect(std.mem.indexOf(u8, body, "\"thinking\":") == null);
}

test "原则1: gpt-4o 不发 prompt_cache_key(能力守门 false)" {
    const a = std.testing.allocator;
    const msgs = [_]types.ApiMessage{
        .{ .role = .user, .content = &[_]types.ApiContent{.{ .text = "hi" }} },
    };
    const body = try openai.serializeOpenAIRequest(a, "gpt-4o", &msgs, "sys", null, null, null);
    defer a.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "prompt_cache_key") == null);
}

test "原则1: gpt-4o 不发 parallel_tool_calls(能力守门 false)" {
    const a = std.testing.allocator;
    const msgs = [_]types.ApiMessage{
        .{ .role = .user, .content = &[_]types.ApiContent{.{ .text = "hi" }} },
    };
    const body = try openai.serializeOpenAIRequest(a, "gpt-4o", &msgs, "sys", null, null, null);
    defer a.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "parallel_tool_calls") == null);
}

test "原则1: gemini-2.5-pro reasoning_effort=null 不发 thinking_level" {
    const a = std.testing.allocator;
    const msgs = [_]types.ApiMessage{
        .{ .role = .user, .content = &[_]types.ApiContent{.{ .text = "hi" }} },
    };
    const body = try gemini.serializeGeminiRequest(a, &msgs, "sys", null, null, "gemini-2.5-pro", null, null);
    defer a.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "thinking_level") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "generation_config") == null);
}

test "原则1: gemini-2.5-pro 不发 prompt_cache_key / parallel_tool_calls" {
    const a = std.testing.allocator;
    const msgs = [_]types.ApiMessage{
        .{ .role = .user, .content = &[_]types.ApiContent{.{ .text = "hi" }} },
    };
    const body = try gemini.serializeGeminiRequest(a, &msgs, "sys", null, null, "gemini-2.5-pro", null, null);
    defer a.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "prompt_cache_key") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "parallel_tool_calls") == null);
}

test "原则1: claude-opus-4 不发 reasoning_effort / prompt_cache_key / parallel_tool_calls" {
    // Claude 走 Anthropic 协议,方言字段都是 OpenAI 协议的,Claude 不发。
    const a = std.testing.allocator;
    const msgs = [_]types.ApiMessage{
        .{ .role = .user, .content = &[_]types.ApiContent{.{ .text = "hi" }} },
    };
    const body = try request.serializeMessagesRequest(.{
        .model = "claude-opus-4",
        .messages = &msgs,
        .system = "sys",
    }, a);
    defer a.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "reasoning_effort") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "prompt_cache_key") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "parallel_tool_calls") == null);
    // Claude 用 thinking:{type:adaptive} 是 Anthropic 原生字段,不是方言扩展。
    // adaptive 模式不发 thinking 字块(effort=null → default adaptive)。
    try std.testing.expect(std.mem.indexOf(u8, body, "thinking") == null);
}

// ── 原则 2:方言模型自然启用方言字段(模型支持时启用)───────────────────────────

test "原则2: glm-5.2 reasoning_effort=high → thinking:{type:enabled} + 顶层 reasoning_effort(GLM 方言)" {
    const a = std.testing.allocator;
    const msgs = [_]types.ApiMessage{
        .{ .role = .user, .content = &[_]types.ApiContent{.{ .text = "hi" }} },
    };
    const body = try openai.serializeOpenAIRequest(a, "glm-5.2", &msgs, "sys", null, .high, null);
    defer a.free(body);
    // GLM-5.2 方言:thinking:{type:enabled} + 顶层 reasoning_effort(7 档透传,服务端自映射)
    // 来源:docs.z.ai/guides/capabilities/thinking(2026-08 KnowForge 调研)。
    try std.testing.expect(std.mem.indexOf(u8, body, "\"thinking\":{\"type\":\"enabled\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"reasoning_effort\":\"high\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "clear_thinking") != null); // preserved thinking
    // 不该发 Kimi K2.6 的 keep 字段
    try std.testing.expect(std.mem.indexOf(u8, body, "\"keep\":\"all\"") == null);
}

test "原则2: deepseek-chat reasoning_effort=high → reasoning_effort + thinking:{type:enabled}(DeepSeek V4 方言)" {
    const a = std.testing.allocator;
    const msgs = [_]types.ApiMessage{
        .{ .role = .user, .content = &[_]types.ApiContent{.{ .text = "hi" }} },
    };
    const body = try openai.serializeOpenAIRequest(a, "deepseek-chat", &msgs, "sys", null, .high, null);
    defer a.free(body);
    // DeepSeek V4 方言:顶层 reasoning_effort + thinking:{type:enabled}(双发,effort 2 档 high/max)
    // 来源:api-docs.deepseek.com/guides/thinking_mode(2026-08 KnowForge 调研)。
    try std.testing.expect(std.mem.indexOf(u8, body, "\"reasoning_effort\":\"high\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"thinking\":{\"type\":\"enabled\"}") != null);
}

test "原则2: deepseek-chat reasoning_effort=xhigh → reasoning_effort:\"max\"(V4 修正)" {
    const a = std.testing.allocator;
    const msgs = [_]types.ApiMessage{
        .{ .role = .user, .content = &[_]types.ApiContent{.{ .text = "hi" }} },
    };
    const body = try openai.serializeOpenAIRequest(a, "deepseek-chat", &msgs, "sys", null, .xhigh, null);
    defer a.free(body);
    // DeepSeek V4 文档明确 xhigh → max(此前误为 high,2026-08 KnowForge 调研修正)
    try std.testing.expect(std.mem.indexOf(u8, body, "\"reasoning_effort\":\"max\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"reasoning_effort\":\"high\"") == null);
}

test "原则2: kimi-k3 effort=high → 顶层 reasoning_effort,不发 thinking body(K3 方言)" {
    const a = std.testing.allocator;
    const msgs = [_]types.ApiMessage{
        .{ .role = .user, .content = &[_]types.ApiContent{.{ .text = "hi" }} },
    };
    const body = try openai.serializeOpenAIRequest(a, "kimi-k3", &msgs, "sys", null, .high, null);
    defer a.free(body);
    // Kimi K3:顶层 reasoning_effort(low/high/max),不发 thinking:{} body(那是 K2.6)
    // 来源:platform.kimi.ai/docs/guide/kimi-k3-quickstart(2026-08 KnowForge 调研)。
    try std.testing.expect(std.mem.indexOf(u8, body, "\"reasoning_effort\":\"high\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"thinking\":") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"keep\":\"all\"") == null);
}

test "原则2: kimi-k3 effort=null → reasoning_effort:\"max\"(K3 默认 max)" {
    const a = std.testing.allocator;
    const msgs = [_]types.ApiMessage{
        .{ .role = .user, .content = &[_]types.ApiContent{.{ .text = "hi" }} },
    };
    const body = try openai.serializeOpenAIRequest(a, "kimi-k3", &msgs, "sys", null, null, null);
    defer a.free(body);
    // K3 默认 max(不能关 thinking)
    try std.testing.expect(std.mem.indexOf(u8, body, "\"reasoning_effort\":\"max\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"thinking\":") == null);
}

test "原则2: kimi-k2 effort=high → thinking:{type,keep}(K2.6 方言,与 K3 区分)" {
    const a = std.testing.allocator;
    const msgs = [_]types.ApiMessage{
        .{ .role = .user, .content = &[_]types.ApiContent{.{ .text = "hi" }} },
    };
    const body = try openai.serializeOpenAIRequest(a, "kimi-k2", &msgs, "sys", null, .high, null);
    defer a.free(body);
    // K2.6:thinking:{type,keep} body(不是 K3 的顶层 reasoning_effort);K2.6 的 thinking
    // 对象没有 effort(platform.kimi.ai/docs/api/chat,2026-11)。
    try std.testing.expect(std.mem.indexOf(u8, body, "\"thinking\":{") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"type\":\"enabled\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"keep\":\"all\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"effort\"") == null);
    // K2.6 不该发顶层 reasoning_effort(那是 K3 的)
    try std.testing.expect(std.mem.indexOf(u8, body, "\"reasoning_effort\":") == null);
}

test "原则2: gemini-2.5-pro reasoning_effort=high → thinking_level high(Gemini 方言)" {
    const a = std.testing.allocator;
    const msgs = [_]types.ApiMessage{
        .{ .role = .user, .content = &[_]types.ApiContent{.{ .text = "hi" }} },
    };
    const body = try gemini.serializeGeminiRequest(a, &msgs, "sys", null, null, "gemini-2.5-pro", null, .high);
    defer a.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"generation_config\":{\"thinking_level\":\"high\"}") != null);
}

test "原则2: mistral-large parallel_tool_calls=true → 发 wire(Mistral 方言)" {
    // Mistral 独有 parallel_tool_calls 显式控制。通过 dialect.serializeParallelToolCalls 验证。
    const a = std.testing.allocator;
    const d = dialect_mod.dialectFor(.openai, "mistral-large");
    const p = d.profileFor(.openai, "mistral-large");
    try std.testing.expect(p.supports_parallel_tool_calls);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    const got = try d.serializeParallelToolCalls(p, true, &out, a);
    try std.testing.expect(got);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"parallel_tool_calls\":true") != null);
}

test "原则2: kimi-k2 prompt_cache_key 能力守门=true(K3 显式 cache 提示)" {
    // Kimi K3 是唯一 supports_prompt_cache_key=true 的方言模型。
    const a = std.testing.allocator;
    const d = dialect_mod.dialectFor(.openai, "kimi-k2");
    const p = d.profileFor(.openai, "kimi-k2");
    try std.testing.expect(p.supports_prompt_cache_key);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    const got = try d.serializePromptCacheKey(p, "session-abc", &out, a);
    try std.testing.expect(got);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"prompt_cache_key\":\"session-abc\"") != null);
}

// ── 原则 2 续:无副作用(null 不发、能力守门降级)──────────────────────────────

test "无副作用: tool_choice=null 不发 tool_choice 字段(所有模型)" {
    const a = std.testing.allocator;
    const msgs = [_]types.ApiMessage{
        .{ .role = .user, .content = &[_]types.ApiContent{.{ .text = "hi" }} },
    };
    // gpt-4o
    {
        const body = try openai.serializeOpenAIRequest(a, "gpt-4o", &msgs, "sys", null, null, null);
        defer a.free(body);
        try std.testing.expect(std.mem.indexOf(u8, body, "tool_choice") == null);
    }
    // glm-5.2
    {
        const body = try openai.serializeOpenAIRequest(a, "glm-5.2", &msgs, "sys", null, null, null);
        defer a.free(body);
        try std.testing.expect(std.mem.indexOf(u8, body, "tool_choice") == null);
    }
    // gemini
    {
        const body = try gemini.serializeGeminiRequest(a, &msgs, "sys", null, null, "gemini-2.5-pro", null, null);
        defer a.free(body);
        try std.testing.expect(std.mem.indexOf(u8, body, "tool_config") == null);
    }
}

test "无副作用: GLM-5 tool_choice=required 降级为 auto(能力守门,不破坏请求)" {
    const a = std.testing.allocator;
    const msgs = [_]types.ApiMessage{
        .{ .role = .user, .content = &[_]types.ApiContent{.{ .text = "hi" }} },
    };
    const tc = json_mod.ToolChoice{ .type = "required" };
    const body = try openai.serializeOpenAIRequest(a, "glm-5.2", &msgs, "sys", null, null, tc);
    defer a.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"tool_choice\":\"auto\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"tool_choice\":\"required\"") == null);
}

test "无副作用: GLM-5 tool_choice=none 不降级(通用语义)" {
    const a = std.testing.allocator;
    const msgs = [_]types.ApiMessage{
        .{ .role = .user, .content = &[_]types.ApiContent{.{ .text = "hi" }} },
    };
    const tc = json_mod.ToolChoice{ .type = "none" };
    const body = try openai.serializeOpenAIRequest(a, "glm-5.2", &msgs, "sys", null, null, tc);
    defer a.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"tool_choice\":\"none\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"tool_choice\":\"auto\"") == null);
}

test "无副作用: GLM-5 response_format=json_schema 降级为 json_object(能力守门)" {
    const a = std.testing.allocator;
    const d = dialect_mod.dialectFor(.openai, "glm-5.2");
    const p = d.profileFor(.openai, "glm-5.2");
    try std.testing.expectEqual(adapter.ResponseFormatSupport.json_object_only, p.response_format_support);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    const got = try d.serializeResponseFormat(p, .{ .kind = .json_schema, .schema = "{\"type\":\"object\"}" }, &out, a);
    try std.testing.expect(got);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"response_format\":{\"type\":\"json_object\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "json_schema") == null);
}

test "无副作用: gemini 2.5 reasoning_effort=null 不发 generation_config(可关)" {
    const a = std.testing.allocator;
    const msgs = [_]types.ApiMessage{
        .{ .role = .user, .content = &[_]types.ApiContent{.{ .text = "hi" }} },
    };
    const body = try gemini.serializeGeminiRequest(a, &msgs, "sys", null, null, "gemini-2.5-pro", null, null);
    defer a.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "generation_config") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "thinking_level") == null);
}

test "无副作用: gemini 3.1 Pro reasoning_effort=null 不发 thinking_level(用模型默认)" {
    const a = std.testing.allocator;
    const msgs = [_]types.ApiMessage{
        .{ .role = .user, .content = &[_]types.ApiContent{.{ .text = "hi" }} },
    };
    const body = try gemini.serializeGeminiRequest(a, &msgs, "sys", null, null, "gemini-3.1-pro", null, null);
    defer a.free(body);
    // An unset level leaves the model's default (high on 3.1 Pro), not `low`.
    try std.testing.expect(std.mem.indexOf(u8, body, "thinking_level") == null);
}

// ── 原则 3:dialectFor + profileFor 一致性(同 model 选同 dialect)──────────────────

test "一致性: dialectFor 与 profileFor 对同 model 选同方言(6 个 OpenAI dialect)" {
    // 如果 dialectFor 认为 glm-5.2 是 OpenAINative 但 profileFor 认为是 Glm,
    // serializeThinking 会用 OpenAI 格式发给 GLM 服务端 → 服务端拒。
    // 这个测试断言两个查表路径对同 model 选一致方言。
    inline for ([_]struct { model: []const u8, kind: adapter.ProviderKind }{
        .{ .model = "gpt-4o", .kind = .openai },
        .{ .model = "glm-5.2", .kind = .openai },
        .{ .model = "kimi-k3", .kind = .openai },
        .{ .model = "kimi-k2", .kind = .openai },
        .{ .model = "deepseek-chat", .kind = .openai },
        .{ .model = "qwen3-235b-a22b", .kind = .openai },
        .{ .model = "mistral-large-2411", .kind = .openai },
        .{ .model = "claude-opus-4", .kind = .anthropic },
        .{ .model = "gemini-2.5-pro", .kind = .gemini },
        .{ .model = "gemini-3.1-pro", .kind = .gemini },
    }) |entry| {
        const profile = adapter.profileFor(entry.kind, entry.model);
        const dialect = dialect_mod.dialectFor(entry.kind, entry.model);
        const dialect_profile = dialect.profileFor(entry.kind, entry.model);
        try std.testing.expectEqual(profile.thinking_mode, dialect_profile.thinking_mode);
        try std.testing.expectEqual(profile.tool_choice_support, dialect_profile.tool_choice_support);
        try std.testing.expectEqual(profile.response_format_support, dialect_profile.response_format_support);
        try std.testing.expectEqual(profile.supports_prompt_cache_key, dialect_profile.supports_prompt_cache_key);
        try std.testing.expectEqual(profile.supports_parallel_tool_calls, dialect_profile.supports_parallel_tool_calls);
        try std.testing.expectEqual(profile.cannot_disable_thinking, dialect_profile.cannot_disable_thinking);
    }
}

// ── 原则 3 续:方言字段不泄漏到非方言模型(交叉矩阵)──────────────────────────────

test "交叉矩阵: 各模型 reasoning_effort=high 的 thinking 字段输出差异" {
    // 这是最关键的交叉矩阵测试:同 effort=high,不同模型输出不同方言字段。
    // 断言每个模型只发自己方言的字段,不泄漏其它方言字段。
    const a = std.testing.allocator;
    const msgs = [_]types.ApiMessage{
        .{ .role = .user, .content = &[_]types.ApiContent{.{ .text = "hi" }} },
    };
    // gpt-4o:只 reasoning_effort,无 thinking
    {
        const body = try openai.serializeOpenAIRequest(a, "gpt-4o", &msgs, "sys", null, .high, null);
        defer a.free(body);
        try std.testing.expect(std.mem.indexOf(u8, body, "\"reasoning_effort\":\"high\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, body, "\"thinking\":") == null);
        try std.testing.expect(std.mem.indexOf(u8, body, "\"keep\":\"all\"") == null); // K2.6 字段不泄漏
        try std.testing.expect(std.mem.indexOf(u8, body, "\"enable_thinking\"") == null); // Qwen 字段不泄漏
    }
    // glm-5.2:thinking:{type:enabled} + 顶层 reasoning_effort(双发),无 keep,无 enable_thinking
    {
        const body = try openai.serializeOpenAIRequest(a, "glm-5.2", &msgs, "sys", null, .high, null);
        defer a.free(body);
        try std.testing.expect(std.mem.indexOf(u8, body, "\"thinking\":{\"type\":\"enabled\"}") != null);
        try std.testing.expect(std.mem.indexOf(u8, body, "\"reasoning_effort\":\"high\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, body, "\"keep\":\"all\"") == null);
        try std.testing.expect(std.mem.indexOf(u8, body, "\"enable_thinking\"") == null);
    }
    // kimi-k3:顶层 reasoning_effort,不发 thinking:{} body,无 keep,无 enable_thinking
    {
        const body = try openai.serializeOpenAIRequest(a, "kimi-k3", &msgs, "sys", null, .high, null);
        defer a.free(body);
        try std.testing.expect(std.mem.indexOf(u8, body, "\"reasoning_effort\":\"high\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, body, "\"thinking\":") == null);
        try std.testing.expect(std.mem.indexOf(u8, body, "\"keep\":\"all\"") == null);
        try std.testing.expect(std.mem.indexOf(u8, body, "\"enable_thinking\"") == null);
    }
    // kimi-k2 (K2.6):thinking:{type,keep,effort} body,无顶层 reasoning_effort,无 enable_thinking
    {
        const body = try openai.serializeOpenAIRequest(a, "kimi-k2", &msgs, "sys", null, .high, null);
        defer a.free(body);
        try std.testing.expect(std.mem.indexOf(u8, body, "\"keep\":\"all\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, body, "\"reasoning_effort\":") == null); // K3 字段不泄漏到 K2.6
        try std.testing.expect(std.mem.indexOf(u8, body, "\"enable_thinking\"") == null);
    }
    // deepseek-chat:reasoning_effort + thinking:{type:enabled}(双发),无 keep,无 enable_thinking
    {
        const body = try openai.serializeOpenAIRequest(a, "deepseek-chat", &msgs, "sys", null, .high, null);
        defer a.free(body);
        try std.testing.expect(std.mem.indexOf(u8, body, "\"reasoning_effort\":\"high\"") != null);
        try std.testing.expect(std.mem.indexOf(u8, body, "\"thinking\":{\"type\":\"enabled\"}") != null);
        try std.testing.expect(std.mem.indexOf(u8, body, "\"keep\":\"all\"") == null);
        try std.testing.expect(std.mem.indexOf(u8, body, "\"enable_thinking\"") == null);
    }
    // qwen3:enable_thinking body,无 thinking:{type:...},无 keep,无 reasoning_effort
    {
        const body = try openai.serializeOpenAIRequest(a, "qwen3-235b-a22b", &msgs, "sys", null, .high, null);
        defer a.free(body);
        try std.testing.expect(std.mem.indexOf(u8, body, "\"enable_thinking\":true") != null);
        try std.testing.expect(std.mem.indexOf(u8, body, "\"thinking\":") == null);
        try std.testing.expect(std.mem.indexOf(u8, body, "\"keep\":\"all\"") == null);
        try std.testing.expect(std.mem.indexOf(u8, body, "\"reasoning_effort\"") == null);
    }
}

// ── Issue #421: reasoning passback ──────────────────────────────────────────
//
// The neutral IR now carries thinking blocks; each dialect decides. DeepSeek,
// Kimi and MiniMax M3+ get their reasoning back as `reasoning_content` on
// OpenAI chat, and a route declaring DeepSeek on the Anthropic wire gets its
// non-empty thinking blocks (tests/component/vendor_dialect_test.zig); every
// other request is byte-identical to the one without thinking, and Claude
// never sees an unsigned thinking block. Carried over from #429.

const harness = @import("harness");

const SECRET_REASONING = "need the clock first";

/// A tool turn after a thinking turn: user → assistant(thinking, text,
/// tool_use) → user(tool_result).
fn toolTurn(comptime with_thinking: bool) [3]types.ApiMessage {
    const assistant_blocks = if (with_thinking) &[_]types.ApiContent{
        .{ .thinking = SECRET_REASONING },
        .{ .text = "checking" },
        .{ .tool_use = .{ .id = "call_1", .name = "get_time", .input = "{}" } },
    } else &[_]types.ApiContent{
        .{ .text = "checking" },
        .{ .tool_use = .{ .id = "call_1", .name = "get_time", .input = "{}" } },
    };
    return .{
        .{ .role = .user, .content = &[_]types.ApiContent{.{ .text = "what time is it" }} },
        .{ .role = .assistant, .content = assistant_blocks },
        .{ .role = .user, .content = &[_]types.ApiContent{.{ .tool_result = .{ .tool_use_id = "call_1", .content = "{\"t\":42}" } }} },
    };
}

test "issue #421 (a): DeepSeek/Kimi/MiniMax OpenAI chat sends reasoning_content on the assistant message" {
    const a = std.testing.allocator;
    const msgs = toolTurn(true);
    inline for (.{ "deepseek-chat", "deepseek-v4-pro", "deepseek/deepseek-v4", "kimi-k3", "kimi-k2.6", "MiniMax-M3.1-Flash", "MiniMax-M3" }) |model| {
        const body = try openai.serializeOpenAIRequest(a, model, &msgs, "sys", null, .high, null);
        defer a.free(body);
        try std.testing.expect(std.mem.indexOf(
            u8,
            body,
            "{\"role\":\"assistant\",\"content\":\"checking\",\"reasoning_content\":\"" ++ SECRET_REASONING ++ "\",\"tool_calls\":[",
        ) != null);
        // Exactly once: never on user or tool messages.
        try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, body, "reasoning_content"));
    }
}

test "issue #421 (b): a route declaring DeepSeek on the Anthropic wire gets its thinking back in order, never an empty block" {
    const a = std.testing.allocator;
    const msgs = toolTurn(true);
    const d = dialect_mod.dialectForVendor(.anthropic, .deepseek, "house-deployment");
    const req = request.MessagesRequest{ .model = "house-deployment", .messages = &msgs, .system = "sys" };
    const body = try request.serializeMessagesRequestWithDialect(req, a, d);
    defer a.free(body);
    try std.testing.expect(std.mem.indexOf(
        u8,
        body,
        "{\"role\":\"assistant\",\"content\":[{\"type\":\"thinking\",\"thinking\":\"" ++ SECRET_REASONING ++ "\"},{\"type\":\"text\",\"text\":\"checking\"},{\"type\":\"tool_use\"",
    ) != null);

    // An empty thinking block is not reasoning: it is left out.
    const empty = [_]types.ApiMessage{
        .{ .role = .user, .content = &[_]types.ApiContent{.{ .text = "what time is it" }} },
        .{ .role = .assistant, .content = &[_]types.ApiContent{ .{ .thinking = "" }, .{ .text = "checking" } } },
    };
    const empty_body = try request.serializeMessagesRequestWithDialect(.{ .model = "house-deployment", .messages = &empty, .system = "sys" }, a, d);
    defer a.free(empty_body);
    try std.testing.expect(std.mem.indexOf(u8, empty_body, "\"type\":\"thinking\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, empty_body, "{\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"checking\"}]}") != null);
}

test "issue #421 (c): every other dialect's request bytes are unchanged by thinking blocks" {
    const a = std.testing.allocator;
    const with = toolTurn(true);
    const without = toolTurn(false);
    // OpenAI chat: native, catch-all and every non-echoing compatible dialect
    // (GLM/Qwen/MiniMax/Mistral return reasoning but do not ask for it back).
    inline for (.{ "gpt-4o", "gpt-5.2", "some-unknown-model", "glm-5.2", "qwen3-235b-a22b", "minimax-m2.5", "mistral-large" }) |model| {
        const got = try openai.serializeOpenAIRequest(a, model, &with, "sys", null, .high, null);
        defer a.free(got);
        const want = try openai.serializeOpenAIRequest(a, model, &without, "sys", null, .high, null);
        defer a.free(want);
        try std.testing.expectEqualStrings(want, got);
    }
    // OpenAI Responses.
    inline for (.{ "gpt-5.2", "deepseek-chat" }) |model| {
        const d = dialect_mod.dialectFor(.openai, model);
        const got = try openai.serializeOpenAIResponsesRequest(a, model, &with, "sys", null, .{}, d);
        defer a.free(got);
        const want = try openai.serializeOpenAIResponsesRequest(a, model, &without, "sys", null, .{}, d);
        defer a.free(want);
        try std.testing.expectEqualStrings(want, got);
    }
    // Gemini.
    inline for (.{ "gemini-2.5-pro", "gemini-3.1-pro" }) |model| {
        const got = try gemini.serializeGeminiRequest(a, &with, "sys", null, null, model, null, .high);
        defer a.free(got);
        const want = try gemini.serializeGeminiRequest(a, &without, "sys", null, null, model, null, .high);
        defer a.free(want);
        try std.testing.expectEqualStrings(want, got);
    }
    // Anthropic Messages without a declaration: Claude's dialect for every
    // name, DeepSeek's included (only a route declaring DeepSeek gets its
    // thinking back on this wire).
    inline for (.{ "claude-opus-4-6", "claude-sonnet-4-5", "claude-3-5-haiku-20241022", "glm-5.2", "kimi-k3", "deepseek-v4-pro", "test-model" }) |model| {
        const got = try request.serializeMessagesRequest(.{ .model = model, .messages = &with, .system = "sys", .reasoning_effort = .high }, a);
        defer a.free(got);
        const want = try request.serializeMessagesRequest(.{ .model = model, .messages = &without, .system = "sys", .reasoning_effort = .high }, a);
        defer a.free(want);
        try std.testing.expectEqualStrings(want, got);
        // The budget/journal projection keeps its bytes too.
        const got_projection = try request.serializeCanonicalRequestProjection(.{ .model = model, .messages = &with }, a);
        defer a.free(got_projection);
        const want_projection = try request.serializeCanonicalRequestProjection(.{ .model = model, .messages = &without }, a);
        defer a.free(want_projection);
        try std.testing.expectEqualStrings(want_projection, got_projection);
    }
}

test "issue #421 (d): Claude never receives an unsigned thinking block" {
    const a = std.testing.allocator;
    const msgs = toolTurn(true);
    inline for (.{ "claude-opus-4-6", "claude-sonnet-4-5", "claude-haiku-4-5", "claude-3-7-sonnet-20250219", "claude-deepseek-distill" }) |model| {
        const body = try request.serializeMessagesRequest(.{ .model = model, .messages = &msgs, .reasoning_effort = .high }, a);
        defer a.free(body);
        try std.testing.expect(std.mem.indexOf(u8, body, "\"type\":\"thinking\"") == null);
        try std.testing.expect(std.mem.indexOf(u8, body, SECRET_REASONING) == null);
    }
}

// ── L2 through agent_loop: the reasoning a model streamed comes back (or not) ──

const OPENAI_REASONING_TOOLCALL_SSE =
    "data: {\"choices\":[{\"delta\":{\"role\":\"assistant\",\"content\":null,\"reasoning_content\":\"need the \"}}]}\n\n" ++
    "data: {\"choices\":[{\"delta\":{\"reasoning_content\":\"clock first\"}}]}\n\n" ++
    "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_1\",\"type\":\"function\",\"function\":{\"name\":\"get_time\",\"arguments\":\"{}\"}}]}}]}\n\n" ++
    "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}]}\n\n" ++
    "data: [DONE]\n\n";

const OPENAI_FINAL_SSE =
    "data: {\"choices\":[{\"delta\":{\"content\":\"it is 42\"}}]}\n\n" ++
    "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n" ++
    "data: [DONE]\n\n";

const ANTHROPIC_THINKING_TOOLCALL_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":5,\"output_tokens\":0}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"thinking\",\"thinking\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"" ++ SECRET_REASONING ++ "\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"tu_1\",\"name\":\"get_time\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{}\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":1}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":3}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const ANTHROPIC_FINAL_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_2\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":9,\"output_tokens\":0}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"it is 42\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":2}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

fn getTimeExec(ctx: *const cc.tool_context.ToolContext, _: []const u8, _: ?*anyopaque) anyerror![]u8 {
    return ctx.allocator.dupe(u8, "{\"t\":42}");
}

const Wire = enum { openai_chat, anthropic };

/// Runs one tool turn and a final turn through `agent_loop.run` against a
/// mock server, then hands the second request's body to `check`.
fn runToolTurn(comptime wire: Wire, model: []const u8, check: *const fn ([]const u8) anyerror!void) !void {
    const a = std.testing.allocator;
    const cassette = switch (wire) {
        .openai_chat => [_][]const u8{ OPENAI_REASONING_TOOLCALL_SSE, OPENAI_FINAL_SSE },
        .anthropic => [_][]const u8{ ANTHROPIC_THINKING_TOOLCALL_SSE, ANTHROPIC_FINAL_SSE },
    };
    var srv = try harness.MockServer.startCassette(&cassette, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    var io_rt = @import("platform").signal.threadedIo(a, .{});
    defer io_rt.deinit();

    var dyn = cc.tools_dynamic.DynRegistry.init(a);
    defer dyn.deinit();
    try dyn.register("get_time", "Get current time", &.{}, getTimeExec, null, false);
    const tool_defs = try cc.tools.toToolDefinitionsFull(a, &dyn, null);
    defer a.free(tool_defs);

    var conv = cc.conversation.Conversation.init(a);
    defer conv.deinit();
    try conv.appendText(.user, "what time is it");
    const perm = cc.permission.createContext(.bypass_permissions, a);
    var render = cc.writer_backend.WriterBackend.initNull();
    const be = render.backend();

    const result = switch (wire) {
        .openai_chat => blk: {
            var client = openai.OpenAIClient.init(a, io_rt.io(), "test-key", model, url);
            defer client.deinit();
            break :blk try cc.agent_loop.run(&conv, client.provider(), tool_defs, &perm, .{ .max_turns = 4, .dyn_registry = &dyn }, &be, a);
        },
        .anthropic => blk: {
            var client = cc.client_mod.Client.initWithBaseUrl(a, io_rt.io(), "test-key", model, url);
            defer client.deinit();
            break :blk try cc.agent_loop.run(&conv, client.provider(), tool_defs, &perm, .{ .max_turns = 4, .dyn_registry = &dyn }, &be, a);
        },
    };
    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, result.stop_reason);
    try std.testing.expectEqual(@as(usize, 2), srv.requestCount());

    // The streamed reasoning is in the conversation either way.
    var saw_thinking = false;
    for (conv.messages.items) |m| for (m.blocks) |b| switch (b) {
        .thinking => |t| saw_thinking = saw_thinking or std.mem.eql(u8, t, SECRET_REASONING),
        else => {},
    };
    try std.testing.expect(saw_thinking);

    try check(srv.requestAt(1).?.body());
}

fn expectReasoningContentEchoed(body: []const u8) anyerror!void {
    try std.testing.expect(std.mem.indexOf(
        u8,
        body,
        "{\"role\":\"assistant\",\"content\":\"\",\"reasoning_content\":\"" ++ SECRET_REASONING ++ "\",\"tool_calls\":[{\"id\":\"call_1\"",
    ) != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, body, "reasoning_content"));
}

fn expectNoReasoning(body: []const u8) anyerror!void {
    try std.testing.expect(std.mem.indexOf(u8, body, "reasoning_content") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"type\":\"thinking\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, SECRET_REASONING) == null);
}

test "issue #421 L2 (a): DeepSeek, Kimi and MiniMax M3.1 get reasoning_content back after a tool turn" {
    try runToolTurn(.openai_chat, "deepseek-v4-pro", expectReasoningContentEchoed);
    try runToolTurn(.openai_chat, "kimi-k3", expectReasoningContentEchoed);
    try runToolTurn(.openai_chat, "MiniMax-M3.1-Flash", expectReasoningContentEchoed);
}

test "issue #421 L2 (c): GLM and Qwen stream reasoning but never get it back" {
    try runToolTurn(.openai_chat, "glm-5.2", expectNoReasoning);
    try runToolTurn(.openai_chat, "qwen3-235b-a22b", expectNoReasoning);
}

test "issue #421 L2 (d): Claude's next request carries no thinking block" {
    try runToolTurn(.anthropic, "claude-sonnet-4-5", expectNoReasoning);
}
