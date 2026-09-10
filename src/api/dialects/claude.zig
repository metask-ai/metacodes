//! Anthropic Claude dialect 实现。
//!
//! Claude 4.x thinking 控制:顶层 `thinking:{type:adaptive, budget_tokens:N}` + `output_config:{reasoning_effort:high}`。
//! preserved thinking 默认 true(Claude 自动保留思考块)。

const std = @import("std");
const types = @import("../../types.zig");
const util_json = @import("../../util/json.zig");
const model_adapter = @import("../model_adapter.zig");
const dialect_mod = @import("../dialect.zig");
const capability_activation = @import("../capability_activation.zig");

const Dialect = dialect_mod.Dialect;
const ModelProfile = model_adapter.ModelProfile;
const ReasoningEffort = types.ReasoningEffort;
const ToolChoice = dialect_mod.ToolChoice;

const Stateless = struct {};
var stateless: Stateless = .{};
fn statelessCtx() *anyopaque {
    return @ptrCast(&stateless);
}

const Claude = struct {
    fn serializeThinking(ctx: *anyopaque, p: ModelProfile, effort: ?ReasoningEffort, out: *std.ArrayList(u8), a: std.mem.Allocator) anyerror!void {
        _ = ctx;
        _ = p;
        // Claude:thinking.type=adaptive + output_config.effort(对齐 metacodes request.zig 既有 wire)。
        // effort=null 时省略(让 Anthropic 端用默认)。
        if (effort) |e| if (e.active()) {
            try out.appendSlice(a, ",\"output_config\":{\"effort\":");
            try util_json.serializeString(anthropicEffortName(e), out, a);
            try out.append(a, '}');
            try out.appendSlice(a, ",\"thinking\":{\"type\":\"adaptive\"}");
        };
    }

    /// Anthropic Messages `output_config.effort` 的词汇是 low / medium / high / **max**。
    /// 中立枚举的顶档 `.xhigh` 是 OpenAI 的叫法,原样发过去不是 Anthropic 认的值;Metask
    /// 网关的目录对 glm-5.3-flash 也只声明 high/max。其余档位各家叫法一致,原样透传。
    fn anthropicEffortName(e: ReasoningEffort) []const u8 {
        return switch (e) {
            .xhigh => "max",
            else => e.name(),
        };
    }

    fn extractThinkingDelta(ctx: *anyopaque, raw: []const u8, a: std.mem.Allocator) anyerror!?[]u8 {
        _ = ctx;
        _ = raw;
        _ = a;
        // Claude 用 SSE 事件类型 thinking_delta,不经 chunk 解析;Anthropic stream.zig
        // 的 extractThinkingDelta 直接处理。这里返 null。
        return null;
    }

    /// Claude:tool_choice 已是 Anthropic 语义,直接透传 wire(由 request.zig 既有路径处理)。
    /// 这里返 false 表示"dialect 不接管"——request.zig 的 tool_choice 序列化路径保持原样。
    /// (若将来要让 dialect 接管 Anthropic 的 tool_choice 序列化,把这里改成真序列化即可。)
    fn serializeToolChoice(ctx: *anyopaque, p: ModelProfile, tc: ?ToolChoice, out: *std.ArrayList(u8), a: std.mem.Allocator) anyerror!bool {
        _ = ctx;
        _ = p;
        _ = tc;
        _ = out;
        _ = a;
        return false;
    }

    /// Anthropic Messages API 图像 content block:
    /// {"type":"image","source":{"type":"base64","media_type":<mime>,"data":<b64>}}。
    /// 能力守门在 Dialect.serializeImagePart wrapper(集中一处);本实现只管 wire 形态。
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

    const dialect = Dialect{
        .ctx = undefined,
        .serializeThinkingFn = serializeThinking,
        .extractThinkingDeltaFn = extractThinkingDelta,
        .serializeToolChoiceFn = serializeToolChoice,
        .serializeImagePartFn = serializeImagePart,
    };
};

/// GLM models are also exposed by Anthropic-compatible gateways. They keep the
/// Anthropic wire dialect but benefit from a stricter capability-call contract;
/// this is a presentation projection only and never auto-authorizes a Skill.
const GlmAnthropic = struct {
    fn activateCapabilities(ctx: *anyopaque, p: ModelProfile, capabilities: @import("../dialect.zig").VisibleCapabilities, system: *std.ArrayList(u8), allocator: std.mem.Allocator) anyerror!void {
        _ = ctx;
        _ = p;
        try capability_activation.injectStrictSkillToolFirst(
            system,
            capabilities.skill_tool,
            capabilities.requiredSkillInvocation(),
            allocator,
        );
    }

    fn routeToolChoice(ctx: *anyopaque, p: ModelProfile, capabilities: dialect_mod.VisibleCapabilities, already_invoked: bool, requested: ?ToolChoice) ?ToolChoice {
        _ = ctx;
        _ = p;
        return dialect_mod.routeRequiredFirst(capabilities, already_invoked, requested);
    }

    const dialect = Dialect{
        .ctx = undefined,
        .serializeThinkingFn = Claude.serializeThinking,
        .activateCapabilitiesFn = activateCapabilities,
        .routeToolChoiceFn = routeToolChoice,
        .extractThinkingDeltaFn = Claude.extractThinkingDelta,
        .serializeToolChoiceFn = Claude.serializeToolChoice,
        .serializeImagePartFn = Claude.serializeImagePart,
    };
};

