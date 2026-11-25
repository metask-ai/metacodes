//! L2: the generating region's merge window (#328), asserted on what the
//! virtual terminal shows (vterm.zig, #319): screen, scrollback and frame
//! counters, never the region's fields.
//!
//! Contracts:
//!   - a burst inside one window reaches the scrollback once, in order, with
//!     no blank row and one synchronized frame; the live region never does;
//!   - a resize while that frame is pending lays it out at the new width and
//!     leaves one region, nothing stranded above it;
//!   - the end of a provider turn (`endScrollLine`) seals a half line in one
//!     closed DEC 2026 frame, with no blank row after it (group A's finding:
//!     it used to be three separate writes).

const std = @import("std");
const cc = @import("cc");
const harness = @import("region_harness.zig");

const testing = std.testing;
const gpa = testing.allocator;

const Clock = struct {
    var now: i64 = 0;
    fn read() i64 {
        return now;
    }
};

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

fn expectTranscript(t: *harness.Term, expected: []const u8) !void {
    const got = try t.transcriptAlloc(.{});
    defer gpa.free(got);
    if (std.mem.eql(u8, got, expected)) return;
    std.debug.print("transcript:\n{s}\n-- expected:\n{s}\n", .{ got, expected });
    t.printDump();
    return error.TestExpectedEqual;
}

/// A region with the merge window on, driven by the fake clock (no timer
/// thread: `pumpFrame` is its step).
fn mergingTerm(opts: harness.Term.Options) !*harness.Term {
    const t = try harness.Term.create(gpa, opts);
    t.region.merge = .{ .now_ms = Clock.read, .timer = false };
    Clock.now = 50_000;
    return t;
}

test "merge window: a burst reaches the scrollback once, in order, in one frame" {
    const fx = try harness.AppFixture.create(gpa);
    defer fx.destroy();
    const t = try mergingTerm(.{ .rows = 12, .cols = 60 });
    defer t.destroy();
    const r = &t.region;
    r.enterGenerating(fx.app, null);
    r.tickSpinner(fx.app); // nothing painted yet: this frame goes out at once
    try expectRegionOnScreenOnce(t);
    const frames_before = t.screen.sync_frames;

    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(gpa);
    for (0..20) |i| { // all inside the window
        var buf: [32]u8 = undefined;
        r.writeGenText(try std.fmt.bufPrint(&buf, "burst {d}\n", .{i}));
        try expected.print(gpa, "burst {d}\n", .{i});
    }
    try t.sync();
    try testing.expectEqual(frames_before, t.screen.sync_frames); // still waiting for the window
    Clock.now += 16;
    try testing.expect(r.pumpFrame());
    try expectRegionOnScreenOnce(t);
    try testing.expectEqual(frames_before + 1, t.screen.sync_frames); // twenty lines, one frame

    r.leaveGenerating(fx.app);
    try expectTranscript(t, std.mem.trimEnd(u8, expected.items, "\n"));
}

test "merge window: a resize while the frame is pending lays it out at the new width" {
    const fx = try harness.AppFixture.create(gpa);
    defer fx.destroy();
    for ([_]bool{ true, false }) |reflow| {
        const t = try mergingTerm(.{ .rows = 14, .cols = 80 });
        defer t.destroy();
        const r = &t.region;
        r.enterGenerating(fx.app, null);
        r.tickSpinner(fx.app);
        var expected: std.ArrayList(u8) = .empty;
        defer expected.deinit(gpa);
        for (0..6) |i| {
            var buf: [32]u8 = undefined;
            r.writeGenText(try std.fmt.bufPrint(&buf, "pending {d}\n", .{i}));
            try expected.print(gpa, "pending {d}\n", .{i});
        }
        // The terminal narrows before the window ends: the region drawn at
        // 80 columns is re-wrapped (or clipped) under the pending frame.
        try t.resize(14, 50, reflow);
        Clock.now += 16;
        try testing.expect(r.pumpFrame());
        expectRegionOnScreenOnce(t) catch |err| {
            std.debug.print("reflow={}\n", .{reflow});
            return err;
        };
        r.leaveGenerating(fx.app);
        try expectTranscript(t, std.mem.trimEnd(u8, expected.items, "\n"));
    }
}

