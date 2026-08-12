const std = @import("std");

pub const NodePropertyIndexHeader = struct {
    record_count: u64,
    node_count: u64,
    node_digest: u64,

    const magic = [_]u8{ 'T', 'K', 'P', 'R' };
    const version: u16 = 1;
    pub const encoded_len: usize = 40;

    pub fn encode(self: NodePropertyIndexHeader, out: *[encoded_len]u8) void {
        @memcpy(out[0..4], &magic);
        std.mem.writeInt(u16, out[4..6], version, .little);
        std.mem.writeInt(u16, out[6..8], encoded_len, .little);
        std.mem.writeInt(u64, out[8..16], self.record_count, .little);
        std.mem.writeInt(u64, out[16..24], self.node_count, .little);
        std.mem.writeInt(u64, out[24..32], self.node_digest, .little);
        std.mem.writeInt(u64, out[32..40], 0, .little);
    }

    pub fn decode(bytes: *const [encoded_len]u8) !NodePropertyIndexHeader {
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

pub const NodePropertyIndexRecord = struct {
    key_hash: u64,
    value_hash: u64,
    node_id: u64,
    value_type: u8,

    pub const value_type_string: u8 = 1;
    pub const value_type_uint: u8 = 2;
    pub const encoded_len: usize = 32;

    pub fn encode(self: NodePropertyIndexRecord, out: *[encoded_len]u8) !void {
        if (self.node_id == 0 or self.node_id == std.math.maxInt(u64)) return error.InvalidRecord;
        if (self.value_type != value_type_string and self.value_type != value_type_uint) return error.InvalidRecord;
        std.mem.writeInt(u64, out[0..8], self.key_hash, .little);
        std.mem.writeInt(u64, out[8..16], self.value_hash, .little);
        std.mem.writeInt(u64, out[16..24], self.node_id, .little);
        out[24] = self.value_type;
        @memset(out[25..32], 0);
    }

    pub fn decode(bytes: *const [encoded_len]u8) !NodePropertyIndexRecord {
        const node_id = std.mem.readInt(u64, bytes[16..24], .little);
        if (node_id == 0 or node_id == std.math.maxInt(u64)) return error.InvalidRecord;
        const value_type = bytes[24];
        if (value_type != value_type_string and value_type != value_type_uint) return error.InvalidRecord;
        for (bytes[25..32]) |byte| {
            if (byte != 0) return error.InvalidRecord;
        }
        return .{
            .key_hash = std.mem.readInt(u64, bytes[0..8], .little),
            .value_hash = std.mem.readInt(u64, bytes[8..16], .little),
            .node_id = node_id,
            .value_type = value_type,
        };
    }
};

pub const PropertyPayloadIndexHeader = struct {
    record_count: u64,
    owner_count: u64,
    owner_digest: u64,

    const magic = [_]u8{ 'T', 'K', 'P', 'X' };
    const version: u16 = 1;
    pub const encoded_len: usize = 40;

    pub fn encode(self: PropertyPayloadIndexHeader, out: *[encoded_len]u8) void {
        @memcpy(out[0..4], &magic);
        std.mem.writeInt(u16, out[4..6], version, .little);
        std.mem.writeInt(u16, out[6..8], encoded_len, .little);
        std.mem.writeInt(u64, out[8..16], self.record_count, .little);
        std.mem.writeInt(u64, out[16..24], self.owner_count, .little);
        std.mem.writeInt(u64, out[24..32], self.owner_digest, .little);
        std.mem.writeInt(u64, out[32..40], 0, .little);
    }

    pub fn decode(bytes: *const [encoded_len]u8) !PropertyPayloadIndexHeader {
        if (!std.mem.eql(u8, bytes[0..4], &magic)) return error.InvalidRecord;
        if (std.mem.readInt(u16, bytes[4..6], .little) != version) return error.InvalidRecord;
        if (std.mem.readInt(u16, bytes[6..8], .little) != encoded_len) return error.InvalidRecord;
        if (std.mem.readInt(u64, bytes[32..40], .little) != 0) return error.InvalidRecord;
        return .{
            .record_count = std.mem.readInt(u64, bytes[8..16], .little),
            .owner_count = std.mem.readInt(u64, bytes[16..24], .little),
            .owner_digest = std.mem.readInt(u64, bytes[24..32], .little),
        };
    }
};

pub const PropertyPayloadRedoJournalHeader = struct {
    index_len: u64,
    values_len: u64,
    index_digest: u64,
    values_digest: u64,

    const magic = [_]u8{ 'T', 'K', 'P', 'J' };
    const version: u16 = 1;
    pub const encoded_len: usize = 48;

    pub fn encode(self: PropertyPayloadRedoJournalHeader, out: *[encoded_len]u8) void {
        @memset(out, 0);
        @memcpy(out[0..4], &magic);
        std.mem.writeInt(u16, out[4..6], version, .little);
        std.mem.writeInt(u16, out[6..8], encoded_len, .little);
        std.mem.writeInt(u64, out[8..16], self.index_len, .little);
        std.mem.writeInt(u64, out[16..24], self.values_len, .little);
        std.mem.writeInt(u64, out[24..32], self.index_digest, .little);
        std.mem.writeInt(u64, out[32..40], self.values_digest, .little);
    }

    pub fn decode(bytes: *const [encoded_len]u8) !PropertyPayloadRedoJournalHeader {
        if (!std.mem.eql(u8, bytes[0..4], &magic)) return error.InvalidRecord;
        if (std.mem.readInt(u16, bytes[4..6], .little) != version) return error.InvalidRecord;
        if (std.mem.readInt(u16, bytes[6..8], .little) != encoded_len) return error.InvalidRecord;
        if (!std.mem.allEqual(u8, bytes[40..48], 0)) return error.InvalidRecord;
        const header = PropertyPayloadRedoJournalHeader{
            .index_len = std.mem.readInt(u64, bytes[8..16], .little),
            .values_len = std.mem.readInt(u64, bytes[16..24], .little),
            .index_digest = std.mem.readInt(u64, bytes[24..32], .little),
            .values_digest = std.mem.readInt(u64, bytes[32..40], .little),
        };
        if (header.index_len < PropertyPayloadIndexHeader.encoded_len or
            header.values_len < NodePropertyValueBlockHeader.encoded_len)
        {
            return error.InvalidRecord;
        }
        return header;
    }
};

pub const PropertyPayloadIndexRecord = struct {
    key_hash: u64,
    value_hash: u64,
    owner_id: u64,
    owner_kind: u8,
    value_type: u8,

    pub const owner_kind_node: u8 = 1;
    pub const owner_kind_edge: u8 = 2;
    pub const value_type_string: u8 = 1;
    pub const value_type_uint: u8 = 2;
    pub const encoded_len: usize = 32;

    pub fn encode(self: PropertyPayloadIndexRecord, out: *[encoded_len]u8) !void {
        if (self.owner_id == 0 or self.owner_id == std.math.maxInt(u64)) return error.InvalidRecord;
        if (self.owner_kind != owner_kind_node and self.owner_kind != owner_kind_edge) return error.InvalidRecord;
        if (self.value_type != value_type_string and self.value_type != value_type_uint) return error.InvalidRecord;
        std.mem.writeInt(u64, out[0..8], self.key_hash, .little);
        std.mem.writeInt(u64, out[8..16], self.value_hash, .little);
        std.mem.writeInt(u64, out[16..24], self.owner_id, .little);
        out[24] = self.owner_kind;
        out[25] = self.value_type;
        @memset(out[26..32], 0);
    }

    pub fn decode(bytes: *const [encoded_len]u8) !PropertyPayloadIndexRecord {
        const owner_id = std.mem.readInt(u64, bytes[16..24], .little);
        if (owner_id == 0 or owner_id == std.math.maxInt(u64)) return error.InvalidRecord;
        const owner_kind = bytes[24];
        if (owner_kind != owner_kind_node and owner_kind != owner_kind_edge) return error.InvalidRecord;
        const value_type = bytes[25];
        if (value_type != value_type_string and value_type != value_type_uint) return error.InvalidRecord;
        for (bytes[26..32]) |byte| {
            if (byte != 0) return error.InvalidRecord;
        }
        return .{
            .key_hash = std.mem.readInt(u64, bytes[0..8], .little),
            .value_hash = std.mem.readInt(u64, bytes[8..16], .little),
            .owner_id = owner_id,
            .owner_kind = owner_kind,
            .value_type = value_type,
        };
    }
};

pub const property_payload_delta_magic = [_]u8{ 'T', 'K', 'P', 'D' };
pub const property_payload_delta_version: u16 = 1;
pub const property_payload_delta_header_len: usize = 32;
pub const property_payload_delta_entry_len: usize = 40;
pub const property_payload_delta_digest_seed: u64 = 0x544B_5044;
pub const property_payload_delta_max_frame_bytes: u32 = 16 * 1024 * 1024;
pub const property_snapshot_legacy_version: u64 = 0;
pub const property_snapshot_base_version: u64 = 1 << 62;
pub const property_snapshot_delta_version_base: u64 = 2 << 62;

pub const PropertyPayloadDeltaHeader = struct {
    sequence: u64,
    write_count: u32,
    payload_len: u32,
    payload_digest: u64,

    pub fn encode(self: PropertyPayloadDeltaHeader, out: *[property_payload_delta_header_len]u8) !void {
        if (self.sequence == 0 or self.write_count == 0 or self.payload_len == 0 or self.payload_len > property_payload_delta_max_frame_bytes) return error.InvalidRecord;
        @memcpy(out[0..4], &property_payload_delta_magic);
        std.mem.writeInt(u16, out[4..6], property_payload_delta_version, .little);
        std.mem.writeInt(u16, out[6..8], property_payload_delta_header_len, .little);
        std.mem.writeInt(u64, out[8..16], self.sequence, .little);
        std.mem.writeInt(u32, out[16..20], self.write_count, .little);
        std.mem.writeInt(u32, out[20..24], self.payload_len, .little);
        std.mem.writeInt(u64, out[24..32], self.payload_digest, .little);
    }

    pub fn decode(bytes: *const [property_payload_delta_header_len]u8) !PropertyPayloadDeltaHeader {
        if (!std.mem.eql(u8, bytes[0..4], &property_payload_delta_magic)) return error.InvalidRecord;
        if (std.mem.readInt(u16, bytes[4..6], .little) != property_payload_delta_version or
            std.mem.readInt(u16, bytes[6..8], .little) != property_payload_delta_header_len)
        {
            return error.InvalidRecord;
        }
        const header = PropertyPayloadDeltaHeader{
            .sequence = std.mem.readInt(u64, bytes[8..16], .little),
            .write_count = std.mem.readInt(u32, bytes[16..20], .little),
            .payload_len = std.mem.readInt(u32, bytes[20..24], .little),
            .payload_digest = std.mem.readInt(u64, bytes[24..32], .little),
        };
        if (header.sequence == 0 or header.write_count == 0 or header.payload_len == 0 or header.payload_len > property_payload_delta_max_frame_bytes) return error.InvalidRecord;
        return header;
    }
};

pub const NodePropertyValueBlockHeader = struct {
    record_count: u64,
    node_count: u64,
    node_digest: u64,
    payload_bytes: u64,
    payload_digest: u64,

    const magic = [_]u8{ 'T', 'K', 'P', 'V' };
    const version: u16 = 1;
    pub const encoded_len: usize = 56;

    pub fn encode(self: NodePropertyValueBlockHeader, out: *[encoded_len]u8) void {
        @memcpy(out[0..4], &magic);
        std.mem.writeInt(u16, out[4..6], version, .little);
        std.mem.writeInt(u16, out[6..8], encoded_len, .little);
        std.mem.writeInt(u64, out[8..16], self.record_count, .little);
        std.mem.writeInt(u64, out[16..24], self.node_count, .little);
        std.mem.writeInt(u64, out[24..32], self.node_digest, .little);
        std.mem.writeInt(u64, out[32..40], self.payload_bytes, .little);
        std.mem.writeInt(u64, out[40..48], self.payload_digest, .little);
        std.mem.writeInt(u64, out[48..56], 0, .little);
    }

    pub fn decode(bytes: *const [encoded_len]u8) !NodePropertyValueBlockHeader {
        if (!std.mem.eql(u8, bytes[0..4], &magic)) return error.InvalidRecord;
        if (std.mem.readInt(u16, bytes[4..6], .little) != version) return error.InvalidRecord;
        if (std.mem.readInt(u16, bytes[6..8], .little) != encoded_len) return error.InvalidRecord;
        if (std.mem.readInt(u64, bytes[48..56], .little) != 0) return error.InvalidRecord;
        return .{
            .record_count = std.mem.readInt(u64, bytes[8..16], .little),
            .node_count = std.mem.readInt(u64, bytes[16..24], .little),
            .node_digest = std.mem.readInt(u64, bytes[24..32], .little),
            .payload_bytes = std.mem.readInt(u64, bytes[32..40], .little),
            .payload_digest = std.mem.readInt(u64, bytes[40..48], .little),
        };
    }
};

pub const NodePropertyValueRecord = struct {
    offset: u64,
    len: u32,

    pub const encoded_len: usize = 16;

    pub fn encode(self: NodePropertyValueRecord, out: *[encoded_len]u8) void {
        std.mem.writeInt(u64, out[0..8], self.offset, .little);
        std.mem.writeInt(u32, out[8..12], self.len, .little);
        std.mem.writeInt(u32, out[12..16], 0, .little);
    }

    pub fn decode(bytes: *const [encoded_len]u8) !NodePropertyValueRecord {
        if (std.mem.readInt(u32, bytes[12..16], .little) != 0) return error.InvalidRecord;
        return .{
            .offset = std.mem.readInt(u64, bytes[0..8], .little),
            .len = std.mem.readInt(u32, bytes[8..12], .little),
        };
    }
};

test "property index headers round trip stable bytes" {
    const node_header = NodePropertyIndexHeader{
        .record_count = 9,
        .node_count = 4,
        .node_digest = 0x1020_3040_5060_7080,
    };
    var node_bytes: [NodePropertyIndexHeader.encoded_len]u8 = undefined;
    node_header.encode(&node_bytes);
    try std.testing.expectEqualSlices(u8, "TKPR", node_bytes[0..4]);
    try std.testing.expectEqual(node_header, try NodePropertyIndexHeader.decode(&node_bytes));

    const payload_header = PropertyPayloadIndexHeader{
        .record_count = 11,
        .owner_count = 7,
        .owner_digest = 0x8877_6655_4433_2211,
    };
    var payload_bytes: [PropertyPayloadIndexHeader.encoded_len]u8 = undefined;
    payload_header.encode(&payload_bytes);
    try std.testing.expectEqualSlices(u8, "TKPX", payload_bytes[0..4]);
    try std.testing.expectEqual(payload_header, try PropertyPayloadIndexHeader.decode(&payload_bytes));
}

test "property index records round trip and reject invalid tags" {
    const node_record = NodePropertyIndexRecord{
        .key_hash = 1,
        .value_hash = 2,
        .node_id = 3,
        .value_type = NodePropertyIndexRecord.value_type_string,
    };
    var node_bytes: [NodePropertyIndexRecord.encoded_len]u8 = undefined;
    try node_record.encode(&node_bytes);
    try std.testing.expectEqual(node_record, try NodePropertyIndexRecord.decode(&node_bytes));
    node_bytes[25] = 1;
    try std.testing.expectError(error.InvalidRecord, NodePropertyIndexRecord.decode(&node_bytes));

    const payload_record = PropertyPayloadIndexRecord{
        .key_hash = 4,
        .value_hash = 5,
        .owner_id = 6,
        .owner_kind = PropertyPayloadIndexRecord.owner_kind_edge,
        .value_type = PropertyPayloadIndexRecord.value_type_uint,
    };
    var payload_bytes: [PropertyPayloadIndexRecord.encoded_len]u8 = undefined;
    try payload_record.encode(&payload_bytes);
    try std.testing.expectEqual(payload_record, try PropertyPayloadIndexRecord.decode(&payload_bytes));
    payload_bytes[24] = 0;
    try std.testing.expectError(error.InvalidRecord, PropertyPayloadIndexRecord.decode(&payload_bytes));
}

test "property delta header round trips and enforces frame bounds" {
    const header = PropertyPayloadDeltaHeader{
        .sequence = 8,
        .write_count = 2,
        .payload_len = 128,
        .payload_digest = 0x1234_5678_9abc_def0,
    };
    var bytes: [property_payload_delta_header_len]u8 = undefined;
    try header.encode(&bytes);
    try std.testing.expectEqualSlices(u8, "TKPD", bytes[0..4]);
    try std.testing.expectEqual(header, try PropertyPayloadDeltaHeader.decode(&bytes));

    var too_large = header;
    too_large.payload_len = property_payload_delta_max_frame_bytes + 1;
    try std.testing.expectError(error.InvalidRecord, too_large.encode(&bytes));
    std.mem.writeInt(u64, bytes[8..16], 0, .little);
    try std.testing.expectError(error.InvalidRecord, PropertyPayloadDeltaHeader.decode(&bytes));
}

test "property value and redo formats reject reserved bytes and short targets" {
    const value_header = NodePropertyValueBlockHeader{
        .record_count = 3,
        .node_count = 2,
        .node_digest = 7,
        .payload_bytes = 64,
        .payload_digest = 9,
    };
    var value_header_bytes: [NodePropertyValueBlockHeader.encoded_len]u8 = undefined;
    value_header.encode(&value_header_bytes);
    try std.testing.expectEqual(value_header, try NodePropertyValueBlockHeader.decode(&value_header_bytes));
    value_header_bytes[55] = 1;
    try std.testing.expectError(error.InvalidRecord, NodePropertyValueBlockHeader.decode(&value_header_bytes));

    const value_record = NodePropertyValueRecord{ .offset = 32, .len = 12 };
    var value_record_bytes: [NodePropertyValueRecord.encoded_len]u8 = undefined;
    value_record.encode(&value_record_bytes);
    try std.testing.expectEqual(value_record, try NodePropertyValueRecord.decode(&value_record_bytes));
    value_record_bytes[12] = 1;
    try std.testing.expectError(error.InvalidRecord, NodePropertyValueRecord.decode(&value_record_bytes));

    const redo = PropertyPayloadRedoJournalHeader{
        .index_len = PropertyPayloadIndexHeader.encoded_len,
        .values_len = NodePropertyValueBlockHeader.encoded_len,
        .index_digest = 10,
        .values_digest = 11,
    };
    var redo_bytes: [PropertyPayloadRedoJournalHeader.encoded_len]u8 = undefined;
    redo.encode(&redo_bytes);
    try std.testing.expectEqual(redo, try PropertyPayloadRedoJournalHeader.decode(&redo_bytes));
    std.mem.writeInt(u64, redo_bytes[8..16], PropertyPayloadIndexHeader.encoded_len - 1, .little);
    try std.testing.expectError(error.InvalidRecord, PropertyPayloadRedoJournalHeader.decode(&redo_bytes));
}
