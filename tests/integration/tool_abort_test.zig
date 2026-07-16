//! 集成测试：Bash tool + AbortSignal 端到端验证。
//!
//! 证明 M2.1 的 ToolContext.abort 真的从 ctx → spawnCaptureStdoutAbortable → killGroup
//! 整条链路工作。

const std = @import("std");
const cc = @import("cc");

test "Bash tool aborts sleep within 3s" {
    const a = std.testing.allocator;
    var sig = cc.util_abort.AbortSignal.init();
    const ctx = cc.tools.ToolContext{ .allocator = a, .abort = &sig };

    // 200ms 后触发 abort
    const trigger = try std.Thread.spawn(.{}, struct {
        fn run(s: *cc.util_abort.AbortSignal) void {
            cc.util_time.sleepMs(200);
            s.abort(.user_ctrl_c);
        }
    }.run, .{&sig});

    const t0 = nowMs();
    const result = cc.bash.execute(&ctx, "{\"command\":\"sleep 10\"}");
    trigger.join();
    const dt = nowMs() - t0;

    try std.testing.expectError(error.Aborted, result);
    // killGroup 含 2s SIGTERM 等待期，总耗时 < 3s（而不是 sleep 10）
    try std.testing.expect(dt < 3500);
}

fn nowMs() i64 {
    // 测的是"几秒量级的耗时上界",wall clock 足够;std.c.clock_gettime 在 Windows 编不过。
    return cc.util_time.nowMs();
}
