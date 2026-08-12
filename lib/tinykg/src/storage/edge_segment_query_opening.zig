const std = @import("std");

/// Owns edge-segment query opening admission and lifetime transfer. Concrete
/// manifests, retention leases, CSR/mmap opening, and result types remain in
/// the storage facade behind `Ops`.
pub fn EdgeSegmentQueryOpening(comptime Ops: type) type {
    return struct {
        pub fn openCurrent(
            context: anytype,
            allocator: std.mem.Allocator,
            filter_direction: ?Ops.DirectionType,
            filter_node_id: ?Ops.NodeIdType,
        ) !?Ops.ResultType {
            var manifest = Ops.readCurrentManifest(context, allocator) catch |err| switch (err) {
                error.FileNotFound => return null,
                else => |e| return e,
            };
            defer Ops.deinitManifest(context, allocator, &manifest);
            return openFromManifest(context, allocator, &manifest, filter_direction, filter_node_id);
        }

        pub fn openRetained(
            context: anytype,
            allocator: std.mem.Allocator,
            registry: *Ops.RegistryType,
            filter_direction: ?Ops.DirectionType,
            filter_node_id: ?Ops.NodeIdType,
        ) !?Ops.ResultType {
            var retention_window = try Ops.acquireRetentionWindow(context, registry);
            errdefer Ops.deinitRetentionWindow(&retention_window);
            const manifest_path = Ops.retentionManifestPath(&retention_window) orelse {
                Ops.deinitRetentionWindow(&retention_window);
                return null;
            };

            var manifest = Ops.readManifestAtPath(context, allocator, manifest_path) catch |err| switch (err) {
                error.FileNotFound => return error.InvalidRecord,
                else => |e| return e,
            };
            defer Ops.deinitManifest(context, allocator, &manifest);
            var opened = try openFromManifest(context, allocator, &manifest, filter_direction, filter_node_id);
            if (opened) |*result| {
                Ops.attachRetentionWindow(result, retention_window);
                return opened;
            }
            Ops.deinitRetentionWindow(&retention_window);
            return null;
        }

        fn openFromManifest(
            context: anytype,
            allocator: std.mem.Allocator,
            manifest: *const Ops.ManifestType,
            filter_direction: ?Ops.DirectionType,
            filter_node_id: ?Ops.NodeIdType,
        ) !?Ops.ResultType {
            const meta = try Ops.readCurrentMeta(context);
            const manifest_edges = Ops.manifestTotalEdges(manifest);
            const physical_edges = try Ops.visiblePlusTombstoneEdges(context, meta);
            const coverage: Ops.CoverageType = if (manifest_edges == physical_edges)
                .full
            else coverage: {
                if (try Ops.manifestCoversVisibleEdges(context, meta, manifest_edges) and
                    try Ops.metaSummaryCurrent(context, meta))
                {
                    break :coverage .visible_full;
                }
                const indexed_edges = Ops.indexedEdgeCount(meta);
                if (indexed_edges > physical_edges) return null;
                if (manifest_edges != physical_edges - indexed_edges) return null;
                if (!try Ops.baseHeadersMatchMeta(context, meta)) return null;
                break :coverage .delta;
            };

            const filtered = coverage != .visible_full and
                filter_direction != null and
                filter_node_id != null and
                Ops.manifestRangesTrusted(manifest);
            return Ops.openSegments(
                context,
                allocator,
                manifest,
                coverage,
                filter_direction,
                filter_node_id,
                filtered,
            );
        }
    };
}

const TestDirection = enum {
    forward,
    reverse,
};

const TestNodeId = struct {
    value: u64,
};

const TestCoverage = enum {
    full,
    visible_full,
    delta,
};

const TestMeta = struct {
    indexed_edges: u64 = 0,
};

const TestManifest = struct {
    total_edges: u64 = 0,
    ranges_trusted: bool = false,
};

const TestRegistry = struct {};

const TestResult = struct {
    coverage: TestCoverage,
    filtered: bool,
    direction: ?TestDirection,
    node_id: ?TestNodeId,
    retention_attached: bool = false,
};

const TestPhase = enum {
    read_current_manifest,
    acquire_retention,
    read_retained_manifest,
    read_meta,
    visible_plus_tombstone,
    covers_visible,
    summary_current,
    base_headers,
    open_segments,
    deinit_retention,
    deinit_manifest,
};

