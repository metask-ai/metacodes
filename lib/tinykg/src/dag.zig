const std = @import("std");
const core = @import("core.zig");
const graph_mod = @import("graph.zig");
const index = @import("index.zig");
const query = @import("query.zig");
const storage = @import("storage.zig");
const in_memory = @import("dag/in_memory.zig");
const traversal = @import("dag/traversal_state.zig").Support;

/// Stable DAG façade aliases for the storage-independent in-memory owner.
pub const RelationPolicy = in_memory.RelationPolicy;
pub const relationPolicy = in_memory.relationPolicy;
pub const isDagRelation = in_memory.isDagRelation;
pub const reachable = in_memory.reachable;
pub const reachableWithIndex = in_memory.reachableWithIndex;
pub const wouldCreateCycle = in_memory.wouldCreateCycle;
pub const wouldCreateCycleWithIndex = in_memory.wouldCreateCycleWithIndex;
pub const addEdgeChecked = in_memory.addEdgeChecked;

pub fn reachableWithCursor(
    allocator: std.mem.Allocator,
    graph: *const graph_mod.Graph,
    mem_index: *index.MemoryIndex,
    edge_cursor: query.EdgeCursor,
    from: core.NodeId,
    to: core.NodeId,
    rel: core.RelKind,
    budget: core.QueryBudget,
) !bool {
    if (traversal.isReservedNodeId(from) or traversal.isReservedNodeId(to)) return core.Error.InvalidId;
    if (traversal.timedOutImmediately(budget)) return core.Error.BudgetExceeded;
    if (from.toInt() != to.toInt() and traversal.nodeBudgetExhausted(budget)) return core.Error.BudgetExceeded;
    if (mem_index.getNode(graph, from) == null or mem_index.getNode(graph, to) == null) return core.Error.NotFound;
    if (from.toInt() == to.toInt()) return true;
    var node_state = try traversal.NodeState.init(allocator, traversal.graphMaxNodeIdHint(graph.next_node_id), budget);
    defer node_state.deinit(allocator);
    var frontier = std.ArrayList(core.NodeId).empty;
    defer frontier.deinit(allocator);
    const prealloc_nodes = traversal.preallocNodeCapacity(budget);
    try frontier.ensureTotalCapacity(allocator, prealloc_nodes);
    try frontier.append(allocator, from);
    try node_state.putDepth(from.toInt(), 0);

    var pos: usize = 0;
    var edges_visited: usize = 0;
    while (pos < frontier.items.len) : (pos += 1) {
        if (node_state.visitedCount() >= budget.max_visited_nodes) return core.Error.BudgetExceeded;
        const current = frontier.items[pos];
        if (current.toInt() == to.toInt()) return true;
        if (try node_state.containsVisited(current.toInt())) continue;
        const current_depth = (try node_state.getDepth(current.toInt())).?;
        try node_state.markVisited(current.toInt());
        var context = ReachableExploreContext{
            .allocator = allocator,
            .graph = graph,
            .mem_index = mem_index,
            .node_state = &node_state,
            .frontier = &frontier,
            .to = to,
            .current_depth = current_depth,
            .budget = budget,
            .edges_visited = &edges_visited,
        };
        if (try edge_cursor.forEachOutgoingRelation(current, rel, &context, exploreReachableEdge)) return true;
    }
    return false;
}

const ReachableExploreContext = struct {
    allocator: std.mem.Allocator,
    graph: *const graph_mod.Graph,
    mem_index: *index.MemoryIndex,
    node_state: *traversal.NodeState,
    frontier: *std.ArrayList(core.NodeId),
    to: core.NodeId,
    current_depth: u8,
    budget: core.QueryBudget,
    edges_visited: *usize,
};

fn exploreReachableEdge(ctx: *ReachableExploreContext, edge: index.EdgeRef) !bool {
    if (ctx.edges_visited.* >= ctx.budget.max_visited_edges) return core.Error.BudgetExceeded;
    ctx.edges_visited.* = try traversal.incrementCounter(ctx.edges_visited.*);
    if (ctx.current_depth >= ctx.budget.max_depth) return core.Error.BudgetExceeded;
    if (edge.dst.toInt() == ctx.to.toInt()) return true;
    if (try ctx.node_state.containsVisited(edge.dst.toInt())) return false;
    if (try ctx.node_state.hasDepth(edge.dst.toInt())) return false;
    if (ctx.mem_index.getNode(ctx.graph, edge.dst) == null) return false;
    try ctx.node_state.putDepth(edge.dst.toInt(), ctx.current_depth + 1);
    try ctx.frontier.append(ctx.allocator, edge.dst);
    return false;
}

pub fn wouldCreateCycleWithCursor(
    allocator: std.mem.Allocator,
    graph: *const graph_mod.Graph,
    mem_index: *index.MemoryIndex,
    edge_cursor: query.EdgeCursor,
    src: core.NodeId,
    dst: core.NodeId,
    rel: core.RelKind,
    budget: core.QueryBudget,
) !bool {
    if (traversal.isReservedNodeId(src) or traversal.isReservedNodeId(dst)) return core.Error.InvalidId;
    if (!isDagRelation(rel)) return false;
    return reachableWithCursor(allocator, graph, mem_index, edge_cursor, dst, src, rel, budget) catch |err| switch (err) {
        core.Error.BudgetExceeded => return core.Error.CycleCheckUncertain,
        else => |e| return e,
    };
}

pub fn reachableWithPersistentStore(
    allocator: std.mem.Allocator,
    store: storage.Store,
    from: core.NodeId,
    to: core.NodeId,
    rel: core.RelKind,
    budget: core.QueryBudget,
) !bool {
    var stats: index.QueryStats = .{};
    return reachableWithPersistentStoreMeasured(allocator, store, from, to, rel, budget, &stats);
}

pub fn reachableWithPersistentStoreRetained(
    allocator: std.mem.Allocator,
    store: storage.Store,
    edge_retention_registry: *storage.EdgeSegmentRetentionRegistry,
    from: core.NodeId,
    to: core.NodeId,
    rel: core.RelKind,
    budget: core.QueryBudget,
) !bool {
    var stats: index.QueryStats = .{};
    return reachableWithPersistentStoreMeasuredRetained(allocator, store, edge_retention_registry, from, to, rel, budget, &stats);
}

