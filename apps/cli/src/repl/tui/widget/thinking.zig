const std = @import("std");
const theme_mod = @import("../theme.zig");
const term = @import("../term.zig");
const Theme = theme_mod.Theme;

pub const live_rows = 3;

pub const Row = struct { start: usize, end: usize };

const Glyph = struct { len: usize, cp: ?u21 };

fn glyphAt(text: []const u8, i: usize) Glyph {
    const n = std.unicode.utf8ByteSequenceLength(text[i]) catch return .{ .len = 1, .cp = null };
    if (i + n > text.len) return .{ .len = text.len - i, .cp = null };
    const cp = std.unicode.utf8Decode(text[i..][0..n]) catch return .{ .len = 1, .cp = null };
    return .{ .len = n, .cp = cp };
}

fn isControl(cp: u21) bool {
    return cp < 0x20 or (cp >= 0x7F and cp < 0xA0);
}

fn columns(cp: u21) usize {
    if (cp == '\t') return 1;
    if (isControl(cp)) return 0;
    return term.codepointDisplayWidth(cp);
}

pub fn lastRows(text: []const u8, width: usize, out: *[live_rows]Row) []const Row {
    var ring: [live_rows]Row = undefined;
    var total: usize = 0;
    var start: usize = 0;
    var used: usize = 0;
    var inked = false;
    var i: usize = 0;
    while (i < text.len) {
        const g = glyphAt(text, i);
        const cp = g.cp orelse {
            i += g.len;
            continue;
        };
        if (cp == '\n') {
            if (inked) {
                ring[total % live_rows] = .{ .start = start, .end = i };
                total += 1;
            }
            i += g.len;
            start = i;
            used = 0;
            inked = false;
            continue;
        }
        if (used == 0 and (cp == ' ' or cp == '\t' or isControl(cp))) {
            i += g.len;
            start = i;
            continue;
        }
        const w = columns(cp);
        if (used > 0 and used + w > width) {
            if (inked) {
                ring[total % live_rows] = .{ .start = start, .end = i };
                total += 1;
            }
            start = i;
            used = 0;
            inked = false;
            if (cp == ' ' or cp == '\t') {
                i += g.len;
                start = i;
                continue;
            }
        }
        used += w;
        if (w > 0 and cp != ' ' and cp != '\t') inked = true;
        i += g.len;
    }
    if (inked) {
        ring[total % live_rows] = .{ .start = start, .end = text.len };
        total += 1;
    }
    const n = @min(total, live_rows);
    for (0..n) |k| out[k] = ring[(total - n + k) % live_rows];
    return out[0..n];
}

pub fn writeRow(w: *std.Io.Writer, text: []const u8, row: Row) std.Io.Writer.Error!void {
    var i = row.start;
    while (i < row.end) {
        const g = glyphAt(text, i);
        if (g.cp) |cp| {
            if (cp == '\t') {
                try w.writeByte(' ');
            } else if (!isControl(cp)) try w.writeAll(text[i..][0..g.len]);
        }
        i += g.len;
    }
}

pub fn summarySeconds(elapsed_ms: i64) u64 {
    const ms: u64 = @intCast(@max(elapsed_ms, 0));
    return @max(1, (ms + 500) / 1000);
}

pub fn writeSummary(w: *std.Io.Writer, th: Theme, elapsed_ms: ?i64) std.Io.Writer.Error!void {
    try w.print("{s}{s} Thought", .{ th.dim, th.icon_thinking });
    if (elapsed_ms) |ms| try w.print(" for {d}s", .{summarySeconds(ms)});
    try w.print("{s}\n", .{th.reset});
}

const testing = std.testing;

fn rowsText(text: []const u8, width: usize, buf: []u8) ![]const u8 {
    var out: [live_rows]Row = undefined;
    var w: std.Io.Writer = .fixed(buf);
    for (lastRows(text, width, &out)) |row| {
        try writeRow(&w, text, row);
        try w.writeByte('|');
    }
    return w.buffered();
}

test "lastRows: the last three rows of the thinking, wrapped at the width, without blank lines" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("b|c|d|", try rowsText("a\n\nb\n  \nc\nd\n", 10, &buf));
    try testing.expectEqualStrings("efgh|ijkl|mnop|", try rowsText("abcdefghijklmnop", 4, &buf));
    try testing.expectEqualStrings("one two |three|", try rowsText("one two three", 8, &buf));
    try testing.expectEqualStrings("one|two|", try rowsText("one two", 3, &buf));
    try testing.expectEqualStrings("", try rowsText("\n \n\t\n", 8, &buf));
}

test "lastRows: wide characters wrap by columns, and control bytes take none" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("\xe4\xbd\xa0\xe5\xa5\xbd|\xe4\xb8\x96|", try rowsText("\xe4\xbd\xa0\xe5\xa5\xbd\xe4\xb8\x96", 5, &buf));
    try testing.expectEqualStrings("abcd|", try rowsText("ab\x1bcd", 4, &buf));
}

test "writeRow: control bytes are left out, a tab is a space, a broken sequence is dropped" {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const text = "a\tb\x07c\xffd\xc2\x9be";
    try writeRow(&w, text, .{ .start = 0, .end = text.len });
    try testing.expectEqualStrings("a bcde", w.buffered());
}

test "writeSummary: whole seconds, at least one, and no duration when it is not known" {
    const th = theme_mod.monochrome;
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try writeSummary(&w, th, 12_400);
    try writeSummary(&w, th, 300);
    try writeSummary(&w, th, null);
    try testing.expectEqualStrings("~ Thought for 12s\n~ Thought for 1s\n~ Thought\n", w.buffered());
    try testing.expectEqual(@as(u64, 13), summarySeconds(12_500));
}
