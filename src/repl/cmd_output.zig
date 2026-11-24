//! Local slash-command results in the scrollback, shaped like Claude Code's:
//!
//!     ❯ /cost
//!       ⎿  Usage (claude-sonnet-4):
//!          input   0 tokens
//!
//! The first line hangs off a dim `⎿`; every later line, and every row a long
//! line wraps onto, sits under it at the same five-column indent. Wrapping is by
//! display width, skips ANSI escapes, and prefers word boundaries.
//!
//! `Shaper` is the pure part (bytes in, shaped bytes out). The module-level
//! `begin` / `print` / `end` drive one shaper for the REPL's main thread: the
//! command dispatcher opens a block around a local command, and the handlers
//! print through `print`, which falls back to plain `std.debug.print` when no
//! block is open — so a handler is shaped exactly when it runs as a command.

const std = @import("std");
const term = @import("tui/term.zig");
const screen_mirror = @import("tui/screen_mirror.zig");

/// Columns before the result text: `  ⎿  ` and the continuation indent.
pub const INDENT: usize = 5;
const FIRST_PREFIX_LEAD = "  ";
const FIRST_PREFIX_TAIL = "  ";
const CONTINUATION = "     ";

pub const Shaper = struct {
    allocator: std.mem.Allocator,
    /// Terminal columns; at or below `INDENT + 8` lines are not wrapped.
    cols: usize,
    dim: []const u8 = "",
    reset: []const u8 = "",
    /// The theme's gutter: `⎿`, or `\` without Unicode.
    gutter: []const u8 = "⎿",
    line: std.ArrayList(u8) = .empty,
    /// No content line has been emitted yet: the next one takes `⎿`, and
    /// blank lines before it are dropped.
    first: bool = true,

    pub fn init(allocator: std.mem.Allocator, cols: usize, dim: []const u8, reset: []const u8, gutter: []const u8) Shaper {
        return .{ .allocator = allocator, .cols = cols, .dim = dim, .reset = reset, .gutter = gutter };
    }

    pub fn deinit(self: *Shaper) void {
        self.line.deinit(self.allocator);
    }

    /// Shape `bytes`; complete lines go to `out`, a partial line waits for its
    /// newline or `finish`.
    pub fn feed(self: *Shaper, out: *std.ArrayList(u8), bytes: []const u8) !void {
        var rest = bytes;
        while (std.mem.indexOfScalar(u8, rest, '\n')) |nl| {
            try self.line.appendSlice(self.allocator, rest[0..nl]);
            try self.emitLine(out);
            rest = rest[nl + 1 ..];
        }
        try self.line.appendSlice(self.allocator, rest);
    }

    /// Emit a pending partial line.
    pub fn finish(self: *Shaper, out: *std.ArrayList(u8)) !void {
        if (self.line.items.len > 0) try self.emitLine(out);
    }

    fn emitLine(self: *Shaper, out: *std.ArrayList(u8)) !void {
        defer self.line.clearRetainingCapacity();
        const text = std.mem.trimEnd(u8, self.line.items, " \r");
        if (visibleWidth(text) == 0) {
            // Blank lines inside the result keep their place; before the first
            // content line they would only push it away from the command.
            if (!self.first) try out.append(self.allocator, '\n');
            return;
        }
        const avail: usize = if (self.cols > INDENT + 8) self.cols - INDENT else 0;
        var start: usize = 0;
        while (true) {
            if (self.first) {
                try out.appendSlice(self.allocator, FIRST_PREFIX_LEAD);
                try out.appendSlice(self.allocator, self.dim);
                try out.appendSlice(self.allocator, self.gutter);
                try out.appendSlice(self.allocator, self.reset);
                try out.appendSlice(self.allocator, FIRST_PREFIX_TAIL);
                self.first = false;
            } else {
                try out.appendSlice(self.allocator, CONTINUATION);
            }
            const brk = if (avail == 0) Break{ .end = text.len, .next = text.len } else wrapAt(text, start, avail);
            try out.appendSlice(self.allocator, text[start..brk.end]);
            try out.append(self.allocator, '\n');
            if (brk.next >= text.len) break;
            start = brk.next;
        }
    }
};

