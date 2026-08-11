const std = @import("std");

pub fn SegmentNodeIndexFormat(
    comptime core: type,
    comptime max_nodes: u64,
    comptime max_text_bytes: u32,
) type {
    return struct {
        pub const IndexHeader = struct {
            pub const version: u16 = 7;
            pub const encoded_len: usize = 56;
            pub const flag_uniform_kind: u16 = 1;

            magic: [4]u8,
            record_len: u16,
            flags: u16 = 0,
            uniform_kind: ?core.NodeKind = null,
            node_count: u64,
            texts_bytes: u64,
            record_digest: u64,
            texts_digest: u64,
            id_base: u64 = 0,
        };

        pub const NodeByIdRecord = struct {
            pub const magic = [_]u8{ 'T', 'K', 'N', 'I' };
            pub const dense_uniform_kind_encoded_len: usize = 6;
            pub const dense_encoded_len: usize = 8;
            pub const sparse_uniform_kind_encoded_len: usize = 14;
            pub const sparse_encoded_len: usize = 16;
            pub const logical_encoded_len: usize = 24;

            id: core.NodeId,
            kind: core.NodeKind,
            text_offset: u64,
            text_len: u32,
        };

        pub const ExactTextRecord = struct {
            pub const magic = [_]u8{ 'T', 'K', 'N', 'E' };
            pub const dense_ordinal_encoded_len: usize = 4;
            pub const id_encoded_len: usize = 8;
            pub const logical_encoded_len: usize = id_encoded_len;

            id: core.NodeId,
        };

        pub fn encodeIndexHeader(header: IndexHeader, out: []u8) void {
            @memcpy(out[0..4], &header.magic);
            std.mem.writeInt(u16, out[4..6], IndexHeader.version, .little);
            std.mem.writeInt(u16, out[6..8], IndexHeader.encoded_len, .little);
            std.mem.writeInt(u16, out[8..10], header.record_len, .little);
            const flags: u16 = if (header.uniform_kind != null) header.flags | IndexHeader.flag_uniform_kind else header.flags;
            std.mem.writeInt(u16, out[10..12], flags, .little);
            std.mem.writeInt(u16, out[12..14], if (header.uniform_kind) |kind| @intFromEnum(kind) else 0, .little);
            @memset(out[14..16], 0);
            std.mem.writeInt(u64, out[16..24], header.node_count, .little);
            std.mem.writeInt(u64, out[24..32], header.texts_bytes, .little);
            std.mem.writeInt(u64, out[32..40], header.record_digest, .little);
            std.mem.writeInt(u64, out[40..48], header.texts_digest, .little);
            std.mem.writeInt(u64, out[48..56], header.id_base, .little);
        }

        pub fn decodeIndexHeader(bytes: []const u8, magic: [4]u8, record_len: usize, texts_len: usize, texts_digest: u64) !IndexHeader {
            if (bytes.len < IndexHeader.encoded_len) return error.InvalidRecord;
            if (!std.mem.eql(u8, bytes[0..4], &magic)) return error.InvalidRecord;
            if (std.mem.readInt(u16, bytes[4..6], .little) != IndexHeader.version) return error.InvalidRecord;
            if (std.mem.readInt(u16, bytes[6..8], .little) != IndexHeader.encoded_len) return error.InvalidRecord;
            const physical_record_len = std.mem.readInt(u16, bytes[8..10], .little);
            if (record_len != 0 and physical_record_len != record_len) return error.InvalidRecord;
            const flags = std.mem.readInt(u16, bytes[10..12], .little);
            const uniform_kind_value = std.mem.readInt(u16, bytes[12..14], .little);
            if (flags & IndexHeader.flag_uniform_kind == 0 and uniform_kind_value != 0) return error.InvalidRecord;
            if (!allZero(bytes[14..16])) return error.InvalidRecord;
            const node_count = std.mem.readInt(u64, bytes[16..24], .little);
            if (node_count > max_nodes) return error.RecordTooLarge;
            const texts_bytes = std.mem.readInt(u64, bytes[24..32], .little);
            if (texts_bytes != texts_len) return error.InvalidRecord;
            const payload_size = std.math.mul(usize, @intCast(node_count), physical_record_len) catch return error.RecordTooLarge;
            const expected_size = std.math.add(usize, IndexHeader.encoded_len, payload_size) catch return error.RecordTooLarge;
            if (bytes.len != expected_size) return error.InvalidRecord;
            const header = IndexHeader{
                .magic = magic,
                .record_len = physical_record_len,
                .flags = flags,
                .uniform_kind = if (flags & IndexHeader.flag_uniform_kind != 0) kindFromInt(uniform_kind_value) orelse return error.InvalidRecord else null,
                .node_count = node_count,
                .texts_bytes = texts_bytes,
                .record_digest = std.mem.readInt(u64, bytes[32..40], .little),
                .texts_digest = std.mem.readInt(u64, bytes[40..48], .little),
                .id_base = std.mem.readInt(u64, bytes[48..56], .little),
            };
            if (header.texts_digest != texts_digest) return error.InvalidRecord;
            try validateIndexHeaderFlags(header);
            return header;
        }

        pub fn decodeNodeByIdIndexHeader(bytes: []const u8, texts_len: usize, texts_digest: u64) !IndexHeader {
            const header = try decodeIndexHeader(bytes, NodeByIdRecord.magic, 0, texts_len, texts_digest);
            try validateNodeByIdHeaderRecordLen(header.record_len);
            try validateNodeByIdHeaderLayout(header);
            try validateNodeByIdDenseRange(header);
            if (!nodeByIdHeaderUsesDenseIds(header) and header.id_base != 0) return error.InvalidRecord;
            return header;
        }

        pub fn decodeNodeByIdIndexHeaderWithCount(bytes: []const u8, node_count: u64) !IndexHeader {
            if (bytes.len < IndexHeader.encoded_len) return error.InvalidRecord;
            if (!std.mem.eql(u8, bytes[0..4], &NodeByIdRecord.magic)) return error.InvalidRecord;
            if (std.mem.readInt(u16, bytes[4..6], .little) != IndexHeader.version) return error.InvalidRecord;
            if (std.mem.readInt(u16, bytes[6..8], .little) != IndexHeader.encoded_len) return error.InvalidRecord;
            const record_len = std.mem.readInt(u16, bytes[8..10], .little);
            try validateNodeByIdHeaderRecordLen(record_len);
            const flags = std.mem.readInt(u16, bytes[10..12], .little);
            const uniform_kind_value = std.mem.readInt(u16, bytes[12..14], .little);
            if (flags & IndexHeader.flag_uniform_kind == 0 and uniform_kind_value != 0) return error.InvalidRecord;
            if (!allZero(bytes[14..16])) return error.InvalidRecord;
            const header = IndexHeader{
                .magic = NodeByIdRecord.magic,
                .record_len = record_len,
                .flags = flags,
                .uniform_kind = if (flags & IndexHeader.flag_uniform_kind != 0) kindFromInt(uniform_kind_value) orelse return error.InvalidRecord else null,
                .node_count = std.mem.readInt(u64, bytes[16..24], .little),
                .texts_bytes = std.mem.readInt(u64, bytes[24..32], .little),
                .record_digest = std.mem.readInt(u64, bytes[32..40], .little),
                .texts_digest = std.mem.readInt(u64, bytes[40..48], .little),
                .id_base = std.mem.readInt(u64, bytes[48..56], .little),
            };
            try validateIndexHeaderFlags(header);
            if (header.node_count != node_count) return error.InvalidRecord;
            try validateNodeByIdHeaderLayout(header);
            try validateNodeByIdDenseRange(header);
            if (!nodeByIdHeaderUsesDenseIds(header) and header.id_base != 0) return error.InvalidRecord;
            const payload_size = std.math.mul(usize, @intCast(header.node_count), header.record_len) catch return error.RecordTooLarge;
            const expected_size = std.math.add(usize, IndexHeader.encoded_len, payload_size) catch return error.RecordTooLarge;
            if (bytes.len != expected_size) return error.InvalidRecord;
            return header;
        }

        fn validateNodeByIdHeaderRecordLen(record_len: u16) !void {
            if (record_len != NodeByIdRecord.dense_uniform_kind_encoded_len and
                record_len != NodeByIdRecord.dense_encoded_len and
                record_len != NodeByIdRecord.sparse_uniform_kind_encoded_len and
                record_len != NodeByIdRecord.sparse_encoded_len)
            {
                return error.InvalidRecord;
            }
        }

        fn validateIndexHeaderFlags(header: IndexHeader) !void {
            const known_flags = IndexHeader.flag_uniform_kind;
            if (header.flags & ~known_flags != 0) return error.InvalidRecord;
            if (header.uniform_kind == null and header.flags != 0) return error.InvalidRecord;
            if (header.uniform_kind != null and header.flags != IndexHeader.flag_uniform_kind) return error.InvalidRecord;
            if (header.uniform_kind != null and !std.mem.eql(u8, &header.magic, &NodeByIdRecord.magic)) return error.InvalidRecord;
        }

        fn validateNodeByIdHeaderLayout(header: IndexHeader) !void {
            if (nodeByIdHeaderUsesUniformKind(header)) {
                if (header.record_len != NodeByIdRecord.dense_uniform_kind_encoded_len and
                    header.record_len != NodeByIdRecord.sparse_uniform_kind_encoded_len)
                {
                    return error.InvalidRecord;
                }
            } else if (header.record_len != NodeByIdRecord.dense_encoded_len and
                header.record_len != NodeByIdRecord.sparse_encoded_len)
            {
                return error.InvalidRecord;
            }
        }

        pub fn nodeByIdHeaderUsesDenseIds(header: IndexHeader) bool {
            return header.record_len == NodeByIdRecord.dense_uniform_kind_encoded_len or header.record_len == NodeByIdRecord.dense_encoded_len;
        }

        pub fn nodeByIdHeaderUsesUniformKind(header: IndexHeader) bool {
            return header.uniform_kind != null;
        }

        fn validateNodeByIdDenseRange(header: IndexHeader) !void {
            if (!nodeByIdHeaderUsesDenseIds(header)) return;
            if (header.node_count == 0) return error.InvalidRecord;
            if (!validNodeId(core.NodeId.fromInt(header.id_base))) return error.InvalidRecord;
            const last_offset = header.node_count - 1;
            const last_id = std.math.add(u64, header.id_base, last_offset) catch return error.InvalidRecord;
            if (!validNodeId(core.NodeId.fromInt(last_id))) return error.InvalidRecord;
        }

        pub fn validateExactTextHeader(header: IndexHeader, nodes_header: IndexHeader) !void {
            if (header.record_len != ExactTextRecord.dense_ordinal_encoded_len and header.record_len != ExactTextRecord.id_encoded_len) return error.InvalidRecord;
            if (exactTextHeaderUsesDenseOrdinals(header)) {
                if (!nodeByIdHeaderUsesDenseIds(nodes_header)) return error.InvalidRecord;
                if (header.id_base != nodes_header.id_base) return error.InvalidRecord;
                if (!validNodeId(core.NodeId.fromInt(header.id_base))) return error.InvalidRecord;
            } else if (header.id_base != 0) {
                return error.InvalidRecord;
            }
        }

        pub fn exactTextHeaderUsesDenseOrdinals(header: IndexHeader) bool {
            return header.record_len == ExactTextRecord.dense_ordinal_encoded_len;
        }

        pub fn exactTextRecordLen(node_id_base: u64) u16 {
            return if (node_id_base != 0) ExactTextRecord.dense_ordinal_encoded_len else ExactTextRecord.id_encoded_len;
        }

        pub fn encodeNodeByIdLogicalRecord(record: NodeByIdRecord, out: *[NodeByIdRecord.logical_encoded_len]u8) void {
            std.mem.writeInt(u64, out[0..8], record.id.toInt(), .little);
            std.mem.writeInt(u16, out[8..10], @intFromEnum(record.kind), .little);
            @memset(out[10..12], 0);
            std.mem.writeInt(u32, out[12..16], record.text_len, .little);
            std.mem.writeInt(u64, out[16..24], record.text_offset, .little);
        }

        pub fn encodeSparseNodeByIdRecord(record: NodeByIdRecord, out: *[NodeByIdRecord.sparse_encoded_len]u8) !void {
            std.mem.writeInt(u64, out[0..8], record.id.toInt(), .little);
            std.mem.writeInt(u16, out[8..10], @intFromEnum(record.kind), .little);
            std.mem.writeInt(u16, out[10..12], try encodeNodeTextLenMinusOne(record.text_len), .little);
            std.mem.writeInt(u32, out[12..16], try encodeNodeTextOffset(record.text_offset), .little);
        }

        pub fn encodeSparseUniformKindNodeByIdRecord(record: NodeByIdRecord, out: *[NodeByIdRecord.sparse_uniform_kind_encoded_len]u8) !void {
            std.mem.writeInt(u64, out[0..8], record.id.toInt(), .little);
            std.mem.writeInt(u16, out[8..10], try encodeNodeTextLenMinusOne(record.text_len), .little);
            std.mem.writeInt(u32, out[10..14], try encodeNodeTextOffset(record.text_offset), .little);
        }

        pub fn encodeDenseNodeByIdRecord(record: NodeByIdRecord, out: *[NodeByIdRecord.dense_encoded_len]u8) !void {
            std.mem.writeInt(u16, out[0..2], @intFromEnum(record.kind), .little);
            std.mem.writeInt(u16, out[2..4], try encodeNodeTextLenMinusOne(record.text_len), .little);
            std.mem.writeInt(u32, out[4..8], try encodeNodeTextOffset(record.text_offset), .little);
        }

        pub fn encodeDenseUniformKindNodeByIdRecord(record: NodeByIdRecord, out: *[NodeByIdRecord.dense_uniform_kind_encoded_len]u8) !void {
            std.mem.writeInt(u16, out[0..2], try encodeNodeTextLenMinusOne(record.text_len), .little);
            std.mem.writeInt(u32, out[2..6], try encodeNodeTextOffset(record.text_offset), .little);
        }

        pub fn encodeNodeTextLenMinusOne(text_len: u32) !u16 {
            if (text_len == 0 or text_len > max_text_bytes) return error.InvalidRecord;
            return @intCast(text_len - 1);
        }

        pub fn encodeNodeTextOffset(text_offset: u64) !u32 {
            return std.math.cast(u32, text_offset) orelse error.RecordTooLarge;
        }

        pub fn decodeNodeTextLen(encoded: u16) u32 {
            return @as(u32, encoded) + 1;
        }

        pub fn decodeSparseNodeByIdRecord(bytes: []const u8) !NodeByIdRecord {
            if (bytes.len != NodeByIdRecord.sparse_encoded_len) return error.InvalidRecord;
            return .{
                .id = core.NodeId.fromInt(std.mem.readInt(u64, bytes[0..8], .little)),
                .kind = kindFromInt(std.mem.readInt(u16, bytes[8..10], .little)) orelse return error.InvalidRecord,
                .text_len = decodeNodeTextLen(std.mem.readInt(u16, bytes[10..12], .little)),
                .text_offset = std.mem.readInt(u32, bytes[12..16], .little),
            };
        }

        pub fn decodeNodeByIdRecord(bytes: []const u8, header: IndexHeader, index: u64) !NodeByIdRecord {
            if (nodeByIdHeaderUsesDenseIds(header)) {
                if (nodeByIdHeaderUsesUniformKind(header)) {
                    if (bytes.len != NodeByIdRecord.dense_uniform_kind_encoded_len) return error.InvalidRecord;
                    const id = std.math.add(u64, header.id_base, index) catch return error.InvalidRecord;
                    return .{
                        .id = core.NodeId.fromInt(id),
                        .kind = header.uniform_kind orelse return error.InvalidRecord,
                        .text_len = decodeNodeTextLen(std.mem.readInt(u16, bytes[0..2], .little)),
                        .text_offset = std.mem.readInt(u32, bytes[2..6], .little),
                    };
                }
                if (bytes.len != NodeByIdRecord.dense_encoded_len) return error.InvalidRecord;
                const id = std.math.add(u64, header.id_base, index) catch return error.InvalidRecord;
                return .{
                    .id = core.NodeId.fromInt(id),
                    .kind = kindFromInt(std.mem.readInt(u16, bytes[0..2], .little)) orelse return error.InvalidRecord,
                    .text_len = decodeNodeTextLen(std.mem.readInt(u16, bytes[2..4], .little)),
                    .text_offset = std.mem.readInt(u32, bytes[4..8], .little),
                };
            }
            if (nodeByIdHeaderUsesUniformKind(header)) {
                if (bytes.len != NodeByIdRecord.sparse_uniform_kind_encoded_len) return error.InvalidRecord;
                return .{
                    .id = core.NodeId.fromInt(std.mem.readInt(u64, bytes[0..8], .little)),
                    .kind = header.uniform_kind orelse return error.InvalidRecord,
                    .text_len = decodeNodeTextLen(std.mem.readInt(u16, bytes[8..10], .little)),
                    .text_offset = std.mem.readInt(u32, bytes[10..14], .little),
                };
            }
            return try decodeSparseNodeByIdRecord(bytes);
        }

        pub fn decodeNodeByIdRecordAt(bytes: []const u8, header: IndexHeader, index: u64) !NodeByIdRecord {
            if (index >= header.node_count) return error.InvalidRecord;
            const offset = try recordOffset(index, header.record_len);
            const record_len: usize = header.record_len;
            return try decodeNodeByIdRecord(bytes[offset..][0..record_len], header, index);
        }

        pub fn validateNodeByIdRecordDigest(bytes: []const u8, header: IndexHeader) !void {
            var digest = std.hash.Wyhash.init(0x544B_4E49);
            var logical_bytes: [NodeByIdRecord.logical_encoded_len]u8 = undefined;
            var index: u64 = 0;
            while (index < header.node_count) : (index += 1) {
                const record = try decodeNodeByIdRecordAt(bytes, header, index);
                encodeNodeByIdLogicalRecord(record, &logical_bytes);
                digest.update(&logical_bytes);
            }
            if (digest.final() != header.record_digest) return error.InvalidRecord;
        }

        pub fn encodeExactTextLogicalRecord(record: ExactTextRecord, out: *[ExactTextRecord.logical_encoded_len]u8) void {
            std.mem.writeInt(u64, out[0..8], record.id.toInt(), .little);
        }

        pub fn encodeDenseOrdinalExactTextRecord(record: ExactTextRecord, id_base: u64, out: *[ExactTextRecord.dense_ordinal_encoded_len]u8) !void {
            const id = record.id.toInt();
            if (id < id_base) return error.InvalidRecord;
            const ordinal = id - id_base;
            if (ordinal > std.math.maxInt(u32)) return error.RecordTooLarge;
            std.mem.writeInt(u32, out[0..4], @intCast(ordinal), .little);
        }

        pub fn decodeExactTextRecord(bytes: []const u8, header: IndexHeader) !ExactTextRecord {
            if (exactTextHeaderUsesDenseOrdinals(header)) {
                if (bytes.len != ExactTextRecord.dense_ordinal_encoded_len) return error.InvalidRecord;
                const ordinal = std.mem.readInt(u32, bytes[0..4], .little);
                const id = std.math.add(u64, header.id_base, ordinal) catch return error.InvalidRecord;
                return .{ .id = core.NodeId.fromInt(id) };
            }
            if (bytes.len != ExactTextRecord.id_encoded_len) return error.InvalidRecord;
            return .{
                .id = core.NodeId.fromInt(std.mem.readInt(u64, bytes[0..8], .little)),
            };
        }

        pub fn validateExactRecordDigest(bytes: []const u8, header: IndexHeader) !void {
            var digest = std.hash.Wyhash.init(0x544B_4E45);
            var logical_bytes: [ExactTextRecord.logical_encoded_len]u8 = undefined;
            var index: u64 = 0;
            while (index < header.node_count) : (index += 1) {
                const offset = try recordOffset(index, header.record_len);
                const record_len: usize = header.record_len;
                const record = try decodeExactTextRecord(bytes[offset..][0..record_len], header);
                encodeExactTextLogicalRecord(record, &logical_bytes);
                digest.update(&logical_bytes);
            }
            if (digest.final() != header.record_digest) return error.InvalidRecord;
        }

        pub fn recordOffset(index: u64, record_len: usize) !u64 {
            const payload_offset = std.math.mul(u64, index, record_len) catch return error.RecordTooLarge;
            return std.math.add(u64, IndexHeader.encoded_len, payload_offset) catch return error.RecordTooLarge;
        }

        pub fn validNodeId(id: core.NodeId) bool {
            return id != .none and id.toInt() != std.math.maxInt(u64);
        }

        fn kindFromInt(value: u16) ?core.NodeKind {
            inline for (@typeInfo(core.NodeKind).@"enum".fields) |field| {
                if (field.value == value) return @enumFromInt(value);
            }
            return null;
        }

        fn allZero(bytes: []const u8) bool {
            for (bytes) |byte| {
                if (byte != 0) return false;
            }
            return true;
        }
    };
}

