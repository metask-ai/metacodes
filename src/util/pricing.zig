//! 价格表（USD per million tokens）。
//! 数字可能随 Anthropic 调价变化，属于 L2 事实而非 L1 记忆——需要时更新常量即可。
//! 参考：https://www.anthropic.com/pricing （2026-04 snapshot）

const std = @import("std");
const model_name = @import("../api/model_name.zig");

pub const Rates = struct {
    /// 每百万 input token USD
    input_per_mtok: f64,
    output_per_mtok: f64,
    cache_read_per_mtok: f64,
    cache_write_per_mtok: f64,
};

/// 默认 fallback：按 sonnet 4 的价格算。
pub const DEFAULT_RATES: Rates = .{
    .input_per_mtok = 3.0,
    .output_per_mtok = 15.0,
    .cache_read_per_mtok = 0.30,
    .cache_write_per_mtok = 3.75,
};

/// GLM-5.2 production pilot guardrail. This deliberately keeps the higher
/// Sonnet-4 USD rates instead of pretending the provider's RMB bill is known.
/// Zhipu's 2026-08-07 public price (8/28 RMB per MTok, 2 RMB cache hit) and
/// Metask's official-price policy make this conservative for authorization;
/// it remains an estimate, never a provider-billed cost.
pub const GLM_52_GUARDRAIL_RATES = DEFAULT_RATES;
pub const GLM_52_GUARDRAIL_PROVENANCE = "metacodes_glm-5.2_conservative_sonnet4_usd_guardrail_2026-08-07_not_provider_bill";

/// 按 model 名称（子串匹配）返回单价。未匹配到 → DEFAULT_RATES。
pub fn rateFor(model: []const u8) Rates {
    if (model_name.eqlIgnoreCase(model, "glm-5.2")) return GLM_52_GUARDRAIL_RATES;
    // opus 系列
    if (model_name.containsIgnoreCase(model, "opus")) {
        return .{
            .input_per_mtok = 15.0,
            .output_per_mtok = 75.0,
            .cache_read_per_mtok = 1.50,
            .cache_write_per_mtok = 18.75,
        };
    }
    // haiku 系列
    if (model_name.containsIgnoreCase(model, "haiku")) {
        return .{
            .input_per_mtok = 1.0,
            .output_per_mtok = 5.0,
            .cache_read_per_mtok = 0.10,
            .cache_write_per_mtok = 1.25,
        };
    }
    // sonnet / 默认
    return DEFAULT_RATES;
}

pub fn provenanceFor(model: []const u8) []const u8 {
    if (model_name.eqlIgnoreCase(model, "glm-5.2")) return GLM_52_GUARDRAIL_PROVENANCE;
    return "metacodes_builtin_2026-04_with_fallback";
}

/// 计算给定 usage 的总 cost（USD）。
pub fn computeCost(rates: Rates, input_tokens: u64, output_tokens: u64, cache_read: u64, cache_write: u64) f64 {
    const i = @as(f64, @floatFromInt(input_tokens)) / 1_000_000.0 * rates.input_per_mtok;
    const o = @as(f64, @floatFromInt(output_tokens)) / 1_000_000.0 * rates.output_per_mtok;
    const cr = @as(f64, @floatFromInt(cache_read)) / 1_000_000.0 * rates.cache_read_per_mtok;
    const cw = @as(f64, @floatFromInt(cache_write)) / 1_000_000.0 * rates.cache_write_per_mtok;
    return i + o + cr + cw;
}

test "rateFor sonnet default" {
    const r = rateFor("claude-sonnet-4-20250514");
    try std.testing.expect(r.input_per_mtok == 3.0);
}

test "glm-5.2 uses explicit conservative guardrail provenance" {
    const rates = rateFor("glm-5.2");
    try std.testing.expectEqual(GLM_52_GUARDRAIL_RATES, rates);
    try std.testing.expectEqualStrings(GLM_52_GUARDRAIL_PROVENANCE, provenanceFor("glm-5.2"));
}

test "rateFor opus" {
    const r = rateFor("claude-opus-4");
    try std.testing.expect(r.input_per_mtok == 15.0);
}

test "rateFor haiku" {
    const r = rateFor("claude-haiku-4-5");
    try std.testing.expect(r.input_per_mtok == 1.0);
}

test "computeCost basic" {
    const r = DEFAULT_RATES;
    const c = computeCost(r, 1_000_000, 0, 0, 0);
    try std.testing.expect(@abs(c - 3.0) < 1e-9);
}

test "computeCost all components" {
    const r = DEFAULT_RATES;
    const c = computeCost(r, 1_000_000, 1_000_000, 1_000_000, 1_000_000);
    // 3 + 15 + 0.30 + 3.75 = 22.05
    try std.testing.expect(@abs(c - 22.05) < 1e-6);
}
