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
const context = @import("context.zig");
const ToolContext = context.ToolContext;
const AskQuestion = context.AskQuestion;
const AskOption = context.AskOption;

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
        for (answers.items) |a| allocator.free(@constCast(a));
        answers.deinit(allocator);
    }

    // 应答队列路径(Stage 3 e2e:非交互,逐问从队列弹应答)。校验同交互路径(早失败)。
    if (answer_queue.wasLoaded()) {
        for (qs_v.array.items) |q_v| {
            const options_v = try validateQuestion(q_v);
            const multi = questionMulti(q_v);
            if (answer_queue.pop()) |picked| {
                const ans = try resolveAnswer(picked, options_v.array.items, multi, allocator);
                try answers.append(allocator, ans);
            } else {
                // 队列耗尽但曾加载 → 用第一个 option 的 label 兜底(绝不读 fd 0 死等)。
                const txt = try optionLabel(options_v.array.items[0]);
                try answers.append(allocator, try allocator.dupe(u8, txt));
            }
        }
    } else {
        // 交互路径:校验 + 构造 []AskQuestion,经回调让 TUI backend(主线程)渲染可交互对话框。
        // 回调缺失(headless/WriterBackend/单测)→ NotATty(与非 tty 拒绝语义一致)。
        const ask_fn = ctx.ask_question_fn orelse return error.NotATty;
        const ask_state = ctx.ask_question_state orelse return error.NotATty;

        var qlist = std.ArrayList(AskQuestion).empty;
        defer qlist.deinit(allocator);
        for (qs_v.array.items) |q_v| {
            const options_v = try validateQuestion(q_v);
            var opts = std.ArrayList(AskOption).empty;
            errdefer opts.deinit(allocator);
            for (options_v.array.items) |o| {
                try opts.append(allocator, .{ .label = try optionLabel(o), .description = optionDesc(o) });
            }
            try qlist.append(allocator, .{
                .question = q_v.object.get("question").?.string, // validateQuestion 已确保 .string
                .header = questionHeader(q_v),
                .multi = questionMulti(q_v),
                .options = try opts.toOwnedSlice(allocator),
            });
        }
        defer for (qlist.items) |q| allocator.free(@constCast(q.options));

        try ask_fn(ask_state, allocator, qlist.items, &answers);
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

/// 校验单个 question 对象(question 是 string、options 是 2-4 长 array、每 option 有合法 label)。
/// 返回 options 的 json array Value(供两路径共用)。任一不合规 → InvalidArgs(早失败)。
fn validateQuestion(q_v: std.json.Value) !std.json.Value {
    if (q_v != .object) return error.InvalidArgs;
    const question_v = q_v.object.get("question") orelse return error.InvalidArgs;
    const options_v = q_v.object.get("options") orelse return error.InvalidArgs;
    if (question_v != .string or options_v != .array) return error.InvalidArgs;
    if (options_v.array.items.len < 2 or options_v.array.items.len > 4) return error.InvalidArgs;
    for (options_v.array.items) |o| _ = try optionLabel(o);
    return options_v;
}

/// header(可选短标签;无/非字符串 → "")。
fn questionHeader(q_v: std.json.Value) []const u8 {
    const h = q_v.object.get("header") orelse return "";
    return if (h == .string) h.string else "";
}

/// multiSelect(可选,默认 false)。
fn questionMulti(q_v: std.json.Value) bool {
    const m = q_v.object.get("multiSelect") orelse return false;
    return m == .bool and m.bool;
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
