const std = @import("std");

/// Owned TinyQL execution-result values shared by the executor, segment
/// executor, and presentation layers. Query cursors, predicates, expansion,
/// ordering, and budget control deliberately remain in executor.zig.
pub fn ExecutionResult(
    comptime core: type,
    comptime QueryStats: type,
    comptime PhysicalPlan: type,
) type {
    return struct {
        pub const Binding = struct {
            name: []u8,
            node_id: core.NodeId,
        };

        pub const EdgeBinding = struct {
            name: []u8,
            edge_id: core.EdgeId,
        };

        pub const PathBinding = struct {
            from_var: []u8,
            to_var: []u8,
            nodes: []core.NodeId,
        };

        pub const ScoreBinding = struct {
            var_name: []u8,
            score: f32,
        };

        pub const Row = struct {
            bindings: std.ArrayList(Binding),
            edge_bindings: std.ArrayList(EdgeBinding),
            paths: std.ArrayList(PathBinding),
            scores: std.ArrayList(ScoreBinding),

            pub fn init() Row {
                return .{ .bindings = .empty, .edge_bindings = .empty, .paths = .empty, .scores = .empty };
            }

            pub fn initBinding(allocator: std.mem.Allocator, name: []const u8, node_id: core.NodeId) !Row {
                var row = Row.init();
                errdefer row.deinit(allocator);
                try row.bindings.ensureTotalCapacity(allocator, 1);
                try row.appendBindingAssumeCapacity(allocator, name, node_id);
                return row;
            }

            pub fn initBindingScore(allocator: std.mem.Allocator, name: []const u8, node_id: core.NodeId, score: f32) !Row {
                var row = try Row.initBinding(allocator, name, node_id);
                errdefer row.deinit(allocator);
                try row.scores.ensureTotalCapacity(allocator, 1);
                try row.appendScoreAssumeCapacity(allocator, name, score);
                return row;
            }

            pub fn deinit(self: *Row, allocator: std.mem.Allocator) void {
                for (self.scores.items) |score| allocator.free(score.var_name);
                self.scores.deinit(allocator);
                for (self.paths.items) |path| {
                    allocator.free(path.from_var);
                    allocator.free(path.to_var);
                    allocator.free(path.nodes);
                }
                self.paths.deinit(allocator);
                for (self.edge_bindings.items) |binding| allocator.free(binding.name);
                self.edge_bindings.deinit(allocator);
                for (self.bindings.items) |binding| allocator.free(binding.name);
                self.bindings.deinit(allocator);
            }

            pub fn get(self: Row, name: []const u8) ?core.NodeId {
                for (self.bindings.items) |binding| {
                    if (std.mem.eql(u8, binding.name, name)) return binding.node_id;
                }
                return null;
            }

            pub fn getEdge(self: Row, name: []const u8) ?core.EdgeId {
                for (self.edge_bindings.items) |binding| {
                    if (std.mem.eql(u8, binding.name, name)) return binding.edge_id;
                }
                return null;
            }

            fn getAt(self: Row, index_pos: ?usize, name: []const u8) ?core.NodeId {
                if (index_pos) |pos| {
                    if (pos < self.bindings.items.len and std.mem.eql(u8, self.bindings.items[pos].name, name)) {
                        return self.bindings.items[pos].node_id;
                    }
                }
                return self.get(name);
            }

            pub fn put(self: *Row, allocator: std.mem.Allocator, name: []const u8, node_id: core.NodeId) !bool {
                for (self.bindings.items) |*binding| {
                    if (std.mem.eql(u8, binding.name, name)) {
                        return binding.node_id.toInt() == node_id.toInt();
                    }
                }
                const owned_name = try allocator.dupe(u8, name);
                errdefer allocator.free(owned_name);
                try self.bindings.append(allocator, .{ .name = owned_name, .node_id = node_id });
                return true;
            }

            pub fn putEdge(self: *Row, allocator: std.mem.Allocator, name: []const u8, edge_id: core.EdgeId) !bool {
                for (self.edge_bindings.items) |*binding| {
                    if (std.mem.eql(u8, binding.name, name)) {
                        return binding.edge_id.toInt() == edge_id.toInt();
                    }
                }
                const owned_name = try allocator.dupe(u8, name);
                errdefer allocator.free(owned_name);
                try self.edge_bindings.append(allocator, .{ .name = owned_name, .edge_id = edge_id });
                return true;
            }

            pub fn putPath(self: *Row, allocator: std.mem.Allocator, from_var: []const u8, to_var: []const u8, nodes: []const core.NodeId) !void {
                for (self.paths.items) |*path| {
                    if (std.mem.eql(u8, path.from_var, from_var) and std.mem.eql(u8, path.to_var, to_var)) {
                        const owned_nodes = try allocator.dupe(core.NodeId, nodes);
                        errdefer allocator.free(owned_nodes);
                        allocator.free(path.nodes);
                        path.nodes = owned_nodes;
                        return;
                    }
                }
                const owned_from_var = try allocator.dupe(u8, from_var);
                errdefer allocator.free(owned_from_var);
                const owned_to_var = try allocator.dupe(u8, to_var);
                errdefer allocator.free(owned_to_var);
                const owned_nodes = try allocator.dupe(core.NodeId, nodes);
                errdefer allocator.free(owned_nodes);
                try self.paths.append(allocator, .{
                    .from_var = owned_from_var,
                    .to_var = owned_to_var,
                    .nodes = owned_nodes,
                });
            }

            pub fn getPath(self: Row, from_var: []const u8, to_var: []const u8) ?[]const core.NodeId {
                for (self.paths.items) |path| {
                    if (std.mem.eql(u8, path.from_var, from_var) and std.mem.eql(u8, path.to_var, to_var)) {
                        return path.nodes;
                    }
                }
                return null;
            }

            pub fn putScore(self: *Row, allocator: std.mem.Allocator, var_name: []const u8, score: f32) !void {
                for (self.scores.items) |*binding| {
                    if (std.mem.eql(u8, binding.var_name, var_name)) {
                        binding.score = score;
                        return;
                    }
                }
                const owned_var_name = try allocator.dupe(u8, var_name);
                errdefer allocator.free(owned_var_name);
                try self.scores.append(allocator, .{ .var_name = owned_var_name, .score = score });
            }

            pub fn getScore(self: Row, var_name: []const u8) ?f32 {
                for (self.scores.items) |binding| {
                    if (std.mem.eql(u8, binding.var_name, var_name)) return binding.score;
                }
                return null;
            }

            fn appendBindingAssumeCapacity(self: *Row, allocator: std.mem.Allocator, name: []const u8, node_id: core.NodeId) !void {
                const owned_name = try allocator.dupe(u8, name);
                errdefer allocator.free(owned_name);
                self.bindings.appendAssumeCapacity(.{ .name = owned_name, .node_id = node_id });
            }

            fn appendClonedBindingAssumeCapacity(self: *Row, allocator: std.mem.Allocator, binding: Binding) !void {
                try self.appendBindingAssumeCapacity(allocator, binding.name, binding.node_id);
            }

            fn appendEdgeBindingAssumeCapacity(self: *Row, allocator: std.mem.Allocator, name: []const u8, edge_id: core.EdgeId) !void {
                const owned_name = try allocator.dupe(u8, name);
                errdefer allocator.free(owned_name);
                self.edge_bindings.appendAssumeCapacity(.{ .name = owned_name, .edge_id = edge_id });
            }

            fn appendClonedEdgeBindingAssumeCapacity(self: *Row, allocator: std.mem.Allocator, binding: EdgeBinding) !void {
                try self.appendEdgeBindingAssumeCapacity(allocator, binding.name, binding.edge_id);
            }

            fn appendClonedPathAssumeCapacity(self: *Row, allocator: std.mem.Allocator, path: PathBinding) !void {
                const owned_from_var = try allocator.dupe(u8, path.from_var);
                errdefer allocator.free(owned_from_var);
                const owned_to_var = try allocator.dupe(u8, path.to_var);
                errdefer allocator.free(owned_to_var);
                const owned_nodes = try allocator.dupe(core.NodeId, path.nodes);
                errdefer allocator.free(owned_nodes);
                self.paths.appendAssumeCapacity(.{
                    .from_var = owned_from_var,
                    .to_var = owned_to_var,
                    .nodes = owned_nodes,
                });
            }

            fn appendScoreAssumeCapacity(self: *Row, allocator: std.mem.Allocator, var_name: []const u8, score: f32) !void {
                const owned_var_name = try allocator.dupe(u8, var_name);
                errdefer allocator.free(owned_var_name);
                self.scores.appendAssumeCapacity(.{ .var_name = owned_var_name, .score = score });
            }

            fn appendClonedScoreAssumeCapacity(self: *Row, allocator: std.mem.Allocator, score: ScoreBinding) !void {
                try self.appendScoreAssumeCapacity(allocator, score.var_name, score.score);
            }

            pub fn clone(self: Row, allocator: std.mem.Allocator) !Row {
                return (try self.cloneWithOptionalBinding(allocator, null)).?;
            }

            pub fn cloneWithBinding(self: Row, allocator: std.mem.Allocator, name: []const u8, node_id: core.NodeId) !?Row {
                return try self.cloneWithOptionalBinding(allocator, .{ .name = name, .node_id = node_id });
            }

            fn cloneAppendingBinding(self: Row, allocator: std.mem.Allocator, name: []const u8, node_id: core.NodeId, keep_scores: bool) !Row {
                var out = Row.init();
                errdefer out.deinit(allocator);
                try out.bindings.ensureTotalCapacity(allocator, self.bindings.items.len + 1);
                for (self.bindings.items) |binding| {
                    try out.appendClonedBindingAssumeCapacity(allocator, binding);
                }
                try out.appendBindingAssumeCapacity(allocator, name, node_id);
                try out.edge_bindings.ensureTotalCapacity(allocator, self.edge_bindings.items.len);
                for (self.edge_bindings.items) |binding| {
                    try out.appendClonedEdgeBindingAssumeCapacity(allocator, binding);
                }
                try out.paths.ensureTotalCapacity(allocator, self.paths.items.len);
                for (self.paths.items) |path| {
                    try out.appendClonedPathAssumeCapacity(allocator, path);
                }
                if (keep_scores) {
                    try out.scores.ensureTotalCapacity(allocator, self.scores.items.len);
                    for (self.scores.items) |score| {
                        try out.appendClonedScoreAssumeCapacity(allocator, score);
                    }
                }
                return out;
            }

            const ExtraBinding = struct {
                name: []const u8,
                node_id: core.NodeId,
            };

            fn cloneWithOptionalBinding(self: Row, allocator: std.mem.Allocator, extra: ?ExtraBinding) !?Row {
                return try self.cloneWithOptionalBindingAndScores(allocator, extra, true);
            }

            fn cloneWithOptionalBindingAndScores(self: Row, allocator: std.mem.Allocator, extra: ?ExtraBinding, keep_scores: bool) !?Row {
                var append_extra = false;
                if (extra) |binding| {
                    append_extra = true;
                    for (self.bindings.items) |existing| {
                        if (std.mem.eql(u8, existing.name, binding.name)) {
                            if (existing.node_id.toInt() != binding.node_id.toInt()) return null;
                            append_extra = false;
                            break;
                        }
                    }
                }

                var out = Row.init();
                errdefer out.deinit(allocator);
                try out.bindings.ensureTotalCapacity(allocator, self.bindings.items.len + @intFromBool(append_extra));
                for (self.bindings.items) |binding| {
                    try out.appendClonedBindingAssumeCapacity(allocator, binding);
                }
                if (append_extra) {
                    const binding = extra.?;
                    try out.appendBindingAssumeCapacity(allocator, binding.name, binding.node_id);
                }
                try out.edge_bindings.ensureTotalCapacity(allocator, self.edge_bindings.items.len);
                for (self.edge_bindings.items) |binding| {
                    try out.appendClonedEdgeBindingAssumeCapacity(allocator, binding);
                }
                try out.paths.ensureTotalCapacity(allocator, self.paths.items.len);
                for (self.paths.items) |path| {
                    try out.appendClonedPathAssumeCapacity(allocator, path);
                }
                if (keep_scores) {
                    try out.scores.ensureTotalCapacity(allocator, self.scores.items.len);
                    for (self.scores.items) |score| {
                        try out.appendClonedScoreAssumeCapacity(allocator, score);
                    }
                }
                return out;
            }
        };

        pub const ResultTable = struct {
            rows: std.ArrayList(Row),
            stats: QueryStats = .{},
            /// Persistent task leases are evaluated against one wall-clock snapshot
            /// for the whole query, including CLI projection after execution.
            read_timestamp_ns: ?u64 = null,

            pub fn init() ResultTable {
                return .{ .rows = .empty };
            }

            pub fn deinit(self: *ResultTable, allocator: std.mem.Allocator) void {
                for (self.rows.items) |*row| row.deinit(allocator);
                self.rows.deinit(allocator);
            }
        };

        pub const OperatorTiming = struct {
            op_index: usize,
            op_name: []const u8,
            elapsed_ns: u128,
            input_rows: usize,
            output_rows: usize,
            nodes_visited_delta: usize,
            edges_visited_delta: usize,
            budget_exceeded: bool,
        };

        pub const OperatorTimingRecorder = struct {
            allocator: std.mem.Allocator,
            io: std.Io,
            entries: std.ArrayList(OperatorTiming) = .empty,

            pub fn init(allocator: std.mem.Allocator, io: std.Io) OperatorTimingRecorder {
                return .{ .allocator = allocator, .io = io };
            }

            pub fn deinit(self: *OperatorTimingRecorder) void {
                self.entries.deinit(self.allocator);
            }

            pub fn clearRetainingCapacity(self: *OperatorTimingRecorder) void {
                self.entries.clearRetainingCapacity();
            }

            pub fn ensureCapacityForPlan(self: *OperatorTimingRecorder, plan: PhysicalPlan) !void {
                try self.entries.ensureUnusedCapacity(self.allocator, plan.ops.items.len);
            }

            pub fn nowNs(self: OperatorTimingRecorder) u128 {
                const timestamp = std.Io.Clock.awake.now(self.io).nanoseconds;
                return if (timestamp < 0) 0 else @intCast(timestamp);
            }

            pub fn recordAssumeCapacity(self: *OperatorTimingRecorder, timing: OperatorTiming) void {
                self.entries.appendAssumeCapacity(timing);
            }
        };

        /// Private façade protocol for executor hot paths whose operations are
        /// intentionally not part of the public TinyQL result surface.
        pub const Internal = struct {
            pub fn rowGetAt(row: Row, index_pos: ?usize, name: []const u8) ?core.NodeId {
                return row.getAt(index_pos, name);
            }

            pub fn rowCloneAppendingBinding(
                row: Row,
                allocator: std.mem.Allocator,
                name: []const u8,
                node_id: core.NodeId,
                keep_scores: bool,
            ) !Row {
                return row.cloneAppendingBinding(allocator, name, node_id, keep_scores);
            }

            pub fn rowCloneWithBindingAndScores(
                row: Row,
                allocator: std.mem.Allocator,
                name: []const u8,
                node_id: core.NodeId,
                keep_scores: bool,
            ) !?Row {
                return row.cloneWithOptionalBindingAndScores(
                    allocator,
                    .{ .name = name, .node_id = node_id },
                    keep_scores,
                );
            }
        };
    };
}

