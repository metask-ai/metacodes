//! # DeepSeek 接入
//!
//! DeepSeek V4 系列的方言,覆盖 OpenAI chat/completions 与 Anthropic messages 两条 wire。
//!
//! ## 接入点
//!
//! - 还没有内置 Provider:经 `custom_providers` 或 OpenRouter 接入。官方端点:
//!   `https://api.deepseek.com`(OpenAI chat,`/chat/completions`)与
//!   `https://api.deepseek.com/anthropic`(Anthropic messages,`/v1/messages`)。
//! - 型号:`deepseek-v4-pro`、`deepseek-flash`(由 V4.1-Flash 提供;旧名 `deepseek-v4-flash`
//!   仍可用,按 Flash 计费)。上下文 1,048,576 token。
//!
//! ## 协议
//!
//! - 两条 wire 都有本方言:OpenAI chat 上按模型名也能认出 DeepSeek,Anthropic wire 上只在
//!   路由声明 `.deepseek` 时使用。鉴权:`Authorization: Bearer`。
//!
//! ## 思考与推理
//!
//! 思考默认开启,默认档位 high。中立档位映射(两条 wire 相同):
//!
//! | 中立 | 发送 |
//! |---|---|
//! | none / minimal | 关思考 |
//! | low | low |
//! | medium / high | high |
//! | xhigh / max | max |
//! | 未指定 | 不发档位,开思考,用服务端默认 |
//!
//! 服务端自己的映射把 `xhigh` 当 high;我们把中立的 xhigh 发成 max,因为中立档位里
//! xhigh 表示"比 high 更深"。
//!
//! - OpenAI chat wire:`thinking:{"type":"enabled"|"disabled"}` + 顶层 `reasoning_effort`。
//!   响应 `delta.reasoning_content`。
//! - Anthropic wire:`thinking:{"type":"enabled"|"disabled"}`(`adaptive` 也被当作 enabled,
//!   `budget_tokens` 被忽略)+ `output_config:{"effort":...}`。
//!
//! ## 回传与缓存
//!
//! - **请求带 tools 时,历史各轮的 `reasoning_content` 必须全部回传,否则 400**(即使那一轮
//!   没调工具)。本仓库目前不回传历史思考(`agent_loop.buildApiMessages` 不投影 thinking
//!   块):这是已知缺口,开启思考的多轮工具调用会被拒。
//! - Anthropic wire 上文档同样要求原样带回 thinking 块;服务端能从 tool-call id 恢复缺失的
//!   思考,但恢复失败也是 400。
//! - 缓存:服务端自动前缀缓存;Anthropic wire 上的 `cache_control` 被忽略。
//!
//! ## 已知差异
//!
//! - Anthropic wire 上 `tool_choice: any` 当作 auto;思考模式下 `tool_choice: tool` 返回 400。
//! - `deepseek-v4-pro` 不处理图像(替换成 `[Unsupported Image]`);`deepseek-flash` 收
//!   user 与 tool_result 里的图像,assistant 消息里的图像 400。
//! - 思考模式下 temperature 固定 1.0,`top_p` 在 v4-pro 上被忽略。
//!
//! ## 来源
//!
//! - https://api-docs.deepseek.com/(2026-11 核对:base URL、型号)
//! - https://api-docs.deepseek.com/guides/thinking_mode(2026-11 核对:档位、映射表、回传)
//! - https://api-docs.deepseek.com/guides/anthropic_api(2026-11 核对:Anthropic wire 字段)

const std = @import("std");
const types = @import("../../types.zig");
const util_json = @import("../../util/json.zig");
const model_adapter = @import("../model_adapter.zig");
const dialect_mod = @import("../dialect.zig");
const compat = @import("openai_compat.zig");
const claude = @import("claude.zig");
const Vendor = @import("../../provider/vendor.zig").Vendor;

const Dialect = dialect_mod.Dialect;
const ModelProfile = model_adapter.ModelProfile;
const ProviderKind = model_adapter.ProviderKind;
const ReasoningEffort = types.ReasoningEffort;
const hasSubstr = model_adapter.hasSubstr;

pub const vendor: Vendor = .deepseek;

/// 按名推断(只在 OpenAI wire 上,保持旧路由的行为)。
pub fn claims(kind: ProviderKind, model: []const u8) bool {
    return kind == .openai and hasSubstr(model, "deepseek");
}

pub fn dialect(kind: ProviderKind, model: []const u8) ?Dialect {
    _ = model;
    return switch (kind) {
        .openai => compat.ready(Chat.dialect),
        .anthropic => compat.ready(Messages.dialect),
        else => null,
    };
}

pub fn openaiProfile(model: []const u8) ModelProfile {
    _ = model;
    return .{
        .thinking_mode = .deepseek_top,
        .effort_levels = .deepseek_2,
        .returns_reasoning_content = true,
    };
}

fn profile(ctx: *anyopaque, kind: ProviderKind, model: []const u8) ModelProfile {
    _ = ctx;
    return if (kind == .openai) openaiProfile(model) else model_adapter.profileFor(kind, model);
}

