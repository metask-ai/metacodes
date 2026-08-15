const std = @import("std");
const format = @import("format.zig");
const mutation = @import("mutation.zig");

const PropertyIdentity = struct {
    owner_type: u8,
    owner_id: u64,
    key_hash: u64,
};

/// Build the smallest canonical operation set that turns `before` into
/// `after`. Returned string slices borrow from `after`; only the operation
/// array itself is owned by the caller.
///
/// The compact Runtime uses this owner to collapse an append-only WAL without
/// rewriting its immutable checkpoint. Identity maps keep the work linear in
/// the snapshot size, including property-heavy agent-memory Stores.
pub fn operationsAlloc(
    allocator: std.mem.Allocator,
    before: format.Snapshot,
    after: format.Snapshot,
) ![]mutation.Operation {
    var before_nodes = std.AutoHashMap(u64, usize).init(allocator);
    defer before_nodes.deinit();
    var after_nodes = std.AutoHashMap(u64, usize).init(allocator);
    defer after_nodes.deinit();
    var before_edges = std.AutoHashMap(u64, usize).init(allocator);
    defer before_edges.deinit();
    var after_edges = std.AutoHashMap(u64, usize).init(allocator);
    defer after_edges.deinit();
    var before_orders = std.AutoHashMap(u64, usize).init(allocator);
    defer before_orders.deinit();
    var after_orders = std.AutoHashMap(u64, usize).init(allocator);
    defer after_orders.deinit();
    var before_properties = std.AutoHashMap(PropertyIdentity, usize).init(allocator);
    defer before_properties.deinit();
    var after_properties = std.AutoHashMap(PropertyIdentity, usize).init(allocator);
    defer after_properties.deinit();

    try indexNodes(&before_nodes, before.nodes);
    try indexNodes(&after_nodes, after.nodes);
    try indexEdges(&before_edges, before.edges);
    try indexEdges(&after_edges, after.edges);
    try indexOrders(&before_orders, before.edge_orders);
    try indexOrders(&after_orders, after.edge_orders);
    try indexProperties(&before_properties, before.properties);
    try indexProperties(&after_properties, after.properties);

    var operations = std.ArrayList(mutation.Operation).empty;
    errdefer operations.deinit(allocator);

    // Remove dependent records before their owners. MutableState validates the
    // final graph atomically, while this order remains suitable for a future
    // streaming mutation adapter.
    for (before.edge_orders) |order| if (!after_orders.contains(order.edge_id)) {
        try operations.append(allocator, .{ .edge_order_delete = order.edge_id });
    };
    for (before.properties) |property| {
        const identity = propertyIdentity(property);
        if (!after_properties.contains(identity)) try operations.append(allocator, .{
            .property_delete = .{
                .owner_type = property.owner_type,
                .owner_id = property.owner_id,
                .key_hash = property.key_hash,
            },
        });
    }
    for (before.edges) |edge| if (!after_edges.contains(edge.id)) {
        try operations.append(allocator, .{ .edge_delete = edge.id });
    };
    for (before.nodes) |node| if (!after_nodes.contains(node.id)) {
        try operations.append(allocator, .{ .node_delete = node.id });
    };

    for (after.nodes) |node| {
        const changed = if (before_nodes.get(node.id)) |index|
            !nodeEqual(before.nodes[index], node)
        else
            true;
        if (changed) try operations.append(allocator, .{ .node_upsert = node });
    }
    for (after.edges) |edge| {
        const changed = if (before_edges.get(edge.id)) |index|
            !edgeEqual(before.edges[index], edge)
        else
            true;
        if (changed) try operations.append(allocator, .{ .edge_upsert = edge });
    }
    for (after.edge_orders) |order| {
        const changed = if (before_orders.get(order.edge_id)) |index|
            before.edge_orders[index].order_key != order.order_key
        else
            true;
        if (changed) try operations.append(allocator, .{ .edge_order_upsert = order });
    }
    for (after.properties) |property| {
        const changed = if (before_properties.get(propertyIdentity(property))) |index|
            !propertyEqual(before.properties[index], property)
        else
            true;
        if (changed) try operations.append(allocator, .{ .property_upsert = property });
    }
    if (!std.mem.eql(u8, before.catalog, after.catalog)) {
        try operations.append(allocator, .{ .catalog_replace = after.catalog });
    }
    if (!std.mem.eql(u8, before.schema, after.schema)) {
        try operations.append(allocator, .{ .schema_replace = after.schema });
    }
    if (!std.mem.eql(u8, before.profiles, after.profiles)) {
        try operations.append(allocator, .{ .profiles_replace = after.profiles });
    }
    return operations.toOwnedSlice(allocator);
}

fn indexNodes(map: *std.AutoHashMap(u64, usize), values: []const format.Node) !void {
    try map.ensureTotalCapacity(std.math.cast(u32, values.len) orelse return error.RecordTooLarge);
    for (values, 0..) |value, index| {
        if (map.contains(value.id)) return error.InvalidRecord;
        map.putAssumeCapacityNoClobber(value.id, index);
    }
}

