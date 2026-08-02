//! Process-wide admission control for isolated WebSearch subrequests.
//!
//! Each admitted search owns its provider/client, so active streams are safe to
//! overlap. The separate cap protects all sessions in the process from turning
//! one model tool batch into an unbounded outbound request burst.

const std = @import("std");
const connection_gate = @import("connection_gate.zig");
const AbortSignal = @import("../util/abort.zig").AbortSignal;

pub const MAX_CONCURRENT_WEB_SEARCHES: usize = 2;
pub const Gate = connection_gate.Gate;
pub const Lease = connection_gate.Lease;

var process_gate = Gate.init(MAX_CONCURRENT_WEB_SEARCHES);

pub fn acquire(abort: ?*const AbortSignal) error{Aborted}!Lease {
    return process_gate.acquire(abort);
}

test "three searches are bounded at two" {
    const Shared = struct {
        gate: Gate = Gate.init(MAX_CONCURRENT_WEB_SEARCHES),
        active: std.atomic.Value(usize) = .init(0),
        max_active: std.atomic.Value(usize) = .init(0),
        entered: std.atomic.Value(usize) = .init(0),
        release: std.atomic.Value(bool) = .init(false),

        fn worker(self: *@This()) void {
            var lease = self.gate.acquire(null) catch return;
            defer lease.release();
            const now = self.active.fetchAdd(1, .acq_rel) + 1;
            _ = self.entered.fetchAdd(1, .acq_rel);
            var seen = self.max_active.load(.acquire);
            while (now > seen) {
                seen = self.max_active.cmpxchgWeak(seen, now, .acq_rel, .acquire) orelse break;
            }
            while (!self.release.load(.acquire)) std.Thread.yield() catch {};
            _ = self.active.fetchSub(1, .acq_rel);
        }
    };

    var shared = Shared{};
    var threads: [3]std.Thread = undefined;
    for (&threads) |*thread| thread.* = try std.Thread.spawn(.{}, Shared.worker, .{&shared});
    while (shared.entered.load(.acquire) < MAX_CONCURRENT_WEB_SEARCHES) std.Thread.yield() catch {};
    for (0..10_000) |_| std.Thread.yield() catch {};
    try std.testing.expectEqual(MAX_CONCURRENT_WEB_SEARCHES, shared.max_active.load(.acquire));
    try std.testing.expectEqual(MAX_CONCURRENT_WEB_SEARCHES, shared.entered.load(.acquire));
    shared.release.store(true, .release);
    for (threads) |thread| thread.join();
    try std.testing.expectEqual(@as(usize, 3), shared.entered.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), shared.gate.current());
}

test "waiting search observes abort and failed holder cannot leak permit" {
    var gate = Gate.init(1);
    var holder = try gate.acquire(null);
    var signal = AbortSignal.init();
    const Waiting = struct {
        gate: *Gate,
        signal: *AbortSignal,
        aborted: std.atomic.Value(bool) = .init(false),

        fn run(self: *@This()) void {
            _ = self.gate.acquire(self.signal) catch {
                self.aborted.store(true, .release);
                return;
            };
        }
    };
    var waiting = Waiting{ .gate = &gate, .signal = &signal };
    const thread = try std.Thread.spawn(.{}, Waiting.run, .{&waiting});
    signal.abort(.user_interrupt);
    thread.join();
    try std.testing.expect(waiting.aborted.load(.acquire));

    // Simulate every early-return/error path by releasing through defer semantics.
    holder.release();
    var after_failure = try gate.acquire(null);
    after_failure.release();
    try std.testing.expectEqual(@as(usize, 0), gate.current());
}
