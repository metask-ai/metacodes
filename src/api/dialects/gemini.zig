//! Google Gemini dialect 实现。
//!
//! Gemini thinking 控制:generation_config.thinking_level = "low"/"high"(Gemini 2.5+)。
//! Gemini 不经 OpenAI-compatible 端点,走原生 generateContent;但 dialect 仍提供 serializeThinking
//! 供未来 Gemini 侧接 thinking 控制时用(当前 gemini_client.zig 未接,留位)。

const std = @import("std");
const types = @import("../../types.zig");
const util_json = @import("../../util/json.zig");
const model_adapter = @import("../model_adapter.zig");
const dialect_mod = @import("../dialect.zig");

const Dialect = dialect_mod.Dialect;
const ModelProfile = model_adapter.ModelProfile;
const ReasoningEffort = types.ReasoningEffort;

const Stateless = struct {};
var stateless: Stateless = .{};
fn statelessCtx() *anyopaque {
    return @ptrCast(&stateless);
}

/// effort → Gemini thinking_level 映射。Gemini 只 2 档(low/high)。
fn geminiThinkingLevel(effort: ReasoningEffort) ?[]const u8 {
    if (!effort.active()) return null;
    return switch (effort) {
        .minimal, .low => "low",
        .medium, .high, .xhigh => "high",
        .none => null,
    };
}

const Gemini = struct {
    fn serializeThinking(ctx: *anyopaque, p: ModelProfile, effort: ?ReasoningEffort, out: *std.ArrayList(u8), a: std.mem.Allocator) anyerror!void {
        _ = ctx;
        _ = p;
        // Gemini:generation_config.thinking_level(低/高)。当前 gemini_client.zig 未接 thinking
        // 控制,这里只输出 thinking_level 片段,由调用方合并进 generation_config。
        if (effort) |e| if (geminiThinkingLevel(e)) |level| {
            try out.appendSlice(a, "\"thinking_level\":");
            try util_json.serializeString(level, out, a);
        };
    }

    const dialect = Dialect{
        .ctx = undefined,
        .serializeThinkingFn = serializeThinking,
    };
};

pub fn geminiDialectFor(model: []const u8) Dialect {
    _ = model;
    return Gemini.dialect.withCtx(statelessCtx());
}

// ── 测试 ─────────────────────────────────────────────────────────────────────

test "geminiDialectFor: effort=high 发 thinking_level high" {
    const d = geminiDialectFor("gemini-2.5-pro");
    const a = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try d.serializeThinking(.{}, .high, &out, a);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"thinking_level\":\"high\"") != null);
}

test "geminiDialectFor: effort=low 发 thinking_level low" {
    const d = geminiDialectFor("gemini-2.5-pro");
    const a = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try d.serializeThinking(.{}, .low, &out, a);
    try std.testing.expect(std.mem.indexOf(u8, out.items, "\"thinking_level\":\"low\"") != null);
}

test "geminiDialectFor: effort=null 不发 thinking_level" {
    const d = geminiDialectFor("gemini-2.5-pro");
    const a = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try d.serializeThinking(.{}, null, &out, a);
    try std.testing.expectEqual(@as(usize, 0), out.items.len);
}
