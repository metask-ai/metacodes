//! L2 component tests for /goal backing state.
//!
//! Covers the durable state that the slash command uses: one session goal,
//! version-guarded accounting, budget transition, and goal.json persistence.

const std = @import("std");
const cc = @import("cc");

fn ensureDir(path: []const u8) !void {
    var buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (path.len >= buf.len) return error.PathTooLong;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    if (std.c.mkdir(@ptrCast(&buf), 0o700) != 0) {
        const e: std.c.E = @enumFromInt(std.c._errno().*);
        if (e != .EXIST) return error.MkdirFailed;
    }
}

test "L2 goal: set active goal, account tokens, cross budget, persist and reload" {
    const a = std.testing.allocator;
    const dir = "/tmp/cc-zig-goal-l2";
    try ensureDir(dir);

    var state = cc.core_goal.State.init(a);
    defer state.deinit();
    try std.testing.expectError(error.InvalidBudget, state.setNew("bad budget", 0));
    try state.setNew("ship OAuth and loop", 12);
    const id = state.current.?.id;
    try state.accountProgress(5, 125, id[0..]);
    try std.testing.expectEqual(@as(u64, 5), state.current.?.tokens_used);
    try std.testing.expectEqual(@as(u64, 125), state.current.?.time_used_ms);
    try state.accountTokens(8, id[0..]);
    try std.testing.expectEqual(cc.core_goal.Status.budget_limited, state.current.?.status);
    try state.persistToDir(dir);

    var loaded = cc.core_goal.State.init(a);
    defer loaded.deinit();
    try loaded.loadFromDir(dir);
    try std.testing.expectEqualStrings("ship OAuth and loop", loaded.current.?.objective);
    try std.testing.expectEqualStrings(id[0..], loaded.current.?.id[0..]);
    try std.testing.expectEqual(@as(u64, 13), loaded.current.?.tokens_used);
    try std.testing.expectEqual(@as(u64, 125), loaded.current.?.time_used_ms);
    try std.testing.expectEqual(cc.core_goal.Status.budget_limited, loaded.current.?.status);
}

test "L2 loop: continuation gate rejects non-idle and non-active goal states" {
    const base = cc.repl_loop.LoopGateInput{
        .loop_enabled = true,
        .loop_remaining = 2,
        .queued_count = 0,
        .goal_status = .active,
        .permission_mode = .default,
        .aborted = false,
    };
    try std.testing.expect(cc.repl_loop.shouldRunLoopContinuationInput(base));

    var queued = base;
    queued.queued_count = 1;
    try std.testing.expect(!cc.repl_loop.shouldRunLoopContinuationInput(queued));

    var plan = base;
    plan.permission_mode = .plan;
    try std.testing.expect(!cc.repl_loop.shouldRunLoopContinuationInput(plan));

    var paused = base;
    paused.goal_status = .paused;
    try std.testing.expect(!cc.repl_loop.shouldRunLoopContinuationInput(paused));

    var complete = base;
    complete.goal_status = .complete;
    try std.testing.expect(!cc.repl_loop.shouldRunLoopContinuationInput(complete));

    var exhausted = base;
    exhausted.loop_remaining = 0;
    try std.testing.expect(!cc.repl_loop.shouldRunLoopContinuationInput(exhausted));
}

test "L2 goal: stale goal id accounting is a no-op" {
    const a = std.testing.allocator;
    var state = cc.core_goal.State.init(a);
    defer state.deinit();
    try state.setNew("first", null);
    const old = state.current.?.id;
    try state.setNew("replacement", null);
    try state.accountProgress(99, 5000, old[0..]);
    try std.testing.expectEqual(@as(u64, 0), state.current.?.tokens_used);
    try std.testing.expectEqual(@as(u64, 0), state.current.?.time_used_ms);
    try state.accountProgress(3, 7, state.current.?.id[0..]);
    try std.testing.expectEqual(@as(u64, 3), state.current.?.tokens_used);
    try std.testing.expectEqual(@as(u64, 7), state.current.?.time_used_ms);
}

test "L2 goal: clear removes persisted goal file" {
    const a = std.testing.allocator;
    const dir = "/tmp/cc-zig-goal-l2-clear";
    try ensureDir(dir);

    var state = cc.core_goal.State.init(a);
    defer state.deinit();
    try state.setNew("temporary", null);
    try state.persistToDir(dir);
    state.clearInMemory();
    try state.persistToDir(dir);
    try std.testing.expectError(error.NotFound, state.loadFromDir(dir));
}
