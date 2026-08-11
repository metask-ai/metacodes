const std = @import("std");
const core = @import("../core.zig");
const graph_mod = @import("../graph.zig");
const index = @import("../index.zig");
const traversal = @import("traversal_state.zig").Support;

/// Storage-independent DAG relation and in-memory cycle policy. Persistent
/// adapters remain in dag.zig; snapshots depend only on this owner.
pub const RelationPolicy = enum {
    cyclic_allowed,
    dag,
};

pub fn relationPolicy(rel: core.RelKind) RelationPolicy {
    return switch (rel) {
        .contains, .depends_on, .blocks, .precedes, .derived_from, .summarizes, .contain => .dag,
        else => .cyclic_allowed,
    };
}

pub fn isDagRelation(rel: core.RelKind) bool {
    return relationPolicy(rel) == .dag;
}

pub fn reachable(graph: *const graph_mod.Graph, from: core.NodeId, to: core.NodeId, rel: core.RelKind, budget: core.QueryBudget) !bool {
    var mem_index = try index.MemoryIndex.init(graph.allocator, graph);
    defer mem_index.deinit();
    return reachableWithIndex(graph, &mem_index, from, to, rel, budget);
}

pub fn reachableWithIndex(graph: *const graph_mod.Graph, mem_index: *index.MemoryIndex, from: core.NodeId, to: core.NodeId, rel: core.RelKind, budget: core.QueryBudget) !bool {
    if (traversal.isReservedNodeId(from) or traversal.isReservedNodeId(to)) return core.Error.InvalidId;
    if (traversal.timedOutImmediately(budget)) return core.Error.BudgetExceeded;
    if (from != to and traversal.nodeBudgetExhausted(budget)) return core.Error.BudgetExceeded;
    if (mem_index.getNode(graph, from) == null or mem_index.getNode(graph, to) == null) return core.Error.NotFound;
    if (from == to) return true;

    var node_state = try traversal.NodeState.init(graph.allocator, traversal.graphMaxNodeIdHint(graph.next_node_id), budget);
    defer node_state.deinit(graph.allocator);
    var frontier = std.ArrayList(core.NodeId).empty;
    defer frontier.deinit(graph.allocator);
    try frontier.ensureTotalCapacity(graph.allocator, traversal.preallocNodeCapacity(budget));
    try frontier.append(graph.allocator, from);
    try node_state.putDepth(from.toInt(), 0);

    var position: usize = 0;
    var edges_visited: usize = 0;
    while (position < frontier.items.len) : (position += 1) {
        if (node_state.visitedCount() >= budget.max_visited_nodes) return core.Error.BudgetExceeded;
        const current = frontier.items[position];
        if (current == to) return true;
        if (try node_state.containsVisited(current.toInt())) continue;
        const current_depth = (try node_state.getDepth(current.toInt())).?;
        try node_state.markVisited(current.toInt());
        for (mem_index.outgoingRelation(current, rel)) |edge| {
            if (edges_visited >= budget.max_visited_edges) return core.Error.BudgetExceeded;
            edges_visited = try traversal.incrementCounter(edges_visited);
            if (current_depth >= budget.max_depth) return core.Error.BudgetExceeded;
            if (edge.dst == to) return true;
            if (try node_state.containsVisited(edge.dst.toInt())) continue;
            if (try node_state.hasDepth(edge.dst.toInt())) continue;
            if (mem_index.getNode(graph, edge.dst) == null) continue;
            try node_state.putDepth(edge.dst.toInt(), current_depth + 1);
            try frontier.append(graph.allocator, edge.dst);
        }
    }
    return false;
}

pub fn wouldCreateCycle(graph: *const graph_mod.Graph, src: core.NodeId, dst: core.NodeId, rel: core.RelKind, budget: core.QueryBudget) !bool {
    var mem_index = try index.MemoryIndex.init(graph.allocator, graph);
    defer mem_index.deinit();
    return wouldCreateCycleWithIndex(graph, &mem_index, src, dst, rel, budget);
}

pub fn wouldCreateCycleWithIndex(graph: *const graph_mod.Graph, mem_index: *index.MemoryIndex, src: core.NodeId, dst: core.NodeId, rel: core.RelKind, budget: core.QueryBudget) !bool {
    if (traversal.isReservedNodeId(src) or traversal.isReservedNodeId(dst)) return core.Error.InvalidId;
    if (!isDagRelation(rel)) return false;
    return reachableWithIndex(graph, mem_index, dst, src, rel, budget) catch |err| switch (err) {
        core.Error.BudgetExceeded => return core.Error.CycleCheckUncertain,
        else => |other| return other,
    };
}

pub fn addEdgeChecked(graph: *graph_mod.Graph, src: core.NodeId, rel: core.RelKind, dst: core.NodeId, budget: core.QueryBudget) !core.EdgeId {
    if (try wouldCreateCycle(graph, src, dst, rel, budget)) return core.Error.CycleDetected;
    return graph.addEdgeUnchecked(src, rel, dst);
}

test "in-memory DAG owner classifies policy and rejects a cycle" {
    try std.testing.expect(isDagRelation(.depends_on));
    try std.testing.expect(!isDagRelation(.calls));
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    const a = try graph.addNode(.task, "a");
    const b = try graph.addNode(.task, "b");
    _ = try addEdgeChecked(&graph, a, .depends_on, b, .{});
    try std.testing.expectError(core.Error.CycleDetected, addEdgeChecked(&graph, b, .depends_on, a, .{}));
    _ = try addEdgeChecked(&graph, b, .calls, a, .{});
}

test "in-memory DAG owner preserves budget and missing-node policy" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    const a = try graph.addNode(.task, "a");
    const b = try graph.addNode(.task, "b");
    const c = try graph.addNode(.task, "c");
    _ = try graph.addEdgeUnchecked(a, .depends_on, b);
    _ = try graph.addEdgeUnchecked(b, .depends_on, c);
    try std.testing.expect(try reachable(&graph, a, c, .depends_on, .{}));
    try std.testing.expectError(core.Error.BudgetExceeded, reachable(&graph, a, c, .depends_on, .{ .max_visited_edges = 1 }));
    try std.testing.expectError(core.Error.NotFound, reachable(&graph, a, .fromInt(99), .depends_on, .{}));
    try std.testing.expectError(core.Error.CycleCheckUncertain, wouldCreateCycle(&graph, c, a, .depends_on, .{ .timeout_ms = 0 }));
}

test "in-memory DAG owner skips dangling intermediate targets" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    const a = try graph.addNode(.task, "a");
    const c = try graph.addNode(.task, "c");
    const missing = core.NodeId.fromInt(99);
    try graph.edges.append(std.testing.allocator, .{ .id = .fromInt(1), .src = a, .dst = missing, .rel = .depends_on });
    try graph.edges.append(std.testing.allocator, .{ .id = .fromInt(2), .src = missing, .dst = c, .rel = .depends_on });
    try std.testing.expect(!try reachable(&graph, a, c, .depends_on, .{ .max_depth = 3 }));
}
