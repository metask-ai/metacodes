const std = @import("std");
const core = @import("core.zig");
const graph_mod = @import("graph.zig");
const index = @import("index.zig");
const segment_mod = @import("segment.zig");
const storage = @import("storage.zig");
const checkpoint_view_mod = @import("query/checkpoint_view.zig");
const metaknow_deferred_based_on_mod = @import("query/metaknow_deferred_based_on.zig");
const metaknow_deferred_based_on = metaknow_deferred_based_on_mod.MetaknowDeferredBasedOn(core, index, storage);
const neighbor_traversal_mod = @import("query/neighbor_traversal.zig");
const neighbor_traversal = neighbor_traversal_mod.NeighborTraversal(core, index, EdgeCursor, NodeLookup);
const path_traversal_mod = @import("query/path_traversal.zig");
const path_traversal = path_traversal_mod.PathTraversal(core, index);

pub const metaknow_deferred_based_on_file = metaknow_deferred_based_on.metaknow_deferred_based_on_file;
pub const metaknow_deferred_based_on_magic = metaknow_deferred_based_on.metaknow_deferred_based_on_magic;
pub const metaknow_deferred_based_on_header_len = metaknow_deferred_based_on.metaknow_deferred_based_on_header_len;
pub const metaknow_deferred_based_on_index_record_len = metaknow_deferred_based_on.metaknow_deferred_based_on_index_record_len;
pub const metaknow_deferred_based_on_target_record_len = metaknow_deferred_based_on.metaknow_deferred_based_on_target_record_len;
pub const metaknow_deferred_based_on_edge_id_base = metaknow_deferred_based_on.metaknow_deferred_based_on_edge_id_base;
pub const MetaknowDeferredBasedOnDirection = metaknow_deferred_based_on.MetaknowDeferredBasedOnDirection;
pub const MetaknowDeferredBasedOnQueryResult = metaknow_deferred_based_on.MetaknowDeferredBasedOnQueryResult;
pub const metaknowDeferredBasedOnPath = metaknow_deferred_based_on.metaknowDeferredBasedOnPath;
pub const readMetaknowDeferredBasedOnTargets = metaknow_deferred_based_on.readMetaknowDeferredBasedOnTargets;
pub const Neighbor = neighbor_traversal.Neighbor;
pub const NeighborResult = neighbor_traversal.NeighborResult;
pub const neighborsWithCursor = neighbor_traversal.neighborsWithCursor;
pub const PathResult = path_traversal.PathResult;
pub const pathWithCursor = path_traversal.pathWithCursor;
pub const CheckpointProperty = checkpoint_view_mod.CheckpointProperty;
pub const CheckpointEdgeOrder = checkpoint_view_mod.CheckpointEdgeOrder;
pub const CheckpointView = checkpoint_view_mod.CheckpointView;

pub const EdgeCursor = union(enum) {
    memory: struct {
        mem_index: *index.MemoryIndex,
        checkpoint_view: ?CheckpointView = null,
    },
    store: struct {
        allocator: std.mem.Allocator,
        store: storage.Store,
        graph: *const graph_mod.Graph,
    },
    persistent_store: struct {
        allocator: std.mem.Allocator,
        store: storage.Store,
        edge_segments: ?*storage.PublishedEdgeSegments = null,
        edge_segments_coverage: storage.PublishedEdgeSegmentsCoverage = .full,
        edge_retention_registry: ?*storage.EdgeSegmentRetentionRegistry = null,
    },

    pub fn outgoing(self: EdgeCursor, allocator: std.mem.Allocator, node_id: core.NodeId) !std.ArrayList(index.EdgeRef) {
        switch (self) {
            .memory => |cursor| {
                return copyMemoryEdgeRefsLimited(allocator, cursor.mem_index.outgoing(node_id), (core.QueryBudget{}).max_visited_edges);
            },
            .store => |cursor| {
                return readStoreEdgeRefs(allocator, cursor.allocator, cursor.store, cursor.graph, .src, node_id);
            },
            .persistent_store => |cursor| {
                return readPersistentStoreEdgeRefs(allocator, cursor.allocator, cursor.store, cursor.edge_segments, cursor.edge_segments_coverage, cursor.edge_retention_registry, .src, node_id);
            },
        }
    }

    pub fn incoming(self: EdgeCursor, allocator: std.mem.Allocator, node_id: core.NodeId) !std.ArrayList(index.EdgeRef) {
        switch (self) {
            .memory => |cursor| {
                return copyMemoryEdgeRefsLimited(allocator, cursor.mem_index.incoming(node_id), (core.QueryBudget{}).max_visited_edges);
            },
            .store => |cursor| {
                return readStoreEdgeRefs(allocator, cursor.allocator, cursor.store, cursor.graph, .dst, node_id);
            },
            .persistent_store => |cursor| {
                return readPersistentStoreEdgeRefs(allocator, cursor.allocator, cursor.store, cursor.edge_segments, cursor.edge_segments_coverage, cursor.edge_retention_registry, .dst, node_id);
            },
        }
    }

    pub fn forEachOutgoing(self: EdgeCursor, node_id: core.NodeId, context: anytype, comptime callback: fn (@TypeOf(context), index.EdgeRef) anyerror!bool) !bool {
        return self.forEach(.src, node_id, context, callback);
    }

    pub fn forEachOutgoingRelation(self: EdgeCursor, node_id: core.NodeId, rel_filter: ?core.RelKind, context: anytype, comptime callback: fn (@TypeOf(context), index.EdgeRef) anyerror!bool) !bool {
        return self.forEachFiltered(.src, node_id, rel_filter, context, callback);
    }

    pub fn forEachIncoming(self: EdgeCursor, node_id: core.NodeId, context: anytype, comptime callback: fn (@TypeOf(context), index.EdgeRef) anyerror!bool) !bool {
        return self.forEach(.dst, node_id, context, callback);
    }

    pub fn forEachIncomingRelation(self: EdgeCursor, node_id: core.NodeId, rel_filter: ?core.RelKind, context: anytype, comptime callback: fn (@TypeOf(context), index.EdgeRef) anyerror!bool) !bool {
        return self.forEachFiltered(.dst, node_id, rel_filter, context, callback);
    }

    fn forEach(self: EdgeCursor, order: storage.EdgeIndexOrder, node_id: core.NodeId, context: anytype, comptime callback: fn (@TypeOf(context), index.EdgeRef) anyerror!bool) !bool {
        return self.forEachFiltered(order, node_id, null, context, callback);
    }

    fn forEachFiltered(self: EdgeCursor, order: storage.EdgeIndexOrder, node_id: core.NodeId, rel_filter: ?core.RelKind, context: anytype, comptime callback: fn (@TypeOf(context), index.EdgeRef) anyerror!bool) !bool {
        switch (self) {
            .memory => |cursor| {
                const edges = try memoryCursorEdges(cursor.mem_index, order, node_id, rel_filter);
                for (edges) |edge| {
                    if (try callback(context, edge)) return true;
                }
                return false;
            },
            .store => |cursor| {
                try cursor.store.ensurePersistentEdgeIndexes(cursor.graph);
                return forEachStoreEdgeRefFiltered(cursor.allocator, cursor.store, null, .full, null, order, node_id, rel_filter, context, callback);
            },
            .persistent_store => |cursor| {
                return forEachStoreEdgeRefFiltered(cursor.allocator, cursor.store, cursor.edge_segments, cursor.edge_segments_coverage, cursor.edge_retention_registry, order, node_id, rel_filter, context, callback);
            },
        }
    }
};

fn memoryCursorEdges(mem_index: *index.MemoryIndex, order: storage.EdgeIndexOrder, node_id: core.NodeId, rel_filter: ?core.RelKind) ![]const index.EdgeRef {
    return switch (order) {
        .src => if (rel_filter) |rel| mem_index.outgoingRelation(node_id, rel) else mem_index.outgoing(node_id),
        .dst => if (rel_filter) |rel| mem_index.incomingRelation(node_id, rel) else mem_index.incoming(node_id),
        .id => core.Error.Unsupported,
    };
}

fn copyMemoryEdgeRefsLimited(allocator: std.mem.Allocator, edges: []const index.EdgeRef, max_records: usize) !std.ArrayList(index.EdgeRef) {
    var out = std.ArrayList(index.EdgeRef).empty;
    errdefer out.deinit(allocator);
    for (edges) |edge| {
        if (out.items.len >= max_records) return core.Error.BudgetExceeded;
        try out.append(allocator, edge);
    }
    return out;
}

fn forEachStoreEdgeRefFiltered(allocator: std.mem.Allocator, store: storage.Store, edge_segments: ?*storage.PublishedEdgeSegments, edge_segments_coverage: storage.PublishedEdgeSegmentsCoverage, edge_retention_registry: ?*storage.EdgeSegmentRetentionRegistry, order: storage.EdgeIndexOrder, node_id: core.NodeId, rel_filter: ?core.RelKind, context: anytype, comptime callback: fn (@TypeOf(context), index.EdgeRef) anyerror!bool) !bool {
    var stopped = false;
    var used_segment = false;
    if (edge_segments) |segments| {
        if (edgeSegmentDirectionForOrder(order)) |direction| {
            used_segment = true;
            if (edge_segments_coverage == .delta) {
                stopped = try forEachDeltaOverlayEdgeRefFiltered(allocator, store, segments, order, direction, node_id, rel_filter, context, callback);
            } else {
                stopped = try forEachOpenedFullSegmentEdgeRef(store, segments, edge_segments_coverage, direction, node_id, rel_filter, context, callback);
            }
        }
    } else if (edgeSegmentDirectionForOrder(order)) |direction| {
        var opened = if (edge_retention_registry) |registry|
            try store.openPublishedEdgeSegmentsForQueryForNodeRetained(allocator, registry, direction, node_id)
        else
            try store.openPublishedEdgeSegmentsForQueryForNode(allocator, direction, node_id);
        if (opened) |*segments_for_query| {
            defer segments_for_query.deinit();
            used_segment = true;
            if (segments_for_query.coverage == .delta) {
                stopped = try forEachDeltaOverlayEdgeRefFiltered(allocator, store, &segments_for_query.segments, order, direction, node_id, rel_filter, context, callback);
            } else {
                stopped = try forEachOpenedFullSegmentEdgeRef(store, &segments_for_query.segments, segments_for_query.coverage, direction, node_id, rel_filter, context, callback);
            }
        }
    }
    if (!used_segment) {
        var records = try store.edgeIndexRecordsByNodeAndRelationIterator(order, node_id, rel_filter);
        defer records.deinit();
        while (try records.next()) |record| {
            const edge: index.EdgeRef = .{
                .src = core.NodeId.fromInt(record.src),
                .dst = core.NodeId.fromInt(record.dst),
                .edge_id = core.EdgeId.fromInt(record.edge_id),
                .rel = try record.relKind(),
            };
            if (try callback(context, edge)) return true;
        }
    }
    if (stopped) return true;
    if (rel_filter == null or rel_filter.? == .based_on) {
        if (try metaknow_deferred_based_on.forEachEdgeRef(allocator, store, order, node_id, context, callback)) return true;
    }
    return false;
}

