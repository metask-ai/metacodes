const std = @import("std");
const ai = @import("metacodes-ai");
const message = @import("message.zig");
const Conversation = @import("conversation.zig").Conversation;
const executor = @import("executor.zig");
const types = @import("types.zig");

pub const Options = struct {
    stream_gpa: std.mem.Allocator,
    provider: ai.Provider,
    conversation: *Conversation,
    abort: *const types.AbortSignal,
    max_turns: u32,
    system: ?[]const u8 = null,
    tools: []const types.Tool = &.{},
    hooks: []const types.Hook = &.{},
};

pub fn StepOutcome(comptime Result: type) type {
    return union(enum) {
        continue_run,
        stop: Result,
    };
}

pub fn drive(
    comptime Result: type,
    context: anytype,
    comptime limit: fn (@TypeOf(context)) u32,
    comptime isAborted: fn (@TypeOf(context)) bool,
    comptime step: anytype,
    comptime onAborted: fn (@TypeOf(context), u32) Result,
    comptime onLimit: fn (@TypeOf(context), u32) Result,
    comptime abort_precedes_limit: bool,
) !Result {
    var turns: u32 = 0;
    while (true) {
        if (abort_precedes_limit and isAborted(context)) return onAborted(context, turns);
        if (turns >= limit(context)) return onLimit(context, turns);
        if (!abort_precedes_limit and isAborted(context)) return onAborted(context, turns);
        switch (try step(context, turns)) {
            .continue_run => turns += 1,
            .stop => |result| return result,
        }
    }
}

pub fn run(options: Options) types.Outcome {
    var events: types.Dispatcher = .{ .hooks = options.hooks };
    events.emit(.agent_start);
    const outcome = runTurns(options, &events);
    events.emit(.{ .agent_end = outcome });
    return outcome;
}

const RunTurnsContext = struct {
    options: Options,
    events: *types.Dispatcher,
    stop_reason: ai.StopReason = .unknown,

    fn limit(ctx: *RunTurnsContext) u32 {
        return ctx.options.max_turns;
    }

    fn isAborted(ctx: *RunTurnsContext) bool {
        return ctx.options.abort.isAborted();
    }

    fn onAborted(ctx: *RunTurnsContext, turns: u32) types.Outcome {
        return .{ .stop = .aborted, .turns = turns, .stop_reason = ctx.stop_reason };
    }

    fn onLimit(ctx: *RunTurnsContext, turns: u32) types.Outcome {
        return .{ .stop = .max_turns, .turns = turns, .stop_reason = ctx.stop_reason };
    }

    fn step(ctx: *RunTurnsContext, completed_turns: u32) error{}!StepOutcome(types.Outcome) {
        const turn = completed_turns + 1;
        ctx.events.emit(.{ .turn_start = turn });
        const next_step = runTurn(ctx.options, ctx.events, turn);
        ctx.events.emit(.{ .turn_end = turn });
        const next = next_step catch |err| {
            return .{ .stop = .{
                .stop = if (ctx.options.abort.isAborted()) .aborted else .{ .failed = err },
                .turns = turn,
                .stop_reason = ctx.stop_reason,
            } };
        };
        ctx.stop_reason = next.stop_reason;
        if (next.stop) |stop| {
            return .{ .stop = .{ .stop = stop, .turns = turn, .stop_reason = next.stop_reason } };
        }
        return .continue_run;
    }
};

fn runTurns(options: Options, events: *types.Dispatcher) types.Outcome {
    var ctx: RunTurnsContext = .{ .options = options, .events = events };
    return drive(
        types.Outcome,
        &ctx,
        RunTurnsContext.limit,
        RunTurnsContext.isAborted,
        RunTurnsContext.step,
        RunTurnsContext.onAborted,
        RunTurnsContext.onLimit,
        true,
    ) catch unreachable;
}

const Step = struct {
    stop_reason: ai.StopReason,
    stop: ?types.Stop,
};

