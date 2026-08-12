const std = @import("std");

/// Owns the mutually consistent terms, postings, block, impact, and top-hit
/// file set for one rebuilt persistent text catalog. Atomic catalog anchoring
/// remains outside this owner.
pub fn TermPostingCatalogPublication(comptime core: type, comptime storage_mod: type, comptime Ops: type) type {
    return struct {
        const PersistentTermBuilder = Ops.PersistentTermBuilder_dep;
        const TextDocsFileView = Ops.TextDocsFileView_dep;
        const PersistentTextMeta = Ops.PersistentTextMeta_dep;
        const PersistentTextCatalogStats = Ops.PersistentTextCatalogStats_dep;
        const PersistentTerm = Ops.PersistentTerm_dep;
        const TextPostingRecord = Ops.TextPostingRecord_dep;
        const TextBufferedWriter = Ops.TextBufferedWriter_dep;
        const TextPostingsHeader = Ops.TextPostingsHeader_dep;
        const TextPostingBlocksHeader = Ops.TextPostingBlocksHeader_dep;
        const TextPostingBlockRecord = Ops.TextPostingBlockRecord_dep;
        const TextPostingBlockImpactsHeader = Ops.TextPostingBlockImpactsHeader_dep;
        const TextTermTopHitsHeader = Ops.TextTermTopHitsHeader_dep;
        const TextTermTopHitTermRecord = Ops.TextTermTopHitTermRecord_dep;
        const TextTermTopHitRecord = Ops.TextTermTopHitRecord_dep;
        const TextTopHitDocStats = Ops.TextTopHitDocStats_dep;
        const TextPostingBlockStats = Ops.TextPostingBlockStats_dep;
        const TextTermsHeader = Ops.TextTermsHeader_dep;
        const TextTermEntry = Ops.TextTermEntry_dep;
        const TextTermExceptionRecord = Ops.TextTermExceptionRecord_dep;
        const TextTermSingletonPayloadCheckpoint = Ops.TextTermSingletonPayloadCheckpoint_dep;
        const persistentTermLessThan = Ops.persistentTermLessThan_dep;
        const termPostingPayloadOrBodyOffset = Ops.termPostingPayloadOrBodyOffset_dep;
        const persistentTermFrontCodedLen = Ops.persistentTermFrontCodedLen_dep;
        const publishedPostingBodyBytesForTerm = Ops.publishedPostingBodyBytesForTerm_dep;
        const textPostingsPath = Ops.textPostingsPath_dep;
        const textPostingBlocksPath = Ops.textPostingBlocksPath_dep;
        const textPostingBlockImpactsPath = Ops.textPostingBlockImpactsPath_dep;
        const textTermTopHitsPath = Ops.textTermTopHitsPath_dep;
        const textTermsPath = Ops.textTermsPath_dep;
        const persistent_posting_block_size = Ops.persistent_posting_block_size_dep;
        const persistent_posting_block_capacity = Ops.persistent_posting_block_capacity_dep;
        const persistent_term_top_hit_capacity = Ops.persistent_term_top_hit_capacity_dep;
        const persistent_term_top_hit_min_postings = Ops.persistent_term_top_hit_min_postings_dep;
        const text_write_buffer_bytes = Ops.text_write_buffer_bytes_dep;
        const tmpPathFor = Ops.tmpPathFor_dep;
        const textOptionsNeedSync = Ops.textOptionsNeedSync_dep;
        const renameReplace = Ops.renameReplace_dep;
        const compressedTextPostingBytesForTerm = Ops.compressedTextPostingBytesForTerm_dep;
        const encodeTextPostingsHeader = Ops.encodeTextPostingsHeader_dep;
        const canVirtualizeAllDocsConstantTextFreqTerm = Ops.canVirtualizeAllDocsConstantTextFreqTerm_dep;
        const virtualAllDocsConstantTextFreq = Ops.virtualAllDocsConstantTextFreq_dep;
        const canDenseAllDocsFreqStream = Ops.canDenseAllDocsFreqStream_dep;
        const appendDenseAllDocsFreqStreamPostings = Ops.appendDenseAllDocsFreqStreamPostings_dep;
        const encodeTextPostingRecord = Ops.encodeTextPostingRecord_dep;
        const encodeCompressedTextPosting = Ops.encodeCompressedTextPosting_dep;
        const textPostingsFileSize = Ops.textPostingsFileSize_dep;
        const encodeTextPostingBlocksHeader = Ops.encodeTextPostingBlocksHeader_dep;
        const textPostingBlockRecordFromStats = Ops.textPostingBlockRecordFromStats_dep;
        const encodeTextPostingBlockRecord = Ops.encodeTextPostingBlockRecord_dep;
        const textPostingBlocksFileSize = Ops.textPostingBlocksFileSize_dep;
        const quantizePersistentBlockScoreBounds = Ops.quantizePersistentBlockScoreBounds_dep;
        const encodeTextPostingBlockImpactsHeader = Ops.encodeTextPostingBlockImpactsHeader_dep;
        const encodePersistentBlockOrdinal = Ops.encodePersistentBlockOrdinal_dep;
        const textPostingBlockImpactsFileSize = Ops.textPostingBlockImpactsFileSize_dep;
        const textTermTopHitLessThan = Ops.textTermTopHitLessThan_dep;
        const textTermTopHitScoreOrderValid = Ops.textTermTopHitScoreOrderValid_dep;
        const persistentWeightedTf = Ops.persistentWeightedTf_dep;
        const persistentDocLen = Ops.persistentDocLen_dep;
        const persistentAvgDocLen = Ops.persistentAvgDocLen_dep;
        const encodeTextTermTopHitsHeader = Ops.encodeTextTermTopHitsHeader_dep;
        const encodeTextTermTopHitTermRecord = Ops.encodeTextTermTopHitTermRecord_dep;
        const encodeTextTermTopHitRecord = Ops.encodeTextTermTopHitRecord_dep;
        const textTermTopHitsFileSize = Ops.textTermTopHitsFileSize_dep;
        const canInlineSingletonPosting = Ops.canInlineSingletonPosting_dep;
        const textTermEntryFromPersistentTerm = Ops.textTermEntryFromPersistentTerm_dep;
        const persistentTermFrontCodedPrefixLen = Ops.persistentTermFrontCodedPrefixLen_dep;
        const appendPersistentFrontCodedTerm = Ops.appendPersistentFrontCodedTerm_dep;
        const encodeTextTermExceptionRecord = Ops.encodeTextTermExceptionRecord_dep;
        const encodeTextTermSingletonPayloadCheckpoint = Ops.encodeTextTermSingletonPayloadCheckpoint_dep;
        const textTermsFileSizeForHeader = Ops.textTermsFileSizeForHeader_dep;
        const textWriteBufferCapacity = Ops.textWriteBufferCapacity_dep;
        const termEntryVirtualAllDocsTextFreq = Ops.termEntryVirtualAllDocsTextFreq_dep;
        const persistent_term_inline_posting_marker = Ops.persistent_term_inline_posting_marker_dep;
        const addPostingToBlockStats = Ops.addPostingToBlockStats_dep;
        const termEntryHasInlinePosting = Ops.termEntryHasInlinePosting_dep;
        const decodeInlineSingletonPostingPayload = Ops.decodeInlineSingletonPostingPayload_dep;
        const textTermSingletonPayloadCount = Ops.textTermSingletonPayloadCount_dep;
        const compressed_posting_max_encoded_len = Ops.compressed_posting_max_encoded_len_dep;
        const persistent_posting_block_ordinal_len = Ops.persistent_posting_block_ordinal_len_dep;
        const textTermTopHitCandidateCannotBeatCurrentWorst = Ops.textTermTopHitCandidateCannotBeatCurrentWorst_dep;
        const termEntryDenseAllDocsFreqStreamOffset = Ops.termEntryDenseAllDocsFreqStreamOffset_dep;
        const persistent_term_singleton_payload_checkpoint_terms = Ops.persistent_term_singleton_payload_checkpoint_terms_dep;
        const textTermSingletonPayloadCheckpointTableBytes = Ops.textTermSingletonPayloadCheckpointTableBytes_dep;
        const textTermsFileSize = Ops.textTermsFileSize_dep;
        const compressedTextPostingBytesForRange = Ops.compressedTextPostingBytesForRange_dep;
        const bm25WeightedTermScore = Ops.bm25WeightedTermScore_dep;
        const encodeZigZagI64 = Ops.encodeZigZagI64_dep;
        const singletonPayloadDelta = Ops.singletonPayloadDelta_dep;
        const encodeTextTermsHeader = Ops.encodeTextTermsHeader_dep;
        const persistent_posting_block_offset_checkpoint_terms = Ops.persistent_posting_block_offset_checkpoint_terms_dep;
        const encodePersistentVarint = Ops.encodePersistentVarint_dep;
        const encodeTextTermEntry = Ops.encodeTextTermEntry_dep;
        const persistent_posting_block_byte_offset_checkpoint_blocks = Ops.persistent_posting_block_byte_offset_checkpoint_blocks_dep;
        const appendTopTextTermHitBoundedCachedWorst = Ops.appendTopTextTermHitBoundedCachedWorst_dep;
        const textTermByteOffsetCheckpointTableBytes = Ops.textTermByteOffsetCheckpointTableBytes_dep;
        const persistent_term_byte_offset_checkpoint_terms = Ops.persistent_term_byte_offset_checkpoint_terms_dep;
        const persistent_term_bytes_max_offset = Ops.persistent_term_bytes_max_offset_dep;
        const persistent_term_exception_rank_checkpoint_terms = Ops.persistent_term_exception_rank_checkpoint_terms_dep;
        const textTermExceptionRankCheckpointCount = Ops.textTermExceptionRankCheckpointCount_dep;
        const textTermExceptionMembershipBytes = Ops.textTermExceptionMembershipBytes_dep;

        pub fn writeTermsAndPostingsFiles(
            allocator: std.mem.Allocator,
            store: storage_mod.Store,
            builder: *PersistentTermBuilder,
            docs_view: *TextDocsFileView,
            meta: PersistentTextMeta,
        ) !PersistentTextCatalogStats {
            std.mem.sort(PersistentTerm, builder.terms.items, {}, persistentTermLessThan);

            var term_bytes_len: u64 = 0;
            var posting_count: u64 = 0;
            var postings_body_bytes: u64 = 0;
            var previous_term: ?[]const u8 = null;
            for (builder.terms.items, 0..) |*term, term_index| {
                if (term.term.len == 0 or term.term.len > std.math.maxInt(u32)) return error.RecordTooLarge;
                if (term.postings.len == 0 or term.postings.len > std.math.maxInt(u32)) return error.InvalidRecord;
                const postings_payload = try termPostingPayloadOrBodyOffset(term.postings.items(), postings_body_bytes, meta.doc_count);
                term.postings_offset = postings_payload.offset;
                term.postings_offset_is_plain = postings_payload.is_plain;
                term.postings_offset_is_dense_freq_stream = postings_payload.is_dense_freq_stream;
                term_bytes_len = std.math.add(u64, term_bytes_len, try persistentTermFrontCodedLen(@intCast(term_index), previous_term, term.term)) catch return error.RecordTooLarge;
                posting_count = std.math.add(u64, posting_count, term.postings.len) catch return error.RecordTooLarge;
                postings_body_bytes = std.math.add(u64, postings_body_bytes, try publishedPostingBodyBytesForTerm(term.postings.items(), term.postings_offset, term.postings_offset_is_plain, term.postings_offset_is_dense_freq_stream)) catch return error.RecordTooLarge;
                previous_term = term.term;
            }

            const postings_path = try textPostingsPath(allocator, store);
            defer allocator.free(postings_path);
            try writeTextPostingsFile(allocator, store, postings_path, builder.terms.items, posting_count, postings_body_bytes);

            const blocks_path = try textPostingBlocksPath(allocator, store);
            defer allocator.free(blocks_path);
            try writeTextPostingBlocksFile(allocator, store, blocks_path, builder.terms.items, posting_count, persistent_posting_block_size);

            const impacts_path = try textPostingBlockImpactsPath(allocator, store);
            defer allocator.free(impacts_path);
            try writeTextPostingBlockImpactsFile(allocator, store, impacts_path, builder.terms.items, persistent_posting_block_size, meta);

            const top_hits_path = try textTermTopHitsPath(allocator, store);
            defer allocator.free(top_hits_path);
            try writeTextTermTopHitsFile(allocator, store, top_hits_path, builder.terms.items, docs_view, meta);

            const terms_path = try textTermsPath(allocator, store);
            defer allocator.free(terms_path);
            try writeTextTermsFile(allocator, store, terms_path, builder.terms.items, term_bytes_len);
            return .{
                .term_count = @intCast(builder.terms.items.len),
                .term_bytes = term_bytes_len,
                .posting_count = posting_count,
            };
        }

        pub fn writeEmptyTermsAndPostingsFiles(
            allocator: std.mem.Allocator,
            store: storage_mod.Store,
            docs_view: *TextDocsFileView,
            meta: PersistentTextMeta,
        ) !PersistentTextCatalogStats {
            if (meta.doc_count != 0) return error.InvalidRecord;
            const terms: []const PersistentTerm = &.{};

            const postings_path = try textPostingsPath(allocator, store);
            defer allocator.free(postings_path);
            try writeTextPostingsFile(allocator, store, postings_path, terms, 0, 0);

            const blocks_path = try textPostingBlocksPath(allocator, store);
            defer allocator.free(blocks_path);
            try writeTextPostingBlocksFile(allocator, store, blocks_path, terms, 0, persistent_posting_block_size);

            const impacts_path = try textPostingBlockImpactsPath(allocator, store);
            defer allocator.free(impacts_path);
            try writeTextPostingBlockImpactsFile(allocator, store, impacts_path, terms, persistent_posting_block_size, meta);

            const top_hits_path = try textTermTopHitsPath(allocator, store);
            defer allocator.free(top_hits_path);
            try writeTextTermTopHitsFile(allocator, store, top_hits_path, terms, docs_view, meta);

            const terms_path = try textTermsPath(allocator, store);
            defer allocator.free(terms_path);
            try writeTextTermsFile(allocator, store, terms_path, terms, 0);

            return .{};
        }

        pub fn writeTextPostingsFile(
            allocator: std.mem.Allocator,
            store: storage_mod.Store,
            path: []const u8,
            terms: []const PersistentTerm,
            posting_count: u64,
            body_bytes: u64,
        ) !void {
            const tmp_path = try tmpPathFor(allocator, path);
            defer allocator.free(tmp_path);
            errdefer std.Io.Dir.cwd().deleteFile(store.io, tmp_path) catch {};
            {
                var file = try std.Io.Dir.cwd().createFile(store.io, tmp_path, .{ .read = true, .truncate = true });
                defer file.close(store.io);
                var writer = try TextBufferedWriter.init(allocator, store.io, file, try textWriteBufferCapacity(try textPostingsFileSize(body_bytes)));
                defer writer.deinit();

                var header_bytes: [TextPostingsHeader.encoded_len]u8 = undefined;
                const header = TextPostingsHeader{ .posting_count = posting_count, .body_bytes = body_bytes };
                encodeTextPostingsHeader(header, &header_bytes);
                try writer.append(&header_bytes);
                var record_bytes: [compressed_posting_max_encoded_len]u8 = undefined;
                var written_body_bytes: u64 = 0;
                for (terms) |term| {
                    const entry = textTermEntryFromPersistentTerm(term, null);
                    if (termEntryHasInlinePosting(entry)) continue;
                    if (termEntryDenseAllDocsFreqStreamOffset(entry)) |offset| {
                        if (offset != written_body_bytes) return error.InvalidRecord;
                        written_body_bytes = std.math.add(u64, written_body_bytes, try appendDenseAllDocsFreqStreamPostings(&writer, term.postings.items())) catch return error.RecordTooLarge;
                        continue;
                    }
                    if (!term.postings_offset_is_plain and !term.postings_offset_is_dense_freq_stream and (term.postings_offset & persistent_term_inline_posting_marker) != 0 and term.postings.len > 1) continue;
                    if (term.postings_offset != written_body_bytes) return error.InvalidRecord;
                    var previous_doc_id: u64 = 0;
                    for (term.postings.items(), 0..) |posting, posting_index| {
                        if (posting_index % persistent_posting_block_capacity == 0) previous_doc_id = 0;
                        const encoded_len = try encodeCompressedTextPosting(posting, previous_doc_id, &record_bytes);
                        try writer.append(record_bytes[0..encoded_len]);
                        written_body_bytes = std.math.add(u64, written_body_bytes, encoded_len) catch return error.RecordTooLarge;
                        previous_doc_id = posting.doc_id;
                    }
                }
                if (written_body_bytes != body_bytes) return error.InvalidRecord;
                try writer.flush();
                if (textOptionsNeedSync(store)) try file.sync(store.io);
            }
            try renameReplace(store.io, tmp_path, path);
        }

        pub fn writeTextPostingBlocksFile(
            allocator: std.mem.Allocator,
            store: storage_mod.Store,
            path: []const u8,
            terms: []const PersistentTerm,
            posting_count: u64,
            block_size: u64,
        ) !void {
            if (block_size == 0) return error.InvalidRecord;
            const block_count = try postingBlockCountForTerms(terms, block_size);
            const tmp_path = try tmpPathFor(allocator, path);
            defer allocator.free(tmp_path);
            errdefer std.Io.Dir.cwd().deleteFile(store.io, tmp_path) catch {};
            {
                var file = try std.Io.Dir.cwd().createFile(store.io, tmp_path, .{ .read = true, .truncate = true });
                defer file.close(store.io);
                var writer = try TextBufferedWriter.init(allocator, store.io, file, try textWriteBufferCapacity(try textPostingBlocksFileSize(@intCast(terms.len), block_count)));
                defer writer.deinit();

                var header_bytes: [TextPostingBlocksHeader.encoded_len]u8 = undefined;
                const header = TextPostingBlocksHeader{
                    .term_count = @intCast(terms.len),
                    .posting_count = posting_count,
                    .block_count = block_count,
                    .block_size = block_size,
                };
                encodeTextPostingBlocksHeader(header, &header_bytes);
                try writer.append(&header_bytes);

                var record_bytes: [TextPostingBlockRecord.encoded_len]u8 = undefined;
                var term_block_offset: u64 = 0;
                var term_offset_bytes: [persistent_posting_block_ordinal_len]u8 = undefined;
                const block_len = std.math.cast(usize, block_size) orelse return error.RecordTooLarge;
                for (terms) |term| {
                    const postings = term.postings.items();
                    const term_blocks = try publishedPostingBlockCountForPayload(postings.len, term.postings_offset, term.postings_offset_is_plain, term.postings_offset_is_dense_freq_stream, block_size);
                    if (term_blocks == 0) continue;
                    var pos: usize = 0;
                    var block_posting_offset = term.postings_offset;
                    while (pos < postings.len) {
                        const current_block_count = @min(postings.len - pos, block_len);
                        const block_postings = postings[pos..][0..current_block_count];
                        const stats = try postingBlockStatsFromMemory(
                            block_postings,
                            block_posting_offset,
                        );
                        try encodeTextPostingBlockRecord(try textPostingBlockRecordFromStats(stats), &record_bytes);
                        try writer.append(&record_bytes);
                        const range_bytes = try compressedTextPostingBytesForRange(block_postings, 0);
                        block_posting_offset = std.math.add(u64, block_posting_offset, range_bytes.bytes) catch return error.RecordTooLarge;
                        pos += current_block_count;
                    }
                }
                for (terms, 0..) |term, term_index| {
                    if (@as(u64, @intCast(term_index)) % persistent_posting_block_offset_checkpoint_terms == 0) {
                        try encodePersistentBlockOrdinal(term_block_offset, &term_offset_bytes);
                        try writer.append(&term_offset_bytes);
                    }
                    const term_blocks = try publishedPostingBlockCountForPayload(term.postings.len, term.postings_offset, term.postings_offset_is_plain, term.postings_offset_is_dense_freq_stream, block_size);
                    term_block_offset = std.math.add(u64, term_block_offset, term_blocks) catch return error.RecordTooLarge;
                }
                if (term_block_offset != block_count) return error.InvalidRecord;
                var global_block_index: u64 = 0;
                for (terms) |term| {
                    const postings = term.postings.items();
                    const term_blocks = try publishedPostingBlockCountForPayload(postings.len, term.postings_offset, term.postings_offset_is_plain, term.postings_offset_is_dense_freq_stream, block_size);
                    if (term_blocks == 0) continue;
                    var pos: usize = 0;
                    var block_posting_offset = term.postings_offset;
                    while (pos < postings.len) {
                        if (global_block_index % persistent_posting_block_byte_offset_checkpoint_blocks == 0) {
                            if (block_posting_offset < term.postings_offset) return error.InvalidRecord;
                            const relative_offset = block_posting_offset - term.postings_offset;
                            if (relative_offset > std.math.maxInt(u32)) return error.RecordTooLarge;
                            var offset_bytes: [4]u8 = undefined;
                            std.mem.writeInt(u32, &offset_bytes, @intCast(relative_offset), .little);
                            try writer.append(&offset_bytes);
                        }
                        const current_block_count = @min(postings.len - pos, block_len);
                        const range_bytes = try compressedTextPostingBytesForRange(postings[pos..][0..current_block_count], 0);
                        block_posting_offset = std.math.add(u64, block_posting_offset, range_bytes.bytes) catch return error.RecordTooLarge;
                        pos += current_block_count;
                        global_block_index = std.math.add(u64, global_block_index, 1) catch return error.RecordTooLarge;
                    }
                }
                if (global_block_index != block_count) return error.InvalidRecord;
                try writer.flush();
                if (textOptionsNeedSync(store)) try file.sync(store.io);
            }
            try renameReplace(store.io, tmp_path, path);
        }

        pub const MemoryPostingBlockImpact = struct {
            local_block_index: u64,
            max_weighted_tf: f32,
            upper_score: f32,
        };

        pub fn memoryPostingBlockImpactLessThan(_: void, lhs: MemoryPostingBlockImpact, rhs: MemoryPostingBlockImpact) bool {
            if (lhs.upper_score != rhs.upper_score) return lhs.upper_score > rhs.upper_score;
            if (lhs.max_weighted_tf != rhs.max_weighted_tf) return lhs.max_weighted_tf > rhs.max_weighted_tf;
            return lhs.local_block_index < rhs.local_block_index;
        }

        pub fn writeTextPostingBlockImpactsFile(
            allocator: std.mem.Allocator,
            store: storage_mod.Store,
            path: []const u8,
            terms: []const PersistentTerm,
            block_size: u64,
            meta: PersistentTextMeta,
        ) !void {
            if (block_size == 0) return error.InvalidRecord;
            const block_count = try postingBlockCountForTerms(terms, block_size);
            const tmp_path = try tmpPathFor(allocator, path);
            defer allocator.free(tmp_path);
            errdefer std.Io.Dir.cwd().deleteFile(store.io, tmp_path) catch {};
            {
                var file = try std.Io.Dir.cwd().createFile(store.io, tmp_path, .{ .read = true, .truncate = true });
                defer file.close(store.io);
                var writer = try TextBufferedWriter.init(allocator, store.io, file, try textWriteBufferCapacity(try textPostingBlockImpactsFileSize(@intCast(terms.len), block_count)));
                defer writer.deinit();

                var header_bytes: [TextPostingBlockImpactsHeader.encoded_len]u8 = undefined;
                const header = TextPostingBlockImpactsHeader{
                    .term_count = @intCast(terms.len),
                    .block_count = block_count,
                };
                encodeTextPostingBlockImpactsHeader(header, &header_bytes);
                try writer.append(&header_bytes);

                var block_index_base: u64 = 0;
                const block_len = std.math.cast(usize, block_size) orelse return error.RecordTooLarge;
                const avg_doc_len = persistentAvgDocLen(meta);
                var impact_bytes: [persistent_posting_block_ordinal_len]u8 = undefined;
                for (terms) |term| {
                    const postings = term.postings.items();
                    var impacts = std.ArrayList(MemoryPostingBlockImpact).empty;
                    defer impacts.deinit(allocator);
                    const term_block_count = try publishedPostingBlockCountForPayload(postings.len, term.postings_offset, term.postings_offset_is_plain, term.postings_offset_is_dense_freq_stream, block_size);
                    if (term_block_count == 0) continue;
                    try impacts.ensureTotalCapacityPrecise(allocator, std.math.cast(usize, term_block_count) orelse return error.RecordTooLarge);
                    var pos: usize = 0;
                    var local_block_index: u64 = 0;
                    while (pos < postings.len) : (local_block_index += 1) {
                        const current_block_count = @min(postings.len - pos, block_len);
                        const stats = try postingBlockStatsFromMemory(
                            postings[pos..][0..current_block_count],
                            std.math.add(u64, block_index_base, local_block_index) catch return error.RecordTooLarge,
                        );
                        const stored_bounds = try quantizePersistentBlockScoreBounds(stats.max_weighted_tf, stats.min_doc_len);
                        const upper_score = bm25WeightedTermScore(
                            stored_bounds.max_weighted_tf,
                            stored_bounds.min_doc_len,
                            avg_doc_len,
                            meta.doc_count,
                            @intCast(postings.len),
                            .{},
                        );
                        if (!std.math.isFinite(upper_score)) return core.Error.Unsupported;
                        impacts.appendAssumeCapacity(.{
                            .local_block_index = local_block_index,
                            .max_weighted_tf = stored_bounds.max_weighted_tf,
                            .upper_score = upper_score,
                        });
                        pos += current_block_count;
                    }
                    std.mem.sort(MemoryPostingBlockImpact, impacts.items, {}, memoryPostingBlockImpactLessThan);
                    for (impacts.items) |impact| {
                        const global_block_index = std.math.add(u64, block_index_base, impact.local_block_index) catch return error.RecordTooLarge;
                        try encodePersistentBlockOrdinal(global_block_index, &impact_bytes);
                        try writer.append(&impact_bytes);
                    }
                    block_index_base = std.math.add(u64, block_index_base, term_block_count) catch return error.RecordTooLarge;
                }
                if (block_index_base != block_count) return error.InvalidRecord;
                try writer.flush();
                if (textOptionsNeedSync(store)) try file.sync(store.io);
            }
            try renameReplace(store.io, tmp_path, path);
        }

        pub fn writeTextTermTopHitsFile(
            allocator: std.mem.Allocator,
            store: storage_mod.Store,
            path: []const u8,
            terms: []const PersistentTerm,
            docs_view: *TextDocsFileView,
            meta: PersistentTextMeta,
        ) !void {
            const hit_count = try textTermTopHitCount(terms);
            const hit_term_count = try textTermTopHitTermCount(terms);
            const tmp_path = try tmpPathFor(allocator, path);
            defer allocator.free(tmp_path);
            errdefer std.Io.Dir.cwd().deleteFile(store.io, tmp_path) catch {};
            {
                var file = try std.Io.Dir.cwd().createFile(store.io, tmp_path, .{ .read = true, .truncate = true });
                defer file.close(store.io);
                var writer = try TextBufferedWriter.init(allocator, store.io, file, try textWriteBufferCapacity(try textTermTopHitsFileSize(hit_count, hit_term_count)));
                defer writer.deinit();

                var header_bytes: [TextTermTopHitsHeader.encoded_len]u8 = undefined;
                const header = TextTermTopHitsHeader{
                    .term_count = @intCast(terms.len),
                    .hit_count = hit_count,
                    .hit_term_count = hit_term_count,
                    .capacity = persistent_term_top_hit_capacity,
                };
                encodeTextTermTopHitsHeader(header, &header_bytes);
                try writer.append(&header_bytes);

                const avg_doc_len = persistentAvgDocLen(meta);
                var record_bytes: [TextTermTopHitRecord.encoded_len]u8 = undefined;
                for (terms) |term| {
                    const postings = term.postings.items();
                    const term_hit_count = persistentTermTopHitCountForTerm(term);
                    if (term_hit_count == 0) continue;
                    var hits = std.ArrayList(TextTermTopHitRecord).empty;
                    defer hits.deinit(allocator);
                    try hits.ensureTotalCapacityPrecise(allocator, @intCast(term_hit_count));
                    var worst_hit_index: ?usize = null;
                    for (postings) |posting| {
                        if (posting.doc_id == 0 or posting.doc_id > meta.doc_count) return error.InvalidRecord;
                        if (try textTermTopHitCandidateCannotBeatCurrentWorst(
                            hits.items,
                            worst_hit_index,
                            @intCast(term_hit_count),
                            posting,
                            avg_doc_len,
                            meta.doc_count,
                            @intCast(postings.len),
                        )) continue;
                        const doc = try docs_view.readTopHitDocStatsAt(posting.doc_id - 1);
                        if (doc.doc_id != posting.doc_id) return error.InvalidRecord;
                        const score = bm25WeightedTermScore(
                            persistentWeightedTf(posting),
                            doc.doc_len,
                            avg_doc_len,
                            meta.doc_count,
                            @intCast(postings.len),
                            .{},
                        );
                        if (!std.math.isFinite(score)) return core.Error.Unsupported;
                        try appendTopTextTermHitBoundedCachedWorst(allocator, &hits, @intCast(persistent_term_top_hit_capacity), &worst_hit_index, .{
                            .doc_id = doc.doc_id,
                            .text_freq = posting.text_freq,
                            .node_id = doc.node_id,
                            .score = score,
                        });
                    }
                    std.mem.sort(TextTermTopHitRecord, hits.items, {}, textTermTopHitLessThan);
                    for (hits.items) |hit| {
                        try encodeTextTermTopHitRecord(hit, &record_bytes);
                        try writer.append(&record_bytes);
                    }
                }
                var term_hit_offset: u64 = 0;
                var hit_terms_written: u64 = 0;
                var term_header_bytes: [TextTermTopHitTermRecord.encoded_len]u8 = undefined;
                for (terms, 0..) |term, term_index| {
                    const term_hit_count = persistentTermTopHitCountForTerm(term);
                    if (term_hit_count == 0) continue;
                    try encodeTextTermTopHitTermRecord(.{
                        .term_index = @intCast(term_index),
                        .hit_offset = term_hit_offset,
                        .hit_count = term_hit_count,
                    }, &term_header_bytes);
                    try writer.append(&term_header_bytes);
                    hit_terms_written = std.math.add(u64, hit_terms_written, 1) catch return error.RecordTooLarge;
                    term_hit_offset = std.math.add(u64, term_hit_offset, term_hit_count) catch return error.RecordTooLarge;
                }
                if (term_hit_offset != hit_count) return error.InvalidRecord;
                if (hit_terms_written != hit_term_count) return error.InvalidRecord;
                try writer.flush();
                if (textOptionsNeedSync(store)) try file.sync(store.io);
            }
            try renameReplace(store.io, tmp_path, path);
        }

        pub fn textTermTopHitCount(terms: []const PersistentTerm) !u64 {
            var hit_count: u64 = 0;
            for (terms) |term| {
                hit_count = std.math.add(u64, hit_count, persistentTermTopHitCountForTerm(term)) catch return error.RecordTooLarge;
            }
            return hit_count;
        }

        pub fn textTermTopHitTermCount(terms: []const PersistentTerm) !u64 {
            var hit_term_count: u64 = 0;
            for (terms) |term| {
                if (persistentTermTopHitCountForTerm(term) != 0) {
                    hit_term_count = std.math.add(u64, hit_term_count, 1) catch return error.RecordTooLarge;
                }
            }
            return hit_term_count;
        }

        pub fn persistentTermTopHitCountForTerm(term: PersistentTerm) u64 {
            return persistentTermTopHitCountForPostingCount(@intCast(term.postings.len));
        }

        pub fn persistentTermTopHitCountForPostingCount(postings_len: u64) u64 {
            if (postings_len < persistent_term_top_hit_min_postings) return 0;
            return @min(postings_len, persistent_term_top_hit_capacity);
        }

        pub fn postingBlockCountForTerms(terms: []const PersistentTerm, block_size: u64) !u64 {
            if (block_size == 0) return error.InvalidRecord;
            var block_count: u64 = 0;
            for (terms) |term| {
                block_count = std.math.add(u64, block_count, try publishedPostingBlockCountForPayload(term.postings.len, term.postings_offset, term.postings_offset_is_plain, term.postings_offset_is_dense_freq_stream, block_size)) catch return error.RecordTooLarge;
            }
            return block_count;
        }

        pub fn publishedPostingBlockCountForEntry(entry: TextTermEntry, block_size: u64) !u64 {
            if (termEntryVirtualAllDocsTextFreq(entry) != null) return 0;
            if (termEntryDenseAllDocsFreqStreamOffset(entry) != null) return 0;
            return publishedPostingBlockCount(std.math.cast(usize, entry.postings_count) orelse return error.RecordTooLarge, block_size);
        }

        pub fn publishedPostingBlockCountForPayload(postings_len: usize, postings_offset: u64, postings_offset_is_plain: bool, postings_offset_is_dense_freq_stream: bool, block_size: u64) !u64 {
            if (postings_offset_is_dense_freq_stream) return 0;
            if (!postings_offset_is_plain and postings_len > 1 and (postings_offset & persistent_term_inline_posting_marker) != 0) return 0;
            return publishedPostingBlockCount(postings_len, block_size);
        }

        pub fn publishedPostingBlockCount(postings_len: usize, block_size: u64) !u64 {
            const natural_count = try postingBlockCount(postings_len, block_size);
            if (natural_count <= 1) return 0;
            return natural_count;
        }

        pub fn postingBlockCount(postings_len: usize, block_size: u64) !u64 {
            if (block_size == 0) return error.InvalidRecord;
            const len: u64 = @intCast(postings_len);
            const with_rounding = std.math.add(u64, len, block_size - 1) catch return error.RecordTooLarge;
            return with_rounding / block_size;
        }

        pub fn postingBlockStatsFromMemory(postings: []const TextPostingRecord, posting_offset: u64) !TextPostingBlockStats {
            if (postings.len == 0) return error.InvalidRecord;
            var previous_doc_id: u64 = 0;
            var stats = TextPostingBlockStats{
                .posting_offset = posting_offset,
                .posting_count = @intCast(postings.len),
                .first_doc_id = 0,
                .last_doc_id = 0,
                .max_weighted_tf = 0,
                .min_doc_len = std.math.inf(f32),
            };
            for (postings) |posting| {
                try addPostingToBlockStats(posting, &previous_doc_id, std.math.maxInt(u64), &stats);
            }
            return stats;
        }

        pub fn persistentTermExceptionCount(terms: []const PersistentTerm) !u64 {
            var count: u64 = 0;
            for (terms) |term| {
                const entry = textTermEntryFromPersistentTerm(term, null);
                if (!termEntryHasInlinePosting(entry)) {
                    count = std.math.add(u64, count, 1) catch return error.RecordTooLarge;
                }
            }
            return count;
        }

        pub const SingletonPayloadBytes = struct {
            checkpoints: std.ArrayList(u8) = .empty,
            payloads: std.ArrayList(u8) = .empty,
            count: u64 = 0,

            fn deinit(self: *SingletonPayloadBytes, allocator: std.mem.Allocator) void {
                self.payloads.deinit(allocator);
                self.checkpoints.deinit(allocator);
            }
        };

        pub fn appendSingletonPayloadBytes(
            allocator: std.mem.Allocator,
            out: *SingletonPayloadBytes,
            previous_payload: *u32,
            payload: u32,
        ) !void {
            _ = try decodeInlineSingletonPostingPayload(payload);
            if (out.count % persistent_term_singleton_payload_checkpoint_terms == 0) {
                var checkpoint_bytes: [TextTermSingletonPayloadCheckpoint.encoded_len]u8 = undefined;
                try encodeTextTermSingletonPayloadCheckpoint(.{
                    .stream_offset = @intCast(out.payloads.items.len),
                    .previous_payload = previous_payload.*,
                }, &checkpoint_bytes);
                try out.checkpoints.appendSlice(allocator, &checkpoint_bytes);
            }
            var delta_bytes: [10]u8 = undefined;
            const encoded_delta = encodeZigZagI64(singletonPayloadDelta(previous_payload.*, payload));
            const delta_len = try encodePersistentVarint(encoded_delta, &delta_bytes);
            try out.payloads.appendSlice(allocator, delta_bytes[0..delta_len]);
            previous_payload.* = payload;
            out.count = std.math.add(u64, out.count, 1) catch return error.RecordTooLarge;
        }

        pub fn buildSingletonPayloadBytes(allocator: std.mem.Allocator, terms: []const PersistentTerm) !SingletonPayloadBytes {
            var out = SingletonPayloadBytes{};
            errdefer out.deinit(allocator);
            var previous_payload: u32 = 0;
            for (terms) |term| {
                const entry = textTermEntryFromPersistentTerm(term, null);
                if (!termEntryHasInlinePosting(entry)) continue;
                try appendSingletonPayloadBytes(allocator, &out, &previous_payload, @intCast(entry.postings_offset));
            }
            const expected_checkpoint_bytes = try textTermSingletonPayloadCheckpointTableBytes(out.count);
            if (out.checkpoints.items.len != expected_checkpoint_bytes) return error.InvalidRecord;
            return out;
        }

        pub fn writeTextTermsFile(
            allocator: std.mem.Allocator,
            store: storage_mod.Store,
            path: []const u8,
            terms: []const PersistentTerm,
            term_bytes_len: u64,
        ) !void {
            const tmp_path = try tmpPathFor(allocator, path);
            defer allocator.free(tmp_path);
            errdefer std.Io.Dir.cwd().deleteFile(store.io, tmp_path) catch {};
            {
                var file = try std.Io.Dir.cwd().createFile(store.io, tmp_path, .{ .read = true, .truncate = true });
                defer file.close(store.io);
                const term_exception_count = try persistentTermExceptionCount(terms);
                var singleton_payloads = try buildSingletonPayloadBytes(allocator, terms);
                defer singleton_payloads.deinit(allocator);
                const singleton_count = try textTermSingletonPayloadCount(@intCast(terms.len), term_exception_count);
                if (singleton_payloads.count != singleton_count) return error.InvalidRecord;
                var writer = try TextBufferedWriter.init(allocator, store.io, file, try textWriteBufferCapacity(try textTermsFileSize(@intCast(terms.len), term_bytes_len, term_exception_count, @intCast(singleton_payloads.payloads.items.len))));
                defer writer.deinit();

                var header_bytes: [TextTermsHeader.encoded_len]u8 = undefined;
                const header = TextTermsHeader{
                    .term_count = @intCast(terms.len),
                    .term_bytes = term_bytes_len,
                    .term_exception_count = term_exception_count,
                    .singleton_payload_bytes = @intCast(singleton_payloads.payloads.items.len),
                };
                encodeTextTermsHeader(header, &header_bytes);
                try writer.append(&header_bytes);

                var entry_bytes: [TextTermEntry.encoded_len]u8 = undefined;
                var previous_entry_term: ?[]const u8 = null;
                for (terms, 0..) |term, term_index| {
                    const front_prefix_len = try persistentTermFrontCodedPrefixLen(@intCast(term_index), previous_entry_term, term.term);
                    const entry = textTermEntryFromPersistentTerm(term, front_prefix_len);
                    try encodeTextTermEntry(entry, &entry_bytes);
                    try writer.append(&entry_bytes);
                    previous_entry_term = term.term;
                }
                var checkpoint_bytes = std.ArrayList(u8).empty;
                defer checkpoint_bytes.deinit(allocator);
                try checkpoint_bytes.ensureTotalCapacityPrecise(allocator, std.math.cast(usize, try textTermByteOffsetCheckpointTableBytes(@intCast(terms.len))) orelse return error.RecordTooLarge);

                var term_offset: u64 = 0;
                var previous_term: ?[]const u8 = null;
                for (terms, 0..) |term, term_index| {
                    if (@as(u64, @intCast(term_index)) % persistent_term_byte_offset_checkpoint_terms == 0) {
                        if (term_offset > persistent_term_bytes_max_offset) return error.RecordTooLarge;
                        var offset_bytes: [4]u8 = undefined;
                        std.mem.writeInt(u32, &offset_bytes, @intCast(term_offset), .little);
                        try checkpoint_bytes.appendSlice(allocator, &offset_bytes);
                    }
                    const encoded_term_len = try appendPersistentFrontCodedTerm(&writer, @intCast(term_index), previous_term, term.term);
                    term_offset = std.math.add(u64, term_offset, encoded_term_len) catch return error.RecordTooLarge;
                    previous_term = term.term;
                }
                if (term_offset != term_bytes_len) return error.InvalidRecord;
                if (checkpoint_bytes.items.len != (try textTermByteOffsetCheckpointTableBytes(@intCast(terms.len)))) return error.InvalidRecord;
                try writer.append(checkpoint_bytes.items);

                var exception_rank_checkpoints_written: u64 = 0;
                var exception_membership_bytes_written: u64 = 0;
                var exception_membership_byte: u8 = 0;
                var exception_membership_bits: u8 = 0;
                var exceptions_written: u64 = 0;
                for (terms, 0..) |term, term_index| {
                    const term_index_u64: u64 = @intCast(term_index);
                    if (term_index_u64 % persistent_term_exception_rank_checkpoint_terms == 0) {
                        if (exceptions_written > std.math.maxInt(u32)) return error.RecordTooLarge;
                        var rank_bytes: [4]u8 = undefined;
                        std.mem.writeInt(u32, &rank_bytes, @intCast(exceptions_written), .little);
                        try writer.append(&rank_bytes);
                        exception_rank_checkpoints_written = std.math.add(u64, exception_rank_checkpoints_written, 1) catch return error.RecordTooLarge;
                    }
                    const entry = textTermEntryFromPersistentTerm(term, null);
                    if (!termEntryHasInlinePosting(entry)) {
                        exception_membership_byte |= @as(u8, 1) << @as(u3, @intCast(exception_membership_bits));
                        exceptions_written = std.math.add(u64, exceptions_written, 1) catch return error.RecordTooLarge;
                    }
                    exception_membership_bits += 1;
                    if (exception_membership_bits == 8) {
                        try writer.append(&.{exception_membership_byte});
                        exception_membership_bytes_written = std.math.add(u64, exception_membership_bytes_written, 1) catch return error.RecordTooLarge;
                        exception_membership_byte = 0;
                        exception_membership_bits = 0;
                    }
                }
                if (exception_membership_bits != 0) {
                    try writer.append(&.{exception_membership_byte});
                    exception_membership_bytes_written = std.math.add(u64, exception_membership_bytes_written, 1) catch return error.RecordTooLarge;
                }
                if (exception_rank_checkpoints_written != (try textTermExceptionRankCheckpointCount(@intCast(terms.len)))) return error.InvalidRecord;
                if (exception_membership_bytes_written != (try textTermExceptionMembershipBytes(@intCast(terms.len)))) return error.InvalidRecord;
                if (exceptions_written != term_exception_count) return error.InvalidRecord;

                var exception_record_bytes: [TextTermExceptionRecord.encoded_len]u8 = undefined;
                exceptions_written = 0;
                for (terms, 0..) |term, term_index| {
                    const entry = textTermEntryFromPersistentTerm(term, null);
                    if (termEntryHasInlinePosting(entry)) continue;
                    _ = term_index;
                    try encodeTextTermExceptionRecord(.{
                        .doc_freq = @intCast(term.postings.len),
                        .postings_offset = term.postings_offset,
                        .postings_offset_is_plain = term.postings_offset_is_plain,
                        .postings_offset_is_dense_freq_stream = term.postings_offset_is_dense_freq_stream,
                    }, &exception_record_bytes);
                    try writer.append(&exception_record_bytes);
                    exceptions_written = std.math.add(u64, exceptions_written, 1) catch return error.RecordTooLarge;
                }
                if (exceptions_written != term_exception_count) return error.InvalidRecord;
                try writer.append(singleton_payloads.checkpoints.items);
                try writer.append(singleton_payloads.payloads.items);
                try writer.flush();
                if (textOptionsNeedSync(store)) try file.sync(store.io);
            }
            try renameReplace(store.io, tmp_path, path);
        }

        const postingBlockCountForTest = postingBlockCount;
        const topHitCountForPostingCountForTest = persistentTermTopHitCountForPostingCount;
        pub const Internal = struct {
            pub const postingBlockCount = postingBlockCountForTest;
            pub const topHitCountForPostingCount = topHitCountForPostingCountForTest;
        };
    };
}

