const std = @import("std");
const core = @import("core.zig");
const segment = @import("segment.zig");
const segment_executor = @import("ql/segment_executor.zig");
const segment_manifest = @import("segment_manifest.zig");
const segment_node_index = @import("segment_node_index.zig");
const optimizer = @import("ql/optimizer.zig");
const executor = @import("ql/executor.zig");

pub const nodes_leaf = "nodes";
pub const edges_leaf = "edges";
pub const manifest_leaf = "manifest";

pub const PublishInput = struct {
    nodes: []const segment_executor.NodeInfoEntry,
    edges: []const segment.EdgeRecord,
    wal_checkpoint_bytes: u64 = 0,
};

const NodeCatalogInfo = struct {
    range: segment_manifest.IdRange,
    summary: segment_node_index.CatalogSummary,
    node_digest: u64 = 0,
};

const EdgeSegmentInfo = struct {
    count: u64,
    id_range: segment_manifest.IdRange,
    digest: u64,
};

pub const GcResult = struct {
    deleted_manifests: u64 = 0,
    deleted_trees: u64 = 0,
};

const PublishLayout = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    generation: u64,
    manifest_dir: []u8,
    nodes_leaf_path: []u8,
    edges_leaf_path: []u8,
    nodes_dir: []u8,
    edges_dir: []u8,

    fn deinit(self: *PublishLayout) void {
        self.allocator.free(self.edges_dir);
        self.allocator.free(self.nodes_dir);
        self.allocator.free(self.edges_leaf_path);
        self.allocator.free(self.nodes_leaf_path);
        self.allocator.free(self.manifest_dir);
    }

    fn cleanupGeneratedTrees(self: PublishLayout) void {
        std.Io.Dir.cwd().deleteTree(self.io, self.nodes_dir) catch {};
        std.Io.Dir.cwd().deleteTree(self.io, self.edges_dir) catch {};
    }
};

pub const Opened = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    root_dir: []u8,
    snapshot: segment_manifest.Snapshot,
    catalog: segment_node_index.MappedCatalog,
    edge_segment: EdgeSegmentSet,

    pub fn deinit(self: *Opened) void {
        self.edge_segment.deinit();
        self.catalog.deinit();
        self.snapshot.deinit(self.allocator);
        self.allocator.free(self.root_dir);
    }

    pub fn executeExactTextPath(
        self: *Opened,
        allocator: std.mem.Allocator,
        plan: optimizer.PhysicalPlan,
        budget: core.QueryBudget,
    ) !executor.ResultTable {
        return try segment_executor.executeExactTextPathWithCatalog(
            allocator,
            .{ .catalog = &self.catalog, .segment = &self.edge_segment },
            plan,
            budget,
        );
    }

    pub fn executeExactTextPathExplain(
        self: *Opened,
        allocator: std.mem.Allocator,
        plan: optimizer.PhysicalPlan,
        budget: core.QueryBudget,
        timings: *executor.OperatorTimingRecorder,
    ) !executor.ResultTable {
        return try segment_executor.executeExactTextPathWithCatalogExplain(
            allocator,
            .{ .catalog = &self.catalog, .segment = &self.edge_segment },
            plan,
            budget,
            timings,
        );
    }
};

pub const EdgeSegmentSet = struct {
    allocator: std.mem.Allocator,
    segments: std.ArrayList(segment.ImmutableAdjacencySegment) = .empty,

    pub fn deinit(self: *EdgeSegmentSet) void {
        for (self.segments.items) |*edge_segment| edge_segment.deinit();
        self.segments.deinit(self.allocator);
    }

    pub fn edgeCount(self: *EdgeSegmentSet) !u64 {
        var total: u64 = 0;
        for (self.segments.items) |*edge_segment| {
            total = std.math.add(u64, total, try edge_segment.edgeCount()) catch return error.InvalidRecord;
        }
        return total;
    }

    pub fn neighborIterator(
        self: *EdgeSegmentSet,
        direction: segment.Direction,
        node_id: core.NodeId,
        rel_filter: ?core.RelKind,
    ) !?NeighborIterator {
        if (self.segments.items.len == 0) return null;
        return .{
            .set = self,
            .direction = direction,
            .node_id = node_id,
            .rel_filter = rel_filter,
        };
    }

    pub const NeighborIterator = struct {
        set: *EdgeSegmentSet,
        direction: segment.Direction,
        node_id: core.NodeId,
        rel_filter: ?core.RelKind,
        segment_index: usize = 0,
        current: ?segment.ImmutableAdjacencySegment.NeighborIterator = null,

        pub fn next(self: *NeighborIterator) !?segment.EdgeRecord {
            while (true) {
                if (self.current) |*iterator| {
                    if (try iterator.next()) |edge| return edge;
                    self.current = null;
                }
                while (self.segment_index < self.set.segments.items.len) {
                    const index = self.segment_index;
                    self.segment_index += 1;
                    self.current = (try self.set.segments.items[index].neighborIterator(self.direction, self.node_id, self.rel_filter)) orelse continue;
                    break;
                }
                if (self.current == null) return null;
            }
        }
    };
};

pub fn publish(
    allocator: std.mem.Allocator,
    io: std.Io,
    root_dir: []const u8,
    input: PublishInput,
) !void {
    if (input.nodes.len == 0) return error.InvalidRecord;
    if (input.edges.len == 0) return error.InvalidRecord;
    var layout = try preparePublishLayout(allocator, io, root_dir);
    defer layout.deinit();
    errdefer layout.cleanupGeneratedTrees();

    const catalog_info = try writeNodeCatalog(allocator, io, layout.nodes_dir, input.nodes);
    const edge_info = try publishInputEdgeSegment(allocator, io, layout.edges_dir, input.edges);
    try publishManifest(allocator, io, layout, input.wal_checkpoint_bytes, catalog_info, edge_info);
}

const OrderedInputEdgeReader = struct {
    edges: []const segment.EdgeRecord,
    order: []const u32,

    fn read(context: OrderedInputEdgeReader, index: u64) !segment.EdgeRecord {
        const pos = std.math.cast(usize, index) orelse return error.RecordTooLarge;
        if (pos >= context.order.len) return error.InvalidRecord;
        const edge_pos: usize = @intCast(context.order[pos]);
        if (edge_pos >= context.edges.len) return error.InvalidRecord;
        return context.edges[edge_pos];
    }
};

const InputEdgeOrderState = struct {
    by_id: bool = true,
    forward: bool = true,
    reverse: bool = true,
};

fn publishInputEdgeSegment(
    allocator: std.mem.Allocator,
    io: std.Io,
    edges_dir: []const u8,
    edges: []const segment.EdgeRecord,
) !EdgeSegmentInfo {
    if (edges.len > std.math.maxInt(u32)) return error.RecordTooLarge;
    const order_state = try inputEdgeOrderState(edges);
    var order: ?[]u32 = null;
    defer if (order) |items| allocator.free(items);

    if (order_state.by_id) {
        try validateInputEdgesSortedByInputOrder(edges);
    } else {
        const id_order = try ensureInputEdgeOrder(allocator, &order, edges.len);
        std.mem.sort(u32, id_order, edges, inputEdgeIdLessThan);
        try validateInputEdgesSortedByIdOrder(edges, id_order);
    }

    var edge_segment = try segment.ImmutableAdjacencySegment.initEmpty(allocator, io, edges_dir);
    defer edge_segment.deinit();

    const forward_summary = if (order_state.forward)
        try edge_segment.writeOrderedRecordsSummary(.forward, segment.EdgeRecord, edges, inputEdgeIdentity)
    else blk: {
        const forward_order = try ensureInputEdgeOrder(allocator, &order, edges.len);
        std.mem.sort(u32, forward_order, edges, inputEdgeForwardLessThan);
        const context = OrderedInputEdgeReader{ .edges = edges, .order = forward_order };
        break :blk try edge_segment.writeOrderedRecordReaderSummary(.forward, @intCast(forward_order.len), context, OrderedInputEdgeReader.read);
    };

    const reverse_summary = if (order_state.reverse)
        try edge_segment.writeOrderedRecordsSummary(.reverse, segment.EdgeRecord, edges, inputEdgeIdentity)
    else blk: {
        const reverse_order = try ensureInputEdgeOrder(allocator, &order, edges.len);
        std.mem.sort(u32, reverse_order, edges, inputEdgeReverseLessThan);
        const context = OrderedInputEdgeReader{ .edges = edges, .order = reverse_order };
        break :blk try edge_segment.writeOrderedRecordReaderSummary(.reverse, @intCast(reverse_order.len), context, OrderedInputEdgeReader.read);
    };

    return try trustedEdgeSegmentInfo(forward_summary, reverse_summary, @intCast(edges.len));
}

