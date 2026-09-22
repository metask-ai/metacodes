//! 用户提交回显 `❯ <text>`:软折到终端宽度 + 2 列悬挂缩进(对齐 cc:长输入回显续行缩进 2 列,
//! 不回第 0 列;断行处的空格不带到续行行首)。
//!
//! 两个消费点共用这一份排版,只换 sink:REPL 在两个 Run 之间消费队列时打到 stderr
//! (loop.zig `echoUserSubmission`),TuiBackend 在 turn 边界消费时写进 scrollback(#115)。
//! 此前各写一份,多行/超宽消息在两处长得不一样。

const std = @import("std");
const term = @import("tui/term.zig");

/// 把 `submitted` 排版成若干行追加进 `out`(每行以 '\n' 结尾)。`cols` = 终端列数(≤6 = 不折);
/// `accent`/`reset` 是主题转义串(无主题传 "")。首尾空白先去掉(与进对话的文本一致,尾部换行不
/// 多出一行缩进空行);空白提交排成一个空行。
pub fn render(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    accent: []const u8,
    reset: []const u8,
    cols: usize,
    submitted: []const u8,
) !void {
    const text = std.mem.trim(u8, submitted, " \t\r\n");
    if (text.len == 0) {
        try out.append(allocator, '\n');
        return;
    }
    const avail: usize = if (cols > 6) cols - 2 else 0; // 0 = 不折
    var first_logical = true;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |seg| {
        // 每个逻辑行按显示宽软折成多段;首段带前缀(❯/续行 2 空格),软折续段恒 2 空格。
        var start: usize = 0;
        var first_seg = true;
        while (start <= seg.len) {
            const end = if (avail == 0) seg.len else wrapPointAt(seg, start, avail);
            const piece = seg[start..end];
            if (first_logical and first_seg) {
                try out.appendSlice(allocator, accent);
                try out.appendSlice(allocator, "❯");
                try out.appendSlice(allocator, reset);
                try out.append(allocator, ' ');
            } else {
                try out.appendSlice(allocator, "  ");
            }
            try out.appendSlice(allocator, piece);
            try out.append(allocator, '\n');
            first_seg = false;
            if (end >= seg.len) break;
            start = end;
            // 续段跳过 1 个折点空格(对齐 cc 词折:断行处的空格不带到续行行首)。
            if (start < seg.len and seg[start] == ' ') start += 1;
        }
        first_logical = false;
    }
}

/// 从 start 起返回不超过 max_w 显示宽的最大 byte 终点(至少进 1 codepoint 防死循环)。纯文本用。
pub fn wrapPointAt(s: []const u8, start: usize, max_w: usize) usize {
    var i = start;
    var w: usize = 0;
    while (i < s.len) {
        const cp_len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        const e = @min(i + cp_len, s.len);
        const cw = term.displayWidth(s[i..e]);
        if (w + cw > max_w) {
            if (i == start) return e;
            return i;
        }
        w += cw;
        i = e;
    }
    return i;
}

test "render: single line gets the accent prefix, blank input is one empty line" {
    const a = std.testing.allocator;
    var out = std.ArrayList(u8).empty;
    defer out.deinit(a);
    try render(&out, a, "<A>", "<R>", 80, "hello\n");
    try std.testing.expectEqualStrings("<A>❯<R> hello\n", out.items);
    out.clearRetainingCapacity();
    try render(&out, a, "", "", 80, "   \n");
    try std.testing.expectEqualStrings("\n", out.items);
}

test "render: logical lines and soft wraps get the 2-column hanging indent" {
    const a = std.testing.allocator;
    var out = std.ArrayList(u8).empty;
    defer out.deinit(a);
    // cols=11 → avail=9:"aaaa bbbb cccc" 折成 "aaaa bbbb" + "cccc"(折点空格不带到续行行首)。
    try render(&out, a, "", "", 11, "aaaa bbbb cccc\nsecond");
    try std.testing.expectEqualStrings("❯ aaaa bbbb\n  cccc\n  second\n", out.items);
}
