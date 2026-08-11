//! OpenAI-compatible dialect 实现(覆盖 OpenAI 原生 + GLM-5 + Kimi K3 + DeepSeek + Qwen3 + Mistral)。
//!
//! 这些模型都走 OpenAI chat/completions wire 协议(Provider=OpenAIClient),但各有
//! thinking 控制 / system 改写 / reasoning_content 解析的变体。本文件把它们集中,
//! serializeOpenAIRequest 通过 dialectFor(.openai, model).serializeThinking(...) 调用,
//! 不再自己 switch(profile.thinking_mode)。
//!
//! 设计:每厂商一个 namespace,导出一组静态 fn;Dialect struct 用 fn-ptr 指向它们。
//! 新增厂商 = 加一个 namespace + 注册一行。

const std = @import("std");
const types = @import("../../types.zig");
const util_json = @import("../../util/json.zig");
const model_adapter = @import("../model_adapter.zig");
const dialect_mod = @import("../dialect.zig");

const Dialect = dialect_mod.Dialect;
const ModelProfile = model_adapter.ModelProfile;
const ReasoningEffort = types.ReasoningEffort;
const ToolChoice = dialect_mod.ToolChoice;
const ResponseFormatRequest = dialect_mod.ResponseFormatRequest;

// ── 公共 helper ──────────────────────────────────────────────────────────────

/// OpenAI-compatible dialect 共享一个 ctx 类型(无状态),所有变体共用。
/// 不同厂商的 Dialect.ctx 都指向同一个静态 sentinel——它们是无状态的纯函数集合。
const Stateless = struct {};

var stateless: Stateless = .{};

fn statelessCtx() *anyopaque {
    return @ptrCast(&stateless);
}

// ── 共享:tool_choice 序列化(所有 OpenAI-compatible dialect 同 wire 格式)─────────
//
// 中立 ToolChoice(Anthropic 语义)→ OpenAI chat/completions wire:
//   auto     → "auto"
//   any      → "required"(OpenAI 强制选一个工具的语义)
//   tool+name→ {"type":"function","function":{"name":...}}
//   none     → "none"
//
// 能力降级:GLM-5 profile.tool_choice_support==.auto_only,任何非 auto 都降级成 "auto"
// (服务端拒 required/function,静默降级保请求成功)。其它 dialect 全支持。
// **本函数是 OpenAI-compatible 协议的单一真相源**——6 个 dialect struct 都指向它,
// 通过 profile 参数实现 per-model 降级(无需每个 dialect 重复实现)。
fn openaiSerializeToolChoice(ctx: *anyopaque, p: ModelProfile, tc: ?ToolChoice, out: *std.ArrayList(u8), a: std.mem.Allocator) anyerror!bool {
    _ = ctx;
    const t = tc orelse return false;
    // GLM-5 仅支持 auto:降级
    if (p.tool_choice_support == .auto_only) {
        try out.appendSlice(a, ",\"tool_choice\":\"auto\"");
        return true;
    }
    if (std.mem.eql(u8, t.type, "auto") or std.mem.eql(u8, t.type, "none")) {
        try out.appendSlice(a, ",\"tool_choice\":");
        try util_json.serializeString(t.type, out, a);
        return true;
    }
    if (std.mem.eql(u8, t.type, "any") or std.mem.eql(u8, t.type, "required")) {
        try out.appendSlice(a, ",\"tool_choice\":\"required\"");
        return true;
    }
    if (std.mem.eql(u8, t.type, "tool")) {
        if (t.name) |n| {
            try out.appendSlice(a, ",\"tool_choice\":{\"type\":\"function\",\"function\":{\"name\":");
            try util_json.serializeString(n, out, a);
            try out.appendSlice(a, "}}");
            return true;
        }
        // name 缺失:退到 required
        try out.appendSlice(a, ",\"tool_choice\":\"required\"");
        return true;
    }
    // 未识别 type:不发(让服务端用默认)
    return false;
}

