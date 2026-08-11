const std = @import("std");
const posting_format_mod = @import("posting_format.zig");

/// Persistent `text_terms.idx` byte and payload contracts. The posting-format
/// configuration is shared with the façade so inline posting payloads retain
/// the exact `TextPostingRecord` type and compression semantics.
pub fn TermFormat(comptime posting_config: type, comptime config: type) type {
    const posting_format = posting_format_mod.PostingFormat(posting_config);
    const TextPostingRecord = posting_format.TextPostingRecord;
    const posting_internal = posting_format.Internal;

    return struct {
        pub const TextTermsHeader = struct {
            term_count: u64,
            term_bytes: u64,
            term_exception_count: u64 = 0,
            singleton_payload_bytes: u64 = 0,

            pub const encoded_len: usize = 40;
        };

        pub const TextTermEntry = struct {
            term_len: u32,
            doc_freq: u32,
            postings_offset: u64,
            postings_count: u64,
            front_prefix_len: ?u8 = null,
            postings_offset_is_plain: bool = false,
            postings_offset_is_dense_freq_stream: bool = false,

            pub const encoded_len: usize = 1;
        };

        /// Codec and layout mechanics stay private behind `text.zig`; only the
        /// two stable logical types above are façade exports.
        pub const Internal = struct {
            const terms_magic = [_]u8{ 'T', 'K', 'G', 'R' };

            pub const term_byte_offset_checkpoint_terms: u64 = 128;
            pub const term_bytes_max_offset: u64 = std.math.maxInt(u32);
            pub const term_max_len: u32 = @intCast(config.persistent_term_max_len);
            pub const term_inline_posting_marker: u32 = 1 << 31;
            pub const term_virtual_all_docs_payload_marker: u32 = term_inline_posting_marker;
            pub const term_inline_posting_payload_mask: u32 = term_inline_posting_marker - 1;
            pub const term_dense_all_docs_freq_stream_payload_base: u64 = posting_config.persistent_posting_max_field_freq + 1;
            pub const postings_body_max_offset: u64 = term_inline_posting_payload_mask;
            pub const inline_posting_doc_id_bits: u6 = 31 - posting_internal.compressed_field_tag_bits;
            pub const inline_posting_max_doc_id: u64 = @as(u64, 1) << inline_posting_doc_id_bits;
            pub const term_max_doc_freq: u64 = (1 << 30) - 1;
            pub const term_exception_payload_len: usize = 12;
            pub const term_exception_plain_offset_flag: u32 = 1 << 31;
            pub const term_exception_dense_freq_stream_flag: u32 = 1 << 30;
            pub const term_exception_doc_freq_mask: u32 = (1 << 30) - 1;
            pub const term_exception_rank_checkpoint_terms: u64 = 256;
            pub const term_singleton_payload_checkpoint_terms: u64 = 128;
            pub const term_singleton_payload_checkpoint_len: usize = 8;
            pub const front_coded_entry_prefix_marker: u8 = 0x80;

            pub const TextTermSingletonPayloadCheckpoint = struct {
                stream_offset: u64,
                previous_payload: u32,

                pub const encoded_len: usize = term_singleton_payload_checkpoint_len;
            };

            pub const TextTermExceptionRecord = struct {
                doc_freq: u32,
                postings_offset: u64,
                postings_offset_is_plain: bool = false,
                postings_offset_is_dense_freq_stream: bool = false,

                pub const encoded_len: usize = term_exception_payload_len;
            };

            pub fn encodeHeader(header: TextTermsHeader, out: *[TextTermsHeader.encoded_len]u8) void {
                @memcpy(out[0..4], &terms_magic);
                std.mem.writeInt(u16, out[4..6], posting_config.persistent_text_index_version, .little);
                std.mem.writeInt(u16, out[6..8], TextTermsHeader.encoded_len, .little);
                std.mem.writeInt(u64, out[8..16], header.term_count, .little);
                std.mem.writeInt(u64, out[16..24], header.term_bytes, .little);
                std.mem.writeInt(u64, out[24..32], header.term_exception_count, .little);
                std.mem.writeInt(u64, out[32..40], header.singleton_payload_bytes, .little);
            }

            pub fn decodeHeader(bytes: []const u8) !TextTermsHeader {
                if (bytes.len != TextTermsHeader.encoded_len) return error.InvalidRecord;
                if (!std.mem.eql(u8, bytes[0..4], &terms_magic)) return error.InvalidRecord;
                if (std.mem.readInt(u16, bytes[4..6], .little) != posting_config.persistent_text_index_version) return error.InvalidRecord;
                if (std.mem.readInt(u16, bytes[6..8], .little) != TextTermsHeader.encoded_len) return error.InvalidRecord;
                const header = TextTermsHeader{
                    .term_count = std.mem.readInt(u64, bytes[8..16], .little),
                    .term_bytes = std.mem.readInt(u64, bytes[16..24], .little),
                    .term_exception_count = std.mem.readInt(u64, bytes[24..32], .little),
                    .singleton_payload_bytes = std.mem.readInt(u64, bytes[32..40], .little),
                };
                try validateHeaderShape(header);
                return header;
            }

            pub fn validateHeaderShape(header: TextTermsHeader) !void {
                if (header.term_exception_count > header.term_count) return error.InvalidRecord;
                const singleton_count = header.term_count - header.term_exception_count;
                if (singleton_count == 0 and header.singleton_payload_bytes != 0) return error.InvalidRecord;
                if (singleton_count != 0 and header.singleton_payload_bytes == 0) return error.InvalidRecord;
                if (header.term_bytes > term_bytes_max_offset) return error.InvalidRecord;
            }

            pub fn encodeEntry(entry: TextTermEntry, out: *[TextTermEntry.encoded_len]u8) !void {
                if (entry.term_len == 0) return error.InvalidRecord;
                if (entry.term_len > term_max_len) return error.RecordTooLarge;
                if (entryFrontPrefixLen(entry)) |prefix_len| {
                    const suffix_len = try entryFrontSuffixLen(entry, prefix_len);
                    if (frontCodedPrefixInlineable(prefix_len, suffix_len)) {
                        out[0] = front_coded_entry_prefix_marker | (prefix_len << 4) | suffix_len;
                        return;
                    }
                }
                out[0] = if (entry.term_len == term_max_len) 0 else @intCast(entry.term_len);
            }

            pub fn decodeEntry(bytes: []const u8) !TextTermEntry {
                if (bytes.len != TextTermEntry.encoded_len) return error.InvalidRecord;
                if ((bytes[0] & front_coded_entry_prefix_marker) != 0) {
                    const prefix_len: u8 = (bytes[0] >> 4) & 0x07;
                    const suffix_len: u8 = bytes[0] & 0x0f;
                    if (!frontCodedPrefixInlineable(prefix_len, suffix_len)) return error.InvalidRecord;
                    return .{
                        .term_len = @as(u32, prefix_len) + suffix_len,
                        .doc_freq = 0,
                        .postings_offset = 0,
                        .postings_count = 0,
                        .front_prefix_len = prefix_len,
                    };
                }
                const term_len: u32 = if (bytes[0] == 0) term_max_len else bytes[0];
                if (term_len > term_max_len) return error.InvalidRecord;
                return .{
                    .term_len = term_len,
                    .doc_freq = 0,
                    .postings_offset = 0,
                    .postings_count = 0,
                };
            }

            pub fn entryWithDocFreq(value: TextTermEntry, doc_freq: u32) !TextTermEntry {
                if (doc_freq == 0) return error.InvalidRecord;
                if (doc_freq > term_max_doc_freq) return error.RecordTooLarge;
                var entry = value;
                entry.doc_freq = doc_freq;
                entry.postings_count = doc_freq;
                if (!termEntryPostingPayloadValid(entry)) return error.InvalidRecord;
                return entry;
            }

            pub fn entryFrontPrefixLen(entry: TextTermEntry) ?u8 {
                return entry.front_prefix_len;
            }

            pub fn entryFrontSuffixLen(entry: TextTermEntry, prefix_len: u8) !u8 {
                if (prefix_len > entry.term_len) return error.InvalidRecord;
                const suffix_len = entry.term_len - prefix_len;
                if (suffix_len == 0 or suffix_len > term_max_len) return error.InvalidRecord;
                return @intCast(suffix_len);
            }

            pub fn encodeSingletonCheckpoint(checkpoint: TextTermSingletonPayloadCheckpoint, out: *[TextTermSingletonPayloadCheckpoint.encoded_len]u8) !void {
                if (checkpoint.stream_offset > std.math.maxInt(u32)) return error.RecordTooLarge;
                std.mem.writeInt(u32, out[0..4], @intCast(checkpoint.stream_offset), .little);
                std.mem.writeInt(u32, out[4..8], checkpoint.previous_payload, .little);
            }

            pub fn decodeSingletonCheckpoint(bytes: []const u8) !TextTermSingletonPayloadCheckpoint {
                if (bytes.len != TextTermSingletonPayloadCheckpoint.encoded_len) return error.InvalidRecord;
                return .{
                    .stream_offset = std.mem.readInt(u32, bytes[0..4], .little),
                    .previous_payload = std.mem.readInt(u32, bytes[4..8], .little),
                };
            }

            pub fn encodeExceptionRecord(record: TextTermExceptionRecord, out: *[TextTermExceptionRecord.encoded_len]u8) !void {
                if (record.doc_freq == 0) return error.InvalidRecord;
                if (record.doc_freq > term_max_doc_freq) return error.RecordTooLarge;
                const logical = exceptionRecordEntry(record);
                if (!termEntryPostingPayloadValid(logical)) return error.RecordTooLarge;
                if (termEntryHasInlinePosting(logical)) return error.InvalidRecord;
                const encoded_doc_freq = record.doc_freq |
                    (if (record.postings_offset_is_plain) term_exception_plain_offset_flag else 0) |
                    (if (record.postings_offset_is_dense_freq_stream) term_exception_dense_freq_stream_flag else 0);
                std.mem.writeInt(u32, out[0..4], encoded_doc_freq, .little);
                std.mem.writeInt(u64, out[4..12], record.postings_offset, .little);
            }

            pub fn decodeExceptionRecord(bytes: []const u8) !TextTermExceptionRecord {
                if (bytes.len != TextTermExceptionRecord.encoded_len) return error.InvalidRecord;
                const encoded_doc_freq = std.mem.readInt(u32, bytes[0..4], .little);
                if ((encoded_doc_freq & ~(term_exception_plain_offset_flag | term_exception_dense_freq_stream_flag | term_exception_doc_freq_mask)) != 0) return error.InvalidRecord;
                const doc_freq = encoded_doc_freq & term_exception_doc_freq_mask;
                if (doc_freq == 0 or doc_freq > term_max_doc_freq) return error.InvalidRecord;
                const record = TextTermExceptionRecord{
                    .doc_freq = doc_freq,
                    .postings_offset = std.mem.readInt(u64, bytes[4..12], .little),
                    .postings_offset_is_plain = (encoded_doc_freq & term_exception_plain_offset_flag) != 0,
                    .postings_offset_is_dense_freq_stream = (encoded_doc_freq & term_exception_dense_freq_stream_flag) != 0,
                };
                const logical = exceptionRecordEntry(record);
                if (!termEntryPostingPayloadValid(logical)) return error.InvalidRecord;
                if (termEntryHasInlinePosting(logical)) return error.InvalidRecord;
                return record;
            }

            fn exceptionRecordEntry(record: TextTermExceptionRecord) TextTermEntry {
                return .{
                    .term_len = 1,
                    .doc_freq = record.doc_freq,
                    .postings_offset = record.postings_offset,
                    .postings_count = record.doc_freq,
                    .postings_offset_is_plain = record.postings_offset_is_plain,
                    .postings_offset_is_dense_freq_stream = record.postings_offset_is_dense_freq_stream,
                };
            }

            pub fn termEntryHasInlinePosting(entry: TextTermEntry) bool {
                if (entry.postings_offset_is_plain or entry.postings_offset_is_dense_freq_stream) return false;
                return entry.postings_count == 1 and (entry.postings_offset & term_inline_posting_marker) != 0;
            }

            pub fn encodeVirtualAllDocsPostingPayload(text_freq: u32) !u64 {
                if (text_freq == 0 or text_freq > posting_config.persistent_posting_max_field_freq) return error.RecordTooLarge;
                return @as(u64, term_virtual_all_docs_payload_marker) | text_freq;
            }

            pub fn termEntryVirtualAllDocsTextFreq(entry: TextTermEntry) ?u32 {
                if (entry.postings_offset_is_plain or entry.postings_offset_is_dense_freq_stream) return null;
                if (entry.postings_count < config.persistent_all_docs_synthesis_min_postings) return null;
                if ((entry.postings_offset & term_inline_posting_marker) == 0) return null;
                const payload = entry.postings_offset & term_inline_posting_payload_mask;
                if (payload == 0 or payload > posting_config.persistent_posting_max_field_freq) return null;
                return @intCast(payload);
            }

            pub fn denseAllDocsFreqStreamOffsetFromPayload(payload: u64) ?u64 {
                if (payload < term_dense_all_docs_freq_stream_payload_base) return null;
                return payload - term_dense_all_docs_freq_stream_payload_base;
            }

            pub fn denseAllDocsFreqStreamOffset(postings_count: u64, postings_offset: u64) ?u64 {
                if (postings_count < config.persistent_all_docs_synthesis_min_postings) return null;
                if ((postings_offset & term_inline_posting_marker) == 0) return null;
                return denseAllDocsFreqStreamOffsetFromPayload(postings_offset & term_inline_posting_payload_mask);
            }

            pub fn termEntryDenseAllDocsFreqStreamOffset(entry: TextTermEntry) ?u64 {
                if (entry.postings_offset_is_plain) return null;
                if (entry.postings_offset_is_dense_freq_stream) return entry.postings_offset;
                return denseAllDocsFreqStreamOffset(entry.postings_count, entry.postings_offset);
            }

            pub fn termEntryPostingPayloadValid(entry: TextTermEntry) bool {
                if (entry.postings_offset_is_plain and entry.postings_offset_is_dense_freq_stream) return false;
                if (entry.postings_offset_is_plain) return true;
                if (entry.postings_offset_is_dense_freq_stream) return entry.postings_count >= config.persistent_all_docs_synthesis_min_postings;
                if ((entry.postings_offset & term_inline_posting_marker) == 0) return entry.postings_offset <= postings_body_max_offset;
                if (termEntryVirtualAllDocsTextFreq(entry) != null) return true;
                if (termEntryDenseAllDocsFreqStreamOffset(entry) != null) return true;
                if (entry.postings_count != 1) return false;
                _ = decodeInlineSingletonPostingPayload(entry.postings_offset) catch return false;
                return true;
            }

            pub fn encodeDenseAllDocsFreqStreamPayload(body_offset: u64) !u64 {
                const payload = std.math.add(u64, term_dense_all_docs_freq_stream_payload_base, body_offset) catch return error.RecordTooLarge;
                if (payload > term_inline_posting_payload_mask) return error.RecordTooLarge;
                return @as(u64, term_inline_posting_marker) | payload;
            }

            pub fn canInlineSingletonPosting(posting: TextPostingRecord) bool {
                const field_tag = posting_internal.compressedFieldTag(posting) catch return false;
                if (posting_internal.compressedTagTextExplicit(field_tag)) return false;
                return posting.doc_id >= 1 and posting.doc_id <= inline_posting_max_doc_id;
            }

            pub fn encodeInlineSingletonPostingPayload(posting: TextPostingRecord) !u64 {
                if (!canInlineSingletonPosting(posting)) return error.RecordTooLarge;
                const field_tag = try posting_internal.compressedFieldTag(posting);
                const encoded_doc_id = posting.doc_id - 1;
                const payload = (encoded_doc_id << posting_internal.compressed_field_tag_bits) | field_tag;
                if (payload > term_inline_posting_payload_mask) return error.RecordTooLarge;
                return @as(u64, term_inline_posting_marker) | payload;
            }

            pub fn decodeInlineSingletonPostingPayload(payload: u64) !TextPostingRecord {
                if ((payload & term_inline_posting_marker) == 0) return error.InvalidRecord;
                const raw = payload & term_inline_posting_payload_mask;
                const field_tag: u8 = @intCast(raw & posting_internal.compressed_field_tag_mask);
                if (posting_internal.compressedTagTextExplicit(field_tag)) return error.InvalidRecord;
                const doc_id = (raw >> posting_internal.compressed_field_tag_bits) + 1;
                if (doc_id == 0 or doc_id > inline_posting_max_doc_id) return error.InvalidRecord;
                const text_freq = posting_internal.compressedTagInlineTextFreq(field_tag) orelse 0;
                const kind_freq: u32 = 0;
                try posting_internal.validateFields(doc_id, text_freq, kind_freq);
                return .{ .doc_id = doc_id, .text_freq = text_freq, .kind_freq = kind_freq };
            }

            pub fn encodeZigZagI64(value: i64) u64 {
                if (value >= 0) return @as(u64, @intCast(value)) * 2;
                return @as(u64, @intCast(-value)) * 2 - 1;
            }

            pub fn decodeZigZagI64(value: u64) i64 {
                const magnitude: i64 = @intCast(value >> 1);
                return magnitude ^ -@as(i64, @intCast(value & 1));
            }

            pub fn singletonPayloadDelta(previous_payload: u32, payload: u32) i64 {
                return @as(i64, payload) - @as(i64, previous_payload);
            }

            pub fn applySingletonPayloadDelta(previous_payload: u32, encoded_delta: u64) !u32 {
                const delta = decodeZigZagI64(encoded_delta);
                const next = @as(i64, previous_payload) + delta;
                if (next <= 0 or next > std.math.maxInt(u32)) return error.InvalidRecord;
                return @intCast(next);
            }

            pub fn termCommonPrefixLen(lhs: []const u8, rhs: []const u8) u8 {
                const n = @min(lhs.len, rhs.len);
                var index: usize = 0;
                while (index < n and lhs[index] == rhs[index]) : (index += 1) {}
                return @intCast(index);
            }

            pub fn termFrontCodedPrefixLen(term_index: u64, previous_term: ?[]const u8, term: []const u8) !u8 {
                if (term.len == 0 or term.len > term_max_len) return error.InvalidRecord;
                if (term_index % term_byte_offset_checkpoint_terms == 0) return 0;
                const previous = previous_term orelse return error.InvalidRecord;
                return termCommonPrefixLen(previous, term);
            }

            pub fn frontCodedPrefixInlineable(prefix_len: u8, suffix_len: u8) bool {
                return prefix_len <= 7 and suffix_len >= 1 and suffix_len <= 15;
            }

            pub fn frontCodedPrefixByteCount(entry: TextTermEntry, prefix_len: u8) u64 {
                const stored_prefix = entryFrontPrefixLen(entry) orelse return 1;
                if (stored_prefix != prefix_len or prefix_len > entry.term_len) return 1;
                const suffix_len = entry.term_len - prefix_len;
                if (suffix_len > std.math.maxInt(u8)) return 1;
                return if (frontCodedPrefixInlineable(prefix_len, @intCast(suffix_len))) 0 else 1;
            }

            pub fn frontCodedEncodedLen(entry: TextTermEntry, prefix_len: u8) !u64 {
                const suffix_len = try entryFrontSuffixLen(entry, prefix_len);
                return frontCodedPrefixByteCount(entry, prefix_len) + suffix_len;
            }

            pub fn termEntryOffset(index: u64) !u64 {
                const bytes = std.math.mul(u64, index, TextTermEntry.encoded_len) catch return error.RecordTooLarge;
                return std.math.add(u64, TextTermsHeader.encoded_len, bytes) catch return error.RecordTooLarge;
            }

            pub fn termsBytesOffset(term_count: u64) !u64 {
                const bytes = std.math.mul(u64, term_count, TextTermEntry.encoded_len) catch return error.RecordTooLarge;
                return std.math.add(u64, TextTermsHeader.encoded_len, bytes) catch return error.RecordTooLarge;
            }

            pub fn termByteOffsetCheckpointCount(term_count: u64) !u64 {
                return std.math.divCeil(u64, term_count, term_byte_offset_checkpoint_terms) catch return error.RecordTooLarge;
            }

            pub fn termByteOffsetCheckpointTableBytes(term_count: u64) !u64 {
                return std.math.mul(u64, try termByteOffsetCheckpointCount(term_count), 4) catch return error.RecordTooLarge;
            }

            pub fn termByteOffsetCheckpointTableOffset(term_count: u64, term_bytes: u64) !u64 {
                if (term_bytes > term_bytes_max_offset) return error.RecordTooLarge;
                return std.math.add(u64, try termsBytesOffset(term_count), term_bytes) catch return error.RecordTooLarge;
            }

            pub fn termByteOffsetCheckpointOffset(term_count: u64, term_bytes: u64, checkpoint_index: u64) !u64 {
                const checkpoint_count = try termByteOffsetCheckpointCount(term_count);
                if (checkpoint_index >= checkpoint_count) return error.InvalidRecord;
                const bytes = std.math.mul(u64, checkpoint_index, 4) catch return error.RecordTooLarge;
                return std.math.add(u64, try termByteOffsetCheckpointTableOffset(term_count, term_bytes), bytes) catch return error.RecordTooLarge;
            }

            pub fn termExceptionRankCheckpointCount(term_count: u64) !u64 {
                return std.math.divCeil(u64, term_count, term_exception_rank_checkpoint_terms) catch return error.RecordTooLarge;
            }

            pub fn termExceptionRankCheckpointTableBytes(term_count: u64) !u64 {
                return std.math.mul(u64, try termExceptionRankCheckpointCount(term_count), 4) catch return error.RecordTooLarge;
            }

            pub fn termExceptionMembershipBytes(term_count: u64) !u64 {
                return std.math.divCeil(u64, term_count, 8) catch return error.RecordTooLarge;
            }

            pub fn termExceptionPayloadTableBytes(exception_count: u64) !u64 {
                return std.math.mul(u64, exception_count, TextTermExceptionRecord.encoded_len) catch return error.RecordTooLarge;
            }

            pub fn termExceptionTableBytes(term_count: u64, exception_count: u64) !u64 {
                var total = try termExceptionRankCheckpointTableBytes(term_count);
                total = std.math.add(u64, total, try termExceptionMembershipBytes(term_count)) catch return error.RecordTooLarge;
                return std.math.add(u64, total, try termExceptionPayloadTableBytes(exception_count)) catch return error.RecordTooLarge;
            }

            pub fn termExceptionTableOffset(term_count: u64, term_bytes: u64) !u64 {
                return std.math.add(u64, try termByteOffsetCheckpointTableOffset(term_count, term_bytes), try termByteOffsetCheckpointTableBytes(term_count)) catch return error.RecordTooLarge;
            }

            pub fn termExceptionRankCheckpointTableOffset(term_count: u64, term_bytes: u64) !u64 {
                return termExceptionTableOffset(term_count, term_bytes);
            }

            pub fn termExceptionRankCheckpointOffset(term_count: u64, term_bytes: u64, checkpoint_index: u64) !u64 {
                const checkpoint_count = try termExceptionRankCheckpointCount(term_count);
                if (checkpoint_index >= checkpoint_count) return error.InvalidRecord;
                const bytes = std.math.mul(u64, checkpoint_index, 4) catch return error.RecordTooLarge;
                return std.math.add(u64, try termExceptionRankCheckpointTableOffset(term_count, term_bytes), bytes) catch return error.RecordTooLarge;
            }

            pub fn termExceptionMembershipBitsetOffset(term_count: u64, term_bytes: u64) !u64 {
                return std.math.add(u64, try termExceptionRankCheckpointTableOffset(term_count, term_bytes), try termExceptionRankCheckpointTableBytes(term_count)) catch return error.RecordTooLarge;
            }

            pub fn termExceptionMembershipByteOffset(term_count: u64, term_bytes: u64, byte_index: u64) !u64 {
                const byte_count = try termExceptionMembershipBytes(term_count);
                if (byte_index >= byte_count) return error.InvalidRecord;
                return std.math.add(u64, try termExceptionMembershipBitsetOffset(term_count, term_bytes), byte_index) catch return error.RecordTooLarge;
            }

            pub fn termExceptionPayloadTableOffset(term_count: u64, term_bytes: u64) !u64 {
                return std.math.add(u64, try termExceptionMembershipBitsetOffset(term_count, term_bytes), try termExceptionMembershipBytes(term_count)) catch return error.RecordTooLarge;
            }

            pub fn termExceptionRecordOffset(term_count: u64, term_bytes: u64, exception_index: u64) !u64 {
                const bytes = std.math.mul(u64, exception_index, TextTermExceptionRecord.encoded_len) catch return error.RecordTooLarge;
                return std.math.add(u64, try termExceptionPayloadTableOffset(term_count, term_bytes), bytes) catch return error.RecordTooLarge;
            }

            pub fn termSingletonPayloadCount(term_count: u64, term_exception_count: u64) !u64 {
                if (term_exception_count > term_count) return error.InvalidRecord;
                return term_count - term_exception_count;
            }

            pub fn termSingletonPayloadCheckpointCount(singleton_count: u64) !u64 {
                return std.math.divCeil(u64, singleton_count, term_singleton_payload_checkpoint_terms) catch return error.RecordTooLarge;
            }

            pub fn termSingletonPayloadCheckpointTableBytes(singleton_count: u64) !u64 {
                return std.math.mul(u64, try termSingletonPayloadCheckpointCount(singleton_count), TextTermSingletonPayloadCheckpoint.encoded_len) catch return error.RecordTooLarge;
            }

            pub fn termSingletonPayloadCheckpointTableOffset(term_count: u64, term_bytes: u64, term_exception_count: u64) !u64 {
                return std.math.add(u64, try termExceptionTableOffset(term_count, term_bytes), try termExceptionTableBytes(term_count, term_exception_count)) catch return error.RecordTooLarge;
            }

            pub fn termSingletonPayloadCheckpointOffset(term_count: u64, term_bytes: u64, term_exception_count: u64, checkpoint_index: u64) !u64 {
                const singleton_count = try termSingletonPayloadCount(term_count, term_exception_count);
                const checkpoint_count = try termSingletonPayloadCheckpointCount(singleton_count);
                if (checkpoint_index >= checkpoint_count) return error.InvalidRecord;
                const bytes = std.math.mul(u64, checkpoint_index, TextTermSingletonPayloadCheckpoint.encoded_len) catch return error.RecordTooLarge;
                return std.math.add(u64, try termSingletonPayloadCheckpointTableOffset(term_count, term_bytes, term_exception_count), bytes) catch return error.RecordTooLarge;
            }

            pub fn termSingletonPayloadStreamOffset(term_count: u64, term_bytes: u64, term_exception_count: u64) !u64 {
                const singleton_count = try termSingletonPayloadCount(term_count, term_exception_count);
                return std.math.add(u64, try termSingletonPayloadCheckpointTableOffset(term_count, term_bytes, term_exception_count), try termSingletonPayloadCheckpointTableBytes(singleton_count)) catch return error.RecordTooLarge;
            }

            pub fn termsFileSize(term_count: u64, term_bytes: u64, term_exception_count: u64, singleton_payload_bytes: u64) !u64 {
                return std.math.add(u64, try termSingletonPayloadStreamOffset(term_count, term_bytes, term_exception_count), singleton_payload_bytes) catch return error.RecordTooLarge;
            }

            pub fn termsFileSizeForHeader(header: TextTermsHeader) !u64 {
                try validateHeaderShape(header);
                return termsFileSize(header.term_count, header.term_bytes, header.term_exception_count, header.singleton_payload_bytes);
            }
        };
    };
}

