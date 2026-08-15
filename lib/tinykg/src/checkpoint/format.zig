const std = @import("std");

pub const header_len: usize = 256;
pub const current_version: u16 = 2;
pub const codec_zstd: u8 = 1;
pub const logical_edge_bytes: u64 = 16;
pub const max_payload_bytes: u64 = 64 * 1024 * 1024 * 1024;

const file_magic = "TKGCKP1\n";
const payload_magic = "TKGPAY2\n";

pub const Node = struct {
    id: u64,
    kind: u16,
    text: []const u8,
};

pub const Edge = struct {
    id: u64,
    src: u64,
    rel: u16,
    dst: u64,
};

/// Canonical ordered-edge semantics. `src` and `rel` are derived from the
/// referenced edge during restore, so persisting them again would charge the
/// checkpoint for redundant index material.
pub const EdgeOrder = struct {
    edge_id: u64,
    order_key: u64,
};

pub const PropertyValueKind = enum(u8) {
    string = 1,
    uint = 2,
};

pub const Property = struct {
    owner_type: u8,
    owner_id: u64,
    key_hash: u64,
    value_kind: PropertyValueKind,
    string_value: []const u8 = &.{},
    uint_value: u64 = 0,
};

pub const Snapshot = struct {
    nodes: []Node,
    edges: []Edge,
    edge_orders: []EdgeOrder = &.{},
    properties: []Property,
    catalog: []const u8 = &.{},
    schema: []const u8 = &.{},
    profiles: []const u8 = &.{},
    /// When set, every string in this snapshot (node text, string property
    /// values, catalog, schema, profiles) is a slice into this single decoded
    /// payload buffer instead of an individual allocation. `deinitOwned`
    /// releases the buffer and the entity arrays only.
    backing: ?[]const u8 = null,

    pub fn deinitOwned(self: *Snapshot, allocator: std.mem.Allocator) void {
        if (self.backing) |backing| {
            allocator.free(backing);
        } else {
            for (self.nodes) |node| allocator.free(node.text);
            for (self.properties) |property| {
                if (property.value_kind == .string) allocator.free(property.string_value);
            }
            allocator.free(self.catalog);
            allocator.free(self.schema);
            allocator.free(self.profiles);
        }
        allocator.free(self.nodes);
        allocator.free(self.edges);
        allocator.free(self.edge_orders);
        allocator.free(self.properties);
        self.* = .{ .nodes = &.{}, .edges = &.{}, .properties = &.{} };
    }
};

