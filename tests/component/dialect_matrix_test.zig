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

test "原则2: glm-5.2 reasoning_effort=high → thinking:{type:enabled}(GLM 方言)" {
    const a = std.testing.allocator;
    const msgs = [_]types.ApiMessage{
        .{ .role = .user, .content = &[_]types.ApiContent{.{ .text = "hi" }} },
    };
    const body = try openai.serializeOpenAIRequest(a, "glm-5.2", &msgs, "sys", null, .high, null);
    defer a.free(body);
    // GLM 方言:thinking:{type:enabled}(非 OpenAI 原生 reasoning_effort)
    try std.testing.expect(std.mem.indexOf(u8, body, "\"thinking\":{\"type\":\"enabled\"}") != null);
    // GLM 不该发 OpenAI 原生 reasoning_effort(那是 OpenAINative dialect)
    try std.testing.expect(std.mem.indexOf(u8, body, "\"reasoning_effort\"") == null);
}

test "原则2: kimi-k2 reasoning_effort=high → thinking:{type,keep,effort}(K3 方言)" {
    const a = std.testing.allocator;
    const msgs = [_]types.ApiMessage{
        .{ .role = .user, .content = &[_]types.ApiContent{.{ .text = "hi" }} },
    };
    const body = try openai.serializeOpenAIRequest(a, "kimi-k2", &msgs, "sys", null, .high, null);
    defer a.free(body);
    // K3 方言:thinking:{type:enabled,keep:all,effort:high}
    try std.testing.expect(std.mem.indexOf(u8, body, "\"thinking\":{") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"type\":\"enabled\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"keep\":\"all\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"effort\":\"high\"") != null);
}

test "原则2: deepseek-chat reasoning_effort=high → reasoning_effort + thinking:{type:enabled}(DeepSeek 方言)" {
    const a = std.testing.allocator;
    const msgs = [_]types.ApiMessage{
        .{ .role = .user, .content = &[_]types.ApiContent{.{ .text = "hi" }} },
    };
    const body = try openai.serializeOpenAIRequest(a, "deepseek-chat", &msgs, "sys", null, .high, null);
    defer a.free(body);
    // DeepSeek 方言:顶层 reasoning_effort + thinking:{type:enabled}(双发)
    try std.testing.expect(std.mem.indexOf(u8, body, "\"reasoning_effort\":\"high\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"thinking\":{\"type\":\"enabled\"}") != null);
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

test "无副作用: gemini reasoning_effort=null 不发 generation_config(自适应)" {
    const a = std.testing.allocator;
    const msgs = [_]types.ApiMessage{
        .{ .role = .user, .content = &[_]types.ApiContent{.{ .text = "hi" }} },
    };
    const body = try gemini.serializeGeminiRequest(a, &msgs, "sys", null, null, "gemini-2.5-pro", null, null);
    defer a.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "generation_config") == null);
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
        .{ .model = "kimi-k2", .kind = .openai },
        .{ .model = "deepseek-chat", .kind = .openai },
        .{ .model = "qwen3-235b-a22b", .kind = .openai },
        .{ .model = "mistral-large-2411", .kind = .openai },
        .{ .model = "claude-opus-4", .kind = .anthropic },
        .{ .model = "gemini-2.5-pro", .kind = .gemini },
    }) |entry| {
        const profile = adapter.profileFor(entry.kind, entry.model);
        const dialect = dialect_mod.dialectFor(entry.kind, entry.model);
        // dialect.profileFor 必须与 adapter.profileFor 一致(同方言选择)
        const dialect_profile = dialect.profileFor(entry.kind, entry.model);
        try std.testing.expectEqual(profile.thinking_mode, dialect_profile.thinking_mode);
        try std.testing.expectEqual(profile.tool_choice_support, dialect_profile.tool_choice_support);
        try std.testing.expectEqual(profile.response_format_support, dialect_profile.response_format_support);
        try std.testing.expectEqual(profile.supports_prompt_cache_key, dialect_profile.supports_prompt_cache_key);
        try std.testing.expectEqual(profile.supports_parallel_tool_calls, dialect_profile.supports_parallel_tool_calls);
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
        try std.testing.expect(std.mem.indexOf(u8, body, "\"keep\":\"all\"") == null); // K3 字段不泄漏
        try std.testing.expect(std.mem.indexOf(u8, body, "\"enable_thinking\"") == null); // Qwen 字段不泄漏
    }
    // glm-5.2:只 thinking:{type:enabled},无 reasoning_effort,无 keep,无 enable_thinking
    {
        const body = try openai.serializeOpenAIRequest(a, "glm-5.2", &msgs, "sys", null, .high, null);
        defer a.free(body);
        try std.testing.expect(std.mem.indexOf(u8, body, "\"thinking\":{\"type\":\"enabled\"}") != null);
        try std.testing.expect(std.mem.indexOf(u8, body, "\"reasoning_effort\"") == null);
        try std.testing.expect(std.mem.indexOf(u8, body, "\"keep\":\"all\"") == null);
        try std.testing.expect(std.mem.indexOf(u8, body, "\"enable_thinking\"") == null);
    }
    // kimi-k2:thinking:{type,keep,effort},无 enable_thinking
    {
        const body = try openai.serializeOpenAIRequest(a, "kimi-k2", &msgs, "sys", null, .high, null);
        defer a.free(body);
        try std.testing.expect(std.mem.indexOf(u8, body, "\"keep\":\"all\"") != null);
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
