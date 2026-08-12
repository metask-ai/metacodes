const std = @import("std");

/// Owns persistent-index repair coordination while the storage façade keeps
/// canonical log replay, spool construction, index encoding, and publication
/// behind `Ops`. The split makes the recovery protocol directly testable
/// without exposing Store internals or inventing a second persistence API.
pub fn RepairSession(comptime Ops: type) type {
    return struct {
        pub const PersistentRepairTimings = struct {
            truncate_ns: u128 = 0,
            rebuild_total_ns: u128 = 0,
            reuse_attempt_ns: u128 = 0,
            retry_rebuild_ns: u128 = 0,
            replay_events_ns: u128 = 0,
            spool_flush_ns: u128 = 0,
            node_by_id_finalize_ns: u128 = 0,
            primary_rename_ns: u128 = 0,
            node_texts_compress_ns: u128 = 0,
            node_text_index_ns: u128 = 0,
            edge_index_ns: u128 = 0,
            edge_id_index_ns: u128 = 0,
            edge_src_index_ns: u128 = 0,
            edge_dst_index_ns: u128 = 0,
            tombstone_index_ns: u128 = 0,
            meta_write_ns: u128 = 0,
            drop_overlay_ns: u128 = 0,
            reuse_failed: bool = false,
            nodes: u64 = 0,
            edges: u64 = 0,
            node_text_records: u64 = 0,
            edge_records: u64 = 0,
            tombstone_records: u64 = 0,
        };

        pub fn repair(context: anytype, timings: *PersistentRepairTimings) !void {
            timings.* = .{};
            const committed_node_text_journal = try Ops.recoverCommittedNodeTextJournal(context);

            const truncate_start = Ops.monotonicNs(context);
            try Ops.truncateIncompleteBatchTail(context);
            timings.truncate_ns = Ops.elapsedNs(context, truncate_start);

            const rebuild_start = Ops.monotonicNs(context);
            try Internal.rebuildWithTextReuse(context, timings);
            timings.rebuild_total_ns = Ops.elapsedNs(context, rebuild_start);

            const drop_start = Ops.monotonicNs(context);
            Ops.dropRedundantEdgeOverlay(context);
            timings.drop_overlay_ns = Ops.elapsedNs(context, drop_start);
            if (committed_node_text_journal) {
                Ops.cleanupCommittedNodeTextJournal(context);
            }
        }

        pub const Internal = struct {
            pub fn rebuildWithTextReuse(context: anytype, timings: *PersistentRepairTimings) !void {
                const reuse_start = Ops.monotonicNs(context);
                Ops.rebuildPersistentIndexes(context, true, timings) catch |err| switch (err) {
                    error.CannotReuseNodeTexts => {
                        timings.reuse_failed = true;
                        timings.reuse_attempt_ns += Ops.elapsedNs(context, reuse_start);

                        const retry_start = Ops.monotonicNs(context);
                        Ops.rebuildPersistentIndexes(context, false, timings) catch |retry_err| {
                            timings.retry_rebuild_ns += Ops.elapsedNs(context, retry_start);
                            return retry_err;
                        };
                        timings.retry_rebuild_ns += Ops.elapsedNs(context, retry_start);
                        return;
                    },
                    else => |other| return other,
                };
                timings.reuse_attempt_ns += Ops.elapsedNs(context, reuse_start);
            }
        };
    };
}

const TestFailure = enum {
    none,
    cannot_reuse,
    denied,
};

const TestPhase = enum {
    recover,
    truncate,
    rebuild_reuse,
    rebuild_fresh,
    drop_overlay,
    cleanup_journal,
};

const TestContext = struct {
    phases: [8]TestPhase = undefined,
    phase_count: usize = 0,
    clock: u128 = 0,
    committed_journal: bool = false,
    reuse_failure: TestFailure = .none,
    fresh_failure: TestFailure = .none,

    fn record(self: *TestContext, phase: TestPhase) void {
        self.phases[self.phase_count] = phase;
        self.phase_count += 1;
    }

    fn recorded(self: *const TestContext) []const TestPhase {
        return self.phases[0..self.phase_count];
    }
};

