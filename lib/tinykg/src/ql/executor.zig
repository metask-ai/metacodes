const std = @import("std");
const core = @import("../core.zig");
const graph_mod = @import("../graph.zig");
const index = @import("../index.zig");
const query_mod = @import("../query.zig");
const schema = @import("../schema.zig");
const storage = @import("../storage.zig");
const text_mod = @import("../text.zig");
const ast = @import("ast.zig");
const optimizer = @import("optimizer.zig");
const planner = @import("planner.zig");

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
    stats: index.QueryStats = .{},

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

    pub fn ensureCapacityForPlan(self: *OperatorTimingRecorder, plan: optimizer.PhysicalPlan) !void {
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

const NodeView = struct {
    id: core.NodeId,
    kind: core.NodeKind,
    text: []const u8,
    owned_text: ?[]u8 = null,

    fn fromGraphNode(node: graph_mod.Node) NodeView {
        return .{
            .id = node.id,
            .kind = node.kind,
            .text = node.text,
        };
    }

    fn fromStoredNode(node: storage.StoredNode) NodeView {
        return .{
            .id = node.id,
            .kind = node.kind,
            .text = node.text,
            .owned_text = node.text,
        };
    }

    fn deinit(self: *NodeView, allocator: std.mem.Allocator) void {
        if (self.owned_text) |text_value| allocator.free(text_value);
    }
};

fn typeFilterIsAny(filter: schema.NodeTypeFilter) bool {
    return switch (filter) {
        .any => true,
        else => false,
    };
}

fn effectiveNodeTypeFilter(kind: ?core.NodeKind, filter: schema.NodeTypeFilter) schema.NodeTypeFilter {
    if (typeFilterIsAny(filter)) return schema.NodeTypeFilter.fromOptionalKind(kind);
    return filter;
}

fn relationFilterIsAny(filter: schema.RelationTypeFilter) bool {
    return switch (filter) {
        .any => true,
        else => false,
    };
}

fn effectiveRelationTypeFilter(rel: ?core.RelKind, filter: schema.RelationTypeFilter) schema.RelationTypeFilter {
    if (relationFilterIsAny(filter)) return schema.RelationTypeFilter.fromOptionalRel(rel);
    return filter;
}

fn nodeIdLessThan(_: void, lhs: core.NodeId, rhs: core.NodeId) bool {
    return lhs.toInt() < rhs.toInt();
}

fn sortNodeIds(ids: []core.NodeId) void {
    std.mem.sort(core.NodeId, ids, {}, nodeIdLessThan);
}

const NodeUintPropertySortContext = struct {
    allocator: std.mem.Allocator,
    graph: *const graph_mod.Graph,
    mem_index: *index.MemoryIndex,
    key: []const u8,
};

fn nodeUintPropertyLessThan(ctx: NodeUintPropertySortContext, lhs: core.NodeId, rhs: core.NodeId) bool {
    const lhs_node = ctx.mem_index.getNode(ctx.graph, lhs);
    const rhs_node = ctx.mem_index.getNode(ctx.graph, rhs);
    const lhs_value = if (lhs_node) |node| nodeUintPropertyValue(ctx.allocator, node.text, ctx.key) else null;
    const rhs_value = if (rhs_node) |node| nodeUintPropertyValue(ctx.allocator, node.text, ctx.key) else null;
    if (lhs_value == null and rhs_value == null) return nodeIdLessThan({}, lhs, rhs);
    if (lhs_value == null) return false;
    if (rhs_value == null) return true;
    if (lhs_value.? != rhs_value.?) return lhs_value.? < rhs_value.?;
    return nodeIdLessThan({}, lhs, rhs);
}

fn sortNodeIdsByUintProperty(allocator: std.mem.Allocator, graph: *const graph_mod.Graph, mem_index: *index.MemoryIndex, ids: []core.NodeId, key: []const u8) void {
    std.mem.sort(core.NodeId, ids, NodeUintPropertySortContext{
        .allocator = allocator,
        .graph = graph,
        .mem_index = mem_index,
        .key = key,
    }, nodeUintPropertyLessThan);
}

fn nodeStringPropertyValueAlloc(allocator: std.mem.Allocator, text: []const u8, key: []const u8) !?[]u8 {
    _ = allocator;
    _ = text;
    _ = key;
    return null;
}

fn nodeUintPropertySupported(key: []const u8) bool {
    return std.mem.eql(u8, key, "task_recorded_ns") or
        std.mem.eql(u8, key, "task_created_ns") or
        std.mem.eql(u8, key, "task_completed_ns") or
        std.mem.eql(u8, key, "task_event_ns") or
        std.mem.eql(u8, key, "task_root_id") or
        std.mem.eql(u8, key, "task_id");
}

fn nodeUintPropertyValue(allocator: std.mem.Allocator, text: []const u8, key: []const u8) ?u64 {
    _ = allocator;
    _ = text;
    _ = key;
    return null;
}

fn nodeMatchesStringProperty(allocator: std.mem.Allocator, text: []const u8, property_eq: planner.PropertyPredicate) !bool {
    if (property_eq.op != .eq) return false;
    const parsed_value = try nodeStringPropertyValueAlloc(allocator, text, property_eq.key);
    defer if (parsed_value) |concrete| allocator.free(concrete);
    return if (parsed_value) |concrete|
        std.mem.eql(u8, concrete, property_eq.value)
    else
        nodeStringPropertyMissingMatchesEmpty(property_eq);
}

fn nodeStringPropertyMissingMatchesEmpty(property_eq: planner.PropertyPredicate) bool {
    if (property_eq.op != .eq or property_eq.value.len != 0) return false;
    return std.mem.eql(u8, property_eq.key, "name") or
        std.mem.eql(u8, property_eq.key, "summary");
}

fn predicateMatchesUint(op: ast.PredicateOperator, concrete: u64, expected: u64) bool {
    return switch (op) {
        .eq => concrete == expected,
        .lt => concrete < expected,
        .lte => concrete <= expected,
        .gt => concrete > expected,
        .gte => concrete >= expected,
    };
}

fn uintPropertyRangeForPredicate(op: ast.PredicateOperator, expected: u64) storage.Store.UintPropertyRange {
    return switch (op) {
        .eq => .{ .min = expected, .max = expected },
        .lt => .{ .max = expected, .max_inclusive = false },
        .lte => .{ .max = expected, .max_inclusive = true },
        .gt => .{ .min = expected, .min_inclusive = false },
        .gte => .{ .min = expected, .min_inclusive = true },
    };
}

fn uintPropertyRangeForPlannerRange(range: planner.UintRangePredicate) ?storage.Store.UintPropertyRange {
    return .{
        .min = if (range.min_value) |value| std.fmt.parseInt(u64, value, 10) catch return null else null,
        .min_inclusive = range.min_inclusive,
        .max = if (range.max_value) |value| std.fmt.parseInt(u64, value, 10) catch return null else null,
        .max_inclusive = range.max_inclusive,
    };
}

fn uintPropertyRangeContains(range: storage.Store.UintPropertyRange, value: u64) bool {
    if (range.min) |min| {
        if (range.min_inclusive) {
            if (value < min) return false;
        } else if (value <= min) return false;
    }
    if (range.max) |max| {
        if (range.max_inclusive) {
            if (value > max) return false;
        } else if (value >= max) return false;
    }
    return true;
}

fn nodeMatchesProperty(allocator: std.mem.Allocator, text: []const u8, property_eq: planner.PropertyPredicate) !bool {
    if (nodeUintPropertySupported(property_eq.key)) {
        if (property_eq.uint_range) |planner_range| {
            const range = uintPropertyRangeForPlannerRange(planner_range) orelse return false;
            return if (nodeUintPropertyValue(allocator, text, property_eq.key)) |concrete| uintPropertyRangeContains(range, concrete) else false;
        }
        const expected = std.fmt.parseInt(u64, property_eq.value, 10) catch return false;
        return if (nodeUintPropertyValue(allocator, text, property_eq.key)) |concrete| predicateMatchesUint(property_eq.op, concrete, expected) else false;
    }
    return try nodeMatchesStringProperty(allocator, text, property_eq);
}

fn edgeCursorMatchesStringProperty(edge_cursor: query_mod.EdgeCursor, allocator: std.mem.Allocator, edge_id: core.EdgeId, property_eq: planner.PropertyPredicate) !bool {
    if (property_eq.op != .eq) return false;
    const value = switch (edge_cursor) {
        .memory => return false,
        .store => |cursor| cursor.store.getStringProperty(allocator, .{ .edge = edge_id }, property_eq.key) catch |err| switch (err) {
            core.Error.InvalidId, core.Error.NotFound => return false,
            else => |e| return e,
        },
        .persistent_store => |cursor| cursor.store.getStringProperty(allocator, .{ .edge = edge_id }, property_eq.key) catch |err| switch (err) {
            core.Error.InvalidId, core.Error.NotFound => return false,
            else => |e| return e,
        },
    };
    defer if (value) |owned| allocator.free(owned);
    return if (value) |owned| std.mem.eql(u8, owned, property_eq.value) else false;
}

fn edgeIdSliceContains(sorted_ids: []const core.EdgeId, edge_id: core.EdgeId) bool {
    var lo: usize = 0;
    var hi: usize = sorted_ids.len;
    const needle = edge_id.toInt();
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const current = sorted_ids[mid].toInt();
        if (current < needle) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    return lo < sorted_ids.len and sorted_ids[lo].toInt() == needle;
}

fn lookupEdgeIdsByProperty(edge_cursor: query_mod.EdgeCursor, allocator: std.mem.Allocator, property_eq: planner.PropertyPredicate) !std.ArrayList(core.EdgeId) {
    if (property_eq.op != .eq) return std.ArrayList(core.EdgeId).empty;
    return switch (edge_cursor) {
        .memory => return std.ArrayList(core.EdgeId).empty,
        .store => |cursor| try cursor.store.lookupEdgeIdsByStringProperty(allocator, property_eq.key, property_eq.value, std.math.maxInt(usize)),
        .persistent_store => |cursor| try cursor.store.lookupEdgeIdsByStringProperty(allocator, property_eq.key, property_eq.value, std.math.maxInt(usize)),
    };
}

fn lookupStoreNodeIdsByProperty(store: storage.Store, allocator: std.mem.Allocator, property_eq: planner.PropertyPredicate, kind_filter: ?core.NodeKind, max_ids: usize) !std.ArrayList(core.NodeId) {
    if (nodeUintPropertySupported(property_eq.key)) {
        if (property_eq.uint_range) |planner_range| {
            const range = uintPropertyRangeForPlannerRange(planner_range) orelse return std.ArrayList(core.NodeId).empty;
            return try store.lookupNodeIdsByUintPropertyRange(allocator, property_eq.key, range, kind_filter, max_ids);
        }
        const expected = std.fmt.parseInt(u64, property_eq.value, 10) catch {
            return std.ArrayList(core.NodeId).empty;
        };
        if (property_eq.op != .eq) {
            return try store.lookupNodeIdsByUintPropertyRange(allocator, property_eq.key, uintPropertyRangeForPredicate(property_eq.op, expected), kind_filter, max_ids);
        }
        return try store.lookupNodeIdsByUintProperty(allocator, property_eq.key, expected, kind_filter, max_ids);
    }
    if (property_eq.op != .eq) return std.ArrayList(core.NodeId).empty;
    if (nodeStringPropertyMissingMatchesEmpty(property_eq)) {
        return try lookupStoreNodeIdsByMissingStringProperty(store, allocator, property_eq.key, kind_filter, max_ids);
    }
    return try store.lookupNodeIdsByStringProperty(allocator, property_eq.key, property_eq.value, kind_filter, max_ids);
}

fn lookupStoreNodeIdsByMissingStringProperty(store: storage.Store, allocator: std.mem.Allocator, key: []const u8, kind_filter: ?core.NodeKind, max_ids: usize) !std.ArrayList(core.NodeId) {
    var out = std.ArrayList(core.NodeId).empty;
    errdefer out.deinit(allocator);
    if (max_ids == 0) return out;
    var ids = try store.scanNodeIds(allocator, kind_filter, max_ids);
    defer ids.deinit(allocator);
    for (ids.items) |node_id| {
        const value = store.getNodeStringProperty(allocator, node_id, key) catch |err| switch (err) {
            core.Error.InvalidId, core.Error.NotFound => continue,
            else => |e| return e,
        };
        defer if (value) |owned| allocator.free(owned);
        if (value) |owned| {
            if (owned.len != 0) continue;
        }
        try out.append(allocator, node_id);
    }
    return out;
}

fn visibleNodeText(text: []const u8) []const u8 {
    return text;
}

fn visibleNodeTextEquals(text: []const u8, expected: []const u8) bool {
    return std.mem.eql(u8, text, expected);
}

fn appendUniqueNodeId(allocator: std.mem.Allocator, out: *std.ArrayList(core.NodeId), node_id: core.NodeId) !void {
    for (out.items) |existing| {
        if (existing == node_id) return;
    }
    try out.append(allocator, node_id);
}

const NodeCursor = union(enum) {
    memory: struct {
        graph: *const graph_mod.Graph,
        mem_index: *index.MemoryIndex,
    },
    store: struct {
        allocator: std.mem.Allocator,
        store: storage.Store,
        state: ?*PersistentNodeCursorState = null,
    },

    fn get(self: NodeCursor, allocator: std.mem.Allocator, id: core.NodeId) !?NodeView {
        return switch (self) {
            .memory => |cursor| blk: {
                const node = cursor.mem_index.getNode(cursor.graph, id) orelse break :blk null;
                break :blk NodeView.fromGraphNode(node);
            },
            .store => |cursor| blk: {
                const node = if (cursor.state) |state|
                    (try state.readNodeById(allocator, id)) orelse break :blk null
                else
                    (try cursor.store.readNodeById(allocator, id)) orelse break :blk null;
                break :blk NodeView.fromStoredNode(node);
            },
        };
    }

    fn matchNode(self: NodeCursor, allocator: std.mem.Allocator, id: core.NodeId, kind_filter: ?core.NodeKind, text_eq: ?[]const u8) !?bool {
        return self.matchNodeFilter(allocator, id, schema.NodeTypeFilter.fromOptionalKind(kind_filter), text_eq);
    }

    fn matchNodeFilter(self: NodeCursor, allocator: std.mem.Allocator, id: core.NodeId, type_filter: schema.NodeTypeFilter, text_eq: ?[]const u8) !?bool {
        return switch (self) {
            .memory => |cursor| blk: {
                const node = cursor.mem_index.getNode(cursor.graph, id) orelse break :blk null;
                if (!nodeCursorMemoryNodeIsCurrentGeneration(cursor.graph, id)) break :blk false;
                if (!type_filter.matches(node.kind)) break :blk false;
                if (text_eq) |text| {
                    if (!visibleNodeTextEquals(node.text, text)) break :blk false;
                }
                break :blk true;
            },
            .store => |cursor| blk: {
                if (cursor.state) |state| {
                    break :blk try state.matchNodeFilter(id, type_filter, text_eq);
                }
                var node = (try cursor.store.readNodeById(allocator, id)) orelse break :blk null;
                defer node.deinit(allocator);
                if (!try nodeCursorStoreNodeIsCurrentGeneration(cursor.store, id)) break :blk false;
                if (!type_filter.matches(node.kind)) break :blk false;
                if (text_eq) |text| {
                    if (!visibleNodeTextEquals(node.text, text)) break :blk false;
                }
                break :blk true;
            },
        };
    }

    fn lookupByText(self: NodeCursor, allocator: std.mem.Allocator, kind_filter: ?core.NodeKind, text: []const u8, max_ids: usize) !std.ArrayList(core.NodeId) {
        return self.lookupByTextFilter(allocator, schema.NodeTypeFilter.fromOptionalKind(kind_filter), text, max_ids);
    }

    fn lookupByTextFilter(self: NodeCursor, allocator: std.mem.Allocator, type_filter: schema.NodeTypeFilter, text: []const u8, max_ids: usize) !std.ArrayList(core.NodeId) {
        var out = std.ArrayList(core.NodeId).empty;
        errdefer out.deinit(allocator);
        if (max_ids == 0) return out;
        const candidate_limit = currentGenerationCandidateLimit(max_ids);
        if (type_filter.asSingle()) |kind| {
            switch (self) {
                .memory => |cursor| {
                    for (try cursor.mem_index.lookupByText(kind, text)) |id| {
                        if (out.items.len >= max_ids) break;
                        if (!nodeCursorMemoryNodeIsCurrentGeneration(cursor.graph, id)) continue;
                        try appendUniqueNodeId(allocator, &out, id);
                    }
                },
                .store => |cursor| {
                    var ids = if (cursor.state) |state|
                        try state.lookupByText(allocator, kind, text, candidate_limit)
                    else
                        try cursor.store.lookupNodeIdsByTextLimited(allocator, kind, text, candidate_limit);
                    defer ids.deinit(allocator);
                    try nodeCursorRetainStoreCurrentGeneration(cursor.store, &ids, max_ids);
                    for (ids.items) |id| try appendUniqueNodeId(allocator, &out, id);
                },
            }
            return out;
        }
        switch (self) {
            .memory => |cursor| {
                for (try cursor.mem_index.lookupByText(null, text)) |id| {
                    if (out.items.len >= max_ids) break;
                    if (!nodeCursorMemoryNodeIsCurrentGeneration(cursor.graph, id)) continue;
                    const node = cursor.mem_index.getNode(cursor.graph, id) orelse continue;
                    if (!type_filter.matches(node.kind)) continue;
                    try appendUniqueNodeId(allocator, &out, id);
                }
            },
            .store => |cursor| {
                if (typeFilterIsAny(type_filter)) {
                    var ids = if (cursor.state) |state|
                        try state.lookupByText(allocator, null, text, candidate_limit)
                    else
                        try cursor.store.lookupNodeIdsByTextLimited(allocator, null, text, candidate_limit);
                    defer ids.deinit(allocator);
                    try nodeCursorRetainStoreCurrentGeneration(cursor.store, &ids, max_ids);
                    for (ids.items) |id| try appendUniqueNodeId(allocator, &out, id);
                    return out;
                }
                var merged = std.ArrayList(core.NodeId).empty;
                errdefer merged.deinit(allocator);
                defer merged.deinit(allocator);
                for (0..schema.max_node_types) |raw_id| {
                    const kind: core.NodeKind = @enumFromInt(@as(u16, @intCast(raw_id)));
                    if (!type_filter.matches(kind)) continue;
                    var ids = if (cursor.state) |state|
                        try state.lookupByText(allocator, kind, text, candidate_limit)
                    else
                        try cursor.store.lookupNodeIdsByTextLimited(allocator, kind, text, candidate_limit);
                    defer ids.deinit(allocator);
                    try merged.appendSlice(allocator, ids.items);
                }
                sortNodeIds(merged.items);
                for (merged.items) |id| {
                    if (out.items.len >= max_ids) break;
                    if (!try nodeCursorStoreNodeIsCurrentGeneration(cursor.store, id)) continue;
                    try appendUniqueNodeId(allocator, &out, id);
                }
            },
        }
        return out;
    }

    fn lookupByPropertyFilter(self: NodeCursor, allocator: std.mem.Allocator, type_filter: schema.NodeTypeFilter, property_eq: planner.PropertyPredicate, max_ids: usize) !std.ArrayList(core.NodeId) {
        var out = std.ArrayList(core.NodeId).empty;
        errdefer out.deinit(allocator);
        if (max_ids == 0) return out;
        const candidate_limit = currentGenerationCandidateLimit(max_ids);
        switch (self) {
            .memory => |cursor| {
                const needs_uint_order = nodeUintPropertySupported(property_eq.key);
                for (cursor.graph.nodes.items) |node| {
                    if (!needs_uint_order and out.items.len >= max_ids) break;
                    if (node.status != .active) continue;
                    if (!nodeCursorMemoryNodeIsCurrentGeneration(cursor.graph, node.id)) continue;
                    if (!type_filter.matches(node.kind)) continue;
                    if (!try nodeMatchesProperty(allocator, node.text, property_eq)) continue;
                    try out.append(allocator, node.id);
                }
                if (needs_uint_order) {
                    sortNodeIdsByUintProperty(allocator, cursor.graph, cursor.mem_index, out.items, property_eq.key);
                    if (out.items.len > max_ids) out.shrinkRetainingCapacity(max_ids);
                }
            },
            .store => |cursor| {
                if (type_filter.asSingle()) |kind| {
                    var ids = try lookupStoreNodeIdsByProperty(cursor.store, allocator, property_eq, kind, candidate_limit);
                    errdefer ids.deinit(allocator);
                    try nodeCursorRetainStoreCurrentGeneration(cursor.store, &ids, max_ids);
                    return ids;
                }
                if (typeFilterIsAny(type_filter)) {
                    var ids = try lookupStoreNodeIdsByProperty(cursor.store, allocator, property_eq, null, candidate_limit);
                    errdefer ids.deinit(allocator);
                    try nodeCursorRetainStoreCurrentGeneration(cursor.store, &ids, max_ids);
                    return ids;
                }
                var merged = std.ArrayList(core.NodeId).empty;
                errdefer merged.deinit(allocator);
                defer merged.deinit(allocator);
                for (0..schema.max_node_types) |raw_id| {
                    const kind: core.NodeKind = @enumFromInt(@as(u16, @intCast(raw_id)));
                    if (!type_filter.matches(kind)) continue;
                    var ids = try lookupStoreNodeIdsByProperty(cursor.store, allocator, property_eq, kind, candidate_limit);
                    defer ids.deinit(allocator);
                    try merged.appendSlice(allocator, ids.items);
                }
                sortNodeIds(merged.items);
                for (merged.items) |id| {
                    if (out.items.len >= max_ids) break;
                    if (!try nodeCursorStoreNodeIsCurrentGeneration(cursor.store, id)) continue;
                    try out.append(allocator, id);
                }
            },
        }
        return out;
    }

    fn matchStringProperty(self: NodeCursor, allocator: std.mem.Allocator, id: core.NodeId, property_eq: planner.PropertyPredicate) !?bool {
        var node = (try self.get(allocator, id)) orelse return null;
        defer node.deinit(allocator);
        if (nodeUintPropertySupported(property_eq.key)) {
            return switch (self) {
                .memory => try nodeMatchesProperty(allocator, node.text, property_eq),
                .store => |cursor| blk: {
                    const concrete = try cursor.store.getUintProperty(allocator, .{ .node = id }, property_eq.key) orelse break :blk false;
                    if (property_eq.uint_range) |planner_range| {
                        const range = uintPropertyRangeForPlannerRange(planner_range) orelse break :blk false;
                        break :blk uintPropertyRangeContains(range, concrete);
                    }
                    const expected = std.fmt.parseInt(u64, property_eq.value, 10) catch break :blk false;
                    break :blk predicateMatchesUint(property_eq.op, concrete, expected);
                },
            };
        }
        if (property_eq.op != .eq) return false;
        return switch (self) {
            .memory => try nodeMatchesStringProperty(allocator, node.text, property_eq),
            .store => |cursor| blk: {
                const value = cursor.store.getNodeStringProperty(allocator, id, property_eq.key) catch |err| switch (err) {
                    core.Error.InvalidId, core.Error.NotFound => break :blk null,
                    else => |e| return e,
                };
                defer if (value) |owned| allocator.free(owned);
                break :blk if (value) |owned|
                    std.mem.eql(u8, owned, property_eq.value)
                else
                    nodeStringPropertyMissingMatchesEmpty(property_eq);
            },
        };
    }

    fn uintProperty(self: NodeCursor, allocator: std.mem.Allocator, id: core.NodeId, key: []const u8) !?u64 {
        if (!nodeUintPropertySupported(key)) return null;
        return switch (self) {
            .memory => blk: {
                var node = (try self.get(allocator, id)) orelse return null;
                defer node.deinit(allocator);
                break :blk nodeUintPropertyValue(allocator, node.text, key);
            },
            .store => |cursor| try cursor.store.getUintProperty(allocator, .{ .node = id }, key),
        };
    }

    fn scan(self: NodeCursor, allocator: std.mem.Allocator, kind_filter: ?core.NodeKind, max_ids: usize) !std.ArrayList(core.NodeId) {
        return self.scanFilter(allocator, schema.NodeTypeFilter.fromOptionalKind(kind_filter), max_ids);
    }

    fn scanFilter(self: NodeCursor, allocator: std.mem.Allocator, type_filter: schema.NodeTypeFilter, max_ids: usize) !std.ArrayList(core.NodeId) {
        return switch (self) {
            .memory => |cursor| blk: {
                var out = std.ArrayList(core.NodeId).empty;
                errdefer out.deinit(allocator);
                for (cursor.graph.nodes.items) |node| {
                    if (out.items.len >= max_ids) break;
                    if (node.status != .active) continue;
                    if (!nodeCursorMemoryNodeIsCurrentGeneration(cursor.graph, node.id)) continue;
                    if (!type_filter.matches(node.kind)) continue;
                    try out.append(allocator, node.id);
                }
                break :blk out;
            },
            .store => |cursor| blk: {
                const candidate_limit = currentGenerationCandidateLimit(max_ids);
                if (type_filter.asSingle()) |kind| {
                    var ids = try cursor.store.scanNodeIds(allocator, kind, candidate_limit);
                    errdefer ids.deinit(allocator);
                    try nodeCursorRetainStoreCurrentGeneration(cursor.store, &ids, max_ids);
                    break :blk ids;
                }
                if (typeFilterIsAny(type_filter)) {
                    var ids = try cursor.store.scanNodeIds(allocator, null, candidate_limit);
                    errdefer ids.deinit(allocator);
                    try nodeCursorRetainStoreCurrentGeneration(cursor.store, &ids, max_ids);
                    break :blk ids;
                }
                var merged = std.ArrayList(core.NodeId).empty;
                errdefer merged.deinit(allocator);
                for (0..schema.max_node_types) |raw_id| {
                    const kind: core.NodeKind = @enumFromInt(@as(u16, @intCast(raw_id)));
                    if (!type_filter.matches(kind)) continue;
                    var ids = try cursor.store.scanNodeIds(allocator, kind, candidate_limit);
                    defer ids.deinit(allocator);
                    try merged.appendSlice(allocator, ids.items);
                }
                sortNodeIds(merged.items);
                var write_index: usize = 0;
                for (merged.items) |id| {
                    if (write_index >= max_ids) break;
                    if (!try nodeCursorStoreNodeIsCurrentGeneration(cursor.store, id)) continue;
                    merged.items[write_index] = id;
                    write_index += 1;
                }
                merged.shrinkRetainingCapacity(write_index);
                break :blk merged;
            },
        };
    }

    fn searchText(
        self: NodeCursor,
        allocator: std.mem.Allocator,
        query: []const u8,
        kind_filter: ?core.NodeKind,
        max_ids: usize,
        max_postings_scanned: usize,
        deadline: core.QueryDeadline,
    ) !std.ArrayList(text_mod.TextSearchHit) {
        return switch (self) {
            .memory => |cursor| blk: {
                var text_index = try text_mod.TextIndex.buildFromGraphDeadline(allocator, cursor.graph, deadline);
                defer text_index.deinit();
                break :blk try text_index.search(query, .{
                    .kind_filter = kind_filter,
                    .limit = max_ids,
                    .max_postings_scanned = max_postings_scanned,
                    .deadline = deadline,
                });
            },
            .store => |cursor| blk: {
                var hits = try text_mod.searchText(allocator, cursor.store, query, .{
                    .kind_filter = kind_filter,
                    .limit = textSearchCandidateLimitForLatest(max_ids),
                    .max_postings_scanned = max_postings_scanned,
                    .deadline = deadline,
                });
                errdefer hits.deinit(allocator);
                try retainCurrentGenerationTextHits(cursor.store, &hits, max_ids);
                break :blk hits;
            },
        };
    }
};

fn textSearchCandidateLimitForLatest(max_ids: usize) usize {
    if (max_ids == 0) return 0;
    const max_candidate_limit: usize = 4096;
    const expanded = std.math.add(usize, std.math.mul(usize, max_ids, 4) catch max_candidate_limit, 32) catch max_candidate_limit;
    return @min(max_candidate_limit, @max(max_ids, expanded));
}

fn retainCurrentGenerationTextHits(store: storage.Store, hits: *std.ArrayList(text_mod.TextSearchHit), max_ids: usize) !void {
    var write_index: usize = 0;
    for (hits.items) |hit| {
        if (write_index >= max_ids) break;
        if (!try nodeCursorStoreNodeIsCurrentGeneration(store, hit.node_id)) continue;
        hits.items[write_index] = hit;
        write_index += 1;
    }
    hits.shrinkRetainingCapacity(write_index);
}

fn currentGenerationCandidateLimit(max_ids: usize) usize {
    if (max_ids == 0) return 0;
    const max_candidate_limit: usize = 4096;
    const expanded = std.math.add(usize, std.math.mul(usize, max_ids, 4) catch max_candidate_limit, 32) catch max_candidate_limit;
    return @min(max_candidate_limit, @max(max_ids, expanded));
}

fn nodeCursorRetainStoreCurrentGeneration(store: storage.Store, ids: *std.ArrayList(core.NodeId), max_ids: usize) !void {
    var write_index: usize = 0;
    for (ids.items) |id| {
        if (write_index >= max_ids) break;
        if (!try nodeCursorStoreNodeIsCurrentGeneration(store, id)) continue;
        ids.items[write_index] = id;
        write_index += 1;
    }
    ids.shrinkRetainingCapacity(write_index);
}

fn nodeCursorStoreNodeIsCurrentGeneration(store: storage.Store, node_id: core.NodeId) !bool {
    var iter = try store.edgeIndexRecordsByNodeAndRelationIterator(.src, node_id, .deprecated_by);
    defer iter.deinit();
    return (try iter.next()) == null;
}

fn nodeCursorMemoryNodeIsCurrentGeneration(graph: *const graph_mod.Graph, node_id: core.NodeId) bool {
    for (graph.edges.items) |edge| {
        if (edge.status != .active) continue;
        if (edge.src == node_id and edge.rel == .deprecated_by) return false;
    }
    return true;
}

const PersistentNodeCursorState = struct {
    // Avoid paying mmap/open setup for tiny result sets; switch after repeated node materialization.
    const direct_reads_before_view: usize = 8;

    store: storage.Store,
    node_text_retention_registry: ?*storage.NodeTextRunRetentionRegistry = null,
    node_view: ?storage.Store.NodeRecordView = null,
    node_id_view: ?storage.Store.NodeByIdIndexView = null,
    node_text_lookup_view: ?storage.Store.NodeTextLookupView = null,
    direct_reads: usize = 0,

    fn deinit(self: *PersistentNodeCursorState) void {
        if (self.node_text_lookup_view) |*view| view.deinit();
        if (self.node_view) |*view| view.deinit();
        if (self.node_id_view) |*view| view.deinit();
    }

    fn readNodeById(self: *PersistentNodeCursorState, allocator: std.mem.Allocator, id: core.NodeId) !?storage.StoredNode {
        if (self.node_view == null and self.direct_reads < direct_reads_before_view) {
            self.direct_reads += 1;
            return try self.store.readNodeById(allocator, id);
        }
        if (self.node_view == null) self.node_view = try self.store.openNodeRecordView();
        return try self.node_view.?.readNodeById(allocator, id);
    }

    fn matchNode(self: *PersistentNodeCursorState, id: core.NodeId, kind_filter: ?core.NodeKind, text_eq: ?[]const u8) !?bool {
        return self.matchNodeFilter(id, schema.NodeTypeFilter.fromOptionalKind(kind_filter), text_eq);
    }

    fn matchNodeFilter(self: *PersistentNodeCursorState, id: core.NodeId, type_filter: schema.NodeTypeFilter, text_eq: ?[]const u8) !?bool {
        if (!try nodeCursorStoreNodeIsCurrentGeneration(self.store, id)) return false;
        if (text_eq == null) {
            if (self.node_id_view == null) self.node_id_view = try self.store.openNodeByIdIndexView();
            const kind = (try self.node_id_view.?.nodeKind(id)) orelse return null;
            if (!type_filter.matches(kind)) return false;
            return true;
        }
        if (self.node_view == null) self.node_view = try self.store.openNodeRecordView();
        var node = (try self.node_view.?.readNodeById(self.store.allocator, id)) orelse return null;
        defer node.deinit(self.store.allocator);
        if (!type_filter.matches(node.kind)) return false;
        return visibleNodeTextEquals(node.text, text_eq.?);
    }

    fn lookupByText(self: *PersistentNodeCursorState, allocator: std.mem.Allocator, kind_filter: ?core.NodeKind, text: []const u8, max_ids: usize) !std.ArrayList(core.NodeId) {
        if (self.node_text_lookup_view == null) {
            self.node_text_lookup_view = if (self.node_text_retention_registry) |registry|
                try self.store.openNodeTextLookupViewRetained(allocator, registry)
            else
                try self.store.openNodeTextLookupView(allocator);
        }
        return try self.node_text_lookup_view.?.lookupIds(allocator, kind_filter, text, max_ids);
    }
};

pub const PersistentStoreQuerySession = struct {
    allocator: std.mem.Allocator,
    store: storage.Store,
    edge_retention_registry: storage.EdgeSegmentRetentionRegistry,
    node_text_retention_registry: storage.NodeTextRunRetentionRegistry,
    node_state: PersistentNodeCursorState,

    pub fn init(allocator: std.mem.Allocator, store: storage.Store) PersistentStoreQuerySession {
        return .{
            .allocator = allocator,
            .store = store,
            .edge_retention_registry = storage.EdgeSegmentRetentionRegistry.init(allocator),
            .node_text_retention_registry = storage.NodeTextRunRetentionRegistry.init(allocator),
            .node_state = .{ .store = store },
        };
    }

    pub fn deinit(self: *PersistentStoreQuerySession) void {
        self.node_state.deinit();
        self.node_text_retention_registry.deinit();
        self.edge_retention_registry.deinit();
    }

    pub fn execute(
        self: *PersistentStoreQuerySession,
        io: std.Io,
        plan: optimizer.PhysicalPlan,
        budget: core.QueryBudget,
    ) !ResultTable {
        var repaired = false;
        while (true) {
            self.bindNodeState();
            return executeWithCursorDeadline(
                self.allocator,
                .{ .store = .{ .allocator = self.allocator, .store = self.store, .state = &self.node_state } },
                .{ .persistent_store = .{ .allocator = self.allocator, .store = self.store, .edge_retention_registry = &self.edge_retention_registry } },
                plan,
                budget,
                core.QueryDeadline.fromIo(io, budget.timeout_ms),
                null,
            ) catch |err| switch (err) {
                error.FileNotFound, error.InvalidRecord => {
                    if (repaired) return err;
                    repaired = true;
                    self.node_state.deinit();
                    self.resetNodeState();
                    try self.store.repairPersistentIndexesFromLog();
                    continue;
                },
                else => |e| return e,
            };
        }
    }

    pub fn edgeRetentionRegistry(self: *PersistentStoreQuerySession) *storage.EdgeSegmentRetentionRegistry {
        return &self.edge_retention_registry;
    }

    fn bindNodeState(self: *PersistentStoreQuerySession) void {
        self.node_state.store = self.store;
        self.node_state.node_text_retention_registry = &self.node_text_retention_registry;
    }

    fn resetNodeState(self: *PersistentStoreQuerySession) void {
        self.node_state = .{
            .store = self.store,
            .node_text_retention_registry = &self.node_text_retention_registry,
        };
    }
};

pub fn execute(allocator: std.mem.Allocator, graph: *const graph_mod.Graph, plan: optimizer.PhysicalPlan) !ResultTable {
    return executeWithBudget(allocator, graph, plan, .{});
}

pub fn executeWithBudget(allocator: std.mem.Allocator, graph: *const graph_mod.Graph, plan: optimizer.PhysicalPlan, budget: @import("../core.zig").QueryBudget) !ResultTable {
    var mem_index = try index.MemoryIndex.init(allocator, graph);
    defer mem_index.deinit();
    return executeWithIndex(allocator, graph, &mem_index, plan, budget);
}

pub fn executeWithIndex(
    allocator: std.mem.Allocator,
    graph: *const graph_mod.Graph,
    mem_index: *index.MemoryIndex,
    plan: optimizer.PhysicalPlan,
    budget: @import("../core.zig").QueryBudget,
) !ResultTable {
    return executeWithIndexDeadline(allocator, graph, mem_index, plan, budget, core.QueryDeadline.immediateOrNone(budget.timeout_ms));
}

pub fn executeWithIndexAndIo(
    allocator: std.mem.Allocator,
    io: std.Io,
    graph: *const graph_mod.Graph,
    mem_index: *index.MemoryIndex,
    plan: optimizer.PhysicalPlan,
    budget: @import("../core.zig").QueryBudget,
) !ResultTable {
    return executeWithIndexDeadline(allocator, graph, mem_index, plan, budget, core.QueryDeadline.fromIo(io, budget.timeout_ms));
}

pub fn executeWithStoreAndIo(
    allocator: std.mem.Allocator,
    io: std.Io,
    store: storage.Store,
    graph: *const graph_mod.Graph,
    mem_index: *index.MemoryIndex,
    plan: optimizer.PhysicalPlan,
    budget: @import("../core.zig").QueryBudget,
) !ResultTable {
    return executeWithCursorDeadline(
        allocator,
        .{ .memory = .{ .graph = graph, .mem_index = mem_index } },
        .{ .store = .{ .allocator = allocator, .store = store, .graph = graph } },
        plan,
        budget,
        core.QueryDeadline.fromIo(io, budget.timeout_ms),
        null,
    );
}

pub fn executeWithPersistentStoreAndIo(
    allocator: std.mem.Allocator,
    io: std.Io,
    store: storage.Store,
    plan: optimizer.PhysicalPlan,
    budget: @import("../core.zig").QueryBudget,
) !ResultTable {
    return executeWithPersistentStoreAndIoMaybeRetained(allocator, io, store, null, plan, budget);
}

pub fn executeWithPersistentStoreAndIoRetained(
    allocator: std.mem.Allocator,
    io: std.Io,
    store: storage.Store,
    edge_retention_registry: *storage.EdgeSegmentRetentionRegistry,
    plan: optimizer.PhysicalPlan,
    budget: @import("../core.zig").QueryBudget,
) !ResultTable {
    return executeWithPersistentStoreAndIoMaybeRetained(allocator, io, store, edge_retention_registry, plan, budget);
}

pub fn executeWithPersistentStoreAndIoRetainedIndexes(
    allocator: std.mem.Allocator,
    io: std.Io,
    store: storage.Store,
    edge_retention_registry: *storage.EdgeSegmentRetentionRegistry,
    node_text_retention_registry: *storage.NodeTextRunRetentionRegistry,
    plan: optimizer.PhysicalPlan,
    budget: @import("../core.zig").QueryBudget,
) !ResultTable {
    return executeWithPersistentStoreAndIoMaybeRetainedIndexes(allocator, io, store, edge_retention_registry, node_text_retention_registry, plan, budget);
}

pub fn executeWithPersistentStoreAndIoRetainedIndexesExplain(
    allocator: std.mem.Allocator,
    io: std.Io,
    store: storage.Store,
    edge_retention_registry: ?*storage.EdgeSegmentRetentionRegistry,
    node_text_retention_registry: ?*storage.NodeTextRunRetentionRegistry,
    plan: optimizer.PhysicalPlan,
    budget: @import("../core.zig").QueryBudget,
    timings: *OperatorTimingRecorder,
) !ResultTable {
    return executeWithPersistentStoreAndIoMaybeRetainedIndexesTimed(allocator, io, store, edge_retention_registry, node_text_retention_registry, plan, budget, timings);
}

fn executeWithPersistentStoreAndIoMaybeRetained(
    allocator: std.mem.Allocator,
    io: std.Io,
    store: storage.Store,
    edge_retention_registry: ?*storage.EdgeSegmentRetentionRegistry,
    plan: optimizer.PhysicalPlan,
    budget: @import("../core.zig").QueryBudget,
) !ResultTable {
    return executeWithPersistentStoreAndIoMaybeRetainedIndexes(allocator, io, store, edge_retention_registry, null, plan, budget);
}

fn executeWithPersistentStoreAndIoMaybeRetainedIndexes(
    allocator: std.mem.Allocator,
    io: std.Io,
    store: storage.Store,
    edge_retention_registry: ?*storage.EdgeSegmentRetentionRegistry,
    node_text_retention_registry: ?*storage.NodeTextRunRetentionRegistry,
    plan: optimizer.PhysicalPlan,
    budget: @import("../core.zig").QueryBudget,
) !ResultTable {
    return executeWithPersistentStoreAndIoMaybeRetainedIndexesTimed(allocator, io, store, edge_retention_registry, node_text_retention_registry, plan, budget, null);
}

fn executeWithPersistentStoreAndIoMaybeRetainedIndexesTimed(
    allocator: std.mem.Allocator,
    io: std.Io,
    store: storage.Store,
    edge_retention_registry: ?*storage.EdgeSegmentRetentionRegistry,
    node_text_retention_registry: ?*storage.NodeTextRunRetentionRegistry,
    plan: optimizer.PhysicalPlan,
    budget: @import("../core.zig").QueryBudget,
    timings: ?*OperatorTimingRecorder,
) !ResultTable {
    if (timings) |recorder| try recorder.ensureCapacityForPlan(plan);
    var repaired = false;
    while (true) {
        if (timings) |recorder| recorder.clearRetainingCapacity();
        var node_state = PersistentNodeCursorState{ .store = store, .node_text_retention_registry = node_text_retention_registry };
        defer node_state.deinit();
        return executeWithCursorDeadline(
            allocator,
            .{ .store = .{ .allocator = allocator, .store = store, .state = &node_state } },
            .{ .persistent_store = .{ .allocator = allocator, .store = store, .edge_retention_registry = edge_retention_registry } },
            plan,
            budget,
            core.QueryDeadline.fromIo(io, budget.timeout_ms),
            timings,
        ) catch |err| switch (err) {
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

fn executeWithIndexDeadline(
    allocator: std.mem.Allocator,
    graph: *const graph_mod.Graph,
    mem_index: *index.MemoryIndex,
    plan: optimizer.PhysicalPlan,
    budget: @import("../core.zig").QueryBudget,
    deadline: core.QueryDeadline,
) !ResultTable {
    return executeWithCursorDeadline(
        allocator,
        .{ .memory = .{ .graph = graph, .mem_index = mem_index } },
        .{ .memory = .{ .mem_index = mem_index } },
        plan,
        budget,
        deadline,
        null,
    );
}

fn executeWithCursorDeadline(
    allocator: std.mem.Allocator,
    node_cursor: NodeCursor,
    edge_cursor: query_mod.EdgeCursor,
    plan: optimizer.PhysicalPlan,
    budget: @import("../core.zig").QueryBudget,
    deadline: core.QueryDeadline,
    timings: ?*OperatorTimingRecorder,
) !ResultTable {
    var table = ResultTable.init();
    errdefer table.deinit(allocator);
    const limit: ?usize = effectiveLimit(plan, budget);
    if (limit != null and limit.? == 0) return table;
    if (deadline.expired()) {
        table.stats.budget_exceeded = true;
        return table;
    }
    const store_scores = shouldStoreScores(plan);

    for (plan.ops.items, 0..) |op, op_index| {
        const can_apply_result_limit = !hasLaterExpandOrBlockingOrder(plan, op_index, op);
        const timing_start_ns = if (timings) |recorder| recorder.nowNs() else 0;
        const timing_input_rows = table.rows.items.len;
        const timing_input_nodes = table.stats.nodes_visited;
        const timing_input_edges = table.stats.edges_visited;
        defer if (timings) |recorder| {
            const timing_end_ns = recorder.nowNs();
            recorder.recordAssumeCapacity(.{
                .op_index = op_index,
                .op_name = physicalOpName(op),
                .elapsed_ns = if (timing_end_ns >= timing_start_ns) timing_end_ns - timing_start_ns else 0,
                .input_rows = timing_input_rows,
                .output_rows = table.rows.items.len,
                .nodes_visited_delta = table.stats.nodes_visited -| timing_input_nodes,
                .edges_visited_delta = table.stats.edges_visited -| timing_input_edges,
                .budget_exceeded = table.stats.budget_exceeded,
            });
        };
        switch (op) {
            .text_search => |text_search| {
                if (nodeBudgetExhausted(&table, budget)) break;
                const can_cap_text_candidates = can_apply_result_limit and text_search.text_eq == null;
                const text_limit = if (can_cap_text_candidates) (limit orelse text_search.limit) else null;
                const text_type_filter = effectiveNodeTypeFilter(text_search.kind, text_search.type_filter);
                const maybe_hits: ?std.ArrayList(text_mod.TextSearchHit) = node_cursor.searchText(allocator, text_search.query, text_search.kind, seedCap(can_cap_text_candidates, text_limit, budget), budget.max_text_postings_scanned, deadline) catch |err| switch (err) {
                    core.Error.BudgetExceeded => blk: {
                        table.stats.budget_exceeded = true;
                        break :blk null;
                    },
                    else => |e| return e,
                };
                var hits = maybe_hits orelse continue;
                defer hits.deinit(allocator);
                try reserveSeedRows(allocator, &table, hits.items.len, can_apply_result_limit, limit);
                for (hits.items) |hit| {
                    if (deadline.expired()) {
                        table.stats.budget_exceeded = true;
                        break;
                    }
                    if (can_apply_result_limit) if (limit) |max| {
                        if (table.rows.items.len >= max) break;
                    };
                    if (table.stats.nodes_visited >= budget.max_visited_nodes) {
                        table.stats.budget_exceeded = true;
                        break;
                    }
                    try index.addVisitedNodes(&table.stats, 1);
                    if (text_search.text_eq) |text| {
                        const matches = (try node_cursor.matchNodeFilter(allocator, hit.node_id, text_type_filter, text)) orelse {
                            try missingCandidateNode(node_cursor);
                            continue;
                        };
                        if (!matches) continue;
                    }
                    var row = if (store_scores)
                        try Row.initBindingScore(allocator, text_search.var_name, hit.node_id, hit.score)
                    else
                        try Row.initBinding(allocator, text_search.var_name, hit.node_id);
                    var row_owned = true;
                    errdefer if (row_owned) row.deinit(allocator);
                    try table.rows.append(allocator, row);
                    row_owned = false;
                    table.stats.results = table.rows.items.len;
                }
            },
            .node_lookup_by_text => |lookup| {
                if (nodeBudgetExhausted(&table, budget)) break;
                const lookup_type_filter = effectiveNodeTypeFilter(lookup.kind, lookup.type_filter);
                var node_ids = try node_cursor.lookupByTextFilter(allocator, lookup_type_filter, lookup.text, seedCap(can_apply_result_limit, limit, budget));
                defer node_ids.deinit(allocator);
                try reserveSeedRows(allocator, &table, node_ids.items.len, can_apply_result_limit, limit);
                for (node_ids.items) |node_id| {
                    if (deadline.expired()) {
                        table.stats.budget_exceeded = true;
                        break;
                    }
                    if (can_apply_result_limit) if (limit) |max| {
                        if (table.rows.items.len >= max) break;
                    };
                    if (table.stats.nodes_visited >= budget.max_visited_nodes) {
                        table.stats.budget_exceeded = true;
                        break;
                    }
                    try index.addVisitedNodes(&table.stats, 1);
                    if (lookup.property_eq) |property_eq| {
                        const matches = (try node_cursor.matchStringProperty(allocator, node_id, property_eq)) orelse {
                            try missingCandidateNode(node_cursor);
                            continue;
                        };
                        if (!matches) continue;
                    }
                    var row = try Row.initBinding(allocator, lookup.var_name, node_id);
                    var row_owned = true;
                    errdefer if (row_owned) row.deinit(allocator);
                    try table.rows.append(allocator, row);
                    row_owned = false;
                    table.stats.results = table.rows.items.len;
                }
            },
            .node_lookup_by_property => |lookup| {
                if (nodeBudgetExhausted(&table, budget)) break;
                const lookup_type_filter = effectiveNodeTypeFilter(lookup.kind, lookup.type_filter);
                var node_ids = try node_cursor.lookupByPropertyFilter(allocator, lookup_type_filter, lookup.property_eq, seedCap(can_apply_result_limit, limit, budget));
                defer node_ids.deinit(allocator);
                try reserveSeedRows(allocator, &table, node_ids.items.len, can_apply_result_limit, limit);
                for (node_ids.items) |node_id| {
                    if (deadline.expired()) {
                        table.stats.budget_exceeded = true;
                        break;
                    }
                    if (can_apply_result_limit) if (limit) |max| {
                        if (table.rows.items.len >= max) break;
                    };
                    if (table.stats.nodes_visited >= budget.max_visited_nodes) {
                        table.stats.budget_exceeded = true;
                        break;
                    }
                    try index.addVisitedNodes(&table.stats, 1);
                    var row = try Row.initBinding(allocator, lookup.var_name, node_id);
                    var row_owned = true;
                    errdefer if (row_owned) row.deinit(allocator);
                    try table.rows.append(allocator, row);
                    row_owned = false;
                    table.stats.results = table.rows.items.len;
                }
            },
            .node_scan => |scan| {
                if (nodeBudgetExhausted(&table, budget)) break;
                const can_cap_scan_candidates = can_apply_result_limit and scan.text_eq == null;
                const scan_type_filter = effectiveNodeTypeFilter(scan.kind, scan.type_filter);
                var node_ids = try node_cursor.scanFilter(allocator, scan_type_filter, seedCap(can_cap_scan_candidates, if (can_cap_scan_candidates) limit else null, budget));
                defer node_ids.deinit(allocator);
                try reserveSeedRows(allocator, &table, node_ids.items.len, can_apply_result_limit, limit);
                for (node_ids.items) |node_id| {
                    if (deadline.expired()) {
                        table.stats.budget_exceeded = true;
                        break;
                    }
                    if (can_apply_result_limit) if (limit) |max| {
                        if (table.rows.items.len >= max) break;
                    };
                    if (table.stats.nodes_visited >= budget.max_visited_nodes) {
                        table.stats.budget_exceeded = true;
                        break;
                    }
                    try index.addVisitedNodes(&table.stats, 1);
                    if (scan.text_eq) |text| {
                        const matches = (try node_cursor.matchNodeFilter(allocator, node_id, scan_type_filter, text)) orelse {
                            try missingCandidateNode(node_cursor);
                            continue;
                        };
                        if (!matches) continue;
                    }
                    if (scan.property_eq) |property_eq| {
                        const matches = (try node_cursor.matchStringProperty(allocator, node_id, property_eq)) orelse {
                            try missingCandidateNode(node_cursor);
                            continue;
                        };
                        if (!matches) continue;
                    }
                    var row = try Row.initBinding(allocator, scan.var_name, node_id);
                    var row_owned = true;
                    errdefer if (row_owned) row.deinit(allocator);
                    try table.rows.append(allocator, row);
                    row_owned = false;
                    table.stats.results = table.rows.items.len;
                }
            },
            .expand => |expand| {
                var next = ResultTable.init();
                next.stats = table.stats;
                errdefer next.deinit(allocator);
                try reserveExpandRows(allocator, &next, can_apply_result_limit, limit);
                var edge_property_candidate_ids = if (expand.edge_property_eq) |property_eq|
                    try lookupEdgeIdsByProperty(edge_cursor, allocator, property_eq)
                else
                    std.ArrayList(core.EdgeId).empty;
                defer edge_property_candidate_ids.deinit(allocator);
                const edge_property_filter: ?[]const core.EdgeId = if (expand.edge_property_eq != null)
                    edge_property_candidate_ids.items
                else
                    null;
                const store_paths = shouldStoreExpandPath(plan, expand);
                const left_binding_index = commonBindingIndex(table.rows.items, expand.left_var);
                const right_var_absent = !anyRowHasBinding(table.rows.items, expand.right_var);
                for (table.rows.items) |row| {
                    if (can_apply_result_limit) if (limit) |max| {
                        if (next.rows.items.len >= max) break;
                    };
                    const left_id = row.getAt(left_binding_index, expand.left_var) orelse continue;
                    const limit_reached = try expandFromRow(allocator, node_cursor, edge_cursor, row, expand, left_id, &next, if (can_apply_result_limit) limit else null, budget, deadline, store_paths, right_var_absent, store_scores, edge_property_filter);
                    if (limit_reached) break;
                }
                next.stats.results = next.rows.items.len;
                table.deinit(allocator);
                table = next;
            },
            .order_by => |order_by| try sortResultTableByOrder(allocator, node_cursor, &table, order_by),
            .project => {},
            .limit => |max| {
                if (table.rows.items.len > max) {
                    var i: usize = max;
                    while (i < table.rows.items.len) : (i += 1) {
                        table.rows.items[i].deinit(allocator);
                    }
                    table.rows.shrinkRetainingCapacity(max);
                }
                table.stats.results = table.rows.items.len;
            },
        }
    }
    return table;
}

fn nodeBudgetExhausted(table: *ResultTable, budget: core.QueryBudget) bool {
    if (table.stats.nodes_visited < budget.max_visited_nodes) return false;
    table.stats.budget_exceeded = true;
    return true;
}

fn effectiveLimit(plan: optimizer.PhysicalPlan, budget: core.QueryBudget) ?usize {
    var out: ?usize = budget.max_results;
    for (plan.ops.items) |op| {
        if (op == .limit) {
            out = if (out) |current| @min(current, op.limit) else op.limit;
        }
    }
    return out;
}

fn seedCap(can_apply_result_limit: bool, limit: ?usize, budget: core.QueryBudget) usize {
    if (!can_apply_result_limit) return std.math.add(usize, budget.max_visited_nodes, 1) catch std.math.maxInt(usize);
    const by_results = limit orelse budget.max_results;
    if (budget.max_visited_nodes < by_results) {
        const sentinel_cap = std.math.add(usize, budget.max_visited_nodes, 1) catch std.math.maxInt(usize);
        return @min(by_results, sentinel_cap);
    }
    return by_results;
}

fn reserveSeedRows(allocator: std.mem.Allocator, table: *ResultTable, candidate_count: usize, can_apply_result_limit: bool, limit: ?usize) !void {
    if (candidate_count == 0) return;
    var reserve_count = candidate_count;
    if (can_apply_result_limit) if (limit) |max| {
        if (table.rows.items.len >= max) return;
        reserve_count = @min(reserve_count, max - table.rows.items.len);
    };
    try table.rows.ensureUnusedCapacity(allocator, reserve_count);
}

fn reserveExpandRows(allocator: std.mem.Allocator, table: *ResultTable, can_apply_result_limit: bool, limit: ?usize) !void {
    if (!can_apply_result_limit) return;
    const max = limit orelse return;
    if (table.rows.items.len >= max) return;
    try table.rows.ensureUnusedCapacity(allocator, max - table.rows.items.len);
}

const OrderByRowKey = struct {
    index: usize,
    has_value: bool,
    value: u64 = 0,
    node_id: core.NodeId = .none,
};

const OrderByRowKeyContext = struct {
    direction: ast.OrderDirection,
};

fn orderByRowKeyLessThan(ctx: OrderByRowKeyContext, lhs: OrderByRowKey, rhs: OrderByRowKey) bool {
    if (lhs.has_value != rhs.has_value) return lhs.has_value;
    if (lhs.has_value and lhs.value != rhs.value) {
        return switch (ctx.direction) {
            .asc => lhs.value < rhs.value,
            .desc => lhs.value > rhs.value,
        };
    }
    if (lhs.node_id.toInt() != rhs.node_id.toInt()) return lhs.node_id.toInt() < rhs.node_id.toInt();
    return lhs.index < rhs.index;
}

fn orderByValueForRow(node_cursor: NodeCursor, allocator: std.mem.Allocator, row: Row, order_by: ast.OrderBy) !OrderByRowKey {
    const node_id = row.get(order_by.var_name) orelse return .{ .index = 0, .has_value = false };
    const value = (try node_cursor.uintProperty(allocator, node_id, order_by.property)) orelse return .{ .index = 0, .has_value = false, .node_id = node_id };
    return .{ .index = 0, .has_value = true, .value = value, .node_id = node_id };
}

fn sortResultTableByOrder(allocator: std.mem.Allocator, node_cursor: NodeCursor, table: *ResultTable, order_by: ast.OrderBy) !void {
    if (table.rows.items.len <= 1) return;
    var keys = std.ArrayList(OrderByRowKey).empty;
    defer keys.deinit(allocator);
    try keys.ensureTotalCapacity(allocator, table.rows.items.len);
    for (table.rows.items, 0..) |row, index_pos| {
        var key = try orderByValueForRow(node_cursor, allocator, row, order_by);
        key.index = index_pos;
        keys.appendAssumeCapacity(key);
    }
    std.mem.sort(OrderByRowKey, keys.items, OrderByRowKeyContext{ .direction = order_by.direction }, orderByRowKeyLessThan);

    var ordered_rows = std.ArrayList(Row).empty;
    errdefer ordered_rows.deinit(allocator);
    try ordered_rows.ensureTotalCapacity(allocator, table.rows.items.len);
    for (keys.items) |key| {
        ordered_rows.appendAssumeCapacity(table.rows.items[key.index]);
    }
    var old_rows = table.rows;
    table.rows = ordered_rows;
    old_rows.deinit(allocator);
}

fn hasLaterExpand(plan: optimizer.PhysicalPlan, op_index: usize) bool {
    for (plan.ops.items[op_index + 1 ..]) |op| {
        if (op == .expand) return true;
    }
    return false;
}

fn hasLaterExpandOrBlockingOrder(plan: optimizer.PhysicalPlan, op_index: usize, op: optimizer.PhysicalOp) bool {
    if (hasLaterExpand(plan, op_index)) return true;
    const order_by = laterOrderBy(plan, op_index) orelse return false;
    return !opStreamSatisfiesOrder(op, order_by);
}

fn laterOrderBy(plan: optimizer.PhysicalPlan, op_index: usize) ?ast.OrderBy {
    for (plan.ops.items[op_index + 1 ..]) |op| {
        if (op == .order_by) return op.order_by;
    }
    return null;
}

fn opStreamSatisfiesOrder(op: optimizer.PhysicalOp, order_by: ast.OrderBy) bool {
    if (order_by.direction != .asc) return false;
    return switch (op) {
        .node_lookup_by_property => |lookup| std.mem.eql(u8, lookup.var_name, order_by.var_name) and
            std.mem.eql(u8, lookup.property_eq.key, order_by.property) and
            nodeUintPropertySupported(order_by.property),
        else => false,
    };
}

fn shouldStoreExpandPath(plan: optimizer.PhysicalPlan, expand: planner.Expand) bool {
    var saw_project = false;
    for (plan.ops.items) |op| {
        switch (op) {
            .project => |projections| {
                saw_project = true;
                for (projections) |projection| {
                    switch (projection) {
                        .path => |path| {
                            if (std.mem.eql(u8, path.from_var, expand.left_var) and
                                std.mem.eql(u8, path.to_var, expand.right_var))
                            {
                                return true;
                            }
                        },
                        else => {},
                    }
                }
            },
            else => {},
        }
    }
    return !saw_project;
}

fn shouldStoreScores(plan: optimizer.PhysicalPlan) bool {
    var saw_project = false;
    for (plan.ops.items) |op| {
        switch (op) {
            .project => |projections| {
                saw_project = true;
                for (projections) |projection| {
                    if (projection == .score) return true;
                }
            },
            else => {},
        }
    }
    return !saw_project;
}

fn physicalOpName(op: optimizer.PhysicalOp) []const u8 {
    return switch (op) {
        .text_search => "text_search",
        .node_lookup_by_text => "node_lookup_by_text",
        .node_lookup_by_property => "node_lookup_by_property",
        .node_scan => "node_scan",
        .expand => "expand",
        .order_by => "order_by",
        .project => "project",
        .limit => "limit",
    };
}

fn commonBindingIndex(rows: []const Row, name: []const u8) ?usize {
    if (rows.len == 0) return null;
    for (rows[0].bindings.items, 0..) |binding, index_pos| {
        if (!std.mem.eql(u8, binding.name, name)) continue;
        for (rows[1..]) |row| {
            if (index_pos >= row.bindings.items.len) return null;
            if (!std.mem.eql(u8, row.bindings.items[index_pos].name, name)) return null;
        }
        return index_pos;
    }
    return null;
}

fn anyRowHasBinding(rows: []const Row, name: []const u8) bool {
    for (rows) |row| {
        if (row.get(name) != null) return true;
    }
    return false;
}

fn expandFromRow(
    allocator: std.mem.Allocator,
    node_cursor: NodeCursor,
    edge_cursor: query_mod.EdgeCursor,
    row: Row,
    expand: planner.Expand,
    left_id: @import("../core.zig").NodeId,
    next: *ResultTable,
    limit: ?usize,
    budget: @import("../core.zig").QueryBudget,
    deadline: core.QueryDeadline,
    store_paths: bool,
    right_var_absent: bool,
    store_scores: bool,
    edge_property_candidate_ids: ?[]const core.EdgeId,
) !bool {
    const max_hops = @min(expand.max_hops, budget.max_depth);
    if (max_hops < expand.min_hops) {
        next.stats.budget_exceeded = true;
        return false;
    }
    if (max_hops == 1) {
        var initial_nodes = [_]core.NodeId{left_id};
        const current = FrontierItem{ .id = left_id, .depth = 0, .nodes = initial_nodes[0..] };
        if (expand.direction == .outgoing or expand.direction == .undirected) {
            var ctx = ExpandEdgeContext{
                .allocator = allocator,
                .node_cursor = node_cursor,
                .edge_cursor = edge_cursor,
                .row = row,
                .expand = expand,
                .current = current,
                .frontier = null,
                .next = next,
                .limit = limit,
                .budget = budget,
                .deadline = deadline,
                .direction = .outgoing,
                .max_hops = max_hops,
                .store_paths = store_paths,
                .right_var_absent = right_var_absent,
                .store_scores = store_scores,
                .edge_property_candidate_ids = edge_property_candidate_ids,
            };
            if (try forEachOutgoingRelationFilter(edge_cursor, current.id, effectiveRelationTypeFilter(expand.rel, expand.rel_filter), &ctx)) return true;
        }
        if (expand.direction == .incoming or expand.direction == .undirected) {
            var ctx = ExpandEdgeContext{
                .allocator = allocator,
                .node_cursor = node_cursor,
                .edge_cursor = edge_cursor,
                .row = row,
                .expand = expand,
                .current = current,
                .frontier = null,
                .next = next,
                .limit = limit,
                .budget = budget,
                .deadline = deadline,
                .direction = .incoming,
                .max_hops = max_hops,
                .store_paths = store_paths,
                .right_var_absent = right_var_absent,
                .store_scores = store_scores,
                .edge_property_candidate_ids = edge_property_candidate_ids,
            };
            if (try forEachIncomingRelationFilter(edge_cursor, current.id, effectiveRelationTypeFilter(expand.rel, expand.rel_filter), &ctx)) return true;
        }
        return false;
    }
    var frontier = std.ArrayList(FrontierItem).empty;
    defer {
        for (frontier.items) |item| allocator.free(item.nodes);
        frontier.deinit(allocator);
    }
    const initial_path = try allocator.dupe(core.NodeId, &.{left_id});
    var initial_path_owned = true;
    errdefer if (initial_path_owned) allocator.free(initial_path);
    try frontier.append(allocator, .{ .id = left_id, .depth = 0, .nodes = initial_path });
    initial_path_owned = false;
    var pos: usize = 0;
    while (pos < frontier.items.len) : (pos += 1) {
        const current = frontier.items[pos];
        if (deadline.expired()) {
            next.stats.budget_exceeded = true;
            return false;
        }
        if (current.depth >= max_hops) continue;
        if (expand.direction == .outgoing or expand.direction == .undirected) {
            var ctx = ExpandEdgeContext{
                .allocator = allocator,
                .node_cursor = node_cursor,
                .edge_cursor = edge_cursor,
                .row = row,
                .expand = expand,
                .current = current,
                .frontier = &frontier,
                .next = next,
                .limit = limit,
                .budget = budget,
                .deadline = deadline,
                .direction = .outgoing,
                .max_hops = max_hops,
                .store_paths = store_paths,
                .right_var_absent = right_var_absent,
                .store_scores = store_scores,
                .edge_property_candidate_ids = edge_property_candidate_ids,
            };
            if (try forEachOutgoingRelationFilter(edge_cursor, current.id, effectiveRelationTypeFilter(expand.rel, expand.rel_filter), &ctx)) return true;
        }
        if (expand.direction == .incoming or expand.direction == .undirected) {
            var ctx = ExpandEdgeContext{
                .allocator = allocator,
                .node_cursor = node_cursor,
                .edge_cursor = edge_cursor,
                .row = row,
                .expand = expand,
                .current = current,
                .frontier = &frontier,
                .next = next,
                .limit = limit,
                .budget = budget,
                .deadline = deadline,
                .direction = .incoming,
                .max_hops = max_hops,
                .store_paths = store_paths,
                .right_var_absent = right_var_absent,
                .store_scores = store_scores,
                .edge_property_candidate_ids = edge_property_candidate_ids,
            };
            if (try forEachIncomingRelationFilter(edge_cursor, current.id, effectiveRelationTypeFilter(expand.rel, expand.rel_filter), &ctx)) return true;
        }
    }
    return false;
}

const FrontierItem = struct { id: core.NodeId, depth: u8, nodes: []core.NodeId };

const ExpandEdgeContext = struct {
    allocator: std.mem.Allocator,
    node_cursor: NodeCursor,
    edge_cursor: query_mod.EdgeCursor,
    row: Row,
    expand: planner.Expand,
    current: FrontierItem,
    frontier: ?*std.ArrayList(FrontierItem),
    next: *ResultTable,
    limit: ?usize,
    budget: core.QueryBudget,
    deadline: core.QueryDeadline,
    direction: ast.EdgeDirection,
    max_hops: u8,
    store_paths: bool,
    right_var_absent: bool,
    store_scores: bool,
    edge_property_candidate_ids: ?[]const core.EdgeId,
};

fn forEachOutgoingRelationFilter(edge_cursor: query_mod.EdgeCursor, node_id: core.NodeId, rel_filter: schema.RelationTypeFilter, ctx: *ExpandEdgeContext) !bool {
    if (rel_filter.asSingle()) |rel| return try edge_cursor.forEachOutgoingRelation(node_id, rel, ctx, expandEdgeCallback);
    if (relationFilterIsAny(rel_filter)) return try edge_cursor.forEachOutgoingRelation(node_id, null, ctx, expandEdgeCallback);
    return try forEachRelationSet(edge_cursor, .outgoing, node_id, rel_filter, ctx);
}

fn forEachIncomingRelationFilter(edge_cursor: query_mod.EdgeCursor, node_id: core.NodeId, rel_filter: schema.RelationTypeFilter, ctx: *ExpandEdgeContext) !bool {
    if (rel_filter.asSingle()) |rel| return try edge_cursor.forEachIncomingRelation(node_id, rel, ctx, expandEdgeCallback);
    if (relationFilterIsAny(rel_filter)) return try edge_cursor.forEachIncomingRelation(node_id, null, ctx, expandEdgeCallback);
    return try forEachRelationSet(edge_cursor, .incoming, node_id, rel_filter, ctx);
}

fn forEachRelationSet(edge_cursor: query_mod.EdgeCursor, direction: ast.EdgeDirection, node_id: core.NodeId, rel_filter: schema.RelationTypeFilter, ctx: *ExpandEdgeContext) !bool {
    for (0..schema.max_relation_types) |raw_id| {
        const rel: core.RelKind = @enumFromInt(@as(u16, @intCast(raw_id)));
        if (!rel_filter.matches(rel)) continue;
        const stopped = switch (direction) {
            .outgoing => try edge_cursor.forEachOutgoingRelation(node_id, rel, ctx, expandEdgeCallback),
            .incoming => try edge_cursor.forEachIncomingRelation(node_id, rel, ctx, expandEdgeCallback),
            .undirected => return core.Error.Unsupported,
        };
        if (stopped) return true;
    }
    return false;
}

fn expandEdgeCallback(ctx: *ExpandEdgeContext, edge: index.EdgeRef) !bool {
    if (ctx.expand.direction == .undirected and ctx.direction == .incoming and edge.src.toInt() == edge.dst.toInt()) {
        return false;
    }
    if (ctx.deadline.expired()) {
        ctx.next.stats.budget_exceeded = true;
        return true;
    }
    if (ctx.next.stats.edges_visited >= ctx.budget.max_visited_edges) {
        ctx.next.stats.budget_exceeded = true;
        return true;
    }
    try index.addVisitedEdges(&ctx.next.stats, 1);
    if (ctx.expand.edge_property_eq) |property_eq| {
        if (ctx.edge_property_candidate_ids) |candidate_ids| {
            if (!edgeIdSliceContains(candidate_ids, edge.edge_id)) return false;
        } else if (!try edgeCursorMatchesStringProperty(ctx.edge_cursor, ctx.allocator, edge.edge_id, property_eq)) return false;
    }
    const next_id = switch (ctx.direction) {
        .outgoing => edge.dst,
        .incoming => edge.src,
        .undirected => return core.Error.Unsupported,
    };
    if (ctx.expand.max_hops > 1 and pathContains(ctx.current.nodes, next_id)) return false;
    const depth = ctx.current.depth + 1;
    if (ctx.next.stats.nodes_visited >= ctx.budget.max_visited_nodes) {
        ctx.next.stats.budget_exceeded = true;
        return true;
    }
    const can_return_at_depth = depth >= ctx.expand.min_hops;
    const match_type_filter = if (can_return_at_depth) effectiveNodeTypeFilter(ctx.expand.right_kind, ctx.expand.right_type_filter) else schema.NodeTypeFilter.any;
    const match_text = if (can_return_at_depth) ctx.expand.right_text_eq else null;
    const node_matches = (try ctx.node_cursor.matchNodeFilter(ctx.allocator, next_id, match_type_filter, match_text)) orelse return missingExpansionTarget(ctx.node_cursor);
    try index.addVisitedNodes(&ctx.next.stats, 1);
    var next_path_buf: [max_tinyql_expand_path_nodes]core.NodeId = undefined;
    var next_path: ?[]core.NodeId = null;
    if (depth < ctx.max_hops or ctx.store_paths) {
        const next_len = ctx.current.nodes.len + 1;
        if (next_len > next_path_buf.len) return error.RecordTooLarge;
        const path = next_path_buf[0..next_len];
        @memcpy(path[0..ctx.current.nodes.len], ctx.current.nodes);
        path[ctx.current.nodes.len] = next_id;
        next_path = path;
    }
    if (depth < ctx.max_hops) {
        const owned_path = try ctx.allocator.dupe(core.NodeId, next_path.?);
        var owned_path_transferred = false;
        errdefer if (!owned_path_transferred) ctx.allocator.free(owned_path);
        try ctx.frontier.?.append(ctx.allocator, .{
            .id = next_id,
            .depth = depth,
            .nodes = owned_path,
        });
        owned_path_transferred = true;
    } else if (depth < ctx.expand.max_hops) {
        ctx.next.stats.budget_exceeded = true;
    }
    if (!can_return_at_depth) return false;
    if (!node_matches) return false;
    var new_row = if (ctx.right_var_absent)
        try ctx.row.cloneAppendingBinding(ctx.allocator, ctx.expand.right_var, next_id, ctx.store_scores)
    else
        (try ctx.row.cloneWithOptionalBindingAndScores(ctx.allocator, .{ .name = ctx.expand.right_var, .node_id = next_id }, ctx.store_scores)) orelse return false;
    errdefer new_row.deinit(ctx.allocator);
    if (ctx.expand.edge_var) |edge_var| {
        if (!try new_row.putEdge(ctx.allocator, edge_var, edge.edge_id)) return false;
    }
    if (ctx.store_paths) try new_row.putPath(ctx.allocator, ctx.expand.left_var, ctx.expand.right_var, next_path.?);
    try ctx.next.rows.append(ctx.allocator, new_row);
    ctx.next.stats.results = ctx.next.rows.items.len;
    if (ctx.limit) |max| {
        if (ctx.next.rows.items.len >= max) return true;
    }
    return false;
}

fn missingExpansionTarget(node_cursor: NodeCursor) anyerror!bool {
    return switch (node_cursor) {
        .memory => false,
        .store => error.InvalidRecord,
    };
}

const max_tinyql_expand_path_nodes: usize = @as(usize, std.math.maxInt(u8)) + 1;

fn missingCandidateNode(node_cursor: NodeCursor) anyerror!void {
    return switch (node_cursor) {
        .memory => {},
        .store => error.InvalidRecord,
    };
}

fn pathContains(nodes: []const core.NodeId, id: core.NodeId) bool {
    for (nodes) |node| {
        if (node.toInt() == id.toInt()) return true;
    }
    return false;
}

test "row clone preserves values with independent ownership" {
    var row = Row.init();
    defer row.deinit(std.testing.allocator);
    try std.testing.expect(try row.put(std.testing.allocator, "a", .fromInt(1)));
    try row.putPath(std.testing.allocator, "a", "b", &.{ .fromInt(1), .fromInt(2) });
    try row.putScore(std.testing.allocator, "a", 1.25);

    var cloned = try row.clone(std.testing.allocator);
    defer cloned.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u64, 1), cloned.get("a").?.toInt());
    try std.testing.expectEqual(@as(f32, 1.25), cloned.getScore("a").?);
    const cloned_path = cloned.getPath("a", "b") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 2), cloned_path.len);
    try std.testing.expectEqual(@as(u64, 2), cloned_path[1].toInt());

    try std.testing.expect(try row.put(std.testing.allocator, "c", .fromInt(3)));
    try row.putPath(std.testing.allocator, "a", "b", &.{ .fromInt(1), .fromInt(3) });
    try row.putScore(std.testing.allocator, "a", 9.0);

    try std.testing.expect(cloned.get("c") == null);
    try std.testing.expectEqual(@as(f32, 1.25), cloned.getScore("a").?);
    try std.testing.expectEqual(@as(u64, 2), cloned.getPath("a", "b").?[1].toInt());
}

