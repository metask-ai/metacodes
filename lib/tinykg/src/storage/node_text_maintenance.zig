const std = @import("std");

/// Owns node-text maintenance admission and fallback sequencing. The storage
/// facade supplies concrete metadata, manifests, compaction data planes, and
/// publication mechanics through `Ops`; this controller decides when each
/// mutation is permitted and how its stable result is reported.
pub fn NodeTextMaintenance(comptime Ops: type) type {
    return struct {
        pub fn compactDelta(context: anytype, max_delta_records: u64) !Ops.DeltaResultType {
            const meta = try Ops.readCurrentMeta(context);
            const delta_header = try Ops.readDeltaHeader(context);
            if (delta_header.node_count == 0) return .{
                .compacted = false,
                .delta_records_before = 0,
                .delta_records_after = 0,
            };
            if (max_delta_records != 0 and delta_header.node_count > max_delta_records) return .{
                .compacted = false,
                .delta_records_before = delta_header.node_count,
                .delta_records_after = delta_header.node_count,
            };

            try Ops.compactDeltaForMeta(context, meta);
            return .{
                .compacted = true,
                .delta_records_before = delta_header.node_count,
                .delta_records_after = 0,
            };
        }

        pub fn compactRuns(
            context: anytype,
            max_run_records: u64,
            pinned_manifest_paths: []const []const u8,
        ) !Ops.RunResultType {
            const meta = try Ops.readCurrentMeta(context);
            var manifest = try Ops.readRunManifest(context);
            defer Ops.deinitRunManifest(context, &manifest);
            const entries = Ops.runEntries(&manifest);
            const run_count = Ops.totalRunCount(&manifest);
            if (run_count == std.math.maxInt(u64)) return error.InvalidRecord;

            const delta_header = try Ops.readDeltaHeader(context);
            if (entries.len == 0) return .{
                .compacted = false,
                .run_entries_before = 0,
                .run_entries_after = 0,
                .run_records_before = 0,
                .run_records_after = 0,
                .delta_records_before = delta_header.node_count,
                .delta_records_after = delta_header.node_count,
            };

            if (try Ops.compactRunWindow(
                context,
                meta,
                entries,
                delta_header,
                max_run_records,
                pinned_manifest_paths,
            )) |compacted| {
                return compacted;
            }

            if (max_run_records != 0 and run_count > max_run_records) return .{
                .compacted = false,
                .run_entries_before = entries.len,
                .run_entries_after = entries.len,
                .run_records_before = run_count,
                .run_records_after = run_count,
                .delta_records_before = delta_header.node_count,
                .delta_records_after = delta_header.node_count,
            };

            const compacted = try Ops.compactOverlaysForMeta(context, meta, pinned_manifest_paths);
            return .{
                .compacted = true,
                .run_entries_before = compacted.run_entries_before,
                .run_entries_after = 0,
                .run_records_before = compacted.run_records_before,
                .run_records_after = 0,
                .compacted_run_records = compacted.run_records_before,
                .delta_records_before = compacted.delta_records_before,
                .delta_records_after = 0,
                .gc_deleted_runs = compacted.gc_deleted_runs,
            };
        }
    };
}

const TestMeta = struct {
    nodes: u64 = 11,
    node_digest: u64 = 22,
    node_by_text_order_digest: u64 = 33,
};

const TestDeltaHeader = struct {
    node_count: u64 = 0,
};

const TestEntry = struct {
    records: u64,
};

const TestManifest = struct {
    entries: []const TestEntry,
    total_records: u64,
};

const TestDeltaResult = struct {
    compacted: bool,
    delta_records_before: u64 = 0,
    delta_records_after: u64 = 0,
};

const TestRunResult = struct {
    compacted: bool,
    run_entries_before: usize = 0,
    run_entries_after: usize = 0,
    run_records_before: u64 = 0,
    run_records_after: u64 = 0,
    compacted_run_records: u64 = 0,
    delta_records_before: u64 = 0,
    delta_records_after: u64 = 0,
    gc_deleted_runs: u64 = 0,
};

const TestOverlayResult = struct {
    run_entries_before: usize,
    run_records_before: u64,
    delta_records_before: u64,
    gc_deleted_runs: u64,
};

const TestPhase = enum {
    read_meta,
    read_manifest,
    total_run_count,
    read_delta,
    compact_delta,
    compact_window,
    compact_overlays,
    deinit_manifest,
};

