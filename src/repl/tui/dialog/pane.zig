//! Command dialogs (`/login`, `/skills`, `/help`) drawn as Claude Code's
//! bottom pane:
//!
//!     ▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔▔
//!       Login
//!
//!       Select a provider:
//!
//!       ❯ 1. Anthropic · claude.ai
//!         2. OpenAI · chatgpt.com
//!
//!       Esc to cancel
//!
//! `Pane` builds one frame (pure: bytes plus the rows they occupy); `run`
//! is the modal key loop that owns the terminal while the dialog is open.
//! Commands run after the prompt has been read and its region erased, so
//! the dialog draws below the scrollback and erases itself on close; the
//! command then prints its one-line outcome (`⎿  Login interrupted`).

const std = @import("std");
const pfs = @import("platform").fs;
const platform_term = @import("platform").terminal;
const ansi = @import("../ansi.zig");
const term = @import("../term.zig");
const reflow = @import("../reflow.zig");
const input = @import("../../input.zig");
const Theme = @import("../theme.zig").Theme;

pub const INDENT = "  ";
const POINTER = "❯";
const POINTER_ASCII = ">";
const RULE = "▔";
const RULE_ASCII = "-";

fn unicode(th: Theme) bool {
    return !std.mem.eql(u8, th.box_h, "-");
}

fn styled(th: Theme) bool {
    return th.reset.len != 0;
}

