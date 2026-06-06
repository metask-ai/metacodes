//! Transcript viewer:Ctrl+O 打开的对话浏览器。
//!
//! **inline 内联模式(对齐 cc 2.1.167,DIFF#6/#7)**:不进 alt-screen,不 2J 清屏——
//! 用绝对光标定位(`ESC[{r};1H` + `ESC[2K`)原地重绘整个可见视口(像 cc 全帧管理)。
//! 关键正确性:绝不 emit 滚动用的 `\n`(会把内容推进 scrollback 毁历史),只用光标定位。
//! 退出时重绘对话尾部 + 交还给 loop.zig 重画输入框(对齐 cc 关闭后历史+输入框可见)。
//!
//! 键(对齐 cc:↑↓ 主滚动 + ctrl+o toggle;保留 vim 键作增强):
//!   ↓ / j / Space   向下滚一行       ↑ / k   向上滚一行
//!   { / }           上/下一条 user prompt
//!   g / G           顶 / 底
//!   q / Esc / Ctrl+O 退出(ctrl+o 对称开关)
//!
//! 本模块拆两层:
//!   - renderToLines:把 Conversation 渲染成行数组(纯函数,可单测)
//!   - runWithTheme:inline 交互循环(从 loop.zig 调,需要 tty)

const std = @import("std");
const Conversation = @import("../core/conversation.zig").Conversation;

/// 把整个对话渲染成可显示的行(owned;caller free 每行 + 数组)。
/// 每条 message 前加 role 头;tool_use/tool_result 用缩进 + 标记区分。
pub fn renderToLines(allocator: std.mem.Allocator, conv: *const Conversation) ![][]u8 {
    return renderToLinesWithTheme(allocator, conv, @import("tui/theme.zig").dark);
}

pub fn renderToLinesWithTheme(allocator: std.mem.Allocator, conv: *const Conversation, th: @import("tui/theme.zig").Theme) ![][]u8 {
    const tool_card = @import("tui/widget/tool_card.zig");
    // 全程持 snapshot 锁:遍历 conv.messages.items 期间禁止 append(realloc 会抽走 items
    // 底层 buffer → UAF)。生成期 watcher 线程经此读快照,与主线程 agent_loop 的 append 互斥。
    // mutex 是同步原语,@constCast 取可变指针不算逻辑修改 conv。锁持有时间 = 一次渲染(O(msgs)),
    // append 一轮几次故阻塞可忽略。
    const mut_conv = @constCast(conv);
    mut_conv.lockSnapshot();
    defer mut_conv.unlockSnapshot();

    var lines = std.ArrayList([]u8).empty;
    errdefer {
        for (lines.items) |l| allocator.free(l);
        lines.deinit(allocator);
    }

    // 先建 tool_use_id → {name,input} 查表,供 tool_result 用 renderResult 走逐工具渲染器
    // (Edit diff 着色 / 搜索摘要 / Read 摘要)。borrow 自 conversation,无需 free。
    const ToolMeta = struct { name: []const u8, input: []const u8 };
    var tool_meta = std.StringHashMap(ToolMeta).init(allocator);
    defer tool_meta.deinit();
    for (conv.messages.items) |m| {
        for (m.blocks) |b| {
            if (b == .tool_use) try tool_meta.put(b.tool_use.id, .{ .name = b.tool_use.name, .input = b.tool_use.input });
        }
    }

    for (conv.messages.items) |m| {
        const role_label = switch (m.role) {
            .user => try std.fmt.allocPrint(allocator, "{s}▶ user{s}", .{ th.role_user, th.reset }),
            .assistant => try std.fmt.allocPrint(allocator, "{s}◀ assistant{s}", .{ th.role_assistant, th.reset }),
        };
        try lines.append(allocator, role_label);

        for (m.blocks) |b| {
            switch (b) {
                .text => |t| try appendWrapped(allocator, &lines, t, "  "),
                .tool_use => |tu| {
                    // tool_card.renderStart 输出多行字符串(2 行带 ANSI);split 进 lines。
                    const card = try tool_card.renderStart(allocator, th, tu.name, tu.input);
                    defer allocator.free(card);
                    var pos: usize = 0;
                    while (pos < card.len) {
                        const eol = std.mem.indexOfScalarPos(u8, card, pos, '\n') orelse card.len;
                        if (eol > pos) {
                            // 加 2 空格缩进
                            const indented = try std.fmt.allocPrint(allocator, "  {s}", .{card[pos..eol]});
                            try lines.append(allocator, indented);
                        }
                        pos = eol + 1;
                    }
                },
                .tool_result => |tr| {
                    // 用 renderResult 走逐工具渲染器(Edit diff 着色 / 搜索摘要 / Read 摘要);
                    // transcript 视图展开(verbose 语义)。查不到 tool_use 则用空名走通用折叠。
                    const meta = tool_meta.get(tr.tool_use_id);
                    const t_name: []const u8 = if (meta) |mm| mm.name else "";
                    const t_input: []const u8 = if (meta) |mm| mm.input else "{}";
                    const kind: tool_card.ResultKind = if (tr.is_error) .err else .ok;
                    const card = try tool_card.renderResult(allocator, th, t_name, t_input, tr.content, kind, 0, .{ .transcript = true });
                    defer allocator.free(card);
                    var pos: usize = 0;
                    while (pos < card.len) {
                        const eol = std.mem.indexOfScalarPos(u8, card, pos, '\n') orelse card.len;
                        if (eol > pos) {
                            const indented = try std.fmt.allocPrint(allocator, "  {s}", .{card[pos..eol]});
                            try lines.append(allocator, indented);
                        }
                        pos = eol + 1;
                    }
                },
                .thinking => |t| {
                    // 思考块:头标 + 折叠内容(前 3 行)
                    const head = try std.fmt.allocPrint(allocator, "  {s}{s} thinking{s}", .{ th.role_thinking, th.icon_thinking, th.reset });
                    try lines.append(allocator, head);
                    try appendWrappedFolded(allocator, &lines, t, "    ", th.dim, th.reset, 3);
                },
            }
        }
        try lines.append(allocator, try allocator.dupe(u8, "")); // 空行分隔
    }

    return try lines.toOwnedSlice(allocator);
}