const TestId = struct {
    value: u64,

    pub fn fromInt(value: u64) TestId {
        return .{ .value = value };
    }

    pub fn toInt(self: TestId) u64 {
        return self.value;
    }
};

const TestCore = struct {
    pub const NodeId = TestId;
    pub const EdgeId = TestId;
};

const TestQueryStats = struct {
    nodes_visited: usize = 0,
    edges_visited: usize = 0,
    budget_exceeded: bool = false,
};

const TestPhysicalPlan = struct {
    ops: std.ArrayList(u8) = .empty,

    fn deinit(self: *TestPhysicalPlan) void {
        self.ops.deinit(std.testing.allocator);
    }
};

const test_result = ExecutionResult(TestCore, TestQueryStats, TestPhysicalPlan);

test "execution result row owns node edge path and score bindings" {
    var row = test_result.Row.init();
    defer row.deinit(std.testing.allocator);

    var node_name = [_]u8{'n'};
    var edge_name = [_]u8{'e'};
    var path_from = [_]u8{'a'};
    var path_to = [_]u8{'b'};
    var score_name = [_]u8{'s'};

    try std.testing.expect(try row.put(std.testing.allocator, &node_name, .fromInt(7)));
    try std.testing.expect(try row.putEdge(std.testing.allocator, &edge_name, .fromInt(11)));
    try row.putPath(std.testing.allocator, &path_from, &path_to, &.{ .fromInt(7), .fromInt(9) });
    try row.putScore(std.testing.allocator, &score_name, 2.5);

    node_name[0] = 'x';
    edge_name[0] = 'x';
    path_from[0] = 'x';
    path_to[0] = 'x';
    score_name[0] = 'x';

    try std.testing.expectEqual(@as(u64, 7), row.get("n").?.toInt());
    try std.testing.expectEqual(@as(u64, 11), row.getEdge("e").?.toInt());
    try std.testing.expectEqual(@as(u64, 9), row.getPath("a", "b").?[1].toInt());
    try std.testing.expectEqual(@as(f32, 2.5), row.getScore("s").?);
}

