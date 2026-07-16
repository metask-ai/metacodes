const std = @import("std");
const core = @import("core.zig");
const graph_mod = @import("graph.zig");

pub const NodeOffset = struct {
    id: core.NodeId,
    offset: u64,
};

pub const EdgeRef = struct {
    src: core.NodeId,
    dst: core.NodeId,
    edge_id: core.EdgeId,
    rel: core.RelKind,
};

pub const QueryStats = struct {
    nodes_visited: usize = 0,
    edges_visited: usize = 0,
    results: usize = 0,
    budget_exceeded: bool = false,
    hub_truncated: bool = false,
};

pub fn addVisitedNodes(stats: *QueryStats, amount: usize) !void {
    stats.nodes_visited = std.math.add(usize, stats.nodes_visited, amount) catch return error.RecordTooLarge;
}

pub fn addVisitedEdges(stats: *QueryStats, amount: usize) !void {
    stats.edges_visited = std.math.add(usize, stats.edges_visited, amount) catch return error.RecordTooLarge;
}

pub fn edgeLessThan(_: void, lhs: EdgeRef, rhs: EdgeRef) bool {
    if (lhs.src.toInt() != rhs.src.toInt()) return lhs.src.toInt() < rhs.src.toInt();
    if (@intFromEnum(lhs.rel) != @intFromEnum(rhs.rel)) return @intFromEnum(lhs.rel) < @intFromEnum(rhs.rel);
    if (lhs.dst.toInt() != rhs.dst.toInt()) return lhs.dst.toInt() < rhs.dst.toInt();
    return lhs.edge_id.toInt() < rhs.edge_id.toInt();
}

pub fn incomingEdgeLessThan(_: void, lhs: EdgeRef, rhs: EdgeRef) bool {
    if (lhs.dst.toInt() != rhs.dst.toInt()) return lhs.dst.toInt() < rhs.dst.toInt();
    if (@intFromEnum(lhs.rel) != @intFromEnum(rhs.rel)) return @intFromEnum(lhs.rel) < @intFromEnum(rhs.rel);
    if (lhs.src.toInt() != rhs.src.toInt()) return lhs.src.toInt() < rhs.src.toInt();
    return lhs.edge_id.toInt() < rhs.edge_id.toInt();
}

test "query stats checked increments reject overflow" {
    var stats = QueryStats{ .nodes_visited = std.math.maxInt(usize) };
    try std.testing.expectError(error.RecordTooLarge, addVisitedNodes(&stats, 1));
    try std.testing.expectEqual(std.math.maxInt(usize), stats.nodes_visited);

    stats = .{ .edges_visited = std.math.maxInt(usize) };
    try std.testing.expectError(error.RecordTooLarge, addVisitedEdges(&stats, 1));
    try std.testing.expectEqual(std.math.maxInt(usize), stats.edges_visited);

    try addVisitedNodes(&stats, 2);
    try addVisitedEdges(&stats, 0);
    try std.testing.expectEqual(@as(usize, 2), stats.nodes_visited);
    try std.testing.expectEqual(std.math.maxInt(usize), stats.edges_visited);
}

