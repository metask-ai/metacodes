//! # Anthropic Claude 接入
//!
//! Anthropic messages wire 上 Claude 的方言,也是这条 wire 的兜底方言:没声明方言、
//! 名字又认不出厂商的 Anthropic 兼容路由都用它。别家的 Anthropic 方言(GLM、DeepSeek)
//! 以 `wire` 为基础只改不同的方法。
//!
//! ## 接入点
//!
//! - Provider:`src/provider/profiles/metask.zig`(默认路径,`https://napi.metask-ai.com`,
//!   Anthropic messages)。环境变量 `METASK_API_KEY`。
//! - 其它厂商的 Anthropic 兼容渠道(DeepSeek、Kimi、Qwen、MiniMax、Z.AI)在各自 profile 里,
//!   路由声明各自的方言,这几家在 Anthropic wire 上都有专属方言;没声明方言、名字也认不出
//!   厂商的 Anthropic 路由用本方言。
//!
//! ## 协议
//!
//! - `anthropic_messages`(`/v1/messages`)。鉴权按 profile 声明(Metask 是 Bearer)。
//!
//! ## 思考与推理
//!
//! - 选了档位才发:`output_config:{"effort":...}` + `thinking:{"type":"adaptive"}`;
//!   none / minimal / 未指定都不发,用服务端默认。
//! - 词汇 low / medium / high / max:中立的 `xhigh` 发成 `max`(Anthropic 没有 xhigh);
//!   GLM-5.3+ 在这条 wire 上换成 low / high / max(`glm53_effort_vocabulary`)。
//! - 响应:SSE 的 `thinking_delta` 事件由 `client.zig` 的事件解析直接处理,不经本方言。
//!
//! ## 回传与缓存
//!
//! - thinking 块不回传:签名(`signature_delta`)没有保存,发回无签名的 thinking 块会被拒。
//! - 缓存:`cache_control` 断点由 `request.zig` 放置,不经方言。
//!
//! ## 已知差异
//!
//! - `tool_choice` 已经是 Anthropic 语义,由 `request.zig` 原样序列化;本方言不接管。
//! - `response_format` 不发(用 system prompt 指示 JSON)。
//! - Anthropic 文档要求带工具的思考回合回传最后一条 assistant 的 thinking 块(含签名);
//!   本仓库不保存签名,这是现有行为,本方言没有处理。
//!
//! ## 来源
//!
//! - https://docs.anthropic.com/en/api/messages(2026-08 核对)
//! - https://docs.anthropic.com/en/docs/build-with-claude/adaptive-thinking(2026-08 核对)

const std = @import("std");
const types = @import("../../types.zig");
const util_json = @import("../../util/json.zig");
const model_adapter = @import("../model_adapter.zig");
const dialect_mod = @import("../dialect.zig");
const compat = @import("openai_compat.zig");
const Vendor = @import("../../provider/vendor.zig").Vendor;

const Dialect = dialect_mod.Dialect;
const ModelProfile = model_adapter.ModelProfile;
const ProviderKind = model_adapter.ProviderKind;
const ReasoningEffort = types.ReasoningEffort;
const ToolChoice = dialect_mod.ToolChoice;

pub const vendor: Vendor = .claude;

/// Claude 是 Anthropic wire 的兜底方言,不参与按名推断。
pub fn claims(kind: ProviderKind, model: []const u8) bool {
    _ = kind;
    _ = model;
    return false;
}

pub fn dialect(kind: ProviderKind, model: []const u8) ?Dialect {
    _ = model;
    return if (kind == .anthropic) compat.ready(wire) else null;
}

/// Anthropic messages wire 的基础方言值(ctx 未填)。别家的 Anthropic 方言拷贝它再覆盖。
pub const wire = Dialect{
    .ctx = undefined,
    .serializeThinkingFn = serializeThinking,
    .extractThinkingDeltaFn = extractThinkingDelta,
    .serializeToolChoiceFn = serializeToolChoice,
    .serializeImagePartFn = serializeImagePart,
};

fn serializeThinking(ctx: *anyopaque, p: ModelProfile, effort: ?ReasoningEffort, out: *std.ArrayList(u8), a: std.mem.Allocator) anyerror!void {
    _ = ctx;
    if (effort) |e| if (e.active()) {
        try out.appendSlice(a, ",\"output_config\":{\"effort\":");
        const name = if (p.glm53_effort_vocabulary) model_adapter.glm53EffortName(e) else effortName(e);
        try util_json.serializeString(name, out, a);
        try out.append(a, '}');
        try out.appendSlice(a, ",\"thinking\":{\"type\":\"adaptive\"}");
    };
}

