//! # 智谱 GLM(Z.AI)接入
//!
//! GLM-4.x / GLM-5.x 系列的方言,覆盖 OpenAI chat/completions 与 Anthropic messages
//! 两条 wire。
//!
//! ## 接入点
//!
//! - Provider:`src/provider/profiles/zai_coding_plan.zig`(GLM Coding Plan)。四个渠道:
//!   `cn-anthropic`(默认)`https://open.bigmodel.cn/api/anthropic`、
//!   `cn-openai` `https://open.bigmodel.cn/api/coding/paas/v4`、
//!   `global-anthropic` `https://api.z.ai/api/anthropic`、
//!   `global-openai` `https://api.z.ai/api/coding/paas/v4`。
//!   通用 API(`/api/paas/v4`)被 profile 的端点策略禁止,Coding Plan 的 key 不能落到那里。
//! - Metask 网关也在 Anthropic wire 上提供 GLM 模型(`src/provider/profiles/metask.zig`)。
//! - 环境变量:`ZAI_API_KEY`(规范名)、`GLM_API_KEY`、`Z_AI_API_KEY`。
//!
//! ## 协议
//!
//! - `openai_chat` 与 `anthropic_messages` 两条 wire 上都按模型名认出 GLM。
//! - 鉴权:Bearer。
//!
//! ## 思考与推理
//!
//! OpenAI chat wire:
//! - GLM-5.2 及更早:`thinking:{"type":"enabled"|"disabled"}`;开启时再发
//!   `clear_thinking:false` 与顶层 `reasoning_effort`(中立档位原样发,服务端自己映射
//!   low/medium→high、xhigh→max)。未指定档位时开启思考、不发 `reasoning_effort`。
//! - GLM-5.3 及以后:思考不能关(发 `disabled` 会被拒),`thinking.type` 恒为 `enabled`;
//!   `reasoning_effort` 只认 low / high / max(none/minimal/low→low,medium/high→high,
//!   xhigh/max→max)。
//! - 响应:`delta.reasoning_content`。
//!
//! Anthropic messages wire:沿用 Claude 方言的 `thinking:{type:adaptive}` +
//! `output_config.effort`;GLM-5.3+ 的 effort 词汇换成 low / high / max
//! (`ModelProfile.glm53_effort_vocabulary`)。
//!
//! 两条 wire 上都追加 Skill 工具优先的能力提示(`capability_activation`),只在本轮请求
//! 真的暴露了 Skill 工具时注入;Anthropic wire 上还会在 required-first 路由未满足时
//! 发 `tool_choice` 指定该工具。
//!
//! ## 回传与缓存
//!
//! - `clear_thinking:false` 声明保留思考(preserved thinking)。本仓库目前不把历史
//!   `reasoning_content` 回传给 GLM(`agent_loop.buildApiMessages` 不投影 thinking
//!   块),GLM 的真实端到端(2026-07-15 swarm e2e)在不回传时工作正常。
//! - 缓存:服务端隐式缓存;不发 `prompt_cache_key`(未确认支持)。
//!
//! ## 已知差异
//!
//! - `tool_choice` 只认 `auto`(profile `tool_choice_support = .auto_only`):
//!   required / 指定函数降级成 `auto`。
//! - `response_format` 只认 `json_object`:`json_schema` 降级成 `json_object`。
//! - 视觉:版本段以 `v` 结尾的是视觉变体(glm-4v、glm-4.5v);glm-5.3-flash 这类新名字
//!   看不出来,由目录声明。
//! - 原生端点的 XML 工具格式与 `defer_loading` 不用:走兼容端点的 JSON function 调用。
//!
//! ## 来源
//!
//! - https://docs.z.ai/guides/capabilities/thinking(2026-08 核对)
//! - https://docs.z.ai/guides/llm/glm-5.3(2026-10 核对)
//! - https://docs.bigmodel.cn/cn/coding-plan/overview(2026-08 核对)

const std = @import("std");
const types = @import("../../types.zig");
const util_json = @import("../../util/json.zig");
const model_adapter = @import("../model_adapter.zig");
const dialect_mod = @import("../dialect.zig");
const capability_activation = @import("../capability_activation.zig");
const compat = @import("openai_compat.zig");
const claude = @import("claude.zig");
const Vendor = @import("../../provider/vendor.zig").Vendor;

const Dialect = dialect_mod.Dialect;
const ModelProfile = model_adapter.ModelProfile;
const ProviderKind = model_adapter.ProviderKind;
const ReasoningEffort = types.ReasoningEffort;
const ToolChoice = dialect_mod.ToolChoice;
const hasSubstr = model_adapter.hasSubstr;

pub const vendor: Vendor = .glm;

/// 按名推断:GLM-4.x / GLM-5.x 的名字;OpenAI wire 上 GLM-5.3 之后的代号也算。
pub fn claims(kind: ProviderKind, model: []const u8) bool {
    const named = hasSubstr(model, "glm-5") or hasSubstr(model, "glm4") or hasSubstr(model, "glm-4");
    return switch (kind) {
        .openai => named or model_adapter.glmAlwaysThinks(model),
        .anthropic => named,
        else => false,
    };
}

