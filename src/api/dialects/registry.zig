//! 厂商方言登记表:`Vendor` 的每个值对应一个接入文件,文件头就是那家厂商的接入文档。
//!
//! 加一家厂商 = 写 `dialects/<vendor>.zig`(文件头按 `REQUIRED_SECTIONS` 写接入说明,
//! 导出 `vendor` / `claims` / `dialect`)+ 在 `Vendor` 里加一个值 + 在 `module` 里加一行。
//! 漏了任何一步,编译期或本文件的测试会失败。
//!
//! 选择方言的规则(`dialectFor`):
//! 1. 按模型名推断厂商(`INFERENCE_ORDER` 里各家的 `claims`,顺序与拆分前的
//!    `openaiDialectFor` / `claudeDialectFor` 相同);
//! 2. 那家在这条 wire 上没有专属方言(`dialect` 返回 null)或认不出厂商 → 用这条 wire 的
//!    基础方言(OpenAI chat → OpenAI 原生,Anthropic → Claude,Gemini → Gemini)。

const std = @import("std");
const model_adapter = @import("../model_adapter.zig");
const dialect_mod = @import("../dialect.zig");
const Vendor = @import("../../provider/vendor.zig").Vendor;

const Dialect = dialect_mod.Dialect;
const ModelProfile = model_adapter.ModelProfile;
const ProviderKind = model_adapter.ProviderKind;

pub const openai = @import("openai.zig");
pub const claude = @import("claude.zig");
pub const gemini = @import("gemini.zig");
pub const glm = @import("glm.zig");
pub const kimi = @import("kimi.zig");
pub const deepseek = @import("deepseek.zig");
pub const qwen = @import("qwen.zig");
pub const minimax = @import("minimax.zig");
pub const mistral = @import("mistral.zig");

/// 每个 `Vendor` 值的接入文件。
pub fn module(comptime v: Vendor) type {
    return switch (v) {
        .openai => openai,
        .claude => claude,
        .gemini => gemini,
        .glm => glm,
        .kimi => kimi,
        .deepseek => deepseek,
        .qwen => qwen,
        .minimax => minimax,
        .mistral => mistral,
    };
}

/// 每个接入文件的源码,供文档契约测试检查文件头。顺序与 `Vendor` 无关。
const SOURCES = [_]struct { vendor: Vendor, text: []const u8 }{
    .{ .vendor = .openai, .text = @embedFile("openai.zig") },
    .{ .vendor = .claude, .text = @embedFile("claude.zig") },
    .{ .vendor = .gemini, .text = @embedFile("gemini.zig") },
    .{ .vendor = .glm, .text = @embedFile("glm.zig") },
    .{ .vendor = .kimi, .text = @embedFile("kimi.zig") },
    .{ .vendor = .deepseek, .text = @embedFile("deepseek.zig") },
    .{ .vendor = .qwen, .text = @embedFile("qwen.zig") },
    .{ .vendor = .minimax, .text = @embedFile("minimax.zig") },
    .{ .vendor = .mistral, .text = @embedFile("mistral.zig") },
};

/// 接入文件头必须有的段落,按顺序。
pub const REQUIRED_SECTIONS = [_][]const u8{
    "//! ## 接入点",
    "//! ## 协议",
    "//! ## 思考与推理",
    "//! ## 回传与缓存",
    "//! ## 已知差异",
    "//! ## 来源",
};

/// 按名推断的顺序:先具体的家族;OpenAI / Claude / Gemini 是各自 wire 的兜底,不参与推断。
const INFERENCE_ORDER = [_]Vendor{ .glm, .kimi, .deepseek, .qwen, .minimax, .mistral };

comptime {
    for (@typeInfo(Vendor).@"enum".fields) |field| {
        const v: Vendor = @field(Vendor, field.name);
        const m = module(v);
        if (m.vendor != v) @compileError("dialects/" ++ field.name ++ ".zig declares the wrong vendor");
        _ = @as(fn (ProviderKind, []const u8) bool, m.claims);
        _ = @as(fn (ProviderKind, []const u8) ?Dialect, m.dialect);
        var found = false;
        for (SOURCES) |source| {
            if (source.vendor == v) found = true;
        }
        if (!found) @compileError("dialects/" ++ field.name ++ ".zig is missing from SOURCES");
    }
}