/// One frame. Every line is either clipped to the width or, for `raw`, left
/// to the terminal's own wrapping with its rows counted, so `rows` is exact.
pub const Pane = struct {
    allocator: std.mem.Allocator,
    th: Theme,
    cols: usize,
    bytes: std.ArrayList(u8) = .empty,
    rows: usize = 0,
    /// Lines written (a `raw` line the terminal wraps is one line, several rows).
    lines: usize = 0,
    /// Display column the cursor should rest on in the last row that asked
    /// for it (a search box), with that row's line; null leaves the cursor hidden.
    cursor: ?struct { row: usize, col: usize, line: usize } = null,

    pub fn init(allocator: std.mem.Allocator, th: Theme, cols: usize) Pane {
        return .{ .allocator = allocator, .th = th, .cols = @max(cols, 20) };
    }

    pub fn deinit(self: *Pane) void {
        self.bytes.deinit(self.allocator);
    }

    fn newline(self: *Pane) !void {
        if (self.rows > 0) try self.bytes.appendSlice(self.allocator, "\r\n");
        try self.bytes.appendSlice(self.allocator, ansi.clear.line);
        self.lines += 1;
    }

    /// The rule that opens the pane.
    pub fn rule(self: *Pane) !void {
        try self.newline();
        const glyph = if (unicode(self.th)) RULE else RULE_ASCII;
        try self.bytes.appendSlice(self.allocator, self.th.dim);
        var i: usize = 0;
        while (i < self.cols) : (i += 1) try self.bytes.appendSlice(self.allocator, glyph);
        try self.bytes.appendSlice(self.allocator, self.th.reset);
        self.rows += 1;
    }

    pub fn blank(self: *Pane) !void {
        try self.newline();
        self.rows += 1;
    }

    /// An indented line, clipped to the width. `style` precedes the text.
    pub fn line(self: *Pane, style: []const u8, value: []const u8) !void {
        try self.newline();
        try self.bytes.appendSlice(self.allocator, INDENT);
        try self.bytes.appendSlice(self.allocator, style);
        _ = try self.appendClipped(value, self.cols -| (INDENT.len + 1));
        if (style.len != 0) try self.bytes.appendSlice(self.allocator, self.th.reset);
        self.rows += 1;
    }

    pub fn title(self: *Pane, value: []const u8) !void {
        try self.line(if (styled(self.th)) ansi.sgr.bold else "", value);
    }

    pub fn text(self: *Pane, value: []const u8) !void {
        try self.line("", value);
    }

    pub fn dim(self: *Pane, value: []const u8) !void {
        try self.line(self.th.dim, value);
    }

    /// Indented prose wrapped at word boundaries onto further indented rows.
    /// A word wider than a row (a URL) gets a row of its own at column 0,
    /// whole, so it can be copied (`raw`).
    pub fn paragraph(self: *Pane, style: []const u8, value: []const u8) !void {
        const width = self.cols -| (INDENT.len + 1);
        var rest = std.mem.trim(u8, value, " ");
        while (rest.len > 0) {
            const word_end = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
            if (term.displayWidth(rest[0..word_end]) > width) {
                try self.raw(rest[0..word_end]);
                rest = std.mem.trimStart(u8, rest[word_end..], " ");
                continue;
            }
            // The first word fits, so the cut falls at a space.
            const cut = wrapPoint(rest, width);
            try self.line(style, std.mem.trimEnd(u8, rest[0..cut], " "));
            rest = std.mem.trimStart(u8, rest[cut..], " ");
        }
    }

    pub const Span = struct { style: []const u8 = "", text: []const u8 };

    /// An indented line of differently styled pieces (a tab bar), clipped to
    /// the width by its visible text.
    pub fn spans(self: *Pane, parts: []const Span) !void {
        try self.newline();
        try self.bytes.appendSlice(self.allocator, INDENT);
        var room = self.cols -| (INDENT.len + 1);
        for (parts) |part| {
            if (room == 0) break;
            try self.bytes.appendSlice(self.allocator, part.style);
            room -|= try self.appendClipped(part.text, room);
            if (part.style.len != 0) try self.bytes.appendSlice(self.allocator, self.th.reset);
        }
        self.rows += 1;
    }

    /// The pane's key hint, dim and italic like Claude Code's.
    pub fn footer(self: *Pane, hint: []const u8) !void {
        try self.line(if (styled(self.th)) ansi.sgr.dim ++ ansi.sgr.italic else "", hint);
    }

    /// A list row: `❯ 1. label  detail` when selected, two spaces otherwise.
    pub fn option(self: *Pane, number: ?usize, selected: bool, label: []const u8, detail: []const u8) !void {
        try self.newline();
        try self.bytes.appendSlice(self.allocator, INDENT);
        const pointer = if (unicode(self.th)) POINTER else POINTER_ASCII;
        var used: usize = INDENT.len;
        if (selected) {
            try self.bytes.appendSlice(self.allocator, self.th.accent);
            try self.bytes.appendSlice(self.allocator, pointer);
            try self.bytes.append(self.allocator, ' ');
        } else {
            try self.bytes.appendSlice(self.allocator, "  ");
        }
        used += 2;
        var num_buf: [16]u8 = undefined;
        if (number) |n| {
            const num = std.fmt.bufPrint(&num_buf, "{d}. ", .{n}) catch "";
            try self.bytes.appendSlice(self.allocator, num);
            used += num.len;
        }
        const room = self.cols -| (used + 1);
        used += try self.appendClipped(label, room);
        if (selected) try self.bytes.appendSlice(self.allocator, self.th.reset);
        if (detail.len != 0 and used + 4 < self.cols) {
            try self.bytes.appendSlice(self.allocator, self.th.dim);
            try self.bytes.appendSlice(self.allocator, " · ");
            used += 3;
            _ = try self.appendClipped(detail, self.cols -| (used + 1));
            try self.bytes.appendSlice(self.allocator, self.th.reset);
        }
        self.rows += 1;
    }

    /// A line the user may need to copy whole (a URL, a code): written at
    /// column 0, unclipped, wrapped by the terminal; its rows are counted.
    pub fn raw(self: *Pane, value: []const u8) !void {
        try self.newline();
        try self.bytes.appendSlice(self.allocator, value);
        const width = term.displayWidth(value);
        self.rows += @max(1, (width + self.cols - 1) / self.cols);
    }

    /// A one-line input box: `⌕ query▏` (placeholder dim when empty); the
    /// terminal cursor rests after the query.
    pub fn search(self: *Pane, query: []const u8, placeholder: []const u8) !void {
        try self.newline();
        try self.bytes.appendSlice(self.allocator, INDENT);
        const glyph = if (unicode(self.th)) "⌕ " else "/ ";
        try self.bytes.appendSlice(self.allocator, self.th.dim);
        try self.bytes.appendSlice(self.allocator, glyph);
        try self.bytes.appendSlice(self.allocator, self.th.reset);
        const prefix = INDENT.len + 2;
        if (query.len == 0) {
            try self.bytes.appendSlice(self.allocator, self.th.dim);
            _ = try self.appendClipped(placeholder, self.cols -| (prefix + 1));
            try self.bytes.appendSlice(self.allocator, self.th.reset);
            self.cursor = .{ .row = self.rows, .col = prefix, .line = self.lines - 1 };
        } else {
            const shown = try self.appendClipped(query, self.cols -| (prefix + 1));
            self.cursor = .{ .row = self.rows, .col = prefix + shown, .line = self.lines - 1 };
        }
        self.rows += 1;
    }

    /// Append `value` cut to `max_w` display columns (an ellipsis marks the
    /// cut); returns the columns written.
    fn appendClipped(self: *Pane, value: []const u8, max_w: usize) !usize {
        const width = term.displayWidth(value);
        if (width <= max_w) {
            try self.bytes.appendSlice(self.allocator, value);
            return width;
        }
        if (max_w == 0) return 0;
        const cut = wrapPoint(value, max_w - 1);
        try self.bytes.appendSlice(self.allocator, value[0..cut]);
        try self.bytes.appendSlice(self.allocator, if (unicode(self.th)) "…" else "~");
        return term.displayWidth(value[0..cut]) + 1;
    }
};