test "row seed helpers create owned binding rows" {
    var row = try Row.initBinding(std.testing.allocator, "n", .fromInt(99));
    defer row.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 99), row.get("n").?.toInt());
    try std.testing.expect(row.getScore("n") == null);

    var scored = try Row.initBindingScore(std.testing.allocator, "hit", .fromInt(7), 3.5);
    defer scored.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 7), scored.get("hit").?.toInt());
    try std.testing.expectEqual(@as(f32, 3.5), scored.getScore("hit").?);
}

test "seed row reservation respects result limit remainder" {
    var table = ResultTable.init();
    defer table.deinit(std.testing.allocator);

    try reserveSeedRows(std.testing.allocator, &table, 0, true, 4);
    try std.testing.expectEqual(@as(usize, 0), table.rows.capacity);

    try reserveSeedRows(std.testing.allocator, &table, 8, true, 3);
    try std.testing.expect(table.rows.capacity >= 3);

    var row = try Row.initBinding(std.testing.allocator, "n", .fromInt(1));
    var row_owned = true;
    errdefer if (row_owned) row.deinit(std.testing.allocator);
    try table.rows.append(std.testing.allocator, row);
    row_owned = false;

    const before = table.rows.capacity;
    try reserveSeedRows(std.testing.allocator, &table, 8, true, 1);
    try std.testing.expectEqual(before, table.rows.capacity);
}