pub const Header = struct {
    codec: u8 = codec_zstd,
    window_log: u8,
    uncompressed_bytes: u64,
    compressed_bytes: u64,
    logical_content_bytes: u64,
    node_count: u64,
    edge_count: u64,
    property_count: u64,
    catalog_bytes: u64,
    schema_bytes: u64,
    profile_bytes: u64,
    edge_order_count: u64,
    payload_digest: [32]u8,
    semantic_digest: [32]u8,
    catalog_digest: [32]u8,
    schema_digest: [32]u8,
    profile_digest: [32]u8,

    pub fn encode(self: Header, out: *[header_len]u8) !void {
        try self.validate();
        @memset(out, 0);
        @memcpy(out[0..8], file_magic);
        std.mem.writeInt(u16, out[8..10], current_version, .little);
        std.mem.writeInt(u16, out[10..12], header_len, .little);
        out[12] = self.codec;
        out[13] = 0;
        out[14] = self.window_log;
        out[15] = 0;
        std.mem.writeInt(u64, out[16..24], self.uncompressed_bytes, .little);
        std.mem.writeInt(u64, out[24..32], self.compressed_bytes, .little);
        std.mem.writeInt(u64, out[32..40], self.logical_content_bytes, .little);
        std.mem.writeInt(u64, out[40..48], self.node_count, .little);
        std.mem.writeInt(u64, out[48..56], self.edge_count, .little);
        std.mem.writeInt(u64, out[56..64], self.property_count, .little);
        std.mem.writeInt(u64, out[64..72], self.catalog_bytes, .little);
        std.mem.writeInt(u64, out[72..80], self.schema_bytes, .little);
        std.mem.writeInt(u64, out[80..88], self.profile_bytes, .little);
        @memcpy(out[88..120], &self.payload_digest);
        @memcpy(out[120..152], &self.semantic_digest);
        @memcpy(out[152..184], &self.catalog_digest);
        @memcpy(out[184..216], &self.schema_digest);
        @memcpy(out[216..248], &self.profile_digest);
        std.mem.writeInt(u64, out[248..256], self.edge_order_count, .little);
    }

    pub fn decode(bytes: *const [header_len]u8) !Header {
        if (!std.mem.eql(u8, bytes[0..8], file_magic)) return error.InvalidRecord;
        if (std.mem.readInt(u16, bytes[8..10], .little) != current_version) return error.UnsupportedVersion;
        if (std.mem.readInt(u16, bytes[10..12], .little) != header_len) return error.InvalidRecord;
        if (bytes[13] != 0 or bytes[15] != 0) return error.InvalidRecord;
        const header = Header{
            .codec = bytes[12],
            .window_log = bytes[14],
            .uncompressed_bytes = std.mem.readInt(u64, bytes[16..24], .little),
            .compressed_bytes = std.mem.readInt(u64, bytes[24..32], .little),
            .logical_content_bytes = std.mem.readInt(u64, bytes[32..40], .little),
            .node_count = std.mem.readInt(u64, bytes[40..48], .little),
            .edge_count = std.mem.readInt(u64, bytes[48..56], .little),
            .property_count = std.mem.readInt(u64, bytes[56..64], .little),
            .catalog_bytes = std.mem.readInt(u64, bytes[64..72], .little),
            .schema_bytes = std.mem.readInt(u64, bytes[72..80], .little),
            .profile_bytes = std.mem.readInt(u64, bytes[80..88], .little),
            .payload_digest = bytes[88..120].*,
            .semantic_digest = bytes[120..152].*,
            .catalog_digest = bytes[152..184].*,
            .schema_digest = bytes[184..216].*,
            .profile_digest = bytes[216..248].*,
            .edge_order_count = std.mem.readInt(u64, bytes[248..256], .little),
        };
        try header.validate();
        return header;
    }

    pub fn validate(self: Header) !void {
        if (self.codec != codec_zstd or self.window_log != 23) return error.UnsupportedCodec;
        if (self.uncompressed_bytes == 0 or self.compressed_bytes == 0) return error.InvalidRecord;
        if (self.uncompressed_bytes > max_payload_bytes or self.compressed_bytes > max_payload_bytes) return error.RecordTooLarge;
        if (self.node_count == 0 or self.logical_content_bytes == 0) return error.InvalidRecord;
        if (self.edge_order_count > self.edge_count) return error.InvalidRecord;
    }
};

pub const EncodedPayload = struct {
    bytes: []u8,
    semantic_bytes: usize,
    logical_content_bytes: u64,

    pub fn deinit(self: EncodedPayload, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
    }
};

pub const DecodedPayload = struct {
    snapshot: Snapshot,
    semantic_bytes: usize,
    logical_content_bytes: u64,
};

fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}

fn appendVarint(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value_in: u64) !void {
    var value = value_in;
    while (value >= 0x80) : (value >>= 7) try out.append(allocator, @intCast((value & 0x7f) | 0x80));
    try out.append(allocator, @intCast(value));
}

fn appendBytes(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: []const u8) !void {
    try appendVarint(out, allocator, @intCast(value.len));
    try out.appendSlice(allocator, value);
}

fn zigzag(value: i128) !u64 {
    const encoded: u128 = if (value >= 0) @as(u128, @intCast(value)) << 1 else (@as(u128, @intCast(-value)) << 1) - 1;
    return std.math.cast(u64, encoded) orelse error.RecordTooLarge;
}

fn nodeLessThan(_: void, lhs: Node, rhs: Node) bool {
    return lhs.id < rhs.id;
}

fn edgeLessThan(_: void, lhs: Edge, rhs: Edge) bool {
    return lhs.rel < rhs.rel or (lhs.rel == rhs.rel and lhs.id < rhs.id);
}

