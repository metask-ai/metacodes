const std = @import("std");

/// Persistent `text_postings.dat` byte contracts. Configuration is injected so
/// this module remains directly testable without importing the text façade.
pub fn PostingFormat(comptime config: type) type {
    return struct {
        pub const TextPostingsHeader = struct {
            posting_count: u64,
            body_bytes: u64,

            pub const encoded_len: usize = 32;
        };

        pub const TextPostingRecord = struct {
            doc_id: u64,
            text_freq: u32 = 0,
            kind_freq: u32 = 0,

            pub const encoded_len: usize = 6;
        };

        /// Encoding is intentionally not re-exported by `text.zig`; keeping it
        /// here avoids turning format mechanics into downstream API methods.
        pub const Internal = struct {
            const postings_magic = [_]u8{ 'T', 'K', 'G', 'P' };

            pub const compressed_tag_text_unit: u8 = 0;
            pub const compressed_tag_text_two: u8 = 1;
            pub const compressed_tag_text_three: u8 = 2;
            pub const compressed_tag_text_explicit: u8 = 3;
            pub const compressed_field_tag_bits: u6 = 2;
            pub const compressed_field_tag_mask: u64 = (1 << compressed_field_tag_bits) - 1;

            pub const DecodedCompressedPostingDelta = struct {
                doc_delta: u64,
                field_tag: u8,
            };

            pub fn encodeHeader(header: TextPostingsHeader, out: *[TextPostingsHeader.encoded_len]u8) void {
                @memcpy(out[0..4], &postings_magic);
                std.mem.writeInt(u16, out[4..6], config.persistent_text_index_version, .little);
                std.mem.writeInt(u16, out[6..8], TextPostingsHeader.encoded_len, .little);
                std.mem.writeInt(u64, out[8..16], header.posting_count, .little);
                std.mem.writeInt(u64, out[16..24], header.body_bytes, .little);
                @memset(out[24..32], 0);
            }

            pub fn decodeHeader(bytes: []const u8) !TextPostingsHeader {
                if (bytes.len != TextPostingsHeader.encoded_len) return error.InvalidRecord;
                if (!std.mem.eql(u8, bytes[0..4], &postings_magic)) return error.InvalidRecord;
                if (std.mem.readInt(u16, bytes[4..6], .little) != config.persistent_text_index_version) return error.InvalidRecord;
                if (std.mem.readInt(u16, bytes[6..8], .little) != TextPostingsHeader.encoded_len) return error.InvalidRecord;
                if (!allZero(bytes[24..32])) return error.InvalidRecord;
                return .{
                    .posting_count = std.mem.readInt(u64, bytes[8..16], .little),
                    .body_bytes = std.mem.readInt(u64, bytes[16..24], .little),
                };
            }

            pub fn encodeRecord(record: TextPostingRecord, out: *[TextPostingRecord.encoded_len]u8) !void {
                try validateFields(record.doc_id, record.text_freq, record.kind_freq);
                std.mem.writeInt(u32, out[0..4], @intCast(record.doc_id), .little);
                std.mem.writeInt(u16, out[4..6], @intCast(record.text_freq), .little);
            }

            pub fn decodeRecord(bytes: []const u8) !TextPostingRecord {
                if (bytes.len != TextPostingRecord.encoded_len) return error.InvalidRecord;
                const doc_id: u64 = std.mem.readInt(u32, bytes[0..4], .little);
                const text_freq: u32 = std.mem.readInt(u16, bytes[4..6], .little);
                const kind_freq: u32 = 0;
                try validateFields(doc_id, text_freq, kind_freq);
                return .{ .doc_id = doc_id, .text_freq = text_freq, .kind_freq = kind_freq };
            }

            pub fn validateFields(doc_id: u64, text_freq: u32, kind_freq: u32) !void {
                if (doc_id == 0) return error.InvalidRecord;
                if (doc_id > config.persistent_posting_max_doc_id) return error.RecordTooLarge;
                if (text_freq == 0 and kind_freq == 0) return error.InvalidRecord;
                if (text_freq > config.persistent_posting_max_field_freq or kind_freq > config.persistent_posting_max_kind_freq) return error.RecordTooLarge;
            }

            pub fn compressedTextFreqTag(text_freq: u32) !u8 {
                if (text_freq == 0) return error.InvalidRecord;
                if (text_freq > config.persistent_posting_max_field_freq) return error.RecordTooLarge;
                return switch (text_freq) {
                    1 => compressed_tag_text_unit,
                    2 => compressed_tag_text_two,
                    3 => compressed_tag_text_three,
                    else => compressed_tag_text_explicit,
                };
            }

            pub fn compressedFieldTag(posting: TextPostingRecord) !u8 {
                const has_text = posting.text_freq != 0;
                const has_kind = posting.kind_freq != 0;
                if (!has_text and !has_kind) return error.InvalidRecord;
                if (posting.kind_freq > config.persistent_posting_max_kind_freq) return error.RecordTooLarge;
                if (has_kind) return error.RecordTooLarge;
                return compressedTextFreqTag(posting.text_freq);
            }

            pub fn taggedCompressedDelta(doc_delta: u64, posting: TextPostingRecord) !u64 {
                if (doc_delta == 0) return error.InvalidRecord;
                if (doc_delta > (std.math.maxInt(u64) >> compressed_field_tag_bits)) return error.RecordTooLarge;
                return (doc_delta << compressed_field_tag_bits) | try compressedFieldTag(posting);
            }

            pub fn decodeTaggedCompressedDelta(tagged_delta: u64) !DecodedCompressedPostingDelta {
                const field_tag: u8 = @intCast(tagged_delta & compressed_field_tag_mask);
                const doc_delta = tagged_delta >> compressed_field_tag_bits;
                if (doc_delta == 0) return error.InvalidRecord;
                return .{ .doc_delta = doc_delta, .field_tag = field_tag };
            }

            pub fn compressedTagInlineTextFreq(field_tag: u8) ?u32 {
                return switch (field_tag) {
                    compressed_tag_text_unit => 1,
                    compressed_tag_text_two => 2,
                    compressed_tag_text_three => 3,
                    else => null,
                };
            }

            pub fn compressedTagTextExplicit(field_tag: u8) bool {
                return field_tag == compressed_tag_text_explicit;
            }

            pub fn validateCompressedExplicitFreq(field_tag: u8, freq: u64) !u32 {
                const min_explicit: u64 = switch (field_tag) {
                    compressed_tag_text_explicit => 4,
                    else => return error.InvalidRecord,
                };
                if (freq < min_explicit) return error.InvalidRecord;
                if (freq > config.persistent_posting_max_field_freq) return error.RecordTooLarge;
                return @intCast(freq);
            }

            fn allZero(bytes: []const u8) bool {
                for (bytes) |byte| {
                    if (byte != 0) return false;
                }
                return true;
            }
        };
    };
}

