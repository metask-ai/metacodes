const std = @import("std");
const core = @import("../core.zig");

pub const Var = []const u8;

pub const NodePattern = struct {
    var_name: Var,
    kind: ?core.NodeKind = null,
    type_label: ?[]const u8 = null,
};

pub const EdgeDirection = enum {
    outgoing,
    incoming,
    undirected,
};

pub const EdgePattern = struct {
    var_name: ?Var = null,
    rel: ?core.RelKind = null,
    rel_label: ?[]const u8 = null,
    direction: EdgeDirection = .outgoing,
    min_hops: u8 = 1,
    max_hops: u8 = 1,
};

pub const PatternSegment = struct {
    edge: EdgePattern,
    right: NodePattern,
};

pub const Pattern = struct {
    start: NodePattern,
    segments: []const PatternSegment,

    pub fn isNodeOnly(self: Pattern) bool {
        return self.segments.len == 0;
    }
};

pub const TextPattern = struct {
    query: []const u8,
    var_name: Var,
    kind: ?core.NodeKind = null,
    type_label: ?[]const u8 = null,
};

pub const PredicateOperator = enum {
    eq,
    lt,
    lte,
    gt,
    gte,
};

pub const Predicate = struct {
    var_name: Var,
    property: []const u8,
    op: PredicateOperator = .eq,
    value: []const u8,
};

pub const OrderDirection = enum {
    asc,
    desc,
};

pub const OrderBy = struct {
    var_name: Var,
    property: []const u8,
    direction: OrderDirection = .asc,
};

pub const Projection = union(enum) {
    variable: Var,
    property: struct {
        var_name: Var,
        property: []const u8,
    },
    path: struct {
        from_var: Var,
        to_var: Var,
    },
    reachable: struct {
        from_var: Var,
        to_var: Var,
        rel: core.RelKind,
    },
    context: struct {
        var_name: Var,
    },
    score: struct {
        var_name: Var,
    },
};

pub const Query = struct {
    pattern: Pattern,
    text_pattern: ?TextPattern = null,
    where_predicates: []const Predicate = &.{},
    returns: []const Projection,
    order_by: ?OrderBy = null,
    limit: ?usize = null,
    owned_strings: []const []u8 = &.{},
};

pub fn freeQuery(allocator: std.mem.Allocator, query: Query) void {
    for (query.owned_strings) |string| allocator.free(string);
    if (query.owned_strings.len != 0) allocator.free(query.owned_strings);
    allocator.free(query.pattern.segments);
    allocator.free(query.where_predicates);
    allocator.free(query.returns);
}

test "AST can represent node pattern query" {
    const returns = [_]Projection{.{ .variable = "n" }};
    const query = Query{
        .pattern = .{ .start = .{ .var_name = "n", .kind = .file }, .segments = &.{} },
        .returns = &returns,
    };
    try std.testing.expectEqual(core.NodeKind.file, query.pattern.start.kind.?);
    try std.testing.expect(query.pattern.isNodeOnly());
}
