const std = @import("std");
const core = @import("../core.zig");

/// Shared bounded traversal resources for in-memory and persistent DAG walks.
/// The namespace keeps allocation policy and overflow handling behind one
/// internal port without importing Query or Storage.
pub const Support = struct {
    const dense_max_id: u64 = 4 * 1024 * 1024;
    const dense_min_id: u64 = 64 * 1024;
    const dense_budget_ratio: u64 = 64;

    pub const NodeState = union(enum) {
        dense: Dense,
        sparse: Sparse,

        const Dense = struct {
            visited: std.DynamicBitSetUnmanaged,
            discovered: std.DynamicBitSetUnmanaged,
            depths: []u8,
            visited_count: usize = 0,
        };

        const Sparse = struct {
            visited: std.AutoHashMap(u64, void),
            depths: std.AutoHashMap(u64, u8),
        };

        pub fn init(allocator: std.mem.Allocator, max_node_id: u64, budget: core.QueryBudget) !NodeState {
            if (try shouldUseDense(max_node_id, budget)) {
                const bit_count = std.math.cast(usize, max_node_id) orelse return error.RecordTooLarge;
                var visited = try std.DynamicBitSetUnmanaged.initEmpty(allocator, bit_count);
                errdefer visited.deinit(allocator);
                var discovered = try std.DynamicBitSetUnmanaged.initEmpty(allocator, bit_count);
                errdefer discovered.deinit(allocator);
                const depths = try allocator.alloc(u8, bit_count);
                @memset(depths, 0);
                return .{ .dense = .{
                    .visited = visited,
                    .discovered = discovered,
                    .depths = depths,
                } };
            }

            var visited = std.AutoHashMap(u64, void).init(allocator);
            errdefer visited.deinit();
            var depths = std.AutoHashMap(u64, u8).init(allocator);
            errdefer depths.deinit();
            const prealloc_nodes = preallocNodeCapacity(budget);
            try visited.ensureTotalCapacity(@intCast(prealloc_nodes));
            try depths.ensureTotalCapacity(@intCast(prealloc_nodes));
            return .{ .sparse = .{
                .visited = visited,
                .depths = depths,
            } };
        }

        pub fn deinit(self: *NodeState, allocator: std.mem.Allocator) void {
            switch (self.*) {
                .dense => |*dense| {
                    dense.visited.deinit(allocator);
                    dense.discovered.deinit(allocator);
                    allocator.free(dense.depths);
                },
                .sparse => |*sparse| {
                    sparse.visited.deinit();
                    sparse.depths.deinit();
                },
            }
        }

        pub fn visitedCount(self: *const NodeState) usize {
            return switch (self.*) {
                .dense => |*dense| dense.visited_count,
                .sparse => |*sparse| sparse.visited.count(),
            };
        }

        pub fn containsVisited(self: *const NodeState, id: u64) !bool {
            return switch (self.*) {
                .dense => |*dense| {
                    const index_id = denseIndex(id) orelse return false;
                    if (index_id >= dense.visited.capacity()) return false;
                    return dense.visited.isSet(index_id);
                },
                .sparse => |*sparse| sparse.visited.contains(id),
            };
        }

        pub fn markVisited(self: *NodeState, id: u64) !void {
            switch (self.*) {
                .dense => |*dense| {
                    const index_id = denseIndex(id) orelse return error.InvalidRecord;
                    if (index_id >= dense.visited.capacity()) return error.InvalidRecord;
                    if (!dense.visited.isSet(index_id)) {
                        dense.visited.set(index_id);
                        dense.visited_count = std.math.add(usize, dense.visited_count, 1) catch return core.Error.BudgetExceeded;
                    }
                },
                .sparse => |*sparse| try sparse.visited.put(id, {}),
            }
        }

        pub fn hasDepth(self: *const NodeState, id: u64) !bool {
            return switch (self.*) {
                .dense => |*dense| {
                    const index_id = denseIndex(id) orelse return false;
                    if (index_id >= dense.discovered.capacity()) return false;
                    return dense.discovered.isSet(index_id);
                },
                .sparse => |*sparse| sparse.depths.contains(id),
            };
        }

        pub fn putDepth(self: *NodeState, id: u64, depth: u8) !void {
            switch (self.*) {
                .dense => |*dense| {
                    const index_id = denseIndex(id) orelse return error.InvalidRecord;
                    if (index_id >= dense.discovered.capacity()) return error.InvalidRecord;
                    dense.discovered.set(index_id);
                    dense.depths[index_id] = depth;
                },
                .sparse => |*sparse| try sparse.depths.put(id, depth),
            }
        }

        pub fn getDepth(self: *const NodeState, id: u64) !?u8 {
            return switch (self.*) {
                .dense => |*dense| {
                    const index_id = denseIndex(id) orelse return null;
                    if (index_id >= dense.discovered.capacity() or !dense.discovered.isSet(index_id)) return null;
                    return dense.depths[index_id];
                },
                .sparse => |*sparse| sparse.depths.get(id),
            };
        }

        fn denseIndex(id: u64) ?usize {
            if (id == 0 or id == std.math.maxInt(u64)) return null;
            return std.math.cast(usize, id - 1) orelse null;
        }
    };

    pub fn isReservedNodeId(id: core.NodeId) bool {
        return id == .none or id.toInt() == std.math.maxInt(u64);
    }

    pub fn timedOutImmediately(budget: core.QueryBudget) bool {
        return budget.timeout_ms == 0;
    }

    pub fn nodeBudgetExhausted(budget: core.QueryBudget) bool {
        return budget.max_visited_nodes == 0;
    }

    pub fn preallocNodeCapacity(budget: core.QueryBudget) usize {
        const max_prealloc_nodes: usize = 16 * 1024;
        const wanted = std.math.add(usize, budget.max_visited_nodes, 1) catch max_prealloc_nodes;
        return @min(wanted, max_prealloc_nodes);
    }

    pub fn graphMaxNodeIdHint(next_node_id: u64) u64 {
        if (next_node_id == 0) return std.math.maxInt(u64);
        return next_node_id - 1;
    }

    pub fn incrementCounter(current: usize) !usize {
        return std.math.add(usize, current, 1) catch return core.Error.BudgetExceeded;
    }

    fn shouldUseDense(max_node_id: u64, budget: core.QueryBudget) !bool {
        if (max_node_id == 0 or max_node_id > dense_max_id) return false;
        if (budget.max_visited_nodes == 0) return false;
        const expected = std.math.cast(u64, budget.max_visited_nodes) orelse dense_max_id;
        const scaled = std.math.mul(u64, expected, dense_budget_ratio) catch dense_max_id;
        return max_node_id <= @max(dense_min_id, scaled);
    }
};

