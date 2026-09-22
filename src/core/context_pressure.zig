const std = @import("std");

pub const OUTPUT_RESERVE_TOKENS: usize = 20_000;
pub const AUTOCOMPACT_BUFFER_TOKENS: usize = 13_000;
pub const BLOCKING_LIMIT_BUFFER_TOKENS: usize = 3_000;
pub const TOKEN_WARNING_BUFFER_TOKENS: usize = 20_000;
/// The window the three buffers above were sized for (cc's 200K Claude window).
/// On larger windows they scale linearly, so a 1M window keeps the same 6.5% /
/// 10% / 1.5% margins instead of shrinking to 1.3% / 2% / 0.3% — margins that
/// any counting difference between client and server swallows whole.
pub const BUFFER_REFERENCE_WINDOW_TOKENS: usize = 200_000;

/// Scale a 200K-tuned buffer to `effective_window`; never below its base.
pub fn scaledBuffer(base: usize, effective_window: usize) usize {
    if (effective_window <= BUFFER_REFERENCE_WINDOW_TOKENS) return base;
    const scaled = (@as(u128, base) * @as(u128, effective_window)) / @as(u128, BUFFER_REFERENCE_WINDOW_TOKENS);
    return @intCast(@min(scaled, @as(u128, std.math.maxInt(usize))));
}

pub const ContextPressure = struct {
    pub const Level = enum {
        low,
        medium,
        high,
        critical,

        pub fn label(self: Level) []const u8 {
            return switch (self) {
                .low => "low",
                .medium => "medium",
                .high => "high",
                .critical => "critical",
            };
        }
    };

    raw_context_window: usize,
    /// Prompt room after the output reserve, as the catalog describes it.
    catalog_effective_window: usize,
    /// A wall measured on this endpoint (core.context_caps), when one is known.
    learned_input_cap: ?usize,
    /// min(catalog_effective_window, learned_input_cap): what the thresholds hang off.
    effective_context_window: usize,
    auto_compact_threshold: usize,
    warning_threshold: usize,
    blocking_limit: usize,
    current_context_tokens: usize,

    pub fn fromModel(
        raw_context_window: usize,
        max_output_tokens: usize,
        configured_auto_compact_threshold: ?usize,
        current_context_tokens: usize,
    ) ContextPressure {
        return fromModelWithCap(raw_context_window, max_output_tokens, configured_auto_compact_threshold, current_context_tokens, null);
    }

    /// Same derivation, bounded by a learned wall. The catalog window stays an
    /// upper bound: a learned cap can only pull the thresholds down.
    pub fn fromModelWithCap(
        raw_context_window: usize,
        max_output_tokens: usize,
        configured_auto_compact_threshold: ?usize,
        current_context_tokens: usize,
        learned_input_cap: ?usize,
    ) ContextPressure {
        // 输出预留必须按实际请求的 max_tokens **全额**预留(下限 20K 作余量):
        // 服务端普遍校验 input + max_tokens ≤ context window(Anthropic "prompt is
        // 服务端普遍校验 input + max_tokens ≤ context window（Anthropic 报 "prompt is
        // too long"；glm-5.2/metask 在 2026-07-06 曾实测 198758 input + 64000 completion
        // 直接 400，说明当时窗口为 262144）。2026-09-05 同一线路实测 /v1/models 报
        // max_input_tokens=1048576、max_tokens=64000；1,001,205 input tokens 请求成功，
        // 1,101,379 tokens 返回 400 "longer than the model's context length (1048576 tokens)"。
        // 公式与具体窗口无关。旧公式 @min(max_output, 20K) 只留 20K，glm-5.2
        // （窗口 262144、max_tokens 64000）算出 auto 阈值 229144 高于真实输入上限
        // 198144，压缩永远来不及，长会话必撞 400——这是 "auto compact 失效" 的主因。
        const output_reserve = @max(max_output_tokens, OUTPUT_RESERVE_TOKENS);
        const catalog_effective = raw_context_window -| output_reserve;
        const effective = if (learned_input_cap) |cap| @min(catalog_effective, cap) else catalog_effective;
        const formula_auto = effective -| scaledBuffer(AUTOCOMPACT_BUFFER_TOKENS, effective);
        const auto = if (configured_auto_compact_threshold) |v| @min(v, formula_auto) else formula_auto;
        return .{
            .raw_context_window = raw_context_window,
            .catalog_effective_window = catalog_effective,
            .learned_input_cap = learned_input_cap,
            .effective_context_window = effective,
            .auto_compact_threshold = auto,
            .warning_threshold = effective -| scaledBuffer(TOKEN_WARNING_BUFFER_TOKENS, effective),
            .blocking_limit = effective -| scaledBuffer(BLOCKING_LIMIT_BUFFER_TOKENS, effective),
            .current_context_tokens = current_context_tokens,
        };
    }

    pub fn isAtAutoCompactThreshold(self: ContextPressure) bool {
        return self.current_context_tokens >= self.auto_compact_threshold;
    }

    pub fn isAtBlockingLimit(self: ContextPressure) bool {
        return self.current_context_tokens >= self.blocking_limit;
    }

    pub fn isAtWarningThreshold(self: ContextPressure) bool {
        return self.current_context_tokens >= self.warning_threshold;
    }

    pub fn level(self: ContextPressure) Level {
        if (self.current_context_tokens >= self.blocking_limit) return .critical;
        if (self.current_context_tokens >= self.auto_compact_threshold) return .high;
        if (self.current_context_tokens >= self.warning_threshold) return .medium;
        return .low;
    }
};

