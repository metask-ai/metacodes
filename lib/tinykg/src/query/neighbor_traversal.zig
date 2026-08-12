const std = @import("std");

/// Owns bounded relation-filtered neighbor collection. Concrete cursor,
/// lookup, storage-repair, and reader-lifetime behavior remain in the facade.
pub fn NeighborTraversal(
    comptime core: type,
    comptime index: type,
    comptime EdgeCursor: type,
    comptime NodeLookup: type,
) type {
    return struct {
        pub const Neighbor = struct {
            edge_id: core.EdgeId,
            node_id: core.NodeId,
            rel: core.RelKind,
        };

        pub const NeighborResult = struct {
            neighbors: std.ArrayList(Neighbor),
            stats: index.QueryStats,

            pub fn deinit(self: *NeighborResult, allocator: std.mem.Allocator) void {
                self.neighbors.deinit(allocator);
            }
        };

        pub fn neighborsWithCursor(
            allocator: std.mem.Allocator,
            cursor: EdgeCursor,
            node_id: core.NodeId,
            rel_filter: ?core.RelKind,
            budget: core.QueryBudget,
        ) !NeighborResult {
            if (isReservedNodeId(node_id)) return core.Error.InvalidId;
            return neighborsWithCursorAndLookup(allocator, cursor, null, node_id, rel_filter, budget);
        }

        pub fn neighborsWithCursorAndLookup(
            allocator: std.mem.Allocator,
            cursor: EdgeCursor,
            node_lookup: ?NodeLookup,
            node_id: core.NodeId,
            rel_filter: ?core.RelKind,
            budget: core.QueryBudget,
        ) !NeighborResult {
            return neighborsWithCursorAndLookupDeadline(
                allocator,
                cursor,
                node_lookup,
                node_id,
                rel_filter,
                budget,
                core.QueryDeadline.immediateOrNone(budget.timeout_ms),
            );
        }

        pub fn neighborsWithCursorAndLookupDeadline(
            allocator: std.mem.Allocator,
            cursor: EdgeCursor,
            node_lookup: ?NodeLookup,
            node_id: core.NodeId,
            rel_filter: ?core.RelKind,
            budget: core.QueryBudget,
            deadline: core.QueryDeadline,
        ) !NeighborResult {
            var result = NeighborResult{
                .neighbors = .empty,
                .stats = .{},
            };
            errdefer result.deinit(allocator);
            if (deadline.expired()) {
                result.stats.budget_exceeded = true;
                return result;
            }

            var context = NeighborCollectContext{
                .allocator = allocator,
                .result = &result,
                .rel_filter = rel_filter,
                .budget = budget,
                .node_lookup = node_lookup,
                .deadline = deadline,
            };
            _ = try cursor.forEachOutgoingRelation(node_id, rel_filter, &context, collectNeighbor);
            result.stats.results = result.neighbors.items.len;
            return result;
        }

        const NeighborCollectContext = struct {
            allocator: std.mem.Allocator,
            result: *NeighborResult,
            rel_filter: ?core.RelKind,
            budget: core.QueryBudget,
            node_lookup: ?NodeLookup,
            deadline: core.QueryDeadline,
            preallocated: bool = false,
        };

        fn collectNeighbor(ctx: *NeighborCollectContext, edge: index.EdgeRef) !bool {
            if (ctx.deadline.expired()) {
                ctx.result.stats.budget_exceeded = true;
                return true;
            }
            if (ctx.result.stats.edges_visited >= ctx.budget.max_visited_edges) {
                ctx.result.stats.budget_exceeded = true;
                return true;
            }
            try index.addVisitedEdges(&ctx.result.stats, 1);
            if (ctx.rel_filter) |rel| {
                if (edge.rel != rel) return false;
            }
            if (ctx.node_lookup) |lookup| {
                if (!try lookup.exists(edge.dst)) return false;
            }
            if (ctx.result.neighbors.items.len >= ctx.budget.max_results) {
                ctx.result.stats.budget_exceeded = true;
                return true;
            }
            if (!ctx.preallocated) {
                try ctx.result.neighbors.ensureTotalCapacity(ctx.allocator, neighborPreallocCapacity(ctx.budget));
                ctx.preallocated = true;
            }
            try ctx.result.neighbors.append(ctx.allocator, .{
                .edge_id = edge.edge_id,
                .node_id = edge.dst,
                .rel = edge.rel,
            });
            return false;
        }

        fn neighborPreallocCapacity(budget: core.QueryBudget) usize {
            const max_neighbor_prealloc: usize = 256;
            return @min(max_neighbor_prealloc, @min(budget.max_results, budget.max_visited_edges));
        }

        fn isReservedNodeId(id: core.NodeId) bool {
            return id == .none or id.toInt() == std.math.maxInt(u64);
        }
    };
}