/// 按模型名推断厂商。
pub fn infer(kind: ProviderKind, model: []const u8) ?Vendor {
    inline for (INFERENCE_ORDER) |v| {
        if (module(v).claims(kind, model)) return v;
    }
    return null;
}

/// `model` 在 `kind` 这条 wire 上的方言:按名推断,再退到这条 wire 的基础方言。
pub fn dialectFor(kind: ProviderKind, model: []const u8) ?Dialect {
    if (infer(kind, model)) |v| switch (v) {
        inline else => |tag| if (module(tag).dialect(kind, model)) |d| return d,
    };
    return switch (kind) {
        .openai => openai.native(),
        .anthropic => claude.dialect(.anthropic, model).?,
        .gemini => gemini.dialect(.gemini, model).?,
        .other => null,
    };
}

/// OpenAI chat wire 上按名推断的家族 profile;认不出时 null(由调用方给 OpenAI 原生默认)。
pub fn inferredOpenAIProfile(model: []const u8) ?ModelProfile {
    const v = infer(.openai, model) orelse return null;
    return switch (v) {
        inline else => |tag| if (@hasDecl(module(tag), "openaiProfile")) module(tag).openaiProfile(model) else null,
    };
}

// ── 测试 ─────────────────────────────────────────────────────────────────────

fn expectIntegrationHeader(name: []const u8, text: []const u8) !void {
    const header_end = std.mem.indexOf(u8, text, "\nconst ") orelse text.len;
    const header = text[0..header_end];
    try std.testing.expect(std.mem.startsWith(u8, header, "//! # "));
    var at: usize = 0;
    for (REQUIRED_SECTIONS) |section| {
        const found = std.mem.indexOfPos(u8, header, at, section) orelse {
            std.debug.print("dialects/{s}.zig: missing section `{s}`\n", .{ name, section });
            return error.MissingIntegrationSection;
        };
        at = found + section.len;
    }
    // "来源" 段至少有一个链接。
    try std.testing.expect(std.mem.indexOfPos(u8, header, at, "https://") != null);
}

test "每个接入文件的文件头都按顺序写全了接入文档段落" {
    for (SOURCES) |source| try expectIntegrationHeader(source.vendor.name(), source.text);
}

test "SOURCES 与 Vendor 一一对应" {
    try std.testing.expectEqual(@typeInfo(Vendor).@"enum".fields.len, SOURCES.len);
}

test "按名推断保持旧顺序:GLM 先于 Kimi 的 k2 子串,OpenAI 兜底" {
    try std.testing.expectEqual(Vendor.glm, infer(.openai, "glm-5.2").?);
    try std.testing.expectEqual(Vendor.kimi, infer(.openai, "kimi-k3").?);
    try std.testing.expectEqual(Vendor.deepseek, infer(.openai, "deepseek-chat").?);
    try std.testing.expectEqual(Vendor.qwen, infer(.openai, "qwen3-235b").?);
    try std.testing.expectEqual(Vendor.minimax, infer(.openai, "MiniMax-M3").?);
    try std.testing.expectEqual(Vendor.mistral, infer(.openai, "magistral-medium").?);
    try std.testing.expect(infer(.openai, "gpt-5") == null);
    try std.testing.expectEqual(Vendor.glm, infer(.anthropic, "glm-5.3-flash").?);
    try std.testing.expect(infer(.anthropic, "deepseek-v4-pro") == null);
    try std.testing.expect(infer(.gemini, "glm-5.2") == null);
}

test "认不出厂商时用这条 wire 的基础方言" {
    const a = std.testing.allocator;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try dialectFor(.openai, "house-relay-model").?.serializeThinking(.{}, .high, &out, a);
    try std.testing.expectEqualStrings(",\"reasoning_effort\":\"high\"", out.items);
    out.clearRetainingCapacity();
    try dialectFor(.anthropic, "kimi-k3").?.serializeThinking(.{}, .high, &out, a);
    try std.testing.expectEqualStrings(",\"output_config\":{\"effort\":\"high\"},\"thinking\":{\"type\":\"adaptive\"}", out.items);
    try std.testing.expect(dialectFor(.other, "x") == null);
}
