//! AskUserQuestion：Claude 主动向用户提问，阻塞等答复。
//!
//! schema(对齐真实 Claude Code AskUserQuestion):
//! - input: `{"questions":[{"question":"...","header":"...","options":[{"label":"...","description":"..."}],"multiSelect":false}]}`
//!   - question(必填)/header(可选,短标签)/options(2-4 条 {label,description,preview?} 对象)/multiSelect(默认 false)。
//! - 非 TTY：直接 error(不能 block pipe);应答队列加载时例外。
//! - TTY：打印 header + 问题 + 带数字的选项(label[ — description]),读一行。
//!   - 单选:读一个数字 → 选中 label。
//!   - 多选(multiSelect=true):读逗号分隔数字(如 1,3)→ 多个 label 用 ", " 拼接。
//!
//! 返回: {"answers":["label" 或 "labelA, labelB"]}

const std = @import("std");
const common = @import("common.zig");
const util_json = @import("../util/json.zig");
const answer_queue = @import("../core/answer_queue.zig");
const ToolContext = @import("context.zig").ToolContext;

/// 从 option 对象取 label(必有);非对象或无 label → error。
fn optionLabel(o: std.json.Value) ![]const u8 {
    if (o != .object) return error.InvalidArgs;
    const lv = o.object.get("label") orelse return error.InvalidArgs;
    if (lv != .string) return error.InvalidArgs;
    return lv.string;
}

/// 从 option 对象取 description(可选);无/非字符串 → "".
fn optionDesc(o: std.json.Value) []const u8 {
    if (o != .object) return "";
    const dv = o.object.get("description") orelse return "";
    return if (dv == .string) dv.string else "";
}

pub fn execute(ctx: *const ToolContext, args: []const u8) anyerror![]u8 {
    const allocator = ctx.allocator;

    // 非 TTY 且应答队列从未加载 → 拒绝(否则会吞掉 pipe 输入或死等)。
    if (std.c.isatty(0) == 0 and !answer_queue.wasLoaded()) return error.NotATty;

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
        // header(可选,短标签;无则 "");multiSelect(可选,默认 false)。
        const header: []const u8 = if (q_v.object.get("header")) |h|
            (if (h == .string) h.string else "")
        else
            "";
        const multi: bool = if (q_v.object.get("multiSelect")) |m|
            (m == .bool and m.bool)
        else
            false;
        // 校验每个 option 都有合法 label(早失败,不进交互/队列)。
        for (options_v.array.items) |o| _ = try optionLabel(o);

        // 预置应答队列(Stage 3 e2e):弹一条作为本问应答。
        if (answer_queue.wasLoaded()) {
            if (answer_queue.pop()) |picked| {
                const ans = try resolveAnswer(picked, options_v.array.items, multi, allocator);
                try answers.append(allocator, ans);
            } else {
                // 队列耗尽但曾加载 → 用第一个 option 的 label 兜底(绝不读 fd 0 死等)。
                const txt = try optionLabel(options_v.array.items[0]);
                try answers.append(allocator, try allocator.dupe(u8, txt));
            }
            continue;
        }

        const ans = try askOne(question_v.string, header, options_v.array.items, multi, allocator);
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

/// 打印 header + 问题 + 选项(label[ — desc]),读用户输入。返回选中 label(s)(owned)。
/// 单选:一个数字。多选:逗号分隔数字(如 1,3),label 用 ", " 拼接。
fn askOne(question: []const u8, header: []const u8, options: []const std.json.Value, multi: bool, allocator: std.mem.Allocator) ![]const u8 {
    // 打印到 stderr(不污染 stdout 的工具输出流)。
    if (header.len > 0) std.debug.print("\n\x1b[2m{s}\x1b[0m", .{header});
    std.debug.print("\n\x1b[1m? {s}\x1b[0m\n", .{question});
    for (options, 0..) |o, idx| {
        const label = try optionLabel(o);
        const desc = optionDesc(o);
        if (desc.len > 0) {
            std.debug.print("  \x1b[36m{d})\x1b[0m {s} \x1b[2m— {s}\x1b[0m\n", .{ idx + 1, label, desc });
        } else {
            std.debug.print("  \x1b[36m{d})\x1b[0m {s}\n", .{ idx + 1, label });
        }
    }

    while (true) {
        if (multi) {
            std.debug.print("Choose (逗号分隔多个, 如 1,3) [1-{d}]: ", .{options.len});
        } else {
            std.debug.print("Choose [1-{d}]: ", .{options.len});
        }
        var line_buf: [256]u8 = undefined;
        const n = std.c.read(0, &line_buf, line_buf.len);
        if (n <= 0) return error.InputAborted;
        const line = std.mem.trim(u8, line_buf[0..@intCast(n)], " \t\r\n");
        if (line.len == 0) continue;

        if (multi) {
            // 解析逗号分隔的数字,收集选中 label,用 ", " 拼接。
            if (try parseMultiChoice(line, options, allocator)) |joined| return joined;
            continue; // 解析失败 → 重提示
        }
        const choice = std.fmt.parseInt(usize, line, 10) catch continue;
        if (choice < 1 or choice > options.len) continue;
        return try allocator.dupe(u8, try optionLabel(options[choice - 1]));
    }
}

/// 解析逗号分隔的数字序号(1-based),返回选中 label 用 ", " 拼接(owned)。
/// 任一序号越界/非数字 → 返回 null(调用方重提示)。空选 → null。
fn parseMultiChoice(line: []const u8, options: []const std.json.Value, allocator: std.mem.Allocator) !?[]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var it = std.mem.tokenizeScalar(u8, line, ',');
    var count: usize = 0;
    while (it.next()) |tok| {
        const t = std.mem.trim(u8, tok, " \t");
        if (t.len == 0) continue;
        const choice = std.fmt.parseInt(usize, t, 10) catch {
            out.deinit(allocator);
            return null;
        };
        if (choice < 1 or choice > options.len) {
            out.deinit(allocator);
            return null;
        }
        if (count > 0) try out.appendSlice(allocator, ", ");
        try out.appendSlice(allocator, try optionLabel(options[choice - 1]));
        count += 1;
    }
    if (count == 0) {
        out.deinit(allocator);
        return null;
    }
    return try out.toOwnedSlice(allocator);
}

