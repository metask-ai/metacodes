//! L2 component coverage for harness-to-conversation background exit delivery
//! (turn-boundary drain) and the in-core end-of-turn wait (2026-09-19 polling
//! incident: the model had exactly one input channel and could only discover a
//! finished job by polling BashOutput once per API round trip).

const std = @import("std");
const cc = @import("cc");

/// One scripted provider response: a single tool_use, or a text end_turn.
const Step = union(enum) {
    tool_use: struct { id: []const u8, input: []const u8 },
    text: []const u8,
};

const FakeStream = struct {
    allocator: std.mem.Allocator,
    step: Step,
    stage: u8 = 0,
    rid: cc.util_log.RequestId,

    fn next(ctx: *anyopaque) anyerror!?cc.api_stream.StreamEvent {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        if (self.stage == 0) {
            self.stage = 1;
            return switch (self.step) {
                .tool_use => |tu| .{ .tool_use_start = .{
                    .id = try self.allocator.dupe(u8, tu.id),
                    .name = try self.allocator.dupe(u8, "Bash"),
                    .input_json = try self.allocator.dupe(u8, tu.input),
                } },
                .text => |t| .{ .text = try self.allocator.dupe(u8, t) },
            };
        }
        if (self.stage == 1) {
            self.stage = 2;
            return .{ .done = {} };
        }
        return null;
    }
    fn deinit(_: *anyopaque) void {}
    fn stop(ctx: *anyopaque) cc.api_stream.StopReason {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        return switch (self.step) {
            .tool_use => .tool_use,
            .text => .end_turn,
        };
    }
    fn requestId(ctx: *anyopaque) cc.util_log.RequestId {
        return @as(*@This(), @ptrCast(@alignCast(ctx))).rid;
    }
};

/// Scripted provider. Records, per send, whether the request carried a user
/// text block with a `<task-notification>` (the delivered channel), so tests
/// assert the wire, not only the persisted conversation.
const FakeProvider = struct {
    allocator: std.mem.Allocator,
    script: []const Step,
    sends: u8 = 0,
    streams: [8]FakeStream = undefined,
    /// Index of the first send whose request carried a notification; null = never.
    notification_send_index: ?u8 = null,
    notification_job_id: [12]u8 = "000000000000".*,

    fn model(_: *anyopaque) []const u8 {
        return "fake";
    }
    fn sendStreamRetry(ctx: *anyopaque, messages: []const cc.types_mod.ApiMessage, _: ?[]const u8, _: ?[]const cc.json_mod.ToolDefinition, _: ?*const cc.util_abort.AbortSignal, _: ?[]const u8, _: ?cc.json_mod.ToolChoice, _: u32, _: u64, _: ?cc.api_provider.RetryReporter, _: []const u8) anyerror!cc.api_provider.StreamHandle {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        if (self.sends >= self.script.len or self.sends >= self.streams.len) return error.UnexpectedTestCall;
        const index = self.sends;
        self.sends += 1;
        // The job id lives in the Bash tool_result already in the conversation.
        var job_id: ?[]const u8 = null;
        for (messages) |message| {
            if (message.role != .user) continue;
            for (message.content) |content| switch (content) {
                .tool_result => |result| {
                    const marker = "\"job_id\":\"";
                    if (std.mem.indexOf(u8, result.content, marker)) |at| {
                        const start = at + marker.len;
                        if (start + 12 <= result.content.len) job_id = result.content[start .. start + 12];
                    }
                },
                else => {},
            };
        }
        for (messages) |message| {
            if (message.role != .user) continue;
            for (message.content) |content| switch (content) {
                .text => |text| {
                    if (std.mem.indexOf(u8, text, "<task-notification>") != null) {
                        if (self.notification_send_index == null) self.notification_send_index = index;
                        if (job_id) |id| if (std.mem.indexOf(u8, text, id) != null) {
                            @memcpy(&self.notification_job_id, id);
                        };
                    }
                },
                else => {},
            };
        }
        self.streams[index] = .{ .allocator = self.allocator, .step = self.script[index], .rid = cc.util_log.genRequestId() };
        return .{ .ctx = @ptrCast(&self.streams[index]), .nextFn = FakeStream.next, .deinitFn = FakeStream.deinit, .stopReasonFn = FakeStream.stop, .requestIdFn = FakeStream.requestId };
    }
    fn sendStream(ctx: *anyopaque, messages: []const cc.types_mod.ApiMessage, system: ?[]const u8, tools: ?[]const cc.json_mod.ToolDefinition, abort: ?*const cc.util_abort.AbortSignal, model_override: ?[]const u8, choice: ?cc.json_mod.ToolChoice, query: []const u8) anyerror!cc.api_provider.StreamHandle {
        return sendStreamRetry(ctx, messages, system, tools, abort, model_override, choice, 0, 0, null, query);
    }
    fn send(_: *anyopaque, _: []const cc.types_mod.ApiMessage, _: ?[]const u8, _: ?[]const cc.json_mod.ToolDefinition, _: ?[]const u8) anyerror!cc.api_provider.ApiResponse {
        return error.UnexpectedTestCall;
    }
    fn maxTokens(_: *anyopaque) u32 {
        return 32_000;
    }
    fn maxInputTokens(_: *anyopaque) u32 {
        return 200_000;
    }
    fn reasoning(_: *anyopaque) ?cc.types_mod.ReasoningEffort {
        return null;
    }
    fn supports(_: *anyopaque, _: cc.api_provider.Capability) bool {
        return false;
    }
    fn provider(self: *@This()) cc.api_provider.Provider {
        return .{ .ctx = @ptrCast(self), .modelFn = model, .sendStreamFn = sendStream, .sendStreamRetryFn = sendStreamRetry, .sendFn = send, .maxTokensFn = maxTokens, .maxInputTokensFn = maxInputTokens, .reasoningEffortFn = reasoning, .supportsFn = supports };
    }
};

