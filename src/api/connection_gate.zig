//! Process-wide admission gate for TCP/TLS request setup.
//!
//! Streaming bodies may remain open for minutes, so the lease covers only request construction,
//! body send, and response-head receipt. This bounds simultaneous DNS/TCP/TLS bursts across
//! Anthropic/OpenAI/Gemini clients without serializing active streams.

const std = @import("std");
const sync = @import("platform").sync;
const AbortSignal = @import("../util/abort.zig").AbortSignal;

pub const MAX_CONNECTING_REQUESTS: usize = 8;

pub const Gate = struct {
    mutex: sync.Mutex = .{},
    cond: sync.Condition = .{},
    in_flight: usize = 0,
    limit: usize,

    pub fn init(limit: usize) Gate {
        std.debug.assert(limit > 0);
        return .{ .limit = limit };
    }

    pub fn acquire(self: *Gate, abort: ?*const AbortSignal) error{Aborted}!Lease {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (self.in_flight >= self.limit) {
            if (abort) |signal| if (signal.isAborted()) return error.Aborted;
            // Timed wait keeps cancellation responsive even when no holder releases promptly.
            _ = self.cond.timedWait(&self.mutex, 50 * std.time.ns_per_ms);
        }
        if (abort) |signal| if (signal.isAborted()) return error.Aborted;
        self.in_flight += 1;
        return .{ .gate = self };
    }

    fn releaseOne(self: *Gate) void {
        self.mutex.lock();
        std.debug.assert(self.in_flight > 0);
        self.in_flight -= 1;
        self.cond.signal();
        self.mutex.unlock();
    }

    pub fn current(self: *Gate) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.in_flight;
    }
};

pub const Lease = struct {
    gate: ?*Gate,

    /// Idempotent so callers can release immediately after receiveHead and still keep a defer
    /// beside acquisition for every error path.
    pub fn release(self: *Lease) void {
        const gate = self.gate orelse return;
        self.gate = null;
        gate.releaseOne();
    }
};

var process_gate = Gate.init(MAX_CONNECTING_REQUESTS);

pub fn acquire(abort: ?*const AbortSignal) error{Aborted}!Lease {
    return process_gate.acquire(abort);
}

test "Gate bounds concurrent setup and releases idempotently" {
    var gate = Gate.init(1);
    var first = try gate.acquire(null);
    try std.testing.expectEqual(@as(usize, 1), gate.current());
    first.release();
    first.release();
    try std.testing.expectEqual(@as(usize, 0), gate.current());
}

test "Gate capacity is enforced under concurrent callers" {
    const Shared = struct {
        gate: Gate = Gate.init(2),
        active: std.atomic.Value(usize) = .init(0),
        max_active: std.atomic.Value(usize) = .init(0),
        release: std.atomic.Value(bool) = .init(false),

        fn worker(self: *@This()) void {
            var lease = self.gate.acquire(null) catch return;
            defer lease.release();
            const now = self.active.fetchAdd(1, .acq_rel) + 1;
            if (now > self.max_active.load(.acquire)) self.max_active.store(now, .release);
            while (!self.release.load(.acquire)) std.Thread.yield() catch {};
            _ = self.active.fetchSub(1, .acq_rel);
        }
    };
    var shared = Shared{};
    var threads: [4]std.Thread = undefined;
    for (&threads) |*thread| thread.* = try std.Thread.spawn(.{}, Shared.worker, .{&shared});
    while (shared.active.load(.acquire) < 2) std.Thread.yield() catch {};
    // Give blocked callers ample scheduling opportunities; they must not enter above capacity.
    for (0..10_000) |_| std.Thread.yield() catch {};
    try std.testing.expectEqual(@as(usize, 2), shared.max_active.load(.acquire));
    shared.release.store(true, .release);
    for (threads) |thread| thread.join();
    try std.testing.expectEqual(@as(usize, 0), shared.gate.current());
}
