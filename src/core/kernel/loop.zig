const std = @import("std");
const ai = @import("../../ai.zig");
const message = @import("../message.zig");
const Conversation = @import("../conversation.zig").Conversation;
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

pub fn run(options: Options) types.Outcome {
    var events: types.Dispatcher = .{ .hooks = options.hooks };
    events.emit(.agent_start);
    const outcome = runTurns(options, &events);
    events.emit(.{ .agent_end = outcome });
    return outcome;
}

fn runTurns(options: Options, events: *types.Dispatcher) types.Outcome {
    var outcome: types.Outcome = .{ .stop = .completed, .turns = 0 };
    while (true) {
        if (options.abort.isAborted()) {
            outcome.stop = .aborted;
            return outcome;
        }
        if (outcome.turns == options.max_turns) {
            outcome.stop = .max_turns;
            return outcome;
        }
        outcome.turns += 1;
        events.emit(.{ .turn_start = outcome.turns });
        const step = runTurn(options, events, outcome.turns);
        events.emit(.{ .turn_end = outcome.turns });
        const next = step catch |err| {
            outcome.stop = if (options.abort.isAborted()) .aborted else .{ .failed = err };
            return outcome;
        };
        outcome.stop_reason = next.stop_reason;
        outcome.stop = next.stop orelse continue;
        return outcome;
    }
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
    const arena = turn_arena.allocator();
    var hook_failure: ?anyerror = null;
    var start: usize = 0;
    while (start < tasks.len) {
        const end = executor.batchEnd(tasks, start);
        const batch = tasks[start..end];
        for (batch) |*task| {
            events.emit(.{ .tool_start = task.call });
            if (options.abort.isAborted()) {
                task.result = executor.aborted_result;
                continue;
            }
            gate(options.hooks, arena, task) catch |err| {
                hook_failure = hook_failure orelse err;
                task.result = .{ .content = @errorName(err), .is_error = true };
            };
        }
        executor.runBatch(gpa, batch, options.abort, events);
        for (batch) |*task| {
            for (options.hooks) |hook| {
                const after = hook.after_tool orelse continue;
                after(hook.context, arena, task.call, &task.result.?) catch |err| {
                    hook_failure = hook_failure orelse err;
                };
            }
            events.emit(.{ .tool_end = .{ .call = task.call, .result = task.result.? } });
        }
        start = end;
    }
    try appendResults(options.conversation, events, tasks);
    if (hook_failure) |err| return err;
}

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
    var draft: Draft = .{ .gpa = options.conversation.allocator, .stream_gpa = options.stream_gpa };
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

const Draft = struct {
    gpa: std.mem.Allocator,
    stream_gpa: std.mem.Allocator,
    text: std.ArrayList(u8) = .empty,
    thinking: std.ArrayList(u8) = .empty,
    reasoning: std.ArrayList([]u8) = .empty,
    tool_uses: std.ArrayList(message.ToolUse) = .empty,
    started: bool = false,

    fn start(draft: *Draft, events: *types.Dispatcher) void {
        if (draft.started) return;
        draft.started = true;
        events.emit(.{ .message_start = .assistant });
    }

    fn deinit(draft: *Draft) void {
        draft.text.deinit(draft.gpa);
        draft.thinking.deinit(draft.gpa);
        for (draft.reasoning.items) |json| draft.gpa.free(json);
        draft.reasoning.deinit(draft.gpa);
        for (draft.tool_uses.items) |tool_use| freeToolUse(draft.gpa, tool_use);
        draft.tool_uses.deinit(draft.gpa);
    }

    fn take(draft: *Draft, events: *types.Dispatcher, event: ai.StreamEvent) !void {
        switch (event) {
            .text => |text| {
                defer draft.stream_gpa.free(text);
                draft.start(events);
                try draft.text.appendSlice(draft.gpa, text);
                events.emit(.{ .message_update = .{ .text = text } });
            },
            .thinking => |text| {
                defer draft.stream_gpa.free(text);
                draft.start(events);
                try draft.thinking.appendSlice(draft.gpa, text);
                events.emit(.{ .message_update = .{ .thinking = text } });
            },
            .tool_use_start => |tool_use| {
                defer {
                    draft.stream_gpa.free(tool_use.id);
                    draft.stream_gpa.free(tool_use.name);
                    draft.stream_gpa.free(tool_use.input_json);
                }
                draft.start(events);
                const owned = try dupeToolUse(draft.gpa, .{ .id = tool_use.id, .name = tool_use.name, .input = tool_use.input_json });
                draft.tool_uses.append(draft.gpa, owned) catch |err| {
                    freeToolUse(draft.gpa, owned);
                    return err;
                };
            },
            .reasoning_item => |json| {
                defer draft.stream_gpa.free(json);
                draft.start(events);
                const owned = try draft.gpa.dupe(u8, json);
                draft.reasoning.append(draft.gpa, owned) catch |err| {
                    draft.gpa.free(owned);
                    return err;
                };
            },
            .web_search_result => |result| {
                draft.stream_gpa.free(result.ui_text);
                draft.stream_gpa.free(result.content_json);
            },
            .web_search_query => |query| draft.stream_gpa.free(query),
            .usage, .done => {},
        }
    }

    fn finish(draft: *Draft, model: []const u8) !?message.Message {
        const gpa = draft.gpa;
        const count = draft.reasoning.items.len + draft.tool_uses.items.len +
            @intFromBool(draft.thinking.items.len != 0) + @intFromBool(draft.text.items.len != 0);
        if (count == 0) return null;
        const blocks = try gpa.alloc(message.Block, count);
        errdefer gpa.free(blocks);
        var filled: usize = 0;
        errdefer for (blocks[0..filled]) |block| gpa.free(block.reasoning_item.model);
        for (draft.reasoning.items) |json| {
            blocks[filled] = .{ .reasoning_item = .{ .model = try gpa.dupe(u8, model), .json = json } };
            filled += 1;
        }
        const thinking: ?[]u8 = if (draft.thinking.items.len != 0) try draft.thinking.toOwnedSlice(gpa) else null;
        errdefer if (thinking) |owned| gpa.free(owned);
        const text: ?[]u8 = if (draft.text.items.len != 0) try draft.text.toOwnedSlice(gpa) else null;
        if (thinking) |owned| {
            blocks[filled] = .{ .thinking = owned };
            filled += 1;
        }
        if (text) |owned| {
            blocks[filled] = .{ .text = owned };
            filled += 1;
        }
        for (draft.tool_uses.items) |tool_use| {
            blocks[filled] = .{ .tool_use = tool_use };
            filled += 1;
        }
        draft.reasoning.clearRetainingCapacity();
        draft.tool_uses.clearRetainingCapacity();
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