fn ensureInputEdgeOrder(allocator: std.mem.Allocator, order: *?[]u32, len: usize) ![]u32 {
    if (order.* == null) order.* = try allocator.alloc(u32, len);
    const items = order.*.?;
    if (items.len != len) return error.InvalidRecord;
    for (items, 0..) |*slot, index| slot.* = @intCast(index);
    return items;
}

pub fn publishOrderedEdgeStreams(
    allocator: std.mem.Allocator,
    io: std.Io,
    root_dir: []const u8,
    nodes: []const segment_executor.NodeInfoEntry,
    edge_count: u64,
    wal_checkpoint_bytes: u64,
    forward_context: anytype,
    comptime forward_reset: fn (@TypeOf(forward_context)) anyerror!void,
    comptime forward_next: fn (@TypeOf(forward_context)) anyerror!?segment.EdgeRecord,
    reverse_context: anytype,
    comptime reverse_reset: fn (@TypeOf(reverse_context)) anyerror!void,
    comptime reverse_next: fn (@TypeOf(reverse_context)) anyerror!?segment.EdgeRecord,
) !void {
    if (nodes.len == 0) return error.InvalidRecord;
    if (edge_count == 0) return error.InvalidRecord;
    var layout = try preparePublishLayout(allocator, io, root_dir);
    defer layout.deinit();
    errdefer layout.cleanupGeneratedTrees();

    const catalog_info = try writeNodeCatalog(allocator, io, layout.nodes_dir, nodes);

    var edge_segment = try segment.ImmutableAdjacencySegment.initEmpty(allocator, io, layout.edges_dir);
    defer edge_segment.deinit();
    const forward_summary = try edge_segment.writeTrustedOrderedEdgeStreamSummary(.forward, edge_count, forward_context, forward_reset, forward_next);
    const reverse_summary = try edge_segment.writeTrustedOrderedEdgeStreamSummary(.reverse, edge_count, reverse_context, reverse_reset, reverse_next);
    const edge_info = try trustedEdgeSegmentInfo(forward_summary, reverse_summary, edge_count);

    try publishManifest(allocator, io, layout, wal_checkpoint_bytes, catalog_info, edge_info);
}

pub fn publishOrderedCatalogAndEdgeStreams(
    allocator: std.mem.Allocator,
    io: std.Io,
    root_dir: []const u8,
    node_count: u64,
    texts_context: anytype,
    comptime texts_reset: fn (@TypeOf(texts_context)) anyerror!void,
    comptime texts_next: fn (@TypeOf(texts_context)) anyerror!?[]const u8,
    node_by_id_context: anytype,
    comptime node_by_id_reset: fn (@TypeOf(node_by_id_context)) anyerror!void,
    comptime node_by_id_next: fn (@TypeOf(node_by_id_context)) anyerror!?segment_node_index.CatalogRecord,
    exact_text_context: anytype,
    comptime exact_text_reset: fn (@TypeOf(exact_text_context)) anyerror!void,
    comptime exact_text_next: fn (@TypeOf(exact_text_context)) anyerror!?segment_node_index.CatalogRecord,
    edge_count: u64,
    wal_checkpoint_bytes: u64,
    forward_context: anytype,
    comptime forward_reset: fn (@TypeOf(forward_context)) anyerror!void,
    comptime forward_next: fn (@TypeOf(forward_context)) anyerror!?segment.EdgeRecord,
    reverse_context: anytype,
    comptime reverse_reset: fn (@TypeOf(reverse_context)) anyerror!void,
    comptime reverse_next: fn (@TypeOf(reverse_context)) anyerror!?segment.EdgeRecord,
) !void {
    if (node_count == 0) return error.InvalidRecord;
    if (edge_count == 0) return error.InvalidRecord;
    var layout = try preparePublishLayout(allocator, io, root_dir);
    defer layout.deinit();
    errdefer layout.cleanupGeneratedTrees();

    const catalog_stream_info = try segment_node_index.writeCatalogFromStreamedTextsAndOrderedRecords(
        allocator,
        io,
        layout.nodes_dir,
        node_count,
        texts_context,
        texts_reset,
        texts_next,
        node_by_id_context,
        node_by_id_reset,
        node_by_id_next,
        exact_text_context,
        exact_text_reset,
        exact_text_next,
    );
    const catalog_info = NodeCatalogInfo{
        .range = catalog_stream_info.range,
        .summary = catalog_stream_info.summary,
    };
    if (catalog_info.summary.node_count != node_count) return error.InvalidRecord;

    var edge_segment = try segment.ImmutableAdjacencySegment.initEmpty(allocator, io, layout.edges_dir);
    defer edge_segment.deinit();
    const forward_summary = try edge_segment.writeTrustedOrderedEdgeStreamSummary(.forward, edge_count, forward_context, forward_reset, forward_next);
    const reverse_summary = try edge_segment.writeTrustedOrderedEdgeStreamSummary(.reverse, edge_count, reverse_context, reverse_reset, reverse_next);
    const edge_info = try trustedEdgeSegmentInfo(forward_summary, reverse_summary, edge_count);

    try publishManifest(allocator, io, layout, wal_checkpoint_bytes, catalog_info, edge_info);
}

pub fn publishTrustedOrderedCatalogAndEdgeStreams(
    allocator: std.mem.Allocator,
    io: std.Io,
    root_dir: []const u8,
    node_count: u64,
    node_digest: u64,
    texts_context: anytype,
    comptime texts_reset: fn (@TypeOf(texts_context)) anyerror!void,
    comptime texts_next: fn (@TypeOf(texts_context)) anyerror!?[]const u8,
    node_by_id_context: anytype,
    comptime node_by_id_reset: fn (@TypeOf(node_by_id_context)) anyerror!void,
    comptime node_by_id_next: fn (@TypeOf(node_by_id_context)) anyerror!?segment_node_index.CatalogRecord,
    exact_text_context: anytype,
    comptime exact_text_reset: fn (@TypeOf(exact_text_context)) anyerror!void,
    comptime exact_text_next: fn (@TypeOf(exact_text_context)) anyerror!?segment_node_index.CatalogRecord,
    edge_count: u64,
    wal_checkpoint_bytes: u64,
    forward_context: anytype,
    comptime forward_reset: fn (@TypeOf(forward_context)) anyerror!void,
    comptime forward_next: fn (@TypeOf(forward_context)) anyerror!?segment.EdgeRecord,
    reverse_context: anytype,
    comptime reverse_reset: fn (@TypeOf(reverse_context)) anyerror!void,
    comptime reverse_next: fn (@TypeOf(reverse_context)) anyerror!?segment.EdgeRecord,
) !void {
    if (node_count == 0) return error.InvalidRecord;
    if (edge_count == 0) return error.InvalidRecord;
    var layout = try preparePublishLayout(allocator, io, root_dir);
    defer layout.deinit();
    errdefer layout.cleanupGeneratedTrees();

    const catalog_stream_info = try segment_node_index.writeCatalogFromStreamedTextsAndOrderedRecords(
        allocator,
        io,
        layout.nodes_dir,
        node_count,
        texts_context,
        texts_reset,
        texts_next,
        node_by_id_context,
        node_by_id_reset,
        node_by_id_next,
        exact_text_context,
        exact_text_reset,
        exact_text_next,
    );
    const catalog_info = NodeCatalogInfo{
        .range = catalog_stream_info.range,
        .summary = catalog_stream_info.summary,
        .node_digest = node_digest,
    };
    if (catalog_info.summary.node_count != node_count) return error.InvalidRecord;

    var edge_segment = try segment.ImmutableAdjacencySegment.initEmpty(allocator, io, layout.edges_dir);
    defer edge_segment.deinit();
    const forward_summary = try edge_segment.writeTrustedOrderedEdgeStreamSummary(.forward, edge_count, forward_context, forward_reset, forward_next);
    const reverse_summary = try edge_segment.writeTrustedOrderedEdgeStreamSummary(.reverse, edge_count, reverse_context, reverse_reset, reverse_next);
    const edge_info = try trustedEdgeSegmentInfo(forward_summary, reverse_summary, edge_count);

    try publishManifest(allocator, io, layout, wal_checkpoint_bytes, catalog_info, edge_info);
}

