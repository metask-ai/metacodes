const std = @import("std");
const compaction_policy = @import("edge_segment_compaction_policy.zig");

/// Owns edge-segment maintenance admission, ordering, and stable result
/// mapping. The storage facade supplies manifest/meta access, compaction,
/// publication, garbage collection, and path mechanics through `Ops`.
pub fn EdgeSegmentMaintenance(comptime Ops: type) type {
    return struct {
        /// Append-log mutations are already committed before this hook runs.
        /// Each maintenance action is therefore independently best-effort so
        /// one derived-index failure cannot suppress the other action or make
        /// callers retry a committed append.
        pub fn afterCommittedAppend(context: anytype) void {
            _ = Ops.dropRedundantOverlay(context) catch {};
            _ = autoCompactIfNeeded(context) catch {};
        }

        pub fn autoCompactIfNeeded(context: anytype) !bool {
            const threshold = Ops.autoCompactEntryThreshold(context);
            if (threshold == 0) return false;

            var manifest = Ops.readManifest(context) catch |err| switch (err) {
                error.FileNotFound => return false,
                else => |e| return e,
            };
            defer Ops.deinitManifest(context, &manifest);
            const entries = Ops.manifestEntries(&manifest);
            if (entries.len <= 1 or entries.len < threshold) return false;

            const meta = try Ops.readCurrentMeta(context);
            const manifest_edges = Ops.totalEdgeCount(&manifest);
            const physical_edges = (try Ops.coveredPhysicalEdges(context, meta, manifest_edges)) orelse return false;
            if (manifest_edges == physical_edges) return false;

            const configured_batch = Ops.autoCompactBatchEntries(context);
            const batch_limit = if (configured_batch == 0)
                entries.len
            else
                @min(entries.len, configured_batch);
            if (batch_limit <= 1) return false;

            const window = (try compaction_policy.select(Ops.allocator(context), entries, batch_limit, 0)) orelse return false;
            const target_path = try compactionTargetPath(context, entries, window);
            defer Ops.freePath(context, target_path);
            if (try Ops.pathExists(context, target_path)) return false;

            try Ops.compactWindow(context, target_path, entries, window.start, window.count, window.edge_count);
            if (Ops.autoGcEnabled(context)) _ = try Ops.gcAfterAutoCompaction(context);
            return true;
        }

        pub fn compactBudgeted(
            context: anytype,
            budget: Ops.BudgetType,
            pinned_manifest_paths: []const []const u8,
        ) !Ops.ResultType {
            var manifest = Ops.readManifest(context) catch |err| switch (err) {
                error.FileNotFound => return .{ .compacted = false },
                else => |e| return e,
            };
            defer Ops.deinitManifest(context, &manifest);
            const entries = Ops.manifestEntries(&manifest);
            const entries_before = entries.len;
            if (entries_before <= 1) return unchangedResult(entries_before);

            const meta = try Ops.readCurrentMeta(context);
            const manifest_edges = Ops.totalEdgeCount(&manifest);
            _ = (try Ops.coveredPhysicalEdges(context, meta, manifest_edges)) orelse
                return unchangedResult(entries_before);

            const max_segments = if (budget.max_segments == 0)
                entries_before
            else
                @min(entries_before, budget.max_segments);
            const window = (try compaction_policy.select(
                Ops.allocator(context),
                entries,
                max_segments,
                budget.max_edges,
            )) orelse return unchangedResult(entries_before);
            const target_path = try compactionTargetPath(context, entries, window);
            defer Ops.freePath(context, target_path);
            if (try Ops.pathExists(context, target_path)) return unchangedResult(entries_before);

            try Ops.compactWindow(context, target_path, entries, window.start, window.count, window.edge_count);
            const gc_result = if (Ops.autoGcEnabled(context))
                try Ops.gcAfterBudgetedCompaction(context, pinned_manifest_paths)
            else
                Ops.GcResultType{};
            return .{
                .compacted = true,
                .compacted_edges = window.edge_count,
                .compacted_segments = window.count,
                .gc_deleted_segments = gc_result.deleted_segments,
                .gc_deleted_manifests = gc_result.deleted_manifests,
                .manifest_entries_before = entries_before,
                .manifest_entries_after = entries_before - window.count + 1,
            };
        }

        fn compactionTargetPath(context: anytype, entries: anytype, window: compaction_policy.Window) ![]u8 {
            const compact_entries = entries[window.start..][0..window.count];
            const compact_digest = try Ops.manifestOwnedDigest(context, compact_entries);
            return Ops.autoCompactedPath(context, window.edge_count, window.count, compact_digest);
        }

        fn unchangedResult(entries_before: usize) Ops.ResultType {
            return .{
                .compacted = false,
                .manifest_entries_before = entries_before,
                .manifest_entries_after = entries_before,
            };
        }
    };
}

