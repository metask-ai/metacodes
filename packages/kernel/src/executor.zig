const std = @import("std");
const platform_thread = @import("platform").thread;
const types = @import("types.zig");

pub const Task = struct {
    call: types.ToolCall,
    tool: ?*const types.Tool,
    arena: std.heap.ArenaAllocator,
    result: ?types.ToolResult = null,

    pub fn init(gpa: std.mem.Allocator, call: types.ToolCall, tool: ?*const types.Tool) Task {
        return .{ .call = call, .tool = tool, .arena = .init(gpa) };
    }

    pub fn deinit(task: *Task) void {
        task.arena.deinit();
    }

    pub fn executionMode(task: Task) types.ExecutionMode {
        return if (task.tool) |tool| tool.mode else .parallel;
    }

    fn run(task: *Task, abort: *const types.AbortSignal, events: *types.Dispatcher) void {
        const tool = task.tool.?;
        task.result = tool.execute(tool.context, .{
            .arena = task.arena.allocator(),
            .call = task.call,
            .abort = abort,
            .events = events,
        }) catch |err| .{ .content = @errorName(err), .is_error = true };
    }
};

pub const aborted_result: types.ToolResult = .{ .content = "aborted before the tool ran", .is_error = true };

pub fn batchEnd(tasks: []const Task, start: usize) usize {
    return start + batchLength(tasks[start..], taskMode({}, tasks[start]), {}, taskMode, false);
}

fn taskMode(_: void, task: Task) ?types.ExecutionMode {
    return task.executionMode();
}

fn batchLength(items: anytype, mode: ?types.ExecutionMode, context: anytype, comptime classify: anytype, comptime group_sequential: bool) usize {
    if (mode == null or (!group_sequential and mode == .sequential)) return 1;
    var end: usize = 1;
    while (end < items.len and classify(context, items[end]) == mode) end += 1;
    return end;
}

pub fn dispatchBatches(items: anytype, context: anytype, comptime classify: anytype, comptime execute: anytype, comptime group_sequential: bool) !void {
    var remaining = items;
    while (remaining.len != 0) {
        const mode = classify(context, remaining[0]);
        const len = batchLength(remaining, mode, context, classify, group_sequential);
        try execute(context, remaining[0..len], mode);
        remaining = remaining[len..];
    }
}

pub fn runWindow(jobs: anytype, threads: []?std.Thread, spawn: anytype, comptime run: anytype, comptime should_stop: anytype) usize {
    var launched: usize = 0;
    for (jobs, threads) |*job, *thread| {
        thread.* = spawn(job) catch null;
        launched += 1;
        if (thread.* == null) {
            run(job);
            if (should_stop(job)) break;
        }
    }
    for (threads[0..launched]) |thread| if (thread) |worker| worker.join();
    return launched;
}

pub fn runBatch(gpa: std.mem.Allocator, batch: []Task, abort: *const types.AbortSignal, events: *types.Dispatcher) void {
    var pending: usize = 0;
    for (batch) |*task| {
        if (task.result != null) continue;
        if (abort.isAborted()) {
            task.result = aborted_result;
            continue;
        }
        pending += 1;
    }
    const threads = if (pending > 1) gpa.alloc(?std.Thread, batch.len) catch null else null;
    defer if (threads) |owned| gpa.free(owned);
    const workers = threads orelse {
        for (batch) |*task| if (task.result == null) task.run(abort, events);
        return;
    };
    for (batch, workers) |*task, *worker| {
        worker.* = null;
        if (task.result != null) continue;
        worker.* = platform_thread.spawn(.full, Task.run, .{ task, abort, events }) catch null;
    }
    for (batch, workers) |*task, worker| {
        if (worker) |thread| thread.join() else if (task.result == null) task.run(abort, events);
    }
}
