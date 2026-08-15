const std = @import("std");

/// Owns the public resource lifetime for opened immutable edge segments,
/// virtual manifest edges, query-direction specialization, and transferred
/// retention windows. Manifest selection and Store query admission stay in
/// their existing control-plane owners.
pub fn PublishedEdgeSegmentResources(comptime Ops: type) type {
    const core = Ops.dep_core;
    const segment_mod = Ops.dep_segment_mod;
    const support = Ops.dep_support;
    const EdgeSegmentRegisteredRetentionWindow = Ops.dep_EdgeSegmentRegisteredRetentionWindow;

    return struct {
        pub const PublishedEdgeSegments = struct {
            allocator: std.mem.Allocator,
            segments: std.ArrayList(segment_mod.ImmutableAdjacencySegment) = .empty,
            virtual_edges: std.ArrayList(segment_mod.EdgeRecord) = .empty,
            query_direction: ?segment_mod.Direction = null,

            pub fn init(allocator: std.mem.Allocator) PublishedEdgeSegments {
                return .{ .allocator = allocator };
            }

            pub fn openFromManifest(allocator: std.mem.Allocator, io: std.Io, entries: []const support.OwnedEdgeSegmentManifestEntry) !PublishedEdgeSegments {
                var out = PublishedEdgeSegments.init(allocator);
                errdefer out.deinit();
                try out.openEntries(io, entries);
                return out;
            }

            pub fn openEntries(self: *PublishedEdgeSegments, io: std.Io, entries: []const support.OwnedEdgeSegmentManifestEntry) !void {
                try self.segments.ensureTotalCapacity(self.allocator, self.segments.items.len + entries.len);
                for (entries) |entry| {
                    try self.openEntry(io, entry);
                }
            }

            pub fn openTrustedEntriesForQuery(self: *PublishedEdgeSegments, io: std.Io, entries: []const support.OwnedEdgeSegmentManifestEntry) !void {
                try self.segments.ensureTotalCapacity(self.allocator, self.segments.items.len + entries.len);
                for (entries) |entry| {
                    try self.openTrustedEntryForQuery(io, entry);
                }
            }

            /// Validate every physical entry while keeping at most one segment
            /// open. Full-store validation needs header/count admission, not a
            /// query container retaining every immutable reader until teardown.
            pub fn validateTrustedEntriesBounded(self: *PublishedEdgeSegments, io: std.Io, entries: []const support.OwnedEdgeSegmentManifestEntry) !void {
                for (entries) |entry| {
                    if (support.edgeSegmentManifestEntryIsVirtual(entry)) {
                        try support.edgeSegmentManifestValidateVirtualEntry(entry);
                        continue;
                    }
                    var segment = try segment_mod.ImmutableAdjacencySegment.openTrustedForQuery(self.allocator, io, entry.path, entry.edge_count);
                    segment.deinit();
                }
            }

            /// Stream every manifest edge while retaining at most one physical
            /// segment reader. Full-store scans do not need a query container
            /// whose lifetime spans the complete manifest.
            pub fn scanTrustedEntriesBounded(
                self: *PublishedEdgeSegments,
                io: std.Io,
                entries: []const support.OwnedEdgeSegmentManifestEntry,
                direction: segment_mod.Direction,
                context: anytype,
                comptime callback: fn (@TypeOf(context), segment_mod.EdgeRecord) anyerror!void,
            ) !void {
                for (entries) |entry| {
                    if (support.edgeSegmentManifestEntryIsVirtual(entry)) {
                        var index: u64 = 0;
                        while (index < entry.edge_count) : (index += 1) {
                            try callback(context, try support.edgeSegmentManifestVirtualRunEdgeAt(entry, index));
                        }
                        continue;
                    }
                    var segment = try segment_mod.ImmutableAdjacencySegment.openTrustedDirectionForQuery(
                        self.allocator,
                        io,
                        entry.path,
                        direction,
                        entry.edge_count,
                    );
                    defer segment.deinit();
                    var iterator = try segment.edgeIterator(direction);
                    while (try iterator.next()) |edge| try callback(context, edge);
                }
            }

            pub fn openEntry(self: *PublishedEdgeSegments, io: std.Io, entry: support.OwnedEdgeSegmentManifestEntry) !void {
                if (support.edgeSegmentManifestEntryIsVirtual(entry)) {
                    try support.appendEdgeSegmentManifestVirtualEdges(self.allocator, &self.virtual_edges, entry);
                    return;
                }
                const segment = try segment_mod.ImmutableAdjacencySegment.open(self.allocator, io, entry.path);
                errdefer {
                    var cleanup = segment;
                    cleanup.deinit();
                }
                if (try segment.edgeCount() != entry.edge_count) return error.InvalidRecord;
                self.segments.appendAssumeCapacity(segment);
            }

            pub fn openTrustedEntryForQuery(self: *PublishedEdgeSegments, io: std.Io, entry: support.OwnedEdgeSegmentManifestEntry) !void {
                if (support.edgeSegmentManifestEntryIsVirtual(entry)) {
                    try support.appendEdgeSegmentManifestVirtualEdges(self.allocator, &self.virtual_edges, entry);
                    return;
                }
                const segment = try segment_mod.ImmutableAdjacencySegment.openTrustedForQuery(self.allocator, io, entry.path, entry.edge_count);
                errdefer {
                    var cleanup = segment;
                    cleanup.deinit();
                }
                self.segments.appendAssumeCapacity(segment);
            }

            pub fn openTrustedEntryDirectionForQuery(
                self: *PublishedEdgeSegments,
                io: std.Io,
                entry: support.OwnedEdgeSegmentManifestEntry,
                direction: segment_mod.Direction,
            ) !void {
                if (self.query_direction) |query_direction| {
                    if (query_direction != direction) return error.InvalidRecord;
                } else {
                    self.query_direction = direction;
                }
                if (support.edgeSegmentManifestEntryIsVirtual(entry)) {
                    try support.appendEdgeSegmentManifestVirtualEdges(self.allocator, &self.virtual_edges, entry);
                    return;
                }
                const segment = try segment_mod.ImmutableAdjacencySegment.openTrustedDirectionForQuery(self.allocator, io, entry.path, direction, entry.edge_count);
                errdefer {
                    var cleanup = segment;
                    cleanup.deinit();
                }
                self.segments.appendAssumeCapacity(segment);
            }

            pub fn deinit(self: *PublishedEdgeSegments) void {
                for (self.segments.items) |*segment| segment.deinit();
                self.segments.deinit(self.allocator);
                self.virtual_edges.deinit(self.allocator);
            }

            pub fn edgeDigest(self: *PublishedEdgeSegments) !u64 {
                if (self.query_direction != null) return error.InvalidRecord;
                var digest: u64 = 0;
                for (self.segments.items) |segment| {
                    digest ^= try segment.edgeDigest();
                }
                for (self.virtual_edges.items) |edge| {
                    digest ^= support.edgeRecordDigest(.{
                        .src = edge.src.toInt(),
                        .dst = edge.dst.toInt(),
                        .edge_id = edge.edge_id.toInt(),
                        .rel = @intFromEnum(edge.rel),
                    });
                }
                return digest;
            }

            pub fn forEachNeighbor(
                self: *PublishedEdgeSegments,
                direction: segment_mod.Direction,
                node_id: core.NodeId,
                rel_filter: ?core.RelKind,
                max_edges: usize,
                context: anytype,
                comptime callback: fn (@TypeOf(context), segment_mod.EdgeRecord) anyerror!bool,
            ) !bool {
                if (self.query_direction) |query_direction| {
                    if (query_direction != direction) return error.InvalidRecord;
                }
                return support.edge_segment_merge.forEachNeighbor(
                    self.allocator,
                    &self.segments,
                    self.virtual_edges.items,
                    direction,
                    node_id,
                    rel_filter,
                    max_edges,
                    context,
                    callback,
                );
            }
        };

        pub const PublishedEdgeSegmentsCoverage = enum {
            full,
            visible_full,
            delta,
        };

        pub const PublishedEdgeSegmentsForQuery = struct {
            segments: PublishedEdgeSegments,
            coverage: PublishedEdgeSegmentsCoverage,
            retention_window: ?EdgeSegmentRegisteredRetentionWindow = null,

            pub fn deinit(self: *PublishedEdgeSegmentsForQuery) void {
                self.segments.deinit();
                if (self.retention_window) |*retention_window| retention_window.deinit();
                self.retention_window = null;
            }
        };
    };
}

