const std = @import("std");
const sync = @import("platform").sync;
const term = @import("term.zig");

pub const Point = struct {
    row: i32,
    col: u16,

    fn before(self: Point, other: Point) bool {
        return self.row < other.row or (self.row == other.row and self.col <= other.col);
    }
};

const Cell = struct {
    cp: u21 = ' ',
    marks: [2]u21 = .{ 0, 0 },

    fn isWideTail(self: Cell) bool {
        return self.cp == 0;
    }

    fn isFiller(self: Cell) bool {
        return self.cp == 0 or self.cp == wrap_pad.cp;
    }

    fn isBlank(self: Cell) bool {
        return (self.cp == ' ' and self.marks[0] == 0) or self.cp == wrap_pad.cp;
    }
};

const blank: Cell = .{};
const wide_tail: Cell = .{ .cp = 0 };
const wrap_pad: Cell = .{ .cp = std.math.maxInt(u21) };
const max_params = 16;

pub const Screen = struct {
    gpa: std.mem.Allocator,
    cols: u16,
    rows: u16,
    cells: []Cell,
    wrapped: []bool,
    row: u16 = 0,
    col: u16 = 0,
    pending_wrap: bool = false,
    alternate: bool = false,
    query_row: ?u16 = null,
    state: State = .ground,
    params: [max_params]u32 = undefined,
    param_count: u8 = 0,
    private: bool = false,
    utf8: [4]u8 = undefined,
    utf8_len: u8 = 0,
    utf8_need: u8 = 0,

    const State = enum { ground, utf8, esc, esc_intermediate, csi, osc, osc_esc };

    pub fn init(gpa: std.mem.Allocator, cols: u16, rows: u16) !Screen {
        const c = @max(cols, 1);
        const r = @max(rows, 1);
        const cells = try gpa.alloc(Cell, @as(usize, c) * r);
        errdefer gpa.free(cells);
        const wrapped = try gpa.alloc(bool, r);
        @memset(cells, blank);
        @memset(wrapped, false);
        return .{ .gpa = gpa, .cols = c, .rows = r, .cells = cells, .wrapped = wrapped };
    }

    pub fn deinit(self: *Screen) void {
        self.gpa.free(self.cells);
        self.gpa.free(self.wrapped);
    }

    pub fn resize(self: *Screen, cols: u16, rows: u16, reflow: bool) !void {
        const c = @max(cols, 1);
        const r = @max(rows, 1);
        if (c == self.cols and r == self.rows) return;
        if (reflow and c != self.cols) return self.rewrap(c, r);
        var next = try Screen.init(self.gpa, c, r);
        const shift: u16 = if (self.row >= r) self.row - (r - 1) else 0;
        for (0..r) |dst| {
            const src = dst + shift;
            if (src >= self.rows) break;
            const width = @min(c, self.cols);
            @memcpy(next.cells[dst * c ..][0..width], self.cells[src * self.cols ..][0..width]);
            next.wrapped[dst] = self.wrapped[src] and c == self.cols;
        }
        self.gpa.free(self.cells);
        self.gpa.free(self.wrapped);
        self.cells = next.cells;
        self.wrapped = next.wrapped;
        self.cols = c;
        self.rows = r;
        self.row -= shift;
        self.col = @min(self.col, c - 1);
        self.pending_wrap = false;
        if (self.query_row) |q| self.query_row = if (q >= shift) q - shift else null;
    }

    const Rows = struct {
        gpa: std.mem.Allocator,
        cols: u16,
        cells: std.ArrayList(Cell) = .empty,
        wrapped: std.ArrayList(bool) = .empty,

        fn deinit(self: *Rows) void {
            self.cells.deinit(self.gpa);
            self.wrapped.deinit(self.gpa);
        }

        fn count(self: *const Rows) usize {
            return self.wrapped.items.len;
        }

        fn add(self: *Rows) !void {
            try self.cells.appendNTimes(self.gpa, blank, self.cols);
            try self.wrapped.append(self.gpa, false);
        }

        fn put(self: *Rows, col: usize, cell: Cell) void {
            self.cells.items[(self.count() - 1) * self.cols + col] = cell;
        }
    };

    fn usedCells(self: *Screen, row: u16) usize {
        const cells = self.rowCells(row);
        var used = cells.len;
        while (used > 0 and cells[used - 1].isBlank()) used -= 1;
        if (row == self.row) used = @max(used, @as(usize, self.col) + @intFromBool(self.pending_wrap));
        return used;
    }

    fn rewrap(self: *Screen, c: u16, r: u16) !void {
        var out: Rows = .{ .gpa = self.gpa, .cols = c };
        defer out.deinit();
        const Spot = struct { row: usize, col: usize, pending: bool };
        var cursor: ?Spot = null;
        var query: ?usize = null;
        const old: usize = self.cols;
        var first: u16 = 0;
        while (first < self.rows) {
            var last = first;
            while (last + 1 < self.rows and self.wrapped[last]) last += 1;
            const len = (last - first) * old + self.usedCells(last);
            const cursor_at: ?usize = if (self.row >= first and self.row <= last) (self.row - first) * old + self.col + @intFromBool(self.pending_wrap) else null;
            const query_at: ?usize = if (self.query_row) |q| (if (q >= first and q <= last) (q - first) * old else null) else null;
            try out.add();
            var col: usize = 0;
            for (0..len) |i| {
                if (query_at != null and query == null and i >= query_at.?) query = out.count() - 1;
                const cell = self.cells[first * old + i];
                if (cell.isFiller()) continue;
                const width: usize = if (i + 1 < len and self.cells[first * old + i + 1].isWideTail()) 2 else 1;
                if (col + width > c) {
                    if (col < c) out.put(col, wrap_pad);
                    out.wrapped.items[out.count() - 1] = true;
                    try out.add();
                    col = 0;
                }
                if (cursor_at != null and cursor == null and i >= cursor_at.?) cursor = .{ .row = out.count() - 1, .col = col, .pending = false };
                out.put(col, cell);
                if (width == 2) out.put(col + 1, wide_tail);
                col += width;
            }
            if (query_at != null and query == null) query = out.count() - 1;
            if (cursor_at != null and cursor == null) {
                cursor = if (col >= c) Spot{ .row = out.count() - 1, .col = c - 1, .pending = true } else Spot{ .row = out.count() - 1, .col = col, .pending = false };
            }
            first = last + 1;
        }
        const at = cursor orelse Spot{ .row = 0, .col = 0, .pending = false };
        const top: usize = if (at.row + 1 > r) at.row + 1 - r else 0;
        var next = try Screen.init(self.gpa, c, r);
        const kept = @min(out.count() - top, r);
        @memcpy(next.cells[0 .. kept * c], out.cells.items[top * c ..][0 .. kept * c]);
        @memcpy(next.wrapped[0..kept], out.wrapped.items[top..][0..kept]);
        self.gpa.free(self.cells);
        self.gpa.free(self.wrapped);
        self.cells = next.cells;
        self.wrapped = next.wrapped;
        self.cols = c;
        self.rows = r;
        self.row = @intCast(at.row - top);
        self.col = @intCast(at.col);
        self.pending_wrap = at.pending;
        self.query_row = if (query) |q| (if (q >= top) @intCast(q - top) else null) else null;
    }

    pub fn feed(self: *Screen, bytes: []const u8) void {
        for (bytes) |b| self.feedByte(b);
    }

    fn feedByte(self: *Screen, b: u8) void {
        switch (self.state) {
            .ground => self.ground(b),
            .utf8 => {
                if (b & 0xC0 != 0x80) {
                    self.state = .ground;
                    self.print(0xFFFD);
                    return self.feedByte(b);
                }
                self.utf8[self.utf8_len] = b;
                self.utf8_len += 1;
                if (self.utf8_len < self.utf8_need) return;
                self.state = .ground;
                const cp = std.unicode.utf8Decode(self.utf8[0..self.utf8_len]) catch 0xFFFD;
                self.print(cp);
            },
            .esc => switch (b) {
                '[' => {
                    self.state = .csi;
                    self.param_count = 0;
                    self.params[0] = 0;
                    self.private = false;
                },
                ']' => self.state = .osc,
                0x20...0x2F => self.state = .esc_intermediate,
                else => self.state = .ground,
            },
            .esc_intermediate => {
                if (b < 0x20 or b > 0x2F) self.state = .ground;
            },
            .csi => self.csiByte(b),
            .osc => switch (b) {
                0x07 => self.state = .ground,
                0x1b => self.state = .osc_esc,
                else => {},
            },
            .osc_esc => self.state = if (b == '\\') .ground else .osc,
        }
    }

    fn ground(self: *Screen, b: u8) void {
        switch (b) {
            0x1b => self.state = .esc,
            '\r' => self.carriageReturn(),
            '\n' => {
                if (self.alternate) return;
                self.carriageReturn();
                self.lineFeed();
            },
            0x08 => {
                if (self.alternate) return;
                self.pending_wrap = false;
                if (self.col > 0) self.col -= 1;
            },
            '\t' => {
                if (self.alternate) return;
                self.pending_wrap = false;
                self.col = @min((self.col / 8 + 1) * 8, self.cols - 1);
            },
            0x00...0x07, 0x0b...0x0c, 0x0e...0x1a, 0x1c...0x1f, 0x7f => {},
            0x80...0xff => {
                const need: u8 = if (b & 0xE0 == 0xC0) 2 else if (b & 0xF0 == 0xE0) 3 else if (b & 0xF8 == 0xF0) 4 else 0;
                if (need == 0) return self.print(0xFFFD);
                self.utf8[0] = b;
                self.utf8_len = 1;
                self.utf8_need = need;
                self.state = .utf8;
            },
            else => self.print(b),
        }
    }

    fn csiByte(self: *Screen, b: u8) void {
        switch (b) {
            '0'...'9' => {
                if (self.param_count == 0) self.param_count = 1;
                const p = &self.params[self.param_count - 1];
                p.* = p.* *| 10 +| (b - '0');
            },
            ';', ':' => {
                if (self.param_count == 0) self.param_count = 1;
                if (self.param_count < max_params) {
                    self.params[self.param_count] = 0;
                    self.param_count += 1;
                }
            },
            '<', '=', '>', '?' => self.private = true,
            0x20...0x2F => {},
            0x40...0x7E => {
                self.state = .ground;
                self.dispatchCsi(b);
            },
            else => self.state = .ground,
        }
    }

    fn param(self: *const Screen, index: usize, default: u32) u32 {
        if (index >= self.param_count) return default;
        const value = self.params[index];
        return if (value == 0) default else value;
    }

    fn dispatchCsi(self: *Screen, final: u8) void {
        if (self.private) {
            if (final != 'h' and final != 'l') return;
            for (self.params[0..self.param_count]) |mode| {
                if (mode == 1049 or mode == 1047 or mode == 47) self.alternate = final == 'h';
            }
            return;
        }
        if (self.alternate) return;
        const n: u16 = @intCast(@min(self.param(0, 1), std.math.maxInt(u16)));
        switch (final) {
            'A' => self.moveTo(self.row -| n, self.col),
            'B' => self.moveTo(self.row +| n, self.col),
            'C' => self.moveTo(self.row, self.col +| n),
            'D' => self.moveTo(self.row, self.col -| n),
            'E' => self.moveTo(self.row +| n, 0),
            'F' => self.moveTo(self.row -| n, 0),
            'G' => self.moveTo(self.row, n - 1),
            'd' => self.moveTo(n - 1, self.col),
            'H', 'f' => {
                const col: u16 = @intCast(@min(self.param(1, 1), std.math.maxInt(u16)));
                self.moveTo(n - 1, col - 1);
            },
            'J' => self.eraseDisplay(self.param(0, 0)),
            'K' => self.eraseLine(self.row, self.param(0, 0)),
            'n' => {
                if (self.param(0, 0) == 6) self.query_row = self.row;
            },
            else => {},
        }
    }

    fn moveTo(self: *Screen, row: u16, col: u16) void {
        self.pending_wrap = false;
        self.row = @min(row, self.rows - 1);
        self.col = @min(col, self.cols - 1);
    }

    fn carriageReturn(self: *Screen) void {
        self.pending_wrap = false;
        self.col = 0;
    }

    fn lineFeed(self: *Screen) void {
        if (self.row + 1 < self.rows) {
            self.row += 1;
            return;
        }
        const width: usize = self.cols;
        std.mem.copyForwards(Cell, self.cells[0 .. self.cells.len - width], self.cells[width..]);
        @memset(self.cells[self.cells.len - width ..], blank);
        std.mem.copyForwards(bool, self.wrapped[0 .. self.wrapped.len - 1], self.wrapped[1..]);
        self.wrapped[self.wrapped.len - 1] = false;
        if (self.query_row) |q| self.query_row = if (q > 0) q - 1 else null;
    }

    fn rowCells(self: *Screen, row: u16) []Cell {
        return self.cells[@as(usize, row) * self.cols ..][0..self.cols];
    }

    fn eraseLine(self: *Screen, row: u16, mode: u32) void {
        const cells = self.rowCells(row);
        switch (mode) {
            0 => {
                @memset(cells[self.col..], blank);
                self.wrapped[row] = false;
            },
            1 => @memset(cells[0 .. self.col + 1], blank),
            else => {
                @memset(cells, blank);
                self.wrapped[row] = false;
            },
        }
    }

    fn eraseDisplay(self: *Screen, mode: u32) void {
        switch (mode) {
            0 => {
                self.eraseLine(self.row, 0);
                var r = self.row + 1;
                while (r < self.rows) : (r += 1) self.eraseLine(r, 2);
            },
            1 => {
                var r: u16 = 0;
                while (r < self.row) : (r += 1) self.eraseLine(r, 2);
                self.eraseLine(self.row, 1);
            },
            else => {
                @memset(self.cells, blank);
                @memset(self.wrapped, false);
            },
        }
    }

    fn print(self: *Screen, cp: u21) void {
        if (self.alternate) return;
        if (isCombining(cp)) return self.combine(cp);
        const width: u16 = @intCast(term.codepointDisplayWidth(cp));
        if (width == 0) return;
        if (self.pending_wrap or (width == 2 and self.col + 1 >= self.cols and self.cols > 1)) {
            if (!self.pending_wrap) self.rowCells(self.row)[self.col] = wrap_pad;
            self.wrapped[self.row] = true;
            self.carriageReturn();
            self.lineFeed();
        }
        const cells = self.rowCells(self.row);
        cells[self.col] = .{ .cp = cp };
        if (width == 2 and self.col + 1 < self.cols) cells[self.col + 1] = wide_tail;
        const next = self.col + width;
        if (next >= self.cols) {
            self.col = self.cols - 1;
            self.pending_wrap = true;
        } else {
            self.col = next;
        }
    }

    fn combine(self: *Screen, mark: u21) void {
        var col = if (self.pending_wrap) self.col else if (self.col > 0) self.col - 1 else return;
        const cells = self.rowCells(self.row);
        if (cells[col].isWideTail() and col > 0) col -= 1;
        for (&cells[col].marks) |*slot| {
            if (slot.* == 0) {
                slot.* = mark;
                return;
            }
        }
    }

    pub fn text(self: *const Screen, gpa: std.mem.Allocator, a: Point, b: Point) ![]u8 {
        const start = if (a.before(b)) a else b;
        const end = if (a.before(b)) b else a;
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        var row = start.row;
        while (row <= end.row) : (row += 1) {
            const on_screen = row >= 0 and row < self.rows;
            const wrapped = on_screen and self.wrapped[@intCast(row)];
            if (on_screen) {
                const cells = self.cells[@as(usize, @intCast(row)) * self.cols ..][0..self.cols];
                const first: usize = if (row == start.row) @min(start.col, self.cols - 1) else 0;
                const last: usize = if (row == end.row) @min(end.col, self.cols - 1) else self.cols - 1;
                const line_start = out.items.len;
                for (cells[first .. last + 1]) |cell| {
                    if (cell.isFiller()) continue;
                    try appendCodepoint(&out, gpa, cell.cp);
                    for (cell.marks) |mark| {
                        if (mark != 0) try appendCodepoint(&out, gpa, mark);
                    }
                }
                if (!(wrapped and row != end.row)) {
                    while (out.items.len > line_start and out.items[out.items.len - 1] == ' ') out.items.len -= 1;
                }
            }
            if (row != end.row and !wrapped) try out.append(gpa, '\n');
        }
        return out.toOwnedSlice(gpa);
    }
};