pub const MemoryIndex = struct {
    allocator: std.mem.Allocator,
    node_by_id: std.AutoHashMap(u64, usize),
    node_ids_by_text: std.StringHashMap(std.ArrayList(core.NodeId)),
    node_ids_by_kind_text: std.StringHashMap(std.ArrayList(core.NodeId)),
    edge_ids: std.AutoHashMap(u64, void),
    out_edges: std.AutoHashMap(u64, std.ArrayList(EdgeRef)),
    in_edges: std.AutoHashMap(u64, std.ArrayList(EdgeRef)),
    owned_keys: std.ArrayList([]u8),

    pub fn init(allocator: std.mem.Allocator, graph: *const graph_mod.Graph) !MemoryIndex {
        var self = MemoryIndex{
            .allocator = allocator,
            .node_by_id = std.AutoHashMap(u64, usize).init(allocator),
            .node_ids_by_text = std.StringHashMap(std.ArrayList(core.NodeId)).init(allocator),
            .node_ids_by_kind_text = std.StringHashMap(std.ArrayList(core.NodeId)).init(allocator),
            .edge_ids = std.AutoHashMap(u64, void).init(allocator),
            .out_edges = std.AutoHashMap(u64, std.ArrayList(EdgeRef)).init(allocator),
            .in_edges = std.AutoHashMap(u64, std.ArrayList(EdgeRef)).init(allocator),
            .owned_keys = .empty,
        };
        errdefer self.deinit();

        for (graph.nodes.items, 0..) |node, node_index| {
            try self.addNode(node, node_index);
        }

        for (graph.edges.items) |edge| {
            if (!self.edgeEndpointsIndexed(edge)) continue;
            try self.addEdgeRecord(edge);
        }

        var out_it = self.out_edges.valueIterator();
        while (out_it.next()) |edges| std.mem.sort(EdgeRef, edges.items, {}, edgeLessThan);
        var in_it = self.in_edges.valueIterator();
        while (in_it.next()) |edges| std.mem.sort(EdgeRef, edges.items, {}, incomingEdgeLessThan);
        return self;
    }

    pub fn deinit(self: *MemoryIndex) void {
        var out_it = self.out_edges.valueIterator();
        while (out_it.next()) |edges| edges.deinit(self.allocator);
        self.out_edges.deinit();
        var in_it = self.in_edges.valueIterator();
        while (in_it.next()) |edges| edges.deinit(self.allocator);
        self.in_edges.deinit();
        self.edge_ids.deinit();
        self.node_by_id.deinit();
        var text_ids_it = self.node_ids_by_text.valueIterator();
        while (text_ids_it.next()) |ids| ids.deinit(self.allocator);
        self.node_ids_by_text.deinit();
        var kind_text_ids_it = self.node_ids_by_kind_text.valueIterator();
        while (kind_text_ids_it.next()) |ids| ids.deinit(self.allocator);
        self.node_ids_by_kind_text.deinit();
        for (self.owned_keys.items) |key| self.allocator.free(key);
        self.owned_keys.deinit(self.allocator);
    }

    pub fn findByText(self: *MemoryIndex, kind_filter: ?core.NodeKind, text: []const u8) !?core.NodeId {
        const ids = try self.lookupByText(kind_filter, text);
        if (ids.len == 0) return null;
        return ids[0];
    }

    pub fn lookupByText(self: *MemoryIndex, kind_filter: ?core.NodeKind, text: []const u8) ![]const core.NodeId {
        if (kind_filter) |kind| {
            const key = try self.kindTextKey(kind, text);
            defer self.allocator.free(key);
            const ids = self.node_ids_by_kind_text.getPtr(key) orelse return &.{};
            return ids.items;
        }
        const ids = self.node_ids_by_text.getPtr(text) orelse return &.{};
        return ids.items;
    }

    pub fn addNode(self: *MemoryIndex, node: graph_mod.Node, node_index: usize) !void {
        if (node.status != .active) return;
        if (node.id == .none or node.id.toInt() == std.math.maxInt(u64)) return core.Error.InvalidId;
        if (self.node_by_id.contains(node.id.toInt())) return core.Error.InvalidId;
        var inserted_node_by_id = false;
        var text_ids_created = false;
        var text_id_appended = false;
        errdefer {
            if (text_id_appended) self.rollbackNodeIdAppend(&self.node_ids_by_text, node.text, node.id, text_ids_created);
            if (inserted_node_by_id) _ = self.node_by_id.remove(node.id.toInt());
        }

        try self.node_by_id.put(node.id.toInt(), node_index);
        inserted_node_by_id = true;
        text_ids_created = try self.appendNodeIdTracked(&self.node_ids_by_text, node.text, node.id);
        text_id_appended = true;

        const key = try self.kindTextKey(node.kind, node.text);
        var key_owned = true;
        errdefer if (key_owned) self.allocator.free(key);
        if (self.node_ids_by_kind_text.getPtr(key)) |ids| {
            self.allocator.free(key);
            key_owned = false;
            try ids.append(self.allocator, node.id);
            std.mem.sort(core.NodeId, ids.items, {}, nodeIdLessThan);
        } else {
            var ids = std.ArrayList(core.NodeId).empty;
            try ids.append(self.allocator, node.id);
            var ids_in_map = false;
            errdefer if (!ids_in_map) ids.deinit(self.allocator);
            var key_in_owned_keys = false;
            var committed = false;
            errdefer {
                if (!committed) {
                    if (key_in_owned_keys) {
                        _ = self.owned_keys.pop();
                        self.allocator.free(key);
                    }
                }
            }
            try self.owned_keys.append(self.allocator, key);
            key_in_owned_keys = true;
            key_owned = false;
            try self.node_ids_by_kind_text.put(key, ids);
            ids_in_map = true;
            errdefer {
                if (self.node_ids_by_kind_text.getPtr(key)) |stored_ids| stored_ids.deinit(self.allocator);
                _ = self.node_ids_by_kind_text.remove(key);
            }
            committed = true;
        }
    }

    pub fn addEdgeRecord(self: *MemoryIndex, edge: graph_mod.Edge) !void {
        if (edge.status != .active) return;
        if (edge.id == .none or edge.id.toInt() == std.math.maxInt(u64)) return core.Error.InvalidId;
        if (edge.src == .none or edge.dst == .none) return core.Error.InvalidId;
        if (edge.src.toInt() == std.math.maxInt(u64) or edge.dst.toInt() == std.math.maxInt(u64)) return core.Error.InvalidId;
        if (!self.edgeEndpointsIndexed(edge)) return core.Error.NotFound;
        if (self.edge_ids.contains(edge.id.toInt())) return core.Error.InvalidId;
        const ref = EdgeRef{ .src = edge.src, .dst = edge.dst, .edge_id = edge.id, .rel = edge.rel };
        try self.edge_ids.ensureUnusedCapacity(1);
        var out_created = false;
        var out_appended = false;
        errdefer if (out_appended) self.rollbackEdgeRefAppend(&self.out_edges, edge.src.toInt(), ref, out_created);
        out_created = try self.appendEdgeRefTracked(&self.out_edges, edge.src.toInt(), ref, edgeLessThan);
        out_appended = true;
        _ = try self.appendEdgeRefTracked(&self.in_edges, edge.dst.toInt(), ref, incomingEdgeLessThan);
        self.edge_ids.putAssumeCapacityNoClobber(edge.id.toInt(), {});
    }

    fn edgeEndpointsIndexed(self: *MemoryIndex, edge: graph_mod.Edge) bool {
        return self.node_by_id.contains(edge.src.toInt()) and self.node_by_id.contains(edge.dst.toInt());
    }

    pub fn getNode(self: MemoryIndex, graph: *const graph_mod.Graph, id: core.NodeId) ?graph_mod.Node {
        const node_index = self.node_by_id.get(id.toInt()) orelse return null;
        if (node_index >= graph.nodes.items.len) return null;
        const node = graph.nodes.items[node_index];
        if (node.status != .active or node.id.toInt() != id.toInt()) return null;
        return node;
    }

    pub fn outgoing(self: *MemoryIndex, node: core.NodeId) []const EdgeRef {
        const edges = self.out_edges.getPtr(node.toInt()) orelse return &.{};
        return edges.items;
    }

    pub fn outgoingRelation(self: *MemoryIndex, node: core.NodeId, rel: core.RelKind) []const EdgeRef {
        const edges = self.out_edges.getPtr(node.toInt()) orelse return &.{};
        return edgeRelationSlice(edges.items, rel);
    }

    pub fn incoming(self: *MemoryIndex, node: core.NodeId) []const EdgeRef {
        const edges = self.in_edges.getPtr(node.toInt()) orelse return &.{};
        return edges.items;
    }

    pub fn incomingRelation(self: *MemoryIndex, node: core.NodeId, rel: core.RelKind) []const EdgeRef {
        const edges = self.in_edges.getPtr(node.toInt()) orelse return &.{};
        return edgeRelationSlice(edges.items, rel);
    }

    fn kindTextKey(self: *MemoryIndex, kind: core.NodeKind, text: []const u8) ![]u8 {
        return std.fmt.allocPrint(self.allocator, "{d}\x1f{s}", .{ @intFromEnum(kind), text });
    }

    fn appendEdgeRefTracked(self: *MemoryIndex, map: *std.AutoHashMap(u64, std.ArrayList(EdgeRef)), key: u64, ref: EdgeRef, comptime less_than: fn (void, EdgeRef, EdgeRef) bool) !bool {
        const entry = try map.getOrPut(key);
        if (!entry.found_existing) entry.value_ptr.* = .empty;
        entry.value_ptr.append(self.allocator, ref) catch |err| {
            if (!entry.found_existing) {
                entry.value_ptr.deinit(self.allocator);
                _ = map.remove(key);
            }
            return err;
        };
        std.mem.sort(EdgeRef, entry.value_ptr.items, {}, less_than);
        return !entry.found_existing;
    }

    fn rollbackEdgeRefAppend(self: *MemoryIndex, map: *std.AutoHashMap(u64, std.ArrayList(EdgeRef)), key: u64, ref: EdgeRef, created: bool) void {
        if (map.getPtr(key)) |edges| {
            if (created) {
                edges.deinit(self.allocator);
                _ = map.remove(key);
            } else {
                removeEdgeRef(edges, ref);
            }
        }
    }

    fn appendNodeId(self: *MemoryIndex, map: *std.StringHashMap(std.ArrayList(core.NodeId)), key: []const u8, id: core.NodeId) !void {
        _ = try self.appendNodeIdTracked(map, key, id);
    }

    fn appendNodeIdTracked(self: *MemoryIndex, map: *std.StringHashMap(std.ArrayList(core.NodeId)), key: []const u8, id: core.NodeId) !bool {
        if (map.getPtr(key)) |ids| {
            try ids.append(self.allocator, id);
            std.mem.sort(core.NodeId, ids.items, {}, nodeIdLessThan);
            return false;
        }

        var ids = std.ArrayList(core.NodeId).empty;
        errdefer ids.deinit(self.allocator);
        try ids.append(self.allocator, id);

        const owned_key = try self.allocator.dupe(u8, key);
        var owned_key_owned = true;
        errdefer if (owned_key_owned) self.allocator.free(owned_key);

        try self.owned_keys.append(self.allocator, owned_key);
        var key_registered = true;
        errdefer if (key_registered) {
            _ = self.owned_keys.pop();
        };

        try map.put(owned_key, ids);
        owned_key_owned = false;
        key_registered = false;
        return true;
    }

    fn rollbackNodeIdAppend(self: *MemoryIndex, map: *std.StringHashMap(std.ArrayList(core.NodeId)), key: []const u8, id: core.NodeId, created: bool) void {
        if (map.getPtr(key)) |ids| {
            if (created) {
                const stored_key = map.getKey(key);
                ids.deinit(self.allocator);
                _ = map.remove(key);
                if (stored_key) |owned_key| self.removeOwnedKey(owned_key);
            } else {
                removeNodeId(ids, id);
            }
        }
    }

    fn removeOwnedKey(self: *MemoryIndex, key: []const u8) void {
        for (self.owned_keys.items, 0..) |owned_key, i| {
            if (owned_key.ptr != key.ptr) continue;
            _ = self.owned_keys.orderedRemove(i);
            self.allocator.free(owned_key);
            return;
        }
    }
};