test "execution result row replaces path and score values without aliasing" {
    var row = test_result.Row.init();
    defer row.deinit(std.testing.allocator);

    var initial = [_]TestId{ .fromInt(1), .fromInt(2) };
    try row.putPath(std.testing.allocator, "a", "b", &initial);
    initial[1] = .fromInt(99);
    try std.testing.expectEqual(@as(u64, 2), row.getPath("a", "b").?[1].toInt());

    var replacement = [_]TestId{ .fromInt(1), .fromInt(3) };
    try row.putPath(std.testing.allocator, "a", "b", &replacement);
    replacement[1] = .fromInt(88);
    try std.testing.expectEqual(@as(u64, 3), row.getPath("a", "b").?[1].toInt());

    try row.putScore(std.testing.allocator, "a", 1.0);
    try row.putScore(std.testing.allocator, "a", 4.0);
    try std.testing.expectEqual(@as(f32, 4.0), row.getScore("a").?);
}

test "execution result row clone preserves independent ownership" {
    var row = test_result.Row.init();
    defer row.deinit(std.testing.allocator);
    try std.testing.expect(try row.put(std.testing.allocator, "a", .fromInt(1)));
    try row.putPath(std.testing.allocator, "a", "b", &.{ .fromInt(1), .fromInt(2) });
    try row.putScore(std.testing.allocator, "a", 1.25);

    var cloned = try row.clone(std.testing.allocator);
    defer cloned.deinit(std.testing.allocator);

    try std.testing.expect(try row.put(std.testing.allocator, "c", .fromInt(3)));
    try row.putPath(std.testing.allocator, "a", "b", &.{ .fromInt(1), .fromInt(3) });
    try row.putScore(std.testing.allocator, "a", 9.0);

    try std.testing.expect(cloned.get("c") == null);
    try std.testing.expectEqual(@as(f32, 1.25), cloned.getScore("a").?);
    try std.testing.expectEqual(@as(u64, 2), cloned.getPath("a", "b").?[1].toInt());
}