fn forEachOpenedFullSegmentEdgeRef(store: storage.Store, segments: *storage.PublishedEdgeSegments, coverage: storage.PublishedEdgeSegmentsCoverage, direction: segment_mod.Direction, node_id: core.NodeId, rel_filter: ?core.RelKind, context: anytype, comptime callback: fn (@TypeOf(context), index.EdgeRef) anyerror!bool) !bool {
    const RoutedContext = struct {
        inner: @TypeOf(context),
    };
    const routed_context = RoutedContext{ .inner = context };
    if (coverage == .visible_full) {
        return try segments.forEachNeighbor(direction, node_id, rel_filter, (core.QueryBudget{}).max_visited_edges, routed_context, struct {
            fn visit(routed_ctx: RoutedContext, edge: segment_mod.EdgeRecord) !bool {
                return callback(routed_ctx.inner, segmentEdgeToRef(edge));
            }
        }.visit);
    }
    return try store.forEachOpenedPublishedEdgeSegmentNeighbor(segments, direction, node_id, rel_filter, (core.QueryBudget{}).max_visited_edges, routed_context, struct {
        fn visit(routed_ctx: RoutedContext, edge: segment_mod.EdgeRecord) !bool {
            return callback(routed_ctx.inner, segmentEdgeToRef(edge));
        }
    }.visit);
}

fn forEachDeltaOverlayEdgeRefFiltered(allocator: std.mem.Allocator, store: storage.Store, edge_segments: *storage.PublishedEdgeSegments, order: storage.EdgeIndexOrder, direction: segment_mod.Direction, node_id: core.NodeId, rel_filter: ?core.RelKind, context: anytype, comptime callback: fn (@TypeOf(context), index.EdgeRef) anyerror!bool) !bool {
    const max_records = (core.QueryBudget{}).max_visited_edges;
    var delta_edges = try collectDeltaSegmentEdgeRefs(allocator, store, edge_segments, direction, node_id, rel_filter, max_records);
    defer delta_edges.deinit(allocator);
    std.mem.sort(index.EdgeRef, delta_edges.items, EdgeRefSortContext{ .order = order }, edgeRefLessThan);

    var base = try store.edgeIndexRecordsByNodeAndRelationIterator(order, node_id, rel_filter);
    defer base.deinit();
    var base_next = try readNextEdgeRef(&base);
    var delta_pos: usize = 0;
    var emitted: usize = 0;
    while (base_next != null or delta_pos < delta_edges.items.len) {
        if (emitted >= max_records) return core.Error.BudgetExceeded;
        const edge = if (base_next) |base_edge| blk: {
            if (delta_pos < delta_edges.items.len and edgeRefLessThan(.{ .order = order }, delta_edges.items[delta_pos], base_edge)) {
                const delta_edge = delta_edges.items[delta_pos];
                delta_pos += 1;
                break :blk delta_edge;
            }
            base_next = try readNextEdgeRef(&base);
            break :blk base_edge;
        } else blk: {
            const delta_edge = delta_edges.items[delta_pos];
            delta_pos += 1;
            break :blk delta_edge;
        };
        emitted += 1;
        if (try callback(context, edge)) return true;
    }
    return false;
}

fn collectDeltaOverlayEdgeRefs(
    allocator: std.mem.Allocator,
    store: storage.Store,
    edge_segments: *storage.PublishedEdgeSegments,
    order: storage.EdgeIndexOrder,
    direction: segment_mod.Direction,
    node_id: core.NodeId,
    rel_filter: ?core.RelKind,
    max_records: usize,
) !std.ArrayList(index.EdgeRef) {
    var out = std.ArrayList(index.EdgeRef).empty;
    errdefer out.deinit(allocator);

    var records = try store.edgeIndexRecordsByNodeAndRelationIterator(order, node_id, rel_filter);
    defer records.deinit();
    while (try records.next()) |record| {
        if (out.items.len >= max_records) return core.Error.BudgetExceeded;
        try out.append(allocator, .{
            .src = core.NodeId.fromInt(record.src),
            .dst = core.NodeId.fromInt(record.dst),
            .edge_id = core.EdgeId.fromInt(record.edge_id),
            .rel = try record.relKind(),
        });
    }

    var delta_edges = try collectDeltaSegmentEdgeRefs(allocator, store, edge_segments, direction, node_id, rel_filter, max_records);
    defer delta_edges.deinit(allocator);
    if (out.items.len > max_records - delta_edges.items.len) return core.Error.BudgetExceeded;
    try out.appendSlice(allocator, delta_edges.items);
    std.mem.sort(index.EdgeRef, out.items, EdgeRefSortContext{ .order = order }, edgeRefLessThan);
    return out;
}

fn collectDeltaSegmentEdgeRefs(
    allocator: std.mem.Allocator,
    store: storage.Store,
    edge_segments: *storage.PublishedEdgeSegments,
    direction: segment_mod.Direction,
    node_id: core.NodeId,
    rel_filter: ?core.RelKind,
    max_records: usize,
) !std.ArrayList(index.EdgeRef) {
    var out = std.ArrayList(index.EdgeRef).empty;
    errdefer out.deinit(allocator);

    const SegmentCollectContext = struct {
        allocator: std.mem.Allocator,
        out: *std.ArrayList(index.EdgeRef),
        max_records: usize,
    };
    var collect_context = SegmentCollectContext{
        .allocator = allocator,
        .out = &out,
        .max_records = max_records,
    };
    // Tombstones are filtered inside the storage callback adapter. Keep the
    // visible-result cap in this collector, but allow the bounded default scan
    // budget to skip deleted physical records before a live delta edge.
    const scan_limit = @max(max_records, (core.QueryBudget{}).max_visited_edges);
    _ = try store.forEachOpenedPublishedEdgeSegmentNeighbor(edge_segments, direction, node_id, rel_filter, scan_limit, &collect_context, struct {
        fn visit(collect_ctx: *SegmentCollectContext, edge: segment_mod.EdgeRecord) !bool {
            if (collect_ctx.out.items.len >= collect_ctx.max_records) return core.Error.BudgetExceeded;
            try collect_ctx.out.append(collect_ctx.allocator, segmentEdgeToRef(edge));
            return false;
        }
    }.visit);
    return out;
}

fn readNextEdgeRef(records: *storage.Store.EdgeIndexRecordIterator) !?index.EdgeRef {
    const record = (try records.next()) orelse return null;
    return .{
        .src = core.NodeId.fromInt(record.src),
        .dst = core.NodeId.fromInt(record.dst),
        .edge_id = core.EdgeId.fromInt(record.edge_id),
        .rel = try record.relKind(),
    };
}

const EdgeRefSortContext = struct {
    order: storage.EdgeIndexOrder,
};

fn edgeRefLessThan(context: EdgeRefSortContext, lhs: index.EdgeRef, rhs: index.EdgeRef) bool {
    return switch (context.order) {
        .src => if (lhs.src.toInt() != rhs.src.toInt())
            lhs.src.toInt() < rhs.src.toInt()
        else if (@intFromEnum(lhs.rel) != @intFromEnum(rhs.rel))
            @intFromEnum(lhs.rel) < @intFromEnum(rhs.rel)
        else if (lhs.dst.toInt() != rhs.dst.toInt())
            lhs.dst.toInt() < rhs.dst.toInt()
        else
            lhs.edge_id.toInt() < rhs.edge_id.toInt(),
        .dst => if (lhs.dst.toInt() != rhs.dst.toInt())
            lhs.dst.toInt() < rhs.dst.toInt()
        else if (@intFromEnum(lhs.rel) != @intFromEnum(rhs.rel))
            @intFromEnum(lhs.rel) < @intFromEnum(rhs.rel)
        else if (lhs.src.toInt() != rhs.src.toInt())
            lhs.src.toInt() < rhs.src.toInt()
        else
            lhs.edge_id.toInt() < rhs.edge_id.toInt(),
        .id => lhs.edge_id.toInt() < rhs.edge_id.toInt(),
    };
}

fn edgeSegmentDirectionForOrder(order: storage.EdgeIndexOrder) ?segment_mod.Direction {
    return switch (order) {
        .src => .forward,
        .dst => .reverse,
        .id => null,
    };
}

fn segmentEdgeToRef(edge: segment_mod.EdgeRecord) index.EdgeRef {
    return .{
        .src = edge.src,
        .dst = edge.dst,
        .edge_id = edge.edge_id,
        .rel = edge.rel,
    };
}

fn readPublishedSegmentEdgeRefsLimited(
    allocator: std.mem.Allocator,
    store: storage.Store,
    edge_segments: ?*storage.PublishedEdgeSegments,
    edge_segments_coverage: storage.PublishedEdgeSegmentsCoverage,
    edge_retention_registry: ?*storage.EdgeSegmentRetentionRegistry,
    order: storage.EdgeIndexOrder,
    node_id: core.NodeId,
    rel_filter: ?core.RelKind,
    max_records: usize,
) !?std.ArrayList(index.EdgeRef) {
    const direction = edgeSegmentDirectionForOrder(order) orelse return null;
    if (edge_segments == null) {
        var opened = if (edge_retention_registry) |registry|
            try store.openPublishedEdgeSegmentsForQueryForNodeRetained(allocator, registry, direction, node_id)
        else
            try store.openPublishedEdgeSegmentsForQueryForNode(allocator, direction, node_id);
        if (opened) |*segments_for_query| {
            defer segments_for_query.deinit();
            if (segments_for_query.coverage == .delta) return null;
            return readPublishedSegmentEdgeRefsLimited(
                allocator,
                store,
                &segments_for_query.segments,
                segments_for_query.coverage,
                null,
                order,
                node_id,
                rel_filter,
                max_records,
            );
        }
        return null;
    }

    var out = std.ArrayList(index.EdgeRef).empty;
    errdefer out.deinit(allocator);

    const SegmentCollectContext = struct {
        allocator: std.mem.Allocator,
        out: *std.ArrayList(index.EdgeRef),
        max_records: usize,
    };
    var collect_context = SegmentCollectContext{
        .allocator = allocator,
        .out = &out,
        .max_records = max_records,
    };
    const scan_limit = @max(max_records, (core.QueryBudget{}).max_visited_edges);
    const segments = edge_segments.?;
    const routed = if (edge_segments_coverage == .visible_full)
        try segments.forEachNeighbor(direction, node_id, rel_filter, scan_limit, &collect_context, struct {
            fn visit(collect_ctx: *SegmentCollectContext, edge: segment_mod.EdgeRecord) !bool {
                if (collect_ctx.out.items.len >= collect_ctx.max_records) return core.Error.BudgetExceeded;
                try collect_ctx.out.append(collect_ctx.allocator, segmentEdgeToRef(edge));
                return false;
            }
        }.visit)
    else
        try store.forEachOpenedPublishedEdgeSegmentNeighbor(segments, direction, node_id, rel_filter, scan_limit, &collect_context, struct {
            fn visit(collect_ctx: *SegmentCollectContext, edge: segment_mod.EdgeRecord) !bool {
                if (collect_ctx.out.items.len >= collect_ctx.max_records) return core.Error.BudgetExceeded;
                try collect_ctx.out.append(collect_ctx.allocator, segmentEdgeToRef(edge));
                return false;
            }
        }.visit);
    _ = routed;
    return out;
}

fn readStoreEdgeRefs(
    allocator: std.mem.Allocator,
    store_allocator: std.mem.Allocator,
    store: storage.Store,
    graph: *const graph_mod.Graph,
    order: storage.EdgeIndexOrder,
    node_id: core.NodeId,
) !std.ArrayList(index.EdgeRef) {
    return readStoreEdgeRefsLimited(allocator, store_allocator, store, graph, order, node_id, (core.QueryBudget{}).max_visited_edges);
}

fn readStoreEdgeRefsLimited(
    allocator: std.mem.Allocator,
    store_allocator: std.mem.Allocator,
    store: storage.Store,
    graph: *const graph_mod.Graph,
    order: storage.EdgeIndexOrder,
    node_id: core.NodeId,
    max_records: usize,
) !std.ArrayList(index.EdgeRef) {
    _ = store_allocator;
    var out = std.ArrayList(index.EdgeRef).empty;
    errdefer out.deinit(allocator);

    if (try readPublishedSegmentEdgeRefsLimited(allocator, store, null, .full, null, order, node_id, null, max_records)) |segment_edges| {
        return segment_edges;
    }

    try store.ensurePersistentEdgeIndexes(graph);
    var records = try store.edgeIndexRecordsByNodeIterator(order, node_id);
    defer records.deinit();
    while (try records.next()) |record| {
        if (out.items.len >= max_records) return core.Error.BudgetExceeded;
        try out.append(allocator, .{
            .src = core.NodeId.fromInt(record.src),
            .dst = core.NodeId.fromInt(record.dst),
            .edge_id = core.EdgeId.fromInt(record.edge_id),
            .rel = try record.relKind(),
        });
    }
    return out;
}