const TestConfig = struct {
    pub const persistent_text_index_version: u16 = 76;
    pub const persistent_posting_max_doc_id: u64 = std.math.maxInt(u32) - 1;
    pub const persistent_posting_max_field_freq: u32 = std.math.maxInt(u16);
    pub const persistent_posting_max_kind_freq: u32 = 0;
};
const test_format = PostingFormat(TestConfig);
const TestTextPostingsHeader = test_format.TextPostingsHeader;
const TestTextPostingRecord = test_format.TextPostingRecord;
const TestInternal = test_format.Internal;

test "text postings header preserves stable bytes" {
    const header = TestTextPostingsHeader{ .posting_count = 0x0102_0304_0506_0708, .body_bytes = 0x1112_1314_1516_1718 };
    var bytes: [TestTextPostingsHeader.encoded_len]u8 = undefined;
    TestInternal.encodeHeader(header, &bytes);

    try std.testing.expectEqualSlices(u8, "TKGP", bytes[0..4]);
    try std.testing.expectEqual(TestConfig.persistent_text_index_version, std.mem.readInt(u16, bytes[4..6], .little));
    try std.testing.expectEqual(@as(u16, TestTextPostingsHeader.encoded_len), std.mem.readInt(u16, bytes[6..8], .little));
    try std.testing.expectEqual(header, try TestInternal.decodeHeader(&bytes));
}

test "text postings header rejects identity and reserved-byte corruption" {
    const header = TestTextPostingsHeader{ .posting_count = 2, .body_bytes = 12 };
    var bytes: [TestTextPostingsHeader.encoded_len]u8 = undefined;
    TestInternal.encodeHeader(header, &bytes);

    var corrupt = bytes;
    corrupt[0] ^= 1;
    try std.testing.expectError(error.InvalidRecord, TestInternal.decodeHeader(&corrupt));
    corrupt = bytes;
    std.mem.writeInt(u16, corrupt[4..6], TestConfig.persistent_text_index_version - 1, .little);
    try std.testing.expectError(error.InvalidRecord, TestInternal.decodeHeader(&corrupt));
    corrupt = bytes;
    std.mem.writeInt(u16, corrupt[6..8], TestTextPostingsHeader.encoded_len - 1, .little);
    try std.testing.expectError(error.InvalidRecord, TestInternal.decodeHeader(&corrupt));
    corrupt = bytes;
    corrupt[31] = 1;
    try std.testing.expectError(error.InvalidRecord, TestInternal.decodeHeader(&corrupt));
    try std.testing.expectError(error.InvalidRecord, TestInternal.decodeHeader(bytes[0 .. bytes.len - 1]));
}

