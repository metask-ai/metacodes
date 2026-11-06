//! # Mistral 接入
//!
//! Mistral(含已废弃的 Magistral)在 OpenAI chat/completions wire 上的方言。
//!
//! ## 接入点
//!
//! - 没有内置 Provider。经 `custom_providers` 声明 `"dialect": "mistral"` 接入(官方端点
//!   `https://api.mistral.ai/v1`);没声明方言的路由按模型名推断(名字含 `mistral` /
//!   `magistral`)。OpenRouter 路由走 OpenRouter 方言,不经本文件。
//!
//! ## 协议
//!
//! - `openai_chat`。鉴权:Bearer。
//!
//! ## 思考与推理
//!
//! 顶层 `reasoning_effort`。schema 的枚举是 OpenAI 的 7 档,但每个型号只收其中几档,
//! 文档原话是枚举里有的值不代表每个型号都收。本方言只发文档写明的档位:
//!
//! | 型号(API 名,大小写不敏感,忽略 `vendor/` 前缀) | 词汇 | 中立 → 发送 |
//! |---|---|---|
//! | `mistral-small-2603`、`mistral-small-latest` | none / high | none、minimal → none;其余 → high |
//! | `mistral-medium-3-5`、`mistral-medium-3`、`mistral-medium-latest` | none / high | 同上 |
//! | `mistral-large-4-0`、`mistral-large-4` | low / medium / high | none、minimal、low → low;medium → medium;high、xhigh、max → high |
//! | `magistral-*` | 无开关,推理常开 | 不发 |
//! | 其余(含 `mistral-large-latest` = Large 3) | 文档没写推理 | 不发 |
//!
//! - 未指定档位时不发,用服务端默认:API 文档没写各型号的默认档位。
//! - Large 4 不收 `none` / `minimal` / `xhigh` / `max`;文档给的迁移说明是把预览版的
//!   `none` 换成 `low`,所以中立的 none / minimal 发 `low`(`cannot_disable_thinking`)。
//! - Small 与 Medium 只写了 `none` 和 `high`,会不会拒 `low` / `medium` 没写,所以只发这两档。
//! - 不发 `prompt_mode`:它只在 Magistral 的页面上有解释,新型号上的作用没写。
//!
//! 响应:开推理时 `content` 是 chunk 列表——`{"type":"thinking","thinking":[{"type":"text",
//! "text":...}]}` 在前,`{"type":"text","text":...}` 在后;`none` 时是普通字符串。流式时
//! `delta.content` 在思考阶段是装 ThinkChunk 的列表,过渡时是一个同时装收尾 ThinkChunk 与
//! 第一个 TextChunk 的列表,之后变回字符串。`content_chunks` 让共用的 chat 流解析器按序把
//! thinking chunk 的 text 部分记成思考、text chunk 记成正文(`openai_client.zig`
//! `queueContentChunks`)。Mistral 不返回 `reasoning_content`;本方言仍按它解析,给声明了
//! 本方言、以 `reasoning_content` 返回推理的自部署端点用。
//!
//! ## 回传与缓存
//!
//! - 文档要求多轮时原样回放整条 assistant 消息(含 ThinkChunk),去掉它"明显降低输出
//!   质量";没说缺了会被拒。有推理的型号(上表前三行与 Magistral)声明
//!   `content_chunks = .read_and_echo`:带非空思考的 assistant 历史消息以 chunk 列表发回,
//!   thinking chunk 与 text chunk 保持原顺序,`tool_calls` 照常跟在后面;没有思考的消息仍是
//!   字符串,字节与之前相同。其余型号 `.read`:只读不回传。
//! - `content_chunks` 是 Mistral API 的 wire 行为,不是模型的:只放在本方言的 `profileFn`
//!   里,不进按名推断的家族 profile(`openaiProfile`)。声明了别的方言(如 `openai`)、
//!   恰好挂着 Mistral 型号名的路由,解析与请求字节都不变。
//! - 不回传 `signature`:IR 不存它,文档也没说 Mistral 型号会不会发、要不要。
//! - 缓存:服务端隐式缓存。回传的思考按 prompt token 计费(文档示例的 token 算术)。
//!
//! ## 已知差异
//!
//! - 唯一支持显式 `parallel_tool_calls` 的方言(profile `supports_parallel_tool_calls`),
//!   请求覆盖里设置了才发。
//! - 流式 JSON 没有官方原文样例:文档只用文字描述 `delta.content` 的三段形态,上面的
//!   chunk 形状来自 openapi schema(`DeltaMessage.content` 可为 string / null / ContentChunk[])。
//!   ThinkChunk 还有 `signature` 与 `closed`(只用于 prefix)两个字段,解析时忽略。
//! - "思考 + `tool_calls`"同在一条 assistant 消息里回传:schema 允许,文档没有样例。
//! - `usage` 里没有推理 token 计数。
//! - Mistral 端点上的 `zai-glm-5-3` / `zai-glm-5-3-flash` 收 low / high / max,content 总是
//!   chunk 列表;本方言没为它们映射档位(按名推断时它们归 GLM 方言)。
//!
//! ## 来源
//!
//! 页面都没有标更新日期;以下均于 2026-11-06 读取。
//! - https://docs.mistral.ai/studio/conversations/reasoning(`reasoning_effort` 与各型号词汇、
//!   响应与流式形态、多轮回放)
//! - https://docs.mistral.ai/api/endpoint/chat 与其 schema https://docs.mistral.ai/openapi.yaml
//!   (`reasoning_effort` 枚举、`ThinkChunk` / `TextChunk` / `DeltaMessage` / `AssistantMessage`、
//!   `UsageInfo`、`prompt_mode`)
//! - https://docs.mistral.ai/resources/deprecated/native-reasoning(Magistral 已废弃、推理
//!   常开、assistant 回放的 JSON 样例)
//! - https://docs.mistral.ai/models/mistral-small-4-0-26-03、`mistral-medium-3-5-26-04`、
//!   `mistral-large-4-0`、`mistral-large-3-25-12`(API 名与 `-latest` 别名)
//! - https://docs.mistral.ai/api/#tag/chat(parallel_tool_calls,2025-08 调研)

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