pub fn reachableWithPersistentStoreMeasured(
    allocator: std.mem.Allocator,
    store: storage.Store,
    from: core.NodeId,
    to: core.NodeId,
    rel: core.RelKind,
    budget: core.QueryBudget,
    stats: *index.QueryStats,
) !bool {
    return reachableWithPersistentStoreMeasuredMaybeRetained(allocator, store, null, from, to, rel, budget, stats);
}

pub fn reachableWithPersistentStoreMeasuredRetained(
    allocator: std.mem.Allocator,
    store: storage.Store,
    edge_retention_registry: *storage.EdgeSegmentRetentionRegistry,
    from: core.NodeId,
    to: core.NodeId,
    rel: core.RelKind,
    budget: core.QueryBudget,
    stats: *index.QueryStats,
) !bool {
    return reachableWithPersistentStoreMeasuredMaybeRetained(allocator, store, edge_retention_registry, from, to, rel, budget, stats);
}

fn reachableWithPersistentStoreMeasuredMaybeRetained(
    allocator: std.mem.Allocator,
    store: storage.Store,
    edge_retention_registry: ?*storage.EdgeSegmentRetentionRegistry,
    from: core.NodeId,
    to: core.NodeId,
    rel: core.RelKind,
    budget: core.QueryBudget,
    stats: *index.QueryStats,
) !bool {
    var repaired = false;
    while (true) {
        const baseline_nodes = stats.nodes_visited;
        const baseline_edges = stats.edges_visited;
        return reachableWithPersistentStoreOnceMeasured(allocator, store, edge_retention_registry, from, to, rel, budget, stats) catch |err| switch (err) {
            error.FileNotFound, error.InvalidRecord => {
                if (repaired) return err;
                repaired = true;
                stats.nodes_visited = baseline_nodes;
                stats.edges_visited = baseline_edges;
                try store.repairPersistentIndexesFromLog();
                continue;
            },
            else => |e| return e,
        };
    }
}

fn reachableWithPersistentStoreOnceMeasured(
    allocator: std.mem.Allocator,
    store: storage.Store,
    edge_retention_registry: ?*storage.EdgeSegmentRetentionRegistry,
    from: core.NodeId,
    to: core.NodeId,
    rel: core.RelKind,
    budget: core.QueryBudget,
    stats: *index.QueryStats,
) !bool {
    if (traversal.isReservedNodeId(from) or traversal.isReservedNodeId(to)) return core.Error.InvalidId;
    const deadline = core.QueryDeadline.fromIo(store.io, budget.timeout_ms);
    if (deadline.expired()) return core.Error.BudgetExceeded;
    if (from.toInt() != to.toInt() and traversal.nodeBudgetExhausted(budget)) return core.Error.BudgetExceeded;
    var node_view = try store.openNodeByIdIndexView();
    defer node_view.deinit();
    if (!try node_view.nodeExists(from) or !try node_view.nodeExists(to)) return core.Error.NotFound;
    if (from.toInt() == to.toInt()) return true;
    const cursor = query.EdgeCursor{ .persistent_store = .{
        .allocator = allocator,
        .store = store,
        .edge_retention_registry = edge_retention_registry,
    } };

    var node_state = try traversal.NodeState.init(allocator, node_view.max_node_id, budget);
    defer node_state.deinit(allocator);
    var frontier = std.ArrayList(core.NodeId).empty;
    defer frontier.deinit(allocator);
    const prealloc_nodes = traversal.preallocNodeCapacity(budget);
    try frontier.ensureTotalCapacity(allocator, prealloc_nodes);
    try frontier.append(allocator, from);
    try node_state.putDepth(from.toInt(), 0);

    var pos: usize = 0;
    var edges_visited: usize = 0;
    while (pos < frontier.items.len) : (pos += 1) {
        if (deadline.expired()) return core.Error.BudgetExceeded;
        if (node_state.visitedCount() >= budget.max_visited_nodes) return core.Error.BudgetExceeded;
        const current = frontier.items[pos];
        if (current.toInt() == to.toInt()) return true;
        if (try node_state.containsVisited(current.toInt())) continue;
        const current_depth = (try node_state.getDepth(current.toInt())).?;
        try node_state.markVisited(current.toInt());
        try index.addVisitedNodes(stats, 1);
        var context = PersistentReachableExploreContext{
            .allocator = allocator,
            .node_view = &node_view,
            .node_state = &node_state,
            .frontier = &frontier,
            .to = to,
            .current_depth = current_depth,
            .budget = budget,
            .deadline = deadline,
            .edges_visited = &edges_visited,
            .stats = stats,
        };
        if (try cursor.forEachOutgoingRelation(current, rel, &context, explorePersistentReachableEdge)) return true;
    }
    return false;
}

const PersistentReachableExploreContext = struct {
    allocator: std.mem.Allocator,
    node_view: *const storage.Store.NodeByIdIndexView,
    node_state: *traversal.NodeState,
    frontier: *std.ArrayList(core.NodeId),
    to: core.NodeId,
    current_depth: u8,
    budget: core.QueryBudget,
    deadline: core.QueryDeadline,
    edges_visited: *usize,
    stats: *index.QueryStats,
};

fn explorePersistentReachableEdge(ctx: *PersistentReachableExploreContext, edge: index.EdgeRef) !bool {
    if (ctx.deadline.expired()) return core.Error.BudgetExceeded;
    if (ctx.edges_visited.* >= ctx.budget.max_visited_edges) return core.Error.BudgetExceeded;
    ctx.edges_visited.* = try traversal.incrementCounter(ctx.edges_visited.*);
    try index.addVisitedEdges(ctx.stats, 1);
    if (ctx.current_depth >= ctx.budget.max_depth) return core.Error.BudgetExceeded;
    if (edge.dst.toInt() == ctx.to.toInt()) return true;
    if (try ctx.node_state.containsVisited(edge.dst.toInt())) return false;
    if (try ctx.node_state.hasDepth(edge.dst.toInt())) return false;
    if (!try ctx.node_view.nodeExists(edge.dst)) return error.InvalidRecord;
    try ctx.node_state.putDepth(edge.dst.toInt(), ctx.current_depth + 1);
    try ctx.frontier.append(ctx.allocator, edge.dst);
    return false;
}

