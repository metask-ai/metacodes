//! Redraw scheduling for the generating region (#328): a merge window in the
//! style of a render loop.
//!
//! Events still update UiState synchronously (dispatch is untouched); only the
//! paint is scheduled. A normal request paints at once when the last frame is
//! at least one window old, otherwise it marks a frame pending for the end of
//! that window, and every request until then rides on the same frame: it paints
//! whatever the state is by then, so intermediate states never reach the
//! terminal. Immediate transitions (submit, tool completion, interrupt, phase
//! and overlay boundaries) paint at once and satisfy any pending frame, so the
//! normal channel never adds a frame after them.
//!
//! Pure logic with the time injected: no IO, no clock, no lock. The renderer
//! holds it under its mutex and a timer thread asks it when to flush.

const std = @import("std");

/// One frame at 60 Hz. A burst of events within it costs one paint.
pub const WINDOW_MS: i64 = 16;

pub const Scheduler = struct {
    window_ms: i64 = WINDOW_MS,
    /// When the oldest request not yet painted arrived; null when nothing waits.
    pending_since: ?i64 = null,
    /// When the last frame went out (either channel); null before the first.
    last_paint: ?i64 = null,

    pub const Verdict = enum {
        /// Paint now: nothing went out in the last window.
        paint_now,
        /// A frame is pending for `deadline()`; it will show this request's state.
        deferred,
    };

    /// A normal redraw request at `now`.
    pub fn request(self: *Scheduler, now: i64) Verdict {
        if (self.pending_since != null) return .deferred;
        if (self.last_paint) |t| {
            if (now - t < self.window_ms) {
                self.pending_since = now;
                return .deferred;
            }
        }
        return .paint_now;
    }

    /// When the pending frame is due: one window after the last paint, so the
    /// normal channel never paints twice within a window. Null when nothing waits.
    pub fn deadline(self: *const Scheduler) ?i64 {
        const since = self.pending_since orelse return null;
        const after_last = if (self.last_paint) |t| t + self.window_ms else since;
        return @max(since, after_last);
    }

    pub fn due(self: *const Scheduler, now: i64) bool {
        const d = self.deadline() orelse return false;
        return now >= d;
    }

    /// A frame went out at `now` (any channel). It shows the latest state, so
    /// whatever was pending is satisfied.
    pub fn painted(self: *Scheduler, now: i64) void {
        self.pending_since = null;
        self.last_paint = now;
    }

    /// The pending request turned out to have nothing to paint. Nothing went
    /// out, so the window is not restarted.
    pub fn cancel(self: *Scheduler) void {
        self.pending_since = null;
    }

    pub fn isPending(self: *const Scheduler) bool {
        return self.pending_since != null;
    }

    /// A phase boundary: the next phase starts with nothing pending and no
    /// window to wait out.
    pub fn reset(self: *Scheduler) void {
        self.* = .{ .window_ms = self.window_ms };
    }
};

const testing = std.testing;

test "an isolated request paints at once" {
    var s: Scheduler = .{};
    try testing.expectEqual(Scheduler.Verdict.paint_now, s.request(1000));
    s.painted(1000);
    try testing.expect(!s.isPending());
    // A request a full window later is isolated again.
    try testing.expectEqual(Scheduler.Verdict.paint_now, s.request(1016));
}

test "a burst inside the window collapses into one frame at its end" {
    var s: Scheduler = .{};
    try testing.expectEqual(Scheduler.Verdict.paint_now, s.request(0));
    s.painted(0);
    for ([_]i64{ 1, 3, 7, 15 }) |t| try testing.expectEqual(Scheduler.Verdict.deferred, s.request(t));
    try testing.expectEqual(@as(?i64, 16), s.deadline());
    try testing.expect(!s.due(15));
    try testing.expect(s.due(16));
    s.painted(16);
    try testing.expect(!s.isPending());
}

test "an immediate paint satisfies the pending frame" {
    var s: Scheduler = .{};
    s.painted(0);
    try testing.expectEqual(Scheduler.Verdict.deferred, s.request(5));
    s.painted(9); // a submit painted the latest state
    try testing.expect(!s.isPending());
    try testing.expect(s.deadline() == null);
    // and the window restarts from that paint
    try testing.expectEqual(Scheduler.Verdict.deferred, s.request(20));
    try testing.expectEqual(@as(?i64, 25), s.deadline());
}

test "a sustained stream paints at most once per window" {
    var s: Scheduler = .{};
    var paints: usize = 0;
    var t: i64 = 0;
    while (t < 1000) : (t += 2) { // a request every 2 ms for one second
        if (s.request(t) == .paint_now) {
            s.painted(t);
            paints += 1;
        } else if (s.due(t)) {
            s.painted(t);
            paints += 1;
        }
    }
    try testing.expect(paints <= 1000 / WINDOW_MS + 1);
    try testing.expect(paints >= 1000 / WINDOW_MS - 1);
}

test "a cancelled request leaves the window where the last frame put it" {
    var s: Scheduler = .{};
    s.painted(0);
    _ = s.request(5);
    s.cancel();
    try testing.expect(!s.isPending());
    try testing.expectEqual(@as(?i64, 0), s.last_paint);
    try testing.expectEqual(Scheduler.Verdict.paint_now, s.request(16));
}

test "reset drops the pending frame at a phase boundary" {
    var s: Scheduler = .{};
    s.painted(0);
    _ = s.request(3);
    s.reset();
    try testing.expect(!s.isPending());
    try testing.expectEqual(Scheduler.Verdict.paint_now, s.request(4));
}
