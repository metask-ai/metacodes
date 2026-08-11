const std = @import("std");

pub const NodeIndexHeader = struct {
    record_count: u64,
    node_count: u64,
    node_digest: u64,

    const magic = [_]u8{ 'T', 'K', 'E', 'K' };
    const version: u16 = 2;
    pub const encoded_len: usize = 40;

    pub fn encode(self: NodeIndexHeader, out: *[encoded_len]u8) void {
        @memcpy(out[0..4], &magic);
        std.mem.writeInt(u16, out[4..6], version, .little);
        std.mem.writeInt(u16, out[6..8], encoded_len, .little);
        std.mem.writeInt(u64, out[8..16], self.record_count, .little);
        std.mem.writeInt(u64, out[16..24], self.node_count, .little);
        std.mem.writeInt(u64, out[24..32], self.node_digest, .little);
        std.mem.writeInt(u64, out[32..40], 0, .little);
    }

    pub fn decode(bytes: *const [encoded_len]u8) !NodeIndexHeader {
        if (!std.mem.eql(u8, bytes[0..4], &magic)) return error.InvalidRecord;
        if (std.mem.readInt(u16, bytes[4..6], .little) != version) return error.InvalidRecord;
        if (std.mem.readInt(u16, bytes[6..8], .little) != encoded_len) return error.InvalidRecord;
        if (std.mem.readInt(u64, bytes[32..40], .little) != 0) return error.InvalidRecord;
        return .{
            .record_count = std.mem.readInt(u64, bytes[8..16], .little),
            .node_count = std.mem.readInt(u64, bytes[16..24], .little),
            .node_digest = std.mem.readInt(u64, bytes[24..32], .little),
        };
    }
};

pub const NodeIndexRecord = struct {
    hash: u64,
    node_id: u64,

    pub const encoded_len: usize = 16;

    pub fn encode(self: NodeIndexRecord, out: *[encoded_len]u8) !void {
        if (self.node_id == 0 or self.node_id == std.math.maxInt(u64)) return error.InvalidRecord;
        std.mem.writeInt(u64, out[0..8], self.hash, .little);
        std.mem.writeInt(u64, out[8..16], self.node_id, .little);
    }

    pub fn decode(bytes: *const [encoded_len]u8) !NodeIndexRecord {
        const node_id = std.mem.readInt(u64, bytes[8..16], .little);
        if (node_id == 0 or node_id == std.math.maxInt(u64)) return error.InvalidRecord;
        return .{
            .hash = std.mem.readInt(u64, bytes[0..8], .little),
            .node_id = node_id,
        };
    }
};

pub const EdgeIndexHeader = struct {
    record_count: u64,
    node_count: u64,
    node_digest: u64,
    edge_count: u64,
    edge_digest: u64,

    const magic = [_]u8{ 'T', 'K', 'E', 'K' };
    const version: u16 = 1;
    pub const encoded_len: usize = 56;

    pub fn encode(self: EdgeIndexHeader, out: *[encoded_len]u8) void {
        @memcpy(out[0..4], &magic);
        std.mem.writeInt(u16, out[4..6], version, .little);
        std.mem.writeInt(u16, out[6..8], encoded_len, .little);
        std.mem.writeInt(u64, out[8..16], self.record_count, .little);
        std.mem.writeInt(u64, out[16..24], self.node_count, .little);
        std.mem.writeInt(u64, out[24..32], self.node_digest, .little);
        std.mem.writeInt(u64, out[32..40], self.edge_count, .little);
        std.mem.writeInt(u64, out[40..48], self.edge_digest, .little);
        std.mem.writeInt(u64, out[48..56], 0, .little);
    }

    pub fn decode(bytes: *const [encoded_len]u8) !EdgeIndexHeader {
        if (!std.mem.eql(u8, bytes[0..4], &magic)) return error.InvalidRecord;
        if (std.mem.readInt(u16, bytes[4..6], .little) != version) return error.InvalidRecord;
        if (std.mem.readInt(u16, bytes[6..8], .little) != encoded_len) return error.InvalidRecord;
        if (std.mem.readInt(u64, bytes[48..56], .little) != 0) return error.InvalidRecord;
        return .{
            .record_count = std.mem.readInt(u64, bytes[8..16], .little),
            .node_count = std.mem.readInt(u64, bytes[16..24], .little),
            .node_digest = std.mem.readInt(u64, bytes[24..32], .little),
            .edge_count = std.mem.readInt(u64, bytes[32..40], .little),
            .edge_digest = std.mem.readInt(u64, bytes[40..48], .little),
        };
    }
};

