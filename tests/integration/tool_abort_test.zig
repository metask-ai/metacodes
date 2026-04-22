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
            const req = std.c.timespec{ .sec = 0, .nsec = 200 * 1000 * 1000 };
            var rem: std.c.timespec = undefined;
            _ = std.c.nanosleep(&req, &rem);
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
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), 1_000_000);
}
