//! L2: the assistant streaming markdown path converges under any chunking (#318).
//!
//! RenderRegion renders assistant text as it streams: writeGenAssistantText
//! buffers to the next newline, a pipe line is held as a tentative table
//! header until the delimiter row confirms it (or the next line rolls it
//! back), a confirmed table is held until it ends, and every other line goes
//! through the markdown line renderer with state carried across lines (code
//! fences, highlight language). The invariant pinned here: for any chunking
//! of the same text — one token, one line or one byte at a time, every
//! single cut point, seeded random cuts, a table row cut in half, a table
//! that never gets its delimiter row — what the terminal ends up showing
//! (scrollback and screen, characters and SGR styles, replayed through
//! vterm.zig) equals rendering the whole text in one write. Half of the
//! random runs also stream with the live region drawn and redrawn between
//! chunks (spinner ticks), which routes every line through erase → text →
//! redraw; the region must leave no trace.
//!
//! The streaming path is driven only through RenderRegion's public calls.
//! A failure prints the document, width, seed and a minimized cut list.

const std = @import("std");
const harness = @import("region_harness.zig");

const testing = std.testing;
const gpa = testing.allocator;

const Doc = struct { name: []const u8, text: []const u8 };

const corpus = [_]Doc{
    .{ .name = "prose", .text =
    \\# Streaming report
    \\Intro with **bold**, *italic* and `inline code`, then a long sentence that is wide enough to soft-wrap at forty columns and again at eighty columns of terminal width.
    \\
    \\## 小结 Summary
    \\- 第一项: 中文内容和 English mixed together in one list item that wraps
    \\- second *item* with `code|pipe` inside backticks
    \\* star item
    \\
    \\Plain closing line.
    \\
    },
    .{ .name = "code", .text =
    \\Before the code.
    \\```python
    \\def f(x):
    \\    # a comment | with a pipe
    \\    if x is None:
    \\        return lambda y: y  # trailing
    \\    elif x:
    \\        pass
    \\```
    \\```zig
    \\pub fn main() void {
    \\    const a: u8 = 1; // note
    \\}
    \\```
    \\```sh
    \\echo "a | b" && export X=1
    \\```
    \\After the code.
    \\
    },
    .{ .name = "table", .text =
    \\Here is a table:
    \\| Name | Value | Note |
    \\|------|:-----:|-----:|
    \\| alpha | 1 | first row |
    \\| beta | 22 | 第二行 中文 |
    \\| gamma | 333 | a much longer note that will not fit in a narrow terminal column |
    \\Text right after the table.
    \\| a | b |
    \\|---|---|
    \\| 1 | 2 |
    \\
    \\| last | table |
    \\| --- | --- |
    \\| at | end |
    },
    .{ .name = "table_abort", .text =
    \\A pipe line that is not a table:
    \\| looks | like | a header |
    \\but this line is not a delimiter row.
    \\| first | candidate |
    \\| second | candidate |
    \\|---|---|
    \\| confirmed | row |
    \\
    \\| header | then blank |
    \\
    \\a | b with text around
    \\```
    \\| inside | code |
    \\|---|---|
    \\```
    \\| header at the very end | no delimiter |
    },
    .{ .name = "crlf_and_tail", .text = "Windows line\r\n| x | y |\r\n|---|---|\r\n| 1 | 2 |\r\nafter\r\ntrailing text without a newline" },
};

const Config = struct {
    cols: usize,
    /// Stream with the live region drawn; tick between chunks where
    /// `tickAfter` says so.
    app: ?*harness.App = null,
    seed: u64 = 0,
    /// Finish with endScrollLine (stream_done) instead of flushGenAssistant.
    end_scroll_line: bool = false,
    /// Replay on a strict DEC autowrap terminal. The reference is always an
    /// ideal (clipping) one: a line that fills the last column must not add
    /// a row either way.
    autowrap: bool = false,
};

fn tickAfter(seed: u64, pos: usize) bool {
    // Keyed by the cut position, not the chunk index, so removing a cut
    // while minimizing keeps the remaining ticks where they were.
    var h = std.hash.Wyhash.init(seed);
    h.update(std.mem.asBytes(&pos));
    return h.final() & 1 == 1;
}