test "endScrollLine seals a half line in one closed frame, with no blank row after it" {
    const fx = try harness.AppFixture.create(gpa);
    defer fx.destroy();
    const t = try harness.Term.create(gpa, .{ .rows = 12, .cols = 60 });
    defer t.destroy();
    const r = &t.region;
    r.enterGenerating(fx.app, null);
    r.tickSpinner(fx.app);
    try expectRegionOnScreenOnce(t);
    r.writeGenText("first\n");
    r.writeGenText("half"); // the provider turn ends without a newline
    try t.sync();
    const frames_before = t.screen.sync_frames;
    const bytes_before = t.written().len;
    r.endScrollLine();
    try expectRegionOnScreenOnce(t);
    const end_bytes = t.written()[bytes_before..];
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, end_bytes, "\x1b[?2026h"));
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, end_bytes, "\x1b[?2026l"));
    try testing.expectEqual(frames_before + 1, t.screen.sync_frames);
    r.writeGenText("next\n");
    r.leaveGenerating(fx.app);
    try expectTranscript(t, "first\nhalf\nnext");
}

// A panic ends the process with what the merge window still holds unwritten:
// up to one window of the reply, often the lines that led to the panic. The
// panic hook (main.zig) writes them first, but only when it can take the
// region's lock without waiting.
test "panic: the text still waiting in the merge window is written before the panic message" {
    const fx = try harness.AppFixture.create(gpa);
    defer fx.destroy();
    const t = try mergingTerm(.{ .rows = 12, .cols = 60 });
    defer t.destroy();
    const r = &t.region;
    r.enableMergeWindow(); // the session region registers for the hook (keeps the fake clock)
    r.enterGenerating(fx.app, null);
    r.tickSpinner(fx.app);
    try expectRegionOnScreenOnce(t);
    r.writeGenText("before the crash\n");
    r.writeGenText("last words\n"); // inside the window: not on screen yet
    try t.sync();
    try testing.expect((try t.screen.findRow("last words")) == null);

    try testing.expect(cc.tui_render_region.flushPendingOnPanic());
    // The hook keeps the lock, so nothing draws over the panic message.
    defer r.mutex.unlock();
    // The text is out and the region is gone; the cursor waits on the next
    // row, where the panic message is printed.
    try expectTranscript(t, "before the crash\nlast words");
    try testing.expectEqual(@as(usize, 0), try t.screen.countRows(.screen, harness.isRegionRow));
    try testing.expectEqual(@as(usize, 0), t.screen.sync_depth);
    const last = (try t.screen.findRow("last words")).?;
    try testing.expectEqual(harness.vterm.Pos{ .row = last + 1, .col = 0 }, t.screen.cursor());
}

// The terminal can change size inside that last window. The hook measures it
// before erasing, as every frame does: rows drawn at the old width re-wrap,
// and an erase that climbed the old row count would leave the top of the
// region on the screen above the panic message.
test "panic: after a resize in the last window, the region is erased at the new width" {
    const fx = try harness.AppFixture.create(gpa);
    defer fx.destroy();
    for ([_]bool{ true, false }) |reflow| {
        const t = try mergingTerm(.{ .rows = 14, .cols = 80 });
        defer t.destroy();
        const r = &t.region;
        r.enableMergeWindow();
        r.enterGenerating(fx.app, null);
        r.tickSpinner(fx.app);
        r.writeGenText("before the resize\n");
        Clock.now += 16;
        try testing.expect(r.pumpFrame());
        try expectRegionOnScreenOnce(t);
        r.writeGenText("last words\n"); // inside the window: not on screen yet
        try t.resize(14, 50, reflow);
        try testing.expect((try t.screen.findRow("last words")) == null);

        try testing.expect(cc.tui_render_region.flushPendingOnPanic());
        defer r.mutex.unlock();
        expectTranscript(t, "before the resize\nlast words") catch |err| {
            std.debug.print("reflow={}\n", .{reflow});
            return err;
        };
        try testing.expectEqual(@as(usize, 0), try t.screen.countRows(.screen, harness.isRegionRow));
        const last = (try t.screen.findRow("last words")).?;
        try testing.expectEqual(harness.vterm.Pos{ .row = last + 1, .col = 0 }, t.screen.cursor());
    }
}