fn nodeIdLessThan(_: void, lhs: core.NodeId, rhs: core.NodeId) bool {
    return lhs.toInt() < rhs.toInt();
}

fn edgeRefEqual(lhs: EdgeRef, rhs: EdgeRef) bool {
    return lhs.src == rhs.src and lhs.dst == rhs.dst and lhs.edge_id == rhs.edge_id and lhs.rel == rhs.rel;
}

fn edgeRelationSlice(edges: []const EdgeRef, rel: core.RelKind) []const EdgeRef {
    const rel_value: usize = @intFromEnum(rel);
    const start = lowerBoundRel(edges, rel_value);
    const end = lowerBoundRel(edges[start..], rel_value + 1);
    return edges[start .. start + end];
}

fn lowerBoundRel(edges: []const EdgeRef, rel_value: usize) usize {
    var lo: usize = 0;
    var hi: usize = edges.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        if (@as(usize, @intFromEnum(edges[mid].rel)) < rel_value) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    return lo;
}

fn removeEdgeRef(edges: *std.ArrayList(EdgeRef), ref: EdgeRef) void {
    for (edges.items, 0..) |item, i| {
        if (!edgeRefEqual(item, ref)) continue;
        _ = edges.orderedRemove(i);
        return;
    }
}

fn removeNodeId(ids: *std.ArrayList(core.NodeId), id: core.NodeId) void {
    for (ids.items, 0..) |item, i| {
        if (item != id) continue;
        _ = ids.orderedRemove(i);
        return;
    }
}