pub fn publishTrustedOrderedCatalogAndEdgeReaders(
    allocator: std.mem.Allocator,
    io: std.Io,
    root_dir: []const u8,
    node_count: u64,
    node_digest: u64,
    texts_context: anytype,
    comptime texts_reset: fn (@TypeOf(texts_context)) anyerror!void,
    comptime texts_next: fn (@TypeOf(texts_context)) anyerror!?[]const u8,
    node_by_id_context: anytype,
    comptime node_by_id_reset: fn (@TypeOf(node_by_id_context)) anyerror!void,
    comptime node_by_id_next: fn (@TypeOf(node_by_id_context)) anyerror!?segment_node_index.CatalogRecord,
    exact_text_context: anytype,
    comptime exact_text_reset: fn (@TypeOf(exact_text_context)) anyerror!void,
    comptime exact_text_next: fn (@TypeOf(exact_text_context)) anyerror!?segment_node_index.CatalogRecord,
    edge_count: u64,
    wal_checkpoint_bytes: u64,
    forward_context: anytype,
    comptime forward_read: fn (@TypeOf(forward_context), u64) anyerror!segment.EdgeRecord,
    reverse_context: anytype,
    comptime reverse_read: fn (@TypeOf(reverse_context), u64) anyerror!segment.EdgeRecord,
) !void {
    if (node_count == 0) return error.InvalidRecord;
    if (edge_count == 0) return error.InvalidRecord;
    var layout = try preparePublishLayout(allocator, io, root_dir);
    defer layout.deinit();
    errdefer layout.cleanupGeneratedTrees();

    const catalog_stream_info = try segment_node_index.writeCatalogFromStreamedTextsAndOrderedRecords(
        allocator,
        io,
        layout.nodes_dir,
        node_count,
        texts_context,
        texts_reset,
        texts_next,
        node_by_id_context,
        node_by_id_reset,
        node_by_id_next,
        exact_text_context,
        exact_text_reset,
        exact_text_next,
    );
    const catalog_info = NodeCatalogInfo{
        .range = catalog_stream_info.range,
        .summary = catalog_stream_info.summary,
        .node_digest = node_digest,
    };
    if (catalog_info.summary.node_count != node_count) return error.InvalidRecord;

    var edge_segment = try segment.ImmutableAdjacencySegment.initEmpty(allocator, io, layout.edges_dir);
    defer edge_segment.deinit();
    const forward_summary = try edge_segment.writeOrderedRecordReaderSummary(.forward, edge_count, forward_context, forward_read);
    const reverse_summary = try edge_segment.writeOrderedRecordReaderSummary(.reverse, edge_count, reverse_context, reverse_read);
    const edge_info = try trustedEdgeSegmentInfo(forward_summary, reverse_summary, edge_count);

    try publishManifest(allocator, io, layout, wal_checkpoint_bytes, catalog_info, edge_info);
}

pub fn publishTrustedOrderedEdgeStreamsWithNodeEntry(
    allocator: std.mem.Allocator,
    io: std.Io,
    root_dir: []const u8,
    node_entry: segment_manifest.Entry,
    edge_count: u64,
    wal_checkpoint_bytes: u64,
    forward_context: anytype,
    comptime forward_reset: fn (@TypeOf(forward_context)) anyerror!void,
    comptime forward_next: fn (@TypeOf(forward_context)) anyerror!?segment.EdgeRecord,
    reverse_context: anytype,
    comptime reverse_reset: fn (@TypeOf(reverse_context)) anyerror!void,
    comptime reverse_next: fn (@TypeOf(reverse_context)) anyerror!?segment.EdgeRecord,
) !void {
    if (node_entry.kind != .node) return error.InvalidRecord;
    if (node_entry.node_count == 0) return error.InvalidRecord;
    const summary = node_entry.node_catalog_summary orelse return error.InvalidRecord;
    if (summary.node_count != node_entry.node_count) return error.InvalidRecord;
    if (edge_count == 0) return error.InvalidRecord;

    const node_dir = try checkedEntryPath(allocator, root_dir, node_entry);
    defer allocator.free(node_dir);
    const node_stat = try std.Io.Dir.cwd().statFile(io, node_dir, .{});
    if (node_stat.kind != .directory) return error.InvalidRecord;

    var layout = try preparePublishLayout(allocator, io, root_dir);
    defer layout.deinit();
    errdefer layout.cleanupGeneratedTrees();

    var edge_segment = try segment.ImmutableAdjacencySegment.initEmpty(allocator, io, layout.edges_dir);
    defer edge_segment.deinit();
    const forward_summary = try edge_segment.writeTrustedOrderedEdgeStreamSummary(.forward, edge_count, forward_context, forward_reset, forward_next);
    const reverse_summary = try edge_segment.writeTrustedOrderedEdgeStreamSummary(.reverse, edge_count, reverse_context, reverse_reset, reverse_next);
    const edge_info = try trustedEdgeSegmentInfo(forward_summary, reverse_summary, edge_count);

    try publishManifestWithNodeEntry(allocator, io, layout, wal_checkpoint_bytes, node_entry, edge_info);
}

pub fn publishTrustedOrderedEdgeReadersWithNodeEntry(
    allocator: std.mem.Allocator,
    io: std.Io,
    root_dir: []const u8,
    node_entry: segment_manifest.Entry,
    edge_count: u64,
    wal_checkpoint_bytes: u64,
    forward_context: anytype,
    comptime forward_read: fn (@TypeOf(forward_context), u64) anyerror!segment.EdgeRecord,
    reverse_context: anytype,
    comptime reverse_read: fn (@TypeOf(reverse_context), u64) anyerror!segment.EdgeRecord,
) !void {
    if (node_entry.kind != .node) return error.InvalidRecord;
    if (node_entry.node_count == 0) return error.InvalidRecord;
    const summary = node_entry.node_catalog_summary orelse return error.InvalidRecord;
    if (summary.node_count != node_entry.node_count) return error.InvalidRecord;
    if (edge_count == 0) return error.InvalidRecord;

    const node_dir = try checkedEntryPath(allocator, root_dir, node_entry);
    defer allocator.free(node_dir);
    const node_stat = try std.Io.Dir.cwd().statFile(io, node_dir, .{});
    if (node_stat.kind != .directory) return error.InvalidRecord;

    var layout = try preparePublishLayout(allocator, io, root_dir);
    defer layout.deinit();
    errdefer layout.cleanupGeneratedTrees();

    var edge_segment = try segment.ImmutableAdjacencySegment.initEmpty(allocator, io, layout.edges_dir);
    defer edge_segment.deinit();
    const forward_summary = try edge_segment.writeOrderedRecordReaderSummary(.forward, edge_count, forward_context, forward_read);
    const reverse_summary = try edge_segment.writeOrderedRecordReaderSummary(.reverse, edge_count, reverse_context, reverse_read);
    const edge_info = try trustedEdgeSegmentInfo(forward_summary, reverse_summary, edge_count);

    try publishManifestWithNodeEntry(allocator, io, layout, wal_checkpoint_bytes, node_entry, edge_info);
}

pub fn publishEdgeDeltaWithExistingEntriesStreams(
    allocator: std.mem.Allocator,
    io: std.Io,
    root_dir: []const u8,
    node_entry: segment_manifest.Entry,
    existing_edge_entries: []const segment_manifest.Entry,
    edge_count: u64,
    wal_checkpoint_bytes: u64,
    forward_context: anytype,
    comptime forward_reset: fn (@TypeOf(forward_context)) anyerror!void,
    comptime forward_next: fn (@TypeOf(forward_context)) anyerror!?segment.EdgeRecord,
    reverse_context: anytype,
    comptime reverse_reset: fn (@TypeOf(reverse_context)) anyerror!void,
    comptime reverse_next: fn (@TypeOf(reverse_context)) anyerror!?segment.EdgeRecord,
) !void {
    if (node_entry.kind != .node) return error.InvalidRecord;
    if (node_entry.node_count == 0) return error.InvalidRecord;
    const summary = node_entry.node_catalog_summary orelse return error.InvalidRecord;
    if (summary.node_count != node_entry.node_count) return error.InvalidRecord;
    if (existing_edge_entries.len == 0) return error.InvalidRecord;
    for (existing_edge_entries) |entry| {
        if (entry.kind != .edge) return error.InvalidRecord;
        if (entry.edge_count == 0) return error.InvalidRecord;
        if (!segment_manifest.safeRelativePath(entry.path)) return error.InvalidRecord;
    }
    if (edge_count == 0) return error.InvalidRecord;

    const node_dir = try checkedEntryPath(allocator, root_dir, node_entry);
    defer allocator.free(node_dir);
    const node_stat = try std.Io.Dir.cwd().statFile(io, node_dir, .{});
    if (node_stat.kind != .directory) return error.InvalidRecord;
    for (existing_edge_entries) |entry| {
        const edge_dir = try checkedEntryPath(allocator, root_dir, entry);
        defer allocator.free(edge_dir);
        const edge_stat = try std.Io.Dir.cwd().statFile(io, edge_dir, .{});
        if (edge_stat.kind != .directory) return error.InvalidRecord;
    }

    var layout = try preparePublishLayout(allocator, io, root_dir);
    defer layout.deinit();
    errdefer layout.cleanupGeneratedTrees();

    var edge_segment = try segment.ImmutableAdjacencySegment.initEmpty(allocator, io, layout.edges_dir);
    defer edge_segment.deinit();
    const forward_summary = try edge_segment.writeTrustedOrderedEdgeStreamSummary(.forward, edge_count, forward_context, forward_reset, forward_next);
    const reverse_summary = try edge_segment.writeTrustedOrderedEdgeStreamSummary(.reverse, edge_count, reverse_context, reverse_reset, reverse_next);
    const edge_info = try trustedEdgeSegmentInfo(forward_summary, reverse_summary, edge_count);
    try publishManifestWithNodeAndEdgeEntries(allocator, io, layout, wal_checkpoint_bytes, node_entry, existing_edge_entries, edge_info);
}

