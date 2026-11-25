//! Where the fixed region's top is once the terminal has been resized.
//!
//! Every frame climbs from the cursor back to the region's top with a relative
//! cursor-up: an absolute DECSC row does not follow a scroll, and Warp ignores
//! DECRC. The climb counts rows, and most terminals re-wrap their lines when
//! the window narrows, so a rule drawn across 100 columns is two rows at 80.
//! Climbing the rows the frame was drawn with then stops inside the old frame:
//! each resize left the first half of the old rule above the box and the old
//! footer below it. An `Anchor` keeps what the climb needs to count the rows
//! the terminal holds now: the width of every row above the cursor, and the
//! cursor's column.

const std = @import("std");
const term = @import("term.zig");

/// Rows right above the cursor whose width an anchor keeps. A climb stops at
/// the top of the screen, so rows further up than any screen is tall change
/// nothing; they count one row each.
pub const tracked_rows = 256;

pub const Anchor = struct {
    /// The cursor's row, counted from the region's top.
    rows_above: u16 = 0,
    /// The cursor's column on that row (0-based), and the row's width.
    cursor_col: u16 = 0,
    cursor_row_width: u16 = 0,
    /// Terminal width when the frame was drawn (0: unknown, the rows above
    /// count one row each in a terminal that clips).
    drawn_cols: u16 = 0,
    /// Display widths of the `known` rows right above the cursor, top first.
    widths: [tracked_rows]u16 = undefined,
    known: u16 = 0,

    /// The anchor of a frame drawn `drawn_cols` wide whose rows start at
    /// `rows`: one row per `\n`, escapes take no columns, `\r` returns to
    /// column 0. Rows after the cursor's do not move the region's top and
    /// are not read.
    pub fn measure(rows: []const u8, rows_above: u16, cursor_col: u16, drawn_cols: u16) Anchor {
        var anchor: Anchor = .{ .rows_above = rows_above, .cursor_col = cursor_col, .drawn_cols = drawn_cols };
        anchor.known = @min(rows_above, tracked_rows);
        @memset(anchor.widths[0..anchor.known], 0);
        const first_kept = rows_above - anchor.known;
        var row: u16 = 0;
        var at: usize = 0;
        while (at < rows.len and row < rows_above) : (row += 1) {
            const scanned = scanRow(rows, at);
            if (row >= first_kept) anchor.widths[row - first_kept] = clampWidth(scanned.width);
            at = scanned.next;
        }
        if (row == rows_above and at < rows.len) anchor.cursor_row_width = clampWidth(scanRow(rows, at).width);
        return anchor;
    }

    /// The anchor of a frame the cursor rests at the end of (a dialog that
    /// writes its frame and waits for a key).
    pub fn atEnd(frame: []const u8, drawn_cols: u16) Anchor {
        const rows_above = std.mem.count(u8, frame, "\n");
        const last_row = if (std.mem.lastIndexOfScalar(u8, frame, '\n')) |nl| nl + 1 else 0;
        const cursor_col = scanRow(frame, last_row).col;
        return measure(frame, clampWidth(rows_above), clampWidth(cursor_col), drawn_cols);
    }

    /// Rows from the cursor up to the region's top while the terminal is
    /// `cols` wide. A terminal that re-wraps spreads each row over
    /// ceil(width / cols) rows, the cursor's own line included; one that
    /// clips keeps the rows the frame took when it was drawn.
    pub fn climb(self: *const Anchor, cols: u16, reflows: bool) u16 {
        const at = if (reflows) cols else self.drawn_cols;
        if (at == 0) return self.rows_above;
        var rows: u32 = self.rows_above - self.known;
        for (self.widths[0..self.known]) |width| rows += rowsAt(width, at);
        rows += self.cursorRow(at);
        return @intCast(@min(rows, std.math.maxInt(u16)));
    }

    /// The row of its line the cursor is on at `cols`. A cursor that printed
    /// to the end of a full row waits on it (DEC pending wrap) rather than
    /// on the next row.
    fn cursorRow(self: *const Anchor, cols: u16) u32 {
        const col = self.cursor_col;
        if (col > 0 and col == self.cursor_row_width and col % cols == 0) return col / cols - 1;
        return col / cols;
    }
};

