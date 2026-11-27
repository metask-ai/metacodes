//! L2: the component-test virtual terminal (apps/cli/tests/component/vterm.zig, #319)
//! behaves like tests/tty/screen.py, and its additions work.
//!
//! Parity: tests/fixtures/vterm/screen_parity.jsonl is screen.py's complete
//! state (every cell, the scrollback, cursor, pending wrap, sync depth, alt
//! screen, buffered partial sequence) after each of a fixed corpus of byte
//! streams and resizes — semantic cases ported from tests/tty/cases plus a
//! seeded random corpus (tests/tty/vterm_parity.py). Every vector is replayed
//! here and must reach the same state. tests/tty/cases/test_vterm_parity.py
//! keeps the fixture equal to what screen.py answers today.

const std = @import("std");
const cc = @import("cc");
const vterm = @import("vterm.zig");

const testing = std.testing;
const FIXTURE = @embedFile("vterm_screen_parity");

const Resize = struct { rows: usize, cols: usize, reflow: bool };
const Op = struct { feed: ?[]const u8 = null, resize: ?Resize = null };
const Expect = struct {
    lines: []const []const u8,
    cursor: [2]usize,
    cursor_visible: bool,
    pending_wrap: bool,
    saved_cursor: [2]usize,
    scrolled: usize,
    sync_depth: usize,
    max_sync_depth: usize,
    alt: bool,
    pending_bytes: []const u8,
    classes: []const []const u8,
    grid: []const []const []const u8,
    wrapped: []const bool,
    history: []const []const []const u8,
    history_wrapped: []const bool,
};
const Vector = struct {
    name: []const u8,
    rows: usize,
    cols: usize,
    autowrap: bool,
    ops: []const Op,
    expect: Expect,
};

/// screen.py's cell token: `<ch><kind><class><written>`.
fn encodeCell(c: vterm.Cell, buf: *[20]u8) []const u8 {
    var n: usize = 0;
    if (!c.cont) {
        n = std.unicode.utf8Encode(c.cp, buf[0..4]) catch unreachable;
        for (c.marks[0..c.mark_count]) |mark| n += std.unicode.utf8Encode(mark, buf[n..][0..4]) catch unreachable;
    }
    buf[n] = if (c.cont) 'c' else '0' + @as(u8, c.width);
    buf[n + 1] = switch (c.class) {
        .plain => 'p',
        .dim => 'd',
        .accent => 'a',
        .warn => 'w',
        .danger => 'x',
    };
    buf[n + 2] = if (c.written) 'w' else '-';
    return buf[0 .. n + 3];
}

fn expectCells(name: []const u8, what: []const u8, index: usize, got: []const vterm.Cell, want: []const []const u8) !void {
    if (got.len != want.len) {
        std.debug.print("{s}: {s} {d} has {d} cells, screen.py {d}\n", .{ name, what, index, got.len, want.len });
        return error.TestExpectedEqual;
    }
    for (got, want, 0..) |c, tok, col| {
        var buf: [20]u8 = undefined;
        const enc = encodeCell(c, &buf);
        if (!std.mem.eql(u8, enc, tok)) {
            std.debug.print("{s}: {s} {d} col {d}: vterm \"{s}\", screen.py \"{s}\"\n", .{ name, what, index, col, enc, tok });
            return error.TestExpectedEqual;
        }
    }
}

fn mismatch(name: []const u8, field: []const u8, sc: *const vterm.Screen) error{TestExpectedEqual} {
    std.debug.print("{s}: {s} differs from screen.py\n", .{ name, field });
    const dump = sc.dumpAlloc(testing.allocator) catch return error.TestExpectedEqual;
    defer testing.allocator.free(dump);
    std.debug.print("{s}", .{dump});
    return error.TestExpectedEqual;
}

