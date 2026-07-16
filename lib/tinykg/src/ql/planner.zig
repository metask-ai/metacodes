const std = @import("std");
const core = @import("../core.zig");
const schema = @import("../schema.zig");
const ast = @import("ast.zig");

pub const ScanNodes = struct {
    var_name: []const u8,
    kind: ?core.NodeKind,
    type_filter: schema.NodeTypeFilter = .any,
    text_eq: ?[]const u8 = null,
    property_eq: ?PropertyPredicate = null,
};

pub const PropertyPredicate = struct {
    key: []const u8,
    op: ast.PredicateOperator = .eq,
    value: []const u8,
    uint_range: ?UintRangePredicate = null,
};

pub const UintRangePredicate = struct {
    min_value: ?[]const u8 = null,
    min_inclusive: bool = true,
    max_value: ?[]const u8 = null,
    max_inclusive: bool = true,
};

pub const Expand = struct {
    left_var: []const u8,
    edge_var: ?[]const u8 = null,
    edge_property_eq: ?PropertyPredicate = null,
    rel: ?core.RelKind,
    rel_filter: schema.RelationTypeFilter = .any,
    direction: ast.EdgeDirection = .outgoing,
    right_var: []const u8,
    right_kind: ?core.NodeKind,
    right_type_filter: schema.NodeTypeFilter = .any,
    right_text_eq: ?[]const u8 = null,
    min_hops: u8 = 1,
    max_hops: u8 = 1,
};

pub const TextSearch = struct {
    var_name: []const u8,
    query: []const u8,
    kind: ?core.NodeKind,
    type_filter: schema.NodeTypeFilter = .any,
    text_eq: ?[]const u8 = null,
    limit: ?usize = null,
};

pub const LogicalOp = union(enum) {
    text_search: TextSearch,
    scan_nodes: ScanNodes,
    expand: Expand,
    order_by: ast.OrderBy,
    project: []const ast.Projection,
    limit: usize,
};

pub const LogicalPlan = struct {
    ops: std.ArrayList(LogicalOp),
    owned_strings: std.ArrayList([]u8) = .empty,
    owned_projection_slices: std.ArrayList([]ast.Projection) = .empty,

    pub fn deinit(self: *LogicalPlan, allocator: std.mem.Allocator) void {
        for (self.owned_projection_slices.items) |projections| allocator.free(projections);
        self.owned_projection_slices.deinit(allocator);
        for (self.owned_strings.items) |string| allocator.free(string);
        self.owned_strings.deinit(allocator);
        self.ops.deinit(allocator);
    }
};

pub fn plan(allocator: std.mem.Allocator, query: ast.Query) !LogicalPlan {
    return planWithOptionalSchema(allocator, query, null);
}

pub fn planWithSchema(allocator: std.mem.Allocator, query: ast.Query, registry: schema.Registry) !LogicalPlan {
    return planWithOptionalSchema(allocator, query, registry);
}

