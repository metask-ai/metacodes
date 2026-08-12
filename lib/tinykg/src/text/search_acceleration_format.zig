const std = @import("std");

/// Persisted byte contracts for the optional search-acceleration sidecars.
/// Rebuild code writes these records and persistent search reads them, while
/// mmap ownership, posting scans, canonical node materialization, and ranking
/// remain outside this format-only module.
pub fn SearchAccelerationFormat(comptime config: type) type {
    return struct {
        pub const TextPostingBlocksHeader = struct {
            term_count: u64,
            posting_count: u64,
            block_count: u64,
            block_size: u64,

            const magic = [_]u8{ 'T', 'K', 'G', 'B' };
            pub const encoded_len: usize = 40;

            fn encode(self: TextPostingBlocksHeader, out: *[encoded_len]u8) void {
                @memcpy(out[0..4], &magic);
                std.mem.writeInt(u16, out[4..6], config.persistent_text_index_version, .little);
                std.mem.writeInt(u16, out[6..8], encoded_len, .little);
                std.mem.writeInt(u64, out[8..16], self.term_count, .little);
                std.mem.writeInt(u64, out[16..24], self.posting_count, .little);
                std.mem.writeInt(u64, out[24..32], self.block_count, .little);
                std.mem.writeInt(u64, out[32..40], self.block_size, .little);
            }

            fn decode(bytes: []const u8) !TextPostingBlocksHeader {
                if (bytes.len != encoded_len) return error.InvalidRecord;
                if (!std.mem.eql(u8, bytes[0..4], &magic)) return error.InvalidRecord;
                if (std.mem.readInt(u16, bytes[4..6], .little) != config.persistent_text_index_version) return error.InvalidRecord;
                if (std.mem.readInt(u16, bytes[6..8], .little) != encoded_len) return error.InvalidRecord;
                const block_size = std.mem.readInt(u64, bytes[32..40], .little);
                if (block_size == 0) return error.InvalidRecord;
                return .{
                    .term_count = std.mem.readInt(u64, bytes[8..16], .little),
                    .posting_count = std.mem.readInt(u64, bytes[16..24], .little),
                    .block_count = std.mem.readInt(u64, bytes[24..32], .little),
                    .block_size = block_size,
                };
            }
        };

        pub const TextPostingBlockRecord = struct {
            max_weighted_tf: f32,
            min_doc_len: f32,
            last_doc_id: u64,

            pub const encoded_len: usize = 8;
            const max_tf_offset: usize = 0;
            const min_doc_len_offset: usize = max_tf_offset + 2;
            const last_doc_id_offset: usize = min_doc_len_offset + 2;

            fn encode(self: TextPostingBlockRecord, out: *[encoded_len]u8) !void {
                if (!std.math.isFinite(self.max_weighted_tf) or self.max_weighted_tf <= 0) return error.InvalidRecord;
                if (!std.math.isFinite(self.min_doc_len) or self.min_doc_len <= 0) return error.InvalidRecord;
                if (self.last_doc_id == 0 or self.last_doc_id > config.persistent_posting_max_doc_id) return error.RecordTooLarge;
                std.mem.writeInt(u16, out[max_tf_offset..min_doc_len_offset], try encodeF16Ceil(self.max_weighted_tf), .little);
                std.mem.writeInt(u16, out[min_doc_len_offset..last_doc_id_offset], try encodeF16Floor(self.min_doc_len), .little);
                std.mem.writeInt(u32, out[last_doc_id_offset..encoded_len], @intCast(self.last_doc_id), .little);
            }

            fn decode(bytes: []const u8) !TextPostingBlockRecord {
                if (bytes.len != encoded_len) return error.InvalidRecord;
                const max_weighted_tf = try decodeF16(std.mem.readInt(u16, bytes[max_tf_offset..min_doc_len_offset], .little));
                const min_doc_len = try decodeF16(std.mem.readInt(u16, bytes[min_doc_len_offset..last_doc_id_offset], .little));
                const last_doc_id = std.mem.readInt(u32, bytes[last_doc_id_offset..encoded_len], .little);
                if (!std.math.isFinite(max_weighted_tf) or max_weighted_tf <= 0) return error.InvalidRecord;
                if (!std.math.isFinite(min_doc_len) or min_doc_len <= 0) return error.InvalidRecord;
                if (last_doc_id == 0) return error.InvalidRecord;
                return .{
                    .max_weighted_tf = max_weighted_tf,
                    .min_doc_len = min_doc_len,
                    .last_doc_id = last_doc_id,
                };
            }

            fn fromStats(stats: anytype) !TextPostingBlockRecord {
                if (stats.last_doc_id == 0 or stats.last_doc_id > config.persistent_posting_max_doc_id) return error.RecordTooLarge;
                return .{
                    .max_weighted_tf = stats.max_weighted_tf,
                    .min_doc_len = stats.min_doc_len,
                    .last_doc_id = stats.last_doc_id,
                };
            }

            fn conservativelyMatches(self: TextPostingBlockRecord, exact: TextPostingBlockRecord) bool {
                return self.max_weighted_tf >= exact.max_weighted_tf and
                    self.min_doc_len <= exact.min_doc_len and
                    self.last_doc_id == exact.last_doc_id;
            }
        };

        pub const TextPostingBlockImpactsHeader = struct {
            term_count: u64,
            block_count: u64,

            const magic = [_]u8{ 'T', 'K', 'G', 'P' };
            pub const encoded_len: usize = 24;

            fn encode(self: TextPostingBlockImpactsHeader, out: *[encoded_len]u8) void {
                @memcpy(out[0..4], &magic);
                std.mem.writeInt(u16, out[4..6], config.persistent_text_index_version, .little);
                std.mem.writeInt(u16, out[6..8], encoded_len, .little);
                std.mem.writeInt(u64, out[8..16], self.term_count, .little);
                std.mem.writeInt(u64, out[16..24], self.block_count, .little);
            }

            fn decode(bytes: []const u8) !TextPostingBlockImpactsHeader {
                if (bytes.len != encoded_len) return error.InvalidRecord;
                if (!std.mem.eql(u8, bytes[0..4], &magic)) return error.InvalidRecord;
                if (std.mem.readInt(u16, bytes[4..6], .little) != config.persistent_text_index_version) return error.InvalidRecord;
                if (std.mem.readInt(u16, bytes[6..8], .little) != encoded_len) return error.InvalidRecord;
                return .{
                    .term_count = std.mem.readInt(u64, bytes[8..16], .little),
                    .block_count = std.mem.readInt(u64, bytes[16..24], .little),
                };
            }
        };

        pub const TextTermTopHitsHeader = struct {
            term_count: u64,
            hit_count: u64,
            hit_term_count: u64,
            capacity: u64,

            const magic = [_]u8{ 'T', 'K', 'G', 'H' };
            pub const encoded_len: usize = 40;

            fn encode(self: TextTermTopHitsHeader, out: *[encoded_len]u8) void {
                @memcpy(out[0..4], &magic);
                std.mem.writeInt(u16, out[4..6], config.persistent_text_index_version, .little);
                std.mem.writeInt(u16, out[6..8], encoded_len, .little);
                std.mem.writeInt(u64, out[8..16], self.term_count, .little);
                std.mem.writeInt(u64, out[16..24], self.hit_count, .little);
                std.mem.writeInt(u64, out[24..32], self.hit_term_count, .little);
                std.mem.writeInt(u64, out[32..40], self.capacity, .little);
            }

            fn decode(bytes: []const u8) !TextTermTopHitsHeader {
                if (bytes.len != encoded_len) return error.InvalidRecord;
                if (!std.mem.eql(u8, bytes[0..4], &magic)) return error.InvalidRecord;
                if (std.mem.readInt(u16, bytes[4..6], .little) != config.persistent_text_index_version) return error.InvalidRecord;
                if (std.mem.readInt(u16, bytes[6..8], .little) != encoded_len) return error.InvalidRecord;
                const term_count = std.mem.readInt(u64, bytes[8..16], .little);
                const hit_count = std.mem.readInt(u64, bytes[16..24], .little);
                const hit_term_count = std.mem.readInt(u64, bytes[24..32], .little);
                const capacity = std.mem.readInt(u64, bytes[32..40], .little);
                if (capacity == 0) return error.InvalidRecord;
                if (hit_term_count > term_count or hit_term_count > hit_count) return error.InvalidRecord;
                if (hit_count != 0 and hit_term_count == 0) return error.InvalidRecord;
                const expected_hit_count = std.math.mul(u64, hit_term_count, capacity) catch return error.InvalidRecord;
                if (hit_count != expected_hit_count) return error.InvalidRecord;
                return .{
                    .term_count = term_count,
                    .hit_count = hit_count,
                    .hit_term_count = hit_term_count,
                    .capacity = capacity,
                };
            }
        };

        pub const TextTermTopHitTermRecord = struct {
            term_index: u64,
            hit_offset: u64,
            hit_count: u64,

            pub const encoded_len: usize = 4;

            fn encode(self: TextTermTopHitTermRecord, out: *[encoded_len]u8) !void {
                if (self.term_index > std.math.maxInt(u32)) return error.RecordTooLarge;
                if (self.hit_count != config.persistent_term_top_hit_capacity) return error.InvalidRecord;
                std.mem.writeInt(u32, out[0..4], @intCast(self.term_index), .little);
            }

            fn decode(bytes: []const u8, ordinal: u64, capacity: u64) !TextTermTopHitTermRecord {
                if (bytes.len != encoded_len) return error.InvalidRecord;
                if (capacity == 0 or capacity > std.math.maxInt(u32)) return error.InvalidRecord;
                return .{
                    .term_index = std.mem.readInt(u32, bytes[0..4], .little),
                    .hit_offset = std.math.mul(u64, ordinal, capacity) catch return error.InvalidRecord,
                    .hit_count = capacity,
                };
            }
        };

        pub const TextTermTopHitRecord = struct {
            doc_id: u64,
            text_freq: u32 = 0,
            node_id: u64 = 0,
            score: f32,

            pub const encoded_len: usize = 6;

            fn encode(self: TextTermTopHitRecord, out: *[encoded_len]u8) !void {
                if (self.doc_id == 0) return error.InvalidRecord;
                if (self.doc_id > config.persistent_posting_max_doc_id) return error.RecordTooLarge;
                if (self.text_freq == 0) return error.InvalidRecord;
                if (self.text_freq > config.persistent_posting_max_field_freq) return error.RecordTooLarge;
                if (self.node_id == std.math.maxInt(u64)) return error.InvalidRecord;
                if (!std.math.isFinite(self.score)) return error.InvalidRecord;
                std.mem.writeInt(u32, out[0..4], @intCast(self.doc_id), .little);
                std.mem.writeInt(u16, out[4..6], @intCast(self.text_freq), .little);
            }

            fn decode(bytes: []const u8) !TextTermTopHitRecord {
                if (bytes.len != encoded_len) return error.InvalidRecord;
                const doc_id = std.mem.readInt(u32, bytes[0..4], .little);
                const text_freq = std.mem.readInt(u16, bytes[4..6], .little);
                if (doc_id == 0) return error.InvalidRecord;
                if (text_freq == 0) return error.InvalidRecord;
                return .{ .doc_id = doc_id, .text_freq = text_freq, .score = 0 };
            }
        };

        pub const Internal = struct {
            pub const persistent_posting_max_block_ordinal: u64 = std.math.maxInt(u32);
            pub const persistent_posting_block_ordinal_len: usize = 4;
            pub const persistent_block_score_f16_max: f32 = @floatCast(std.math.floatMax(f16));
            pub const block_record_max_tf_offset = TextPostingBlockRecord.max_tf_offset;
            pub const block_record_min_doc_len_offset = TextPostingBlockRecord.min_doc_len_offset;

            pub const PersistentBlockScoreBounds = struct {
                max_weighted_tf: f32,
                min_doc_len: f32,
            };

            pub fn encodeBlocksHeader(header: TextPostingBlocksHeader, out: *[TextPostingBlocksHeader.encoded_len]u8) void {
                header.encode(out);
            }

            pub fn decodeBlocksHeader(bytes: []const u8) !TextPostingBlocksHeader {
                return TextPostingBlocksHeader.decode(bytes);
            }

            pub fn encodeBlockRecord(record: TextPostingBlockRecord, out: *[TextPostingBlockRecord.encoded_len]u8) !void {
                return record.encode(out);
            }

            pub fn decodeBlockRecord(bytes: []const u8) !TextPostingBlockRecord {
                return TextPostingBlockRecord.decode(bytes);
            }

            pub fn blockRecordFromStats(stats: anytype) !TextPostingBlockRecord {
                return TextPostingBlockRecord.fromStats(stats);
            }

            pub fn blockRecordConservativelyMatches(stored: TextPostingBlockRecord, exact: TextPostingBlockRecord) bool {
                return stored.conservativelyMatches(exact);
            }

            pub fn quantizeBlockScoreBounds(max_weighted_tf: f32, min_doc_len: f32) !PersistentBlockScoreBounds {
                return .{
                    .max_weighted_tf = try decodeF16(try encodeF16Ceil(max_weighted_tf)),
                    .min_doc_len = try decodeF16(try encodeF16Floor(min_doc_len)),
                };
            }

            pub fn encodeBlockOrdinal(value: u64, out: *[persistent_posting_block_ordinal_len]u8) !void {
                if (value > persistent_posting_max_block_ordinal) return error.RecordTooLarge;
                std.mem.writeInt(u32, out, @intCast(value), .little);
            }

            pub fn decodeBlockOrdinal(bytes: []const u8) !u64 {
                if (bytes.len != persistent_posting_block_ordinal_len) return error.InvalidRecord;
                return std.mem.readInt(u32, bytes[0..4], .little);
            }

            pub fn encodeImpactsHeader(header: TextPostingBlockImpactsHeader, out: *[TextPostingBlockImpactsHeader.encoded_len]u8) void {
                header.encode(out);
            }

            pub fn decodeImpactsHeader(bytes: []const u8) !TextPostingBlockImpactsHeader {
                return TextPostingBlockImpactsHeader.decode(bytes);
            }

            pub fn encodeTopHitsHeader(header: TextTermTopHitsHeader, out: *[TextTermTopHitsHeader.encoded_len]u8) void {
                header.encode(out);
            }

            pub fn decodeTopHitsHeader(bytes: []const u8) !TextTermTopHitsHeader {
                return TextTermTopHitsHeader.decode(bytes);
            }

            pub fn encodeTopHitTermRecord(record: TextTermTopHitTermRecord, out: *[TextTermTopHitTermRecord.encoded_len]u8) !void {
                return record.encode(out);
            }

            pub fn decodeTopHitTermRecord(bytes: []const u8, ordinal: u64, capacity: u64) !TextTermTopHitTermRecord {
                return TextTermTopHitTermRecord.decode(bytes, ordinal, capacity);
            }

            pub fn encodeTopHitRecord(record: TextTermTopHitRecord, out: *[TextTermTopHitRecord.encoded_len]u8) !void {
                return record.encode(out);
            }

            pub fn decodeTopHitRecord(bytes: []const u8) !TextTermTopHitRecord {
                return TextTermTopHitRecord.decode(bytes);
            }
        };

        fn encodeF16Ceil(value: f32) !u16 {
            if (!std.math.isFinite(value) or value <= 0) return error.InvalidRecord;
            if (value > Internal.persistent_block_score_f16_max) return error.RecordTooLarge;
            var half: f16 = @floatCast(value);
            var widened: f32 = @floatCast(half);
            var bits: u16 = @bitCast(half);
            if (widened < value) {
                if (bits >= @as(u16, @bitCast(std.math.floatMax(f16)))) return error.RecordTooLarge;
                bits += 1;
                half = @bitCast(bits);
                widened = @floatCast(half);
            }
            if (!std.math.isFinite(widened) or widened < value) return error.RecordTooLarge;
            return bits;
        }

        fn encodeF16Floor(value: f32) !u16 {
            if (!std.math.isFinite(value) or value <= 0) return error.InvalidRecord;
            var half: f16 = if (value > Internal.persistent_block_score_f16_max)
                std.math.floatMax(f16)
            else
                @floatCast(value);
            var widened: f32 = @floatCast(half);
            var bits: u16 = @bitCast(half);
            if (widened > value) {
                if (bits == 0) return error.RecordTooLarge;
                bits -= 1;
                half = @bitCast(bits);
                widened = @floatCast(half);
            }
            if (!std.math.isFinite(widened) or widened <= 0 or widened > value) return error.RecordTooLarge;
            return bits;
        }

        fn decodeF16(bits: u16) !f32 {
            const value: f32 = @floatCast(@as(f16, @bitCast(bits)));
            if (!std.math.isFinite(value) or value <= 0) return error.InvalidRecord;
            return value;
        }
    };
}

