//! Model Adapter:按 (provider_kind, model) 返回 per-model 能力 profile。
//!
//! 设计(见 metaknow root「多 Provider 分离架构设计」):
//! 不把 per-model 参数塞进 Provider.sendStreamFn 签名(会膨胀且每加一个参数所有 provider 都要改)。
//! 而是引入纯数据 ModelProfile,各 provider 在自己的 serializeRequest/parseChunk 内部查表
//! 决定 wire 格式。agent_loop 不感知 adapter——它仍只传 reasoning_effort,翻译成各家 wire 格式
//! 是 provider 实现的私事。
//!
//! 每家厂商的参数怎么发、为什么这么发,写在那家的接入文件里(`dialects/<vendor>.zig`,
//! 登记表 `dialects/registry.zig`)。本文件只保留跨厂商的部分:`ModelProfile` 的形状、
//! 按 wire 的默认 profile(Anthropic / Gemini / OpenAI 原生兜底)、图像家族表,以及
//! 按名推断时把 OpenAI chat wire 上的模型名交给对应厂商的 `openaiProfile`。

const std = @import("std");
const image_capability = @import("image_capability.zig");
const model_name = @import("model_name.zig");
const vendor_dialects = @import("dialects/registry.zig");

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
    /// Mistral:顶层 `reasoning_effort`,每个型号自己的词汇(`effort_levels`);
    /// 思考以 content 列表里的 thinking chunk 返回(`content_chunks`)。
    mistral_effort,
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
    /// Mistral Small 2603 / Medium 3.5:none / high 两档。
    mistral_none_high,
    /// Mistral Large 4:low / medium / high 三档,不收 none(思考关不掉)。
    mistral_low_medium_high,
    /// 不支持 effort
    none_,
};

/// OpenAI chat wire 上 list 型 `content`(typed chunk 列表)的读写范围。Mistral 用这种
/// 形态返回推理:`{"type":"thinking","thinking":[{"type":"text","text":...}]}` 与
/// `{"type":"text","text":...}` 并列(issue #437)。
pub const ContentChunks = enum {
    /// `content` 只按字符串读;list 型整个忽略。Mistral 以外的所有方言。
    none,
    /// list 型 `content` 按序读:text chunk → 正文,thinking chunk 的 text 部分 → 思考。
    /// 历史仍按字符串发,不带思考。
    read,
    /// 同 `read`;另外,带思考的 assistant 历史消息以 list 发回:thinking chunk 与
    /// text chunk 保持原顺序(Mistral 的推理模型要求整条消息原样回放)。
    read_and_echo,
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
    /// OpenAI chat wire 上,assistant 历史消息的 thinking 块以 `reasoning_content` 回传。
    /// DeepSeek 在请求带 tools 时要求回传全部历史思考,否则 400;只由厂商接入文件声明。
    echoes_reasoning_content: bool = false,
    /// OpenAI chat wire 上 list 型 `content` 的读写(见 `ContentChunks`)。只由厂商接入
    /// 文件声明(Mistral),其余方言的解析结果与请求字节不受影响。思考回传只走一条路:
    /// `.read_and_echo` 发 thinking chunk 时不再看 `echoes_reasoning_content`。
    content_chunks: ContentChunks = .none,
    /// The vendor pins the sampling parameters (Kimi K3 says to omit
    /// `temperature` / `top_p`; K2.7-code errors on any other value): the
    /// OpenAI chat serializer leaves a caller's `temperature` / `top_p`
    /// override out. Every other profile sends them as before.
    fixed_sampling: bool = false,
    /// 不能关 thinking(Kimi K3 总是开;Gemini 3.x 系列不能关)。
    /// 若 effort=null 或 .none/.minimal,dialect 仍要发"最低档"而非不发。
    cannot_disable_thinking: bool = false,
    /// The model validates the thought signature of each step's first
    /// function call in the current turn (Gemini 3 and later); a call sent
    /// back without one fails the request.
    requires_thought_signatures: bool = false,
    /// The model takes only low / high / max as its effort (GLM 5.3 and later,
    /// on any wire); a neutral level is sent as the nearest of those.
    glm53_effort_vocabulary: bool = false,
    /// 支持原生图像输入(vision)。序列化守门的单一真相:false 的 (kind, model) 在
    /// 请求含 image block 时必须报显式能力错误(error.ImageInputUnsupported),
    /// 绝不静默丢图/OCR/文本占位。保守默认 false;仅对已验证 vision 家族开 true。
    supports_image_input: bool = false,
    /// Who answered `supports_image_input`. `.model_family` when the built-in
    /// table knows the name either way; `.unknown` when it does not (the
    /// answer is then the fail-closed `false`). A catalog or Host declaration
    /// applied by `Dialect.profileFor` replaces both fields (issue #273).
    image_input_source: image_capability.Source = .unknown,
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
        // Vision 按**模型家族**判,与 wire 格式无关(issue #112):Anthropic 兼容网关
        // 后面挂的可以是 gpt-5.x / gemini / qwen-vl,名字认得出的家族照常放行;
        // 认不出的保守 false(来源 unknown)——真相由 /v1/models 目录或 Host 的
        // image_input 声明覆盖(Dialect.image_input_override),不在这里赌远端 400。
    };
    withFamilyImageInput(&p, familyImageInput(model));
    // Claude 4.x 保留 thinking(preserved thinking)
    if (hasSubstr(model, "claude-opus-4") or hasSubstr(model, "claude-sonnet-4") or hasSubstr(model, "claude-haiku-4")) {
        p.preserved_thinking_default = false; // 保留(对齐 Claude Opus 4.5+)
    }
    // GLM 5.3+ behind an Anthropic-wire endpoint (Z.AI's default channel, the
    // Metask gateway) still takes only its own three levels.
    p.glm53_effort_vocabulary = glmAlwaysThinks(model);
    return p;
}

