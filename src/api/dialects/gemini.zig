//! Google Gemini dialect 实现。
//!
//! Gemini thinking 控制:generation_config.thinking_level = "low"/"high"(Gemini 2.5+)。
//! Gemini 不经 OpenAI-compatible 端点,走原生 generateContent;但 dialect 仍提供 serializeThinking
//! 供未来 Gemini 侧接 thinking 控制时用(当前 gemini_client.zig 未接,留位)。

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

const Stateless = struct {};
var stateless: Stateless = .{};
fn statelessCtx() *anyopaque {
    return @ptrCast(&stateless);
}

/// effort → Gemini thinking_level 映射。Gemini 只 2 档(low/high)。
fn geminiThinkingLevel(effort: ReasoningEffort) ?[]const u8 {
    if (!effort.active()) return null;
    return switch (effort) {
        .minimal, .low => "low",
        .medium, .high, .xhigh => "high",
        .none => null,
    };
}

const Gemini = struct {
    fn serializeThinking(ctx: *anyopaque, p: ModelProfile, effort: ?ReasoningEffort, out: *std.ArrayList(u8), a: std.mem.Allocator) anyerror!void {
        _ = ctx;
        _ = p;
        // Gemini:generation_config.thinking_level(低/高)。输出 **片段**(不带外层包裹),
        // 由 serializeGeminiRequest 的 gen_cfg 合并逻辑收进 generation_config。
        // **逗号策略**:与 serializeResponseFormat 一致——若 out 非空(已有片段)则加前导逗号。
        // 这让两个片段函数调用顺序无关(gen_cfg 收集器不需关心谁先调)。
        if (effort) |e| if (geminiThinkingLevel(e)) |level| {
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

    const dialect = Dialect{
        .ctx = undefined,
        .serializeThinkingFn = serializeThinking,
        .serializeToolChoiceFn = serializeToolChoice,
        .serializeResponseFormatFn = serializeResponseFormat,
    };
};

pub fn geminiDialectFor(model: []const u8) Dialect {
    _ = model;
    return Gemini.dialect.withCtx(statelessCtx());
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

test "geminiDialectFor: effort=null 不发 thinking_level" {
    const d = geminiDialectFor("gemini-2.5-pro");
    const a = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try d.serializeThinking(.{}, null, &out, a);
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