const TestOps = struct {
    pub const PersistentTermBuilder_dep = void;
    pub const TextDocsFileView_dep = void;
    pub const PersistentTextMeta_dep = void;
    pub const PersistentTextCatalogStats_dep = void;
    pub const PersistentTerm_dep = void;
    pub const TextPostingRecord_dep = void;
    pub const TextBufferedWriter_dep = void;
    pub const TextPostingsHeader_dep = void;
    pub const TextPostingBlocksHeader_dep = void;
    pub const TextPostingBlockRecord_dep = void;
    pub const TextPostingBlockImpactsHeader_dep = void;
    pub const TextTermTopHitsHeader_dep = void;
    pub const TextTermTopHitTermRecord_dep = void;
    pub const TextTermTopHitRecord_dep = void;
    pub const TextTopHitDocStats_dep = void;
    pub const TextPostingBlockStats_dep = void;
    pub const TextTermsHeader_dep = void;
    pub const TextTermEntry_dep = void;
    pub const TextTermExceptionRecord_dep = void;
    pub const TextTermSingletonPayloadCheckpoint_dep = void;
    pub const persistentTermLessThan_dep = void;
    pub const termPostingPayloadOrBodyOffset_dep = void;
    pub const persistentTermFrontCodedLen_dep = void;
    pub const publishedPostingBodyBytesForTerm_dep = void;
    pub const textPostingsPath_dep = void;
    pub const textPostingBlocksPath_dep = void;
    pub const textPostingBlockImpactsPath_dep = void;
    pub const textTermTopHitsPath_dep = void;
    pub const textTermsPath_dep = void;
    pub const persistent_posting_block_size_dep: u64 = 128;
    pub const persistent_posting_block_capacity_dep: usize = 128;
    pub const persistent_term_top_hit_capacity_dep: u64 = 64;
    pub const persistent_term_top_hit_min_postings_dep: u64 = 128;
    pub const text_write_buffer_bytes_dep: usize = 1;
    pub const tmpPathFor_dep = void;
    pub const textOptionsNeedSync_dep = void;
    pub const renameReplace_dep = void;
    pub const compressedTextPostingBytesForTerm_dep = void;
    pub const encodeTextPostingsHeader_dep = void;
    pub const canVirtualizeAllDocsConstantTextFreqTerm_dep = void;
    pub const virtualAllDocsConstantTextFreq_dep = void;
    pub const canDenseAllDocsFreqStream_dep = void;
    pub const appendDenseAllDocsFreqStreamPostings_dep = void;
    pub const encodeTextPostingRecord_dep = void;
    pub const encodeCompressedTextPosting_dep = void;
    pub const textPostingsFileSize_dep = void;
    pub const encodeTextPostingBlocksHeader_dep = void;
    pub const textPostingBlockRecordFromStats_dep = void;
    pub const encodeTextPostingBlockRecord_dep = void;
    pub const textPostingBlocksFileSize_dep = void;
    pub const quantizePersistentBlockScoreBounds_dep = void;
    pub const encodeTextPostingBlockImpactsHeader_dep = void;
    pub const encodePersistentBlockOrdinal_dep = void;
    pub const textPostingBlockImpactsFileSize_dep = void;
    pub const textTermTopHitLessThan_dep = void;
    pub const textTermTopHitScoreOrderValid_dep = void;
    pub const persistentWeightedTf_dep = void;
    pub const persistentDocLen_dep = void;
    pub const persistentAvgDocLen_dep = void;
    pub const encodeTextTermTopHitsHeader_dep = void;
    pub const encodeTextTermTopHitTermRecord_dep = void;
    pub const encodeTextTermTopHitRecord_dep = void;
    pub const textTermTopHitsFileSize_dep = void;
    pub const canInlineSingletonPosting_dep = void;
    pub const textTermEntryFromPersistentTerm_dep = void;
    pub const persistentTermFrontCodedPrefixLen_dep = void;
    pub const appendPersistentFrontCodedTerm_dep = void;
    pub const encodeTextTermExceptionRecord_dep = void;
    pub const encodeTextTermSingletonPayloadCheckpoint_dep = void;
    pub const textTermsFileSizeForHeader_dep = void;
    pub const textWriteBufferCapacity_dep = void;
    pub const termEntryVirtualAllDocsTextFreq_dep = void;
    pub const persistent_term_inline_posting_marker_dep: u64 = 0;
    pub const addPostingToBlockStats_dep = void;
    pub const termEntryHasInlinePosting_dep = void;
    pub const decodeInlineSingletonPostingPayload_dep = void;
    pub const textTermSingletonPayloadCount_dep = void;
    pub const compressed_posting_max_encoded_len_dep: usize = 24;
    pub const persistent_posting_block_ordinal_len_dep: usize = 8;
    pub const textTermTopHitCandidateCannotBeatCurrentWorst_dep = void;
    pub const termEntryDenseAllDocsFreqStreamOffset_dep = void;
    pub const persistent_term_singleton_payload_checkpoint_terms_dep: u64 = 1;
    pub const textTermSingletonPayloadCheckpointTableBytes_dep = void;
    pub const textTermsFileSize_dep = void;
    pub const compressedTextPostingBytesForRange_dep = void;
    pub const bm25WeightedTermScore_dep = void;
    pub const encodeZigZagI64_dep = void;
    pub const singletonPayloadDelta_dep = void;
    pub const encodeTextTermsHeader_dep = void;
    pub const persistent_posting_block_offset_checkpoint_terms_dep: u64 = 1;
    pub const encodePersistentVarint_dep = void;
    pub const encodeTextTermEntry_dep = void;
    pub const persistent_posting_block_byte_offset_checkpoint_blocks_dep: u64 = 1;
    pub const appendTopTextTermHitBoundedCachedWorst_dep = void;
    pub const textTermByteOffsetCheckpointTableBytes_dep = void;
    pub const persistent_term_byte_offset_checkpoint_terms_dep: u64 = 1;
    pub const persistent_term_bytes_max_offset_dep: u64 = std.math.maxInt(u64);
    pub const persistent_term_exception_rank_checkpoint_terms_dep: u64 = 1;
    pub const textTermExceptionRankCheckpointCount_dep = void;
    pub const textTermExceptionMembershipBytes_dep = void;
};
const TestCore = struct {
    pub const Error = error{Unsupported};
};
const TestStorage = struct {
    pub const Store = void;
};
const test_owner = TermPostingCatalogPublication(TestCore, TestStorage, TestOps);

test "term posting publication omits top hits below admission threshold" {
    try std.testing.expectEqual(@as(u64, 0), test_owner.Internal.topHitCountForPostingCount(127));
}

test "term posting publication caps admitted per-term top hits" {
    try std.testing.expectEqual(@as(u64, 64), test_owner.Internal.topHitCountForPostingCount(4096));
}

test "term posting publication emits no blocks for empty postings" {
    try std.testing.expectEqual(@as(u64, 0), try test_owner.Internal.postingBlockCount(0, 128));
}

test "term posting publication rounds partial posting blocks upward" {
    try std.testing.expectEqual(@as(u64, 2), try test_owner.Internal.postingBlockCount(129, 128));
}