fn runTurn(options: Options, events: *types.Dispatcher, turn: u32) !Step {
    const conversation = options.conversation;
    const reply = try streamReply(options, events);
    defer options.stream_gpa.free(reply.offered);
    var calls: std.ArrayList(types.ToolCall) = .empty;
    defer calls.deinit(options.stream_gpa);
    if (reply.message) |assistant| {
        conversation.append(assistant) catch |err| {
            assistant.deinit(conversation.allocator);
            return err;
        };
        const appended = &conversation.messages.items[conversation.messages.items.len - 1];
        events.emit(.{ .message_end = appended });
        for (appended.blocks) |block| switch (block) {
            .tool_use => |tool_use| try calls.append(options.stream_gpa, .{ .id = tool_use.id, .name = tool_use.name, .input = tool_use.input }),
            else => {},
        };
    }
    if (calls.items.len != 0) try runTools(options, events, calls.items, reply.offered);
    var decision: types.TurnDecision = if (calls.items.len == 0) .no_opinion else .continue_run;
    const report: types.TurnReport = .{ .turn = turn, .tool_calls = calls.items.len, .stop_reason = reply.stop_reason };
    for (options.hooks) |hook| {
        const finish = hook.finish_turn orelse continue;
        switch (try finish(hook.context, report)) {
            .no_opinion => {},
            .continue_run => if (decision != .stop) {
                decision = .continue_run;
            },
            .stop => decision = .stop,
        }
    }
    return .{ .stop_reason = reply.stop_reason, .stop = switch (decision) {
        .no_opinion => .completed,
        .continue_run => null,
        .stop => .stopped,
    } };
}

fn runTools(options: Options, events: *types.Dispatcher, calls: []const types.ToolCall, offered: []const bool) !void {
    const gpa = options.stream_gpa;
    const tasks = try gpa.alloc(executor.Task, calls.len);
    defer gpa.free(tasks);
    for (calls, tasks) |call, *task| task.* = .init(gpa, call, findTool(options.tools, offered, call.name));
    defer for (tasks) |*task| task.deinit();
    var turn_arena: std.heap.ArenaAllocator = .init(gpa);
    defer turn_arena.deinit();
    var ctx = ToolBatchContext{ .options = options, .events = events, .arena = turn_arena.allocator() };
    try executor.dispatchBatches(tasks, &ctx, ToolBatchContext.mode, ToolBatchContext.execute, false);
    try appendResults(options.conversation, events, tasks);
    if (ctx.hook_failure) |err| return err;
}

const ToolBatchContext = struct {
    options: Options,
    events: *types.Dispatcher,
    arena: std.mem.Allocator,
    hook_failure: ?anyerror = null,

    fn mode(_: *ToolBatchContext, task: executor.Task) ?types.ExecutionMode {
        return task.executionMode();
    }

    fn execute(ctx: *ToolBatchContext, batch: []executor.Task, _: ?types.ExecutionMode) !void {
        const options = ctx.options;
        for (batch) |*task| {
            ctx.events.emit(.{ .tool_start = task.call });
            if (options.abort.isAborted()) {
                task.result = executor.aborted_result;
                continue;
            }
            gate(options.hooks, ctx.arena, task) catch |err| {
                ctx.hook_failure = ctx.hook_failure orelse err;
                task.result = .{ .content = @errorName(err), .is_error = true };
            };
        }
        executor.runBatch(options.stream_gpa, batch, options.abort, ctx.events);
        for (batch) |*task| {
            for (options.hooks) |hook| {
                const after = hook.after_tool orelse continue;
                after(hook.context, ctx.arena, task.call, &task.result.?) catch |err| {
                    ctx.hook_failure = ctx.hook_failure orelse err;
                };
            }
            ctx.events.emit(.{ .tool_end = .{ .call = task.call, .result = task.result.? } });
        }
    }
};

fn gate(hooks: []const types.Hook, arena: std.mem.Allocator, task: *executor.Task) !void {
    if (task.tool == null) {
        task.result = .{ .content = try std.fmt.allocPrint(arena, "unknown tool `{s}`", .{task.call.name}), .is_error = true };
        return;
    }
    for (hooks) |hook| {
        const before = hook.before_tool orelse continue;
        switch (try before(hook.context, arena, task.call)) {
            .allow => {},
            .rewrite => |input| task.call.input = input,
            .reject => |reason| {
                task.result = .{ .content = reason, .is_error = true };
                return;
            },
        }
    }
}

fn findTool(tools: []const types.Tool, offered: []const bool, name: []const u8) ?*const types.Tool {
    for (tools, offered) |*tool, available| {
        if (available and std.mem.eql(u8, tool.name, name)) return tool;
    }
    return null;
}

fn offeredTools(gpa: std.mem.Allocator, tools: []const types.Tool, definitions: []const ai.ToolDefinition) ![]bool {
    const offered = try gpa.alloc(bool, tools.len);
    for (tools, offered) |tool, *available| {
        available.* = for (definitions) |definition| {
            if (std.mem.eql(u8, definition.name, tool.name)) break true;
        } else false;
    }
    return offered;
}