test "execution result row clone preserves binding conflict semantics" {
    var row = try test_result.Row.initBinding(std.testing.allocator, "a", .fromInt(1));
    defer row.deinit(std.testing.allocator);

    var appended = (try row.cloneWithBinding(std.testing.allocator, "b", .fromInt(2))).?;
    defer appended.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 2), appended.get("b").?.toInt());

    var matching = (try row.cloneWithBinding(std.testing.allocator, "a", .fromInt(1))).?;
    defer matching.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), matching.bindings.items.len);

    try std.testing.expect((try row.cloneWithBinding(std.testing.allocator, "a", .fromInt(9))) == null);
}

test "execution result row internal append can intentionally drop scores" {
    var row = try test_result.Row.initBindingScore(std.testing.allocator, "hit", .fromInt(1), 2.5);
    defer row.deinit(std.testing.allocator);

    var kept = try test_result.Internal.rowCloneAppendingBinding(
        row,
        std.testing.allocator,
        "next",
        .fromInt(2),
        true,
    );
    defer kept.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(f32, 2.5), kept.getScore("hit").?);

    var dropped = try test_result.Internal.rowCloneWithBindingAndScores(
        row,
        std.testing.allocator,
        "next",
        .fromInt(2),
        false,
    ) orelse return error.TestUnexpectedResult;
    defer dropped.deinit(std.testing.allocator);
    try std.testing.expect(dropped.getScore("hit") == null);
}