/// Anthropic `output_config.effort` 的词汇是 low / medium / high / max。中立的 `xhigh`
/// 是 OpenAI 的叫法,发成 `max`;其余原样。
pub fn effortName(e: ReasoningEffort) []const u8 {
    return switch (e) {
        .xhigh => "max",
        else => e.name(),
    };
}

fn extractThinkingDelta(ctx: *anyopaque, raw: []const u8, a: std.mem.Allocator) anyerror!?[]u8 {
    _ = ctx;
    _ = raw;
    _ = a;
    // thinking_delta 由 client.zig 的 SSE 事件解析直接处理。
    return null;
}

/// tool_choice 已是 Anthropic 语义,由 request.zig 原样序列化;返回 false 表示方言不接管。
fn serializeToolChoice(ctx: *anyopaque, p: ModelProfile, tc: ?ToolChoice, out: *std.ArrayList(u8), a: std.mem.Allocator) anyerror!bool {
    _ = ctx;
    _ = p;
    _ = tc;
    _ = out;
    _ = a;
    return false;
}

/// {"type":"image","source":{"type":"base64","media_type":<mime>,"data":<b64>}}。
/// 能力守门在 Dialect.serializeImagePart wrapper;本实现只管 wire 形态。
fn serializeImagePart(ctx: *anyopaque, p: ModelProfile, image: types.ImageBlock, out: *std.ArrayList(u8), a: std.mem.Allocator) anyerror!bool {
    _ = ctx;
    _ = p;
    try out.appendSlice(a, "{\"type\":\"image\",\"source\":{\"type\":\"base64\",\"media_type\":");
    try util_json.serializeString(image.media_type, out, a);
    try out.appendSlice(a, ",\"data\":");
    try util_json.serializeString(image.data, out, a);
    try out.appendSlice(a, "}}");
    return true;
}

// ── 测试 ─────────────────────────────────────────────────────────────────────

const capability_activation = @import("../capability_activation.zig");

fn claude() Dialect {
    return dialect(.anthropic, "claude-sonnet-4").?;
}

test "Claude: 选了档位才发 adaptive + output_config;xhigh→max,其余原样" {
    const allocator = std.testing.allocator;
    const d = claude();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try d.serializeThinking(.{}, .high, &out, allocator);
    try std.testing.expectEqualStrings(",\"output_config\":{\"effort\":\"high\"},\"thinking\":{\"type\":\"adaptive\"}", out.items);
    out.clearRetainingCapacity();
    try d.serializeThinking(.{}, .xhigh, &out, allocator);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"effort\":\"max\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "xhigh") == null);
    out.clearRetainingCapacity();
    try d.serializeThinking(.{}, .medium, &out, allocator);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"effort\":\"medium\"") != null);
    out.clearRetainingCapacity();
    try d.serializeThinking(.{}, null, &out, allocator);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}

test "Claude wire: GLM 5.3+ 的 effort 用 low/high/max" {
    const a = std.testing.allocator;
    const d = claude();
    const p = model_adapter.profileFor(.anthropic, "glm-5.3-flash");
    try std.testing.expect(p.glm53_effort_vocabulary);
    inline for (.{ .{ ReasoningEffort.low, "low" }, .{ ReasoningEffort.medium, "high" }, .{ ReasoningEffort.xhigh, "max" } }) |case| {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(a);
        try d.serializeThinking(p, case[0], &out, a);
        try std.testing.expect(std.mem.indexOf(u8, out.items, "\"effort\":\"" ++ case[1] ++ "\"") != null);
    }
}

test "Claude: 不注入 Skill 能力契约" {
    const allocator = std.testing.allocator;
    var ordinary: std.ArrayList(u8) = .empty;
    defer ordinary.deinit(allocator);
    try ordinary.appendSlice(allocator, "base\n\n# Available skills\n- verify");
    try claude().activateCapabilities(.{}, .{ .skill_tool = true }, &ordinary, allocator);
    try std.testing.expect(std.mem.indexOf(u8, ordinary.items, capability_activation.STRICT_SKILL_SECTION_MARKER) == null);
}

test "Claude: serializeImagePart 发 base64 source block" {
    const d = claude();
    const a = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    const p = d.profileFor(.anthropic, "claude-sonnet-4");
    try std.testing.expect(try d.serializeImagePart(p, .{ .media_type = "image/png", .data = "QUJD" }, &out, a));
    try std.testing.expectEqualStrings(
        "{\"type\":\"image\",\"source\":{\"type\":\"base64\",\"media_type\":\"image/png\",\"data\":\"QUJD\"}}",
        out.items,
    );
}