fn appendResults(conversation: *Conversation, events: *types.Dispatcher, tasks: []const executor.Task) !void {
    const gpa = conversation.allocator;
    const blocks = try gpa.alloc(message.Block, tasks.len);
    var filled: usize = 0;
    errdefer {
        for (blocks[0..filled]) |block| block.deinit(gpa);
        gpa.free(blocks);
    }
    for (tasks, blocks) |task, *block| {
        const id = try gpa.dupe(u8, task.call.id);
        errdefer gpa.free(id);
        block.* = .{ .tool_result = .{
            .tool_use_id = id,
            .content = try gpa.dupe(u8, task.result.?.content),
            .is_error = task.result.?.is_error,
        } };
        filled += 1;
    }
    try conversation.append(.{ .role = .user, .blocks = blocks });
    events.emit(.{ .message_start = .user });
    events.emit(.{ .message_end = &conversation.messages.items[conversation.messages.items.len - 1] });
}

const Reply = struct {
    message: ?message.Message,
    stop_reason: ai.StopReason,
    offered: []bool,
};

fn streamReply(options: Options, events: *types.Dispatcher) !Reply {
    var request_arena: std.heap.ArenaAllocator = .init(options.stream_gpa);
    defer request_arena.deinit();
    var request = try buildRequest(request_arena.allocator(), options);
    for (options.hooks) |hook| {
        const prepare = hook.prepare_request orelse continue;
        try prepare(hook.context, &request);
    }
    const offered = try offeredTools(options.stream_gpa, options.tools, request.tools.items);
    errdefer options.stream_gpa.free(offered);
    const tools = if (request.tools.items.len == 0) null else request.tools.items;
    const handle = try options.provider.sendStream(request.messages.items, request.system, tools, options.abort, request.model_override, request.tool_choice, "");
    defer handle.deinit();
    var draft: StreamDraft = .init(options.conversation.allocator, options.stream_gpa);
    defer draft.deinit();
    errdefer if (draft.started) events.emit(.{ .message_discarded = .assistant });
    while (try handle.next()) |event| try draft.take(events, event);
    const model = request.model_override orelse options.provider.model();
    return .{ .message = try draft.finish(model), .stop_reason = handle.stopReason(), .offered = offered };
}

fn buildRequest(arena: std.mem.Allocator, options: Options) !types.Request {
    var request: types.Request = .{ .arena = arena, .messages = .empty, .tools = .empty, .system = options.system };
    const conversation = options.conversation;
    if (conversation.compact_summary) |summary| if (summary.len != 0) {
        const content = try arena.alloc(ai.ApiContent, 1);
        content[0] = .{ .text = summary };
        try request.messages.append(arena, .{ .role = .assistant, .content = content });
    };
    for (conversation.activeMessages()) |item| try appendHistoryMessage(&request.messages, arena, item);
    for (options.tools) |tool| {
        try request.tools.append(arena, .{ .name = tool.name, .description = tool.description, .input_schema = tool.input_schema });
    }
    return request;
}

pub fn appendHistoryMessage(out: *std.ArrayList(ai.ApiMessage), allocator: std.mem.Allocator, item: message.Message) !void {
    if (!carriesContent(item)) return;
    const content = try allocator.alloc(ai.ApiContent, item.blocks.len);
    errdefer allocator.free(content);
    for (item.blocks, content) |block, *part| part.* = switch (block) {
        .text => |text| .{ .text = text },
        .thinking => |text| .{ .thinking = text },
        .tool_use => |tool_use| .{ .tool_use = .{ .id = tool_use.id, .name = tool_use.name, .input = tool_use.input } },
        .tool_result => |result| .{ .tool_result = .{ .tool_use_id = result.tool_use_id, .content = result.content, .is_error = result.is_error } },
        .image => |image| .{ .image = .{ .media_type = image.media_type, .data = image.data } },
        .reasoning_item => |item_block| .{ .reasoning_item = .{ .model = item_block.model, .json = item_block.json } },
    };
    try out.append(allocator, .{ .role = item.role, .content = content });
}

fn carriesContent(item: message.Message) bool {
    for (item.blocks) |block| switch (block) {
        .thinking, .reasoning_item => {},
        else => return true,
    };
    return false;
}