fn readPersistentStoreEdgeRefs(
    allocator: std.mem.Allocator,
    store_allocator: std.mem.Allocator,
    store: storage.Store,
    edge_segments: ?*storage.PublishedEdgeSegments,
    edge_segments_coverage: storage.PublishedEdgeSegmentsCoverage,
    edge_retention_registry: ?*storage.EdgeSegmentRetentionRegistry,
    order: storage.EdgeIndexOrder,
    node_id: core.NodeId,
) !std.ArrayList(index.EdgeRef) {
    return readPersistentStoreEdgeRefsLimitedWithSegment(allocator, store_allocator, store, edge_segments, edge_segments_coverage, edge_retention_registry, order, node_id, (core.QueryBudget{}).max_visited_edges);
}

fn readPersistentStoreEdgeRefsLimited(
    allocator: std.mem.Allocator,
    store_allocator: std.mem.Allocator,
    store: storage.Store,
    order: storage.EdgeIndexOrder,
    node_id: core.NodeId,
    max_records: usize,
) !std.ArrayList(index.EdgeRef) {
    return readPersistentStoreEdgeRefsLimitedWithSegment(allocator, store_allocator, store, null, .full, null, order, node_id, max_records);
}

fn readPersistentStoreEdgeRefsLimitedWithSegment(
    allocator: std.mem.Allocator,
    store_allocator: std.mem.Allocator,
    store: storage.Store,
    edge_segments: ?*storage.PublishedEdgeSegments,
    edge_segments_coverage: storage.PublishedEdgeSegmentsCoverage,
    edge_retention_registry: ?*storage.EdgeSegmentRetentionRegistry,
    order: storage.EdgeIndexOrder,
    node_id: core.NodeId,
    max_records: usize,
) !std.ArrayList(index.EdgeRef) {
    _ = store_allocator;
    var out = std.ArrayList(index.EdgeRef).empty;
    errdefer out.deinit(allocator);

    if (edge_segments) |segments| {
        if (edgeSegmentDirectionForOrder(order)) |direction| {
            if (edge_segments_coverage == .delta) {
                out.deinit(allocator);
                return collectDeltaOverlayEdgeRefs(allocator, store, segments, order, direction, node_id, null, max_records);
            }
        }
        if (try readPublishedSegmentEdgeRefsLimited(allocator, store, edge_segments, edge_segments_coverage, null, order, node_id, null, max_records)) |segment_edges| {
            return segment_edges;
        }
    } else if (edgeSegmentDirectionForOrder(order)) |direction| {
        var opened = if (edge_retention_registry) |registry|
            try store.openPublishedEdgeSegmentsForQueryForNodeRetained(allocator, registry, direction, node_id)
        else
            try store.openPublishedEdgeSegmentsForQueryForNode(allocator, direction, node_id);
        if (opened) |*segments_for_query| {
            defer segments_for_query.deinit();
            if (segments_for_query.coverage == .delta) {
                out.deinit(allocator);
                return collectDeltaOverlayEdgeRefs(allocator, store, &segments_for_query.segments, order, direction, node_id, null, max_records);
            }
            if (try readPublishedSegmentEdgeRefsLimited(allocator, store, &segments_for_query.segments, segments_for_query.coverage, null, order, node_id, null, max_records)) |segment_edges| {
                return segment_edges;
            }
        }
    }

    var records = try store.edgeIndexRecordsByNodeIterator(order, node_id);
    defer records.deinit();
    while (try records.next()) |record| {
        if (out.items.len >= max_records) return core.Error.BudgetExceeded;
        try out.append(allocator, .{
            .src = core.NodeId.fromInt(record.src),
            .dst = core.NodeId.fromInt(record.dst),
            .edge_id = core.EdgeId.fromInt(record.edge_id),
            .rel = try record.relKind(),
        });
    }
    return out;
}

pub const NodeLookup = union(enum) {
    graph: *const graph_mod.Graph,
    memory: struct {
        graph: *const graph_mod.Graph,
        mem_index: *index.MemoryIndex,
    },
    persistent_store: struct {
        store: storage.Store,
        node_view: ?*const storage.Store.NodeByIdIndexView = null,
        missing_is_invalid: bool = false,
    },

    pub fn exists(self: NodeLookup, id: core.NodeId) !bool {
        return switch (self) {
            .graph => |graph| graph.getNode(id) != null,
            .memory => |lookup| lookup.mem_index.getNode(lookup.graph, id) != null,
            .persistent_store => |lookup| {
                const present = if (lookup.node_view) |view|
                    try view.nodeExists(id)
                else
                    try lookup.store.nodeExistsById(id);
                if (!present) {
                    if (lookup.missing_is_invalid) return error.InvalidRecord;
                    return false;
                }
                return true;
            },
        };
    }
};

pub fn neighbors(
    allocator: std.mem.Allocator,
    graph: *const graph_mod.Graph,
    node_id: core.NodeId,
    rel_filter: ?core.RelKind,
    budget: core.QueryBudget,
) !NeighborResult {
    var mem_index = try index.MemoryIndex.init(allocator, graph);
    defer mem_index.deinit();
    return neighborsWithIndex(allocator, graph, &mem_index, node_id, rel_filter, budget);
}

pub fn neighborsWithIndex(
    allocator: std.mem.Allocator,
    graph: *const graph_mod.Graph,
    mem_index: *index.MemoryIndex,
    node_id: core.NodeId,
    rel_filter: ?core.RelKind,
    budget: core.QueryBudget,
) !NeighborResult {
    if (isReservedNodeId(node_id)) return core.Error.InvalidId;
    if (mem_index.getNode(graph, node_id) == null) return core.Error.NotFound;
    return neighbor_traversal.neighborsWithCursorAndLookup(
        allocator,
        .{ .memory = .{ .mem_index = mem_index } },
        .{ .memory = .{ .graph = graph, .mem_index = mem_index } },
        node_id,
        rel_filter,
        budget,
    );
}

pub fn neighborsWithStore(
    allocator: std.mem.Allocator,
    store: storage.Store,
    graph: *const graph_mod.Graph,
    node_id: core.NodeId,
    rel_filter: ?core.RelKind,
    budget: core.QueryBudget,
) !NeighborResult {
    if (isReservedNodeId(node_id)) return core.Error.InvalidId;
    if (graph.getNode(node_id) == null) return core.Error.NotFound;
    return neighbor_traversal.neighborsWithCursorAndLookup(
        allocator,
        .{ .store = .{
            .allocator = allocator,
            .store = store,
            .graph = graph,
        } },
        .{ .graph = graph },
        node_id,
        rel_filter,
        budget,
    );
}

pub fn neighborsWithPersistentStore(
    allocator: std.mem.Allocator,
    store: storage.Store,
    node_id: core.NodeId,
    rel_filter: ?core.RelKind,
    budget: core.QueryBudget,
) !NeighborResult {
    return neighborsWithPersistentStoreMaybeRetained(allocator, store, null, node_id, rel_filter, budget);
}

pub fn neighborsWithPersistentStoreRetained(
    allocator: std.mem.Allocator,
    store: storage.Store,
    edge_retention_registry: *storage.EdgeSegmentRetentionRegistry,
    node_id: core.NodeId,
    rel_filter: ?core.RelKind,
    budget: core.QueryBudget,
) !NeighborResult {
    return neighborsWithPersistentStoreMaybeRetained(allocator, store, edge_retention_registry, node_id, rel_filter, budget);
}

fn neighborsWithPersistentStoreMaybeRetained(
    allocator: std.mem.Allocator,
    store: storage.Store,
    edge_retention_registry: ?*storage.EdgeSegmentRetentionRegistry,
    node_id: core.NodeId,
    rel_filter: ?core.RelKind,
    budget: core.QueryBudget,
) !NeighborResult {
    var repaired = false;
    while (true) {
        return neighborsWithPersistentStoreOnce(allocator, store, edge_retention_registry, node_id, rel_filter, budget) catch |err| switch (err) {
            error.FileNotFound, error.InvalidRecord => {
                if (repaired) return err;
                repaired = true;
                try store.repairPersistentIndexesFromLog();
                continue;
            },
            else => |e| return e,
        };
    }
}

fn neighborsWithPersistentStoreOnce(
    allocator: std.mem.Allocator,
    store: storage.Store,
    edge_retention_registry: ?*storage.EdgeSegmentRetentionRegistry,
    node_id: core.NodeId,
    rel_filter: ?core.RelKind,
    budget: core.QueryBudget,
) !NeighborResult {
    if (isReservedNodeId(node_id)) return core.Error.InvalidId;
    const deadline = core.QueryDeadline.fromIo(store.io, budget.timeout_ms);
    if (deadline.expired()) {
        var result = NeighborResult{
            .neighbors = .empty,
            .stats = .{},
        };
        errdefer result.deinit(allocator);
        result.stats.budget_exceeded = true;
        return result;
    }

    var node_view = try store.openNodeByIdIndexView();
    defer node_view.deinit();
    if (!try node_view.nodeExists(node_id)) return core.Error.NotFound;
    var edge_segments = if (edge_retention_registry) |registry|
        try store.openPublishedEdgeSegmentsForQueryForNodeRetained(allocator, registry, .forward, node_id)
    else
        try store.openPublishedEdgeSegmentsForQueryForNode(allocator, .forward, node_id);
    defer if (edge_segments) |*segments| segments.deinit();
    var edge_segments_ref: ?*storage.PublishedEdgeSegments = null;
    var edge_segments_coverage: storage.PublishedEdgeSegmentsCoverage = .full;
    if (edge_segments) |*segments_for_query| {
        edge_segments_ref = &segments_for_query.segments;
        edge_segments_coverage = segments_for_query.coverage;
    }

    return neighbor_traversal.neighborsWithCursorAndLookupDeadline(
        allocator,
        .{ .persistent_store = .{ .allocator = allocator, .store = store, .edge_segments = edge_segments_ref, .edge_segments_coverage = edge_segments_coverage, .edge_retention_registry = edge_retention_registry } },
        .{ .persistent_store = .{ .store = store, .node_view = &node_view, .missing_is_invalid = true } },
        node_id,
        rel_filter,
        budget,
        deadline,
    );
}

pub fn path(
    allocator: std.mem.Allocator,
    graph: *const graph_mod.Graph,
    from: core.NodeId,
    to: core.NodeId,
    rel_filter: ?core.RelKind,
    budget: core.QueryBudget,
) !PathResult {
    var mem_index = try index.MemoryIndex.init(allocator, graph);
    defer mem_index.deinit();
    return pathWithIndex(allocator, graph, &mem_index, from, to, rel_filter, budget);
}

pub fn pathWithIndex(
    allocator: std.mem.Allocator,
    graph: *const graph_mod.Graph,
    mem_index: *index.MemoryIndex,
    from: core.NodeId,
    to: core.NodeId,
    rel_filter: ?core.RelKind,
    budget: core.QueryBudget,
) !PathResult {
    return path_traversal.pathWithCursor(allocator, @as(EdgeCursor, .{ .memory = .{ .mem_index = mem_index } }), @as(NodeLookup, .{ .memory = .{ .graph = graph, .mem_index = mem_index } }), from, to, rel_filter, budget);
}

