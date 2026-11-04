//! # Moonshot Kimi 接入
//!
//! Kimi K2.x / K3.x 系列的方言(OpenAI chat/completions wire)。
//!
//! ## 接入点
//!
//! - 还没有内置 Provider:经 `custom_providers` 或 OpenRouter 接入。官方端点:
//!   中国 `https://api.moonshot.cn/v1`、全球 `https://api.moonshot.ai/v1`(OpenAI chat),
//!   Anthropic 兼容面在同一主机的 `/anthropic`。
//! - Kimi Code 订阅(`https://api.kimi.com/coding/v1`)是另一种账号与配额。
//!
//! ## 协议
//!
//! - `openai_chat`(`/chat/completions`)声明本方言;`anthropic_messages` 路由走 Claude 方言。
//! - 鉴权:`Authorization: Bearer $MOONSHOT_API_KEY`。
//!
//! ## 思考与推理
//!
//! 按型号分三种,型号从模型名判断(路由已声明是 Kimi,不会和别家混):
//! - **K3 / K3.1**(`kimi-k3*`,以及 Kimi Code 的 `k3*`):思考恒开,不接受 K2 的
//!   `thinking` 对象;只发顶层 `reasoning_effort`,取值 low / high / max,默认 max。
//!   none/minimal 也发 max(关不掉,取默认),low→low,medium/high→high,xhigh/max→max。
//! - **K2.6 及更早**(名字含 `k2` 但不是 `k2.7`,或 `moonshot`):
//!   `thinking:{"type":"enabled"|"disabled","keep":"all"}`,none/minimal 关思考。
//!   `keep:"all"` 保留历史思考(服务端默认 null 会丢弃)。
//! - **K2.7-code 与其它 Kimi 名字**:`thinking.type` 只认 `enabled`(发 `disabled` 报错),
//!   恒发 `{"type":"enabled","keep":"all"}`。
//! - 响应:`delta.reasoning_content`,先于 `delta.content`。
//!
//! ## 回传与缓存
//!
//! - 文档要求带 tool_calls 的 assistant 消息**原样带回 `reasoning_content`**。本仓库目前
//!   不回传历史思考(`agent_loop.buildApiMessages` 不投影 thinking 块),见"已知差异"。
//! - `prompt_cache_key`:profile 声明支持(`supports_prompt_cache_key`),请求覆盖里有 key
//!   时才发;Kimi Code 订阅要求必发。
//!
//! ## 已知差异
//!
//! - 不回传 `reasoning_content`:多轮工具调用时服务端拿不到上一步的思考。
//! - 输出上限字段是 `max_completion_tokens`(`max_tokens` 已弃用);本仓库的 OpenAI
//!   chat 序列化器两者都不发,用服务端默认。
//! - 旧名推断里 `k2` 子串会认成 Kimi:那是没声明方言的路由的兼容行为,声明了方言的
//!   路由不受影响。
//!
//! ## 来源
//!
//! - https://platform.kimi.ai/docs/api/chat(2026-11 核对:base URL、型号、思考参数、
//!   reasoning_content 回传、prompt_cache_key、max_completion_tokens)
//! - https://platform.kimi.ai/docs/guide/kimi-k3-quickstart(2026-08 核对)

const std = @import("std");
const types = @import("../../types.zig");
const model_adapter = @import("../model_adapter.zig");
const model_name = @import("../model_name.zig");
const dialect_mod = @import("../dialect.zig");
const compat = @import("openai_compat.zig");
const Vendor = @import("../../provider/vendor.zig").Vendor;

const Dialect = dialect_mod.Dialect;
const ModelProfile = model_adapter.ModelProfile;
const ProviderKind = model_adapter.ProviderKind;
const ReasoningEffort = types.ReasoningEffort;
const hasSubstr = model_adapter.hasSubstr;

pub const vendor: Vendor = .kimi;