const TestConfig = struct {
    pub const persistent_text_index_version: u16 = 76;
    pub const persistent_posting_max_doc_id: u64 = std.math.maxInt(u32) - 1;
    pub const persistent_posting_max_field_freq: u32 = std.math.maxInt(u16);
    pub const persistent_term_top_hit_capacity: u64 = 64;
};
const test_format = SearchAccelerationFormat(TestConfig);
const TestBlocksHeader = test_format.TextPostingBlocksHeader;
const TestBlockRecord = test_format.TextPostingBlockRecord;
const TestImpactsHeader = test_format.TextPostingBlockImpactsHeader;
const TestTopHitsHeader = test_format.TextTermTopHitsHeader;
const TestTopHitTermRecord = test_format.TextTermTopHitTermRecord;
const TestTopHitRecord = test_format.TextTermTopHitRecord;
const TestInternal = test_format.Internal;

test "search acceleration block header preserves stable bytes" {
    const header = TestBlocksHeader{ .term_count = 3, .posting_count = 257, .block_count = 5, .block_size = 128 };
    var bytes: [TestBlocksHeader.encoded_len]u8 = undefined;
    TestInternal.encodeBlocksHeader(header, &bytes);
    try std.testing.expectEqualSlices(u8, "TKGB", bytes[0..4]);
    try std.testing.expectEqual(TestConfig.persistent_text_index_version, std.mem.readInt(u16, bytes[4..6], .little));
    try std.testing.expectEqual(header, try TestInternal.decodeBlocksHeader(&bytes));
}