pub fn dialect(kind: ProviderKind, model: []const u8) ?Dialect {
    return switch (kind) {
        .openai => compat.ready(if (model_adapter.glmAlwaysThinks(model)) Glm53.dialect else Glm.dialect),
        .anthropic => compat.ready(GlmAnthropic.dialect),
        else => null,
    };
}

/// GLM 在 OpenAI chat wire 上的能力 profile。
pub fn openaiProfile(model: []const u8) ModelProfile {
    return .{
        .thinking_mode = .glm_prompt_tag,
        .effort_levels = .glm_7to2,
        .response_format_support = .json_object_only,
        .tool_choice_support = .auto_only,
        .returns_reasoning_content = true,
        // coding-plan 端点默认保留 thinking;标准 API 端点默认清除。harness 从模型名
        // 区分不了端点,保守取 false(保留)——coding agent 场景更常见。
        .preserved_thinking_default = false,
        // 视觉变体是"版本段以 v 收尾"的名字(glm-4v / glm-4.5v)。
        .supports_image_input = model_adapter.glmVisionVariant(model),
        .image_input_source = .model_family,
    };
}

fn profile(ctx: *anyopaque, kind: ProviderKind, model: []const u8) ModelProfile {
    _ = ctx;
    return if (kind == .openai) openaiProfile(model) else model_adapter.profileFor(kind, model);
}

fn activateCapabilities(ctx: *anyopaque, p: ModelProfile, capabilities: dialect_mod.VisibleCapabilities, system: *std.ArrayList(u8), allocator: std.mem.Allocator) anyerror!void {
    _ = ctx;
    _ = p;
    try capability_activation.injectStrictSkillToolFirst(
        system,
        capabilities.skill_tool,
        capabilities.requiredSkillInvocation(),
        allocator,
    );
}

/// GLM-5.2 及更早。
const Glm = struct {
    fn serializeThinking(ctx: *anyopaque, p: ModelProfile, effort: ?ReasoningEffort, out: *std.ArrayList(u8), a: std.mem.Allocator) anyerror!void {
        _ = ctx;
        _ = p;
        const enable = if (effort) |e| e.active() else true;
        try out.appendSlice(a, ",\"thinking\":{\"type\":");
        try util_json.serializeString(if (enable) "enabled" else "disabled", out, a);
        try out.append(a, '}');
        if (enable) {
            try out.appendSlice(a, ",\"clear_thinking\":false");
            if (effort) |e| try compat.appendStringField(out, a, "reasoning_effort", e.name());
        }
    }

    const dialect = blk: {
        var d = compat.base;
        d.serializeThinkingFn = serializeThinking;
        d.activateCapabilitiesFn = activateCapabilities;
        d.profileFn = profile;
        break :blk d;
    };
};

/// GLM-5.3 及以后:思考不能关。
const Glm53 = struct {
    fn serializeThinking(ctx: *anyopaque, p: ModelProfile, effort: ?ReasoningEffort, out: *std.ArrayList(u8), a: std.mem.Allocator) anyerror!void {
        _ = ctx;
        _ = p;
        try out.appendSlice(a, ",\"thinking\":{\"type\":\"enabled\"},\"clear_thinking\":false");
        if (effort) |e| try compat.appendStringField(out, a, "reasoning_effort", model_adapter.glm53EffortName(e));
    }

    const dialect = blk: {
        var d = compat.base;
        d.serializeThinkingFn = serializeThinking;
        d.activateCapabilitiesFn = activateCapabilities;
        d.profileFn = profile;
        break :blk d;
    };
};

/// Anthropic messages wire 上的 GLM:Claude 方言 + Skill 优先的能力契约。只是呈现层投影,
/// 从不自动授权 Skill。
const GlmAnthropic = struct {
    fn routeToolChoice(ctx: *anyopaque, p: ModelProfile, capabilities: dialect_mod.VisibleCapabilities, already_invoked: bool, requested: ?ToolChoice) ?ToolChoice {
        _ = ctx;
        _ = p;
        return dialect_mod.routeRequiredFirst(capabilities, already_invoked, requested);
    }

    const dialect = blk: {
        var d = claude.wire;
        d.activateCapabilitiesFn = activateCapabilities;
        d.routeToolChoiceFn = routeToolChoice;
        break :blk d;
    };
};

// ── 测试 ─────────────────────────────────────────────────────────────────────

fn thinkingBytes(d: Dialect, effort: ?ReasoningEffort, out: *std.ArrayList(u8)) !void {
    out.clearRetainingCapacity();
    try d.serializeThinking(.{}, effort, out, std.testing.allocator);
}

