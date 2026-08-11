const std = @import("std");
const builtin = @import("builtin");
const tokenizer_mod = @import("tokenizer.zig");
const scoring_mod = @import("scoring.zig");
const catalog_format_mod = @import("catalog_format.zig");
const posting_format_mod = @import("posting_format.zig");
const term_format_mod = @import("term_format.zig");
const search_acceleration_format_mod = @import("search_acceleration_format.zig");
const rebuild_runtime_mod = @import("rebuild_runtime.zig");

const streaming_run_derived_scratch_shrink_min_capacity: usize = 4096;
const streaming_run_derived_scratch_shrink_ratio: usize = 4;

fn resetStreamingRunPublicationScratch(
    comptime Item: type,
    allocator: std.mem.Allocator,
    scratch: *std.ArrayList(Item),
    required_capacity: usize,
) !void {
    scratch.clearRetainingCapacity();
    if (scratch.capacity > streaming_run_derived_scratch_shrink_min_capacity and
        required_capacity <= scratch.capacity / streaming_run_derived_scratch_shrink_ratio)
    {
        scratch.shrinkAndFree(allocator, 0);
    }
    try scratch.ensureTotalCapacityPrecise(allocator, required_capacity);
}

test "streaming run derived term scratch uses exact summary capacity" {
    var scratch: std.ArrayList(u64) = .empty;
    defer scratch.deinit(std.testing.allocator);

    try resetStreamingRunPublicationScratch(u64, std.testing.allocator, &scratch, 17);
    try std.testing.expectEqual(@as(usize, 17), scratch.capacity);
}

test "streaming run derived term scratch releases large impact high-water" {
    var scratch: std.ArrayList(u64) = .empty;
    defer scratch.deinit(std.testing.allocator);

    try resetStreamingRunPublicationScratch(
        u64,
        std.testing.allocator,
        &scratch,
        streaming_run_derived_scratch_shrink_min_capacity * 2,
    );
    try std.testing.expectEqual(streaming_run_derived_scratch_shrink_min_capacity * 2, scratch.capacity);

    try resetStreamingRunPublicationScratch(u64, std.testing.allocator, &scratch, 0);
    try std.testing.expectEqual(@as(usize, 0), scratch.capacity);
}

fn virtualAllDocsTopDocLessThanGeneric(lhs: anytype, rhs: @TypeOf(lhs)) bool {
    const lhs_len = lhs.docLen();
    const rhs_len = rhs.docLen();
    if (lhs_len != rhs_len) return lhs_len < rhs_len;
    return lhs.node_id < rhs.node_id;
}

test "streaming run publication ranks virtual all-doc candidates deterministically" {
    const FakeDocRank = struct {
        node_id: u64,
        doc_len: u32,

        fn docLen(self: @This()) u32 {
            return self.doc_len;
        }
    };
    var entries = [_]FakeDocRank{
        .{ .node_id = 40, .doc_len = 7 },
        .{ .node_id = 20, .doc_len = 7 },
        .{ .node_id = 10, .doc_len = 3 },
    };

    const lessThan = struct {
        fn call(_: void, lhs: FakeDocRank, rhs: FakeDocRank) bool {
            return virtualAllDocsTopDocLessThanGeneric(lhs, rhs);
        }
    }.call;
    std.mem.sort(FakeDocRank, &entries, {}, lessThan);

    try std.testing.expectEqual(@as(u64, 10), entries[0].node_id);
    try std.testing.expectEqual(@as(u64, 20), entries[1].node_id);
    try std.testing.expectEqual(@as(u64, 40), entries[2].node_id);
}

fn RegularTermProbeWindow(comptime capacity: usize) type {
    return struct {
        const Self = @This();

        const Probe = struct {
            term_index: u64 = 0,
            postings_count: u64 = 0,
            block_evals: u64 = 0,
            candidate_evals: u64 = 0,
            doc_reads: u64 = 0,
        };

        fn docReadHeavier(lhs: Probe, rhs: Probe) bool {
            if (lhs.doc_reads != rhs.doc_reads) return lhs.doc_reads > rhs.doc_reads;
            if (lhs.candidate_evals != rhs.candidate_evals) return lhs.candidate_evals > rhs.candidate_evals;
            if (lhs.block_evals != rhs.block_evals) return lhs.block_evals > rhs.block_evals;
            if (lhs.postings_count != rhs.postings_count) return lhs.postings_count > rhs.postings_count;
            return lhs.term_index < rhs.term_index;
        }

        fn candidateHeavier(lhs: Probe, rhs: Probe) bool {
            if (lhs.candidate_evals != rhs.candidate_evals) return lhs.candidate_evals > rhs.candidate_evals;
            if (lhs.doc_reads != rhs.doc_reads) return lhs.doc_reads > rhs.doc_reads;
            if (lhs.block_evals != rhs.block_evals) return lhs.block_evals > rhs.block_evals;
            if (lhs.postings_count != rhs.postings_count) return lhs.postings_count > rhs.postings_count;
            return lhs.term_index < rhs.term_index;
        }

        fn insert(
            top: *[capacity]Probe,
            count: *usize,
            probe: Probe,
            comptime heavier: fn (Probe, Probe) bool,
        ) void {
            var insert_at: usize = 0;
            while (insert_at < count.* and !heavier(probe, top[insert_at])) : (insert_at += 1) {}
            if (count.* == capacity and insert_at == capacity) return;

            var target: usize = count.*;
            if (count.* < capacity) {
                count.* += 1;
            } else {
                target = capacity - 1;
            }
            while (target > insert_at) : (target -= 1) {
                top[target] = top[target - 1];
            }
            top[insert_at] = probe;
        }

        fn docReadsSum(probes: []const Probe, limit: usize) !u64 {
            var total: u64 = 0;
            for (probes[0..@min(limit, probes.len)]) |probe| {
                total = std.math.add(u64, total, probe.doc_reads) catch return error.RecordTooLarge;
            }
            return total;
        }

        fn candidateEvalsSum(probes: []const Probe, limit: usize) !u64 {
            var total: u64 = 0;
            for (probes[0..@min(limit, probes.len)]) |probe| {
                total = std.math.add(u64, total, probe.candidate_evals) catch return error.RecordTooLarge;
            }
            return total;
        }
    };
}

test "top-hit regular term probes keep heaviest fixed window" {
    const window = RegularTermProbeWindow(4);
    var by_doc_reads: [4]window.Probe = undefined;
    var by_candidates: [4]window.Probe = undefined;
    var doc_read_count: usize = 0;
    var candidate_count: usize = 0;

    var index: u64 = 0;
    while (index < 7) : (index += 1) {
        const probe = window.Probe{
            .term_index = index,
            .postings_count = 100 + index,
            .block_evals = index + 1,
            .candidate_evals = if (index == 2) 1000 else index * 10,
            .doc_reads = if (index == 1) 900 else index,
        };
        window.insert(&by_doc_reads, &doc_read_count, probe, window.docReadHeavier);
        window.insert(&by_candidates, &candidate_count, probe, window.candidateHeavier);
    }

    try std.testing.expectEqual(@as(usize, 4), doc_read_count);
    try std.testing.expectEqual(@as(usize, 4), candidate_count);
    try std.testing.expectEqual(@as(u64, 1), by_doc_reads[0].term_index);
    try std.testing.expectEqual(@as(u64, 2), by_candidates[0].term_index);
    try std.testing.expectEqual(@as(u64, 900), try window.docReadsSum(&by_doc_reads, 1));
    try std.testing.expectEqual(@as(u64, 1000), try window.candidateEvalsSum(&by_candidates, 1));
    try std.testing.expect((try window.docReadsSum(&by_doc_reads, 4)) > 900);
}