test "expand row reservation is bounded by effective result limit" {
    var table = ResultTable.init();
    defer table.deinit(std.testing.allocator);

    try reserveExpandRows(std.testing.allocator, &table, false, 4);
    try std.testing.expectEqual(@as(usize, 0), table.rows.capacity);

    try reserveExpandRows(std.testing.allocator, &table, true, 4);
    try std.testing.expect(table.rows.capacity >= 4);

    var row = try Row.initBinding(std.testing.allocator, "n", .fromInt(1));
    var row_owned = true;
    errdefer if (row_owned) row.deinit(std.testing.allocator);
    try table.rows.append(std.testing.allocator, row);
    row_owned = false;

    const before = table.rows.capacity;
    try reserveExpandRows(std.testing.allocator, &table, true, 1);
    try std.testing.expectEqual(before, table.rows.capacity);
}

test "row clone with binding preserves conflict semantics" {
    var row = try Row.initBinding(std.testing.allocator, "a", .fromInt(1));
    defer row.deinit(std.testing.allocator);
    try row.putPath(std.testing.allocator, "a", "b", &.{ .fromInt(1), .fromInt(2) });

    var appended = (try row.cloneWithBinding(std.testing.allocator, "b", .fromInt(2))).?;
    defer appended.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 1), appended.get("a").?.toInt());
    try std.testing.expectEqual(@as(u64, 2), appended.get("b").?.toInt());
    try std.testing.expectEqual(@as(u64, 2), appended.getPath("a", "b").?[1].toInt());

    var matching = (try row.cloneWithBinding(std.testing.allocator, "a", .fromInt(1))).?;
    defer matching.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, row.bindings.items.len), matching.bindings.items.len);
    try std.testing.expectEqual(@as(u64, 1), matching.get("a").?.toInt());

    const conflict = try row.cloneWithBinding(std.testing.allocator, "a", .fromInt(9));
    try std.testing.expect(conflict == null);
}

