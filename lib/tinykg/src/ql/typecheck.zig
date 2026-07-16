const std = @import("std");
const core = @import("../core.zig");
const dag = @import("../dag.zig");
const schema = @import("../schema.zig");
const ast = @import("ast.zig");
const parser = @import("parser.zig");

pub const VarType = struct {
    name: []const u8,
    entity: enum { node, edge } = .node,
    kind: ?core.NodeKind,
    type_label: ?[]const u8 = null,
    rel: ?core.RelKind = null,
    rel_label: ?[]const u8 = null,
};

pub const TypeEnv = struct {
    vars: std.ArrayList(VarType),
    owned_strings: std.ArrayList([]u8) = .empty,

    pub fn init() TypeEnv {
        return .{ .vars = .empty };
    }

    pub fn deinit(self: *TypeEnv, allocator: std.mem.Allocator) void {
        for (self.owned_strings.items) |string| allocator.free(string);
        self.owned_strings.deinit(allocator);
        self.vars.deinit(allocator);
    }

    pub fn get(self: TypeEnv, name: []const u8) ?VarType {
        for (self.vars.items) |var_type| {
            if (std.mem.eql(u8, var_type.name, name)) return var_type;
        }
        return null;
    }

    pub fn getNode(self: TypeEnv, name: []const u8) ?VarType {
        const var_type = self.get(name) orelse return null;
        return if (var_type.entity == .node) var_type else null;
    }

    pub fn getEdge(self: TypeEnv, name: []const u8) ?VarType {
        const var_type = self.get(name) orelse return null;
        return if (var_type.entity == .edge) var_type else null;
    }
};

fn ownString(allocator: std.mem.Allocator, env: *TypeEnv, value: []const u8) ![]const u8 {
    const owned = try allocator.dupe(u8, value);
    errdefer allocator.free(owned);
    try env.owned_strings.append(allocator, owned);
    return owned;
}

pub fn check(allocator: std.mem.Allocator, query: ast.Query) !TypeEnv {
    return checkWithOptionalSchema(allocator, query, null);
}

pub fn checkWithSchema(allocator: std.mem.Allocator, query: ast.Query, registry: schema.Registry) !TypeEnv {
    return checkWithOptionalSchema(allocator, query, registry);
}