test "edge ordering groups adjacency by source then relation" {
    var edges = [_]EdgeRef{
        .{ .src = .fromInt(2), .dst = .fromInt(1), .edge_id = .fromInt(1), .rel = .defines },
        .{ .src = .fromInt(1), .dst = .fromInt(3), .edge_id = .fromInt(2), .rel = .calls },
        .{ .src = .fromInt(1), .dst = .fromInt(2), .edge_id = .fromInt(3), .rel = .defines },
    };
    std.mem.sort(EdgeRef, &edges, {}, edgeLessThan);
    try std.testing.expectEqual(@as(u64, 1), edges[0].src.toInt());
    try std.testing.expectEqual(core.RelKind.defines, edges[0].rel);
}

test "edge ordering tie-breaks parallel edges by edge id" {
    var edges = [_]EdgeRef{
        .{ .src = .fromInt(1), .dst = .fromInt(2), .edge_id = .fromInt(10), .rel = .depends_on },
        .{ .src = .fromInt(1), .dst = .fromInt(2), .edge_id = .fromInt(3), .rel = .depends_on },
    };

    std.mem.sort(EdgeRef, &edges, {}, edgeLessThan);

    try std.testing.expectEqual(@as(u64, 3), edges[0].edge_id.toInt());
    try std.testing.expectEqual(@as(u64, 10), edges[1].edge_id.toInt());
}

test "incoming edge ordering groups adjacency by destination then relation" {
    var edges = [_]EdgeRef{
        .{ .src = .fromInt(9), .dst = .fromInt(1), .edge_id = .fromInt(1), .rel = .mentions },
        .{ .src = .fromInt(7), .dst = .fromInt(1), .edge_id = .fromInt(2), .rel = .defines },
        .{ .src = .fromInt(8), .dst = .fromInt(1), .edge_id = .fromInt(3), .rel = .defines },
    };
    std.mem.sort(EdgeRef, &edges, {}, incomingEdgeLessThan);
    try std.testing.expectEqual(core.RelKind.defines, edges[0].rel);
    try std.testing.expectEqual(@as(u64, 7), edges[0].src.toInt());
    try std.testing.expectEqual(core.RelKind.defines, edges[1].rel);
    try std.testing.expectEqual(@as(u64, 8), edges[1].src.toInt());
    try std.testing.expectEqual(core.RelKind.mentions, edges[2].rel);
}

