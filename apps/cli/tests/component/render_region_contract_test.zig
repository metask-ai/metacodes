//! L2: RenderRegion contracts asserted on what the terminal shows (#319).
//!
//! The region's bytes are replayed through the component-test virtual
//! terminal (vterm.zig) after every public call. Assertions read only the
//! screen, the scrollback and the frame counters — never the region's
//! fields — so they hold across refactors of render_region's internals.
//!
//! Contracts:
//!   - emit/erase pairing: while a reply streams, the live region (spinner,
//!     box, footer) is on screen exactly once after every call, every frame
//!     that erases and redraws it is one closed DEC 2026 frame, and none of
//!     its rows ever reaches the scrollback; the text reaches it exactly
//!     once, in order.
//!   - half-line continuation: text committed without a trailing newline
//!     under a drawn region is resumed from the snapshot taken when the
//!     region was drawn, so the next line starts right below it — no blank
//!     row, no overwrite — wherever the region sits on the screen.
//!   - phase hand-off: the input box erased by enterGenerating and the region
//!     erased by leaveGenerating leave nothing behind.
//!
//! Every contract is checked twice: with the merge window off (each request
//! paints at once) and on (#328: requests wait for the window, and the
//! harness's `sync` paints the merged frame, as the timer thread would).

const std = @import("std");
const harness = @import("region_harness.zig");

const testing = std.testing;
const gpa = testing.allocator;

const POINTER = "❯";

/// Run `contract` with the merge window off, then on.
fn inBothModes(comptime contract: fn (merge: bool) anyerror!void) !void {
    for ([_]bool{ false, true }) |merge| {
        contract(merge) catch |err| {
            std.debug.print("merge window {s}\n", .{if (merge) "on" else "off"});
            return err;
        };
    }
}

fn expectRegionOnScreenOnce(t: *harness.Term) !void {
    try t.sync();
    const on_screen = try t.screen.countRows(.screen, harness.isPromptRow);
    const in_history = try t.screen.countRows(.history, harness.isRegionRow);
    if (on_screen == 1 and in_history == 0 and t.screen.sync_depth == 0 and t.screen.stray_sync_ends == 0) return;
    std.debug.print("region on screen {d}x, region rows in scrollback {d}, sync depth {d}, stray ends {d}\n", .{
        on_screen, in_history, t.screen.sync_depth, t.screen.stray_sync_ends,
    });
    t.printDump();
    return error.TestExpectedEqual;
}

fn expectRegionGone(t: *harness.Term) !void {
    try t.sync();
    const left = try t.screen.countRows(.screen, harness.isRegionRow) + try t.screen.countRows(.history, harness.isRegionRow);
    if (left == 0 and t.screen.sync_depth == 0) return;
    std.debug.print("{d} region rows left behind\n", .{left});
    t.printDump();
    return error.TestExpectedEqual;
}

fn expectTranscript(t: *harness.Term, expected: []const u8) !void {
    const got = try t.transcriptAlloc(.{});
    defer gpa.free(got);
    if (std.mem.eql(u8, got, expected)) return;
    std.debug.print("transcript:\n{s}\n-- expected:\n{s}\n", .{ got, expected });
    t.printDump();
    return error.TestExpectedEqual;
}

test "emit/erase pairing: streamed lines reach the scrollback once, the live region never does" {
    try inBothModes(emitErasePairing);
}