const TestMeta = struct {};

const TestEntry = struct {
    edge_count: u64,
};

const TestManifest = struct {
    entries: []const TestEntry,
    total_edges: u64,
};

const TestBudget = struct {
    max_segments: usize = 0,
    max_edges: u64 = 0,
};

const TestResult = struct {
    compacted: bool,
    compacted_edges: u64 = 0,
    compacted_segments: usize = 0,
    gc_deleted_segments: u64 = 0,
    gc_deleted_manifests: u64 = 0,
    manifest_entries_before: usize = 0,
    manifest_entries_after: usize = 0,
};

const TestGcResult = struct {
    deleted_segments: u64 = 0,
    deleted_manifests: u64 = 0,
};

const TestPhase = enum {
    drop_redundant,
    read_manifest,
    read_meta,
    covered_physical,
    manifest_digest,
    build_path,
    path_exists,
    compact_window,
    gc,
    free_path,
    deinit_manifest,
};

const TestContext = struct {
    phases: [48]TestPhase = undefined,
    phase_count: usize = 0,
    fail_at: ?TestPhase = null,
    manifest_missing: bool = false,
    threshold: usize = 0,
    batch_entries: usize = 0,
    auto_gc: bool = false,
    entries: [5]TestEntry = .{
        .{ .edge_count = 3 },
        .{ .edge_count = 3 },
        .{ .edge_count = 1 },
        .{ .edge_count = 1 },
        .{ .edge_count = 20 },
    },
    entry_count: usize = 0,
    total_edges: u64 = 0,
    covered_physical_edges: ?u64 = 0,
    target_exists: bool = false,
    compact_start: usize = 0,
    compact_count: usize = 0,
    compact_edges: u64 = 0,
    pinned_path_count: usize = 0,
    gc_result: TestGcResult = .{},
    manifest_deinit_count: usize = 0,
    free_path_count: usize = 0,

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
    pub const BudgetType = TestBudget;
    pub const ResultType = TestResult;
    pub const GcResultType = TestGcResult;

    pub fn allocator(_: *TestContext) std.mem.Allocator {
        return std.testing.allocator;
    }

    pub fn autoCompactEntryThreshold(context: *TestContext) usize {
        return context.threshold;
    }

    pub fn autoCompactBatchEntries(context: *TestContext) usize {
        return context.batch_entries;
    }

    pub fn autoGcEnabled(context: *TestContext) bool {
        return context.auto_gc;
    }

    pub fn dropRedundantOverlay(context: *TestContext) !bool {
        try context.record(.drop_redundant);
        return true;
    }

    pub fn readManifest(context: *TestContext) !TestManifest {
        try context.record(.read_manifest);
        if (context.manifest_missing) return error.FileNotFound;
        return .{
            .entries = context.entries[0..context.entry_count],
            .total_edges = context.total_edges,
        };
    }

    pub fn deinitManifest(context: *TestContext, manifest: *TestManifest) void {
        _ = manifest;
        context.recordCleanup(.deinit_manifest);
        context.manifest_deinit_count += 1;
    }

    pub fn manifestEntries(manifest: *const TestManifest) []const TestEntry {
        return manifest.entries;
    }

    pub fn totalEdgeCount(manifest: *const TestManifest) u64 {
        return manifest.total_edges;
    }

    pub fn readCurrentMeta(context: *TestContext) !TestMeta {
        try context.record(.read_meta);
        return .{};
    }

    pub fn coveredPhysicalEdges(context: *TestContext, _: TestMeta, manifest_edges: u64) !?u64 {
        try context.record(.covered_physical);
        try std.testing.expectEqual(context.total_edges, manifest_edges);
        return context.covered_physical_edges;
    }

    pub fn manifestOwnedDigest(context: *TestContext, entries: []const TestEntry) !u64 {
        try context.record(.manifest_digest);
        var digest: u64 = 0;
        for (entries) |entry| digest +%= entry.edge_count;
        return digest;
    }

    pub fn autoCompactedPath(context: *TestContext, edge_count: u64, count: usize, digest: u64) ![]u8 {
        try context.record(.build_path);
        return std.fmt.allocPrint(std.testing.allocator, "auto-{d}-{d}-{d}", .{ edge_count, count, digest });
    }

    pub fn freePath(context: *TestContext, path: []const u8) void {
        std.testing.allocator.free(path);
        context.recordCleanup(.free_path);
        context.free_path_count += 1;
    }

    pub fn pathExists(context: *TestContext, _: []const u8) !bool {
        try context.record(.path_exists);
        return context.target_exists;
    }

    pub fn compactWindow(
        context: *TestContext,
        target_path: []const u8,
        _: []const TestEntry,
        start: usize,
        count: usize,
        edge_count: u64,
    ) !void {
        try context.record(.compact_window);
        try std.testing.expect(target_path.len != 0);
        context.compact_start = start;
        context.compact_count = count;
        context.compact_edges = edge_count;
    }

    pub fn gcAfterAutoCompaction(context: *TestContext) !TestGcResult {
        try context.record(.gc);
        context.pinned_path_count = 0;
        return context.gc_result;
    }

    pub fn gcAfterBudgetedCompaction(context: *TestContext, pinned_manifest_paths: []const []const u8) !TestGcResult {
        try context.record(.gc);
        context.pinned_path_count = pinned_manifest_paths.len;
        return context.gc_result;
    }
};