/// Backend that records spinner labels (set_current_tool names, copied) and
/// counts clear_current_tool, so the wait state is asserted through the same
/// events every UI consumes. poll never reports input.
const SpinnerBackend = struct {
    allocator: std.mem.Allocator,
    labels: std.ArrayList([]u8) = .empty,
    clears: u32 = 0,

    fn deinit(self: *SpinnerBackend) void {
        for (self.labels.items) |l| self.allocator.free(l);
        self.labels.deinit(self.allocator);
    }
    fn backend(self: *SpinnerBackend) cc.ui_backend.UiBackend {
        return .{ .ctx = @ptrCast(self), .emit = emitThunk, .poll = pollThunk };
    }
    fn emitThunk(ctx: *anyopaque, _: cc.session_id.SessionId, ev: cc.ui_event.CoreEvent) void {
        const self: *SpinnerBackend = @ptrCast(@alignCast(ctx));
        switch (ev) {
            .set_current_tool => |s| {
                const copy = self.allocator.dupe(u8, s.name) catch return;
                self.labels.append(self.allocator, copy) catch self.allocator.free(copy);
            },
            .clear_current_tool => self.clears += 1,
            else => {},
        }
    }
    fn pollThunk(_: *anyopaque, _: cc.session_id.SessionId) ?cc.ui_event.UiEvent {
        return null;
    }
    fn waitingLabelCount(self: *const SpinnerBackend) usize {
        var n: usize = 0;
        for (self.labels.items) |l| if (std.mem.startsWith(u8, l, "waiting for ")) {
            n += 1;
        };
        return n;
    }
};

const BG_JOB: Step = .{ .tool_use = .{ .id = "bash-bg", .input = "{\"command\":\"sleep 0.3; echo done\",\"run_in_background\":true}" } };
const BG_LONG_JOB: Step = .{ .tool_use = .{ .id = "bash-bg", .input = "{\"command\":\"sleep 5\",\"run_in_background\":true}" } };
const FG_SLEEP: Step = .{ .tool_use = .{ .id = "bash-fg", .input = "{\"command\":\"sleep 0.6\"}" } };
const SAY_WAITING: Step = .{ .text = "I will wait for the job." };
const SAY_DONE: Step = .{ .text = "Got it, the job finished." };

fn countPersistedNotifications(conversation: *const cc.conversation.Conversation) usize {
    var n: usize = 0;
    for (conversation.messages.items) |message| {
        if (message.role != .user) continue;
        for (message.blocks) |block| switch (block) {
            .text => |text| if (std.mem.indexOf(u8, text, "<task-notification>") != null) {
                n += 1;
            },
            else => {},
        };
    }
    return n;
}

const Fixture = struct {
    jobs: cc.job_registry.JobRegistry,
    conversation: cc.conversation.Conversation,
    permission: cc.permission.PermissionContext,
    defs: []const cc.json_mod.ToolDefinition,

    fn init(a: std.mem.Allocator) !Fixture {
        var f: Fixture = undefined;
        f.jobs = try cc.job_registry.JobRegistry.init(a);
        errdefer f.jobs.deinit();
        f.conversation = cc.conversation.Conversation.init(a);
        errdefer f.conversation.deinit();
        try f.conversation.appendText(.user, "run the job and tell me when it is done");
        f.permission = cc.permission.createContext(.bypass_permissions, a);
        f.defs = try cc.tools.toToolDefinitions(a);
        return f;
    }
    fn deinit(self: *Fixture, a: std.mem.Allocator) void {
        a.free(self.defs);
        self.conversation.deinit();
        self.jobs.deinit();
    }
};

