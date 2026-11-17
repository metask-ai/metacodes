//! # Google Gemini 接入
//!
//! Gemini 原生 generateContent wire 的方言。
//!
//! ## 接入点
//!
//! - Provider:`src/provider/profiles/gemini.zig`,渠道 `default`,
//!   `https://generativelanguage.googleapis.com`(传输层自己拼
//!   `/v1beta/models/{model}:streamGenerateContent?alt=sse`,`EndpointShape.base_origin`)。
//! - 环境变量:`GEMINI_API_KEY`(规范名)、`GOOGLE_API_KEY`。
//!
//! ## 协议
//!
//! - `gemini_generate_content`。鉴权:`x-goog-api-key` 头。
//!
//! ## 思考与推理
//!
//! - `generation_config.thinking_level`。本方言输出**片段**(不带外层包裹),由
//!   `gemini_client.zig` 的 gen_cfg 收集器合并;片段之间"非空才加前导逗号",与调用顺序无关。
//! - Gemini 3 及以后思考关不掉:none / minimal / low → low,medium → medium,
//!   high / xhigh / max → high。
//! - Gemini 2.5:none / minimal 不发(可关),low → low,其余 → high。
//! - 未指定不发,用型号自己的默认(Argon、3.8 Flash 是 medium,3.1 Pro 是 high)。
//!
//! ## 回传与缓存
//!
//! - Gemini 3 起每步第一个 functionCall 的 thought signature 必须回传:签名按调用 id
//!   存在客户端(`gemini_signatures.zig`),序列化时放回原 part。
//! - 缓存:隐式缓存 + `cachedContent` 句柄表(`gemini_client.zig`),不经方言。
//!
//! ## 已知差异
//!
//! - `tool_choice` → `tool_config.function_calling_config.mode`(AUTO / ANY / NONE),
//!   指定工具时加 `allowed_function_names`。
//! - `response_format` 只发 `response_mime_type:"application/json"`,schema 不传。
//! - 不发 `prompt_cache_key` / `parallel_tool_calls`(Gemini 默认并行)。
//!
//! ## 来源
//!
//! - https://ai.google.dev/gemini-api/docs/thinking(2026-10 核对:默认档位)
//! - https://ai.google.dev/gemini-api/docs/function-calling(thought signatures)

const std = @import("std");
const types = @import("../../types.zig");
const util_json = @import("../../util/json.zig");
const model_adapter = @import("../model_adapter.zig");
const dialect_mod = @import("../dialect.zig");

const Dialect = dialect_mod.Dialect;
const ModelProfile = model_adapter.ModelProfile;
const profileFor = model_adapter.profileFor;
const ReasoningEffort = types.ReasoningEffort;
const ToolChoice = dialect_mod.ToolChoice;
const ResponseFormatRequest = dialect_mod.ResponseFormatRequest;
const ProviderKind = model_adapter.ProviderKind;
const Vendor = @import("../../provider/vendor.zig").Vendor;

const Stateless = struct {};
var stateless: Stateless = .{};
fn statelessCtx() *anyopaque {
    return @ptrCast(&stateless);
}

/// effort → Gemini thinking_level 映射。Gemini 2.5 4 档(minimal/low/medium/high),
/// Gemini 3.x 不能关 thinking(none/minimal → low)。
fn geminiThinkingLevel(p: ModelProfile, effort: ReasoningEffort) ?[]const u8 {
    if (p.cannot_disable_thinking) {
        // Gemini 3.x:none/minimal → low(不能关);low → low;medium → medium;high/xhigh → high。
        return switch (effort) {
            .none, .minimal, .low => "low",
            .medium => "medium",
            .high, .xhigh, .max => "high",
        };
    }
    // Gemini 2.5:none/minimal → 不发(可关);low → low;medium/high/xhigh → high。
    if (!effort.active()) return null;
    return switch (effort) {
        .minimal, .low => "low",
        .medium, .high, .xhigh, .max => "high",
        .none => null,
    };
}