const TestCore = struct {
    const NodeId = enum(u64) {
        none = 0,
        _,

        fn fromInt(value: u64) NodeId {
            return @enumFromInt(value);
        }

        fn toInt(self: NodeId) u64 {
            return @intFromEnum(self);
        }
    };

    const NodeKind = enum(u16) {
        repo,
        file,
        task,
        _,
    };
};

const test_format = SegmentNodeIndexFormat(TestCore, 1024, 64 * 1024);

fn sparseNodeIndexBytes(record: test_format.NodeByIdRecord, texts_bytes: u64, texts_digest: u64) ![test_format.IndexHeader.encoded_len + test_format.NodeByIdRecord.sparse_encoded_len]u8 {
    var logical: [test_format.NodeByIdRecord.logical_encoded_len]u8 = undefined;
    test_format.encodeNodeByIdLogicalRecord(record, &logical);
    var digest = std.hash.Wyhash.init(0x544B_4E49);
    digest.update(&logical);

    var bytes: [test_format.IndexHeader.encoded_len + test_format.NodeByIdRecord.sparse_encoded_len]u8 = undefined;
    test_format.encodeIndexHeader(.{
        .magic = test_format.NodeByIdRecord.magic,
        .record_len = test_format.NodeByIdRecord.sparse_encoded_len,
        .node_count = 1,
        .texts_bytes = texts_bytes,
        .record_digest = digest.final(),
        .texts_digest = texts_digest,
    }, bytes[0..test_format.IndexHeader.encoded_len]);
    try test_format.encodeSparseNodeByIdRecord(record, bytes[test_format.IndexHeader.encoded_len..][0..test_format.NodeByIdRecord.sparse_encoded_len]);
    return bytes;
}