const Break = struct {
    /// End of this row's bytes.
    end: usize,
    /// Where the next row starts (a breaking space is skipped).
    next: usize,
};

/// The row starting at `start` that fits `max_w` display columns, broken after
/// the last space that fits when there is one. ANSI escapes take no columns and
/// are never split. Always advances by at least one codepoint.
fn wrapAt(s: []const u8, start: usize, max_w: usize) Break {
    var i = start;
    var w: usize = 0;
    var last_space: ?usize = null;
    while (i < s.len) {
        if (s[i] == 0x1b) {
            i = escapeEnd(s, i);
            continue;
        }
        const cp_len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        const e = @min(i + cp_len, s.len);
        const cw = term.displayWidth(s[i..e]);
        if (w + cw > max_w) {
            // A space that does not fit is itself the break.
            if (s[i] == ' ' and i > start) return .{ .end = i, .next = i + 1 };
            // A word that fits a row moves to the next one; one wider than any
            // row (a path, a URL) is cut here instead, so it starts on this row.
            if (last_space) |sp| if (sp > start and wordWidth(s, sp + 1) <= max_w)
                return .{ .end = sp, .next = sp + 1 };
            if (i == start) return .{ .end = e, .next = e };
            return .{ .end = i, .next = i };
        }
        if (s[i] == ' ') last_space = i;
        w += cw;
        i = e;
    }
    return .{ .end = s.len, .next = s.len };
}

/// Display width of the word starting at `from` (up to the next space).
fn wordWidth(s: []const u8, from: usize) usize {
    const stop = std.mem.indexOfScalarPos(u8, s, from, ' ') orelse s.len;
    return visibleWidth(s[from..stop]);
}

/// Index just past the escape sequence at `i` (CSI, OSC, or a two-byte escape).
fn escapeEnd(s: []const u8, i: usize) usize {
    if (i + 1 >= s.len) return s.len;
    switch (s[i + 1]) {
        '[' => {
            var j = i + 2;
            while (j < s.len) : (j += 1) {
                if (s[j] >= 0x40 and s[j] <= 0x7e) return j + 1;
            }
            return s.len;
        },
        ']' => {
            var j = i + 2;
            while (j < s.len) : (j += 1) {
                if (s[j] == 0x07) return j + 1;
                if (s[j] == 0x1b and j + 1 < s.len and s[j + 1] == '\\') return j + 2;
            }
            return s.len;
        },
        else => return i + 2,
    }
}

fn visibleWidth(s: []const u8) usize {
    var i: usize = 0;
    var w: usize = 0;
    while (i < s.len) {
        if (s[i] == 0x1b) {
            i = escapeEnd(s, i);
            continue;
        }
        const cp_len = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        const e = @min(i + cp_len, s.len);
        w += term.displayWidth(s[i..e]);
        i = e;
    }
    return w;
}

// ── The REPL's block (main thread only) ─────────────────────────────────────

var block: ?Shaper = null;
/// The command's own `❯ /cmd` line, written just before the block's first
/// output (or when it closes). Held back so that an unknown command can be
/// reported in its place, as Claude Code does.
var echo: ?[]u8 = null;

/// Open a result block: until `end`, `print` shapes its output. `echo_line`
/// (copied) is the command's echo, emitted ahead of the first result line.
pub fn begin(cols: usize, dim: []const u8, reset: []const u8, gutter: []const u8, echo_line: []const u8) void {
    if (block) |*b| b.deinit();
    dropEcho();
    block = Shaper.init(std.heap.c_allocator, cols, dim, reset, gutter);
    if (echo_line.len > 0) echo = std.heap.c_allocator.dupe(u8, echo_line) catch null;
}