test "search acceleration block header rejects corrupt identity and shape" {
    const header = TestBlocksHeader{ .term_count = 1, .posting_count = 1, .block_count = 1, .block_size = 128 };
    var bytes: [TestBlocksHeader.encoded_len]u8 = undefined;
    TestInternal.encodeBlocksHeader(header, &bytes);
    var corrupt = bytes;
    corrupt[0] ^= 1;
    try std.testing.expectError(error.InvalidRecord, TestInternal.decodeBlocksHeader(&corrupt));
    corrupt = bytes;
    std.mem.writeInt(u16, corrupt[4..6], TestConfig.persistent_text_index_version - 1, .little);
    try std.testing.expectError(error.InvalidRecord, TestInternal.decodeBlocksHeader(&corrupt));
    corrupt = bytes;
    std.mem.writeInt(u64, corrupt[32..40], 0, .little);
    try std.testing.expectError(error.InvalidRecord, TestInternal.decodeBlocksHeader(&corrupt));
    try std.testing.expectError(error.InvalidRecord, TestInternal.decodeBlocksHeader(bytes[0 .. bytes.len - 1]));
}

test "search acceleration block records preserve conservative scoring bounds" {
    const exact = TestBlockRecord{ .max_weighted_tf = 1.1, .min_doc_len = 9.9, .last_doc_id = 42 };
    var bytes: [TestBlockRecord.encoded_len]u8 = undefined;
    try TestInternal.encodeBlockRecord(exact, &bytes);
    const stored = try TestInternal.decodeBlockRecord(&bytes);
    try std.testing.expect(TestInternal.blockRecordConservativelyMatches(stored, exact));
    try std.testing.expect(stored.max_weighted_tf >= exact.max_weighted_tf);
    try std.testing.expect(stored.min_doc_len <= exact.min_doc_len);
    const bounds = try TestInternal.quantizeBlockScoreBounds(exact.max_weighted_tf, exact.min_doc_len);
    try std.testing.expect(bounds.max_weighted_tf >= exact.max_weighted_tf);
    try std.testing.expect(bounds.min_doc_len <= exact.min_doc_len);
}