/// 把预置应答(数字序号 或 label 文本 或 多选逗号分隔)解析成选中 label(s)(owned)。
/// 单选:数字 N → options[N-1].label;否则按 label 精确匹配;都不匹配 → 原文。
/// 多选:逗号分隔数字 → 多个 label 拼接(同 parseMultiChoice)。
fn resolveAnswer(picked: []const u8, options: []const std.json.Value, multi: bool, allocator: std.mem.Allocator) ![]const u8 {
    if (multi) {
        if (try parseMultiChoice(picked, options, allocator)) |joined| return joined;
        // 多选解析失败 → 原文 dupe(可能是直接给的 label 文本)。
        return allocator.dupe(u8, picked);
    }
    if (std.fmt.parseInt(usize, picked, 10)) |idx| {
        if (idx >= 1 and idx <= options.len) {
            return allocator.dupe(u8, try optionLabel(options[idx - 1]));
        }
    } else |_| {}
    for (options) |o| {
        const label = try optionLabel(o);
        if (std.mem.eql(u8, label, picked)) return allocator.dupe(u8, label);
    }
    return allocator.dupe(u8, picked);
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

test "AskUserQuestion: 对象数组 options 经应答队列解析(单选数字)" {
    const a = std.testing.allocator;
    answer_queue.load("2"); // 选第 2 项
    defer answer_queue.resetForTest();
    const ctx = ToolContext{ .allocator = a };
    const args =
        \\{"questions":[{"question":"pick","header":"H","options":[{"label":"apple","description":"red"},{"label":"banana","description":"yellow"}]}]}
    ;
    const out = try execute(&ctx, args);
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "banana") != null);
}

test "AskUserQuestion: 多选逗号分隔 → label 拼接" {
    const a = std.testing.allocator;
    answer_queue.load("1,3");
    defer answer_queue.resetForTest();
    const ctx = ToolContext{ .allocator = a };
    const args =
        \\{"questions":[{"question":"pick","options":[{"label":"a"},{"label":"b"},{"label":"c"}],"multiSelect":true}]}
    ;
    const out = try execute(&ctx, args);
    defer a.free(out);
    // 选 1,3 → "a, c"
    try std.testing.expect(std.mem.indexOf(u8, out, "a, c") != null);
}

test "AskUserQuestion: label 文本应答(非数字)精确匹配" {
    const a = std.testing.allocator;
    answer_queue.load("banana");
    defer answer_queue.resetForTest();
    const ctx = ToolContext{ .allocator = a };
    const args =
        \\{"questions":[{"question":"pick","options":[{"label":"apple"},{"label":"banana"}]}]}
    ;
    const out = try execute(&ctx, args);
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "banana") != null);
}

test "AskUserQuestion: 字符串数组 options(旧格式)→ InvalidArgs(真实 schema 是对象)" {
    const a = std.testing.allocator;
    answer_queue.load("1");
    defer answer_queue.resetForTest();
    const ctx = ToolContext{ .allocator = a };
    // 旧格式 options:["a","b"] 现在应被拒(label 取不到)。
    const args =
        \\{"questions":[{"question":"pick","options":["a","b"]}]}
    ;
    try std.testing.expectError(error.InvalidArgs, execute(&ctx, args));
}
