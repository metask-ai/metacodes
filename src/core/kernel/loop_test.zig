const std = @import("std");
const sync = @import("platform").sync;
const ai = @import("../../ai.zig");
const base = @import("../../base.zig");
const kernel = @import("../kernel.zig");
const Conversation = @import("../conversation.zig").Conversation;

const gpa = std.testing.allocator;

const Scripted = union(enum) {
    text: []const u8,
    thinking: []const u8,
    reasoning: []const u8,
    tool: struct { id: []const u8, name: []const u8, input: []const u8 = "{}" },
};

const Script = struct {
    events: []const Scripted = &.{},
    stop_reason: ai.StopReason = .end_turn,
    refuse: ?anyerror = null,
    break_after: ?anyerror = null,
};

const FakeProvider = struct {
    scripts: []const Script,
    requests: usize = 0,
    seen_messages: [8]usize = @splat(0),
    seen_tools: usize = 0,
    seen_system: ?[]const u8 = null,

    fn provider(fake: *FakeProvider) ai.Provider {
        return .{
            .ctx = fake,
            .modelFn = model,
            .sendStreamFn = sendStream,
            .sendStreamRetryFn = sendStreamRetry,
            .sendFn = send,
            .maxTokensFn = tokens,
            .maxInputTokensFn = tokens,
            .reasoningEffortFn = reasoningEffort,
            .supportsFn = supports,
        };
    }

    fn model(_: *anyopaque) []const u8 {
        return "fake-model";
    }

    fn sendStream(
        ctx: *anyopaque,
        messages: []const ai.ApiMessage,
        system: ?[]const u8,
        tools: ?[]const ai.ToolDefinition,
        _: ?*const kernel.AbortSignal,
        _: ?[]const u8,
        _: ?ai.ToolChoice,
        _: []const u8,
    ) anyerror!ai.StreamHandle {
        const fake: *FakeProvider = @ptrCast(@alignCast(ctx));
        const script = fake.scripts[@min(fake.requests, fake.scripts.len - 1)];
        fake.seen_messages[@min(fake.requests, fake.seen_messages.len - 1)] = messages.len;
        fake.seen_tools = if (tools) |list| list.len else 0;
        fake.seen_system = system;
        fake.requests += 1;
        if (script.refuse) |err| return err;
        const stream = try gpa.create(FakeStream);
        stream.* = .{ .script = script };
        return .{
            .ctx = stream,
            .nextFn = FakeStream.next,
            .deinitFn = FakeStream.deinit,
            .stopReasonFn = FakeStream.stopReason,
            .requestIdFn = FakeStream.requestId,
        };
    }

    fn sendStreamRetry(_: *anyopaque, _: []const ai.ApiMessage, _: ?[]const u8, _: ?[]const ai.ToolDefinition, _: ?*const kernel.AbortSignal, _: ?[]const u8, _: ?ai.ToolChoice, _: u32, _: u64, _: ?ai.RetryReporter, _: []const u8) anyerror!ai.StreamHandle {
        return error.Unsupported;
    }

    fn send(_: *anyopaque, _: []const ai.ApiMessage, _: ?[]const u8, _: ?[]const ai.ToolDefinition, _: ?[]const u8) anyerror!ai.ApiResponse {
        return error.Unsupported;
    }

    fn tokens(_: *anyopaque) u32 {
        return 100_000;
    }

    fn reasoningEffort(_: *anyopaque) ?ai.ReasoningEffort {
        return null;
    }

    fn supports(_: *anyopaque, _: ai.Capability) bool {
        return false;
    }
};

const FakeStream = struct {
    script: Script,
    position: usize = 0,

    fn next(ctx: *anyopaque) anyerror!?ai.StreamEvent {
        const stream: *FakeStream = @ptrCast(@alignCast(ctx));
        if (stream.position == stream.script.events.len) {
            if (stream.script.break_after) |err| return err;
            return null;
        }
        defer stream.position += 1;
        return switch (stream.script.events[stream.position]) {
            .text => |text| .{ .text = try gpa.dupe(u8, text) },
            .thinking => |text| .{ .thinking = try gpa.dupe(u8, text) },
            .reasoning => |json| .{ .reasoning_item = try gpa.dupe(u8, json) },
            .tool => |tool| .{ .tool_use_start = .{
                .id = try gpa.dupe(u8, tool.id),
                .name = try gpa.dupe(u8, tool.name),
                .input_json = try gpa.dupe(u8, tool.input),
            } },
        };
    }

    fn deinit(ctx: *anyopaque) void {
        const stream: *FakeStream = @ptrCast(@alignCast(ctx));
        gpa.destroy(stream);
    }

    fn stopReason(ctx: *anyopaque) ai.StopReason {
        const stream: *FakeStream = @ptrCast(@alignCast(ctx));
        return stream.script.stop_reason;
    }

    fn requestId(_: *anyopaque) base.RequestId {
        return .{ .bytes = "000000000000".* };
    }
};

