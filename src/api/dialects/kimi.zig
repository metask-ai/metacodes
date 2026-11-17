//! # Moonshot Kimi 接入
//!
//! Kimi K2.x / K3.x 系列在 OpenAI chat/completions wire 上的方言,以及 K3 在 Anthropic
//! messages wire 上的方言。Moonshot 开放平台与 Kimi Code 订阅两个 provider 共用本文件。
//!
//! ## 接入点
//!
//! - 开放平台 Provider:`src/provider/profiles/kimi.zig`。渠道:
//!   `cn-openai`(默认)`https://api.moonshot.cn/v1`、`global-openai` `https://api.moonshot.ai/v1`、
//!   `cn-anthropic` `https://api.moonshot.cn/anthropic`、`global-anthropic` `https://api.moonshot.ai/anthropic`。
//!   环境变量只认 `MOONSHOT_API_KEY`。
//! - Kimi Code 订阅 Provider:`src/provider/profiles/kimi_code.zig`,另一种账号与配额(Kimi Code
//!   控制台的 key,与开放平台的 key、Base URL 互不通用)。渠道:`cn-responses`(默认)、`cn-chat`
//!   `https://api.kimi.com/coding/v1`,`global-responses`、`global-chat` `https://api.kimi.ai/coding/v1`。
//!   环境变量:`KIMI_CODE_API_KEY`(规范名)、`KIMI_API_KEY`(Kimi 自己的 Codex、Hermes 指南
//!   给订阅 key 用的名字,所以归订阅,不归开放平台)。
//!
//! ## 协议
//!
//! - `openai_chat`(`/chat/completions`)与 `anthropic_messages`(`/anthropic/v1/messages`)
//!   的路由都声明本方言(`.kimi`);Anthropic 面只服务 K3 系列(kimi-k3、kimi-k3.1-pro、
//!   kimi-k3.1-pro-highspeed),profile 只在 OpenAI 渠道上提供 K2.7-code。
//! - Kimi Code 的 `openai_responses`(`/responses`)与 `openai_chat` 路由同样声明本方言。
//!   Responses wire 走 OpenAI 的通用序列化:深度是 `reasoning:{effort}`,活跃档位按名字发,
//!   服务端把 medium 当 high、xhigh 当 max;本方言的 thinking 序列化不参与。
//! - Kimi Code 的 Anthropic 兼容面(`https://api.kimi.com/coding/`)没有接:文档没说 Messages
//!   请求怎样开思考,而本方言在 Anthropic wire 上不发 `thinking` 对象,在那里可能被当成关思考。
//! - 鉴权:`Authorization: Bearer <key>`(开放平台 `$MOONSHOT_API_KEY`,Kimi Code 是控制台的 key)。
//!
//! ## 思考与推理
//!
//! 按型号分四种,型号从模型名判断(路由已声明是 Kimi,不会和别家混):
//! - **K3 / K3.1**(开放平台的 `kimi-k3*`):思考恒开,不接受 K2 的
//!   `thinking` 对象;只发顶层 `reasoning_effort`,取值 low / high / max,默认 max。
//!   none/minimal 也发 max(关不掉,取默认),low→low,medium/high→high,xhigh/max→max。
//! - **Kimi Code 的 `k3*`(k3.1-pro、k3.1-pro-highspeed、k3、k3-256k)与 `kimi-for-coding`
//!   (2026-11 指向 K2.8 Preview)**:同样只发顶层 `reasoning_effort`(low / high / max,映射
//!   同上),但未指定时不发,用服务端默认:K3.1 Pro 与 K3 为 high,K2.8 Preview 为 max。
//!   none/minimal 也不发:K3.1 Pro 关思考报 400,其余型号关思考会改由 K2.8 Preview 无思考版回答。
//! - **K2.6 及更早**(名字含 `k2` 但不是 `k2.7`,或 `moonshot`):
//!   `thinking:{"type":"enabled"|"disabled","keep":"all"}`,none/minimal 关思考。
//!   `keep:"all"` 保留历史思考(服务端默认 null 会丢弃)。
//! - **K2.7-code 与其它 Kimi 名字**(含 Kimi Code 的 `kimi-for-coding-highspeed`,即 K2.7 Code
//!   Highspeed,思考恒开、没有档位):`thinking.type` 只认 `enabled`(发 `disabled` 报错),
//!   恒发 `{"type":"enabled","keep":"all"}`。
//! - 响应:`delta.reasoning_content`,先于 `delta.content`。
//! - **Anthropic wire**:没有 `thinking` 请求参数(思考恒开);深度只有
//!   `output_config.effort`,取值 low / high / max(没有 medium),默认 max。映射同 K3:
//!   未指定不发,其余经 `k3Effort`。
//! - 采样参数:K3 的 `temperature=1.0`、`top_p=0.95` 等固定,文档要求省略;K2.7-code 发别的
//!   值会报错。这两代(连同 Kimi Code 的同代型号)的 profile 声明 `fixed_sampling`,OpenAI chat
//!   序列化器不发调用方的 `temperature` / `top_p` 覆盖。
//!
//! ## 回传与缓存
//!
//! - 文档要求带 tool_calls 的 assistant 消息**原样带回 `reasoning_content`**。本方言声明
//!   `echoes_reasoning_content`,序列化器把 assistant 历史的 thinking 块作为
//!   `reasoning_content` 发回(三代都发;K2.6 在 `keep` 为 null 时服务端忽略它)。Kimi Code
//!   在思考开着时缺这个字段直接 400(`thinking is enabled but reasoning_content is missing`)。
//! - Kimi Code 的 Responses wire:reasoning item 由 OpenAI 通用序列化逐字节回传。
//! - `prompt_cache_key`:profile 声明支持(`supports_prompt_cache_key`),请求覆盖里有 key
//!   时才发;Kimi Code 订阅要求必发。
//! - Anthropic wire 要求把响应里的 thinking 块(含 `signature`)原样带回;中立 IR 不保存
//!   签名,本方言不回传 thinking 块(与 Claude 方言相同)。
//!
//! ## 已知差异
//!
//! - 回传的是会话里存的思考文本,换过模型的会话里也包括别的模型的思考。
//! - 输出上限字段是 `max_completion_tokens`(`max_tokens` 已弃用);本仓库的 OpenAI
//!   chat 序列化器两者都不发,用服务端默认。
//! - 旧名推断里 `k2` 子串会认成 Kimi:那是没声明方言的路由的兼容行为,声明了方言的
//!   路由不受影响。Kimi Code 的 `k3*` 名字不参与推断(不含 `kimi`),只经声明了方言的路由。
//! - Kimi Code 的 `prompt_cache_key` 本仓库不自动生成,配置了才发。
//! - Kimi Code 的 Responses wire 上思考不显示:OpenAI 通用解析只回传 reasoning item,
//!   要看思考流用 chat 渠道(`reasoning_content`)。Responses 序列化也不看 `fixed_sampling`,
//!   调用方设了 `temperature` / `top_p` 会照发。
//! - Kimi Code 的 1M 窗口随套餐:K3.1 Pro 与 K3 在 Plus / Moderato 上是 262,144,
//!   profile 按所有套餐都有的窗口声明。
//!
//! ## 来源
//!
//! - https://platform.kimi.ai/docs/api/chat(2026-11 核对:base URL、型号、思考参数、
//!   reasoning_content 回传、prompt_cache_key、max_completion_tokens)
//! - https://platform.kimi.ai/docs/guide/kimi-k3-quickstart(2026-11 核对:固定采样参数、
//!   `max_completion_tokens` 默认 131072)
//! - https://platform.kimi.ai/docs/api/messages.md(2026-11 核对:Anthropic 面的型号、
//!   `output_config.effort` 取值、thinking 块回传)
//! - https://platform.kimi.ai/docs/guide/kimi-k2-7-code-quickstart(2026-11 核对:固定采样
//!   参数,其它值报错;262,144 上下文见 pricing 页)
//! - https://www.kimi.com/code/docs/en/kimi-code/models.html(2026-11 核对:Kimi Code 的六个
//!   型号 ID、上下文窗口、`reasoning_effort` 档位与默认值、Base URL、effort 映射与关思考的路由)
//! - https://www.kimi.com/code/docs/en/third-party-tools/codex.html(2026-11 核对:原生支持
//!   Responses API、`KIMI_API_KEY`、按套餐的上下文窗口)
//! - https://www.kimi.com/code/docs/en/kimi-code/error-reference.html(2026-11 核对:
//!   `reasoning_content` 回传要求、K3.1 Pro 关思考 400、各状态码的含义)