pub const vendor: Vendor = .mistral;

pub fn claims(kind: ProviderKind, model: []const u8) bool {
    return kind == .openai and (hasSubstr(model, "mistral") or hasSubstr(model, "magistral"));
}

pub fn dialect(kind: ProviderKind, model: []const u8) ?Dialect {
    _ = model;
    return if (kind == .openai) compat.ready(Chat.dialect) else null;
}

/// 型号在推理上的分类。只认文档写明了推理行为的 API 名。
const Family = enum {
    /// `reasoning_effort` 收 none / high。
    none_high,
    /// `reasoning_effort` 收 low / medium / high(Large 4)。
    low_medium_high,
    /// Magistral:推理常开,没有开关。
    magistral,
    /// 文档没写推理的型号。
    other,
};

const NONE_HIGH_IDS = [_][]const u8{
    "mistral-small-2603",    "mistral-small-latest",
    "mistral-medium-3-5",    "mistral-medium-3",
    "mistral-medium-latest",
};
const LOW_MEDIUM_HIGH_IDS = [_][]const u8{ "mistral-large-4-0", "mistral-large-4" };

fn familyOf(model: []const u8) Family {
    // `mistralai/mistral-small-2603` 这类网关名:只看最后一段。
    const id = if (std.mem.lastIndexOfScalar(u8, model, '/')) |slash| model[slash + 1 ..] else model;
    for (NONE_HIGH_IDS) |known| if (model_name.eqlIgnoreCase(id, known)) return .none_high;
    for (LOW_MEDIUM_HIGH_IDS) |known| if (model_name.eqlIgnoreCase(id, known)) return .low_medium_high;
    if (hasSubstr(model, "magistral")) return .magistral;
    return .other;
}

pub fn openaiProfile(model: []const u8) ModelProfile {
    const family = familyOf(model);
    return .{
        .thinking_mode = switch (family) {
            .none_high, .low_medium_high => .mistral_effort,
            .magistral, .other => .none,
        },
        .effort_levels = switch (family) {
            .none_high => .mistral_none_high,
            .low_medium_high => .mistral_low_medium_high,
            .magistral, .other => .none_,
        },
        .cannot_disable_thinking = family == .low_medium_high or family == .magistral,
        .supports_parallel_tool_calls = true,
        .returns_reasoning_content = true,
    };
}

/// 本方言的 profile:家族 profile 加上 Mistral API 的 chunk 形态 `content`。
fn profile(ctx: *anyopaque, kind: ProviderKind, model: []const u8) ModelProfile {
    _ = ctx;
    if (kind != .openai) return model_adapter.profileFor(kind, model);
    var p = openaiProfile(model);
    p.content_chunks = switch (familyOf(model)) {
        .none_high, .low_medium_high, .magistral => .read_and_echo,
        .other => .read,
    };
    return p;
}

/// 中立档位 → 该型号词汇里的 `reasoning_effort`;null = 不发。
pub fn effortName(levels: model_adapter.EffortLevels, effort: ReasoningEffort) ?[]const u8 {
    return switch (levels) {
        .mistral_none_high => switch (effort) {
            .none, .minimal => "none",
            .low, .medium, .high, .xhigh, .max => "high",
        },
        .mistral_low_medium_high => switch (effort) {
            .none, .minimal, .low => "low",
            .medium => "medium",
            .high, .xhigh, .max => "high",
        },
        else => null,
    };
}

const Chat = struct {
    fn serializeThinking(ctx: *anyopaque, p: ModelProfile, effort: ?ReasoningEffort, out: *std.ArrayList(u8), a: std.mem.Allocator) anyerror!void {
        _ = ctx;
        const e = effort orelse return; // 未指定:服务端默认
        const level = effortName(p.effort_levels, e) orelse return;
        try compat.appendStringField(out, a, "reasoning_effort", level);
    }

    const dialect = blk: {
        var d = compat.base;
        d.serializeThinkingFn = serializeThinking;
        d.profileFn = profile;
        break :blk d;
    };
};

// ── 测试 ─────────────────────────────────────────────────────────────────────

