const std = @import("std");

/// Owns the ordered data-plane merge shared by edge-segment compaction,
/// export, repair, and visible-edge scans. Concrete CSR/mmap iterators, base
/// index readers, tombstone views, and edge representation stay in the stable
/// storage facade behind `Ops`.
pub fn EdgeSegmentMerge(comptime Ops: type) type {
    return struct {
        const Edge = Ops.EdgeType;
        const Direction = Ops.DirectionType;

        pub const Internal = struct {
            pub const HeapEntry = struct {
                iterator_index: ?usize,
                edge: Edge,
            };

            pub const HeapContext = struct {
                direction: Direction,
            };

            pub fn compareHeapEntry(context: HeapContext, lhs: HeapEntry, rhs: HeapEntry) std.math.Order {
                if (Ops.edgeLessThan(context.direction, lhs.edge, rhs.edge)) return .lt;
                if (Ops.edgeLessThan(context.direction, rhs.edge, lhs.edge)) return .gt;
                return std.math.order(optionalHeapIndex(lhs.iterator_index), optionalHeapIndex(rhs.iterator_index));
            }

            fn optionalHeapIndex(index: ?usize) usize {
                return index orelse std.math.maxInt(usize);
            }
        };

        pub fn forEachNeighbor(
            allocator: std.mem.Allocator,
            segments: *Ops.SegmentCollectionType,
            virtual_edges: []const Edge,
            direction: Direction,
            node_id: Ops.NodeIdType,
            rel_filter: ?Ops.RelationType,
            max_edges: usize,
            context: anytype,
            comptime callback: fn (@TypeOf(context), Edge) anyerror!bool,
        ) !bool {
            var iterators = std.ArrayList(Ops.NeighborIteratorType).empty;
            defer iterators.deinit(allocator);

            const segment_count = Ops.segmentCount(segments);
            try iterators.ensureTotalCapacity(allocator, segment_count);
            var queue = std.PriorityQueue(Internal.HeapEntry, Internal.HeapContext, Internal.compareHeapEntry).initContext(.{ .direction = direction });
            defer queue.deinit(allocator);
            try queue.ensureTotalCapacity(allocator, segment_count + virtual_edges.len);

            for (0..segment_count) |segment_index| {
                var iterator = (try Ops.neighborIterator(segments, segment_index, direction, node_id, rel_filter)) orelse continue;
                if (try Ops.nextNeighborEdge(&iterator)) |edge| {
                    const iterator_index = iterators.items.len;
                    iterators.appendAssumeCapacity(iterator);
                    try queue.push(allocator, .{
                        .iterator_index = iterator_index,
                        .edge = edge,
                    });
                }
            }
            for (virtual_edges) |edge| {
                if (!Ops.virtualNeighborMatches(edge, direction, node_id, rel_filter)) continue;
                try queue.push(allocator, .{
                    .iterator_index = null,
                    .edge = edge,
                });
            }

            var emitted: usize = 0;
            while (queue.pop()) |entry| {
                if (emitted >= max_edges) return error.BudgetExceeded;
                emitted += 1;
                if (try callback(context, entry.edge)) return true;
                if (entry.iterator_index) |iterator_index| {
                    if (try Ops.nextNeighborEdge(&iterators.items[iterator_index])) |next_edge| {
                        try queue.push(allocator, .{
                            .iterator_index = iterator_index,
                            .edge = next_edge,
                        });
                    }
                }
            }
            return false;
        }

        pub const SegmentMergeStream = struct {
            allocator: std.mem.Allocator,
            segments: *Ops.SegmentCollectionType,
            virtual_edges: []const Edge = &.{},
            direction: Direction,
            tombstones: ?*Ops.TombstoneViewType = null,
            iterators: std.ArrayList(Ops.SegmentIteratorType) = .empty,
            queue: std.PriorityQueue(Internal.HeapEntry, Internal.HeapContext, Internal.compareHeapEntry),

            pub fn init(
                allocator: std.mem.Allocator,
                segments: *Ops.SegmentCollectionType,
                direction: Direction,
            ) SegmentMergeStream {
                return .{
                    .allocator = allocator,
                    .segments = segments,
                    .direction = direction,
                    .queue = std.PriorityQueue(Internal.HeapEntry, Internal.HeapContext, Internal.compareHeapEntry).initContext(.{ .direction = direction }),
                };
            }

            pub fn initFiltered(
                allocator: std.mem.Allocator,
                segments: *Ops.SegmentCollectionType,
                direction: Direction,
                tombstones: ?*Ops.TombstoneViewType,
            ) SegmentMergeStream {
                var stream = SegmentMergeStream.init(allocator, segments, direction);
                stream.tombstones = tombstones;
                return stream;
            }

            pub fn initWithVirtual(
                allocator: std.mem.Allocator,
                segments: *Ops.SegmentCollectionType,
                virtual_edges: []const Edge,
                direction: Direction,
            ) SegmentMergeStream {
                var stream = SegmentMergeStream.init(allocator, segments, direction);
                stream.virtual_edges = virtual_edges;
                return stream;
            }

            pub fn initWithVirtualFiltered(
                allocator: std.mem.Allocator,
                segments: *Ops.SegmentCollectionType,
                virtual_edges: []const Edge,
                direction: Direction,
                tombstones: ?*Ops.TombstoneViewType,
            ) SegmentMergeStream {
                var stream = SegmentMergeStream.initWithVirtual(allocator, segments, virtual_edges, direction);
                stream.tombstones = tombstones;
                return stream;
            }

            pub fn deinit(self: *SegmentMergeStream) void {
                self.queue.deinit(self.allocator);
                self.iterators.deinit(self.allocator);
            }

            pub fn reset(self: *SegmentMergeStream) !void {
                self.queue.clearRetainingCapacity();
                self.iterators.clearRetainingCapacity();

                const segment_count = Ops.segmentCount(self.segments);
                try self.iterators.ensureTotalCapacity(self.allocator, segment_count);
                try self.queue.ensureTotalCapacity(self.allocator, segment_count + self.virtual_edges.len);
                for (0..segment_count) |segment_index| {
                    var iterator = try Ops.segmentIterator(self.segments, segment_index, self.direction);
                    if (try Ops.nextSegmentEdge(&iterator)) |edge| {
                        const iterator_index = self.iterators.items.len;
                        self.iterators.appendAssumeCapacity(iterator);
                        try self.queue.push(self.allocator, .{
                            .iterator_index = iterator_index,
                            .edge = edge,
                        });
                    }
                }
                for (self.virtual_edges) |edge| {
                    try self.queue.push(self.allocator, .{
                        .iterator_index = null,
                        .edge = edge,
                    });
                }
            }

            pub fn next(self: *SegmentMergeStream) !?Edge {
                while (true) {
                    const entry = self.queue.pop() orelse return null;
                    if (entry.iterator_index) |iterator_index| {
                        if (try Ops.nextSegmentEdge(&self.iterators.items[iterator_index])) |edge| {
                            try self.queue.push(self.allocator, .{
                                .iterator_index = iterator_index,
                                .edge = edge,
                            });
                        }
                    }
                    if (self.tombstones) |tombstones| {
                        if (try Ops.isTombstoned(tombstones, entry.edge)) continue;
                    }
                    return entry.edge;
                }
            }
        };

        pub const BaseAndSegmentMergeStream = struct {
            base: *Ops.BaseReaderType,
            direction: Direction,
            tombstones: ?*Ops.TombstoneViewType = null,
            segment_stream: SegmentMergeStream,
            base_pos: u64 = 0,
            next_base: ?Edge = null,
            next_segment: ?Edge = null,

            pub fn init(
                allocator: std.mem.Allocator,
                base: *Ops.BaseReaderType,
                segments: *Ops.SegmentCollectionType,
                direction: Direction,
            ) BaseAndSegmentMergeStream {
                return .{
                    .base = base,
                    .direction = direction,
                    .segment_stream = SegmentMergeStream.init(allocator, segments, direction),
                };
            }

            pub fn initFiltered(
                allocator: std.mem.Allocator,
                base: *Ops.BaseReaderType,
                segments: *Ops.SegmentCollectionType,
                direction: Direction,
                tombstones: ?*Ops.TombstoneViewType,
            ) BaseAndSegmentMergeStream {
                return .{
                    .base = base,
                    .direction = direction,
                    .tombstones = tombstones,
                    .segment_stream = SegmentMergeStream.initFiltered(allocator, segments, direction, tombstones),
                };
            }

            pub fn initWithVirtualFiltered(
                allocator: std.mem.Allocator,
                base: *Ops.BaseReaderType,
                segments: *Ops.SegmentCollectionType,
                virtual_edges: []const Edge,
                direction: Direction,
                tombstones: ?*Ops.TombstoneViewType,
            ) BaseAndSegmentMergeStream {
                return .{
                    .base = base,
                    .direction = direction,
                    .tombstones = tombstones,
                    .segment_stream = SegmentMergeStream.initWithVirtualFiltered(allocator, segments, virtual_edges, direction, tombstones),
                };
            }

            pub fn deinit(self: *BaseAndSegmentMergeStream) void {
                self.segment_stream.deinit();
            }

            pub fn reset(self: *BaseAndSegmentMergeStream) !void {
                self.base_pos = 0;
                self.next_base = try self.readNextBase();
                try self.segment_stream.reset();
                self.next_segment = try self.segment_stream.next();
            }

            pub fn next(self: *BaseAndSegmentMergeStream) !?Edge {
                if (self.next_base) |base_edge| {
                    if (self.next_segment) |segment_edge| {
                        if (Ops.edgeLessThan(self.direction, segment_edge, base_edge)) {
                            self.next_segment = try self.segment_stream.next();
                            return segment_edge;
                        }
                    }
                    self.next_base = try self.readNextBase();
                    return base_edge;
                }
                if (self.next_segment) |segment_edge| {
                    self.next_segment = try self.segment_stream.next();
                    return segment_edge;
                }
                return null;
            }

            fn readNextBase(self: *BaseAndSegmentMergeStream) !?Edge {
                while (self.base_pos < Ops.baseEdgeCount(self.base)) {
                    const edge = try Ops.baseEdgeAt(self.base, self.base_pos);
                    self.base_pos += 1;
                    if (self.tombstones) |tombstones| {
                        if (try Ops.isTombstoned(tombstones, edge)) continue;
                    }
                    return edge;
                }
                return null;
            }
        };
    };
}