const test_maintenance = EdgeSegmentMaintenance(TestOps);

test "edge segment maintenance keeps post-append actions independently best effort" {
    var drop_failed = TestContext{
        .fail_at = .drop_redundant,
        .manifest_missing = true,
        .threshold = 2,
    };
    test_maintenance.afterCommittedAppend(&drop_failed);
    try std.testing.expectEqualSlices(TestPhase, &.{ .drop_redundant, .read_manifest }, drop_failed.recorded());

    var compact_failed = TestContext{
        .fail_at = .read_manifest,
        .threshold = 2,
    };
    test_maintenance.afterCommittedAppend(&compact_failed);
    try std.testing.expectEqualSlices(TestPhase, &.{ .drop_redundant, .read_manifest }, compact_failed.recorded());
}

test "edge segment maintenance auto admission preserves cheap no-ops" {
    var disabled = TestContext{};
    try std.testing.expect(!try test_maintenance.autoCompactIfNeeded(&disabled));
    try std.testing.expectEqual(@as(usize, 0), disabled.phase_count);

    var missing = TestContext{ .manifest_missing = true, .threshold = 2 };
    try std.testing.expect(!try test_maintenance.autoCompactIfNeeded(&missing));
    try std.testing.expectEqualSlices(TestPhase, &.{.read_manifest}, missing.recorded());

    var short = TestContext{ .threshold = 2, .entry_count = 1, .total_edges = 3 };
    try std.testing.expect(!try test_maintenance.autoCompactIfNeeded(&short));
    try std.testing.expectEqual(@as(usize, 1), short.manifest_deinit_count);
    try std.testing.expectEqualSlices(TestPhase, &.{ .read_manifest, .deinit_manifest }, short.recorded());

    var below_threshold = TestContext{ .threshold = 3, .entry_count = 2, .total_edges = 6 };
    try std.testing.expect(!try test_maintenance.autoCompactIfNeeded(&below_threshold));
    try std.testing.expectEqualSlices(TestPhase, &.{ .read_manifest, .deinit_manifest }, below_threshold.recorded());
}

test "edge segment maintenance auto compaction requires an uncovered overlay" {
    var uncovered_unknown = TestContext{
        .threshold = 2,
        .entry_count = 2,
        .total_edges = 6,
        .covered_physical_edges = null,
    };
    try std.testing.expect(!try test_maintenance.autoCompactIfNeeded(&uncovered_unknown));
    try std.testing.expectEqualSlices(TestPhase, &.{
        .read_manifest,
        .read_meta,
        .covered_physical,
        .deinit_manifest,
    }, uncovered_unknown.recorded());

    var fully_physical = TestContext{
        .threshold = 2,
        .entry_count = 2,
        .total_edges = 6,
        .covered_physical_edges = 6,
    };
    try std.testing.expect(!try test_maintenance.autoCompactIfNeeded(&fully_physical));
    try std.testing.expectEqualSlices(TestPhase, &.{
        .read_manifest,
        .read_meta,
        .covered_physical,
        .deinit_manifest,
    }, fully_physical.recorded());
}

test "edge segment maintenance auto compacts one bounded policy window" {
    var context = TestContext{
        .threshold = 2,
        .batch_entries = 2,
        .auto_gc = true,
        .entry_count = 3,
        .total_edges = 7,
        .covered_physical_edges = 3,
        .gc_result = .{ .deleted_segments = 2, .deleted_manifests = 1 },
    };
    try std.testing.expect(try test_maintenance.autoCompactIfNeeded(&context));
    try std.testing.expectEqual(@as(usize, 0), context.compact_start);
    try std.testing.expectEqual(@as(usize, 2), context.compact_count);
    try std.testing.expectEqual(@as(u64, 6), context.compact_edges);
    try std.testing.expectEqual(@as(usize, 0), context.pinned_path_count);
    try std.testing.expectEqual(@as(usize, 1), context.free_path_count);
    try std.testing.expectEqualSlices(TestPhase, &.{
        .read_manifest,
        .read_meta,
        .covered_physical,
        .manifest_digest,
        .build_path,
        .path_exists,
        .compact_window,
        .gc,
        .free_path,
        .deinit_manifest,
    }, context.recorded());
}

