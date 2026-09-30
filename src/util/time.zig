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
//!   - `sleepAtLeast()`：`std.Io` 上睡满一个时长才返回（截止任务用）
//!
//! 调用方一律 `util/time.zig` 导入；禁止再抄新的 `fn nowMs`。

const std = @import("std");
const builtin = @import("builtin");
const is_windows = builtin.os.tag == .windows;
const win = std.os.windows;

pub const Millis = i64;
pub const Nanos = i128;

// Windows 无 POSIX clock_gettime(std.c 里 clockid_t=void 连编译都过不了)。手 extern kernel32:
// 单调走 QueryPerformanceCounter/Frequency;墙钟走 GetSystemTimeAsFileTime(100ns since 1601)。
const winclock = struct {
    extern "kernel32" fn QueryPerformanceCounter(lpPerformanceCount: *i64) callconv(.winapi) c_int;
    extern "kernel32" fn QueryPerformanceFrequency(lpFrequency: *i64) callconv(.winapi) c_int;
    extern "kernel32" fn GetSystemTimeAsFileTime(lpSystemTimeAsFileTime: *[2]u32) callconv(.winapi) void;
    extern "kernel32" fn Sleep(dwMilliseconds: u32) callconv(.winapi) void;
    // FILETIME(1601)→unix(1970) 差:11644473600 秒 = 116444736000000000 个 100ns tick。
    const EPOCH_DIFF_100NS: i128 = 116_444_736_000_000_000;
};

/// 单调纳秒(原始)。POSIX CLOCK_MONOTONIC / Windows QPC。失败返 0。
fn monotonicRawNs() Nanos {
    if (is_windows) {
        var freq: i64 = 0;
        var cnt: i64 = 0;
        if (winclock.QueryPerformanceFrequency(&freq) == 0 or freq == 0) return 0;
        if (winclock.QueryPerformanceCounter(&cnt) == 0) return 0;
        // cnt/freq 秒 → 纳秒,先乘后除保精度(cnt*1e9 可能溢 i64,用 i128)。
        return @divTrunc(@as(Nanos, cnt) * std.time.ns_per_s, @as(Nanos, freq));
    }
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts) != 0) return 0;
    return @as(Nanos, @intCast(ts.sec)) * std.time.ns_per_s + @as(Nanos, @intCast(ts.nsec));
}

/// 墙钟纳秒(unix epoch)。POSIX CLOCK_REALTIME / Windows FILETIME。失败返 0。
fn wallRawNs() Nanos {
    if (is_windows) {
        var ft: [2]u32 = .{ 0, 0 };
        winclock.GetSystemTimeAsFileTime(&ft);
        const ticks100ns: i128 = (@as(i128, ft[1]) << 32) | @as(i128, ft[0]);
        return (ticks100ns - winclock.EPOCH_DIFF_100NS) * 100;
    }
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts) != 0) return 0;
    return @as(Nanos, @intCast(ts.sec)) * std.time.ns_per_s + @as(Nanos, @intCast(ts.nsec));
}

pub fn nowMs() Millis {
    return @intCast(@divTrunc(monotonicRawNs(), 1_000_000));
}

pub fn nowNs() Nanos {
    return monotonicRawNs();
}

pub fn nowWallNs() Nanos {
    return wallRawNs();
}

/// REALTIME 秒(unix epoch)。Cron 调度用。
pub fn nowUnix() i64 {
    return @intCast(@divTrunc(wallRawNs(), std.time.ns_per_s));
}

/// 可移植睡眠(毫秒)。POSIX nanosleep / Windows Sleep。收编全仓散落的
/// `var req/rem: timespec; std.c.nanosleep(...)` 样板。
pub fn sleepMs(ms: u64) void {
    if (is_windows) {
        winclock.Sleep(@intCast(ms));
        return;
    }
    var req: std.c.timespec = .{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * 1_000_000) };
    var rem: std.c.timespec = undefined;
    _ = std.c.nanosleep(&req, &rem);
}

/// 等 `duration` 在它的时钟上真正走完才返回,每次等待都是取消点。与请求竞速的截止任务都走这里。
/// 单次 sleep 不保证这个下界:Windows 上 `std.Io.Threaded` 把 awake 时钟的等待(连 `.deadline`
/// 在内)都换算成相对的 NT 等待,内核在时钟中断 tick 上服务,可能早醒最多一个 tick(默认
/// 15.625 ms)。所以先定下绝对截止,早醒了就补睡剩余时长。
pub fn sleepAtLeast(io: std.Io, duration: std.Io.Clock.Duration) std.Io.Cancelable!void {
    const deadline: std.Io.Clock.Timestamp = .fromNow(io, duration);
    while (std.Io.Clock.Timestamp.now(io, deadline.clock).compare(.lt, deadline)) {
        try deadline.wait(io);
    }
}

const TickServicedClock = @import("platform").test_support.TickServicedClock;

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

test "sleepAtLeast outlasts a sleep that wakes up to one timer tick early" {
    // tick 内 15 ms 处开始:单次 300 ms 的等待到期于 300 ms,在 312.5 ms 的 tick 上醒来,只过了 297.5 ms。
    var clock: TickServicedClock = .{ .now_ns = 15 * std.time.ns_per_ms };
    const started = clock.now_ns;
    try sleepAtLeast(clock.io(), .{ .raw = .fromMilliseconds(300), .clock = .awake });
    try std.testing.expect(clock.now_ns - started >= 300 * std.time.ns_per_ms);
    // 第一次确实早醒了,第二次补齐。
    try std.testing.expectEqual(@as(u32, 2), clock.sleeps);
}

test "a canceled sleepAtLeast returns at the first wait" {
    var clock: TickServicedClock = .{ .now_ns = 0, .cancel_requested = true };
    try std.testing.expectError(error.Canceled, sleepAtLeast(clock.io(), .{ .raw = .fromMilliseconds(300), .clock = .awake }));
    try std.testing.expectEqual(@as(u32, 1), clock.sleeps);
}
