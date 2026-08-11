const std = @import("std");

/// Owns bounded breadth-first path traversal. Cursor/storage adapters and
/// persistent repair remain in the query facade; this owner only requires a
/// cursor with `forEachOutgoingRelation` and a lookup with `exists`.
pub fn PathTraversal(comptime core: type, comptime index: type) type {
    return struct {
        pub const PathResult = struct {
            nodes: std.ArrayList(core.NodeId),
            stats: index.QueryStats,

            pub fn deinit(self: *PathResult, allocator: std.mem.Allocator) void {
                self.nodes.deinit(allocator);
            }
        };

        pub fn pathWithCursor(
            allocator: std.mem.Allocator,
            cursor: anytype,
            node_lookup: anytype,
            from: core.NodeId,
            to: core.NodeId,
            rel_filter: ?core.RelKind,
            budget: core.QueryBudget,
        ) !PathResult {
            return pathWithCursorDeadline(
                allocator,
                cursor,
                node_lookup,
                from,
                to,
                rel_filter,
                budget,
                core.QueryDeadline.immediateOrNone(budget.timeout_ms),
                false,
            );
        }

        pub fn pathWithCursorDeadline(
            allocator: std.mem.Allocator,
            cursor: anytype,
            node_lookup: anytype,
            from: core.NodeId,
            to: core.NodeId,
            rel_filter: ?core.RelKind,
            budget: core.QueryBudget,
            deadline: core.QueryDeadline,
            missing_edge_target_is_invalid: bool,
        ) !PathResult {
            var result = PathResult{ .nodes = .empty, .stats = .{} };
            errdefer result.deinit(allocator);

            if (isReservedNodeId(from) or isReservedNodeId(to)) return core.Error.InvalidId;
            if (deadline.expired()) {
                result.stats.budget_exceeded = true;
                return result;
            }
            if (from.toInt() == to.toInt()) {
                if (!try node_lookup.exists(from)) return core.Error.NotFound;
                try result.nodes.append(allocator, from);
                result.stats.results = 1;
                return result;
            }
            if (pathNodeBudgetExhausted(&result, budget)) return result;
            if (!try node_lookup.exists(from) or !try node_lookup.exists(to)) return core.Error.NotFound;

            var frontier = std.ArrayList(core.NodeId).empty;
            defer frontier.deinit(allocator);
            var parents = std.AutoHashMap(u64, u64).init(allocator);
            defer parents.deinit();
            var depths = std.AutoHashMap(u64, u8).init(allocator);
            defer depths.deinit();

            const prealloc_nodes = traversalPreallocNodeCapacity(budget);
            try frontier.ensureTotalCapacity(allocator, prealloc_nodes);
            try parents.ensureTotalCapacity(@intCast(prealloc_nodes));
            try depths.ensureTotalCapacity(@intCast(prealloc_nodes));
            try frontier.append(allocator, from);
            try parents.put(from.toInt(), 0);
            try depths.put(from.toInt(), 0);

            var pos: usize = 0;
            while (pos < frontier.items.len) : (pos += 1) {
                if (deadline.expired()) {
                    result.stats.budget_exceeded = true;
                    return result;
                }
                if (result.stats.nodes_visited >= budget.max_visited_nodes) {
                    result.stats.budget_exceeded = true;
                    return result;
                }
                const current = frontier.items[pos];
                const current_depth = depths.get(current.toInt()).?;
                try index.addVisitedNodes(&result.stats, 1);
                if (current_depth >= budget.max_depth) {
                    if (try depthLimitWouldTruncate(cursor, node_lookup, current, rel_filter, &parents, &result, budget, deadline, missing_edge_target_is_invalid)) {
                        result.stats.budget_exceeded = true;
                    }
                    continue;
                }

                const Context = PathExploreContext(@TypeOf(node_lookup));
                var context = Context{
                    .allocator = allocator,
                    .result = &result,
                    .frontier = &frontier,
                    .parents = &parents,
                    .depths = &depths,
                    .node_lookup = node_lookup,
                    .current = current,
                    .current_depth = current_depth,
                    .from = from,
                    .to = to,
                    .budget = budget,
                    .deadline = deadline,
                    .missing_edge_target_is_invalid = missing_edge_target_is_invalid,
                };
                _ = try cursor.forEachOutgoingRelation(current, rel_filter, &context, Context.explorePathEdge);
                if (result.stats.budget_exceeded or result.nodes.items.len != 0) return result;
            }
            return result;
        }

        fn PathExploreContext(comptime NodeLookup: type) type {
            return struct {
                allocator: std.mem.Allocator,
                result: *PathResult,
                frontier: *std.ArrayList(core.NodeId),
                parents: *std.AutoHashMap(u64, u64),
                depths: *std.AutoHashMap(u64, u8),
                node_lookup: NodeLookup,
                current: core.NodeId,
                current_depth: u8,
                from: core.NodeId,
                to: core.NodeId,
                budget: core.QueryBudget,
                deadline: core.QueryDeadline,
                missing_edge_target_is_invalid: bool,

                fn explorePathEdge(ctx: *@This(), edge: index.EdgeRef) !bool {
                    if (ctx.deadline.expired()) {
                        ctx.result.stats.budget_exceeded = true;
                        return true;
                    }
                    if (ctx.result.stats.edges_visited >= ctx.budget.max_visited_edges) {
                        ctx.result.stats.budget_exceeded = true;
                        return true;
                    }
                    try index.addVisitedEdges(&ctx.result.stats, 1);
                    if (ctx.parents.contains(edge.dst.toInt())) return false;
                    if (!try ctx.node_lookup.exists(edge.dst)) {
                        if (ctx.missing_edge_target_is_invalid) return error.InvalidRecord;
                        return false;
                    }
                    try ctx.parents.put(edge.dst.toInt(), ctx.current.toInt());
                    try ctx.depths.put(edge.dst.toInt(), ctx.current_depth + 1);
                    if (edge.dst.toInt() == ctx.to.toInt()) {
                        try reconstructPath(ctx.allocator, &ctx.result.nodes, ctx.parents, ctx.from, ctx.to);
                        ctx.result.stats.results = 1;
                        return true;
                    }
                    try ctx.frontier.append(ctx.allocator, edge.dst);
                    return false;
                }
            };
        }

        fn DepthLimitContext(comptime NodeLookup: type) type {
            return struct {
                node_lookup: NodeLookup,
                parents: *std.AutoHashMap(u64, u64),
                result: *PathResult,
                budget: core.QueryBudget,
                deadline: core.QueryDeadline,
                missing_edge_target_is_invalid: bool,

                fn depthLimitEdgeCallback(ctx: *@This(), edge: index.EdgeRef) !bool {
                    if (ctx.deadline.expired()) {
                        ctx.result.stats.budget_exceeded = true;
                        return true;
                    }
                    if (ctx.result.stats.edges_visited >= ctx.budget.max_visited_edges) {
                        ctx.result.stats.budget_exceeded = true;
                        return true;
                    }
                    try index.addVisitedEdges(&ctx.result.stats, 1);
                    if (ctx.parents.contains(edge.dst.toInt())) return false;
                    if (!try ctx.node_lookup.exists(edge.dst)) {
                        if (ctx.missing_edge_target_is_invalid) return error.InvalidRecord;
                        return false;
                    }
                    return true;
                }
            };
        }

        fn depthLimitWouldTruncate(
            cursor: anytype,
            node_lookup: anytype,
            current: core.NodeId,
            rel_filter: ?core.RelKind,
            parents: *std.AutoHashMap(u64, u64),
            result: *PathResult,
            budget: core.QueryBudget,
            deadline: core.QueryDeadline,
            missing_edge_target_is_invalid: bool,
        ) !bool {
            const Context = DepthLimitContext(@TypeOf(node_lookup));
            var context = Context{
                .node_lookup = node_lookup,
                .parents = parents,
                .result = result,
                .budget = budget,
                .deadline = deadline,
                .missing_edge_target_is_invalid = missing_edge_target_is_invalid,
            };
            return cursor.forEachOutgoingRelation(current, rel_filter, &context, Context.depthLimitEdgeCallback);
        }

        fn isReservedNodeId(id: core.NodeId) bool {
            return id == .none or id.toInt() == std.math.maxInt(u64);
        }

        fn pathNodeBudgetExhausted(result: *PathResult, budget: core.QueryBudget) bool {
            if (result.stats.nodes_visited < budget.max_visited_nodes) return false;
            result.stats.budget_exceeded = true;
            return true;
        }

        fn traversalPreallocNodeCapacity(budget: core.QueryBudget) usize {
            const max_prealloc_nodes: usize = 16 * 1024;
            const wanted = std.math.add(usize, budget.max_visited_nodes, 1) catch max_prealloc_nodes;
            return @min(wanted, max_prealloc_nodes);
        }

        fn reconstructPath(
            allocator: std.mem.Allocator,
            out: *std.ArrayList(core.NodeId),
            parents: *std.AutoHashMap(u64, u64),
            from: core.NodeId,
            to: core.NodeId,
        ) !void {
            var reversed = std.ArrayList(core.NodeId).empty;
            defer reversed.deinit(allocator);
            var current = to.toInt();
            while (current != 0) {
                try reversed.append(allocator, core.NodeId.fromInt(current));
                if (current == from.toInt()) break;
                current = parents.get(current) orelse 0;
            }
            var i = reversed.items.len;
            while (i > 0) {
                i -= 1;
                try out.append(allocator, reversed.items[i]);
            }
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
};

const TestCore = struct {
    const NodeId = TestNodeId;
    const RelKind = enum { based_on };
    const Error = error{ InvalidId, NotFound, BudgetExceeded, InvalidRecord };
    const QueryBudget = struct {
        max_depth: u8 = 3,
        max_visited_nodes: usize = 32,
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

    fn addVisitedNodes(stats: *QueryStats, amount: usize) !void {
        stats.nodes_visited = try std.math.add(usize, stats.nodes_visited, amount);
    }

    fn addVisitedEdges(stats: *QueryStats, amount: usize) !void {
        stats.edges_visited = try std.math.add(usize, stats.edges_visited, amount);
    }
};

const TestPathTraversal = PathTraversal(TestCore, TestIndex);

const TestCursor = struct {
    edges: []const TestIndex.EdgeRef,

    fn forEachOutgoingRelation(self: @This(), node_id: TestNodeId, rel_filter: ?TestCore.RelKind, context: anytype, comptime callback: fn (@TypeOf(context), TestIndex.EdgeRef) anyerror!bool) !bool {
        for (self.edges) |edge| {
            if (edge.src != node_id) continue;
            if (rel_filter) |rel| if (edge.rel != rel) continue;
            if (try callback(context, edge)) return true;
        }
        return false;
    }
};

const TestLookup = struct {
    nodes: []const TestNodeId,

    fn exists(self: @This(), node_id: TestNodeId) !bool {
        return std.mem.indexOfScalar(TestNodeId, self.nodes, node_id) != null;
    }
};

fn testEdge(src: u64, dst: u64) TestIndex.EdgeRef {
    return .{ .src = .fromInt(src), .dst = .fromInt(dst), .edge_id = .none, .rel = .based_on };
}

fn testBudget() TestCore.QueryBudget {
    return .{};
}

test "path traversal returns existing zero hop" {
    const lookup = TestLookup{ .nodes = &.{.fromInt(1)} };
    var result = try TestPathTraversal.pathWithCursor(std.testing.allocator, TestCursor{ .edges = &.{} }, lookup, .fromInt(1), .fromInt(1), null, testBudget());
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), result.nodes.items.len);
    try std.testing.expectEqual(@as(u64, 1), result.nodes.items[0].toInt());
    try std.testing.expectEqual(@as(usize, 1), result.stats.results);
    try std.testing.expectEqual(@as(usize, 0), result.stats.nodes_visited);
}

test "path traversal preserves bounded breadth first path" {
    const edges = [_]TestIndex.EdgeRef{ testEdge(1, 2), testEdge(1, 3), testEdge(2, 4), testEdge(3, 4) };
    const lookup = TestLookup{ .nodes = &.{ .fromInt(1), .fromInt(2), .fromInt(3), .fromInt(4) } };
    var result = try TestPathTraversal.pathWithCursor(std.testing.allocator, TestCursor{ .edges = &edges }, lookup, .fromInt(1), .fromInt(4), null, testBudget());
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), result.nodes.items.len);
    try std.testing.expectEqual(@as(u64, 1), result.nodes.items[0].toInt());
    try std.testing.expectEqual(@as(u64, 2), result.nodes.items[1].toInt());
    try std.testing.expectEqual(@as(u64, 4), result.nodes.items[2].toInt());
    try std.testing.expectEqual(@as(usize, 3), result.stats.edges_visited);
}

