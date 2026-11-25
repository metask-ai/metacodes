//! L2 component tests for goal state (issue #277).
//!
//! Covers the durable state behind /goal and AgentCore's goal table: one
//! session goal, accounting by the agent loop as provider responses arrive,
//! the budget transition, and goal.json persistence.

const std = @import("std");
const pfs = @import("platform").fs;
const harness = @import("harness");
const cc = @import("cc");

fn ensureDir(path: []const u8) !void {
    var buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    if (path.len >= buf.len) return error.PathTooLong;
    @memcpy(buf[0..path.len], path);
    buf[path.len] = 0;
    if (pfs.mkdir(@ptrCast(&buf), 0o700) != 0) {
        const e: std.c.E = @enumFromInt(std.c._errno().*);
        if (e != .EXIST) return error.MkdirFailed;
    }
}

test "L2 goal: set active goal, account tokens, cross budget, persist and reload" {
    const a = std.testing.allocator;
    var dir_buf: [512]u8 = undefined;
    const dir = cc.util_fs.testing.perPidDir(&dir_buf, "cc-zig-goal-l2");
    try ensureDir(dir);
    defer cc.util_fs.testing.rmrfBestEffort(dir);

    var state = cc.core_goal.State.init(a);
    defer state.deinit();
    try std.testing.expectError(error.InvalidBudget, state.setNew("bad budget", 0));
    try state.setNew("ship OAuth and loop", 12);
    const id = state.current.?.id;
    var meter = cc.core_goal.Meter.init(&state);
    meter.beginRun();
    _ = meter.charge(3, 2);
    try std.testing.expectEqual(@as(u64, 5), state.current.?.tokens_used);
    _ = meter.charge(4, 4);
    _ = meter.endRun();
    try std.testing.expectEqual(cc.core_goal.Status.budget_limited, state.current.?.status);
    try state.persistToDir(dir);

    var loaded = cc.core_goal.State.init(a);
    defer loaded.deinit();
    try loaded.loadFromDir(dir);
    try std.testing.expectEqualStrings("ship OAuth and loop", loaded.current.?.objective);
    try std.testing.expectEqualStrings(id[0..], loaded.current.?.id[0..]);
    try std.testing.expectEqual(@as(u64, 13), loaded.current.?.tokens_used);
    try std.testing.expectEqual(state.current.?.time_used_ms, loaded.current.?.time_used_ms);
    try std.testing.expectEqual(cc.core_goal.Status.budget_limited, loaded.current.?.status);
}

test "L2 loop: continuation gate rejects non-idle and non-active goal states" {
    const base = cc.repl_loop.LoopGateInput{
        .loop_enabled = true,
        .loop_remaining = 2,
        .queued_count = 0,
        .goal_status = .active,
        .aborted = false,
    };
    try std.testing.expect(cc.repl_loop.shouldRunLoopContinuationInput(base));

    var queued = base;
    queued.queued_count = 1;
    try std.testing.expect(!cc.repl_loop.shouldRunLoopContinuationInput(queued));

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

test "L2 goal: clear removes persisted goal file" {
    const a = std.testing.allocator;
    var dir_buf: [512]u8 = undefined;
    const dir = cc.util_fs.testing.perPidDir(&dir_buf, "cc-zig-goal-l2-clear");
    try ensureDir(dir);
    defer cc.util_fs.testing.rmrfBestEffort(dir);

    var state = cc.core_goal.State.init(a);
    defer state.deinit();
    try state.setNew("temporary", null);
    try state.persistToDir(dir);
    state.clearInMemory();
    try state.persistToDir(dir);
    try std.testing.expectError(error.NotFound, state.loadFromDir(dir));
}

/// Sums the usage the provider reported, as a Host or the TUI sees it.
const UsageProbe = struct {
    tokens: u64 = 0,

    fn backend(self: *UsageProbe) cc.ui_backend.UiBackend {
        return .{ .ctx = self, .emit = emit, .poll = poll };
    }

    fn emit(raw: *anyopaque, _: cc.session_id.SessionId, event: cc.ui_event.CoreEvent) void {
        const self: *UsageProbe = @ptrCast(@alignCast(raw));
        switch (event) {
            .usage => |u| self.tokens += u.input_tokens + u.output_tokens,
            else => {},
        }
    }

    fn poll(_: *anyopaque, _: cc.session_id.SessionId) ?cc.ui_event.UiEvent {
        return null;
    }
};

const TOOL_TURN =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"m1\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":40,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"t1\",\"name\":\"NoSuchTool\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{}\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":9}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const FINAL_TURN =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"m2\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":3,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"done\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":2}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