pub fn claudeDialectFor(model: []const u8) Dialect {
    if (model_adapter.hasSubstr(model, "glm-5") or
        model_adapter.hasSubstr(model, "glm4") or
        model_adapter.hasSubstr(model, "glm-4"))
        return GlmAnthropic.dialect.withCtx(statelessCtx());
    return Claude.dialect.withCtx(statelessCtx());
}

// ── 测试 ─────────────────────────────────────────────────────────────────────

test "claudeDialectFor: effort=high 发 thinking adaptive + output_config" {
    const d = claudeDialectFor("claude-sonnet-4");
    const a = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try d.serializeThinking(.{}, .high, &out, a);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"thinking\":{\"type\":\"adaptive\"}") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"output_config\":{\"effort\":\"high\"}") != null);
}

test "claudeDialectFor: effort=xhigh 在 Anthropic wire 上是 max(Claude 与经网关的 GLM 同)" {
    const allocator = std.testing.allocator;
    for ([_][]const u8{ "claude-opus-4-6", "glm-5.3-flash" }) |model| {
        const d = claudeDialectFor(model);
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(allocator);
        try d.serializeThinking(.{}, .xhigh, &out, allocator);
        try std.testing.expect(std.mem.indexOf(u8, out.items, "\"output_config\":{\"effort\":\"max\"}") != null);
        try std.testing.expect(std.mem.indexOf(u8, out.items, "xhigh") == null);
        try std.testing.expect(std.mem.indexOf(u8, out.items, "\"thinking\":{\"type\":\"adaptive\"}") != null);
    }
    // 其它档位原样。
    const d = claudeDialectFor("claude-opus-4-6");
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    try d.serializeThinking(.{}, .medium, &out, allocator);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"output_config\":{\"effort\":\"medium\"}") != null);
}

test "claudeDialectFor: effort=null 不发 thinking wire" {
    const d = claudeDialectFor("claude-sonnet-4");
    const a = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try d.serializeThinking(.{}, null, &out, a);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}

test "Anthropic-compatible GLM adds strict Skill activation only when visible" {
    const allocator = std.testing.allocator;
    const glm = claudeDialectFor("glm-5.2");
    var system: std.ArrayList(u8) = .empty;
    defer system.deinit(allocator);
    try system.appendSlice(allocator, "base\n\n# Available skills\n- verify: bounded review");
    try glm.activateCapabilities(.{}, .{ .skill_tool = true }, &system, allocator);
    try std.testing.expect(std.mem.indexOf(
        u8,
        system.items,
        capability_activation.STRICT_SKILL_SECTION_MARKER,
    ) != null);

    const claude = claudeDialectFor("claude-sonnet-4");
    var ordinary: std.ArrayList(u8) = .empty;
    defer ordinary.deinit(allocator);
    try ordinary.appendSlice(allocator, "base\n\n# Available skills\n- verify");
    try claude.activateCapabilities(.{}, .{ .skill_tool = true }, &ordinary, allocator);
    try std.testing.expect(std.mem.indexOf(
        u8,
        ordinary.items,
        capability_activation.STRICT_SKILL_SECTION_MARKER,
    ) == null);

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

test "Claude dialect: serializeImagePart 发 base64 source block" {
    const d = claudeDialectFor("claude-sonnet-4");
    const a = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    const p = d.profileFor(.anthropic, "claude-sonnet-4");
    const ok = try d.serializeImagePart(p, .{ .media_type = "image/png", .data = "QUJD" }, &out, a);
    try std.testing.expect(ok);
    try std.testing.expectEqualStrings(
        "{\"type\":\"image\",\"source\":{\"type\":\"base64\",\"media_type\":\"image/png\",\"data\":\"QUJD\"}}",
        out.items,
    );
}

test "Claude dialect: profile 不支持 vision 时 serializeImagePart 返 false 不输出" {
    // 经 Anthropic 网关的 GLM 文本模型:能力守门,调用方据 false 报显式错误。
    const d = claudeDialectFor("glm-5.2");
    const a = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    const p = d.profileFor(.anthropic, "glm-5.2");
    try std.testing.expect(!p.supports_image_input);
    const ok = try d.serializeImagePart(p, .{ .media_type = "image/png", .data = "QUJD" }, &out, a);
    try std.testing.expect(!ok);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}