const Log = struct {
    mutex: sync.Mutex = .{},
    buffer: [2048]u8 = undefined,
    len: usize = 0,

    fn add(log: *Log, comptime format: []const u8, args: anytype) void {
        log.mutex.lock();
        defer log.mutex.unlock();
        const written = std.fmt.bufPrint(log.buffer[log.len..], format ++ ";", args) catch unreachable;
        log.len += written.len;
    }

    fn text(log: *const Log) []const u8 {
        return log.buffer[0..log.len];
    }
};

const Recorder = struct {
    log: *Log,
    rendezvous: ?*std.atomic.Value(u32) = null,
    abort: ?*kernel.AbortSignal = null,

    fn tool(recorder: *Recorder, name: []const u8, mode: kernel.ExecutionMode) kernel.Tool {
        return .{ .name = name, .description = name, .mode = mode, .context = recorder, .execute = execute };
    }

    fn execute(context: *anyopaque, run: kernel.ToolRun) anyerror!kernel.ToolResult {
        const recorder: *Recorder = @ptrCast(@alignCast(context));
        recorder.log.add("run {s} {s}", .{ run.call.name, run.call.input });
        run.update("working");
        if (recorder.rendezvous) |arrived| {
            _ = arrived.fetchAdd(1, .acq_rel);
            var waited: u32 = 0;
            while (arrived.load(.acquire) < 2) : (waited += 1) {
                if (waited == 5000) return error.NotConcurrent;
                sync.sleepMs(1);
            }
        }
        if (recorder.abort) |signal| signal.abort(.user_interrupt);
        if (std.mem.eql(u8, run.call.input, "{\"fail\":true}")) return error.ToolBroke;
        return .{ .content = try std.fmt.allocPrint(run.arena, "{s} done", .{run.call.name}) };
    }
};

const Observer = struct {
    log: *Log,
    label: []const u8,
    reject: ?[]const u8 = null,
    rewrite: ?[]const u8 = null,
    decision: kernel.TurnDecision = .no_opinion,
    system: ?[]const u8 = null,
    model: ?[]const u8 = null,
    withdraw_tools: bool = false,
    fail_after_tool: bool = false,

    fn hook(observer: *Observer) kernel.Hook {
        return .{
            .context = observer,
            .prepare_request = prepare,
            .before_tool = before,
            .after_tool = after,
            .finish_turn = finish,
            .event = event,
        };
    }

    fn of(context: *anyopaque) *Observer {
        return @ptrCast(@alignCast(context));
    }

    fn prepare(context: *anyopaque, request: *kernel.Request) anyerror!void {
        const observer = of(context);
        observer.log.add("{s} prepare {d}", .{ observer.label, request.messages.items.len });
        if (observer.system) |system| request.system = system;
        if (observer.model) |model| request.model_override = model;
        if (observer.withdraw_tools) request.tools.clearRetainingCapacity();
    }

    fn before(context: *anyopaque, _: std.mem.Allocator, call: kernel.ToolCall) anyerror!kernel.ToolGate {
        const observer = of(context);
        observer.log.add("{s} before {s}", .{ observer.label, call.name });
        if (observer.reject) |reason| return .{ .reject = reason };
        if (observer.rewrite) |input| return .{ .rewrite = input };
        return .allow;
    }

    fn after(context: *anyopaque, arena: std.mem.Allocator, call: kernel.ToolCall, result: *kernel.ToolResult) anyerror!void {
        const observer = of(context);
        observer.log.add("{s} after {s}", .{ observer.label, call.name });
        if (observer.fail_after_tool) return error.AfterToolBroke;
        result.content = try std.fmt.allocPrint(arena, "{s}+{s}", .{ result.content, observer.label });
    }

    fn finish(context: *anyopaque, report: kernel.TurnReport) anyerror!kernel.TurnDecision {
        const observer = of(context);
        observer.log.add("{s} finish {d}", .{ observer.label, report.turn });
        return observer.decision;
    }

    fn event(context: *anyopaque, item: kernel.Event) void {
        const observer = of(context);
        if (!std.mem.eql(u8, observer.label, "A")) return;
        switch (item) {
            .agent_start => observer.log.add("agent_start", .{}),
            .agent_end => |outcome| observer.log.add("agent_end {s}", .{@tagName(outcome.stop)}),
            .turn_start => |turn| observer.log.add("turn_start {d}", .{turn}),
            .turn_end => |turn| observer.log.add("turn_end {d}", .{turn}),
            .message_start => |role| observer.log.add("message_start {s}", .{@tagName(role)}),
            .message_update => |delta| switch (delta) {
                .text => |text| observer.log.add("text {s}", .{text}),
                .thinking => |text| observer.log.add("thinking {s}", .{text}),
            },
            .message_end => |message| observer.log.add("message_end {s}", .{@tagName(message.role)}),
            .message_discarded => |role| observer.log.add("message_discarded {s}", .{@tagName(role)}),
            .tool_start => |call| observer.log.add("tool_start {s}", .{call.name}),
            .tool_update => |update| observer.log.add("tool_update {s} {s}", .{ update.call.name, update.data }),
            .tool_end => |end| observer.log.add("tool_end {s} {s}", .{ end.call.name, end.result.content }),
        }
    }
};

