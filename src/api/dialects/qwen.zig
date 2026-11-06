//! # 阿里 Qwen(百炼 / Model Studio / DashScope)接入
//!
//! Qwen3 系列(qwen3.5 / 3.6 / 3.7 / 3.8、qwen-plus、qwen-flash)在 OpenAI 兼容模式下的方言。
//!
//! ## 接入点
//!
//! - 还没有内置 Provider:经 `custom_providers` 或 OpenRouter 接入。官方端点:
//!   北京 `https://dashscope.aliyuncs.com/compatible-mode/v1`、
//!   新加坡 `https://dashscope-intl.aliyuncs.com/compatible-mode/v1`,Anthropic 兼容面在
//!   同一主机的 `/apps/anthropic`;另有工作空间专属端点
//!   `https://{WorkspaceId}.cn-beijing.maas.aliyuncs.com/compatible-mode/v1` 等。
//! - 各地域的 key 互不通用。
//!
//! ## 协议
//!
//! - `openai_chat` 上用本方言;`anthropic_messages` 上走 Claude 方言。
//! - 鉴权:Bearer。
//!
//! ## 思考与推理
//!
//! - 顶层 `enable_thinking`(非 OpenAI 标准字段,原始 HTTP 放在请求体顶层)。
//!   none / minimal → `false`,其余档位与未指定 → `true`。
//! - Qwen 没有档位词汇,只有开关和 `thinking_budget`(token 上限);本方言不发
//!   `thinking_budget`。
//! - 3.5 及以后的混合模型默认开思考;qwen-plus / qwen-flash 默认不开——本方言在未指定
//!   档位时一律发 `true`,让行为不依赖型号默认值。
//! - 只思考型号(如 qwen3.7-max-preview)忽略这个开关。
//! - 响应:`delta.reasoning_content`。
//!
//! ## 回传与缓存
//!
//! - 是否读历史 `reasoning_content` 由 `preserve_thinking` 控制,不是必需;本方言不回传。
//! - 缓存:服务端隐式缓存;显式缓存走 Anthropic 风格的 cache_control,本方言不用。
//!
//! ## 已知差异
//!
//! - 按名推断只认 `qwen3` / `qwen-3`:qwen-plus / qwen-flash 会被当成 OpenAI 原生
//!   (发 `reasoning_effort`),与拆分前相同。
//! - 部分开源型号(qwen3.5-122b-a10b 等)只接受流式请求;本仓库总是流式。
//! - 视觉:名字含 `vl` 的是视觉变体;qwen3.8 系列原生多模态,但名字看不出来,由目录声明。
//!
//! ## 来源
//!
//! - https://www.alibabacloud.com/help/en/model-studio/deep-thinking(2026-11 核对:
//!   enable_thinking、thinking_budget、各型号默认、reasoning_content、地域端点)

const std = @import("std");
const types = @import("../../types.zig");
const model_adapter = @import("../model_adapter.zig");
const dialect_mod = @import("../dialect.zig");
const compat = @import("openai_compat.zig");
const Vendor = @import("../../provider/vendor.zig").Vendor;

const Dialect = dialect_mod.Dialect;
const ModelProfile = model_adapter.ModelProfile;
const ProviderKind = model_adapter.ProviderKind;
const ReasoningEffort = types.ReasoningEffort;
const hasSubstr = model_adapter.hasSubstr;

pub const vendor: Vendor = .qwen;

pub fn claims(kind: ProviderKind, model: []const u8) bool {
    return kind == .openai and (hasSubstr(model, "qwen3") or hasSubstr(model, "qwen-3"));
}

pub fn dialect(kind: ProviderKind, model: []const u8) ?Dialect {
    _ = model;
    return if (kind == .openai) compat.ready(Chat.dialect) else null;
}

pub fn openaiProfile(model: []const u8) ModelProfile {
    const vl = hasSubstr(model, "vl");
    return .{
        .thinking_mode = .qwen_template,
        .effort_levels = .none_, // 只有开关
        .returns_reasoning_content = true,
        .supports_image_input = vl,
        .image_input_source = if (vl) .model_family else .unknown,
    };
}

fn profile(ctx: *anyopaque, kind: ProviderKind, model: []const u8) ModelProfile {
    _ = ctx;
    return if (kind == .openai) openaiProfile(model) else model_adapter.profileFor(kind, model);
}

const Chat = struct {
    fn serializeThinking(ctx: *anyopaque, p: ModelProfile, effort: ?ReasoningEffort, out: *std.ArrayList(u8), a: std.mem.Allocator) anyerror!void {
        _ = ctx;
        _ = p;
        const enable = if (effort) |e| e.active() else true;
        try out.appendSlice(a, if (enable) ",\"enable_thinking\":true" else ",\"enable_thinking\":false");
    }

    const dialect = blk: {
        var d = compat.base;
        d.serializeThinkingFn = serializeThinking;
        d.profileFn = profile;
        break :blk d;
    };
};

test "Qwen: enable_thinking 开关,none/minimal 关" {
    const a = std.testing.allocator;
    const d = dialect(.openai, "qwen3.8-max").?;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try d.serializeThinking(.{}, .high, &out, a);
    try std.testing.expectEqualStrings(",\"enable_thinking\":true", out.items);
    out.clearRetainingCapacity();
    try d.serializeThinking(.{}, null, &out, a);
    try std.testing.expectEqualStrings(",\"enable_thinking\":true", out.items);
    out.clearRetainingCapacity();
    try d.serializeThinking(.{}, .minimal, &out, a);
    try std.testing.expectEqualStrings(",\"enable_thinking\":false", out.items);
}

test "Qwen: 本方言下 qwen-plus 也用开关,不发 reasoning_effort" {
    const a = std.testing.allocator;
    const d = dialect(.openai, "qwen-plus").?;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try d.serializeThinking(d.profileFor(.openai, "qwen-plus"), .high, &out, a);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "reasoning_effort") == null);
    try std.testing.expect(!claims(.openai, "qwen-plus"));
    try std.testing.expect(claims(.openai, "qwen3-235b"));
}

test "Qwen: vl 变体收图,其余来源 unknown" {
    try std.testing.expect(openaiProfile("qwen3-vl-plus").supports_image_input);
    const p = openaiProfile("qwen3.8-max");
    try std.testing.expect(!p.supports_image_input);
    try std.testing.expectEqual(@import("../image_capability.zig").Source.unknown, p.image_input_source);
}