/// Owns the complete external-run catalog publication state machine. The text
/// façade supplies existing persisted-format and run-reader primitives through
/// one compile-time backend; this owner exposes only one phase-shaped entry.
pub fn StreamingRunCatalogPublication(comptime core: type, comptime storage_mod: type, comptime Ops: type) type {
    return struct {
        const catalog_format = catalog_format_mod.CatalogFormat(core);
        const posting_format = posting_format_mod.PostingFormat(Ops.PostingFormatConfig_dep);
        const term_format = term_format_mod.TermFormat(Ops.PostingFormatConfig_dep, Ops.TermFormatConfig_dep);
        const search_acceleration_format = search_acceleration_format_mod.SearchAccelerationFormat(Ops.SearchAccelerationFormatConfig_dep);
        const rebuild_runtime = rebuild_runtime_mod.RebuildRuntime(core);
        const posting_internal = posting_format.Internal;
        const term_internal = term_format.Internal;
        const search_acceleration_internal = search_acceleration_format.Internal;

        const default_max_token_bytes = tokenizer_mod.default_max_token_bytes;
        const bm25WeightedTermScore = scoring_mod.bm25WeightedTermScore;
        const encodeTextPostingsHeader = posting_internal.encodeHeader;
        const compressedPostingFieldTag = posting_internal.compressedFieldTag;
        const compressedPostingTagTextExplicit = posting_internal.compressedTagTextExplicit;
        const encodeTextTermsHeader = term_internal.encodeHeader;
        const encodeTextTermEntry = term_internal.encodeEntry;
        const TextTermSingletonPayloadCheckpoint = term_internal.TextTermSingletonPayloadCheckpoint;
        const encodeTextTermSingletonPayloadCheckpoint = term_internal.encodeSingletonCheckpoint;
        const TextTermExceptionRecord = term_internal.TextTermExceptionRecord;
        const encodeTextTermExceptionRecord = term_internal.encodeExceptionRecord;
        const termEntryHasInlinePosting = term_internal.termEntryHasInlinePosting;
        const encodeVirtualAllDocsPostingPayload = term_internal.encodeVirtualAllDocsPostingPayload;
        const canInlineSingletonPosting = term_internal.canInlineSingletonPosting;
        const encodeInlineSingletonPostingPayload = term_internal.encodeInlineSingletonPostingPayload;
        const decodeInlineSingletonPostingPayload = term_internal.decodeInlineSingletonPostingPayload;
        const encodeZigZagI64 = term_internal.encodeZigZagI64;
        const singletonPayloadDelta = term_internal.singletonPayloadDelta;
        const persistentTermFrontCodedPrefixLen = term_internal.termFrontCodedPrefixLen;
        const textTermsBytesOffset = term_internal.termsBytesOffset;
        const textTermByteOffsetCheckpointCount = term_internal.termByteOffsetCheckpointCount;
        const textTermByteOffsetCheckpointTableBytes = term_internal.termByteOffsetCheckpointTableBytes;
        const textTermByteOffsetCheckpointTableOffset = term_internal.termByteOffsetCheckpointTableOffset;
        const textTermExceptionRankCheckpointCount = term_internal.termExceptionRankCheckpointCount;
        const textTermExceptionRankCheckpointTableBytes = term_internal.termExceptionRankCheckpointTableBytes;
        const textTermExceptionMembershipBytes = term_internal.termExceptionMembershipBytes;
        const textTermExceptionPayloadTableBytes = term_internal.termExceptionPayloadTableBytes;
        const textTermExceptionRankCheckpointTableOffset = term_internal.termExceptionRankCheckpointTableOffset;
        const textTermExceptionMembershipBitsetOffset = term_internal.termExceptionMembershipBitsetOffset;
        const textTermExceptionPayloadTableOffset = term_internal.termExceptionPayloadTableOffset;
        const textTermSingletonPayloadCount = term_internal.termSingletonPayloadCount;
        const textTermSingletonPayloadCheckpointCount = term_internal.termSingletonPayloadCheckpointCount;
        const textTermSingletonPayloadCheckpointTableBytes = term_internal.termSingletonPayloadCheckpointTableBytes;
        const textTermSingletonPayloadCheckpointTableOffset = term_internal.termSingletonPayloadCheckpointTableOffset;
        const textTermSingletonPayloadStreamOffset = term_internal.termSingletonPayloadStreamOffset;
        const textMonotonicNs = rebuild_runtime.Internal.monotonicNs;
        const textElapsedNs = rebuild_runtime.Internal.elapsedNs;
        const tmpPathFor = rebuild_runtime.Internal.tmpPathFor;
        const persistent_posting_block_size = Ops.persistent_posting_block_size_dep;
        const persistent_posting_block_capacity = Ops.persistent_posting_block_capacity_dep;
        const persistent_posting_block_offset_checkpoint_terms = Ops.persistent_posting_block_offset_checkpoint_terms_dep;
        const persistent_posting_block_byte_offset_checkpoint_blocks = Ops.persistent_posting_block_byte_offset_checkpoint_blocks_dep;
        const persistent_term_byte_offset_checkpoint_terms = term_internal.term_byte_offset_checkpoint_terms;
        const persistent_term_bytes_max_offset = term_internal.term_bytes_max_offset;
        const persistent_term_exception_rank_checkpoint_terms = term_internal.term_exception_rank_checkpoint_terms;
        const persistent_term_singleton_payload_checkpoint_terms = term_internal.term_singleton_payload_checkpoint_terms;
        const persistent_posting_block_ordinal_len = search_acceleration_internal.persistent_posting_block_ordinal_len;
        const persistent_term_top_hit_capacity = Ops.persistent_term_top_hit_capacity_dep;
        const persistent_term_top_hit_capacity_usize = Ops.persistent_term_top_hit_capacity_usize_dep;
        const persistent_term_top_hit_regular_probe_capacity = Ops.persistent_term_top_hit_regular_probe_capacity_dep;
        const persistent_all_docs_synthesis_min_postings = Ops.persistent_all_docs_synthesis_min_postings_dep;
        const persistent_dense_all_docs_freq_group_size = Ops.persistent_dense_all_docs_freq_group_size_dep;
        const persistent_dense_all_docs_top_hit_skip_run_max = Ops.persistent_dense_all_docs_top_hit_skip_run_max_dep;
        const persistent_dense_all_docs_freq_mode_packed = Ops.persistent_dense_all_docs_freq_mode_packed_dep;
        const PersistentTextMeta = catalog_format.PersistentTextMeta;
        const TextTermsHeader = term_format.TextTermsHeader;
        const TextTermEntry = term_format.TextTermEntry;
        const TextPostingsHeader = posting_format.TextPostingsHeader;
        const TextPostingRecord = posting_format.TextPostingRecord;
        const TextPostingRunRecord = Ops.TextPostingRunRecord_dep;
        const TextPostingBlocksHeader = search_acceleration_format.TextPostingBlocksHeader;
        const TextPostingBlockRecord = search_acceleration_format.TextPostingBlockRecord;
        const encodeTextPostingBlocksHeader = search_acceleration_internal.encodeBlocksHeader;
        const encodeTextPostingBlockRecord = search_acceleration_internal.encodeBlockRecord;
        const textPostingBlockRecordFromStats = search_acceleration_internal.blockRecordFromStats;
        const quantizePersistentBlockScoreBounds = search_acceleration_internal.quantizeBlockScoreBounds;
        const encodePersistentBlockOrdinal = search_acceleration_internal.encodeBlockOrdinal;
        const TextPostingBlockImpactsHeader = search_acceleration_format.TextPostingBlockImpactsHeader;
        const TextTermTopHitsHeader = search_acceleration_format.TextTermTopHitsHeader;
        const TextTermTopHitTermRecord = search_acceleration_format.TextTermTopHitTermRecord;
        const TextTermTopHitRecord = search_acceleration_format.TextTermTopHitRecord;
        const encodeTextPostingBlockImpactsHeader = search_acceleration_internal.encodeImpactsHeader;
        const encodeTextTermTopHitsHeader = search_acceleration_internal.encodeTopHitsHeader;
        const encodeTextTermTopHitTermRecord = search_acceleration_internal.encodeTopHitTermRecord;
        const encodeTextTermTopHitRecord = search_acceleration_internal.encodeTopHitRecord;
        const TextTopHitDocStats = Ops.TextTopHitDocStats_dep;
        const TextDocRankEntry = Ops.TextDocRankEntry_dep;
        const TextDocsFileView = Ops.TextDocsFileView_dep;
        const TextPostingBlockStats = Ops.TextPostingBlockStats_dep;
        const addPostingToBlockStats = Ops.addPostingToBlockStats_dep;
        const PersistentTextCatalogStats = Ops.PersistentTextCatalogStats_dep;
        const PersistentTextRebuildTimings = rebuild_runtime.PersistentTextRebuildTimings;
        const textBenchTraceEnabled = Ops.textBenchTraceEnabled_dep;
        const textBenchTrace = Ops.textBenchTrace_dep;
        const textBenchTraceSummaryStats = Ops.textBenchTraceSummaryStats_dep;
        const compressed_posting_max_encoded_len = Ops.compressed_posting_max_encoded_len_dep;
        const validateDenseAllDocsTextFreq = Ops.validateDenseAllDocsTextFreq_dep;
        const encodePersistentVarint = Ops.encodePersistentVarint_dep;
        const encodeCompressedTextPosting = Ops.encodeCompressedTextPosting_dep;
        const textTermTopHitLessThan = Ops.textTermTopHitLessThan_dep;
        const findWorstTextTermTopHitIndex = Ops.findWorstTextTermTopHitIndex_dep;
        const appendTopTextTermHitBoundedInline = Ops.appendTopTextTermHitBoundedInline_dep;
        const persistentMinPossibleDocLen = Ops.persistentMinPossibleDocLen_dep;
        const textTermTopHitCandidateCannotBeatCurrentWorstWithDocLenFloor = Ops.textTermTopHitCandidateCannotBeatCurrentWorstWithDocLenFloor_dep;
        const textTermsPath = Ops.textTermsPath_dep;
        const textPostingsPath = Ops.textPostingsPath_dep;
        const textPostingBlocksPath = Ops.textPostingBlocksPath_dep;
        const textPostingBlockImpactsPath = Ops.textPostingBlockImpactsPath_dep;
        const textTermTopHitsPath = Ops.textTermTopHitsPath_dep;
        const renameReplace = Ops.renameReplace_dep;
        const textOptionsNeedSync = Ops.textOptionsNeedSync_dep;
        const TextBufferedWriter = Ops.TextBufferedWriter_dep;
        const textWriteBufferCapacity = Ops.textWriteBufferCapacity_dep;
        const TextPostingRunReader = Ops.TextPostingRunReader_dep;
        const TextPostingRunSummaryFile = Ops.TextPostingRunSummaryFile_dep;
        const VariableAllDocsFreqSlice = Ops.VariableAllDocsFreqSlice_dep;
        const TextPostingSyntheticRunSource = Ops.TextPostingSyntheticRunSource_dep;
        const TextPostingRunMerger = Ops.TextPostingRunMerger_dep;
        const TextPostingRunTermSummaryRecord = Ops.TextPostingRunTermSummaryRecord_dep;
        const textPostingRunSummaryRegularConstantTopHitCandidate = Ops.textPostingRunSummaryRegularConstantTopHitCandidate_dep;
        const TextPostingRunSummaryStats = Ops.TextPostingRunSummaryStats_dep;
        const TextPostingRunMergedSummaryReader = Ops.TextPostingRunMergedSummaryReader_dep;
        const collectTextPostingRunTermSummaryStatsFromFiles = Ops.collectTextPostingRunTermSummaryStatsFromFiles_dep;
        const writeEmptyTermsAndPostingsFiles = Ops.writeEmptyTermsAndPostingsFiles_dep;
        const appendDenseAllDocsFreqGroup = Ops.appendDenseAllDocsFreqGroup_dep;
        const appendDenseAllDocsFreqStreamFreqs = Ops.appendDenseAllDocsFreqStreamFreqs_dep;
        const MemoryPostingBlockImpact = Ops.MemoryPostingBlockImpact_dep;
        const memoryPostingBlockImpactLessThan = Ops.memoryPostingBlockImpactLessThan_dep;
        const persistentTermTopHitCountForPostingCount = Ops.persistentTermTopHitCountForPostingCount_dep;
        const textPostingsFileSize = Ops.textPostingsFileSize_dep;
        const textPostingBlockCheckpointCount = Ops.textPostingBlockCheckpointCount_dep;
        const textPostingBlockCheckpointTableOffset = Ops.textPostingBlockCheckpointTableOffset_dep;
        const textPostingBlockByteOffsetCheckpointCount = Ops.textPostingBlockByteOffsetCheckpointCount_dep;
        const textPostingBlockByteOffsetCheckpointTableOffset = Ops.textPostingBlockByteOffsetCheckpointTableOffset_dep;
        const textPostingBlockRecordOffset = Ops.textPostingBlockRecordOffset_dep;
        const textPostingBlocksFileSize = Ops.textPostingBlocksFileSize_dep;
        const textPostingBlockImpactRecordOffset = Ops.textPostingBlockImpactRecordOffset_dep;
        const textPostingBlockImpactsFileSize = Ops.textPostingBlockImpactsFileSize_dep;
        const textTermTopHitTermIndexOffset = Ops.textTermTopHitTermIndexOffset_dep;
        const textTermTopHitRecordOffset = Ops.textTermTopHitRecordOffset_dep;
        const textTermTopHitsFileSize = Ops.textTermTopHitsFileSize_dep;
        const regularFileSize = Ops.regularFileSize_dep;
        const persistentWeightedTf = Ops.persistentWeightedTf_dep;
        const persistentAvgDocLen = Ops.persistentAvgDocLen_dep;
        const appendPersistentFrontCodedTerm = Ops.appendPersistentFrontCodedTerm_dep;

        pub fn write(
            allocator: std.mem.Allocator,
            store: storage_mod.Store,
            run_paths: []const []const u8,
            summary_files: []const TextPostingRunSummaryFile,
            synthetic_sources: []const TextPostingSyntheticRunSource,
            run_paths_disjoint_term_ranges: bool,
            docs_view: *TextDocsFileView,
            meta: PersistentTextMeta,
            deadline: core.QueryDeadline,
            timings: ?*PersistentTextRebuildTimings,
        ) !PersistentTextCatalogStats {
            const summary_start = textMonotonicNs(store.io);
            if ((run_paths.len == 0 and synthetic_sources.len == 0) or summary_files.len == 0) {
                return try writeEmptyTermsAndPostingsFiles(allocator, store, docs_view, meta);
            }
            textBenchTrace("catalog_summary_stats_start");
            const summary_stats = collectTextPostingRunTermSummaryStatsFromFiles(allocator, store.io, summary_files, meta.doc_count, deadline) catch |err| {
                textBenchTrace("catalog_summary_stats_error");
                return err;
            };
            textBenchTraceSummaryStats("catalog_summary_stats_done", summary_stats);
            if (timings) |t| t.run_summary_ns = textElapsedNs(store.io, summary_start);
            if (timings) |t| {
                t.run_term_count = summary_stats.term_count;
                t.run_block_count = summary_stats.block_count;
                t.run_top_hit_term_count = summary_stats.top_hit_term_count;
                t.run_top_hit_candidate_records = summary_stats.top_hit_candidate_postings;
                t.run_top_hit_side_stream_candidate_records = summary_stats.top_hit_side_stream_candidates;
                t.run_top_hit_local_side_stream_candidate_records = summary_stats.top_hit_local_side_stream_candidates;
                t.run_virtual_all_docs_term_count = summary_stats.virtual_all_docs_term_count;
                t.run_virtual_all_docs_candidate_records = summary_stats.virtual_all_docs_candidate_records;
                t.run_dense_all_docs_freq_stream_term_count = summary_stats.dense_all_docs_freq_stream_term_count;
                t.run_dense_all_docs_freq_stream_candidate_records = summary_stats.dense_all_docs_freq_stream_candidate_records;
            }
            if (deadline.expired()) return core.Error.BudgetExceeded;

            const derived_start = textMonotonicNs(store.io);
            textBenchTrace("catalog_derived_files_start");
            writeTextRunCatalogFilesFromRuns(
                allocator,
                store,
                run_paths,
                summary_files,
                synthetic_sources,
                run_paths_disjoint_term_ranges,
                summary_stats,
                docs_view,
                meta,
                deadline,
                timings,
            ) catch |err| {
                textBenchTraceSummaryStats("catalog_derived_files_error", summary_stats);
                return err;
            };
            textBenchTrace("catalog_derived_files_done");
            if (timings) |t| t.run_derived_ns = textElapsedNs(store.io, derived_start);
            if (deadline.expired()) return core.Error.BudgetExceeded;

            return .{
                .term_count = summary_stats.term_count,
                .term_bytes = summary_stats.term_bytes_len,
                .posting_count = summary_stats.posting_count,
            };
        }

        const DenseAllDocsTopHitCache = struct {
            term: []const u8,
            freqs: VariableAllDocsFreqSlice,
            freq_top_doc_buckets: []DenseAllDocsFreqTopDocBucket = &.{},
            hits: [persistent_term_top_hit_capacity_usize]TextTermTopHitRecord = undefined,
            hit_count: usize = 0,
            worst_index: ?usize = null,
            upper_bound_skip_text_freq: u32 = 0,
            skip_until_doc_index: u64 = 0,
        };

        const dense_all_docs_top_hit_bucket_max_freq: u32 = 512;
        const dense_all_docs_top_hit_bucket_min_events: u64 = if (builtin.is_test)
            persistent_all_docs_synthesis_min_postings * 2
        else
            32_000_000;

        const DenseAllDocsFreqTopDocBucket = struct {
            docs: [persistent_term_top_hit_capacity_usize]TextTopHitDocStats = undefined,
            count: usize = 0,
            worst_index: ?usize = null,
        };

        fn denseAllDocsTopHitDocLessThan(lhs: TextTopHitDocStats, rhs: TextTopHitDocStats) bool {
            if (lhs.doc_len != rhs.doc_len) return lhs.doc_len < rhs.doc_len;
            return lhs.node_id < rhs.node_id;
        }

        fn findWorstDenseAllDocsTopHitDocIndex(docs: []const TextTopHitDocStats) usize {
            var worst_index: usize = 0;
            for (docs[1..], 1..) |candidate, i| {
                if (denseAllDocsTopHitDocLessThan(docs[worst_index], candidate)) worst_index = i;
            }
            return worst_index;
        }

        fn insertDenseAllDocsFreqTopDoc(
            bucket: *DenseAllDocsFreqTopDocBucket,
            limit: usize,
            doc: TextTopHitDocStats,
        ) !void {
            if (limit == 0 or limit > persistent_term_top_hit_capacity_usize) return error.RecordTooLarge;
            if (bucket.count < limit) {
                bucket.docs[bucket.count] = doc;
                bucket.count += 1;
                if (bucket.count == limit) bucket.worst_index = findWorstDenseAllDocsTopHitDocIndex(bucket.docs[0..bucket.count]);
                return;
            }
            const slot = bucket.worst_index orelse findWorstDenseAllDocsTopHitDocIndex(bucket.docs[0..bucket.count]);
            if (denseAllDocsTopHitDocLessThan(doc, bucket.docs[slot])) {
                bucket.docs[slot] = doc;
                bucket.worst_index = findWorstDenseAllDocsTopHitDocIndex(bucket.docs[0..bucket.count]);
            } else {
                bucket.worst_index = slot;
            }
        }

        const StreamingRunDerivedFilesContext = struct {
            allocator: std.mem.Allocator,
            io: std.Io,
            postings_writer: *TextBufferedWriter,
            blocks_offsets_writer: *TextBufferedWriter,
            blocks_byte_offsets_writer: *TextBufferedWriter,
            blocks_writer: *TextBufferedWriter,
            impacts_writer: *TextBufferedWriter,
            top_hits_index_writer: *TextBufferedWriter,
            top_hits_writer: *TextBufferedWriter,
            terms_entry_writer: *TextBufferedWriter,
            terms_bytes_writer: *TextBufferedWriter,
            terms_checkpoints_writer: *TextBufferedWriter,
            terms_exception_rank_writer: *TextBufferedWriter,
            terms_exception_membership_writer: *TextBufferedWriter,
            terms_exception_payload_writer: *TextBufferedWriter,
            terms_singleton_checkpoints_writer: *TextBufferedWriter,
            terms_singleton_payload_writer: *TextBufferedWriter,
            summary_reader: *TextPostingRunMergedSummaryReader,
            summary_count: u64,
            current_summary: TextPostingRunTermSummaryRecord = undefined,
            docs_view: *TextDocsFileView,
            meta: PersistentTextMeta,
            avg_doc_len: f32,
            block_size: u64,
            summary_index: u64 = 0,
            current_term: [default_max_token_bytes]u8 = [_]u8{0} ** default_max_token_bytes,
            current_term_len: usize = 0,
            current_term_front_prefix_len: u8 = 0,
            have_term: bool = false,
            previous_written_term: [default_max_token_bytes]u8 = [_]u8{0} ** default_max_token_bytes,
            previous_written_term_len: usize = 0,
            have_previous_written_term: bool = false,
            previous_doc_id: u64 = 0,
            term_postings_seen: u64 = 0,
            current_block_postings: u64 = 0,
            current_block: TextPostingBlockStats = undefined,
            current_block_previous_doc_id: u64 = 0,
            current_block_top_hit_postings: [persistent_posting_block_capacity]TextPostingRecord = undefined,
            current_block_top_hit_count: usize = 0,
            inline_singleton_posting: ?TextPostingRecord = null,
            virtual_all_docs_text_freq: u32 = 0,
            dense_all_docs_freq_stream: bool = false,
            dense_freq_tags: [persistent_dense_all_docs_freq_group_size]u8 = undefined,
            dense_freq_tag_count: usize = 0,
            dense_freq_explicit: [persistent_dense_all_docs_freq_group_size * 10]u8 = undefined,
            dense_freq_explicit_len: usize = 0,
            dense_freq_buffering: bool = false,
            dense_freq_stream_written_directly: bool = false,
            collect_derived_shape_probes: bool = false,
            derived_current_term_shape_counted: bool = false,
            dense_freqs: std.ArrayList(u16) = .empty,
            postings_written: u64 = 0,
            postings_body_bytes_written: u64 = 0,
            current_term_postings_offset: u64 = 0,
            blocks_written: u64 = 0,
            block_index_base: u64 = 0,
            local_block_index: u64 = 0,
            impacts: std.ArrayList(MemoryPostingBlockImpact) = .empty,
            impacts_written: u64 = 0,
            hits: [persistent_term_top_hit_capacity_usize]TextTermTopHitRecord = undefined,
            hit_count: usize = 0,
            worst_hit_index: ?usize = null,
            global_doc_rank: std.ArrayList(TextDocRankEntry) = .empty,
            global_doc_rank_ready: bool = false,
            constant_top_hit_doc_bits: std.DynamicBitSetUnmanaged = .{},
            virtual_all_docs_top_docs: [persistent_term_top_hit_capacity_usize]TextDocRankEntry = undefined,
            virtual_all_docs_top_doc_count: usize = 0,
            virtual_all_docs_top_docs_ready: bool = false,
            virtual_all_docs_top_hit_cache_doc_scans: u64 = 0,
            global_min_doc_len: f32 = std.math.inf(f32),
            global_min_doc_len_ready: bool = false,
            dense_all_docs_top_hit_caches: []DenseAllDocsTopHitCache = &.{},
            hits_written: u64 = 0,
            hit_terms_written: u64 = 0,
            term_entries_written: u64 = 0,
            term_exceptions_written: u64 = 0,
            term_exception_rank_checkpoints_written: u64 = 0,
            term_exception_membership_bytes_written: u64 = 0,
            current_exception_membership_byte: u8 = 0,
            current_exception_membership_bits: u8 = 0,
            term_singletons_written: u64 = 0,
            term_singleton_payload_bytes_written: u64 = 0,
            term_singleton_checkpoints_written: u64 = 0,
            previous_singleton_payload: u32 = 0,
            term_bytes_written: u64 = 0,
            term_byte_checkpoints_written: u64 = 0,
            block_offset_checkpoints_written: u64 = 0,
            block_byte_offset_checkpoints_written: u64 = 0,
            derived_inline_singleton_terms: u64 = 0,
            derived_virtual_terms: u64 = 0,
            derived_dense_terms: u64 = 0,
            derived_block_terms: u64 = 0,
            derived_inline_singleton_records: u64 = 0,
            derived_virtual_records: u64 = 0,
            derived_dense_records: u64 = 0,
            derived_block_records: u64 = 0,
            top_hit_block_evals: u64 = 0,
            top_hit_block_skips: u64 = 0,
            top_hit_block_not_full_evals: u64 = 0,
            top_hit_block_ready_evals: u64 = 0,
            top_hit_block_upper_lt_2x_worst: u64 = 0,
            top_hit_block_upper_lt_4x_worst: u64 = 0,
            top_hit_block_upper_gte_4x_worst: u64 = 0,
            top_hit_candidate_evals: u64 = 0,
            top_hit_doc_reads: u64 = 0,
            top_hit_regular_candidate_evals: u64 = 0,
            top_hit_regular_doc_reads: u64 = 0,
            top_hit_virtual_candidate_evals: u64 = 0,
            top_hit_virtual_doc_reads: u64 = 0,
            top_hit_dense_candidate_evals: u64 = 0,
            top_hit_dense_doc_reads: u64 = 0,
            top_hit_dense_scan_records: u64 = 0,
            top_hit_dense_freq_bound_skips: u64 = 0,
            top_hit_dense_freq_bound_skip_runs: u64 = 0,
            current_top_hit_regular_block_evals: u64 = 0,
            current_top_hit_regular_candidate_evals: u64 = 0,
            current_top_hit_regular_doc_reads: u64 = 0,
            current_top_hit_regular_constant_candidate: bool = false,
            current_top_hit_regular_constant_resolved: bool = false,
            current_top_hit_regular_constant_rank_doc_count: u64 = 0,
            top_hit_regular_term_count: u64 = 0,
            top_hit_regular_doc_read_term_count: u64 = 0,
            top_hit_regular_doc_read_heavy_terms: [persistent_term_top_hit_regular_probe_capacity]TextTopHitRegularTermProbe = undefined,
            top_hit_regular_doc_read_heavy_term_count: usize = 0,
            top_hit_regular_candidate_heavy_terms: [persistent_term_top_hit_regular_probe_capacity]TextTopHitRegularTermProbe = undefined,
            top_hit_regular_candidate_heavy_term_count: usize = 0,
            top_hit_regular_constant_terms: u64 = 0,
            top_hit_regular_constant_resolved_terms: u64 = 0,
            top_hit_regular_constant_unresolved_terms: u64 = 0,
            top_hit_regular_constant_candidate_evals: u64 = 0,
            top_hit_regular_constant_doc_reads: u64 = 0,
            top_hit_regular_nonconstant_candidate_evals: u64 = 0,
            top_hit_regular_nonconstant_doc_reads: u64 = 0,
            top_hit_regular_constant_resolved_candidate_skips: u64 = 0,
            derived_next_sampled_ns: u128 = 0,
            derived_next_reader_sampled_ns: u128 = 0,
            derived_next_queue_sampled_ns: u128 = 0,
            derived_next_child_probe_count: u64 = 0,
            derived_next_queue_compare_count: u64 = 0,
            derived_inline_singleton_next_sampled_ns: u128 = 0,
            derived_inline_singleton_publish_sampled_ns: u128 = 0,
            derived_next_probe_count: u64 = 0,
            derived_encode_sampled_ns: u128 = 0,
            derived_write_sampled_ns: u128 = 0,
            derived_block_stats_sampled_ns: u128 = 0,
            derived_top_hit_sampled_ns: u128 = 0,
            derived_block_flush_sampled_ns: u128 = 0,
            derived_global_doc_rank_ns: u128 = 0,
            derived_virtual_top_docs_ns: u128 = 0,

            fn deinit(self: *StreamingRunDerivedFilesContext) void {
                self.impacts.deinit(self.allocator);
                self.dense_freqs.deinit(self.allocator);
                self.global_doc_rank.deinit(self.allocator);
                self.constant_top_hit_doc_bits.deinit(self.allocator);
                for (self.dense_all_docs_top_hit_caches) |*cache| {
                    self.allocator.free(cache.freq_top_doc_buckets);
                }
                self.allocator.free(self.dense_all_docs_top_hit_caches);
            }
        };

        fn textBenchTraceDerivedContext(comptime label: []const u8, context: *const StreamingRunDerivedFilesContext) void {
            if (!textBenchTraceEnabled()) return;
            const term = if (context.have_term) context.current_term[0..context.current_term_len] else "";
            const summary_postings = if (context.have_term) context.current_summary.postings_count else 0;
            const summary_blocks = if (context.have_term) context.current_summary.block_count else 0;
            const summary_top_hits = if (context.have_term) context.current_summary.top_hit_count else 0;
            std.debug.print(
                "text_trace={s} summary_index={} summary_count={} term=\"{s}\" term_postings_seen={} summary_postings={} summary_blocks={} summary_top_hits={} previous_doc_id={} current_block_postings={} local_block_index={} virtual_freq={} dense={} inline={} postings_written={} blocks_written={} term_entries={}\n",
                .{
                    label,
                    context.summary_index,
                    context.summary_count,
                    term,
                    context.term_postings_seen,
                    summary_postings,
                    summary_blocks,
                    summary_top_hits,
                    context.previous_doc_id,
                    context.current_block_postings,
                    context.local_block_index,
                    context.virtual_all_docs_text_freq,
                    context.dense_all_docs_freq_stream,
                    context.inline_singleton_posting != null,
                    context.postings_written,
                    context.blocks_written,
                    context.term_entries_written,
                },
            );
        }

        fn textBenchTraceDerivedRecord(comptime label: []const u8, context: *const StreamingRunDerivedFilesContext, record: TextPostingRunRecord) void {
            if (!textBenchTraceEnabled()) return;
            std.debug.print(
                "text_trace={s} record_term=\"{s}\" doc_id={} text_freq={} kind_freq={}\n",
                .{ label, record.term(), record.doc_id, record.text_freq, record.kind_freq },
            );
            textBenchTraceDerivedContext("derived_record_context", context);
        }

        const streaming_run_derived_record_probe_stride: u64 = 65536;
        const streaming_run_derived_block_probe_stride: u64 = 64;
        const streaming_run_derived_next_child_probe_stride: u64 = 1048576;
        const streaming_run_derived_next_child_probe_offset: u64 = streaming_run_derived_record_probe_stride / 2;

        fn streamingRunDerivedSampleStart(
            context: *const StreamingRunDerivedFilesContext,
            ordinal: u64,
            comptime stride: u64,
        ) u128 {
            comptime std.debug.assert(std.math.isPowerOfTwo(stride));
            if (!context.collect_derived_shape_probes) return 0;
            return if ((ordinal & (stride - 1)) == 0) textMonotonicNs(context.io) else 0;
        }

        fn addStreamingRunDerivedSampleNs(
            context: *const StreamingRunDerivedFilesContext,
            counter: *u128,
            start_ns: u128,
            comptime stride: u64,
        ) void {
            if (start_ns == 0) return;
            counter.* += streamingRunDerivedSampleElapsedNs(context, start_ns, stride);
        }

        fn streamingRunDerivedSampleElapsedNs(
            context: *const StreamingRunDerivedFilesContext,
            start_ns: u128,
            comptime stride: u64,
        ) u128 {
            if (start_ns == 0) return 0;
            return textElapsedNs(context.io, start_ns) * stride;
        }

        fn streamingRunDerivedNextProbeOrdinal(context: *StreamingRunDerivedFilesContext) u64 {
            defer context.derived_next_probe_count += 1;
            return context.derived_next_probe_count;
        }

        fn streamingRunDerivedNextSampleStart(context: *const StreamingRunDerivedFilesContext, ordinal: u64) u128 {
            return streamingRunDerivedSampleStart(context, ordinal, streaming_run_derived_record_probe_stride);
        }

        fn streamingRunDerivedNextChildProbeActive(context: *const StreamingRunDerivedFilesContext, ordinal: u64) bool {
            comptime std.debug.assert(std.math.isPowerOfTwo(streaming_run_derived_next_child_probe_stride));
            comptime std.debug.assert(streaming_run_derived_next_child_probe_offset < streaming_run_derived_next_child_probe_stride);
            if (!context.collect_derived_shape_probes) return false;
            return (ordinal & (streaming_run_derived_next_child_probe_stride - 1)) == streaming_run_derived_next_child_probe_offset;
        }

        fn addStreamingRunDerivedNextProbeNs(
            context: *StreamingRunDerivedFilesContext,
            active: bool,
            probe: TextPostingRunMerger.NextProbe,
        ) void {
            if (!active) return;
            context.derived_next_child_probe_count += 1;
            context.derived_next_queue_compare_count += probe.queue_compare_count;
            context.derived_next_reader_sampled_ns += probe.reader_ns * streaming_run_derived_next_child_probe_stride;
            context.derived_next_queue_sampled_ns += probe.queue_ns * streaming_run_derived_next_child_probe_stride;
        }

        fn streamingRunDerivedPostingSampleStart(context: *const StreamingRunDerivedFilesContext) u128 {
            return streamingRunDerivedSampleStart(context, context.postings_written, streaming_run_derived_record_probe_stride);
        }

        fn streamingRunDerivedTermMatches(context: *const StreamingRunDerivedFilesContext, term: []const u8) bool {
            return context.have_term and context.current_term_len == term.len and std.mem.eql(u8, context.current_term[0..context.current_term_len], term);
        }

        fn addStreamingRunDerivedProbe(collect: bool, counter: *u64, value: u64) !void {
            if (!collect) return;
            counter.* = std.math.add(u64, counter.*, value) catch return error.RecordTooLarge;
        }

        const regular_term_probe_window = RegularTermProbeWindow(persistent_term_top_hit_regular_probe_capacity);
        const TextTopHitRegularTermProbe = regular_term_probe_window.Probe;
        const topHitRegularTermProbeDocReadHeavier = regular_term_probe_window.docReadHeavier;
        const topHitRegularTermProbeCandidateHeavier = regular_term_probe_window.candidateHeavier;
        const insertTextTopHitRegularTermProbe = regular_term_probe_window.insert;
        const textTopHitRegularProbeDocReadsSum = regular_term_probe_window.docReadsSum;
        const textTopHitRegularProbeCandidateEvalsSum = regular_term_probe_window.candidateEvalsSum;

        fn resetStreamingRunDerivedImpactsScratch(context: *StreamingRunDerivedFilesContext, required_capacity: usize) !void {
            try resetStreamingRunPublicationScratch(
                MemoryPostingBlockImpact,
                context.allocator,
                &context.impacts,
                required_capacity,
            );
        }

        fn resetStreamingRunDerivedTermScratch(context: *StreamingRunDerivedFilesContext, summary: TextPostingRunTermSummaryRecord) !void {
            context.current_block_postings = 0;
            context.local_block_index = 0;
            context.hit_count = 0;
            context.worst_hit_index = null;
            context.current_top_hit_regular_block_evals = 0;
            context.current_top_hit_regular_candidate_evals = 0;
            context.current_top_hit_regular_doc_reads = 0;
            context.current_top_hit_regular_constant_candidate = false;
            context.current_top_hit_regular_constant_resolved = false;
            context.current_top_hit_regular_constant_rank_doc_count = 0;
            context.dense_freq_tag_count = 0;
            context.dense_freq_explicit_len = 0;
            context.dense_freq_buffering = false;
            context.dense_freq_stream_written_directly = false;
            context.derived_current_term_shape_counted = false;
            context.dense_freqs.clearRetainingCapacity();
            try resetStreamingRunDerivedImpactsScratch(context, std.math.cast(usize, summary.block_count) orelse return error.RecordTooLarge);
            if (summary.top_hit_count > persistent_term_top_hit_capacity) return error.RecordTooLarge;
        }

        fn startStreamingRunDerivedTerm(context: *StreamingRunDerivedFilesContext, term: []const u8) !void {
            if (context.summary_index >= context.summary_count) return error.InvalidRecord;
            const summary = (try context.summary_reader.nextRecord()) orelse return error.InvalidRecord;
            if (!std.mem.eql(u8, summary.term(), term)) return error.InvalidRecord;
            if (summary.postings_count > std.math.maxInt(u32)) return error.RecordTooLarge;
            context.current_summary = summary;
            context.summary_index += 1;

            const term_index = context.summary_index - 1;
            if (term_index % persistent_posting_block_offset_checkpoint_terms == 0) {
                var offset_bytes: [persistent_posting_block_ordinal_len]u8 = undefined;
                try encodePersistentBlockOrdinal(context.block_index_base, &offset_bytes);
                try context.blocks_offsets_writer.append(&offset_bytes);
                context.block_offset_checkpoints_written = std.math.add(u64, context.block_offset_checkpoints_written, 1) catch return error.RecordTooLarge;
            }
            if (term_index % persistent_term_byte_offset_checkpoint_terms == 0) {
                if (context.term_bytes_written > persistent_term_bytes_max_offset) return error.RecordTooLarge;
                var offset_bytes: [4]u8 = undefined;
                std.mem.writeInt(u32, &offset_bytes, @intCast(context.term_bytes_written), .little);
                try context.terms_checkpoints_writer.append(&offset_bytes);
                context.term_byte_checkpoints_written = std.math.add(u64, context.term_byte_checkpoints_written, 1) catch return error.RecordTooLarge;
            }

            const previous_term: ?[]const u8 = if (context.have_previous_written_term)
                context.previous_written_term[0..context.previous_written_term_len]
            else
                null;
            const front_prefix_len = try persistentTermFrontCodedPrefixLen(term_index, previous_term, term);
            const encoded_term_len = try appendPersistentFrontCodedTerm(context.terms_bytes_writer, term_index, previous_term, term);
            context.term_bytes_written = std.math.add(u64, context.term_bytes_written, encoded_term_len) catch return error.RecordTooLarge;
            @memcpy(context.previous_written_term[0..term.len], term);
            context.previous_written_term_len = term.len;
            context.have_previous_written_term = true;

            @memcpy(context.current_term[0..term.len], term);
            context.current_term_len = term.len;
            context.current_term_front_prefix_len = front_prefix_len;
            context.have_term = true;
            context.previous_doc_id = 0;
            context.term_postings_seen = 0;
            context.current_term_postings_offset = context.postings_body_bytes_written;
            try resetStreamingRunDerivedTermScratch(context, summary);
            context.inline_singleton_posting = null;
            context.virtual_all_docs_text_freq = summary.virtualAllDocsTextFreq(context.meta.doc_count) orelse 0;
            context.dense_all_docs_freq_stream = context.virtual_all_docs_text_freq == 0 and summary.denseAllDocsFreqStream(context.meta.doc_count);
            if (context.virtual_all_docs_text_freq != 0) {
                try addStreamingRunDerivedProbe(context.collect_derived_shape_probes, &context.derived_virtual_terms, 1);
                context.derived_current_term_shape_counted = true;
            } else if (context.dense_all_docs_freq_stream) {
                try addStreamingRunDerivedProbe(context.collect_derived_shape_probes, &context.derived_dense_terms, 1);
                context.derived_current_term_shape_counted = true;
            }
            context.current_top_hit_regular_constant_candidate = textPostingRunSummaryRegularConstantTopHitCandidate(summary, context.meta.doc_count);
            if (context.current_top_hit_regular_constant_candidate) {
                const doc_count = std.math.cast(usize, context.meta.doc_count) orelse return error.RecordTooLarge;
                if (context.constant_top_hit_doc_bits.capacity() != doc_count) {
                    try context.constant_top_hit_doc_bits.resize(context.allocator, doc_count, false);
                } else {
                    context.constant_top_hit_doc_bits.unsetAll();
                }
                try addStreamingRunDerivedProbe(context.collect_derived_shape_probes, &context.top_hit_regular_constant_terms, 1);
            }
            context.dense_freq_buffering = context.dense_all_docs_freq_stream;
            if (context.dense_freq_buffering) {
                context.dense_freqs.clearRetainingCapacity();
            }
        }

        fn initStreamingRunDerivedBlock(context: *StreamingRunDerivedFilesContext) void {
            context.current_block = .{
                .posting_offset = context.postings_body_bytes_written,
                .posting_count = 0,
                .first_doc_id = 0,
                .last_doc_id = 0,
                .max_weighted_tf = 0,
                .min_doc_len = std.math.inf(f32),
            };
            context.current_block_previous_doc_id = 0;
            context.current_block_top_hit_count = 0;
        }

        fn streamingRunDerivedDocLenLowerBound(context: *const StreamingRunDerivedFilesContext) f32 {
            return if (context.global_min_doc_len_ready) context.global_min_doc_len else persistentMinPossibleDocLen();
        }

        fn markStreamingRunDerivedConstantRankDoc(context: *StreamingRunDerivedFilesContext, doc_id: u64) !void {
            if (!context.current_top_hit_regular_constant_candidate or context.current_top_hit_regular_constant_resolved) return;
            if (doc_id == 0 or doc_id > context.meta.doc_count) return error.InvalidRecord;
            const index = std.math.cast(usize, doc_id - 1) orelse return error.RecordTooLarge;
            context.constant_top_hit_doc_bits.set(index);
            context.current_top_hit_regular_constant_rank_doc_count = std.math.add(u64, context.current_top_hit_regular_constant_rank_doc_count, 1) catch return error.RecordTooLarge;
        }

        fn scoreStreamingRunDerivedTopHitBlock(context: *StreamingRunDerivedFilesContext, block_upper_score: f32) !void {
            const summary = context.current_summary;
            if (summary.top_hit_count == 0) {
                if (context.current_block_top_hit_count != 0) return error.InvalidRecord;
                return;
            }
            if (context.current_top_hit_regular_constant_resolved) {
                if (context.current_block_top_hit_count != 0) return error.InvalidRecord;
                return;
            }
            try addStreamingRunDerivedProbe(context.collect_derived_shape_probes, &context.top_hit_block_evals, 1);
            try addStreamingRunDerivedProbe(context.collect_derived_shape_probes, &context.current_top_hit_regular_block_evals, 1);
            const block_postings = std.math.cast(usize, context.current_block_postings) orelse return error.RecordTooLarge;
            if (context.current_block_top_hit_count != block_postings) return error.InvalidRecord;
            const hit_limit = std.math.cast(usize, summary.top_hit_count) orelse return error.RecordTooLarge;
            if (context.hit_count < hit_limit) {
                try addStreamingRunDerivedProbe(context.collect_derived_shape_probes, &context.top_hit_block_not_full_evals, 1);
            } else {
                try addStreamingRunDerivedProbe(context.collect_derived_shape_probes, &context.top_hit_block_ready_evals, 1);
                const worst_index = context.worst_hit_index orelse findWorstTextTermTopHitIndex(context.hits[0..context.hit_count]);
                const worst_score = context.hits[worst_index].score;
                if (!std.math.isFinite(worst_score) or worst_score < 0) return core.Error.Unsupported;
                if (block_upper_score < worst_score) {
                    try addStreamingRunDerivedProbe(context.collect_derived_shape_probes, &context.top_hit_block_skips, 1);
                    return;
                }
                if (block_upper_score < worst_score * 2.0) {
                    try addStreamingRunDerivedProbe(context.collect_derived_shape_probes, &context.top_hit_block_upper_lt_2x_worst, 1);
                } else if (block_upper_score < worst_score * 4.0) {
                    try addStreamingRunDerivedProbe(context.collect_derived_shape_probes, &context.top_hit_block_upper_lt_4x_worst, 1);
                } else {
                    try addStreamingRunDerivedProbe(context.collect_derived_shape_probes, &context.top_hit_block_upper_gte_4x_worst, 1);
                }
            }
            for (context.current_block_top_hit_postings[0..context.current_block_top_hit_count]) |posting| {
                try addStreamingRunDerivedProbe(context.collect_derived_shape_probes, &context.top_hit_candidate_evals, 1);
                try addStreamingRunDerivedProbe(context.collect_derived_shape_probes, &context.top_hit_regular_candidate_evals, 1);
                try addStreamingRunDerivedProbe(context.collect_derived_shape_probes, &context.current_top_hit_regular_candidate_evals, 1);
                if (context.current_top_hit_regular_constant_candidate) {
                    try addStreamingRunDerivedProbe(context.collect_derived_shape_probes, &context.top_hit_regular_constant_candidate_evals, 1);
                } else {
                    try addStreamingRunDerivedProbe(context.collect_derived_shape_probes, &context.top_hit_regular_nonconstant_candidate_evals, 1);
                }
                if (try textTermTopHitCandidateCannotBeatCurrentWorstWithDocLenFloor(
                    context.hits[0..context.hit_count],
                    context.worst_hit_index,
                    @intCast(summary.top_hit_count),
                    posting,
                    context.avg_doc_len,
                    context.meta.doc_count,
                    summary.postings_count,
                    streamingRunDerivedDocLenLowerBound(context),
                )) continue;
                try addStreamingRunDerivedProbe(context.collect_derived_shape_probes, &context.top_hit_doc_reads, 1);
                try addStreamingRunDerivedProbe(context.collect_derived_shape_probes, &context.top_hit_regular_doc_reads, 1);
                try addStreamingRunDerivedProbe(context.collect_derived_shape_probes, &context.current_top_hit_regular_doc_reads, 1);
                if (context.current_top_hit_regular_constant_candidate) {
                    try addStreamingRunDerivedProbe(context.collect_derived_shape_probes, &context.top_hit_regular_constant_doc_reads, 1);
                } else {
                    try addStreamingRunDerivedProbe(context.collect_derived_shape_probes, &context.top_hit_regular_nonconstant_doc_reads, 1);
                }
                const doc = try context.docs_view.readTopHitDocStatsAt(posting.doc_id - 1);
                if (doc.doc_id != posting.doc_id) return error.InvalidRecord;
                const score = bm25WeightedTermScore(
                    persistentWeightedTf(posting),
                    doc.doc_len,
                    context.avg_doc_len,
                    context.meta.doc_count,
                    @intCast(summary.postings_count),
                    .{},
                );
                if (!std.math.isFinite(score)) return core.Error.Unsupported;
                try appendTopTextTermHitBoundedInline(&context.hits, &context.hit_count, @intCast(summary.top_hit_count), &context.worst_hit_index, .{
                    .doc_id = doc.doc_id,
                    .text_freq = posting.text_freq,
                    .node_id = doc.node_id,
                    .score = score,
                });
            }
        }

        fn scoreStreamingRunDerivedVirtualTopHit(context: *StreamingRunDerivedFilesContext, posting: TextPostingRecord) !bool {
            const summary = context.current_summary;
            if (summary.top_hit_count == 0) return false;
            try addStreamingRunDerivedProbe(context.collect_derived_shape_probes, &context.top_hit_candidate_evals, 1);
            if (context.dense_all_docs_freq_stream) {
                try addStreamingRunDerivedProbe(context.collect_derived_shape_probes, &context.top_hit_dense_candidate_evals, 1);
            } else {
                try addStreamingRunDerivedProbe(context.collect_derived_shape_probes, &context.top_hit_virtual_candidate_evals, 1);
            }
            if (try textTermTopHitCandidateCannotBeatCurrentWorstWithDocLenFloor(
                context.hits[0..context.hit_count],
                context.worst_hit_index,
                @intCast(summary.top_hit_count),
                posting,
                context.avg_doc_len,
                context.meta.doc_count,
                summary.postings_count,
                streamingRunDerivedDocLenLowerBound(context),
            )) return true;
            try addStreamingRunDerivedProbe(context.collect_derived_shape_probes, &context.top_hit_doc_reads, 1);
            if (context.dense_all_docs_freq_stream) {
                try addStreamingRunDerivedProbe(context.collect_derived_shape_probes, &context.top_hit_dense_doc_reads, 1);
            } else {
                try addStreamingRunDerivedProbe(context.collect_derived_shape_probes, &context.top_hit_virtual_doc_reads, 1);
            }
            const doc = try context.docs_view.readTopHitDocStatsAt(posting.doc_id - 1);
            if (doc.doc_id != posting.doc_id) return error.InvalidRecord;
            const score = bm25WeightedTermScore(
                persistentWeightedTf(posting),
                doc.doc_len,
                context.avg_doc_len,
                context.meta.doc_count,
                @intCast(summary.postings_count),
                .{},
            );
            if (!std.math.isFinite(score)) return core.Error.Unsupported;
            try appendTopTextTermHitBoundedInline(&context.hits, &context.hit_count, @intCast(summary.top_hit_count), &context.worst_hit_index, .{
                .doc_id = doc.doc_id,
                .text_freq = posting.text_freq,
                .node_id = doc.node_id,
                .score = score,
            });
            return false;
        }

        fn findStreamingRunDerivedDenseAllDocsTopHitCache(
            context: *StreamingRunDerivedFilesContext,
            term: []const u8,
        ) ?*DenseAllDocsTopHitCache {
            for (context.dense_all_docs_top_hit_caches) |*cache| {
                if (std.mem.eql(u8, cache.term, term)) return cache;
            }
            return null;
        }

        fn useStreamingRunDerivedDenseAllDocsTopHitCache(
            context: *StreamingRunDerivedFilesContext,
            term: []const u8,
        ) !bool {
            const cache = findStreamingRunDerivedDenseAllDocsTopHitCache(context, term) orelse return false;
            const summary = context.current_summary;
            const limit = std.math.cast(usize, summary.top_hit_count) orelse return error.RecordTooLarge;
            if (limit == 0 or limit > persistent_term_top_hit_capacity_usize) return error.InvalidRecord;
            if (cache.hit_count != limit) return error.InvalidRecord;
            @memcpy(context.hits[0..limit], cache.hits[0..limit]);
            context.hit_count = limit;
            context.worst_hit_index = findWorstTextTermTopHitIndex(context.hits[0..limit]);
            return true;
        }

        fn precomputeStreamingRunDerivedDenseAllDocsTopHits(
            context: *StreamingRunDerivedFilesContext,
            synthetic_sources: []const TextPostingSyntheticRunSource,
            deadline: core.QueryDeadline,
        ) !void {
            const top_hit_count = persistentTermTopHitCountForPostingCount(context.meta.doc_count);
            if (top_hit_count == 0) return;
            const limit = std.math.cast(usize, top_hit_count) orelse return error.RecordTooLarge;
            if (limit == 0 or limit > persistent_term_top_hit_capacity_usize) return error.InvalidRecord;

            var dense_source_count: usize = 0;
            for (synthetic_sources) |source| switch (source) {
                .virtual_all_docs => {},
                .variable_all_docs => |variable| {
                    if (@as(u64, @intCast(variable.freqs.len())) != context.meta.doc_count) return error.InvalidRecord;
                    dense_source_count += 1;
                },
            };
            if (dense_source_count <= 1) return;
            if (context.dense_all_docs_top_hit_caches.len != 0) return error.InvalidRecord;

            context.dense_all_docs_top_hit_caches = try context.allocator.alloc(DenseAllDocsTopHitCache, dense_source_count);
            var cache_index: usize = 0;
            for (synthetic_sources) |source| switch (source) {
                .virtual_all_docs => {},
                .variable_all_docs => |variable| {
                    if (@as(u64, @intCast(variable.freqs.len())) != context.meta.doc_count) return error.InvalidRecord;
                    context.dense_all_docs_top_hit_caches[cache_index] = .{
                        .term = variable.term,
                        .freqs = variable.freqs.slice(),
                    };
                    cache_index += 1;
                },
            };
            if (cache_index != dense_source_count) return error.InvalidRecord;

            const dense_events = std.math.mul(u64, context.meta.doc_count, dense_source_count) catch return error.RecordTooLarge;
            var bucket_eligible = dense_events >= dense_all_docs_top_hit_bucket_min_events;
            for (context.dense_all_docs_top_hit_caches) |cache| {
                if (cache.freqs.len() != @as(usize, @intCast(context.meta.doc_count))) return error.InvalidRecord;
            }
            for (synthetic_sources) |source| switch (source) {
                .virtual_all_docs => {},
                .variable_all_docs => |variable| {
                    if (variable.freq_stats.max_freq == 0 or variable.freq_stats.max_freq > dense_all_docs_top_hit_bucket_max_freq) {
                        bucket_eligible = false;
                        break;
                    }
                },
            };
            if (bucket_eligible) {
                try precomputeStreamingRunDerivedDenseAllDocsTopHitsByFreqBucket(context, limit, synthetic_sources, deadline);
                return;
            }
            try precomputeStreamingRunDerivedDenseAllDocsTopHitsByScan(context, limit, deadline);
        }

        fn precomputeStreamingRunDerivedDenseAllDocsTopHitsByFreqBucket(
            context: *StreamingRunDerivedFilesContext,
            limit: usize,
            synthetic_sources: []const TextPostingSyntheticRunSource,
            deadline: core.QueryDeadline,
        ) !void {
            // For a dense all-doc term, documents with the same text frequency rank by
            // document length and then node id. Any document outside the top-K shortest
            // docs for its frequency cannot appear in the term's global top-K.
            var cache_index: usize = 0;
            for (synthetic_sources) |source| switch (source) {
                .virtual_all_docs => {},
                .variable_all_docs => |variable| {
                    const bucket_count = std.math.add(usize, std.math.cast(usize, variable.freq_stats.max_freq) orelse return error.RecordTooLarge, 1) catch return error.RecordTooLarge;
                    context.dense_all_docs_top_hit_caches[cache_index].freq_top_doc_buckets = try context.allocator.alloc(DenseAllDocsFreqTopDocBucket, bucket_count);
                    @memset(context.dense_all_docs_top_hit_caches[cache_index].freq_top_doc_buckets, .{});
                    cache_index += 1;
                },
            };
            if (cache_index != context.dense_all_docs_top_hit_caches.len) return error.InvalidRecord;

            var doc_index: u64 = 0;
            while (doc_index < context.meta.doc_count) : (doc_index += 1) {
                if (deadline.expired()) return core.Error.BudgetExceeded;
                const doc = try context.docs_view.readTopHitDocStatsAt(doc_index);
                if (doc.doc_id != doc_index + 1) return error.InvalidRecord;
                try addStreamingRunDerivedProbe(context.collect_derived_shape_probes, &context.top_hit_doc_reads, 1);
                try addStreamingRunDerivedProbe(context.collect_derived_shape_probes, &context.top_hit_dense_doc_reads, 1);

                for (context.dense_all_docs_top_hit_caches) |*cache| {
                    const text_freq = cache.freqs.at(@intCast(doc_index));
                    if (text_freq == 0 or text_freq >= cache.freq_top_doc_buckets.len) return error.InvalidRecord;
                    try insertDenseAllDocsFreqTopDoc(&cache.freq_top_doc_buckets[@intCast(text_freq)], limit, doc);
                }
            }

            for (context.dense_all_docs_top_hit_caches) |*cache| {
                for (cache.freq_top_doc_buckets, 0..) |bucket, text_freq| {
                    if (text_freq == 0) continue;
                    const posting_base = TextPostingRecord{
                        .doc_id = 0,
                        .text_freq = @intCast(text_freq),
                        .kind_freq = 0,
                    };
                    const weighted_tf = persistentWeightedTf(posting_base);
                    for (bucket.docs[0..bucket.count]) |doc| {
                        if (deadline.expired()) return core.Error.BudgetExceeded;
                        try addStreamingRunDerivedProbe(context.collect_derived_shape_probes, &context.top_hit_candidate_evals, 1);
                        try addStreamingRunDerivedProbe(context.collect_derived_shape_probes, &context.top_hit_dense_candidate_evals, 1);
                        const score = bm25WeightedTermScore(
                            weighted_tf,
                            doc.doc_len,
                            context.avg_doc_len,
                            context.meta.doc_count,
                            context.meta.doc_count,
                            .{},
                        );
                        if (!std.math.isFinite(score)) return core.Error.Unsupported;
                        try appendTopTextTermHitBoundedInline(
                            &cache.hits,
                            &cache.hit_count,
                            limit,
                            &cache.worst_index,
                            .{
                                .doc_id = doc.doc_id,
                                .text_freq = @intCast(text_freq),
                                .node_id = doc.node_id,
                                .score = score,
                            },
                        );
                    }
                }
                if (cache.hit_count != limit) return error.InvalidRecord;
                std.mem.sort(TextTermTopHitRecord, cache.hits[0..cache.hit_count], {}, textTermTopHitLessThan);
                cache.worst_index = findWorstTextTermTopHitIndex(cache.hits[0..cache.hit_count]);
            }
        }

        fn precomputeStreamingRunDerivedDenseAllDocsTopHitsByScan(
            context: *StreamingRunDerivedFilesContext,
            limit: usize,
            deadline: core.QueryDeadline,
        ) !void {
            var doc_index: u64 = 0;
            while (doc_index < context.meta.doc_count) : (doc_index += 1) {
                if (deadline.expired()) return core.Error.BudgetExceeded;
                const doc = try context.docs_view.readTopHitDocStatsAt(doc_index);
                if (doc.doc_id != doc_index + 1) return error.InvalidRecord;
                try addStreamingRunDerivedProbe(context.collect_derived_shape_probes, &context.top_hit_doc_reads, 1);
                try addStreamingRunDerivedProbe(context.collect_derived_shape_probes, &context.top_hit_dense_doc_reads, 1);

                for (context.dense_all_docs_top_hit_caches) |*cache| {
                    if (doc_index < cache.skip_until_doc_index) continue;
                    const text_freq = cache.freqs.at(@intCast(doc_index));
                    if (cache.hit_count >= limit and text_freq <= cache.upper_bound_skip_text_freq) {
                        const skip_count = cache.freqs.boundedRunLenLeq(
                            @intCast(doc_index),
                            cache.upper_bound_skip_text_freq,
                            persistent_dense_all_docs_top_hit_skip_run_max,
                        );
                        if (skip_count == 0) return error.InvalidRecord;
                        cache.skip_until_doc_index = doc_index + @as(u64, @intCast(skip_count));
                        try addStreamingRunDerivedProbe(context.collect_derived_shape_probes, &context.top_hit_dense_freq_bound_skips, @intCast(skip_count));
                        try addStreamingRunDerivedProbe(context.collect_derived_shape_probes, &context.top_hit_dense_freq_bound_skip_runs, 1);
                        continue;
                    }
                    const posting = TextPostingRecord{
                        .doc_id = doc.doc_id,
                        .text_freq = text_freq,
                        .kind_freq = 0,
                    };
                    try addStreamingRunDerivedProbe(context.collect_derived_shape_probes, &context.top_hit_candidate_evals, 1);
                    try addStreamingRunDerivedProbe(context.collect_derived_shape_probes, &context.top_hit_dense_candidate_evals, 1);
                    if (try textTermTopHitCandidateCannotBeatCurrentWorstWithDocLenFloor(
                        cache.hits[0..cache.hit_count],
                        cache.worst_index,
                        limit,
                        posting,
                        context.avg_doc_len,
                        context.meta.doc_count,
                        context.meta.doc_count,
                        streamingRunDerivedDocLenLowerBound(context),
                    )) {
                        cache.upper_bound_skip_text_freq = @max(cache.upper_bound_skip_text_freq, text_freq);
                        continue;
                    }
                    const score = bm25WeightedTermScore(
                        persistentWeightedTf(posting),
                        doc.doc_len,
                        context.avg_doc_len,
                        context.meta.doc_count,
                        context.meta.doc_count,
                        .{},
                    );
                    if (!std.math.isFinite(score)) return core.Error.Unsupported;
                    try appendTopTextTermHitBoundedInline(
                        &cache.hits,
                        &cache.hit_count,
                        limit,
                        &cache.worst_index,
                        .{
                            .doc_id = doc.doc_id,
                            .text_freq = text_freq,
                            .node_id = doc.node_id,
                            .score = score,
                        },
                    );
                }
            }

            for (context.dense_all_docs_top_hit_caches) |*cache| {
                if (cache.hit_count != limit) return error.InvalidRecord;
                std.mem.sort(TextTermTopHitRecord, cache.hits[0..cache.hit_count], {}, textTermTopHitLessThan);
                cache.worst_index = findWorstTextTermTopHitIndex(cache.hits[0..cache.hit_count]);
            }
        }

        fn findWorstVirtualAllDocsTopDocIndex(docs: []const TextDocRankEntry) usize {
            var worst_index: usize = 0;
            for (docs[1..], 1..) |candidate, i| {
                if (virtualAllDocsTopDocLessThan(docs[worst_index], candidate)) worst_index = i;
            }
            return worst_index;
        }

        fn virtualAllDocsTopDocLessThan(lhs: TextDocRankEntry, rhs: TextDocRankEntry) bool {
            return virtualAllDocsTopDocLessThanGeneric(lhs, rhs);
        }

        fn textDocRankLessThan(_: void, lhs: TextDocRankEntry, rhs: TextDocRankEntry) bool {
            return virtualAllDocsTopDocLessThan(lhs, rhs);
        }

        fn ensureStreamingRunDerivedVirtualAllDocsTopDocs(
            context: *StreamingRunDerivedFilesContext,
            deadline: core.QueryDeadline,
        ) !void {
            if (context.virtual_all_docs_top_docs_ready) return;
            const start_ns = if (context.collect_derived_shape_probes) textMonotonicNs(context.io) else 0;
            defer {
                if (start_ns != 0) context.derived_virtual_top_docs_ns += textElapsedNs(context.io, start_ns);
            }

            if (context.global_doc_rank_ready) {
                const limit = @min(persistent_term_top_hit_capacity_usize, context.global_doc_rank.items.len);
                context.virtual_all_docs_top_doc_count = limit;
                for (context.global_doc_rank.items[0..limit], 0..) |doc, index| {
                    context.virtual_all_docs_top_docs[index] = doc;
                }
                context.virtual_all_docs_top_docs_ready = true;
                return;
            }

            const limit = @min(persistent_term_top_hit_capacity_usize, std.math.cast(usize, context.meta.doc_count) orelse persistent_term_top_hit_capacity_usize);
            context.virtual_all_docs_top_doc_count = 0;
            var worst_index: ?usize = null;

            var doc_index: u64 = 0;
            while (doc_index < context.meta.doc_count) : (doc_index += 1) {
                if (deadline.expired()) return core.Error.BudgetExceeded;
                const doc = try context.docs_view.readDocAt(doc_index);
                if (doc.doc_id != doc_index + 1) return error.InvalidRecord;
                const rank_entry = try TextDocRankEntry.init(doc);
                context.virtual_all_docs_top_hit_cache_doc_scans = std.math.add(u64, context.virtual_all_docs_top_hit_cache_doc_scans, 1) catch return error.RecordTooLarge;
                context.global_min_doc_len = @min(context.global_min_doc_len, rank_entry.docLen());
                if (context.virtual_all_docs_top_doc_count < limit) {
                    context.virtual_all_docs_top_docs[context.virtual_all_docs_top_doc_count] = rank_entry;
                    context.virtual_all_docs_top_doc_count += 1;
                    if (context.virtual_all_docs_top_doc_count == limit) {
                        worst_index = findWorstVirtualAllDocsTopDocIndex(context.virtual_all_docs_top_docs[0..context.virtual_all_docs_top_doc_count]);
                    }
                    continue;
                }

                const slot = worst_index orelse findWorstVirtualAllDocsTopDocIndex(context.virtual_all_docs_top_docs[0..context.virtual_all_docs_top_doc_count]);
                if (virtualAllDocsTopDocLessThan(rank_entry, context.virtual_all_docs_top_docs[slot])) {
                    context.virtual_all_docs_top_docs[slot] = rank_entry;
                    worst_index = findWorstVirtualAllDocsTopDocIndex(context.virtual_all_docs_top_docs[0..context.virtual_all_docs_top_doc_count]);
                } else {
                    worst_index = slot;
                }
            }

            if (context.meta.doc_count == 0) {
                context.global_min_doc_len = persistentMinPossibleDocLen();
            } else if (!std.math.isFinite(context.global_min_doc_len) or context.global_min_doc_len <= 0) return error.InvalidRecord;
            context.global_min_doc_len_ready = true;
            context.virtual_all_docs_top_docs_ready = true;
        }

        fn ensureStreamingRunDerivedGlobalDocRank(
            context: *StreamingRunDerivedFilesContext,
            deadline: core.QueryDeadline,
        ) !void {
            if (context.global_doc_rank_ready) return;
            const start_ns = if (context.collect_derived_shape_probes) textMonotonicNs(context.io) else 0;
            defer {
                if (start_ns != 0) context.derived_global_doc_rank_ns += textElapsedNs(context.io, start_ns);
            }
            const doc_count = std.math.cast(usize, context.meta.doc_count) orelse return error.RecordTooLarge;
            context.global_doc_rank.clearRetainingCapacity();
            try context.global_doc_rank.ensureTotalCapacityPrecise(context.allocator, doc_count);

            context.global_min_doc_len = std.math.inf(f32);
            var doc_index: u64 = 0;
            while (doc_index < context.meta.doc_count) : (doc_index += 1) {
                if (deadline.expired()) return core.Error.BudgetExceeded;
                const doc = try context.docs_view.readDocAt(doc_index);
                if (doc.doc_id != doc_index + 1) return error.InvalidRecord;
                const rank_entry = try TextDocRankEntry.init(doc);
                context.virtual_all_docs_top_hit_cache_doc_scans = std.math.add(u64, context.virtual_all_docs_top_hit_cache_doc_scans, 1) catch return error.RecordTooLarge;
                context.global_min_doc_len = @min(context.global_min_doc_len, rank_entry.docLen());
                context.global_doc_rank.appendAssumeCapacity(rank_entry);
            }

            if (context.meta.doc_count == 0) {
                context.global_min_doc_len = persistentMinPossibleDocLen();
            } else if (!std.math.isFinite(context.global_min_doc_len) or context.global_min_doc_len <= 0) return error.InvalidRecord;
            std.mem.sort(TextDocRankEntry, context.global_doc_rank.items, {}, textDocRankLessThan);
            context.global_min_doc_len_ready = true;
            context.global_doc_rank_ready = true;
        }

        fn resolveStreamingRunDerivedConstantRegularTopHitsFromRank(context: *StreamingRunDerivedFilesContext, deadline: core.QueryDeadline) !void {
            if (!context.current_top_hit_regular_constant_candidate or context.current_top_hit_regular_constant_resolved) return;
            const summary = context.current_summary;
            const limit = std.math.cast(usize, summary.top_hit_count) orelse return error.RecordTooLarge;
            if (limit == 0 or limit > persistent_term_top_hit_capacity_usize) return error.InvalidRecord;
            if (context.current_top_hit_regular_constant_rank_doc_count != summary.postings_count) return error.InvalidRecord;

            try ensureStreamingRunDerivedGlobalDocRank(context, deadline);
            const text_freq = summary.constantTextFreq();
            if (text_freq == 0) return error.InvalidRecord;
            const posting_base = TextPostingRecord{
                .doc_id = 0,
                .text_freq = text_freq,
                .kind_freq = 0,
            };
            const weighted_tf = persistentWeightedTf(posting_base);

            context.hit_count = 0;
            context.worst_hit_index = null;
            for (context.global_doc_rank.items) |doc| {
                if (deadline.expired()) return core.Error.BudgetExceeded;
                const bit_index = std.math.cast(usize, doc.doc_id - 1) orelse return error.RecordTooLarge;
                if (!context.constant_top_hit_doc_bits.isSet(bit_index)) continue;
                const score = bm25WeightedTermScore(
                    weighted_tf,
                    doc.docLen(),
                    context.avg_doc_len,
                    context.meta.doc_count,
                    @intCast(summary.postings_count),
                    .{},
                );
                if (!std.math.isFinite(score)) return core.Error.Unsupported;
                try appendTopTextTermHitBoundedInline(&context.hits, &context.hit_count, limit, &context.worst_hit_index, .{
                    .doc_id = @as(u64, doc.doc_id),
                    .text_freq = text_freq,
                    .node_id = doc.node_id,
                    .score = score,
                });
                if (context.hit_count == limit) break;
            }
            if (context.hit_count != limit) return error.InvalidRecord;
            context.current_top_hit_regular_constant_resolved = true;
            try addStreamingRunDerivedProbe(context.collect_derived_shape_probes, &context.top_hit_regular_constant_resolved_terms, 1);
            try addStreamingRunDerivedProbe(context.collect_derived_shape_probes, &context.top_hit_regular_constant_resolved_candidate_skips, summary.postings_count);
        }

        fn scoreStreamingRunDerivedVirtualAllDocsTopHits(
            context: *StreamingRunDerivedFilesContext,
            text_freq: u32,
            deadline: core.QueryDeadline,
        ) !void {
            const summary = context.current_summary;
            if (summary.top_hit_count == 0) return;
            // With constant term frequency, BM25 order is doc length, then node id.
            try ensureStreamingRunDerivedVirtualAllDocsTopDocs(context, deadline);

            const limit = std.math.cast(usize, summary.top_hit_count) orelse return error.RecordTooLarge;
            if (context.virtual_all_docs_top_doc_count < limit) return error.InvalidRecord;
            const posting_base = TextPostingRecord{
                .doc_id = 0,
                .text_freq = text_freq,
                .kind_freq = 0,
            };
            const weighted_tf = persistentWeightedTf(posting_base);
            for (context.virtual_all_docs_top_docs[0..limit]) |doc| {
                const score = bm25WeightedTermScore(
                    weighted_tf,
                    doc.docLen(),
                    context.avg_doc_len,
                    context.meta.doc_count,
                    @intCast(summary.postings_count),
                    .{},
                );
                if (!std.math.isFinite(score)) return core.Error.Unsupported;
                try appendTopTextTermHitBoundedInline(&context.hits, &context.hit_count, limit, &context.worst_hit_index, .{
                    .doc_id = @as(u64, doc.doc_id),
                    .text_freq = text_freq,
                    .node_id = doc.node_id,
                    .score = score,
                });
            }
        }

        fn flushStreamingRunDerivedBlock(context: *StreamingRunDerivedFilesContext) !void {
            if (context.current_block_postings == 0) return;
            const flush_start = streamingRunDerivedSampleStart(context, context.blocks_written, streaming_run_derived_block_probe_stride);
            defer addStreamingRunDerivedSampleNs(context, &context.derived_block_flush_sampled_ns, flush_start, streaming_run_derived_block_probe_stride);
            const summary = context.current_summary;
            context.current_block.posting_count = context.current_block_postings;

            if (summary.block_count == 0) {
                if (summary.top_hit_count != 0) return error.InvalidRecord;
                if (summary.postings_count > context.block_size) return error.InvalidRecord;
                context.current_block_postings = 0;
                context.current_block_top_hit_count = 0;
                return;
            }

            var block_bytes: [TextPostingBlockRecord.encoded_len]u8 = undefined;
            try encodeTextPostingBlockRecord(try textPostingBlockRecordFromStats(context.current_block), &block_bytes);
            try context.blocks_writer.append(&block_bytes);
            if (context.blocks_written % persistent_posting_block_byte_offset_checkpoint_blocks == 0) {
                if (context.current_block.posting_offset < context.current_term_postings_offset) return error.InvalidRecord;
                const relative_offset = context.current_block.posting_offset - context.current_term_postings_offset;
                if (relative_offset > std.math.maxInt(u32)) return error.RecordTooLarge;
                var offset_bytes: [4]u8 = undefined;
                std.mem.writeInt(u32, &offset_bytes, @intCast(relative_offset), .little);
                try context.blocks_byte_offsets_writer.append(&offset_bytes);
                context.block_byte_offset_checkpoints_written = std.math.add(u64, context.block_byte_offset_checkpoints_written, 1) catch return error.RecordTooLarge;
            }
            context.blocks_written = std.math.add(u64, context.blocks_written, 1) catch return error.RecordTooLarge;

            const stored_bounds = try quantizePersistentBlockScoreBounds(
                context.current_block.max_weighted_tf,
                context.current_block.min_doc_len,
            );
            const upper_score = bm25WeightedTermScore(
                stored_bounds.max_weighted_tf,
                stored_bounds.min_doc_len,
                context.avg_doc_len,
                context.meta.doc_count,
                @intCast(summary.postings_count),
                .{},
            );
            if (!std.math.isFinite(upper_score)) return core.Error.Unsupported;
            const top_hit_start = streamingRunDerivedPostingSampleStart(context);
            if (!context.current_top_hit_regular_constant_candidate) {
                try scoreStreamingRunDerivedTopHitBlock(context, upper_score);
            } else if (context.current_block_top_hit_count != 0) {
                return error.InvalidRecord;
            }
            addStreamingRunDerivedSampleNs(context, &context.derived_top_hit_sampled_ns, top_hit_start, streaming_run_derived_record_probe_stride);
            context.impacts.appendAssumeCapacity(.{
                .local_block_index = context.local_block_index,
                .max_weighted_tf = stored_bounds.max_weighted_tf,
                .upper_score = upper_score,
            });
            context.local_block_index = std.math.add(u64, context.local_block_index, 1) catch return error.RecordTooLarge;
            context.current_block_postings = 0;
            context.current_block_top_hit_count = 0;
        }

        fn flushStreamingRunDenseAllDocsFreqGroup(context: *StreamingRunDerivedFilesContext) !void {
            if (context.dense_freq_tag_count == 0) return;
            const written = try appendDenseAllDocsFreqGroup(context.postings_writer, context.dense_freq_tags[0..context.dense_freq_tag_count], context.dense_freq_explicit[0..context.dense_freq_explicit_len]);
            context.postings_body_bytes_written = std.math.add(u64, context.postings_body_bytes_written, written) catch return error.RecordTooLarge;
            context.dense_freq_tag_count = 0;
            context.dense_freq_explicit_len = 0;
        }

        fn appendStreamingRunDenseAllDocsFreqPosting(context: *StreamingRunDerivedFilesContext, posting: TextPostingRecord) !void {
            if (context.dense_freq_buffering) {
                if (context.dense_freq_stream_written_directly) return error.InvalidRecord;
                if (posting.kind_freq != 0) return error.InvalidRecord;
                const text_freq = try validateDenseAllDocsTextFreq(posting.text_freq);
                const required_capacity = std.math.cast(usize, context.current_summary.postings_count) orelse return error.RecordTooLarge;
                if (context.dense_freqs.capacity < required_capacity) {
                    try context.dense_freqs.ensureTotalCapacityPrecise(context.allocator, required_capacity);
                }
                try context.dense_freqs.append(context.allocator, @intCast(text_freq));
                return;
            }
            if (context.term_postings_seen == 0 and context.dense_freq_tag_count == 0) {
                try context.postings_writer.append(&.{persistent_dense_all_docs_freq_mode_packed});
                context.postings_body_bytes_written = std.math.add(u64, context.postings_body_bytes_written, 1) catch return error.RecordTooLarge;
            }
            const field_tag = try compressedPostingFieldTag(posting);
            context.dense_freq_tags[context.dense_freq_tag_count] = field_tag;
            context.dense_freq_tag_count += 1;
            if (compressedPostingTagTextExplicit(field_tag)) {
                context.dense_freq_explicit_len += try encodePersistentVarint(posting.text_freq, context.dense_freq_explicit[context.dense_freq_explicit_len..]);
            }
            if (context.dense_freq_tag_count == persistent_dense_all_docs_freq_group_size) {
                try flushStreamingRunDenseAllDocsFreqGroup(context);
            }
        }

        fn appendStreamingRunSingletonPayload(context: *StreamingRunDerivedFilesContext, payload: u32) !void {
            _ = try decodeInlineSingletonPostingPayload(payload);
            if (context.term_singletons_written % persistent_term_singleton_payload_checkpoint_terms == 0) {
                var checkpoint_bytes: [TextTermSingletonPayloadCheckpoint.encoded_len]u8 = undefined;
                try encodeTextTermSingletonPayloadCheckpoint(.{
                    .stream_offset = context.term_singleton_payload_bytes_written,
                    .previous_payload = context.previous_singleton_payload,
                }, &checkpoint_bytes);
                try context.terms_singleton_checkpoints_writer.append(&checkpoint_bytes);
                context.term_singleton_checkpoints_written = std.math.add(u64, context.term_singleton_checkpoints_written, 1) catch return error.RecordTooLarge;
            }
            var delta_bytes: [10]u8 = undefined;
            const encoded_delta = encodeZigZagI64(singletonPayloadDelta(context.previous_singleton_payload, payload));
            const delta_len = try encodePersistentVarint(encoded_delta, &delta_bytes);
            try context.terms_singleton_payload_writer.append(delta_bytes[0..delta_len]);
            context.term_singleton_payload_bytes_written = std.math.add(u64, context.term_singleton_payload_bytes_written, delta_len) catch return error.RecordTooLarge;
            context.previous_singleton_payload = payload;
            context.term_singletons_written = std.math.add(u64, context.term_singletons_written, 1) catch return error.RecordTooLarge;
        }

        fn appendStreamingRunExceptionMembership(context: *StreamingRunDerivedFilesContext, term_index: u64, is_exception: bool) !void {
            if (term_index % persistent_term_exception_rank_checkpoint_terms == 0) {
                if (context.term_exceptions_written > std.math.maxInt(u32)) return error.RecordTooLarge;
                var checkpoint_bytes: [4]u8 = undefined;
                std.mem.writeInt(u32, &checkpoint_bytes, @intCast(context.term_exceptions_written), .little);
                try context.terms_exception_rank_writer.append(&checkpoint_bytes);
                context.term_exception_rank_checkpoints_written = std.math.add(u64, context.term_exception_rank_checkpoints_written, 1) catch return error.RecordTooLarge;
            }
            if (is_exception) {
                context.current_exception_membership_byte |= @as(u8, 1) << @as(u3, @intCast(context.current_exception_membership_bits));
            }
            context.current_exception_membership_bits += 1;
            if (context.current_exception_membership_bits == 8) {
                try context.terms_exception_membership_writer.append(&.{context.current_exception_membership_byte});
                context.term_exception_membership_bytes_written = std.math.add(u64, context.term_exception_membership_bytes_written, 1) catch return error.RecordTooLarge;
                context.current_exception_membership_byte = 0;
                context.current_exception_membership_bits = 0;
            }
        }

        fn finishStreamingRunExceptionMembership(context: *StreamingRunDerivedFilesContext) !void {
            if (context.current_exception_membership_bits != 0) {
                try context.terms_exception_membership_writer.append(&.{context.current_exception_membership_byte});
                context.term_exception_membership_bytes_written = std.math.add(u64, context.term_exception_membership_bytes_written, 1) catch return error.RecordTooLarge;
                context.current_exception_membership_byte = 0;
                context.current_exception_membership_bits = 0;
            }
        }

        fn collectStreamingRunDerivedTopHitRegularTermProbe(context: *StreamingRunDerivedFilesContext, summary: TextPostingRunTermSummaryRecord) !void {
            if (!context.collect_derived_shape_probes) return;
            if (summary.top_hit_count == 0) return;
            if (context.virtual_all_docs_text_freq != 0 or context.dense_all_docs_freq_stream) return;

            context.top_hit_regular_term_count = std.math.add(u64, context.top_hit_regular_term_count, 1) catch return error.RecordTooLarge;
            if (context.current_top_hit_regular_constant_candidate and !context.current_top_hit_regular_constant_resolved) {
                context.top_hit_regular_constant_unresolved_terms = std.math.add(u64, context.top_hit_regular_constant_unresolved_terms, 1) catch return error.RecordTooLarge;
            }
            if (context.current_top_hit_regular_doc_reads != 0) {
                context.top_hit_regular_doc_read_term_count = std.math.add(u64, context.top_hit_regular_doc_read_term_count, 1) catch return error.RecordTooLarge;
            }

            const probe = TextTopHitRegularTermProbe{
                .term_index = context.summary_index - 1,
                .postings_count = summary.postings_count,
                .block_evals = context.current_top_hit_regular_block_evals,
                .candidate_evals = context.current_top_hit_regular_candidate_evals,
                .doc_reads = context.current_top_hit_regular_doc_reads,
            };
            insertTextTopHitRegularTermProbe(
                &context.top_hit_regular_doc_read_heavy_terms,
                &context.top_hit_regular_doc_read_heavy_term_count,
                probe,
                topHitRegularTermProbeDocReadHeavier,
            );
            insertTextTopHitRegularTermProbe(
                &context.top_hit_regular_candidate_heavy_terms,
                &context.top_hit_regular_candidate_heavy_term_count,
                probe,
                topHitRegularTermProbeCandidateHeavier,
            );
        }

        fn finishStreamingRunDerivedInlineSingletonTerm(context: *StreamingRunDerivedFilesContext) !bool {
            const posting = context.inline_singleton_posting orelse return false;
            const summary = context.current_summary;
            if (summary.postings_count != 1 or summary.block_count != 0 or summary.top_hit_count != 0) return error.InvalidRecord;
            if (context.term_postings_seen != 1 or context.previous_doc_id != posting.doc_id) return error.InvalidRecord;
            if (context.current_block_postings != 0 or context.local_block_index != 0 or context.hit_count != 0) return error.InvalidRecord;
            if (context.dense_freq_tag_count != 0 or context.dense_freq_explicit_len != 0) return error.InvalidRecord;
            if (context.dense_freq_buffering or context.dense_freq_stream_written_directly or context.dense_freqs.items.len != 0) return error.InvalidRecord;
            if (context.virtual_all_docs_text_freq != 0 or context.dense_all_docs_freq_stream) return error.InvalidRecord;

            const posting_payload = try encodeInlineSingletonPostingPayload(posting);
            const entry = TextTermEntry{
                .term_len = @intCast(context.current_term_len),
                .doc_freq = 1,
                .postings_offset = posting_payload,
                .postings_count = 1,
                .front_prefix_len = context.current_term_front_prefix_len,
            };
            if (!termEntryHasInlinePosting(entry)) return error.InvalidRecord;
            var entry_bytes: [TextTermEntry.encoded_len]u8 = undefined;
            try encodeTextTermEntry(entry, &entry_bytes);
            try context.terms_entry_writer.append(&entry_bytes);
            context.term_entries_written = std.math.add(u64, context.term_entries_written, 1) catch return error.RecordTooLarge;
            try appendStreamingRunExceptionMembership(context, context.term_entries_written - 1, false);
            try appendStreamingRunSingletonPayload(context, @intCast(posting_payload));
            context.have_term = false;
            return true;
        }

        fn finishStreamingRunDerivedTerm(context: *StreamingRunDerivedFilesContext) !void {
            if (!context.have_term) return;
            if (try finishStreamingRunDerivedInlineSingletonTerm(context)) return;
            flushStreamingRunDerivedBlock(context) catch |err| {
                textBenchTraceDerivedContext("finish_term_flush_block_error", context);
                return err;
            };
            flushStreamingRunDenseAllDocsFreqGroup(context) catch |err| {
                textBenchTraceDerivedContext("finish_term_flush_dense_group_error", context);
                return err;
            };
            const summary = context.current_summary;
            if (context.term_postings_seen != summary.postings_count) {
                textBenchTraceDerivedContext("finish_term_posting_count_mismatch", context);
                return error.InvalidRecord;
            }
            resolveStreamingRunDerivedConstantRegularTopHitsFromRank(context, .none) catch |err| {
                textBenchTraceDerivedContext("finish_term_constant_top_hits_error", context);
                return err;
            };
            if (context.local_block_index != summary.block_count or context.hit_count != summary.top_hit_count) {
                textBenchTraceDerivedContext("finish_term_block_or_hit_count_mismatch", context);
                return error.InvalidRecord;
            }
            if (context.dense_freq_buffering) {
                if (!context.dense_all_docs_freq_stream) {
                    textBenchTraceDerivedContext("finish_term_dense_buffer_without_dense_stream", context);
                    return error.InvalidRecord;
                }
                if (context.dense_freq_stream_written_directly) {
                    if (context.dense_freqs.items.len != 0) {
                        textBenchTraceDerivedContext("finish_term_dense_direct_with_buffered_freqs", context);
                        return error.InvalidRecord;
                    }
                } else {
                    if (@as(u64, @intCast(context.dense_freqs.items.len)) != summary.postings_count) {
                        textBenchTraceDerivedContext("finish_term_dense_freq_count_mismatch", context);
                        return error.InvalidRecord;
                    }
                    const written = try appendDenseAllDocsFreqStreamFreqs(context.postings_writer, context.dense_freqs.items);
                    context.postings_body_bytes_written = std.math.add(u64, context.postings_body_bytes_written, written) catch return error.RecordTooLarge;
                }
            }

            const posting_payload = if (context.inline_singleton_posting) |posting|
                try encodeInlineSingletonPostingPayload(posting)
            else if (context.virtual_all_docs_text_freq != 0)
                try encodeVirtualAllDocsPostingPayload(context.virtual_all_docs_text_freq)
            else if (context.dense_all_docs_freq_stream)
                context.current_term_postings_offset
            else
                context.current_term_postings_offset;
            const posting_payload_is_plain = context.inline_singleton_posting == null and
                context.virtual_all_docs_text_freq == 0 and
                !context.dense_all_docs_freq_stream;
            const posting_payload_is_dense_freq_stream = context.inline_singleton_posting == null and
                context.virtual_all_docs_text_freq == 0 and
                context.dense_all_docs_freq_stream;
            const entry = TextTermEntry{
                .term_len = @intCast(context.current_term_len),
                .doc_freq = @intCast(summary.postings_count),
                .postings_offset = posting_payload,
                .postings_count = @intCast(summary.postings_count),
                .front_prefix_len = context.current_term_front_prefix_len,
                .postings_offset_is_plain = posting_payload_is_plain,
                .postings_offset_is_dense_freq_stream = posting_payload_is_dense_freq_stream,
            };
            var entry_bytes: [TextTermEntry.encoded_len]u8 = undefined;
            try encodeTextTermEntry(entry, &entry_bytes);
            try context.terms_entry_writer.append(&entry_bytes);
            context.term_entries_written = std.math.add(u64, context.term_entries_written, 1) catch return error.RecordTooLarge;
            if (termEntryHasInlinePosting(entry)) {
                try appendStreamingRunExceptionMembership(context, context.term_entries_written - 1, false);
                try appendStreamingRunSingletonPayload(context, @intCast(posting_payload));
            } else {
                try appendStreamingRunExceptionMembership(context, context.term_entries_written - 1, true);
                var exception_bytes: [TextTermExceptionRecord.encoded_len]u8 = undefined;
                try encodeTextTermExceptionRecord(.{
                    .doc_freq = @intCast(summary.postings_count),
                    .postings_offset = posting_payload,
                    .postings_offset_is_plain = posting_payload_is_plain,
                    .postings_offset_is_dense_freq_stream = posting_payload_is_dense_freq_stream,
                }, &exception_bytes);
                try context.terms_exception_payload_writer.append(&exception_bytes);
                context.term_exceptions_written = std.math.add(u64, context.term_exceptions_written, 1) catch return error.RecordTooLarge;
            }

            std.mem.sort(MemoryPostingBlockImpact, context.impacts.items, {}, memoryPostingBlockImpactLessThan);
            var impact_bytes: [persistent_posting_block_ordinal_len]u8 = undefined;
            for (context.impacts.items) |impact| {
                const global_block_index = std.math.add(u64, context.block_index_base, impact.local_block_index) catch return error.RecordTooLarge;
                try encodePersistentBlockOrdinal(global_block_index, &impact_bytes);
                try context.impacts_writer.append(&impact_bytes);
                context.impacts_written = std.math.add(u64, context.impacts_written, 1) catch return error.RecordTooLarge;
            }

            std.mem.sort(TextTermTopHitRecord, context.hits[0..context.hit_count], {}, textTermTopHitLessThan);
            var hit_bytes: [TextTermTopHitRecord.encoded_len]u8 = undefined;
            for (context.hits[0..context.hit_count]) |hit| {
                try encodeTextTermTopHitRecord(hit, &hit_bytes);
                try context.top_hits_writer.append(&hit_bytes);
                context.hits_written = std.math.add(u64, context.hits_written, 1) catch return error.RecordTooLarge;
            }
            if (summary.top_hit_count != 0) {
                const term_index = context.summary_index - 1;
                var hit_term_bytes: [TextTermTopHitTermRecord.encoded_len]u8 = undefined;
                try encodeTextTermTopHitTermRecord(.{
                    .term_index = term_index,
                    .hit_offset = context.hits_written - summary.top_hit_count,
                    .hit_count = summary.top_hit_count,
                }, &hit_term_bytes);
                try context.top_hits_index_writer.append(&hit_term_bytes);
                context.hit_terms_written = std.math.add(u64, context.hit_terms_written, 1) catch return error.RecordTooLarge;
            }
            try collectStreamingRunDerivedTopHitRegularTermProbe(context, summary);

            context.block_index_base = std.math.add(u64, context.block_index_base, summary.block_count) catch return error.RecordTooLarge;
            context.have_term = false;
        }

        fn writeTextRunDerivedRecordFromRun(context: *StreamingRunDerivedFilesContext, record: *const TextPostingRunRecord) !bool {
            if (!streamingRunDerivedTermMatches(context, record.*.term())) {
                finishStreamingRunDerivedTerm(context) catch |err| {
                    textBenchTraceDerivedRecord("record_finish_previous_term_error", context, record.*);
                    return err;
                };
                startStreamingRunDerivedTerm(context, record.*.term()) catch |err| {
                    textBenchTraceDerivedRecord("record_start_term_error", context, record.*);
                    return err;
                };
            }

            const summary = context.current_summary;
            const posting = record.*.toPostingAssumeValid();

            if (context.virtual_all_docs_text_freq != 0) {
                if (summary.postings_count != context.meta.doc_count or summary.block_count != 0) {
                    textBenchTraceDerivedRecord("record_virtual_summary_shape_error", context, record.*);
                    return error.InvalidRecord;
                }
                if (posting.text_freq != context.virtual_all_docs_text_freq or posting.kind_freq != 0) {
                    textBenchTraceDerivedRecord("record_virtual_freq_error", context, record.*);
                    return error.InvalidRecord;
                }
                if (posting.doc_id != context.term_postings_seen + 1) {
                    textBenchTraceDerivedRecord("record_virtual_doc_order_error", context, record.*);
                    return error.InvalidRecord;
                }
                try addStreamingRunDerivedProbe(context.collect_derived_shape_probes, &context.derived_virtual_records, 1);
                context.previous_doc_id = posting.doc_id;
                const top_hit_start = streamingRunDerivedPostingSampleStart(context);
                _ = try scoreStreamingRunDerivedVirtualTopHit(context, posting);
                addStreamingRunDerivedSampleNs(context, &context.derived_top_hit_sampled_ns, top_hit_start, streaming_run_derived_record_probe_stride);
                context.term_postings_seen += 1;
                context.postings_written = std.math.add(u64, context.postings_written, 1) catch return error.RecordTooLarge;
                return false;
            }

            if (summary.postings_count == 1 and canInlineSingletonPosting(posting)) {
                const inline_start = streamingRunDerivedPostingSampleStart(context);
                defer addStreamingRunDerivedSampleNs(context, &context.derived_inline_singleton_publish_sampled_ns, inline_start, streaming_run_derived_record_probe_stride);
                if (context.term_postings_seen != 0 or context.inline_singleton_posting != null) {
                    textBenchTraceDerivedRecord("record_inline_singleton_duplicate_error", context, record.*);
                    return error.InvalidRecord;
                }
                if (posting.doc_id <= context.previous_doc_id) {
                    textBenchTraceDerivedRecord("record_inline_singleton_doc_order_error", context, record.*);
                    return error.InvalidRecord;
                }
                if (!context.derived_current_term_shape_counted) {
                    try addStreamingRunDerivedProbe(context.collect_derived_shape_probes, &context.derived_inline_singleton_terms, 1);
                    context.derived_current_term_shape_counted = true;
                }
                try addStreamingRunDerivedProbe(context.collect_derived_shape_probes, &context.derived_inline_singleton_records, 1);
                context.previous_doc_id = posting.doc_id;
                context.inline_singleton_posting = posting;
                context.term_postings_seen += 1;
                context.postings_written = std.math.add(u64, context.postings_written, 1) catch return error.RecordTooLarge;
                return true;
            }

            if (context.dense_all_docs_freq_stream) {
                if (summary.postings_count != context.meta.doc_count or summary.block_count != 0) {
                    textBenchTraceDerivedRecord("record_dense_summary_shape_error", context, record.*);
                    return error.InvalidRecord;
                }
                if (posting.doc_id != context.term_postings_seen + 1) {
                    textBenchTraceDerivedRecord("record_dense_doc_order_error", context, record.*);
                    return error.InvalidRecord;
                }
                if (posting.text_freq == 0 or posting.kind_freq != 0) {
                    textBenchTraceDerivedRecord("record_dense_freq_error", context, record.*);
                    return error.InvalidRecord;
                }
                try addStreamingRunDerivedProbe(context.collect_derived_shape_probes, &context.derived_dense_records, 1);
                context.previous_doc_id = posting.doc_id;
                try appendStreamingRunDenseAllDocsFreqPosting(context, posting);
                const top_hit_start = streamingRunDerivedPostingSampleStart(context);
                _ = try scoreStreamingRunDerivedVirtualTopHit(context, posting);
                addStreamingRunDerivedSampleNs(context, &context.derived_top_hit_sampled_ns, top_hit_start, streaming_run_derived_record_probe_stride);
                context.term_postings_seen += 1;
                context.postings_written = std.math.add(u64, context.postings_written, 1) catch return error.RecordTooLarge;
                return false;
            }

            if (context.current_block_postings == 0) initStreamingRunDerivedBlock(context);
            if (!context.derived_current_term_shape_counted) {
                try addStreamingRunDerivedProbe(context.collect_derived_shape_probes, &context.derived_block_terms, 1);
                context.derived_current_term_shape_counted = true;
            }
            try addStreamingRunDerivedProbe(context.collect_derived_shape_probes, &context.derived_block_records, 1);
            var posting_bytes: [compressed_posting_max_encoded_len]u8 = undefined;
            const encode_start = streamingRunDerivedPostingSampleStart(context);
            const encoded_len = encodeCompressedTextPosting(posting, context.current_block_previous_doc_id, &posting_bytes) catch |err| {
                textBenchTraceDerivedRecord("record_encode_error", context, record.*);
                return err;
            };
            addStreamingRunDerivedSampleNs(context, &context.derived_encode_sampled_ns, encode_start, streaming_run_derived_record_probe_stride);
            const write_start = streamingRunDerivedPostingSampleStart(context);
            try context.postings_writer.append(posting_bytes[0..encoded_len]);
            addStreamingRunDerivedSampleNs(context, &context.derived_write_sampled_ns, write_start, streaming_run_derived_record_probe_stride);
            context.current_block_previous_doc_id = posting.doc_id;

            const block_stats_start = streamingRunDerivedPostingSampleStart(context);
            addPostingToBlockStats(posting, &context.previous_doc_id, context.meta.doc_count, &context.current_block) catch |err| {
                textBenchTraceDerivedRecord("record_block_stats_error", context, record.*);
                return err;
            };
            addStreamingRunDerivedSampleNs(context, &context.derived_block_stats_sampled_ns, block_stats_start, streaming_run_derived_record_probe_stride);
            context.current_block_postings += 1;
            context.term_postings_seen += 1;
            context.postings_written = std.math.add(u64, context.postings_written, 1) catch return error.RecordTooLarge;
            context.postings_body_bytes_written = std.math.add(u64, context.postings_body_bytes_written, encoded_len) catch return error.RecordTooLarge;
            if (summary.top_hit_count != 0) {
                const top_hit_start = streamingRunDerivedPostingSampleStart(context);
                defer addStreamingRunDerivedSampleNs(context, &context.derived_top_hit_sampled_ns, top_hit_start, streaming_run_derived_record_probe_stride);
                if (context.current_top_hit_regular_constant_candidate) {
                    markStreamingRunDerivedConstantRankDoc(context, posting.doc_id) catch |err| {
                        textBenchTraceDerivedRecord("record_constant_rank_doc_error", context, record.*);
                        return err;
                    };
                } else {
                    if (context.current_block_top_hit_count >= persistent_posting_block_capacity) {
                        textBenchTraceDerivedRecord("record_top_hit_block_overflow", context, record.*);
                        return error.InvalidRecord;
                    }
                    context.current_block_top_hit_postings[context.current_block_top_hit_count] = posting;
                    context.current_block_top_hit_count += 1;
                }
            }
            if (context.current_block_postings == context.block_size) {
                flushStreamingRunDerivedBlock(context) catch |err| {
                    textBenchTraceDerivedRecord("record_flush_block_error", context, record.*);
                    return err;
                };
            }
            return false;
        }

        fn writeTextRunDerivedSyntheticSourceAsRecords(
            context: *StreamingRunDerivedFilesContext,
            source: TextPostingSyntheticRunSource,
            doc_count: u64,
            deadline: core.QueryDeadline,
        ) !void {
            var doc_index: u64 = 0;
            while (doc_index < doc_count) : (doc_index += 1) {
                if (deadline.expired()) return core.Error.BudgetExceeded;
                const doc_id = doc_index + 1;
                const record = switch (source) {
                    .virtual_all_docs => |virtual| try TextPostingRunRecord.init(virtual.term, .{
                        .doc_id = doc_id,
                        .text_freq = virtual.text_freq,
                        .kind_freq = 0,
                    }),
                    .variable_all_docs => |variable| blk: {
                        if (@as(u64, @intCast(variable.freqs.len())) != doc_count) return error.InvalidRecord;
                        break :blk try TextPostingRunRecord.init(variable.term, .{
                            .doc_id = doc_id,
                            .text_freq = variable.freqs.at(@intCast(doc_index)),
                            .kind_freq = 0,
                        });
                    },
                };
                _ = try writeTextRunDerivedRecordFromRun(context, &record);
            }
        }

        fn writeTextRunDerivedSyntheticSourceTerm(
            context: *StreamingRunDerivedFilesContext,
            source: TextPostingSyntheticRunSource,
            doc_count: u64,
            deadline: core.QueryDeadline,
        ) !void {
            try finishStreamingRunDerivedTerm(context);
            try startStreamingRunDerivedTerm(context, source.term());

            const summary = context.current_summary;
            switch (source) {
                .virtual_all_docs => |virtual| {
                    if (context.virtual_all_docs_text_freq != virtual.text_freq) {
                        try writeTextRunDerivedSyntheticSourceAsRecords(context, source, doc_count, deadline);
                        try finishStreamingRunDerivedTerm(context);
                        return;
                    }
                    if (summary.postings_count != doc_count or summary.block_count != 0) return error.InvalidRecord;
                    if (context.term_postings_seen != 0 or context.previous_doc_id != 0) return error.InvalidRecord;
                    try scoreStreamingRunDerivedVirtualAllDocsTopHits(context, virtual.text_freq, deadline);
                    context.previous_doc_id = doc_count;
                    context.term_postings_seen = doc_count;
                    try addStreamingRunDerivedProbe(context.collect_derived_shape_probes, &context.derived_virtual_records, doc_count);
                    context.postings_written = std.math.add(u64, context.postings_written, doc_count) catch return error.RecordTooLarge;
                },
                .variable_all_docs => |variable| {
                    if (@as(u64, @intCast(variable.freqs.len())) != doc_count) return error.InvalidRecord;
                    if (!context.dense_all_docs_freq_stream) {
                        try writeTextRunDerivedSyntheticSourceAsRecords(context, source, doc_count, deadline);
                        try finishStreamingRunDerivedTerm(context);
                        return;
                    }
                    if (summary.postings_count != doc_count or summary.block_count != 0) return error.InvalidRecord;
                    if (deadline.expired()) return core.Error.BudgetExceeded;
                    if (context.dense_freqs.items.len != 0) return error.InvalidRecord;
                    context.dense_freq_stream_written_directly = true;
                    const written = try variable.freqs.slice().appendDenseAllDocsFreqStreamWithStats(context.postings_writer, variable.freq_stats);
                    context.postings_body_bytes_written = std.math.add(u64, context.postings_body_bytes_written, written) catch return error.RecordTooLarge;
                    if (summary.top_hit_count == 0) {
                        context.previous_doc_id = doc_count;
                        context.term_postings_seen = doc_count;
                        try addStreamingRunDerivedProbe(context.collect_derived_shape_probes, &context.derived_dense_records, doc_count);
                        context.postings_written = std.math.add(u64, context.postings_written, doc_count) catch return error.RecordTooLarge;
                    } else {
                        const freq_slice = variable.freqs.slice();
                        if (try useStreamingRunDerivedDenseAllDocsTopHitCache(context, variable.term)) {
                            context.previous_doc_id = doc_count;
                            try addStreamingRunDerivedProbe(context.collect_derived_shape_probes, &context.top_hit_dense_scan_records, doc_count);
                            try addStreamingRunDerivedProbe(context.collect_derived_shape_probes, &context.derived_dense_records, doc_count);
                            context.term_postings_seen = std.math.add(u64, context.term_postings_seen, doc_count) catch return error.RecordTooLarge;
                            context.postings_written = std.math.add(u64, context.postings_written, doc_count) catch return error.RecordTooLarge;
                        } else {
                            var index: usize = 0;
                            var upper_bound_skip_text_freq: u32 = 0;
                            while (index < freq_slice.len()) {
                                if (deadline.expired()) return core.Error.BudgetExceeded;
                                const text_freq = freq_slice.at(index);
                                if (context.hit_count >= summary.top_hit_count and text_freq <= upper_bound_skip_text_freq) {
                                    // BM25 upper bounds are monotonic in term frequency. Once a
                                    // frequency cannot beat the current worst top hit, lower or
                                    // equal frequencies cannot become candidates later.
                                    const skip_count = freq_slice.boundedRunLenLeq(index, upper_bound_skip_text_freq, persistent_dense_all_docs_top_hit_skip_run_max);
                                    if (skip_count == 0) return error.InvalidRecord;
                                    context.previous_doc_id = @intCast(index + skip_count);
                                    try addStreamingRunDerivedProbe(context.collect_derived_shape_probes, &context.top_hit_dense_scan_records, @intCast(skip_count));
                                    try addStreamingRunDerivedProbe(context.collect_derived_shape_probes, &context.top_hit_dense_freq_bound_skips, @intCast(skip_count));
                                    try addStreamingRunDerivedProbe(context.collect_derived_shape_probes, &context.top_hit_dense_freq_bound_skip_runs, 1);
                                    try addStreamingRunDerivedProbe(context.collect_derived_shape_probes, &context.derived_dense_records, @intCast(skip_count));
                                    context.term_postings_seen = std.math.add(u64, context.term_postings_seen, @intCast(skip_count)) catch return error.RecordTooLarge;
                                    context.postings_written = std.math.add(u64, context.postings_written, @intCast(skip_count)) catch return error.RecordTooLarge;
                                    index += skip_count;
                                    continue;
                                }
                                const posting = TextPostingRecord{
                                    .doc_id = @intCast(index + 1),
                                    .text_freq = text_freq,
                                    .kind_freq = 0,
                                };
                                context.previous_doc_id = posting.doc_id;
                                try addStreamingRunDerivedProbe(context.collect_derived_shape_probes, &context.top_hit_dense_scan_records, 1);
                                if (try scoreStreamingRunDerivedVirtualTopHit(context, posting)) {
                                    upper_bound_skip_text_freq = @max(upper_bound_skip_text_freq, text_freq);
                                }
                                try addStreamingRunDerivedProbe(context.collect_derived_shape_probes, &context.derived_dense_records, 1);
                                context.term_postings_seen = std.math.add(u64, context.term_postings_seen, 1) catch return error.RecordTooLarge;
                                context.postings_written = std.math.add(u64, context.postings_written, 1) catch return error.RecordTooLarge;
                                index += 1;
                            }
                        }
                    }
                },
            }
            try finishStreamingRunDerivedTerm(context);
        }

        fn recordTextRunDerivedSyntheticTiming(timings: *PersistentTextRebuildTimings, source: TextPostingSyntheticRunSource, elapsed: u128) void {
            switch (source) {
                .virtual_all_docs => {
                    timings.run_derived_virtual_ns += elapsed;
                    timings.run_derived_virtual_source_terms += 1;
                },
                .variable_all_docs => {
                    timings.run_derived_dense_ns += elapsed;
                    timings.run_derived_dense_source_terms += 1;
                },
            }
        }

        fn writeTextRunDerivedRecordsAndSyntheticTermsFromSingleRun(
            allocator: std.mem.Allocator,
            io: std.Io,
            run_path: []const u8,
            synthetic_sources: []const TextPostingSyntheticRunSource,
            doc_count: u64,
            deadline: core.QueryDeadline,
            context: *StreamingRunDerivedFilesContext,
            timings: ?*PersistentTextRebuildTimings,
        ) !void {
            const records_start = if (timings != null) textMonotonicNs(io) else 0;
            var synthetic_ns: u128 = 0;

            var file = try std.Io.Dir.cwd().openFile(io, run_path, .{});
            const stat = try file.stat(io);
            if (stat.kind != .file) {
                file.close(io);
                return error.InvalidRecord;
            }
            var reader = TextPostingRunReader.init(allocator, io, file, stat.size) catch |err| {
                file.close(io);
                return err;
            };
            defer reader.deinit();

            var record_storage: TextPostingRunRecord = undefined;
            const first_next_ordinal = streamingRunDerivedNextProbeOrdinal(context);
            const first_next_start = streamingRunDerivedNextSampleStart(context, first_next_ordinal);
            var have_next_run_record = try reader.nextRecordInto(&record_storage);
            var next_run_record_sampled_ns = streamingRunDerivedSampleElapsedNs(context, first_next_start, streaming_run_derived_record_probe_stride);
            context.derived_next_sampled_ns += next_run_record_sampled_ns;

            var source_index: usize = 0;
            while (have_next_run_record or source_index < synthetic_sources.len) {
                if (deadline.expired()) return core.Error.BudgetExceeded;

                if (source_index < synthetic_sources.len) {
                    const source = synthetic_sources[source_index];
                    if (have_next_run_record) {
                        switch (std.mem.order(u8, source.term(), record_storage.term())) {
                            .lt => {
                                const synthetic_start = if (timings != null) textMonotonicNs(io) else 0;
                                try writeTextRunDerivedSyntheticSourceTerm(context, source, doc_count, deadline);
                                if (timings) |t| {
                                    const elapsed = textElapsedNs(io, synthetic_start);
                                    synthetic_ns += elapsed;
                                    recordTextRunDerivedSyntheticTiming(t, source, elapsed);
                                }
                                source_index += 1;
                                continue;
                            },
                            .eq => return error.InvalidRecord,
                            .gt => {},
                        }
                    } else {
                        const synthetic_start = if (timings != null) textMonotonicNs(io) else 0;
                        try writeTextRunDerivedSyntheticSourceTerm(context, source, doc_count, deadline);
                        if (timings) |t| {
                            const elapsed = textElapsedNs(io, synthetic_start);
                            synthetic_ns += elapsed;
                            recordTextRunDerivedSyntheticTiming(t, source, elapsed);
                        }
                        source_index += 1;
                        continue;
                    }
                }

                if (!have_next_run_record) return error.InvalidRecord;
                const inline_singleton = try writeTextRunDerivedRecordFromRun(context, &record_storage);
                if (inline_singleton) {
                    context.derived_inline_singleton_next_sampled_ns += next_run_record_sampled_ns;
                }
                const next_ordinal = streamingRunDerivedNextProbeOrdinal(context);
                const next_start = streamingRunDerivedNextSampleStart(context, next_ordinal);
                have_next_run_record = try reader.nextRecordInto(&record_storage);
                next_run_record_sampled_ns = streamingRunDerivedSampleElapsedNs(context, next_start, streaming_run_derived_record_probe_stride);
                context.derived_next_sampled_ns += next_run_record_sampled_ns;
            }
            if (timings) |t| {
                const elapsed = textElapsedNs(io, records_start);
                t.run_derived_regular_ns += if (elapsed >= synthetic_ns) elapsed - synthetic_ns else 0;
            }
        }

        fn writeTextRunDerivedRecordsAndSyntheticTermsFromDisjointRuns(
            allocator: std.mem.Allocator,
            io: std.Io,
            run_paths: []const []const u8,
            synthetic_sources: []const TextPostingSyntheticRunSource,
            doc_count: u64,
            deadline: core.QueryDeadline,
            context: *StreamingRunDerivedFilesContext,
            timings: ?*PersistentTextRebuildTimings,
        ) !void {
            const records_start = if (timings != null) textMonotonicNs(io) else 0;
            var synthetic_ns: u128 = 0;
            var source_index: usize = 0;

            for (run_paths) |run_path| {
                var file = try std.Io.Dir.cwd().openFile(io, run_path, .{});
                const stat = try file.stat(io);
                if (stat.kind != .file) {
                    file.close(io);
                    return error.InvalidRecord;
                }
                var reader = TextPostingRunReader.init(allocator, io, file, stat.size) catch |err| {
                    file.close(io);
                    return err;
                };
                defer reader.deinit();

                var record_storage: TextPostingRunRecord = undefined;
                var have_next_run_record = true;
                while (true) {
                    const next_ordinal = streamingRunDerivedNextProbeOrdinal(context);
                    const next_start = streamingRunDerivedNextSampleStart(context, next_ordinal);
                    have_next_run_record = try reader.nextRecordInto(&record_storage);
                    const next_run_record_sampled_ns = streamingRunDerivedSampleElapsedNs(context, next_start, streaming_run_derived_record_probe_stride);
                    context.derived_next_sampled_ns += next_run_record_sampled_ns;
                    if (!have_next_run_record) break;

                    while (source_index < synthetic_sources.len) {
                        const source = synthetic_sources[source_index];
                        switch (std.mem.order(u8, source.term(), record_storage.term())) {
                            .lt => {
                                const synthetic_start = if (timings != null) textMonotonicNs(io) else 0;
                                try writeTextRunDerivedSyntheticSourceTerm(context, source, doc_count, deadline);
                                if (timings) |t| {
                                    const elapsed = textElapsedNs(io, synthetic_start);
                                    synthetic_ns += elapsed;
                                    recordTextRunDerivedSyntheticTiming(t, source, elapsed);
                                }
                                source_index += 1;
                                continue;
                            },
                            .eq => return error.InvalidRecord,
                            .gt => break,
                        }
                    }

                    if (deadline.expired()) return core.Error.BudgetExceeded;
                    const inline_singleton = try writeTextRunDerivedRecordFromRun(context, &record_storage);
                    if (inline_singleton) {
                        context.derived_inline_singleton_next_sampled_ns += next_run_record_sampled_ns;
                    }
                }
            }

            while (source_index < synthetic_sources.len) {
                if (deadline.expired()) return core.Error.BudgetExceeded;
                const source = synthetic_sources[source_index];
                const synthetic_start = if (timings != null) textMonotonicNs(io) else 0;
                try writeTextRunDerivedSyntheticSourceTerm(context, source, doc_count, deadline);
                if (timings) |t| {
                    const elapsed = textElapsedNs(io, synthetic_start);
                    synthetic_ns += elapsed;
                    recordTextRunDerivedSyntheticTiming(t, source, elapsed);
                }
                source_index += 1;
            }

            if (timings) |t| {
                const elapsed = textElapsedNs(io, records_start);
                t.run_derived_regular_ns += if (elapsed >= synthetic_ns) elapsed - synthetic_ns else 0;
            }
        }

        fn writeTextRunDerivedRecordsAndSyntheticTerms(
            allocator: std.mem.Allocator,
            io: std.Io,
            run_paths: []const []const u8,
            synthetic_sources: []const TextPostingSyntheticRunSource,
            run_paths_disjoint_term_ranges: bool,
            doc_count: u64,
            deadline: core.QueryDeadline,
            context: *StreamingRunDerivedFilesContext,
            timings: ?*PersistentTextRebuildTimings,
        ) !void {
            if (run_paths.len == 1) {
                return try writeTextRunDerivedRecordsAndSyntheticTermsFromSingleRun(
                    allocator,
                    io,
                    run_paths[0],
                    synthetic_sources,
                    doc_count,
                    deadline,
                    context,
                    timings,
                );
            }
            if (run_paths_disjoint_term_ranges and run_paths.len > 1) {
                return try writeTextRunDerivedRecordsAndSyntheticTermsFromDisjointRuns(
                    allocator,
                    io,
                    run_paths,
                    synthetic_sources,
                    doc_count,
                    deadline,
                    context,
                    timings,
                );
            }

            const records_start = if (timings != null) textMonotonicNs(io) else 0;
            var synthetic_ns: u128 = 0;
            var merger = try TextPostingRunMerger.init(allocator, io, run_paths);
            defer merger.deinit();

            const first_next_ordinal = streamingRunDerivedNextProbeOrdinal(context);
            const first_next_start = streamingRunDerivedNextSampleStart(context, first_next_ordinal);
            const first_next_child_probe_active = streamingRunDerivedNextChildProbeActive(context, first_next_ordinal);
            var first_next_probe = TextPostingRunMerger.NextProbe{};
            var next_run_record = try merger.nextWithProbe(if (first_next_child_probe_active) &first_next_probe else null);
            var next_run_record_sampled_ns = streamingRunDerivedSampleElapsedNs(context, first_next_start, streaming_run_derived_record_probe_stride);
            context.derived_next_sampled_ns += next_run_record_sampled_ns;
            addStreamingRunDerivedNextProbeNs(context, first_next_child_probe_active, first_next_probe);
            var source_index: usize = 0;
            while (next_run_record != null or source_index < synthetic_sources.len) {
                if (deadline.expired()) return core.Error.BudgetExceeded;

                if (source_index < synthetic_sources.len) {
                    const source = synthetic_sources[source_index];
                    if (next_run_record) |run_record| {
                        switch (std.mem.order(u8, source.term(), run_record.term())) {
                            .lt => {
                                const synthetic_start = if (timings != null) textMonotonicNs(io) else 0;
                                try writeTextRunDerivedSyntheticSourceTerm(context, source, doc_count, deadline);
                                if (timings) |t| {
                                    const elapsed = textElapsedNs(io, synthetic_start);
                                    synthetic_ns += elapsed;
                                    recordTextRunDerivedSyntheticTiming(t, source, elapsed);
                                }
                                source_index += 1;
                                continue;
                            },
                            .eq => return error.InvalidRecord,
                            .gt => {},
                        }
                    } else {
                        const synthetic_start = if (timings != null) textMonotonicNs(io) else 0;
                        try writeTextRunDerivedSyntheticSourceTerm(context, source, doc_count, deadline);
                        if (timings) |t| {
                            const elapsed = textElapsedNs(io, synthetic_start);
                            synthetic_ns += elapsed;
                            recordTextRunDerivedSyntheticTiming(t, source, elapsed);
                        }
                        source_index += 1;
                        continue;
                    }
                }

                const record = next_run_record orelse return error.InvalidRecord;
                const inline_singleton = try writeTextRunDerivedRecordFromRun(context, &record);
                if (inline_singleton) {
                    context.derived_inline_singleton_next_sampled_ns += next_run_record_sampled_ns;
                }
                const next_ordinal = streamingRunDerivedNextProbeOrdinal(context);
                const next_start = streamingRunDerivedNextSampleStart(context, next_ordinal);
                const next_child_probe_active = streamingRunDerivedNextChildProbeActive(context, next_ordinal);
                var next_probe = TextPostingRunMerger.NextProbe{};
                next_run_record = try merger.nextWithProbe(if (next_child_probe_active) &next_probe else null);
                next_run_record_sampled_ns = streamingRunDerivedSampleElapsedNs(context, next_start, streaming_run_derived_record_probe_stride);
                context.derived_next_sampled_ns += next_run_record_sampled_ns;
                addStreamingRunDerivedNextProbeNs(context, next_child_probe_active, next_probe);
            }
            if (timings) |t| {
                const elapsed = textElapsedNs(io, records_start);
                t.run_derived_regular_ns += if (elapsed >= synthetic_ns) elapsed - synthetic_ns else 0;
            }
        }

        fn writeTextRunCatalogFilesFromRuns(
            allocator: std.mem.Allocator,
            store: storage_mod.Store,
            run_paths: []const []const u8,
            summary_files: []const TextPostingRunSummaryFile,
            synthetic_sources: []const TextPostingSyntheticRunSource,
            run_paths_disjoint_term_ranges: bool,
            summary_stats: TextPostingRunSummaryStats,
            docs_view: *TextDocsFileView,
            meta: PersistentTextMeta,
            deadline: core.QueryDeadline,
            timings: ?*PersistentTextRebuildTimings,
        ) !void {
            const postings_path = try textPostingsPath(allocator, store);
            defer allocator.free(postings_path);
            const blocks_path = try textPostingBlocksPath(allocator, store);
            defer allocator.free(blocks_path);
            const impacts_path = try textPostingBlockImpactsPath(allocator, store);
            defer allocator.free(impacts_path);
            const top_hits_path = try textTermTopHitsPath(allocator, store);
            defer allocator.free(top_hits_path);
            const terms_path = try textTermsPath(allocator, store);
            defer allocator.free(terms_path);

            const postings_tmp_path = try tmpPathFor(allocator, postings_path);
            defer allocator.free(postings_tmp_path);
            const blocks_tmp_path = try tmpPathFor(allocator, blocks_path);
            defer allocator.free(blocks_tmp_path);
            const impacts_tmp_path = try tmpPathFor(allocator, impacts_path);
            defer allocator.free(impacts_tmp_path);
            const top_hits_tmp_path = try tmpPathFor(allocator, top_hits_path);
            defer allocator.free(top_hits_tmp_path);
            const terms_tmp_path = try tmpPathFor(allocator, terms_path);
            defer allocator.free(terms_tmp_path);
            errdefer std.Io.Dir.cwd().deleteFile(store.io, postings_tmp_path) catch {};
            errdefer std.Io.Dir.cwd().deleteFile(store.io, blocks_tmp_path) catch {};
            errdefer std.Io.Dir.cwd().deleteFile(store.io, impacts_tmp_path) catch {};
            errdefer std.Io.Dir.cwd().deleteFile(store.io, top_hits_tmp_path) catch {};
            errdefer std.Io.Dir.cwd().deleteFile(store.io, terms_tmp_path) catch {};

            {
                var postings_file = try std.Io.Dir.cwd().createFile(store.io, postings_tmp_path, .{ .read = true, .truncate = true });
                defer postings_file.close(store.io);
                var blocks_file = try std.Io.Dir.cwd().createFile(store.io, blocks_tmp_path, .{ .read = true, .truncate = true });
                defer blocks_file.close(store.io);
                var impacts_file = try std.Io.Dir.cwd().createFile(store.io, impacts_tmp_path, .{ .read = true, .truncate = true });
                defer impacts_file.close(store.io);
                var top_hits_file = try std.Io.Dir.cwd().createFile(store.io, top_hits_tmp_path, .{ .read = true, .truncate = true });
                defer top_hits_file.close(store.io);
                var terms_file = try std.Io.Dir.cwd().createFile(store.io, terms_tmp_path, .{ .read = true, .truncate = true });
                defer terms_file.close(store.io);

                const max_postings_body_bytes = std.math.mul(u64, summary_stats.posting_count, TextPostingRecord.encoded_len) catch return error.RecordTooLarge;
                var postings_writer = try TextBufferedWriter.init(allocator, store.io, postings_file, try textWriteBufferCapacity(try textPostingsFileSize(max_postings_body_bytes)));
                defer postings_writer.deinit();
                const blocks_records_offset = try textPostingBlockRecordOffset(summary_stats.term_count, 0);
                const blocks_file_size = try textPostingBlocksFileSize(@intCast(summary_stats.term_count), summary_stats.block_count);
                const blocks_offsets_offset = try textPostingBlockCheckpointTableOffset(summary_stats.block_count);
                const blocks_byte_offsets_offset = try textPostingBlockByteOffsetCheckpointTableOffset(summary_stats.term_count, summary_stats.block_count);
                var blocks_offsets_writer = try TextBufferedWriter.initAtOffset(allocator, store.io, blocks_file, try textWriteBufferCapacity(@max(@as(u64, 1), blocks_byte_offsets_offset - blocks_offsets_offset)), blocks_offsets_offset);
                defer blocks_offsets_writer.deinit();
                var blocks_writer = try TextBufferedWriter.initAtOffset(allocator, store.io, blocks_file, try textWriteBufferCapacity(@max(@as(u64, 1), blocks_offsets_offset - blocks_records_offset)), blocks_records_offset);
                defer blocks_writer.deinit();
                var blocks_byte_offsets_writer = try TextBufferedWriter.initAtOffset(allocator, store.io, blocks_file, try textWriteBufferCapacity(@max(@as(u64, 1), blocks_file_size - blocks_byte_offsets_offset)), blocks_byte_offsets_offset);
                defer blocks_byte_offsets_writer.deinit();

                const impacts_records_offset = try textPostingBlockImpactRecordOffset(summary_stats.term_count, 0);
                const impacts_file_size = try textPostingBlockImpactsFileSize(@intCast(summary_stats.term_count), summary_stats.block_count);
                var impacts_writer = try TextBufferedWriter.initAtOffset(allocator, store.io, impacts_file, try textWriteBufferCapacity(@max(@as(u64, 1), impacts_file_size - impacts_records_offset)), impacts_records_offset);
                defer impacts_writer.deinit();

                const top_hits_records_offset = try textTermTopHitRecordOffset(0);
                const top_hits_file_size = try textTermTopHitsFileSize(summary_stats.hit_count, summary_stats.top_hit_term_count);
                const top_hits_index_offset = try textTermTopHitTermIndexOffset(summary_stats.hit_count);
                var top_hits_index_writer = try TextBufferedWriter.initAtOffset(allocator, store.io, top_hits_file, try textWriteBufferCapacity(@max(@as(u64, 1), top_hits_file_size - top_hits_index_offset)), top_hits_index_offset);
                defer top_hits_index_writer.deinit();
                var top_hits_writer = try TextBufferedWriter.initAtOffset(allocator, store.io, top_hits_file, try textWriteBufferCapacity(@max(@as(u64, 1), top_hits_index_offset - top_hits_records_offset)), top_hits_records_offset);
                defer top_hits_writer.deinit();

                const terms_bytes_offset = try textTermsBytesOffset(@intCast(summary_stats.term_count));
                var terms_entry_writer = try TextBufferedWriter.init(allocator, store.io, terms_file, try textWriteBufferCapacity(terms_bytes_offset));
                defer terms_entry_writer.deinit();
                const term_bytes_buffer_size = @max(@as(u64, 1), summary_stats.term_bytes_len);
                var terms_bytes_writer = try TextBufferedWriter.initAtOffset(allocator, store.io, terms_file, try textWriteBufferCapacity(term_bytes_buffer_size), terms_bytes_offset);
                defer terms_bytes_writer.deinit();
                const terms_checkpoints_offset = try textTermByteOffsetCheckpointTableOffset(@intCast(summary_stats.term_count), summary_stats.term_bytes_len);
                const term_checkpoint_buffer_size = @max(@as(u64, 1), try textTermByteOffsetCheckpointTableBytes(summary_stats.term_count));
                var terms_checkpoints_writer = try TextBufferedWriter.initAtOffset(allocator, store.io, terms_file, try textWriteBufferCapacity(term_checkpoint_buffer_size), terms_checkpoints_offset);
                defer terms_checkpoints_writer.deinit();
                const terms_exception_rank_offset = try textTermExceptionRankCheckpointTableOffset(@intCast(summary_stats.term_count), summary_stats.term_bytes_len);
                const terms_exception_rank_buffer_size = @max(@as(u64, 1), try textTermExceptionRankCheckpointTableBytes(summary_stats.term_count));
                var terms_exception_rank_writer = try TextBufferedWriter.initAtOffset(allocator, store.io, terms_file, try textWriteBufferCapacity(terms_exception_rank_buffer_size), terms_exception_rank_offset);
                defer terms_exception_rank_writer.deinit();
                const terms_exception_membership_offset = try textTermExceptionMembershipBitsetOffset(@intCast(summary_stats.term_count), summary_stats.term_bytes_len);
                const terms_exception_membership_buffer_size = @max(@as(u64, 1), try textTermExceptionMembershipBytes(summary_stats.term_count));
                var terms_exception_membership_writer = try TextBufferedWriter.initAtOffset(allocator, store.io, terms_file, try textWriteBufferCapacity(terms_exception_membership_buffer_size), terms_exception_membership_offset);
                defer terms_exception_membership_writer.deinit();
                const terms_exception_payload_offset = try textTermExceptionPayloadTableOffset(@intCast(summary_stats.term_count), summary_stats.term_bytes_len);
                const terms_exception_payload_buffer_size = @max(@as(u64, 1), try textTermExceptionPayloadTableBytes(summary_stats.term_exception_count));
                var terms_exception_payload_writer = try TextBufferedWriter.initAtOffset(allocator, store.io, terms_file, try textWriteBufferCapacity(terms_exception_payload_buffer_size), terms_exception_payload_offset);
                defer terms_exception_payload_writer.deinit();
                const terms_singleton_count = try textTermSingletonPayloadCount(summary_stats.term_count, summary_stats.term_exception_count);
                const terms_singleton_checkpoints_offset = try textTermSingletonPayloadCheckpointTableOffset(@intCast(summary_stats.term_count), summary_stats.term_bytes_len, summary_stats.term_exception_count);
                const terms_singleton_checkpoint_buffer_size = @max(@as(u64, 1), try textTermSingletonPayloadCheckpointTableBytes(terms_singleton_count));
                var terms_singleton_checkpoints_writer = try TextBufferedWriter.initAtOffset(allocator, store.io, terms_file, try textWriteBufferCapacity(terms_singleton_checkpoint_buffer_size), terms_singleton_checkpoints_offset);
                defer terms_singleton_checkpoints_writer.deinit();
                const terms_singleton_payload_offset = try textTermSingletonPayloadStreamOffset(@intCast(summary_stats.term_count), summary_stats.term_bytes_len, summary_stats.term_exception_count);
                const terms_singleton_payload_max_bytes = std.math.mul(u64, terms_singleton_count, 5) catch return error.RecordTooLarge;
                var terms_singleton_payload_writer = try TextBufferedWriter.initAtOffset(allocator, store.io, terms_file, try textWriteBufferCapacity(@max(@as(u64, 1), terms_singleton_payload_max_bytes)), terms_singleton_payload_offset);
                defer terms_singleton_payload_writer.deinit();

                var postings_header_bytes: [TextPostingsHeader.encoded_len]u8 = undefined;
                encodeTextPostingsHeader(.{ .posting_count = summary_stats.posting_count, .body_bytes = 0 }, &postings_header_bytes);
                try postings_writer.append(&postings_header_bytes);

                var blocks_header_bytes: [TextPostingBlocksHeader.encoded_len]u8 = undefined;
                encodeTextPostingBlocksHeader(.{
                    .term_count = @intCast(summary_stats.term_count),
                    .posting_count = summary_stats.posting_count,
                    .block_count = summary_stats.block_count,
                    .block_size = persistent_posting_block_size,
                }, &blocks_header_bytes);
                try blocks_file.writePositionalAll(store.io, &blocks_header_bytes, 0);

                var impacts_header_bytes: [TextPostingBlockImpactsHeader.encoded_len]u8 = undefined;
                encodeTextPostingBlockImpactsHeader(.{
                    .term_count = @intCast(summary_stats.term_count),
                    .block_count = summary_stats.block_count,
                }, &impacts_header_bytes);
                try impacts_file.writePositionalAll(store.io, &impacts_header_bytes, 0);

                var top_hits_header_bytes: [TextTermTopHitsHeader.encoded_len]u8 = undefined;
                encodeTextTermTopHitsHeader(.{
                    .term_count = @intCast(summary_stats.term_count),
                    .hit_count = summary_stats.hit_count,
                    .hit_term_count = summary_stats.top_hit_term_count,
                    .capacity = persistent_term_top_hit_capacity,
                }, &top_hits_header_bytes);
                try top_hits_file.writePositionalAll(store.io, &top_hits_header_bytes, 0);

                var terms_header_bytes: [TextTermsHeader.encoded_len]u8 = undefined;
                encodeTextTermsHeader(.{
                    .term_count = @intCast(summary_stats.term_count),
                    .term_bytes = summary_stats.term_bytes_len,
                    .term_exception_count = summary_stats.term_exception_count,
                    .singleton_payload_bytes = 0,
                }, &terms_header_bytes);
                try terms_entry_writer.append(&terms_header_bytes);

                textBenchTrace("catalog_summary_reader_init_start");
                var summary_reader = TextPostingRunMergedSummaryReader.init(allocator, store.io, summary_files, meta.doc_count) catch |err| {
                    textBenchTrace("catalog_summary_reader_init_error");
                    return err;
                };
                defer summary_reader.deinit();

                var context = StreamingRunDerivedFilesContext{
                    .allocator = allocator,
                    .io = store.io,
                    .postings_writer = &postings_writer,
                    .blocks_offsets_writer = &blocks_offsets_writer,
                    .blocks_byte_offsets_writer = &blocks_byte_offsets_writer,
                    .blocks_writer = &blocks_writer,
                    .impacts_writer = &impacts_writer,
                    .top_hits_index_writer = &top_hits_index_writer,
                    .top_hits_writer = &top_hits_writer,
                    .terms_entry_writer = &terms_entry_writer,
                    .terms_bytes_writer = &terms_bytes_writer,
                    .terms_checkpoints_writer = &terms_checkpoints_writer,
                    .terms_exception_rank_writer = &terms_exception_rank_writer,
                    .terms_exception_membership_writer = &terms_exception_membership_writer,
                    .terms_exception_payload_writer = &terms_exception_payload_writer,
                    .terms_singleton_checkpoints_writer = &terms_singleton_checkpoints_writer,
                    .terms_singleton_payload_writer = &terms_singleton_payload_writer,
                    .summary_reader = &summary_reader,
                    .summary_count = summary_stats.term_count,
                    .docs_view = docs_view,
                    .meta = meta,
                    .avg_doc_len = persistentAvgDocLen(meta),
                    .block_size = persistent_posting_block_size,
                    .collect_derived_shape_probes = timings != null,
                };
                defer context.deinit();
                if (summary_stats.regular_constant_top_hit_term_count != 0) {
                    textBenchTrace("catalog_global_doc_rank_start");
                    ensureStreamingRunDerivedGlobalDocRank(&context, deadline) catch |err| {
                        textBenchTrace("catalog_global_doc_rank_error");
                        return err;
                    };
                    textBenchTrace("catalog_global_doc_rank_done");
                } else if (summary_stats.top_hit_term_count != 0) {
                    textBenchTrace("catalog_virtual_top_docs_start");
                    ensureStreamingRunDerivedVirtualAllDocsTopDocs(&context, deadline) catch |err| {
                        textBenchTrace("catalog_virtual_top_docs_error");
                        return err;
                    };
                    textBenchTrace("catalog_virtual_top_docs_done");
                }
                const dense_top_hit_precompute_start = if (timings != null) textMonotonicNs(store.io) else 0;
                textBenchTrace("catalog_dense_precompute_start");
                precomputeStreamingRunDerivedDenseAllDocsTopHits(&context, synthetic_sources, deadline) catch |err| {
                    textBenchTrace("catalog_dense_precompute_error");
                    return err;
                };
                if (timings) |t| {
                    t.run_derived_dense_ns += textElapsedNs(store.io, dense_top_hit_precompute_start);
                }
                textBenchTrace("catalog_records_start");
                writeTextRunDerivedRecordsAndSyntheticTerms(allocator, store.io, run_paths, synthetic_sources, run_paths_disjoint_term_ranges, meta.doc_count, deadline, &context, timings) catch |err| {
                    textBenchTrace("catalog_records_error");
                    return err;
                };
                textBenchTrace("catalog_finish_term_start");
                finishStreamingRunDerivedTerm(&context) catch |err| {
                    textBenchTrace("catalog_finish_term_error");
                    return err;
                };
                textBenchTrace("catalog_finish_exception_membership_start");
                finishStreamingRunExceptionMembership(&context) catch |err| {
                    textBenchTrace("catalog_finish_exception_membership_error");
                    return err;
                };
                textBenchTrace("catalog_summary_reader_drain_start");
                if ((summary_reader.nextRecord() catch |err| {
                    textBenchTrace("catalog_summary_reader_drain_error");
                    return err;
                }) != null) {
                    textBenchTrace("catalog_summary_reader_drain_extra_record");
                    return error.InvalidRecord;
                }
                textBenchTrace("catalog_summary_reader_drain_done");
                if (timings) |t| {
                    t.run_derived_next_sampled_ns = context.derived_next_sampled_ns;
                    t.run_derived_next_reader_sampled_ns = context.derived_next_reader_sampled_ns;
                    t.run_derived_next_queue_sampled_ns = context.derived_next_queue_sampled_ns;
                    t.run_derived_next_child_probe_count = context.derived_next_child_probe_count;
                    t.run_derived_next_queue_compare_count = context.derived_next_queue_compare_count;
                    t.run_derived_inline_singleton_next_sampled_ns = context.derived_inline_singleton_next_sampled_ns;
                    t.run_derived_inline_singleton_publish_sampled_ns = context.derived_inline_singleton_publish_sampled_ns;
                    t.run_derived_encode_sampled_ns = context.derived_encode_sampled_ns;
                    t.run_derived_write_sampled_ns = context.derived_write_sampled_ns;
                    t.run_derived_block_stats_sampled_ns = context.derived_block_stats_sampled_ns;
                    t.run_derived_top_hit_sampled_ns = context.derived_top_hit_sampled_ns;
                    t.run_derived_block_flush_sampled_ns = context.derived_block_flush_sampled_ns;
                    t.run_derived_global_doc_rank_ns = context.derived_global_doc_rank_ns;
                    t.run_derived_virtual_top_docs_ns = context.derived_virtual_top_docs_ns;
                    t.run_virtual_all_docs_top_hit_cache_doc_scans = context.virtual_all_docs_top_hit_cache_doc_scans;
                    t.run_derived_inline_singleton_terms = context.derived_inline_singleton_terms;
                    t.run_derived_virtual_terms = context.derived_virtual_terms;
                    t.run_derived_dense_terms = context.derived_dense_terms;
                    t.run_derived_block_terms = context.derived_block_terms;
                    t.run_derived_inline_singleton_records = context.derived_inline_singleton_records;
                    t.run_derived_virtual_records = context.derived_virtual_records;
                    t.run_derived_dense_records = context.derived_dense_records;
                    t.run_derived_block_records = context.derived_block_records;
                    t.run_derived_top_hit_block_evals = context.top_hit_block_evals;
                    t.run_derived_top_hit_block_skips = context.top_hit_block_skips;
                    t.run_derived_top_hit_block_not_full_evals = context.top_hit_block_not_full_evals;
                    t.run_derived_top_hit_block_ready_evals = context.top_hit_block_ready_evals;
                    t.run_derived_top_hit_block_upper_lt_2x_worst = context.top_hit_block_upper_lt_2x_worst;
                    t.run_derived_top_hit_block_upper_lt_4x_worst = context.top_hit_block_upper_lt_4x_worst;
                    t.run_derived_top_hit_block_upper_gte_4x_worst = context.top_hit_block_upper_gte_4x_worst;
                    t.run_derived_top_hit_candidate_evals = context.top_hit_candidate_evals;
                    t.run_derived_top_hit_doc_reads = context.top_hit_doc_reads;
                    t.run_derived_top_hit_regular_candidate_evals = context.top_hit_regular_candidate_evals;
                    t.run_derived_top_hit_regular_doc_reads = context.top_hit_regular_doc_reads;
                    t.run_derived_top_hit_virtual_candidate_evals = context.top_hit_virtual_candidate_evals;
                    t.run_derived_top_hit_virtual_doc_reads = context.top_hit_virtual_doc_reads;
                    t.run_derived_top_hit_dense_candidate_evals = context.top_hit_dense_candidate_evals;
                    t.run_derived_top_hit_dense_doc_reads = context.top_hit_dense_doc_reads;
                    t.run_derived_top_hit_dense_scan_records = context.top_hit_dense_scan_records;
                    t.run_derived_top_hit_dense_freq_bound_skips = context.top_hit_dense_freq_bound_skips;
                    t.run_derived_top_hit_dense_freq_bound_skip_runs = context.top_hit_dense_freq_bound_skip_runs;
                    t.run_derived_top_hit_regular_term_count = context.top_hit_regular_term_count;
                    t.run_derived_top_hit_regular_doc_read_term_count = context.top_hit_regular_doc_read_term_count;
                    const doc_read_heavy_terms = context.top_hit_regular_doc_read_heavy_terms[0..context.top_hit_regular_doc_read_heavy_term_count];
                    const candidate_heavy_terms = context.top_hit_regular_candidate_heavy_terms[0..context.top_hit_regular_candidate_heavy_term_count];
                    t.run_derived_top_hit_regular_top1_doc_reads = try textTopHitRegularProbeDocReadsSum(doc_read_heavy_terms, 1);
                    t.run_derived_top_hit_regular_top4_doc_reads = try textTopHitRegularProbeDocReadsSum(doc_read_heavy_terms, 4);
                    t.run_derived_top_hit_regular_top8_doc_reads = try textTopHitRegularProbeDocReadsSum(doc_read_heavy_terms, 8);
                    t.run_derived_top_hit_regular_top1_candidate_evals = try textTopHitRegularProbeCandidateEvalsSum(candidate_heavy_terms, 1);
                    t.run_derived_top_hit_regular_top4_candidate_evals = try textTopHitRegularProbeCandidateEvalsSum(candidate_heavy_terms, 4);
                    t.run_derived_top_hit_regular_top8_candidate_evals = try textTopHitRegularProbeCandidateEvalsSum(candidate_heavy_terms, 8);
                    if (doc_read_heavy_terms.len != 0) {
                        t.run_derived_top_hit_regular_heaviest_doc_read_term_postings = doc_read_heavy_terms[0].postings_count;
                        t.run_derived_top_hit_regular_heaviest_doc_read_term_block_evals = doc_read_heavy_terms[0].block_evals;
                        t.run_derived_top_hit_regular_heaviest_doc_read_term_candidate_evals = doc_read_heavy_terms[0].candidate_evals;
                    }
                    t.run_derived_top_hit_regular_constant_terms = context.top_hit_regular_constant_terms;
                    t.run_derived_top_hit_regular_constant_resolved_terms = context.top_hit_regular_constant_resolved_terms;
                    t.run_derived_top_hit_regular_constant_unresolved_terms = context.top_hit_regular_constant_unresolved_terms;
                    t.run_derived_top_hit_regular_constant_candidate_evals = context.top_hit_regular_constant_candidate_evals;
                    t.run_derived_top_hit_regular_constant_doc_reads = context.top_hit_regular_constant_doc_reads;
                    t.run_derived_top_hit_regular_nonconstant_candidate_evals = context.top_hit_regular_nonconstant_candidate_evals;
                    t.run_derived_top_hit_regular_nonconstant_doc_reads = context.top_hit_regular_nonconstant_doc_reads;
                    t.run_derived_top_hit_regular_constant_resolved_candidate_skips = context.top_hit_regular_constant_resolved_candidate_skips;
                }
                if (context.summary_index != summary_stats.term_count or
                    context.postings_written != summary_stats.posting_count or
                    context.blocks_written != summary_stats.block_count or
                    context.block_index_base != summary_stats.block_count or
                    context.impacts_written != summary_stats.block_count or
                    context.hits_written != summary_stats.hit_count or
                    context.hit_terms_written != summary_stats.top_hit_term_count or
                    context.term_entries_written != summary_stats.term_count or
                    context.term_exceptions_written != summary_stats.term_exception_count or
                    context.term_exception_rank_checkpoints_written != (try textTermExceptionRankCheckpointCount(summary_stats.term_count)) or
                    context.term_exception_membership_bytes_written != (try textTermExceptionMembershipBytes(summary_stats.term_count)) or
                    context.term_singletons_written != terms_singleton_count or
                    context.term_bytes_written != summary_stats.term_bytes_len or
                    context.term_byte_checkpoints_written != (try textTermByteOffsetCheckpointCount(summary_stats.term_count)) or
                    context.term_singleton_checkpoints_written != (try textTermSingletonPayloadCheckpointCount(terms_singleton_count)) or
                    context.block_offset_checkpoints_written != (try textPostingBlockCheckpointCount(summary_stats.term_count)) or
                    context.block_byte_offset_checkpoints_written != (try textPostingBlockByteOffsetCheckpointCount(summary_stats.block_count)))
                {
                    if (textBenchTraceEnabled()) {
                        std.debug.print(
                            "text_trace=catalog_counter_mismatch_a summary_index={}/{} postings={}/{} blocks={}/{} block_index_base={} impacts={}/{} hits={}/{} hit_terms={}/{} term_entries={}/{} term_exceptions={}/{}\n",
                            .{
                                context.summary_index,
                                summary_stats.term_count,
                                context.postings_written,
                                summary_stats.posting_count,
                                context.blocks_written,
                                summary_stats.block_count,
                                context.block_index_base,
                                context.impacts_written,
                                summary_stats.block_count,
                                context.hits_written,
                                summary_stats.hit_count,
                                context.hit_terms_written,
                                summary_stats.top_hit_term_count,
                                context.term_entries_written,
                                summary_stats.term_count,
                                context.term_exceptions_written,
                                summary_stats.term_exception_count,
                            },
                        );
                        std.debug.print(
                            "text_trace=catalog_counter_mismatch_b exception_rank_checkpoints={}/{} exception_membership_bytes={}/{} term_singletons={}/{} term_bytes={}/{} term_byte_checkpoints={}/{} singleton_checkpoints={}/{} block_offset_checkpoints={}/{} block_byte_offset_checkpoints={}/{}\n",
                            .{
                                context.term_exception_rank_checkpoints_written,
                                try textTermExceptionRankCheckpointCount(summary_stats.term_count),
                                context.term_exception_membership_bytes_written,
                                try textTermExceptionMembershipBytes(summary_stats.term_count),
                                context.term_singletons_written,
                                terms_singleton_count,
                                context.term_bytes_written,
                                summary_stats.term_bytes_len,
                                context.term_byte_checkpoints_written,
                                try textTermByteOffsetCheckpointCount(summary_stats.term_count),
                                context.term_singleton_checkpoints_written,
                                try textTermSingletonPayloadCheckpointCount(terms_singleton_count),
                                context.block_offset_checkpoints_written,
                                try textPostingBlockCheckpointCount(summary_stats.term_count),
                                context.block_byte_offset_checkpoints_written,
                                try textPostingBlockByteOffsetCheckpointCount(summary_stats.block_count),
                            },
                        );
                    }
                    return error.InvalidRecord;
                }

                const flush_start = if (timings != null) textMonotonicNs(store.io) else 0;
                textBenchTrace("catalog_flush_start");
                try postings_writer.flush();
                encodeTextPostingsHeader(.{ .posting_count = summary_stats.posting_count, .body_bytes = context.postings_body_bytes_written }, &postings_header_bytes);
                try postings_file.writePositionalAll(store.io, &postings_header_bytes, 0);
                try blocks_offsets_writer.flush();
                try blocks_writer.flush();
                try blocks_byte_offsets_writer.flush();
                try impacts_writer.flush();
                try top_hits_index_writer.flush();
                try top_hits_writer.flush();
                try terms_entry_writer.flush();
                try terms_bytes_writer.flush();
                try terms_checkpoints_writer.flush();
                try terms_exception_rank_writer.flush();
                try terms_exception_membership_writer.flush();
                try terms_exception_payload_writer.flush();
                try terms_singleton_checkpoints_writer.flush();
                try terms_singleton_payload_writer.flush();
                encodeTextTermsHeader(.{
                    .term_count = @intCast(summary_stats.term_count),
                    .term_bytes = summary_stats.term_bytes_len,
                    .term_exception_count = summary_stats.term_exception_count,
                    .singleton_payload_bytes = context.term_singleton_payload_bytes_written,
                }, &terms_header_bytes);
                try terms_file.writePositionalAll(store.io, &terms_header_bytes, 0);
                if (timings) |t| {
                    t.run_derived_tmp_postings_bytes = try regularFileSize(store, postings_file);
                    t.run_derived_tmp_terms_bytes = try regularFileSize(store, terms_file);
                    t.run_derived_tmp_blocks_bytes = try regularFileSize(store, blocks_file);
                    t.run_derived_tmp_impacts_bytes = try regularFileSize(store, impacts_file);
                    t.run_derived_tmp_top_hits_bytes = try regularFileSize(store, top_hits_file);
                    var tmp_total = t.run_derived_tmp_postings_bytes;
                    tmp_total = std.math.add(u64, tmp_total, t.run_derived_tmp_terms_bytes) catch return error.RecordTooLarge;
                    tmp_total = std.math.add(u64, tmp_total, t.run_derived_tmp_blocks_bytes) catch return error.RecordTooLarge;
                    tmp_total = std.math.add(u64, tmp_total, t.run_derived_tmp_impacts_bytes) catch return error.RecordTooLarge;
                    tmp_total = std.math.add(u64, tmp_total, t.run_derived_tmp_top_hits_bytes) catch return error.RecordTooLarge;
                    t.run_derived_tmp_total_bytes = tmp_total;
                }
                if (textOptionsNeedSync(store)) {
                    try postings_file.sync(store.io);
                    try blocks_file.sync(store.io);
                    try impacts_file.sync(store.io);
                    try top_hits_file.sync(store.io);
                    try terms_file.sync(store.io);
                }
                if (timings) |t| t.run_derived_flush_ns += textElapsedNs(store.io, flush_start);
            }

            const rename_start = if (timings != null) textMonotonicNs(store.io) else 0;
            try renameReplace(store.io, postings_tmp_path, postings_path);
            try renameReplace(store.io, blocks_tmp_path, blocks_path);
            try renameReplace(store.io, impacts_tmp_path, impacts_path);
            try renameReplace(store.io, top_hits_tmp_path, top_hits_path);
            try renameReplace(store.io, terms_tmp_path, terms_path);
            if (timings) |t| t.run_derived_rename_ns += textElapsedNs(store.io, rename_start);
        }
    };
}