pub fn wouldCreateCycleWithPersistentStore(
    allocator: std.mem.Allocator,
    store: storage.Store,
    src: core.NodeId,
    dst: core.NodeId,
    rel: core.RelKind,
    budget: core.QueryBudget,
) !bool {
    if (traversal.isReservedNodeId(src) or traversal.isReservedNodeId(dst)) return core.Error.InvalidId;
    if (!isDagRelation(rel)) return false;
    return reachableWithPersistentStore(allocator, store, dst, src, rel, budget) catch |err| switch (err) {
        core.Error.BudgetExceeded => return core.Error.CycleCheckUncertain,
        else => |e| return e,
    };
}

pub fn appendEdgeCheckedWithPersistentStore(allocator: std.mem.Allocator, store: storage.Store, edge: graph_mod.Edge, budget: core.QueryBudget) !void {
    var repaired = false;
    while (true) {
        return appendEdgeCheckedWithPersistentStoreOnce(allocator, store, edge, budget) catch |err| switch (err) {
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

fn appendEdgeCheckedWithPersistentStoreOnce(allocator: std.mem.Allocator, store: storage.Store, edge: graph_mod.Edge, budget: core.QueryBudget) !void {
    if (try wouldCreateCycleWithPersistentStore(allocator, store, edge.src, edge.dst, edge.rel, budget)) {
        return core.Error.CycleDetected;
    }
    try store.appendEdgeIndexed(edge);
}

pub fn addEdgeCheckedWithPersistentStore(
    allocator: std.mem.Allocator,
    store: storage.Store,
    src: core.NodeId,
    rel: core.RelKind,
    dst: core.NodeId,
    budget: core.QueryBudget,
) !core.EdgeId {
    var repaired = false;
    while (true) {
        const id = store.nextEdgeId() catch |err| switch (err) {
            error.FileNotFound, error.InvalidRecord => {
                if (repaired) return err;
                repaired = true;
                try store.repairPersistentIndexesFromLog();
                continue;
            },
            else => |e| return e,
        };
        const edge: graph_mod.Edge = .{ .id = id, .src = src, .rel = rel, .dst = dst };
        appendEdgeCheckedWithPersistentStore(allocator, store, edge, budget) catch |err| switch (err) {
            error.FileNotFound, error.InvalidRecord => {
                if (repaired) return err;
                repaired = true;
                try store.repairPersistentIndexesFromLog();
                continue;
            },
            else => |e| return e,
        };
        return id;
    }
}

pub fn topoSort(allocator: std.mem.Allocator, graph: *const graph_mod.Graph, rel: core.RelKind) !std.ArrayList(core.NodeId) {
    var mem_index = try index.MemoryIndex.init(allocator, graph);
    defer mem_index.deinit();
    return topoSortWithIndex(allocator, graph, &mem_index, rel);
}

pub fn topoSortWithIndex(allocator: std.mem.Allocator, graph: *const graph_mod.Graph, mem_index: *index.MemoryIndex, rel: core.RelKind) !std.ArrayList(core.NodeId) {
    return topoSortWithCursor(allocator, graph, mem_index, .{ .memory = .{ .mem_index = mem_index } }, rel);
}

pub fn topoSortWithCursor(
    allocator: std.mem.Allocator,
    graph: *const graph_mod.Graph,
    mem_index: *index.MemoryIndex,
    edge_cursor: query.EdgeCursor,
    rel: core.RelKind,
) !std.ArrayList(core.NodeId) {
    if (!isDagRelation(rel)) return core.Error.Unsupported;
    _ = mem_index;
    var indegree = std.AutoHashMap(u64, usize).init(allocator);
    defer indegree.deinit();
    var present = std.AutoHashMap(u64, void).init(allocator);
    defer present.deinit();

    for (graph.nodes.items) |node| {
        if (node.status != .active) continue;
        try present.put(node.id.toInt(), {});
        try indegree.put(node.id.toInt(), 0);
    }
    var indegree_context = TopoSortIndegreeContext{
        .present = &present,
        .indegree = &indegree,
        .rel = rel,
    };
    var present_it_for_indegree = present.iterator();
    while (present_it_for_indegree.next()) |entry| {
        _ = try edge_cursor.forEachOutgoing(core.NodeId.fromInt(entry.key_ptr.*), &indegree_context, topoSortCountEdge);
    }

    var queue = std.ArrayList(core.NodeId).empty;
    defer queue.deinit(allocator);
    var it = present.iterator();
    while (it.next()) |entry| {
        const id = entry.key_ptr.*;
        if ((indegree.get(id) orelse 0) == 0) {
            try queue.append(allocator, core.NodeId.fromInt(id));
        }
    }

    var out = std.ArrayList(core.NodeId).empty;
    errdefer out.deinit(allocator);
    var pos: usize = 0;
    while (pos < queue.items.len) : (pos += 1) {
        const current = queue.items[pos];
        try out.append(allocator, current);
        var context = TopoSortContext{
            .allocator = allocator,
            .present = &present,
            .indegree = &indegree,
            .queue = &queue,
            .rel = rel,
        };
        _ = try edge_cursor.forEachOutgoing(current, &context, topoSortVisitEdge);
    }
    if (out.items.len != present.count()) return core.Error.CycleDetected;
    return out;
}

const TopoSortContext = struct {
    allocator: std.mem.Allocator,
    present: *std.AutoHashMap(u64, void),
    indegree: *std.AutoHashMap(u64, usize),
    queue: *std.ArrayList(core.NodeId),
    rel: core.RelKind,
};

const TopoSortIndegreeContext = struct {
    present: *std.AutoHashMap(u64, void),
    indegree: *std.AutoHashMap(u64, usize),
    rel: core.RelKind,
};

fn topoSortCountEdge(ctx: *TopoSortIndegreeContext, edge: index.EdgeRef) !bool {
    if (edge.rel != ctx.rel) return false;
    if (!ctx.present.contains(edge.src.toInt()) or !ctx.present.contains(edge.dst.toInt())) return false;
    const current = ctx.indegree.get(edge.dst.toInt()) orelse 0;
    try ctx.indegree.put(edge.dst.toInt(), try incrementIndegree(current));
    return false;
}

fn topoSortVisitEdge(ctx: *TopoSortContext, edge: index.EdgeRef) !bool {
    if (edge.rel != ctx.rel) return false;
    if (!ctx.present.contains(edge.src.toInt()) or !ctx.present.contains(edge.dst.toInt())) return false;
    const current_degree = ctx.indegree.get(edge.dst.toInt()) orelse return false;
    if (current_degree == 0) return core.Error.InvalidId;
    const next_degree = current_degree - 1;
    try ctx.indegree.put(edge.dst.toInt(), next_degree);
    if (next_degree == 0) try ctx.queue.append(ctx.allocator, edge.dst);
    return false;
}

fn incrementIndegree(current: usize) !usize {
    return std.math.add(usize, current, 1) catch return error.RecordTooLarge;
}

test "DAG policy classifies dependency relations" {
    try std.testing.expect(isDagRelation(.depends_on));
    try std.testing.expect(!isDagRelation(.calls));
}

test "reachability follows selected relation only" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    const a = try graph.addNode(.task, "a");
    const b = try graph.addNode(.task, "b");
    const c = try graph.addNode(.task, "c");
    _ = try graph.addEdgeUnchecked(a, .depends_on, b);
    _ = try graph.addEdgeUnchecked(b, .depends_on, c);
    try std.testing.expect(try reachable(&graph, a, c, .depends_on, .{}));
    try std.testing.expect(!try reachable(&graph, a, c, .blocks, .{}));
}

test "checked in-memory edge append rejects only DAG cycles" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    const a = try graph.addNode(.task, "a");
    const b = try graph.addNode(.task, "b");

    _ = try addEdgeChecked(&graph, a, .depends_on, b, .{});
    try std.testing.expectError(core.Error.CycleDetected, addEdgeChecked(&graph, b, .depends_on, a, .{}));
    try std.testing.expectEqual(@as(usize, 1), graph.edges.items.len);

    _ = try addEdgeChecked(&graph, a, .calls, b, .{});
    _ = try addEdgeChecked(&graph, b, .calls, a, .{});
    try std.testing.expectEqual(@as(usize, 3), graph.edges.items.len);
}

test "checked in-memory edge append rejects DAG self loops" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    const task = try graph.addNode(.task, "self");

    try std.testing.expectError(core.Error.CycleDetected, addEdgeChecked(&graph, task, .depends_on, task, .{}));
    _ = try addEdgeChecked(&graph, task, .related_to, task, .{});
    try std.testing.expectEqual(@as(usize, 1), graph.edges.items.len);
}