const TestOps = struct {
    fn monotonicNs(context: *TestContext) u128 {
        context.clock += 10;
        return context.clock;
    }

    fn elapsedNs(context: *TestContext, start: u128) u128 {
        context.clock += 7;
        return context.clock - start;
    }

    fn recoverCommittedNodeTextJournal(context: *TestContext) !bool {
        context.record(.recover);
        return context.committed_journal;
    }

    fn truncateIncompleteBatchTail(context: *TestContext) !void {
        context.record(.truncate);
    }

    fn rebuildPersistentIndexes(
        context: *TestContext,
        reuse_node_texts: bool,
        timings: anytype,
    ) anyerror!void {
        _ = timings;
        context.record(if (reuse_node_texts) .rebuild_reuse else .rebuild_fresh);
        const failure = if (reuse_node_texts) context.reuse_failure else context.fresh_failure;
        return switch (failure) {
            .none => {},
            .cannot_reuse => error.CannotReuseNodeTexts,
            .denied => error.AccessDenied,
        };
    }

    fn dropRedundantEdgeOverlay(context: *TestContext) void {
        context.record(.drop_overlay);
    }

    fn cleanupCommittedNodeTextJournal(context: *TestContext) void {
        context.record(.cleanup_journal);
    }
};

const test_session = RepairSession(TestOps);

test "repair session sequences recovery rebuild overlay and committed cleanup" {
    var context = TestContext{ .committed_journal = true };
    var timings = test_session.PersistentRepairTimings{};

    try test_session.repair(&context, &timings);

    try std.testing.expectEqualSlices(TestPhase, &.{
        .recover,
        .truncate,
        .rebuild_reuse,
        .drop_overlay,
        .cleanup_journal,
    }, context.recorded());
    try std.testing.expect(timings.truncate_ns > 0);
    try std.testing.expect(timings.rebuild_total_ns > 0);
    try std.testing.expect(timings.reuse_attempt_ns > 0);
    try std.testing.expect(timings.drop_overlay_ns > 0);
    try std.testing.expect(!timings.reuse_failed);
}

test "repair session retries exactly once when node texts cannot be reused" {
    var context = TestContext{ .reuse_failure = .cannot_reuse };
    var timings = test_session.PersistentRepairTimings{};

    try test_session.repair(&context, &timings);

    try std.testing.expectEqualSlices(TestPhase, &.{
        .recover,
        .truncate,
        .rebuild_reuse,
        .rebuild_fresh,
        .drop_overlay,
    }, context.recorded());
    try std.testing.expect(timings.reuse_failed);
    try std.testing.expect(timings.reuse_attempt_ns > 0);
    try std.testing.expect(timings.retry_rebuild_ns > 0);
}

test "repair session propagates non-reuse failure without retry or cleanup" {
    var context = TestContext{
        .committed_journal = true,
        .reuse_failure = .denied,
    };
    var timings = test_session.PersistentRepairTimings{};

    try std.testing.expectError(error.AccessDenied, test_session.repair(&context, &timings));

    try std.testing.expectEqualSlices(TestPhase, &.{
        .recover,
        .truncate,
        .rebuild_reuse,
    }, context.recorded());
    try std.testing.expect(!timings.reuse_failed);
    try std.testing.expectEqual(@as(u128, 0), timings.rebuild_total_ns);
}

test "repair session records failed fresh retry and keeps committed journal" {
    var context = TestContext{
        .committed_journal = true,
        .reuse_failure = .cannot_reuse,
        .fresh_failure = .denied,
    };
    var timings = test_session.PersistentRepairTimings{};

    try std.testing.expectError(error.AccessDenied, test_session.repair(&context, &timings));

    try std.testing.expectEqualSlices(TestPhase, &.{
        .recover,
        .truncate,
        .rebuild_reuse,
        .rebuild_fresh,
    }, context.recorded());
    try std.testing.expect(timings.reuse_failed);
    try std.testing.expect(timings.retry_rebuild_ns > 0);
}

test "repair session resets telemetry and skips absent journal cleanup" {
    var context = TestContext{};
    var timings = test_session.PersistentRepairTimings{
        .truncate_ns = 999,
        .reuse_failed = true,
        .nodes = 999,
    };

    try test_session.repair(&context, &timings);

    try std.testing.expectEqualSlices(TestPhase, &.{
        .recover,
        .truncate,
        .rebuild_reuse,
        .drop_overlay,
    }, context.recorded());
    try std.testing.expect(timings.truncate_ns != 999);
    try std.testing.expect(!timings.reuse_failed);
    try std.testing.expectEqual(@as(u64, 0), timings.nodes);
}