/// Largest prefix of `s` that fits `max_w` columns, cut after a space when
/// one fits (always at least one codepoint).
fn wrapPoint(s: []const u8, max_w: usize) usize {
    var i: usize = 0;
    var w: usize = 0;
    var last_space: ?usize = null;
    while (i < s.len) {
        const cp_len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        const e = @min(i + cp_len, s.len);
        const cw = term.displayWidth(s[i..e]);
        if (w + cw > max_w) {
            // A space that does not fit is itself the break.
            if (s[i] == ' ' and i > 0) return i;
            if (last_space) |sp| if (sp > 0) return sp + 1;
            return if (i == 0) e else i;
        }
        if (s[i] == ' ') last_space = i;
        w += cw;
        i = e;
    }
    return s.len;
}

// ── The modal loop ──────────────────────────────────────────────────────────

/// What a dialog asks of the loop after a key or a tick.
pub const Step = enum {
    /// Nothing visible changed.
    none,
    /// Draw the frame again.
    redraw,
    /// The dialog is finished; the loop erases it and returns.
    done,
};

/// Run `dialog` until it reports `.done`. `D` provides
///   `fn draw(self: *D, pane: *Pane) anyerror!void`,
///   `fn key(self: *D, key: input.Key) Step`, and
///   `fn tick(self: *D) Step` (called about every 100 ms, for dialogs that
///   watch something asynchronous such as a sign-in).
/// Esc reaches `key` like any other key; the dialog decides what it means.
/// A closed terminal reads as Ctrl+C. The frame is erased before returning.
pub fn run(comptime D: type, dialog: *D, allocator: std.mem.Allocator, th: Theme, in_fd: c_int, out_fd: c_int) !void {
    const saved = input.enterRawMode(in_fd);
    defer if (saved) |mode| input.restoreMode(in_fd, mode);

    var parser = input.KeyParser{};
    var drawn_cols: u16 = 0;
    // Where the last frame left the cursor. A narrower terminal re-wraps the
    // pane's full-width rule onto two rows, so the climb back to the frame's
    // first row counts the rows it takes now (reflow.zig).
    var drawn: reflow.Anchor = .{};
    const reflows = term.reflowFromEnv();
    var dirty = true;
    defer {
        erase(out_fd, drawn.climb(terminalCols(out_fd), reflows));
        writeAll(out_fd, ansi.cursor.show);
    }

    while (true) {
        if (dirty) {
            const cols = terminalCols(out_fd);
            drawn_cols = cols;
            var pane = Pane.init(allocator, th, cols);
            defer pane.deinit();
            try dialog.draw(&pane);
            var frame: std.ArrayList(u8) = .empty;
            defer frame.deinit(allocator);
            try frame.appendSlice(allocator, ansi.sync.begin);
            try frame.appendSlice(allocator, ansi.cursor.hide);
            try appendErase(&frame, allocator, drawn.climb(cols, reflows));
            try frame.appendSlice(allocator, pane.bytes.items);
            try frame.appendSlice(allocator, ansi.clear.to_end_of_screen);
            drawn = reflow.Anchor.atEnd(pane.bytes.items, cols);
            if (pane.cursor) |at| {
                var buf: [16]u8 = undefined;
                const last_row = pane.rows -| 1;
                if (last_row > at.row) try frame.appendSlice(allocator, ansi.cursor.up(@intCast(last_row - at.row), &buf));
                try frame.appendSlice(allocator, "\r");
                if (at.col > 0) try frame.appendSlice(allocator, ansi.cursor.forward(@intCast(at.col), &buf));
                try frame.appendSlice(allocator, ansi.cursor.show);
                drawn = reflow.Anchor.measure(pane.bytes.items, @intCast(at.line), @intCast(at.col), cols);
            }
            try frame.appendSlice(allocator, ansi.sync.end);
            writeAll(out_fd, frame.items);
            dirty = false;
        }

        const key: input.Key = key: {
            if (parser.drain()) |pending| break :key pending;
            const rc = platform_term.waitReadable(in_fd, 100);
            if (rc <= 0) {
                if (parser.flushEsc()) |esc| break :key esc;
                // A resize interrupts the wait (or shows on the next tick):
                // draw again at the new width.
                if (terminalCols(out_fd) != drawn_cols) dirty = true;
                switch (dialog.tick()) {
                    .none => {},
                    .redraw => dirty = true,
                    .done => return,
                }
                continue;
            }
            var byte: [1]u8 = undefined;
            const n = platform_term.readInput(in_fd, &byte);
            if (n < 0 and input.retryInterruptedRead(in_fd)) continue;
            if (n <= 0) break :key .ctrl_c;
            break :key parser.feedRead(in_fd, byte[0]) orelse continue;
        };
        switch (dialog.key(key)) {
            .none => {},
            .redraw => dirty = true,
            .done => return,
        }
    }
}