const Row = struct {
    /// Widest column the row reached.
    width: usize,
    /// Column the row ended on.
    col: usize,
    /// Index after the row's `\n` (or the end of the bytes).
    next: usize,
};

/// Scan one row from `start`: escapes take no columns, `\r` returns to
/// column 0, a `\n` ends the row.
fn scanRow(bytes: []const u8, start: usize) Row {
    var col: usize = 0;
    var width: usize = 0;
    var i = start;
    while (i < bytes.len) {
        switch (bytes[i]) {
            0x1b => {
                i += escapeLen(bytes[i..]);
                continue;
            },
            '\r' => col = 0,
            '\n' => return .{ .width = width, .col = col, .next = i + 1 },
            else => |b| if (b >= 0x20) {
                const len = @min(std.unicode.utf8ByteSequenceLength(b) catch 1, bytes.len - i);
                col += term.displayWidth(bytes[i .. i + len]);
                width = @max(width, col);
                i += len;
                continue;
            },
        }
        i += 1;
    }
    return .{ .width = width, .col = col, .next = bytes.len };
}

fn rowsAt(width: u16, cols: u16) u32 {
    if (width <= cols) return 1;
    return (@as(u32, width) + cols - 1) / cols;
}

fn clampWidth(width: usize) u16 {
    return @intCast(@min(width, std.math.maxInt(u16)));
}

/// Bytes of the escape sequence at `s[0] == ESC`: CSI up to its final byte,
/// OSC up to BEL or ST, anything else two bytes.
fn escapeLen(s: []const u8) usize {
    if (s.len < 2) return s.len;
    switch (s[1]) {
        '[' => {
            var j: usize = 2;
            while (j < s.len) : (j += 1) {
                if (s[j] >= 0x40 and s[j] <= 0x7e) return j + 1;
            }
            return s.len;
        },
        ']' => {
            var j: usize = 2;
            while (j < s.len) : (j += 1) {
                if (s[j] == 0x07) return j + 1;
                if (s[j] == 0x1b and j + 1 < s.len and s[j + 1] == '\\') return j + 2;
            }
            return s.len;
        },
        else => return 2,
    }
}

const testing = std.testing;

test "measure reads the visible width of each row above the cursor, and of the cursor's" {
    const frame = "\x1b[2K\x1b[36m" ++ "─" ** 99 ++ "\x1b[0m\r\n" ++
        "\x1b[2K\x1b[36m❯ \x1b[0m你好\r\n" ++
        "\x1b[2K" ++ "─" ** 99 ++ "\r\n";
    const anchor = Anchor.measure(frame, 1, 2, 100);
    try testing.expectEqual(@as(u16, 1), anchor.known);
    try testing.expectEqual(@as(u16, 99), anchor.widths[0]);
    try testing.expectEqual(@as(u16, 6), anchor.cursor_row_width);
}

test "measure skips OSC strings and counts a carriage return as a new column 0" {
    const frame = "\x1b]8;;https://example.com\x07link\x1b]8;;\x1b\\\r\n" ++ "abcdef\rxy\r\n";
    const anchor = Anchor.measure(frame, 2, 0, 80);
    try testing.expectEqual(@as(u16, 4), anchor.widths[0]);
    try testing.expectEqual(@as(u16, 6), anchor.widths[1]);
}

test "a narrower terminal re-wraps every wide row above the cursor" {
    // Rule (99), content row with the cursor at column 2: the frame's own
    // count is 1, but at 60 columns the rule is two rows.
    const anchor = Anchor.measure("─" ** 99 ++ "\r\n❯ hi", 1, 2, 100);
    try testing.expectEqual(@as(u16, 1), anchor.climb(100, true));
    try testing.expectEqual(@as(u16, 2), anchor.climb(60, true));
    try testing.expectEqual(@as(u16, 3), anchor.climb(40, true));
    // A rule exactly as wide as the terminal still fits on one row.
    try testing.expectEqual(@as(u16, 1), anchor.climb(99, true));
}

