const std = @import("std");
const format = @import("format.zig");
const codec = @import("codec.zig");

pub const Snapshot = format.Snapshot;
pub const Header = format.Header;

fn digest(bytes: []const u8) [32]u8 {
    var out: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &out, .{});
    return out;
}

/// Digest of the complete deterministic canonical payload, including catalog,
/// schema and profiles. WAL transactions use this as their before/after state
/// identity; it is deliberately stronger than the header's semantic-only
/// section digest.
pub fn canonicalDigestAlloc(allocator: std.mem.Allocator, snapshot: Snapshot) ![32]u8 {
    const payload = try format.encodePayload(allocator, snapshot);
    defer payload.deinit(allocator);
    return digest(payload.bytes);
}

pub const EncodedCheckpoint = struct {
    bytes: []u8,
    header: Header,

    pub fn deinit(self: EncodedCheckpoint, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
    }
};

pub const DecodedCheckpoint = struct {
    snapshot: Snapshot,
    header: Header,
};

pub fn encodeAlloc(allocator: std.mem.Allocator, snapshot: Snapshot) !EncodedCheckpoint {
    const payload = try format.encodePayload(allocator, snapshot);
    defer payload.deinit(allocator);
    const compressed = try codec.compressAlloc(allocator, payload.bytes);
    defer allocator.free(compressed);
    const header = Header{
        .window_log = codec.window_log,
        .uncompressed_bytes = @intCast(payload.bytes.len),
        .compressed_bytes = @intCast(compressed.len),
        .logical_content_bytes = payload.logical_content_bytes,
        .node_count = @intCast(snapshot.nodes.len),
        .edge_count = @intCast(snapshot.edges.len),
        .property_count = @intCast(snapshot.properties.len),
        .catalog_bytes = @intCast(snapshot.catalog.len),
        .schema_bytes = @intCast(snapshot.schema.len),
        .profile_bytes = @intCast(snapshot.profiles.len),
        .edge_order_count = @intCast(snapshot.edge_orders.len),
        .payload_digest = digest(payload.bytes),
        .semantic_digest = digest(payload.bytes[0..payload.semantic_bytes]),
        .catalog_digest = digest(snapshot.catalog),
        .schema_digest = digest(snapshot.schema),
        .profile_digest = digest(snapshot.profiles),
    };
    const total_len = try std.math.add(usize, format.header_len, compressed.len);
    const bytes = try allocator.alloc(u8, total_len);
    errdefer allocator.free(bytes);
    try header.encode(bytes[0..format.header_len]);
    @memcpy(bytes[format.header_len..], compressed);
    return .{ .bytes = bytes, .header = header };
}

pub fn decodeAlloc(allocator: std.mem.Allocator, bytes: []const u8) !DecodedCheckpoint {
    if (bytes.len < format.header_len) return error.InvalidRecord;
    const header = try Header.decode(bytes[0..format.header_len]);
    const expected_file_bytes = try std.math.add(u64, format.header_len, header.compressed_bytes);
    if (expected_file_bytes != bytes.len) return error.InvalidRecord;
    const uncompressed_len = std.math.cast(usize, header.uncompressed_bytes) orelse return error.RecordTooLarge;
    const payload = try codec.decompressAlloc(allocator, bytes[format.header_len..], uncompressed_len);
    var payload_owned = true;
    errdefer if (payload_owned) allocator.free(payload);
    if (!std.mem.eql(u8, &digest(payload), &header.payload_digest)) return error.DigestMismatch;
    // Strings borrow from the decoded payload buffer, which the snapshot then
    // owns as `backing`: one buffer instead of one allocation per string.
    const decoded_value = try format.decodePayload(allocator, payload, .borrowed);
    var decoded = decoded_value.snapshot;
    decoded.backing = payload;
    payload_owned = false;
    errdefer decoded.deinitOwned(allocator);
    if (decoded_value.semantic_bytes > payload.len or !std.mem.eql(u8, &digest(payload[0..decoded_value.semantic_bytes]), &header.semantic_digest)) return error.DigestMismatch;
    if (decoded_value.logical_content_bytes != header.logical_content_bytes or
        decoded.nodes.len != header.node_count or decoded.edges.len != header.edge_count or decoded.edge_orders.len != header.edge_order_count or decoded.properties.len != header.property_count or
        decoded.catalog.len != header.catalog_bytes or decoded.schema.len != header.schema_bytes or decoded.profiles.len != header.profile_bytes)
    {
        return error.InvalidRecord;
    }
    if (!std.mem.eql(u8, &digest(decoded.catalog), &header.catalog_digest) or
        !std.mem.eql(u8, &digest(decoded.schema), &header.schema_digest) or
        !std.mem.eql(u8, &digest(decoded.profiles), &header.profile_digest))
    {
        return error.DigestMismatch;
    }
    return .{ .snapshot = decoded, .header = header };
}

test "checkpoint store round trips and fails closed" {
    const allocator = std.testing.allocator;
    var nodes = [_]format.Node{
        .{ .id = 1, .kind = 10, .text = "task one" },
        .{ .id = 2, .kind = 13, .text = "verification two" },
    };
    var edges = [_]format.Edge{.{ .id = 1, .src = 1, .rel = 11, .dst = 2 }};
    var properties = [_]format.Property{.{ .owner_type = 1, .owner_id = 1, .key_hash = 7, .value_kind = .string, .string_value = "open" }};
    const source = Snapshot{ .nodes = &nodes, .edges = &edges, .properties = &properties, .catalog = "catalog", .schema = "schema", .profiles = "profile" };
    const encoded = try encodeAlloc(allocator, source);
    defer encoded.deinit(allocator);
    const decoded_value = try decodeAlloc(allocator, encoded.bytes);
    var decoded = decoded_value.snapshot;
    defer decoded.deinitOwned(allocator);
    try std.testing.expectEqualStrings("verification two", decoded.nodes[1].text);

    const tampered = try allocator.dupe(u8, encoded.bytes);
    defer allocator.free(tampered);
    tampered[tampered.len - 8] ^= 0x55;
    try std.testing.expectError(error.DecompressionFailed, decodeAlloc(allocator, tampered));
    try std.testing.expectError(error.InvalidRecord, decodeAlloc(allocator, encoded.bytes[0 .. encoded.bytes.len - 1]));
    var future = try allocator.dupe(u8, encoded.bytes);
    defer allocator.free(future);
    std.mem.writeInt(u16, future[8..10], format.current_version + 1, .little);
    try std.testing.expectError(error.UnsupportedVersion, decodeAlloc(allocator, future));
}