test "path traversal charges exact edge budget" {
    const edges = [_]TestIndex.EdgeRef{ testEdge(1, 2), testEdge(2, 3) };
    const lookup = TestLookup{ .nodes = &.{ .fromInt(1), .fromInt(2), .fromInt(3) } };
    var budget = testBudget();
    budget.max_visited_edges = 1;
    var result = try TestPathTraversal.pathWithCursor(std.testing.allocator, TestCursor{ .edges = &edges }, lookup, .fromInt(1), .fromInt(3), null, budget);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.nodes.items.len == 0);
    try std.testing.expect(result.stats.budget_exceeded);
    try std.testing.expectEqual(@as(usize, 1), result.stats.edges_visited);
}

test "path traversal stops before allocation on exhausted node budget" {
    var bytes: [0]u8 = .{};
    var fixed = std.heap.FixedBufferAllocator.init(&bytes);
    var budget = testBudget();
    budget.max_visited_nodes = 0;
    var result = try TestPathTraversal.pathWithCursor(fixed.allocator(), TestCursor{ .edges = &.{} }, TestLookup{ .nodes = &.{ .fromInt(1), .fromInt(2) } }, .fromInt(1), .fromInt(2), null, budget);
    defer result.deinit(fixed.allocator());

    try std.testing.expect(result.stats.budget_exceeded);
    try std.testing.expectEqual(@as(usize, 0), result.nodes.items.len);
}