fn terminalCols(out_fd: c_int) u16 {
    return if (term.getSize(out_fd)) |size| size.cols else 80;
}

/// Climb `rows` from the cursor to the frame's first row and clear
/// everything below.
fn appendErase(frame: *std.ArrayList(u8), allocator: std.mem.Allocator, rows: u16) !void {
    var buf: [16]u8 = undefined;
    try frame.appendSlice(allocator, "\r");
    if (rows > 0) try frame.appendSlice(allocator, ansi.cursor.up(rows, &buf));
    try frame.appendSlice(allocator, ansi.clear.to_end_of_screen);
}

fn erase(out_fd: c_int, rows: u16) void {
    var frame: std.ArrayList(u8) = .empty;
    defer frame.deinit(std.heap.c_allocator);
    appendErase(&frame, std.heap.c_allocator, rows) catch return;
    writeAll(out_fd, frame.items);
}

fn writeAll(fd: c_int, bytes: []const u8) void {
    @import("../screen_mirror.zig").feed(fd, bytes);
    _ = pfs.writeAll(fd, bytes); // a resize (EINTR) is retried, not half a frame
}

// ── tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;
const theme_mod = @import("../theme.zig");

fn stripAnsi(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < bytes.len) {
        if (bytes[i] == 0x1b and i + 1 < bytes.len and bytes[i + 1] == '[') {
            var j = i + 2;
            while (j < bytes.len and !(bytes[j] >= 0x40 and bytes[j] <= 0x7e)) j += 1;
            i = j + 1;
            continue;
        }
        if (bytes[i] == '\r') {
            i += 1;
            continue;
        }
        try out.append(allocator, bytes[i]);
        i += 1;
    }
    return out.toOwnedSlice(allocator);
}

test "pane: rows match the lines written and the pointer marks the selection" {
    var pane = Pane.init(testing.allocator, theme_mod.monochrome, 40);
    defer pane.deinit();
    try pane.rule();
    try pane.title("Login");
    try pane.blank();
    try pane.option(1, true, "anthropic", "claude.ai");
    try pane.option(2, false, "openai", "");
    try pane.blank();
    try pane.footer("Esc to cancel");
    try testing.expectEqual(@as(usize, 7), pane.rows);
    const plain = try stripAnsi(testing.allocator, pane.bytes.items);
    defer testing.allocator.free(plain);
    try testing.expectEqual(@as(usize, 6), std.mem.count(u8, plain, "\n"));
    try testing.expect(std.mem.indexOf(u8, plain, "  > 1. anthropic · claude.ai\n") != null);
    try testing.expect(std.mem.indexOf(u8, plain, "    2. openai\n") != null);
    try testing.expect(std.mem.endsWith(u8, plain, "  Esc to cancel"));
}

