//! Model Adapter:按 (provider_kind, model) 返回 per-model 能力 profile。
//!
//! 设计(见 metaknow root「多 Provider 分离架构设计」):
//! 不把 per-model 参数塞进 Provider.sendStreamFn 签名(会膨胀且每加一个参数所有 provider 都要改)。
//! 而是引入纯数据 ModelProfile,各 provider 在自己的 serializeRequest/parseChunk 内部查表
//! 决定 wire 格式。agent_loop 不感知 adapter——它仍只传 reasoning_effort,翻译成各家 wire 格式
//! 是 provider 实现的私事。
//!
//! 覆盖 8 家模型厂商(2025-08 调研):
//! - Anthropic Claude: thinking.type=adaptive + output_config.effort
//! - OpenAI GPT-5/o3: reasoning.effort 嵌套对象,7 档
//! - Google Gemini: thinking_level in generation_config
//! - GLM-5.2: <reasoning_effort> prompt 标签,7→2 effort 映射,XML 工具,clear_thinking
//! - Kimi K3: thinking:{type,keep,effort} extra_body,3 档,prompt_cache_key
//! - DeepSeek: thinking:{type} + reasoning_effort 顶层,1 档
//! - Qwen3: enable_thinking + /think /no_think chat template
//! - Mistral: reasoning_effort,parallel_tool_calls
//!
//! 调研来源:各厂商 chat_template.jinja / OpenAPI spec / 官方文档(2025-08 快照)。

const std = @import("std");

/// thinking 控制模式:决定 reasoning_effort 如何翻译到 wire 格式。
pub const ThinkingMode = enum {
    /// 不支持 thinking(或未开启)
    none,
    /// Claude:thinking.type=adaptive + output_config.effort(顶层)
    anthropic_adaptive,
    /// GLM-5:<reasoning_effort> prompt 标签 + thinking:{type} body
    glm_prompt_tag,
    /// Kimi K3:thinking:{type,keep,effort} in extra_body
    kimi_extra_body,
    /// DeepSeek:thinking:{type} + reasoning_effort 顶层(两独立参数)
    deepseek_top,
    /// Qwen3:enable_thinking bool + /think /no_think 文本指令(chat template)
    qwen_template,
    /// OpenAI:reasoning.effort 嵌套对象,7 档
    openai_effort,
    /// Gemini:thinking_level in generation_config
    gemini_level,
};

/// 工具调用 wire 格式
pub const ToolFormat = enum {
    /// OpenAI 标准:function + arguments(JSON)
    openai_json,
    /// GLM-5:XML 格式(invoke: name / param: val / end_invoke)
    glm_xml,
};

/// effort 档位映射:OpenAI 7 档(none/minimal/low/medium/high/xhigh/max)→ 实际支持的档位
pub const EffortLevels = enum {
    /// 全 7 档透传(OpenAI 原生)
    full,
    /// GLM-5:7→2 映射(none/minimal→skip, low/medium→high, high→high, xhigh/max→max)
    glm_7to2,
    /// Kimi K3:3 档(low/high/max)
    kimi_3,
    /// DeepSeek:1 档(仅 high)
    deepseek_1,
    /// 不支持 effort
    none_,
};

/// response_format 支持范围
pub const ResponseFormatSupport = enum {
    /// 支持 json_schema(OpenAI/Claude/K3)
    json_schema,
    /// 仅 json_object(GLM-5)
    json_object_only,
};

/// tool_choice 支持范围
pub const ToolChoiceSupport = enum {
    /// 全支持(auto/none/required/指定函数)
    full,
    /// 仅 auto(GLM-5)
    auto_only,
};

/// 按 (kind, model) 查表返回的模型能力 profile。纯数据,无 fn。
///
/// 默认值适用于"标准 OpenAI-compatible"模型;各 provider 在 serializeRequest 内查此表
/// 决定 wire 格式。新增模型只需在此函数加分支,不改任何 provider 签名。
pub const ModelProfile = struct {
    /// thinking 控制模式
    thinking_mode: ThinkingMode = .none,
    /// preserved thinking 默认值(clear_thinking/keep 的默认)。
    /// null=无此功能;GLM coding-plan 端点=false(保留),标准 API=true(清除)。
    preserved_thinking_default: ?bool = null,
    /// 工具调用 wire 格式
    tool_format: ToolFormat = .openai_json,
    /// 是否支持 defer_loading 工具标记(GLM-5 独有)
    supports_defer_loading: bool = false,
    /// effort 档位映射
    effort_levels: EffortLevels = .none_,
    /// response_format 支持范围
    response_format_support: ResponseFormatSupport = .json_schema,
    /// tool_choice 支持范围
    tool_choice_support: ToolChoiceSupport = .full,
    /// 支持 prompt_cache_key(K3 独有,coding agent 性能相关)
    supports_prompt_cache_key: bool = false,
    /// 支持并行工具调用控制(Mistral 独有)
    supports_parallel_tool_calls: bool = false,
    /// 支持 reasoning_content 响应字段(DeepSeek/Kimi/Qwen/GLM;Claude 用 thinking block;OpenAI 不暴露)
    returns_reasoning_content: bool = false,
};