/// 按 '\n' 拆 text,每行加前缀。(不做列宽 wrap,终端自己软换行)
fn appendWrapped(allocator: std.mem.Allocator, lines: *std.ArrayList([]u8), text: []const u8, prefix: []const u8) !void {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |seg| {
        const line = try std.fmt.allocPrint(allocator, "{s}{s}\x1b[0m", .{ prefix, seg });
        try lines.append(allocator, line);
    }
}

/// 带折叠的 wrapped:超过 max_lines 后,后续行省略,加 "… N more lines"。
fn appendWrappedFolded(
    allocator: std.mem.Allocator,
    lines: *std.ArrayList([]u8),
    text: []const u8,
    prefix: []const u8,
    color: []const u8,
    reset: []const u8,
    max_lines: u16,
) !void {
    // 先算总行数
    var total: u32 = 0;
    {
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |_| total += 1;
    }
    var emitted: u32 = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |seg| {
        if (emitted >= max_lines) break;
        const line = try std.fmt.allocPrint(allocator, "{s}{s}{s}{s}", .{ prefix, color, seg, reset });
        try lines.append(allocator, line);
        emitted += 1;
    }
    if (total > max_lines) {
        const more = total - max_lines;
        const line = try std.fmt.allocPrint(allocator, "{s}{s}… {d} more lines{s}", .{ prefix, color, more, reset });
        try lines.append(allocator, line);
    }
}

/// 找所有 user prompt 在 lines 里的行号(用于 { } 跳转)。
pub fn userPromptLineIndices(allocator: std.mem.Allocator, lines: []const []const u8) ![]usize {
    var idx = std.ArrayList(usize).empty;
    errdefer idx.deinit(allocator);
    for (lines, 0..) |l, i| {
        if (std.mem.indexOf(u8, l, "▶ user") != null) try idx.append(allocator, i);
    }
    return try idx.toOwnedSlice(allocator);
}

pub fn freeLines(allocator: std.mem.Allocator, lines: [][]u8) void {
    for (lines) |l| allocator.free(l);
    allocator.free(lines);
}