fn openaiProfile(model: []const u8) ModelProfile {
    // 认得出厂商的名字:家族 profile 在各家的接入文件里(`dialects/<vendor>.zig`)。
    if (vendor_dialects.inferredOpenAIProfile(model)) |p| return p;
    // OpenAI 原生(GPT-4o/o1/o3/GPT-5)。本分支同时是**所有未匹配模型名的 catch-all**
    // (vLLM/自部署/新厂商)——vision 只对已验证 OpenAI 家族开 true,未知模型保持保守
    // false(fail-closed:本地显式能力错误优于远端 400/静默忽略),来源记为 unknown,
    // 与"已知纯文本"区分开(issue #273)。
    var p = ModelProfile{
        .thinking_mode = .openai_effort,
        .effort_levels = .full,
        .returns_reasoning_content = false, // OpenAI 不暴露 reasoning content
    };
    withFamilyImageInput(&p, familyImageInput(model));
    return p;
}

fn withFamilyImageInput(p: *ModelProfile, family: ?bool) void {
    p.supports_image_input = family orelse false;
    p.image_input_source = if (family != null) .model_family else .unknown;
}

/// 模型**家族**表对 image input 的看法——与调用它的 wire 格式无关(同一个模型经 Anthropic
/// 兼容网关或 OpenAI 兼容端点,能不能看图是模型的事,不是协议的事;issue #112)。
/// true = 已验证的 vision 家族;false = 已验证的纯文本家族;null = 表里不认识这个名字
/// (调用方 fail-closed 按 false 处理,但来源是 unknown,不是"不支持";issue #273)。
/// 目录或 Host 有声明时覆盖本表,见 dialect.Dialect.image_input_override。
pub fn familyImageInput(model: []const u8) ?bool {
    // Claude 3 起原生多模态;claude-1/2/instant 是纯文本代。
    if (hasSubstr(model, "claude")) {
        return !hasSubstr(model, "claude-instant") and
            !hasSubstr(model, "claude-1") and
            !hasSubstr(model, "claude-2");
    }
    if (openaiNativeVision(model)) return true;
    if (openaiKnownTextOnly(model)) return false;
    // Gemini 全系原生多模态。
    if (hasSubstr(model, "gemini")) return true;
    // Qwen VL 变体(qwen2.5-vl / qwen3-vl)。
    if (hasSubstr(model, "qwen") and hasSubstr(model, "vl")) return true;
    // MiniMax-M3:原生多模态(见 openaiProfile 的 M3 分支)。
    if (hasSubstr(model, "minimax-m3") or hasSubstr(model, "minimax_m3")) return true;
    // GLM:版本段以 v 收尾是视觉变体,其余是文本系——命名约定两头都确定。
    if (std.ascii.indexOfIgnoreCase(model, "glm-") != null) return glmVisionVariant(model);
    return null;
}

