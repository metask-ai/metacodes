//! Monitor 工具:把命令丢后台跑,逐行 stdout 收集供模型轮询读取。
//!
//! 与 Bash(run_in_background=true) 的关系:Monitor **始终**后台,语义更明确。
//! Bash 后台是"一次性后台",而 Monitor 是"持续监视" — 默认无超时(or 长超时)。
//!
//! 调用方式:模型用 Monitor 启动,得到 job_id;BashOutput 读累积行;KillShell 停。
//!
//! 设计:复用 JobRegistry 的 spawnBackground(脚本相同),但默认 timeout 不杀。
//!
//! Schema:
//!   command:        必填,要 watch 的命令
//!   description:    必填,告诉用户在 watch 什么
//!   timeout_ms:     可选,默认 3600000 (1h)
//!   persistent:     可选,bool,true → 不设超时(直到 session 结束或被 KillShell)
//!
//! 返回 JSON: {"job_id":"...","status":"running","description":"..."}

const std = @import("std");
const common = @import("common.zig");
const ToolContext = @import("context.zig").ToolContext;

pub fn execute(ctx: *const ToolContext, args: []const u8) anyerror![]u8 {
    const command = common.extractJsonArg(args, "command") orelse return error.MissingCommand;
    if (command.len == 0) return error.EmptyCommand;
    const description = common.extractJsonArg(args, "description") orelse "background monitor";

    const jobs = ctx.jobs orelse return error.JobsUnavailable;

    // 启动后台 job
    const entry = jobs.spawnBackground(command) catch |err| {
        return try std.fmt.allocPrint(ctx.allocator,
            "{{\"error\":\"spawn_failed\",\"message\":\"{s}\"}}", .{@errorName(err)});
    };

    return try std.fmt.allocPrint(ctx.allocator,
        "{{\"job_id\":\"{s}\",\"status\":\"running\",\"description\":\"{s}\",\"hint\":\"Use BashOutput(job_id) to read streamed lines; KillShell(job_id) to stop.\"}}",
        .{ entry.id[0..], description },
    );
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "Monitor: missing command errors" {
    const ctx = ToolContext.simple(testing.allocator);
    try testing.expectError(error.MissingCommand, execute(&ctx, "{\"description\":\"x\"}"));
}

test "Monitor: empty command errors" {
    const ctx = ToolContext.simple(testing.allocator);
    try testing.expectError(error.EmptyCommand, execute(&ctx, "{\"command\":\"\"}"));
}

test "Monitor: no jobs registry → JobsUnavailable" {
    const ctx = ToolContext.simple(testing.allocator);
    try testing.expectError(error.JobsUnavailable, execute(&ctx, "{\"command\":\"echo hi\"}"));
}

test "Monitor: launches background job and returns job_id" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest; // 用 std.posix.poll 等子进程,POSIX 专属
    const a = testing.allocator;
    const JobRegistry = @import("../core/job_registry.zig").JobRegistry;
    var jobs = try JobRegistry.init(a);
    defer jobs.deinit();
    var ctx = ToolContext.simple(a);
    ctx.jobs = &jobs;

    const out = try execute(&ctx, "{\"command\":\"sleep 0.05\",\"description\":\"sleep test\"}");
    defer a.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "\"job_id\":") != null);
    try testing.expect(std.mem.indexOf(u8, out, "\"description\":\"sleep test\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "BashOutput") != null);
    // 等子进程退出,避免 leak — 用 poll 替代 sleep,跨 Zig 版本一致
    var pfd = [_]std.posix.pollfd{};
    _ = std.posix.poll(&pfd, 200) catch {};
    jobs.reapExited();
}