const TestNodeId = enum(u64) {
    none = 0,
    _,

    fn fromInt(value: u64) TestNodeId {
        return @enumFromInt(value);
    }

    fn toInt(self: TestNodeId) u64 {
        return @intFromEnum(self);
    }
};

const TestEdgeId = enum(u64) {
    none = 0,
    _,

    fn fromInt(value: u64) TestEdgeId {
        return @enumFromInt(value);
    }

    fn toInt(self: TestEdgeId) u64 {
        return @intFromEnum(self);
    }
};

const TestCore = struct {
    const NodeId = TestNodeId;
    const EdgeId = TestEdgeId;
    const RelKind = enum { based_on, related_to };
    const Error = error{InvalidId};
    const QueryBudget = struct {
        max_results: usize = 32,
        max_visited_edges: usize = 64,
        timeout_ms: u64 = 1000,
    };
    const QueryDeadline = struct {
        is_expired: bool,

        fn immediateOrNone(timeout_ms: u64) @This() {
            return .{ .is_expired = timeout_ms == 0 };
        }

        fn expired(self: @This()) bool {
            return self.is_expired;
        }
    };
};

const TestIndex = struct {
    const EdgeRef = struct {
        src: TestNodeId,
        dst: TestNodeId,
        edge_id: TestEdgeId,
        rel: TestCore.RelKind,
    };
    const QueryStats = struct {
        nodes_visited: usize = 0,
        edges_visited: usize = 0,
        results: usize = 0,
        budget_exceeded: bool = false,
    };

    fn addVisitedEdges(stats: *QueryStats, amount: usize) !void {
        stats.edges_visited = try std.math.add(usize, stats.edges_visited, amount);
    }
};

const TestNodeLookup = struct {
    nodes: []const TestNodeId,

    fn exists(self: @This(), node_id: TestNodeId) !bool {
        return std.mem.indexOfScalar(TestNodeId, self.nodes, node_id) != null;
    }
};

const TestEdgeCursor = struct {
    edges: []const TestIndex.EdgeRef,
    scanned: *usize,

    fn forEachOutgoingRelation(
        self: @This(),
        node_id: TestNodeId,
        _: ?TestCore.RelKind,
        context: anytype,
        comptime callback: fn (@TypeOf(context), TestIndex.EdgeRef) anyerror!bool,
    ) !bool {
        for (self.edges) |edge| {
            if (edge.src != node_id) continue;
            self.scanned.* += 1;
            if (try callback(context, edge)) return true;
        }
        return false;
    }
};

const TestNeighborTraversal = NeighborTraversal(TestCore, TestIndex, TestEdgeCursor, TestNodeLookup);

fn testEdge(id: u64, src: u64, dst: u64, rel: TestCore.RelKind) TestIndex.EdgeRef {
    return .{
        .src = .fromInt(src),
        .dst = .fromInt(dst),
        .edge_id = .fromInt(id),
        .rel = rel,
    };
}

fn testBudget() TestCore.QueryBudget {
    return .{};
}

test "neighbor traversal rejects reserved source ids" {
    var scanned: usize = 0;
    try std.testing.expectError(
        error.InvalidId,
        TestNeighborTraversal.neighborsWithCursor(
            std.testing.allocator,
            .{ .edges = &.{}, .scanned = &scanned },
            .none,
            null,
            testBudget(),
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), scanned);
}