fn checkWithOptionalSchema(allocator: std.mem.Allocator, query: ast.Query, registry: ?schema.Registry) !TypeEnv {
    var env = TypeEnv.init();
    errdefer env.deinit(allocator);

    if (query.text_pattern) |text_pattern| {
        try bindNode(allocator, &env, .{ .var_name = text_pattern.var_name, .kind = text_pattern.kind, .type_label = text_pattern.type_label });
        try bindNode(allocator, &env, query.pattern.start);
        for (query.pattern.segments) |segment| {
            if (segment.edge.var_name) |edge_var| try bindEdge(allocator, &env, edge_var, segment.edge);
            try bindNode(allocator, &env, segment.right);
        }
    } else {
        try bindNode(allocator, &env, query.pattern.start);
        for (query.pattern.segments) |segment| {
            if (segment.edge.var_name) |edge_var| try bindEdge(allocator, &env, edge_var, segment.edge);
            try bindNode(allocator, &env, segment.right);
        }
    }

    for (query.where_predicates) |predicate| {
        const var_type = env.get(predicate.var_name) orelse return error.UnboundWhereVariable;
        switch (var_type.entity) {
            .node => {
                if (!nodePredicatePropertySupportedForVar(registry, var_type, predicate.property)) return error.UnknownProperty;
                if (!nodePredicatePropertySupported(predicate.property)) return error.UnsupportedPropertyPredicate;
                if (predicate.op != .eq and !predicateNumericRangeSupported(predicate.property)) return error.UnsupportedPropertyPredicate;
            },
            .edge => {
                if (!edgePredicatePropertySupportedForVar(registry, var_type, predicate.property)) return error.UnknownProperty;
                if (!edgePredicatePropertySupported(predicate.property)) return error.UnsupportedPropertyPredicate;
                if (predicate.op != .eq) return error.UnsupportedPropertyPredicate;
            },
        }
    }
    try rejectUnsupportedIndexedPropertyPredicates(query);
    try rejectUnsupportedEdgePropertyPredicates(query);
    try rejectConflictingPredicates(query.where_predicates);
    try rejectUnsupportedOrderBy(env, query);

    for (query.returns) |projection| {
        switch (projection) {
            .variable => |var_name| {
                if (env.getNode(var_name) == null) return error.UnboundReturnVariable;
            },
            .property => |property| {
                const node_var = env.getNode(property.var_name) orelse return error.UnboundReturnVariable;
                if (!nodeProjectionPropertySupportedForVar(registry, node_var, property.property)) return error.UnknownProperty;
            },
            .path => |path| {
                if (env.getNode(path.from_var) == null) return error.UnboundReturnVariable;
                if (env.getNode(path.to_var) == null) return error.UnboundReturnVariable;
                if (!pathProjectionSupported(query, path.from_var, path.to_var)) return error.UnsupportedPathProjection;
            },
            .reachable => |reachable| {
                if (env.getNode(reachable.from_var) == null) return error.UnboundReturnVariable;
                if (env.getNode(reachable.to_var) == null) return error.UnboundReturnVariable;
                if (!dag.isDagRelation(reachable.rel)) return error.UnsupportedReachableRelation;
            },
            .context => |context| {
                if (env.getNode(context.var_name) == null) return error.UnboundReturnVariable;
            },
            .score => |score| {
                if (env.getNode(score.var_name) == null) return error.UnboundReturnVariable;
                if (query.text_pattern == null or !std.mem.eql(u8, query.text_pattern.?.var_name, score.var_name)) return error.UnsupportedScoreProjection;
            },
        }
    }

    return env;
}

fn nodePredicatePropertySupportedForVar(registry: ?schema.Registry, var_type: VarType, property: []const u8) bool {
    const loaded = registry orelse return nodePredicatePropertySupported(property);
    if (std.mem.eql(u8, property, "text")) return loaded.nodePropertyByTypeId(resolveNodeTypeId(loaded, var_type) orelse return true, property) != null;
    const type_id = resolveNodeTypeId(loaded, var_type) orelse return nodePredicatePropertySupported(property);
    return loaded.nodePropertyByTypeId(type_id, property) != null;
}

fn nodeProjectionPropertySupportedForVar(registry: ?schema.Registry, var_type: VarType, property: []const u8) bool {
    const loaded = registry orelse return nodeProjectionPropertySupported(property);
    const type_id = resolveNodeTypeId(loaded, var_type) orelse return nodeProjectionPropertySupported(property);
    return loaded.nodePropertyByTypeId(type_id, property) != null;
}

fn edgePredicatePropertySupportedForVar(registry: ?schema.Registry, var_type: VarType, property: []const u8) bool {
    const loaded = registry orelse return edgePredicatePropertySupported(property);
    const type_id = resolveRelationTypeId(loaded, var_type) orelse return edgePredicatePropertySupported(property);
    return loaded.relationPropertyByTypeId(type_id, property) != null;
}

fn resolveNodeTypeId(registry: schema.Registry, var_type: VarType) ?u16 {
    if (var_type.kind) |kind| return @intFromEnum(kind);
    if (var_type.type_label) |label| return registry.findNodeType(label);
    return null;
}

fn resolveRelationTypeId(registry: schema.Registry, var_type: VarType) ?u16 {
    if (var_type.rel) |rel| return @intFromEnum(rel);
    if (var_type.rel_label) |label| return registry.findRelationType(label);
    return null;
}

fn rejectUnsupportedOrderBy(env: TypeEnv, query: ast.Query) !void {
    const order_by = query.order_by orelse return;
    if (env.get(order_by.var_name) == null) return error.UnboundReturnVariable;
    if (env.getNode(order_by.var_name) == null) return error.UnsupportedPropertyPredicate;
    if (!predicateNumericRangeSupported(order_by.property)) return error.UnsupportedPropertyPredicate;
}