const Harness = struct {
    conversation: Conversation,
    abort: kernel.AbortSignal = .init(),

    fn init() !Harness {
        var harness: Harness = .{ .conversation = .init(gpa) };
        try harness.conversation.appendText(.user, "go");
        return harness;
    }

    fn deinit(harness: *Harness) void {
        harness.conversation.deinit();
    }

    fn run(harness: *Harness, fake: *FakeProvider, tools: []const kernel.Tool, hooks: []const kernel.Hook, max_turns: u32) kernel.Outcome {
        return kernel.run(.{
            .stream_gpa = gpa,
            .provider = fake.provider(),
            .conversation = &harness.conversation,
            .abort = &harness.abort,
            .max_turns = max_turns,
            .tools = tools,
            .hooks = hooks,
        });
    }

    fn result(harness: *Harness, message_index: usize, block_index: usize) @import("../message.zig").ToolResult {
        return harness.conversation.messages.items[message_index].blocks[block_index].tool_result;
    }
};

test "a single turn streams the reply into the conversation and completes" {
    var harness = try Harness.init();
    defer harness.deinit();
    var fake: FakeProvider = .{ .scripts = &.{.{ .events = &.{ .{ .thinking = "hm" }, .{ .text = "hel" }, .{ .text = "lo" } } }} };
    var log: Log = .{};
    var observer: Observer = .{ .log = &log, .label = "A" };
    const outcome = harness.run(&fake, &.{}, &.{observer.hook()}, 10);
    try std.testing.expectEqual(kernel.Stop.completed, outcome.stop);
    try std.testing.expectEqual(@as(u32, 1), outcome.turns);
    try std.testing.expectEqual(ai.StopReason.end_turn, outcome.stop_reason);
    const reply = harness.conversation.messages.items[1];
    try std.testing.expectEqualStrings("hm", reply.blocks[0].thinking);
    try std.testing.expectEqualStrings("hello", reply.blocks[1].text);
    try std.testing.expectEqualStrings(
        "agent_start;turn_start 1;A prepare 1;message_start assistant;thinking hm;text hel;text lo;message_end assistant;A finish 1;turn_end 1;agent_end completed;",
        log.text(),
    );
}