test "memory index supports text lookup and adjacency" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    const file = try graph.addNode(.file, "src/main.zig");
    const func = try graph.addNode(.function, "main");
    _ = try graph.addEdgeUnchecked(file, .defines, func);

    var mem = try MemoryIndex.init(std.testing.allocator, &graph);
    defer mem.deinit();

    try std.testing.expectEqual(file.toInt(), (try mem.findByText(.file, "src/main.zig")).?.toInt());
    try std.testing.expectEqualStrings("main", mem.getNode(&graph, func).?.text);
    try std.testing.expectEqual(func.toInt(), mem.outgoing(file)[0].dst.toInt());
    try std.testing.expectEqual(file.toInt(), mem.incoming(func)[0].src.toInt());
}

test "memory index supports incremental node and edge updates" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    var mem = try MemoryIndex.init(std.testing.allocator, &graph);
    defer mem.deinit();

    const file = try graph.addNode(.file, "src/main.zig");
    try mem.addNode(graph.nodes.items[0], 0);
    const func = try graph.addNode(.function, "main");
    try mem.addNode(graph.nodes.items[1], 1);
    _ = try graph.addEdgeUnchecked(file, .defines, func);
    try mem.addEdgeRecord(graph.edges.items[0]);

    try std.testing.expectEqual(file.toInt(), (try mem.findByText(.file, "src/main.zig")).?.toInt());
    try std.testing.expectEqual(func.toInt(), mem.outgoing(file)[0].dst.toInt());
    try std.testing.expectEqual(file.toInt(), mem.incoming(func)[0].src.toInt());
}

test "memory index rejects duplicate node ids without overwriting existing entry" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    try graph.addNodeWithId(.fromInt(10), .file, "first.zig");
    try graph.addNodeWithId(.fromInt(2), .file, "second.zig");

    var mem = try MemoryIndex.init(std.testing.allocator, &graph);
    defer mem.deinit();

    try std.testing.expectError(core.Error.InvalidId, mem.addNode(.{
        .id = .fromInt(10),
        .kind = .file,
        .text = "duplicate.zig",
    }, 1));

    try std.testing.expectEqualStrings("first.zig", mem.getNode(&graph, .fromInt(10)).?.text);
    const matches = try mem.lookupByText(.file, "duplicate.zig");
    try std.testing.expectEqual(@as(usize, 0), matches.len);
}

test "memory index rejects reserved node ids" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();

    var mem = try MemoryIndex.init(std.testing.allocator, &graph);
    defer mem.deinit();

    try std.testing.expectError(core.Error.InvalidId, mem.addNode(.{
        .id = .none,
        .kind = .file,
        .text = "zero.zig",
    }, 0));

    try std.testing.expectEqual(@as(usize, 0), (try mem.lookupByText(.file, "zero.zig")).len);
    try std.testing.expect(mem.getNode(&graph, .none) == null);
    try std.testing.expectError(core.Error.InvalidId, mem.addNode(.{
        .id = .fromInt(std.math.maxInt(u64)),
        .kind = .file,
        .text = "max.zig",
    }, 0));
    try std.testing.expectEqual(@as(usize, 0), (try mem.lookupByText(.file, "max.zig")).len);
}

test "memory index rejects duplicate edge ids without appending adjacency" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    const a = try graph.addNode(.task, "a");
    const b = try graph.addNode(.task, "b");
    const c = try graph.addNode(.task, "c");
    _ = try graph.addEdgeUnchecked(a, .depends_on, b);

    var mem = try MemoryIndex.init(std.testing.allocator, &graph);
    defer mem.deinit();

    try std.testing.expectError(core.Error.InvalidId, mem.addEdgeRecord(.{
        .id = .fromInt(1),
        .src = a,
        .dst = c,
        .rel = .depends_on,
    }));

    try std.testing.expectEqual(@as(usize, 1), mem.outgoing(a).len);
    try std.testing.expectEqual(b.toInt(), mem.outgoing(a)[0].dst.toInt());
    try std.testing.expectEqual(@as(usize, 0), mem.incoming(c).len);
    try std.testing.expectEqual(@as(usize, 1), mem.edge_ids.count());
}