fn planWithOptionalSchema(allocator: std.mem.Allocator, query: ast.Query, registry: ?schema.Registry) !LogicalPlan {
    var out = LogicalPlan{ .ops = .empty };
    errdefer out.deinit(allocator);
    if (query.text_pattern) |text_pattern| {
        const text_kind = text_pattern.kind orelse query.pattern.start.kind;
        const text_label = text_pattern.type_label orelse query.pattern.start.type_label;
        try out.ops.append(allocator, .{ .text_search = .{
            .var_name = try ownString(allocator, &out, text_pattern.var_name),
            .query = try ownString(allocator, &out, text_pattern.query),
            .kind = text_kind,
            .type_filter = try nodeTypeFilter(registry, text_kind, text_label),
            .text_eq = try maybeOwnString(allocator, &out, textPredicateFor(query, text_pattern.var_name)),
            .limit = if (query.pattern.segments.len == 0) query.limit else null,
        } });
        var left = query.pattern.start;
        for (query.pattern.segments) |segment| {
            try out.ops.append(allocator, .{ .expand = .{
                .left_var = try ownString(allocator, &out, left.var_name),
                .edge_var = try maybeOwnString(allocator, &out, segment.edge.var_name),
                .edge_property_eq = try maybeOwnPropertyPredicate(allocator, &out, propertyPredicateFor(query, segment.edge.var_name orelse "")),
                .rel = segment.edge.rel,
                .rel_filter = try relationTypeFilter(registry, segment.edge.rel, segment.edge.rel_label),
                .direction = segment.edge.direction,
                .right_var = try ownString(allocator, &out, segment.right.var_name),
                .right_kind = segment.right.kind,
                .right_type_filter = try nodeTypeFilter(registry, segment.right.kind, segment.right.type_label),
                .right_text_eq = try maybeOwnString(allocator, &out, textPredicateFor(query, segment.right.var_name)),
                .min_hops = segment.edge.min_hops,
                .max_hops = segment.edge.max_hops,
            } });
            left = segment.right;
        }
    } else {
        try out.ops.append(allocator, .{ .scan_nodes = .{
            .var_name = try ownString(allocator, &out, query.pattern.start.var_name),
            .kind = query.pattern.start.kind,
            .type_filter = try nodeTypeFilter(registry, query.pattern.start.kind, query.pattern.start.type_label),
            .text_eq = try maybeOwnString(allocator, &out, textPredicateFor(query, query.pattern.start.var_name)),
            .property_eq = try maybeOwnPropertyPredicate(allocator, &out, propertyPredicateFor(query, query.pattern.start.var_name)),
        } });

        var left = query.pattern.start;
        for (query.pattern.segments) |segment| {
            try out.ops.append(allocator, .{ .expand = .{
                .left_var = try ownString(allocator, &out, left.var_name),
                .edge_var = try maybeOwnString(allocator, &out, segment.edge.var_name),
                .edge_property_eq = try maybeOwnPropertyPredicate(allocator, &out, propertyPredicateFor(query, segment.edge.var_name orelse "")),
                .rel = segment.edge.rel,
                .rel_filter = try relationTypeFilter(registry, segment.edge.rel, segment.edge.rel_label),
                .direction = segment.edge.direction,
                .right_var = try ownString(allocator, &out, segment.right.var_name),
                .right_kind = segment.right.kind,
                .right_type_filter = try nodeTypeFilter(registry, segment.right.kind, segment.right.type_label),
                .right_text_eq = try maybeOwnString(allocator, &out, textPredicateFor(query, segment.right.var_name)),
                .min_hops = segment.edge.min_hops,
                .max_hops = segment.edge.max_hops,
            } });
            left = segment.right;
        }
    }
    if (query.order_by) |order_by| try out.ops.append(allocator, .{ .order_by = try cloneOrderBy(allocator, &out, order_by) });
    try out.ops.append(allocator, .{ .project = try cloneProjections(allocator, &out, query.returns) });
    if (query.limit) |limit| try out.ops.append(allocator, .{ .limit = limit });
    return out;
}

fn nodeTypeFilter(registry: ?schema.Registry, kind: ?core.NodeKind, label: ?[]const u8) !schema.NodeTypeFilter {
    if (label) |name| {
        if (registry) |resolved| return try resolved.resolveNodeFilter(name);
        if (kind == null) return error.UnknownNodeKind;
    }
    return schema.NodeTypeFilter.fromOptionalKind(kind);
}

fn relationTypeFilter(registry: ?schema.Registry, rel: ?core.RelKind, label: ?[]const u8) !schema.RelationTypeFilter {
    if (label) |name| {
        if (registry) |resolved| return try resolved.resolveRelationFilter(name);
        if (rel == null) return error.UnknownRelationKind;
    }
    return schema.RelationTypeFilter.fromOptionalRel(rel);
}