/// inline 交互循环。fd = stdin。rows = 终端高度(末 1 行给提示)。
/// 进 alt screen → 渲染 → 处理键 → 退出恢复。(签名保留,内部已改 inline 内联,见模块头注)
pub fn run(fd: std.c.fd_t, allocator: std.mem.Allocator, conv: *const Conversation, rows: usize) !void {
    return runWithTheme(fd, allocator, conv, rows, @import("tui/theme.zig").dark);
}

pub fn runWithTheme(fd: std.c.fd_t, allocator: std.mem.Allocator, conv: *const Conversation, rows: usize, th: @import("tui/theme.zig").Theme) !void {
    const lines = try renderToLinesWithTheme(allocator, conv, th);
    defer freeLines(allocator, lines);
    const prompts = try userPromptLineIndices(allocator, lines);
    defer allocator.free(prompts);

    const cols = blk: {
        const sz = @import("tui/term.zig").getSize(fd) orelse break :blk @as(usize, 80);
        break :blk @as(usize, sz.cols);
    };

    // inline 内联:不进 alt-screen。保存光标 + 隐藏(DECSC),退出时恢复(DECRC)。
    writeAll(1, "\x1b[?25l"); // hide cursor
    defer writeAll(1, "\x1b[?25h"); // show cursor

    // 视口:末 2 行留给 footer(对齐 cc:分隔线 + 提示)。
    const footer_rows: usize = 2;
    const view_rows = if (rows > footer_rows + 1) rows - footer_rows - 1 else 1;
    var top: usize = 0;
    const max_top = if (lines.len > view_rows) lines.len - view_rows else 0;
    top = max_top; // 对齐 cc:打开时定位到底部(最新)

    // 简单 ESC 序列解析:↑=\x1b[A ↓=\x1b[B。esc 单独=退出。
    while (true) {
        drawScreenInline(lines, top, view_rows, rows, cols, th);
        var b: [1]u8 = undefined;
        const n = std.c.read(fd, &b, 1);
        if (n <= 0) break;
        const c = b[0];
        if (c == 0x1b) {
            // 可能是方向键 CSI 或单 Esc。读后续两字节判定。
            var s0: [1]u8 = undefined;
            const n2 = std.c.read(fd, &s0, 1);
            if (n2 <= 0) break; // 裸 Esc → 退出
            if (s0[0] == '[') {
                var s1: [1]u8 = undefined;
                const n3 = std.c.read(fd, &s1, 1);
                if (n3 <= 0) break;
                switch (s1[0]) {
                    'A' => top = if (top > 0) top - 1 else 0, // ↑
                    'B' => top = @min(top + 1, max_top), // ↓
                    else => {},
                }
                continue;
            }
            break; // Esc + 非 [ → 退出
        }
        switch (c) {
            'q', 0x03, 0x0f => break, // q / Ctrl+C / Ctrl+O(对称开关)
            'j', ' ' => top = @min(top + 1, max_top),
            'k' => top = if (top > 0) top - 1 else 0,
            'g' => top = 0,
            'G' => top = max_top,
            'd' => top = @min(top + view_rows / 2, max_top),
            'u' => top = if (top > view_rows / 2) top - view_rows / 2 else 0,
            '}' => top = @min(nextPrompt(prompts, top), max_top),
            '{' => top = prevPrompt(prompts, top),
            else => {},
        }
    }

    // 退出:重建"正常视图"的可见视口(对齐 cc 关闭后形态:历史尾 + 底部输入框)。
    // 关键正确性(守住 test_ctrl_o_bottom_anchored_idempotent):用绝对光标定位重绘,**不 2J、
    // 不 emit \n 滚动**——把对话尾部 N 行填到上方,光标停在"输入框锚定行"(rows - box_h),
    // loop.zig 随后从此处 redraw 输入框 → 框回到屏底原位,scrollback 不被毁。
    const box_h: usize = 5; // 上框(1)+❯(1)+下框(1)+footer(1)+底部余量(1);使框回原 box_top
    const tail_rows: usize = if (rows > box_h) rows - box_h else 1;
    // 对话尾部起始行:lines 末 tail_rows 行(不足则从 0)。
    const tail_start: usize = if (lines.len > tail_rows) lines.len - tail_rows else 0;
    {
        var nb: [16]u8 = undefined;
        writeAll(1, "\x1b[H");
        var rr: usize = 0;
        var li: usize = tail_start;
        while (rr < tail_rows) : (rr += 1) {
            writeAll(1, std.fmt.bufPrint(&nb, "\x1b[{d};1H\x1b[2K", .{rr + 1}) catch "");
            if (li < lines.len) {
                writeAll(1, lines[li]);
                li += 1;
            }
        }
        // 清掉 box 区那几行(redraw 会重画),光标停在锚定行(tail_rows+1)。
        var cr: usize = tail_rows;
        while (cr < rows) : (cr += 1) {
            writeAll(1, std.fmt.bufPrint(&nb, "\x1b[{d};1H\x1b[2K", .{cr + 1}) catch "");
        }
        writeAll(1, std.fmt.bufPrint(&nb, "\x1b[{d};1H", .{tail_rows + 1}) catch "");
    }
}