test "panic: a region whose lock is held is left alone, and a freed one is forgotten" {
    const fx = try harness.AppFixture.create(gpa);
    defer fx.destroy();
    {
        const t = try mergingTerm(.{ .rows = 12, .cols = 60 });
        defer t.destroy();
        const r = &t.region;
        r.enableMergeWindow();
        r.enterGenerating(fx.app, null);
        r.tickSpinner(fx.app);
        r.writeGenText("pending\n");
        try t.sync();
        const bytes_before = t.written().len;
        // Another thread is drawing (or the panicking thread was): the frame
        // state cannot be trusted, so the hook gives up rather than wait.
        r.mutex.lock();
        const took = cc.tui_render_region.flushPendingOnPanic();
        r.mutex.unlock();
        try testing.expect(!took);
        try testing.expectEqual(bytes_before, t.written().len);
        r.leaveGenerating(fx.app);
    }
    // The region is gone: the hook must not reach for it.
    try testing.expect(!cc.tui_render_region.flushPendingOnPanic());
}

/// Hands every allocation to `backing`; counts the ones made while armed.
const AllocProbe = struct {
    backing: std.mem.Allocator,
    armed: bool = false,
    calls: usize = 0,

    fn allocator(self: *AllocProbe) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn note(self: *AllocProbe) void {
        if (self.armed) self.calls += 1;
    }
    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *AllocProbe = @ptrCast(@alignCast(ctx));
        self.note();
        return self.backing.rawAlloc(len, alignment, ret_addr);
    }
    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *AllocProbe = @ptrCast(@alignCast(ctx));
        self.note();
        return self.backing.rawResize(memory, alignment, new_len, ret_addr);
    }
    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *AllocProbe = @ptrCast(@alignCast(ctx));
        self.note();
        return self.backing.rawRemap(memory, alignment, new_len, ret_addr);
    }
    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *AllocProbe = @ptrCast(@alignCast(ctx));
        self.note();
        self.backing.rawFree(memory, alignment, ret_addr);
    }
};

// The panic can come from the allocator itself: Zig's DebugAllocator panics on
// an invalid or double free while it holds its own lock. A hook that grew a
// buffer then would wait on that lock forever, turning the crash into a hang.
test "panic: the hook writes the pending text without allocating" {
    const fx = try harness.AppFixture.create(gpa);
    defer fx.destroy();
    var probe: AllocProbe = .{ .backing = gpa };
    const t = try mergingTerm(.{ .rows = 12, .cols = 60, .region_gpa = probe.allocator() });
    defer t.destroy();
    const r = &t.region;
    r.enableMergeWindow();
    r.enterGenerating(fx.app, null);
    r.tickSpinner(fx.app);
    try expectRegionOnScreenOnce(t);
    // Far more text than the last frame: painted through the frame buffer, it
    // would have to grow it.
    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(gpa);
    for (0..120) |i| {
        var buf: [64]u8 = undefined;
        const line = try std.fmt.bufPrint(&buf, "line {d:0>3} still waiting for the window\n", .{i});
        r.writeGenText(line);
        try expected.appendSlice(gpa, line);
    }
    try t.sync();
    try testing.expect((try t.screen.findRow("line 119")) == null);

    probe.armed = true;
    const took = cc.tui_render_region.flushPendingOnPanic();
    probe.armed = false;
    try testing.expect(took);
    defer r.mutex.unlock();
    try testing.expectEqual(@as(usize, 0), probe.calls);
    try expectTranscript(t, std.mem.trimEnd(u8, expected.items, "\n"));
    try testing.expectEqual(@as(usize, 0), try t.screen.countRows(.screen, harness.isRegionRow));
}