const TestContext = struct {
    phases: [48]TestPhase = undefined,
    phase_count: usize = 0,
    fail_at: ?TestPhase = null,
    current_missing: bool = false,
    retained_manifest_missing: bool = false,
    retained_path: ?[]const u8 = "manifest-epoch",
    manifest: TestManifest = .{},
    meta: TestMeta = .{},
    physical_edges: u64 = 0,
    covers_visible: bool = false,
    summary_current: bool = false,
    base_headers_match: bool = true,
    open_returns_result: bool = true,
    manifest_deinit_count: usize = 0,
    retention_deinit_count: usize = 0,
    observed_coverage: ?TestCoverage = null,
    observed_filtered: bool = false,

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

const TestRetentionWindow = struct {
    context: *TestContext,
    manifest_path: ?[]const u8,
    active: bool = true,
};

const TestOps = struct {
    pub const DirectionType = TestDirection;
    pub const NodeIdType = TestNodeId;
    pub const CoverageType = TestCoverage;
    pub const ManifestType = TestManifest;
    pub const RegistryType = TestRegistry;
    pub const ResultType = TestResult;

    pub fn readCurrentManifest(context: *TestContext, _: std.mem.Allocator) !TestManifest {
        try context.record(.read_current_manifest);
        if (context.current_missing) return error.FileNotFound;
        return context.manifest;
    }

    pub fn readManifestAtPath(context: *TestContext, _: std.mem.Allocator, manifest_path: []const u8) !TestManifest {
        try context.record(.read_retained_manifest);
        try std.testing.expectEqualStrings(context.retained_path.?, manifest_path);
        if (context.retained_manifest_missing) return error.FileNotFound;
        return context.manifest;
    }

    pub fn deinitManifest(context: *TestContext, _: std.mem.Allocator, _: *TestManifest) void {
        context.recordCleanup(.deinit_manifest);
        context.manifest_deinit_count += 1;
    }

    pub fn acquireRetentionWindow(context: *TestContext, _: *TestRegistry) !TestRetentionWindow {
        try context.record(.acquire_retention);
        return .{
            .context = context,
            .manifest_path = context.retained_path,
        };
    }

    pub fn retentionManifestPath(window: *const TestRetentionWindow) ?[]const u8 {
        return window.manifest_path;
    }

    pub fn deinitRetentionWindow(window: *TestRetentionWindow) void {
        if (!window.active) return;
        window.context.recordCleanup(.deinit_retention);
        window.context.retention_deinit_count += 1;
        window.active = false;
    }

    pub fn attachRetentionWindow(result: *TestResult, window: TestRetentionWindow) void {
        std.debug.assert(window.active);
        result.retention_attached = true;
    }

    pub fn readCurrentMeta(context: *TestContext) !TestMeta {
        try context.record(.read_meta);
        return context.meta;
    }

    pub fn manifestTotalEdges(manifest: *const TestManifest) u64 {
        return manifest.total_edges;
    }

    pub fn visiblePlusTombstoneEdges(context: *TestContext, _: TestMeta) !u64 {
        try context.record(.visible_plus_tombstone);
        return context.physical_edges;
    }

    pub fn manifestCoversVisibleEdges(context: *TestContext, _: TestMeta, _: u64) !bool {
        try context.record(.covers_visible);
        return context.covers_visible;
    }

    pub fn metaSummaryCurrent(context: *TestContext, _: TestMeta) !bool {
        try context.record(.summary_current);
        return context.summary_current;
    }

    pub fn indexedEdgeCount(meta: TestMeta) u64 {
        return meta.indexed_edges;
    }

    pub fn baseHeadersMatchMeta(context: *TestContext, _: TestMeta) !bool {
        try context.record(.base_headers);
        return context.base_headers_match;
    }

    pub fn manifestRangesTrusted(manifest: *const TestManifest) bool {
        return manifest.ranges_trusted;
    }

    pub fn openSegments(
        context: *TestContext,
        _: std.mem.Allocator,
        _: *const TestManifest,
        coverage: TestCoverage,
        filter_direction: ?TestDirection,
        filter_node_id: ?TestNodeId,
        filtered: bool,
    ) !?TestResult {
        try context.record(.open_segments);
        context.observed_coverage = coverage;
        context.observed_filtered = filtered;
        if (!context.open_returns_result) return null;
        return .{
            .coverage = coverage,
            .filtered = filtered,
            .direction = filter_direction,
            .node_id = filter_node_id,
        };
    }
};

const test_opening = EdgeSegmentQueryOpening(TestOps);

test "edge segment query opening maps a missing current manifest to no result" {
    var context = TestContext{ .current_missing = true };
    const opened = try test_opening.openCurrent(&context, std.testing.allocator, null, null);
    try std.testing.expectEqual(null, opened);
    try std.testing.expectEqual(@as(usize, 0), context.manifest_deinit_count);
    try std.testing.expectEqualSlices(TestPhase, &.{.read_current_manifest}, context.recorded());

    var failed = TestContext{ .fail_at = .read_current_manifest };
    try std.testing.expectError(
        error.InjectedFailure,
        test_opening.openCurrent(&failed, std.testing.allocator, null, null),
    );

    var failed_after_manifest = TestContext{
        .manifest = .{ .total_edges = 1 },
        .physical_edges = 1,
        .fail_at = .read_meta,
    };
    try std.testing.expectError(
        error.InjectedFailure,
        test_opening.openCurrent(&failed_after_manifest, std.testing.allocator, null, null),
    );
    try std.testing.expectEqual(@as(usize, 1), failed_after_manifest.manifest_deinit_count);
}

test "edge segment query opening classifies full coverage and trusted filters" {
    var context = TestContext{
        .manifest = .{ .total_edges = 10, .ranges_trusted = true },
        .physical_edges = 10,
    };
    const node = TestNodeId{ .value = 7 };
    const opened = (try test_opening.openCurrent(&context, std.testing.allocator, .forward, node)).?;
    try std.testing.expectEqual(TestCoverage.full, opened.coverage);
    try std.testing.expect(opened.filtered);
    try std.testing.expectEqual(TestDirection.forward, opened.direction.?);
    try std.testing.expectEqual(node, opened.node_id.?);
    try std.testing.expectEqual(@as(usize, 1), context.manifest_deinit_count);
    try std.testing.expectEqualSlices(TestPhase, &.{
        .read_current_manifest,
        .read_meta,
        .visible_plus_tombstone,
        .open_segments,
        .deinit_manifest,
    }, context.recorded());

    var untrusted = TestContext{
        .manifest = .{ .total_edges = 10, .ranges_trusted = false },
        .physical_edges = 10,
    };
    const untrusted_opened = (try test_opening.openCurrent(&untrusted, std.testing.allocator, .forward, node)).?;
    try std.testing.expect(!untrusted_opened.filtered);

    var missing_direction = TestContext{
        .manifest = .{ .total_edges = 10, .ranges_trusted = true },
        .physical_edges = 10,
    };
    const missing_direction_opened = (try test_opening.openCurrent(&missing_direction, std.testing.allocator, null, node)).?;
    try std.testing.expect(!missing_direction_opened.filtered);

    var missing_node = TestContext{
        .manifest = .{ .total_edges = 10, .ranges_trusted = true },
        .physical_edges = 10,
    };
    const missing_node_opened = (try test_opening.openCurrent(&missing_node, std.testing.allocator, .reverse, null)).?;
    try std.testing.expect(!missing_node_opened.filtered);
}

test "edge segment query opening keeps visible-full opens unfiltered" {
    var context = TestContext{
        .manifest = .{ .total_edges = 8, .ranges_trusted = true },
        .physical_edges = 10,
        .covers_visible = true,
        .summary_current = true,
    };
    const opened = (try test_opening.openCurrent(
        &context,
        std.testing.allocator,
        .reverse,
        .{ .value = 9 },
    )).?;
    try std.testing.expectEqual(TestCoverage.visible_full, opened.coverage);
    try std.testing.expect(!opened.filtered);
    try std.testing.expectEqualSlices(TestPhase, &.{
        .read_current_manifest,
        .read_meta,
        .visible_plus_tombstone,
        .covers_visible,
        .summary_current,
        .open_segments,
        .deinit_manifest,
    }, context.recorded());
}

test "edge segment query opening admits only a matching delta overlay" {
    var context = TestContext{
        .manifest = .{ .total_edges = 3, .ranges_trusted = true },
        .meta = .{ .indexed_edges = 7 },
        .physical_edges = 10,
        .base_headers_match = true,
    };
    const opened = (try test_opening.openCurrent(
        &context,
        std.testing.allocator,
        .forward,
        .{ .value = 4 },
    )).?;
    try std.testing.expectEqual(TestCoverage.delta, opened.coverage);
    try std.testing.expect(opened.filtered);
    try std.testing.expectEqualSlices(TestPhase, &.{
        .read_current_manifest,
        .read_meta,
        .visible_plus_tombstone,
        .covers_visible,
        .base_headers,
        .open_segments,
        .deinit_manifest,
    }, context.recorded());
}

test "edge segment query opening rejects stale delta shapes before opening data" {
    var indexed_ahead = TestContext{
        .manifest = .{ .total_edges = 1 },
        .meta = .{ .indexed_edges = 11 },
        .physical_edges = 10,
    };
    try std.testing.expectEqual(
        null,
        try test_opening.openCurrent(&indexed_ahead, std.testing.allocator, null, null),
    );

    var mismatched_count = TestContext{
        .manifest = .{ .total_edges = 2 },
        .meta = .{ .indexed_edges = 7 },
        .physical_edges = 10,
    };
    try std.testing.expectEqual(
        null,
        try test_opening.openCurrent(&mismatched_count, std.testing.allocator, null, null),
    );

    var stale_base = TestContext{
        .manifest = .{ .total_edges = 3 },
        .meta = .{ .indexed_edges = 7 },
        .physical_edges = 10,
        .base_headers_match = false,
    };
    try std.testing.expectEqual(
        null,
        try test_opening.openCurrent(&stale_base, std.testing.allocator, null, null),
    );
    try std.testing.expect(indexed_ahead.observed_coverage == null);
    try std.testing.expect(mismatched_count.observed_coverage == null);
    try std.testing.expect(stale_base.observed_coverage == null);
}

test "edge segment query opening releases an empty retained acquisition" {
    var context = TestContext{ .retained_path = null };
    var registry = TestRegistry{};
    const opened = try test_opening.openRetained(&context, std.testing.allocator, &registry, null, null);
    try std.testing.expectEqual(null, opened);
    try std.testing.expectEqual(@as(usize, 1), context.retention_deinit_count);
    try std.testing.expectEqualSlices(TestPhase, &.{ .acquire_retention, .deinit_retention }, context.recorded());
}

test "edge segment query opening maps a vanished retained epoch to invalid" {
    var context = TestContext{ .retained_manifest_missing = true };
    var registry = TestRegistry{};
    try std.testing.expectError(
        error.InvalidRecord,
        test_opening.openRetained(&context, std.testing.allocator, &registry, null, null),
    );
    try std.testing.expectEqual(@as(usize, 1), context.retention_deinit_count);
    try std.testing.expectEqual(@as(usize, 0), context.manifest_deinit_count);
}

test "edge segment query opening transfers retained ownership only on success" {
    var no_result = TestContext{
        .manifest = .{ .total_edges = 4 },
        .physical_edges = 4,
        .open_returns_result = false,
    };
    var registry = TestRegistry{};
    try std.testing.expectEqual(
        null,
        try test_opening.openRetained(&no_result, std.testing.allocator, &registry, null, null),
    );
    try std.testing.expectEqual(@as(usize, 1), no_result.retention_deinit_count);
    try std.testing.expectEqual(@as(usize, 1), no_result.manifest_deinit_count);

    var success = TestContext{
        .manifest = .{ .total_edges = 4 },
        .physical_edges = 4,
    };
    const opened = (try test_opening.openRetained(&success, std.testing.allocator, &registry, null, null)).?;
    try std.testing.expect(opened.retention_attached);
    try std.testing.expectEqual(@as(usize, 0), success.retention_deinit_count);
    try std.testing.expectEqual(@as(usize, 1), success.manifest_deinit_count);

    var failed = TestContext{
        .manifest = .{ .total_edges = 4 },
        .physical_edges = 4,
        .fail_at = .open_segments,
    };
    try std.testing.expectError(
        error.InjectedFailure,
        test_opening.openRetained(&failed, std.testing.allocator, &registry, null, null),
    );
    try std.testing.expectEqual(@as(usize, 1), failed.retention_deinit_count);
    try std.testing.expectEqual(@as(usize, 1), failed.manifest_deinit_count);
}