test "path traversal marks unseen edge beyond max depth" {
    const edges = [_]TestIndex.EdgeRef{testEdge(1, 2)};
    const lookup = TestLookup{ .nodes = &.{ .fromInt(1), .fromInt(2) } };
    var budget = testBudget();
    budget.max_depth = 0;
    var result = try TestPathTraversal.pathWithCursor(std.testing.allocator, TestCursor{ .edges = &edges }, lookup, .fromInt(1), .fromInt(2), null, budget);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.stats.budget_exceeded);
    try std.testing.expectEqual(@as(usize, 1), result.stats.edges_visited);
    try std.testing.expectEqual(@as(usize, 0), result.nodes.items.len);
}

test "path traversal applies missing target policy" {
    const edges = [_]TestIndex.EdgeRef{testEdge(1, 99)};
    const lookup = TestLookup{ .nodes = &.{ .fromInt(1), .fromInt(2) } };
    var skipped = try TestPathTraversal.pathWithCursor(std.testing.allocator, TestCursor{ .edges = &edges }, lookup, .fromInt(1), .fromInt(2), null, testBudget());
    defer skipped.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), skipped.nodes.items.len);

    try std.testing.expectError(error.InvalidRecord, TestPathTraversal.pathWithCursorDeadline(std.testing.allocator, TestCursor{ .edges = &edges }, lookup, .fromInt(1), .fromInt(2), null, testBudget(), .{ .is_expired = false }, true));
}

test "path traversal stops on expired deadline" {
    var result = try TestPathTraversal.pathWithCursorDeadline(std.testing.allocator, TestCursor{ .edges = &.{} }, TestLookup{ .nodes = &.{ .fromInt(1), .fromInt(2) } }, .fromInt(1), .fromInt(2), null, testBudget(), .{ .is_expired = true }, false);
    defer result.deinit(std.testing.allocator);

    try std.testing.expect(result.stats.budget_exceeded);
    try std.testing.expectEqual(@as(usize, 0), result.nodes.items.len);
}