pub const AssistantDraft = struct {
    gpa: std.mem.Allocator,
    text: std.ArrayList(u8) = .empty,
    thinking: std.ArrayList(u8) = .empty,
    reasoning: std.ArrayList([]u8) = .empty,
    tool_uses: std.ArrayList(message.ToolUse) = .empty,
    blocks: std.ArrayList(message.Block) = .empty,

    pub const FinishOptions = struct {
        drop_reasoning_without_content: bool = false,
    };

    pub fn init(gpa: std.mem.Allocator) AssistantDraft {
        return .{ .gpa = gpa };
    }

    pub fn deinit(draft: *AssistantDraft) void {
        draft.clear();
        draft.text.deinit(draft.gpa);
        draft.thinking.deinit(draft.gpa);
        draft.reasoning.deinit(draft.gpa);
        draft.tool_uses.deinit(draft.gpa);
        draft.blocks.deinit(draft.gpa);
    }

    pub fn clear(draft: *AssistantDraft) void {
        for (draft.blocks.items) |block| block.deinit(draft.gpa);
        draft.blocks.clearRetainingCapacity();
        draft.text.clearRetainingCapacity();
        draft.thinking.clearRetainingCapacity();
        for (draft.reasoning.items) |json| draft.gpa.free(json);
        draft.reasoning.clearRetainingCapacity();
        for (draft.tool_uses.items) |tool_use| freeToolUse(draft.gpa, tool_use);
        draft.tool_uses.clearRetainingCapacity();
    }

    pub fn hasVisibleOutput(draft: *const AssistantDraft) bool {
        return draft.text.items.len != 0 or
            draft.thinking.items.len != 0 or
            draft.tool_uses.items.len != 0 or
            draft.blocks.items.len != 0;
    }

    pub fn hasSubstantiveOutput(draft: *const AssistantDraft) bool {
        return draft.text.items.len != 0 or
            draft.tool_uses.items.len != 0 or
            draft.blocks.items.len != 0;
    }

    pub fn appendText(draft: *AssistantDraft, bytes: []const u8) !void {
        try draft.text.appendSlice(draft.gpa, bytes);
    }

    pub fn appendThinking(draft: *AssistantDraft, bytes: []const u8) !void {
        try draft.thinking.appendSlice(draft.gpa, bytes);
    }

    pub fn appendReasoningOwned(draft: *AssistantDraft, json: []u8) !void {
        draft.reasoning.append(draft.gpa, json) catch |err| {
            draft.gpa.free(json);
            return err;
        };
    }

    pub fn appendToolUseOwned(draft: *AssistantDraft, tool_use: message.ToolUse) !void {
        draft.tool_uses.append(draft.gpa, tool_use) catch |err| {
            freeToolUse(draft.gpa, tool_use);
            return err;
        };
    }

    pub fn appendBlockOwned(draft: *AssistantDraft, block: message.Block) !void {
        draft.blocks.append(draft.gpa, block) catch |err| {
            block.deinit(draft.gpa);
            return err;
        };
    }

    pub fn finishPartialText(draft: *AssistantDraft) !?[]message.Block {
        for (draft.tool_uses.items) |tool_use| freeToolUse(draft.gpa, tool_use);
        draft.tool_uses.clearRetainingCapacity();
        for (draft.reasoning.items) |json| draft.gpa.free(json);
        draft.reasoning.clearRetainingCapacity();
        draft.thinking.clearRetainingCapacity();
        if (draft.text.items.len > 0) {
            const owned = try draft.gpa.dupe(u8, draft.text.items);
            errdefer draft.gpa.free(owned);
            try draft.blocks.append(draft.gpa, .{ .text = owned });
        }
        if (draft.blocks.items.len == 0) return null;
        return try draft.blocks.toOwnedSlice(draft.gpa);
    }

    pub fn finishBlocks(draft: *AssistantDraft, model: []const u8, options: FinishOptions) !?[]message.Block {
        if (options.drop_reasoning_without_content and !draft.hasSubstantiveOutput()) {
            for (draft.reasoning.items) |json| draft.gpa.free(json);
            draft.reasoning.clearRetainingCapacity();
        }
        const extra = draft.reasoning.items.len +
            @as(usize, @intFromBool(draft.thinking.items.len > 0)) +
            @as(usize, @intFromBool(draft.text.items.len > 0)) +
            draft.tool_uses.items.len;
        try draft.blocks.ensureUnusedCapacity(draft.gpa, extra);
        if (draft.reasoning.items.len > 0) {
            const models = try draft.gpa.alloc([]u8, draft.reasoning.items.len);
            var duped: usize = 0;
            errdefer {
                for (models[0..duped]) |owned_model| draft.gpa.free(owned_model);
                draft.gpa.free(models);
            }
            for (models) |*slot| {
                slot.* = try draft.gpa.dupe(u8, model);
                duped += 1;
            }
            defer draft.gpa.free(models);
            for (draft.reasoning.items, models) |json, owned_model| {
                draft.blocks.appendAssumeCapacity(.{ .reasoning_item = .{ .model = owned_model, .json = json } });
            }
            draft.reasoning.clearRetainingCapacity();
        }
        if (draft.thinking.items.len > 0) {
            const owned = try draft.gpa.dupe(u8, draft.thinking.items);
            draft.blocks.appendAssumeCapacity(.{ .thinking = owned });
        }
        if (draft.text.items.len > 0) {
            const owned = try draft.gpa.dupe(u8, draft.text.items);
            draft.blocks.appendAssumeCapacity(.{ .text = owned });
        }
        for (draft.tool_uses.items) |tool_use| {
            draft.blocks.appendAssumeCapacity(.{ .tool_use = tool_use });
        }
        draft.tool_uses.clearRetainingCapacity();
        if (draft.blocks.items.len == 0) return null;
        return try draft.blocks.toOwnedSlice(draft.gpa);
    }
};