const TestPostingConfig = struct {
    pub const persistent_text_index_version: u16 = 76;
    pub const persistent_posting_max_doc_id: u64 = std.math.maxInt(u32) - 1;
    pub const persistent_posting_max_field_freq: u32 = std.math.maxInt(u16);
    pub const persistent_posting_max_kind_freq: u32 = 0;
};
const TestConfig = struct {
    pub const persistent_term_max_len: usize = 128;
    pub const persistent_all_docs_synthesis_min_postings: u64 = 4;
};
const test_format = TermFormat(TestPostingConfig, TestConfig);
const TestTextTermsHeader = test_format.TextTermsHeader;
const TestTextTermEntry = test_format.TextTermEntry;
const TestInternal = test_format.Internal;

test "text terms header preserves stable bytes and shape" {
    const header = TestTextTermsHeader{ .term_count = 5, .term_bytes = 17, .term_exception_count = 2, .singleton_payload_bytes = 9 };
    var bytes: [TestTextTermsHeader.encoded_len]u8 = undefined;
    TestInternal.encodeHeader(header, &bytes);
    try std.testing.expectEqualSlices(u8, "TKGR", bytes[0..4]);
    try std.testing.expectEqual(TestPostingConfig.persistent_text_index_version, std.mem.readInt(u16, bytes[4..6], .little));
    try std.testing.expectEqual(@as(u16, TestTextTermsHeader.encoded_len), std.mem.readInt(u16, bytes[6..8], .little));
    try std.testing.expectEqual(header, try TestInternal.decodeHeader(&bytes));
}