test "row clone appending binding skips conflict scan when caller proves absence" {
    var row = try Row.initBindingScore(std.testing.allocator, "hit", .fromInt(1), 2.5);
    defer row.deinit(std.testing.allocator);

    var appended = try row.cloneAppendingBinding(std.testing.allocator, "next", .fromInt(2), true);
    defer appended.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u64, 1), appended.get("hit").?.toInt());
    try std.testing.expectEqual(@as(u64, 2), appended.get("next").?.toInt());
    try std.testing.expectEqual(@as(f32, 2.5), appended.getScore("hit").?);
    try std.testing.expectEqual(@as(usize, 2), appended.bindings.items.len);

    var without_score = try row.cloneAppendingBinding(std.testing.allocator, "next", .fromInt(2), false);
    defer without_score.deinit(std.testing.allocator);
    try std.testing.expect(without_score.getScore("hit") == null);
}

test "executor detects common binding slot for factorized expand input" {
    var first = try Row.initBinding(std.testing.allocator, "left", .fromInt(1));
    defer first.deinit(std.testing.allocator);
    try std.testing.expect(try first.put(std.testing.allocator, "other", .fromInt(9)));
    var second = try Row.initBinding(std.testing.allocator, "left", .fromInt(2));
    defer second.deinit(std.testing.allocator);
    try std.testing.expect(try second.put(std.testing.allocator, "other", .fromInt(10)));

    var rows = [_]Row{ first, second };
    try std.testing.expectEqual(@as(?usize, 0), commonBindingIndex(&rows, "left"));
    try std.testing.expectEqual(@as(u64, 2), rows[1].getAt(commonBindingIndex(&rows, "left"), "left").?.toInt());
    try std.testing.expect(!anyRowHasBinding(&rows, "missing"));

    var mismatched = try Row.initBinding(std.testing.allocator, "other", .fromInt(3));
    defer mismatched.deinit(std.testing.allocator);
    try std.testing.expect(try mismatched.put(std.testing.allocator, "left", .fromInt(4)));
    var mixed = [_]Row{ first, mismatched };
    try std.testing.expectEqual(@as(?usize, null), commonBindingIndex(&mixed, "left"));
    try std.testing.expectEqual(@as(u64, 4), mixed[1].getAt(commonBindingIndex(&mixed, "left"), "left").?.toInt());
}