const TestContext = struct {
    phases: [16]TestPhase = undefined,
    phase_count: usize = 0,
    fail_at: ?TestPhase = null,
    meta: TestMeta = .{},
    delta_count: u64 = 0,
    entries: [3]TestEntry = .{ .{ .records = 2 }, .{ .records = 3 }, .{ .records = 5 } },
    entry_count: usize = 0,
    total_records: u64 = 0,
    window_result: ?TestRunResult = null,
    overlay_result: TestOverlayResult = .{
        .run_entries_before = 0,
        .run_records_before = 0,
        .delta_records_before = 0,
        .gc_deleted_runs = 0,
    },
    manifest_deinit_count: usize = 0,
    observed_max_run_records: u64 = 0,
    observed_pinned_paths: usize = 0,

    fn record(self: *TestContext, phase: TestPhase) !void {
        self.phases[self.phase_count] = phase;
        self.phase_count += 1;
        if (self.fail_at == phase) return error.InjectedFailure;
    }

    fn recordCleanup(self: *TestContext, phase: TestPhase) void {
        self.phases[self.phase_count] = phase;
        self.phase_count += 1;
    }

    fn recorded(self: *const TestContext) []const TestPhase {
        return self.phases[0..self.phase_count];
    }
};

const TestOps = struct {
    pub const DeltaResultType = TestDeltaResult;
    pub const RunResultType = TestRunResult;

    pub fn readCurrentMeta(context: *TestContext) !TestMeta {
        try context.record(.read_meta);
        return context.meta;
    }

    pub fn readDeltaHeader(context: *TestContext) !TestDeltaHeader {
        try context.record(.read_delta);
        return .{ .node_count = context.delta_count };
    }

    pub fn compactDeltaForMeta(context: *TestContext, meta: TestMeta) !void {
        try context.record(.compact_delta);
        try std.testing.expectEqual(context.meta, meta);
    }

    pub fn readRunManifest(context: *TestContext) !TestManifest {
        try context.record(.read_manifest);
        return .{
            .entries = context.entries[0..context.entry_count],
            .total_records = context.total_records,
        };
    }

    pub fn deinitRunManifest(context: *TestContext, manifest: *TestManifest) void {
        _ = manifest;
        context.recordCleanup(.deinit_manifest);
        context.manifest_deinit_count += 1;
    }

    pub fn runEntries(manifest: *const TestManifest) []const TestEntry {
        return manifest.entries;
    }

    pub fn totalRunCount(manifest: *const TestManifest) u64 {
        return manifest.total_records;
    }

    pub fn compactRunWindow(
        context: *TestContext,
        meta: TestMeta,
        entries: []const TestEntry,
        delta_header: TestDeltaHeader,
        max_run_records: u64,
        pinned_manifest_paths: []const []const u8,
    ) !?TestRunResult {
        _ = entries;
        try context.record(.compact_window);
        try std.testing.expectEqual(context.meta, meta);
        try std.testing.expectEqual(context.delta_count, delta_header.node_count);
        context.observed_max_run_records = max_run_records;
        context.observed_pinned_paths = pinned_manifest_paths.len;
        return context.window_result;
    }

    pub fn compactOverlaysForMeta(
        context: *TestContext,
        meta: TestMeta,
        pinned_manifest_paths: []const []const u8,
    ) !TestOverlayResult {
        try context.record(.compact_overlays);
        try std.testing.expectEqual(context.meta, meta);
        context.observed_pinned_paths = pinned_manifest_paths.len;
        return context.overlay_result;
    }
};

const test_maintenance = NodeTextMaintenance(TestOps);

test "node text maintenance skips empty and over-budget deltas" {
    var empty = TestContext{};
    const empty_result = try test_maintenance.compactDelta(&empty, 4);
    try std.testing.expect(!empty_result.compacted);
    try std.testing.expectEqualSlices(TestPhase, &.{ .read_meta, .read_delta }, empty.recorded());

    var bounded = TestContext{ .delta_count = 5 };
    const bounded_result = try test_maintenance.compactDelta(&bounded, 4);
    try std.testing.expect(!bounded_result.compacted);
    try std.testing.expectEqual(@as(u64, 5), bounded_result.delta_records_before);
    try std.testing.expectEqual(@as(u64, 5), bounded_result.delta_records_after);
    try std.testing.expectEqualSlices(TestPhase, &.{ .read_meta, .read_delta }, bounded.recorded());
}

test "node text maintenance compacts an admitted delta with current metadata" {
    var context = TestContext{ .delta_count = 5 };
    const result = try test_maintenance.compactDelta(&context, 0);
    try std.testing.expect(result.compacted);
    try std.testing.expectEqual(@as(u64, 5), result.delta_records_before);
    try std.testing.expectEqual(@as(u64, 0), result.delta_records_after);
    try std.testing.expectEqualSlices(TestPhase, &.{ .read_meta, .read_delta, .compact_delta }, context.recorded());
}

