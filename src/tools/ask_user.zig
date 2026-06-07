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

/// 一次调用最多问几个问题(用户决策:放宽到 9,比 cc 的 4 宽,鼓励一次问全)。
/// 必须 ≤ dialog 的 MAX_Q(栈数组容量);两者一起改,否则 4<nq≤MAX_Q 漏进 dialog 撞容量上限。
pub const MAX_QUESTIONS = 9;

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

fn optionPreview(o: std.json.Value) []const u8 {
    if (o != .object) return "";
    const pv = o.object.get("preview") orelse return "";
    return if (pv == .string) pv.string else "";
}

pub fn execute(ctx: *const ToolContext, args: []const u8) anyerror![]u8 {
    const allocator = ctx.allocator;

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, args, .{});
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return error.InvalidArgs;
    const qs_v = root.object.get("questions") orelse return error.MissingQuestions;
    if (qs_v != .array) return error.InvalidArgs;
    // 问题数 1-MAX_QUESTIONS。**参数校验先于 tty/环境检查**(schema-first,对齐 cc):否则超量问题
    // 漏进 dialog,>MAX_Q 时 run() 错误地 return InputAborted——把"参数超限"伪装成"用户取消"
    // (真 tty bug:9 问场景模型逐餐拆 → InputAborted,工具静默失败降级文本)。
    // 放宽到 9(用户决策:比 cc 的 4 宽,鼓励一次问全;wizard 单屏只画当前问 + 导航条切换,不撑屏)。
    // 仍设上限:对话框是单屏阻塞键盘导航,无限问会让用户在"答到第几个"里迷失。超限引导用 multiSelect。
    if (qs_v.array.items.len < 1 or qs_v.array.items.len > MAX_QUESTIONS) {
        if (ctx.error_detail) |slot| slot.* = std.fmt.allocPrint(
            allocator,
            "AskUserQuestion accepts 1-{d} questions but got {d}. Use multiSelect to let the user pick several options in one question, merge related items, or split into separate tool calls.",
            .{ MAX_QUESTIONS, qs_v.array.items.len },
        ) catch null;
        return error.TooManyQuestions;
    }

    // 非 TTY 且应答队列从未加载 → 拒绝(否则会吞掉 pipe 输入或死等)。
    if (std.c.isatty(0) == 0 and !answer_queue.wasLoaded()) return error.NotATty;

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
        if (ctx.ui_request_fn == null or ctx.ui_request_state == null) return error.NotATty;

        var qlist = std.ArrayList(AskQuestion).empty;
        defer qlist.deinit(allocator);
        for (qs_v.array.items) |q_v| {
            const options_v = try validateQuestion(q_v);
            var opts = std.ArrayList(AskOption).empty;
            errdefer opts.deinit(allocator);
            for (options_v.array.items) |o| {
                try opts.append(allocator, .{ .label = try optionLabel(o), .description = optionDesc(o), .preview = optionPreview(o) });
            }
            try qlist.append(allocator, .{
                .question = q_v.object.get("question").?.string, // validateQuestion 已确保 .string
                .header = questionHeader(q_v),
                .multi = questionMulti(q_v),
                .options = try opts.toOwnedSlice(allocator),
            });
        }
        defer for (qlist.items) |q| allocator.free(@constCast(q.options));

        // 统一 UI 请求:发 .ask_question,backend 渲染对话框,返回选中 label(s)(owned)。
        const ui_request = @import("../repl/ui_request.zig");
        const req = ui_request.UiRequest{ .ask_question = qlist.items };
        var resp: ui_request.UiResponse = undefined;
        _ = try ctx.requestUi(allocator, &req, &resp);
        // resp.answers owned by allocator → 转移进 answers(后续序列化用),用完统一 free。
        switch (resp) {
            .answers => |arr| {
                defer allocator.free(arr); // 释放外层 slice(元素所有权转移给 answers)
                for (arr) |ans| try answers.append(allocator, ans);
            },
            else => return error.NotATty, // backend 返回了非预期 tag(不该发生)
        }
    }

    // "Chat about this" 哨兵:用户选择放弃结构化问答转自由回复(对齐 cc onRespondToClaude)。
    // 任一答案是哨兵 → 不把它当答案塞模型,返回一句话提示让模型等用户自由输入。
    const ask_dialog = @import("../repl/tui/dialog/ask_question.zig");
    for (answers.items) |a| {
        if (std.mem.eql(u8, a, ask_dialog.CHAT_SENTINEL)) {
            return try allocator.dupe(u8,
                \\{"user_chose_free_response":true,"note":"User dismissed the structured question to reply in their own words. Wait for their next message; do not re-ask."}
            );
        }
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

test "AskUserQuestion: >9 问 → TooManyQuestions(早失败,不漏进 dialog 变 InputAborted)" {
    // 真 tty bug:超量问题 run() 返 InputAborted,模型误解为"用户取消/环境不支持"降级文本。
    // 修:工具层校验 1-MAX_QUESTIONS(9),超限清晰报错让模型用 multiSelect/合并/拆分。
    const a = std.testing.allocator;
    answer_queue.load("1"); // 即便有应答队列,也应在校验阶段早失败(校验先于队列消费)。
    defer answer_queue.resetForTest();
    var err_detail: ?[]const u8 = null;
    const ctx = ToolContext{ .allocator = a, .error_detail = &err_detail };
    // 10 个问题(>9)。
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try buf.appendSlice(a, "{\"questions\":[");
    for (0..10) |i| {
        if (i > 0) try buf.append(a, ',');
        try buf.print(a, "{{\"question\":\"q{d}\",\"options\":[{{\"label\":\"a\"}},{{\"label\":\"b\"}}]}}", .{i});
    }
    try buf.appendSlice(a, "]}");
    try std.testing.expectError(error.TooManyQuestions, execute(&ctx, buf.items));
    // 富 detail 写入,含上限提示(模型可见,引导 multiSelect/合并/拆分)。
    try std.testing.expect(err_detail != null);
    defer if (err_detail) |d| a.free(@constCast(d));
    try std.testing.expect(std.mem.indexOf(u8, err_detail.?, "1-9 questions") != null);
    try std.testing.expect(std.mem.indexOf(u8, err_detail.?, "multiSelect") != null);
}

test "AskUserQuestion: 0 问 → TooManyQuestions(min 1)" {
    const a = std.testing.allocator;
    var err_detail: ?[]const u8 = null;
    const ctx = ToolContext{ .allocator = a, .error_detail = &err_detail };
    defer if (err_detail) |d| a.free(@constCast(d));
    try std.testing.expectError(error.TooManyQuestions, execute(&ctx, "{\"questions\":[]}"));
}

test "AskUserQuestion: 恰好 9 问通过校验(放宽后边界,经应答队列)" {
    const a = std.testing.allocator;
    answer_queue.load("1"); // 队列只 1 项,其余 8 问走"队列耗尽→首选项兜底"路径(不读 fd)。
    defer answer_queue.resetForTest();
    const ctx = ToolContext{ .allocator = a };
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(a);
    try buf.appendSlice(a, "{\"questions\":[");
    for (0..9) |i| { // 恰好 MAX_QUESTIONS
        if (i > 0) try buf.append(a, ',');
        try buf.print(a, "{{\"question\":\"q{d}\",\"options\":[{{\"label\":\"a{d}\"}},{{\"label\":\"b{d}\"}}]}}", .{ i, i, i });
    }
    try buf.appendSlice(a, "]}");
    const out = try execute(&ctx, buf.items); // 不应 TooManyQuestions
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"answers\"") != null);
}

