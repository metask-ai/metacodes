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
const util_time = @import("time.zig");

pub const Reason = enum(u8) {
    not_aborted = 0,
    user_ctrl_c = 1,
    timeout = 2,
    max_turns = 3,
    api_error = 4,
    /// 中断当前 run 但**不退出进程**:web /interrupt(浏览器 Stop)、GUI 停某会话。
    /// 与 user_ctrl_c(进程级 SIGINT,退出)区分——两者都中断 agent_loop,但宿主对
    /// "run 结束后是否继续 REPL"的决策相反。见 web/session.zig handleAbortAfterRun。
    user_interrupt = 5,
    /// Host-side infrastructure/callback failure. This must not be reported as
    /// a user cancellation by binary-library consumers.
    host_failure = 6,
    /// Evaluation-only metered budget guard. The process must terminate the
    /// scored rollout instead of resetting this signal and accepting another
    /// user submission.
    evaluation_budget = 7,
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
            // 按时间而不是按迭代次数忙等:10M 次原子读只有几十毫秒,主线程在满载的
            // 3 核托管 runner 上被调度出去更久就会让 worker 先放弃(CI 实测 flake)。
            // 上限 10 秒只决定"真坏了"时多久报错,正常路径几微秒就结束。
            const deadline = util_time.nowMs() + 10 * std.time.ms_per_s;
            while (util_time.nowMs() < deadline) {
                if (sig.isAborted()) {
                    stopped.store(true, .release);
                    return;
                }
                std.Thread.yield() catch {};
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
    inline for (.{ .user_ctrl_c, .timeout, .max_turns, .api_error, .user_interrupt, .host_failure, .evaluation_budget }) |r| {
        var s = AbortSignal.init();
        s.abort(r);
        try std.testing.expect(s.reason() == r);
    }
}

test "per-session 隔离:两个独立 AbortSignal,abort 一个不影响另一个" {
    // 多 Session 核心保证:每 App(session)持自己的 abort 字段。GUI 经 App.requestStop()
    // 停某会话 → 只置该会话的 abort,别的会话照跑。这里直接验两个 AbortSignal 互不干扰。
    var a = AbortSignal.init();
    var b = AbortSignal.init();
    a.abort(.user_ctrl_c);
    try std.testing.expect(a.isAborted());
    try std.testing.expect(!b.isAborted()); // 关键:停 a 不波及 b
    b.abort(.timeout);
    try std.testing.expect(b.reason() == .timeout);
    try std.testing.expect(a.reason() == .user_ctrl_c); // a 的 reason 不被 b 覆盖
}