test "JobNotify agent loop delivers one persisted notification at the next turn" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var f = try Fixture.init(a);
    defer f.deinit(a);
    var fake = FakeProvider{ .allocator = a, .script = &.{ .{ .tool_use = .{ .id = "bash-bg", .input = "{\"command\":\"sleep 0.2; echo done\",\"run_in_background\":true}" } }, FG_SLEEP, SAY_DONE } };
    var writer = cc.writer_backend.WriterBackend.initNull();
    const backend = writer.backend();
    const result = try cc.agent_loop.run(&f.conversation, fake.provider(), f.defs, &f.permission, .{
        .max_turns = 5,
        .jobs = &f.jobs,
        .job_notifications = &f.jobs,
    }, &backend, a);
    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, result.stop_reason);
    try std.testing.expectEqual(@as(u8, 3), fake.sends);
    // Delivered on the wire in the request after the foreground sleep (index 2), naming the real job.
    try std.testing.expectEqual(@as(?u8, 2), fake.notification_send_index);
    try std.testing.expect(!std.mem.eql(u8, fake.notification_job_id[0..], "000000000000"));
    try std.testing.expectEqual(@as(usize, 1), countPersistedNotifications(&f.conversation));
}

test "JobNotify null option injects nothing" {
    const a = std.testing.allocator;
    var conversation = cc.conversation.Conversation.init(a);
    defer conversation.deinit();
    try conversation.appendText(.user, "hello");
    var jobs = try cc.job_registry.JobRegistry.init(a);
    defer jobs.deinit();
    const owner = cc.session_id.gen();
    const job = try jobs.spawnBackgroundOwned("true", null, owner);
    jobs.markExitObserved(job.idSlice());
    var fake = FakeProvider{ .allocator = a, .script = &.{SAY_DONE} };
    const permission = cc.permission.createContext(.bypass_permissions, a);
    var writer = cc.writer_backend.WriterBackend.initNull();
    const backend = writer.backend();
    _ = try cc.agent_loop.run(&conversation, fake.provider(), &.{}, &permission, .{ .max_turns = 1, .jobs = &jobs, .job_notifications = null }, &backend, a);
    try std.testing.expectEqual(@as(usize, 2), conversation.len());
    try std.testing.expectEqual(@as(?u8, null), fake.notification_send_index);
    try std.testing.expectEqual(@as(usize, 0), countPersistedNotifications(&conversation));
}

test "JobWait T1 end_turn with a running job waits in core and continues after the exit" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var f = try Fixture.init(a);
    defer f.deinit(a);
    var fake = FakeProvider{ .allocator = a, .script = &.{ BG_JOB, SAY_WAITING, SAY_DONE } };
    var writer = cc.writer_backend.WriterBackend.initNull();
    const backend = writer.backend();
    const started = cc.util_time.nowMs();
    const result = try cc.agent_loop.run(&f.conversation, fake.provider(), f.defs, &f.permission, .{
        .max_turns = 5,
        .jobs = &f.jobs,
        .job_notifications = &f.jobs,
    }, &backend, a);
    const elapsed = cc.util_time.nowMs() - started;
    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, result.stop_reason);
    try std.testing.expectEqual(@as(u8, 3), fake.sends);
    try std.testing.expectEqual(@as(u32, 3), result.turns);
    try std.testing.expect(elapsed >= 300);
    // The notification was delivered with the third request and sits between the two answers.
    try std.testing.expectEqual(@as(?u8, 2), fake.notification_send_index);
    try std.testing.expect(!std.mem.eql(u8, fake.notification_job_id[0..], "000000000000"));
    var assistant_seen: usize = 0;
    var notification_after_assistants: ?usize = null;
    for (f.conversation.messages.items) |message| {
        if (message.role == .assistant) {
            assistant_seen += 1;
            continue;
        }
        for (message.blocks) |block| switch (block) {
            .text => |text| if (std.mem.indexOf(u8, text, "<task-notification>") != null) {
                notification_after_assistants = assistant_seen;
            },
            else => {},
        };
    }
    // assistant #1 = tool call, #2 = "I will wait": the notification follows exactly two assistant messages.
    try std.testing.expectEqual(@as(?usize, 2), notification_after_assistants);
}

