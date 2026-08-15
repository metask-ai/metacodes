const std = @import("std");
const format = @import("format.zig");
const checkpoint_store = @import("store.zig");

const magic = "TKGMUT1\n";
const version: u16 = 1;
const header_len: usize = 80;

pub const Operation = union(enum) {
    node_upsert: format.Node,
    node_delete: u64,
    edge_upsert: format.Edge,
    edge_delete: u64,
    edge_order_upsert: format.EdgeOrder,
    edge_order_delete: u64,
    property_upsert: format.Property,
    property_delete: struct { owner_type: u8, owner_id: u64, key_hash: u64 },
    catalog_replace: []const u8,
    schema_replace: []const u8,
    profiles_replace: []const u8,
};

pub const Prepared = struct {
    bytes: []u8,
    after: format.Snapshot,

    pub fn deinit(self: *Prepared, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
        self.after.deinitOwned(allocator);
        self.* = undefined;
    }
};

/// Prepare a complete mutation before durability. The returned state is fully
/// validated and its digest is embedded in the encoded transaction, allowing a
/// runtime to build all derived RAM indexes before appending the WAL record.
pub fn prepareAlloc(
    allocator: std.mem.Allocator,
    before: format.Snapshot,
    operations: []const Operation,
) !Prepared {
    if (operations.len == 0) return error.InvalidRecord;
    const before_digest = try checkpoint_store.canonicalDigestAlloc(allocator, before);
    var after = try applyOperationsAlloc(allocator, before, operations);
    errdefer after.deinitOwned(allocator);
    const after_digest = try checkpoint_store.canonicalDigestAlloc(allocator, after);
    const bytes = try encodeAlloc(allocator, before_digest, after_digest, operations);
    return .{ .bytes = bytes, .after = after };
}

pub fn encodeAlloc(
    allocator: std.mem.Allocator,
    before_digest: [32]u8,
    after_digest: [32]u8,
    operations: []const Operation,
) ![]u8 {
    if (operations.len == 0 or operations.len > std.math.maxInt(u32)) return error.InvalidRecord;
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.resize(allocator, header_len);
    @memset(out.items[0..header_len], 0);
    @memcpy(out.items[0..8], magic);
    std.mem.writeInt(u16, out.items[8..10], version, .little);
    std.mem.writeInt(u16, out.items[10..12], header_len, .little);
    std.mem.writeInt(u32, out.items[12..16], @intCast(operations.len), .little);
    @memcpy(out.items[16..48], &before_digest);
    @memcpy(out.items[48..80], &after_digest);
    for (operations) |operation| try encodeOperation(&out, allocator, operation);
    return out.toOwnedSlice(allocator);
}

/// Apply an encoded transaction atomically. `before` remains untouched on any
/// parse, semantic or digest failure; the caller owns the returned snapshot.
pub fn applyEncodedAlloc(
    allocator: std.mem.Allocator,
    before: format.Snapshot,
    bytes: []const u8,
) !format.Snapshot {
    if (bytes.len < header_len or !std.mem.eql(u8, bytes[0..8], magic)) return error.InvalidRecord;
    if (std.mem.readInt(u16, bytes[8..10], .little) != version) return error.UnsupportedVersion;
    if (std.mem.readInt(u16, bytes[10..12], .little) != header_len) return error.InvalidRecord;
    const operation_count = std.mem.readInt(u32, bytes[12..16], .little);
    if (operation_count == 0) return error.InvalidRecord;
    const expected_before = bytes[16..48].*;
    const expected_after = bytes[48..80].*;
    if (!std.mem.eql(u8, &try checkpoint_store.canonicalDigestAlloc(allocator, before), &expected_before)) return error.StateConflict;

    var reader = Reader{ .bytes = bytes, .pos = header_len };
    var state = try MutableState.clone(allocator, before);
    defer state.deinit();
    for (0..operation_count) |_| try state.applyDecoded(&reader);
    if (reader.pos != bytes.len) return error.InvalidRecord;
    var after = try state.finish();
    errdefer after.deinitOwned(allocator);
    if (!std.mem.eql(u8, &try checkpoint_store.canonicalDigestAlloc(allocator, after), &expected_after)) return error.DigestMismatch;
    return after;
}