test "segment node index format header preserves v7 bytes and identity" {
    const record = test_format.NodeByIdRecord{ .id = .fromInt(42), .kind = .file, .text_offset = 7, .text_len = 3 };
    const bytes = try sparseNodeIndexBytes(record, 10, 0x1122_3344_5566_7788);
    try std.testing.expectEqualSlices(u8, "TKNI", bytes[0..4]);
    try std.testing.expectEqual(@as(u16, 7), std.mem.readInt(u16, bytes[4..6], .little));
    try std.testing.expectEqual(@as(u16, 56), std.mem.readInt(u16, bytes[6..8], .little));
    try std.testing.expectEqual(@as(u16, 16), std.mem.readInt(u16, bytes[8..10], .little));
    try std.testing.expectEqual(@as(u64, 1), std.mem.readInt(u64, bytes[16..24], .little));
    try std.testing.expectEqual(@as(u64, 10), std.mem.readInt(u64, bytes[24..32], .little));

    const header = try test_format.decodeNodeByIdIndexHeader(&bytes, 10, 0x1122_3344_5566_7788);
    try std.testing.expectEqual(@as(u16, test_format.NodeByIdRecord.sparse_encoded_len), header.record_len);
    try std.testing.expectEqual(@as(u64, 0), header.id_base);
    try std.testing.expectEqual(record, try test_format.decodeNodeByIdRecordAt(&bytes, header, 0));
}

