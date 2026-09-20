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

    const cron_raw = common.extractJsonArg(args, "cron");
    const cron_expr = if (cron_raw) |raw| try util_json.unescapeString(raw, a) else "";
    defer if (cron_raw != null) a.free(cron_expr);
    const delay_s: ?i64 = blk: {
        const v = common.extractJsonArg(args, "delaySeconds") orelse common.extractJsonArg(args, "delay_seconds");
        if (v) |s| break :blk std.fmt.parseInt(i64, s, 10) catch null;
        break :blk null;
    };
    if (cron_expr.len == 0 and delay_s == null) return error.MissingSchedule;

    const recurring = blk: {
        const v = common.extractJsonArg(args, "recurring") orelse break :blk true;
        break :blk !std.mem.eql(u8, v, "false");
    };

    const id = reg.create(cron_expr, delay_s, prompt, recurring) catch |err| {
        return try std.fmt.allocPrint(a, "{{\"error\":\"{s}\"}}", .{@errorName(err)});
    };

    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    try out.writer.writeAll("{\"id\":");
    try util_json.writeJsonString(&out.writer, id[0..]);
    try out.writer.print(",\"recurring\":{},\"scheduled\":true}}", .{recurring});
    return try out.toOwnedSlice();
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
        try util_json.writeJsonString(&out.writer, j.id[0..]);
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
