//! Transcript viewer:Ctrl+O 打开的全屏对话浏览器。
//!
//! 用 alt screen(ESC[?1049h / ESC[?1049l)切到独立屏幕,渲染完整对话历史
//! (含 tool_use / tool_result 细节,主流程默认折叠),退出后恢复原屏。
//!
//! 键:
//!   j / ↓ / Space   向下滚一行
//!   k / ↑           向上滚一行
//!   { / }           上/下一条 user prompt
//!   g / G           顶 / 底
//!   q / Esc / Ctrl+C 退出
//!
//! 本模块拆两层:
//!   - renderToLines:把 Conversation 渲染成行数组(纯函数,可单测)
//!   - run:alt-screen 交互循环(从 loop.zig 调,需要 tty)

const std = @import("std");
const Conversation = @import("../core/conversation.zig").Conversation;

/// 把整个对话渲染成可显示的行(owned;caller free 每行 + 数组)。
/// 每条 message 前加 role 头;tool_use/tool_result 用缩进 + 标记区分。
pub fn renderToLines(allocator: std.mem.Allocator, conv: *const Conversation) ![][]u8 {
    return renderToLinesWithTheme(allocator, conv, @import("tui/theme.zig").dark);
}

pub fn renderToLinesWithTheme(allocator: std.mem.Allocator, conv: *const Conversation, th: @import("tui/theme.zig").Theme) ![][]u8 {
    const tool_card = @import("tui/widget/tool_card.zig");
    var lines = std.ArrayList([]u8).empty;
    errdefer {
        for (lines.items) |l| allocator.free(l);
        lines.deinit(allocator);
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
                    // 状态符 + 分隔线 + 折叠输出(最多 5 行)
                    const marker_color = if (tr.is_error) th.danger else th.success;
                    const marker_icon = if (tr.is_error) th.icon_cross else th.icon_check;
                    const marker_line = try std.fmt.allocPrint(allocator, "  {s}{s} result{s}", .{ marker_color, marker_icon, th.reset });
                    try lines.append(allocator, marker_line);
                    try appendWrappedFolded(allocator, &lines, tr.content, "    ", th.dim, th.reset, 5);
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

/// 全屏交互循环。fd = stdin。rows = 终端高度(留 1 行给提示)。
/// 进 alt screen → 渲染 → 处理键 → 退出恢复。
pub fn run(fd: std.c.fd_t, allocator: std.mem.Allocator, conv: *const Conversation, rows: usize) !void {
    return runWithTheme(fd, allocator, conv, rows, @import("tui/theme.zig").dark);
}

pub fn runWithTheme(fd: std.c.fd_t, allocator: std.mem.Allocator, conv: *const Conversation, rows: usize, th: @import("tui/theme.zig").Theme) !void {
    const lines = try renderToLinesWithTheme(allocator, conv, th);
    defer freeLines(allocator, lines);
    const prompts = try userPromptLineIndices(allocator, lines);
    defer allocator.free(prompts);

    // 进 alt screen + 隐藏光标(用 tui/overlay 抽出的通用形式)
    var ov = @import("tui/overlay.zig").Overlay{ .fd = 1 };
    ov.enter();
    defer ov.exit();

    const view_rows = if (rows > 1) rows - 1 else 1;
    var top: usize = 0;
    const max_top = if (lines.len > view_rows) lines.len - view_rows else 0;

    while (true) {
        drawScreen(lines, top, view_rows);
        var b: [1]u8 = undefined;
        const n = std.c.read(fd, &b, 1);
        if (n <= 0) break;
        switch (b[0]) {
            'q', 0x1b, 0x03 => break, // q / Esc / Ctrl+C
            'j', ' ' => top = @min(top + 1, max_top),
            'k' => top = if (top > 0) top - 1 else 0,
            'g' => top = 0,
            'G' => top = max_top,
            'd' => top = @min(top + view_rows / 2, max_top), // half page down
            'u' => top = if (top > view_rows / 2) top - view_rows / 2 else 0,
            '}' => top = @min(nextPrompt(prompts, top), max_top),
            '{' => top = prevPrompt(prompts, top),
            else => {},
        }
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

fn drawScreen(lines: []const []const u8, top: usize, view_rows: usize) void {
    writeAll(1, "\x1b[2J\x1b[H"); // 清屏 + 光标回顶
    var i: usize = top;
    var drawn: usize = 0;
    while (drawn < view_rows and i < lines.len) : (i += 1) {
        writeAll(1, lines[i]);
        writeAll(1, "\r\n");
        drawn += 1;
    }
    // 底部提示行
    writeAll(1, "\x1b[7m transcript  j/k scroll  {/} prompts  g/G top/bot  q quit \x1b[0m");
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