fn propertyLessThan(_: void, lhs: Property, rhs: Property) bool {
    if (lhs.key_hash != rhs.key_hash) return lhs.key_hash < rhs.key_hash;
    if (lhs.owner_type != rhs.owner_type) return lhs.owner_type < rhs.owner_type;
    return lhs.owner_id < rhs.owner_id;
}

fn edgeOrderLessThan(_: void, lhs: EdgeOrder, rhs: EdgeOrder) bool {
    return lhs.edge_id < rhs.edge_id;
}

pub fn logicalContentBytes(snapshot: Snapshot) !u64 {
    var total: u64 = 0;
    for (snapshot.nodes) |node| total = try std.math.add(u64, total, @intCast(node.text.len));
    total = try std.math.add(u64, total, try std.math.mul(u64, @intCast(snapshot.edges.len), logical_edge_bytes));
    for (snapshot.properties) |property| {
        total = try std.math.add(u64, total, switch (property.value_kind) {
            .string => @intCast(property.string_value.len),
            .uint => 8,
        });
    }
    return total;
}

pub fn encodePayload(allocator: std.mem.Allocator, snapshot: Snapshot) !EncodedPayload {
    if (snapshot.nodes.len == 0) return error.InvalidRecord;
    const nodes = try allocator.dupe(Node, snapshot.nodes);
    defer allocator.free(nodes);
    var edges = try allocator.dupe(Edge, snapshot.edges);
    defer allocator.free(edges);
    const edge_orders = try allocator.dupe(EdgeOrder, snapshot.edge_orders);
    defer allocator.free(edge_orders);
    var properties = try allocator.dupe(Property, snapshot.properties);
    defer allocator.free(properties);
    std.mem.sort(Node, nodes, {}, nodeLessThan);
    std.mem.sort(Edge, edges, {}, edgeLessThan);
    std.mem.sort(EdgeOrder, edge_orders, {}, edgeOrderLessThan);
    std.mem.sort(Property, properties, {}, propertyLessThan);

    var node_ids = std.AutoHashMap(u64, void).init(allocator);
    defer node_ids.deinit();
    try node_ids.ensureTotalCapacity(std.math.cast(u32, nodes.len) orelse return error.RecordTooLarge);
    for (nodes) |node| {
        if (node.id == 0 or node.id == std.math.maxInt(u64) or node_ids.contains(node.id)) return error.InvalidRecord;
        node_ids.putAssumeCapacityNoClobber(node.id, {});
    }

    var edge_ids = std.AutoHashMap(u64, void).init(allocator);
    defer edge_ids.deinit();
    try edge_ids.ensureTotalCapacity(std.math.cast(u32, edges.len) orelse return error.RecordTooLarge);
    for (edges) |edge| {
        if (edge.id == 0 or edge.id == std.math.maxInt(u64) or edge_ids.contains(edge.id)) return error.InvalidRecord;
        if (!node_ids.contains(edge.src) or !node_ids.contains(edge.dst)) return error.InvalidRecord;
        edge_ids.putAssumeCapacityNoClobber(edge.id, {});
    }
    for (properties) |property| {
        const owner_exists = switch (property.owner_type) {
            1 => node_ids.contains(property.owner_id),
            2 => edge_ids.contains(property.owner_id),
            else => false,
        };
        if (!owner_exists) return error.InvalidRecord;
    }

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, payload_magic);

    try out.appendSlice(allocator, "NOD2");
    try appendVarint(&out, allocator, @intCast(nodes.len));
    var previous_node_id: u64 = 0;
    for (nodes) |node| {
        if (node.id <= previous_node_id) return error.InvalidRecord;
        try appendVarint(&out, allocator, node.id - previous_node_id);
        try appendVarint(&out, allocator, node.kind);
        try appendBytes(&out, allocator, node.text);
        previous_node_id = node.id;
    }

    try out.appendSlice(allocator, "EDG1");
    var edge_groups: u64 = 0;
    var pos: usize = 0;
    while (pos < edges.len) : (edge_groups += 1) {
        const rel = edges[pos].rel;
        while (pos < edges.len and edges[pos].rel == rel) pos += 1;
    }
    try appendVarint(&out, allocator, edge_groups);
    pos = 0;
    while (pos < edges.len) {
        const start = pos;
        const rel = edges[pos].rel;
        while (pos < edges.len and edges[pos].rel == rel) pos += 1;
        try appendVarint(&out, allocator, rel);
        try appendVarint(&out, allocator, @intCast(pos - start));
        var previous_id: u64 = 0;
        var previous_src: u64 = 0;
        var previous_dst: u64 = 0;
        for (edges[start..pos]) |edge| {
            if (edge.id <= previous_id or edge.src == 0 or edge.dst == 0) return error.InvalidRecord;
            try appendVarint(&out, allocator, edge.id - previous_id);
            try appendVarint(&out, allocator, try zigzag(@as(i128, edge.src) - previous_src));
            try appendVarint(&out, allocator, try zigzag(@as(i128, edge.dst) - previous_dst));
            previous_id = edge.id;
            previous_src = edge.src;
            previous_dst = edge.dst;
        }
    }

    try out.appendSlice(allocator, "ORD1");
    try appendVarint(&out, allocator, @intCast(edge_orders.len));
    var previous_order_edge_id: u64 = 0;
    for (edge_orders) |order| {
        if (order.edge_id <= previous_order_edge_id or order.order_key == std.math.maxInt(u64)) return error.InvalidRecord;
        if (!edge_ids.contains(order.edge_id)) return error.InvalidRecord;
        try appendVarint(&out, allocator, order.edge_id - previous_order_edge_id);
        try appendVarint(&out, allocator, order.order_key);
        previous_order_edge_id = order.edge_id;
    }

    try out.appendSlice(allocator, "PRP1");
    var property_groups: u64 = 0;
    pos = 0;
    while (pos < properties.len) : (property_groups += 1) {
        const key_hash = properties[pos].key_hash;
        while (pos < properties.len and properties[pos].key_hash == key_hash) pos += 1;
    }
    try appendVarint(&out, allocator, property_groups);
    pos = 0;
    while (pos < properties.len) {
        const start = pos;
        const key_hash = properties[pos].key_hash;
        while (pos < properties.len and properties[pos].key_hash == key_hash) pos += 1;
        var key_bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &key_bytes, key_hash, .little);
        try out.appendSlice(allocator, &key_bytes);
        try appendVarint(&out, allocator, @intCast(pos - start));
        var previous_owner_type: u8 = 0;
        var previous_owner_id: u64 = 0;
        for (properties[start..pos]) |property| {
            if (property.owner_type != 1 and property.owner_type != 2) return error.InvalidRecord;
            if (property.owner_type != previous_owner_type) previous_owner_id = 0;
            if (property.owner_id <= previous_owner_id) return error.InvalidRecord;
            try appendVarint(&out, allocator, property.owner_type);
            try appendVarint(&out, allocator, property.owner_id - previous_owner_id);
            try appendVarint(&out, allocator, @intFromEnum(property.value_kind));
            switch (property.value_kind) {
                .string => try appendBytes(&out, allocator, property.string_value),
                .uint => try appendVarint(&out, allocator, property.uint_value),
            }
            previous_owner_type = property.owner_type;
            previous_owner_id = property.owner_id;
        }
    }
    const semantic_bytes = out.items.len;

    try out.appendSlice(allocator, "MET1");
    try appendBytes(&out, allocator, snapshot.catalog);
    try appendBytes(&out, allocator, snapshot.schema);
    try appendBytes(&out, allocator, snapshot.profiles);
    return .{
        .bytes = try out.toOwnedSlice(allocator),
        .semantic_bytes = semantic_bytes,
        .logical_content_bytes = try logicalContentBytes(snapshot),
    };
}