fn checkVector(gpa: std.mem.Allocator, v: Vector) !void {
    var sc = try vterm.Screen.init(gpa, v.rows, v.cols, .{ .autowrap = v.autowrap });
    defer sc.deinit();
    for (v.ops) |op| {
        if (op.feed) |hex| {
            const bytes = try gpa.alloc(u8, hex.len / 2);
            defer gpa.free(bytes);
            try sc.feed(try std.fmt.hexToBytes(bytes, hex));
        }
        if (op.resize) |r| try sc.resize(r.rows, r.cols, r.reflow);
    }
    const e = v.expect;
    if (sc.rows != e.grid.len) return mismatch(v.name, "row count", &sc);
    for (e.lines, 0..) |want, r| {
        const got = try sc.lineAlloc(gpa, r);
        defer gpa.free(got);
        if (!std.mem.eql(u8, got, want)) {
            std.debug.print("{s}: line {d} \"{s}\" vs screen.py \"{s}\"\n", .{ v.name, r, got, want });
            return mismatch(v.name, "line text", &sc);
        }
        if (!std.mem.eql(u8, @tagName(sc.lineClass(r)), e.classes[r])) return mismatch(v.name, "line class", &sc);
    }
    for (e.grid, 0..) |want, r| try expectCells(v.name, "row", r, sc.grid.items[r], want);
    if (!std.mem.eql(bool, sc.wrapped.items, e.wrapped)) return mismatch(v.name, "wrapped flags", &sc);
    if (sc.history.items.len != e.history.len) return mismatch(v.name, "scrollback length", &sc);
    for (e.history, e.history_wrapped, 0..) |want, want_wrapped, i| {
        try expectCells(v.name, "scrollback line", i, sc.history.items[i].cells, want);
        if (sc.history.items[i].wrapped != want_wrapped) return mismatch(v.name, "scrollback wrapped flag", &sc);
    }
    if (sc.row != e.cursor[0] or sc.col != e.cursor[1]) {
        std.debug.print("{s}: cursor ({d},{d}) vs screen.py ({d},{d})\n", .{ v.name, sc.row, sc.col, e.cursor[0], e.cursor[1] });
        return mismatch(v.name, "cursor", &sc);
    }
    if (sc.saved_row != e.saved_cursor[0] or sc.saved_col != e.saved_cursor[1]) return mismatch(v.name, "DECSC cursor", &sc);
    if (sc.cursor_visible != e.cursor_visible) return mismatch(v.name, "cursor visibility", &sc);
    if (sc.pending_wrap != e.pending_wrap) return mismatch(v.name, "pending wrap", &sc);
    if (sc.scrolled != e.scrolled) return mismatch(v.name, "scroll count", &sc);
    if (sc.sync_depth != e.sync_depth or sc.max_sync_depth != e.max_sync_depth) return mismatch(v.name, "sync depth", &sc);
    if (sc.inAltScreen() != e.alt) return mismatch(v.name, "alternate screen", &sc);
    const partial = try gpa.alloc(u8, e.pending_bytes.len / 2);
    defer gpa.free(partial);
    if (!std.mem.eql(u8, sc.partial.items, try std.fmt.hexToBytes(partial, e.pending_bytes))) return mismatch(v.name, "buffered partial sequence", &sc);
}

test "vterm agrees with screen.py on every golden vector" {
    const gpa = testing.allocator;
    var count: usize = 0;
    var hand: usize = 0;
    var it = std.mem.splitScalar(u8, FIXTURE, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (line.len == 0) continue;
        const parsed = try std.json.parseFromSlice(Vector, gpa, line, .{});
        defer parsed.deinit();
        checkVector(gpa, parsed.value) catch |err| {
            std.debug.print("vterm parity: vector \"{s}\" failed\n", .{parsed.value.name});
            return err;
        };
        count += 1;
        if (!std.mem.startsWith(u8, parsed.value.name, "random_")) hand += 1;
    }
    // A truncated fixture must not pass by checking nothing.
    try testing.expect(hand >= 40);
    try testing.expect(count >= hand + 80);
}

test "the TUI never counts a character narrower than the reference terminal draws it" {
    var cp: u21 = 0;
    while (cp <= 0x10FFFF) : (cp += 1) {
        if (cp >= 0xD800 and cp <= 0xDFFF) continue;
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &buf) catch unreachable;
        const tui = cc.tui_term.displayWidth(buf[0..n]);
        const drawn = vterm.charWidth(cp);
        const kept_wider = (drawn == 0 and tui == 1) or (cp >= 0x1F1E6 and cp <= 0x1F1FF and drawn == 1 and tui == 2);
        if (tui < drawn or (tui != drawn and !kept_wider)) {
            std.debug.print("U+{X:0>4}: term.zig width {d}, reference terminal {d}\n", .{ cp, tui, drawn });
            return error.TestExpectedEqual;
        }
    }
}

