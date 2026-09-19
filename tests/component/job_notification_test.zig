//! L2 component coverage for harness-to-conversation background exit delivery.

const std = @import("std");
const cc = @import("cc");

const FakeStream = struct {
    allocator: std.mem.Allocator,
    response: u8,
    step: u8 = 0,
    rid: cc.util_log.RequestId,

    fn next(ctx: *anyopaque) anyerror!?cc.api_stream.StreamEvent {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        if (self.response < 2 and self.step == 0) {
            self.step = 1;
            const input = if (self.response == 0)
                "{\"command\":\"sleep 0.2; echo done\",\"run_in_background\":true}"
            else
                "{\"command\":\"sleep 0.6\"}";
            return .{ .tool_use_start = .{
                .id = try self.allocator.dupe(u8, if (self.response == 0) "bash-bg" else "bash-fg"),
                .name = try self.allocator.dupe(u8, "Bash"),
                .input_json = try self.allocator.dupe(u8, input),
            } };
        }
        if (self.response == 2 and self.step == 0) {
            self.step = 1;
            return .{ .text = try self.allocator.dupe(u8, "done") };
        }
        if (self.step == 1) {
            self.step = 2;
            return .{ .done = {} };
        }
        return null;
    }
    fn deinit(_: *anyopaque) void {}
    fn stop(ctx: *anyopaque) cc.api_stream.StopReason {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        return if (self.response < 2) .tool_use else .end_turn;
    }
    fn requestId(ctx: *anyopaque) cc.util_log.RequestId {
        return @as(*@This(), @ptrCast(@alignCast(ctx))).rid;
    }
};

const FakeProvider = struct {
    allocator: std.mem.Allocator,
    start_response: u8 = 0,
    sends: u8 = 0,
    streams: [3]FakeStream = undefined,
    notification_seen: bool = false,
    notification_job_id: [12]u8 = undefined,

    fn model(_: *anyopaque) []const u8 {
        return "fake";
    }
    fn sendStreamRetry(ctx: *anyopaque, messages: []const cc.types_mod.ApiMessage, _: ?[]const u8, _: ?[]const cc.json_mod.ToolDefinition, _: ?*const cc.util_abort.AbortSignal, _: ?[]const u8, _: ?cc.json_mod.ToolChoice, _: u32, _: u64, _: ?cc.api_provider.RetryReporter, _: []const u8) anyerror!cc.api_provider.StreamHandle {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        if (self.sends >= self.streams.len) return error.UnexpectedTestCall;
        const index = self.sends;
        self.sends += 1;
        if (index == 2) {
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
            if (job_id) |id| {
                @memcpy(&self.notification_job_id, id);
                for (messages) |message| {
                    if (message.role != .user) continue;
                    for (message.content) |content| switch (content) {
                        .text => |text| {
                            if (std.mem.indexOf(u8, text, "<task-notification>") != null and
                                std.mem.indexOf(u8, text, id) != null)
                                self.notification_seen = true;
                        },
                        else => {},
                    };
                }
            }
        }
        self.streams[index] = .{ .allocator = self.allocator, .response = self.start_response + index, .rid = cc.util_log.genRequestId() };
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

test "JobNotify agent loop delivers one persisted notification at the next turn" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    var fake = FakeProvider{ .allocator = a };
    var jobs = try cc.job_registry.JobRegistry.init(a);
    defer jobs.deinit();
    var conversation = cc.conversation.Conversation.init(a);
    defer conversation.deinit();
    try conversation.appendText(.user, "run the job");
    const permission = cc.permission.createContext(.bypass_permissions, a);
    const defs = try cc.tools.toToolDefinitions(a);
    defer a.free(defs);
    var writer = cc.writer_backend.WriterBackend.initNull();
    const backend = writer.backend();
    const result = try cc.agent_loop.run(&conversation, fake.provider(), defs, &permission, .{
        .max_turns = 5,
        .jobs = &jobs,
        .job_notifications = &jobs,
    }, &backend, a);
    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, result.stop_reason);
    try std.testing.expectEqual(@as(u8, 3), fake.sends);
    try std.testing.expect(fake.notification_seen);
    try std.testing.expect(!std.mem.eql(u8, fake.notification_job_id[0..], "000000000000"));
    var persisted = false;
    for (conversation.messages.items) |message| {
        if (message.role != .user) continue;
        for (message.blocks) |block| {
            switch (block) {
                .text => |text| {
                    if (std.mem.indexOf(u8, text, "task-notification") != null) persisted = true;
                },
                else => {},
            }
        }
    }
    try std.testing.expect(persisted);
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
    var fake = FakeProvider{ .allocator = a, .start_response = 2 };
    const permission = cc.permission.createContext(.bypass_permissions, a);
    var writer = cc.writer_backend.WriterBackend.initNull();
    const backend = writer.backend();
    _ = try cc.agent_loop.run(&conversation, fake.provider(), &.{}, &permission, .{ .max_turns = 1, .jobs = &jobs, .job_notifications = null }, &backend, a);
    try std.testing.expectEqual(@as(usize, 2), conversation.len());
    for (conversation.messages.items) |message| {
        for (message.blocks) |block| {
            switch (block) {
                .text => |text| try std.testing.expect(std.mem.indexOf(u8, text, "task-notification") == null),
                else => {},
            }
        }
    }
}