fn applyOperationsAlloc(
    allocator: std.mem.Allocator,
    before: format.Snapshot,
    operations: []const Operation,
) !format.Snapshot {
    // `finish` moves the entity arrays and interns the surviving strings into
    // the snapshot's backing buffer, so tearing the state down afterwards
    // releases only working memory (including the string arena).
    var state = try MutableState.clone(allocator, before);
    defer state.deinit();
    for (operations) |operation| try state.apply(operation);
    return state.finish();
}

const MutableState = struct {
    allocator: std.mem.Allocator,
    /// All working strings (cloned source text, upserted values, catalog,
    /// schema, profiles) live in this arena and are never freed one by one;
    /// `finish` interns the survivors into the snapshot's backing buffer and
    /// `deinit` releases the arena wholesale. This keeps a mutation's small
    /// allocation count independent of store size.
    strings: std.heap.ArenaAllocator,
    nodes: std.ArrayList(format.Node),
    edges: std.ArrayList(format.Edge),
    edge_orders: std.ArrayList(format.EdgeOrder),
    properties: std.ArrayList(format.Property),
    catalog: []const u8,
    schema: []const u8,
    profiles: []const u8,

    fn clone(allocator: std.mem.Allocator, source: format.Snapshot) !MutableState {
        var strings = std.heap.ArenaAllocator.init(allocator);
        errdefer strings.deinit();
        var nodes = std.ArrayList(format.Node).empty;
        errdefer nodes.deinit(allocator);
        for (source.nodes) |node| {
            try nodes.append(allocator, .{
                .id = node.id,
                .kind = node.kind,
                .text = try strings.allocator().dupe(u8, node.text),
            });
        }
        var edges = std.ArrayList(format.Edge).empty;
        errdefer edges.deinit(allocator);
        try edges.appendSlice(allocator, source.edges);
        var edge_orders = std.ArrayList(format.EdgeOrder).empty;
        errdefer edge_orders.deinit(allocator);
        try edge_orders.appendSlice(allocator, source.edge_orders);
        var properties = std.ArrayList(format.Property).empty;
        errdefer properties.deinit(allocator);
        for (source.properties) |property| {
            var owned = property;
            if (property.value_kind == .string) owned.string_value = try strings.allocator().dupe(u8, property.string_value);
            try properties.append(allocator, owned);
        }
        const catalog = try strings.allocator().dupe(u8, source.catalog);
        const schema = try strings.allocator().dupe(u8, source.schema);
        const profiles = try strings.allocator().dupe(u8, source.profiles);
        return .{
            .allocator = allocator,
            .strings = strings,
            .nodes = nodes,
            .edges = edges,
            .edge_orders = edge_orders,
            .properties = properties,
            .catalog = catalog,
            .schema = schema,
            .profiles = profiles,
        };
    }

    fn deinit(self: *MutableState) void {
        self.nodes.deinit(self.allocator);
        self.edges.deinit(self.allocator);
        self.edge_orders.deinit(self.allocator);
        self.properties.deinit(self.allocator);
        self.strings.deinit();
        self.* = undefined;
    }

    fn finish(self: *MutableState) !format.Snapshot {
        std.mem.sort(format.Node, self.nodes.items, {}, nodeLessThan);
        std.mem.sort(format.Edge, self.edges.items, {}, edgeLessThan);
        std.mem.sort(format.EdgeOrder, self.edge_orders.items, {}, edgeOrderLessThan);
        std.mem.sort(format.Property, self.properties.items, {}, propertyLessThan);
        var arrays_owned = true;
        const nodes = try self.nodes.toOwnedSlice(self.allocator);
        errdefer if (arrays_owned) self.allocator.free(nodes);
        const edges = try self.edges.toOwnedSlice(self.allocator);
        errdefer if (arrays_owned) self.allocator.free(edges);
        const edge_orders = try self.edge_orders.toOwnedSlice(self.allocator);
        errdefer if (arrays_owned) self.allocator.free(edge_orders);
        const properties = try self.properties.toOwnedSlice(self.allocator);
        errdefer if (arrays_owned) self.allocator.free(properties);
        var snapshot = format.Snapshot{
            .nodes = nodes,
            .edges = edges,
            .edge_orders = edge_orders,
            .properties = properties,
            .catalog = self.catalog,
            .schema = self.schema,
            .profiles = self.profiles,
        };
        // The strings still live in this state's arena; the snapshot becomes
        // resident state, so give it one backing buffer of its own.
        try internArenaStrings(self.allocator, &snapshot);
        arrays_owned = false;
        errdefer snapshot.deinitOwned(self.allocator);
        self.catalog = &.{};
        self.schema = &.{};
        self.profiles = &.{};
        // Re-encoding is the canonical cross-reference and uniqueness oracle.
        _ = try checkpoint_store.canonicalDigestAlloc(self.allocator, snapshot);
        return snapshot;
    }

    fn apply(self: *MutableState, operation: Operation) !void {
        switch (operation) {
            .node_upsert => |node| try self.upsertNode(node),
            .node_delete => |id| try self.deleteNode(id),
            .edge_upsert => |edge| try self.upsertEdge(edge),
            .edge_delete => |id| try self.deleteEdge(id),
            .edge_order_upsert => |order| try self.upsertEdgeOrder(order),
            .edge_order_delete => |id| try self.deleteEdgeOrder(id),
            .property_upsert => |property| try self.upsertProperty(property),
            .property_delete => |key| try self.deleteProperty(key.owner_type, key.owner_id, key.key_hash),
            .catalog_replace => |value| try self.replaceBytes(&self.catalog, value),
            .schema_replace => |value| try self.replaceBytes(&self.schema, value),
            .profiles_replace => |value| try self.replaceBytes(&self.profiles, value),
        }
    }

    fn applyDecoded(self: *MutableState, reader: *Reader) !void {
        const opcode = try reader.byte();
        switch (opcode) {
            1 => try self.upsertNode(.{ .id = try reader.varint(), .kind = std.math.cast(u16, try reader.varint()) orelse return error.InvalidRecord, .text = try reader.bytesValue() }),
            2 => try self.deleteNode(try reader.varint()),
            3 => try self.upsertEdge(.{ .id = try reader.varint(), .src = try reader.varint(), .rel = std.math.cast(u16, try reader.varint()) orelse return error.InvalidRecord, .dst = try reader.varint() }),
            4 => try self.deleteEdge(try reader.varint()),
            5 => try self.upsertEdgeOrder(.{ .edge_id = try reader.varint(), .order_key = try reader.varint() }),
            6 => try self.deleteEdgeOrder(try reader.varint()),
            7 => {
                const owner_type = try reader.byte();
                const owner_id = try reader.varint();
                const key_hash = try reader.fixedU64();
                const value_kind: format.PropertyValueKind = switch (try reader.byte()) {
                    1 => .string,
                    2 => .uint,
                    else => return error.InvalidRecord,
                };
                var property = format.Property{ .owner_type = owner_type, .owner_id = owner_id, .key_hash = key_hash, .value_kind = value_kind };
                if (value_kind == .string) property.string_value = try reader.bytesValue() else property.uint_value = try reader.varint();
                try self.upsertProperty(property);
            },
            8 => try self.deleteProperty(try reader.byte(), try reader.varint(), try reader.fixedU64()),
            9 => try self.replaceBytes(&self.catalog, try reader.bytesValue()),
            10 => try self.replaceBytes(&self.schema, try reader.bytesValue()),
            11 => try self.replaceBytes(&self.profiles, try reader.bytesValue()),
            else => return error.InvalidRecord,
        }
    }

    fn upsertNode(self: *MutableState, node: format.Node) !void {
        if (node.id == 0 or node.id == std.math.maxInt(u64)) return error.InvalidRecord;
        const text = try self.strings.allocator().dupe(u8, node.text);
        for (self.nodes.items) |*existing| if (existing.id == node.id) {
            existing.* = .{ .id = node.id, .kind = node.kind, .text = text };
            return;
        };
        try self.nodes.append(self.allocator, .{ .id = node.id, .kind = node.kind, .text = text });
    }

    fn deleteNode(self: *MutableState, id: u64) !void {
        for (self.nodes.items, 0..) |node, index| if (node.id == id) {
            _ = self.nodes.orderedRemove(index);
            return;
        };
        return error.NotFound;
    }

    fn upsertEdge(self: *MutableState, edge: format.Edge) !void {
        if (edge.id == 0 or edge.id == std.math.maxInt(u64)) return error.InvalidRecord;
        for (self.edges.items) |*existing| if (existing.id == edge.id) {
            existing.* = edge;
            return;
        };
        try self.edges.append(self.allocator, edge);
    }

    fn deleteEdge(self: *MutableState, id: u64) !void {
        for (self.edges.items, 0..) |edge, index| if (edge.id == id) {
            _ = self.edges.orderedRemove(index);
            return;
        };
        return error.NotFound;
    }

    fn upsertEdgeOrder(self: *MutableState, order: format.EdgeOrder) !void {
        for (self.edge_orders.items) |*existing| if (existing.edge_id == order.edge_id) {
            existing.* = order;
            return;
        };
        try self.edge_orders.append(self.allocator, order);
    }

    fn deleteEdgeOrder(self: *MutableState, edge_id: u64) !void {
        for (self.edge_orders.items, 0..) |order, index| if (order.edge_id == edge_id) {
            _ = self.edge_orders.orderedRemove(index);
            return;
        };
        return error.NotFound;
    }

    fn sameProperty(property: format.Property, owner_type: u8, owner_id: u64, key_hash: u64) bool {
        return property.owner_type == owner_type and property.owner_id == owner_id and property.key_hash == key_hash;
    }

    fn upsertProperty(self: *MutableState, property: format.Property) !void {
        if (property.owner_type != 1 and property.owner_type != 2) return error.InvalidRecord;
        var owned = property;
        if (property.value_kind == .string) owned.string_value = try self.strings.allocator().dupe(u8, property.string_value);
        for (self.properties.items) |*existing| if (sameProperty(existing.*, property.owner_type, property.owner_id, property.key_hash)) {
            existing.* = owned;
            return;
        };
        try self.properties.append(self.allocator, owned);
    }

    fn deleteProperty(self: *MutableState, owner_type: u8, owner_id: u64, key_hash: u64) !void {
        for (self.properties.items, 0..) |property, index| if (sameProperty(property, owner_type, owner_id, key_hash)) {
            _ = self.properties.orderedRemove(index);
            return;
        };
        return error.NotFound;
    }

    fn replaceBytes(self: *MutableState, target: *[]const u8, value: []const u8) !void {
        target.* = try self.strings.allocator().dupe(u8, value);
    }
};