/// 中立档位 → DeepSeek 的 low / high / max。null = 关思考(none / minimal,
/// 与 `ReasoningEffort.active` 一致)。
pub fn effortName(effort: ReasoningEffort) ?[]const u8 {
    return switch (effort) {
        .none, .minimal => null,
        .low => "low",
        .medium, .high => "high",
        .xhigh, .max => "max",
    };
}

const Chat = struct {
    fn serializeThinking(ctx: *anyopaque, p: ModelProfile, effort: ?ReasoningEffort, out: *std.ArrayList(u8), a: std.mem.Allocator) anyerror!void {
        _ = ctx;
        _ = p;
        const level: ?[]const u8 = if (effort) |e| effortName(e) else null;
        const enable = effort == null or level != null;
        try out.appendSlice(a, if (enable) ",\"thinking\":{\"type\":\"enabled\"}" else ",\"thinking\":{\"type\":\"disabled\"}");
        if (level) |name| try compat.appendStringField(out, a, "reasoning_effort", name);
    }

    const dialect = blk: {
        var d = compat.base;
        d.serializeThinkingFn = serializeThinking;
        d.profileFn = profile;
        break :blk d;
    };
};

const Messages = struct {
    fn serializeThinking(ctx: *anyopaque, p: ModelProfile, effort: ?ReasoningEffort, out: *std.ArrayList(u8), a: std.mem.Allocator) anyerror!void {
        _ = ctx;
        _ = p;
        const e = effort orelse return; // 未指定:服务端默认(开思考,high)
        const level = effortName(e) orelse {
            try out.appendSlice(a, ",\"thinking\":{\"type\":\"disabled\"}");
            return;
        };
        try out.appendSlice(a, ",\"output_config\":{\"effort\":");
        try util_json.serializeString(level, out, a);
        try out.appendSlice(a, "},\"thinking\":{\"type\":\"enabled\"}");
    }

    const dialect = blk: {
        var d = claude.wire;
        d.serializeThinkingFn = serializeThinking;
        break :blk d;
    };
};

// ── 测试 ─────────────────────────────────────────────────────────────────────

fn bytes(kind: ProviderKind, effort: ?ReasoningEffort, out: *std.ArrayList(u8)) !void {
    out.clearRetainingCapacity();
    try dialect(kind, "deepseek-v4-pro").?.serializeThinking(.{}, effort, out, std.testing.allocator);
}

test "DeepSeek chat: thinking + reasoning_effort(low/high/max),none 关思考,null 用默认" {
    const a = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    inline for (.{
        .{ ReasoningEffort.low, "low" },
        .{ ReasoningEffort.medium, "high" },
        .{ ReasoningEffort.high, "high" },
        .{ ReasoningEffort.xhigh, "max" },
        .{ ReasoningEffort.max, "max" },
    }) |case| {
        try bytes(.openai, case[0], &out);
        try std.testing.expectEqualStrings(",\"thinking\":{\"type\":\"enabled\"},\"reasoning_effort\":\"" ++ case[1] ++ "\"", out.items);
    }
    try bytes(.openai, null, &out);
    try std.testing.expectEqualStrings(",\"thinking\":{\"type\":\"enabled\"}", out.items);
    try bytes(.openai, .none, &out);
    try std.testing.expectEqualStrings(",\"thinking\":{\"type\":\"disabled\"}", out.items);
    try bytes(.openai, .minimal, &out);
    try std.testing.expectEqualStrings(",\"thinking\":{\"type\":\"disabled\"}", out.items);
}

test "DeepSeek Anthropic wire: output_config.effort 用 DeepSeek 词汇,不发 adaptive" {
    const a = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try bytes(.anthropic, .medium, &out);
    try std.testing.expectEqualStrings(",\"output_config\":{\"effort\":\"high\"},\"thinking\":{\"type\":\"enabled\"}", out.items);
    try bytes(.anthropic, .xhigh, &out);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"effort\":\"max\"") != null);
    try bytes(.anthropic, .none, &out);
    try std.testing.expectEqualStrings(",\"thinking\":{\"type\":\"disabled\"}", out.items);
    try bytes(.anthropic, null, &out);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}

test "DeepSeek: 声明的路由用 DeepSeek 家族 profile,解析 reasoning_content 增量" {
    const a = std.testing.allocator;
    const d = dialect(.openai, "deepseek-flash").?;
    try std.testing.expect(d.profileFor(.openai, "my-relay-name").returns_reasoning_content);
    const got = (try d.extractThinkingDelta("{\"delta\":{\"reasoning_content\":\"a\\nb\\t\\u4f60\"}}", a)).?;
    defer a.free(got);
    try std.testing.expectEqualStrings("a\nb\t你", got);
}

test "DeepSeek 按名推断只在 OpenAI wire 上" {
    try std.testing.expect(claims(.openai, "DeepSeek-V4-Pro"));
    try std.testing.expect(!claims(.anthropic, "deepseek-v4-pro"));
    try std.testing.expect(!claims(.openai, "gpt-5"));
}