/// provider kind(与 capability.zig 对齐,但本模块独立持有以解耦)
pub const ProviderKind = enum { anthropic, openai, gemini, other };

/// 按 (provider_kind, model) 返回 profile。单一真相源。
///
/// 匹配规则:先按 provider_kind 分流,再按 model 子串匹配具体模型版本。
/// 未匹配到具体版本 → 该 kind 的保守默认。
pub fn profileFor(kind: ProviderKind, model: []const u8) ModelProfile {
    return switch (kind) {
        .anthropic => anthropicProfile(model),
        .openai => openaiProfile(model),
        .gemini => geminiProfile(model),
        .other => .{},
    };
}

fn anthropicProfile(model: []const u8) ModelProfile {
    var p = ModelProfile{
        .thinking_mode = .anthropic_adaptive,
        .effort_levels = .full,
        .returns_reasoning_content = false, // Claude 用 content[] 里的 thinking block,非平级字段
    };
    // Claude 4.x 保留 thinking(preserved thinking)
    if (hasSubstr(model, "claude-opus-4") or hasSubstr(model, "claude-sonnet-4") or hasSubstr(model, "claude-haiku-4")) {
        p.preserved_thinking_default = false; // 保留(对齐 Claude Opus 4.5+)
    }
    return p;
}

fn openaiProfile(model: []const u8) ModelProfile {
    // GLM-5 系列(经 OpenAI-compatible 端点调用)
    // 注:GLM 原生端点用 XML 工具格式 + defer_loading,但 metacodes 走 OpenAI-compatible
    // 端点(标准 JSON function 调用),07-15 swarm e2e 真 GLM-5.2 + JSON 工具调用 PASS 证实。
    // tool_format/supports_defer_loading 走默认(openai_json/false)——XML 格式留 ToolFormat.glm_xml
    // 枚举供将来原生端点适配,OpenAI-compatible 端点不消费。
    if (hasSubstr(model, "glm-5") or hasSubstr(model, "glm4") or hasSubstr(model, "glm-4")) {
        return .{
            .thinking_mode = .glm_prompt_tag,
            .effort_levels = .glm_7to2,
            .response_format_support = .json_object_only,
            .tool_choice_support = .auto_only,
            .returns_reasoning_content = true,
            // GLM coding-plan 端点默认保留 thinking;标准 API 端点默认清除。
            // harness 无法从 model 名区分端点,保守取 false(保留)——coding agent 场景更常见。
            .preserved_thinking_default = false,
        };
    }
    // Kimi K3
    if (hasSubstr(model, "kimi") or hasSubstr(model, "k2") or hasSubstr(model, "moonshot")) {
        return .{
            .thinking_mode = .kimi_extra_body,
            .effort_levels = .kimi_3,
            .supports_prompt_cache_key = true,
            .returns_reasoning_content = true,
            .preserved_thinking_default = false, // keep="all" 等价
        };
    }
    // DeepSeek
    if (hasSubstr(model, "deepseek")) {
        return .{
            .thinking_mode = .deepseek_top,
            .effort_levels = .deepseek_1,
            .returns_reasoning_content = true,
        };
    }
    // Qwen3
    if (hasSubstr(model, "qwen3") or hasSubstr(model, "qwen-3")) {
        return .{
            .thinking_mode = .qwen_template,
            .effort_levels = .none_, // Qwen3 无 effort 档位,只开关
            .returns_reasoning_content = true,
        };
    }
    // Mistral
    if (hasSubstr(model, "mistral") or hasSubstr(model, "magistral")) {
        return .{
            .thinking_mode = .none, // Mistral 用 reasoning_effort 但非 thinking block
            .effort_levels = .full, // reasoning_effort: high/none
            .supports_parallel_tool_calls = true,
            .returns_reasoning_content = true, // ThinkChunk
        };
    }
    // OpenAI 原生(GPT-4o/o1/o3/GPT-5)
    return .{
        .thinking_mode = .openai_effort,
        .effort_levels = .full,
        .returns_reasoning_content = false, // OpenAI 不暴露 reasoning content
    };
}

fn geminiProfile(model: []const u8) ModelProfile {
    _ = model;
    return .{
        .thinking_mode = .gemini_level,
        .effort_levels = .none_, // Gemini 用 thinking_level(minimal/low/medium/high),非 effort
        .returns_reasoning_content = false, // Gemini 用 thought_summary + signature,非平级字段
    };
}

/// GLM-5 的 effort 7→2 映射:none/minimal → 跳过;low/medium → high;high → high;xhigh/max → max。
/// 返回 null 表示"跳过 thinking"(对应 none/minimal)。
pub fn glmEffortMap(effort: @import("../types.zig").ReasoningEffort) ?[]const u8 {
    return switch (effort) {
        .none, .minimal => null, // 跳过
        .low, .medium, .high => "high",
        .xhigh => "max",
    };
}