fn nodePredicatePropertySupported(property: []const u8) bool {
    return std.mem.eql(u8, property, "name") or
        std.mem.eql(u8, property, "text") or
        std.mem.eql(u8, property, "schema_type") or
        std.mem.eql(u8, property, "summary") or
        std.mem.eql(u8, property, "retrieval_hints") or
        std.mem.eql(u8, property, "task_recorded_ns") or
        std.mem.eql(u8, property, "task_created_ns") or
        std.mem.eql(u8, property, "task_completed_ns") or
        std.mem.eql(u8, property, "task_event_ns") or
        std.mem.eql(u8, property, "task_root_id") or
        std.mem.eql(u8, property, "task_id");
}

fn edgePredicatePropertySupported(property: []const u8) bool {
    return std.mem.eql(u8, property, "markdown_attr") or
        std.mem.eql(u8, property, "render_flags") or
        std.mem.eql(u8, property, "source_span") or
        std.mem.eql(u8, property, "confidence") or
        std.mem.eql(u8, property, "created_by");
}

fn nodeIndexedPredicatePropertySupported(property: []const u8) bool {
    return !std.mem.eql(u8, property, "text") and nodePredicatePropertySupported(property);
}

fn nodeProjectionPropertySupported(property: []const u8) bool {
    return std.mem.eql(u8, property, "name") or
        std.mem.eql(u8, property, "summary") or
        std.mem.eql(u8, property, "text") or
        std.mem.eql(u8, property, "retrieval_hints") or
        std.mem.eql(u8, property, "schema_type") or
        std.mem.eql(u8, property, "external_key") or
        std.mem.eql(u8, property, "content_hash") or
        std.mem.eql(u8, property, "task_event_type") or
        std.mem.eql(u8, property, "dependency_relation") or
        predicateNumericRangeSupported(property);
}

fn predicateNumericRangeSupported(property: []const u8) bool {
    return std.mem.eql(u8, property, "task_recorded_ns") or
        std.mem.eql(u8, property, "task_created_ns") or
        std.mem.eql(u8, property, "task_completed_ns") or
        std.mem.eql(u8, property, "task_event_ns") or
        std.mem.eql(u8, property, "task_root_id") or
        std.mem.eql(u8, property, "task_id");
}

fn rejectUnsupportedIndexedPropertyPredicates(query: ast.Query) !void {
    var first_indexed_predicate: ?ast.Predicate = null;
    var indexed_predicate_count: usize = 0;
    var seen_lower_bound = false;
    var seen_upper_bound = false;
    for (query.where_predicates) |predicate| {
        if (!nodeIndexedPredicatePropertySupported(predicate.property)) continue;
        if (query.text_pattern != null) return error.UnsupportedPropertyPredicate;
        if (!std.mem.eql(u8, predicate.var_name, query.pattern.start.var_name)) return error.UnsupportedPropertyPredicate;
        indexed_predicate_count += 1;
        if (first_indexed_predicate) |first| {
            if (!predicateNumericRangeSupported(predicate.property)) return error.UnsupportedPropertyPredicate;
            if (!std.mem.eql(u8, first.property, predicate.property)) return error.UnsupportedPropertyPredicate;
            if (predicate.op == .eq) return error.UnsupportedPropertyPredicate;
        } else {
            first_indexed_predicate = predicate;
        }
        switch (predicate.op) {
            .eq => if (indexed_predicate_count > 1) return error.UnsupportedPropertyPredicate,
            .gt, .gte => {
                if (seen_lower_bound) return error.UnsupportedPropertyPredicate;
                seen_lower_bound = true;
            },
            .lt, .lte => {
                if (seen_upper_bound) return error.UnsupportedPropertyPredicate;
                seen_upper_bound = true;
            },
        }
        if (indexed_predicate_count > 2) return error.UnsupportedPropertyPredicate;
    }
}

