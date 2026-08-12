//! KillShell：终止后台作业。
//!
//! input: {"job_id": "..."}
//! output: {"job_id":"...","killed":true,"exit_code":N?}

const std = @import("std");
const common = @import("common.zig");
const ToolContext = @import("context.zig").ToolContext;

pub fn execute(ctx: *const ToolContext, args: []const u8) anyerror![]u8 {
    const allocator = ctx.allocator;
    const job_id = common.extractJsonArg(args, "job_id") orelse return error.MissingJobId;
    const registry = ctx.jobs orelse return error.JobsNotAvailable;

    try registry.kill(job_id);
    const job = registry.get(job_id) orelse return error.JobNotFound;

    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try aw.writer.writeAll("{\"job_id\":");
    try std.json.Stringify.encodeJsonString(job_id, .{}, &aw.writer);
    try aw.writer.print(",\"status\":\"{s}\"", .{@tagName(job.status)});
    if (job.exit_code) |ec| {
        try aw.writer.print(",\"exit_code\":{d}", .{ec});
    }
    try aw.writer.writeAll("}");
    return try aw.toOwnedSlice();
}

test "KillShell on running job" {
    const a = std.testing.allocator;
    var r = try @import("../core/job_registry.zig").JobRegistry.init(a);
    defer r.deinit();
    const j = try r.spawnBackground("sleep 30", null);

    var args_buf: [128]u8 = undefined;
    const args = try std.fmt.bufPrint(&args_buf, "{{\"job_id\":\"{s}\"}}", .{j.id[0..]});

    const ctx = ToolContext{ .allocator = a, .jobs = &r };
    const result = try execute(&ctx, args);
    defer a.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"status\":\"killed\"") != null);
}
