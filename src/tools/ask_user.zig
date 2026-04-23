//! AskUserQuestion：Claude 主动向用户提问，阻塞等答复。
//!
//! 简化实现（一期）：
//! - input: `{"questions":[{"question":"...","options":["a","b","c"]}]}`
//!   单个或多个问题，每个带选项列表（2-4 条）。
//! - 非 TTY：直接 error（不能 block pipe）。
//! - TTY：打印问题 + 带数字的选项，读一行数字，回答即选中的 option。
//! - 多选问题一次一问，不支持 multiSelect（P2）。
//!
//! 返回: {"answers":["..."]}

const std = @import("std");
const common = @import("common.zig");
const util_json = @import("../util/json.zig");
const ToolContext = @import("context.zig").ToolContext;

pub fn execute(ctx: *const ToolContext, args: []const u8) anyerror![]u8 {
    const allocator = ctx.allocator;

    // 非 TTY 下拒绝（否则会吞掉 pipe 输入或死等）
    if (std.c.isatty(0) == 0) return error.NotATty;

    // 解析 questions 数组。用 std.json.parseFromSlice 取 root.object.get("questions")。
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, args, .{});
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return error.InvalidArgs;
    const qs_v = root.object.get("questions") orelse return error.MissingQuestions;
    if (qs_v != .array) return error.InvalidArgs;

    var answers = std.ArrayList([]const u8).empty;
    defer {
        for (answers.items) |a| allocator.free(a);
        answers.deinit(allocator);
    }

    for (qs_v.array.items) |q_v| {
        if (q_v != .object) return error.InvalidArgs;
        const question_v = q_v.object.get("question") orelse return error.InvalidArgs;
        const options_v = q_v.object.get("options") orelse return error.InvalidArgs;
        if (question_v != .string or options_v != .array) return error.InvalidArgs;
        if (options_v.array.items.len < 2 or options_v.array.items.len > 4) return error.InvalidArgs;

        const ans = try askOne(question_v.string, options_v.array.items, allocator);
        try answers.append(allocator, ans);
    }

    // 序列化 answers
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    try aw.writer.writeAll("{\"answers\":[");
    for (answers.items, 0..) |a, i| {
        if (i > 0) try aw.writer.writeAll(",");
        try std.json.Stringify.encodeJsonString(a, .{}, &aw.writer);
    }
    try aw.writer.writeAll("]}");
    return try aw.toOwnedSlice();
}

/// 打印问题 + 选项，读用户输入。返回被选中的 option text（owned）。
fn askOne(question: []const u8, options: []const std.json.Value, allocator: std.mem.Allocator) ![]const u8 {
    // 打印到 stderr（不污染 stdout 的工具输出流）
    std.debug.print("\n\x1b[1m? {s}\x1b[0m\n", .{question});
    for (options, 0..) |o, idx| {
        if (o != .string) return error.InvalidArgs;
        std.debug.print("  \x1b[36m{d})\x1b[0m {s}\n", .{ idx + 1, o.string });
    }

    while (true) {
        std.debug.print("Choose [1-{d}]: ", .{options.len});
        // 读一行
        var line_buf: [256]u8 = undefined;
        const n = std.c.read(0, &line_buf, line_buf.len);
        if (n <= 0) return error.InputAborted;
        const line = std.mem.trim(u8, line_buf[0..@intCast(n)], " \t\r\n");
        if (line.len == 0) continue;

        const choice = std.fmt.parseInt(usize, line, 10) catch continue;
        if (choice < 1 or choice > options.len) continue;
        return try allocator.dupe(u8, options[choice - 1].string);
    }
}

// ============================================================================
// Tests
// ============================================================================

test "AskUserQuestion rejects non-tty" {
    // zig test 环境不是 tty，execute 应返 NotATty
    const a = std.testing.allocator;
    const ctx = ToolContext{ .allocator = a };
    try std.testing.expectError(error.NotATty, execute(&ctx, "{\"questions\":[]}"));
}