fn rejectUnsupportedEdgePropertyPredicates(query: ast.Query) !void {
    for (query.pattern.segments) |segment| {
        const edge_var = segment.edge.var_name orelse continue;
        if (segment.edge.min_hops != 1 or segment.edge.max_hops != 1) {
            for (query.where_predicates) |predicate| {
                if (std.mem.eql(u8, predicate.var_name, edge_var)) return error.UnsupportedPropertyPredicate;
            }
            continue;
        }
        var edge_predicate_count: usize = 0;
        for (query.where_predicates) |predicate| {
            if (!std.mem.eql(u8, predicate.var_name, edge_var)) continue;
            edge_predicate_count += 1;
            if (edge_predicate_count > 1) return error.UnsupportedPropertyPredicate;
        }
    }
}

fn rejectConflictingPredicates(predicates: []const ast.Predicate) !void {
    for (predicates, 0..) |left, i| {
        for (predicates[i + 1 ..]) |right| {
            if (!std.mem.eql(u8, left.var_name, right.var_name)) continue;
            if (!std.mem.eql(u8, left.property, right.property)) continue;
            if (left.op != right.op) continue;
            if (!std.mem.eql(u8, left.value, right.value)) return error.ConflictingPredicate;
        }
    }
}

fn pathProjectionSupported(query: ast.Query, from_var: []const u8, to_var: []const u8) bool {
    var left = query.pattern.start;
    for (query.pattern.segments) |segment| {
        if (std.mem.eql(u8, left.var_name, from_var) and std.mem.eql(u8, segment.right.var_name, to_var)) {
            return true;
        }
        left = segment.right;
    }
    return false;
}

fn bindNode(allocator: std.mem.Allocator, env: *TypeEnv, node: ast.NodePattern) !void {
    for (env.vars.items) |*existing| {
        if (!std.mem.eql(u8, existing.name, node.var_name)) continue;
        if (existing.entity != .node) return error.ConflictingVariableKind;
        if (existing.kind != null and node.kind != null and existing.kind.? != node.kind.?) {
            return error.ConflictingVariableKind;
        }
        if (existing.kind == null and node.kind != null) existing.kind = node.kind;
        if (existing.type_label == null and node.type_label != null) existing.type_label = try ownString(allocator, env, node.type_label.?);
        return;
    }
    try env.vars.append(allocator, .{
        .name = try ownString(allocator, env, node.var_name),
        .entity = .node,
        .kind = node.kind,
        .type_label = if (node.type_label) |label| try ownString(allocator, env, label) else null,
    });
}

fn bindEdge(allocator: std.mem.Allocator, env: *TypeEnv, var_name: []const u8, edge: ast.EdgePattern) !void {
    for (env.vars.items) |existing| {
        if (!std.mem.eql(u8, existing.name, var_name)) continue;
        return error.ConflictingVariableKind;
    }
    try env.vars.append(allocator, .{
        .name = try ownString(allocator, env, var_name),
        .entity = .edge,
        .kind = null,
        .rel = edge.rel,
        .rel_label = if (edge.rel_label) |label| try ownString(allocator, env, label) else null,
    });
}

test "type checker accepts bound return variable" {
    const query = ast.Query{
        .pattern = .{ .start = .{ .var_name = "n", .kind = .file }, .segments = &.{} },
        .returns = &.{.{ .variable = "n" }},
    };
    var env = try check(std.testing.allocator, query);
    defer env.deinit(std.testing.allocator);
    try std.testing.expect(env.get("n") != null);
}

test "type environment owns variable texts after AST is freed" {
    const source = try std.testing.allocator.dupe(u8, "MATCH (f:file)-[:defines]->(s:function) RETURN s");
    defer std.testing.allocator.free(source);
    const query = try parser.parse(std.testing.allocator, source);

    var env = try check(std.testing.allocator, query);
    defer env.deinit(std.testing.allocator);
    ast.freeQuery(std.testing.allocator, query);

    try std.testing.expect(env.get("f") != null);
    try std.testing.expect(env.get("s") != null);
    try std.testing.expectEqual(core.NodeKind.function, env.get("s").?.kind.?);
}