fn nextPrompt(prompts: []const usize, cur: usize) usize {
    for (prompts) |p| {
        if (p > cur) return p;
    }
    return cur;
}

fn prevPrompt(prompts: []const usize, cur: usize) usize {
    var result: usize = 0;
    for (prompts) |p| {
        if (p < cur) result = p else break;
    }
    return result;
}

/// inline 内联重绘整个可见视口(对齐 cc:绝对光标定位 + 逐行 ESC[2K,**不 2J、不 emit \n**)。
/// 顶部 view_rows 行画 transcript 内容,末两行画 cc 风格 footer(分隔线 + 提示)。
fn drawScreenInline(lines: []const []const u8, top: usize, view_rows: usize, rows: usize, cols: usize, th: @import("tui/theme.zig").Theme) void {
    var nbuf: [16]u8 = undefined;
    // 光标 home。
    writeAll(1, "\x1b[H");
    var r: usize = 0;
    var i: usize = top;
    while (r < view_rows) : (r += 1) {
        // 绝对定位到第 r+1 行行首 + 清行。
        writeAll(1, std.fmt.bufPrint(&nbuf, "\x1b[{d};1H\x1b[2K", .{r + 1}) catch "");
        if (i < lines.len) {
            writeAll(1, lines[i]);
            i += 1;
        }
    }
    // 分隔线行(view_rows+1)。
    const sep_row = view_rows + 1;
    writeAll(1, std.fmt.bufPrint(&nbuf, "\x1b[{d};1H\x1b[2K", .{sep_row}) catch "");
    writeAll(1, th.dim);
    var k: usize = 0;
    const sep_w = if (cols > 0) cols else 80;
    while (k < sep_w) : (k += 1) writeAll(1, "\xe2\x94\x80"); // ─
    writeAll(1, th.reset);
    // footer 提示行(对齐 cc):`Showing detailed transcript · ctrl+o to toggle · ↑↓ scroll · ? for shortcuts`。
    const foot_row = view_rows + 2;
    writeAll(1, std.fmt.bufPrint(&nbuf, "\x1b[{d};1H\x1b[2K", .{foot_row}) catch "");
    writeAll(1, th.dim);
    writeAll(1, "  Showing detailed transcript · ctrl+o to toggle · ↑↓ scroll · q quit");
    writeAll(1, th.reset);
    _ = rows;
}

fn writeAll(fd: std.c.fd_t, bytes: []const u8) void {
    var total: usize = 0;
    while (total < bytes.len) {
        const n = std.c.write(fd, bytes.ptr + total, bytes.len - total);
        if (n <= 0) return;
        total += @intCast(n);
    }
}

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