const Reader = struct {
    bytes: []const u8,
    pos: usize = 0,

    fn take(self: *Reader, len: usize) ![]const u8 {
        const end = std.math.add(usize, self.pos, len) catch return error.InvalidRecord;
        if (end > self.bytes.len) return error.InvalidRecord;
        defer self.pos = end;
        return self.bytes[self.pos..end];
    }

    fn expect(self: *Reader, expected: []const u8) !void {
        if (!std.mem.eql(u8, try self.take(expected.len), expected)) return error.InvalidRecord;
    }

    fn varint(self: *Reader) !u64 {
        var value: u64 = 0;
        var shift: u6 = 0;
        for (0..10) |index| {
            const byte = (try self.take(1))[0];
            if (index == 9 and byte > 1) return error.InvalidRecord;
            value |= @as(u64, byte & 0x7f) << shift;
            if ((byte & 0x80) == 0) return value;
            shift += 7;
        }
        return error.InvalidRecord;
    }

    fn bytesValue(self: *Reader) ![]const u8 {
        const len = std.math.cast(usize, try self.varint()) orelse return error.RecordTooLarge;
        return self.take(len);
    }
};

fn unzigzag(value: u64) i128 {
    return if ((value & 1) == 0) @as(i128, value >> 1) else -@as(i128, (value >> 1) + 1);
}