test "memory index rejects reserved edge ids and endpoints" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();

    var mem = try MemoryIndex.init(std.testing.allocator, &graph);
    defer mem.deinit();

    try std.testing.expectError(core.Error.InvalidId, mem.addEdgeRecord(.{
        .id = .none,
        .src = .fromInt(1),
        .dst = .fromInt(2),
        .rel = .defines,
    }));
    try std.testing.expectError(core.Error.InvalidId, mem.addEdgeRecord(.{
        .id = .fromInt(1),
        .src = .none,
        .dst = .fromInt(2),
        .rel = .defines,
    }));
    try std.testing.expectError(core.Error.InvalidId, mem.addEdgeRecord(.{
        .id = .fromInt(2),
        .src = .fromInt(1),
        .dst = .none,
        .rel = .defines,
    }));
    try std.testing.expectError(core.Error.InvalidId, mem.addEdgeRecord(.{
        .id = .fromInt(std.math.maxInt(u64)),
        .src = .fromInt(1),
        .dst = .fromInt(2),
        .rel = .defines,
    }));
    try std.testing.expectError(core.Error.InvalidId, mem.addEdgeRecord(.{
        .id = .fromInt(3),
        .src = .fromInt(std.math.maxInt(u64)),
        .dst = .fromInt(2),
        .rel = .defines,
    }));
    try std.testing.expectError(core.Error.InvalidId, mem.addEdgeRecord(.{
        .id = .fromInt(4),
        .src = .fromInt(1),
        .dst = .fromInt(std.math.maxInt(u64)),
        .rel = .defines,
    }));

    try std.testing.expectEqual(@as(usize, 0), mem.outgoing(.fromInt(1)).len);
    try std.testing.expectEqual(@as(usize, 0), mem.incoming(.fromInt(2)).len);
    try std.testing.expectEqual(@as(usize, 0), mem.outgoing(.none).len);
    try std.testing.expectEqual(@as(usize, 0), mem.incoming(.none).len);
}

test "memory index rejects dangling edge endpoints" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    const source = try graph.addNode(.task, "source");

    var mem = try MemoryIndex.init(std.testing.allocator, &graph);
    defer mem.deinit();

    try std.testing.expectError(core.Error.NotFound, mem.addEdgeRecord(.{
        .id = .fromInt(1),
        .src = source,
        .dst = .fromInt(99),
        .rel = .depends_on,
    }));
    try std.testing.expectError(core.Error.NotFound, mem.addEdgeRecord(.{
        .id = .fromInt(2),
        .src = .fromInt(99),
        .dst = source,
        .rel = .depends_on,
    }));
    try std.testing.expectEqual(@as(usize, 0), mem.outgoing(source).len);
    try std.testing.expectEqual(@as(usize, 0), mem.incoming(source).len);
    try std.testing.expectEqual(@as(usize, 0), mem.edge_ids.count());
}

test "memory index orders parallel adjacency by edge id" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    const a = try graph.addNode(.task, "a");
    const b = try graph.addNode(.task, "b");
    try graph.addEdgeWithIdUnchecked(.fromInt(10), a, .depends_on, b);
    try graph.addEdgeWithIdUnchecked(.fromInt(3), a, .depends_on, b);

    var mem = try MemoryIndex.init(std.testing.allocator, &graph);
    defer mem.deinit();

    const outgoing_edges = mem.outgoing(a);
    try std.testing.expectEqual(@as(usize, 2), outgoing_edges.len);
    try std.testing.expectEqual(@as(u64, 3), outgoing_edges[0].edge_id.toInt());
    try std.testing.expectEqual(@as(u64, 10), outgoing_edges[1].edge_id.toInt());
}

test "memory index preserves duplicate exact-text matches" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    try graph.addNodeWithId(.fromInt(10), .file, "shared");
    const file = core.NodeId.fromInt(10);
    const doc = try graph.addNode(.document, "shared");
    try graph.addNodeWithId(.fromInt(2), .file, "shared");

    var mem = try MemoryIndex.init(std.testing.allocator, &graph);
    defer mem.deinit();

    const all = try mem.lookupByText(null, "shared");
    try std.testing.expectEqual(@as(usize, 3), all.len);
    try std.testing.expectEqual(@as(u64, 2), all[0].toInt());
    try std.testing.expectEqual(@as(u64, 10), all[1].toInt());
    try std.testing.expectEqual(doc.toInt(), all[2].toInt());
    const files = try mem.lookupByText(.file, "shared");
    try std.testing.expectEqual(@as(usize, 2), files.len);
    try std.testing.expectEqual(@as(u64, 2), files[0].toInt());
    try std.testing.expectEqual(file.toInt(), files[1].toInt());
    try std.testing.expectEqual(@as(u64, 2), (try mem.findByText(.file, "shared")).?.toInt());
    const docs = try mem.lookupByText(.document, "shared");
    try std.testing.expectEqual(doc.toInt(), docs[0].toInt());
}