test "segment node index format rejects corrupt flags sizes and digests" {
    const record = test_format.NodeByIdRecord{ .id = .fromInt(7), .kind = .task, .text_offset = 0, .text_len = 4 };
    const original = try sparseNodeIndexBytes(record, 4, 0x8877);

    var bytes = original;
    bytes[4] = 6;
    try std.testing.expectError(error.InvalidRecord, test_format.decodeNodeByIdIndexHeader(&bytes, 4, 0x8877));

    bytes = original;
    std.mem.writeInt(u16, bytes[10..12], 2, .little);
    try std.testing.expectError(error.InvalidRecord, test_format.decodeNodeByIdIndexHeader(&bytes, 4, 0x8877));

    bytes = original;
    bytes[14] = 1;
    try std.testing.expectError(error.InvalidRecord, test_format.decodeNodeByIdIndexHeader(&bytes, 4, 0x8877));

    try std.testing.expectError(error.InvalidRecord, test_format.decodeNodeByIdIndexHeader(original[0 .. original.len - 1], 4, 0x8877));
    try std.testing.expectError(error.InvalidRecord, test_format.decodeNodeByIdIndexHeader(&original, 4, 0x8878));
}

test "segment node index format validates dense and exact header coupling" {
    const nodes_dense = test_format.IndexHeader{
        .magic = test_format.NodeByIdRecord.magic,
        .record_len = test_format.NodeByIdRecord.dense_encoded_len,
        .node_count = 2,
        .texts_bytes = 8,
        .record_digest = 1,
        .texts_digest = 2,
        .id_base = 10,
    };
    const exact_dense = test_format.IndexHeader{
        .magic = test_format.ExactTextRecord.magic,
        .record_len = test_format.ExactTextRecord.dense_ordinal_encoded_len,
        .node_count = 2,
        .texts_bytes = 8,
        .record_digest = 3,
        .texts_digest = 2,
        .id_base = 10,
    };
    try test_format.validateExactTextHeader(exact_dense, nodes_dense);

    var wrong_base = exact_dense;
    wrong_base.id_base = 11;
    try std.testing.expectError(error.InvalidRecord, test_format.validateExactTextHeader(wrong_base, nodes_dense));

    var sparse_exact = exact_dense;
    sparse_exact.record_len = test_format.ExactTextRecord.id_encoded_len;
    try std.testing.expectError(error.InvalidRecord, test_format.validateExactTextHeader(sparse_exact, nodes_dense));

    var sparse_nodes = nodes_dense;
    sparse_nodes.record_len = test_format.NodeByIdRecord.sparse_encoded_len;
    sparse_nodes.id_base = 0;
    try std.testing.expectError(error.InvalidRecord, test_format.validateExactTextHeader(exact_dense, sparse_nodes));
}