test "cycle check rejects reserved ids before non-DAG relation shortcut" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    const a = try graph.addNode(.task, "a");

    try std.testing.expectError(core.Error.InvalidId, wouldCreateCycle(&graph, .none, a, .calls, .{}));
    try std.testing.expectError(core.Error.InvalidId, wouldCreateCycle(&graph, a, .none, .calls, .{}));
    try std.testing.expectError(core.Error.InvalidId, wouldCreateCycle(&graph, .fromInt(std.math.maxInt(u64)), a, .calls, .{}));
    try std.testing.expectError(core.Error.InvalidId, wouldCreateCycle(&graph, a, .fromInt(std.math.maxInt(u64)), .calls, .{}));
}

test "reachability enforces edge budget" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    const a = try graph.addNode(.task, "a");
    const b = try graph.addNode(.task, "b");
    const c = try graph.addNode(.task, "c");
    _ = try graph.addEdgeUnchecked(a, .depends_on, b);
    _ = try graph.addEdgeUnchecked(b, .depends_on, c);
    try std.testing.expectError(core.Error.BudgetExceeded, reachable(&graph, a, c, .depends_on, .{ .max_visited_edges = 1 }));
    try std.testing.expectError(core.Error.InvalidId, reachable(&graph, .none, c, .depends_on, .{}));
    try std.testing.expectError(core.Error.InvalidId, reachable(&graph, a, .none, .depends_on, .{}));
    try std.testing.expectError(core.Error.InvalidId, reachable(&graph, .fromInt(std.math.maxInt(u64)), c, .depends_on, .{}));
    try std.testing.expectError(core.Error.InvalidId, reachable(&graph, a, .fromInt(std.math.maxInt(u64)), .depends_on, .{}));
    try std.testing.expectError(core.Error.NotFound, reachable(&graph, a, .fromInt(99), .depends_on, .{}));
}

test "reachability uses relation-bounded edge budget" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    const a = try graph.addNode(.task, "a");
    const b = try graph.addNode(.task, "b");
    const c = try graph.addNode(.task, "c");
    _ = try graph.addEdgeUnchecked(a, .defines, c);
    _ = try graph.addEdgeUnchecked(a, .depends_on, b);

    try std.testing.expect(try reachable(&graph, a, b, .depends_on, .{ .max_visited_edges = 1 }));
}

test "reachability honors immediate timeout budget" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    const a = try graph.addNode(.task, "a");
    const b = try graph.addNode(.task, "b");
    _ = try graph.addEdgeUnchecked(a, .depends_on, b);

    try std.testing.expectError(core.Error.BudgetExceeded, reachable(&graph, a, b, .depends_on, .{ .timeout_ms = 0 }));
    try std.testing.expectError(core.Error.CycleCheckUncertain, wouldCreateCycle(&graph, b, a, .depends_on, .{ .timeout_ms = 0 }));
}

test "reachability exhausted node budget returns before traversal allocation" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    const a = try graph.addNode(.task, "a");
    const b = try graph.addNode(.task, "b");
    _ = try graph.addEdgeUnchecked(a, .depends_on, b);

    var mem_index = try index.MemoryIndex.init(std.testing.allocator, &graph);
    defer mem_index.deinit();

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(
        core.Error.BudgetExceeded,
        reachableWithCursor(failing.allocator(), &graph, &mem_index, .{ .memory = .{ .mem_index = &mem_index } }, a, b, .depends_on, .{ .max_visited_nodes = 0 }),
    );
    try std.testing.expectError(
        core.Error.CycleCheckUncertain,
        wouldCreateCycleWithCursor(failing.allocator(), &graph, &mem_index, .{ .memory = .{ .mem_index = &mem_index } }, b, a, .depends_on, .{ .max_visited_nodes = 0 }),
    );
}

