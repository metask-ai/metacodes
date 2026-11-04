//! # MiniMax 接入
//!
//! MiniMax M2.x / M3 / M3.1 系列在 OpenAI chat/completions wire 上的方言。
//!
//! ## 接入点
//!
//! - 还没有内置 Provider:经 `custom_providers` 或 OpenRouter 接入。官方端点:
//!   中国 `https://api.minimax.cn/v1`、全球 `https://api.minimax.io/v1`(OpenAI chat),
//!   Anthropic 兼容面在同一主机的 `/anthropic`。
//! - 型号:`MiniMax-M3.1-Flash`、`MiniMax-M3`、`MiniMax-M2.7`。
//!
//! ## 协议
//!
//! - `openai_chat` 上用本方言;`anthropic_messages` 上走 Claude 方言。
//! - 鉴权:`Authorization: Bearer <API_key>`。
//!
//! ## 思考与推理
//!
//! `thinking.type` 只认 `disabled` / `adaptive`(默认 adaptive);`reasoning_effort` 认
//! low / medium / high / xhigh / max,发 `none` 会 400,而且只有 M3.1 起真的调深度。
//!
//! | 型号 | 发送 |
//! |---|---|
//! | M3.1 及以后 | `thinking:{"type":"adaptive"}`(发 disabled 会 400);档位映射 none/minimal→low,其余原样;未指定不发(默认 max) |
//! | M3 | none/minimal → `disabled`,其余与未指定 → `adaptive`;不发 `reasoning_effort`(会被忽略) |
//! | M2.x | 不发 thinking(disabled 被接受但忽略,思考常开) |
//!
//! 所有型号都发 `reasoning_split:true`:思考进 `reasoning_content` 平级字段;为 false 时
//! 思考以 `<think>` 标签混在 `content` 里。M3.1-Flash 不接受 false。
//!
//! ## 回传与缓存
//!
//! - 文档只要求回传 tool_calls,未要求回传 `reasoning_content`;本方言不回传。
//! - 缓存:服务端隐式缓存。
//!
//! ## 已知差异
//!
//! - 输出上限字段是 `max_completion_tokens`(M3/M3.1 建议 131072,上限 524288);本仓库的
//!   OpenAI chat 序列化器不发,用服务端默认。
//! - 视觉:M3 起原生多模态(OpenAI image_url part);M2.x 纯文本。
//! - 2026-08 的旧实现给 M3 发 `thinking.type:"enabled"`;现行文档只列 disabled / adaptive,
//!   已改成 adaptive。
//!
//! ## 来源
//!
//! - https://platform.minimax.io/docs/api-reference/text-chat-openai(2026-11 核对:
//!   thinking.type、reasoning_effort、reasoning_split、输出上限、型号)
//! - https://platform.minimax.cn/docs/api-reference/text-chat-openai(2026-11 核对:
//!   中国区 `https://api.minimax.cn`)

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
const hasSubstr = model_adapter.hasSubstr;

pub const vendor: Vendor = .minimax;

pub fn claims(kind: ProviderKind, model: []const u8) bool {
    return kind == .openai and hasSubstr(model, "minimax");
}

pub fn dialect(kind: ProviderKind, model: []const u8) ?Dialect {
    if (kind != .openai) return null;
    return compat.ready(switch (generation(model)) {
        .m31 => M31.dialect,
        .m3 => M3.dialect,
        .m2 => M2.dialect,
    });
}

const Generation = enum { m2, m3, m31 };

fn generation(model: []const u8) Generation {
    const v = model_adapter.familyVersion(model, "minimax-m") orelse
        model_adapter.familyVersion(model, "minimax_m") orelse return .m2;
    if (v.major > 3 or (v.major == 3 and v.minor >= 1)) return .m31;
    if (v.major == 3) return .m3;
    return .m2;
}

pub fn openaiProfile(model: []const u8) ModelProfile {
    return switch (generation(model)) {
        .m31 => .{
            .thinking_mode = .minimax_m3_thinking,
            .effort_levels = .full,
            .returns_reasoning_content = true,
            .cannot_disable_thinking = true,
            .supports_image_input = true,
            .image_input_source = .model_family,
        },
        .m3 => .{
            .thinking_mode = .minimax_m3_thinking,
            .effort_levels = .minimax_3state,
            .returns_reasoning_content = true,
            .supports_image_input = true,
            .image_input_source = .model_family,
        },
        .m2 => .{
            .thinking_mode = .minimax_m2_split,
            .effort_levels = .none_,
            .returns_reasoning_content = true,
            .cannot_disable_thinking = true,
        },
    };
}