/// What the terminal shows after streaming `doc` cut at `cuts` (ascending,
/// inside 1..doc.len-1). Caller frees.
fn render(doc: []const u8, cuts: []const usize, cfg: Config) ![]u8 {
    const t = try harness.Term.create(gpa, .{ .rows = 24, .cols = cfg.cols, .autowrap = cfg.autowrap });
    defer t.destroy();
    const r = &t.region;
    if (cfg.app) |app| {
        r.enterGenerating(app, null);
        r.tickSpinner(app);
    }
    r.beginGenAssistant();
    var last: usize = 0;
    for (0..cuts.len + 1) |i| {
        const end = if (i < cuts.len) cuts[i] else doc.len;
        r.writeGenAssistantText(doc[last..end]);
        last = end;
        if (cfg.app) |app| {
            if (tickAfter(cfg.seed, end)) r.tickSpinner(app);
        }
    }
    if (cfg.end_scroll_line) r.endScrollLine() else r.flushGenAssistant();
    if (cfg.app) |app| {
        r.leaveGenerating(app);
        try t.sync();
        // The region left nothing behind and never reached the scrollback.
        const left = try t.screen.countRows(.screen, harness.isRegionRow) + try t.screen.countRows(.history, harness.isRegionRow);
        if (left != 0 or t.screen.sync_depth != 0) {
            t.printDump();
            return error.RegionLeftBehind;
        }
    }
    return t.transcriptAlloc(.{ .styles = true });
}

fn sameAsReference(doc: []const u8, cuts: []const usize, cfg: Config, reference: []const u8) !bool {
    const got = try render(doc, cuts, cfg);
    defer gpa.free(got);
    return std.mem.eql(u8, got, reference);
}

const Failure = error{ChunkingChangedOutput};

/// Compare one chunking with the reference; on a mismatch, minimize the cut
/// list (drop cuts while the output still differs), print it and fail.
fn check(doc: Doc, cuts: []const usize, cfg: Config, reference: []const u8, what: []const u8) !void {
    if (try sameAsReference(doc.text, cuts, cfg, reference)) return;
    var kept: std.ArrayList(usize) = .empty;
    defer kept.deinit(gpa);
    try kept.appendSlice(gpa, cuts);
    var i: usize = 0;
    while (i < kept.items.len) {
        const removed = kept.orderedRemove(i);
        if (!try sameAsReference(doc.text, kept.items, cfg, reference)) continue;
        try kept.insert(gpa, i, removed);
        i += 1;
    }
    std.debug.print(
        "md stream convergence: doc \"{s}\", {d} cols ({s} terminal), {s}, region {s}, seed 0x{x}, end {s}\n  minimized cuts {any}\n  chunks:",
        .{
            doc.name,                                                          cfg.cols,
            if (cfg.autowrap) "autowrap" else "clipping",                      what,
            if (cfg.app != null) "drawn" else "off",                           cfg.seed,
            if (cfg.end_scroll_line) "endScrollLine" else "flushGenAssistant", kept.items,
        },
    );
    var last: usize = 0;
    for (0..kept.items.len + 1) |k| {
        const end = if (k < kept.items.len) kept.items[k] else doc.text.len;
        std.debug.print(" \"{f}\"", .{std.zig.fmtString(doc.text[last..end])});
        last = end;
    }
    const got = try render(doc.text, kept.items, cfg);
    defer gpa.free(got);
    printFirstDifference(reference, got);
    return error.ChunkingChangedOutput;
}

fn printFirstDifference(want: []const u8, got: []const u8) void {
    var a = std.mem.splitScalar(u8, want, '\n');
    var b = std.mem.splitScalar(u8, got, '\n');
    var line: usize = 0;
    while (true) : (line += 1) {
        const x = a.next();
        const y = b.next();
        if (x == null and y == null) return;
        if (x != null and y != null and std.mem.eql(u8, x.?, y.?)) continue;
        std.debug.print("\n  first difference at transcript line {d}:\n    whole:   \"{s}\"\n    chunked: \"{s}\"\n", .{ line, x orelse "<end>", y orelse "<end>" });
        return;
    }
}