const Gemini = struct {
    fn serializeThinking(ctx: *anyopaque, p: ModelProfile, effort: ?ReasoningEffort, out: *std.ArrayList(u8), a: std.mem.Allocator) anyerror!void {
        _ = ctx;
        // Gemini:generation_config.thinking_level(低/高)。输出 **片段**(不带外层包裹),
        // 由 serializeGeminiRequest 的 gen_cfg 合并逻辑收进 generation_config。
        // **逗号策略**:与 serializeResponseFormat 一致——若 out 非空(已有片段)则加前导逗号。
        // 这让两个片段函数调用顺序无关(gen_cfg 收集器不需关心谁先调)。
        // No level chosen leaves the model's own default: medium on Gemini 4
        // Argon and 3.8 Flash, high on 3.1 Pro (ai.google.dev .../thinking,
        // 2026-10). Sending `low` there, as this did, quietly cut the
        // reasoning of every session that never picked a level. A chosen
        // none/minimal on a model that cannot stop thinking is still `low`.
        if (effort) |e| if (geminiThinkingLevel(p, e)) |level| {
            if (out.items.len > 0) try out.appendSlice(a, ",");
            try out.appendSlice(a, "\"thinking_level\":");
            try util_json.serializeString(level, out, a);
        };
    }

    /// Gemini:tool_choice → tool_config.function_calling_config.mode + allowed_function_names。
    /// 中立语义映射:auto→AUTO,any→ANY,tool+name→ANY+allowed_function_names=[name],none→NONE。
    /// 输出片段形如 `"tool_config":{"function_calling_config":{"mode":"ANY","allowed_function_names":["web_search"]}}`,
    /// 由 serializeGeminiRequest 合并进请求体。
    fn serializeToolChoice(ctx: *anyopaque, p: ModelProfile, tc: ?ToolChoice, out: *std.ArrayList(u8), a: std.mem.Allocator) anyerror!bool {
        _ = ctx;
        _ = p;
        const t = tc orelse return false;
        const mode: []const u8 = blk: {
            if (std.mem.eql(u8, t.type, "auto")) break :blk "AUTO";
            if (std.mem.eql(u8, t.type, "any") or std.mem.eql(u8, t.type, "required")) break :blk "ANY";
            if (std.mem.eql(u8, t.type, "tool")) break :blk "ANY";
            if (std.mem.eql(u8, t.type, "none")) break :blk "NONE";
            return false; // 未识别 type:不发
        };
        try out.appendSlice(a, ",\"tool_config\":{\"function_calling_config\":{\"mode\":");
        try util_json.serializeString(mode, out, a);
        // tool+name → allowed_function_names:[name](Gemini 靠此锁定单工具)
        if (std.mem.eql(u8, t.type, "tool")) {
            if (t.name) |n| {
                try out.appendSlice(a, ",\"allowed_function_names\":[");
                try util_json.serializeString(n, out, a);
                try out.appendSlice(a, "]");
            }
        }
        try out.appendSlice(a, "}}");
        return true;
    }

    /// Gemini:response_format → response_mime_type 片段(由 serializeGeminiRequest
    /// 的 gen_cfg 合并逻辑收进 generation_config,不带外层包裹)。
    /// Gemini 不支持 json_schema 单独字段,schema 进 generation_config.response_schema,
    /// 当前只接 json_object,留位 schema 待消费方需要时再扩。
    /// **返回片段格式**:`"response_mime_type":"application/json"`(不带前导逗号或包裹,
    /// 由调用方合并进 gen_cfg ArrayList,与 thinking_level 等其它片段同级)。
    fn serializeResponseFormat(ctx: *anyopaque, p: ModelProfile, rf: ?ResponseFormatRequest, out: *std.ArrayList(u8), a: std.mem.Allocator) anyerror!bool {
        _ = ctx;
        _ = p;
        const r = rf orelse return false;
        if (r.kind == .none) return false;
        // json_object 或 json_schema(降级为 json_object,Gemini 当前只接 mime_type)
        // 片段格式:与 serializeThinking 的 "thinking_level":"low" 同级(无前导逗号)。
        if (out.items.len > 0) try out.appendSlice(a, ",");
        try out.appendSlice(a, "\"response_mime_type\":\"application/json\"");
        return true;
    }

    /// Gemini generateContent 图像 part:{"inline_data":{"mime_type":<mime>,"data":<b64>}}。
    /// 输出单个 part 对象(与 {"text":..} 同级),数组逗号由 serializeGeminiContent 管理。
    /// 能力守门在 Dialect.serializeImagePart wrapper(集中一处);本实现只管 wire 形态。
    fn serializeImagePart(ctx: *anyopaque, p: ModelProfile, image: types.ImageBlock, out: *std.ArrayList(u8), a: std.mem.Allocator) anyerror!bool {
        _ = ctx;
        _ = p;
        try out.appendSlice(a, "{\"inline_data\":{\"mime_type\":");
        try util_json.serializeString(image.media_type, out, a);
        try out.appendSlice(a, ",\"data\":");
        try util_json.serializeString(image.data, out, a);
        try out.appendSlice(a, "}}");
        return true;
    }

    const dialect = Dialect{
        .ctx = undefined,
        .serializeThinkingFn = serializeThinking,
        .serializeToolChoiceFn = serializeToolChoice,
        .serializeResponseFormatFn = serializeResponseFormat,
        .serializeImagePartFn = serializeImagePart,
    };
};

pub const vendor: Vendor = .gemini;

/// Gemini 是 generateContent wire 的唯一方言,不参与按名推断。
pub fn claims(kind: ProviderKind, model: []const u8) bool {
    _ = kind;
    _ = model;
    return false;
}

pub fn dialect(kind: ProviderKind, model: []const u8) ?Dialect {
    _ = model;
    return if (kind == .gemini) Gemini.dialect.withCtx(statelessCtx()) else null;
}

fn geminiDialectFor(model: []const u8) Dialect {
    return dialect(.gemini, model).?;
}

// ── 测试 ─────────────────────────────────────────────────────────────────────