test "tool calls run over several turns and their results are written back" {
    var harness = try Harness.init();
    defer harness.deinit();
    var fake: FakeProvider = .{ .scripts = &.{
        .{ .events = &.{.{ .tool = .{ .id = "t1", .name = "read" } }}, .stop_reason = .tool_use },
        .{ .events = &.{.{ .tool = .{ .id = "t2", .name = "read", .input = "{\"fail\":true}" } }}, .stop_reason = .tool_use },
        .{ .events = &.{.{ .text = "all done" }} },
    } };
    var log: Log = .{};
    var recorder: Recorder = .{ .log = &log };
    const outcome = harness.run(&fake, &.{recorder.tool("read", .sequential)}, &.{}, 10);
    try std.testing.expectEqual(kernel.Stop.completed, outcome.stop);
    try std.testing.expectEqual(@as(u32, 3), outcome.turns);
    try std.testing.expectEqual(@as(usize, 1), fake.seen_tools);
    try std.testing.expectEqualSlices(usize, &.{ 1, 3, 5 }, fake.seen_messages[0..3]);
    try std.testing.expectEqual(@as(usize, 6), harness.conversation.messages.items.len);
    try std.testing.expectEqualStrings("t1", harness.result(2, 0).tool_use_id);
    try std.testing.expectEqualStrings("read done", harness.result(2, 0).content);
    try std.testing.expectEqualStrings("ToolBroke", harness.result(4, 0).content);
    try std.testing.expect(harness.result(4, 0).is_error);
    try std.testing.expectEqualStrings("all done", harness.conversation.messages.items[5].blocks[0].text);
}

test "parallel tools run at the same time and sequential tools split the batches" {
    var harness = try Harness.init();
    defer harness.deinit();
    var fake: FakeProvider = .{ .scripts = &.{
        .{ .events = &.{
            .{ .tool = .{ .id = "a", .name = "grep" } },
            .{ .tool = .{ .id = "b", .name = "grep" } },
            .{ .tool = .{ .id = "c", .name = "edit" } },
            .{ .tool = .{ .id = "d", .name = "missing" } },
        }, .stop_reason = .tool_use },
        .{ .events = &.{.{ .text = "ok" }} },
    } };
    var log: Log = .{};
    var arrived: std.atomic.Value(u32) = .init(0);
    var parallel: Recorder = .{ .log = &log, .rendezvous = &arrived };
    var serial: Recorder = .{ .log = &log };
    const tools = [_]kernel.Tool{ parallel.tool("grep", .parallel), serial.tool("edit", .sequential) };
    const outcome = harness.run(&fake, &tools, &.{}, 10);
    try std.testing.expectEqual(kernel.Stop.completed, outcome.stop);
    try std.testing.expectEqual(@as(u32, 2), arrived.load(.acquire));
    const results = harness.conversation.messages.items[2].blocks;
    try std.testing.expectEqual(@as(usize, 4), results.len);
    for (results, [_][]const u8{ "a", "b", "c", "d" }) |block, id| try std.testing.expectEqualStrings(id, block.tool_result.tool_use_id);
    try std.testing.expectEqualStrings("grep done", results[0].tool_result.content);
    try std.testing.expectEqualStrings("grep done", results[1].tool_result.content);
    try std.testing.expectEqualStrings("edit done", results[2].tool_result.content);
    try std.testing.expectEqualStrings("unknown tool `missing`", results[3].tool_result.content);
    try std.testing.expect(results[3].tool_result.is_error);
    try std.testing.expect(std.mem.endsWith(u8, log.text(), "run edit {};"));
}

test "hooks run in registration order around every step" {
    var harness = try Harness.init();
    defer harness.deinit();
    var fake: FakeProvider = .{ .scripts = &.{
        .{ .events = &.{.{ .tool = .{ .id = "t1", .name = "read" } }}, .stop_reason = .tool_use },
        .{ .events = &.{.{ .text = "ok" }} },
    } };
    var log: Log = .{};
    var recorder: Recorder = .{ .log = &log };
    var first: Observer = .{ .log = &log, .label = "A", .system = "from A" };
    var second: Observer = .{ .log = &log, .label = "B", .rewrite = "{\"path\":\"x\"}" };
    const outcome = harness.run(&fake, &.{recorder.tool("read", .sequential)}, &.{ first.hook(), second.hook() }, 10);
    try std.testing.expectEqual(kernel.Stop.completed, outcome.stop);
    try std.testing.expectEqualStrings("from A", fake.seen_system.?);
    try std.testing.expectEqualStrings("read done+A+B", harness.result(2, 0).content);
    try std.testing.expectEqualStrings(
        "agent_start;turn_start 1;A prepare 1;B prepare 1;message_start assistant;message_end assistant;" ++
            "tool_start read;A before read;B before read;run read {\"path\":\"x\"};tool_update read working;" ++
            "A after read;B after read;tool_end read read done+A+B;message_start user;message_end user;" ++
            "A finish 1;B finish 1;turn_end 1;turn_start 2;A prepare 3;B prepare 3;message_start assistant;text ok;" ++
            "message_end assistant;A finish 2;B finish 2;turn_end 2;agent_end completed;",
        log.text(),
    );
}