/// `familyImageInput` 的 fail-closed 布尔视图:不认识的名字按不支持。
pub fn knownVisionFamily(model: []const u8) bool {
    return familyImageInput(model) orelse false;
}

/// OpenAI 已知的纯文本型号:o1-mini/o1-preview/o3-mini、GPT-3.5、0613 代的裸 gpt-4。
fn openaiKnownTextOnly(model: []const u8) bool {
    if (hasSubstr(model, "o1-mini") or hasSubstr(model, "o1-preview") or
        hasSubstr(model, "o3-mini") or hasSubstr(model, "gpt-3.5")) return true;
    if (model_name.eqlIgnoreCase(model, "gpt-4")) return true;
    return model_name.startsWithIgnoreCase(model, "gpt-4-0") or model_name.startsWithIgnoreCase(model, "gpt-4-32k");
}

/// GLM 视觉变体:`glm-` 后的版本段以 `v` 收尾——glm-4v、glm-4.1v-thinking、glm-4.5v、
/// glm-4.6v-flash 命中;glm-4-plus / glm-4-flash / glm-5.2 / glm-5.3-flash 不命中
/// (它们的版本段是 "4" / "5.2" / "5.3")。
pub fn glmVisionVariant(model: []const u8) bool {
    const at = std.ascii.indexOfIgnoreCase(model, "glm-") orelse return false;
    const rest = model[at + "glm-".len ..];
    const seg_end = std.mem.indexOfScalar(u8, rest, '-') orelse rest.len;
    const segment = rest[0..seg_end];
    if (segment.len < 2) return false;
    return segment[segment.len - 1] == 'v' or segment[segment.len - 1] == 'V';
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
    // Gemini 3 and every later generation (gemini-4-argon, ...).
    const is_gemini3_family = if (familyVersion(model, "gemini-")) |v| v.major >= 3 else false;
    return .{
        .thinking_mode = .gemini_level,
        .supports_image_input = true, // Gemini 全系原生多模态(inline_data parts)
        .image_input_source = .model_family,
        // multimodal functionResponse(functionResponse.parts[].inlineData)仅 Gemini 3 系起
        // 官方支持;旧世代(2.5 等)tool_result 图像走同级 inline_data part 形态。
        .supports_multimodal_function_response = is_gemini3_family,

        .effort_levels = .none_, // Gemini 用 thinking_level(minimal/low/medium/high),非 effort
        .returns_reasoning_content = false, // Gemini 用 thought_summary + signature,非平级字段
        .cannot_disable_thinking = is_gemini3_family,
        .requires_thought_signatures = is_gemini3_family,
    };
}

pub const FamilyVersion = struct { major: u32, minor: u32 };

/// The `<major>[.<minor>]` right after `prefix` in `model` (case-insensitive):
/// `glm-5.3-flash` → 5.3 for "glm-", `gemini-4-argon` → 4.0 for "gemini-".
/// Null when the prefix is absent or no digit follows it.
pub fn familyVersion(model: []const u8, prefix: []const u8) ?FamilyVersion {
    if (model.len < prefix.len) return null;
    var at: usize = 0;
    while (at + prefix.len <= model.len) : (at += 1) {
        if (!std.ascii.eqlIgnoreCase(model[at .. at + prefix.len], prefix)) continue;
        var i = at + prefix.len;
        const major = readNumber(model, &i) orelse continue;
        var minor: u32 = 0;
        if (i + 1 < model.len and model[i] == '.' and std.ascii.isDigit(model[i + 1])) {
            i += 1;
            minor = readNumber(model, &i) orelse 0;
        }
        return .{ .major = major, .minor = minor };
    }
    return null;
}

