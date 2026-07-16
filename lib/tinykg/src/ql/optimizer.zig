const std = @import("std");
const core = @import("../core.zig");
const schema = @import("../schema.zig");
const ast = @import("ast.zig");
const planner = @import("planner.zig");

pub const PhysicalOp = union(enum) {
    text_search: planner.TextSearch,
    node_lookup_by_text: struct {
        var_name: []const u8,
        kind: ?core.NodeKind,
        type_filter: schema.NodeTypeFilter = .any,
        text: []const u8,
        property_eq: ?planner.PropertyPredicate = null,
    },
    node_lookup_by_property: struct {
        var_name: []const u8,
        kind: ?core.NodeKind,
        type_filter: schema.NodeTypeFilter = .any,
        property_eq: planner.PropertyPredicate,
    },
    node_scan: planner.ScanNodes,
    expand: planner.Expand,
    order_by: ast.OrderBy,
    project: []const ast.Projection,
    limit: usize,
};

pub const PhysicalPlan = struct {
    ops: std.ArrayList(PhysicalOp),
    owned_strings: std.ArrayList([]u8) = .empty,
    owned_projection_slices: std.ArrayList([]ast.Projection) = .empty,

    pub fn deinit(self: *PhysicalPlan, allocator: std.mem.Allocator) void {
        for (self.owned_projection_slices.items) |projections| allocator.free(projections);
        self.owned_projection_slices.deinit(allocator);
        for (self.owned_strings.items) |string| allocator.free(string);
        self.owned_strings.deinit(allocator);
        self.ops.deinit(allocator);
    }
};

pub fn optimize(allocator: std.mem.Allocator, logical: planner.LogicalPlan) !PhysicalPlan {
    var out = PhysicalPlan{ .ops = .empty };
    errdefer out.deinit(allocator);
    for (logical.ops.items) |op| {
        switch (op) {
            .text_search => |text_search| try out.ops.append(allocator, .{ .text_search = .{
                .var_name = try ownString(allocator, &out, text_search.var_name),
                .query = try ownString(allocator, &out, text_search.query),
                .kind = text_search.kind,
                .type_filter = text_search.type_filter,
                .text_eq = try maybeOwnString(allocator, &out, text_search.text_eq),
                .limit = text_search.limit,
            } }),
            .scan_nodes => |scan| {
                if (scan.text_eq) |text| {
                    try out.ops.append(allocator, .{ .node_lookup_by_text = .{
                        .var_name = try ownString(allocator, &out, scan.var_name),
                        .kind = scan.kind,
                        .type_filter = scan.type_filter,
                        .text = try ownString(allocator, &out, text),
                        .property_eq = try maybeOwnPropertyPredicate(allocator, &out, scan.property_eq),
                    } });
                } else if (scan.property_eq) |property_eq| {
                    try out.ops.append(allocator, .{ .node_lookup_by_property = .{
                        .var_name = try ownString(allocator, &out, scan.var_name),
                        .kind = scan.kind,
                        .type_filter = scan.type_filter,
                        .property_eq = try ownPropertyPredicate(allocator, &out, property_eq),
                    } });
                } else {
                    try out.ops.append(allocator, .{ .node_scan = .{
                        .var_name = try ownString(allocator, &out, scan.var_name),
                        .kind = scan.kind,
                        .type_filter = scan.type_filter,
                        .text_eq = null,
                        .property_eq = null,
                    } });
                }
            },
            .expand => |expand| try out.ops.append(allocator, .{ .expand = .{
                .left_var = try ownString(allocator, &out, expand.left_var),
                .edge_var = try maybeOwnString(allocator, &out, expand.edge_var),
                .edge_property_eq = try maybeOwnPropertyPredicate(allocator, &out, expand.edge_property_eq),
                .rel = expand.rel,
                .rel_filter = expand.rel_filter,
                .direction = expand.direction,
                .right_var = try ownString(allocator, &out, expand.right_var),
                .right_kind = expand.right_kind,
                .right_type_filter = expand.right_type_filter,
                .right_text_eq = try maybeOwnString(allocator, &out, expand.right_text_eq),
                .min_hops = expand.min_hops,
                .max_hops = expand.max_hops,
            } }),
            .order_by => |order_by| try out.ops.append(allocator, .{ .order_by = try cloneOrderBy(allocator, &out, order_by) }),
            .project => |project| try out.ops.append(allocator, .{ .project = try cloneProjections(allocator, &out, project) }),
            .limit => |limit| try out.ops.append(allocator, .{ .limit = limit }),
        }
    }
    return out;
}

fn ownString(allocator: std.mem.Allocator, plan_out: *PhysicalPlan, value: []const u8) ![]const u8 {
    const owned = try allocator.dupe(u8, value);
    errdefer allocator.free(owned);
    try plan_out.owned_strings.append(allocator, owned);
    return owned;
}

fn maybeOwnString(allocator: std.mem.Allocator, plan_out: *PhysicalPlan, value: ?[]const u8) !?[]const u8 {
    return if (value) |text| try ownString(allocator, plan_out, text) else null;
}