test "segment node index format node records preserve all compact shapes" {
    const record = test_format.NodeByIdRecord{ .id = .fromInt(101), .kind = .file, .text_offset = 1234, .text_len = 64 * 1024 };

    var sparse: [test_format.NodeByIdRecord.sparse_encoded_len]u8 = undefined;
    try test_format.encodeSparseNodeByIdRecord(record, &sparse);
    try std.testing.expectEqual(record, try test_format.decodeSparseNodeByIdRecord(&sparse));

    var sparse_uniform: [test_format.NodeByIdRecord.sparse_uniform_kind_encoded_len]u8 = undefined;
    try test_format.encodeSparseUniformKindNodeByIdRecord(record, &sparse_uniform);
    const sparse_uniform_header = test_format.IndexHeader{
        .magic = test_format.NodeByIdRecord.magic,
        .record_len = test_format.NodeByIdRecord.sparse_uniform_kind_encoded_len,
        .flags = test_format.IndexHeader.flag_uniform_kind,
        .uniform_kind = .file,
        .node_count = 1,
        .texts_bytes = 64 * 1024,
        .record_digest = 0,
        .texts_digest = 0,
    };
    try std.testing.expectEqual(record, try test_format.decodeNodeByIdRecord(&sparse_uniform, sparse_uniform_header, 0));

    var dense: [test_format.NodeByIdRecord.dense_encoded_len]u8 = undefined;
    try test_format.encodeDenseNodeByIdRecord(record, &dense);
    var dense_header = sparse_uniform_header;
    dense_header.record_len = test_format.NodeByIdRecord.dense_encoded_len;
    dense_header.flags = 0;
    dense_header.uniform_kind = null;
    dense_header.id_base = 100;
    try std.testing.expectEqual(record, try test_format.decodeNodeByIdRecord(&dense, dense_header, 1));

    var dense_uniform: [test_format.NodeByIdRecord.dense_uniform_kind_encoded_len]u8 = undefined;
    try test_format.encodeDenseUniformKindNodeByIdRecord(record, &dense_uniform);
    dense_header.record_len = test_format.NodeByIdRecord.dense_uniform_kind_encoded_len;
    dense_header.flags = test_format.IndexHeader.flag_uniform_kind;
    dense_header.uniform_kind = .file;
    try std.testing.expectEqual(record, try test_format.decodeNodeByIdRecord(&dense_uniform, dense_header, 1));
}