fn writeNodeCatalog(
    allocator: std.mem.Allocator,
    io: std.Io,
    nodes_dir: []const u8,
    nodes: []const segment_executor.NodeInfoEntry,
) !NodeCatalogInfo {
    const nodes_range = try nodeIdRange(nodes);
    try segment_node_index.writeCatalog(allocator, io, nodes_dir, nodes);
    var catalog = try segment_node_index.MappedCatalog.open(io, nodes_dir);
    defer catalog.deinit();
    return .{
        .range = nodes_range,
        .summary = catalog.summary(),
    };
}

fn trustedEdgeSegmentInfo(
    forward: segment.ImmutableAdjacencySegment.WrittenEdgeStreamSummary,
    reverse: segment.ImmutableAdjacencySegment.WrittenEdgeStreamSummary,
    expected_edge_count: u64,
) !EdgeSegmentInfo {
    if (forward.edge_count != expected_edge_count or reverse.edge_count != expected_edge_count) return error.InvalidRecord;
    const summary = try segment.ImmutableAdjacencySegment.summarizeWrittenEdgeStreams(forward, reverse);
    return .{
        .count = summary.edge_count,
        .id_range = .{ .min = summary.edge_id_summary.range.min, .max = summary.edge_id_summary.range.max },
        .digest = summary.edge_digest,
    };
}

fn inputEdgeIdLessThan(edges: []const segment.EdgeRecord, lhs: u32, rhs: u32) bool {
    return edges[@intCast(lhs)].edge_id.toInt() < edges[@intCast(rhs)].edge_id.toInt();
}

fn inputEdgeForwardLessThan(edges: []const segment.EdgeRecord, lhs: u32, rhs: u32) bool {
    const lhs_edge = edges[@intCast(lhs)];
    const rhs_edge = edges[@intCast(rhs)];
    if (lhs_edge.src.toInt() != rhs_edge.src.toInt()) return lhs_edge.src.toInt() < rhs_edge.src.toInt();
    if (@intFromEnum(lhs_edge.rel) != @intFromEnum(rhs_edge.rel)) return @intFromEnum(lhs_edge.rel) < @intFromEnum(rhs_edge.rel);
    if (lhs_edge.dst.toInt() != rhs_edge.dst.toInt()) return lhs_edge.dst.toInt() < rhs_edge.dst.toInt();
    return lhs_edge.edge_id.toInt() < rhs_edge.edge_id.toInt();
}

fn inputEdgeReverseLessThan(edges: []const segment.EdgeRecord, lhs: u32, rhs: u32) bool {
    const lhs_edge = edges[@intCast(lhs)];
    const rhs_edge = edges[@intCast(rhs)];
    if (lhs_edge.dst.toInt() != rhs_edge.dst.toInt()) return lhs_edge.dst.toInt() < rhs_edge.dst.toInt();
    if (@intFromEnum(lhs_edge.rel) != @intFromEnum(rhs_edge.rel)) return @intFromEnum(lhs_edge.rel) < @intFromEnum(rhs_edge.rel);
    if (lhs_edge.src.toInt() != rhs_edge.src.toInt()) return lhs_edge.src.toInt() < rhs_edge.src.toInt();
    return lhs_edge.edge_id.toInt() < rhs_edge.edge_id.toInt();
}

fn inputEdgeIdentity(edge: segment.EdgeRecord) !segment.EdgeRecord {
    return edge;
}

fn inputEdgeIdRecordLessThan(lhs: segment.EdgeRecord, rhs: segment.EdgeRecord) bool {
    return lhs.edge_id.toInt() < rhs.edge_id.toInt();
}

fn inputEdgeForwardRecordLessThan(lhs: segment.EdgeRecord, rhs: segment.EdgeRecord) bool {
    if (lhs.src.toInt() != rhs.src.toInt()) return lhs.src.toInt() < rhs.src.toInt();
    if (@intFromEnum(lhs.rel) != @intFromEnum(rhs.rel)) return @intFromEnum(lhs.rel) < @intFromEnum(rhs.rel);
    if (lhs.dst.toInt() != rhs.dst.toInt()) return lhs.dst.toInt() < rhs.dst.toInt();
    return lhs.edge_id.toInt() < rhs.edge_id.toInt();
}

fn inputEdgeReverseRecordLessThan(lhs: segment.EdgeRecord, rhs: segment.EdgeRecord) bool {
    if (lhs.dst.toInt() != rhs.dst.toInt()) return lhs.dst.toInt() < rhs.dst.toInt();
    if (@intFromEnum(lhs.rel) != @intFromEnum(rhs.rel)) return @intFromEnum(lhs.rel) < @intFromEnum(rhs.rel);
    if (lhs.src.toInt() != rhs.src.toInt()) return lhs.src.toInt() < rhs.src.toInt();
    return lhs.edge_id.toInt() < rhs.edge_id.toInt();
}

fn validateInputEdge(edge: segment.EdgeRecord) !void {
    const src = edge.src.toInt();
    const dst = edge.dst.toInt();
    const edge_id = edge.edge_id.toInt();
    if (src == 0 or dst == 0 or edge_id == 0) return core.Error.InvalidId;
    if (src == std.math.maxInt(u64) or dst == std.math.maxInt(u64) or edge_id == std.math.maxInt(u64)) return core.Error.InvalidId;
}

fn inputEdgeOrderState(edges: []const segment.EdgeRecord) !InputEdgeOrderState {
    var state = InputEdgeOrderState{};
    for (edges, 0..) |edge, index| {
        try validateInputEdge(edge);
        if (index == 0) continue;
        const previous = edges[index - 1];
        if (!inputEdgeIdRecordLessThan(previous, edge)) state.by_id = false;
        if (!inputEdgeForwardRecordLessThan(previous, edge)) state.forward = false;
        if (!inputEdgeReverseRecordLessThan(previous, edge)) state.reverse = false;
    }
    return state;
}

fn validateInputEdgesSortedByInputOrder(edges: []const segment.EdgeRecord) !void {
    var previous_edge_id: u64 = 0;
    for (edges, 0..) |edge, index| {
        try validateInputEdge(edge);
        const edge_id = edge.edge_id.toInt();
        if (index != 0 and edge_id <= previous_edge_id) return core.Error.InvalidId;
        previous_edge_id = edge_id;
    }
}

fn validateInputEdgesSortedByIdOrder(edges: []const segment.EdgeRecord, order: []const u32) !void {
    if (edges.len != order.len) return error.InvalidRecord;
    var previous_edge_id: u64 = 0;
    for (order, 0..) |edge_index, index| {
        const edge_pos: usize = @intCast(edge_index);
        if (edge_pos >= edges.len) return error.InvalidRecord;
        const edge = edges[edge_pos];
        try validateInputEdge(edge);
        const edge_id = edge.edge_id.toInt();
        if (index != 0 and edge_id <= previous_edge_id) return core.Error.InvalidId;
        previous_edge_id = edge_id;
    }
}

fn preparePublishLayout(allocator: std.mem.Allocator, io: std.Io, root_dir: []const u8) !PublishLayout {
    try std.Io.Dir.cwd().createDirPath(io, root_dir);
    const manifest_dir = try std.fs.path.join(allocator, &.{ root_dir, manifest_leaf });
    errdefer allocator.free(manifest_dir);

    var store = try segment_manifest.Store.init(allocator, io, manifest_dir);
    defer store.deinit();
    const generation = try store.nextGeneration();

    const nodes_leaf_path = try generationLeaf(allocator, nodes_leaf, generation);
    errdefer allocator.free(nodes_leaf_path);
    const edges_leaf_path = try generationLeaf(allocator, edges_leaf, generation);
    errdefer allocator.free(edges_leaf_path);
    const nodes_dir = try std.fs.path.join(allocator, &.{ root_dir, nodes_leaf_path });
    errdefer allocator.free(nodes_dir);
    const edges_dir = try std.fs.path.join(allocator, &.{ root_dir, edges_leaf_path });
    errdefer allocator.free(edges_dir);

    try ensurePathAbsent(io, nodes_dir);
    try ensurePathAbsent(io, edges_dir);

    return .{
        .allocator = allocator,
        .io = io,
        .generation = generation,
        .manifest_dir = manifest_dir,
        .nodes_leaf_path = nodes_leaf_path,
        .edges_leaf_path = edges_leaf_path,
        .nodes_dir = nodes_dir,
        .edges_dir = edges_dir,
    };
}