test "text terms header rejects identity and inconsistent sidecars" {
    var bytes: [TestTextTermsHeader.encoded_len]u8 = undefined;
    TestInternal.encodeHeader(.{ .term_count = 2, .term_bytes = 7, .term_exception_count = 1, .singleton_payload_bytes = 1 }, &bytes);
    var corrupt = bytes;
    corrupt[0] ^= 1;
    try std.testing.expectError(error.InvalidRecord, TestInternal.decodeHeader(&corrupt));
    corrupt = bytes;
    std.mem.writeInt(u16, corrupt[4..6], TestPostingConfig.persistent_text_index_version - 1, .little);
    try std.testing.expectError(error.InvalidRecord, TestInternal.decodeHeader(&corrupt));
    corrupt = bytes;
    std.mem.writeInt(u16, corrupt[6..8], TestTextTermsHeader.encoded_len - 1, .little);
    try std.testing.expectError(error.InvalidRecord, TestInternal.decodeHeader(&corrupt));
    try std.testing.expectError(error.InvalidRecord, TestInternal.validateHeaderShape(.{ .term_count = 1, .term_bytes = 0, .term_exception_count = 2 }));
    try std.testing.expectError(error.InvalidRecord, TestInternal.validateHeaderShape(.{ .term_count = 1, .term_bytes = 0 }));
    try std.testing.expectError(error.InvalidRecord, TestInternal.validateHeaderShape(.{ .term_count = 0, .term_bytes = 0, .singleton_payload_bytes = 1 }));
}