pub fn pathWithStore(
    allocator: std.mem.Allocator,
    store: storage.Store,
    graph: *const graph_mod.Graph,
    from: core.NodeId,
    to: core.NodeId,
    rel_filter: ?core.RelKind,
    budget: core.QueryBudget,
) !PathResult {
    return path_traversal.pathWithCursor(allocator, @as(EdgeCursor, .{ .store = .{
        .allocator = allocator,
        .store = store,
        .graph = graph,
    } }), @as(NodeLookup, .{ .graph = graph }), from, to, rel_filter, budget);
}

pub fn pathWithPersistentStore(
    allocator: std.mem.Allocator,
    store: storage.Store,
    from: core.NodeId,
    to: core.NodeId,
    rel_filter: ?core.RelKind,
    budget: core.QueryBudget,
) !PathResult {
    return pathWithPersistentStoreMaybeRetained(allocator, store, null, from, to, rel_filter, budget);
}

pub fn pathWithPersistentStoreRetained(
    allocator: std.mem.Allocator,
    store: storage.Store,
    edge_retention_registry: *storage.EdgeSegmentRetentionRegistry,
    from: core.NodeId,
    to: core.NodeId,
    rel_filter: ?core.RelKind,
    budget: core.QueryBudget,
) !PathResult {
    return pathWithPersistentStoreMaybeRetained(allocator, store, edge_retention_registry, from, to, rel_filter, budget);
}

fn pathWithPersistentStoreMaybeRetained(
    allocator: std.mem.Allocator,
    store: storage.Store,
    edge_retention_registry: ?*storage.EdgeSegmentRetentionRegistry,
    from: core.NodeId,
    to: core.NodeId,
    rel_filter: ?core.RelKind,
    budget: core.QueryBudget,
) !PathResult {
    var repaired = false;
    while (true) {
        return pathWithPersistentStoreOnce(allocator, store, edge_retention_registry, from, to, rel_filter, budget) catch |err| switch (err) {
            error.FileNotFound, error.InvalidRecord => {
                if (repaired) return err;
                repaired = true;
                try store.repairPersistentIndexesFromLog();
                continue;
            },
            else => |e| return e,
        };
    }
}

fn pathWithPersistentStoreOnce(
    allocator: std.mem.Allocator,
    store: storage.Store,
    edge_retention_registry: ?*storage.EdgeSegmentRetentionRegistry,
    from: core.NodeId,
    to: core.NodeId,
    rel_filter: ?core.RelKind,
    budget: core.QueryBudget,
) !PathResult {
    if (isReservedNodeId(from) or isReservedNodeId(to)) return core.Error.InvalidId;
    const deadline = core.QueryDeadline.fromIo(store.io, budget.timeout_ms);
    if (deadline.expired() or (from.toInt() != to.toInt() and budget.max_visited_nodes == 0)) {
        return path_traversal.pathWithCursorDeadline(
            allocator,
            @as(EdgeCursor, .{ .persistent_store = .{ .allocator = allocator, .store = store, .edge_retention_registry = edge_retention_registry } }),
            @as(NodeLookup, .{ .persistent_store = .{ .store = store } }),
            from,
            to,
            rel_filter,
            budget,
            deadline,
            true,
        );
    }
    var node_view = try store.openNodeByIdIndexView();
    defer node_view.deinit();
    var edge_segments = if (edge_retention_registry) |registry|
        try store.openPublishedEdgeSegmentsForQueryRetained(allocator, registry)
    else
        try store.openPublishedEdgeSegmentsForQuery(allocator);
    defer if (edge_segments) |*segments| segments.deinit();
    var edge_segments_ref: ?*storage.PublishedEdgeSegments = null;
    var edge_segments_coverage: storage.PublishedEdgeSegmentsCoverage = .full;
    if (edge_segments) |*segments_for_query| {
        edge_segments_ref = &segments_for_query.segments;
        edge_segments_coverage = segments_for_query.coverage;
    }
    return path_traversal.pathWithCursorDeadline(
        allocator,
        @as(EdgeCursor, .{ .persistent_store = .{ .allocator = allocator, .store = store, .edge_segments = edge_segments_ref, .edge_segments_coverage = edge_segments_coverage, .edge_retention_registry = edge_retention_registry } }),
        @as(NodeLookup, .{ .persistent_store = .{ .store = store, .node_view = &node_view } }),
        from,
        to,
        rel_filter,
        budget,
        deadline,
        true,
    );
}

fn isReservedNodeId(id: core.NodeId) bool {
    return id == .none or id.toInt() == std.math.maxInt(u64);
}

fn budgetTimedOutImmediately(budget: core.QueryBudget) bool {
    return budget.timeout_ms == 0;
}

test "neighbors filters by relation" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();

    const file = try graph.addNode(.file, "src/main.zig");
    const func = try graph.addNode(.function, "main");
    const doc = try graph.addNode(.document, "README.md");
    _ = try graph.addEdgeUnchecked(file, .defines, func);
    _ = try graph.addEdgeUnchecked(file, .contains, doc);

    var result = try neighbors(std.testing.allocator, &graph, file, .defines, .{});
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), result.neighbors.items.len);
    try std.testing.expectEqual(func.toInt(), result.neighbors.items[0].node_id.toInt());
}

test "neighbors rejects missing source node" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();

    try std.testing.expectError(core.Error.NotFound, neighbors(std.testing.allocator, &graph, .fromInt(42), null, .{}));
    try std.testing.expectError(core.Error.InvalidId, neighbors(std.testing.allocator, &graph, .none, null, .{}));
    try std.testing.expectError(core.Error.InvalidId, neighbors(std.testing.allocator, &graph, .fromInt(std.math.maxInt(u64)), null, .{}));
}

test "neighbors with cursor rejects reserved source node ids" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    var mem_index = try index.MemoryIndex.init(std.testing.allocator, &graph);
    defer mem_index.deinit();

    const cursor = EdgeCursor{ .memory = .{ .mem_index = &mem_index } };
    try std.testing.expectError(core.Error.InvalidId, neighborsWithCursor(std.testing.allocator, cursor, .none, null, .{}));
    try std.testing.expectError(core.Error.InvalidId, neighborsWithCursor(std.testing.allocator, cursor, .fromInt(std.math.maxInt(u64)), null, .{}));
}

test "node lookup borrows graph and sees growth after construction" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();

    var mem_index = try index.MemoryIndex.init(std.testing.allocator, &graph);
    defer mem_index.deinit();

    const lookup = NodeLookup{ .memory = .{ .graph = &graph, .mem_index = &mem_index } };
    const task = try graph.addNode(.task, "late task");
    try mem_index.addNode(graph.nodes.items[graph.nodes.items.len - 1], graph.nodes.items.len - 1);

    try std.testing.expect(try lookup.exists(task));
    const node = mem_index.getNode(&graph, task) orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(task.toInt(), node.id.toInt());
    try std.testing.expectEqualStrings("late task", node.text);
}

test "neighbors with index skips dangling edge targets" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();

    const file = try graph.addNode(.file, "src/main.zig");
    try graph.edges.append(std.testing.allocator, .{
        .id = .fromInt(1),
        .src = file,
        .dst = .fromInt(99),
        .rel = .defines,
    });

    var result = try neighbors(std.testing.allocator, &graph, file, .defines, .{});
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), result.neighbors.items.len);
}

test "neighbors uses relation-bounded edge budget" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();

    const file = try graph.addNode(.file, "src/main.zig");
    const func = try graph.addNode(.function, "main");
    const doc = try graph.addNode(.document, "README.md");
    _ = try graph.addEdgeUnchecked(file, .contains, doc);
    _ = try graph.addEdgeUnchecked(file, .defines, func);

    var one = try neighbors(std.testing.allocator, &graph, file, .defines, .{ .max_visited_edges = 1 });
    defer one.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), one.neighbors.items.len);
    try std.testing.expectEqual(func.toInt(), one.neighbors.items[0].node_id.toInt());
    try std.testing.expectEqual(@as(usize, 1), one.stats.edges_visited);
    try std.testing.expect(!one.stats.budget_exceeded);

    var zero = try neighbors(std.testing.allocator, &graph, file, .defines, .{ .max_visited_edges = 0 });
    defer zero.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), zero.neighbors.items.len);
    try std.testing.expect(zero.stats.budget_exceeded);
}

test "neighbors honors immediate timeout budget" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();

    const file = try graph.addNode(.file, "src/main.zig");
    const func = try graph.addNode(.function, "main");
    _ = try graph.addEdgeUnchecked(file, .defines, func);

    var result = try neighbors(std.testing.allocator, &graph, file, .defines, .{ .timeout_ms = 0 });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), result.neighbors.items.len);
    try std.testing.expect(result.stats.budget_exceeded);
}

test "neighbors applies zero edge budget before materializing outgoing edges" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();

    const file = try graph.addNode(.file, "src/main.zig");
    const func = try graph.addNode(.function, "main");
    _ = try graph.addEdgeUnchecked(file, .defines, func);

    var mem_index = try index.MemoryIndex.init(std.testing.allocator, &graph);
    defer mem_index.deinit();

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var result = try neighborsWithIndex(failing.allocator(), &graph, &mem_index, file, .defines, .{ .max_visited_edges = 0 });
    defer result.deinit(failing.allocator());
    try std.testing.expectEqual(@as(usize, 0), result.neighbors.items.len);
    try std.testing.expect(result.stats.budget_exceeded);
    try std.testing.expectEqual(@as(usize, 0), failing.alloc_index);
}

test "neighbors applies zero result budget before preallocating output" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();

    const file = try graph.addNode(.file, "src/main.zig");
    const func = try graph.addNode(.function, "main");
    _ = try graph.addEdgeUnchecked(file, .defines, func);

    var mem_index = try index.MemoryIndex.init(std.testing.allocator, &graph);
    defer mem_index.deinit();

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var result = try neighborsWithIndex(failing.allocator(), &graph, &mem_index, file, .defines, .{ .max_results = 0 });
    defer result.deinit(failing.allocator());
    try std.testing.expectEqual(@as(usize, 0), result.neighbors.items.len);
    try std.testing.expect(result.stats.budget_exceeded);
    try std.testing.expectEqual(@as(usize, 0), failing.alloc_index);
}

test "neighbors can read from persistent store edge index" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    const file = try graph.addNode(.file, "src/main.zig");
    const func = try graph.addNode(.function, "main");
    const doc = try graph.addNode(.document, "README");
    const e1 = try graph.addEdgeUnchecked(file, .contains, doc);
    const e2 = try graph.addEdgeUnchecked(file, .defines, func);
    for (graph.nodes.items) |node| try store.appendNode(node);
    try store.appendEdge(graph.edges.items[e1.toInt() - 1]);
    try store.appendEdge(graph.edges.items[e2.toInt() - 1]);

    var loaded = try store.loadGraph();
    defer loaded.deinit();
    var result = try neighborsWithStore(std.testing.allocator, store, &loaded, file, .defines, .{});
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), result.neighbors.items.len);
    try std.testing.expectEqual(func.toInt(), result.neighbors.items[0].node_id.toInt());
    try std.testing.expectEqual(core.RelKind.defines, result.neighbors.items[0].rel);
}

test "neighbors persistent store uses relation-bounded edge budget" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    const file = try graph.addNode(.file, "src/main.zig");
    const func = try graph.addNode(.function, "main");
    const doc = try graph.addNode(.document, "README");
    const e1 = try graph.addEdgeUnchecked(file, .contains, doc);
    const e2 = try graph.addEdgeUnchecked(file, .defines, func);
    for (graph.nodes.items) |node| try store.appendNode(node);
    try store.appendEdge(graph.edges.items[e1.toInt() - 1]);
    try store.appendEdge(graph.edges.items[e2.toInt() - 1]);

    var result = try neighborsWithPersistentStore(std.testing.allocator, store, file, .defines, .{ .max_visited_edges = 1 });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), result.neighbors.items.len);
    try std.testing.expectEqual(func.toInt(), result.neighbors.items[0].node_id.toInt());
    try std.testing.expectEqual(@as(usize, 1), result.stats.edges_visited);
    try std.testing.expect(!result.stats.budget_exceeded);
}

