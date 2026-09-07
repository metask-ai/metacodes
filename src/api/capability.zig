//! Capability:provider+model 能力的单一真相源(P2)。
//!
//! 设计(见 metaknow root「多 Provider 分离架构设计」f5no2pxq9rqvs99t23x8 § capability 表):
//! cc 把 supports_web_search 之类判断散落各工具(if(provider==vertex && model.includes(opus-4)))
//! 是工程债。本模块集中成一张 [ProviderKind][model] -> CapabilitySet 的表/函数,工具与 agent_loop
//! 只问 supports(),绝不自己 if(model.includes)。
//!
//! 用法:Provider.supports(cap) 转调本模块的 supports(self.kind, self.model, cap)。一个工具在不
//! 支持的 provider 上 → 不进 API tools 数组(P3 接第二 provider 时由 tool-list build 据此门控;
//! 当前单 Anthropic provider 全支持, 门控未激活但表已就位)。

const std = @import("std");
const model_name = @import("model_name.zig");
const Capability = @import("provider.zig").Capability;
const model_adapter = @import("model_adapter.zig");

/// LLM 后端种类(决定能力矩阵走哪一行)。anthropic + openai 有真实矩阵(P3 写了真 Provider、
/// 验证过其 API);其它 provider(gemini/grok)加时再据实填,不预先猜测。
pub const ProviderKind = enum {
    anthropic,
    openai,
    gemini,
    other, // 尚未实现的 provider:能力保守 false(避免发它不认的请求)。
};

/// provider+model 是否支持某能力。**单一真相源**——所有 supports 查询走这里,不在别处 if(model)。
/// 只有真验证过的 provider 给真矩阵;other 一律 false(不猜未实现 provider 的能力)。
pub fn supports(kind: ProviderKind, model: []const u8, cap: Capability) bool {
    return switch (kind) {
        .anthropic => anthropicSupports(model, cap),
        .openai => openaiSupports(model, cap),
        .gemini => geminiSupports(model, cap),
        .other => false,
    };
}

/// Gemini 能力矩阵(C3 真填:Gemini 用 function calling + responseSchema structured output + 隐式/显式
/// context caching;无 Anthropic 式 server-tool web_search)。
/// Gemini 能力矩阵
fn geminiSupports(model: []const u8, cap: Capability) bool {
    return switch (cap) {
        .prompt_cache => true, // 隐式 + 显式 context caching(有状态对象)——本 client 实现了句柄表机制
        .web_search, .server_tool => false, // Gemini grounding 与 Anthropic server-tool 语义不同, 保守 false
        .extended_thinking => false, // thinking(thought parts)未接, 保守 false
        .structured_output => true, // responseSchema JSON
        .reasoning_content => false, // Gemini 用 thought_summary+signature,非平级字段
        .image_input => model_adapter.profileFor(.gemini, model).supports_image_input,
    };
}

/// OpenAI 兼容端点能力矩阵。按 model 子串区分:
/// - OpenAI 原生:无 reasoning_content(只 reasoning_tokens 计数)
/// - GLM-5/Kimi K3/DeepSeek/Qwen3:有 reasoning_content 平级字段
/// - Mistral:ThinkChunk(content[] 里的 thinking 类型,语义接近 reasoning_content)
fn openaiSupports(model: []const u8, cap: Capability) bool {
    return switch (cap) {
        .structured_output => !hasSubstr(model, "glm-5") and !hasSubstr(model, "glm-4"), // GLM-5 仅 json_object
        .web_search, .server_tool => false, // 无 Anthropic 式 server-tool web_search
        .prompt_cache => hasSubstr(model, "kimi") or hasSubstr(model, "k2") or hasSubstr(model, "moonshot"), // K3 prompt_cache_key
        .extended_thinking => false, // o1/o3 的 reasoning 与 Anthropic interleaved thinking 不同
        .reasoning_content => blk: {
            // OpenAI 原生(GPT-4o/o1/o3/GPT-5)不返回 reasoning_content;兼容端点返回。
            const compat = hasSubstr(model, "glm-") or hasSubstr(model, "kimi") or hasSubstr(model, "k2") or
                hasSubstr(model, "moonshot") or hasSubstr(model, "deepseek") or hasSubstr(model, "qwen3") or
                hasSubstr(model, "qwen-3") or hasSubstr(model, "mistral") or hasSubstr(model, "magistral");
            break :blk compat;
        },
        // 单一真相在 ModelProfile(序列化守门同源),此处转发查表。
        .image_input => model_adapter.profileFor(.openai, model).supports_image_input,
    };
}