test "reachability traversal node state uses dense storage for dense ids" {
    var state = try traversal.NodeState.init(std.testing.allocator, 64, .{ .max_visited_nodes = 16 });
    defer state.deinit(std.testing.allocator);

    switch (state) {
        .dense => {},
        .sparse => return error.ExpectedDenseTraversalState,
    }

    try std.testing.expectEqual(@as(usize, 0), state.visitedCount());
    try std.testing.expect(!try state.hasDepth(3));
    try state.putDepth(3, 2);
    try std.testing.expect(try state.hasDepth(3));
    try std.testing.expectEqual(@as(?u8, 2), try state.getDepth(3));
    try std.testing.expect(!try state.containsVisited(3));
    try state.markVisited(3);
    try state.markVisited(3);
    try std.testing.expect(try state.containsVisited(3));
    try std.testing.expectEqual(@as(usize, 1), state.visitedCount());
}

test "reachability traversal node state falls back for sparse high ids" {
    const sparse_high_id: u64 = 4 * 1024 * 1024 + 1;
    var state = try traversal.NodeState.init(std.testing.allocator, sparse_high_id, .{ .max_visited_nodes = 16 });
    defer state.deinit(std.testing.allocator);

    switch (state) {
        .dense => return error.ExpectedSparseTraversalState,
        .sparse => {},
    }

    const high_id = sparse_high_id;
    try std.testing.expect(!try state.hasDepth(high_id));
    try state.putDepth(high_id, 1);
    try std.testing.expectEqual(@as(?u8, 1), try state.getDepth(high_id));
    try state.markVisited(high_id);
    try std.testing.expect(try state.containsVisited(high_id));
    try std.testing.expectEqual(@as(usize, 1), state.visitedCount());
}

test "reachability enforces max depth budget" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    const a = try graph.addNode(.task, "a");
    const b = try graph.addNode(.task, "b");
    const c = try graph.addNode(.task, "c");
    _ = try graph.addEdgeUnchecked(a, .depends_on, b);
    _ = try graph.addEdgeUnchecked(b, .depends_on, c);

    try std.testing.expect(try reachable(&graph, a, c, .depends_on, .{ .max_depth = 2 }));
    try std.testing.expectError(core.Error.BudgetExceeded, reachable(&graph, a, c, .depends_on, .{ .max_depth = 1 }));
    try std.testing.expectError(core.Error.CycleCheckUncertain, wouldCreateCycle(&graph, c, a, .depends_on, .{ .max_depth = 1 }));
}

test "reachability does not charge duplicate discovered frontier nodes" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    const a = try graph.addNode(.task, "a");
    const b = try graph.addNode(.task, "b");
    const c = try graph.addNode(.task, "c");
    const d = try graph.addNode(.task, "d");
    const f = try graph.addNode(.task, "f");
    _ = try graph.addEdgeUnchecked(a, .depends_on, b);
    _ = try graph.addEdgeUnchecked(a, .depends_on, c);
    _ = try graph.addEdgeUnchecked(b, .depends_on, d);
    _ = try graph.addEdgeUnchecked(c, .depends_on, d);

    try std.testing.expect(!try reachable(&graph, a, f, .depends_on, .{
        .max_visited_nodes = 4,
        .max_depth = 3,
    }));
}

test "reachability zero-hop result ignores traversal budget" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    const a = try graph.addNode(.task, "a");

    try std.testing.expect(try reachable(&graph, a, a, .depends_on, .{
        .max_visited_nodes = 0,
        .max_visited_edges = 0,
        .max_depth = 0,
    }));
}

test "reachability does not traverse through missing intermediate nodes" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    const a = try graph.addNode(.task, "a");
    const c = try graph.addNode(.task, "c");
    const missing = core.NodeId.fromInt(99);
    try graph.edges.append(std.testing.allocator, .{ .id = .fromInt(1), .src = a, .dst = missing, .rel = .depends_on });
    try graph.edges.append(std.testing.allocator, .{ .id = .fromInt(2), .src = missing, .dst = c, .rel = .depends_on });

    try std.testing.expect(!try reachable(&graph, a, c, .depends_on, .{ .max_depth = 3 }));
}

test "reachability uses store-backed edge cursor" {
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
    const ab = try graph.addEdgeUnchecked(a, .depends_on, b);
    const bc = try graph.addEdgeUnchecked(b, .depends_on, c);
    try store.appendNode(graph.nodes.items[0]);
    try store.appendNode(graph.nodes.items[1]);
    try store.appendNode(graph.nodes.items[2]);
    try store.appendEdge(graph.edges.items[ab.toInt() - 1]);
    try store.appendEdge(graph.edges.items[bc.toInt() - 1]);

    var loaded = try store.loadGraph();
    defer loaded.deinit();
    var mem_index = try index.MemoryIndex.init(std.testing.allocator, &loaded);
    defer mem_index.deinit();

    const cursor: query.EdgeCursor = .{ .store = .{ .allocator = std.testing.allocator, .store = store, .graph = &loaded } };
    try std.testing.expect(try reachableWithCursor(std.testing.allocator, &loaded, &mem_index, cursor, a, c, .depends_on, .{}));
    try std.testing.expect(!try reachableWithCursor(std.testing.allocator, &loaded, &mem_index, cursor, a, c, .blocks, .{}));
}