/// Write the held echo now (before something other than `print` writes to
/// the terminal, such as a model run).
pub fn flushEcho() void {
    const line = echo orelse return;
    echo = null;
    defer std.heap.c_allocator.free(line);
    screen_mirror.feed(2, line);
    std.debug.print("{s}", .{line});
}

/// Forget the held echo: the command is reported some other way.
pub fn dropEcho() void {
    const line = echo orelse return;
    echo = null;
    std.heap.c_allocator.free(line);
}

/// Close the block, emitting the echo if nothing did and any partial line.
pub fn end() void {
    flushEcho();
    var b = block orelse return;
    block = null;
    defer b.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.heap.c_allocator);
    b.finish(&out) catch {};
    if (out.items.len > 0) {
        screen_mirror.feed(2, out.items);
        std.debug.print("{s}", .{out.items});
    }
}

/// Whether a block is open (a handler running as a local command).
pub fn active() bool {
    return block != null;
}

/// `std.debug.print`, shaped when a block is open.
pub fn print(comptime fmt: []const u8, args: anytype) void {
    const text = std.fmt.allocPrint(std.heap.c_allocator, fmt, args) catch return std.debug.print(fmt, args);
    defer std.heap.c_allocator.free(text);
    const b = if (block) |*value| value else {
        screen_mirror.feed(2, text);
        return std.debug.print("{s}", .{text});
    };
    flushEcho();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.heap.c_allocator);
    b.feed(&out, text) catch return std.debug.print("{s}", .{text});
    if (out.items.len > 0) {
        screen_mirror.feed(2, out.items);
        std.debug.print("{s}", .{out.items});
    }
}

/// What a `!cmd` run printed, from the Bash tool's JSON result: stdout as
/// is, stderr in yellow, `(No output)` dim when there was neither. Unshaped:
/// the REPL prints it into the open command block, a replayed session feeds
/// it through a `Shaper`.
pub fn shellOutputText(allocator: std.mem.Allocator, dim: []const u8, reset: []const u8, result: []const u8) error{OutOfMemory}![]u8 {
    // Decoded once, parity-correct (the web's shellCommandResult reads it the
    // same way); the old closing-quote scan misread a trailing backslash.
    const json_util = @import("../util/json.zig");
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    if (json_util.extractAndUnescapeStringField(result, "stdout", allocator) catch null) |u| {
        defer allocator.free(u);
        try out.appendSlice(allocator, u);
    }
    if (json_util.extractAndUnescapeStringField(result, "stderr", allocator) catch null) |u| {
        defer allocator.free(u);
        if (u.len > 0) try out.print(allocator, "\x1b[33m{s}\x1b[0m", .{u});
    }
    if (out.items.len == 0) try out.print(allocator, "{s}(No output){s}\n", .{ dim, reset });
    return out.toOwnedSlice(allocator);
}

/// Columns before a notice's text: the marker and a space.
const NOTICE_INDENT: usize = 2;

/// A one-line report in place of a command's echo (`⏺ Unknown command: …`):
/// `marker` (one column, may carry ANSI) and the text, wrapped at word
/// boundaries with later rows under the text, as Claude Code prints it.
pub fn notice(cols: usize, marker: []const u8, text: []const u8) void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(std.heap.c_allocator);
    noticeInto(&out, std.heap.c_allocator, cols, marker, text) catch
        return std.debug.print("{s} {s}\n", .{ marker, text });
    screen_mirror.feed(2, out.items);
    std.debug.print("{s}", .{out.items});
}

fn noticeInto(out: *std.ArrayList(u8), allocator: std.mem.Allocator, cols: usize, marker: []const u8, text: []const u8) !void {
    const avail: usize = if (cols > NOTICE_INDENT + 8) cols - NOTICE_INDENT else 0;
    var start: usize = 0;
    var first = true;
    while (true) {
        if (first) {
            try out.appendSlice(allocator, marker);
            try out.append(allocator, ' ');
            first = false;
        } else {
            try out.appendSlice(allocator, "  ");
        }
        const brk = if (avail == 0) Break{ .end = text.len, .next = text.len } else wrapAt(text, start, avail);
        try out.appendSlice(allocator, text[start..brk.end]);
        try out.append(allocator, '\n');
        if (brk.next >= text.len) break;
        start = brk.next;
    }
}

// ── tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

fn shape(cols: usize, text: []const u8) ![]u8 {
    var s = Shaper.init(testing.allocator, cols, "<d>", "<r>", "⎿");
    defer s.deinit();
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(testing.allocator);
    try s.feed(&out, text);
    try s.finish(&out);
    return out.toOwnedSlice(testing.allocator);
}

test "the first line hangs off a dim ⎿, later lines take the indent" {
    const got = try shape(80, "Usage:\n  input 0\n");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("  <d>⎿<r>  Usage:\n       input 0\n", got);
}

test "leading blank lines are dropped, inner ones kept, trailing spaces trimmed" {
    const got = try shape(80, "\n\nfirst  \n\nsecond");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("  <d>⎿<r>  first\n\n     second\n", got);
}

test "a space exactly at the edge is the break" {
    // cols 15 → 10 columns of text per row: "abcde fghi" fills the row and the
    // following space breaks it.
    const got = try shape(15, "abcde fghij klm");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("  <d>⎿<r>  abcde\n     fghij klm\n", got);
    const exact = try shape(15, "abcd efghi jkl");
    defer testing.allocator.free(exact);
    try testing.expectEqualStrings("  <d>⎿<r>  abcd efghi\n     jkl\n", exact);
}

test "a word wider than any row starts on the current row and is cut" {
    // 10 columns per row: the path cannot fit a row, so it is not pushed down.
    const got = try shape(15, "File: /a/very/long/path end");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("  <d>⎿<r>  File: /a/v\n     ery/long/p\n     ath end\n", got);
}

test "long lines wrap at a word boundary onto the indent" {
    // cols 20 → 15 columns of text per row.
    const got = try shape(20, "alpha beta gamma delta");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("  <d>⎿<r>  alpha beta\n     gamma delta\n", got);
}

test "a word longer than the row is split, escapes take no columns" {
    const got = try shape(15, "\x1b[31m/a/very/long/path\x1b[0m");
    defer testing.allocator.free(got);
    // 10 columns per row; the colour codes stay intact on the rows they open/close.
    try testing.expectEqualStrings("  <d>⎿<r>  \x1b[31m/a/very/lo\n     ng/path\x1b[0m\n", got);
}

test "wide characters count two columns" {
    const got = try shape(15, "中文中文中文中文");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("  <d>⎿<r>  中文中文中\n     文中文\n", got);
}

test "partial lines wait for their newline across feeds" {
    var s = Shaper.init(testing.allocator, 80, "", "", "⎿");
    defer s.deinit();
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try s.feed(&out, "hel");
    try testing.expectEqual(@as(usize, 0), out.items.len);
    try s.feed(&out, "lo\nwor");
    try testing.expectEqualStrings("  ⎿  hello\n", out.items);
    try s.finish(&out);
    try testing.expectEqualStrings("  ⎿  hello\n     wor\n", out.items);
}

test "a narrow terminal does not wrap" {
    const got = try shape(10, "abcdefghijklmnop");
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("  <d>⎿<r>  abcdefghijklmnop\n", got);
}

test "notice: wraps at a word and indents later rows under the text" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try noticeInto(&out, testing.allocator, 24, "*", "Skill \"demo\" is disabled via skillOverrides.");
    try testing.expectEqualStrings(
        "* Skill \"demo\" is\n  disabled via\n  skillOverrides.\n",
        out.items,
    );
    out.clearRetainingCapacity();
    try noticeInto(&out, testing.allocator, 80, "\x1b[33m*\x1b[0m", "short");
    try testing.expectEqualStrings("\x1b[33m*\x1b[0m short\n", out.items);
}
