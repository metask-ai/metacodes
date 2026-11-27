//! Component-level virtual terminal (#319).
//!
//! Replays the bytes the TUI writes into a row/column grid, a cursor and a
//! bounded scrollback, so a component test can assert what a person would
//! see — "row N column M shows X", "the scrollback ends with exactly Y", "no
//! frame was committed twice" — without a pty.
//!
//! Port of tests/tty/screen.py, which stays the pty suite's model. The two
//! must give the same answers: tests/fixtures/vterm/screen_parity.jsonl holds
//! screen.py's state after a fixed corpus of byte streams (regenerate with
//! `python tests/tty/vterm_parity.py --write`); vterm_test.zig replays it here
//! and tests/tty/cases/test_vterm_parity.py checks it is still screen.py's.
//!
//! Beyond screen.py: the scrollback keeps its cells up to `max_history` lines
//! (older lines are dropped and counted in `history_dropped`), every cell
//! keeps its full SGR style next to screen.py's coarse class, and DEC 2026
//! frames are counted (`sync_frames`, `stray_sync_ends`).
//!
//! Simplifications shared with screen.py: TAB writes one space; only the CSI
//! finals A B C D G H f J K m and the DEC private modes 25, 1049 and 2026 act
//! (scroll regions, insert/delete, ECH and the rest are swallowed); ED 3
//! clears the screen but keeps the scrollback; erased cells take the default
//! style (no background-colour erase); a wide character that does not
//! fit the last column of an autowrap terminal wraps whole; a zero-width
//! mark joins the cell before the cursor, three at most; a line's text
//! drops trailing U+0020 only (screen.py's `rstrip` drops all Unicode
//! whitespace, so the parity corpus avoids the others).

const std = @import("std");
const terminal_width = @import("terminal_width.zig");

/// screen.py's `border_class`: SGR foreground folded to the theme's semantic
/// colours. Kept for parity; `Style` is the full state.
pub const Class = enum { plain, dim, accent, warn, danger };

pub const Color = union(enum) {
    default,
    /// 30-37 → 0-7, 90-97 → 8-15 (and the 40/100 backgrounds).
    basic: u8,
    indexed: u8,
    rgb: [3]u8,
};

pub const Style = struct {
    fg: Color = .default,
    bg: Color = .default,
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    reverse: bool = false,
    strike: bool = false,

    pub fn eql(a: Style, b: Style) bool {
        return std.meta.eql(a, b);
    }

    pub fn isDefault(s: Style) bool {
        return s.eql(.{});
    }
};

pub const Cell = struct {
    /// Code point shown here; meaningless on a continuation cell.
    cp: u21 = ' ',
    /// 2 on the left cell of a wide character.
    width: u2 = 1,
    /// Right half of a wide character: shows nothing of its own.
    cont: bool = false,
    class: Class = .plain,
    style: Style = .{},
    /// A character (an explicit space included) was written here. Erased
    /// cells are not; resize re-wrap measures a line by it.
    written: bool = false,
    marks: [3]u21 = @splat(0),
    mark_count: u2 = 0,
};

/// One scrollback line: its cells at the width it had when it left the
/// screen, and whether it continues the line above (soft wrap).
pub const Line = struct {
    cells: []Cell,
    wrapped: bool,
};

pub const Pos = struct { row: usize, col: usize };

pub const Options = struct {
    /// Strict DEC autowrap: writing the last column arms a pending wrap and
    /// the next printable character moves to a new line. False is
    /// screen.py's default, an ideal terminal that clips at the right edge.
    autowrap: bool = false,
    /// Scrollback lines kept. Older lines are dropped (`history_dropped`).
    max_history: usize = 10_000,
};

/// The main screen saved by `?1049h`.
const Saved = struct {
    grid: std.ArrayList([]Cell),
    wrapped: std.ArrayList(bool),
    row: usize,
    col: usize,
    scrolled: usize,
};

const max_params = 64;
const sgr_reset = [_]u32{0};