test "reachability can use persistent store without graph argument" {
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
    const ab = try graph.addEdgeUnchecked(a, .depends_on, b);
    const bc = try graph.addEdgeUnchecked(b, .depends_on, c);
    for (graph.nodes.items) |node| try store.appendNode(node);
    try store.appendEdge(graph.edges.items[ab.toInt() - 1]);
    try store.appendEdge(graph.edges.items[bc.toInt() - 1]);
    try store.ensurePersistentEdgeIndexes(&graph);

    try std.testing.expect(try reachableWithPersistentStore(std.testing.allocator, store, a, c, .depends_on, .{}));
    try std.testing.expect(try reachableWithPersistentStore(std.testing.allocator, store, a, a, .depends_on, .{
        .max_visited_nodes = 0,
        .max_visited_edges = 0,
        .max_depth = 0,
    }));
    try std.testing.expect(!try reachableWithPersistentStore(std.testing.allocator, store, a, c, .blocks, .{}));
    try std.testing.expectError(core.Error.InvalidId, reachableWithPersistentStore(std.testing.allocator, store, .none, c, .depends_on, .{}));
    try std.testing.expectError(core.Error.InvalidId, reachableWithPersistentStore(std.testing.allocator, store, a, .none, .depends_on, .{}));
    try std.testing.expectError(core.Error.InvalidId, reachableWithPersistentStore(std.testing.allocator, store, .fromInt(std.math.maxInt(u64)), c, .depends_on, .{}));
    try std.testing.expectError(core.Error.InvalidId, reachableWithPersistentStore(std.testing.allocator, store, a, .fromInt(std.math.maxInt(u64)), .depends_on, .{}));
    try std.testing.expectError(core.Error.NotFound, reachableWithPersistentStore(std.testing.allocator, store, a, .fromInt(99), .depends_on, .{}));
    try std.testing.expectError(core.Error.BudgetExceeded, reachableWithPersistentStore(std.testing.allocator, store, a, c, .depends_on, .{ .timeout_ms = 0 }));
    try std.testing.expectError(core.Error.CycleCheckUncertain, wouldCreateCycleWithPersistentStore(std.testing.allocator, store, c, a, .depends_on, .{ .timeout_ms = 0 }));
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(
        core.Error.BudgetExceeded,
        reachableWithPersistentStore(failing.allocator(), store, a, c, .depends_on, .{ .max_visited_nodes = 0 }),
    );
    try std.testing.expectError(
        core.Error.CycleCheckUncertain,
        wouldCreateCycleWithPersistentStore(failing.allocator(), store, c, a, .depends_on, .{ .max_visited_nodes = 0 }),
    );
    try std.testing.expectError(core.Error.InvalidId, wouldCreateCycleWithPersistentStore(std.testing.allocator, store, .none, a, .calls, .{}));
    try std.testing.expectError(core.Error.InvalidId, wouldCreateCycleWithPersistentStore(std.testing.allocator, store, a, .none, .calls, .{}));
    try std.testing.expectError(core.Error.InvalidId, wouldCreateCycleWithPersistentStore(std.testing.allocator, store, .fromInt(std.math.maxInt(u64)), a, .calls, .{}));
    try std.testing.expectError(core.Error.InvalidId, wouldCreateCycleWithPersistentStore(std.testing.allocator, store, a, .fromInt(std.math.maxInt(u64)), .calls, .{}));
    try std.testing.expectError(
        core.Error.BudgetExceeded,
        reachableWithPersistentStore(std.testing.allocator, store, a, c, .depends_on, .{ .max_visited_edges = 1 }),
    );
    try std.testing.expectError(
        core.Error.BudgetExceeded,
        reachableWithPersistentStore(std.testing.allocator, store, a, c, .depends_on, .{ .max_depth = 1 }),
    );
    try std.testing.expectError(
        core.Error.CycleCheckUncertain,
        wouldCreateCycleWithPersistentStore(std.testing.allocator, store, c, a, .depends_on, .{ .max_depth = 1 }),
    );
}

test "persistent reachability routes through published edge segment before index fallback" {
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

    const a = core.NodeId.fromInt(1);
    const b = core.NodeId.fromInt(2);
    const c = core.NodeId.fromInt(3);
    try store.appendNode(.{ .id = a, .kind = .task, .text = "a" });
    try store.appendNode(.{ .id = b, .kind = .task, .text = "b" });
    try store.appendNode(.{ .id = c, .kind = .task, .text = "c" });
    try store.appendEdge(.{ .id = .fromInt(1), .src = a, .dst = b, .rel = .depends_on });
    try store.appendEdge(.{ .id = .fromInt(2), .src = b, .dst = c, .rel = .depends_on });
    try std.testing.expectEqual(@as(u64, 2), try store.publishEdgeAdjacencySegment(segment_path));

    try std.Io.Dir.cwd().deleteFile(std.testing.io, store.edge_by_src_path);
    try std.testing.expect(try reachableWithPersistentStore(std.testing.allocator, store, a, c, .depends_on, .{}));
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().openFile(std.testing.io, store.edge_by_src_path, .{}));
}

test "persistent reachability uses relation-bounded edge budget" {
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

    var stats: index.QueryStats = .{};
    try std.testing.expect(try reachableWithPersistentStoreMeasured(std.testing.allocator, store, a, b, .depends_on, .{ .max_visited_edges = 1 }, &stats));
    try std.testing.expectEqual(@as(usize, 1), stats.edges_visited);
}

test "persistent reachability measured stats reject overflow" {
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
    try store.appendNode(.{ .id = a, .kind = .task, .text = "a" });
    try store.appendNode(.{ .id = b, .kind = .task, .text = "b" });
    try store.appendEdge(.{ .id = .fromInt(1), .src = a, .rel = .depends_on, .dst = b });

    var node_stats = index.QueryStats{ .nodes_visited = std.math.maxInt(usize) };
    try std.testing.expectError(
        error.RecordTooLarge,
        reachableWithPersistentStoreMeasured(std.testing.allocator, store, a, b, .depends_on, .{}, &node_stats),
    );
    try std.testing.expectEqual(std.math.maxInt(usize), node_stats.nodes_visited);

    var edge_stats = index.QueryStats{ .edges_visited = std.math.maxInt(usize) };
    try std.testing.expectError(
        error.RecordTooLarge,
        reachableWithPersistentStoreMeasured(std.testing.allocator, store, a, b, .depends_on, .{}, &edge_stats),
    );
    try std.testing.expectEqual(std.math.maxInt(usize), edge_stats.edges_visited);
}