test "packed text term entries preserve plain and front-coded bytes" {
    var bytes: [TestTextTermEntry.encoded_len]u8 = undefined;
    const plain = TestTextTermEntry{ .term_len = 17, .doc_freq = 0, .postings_offset = 0, .postings_count = 0 };
    try TestInternal.encodeEntry(plain, &bytes);
    try std.testing.expectEqual(@as(u8, 17), bytes[0]);
    try std.testing.expectEqual(plain, try TestInternal.decodeEntry(&bytes));

    const max_len = TestTextTermEntry{ .term_len = TestConfig.persistent_term_max_len, .doc_freq = 0, .postings_offset = 0, .postings_count = 0 };
    try TestInternal.encodeEntry(max_len, &bytes);
    try std.testing.expectEqual(@as(u8, 0), bytes[0]);
    try std.testing.expectEqual(max_len, try TestInternal.decodeEntry(&bytes));

    const front = TestTextTermEntry{ .term_len = 10, .doc_freq = 0, .postings_offset = 0, .postings_count = 0, .front_prefix_len = 3 };
    try TestInternal.encodeEntry(front, &bytes);
    try std.testing.expectEqual(@as(u8, 0xb7), bytes[0]);
    try std.testing.expectEqual(front, try TestInternal.decodeEntry(&bytes));
}