/// Anthropic 能力矩阵(对齐 cc:web_search/thinking/structured-output 按 Claude 版本)。
fn anthropicSupports(model: []const u8, cap: Capability) bool {
    const claude4 = isClaude4(model);
    return switch (cap) {
        // 第一方 Anthropic 端点:server-tool web_search 全模型可用(对齐 cc firstParty=true)。
        .web_search, .server_tool => true,
        // prompt caching:Anthropic 全模型(ephemeral cache_control)。
        .prompt_cache => true,
        // extended thinking(interleaved):Claude 4.x(及 3.7),3.x 旧版不支持。
        .extended_thinking => claude4 or hasSubstr(model, "claude-3-7"),
        // structured outputs:Claude 4.x 子集(对齐 cc modelSupportsStructuredOutputs)。
        .structured_output => claude4,
        // Claude 用 content[] 里的 thinking block,非平级 reasoning_content 字段。
        .reasoning_content => false,
        .image_input => model_adapter.profileFor(.anthropic, model).supports_image_input,
    };
}

/// 一个工具需要 provider 具备哪个能力才能用(null = 无特殊要求, 任何 provider 都能用)。
/// **真消费者**:agent_loop 发请求前据此 + provider.supports 把不支持的工具从 tools 数组剔除
/// (对齐 cc isEnabled:provider 不支持 web_search → 该工具不进清单)。当前单 Anthropic 全支持,
/// 故无工具被剔(行为零变化),但门控路径活着;P3 加不支持 web_search 的 provider 时自动剔除。
pub fn requiredCapability(tool_name: []const u8) ?Capability {
    if (std.mem.eql(u8, tool_name, "WebSearch")) return .web_search;
    return null;
}

fn isClaude4(model: []const u8) bool {
    return hasSubstr(model, "claude-opus-4") or hasSubstr(model, "claude-sonnet-4") or hasSubstr(model, "claude-haiku-4");
}
fn hasSubstr(haystack: []const u8, needle: []const u8) bool {
    return model_name.containsIgnoreCase(haystack, needle);
}

// ── 测试:能力矩阵是单一真相源(断言关键格子)──────────────────────────────────
test "Anthropic 能力矩阵" {
    // Claude 4.x:web_search/thinking/structured-output 全支持。
    try std.testing.expect(supports(.anthropic, "claude-sonnet-4-20250514", .web_search));
    try std.testing.expect(supports(.anthropic, "claude-opus-4-1", .extended_thinking));
    try std.testing.expect(supports(.anthropic, "claude-sonnet-4-6", .structured_output));
    try std.testing.expect(supports(.anthropic, "claude-haiku-4-5", .prompt_cache));
    // Claude 3.5:web_search/cache 有, structured-output 无(非 4.x)。
    try std.testing.expect(supports(.anthropic, "claude-3-5-haiku-20241022", .web_search));
    try std.testing.expect(!supports(.anthropic, "claude-3-5-haiku-20241022", .structured_output));
}

test "other provider(未实现)保守全 false" {
    // 不预先猜测未实现 provider 的能力——一律 false, 避免发它不认的请求。
    try std.testing.expect(!supports(.other, "mystery", .structured_output));
    try std.testing.expect(!supports(.other, "mystery", .web_search));
}

test "OpenAI 能力矩阵(P3 据实)" {
    try std.testing.expect(supports(.openai, "gpt-4o", .structured_output)); // function calling/json mode
    try std.testing.expect(!supports(.openai, "gpt-4o", .web_search)); // 无 Anthropic 式 server-tool
    try std.testing.expect(!supports(.openai, "gpt-4o", .prompt_cache));
}

test "Gemini 能力矩阵(C3 据实)" {
    try std.testing.expect(supports(.gemini, "gemini-2.5-flash", .structured_output)); // responseSchema
    try std.testing.expect(supports(.gemini, "gemini-2.5-pro", .prompt_cache)); // context caching
    try std.testing.expect(!supports(.gemini, "gemini-2.5-flash", .web_search)); // grounding 语义不同, 保守
    try std.testing.expect(!supports(.gemini, "gemini-2.5-flash", .extended_thinking));
}

test "image_input 能力矩阵转发 ModelProfile(单一真相)" {
    try std.testing.expect(supports(.anthropic, "claude-sonnet-4", .image_input));
    try std.testing.expect(supports(.openai, "gpt-4o", .image_input));
    try std.testing.expect(supports(.gemini, "gemini-2.5-flash", .image_input));
    try std.testing.expect(!supports(.openai, "deepseek-chat", .image_input));
    try std.testing.expect(!supports(.other, "mystery", .image_input));
}
