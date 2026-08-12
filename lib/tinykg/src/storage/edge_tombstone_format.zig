const std = @import("std");

pub const Header = struct {
    count: u64,
    digest: u64 = 0,

    const magic = [_]u8{ 'T', 'K', 'G', 'T' };
    const version: u16 = 2;
    pub const encoded_len: usize = 24;

    pub fn encode(self: Header, out: *[encoded_len]u8) void {
        @memcpy(out[0..4], &magic);
        std.mem.writeInt(u16, out[4..6], version, .little);
        std.mem.writeInt(u16, out[6..8], encoded_len, .little);
        std.mem.writeInt(u64, out[8..16], self.count, .little);
        std.mem.writeInt(u64, out[16..24], self.digest, .little);
    }

    pub fn decode(bytes: *const [encoded_len]u8) !Header {
        if (!std.mem.eql(u8, bytes[0..4], &magic)) return error.InvalidRecord;
        if (std.mem.readInt(u16, bytes[4..6], .little) != version) return error.InvalidRecord;
        if (std.mem.readInt(u16, bytes[6..8], .little) != encoded_len) return error.InvalidRecord;
        return .{
            .count = std.mem.readInt(u64, bytes[8..16], .little),
            .digest = std.mem.readInt(u64, bytes[16..24], .little),
        };
    }
};

pub const Record = struct {
    edge_id: u64,
    edge_digest: u64,

    pub const encoded_len: usize = 8;

    pub fn encode(self: Record, out: *[encoded_len]u8) void {
        std.mem.writeInt(u64, out[0..8], self.edge_id, .little);
    }

    pub fn decode(bytes: *const [encoded_len]u8) !Record {
        return decodeSlice(bytes);
    }

    pub fn decodeSlice(bytes: []const u8) !Record {
        if (bytes.len != encoded_len) return error.InvalidRecord;
        const edge_id = std.mem.readInt(u64, bytes[0..8], .little);
        if (edge_id == 0 or edge_id == std.math.maxInt(u64)) return error.InvalidRecord;
        return .{
            .edge_id = edge_id,
            .edge_digest = 0,
        };
    }
};

test "edge tombstone format round trips stable bytes" {
    const header = Header{ .count = 7, .digest = 0x1020_3040_5060_7080 };
    var header_bytes: [Header.encoded_len]u8 = undefined;
    header.encode(&header_bytes);
    try std.testing.expectEqualSlices(u8, "TKGT", header_bytes[0..4]);
    try std.testing.expectEqual(@as(u16, 2), std.mem.readInt(u16, header_bytes[4..6], .little));
    try std.testing.expectEqual(header, try Header.decode(&header_bytes));

    const record = Record{ .edge_id = 42, .edge_digest = 0 };
    var record_bytes: [Record.encoded_len]u8 = undefined;
    record.encode(&record_bytes);
    try std.testing.expectEqual(record, try Record.decode(&record_bytes));
}

test "edge tombstone format rejects reserved ids" {
    var bytes: [Record.encoded_len]u8 = undefined;
    std.mem.writeInt(u64, &bytes, 0, .little);
    try std.testing.expectError(error.InvalidRecord, Record.decode(&bytes));
    std.mem.writeInt(u64, &bytes, std.math.maxInt(u64), .little);
    try std.testing.expectError(error.InvalidRecord, Record.decode(&bytes));
}