// ── 共享:response_format 序列化(所有 OpenAI-compatible dialect 同 wire 格式)─────────
//
// 中立 ResponseFormatRequest → OpenAI chat/completions wire:
//   json_object → ",\"response_format\":{\"type\":\"json_object\"}"
//   json_schema → ",\"response_format\":{\"type\":\"json_schema\",\"json_schema\":{\"schema\":<schema>}}"
//
// 能力降级:GLM-5 profile.response_format_support==.json_object_only,json_schema 降级为
// json_object(服务端拒 json_schema,静默降级保请求成功)。
fn openaiSerializeResponseFormat(ctx: *anyopaque, p: ModelProfile, rf: ?ResponseFormatRequest, out: *std.ArrayList(u8), a: std.mem.Allocator) anyerror!bool {
    _ = ctx;
    const r = rf orelse return false;
    if (r.kind == .none) return false;
    // GLM-5 仅 json_object:json_schema 降级
    const kind: ResponseFormatRequest = if (p.response_format_support == .json_object_only and r.kind == .json_schema) .{ .kind = .json_object } else r;
    if (kind.kind == .json_object) {
        try out.appendSlice(a, ",\"response_format\":{\"type\":\"json_object\"}");
        return true;
    }
    if (kind.kind == .json_schema) {
        if (kind.schema) |s| {
            try out.appendSlice(a, ",\"response_format\":{\"type\":\"json_schema\",\"json_schema\":{\"schema\":");
            try out.appendSlice(a, s);
            try out.appendSlice(a, "}}");
            return true;
        }
        // schema 缺失:退到 json_object
        try out.appendSlice(a, ",\"response_format\":{\"type\":\"json_object\"}");
        return true;
    }
    return false;
}

// ── 共享:prompt_cache_key 序列化(OpenAI 原生 + DeepSeek + Kimi 支持)─────────────
//
// 中立 key → OpenAI chat/completions 顶层 \"prompt_cache_key\":\"<key>\"。
// 该字段是 OpenAI 2024 引入的显式 cache 提示(同 prompt 命中率提升),DeepSeek/Kimi
// 兼容此字段。GLM-5/Qwen/Mistral 当前不支持,但服务端忽略未知字段(无害)。
// 能力守门:profile.supports_prompt_cache_key=false 时不发(避免给不支持的服务端
// 加无意义字段;虽然无害,但能力探测应保持诚实)。
fn openaiSerializePromptCacheKey(ctx: *anyopaque, p: ModelProfile, key: ?[]const u8, out: *std.ArrayList(u8), a: std.mem.Allocator) anyerror!bool {
    _ = ctx;
    if (!p.supports_prompt_cache_key) return false;
    const k = key orelse return false;
    try out.appendSlice(a, ",\"prompt_cache_key\":");
    try util_json.serializeString(k, out, a);
    return true;
}

// ── OpenAI 原生(GPT-4o / GPT-5 / o1 / o3)──────────────────────────────────
const OpenAINative = struct {
    fn serializeThinking(ctx: *anyopaque, p: ModelProfile, effort: ?ReasoningEffort, out: *std.ArrayList(u8), a: std.mem.Allocator) anyerror!void {
        _ = ctx;
        _ = p;
        // OpenAI 原生:reasoning.effort 嵌套对象(GPT-5/o3)。effort 直接透传 7 档。
        if (effort) |e| if (e.active()) {
            try out.appendSlice(a, ",\"reasoning_effort\":");
            try util_json.serializeString(e.name(), out, a);
        };
    }

    fn extractThinkingDelta(ctx: *anyopaque, raw: []const u8, a: std.mem.Allocator) anyerror!?[]u8 {
        _ = ctx;
        _ = raw;
        _ = a;
        // OpenAI 原生不返回 reasoning_content 字段(仅 reasoning_tokens 计数)。
        return null;
    }

    const dialect = Dialect{
        .ctx = undefined, // 运行时由 statelessCtx() 填
        .serializeThinkingFn = serializeThinking,
        .extractThinkingDeltaFn = extractThinkingDelta,
        .serializeToolChoiceFn = openaiSerializeToolChoice,
        .serializeResponseFormatFn = openaiSerializeResponseFormat,
        .serializePromptCacheKeyFn = openaiSerializePromptCacheKey,
        // injectSystemMods / supportsToolChoice / supportsResponseFormat / profile 走 default
    };
};