fn typecheckAllocationFailure(allocator: std.mem.Allocator) !void {
    const query = try parser.parse(allocator, "MATCH TEXT \"edge index\" AS o MATCH (o)-[:EVIDENCES]->(t:Task) WHERE t.text = \"repair\" RETURN t.text, score(o), path(o,t)");
    defer ast.freeQuery(allocator, query);
    var env = try check(allocator, query);
    defer env.deinit(allocator);
    try std.testing.expect(env.get("o") != null);
    try std.testing.expect(env.get("t") != null);
}

test "type checker rolls back allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, typecheckAllocationFailure, .{});
}

test "type checker rejects unbound return variable" {
    const query = ast.Query{
        .pattern = .{ .start = .{ .var_name = "n", .kind = .file }, .segments = &.{} },
        .returns = &.{.{ .variable = "missing" }},
    };
    try std.testing.expectError(error.UnboundReturnVariable, check(std.testing.allocator, query));
}

test "type checker rejects conflicting text predicates" {
    const query = ast.Query{
        .pattern = .{ .start = .{ .var_name = "n", .kind = .file }, .segments = &.{} },
        .where_predicates = &.{
            .{ .var_name = "n", .property = "text", .value = "a.zig" },
            .{ .var_name = "n", .property = "text", .value = "b.zig" },
        },
        .returns = &.{.{ .variable = "n" }},
    };
    try std.testing.expectError(error.ConflictingPredicate, check(std.testing.allocator, query));
}

test "type checker accepts duplicate identical text predicates" {
    const query = ast.Query{
        .pattern = .{ .start = .{ .var_name = "n", .kind = .file }, .segments = &.{} },
        .where_predicates = &.{
            .{ .var_name = "n", .property = "text", .value = "a.zig" },
            .{ .var_name = "n", .property = "text", .value = "a.zig" },
        },
        .returns = &.{.{ .variable = "n" }},
    };
    var env = try check(std.testing.allocator, query);
    defer env.deinit(std.testing.allocator);
    try std.testing.expect(env.get("n") != null);
}

test "type checker accepts governed string property predicate on start node" {
    const query = ast.Query{
        .pattern = .{ .start = .{ .var_name = "n", .kind = .document }, .segments = &.{} },
        .where_predicates = &.{.{ .var_name = "n", .property = "summary", .value = "agent hint" }},
        .returns = &.{.{ .variable = "n" }},
    };
    var env = try check(std.testing.allocator, query);
    defer env.deinit(std.testing.allocator);
    try std.testing.expect(env.get("n") != null);
}

test "type checker accepts governed numeric property predicate on start node" {
    const query = ast.Query{
        .pattern = .{ .start = .{ .var_name = "n", .kind = .command }, .segments = &.{} },
        .where_predicates = &.{.{ .var_name = "n", .property = "task_root_id", .value = "42" }},
        .returns = &.{.{ .variable = "n" }},
    };
    var env = try check(std.testing.allocator, query);
    defer env.deinit(std.testing.allocator);
    try std.testing.expect(env.get("n") != null);
}

test "type checker accepts governed numeric range predicate on start node" {
    const query = ast.Query{
        .pattern = .{ .start = .{ .var_name = "n", .kind = .command }, .segments = &.{} },
        .where_predicates = &.{.{ .var_name = "n", .property = "task_recorded_ns", .op = .gte, .value = "42" }},
        .returns = &.{.{ .variable = "n" }},
    };
    var env = try check(std.testing.allocator, query);
    defer env.deinit(std.testing.allocator);
    try std.testing.expect(env.get("n") != null);
}

