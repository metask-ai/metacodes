//! Cron 工具:CronCreate / CronDelete / CronList。
//!
//! 调度由 core/cron_registry.zig 管理(session 级)。REPL 主循环在读 prompt 前
//! 调 collectDue 把到期 cron 的 prompt 注入对话。

const std = @import("std");
const common = @import("common.zig");
const ToolContext = @import("context.zig").ToolContext;
const util_json = @import("../util/json.zig");

pub fn createExecute(ctx: *const ToolContext, args: []const u8) anyerror![]u8 {
    const a = ctx.allocator;
    const reg = ctx.cron_registry orelse return error.CronUnavailable;

    const prompt_raw = common.extractJsonArg(args, "prompt") orelse return error.MissingPrompt;
    const prompt = try @import("../util/json.zig").unescapeString(prompt_raw, a);
    defer a.free(prompt);
    if (prompt.len == 0) return error.EmptyPrompt;

    const cron_raw = optionalArg(args, "cron");
    const cron_expr = if (cron_raw) |raw| try util_json.unescapeString(raw, a) else "";
    defer if (cron_raw != null) a.free(cron_expr);
    const delay_s: ?i64 = blk: {
        const v = common.extractJsonArg(args, "delaySeconds") orelse common.extractJsonArg(args, "delay_seconds");
        if (v) |s| break :blk std.fmt.parseInt(i64, s, 10) catch null;
        break :blk null;
    };
    if (cron_expr.len == 0 and delay_s == null) return error.MissingSchedule;

    // Only a cron expression repeats. Without one the job is the one-shot
    // delaySeconds the tool's description promises, and `recurring: true` is
    // refused: stored, it had no expression to repeat on.
    const recurring = if (optionalArg(args, "recurring")) |v| !std.mem.eql(u8, v, "false") else cron_expr.len > 0;
    if (recurring and cron_expr.len == 0) {
        common.setErrorDetail(ctx.error_detail, a, "recurring: true needs a cron expression to repeat on, and none was given; nothing was scheduled. For a recurring job pass cron (5-field 'M H DoM Mon DoW'); for one fire after delaySeconds, leave out recurring or set it to false.", .{});
        return error.InvalidRecurringWithoutCron;
    }

    const id = reg.create(cron_expr, delay_s, prompt, recurring) catch |err| {
        return try std.fmt.allocPrint(a, "{{\"error\":\"{s}\"}}", .{@errorName(err)});
    };

    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    try out.writer.writeAll("{\"id\":");
    try util_json.writeJsonString(&out.writer, id.slice());
    try out.writer.print(",\"recurring\":{},\"scheduled\":true}}", .{recurring});
    return try out.toOwnedSlice();
}

/// An optional argument as given, or null when it is absent or JSON `null`,
/// which a model may send for a parameter it means to leave out.
fn optionalArg(args: []const u8, field: []const u8) ?[]const u8 {
    const v = common.extractJsonArg(args, field) orelse return null;
    return if (std.mem.eql(u8, v, "null")) null else v;
}

pub fn deleteExecute(ctx: *const ToolContext, args: []const u8) anyerror![]u8 {
    const a = ctx.allocator;
    const reg = ctx.cron_registry orelse return error.CronUnavailable;
    const id_raw = common.extractJsonArg(args, "id") orelse return error.MissingId;
    const id = try util_json.unescapeString(id_raw, a);
    defer a.free(id);
    const found = reg.delete(id);
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    try out.writer.print("{{\"deleted\":{},\"id\":", .{found});
    try util_json.writeJsonString(&out.writer, id);
    try out.writer.writeByte('}');
    return try out.toOwnedSlice();
}

pub fn listExecute(ctx: *const ToolContext, args: []const u8) anyerror![]u8 {
    _ = args;
    const a = ctx.allocator;
    const reg = ctx.cron_registry orelse return error.CronUnavailable;

    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    try out.writer.writeAll("{\"jobs\":[");
    for (reg.jobs.items, 0..) |j, i| {
        if (i > 0) try out.writer.writeByte(',');
        try out.writer.writeAll("{\"id\":");
        try util_json.writeJsonString(&out.writer, j.id.slice());
        try out.writer.writeAll(",\"cron\":");
        try util_json.writeJsonString(&out.writer, j.cron_expr);
        try out.writer.print(",\"recurring\":{},\"next_fire_unix\":{d}}}", .{ j.recurring, j.next_fire_unix });
    }
    try out.writer.print("],\"count\":{d}}}", .{reg.count()});
    return try out.toOwnedSlice();
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;
const CronRegistry = @import("../core/cron_registry.zig").CronRegistry;

test "CronCreate: missing prompt errors" {
    const ctx = ToolContext.simple(testing.allocator);
    // 没 cron_registry → CronUnavailable 先触发
    try testing.expectError(error.CronUnavailable, createExecute(&ctx, "{\"prompt\":\"x\"}"));
}

test "CronCreate + List + Delete cycle" {
    const a = testing.allocator;
    var reg = CronRegistry.init(a);
    defer reg.deinit();
    var ctx = ToolContext.simple(a);
    ctx.cron_registry = &reg;

    const out = try createExecute(&ctx, "{\"cron\":\"*/5 * * * *\",\"prompt\":\"check deploy\"}");
    defer a.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "\"scheduled\":true") != null);

    const list = try listExecute(&ctx, "{}");
    defer a.free(list);
    try testing.expect(std.mem.indexOf(u8, list, "\"count\":1") != null);
    try testing.expect(std.mem.indexOf(u8, list, "check deploy") == null); // prompt 不在 list 输出
    try testing.expect(std.mem.indexOf(u8, list, "*/5 * * * *") != null);

    // 抽 id
    const id_start = std.mem.indexOf(u8, out, "\"id\":\"").? + 6;
    const id = out[id_start .. id_start + 12];
    const del_args = try std.fmt.allocPrint(a, "{{\"id\":\"{s}\"}}", .{id});
    defer a.free(del_args);
    const del = try deleteExecute(&ctx, del_args);
    defer a.free(del);
    try testing.expect(std.mem.indexOf(u8, del, "\"deleted\":true") != null);
}