// ── GLM-5 ──────────────────────────────────────────────────────────────────
const Glm = struct {
    fn serializeThinking(ctx: *anyopaque, p: ModelProfile, effort: ?ReasoningEffort, out: *std.ArrayList(u8), a: std.mem.Allocator) anyerror!void {
        _ = ctx;
        _ = p;
        // GLM-5:thinking:{type} 在 body(OpenAI-compatible),effort 7→2 映射注入 system prompt 标签。
        // effort=null 时默认 enabled(GLM 自动判断是否思考)。
        const enable = if (effort) |e| e.active() else true;
        try out.appendSlice(a, ",\"thinking\":{\"type\":");
        try util_json.serializeString(if (enable) "enabled" else "disabled", out, a);
        try out.append(a, '}');
        if (enable) {
            // clear_thinking=false(保留)→ 对齐 preserved thinking;coding-plan 默认。
            try out.appendSlice(a, ",\"clear_thinking\":false");
        }
    }

    fn injectSystemMods(ctx: *anyopaque, p: ModelProfile, effort: ?ReasoningEffort, sys: *std.ArrayList(u8), a: std.mem.Allocator) anyerror!void {
        _ = ctx;
        _ = p;
        // effort 7→2 映射:low/medium/high → "high";xhigh → "max";none/minimal → 跳过(不发标签)。
        if (effort) |e| if (e.active()) {
            if (model_adapter.glmEffortMap(e)) |mapped| {
                try sys.appendSlice(a, "\n<reasoning_effort> ");
                try sys.appendSlice(a, mapped);
            }
        };
    }

    fn extractThinkingDelta(ctx: *anyopaque, raw: []const u8, a: std.mem.Allocator) anyerror!?[]u8 {
        _ = ctx;
        // GLM-5 OpenAI-compatible 端点返回 reasoning_content 平级字段。
        if (util_json.extractStringField(raw, "reasoning_content")) |r| {
            if (r.len > 0) return try a.dupe(u8, r);
        }
        return null;
    }

    const dialect = Dialect{
        .ctx = undefined,
        .serializeThinkingFn = serializeThinking,
        .injectSystemModsFn = injectSystemMods,
        .extractThinkingDeltaFn = extractThinkingDelta,
        .serializeToolChoiceFn = openaiSerializeToolChoice,
        .serializeResponseFormatFn = openaiSerializeResponseFormat,
        .serializePromptCacheKeyFn = openaiSerializePromptCacheKey,
    };
};

// ── Kimi K3 ──────────────────────────────────────────────────────────────────
const Kimi = struct {
    fn serializeThinking(ctx: *anyopaque, p: ModelProfile, effort: ?ReasoningEffort, out: *std.ArrayList(u8), a: std.mem.Allocator) anyerror!void {
        _ = ctx;
        _ = p;
        // Kimi K3:thinking:{type,keep,effort} 在 body。effort 3 档(low/high/max)。
        const enable = if (effort) |e| e.active() else true;
        try out.appendSlice(a, ",\"thinking\":{\"type\":");
        try util_json.serializeString(if (enable) "enabled" else "disabled", out, a);
        if (enable) {
            try out.appendSlice(a, ",\"keep\":\"all\"");
            if (model_adapter.kimiEffortMap(effort.?)) |mapped| {
                try out.appendSlice(a, ",\"effort\":");
                try util_json.serializeString(mapped, out, a);
            }
        }
        try out.append(a, '}');
    }

    fn extractThinkingDelta(ctx: *anyopaque, raw: []const u8, a: std.mem.Allocator) anyerror!?[]u8 {
        _ = ctx;
        if (util_json.extractStringField(raw, "reasoning_content")) |r| {
            if (r.len > 0) return try a.dupe(u8, r);
        }
        return null;
    }

    const dialect = Dialect{
        .ctx = undefined,
        .serializeThinkingFn = serializeThinking,
        .extractThinkingDeltaFn = extractThinkingDelta,
        .serializeToolChoiceFn = openaiSerializeToolChoice,
        .serializeResponseFormatFn = openaiSerializeResponseFormat,
        .serializePromptCacheKeyFn = openaiSerializePromptCacheKey,
    };
};

