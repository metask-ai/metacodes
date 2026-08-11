const std = @import("std");

/// Instantiate the catalog byte contracts with the public core type namespace.
/// Keeping that dependency explicit lets this module compile and fuzz in
/// isolation while the facade still exposes records returning `core.NodeKind`.
pub fn CatalogFormat(comptime core: type) type {
    return struct {
        /// One version governs every file that makes up the persistent text catalog.
        /// Bump this only alongside an explicit compatibility or rebuild decision.
        pub const persistent_text_index_version: u16 = 76;
        pub const tokenizer_version: u16 = 12;

        pub const persistent_doc_max_field_tokens: u64 = std.math.maxInt(u16);
        pub const persistent_doc_node_id_inline_max: u64 = std.math.maxInt(u32) - 1;
        pub const persistent_doc_node_id_overflow_marker: u32 = std.math.maxInt(u32);
        pub const persistent_posting_max_doc_id: u64 = std.math.maxInt(u32) - 1;
        const persistent_doc_node_id_overflow_record_len: usize = 12;

        pub const PersistentTextMeta = struct {
            node_digest: u64 = 0,
            node_by_text_order_digest: u64 = 0,
            searchable_metadata_digest: u64 = 0,
            doc_count: u64 = 0,
            total_text_tokens: u64 = 0,
            term_count: u64 = 0,
            term_bytes: u64 = 0,
            posting_count: u64 = 0,
            tokenizer: u16 = tokenizer_version,

            const magic = [_]u8{ 'T', 'K', 'G', 'T' };
            pub const encoded_len: usize = 88;

            pub fn encode(self: PersistentTextMeta, out: *[encoded_len]u8) void {
                @memcpy(out[0..4], &magic);
                std.mem.writeInt(u16, out[4..6], persistent_text_index_version, .little);
                std.mem.writeInt(u16, out[6..8], encoded_len, .little);
                std.mem.writeInt(u64, out[8..16], self.node_digest, .little);
                std.mem.writeInt(u64, out[16..24], self.node_by_text_order_digest, .little);
                std.mem.writeInt(u64, out[24..32], self.searchable_metadata_digest, .little);
                std.mem.writeInt(u64, out[32..40], self.doc_count, .little);
                std.mem.writeInt(u64, out[40..48], self.total_text_tokens, .little);
                std.mem.writeInt(u64, out[48..56], self.term_count, .little);
                std.mem.writeInt(u64, out[56..64], self.term_bytes, .little);
                std.mem.writeInt(u64, out[64..72], self.posting_count, .little);
                std.mem.writeInt(u16, out[72..74], self.tokenizer, .little);
                @memset(out[74..88], 0);
                std.mem.writeInt(u32, out[80..84], persistentTextMetaChecksum(out), .little);
            }

            pub fn decode(bytes: *const [encoded_len]u8) !PersistentTextMeta {
                if (!std.mem.eql(u8, bytes[0..4], &magic)) return error.InvalidRecord;
                if (std.mem.readInt(u16, bytes[4..6], .little) != persistent_text_index_version) return error.InvalidRecord;
                if (std.mem.readInt(u16, bytes[6..8], .little) != encoded_len) return error.InvalidRecord;
                if (!allZero(bytes[74..80]) or !allZero(bytes[84..88])) return error.InvalidRecord;
                const expected_checksum = std.mem.readInt(u32, bytes[80..84], .little);
                var checksum_bytes = bytes.*;
                @memset(checksum_bytes[80..84], 0);
                if (expected_checksum != persistentTextMetaChecksum(&checksum_bytes)) return error.InvalidRecord;
                const tokenizer = std.mem.readInt(u16, bytes[72..74], .little);
                if (tokenizer != tokenizer_version) return error.InvalidRecord;
                return .{
                    .node_digest = std.mem.readInt(u64, bytes[8..16], .little),
                    .node_by_text_order_digest = std.mem.readInt(u64, bytes[16..24], .little),
                    .searchable_metadata_digest = std.mem.readInt(u64, bytes[24..32], .little),
                    .doc_count = std.mem.readInt(u64, bytes[32..40], .little),
                    .total_text_tokens = std.mem.readInt(u64, bytes[40..48], .little),
                    .term_count = std.mem.readInt(u64, bytes[48..56], .little),
                    .term_bytes = std.mem.readInt(u64, bytes[56..64], .little),
                    .posting_count = std.mem.readInt(u64, bytes[64..72], .little),
                    .tokenizer = tokenizer,
                };
            }
        };

        pub const TextDocsHeader = struct {
            doc_count: u64 = 0,
            node_id_overflow_count: u64 = 0,
            flags: u16 = 0,
            uniform_kind: u16 = 0,
            dense_node_id_base: u32 = 0,

            const magic = [_]u8{ 'T', 'K', 'G', 'D' };
            pub const encoded_len: usize = 32;
            const flag_dense_node_ids: u16 = 1;
            const flag_uniform_kind: u16 = 2;
            const allowed_flags: u16 = flag_dense_node_ids | flag_uniform_kind;

            pub fn encode(self: TextDocsHeader, out: *[encoded_len]u8) void {
                @memcpy(out[0..4], &magic);
                std.mem.writeInt(u16, out[4..6], persistent_text_index_version, .little);
                std.mem.writeInt(u16, out[6..8], encoded_len, .little);
                std.mem.writeInt(u64, out[8..16], self.doc_count, .little);
                std.mem.writeInt(u64, out[16..24], self.node_id_overflow_count, .little);
                std.mem.writeInt(u16, out[24..26], self.flags, .little);
                std.mem.writeInt(u16, out[26..28], self.uniform_kind, .little);
                std.mem.writeInt(u32, out[28..32], self.dense_node_id_base, .little);
            }

            pub fn decode(bytes: []const u8) !TextDocsHeader {
                if (bytes.len != encoded_len) return error.InvalidRecord;
                if (!std.mem.eql(u8, bytes[0..4], &magic)) return error.InvalidRecord;
                if (std.mem.readInt(u16, bytes[4..6], .little) != persistent_text_index_version) return error.InvalidRecord;
                if (std.mem.readInt(u16, bytes[6..8], .little) != encoded_len) return error.InvalidRecord;
                const header = TextDocsHeader{
                    .doc_count = std.mem.readInt(u64, bytes[8..16], .little),
                    .node_id_overflow_count = std.mem.readInt(u64, bytes[16..24], .little),
                    .flags = std.mem.readInt(u16, bytes[24..26], .little),
                    .uniform_kind = std.mem.readInt(u16, bytes[26..28], .little),
                    .dense_node_id_base = std.mem.readInt(u32, bytes[28..32], .little),
                };
                try header.validateShape();
                return header;
            }

            pub fn validateShape(self: TextDocsHeader) !void {
                if (self.node_id_overflow_count > self.doc_count) return error.InvalidRecord;
                if ((self.flags & ~allowed_flags) != 0) return error.InvalidRecord;
                const compact = self.hasDenseNodeIds() and self.hasUniformKind();
                if (compact) {
                    if (self.doc_count == 0) return error.InvalidRecord;
                    if (self.node_id_overflow_count != 0) return error.InvalidRecord;
                    if (self.dense_node_id_base == 0) return error.InvalidRecord;
                    if (nodeKindFromInt(self.uniform_kind) == null) return error.InvalidRecord;
                    const max_node_id = std.math.add(u64, self.dense_node_id_base, self.doc_count - 1) catch return error.InvalidRecord;
                    if (max_node_id > persistent_doc_node_id_inline_max) return error.InvalidRecord;
                } else if (self.flags != 0 or self.uniform_kind != 0 or self.dense_node_id_base != 0) {
                    return error.InvalidRecord;
                }
            }

            pub fn denseUniform(doc_count: u64, dense_node_id_base: u32, uniform_kind: core.NodeKind) TextDocsHeader {
                return .{
                    .doc_count = doc_count,
                    .flags = flag_dense_node_ids | flag_uniform_kind,
                    .uniform_kind = @intFromEnum(uniform_kind),
                    .dense_node_id_base = dense_node_id_base,
                };
            }

            pub fn hasDenseNodeIds(self: TextDocsHeader) bool {
                return (self.flags & flag_dense_node_ids) != 0;
            }

            pub fn hasUniformKind(self: TextDocsHeader) bool {
                return (self.flags & flag_uniform_kind) != 0;
            }

            pub fn hasDenseUniformRecords(self: TextDocsHeader) bool {
                return self.hasDenseNodeIds() and self.hasUniformKind();
            }

            pub fn recordLen(self: TextDocsHeader) u16 {
                return if (self.hasDenseUniformRecords()) TextDocRecord.dense_uniform_encoded_len else TextDocRecord.encoded_len;
            }
        };

        pub const TextDocRecord = struct {
            doc_id: u64,
            node_id: u64,
            kind: u16,
            text_tokens: u32,

            pub const encoded_len: usize = 8;
            pub const dense_uniform_encoded_len: usize = 2;

            pub fn encode(self: TextDocRecord, out: *[encoded_len]u8) !void {
                if (self.doc_id == 0 or self.node_id == 0) return error.InvalidRecord;
                if (self.doc_id == std.math.maxInt(u64) or self.node_id == std.math.maxInt(u64)) return error.InvalidRecord;
                if (nodeKindFromInt(self.kind) == null) return error.InvalidRecord;
                if (self.text_tokens > persistent_doc_max_field_tokens) return error.RecordTooLarge;
                const persisted_node_id: u32 = if (self.node_id > persistent_doc_node_id_inline_max)
                    persistent_doc_node_id_overflow_marker
                else
                    @intCast(self.node_id);
                std.mem.writeInt(u32, out[0..4], persisted_node_id, .little);
                std.mem.writeInt(u16, out[4..6], self.kind, .little);
                std.mem.writeInt(u16, out[6..8], @intCast(self.text_tokens), .little);
            }

            pub fn decode(bytes: []const u8, doc_id: u64) !TextDocRecord {
                return decodeWithOverflow(bytes, doc_id, null);
            }

            pub fn encodeForHeader(self: TextDocRecord, header: TextDocsHeader, out: []u8) !void {
                if (out.len != header.recordLen()) return error.InvalidRecord;
                if (!header.hasDenseUniformRecords()) {
                    var full: [encoded_len]u8 = undefined;
                    try self.encode(&full);
                    @memcpy(out, &full);
                    return;
                }
                if (self.doc_id == 0 or self.doc_id > header.doc_count) return error.InvalidRecord;
                const expected_node_id = std.math.add(u64, header.dense_node_id_base, self.doc_id - 1) catch return error.InvalidRecord;
                if (self.node_id != expected_node_id) return error.InvalidRecord;
                if (self.kind != header.uniform_kind) return error.InvalidRecord;
                if (self.text_tokens > persistent_doc_max_field_tokens) return error.RecordTooLarge;
                std.mem.writeInt(u16, out[0..2], @intCast(self.text_tokens), .little);
            }

            pub fn decodeForHeader(bytes: []const u8, header: TextDocsHeader, index: u64, overflow_node_id: ?u64) !TextDocRecord {
                if (bytes.len != header.recordLen()) return error.InvalidRecord;
                const doc_id = try nextPersistentTextDocId(index);
                if (!header.hasDenseUniformRecords()) return decodeWithOverflow(bytes, doc_id, overflow_node_id);
                if (overflow_node_id != null) return error.InvalidRecord;
                const node_id = std.math.add(u64, header.dense_node_id_base, index) catch return error.InvalidRecord;
                if (node_id == 0 or node_id > persistent_doc_node_id_inline_max) return error.InvalidRecord;
                return .{
                    .doc_id = doc_id,
                    .node_id = node_id,
                    .kind = header.uniform_kind,
                    .text_tokens = std.mem.readInt(u16, bytes[0..2], .little),
                };
            }

            pub fn decodeWithOverflow(bytes: []const u8, doc_id: u64, overflow_node_id: ?u64) !TextDocRecord {
                if (bytes.len != encoded_len) return error.InvalidRecord;
                if (doc_id == 0 or doc_id == std.math.maxInt(u64)) return error.InvalidRecord;
                const kind = std.mem.readInt(u16, bytes[4..6], .little);
                if (nodeKindFromInt(kind) == null) return error.InvalidRecord;
                const raw_node_id = std.mem.readInt(u32, bytes[0..4], .little);
                const node_id = if (raw_node_id == persistent_doc_node_id_overflow_marker)
                    overflow_node_id orelse return error.InvalidRecord
                else
                    @as(u64, raw_node_id);
                if (node_id == 0 or node_id == std.math.maxInt(u64)) return error.InvalidRecord;
                if (raw_node_id != persistent_doc_node_id_overflow_marker and overflow_node_id != null) return error.InvalidRecord;
                if (raw_node_id == persistent_doc_node_id_overflow_marker and node_id <= persistent_doc_node_id_inline_max) return error.InvalidRecord;
                return .{
                    .doc_id = doc_id,
                    .node_id = node_id,
                    .kind = kind,
                    .text_tokens = std.mem.readInt(u16, bytes[6..8], .little),
                };
            }

            pub fn needsNodeIdOverflow(self: TextDocRecord) bool {
                return self.node_id > persistent_doc_node_id_inline_max;
            }

            pub fn nodeKind(self: TextDocRecord) !core.NodeKind {
                return nodeKindFromInt(self.kind) orelse error.InvalidRecord;
            }
        };

        pub const TextDocNodeIdOverflowRecord = struct {
            doc_id: u64,
            node_id: u64,

            pub const encoded_len: usize = persistent_doc_node_id_overflow_record_len;

            pub fn init(doc: TextDocRecord) !TextDocNodeIdOverflowRecord {
                if (!doc.needsNodeIdOverflow()) return error.InvalidRecord;
                if (doc.doc_id == 0 or doc.doc_id > persistent_posting_max_doc_id) return error.RecordTooLarge;
                if (doc.node_id == std.math.maxInt(u64)) return error.InvalidRecord;
                return .{ .doc_id = doc.doc_id, .node_id = doc.node_id };
            }

            pub fn encode(self: TextDocNodeIdOverflowRecord, out: *[encoded_len]u8) !void {
                if (self.doc_id == 0 or self.doc_id > persistent_posting_max_doc_id) return error.RecordTooLarge;
                if (self.node_id <= persistent_doc_node_id_inline_max or self.node_id == std.math.maxInt(u64)) return error.InvalidRecord;
                std.mem.writeInt(u32, out[0..4], @intCast(self.doc_id), .little);
                std.mem.writeInt(u64, out[4..12], self.node_id, .little);
            }

            pub fn decodeBytes(bytes: []const u8) !TextDocNodeIdOverflowRecord {
                if (bytes.len != encoded_len) return error.InvalidRecord;
                const doc_id = std.mem.readInt(u32, bytes[0..4], .little);
                const node_id = std.mem.readInt(u64, bytes[4..12], .little);
                if (doc_id == 0) return error.InvalidRecord;
                if (node_id <= persistent_doc_node_id_inline_max or node_id == std.math.maxInt(u64)) return error.InvalidRecord;
                return .{ .doc_id = doc_id, .node_id = node_id };
            }

            pub fn decode(bytes: *const [encoded_len]u8) !TextDocNodeIdOverflowRecord {
                return decodeBytes(bytes);
            }
        };

        pub fn nextPersistentTextDocId(current_doc_count: u64) !u64 {
            return std.math.add(u64, current_doc_count, 1) catch return error.RecordTooLarge;
        }

        fn persistentTextMetaChecksum(bytes: *const [PersistentTextMeta.encoded_len]u8) u32 {
            return @truncate(std.hash.Wyhash.hash(0x544B_4754_4D455441, bytes[0..80]));
        }

        fn nodeKindFromInt(value: u16) ?core.NodeKind {
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
    pub const NodeKind = enum(u16) {
        file,
        function,
        document,
    };
};
const test_format = CatalogFormat(TestCore);
const test_persistent_text_index_version = test_format.persistent_text_index_version;
const test_tokenizer_version = test_format.tokenizer_version;
const test_persistent_doc_max_field_tokens = test_format.persistent_doc_max_field_tokens;
const test_persistent_doc_node_id_overflow_marker = test_format.persistent_doc_node_id_overflow_marker;
const TestPersistentTextMeta = test_format.PersistentTextMeta;
const TestTextDocsHeader = test_format.TextDocsHeader;
const TestTextDocRecord = test_format.TextDocRecord;
const TestTextDocNodeIdOverflowRecord = test_format.TextDocNodeIdOverflowRecord;
const testNextPersistentTextDocId = test_format.nextPersistentTextDocId;

test "persistent text metadata has stable bytes and rejects corruption" {
    const meta = TestPersistentTextMeta{
        .node_digest = 0x0102_0304_0506_0708,
        .node_by_text_order_digest = 11,
        .searchable_metadata_digest = 12,
        .doc_count = 13,
        .total_text_tokens = 14,
        .term_count = 15,
        .term_bytes = 16,
        .posting_count = 17,
    };
    var bytes: [TestPersistentTextMeta.encoded_len]u8 = undefined;
    meta.encode(&bytes);

    try std.testing.expectEqualSlices(u8, "TKGT", bytes[0..4]);
    try std.testing.expectEqual(test_persistent_text_index_version, std.mem.readInt(u16, bytes[4..6], .little));
    try std.testing.expectEqual(@as(u16, TestPersistentTextMeta.encoded_len), std.mem.readInt(u16, bytes[6..8], .little));
    try std.testing.expectEqual(meta, try TestPersistentTextMeta.decode(&bytes));

    var corrupt = bytes;
    corrupt[8] ^= 1;
    try std.testing.expectError(error.InvalidRecord, TestPersistentTextMeta.decode(&corrupt));
    corrupt = bytes;
    corrupt[74] = 1;
    try std.testing.expectError(error.InvalidRecord, TestPersistentTextMeta.decode(&corrupt));
    corrupt = bytes;
    std.mem.writeInt(u16, corrupt[72..74], test_tokenizer_version - 1, .little);
    try std.testing.expectError(error.InvalidRecord, TestPersistentTextMeta.decode(&corrupt));
}

test "persistent text document headers preserve legacy and dense layouts" {
    const legacy = TestTextDocsHeader{ .doc_count = 7, .node_id_overflow_count = 2 };
    var bytes: [TestTextDocsHeader.encoded_len]u8 = undefined;
    legacy.encode(&bytes);
    try std.testing.expectEqualSlices(u8, "TKGD", bytes[0..4]);
    try std.testing.expectEqual(legacy, try TestTextDocsHeader.decode(&bytes));

    const dense = TestTextDocsHeader.denseUniform(3, 41, .file);
    dense.encode(&bytes);
    try std.testing.expectEqual(dense, try TestTextDocsHeader.decode(&bytes));
    try std.testing.expectEqual(@as(u16, TestTextDocRecord.dense_uniform_encoded_len), dense.recordLen());

    var invalid = bytes;
    std.mem.writeInt(u64, invalid[16..24], 1, .little);
    try std.testing.expectError(error.InvalidRecord, TestTextDocsHeader.decode(&invalid));
    invalid = bytes;
    invalid[24] |= 0x80;
    try std.testing.expectError(error.InvalidRecord, TestTextDocsHeader.decode(&invalid));
}

test "persistent text document records preserve full dense and overflow layouts" {
    const full = TestTextDocRecord{
        .doc_id = 9,
        .node_id = 42,
        .kind = @intFromEnum(TestCore.NodeKind.function),
        .text_tokens = 321,
    };
    var full_bytes: [TestTextDocRecord.encoded_len]u8 = undefined;
    try full.encode(&full_bytes);
    try std.testing.expectEqual(full, try TestTextDocRecord.decode(&full_bytes, full.doc_id));

    const dense_header = TestTextDocsHeader.denseUniform(4, 100, .file);
    const dense = TestTextDocRecord{
        .doc_id = 3,
        .node_id = 102,
        .kind = @intFromEnum(TestCore.NodeKind.file),
        .text_tokens = 17,
    };
    var dense_bytes: [TestTextDocRecord.dense_uniform_encoded_len]u8 = undefined;
    try dense.encodeForHeader(dense_header, &dense_bytes);
    try std.testing.expectEqual(dense, try TestTextDocRecord.decodeForHeader(&dense_bytes, dense_header, 2, null));

    const overflow = TestTextDocRecord{
        .doc_id = 10,
        .node_id = @as(u64, test_persistent_doc_node_id_overflow_marker) + 99,
        .kind = @intFromEnum(TestCore.NodeKind.document),
        .text_tokens = 7,
    };
    try overflow.encode(&full_bytes);
    try std.testing.expectError(error.InvalidRecord, TestTextDocRecord.decode(&full_bytes, overflow.doc_id));
    const overflow_record = try TestTextDocNodeIdOverflowRecord.init(overflow);
    var overflow_bytes: [TestTextDocNodeIdOverflowRecord.encoded_len]u8 = undefined;
    try overflow_record.encode(&overflow_bytes);
    try std.testing.expectEqual(overflow_record, try TestTextDocNodeIdOverflowRecord.decode(&overflow_bytes));
    try std.testing.expectEqual(overflow, try TestTextDocRecord.decodeWithOverflow(&full_bytes, overflow.doc_id, overflow.node_id));
}

test "persistent text document format rejects reserved values and allocation overflow" {
    try std.testing.expectEqual(@as(u64, 1), try testNextPersistentTextDocId(0));
    try std.testing.expectError(error.RecordTooLarge, testNextPersistentTextDocId(std.math.maxInt(u64)));

    var bytes: [TestTextDocRecord.encoded_len]u8 = undefined;
    try std.testing.expectError(error.InvalidRecord, (TestTextDocRecord{
        .doc_id = 0,
        .node_id = 1,
        .kind = @intFromEnum(TestCore.NodeKind.file),
        .text_tokens = 1,
    }).encode(&bytes));
    try std.testing.expectError(error.RecordTooLarge, (TestTextDocRecord{
        .doc_id = 1,
        .node_id = 1,
        .kind = @intFromEnum(TestCore.NodeKind.file),
        .text_tokens = test_persistent_doc_max_field_tokens + 1,
    }).encode(&bytes));
}