test "packed text term entries reject invalid lengths and prefixes" {
    var bytes: [TestTextTermEntry.encoded_len]u8 = undefined;
    try std.testing.expectError(error.InvalidRecord, TestInternal.encodeEntry(.{ .term_len = 0, .doc_freq = 0, .postings_offset = 0, .postings_count = 0 }, &bytes));
    try std.testing.expectError(error.RecordTooLarge, TestInternal.encodeEntry(.{ .term_len = TestConfig.persistent_term_max_len + 1, .doc_freq = 0, .postings_offset = 0, .postings_count = 0 }, &bytes));
    try std.testing.expectError(error.InvalidRecord, TestInternal.encodeEntry(.{ .term_len = 3, .doc_freq = 0, .postings_offset = 0, .postings_count = 0, .front_prefix_len = 4 }, &bytes));
    try std.testing.expectError(error.InvalidRecord, TestInternal.decodeEntry(&.{0x80}));
}

test "text term exception records preserve flags and reject inline payloads" {
    const Exception = TestInternal.TextTermExceptionRecord;
    var bytes: [Exception.encoded_len]u8 = undefined;
    const regular = Exception{ .doc_freq = 2, .postings_offset = 19 };
    try TestInternal.encodeExceptionRecord(regular, &bytes);
    try std.testing.expectEqual(regular, try TestInternal.decodeExceptionRecord(&bytes));

    const plain = Exception{ .doc_freq = 2, .postings_offset = std.math.maxInt(u64), .postings_offset_is_plain = true };
    try TestInternal.encodeExceptionRecord(plain, &bytes);
    try std.testing.expectEqual(plain, try TestInternal.decodeExceptionRecord(&bytes));

    const dense = Exception{ .doc_freq = 4, .postings_offset = 23, .postings_offset_is_dense_freq_stream = true };
    try TestInternal.encodeExceptionRecord(dense, &bytes);
    try std.testing.expectEqual(dense, try TestInternal.decodeExceptionRecord(&bytes));

    const inline_payload = try TestInternal.encodeInlineSingletonPostingPayload(.{ .doc_id = 3, .text_freq = 1 });
    try std.testing.expectError(error.InvalidRecord, TestInternal.encodeExceptionRecord(.{ .doc_freq = 1, .postings_offset = inline_payload }, &bytes));
    try std.testing.expectError(error.RecordTooLarge, TestInternal.encodeExceptionRecord(.{ .doc_freq = 2, .postings_offset = std.math.maxInt(u64) }, &bytes));
    try std.testing.expectError(error.RecordTooLarge, TestInternal.encodeExceptionRecord(.{ .doc_freq = 4, .postings_offset = 1, .postings_offset_is_plain = true, .postings_offset_is_dense_freq_stream = true }, &bytes));
}