fn isCombining(cp: u21) bool {
    return switch (cp) {
        0x0300...0x036F, 0x0483...0x0489, 0x0591...0x05BD, 0x0610...0x061A, 0x064B...0x065F, 0x0E31, 0x0E34...0x0E3A, 0x0E47...0x0E4E, 0x1AB0...0x1AFF, 0x1DC0...0x1DFF, 0x200C, 0x200D, 0x20D0...0x20FF, 0x3099, 0x309A, 0xFE00...0xFE0F, 0xFE20...0xFE2F, 0xE0100...0xE01EF => true,
        else => false,
    };
}

fn appendCodepoint(out: *std.ArrayList(u8), gpa: std.mem.Allocator, cp: u21) !void {
    var buf: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(cp, &buf) catch return;
    try out.appendSlice(gpa, buf[0..len]);
}

var g_mutex: sync.Mutex = .{};
var g_reflow: bool = false;
var g_screen: ?Screen = null;

pub fn enable(fd: c_int) void {
    g_mutex.lock();
    defer g_mutex.unlock();
    if (g_screen != null) return;
    const size = term.getSize(fd) orelse term.TermSize{ .cols = 80, .rows = 24 };
    g_screen = Screen.init(std.heap.c_allocator, size.cols, size.rows) catch null;
    g_reflow = term.reflowFromEnv();
}