/// Copy every string of a snapshot whose strings are currently arena-owned
/// into one backing buffer, without freeing the originals. This keeps the
/// resident allocation count of a mutation result independent of node and
/// property counts.
fn internArenaStrings(allocator: std.mem.Allocator, snapshot: *format.Snapshot) !void {
    if (snapshot.backing != null) return;
    var total: usize = 0;
    for (snapshot.nodes) |node| total += node.text.len;
    for (snapshot.properties) |property| {
        if (property.value_kind == .string) total += property.string_value.len;
    }
    total += snapshot.catalog.len + snapshot.schema.len + snapshot.profiles.len;
    const blob = try allocator.alloc(u8, total);
    // From here on nothing can fail.
    var offset: usize = 0;
    for (snapshot.nodes) |*node| {
        const len = node.text.len;
        @memcpy(blob[offset .. offset + len], node.text);
        node.text = blob[offset .. offset + len];
        offset += len;
    }
    for (snapshot.properties) |*property| {
        if (property.value_kind != .string) continue;
        const len = property.string_value.len;
        @memcpy(blob[offset .. offset + len], property.string_value);
        property.string_value = blob[offset .. offset + len];
        offset += len;
    }
    inline for (.{ "catalog", "schema", "profiles" }) |field| {
        const value = @field(snapshot, field);
        @memcpy(blob[offset .. offset + value.len], value);
        @field(snapshot, field) = blob[offset .. offset + value.len];
        offset += value.len;
    }
    snapshot.backing = blob;
}

