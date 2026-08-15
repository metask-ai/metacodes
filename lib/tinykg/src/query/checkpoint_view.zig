const std = @import("std");
const format = @import("../checkpoint/format.zig");
const storage = @import("../storage.zig");

pub const CheckpointProperty = format.Property;
pub const CheckpointEdgeOrder = format.EdgeOrder;

/// Allocation-free point lookups over decoded canonical checkpoint slices.
///
/// The checkpoint codec guarantees both slices are sorted. This view borrows
/// them without exposing the checkpoint repository, codec, or runtime to
/// query execution.
pub const CheckpointView = struct {
    properties: []const CheckpointProperty,
    edge_orders: []const CheckpointEdgeOrder,

    pub fn init(
        properties: []const CheckpointProperty,
        edge_orders: []const CheckpointEdgeOrder,
    ) !CheckpointView {
        var previous_property: ?PropertyKey = null;
        for (properties) |entry| {
            const key = PropertyKey.fromProperty(entry);
            if (previous_property) |previous| {
                if (!propertyKeyLessThan(previous, key)) return error.InvalidRecord;
            }
            previous_property = key;
        }
        var previous_edge_id: u64 = 0;
        for (edge_orders) |order| {
            if (order.edge_id <= previous_edge_id) return error.InvalidRecord;
            previous_edge_id = order.edge_id;
        }
        return .{ .properties = properties, .edge_orders = edge_orders };
    }

    pub fn nodeProperty(self: CheckpointView, node_id: u64, key: []const u8) ?*const CheckpointProperty {
        return self.property(1, node_id, storage.propertyKeyHashForLookup(key));
    }

    pub fn edgeProperty(self: CheckpointView, edge_id: u64, key: []const u8) ?*const CheckpointProperty {
        return self.property(2, edge_id, storage.propertyKeyHashForLookup(key));
    }

    pub fn property(self: CheckpointView, owner_type: u8, owner_id: u64, key_hash: u64) ?*const CheckpointProperty {
        const needle = PropertyKey{ .key_hash = key_hash, .owner_type = owner_type, .owner_id = owner_id };
        var low: usize = 0;
        var high: usize = self.properties.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            const current = PropertyKey.fromProperty(self.properties[middle]);
            if (propertyKeyLessThan(current, needle)) {
                low = middle + 1;
            } else {
                high = middle;
            }
        }
        if (low == self.properties.len) return null;
        const found = &self.properties[low];
        return if (found.key_hash == key_hash and found.owner_type == owner_type and found.owner_id == owner_id) found else null;
    }

    pub fn propertyRange(self: CheckpointView, key: []const u8) []const CheckpointProperty {
        const key_hash = storage.propertyKeyHashForLookup(key);
        var low: usize = 0;
        var high: usize = self.properties.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (self.properties[middle].key_hash < key_hash) {
                low = middle + 1;
            } else {
                high = middle;
            }
        }
        const start = low;
        high = self.properties.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (self.properties[middle].key_hash <= key_hash) {
                low = middle + 1;
            } else {
                high = middle;
            }
        }
        return self.properties[start..low];
    }

    pub fn edgeOrder(self: CheckpointView, edge_id: u64) ?u64 {
        var low: usize = 0;
        var high: usize = self.edge_orders.len;
        while (low < high) {
            const middle = low + (high - low) / 2;
            if (self.edge_orders[middle].edge_id < edge_id) {
                low = middle + 1;
            } else {
                high = middle;
            }
        }
        if (low == self.edge_orders.len or self.edge_orders[low].edge_id != edge_id) return null;
        return self.edge_orders[low].order_key;
    }
};

const PropertyKey = struct {
    key_hash: u64,
    owner_type: u8,
    owner_id: u64,

    fn fromProperty(property: CheckpointProperty) PropertyKey {
        return .{
            .key_hash = property.key_hash,
            .owner_type = property.owner_type,
            .owner_id = property.owner_id,
        };
    }
};

fn propertyKeyLessThan(left: PropertyKey, right: PropertyKey) bool {
    if (left.key_hash != right.key_hash) return left.key_hash < right.key_hash;
    if (left.owner_type != right.owner_type) return left.owner_type < right.owner_type;
    return left.owner_id < right.owner_id;
}

test "checkpoint query view resolves typed properties and ordered edges" {
    const status_hash = storage.propertyKeyHashForLookup("status");
    const rank_hash = storage.propertyKeyHashForLookup("rank");
    var properties = [_]CheckpointProperty{
        .{ .owner_type = 1, .owner_id = 7, .key_hash = @min(status_hash, rank_hash), .value_kind = .uint, .uint_value = 9 },
        .{ .owner_type = 1, .owner_id = 7, .key_hash = @max(status_hash, rank_hash), .value_kind = .string, .string_value = "open" },
    };
    if (status_hash < rank_hash) {
        properties[0] = .{ .owner_type = 1, .owner_id = 7, .key_hash = status_hash, .value_kind = .string, .string_value = "open" };
        properties[1] = .{ .owner_type = 1, .owner_id = 7, .key_hash = rank_hash, .value_kind = .uint, .uint_value = 9 };
    }
    var orders = [_]CheckpointEdgeOrder{
        .{ .edge_id = 3, .order_key = 1024 },
        .{ .edge_id = 8, .order_key = 2048 },
    };
    const view = try CheckpointView.init(&properties, &orders);
    try std.testing.expectEqualStrings("open", view.nodeProperty(7, "status").?.string_value);
    try std.testing.expectEqual(@as(u64, 9), view.nodeProperty(7, "rank").?.uint_value);
    try std.testing.expect(view.nodeProperty(8, "status") == null);
    try std.testing.expectEqual(@as(?u64, 2048), view.edgeOrder(8));
    try std.testing.expectEqual(@as(?u64, null), view.edgeOrder(9));
}

test "checkpoint query view rejects duplicate property owners" {
    const key_hash = storage.propertyKeyHashForLookup("status");
    var properties = [_]CheckpointProperty{
        .{ .owner_type = 1, .owner_id = 7, .key_hash = key_hash, .value_kind = .string, .string_value = "open" },
        .{ .owner_type = 1, .owner_id = 7, .key_hash = key_hash, .value_kind = .string, .string_value = "claimed" },
    };
    try std.testing.expectError(error.InvalidRecord, CheckpointView.init(&properties, &.{}));
}
