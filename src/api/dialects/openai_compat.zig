//! OpenAI chat/completions 兼容方言的公共部件。
//!
//! 这不是一家厂商的接入文件,而是所有走 OpenAI chat/completions wire 的厂商方言共用的
//! 积木:tool_choice / response_format / prompt_cache_key / parallel_tool_calls / 图像
//! content part 的 wire 形态,以及 `reasoning_content` 流式增量的解码。各厂商文件
//! (`openai.zig`、`glm.zig`、`kimi.zig`、`deepseek.zig`、`qwen.zig`、`minimax.zig`、
//! `mistral.zig`)从 `base` 出发,只覆盖自己真正不同的那几个方法。
//!
//! 每个方法都按 `ModelProfile` 做能力守门:同一套 wire 形态,不同模型通过 profile 上的
//! 能力位降级(例如 GLM-5 只认 `tool_choice:"auto"`)。

const std = @import("std");
const types = @import("../../types.zig");
const util_json = @import("../../util/json.zig");
const model_adapter = @import("../model_adapter.zig");
const dialect_mod = @import("../dialect.zig");

const Dialect = dialect_mod.Dialect;
const ModelProfile = model_adapter.ModelProfile;
const ToolChoice = dialect_mod.ToolChoice;
const ResponseFormatRequest = dialect_mod.ResponseFormatRequest;

/// 所有无状态方言共享的 ctx 哨兵:方言是纯函数集合,ctx 从不解引用。
const Stateless = struct {};
var stateless: Stateless = .{};

pub fn statelessCtx() *anyopaque {
    return @ptrCast(&stateless);
}

/// 一个方言值:声明处 `ctx = undefined`,取用时补上共享哨兵。
pub fn ready(d: Dialect) Dialect {
    return d.withCtx(statelessCtx());
}

/// OpenAI chat/completions 兼容方言的出发点。厂商文件拷贝它,再覆盖思考相关的方法。
/// 默认解析 `reasoning_content`;OpenAI 原生不返回该字段,由 `openai.zig` 换掉。
pub const base = Dialect{
    .ctx = undefined,
    .extractThinkingDeltaFn = extractReasoningContent,
    .serializeToolChoiceFn = serializeToolChoice,
    .serializeResponseFormatFn = serializeResponseFormat,
    .serializePromptCacheKeyFn = serializePromptCacheKey,
    .serializeParallelToolCallsFn = serializeParallelToolCalls,
    .serializeImagePartFn = serializeImagePart,
};