fn thinkingBytes(model: []const u8, effort: ?ReasoningEffort, out: *std.ArrayList(u8)) !void {
    out.clearRetainingCapacity();
    const d = dialect(.openai, model).?;
    try d.serializeThinking(d.profileFor(.openai, model), effort, out, std.testing.allocator);
}

test "Mistral Small 2603 / Medium 3.5: reasoning_effort 只发 none / high,未指定不发" {
    const a = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    inline for (.{ "mistral-small-2603", "mistral-small-latest", "Mistral-Medium-3-5", "mistral-medium-3", "mistral-medium-latest", "mistralai/mistral-small-2603" }) |model| {
        inline for (.{
            .{ ReasoningEffort.none, "none" },
            .{ ReasoningEffort.minimal, "none" },
            .{ ReasoningEffort.low, "high" },
            .{ ReasoningEffort.medium, "high" },
            .{ ReasoningEffort.high, "high" },
            .{ ReasoningEffort.xhigh, "high" },
            .{ ReasoningEffort.max, "high" },
        }) |case| {
            try thinkingBytes(model, case[0], &out);
            try std.testing.expectEqualStrings(",\"reasoning_effort\":\"" ++ case[1] ++ "\"", out.items);
        }
        try thinkingBytes(model, null, &out);
        try std.testing.expectEqual(@as(usize, 0), out.items.len);
    }
}

test "Mistral Large 4: reasoning_effort 只发 low / medium / high,none 发 low" {
    const a = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    inline for (.{ "mistral-large-4-0", "mistral-large-4", "MISTRAL-LARGE-4-0" }) |model| {
        inline for (.{
            .{ ReasoningEffort.none, "low" },
            .{ ReasoningEffort.minimal, "low" },
            .{ ReasoningEffort.low, "low" },
            .{ ReasoningEffort.medium, "medium" },
            .{ ReasoningEffort.high, "high" },
            .{ ReasoningEffort.xhigh, "high" },
            .{ ReasoningEffort.max, "high" },
        }) |case| {
            try thinkingBytes(model, case[0], &out);
            try std.testing.expectEqualStrings(",\"reasoning_effort\":\"" ++ case[1] ++ "\"", out.items);
        }
        try thinkingBytes(model, null, &out);
        try std.testing.expectEqual(@as(usize, 0), out.items.len);
    }
}

test "Mistral: Magistral、Large 3 与其余型号不发思考字段" {
    const a = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    inline for (.{ "magistral-medium-2509", "magistral-small-latest", "mistral-large-latest", "mistral-large-2512", "mistral-large", "mistral-medium-2508", "mistral-small-2506", "mistral-large-4-0-preview", "my-mistral-deploy" }) |model| {
        inline for (.{ null, ReasoningEffort.none, ReasoningEffort.low, ReasoningEffort.high, ReasoningEffort.max }) |effort| {
            try thinkingBytes(model, effort, &out);
            try std.testing.expectEqual(@as(usize, 0), out.items.len);
        }
    }
}

test "Mistral: 有推理的型号回传 thinking chunk,其余只读 list 型 content" {
    inline for (.{ "mistral-small-2603", "mistral-medium-3-5", "mistral-large-4-0", "magistral-medium-2509" }) |model| {
        const p = dialect(.openai, model).?.profileFor(.openai, model);
        try std.testing.expectEqual(model_adapter.ContentChunks.read_and_echo, p.content_chunks);
        try std.testing.expect(!p.echoes_reasoning_content);
    }
    inline for (.{ "mistral-large-latest", "mistral-large", "codestral-latest" }) |model| {
        const p = dialect(.openai, model).?.profileFor(.openai, model);
        try std.testing.expectEqual(model_adapter.ContentChunks.read, p.content_chunks);
    }
    // 声明了本方言、名字认不出的自部署路由:只读,不回传,不发档位。
    const p = dialect(.openai, "house-deployment").?.profileFor(.openai, "house-deployment");
    try std.testing.expectEqual(model_adapter.ContentChunks.read, p.content_chunks);
    try std.testing.expectEqual(model_adapter.EffortLevels.none_, p.effort_levels);
    // chunk 形态只属于本方言:按名推断的家族 profile、以及声明了别的方言的路由都没有。
    try std.testing.expectEqual(model_adapter.ContentChunks.none, model_adapter.profileFor(.openai, "mistral-small-2603").content_chunks);
    inline for (.{ Vendor.openai, Vendor.claude, Vendor.gemini, Vendor.openrouter }) |declared| {
        const other = dialect_mod.dialectForVendor(.openai, declared, "mistral-small-2603");
        try std.testing.expectEqual(model_adapter.ContentChunks.none, other.profileFor(.openai, "mistral-small-2603").content_chunks);
    }
}

test "Mistral: parallel_tool_calls 显式开关" {
    const a = std.testing.allocator;
    const d = dialect(.openai, "mistral-large").?;
    const p = d.profileFor(.openai, "mistral-large");
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try std.testing.expect(try d.serializeParallelToolCalls(p, false, &out, a));
    try std.testing.expectEqualStrings(",\"parallel_tool_calls\":false", out.items);
}