fn generationLeaf(allocator: std.mem.Allocator, prefix: []const u8, generation: u64) ![]u8 {
    if (generation == 0) return error.InvalidRecord;
    return std.fmt.allocPrint(allocator, "{s}-g{d}", .{ prefix, generation });
}

fn ensurePathAbsent(io: std.Io, path: []const u8) !void {
    _ = std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return,
        else => |e| return e,
    };
    return error.InvalidRecord;
}

fn publishManifest(
    allocator: std.mem.Allocator,
    io: std.Io,
    layout: PublishLayout,
    wal_checkpoint_bytes: u64,
    catalog_info: NodeCatalogInfo,
    edge_info: EdgeSegmentInfo,
) !void {
    try publishManifestWithNodeEntry(allocator, io, layout, wal_checkpoint_bytes, .{
        .kind = .node,
        .generation = layout.generation,
        .node_count = catalog_info.summary.node_count,
        .node_digest = catalog_info.node_digest,
        .node_range = catalog_info.range,
        .node_catalog_summary = catalog_info.summary,
        .path = layout.nodes_leaf_path,
    }, edge_info);
}

fn publishManifestWithNodeEntry(
    allocator: std.mem.Allocator,
    io: std.Io,
    layout: PublishLayout,
    wal_checkpoint_bytes: u64,
    node_entry: segment_manifest.Entry,
    edge_info: EdgeSegmentInfo,
) !void {
    try publishManifestWithNodeAndEdgeEntries(allocator, io, layout, wal_checkpoint_bytes, node_entry, &.{}, edge_info);
}

fn publishManifestWithNodeAndEdgeEntries(
    allocator: std.mem.Allocator,
    io: std.Io,
    layout: PublishLayout,
    wal_checkpoint_bytes: u64,
    node_entry: segment_manifest.Entry,
    existing_edge_entries: []const segment_manifest.Entry,
    edge_info: EdgeSegmentInfo,
) !void {
    var store = try segment_manifest.Store.init(allocator, io, layout.manifest_dir);
    defer store.deinit();
    var entries = std.ArrayList(segment_manifest.Entry).empty;
    defer entries.deinit(allocator);
    try entries.ensureTotalCapacity(allocator, 2 + existing_edge_entries.len);
    entries.appendAssumeCapacity(node_entry);
    for (existing_edge_entries) |entry| entries.appendAssumeCapacity(entry);
    entries.appendAssumeCapacity(.{
        .kind = .edge,
        .generation = layout.generation,
        .edge_count = edge_info.count,
        .edge_range = .{ .min = edge_info.id_range.min, .max = edge_info.id_range.max },
        .segment_digest = edge_info.digest,
        .path = layout.edges_leaf_path,
    });
    try store.publishExpectedGeneration(layout.generation, wal_checkpoint_bytes, entries.items);
}

pub fn openTrusted(
    allocator: std.mem.Allocator,
    io: std.Io,
    root_dir: []const u8,
) !Opened {
    const owned_root = try allocator.dupe(u8, root_dir);
    errdefer allocator.free(owned_root);
    const manifest_dir = try std.fs.path.join(allocator, &.{ owned_root, manifest_leaf });
    defer allocator.free(manifest_dir);

    var store = try segment_manifest.Store.init(allocator, io, manifest_dir);
    defer store.deinit();
    var snapshot = try store.pinCurrent();
    errdefer snapshot.deinit(allocator);

    const node_entry = try uniqueEntry(snapshot, .node);
    const edge_entries = try edgeEntries(allocator, snapshot);
    defer allocator.free(edge_entries);
    var catalog = try segment_node_index.openTrustedFromManifestEntry(allocator, io, owned_root, node_entry);
    errdefer catalog.deinit();
    var edge_set = try openTrustedEdgeSet(allocator, io, owned_root, edge_entries);
    errdefer edge_set.deinit();

    return .{
        .allocator = allocator,
        .io = io,
        .root_dir = owned_root,
        .snapshot = snapshot,
        .catalog = catalog,
        .edge_segment = edge_set,
    };
}

pub fn gcUnpinned(
    allocator: std.mem.Allocator,
    io: std.Io,
    root_dir: []const u8,
    pinned: []const segment_manifest.Snapshot,
) !GcResult {
    const manifest_dir = try std.fs.path.join(allocator, &.{ root_dir, manifest_leaf });
    defer allocator.free(manifest_dir);

    var store = try segment_manifest.Store.init(allocator, io, manifest_dir);
    defer store.deinit();
    var current = try store.pinCurrent();
    defer current.deinit(allocator);

    const manifest_gc = try store.gcUnpinned(pinned);
    var result = GcResult{ .deleted_manifests = manifest_gc.deleted_manifests };

    var live_paths = std.StringHashMap(void).init(allocator);
    defer live_paths.deinit();
    try recordSnapshotEntryPaths(&live_paths, current);
    for (pinned) |snapshot| try recordSnapshotEntryPaths(&live_paths, snapshot);

    var root = try std.Io.Dir.cwd().openDir(io, root_dir, .{ .iterate = true });
    defer root.close(io);
    var iter = root.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        if (!generationDataLeaf(entry.name)) continue;
        if (live_paths.contains(entry.name)) continue;

        const path = try std.fs.path.join(allocator, &.{ root_dir, entry.name });
        errdefer allocator.free(path);
        try std.Io.Dir.cwd().deleteTree(io, path);
        allocator.free(path);
        result.deleted_trees = try std.math.add(u64, result.deleted_trees, 1);
    }

    return result;
}

fn nodeIdRange(nodes: []const segment_executor.NodeInfoEntry) !segment_manifest.IdRange {
    if (nodes.len == 0) return error.InvalidRecord;
    var min: u64 = std.math.maxInt(u64);
    var max: u64 = 0;
    for (nodes) |node| {
        const id = node.id.toInt();
        if (id == 0) return error.InvalidRecord;
        min = @min(min, id);
        max = @max(max, id);
    }
    return .{ .min = min, .max = max };
}

fn uniqueEntry(snapshot: segment_manifest.Snapshot, kind: segment_manifest.SegmentKind) !segment_manifest.Entry {
    var found: ?segment_manifest.Entry = null;
    for (snapshot.entries.items) |entry| {
        if (entry.kind != kind) continue;
        if (found != null) return error.InvalidRecord;
        found = entry.asEntry();
    }
    return found orelse error.InvalidRecord;
}

fn edgeEntries(allocator: std.mem.Allocator, snapshot: segment_manifest.Snapshot) ![]segment_manifest.Entry {
    var count: usize = 0;
    for (snapshot.entries.items) |entry| {
        if (entry.kind == .edge) count += 1;
    }
    if (count == 0) return error.InvalidRecord;
    const entries = try allocator.alloc(segment_manifest.Entry, count);
    errdefer allocator.free(entries);
    var pos: usize = 0;
    for (snapshot.entries.items) |entry| {
        if (entry.kind != .edge) continue;
        entries[pos] = entry.asEntry();
        pos += 1;
    }
    return entries;
}

fn openTrustedEdgeSet(
    allocator: std.mem.Allocator,
    io: std.Io,
    root_dir: []const u8,
    entries: []const segment_manifest.Entry,
) !EdgeSegmentSet {
    var edge_set = EdgeSegmentSet{ .allocator = allocator };
    errdefer edge_set.deinit();
    try edge_set.segments.ensureTotalCapacity(allocator, entries.len);
    for (entries) |entry| {
        if (entry.kind != .edge or entry.edge_count == 0) return error.InvalidRecord;
        const edge_dir = try checkedEntryPath(allocator, root_dir, entry);
        defer allocator.free(edge_dir);
        edge_set.segments.appendAssumeCapacity(try segment.ImmutableAdjacencySegment.openTrustedForQuery(allocator, io, edge_dir, entry.edge_count));
    }
    return edge_set;
}

fn recordSnapshotEntryPaths(
    live_paths: *std.StringHashMap(void),
    snapshot: segment_manifest.Snapshot,
) !void {
    for (snapshot.entries.items) |entry| {
        if (!segment_manifest.safeRelativePath(entry.path)) return error.InvalidRecord;
        try live_paths.put(entry.path, {});
    }
}

fn generationDataLeaf(path: []const u8) bool {
    return generationLeafMatches(path, nodes_leaf) or generationLeafMatches(path, edges_leaf);
}