const TestDirection = enum {
    forward,
    reverse,
};

const TestEdge = struct {
    src: u64,
    dst: u64,
    id: u64,
    rel: u8 = 0,
    origin: u8 = 0,
};

const TestSegmentCollection = struct {
    segments: []const []const TestEdge,
};

const TestSegmentIterator = struct {
    edges: []const TestEdge,
    pos: usize = 0,
};

const TestBaseReader = struct {
    edges: []const TestEdge,
};

const TestNeighborIterator = struct {
    edges: []const TestEdge,
    direction: TestDirection,
    node_id: u64,
    rel_filter: ?u8,
    pos: usize = 0,
};

const TestTombstoneView = struct {
    edge_ids: []const u64,
};

const TestOps = struct {
    pub const EdgeType = TestEdge;
    pub const DirectionType = TestDirection;
    pub const SegmentCollectionType = TestSegmentCollection;
    pub const SegmentIteratorType = TestSegmentIterator;
    pub const NeighborIteratorType = TestNeighborIterator;
    pub const BaseReaderType = TestBaseReader;
    pub const TombstoneViewType = TestTombstoneView;
    pub const NodeIdType = u64;
    pub const RelationType = u8;

    pub fn segmentCount(segments: *TestSegmentCollection) usize {
        return segments.segments.len;
    }

    pub fn segmentIterator(segments: *TestSegmentCollection, index: usize, _: TestDirection) !TestSegmentIterator {
        return .{ .edges = segments.segments[index] };
    }

    pub fn nextSegmentEdge(iterator: *TestSegmentIterator) !?TestEdge {
        if (iterator.pos >= iterator.edges.len) return null;
        const edge = iterator.edges[iterator.pos];
        iterator.pos += 1;
        if (edge.id == std.math.maxInt(u64)) return error.InjectedFailure;
        return edge;
    }

    pub fn neighborIterator(
        segments: *TestSegmentCollection,
        index: usize,
        direction: TestDirection,
        node_id: u64,
        rel_filter: ?u8,
    ) !?TestNeighborIterator {
        return .{
            .edges = segments.segments[index],
            .direction = direction,
            .node_id = node_id,
            .rel_filter = rel_filter,
        };
    }

    pub fn nextNeighborEdge(iterator: *TestNeighborIterator) !?TestEdge {
        while (iterator.pos < iterator.edges.len) {
            const edge = iterator.edges[iterator.pos];
            iterator.pos += 1;
            if (!virtualNeighborMatches(edge, iterator.direction, iterator.node_id, iterator.rel_filter)) continue;
            return edge;
        }
        return null;
    }

    pub fn virtualNeighborMatches(edge: TestEdge, direction: TestDirection, node_id: u64, rel_filter: ?u8) bool {
        const owner = if (direction == .forward) edge.src else edge.dst;
        if (owner != node_id) return false;
        if (rel_filter) |rel| return edge.rel == rel;
        return true;
    }

    pub fn baseEdgeCount(reader: *TestBaseReader) u64 {
        return reader.edges.len;
    }

    pub fn baseEdgeAt(reader: *TestBaseReader, index: u64) !TestEdge {
        return reader.edges[@intCast(index)];
    }

    pub fn isTombstoned(view: *TestTombstoneView, edge: TestEdge) !bool {
        for (view.edge_ids) |edge_id| {
            if (edge_id == edge.id) return true;
        }
        return false;
    }

    pub fn edgeLessThan(direction: TestDirection, lhs: TestEdge, rhs: TestEdge) bool {
        const lhs_first = if (direction == .forward) lhs.src else lhs.dst;
        const rhs_first = if (direction == .forward) rhs.src else rhs.dst;
        if (lhs_first != rhs_first) return lhs_first < rhs_first;
        const lhs_second = if (direction == .forward) lhs.dst else lhs.src;
        const rhs_second = if (direction == .forward) rhs.dst else rhs.src;
        if (lhs_second != rhs_second) return lhs_second < rhs_second;
        return lhs.id < rhs.id;
    }
};