const TestCore = struct {
    pub const NodeId = TestId;
    pub const RelKind = TestRel;
};

const TestId = struct {
    value: u64,
    pub fn toInt(self: @This()) u64 {
        return self.value;
    }
};

const TestRel = enum(u16) { related = 1 };

var test_open_cleanup_count: usize = 0;
var test_open_active_count: usize = 0;
var test_open_peak_count: usize = 0;

const TestSegment = struct {
    pub const Direction = enum { forward, reverse };
    pub const EdgeRecord = struct {
        src: TestId,
        dst: TestId,
        edge_id: TestId,
        rel: TestRel,
    };
    pub const ImmutableAdjacencySegment = struct {
        cleanup_count: *usize,
        count: u64 = 0,
        digest: u64 = 0,
        tracks_open: bool = false,

        pub fn open(_: std.mem.Allocator, _: std.Io, _: []const u8) !@This() {
            return .{ .cleanup_count = &test_open_cleanup_count };
        }
        pub fn openTrustedForQuery(_: std.mem.Allocator, _: std.Io, _: []const u8, count: u64) !@This() {
            test_open_active_count += 1;
            test_open_peak_count = @max(test_open_peak_count, test_open_active_count);
            return .{ .cleanup_count = &test_open_cleanup_count, .count = count, .tracks_open = true };
        }
        pub fn openTrustedDirectionForQuery(_: std.mem.Allocator, _: std.Io, _: []const u8, _: Direction, count: u64) !@This() {
            test_open_active_count += 1;
            test_open_peak_count = @max(test_open_peak_count, test_open_active_count);
            return .{ .cleanup_count = &test_open_cleanup_count, .count = count, .tracks_open = true };
        }
        pub fn deinit(self: *@This()) void {
            self.cleanup_count.* += 1;
            if (self.tracks_open) {
                test_open_active_count -= 1;
                self.tracks_open = false;
            }
        }
        pub fn edgeCount(self: @This()) !u64 {
            return self.count;
        }
        pub fn edgeDigest(self: @This()) !u64 {
            return self.digest;
        }

        pub const EdgeIterator = struct {
            remaining: u64,

            pub fn next(self: *@This()) !?EdgeRecord {
                if (self.remaining == 0) return null;
                const value = self.remaining;
                self.remaining -= 1;
                return .{
                    .src = .{ .value = 1 },
                    .dst = .{ .value = value + 1 },
                    .edge_id = .{ .value = value },
                    .rel = .related,
                };
            }
        };

        pub fn edgeIterator(self: *@This(), _: Direction) !EdgeIterator {
            return .{ .remaining = self.count };
        }
    };
};