test "renderToLines: user + assistant + tool" {
    const a = testing.allocator;
    var conv = Conversation.init(a);
    defer conv.deinit();
    try conv.appendText(.user, "fix the bug");
    try conv.appendText(.assistant, "Looking at it.\nFound it.");

    const lines = try renderToLines(a, &conv);
    defer freeLines(a, lines);

    // 至少含 user 头 + assistant 头 + 两行 text
    var has_user = false;
    var has_asst = false;
    var has_found = false;
    for (lines) |l| {
        if (std.mem.indexOf(u8, l, "user") != null) has_user = true;
        if (std.mem.indexOf(u8, l, "assistant") != null) has_asst = true;
        if (std.mem.indexOf(u8, l, "Found it") != null) has_found = true;
    }
    try testing.expect(has_user);
    try testing.expect(has_asst);
    try testing.expect(has_found);
}

test "renderToLines: Edit tool_result 经 renderResult 出 diff 着色" {
    const a = testing.allocator;
    const msg = @import("../core/message.zig");
    var conv = Conversation.init(a);
    defer conv.deinit();

    // assistant 发起 Edit tool_use
    {
        const blocks = try a.alloc(msg.Block, 1);
        blocks[0] = .{ .tool_use = .{
            .id = try a.dupe(u8, "tu_1"),
            .name = try a.dupe(u8, "Edit"),
            .input = try a.dupe(u8, "{\"file_path\":\"/x.zig\"}"),
        } };
        try conv.append(.{ .role = .assistant, .blocks = blocks });
    }
    // user 回 tool_result(含 gitDiff)
    {
        const blocks = try a.alloc(msg.Block, 1);
        blocks[0] = .{ .tool_result = .{
            .tool_use_id = try a.dupe(u8, "tu_1"),
            .content = try a.dupe(u8, "{\"success\":true,\"path\":\"/x.zig\",\"gitDiff\":\"--- a/x.zig\\n+++ b/x.zig\\n@@ -1,1 +1,1 @@\\n-const b = 2;\\n+const b = 20;\\n\"}"),
            .is_error = false,
        } };
        try conv.append(.{ .role = .user, .blocks = blocks });
    }

    const lines = try renderToLinesWithTheme(a, &conv, @import("tui/theme.zig").dark);
    defer freeLines(a, lines);

    var has_new = false;
    var has_old = false;
    var has_green = false;
    var has_red = false;
    const th = @import("tui/theme.zig").dark;
    for (lines) |l| {
        // 内容现经行内语法高亮(const→magenta、20→yellow),整句被 ANSI 切碎,
        // 故断言高亮无法拆开的片段:数字 20(+行)/ 行内 "b = "。
        if (std.mem.indexOf(u8, l, "20") != null) has_new = true;
        if (std.mem.indexOf(u8, l, "b = ") != null) has_old = true;
        if (std.mem.indexOf(u8, l, th.success) != null) has_green = true;
        if (std.mem.indexOf(u8, l, th.danger) != null) has_red = true;
    }
    try testing.expect(has_new); // + 行内容(数字 20)
    try testing.expect(has_old); // 行内 "b = " 片段
    try testing.expect(has_green); // + 行 success 着色
    try testing.expect(has_red); // - 行 danger 着色
}

test "userPromptLineIndices: finds user lines" {
    const a = testing.allocator;
    var conv = Conversation.init(a);
    defer conv.deinit();
    try conv.appendText(.user, "first");
    try conv.appendText(.assistant, "reply");
    try conv.appendText(.user, "second");

    const lines = try renderToLines(a, &conv);
    defer freeLines(a, lines);
    const prompts = try userPromptLineIndices(a, lines);
    defer a.free(prompts);
    try testing.expectEqual(@as(usize, 2), prompts.len);
    try testing.expect(prompts[0] < prompts[1]);
}

test "nextPrompt / prevPrompt navigation" {
    const prompts = [_]usize{ 0, 5, 12 };
    try testing.expectEqual(@as(usize, 5), nextPrompt(&prompts, 0));
    try testing.expectEqual(@as(usize, 12), nextPrompt(&prompts, 5));
    try testing.expectEqual(@as(usize, 12), nextPrompt(&prompts, 12)); // 末尾不动
    try testing.expectEqual(@as(usize, 5), prevPrompt(&prompts, 12));
    try testing.expectEqual(@as(usize, 0), prevPrompt(&prompts, 5));
    try testing.expectEqual(@as(usize, 0), prevPrompt(&prompts, 0));
}