test "execution result table owns rows stats and read timestamp" {
    var table = test_result.ResultTable.init();
    defer table.deinit(std.testing.allocator);
    table.stats.nodes_visited = 3;
    table.stats.edges_visited = 5;
    table.read_timestamp_ns = 42;

    var row = try test_result.Row.initBinding(std.testing.allocator, "n", .fromInt(7));
    var row_owned = true;
    errdefer if (row_owned) row.deinit(std.testing.allocator);
    try table.rows.append(std.testing.allocator, row);
    row_owned = false;

    try std.testing.expectEqual(@as(usize, 1), table.rows.items.len);
    try std.testing.expectEqual(@as(u64, 7), table.rows.items[0].get("n").?.toInt());
    try std.testing.expectEqual(@as(usize, 3), table.stats.nodes_visited);
    try std.testing.expectEqual(@as(usize, 5), table.stats.edges_visited);
    try std.testing.expectEqual(@as(?u64, 42), table.read_timestamp_ns);
}

test "execution result timing recorder reserves records and clears without leaking" {
    var recorder = test_result.OperatorTimingRecorder.init(std.testing.allocator, std.testing.io);
    defer recorder.deinit();

    var plan = TestPhysicalPlan{};
    defer plan.deinit();
    try plan.ops.append(std.testing.allocator, 1);
    try plan.ops.append(std.testing.allocator, 2);
    try recorder.ensureCapacityForPlan(plan);
    try std.testing.expect(recorder.entries.capacity >= 2);

    recorder.recordAssumeCapacity(.{
        .op_index = 0,
        .op_name = "scan",
        .elapsed_ns = 10,
        .input_rows = 0,
        .output_rows = 1,
        .nodes_visited_delta = 1,
        .edges_visited_delta = 0,
        .budget_exceeded = false,
    });
    try std.testing.expectEqual(@as(usize, 1), recorder.entries.items.len);
    _ = recorder.nowNs();

    const capacity = recorder.entries.capacity;
    recorder.clearRetainingCapacity();
    try std.testing.expectEqual(@as(usize, 0), recorder.entries.items.len);
    try std.testing.expectEqual(capacity, recorder.entries.capacity);
}