/// Convert an individually-owned snapshot into backing-buffer form: copy all
/// strings into one blob, free the originals, and set `backing`. Applied to
/// mutation results so the resident allocation count stays independent of
/// node and property counts across the store's lifetime.
/// `string_ownership` selects whether every decoded string is duplicated
/// into its own allocation (`.owned`) or borrowed as a slice into `bytes`
/// (`.borrowed`). Borrowing callers must keep the buffer alive for the
/// snapshot's lifetime, normally by storing it as `Snapshot.backing`; on
/// real agent-memory stores that removes roughly one small allocation per
/// node and per string property.
pub fn decodePayload(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    string_ownership: enum { owned, borrowed },
) !DecodedPayload {
    return switch (string_ownership) {
        .owned => decodePayloadImpl(allocator, bytes, false),
        .borrowed => decodePayloadImpl(allocator, bytes, true),
    };
}

fn decodePayloadImpl(allocator: std.mem.Allocator, bytes: []const u8, comptime borrow: bool) !DecodedPayload {
    var reader = Reader{ .bytes = bytes };
    try reader.expect(payload_magic);
    var nodes = std.ArrayList(Node).empty;
    errdefer {
        if (!borrow) for (nodes.items) |node| allocator.free(node.text);
        nodes.deinit(allocator);
    }
    var edges = std.ArrayList(Edge).empty;
    errdefer edges.deinit(allocator);
    var edge_orders = std.ArrayList(EdgeOrder).empty;
    errdefer edge_orders.deinit(allocator);
    var properties = std.ArrayList(Property).empty;
    errdefer {
        if (!borrow) for (properties.items) |property| if (property.value_kind == .string) allocator.free(property.string_value);
        properties.deinit(allocator);
    }

    try reader.expect("NOD2");
    const node_count = try reader.varint();
    if (node_count == 0) return error.InvalidRecord;
    var previous_node_id: u64 = 0;
    for (0..node_count) |_| {
        const delta = try reader.varint();
        if (delta == 0) return error.InvalidRecord;
        const id = try std.math.add(u64, previous_node_id, delta);
        const kind = std.math.cast(u16, try reader.varint()) orelse return error.InvalidRecord;
        const raw_text = try reader.bytesValue();
        const text = if (borrow) raw_text else try allocator.dupe(u8, raw_text);
        errdefer if (!borrow) allocator.free(text);
        try nodes.append(allocator, .{ .id = id, .kind = kind, .text = text });
        previous_node_id = id;
    }
    var node_ids = std.AutoHashMap(u64, void).init(allocator);
    defer node_ids.deinit();
    try node_ids.ensureTotalCapacity(std.math.cast(u32, nodes.items.len) orelse return error.RecordTooLarge);
    for (nodes.items) |node| node_ids.putAssumeCapacityNoClobber(node.id, {});

    try reader.expect("EDG1");
    const edge_groups = try reader.varint();
    var previous_rel: ?u16 = null;
    for (0..edge_groups) |_| {
        const rel = std.math.cast(u16, try reader.varint()) orelse return error.InvalidRecord;
        if (previous_rel) |value| if (rel <= value) return error.InvalidRecord;
        previous_rel = rel;
        const count = try reader.varint();
        if (count == 0) return error.InvalidRecord;
        var previous_id: u64 = 0;
        var previous_src: u64 = 0;
        var previous_dst: u64 = 0;
        for (0..count) |_| {
            const id_delta = try reader.varint();
            if (id_delta == 0) return error.InvalidRecord;
            const id = try std.math.add(u64, previous_id, id_delta);
            const src_value = @as(i128, previous_src) + unzigzag(try reader.varint());
            const dst_value = @as(i128, previous_dst) + unzigzag(try reader.varint());
            const src = std.math.cast(u64, src_value) orelse return error.InvalidRecord;
            const dst = std.math.cast(u64, dst_value) orelse return error.InvalidRecord;
            if (src == 0 or dst == 0 or !node_ids.contains(src) or !node_ids.contains(dst)) return error.InvalidRecord;
            try edges.append(allocator, .{ .id = id, .src = src, .rel = rel, .dst = dst });
            previous_id = id;
            previous_src = src;
            previous_dst = dst;
        }
    }

    try reader.expect("ORD1");
    const edge_order_count = try reader.varint();
    if (edge_order_count > edges.items.len) return error.InvalidRecord;
    var edge_ids = std.AutoHashMap(u64, void).init(allocator);
    defer edge_ids.deinit();
    try edge_ids.ensureTotalCapacity(std.math.cast(u32, edges.items.len) orelse return error.RecordTooLarge);
    for (edges.items) |edge| {
        if (edge_ids.contains(edge.id)) return error.InvalidRecord;
        edge_ids.putAssumeCapacityNoClobber(edge.id, {});
    }
    var previous_order_edge_id: u64 = 0;
    for (0..edge_order_count) |_| {
        const edge_delta = try reader.varint();
        if (edge_delta == 0) return error.InvalidRecord;
        const edge_id = try std.math.add(u64, previous_order_edge_id, edge_delta);
        if (!edge_ids.contains(edge_id)) return error.InvalidRecord;
        const order_key = try reader.varint();
        if (order_key == std.math.maxInt(u64)) return error.InvalidRecord;
        try edge_orders.append(allocator, .{ .edge_id = edge_id, .order_key = order_key });
        previous_order_edge_id = edge_id;
    }

    try reader.expect("PRP1");
    const property_groups = try reader.varint();
    var previous_key: ?u64 = null;
    for (0..property_groups) |_| {
        const key_hash = std.mem.readInt(u64, (try reader.take(8))[0..8], .little);
        if (previous_key) |value| if (key_hash <= value) return error.InvalidRecord;
        previous_key = key_hash;
        const count = try reader.varint();
        if (count == 0) return error.InvalidRecord;
        var previous_owner_type: u8 = 0;
        var previous_owner_id: u64 = 0;
        for (0..count) |_| {
            const owner_type = std.math.cast(u8, try reader.varint()) orelse return error.InvalidRecord;
            if (owner_type != 1 and owner_type != 2) return error.InvalidRecord;
            if (owner_type != previous_owner_type) previous_owner_id = 0 else if (owner_type < previous_owner_type) return error.InvalidRecord;
            const owner_delta = try reader.varint();
            if (owner_delta == 0) return error.InvalidRecord;
            const owner_id = try std.math.add(u64, previous_owner_id, owner_delta);
            const owner_exists = if (owner_type == 1) node_ids.contains(owner_id) else edge_ids.contains(owner_id);
            if (!owner_exists) return error.InvalidRecord;
            const value_kind: PropertyValueKind = switch (try reader.varint()) {
                1 => .string,
                2 => .uint,
                else => return error.InvalidRecord,
            };
            var property = Property{
                .owner_type = owner_type,
                .owner_id = owner_id,
                .key_hash = key_hash,
                .value_kind = value_kind,
            };
            if (value_kind == .string) {
                const raw_value = try reader.bytesValue();
                property.string_value = if (borrow) raw_value else try allocator.dupe(u8, raw_value);
            } else property.uint_value = try reader.varint();
            errdefer if (!borrow and value_kind == .string) allocator.free(property.string_value);
            try properties.append(allocator, property);
            previous_owner_type = owner_type;
            previous_owner_id = owner_id;
        }
    }
    const semantic_bytes = reader.pos;
    try reader.expect("MET1");
    const raw_catalog = try reader.bytesValue();
    const catalog = if (borrow) raw_catalog else try allocator.dupe(u8, raw_catalog);
    errdefer if (!borrow) allocator.free(catalog);
    const raw_schema = try reader.bytesValue();
    const schema = if (borrow) raw_schema else try allocator.dupe(u8, raw_schema);
    errdefer if (!borrow) allocator.free(schema);
    const raw_profiles = try reader.bytesValue();
    const profiles = if (borrow) raw_profiles else try allocator.dupe(u8, raw_profiles);
    errdefer if (!borrow) allocator.free(profiles);
    if (reader.pos != reader.bytes.len) return error.InvalidRecord;

    const snapshot = Snapshot{
        .nodes = try nodes.toOwnedSlice(allocator),
        .edges = try edges.toOwnedSlice(allocator),
        .edge_orders = try edge_orders.toOwnedSlice(allocator),
        .properties = try properties.toOwnedSlice(allocator),
        .catalog = catalog,
        .schema = schema,
        .profiles = profiles,
    };
    return .{
        .snapshot = snapshot,
        .semantic_bytes = semantic_bytes,
        .logical_content_bytes = try logicalContentBytes(snapshot),
    };
}