test "JobWait T2 without job_notifications the run ends without waiting" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var f = try Fixture.init(a);
    defer f.deinit(a);
    var fake = FakeProvider{ .allocator = a, .script = &.{ BG_JOB, SAY_WAITING, SAY_DONE } };
    var writer = cc.writer_backend.WriterBackend.initNull();
    const backend = writer.backend();
    const result = try cc.agent_loop.run(&f.conversation, fake.provider(), f.defs, &f.permission, .{
        .max_turns = 5,
        .jobs = &f.jobs,
        .job_notifications = null,
    }, &backend, a);
    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, result.stop_reason);
    try std.testing.expectEqual(@as(u8, 2), fake.sends);
    try std.testing.expectEqual(@as(usize, 0), countPersistedNotifications(&f.conversation));
}

const AlwaysPending = struct {
    fn hasPending(_: *anyopaque) bool {
        return true;
    }
};

test "JobWait T3 pending user input ends the wait and leaves the exit for the next run" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var f = try Fixture.init(a);
    defer f.deinit(a);
    var fake = FakeProvider{ .allocator = a, .script = &.{ BG_JOB, SAY_WAITING, SAY_DONE } };
    var writer = cc.writer_backend.WriterBackend.initNull();
    const backend = writer.backend();
    var dummy: u8 = 0;
    const started = cc.util_time.nowMs();
    const result = try cc.agent_loop.run(&f.conversation, fake.provider(), f.defs, &f.permission, .{
        .max_turns = 5,
        .jobs = &f.jobs,
        .job_notifications = &f.jobs,
        .pending_input = .{ .ctx = @ptrCast(&dummy), .hasPendingFn = &AlwaysPending.hasPending },
    }, &backend, a);
    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, result.stop_reason);
    try std.testing.expectEqual(@as(u8, 2), fake.sends);
    try std.testing.expect(cc.util_time.nowMs() - started < 2000);
    // The exit was not consumed: once the job ends it is still announceable.
    var attempts: usize = 0;
    while (attempts < 200) : (attempts += 1) {
        if (!f.jobs.hasPendingNotifyJobs(cc.session_id.SessionId.single)) break;
        cc.util_time.sleepMs(10);
    }
    const events = try f.jobs.takeUnannouncedExits(cc.session_id.SessionId.single, a);
    defer cc.job_registry.freeJobExitEvents(a, events);
    try std.testing.expectEqual(@as(usize, 1), events.len);
}

test "JobWait T4 abort during the wait returns aborted without consuming the exit" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var f = try Fixture.init(a);
    defer f.deinit(a);
    var fake = FakeProvider{ .allocator = a, .script = &.{ BG_LONG_JOB, SAY_WAITING, SAY_DONE } };
    var writer = cc.writer_backend.WriterBackend.initNull();
    const backend = writer.backend();
    var signal = cc.util_abort.AbortSignal.init();
    const Aborter = struct {
        fn run(target: *cc.util_abort.AbortSignal) void {
            cc.util_time.sleepMs(150);
            target.abort(.user_interrupt);
        }
    };
    const thread = try std.Thread.spawn(.{}, Aborter.run, .{&signal});
    defer thread.join();
    const started = cc.util_time.nowMs();
    const result = try cc.agent_loop.run(&f.conversation, fake.provider(), f.defs, &f.permission, .{
        .max_turns = 5,
        .jobs = &f.jobs,
        .job_notifications = &f.jobs,
        .abort = &signal,
    }, &backend, a);
    try std.testing.expectEqual(cc.agent_loop.StopReason.aborted, result.stop_reason);
    try std.testing.expectEqual(@as(u8, 2), fake.sends);
    try std.testing.expect(cc.util_time.nowMs() - started < 2000);
    try std.testing.expectEqual(@as(usize, 0), countPersistedNotifications(&f.conversation));
}

test "JobWait T5 timeout ends the wait with end_turn" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var f = try Fixture.init(a);
    defer f.deinit(a);
    var fake = FakeProvider{ .allocator = a, .script = &.{ BG_LONG_JOB, SAY_WAITING, SAY_DONE } };
    var writer = cc.writer_backend.WriterBackend.initNull();
    const backend = writer.backend();
    const started = cc.util_time.nowMs();
    const result = try cc.agent_loop.run(&f.conversation, fake.provider(), f.defs, &f.permission, .{
        .max_turns = 5,
        .jobs = &f.jobs,
        .job_notifications = &f.jobs,
        .job_wait = .{ .timeout_ms = 300 },
    }, &backend, a);
    const elapsed = cc.util_time.nowMs() - started;
    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, result.stop_reason);
    try std.testing.expectEqual(@as(u8, 2), fake.sends);
    try std.testing.expect(elapsed >= 300);
    try std.testing.expect(elapsed < 4000);
}