fn nodeLessThan(_: void, left: format.Node, right: format.Node) bool {
    return left.id < right.id;
}

fn edgeLessThan(_: void, left: format.Edge, right: format.Edge) bool {
    return left.rel < right.rel or (left.rel == right.rel and left.id < right.id);
}

fn edgeOrderLessThan(_: void, left: format.EdgeOrder, right: format.EdgeOrder) bool {
    return left.edge_id < right.edge_id;
}

fn propertyLessThan(_: void, left: format.Property, right: format.Property) bool {
    if (left.key_hash != right.key_hash) return left.key_hash < right.key_hash;
    if (left.owner_type != right.owner_type) return left.owner_type < right.owner_type;
    return left.owner_id < right.owner_id;
}

fn encodeOperation(out: *std.ArrayList(u8), allocator: std.mem.Allocator, operation: Operation) !void {
    switch (operation) {
        .node_upsert => |node| {
            try out.append(allocator, 1);
            try appendVarint(out, allocator, node.id);
            try appendVarint(out, allocator, node.kind);
            try appendBytes(out, allocator, node.text);
        },
        .node_delete => |id| {
            try out.append(allocator, 2);
            try appendVarint(out, allocator, id);
        },
        .edge_upsert => |edge| {
            try out.append(allocator, 3);
            try appendVarint(out, allocator, edge.id);
            try appendVarint(out, allocator, edge.src);
            try appendVarint(out, allocator, edge.rel);
            try appendVarint(out, allocator, edge.dst);
        },
        .edge_delete => |id| {
            try out.append(allocator, 4);
            try appendVarint(out, allocator, id);
        },
        .edge_order_upsert => |order| {
            try out.append(allocator, 5);
            try appendVarint(out, allocator, order.edge_id);
            try appendVarint(out, allocator, order.order_key);
        },
        .edge_order_delete => |id| {
            try out.append(allocator, 6);
            try appendVarint(out, allocator, id);
        },
        .property_upsert => |property| {
            try out.append(allocator, 7);
            try out.append(allocator, property.owner_type);
            try appendVarint(out, allocator, property.owner_id);
            var key: [8]u8 = undefined;
            std.mem.writeInt(u64, &key, property.key_hash, .little);
            try out.appendSlice(allocator, &key);
            try out.append(allocator, @intFromEnum(property.value_kind));
            switch (property.value_kind) {
                .string => try appendBytes(out, allocator, property.string_value),
                .uint => try appendVarint(out, allocator, property.uint_value),
            }
        },
        .property_delete => |key| {
            try out.append(allocator, 8);
            try out.append(allocator, key.owner_type);
            try appendVarint(out, allocator, key.owner_id);
            var hash: [8]u8 = undefined;
            std.mem.writeInt(u64, &hash, key.key_hash, .little);
            try out.appendSlice(allocator, &hash);
        },
        .catalog_replace => |value| {
            try out.append(allocator, 9);
            try appendBytes(out, allocator, value);
        },
        .schema_replace => |value| {
            try out.append(allocator, 10);
            try appendBytes(out, allocator, value);
        },
        .profiles_replace => |value| {
            try out.append(allocator, 11);
            try appendBytes(out, allocator, value);
        },
    }
}