test "search acceleration block records reject invalid bounds and ids" {
    var bytes: [TestBlockRecord.encoded_len]u8 = undefined;
    try std.testing.expectError(error.InvalidRecord, TestInternal.encodeBlockRecord(.{ .max_weighted_tf = 0, .min_doc_len = 1, .last_doc_id = 1 }, &bytes));
    try std.testing.expectError(error.InvalidRecord, TestInternal.encodeBlockRecord(.{ .max_weighted_tf = 1, .min_doc_len = std.math.nan(f32), .last_doc_id = 1 }, &bytes));
    try std.testing.expectError(error.RecordTooLarge, TestInternal.encodeBlockRecord(.{ .max_weighted_tf = TestInternal.persistent_block_score_f16_max * 2.0, .min_doc_len = 1, .last_doc_id = 1 }, &bytes));
    try std.testing.expectError(error.RecordTooLarge, TestInternal.encodeBlockRecord(.{ .max_weighted_tf = 1, .min_doc_len = 1, .last_doc_id = 0 }, &bytes));
    try std.testing.expectError(error.RecordTooLarge, TestInternal.encodeBlockRecord(.{ .max_weighted_tf = 1, .min_doc_len = 1, .last_doc_id = TestConfig.persistent_posting_max_doc_id + 1 }, &bytes));
    @memset(&bytes, 0);
    try std.testing.expectError(error.InvalidRecord, TestInternal.decodeBlockRecord(&bytes));
}