test "geminiDialectFor: effort=high 发 thinking_level high" {
    const d = geminiDialectFor("gemini-2.5-pro");
    const a = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try d.serializeThinking(.{}, .high, &out, a);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"thinking_level\":\"high\"") != null);
}

test "geminiDialectFor: effort=low 发 thinking_level low" {
    const d = geminiDialectFor("gemini-2.5-pro");
    const a = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try d.serializeThinking(.{}, .low, &out, a);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"thinking_level\":\"low\"") != null);
}

test "geminiDialectFor: 2.5 effort=null 不发 thinking_level(可关)" {
    const d = geminiDialectFor("gemini-2.5-pro");
    const a = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try d.serializeThinking(.{}, null, &out, a);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}

test "geminiDialectFor: no chosen level leaves the model's own default" {
    // Gemini 3+ cannot stop thinking, but its default is not `low` (Argon and
    // 3.8 Flash default to medium, 3.1 Pro to high): an unset level sends
    // nothing rather than lowering it.
    inline for (.{ "gemini-3.1-pro", "gemini-4-argon", "gemini-3.8-flash" }) |model| {
        const d = geminiDialectFor(model);
        const p = profileFor(.gemini, model);
        try std.testing.expect(p.cannot_disable_thinking);
        const a = std.testing.allocator;
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(a);
        try d.serializeThinking(p, null, &out, a);
        try std.testing.expectEqual(@as(usize, 0), out.items.len);
    }
}

test "geminiDialectFor: 3.1 Pro effort=none 仍发 low(不能关,降级到默认)" {
    const d = geminiDialectFor("gemini-3.1-pro");
    const p = profileFor(.gemini, "gemini-3.1-pro");
    const a = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try d.serializeThinking(p, .none, &out, a);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"thinking_level\":\"low\"") != null);
}

test "geminiDialectFor: 3.1 Pro effort=minimal 降级 low(3.1 Pro 把 minimal→low,不保留 minimal)" {
    const d = geminiDialectFor("gemini-3.1-pro");
    const p = profileFor(.gemini, "gemini-3.1-pro");
    const a = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try d.serializeThinking(p, .minimal, &out, a);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"thinking_level\":\"low\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "minimal") == null);
}

test "geminiDialectFor: 3.1 Pro effort=high 仍发 high" {
    const d = geminiDialectFor("gemini-3.1-pro");
    const p = profileFor(.gemini, "gemini-3.1-pro");
    const a = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try d.serializeThinking(p, .high, &out, a);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"thinking_level\":\"high\"") != null);
}

test "geminiDialectFor: 2.5 effort=none 不发(可关,与 3.x 区别)" {
    const d = geminiDialectFor("gemini-2.5-pro");
    const p = profileFor(.gemini, "gemini-2.5-pro");
    try std.testing.expect(!p.cannot_disable_thinking);
    const a = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try d.serializeThinking(p, .none, &out, a);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}

// ── 片段合并逗号策略(顺序无关)─────────────────────────────────────────────
// gen_cfg 收集器把 serializeThinking + serializeResponseFormat 的片段合并进一个
// generation_config。两个片段函数都必须用"若 out 非空则加前导逗号"策略,否则
// 调用顺序敏感:先调的片段没前导逗号(正确),后调的片段缺逗号(JSON 破损)。

test "Gemini 片段合并: thinking 先 + response_format 后,逗号正确" {
    const d = geminiDialectFor("gemini-2.5-pro");
    const a = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try d.serializeThinking(.{}, .high, &out, a);
    _ = try d.serializeResponseFormat(.{}, .{ .kind = .json_object }, &out, a);
    // 期望:thinking_level 在前,response_mime_type 在后,中间有逗号
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"thinking_level\":\"high\",\"response_mime_type\":\"application/json\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"thinking_level\":\"high\"\"response_mime_type") == null); // 无缺逗号破损
}

test "Gemini 片段合并: response_format 先 + thinking 后,逗号正确" {
    const d = geminiDialectFor("gemini-2.5-pro");
    const a = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    _ = try d.serializeResponseFormat(.{}, .{ .kind = .json_object }, &out, a);
    try d.serializeThinking(.{}, .high, &out, a);
    // 期望:response_mime_type 在前,thinking_level 在后,中间有逗号
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"response_mime_type\":\"application/json\",\"thinking_level\":\"high\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "application/json\"\"thinking_level") == null); // 无缺逗号破损
}

test "Gemini dialect: serializeImagePart 发 inline_data part" {
    const d = geminiDialectFor("gemini-2.5-pro");
    const a = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    const p = d.profileFor(.gemini, "gemini-2.5-pro");
    const ok = try d.serializeImagePart(p, .{ .media_type = "image/jpeg", .data = "SlBFRw==" }, &out, a);
    try std.testing.expect(ok);
    try std.testing.expectEqualStrings(
        "{\"inline_data\":{\"mime_type\":\"image/jpeg\",\"data\":\"SlBFRw==\"}}",
        out.items,
    );
}
