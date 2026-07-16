const std = @import("std");
const core = @import("core.zig");
const dag = @import("dag.zig");
const graph_mod = @import("graph.zig");
const index = @import("index.zig");

pub const GraphSnapshot = struct {
    allocator: std.mem.Allocator,
    graph: graph_mod.Graph,
    index: index.MemoryIndex,

    pub fn init(allocator: std.mem.Allocator, graph: graph_mod.Graph) !GraphSnapshot {
        var owned_graph = graph;
        errdefer owned_graph.deinit();
        return .{
            .allocator = allocator,
            .graph = owned_graph,
            .index = try index.MemoryIndex.init(allocator, &owned_graph),
        };
    }

    pub fn deinit(self: *GraphSnapshot) void {
        self.index.deinit();
        self.graph.deinit();
    }

    pub fn rebuildIndex(self: *GraphSnapshot) !void {
        const new_index = try index.MemoryIndex.init(self.allocator, &self.graph);
        self.index.deinit();
        self.index = new_index;
    }

    pub fn addNode(self: *GraphSnapshot, kind: core.NodeKind, text: []const u8) !core.NodeId {
        const id = try self.graph.addNode(kind, text);
        self.index.addNode(self.graph.nodes.items[self.graph.nodes.items.len - 1], self.graph.nodes.items.len - 1) catch |index_err| {
            self.rebuildIndex() catch {
                self.rollbackLastNode(id);
                return index_err;
            };
        };
        return id;
    }

    pub fn addEdgeChecked(self: *GraphSnapshot, src: core.NodeId, rel: core.RelKind, dst: core.NodeId, budget: core.QueryBudget) !core.EdgeId {
        if (try dag.wouldCreateCycleWithIndex(&self.graph, &self.index, src, dst, rel, budget)) {
            return core.Error.CycleDetected;
        }
        const id = try self.graph.addEdgeUnchecked(src, rel, dst);
        self.index.addEdgeRecord(self.graph.edges.items[self.graph.edges.items.len - 1]) catch |index_err| {
            self.rebuildIndex() catch {
                self.rollbackLastEdge(id);
                return index_err;
            };
        };
        return id;
    }

    fn rollbackLastNode(self: *GraphSnapshot, id: core.NodeId) void {
        _ = self.graph.removeLastNodeIfId(id);
    }

    fn rollbackLastEdge(self: *GraphSnapshot, id: core.EdgeId) void {
        _ = self.graph.removeLastEdgeIfId(id);
    }
};

test "snapshot checked edge rejects DAG cycle and refreshes index" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    const a = try graph.addNode(.task, "a");
    const b = try graph.addNode(.task, "b");

    var snapshot = try GraphSnapshot.init(std.testing.allocator, graph);
    defer snapshot.deinit();

    _ = try snapshot.addEdgeChecked(a, .depends_on, b, .{});
    try std.testing.expectEqual(b.toInt(), snapshot.index.outgoing(a)[0].dst.toInt());
    try std.testing.expectError(core.Error.CycleDetected, snapshot.addEdgeChecked(b, .depends_on, a, .{}));
}

test "snapshot checked edge refuses uncertain DAG cycle check without mutation" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    const a = try graph.addNode(.task, "a");
    const b = try graph.addNode(.task, "b");

    var snapshot = try GraphSnapshot.init(std.testing.allocator, graph);
    defer snapshot.deinit();

    _ = try snapshot.addEdgeChecked(a, .depends_on, b, .{});
    const baseline_edges = snapshot.graph.edges.items.len;
    const baseline_edge_ids = snapshot.graph.edge_ids.count();
    const baseline_next_edge_id = snapshot.graph.next_edge_id;
    const baseline_outgoing_b = snapshot.index.outgoing(b).len;
    const baseline_incoming_a = snapshot.index.incoming(a).len;

    try std.testing.expectError(
        core.Error.CycleCheckUncertain,
        snapshot.addEdgeChecked(b, .depends_on, a, .{ .timeout_ms = 0 }),
    );
    try std.testing.expectEqual(baseline_edges, snapshot.graph.edges.items.len);
    try std.testing.expectEqual(baseline_edge_ids, snapshot.graph.edge_ids.count());
    try std.testing.expectEqual(baseline_next_edge_id, snapshot.graph.next_edge_id);
    try std.testing.expectEqual(baseline_outgoing_b, snapshot.index.outgoing(b).len);
    try std.testing.expectEqual(baseline_incoming_a, snapshot.index.incoming(a).len);
}

test "snapshot rebuild index leaves old index usable on allocation failure" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    const a = try graph.addNode(.task, "a");
    const b = try graph.addNode(.task, "b");
    _ = try graph.addEdgeUnchecked(a, .depends_on, b);

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var snapshot = try GraphSnapshot.init(failing.allocator(), graph);
    defer snapshot.deinit();

    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, snapshot.rebuildIndex());
    try std.testing.expectEqual(b.toInt(), snapshot.index.outgoing(a)[0].dst.toInt());
}

test "snapshot init frees consumed graph when index allocation fails" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    _ = try graph.addNode(.task, "a");

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, GraphSnapshot.init(failing.allocator(), graph));
}

test "snapshot add node rolls back graph when index repair fails" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    const a = try graph.addNode(.task, "a");

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var snapshot = try GraphSnapshot.init(failing.allocator(), graph);
    defer snapshot.deinit();

    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, snapshot.addNode(.task, "b"));
    try std.testing.expectEqual(@as(usize, 1), snapshot.graph.nodes.items.len);
    try std.testing.expectEqual(@as(usize, 1), snapshot.graph.node_by_id.count());
    try std.testing.expectEqual(@as(u64, 2), snapshot.graph.next_node_id);
    try std.testing.expect(snapshot.index.getNode(&snapshot.graph, a) != null);

    failing.fail_index = std.math.maxInt(usize);
    const retry = try snapshot.graph.addNode(.task, "b");
    try std.testing.expectEqual(@as(u64, 2), retry.toInt());
}

test "snapshot add edge rolls back graph when index repair fails" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    const a = try graph.addNode(.task, "a");
    const b = try graph.addNode(.task, "b");

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var snapshot = try GraphSnapshot.init(failing.allocator(), graph);
    defer snapshot.deinit();

    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, snapshot.addEdgeChecked(a, .depends_on, b, .{}));
    try std.testing.expectEqual(@as(usize, 0), snapshot.graph.edges.items.len);
    try std.testing.expectEqual(@as(usize, 0), snapshot.graph.edge_ids.count());
    try std.testing.expectEqual(@as(u64, 1), snapshot.graph.next_edge_id);
    try std.testing.expectEqual(@as(usize, 0), snapshot.index.outgoing(a).len);

    failing.fail_index = std.math.maxInt(usize);
    const retry = try snapshot.graph.addEdgeUnchecked(a, .depends_on, b);
    try std.testing.expectEqual(@as(u64, 1), retry.toInt());
}
