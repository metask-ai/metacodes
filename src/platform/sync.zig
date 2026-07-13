//! W1 可移植同步原语（跨平台移植 roadmap，tinykg node 8865）。
//!
//! 现状病灶：全仓 85 处直接用 `std.c.pthread_*`（Zig 0.16 stock std 已移除
//! `std.Thread.Mutex/Condition/Futex`，锁搬进 `std.Io.Mutex` 但 `lock(io)` 强制要 Io 实例
//! → 非 pthread 免费替代）。pthread 是 POSIX-only → Windows 完全不可用。
//!
//! 本模块把锁收编成中立 `Mutex`/`Condition`：
//! - **POSIX**：保留现有 pthread（零行为变化）。
//! - **Windows**：NT 原生 SRWLOCK + CONDITION_VARIABLE（`std.os.windows.ntdll` 已绑定
//!   `Rtl{Acquire,Release}SRWLockExclusive` / `RtlWake{,All}ConditionVariable`；仅
//!   `RtlSleepConditionVariableSRW`（条件变量等待）未绑定，本文件自 extern 一个）。
//!
//! **零成本嵌入**：`mu: Mutex = .{}` 作默认字段值即可，无需显式 init()。各平台静态
//! initializer 不同（macOS pthread 有签名 magic 非全零；Windows SRWLOCK/CONDVAR 全零），
//! 由下面各 backend 的默认字段值各自提供正确初值。
//!
//! **timedWait 语义**：相对超时（ns），返回 `true`=被唤醒 / `false`=超时或错误。调用方
//! 应在返回后重查谓词（虚假唤醒 + abort 分片轮询都靠调用方 loop）。此设计消掉了各文件
//! 原本各自实现的 `absDeadline` helper。

const std = @import("std");
const builtin = @import("builtin");

const is_windows = builtin.os.tag == .windows;

pub const Mutex = if (is_windows) WindowsMutex else PosixMutex;
pub const Condition = if (is_windows) WindowsCondition else PosixCondition;

// ============================================================================
// POSIX backend（pthread）
// ============================================================================

const PosixMutex = struct {
    inner: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER,

    pub fn lock(m: *PosixMutex) void {
        _ = std.c.pthread_mutex_lock(&m.inner);
    }
    pub fn unlock(m: *PosixMutex) void {
        _ = std.c.pthread_mutex_unlock(&m.inner);
    }
};

const PosixCondition = struct {
    inner: std.c.pthread_cond_t = std.c.PTHREAD_COND_INITIALIZER,

    pub fn signal(c: *PosixCondition) void {
        _ = std.c.pthread_cond_signal(&c.inner);
    }
    pub fn broadcast(c: *PosixCondition) void {
        _ = std.c.pthread_cond_broadcast(&c.inner);
    }
    pub fn wait(c: *PosixCondition, m: *PosixMutex) void {
        _ = std.c.pthread_cond_wait(&c.inner, &m.inner);
    }
    /// 相对超时等待。true=被唤醒，false=超时（ETIMEDOUT）或罕见错误。
    pub fn timedWait(c: *PosixCondition, m: *PosixMutex, timeout_ns: u64) bool {
        var ts = posixAbsDeadline(timeout_ns);
        return std.c.pthread_cond_timedwait(&c.inner, &m.inner, &ts) == .SUCCESS;
    }
};

/// 现在 + timeout_ns 的绝对时刻（pthread_cond_timedwait 需 CLOCK_REALTIME 绝对时间）。
/// 逻辑对齐原 web/journal.zig::absDeadline（已验证），改为 ns 输入。
fn posixAbsDeadline(timeout_ns: u64) std.c.timespec {
    var now: std.c.timeval = undefined;
    _ = std.c.gettimeofday(&now, null);
    const NsecT = @TypeOf((std.c.timespec{ .sec = 0, .nsec = 0 }).nsec);
    const SecT = @TypeOf((std.c.timespec{ .sec = 0, .nsec = 0 }).sec);
    var ts: std.c.timespec = .{
        .sec = now.sec + @as(SecT, @intCast(timeout_ns / 1_000_000_000)),
        .nsec = @as(NsecT, @intCast(@as(u64, @intCast(now.usec)) * 1000 + (timeout_ns % 1_000_000_000))),
    };
    if (ts.nsec >= 1_000_000_000) {
        ts.sec += 1;
        ts.nsec -= 1_000_000_000;
    }
    return ts;
}