fn generationLeafMatches(path: []const u8, prefix: []const u8) bool {
    if (!std.mem.startsWith(u8, path, prefix)) return false;
    if (path.len <= prefix.len + 2) return false;
    if (path[prefix.len] != '-' or path[prefix.len + 1] != 'g') return false;
    const digits = path[prefix.len + 2 ..];
    var value: u64 = 0;
    for (digits) |byte| {
        if (byte < '0' or byte > '9') return false;
        value = std.math.mul(u64, value, 10) catch return false;
        value = std.math.add(u64, value, byte - '0') catch return false;
    }
    return value != 0;
}

fn checkedEntryPath(allocator: std.mem.Allocator, root_dir: []const u8, entry: segment_manifest.Entry) ![]u8 {
    if (!segment_manifest.safeRelativePath(entry.path)) return error.InvalidRecord;
    return try std.fs.path.join(allocator, &.{ root_dir, entry.path });
}

test "segment bundle input edge order state detects sorted directions" {
    const fully_ordered = [_]segment.EdgeRecord{
        .{ .edge_id = .fromInt(1), .src = .fromInt(1), .rel = .defines, .dst = .fromInt(10) },
        .{ .edge_id = .fromInt(2), .src = .fromInt(2), .rel = .defines, .dst = .fromInt(20) },
        .{ .edge_id = .fromInt(3), .src = .fromInt(3), .rel = .mentions, .dst = .fromInt(30) },
    };
    const fully_state = try inputEdgeOrderState(&fully_ordered);
    try std.testing.expect(fully_state.by_id);
    try std.testing.expect(fully_state.forward);
    try std.testing.expect(fully_state.reverse);
    try validateInputEdgesSortedByInputOrder(&fully_ordered);

    const forward_only = [_]segment.EdgeRecord{
        .{ .edge_id = .fromInt(3), .src = .fromInt(1), .rel = .defines, .dst = .fromInt(30) },
        .{ .edge_id = .fromInt(1), .src = .fromInt(2), .rel = .defines, .dst = .fromInt(10) },
        .{ .edge_id = .fromInt(2), .src = .fromInt(3), .rel = .mentions, .dst = .fromInt(20) },
    };
    const forward_state = try inputEdgeOrderState(&forward_only);
    try std.testing.expect(!forward_state.by_id);
    try std.testing.expect(forward_state.forward);
    try std.testing.expect(!forward_state.reverse);

    const duplicate_ids = [_]segment.EdgeRecord{
        .{ .edge_id = .fromInt(9), .src = .fromInt(1), .rel = .defines, .dst = .fromInt(10) },
        .{ .edge_id = .fromInt(9), .src = .fromInt(2), .rel = .defines, .dst = .fromInt(20) },
    };
    const duplicate_state = try inputEdgeOrderState(&duplicate_ids);
    try std.testing.expect(!duplicate_state.by_id);
    try std.testing.expectError(core.Error.InvalidId, validateInputEdgesSortedByInputOrder(&duplicate_ids));
}

test "segment bundle publishes opens and executes one-hop query" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_dir = path_buf[0..root_len];

    const nodes = [_]segment_executor.NodeInfoEntry{
        .{ .id = .fromInt(10), .kind = .file, .text = "src/main.zig" },
        .{ .id = .fromInt(20), .kind = .function, .text = "main" },
    };
    const edges = [_]segment.EdgeRecord{
        .{ .edge_id = .fromInt(7), .src = .fromInt(10), .rel = .defines, .dst = .fromInt(20) },
    };
    try publish(std.testing.allocator, std.testing.io, root_dir, .{
        .nodes = &nodes,
        .edges = &edges,
        .wal_checkpoint_bytes = 128,
    });

    var opened = try openTrusted(std.testing.allocator, std.testing.io, root_dir);
    defer opened.deinit();
    try std.testing.expectEqual(@as(u64, 128), opened.snapshot.wal_checkpoint_bytes);
    try std.testing.expectEqual(@as(u64, 10), opened.snapshot.entries.items[0].node_range.min);
    try std.testing.expectEqual(@as(u64, 20), opened.snapshot.entries.items[0].node_range.max);

    var ops = std.ArrayList(optimizer.PhysicalOp).empty;
    defer ops.deinit(std.testing.allocator);
    try ops.append(std.testing.allocator, .{ .node_lookup_by_text = .{ .var_name = "f", .kind = .file, .text = "src/main.zig" } });
    try ops.append(std.testing.allocator, .{ .expand = .{
        .left_var = "f",
        .rel = .defines,
        .right_var = "s",
        .right_kind = .function,
    } });
    try ops.append(std.testing.allocator, .{ .project = &.{} });

    var table = try opened.executeExactTextPath(std.testing.allocator, .{ .ops = ops }, .{});
    defer table.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), table.rows.items.len);
    try std.testing.expectEqual(@as(u64, 10), table.rows.items[0].get("f").?.toInt());
    try std.testing.expectEqual(@as(u64, 20), table.rows.items[0].get("s").?.toInt());
}

test "segment bundle publish sorts edge input without mutating caller slice" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_dir = path_buf[0..root_len];

    const nodes = [_]segment_executor.NodeInfoEntry{
        .{ .id = .fromInt(1), .kind = .file, .text = "src/a.zig" },
        .{ .id = .fromInt(2), .kind = .file, .text = "src/b.zig" },
        .{ .id = .fromInt(3), .kind = .function, .text = "alpha" },
        .{ .id = .fromInt(4), .kind = .function, .text = "beta" },
    };
    var edges = [_]segment.EdgeRecord{
        .{ .edge_id = .fromInt(30), .src = .fromInt(2), .rel = .defines, .dst = .fromInt(4) },
        .{ .edge_id = .fromInt(10), .src = .fromInt(1), .rel = .defines, .dst = .fromInt(3) },
        .{ .edge_id = .fromInt(20), .src = .fromInt(1), .rel = .mentions, .dst = .fromInt(4) },
    };

    try publish(std.testing.allocator, std.testing.io, root_dir, .{
        .nodes = &nodes,
        .edges = &edges,
        .wal_checkpoint_bytes = 256,
    });
    try std.testing.expectEqual(@as(u64, 30), edges[0].edge_id.toInt());
    try std.testing.expectEqual(@as(u64, 10), edges[1].edge_id.toInt());
    try std.testing.expectEqual(@as(u64, 20), edges[2].edge_id.toInt());

    var opened = try openTrusted(std.testing.allocator, std.testing.io, root_dir);
    defer opened.deinit();
    try std.testing.expectEqual(@as(u64, 3), try opened.edge_segment.edgeCount());
    const edge_entry = try uniqueEntry(opened.snapshot, .edge);
    try std.testing.expectEqual(@as(u64, 10), edge_entry.edge_range.min);
    try std.testing.expectEqual(@as(u64, 30), edge_entry.edge_range.max);

    var iter = try opened.edge_segment.segments.items[0].edgeIterator(.forward);
    const first = (try iter.next()).?;
    const second = (try iter.next()).?;
    const third = (try iter.next()).?;
    try std.testing.expectEqual(@as(u64, 10), first.edge_id.toInt());
    try std.testing.expectEqual(@as(u64, 20), second.edge_id.toInt());
    try std.testing.expectEqual(@as(u64, 30), third.edge_id.toInt());
    try std.testing.expectEqual(@as(?segment.EdgeRecord, null), try iter.next());
}

test "segment bundle publish rejects duplicate edge ids before manifest publish" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_dir = path_buf[0..root_len];

    const nodes = [_]segment_executor.NodeInfoEntry{
        .{ .id = .fromInt(1), .kind = .file, .text = "src/a.zig" },
        .{ .id = .fromInt(2), .kind = .function, .text = "alpha" },
        .{ .id = .fromInt(3), .kind = .function, .text = "beta" },
    };
    const edges = [_]segment.EdgeRecord{
        .{ .edge_id = .fromInt(10), .src = .fromInt(1), .rel = .defines, .dst = .fromInt(2) },
        .{ .edge_id = .fromInt(10), .src = .fromInt(1), .rel = .mentions, .dst = .fromInt(3) },
    };

    try std.testing.expectError(core.Error.InvalidId, publish(std.testing.allocator, std.testing.io, root_dir, .{
        .nodes = &nodes,
        .edges = &edges,
        .wal_checkpoint_bytes = 256,
    }));

    try std.testing.expectError(error.FileNotFound, openTrusted(std.testing.allocator, std.testing.io, root_dir));
    const nodes_g1 = try std.fs.path.join(std.testing.allocator, &.{ root_dir, "nodes-g1" });
    defer std.testing.allocator.free(nodes_g1);
    const edges_g1 = try std.fs.path.join(std.testing.allocator, &.{ root_dir, "edges-g1" });
    defer std.testing.allocator.free(edges_g1);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(std.testing.io, nodes_g1, .{}));
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(std.testing.io, edges_g1, .{}));
}