// ── tool_choice ──────────────────────────────────────────────────────────────
//
// 中立 ToolChoice(Anthropic 语义)→ OpenAI chat/completions wire:
//   auto     → "auto"
//   any      → "required"(OpenAI 强制选一个工具的语义)
//   tool+name→ {"type":"function","function":{"name":...}}
//   none     → "none"
//
// 能力降级:GLM-5 profile.tool_choice_support==.auto_only,任何非 auto 都降级成 "auto"
// (服务端拒 required/function,降级保请求成功)。其它方言全支持。
pub fn serializeToolChoice(ctx: *anyopaque, p: ModelProfile, tc: ?ToolChoice, out: *std.ArrayList(u8), a: std.mem.Allocator) anyerror!bool {
    _ = ctx;
    const t = tc orelse return false;
    // none 是通用语义(不调用工具),所有 OpenAI-compatible 服务端都认,不降级。
    if (std.mem.eql(u8, t.type, "none")) {
        try out.appendSlice(a, ",\"tool_choice\":\"none\"");
        return true;
    }
    // GLM-5 仅支持 auto:none(不支持 required/function)。auto 透传,其它降级成 auto。
    if (p.tool_choice_support == .auto_only) {
        try out.appendSlice(a, ",\"tool_choice\":\"auto\"");
        return true;
    }
    if (std.mem.eql(u8, t.type, "auto")) {
        try out.appendSlice(a, ",\"tool_choice\":\"auto\"");
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

// ── response_format ──────────────────────────────────────────────────────────
//
//   json_object → ",\"response_format\":{\"type\":\"json_object\"}"
//   json_schema → ",\"response_format\":{\"type\":\"json_schema\",\"json_schema\":{\"name\":\"response\",\"schema\":<schema>}}"
//   (name 是 OpenAI 必填字段——缺失服务端 400 "Missing required parameter";中立请求
//   结构无 name 概念,发固定 "response"。)
//
// 能力降级:GLM-5 profile.response_format_support==.json_object_only,json_schema 降级为
// json_object(服务端拒 json_schema)。
pub fn serializeResponseFormat(ctx: *anyopaque, p: ModelProfile, rf: ?ResponseFormatRequest, out: *std.ArrayList(u8), a: std.mem.Allocator) anyerror!bool {
    _ = ctx;
    const req = rf orelse return false;
    if (req.kind == .none) return false;
    const effective: ResponseFormatRequest = if (p.response_format_support == .json_object_only and req.kind == .json_schema) .{ .kind = .json_object } else req;
    if (effective.kind == .json_object) {
        try out.appendSlice(a, ",\"response_format\":{\"type\":\"json_object\"}");
        return true;
    }
    if (effective.kind == .json_schema) {
        if (effective.schema) |s| {
            try out.appendSlice(a, ",\"response_format\":{\"type\":\"json_schema\",\"json_schema\":{\"name\":\"response\",\"schema\":");
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

// ── prompt_cache_key ─────────────────────────────────────────────────────────
//
// 中立 key → 顶层 \"prompt_cache_key\":\"<key>\"。只对 profile.supports_prompt_cache_key
// 已确认支持的模型发:未实测的服务端遇到未知字段可能 400。
pub fn serializePromptCacheKey(ctx: *anyopaque, p: ModelProfile, key: ?[]const u8, out: *std.ArrayList(u8), a: std.mem.Allocator) anyerror!bool {
    _ = ctx;
    if (!p.supports_prompt_cache_key) return false;
    const k = key orelse return false;
    try out.appendSlice(a, ",\"prompt_cache_key\":");
    try util_json.serializeString(k, out, a);
    return true;
}

// ── parallel_tool_calls ──────────────────────────────────────────────────────
//
// 中立 enabled → 顶层 \"parallel_tool_calls\":true/false。只对
// profile.supports_parallel_tool_calls 的模型发(Mistral 支持显式关闭)。
pub fn serializeParallelToolCalls(ctx: *anyopaque, p: ModelProfile, enabled: ?bool, out: *std.ArrayList(u8), a: std.mem.Allocator) anyerror!bool {
    _ = ctx;
    if (!p.supports_parallel_tool_calls) return false;
    const e = enabled orelse return false;
    try out.appendSlice(a, ",\"parallel_tool_calls\":");
    try out.appendSlice(a, if (e) "true" else "false");
    return true;
}

// ── 图像 content part ────────────────────────────────────────────────────────
//
// 中立 ImageBlock → {"type":"image_url","image_url":{"url":"data:<mime>;base64,<data>"}}
// (vision 全生态标准形态。Responses API 的 input_image 是 responses-local 形态,不经此方法。)
// 能力守门在 Dialect.serializeImagePart wrapper;本函数只管 wire 形态。
pub fn serializeImagePart(ctx: *anyopaque, p: ModelProfile, image: types.ImageBlock, out: *std.ArrayList(u8), a: std.mem.Allocator) anyerror!bool {
    _ = ctx;
    _ = p;
    try out.appendSlice(a, "{\"type\":\"image_url\",\"image_url\":{\"url\":\"");
    try writeImageDataUrl(image, out, a);
    try out.appendSlice(a, "\"}}");
    return true;
}

/// data URL 核心(`data:<mime>;base64,<data>`,不带外围引号):chat 的 image_url 与
/// Responses 的 input_image 共用同一注入安全实现。分段走 serializeStringContents——
/// 不信任上游校验,异常字节在此被正确转义,不破坏请求 JSON 结构。
pub fn writeImageDataUrl(image: types.ImageBlock, out: *std.ArrayList(u8), a: std.mem.Allocator) !void {
    try out.appendSlice(a, "data:");
    try util_json.serializeStringContents(image.media_type, out, a);
    try out.appendSlice(a, ";base64,");
    try util_json.serializeStringContents(image.data, out, a);
}

// ── reasoning_content 流式增量 ───────────────────────────────────────────────
//
// 兼容端点把 reasoning_content 作为 delta 平级字符串字段流式返回。SSE 片段带一层 JSON
// 转义——必须解除后再交 UI/回传,否则思考文本把转义序列当字面量显示(issue #4)。
// 空片段 free-and-null(不发事件)。
pub fn extractReasoningContent(ctx: *anyopaque, raw: []const u8, a: std.mem.Allocator) anyerror!?[]u8 {
    _ = ctx;
    return extractStringDelta(raw, "reasoning_content", a);
}

/// `extractReasoningContent` 的通用形:按字段名取一个流式字符串增量。
pub fn extractStringDelta(raw: []const u8, field: []const u8, a: std.mem.Allocator) !?[]u8 {
    if (try util_json.extractAndUnescapeStringField(raw, field, a)) |r| {
        if (r.len > 0) return r;
        a.free(r);
    }
    return null;
}

/// 追加 `,"<name>":"<value>"`。
pub fn appendStringField(out: *std.ArrayList(u8), a: std.mem.Allocator, name: []const u8, value: []const u8) !void {
    try out.appendSlice(a, ",\"");
    try out.appendSlice(a, name);
    try out.appendSlice(a, "\":");
    try util_json.serializeString(value, out, a);
}

test "base 方言: reasoning_content 增量解转义,空片段不出事件" {
    const a = std.testing.allocator;
    const d = ready(base);
    const got = (try d.extractThinkingDelta("{\"delta\":{\"reasoning_content\":\"a\\nb\"}}", a)).?;
    defer a.free(got);
    try std.testing.expectEqualStrings("a\nb", got);
    try std.testing.expect(try d.extractThinkingDelta("{\"delta\":{\"reasoning_content\":\"\"}}", a) == null);
    try std.testing.expect(try d.extractThinkingDelta("{\"delta\":{\"content\":\"x\"}}", a) == null);
}