test "a terminal that clips keeps the rows the frame took when it was drawn" {
    const anchor = Anchor.measure("─" ** 99 ++ "\r\n", 1, 70, 100);
    try testing.expectEqual(@as(u16, 1), anchor.climb(60, false));
    // A row wider than the terminal it was drawn on wrapped right then.
    const wrapped = Anchor.measure("─" ** 64 ++ "\r\n", 1, 0, 60);
    try testing.expectEqual(@as(u16, 2), wrapped.climb(60, false));
}

test "the cursor's own line wraps under it" {
    // Cursor at column 70 of its row: at 60 columns it sits on the row
    // after the one its line starts on.
    const anchor = Anchor.measure("─" ** 50 ++ "\r\n" ++ "x" ** 80, 1, 70, 100);
    try testing.expectEqual(@as(u16, 2), anchor.climb(60, true));
    try testing.expectEqual(@as(u16, 1), anchor.climb(80, true));
}

test "rows beyond the tracked window count one row each" {
    var frame: std.ArrayList(u8) = .empty;
    defer frame.deinit(testing.allocator);
    const total = tracked_rows + 4;
    for (0..total) |_| try frame.appendSlice(testing.allocator, "─" ** 30 ++ "\r\n");
    const anchor = Anchor.measure(frame.items, total, 0, 80);
    try testing.expectEqual(@as(u16, tracked_rows), anchor.known);
    // Tracked rows are two rows each at 20 columns; the four oldest count one.
    try testing.expectEqual(@as(u16, 4 + 2 * tracked_rows), anchor.climb(20, true));
}

test "a default anchor climbs nothing and a bare row count climbs that many rows" {
    const none: Anchor = .{};
    try testing.expectEqual(@as(u16, 0), none.climb(40, true));
    const bare: Anchor = .{ .rows_above = 3 };
    try testing.expectEqual(@as(u16, 3), bare.climb(40, true));
    try testing.expectEqual(@as(u16, 3), bare.climb(40, false));
}

test "a dialog's anchor rests where its frame ends" {
    // A 64-wide box: three rows, the cursor after the bottom edge's last
    // column. At 40 columns each row is two rows, and so is the cursor's.
    const box = "╭" ++ "─" ** 62 ++ "╮\n│" ++ " " ** 62 ++ "│\n╰" ++ "─" ** 62 ++ "╯";
    const anchor = Anchor.atEnd(box, 80);
    try testing.expectEqual(@as(u16, 2), anchor.rows_above);
    try testing.expectEqual(@as(u16, 64), anchor.cursor_col);
    try testing.expectEqual(@as(u16, 2), anchor.climb(80, true));
    try testing.expectEqual(@as(u16, 5), anchor.climb(40, true));
    // A box exactly as wide as the terminal: the cursor waits at the end of
    // the bottom edge (pending wrap), not on the row below it.
    try testing.expectEqual(@as(u16, 2), anchor.climb(64, true));
    try testing.expectEqual(@as(u16, 5), anchor.climb(32, true));
    // A frame ending in a newline leaves the cursor at column 0 of the row after it.
    const ended = Anchor.atEnd("\x1b[2Kone\r\n\x1b[2Ktwo\r\n", 80);
    try testing.expectEqual(@as(u16, 2), ended.rows_above);
    try testing.expectEqual(@as(u16, 0), ended.cursor_col);
}

test "a frame shorter than its cursor row counts the missing rows as empty" {
    const anchor = Anchor.measure("─" ** 90, 3, 0, 100);
    try testing.expectEqual(@as(u16, 90), anchor.widths[0]);
    try testing.expectEqual(@as(u16, 0), anchor.widths[1]);
    try testing.expectEqual(@as(u16, 4), anchor.climb(60, true));
}