test "segment bundle repeated publish advances generation and preserves pinned readers" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_dir = path_buf[0..root_len];

    const nodes = [_]segment_executor.NodeInfoEntry{
        .{ .id = .fromInt(1), .kind = .file, .text = "src/lib.zig" },
        .{ .id = .fromInt(2), .kind = .function, .text = "lib" },
    };
    const edges = [_]segment.EdgeRecord{
        .{ .edge_id = .fromInt(1), .src = .fromInt(1), .rel = .defines, .dst = .fromInt(2) },
    };
    try publish(std.testing.allocator, std.testing.io, root_dir, .{
        .nodes = &nodes,
        .edges = &edges,
        .wal_checkpoint_bytes = 64,
    });

    var first = try openTrusted(std.testing.allocator, std.testing.io, root_dir);
    defer first.deinit();
    try std.testing.expectEqual(@as(u64, 1), first.snapshot.generation);
    const first_node_path = (try uniqueEntry(first.snapshot, .node)).path;
    const first_edge_path = (try uniqueEntry(first.snapshot, .edge)).path;

    const next_nodes = [_]segment_executor.NodeInfoEntry{
        .{ .id = .fromInt(10), .kind = .file, .text = "src/app.zig" },
        .{ .id = .fromInt(20), .kind = .function, .text = "app" },
    };
    const next_edges = [_]segment.EdgeRecord{
        .{ .edge_id = .fromInt(10), .src = .fromInt(10), .rel = .defines, .dst = .fromInt(20) },
    };
    try publish(std.testing.allocator, std.testing.io, root_dir, .{
        .nodes = &next_nodes,
        .edges = &next_edges,
        .wal_checkpoint_bytes = 128,
    });

    var second = try openTrusted(std.testing.allocator, std.testing.io, root_dir);
    defer second.deinit();
    try std.testing.expectEqual(@as(u64, 2), second.snapshot.generation);
    try std.testing.expectEqual(@as(u64, 64), first.snapshot.wal_checkpoint_bytes);
    try std.testing.expectEqual(@as(u64, 128), second.snapshot.wal_checkpoint_bytes);
    try std.testing.expect(!std.mem.eql(u8, first_node_path, (try uniqueEntry(second.snapshot, .node)).path));
    try std.testing.expect(!std.mem.eql(u8, first_edge_path, (try uniqueEntry(second.snapshot, .edge)).path));

    var first_ops = std.ArrayList(optimizer.PhysicalOp).empty;
    defer first_ops.deinit(std.testing.allocator);
    try first_ops.append(std.testing.allocator, .{ .node_lookup_by_text = .{ .var_name = "f", .kind = .file, .text = "src/lib.zig" } });
    try first_ops.append(std.testing.allocator, .{ .expand = .{
        .left_var = "f",
        .rel = .defines,
        .right_var = "s",
        .right_kind = .function,
    } });
    try first_ops.append(std.testing.allocator, .{ .project = &.{} });
    var first_table = try first.executeExactTextPath(std.testing.allocator, .{ .ops = first_ops }, .{});
    defer first_table.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), first_table.rows.items.len);
    try std.testing.expectEqual(@as(u64, 2), first_table.rows.items[0].get("s").?.toInt());

    var second_ops = std.ArrayList(optimizer.PhysicalOp).empty;
    defer second_ops.deinit(std.testing.allocator);
    try second_ops.append(std.testing.allocator, .{ .node_lookup_by_text = .{ .var_name = "f", .kind = .file, .text = "src/app.zig" } });
    try second_ops.append(std.testing.allocator, .{ .expand = .{
        .left_var = "f",
        .rel = .defines,
        .right_var = "s",
        .right_kind = .function,
    } });
    try second_ops.append(std.testing.allocator, .{ .project = &.{} });
    var second_table = try second.executeExactTextPath(std.testing.allocator, .{ .ops = second_ops }, .{});
    defer second_table.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), second_table.rows.items.len);
    try std.testing.expectEqual(@as(u64, 20), second_table.rows.items[0].get("s").?.toInt());
}

test "segment bundle gc removes only unpinned generation data" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_dir = path_buf[0..root_len];

    const gen1_nodes = [_]segment_executor.NodeInfoEntry{
        .{ .id = .fromInt(1), .kind = .file, .text = "src/one.zig" },
        .{ .id = .fromInt(2), .kind = .function, .text = "one" },
    };
    const gen1_edges = [_]segment.EdgeRecord{
        .{ .edge_id = .fromInt(1), .src = .fromInt(1), .rel = .defines, .dst = .fromInt(2) },
    };
    const gen2_nodes = [_]segment_executor.NodeInfoEntry{
        .{ .id = .fromInt(10), .kind = .file, .text = "src/two.zig" },
        .{ .id = .fromInt(20), .kind = .function, .text = "two" },
    };
    const gen2_edges = [_]segment.EdgeRecord{
        .{ .edge_id = .fromInt(10), .src = .fromInt(10), .rel = .defines, .dst = .fromInt(20) },
    };
    const gen3_nodes = [_]segment_executor.NodeInfoEntry{
        .{ .id = .fromInt(100), .kind = .file, .text = "src/three.zig" },
        .{ .id = .fromInt(200), .kind = .function, .text = "three" },
    };
    const gen3_edges = [_]segment.EdgeRecord{
        .{ .edge_id = .fromInt(100), .src = .fromInt(100), .rel = .defines, .dst = .fromInt(200) },
    };

    try publish(std.testing.allocator, std.testing.io, root_dir, .{ .nodes = &gen1_nodes, .edges = &gen1_edges });
    var first = try openTrusted(std.testing.allocator, std.testing.io, root_dir);
    errdefer first.deinit();
    try publish(std.testing.allocator, std.testing.io, root_dir, .{ .nodes = &gen2_nodes, .edges = &gen2_edges });
    try publish(std.testing.allocator, std.testing.io, root_dir, .{ .nodes = &gen3_nodes, .edges = &gen3_edges });

    const nodes_g1 = try std.fs.path.join(std.testing.allocator, &.{ root_dir, "nodes-g1" });
    defer std.testing.allocator.free(nodes_g1);
    const edges_g1 = try std.fs.path.join(std.testing.allocator, &.{ root_dir, "edges-g1" });
    defer std.testing.allocator.free(edges_g1);
    const nodes_g2 = try std.fs.path.join(std.testing.allocator, &.{ root_dir, "nodes-g2" });
    defer std.testing.allocator.free(nodes_g2);
    const edges_g2 = try std.fs.path.join(std.testing.allocator, &.{ root_dir, "edges-g2" });
    defer std.testing.allocator.free(edges_g2);
    const nodes_g3 = try std.fs.path.join(std.testing.allocator, &.{ root_dir, "nodes-g3" });
    defer std.testing.allocator.free(nodes_g3);
    const edges_g3 = try std.fs.path.join(std.testing.allocator, &.{ root_dir, "edges-g3" });
    defer std.testing.allocator.free(edges_g3);

    try std.testing.expectEqual(.directory, (try std.Io.Dir.cwd().statFile(std.testing.io, nodes_g1, .{})).kind);
    try std.testing.expectEqual(.directory, (try std.Io.Dir.cwd().statFile(std.testing.io, edges_g1, .{})).kind);
    try std.testing.expectEqual(.directory, (try std.Io.Dir.cwd().statFile(std.testing.io, nodes_g2, .{})).kind);
    try std.testing.expectEqual(.directory, (try std.Io.Dir.cwd().statFile(std.testing.io, edges_g2, .{})).kind);
    try std.testing.expectEqual(.directory, (try std.Io.Dir.cwd().statFile(std.testing.io, nodes_g3, .{})).kind);
    try std.testing.expectEqual(.directory, (try std.Io.Dir.cwd().statFile(std.testing.io, edges_g3, .{})).kind);

    const pinned_gc = try gcUnpinned(std.testing.allocator, std.testing.io, root_dir, &.{first.snapshot});
    try std.testing.expectEqual(@as(u64, 1), pinned_gc.deleted_manifests);
    try std.testing.expectEqual(@as(u64, 2), pinned_gc.deleted_trees);
    try std.testing.expectEqual(.directory, (try std.Io.Dir.cwd().statFile(std.testing.io, nodes_g1, .{})).kind);
    try std.testing.expectEqual(.directory, (try std.Io.Dir.cwd().statFile(std.testing.io, edges_g1, .{})).kind);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(std.testing.io, nodes_g2, .{}));
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(std.testing.io, edges_g2, .{}));
    try std.testing.expectEqual(.directory, (try std.Io.Dir.cwd().statFile(std.testing.io, nodes_g3, .{})).kind);
    try std.testing.expectEqual(.directory, (try std.Io.Dir.cwd().statFile(std.testing.io, edges_g3, .{})).kind);

    var first_ops = std.ArrayList(optimizer.PhysicalOp).empty;
    defer first_ops.deinit(std.testing.allocator);
    try first_ops.append(std.testing.allocator, .{ .node_lookup_by_text = .{ .var_name = "f", .kind = .file, .text = "src/one.zig" } });
    try first_ops.append(std.testing.allocator, .{ .expand = .{
        .left_var = "f",
        .rel = .defines,
        .right_var = "s",
        .right_kind = .function,
    } });
    try first_ops.append(std.testing.allocator, .{ .project = &.{} });
    var first_table = try first.executeExactTextPath(std.testing.allocator, .{ .ops = first_ops }, .{});
    defer first_table.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), first_table.rows.items.len);
    try std.testing.expectEqual(@as(u64, 2), first_table.rows.items[0].get("s").?.toInt());
    first.deinit();

    const final_gc = try gcUnpinned(std.testing.allocator, std.testing.io, root_dir, &.{});
    try std.testing.expectEqual(@as(u64, 1), final_gc.deleted_manifests);
    try std.testing.expectEqual(@as(u64, 2), final_gc.deleted_trees);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(std.testing.io, nodes_g1, .{}));
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(std.testing.io, edges_g1, .{}));
    try std.testing.expectEqual(.directory, (try std.Io.Dir.cwd().statFile(std.testing.io, nodes_g3, .{})).kind);
    try std.testing.expectEqual(.directory, (try std.Io.Dir.cwd().statFile(std.testing.io, edges_g3, .{})).kind);

    var current = try openTrusted(std.testing.allocator, std.testing.io, root_dir);
    defer current.deinit();
    try std.testing.expectEqual(@as(u64, 3), current.snapshot.generation);
}