test "type checker accepts composed governed numeric range predicate on start node" {
    const query = ast.Query{
        .pattern = .{ .start = .{ .var_name = "n", .kind = .command }, .segments = &.{} },
        .where_predicates = &.{
            .{ .var_name = "n", .property = "task_recorded_ns", .op = .gte, .value = "42" },
            .{ .var_name = "n", .property = "task_recorded_ns", .op = .lt, .value = "100" },
        },
        .returns = &.{.{ .variable = "n" }},
    };
    var env = try check(std.testing.allocator, query);
    defer env.deinit(std.testing.allocator);
    try std.testing.expect(env.get("n") != null);
}

test "type checker rejects composed range predicates on different properties" {
    const query = ast.Query{
        .pattern = .{ .start = .{ .var_name = "n", .kind = .command }, .segments = &.{} },
        .where_predicates = &.{
            .{ .var_name = "n", .property = "task_recorded_ns", .op = .gte, .value = "42" },
            .{ .var_name = "n", .property = "task_event_ns", .op = .lt, .value = "100" },
        },
        .returns = &.{.{ .variable = "n" }},
    };
    try std.testing.expectError(error.UnsupportedPropertyPredicate, check(std.testing.allocator, query));
}

test "type checker rejects composed duplicate range bound direction" {
    const query = ast.Query{
        .pattern = .{ .start = .{ .var_name = "n", .kind = .command }, .segments = &.{} },
        .where_predicates = &.{
            .{ .var_name = "n", .property = "task_recorded_ns", .op = .gte, .value = "42" },
            .{ .var_name = "n", .property = "task_recorded_ns", .op = .gt, .value = "50" },
        },
        .returns = &.{.{ .variable = "n" }},
    };
    try std.testing.expectError(error.UnsupportedPropertyPredicate, check(std.testing.allocator, query));
}

test "type checker accepts indexed ascending order by matching governed uint predicate" {
    const query = ast.Query{
        .pattern = .{ .start = .{ .var_name = "n", .kind = .command }, .segments = &.{} },
        .where_predicates = &.{.{ .var_name = "n", .property = "task_event_ns", .op = .gte, .value = "42" }},
        .returns = &.{.{ .variable = "n" }},
        .order_by = .{ .var_name = "n", .property = "task_event_ns", .direction = .asc },
    };
    var env = try check(std.testing.allocator, query);
    defer env.deinit(std.testing.allocator);
    try std.testing.expect(env.get("n") != null);
}

test "type checker accepts descending order by for governed property" {
    const query = ast.Query{
        .pattern = .{ .start = .{ .var_name = "n", .kind = .command }, .segments = &.{} },
        .where_predicates = &.{.{ .var_name = "n", .property = "task_event_ns", .op = .gte, .value = "42" }},
        .returns = &.{.{ .variable = "n" }},
        .order_by = .{ .var_name = "n", .property = "task_event_ns", .direction = .desc },
    };
    var env = try check(std.testing.allocator, query);
    defer env.deinit(std.testing.allocator);
    try std.testing.expect(env.get("n") != null);
}

test "type checker accepts order by without matching governed property seed" {
    const query = ast.Query{
        .pattern = .{ .start = .{ .var_name = "n", .kind = .command }, .segments = &.{} },
        .returns = &.{.{ .variable = "n" }},
        .order_by = .{ .var_name = "n", .property = "task_event_ns", .direction = .asc },
    };
    var env = try check(std.testing.allocator, query);
    defer env.deinit(std.testing.allocator);
    try std.testing.expect(env.get("n") != null);
}

test "type checker accepts order by expanded node governed property" {
    const query = ast.Query{
        .pattern = .{
            .start = .{ .var_name = "a", .kind = .document },
            .segments = &.{.{ .edge = .{ .rel = .references }, .right = .{ .var_name = "b", .kind = .command } }},
        },
        .returns = &.{.{ .variable = "b" }},
        .order_by = .{ .var_name = "b", .property = "task_event_ns", .direction = .desc },
    };
    var env = try check(std.testing.allocator, query);
    defer env.deinit(std.testing.allocator);
    try std.testing.expect(env.get("b") != null);
}