fn readNumber(text: []const u8, index: *usize) ?u32 {
    const start = index.*;
    var value: u32 = 0;
    while (index.* < text.len and std.ascii.isDigit(text[index.*])) : (index.* += 1) {
        value = std.math.mul(u32, value, 10) catch return null;
        value = std.math.add(u32, value, text[index.*] - '0') catch return null;
    }
    return if (index.* == start) null else value;
}

/// GLM 5.3 and later think on every request: `thinking.type` must be
/// `enabled` (disabled fails the request) and `reasoning_effort` is one of
/// low / high / max (docs.z.ai guides/llm/glm-5.3, 2026-10).
pub fn glmAlwaysThinks(model: []const u8) bool {
    const v = familyVersion(model, "glm-") orelse return false;
    return v.major > 5 or (v.major == 5 and v.minor >= 3);
}

/// The GLM 5.3 effort vocabulary for a neutral level.
pub fn glm53EffortName(effort: @import("../types.zig").ReasoningEffort) []const u8 {
    return switch (effort) {
        .none, .minimal, .low => "low",
        .medium, .high => "high",
        .xhigh, .max => "max",
    };
}

test "familyVersion reads the generation after a family prefix" {
    try std.testing.expectEqual(FamilyVersion{ .major = 5, .minor = 3 }, familyVersion("glm-5.3-flash", "glm-").?);
    try std.testing.expectEqual(FamilyVersion{ .major = 5, .minor = 0 }, familyVersion("GLM-5", "glm-").?);
    try std.testing.expectEqual(FamilyVersion{ .major = 4, .minor = 0 }, familyVersion("gemini-4-argon", "gemini-").?);
    try std.testing.expectEqual(FamilyVersion{ .major = 3, .minor = 8 }, familyVersion("models/gemini-3.8-flash", "gemini-").?);
    try std.testing.expect(familyVersion("gemini-pro", "gemini-") == null);
    try std.testing.expect(familyVersion("claude-opus", "glm-") == null);
}