test "segment node index format exact records preserve ordinal and sparse ids" {
    const record = test_format.ExactTextRecord{ .id = .fromInt(123) };
    var ordinal: [test_format.ExactTextRecord.dense_ordinal_encoded_len]u8 = undefined;
    try test_format.encodeDenseOrdinalExactTextRecord(record, 100, &ordinal);
    try std.testing.expectEqual(@as(u32, 23), std.mem.readInt(u32, &ordinal, .little));

    const dense_header = test_format.IndexHeader{
        .magic = test_format.ExactTextRecord.magic,
        .record_len = test_format.ExactTextRecord.dense_ordinal_encoded_len,
        .node_count = 1,
        .texts_bytes = 1,
        .record_digest = 0,
        .texts_digest = 0,
        .id_base = 100,
    };
    try std.testing.expectEqual(record, try test_format.decodeExactTextRecord(&ordinal, dense_header));

    var id_bytes: [test_format.ExactTextRecord.id_encoded_len]u8 = undefined;
    test_format.encodeExactTextLogicalRecord(record, &id_bytes);
    var id_header = dense_header;
    id_header.record_len = test_format.ExactTextRecord.id_encoded_len;
    id_header.id_base = 0;
    try std.testing.expectEqual(record, try test_format.decodeExactTextRecord(&id_bytes, id_header));
    try std.testing.expectError(error.InvalidRecord, test_format.encodeDenseOrdinalExactTextRecord(.{ .id = .fromInt(99) }, 100, &ordinal));
    try std.testing.expectError(error.RecordTooLarge, test_format.encodeDenseOrdinalExactTextRecord(.{ .id = .fromInt(@as(u64, std.math.maxInt(u32)) + 101) }, 100, &ordinal));
}

