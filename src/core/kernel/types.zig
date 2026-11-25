const std = @import("std");
const sync = @import("platform").sync;
const ai = @import("../../ai.zig");
const base = @import("../../base.zig");
const message = @import("../message.zig");

pub const AbortSignal = base.AbortSignal;

pub const ExecutionMode = enum { sequential, parallel };

pub const ToolCall = struct {
    id: []const u8,
    name: []const u8,
    input: []const u8,
};

pub const ToolResult = struct {
    content: []const u8,
    is_error: bool = false,
};

pub const Tool = struct {
    name: []const u8,
    description: []const u8,
    input_schema: ai.InputSchema = .{},
    mode: ExecutionMode = .sequential,
    context: *anyopaque,
    execute: *const fn (context: *anyopaque, run: ToolRun) anyerror!ToolResult,
};

pub const ToolRun = struct {
    arena: std.mem.Allocator,
    call: ToolCall,
    abort: *const AbortSignal,
    events: *Dispatcher,

    pub fn update(run: ToolRun, data: []const u8) void {
        run.events.emit(.{ .tool_update = .{ .call = run.call, .data = data } });
    }
};

pub const Request = struct {
    arena: std.mem.Allocator,
    messages: std.ArrayList(ai.ApiMessage),
    tools: std.ArrayList(ai.ToolDefinition),
    system: ?[]const u8,
    model_override: ?[]const u8 = null,
    tool_choice: ?ai.ToolChoice = null,
};

pub const ToolGate = union(enum) {
    allow,
    rewrite: []const u8,
    reject: []const u8,
};

pub const TurnReport = struct {
    turn: u32,
    tool_calls: usize,
    stop_reason: ai.StopReason,
};

pub const TurnDecision = enum { no_opinion, continue_run, stop };

pub const Delta = union(enum) {
    text: []const u8,
    thinking: []const u8,
};

pub const Stop = union(enum) {
    completed,
    max_turns,
    aborted,
    stopped,
    failed: anyerror,
};

pub const Outcome = struct {
    stop: Stop,
    turns: u32,
    stop_reason: ai.StopReason = .unknown,
};

pub const Event = union(enum) {
    agent_start,
    agent_end: Outcome,
    turn_start: u32,
    turn_end: u32,
    message_start: message.Role,
    message_update: Delta,
    message_end: *const message.Message,
    message_discarded: message.Role,
    tool_start: ToolCall,
    tool_update: struct { call: ToolCall, data: []const u8 },
    tool_end: struct { call: ToolCall, result: ToolResult },
};

pub const Hook = struct {
    context: *anyopaque,
    prepare_request: ?*const fn (context: *anyopaque, request: *Request) anyerror!void = null,
    before_tool: ?*const fn (context: *anyopaque, arena: std.mem.Allocator, call: ToolCall) anyerror!ToolGate = null,
    after_tool: ?*const fn (context: *anyopaque, arena: std.mem.Allocator, call: ToolCall, result: *ToolResult) anyerror!void = null,
    finish_turn: ?*const fn (context: *anyopaque, report: TurnReport) anyerror!TurnDecision = null,
    event: ?*const fn (context: *anyopaque, event: Event) void = null,
};

pub const Dispatcher = struct {
    hooks: []const Hook,
    mutex: sync.Mutex = .{},

    pub fn emit(dispatcher: *Dispatcher, event: Event) void {
        dispatcher.mutex.lock();
        defer dispatcher.mutex.unlock();
        for (dispatcher.hooks) |hook| {
            const sink = hook.event orelse continue;
            sink(hook.context, event);
        }
    }
};