test "singleton payload checkpoints and deltas preserve stable bytes" {
    const Checkpoint = TestInternal.TextTermSingletonPayloadCheckpoint;
    const checkpoint = Checkpoint{ .stream_offset = 0x0102_0304, .previous_payload = 0x0506_0708 };
    var bytes: [Checkpoint.encoded_len]u8 = undefined;
    try TestInternal.encodeSingletonCheckpoint(checkpoint, &bytes);
    try std.testing.expectEqualSlices(u8, &.{ 0x04, 0x03, 0x02, 0x01, 0x08, 0x07, 0x06, 0x05 }, &bytes);
    try std.testing.expectEqual(checkpoint, try TestInternal.decodeSingletonCheckpoint(&bytes));
    try std.testing.expectError(error.RecordTooLarge, TestInternal.encodeSingletonCheckpoint(.{ .stream_offset = @as(u64, std.math.maxInt(u32)) + 1, .previous_payload = 0 }, &bytes));
    try std.testing.expectError(error.InvalidRecord, TestInternal.decodeSingletonCheckpoint(bytes[0 .. bytes.len - 1]));

    const delta = TestInternal.singletonPayloadDelta(100, 73);
    const encoded = TestInternal.encodeZigZagI64(delta);
    try std.testing.expectEqual(@as(u32, 73), try TestInternal.applySingletonPayloadDelta(100, encoded));
    try std.testing.expectError(error.InvalidRecord, TestInternal.applySingletonPayloadDelta(0, 0));
}

