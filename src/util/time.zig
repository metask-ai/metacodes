//! 时钟工具：单一事实源，统一类型。
//!
//! 之前散在 common.zig / bash.zig / read_state.zig / transcript.zig / agent_loop.zig / job_registry.zig
//! 六处独立 `nowMs()` 函数，返回类型有 i64 和 u64，混用导致隐式转换。
//! 这里统一：
//!   - `Millis`：毫秒时间戳类型（i64，匹配 POSIX `ts.sec * 1000`）
//!   - `Nanos`：纳秒时间戳类型（i128，足够表达 sec * 1e9 + nsec）
//!   - `nowMs()`：MONOTONIC 毫秒；失败返 0（保持老语义）
//!   - `nowNs()`：MONOTONIC 纳秒
//!   - `nowWallNs()`：REALTIME 纳秒（transcript last_modified_ns 用）
//!
//! 调用方一律 `util/time.zig` 导入；禁止再抄新的 `fn nowMs`。

const std = @import("std");

pub const Millis = i64;
pub const Nanos = i128;

pub fn nowMs() Millis {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts) != 0) return 0;
    return @as(Millis, @intCast(ts.sec)) * 1000 + @divTrunc(@as(Millis, @intCast(ts.nsec)), 1_000_000);
}

pub fn nowNs() Nanos {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts) != 0) return 0;
    const sec: Nanos = @intCast(ts.sec);
    const nsec: Nanos = @intCast(ts.nsec);
    return sec * std.time.ns_per_s + nsec;
}

pub fn nowWallNs() Nanos {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts) != 0) return 0;
    const sec: Nanos = @intCast(ts.sec);
    const nsec: Nanos = @intCast(ts.nsec);
    return sec * std.time.ns_per_s + nsec;
}

test "nowMs is monotonic and positive" {
    const a = nowMs();
    const b = nowMs();
    try std.testing.expect(a > 0);
    try std.testing.expect(b >= a);
}

test "nowNs is monotonic and positive" {
    const a = nowNs();
    const b = nowNs();
    try std.testing.expect(a > 0);
    try std.testing.expect(b >= a);
}

test "nowWallNs is positive" {
    try std.testing.expect(nowWallNs() > 0);
}