const StopAfterOneContext = struct {
    calls: usize = 0,
    last_src: ?core.NodeId = null,
    last_rel: ?core.RelKind = null,
    last_dst: ?core.NodeId = null,
};

fn stopAfterOne(ctx: *StopAfterOneContext, edge: index.EdgeRef) !bool {
    ctx.calls += 1;
    ctx.last_src = edge.src;
    ctx.last_rel = edge.rel;
    ctx.last_dst = edge.dst;
    return true;
}

fn testDirExists(dir_path: []const u8) !bool {
    var dir = std.Io.Dir.cwd().openDir(std.testing.io, dir_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => |e| return e,
    };
    dir.close(std.testing.io);
    return true;
}

test "persistent edge cursor forEach stops without materializing all edges" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    const focus = try graph.addNode(.file, "src/main.zig");
    const a = try graph.addNode(.function, "a");
    const b = try graph.addNode(.function, "b");
    const e1 = try graph.addEdgeUnchecked(focus, .defines, a);
    const e2 = try graph.addEdgeUnchecked(focus, .mentions, b);
    for (graph.nodes.items) |node| try store.appendNode(node);
    try store.appendEdge(graph.edges.items[e1.toInt() - 1]);
    try store.appendEdge(graph.edges.items[e2.toInt() - 1]);

    var ctx = StopAfterOneContext{};
    const stopped = try (EdgeCursor{ .persistent_store = .{ .allocator = std.testing.allocator, .store = store } }).forEachOutgoing(focus, &ctx, stopAfterOne);
    try std.testing.expect(stopped);
    try std.testing.expectEqual(@as(usize, 1), ctx.calls);
}

test "memory edge cursor relation scan jumps to matching slice" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    const focus = try graph.addNode(.file, "src/main.zig");
    const doc = try graph.addNode(.document, "README");
    const func = try graph.addNode(.function, "main");
    _ = try graph.addEdgeUnchecked(focus, .contains, doc);
    _ = try graph.addEdgeUnchecked(focus, .defines, func);

    var mem_index = try index.MemoryIndex.init(std.testing.allocator, &graph);
    defer mem_index.deinit();

    var ctx = StopAfterOneContext{};
    const stopped = try (EdgeCursor{ .memory = .{ .mem_index = &mem_index } }).forEachOutgoingRelation(focus, .defines, &ctx, stopAfterOne);
    try std.testing.expect(stopped);
    try std.testing.expectEqual(@as(usize, 1), ctx.calls);
    try std.testing.expectEqual(core.RelKind.defines, ctx.last_rel.?);
    try std.testing.expectEqual(func.toInt(), ctx.last_dst.?.toInt());

    ctx = .{};
    try std.testing.expect(!try (EdgeCursor{ .memory = .{ .mem_index = &mem_index } }).forEachOutgoingRelation(focus, .calls, &ctx, stopAfterOne));
    try std.testing.expectEqual(@as(usize, 0), ctx.calls);
}

test "memory incoming edge cursor relation scan jumps to matching slice" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    const focus = try graph.addNode(.file, "src/main.zig");
    const doc = try graph.addNode(.document, "README");
    const blocker = try graph.addNode(.task, "blocked");
    _ = try graph.addEdgeUnchecked(doc, .mentions, focus);
    _ = try graph.addEdgeUnchecked(blocker, .blocks, focus);

    var mem_index = try index.MemoryIndex.init(std.testing.allocator, &graph);
    defer mem_index.deinit();

    var ctx = StopAfterOneContext{};
    const stopped = try (EdgeCursor{ .memory = .{ .mem_index = &mem_index } }).forEachIncomingRelation(focus, .blocks, &ctx, stopAfterOne);
    try std.testing.expect(stopped);
    try std.testing.expectEqual(@as(usize, 1), ctx.calls);
    try std.testing.expectEqual(blocker.toInt(), ctx.last_src.?.toInt());
    try std.testing.expectEqual(core.RelKind.blocks, ctx.last_rel.?);
    try std.testing.expectEqual(focus.toInt(), ctx.last_dst.?.toInt());

    ctx = .{};
    try std.testing.expect(!try (EdgeCursor{ .memory = .{ .mem_index = &mem_index } }).forEachIncomingRelation(focus, .depends_on, &ctx, stopAfterOne));
    try std.testing.expectEqual(@as(usize, 0), ctx.calls);
}

test "neighbors can use persistent store without graph argument" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    const file = try graph.addNode(.file, "src/main.zig");
    const func = try graph.addNode(.function, "main");
    const edge = try graph.addEdgeUnchecked(file, .defines, func);
    try store.appendNode(graph.nodes.items[0]);
    try store.appendNode(graph.nodes.items[1]);
    try store.appendEdge(graph.edges.items[edge.toInt() - 1]);
    try store.ensurePersistentEdgeIndexes(&graph);

    var result = try neighborsWithPersistentStore(std.testing.allocator, store, file, .defines, .{});
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), result.neighbors.items.len);
    try std.testing.expectEqual(func.toInt(), result.neighbors.items[0].node_id.toInt());
    try std.testing.expectError(core.Error.InvalidId, neighborsWithPersistentStore(std.testing.allocator, store, .none, .defines, .{}));
    try std.testing.expectError(core.Error.InvalidId, neighborsWithPersistentStore(std.testing.allocator, store, .fromInt(std.math.maxInt(u64)), .defines, .{}));

    var zero = try neighborsWithPersistentStore(std.testing.allocator, store, file, .defines, .{ .max_visited_edges = 0 });
    defer zero.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), zero.neighbors.items.len);
    try std.testing.expect(zero.stats.budget_exceeded);

    var timed_out = try neighborsWithPersistentStore(std.testing.allocator, store, file, .defines, .{ .timeout_ms = 0 });
    defer timed_out.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), timed_out.neighbors.items.len);
    try std.testing.expect(timed_out.stats.budget_exceeded);
}

test "persistent edge cursor materialization is capped" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    const file = core.NodeId.fromInt(1);
    const a = core.NodeId.fromInt(2);
    const b = core.NodeId.fromInt(3);
    try store.appendNode(.{ .id = file, .kind = .file, .text = "src/main.zig" });
    try store.appendNode(.{ .id = a, .kind = .function, .text = "a" });
    try store.appendNode(.{ .id = b, .kind = .function, .text = "b" });
    try store.appendEdge(.{ .id = .fromInt(1), .src = file, .dst = a, .rel = .defines });
    try store.appendEdge(.{ .id = .fromInt(2), .src = file, .dst = b, .rel = .defines });

    try std.testing.expectError(
        core.Error.BudgetExceeded,
        readPersistentStoreEdgeRefsLimited(std.testing.allocator, std.testing.allocator, store, .src, file, 1),
    );

    var refs = try readPersistentStoreEdgeRefsLimited(std.testing.allocator, std.testing.allocator, store, .src, file, 2);
    defer refs.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), refs.items.len);
    try std.testing.expectEqual(a.toInt(), refs.items[0].dst.toInt());
    try std.testing.expectEqual(b.toInt(), refs.items[1].dst.toInt());
}

test "persistent neighbors route through published edge segment before index fallback" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);
    const segment_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "edge-s000001" });
    defer std.testing.allocator.free(segment_path);

    var store = try storage.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    const file = core.NodeId.fromInt(1);
    const func = core.NodeId.fromInt(2);
    try store.appendNode(.{ .id = file, .kind = .file, .text = "src/main.zig" });
    try store.appendNode(.{ .id = func, .kind = .function, .text = "main" });
    try store.appendEdge(.{ .id = .fromInt(1), .src = file, .dst = func, .rel = .defines });
    try std.testing.expectEqual(@as(u64, 1), try store.publishEdgeAdjacencySegment(segment_path));

    try std.Io.Dir.cwd().deleteFile(std.testing.io, store.edge_by_src_path);

    var result = try neighborsWithPersistentStore(std.testing.allocator, store, file, .defines, .{});
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), result.neighbors.items.len);
    try std.testing.expectEqual(func.toInt(), result.neighbors.items[0].node_id.toInt());
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().openFile(std.testing.io, store.edge_by_src_path, .{}));
}

test "retained persistent query cursor protects old edge segment epoch during gc" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);
    const base_segment_path = try std.fs.path.join(std.testing.allocator, &.{ store_path, "edge_segments", "base" });
    defer std.testing.allocator.free(base_segment_path);

    var store = try storage.Store.initWithOptions(std.testing.allocator, std.testing.io, store_path, .{
        .durability = .fast,
        .validate_indexes_on_read = false,
        .auto_compact_edge_segment_entries = 0,
    });
    defer store.deinit();
    try store.createEmpty();

    const file = core.NodeId.fromInt(1);
    const base_func = core.NodeId.fromInt(2);
    const later_func = core.NodeId.fromInt(3);
    const earlier_func = core.NodeId.fromInt(4);
    try store.appendNode(.{ .id = file, .kind = .file, .text = "src/main.zig" });
    try store.appendNode(.{ .id = base_func, .kind = .function, .text = "base" });
    try store.appendNode(.{ .id = later_func, .kind = .function, .text = "later" });
    try store.appendNode(.{ .id = earlier_func, .kind = .function, .text = "earlier" });
    try store.appendEdgesBatch(&.{
        .{ .id = .fromInt(1), .src = file, .dst = base_func, .rel = .defines },
    });
    try std.testing.expectEqual(@as(u64, 1), try store.publishEdgeAdjacencySegment(base_segment_path));
    try store.appendEdgesBatch(&.{
        .{ .id = .fromInt(3), .src = file, .dst = later_func, .rel = .defines },
        .{ .id = .fromInt(2), .src = file, .dst = earlier_func, .rel = .defines },
    });

    var public_registry = storage.EdgeSegmentRetentionRegistry.init(std.testing.allocator);
    defer public_registry.deinit();
    var retained_neighbors = try neighborsWithPersistentStoreRetained(std.testing.allocator, store, &public_registry, file, .defines, .{});
    defer retained_neighbors.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), retained_neighbors.neighbors.items.len);
    {
        const active_paths = try public_registry.activeManifestPaths(std.testing.allocator);
        defer std.testing.allocator.free(active_paths);
        try std.testing.expectEqual(@as(usize, 0), active_paths.len);
    }

    var retained_path = try pathWithPersistentStoreRetained(std.testing.allocator, store, &public_registry, file, later_func, .defines, .{ .max_depth = 1 });
    defer retained_path.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), retained_path.nodes.items.len);
    {
        const active_paths = try public_registry.activeManifestPaths(std.testing.allocator);
        defer std.testing.allocator.free(active_paths);
        try std.testing.expectEqual(@as(usize, 0), active_paths.len);
    }

    var cursor_registry = storage.EdgeSegmentRetentionRegistry.init(std.testing.allocator);
    defer cursor_registry.deinit();
    const CursorGcContext = struct {
        store: storage.Store,
        registry: *storage.EdgeSegmentRetentionRegistry,
        base_segment_path: []const u8,
        ran_gc: bool = false,
        rows: usize = 0,

        fn visit(ctx: *@This(), edge: index.EdgeRef) !bool {
            _ = edge;
            ctx.rows += 1;
            if (ctx.ran_gc) return false;
            ctx.ran_gc = true;
            {
                const active_paths = try ctx.registry.activeManifestPaths(std.testing.allocator);
                defer std.testing.allocator.free(active_paths);
                try std.testing.expectEqual(@as(usize, 1), active_paths.len);
            }
            const compacted = try ctx.store.compactEdgeSegmentsBudgeted(.{ .max_segments = 2, .max_edges = 3 });
            try std.testing.expect(compacted.compacted);
            const retained_gc = try ctx.store.gcUnreferencedEdgeSegmentsRetainingRegistry(ctx.registry);
            try std.testing.expectEqual(@as(u64, 0), retained_gc.deleted_segments);
            try std.testing.expect(try testDirExists(ctx.base_segment_path));
            return false;
        }
    };
    var gc_context = CursorGcContext{
        .store = store,
        .registry = &cursor_registry,
        .base_segment_path = base_segment_path,
    };
    const routed = try (EdgeCursor{ .persistent_store = .{
        .allocator = std.testing.allocator,
        .store = store,
        .edge_retention_registry = &cursor_registry,
    } }).forEachOutgoingRelation(file, .defines, &gc_context, CursorGcContext.visit);
    try std.testing.expect(!routed);
    try std.testing.expect(gc_context.ran_gc);
    try std.testing.expectEqual(@as(usize, 3), gc_context.rows);
    {
        const active_paths = try cursor_registry.activeManifestPaths(std.testing.allocator);
        defer std.testing.allocator.free(active_paths);
        try std.testing.expectEqual(@as(usize, 0), active_paths.len);
    }

    const final_gc = try store.gcUnreferencedEdgeSegmentsRetainingRegistry(&cursor_registry);
    try std.testing.expectEqual(@as(u64, 2), final_gc.deleted_segments);
    try std.testing.expect(!try testDirExists(base_segment_path));
}