/// 按名推断(只在 OpenAI wire 上):`kimi` / `moonshot`,以及历史上的 `k2` 子串。
pub fn claims(kind: ProviderKind, model: []const u8) bool {
    if (kind != .openai) return false;
    return hasSubstr(model, "kimi") or hasSubstr(model, "k2") or hasSubstr(model, "moonshot");
}

pub fn dialect(kind: ProviderKind, model: []const u8) ?Dialect {
    if (kind != .openai) return null;
    return compat.ready(switch (generation(model)) {
        .k3 => K3.dialect,
        .k2_classic => K2.dialect,
        .k2_always_on => K27.dialect,
    });
}

const Generation = enum { k3, k2_classic, k2_always_on };

fn generation(model: []const u8) Generation {
    if (hasSubstr(model, "kimi-k3") or hasSubstr(model, "kimi_k3") or model_name.startsWithIgnoreCase(model, "k3")) return .k3;
    if (hasSubstr(model, "k2.7")) return .k2_always_on;
    if (hasSubstr(model, "k2") or hasSubstr(model, "moonshot")) return .k2_classic;
    return .k2_always_on;
}

pub fn openaiProfile(model: []const u8) ModelProfile {
    return switch (generation(model)) {
        .k3 => .{
            .thinking_mode = .kimi_k3_top_level,
            .effort_levels = .kimi_3,
            .supports_prompt_cache_key = true,
            .returns_reasoning_content = true,
            .cannot_disable_thinking = true,
        },
        .k2_classic => .{
            .thinking_mode = .kimi_extra_body,
            .effort_levels = .kimi_k2_3,
            .supports_prompt_cache_key = true,
            .returns_reasoning_content = true,
            .preserved_thinking_default = false, // keep="all"
        },
        .k2_always_on => .{
            .thinking_mode = .kimi_extra_body,
            .effort_levels = .none_,
            .supports_prompt_cache_key = true,
            .returns_reasoning_content = true,
            .preserved_thinking_default = false,
            .cannot_disable_thinking = true,
        },
    };
}

fn profile(ctx: *anyopaque, kind: ProviderKind, model: []const u8) ModelProfile {
    _ = ctx;
    return if (kind == .openai) openaiProfile(model) else model_adapter.profileFor(kind, model);
}

/// K3 的 effort 词汇:low / high / max,关不掉的档位取默认 max。
pub fn k3Effort(effort: ReasoningEffort) []const u8 {
    return switch (effort) {
        .none, .minimal => "max",
        .low => "low",
        .medium, .high => "high",
        .xhigh, .max => "max",
    };
}

const K3 = struct {
    fn serializeThinking(ctx: *anyopaque, p: ModelProfile, effort: ?ReasoningEffort, out: *std.ArrayList(u8), a: std.mem.Allocator) anyerror!void {
        _ = ctx;
        _ = p;
        try compat.appendStringField(out, a, "reasoning_effort", k3Effort(effort orelse .max));
    }

    const dialect = blk: {
        var d = compat.base;
        d.serializeThinkingFn = serializeThinking;
        d.profileFn = profile;
        break :blk d;
    };
};

const K2 = struct {
    fn serializeThinking(ctx: *anyopaque, p: ModelProfile, effort: ?ReasoningEffort, out: *std.ArrayList(u8), a: std.mem.Allocator) anyerror!void {
        _ = ctx;
        _ = p;
        const enable = if (effort) |e| e.active() else true;
        try out.appendSlice(a, if (enable)
            ",\"thinking\":{\"type\":\"enabled\",\"keep\":\"all\"}"
        else
            ",\"thinking\":{\"type\":\"disabled\"}");
    }

    const dialect = blk: {
        var d = compat.base;
        d.serializeThinkingFn = serializeThinking;
        d.profileFn = profile;
        break :blk d;
    };
};

