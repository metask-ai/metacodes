//! Tool surface only. The AgentLoop owns the VM and the nested invocation gate.
const std = @import("std");
const ToolContext = @import("context.zig").ToolContext;

pub fn execute(ctx: *const ToolContext, args: []const u8) anyerror![]u8 {
    if (!ctx.preview) return error.PreviewFeatureDisabled;
    const parsed = try std.json.parseFromSlice(std.json.Value, ctx.allocator, args, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidArgs;
    const code = parsed.value.object.get("code") orelse return error.MissingRequiredField;
    if (code != .string) return error.InvalidArgs;
    var timeout_ms: u32 = 30000;
    if (parsed.value.object.get("timeout_ms")) |timeout| {
        if (timeout != .integer or timeout.integer < 1 or timeout.integer > 120000) return error.InvalidArgs;
        timeout_ms = @intCast(timeout.integer);
    }
    const executor = ctx.code_executor orelse return error.CodeExecutionUnavailable;
    return executor.executeFn(executor.ctx, ctx, code.string, timeout_ms);
}