fn appendVarint(out: *std.ArrayList(u8), allocator: std.mem.Allocator, input: u64) !void {
    var value = input;
    while (value >= 0x80) : (value >>= 7) try out.append(allocator, @intCast((value & 0x7f) | 0x80));
    try out.append(allocator, @intCast(value));
}

fn appendBytes(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: []const u8) !void {
    try appendVarint(out, allocator, @intCast(value.len));
    try out.appendSlice(allocator, value);
}

const Reader = struct {
    bytes: []const u8,
    pos: usize,

    fn take(self: *Reader, count: usize) ![]const u8 {
        const end = std.math.add(usize, self.pos, count) catch return error.InvalidRecord;
        if (end > self.bytes.len) return error.InvalidRecord;
        defer self.pos = end;
        return self.bytes[self.pos..end];
    }

    fn byte(self: *Reader) !u8 {
        return (try self.take(1))[0];
    }

    fn fixedU64(self: *Reader) !u64 {
        return std.mem.readInt(u64, (try self.take(8))[0..8], .little);
    }

    fn varint(self: *Reader) !u64 {
        var value: u64 = 0;
        var shift: u6 = 0;
        for (0..10) |index| {
            const next = try self.byte();
            if (index == 9 and next > 1) return error.InvalidRecord;
            value |= @as(u64, next & 0x7f) << shift;
            if ((next & 0x80) == 0) return value;
            shift += 7;
        }
        return error.InvalidRecord;
    }

    fn bytesValue(self: *Reader) ![]const u8 {
        const count = std.math.cast(usize, try self.varint()) orelse return error.RecordTooLarge;
        return self.take(count);
    }
};