fn indexEdges(map: *std.AutoHashMap(u64, usize), values: []const format.Edge) !void {
    try map.ensureTotalCapacity(std.math.cast(u32, values.len) orelse return error.RecordTooLarge);
    for (values, 0..) |value, index| {
        if (map.contains(value.id)) return error.InvalidRecord;
        map.putAssumeCapacityNoClobber(value.id, index);
    }
}

fn indexOrders(map: *std.AutoHashMap(u64, usize), values: []const format.EdgeOrder) !void {
    try map.ensureTotalCapacity(std.math.cast(u32, values.len) orelse return error.RecordTooLarge);
    for (values, 0..) |value, index| {
        if (map.contains(value.edge_id)) return error.InvalidRecord;
        map.putAssumeCapacityNoClobber(value.edge_id, index);
    }
}

fn indexProperties(map: *std.AutoHashMap(PropertyIdentity, usize), values: []const format.Property) !void {
    try map.ensureTotalCapacity(std.math.cast(u32, values.len) orelse return error.RecordTooLarge);
    for (values, 0..) |value, index| {
        const identity = propertyIdentity(value);
        if (map.contains(identity)) return error.InvalidRecord;
        map.putAssumeCapacityNoClobber(identity, index);
    }
}

fn propertyIdentity(property: format.Property) PropertyIdentity {
    return .{
        .owner_type = property.owner_type,
        .owner_id = property.owner_id,
        .key_hash = property.key_hash,
    };
}

fn nodeEqual(left: format.Node, right: format.Node) bool {
    return left.id == right.id and left.kind == right.kind and std.mem.eql(u8, left.text, right.text);
}

fn edgeEqual(left: format.Edge, right: format.Edge) bool {
    return left.id == right.id and left.src == right.src and left.rel == right.rel and left.dst == right.dst;
}

fn propertyEqual(left: format.Property, right: format.Property) bool {
    if (left.owner_type != right.owner_type or left.owner_id != right.owner_id or
        left.key_hash != right.key_hash or left.value_kind != right.value_kind)
    {
        return false;
    }
    return switch (left.value_kind) {
        .string => std.mem.eql(u8, left.string_value, right.string_value),
        .uint => left.uint_value == right.uint_value,
    };
}

test "checkpoint delta emits only changed canonical owners" {
    var before_nodes = [_]format.Node{
        .{ .id = 1, .kind = 10, .text = "one" },
        .{ .id = 2, .kind = 10, .text = "remove" },
    };
    var before_edges = [_]format.Edge{.{ .id = 3, .src = 1, .rel = 4, .dst = 2 }};
    var before_orders = [_]format.EdgeOrder{.{ .edge_id = 3, .order_key = 10 }};
    var before_properties = [_]format.Property{.{
        .owner_type = 1,
        .owner_id = 1,
        .key_hash = 7,
        .value_kind = .string,
        .string_value = "before",
    }};
    const before = format.Snapshot{
        .nodes = &before_nodes,
        .edges = &before_edges,
        .edge_orders = &before_orders,
        .properties = &before_properties,
        .catalog = "cat-1",
    };

    var after_nodes = [_]format.Node{
        .{ .id = 1, .kind = 10, .text = "one changed" },
        .{ .id = 4, .kind = 13, .text = "added" },
    };
    var after_edges = [_]format.Edge{.{ .id = 5, .src = 1, .rel = 4, .dst = 4 }};
    var after_properties = [_]format.Property{.{
        .owner_type = 1,
        .owner_id = 1,
        .key_hash = 7,
        .value_kind = .string,
        .string_value = "after",
    }};
    const after = format.Snapshot{
        .nodes = &after_nodes,
        .edges = &after_edges,
        .properties = &after_properties,
        .catalog = "cat-2",
    };
    const operations = try operationsAlloc(std.testing.allocator, before, after);
    defer std.testing.allocator.free(operations);
    try std.testing.expectEqual(@as(usize, 8), operations.len);
    var prepared = try mutation.prepareAlloc(std.testing.allocator, before, operations);
    defer prepared.deinit(std.testing.allocator);
    const expected = try @import("store.zig").canonicalDigestAlloc(std.testing.allocator, after);
    const actual = try @import("store.zig").canonicalDigestAlloc(std.testing.allocator, prepared.after);
    try std.testing.expectEqualSlices(u8, &expected, &actual);
}

test "checkpoint delta collapses semantic no-op to zero operations" {
    var nodes = [_]format.Node{.{ .id = 1, .kind = 10, .text = "same" }};
    const snapshot = format.Snapshot{ .nodes = &nodes, .edges = &.{}, .properties = &.{} };
    const operations = try operationsAlloc(std.testing.allocator, snapshot, snapshot);
    defer std.testing.allocator.free(operations);
    try std.testing.expectEqual(@as(usize, 0), operations.len);
}