test "neighbor traversal filters and projects stable neighbors" {
    const edges = [_]TestIndex.EdgeRef{
        testEdge(7, 1, 2, .based_on),
        testEdge(8, 1, 3, .related_to),
    };
    var scanned: usize = 0;
    var result = try TestNeighborTraversal.neighborsWithCursor(
        std.testing.allocator,
        .{ .edges = &edges, .scanned = &scanned },
        .fromInt(1),
        .based_on,
        testBudget(),
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), result.neighbors.items.len);
    try std.testing.expectEqual(@as(u64, 7), result.neighbors.items[0].edge_id.toInt());
    try std.testing.expectEqual(@as(u64, 2), result.neighbors.items[0].node_id.toInt());
    try std.testing.expectEqual(TestCore.RelKind.based_on, result.neighbors.items[0].rel);
    try std.testing.expectEqual(@as(usize, 2), result.stats.edges_visited);
}

test "neighbor traversal skips missing targets through lookup" {
    const edges = [_]TestIndex.EdgeRef{
        testEdge(7, 1, 2, .based_on),
        testEdge(8, 1, 3, .based_on),
    };
    var scanned: usize = 0;
    var result = try TestNeighborTraversal.neighborsWithCursorAndLookup(
        std.testing.allocator,
        .{ .edges = &edges, .scanned = &scanned },
        .{ .nodes = &.{.fromInt(2)} },
        .fromInt(1),
        .based_on,
        testBudget(),
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), result.neighbors.items.len);
    try std.testing.expectEqual(@as(u64, 2), result.neighbors.items[0].node_id.toInt());
    try std.testing.expectEqual(@as(usize, 2), result.stats.edges_visited);
}

test "neighbor traversal charges exact edge budget" {
    const edges = [_]TestIndex.EdgeRef{
        testEdge(7, 1, 2, .based_on),
        testEdge(8, 1, 3, .based_on),
    };
    var scanned: usize = 0;
    var budget = testBudget();
    budget.max_visited_edges = 1;
    var result = try TestNeighborTraversal.neighborsWithCursor(
        std.testing.allocator,
        .{ .edges = &edges, .scanned = &scanned },
        .fromInt(1),
        null,
        budget,
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), result.neighbors.items.len);
    try std.testing.expectEqual(@as(usize, 1), result.stats.edges_visited);
    try std.testing.expect(result.stats.budget_exceeded);
}

test "neighbor traversal enforces result limit before allocation" {
    const edges = [_]TestIndex.EdgeRef{testEdge(7, 1, 2, .based_on)};
    var scanned: usize = 0;
    var budget = testBudget();
    budget.max_results = 0;
    var bytes: [0]u8 = .{};
    var fixed = std.heap.FixedBufferAllocator.init(&bytes);
    var result = try TestNeighborTraversal.neighborsWithCursor(
        fixed.allocator(),
        .{ .edges = &edges, .scanned = &scanned },
        .fromInt(1),
        null,
        budget,
    );
    defer result.deinit(fixed.allocator());

    try std.testing.expectEqual(@as(usize, 0), result.neighbors.items.len);
    try std.testing.expectEqual(@as(usize, 1), result.stats.edges_visited);
    try std.testing.expect(result.stats.budget_exceeded);
}

test "neighbor traversal stops on expired deadline" {
    const edges = [_]TestIndex.EdgeRef{testEdge(7, 1, 2, .based_on)};
    var scanned: usize = 0;
    var result = try TestNeighborTraversal.neighborsWithCursorAndLookupDeadline(
        std.testing.allocator,
        .{ .edges = &edges, .scanned = &scanned },
        null,
        .fromInt(1),
        null,
        testBudget(),
        .{ .is_expired = true },
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), scanned);
    try std.testing.expect(result.stats.budget_exceeded);
}

test "neighbor traversal stops cursor after result budget" {
    const edges = [_]TestIndex.EdgeRef{
        testEdge(7, 1, 2, .based_on),
        testEdge(8, 1, 3, .based_on),
        testEdge(9, 1, 4, .based_on),
    };
    var scanned: usize = 0;
    var budget = testBudget();
    budget.max_results = 1;
    var result = try TestNeighborTraversal.neighborsWithCursor(
        std.testing.allocator,
        .{ .edges = &edges, .scanned = &scanned },
        .fromInt(1),
        null,
        budget,
    );
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), result.neighbors.items.len);
    try std.testing.expectEqual(@as(usize, 2), scanned);
    try std.testing.expect(result.stats.budget_exceeded);
}