fn textPredicateFor(query: ast.Query, var_name: []const u8) ?[]const u8 {
    for (query.where_predicates) |predicate| {
        if (!std.mem.eql(u8, predicate.var_name, var_name)) continue;
        if (!std.mem.eql(u8, predicate.property, "text")) continue;
        return predicate.value;
    }
    return null;
}

fn propertyPredicateFor(query: ast.Query, var_name: []const u8) ?PropertyPredicate {
    var out: ?PropertyPredicate = null;
    for (query.where_predicates) |predicate| {
        if (!std.mem.eql(u8, predicate.var_name, var_name)) continue;
        if (std.mem.eql(u8, predicate.property, "text")) continue;
        if (out == null) {
            out = .{
                .key = predicate.property,
                .op = predicate.op,
                .value = predicate.value,
                .uint_range = uintRangeFromPredicate(predicate),
            };
            continue;
        }
        if (out.?.uint_range) |range| {
            var merged = range;
            mergeUintRangePredicate(&merged, predicate);
            out.?.uint_range = merged;
            continue;
        }
        return out;
    }
    return out;
}

fn uintRangeFromPredicate(predicate: ast.Predicate) ?UintRangePredicate {
    return switch (predicate.op) {
        .eq => null,
        .lt => .{ .max_value = predicate.value, .max_inclusive = false },
        .lte => .{ .max_value = predicate.value, .max_inclusive = true },
        .gt => .{ .min_value = predicate.value, .min_inclusive = false },
        .gte => .{ .min_value = predicate.value, .min_inclusive = true },
    };
}

fn mergeUintRangePredicate(range: *UintRangePredicate, predicate: ast.Predicate) void {
    switch (predicate.op) {
        .eq => {},
        .lt => {
            range.max_value = predicate.value;
            range.max_inclusive = false;
        },
        .lte => {
            range.max_value = predicate.value;
            range.max_inclusive = true;
        },
        .gt => {
            range.min_value = predicate.value;
            range.min_inclusive = false;
        },
        .gte => {
            range.min_value = predicate.value;
            range.min_inclusive = true;
        },
    }
}

fn cloneUintRangePredicate(allocator: std.mem.Allocator, plan_out: *LogicalPlan, value: ?UintRangePredicate) !?UintRangePredicate {
    return if (value) |range| .{
        .min_value = try maybeOwnString(allocator, plan_out, range.min_value),
        .min_inclusive = range.min_inclusive,
        .max_value = try maybeOwnString(allocator, plan_out, range.max_value),
        .max_inclusive = range.max_inclusive,
    } else null;
}

fn ownString(allocator: std.mem.Allocator, plan_out: *LogicalPlan, value: []const u8) ![]const u8 {
    const owned = try allocator.dupe(u8, value);
    errdefer allocator.free(owned);
    try plan_out.owned_strings.append(allocator, owned);
    return owned;
}

fn maybeOwnString(allocator: std.mem.Allocator, plan_out: *LogicalPlan, value: ?[]const u8) !?[]const u8 {
    return if (value) |text| try ownString(allocator, plan_out, text) else null;
}

fn maybeOwnPropertyPredicate(allocator: std.mem.Allocator, plan_out: *LogicalPlan, value: ?PropertyPredicate) !?PropertyPredicate {
    return if (value) |predicate| .{
        .key = try ownString(allocator, plan_out, predicate.key),
        .op = predicate.op,
        .value = try ownString(allocator, plan_out, predicate.value),
        .uint_range = try cloneUintRangePredicate(allocator, plan_out, predicate.uint_range),
    } else null;
}

fn cloneOrderBy(allocator: std.mem.Allocator, plan_out: *LogicalPlan, order_by: ast.OrderBy) !ast.OrderBy {
    return .{
        .var_name = try ownString(allocator, plan_out, order_by.var_name),
        .property = try ownString(allocator, plan_out, order_by.property),
        .direction = order_by.direction,
    };
}