test "type checker rejects string range predicate" {
    const query = ast.Query{
        .pattern = .{ .start = .{ .var_name = "n", .kind = .document }, .segments = &.{} },
        .where_predicates = &.{.{ .var_name = "n", .property = "summary", .op = .gte, .value = "agent hint" }},
        .returns = &.{.{ .variable = "n" }},
    };
    try std.testing.expectError(error.UnsupportedPropertyPredicate, check(std.testing.allocator, query));
}

test "type checker rejects governed property predicate outside start seed" {
    const query = ast.Query{
        .pattern = .{
            .start = .{ .var_name = "a", .kind = .document },
            .segments = &.{.{ .edge = .{ .rel = .mentions }, .right = .{ .var_name = "b", .kind = .document } }},
        },
        .where_predicates = &.{.{ .var_name = "b", .property = "summary", .value = "agent hint" }},
        .returns = &.{.{ .variable = "b" }},
    };
    try std.testing.expectError(error.UnsupportedPropertyPredicate, check(std.testing.allocator, query));
}

test "type checker accepts edge property equality on edge alias" {
    const query = ast.Query{
        .pattern = .{
            .start = .{ .var_name = "a", .kind = .document },
            .segments = &.{.{ .edge = .{ .var_name = "e", .rel = .references }, .right = .{ .var_name = "b", .kind = .observation } }},
        },
        .where_predicates = &.{.{ .var_name = "e", .property = "created_by", .value = "agent" }},
        .returns = &.{.{ .variable = "b" }},
    };
    var env = try check(std.testing.allocator, query);
    defer env.deinit(std.testing.allocator);
    try std.testing.expect(env.getEdge("e") != null);
}

test "type checker rejects edge property range and unknown key" {
    const range_query = ast.Query{
        .pattern = .{
            .start = .{ .var_name = "a", .kind = .document },
            .segments = &.{.{ .edge = .{ .var_name = "e", .rel = .references }, .right = .{ .var_name = "b", .kind = .observation } }},
        },
        .where_predicates = &.{.{ .var_name = "e", .property = "confidence", .op = .gte, .value = "0.7" }},
        .returns = &.{.{ .variable = "b" }},
    };
    try std.testing.expectError(error.UnsupportedPropertyPredicate, check(std.testing.allocator, range_query));

    const unknown_key_query = ast.Query{
        .pattern = .{
            .start = .{ .var_name = "a", .kind = .document },
            .segments = &.{.{ .edge = .{ .var_name = "e", .rel = .references }, .right = .{ .var_name = "b", .kind = .observation } }},
        },
        .where_predicates = &.{.{ .var_name = "e", .property = "summary", .value = "wrong lane" }},
        .returns = &.{.{ .variable = "b" }},
    };
    try std.testing.expectError(error.UnknownProperty, check(std.testing.allocator, unknown_key_query));
}

test "type checker rejects edge alias return and edge order by" {
    const return_query = ast.Query{
        .pattern = .{
            .start = .{ .var_name = "a", .kind = .document },
            .segments = &.{.{ .edge = .{ .var_name = "e", .rel = .references }, .right = .{ .var_name = "b", .kind = .observation } }},
        },
        .returns = &.{.{ .variable = "e" }},
    };
    try std.testing.expectError(error.UnboundReturnVariable, check(std.testing.allocator, return_query));

    const order_query = ast.Query{
        .pattern = .{
            .start = .{ .var_name = "a", .kind = .document },
            .segments = &.{.{ .edge = .{ .var_name = "e", .rel = .references }, .right = .{ .var_name = "b", .kind = .observation } }},
        },
        .where_predicates = &.{.{ .var_name = "e", .property = "created_by", .value = "agent" }},
        .returns = &.{.{ .variable = "b" }},
        .order_by = .{ .var_name = "e", .property = "created_by", .direction = .asc },
    };
    try std.testing.expectError(error.UnsupportedPropertyPredicate, check(std.testing.allocator, order_query));
}

