//! 模型元数据：model name → max output tokens（默认 + 上限）。
//!
//! 数字对齐 TypeScript 版 `cc/src/utils/context.ts::getModelMaxOutputTokens`：
//!   default = 单次请求优先用的值（请求构造时的 max_tokens）
//!   upper   = 重试时可提升到的上限
//!
//! TS 版不按 input_tokens 动态缩减 max_tokens —— max_tokens 只看模型默认 + 用户 override +
//! 重试升级。Context 占用控制由独立的 auto-compact 机制（M6）负责。
//!
//! 未知模型 → DEFAULT_MAX_TOKENS (32000) / DEFAULT_UPPER_LIMIT (64000)。

const std = @import("std");

pub const DEFAULT_MAX_TOKENS: u32 = 32_000;
pub const DEFAULT_UPPER_LIMIT: u32 = 64_000;

pub const ModelLimits = struct {
    /// 请求构造时默认使用的 max_tokens
    default: u32,
    /// 重试升级时的上限（hit max_tokens stop_reason 时）
    upper: u32,
};

const ModelEntry = struct {
    prefix: []const u8,
    limits: ModelLimits,
};

/// 按前缀从长到短排（避免 "claude-3" 误命中 "claude-3-opus"）。
const TABLE = [_]ModelEntry{
    // Claude 4.x —— 对齐 TS context.ts L149-210
    .{ .prefix = "claude-opus-4-6", .limits = .{ .default = 64_000, .upper = 128_000 } },
    .{ .prefix = "claude-opus-4-5", .limits = .{ .default = 32_000, .upper = 64_000 } },
    .{ .prefix = "claude-opus-4", .limits = .{ .default = 32_000, .upper = 64_000 } },
    .{ .prefix = "claude-sonnet-4-6", .limits = .{ .default = 32_000, .upper = 128_000 } },
    .{ .prefix = "claude-sonnet-4", .limits = .{ .default = 32_000, .upper = 64_000 } },
    .{ .prefix = "claude-haiku-4", .limits = .{ .default = 32_000, .upper = 64_000 } },
    // Claude 3.x legacy
    .{ .prefix = "claude-3-5-sonnet", .limits = .{ .default = 8_192, .upper = 8_192 } },
    .{ .prefix = "claude-3-5-haiku", .limits = .{ .default = 8_192, .upper = 8_192 } },
    .{ .prefix = "claude-3-opus", .limits = .{ .default = 4_096, .upper = 4_096 } },
    .{ .prefix = "claude-3-sonnet", .limits = .{ .default = 4_096, .upper = 4_096 } },
    .{ .prefix = "claude-3-haiku", .limits = .{ .default = 4_096, .upper = 4_096 } },
};

/// 查模型限额。未知模型返 DEFAULT。
pub fn limitsFor(model: []const u8) ModelLimits {
    for (TABLE) |e| {
        if (std.mem.startsWith(u8, model, e.prefix)) return e.limits;
    }
    return .{ .default = DEFAULT_MAX_TOKENS, .upper = DEFAULT_UPPER_LIMIT };
}

/// 简易 API：只要 default 值（供 catalog.maxTokensFor 兜底）。
pub fn maxOutputTokens(model: []const u8) u32 {
    return limitsFor(model).default;
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "Sonnet 4.6 limits" {
    const l = limitsFor("claude-sonnet-4-6");
    try testing.expect(l.default == 32_000);
    try testing.expect(l.upper == 128_000);
}

test "Opus 4.6 limits" {
    const l = limitsFor("claude-opus-4-6-20260204");
    try testing.expect(l.default == 64_000);
    try testing.expect(l.upper == 128_000);
}

test "Sonnet 4 (non 4.6) limits" {
    const l = limitsFor("claude-sonnet-4-20250514");
    try testing.expect(l.default == 32_000);
    try testing.expect(l.upper == 64_000);
}

test "Haiku 4.5 limits" {
    const l = limitsFor("claude-haiku-4-5-20251001");
    try testing.expect(l.default == 32_000);
    try testing.expect(l.upper == 64_000);
}

test "legacy Claude 3.5 sonnet" {
    const l = limitsFor("claude-3-5-sonnet-20241022");
    try testing.expect(l.default == 8_192);
}

test "unknown model falls back to default" {
    const l = limitsFor("mysterious-model-x");
    try testing.expect(l.default == DEFAULT_MAX_TOKENS);
    try testing.expect(l.upper == DEFAULT_UPPER_LIMIT);
}

test "maxOutputTokens alias returns default" {
    try testing.expect(maxOutputTokens("claude-sonnet-4-6") == 32_000);
}

test "prefix matching precision: sonnet-4-6 must win over sonnet-4" {
    // "claude-sonnet-4-6-xxx" 应该命中 4-6（128k upper），不是 4（64k upper）
    const l = limitsFor("claude-sonnet-4-6-20260217");
    try testing.expect(l.upper == 128_000);
}
