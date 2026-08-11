const std = @import("std");

/// Owns context-fact ranking and bounded selection. Concrete graph/store
/// adapters, index repair, and reader lifetimes remain in the agent facade.
pub fn ContextPacketAssembly(
    comptime core: type,
    comptime index: type,
    comptime EdgeCursor: type,
    comptime NodeLookup: type,
) type {
    return struct {
        pub const ContextPacket = struct {
            focus: core.NodeId,
            max_facts: usize,
            facts: std.ArrayList(ContextFact),

            pub fn deinit(self: *ContextPacket, allocator: std.mem.Allocator) void {
                self.facts.deinit(allocator);
            }
        };

        pub const ContextFact = struct {
            node_id: core.NodeId,
            edge_id: core.EdgeId,
            rel: core.RelKind,
            direction: Direction,
            score: u16,

            pub const Direction = enum {
                outgoing,
                incoming,
            };
        };

        pub const BudgetControl = struct {
            budget: core.QueryBudget,
            stats: *index.QueryStats,
            budget_start_nodes: usize,
            budget_start_edges: usize,
            deadline: core.QueryDeadline,
        };

        pub fn assemble(
            allocator: std.mem.Allocator,
            edge_cursor: EdgeCursor,
            node_lookup: NodeLookup,
            focus: core.NodeId,
            max_facts: usize,
            budget_control: ?BudgetControl,
        ) !ContextPacket {
            if (budget_control) |control| {
                if (control.deadline.expired()) return core.Error.BudgetExceeded;
            }

            var facts = std.ArrayList(ContextFact).empty;
            errdefer facts.deinit(allocator);
            if (max_facts == 0) return .{
                .focus = focus,
                .max_facts = max_facts,
                .facts = facts,
            };

            var outgoing_context = CollectContext{
                .allocator = allocator,
                .facts = &facts,
                .max_facts = max_facts,
                .direction = .outgoing,
                .node_lookup = node_lookup,
                .budget_control = budget_control,
            };
            _ = try edge_cursor.forEachOutgoing(focus, &outgoing_context, collectFact);

            var incoming_context = CollectContext{
                .allocator = allocator,
                .facts = &facts,
                .max_facts = max_facts,
                .direction = .incoming,
                .node_lookup = node_lookup,
                .budget_control = budget_control,
            };
            _ = try edge_cursor.forEachIncoming(focus, &incoming_context, collectFact);

            std.mem.sort(ContextFact, facts.items, {}, factLessThan);
            return .{
                .focus = focus,
                .max_facts = max_facts,
                .facts = facts,
            };
        }

        const CollectContext = struct {
            allocator: std.mem.Allocator,
            facts: *std.ArrayList(ContextFact),
            max_facts: usize,
            direction: ContextFact.Direction,
            node_lookup: NodeLookup,
            budget_control: ?BudgetControl,
        };

        fn collectFact(ctx: *CollectContext, edge: index.EdgeRef) !bool {
            try chargeEdge(ctx);
            switch (ctx.direction) {
                .outgoing => {
                    try chargeNode(ctx);
                    if (!try ctx.node_lookup.exists(edge.dst)) return false;
                    try countNode(ctx);
                    try appendFactBounded(ctx.allocator, ctx.facts, ctx.max_facts, .{
                        .node_id = edge.dst,
                        .edge_id = edge.edge_id,
                        .rel = edge.rel,
                        .direction = .outgoing,
                        .score = relationScore(edge.rel) + 20,
                    });
                },
                .incoming => {
                    if (edge.src.toInt() == edge.dst.toInt()) return false;
                    try chargeNode(ctx);
                    if (!try ctx.node_lookup.exists(edge.src)) return false;
                    try countNode(ctx);
                    try appendFactBounded(ctx.allocator, ctx.facts, ctx.max_facts, .{
                        .node_id = edge.src,
                        .edge_id = edge.edge_id,
                        .rel = edge.rel,
                        .direction = .incoming,
                        .score = relationScore(edge.rel),
                    });
                },
            }
            return false;
        }

        fn chargeEdge(ctx: *CollectContext) !void {
            const control = ctx.budget_control orelse return;
            if (control.deadline.expired()) return core.Error.BudgetExceeded;
            if (control.stats.edges_visited - control.budget_start_edges >= control.budget.max_visited_edges) {
                return core.Error.BudgetExceeded;
            }
            try index.addVisitedEdges(control.stats, 1);
        }

        fn chargeNode(ctx: *CollectContext) !void {
            const control = ctx.budget_control orelse return;
            if (control.stats.nodes_visited - control.budget_start_nodes >= control.budget.max_visited_nodes) {
                return core.Error.BudgetExceeded;
            }
        }

        fn countNode(ctx: *CollectContext) !void {
            const control = ctx.budget_control orelse return;
            try index.addVisitedNodes(control.stats, 1);
        }

        fn relationScore(rel: core.RelKind) u16 {
            return switch (rel) {
                .defines, .depends_on, .blocks, .evidences, .verified_by => 80,
                .contains, .calls, .imports, .derived_from, .summarizes => 60,
                .mentions, .references, .explains, .based_on => 40,
                else => 20,
            };
        }

        fn factLessThan(_: void, lhs: ContextFact, rhs: ContextFact) bool {
            if (lhs.score != rhs.score) return lhs.score > rhs.score;
            if (@intFromEnum(lhs.rel) != @intFromEnum(rhs.rel)) return @intFromEnum(lhs.rel) < @intFromEnum(rhs.rel);
            if (lhs.node_id.toInt() != rhs.node_id.toInt()) return lhs.node_id.toInt() < rhs.node_id.toInt();
            return lhs.edge_id.toInt() < rhs.edge_id.toInt();
        }

        fn appendFactBounded(
            allocator: std.mem.Allocator,
            facts: *std.ArrayList(ContextFact),
            max_facts: usize,
            fact: ContextFact,
        ) !void {
            if (max_facts == 0) return;
            if (facts.items.len < max_facts) {
                if (facts.items.len == facts.capacity) {
                    const doubled = std.math.mul(usize, facts.capacity, 2) catch max_facts;
                    const next_capacity = @min(max_facts, @max(@as(usize, 1), doubled));
                    try facts.ensureTotalCapacityPrecise(allocator, next_capacity);
                }
                facts.appendAssumeCapacity(fact);
                return;
            }

            var worst_index: usize = 0;
            for (facts.items[1..], 1..) |candidate, i| {
                if (factLessThan({}, facts.items[worst_index], candidate)) {
                    worst_index = i;
                }
            }
            if (factLessThan({}, fact, facts.items[worst_index])) {
                facts.items[worst_index] = fact;
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
    const RelKind = enum {
        defines,
        depends_on,
        blocks,
        evidences,
        verified_by,
        contains,
        calls,
        imports,
        derived_from,
        summarizes,
        mentions,
        references,
        explains,
        based_on,
        related_to,
    };
    const Error = error{ BudgetExceeded, Unsupported };
    const QueryBudget = struct {
        max_visited_nodes: usize = 64,
        max_visited_edges: usize = 64,
    };
    const QueryDeadline = struct {
        expired_now: bool = false,

        fn expired(self: @This()) bool {
            return self.expired_now;
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
    };

    fn addVisitedEdges(stats: *QueryStats, amount: usize) !void {
        stats.edges_visited = try std.math.add(usize, stats.edges_visited, amount);
    }

    fn addVisitedNodes(stats: *QueryStats, amount: usize) !void {
        stats.nodes_visited = try std.math.add(usize, stats.nodes_visited, amount);
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

    fn forEachOutgoing(
        self: @This(),
        focus: TestNodeId,
        context: anytype,
        comptime callback: fn (@TypeOf(context), TestIndex.EdgeRef) anyerror!bool,
    ) !bool {
        for (self.edges) |edge| {
            if (edge.src != focus) continue;
            self.scanned.* += 1;
            if (try callback(context, edge)) return true;
        }
        return false;
    }

    fn forEachIncoming(
        self: @This(),
        focus: TestNodeId,
        context: anytype,
        comptime callback: fn (@TypeOf(context), TestIndex.EdgeRef) anyerror!bool,
    ) !bool {
        for (self.edges) |edge| {
            if (edge.dst != focus) continue;
            self.scanned.* += 1;
            if (try callback(context, edge)) return true;
        }
        return false;
    }
};

const TestAssembly = ContextPacketAssembly(TestCore, TestIndex, TestEdgeCursor, TestNodeLookup);

fn testEdge(id: u64, src: u64, dst: u64, rel: TestCore.RelKind) TestIndex.EdgeRef {
    return .{
        .src = .fromInt(src),
        .dst = .fromInt(dst),
        .edge_id = .fromInt(id),
        .rel = rel,
    };
}

fn testControl(stats: *TestIndex.QueryStats, budget: TestCore.QueryBudget, expired: bool) TestAssembly.BudgetControl {
    return .{
        .budget = budget,
        .stats = stats,
        .budget_start_nodes = stats.nodes_visited,
        .budget_start_edges = stats.edges_visited,
        .deadline = .{ .expired_now = expired },
    };
}

test "context packet assembly ranks directions and relations deterministically" {
    const edges = [_]TestIndex.EdgeRef{
        testEdge(3, 1, 4, .mentions),
        testEdge(2, 3, 1, .defines),
        testEdge(1, 1, 2, .defines),
    };
    var scanned: usize = 0;
    var packet = try TestAssembly.assemble(
        std.testing.allocator,
        .{ .edges = &edges, .scanned = &scanned },
        .{ .nodes = &.{ .fromInt(1), .fromInt(2), .fromInt(3), .fromInt(4) } },
        .fromInt(1),
        3,
        null,
    );
    defer packet.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), packet.facts.items.len);
    try std.testing.expectEqual(@as(u16, 100), packet.facts.items[0].score);
    try std.testing.expectEqual(TestAssembly.ContextFact.Direction.outgoing, packet.facts.items[0].direction);
    try std.testing.expectEqual(@as(u16, 80), packet.facts.items[1].score);
    try std.testing.expectEqual(TestAssembly.ContextFact.Direction.incoming, packet.facts.items[1].direction);
}

test "context packet assembly keeps only the highest ranked facts" {
    const edges = [_]TestIndex.EdgeRef{
        testEdge(1, 1, 2, .related_to),
        testEdge(2, 3, 1, .defines),
    };
    var scanned: usize = 0;
    var packet = try TestAssembly.assemble(
        std.testing.allocator,
        .{ .edges = &edges, .scanned = &scanned },
        .{ .nodes = &.{ .fromInt(1), .fromInt(2), .fromInt(3) } },
        .fromInt(1),
        1,
        null,
    );
    defer packet.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), packet.facts.items.len);
    try std.testing.expectEqual(@as(u64, 3), packet.facts.items[0].node_id.toInt());
    try std.testing.expectEqual(TestCore.RelKind.defines, packet.facts.items[0].rel);
}

test "context packet assembly skips missing edge endpoints" {
    const edges = [_]TestIndex.EdgeRef{
        testEdge(1, 1, 2, .mentions),
        testEdge(2, 3, 1, .defines),
    };
    var scanned: usize = 0;
    var packet = try TestAssembly.assemble(
        std.testing.allocator,
        .{ .edges = &edges, .scanned = &scanned },
        .{ .nodes = &.{.fromInt(1)} },
        .fromInt(1),
        4,
        null,
    );
    defer packet.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), packet.facts.items.len);
    try std.testing.expectEqual(@as(usize, 2), scanned);
}