test "executor expands outgoing edge" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    const file = try graph.addNode(.file, "a.zig");
    const func = try graph.addNode(.function, "main");
    _ = try graph.addEdgeUnchecked(file, .defines, func);

    var ops = std.ArrayList(optimizer.PhysicalOp).empty;
    defer ops.deinit(std.testing.allocator);
    try ops.append(std.testing.allocator, .{ .node_lookup_by_text = .{ .var_name = "f", .kind = .file, .text = "a.zig" } });
    try ops.append(std.testing.allocator, .{ .expand = .{ .left_var = "f", .rel = .defines, .right_var = "s", .right_kind = .function } });

    var table = try execute(std.testing.allocator, &graph, .{ .ops = ops });
    defer table.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), table.rows.items.len);
    try std.testing.expectEqual(func.toInt(), table.rows.items[0].get("s").?.toInt());
}

test "executor expand respects visited node budget" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    const file = try graph.addNode(.file, "a.zig");
    _ = try graph.addNode(.function, "main");
    _ = try graph.addEdgeUnchecked(file, .defines, core.NodeId.fromInt(2));

    var ops = std.ArrayList(optimizer.PhysicalOp).empty;
    defer ops.deinit(std.testing.allocator);
    try ops.append(std.testing.allocator, .{ .node_lookup_by_text = .{ .var_name = "f", .kind = .file, .text = "a.zig" } });
    try ops.append(std.testing.allocator, .{ .expand = .{ .left_var = "f", .rel = .defines, .right_var = "s", .right_kind = .function } });

    var table = try executeWithBudget(std.testing.allocator, &graph, .{ .ops = ops }, .{ .max_visited_nodes = 1 });
    defer table.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), table.rows.items.len);
    try std.testing.expect(table.stats.budget_exceeded);
}

