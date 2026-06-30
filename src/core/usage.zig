//! UsageTotals:跨 turn 累加的 token 计数(input/output/cache)。
//!
//! L1 重构:从 app.zig 下沉到 core——usage 走 CoreEvent.usage 总线后,消费方
//! (TuiBackend / WriterBackend / JobEntry)都在 core 或 UI 层累加进一个 UsageTotals,
//! 故类型必须中立、可被 core 引用(core 不得 import app.zig,见 lib-extraction 隔离)。
//! app.usage 仍是本类型;app 只 re-export(`pub const UsageTotals = ...`)+ 提供 costUsd。

const api_stream = @import("../api/stream.zig");
const pricing = @import("../util/pricing.zig");

pub const UsageTotals = struct {
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    cache_read_input_tokens: u64 = 0,
    cache_creation_input_tokens: u64 = 0,

    pub fn apply(self: *UsageTotals, d: api_stream.UsageDelta) void {
        self.input_tokens += d.input_tokens;
        self.output_tokens += d.output_tokens;
        self.cache_read_input_tokens += d.cache_read_input_tokens;
        self.cache_creation_input_tokens += d.cache_creation_input_tokens;
    }

    pub fn costUsd(self: *const UsageTotals, model: []const u8) f64 {
        return pricing.computeCost(
            pricing.rateFor(model),
            self.input_tokens,
            self.output_tokens,
            self.cache_read_input_tokens,
            self.cache_creation_input_tokens,
        );
    }
};

test "UsageTotals.apply 累加四项" {
    const std = @import("std");
    var t = UsageTotals{};
    t.apply(.{ .input_tokens = 10, .output_tokens = 5, .cache_read_input_tokens = 2, .cache_creation_input_tokens = 1 });
    t.apply(.{ .input_tokens = 3, .output_tokens = 4 });
    try std.testing.expectEqual(@as(u64, 13), t.input_tokens);
    try std.testing.expectEqual(@as(u64, 9), t.output_tokens);
    try std.testing.expectEqual(@as(u64, 2), t.cache_read_input_tokens);
}