fn cloneProjections(allocator: std.mem.Allocator, plan_out: *LogicalPlan, projections: []const ast.Projection) ![]ast.Projection {
    const owned = try allocator.alloc(ast.Projection, projections.len);
    errdefer allocator.free(owned);
    for (projections, 0..) |projection, i| {
        owned[i] = try cloneProjection(allocator, plan_out, projection);
    }
    try plan_out.owned_projection_slices.append(allocator, owned);
    return owned;
}

fn cloneProjection(allocator: std.mem.Allocator, plan_out: *LogicalPlan, projection: ast.Projection) !ast.Projection {
    return switch (projection) {
        .variable => |var_name| .{ .variable = try ownString(allocator, plan_out, var_name) },
        .property => |property| .{ .property = .{
            .var_name = try ownString(allocator, plan_out, property.var_name),
            .property = try ownString(allocator, plan_out, property.property),
        } },
        .path => |path| .{ .path = .{
            .from_var = try ownString(allocator, plan_out, path.from_var),
            .to_var = try ownString(allocator, plan_out, path.to_var),
        } },
        .reachable => |reachable| .{ .reachable = .{
            .from_var = try ownString(allocator, plan_out, reachable.from_var),
            .to_var = try ownString(allocator, plan_out, reachable.to_var),
            .rel = reachable.rel,
        } },
        .context => |context| .{ .context = .{ .var_name = try ownString(allocator, plan_out, context.var_name) } },
        .score => |score| .{ .score = .{ .var_name = try ownString(allocator, plan_out, score.var_name) } },
    };
}

test "planner uses text predicate as scan binding" {
    const returns = [_]ast.Projection{.{ .variable = "n" }};
    const query = ast.Query{
        .pattern = .{ .start = .{ .var_name = "n", .kind = .file }, .segments = &.{} },
        .where_predicates = &.{.{ .var_name = "n", .property = "text", .value = "a.zig" }},
        .returns = &returns,
    };
    var logical = try plan(std.testing.allocator, query);
    defer logical.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("a.zig", logical.ops.items[0].scan_nodes.text_eq.?);
}

test "planner uses governed property predicate as scan binding" {
    const returns = [_]ast.Projection{.{ .variable = "n" }};
    const query = ast.Query{
        .pattern = .{ .start = .{ .var_name = "n", .kind = .document }, .segments = &.{} },
        .where_predicates = &.{.{ .var_name = "n", .property = "retrieval_hints", .value = "agent context" }},
        .returns = &returns,
    };
    var logical = try plan(std.testing.allocator, query);
    defer logical.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("retrieval_hints", logical.ops.items[0].scan_nodes.property_eq.?.key);
    try std.testing.expectEqualStrings("agent context", logical.ops.items[0].scan_nodes.property_eq.?.value);
}

test "planner preserves governed numeric property predicate operator" {
    const returns = [_]ast.Projection{.{ .variable = "n" }};
    const query = ast.Query{
        .pattern = .{ .start = .{ .var_name = "n", .kind = .command }, .segments = &.{} },
        .where_predicates = &.{.{ .var_name = "n", .property = "task_recorded_ns", .op = .gte, .value = "42" }},
        .returns = &returns,
    };
    var logical = try plan(std.testing.allocator, query);
    defer logical.deinit(std.testing.allocator);
    try std.testing.expectEqual(ast.PredicateOperator.gte, logical.ops.items[0].scan_nodes.property_eq.?.op);
}

test "planner composes governed numeric property range predicates" {
    const returns = [_]ast.Projection{.{ .variable = "n" }};
    const query = ast.Query{
        .pattern = .{ .start = .{ .var_name = "n", .kind = .command }, .segments = &.{} },
        .where_predicates = &.{
            .{ .var_name = "n", .property = "task_recorded_ns", .op = .gte, .value = "42" },
            .{ .var_name = "n", .property = "task_recorded_ns", .op = .lt, .value = "100" },
        },
        .returns = &returns,
    };
    var logical = try plan(std.testing.allocator, query);
    defer logical.deinit(std.testing.allocator);
    const range = logical.ops.items[0].scan_nodes.property_eq.?.uint_range.?;
    try std.testing.expectEqualStrings("42", range.min_value.?);
    try std.testing.expectEqualStrings("100", range.max_value.?);
    try std.testing.expect(!range.max_inclusive);
}