pub fn feed(fd: c_int, bytes: []const u8) void {
    g_mutex.lock();
    defer g_mutex.unlock();
    const screen = if (g_screen) |*s| s else return;
    if (term.getSize(fd)) |size| screen.resize(size.cols, size.rows, g_reflow) catch {};
    screen.feed(bytes);
}

pub fn selectedText(gpa: std.mem.Allocator, a: Point, b: Point, cursor_row: u16) !?[]u8 {
    g_mutex.lock();
    defer g_mutex.unlock();
    const screen = if (g_screen) |*s| s else return null;
    const query_row = screen.query_row orelse return null;
    const shift = @as(i32, cursor_row) - query_row;
    return try screen.text(gpa, .{ .row = a.row - shift, .col = a.col }, .{ .row = b.row - shift, .col = b.col });
}

const testing = std.testing;

fn expectText(screen: *const Screen, a: Point, b: Point, expected: []const u8) !void {
    const got = try screen.text(testing.allocator, a, b);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(expected, got);
}

test "mirror: printed lines, colors and relative moves land where the terminal puts them" {
    var s = try Screen.init(testing.allocator, 10, 4);
    defer s.deinit();
    s.feed("\x1b[31mred\x1b[0m line\nsecond\n\x1b[2Ahey");
    try expectText(&s, .{ .row = 0, .col = 0 }, .{ .row = 1, .col = 9 }, "hey line\nsecond");
    try testing.expectEqual(@as(u16, 0), s.row);
}