fn emitErasePairing(merge: bool) !void {
    const fx = try harness.AppFixture.create(gpa);
    defer fx.destroy();
    const t = try harness.Term.create(gpa, .{ .rows = 12, .cols = 60, .merge_window = merge });
    defer t.destroy();
    const r = &t.region;

    r.enterGenerating(fx.app, null);
    r.tickSpinner(fx.app);
    try expectRegionOnScreenOnce(t);
    const frames_before = t.screen.sync_frames;

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(gpa);
    // 30 lines on 12 rows: the region is drawn at the top, then pinned to
    // the bottom, where its own line feeds scroll the screen.
    for (0..30) |i| {
        var buf: [32]u8 = undefined;
        const line = try std.fmt.bufPrint(&buf, "line {d}\n", .{i});
        const written = t.written().len;
        r.writeGenText(line);
        if (merge) {
            // Inside the window: nothing reaches the terminal yet, and the
            // tick rides on the same frame as the line.
            try testing.expectEqual(written, t.written().len);
            if (i % 3 == 0) r.tickSpinner(fx.app);
            try testing.expectEqual(written, t.written().len);
            try expectRegionOnScreenOnce(t);
        } else {
            try expectRegionOnScreenOnce(t);
            if (i % 3 == 0) {
                r.tickSpinner(fx.app);
                try expectRegionOnScreenOnce(t);
            }
        }
        if (i > 0) try expected.append(gpa, '\n');
        try expected.appendSlice(gpa, line[0 .. line.len - 1]);
    }
    // Every erase+redraw above was one closed frame: one per request, or,
    // with the merge window, one per window.
    if (merge) {
        try testing.expectEqual(frames_before + 30, t.screen.sync_frames);
    } else {
        try testing.expect(t.screen.sync_frames >= frames_before + 30 + 10);
    }

    r.leaveGenerating(fx.app);
    try expectRegionGone(t);
    try expectTranscript(t, expected.items);
    // The next write continues on the row after the last line.
    const last = (try t.screen.findRow("line 29")).?;
    try testing.expectEqual(harness.vterm.Pos{ .row = last + 1, .col = 0 }, t.screen.cursor());
}

test "half-line continuation: the next line starts right below, wherever the region sits" {
    try inBothModes(halfLineContinuation);
}

fn halfLineContinuation(merge: bool) !void {
    const fx = try harness.AppFixture.create(gpa);
    defer fx.destroy();
    // Above the region at the top, in the middle, and with the region
    // pinned to the bottom (its draw scrolls the half line up).
    for ([_]usize{ 0, 4, 25 }) |lines_before| {
        const t = try harness.Term.create(gpa, .{ .rows = 12, .cols = 60, .merge_window = merge });
        defer t.destroy();
        const r = &t.region;
        r.enterGenerating(fx.app, null);
        r.tickSpinner(fx.app);

        var expected: std.ArrayList(u8) = .empty;
        defer expected.deinit(gpa);
        for (0..lines_before) |i| {
            var buf: [32]u8 = undefined;
            r.writeGenText(try std.fmt.bufPrint(&buf, "before {d}\n", .{i}));
            try expected.print(gpa, "before {d}\n", .{i});
        }
        // A half line committed under the drawn region: the region is
        // redrawn below it, then erased back to its end and the line sealed.
        r.writeGenText("abc");
        r.endScrollLine();
        try expectRegionOnScreenOnce(t);
        r.tickSpinner(fx.app);
        r.tickSpinner(fx.app);
        try expectRegionOnScreenOnce(t);
        // Wide characters: the saved column counts display cells.
        r.writeGenText("中文ab");
        r.endScrollLine();
        try expectRegionOnScreenOnce(t);
        r.writeGenText("def\n");
        try expectRegionOnScreenOnce(t);
        // A half line left at the end of the reply is sealed by leaveGenerating.
        r.writeGenText("tail");
        r.tickSpinner(fx.app);
        r.leaveGenerating(fx.app);
        try expectRegionGone(t);
        try expected.appendSlice(gpa, "abc\n中文ab\ndef\ntail");
        expectTranscript(t, expected.items) catch |err| {
            std.debug.print("lines before the half line: {d}\n", .{lines_before});
            return err;
        };
        const tail_row = (try t.screen.findRow("tail")).?;
        try testing.expectEqual(harness.vterm.Pos{ .row = tail_row + 1, .col = 0 }, t.screen.cursor());
    }
}

test "phase hand-off: the input box and the live region leave nothing behind" {
    try inBothModes(phaseHandOff);
}

fn phaseHandOff(merge: bool) !void {
    const fx = try harness.AppFixture.create(gpa);
    defer fx.destroy();
    const t = try harness.Term.create(gpa, .{ .rows = 10, .cols = 50, .merge_window = merge });
    defer t.destroy();
    const r = &t.region;

    for (0..3) |turn| {
        // A read is an input phase (#330): readLineRaw opens and closes it.
        r.beginInput(.builtin);
        r.setInput("draft", 5);
        r.render(fx.app);
        try expectRegionOnScreenOnce(t);
        try t.screen.expectLine((try t.screen.findRow(POINTER)).?, "❯ draft");
        r.endInput();

        r.enterGenerating(fx.app, null);
        try expectRegionGone(t);
        r.tickSpinner(fx.app);
        try expectRegionOnScreenOnce(t);
        var buf: [32]u8 = undefined;
        r.writeGenText(try std.fmt.bufPrint(&buf, "reply {d}\n", .{turn}));
        r.tickSpinner(fx.app);
        r.leaveGenerating(fx.app);
        try expectRegionGone(t);
    }
    try expectTranscript(t, "reply 0\nreply 1\nreply 2");
}