test "node text maintenance reports an empty run manifest and always deinitializes it" {
    var context = TestContext{ .delta_count = 4 };
    const result = try test_maintenance.compactRuns(&context, 9, &.{});
    try std.testing.expect(!result.compacted);
    try std.testing.expectEqual(@as(u64, 4), result.delta_records_before);
    try std.testing.expectEqual(@as(usize, 1), context.manifest_deinit_count);
    try std.testing.expectEqualSlices(TestPhase, &.{
        .read_meta,
        .read_manifest,
        .read_delta,
        .deinit_manifest,
    }, context.recorded());
}

test "node text maintenance prefers one bounded run-window result" {
    const expected = TestRunResult{
        .compacted = true,
        .run_entries_before = 3,
        .run_entries_after = 2,
        .run_records_before = 10,
        .run_records_after = 10,
        .compacted_run_records = 5,
        .delta_records_before = 2,
        .delta_records_after = 2,
        .gc_deleted_runs = 2,
    };
    var context = TestContext{
        .delta_count = 2,
        .entry_count = 3,
        .total_records = 10,
        .window_result = expected,
    };
    const pinned = [_][]const u8{ "manifest-a", "manifest-b" };
    const result = try test_maintenance.compactRuns(&context, 6, &pinned);
    try std.testing.expectEqual(expected, result);
    try std.testing.expectEqual(@as(u64, 6), context.observed_max_run_records);
    try std.testing.expectEqual(@as(usize, 2), context.observed_pinned_paths);
    try std.testing.expectEqualSlices(TestPhase, &.{
        .read_meta,
        .read_manifest,
        .read_delta,
        .compact_window,
        .deinit_manifest,
    }, context.recorded());
}

test "node text maintenance preserves an over-budget run no-op after window selection" {
    var context = TestContext{
        .delta_count = 2,
        .entry_count = 3,
        .total_records = 10,
    };
    const result = try test_maintenance.compactRuns(&context, 6, &.{});
    try std.testing.expect(!result.compacted);
    try std.testing.expectEqual(@as(usize, 3), result.run_entries_before);
    try std.testing.expectEqual(@as(u64, 10), result.run_records_before);
    try std.testing.expectEqual(@as(u64, 2), result.delta_records_before);
    try std.testing.expectEqualSlices(TestPhase, &.{
        .read_meta,
        .read_manifest,
        .read_delta,
        .compact_window,
        .deinit_manifest,
    }, context.recorded());
}

test "node text maintenance falls back to full overlays only within budget" {
    var context = TestContext{
        .delta_count = 2,
        .entry_count = 3,
        .total_records = 10,
        .overlay_result = .{
            .run_entries_before = 3,
            .run_records_before = 10,
            .delta_records_before = 2,
            .gc_deleted_runs = 3,
        },
    };
    const pinned = [_][]const u8{"manifest-a"};
    const result = try test_maintenance.compactRuns(&context, 0, &pinned);
    try std.testing.expect(result.compacted);
    try std.testing.expectEqual(@as(usize, 3), result.run_entries_before);
    try std.testing.expectEqual(@as(usize, 0), result.run_entries_after);
    try std.testing.expectEqual(@as(u64, 10), result.compacted_run_records);
    try std.testing.expectEqual(@as(u64, 3), result.gc_deleted_runs);
    try std.testing.expectEqual(@as(usize, 1), context.observed_pinned_paths);
    try std.testing.expectEqualSlices(TestPhase, &.{
        .read_meta,
        .read_manifest,
        .read_delta,
        .compact_window,
        .compact_overlays,
        .deinit_manifest,
    }, context.recorded());
}

test "node text maintenance rejects overflow and cleans manifests on data-plane errors" {
    var overflow = TestContext{
        .entry_count = 1,
        .total_records = std.math.maxInt(u64),
    };
    try std.testing.expectError(error.InvalidRecord, test_maintenance.compactRuns(&overflow, 0, &.{}));
    try std.testing.expectEqualSlices(TestPhase, &.{
        .read_meta,
        .read_manifest,
        .deinit_manifest,
    }, overflow.recorded());

    var failed = TestContext{
        .fail_at = .compact_window,
        .entry_count = 2,
        .total_records = 5,
    };
    try std.testing.expectError(error.InjectedFailure, test_maintenance.compactRuns(&failed, 0, &.{}));
    try std.testing.expectEqual(@as(usize, 1), failed.manifest_deinit_count);
    try std.testing.expectEqualSlices(TestPhase, &.{
        .read_meta,
        .read_manifest,
        .read_delta,
        .compact_window,
        .deinit_manifest,
    }, failed.recorded());
}