test "GLM 5.3 and later always think; earlier GLM may switch it off" {
    try std.testing.expect(glmAlwaysThinks("glm-5.3"));
    try std.testing.expect(glmAlwaysThinks("glm-5.3-flash[1m]"));
    try std.testing.expect(glmAlwaysThinks("glm-6"));
    try std.testing.expect(!glmAlwaysThinks("glm-5.2"));
    try std.testing.expect(!glmAlwaysThinks("glm-4.6"));
    try std.testing.expectEqualStrings("low", glm53EffortName(.none));
    try std.testing.expectEqualStrings("high", glm53EffortName(.medium));
    try std.testing.expectEqualStrings("max", glm53EffortName(.xhigh));
    try std.testing.expectEqualStrings("max", glm53EffortName(.max));
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

test "profileFor: other 保守默认" {
    const p = profileFor(.other, "mystery-model");
    try std.testing.expect(p.thinking_mode == .none);
    try std.testing.expect(p.effort_levels == .none_);
    try std.testing.expect(!p.returns_reasoning_content);
}

test "profileFor: vision 家族判定与 wire 格式无关(issue #112)" {
    // 同一个名字,Anthropic 兼容路由和 OpenAI 兼容路由给同一个答案。
    try std.testing.expect(profileFor(.anthropic, "gpt-5.6-sol").supports_image_input);
    try std.testing.expect(profileFor(.openai, "gpt-5.6-sol").supports_image_input);
    try std.testing.expect(profileFor(.anthropic, "gemini-2.5-pro").supports_image_input);
    try std.testing.expect(profileFor(.anthropic, "qwen3-vl-235b").supports_image_input);
    try std.testing.expect(profileFor(.anthropic, "glm-4.5v").supports_image_input);
    // 文本家族 / 认不出的名字在两条路由上都 fail-closed。
    try std.testing.expect(!profileFor(.anthropic, "glm-5.2").supports_image_input);
    try std.testing.expect(!profileFor(.anthropic, "glm-5.3-flash").supports_image_input);
    try std.testing.expect(!profileFor(.anthropic, "deepseek-chat").supports_image_input);
    try std.testing.expect(!profileFor(.anthropic, "marco-o1").supports_image_input);
    try std.testing.expect(!profileFor(.anthropic, "claude-2.1").supports_image_input);
    try std.testing.expect(!knownVisionFamily("llama-3.3-70b"));
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
    try std.testing.expect(!profileFor(.openai, "glm-5.3-flash").supports_image_input); // 名字看不出,靠目录
    try std.testing.expect(!profileFor(.openai, "glm-4-plus").supports_image_input);
    try std.testing.expect(profileFor(.openai, "glm-4v").supports_image_input);
    try std.testing.expect(profileFor(.openai, "glm-4.5v").supports_image_input);
    try std.testing.expect(profileFor(.openai, "GLM-4.6V-Flash").supports_image_input);
    try std.testing.expect(!profileFor(.openai, "deepseek-chat").supports_image_input);
    try std.testing.expect(!profileFor(.openai, "kimi-k3").supports_image_input);
    // MiniMax-M3 是原生多模态(issue #273 回归),两条路由同答;M2.x 表里不下结论。
    try std.testing.expect(profileFor(.openai, "minimax-m3").supports_image_input);
    try std.testing.expect(profileFor(.anthropic, "MiniMax-M3").supports_image_input);
    try std.testing.expect(!profileFor(.openai, "minimax-m2.5").supports_image_input);
    try std.testing.expect(!profileFor(.openai, "mistral-large").supports_image_input);
    try std.testing.expect(!profileFor(.other, "mystery").supports_image_input);
}

test "profileFor: image input says who answered - family table or nobody (issue #273)" {
    const Source = image_capability.Source;
    // Known either way: the family table answered.
    inline for (.{
        .{ ProviderKind.anthropic, "claude-sonnet-4-6", true },
        .{ ProviderKind.anthropic, "claude-2.1", false },
        .{ ProviderKind.openai, "gpt-4o", true },
        .{ ProviderKind.openai, "o3-mini", false },
        .{ ProviderKind.openai, "gpt-3.5-turbo", false },
        .{ ProviderKind.openai, "gpt-4-0613", false },
        .{ ProviderKind.openai, "glm-5.2", false },
        .{ ProviderKind.openai, "glm-4.5v", true },
        .{ ProviderKind.anthropic, "glm-5.3-flash", false },
        .{ ProviderKind.openai, "qwen3-vl-235b", true },
        .{ ProviderKind.openai, "minimax-m3", true },
        .{ ProviderKind.gemini, "gemini-2.5-pro", true },
    }) |case| {
        const profile = profileFor(case[0], case[1]);
        try std.testing.expectEqual(case[2], profile.supports_image_input);
        try std.testing.expectEqual(Source.model_family, profile.image_input_source);
    }
    // Nobody knows: refused by default, but the source says unknown, not "unsupported".
    inline for (.{
        .{ ProviderKind.openai, "llama-3.3-70b" },
        .{ ProviderKind.openai, "grok-4" },
        .{ ProviderKind.openai, "deepseek-chat" },
        .{ ProviderKind.openai, "kimi-k3" },
        .{ ProviderKind.openai, "minimax-m2.5" },
        .{ ProviderKind.openai, "mistral-large" },
        .{ ProviderKind.openai, "qwen3-235b" },
        .{ ProviderKind.anthropic, "test-model" },
        .{ ProviderKind.other, "mystery" },
    }) |case| {
        const profile = profileFor(case[0], case[1]);
        try std.testing.expect(!profile.supports_image_input);
        try std.testing.expectEqual(Source.unknown, profile.image_input_source);
    }
    try std.testing.expectEqual(@as(?bool, null), familyImageInput("vendor-new-model"));
}

test "profileFor: multimodal functionResponse 仅 Gemini 3 系 true" {
    try std.testing.expect(profileFor(.gemini, "gemini-3-flash").supports_multimodal_function_response);
    try std.testing.expect(profileFor(.gemini, "gemini-3.1-pro").supports_multimodal_function_response);
    try std.testing.expect(!profileFor(.gemini, "gemini-2.5-pro").supports_multimodal_function_response);
    try std.testing.expect(!profileFor(.anthropic, "claude-sonnet-4-20250514").supports_multimodal_function_response);
    try std.testing.expect(!profileFor(.openai, "gpt-5.2").supports_multimodal_function_response);
}