test "context packet assembly reports a self loop once" {
    const edges = [_]TestIndex.EdgeRef{testEdge(1, 1, 1, .related_to)};
    var scanned: usize = 0;
    var packet = try TestAssembly.assemble(
        std.testing.allocator,
        .{ .edges = &edges, .scanned = &scanned },
        .{ .nodes = &.{.fromInt(1)} },
        .fromInt(1),
        4,
        null,
    );
    defer packet.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), packet.facts.items.len);
    try std.testing.expectEqual(TestAssembly.ContextFact.Direction.outgoing, packet.facts.items[0].direction);
    try std.testing.expectEqual(@as(usize, 2), scanned);
}

test "context packet assembly charges exact edge and node budgets" {
    const edges = [_]TestIndex.EdgeRef{
        testEdge(1, 1, 2, .mentions),
        testEdge(2, 1, 3, .mentions),
    };
    var scanned: usize = 0;
    var edge_stats = TestIndex.QueryStats{};
    try std.testing.expectError(
        error.BudgetExceeded,
        TestAssembly.assemble(
            std.testing.allocator,
            .{ .edges = &edges, .scanned = &scanned },
            .{ .nodes = &.{ .fromInt(1), .fromInt(2), .fromInt(3) } },
            .fromInt(1),
            4,
            testControl(&edge_stats, .{ .max_visited_edges = 1 }, false),
        ),
    );
    try std.testing.expectEqual(@as(usize, 1), edge_stats.edges_visited);
    try std.testing.expectEqual(@as(usize, 1), edge_stats.nodes_visited);

    scanned = 0;
    var node_stats = TestIndex.QueryStats{};
    try std.testing.expectError(
        error.BudgetExceeded,
        TestAssembly.assemble(
            std.testing.allocator,
            .{ .edges = &edges, .scanned = &scanned },
            .{ .nodes = &.{ .fromInt(1), .fromInt(2), .fromInt(3) } },
            .fromInt(1),
            4,
            testControl(&node_stats, .{ .max_visited_nodes = 0 }, false),
        ),
    );
    try std.testing.expectEqual(@as(usize, 1), node_stats.edges_visited);
    try std.testing.expectEqual(@as(usize, 0), node_stats.nodes_visited);
}