test "mirror: autowrap joins the rows of one line and a full screen scrolls" {
    var s = try Screen.init(testing.allocator, 4, 2);
    defer s.deinit();
    s.feed("abcdefgh\nxy");
    try expectText(&s, .{ .row = 0, .col = 0 }, .{ .row = 1, .col = 3 }, "efgh\nxy");
    try expectText(&s, .{ .row = -1, .col = 0 }, .{ .row = 0, .col = 3 }, "\nefgh");
    var w = try Screen.init(testing.allocator, 4, 3);
    defer w.deinit();
    w.feed("abcdefgh");
    try expectText(&w, .{ .row = 0, .col = 2 }, .{ .row = 1, .col = 1 }, "cdef");
}

test "mirror: wide characters take two cells and copy once" {
    var s = try Screen.init(testing.allocator, 5, 2);
    defer s.deinit();
    s.feed("中文ab");
    try expectText(&s, .{ .row = 0, .col = 0 }, .{ .row = 0, .col = 3 }, "中文");
    try expectText(&s, .{ .row = 0, .col = 0 }, .{ .row = 1, .col = 4 }, "中文ab");
}

test "mirror: ED 0 and EL clear, the alternate screen leaves the main grid alone" {
    var s = try Screen.init(testing.allocator, 8, 3);
    defer s.deinit();
    s.feed("one\ntwo\nthree\x1b[1A\r\x1b[0J");
    s.feed("\x1b[?1049h\x1b[Hviewer\x1b[?1049l");
    try expectText(&s, .{ .row = 0, .col = 0 }, .{ .row = 2, .col = 7 }, "one\n\n");
    s.feed("\x1b[2J\x1b[Hfresh");
    try expectText(&s, .{ .row = 0, .col = 0 }, .{ .row = 0, .col = 7 }, "fresh");
}