test "persistent reachability repairs corrupt edge index" {
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
    const a = try graph.addNode(.task, "a");
    const b = try graph.addNode(.task, "b");
    const edge = try graph.addEdgeUnchecked(a, .depends_on, b);
    for (graph.nodes.items) |node| try store.appendNode(node);
    try store.appendEdge(graph.edges.items[edge.toInt() - 1]);

    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = store.edge_by_src_path,
        .data = "bad",
        .flags = .{ .truncate = true },
    });
    try std.testing.expectError(
        error.InvalidRecord,
        store.readEdgeIndexRecordsByNode(std.testing.allocator, .src, a),
    );

    try std.testing.expect(try reachableWithPersistentStore(std.testing.allocator, store, a, b, .depends_on, .{}));
}

test "persistent reachability repairs dangling edge index target" {
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

    try store.appendNode(.{ .id = .fromInt(1), .kind = .task, .text = "a" });
    try store.appendNode(.{ .id = .fromInt(2), .kind = .task, .text = "b" });
    try store.appendEdge(.{ .id = .fromInt(1), .src = .fromInt(1), .rel = .depends_on, .dst = .fromInt(2) });

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
    std.mem.writeInt(u64, bytes[record_offset + 0 .. record_offset + 8], 1, .little);
    std.mem.writeInt(u64, bytes[record_offset + 8 .. record_offset + 16], 99, .little);
    std.mem.writeInt(u64, bytes[record_offset + 16 .. record_offset + 24], 1, .little);
    std.mem.writeInt(u16, bytes[record_offset + 24 .. record_offset + 26], @intFromEnum(core.RelKind.depends_on), .little);
    @memset(bytes[record_offset + 26 .. record_offset + 34], 0);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = store.edge_by_src_path,
        .data = &bytes,
        .flags = .{ .truncate = true },
    });

    try std.testing.expect(try reachableWithPersistentStore(std.testing.allocator, store, .fromInt(1), .fromInt(2), .depends_on, .{}));
}

test "checked persistent edge append rejects DAG cycles before commit" {
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

    try store.appendNode(.{ .id = .fromInt(1), .kind = .task, .text = "a" });
    try store.appendNode(.{ .id = .fromInt(2), .kind = .task, .text = "b" });

    try appendEdgeCheckedWithPersistentStore(std.testing.allocator, store, .{
        .id = .fromInt(1),
        .src = .fromInt(1),
        .rel = .depends_on,
        .dst = .fromInt(2),
    }, .{});
    try std.testing.expectError(core.Error.CycleDetected, appendEdgeCheckedWithPersistentStore(std.testing.allocator, store, .{
        .id = .fromInt(2),
        .src = .fromInt(2),
        .rel = .depends_on,
        .dst = .fromInt(1),
    }, .{}));

    const stats = try store.stats();
    try std.testing.expectEqual(@as(usize, 1), stats.edges);
    try appendEdgeCheckedWithPersistentStore(std.testing.allocator, store, .{
        .id = .fromInt(2),
        .src = .fromInt(2),
        .rel = .calls,
        .dst = .fromInt(1),
    }, .{});
}

test "checked persistent edge append rejects DAG self loops before commit" {
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

    try store.appendNode(.{ .id = .fromInt(1), .kind = .task, .text = "self" });
    try std.testing.expectError(core.Error.CycleDetected, appendEdgeCheckedWithPersistentStore(std.testing.allocator, store, .{
        .id = .fromInt(1),
        .src = .fromInt(1),
        .rel = .depends_on,
        .dst = .fromInt(1),
    }, .{}));
    try std.testing.expectEqual(@as(usize, 0), (try store.stats()).edges);

    try appendEdgeCheckedWithPersistentStore(std.testing.allocator, store, .{
        .id = .fromInt(1),
        .src = .fromInt(1),
        .rel = .related_to,
        .dst = .fromInt(1),
    }, .{});
    try std.testing.expectEqual(@as(usize, 1), (try store.stats()).edges);
}

test "checked persistent edge add allocates ids and rejects DAG cycles" {
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

    const a = try store.addNode(.task, "a");
    const b = try store.addNode(.task, "b");
    const first = try addEdgeCheckedWithPersistentStore(std.testing.allocator, store, a, .depends_on, b, .{});
    try std.testing.expectEqual(@as(u64, 1), first.toInt());
    try std.testing.expectError(core.Error.CycleDetected, addEdgeCheckedWithPersistentStore(std.testing.allocator, store, b, .depends_on, a, .{}));
    try std.testing.expectEqual(@as(u64, 2), (try store.nextEdgeId()).toInt());

    const calls = try addEdgeCheckedWithPersistentStore(std.testing.allocator, store, b, .calls, a, .{});
    try std.testing.expectEqual(@as(u64, 2), calls.toInt());
}

test "checked persistent edge writes fail closed when cycle check is uncertain" {
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

    const a = try store.addNode(.task, "a");
    const b = try store.addNode(.task, "b");
    _ = try addEdgeCheckedWithPersistentStore(std.testing.allocator, store, a, .depends_on, b, .{});

    const before_events = try store.eventByteCount();
    try std.testing.expectEqual(@as(usize, 1), (try store.stats()).edges);

    try std.testing.expectError(
        core.Error.CycleCheckUncertain,
        addEdgeCheckedWithPersistentStore(std.testing.allocator, store, b, .depends_on, a, .{ .timeout_ms = 0 }),
    );
    try std.testing.expectEqual(before_events, try store.eventByteCount());
    try std.testing.expectEqual(@as(usize, 1), (try store.stats()).edges);
    try std.testing.expectEqual(@as(u64, 2), (try store.nextEdgeId()).toInt());

    try std.testing.expectError(
        core.Error.CycleCheckUncertain,
        appendEdgeCheckedWithPersistentStore(std.testing.allocator, store, .{
            .id = .fromInt(2),
            .src = b,
            .rel = .depends_on,
            .dst = a,
        }, .{ .max_visited_edges = 0 }),
    );
    try std.testing.expectEqual(before_events, try store.eventByteCount());
    try std.testing.expectEqual(@as(usize, 1), (try store.stats()).edges);
}