test "planner preserves order by property" {
    const returns = [_]ast.Projection{.{ .variable = "n" }};
    const query = ast.Query{
        .pattern = .{ .start = .{ .var_name = "n", .kind = .command }, .segments = &.{} },
        .where_predicates = &.{.{ .var_name = "n", .property = "task_event_ns", .op = .gte, .value = "42" }},
        .returns = &returns,
        .order_by = .{ .var_name = "n", .property = "task_event_ns", .direction = .asc },
    };
    var logical = try plan(std.testing.allocator, query);
    defer logical.deinit(std.testing.allocator);
    try std.testing.expectEqual(LogicalOp.order_by, std.meta.activeTag(logical.ops.items[1]));
    try std.testing.expectEqualStrings("task_event_ns", logical.ops.items[1].order_by.property);
}

test "planner attaches edge property predicate to expand" {
    const returns = [_]ast.Projection{.{ .variable = "b" }};
    const query = ast.Query{
        .pattern = .{
            .start = .{ .var_name = "a", .kind = .document },
            .segments = &.{.{ .edge = .{ .var_name = "e", .rel = .references }, .right = .{ .var_name = "b", .kind = .observation } }},
        },
        .where_predicates = &.{.{ .var_name = "e", .property = "created_by", .value = "agent" }},
        .returns = &returns,
    };
    var logical = try plan(std.testing.allocator, query);
    defer logical.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("e", logical.ops.items[1].expand.edge_var.?);
    try std.testing.expectEqualStrings("created_by", logical.ops.items[1].expand.edge_property_eq.?.key);
    try std.testing.expectEqualStrings("agent", logical.ops.items[1].expand.edge_property_eq.?.value);
}

test "planner resolves custom schema labels to descendant filters" {
    var registry = schema.Registry.init(std.testing.allocator);
    defer registry.deinit();
    try registry.addDefaultTypes();
    try registry.addNodeType("Human", 100, &.{});
    try registry.addNodeType("Man", 101, &.{100});
    try registry.addRelationType("Supports", 100, &.{});
    try registry.addRelationType("Proves", 101, &.{100});

    const query = try @import("parser.zig").parse(std.testing.allocator, "MATCH (h:Human)-[:Supports]->(m:Man) RETURN m");
    defer ast.freeQuery(std.testing.allocator, query);

    try std.testing.expectError(error.UnknownNodeKind, plan(std.testing.allocator, query));

    var logical = try planWithSchema(std.testing.allocator, query, registry);
    defer logical.deinit(std.testing.allocator);
    try std.testing.expect(logical.ops.items[0].scan_nodes.type_filter.matches(@enumFromInt(@as(u16, 100))));
    try std.testing.expect(logical.ops.items[0].scan_nodes.type_filter.matches(@enumFromInt(@as(u16, 101))));
    try std.testing.expect(logical.ops.items[1].expand.rel_filter.matches(@enumFromInt(@as(u16, 100))));
    try std.testing.expect(logical.ops.items[1].expand.rel_filter.matches(@enumFromInt(@as(u16, 101))));
    try std.testing.expect(logical.ops.items[1].expand.right_type_filter.matches(@enumFromInt(@as(u16, 101))));
}

fn plannerAllocationFailure(allocator: std.mem.Allocator) !void {
    const query = try @import("parser.zig").parse(allocator, "MATCH (f:file)-[:defines]->(s:function) WHERE f.text = \"src/main.zig\" RETURN s.text, path(f,s) LIMIT 10");
    defer ast.freeQuery(allocator, query);
    var logical = try plan(allocator, query);
    defer logical.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 4), logical.ops.items.len);
}

test "planner rolls back allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, plannerAllocationFailure, .{});
}