test "memory index keeps incremental duplicate texts and adjacency sorted" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    var mem = try MemoryIndex.init(std.testing.allocator, &graph);
    defer mem.deinit();

    try mem.addNode(.{ .id = .fromInt(10), .kind = .file, .text = "shared" }, 0);
    try mem.addNode(.{ .id = .fromInt(2), .kind = .file, .text = "shared" }, 1);
    try mem.addNode(.{ .id = .fromInt(1), .kind = .concept, .text = "root" }, 2);
    const files = try mem.lookupByText(.file, "shared");
    try std.testing.expectEqual(@as(usize, 2), files.len);
    try std.testing.expectEqual(@as(u64, 2), files[0].toInt());
    try std.testing.expectEqual(@as(u64, 10), files[1].toInt());
    try std.testing.expectEqual(@as(u64, 2), (try mem.findByText(.file, "shared")).?.toInt());

    try mem.addEdgeRecord(.{ .id = .fromInt(1), .src = .fromInt(1), .dst = .fromInt(10), .rel = .mentions });
    try mem.addEdgeRecord(.{ .id = .fromInt(2), .src = .fromInt(1), .dst = .fromInt(2), .rel = .defines });
    try mem.addEdgeRecord(.{ .id = .fromInt(3), .src = .fromInt(1), .dst = .fromInt(1), .rel = .defines });
    try mem.addEdgeRecord(.{ .id = .fromInt(4), .src = .fromInt(10), .dst = .fromInt(1), .rel = .mentions });
    try mem.addEdgeRecord(.{ .id = .fromInt(5), .src = .fromInt(2), .dst = .fromInt(1), .rel = .defines });
    try std.testing.expectEqual(@as(usize, 5), mem.edge_ids.count());
    const outgoing_edges = mem.outgoing(.fromInt(1));
    try std.testing.expectEqual(core.RelKind.defines, outgoing_edges[0].rel);
    try std.testing.expectEqual(@as(u64, 1), outgoing_edges[0].dst.toInt());
    try std.testing.expectEqual(core.RelKind.defines, outgoing_edges[1].rel);
    try std.testing.expectEqual(@as(u64, 2), outgoing_edges[1].dst.toInt());
    try std.testing.expectEqual(core.RelKind.mentions, outgoing_edges[2].rel);
    try std.testing.expectEqual(@as(u64, 10), outgoing_edges[2].dst.toInt());

    const defines = mem.outgoingRelation(.fromInt(1), .defines);
    try std.testing.expectEqual(@as(usize, 2), defines.len);
    try std.testing.expectEqual(@as(u64, 1), defines[0].dst.toInt());
    try std.testing.expectEqual(@as(u64, 2), defines[1].dst.toInt());
    try std.testing.expectEqual(@as(usize, 1), mem.outgoingRelation(.fromInt(1), .mentions).len);
    try std.testing.expectEqual(@as(usize, 0), mem.outgoingRelation(.fromInt(1), .calls).len);

    const incoming_defines = mem.incomingRelation(.fromInt(1), .defines);
    try std.testing.expectEqual(@as(usize, 2), incoming_defines.len);
    try std.testing.expectEqual(@as(u64, 1), incoming_defines[0].src.toInt());
    try std.testing.expectEqual(@as(u64, 2), incoming_defines[1].src.toInt());
    const incoming_mentions = mem.incomingRelation(.fromInt(1), .mentions);
    try std.testing.expectEqual(@as(usize, 1), incoming_mentions.len);
    try std.testing.expectEqual(@as(u64, 10), incoming_mentions[0].src.toInt());
}

test "memory index owns incremental exact-text keys" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    var mem = try MemoryIndex.init(std.testing.allocator, &graph);
    defer mem.deinit();

    const text = try std.testing.allocator.dupe(u8, "volatile");
    defer std.testing.allocator.free(text);

    try mem.addNode(.{ .id = .fromInt(1), .kind = .file, .text = text }, 0);
    @memset(text, 'x');

    const original = try mem.lookupByText(null, "volatile");
    try std.testing.expectEqual(@as(usize, 1), original.len);
    try std.testing.expectEqual(@as(u64, 1), original[0].toInt());
    try std.testing.expectEqual(@as(usize, 0), (try mem.lookupByText(null, "xxxxxxxx")).len);
    try std.testing.expectEqual(@as(u64, 1), (try mem.findByText(.file, "volatile")).?.toInt());
}

fn memoryIndexAddNodeAllocationFailure(allocator: std.mem.Allocator) !void {
    var graph = graph_mod.Graph.init(allocator);
    defer graph.deinit();
    var mem = try MemoryIndex.init(allocator, &graph);
    defer mem.deinit();

    try mem.addNode(.{
        .id = .fromInt(1),
        .kind = .file,
        .text = "src/main.zig",
    }, 0);
    try mem.addNode(.{
        .id = .fromInt(2),
        .kind = .document,
        .text = "src/main.zig",
    }, 1);
}