fn runGoalTurns(
    a: std.mem.Allocator,
    srv: *harness.MockServer,
    meter: *cc.core_goal.Meter,
    probe: *UsageProbe,
) !cc.agent_loop.StopReason {
    const url = try srv.urlOwned(a);
    defer a.free(url);
    var io_rt = @import("platform").signal.threadedIo(a, .{});
    defer io_rt.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(a, io_rt.io(), "key", "model", url);
    defer client.deinit();
    var conv = cc.conversation.Conversation.init(a);
    defer conv.deinit();
    try conv.appendText(.user, "work on the goal");
    var perm = cc.permission.createContext(.bypass_permissions, a);
    perm.no_interactive_prompt = true;
    const be = probe.backend();
    const result = try cc.agent_loop.run(&conv, client.provider(), &.{}, &perm, .{
        .max_turns = 4,
        .goal_meter = meter,
    }, &be, a);
    return result.stop_reason;
}

test "L2 goal: the agent loop charges every response to the active goal and asks once, at the next turn, to wrap up (issue #277)" {
    const a = std.testing.allocator;
    var state = cc.core_goal.State.init(a);
    defer state.deinit();
    try state.setNew("ship it", 30);
    var meter = cc.core_goal.Meter.init(&state);
    var probe = UsageProbe{};

    var srv = try harness.MockServer.startCassette(&.{ TOOL_TURN, FINAL_TURN }, 0);
    defer srv.stop();
    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, try runGoalTurns(a, srv, &meter, &probe));
    // Charged exactly what the provider reported, the turn after the budget
    // ran out included.
    try std.testing.expect(probe.tokens > 30);
    try std.testing.expectEqual(probe.tokens, state.current.?.tokens_used);
    try std.testing.expectEqual(cc.core_goal.Status.budget_limited, state.current.?.status);
    // The first request carries no notice; the second carries it once.
    const first = (srv.requestAt(0) orelse return error.MissingRequest).body();
    const second = (srv.requestAt(1) orelse return error.MissingRequest).body();
    try std.testing.expect(std.mem.indexOf(u8, first, "token budget for the active goal is used up") == null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, second, "token budget for the active goal is used up"));
}

test "L2 goal: a Run that ends in a provider error is still charged, and a paused goal is not (issue #277)" {
    const a = std.testing.allocator;
    var state = cc.core_goal.State.init(a);
    defer state.deinit();
    try state.setNew("ship it", null);
    var meter = cc.core_goal.Meter.init(&state);

    // The second request is refused: the Run ends api_error after the first
    // turn was billed.
    var probe = UsageProbe{};
    const bodies = [_][]const u8{ TOOL_TURN, "{\"type\":\"error\",\"error\":{\"type\":\"invalid_request_error\",\"message\":\"refused\"}}" };
    const statuses = [_][]const u8{ "HTTP/1.1 200 OK", "HTTP/1.1 400 Bad Request" };
    var failing = try harness.MockServer.startHttpCassette(&bodies, &statuses);
    defer failing.stop();
    try std.testing.expectEqual(cc.agent_loop.StopReason.api_error, try runGoalTurns(a, failing, &meter, &probe));
    try std.testing.expect(probe.tokens > 0);
    try std.testing.expectEqual(probe.tokens, state.current.?.tokens_used);
    const charged = state.current.?.tokens_used;

    try state.apply(.pause);
    var paused_probe = UsageProbe{};
    var final_only = try harness.MockServer.startCassette(&.{FINAL_TURN}, 0);
    defer final_only.stop();
    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, try runGoalTurns(a, final_only, &meter, &paused_probe));
    try std.testing.expect(paused_probe.tokens > 0);
    try std.testing.expectEqual(charged, state.current.?.tokens_used);
}