/// Kimi K3 的 effort 映射:3 档(low/high/max)。
pub fn kimiEffortMap(effort: @import("../types.zig").ReasoningEffort) ?[]const u8 {
    return switch (effort) {
        .none, .minimal => null, // 跳过
        .low => "low",
        .medium, .high => "high",
        .xhigh => "max",
    };
}

/// DeepSeek 的 effort 映射:1 档(仅 high)。
pub fn deepseekEffortMap(effort: @import("../types.zig").ReasoningEffort) ?[]const u8 {
    return switch (effort) {
        .none, .minimal => null, // 跳过
        .low, .medium, .high, .xhigh => "high",
    };
}

fn hasSubstr(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

// ── 测试 ────────────────────────────────────────────────────────────────────

test "profileFor: Anthropic Claude 4.x" {
    const p = profileFor(.anthropic, "claude-sonnet-4-20250514");
    try std.testing.expect(p.thinking_mode == .anthropic_adaptive);
    try std.testing.expect(p.effort_levels == .full);
    try std.testing.expect(p.preserved_thinking_default == false);
    try std.testing.expect(!p.returns_reasoning_content);
}

test "profileFor: GLM-5.2" {
    const p = profileFor(.openai, "glm-5.2");
    try std.testing.expect(p.thinking_mode == .glm_prompt_tag);
    // OpenAI-compatible 端点用 JSON function 调用(非原生 XML);glm_xml 枚举保留供将来原生端点。
    try std.testing.expect(p.tool_format == .openai_json);
    try std.testing.expect(!p.supports_defer_loading);
    try std.testing.expect(p.effort_levels == .glm_7to2);
    try std.testing.expect(p.response_format_support == .json_object_only);
    try std.testing.expect(p.tool_choice_support == .auto_only);
    try std.testing.expect(p.returns_reasoning_content);
}

test "profileFor: Kimi K3" {
    const p = profileFor(.openai, "kimi-k2");
    try std.testing.expect(p.thinking_mode == .kimi_extra_body);
    try std.testing.expect(p.effort_levels == .kimi_3);
    try std.testing.expect(p.supports_prompt_cache_key);
    try std.testing.expect(p.returns_reasoning_content);
}

test "profileFor: DeepSeek" {
    const p = profileFor(.openai, "deepseek-chat");
    try std.testing.expect(p.thinking_mode == .deepseek_top);
    try std.testing.expect(p.effort_levels == .deepseek_1);
    try std.testing.expect(p.returns_reasoning_content);
}

test "profileFor: Qwen3" {
    const p = profileFor(.openai, "qwen3-235b");
    try std.testing.expect(p.thinking_mode == .qwen_template);
    try std.testing.expect(p.effort_levels == .none_);
    try std.testing.expect(p.returns_reasoning_content);
}

test "profileFor: Mistral" {
    const p = profileFor(.openai, "mistral-large");
    try std.testing.expect(p.supports_parallel_tool_calls);
    try std.testing.expect(p.returns_reasoning_content);
}

test "profileFor: OpenAI GPT-4o" {
    const p = profileFor(.openai, "gpt-4o");
    try std.testing.expect(p.thinking_mode == .openai_effort);
    try std.testing.expect(p.effort_levels == .full);
    try std.testing.expect(!p.returns_reasoning_content);
}

test "profileFor: Gemini" {
    const p = profileFor(.gemini, "gemini-2.5-pro");
    try std.testing.expect(p.thinking_mode == .gemini_level);
}

test "glmEffortMap 7→2" {
    try std.testing.expect(glmEffortMap(.none) == null);
    try std.testing.expect(glmEffortMap(.minimal) == null);
    try std.testing.expectEqualStrings("high", glmEffortMap(.low).?);
    try std.testing.expectEqualStrings("high", glmEffortMap(.medium).?);
    try std.testing.expectEqualStrings("high", glmEffortMap(.high).?);
    try std.testing.expectEqualStrings("max", glmEffortMap(.xhigh).?);
}

test "kimiEffortMap 3 档" {
    try std.testing.expect(kimiEffortMap(.none) == null);
    try std.testing.expectEqualStrings("low", kimiEffortMap(.low).?);
    try std.testing.expectEqualStrings("high", kimiEffortMap(.high).?);
    try std.testing.expectEqualStrings("max", kimiEffortMap(.xhigh).?);
}

test "deepseekEffortMap 1 档" {
    try std.testing.expect(deepseekEffortMap(.none) == null);
    try std.testing.expectEqualStrings("high", deepseekEffortMap(.high).?);
}

test "profileFor: other 保守默认" {
    const p = profileFor(.other, "mystery-model");
    try std.testing.expect(p.thinking_mode == .none);
    try std.testing.expect(p.effort_levels == .none_);
    try std.testing.expect(!p.returns_reasoning_content);
}
