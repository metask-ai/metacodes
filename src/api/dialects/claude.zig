//! Anthropic Claude dialect 实现。
//!
//! Claude 4.x thinking 控制:顶层 `thinking:{type:adaptive, budget_tokens:N}` + `output_config:{reasoning_effort:high}`。
//! preserved thinking 默认 true(Claude 自动保留思考块)。

const std = @import("std");
const types = @import("../../types.zig");
const util_json = @import("../../util/json.zig");
const model_adapter = @import("../model_adapter.zig");
const dialect_mod = @import("../dialect.zig");

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
            try util_json.serializeString(e.name(), out, a);
            try out.append(a, '}');
            try out.appendSlice(a, ",\"thinking\":{\"type\":\"adaptive\"}");
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

    const dialect = Dialect{
        .ctx = undefined,
        .serializeThinkingFn = serializeThinking,
        .extractThinkingDeltaFn = extractThinkingDelta,
        .serializeToolChoiceFn = serializeToolChoice,
    };
};

pub fn claudeDialectFor(model: []const u8) Dialect {
    _ = model;
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

test "claudeDialectFor: effort=null 不发 thinking wire" {
    const d = claudeDialectFor("claude-sonnet-4");
    const a = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try d.serializeThinking(.{}, null, &out, a);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}