const StreamDraft = struct {
    assistant: AssistantDraft,
    stream_gpa: std.mem.Allocator,
    started: bool = false,

    fn init(gpa: std.mem.Allocator, stream_gpa: std.mem.Allocator) StreamDraft {
        return .{ .assistant = .init(gpa), .stream_gpa = stream_gpa };
    }

    fn start(draft: *StreamDraft, events: *types.Dispatcher) void {
        if (draft.started) return;
        draft.started = true;
        events.emit(.{ .message_start = .assistant });
    }

    fn deinit(draft: *StreamDraft) void {
        draft.assistant.deinit();
    }

    fn take(draft: *StreamDraft, events: *types.Dispatcher, event: ai.StreamEvent) !void {
        switch (event) {
            .text => |text| {
                defer draft.stream_gpa.free(text);
                draft.start(events);
                try draft.assistant.appendText(text);
                events.emit(.{ .message_update = .{ .text = text } });
            },
            .thinking => |text| {
                defer draft.stream_gpa.free(text);
                draft.start(events);
                try draft.assistant.appendThinking(text);
                events.emit(.{ .message_update = .{ .thinking = text } });
            },
            .tool_use_start => |tool_use| {
                defer {
                    draft.stream_gpa.free(tool_use.id);
                    draft.stream_gpa.free(tool_use.name);
                    draft.stream_gpa.free(tool_use.input_json);
                }
                draft.start(events);
                const owned = try dupeToolUse(draft.assistant.gpa, .{ .id = tool_use.id, .name = tool_use.name, .input = tool_use.input_json });
                try draft.assistant.appendToolUseOwned(owned);
            },
            .reasoning_item => |json| {
                defer draft.stream_gpa.free(json);
                draft.start(events);
                const owned = try draft.assistant.gpa.dupe(u8, json);
                try draft.assistant.appendReasoningOwned(owned);
            },
            .web_search_result => |result| {
                draft.stream_gpa.free(result.ui_text);
                draft.stream_gpa.free(result.content_json);
            },
            .web_search_query => |query| draft.stream_gpa.free(query),
            .usage, .done => {},
        }
    }

    fn finish(draft: *StreamDraft, model: []const u8) !?message.Message {
        const blocks = try draft.assistant.finishBlocks(model, .{}) orelse return null;
        return .{ .role = .assistant, .blocks = blocks };
    }
};

fn dupeToolUse(gpa: std.mem.Allocator, tool_use: message.ToolUse) !message.ToolUse {
    const id = try gpa.dupe(u8, tool_use.id);
    errdefer gpa.free(id);
    const name = try gpa.dupe(u8, tool_use.name);
    errdefer gpa.free(name);
    return .{ .id = id, .name = name, .input = try gpa.dupe(u8, tool_use.input) };
}

fn freeToolUse(gpa: std.mem.Allocator, tool_use: message.ToolUse) void {
    gpa.free(tool_use.id);
    gpa.free(tool_use.name);
    gpa.free(tool_use.input);
}