test "persistent neighbors hide tombstoned edges from opened published segment" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);
    const segment_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "edge-s000001" });
    defer std.testing.allocator.free(segment_path);

    var store = try storage.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    const file = core.NodeId.fromInt(1);
    const old_func = core.NodeId.fromInt(2);
    const live_func = core.NodeId.fromInt(3);
    try store.appendNode(.{ .id = file, .kind = .file, .text = "src/main.zig" });
    try store.appendNode(.{ .id = old_func, .kind = .function, .text = "old" });
    try store.appendNode(.{ .id = live_func, .kind = .function, .text = "live" });
    try store.appendEdgesBatch(&.{
        .{ .id = .fromInt(1), .src = file, .dst = old_func, .rel = .defines },
        .{ .id = .fromInt(2), .src = file, .dst = live_func, .rel = .defines },
    });
    try std.testing.expectEqual(@as(u64, 2), try store.publishEdgeAdjacencySegment(segment_path));
    try store.deleteEdge(.fromInt(1));
    try std.Io.Dir.cwd().deleteFile(std.testing.io, store.edge_by_src_path);

    var result = try neighborsWithPersistentStore(std.testing.allocator, store, file, .defines, .{});
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), result.neighbors.items.len);
    try std.testing.expectEqual(live_func.toInt(), result.neighbors.items[0].node_id.toInt());
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().openFile(std.testing.io, store.edge_by_src_path, .{}));
}

test "persistent delta lookup counts visible edges after tombstone filtering" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);
    const segment_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "edge-base" });
    defer std.testing.allocator.free(segment_path);

    var store = try storage.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    const base_src = core.NodeId.fromInt(1);
    const base_dst = core.NodeId.fromInt(2);
    const delta_src = core.NodeId.fromInt(3);
    const deleted_dst = core.NodeId.fromInt(4);
    const live_dst = core.NodeId.fromInt(5);
    try store.appendNodesBatch(&.{
        .{ .id = base_src, .kind = .file, .text = "base source" },
        .{ .id = base_dst, .kind = .function, .text = "base target" },
        .{ .id = delta_src, .kind = .file, .text = "delta source" },
        .{ .id = deleted_dst, .kind = .function, .text = "deleted target" },
        .{ .id = live_dst, .kind = .function, .text = "live target" },
    });
    try store.appendEdge(.{ .id = .fromInt(1), .src = base_src, .dst = base_dst, .rel = .defines });
    try std.testing.expectEqual(@as(u64, 1), try store.publishEdgeAdjacencySegment(segment_path));
    try store.appendEdgesBatch(&.{
        .{ .id = .fromInt(2), .src = delta_src, .dst = deleted_dst, .rel = .defines },
        .{ .id = .fromInt(3), .src = delta_src, .dst = live_dst, .rel = .defines },
    });
    try store.deleteEdge(.fromInt(2));

    var refs = try readPersistentStoreEdgeRefsLimited(std.testing.allocator, std.testing.allocator, store, .src, delta_src, 1);
    defer refs.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), refs.items.len);
    try std.testing.expectEqual(@as(u64, 3), refs.items[0].edge_id.toInt());
    try std.testing.expectEqual(live_dst, refs.items[0].dst);
}

test "persistent neighbors use visible full compacted segment after tombstone" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);
    const segment_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "edge-s000001" });
    defer std.testing.allocator.free(segment_path);
    const compacted_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "edge-s000002" });
    defer std.testing.allocator.free(compacted_path);

    var store = try storage.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    const file = core.NodeId.fromInt(1);
    const old_func = core.NodeId.fromInt(2);
    const live_func = core.NodeId.fromInt(3);
    try store.appendNode(.{ .id = file, .kind = .file, .text = "src/main.zig" });
    try store.appendNode(.{ .id = old_func, .kind = .function, .text = "old" });
    try store.appendNode(.{ .id = live_func, .kind = .function, .text = "live" });
    try store.appendEdgesBatch(&.{
        .{ .id = .fromInt(1), .src = file, .dst = old_func, .rel = .defines },
        .{ .id = .fromInt(2), .src = file, .dst = live_func, .rel = .defines },
    });
    try std.testing.expectEqual(@as(u64, 2), try store.publishEdgeAdjacencySegment(segment_path));
    try store.deleteEdge(.fromInt(1));
    try std.testing.expectEqual(@as(u64, 1), try store.compactPublishedEdgeSegments(compacted_path));

    var query_segments = (try store.openPublishedEdgeSegmentsForQuery(std.testing.allocator)).?;
    defer query_segments.deinit();
    try std.testing.expectEqual(storage.PublishedEdgeSegmentsCoverage.visible_full, query_segments.coverage);

    try std.Io.Dir.cwd().deleteFile(std.testing.io, store.edge_by_src_path);

    var result = try neighborsWithPersistentStore(std.testing.allocator, store, file, .defines, .{});
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), result.neighbors.items.len);
    try std.testing.expectEqual(live_func.toInt(), result.neighbors.items[0].node_id.toInt());
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().openFile(std.testing.io, store.edge_by_src_path, .{}));
}

test "persistent neighbors fall back to indexes when edge segment manifest is stale" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);
    const segment_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "edge-s000001" });
    defer std.testing.allocator.free(segment_path);

    var store = try storage.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    const file = core.NodeId.fromInt(1);
    const a = core.NodeId.fromInt(2);
    const b = core.NodeId.fromInt(3);
    try store.appendNode(.{ .id = file, .kind = .file, .text = "src/main.zig" });
    try store.appendNode(.{ .id = a, .kind = .function, .text = "a" });
    try store.appendNode(.{ .id = b, .kind = .function, .text = "b" });
    try store.appendEdge(.{ .id = .fromInt(1), .src = file, .dst = a, .rel = .defines });
    try std.testing.expectEqual(@as(u64, 1), try store.publishEdgeAdjacencySegment(segment_path));
    try store.appendEdge(.{ .id = .fromInt(2), .src = file, .dst = b, .rel = .defines });

    var result = try neighborsWithPersistentStore(std.testing.allocator, store, file, .defines, .{});
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), result.neighbors.items.len);
    try std.testing.expectEqual(a.toInt(), result.neighbors.items[0].node_id.toInt());
    try std.testing.expectEqual(b.toInt(), result.neighbors.items[1].node_id.toInt());
}

test "persistent neighbors merge implicit L0 edge segment with sorted index base" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage.Store.initWithOptions(std.testing.allocator, std.testing.io, store_path, .{
        .durability = .fast,
        .validate_indexes_on_read = false,
    });
    defer store.deinit();
    try store.createEmpty();

    const file = core.NodeId.fromInt(1);
    const base_func = core.NodeId.fromInt(2);
    const delta_func = core.NodeId.fromInt(3);
    try store.appendNode(.{ .id = file, .kind = .file, .text = "src/main.zig" });
    try store.appendNode(.{ .id = base_func, .kind = .function, .text = "base" });
    try store.appendNode(.{ .id = delta_func, .kind = .function, .text = "delta" });

    var base_edges = std.ArrayList(graph_mod.Edge).empty;
    defer base_edges.deinit(std.testing.allocator);
    try base_edges.ensureTotalCapacity(std.testing.allocator, 1024);
    var edge_id: u64 = 1;
    while (edge_id <= 1024) : (edge_id += 1) {
        base_edges.appendAssumeCapacity(.{
            .id = .fromInt(edge_id),
            .src = file,
            .dst = base_func,
            .rel = .defines,
        });
    }
    try store.appendEdgesBatch(base_edges.items);
    const src_index_size_before = try testFileSize(store.edge_by_src_path);
    const dst_index_size_before = try testFileSize(store.edge_by_dst_path);
    const id_index_size_before = try testFileSize(store.edge_by_id_path);

    try store.appendEdge(.{ .id = .fromInt(1025), .src = file, .dst = delta_func, .rel = .defines });
    try std.testing.expectEqual(src_index_size_before, try testFileSize(store.edge_by_src_path));
    try std.testing.expectEqual(dst_index_size_before, try testFileSize(store.edge_by_dst_path));
    try std.testing.expectEqual(id_index_size_before, try testFileSize(store.edge_by_id_path));

    const meta = try store.readIndexMeta();
    try std.testing.expectEqual(@as(u64, 1025), meta.edges);
    try std.testing.expectEqual(@as(u64, 1024), meta.edge_indexed_edges);
    try std.testing.expectEqual(@as(u64, 1025), meta.max_edge_id_seen);
    var full_segments = try store.openPublishedEdgeSegments(std.testing.allocator);
    if (full_segments) |*segments| segments.deinit();
    try std.testing.expect(full_segments == null);
    var query_segments = (try store.openPublishedEdgeSegmentsForQuery(std.testing.allocator)).?;
    defer query_segments.deinit();
    try std.testing.expectEqual(storage.PublishedEdgeSegmentsCoverage.delta, query_segments.coverage);

    var refs = try readPersistentStoreEdgeRefsLimited(std.testing.allocator, std.testing.allocator, store, .src, file, 1025);
    defer refs.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1025), refs.items.len);
    try std.testing.expectEqual(base_func.toInt(), refs.items[0].dst.toInt());
    try std.testing.expectEqual(delta_func.toInt(), refs.items[1024].dst.toInt());
}