test "vterm scrollback keeps the content of the lines that left the screen, bounded" {
    var sc = try vterm.Screen.init(testing.allocator, 2, 10, .{ .max_history = 3 });
    defer sc.deinit();
    try sc.feed("l0\r\nl1\r\nl2\r\nl3\r\nl4\r\nl5");
    // l0..l4 scrolled off; only the newest three are kept, the rest counted.
    try testing.expectEqual(@as(usize, 3), sc.history.items.len);
    try testing.expectEqual(@as(usize, 1), sc.history_dropped);
    try testing.expectEqual(@as(usize, 4), sc.scrolled);
    try sc.expectHistoryTail(&.{ "l1", "l2", "l3" });
    try sc.expectHistoryTail(&.{"l3"});
    try sc.expectLine(0, "l4");
    try sc.expectLine(1, "l5");
    try testing.expectEqual(@as(usize, 1), try sc.historyCount("l2"));
    try testing.expectEqual(@as(usize, 0), try sc.historyCount("l0"));

    const transcript = try sc.transcriptAlloc(testing.allocator, .{});
    defer testing.allocator.free(transcript);
    try testing.expectEqualStrings("l1\nl2\nl3\nl4\nl5", transcript);
}

test "vterm: the alternate screen never reaches the scrollback" {
    var sc = try vterm.Screen.init(testing.allocator, 2, 10, .{});
    defer sc.deinit();
    try sc.feed("main\r\n\x1b[?1049ha1\r\na2\r\na3\r\na4\x1b[?1049l");
    try testing.expectEqual(@as(usize, 0), sc.history.items.len);
    try sc.expectLine(0, "main");
    try testing.expect(!sc.inAltScreen());
}

test "vterm counts closed and stray DEC 2026 frames" {
    var sc = try vterm.Screen.init(testing.allocator, 3, 10, .{});
    defer sc.deinit();
    try sc.feed("\x1b[?2026ha\x1b[?2026l\x1b[?2026h\x1b[?2026hb\x1b[?2026l");
    try testing.expectEqual(@as(usize, 1), sc.sync_frames);
    try testing.expectEqual(@as(usize, 1), sc.sync_depth); // second frame still open
    try sc.feed("\x1b[?2026l\x1b[?2026l");
    try testing.expectEqual(@as(usize, 2), sc.sync_frames);
    try testing.expectEqual(@as(usize, 0), sc.sync_depth);
    try testing.expectEqual(@as(usize, 1), sc.stray_sync_ends);
    try testing.expectEqual(@as(usize, 2), sc.max_sync_depth);
}

test "vterm keeps each cell's full SGR style" {
    var sc = try vterm.Screen.init(testing.allocator, 2, 10, .{});
    defer sc.deinit();
    try sc.feed("\x1b[1;38;5;33mA\x1b[22;48;2;1;2;3mB\x1b[0;3;94mC\x1b[mD");
    const a = sc.cellAt(0, 0).style;
    try testing.expect(a.bold and !a.dim);
    try testing.expect(std.meta.eql(a.fg, vterm.Color{ .indexed = 33 }));
    try testing.expectEqual(vterm.Class.accent, sc.cellAt(0, 0).class);
    const b = sc.cellAt(0, 1).style;
    try testing.expect(!b.bold);
    try testing.expect(std.meta.eql(b.fg, vterm.Color{ .indexed = 33 }));
    try testing.expect(std.meta.eql(b.bg, vterm.Color{ .rgb = .{ 1, 2, 3 } }));
    const c = sc.cellAt(0, 2).style;
    try testing.expect(c.italic and std.meta.eql(c.fg, vterm.Color{ .basic = 12 }) and std.meta.eql(c.bg, vterm.Color.default));
    try testing.expect(sc.cellAt(0, 3).style.isDefault());

    const styled = try sc.transcriptAlloc(testing.allocator, .{ .styles = true });
    defer testing.allocator.free(styled);
    try testing.expectEqualStrings("ABCD  ~ 0-0:b/fg#33 1-1:/fg#33/bg(1,2,3) 2-2:i/fg12", styled);
}

test "vterm: wide characters take two cells and the cursor moves two columns" {
    var sc = try vterm.Screen.init(testing.allocator, 2, 6, .{});
    defer sc.deinit();
    try sc.feed("a中b");
    try sc.expectCell(0, 0, "a");
    try sc.expectCell(0, 1, "中");
    try sc.expectCell(0, 2, ""); // continuation
    try sc.expectCell(0, 3, "b");
    try testing.expectEqual(vterm.Pos{ .row = 0, .col = 4 }, sc.cursor());
    try sc.expectLine(0, "a中b");
}