test "ContextPressure reserves full max_output_tokens" {
    // 200K 窗口 + 32K 输出:effective = 200K-32K = 168K(服务端校验 in+max_tokens ≤ window)。
    const p = ContextPressure.fromModel(200_000, 32_000, null, 0);
    try std.testing.expectEqual(@as(usize, 168_000), p.effective_context_window);
    try std.testing.expectEqual(@as(usize, 155_000), p.auto_compact_threshold);
    try std.testing.expectEqual(@as(usize, 148_000), p.warning_threshold);
    try std.testing.expectEqual(@as(usize, 165_000), p.blocking_limit);
    try std.testing.expectEqual(ContextPressure.Level.low, p.level());
    // 小 max_tokens 也保底 20K 预留。
    const small_out = ContextPressure.fromModel(200_000, 4_096, null, 0);
    try std.testing.expectEqual(@as(usize, 180_000), small_out.effective_context_window);
}

test "ContextPressure glm-5.2 metask historical July parameters" {
    // 参数为 2026-07 历史值：2026-07-06 窗口 262144、max_tokens 64000，服务端强制
    // in+completion ≤ 262144，因而真实 input 上限为 198144；阈值必须低于它。
    // 2026-09-05 的当前实测为 1048576，但公式对任一窗口都成立。
    const p = ContextPressure.fromModel(262_144, 64_000, null, 0);
    const real_input_cap: usize = 262_144 - 64_000;
    try std.testing.expectEqual(@as(usize, 185_144), p.auto_compact_threshold);
    try std.testing.expect(p.auto_compact_threshold < real_input_cap);
    try std.testing.expect(p.blocking_limit < real_input_cap);
    try std.testing.expect(p.warning_threshold < p.auto_compact_threshold);
}

test "ContextPressure configured auto threshold is capped at formula limit" {
    const low = ContextPressure.fromModel(200_000, 32_000, 140_000, 140_000);
    try std.testing.expectEqual(@as(usize, 140_000), low.auto_compact_threshold);
    try std.testing.expect(low.isAtAutoCompactThreshold());

    const high = ContextPressure.fromModel(200_000, 32_000, 250_000, 160_000);
    try std.testing.expectEqual(@as(usize, 155_000), high.auto_compact_threshold);
    try std.testing.expect(high.isAtAutoCompactThreshold());
}

test "ContextPressure exposes low medium high critical levels" {
    try std.testing.expectEqual(ContextPressure.Level.low, ContextPressure.fromModel(200_000, 32_000, null, 147_999).level());
    try std.testing.expectEqual(ContextPressure.Level.medium, ContextPressure.fromModel(200_000, 32_000, null, 148_000).level());
    try std.testing.expectEqual(ContextPressure.Level.high, ContextPressure.fromModel(200_000, 32_000, null, 155_000).level());
    try std.testing.expectEqual(ContextPressure.Level.critical, ContextPressure.fromModel(200_000, 32_000, null, 165_000).level());
    try std.testing.expectEqualStrings("critical", ContextPressure.Level.critical.label());
}

test "ContextPressure scales the buffers with the window above 200K" {
    // 200K reference: identical to the historical constants.
    try std.testing.expectEqual(@as(usize, 13_000), scaledBuffer(AUTOCOMPACT_BUFFER_TOKENS, 168_000));
    try std.testing.expectEqual(@as(usize, 13_000), scaledBuffer(AUTOCOMPACT_BUFFER_TOKENS, 200_000));
    // Metask glm-5.3-flash catalog (2026-09-22): 1,048,576 window, 131,072 max_tokens.
    const p = ContextPressure.fromModel(1_048_576, 131_072, null, 0);
    try std.testing.expectEqual(@as(usize, 917_504), p.catalog_effective_window);
    try std.testing.expectEqual(@as(usize, 917_504), p.effective_context_window);
    // 13K × 917,504 / 200,000 = 59,637 (6.5%, not 1.4%).
    try std.testing.expectEqual(@as(usize, 917_504 - 59_637), p.auto_compact_threshold);
    try std.testing.expectEqual(@as(usize, 917_504 - 91_750), p.warning_threshold);
    try std.testing.expectEqual(@as(usize, 917_504 - 13_762), p.blocking_limit);
    try std.testing.expect(p.warning_threshold < p.auto_compact_threshold);
    try std.testing.expect(p.auto_compact_threshold < p.blocking_limit);
}

test "ContextPressure learned cap lowers every threshold and never raises them" {
    // The wall measured on that route was ≈883K, 34K under the catalog's 917,504.
    const learned = ContextPressure.fromModelWithCap(1_048_576, 131_072, null, 0, 883_000);
    try std.testing.expectEqual(@as(?usize, 883_000), learned.learned_input_cap);
    try std.testing.expectEqual(@as(usize, 917_504), learned.catalog_effective_window);
    try std.testing.expectEqual(@as(usize, 883_000), learned.effective_context_window);
    try std.testing.expectEqual(@as(usize, 883_000 - 57_395), learned.auto_compact_threshold);
    try std.testing.expect(learned.blocking_limit < 883_000);
    // A cap above the catalog window is ignored: the catalog stays the upper bound.
    const loose = ContextPressure.fromModelWithCap(1_048_576, 131_072, null, 0, 2_000_000);
    try std.testing.expectEqual(@as(usize, 917_504), loose.effective_context_window);
    // Session-configured thresholds still clamp from above.
    const configured = ContextPressure.fromModelWithCap(1_048_576, 131_072, 500_000, 0, 883_000);
    try std.testing.expectEqual(@as(usize, 500_000), configured.auto_compact_threshold);
    // Tiny observed caps degrade gracefully (saturating), no underflow.
    const tiny = ContextPressure.fromModelWithCap(200_000, 32_000, null, 0, 100);
    try std.testing.expectEqual(@as(usize, 0), tiny.auto_compact_threshold);
}