test "before_tool can reject a call, and the model sees the reason" {
    var harness = try Harness.init();
    defer harness.deinit();
    var fake: FakeProvider = .{ .scripts = &.{
        .{ .events = &.{.{ .tool = .{ .id = "t1", .name = "bash" } }}, .stop_reason = .tool_use },
        .{ .events = &.{.{ .text = "understood" }} },
    } };
    var log: Log = .{};
    var recorder: Recorder = .{ .log = &log };
    var guard: Observer = .{ .log = &log, .label = "G", .reject = "denied by policy" };
    const outcome = harness.run(&fake, &.{recorder.tool("bash", .sequential)}, &.{guard.hook()}, 10);
    try std.testing.expectEqual(kernel.Stop.completed, outcome.stop);
    try std.testing.expectEqualStrings("denied by policy+G", harness.result(2, 0).content);
    try std.testing.expect(harness.result(2, 0).is_error);
    try std.testing.expect(std.mem.indexOf(u8, log.text(), "run bash") == null);
}

test "an abort during a tool stops the run with every call answered" {
    var harness = try Harness.init();
    defer harness.deinit();
    var fake: FakeProvider = .{ .scripts = &.{
        .{ .events = &.{ .{ .tool = .{ .id = "t1", .name = "edit" } }, .{ .tool = .{ .id = "t2", .name = "edit" } } }, .stop_reason = .tool_use },
    } };
    var log: Log = .{};
    var recorder: Recorder = .{ .log = &log, .abort = &harness.abort };
    var gate: Observer = .{ .log = &log, .label = "G", .fail_after_tool = true };
    const outcome = harness.run(&fake, &.{recorder.tool("edit", .sequential)}, &.{gate.hook()}, 10);
    try std.testing.expectEqual(kernel.Stop.aborted, outcome.stop);
    try std.testing.expectEqual(@as(usize, 1), fake.requests);
    try std.testing.expectEqualStrings("edit done", harness.result(2, 0).content);
    try std.testing.expectEqualStrings("aborted before the tool ran", harness.result(2, 1).content);
    try std.testing.expectEqualStrings("G prepare 1;G before edit;run edit {};G after edit;G after edit;", log.text());
}

test "a provider error fails the run and leaves the conversation as it was" {
    var harness = try Harness.init();
    defer harness.deinit();
    var refused: FakeProvider = .{ .scripts = &.{.{ .refuse = error.ProviderDown }} };
    const outcome = harness.run(&refused, &.{}, &.{}, 10);
    try std.testing.expectEqual(kernel.Stop{ .failed = error.ProviderDown }, outcome.stop);
    try std.testing.expectEqual(@as(usize, 1), harness.conversation.messages.items.len);
    var broken: FakeProvider = .{ .scripts = &.{.{ .events = &.{ .{ .text = "par" }, .{ .tool = .{ .id = "t1", .name = "x" } } }, .break_after = error.ConnectionReset }} };
    var log: Log = .{};
    var observer: Observer = .{ .log = &log, .label = "A" };
    const broken_outcome = harness.run(&broken, &.{}, &.{observer.hook()}, 10);
    try std.testing.expectEqualStrings(
        "agent_start;turn_start 1;A prepare 1;message_start assistant;text par;message_discarded assistant;turn_end 1;agent_end failed;",
        log.text(),
    );
    try std.testing.expectEqual(kernel.Stop{ .failed = error.ConnectionReset }, broken_outcome.stop);
    try std.testing.expectEqual(@as(usize, 1), harness.conversation.messages.items.len);
}

test "an after_tool failure still writes every result back before the run fails" {
    var harness = try Harness.init();
    defer harness.deinit();
    var fake: FakeProvider = .{ .scripts = &.{.{ .events = &.{.{ .tool = .{ .id = "t1", .name = "read" } }}, .stop_reason = .tool_use }} };
    var log: Log = .{};
    var recorder: Recorder = .{ .log = &log };
    var broken: Observer = .{ .log = &log, .label = "B", .fail_after_tool = true };
    const outcome = harness.run(&fake, &.{recorder.tool("read", .sequential)}, &.{broken.hook()}, 10);
    try std.testing.expectEqual(kernel.Stop{ .failed = error.AfterToolBroke }, outcome.stop);
    try std.testing.expectEqualStrings("read done", harness.result(2, 0).content);
}