test "executor expand uses relation-bounded edge budget" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    const file = try graph.addNode(.file, "a.zig");
    const doc = try graph.addNode(.document, "README");
    const func = try graph.addNode(.function, "main");
    _ = try graph.addEdgeUnchecked(file, .contains, doc);
    _ = try graph.addEdgeUnchecked(file, .defines, func);

    var ops = std.ArrayList(optimizer.PhysicalOp).empty;
    defer ops.deinit(std.testing.allocator);
    try ops.append(std.testing.allocator, .{ .node_lookup_by_text = .{ .var_name = "f", .kind = .file, .text = "a.zig" } });
    try ops.append(std.testing.allocator, .{ .expand = .{ .left_var = "f", .rel = .defines, .right_var = "s", .right_kind = .function } });

    var table = try executeWithBudget(std.testing.allocator, &graph, .{ .ops = ops }, .{ .max_visited_edges = 1 });
    defer table.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), table.rows.items.len);
    try std.testing.expectEqual(func.toInt(), table.rows.items[0].get("s").?.toInt());
    try std.testing.expect(!table.stats.budget_exceeded);
    try std.testing.expectEqual(@as(usize, 1), table.stats.edges_visited);
}

test "persistent executor expand uses relation-bounded edge budget" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    const file = core.NodeId.fromInt(1);
    const doc = core.NodeId.fromInt(2);
    const func = core.NodeId.fromInt(3);
    try store.appendNode(.{ .id = file, .kind = .file, .text = "a.zig" });
    try store.appendNode(.{ .id = doc, .kind = .document, .text = "README" });
    try store.appendNode(.{ .id = func, .kind = .function, .text = "main" });
    try store.appendEdge(.{ .id = .fromInt(1), .src = file, .rel = .contains, .dst = doc });
    try store.appendEdge(.{ .id = .fromInt(2), .src = file, .rel = .defines, .dst = func });

    var ops = std.ArrayList(optimizer.PhysicalOp).empty;
    defer ops.deinit(std.testing.allocator);
    try ops.append(std.testing.allocator, .{ .node_lookup_by_text = .{ .var_name = "f", .kind = .file, .text = "a.zig" } });
    try ops.append(std.testing.allocator, .{ .expand = .{ .left_var = "f", .rel = .defines, .right_var = "s", .right_kind = .function } });

    var table = try executeWithPersistentStoreAndIo(std.testing.allocator, std.testing.io, store, .{ .ops = ops }, .{ .max_visited_edges = 1 });
    defer table.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), table.rows.items.len);
    try std.testing.expectEqual(func.toInt(), table.rows.items[0].get("s").?.toInt());
    try std.testing.expect(!table.stats.budget_exceeded);
    try std.testing.expectEqual(@as(usize, 1), table.stats.edges_visited);
}

test "persistent query session reuses node-text lookup view across executions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    const file = core.NodeId.fromInt(1);
    try store.appendNode(.{ .id = file, .kind = .file, .text = "a.zig" });

    var ops = std.ArrayList(optimizer.PhysicalOp).empty;
    defer ops.deinit(std.testing.allocator);
    try ops.append(std.testing.allocator, .{ .node_lookup_by_text = .{ .var_name = "f", .kind = .file, .text = "a.zig" } });

    var session = PersistentStoreQuerySession.init(std.testing.allocator, store);
    defer session.deinit();

    var first = try session.execute(std.testing.io, .{ .ops = ops }, .{});
    defer first.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), first.rows.items.len);
    try std.testing.expectEqual(file.toInt(), first.rows.items[0].get("f").?.toInt());
    try std.testing.expect(session.node_state.node_text_lookup_view != null);
    const retained_view = session.node_state.node_text_lookup_view.?;

    var second = try session.execute(std.testing.io, .{ .ops = ops }, .{});
    defer second.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), second.rows.items.len);
    try std.testing.expectEqual(file.toInt(), second.rows.items[0].get("f").?.toInt());
    try std.testing.expect(session.node_state.node_text_lookup_view != null);
    try std.testing.expectEqual(retained_view, session.node_state.node_text_lookup_view.?);
}

test "persistent executor lazily opens published edge segments by node range" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);
    const base_segment_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "base-segment" });
    defer std.testing.allocator.free(base_segment_path);

    var store = try storage.Store.initWithOptions(std.testing.allocator, std.testing.io, store_path, .{
        .durability = .fast,
        .validate_indexes_on_read = false,
    });
    defer store.deinit();
    try store.createEmpty();

    const file = core.NodeId.fromInt(1);
    const func = core.NodeId.fromInt(2);
    const unrelated_file = core.NodeId.fromInt(10);
    const unrelated_func = core.NodeId.fromInt(11);
    const delta_file = core.NodeId.fromInt(20);
    const delta_func = core.NodeId.fromInt(21);
    try store.appendNode(.{ .id = file, .kind = .file, .text = "a.zig" });
    try store.appendNode(.{ .id = func, .kind = .function, .text = "main" });
    try store.appendNode(.{ .id = unrelated_file, .kind = .file, .text = "b.zig" });
    try store.appendNode(.{ .id = unrelated_func, .kind = .function, .text = "helper" });
    try store.appendNode(.{ .id = delta_file, .kind = .file, .text = "c.zig" });
    try store.appendNode(.{ .id = delta_func, .kind = .function, .text = "delta" });

    var base_edges = std.ArrayList(graph_mod.Edge).empty;
    defer base_edges.deinit(std.testing.allocator);
    try base_edges.ensureTotalCapacity(std.testing.allocator, 1024);
    base_edges.appendAssumeCapacity(.{
        .id = .fromInt(1),
        .src = file,
        .rel = .defines,
        .dst = func,
    });
    var edge_id: u64 = 1;
    while (edge_id < 1024) : (edge_id += 1) {
        base_edges.appendAssumeCapacity(.{
            .id = .fromInt(edge_id + 1),
            .src = unrelated_file,
            .rel = .defines,
            .dst = unrelated_func,
        });
    }
    try store.appendEdgesBatch(base_edges.items);
    try std.testing.expectEqual(@as(u64, 1024), try store.publishEdgeAdjacencySegment(base_segment_path));

    try store.appendEdge(.{
        .id = .fromInt(1025),
        .src = delta_file,
        .rel = .defines,
        .dst = delta_func,
    });

    var base_query_segments = (try store.openPublishedEdgeSegmentsForQueryForNode(std.testing.allocator, .forward, file)).?;
    defer base_query_segments.deinit();
    try std.testing.expectEqual(@as(usize, 1), base_query_segments.segments.segments.items.len);
    try std.testing.expectEqual(@as(usize, 0), base_query_segments.segments.virtual_edges.items.len);

    var delta_query_segments = (try store.openPublishedEdgeSegmentsForQueryForNode(std.testing.allocator, .forward, delta_file)).?;
    defer delta_query_segments.deinit();
    try std.testing.expectEqual(@as(usize, 0), delta_query_segments.segments.segments.items.len);
    try std.testing.expectEqual(@as(usize, 1), delta_query_segments.segments.virtual_edges.items.len);

    var ops = std.ArrayList(optimizer.PhysicalOp).empty;
    defer ops.deinit(std.testing.allocator);
    try ops.append(std.testing.allocator, .{ .node_lookup_by_text = .{ .var_name = "f", .kind = .file, .text = "a.zig" } });
    try ops.append(std.testing.allocator, .{ .expand = .{ .left_var = "f", .rel = .defines, .right_var = "s", .right_kind = .function } });

    var table = try executeWithPersistentStoreAndIo(std.testing.allocator, std.testing.io, store, .{ .ops = ops }, .{});
    defer table.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), table.rows.items.len);
    try std.testing.expectEqual(func.toInt(), table.rows.items[0].get("s").?.toInt());
    try std.testing.expect(!table.stats.budget_exceeded);
}

test "persistent executor expand kind filter avoids node text materialization" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage.Store.initWithOptions(std.testing.allocator, std.testing.io, store_path, .{
        .durability = .fast,
        .validate_indexes_on_read = false,
    });
    defer store.deinit();
    try store.createEmpty();

    const file = core.NodeId.fromInt(1);
    const func = core.NodeId.fromInt(2);
    try store.appendNode(.{ .id = file, .kind = .file, .text = "a.zig" });
    try store.appendNode(.{ .id = func, .kind = .function, .text = "main" });
    try store.appendEdge(.{ .id = .fromInt(1), .src = file, .rel = .defines, .dst = func });

    const names_path = try std.fs.path.join(std.testing.allocator, &.{ store_path, "node_texts.dat" });
    defer std.testing.allocator.free(names_path);
    try std.Io.Dir.cwd().deleteFile(std.testing.io, names_path);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, names_path);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, names_path) catch {};

    var ops = std.ArrayList(optimizer.PhysicalOp).empty;
    defer ops.deinit(std.testing.allocator);
    try ops.append(std.testing.allocator, .{ .node_scan = .{ .var_name = "f", .kind = .file } });
    try ops.append(std.testing.allocator, .{ .expand = .{ .left_var = "f", .rel = .defines, .right_var = "s", .right_kind = .function } });

    var table = try executeWithPersistentStoreAndIo(std.testing.allocator, std.testing.io, store, .{ .ops = ops }, .{});
    defer table.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), table.rows.items.len);
    try std.testing.expectEqual(func.toInt(), table.rows.items[0].get("s").?.toInt());
    try std.testing.expectEqual(@as(usize, 2), table.stats.nodes_visited);
}

test "executor expand with no matches keeps result stats in sync" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    const file = try graph.addNode(.file, "a.zig");
    const doc = try graph.addNode(.document, "README");
    _ = try graph.addEdgeUnchecked(file, .mentions, doc);

    var ops = std.ArrayList(optimizer.PhysicalOp).empty;
    defer ops.deinit(std.testing.allocator);
    try ops.append(std.testing.allocator, .{ .node_lookup_by_text = .{ .var_name = "f", .kind = .file, .text = "a.zig" } });
    try ops.append(std.testing.allocator, .{ .expand = .{ .left_var = "f", .rel = .defines, .right_var = "s", .right_kind = .function } });

    var table = try execute(std.testing.allocator, &graph, .{ .ops = ops });
    defer table.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), table.rows.items.len);
    try std.testing.expectEqual(@as(usize, 0), table.stats.results);
    try std.testing.expect(!table.stats.budget_exceeded);
}