test "text term payload categories preserve inline virtual and dense semantics" {
    const posting = posting_format_mod.PostingFormat(TestPostingConfig).TextPostingRecord{ .doc_id = 9, .text_freq = 3 };
    const inline_payload = try TestInternal.encodeInlineSingletonPostingPayload(posting);
    try std.testing.expectEqual(posting, try TestInternal.decodeInlineSingletonPostingPayload(inline_payload));
    try std.testing.expect(TestInternal.termEntryHasInlinePosting(.{ .term_len = 1, .doc_freq = 1, .postings_offset = inline_payload, .postings_count = 1 }));
    try std.testing.expectError(error.RecordTooLarge, TestInternal.encodeInlineSingletonPostingPayload(.{ .doc_id = 9, .text_freq = 4 }));

    const virtual_payload = try TestInternal.encodeVirtualAllDocsPostingPayload(2);
    const virtual_entry = TestTextTermEntry{ .term_len = 1, .doc_freq = 4, .postings_offset = virtual_payload, .postings_count = 4 };
    try std.testing.expectEqual(@as(?u32, 2), TestInternal.termEntryVirtualAllDocsTextFreq(virtual_entry));
    try std.testing.expect(TestInternal.termEntryPostingPayloadValid(virtual_entry));

    const dense_payload = try TestInternal.encodeDenseAllDocsFreqStreamPayload(7);
    const dense_entry = TestTextTermEntry{ .term_len = 1, .doc_freq = 4, .postings_offset = dense_payload, .postings_count = 4 };
    try std.testing.expectEqual(@as(?u64, 7), TestInternal.termEntryDenseAllDocsFreqStreamOffset(dense_entry));
    try std.testing.expect(TestInternal.termEntryPostingPayloadValid(dense_entry));
    try std.testing.expect(!TestInternal.termEntryPostingPayloadValid(.{ .term_len = 1, .doc_freq = 4, .postings_offset = 1, .postings_count = 4, .postings_offset_is_plain = true, .postings_offset_is_dense_freq_stream = true }));
}