test "checked persistent edge add reallocates id after stale allocation repair" {
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

    const a = try store.addNode(.task, "a");
    const b = try store.addNode(.task, "b");
    const c = try store.addNode(.task, "c");
    _ = try addEdgeCheckedWithPersistentStore(std.testing.allocator, store, a, .depends_on, b, .{});
    try store.appendEdge(.{ .id = .fromInt(2), .src = b, .rel = .depends_on, .dst = c });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = store.index_meta_path,
        .data = "bad",
        .flags = .{ .truncate = true },
    });

    const added = try addEdgeCheckedWithPersistentStore(std.testing.allocator, store, c, .calls, a, .{});
    try std.testing.expectEqual(@as(u64, 3), added.toInt());
}

test "checked persistent edge append repairs corrupt node catalog before direct append" {
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

    const a = try store.addNode(.task, "a");
    const b = try store.addNode(.task, "b");
    var texts = try std.Io.Dir.cwd().createFile(std.testing.io, store.node_texts_path, .{
        .read = true,
        .truncate = false,
    });
    defer texts.close(std.testing.io);
    try texts.writePositionalAll(std.testing.io, "trailing garbage", (try texts.stat(std.testing.io)).size);
    try std.testing.expectError(error.InvalidRecord, store.readNodeById(std.testing.allocator, a));

    try appendEdgeCheckedWithPersistentStore(std.testing.allocator, store, .{
        .id = .fromInt(1),
        .src = a,
        .rel = .depends_on,
        .dst = b,
    }, .{});
    try std.testing.expectEqual(@as(usize, 1), (try store.stats()).edges);
}

test "persistent reachability does not charge duplicate discovered frontier nodes" {
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
    const d = try graph.addNode(.task, "d");
    const f = try graph.addNode(.task, "f");
    const ab = try graph.addEdgeUnchecked(a, .depends_on, b);
    const ac = try graph.addEdgeUnchecked(a, .depends_on, c);
    const bd = try graph.addEdgeUnchecked(b, .depends_on, d);
    const cd = try graph.addEdgeUnchecked(c, .depends_on, d);
    for (graph.nodes.items) |node| try store.appendNode(node);
    try store.appendEdge(graph.edges.items[ab.toInt() - 1]);
    try store.appendEdge(graph.edges.items[ac.toInt() - 1]);
    try store.appendEdge(graph.edges.items[bd.toInt() - 1]);
    try store.appendEdge(graph.edges.items[cd.toInt() - 1]);
    try store.ensurePersistentEdgeIndexes(&graph);

    try std.testing.expect(!try reachableWithPersistentStore(std.testing.allocator, store, a, f, .depends_on, .{
        .max_visited_nodes = 4,
        .max_depth = 3,
    }));
}

test "topological sort rejects cycles" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    const a = try graph.addNode(.task, "a");
    const b = try graph.addNode(.task, "b");
    _ = try graph.addEdgeUnchecked(a, .depends_on, b);
    _ = try graph.addEdgeUnchecked(b, .depends_on, a);
    try std.testing.expectError(core.Error.CycleDetected, topoSort(std.testing.allocator, &graph, .depends_on));
}

test "topological sort ignores dangling edge endpoints" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    const a = try graph.addNode(.task, "a");
    const b = try graph.addNode(.task, "b");
    const missing = core.NodeId.fromInt(99);
    try graph.edges.append(std.testing.allocator, .{ .id = .fromInt(1), .src = a, .dst = missing, .rel = .depends_on });
    try graph.edges.append(std.testing.allocator, .{ .id = .fromInt(2), .src = missing, .dst = b, .rel = .depends_on });

    var sorted = try topoSort(std.testing.allocator, &graph, .depends_on);
    defer sorted.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), sorted.items.len);
    for (sorted.items) |id| {
        try std.testing.expect(id.toInt() != missing.toInt());
    }
}

test "topological sort cursor path counts indegree from cursor edges only" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    const a = try graph.addNode(.task, "a");
    const b = try graph.addNode(.task, "b");
    _ = try graph.addEdgeUnchecked(a, .depends_on, b);

    var cursor_graph = graph_mod.Graph.init(std.testing.allocator);
    defer cursor_graph.deinit();
    try cursor_graph.addNodeWithId(a, .task, "a");
    try cursor_graph.addNodeWithId(b, .task, "b");
    var cursor_index = try index.MemoryIndex.init(std.testing.allocator, &cursor_graph);
    defer cursor_index.deinit();

    var sorted = try topoSortWithCursor(
        std.testing.allocator,
        &graph,
        &cursor_index,
        .{ .memory = .{ .mem_index = &cursor_index } },
        .depends_on,
    );
    defer sorted.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), sorted.items.len);
}

test "topological sort ignores non-active nodes and edges" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    const active = try graph.addNode(.task, "active");
    const stale = try graph.addNode(.task, "stale");
    const target = try graph.addNode(.task, "target");
    const stale_edge = try graph.addEdgeUnchecked(active, .depends_on, target);
    for (graph.nodes.items) |*node| {
        if (node.id == stale) node.status = .stale;
    }
    for (graph.edges.items) |*edge| {
        if (edge.id == stale_edge) edge.status = .stale;
    }

    var sorted = try topoSort(std.testing.allocator, &graph, .depends_on);
    defer sorted.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), sorted.items.len);
    for (sorted.items) |id| {
        try std.testing.expect(id.toInt() != stale.toInt());
    }
}

test "topological sort indegree increment rejects overflow" {
    try std.testing.expectEqual(@as(usize, 1), try incrementIndegree(0));
    try std.testing.expectEqual(std.math.maxInt(usize), try incrementIndegree(std.math.maxInt(usize) - 1));
    try std.testing.expectError(error.RecordTooLarge, incrementIndegree(std.math.maxInt(usize)));
}

test "traversal counter increment rejects overflow" {
    try std.testing.expectEqual(@as(usize, 1), try traversal.incrementCounter(0));
    try std.testing.expectEqual(std.math.maxInt(usize), try traversal.incrementCounter(std.math.maxInt(usize) - 1));
    try std.testing.expectError(core.Error.BudgetExceeded, traversal.incrementCounter(std.math.maxInt(usize)));
}

test "topological sort rejects non-DAG relations" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    const a = try graph.addNode(.function, "a");
    const b = try graph.addNode(.function, "b");
    _ = try graph.addEdgeUnchecked(a, .calls, b);

    try std.testing.expectError(core.Error.Unsupported, topoSort(std.testing.allocator, &graph, .calls));
}