test "checkpoint payload is deterministic and byte exact" {
    const allocator = std.testing.allocator;
    var nodes = [_]Node{
        .{ .id = 9, .kind = 13, .text = "verification 中" },
        .{ .id = 2, .kind = 10, .text = "task body" },
        .{ .id = 3, .kind = 13, .text = "verification alpha" },
    };
    var edges = [_]Edge{
        .{ .id = 8, .src = 9, .rel = 11, .dst = 2 },
        .{ .id = 4, .src = 2, .rel = 24, .dst = 3 },
    };
    var edge_orders = [_]EdgeOrder{.{ .edge_id = 8, .order_key = 1024 }};
    var properties = [_]Property{
        .{ .owner_type = 1, .owner_id = 9, .key_hash = 99, .value_kind = .string, .string_value = "claimed" },
        .{ .owner_type = 1, .owner_id = 2, .key_hash = 42, .value_kind = .uint, .uint_value = 7 },
    };
    const snapshot = Snapshot{
        .nodes = &nodes,
        .edges = &edges,
        .edge_orders = &edge_orders,
        .properties = &properties,
        .catalog = "catalog-v1",
        .schema = "schema-v1",
        .profiles = "agent-memory",
    };
    const encoded = try encodePayload(allocator, snapshot);
    defer encoded.deinit(allocator);
    const decoded_value = try decodePayload(allocator, encoded.bytes, .owned);
    var decoded = decoded_value.snapshot;
    defer decoded.deinitOwned(allocator);
    try std.testing.expectEqual(@as(usize, 3), decoded.nodes.len);
    try std.testing.expectEqual(@as(u64, 2), decoded.nodes[0].id);
    try std.testing.expectEqualStrings("verification 中", decoded.nodes[2].text);
    try std.testing.expectEqual(@as(u16, 11), decoded.edges[0].rel);
    try std.testing.expectEqual(@as(u64, 1024), decoded.edge_orders[0].order_key);
    try std.testing.expectEqual(@as(u64, 7), decoded.properties[0].uint_value);
    try std.testing.expectEqualStrings("claimed", decoded.properties[1].string_value);
    try std.testing.expectEqualStrings("catalog-v1", decoded.catalog);
    try std.testing.expectEqual(encoded.logical_content_bytes, decoded_value.logical_content_bytes);
}

test "checkpoint payload rejects dangling edges and property owners" {
    const allocator = std.testing.allocator;
    var nodes = [_]Node{.{ .id = 1, .kind = 10, .text = "task" }};
    var dangling_edge = [_]Edge{.{ .id = 1, .src = 1, .rel = 11, .dst = 2 }};
    try std.testing.expectError(error.InvalidRecord, encodePayload(allocator, .{
        .nodes = &nodes,
        .edges = &dangling_edge,
        .properties = &.{},
    }));

    var dangling_property = [_]Property{.{
        .owner_type = 2,
        .owner_id = 9,
        .key_hash = 42,
        .value_kind = .uint,
        .uint_value = 7,
    }};
    try std.testing.expectError(error.InvalidRecord, encodePayload(allocator, .{
        .nodes = &nodes,
        .edges = &.{},
        .properties = &dangling_property,
    }));
}