const test_merge = EdgeSegmentMerge(TestOps);

fn collectIds(stream: anytype, output: *std.ArrayList(u64)) !void {
    while (try stream.next()) |edge| try output.append(std.testing.allocator, edge.id);
}

const TestNeighborContext = struct {
    ids: *std.ArrayList(u64),
    stop_at: ?u64 = null,
};

fn collectNeighbor(context: *TestNeighborContext, edge: TestEdge) !bool {
    try context.ids.append(std.testing.allocator, edge.id);
    return context.stop_at == edge.id;
}

test "edge segment merge orders physical and virtual streams across resets" {
    const first = [_]TestEdge{
        .{ .src = 1, .dst = 2, .id = 1 },
        .{ .src = 2, .dst = 1, .id = 4 },
    };
    const second = [_]TestEdge{
        .{ .src = 1, .dst = 3, .id = 2 },
        .{ .src = 3, .dst = 1, .id = 5 },
    };
    const virtual = [_]TestEdge{
        .{ .src = 1, .dst = 4, .id = 3 },
    };
    var segments = TestSegmentCollection{ .segments = &.{ &first, &second } };
    var stream = test_merge.SegmentMergeStream.initWithVirtual(std.testing.allocator, &segments, &virtual, .forward);
    defer stream.deinit();

    var ids = std.ArrayList(u64).empty;
    defer ids.deinit(std.testing.allocator);
    try stream.reset();
    try collectIds(&stream, &ids);
    try std.testing.expectEqualSlices(u64, &.{ 1, 2, 3, 4, 5 }, ids.items);

    ids.clearRetainingCapacity();
    try stream.reset();
    try collectIds(&stream, &ids);
    try std.testing.expectEqualSlices(u64, &.{ 1, 2, 3, 4, 5 }, ids.items);
}