pub const Screen = struct {
    gpa: std.mem.Allocator,
    rows: usize,
    cols: usize,
    autowrap: bool,
    max_history: usize,
    grid: std.ArrayList([]Cell) = .empty,
    /// wrapped[r]: row r is the soft-wrapped continuation of row r-1.
    wrapped: std.ArrayList(bool) = .empty,
    history: std.ArrayList(Line) = .empty,
    history_dropped: usize = 0,
    row: usize = 0,
    /// May equal `cols` on a clipping terminal after a full row.
    col: usize = 0,
    cursor_visible: bool = true,
    /// Rows scrolled off the top, the alternate screen's included.
    scrolled: usize = 0,
    /// DEC Last-Column Flag (autowrap only).
    pending_wrap: bool = false,
    sync_depth: usize = 0,
    max_sync_depth: usize = 0,
    /// `?2026l` that closed the outermost frame.
    sync_frames: usize = 0,
    /// `?2026l` with no frame open.
    stray_sync_ends: usize = 0,
    saved_row: usize = 0,
    saved_col: usize = 0,
    cur_class: Class = .plain,
    cur_style: Style = .{},
    alt: ?Saved = null,
    /// Bytes of an incomplete sequence, completed by the next feed.
    partial: std.ArrayList(u8) = .empty,

    pub fn init(gpa: std.mem.Allocator, rows: usize, cols: usize, opts: Options) !Screen {
        std.debug.assert(rows > 0 and cols > 0);
        var s: Screen = .{ .gpa = gpa, .rows = rows, .cols = cols, .autowrap = opts.autowrap, .max_history = opts.max_history };
        errdefer s.deinit();
        try s.appendBlankRows(&s.grid, &s.wrapped, rows, cols);
        return s;
    }

    pub fn deinit(self: *Screen) void {
        freeRows(self.gpa, &self.grid);
        self.wrapped.deinit(self.gpa);
        for (self.history.items) |line| self.gpa.free(line.cells);
        self.history.deinit(self.gpa);
        if (self.alt) |*saved| {
            freeRows(self.gpa, &saved.grid);
            saved.wrapped.deinit(self.gpa);
        }
        self.partial.deinit(self.gpa);
        self.* = undefined;
    }

    fn freeRows(gpa: std.mem.Allocator, grid: *std.ArrayList([]Cell)) void {
        for (grid.items) |cells| gpa.free(cells);
        grid.deinit(gpa);
    }

    fn blankRow(self: *Screen, cols: usize) ![]Cell {
        const cells = try self.gpa.alloc(Cell, cols);
        @memset(cells, .{});
        return cells;
    }

    fn appendBlankRows(self: *Screen, grid: *std.ArrayList([]Cell), wrapped: *std.ArrayList(bool), n: usize, cols: usize) !void {
        try grid.ensureUnusedCapacity(self.gpa, n);
        try wrapped.ensureUnusedCapacity(self.gpa, n);
        for (0..n) |_| {
            grid.appendAssumeCapacity(try self.blankRow(cols));
            wrapped.appendAssumeCapacity(false);
        }
    }

    // ---------------- write path ----------------

    pub fn feed(self: *Screen, bytes: []const u8) !void {
        try self.partial.appendSlice(self.gpa, bytes);
        const data = self.partial.items;
        var i: usize = 0;
        while (i < data.len) {
            i += try self.step(data, i) orelse break;
        }
        const rest = data.len - i;
        std.mem.copyForwards(u8, data[0..rest], data[i..]);
        self.partial.shrinkRetainingCapacity(rest);
    }

    /// Consume one control, sequence or character at data[i]. Null: the
    /// sequence is incomplete and waits for the next feed.
    fn step(self: *Screen, data: []const u8, i: usize) !?usize {
        const b = data[i];
        switch (b) {
            0x1B => return try self.escape(data, i),
            '\r' => {
                self.col = 0;
                self.pending_wrap = false;
                return 1;
            },
            '\n' => {
                // A pending wrap does not add a second line feed (DEC).
                self.pending_wrap = false;
                try self.newline();
                return 1;
            },
            '\t' => {
                try self.putChar(' ', 1);
                return 1;
            },
            else => if (b < 0x20) return 1,
        }
        const len: usize = if (b < 0x80) 1 else if (b & 0xE0 == 0xC0) 2 else if (b & 0xF0 == 0xE0) 3 else if (b & 0xF8 == 0xF0) 4 else 1;
        if (i + len > data.len) return null;
        if (len == 1) {
            if (b >= 0x80) {
                try self.putChar(0xFFFD, 1);
            } else {
                try self.putChar(b, charWidth(b));
            }
            return 1;
        }
        const cp = std.unicode.utf8Decode(data[i .. i + len]) catch {
            // Broken UTF-8 shows U+FFFD and resynchronises on the next byte.
            try self.putChar(0xFFFD, 1);
            return 1;
        };
        try self.putChar(cp, charWidth(cp));
        return len;
    }

    fn escape(self: *Screen, data: []const u8, i: usize) !?usize {
        if (i + 1 >= data.len) return null;
        switch (data[i + 1]) {
            '[' => return try self.csi(data, i),
            ']' => {
                // OSC: up to BEL or ST.
                var j = i + 2;
                while (j < data.len and data[j] != 0x07) : (j += 1) {
                    if (data[j] == 0x1B and j + 1 < data.len and data[j + 1] == '\\') return j + 2 - i;
                }
                if (j < data.len) return j + 1 - i;
                return null;
            },
            '7' => {
                self.saved_row = self.row;
                self.saved_col = self.col;
                return 2;
            },
            '8' => {
                self.row = self.saved_row;
                self.col = self.saved_col;
                return 2;
            },
            else => return 2,
        }
    }

    fn csi(self: *Screen, data: []const u8, i: usize) !?usize {
        var j = i + 2;
        var private: u8 = 0;
        if (j < data.len and (data[j] == '?' or data[j] == '>')) {
            private = data[j];
            j += 1;
        }
        const params_start = j;
        while (j < data.len and data[j] >= 0x30 and data[j] <= 0x3F) j += 1;
        const params = data[params_start..j];
        while (j < data.len and data[j] >= 0x20 and data[j] <= 0x2F) j += 1;
        if (j >= data.len) return null;
        var buf: [max_params]u32 = undefined;
        try self.dispatchCsi(private, parseParams(params, &buf), data[j]);
        return j + 1 - i;
    }

    /// screen.py: split on ';', an empty field is 0, a field that is not a
    /// decimal number (`1:2`, `?`) is 0. Values saturate.
    fn parseParams(params: []const u8, buf: *[max_params]u32) []const u32 {
        if (params.len == 0) return buf[0..0];
        var n: usize = 0;
        var it = std.mem.splitScalar(u8, params, ';');
        while (it.next()) |field| {
            if (n == buf.len) break;
            var v: u32 = 0;
            for (field) |c| {
                if (c < '0' or c > '9') {
                    v = 0;
                    break;
                }
                v = v *| 10 +| (c - '0');
            }
            buf[n] = v;
            n += 1;
        }
        return buf[0..n];
    }

    fn dispatchCsi(self: *Screen, private: u8, ps: []const u32, final: u8) !void {
        const n1: u32 = if (ps.len > 0) ps[0] else 0;
        if (private != 0) {
            if (private != '?' or ps.len == 0) return;
            switch (ps[0]) {
                25 => self.cursor_visible = final == 'h',
                2026 => if (final == 'h') {
                    self.sync_depth += 1;
                    self.max_sync_depth = @max(self.max_sync_depth, self.sync_depth);
                } else if (final == 'l') {
                    if (self.sync_depth > 0) {
                        self.sync_depth -= 1;
                        if (self.sync_depth == 0) self.sync_frames += 1;
                    } else {
                        self.stray_sync_ends += 1;
                    }
                },
                1049 => if (final == 'h') try self.enterAlt() else if (final == 'l') self.leaveAlt(),
                else => {},
            }
            return;
        }
        const step_n: usize = @max(1, n1);
        switch (final) {
            'A' => {
                self.pending_wrap = false;
                self.row -|= step_n;
            },
            'B' => {
                self.pending_wrap = false;
                self.row = @min(self.rows - 1, self.row +| step_n);
            },
            'C' => {
                self.pending_wrap = false;
                self.col = @min(self.cols - 1, self.col +| step_n);
            },
            'D' => {
                self.pending_wrap = false;
                self.col -|= step_n;
            },
            'G' => {
                self.pending_wrap = false;
                const v: usize = if (ps.len > 0) n1 else 1;
                self.col = @min(self.cols - 1, v -| 1);
            },
            'H', 'f' => {
                self.pending_wrap = false;
                const r: usize = if (ps.len >= 1 and ps[0] != 0) ps[0] else 1;
                const c: usize = if (ps.len >= 2 and ps[1] != 0) ps[1] else 1;
                self.row = @min(self.rows - 1, r - 1);
                self.col = @min(self.cols - 1, c - 1);
            },
            'K' => switch (n1) {
                2 => {
                    clearCells(self.grid.items[self.row]);
                    self.wrapped.items[self.row] = false;
                },
                0 => {
                    if (self.col < self.cols) clearCells(self.grid.items[self.row][self.col..]);
                    if (self.col == 0) self.wrapped.items[self.row] = false;
                },
                // screen.py indexes past the row when the cursor sits at
                // `cols`; clamp instead.
                1 => clearCells(self.grid.items[self.row][0 .. @min(self.col, self.cols - 1) + 1]),
                else => {},
            },
            'J' => switch (n1) {
                2, 3 => {
                    for (self.grid.items) |cells| clearCells(cells);
                    @memset(self.wrapped.items, false);
                },
                0 => {
                    if (self.col < self.cols) clearCells(self.grid.items[self.row][self.col..]);
                    if (self.col == 0) self.wrapped.items[self.row] = false;
                    for (self.grid.items[self.row + 1 ..]) |cells| clearCells(cells);
                    @memset(self.wrapped.items[self.row + 1 ..], false);
                },
                1 => {
                    for (self.grid.items[0..self.row]) |cells| clearCells(cells);
                    @memset(self.wrapped.items[0..self.row], false);
                    clearCells(self.grid.items[self.row][0 .. @min(self.col, self.cols - 1) + 1]);
                },
                else => {},
            },
            'm' => self.applySgr(if (ps.len == 0) &sgr_reset else ps),
            else => {},
        }
    }

    fn clearCells(cells: []Cell) void {
        @memset(cells, .{});
    }

    /// One pass over the parameters keeps screen.py's class (only some
    /// codes move it, 22 does not undo dim) and the full style in step.
    fn applySgr(self: *Screen, ps: []const u32) void {
        var i: usize = 0;
        const n = ps.len;
        while (i < n) {
            const p = ps[i];
            if (p == 38 or p == 48) {
                if (i + 1 < n and ps[i + 1] == 5) {
                    const idx: u32 = if (i + 2 < n) ps[i + 2] else 0;
                    const color: Color = .{ .indexed = @intCast(@min(idx, 255)) };
                    if (p == 38) {
                        self.cur_class = classFrom256(idx);
                        self.cur_style.fg = color;
                    } else {
                        self.cur_style.bg = color;
                    }
                    i += 3;
                    continue;
                }
                if (i + 1 < n and ps[i + 1] == 2) {
                    const r: u32 = if (i + 2 < n) ps[i + 2] else 0;
                    const g: u32 = if (i + 3 < n) ps[i + 3] else 0;
                    const b: u32 = if (i + 4 < n) ps[i + 4] else 0;
                    const color: Color = .{ .rgb = .{ @intCast(@min(r, 255)), @intCast(@min(g, 255)), @intCast(@min(b, 255)) } };
                    if (p == 38) {
                        self.cur_class = classFromRgb(r, g, b);
                        self.cur_style.fg = color;
                    } else {
                        self.cur_style.bg = color;
                    }
                    i += 5;
                    continue;
                }
                // Malformed: skip the 38/48 alone, keep what follows.
                i += 1;
                continue;
            }
            switch (p) {
                0 => self.cur_class = .plain,
                2 => self.cur_class = .dim,
                34, 36, 94, 96 => self.cur_class = .accent,
                33, 93 => self.cur_class = .warn,
                31, 91 => self.cur_class = .danger,
                39 => self.cur_class = .plain,
                else => {},
            }
            const st = &self.cur_style;
            switch (p) {
                0 => st.* = .{},
                1 => st.bold = true,
                2 => st.dim = true,
                3 => st.italic = true,
                4 => st.underline = true,
                7 => st.reverse = true,
                9 => st.strike = true,
                22 => {
                    st.bold = false;
                    st.dim = false;
                },
                23 => st.italic = false,
                24 => st.underline = false,
                27 => st.reverse = false,
                29 => st.strike = false,
                30...37 => st.fg = .{ .basic = @intCast(p - 30) },
                39 => st.fg = .default,
                90...97 => st.fg = .{ .basic = @intCast(p - 90 + 8) },
                40...47 => st.bg = .{ .basic = @intCast(p - 40) },
                49 => st.bg = .default,
                100...107 => st.bg = .{ .basic = @intCast(p - 100 + 8) },
                else => {},
            }
            i += 1;
        }
    }

    fn classFrom256(idx: u32) Class {
        if (idx >= 16 and idx <= 231) {
            const c = idx - 16;
            return classFromRgb((c / 36) % 6 * 51, (c / 6) % 6 * 51, c % 6 * 51);
        }
        return switch (idx) {
            4, 6, 12, 14 => .accent,
            3, 11 => .warn,
            1, 9 => .danger,
            else => .plain,
        };
    }

    fn classFromRgb(r: u32, g: u32, b: u32) Class {
        if (@max(r, g, b) - @min(r, g, b) < 40) return .plain;
        if (b > r and (b > g or g > r)) return .accent;
        if (r > 120 and g > 120 and b < 120) return .warn;
        if (r > g and r > b) return .danger;
        return .plain;
    }

    fn putChar(self: *Screen, cp: u21, w: u2) !void {
        if (w == 0 and cp >= 0xA0) return self.attachMark(cp);
        if (self.autowrap) {
            if (self.pending_wrap) {
                self.pending_wrap = false;
                self.col = 0;
                try self.newline();
                self.wrapped.items[self.row] = true;
            }
            if (w == 2 and self.col == self.cols - 1) {
                self.col = 0;
                try self.newline();
                self.wrapped.items[self.row] = true;
            }
        }
        if (self.col >= self.cols) return;
        const cells = self.grid.items[self.row];
        cells[self.col] = .{ .cp = cp, .width = @max(1, w), .class = self.cur_class, .style = self.cur_style, .written = true };
        if (w == 2 and self.col + 1 < self.cols) {
            cells[self.col + 1] = .{ .cp = 0, .cont = true, .class = self.cur_class, .style = self.cur_style, .written = true };
        }
        self.col += @max(1, w);
        if (self.autowrap) {
            if (self.col >= self.cols) {
                self.col = self.cols - 1;
                self.pending_wrap = true;
            }
        } else if (self.col > self.cols) {
            self.col = self.cols;
        }
    }

    fn attachMark(self: *Screen, cp: u21) void {
        var col = if (self.pending_wrap) self.col else if (self.col > 0) self.col - 1 else return;
        col = @min(col, self.cols - 1);
        const cells = self.grid.items[self.row];
        if (cells[col].cont and col > 0) col -= 1;
        const cell = &cells[col];
        if (cell.mark_count == cell.marks.len) return;
        cell.marks[cell.mark_count] = cp;
        cell.mark_count += 1;
    }

    fn newline(self: *Screen) !void {
        if (self.row >= self.rows - 1) {
            try self.scrollUp();
        } else {
            self.row += 1;
        }
    }

    /// The top row leaves the screen: into the scrollback on the main
    /// screen, gone on the alternate one.
    fn scrollUp(self: *Screen) !void {
        const fresh = try self.blankRow(self.cols);
        errdefer self.gpa.free(fresh);
        try self.history.ensureUnusedCapacity(self.gpa, 1);
        const top = self.grid.orderedRemove(0);
        const top_wrapped = self.wrapped.orderedRemove(0);
        self.grid.appendAssumeCapacity(fresh);
        self.wrapped.appendAssumeCapacity(false);
        if (self.alt == null) {
            self.pushHistory(.{ .cells = top, .wrapped = top_wrapped });
        } else {
            self.gpa.free(top);
        }
        self.scrolled += 1;
    }

    /// Caller reserved one slot.
    fn pushHistory(self: *Screen, line: Line) void {
        self.history.appendAssumeCapacity(line);
        self.trimHistory();
    }

    fn trimHistory(self: *Screen) void {
        if (self.history.items.len <= self.max_history) return;
        const items = self.history.items;
        const drop = items.len - self.max_history;
        for (items[0..drop]) |line| self.gpa.free(line.cells);
        std.mem.copyForwards(Line, items[0 .. items.len - drop], items[drop..]);
        self.history.shrinkRetainingCapacity(items.len - drop);
        self.history_dropped += drop;
    }

    /// `?1049h`. A second one saves the alternate screen over the main one,
    /// as screen.py does.
    fn enterAlt(self: *Screen) !void {
        var grid: std.ArrayList([]Cell) = .empty;
        var wrapped: std.ArrayList(bool) = .empty;
        errdefer {
            freeRows(self.gpa, &grid);
            wrapped.deinit(self.gpa);
        }
        try self.appendBlankRows(&grid, &wrapped, self.rows, self.cols);
        if (self.alt) |*old| {
            freeRows(self.gpa, &old.grid);
            old.wrapped.deinit(self.gpa);
        }
        self.alt = .{ .grid = self.grid, .wrapped = self.wrapped, .row = self.row, .col = self.col, .scrolled = self.scrolled };
        self.grid = grid;
        self.wrapped = wrapped;
        self.row = 0;
        self.col = 0;
    }

    fn leaveAlt(self: *Screen) void {
        const saved = self.alt orelse return;
        freeRows(self.gpa, &self.grid);
        self.wrapped.deinit(self.gpa);
        self.grid = saved.grid;
        self.wrapped = saved.wrapped;
        self.row = saved.row;
        self.col = saved.col;
        self.scrolled = saved.scrolled;
        self.alt = null;
    }

    // ---------------- resize ----------------

    /// The terminal window changes size. `reflow`: a modern terminal
    /// re-wraps logical lines (narrower splits them, wider joins soft-wrapped
    /// rows; a full screen stays anchored at the bottom and trades rows with
    /// the scrollback). Otherwise xterm/GNU screen clipping: rows are cut or
    /// padded, the cursor column is clamped.
    pub fn resize(self: *Screen, rows: usize, cols: usize, reflow: bool) !void {
        if (self.alt != null) return error.ResizeOnAlternateScreen;
        std.debug.assert(rows > 0 and cols >= 2);
        self.pending_wrap = false;
        if (reflow) try self.reflowTo(rows, cols) else try self.clipTo(rows, cols);
        self.rows = rows;
        self.cols = cols;
    }

    fn clipTo(self: *Screen, rows: usize, cols: usize) !void {
        for (self.grid.items) |*slot| {
            const old = slot.*;
            const cells = try self.blankRow(cols);
            const keep = @min(old.len, cols);
            @memcpy(cells[0..keep], old[0..keep]);
            // Cut through a wide character: its left half no longer shows.
            if (cols < old.len and old[cols].cont) cells[cols - 1] = .{};
            self.gpa.free(old);
            slot.* = cells;
        }
        if (rows < self.rows) {
            // Shorter: keep the cursor's row, push the top rows into the scrollback.
            const drop = self.row -| (rows - 1);
            try self.history.ensureUnusedCapacity(self.gpa, drop);
            for (0..drop) |_| {
                const top = self.grid.orderedRemove(0);
                const top_wrapped = self.wrapped.orderedRemove(0);
                self.history.appendAssumeCapacity(.{ .cells = top, .wrapped = top_wrapped });
            }
            self.trimHistory();
            self.row -= drop;
            for (self.grid.items[rows..]) |cells| self.gpa.free(cells);
            self.grid.shrinkRetainingCapacity(rows);
            self.wrapped.shrinkRetainingCapacity(rows);
        } else {
            try self.appendBlankRows(&self.grid, &self.wrapped, rows - self.rows, cols);
        }
        self.col = @min(self.col, cols - 1);
    }

    const Span = struct { start: usize, len: usize };
    const At = struct { seg: usize, col: usize };

    fn reflowTo(self: *Screen, rows: usize, cols: usize) !void {
        const gpa = self.gpa;
        var old: std.ArrayList(Line) = .empty;
        defer old.deinit(gpa);
        try old.appendSlice(gpa, self.history.items);
        for (self.grid.items, self.wrapped.items) |cells, w| try old.append(gpa, .{ .cells = cells, .wrapped = w });
        const cursor_at = self.history.items.len + self.row;

        // Content ends at the last written row or the cursor's row; blank
        // rows below take no part.
        var last = cursor_at;
        var k = old.items.len;
        while (k > cursor_at + 1) {
            k -= 1;
            if (anyWritten(old.items[k].cells)) {
                last = k;
                break;
            }
        }

        // Join soft-wrapped rows into logical lines; note the cursor's cell
        // offset in its line.
        const Logical = struct { cells: std.ArrayList(Cell) = .empty, cursor: ?usize = null };
        var lines: std.ArrayList(Logical) = .empty;
        defer {
            for (lines.items) |*l| l.cells.deinit(gpa);
            lines.deinit(gpa);
        }
        for (old.items[0 .. last + 1], 0..) |ln, i| {
            if (!ln.wrapped or lines.items.len == 0) try lines.append(gpa, .{});
            const cur = &lines.items[lines.items.len - 1];
            if (i == cursor_at) cur.cursor = cur.cells.items.len + self.col;
            try cur.cells.appendSlice(gpa, ln.cells);
        }

        var out: std.ArrayList(Line) = .empty;
        defer {
            for (out.items) |line| gpa.free(line.cells);
            out.deinit(gpa);
        }
        var new_cursor: Pos = .{ .row = 0, .col = 0 };
        var chunks: std.ArrayList(Span) = .empty;
        defer chunks.deinit(gpa);
        var at: std.ArrayList(At) = .empty;
        defer at.deinit(gpa);
        for (lines.items) |*lg| {
            const cells = lg.cells.items;
            var end = cells.len;
            while (end > 0 and !cells[end - 1].written) end -= 1;
            chunks.clearRetainingCapacity();
            at.clearRetainingCapacity();
            try chunks.append(gpa, .{ .start = 0, .len = 0 });
            var i: usize = 0;
            while (i < end) {
                const width: usize = if (i + 1 < end and cells[i + 1].cont) 2 else 1;
                if (chunks.items[chunks.items.len - 1].len + width > cols) try chunks.append(gpa, .{ .start = i, .len = 0 });
                const tail = &chunks.items[chunks.items.len - 1];
                for (0..width) |_| {
                    try at.append(gpa, .{ .seg = chunks.items.len - 1, .col = tail.len });
                    tail.len += 1;
                }
                i += width;
            }
            if (lg.cursor) |cursor_cell| {
                const tail_len = chunks.items[chunks.items.len - 1].len;
                var seg: usize = undefined;
                var col: usize = undefined;
                if (cursor_cell < at.items.len) {
                    seg = at.items[cursor_cell].seg;
                    col = at.items[cursor_cell].col;
                } else if (cursor_cell == end and end > 0 and tail_len == cols) {
                    // Just filled the last row: wait at its end (pending wrap).
                    seg = chunks.items.len - 1;
                    col = cols - 1;
                } else {
                    // Past the content: count on from the last row.
                    const past = tail_len + cursor_cell - end;
                    seg = chunks.items.len - 1 + past / cols;
                    col = past % cols;
                }
                while (chunks.items.len <= seg) try chunks.append(gpa, .{ .start = end, .len = 0 });
                new_cursor = .{ .row = out.items.len + seg, .col = col };
            }
            try out.ensureUnusedCapacity(gpa, chunks.items.len);
            for (chunks.items, 0..) |chunk, ci| {
                const row_cells = try self.blankRow(cols);
                @memcpy(row_cells[0..chunk.len], cells[chunk.start .. chunk.start + chunk.len]);
                out.appendAssumeCapacity(.{ .cells = row_cells, .wrapped = ci > 0 });
            }
        }

        // A full screen sits on the bottom, but the cursor stays on screen.
        // Rows below the screen are dropped, as screen.py drops them.
        const top = @min(out.items.len -| rows, new_cursor.row);
        const screen_end = @min(out.items.len, top + rows);
        const pad = rows - (screen_end - top);
        var history: std.ArrayList(Line) = .empty;
        var grid: std.ArrayList([]Cell) = .empty;
        var wrapped: std.ArrayList(bool) = .empty;
        errdefer {
            history.deinit(gpa);
            grid.deinit(gpa);
            wrapped.deinit(gpa);
        }
        try history.ensureTotalCapacity(gpa, top);
        try grid.ensureTotalCapacity(gpa, rows);
        try wrapped.ensureTotalCapacity(gpa, rows);
        // Padding rows go to the end of `out`, which still owns everything.
        const body_len = out.items.len;
        try out.ensureUnusedCapacity(gpa, pad);
        for (0..pad) |_| out.appendAssumeCapacity(.{ .cells = try self.blankRow(cols), .wrapped = false });

        // Ownership moves out of `out`; nothing below fails.
        for (out.items[0..top]) |line| history.appendAssumeCapacity(line);
        for (out.items[top..screen_end]) |line| {
            grid.appendAssumeCapacity(line.cells);
            wrapped.appendAssumeCapacity(line.wrapped);
        }
        for (out.items[body_len..]) |line| {
            grid.appendAssumeCapacity(line.cells);
            wrapped.appendAssumeCapacity(false);
        }
        for (out.items[screen_end..body_len]) |line| gpa.free(line.cells);
        out.clearRetainingCapacity();

        for (self.history.items) |line| gpa.free(line.cells);
        self.history.deinit(gpa);
        freeRows(gpa, &self.grid);
        self.wrapped.deinit(gpa);
        self.history = history;
        self.grid = grid;
        self.wrapped = wrapped;
        self.trimHistory();
        self.row = new_cursor.row - top;
        self.col = @min(new_cursor.col, cols - 1);
    }

    fn anyWritten(cells: []const Cell) bool {
        for (cells) |c| if (c.written) return true;
        return false;
    }

    // ---------------- read path ----------------

    pub fn cursor(self: *const Screen) Pos {
        return .{ .row = self.row, .col = self.col };
    }

    pub fn cellAt(self: *const Screen, row: usize, col: usize) Cell {
        return self.grid.items[row][col];
    }

    pub fn inAltScreen(self: *const Screen) bool {
        return self.alt != null;
    }

    /// A row's text: continuation cells skipped, trailing spaces dropped.
    pub fn appendCellsText(gpa: std.mem.Allocator, out: *std.ArrayList(u8), cells: []const Cell) !void {
        const start = out.items.len;
        for (cells) |c| {
            if (c.cont) continue;
            var buf: [4]u8 = undefined;
            try out.appendSlice(gpa, buf[0 .. std.unicode.utf8Encode(c.cp, &buf) catch unreachable]);
            for (c.marks[0..c.mark_count]) |mark| try out.appendSlice(gpa, buf[0 .. std.unicode.utf8Encode(mark, &buf) catch unreachable]);
        }
        var end = out.items.len;
        while (end > start and out.items[end - 1] == ' ') end -= 1;
        out.shrinkRetainingCapacity(end);
    }

    pub fn lineAlloc(self: *const Screen, gpa: std.mem.Allocator, row: usize) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        try appendCellsText(gpa, &out, self.grid.items[row]);
        return out.toOwnedSlice(gpa);
    }

    /// Scrollback line `index`, oldest first.
    pub fn historyLineAlloc(self: *const Screen, gpa: std.mem.Allocator, index: usize) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        try appendCellsText(gpa, &out, self.history.items[index].cells);
        return out.toOwnedSlice(gpa);
    }

    /// screen.py `line_attr_class`: the class of the row's first visible
    /// non-space character.
    pub fn lineClass(self: *const Screen, row: usize) Class {
        for (self.grid.items[row]) |c| {
            if (c.cont) continue;
            if (c.cp != ' ') return c.class;
        }
        return .plain;
    }

    pub fn findRow(self: *const Screen, needle: []const u8) !?usize {
        for (0..self.rows) |r| {
            const text = try self.lineAlloc(self.gpa, r);
            defer self.gpa.free(text);
            if (std.mem.indexOf(u8, text, needle) != null) return r;
        }
        return null;
    }

    /// Scrollback lines whose text contains `needle`.
    pub fn historyCount(self: *const Screen, needle: []const u8) !usize {
        var n: usize = 0;
        for (0..self.history.items.len) |i| {
            const text = try self.historyLineAlloc(self.gpa, i);
            defer self.gpa.free(text);
            if (std.mem.indexOf(u8, text, needle) != null) n += 1;
        }
        return n;
    }

    /// Rows on screen whose text contains `needle`.
    pub fn screenCount(self: *const Screen, needle: []const u8) !usize {
        var n: usize = 0;
        for (0..self.rows) |r| {
            const text = try self.lineAlloc(self.gpa, r);
            defer self.gpa.free(text);
            if (std.mem.indexOf(u8, text, needle) != null) n += 1;
        }
        return n;
    }

    pub const Scope = enum { screen, history };

    /// Rows (on screen, or in the scrollback) whose text satisfies `pred`.
    pub fn countRows(self: *const Screen, scope: Scope, pred: *const fn ([]const u8) bool) !usize {
        const n = switch (scope) {
            .screen => self.rows,
            .history => self.history.items.len,
        };
        var count: usize = 0;
        for (0..n) |i| {
            const text = switch (scope) {
                .screen => try self.lineAlloc(self.gpa, i),
                .history => try self.historyLineAlloc(self.gpa, i),
            };
            defer self.gpa.free(text);
            if (pred(text)) count += 1;
        }
        return count;
    }

    pub const TranscriptOptions = struct {
        /// Follow each line that has styled cells with its style runs.
        styles: bool = false,
    };

    /// Everything the terminal has shown, top to bottom: the scrollback,
    /// then the screen, without the blank rows at the bottom. Lines are
    /// joined with '\n'. With `styles`, a line whose cells carry any SGR
    /// style is followed by `  ~ <runs>` naming each run's columns and style.
    pub fn transcriptAlloc(self: *const Screen, gpa: std.mem.Allocator, opts: TranscriptOptions) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        var keep_len: usize = 0;
        const total = self.history.items.len + self.rows;
        for (0..total) |i| {
            const cells = if (i < self.history.items.len) self.history.items[i].cells else self.grid.items[i - self.history.items.len];
            if (i > 0) try out.append(gpa, '\n');
            const line_start = out.items.len;
            try appendCellsText(gpa, &out, cells);
            const has_text = out.items.len > line_start;
            if (opts.styles) try appendStyleRuns(gpa, &out, cells);
            if (has_text or out.items.len > line_start) keep_len = out.items.len;
        }
        out.shrinkRetainingCapacity(keep_len);
        return out.toOwnedSlice(gpa);
    }

    fn appendStyleRuns(gpa: std.mem.Allocator, out: *std.ArrayList(u8), cells: []const Cell) !void {
        var col: usize = 0;
        var wrote_marker = false;
        while (col < cells.len) {
            const st = cells[col].style;
            var end = col + 1;
            while (end < cells.len and cells[end].style.eql(st)) end += 1;
            if (!st.isDefault() and anyWritten(cells[col..end])) {
                if (!wrote_marker) {
                    try out.appendSlice(gpa, "  ~");
                    wrote_marker = true;
                }
                try out.print(gpa, " {d}-{d}:", .{ col, end - 1 });
                try appendStyle(gpa, out, st);
            }
            col = end;
        }
    }

    fn appendStyle(gpa: std.mem.Allocator, out: *std.ArrayList(u8), st: Style) !void {
        const flags = [_]struct { on: bool, name: []const u8 }{
            .{ .on = st.bold, .name = "b" },
            .{ .on = st.dim, .name = "d" },
            .{ .on = st.italic, .name = "i" },
            .{ .on = st.underline, .name = "u" },
            .{ .on = st.reverse, .name = "r" },
            .{ .on = st.strike, .name = "s" },
        };
        for (flags) |f| if (f.on) try out.appendSlice(gpa, f.name);
        try appendColor(gpa, out, "fg", st.fg);
        try appendColor(gpa, out, "bg", st.bg);
    }

    fn appendColor(gpa: std.mem.Allocator, out: *std.ArrayList(u8), which: []const u8, c: Color) !void {
        switch (c) {
            .default => {},
            .basic => |v| try out.print(gpa, "/{s}{d}", .{ which, v }),
            .indexed => |v| try out.print(gpa, "/{s}#{d}", .{ which, v }),
            .rgb => |v| try out.print(gpa, "/{s}({d},{d},{d})", .{ which, v[0], v[1], v[2] }),
        }
    }

    /// Human-readable state for failure messages: the scrollback tail, the
    /// screen with row numbers, the cursor and the frame counters.
    pub fn dumpAlloc(self: *const Screen, gpa: std.mem.Allocator) ![]u8 {
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(gpa);
        const shown = @min(self.history.items.len, 12);
        try out.print(gpa, "-- scrollback: {d} lines ({d} dropped), last {d}:\n", .{ self.history.items.len, self.history_dropped, shown });
        for (self.history.items.len - shown..self.history.items.len) |i| {
            try out.appendSlice(gpa, "   |");
            try appendCellsText(gpa, &out, self.history.items[i].cells);
            try out.append(gpa, '\n');
        }
        try out.print(gpa, "-- screen {d}x{d}{s}:\n", .{ self.rows, self.cols, if (self.alt != null) " (alternate)" else "" });
        for (self.grid.items, 0..) |cells, r| {
            try out.print(gpa, "{d:>3}|", .{r});
            try appendCellsText(gpa, &out, cells);
            if (r == self.row) try out.print(gpa, "   <cursor col={d}>", .{self.col});
            try out.append(gpa, '\n');
        }
        try out.print(gpa, "-- sync depth={d} frames={d} stray_ends={d}; cursor {s}\n", .{
            self.sync_depth,
            self.sync_frames,
            self.stray_sync_ends,
            if (self.cursor_visible) "shown" else "hidden",
        });
        return out.toOwnedSlice(gpa);
    }

    fn printDump(self: *const Screen) void {
        const dump = self.dumpAlloc(self.gpa) catch return;
        defer self.gpa.free(dump);
        std.debug.print("{s}", .{dump});
    }

    // ---------------- assertions ----------------

    /// Row `row` shows exactly `expected` (trailing spaces ignored).
    pub fn expectLine(self: *const Screen, row: usize, expected: []const u8) !void {
        const text = try self.lineAlloc(self.gpa, row);
        defer self.gpa.free(text);
        if (std.mem.eql(u8, text, expected)) return;
        std.debug.print("vterm: row {d} shows \"{s}\", expected \"{s}\"\n", .{ row, text, expected });
        self.printDump();
        return error.TestExpectedEqual;
    }

    /// The character at (row, col) is `expected` (one code point, UTF-8).
    /// A continuation cell matches "".
    pub fn expectCell(self: *const Screen, row: usize, col: usize, expected: []const u8) !void {
        const c = self.cellAt(row, col);
        var buf: [4]u8 = undefined;
        const got: []const u8 = if (c.cont) "" else buf[0 .. std.unicode.utf8Encode(c.cp, &buf) catch unreachable];
        if (std.mem.eql(u8, got, expected)) return;
        std.debug.print("vterm: cell ({d},{d}) shows \"{s}\", expected \"{s}\"\n", .{ row, col, got, expected });
        self.printDump();
        return error.TestExpectedEqual;
    }

    /// The scrollback ends with exactly these lines.
    pub fn expectHistoryTail(self: *const Screen, expected: []const []const u8) !void {
        const n = self.history.items.len;
        var ok = n >= expected.len;
        if (ok) {
            for (expected, n - expected.len..) |want, i| {
                const text = try self.historyLineAlloc(self.gpa, i);
                defer self.gpa.free(text);
                if (!std.mem.eql(u8, text, want)) {
                    ok = false;
                    break;
                }
            }
        }
        if (ok) return;
        std.debug.print("vterm: scrollback tail differs; expected:\n", .{});
        for (expected) |want| std.debug.print("   |{s}\n", .{want});
        self.printDump();
        return error.TestExpectedEqual;
    }
};

/// Display width the terminal gives a code point: terminal_width.zig, the
/// Unicode tables scripts/gen_char_width.py writes for this file and for
/// screen.py `char_width`. A terminal model, not the TUI's own estimate.
pub fn charWidth(cp: u21) u2 {
    if (cp < 0xA0) return if (cp < 0x20 or cp == 0x7F) 0 else 1;
    if (inRanges(&terminal_width.zero, cp)) return 0;
    if (inRanges(&terminal_width.wide, cp)) return 2;
    return 1;
}

fn inRanges(ranges: []const [2]u21, cp: u21) bool {
    var lo: usize = 0;
    var hi: usize = ranges.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (cp < ranges[mid][0]) {
            hi = mid;
        } else if (cp > ranges[mid][1]) {
            lo = mid + 1;
        } else return true;
    }
    return false;
}
