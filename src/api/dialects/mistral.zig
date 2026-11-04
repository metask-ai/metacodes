//! # Mistral 接入
//!
//! Mistral / Magistral 在 OpenAI chat/completions wire 上的方言。
//!
//! ## 接入点
//!
//! - 没有内置 Provider。经 OpenRouter 目录、或 `custom_providers` 声明
//!   `"dialect": "mistral"` 接入(官方端点 `https://api.mistral.ai/v1`)。
//!
//! ## 协议
//!
//! - `openai_chat`。鉴权:Bearer。
//!
//! ## 思考与推理
//!
//! - 不发任何思考控制字段:Magistral 的推理是模型自带的,本方言没有可映射的档位开关。
//! - 响应里的思考按平级 `reasoning_content` 解析。
//!
//! ## 回传与缓存
//!
//! - 不回传思考。缓存:服务端隐式缓存。
//!
//! ## 已知差异
//!
//! - 唯一支持显式 `parallel_tool_calls` 的方言(profile `supports_parallel_tool_calls`),
//!   请求覆盖里设置了才发。
//! - Magistral 原生把思考放在 content 数组的 thinking chunk 里;经兼容端点时以
//!   `reasoning_content` 返回。本方言只解析后者,原生端点的 chunk 形态未接。
//!
//! ## 来源
//!
//! - https://docs.mistral.ai/capabilities/reasoning(2025-08 调研,见 model_adapter 头注释)
//! - https://docs.mistral.ai/api/#tag/chat(parallel_tool_calls,2025-08 调研)

const std = @import("std");
const model_adapter = @import("../model_adapter.zig");
const dialect_mod = @import("../dialect.zig");
const compat = @import("openai_compat.zig");
const Vendor = @import("../../provider/vendor.zig").Vendor;

const Dialect = dialect_mod.Dialect;
const ModelProfile = model_adapter.ModelProfile;
const ProviderKind = model_adapter.ProviderKind;
const hasSubstr = model_adapter.hasSubstr;

pub const vendor: Vendor = .mistral;

pub fn claims(kind: ProviderKind, model: []const u8) bool {
    return kind == .openai and (hasSubstr(model, "mistral") or hasSubstr(model, "magistral"));
}

pub fn dialect(kind: ProviderKind, model: []const u8) ?Dialect {
    _ = model;
    return if (kind == .openai) compat.ready(Chat.dialect) else null;
}

pub fn openaiProfile(model: []const u8) ModelProfile {
    _ = model;
    return .{
        .thinking_mode = .none,
        .effort_levels = .full,
        .supports_parallel_tool_calls = true,
        .returns_reasoning_content = true,
    };
}

fn profile(ctx: *anyopaque, kind: ProviderKind, model: []const u8) ModelProfile {
    _ = ctx;
    return if (kind == .openai) openaiProfile(model) else model_adapter.profileFor(kind, model);
}

const Chat = struct {
    const dialect = blk: {
        var d = compat.base;
        d.profileFn = profile;
        break :blk d;
    };
};

test "Mistral: 不发思考字段,parallel_tool_calls 显式开关" {
    const a = std.testing.allocator;
    const d = dialect(.openai, "mistral-large").?;
    const p = d.profileFor(.openai, "mistral-large");
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try d.serializeThinking(p, .high, &out, a);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
    try std.testing.expect(try d.serializeParallelToolCalls(p, false, &out, a));
    try std.testing.expectEqualStrings(",\"parallel_tool_calls\":false", out.items);
}