test "executor expand edge budget stops matching relation" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    const file = try graph.addNode(.file, "a.zig");
    const func = try graph.addNode(.function, "main");
    _ = try graph.addEdgeUnchecked(file, .defines, func);

    var ops = std.ArrayList(optimizer.PhysicalOp).empty;
    defer ops.deinit(std.testing.allocator);
    try ops.append(std.testing.allocator, .{ .node_lookup_by_text = .{ .var_name = "f", .kind = .file, .text = "a.zig" } });
    try ops.append(std.testing.allocator, .{ .expand = .{ .left_var = "f", .rel = .defines, .right_var = "s", .right_kind = .function } });

    var table = try executeWithBudget(std.testing.allocator, &graph, .{ .ops = ops }, .{ .max_visited_edges = 0 });
    defer table.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), table.rows.items.len);
    try std.testing.expect(table.stats.budget_exceeded);
    try std.testing.expectEqual(@as(usize, 0), table.stats.edges_visited);
}

test "executor expand respects max depth budget" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    const a = try graph.addNode(.task, "a");
    const b = try graph.addNode(.task, "b");
    const c = try graph.addNode(.task, "c");
    _ = try graph.addEdgeUnchecked(a, .depends_on, b);
    _ = try graph.addEdgeUnchecked(b, .depends_on, c);

    var ops = std.ArrayList(optimizer.PhysicalOp).empty;
    defer ops.deinit(std.testing.allocator);
    try ops.append(std.testing.allocator, .{ .node_lookup_by_text = .{ .var_name = "a", .kind = .task, .text = "a" } });
    try ops.append(std.testing.allocator, .{ .expand = .{ .left_var = "a", .rel = .depends_on, .right_var = "t", .right_kind = .task, .min_hops = 1, .max_hops = 2 } });

    var table = try executeWithBudget(std.testing.allocator, &graph, .{ .ops = ops }, .{ .max_depth = 1 });
    defer table.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), table.rows.items.len);
    try std.testing.expectEqual(b.toInt(), table.rows.items[0].get("t").?.toInt());
    try std.testing.expect(table.stats.budget_exceeded);
}

test "executor variable-hop expansion uses simple node paths through cycles" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    const a = try graph.addNode(.task, "a");
    const b = try graph.addNode(.task, "b");
    const c = try graph.addNode(.task, "c");
    _ = try graph.addEdgeUnchecked(a, .depends_on, b);
    _ = try graph.addEdgeUnchecked(b, .depends_on, a);
    _ = try graph.addEdgeUnchecked(b, .depends_on, c);

    var ops = std.ArrayList(optimizer.PhysicalOp).empty;
    defer ops.deinit(std.testing.allocator);
    try ops.append(std.testing.allocator, .{ .node_lookup_by_text = .{ .var_name = "a", .kind = .task, .text = "a" } });
    try ops.append(std.testing.allocator, .{
        .expand = .{
            .left_var = "a",
            .rel = .depends_on,
            .right_var = "t",
            .right_kind = .task,
            .min_hops = 1,
            .max_hops = 3,
        },
    });

    var table = try execute(std.testing.allocator, &graph, .{ .ops = ops });
    defer table.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), table.rows.items.len);

    var saw_b = false;
    var saw_c = false;
    for (table.rows.items) |row| {
        const target = row.get("t").?;
        if (target.toInt() == b.toInt()) saw_b = true;
        if (target.toInt() == c.toInt()) saw_c = true;
        const path = row.getPath("a", "t").?;
        for (path, 0..) |node, i| {
            for (path[i + 1 ..]) |later| {
                try std.testing.expect(node.toInt() != later.toInt());
            }
        }
    }
    try std.testing.expect(saw_b);
    try std.testing.expect(saw_c);
}

test "executor variable-hop applies right predicates only at return depth" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    const start = try graph.addNode(.task, "start");
    const middle = try graph.addNode(.concept, "middle");
    const target = try graph.addNode(.task, "target");
    _ = try graph.addEdgeUnchecked(start, .depends_on, middle);
    _ = try graph.addEdgeUnchecked(middle, .depends_on, target);

    var ops = std.ArrayList(optimizer.PhysicalOp).empty;
    defer ops.deinit(std.testing.allocator);
    try ops.append(std.testing.allocator, .{ .node_lookup_by_text = .{ .var_name = "s", .kind = .task, .text = "start" } });
    try ops.append(std.testing.allocator, .{
        .expand = .{
            .left_var = "s",
            .rel = .depends_on,
            .right_var = "t",
            .right_kind = .task,
            .right_text_eq = "target",
            .min_hops = 2,
            .max_hops = 2,
        },
    });

    var table = try execute(std.testing.allocator, &graph, .{ .ops = ops });
    defer table.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), table.rows.items.len);
    try std.testing.expectEqual(target.toInt(), table.rows.items[0].get("t").?.toInt());
}

test "executor skips expand path binding when projection does not need it" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    const a = try graph.addNode(.task, "a");
    const b = try graph.addNode(.task, "b");
    _ = try graph.addEdgeUnchecked(a, .depends_on, b);

    const projections = [_]ast.Projection{.{ .variable = "t" }};
    var ops = std.ArrayList(optimizer.PhysicalOp).empty;
    defer ops.deinit(std.testing.allocator);
    try ops.append(std.testing.allocator, .{ .node_lookup_by_text = .{ .var_name = "a", .kind = .task, .text = "a" } });
    try ops.append(std.testing.allocator, .{ .expand = .{ .left_var = "a", .rel = .depends_on, .right_var = "t", .right_kind = .task } });
    try ops.append(std.testing.allocator, .{ .project = projections[0..] });

    var table = try execute(std.testing.allocator, &graph, .{ .ops = ops });
    defer table.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), table.rows.items.len);
    try std.testing.expectEqual(b.toInt(), table.rows.items[0].get("t").?.toInt());
    try std.testing.expect(table.rows.items[0].getPath("a", "t") == null);
}

test "executor keeps expand path binding when projection needs it" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    const a = try graph.addNode(.task, "a");
    const b = try graph.addNode(.task, "b");
    _ = try graph.addEdgeUnchecked(a, .depends_on, b);

    const projections = [_]ast.Projection{.{ .path = .{ .from_var = "a", .to_var = "t" } }};
    var ops = std.ArrayList(optimizer.PhysicalOp).empty;
    defer ops.deinit(std.testing.allocator);
    try ops.append(std.testing.allocator, .{ .node_lookup_by_text = .{ .var_name = "a", .kind = .task, .text = "a" } });
    try ops.append(std.testing.allocator, .{ .expand = .{ .left_var = "a", .rel = .depends_on, .right_var = "t", .right_kind = .task } });
    try ops.append(std.testing.allocator, .{ .project = projections[0..] });

    var table = try execute(std.testing.allocator, &graph, .{ .ops = ops });
    defer table.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), table.rows.items.len);
    const path = table.rows.items[0].getPath("a", "t").?;
    try std.testing.expectEqual(@as(usize, 2), path.len);
    try std.testing.expectEqual(a.toInt(), path[0].toInt());
    try std.testing.expectEqual(b.toInt(), path[1].toInt());
}

test "executor drops text score binding when projection does not need it across expand" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    const file = try graph.addNode(.file, "source file");
    const func = try graph.addNode(.function, "target");
    _ = try graph.addEdgeUnchecked(file, .defines, func);

    const projections = [_]ast.Projection{.{ .variable = "t" }};
    var ops = std.ArrayList(optimizer.PhysicalOp).empty;
    defer ops.deinit(std.testing.allocator);
    try ops.append(std.testing.allocator, .{ .text_search = .{ .var_name = "o", .query = "source", .kind = .file } });
    try ops.append(std.testing.allocator, .{ .expand = .{ .left_var = "o", .rel = .defines, .right_var = "t", .right_kind = .function } });
    try ops.append(std.testing.allocator, .{ .project = projections[0..] });

    var table = try execute(std.testing.allocator, &graph, .{ .ops = ops });
    defer table.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), table.rows.items.len);
    try std.testing.expectEqual(func.toInt(), table.rows.items[0].get("t").?.toInt());
    try std.testing.expect(table.rows.items[0].getScore("o") == null);
}

test "executor keeps text score binding when projection needs it across expand" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    const file = try graph.addNode(.file, "source file");
    const func = try graph.addNode(.function, "target");
    _ = try graph.addEdgeUnchecked(file, .defines, func);

    const projections = [_]ast.Projection{ .{ .variable = "t" }, .{ .score = .{ .var_name = "o" } } };
    var ops = std.ArrayList(optimizer.PhysicalOp).empty;
    defer ops.deinit(std.testing.allocator);
    try ops.append(std.testing.allocator, .{ .text_search = .{ .var_name = "o", .query = "source", .kind = .file } });
    try ops.append(std.testing.allocator, .{ .expand = .{ .left_var = "o", .rel = .defines, .right_var = "t", .right_kind = .function } });
    try ops.append(std.testing.allocator, .{ .project = projections[0..] });

    var table = try execute(std.testing.allocator, &graph, .{ .ops = ops });
    defer table.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), table.rows.items.len);
    try std.testing.expectEqual(func.toInt(), table.rows.items[0].get("t").?.toInt());
    try std.testing.expect(table.rows.items[0].getScore("o") != null);
}

test "executor does not push limit before expand scan candidates" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    const first_file = try graph.addNode(.file, "a.zig");
    const second_file = try graph.addNode(.file, "b.zig");
    const other = try graph.addNode(.function, "other");
    const target = try graph.addNode(.function, "target");
    _ = try graph.addEdgeUnchecked(first_file, .defines, other);
    _ = try graph.addEdgeUnchecked(second_file, .defines, target);

    var ops = std.ArrayList(optimizer.PhysicalOp).empty;
    defer ops.deinit(std.testing.allocator);
    try ops.append(std.testing.allocator, .{ .node_scan = .{ .var_name = "f", .kind = .file } });
    try ops.append(std.testing.allocator, .{ .expand = .{
        .left_var = "f",
        .rel = .defines,
        .right_var = "s",
        .right_kind = .function,
        .right_text_eq = "target",
    } });
    try ops.append(std.testing.allocator, .{ .limit = 1 });

    var table = try execute(std.testing.allocator, &graph, .{ .ops = ops });
    defer table.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), table.rows.items.len);
    try std.testing.expectEqual(second_file.toInt(), table.rows.items[0].get("f").?.toInt());
}

test "executor does not push limit before duplicate-text lookup expansion" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    const first_file = try graph.addNode(.file, "shared.zig");
    const second_file = try graph.addNode(.file, "shared.zig");
    const other = try graph.addNode(.function, "other");
    const target = try graph.addNode(.function, "target");
    _ = try graph.addEdgeUnchecked(first_file, .defines, other);
    _ = try graph.addEdgeUnchecked(second_file, .defines, target);

    var ops = std.ArrayList(optimizer.PhysicalOp).empty;
    defer ops.deinit(std.testing.allocator);
    try ops.append(std.testing.allocator, .{ .node_lookup_by_text = .{ .var_name = "f", .kind = .file, .text = "shared.zig" } });
    try ops.append(std.testing.allocator, .{ .expand = .{
        .left_var = "f",
        .rel = .defines,
        .right_var = "s",
        .right_kind = .function,
        .right_text_eq = "target",
    } });
    try ops.append(std.testing.allocator, .{ .limit = 1 });

    var table = try execute(std.testing.allocator, &graph, .{ .ops = ops });
    defer table.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), table.rows.items.len);
    try std.testing.expectEqual(second_file.toInt(), table.rows.items[0].get("f").?.toInt());
}

test "executor marks visited node budget truncation for scan candidates" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    _ = try graph.addNode(.file, "a.zig");
    _ = try graph.addNode(.file, "b.zig");

    var ops = std.ArrayList(optimizer.PhysicalOp).empty;
    defer ops.deinit(std.testing.allocator);
    try ops.append(std.testing.allocator, .{ .node_scan = .{ .var_name = "f", .kind = .file } });

    var table = try executeWithBudget(std.testing.allocator, &graph, .{ .ops = ops }, .{ .max_visited_nodes = 1 });
    defer table.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), table.rows.items.len);
    try std.testing.expectEqual(@as(usize, 1), table.stats.nodes_visited);
    try std.testing.expect(table.stats.budget_exceeded);
}

test "executor marks visited node budget truncation for exact-text lookup candidates" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    _ = try graph.addNode(.file, "shared.zig");
    _ = try graph.addNode(.file, "shared.zig");

    var ops = std.ArrayList(optimizer.PhysicalOp).empty;
    defer ops.deinit(std.testing.allocator);
    try ops.append(std.testing.allocator, .{ .node_lookup_by_text = .{ .var_name = "f", .kind = .file, .text = "shared.zig" } });

    var table = try executeWithBudget(std.testing.allocator, &graph, .{ .ops = ops }, .{ .max_visited_nodes = 1 });
    defer table.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), table.rows.items.len);
    try std.testing.expectEqual(@as(usize, 1), table.stats.nodes_visited);
    try std.testing.expect(table.stats.budget_exceeded);
}

test "executor result limit does not report budget truncation for scan candidates" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    _ = try graph.addNode(.file, "a.zig");
    _ = try graph.addNode(.file, "b.zig");

    var ops = std.ArrayList(optimizer.PhysicalOp).empty;
    defer ops.deinit(std.testing.allocator);
    try ops.append(std.testing.allocator, .{ .node_scan = .{ .var_name = "f", .kind = .file } });

    var table = try executeWithBudget(std.testing.allocator, &graph, .{ .ops = ops }, .{ .max_results = 1 });
    defer table.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), table.rows.items.len);
    try std.testing.expectEqual(@as(usize, 1), table.stats.nodes_visited);
    try std.testing.expect(!table.stats.budget_exceeded);
}

test "executor node scan hides non-active graph nodes" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    const active = try graph.addNode(.file, "active.zig");
    const stale = try graph.addNode(.file, "stale.zig");
    for (graph.nodes.items) |*node| {
        if (node.id == stale) node.status = .stale;
    }

    var ops = std.ArrayList(optimizer.PhysicalOp).empty;
    defer ops.deinit(std.testing.allocator);
    try ops.append(std.testing.allocator, .{ .node_scan = .{ .var_name = "f", .kind = .file } });

    var table = try execute(std.testing.allocator, &graph, .{ .ops = ops });
    defer table.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), table.rows.items.len);
    try std.testing.expectEqual(active.toInt(), table.rows.items[0].get("f").?.toInt());
}

test "executor applies node scan text predicate before result limit" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    _ = try graph.addNode(.file, "noise.zig");
    const target = try graph.addNode(.file, "target.zig");

    var ops = std.ArrayList(optimizer.PhysicalOp).empty;
    defer ops.deinit(std.testing.allocator);
    try ops.append(std.testing.allocator, .{ .node_scan = .{
        .var_name = "f",
        .kind = .file,
        .text_eq = "target.zig",
    } });
    try ops.append(std.testing.allocator, .{ .limit = 1 });

    var table = try execute(std.testing.allocator, &graph, .{ .ops = ops });
    defer table.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), table.rows.items.len);
    try std.testing.expectEqual(target.toInt(), table.rows.items[0].get("f").?.toInt());
    try std.testing.expectEqual(@as(usize, 2), table.stats.nodes_visited);
}