test "pane: long lines are clipped, raw lines keep every byte and count wrapped rows" {
    var pane = Pane.init(testing.allocator, theme_mod.monochrome, 20);
    defer pane.deinit();
    try pane.text("abcdefghijklmnopqrstuvwxyz");
    try pane.raw("https://example.test/authorize?state=0123456789");
    try testing.expectEqual(@as(usize, 1 + 3), pane.rows);
    const plain = try stripAnsi(testing.allocator, pane.bytes.items);
    defer testing.allocator.free(plain);
    try testing.expect(std.mem.indexOf(u8, plain, "  abcdefghijklmnop~\n") != null);
    try testing.expect(std.mem.endsWith(u8, plain, "https://example.test/authorize?state=0123456789"));
}

test "pane: paragraph wraps at words under the indent" {
    var pane = Pane.init(testing.allocator, theme_mod.monochrome, 24);
    defer pane.deinit();
    try pane.paragraph("", "Sign in to a provider to use its models here.");
    const plain = try stripAnsi(testing.allocator, pane.bytes.items);
    defer testing.allocator.free(plain);
    try testing.expectEqualStrings("  Sign in to a provider\n  to use its models\n  here.", plain);
    try testing.expectEqual(@as(usize, 3), pane.rows);
}

test "pane: a word wider than a row (a URL) gets its own unclipped row" {
    var pane = Pane.init(testing.allocator, theme_mod.monochrome, 30);
    defer pane.deinit();
    try pane.paragraph("", "Open https://auth.example.test/device?code=ABCD-1234 and enter ABCD-1234");
    const plain = try stripAnsi(testing.allocator, pane.bytes.items);
    defer testing.allocator.free(plain);
    try testing.expectEqualStrings("  Open\nhttps://auth.example.test/device?code=ABCD-1234\n  and enter ABCD-1234", plain);
    try testing.expectEqual(@as(usize, 1 + 2 + 1), pane.rows);
}

test "pane: the search box places the cursor after the query" {
    var pane = Pane.init(testing.allocator, theme_mod.monochrome, 40);
    defer pane.deinit();
    try pane.title("Skills");
    try pane.search("", "Search skills…");
    try testing.expectEqual(@as(usize, 1), pane.cursor.?.row);
    try testing.expectEqual(@as(usize, 4), pane.cursor.?.col);
    try pane.search("rev", "Search skills…");
    try testing.expectEqual(@as(usize, 2), pane.cursor.?.row);
    try testing.expectEqual(@as(usize, 7), pane.cursor.?.col);
    try testing.expectEqual(@as(usize, 2), pane.cursor.?.line);
}

// The loop climbs from the search box to the pane's first row by lines, and
// a `raw` line the terminal wraps is one line on several rows: at a narrower
// width the climb still lands on the rule.
test "pane: the climb from the search box counts the rows a wrapped line takes" {
    var pane = Pane.init(testing.allocator, theme_mod.monochrome, 40);
    defer pane.deinit();
    try pane.rule();
    try pane.raw("https://auth.example.test/device?code=ABCD-1234-EFGH-5678");
    try pane.search("", "Search…");
    const at = pane.cursor.?;
    try testing.expectEqual(@as(usize, 3), at.row);
    try testing.expectEqual(@as(usize, 2), at.line);
    const anchor = reflow.Anchor.measure(pane.bytes.items, @intCast(at.line), @intCast(at.col), 40);
    // Drawn at 40: rule 1 row, URL (57) 2 rows.
    try testing.expectEqual(@as(u16, 3), anchor.climb(40, true));
    try testing.expectEqual(@as(u16, 3), anchor.climb(40, false));
    // At 20 columns: rule 2 rows, URL 3 rows.
    try testing.expectEqual(@as(u16, 5), anchor.climb(20, true));
}