test "context packet assembly enforces deadline before traversal" {
    const edges = [_]TestIndex.EdgeRef{testEdge(1, 1, 2, .mentions)};
    var scanned: usize = 0;
    var stats = TestIndex.QueryStats{};
    try std.testing.expectError(
        error.BudgetExceeded,
        TestAssembly.assemble(
            std.testing.allocator,
            .{ .edges = &edges, .scanned = &scanned },
            .{ .nodes = &.{ .fromInt(1), .fromInt(2) } },
            .fromInt(1),
            4,
            testControl(&stats, .{}, true),
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), scanned);
    try std.testing.expectEqual(@as(usize, 0), stats.edges_visited);
}

test "context packet assembly bounds allocation by the requested fact limit" {
    const edges = [_]TestIndex.EdgeRef{
        testEdge(1, 1, 2, .mentions),
        testEdge(2, 1, 3, .mentions),
        testEdge(3, 1, 4, .mentions),
    };
    var scanned: usize = 0;
    var packet = try TestAssembly.assemble(
        std.testing.allocator,
        .{ .edges = &edges, .scanned = &scanned },
        .{ .nodes = &.{ .fromInt(1), .fromInt(2), .fromInt(3), .fromInt(4) } },
        .fromInt(1),
        1,
        null,
    );
    defer packet.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), packet.facts.items.len);
    try std.testing.expectEqual(@as(usize, 1), packet.facts.capacity);
}