test "persistent neighbors merge implicit batch L0 segments with sorted index base" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage.Store.initWithOptions(std.testing.allocator, std.testing.io, store_path, .{
        .durability = .fast,
        .validate_indexes_on_read = false,
    });
    defer store.deinit();
    try store.createEmpty();

    const file = core.NodeId.fromInt(1);
    const base_func = core.NodeId.fromInt(2);
    const delta_a = core.NodeId.fromInt(3);
    const delta_b = core.NodeId.fromInt(4);
    try store.appendNode(.{ .id = file, .kind = .file, .text = "src/main.zig" });
    try store.appendNode(.{ .id = base_func, .kind = .function, .text = "base" });
    try store.appendNode(.{ .id = delta_a, .kind = .function, .text = "delta_a" });
    try store.appendNode(.{ .id = delta_b, .kind = .function, .text = "delta_b" });

    var base_edges = std.ArrayList(graph_mod.Edge).empty;
    defer base_edges.deinit(std.testing.allocator);
    try base_edges.ensureTotalCapacity(std.testing.allocator, 1024);
    var edge_id: u64 = 1;
    while (edge_id <= 1024) : (edge_id += 1) {
        base_edges.appendAssumeCapacity(.{
            .id = .fromInt(edge_id),
            .src = file,
            .dst = base_func,
            .rel = .defines,
        });
    }
    try store.appendEdgesBatch(base_edges.items);
    const src_index_size_before = try testFileSize(store.edge_by_src_path);
    const dst_index_size_before = try testFileSize(store.edge_by_dst_path);
    const id_index_size_before = try testFileSize(store.edge_by_id_path);

    try store.appendEdgesBatch(&.{
        .{ .id = .fromInt(1025), .src = file, .dst = delta_a, .rel = .defines },
        .{ .id = .fromInt(1026), .src = file, .dst = delta_b, .rel = .defines },
    });
    try store.appendEdgesBatch(&.{
        .{ .id = .fromInt(1027), .src = file, .dst = delta_a, .rel = .defines },
        .{ .id = .fromInt(1028), .src = file, .dst = delta_b, .rel = .defines },
    });
    try std.testing.expectEqual(src_index_size_before, try testFileSize(store.edge_by_src_path));
    try std.testing.expectEqual(dst_index_size_before, try testFileSize(store.edge_by_dst_path));
    try std.testing.expectEqual(id_index_size_before, try testFileSize(store.edge_by_id_path));

    const meta = try store.readIndexMeta();
    try std.testing.expectEqual(@as(u64, 1028), meta.edges);
    try std.testing.expectEqual(@as(u64, 1024), meta.edge_indexed_edges);
    try store.validatePersistentIndexes();

    var query_segments = (try store.openPublishedEdgeSegmentsForQuery(std.testing.allocator)).?;
    defer query_segments.deinit();
    try std.testing.expectEqual(storage.PublishedEdgeSegmentsCoverage.delta, query_segments.coverage);
    try std.testing.expectEqual(@as(usize, 2), query_segments.segments.segments.items.len);

    var refs = try readPersistentStoreEdgeRefsLimited(std.testing.allocator, std.testing.allocator, store, .src, file, 1028);
    defer refs.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1028), refs.items.len);
    try std.testing.expectEqual(base_func.toInt(), refs.items[0].dst.toInt());
    try std.testing.expectEqual(delta_a.toInt(), refs.items[1024].dst.toInt());
    try std.testing.expectEqual(delta_a.toInt(), refs.items[1025].dst.toInt());
    try std.testing.expectEqual(delta_b.toInt(), refs.items[1026].dst.toInt());
    try std.testing.expectEqual(delta_b.toInt(), refs.items[1027].dst.toInt());
}

fn testFileSize(file_path: []const u8) !u64 {
    var file = try std.Io.Dir.cwd().openFile(std.testing.io, file_path, .{});
    defer file.close(std.testing.io);
    return (try file.stat(std.testing.io)).size;
}

test "memory edge cursor materialization is capped" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();

    const file = try graph.addNode(.file, "src/main.zig");
    const a = try graph.addNode(.function, "a");
    const b = try graph.addNode(.function, "b");
    _ = try graph.addEdgeUnchecked(file, .defines, a);
    _ = try graph.addEdgeUnchecked(file, .defines, b);

    var mem_index = try index.MemoryIndex.init(std.testing.allocator, &graph);
    defer mem_index.deinit();

    try std.testing.expectError(
        core.Error.BudgetExceeded,
        copyMemoryEdgeRefsLimited(std.testing.allocator, mem_index.outgoing(file), 1),
    );

    var refs = try copyMemoryEdgeRefsLimited(std.testing.allocator, mem_index.outgoing(file), 2);
    defer refs.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), refs.items.len);
    try std.testing.expectEqual(a.toInt(), refs.items[0].dst.toInt());
    try std.testing.expectEqual(b.toInt(), refs.items[1].dst.toInt());
}

test "neighbors persistent store repairs corrupt edge index" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage.Store.init(std.testing.allocator, std.testing.io, store_path);
    store.options.validate_indexes_on_read = true;
    defer store.deinit();
    try store.createEmpty();

    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    const file = try graph.addNode(.file, "src/main.zig");
    const func = try graph.addNode(.function, "main");
    const edge = try graph.addEdgeUnchecked(file, .defines, func);
    for (graph.nodes.items) |node| try store.appendNode(node);
    try store.appendEdge(graph.edges.items[edge.toInt() - 1]);

    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = store.edge_by_src_path,
        .data = "bad",
        .flags = .{ .truncate = true },
    });
    try std.testing.expectError(
        error.InvalidRecord,
        store.readEdgeIndexRecordsByNode(std.testing.allocator, .src, file),
    );

    var result = try neighborsWithPersistentStore(std.testing.allocator, store, file, .defines, .{});
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), result.neighbors.items.len);
    try std.testing.expectEqual(func.toInt(), result.neighbors.items[0].node_id.toInt());
}

test "neighbors persistent store repairs dangling target edge index" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage.Store.init(std.testing.allocator, std.testing.io, store_path);
    store.options.validate_indexes_on_read = false;
    defer store.deinit();
    try store.createEmpty();

    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    const file = try graph.addNode(.file, "src/main.zig");
    const func = try graph.addNode(.function, "main");
    const edge = try graph.addEdgeUnchecked(file, .defines, func);
    for (graph.nodes.items) |node| try store.appendNode(node);
    try store.appendEdge(graph.edges.items[edge.toInt() - 1]);

    var edge_index = try std.Io.Dir.cwd().openFile(std.testing.io, store.edge_by_src_path, .{ .mode = .read_write });
    defer edge_index.close(std.testing.io);
    var dangling_dst: [8]u8 = undefined;
    std.mem.writeInt(u64, &dangling_dst, 99, .little);
    try edge_index.writePositionalAll(std.testing.io, &dangling_dst, storage.EdgeIndexHeader.encoded_len + 8);

    var result = try neighborsWithPersistentStore(std.testing.allocator, store, file, .defines, .{});
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), result.neighbors.items.len);
    try std.testing.expectEqual(func.toInt(), result.neighbors.items[0].node_id.toInt());
}

test "path finds bounded directed path" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();

    const a = try graph.addNode(.task, "a");
    const b = try graph.addNode(.task, "b");
    const c = try graph.addNode(.task, "c");
    _ = try graph.addEdgeUnchecked(a, .depends_on, b);
    _ = try graph.addEdgeUnchecked(b, .depends_on, c);

    var result = try path(std.testing.allocator, &graph, a, c, .depends_on, .{ .max_depth = 3 });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), result.nodes.items.len);
    try std.testing.expectEqual(c.toInt(), result.nodes.items[2].toInt());
    try std.testing.expectEqual(@as(usize, 1), result.stats.results);
    try std.testing.expectError(core.Error.InvalidId, path(std.testing.allocator, &graph, .none, c, .depends_on, .{}));
    try std.testing.expectError(core.Error.InvalidId, path(std.testing.allocator, &graph, a, .none, .depends_on, .{}));
    try std.testing.expectError(core.Error.InvalidId, path(std.testing.allocator, &graph, .fromInt(std.math.maxInt(u64)), c, .depends_on, .{}));
    try std.testing.expectError(core.Error.InvalidId, path(std.testing.allocator, &graph, a, .fromInt(std.math.maxInt(u64)), .depends_on, .{}));
    try std.testing.expectError(core.Error.NotFound, path(std.testing.allocator, &graph, a, .fromInt(99), .depends_on, .{}));
}

test "path edge budget allows exactly budgeted edges" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();

    const a = try graph.addNode(.task, "a");
    const b = try graph.addNode(.task, "b");
    _ = try graph.addEdgeUnchecked(a, .depends_on, b);

    var one = try path(std.testing.allocator, &graph, a, b, .depends_on, .{ .max_depth = 1, .max_visited_edges = 1 });
    defer one.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), one.nodes.items.len);
    try std.testing.expect(!one.stats.budget_exceeded);

    var zero = try path(std.testing.allocator, &graph, a, b, .depends_on, .{ .max_depth = 1, .max_visited_edges = 0 });
    defer zero.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), zero.nodes.items.len);
    try std.testing.expect(zero.stats.budget_exceeded);
}

test "path uses relation-bounded edge budget" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();

    const a = try graph.addNode(.task, "a");
    const b = try graph.addNode(.task, "b");
    const c = try graph.addNode(.task, "c");
    _ = try graph.addEdgeUnchecked(a, .defines, c);
    _ = try graph.addEdgeUnchecked(a, .depends_on, b);

    var result = try path(std.testing.allocator, &graph, a, b, .depends_on, .{ .max_depth = 1, .max_visited_edges = 1 });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), result.nodes.items.len);
    try std.testing.expectEqual(@as(usize, 1), result.stats.edges_visited);
    try std.testing.expect(!result.stats.budget_exceeded);
}

test "path honors immediate timeout budget" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();

    const a = try graph.addNode(.task, "a");
    const b = try graph.addNode(.task, "b");
    _ = try graph.addEdgeUnchecked(a, .depends_on, b);

    var result = try path(std.testing.allocator, &graph, a, b, .depends_on, .{ .timeout_ms = 0 });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), result.nodes.items.len);
    try std.testing.expect(result.stats.budget_exceeded);
}

test "path exhausted node budget returns before allocating traversal state" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();

    const a = try graph.addNode(.task, "a");
    const b = try graph.addNode(.task, "b");
    _ = try graph.addEdgeUnchecked(a, .depends_on, b);

    var mem_index = try index.MemoryIndex.init(std.testing.allocator, &graph);
    defer mem_index.deinit();

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var result = try pathWithIndex(failing.allocator(), &graph, &mem_index, a, b, .depends_on, .{ .max_visited_nodes = 0 });
    defer result.deinit(failing.allocator());
    try std.testing.expectEqual(@as(usize, 0), result.nodes.items.len);
    try std.testing.expectEqual(@as(usize, 0), result.stats.nodes_visited);
    try std.testing.expectEqual(@as(usize, 0), result.stats.edges_visited);
    try std.testing.expect(result.stats.budget_exceeded);
}

test "path zero-hop result is not exhausted by node visit budget" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();

    const a = try graph.addNode(.task, "a");

    var result = try path(std.testing.allocator, &graph, a, a, .depends_on, .{ .max_visited_nodes = 0 });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), result.nodes.items.len);
    try std.testing.expectEqual(a.toInt(), result.nodes.items[0].toInt());
    try std.testing.expectEqual(@as(usize, 1), result.stats.results);
    try std.testing.expect(!result.stats.budget_exceeded);
}

test "path does not traverse through missing intermediate nodes" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();

    const a = try graph.addNode(.task, "a");
    const c = try graph.addNode(.task, "c");
    const missing = core.NodeId.fromInt(99);
    try graph.edges.append(std.testing.allocator, .{ .id = .fromInt(1), .src = a, .dst = missing, .rel = .depends_on });
    try graph.edges.append(std.testing.allocator, .{ .id = .fromInt(2), .src = missing, .dst = c, .rel = .depends_on });

    var result = try path(std.testing.allocator, &graph, a, c, .depends_on, .{ .max_depth = 3 });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), result.nodes.items.len);
    try std.testing.expectEqual(@as(usize, 0), result.stats.results);
}

test "path marks budget exceeded when max depth truncates matching edge" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();

    const a = try graph.addNode(.task, "a");
    const b = try graph.addNode(.task, "b");
    const c = try graph.addNode(.task, "c");
    _ = try graph.addEdgeUnchecked(a, .depends_on, b);
    _ = try graph.addEdgeUnchecked(b, .depends_on, c);

    var result = try path(std.testing.allocator, &graph, a, c, .depends_on, .{ .max_depth = 1 });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), result.nodes.items.len);
    try std.testing.expect(result.stats.budget_exceeded);
}