test "AskUserQuestion rejects non-tty" {
    // zig test 环境不是 tty，合法参数(1 问)应返 NotATty(参数校验通过后才到 tty 检查)。
    const a = std.testing.allocator;
    const ctx = ToolContext{ .allocator = a };
    const args =
        \\{"questions":[{"question":"q","options":[{"label":"a"},{"label":"b"}]}]}
    ;
    try std.testing.expectError(error.NotATty, execute(&ctx, args));
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

test "AskUserQuestion: Chat about this 哨兵 → 自由回复结果(不当答案塞模型,bug2)" {
    const a = std.testing.allocator;
    const ask_dialog = @import("../repl/tui/dialog/ask_question.zig");
    // 经应答队列喂哨兵(resolveAnswer 非数字/非匹配 label → 原文透传),模拟对话框选 Chat。
    answer_queue.load(ask_dialog.CHAT_SENTINEL);
    defer answer_queue.resetForTest();
    const ctx = ToolContext{ .allocator = a };
    const args =
        \\{"questions":[{"question":"pick","options":[{"label":"apple"},{"label":"banana"}]}]}
    ;
    const out = try execute(&ctx, args);
    defer a.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "user_chose_free_response") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"answers\"") == null); // 绝不把哨兵当 answer 输出
    // 哨兵本身(含 NUL)不得泄漏进结果。
    try std.testing.expect(std.mem.indexOf(u8, out, ask_dialog.CHAT_SENTINEL) == null);
}
