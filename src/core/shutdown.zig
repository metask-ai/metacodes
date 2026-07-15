//! **进程级停机信号(U9)** —— 与"单 session run 中断"彻底解耦。
//!
//! 背景:此前 SIGINT 只 `g_abort_signal.abort(.user_ctrl_c)`(app.zig),单指针指向**一个** session
//! 的 run-abort。对 TUI/web/headless(N=1)正确;但 daemon(U10)一个进程宿主 N 个 session 时,
//! SIGINT 语义应是**关停整个进程**(优雅关所有 session),而非中断某一个 session 的 run。
//!
//! 两个被混同的概念在此拆开:
//!   · **进程关停(process shutdown)** = SIGINT / daemon stop → 本模块的 `request()`。进程全局
//!     单一 flag(SIGINT 本就进程级,这不是缺陷)。宿主主循环 poll `requested()` 决定优雅退出。
//!   · **单 session run 中断(run abort)** = 某 session 的 Stop → 走**协议**(web POST /interrupt →
//!     该 session `app.abort.abort(.user_interrupt)`)。永不走进程信号。N 个 session 各自 Stop 互不影响。
//!
//! **async-signal-safe**:SIGINT handler 只能 atomic store(不分配/不锁/不 IO/不遍历列表)。故本模块
//! 只提供一个原子 flag;"通知所有 session 关停"的遍历放到**正常线程上下文**(daemon 主循环 poll 到
//! flag 后,加锁遍历 registry 逐个 abort+join)。SIGINT handler 另戳 `g_abort_signal`(app.zig)唤醒
//! 阻塞中的宿主(N=1 宿主的 run;daemon 的 accept 被 EINTR 打断亦可醒)。

const std = @import("std");

/// 进程级停机 flag。SIGINT handler / daemon stop 置位;宿主主循环 poll。
var g_requested = std.atomic.Value(bool).init(false);

/// 请求进程停机。**async-signal-safe**(仅 atomic store)——可在 SIGINT handler 调。
pub fn request() void {
    g_requested.store(true, .seq_cst);
}

/// 是否已请求停机(宿主主循环 poll)。
pub fn requested() bool {
    return g_requested.load(.seq_cst);
}

/// 复位(测试用;生产进程一旦请求停机即走向退出,不复位)。
pub fn resetForTesting() void {
    g_requested.store(false, .seq_cst);
}

test "shutdown flag: request/requested/reset" {
    resetForTesting();
    try std.testing.expect(!requested());
    request();
    try std.testing.expect(requested());
    resetForTesting();
    try std.testing.expect(!requested());
}
