//! # OpenAI 接入
//!
//! OpenAI 自家模型(GPT、o 系列)的方言,同时是 OpenAI chat/completions wire 上
//! **所有认不出厂商的模型**的兜底方言(vLLM、自部署、未登记的兼容网关)。
//!
//! ## 接入点
//!
//! - Provider:`src/provider/profiles/openai.zig`,渠道 `default`,
//!   `https://api.openai.com/v1`。Codex OAuth 复用同一实现,是另一种凭证类型。
//! - 环境变量:`OPENAI_API_KEY`。
//!
//! ## 协议
//!
//! - `openai_chat`(`/chat/completions`)与 `openai_responses`(`/responses`)两条路由,
//!   由路由声明选择,绝不从 base URL 或模型名推断。
//! - 鉴权:`Authorization: Bearer <key>`。
//!
//! ## 思考与推理
//!
//! - 顶层 `reasoning_effort`,中立档位原样透传(none / minimal / low / medium / high /
//!   xhigh / max);`none`、未指定时不发,用服务端默认。
//! - Responses 路由的 `reasoning.effort` 由 `openai_client.zig` 的 Responses 序列化器发。
//! - chat/completions 不返回思考文本(只有 `reasoning_tokens` 计数),本方言不解析
//!   `reasoning_content`。
//!
//! ## 回传与缓存
//!
//! - Responses 路由:`reasoning` output item(含 `encrypted_content`)按模型门控原样回传
//!   (`types.ReasoningItemBlock`,issue #23)。chat/completions 无可回传的推理状态。
//! - 缓存:服务端自动前缀缓存。本方言不发 `prompt_cache_key`(profile 未声明支持)。
//!
//! ## 已知差异
//!
//! - 作为兜底方言时,对认不出的模型按 OpenAI 原生处理:发 `reasoning_effort`,图像输入
//!   保守视为不支持(来源 unknown),由目录或 Host 声明覆盖。
//! - 未知字段一律不发:兼容网关遇到不认识的字段可能 400。
//!
//! ## 来源
//!
//! - https://platform.openai.com/docs/api-reference/chat(2026-08 核对)
//! - https://platform.openai.com/docs/guides/reasoning(2026-08 核对)

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

pub const vendor: Vendor = .openai;

/// OpenAI 是 chat/completions wire 的兜底方言,不参与按名推断:认不出厂商的模型
/// 本来就落到这里。
pub fn claims(kind: ProviderKind, model: []const u8) bool {
    _ = kind;
    _ = model;
    return false;
}

pub fn dialect(kind: ProviderKind, model: []const u8) ?Dialect {
    _ = model;
    return switch (kind) {
        .openai => native(),
        else => null,
    };
}

/// OpenAI 原生方言值(也是 chat/completions wire 的兜底)。
pub fn native() Dialect {
    return compat.ready(Native.dialect);
}

/// `openai_client.zig` 的 Responses 序列化器与 chat 共用同一个 data URL 实现。
pub const writeImageDataUrl = compat.writeImageDataUrl;

const Native = struct {
    fn serializeThinking(ctx: *anyopaque, p: ModelProfile, effort: ?ReasoningEffort, out: *std.ArrayList(u8), a: std.mem.Allocator) anyerror!void {
        _ = ctx;
        _ = p;
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

    const dialect = blk: {
        var d = compat.base;
        d.serializeThinkingFn = serializeThinking;
        d.extractThinkingDeltaFn = extractThinkingDelta;
        break :blk d;
    };
};

// ── 测试 ─────────────────────────────────────────────────────────────────────

const capability_activation = @import("../capability_activation.zig");

test "OpenAI 原生: effort 原样透传,不发 thinking 对象" {
    const d = native();
    const a = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try d.serializeThinking(.{}, .high, &out, a);
    try std.testing.expectEqualStrings(",\"reasoning_effort\":\"high\"", out.items);
    out.clearRetainingCapacity();
    try d.serializeThinking(.{}, .none, &out, a);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
    out.clearRetainingCapacity();
    try d.serializeThinking(.{}, null, &out, a);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}

test "OpenAI 原生: 不注入 system,不解析 reasoning_content" {
    const d = native();
    const a = std.testing.allocator;
    var sys: std.ArrayList(u8) = .empty;
    defer sys.deinit(a);
    try sys.appendSlice(a, "base");
    try d.activateCapabilities(.{}, .{ .skill_tool = true }, &sys, a);
    try std.testing.expectEqualStrings("base", sys.items);
    try std.testing.expect(try d.extractThinkingDelta("{\"delta\":{\"reasoning_content\":\"x\"}}", a) == null);
    try std.testing.expect(std.mem.indexOf(u8, sys.items, capability_activation.STRICT_SKILL_SECTION_MARKER) == null);
}

test "OpenAI 原生: serializeImagePart 发 image_url data URL;异常 MIME 被转义" {
    const d = native();
    const a = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    const p = d.profileFor(.openai, "gpt-4o");
    try std.testing.expect(try d.serializeImagePart(p, .{ .media_type = "image/png", .data = "QUJD" }, &out, a));
    try std.testing.expectEqualStrings(
        "{\"type\":\"image_url\",\"image_url\":{\"url\":\"data:image/png;base64,QUJD\"}}",
        out.items,
    );
    out.clearRetainingCapacity();
    _ = try d.serializeImagePart(p, .{ .media_type = "image/\"x", .data = "QUJD" }, &out, a);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "image/\\\"x") != null);
}