test "path relation-bounded depth-limit check ignores unrelated relations" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();

    const a = try graph.addNode(.task, "a");
    const b = try graph.addNode(.task, "b");
    const c = try graph.addNode(.task, "c");
    _ = try graph.addEdgeUnchecked(a, .depends_on, b);
    _ = try graph.addEdgeUnchecked(b, .defines, c);

    var result = try path(std.testing.allocator, &graph, a, c, .depends_on, .{ .max_depth = 1, .max_visited_edges = 1 });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), result.nodes.items.len);
    try std.testing.expectEqual(@as(usize, 1), result.stats.edges_visited);
    try std.testing.expect(!result.stats.budget_exceeded);
}

test "path does not mark budget exceeded at max depth leaf" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();

    const a = try graph.addNode(.task, "a");
    const b = try graph.addNode(.task, "b");
    const c = try graph.addNode(.task, "c");
    _ = try graph.addEdgeUnchecked(a, .depends_on, b);

    var leaf = try path(std.testing.allocator, &graph, a, c, .depends_on, .{ .max_depth = 1 });
    defer leaf.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), leaf.nodes.items.len);
    try std.testing.expect(!leaf.stats.budget_exceeded);

    const doc = try graph.addNode(.document, "note");
    _ = try graph.addEdgeUnchecked(b, .mentions, doc);
    var unrelated = try path(std.testing.allocator, &graph, a, c, .depends_on, .{ .max_depth = 1 });
    defer unrelated.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), unrelated.nodes.items.len);
    try std.testing.expect(!unrelated.stats.budget_exceeded);
}

test "path can read from persistent store edge index" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    const a = try graph.addNode(.task, "a");
    const b = try graph.addNode(.task, "b");
    const c = try graph.addNode(.task, "c");
    const e1 = try graph.addEdgeUnchecked(a, .depends_on, b);
    const e2 = try graph.addEdgeUnchecked(b, .depends_on, c);
    for (graph.nodes.items) |node| try store.appendNode(node);
    try store.appendEdge(graph.edges.items[e1.toInt() - 1]);
    try store.appendEdge(graph.edges.items[e2.toInt() - 1]);

    var loaded = try store.loadGraph();
    defer loaded.deinit();
    var result = try pathWithStore(std.testing.allocator, store, &loaded, a, c, .depends_on, .{ .max_depth = 3 });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), result.nodes.items.len);
    try std.testing.expectEqual(a.toInt(), result.nodes.items[0].toInt());
    try std.testing.expectEqual(c.toInt(), result.nodes.items[2].toInt());
}

test "path can use persistent store without graph argument" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    const a = try graph.addNode(.task, "a");
    const b = try graph.addNode(.task, "b");
    const c = try graph.addNode(.task, "c");
    const e1 = try graph.addEdgeUnchecked(a, .depends_on, b);
    const e2 = try graph.addEdgeUnchecked(b, .depends_on, c);
    for (graph.nodes.items) |node| try store.appendNode(node);
    try store.appendEdge(graph.edges.items[e1.toInt() - 1]);
    try store.appendEdge(graph.edges.items[e2.toInt() - 1]);
    try store.ensurePersistentEdgeIndexes(&graph);

    var result = try pathWithPersistentStore(std.testing.allocator, store, a, c, .depends_on, .{ .max_depth = 3 });
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), result.nodes.items.len);
    try std.testing.expectEqual(a.toInt(), result.nodes.items[0].toInt());
    try std.testing.expectEqual(c.toInt(), result.nodes.items[2].toInt());
    try std.testing.expectEqual(@as(usize, 1), result.stats.results);

    var one = try pathWithPersistentStore(std.testing.allocator, store, a, b, .depends_on, .{ .max_depth = 1, .max_visited_edges = 1 });
    defer one.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), one.nodes.items.len);
    try std.testing.expectEqual(@as(usize, 1), one.stats.results);
    try std.testing.expect(!one.stats.budget_exceeded);

    var shallow = try pathWithPersistentStore(std.testing.allocator, store, a, c, .depends_on, .{ .max_depth = 1 });
    defer shallow.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), shallow.nodes.items.len);
    try std.testing.expect(shallow.stats.budget_exceeded);

    var timed_out = try pathWithPersistentStore(std.testing.allocator, store, a, c, .depends_on, .{ .timeout_ms = 0 });
    defer timed_out.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), timed_out.nodes.items.len);
    try std.testing.expect(timed_out.stats.budget_exceeded);

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var exhausted = try pathWithPersistentStore(failing.allocator(), store, a, c, .depends_on, .{ .max_visited_nodes = 0 });
    defer exhausted.deinit(failing.allocator());
    try std.testing.expectEqual(@as(usize, 0), exhausted.nodes.items.len);
    try std.testing.expectEqual(@as(usize, 0), exhausted.stats.nodes_visited);
    try std.testing.expectEqual(@as(usize, 0), exhausted.stats.edges_visited);
    try std.testing.expect(exhausted.stats.budget_exceeded);

    var zero_hop = try pathWithPersistentStore(std.testing.allocator, store, a, a, .depends_on, .{ .max_visited_nodes = 0 });
    defer zero_hop.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), zero_hop.nodes.items.len);
    try std.testing.expectEqual(a.toInt(), zero_hop.nodes.items[0].toInt());
    try std.testing.expectEqual(@as(usize, 1), zero_hop.stats.results);
    try std.testing.expect(!zero_hop.stats.budget_exceeded);
}

test "path persistent store relation-bounded depth-limit check ignores unrelated relations" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    const a = core.NodeId.fromInt(1);
    const b = core.NodeId.fromInt(2);
    const c = core.NodeId.fromInt(3);
    try store.appendNode(.{ .id = a, .kind = .task, .text = "a" });
    try store.appendNode(.{ .id = b, .kind = .task, .text = "b" });
    try store.appendNode(.{ .id = c, .kind = .task, .text = "c" });
    try store.appendEdge(.{ .id = .fromInt(1), .src = a, .rel = .depends_on, .dst = b });
    try store.appendEdge(.{ .id = .fromInt(2), .src = b, .rel = .defines, .dst = c });

    var result = try pathWithPersistentStore(std.testing.allocator, store, a, c, .depends_on, .{ .max_depth = 1, .max_visited_edges = 1 });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), result.nodes.items.len);
    try std.testing.expectEqual(@as(usize, 1), result.stats.edges_visited);
    try std.testing.expect(!result.stats.budget_exceeded);
}

test "path persistent store does not mark budget exceeded at max depth leaf" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    const a = try graph.addNode(.task, "a");
    const b = try graph.addNode(.task, "b");
    const c = try graph.addNode(.task, "c");
    const edge = try graph.addEdgeUnchecked(a, .depends_on, b);
    for (graph.nodes.items) |node| try store.appendNode(node);
    try store.appendEdge(graph.edges.items[edge.toInt() - 1]);
    try store.ensurePersistentEdgeIndexes(&graph);

    var leaf = try pathWithPersistentStore(std.testing.allocator, store, a, c, .depends_on, .{ .max_depth = 1 });
    defer leaf.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), leaf.nodes.items.len);
    try std.testing.expect(!leaf.stats.budget_exceeded);
}

test "path persistent store uses relation-bounded edge budget" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    const a = core.NodeId.fromInt(1);
    const b = core.NodeId.fromInt(2);
    const c = core.NodeId.fromInt(3);
    try store.appendNode(.{ .id = a, .kind = .task, .text = "a" });
    try store.appendNode(.{ .id = b, .kind = .task, .text = "b" });
    try store.appendNode(.{ .id = c, .kind = .task, .text = "c" });
    try store.appendEdge(.{ .id = .fromInt(1), .src = a, .rel = .defines, .dst = c });
    try store.appendEdge(.{ .id = .fromInt(2), .src = a, .rel = .depends_on, .dst = b });

    var result = try pathWithPersistentStore(std.testing.allocator, store, a, b, .depends_on, .{ .max_depth = 1, .max_visited_edges = 1 });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), result.nodes.items.len);
    try std.testing.expectEqual(@as(usize, 1), result.stats.edges_visited);
    try std.testing.expect(!result.stats.budget_exceeded);
}

test "path persistent store repairs dangling target edge index" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage.Store.init(std.testing.allocator, std.testing.io, store_path);
    store.options.validate_indexes_on_read = false;
    defer store.deinit();
    try store.createEmpty();

    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    const a = try graph.addNode(.task, "a");
    const b = try graph.addNode(.task, "b");
    const edge = try graph.addEdgeUnchecked(a, .depends_on, b);
    for (graph.nodes.items) |node| try store.appendNode(node);
    try store.appendEdge(graph.edges.items[edge.toInt() - 1]);

    const edge_index_header_len = storage.EdgeIndexHeader.encoded_len;
    const edge_index_record_len = 34;
    var bytes: [edge_index_header_len + edge_index_record_len]u8 = undefined;
    @memcpy(bytes[0..4], "TKGX");
    std.mem.writeInt(u16, bytes[4..6], 2, .little);
    std.mem.writeInt(u16, bytes[6..8], edge_index_header_len, .little);
    bytes[8] = @intFromEnum(storage.EdgeIndexOrder.src);
    @memset(bytes[9..16], 0);
    std.mem.writeInt(u64, bytes[16..24], 1, .little);
    std.mem.writeInt(u64, bytes[24..32], 0, .little);
    const record_offset = edge_index_header_len;
    std.mem.writeInt(u64, bytes[record_offset + 0 .. record_offset + 8], a.toInt(), .little);
    std.mem.writeInt(u64, bytes[record_offset + 8 .. record_offset + 16], 99, .little);
    std.mem.writeInt(u64, bytes[record_offset + 16 .. record_offset + 24], edge.toInt(), .little);
    std.mem.writeInt(u16, bytes[record_offset + 24 .. record_offset + 26], @intFromEnum(core.RelKind.depends_on), .little);
    @memset(bytes[record_offset + 26 .. record_offset + 34], 0);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = store.edge_by_src_path,
        .data = &bytes,
        .flags = .{ .truncate = true },
    });

    var result = try pathWithPersistentStore(std.testing.allocator, store, a, b, .depends_on, .{ .max_depth = 1 });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), result.nodes.items.len);
    try std.testing.expectEqual(a.toInt(), result.nodes.items[0].toInt());
    try std.testing.expectEqual(b.toInt(), result.nodes.items[1].toInt());
}

test "path persistent store repairs corrupt node catalog" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage.Store.initWithOptions(std.testing.allocator, std.testing.io, store_path, .{
        .primary_text_write_mode = .bulk_ingest,
        .validate_indexes_on_read = true,
    });
    defer store.deinit();
    try store.createEmpty();

    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    const a = try graph.addNode(.task, "a");
    const b = try graph.addNode(.task, "b");
    const edge = try graph.addEdgeUnchecked(a, .depends_on, b);
    for (graph.nodes.items) |node| try store.appendNode(node);
    try store.appendEdge(graph.edges.items[edge.toInt() - 1]);

    var texts = try std.Io.Dir.cwd().createFile(std.testing.io, store.node_texts_path, .{
        .read = true,
        .truncate = false,
    });
    defer texts.close(std.testing.io);
    try texts.writePositionalAll(std.testing.io, "trailing garbage", (try texts.stat(std.testing.io)).size);
    try std.testing.expectError(error.InvalidRecord, store.readNodeById(std.testing.allocator, a));

    var result = try pathWithPersistentStore(std.testing.allocator, store, a, b, .depends_on, .{ .max_depth = 1 });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), result.nodes.items.len);
    try std.testing.expectEqual(a.toInt(), result.nodes.items[0].toInt());
    try std.testing.expectEqual(b.toInt(), result.nodes.items[1].toInt());
}