test "canonical mutation round trips all state owners and rejects conflicts" {
    var nodes = [_]format.Node{
        .{ .id = 1, .kind = 10, .text = "before" },
        .{ .id = 2, .kind = 13, .text = "target" },
    };
    var edges = [_]format.Edge{.{ .id = 3, .src = 1, .rel = 11, .dst = 2 }};
    var properties = [_]format.Property{.{ .owner_type = 1, .owner_id = 1, .key_hash = 7, .value_kind = .string, .string_value = "open" }};
    const before = format.Snapshot{ .nodes = &nodes, .edges = &edges, .properties = &properties, .catalog = "cat-1" };
    const operations = [_]Operation{
        .{ .node_upsert = .{ .id = 1, .kind = 10, .text = "after" } },
        .{ .edge_order_upsert = .{ .edge_id = 3, .order_key = 1024 } },
        .{ .property_upsert = .{ .owner_type = 1, .owner_id = 1, .key_hash = 7, .value_kind = .string, .string_value = "claimed" } },
        .{ .catalog_replace = "cat-2" },
    };
    var prepared = try prepareAlloc(std.testing.allocator, before, &operations);
    defer prepared.deinit(std.testing.allocator);
    var replayed = try applyEncodedAlloc(std.testing.allocator, before, prepared.bytes);
    defer replayed.deinitOwned(std.testing.allocator);
    try std.testing.expectEqualStrings("after", replayed.nodes[0].text);
    try std.testing.expectEqual(@as(u64, 1024), replayed.edge_orders[0].order_key);
    try std.testing.expectEqualStrings("claimed", replayed.properties[0].string_value);
    try std.testing.expectEqualStrings("cat-2", replayed.catalog);
    try std.testing.expectEqualSlices(u8, &try checkpoint_store.canonicalDigestAlloc(std.testing.allocator, prepared.after), &try checkpoint_store.canonicalDigestAlloc(std.testing.allocator, replayed));

    var conflicting = before;
    conflicting.catalog = "different";
    try std.testing.expectError(error.StateConflict, applyEncodedAlloc(std.testing.allocator, conflicting, prepared.bytes));
}
