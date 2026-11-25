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

    fn mode(task: Task) types.ExecutionMode {
        const tool = task.tool orelse return .parallel;
        return tool.mode;
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
    var end = start + 1;
    if (tasks[start].mode() == .sequential) return end;
    while (end < tasks.len and tasks[end].mode() == .parallel) end += 1;
    return end;
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