fn ownPropertyPredicate(allocator: std.mem.Allocator, plan_out: *PhysicalPlan, value: planner.PropertyPredicate) !planner.PropertyPredicate {
    return .{
        .key = try ownString(allocator, plan_out, value.key),
        .op = value.op,
        .value = try ownString(allocator, plan_out, value.value),
        .uint_range = try cloneUintRangePredicate(allocator, plan_out, value.uint_range),
    };
}

fn maybeOwnPropertyPredicate(allocator: std.mem.Allocator, plan_out: *PhysicalPlan, value: ?planner.PropertyPredicate) !?planner.PropertyPredicate {
    return if (value) |predicate| try ownPropertyPredicate(allocator, plan_out, predicate) else null;
}

fn cloneUintRangePredicate(allocator: std.mem.Allocator, plan_out: *PhysicalPlan, value: ?planner.UintRangePredicate) !?planner.UintRangePredicate {
    return if (value) |range| .{
        .min_value = try maybeOwnString(allocator, plan_out, range.min_value),
        .min_inclusive = range.min_inclusive,
        .max_value = try maybeOwnString(allocator, plan_out, range.max_value),
        .max_inclusive = range.max_inclusive,
    } else null;
}

fn cloneOrderBy(allocator: std.mem.Allocator, plan_out: *PhysicalPlan, order_by: ast.OrderBy) !ast.OrderBy {
    return .{
        .var_name = try ownString(allocator, plan_out, order_by.var_name),
        .property = try ownString(allocator, plan_out, order_by.property),
        .direction = order_by.direction,
    };
}

fn cloneProjections(allocator: std.mem.Allocator, plan_out: *PhysicalPlan, projections: []const ast.Projection) ![]ast.Projection {
    const owned = try allocator.alloc(ast.Projection, projections.len);
    errdefer allocator.free(owned);
    for (projections, 0..) |projection, i| {
        owned[i] = try cloneProjection(allocator, plan_out, projection);
    }
    try plan_out.owned_projection_slices.append(allocator, owned);
    return owned;
}

fn cloneProjection(allocator: std.mem.Allocator, plan_out: *PhysicalPlan, projection: ast.Projection) !ast.Projection {
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

test "optimizer selects text lookup" {
    var ops = std.ArrayList(planner.LogicalOp).empty;
    defer ops.deinit(std.testing.allocator);
    try ops.append(std.testing.allocator, .{ .scan_nodes = .{ .var_name = "n", .kind = null, .text_eq = "x" } });
    var physical = try optimize(std.testing.allocator, .{ .ops = ops });
    defer physical.deinit(std.testing.allocator);
    try std.testing.expectEqual(PhysicalOp.node_lookup_by_text, std.meta.activeTag(physical.ops.items[0]));
}

test "optimizer selects governed property lookup" {
    var ops = std.ArrayList(planner.LogicalOp).empty;
    defer ops.deinit(std.testing.allocator);
    try ops.append(std.testing.allocator, .{ .scan_nodes = .{
        .var_name = "n",
        .kind = .document,
        .property_eq = .{ .key = "summary", .value = "agent hint" },
    } });
    var physical = try optimize(std.testing.allocator, .{ .ops = ops });
    defer physical.deinit(std.testing.allocator);
    try std.testing.expectEqual(PhysicalOp.node_lookup_by_property, std.meta.activeTag(physical.ops.items[0]));
    try std.testing.expectEqualStrings("summary", physical.ops.items[0].node_lookup_by_property.property_eq.key);
}

test "optimizer preserves order by property" {
    var ops = std.ArrayList(planner.LogicalOp).empty;
    defer ops.deinit(std.testing.allocator);
    try ops.append(std.testing.allocator, .{ .scan_nodes = .{
        .var_name = "n",
        .kind = .command,
        .property_eq = .{ .key = "task_event_ns", .op = .gte, .value = "42" },
    } });
    try ops.append(std.testing.allocator, .{ .order_by = .{ .var_name = "n", .property = "task_event_ns", .direction = .asc } });
    var physical = try optimize(std.testing.allocator, .{ .ops = ops });
    defer physical.deinit(std.testing.allocator);
    try std.testing.expectEqual(PhysicalOp.order_by, std.meta.activeTag(physical.ops.items[1]));
    try std.testing.expectEqualStrings("task_event_ns", physical.ops.items[1].order_by.property);
}

fn optimizerAllocationFailure(allocator: std.mem.Allocator) !void {
    const query = try @import("parser.zig").parse(allocator, "MATCH (f:file)-[:defines]->(s:function) WHERE f.text = \"src/main.zig\" RETURN s.text, path(f,s) LIMIT 10");
    defer ast.freeQuery(allocator, query);
    var logical = try planner.plan(allocator, query);
    defer logical.deinit(allocator);
    var physical = try optimize(allocator, logical);
    defer physical.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 4), physical.ops.items.len);
}

test "optimizer rolls back allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, optimizerAllocationFailure, .{});
}