test "edge segment merge filters tombstones from base segment and virtual inputs" {
    const base_edges = [_]TestEdge{
        .{ .src = 1, .dst = 1, .id = 1 },
        .{ .src = 2, .dst = 1, .id = 4 },
    };
    const physical = [_]TestEdge{
        .{ .src = 1, .dst = 2, .id = 2 },
    };
    const virtual = [_]TestEdge{
        .{ .src = 1, .dst = 3, .id = 3 },
    };
    var base = TestBaseReader{ .edges = &base_edges };
    var segments = TestSegmentCollection{ .segments = &.{&physical} };
    var tombstones = TestTombstoneView{ .edge_ids = &.{ 2, 4 } };
    var stream = test_merge.BaseAndSegmentMergeStream.initWithVirtualFiltered(
        std.testing.allocator,
        &base,
        &segments,
        &virtual,
        .forward,
        &tombstones,
    );
    defer stream.deinit();

    var ids = std.ArrayList(u64).empty;
    defer ids.deinit(std.testing.allocator);
    try stream.reset();
    try collectIds(&stream, &ids);
    try std.testing.expectEqualSlices(u64, &.{ 1, 3 }, ids.items);
}

test "edge segment merge keeps deterministic source order for equal edges" {
    const first = [_]TestEdge{.{ .src = 1, .dst = 2, .id = 3, .origin = 10 }};
    const second = [_]TestEdge{.{ .src = 1, .dst = 2, .id = 3, .origin = 20 }};
    const virtual = [_]TestEdge{.{ .src = 1, .dst = 2, .id = 3, .origin = 30 }};
    var segments = TestSegmentCollection{ .segments = &.{ &first, &second } };
    var stream = test_merge.SegmentMergeStream.initWithVirtual(std.testing.allocator, &segments, &virtual, .reverse);
    defer stream.deinit();
    try stream.reset();

    var origins: [3]u8 = undefined;
    for (&origins) |*origin| origin.* = (try stream.next()).?.origin;
    try std.testing.expectEqualSlices(u8, &.{ 10, 20, 30 }, &origins);
    try std.testing.expectEqual(@as(?TestEdge, null), try stream.next());
}