test "search acceleration impact header preserves stable bytes and rejects corruption" {
    const header = TestImpactsHeader{ .term_count = 9, .block_count = 17 };
    var bytes: [TestImpactsHeader.encoded_len]u8 = undefined;
    TestInternal.encodeImpactsHeader(header, &bytes);
    try std.testing.expectEqualSlices(u8, "TKGP", bytes[0..4]);
    try std.testing.expectEqual(header, try TestInternal.decodeImpactsHeader(&bytes));
    var corrupt = bytes;
    corrupt[0] ^= 1;
    try std.testing.expectError(error.InvalidRecord, TestInternal.decodeImpactsHeader(&corrupt));
    corrupt = bytes;
    std.mem.writeInt(u16, corrupt[6..8], TestImpactsHeader.encoded_len - 1, .little);
    try std.testing.expectError(error.InvalidRecord, TestInternal.decodeImpactsHeader(&corrupt));
}

test "search acceleration top-hit header validates sparse shape" {
    const header = TestTopHitsHeader{ .term_count = 11, .hit_count = 128, .hit_term_count = 2, .capacity = 64 };
    var bytes: [TestTopHitsHeader.encoded_len]u8 = undefined;
    TestInternal.encodeTopHitsHeader(header, &bytes);
    try std.testing.expectEqualSlices(u8, "TKGH", bytes[0..4]);
    try std.testing.expectEqual(header, try TestInternal.decodeTopHitsHeader(&bytes));
    var invalid = header;
    invalid.hit_count = 127;
    TestInternal.encodeTopHitsHeader(invalid, &bytes);
    try std.testing.expectError(error.InvalidRecord, TestInternal.decodeTopHitsHeader(&bytes));
    invalid = header;
    invalid.hit_term_count = invalid.term_count + 1;
    TestInternal.encodeTopHitsHeader(invalid, &bytes);
    try std.testing.expectError(error.InvalidRecord, TestInternal.decodeTopHitsHeader(&bytes));
    invalid = header;
    invalid.capacity = 0;
    TestInternal.encodeTopHitsHeader(invalid, &bytes);
    try std.testing.expectError(error.InvalidRecord, TestInternal.decodeTopHitsHeader(&bytes));
}