test "type checker rejects metaknow id where predicate" {
    const query = ast.Query{
        .pattern = .{ .start = .{ .var_name = "n", .kind = .task }, .segments = &.{} },
        .where_predicates = &.{.{ .var_name = "n", .property = "metaknow_id", .value = "entity_node:abc" }},
        .returns = &.{.{ .variable = "n" }},
    };
    try std.testing.expectError(error.UnknownProperty, check(std.testing.allocator, query));
}

test "type checker still rejects unsupported property projections" {
    const query = ast.Query{
        .pattern = .{ .start = .{ .var_name = "n", .kind = .task }, .segments = &.{} },
        .returns = &.{.{ .property = .{ .var_name = "n", .property = "metaknow_id" } }},
    };
    try std.testing.expectError(error.UnknownProperty, check(std.testing.allocator, query));
}

test "type checker rejects unsupported composed path projection" {
    const segments = [_]ast.PatternSegment{
        .{
            .edge = .{ .rel = .depends_on },
            .right = .{ .var_name = "b", .kind = .task },
        },
        .{
            .edge = .{ .rel = .depends_on },
            .right = .{ .var_name = "c", .kind = .task },
        },
    };
    const query = ast.Query{
        .pattern = .{ .start = .{ .var_name = "a", .kind = .task }, .segments = &segments },
        .returns = &.{.{ .path = .{ .from_var = "a", .to_var = "c" } }},
    };
    try std.testing.expectError(error.UnsupportedPathProjection, check(std.testing.allocator, query));
}

test "type checker rejects reachable projection for non-DAG relation" {
    const segments = [_]ast.PatternSegment{
        .{
            .edge = .{ .rel = .calls },
            .right = .{ .var_name = "b", .kind = .function },
        },
    };
    const query = ast.Query{
        .pattern = .{ .start = .{ .var_name = "a", .kind = .function }, .segments = &segments },
        .returns = &.{.{ .reachable = .{ .from_var = "a", .to_var = "b", .rel = .calls } }},
    };
    try std.testing.expectError(error.UnsupportedReachableRelation, check(std.testing.allocator, query));
}

test "type checker accepts reachable projection for DAG relation" {
    const segments = [_]ast.PatternSegment{
        .{
            .edge = .{ .rel = .depends_on },
            .right = .{ .var_name = "b", .kind = .task },
        },
    };
    const query = ast.Query{
        .pattern = .{ .start = .{ .var_name = "a", .kind = .task }, .segments = &segments },
        .returns = &.{.{ .reachable = .{ .from_var = "a", .to_var = "b", .rel = .depends_on } }},
    };
    var env = try check(std.testing.allocator, query);
    defer env.deinit(std.testing.allocator);
}

test "type checker rejects variable kind conflict after untyped occurrence" {
    const segments = [_]ast.PatternSegment{
        .{
            .edge = .{ .rel = .related_to },
            .right = .{ .var_name = "n", .kind = .function },
        },
        .{
            .edge = .{ .rel = .related_to },
            .right = .{ .var_name = "n", .kind = .file },
        },
    };
    const query = ast.Query{
        .pattern = .{ .start = .{ .var_name = "n" }, .segments = &segments },
        .returns = &.{.{ .variable = "n" }},
    };
    try std.testing.expectError(error.ConflictingVariableKind, check(std.testing.allocator, query));
}

test "type checker rejects text binding kind conflict with graph start" {
    const query = ast.Query{
        .text_pattern = .{ .query = "edge index", .var_name = "n", .kind = .task },
        .pattern = .{ .start = .{ .var_name = "n", .kind = .function }, .segments = &.{} },
        .returns = &.{.{ .score = .{ .var_name = "n" } }},
    };
    try std.testing.expectError(error.ConflictingVariableKind, check(std.testing.allocator, query));
}