test "text posting record preserves stable bytes" {
    const record = TestTextPostingRecord{ .doc_id = 0x0102_0304, .text_freq = 0x0506 };
    var bytes: [TestTextPostingRecord.encoded_len]u8 = undefined;
    try TestInternal.encodeRecord(record, &bytes);

    try std.testing.expectEqualSlices(u8, &.{ 0x04, 0x03, 0x02, 0x01, 0x06, 0x05 }, &bytes);
    try std.testing.expectEqual(record, try TestInternal.decodeRecord(&bytes));
}

test "text posting record rejects reserved ids and invalid frequencies" {
    var bytes: [TestTextPostingRecord.encoded_len]u8 = undefined;
    try std.testing.expectError(error.InvalidRecord, TestInternal.encodeRecord(.{ .doc_id = 0, .text_freq = 1 }, &bytes));
    try std.testing.expectError(error.RecordTooLarge, TestInternal.encodeRecord(.{ .doc_id = TestConfig.persistent_posting_max_doc_id + 1, .text_freq = 1 }, &bytes));
    try std.testing.expectError(error.InvalidRecord, TestInternal.encodeRecord(.{ .doc_id = 1 }, &bytes));
    try std.testing.expectError(error.RecordTooLarge, TestInternal.encodeRecord(.{ .doc_id = 1, .text_freq = TestConfig.persistent_posting_max_field_freq + 1 }, &bytes));
    try std.testing.expectError(error.RecordTooLarge, TestInternal.encodeRecord(.{ .doc_id = 1, .kind_freq = 1 }, &bytes));

    @memset(&bytes, 0);
    try std.testing.expectError(error.InvalidRecord, TestInternal.decodeRecord(&bytes));
    try std.testing.expectError(error.InvalidRecord, TestInternal.decodeRecord(bytes[0 .. bytes.len - 1]));
}

test "compressed posting field tags preserve frequency and delta semantics" {
    try std.testing.expectEqual(TestInternal.compressed_tag_text_unit, try TestInternal.compressedFieldTag(.{ .doc_id = 1, .text_freq = 1 }));
    try std.testing.expectEqual(TestInternal.compressed_tag_text_two, try TestInternal.compressedFieldTag(.{ .doc_id = 1, .text_freq = 2 }));
    try std.testing.expectEqual(TestInternal.compressed_tag_text_three, try TestInternal.compressedFieldTag(.{ .doc_id = 1, .text_freq = 3 }));
    try std.testing.expectEqual(TestInternal.compressed_tag_text_explicit, try TestInternal.compressedFieldTag(.{ .doc_id = 1, .text_freq = 4 }));

    const tagged = try TestInternal.taggedCompressedDelta(9, .{ .doc_id = 12, .text_freq = 2 });
    const decoded = try TestInternal.decodeTaggedCompressedDelta(tagged);
    try std.testing.expectEqual(@as(u64, 9), decoded.doc_delta);
    try std.testing.expectEqual(TestInternal.compressed_tag_text_two, decoded.field_tag);
    try std.testing.expectEqual(@as(?u32, 2), TestInternal.compressedTagInlineTextFreq(decoded.field_tag));
    try std.testing.expect(!TestInternal.compressedTagTextExplicit(decoded.field_tag));
    try std.testing.expect(TestInternal.compressedTagTextExplicit(TestInternal.compressed_tag_text_explicit));
}

test "compressed posting field tags reject invalid shapes" {
    try std.testing.expectError(error.InvalidRecord, TestInternal.compressedFieldTag(.{ .doc_id = 1 }));
    try std.testing.expectError(error.RecordTooLarge, TestInternal.compressedFieldTag(.{ .doc_id = 1, .kind_freq = 1 }));
    try std.testing.expectError(error.InvalidRecord, TestInternal.taggedCompressedDelta(0, .{ .doc_id = 1, .text_freq = 1 }));
    try std.testing.expectError(error.InvalidRecord, TestInternal.decodeTaggedCompressedDelta(TestInternal.compressed_tag_text_unit));
    try std.testing.expectEqual(@as(u32, 4), try TestInternal.validateCompressedExplicitFreq(TestInternal.compressed_tag_text_explicit, 4));
    try std.testing.expectError(error.InvalidRecord, TestInternal.validateCompressedExplicitFreq(TestInternal.compressed_tag_text_explicit, 3));
    try std.testing.expectError(error.InvalidRecord, TestInternal.validateCompressedExplicitFreq(TestInternal.compressed_tag_text_unit, 4));
}