test "search acceleration top-hit term records derive offsets and reject invalid capacities" {
    const record = TestTopHitTermRecord{ .term_index = std.math.maxInt(u32), .hit_offset = 0, .hit_count = TestConfig.persistent_term_top_hit_capacity };
    var bytes: [TestTopHitTermRecord.encoded_len]u8 = undefined;
    try TestInternal.encodeTopHitTermRecord(record, &bytes);
    const decoded = try TestInternal.decodeTopHitTermRecord(&bytes, 7, TestConfig.persistent_term_top_hit_capacity);
    try std.testing.expectEqual(record.term_index, decoded.term_index);
    try std.testing.expectEqual(@as(u64, 7 * TestConfig.persistent_term_top_hit_capacity), decoded.hit_offset);
    try std.testing.expectEqual(record.hit_count, decoded.hit_count);
    try std.testing.expectError(error.RecordTooLarge, TestInternal.encodeTopHitTermRecord(.{ .term_index = @as(u64, std.math.maxInt(u32)) + 1, .hit_offset = 0, .hit_count = TestConfig.persistent_term_top_hit_capacity }, &bytes));
    try std.testing.expectError(error.InvalidRecord, TestInternal.encodeTopHitTermRecord(.{ .term_index = 0, .hit_offset = 0, .hit_count = 0 }, &bytes));
    try std.testing.expectError(error.InvalidRecord, TestInternal.decodeTopHitTermRecord(&bytes, 0, 0));
}