test "mirror: a cursor query records the row it was asked from, scrolling moves it" {
    var s = try Screen.init(testing.allocator, 8, 2);
    defer s.deinit();
    s.feed("a\n\x1b[6n");
    try testing.expectEqual(@as(?u16, 1), s.query_row);
    s.feed("b\nc");
    try testing.expectEqual(@as(?u16, 0), s.query_row);
}

test "mirror: selection runs in reading order from either end, OSC titles are not text" {
    var s = try Screen.init(testing.allocator, 6, 3);
    defer s.deinit();
    s.feed("\x1b]0;title\x07hello\nworld");
    try expectText(&s, .{ .row = 1, .col = 2 }, .{ .row = 0, .col = 1 }, "ello\nwor");
}

test "mirror: shrinking keeps the cursor row and drops rows above it" {
    var s = try Screen.init(testing.allocator, 6, 4);
    defer s.deinit();
    s.feed("1\n2\n3\n4\x1b[6n");
    try s.resize(6, 2, false);
    try expectText(&s, .{ .row = 0, .col = 0 }, .{ .row = 1, .col = 5 }, "3\n4");
    try testing.expectEqual(@as(?u16, 1), s.query_row);
}

test "mirror: a narrower reflowing terminal rewraps lines, so the second half of an old line can be selected" {
    var s = try Screen.init(testing.allocator, 8, 4);
    defer s.deinit();
    s.feed("abcdefgh\nxy\x1b[6n");
    try s.resize(4, 4, true);
    try expectText(&s, .{ .row = 1, .col = 0 }, .{ .row = 1, .col = 3 }, "efgh");
    try expectText(&s, .{ .row = 0, .col = 0 }, .{ .row = 2, .col = 3 }, "abcdefgh\nxy");
    try testing.expectEqual(@as(u16, 2), s.row);
    try testing.expectEqual(@as(u16, 2), s.col);
    try testing.expectEqual(@as(?u16, 2), s.query_row);
    try s.resize(8, 4, true);
    try expectText(&s, .{ .row = 0, .col = 0 }, .{ .row = 1, .col = 7 }, "abcdefgh\nxy");
    try testing.expectEqual(@as(u16, 1), s.row);
}

test "mirror: rewrapping keeps a wide character whole and the cursor row on the screen" {
    var s = try Screen.init(testing.allocator, 6, 2);
    defer s.deinit();
    s.feed("ab中文");
    try s.resize(3, 2, true);
    try expectText(&s, .{ .row = 0, .col = 0 }, .{ .row = 1, .col = 2 }, "中文");
    try testing.expectEqual(@as(u16, 1), s.row);
}

test "mirror: a combining mark stays with the character before it" {
    var s = try Screen.init(testing.allocator, 8, 2);
    defer s.deinit();
    s.feed("e\u{301}XY");
    try expectText(&s, .{ .row = 0, .col = 1 }, .{ .row = 0, .col = 2 }, "XY");
    try expectText(&s, .{ .row = 0, .col = 0 }, .{ .row = 0, .col = 0 }, "e\u{301}");
    try testing.expectEqual(@as(u16, 3), s.col);
}