// ── DeepSeek ────────────────────────────────────────────────────────────────
const DeepSeek = struct {
    fn serializeThinking(ctx: *anyopaque, p: ModelProfile, effort: ?ReasoningEffort, out: *std.ArrayList(u8), a: std.mem.Allocator) anyerror!void {
        _ = ctx;
        _ = p;
        // DeepSeek:thinking:{type} + reasoning_effort 顶层(两独立参数)。effort 1 档(high)。
        const enable = if (effort) |e| e.active() else true;
        try out.appendSlice(a, ",\"thinking\":{\"type\":");
        try util_json.serializeString(if (enable) "enabled" else "disabled", out, a);
        try out.append(a, '}');
        if (enable and model_adapter.deepseekEffortMap(effort.?) != null) {
            try out.appendSlice(a, ",\"reasoning_effort\":\"high\"");
        }
    }

    fn extractThinkingDelta(ctx: *anyopaque, raw: []const u8, a: std.mem.Allocator) anyerror!?[]u8 {
        _ = ctx;
        if (util_json.extractStringField(raw, "reasoning_content")) |r| {
            if (r.len > 0) return try a.dupe(u8, r);
        }
        return null;
    }

    const dialect = Dialect{
        .ctx = undefined,
        .serializeThinkingFn = serializeThinking,
        .extractThinkingDeltaFn = extractThinkingDelta,
        .serializeToolChoiceFn = openaiSerializeToolChoice,
        .serializeResponseFormatFn = openaiSerializeResponseFormat,
        .serializePromptCacheKeyFn = openaiSerializePromptCacheKey,
    };
};

// ── Qwen3 ────────────────────────────────────────────────────────────────────
const Qwen = struct {
    fn serializeThinking(ctx: *anyopaque, p: ModelProfile, effort: ?ReasoningEffort, out: *std.ArrayList(u8), a: std.mem.Allocator) anyerror!void {
        _ = ctx;
        _ = p;
        // Qwen3:enable_thinking bool + /think /no_think 文本指令(chat template 处理)。
        // body 只传 enable_thinking;文本指令由 system prompt 携带(调用方加,本 dialect 不注入)。
        const enable = if (effort) |e| e.active() else true;
        try out.appendSlice(a, ",\"enable_thinking\":");
        try out.appendSlice(a, if (enable) "true" else "false");
    }

    fn extractThinkingDelta(ctx: *anyopaque, raw: []const u8, a: std.mem.Allocator) anyerror!?[]u8 {
        _ = ctx;
        if (util_json.extractStringField(raw, "reasoning_content")) |r| {
            if (r.len > 0) return try a.dupe(u8, r);
        }
        return null;
    }

    const dialect = Dialect{
        .ctx = undefined,
        .serializeThinkingFn = serializeThinking,
        .extractThinkingDeltaFn = extractThinkingDelta,
        .serializeToolChoiceFn = openaiSerializeToolChoice,
        .serializeResponseFormatFn = openaiSerializeResponseFormat,
        .serializePromptCacheKeyFn = openaiSerializePromptCacheKey,
    };
};

// ── Mistral(ThinkChunk,语义同 reasoning_content)────────────────────────────
const Mistral = struct {
    fn extractThinkingDelta(ctx: *anyopaque, raw: []const u8, a: std.mem.Allocator) anyerror!?[]u8 {
        _ = ctx;
        if (util_json.extractStringField(raw, "reasoning_content")) |r| {
            if (r.len > 0) return try a.dupe(u8, r);
        }
        return null;
    }

    const dialect = Dialect{
        .ctx = undefined,
        .extractThinkingDeltaFn = extractThinkingDelta,
        .serializeToolChoiceFn = openaiSerializeToolChoice,
        .serializeResponseFormatFn = openaiSerializeResponseFormat,
        .serializePromptCacheKeyFn = openaiSerializePromptCacheKey,
    };
};

// ── dialectFor:按 model 子串返回对应 Dialect ────────────────────────────────
// 顺序敏感:先匹配更具体的(GLM-4 在 GLM 前);k2/kimi 都匹配 Kimi。
//
// **ctx 共享**:所有 OpenAI-compatible dialect 无状态,共享同一个 `stateless` 实例。
// 不同厂商只是 fn-ptr 集不同,ctx 指向同一块内存(不解引用)。

