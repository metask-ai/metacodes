const std = @import("std");
const cc = @import("cc");

const RUNS = 10;
const OLD_POLL_FLOOR_MS: i64 = 100;

fn dispatchBash(ctx: *const cc.tools.ToolContext, input: []const u8) !std.json.Parsed(std.json.Value) {
    var outcome = try cc.tools.dispatch(ctx, "Bash", input);
    defer outcome.deinit(ctx.allocator);
    const bytes = switch (outcome) {
        .ok => |body| switch (body) {
            .@"inline" => |result| result.bytes,
            else => return error.UnexpectedBashBody,
        },
        else => return error.UnexpectedBashOutcome,
    };
    return std.json.parseFromSlice(std.json.Value, ctx.allocator, bytes, .{ .allocate = .alloc_always });
}

test "L2 a foreground Bash command that exits at once is collected without a poll floor (#670)" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var jobs = try cc.job_registry.JobRegistry.init(allocator);
    defer jobs.deinit();
    const ctx = cc.tools.ToolContext{ .allocator = allocator, .jobs = &jobs };

    var fastest: i64 = std.math.maxInt(i64);
    for (0..RUNS) |_| {
        const started = cc.util_time.nowMs();
        var result = try dispatchBash(&ctx, "{\"command\":\"printf ok\"}");
        const took = cc.util_time.nowMs() - started;
        defer result.deinit();
        try std.testing.expectEqualStrings("ok", result.value.object.get("stdout").?.string);
        fastest = @min(fastest, took);
    }
    try std.testing.expect(fastest < OLD_POLL_FLOOR_MS);
}

const Aborter = struct {
    fn run(abort: *cc.util_abort.AbortSignal) void {
        cc.util_time.sleepMs(300);
        abort.abort(.user_interrupt);
    }
};

test "L2 a foreground Bash wait still answers an abort within one poll slice (#670)" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var jobs = try cc.job_registry.JobRegistry.init(allocator);
    defer jobs.deinit();
    var abort = cc.util_abort.AbortSignal.init();
    const ctx = cc.tools.ToolContext{ .allocator = allocator, .jobs = &jobs, .abort = &abort };

    const started = cc.util_time.nowMs();
    const aborter = try std.Thread.spawn(.{}, Aborter.run, .{&abort});
    var outcome = cc.tools.dispatch(&ctx, "Bash", "{\"command\":\"sleep 30\"}");
    aborter.join();
    const took = cc.util_time.nowMs() - started;
    if (outcome) |*o| o.deinit(allocator) else |_| {}
    try std.testing.expect(took < 10_000);
    try std.testing.expectEqual(@as(usize, 0), jobs.runningCount());
}