test "max_turns ends a run that keeps calling tools, and finish_turn can stop one early" {
    var harness = try Harness.init();
    defer harness.deinit();
    var fake: FakeProvider = .{ .scripts = &.{.{ .events = &.{.{ .tool = .{ .id = "t", .name = "read" } }}, .stop_reason = .tool_use }} };
    var log: Log = .{};
    var recorder: Recorder = .{ .log = &log };
    const tools = [_]kernel.Tool{recorder.tool("read", .sequential)};
    const outcome = harness.run(&fake, &tools, &.{}, 2);
    try std.testing.expectEqual(kernel.Stop.max_turns, outcome.stop);
    try std.testing.expectEqual(@as(u32, 2), outcome.turns);
    try std.testing.expectEqual(@as(usize, 2), fake.requests);
    var stopper: Observer = .{ .log = &log, .label = "S", .decision = .stop };
    var keep: Observer = .{ .log = &log, .label = "K", .decision = .continue_run };
    const stopped = harness.run(&fake, &tools, &.{ keep.hook(), stopper.hook() }, 10);
    try std.testing.expectEqual(kernel.Stop.stopped, stopped.stop);
    try std.testing.expectEqual(@as(u32, 1), stopped.turns);
}

test "an empty reply completes the run without writing a message" {
    var harness = try Harness.init();
    defer harness.deinit();
    var fake: FakeProvider = .{ .scripts = &.{.{}} };
    var log: Log = .{};
    var observer: Observer = .{ .log = &log, .label = "A" };
    const outcome = harness.run(&fake, &.{}, &.{observer.hook()}, 10);
    try std.testing.expectEqual(kernel.Stop.completed, outcome.stop);
    try std.testing.expectEqual(@as(usize, 1), harness.conversation.messages.items.len);
    try std.testing.expectEqualStrings("agent_start;turn_start 1;A prepare 1;A finish 1;turn_end 1;agent_end completed;", log.text());
}

test "the request names the model that answers, and reasoning is recorded under it" {
    var harness = try Harness.init();
    defer harness.deinit();
    var fake: FakeProvider = .{ .scripts = &.{.{ .events = &.{ .{ .reasoning = "{\"id\":\"r1\"}" }, .{ .text = "ok" } } }} };
    var log: Log = .{};
    var switcher: Observer = .{ .log = &log, .label = "M", .model = "model-b" };
    _ = harness.run(&fake, &.{}, &.{switcher.hook()}, 10);
    const item = harness.conversation.messages.items[1].blocks[0].reasoning_item;
    try std.testing.expectEqualStrings("model-b", item.model);
    try std.testing.expectEqualStrings("{\"id\":\"r1\"}", item.json);
}

test "a history message with only thinking is kept locally but not sent" {
    var harness = try Harness.init();
    defer harness.deinit();
    const blocks = try gpa.alloc(@import("../message.zig").Block, 1);
    blocks[0] = .{ .thinking = try gpa.dupe(u8, "ran out of tokens") };
    try harness.conversation.append(.{ .role = .assistant, .blocks = blocks });
    try harness.conversation.appendText(.user, "again");
    var fake: FakeProvider = .{ .scripts = &.{.{ .events = &.{.{ .text = "ok" }} }} };
    _ = harness.run(&fake, &.{}, &.{}, 10);
    try std.testing.expectEqual(@as(usize, 2), fake.seen_messages[0]);
    try std.testing.expectEqual(@as(usize, 4), harness.conversation.messages.items.len);
}

test "a tool withdrawn from the request does not run even when the model calls it" {
    var harness = try Harness.init();
    defer harness.deinit();
    var fake: FakeProvider = .{ .scripts = &.{
        .{ .events = &.{.{ .tool = .{ .id = "t1", .name = "read" } }}, .stop_reason = .tool_use },
        .{ .events = &.{.{ .text = "ok" }} },
    } };
    var log: Log = .{};
    var recorder: Recorder = .{ .log = &log };
    var narrower: Observer = .{ .log = &log, .label = "N", .withdraw_tools = true };
    _ = harness.run(&fake, &.{recorder.tool("read", .sequential)}, &.{narrower.hook()}, 10);
    try std.testing.expectEqual(@as(usize, 0), fake.seen_tools);
    try std.testing.expectEqualStrings("unknown tool `read`+N", harness.result(2, 0).content);
    try std.testing.expect(std.mem.indexOf(u8, log.text(), "run read") == null);
}