test "edge segment merge propagates iterator failures without owning readers" {
    const failing = [_]TestEdge{.{ .src = 1, .dst = 2, .id = std.math.maxInt(u64) }};
    var segments = TestSegmentCollection{ .segments = &.{&failing} };
    var stream = test_merge.SegmentMergeStream.init(std.testing.allocator, &segments, .forward);
    defer stream.deinit();

    try std.testing.expectError(error.InjectedFailure, stream.reset());
}

test "edge segment neighbor merge orders filters and stops through one callback" {
    const first = [_]TestEdge{
        .{ .src = 1, .dst = 2, .id = 1, .rel = 7 },
        .{ .src = 1, .dst = 4, .id = 4, .rel = 7 },
        .{ .src = 2, .dst = 1, .id = 8, .rel = 7 },
    };
    const second = [_]TestEdge{
        .{ .src = 1, .dst = 3, .id = 2, .rel = 7 },
        .{ .src = 1, .dst = 5, .id = 5, .rel = 9 },
    };
    const virtual = [_]TestEdge{
        .{ .src = 1, .dst = 3, .id = 3, .rel = 7 },
        .{ .src = 3, .dst = 1, .id = 6, .rel = 7 },
    };
    var segments = TestSegmentCollection{ .segments = &.{ &first, &second } };
    var ids = std.ArrayList(u64).empty;
    defer ids.deinit(std.testing.allocator);
    var context = TestNeighborContext{ .ids = &ids, .stop_at = 3 };

    const stopped = try test_merge.forEachNeighbor(
        std.testing.allocator,
        &segments,
        &virtual,
        .forward,
        1,
        7,
        16,
        &context,
        collectNeighbor,
    );

    try std.testing.expect(stopped);
    try std.testing.expectEqualSlices(u64, &.{ 1, 2, 3 }, ids.items);
}

test "edge segment neighbor merge enforces the shared edge budget" {
    const physical = [_]TestEdge{
        .{ .src = 1, .dst = 2, .id = 1 },
        .{ .src = 1, .dst = 3, .id = 2 },
    };
    var segments = TestSegmentCollection{ .segments = &.{&physical} };
    var ids = std.ArrayList(u64).empty;
    defer ids.deinit(std.testing.allocator);
    var context = TestNeighborContext{ .ids = &ids };

    try std.testing.expectError(error.BudgetExceeded, test_merge.forEachNeighbor(
        std.testing.allocator,
        &segments,
        &.{},
        .forward,
        1,
        null,
        1,
        &context,
        collectNeighbor,
    ));
    try std.testing.expectEqualSlices(u64, &.{1}, ids.items);
}