const TestRetention = struct {
    order: *usize,
    pub fn deinit(self: *@This()) void {
        self.order.* = if (self.order.* == 1) 2 else 99;
    }
};

const TestSupport = struct {
    pub const OwnedEdgeSegmentManifestEntry = struct {
        path: []const u8 = "virtual",
        edge_count: u64 = 0,
        virtual: bool = true,
        edge: TestSegment.EdgeRecord = .{
            .src = .{ .value = 1 },
            .dst = .{ .value = 2 },
            .edge_id = .{ .value = 3 },
            .rel = .related,
        },
    };
    pub fn edgeSegmentManifestEntryIsVirtual(entry: OwnedEdgeSegmentManifestEntry) bool {
        return entry.virtual;
    }
    pub fn appendEdgeSegmentManifestVirtualEdges(
        allocator: std.mem.Allocator,
        edges: *std.ArrayList(TestSegment.EdgeRecord),
        entry: OwnedEdgeSegmentManifestEntry,
    ) !void {
        try edges.append(allocator, entry.edge);
    }
    pub fn edgeSegmentManifestVirtualRunEdgeAt(entry: OwnedEdgeSegmentManifestEntry, index: u64) !TestSegment.EdgeRecord {
        if (index >= entry.edge_count) return error.InvalidRecord;
        return entry.edge;
    }
    pub fn edgeSegmentManifestValidateVirtualEntry(entry: OwnedEdgeSegmentManifestEntry) !void {
        if (!entry.virtual) return error.InvalidRecord;
    }
    pub fn edgeRecordDigest(record: anytype) u64 {
        return record.src ^ record.dst ^ record.edge_id ^ record.rel;
    }
    pub const edge_segment_merge = struct {
        pub fn forEachNeighbor(
            _: std.mem.Allocator,
            _: *std.ArrayList(TestSegment.ImmutableAdjacencySegment),
            virtual_edges: []const TestSegment.EdgeRecord,
            _: TestSegment.Direction,
            _: TestCore.NodeId,
            _: ?TestCore.RelKind,
            max_edges: usize,
            context: anytype,
            comptime callback: fn (@TypeOf(context), TestSegment.EdgeRecord) anyerror!bool,
        ) !bool {
            for (virtual_edges[0..@min(virtual_edges.len, max_edges)]) |edge| {
                if (!try callback(context, edge)) return false;
            }
            return true;
        }
    };
};