const Cuts = std.ArrayList(usize);

fn lineCuts(text: []const u8, out: *Cuts) !void {
    for (text[0 .. text.len - 1], 0..) |c, i| if (c == '\n') try out.append(gpa, i + 1);
}

/// Token boundaries the way a model streams: a run of word bytes (UTF-8
/// continuation bytes stay with their character), a run of spaces, or one
/// punctuation byte.
fn tokenCuts(text: []const u8, out: *Cuts) !void {
    const Kind = enum { word, space, punct };
    const kindOf = struct {
        fn f(c: u8) Kind {
            if (std.ascii.isAlphanumeric(c) or c >= 0x80) return .word;
            if (c == ' ' or c == '\t') return .space;
            return .punct;
        }
    }.f;
    for (1..text.len) |i| {
        if (text[i] & 0xC0 == 0x80) continue; // inside a UTF-8 sequence
        const a = kindOf(text[i - 1]);
        const b = kindOf(text[i]);
        if (a != b or a == .punct) try out.append(gpa, i);
    }
}

/// Every table row cut in half and right after its first pipe.
fn tableRowCuts(text: []const u8, out: *Cuts) !void {
    var start: usize = 0;
    while (start < text.len) {
        const end = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse text.len;
        const row = text[start..end];
        if (std.mem.indexOfScalar(u8, row, '|')) |pipe| {
            if (start + pipe + 1 < text.len) try out.append(gpa, start + pipe + 1);
            const mid = start + row.len / 2;
            if (mid > start + pipe + 1 and mid < text.len) try out.append(gpa, mid);
        }
        start = end + 1;
    }
}

fn randomCuts(rng: std.Random, text_len: usize, out: *Cuts) !void {
    const n = rng.intRangeAtMost(usize, 1, 16);
    for (0..n) |_| try out.append(gpa, rng.intRangeAtMost(usize, 1, text_len - 1));
    std.mem.sortUnstable(usize, out.items, {}, std.sort.asc(usize));
    // Duplicate cuts would make empty chunks; writeGenAssistantText ignores
    // them, but keep the list a set so a minimized report reads cleanly.
    var w: usize = 0;
    for (out.items) |c| {
        if (w > 0 and out.items[w - 1] == c) continue;
        out.items[w] = c;
        w += 1;
    }
    out.shrinkRetainingCapacity(w);
}

fn renderWhole(doc: Doc, cols: usize) ![]u8 {
    return render(doc.text, &.{}, .{ .cols = cols });
}

test "md stream: token, line and byte chunkings render like the whole text" {
    for ([_]usize{ 80, 40 }) |cols| {
        for (corpus) |doc| {
            const ref = try renderWhole(doc, cols);
            defer gpa.free(ref);
            var cuts: Cuts = .empty;
            defer cuts.deinit(gpa);

            try lineCuts(doc.text, &cuts);
            try check(doc, cuts.items, .{ .cols = cols }, ref, "line chunks");
            cuts.clearRetainingCapacity();
            try tokenCuts(doc.text, &cuts);
            try check(doc, cuts.items, .{ .cols = cols }, ref, "token chunks");
            try check(doc, cuts.items, .{ .cols = cols, .end_scroll_line = true }, ref, "token chunks");
            cuts.clearRetainingCapacity();
            for (1..doc.text.len) |i| try cuts.append(gpa, i);
            try check(doc, cuts.items, .{ .cols = cols }, ref, "byte chunks");
            cuts.clearRetainingCapacity();
            try tableRowCuts(doc.text, &cuts);
            try check(doc, cuts.items, .{ .cols = cols }, ref, "table rows cut mid-row");
        }
    }
}

test "md stream: every single cut point renders like the whole text" {
    for ([_]usize{ 80, 40 }) |cols| {
        for (corpus) |doc| {
            const ref = try renderWhole(doc, cols);
            defer gpa.free(ref);
            for (1..doc.text.len) |cut| try check(doc, &.{cut}, .{ .cols = cols }, ref, "single cut");
        }
    }
}