const TestEdgeStream = struct {
    edges: []const segment.EdgeRecord,
    pos: usize = 0,

    fn reset(self: *TestEdgeStream) !void {
        self.pos = 0;
    }

    fn next(self: *TestEdgeStream) !?segment.EdgeRecord {
        if (self.pos >= self.edges.len) return null;
        const edge = self.edges[self.pos];
        self.pos += 1;
        return edge;
    }
};

const TestTextStream = struct {
    texts: []const []const u8,
    pos: usize = 0,

    fn reset(self: *TestTextStream) !void {
        self.pos = 0;
    }

    fn next(self: *TestTextStream) !?[]const u8 {
        if (self.pos >= self.texts.len) return null;
        const text = self.texts[self.pos];
        self.pos += 1;
        return text;
    }
};

const TestCatalogRecordStream = struct {
    records: []const segment_node_index.CatalogRecord,
    pos: usize = 0,

    fn reset(self: *TestCatalogRecordStream) !void {
        self.pos = 0;
    }

    fn next(self: *TestCatalogRecordStream) !?segment_node_index.CatalogRecord {
        if (self.pos >= self.records.len) return null;
        const record = self.records[self.pos];
        self.pos += 1;
        return record;
    }
};

test "segment bundle publishes ordered edge streams" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_dir = path_buf[0..root_len];

    const nodes = [_]segment_executor.NodeInfoEntry{
        .{ .id = .fromInt(1), .kind = .file, .text = "src/a.zig" },
        .{ .id = .fromInt(2), .kind = .file, .text = "src/b.zig" },
        .{ .id = .fromInt(3), .kind = .function, .text = "shared" },
    };
    const forward = [_]segment.EdgeRecord{
        .{ .edge_id = .fromInt(1), .src = .fromInt(1), .rel = .defines, .dst = .fromInt(3) },
        .{ .edge_id = .fromInt(2), .src = .fromInt(2), .rel = .defines, .dst = .fromInt(3) },
    };
    const reverse = [_]segment.EdgeRecord{
        .{ .edge_id = .fromInt(1), .src = .fromInt(1), .rel = .defines, .dst = .fromInt(3) },
        .{ .edge_id = .fromInt(2), .src = .fromInt(2), .rel = .defines, .dst = .fromInt(3) },
    };
    var forward_stream = TestEdgeStream{ .edges = &forward };
    var reverse_stream = TestEdgeStream{ .edges = &reverse };

    try publishOrderedEdgeStreams(
        std.testing.allocator,
        std.testing.io,
        root_dir,
        &nodes,
        forward.len,
        256,
        &forward_stream,
        TestEdgeStream.reset,
        TestEdgeStream.next,
        &reverse_stream,
        TestEdgeStream.reset,
        TestEdgeStream.next,
    );

    var opened = try openTrusted(std.testing.allocator, std.testing.io, root_dir);
    defer opened.deinit();
    try std.testing.expectEqual(@as(u64, 256), opened.snapshot.wal_checkpoint_bytes);
    try std.testing.expectEqual(@as(u64, 2), try opened.edge_segment.edgeCount());

    var ops = std.ArrayList(optimizer.PhysicalOp).empty;
    defer ops.deinit(std.testing.allocator);
    try ops.append(std.testing.allocator, .{ .node_lookup_by_text = .{ .var_name = "f", .kind = .file, .text = "src/a.zig" } });
    try ops.append(std.testing.allocator, .{ .expand = .{
        .left_var = "f",
        .rel = .defines,
        .right_var = "s",
        .right_kind = .function,
    } });
    try ops.append(std.testing.allocator, .{ .project = &.{} });

    var table = try opened.executeExactTextPath(std.testing.allocator, .{ .ops = ops }, .{});
    defer table.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), table.rows.items.len);
    try std.testing.expectEqual(@as(u64, 1), table.rows.items[0].get("f").?.toInt());
    try std.testing.expectEqual(@as(u64, 3), table.rows.items[0].get("s").?.toInt());
}

test "segment bundle trusted ordered streams reject mismatched directions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_dir = path_buf[0..root_len];

    var texts_stream = TestTextStream{ .texts = &.{ "src/a.zig", "target-a", "target-b" } };
    var nodes_stream = TestCatalogRecordStream{ .records = &.{
        .{ .id = .fromInt(1), .kind = .file, .text_offset = 0, .text_len = 9 },
        .{ .id = .fromInt(2), .kind = .function, .text_offset = 9, .text_len = 8 },
        .{ .id = .fromInt(3), .kind = .function, .text_offset = 17, .text_len = 8 },
    } };
    var exact_stream = TestCatalogRecordStream{ .records = &.{
        .{ .id = .fromInt(1), .kind = .file, .text_offset = 0, .text_len = 9 },
        .{ .id = .fromInt(2), .kind = .function, .text_offset = 9, .text_len = 8 },
        .{ .id = .fromInt(3), .kind = .function, .text_offset = 17, .text_len = 8 },
    } };
    var forward_stream = TestEdgeStream{ .edges = &.{
        .{ .edge_id = .fromInt(1), .src = .fromInt(1), .rel = .defines, .dst = .fromInt(2) },
    } };
    var reverse_stream = TestEdgeStream{ .edges = &.{
        .{ .edge_id = .fromInt(1), .src = .fromInt(1), .rel = .defines, .dst = .fromInt(3) },
    } };

    try std.testing.expectError(error.InvalidRecord, publishTrustedOrderedCatalogAndEdgeStreams(
        std.testing.allocator,
        std.testing.io,
        root_dir,
        3,
        0,
        &texts_stream,
        TestTextStream.reset,
        TestTextStream.next,
        &nodes_stream,
        TestCatalogRecordStream.reset,
        TestCatalogRecordStream.next,
        &exact_stream,
        TestCatalogRecordStream.reset,
        TestCatalogRecordStream.next,
        1,
        0,
        &forward_stream,
        TestEdgeStream.reset,
        TestEdgeStream.next,
        &reverse_stream,
        TestEdgeStream.reset,
        TestEdgeStream.next,
    ));
}

test "segment bundle trusted open rejects incomplete manifests" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_dir = path_buf[0..root_len];
    const manifest_dir = try std.fs.path.join(std.testing.allocator, &.{ root_dir, manifest_leaf });
    defer std.testing.allocator.free(manifest_dir);

    var store = try segment_manifest.Store.init(std.testing.allocator, std.testing.io, manifest_dir);
    defer store.deinit();
    _ = try store.publish(0, &.{
        .{
            .kind = .edge,
            .generation = 1,
            .edge_count = 1,
            .edge_range = .{ .min = 1, .max = 1 },
            .path = edges_leaf,
        },
    });

    try std.testing.expectError(error.InvalidRecord, openTrusted(std.testing.allocator, std.testing.io, root_dir));
}