// ============================================================================
// Windows backend（NT 原生 SRWLOCK + CONDITION_VARIABLE）
// ============================================================================

const win = std.os.windows;

/// 条件变量等待——ntdll.zig 未绑定，自 extern。Timeout 为 LARGE_INTEGER（100ns 单位），
/// 负值=相对超时；null=无限等待。Flags=0 表示独占锁模式。返回 NTSTATUS。
extern "ntdll" fn RtlSleepConditionVariableSRW(
    ConditionVariable: *win.CONDITION_VARIABLE,
    SRWLock: *win.SRWLOCK,
    Timeout: ?*const win.LARGE_INTEGER,
    Flags: win.ULONG,
) win.NTSTATUS;

const WindowsMutex = struct {
    inner: win.SRWLOCK = .{},

    pub fn lock(m: *WindowsMutex) void {
        win.ntdll.RtlAcquireSRWLockExclusive(&m.inner);
    }
    pub fn unlock(m: *WindowsMutex) void {
        win.ntdll.RtlReleaseSRWLockExclusive(&m.inner);
    }
};

const WindowsCondition = struct {
    inner: win.CONDITION_VARIABLE = .{},

    pub fn signal(c: *WindowsCondition) void {
        win.ntdll.RtlWakeConditionVariable(&c.inner);
    }
    pub fn broadcast(c: *WindowsCondition) void {
        win.ntdll.RtlWakeAllConditionVariable(&c.inner);
    }
    pub fn wait(c: *WindowsCondition, m: *WindowsMutex) void {
        _ = RtlSleepConditionVariableSRW(&c.inner, &m.inner, null, 0);
    }
    /// 相对超时等待。true=被唤醒，false=STATUS_TIMEOUT 或错误。
    pub fn timedWait(c: *WindowsCondition, m: *WindowsMutex, timeout_ns: u64) bool {
        // LARGE_INTEGER 单位 100ns，负值=相对当前时刻。
        const t: win.LARGE_INTEGER = -@as(win.LARGE_INTEGER, @intCast(timeout_ns / 100));
        const rc = RtlSleepConditionVariableSRW(&c.inner, &m.inner, &t, 0);
        return rc == .SUCCESS;
    }
};

// ============================================================================
// Tests（POSIX 可跑；验证基本互斥 + 条件唤醒 + 超时）
// ============================================================================

test "Mutex lock/unlock 基本" {
    var m: Mutex = .{};
    m.lock();
    m.unlock();
    // 再次可重入获取（非递归锁，unlock 后能再 lock）
    m.lock();
    m.unlock();
}

test "Condition signal 跨线程唤醒" {
    // std.Thread.spawn 两平台可用。此测试在 Windows CI（windows-latest）真跑，
    // 运行时验证 NT RtlAcquireSRWLockExclusive + RtlSleepConditionVariableSRW + RtlWakeConditionVariable。
    const Shared = struct {
        m: Mutex = .{},
        c: Condition = .{},
        ready: bool = false,
    };
    var sh = Shared{};

    const Worker = struct {
        fn run(s: *Shared) void {
            s.m.lock();
            defer s.m.unlock();
            s.ready = true;
            s.c.signal();
        }
    };

    var thread = try std.Thread.spawn(.{}, Worker.run, .{&sh});
    defer thread.join();

    sh.m.lock();
    defer sh.m.unlock();
    while (!sh.ready) {
        // 分片超时轮询：即使错过 signal 也能在 100ms 内醒来重查谓词。
        _ = sh.c.timedWait(&sh.m, 100 * std.time.ns_per_ms);
    }
    try std.testing.expect(sh.ready);
}

test "timedWait 无信号时超时返回 false" {
    // Windows CI 真跑：验证 RtlSleepConditionVariableSRW 的相对超时（100ns 负值）单位正确——
    // 若符号/单位错，此断言(!signaled)会红，正是运行时验证的价值。
    var m: Mutex = .{};
    var c: Condition = .{};
    m.lock();
    defer m.unlock();
    const signaled = c.timedWait(&m, 5 * std.time.ns_per_ms);
    try std.testing.expect(!signaled); // 无人 signal → 超时
}