const std = @import("std");
const types = @import("../../types.zig");
const model_adapter = @import("../model_adapter.zig");
const model_name = @import("../model_name.zig");
const util_json = @import("../../util/json.zig");
const claude = @import("claude.zig");
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
    return switch (kind) {
        .openai => compat.ready(switch (generation(model)) {
            .k3 => K3.dialect,
            .code_effort => CodeEffort.dialect,
            .k2_classic => K2.dialect,
            .k2_always_on => K27.dialect,
        }),
        .anthropic => compat.ready(Messages.dialect),
        else => null,
    };
}

const Generation = enum { k3, code_effort, k2_classic, k2_always_on };

fn generation(model: []const u8) Generation {
    // Kimi Code 订阅的型号 ID:k3.1-pro、k3.1-pro-highspeed、k3、k3-256k,以及指向
    // K2.8 Preview 的 kimi-for-coding。kimi-for-coding-highspeed(K2.7 Code)不在其中。
    if (model_name.startsWithIgnoreCase(model, "k3") or model_name.eqlIgnoreCase(model, "kimi-for-coding")) return .code_effort;
    if (hasSubstr(model, "kimi-k3") or hasSubstr(model, "kimi_k3")) return .k3;
    if (hasSubstr(model, "k2.7")) return .k2_always_on;
    if (hasSubstr(model, "k2") or hasSubstr(model, "moonshot")) return .k2_classic;
    return .k2_always_on;
}