test "memory index add node rolls back allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, memoryIndexAddNodeAllocationFailure, .{});
}

fn memoryIndexAddEdgeAllocationFailure(allocator: std.mem.Allocator) !void {
    var graph = graph_mod.Graph.init(allocator);
    defer graph.deinit();
    try graph.addNodeWithId(.fromInt(1), .task, "one");
    try graph.addNodeWithId(.fromInt(2), .task, "two");
    try graph.addNodeWithId(.fromInt(3), .task, "three");
    var mem = try MemoryIndex.init(allocator, &graph);
    defer mem.deinit();

    try mem.addEdgeRecord(.{
        .id = .fromInt(1),
        .src = .fromInt(1),
        .dst = .fromInt(2),
        .rel = .defines,
    });
    const baseline_edge_ids = mem.edge_ids.count();
    try mem.addEdgeRecord(.{
        .id = .fromInt(2),
        .src = .fromInt(1),
        .dst = .fromInt(3),
        .rel = .defines,
    });
    try std.testing.expect(mem.edge_ids.count() >= baseline_edge_ids);
}

test "memory index add edge rolls back allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, memoryIndexAddEdgeAllocationFailure, .{});
}

test "memory index add edge leaves no edge id on allocation failure" {
    var fail_offset: usize = 0;
    var saw_failure = false;
    while (fail_offset < 40) : (fail_offset += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        var graph = graph_mod.Graph.init(failing.allocator());
        defer graph.deinit();
        try graph.addNodeWithId(.fromInt(1), .task, "one");
        try graph.addNodeWithId(.fromInt(2), .task, "two");
        try graph.addNodeWithId(.fromInt(3), .task, "three");
        var mem = try MemoryIndex.init(failing.allocator(), &graph);
        defer mem.deinit();

        try mem.addEdgeRecord(.{
            .id = .fromInt(1),
            .src = .fromInt(1),
            .dst = .fromInt(2),
            .rel = .defines,
        });
        const baseline_alloc_index = failing.alloc_index;
        const baseline_edge_ids = mem.edge_ids.count();
        const baseline_out = mem.outgoing(.fromInt(1)).len;
        const baseline_in = mem.incoming(.fromInt(3)).len;

        failing.fail_index = baseline_alloc_index + fail_offset;
        const result = mem.addEdgeRecord(.{
            .id = .fromInt(2),
            .src = .fromInt(1),
            .dst = .fromInt(3),
            .rel = .defines,
        });
        if (result) |_| {
            continue;
        } else |err| switch (err) {
            error.OutOfMemory => {
                saw_failure = true;
                try std.testing.expectEqual(baseline_edge_ids, mem.edge_ids.count());
                try std.testing.expect(!mem.edge_ids.contains(2));
                try std.testing.expectEqual(baseline_out, mem.outgoing(.fromInt(1)).len);
                try std.testing.expectEqual(baseline_in, mem.incoming(.fromInt(3)).len);
            },
            else => return err,
        }
    }
    try std.testing.expect(saw_failure);
}

test "memory index hides non-active nodes and edges" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();

    const active = try graph.addNode(.task, "active");
    const stale = try graph.addNode(.task, "stale");
    const target = try graph.addNode(.task, "target");
    const hidden_target = try graph.addNode(.task, "hidden-target");
    const active_edge = try graph.addEdgeUnchecked(active, .depends_on, target);
    const stale_edge = try graph.addEdgeUnchecked(active, .blocks, target);
    _ = try graph.addEdgeUnchecked(active, .depends_on, hidden_target);
    for (graph.nodes.items) |*node| {
        if (node.id == stale) node.status = .stale;
        if (node.id == hidden_target) node.status = .stale;
    }
    for (graph.edges.items) |*edge| {
        if (edge.id == stale_edge) edge.status = .stale;
    }

    var mem = try MemoryIndex.init(std.testing.allocator, &graph);
    defer mem.deinit();

    try std.testing.expect(mem.getNode(&graph, stale) == null);
    try std.testing.expect(mem.getNode(&graph, hidden_target) == null);
    try std.testing.expectEqual(@as(usize, 0), (try mem.lookupByText(.task, "stale")).len);
    try std.testing.expectEqual(@as(usize, 0), (try mem.lookupByText(.task, "hidden-target")).len);
    try std.testing.expectEqual(@as(usize, 1), mem.outgoing(active).len);
    try std.testing.expectEqual(active_edge.toInt(), mem.outgoing(active)[0].edge_id.toInt());
    try std.testing.expectEqual(@as(usize, 0), mem.incoming(hidden_target).len);
    try std.testing.expectEqual(@as(usize, 1), mem.edge_ids.count());
}