test "md stream: seeded random chunkings, half with the live region redrawn between chunks" {
    const fx = try harness.AppFixture.create(gpa);
    defer fx.destroy();
    const seed: u64 = 0x318_0318;
    var prng = std.Random.DefaultPrng.init(seed);
    const rng = prng.random();
    for ([_]usize{ 80, 40 }) |cols| {
        for (corpus) |doc| {
            const ref = try renderWhole(doc, cols);
            defer gpa.free(ref);
            var cuts: Cuts = .empty;
            defer cuts.deinit(gpa);
            for (0..60) |run| {
                cuts.clearRetainingCapacity();
                try randomCuts(rng, doc.text.len, &cuts);
                const run_seed = rng.int(u64);
                const cfg: Config = .{
                    .cols = cols,
                    .app = if (run % 2 == 0) fx.app else null,
                    .seed = run_seed,
                    .end_scroll_line = run % 3 == 0,
                    .autowrap = run % 4 >= 2,
                };
                check(doc, cuts.items, cfg, ref, "random cuts") catch |err| {
                    std.debug.print("\n  (random run {d} of corpus seed 0x{x})\n", .{ run, seed });
                    return err;
                };
            }
            // Table rows cut mid-row with the region redrawn after every chunk.
            cuts.clearRetainingCapacity();
            try tableRowCuts(doc.text, &cuts);
            try check(doc, cuts.items, .{ .cols = cols, .app = fx.app, .seed = 1 }, ref, "table rows cut mid-row");
        }
    }
}

// The reference is one write of the whole text; these pin that it is itself
// right, so convergence is towards the intended rendering.
test "md stream: the whole-text render is the intended one" {
    const t = try harness.Term.create(gpa, .{ .rows = 120, .cols = 80 });
    defer t.destroy();
    const r = &t.region;
    for (corpus) |doc| {
        r.beginGenAssistant();
        r.writeGenAssistantText(doc.text);
        r.flushGenAssistant();
    }
    try t.sync();
    const sc = &t.screen;

    // Segment start: the first line of each document carries the ⏺ marker.
    try testing.expect((try sc.findRow("⏺ Streaming report")) != null);
    // A confirmed table is drawn with a frame; its delimiter row is gone.
    const name_row = (try sc.findRow("Name")).?;
    const header = try sc.lineAlloc(gpa, name_row);
    defer gpa.free(header);
    try testing.expect(std.mem.indexOf(u8, header, "│") != null);
    try testing.expectEqual(@as(usize, 0), try sc.screenCount("|------|"));
    // A pipe line without a delimiter row is plain text, shown once.
    try testing.expectEqual(@as(usize, 1), try sc.screenCount("| looks | like | a header |"));
    try testing.expectEqual(@as(usize, 1), try sc.screenCount("| header at the very end | no delimiter |"));
    // The first of two candidates rolls back; the second heads the table.
    try testing.expectEqual(@as(usize, 1), try sc.screenCount("| first | candidate |"));
    try testing.expect((try sc.findRow("│ second")) != null);
    // Pipes inside a code block are code, not a table.
    try testing.expectEqual(@as(usize, 1), try sc.screenCount("| inside | code |"));

    // Code blocks are highlighted for the fence's language: a Python-only
    // keyword is styled like the other keywords, unlike a plain identifier.
    const lambda_row = (try sc.findRow("return lambda")).?;
    const line = try sc.lineAlloc(gpa, lambda_row); // ASCII: byte offset = column
    defer gpa.free(line);
    const kw = std.mem.indexOf(u8, line, "return").?;
    const py_kw = std.mem.indexOf(u8, line, "lambda").?;
    const ident = std.mem.indexOf(u8, line, " y:").? + 1;
    try testing.expect(sc.cellAt(lambda_row, py_kw).style.eql(sc.cellAt(lambda_row, kw).style));
    try testing.expect(!sc.cellAt(lambda_row, ident).style.eql(sc.cellAt(lambda_row, kw).style));
}
