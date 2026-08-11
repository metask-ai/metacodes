const std = @import("std");

/// Persistent ordered-edge sidecar bytes. Sorting, digest aggregation, remap,
/// scanning, atomic publication, and file I/O remain in the storage facade.
pub fn EdgeOrderFormat(comptime max_relation_types: u16) type {
    return struct {
        pub const EdgeOrderRecord = struct {
            src: u64,
            rel: u16,
            edge_id: u64,
            order_key: u64,
        };

        pub const EdgeOrderHeader = struct {
            count: u64 = 0,
            digest: u64 = 0,
        };

        pub const record_encoded_len: usize = 26;
        pub const header_encoded_len: usize = 16;

        pub fn encodeRecord(record: EdgeOrderRecord, out: *[record_encoded_len]u8) void {
            std.mem.writeInt(u64, out[0..8], record.src, .little);
            std.mem.writeInt(u16, out[8..10], record.rel, .little);
            std.mem.writeInt(u64, out[10..18], record.edge_id, .little);
            std.mem.writeInt(u64, out[18..26], record.order_key, .little);
        }

        pub fn decodeRecord(bytes: *const [record_encoded_len]u8) !EdgeOrderRecord {
            const record = EdgeOrderRecord{
                .src = std.mem.readInt(u64, bytes[0..8], .little),
                .rel = std.mem.readInt(u16, bytes[8..10], .little),
                .edge_id = std.mem.readInt(u64, bytes[10..18], .little),
                .order_key = std.mem.readInt(u64, bytes[18..26], .little),
            };
            if (record.src == 0 or record.src == std.math.maxInt(u64)) return error.InvalidRecord;
            if (record.edge_id == 0 or record.edge_id == std.math.maxInt(u64)) return error.InvalidRecord;
            if (!validRelation(record.rel)) return error.InvalidRecord;
            return record;
        }

        pub fn validateRecord(record: EdgeOrderRecord) !void {
            if (record.src == 0 or record.src == std.math.maxInt(u64)) return error.InvalidRecord;
            if (record.edge_id == 0 or record.edge_id == std.math.maxInt(u64)) return error.InvalidRecord;
            if (record.order_key == std.math.maxInt(u64)) return error.InvalidRecord;
            if (!validRelation(record.rel)) return error.InvalidRecord;
        }

        pub fn encodeHeader(header: EdgeOrderHeader, out: *[header_encoded_len]u8) void {
            std.mem.writeInt(u64, out[0..8], header.count, .little);
            std.mem.writeInt(u64, out[8..16], header.digest, .little);
        }

        pub fn decodeHeader(bytes: *const [header_encoded_len]u8) EdgeOrderHeader {
            return .{
                .count = std.mem.readInt(u64, bytes[0..8], .little),
                .digest = std.mem.readInt(u64, bytes[8..16], .little),
            };
        }

        fn validRelation(value: u16) bool {
            return value < max_relation_types;
        }
    };
}

const TestFormat = EdgeOrderFormat(8);

test "edge order record round trips stable bytes" {
    const record = TestFormat.EdgeOrderRecord{
        .src = 0x0807_0605_0403_0201,
        .rel = 7,
        .edge_id = 0x1817_1615_1413_1211,
        .order_key = 0x2827_2625_2423_2221,
    };
    var bytes: [TestFormat.record_encoded_len]u8 = undefined;
    TestFormat.encodeRecord(record, &bytes);

    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6, 7, 8 }, bytes[0..8]);
    try std.testing.expectEqual(@as(u16, 7), std.mem.readInt(u16, bytes[8..10], .little));
    try std.testing.expectEqualDeep(record, try TestFormat.decodeRecord(&bytes));
}

test "edge order record rejects reserved ids relations and order keys" {
    const valid = TestFormat.EdgeOrderRecord{ .src = 1, .rel = 2, .edge_id = 3, .order_key = 4 };
    try TestFormat.validateRecord(valid);
    try std.testing.expectError(error.InvalidRecord, TestFormat.validateRecord(.{ .src = 0, .rel = 2, .edge_id = 3, .order_key = 4 }));
    try std.testing.expectError(error.InvalidRecord, TestFormat.validateRecord(.{ .src = 1, .rel = 8, .edge_id = 3, .order_key = 4 }));
    try std.testing.expectError(error.InvalidRecord, TestFormat.validateRecord(.{ .src = 1, .rel = 2, .edge_id = 3, .order_key = std.math.maxInt(u64) }));

    var bytes: [TestFormat.record_encoded_len]u8 = undefined;
    TestFormat.encodeRecord(valid, &bytes);
    std.mem.writeInt(u64, bytes[10..18], 0, .little);
    try std.testing.expectError(error.InvalidRecord, TestFormat.decodeRecord(&bytes));
}

test "edge order header round trips stable bytes" {
    const header = TestFormat.EdgeOrderHeader{
        .count = 0x0807_0605_0403_0201,
        .digest = 0x1817_1615_1413_1211,
    };
    var bytes: [TestFormat.header_encoded_len]u8 = undefined;
    TestFormat.encodeHeader(header, &bytes);

    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3, 4, 5, 6, 7, 8 }, bytes[0..8]);
    try std.testing.expectEqualSlices(u8, &.{ 17, 18, 19, 20, 21, 22, 23, 24 }, bytes[8..16]);
    try std.testing.expectEqualDeep(header, TestFormat.decodeHeader(&bytes));
}