test "a strict-autowrap terminal shows the same reply as an ideal one" {
    try inBothModes(strictAutowrap);
}

fn strictAutowrap(merge: bool) !void {
    const fx = try harness.AppFixture.create(gpa);
    defer fx.destroy();
    // Lines exactly as wide as the terminal arm the DEC pending wrap on a
    // strict terminal; the region's \r\n must cancel it, not add a row.
    var transcripts: [2][]u8 = .{ &.{}, &.{} };
    defer for (transcripts) |tr| gpa.free(tr);
    for ([_]bool{ false, true }, 0..) |autowrap, k| {
        const t = try harness.Term.create(gpa, .{ .rows = 8, .cols = 20, .autowrap = autowrap, .merge_window = merge });
        defer t.destroy();
        const r = &t.region;
        r.enterGenerating(fx.app, null);
        r.tickSpinner(fx.app);
        for (0..12) |i| {
            var buf: [32]u8 = undefined;
            r.writeGenText(try std.fmt.bufPrint(&buf, "{d:0>2}" ++ "x" ** 18 ++ "\n", .{i}));
            if (i % 4 == 0) r.tickSpinner(fx.app);
            try expectRegionOnScreenOnce(t);
        }
        r.beginGenAssistant();
        r.writeGenAssistantText("a reply line that is long enough to wrap twice at twenty\n");
        r.flushGenAssistant();
        try expectRegionOnScreenOnce(t);
        r.leaveGenerating(fx.app);
        try expectRegionGone(t);
        transcripts[k] = try t.transcriptAlloc(.{ .styles = true });
    }
    try testing.expectEqualStrings(transcripts[0], transcripts[1]);
}

// Found by the test above: the footer (`⏵⏵ bypass permissions on (shift+tab
// to cycle) · esc to interrupt`, 65 columns) was never cut to the terminal.
// On a narrower autowrapping terminal it took extra rows the region does not
// count; at the bottom of the screen every frame then pushed the spinner,
// border and prompt rows into the scrollback.
test "the footer is cut to the terminal width, in both phases, instead of wrapping" {
    try inBothModes(footerFits);
}

fn footerFits(merge: bool) !void {
    const fx = try harness.AppFixture.create(gpa);
    defer fx.destroy();
    const t = try harness.Term.create(gpa, .{ .rows = 10, .cols = 30, .autowrap = true, .merge_window = merge });
    defer t.destroy();
    const r = &t.region;

    r.beginInput(.builtin);
    r.setInput("", 0);
    r.render(fx.app);
    try expectRegionOnScreenOnce(t);
    try expectFooterFits(t, 30);
    r.endInput();

    r.enterGenerating(fx.app, null);
    for (0..15) |i| {
        var buf: [32]u8 = undefined;
        r.writeGenText(try std.fmt.bufPrint(&buf, "line {d}\n", .{i}));
        r.tickSpinner(fx.app);
        try expectRegionOnScreenOnce(t);
        try expectFooterFits(t, 30);
    }
    r.leaveGenerating(fx.app);
    try expectRegionGone(t);
}

/// The footer row (the mode line) is one row that ends inside the terminal.
fn expectFooterFits(t: *harness.Term, cols: usize) !void {
    const row = (try t.screen.findRow("bypass")) orelse {
        t.printDump();
        return error.TestExpectedEqual;
    };
    const text = try t.screen.lineAlloc(gpa, row);
    defer gpa.free(text);
    const width = try std.unicode.utf8CountCodepoints(text);
    try testing.expect(width <= cols - 1);
    try testing.expect(std.mem.endsWith(u8, text, "…"));
    // Nothing of it spilled onto the next row.
    if (row + 1 < t.screen.rows) {
        const next = try t.screen.lineAlloc(gpa, row + 1);
        defer gpa.free(next);
        try testing.expectEqualStrings("", next);
    }
}