test "search acceleration top-hit records preserve stable bytes and reject invalid fields" {
    const record = TestTopHitRecord{ .doc_id = TestConfig.persistent_posting_max_doc_id, .text_freq = TestConfig.persistent_posting_max_field_freq, .node_id = std.math.maxInt(u64) - 1, .score = 1.5 };
    var bytes: [TestTopHitRecord.encoded_len]u8 = undefined;
    try TestInternal.encodeTopHitRecord(record, &bytes);
    const decoded = try TestInternal.decodeTopHitRecord(&bytes);
    try std.testing.expectEqual(record.doc_id, decoded.doc_id);
    try std.testing.expectEqual(record.text_freq, decoded.text_freq);
    try std.testing.expectEqual(@as(u64, 0), decoded.node_id);
    try std.testing.expectEqual(@as(f32, 0), decoded.score);
    try std.testing.expectError(error.InvalidRecord, TestInternal.encodeTopHitRecord(.{ .doc_id = 0, .text_freq = 1, .score = 1 }, &bytes));
    try std.testing.expectError(error.RecordTooLarge, TestInternal.encodeTopHitRecord(.{ .doc_id = TestConfig.persistent_posting_max_doc_id + 1, .text_freq = 1, .score = 1 }, &bytes));
    try std.testing.expectError(error.InvalidRecord, TestInternal.encodeTopHitRecord(.{ .doc_id = 1, .text_freq = 0, .score = 1 }, &bytes));
    try std.testing.expectError(error.RecordTooLarge, TestInternal.encodeTopHitRecord(.{ .doc_id = 1, .text_freq = TestConfig.persistent_posting_max_field_freq + 1, .score = 1 }, &bytes));
    try std.testing.expectError(error.InvalidRecord, TestInternal.encodeTopHitRecord(.{ .doc_id = 1, .text_freq = 1, .node_id = std.math.maxInt(u64), .score = 1 }, &bytes));
    try std.testing.expectError(error.InvalidRecord, TestInternal.encodeTopHitRecord(.{ .doc_id = 1, .text_freq = 1, .score = std.math.nan(f32) }, &bytes));
}