const K27 = struct {
    fn serializeThinking(ctx: *anyopaque, p: ModelProfile, effort: ?ReasoningEffort, out: *std.ArrayList(u8), a: std.mem.Allocator) anyerror!void {
        _ = ctx;
        _ = p;
        _ = effort; // 关不掉,也没有档位
        try out.appendSlice(a, ",\"thinking\":{\"type\":\"enabled\",\"keep\":\"all\"}");
    }

    const dialect = blk: {
        var d = compat.base;
        d.serializeThinkingFn = serializeThinking;
        d.profileFn = profile;
        break :blk d;
    };
};

// ── 测试 ─────────────────────────────────────────────────────────────────────

fn bytes(model: []const u8, effort: ?ReasoningEffort, out: *std.ArrayList(u8)) !void {
    out.clearRetainingCapacity();
    try dialect(.openai, model).?.serializeThinking(.{}, effort, out, std.testing.allocator);
}

test "Kimi K3/K3.1: 只发顶层 reasoning_effort(low/high/max,默认 max)" {
    const a = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    for ([_][]const u8{ "kimi-k3", "kimi-k3.1-pro", "k3.1-pro-highspeed", "K3-256k" }) |model| {
        try bytes(model, .high, &out);
        try std.testing.expectEqualStrings(",\"reasoning_effort\":\"high\"", out.items);
        try bytes(model, null, &out);
        try std.testing.expectEqualStrings(",\"reasoning_effort\":\"max\"", out.items);
        try bytes(model, .none, &out);
        try std.testing.expectEqualStrings(",\"reasoning_effort\":\"max\"", out.items);
        try bytes(model, .low, &out);
        try std.testing.expectEqualStrings(",\"reasoning_effort\":\"low\"", out.items);
    }
}

test "Kimi K2.6: thinking enabled+keep all,none 关思考,不发 effort" {
    const a = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try bytes("kimi-k2.6", .high, &out);
    try std.testing.expectEqualStrings(",\"thinking\":{\"type\":\"enabled\",\"keep\":\"all\"}", out.items);
    try bytes("kimi-k2", null, &out);
    try std.testing.expectEqualStrings(",\"thinking\":{\"type\":\"enabled\",\"keep\":\"all\"}", out.items);
    try bytes("kimi-k2.6", .none, &out);
    try std.testing.expectEqualStrings(",\"thinking\":{\"type\":\"disabled\"}", out.items);
}

test "Kimi K2.7-code: 思考关不掉,永不发 disabled" {
    const a = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    for ([_][]const u8{ "kimi-k2.7-code", "kimi-k2.7-code-highspeed", "kimi-for-coding" }) |model| {
        try bytes(model, .none, &out);
        try std.testing.expectEqualStrings(",\"thinking\":{\"type\":\"enabled\",\"keep\":\"all\"}", out.items);
        try std.testing.expect(openaiProfile(model).cannot_disable_thinking);
    }
}

test "Kimi: reasoning_content 解析(含结尾转义反斜杠),prompt_cache_key 随 profile 发出" {
    const a = std.testing.allocator;
    const d = dialect(.openai, "kimi-k3").?;
    const got = (try d.extractThinkingDelta("{\"delta\":{\"reasoning_content\":\"frag\\\\\"}}", a)).?;
    defer a.free(got);
    try std.testing.expectEqualStrings("frag\\", got);

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try std.testing.expect(try d.serializePromptCacheKey(d.profileFor(.openai, "kimi-k3"), "sess-1", &out, a));
    try std.testing.expectEqualStrings(",\"prompt_cache_key\":\"sess-1\"", out.items);
}

test "Kimi 按名推断只在 OpenAI wire 上" {
    try std.testing.expect(claims(.openai, "moonshot-v1-8k"));
    try std.testing.expect(claims(.openai, "Kimi-K3"));
    try std.testing.expect(!claims(.anthropic, "kimi-k3"));
    try std.testing.expect(dialect(.anthropic, "kimi-k3") == null);
}
