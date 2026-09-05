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
//! - MiniMax M3: thinking:{type: disabled|adaptive|enabled} 三态(effort 串仅兼容不调深度);
//!   M2.x: thinking 常开不可关,reasoning_split 分离 reasoning_content(2026-08 调研)
//!
//! 调研来源:各厂商 chat_template.jinja / OpenAPI spec / 官方文档(2025-08 快照)。

const std = @import("std");
const model_name = @import("model_name.zig");

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
    /// Kimi K3:顶层 reasoning_effort(low/high/max 默认 max),不发 thinking body,
    /// 必须 省略 temperature/top_p/n 等参数。K3 总是开 thinking(不能关)。
    kimi_k3_top_level,
    /// MiniMax M3:thinking:{type: disabled|adaptive|enabled} 三态;OpenAI-compat 的
    /// reasoning.effort 档位串仅兼容接受、不调深度,故不发。
    minimax_m3_thinking,
    /// MiniMax M2.x:thinking 常开且不可关(disabled 被接受但忽略);只发
    /// reasoning_split:true 让思考以 reasoning_content 平级字段返回。
    minimax_m2_split,
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
    /// Kimi K2.6:thinking:{type,keep,effort} body,effort 3 档(同 kimi_3 但走 body 而非顶层)
    kimi_k2_3,
    /// DeepSeek:2 档(high/max)— V4 文档明确 xhigh→max(此前误为 high)
    deepseek_2,
    /// MiniMax M3:三态(none→disabled,minimal/low→adaptive,medium+→enabled)。
    minimax_3state,
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
    /// 不能关 thinking(Kimi K3 总是开;Gemini 3.x 系列不能关)。
    /// 若 effort=null 或 .none/.minimal,dialect 仍要发"最低档"而非不发。
    cannot_disable_thinking: bool = false,
    /// 支持原生图像输入(vision)。序列化守门的单一真相:false 的 (kind, model) 在
    /// 请求含 image block 时必须报显式能力错误(error.ImageInputUnsupported),
    /// 绝不静默丢图/OCR/文本占位。保守默认 false;仅对已验证 vision 家族开 true。
    supports_image_input: bool = false,
    /// 支持 multimodal functionResponse(图像嵌在 functionResponse.parts 里,官方形态)。
    /// 仅 Gemini 3 系起支持(ai.google.dev function-calling#multimodal + v1beta discovery
    /// doc,2025-12-17 changelog);旧世代 Gemini 走同级 inline_data part 形态。
    /// 保守默认 false。
    supports_multimodal_function_response: bool = false,
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
        // Vision 自 Claude 3 起(claude-1/2/instant 是纯文本代);经 Anthropic 兼容
        // 网关的第三方文本模型(如 glm-5)同样不支持。按已验证家族守门,其余保守 false。
        .supports_image_input = hasSubstr(model, "claude") and
            !hasSubstr(model, "claude-instant") and
            !hasSubstr(model, "claude-1") and
            !hasSubstr(model, "claude-2"),
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
    // Kimi K3(总是开 thinking,顶层 reasoning_effort,不发 thinking body,省略 temp/top_p/n)
    if (hasSubstr(model, "kimi-k3") or hasSubstr(model, "kimi_k3")) {
        return .{
            .thinking_mode = .kimi_k3_top_level,
            .effort_levels = .kimi_3,
            .supports_prompt_cache_key = true,
            .returns_reasoning_content = true,
            .cannot_disable_thinking = true, // K3 总是开 thinking
            // preserved_thinking 默认 null(K3 文档未提 keep 字段,只 K2.6 用)
        };
    }
    // Kimi K2.6 及更早(thinking:{type,keep,effort} body,effort 3 档)
    if (hasSubstr(model, "kimi") or hasSubstr(model, "k2") or hasSubstr(model, "moonshot")) {
        return .{
            .thinking_mode = .kimi_extra_body,
            .effort_levels = .kimi_k2_3,
            .supports_prompt_cache_key = true,
            .returns_reasoning_content = true,
            .preserved_thinking_default = false, // keep="all" 等价
        };
    }
    // DeepSeek V4(thinking:{type} + reasoning_effort 顶层;V4 xhigh→max,V3 仅 high)
    if (hasSubstr(model, "deepseek")) {
        return .{
            .thinking_mode = .deepseek_top,
            .effort_levels = .deepseek_2,
            .returns_reasoning_content = true,
        };
    }
    // Qwen3
    if (hasSubstr(model, "qwen3") or hasSubstr(model, "qwen-3")) {
        return .{
            .thinking_mode = .qwen_template,
            .effort_levels = .none_, // Qwen3 无 effort 档位,只开关
            .returns_reasoning_content = true,
            // Qwen3 文本模型无 vision;VL 变体(qwen3-vl-*)走 OpenAI image_url 格式。
            .supports_image_input = hasSubstr(model, "vl"),
        };
    }
    // MiniMax M3(三态 thinking;可关)
    if (hasSubstr(model, "minimax-m3") or hasSubstr(model, "minimax_m3")) {
        return .{
            .thinking_mode = .minimax_m3_thinking,
            .effort_levels = .minimax_3state,
            .returns_reasoning_content = true,
        };
    }
    // MiniMax M2.x(常开不可关;reasoning_split 平级返回思考)
    if (hasSubstr(model, "minimax")) {
        return .{
            .thinking_mode = .minimax_m2_split,
            .effort_levels = .none_,
            .returns_reasoning_content = true,
            .cannot_disable_thinking = true,
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
    // OpenAI 原生(GPT-4o/o1/o3/GPT-5)。注意本分支同时是**所有未匹配模型名的
    // catch-all**(vLLM/自部署/新厂商)——vision 只对已验证 OpenAI 家族开 true,
    // 未知模型保持保守 false(fail-closed:本地显式能力错误优于远端 400/静默忽略)。
    return .{
        .thinking_mode = .openai_effort,
        .effort_levels = .full,
        .returns_reasoning_content = false, // OpenAI 不暴露 reasoning content
        .supports_image_input = openaiNativeVision(model),
    };
}

/// OpenAI 原生已验证 vision 家族:GPT-4o/4.1/4.5/GPT-5/ChatGPT 全系、gpt-4-turbo/
/// gpt-4-vision;推理系 o1/o3/o4(o1-mini/o1-preview/o3-mini 除外)。o 系按**前缀+
/// 边界**匹配——裸子串会把 marco-o1/skywork-o1 这类第三方文本模型误判成 vision
/// (正是本表要关死的远端 400 模式)。GPT-3.5/裸 gpt-4(0613 代)与一切未知名字保守 false。
fn openaiNativeVision(model: []const u8) bool {
    if (hasSubstr(model, "gpt-4o") or hasSubstr(model, "gpt-4.1") or
        hasSubstr(model, "gpt-4.5") or hasSubstr(model, "gpt-4-turbo") or
        hasSubstr(model, "gpt-4-vision") or
        hasSubstr(model, "gpt-5") or hasSubstr(model, "chatgpt")) return true;
    if (hasSubstr(model, "o1-mini") or hasSubstr(model, "o1-preview") or
        hasSubstr(model, "o3-mini")) return false;
    return oSeriesPrefix(model, "o1") or oSeriesPrefix(model, "o3") or oSeriesPrefix(model, "o4");
}

/// o 系推理模型名以 "oN" 开头且后随边界(结尾/'-'/'.'):o1、o3-pro、o4-mini-2025 命中;
/// marco-o1、skywork-o1、olmo-4 等不命中。
fn oSeriesPrefix(model: []const u8, prefix: []const u8) bool {
    if (!model_name.startsWithIgnoreCase(model, prefix)) return false;
    if (model.len == prefix.len) return true;
    return model[prefix.len] == '-' or model[prefix.len] == '.';
}

fn geminiProfile(model: []const u8) ModelProfile {
    // Gemini 3.x 系列(3.1 Pro / 3.1 Flash-Lite / 3 Flash)不能关 thinking:
    // 默认就是 low,effort=null/none/minimal 应映射为 low(不是不发)。
    // 来源:ai.google.dev/gemini-api/docs/openai(2026-08 KnowForge 调研)。
    const is_gemini3_family = hasSubstr(model, "gemini-3");
    return .{
        .thinking_mode = .gemini_level,
        .supports_image_input = true, // Gemini 全系原生多模态(inline_data parts)
        // multimodal functionResponse(functionResponse.parts[].inlineData)仅 Gemini 3 系起
        // 官方支持;旧世代(2.5 等)tool_result 图像走同级 inline_data part 形态。
        .supports_multimodal_function_response = is_gemini3_family,

        .effort_levels = .none_, // Gemini 用 thinking_level(minimal/low/medium/high),非 effort
        .returns_reasoning_content = false, // Gemini 用 thought_summary + signature,非平级字段
        .cannot_disable_thinking = is_gemini3_family,
    };
}

/// Kimi K2.6 的 effort 映射:3 档(low/high/max)。
pub fn kimiEffortMap(effort: @import("../types.zig").ReasoningEffort) ?[]const u8 {
    return switch (effort) {
        .none, .minimal => null, // 跳过
        .low => "low",
        .medium, .high => "high",
        .xhigh => "max",
    };
}

/// Kimi K3 的 effort 映射:3 档(low/high/max,默认 max)。
/// K3 总是开 thinking,effort=null 走默认 "max"(由调用方处理 null,本函数只接非 null)。
pub fn kimiK3EffortMap(effort: @import("../types.zig").ReasoningEffort) []const u8 {
    return switch (effort) {
        .none, .minimal => "max", // K3 不能关,降级到默认 max
        .low => "low",
        .medium, .high => "high",
        .xhigh => "max",
    };
}

/// DeepSeek 的 effort 映射:2 档(high/max)。
/// V4 文档明确 xhigh → max(此前误为 high,2026-08 KnowForge 调研修正)。
/// 来源:api-docs.deepseek.com/guides/thinking_mode。
pub fn deepseekEffortMap(effort: @import("../types.zig").ReasoningEffort) ?[]const u8 {
    return switch (effort) {
        .none, .minimal => null, // 跳过
        .low, .medium, .high => "high",
        .xhigh => "max",
    };
}

/// MiniMax M3 的 thinking 三态映射:none→disabled,minimal/low→adaptive(模型自判),
/// medium/high/xhigh→enabled(强制)。null(未指定)→ adaptive(官方默认,显式发送保证
/// 请求字节确定性)。来源:platform.minimax.io responses-create + MiniMax-M3 model card
/// (2026-08 调研):OpenAI-compat 的 reasoning.effort 串仅兼容接受、不调 M3 深度。
pub fn minimaxM3ThinkingType(effort: ?@import("../types.zig").ReasoningEffort) []const u8 {
    const e = effort orelse return "adaptive";
    return switch (e) {
        .none => "disabled",
        .minimal, .low => "adaptive",
        .medium, .high, .xhigh => "enabled",
    };
}

pub fn hasSubstr(haystack: []const u8, needle: []const u8) bool {
    return model_name.containsIgnoreCase(haystack, needle);
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

test "profileFor: Kimi K3(顶层 reasoning_effort,不能关)" {
    const p = profileFor(.openai, "kimi-k3");
    try std.testing.expect(p.thinking_mode == .kimi_k3_top_level);
    try std.testing.expect(p.effort_levels == .kimi_3);
    try std.testing.expect(p.supports_prompt_cache_key);
    try std.testing.expect(p.returns_reasoning_content);
    try std.testing.expect(p.cannot_disable_thinking);
}

test "profileFor: Kimi K2.6(thinking body,effort 3 档)" {
    const p = profileFor(.openai, "kimi-k2");
    try std.testing.expect(p.thinking_mode == .kimi_extra_body);
    try std.testing.expect(p.effort_levels == .kimi_k2_3);
    try std.testing.expect(p.supports_prompt_cache_key);
    try std.testing.expect(p.returns_reasoning_content);
    try std.testing.expect(!p.cannot_disable_thinking);
}

test "profileFor: DeepSeek V4" {
    const p = profileFor(.openai, "deepseek-chat");
    try std.testing.expect(p.thinking_mode == .deepseek_top);
    try std.testing.expect(p.effort_levels == .deepseek_2);
    try std.testing.expect(p.returns_reasoning_content);
}

test "profileFor: Gemini 2.5(可关 thinking)" {
    const p = profileFor(.gemini, "gemini-2.5-pro");
    try std.testing.expect(p.thinking_mode == .gemini_level);
    try std.testing.expect(!p.cannot_disable_thinking);
}

test "profileFor: Gemini 3.1 Pro(不能关 thinking)" {
    const p = profileFor(.gemini, "gemini-3.1-pro");
    try std.testing.expect(p.thinking_mode == .gemini_level);
    try std.testing.expect(p.cannot_disable_thinking);
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

test "kimiEffortMap 3 档(K2.6)" {
    try std.testing.expect(kimiEffortMap(.none) == null);
    try std.testing.expectEqualStrings("low", kimiEffortMap(.low).?);
    try std.testing.expectEqualStrings("high", kimiEffortMap(.high).?);
    try std.testing.expectEqualStrings("max", kimiEffortMap(.xhigh).?);
}

test "kimiK3EffortMap 3 档(K3,不能关)" {
    // K3 不能关 thinking,none/minimal 降级到默认 max
    try std.testing.expectEqualStrings("max", kimiK3EffortMap(.none));
    try std.testing.expectEqualStrings("max", kimiK3EffortMap(.minimal));
    try std.testing.expectEqualStrings("low", kimiK3EffortMap(.low));
    try std.testing.expectEqualStrings("high", kimiK3EffortMap(.high));
    try std.testing.expectEqualStrings("max", kimiK3EffortMap(.xhigh));
}

test "deepseekEffortMap 2 档(V4 xhigh→max)" {
    try std.testing.expect(deepseekEffortMap(.none) == null);
    try std.testing.expect(deepseekEffortMap(.minimal) == null);
    try std.testing.expectEqualStrings("high", deepseekEffortMap(.low).?);
    try std.testing.expectEqualStrings("high", deepseekEffortMap(.medium).?);
    try std.testing.expectEqualStrings("high", deepseekEffortMap(.high).?);
    try std.testing.expectEqualStrings("max", deepseekEffortMap(.xhigh).?);
}

test "profileFor: MiniMax M3(三态 thinking,可关)" {
    const p = profileFor(.openai, "minimax-m3");
    try std.testing.expect(p.thinking_mode == .minimax_m3_thinking);
    try std.testing.expect(p.effort_levels == .minimax_3state);
    try std.testing.expect(p.returns_reasoning_content);
    try std.testing.expect(!p.cannot_disable_thinking);
}

test "profileFor: MiniMax M2.1(常开不可关)" {
    const p = profileFor(.openai, "minimax-m2.1");
    try std.testing.expect(p.thinking_mode == .minimax_m2_split);
    try std.testing.expect(p.effort_levels == .none_);
    try std.testing.expect(p.returns_reasoning_content);
    try std.testing.expect(p.cannot_disable_thinking);
}

test "minimaxM3ThinkingType 三态映射" {
    try std.testing.expectEqualStrings("adaptive", minimaxM3ThinkingType(null));
    try std.testing.expectEqualStrings("disabled", minimaxM3ThinkingType(.none));
    try std.testing.expectEqualStrings("adaptive", minimaxM3ThinkingType(.minimal));
    try std.testing.expectEqualStrings("adaptive", minimaxM3ThinkingType(.low));
    try std.testing.expectEqualStrings("enabled", minimaxM3ThinkingType(.medium));
    try std.testing.expectEqualStrings("enabled", minimaxM3ThinkingType(.high));
    try std.testing.expectEqualStrings("enabled", minimaxM3ThinkingType(.xhigh));
}

test "profileFor: other 保守默认" {
    const p = profileFor(.other, "mystery-model");
    try std.testing.expect(p.thinking_mode == .none);
    try std.testing.expect(p.effort_levels == .none_);
    try std.testing.expect(!p.returns_reasoning_content);
}

test "profileFor: vision 能力矩阵(issue #10)" {
    // 已验证 vision 家族 true;文本模型/未验证家族/未知模型名保守 false(fail-closed)。
    try std.testing.expect(profileFor(.anthropic, "claude-sonnet-4-20250514").supports_image_input);
    try std.testing.expect(profileFor(.anthropic, "claude-3-5-haiku-20241022").supports_image_input);
    try std.testing.expect(!profileFor(.anthropic, "claude-2.1").supports_image_input);
    try std.testing.expect(!profileFor(.anthropic, "claude-instant-1.2").supports_image_input);
    try std.testing.expect(profileFor(.openai, "gpt-4o").supports_image_input);
    try std.testing.expect(profileFor(.openai, "gpt-5.2").supports_image_input);
    try std.testing.expect(profileFor(.openai, "o3").supports_image_input);
    try std.testing.expect(!profileFor(.openai, "o3-mini").supports_image_input);
    try std.testing.expect(!profileFor(.openai, "o1-mini").supports_image_input);
    try std.testing.expect(!profileFor(.openai, "gpt-3.5-turbo").supports_image_input);
    try std.testing.expect(profileFor(.openai, "gpt-4-turbo-2024-04-09").supports_image_input);
    try std.testing.expect(profileFor(.openai, "o4-mini").supports_image_input);
    try std.testing.expect(profileFor(.openai, "o1-2024-12-17").supports_image_input);
    // o 系是前缀匹配:含 "o1" 子串的第三方文本模型不误判(marco-o1 等)。
    try std.testing.expect(!profileFor(.openai, "marco-o1").supports_image_input);
    try std.testing.expect(!profileFor(.openai, "skywork-o1-open").supports_image_input);
    // 未知模型名落 OpenAI catch-all:vision 必须 fail-closed(不发远端赌 400)。
    try std.testing.expect(!profileFor(.openai, "llama-3.3-70b").supports_image_input);
    try std.testing.expect(!profileFor(.openai, "grok-4").supports_image_input);
    try std.testing.expect(profileFor(.gemini, "gemini-2.5-pro").supports_image_input);
    try std.testing.expect(profileFor(.openai, "qwen3-vl-235b").supports_image_input);
    try std.testing.expect(!profileFor(.openai, "qwen3-235b").supports_image_input);
    try std.testing.expect(!profileFor(.openai, "glm-5.2").supports_image_input);
    try std.testing.expect(!profileFor(.openai, "deepseek-chat").supports_image_input);
    try std.testing.expect(!profileFor(.openai, "kimi-k3").supports_image_input);
    try std.testing.expect(!profileFor(.openai, "minimax-m3").supports_image_input);
    try std.testing.expect(!profileFor(.openai, "mistral-large").supports_image_input);
    try std.testing.expect(!profileFor(.other, "mystery").supports_image_input);
}

test "profileFor: multimodal functionResponse 仅 Gemini 3 系 true" {
    try std.testing.expect(profileFor(.gemini, "gemini-3-flash").supports_multimodal_function_response);
    try std.testing.expect(profileFor(.gemini, "gemini-3.1-pro").supports_multimodal_function_response);
    try std.testing.expect(!profileFor(.gemini, "gemini-2.5-pro").supports_multimodal_function_response);
    try std.testing.expect(!profileFor(.anthropic, "claude-sonnet-4-20250514").supports_multimodal_function_response);
    try std.testing.expect(!profileFor(.openai, "gpt-5.2").supports_multimodal_function_response);
}