test "text term layout arithmetic bounds every sidecar region" {
    try std.testing.expectEqual(@as(u64, 3), try TestInternal.termByteOffsetCheckpointCount(257));
    try std.testing.expectEqual(@as(u64, 2), try TestInternal.termExceptionRankCheckpointCount(257));
    try std.testing.expectEqual(@as(u64, 250), try TestInternal.termSingletonPayloadCount(257, 7));
    try std.testing.expectEqual(@as(u64, 2), try TestInternal.termSingletonPayloadCheckpointCount(250));
    const exception_offset = try TestInternal.termExceptionTableOffset(257, 4096);
    const singleton_offset = try TestInternal.termSingletonPayloadCheckpointTableOffset(257, 4096, 7);
    const stream_offset = try TestInternal.termSingletonPayloadStreamOffset(257, 4096, 7);
    const file_size = try TestInternal.termsFileSize(257, 4096, 7, 91);
    try std.testing.expect(exception_offset < singleton_offset);
    try std.testing.expect(singleton_offset < stream_offset);
    try std.testing.expectEqual(stream_offset + 91, file_size);
    try std.testing.expectError(error.InvalidRecord, TestInternal.termSingletonPayloadCount(1, 2));
    try std.testing.expectError(error.InvalidRecord, TestInternal.termByteOffsetCheckpointOffset(1, 0, 1));
    try std.testing.expectError(error.RecordTooLarge, TestInternal.termByteOffsetCheckpointTableOffset(1, @as(u64, std.math.maxInt(u32)) + 1));
}

test "front-coded term rules reset at checkpoints and preserve suffix length" {
    try std.testing.expectEqual(@as(u8, 5), TestInternal.termCommonPrefixLen("alpha", "alphabet"));
    try std.testing.expectEqual(@as(u8, 0), try TestInternal.termFrontCodedPrefixLen(128, null, "alpha"));
    try std.testing.expectEqual(@as(u8, 5), try TestInternal.termFrontCodedPrefixLen(129, "alpha", "alphabet"));
    try std.testing.expectError(error.InvalidRecord, TestInternal.termFrontCodedPrefixLen(129, null, "alphabet"));
    const entry = TestTextTermEntry{ .term_len = 8, .doc_freq = 0, .postings_offset = 0, .postings_count = 0, .front_prefix_len = 5 };
    try std.testing.expectEqual(@as(u64, 3), try TestInternal.frontCodedEncodedLen(entry, 5));
}