test "executor marks scan text predicate candidate truncation" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    _ = try graph.addNode(.file, "noise.zig");
    _ = try graph.addNode(.file, "target.zig");

    var ops = std.ArrayList(optimizer.PhysicalOp).empty;
    defer ops.deinit(std.testing.allocator);
    try ops.append(std.testing.allocator, .{ .node_scan = .{
        .var_name = "f",
        .kind = .file,
        .text_eq = "target.zig",
    } });
    try ops.append(std.testing.allocator, .{ .limit = 1 });

    var table = try executeWithBudget(std.testing.allocator, &graph, .{ .ops = ops }, .{ .max_visited_nodes = 1 });
    defer table.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), table.rows.items.len);
    try std.testing.expectEqual(@as(usize, 1), table.stats.nodes_visited);
    try std.testing.expect(table.stats.budget_exceeded);
}

test "executor limit keeps result stats in sync" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    _ = try graph.addNode(.file, "a.zig");
    _ = try graph.addNode(.file, "b.zig");

    var ops = std.ArrayList(optimizer.PhysicalOp).empty;
    defer ops.deinit(std.testing.allocator);
    try ops.append(std.testing.allocator, .{ .node_scan = .{ .var_name = "f", .kind = .file } });
    try ops.append(std.testing.allocator, .{ .limit = 1 });

    var table = try execute(std.testing.allocator, &graph, .{ .ops = ops });
    defer table.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), table.rows.items.len);
    try std.testing.expectEqual(@as(usize, 1), table.stats.results);
}

test "executor limit zero returns without scanning expand candidates" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    const file = try graph.addNode(.file, "a.zig");
    const func = try graph.addNode(.function, "main");
    _ = try graph.addEdgeUnchecked(file, .defines, func);

    var ops = std.ArrayList(optimizer.PhysicalOp).empty;
    defer ops.deinit(std.testing.allocator);
    try ops.append(std.testing.allocator, .{ .node_scan = .{ .var_name = "f", .kind = .file } });
    try ops.append(std.testing.allocator, .{ .expand = .{ .left_var = "f", .rel = .defines, .right_var = "s", .right_kind = .function } });
    try ops.append(std.testing.allocator, .{ .limit = 0 });

    var table = try execute(std.testing.allocator, &graph, .{ .ops = ops });
    defer table.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), table.rows.items.len);
    try std.testing.expectEqual(@as(usize, 0), table.stats.results);
    try std.testing.expectEqual(@as(usize, 0), table.stats.nodes_visited);
    try std.testing.expectEqual(@as(usize, 0), table.stats.edges_visited);
    try std.testing.expect(!table.stats.budget_exceeded);
}

test "executor immediate timeout returns before scanning candidates" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    _ = try graph.addNode(.file, "a.zig");
    _ = try graph.addNode(.file, "b.zig");

    var mem_index = try index.MemoryIndex.init(std.testing.allocator, &graph);
    defer mem_index.deinit();

    var ops = std.ArrayList(optimizer.PhysicalOp).empty;
    defer ops.deinit(std.testing.allocator);
    try ops.append(std.testing.allocator, .{ .node_scan = .{ .var_name = "f", .kind = .file } });

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var table = try executeWithIndex(failing.allocator(), &graph, &mem_index, .{ .ops = ops }, .{ .timeout_ms = 0 });
    defer table.deinit(failing.allocator());
    try std.testing.expectEqual(@as(usize, 0), table.rows.items.len);
    try std.testing.expectEqual(@as(usize, 0), table.stats.nodes_visited);
    try std.testing.expectEqual(@as(usize, 0), table.stats.edges_visited);
    try std.testing.expect(table.stats.budget_exceeded);
}

test "executor exhausted node budget returns before scanning candidates" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    _ = try graph.addNode(.file, "a.zig");
    _ = try graph.addNode(.file, "b.zig");

    var mem_index = try index.MemoryIndex.init(std.testing.allocator, &graph);
    defer mem_index.deinit();

    var ops = std.ArrayList(optimizer.PhysicalOp).empty;
    defer ops.deinit(std.testing.allocator);
    try ops.append(std.testing.allocator, .{ .node_scan = .{ .var_name = "f", .kind = .file } });

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var table = try executeWithIndex(failing.allocator(), &graph, &mem_index, .{ .ops = ops }, .{ .max_visited_nodes = 0 });
    defer table.deinit(failing.allocator());
    try std.testing.expectEqual(@as(usize, 0), table.rows.items.len);
    try std.testing.expectEqual(@as(usize, 0), table.stats.nodes_visited);
    try std.testing.expectEqual(@as(usize, 0), table.stats.edges_visited);
    try std.testing.expect(table.stats.budget_exceeded);
}

test "executor expand stops outer rows once limit is reached" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    const first_file = try graph.addNode(.file, "a.zig");
    const second_file = try graph.addNode(.file, "b.zig");
    const first_func = try graph.addNode(.function, "a");
    const second_func = try graph.addNode(.function, "b");
    _ = try graph.addEdgeUnchecked(first_file, .defines, first_func);
    _ = try graph.addEdgeUnchecked(second_file, .defines, second_func);

    var ops = std.ArrayList(optimizer.PhysicalOp).empty;
    defer ops.deinit(std.testing.allocator);
    try ops.append(std.testing.allocator, .{ .node_scan = .{ .var_name = "f", .kind = .file } });
    try ops.append(std.testing.allocator, .{ .expand = .{
        .left_var = "f",
        .rel = .defines,
        .right_var = "s",
        .right_kind = .function,
    } });
    try ops.append(std.testing.allocator, .{ .limit = 1 });

    var table = try execute(std.testing.allocator, &graph, .{ .ops = ops });
    defer table.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), table.rows.items.len);
    try std.testing.expectEqual(@as(usize, 1), table.stats.edges_visited);
    try std.testing.expectEqual(first_func.toInt(), table.rows.items[0].get("s").?.toInt());
}

test "executor undirected self loop returns one binding" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    const concept = try graph.addNode(.concept, "self");
    _ = try graph.addEdgeUnchecked(concept, .related_to, concept);

    var ops = std.ArrayList(optimizer.PhysicalOp).empty;
    defer ops.deinit(std.testing.allocator);
    try ops.append(std.testing.allocator, .{ .node_lookup_by_text = .{ .var_name = "a", .kind = .concept, .text = "self" } });
    try ops.append(std.testing.allocator, .{ .expand = .{
        .left_var = "a",
        .rel = .related_to,
        .direction = .undirected,
        .right_var = "b",
        .right_kind = .concept,
    } });

    var table = try execute(std.testing.allocator, &graph, .{ .ops = ops });
    defer table.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), table.rows.items.len);
    try std.testing.expectEqual(concept.toInt(), table.rows.items[0].get("b").?.toInt());
}

fn executorScanAllocationFailure(allocator: std.mem.Allocator) !void {
    var graph = graph_mod.Graph.init(allocator);
    defer graph.deinit();
    _ = try graph.addNode(.file, "a.zig");

    var ops = std.ArrayList(optimizer.PhysicalOp).empty;
    defer ops.deinit(allocator);
    try ops.append(allocator, .{ .node_scan = .{ .var_name = "f", .kind = .file } });

    var table = try execute(allocator, &graph, .{ .ops = ops });
    defer table.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), table.rows.items.len);
}

test "executor scan rolls back allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, executorScanAllocationFailure, .{});
}

fn executorExpandPathAllocationFailure(allocator: std.mem.Allocator) !void {
    var graph = graph_mod.Graph.init(allocator);
    defer graph.deinit();
    const file = try graph.addNode(.file, "a.zig");
    const func = try graph.addNode(.function, "main");
    _ = try graph.addEdgeUnchecked(file, .defines, func);

    var ops = std.ArrayList(optimizer.PhysicalOp).empty;
    defer ops.deinit(allocator);
    try ops.append(allocator, .{ .node_lookup_by_text = .{ .var_name = "f", .kind = .file, .text = "a.zig" } });
    try ops.append(allocator, .{ .expand = .{
        .left_var = "f",
        .rel = .defines,
        .right_var = "s",
        .right_kind = .function,
    } });

    var table = try execute(allocator, &graph, .{ .ops = ops });
    defer table.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), table.rows.items.len);
}

test "executor expand rolls back allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, executorExpandPathAllocationFailure, .{});
}

fn executorExpandFrontierAllocationFailure(allocator: std.mem.Allocator) !void {
    var graph = graph_mod.Graph.init(allocator);
    defer graph.deinit();
    const a = try graph.addNode(.task, "a");
    const b = try graph.addNode(.task, "b");
    const c = try graph.addNode(.task, "c");
    _ = try graph.addEdgeUnchecked(a, .depends_on, b);
    _ = try graph.addEdgeUnchecked(b, .depends_on, c);

    var ops = std.ArrayList(optimizer.PhysicalOp).empty;
    defer ops.deinit(allocator);
    try ops.append(allocator, .{ .node_lookup_by_text = .{ .var_name = "a", .kind = .task, .text = "a" } });
    try ops.append(allocator, .{ .expand = .{
        .left_var = "a",
        .rel = .depends_on,
        .right_var = "t",
        .right_kind = .task,
        .min_hops = 2,
        .max_hops = 2,
    } });

    var table = try execute(allocator, &graph, .{ .ops = ops });
    defer table.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), table.rows.items.len);
}

test "executor expand frontier rolls back allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, executorExpandFrontierAllocationFailure, .{});
}

test "executor expand rejects min hops beyond max depth budget" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    const a = try graph.addNode(.task, "a");
    const b = try graph.addNode(.task, "b");
    _ = try graph.addEdgeUnchecked(a, .depends_on, b);

    var ops = std.ArrayList(optimizer.PhysicalOp).empty;
    defer ops.deinit(std.testing.allocator);
    try ops.append(std.testing.allocator, .{ .node_lookup_by_text = .{ .var_name = "a", .kind = .task, .text = "a" } });
    try ops.append(std.testing.allocator, .{ .expand = .{ .left_var = "a", .rel = .depends_on, .right_var = "t", .right_kind = .task, .min_hops = 2, .max_hops = 2 } });

    var table = try executeWithBudget(std.testing.allocator, &graph, .{ .ops = ops }, .{ .max_depth = 1 });
    defer table.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), table.rows.items.len);
    try std.testing.expect(table.stats.budget_exceeded);
    try std.testing.expectEqual(@as(usize, 0), table.stats.edges_visited);
}

test "executor classifies missing persistent candidates as invalid records" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    var mem_index = try index.MemoryIndex.init(std.testing.allocator, &graph);
    defer mem_index.deinit();

    try missingCandidateNode(.{ .memory = .{ .graph = &graph, .mem_index = &mem_index } });

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    try std.testing.expectError(
        error.InvalidRecord,
        missingCandidateNode(.{ .store = .{ .allocator = std.testing.allocator, .store = store } }),
    );
}

test "executor node scan accepts schema descendant type filter" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    const human_kind: core.NodeKind = @enumFromInt(100);
    const man_kind: core.NodeKind = @enumFromInt(101);
    const woman_kind: core.NodeKind = @enumFromInt(102);
    const human = try graph.addNode(human_kind, "human");
    const man = try graph.addNode(man_kind, "man");
    const woman = try graph.addNode(woman_kind, "woman");
    _ = try graph.addNode(.task, "task");

    var type_set = schema.NodeTypeSet.empty();
    try type_set.insert(100);
    try type_set.insert(101);
    try type_set.insert(102);

    var ops = std.ArrayList(optimizer.PhysicalOp).empty;
    defer ops.deinit(std.testing.allocator);
    try ops.append(std.testing.allocator, .{ .node_scan = .{
        .var_name = "n",
        .kind = null,
        .type_filter = schema.NodeTypeFilter.fromDescendants(type_set),
    } });

    var table = try execute(std.testing.allocator, &graph, .{ .ops = ops });
    defer table.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), table.rows.items.len);
    try std.testing.expectEqual(human.toInt(), table.rows.items[0].get("n").?.toInt());
    try std.testing.expectEqual(man.toInt(), table.rows.items[1].get("n").?.toInt());
    try std.testing.expectEqual(woman.toInt(), table.rows.items[2].get("n").?.toInt());
}

test "executor expand accepts schema descendant right type filter" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    const person_kind: core.NodeKind = @enumFromInt(100);
    const man_kind: core.NodeKind = @enumFromInt(101);
    const woman_kind: core.NodeKind = @enumFromInt(102);
    const root = try graph.addNode(.concept, "root");
    const man = try graph.addNode(man_kind, "man");
    const woman = try graph.addNode(woman_kind, "woman");
    const task = try graph.addNode(.task, "task");
    _ = try graph.addEdgeUnchecked(root, .mentions, man);
    _ = try graph.addEdgeUnchecked(root, .mentions, woman);
    _ = try graph.addEdgeUnchecked(root, .mentions, task);

    var type_set = schema.NodeTypeSet.empty();
    try type_set.insert(@intFromEnum(person_kind));
    try type_set.insert(@intFromEnum(man_kind));
    try type_set.insert(@intFromEnum(woman_kind));

    var ops = std.ArrayList(optimizer.PhysicalOp).empty;
    defer ops.deinit(std.testing.allocator);
    try ops.append(std.testing.allocator, .{ .node_lookup_by_text = .{ .var_name = "r", .kind = .concept, .text = "root" } });
    try ops.append(std.testing.allocator, .{ .expand = .{
        .left_var = "r",
        .rel = .mentions,
        .right_var = "p",
        .right_kind = null,
        .right_type_filter = schema.NodeTypeFilter.fromDescendants(type_set),
    } });

    var table = try execute(std.testing.allocator, &graph, .{ .ops = ops });
    defer table.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), table.rows.items.len);
    try std.testing.expectEqual(man.toInt(), table.rows.items[0].get("p").?.toInt());
    try std.testing.expectEqual(woman.toInt(), table.rows.items[1].get("p").?.toInt());
}

test "executor expand accepts schema descendant relation type filter" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    const supports_rel: core.RelKind = @enumFromInt(100);
    const proves_rel: core.RelKind = @enumFromInt(101);
    const root = try graph.addNode(.concept, "root");
    const evidence = try graph.addNode(.evidence, "evidence");
    const verification = try graph.addNode(.verification, "verification");
    const task = try graph.addNode(.task, "task");
    _ = try graph.addEdgeUnchecked(root, supports_rel, evidence);
    _ = try graph.addEdgeUnchecked(root, proves_rel, verification);
    _ = try graph.addEdgeUnchecked(root, .mentions, task);

    var rel_set = schema.RelationTypeSet.empty();
    try rel_set.insert(@intFromEnum(supports_rel));
    try rel_set.insert(@intFromEnum(proves_rel));

    var ops = std.ArrayList(optimizer.PhysicalOp).empty;
    defer ops.deinit(std.testing.allocator);
    try ops.append(std.testing.allocator, .{ .node_lookup_by_text = .{ .var_name = "r", .kind = .concept, .text = "root" } });
    try ops.append(std.testing.allocator, .{ .expand = .{
        .left_var = "r",
        .rel = null,
        .rel_filter = schema.RelationTypeFilter.fromDescendants(rel_set),
        .right_var = "n",
        .right_kind = null,
    } });

    var table = try execute(std.testing.allocator, &graph, .{ .ops = ops });
    defer table.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), table.rows.items.len);
    try std.testing.expectEqual(evidence.toInt(), table.rows.items[0].get("n").?.toInt());
    try std.testing.expectEqual(verification.toInt(), table.rows.items[1].get("n").?.toInt());
}
