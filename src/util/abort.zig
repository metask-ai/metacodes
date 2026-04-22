//! AbortSignal：跨线程的原子中断标志。
//!
//! 设计目标：
//! - 同步触发：任何线程（含 signal handler）都可 `abort(reason)`
//! - 非阻塞检查：`isAborted()` 只是一次 atomic load，适合在循环里高频调用
//! - 可诊断：`reason()` 返回触发原因便于日志/错误消息
//!
//! 不提供跨线程 wait/wake —— 这是 SIGINT handler 场景，HTTP read 通过
//! `SO_RCVTIMEO=100ms` 的轮询模式检查 abort（M1.4 落地）。
//!
//! signal handler 兼容：`abort()` 只做 `@atomicStore` + enum store，不分配、不打印、
//! 不获锁——async-signal-safe。

const std = @import("std");

pub const Reason = enum(u8) {
    not_aborted = 0,
    user_ctrl_c = 1,
    timeout = 2,
    max_turns = 3,
    api_error = 4,
};

pub const AbortSignal = struct {
    flag: std.atomic.Value(bool),
    reason_value: std.atomic.Value(u8),

    pub fn init() AbortSignal {
        return .{
            .flag = std.atomic.Value(bool).init(false),
            .reason_value = std.atomic.Value(u8).init(@intFromEnum(Reason.not_aborted)),
        };
    }

    /// 触发中断。设置 flag 前先写 reason（release 语序）——观察线程先看到 flag 再读 reason
    /// 时能拿到一致值。多次调用保留首次 reason（.monotonic 级别，不强保证）。
    ///
    /// Signal-safe：仅 atomic store，无分配、无锁、无 IO。
    pub fn abort(self: *AbortSignal, reason_: Reason) void {
        // cmpxchg 确保只有首个 abort 写入 reason（幂等）
        _ = self.reason_value.cmpxchgStrong(
            @intFromEnum(Reason.not_aborted),
            @intFromEnum(reason_),
            .release,
            .monotonic,
        );
        self.flag.store(true, .release);
    }

    /// 非阻塞检查。用 .acquire 配对 abort 的 .release。
    pub fn isAborted(self: *const AbortSignal) bool {
        return self.flag.load(.acquire);
    }

    /// 返回触发原因，未触发返回 .not_aborted。
    pub fn reason(self: *const AbortSignal) Reason {
        return @enumFromInt(self.reason_value.load(.acquire));
    }

    /// 便利：若已中断，返回 error.Aborted。用于循环体开头的检查点。
    pub fn throwIfAborted(self: *const AbortSignal) error{Aborted}!void {
        if (self.isAborted()) return error.Aborted;
    }

    /// 仅测试用：重置为未触发。生产代码不应调用（abort 应是单向的）。
    pub fn resetForTesting(self: *AbortSignal) void {
        self.reason_value.store(@intFromEnum(Reason.not_aborted), .release);
        self.flag.store(false, .release);
    }
};

// --------------------------------------------------------------------------
// Tests
// --------------------------------------------------------------------------

test "init: not aborted, reason = not_aborted" {
    const s = AbortSignal.init();
    try std.testing.expect(!s.isAborted());
    try std.testing.expect(s.reason() == .not_aborted);
}

test "abort sets flag and reason" {
    var s = AbortSignal.init();
    s.abort(.user_ctrl_c);
    try std.testing.expect(s.isAborted());
    try std.testing.expect(s.reason() == .user_ctrl_c);
}

test "second abort does not overwrite reason" {
    var s = AbortSignal.init();
    s.abort(.timeout);
    s.abort(.user_ctrl_c);
    try std.testing.expect(s.reason() == .timeout);
}

test "throwIfAborted returns void when clean" {
    const s = AbortSignal.init();
    try s.throwIfAborted();
}

test "throwIfAborted returns error when aborted" {
    var s = AbortSignal.init();
    s.abort(.max_turns);
    try std.testing.expectError(error.Aborted, s.throwIfAborted());
}

test "resetForTesting clears state" {
    var s = AbortSignal.init();
    s.abort(.api_error);
    s.resetForTesting();
    try std.testing.expect(!s.isAborted());
    try std.testing.expect(s.reason() == .not_aborted);
}

test "cross-thread: worker observes flag set by main" {
    var s = AbortSignal.init();

    const Worker = struct {
        fn run(sig: *AbortSignal, stopped: *std.atomic.Value(bool)) void {
            // 忙等最多 ~1 秒
            var i: usize = 0;
            while (i < 10_000_000) : (i += 1) {
                if (sig.isAborted()) {
                    stopped.store(true, .release);
                    return;
                }
            }
            stopped.store(false, .release);
        }
    };

    var stopped = std.atomic.Value(bool).init(false);
    const t = try std.Thread.spawn(.{}, Worker.run, .{ &s, &stopped });
    // 让 worker 先跑起来
    std.Thread.yield() catch {};
    s.abort(.user_ctrl_c);
    t.join();

    try std.testing.expect(stopped.load(.acquire));
    try std.testing.expect(s.reason() == .user_ctrl_c);
}

test "all reasons round-trip" {
    inline for (.{ .user_ctrl_c, .timeout, .max_turns, .api_error }) |r| {
        var s = AbortSignal.init();
        s.abort(r);
        try std.testing.expect(s.reason() == r);
    }
}