pub fn openaiProfile(model: []const u8) ModelProfile {
    return switch (generation(model)) {
        // 参数与开放平台的 K3 相同,只是未指定的档位交给服务端默认(见 CodeEffort)。
        .k3, .code_effort => .{
            .thinking_mode = .kimi_k3_top_level,
            .effort_levels = .kimi_3,
            .supports_prompt_cache_key = true,
            .returns_reasoning_content = true,
            .echoes_reasoning_content = true,
            .cannot_disable_thinking = true,
            .fixed_sampling = true,
        },
        .k2_classic => .{
            .thinking_mode = .kimi_extra_body,
            .effort_levels = .kimi_k2_3,
            .supports_prompt_cache_key = true,
            .returns_reasoning_content = true,
            .echoes_reasoning_content = true,
            .preserved_thinking_default = false, // keep="all"
        },
        .k2_always_on => .{
            .thinking_mode = .kimi_extra_body,
            .effort_levels = .none_,
            .supports_prompt_cache_key = true,
            .returns_reasoning_content = true,
            .echoes_reasoning_content = true,
            .preserved_thinking_default = false,
            .cannot_disable_thinking = true,
            .fixed_sampling = true,
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

/// Kimi Code 的 reasoning_effort 型号(K3.1 Pro、K3、K2.8 Preview):顶层 `reasoning_effort`,
/// 词汇同 K3;未指定和 none/minimal 都不发,由服务端取默认(K3.1 Pro 与 K3 为 high,
/// K2.8 Preview 为 max)。关思考在这里不是"省",而是 400(K3.1 Pro)或换成另一个型号。
const CodeEffort = struct {
    fn serializeThinking(ctx: *anyopaque, p: ModelProfile, effort: ?ReasoningEffort, out: *std.ArrayList(u8), a: std.mem.Allocator) anyerror!void {
        _ = ctx;
        _ = p;
        const e = effort orelse return;
        if (!e.active()) return;
        try compat.appendStringField(out, a, "reasoning_effort", k3Effort(e));
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

/// Anthropic messages wire(K3):没有 thinking 对象,只发 `output_config.effort`。
const Messages = struct {
    fn serializeThinking(ctx: *anyopaque, p: ModelProfile, effort: ?ReasoningEffort, out: *std.ArrayList(u8), a: std.mem.Allocator) anyerror!void {
        _ = ctx;
        _ = p;
        const e = effort orelse return; // 未指定:服务端默认 max
        try out.appendSlice(a, ",\"output_config\":{\"effort\":");
        try util_json.serializeString(k3Effort(e), out, a);
        try out.append(a, '}');
    }

    const dialect = blk: {
        var d = claude.wire;
        d.serializeThinkingFn = serializeThinking;
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
    for ([_][]const u8{ "kimi-k3", "kimi-k3.1-pro", "kimi-k3.1-pro-highspeed", "Kimi-K3" }) |model| {
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
    // kimi-for-coding-highspeed 是 Kimi Code 的 K2.7 Code Highspeed:思考恒开、没有档位。
    for ([_][]const u8{ "kimi-k2.7-code", "kimi-k2.7-code-highspeed", "kimi-for-coding-highspeed" }) |model| {
        try bytes(model, .none, &out);
        try std.testing.expectEqualStrings(",\"thinking\":{\"type\":\"enabled\",\"keep\":\"all\"}", out.items);
        try bytes(model, .max, &out);
        try std.testing.expectEqualStrings(",\"thinking\":{\"type\":\"enabled\",\"keep\":\"all\"}", out.items);
        try std.testing.expect(openaiProfile(model).cannot_disable_thinking);
    }
}

test "Kimi Code 的 k3* 与 kimi-for-coding:顶层 reasoning_effort,未指定不发(服务端默认)" {
    const a = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    for ([_][]const u8{ "k3.1-pro", "k3.1-pro-highspeed", "k3", "k3-256k", "K3-256k", "kimi-for-coding" }) |model| {
        // 未指定:服务端默认(K3.1 Pro / K3 为 high,K2.8 Preview 为 max),不替用户选 max。
        try bytes(model, null, &out);
        try std.testing.expectEqualStrings("", out.items);
        // none/minimal 也不发:K3.1 Pro 关思考报 400,其余会换成 K2.8 Preview 无思考版。
        try bytes(model, .none, &out);
        try std.testing.expectEqualStrings("", out.items);
        try bytes(model, .minimal, &out);
        try std.testing.expectEqualStrings("", out.items);
        inline for (.{
            .{ ReasoningEffort.low, "low" },
            .{ ReasoningEffort.medium, "high" },
            .{ ReasoningEffort.high, "high" },
            .{ ReasoningEffort.xhigh, "max" },
            .{ ReasoningEffort.max, "max" },
        }) |case| {
            try bytes(model, case[0], &out);
            try std.testing.expectEqualStrings(",\"reasoning_effort\":\"" ++ case[1] ++ "\"", out.items);
        }
        const p = openaiProfile(model);
        try std.testing.expect(p.echoes_reasoning_content);
        try std.testing.expect(p.fixed_sampling);
        try std.testing.expect(p.supports_prompt_cache_key);
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

test "Kimi: 三代都回传 reasoning_content" {
    for ([_][]const u8{ "kimi-k3", "kimi-k2.6", "kimi-k2.7-code", "k3.1-pro", "kimi-for-coding", "kimi-for-coding-highspeed" }) |model| {
        try std.testing.expect(openaiProfile(model).echoes_reasoning_content);
    }
}

test "Kimi 按名推断只在 OpenAI wire 上;Anthropic wire 的方言只给声明了 Kimi 的路由" {
    try std.testing.expect(claims(.openai, "moonshot-v1-8k"));
    try std.testing.expect(claims(.openai, "Kimi-K3"));
    try std.testing.expect(!claims(.anthropic, "kimi-k3"));
    try std.testing.expect(dialect(.anthropic, "kimi-k3") != null);
}

test "Kimi Anthropic wire: 只发 output_config.effort(low/high/max),不发 thinking 对象" {
    const a = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    const d = dialect(.anthropic, "kimi-k3.1-pro").?;
    inline for (.{
        .{ ReasoningEffort.low, ",\"output_config\":{\"effort\":\"low\"}" },
        .{ ReasoningEffort.medium, ",\"output_config\":{\"effort\":\"high\"}" },
        .{ ReasoningEffort.xhigh, ",\"output_config\":{\"effort\":\"max\"}" },
        .{ ReasoningEffort.none, ",\"output_config\":{\"effort\":\"max\"}" },
    }) |case| {
        out.clearRetainingCapacity();
        try d.serializeThinking(.{}, case[0], &out, a);
        try std.testing.expectEqualStrings(case[1], out.items);
    }
    out.clearRetainingCapacity();
    try d.serializeThinking(.{}, null, &out, a);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
    // 不回传无签名的 thinking 块。
    try std.testing.expect(!d.profileFor(.anthropic, "kimi-k3").echoes_reasoning_content);
}

test "Kimi: K3 与 K2.7 固定采样参数,K2.6 不固定" {
    try std.testing.expect(openaiProfile("kimi-k3").fixed_sampling);
    try std.testing.expect(openaiProfile("kimi-k2.7-code").fixed_sampling);
    try std.testing.expect(!openaiProfile("kimi-k2.6").fixed_sampling);
}