test "edge segment maintenance auto compaction preserves an existing-target no-op" {
    var context = TestContext{
        .threshold = 2,
        .batch_entries = 2,
        .entry_count = 2,
        .total_edges = 6,
        .covered_physical_edges = 3,
        .target_exists = true,
    };
    try std.testing.expect(!try test_maintenance.autoCompactIfNeeded(&context));
    try std.testing.expectEqual(@as(usize, 0), context.compact_count);
    try std.testing.expectEqual(@as(usize, 1), context.free_path_count);
}

test "edge segment maintenance budgeted admission reports stable no-ops" {
    var missing = TestContext{ .manifest_missing = true };
    const missing_result = try test_maintenance.compactBudgeted(&missing, .{}, &.{});
    try std.testing.expect(!missing_result.compacted);

    var singleton = TestContext{ .entry_count = 1, .total_edges = 3 };
    const singleton_result = try test_maintenance.compactBudgeted(&singleton, .{}, &.{});
    try std.testing.expectEqual(@as(usize, 1), singleton_result.manifest_entries_before);
    try std.testing.expectEqual(@as(usize, 1), singleton_result.manifest_entries_after);

    var uncovered = TestContext{
        .entry_count = 2,
        .total_edges = 6,
        .covered_physical_edges = null,
    };
    const uncovered_result = try test_maintenance.compactBudgeted(&uncovered, .{}, &.{});
    try std.testing.expect(!uncovered_result.compacted);
    try std.testing.expectEqual(@as(usize, 2), uncovered_result.manifest_entries_before);

    var over_budget = TestContext{
        .entry_count = 2,
        .total_edges = 6,
        .covered_physical_edges = 3,
    };
    const over_budget_result = try test_maintenance.compactBudgeted(&over_budget, .{ .max_segments = 2, .max_edges = 5 }, &.{});
    try std.testing.expect(!over_budget_result.compacted);
    try std.testing.expectEqual(@as(usize, 2), over_budget_result.manifest_entries_after);
}

test "edge segment maintenance maps budgeted compaction and gc results" {
    var context = TestContext{
        .auto_gc = true,
        .entry_count = 4,
        .total_edges = 8,
        .covered_physical_edges = 3,
        .gc_result = .{ .deleted_segments = 4, .deleted_manifests = 2 },
    };
    const pinned = [_][]const u8{ "manifest-a", "manifest-b" };
    const result = try test_maintenance.compactBudgeted(&context, .{ .max_segments = 2, .max_edges = 6 }, &pinned);
    try std.testing.expect(result.compacted);
    try std.testing.expectEqual(@as(u64, 6), result.compacted_edges);
    try std.testing.expectEqual(@as(usize, 2), result.compacted_segments);
    try std.testing.expectEqual(@as(u64, 4), result.gc_deleted_segments);
    try std.testing.expectEqual(@as(u64, 2), result.gc_deleted_manifests);
    try std.testing.expectEqual(@as(usize, 4), result.manifest_entries_before);
    try std.testing.expectEqual(@as(usize, 3), result.manifest_entries_after);
    try std.testing.expectEqual(@as(usize, 2), context.pinned_path_count);
}

test "edge segment maintenance cleans resources on data-plane failures" {
    var path_failure = TestContext{
        .fail_at = .path_exists,
        .entry_count = 2,
        .total_edges = 6,
        .covered_physical_edges = 3,
    };
    try std.testing.expectError(
        error.InjectedFailure,
        test_maintenance.compactBudgeted(&path_failure, .{}, &.{}),
    );
    try std.testing.expectEqual(@as(usize, 1), path_failure.free_path_count);
    try std.testing.expectEqual(@as(usize, 1), path_failure.manifest_deinit_count);

    var compact_failure = TestContext{
        .fail_at = .compact_window,
        .entry_count = 2,
        .total_edges = 6,
        .covered_physical_edges = 3,
    };
    try std.testing.expectError(
        error.InjectedFailure,
        test_maintenance.compactBudgeted(&compact_failure, .{}, &.{}),
    );
    try std.testing.expectEqual(@as(usize, 1), compact_failure.free_path_count);
    try std.testing.expectEqual(@as(usize, 1), compact_failure.manifest_deinit_count);
}