fn profile(ctx: *anyopaque, kind: ProviderKind, model: []const u8) ModelProfile {
    _ = ctx;
    return if (kind == .openai) openaiProfile(model) else model_adapter.profileFor(kind, model);
}

/// M3 的思考开关:none / minimal 关,其余(含未指定)adaptive。
pub fn m3ThinkingType(effort: ?ReasoningEffort) []const u8 {
    const e = effort orelse return "adaptive";
    return if (e.active()) "adaptive" else "disabled";
}

/// M3.1 的档位:none / minimal 不被接受,取最低的 low。
pub fn m31Effort(effort: ReasoningEffort) []const u8 {
    return switch (effort) {
        .none, .minimal => "low",
        else => effort.name(),
    };
}

const M31 = struct {
    fn serializeThinking(ctx: *anyopaque, p: ModelProfile, effort: ?ReasoningEffort, out: *std.ArrayList(u8), a: std.mem.Allocator) anyerror!void {
        _ = ctx;
        _ = p;
        try out.appendSlice(a, ",\"thinking\":{\"type\":\"adaptive\"}");
        if (effort) |e| try compat.appendStringField(out, a, "reasoning_effort", m31Effort(e));
        try out.appendSlice(a, ",\"reasoning_split\":true");
    }

    const dialect = blk: {
        var d = compat.base;
        d.serializeThinkingFn = serializeThinking;
        d.profileFn = profile;
        break :blk d;
    };
};

const M3 = struct {
    fn serializeThinking(ctx: *anyopaque, p: ModelProfile, effort: ?ReasoningEffort, out: *std.ArrayList(u8), a: std.mem.Allocator) anyerror!void {
        _ = ctx;
        _ = p;
        try out.appendSlice(a, ",\"thinking\":{\"type\":");
        try util_json.serializeString(m3ThinkingType(effort), out, a);
        try out.append(a, '}');
        try out.appendSlice(a, ",\"reasoning_split\":true");
    }

    const dialect = blk: {
        var d = compat.base;
        d.serializeThinkingFn = serializeThinking;
        d.profileFn = profile;
        break :blk d;
    };
};

const M2 = struct {
    fn serializeThinking(ctx: *anyopaque, p: ModelProfile, effort: ?ReasoningEffort, out: *std.ArrayList(u8), a: std.mem.Allocator) anyerror!void {
        _ = ctx;
        _ = p;
        _ = effort; // 常开不可关,也没有档位
        try out.appendSlice(a, ",\"reasoning_split\":true");
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

test "MiniMax M3.1: 恒 adaptive,档位原样(none→low),reasoning_split" {
    const a = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try bytes("MiniMax-M3.1-Flash", .xhigh, &out);
    try std.testing.expectEqualStrings(",\"thinking\":{\"type\":\"adaptive\"},\"reasoning_effort\":\"xhigh\",\"reasoning_split\":true", out.items);
    try bytes("MiniMax-M3.1-Flash", .none, &out);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"reasoning_effort\":\"low\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "disabled") == null);
    try bytes("MiniMax-M3.1-Flash", null, &out);
    try std.testing.expectEqualStrings(",\"thinking\":{\"type\":\"adaptive\"},\"reasoning_split\":true", out.items);
}

test "MiniMax M3: disabled / adaptive 两态,不发档位" {
    const a = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try bytes("minimax-m3", .xhigh, &out);
    try std.testing.expectEqualStrings(",\"thinking\":{\"type\":\"adaptive\"},\"reasoning_split\":true", out.items);
    try bytes("MiniMax-M3", .low, &out);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"type\":\"adaptive\"") != null);
    try bytes("MiniMax-M3", .none, &out);
    try std.testing.expectEqualStrings(",\"thinking\":{\"type\":\"disabled\"},\"reasoning_split\":true", out.items);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "reasoning_effort") == null);
}

test "MiniMax M2.x: 只发 reasoning_split(常开不可关)" {
    const a = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try bytes("minimax-m2.1", .xhigh, &out);
    try std.testing.expectEqualStrings(",\"reasoning_split\":true", out.items);
    try bytes("MiniMax-M2.7", .none, &out);
    try std.testing.expectEqualStrings(",\"reasoning_split\":true", out.items);
    try std.testing.expect(!openaiProfile("MiniMax-M2.7").supports_image_input);
    try std.testing.expect(openaiProfile("MiniMax-M3").supports_image_input);
}