test "DAG traversal state uses dense storage for bounded dense ids" {
    var state = try Support.NodeState.init(std.testing.allocator, 64, .{ .max_visited_nodes = 16 });
    defer state.deinit(std.testing.allocator);
    switch (state) {
        .dense => {},
        .sparse => return error.ExpectedDenseTraversalState,
    }
    try std.testing.expectEqual(@as(usize, 0), state.visitedCount());
    try state.putDepth(3, 2);
    try std.testing.expectEqual(@as(?u8, 2), try state.getDepth(3));
    try state.markVisited(3);
    try state.markVisited(3);
    try std.testing.expect(try state.containsVisited(3));
    try std.testing.expectEqual(@as(usize, 1), state.visitedCount());
}

test "DAG traversal state falls back for sparse high ids and bounds overflow" {
    var state = try Support.NodeState.init(std.testing.allocator, Support.dense_max_id + 1, .{ .max_visited_nodes = 16 });
    defer state.deinit(std.testing.allocator);
    switch (state) {
        .dense => return error.ExpectedSparseTraversalState,
        .sparse => {},
    }
    const high_id = Support.dense_max_id + 1;
    try state.putDepth(high_id, 1);
    try state.markVisited(high_id);
    try std.testing.expect(try state.containsVisited(high_id));
    try std.testing.expectEqual(@as(?u8, 1), try state.getDepth(high_id));
    try std.testing.expectError(core.Error.BudgetExceeded, Support.incrementCounter(std.math.maxInt(usize)));
}
