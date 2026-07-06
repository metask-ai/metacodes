const std = @import("std");

pub const OUTPUT_RESERVE_TOKENS: usize = 20_000;
pub const AUTOCOMPACT_BUFFER_TOKENS: usize = 13_000;
pub const BLOCKING_LIMIT_BUFFER_TOKENS: usize = 3_000;
pub const TOKEN_WARNING_BUFFER_TOKENS: usize = 20_000;

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
        const output_reserve = @min(max_output_tokens, OUTPUT_RESERVE_TOKENS);
        const effective = raw_context_window -| output_reserve;
        const formula_auto = effective -| AUTOCOMPACT_BUFFER_TOKENS;
        const auto = if (configured_auto_compact_threshold) |v| @min(v, formula_auto) else formula_auto;
        return .{
            .raw_context_window = raw_context_window,
            .effective_context_window = effective,
            .auto_compact_threshold = auto,
            .warning_threshold = effective -| TOKEN_WARNING_BUFFER_TOKENS,
            .blocking_limit = effective -| BLOCKING_LIMIT_BUFFER_TOKENS,
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

test "ContextPressure derives Rust/metacode thresholds" {
    const p = ContextPressure.fromModel(200_000, 32_000, null, 0);
    try std.testing.expectEqual(@as(usize, 180_000), p.effective_context_window);
    try std.testing.expectEqual(@as(usize, 167_000), p.auto_compact_threshold);
    try std.testing.expectEqual(@as(usize, 160_000), p.warning_threshold);
    try std.testing.expectEqual(@as(usize, 177_000), p.blocking_limit);
    try std.testing.expectEqual(ContextPressure.Level.low, p.level());
}

test "ContextPressure configured auto threshold is capped at formula limit" {
    const low = ContextPressure.fromModel(200_000, 32_000, 140_000, 140_000);
    try std.testing.expectEqual(@as(usize, 140_000), low.auto_compact_threshold);
    try std.testing.expect(low.isAtAutoCompactThreshold());

    const high = ContextPressure.fromModel(200_000, 32_000, 250_000, 170_000);
    try std.testing.expectEqual(@as(usize, 167_000), high.auto_compact_threshold);
    try std.testing.expect(high.isAtAutoCompactThreshold());
}

test "ContextPressure exposes low medium high critical levels" {
    try std.testing.expectEqual(ContextPressure.Level.low, ContextPressure.fromModel(200_000, 32_000, null, 159_999).level());
    try std.testing.expectEqual(ContextPressure.Level.medium, ContextPressure.fromModel(200_000, 32_000, null, 160_000).level());
    try std.testing.expectEqual(ContextPressure.Level.high, ContextPressure.fromModel(200_000, 32_000, null, 167_000).level());
    try std.testing.expectEqual(ContextPressure.Level.critical, ContextPressure.fromModel(200_000, 32_000, null, 177_000).level());
    try std.testing.expectEqualStrings("critical", ContextPressure.Level.critical.label());
}