test "GLM-5.3: 思考恒开,effort 只发 low/high/max" {
    const a = std.testing.allocator;
    const d = dialect(.openai, "glm-5.3").?;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    inline for (.{
        .{ ReasoningEffort.none, "low" },
        .{ ReasoningEffort.medium, "high" },
        .{ ReasoningEffort.high, "high" },
        .{ ReasoningEffort.xhigh, "max" },
        .{ ReasoningEffort.max, "max" },
    }) |case| {
        try thinkingBytes(d, case[0], &out);
        try std.testing.expect(std.mem.indexOf(u8, out.items, "\"thinking\":{\"type\":\"enabled\"}") != null);
        try std.testing.expect(std.mem.indexOf(u8, out.items, "disabled") == null);
        try std.testing.expect(std.mem.indexOf(u8, out.items, "\"reasoning_effort\":\"" ++ case[1] ++ "\"") != null);
    }
    try thinkingBytes(d, null, &out);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "reasoning_effort") == null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"type\":\"enabled\"") != null);
}

test "GLM-5.2: thinking + clear_thinking + 顶层 reasoning_effort 原样透传" {
    const a = std.testing.allocator;
    const d = dialect(.openai, "glm-5.2").?;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try thinkingBytes(d, .high, &out);
    try std.testing.expectEqualStrings(",\"thinking\":{\"type\":\"enabled\"},\"clear_thinking\":false,\"reasoning_effort\":\"high\"", out.items);
    try thinkingBytes(d, .xhigh, &out);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"reasoning_effort\":\"xhigh\"") != null);
    try thinkingBytes(d, null, &out);
    try std.testing.expectEqualStrings(",\"thinking\":{\"type\":\"enabled\"},\"clear_thinking\":false", out.items);
    try thinkingBytes(d, .none, &out);
    try std.testing.expectEqualStrings(",\"thinking\":{\"type\":\"disabled\"}", out.items);
}

test "GLM: Skill 能力提示只在暴露 Skill 时注入,不再注入 <reasoning_effort> 标签" {
    const a = std.testing.allocator;
    const d = dialect(.openai, "glm-5.2").?;
    var sys: std.ArrayList(u8) = .empty;
    defer sys.deinit(a);
    try sys.appendSlice(a, "base system\n\n# Available skills\n- verify: bounded review");
    try d.activateCapabilities(.{}, .{ .skill_tool = true }, &sys, a);
    try std.testing.expect(std.mem.indexOf(u8, sys.items, "<reasoning_effort>") == null);
    try std.testing.expect(std.mem.indexOf(u8, sys.items, capability_activation.STRICT_SKILL_SECTION_MARKER) != null);
}

test "GLM: tool_choice 只认 auto,json_schema 降级 json_object" {
    const a = std.testing.allocator;
    const d = dialect(.openai, "glm-5.2").?;
    const p = d.profileFor(.openai, "glm-5.2");
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    _ = try d.serializeToolChoice(p, .{ .type = "any" }, &out, a);
    try std.testing.expectEqualStrings(",\"tool_choice\":\"auto\"", out.items);
    out.clearRetainingCapacity();
    _ = try d.serializeResponseFormat(p, .{ .kind = .json_schema, .schema = "{}" }, &out, a);
    try std.testing.expectEqualStrings(",\"response_format\":{\"type\":\"json_object\"}", out.items);
}

test "GLM 经 Anthropic wire: Skill 契约 + required-first 路由,Claude 不受影响" {
    const allocator = std.testing.allocator;
    const glm = dialect(.anthropic, "glm-5.2").?;
    var system: std.ArrayList(u8) = .empty;
    defer system.deinit(allocator);
    try system.appendSlice(allocator, "base\n\n# Available skills\n- verify: bounded review");
    try glm.activateCapabilities(.{}, .{ .skill_tool = true }, &system, allocator);
    try std.testing.expect(std.mem.indexOf(u8, system.items, capability_activation.STRICT_SKILL_SECTION_MARKER) != null);

    const required = dialect_mod.VisibleCapabilities{ .skill_tool = true, .required_first = .{
        .tool_name = "Skill",
        .argument_name = "name",
        .argument_value = "verify-change",
    } };
    const first = glm.routeToolChoice(.{}, required, false, null).?;
    try std.testing.expectEqualStrings("tool", first.type);
    try std.testing.expectEqualStrings("Skill", first.name.?);
    try std.testing.expect(glm.routeToolChoice(.{}, required, true, null) == null);
}

test "GLM 经 Anthropic wire: 文本模型不收图(能力守门)" {
    const d = dialect(.anthropic, "glm-5.2").?;
    const a = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    const p = d.profileFor(.anthropic, "glm-5.2");
    try std.testing.expect(!p.supports_image_input);
    try std.testing.expect(!(try d.serializeImagePart(p, .{ .media_type = "image/png", .data = "QUJD" }, &out, a)));
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}

test "GLM 按名推断: OpenAI wire 认 glm-6,Anthropic wire 只认 glm-4/glm-5" {
    try std.testing.expect(claims(.openai, "GLM-5.2"));
    try std.testing.expect(claims(.openai, "glm-6"));
    try std.testing.expect(!claims(.anthropic, "glm-6"));
    try std.testing.expect(claims(.anthropic, "glm-5.3-flash"));
    try std.testing.expect(!claims(.gemini, "glm-5.2"));
    try std.testing.expect(!claims(.openai, "gpt-5"));
}