test "segment node index format logical digests reject payload corruption" {
    const record = test_format.NodeByIdRecord{ .id = .fromInt(44), .kind = .repo, .text_offset = 9, .text_len = 5 };
    var node_bytes = try sparseNodeIndexBytes(record, 14, 0x1234);
    const node_header = try test_format.decodeNodeByIdIndexHeader(&node_bytes, 14, 0x1234);
    try test_format.validateNodeByIdRecordDigest(&node_bytes, node_header);
    node_bytes[node_bytes.len - 1] ^= 1;
    try std.testing.expectError(error.InvalidRecord, test_format.validateNodeByIdRecordDigest(&node_bytes, node_header));

    const exact = test_format.ExactTextRecord{ .id = .fromInt(44) };
    var logical: [test_format.ExactTextRecord.logical_encoded_len]u8 = undefined;
    test_format.encodeExactTextLogicalRecord(exact, &logical);
    var digest = std.hash.Wyhash.init(0x544B_4E45);
    digest.update(&logical);
    var exact_bytes: [test_format.IndexHeader.encoded_len + test_format.ExactTextRecord.id_encoded_len]u8 = undefined;
    test_format.encodeIndexHeader(.{
        .magic = test_format.ExactTextRecord.magic,
        .record_len = test_format.ExactTextRecord.id_encoded_len,
        .node_count = 1,
        .texts_bytes = 14,
        .record_digest = digest.final(),
        .texts_digest = 0x1234,
    }, exact_bytes[0..test_format.IndexHeader.encoded_len]);
    @memcpy(exact_bytes[test_format.IndexHeader.encoded_len..], &logical);
    const exact_header = try test_format.decodeIndexHeader(&exact_bytes, test_format.ExactTextRecord.magic, 0, 14, 0x1234);
    try test_format.validateExactRecordDigest(&exact_bytes, exact_header);
    exact_bytes[exact_bytes.len - 1] ^= 1;
    try std.testing.expectError(error.InvalidRecord, test_format.validateExactRecordDigest(&exact_bytes, exact_header));
}

test "segment node index format offset arithmetic and ids reject invalid bounds" {
    try std.testing.expectEqual(@as(u64, test_format.IndexHeader.encoded_len), try test_format.recordOffset(0, 16));
    try std.testing.expectEqual(@as(u64, test_format.IndexHeader.encoded_len + 48), try test_format.recordOffset(3, 16));
    try std.testing.expectError(error.RecordTooLarge, test_format.recordOffset(std.math.maxInt(u64), std.math.maxInt(usize)));
    try std.testing.expect(!test_format.validNodeId(.none));
    try std.testing.expect(!test_format.validNodeId(.fromInt(std.math.maxInt(u64))));
    try std.testing.expect(test_format.validNodeId(.fromInt(1)));
    try std.testing.expectError(error.InvalidRecord, test_format.encodeNodeTextLenMinusOne(0));
    try std.testing.expectError(error.InvalidRecord, test_format.encodeNodeTextLenMinusOne(64 * 1024 + 1));
    try std.testing.expectError(error.RecordTooLarge, test_format.encodeNodeTextOffset(@as(u64, std.math.maxInt(u32)) + 1));
}