pub fn openaiDialectFor(model: []const u8) Dialect {
    if (model_adapter.hasSubstr(model, "glm-5") or model_adapter.hasSubstr(model, "glm4") or model_adapter.hasSubstr(model, "glm-4")) {
        return Glm.dialect.withCtx(statelessCtx());
    }
    if (model_adapter.hasSubstr(model, "kimi") or model_adapter.hasSubstr(model, "k2") or model_adapter.hasSubstr(model, "moonshot")) {
        return Kimi.dialect.withCtx(statelessCtx());
    }
    if (model_adapter.hasSubstr(model, "deepseek")) {
        return DeepSeek.dialect.withCtx(statelessCtx());
    }
    if (model_adapter.hasSubstr(model, "qwen3") or model_adapter.hasSubstr(model, "qwen-3")) {
        return Qwen.dialect.withCtx(statelessCtx());
    }
    if (model_adapter.hasSubstr(model, "mistral") or model_adapter.hasSubstr(model, "magistral")) {
        return Mistral.dialect.withCtx(statelessCtx());
    }
    // 默认:OpenAI 原生(GPT-4o / GPT-5 / o1 / o3 / 其它未注册)。
    return OpenAINative.dialect.withCtx(statelessCtx());
}

// Dialect.withCtx helper(因 const dialect 声明 ctx=undefined,运行时填)
// 注:Dialect.withCtx 方法在 dialect.zig 定义,这里直接用。

// ── 测试 ─────────────────────────────────────────────────────────────────────

test "openaiDialectFor: GLM-5 返 Glm dialect" {
    const d = openaiDialectFor("glm-5.2");
    const a = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try d.serializeThinking(.{}, .high, &out, a);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"thinking\":{\"type\":\"enabled\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "clear_thinking") != null);
}

test "openaiDialectFor: Kimi K3 返 Kimi dialect" {
    const d = openaiDialectFor("kimi-k2");
    const a = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try d.serializeThinking(.{}, .high, &out, a);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"keep\":\"all\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"effort\":\"high\"") != null);
}

test "openaiDialectFor: DeepSeek 返 DeepSeek dialect" {
    const d = openaiDialectFor("deepseek-chat");
    const a = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try d.serializeThinking(.{}, .high, &out, a);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"reasoning_effort\":\"high\"") != null);
}

test "openaiDialectFor: Qwen3 返 Qwen dialect" {
    const d = openaiDialectFor("qwen3-235b");
    const a = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try d.serializeThinking(.{}, .high, &out, a);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"enable_thinking\":true") != null);
}

test "openaiDialectFor: GPT-4o 返 OpenAI native dialect" {
    const d = openaiDialectFor("gpt-4o");
    const a = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try d.serializeThinking(.{}, .high, &out, a);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"reasoning_effort\":\"high\"") != null);
    // OpenAI 原生不发 thinking:{} 对象
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"thinking\":") == null);
}

test "openaiDialectFor: GLM system 标签注入" {
    const d = openaiDialectFor("glm-5.2");
    const a = std.testing.allocator;
    var sys: std.ArrayList(u8) = .empty;
    defer sys.deinit(a);
    try sys.appendSlice(a, "base system");
    try d.injectSystemMods(.{}, .high, &sys, a);
    try std.testing.expect(std.mem.indexOf(u8, sys.items, "<reasoning_effort> high") != null);
}

test "openaiDialectFor: GPT-4o 不注入 system 标签(default no-op)" {
    const d = openaiDialectFor("gpt-4o");
    const a = std.testing.allocator;
    var sys: std.ArrayList(u8) = .empty;
    defer sys.deinit(a);
    try sys.appendSlice(a, "base");
    try d.injectSystemMods(.{}, .high, &sys, a);
    try std.testing.expectEqualStrings("base", sys.items);
}

test "openaiDialectFor: extractThinkingDelta 解析 reasoning_content" {
    const a = std.testing.allocator;
    const d = openaiDialectFor("deepseek-chat");
    const got = try d.extractThinkingDelta("{\"delta\":{\"reasoning_content\":\"thinking...\"}}", a);
    try std.testing.expect(got != null);
    defer a.free(got.?);
    try std.testing.expectEqualStrings("thinking...", got.?);
}

test "openaiDialectFor: OpenAI 原生 extractThinkingDelta 返 null" {
    const a = std.testing.allocator;
    const d = openaiDialectFor("gpt-4o");
    const got = try d.extractThinkingDelta("{\"delta\":{\"content\":\"hi\"}}", a);
    try std.testing.expect(got == null);
}
