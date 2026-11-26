//! Process-wide admission gate for TCP/TLS request setup.
//!
//! Streaming bodies may remain open for minutes, so the lease covers only request construction,
//! body send, and response-head receipt. This bounds simultaneous DNS/TCP/TLS bursts across
//! Anthropic/OpenAI/Gemini clients without serializing active streams.

const std = @import("std");
const sync = @import("platform").sync;
const AbortSignal = @import("metacodes-base").util.abort.AbortSignal;

pub const MAX_CONNECTING_REQUESTS: usize = 8;

pub const Gate = struct {
    mutex: sync.Mutex = .{},
    cond: sync.Condition = .{},
    in_flight: usize = 0,
    /// Callers blocked in `acquire` for a slot.
    waiting: usize = 0,
    limit: usize,

    pub fn init(limit: usize) Gate {
        std.debug.assert(limit > 0);
        return .{ .limit = limit };
    }

    pub fn acquire(self: *Gate, abort: ?*const AbortSignal) error{Aborted}!Lease {
        self.mutex.lock();
        defer self.mutex.unlock();
        var counted = false;
        defer if (counted) {
            self.waiting -= 1;
        };
        while (self.in_flight >= self.limit) {
            if (!counted) {
                counted = true;
                self.waiting += 1;
            }
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

/// Raise the process-wide limit (never below `MAX_CONNECTING_REQUESTS`).
///
/// The lease covers the wait for the response head, which for a model
/// request is its time to first token: a process that serves many clients'
/// model calls at once — the sealed gateway — would otherwise be capped at
/// eight concurrent calls whatever its worker count (`sealed:bench` found
/// it: throughput flat at 8 ÷ latency). The CLI keeps the default.
pub fn raiseProcessLimit(limit: usize) void {
    process_gate.mutex.lock();
    defer process_gate.mutex.unlock();
    if (limit > process_gate.limit) {
        process_gate.limit = limit;
        process_gate.cond.broadcast();
    }
}

/// Callers waiting for a process slot now (a test can tell that a request
/// is queued at the gate).
pub fn processWaiting() usize {
    process_gate.mutex.lock();
    defer process_gate.mutex.unlock();
    return process_gate.waiting;
}

pub fn processLimit() usize {
    process_gate.mutex.lock();
    defer process_gate.mutex.unlock();
    return process_gate.limit;
}

test "raiseProcessLimit only ever raises, and wakes waiters" {
    const before = processLimit();
    raiseProcessLimit(1);
    try std.testing.expectEqual(before, processLimit());
    raiseProcessLimit(before + 3);
    try std.testing.expectEqual(before + 3, processLimit());
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
            // One read-modify-write: a load-then-store lets a later, smaller
            // `now` overwrite a larger one, so the peak could read 1.
            _ = self.max_active.fetchMax(now, .acq_rel);
            while (!self.release.load(.acquire)) std.Thread.yield() catch {};
            _ = self.active.fetchSub(1, .acq_rel);
        }
    };
    var shared = Shared{};
    var threads: [4]std.Thread = undefined;
    for (&threads) |*thread| thread.* = try std.Thread.spawn(.{}, Shared.worker, .{&shared});
    // Wait for the recorded peak, not `active`: a caller counts itself in
    // `active` before it records the peak.
    while (shared.max_active.load(.acquire) < 2) std.Thread.yield() catch {};
    // Give blocked callers ample scheduling opportunities; they must not enter above capacity.
    for (0..10_000) |_| std.Thread.yield() catch {};
    try std.testing.expectEqual(@as(usize, 2), shared.max_active.load(.acquire));
    shared.release.store(true, .release);
    for (threads) |thread| thread.join();
    try std.testing.expectEqual(@as(usize, 0), shared.gate.current());
}

test "Gate counts a caller while it waits for a slot" {
    var gate = Gate.init(1);
    var held = try gate.acquire(null);
    const Waiter = struct {
        fn run(target: *Gate) void {
            var lease = target.acquire(null) catch return;
            lease.release();
        }
    };
    const thread = try std.Thread.spawn(.{}, Waiter.run, .{&gate});
    while (true) {
        gate.mutex.lock();
        const waiting = gate.waiting;
        gate.mutex.unlock();
        if (waiting == 1) break;
        std.Thread.yield() catch {};
    }
    held.release();
    thread.join();
    try std.testing.expectEqual(@as(usize, 0), gate.waiting);
    try std.testing.expectEqual(@as(usize, 0), gate.current());
}