test "JobWait T6 wakeup cap zero never waits" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var f = try Fixture.init(a);
    defer f.deinit(a);
    var fake = FakeProvider{ .allocator = a, .script = &.{ BG_LONG_JOB, SAY_WAITING, SAY_DONE } };
    var writer = cc.writer_backend.WriterBackend.initNull();
    const backend = writer.backend();
    const started = cc.util_time.nowMs();
    const result = try cc.agent_loop.run(&f.conversation, fake.provider(), f.defs, &f.permission, .{
        .max_turns = 5,
        .jobs = &f.jobs,
        .job_notifications = &f.jobs,
        .job_wait = .{ .max_wakeups = 0 },
    }, &backend, a);
    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, result.stop_reason);
    try std.testing.expectEqual(@as(u8, 2), fake.sends);
    try std.testing.expect(cc.util_time.nowMs() - started < 2000);
}

test "JobWait T7 the wait is visible through set_current_tool and cleared afterwards" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    {
        var f = try Fixture.init(a);
        defer f.deinit(a);
        var fake = FakeProvider{ .allocator = a, .script = &.{ BG_JOB, SAY_WAITING, SAY_DONE } };
        var spinner = SpinnerBackend{ .allocator = a };
        defer spinner.deinit();
        const backend = spinner.backend();
        _ = try cc.agent_loop.run(&f.conversation, fake.provider(), f.defs, &f.permission, .{
            .max_turns = 5,
            .jobs = &f.jobs,
            .job_notifications = &f.jobs,
        }, &backend, a);
        try std.testing.expectEqual(@as(usize, 1), spinner.waitingLabelCount());
        var named_job = false;
        for (spinner.labels.items) |l| if (std.mem.startsWith(u8, l, "waiting for background job ") and std.mem.indexOf(u8, l, fake.notification_job_id[0..]) != null) {
            named_job = true;
        };
        try std.testing.expect(named_job);
        try std.testing.expect(spinner.clears >= 1);
    }
    {
        var f = try Fixture.init(a);
        defer f.deinit(a);
        var fake = FakeProvider{ .allocator = a, .script = &.{ BG_JOB, SAY_WAITING, SAY_DONE } };
        var spinner = SpinnerBackend{ .allocator = a };
        defer spinner.deinit();
        const backend = spinner.backend();
        _ = try cc.agent_loop.run(&f.conversation, fake.provider(), f.defs, &f.permission, .{
            .max_turns = 5,
            .jobs = &f.jobs,
            .job_notifications = null,
        }, &backend, a);
        try std.testing.expectEqual(@as(usize, 0), spinner.waitingLabelCount());
    }
}

test "JobWait T8 an exit left over from a previous run is delivered with the next prompt" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var f = try Fixture.init(a);
    defer f.deinit(a);
    // Owner = the run's session (.single here), exactly what the Bash tool would have used.
    const job = try f.jobs.spawnBackground("true", null);
    var attempts: usize = 0;
    while (attempts < 200) : (attempts += 1) {
        f.jobs.reapExited();
        if ((f.jobs.get(job.idSlice()) orelse return error.JobNotFound).status != .running) break;
        cc.util_time.sleepMs(10);
    }
    var fake = FakeProvider{ .allocator = a, .script = &.{SAY_DONE} };
    var writer = cc.writer_backend.WriterBackend.initNull();
    const backend = writer.backend();
    const result = try cc.agent_loop.run(&f.conversation, fake.provider(), f.defs, &f.permission, .{
        .max_turns = 3,
        .jobs = &f.jobs,
        .job_notifications = &f.jobs,
    }, &backend, a);
    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, result.stop_reason);
    try std.testing.expectEqual(@as(u8, 1), fake.sends);
    try std.testing.expectEqual(@as(?u8, 0), fake.notification_send_index);
    try std.testing.expectEqual(@as(usize, 1), countPersistedNotifications(&f.conversation));
    // Delivered once: a second run finds nothing to announce.
    const events = try f.jobs.takeUnannouncedExits(cc.session_id.SessionId.single, a);
    defer cc.job_registry.freeJobExitEvents(a, events);
    try std.testing.expectEqual(@as(usize, 0), events.len);
}