pub const EdgeIndexRecord = struct {
    hash: u64,
    edge_id: u64,

    pub const encoded_len: usize = 16;

    pub fn encode(self: EdgeIndexRecord, out: *[encoded_len]u8) !void {
        if (self.edge_id == 0 or self.edge_id == std.math.maxInt(u64)) return error.InvalidRecord;
        std.mem.writeInt(u64, out[0..8], self.hash, .little);
        std.mem.writeInt(u64, out[8..16], self.edge_id, .little);
    }

    pub fn decode(bytes: *const [encoded_len]u8) !EdgeIndexRecord {
        const edge_id = std.mem.readInt(u64, bytes[8..16], .little);
        if (edge_id == 0 or edge_id == std.math.maxInt(u64)) return error.InvalidRecord;
        return .{
            .hash = std.mem.readInt(u64, bytes[0..8], .little),
            .edge_id = edge_id,
        };
    }
};

test "node external-key header round trips stable bytes" {
    const header = NodeIndexHeader{
        .record_count = 7,
        .node_count = 5,
        .node_digest = 0x1020_3040_5060_7080,
    };
    var bytes: [NodeIndexHeader.encoded_len]u8 = undefined;
    header.encode(&bytes);
    try std.testing.expectEqualSlices(u8, "TKEK", bytes[0..4]);
    try std.testing.expectEqual(@as(u16, 2), std.mem.readInt(u16, bytes[4..6], .little));
    try std.testing.expectEqual(header, try NodeIndexHeader.decode(&bytes));
    bytes[39] = 1;
    try std.testing.expectError(error.InvalidRecord, NodeIndexHeader.decode(&bytes));
}

test "edge external-key header round trips stable bytes" {
    const header = EdgeIndexHeader{
        .record_count = 11,
        .node_count = 8,
        .node_digest = 9,
        .edge_count = 10,
        .edge_digest = 0x8877_6655_4433_2211,
    };
    var bytes: [EdgeIndexHeader.encoded_len]u8 = undefined;
    header.encode(&bytes);
    try std.testing.expectEqualSlices(u8, "TKEK", bytes[0..4]);
    try std.testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, bytes[4..6], .little));
    try std.testing.expectEqual(header, try EdgeIndexHeader.decode(&bytes));
    bytes[48] = 1;
    try std.testing.expectError(error.InvalidRecord, EdgeIndexHeader.decode(&bytes));
}

test "node external-key record rejects reserved ids" {
    const record = NodeIndexRecord{ .hash = 12, .node_id = 13 };
    var bytes: [NodeIndexRecord.encoded_len]u8 = undefined;
    try record.encode(&bytes);
    try std.testing.expectEqual(record, try NodeIndexRecord.decode(&bytes));
    std.mem.writeInt(u64, bytes[8..16], 0, .little);
    try std.testing.expectError(error.InvalidRecord, NodeIndexRecord.decode(&bytes));
    std.mem.writeInt(u64, bytes[8..16], std.math.maxInt(u64), .little);
    try std.testing.expectError(error.InvalidRecord, NodeIndexRecord.decode(&bytes));
}

test "edge external-key record rejects reserved ids" {
    const record = EdgeIndexRecord{ .hash = 14, .edge_id = 15 };
    var bytes: [EdgeIndexRecord.encoded_len]u8 = undefined;
    try record.encode(&bytes);
    try std.testing.expectEqual(record, try EdgeIndexRecord.decode(&bytes));
    std.mem.writeInt(u64, bytes[8..16], 0, .little);
    try std.testing.expectError(error.InvalidRecord, EdgeIndexRecord.decode(&bytes));
    std.mem.writeInt(u64, bytes[8..16], std.math.maxInt(u64), .little);
    try std.testing.expectError(error.InvalidRecord, EdgeIndexRecord.decode(&bytes));
}