test "CronCreate: one-shot delay" {
    const a = testing.allocator;
    var reg = CronRegistry.init(a);
    defer reg.deinit();
    var ctx = ToolContext.simple(a);
    ctx.cron_registry = &reg;

    const out = try createExecute(&ctx, "{\"delaySeconds\":\"120\",\"prompt\":\"remind me\",\"recurring\":\"false\"}");
    defer a.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "\"recurring\":false") != null);
    try testing.expectEqual(@as(usize, 1), reg.count());
}

test "CronCreate: delaySeconds alone is one-shot, gone after it fires" {
    const a = testing.allocator;
    // `recurring` left out, and sent as JSON null, which counts as left out.
    for ([_][]const u8{
        "{\"prompt\":\"remind me once\",\"delaySeconds\":0}",
        "{\"prompt\":\"remind me once\",\"delaySeconds\":0,\"cron\":null,\"recurring\":null}",
    }) |args| {
        var reg = CronRegistry.init(a);
        defer reg.deinit();
        var ctx = ToolContext.simple(a);
        ctx.cron_registry = &reg;

        const out = try createExecute(&ctx, args);
        defer a.free(out);
        try testing.expect(std.mem.indexOf(u8, out, "\"recurring\":false") != null);
        try testing.expectEqual(@as(usize, 1), reg.count());

        const due = try reg.collectDue(a, std.math.maxInt(usize));
        defer {
            for (due) |p| a.free(p);
            a.free(due);
        }
        try testing.expectEqual(@as(usize, 1), due.len);
        try testing.expectEqualStrings("remind me once", due[0]);
        try testing.expectEqual(@as(usize, 0), reg.count());
    }
}

test "CronCreate: recurring true without cron is refused and schedules nothing" {
    const a = testing.allocator;
    var reg = CronRegistry.init(a);
    defer reg.deinit();
    var detail: ?[]const u8 = null;
    defer if (detail) |d| a.free(d);
    var ctx = ToolContext.simple(a);
    ctx.cron_registry = &reg;
    ctx.error_detail = &detail;

    const err = createExecute(&ctx, "{\"prompt\":\"every minute\",\"delaySeconds\":60,\"recurring\":true}");
    try testing.expectError(error.InvalidRecurringWithoutCron, err);
    try testing.expectEqual(@as(usize, 0), reg.count());

    // What the model reads: tool_exec sends the detail under the error's
    // code, and the name makes it invalid_args, the model's to correct.
    const tool_error = @import("../core/tool_error.zig");
    const seen = try tool_error.errorToJson(@errorName(error.InvalidRecurringWithoutCron), "{s}", .{detail.?}, a);
    defer a.free(seen);
    try testing.expect(std.mem.indexOf(u8, seen, "\"code\":\"invalid_args\",\"category\":\"user_error\"") != null);
    try testing.expect(std.mem.indexOf(u8, seen, "recurring: true needs a cron expression") != null);
    try testing.expect(std.mem.indexOf(u8, seen, "nothing was scheduled") != null);
}

test "CronCreate: a cron expression is recurring by default" {
    const a = testing.allocator;
    var reg = CronRegistry.init(a);
    defer reg.deinit();
    var ctx = ToolContext.simple(a);
    ctx.cron_registry = &reg;

    // Also with delaySeconds, which sets the first fire.
    for ([_][]const u8{
        "{\"cron\":\"*/5 * * * *\",\"prompt\":\"check deploy\"}",
        "{\"cron\":\"*/5 * * * *\",\"delaySeconds\":30,\"prompt\":\"check deploy\"}",
    }) |args| {
        const out = try createExecute(&ctx, args);
        defer a.free(out);
        try testing.expect(std.mem.indexOf(u8, out, "\"recurring\":true") != null);
    }
    try testing.expectEqual(@as(usize, 2), reg.count());
    for (reg.jobs.items) |j| try testing.expect(j.recurring);
}