const TestOps = struct {
    pub const dep_core = TestCore;
    pub const dep_segment_mod = TestSegment;
    pub const dep_support = TestSupport;
    pub const dep_EdgeSegmentRegisteredRetentionWindow = TestRetention;
};

const TestResources = PublishedEdgeSegmentResources(TestOps);

test "published edge segments reject mixed query directions" {
    var segments = TestResources.PublishedEdgeSegments.init(std.testing.allocator);
    defer segments.deinit();
    const entry = TestSupport.OwnedEdgeSegmentManifestEntry{};
    try segments.openTrustedEntryDirectionForQuery(std.testing.io, entry, .forward);
    try std.testing.expectError(
        error.InvalidRecord,
        segments.openTrustedEntryDirectionForQuery(std.testing.io, entry, .reverse),
    );
}

test "published edge segment digest rejects direction limited views" {
    var segments = TestResources.PublishedEdgeSegments.init(std.testing.allocator);
    defer segments.deinit();
    segments.query_direction = .forward;
    try std.testing.expectError(error.InvalidRecord, segments.edgeDigest());
}

test "published edge segments deinitialize physical and virtual resources" {
    var cleanup_count: usize = 0;
    var segments = TestResources.PublishedEdgeSegments.init(std.testing.allocator);
    try segments.segments.append(std.testing.allocator, .{ .cleanup_count = &cleanup_count });
    try segments.virtual_edges.append(std.testing.allocator, (TestSupport.OwnedEdgeSegmentManifestEntry{}).edge);
    segments.deinit();
    try std.testing.expectEqual(@as(usize, 1), cleanup_count);
}

test "published edge segment validation releases each physical entry immediately" {
    test_open_cleanup_count = 0;
    test_open_active_count = 0;
    test_open_peak_count = 0;
    var segments = TestResources.PublishedEdgeSegments.init(std.testing.allocator);
    defer segments.deinit();
    const entries = [_]TestSupport.OwnedEdgeSegmentManifestEntry{
        .{ .path = "one", .edge_count = 1, .virtual = false },
        .{ .path = "two", .edge_count = 2, .virtual = false },
        .{ .path = "three", .edge_count = 3, .virtual = false },
    };
    try segments.validateTrustedEntriesBounded(std.testing.io, &entries);
    try std.testing.expectEqual(@as(usize, 3), test_open_cleanup_count);
    try std.testing.expectEqual(@as(usize, 0), test_open_active_count);
    try std.testing.expectEqual(@as(usize, 1), test_open_peak_count);
    try std.testing.expectEqual(@as(usize, 0), segments.segments.items.len);
}

test "published edge segment full scan releases each physical entry immediately" {
    test_open_cleanup_count = 0;
    test_open_active_count = 0;
    test_open_peak_count = 0;
    var segments = TestResources.PublishedEdgeSegments.init(std.testing.allocator);
    defer segments.deinit();
    const entries = [_]TestSupport.OwnedEdgeSegmentManifestEntry{
        .{ .path = "one", .edge_count = 1, .virtual = false },
        .{ .path = "two", .edge_count = 2, .virtual = false },
        .{ .path = "three", .edge_count = 3, .virtual = false },
    };
    const ScanContext = struct {
        count: usize = 0,

        fn visit(context: *@This(), _: TestSegment.EdgeRecord) !void {
            context.count += 1;
        }
    };
    var context = ScanContext{};
    try segments.scanTrustedEntriesBounded(std.testing.io, &entries, .forward, &context, ScanContext.visit);
    try std.testing.expectEqual(@as(usize, 6), context.count);
    try std.testing.expectEqual(@as(usize, 3), test_open_cleanup_count);
    try std.testing.expectEqual(@as(usize, 0), test_open_active_count);
    try std.testing.expectEqual(@as(usize, 1), test_open_peak_count);
    try std.testing.expectEqual(@as(usize, 0), segments.segments.items.len);
}

test "published edge segment query teardown releases retention after segments" {
    var order: usize = 0;
    var query = TestResources.PublishedEdgeSegmentsForQuery{
        .segments = TestResources.PublishedEdgeSegments.init(std.testing.allocator),
        .coverage = .delta,
        .retention_window = .{ .order = &order },
    };
    try query.segments.segments.append(std.testing.allocator, .{ .cleanup_count = &order });
    query.deinit();
    try std.testing.expectEqual(@as(usize, 2), order);
    try std.testing.expect(query.retention_window == null);
}
