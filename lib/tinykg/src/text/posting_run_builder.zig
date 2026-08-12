/// Complete posting-run construction state machine. The Text facade supplies
/// format, summary, merge, timing, and token-frequency capabilities while this
/// owner controls candidate lifetime, chunk materialization, temporary runs,
/// fan-in compaction, and cleanup.
pub fn PostingRunBuilder(comptime Ops: type) type {
    return struct {
        const std = Ops.std;
        const TextBufferedWriter = Ops.TextBufferedWriter_dep;
        const DenseAllDocsFreqStreamSizeStats = Ops.DenseAllDocsFreqStreamSizeStats_dep;
        const appendDenseAllDocsFreqStreamFreqs = Ops.appendDenseAllDocsFreqStreamFreqs_dep;
        const appendDenseAllDocsFreqStreamFreqsWithStats = Ops.appendDenseAllDocsFreqStreamFreqsWithStats_dep;
        const denseAllDocsFreqStreamSizeStatsForFreqs = Ops.denseAllDocsFreqStreamSizeStatsForFreqs_dep;
        const validateDenseAllDocsTextFreq = Ops.validateDenseAllDocsTextFreq_dep;
        const default_max_token_bytes = Ops.default_max_token_bytes_dep;
        const TextPostingRunSummaryFile = Ops.TextPostingRunSummaryFile_dep;
        const CollectTextPostingRunSummaryContext = Ops.CollectTextPostingRunSummaryContext_dep;
        const FieldTermFreq = Ops.FieldTermFreq_dep;
        const TextPostingRecord = Ops.TextPostingRecord_dep;
        const TextPostingRunChunkRecord = Ops.TextPostingRunChunkRecord_dep;
        const TextPostingRunFrontCodedWriter = Ops.TextPostingRunFrontCodedWriter_dep;
        const TextPostingRunRecord = Ops.TextPostingRunRecord_dep;
        const TextPostingRunSummaryStats = Ops.TextPostingRunSummaryStats_dep;
        const TextPostingRunSummaryWriter = Ops.TextPostingRunSummaryWriter_dep;
        const TextPostingRunTermSummaryRecord = Ops.TextPostingRunTermSummaryRecord_dep;
        const TextRebuildTextFreqCache = Ops.TextRebuildTextFreqCache_dep;
        const text_posting_run_chunk_records = Ops.text_posting_run_chunk_records_dep;
        const termSortPrefixKey = Ops.termSortPrefixKey_dep;
        const termSortTailKey = Ops.termSortTailKey_dep;
        const textMonotonicNs = Ops.textMonotonicNs_dep;
        const textElapsedNs = Ops.textElapsedNs_dep;
        const text_write_buffer_bytes = Ops.text_write_buffer_bytes_dep;
        const appendTextPostingRunSummaryRecord = Ops.appendTextPostingRunSummaryRecord_dep;
        const textBenchTraceRunBuilder = Ops.textBenchTraceRunBuilder_dep;
        const text_posting_run_direct_merge_fan_in = Ops.text_posting_run_direct_merge_fan_in_dep;
        const writeMergedTextPostingRunWithSummary = Ops.writeMergedTextPostingRunWithSummary_dep;
        const text_posting_run_merge_fan_in = Ops.text_posting_run_merge_fan_in_dep;
        const collectTextPostingRunTermSummariesFromFilesToFile = Ops.collectTextPostingRunTermSummariesFromFilesToFile_dep;
        const writeSortedTextPostingRunChunkWithSummary = Ops.writeSortedTextPostingRunChunkWithSummary_dep;
        const collectTextPostingRunSummaryFields = Ops.collectTextPostingRunSummaryFields_dep;
        const validateTextPostingFields = Ops.validateTextPostingFields_dep;
        const textPostingRunChunkRecordLessThan = Ops.textPostingRunChunkRecordLessThan_dep;
        const text_posting_run_record_long_term_threshold = Ops.text_posting_run_record_long_term_threshold_dep;
        const flushTextPostingRunSummary = Ops.flushTextPostingRunSummary_dep;
        const VirtualAllDocsRunCandidate = struct {
            text_freq: u32,
            last_seen_doc_id: u64,
        };

        pub const VariableAllDocsFreqSlice = union(enum) {
            narrow: []const u8,
            wide: []const u16,

            pub fn len(self: VariableAllDocsFreqSlice) usize {
                return switch (self) {
                    .narrow => |freqs| freqs.len,
                    .wide => |freqs| freqs.len,
                };
            }

            pub fn at(self: VariableAllDocsFreqSlice, index: usize) u32 {
                return switch (self) {
                    .narrow => |freqs| freqs[index],
                    .wide => |freqs| freqs[index],
                };
            }

            pub fn boundedRunLenLeq(self: VariableAllDocsFreqSlice, start: usize, max_freq: u32, max_run: usize) usize {
                const total_len = self.len();
                std.debug.assert(start < total_len);
                var index = start;
                const requested_end = std.math.add(usize, start, max_run) catch total_len;
                const end = @min(total_len, requested_end);
                while (index < end and self.at(index) <= max_freq) : (index += 1) {}
                return index - start;
            }

            pub fn elementSize(self: VariableAllDocsFreqSlice) usize {
                return switch (self) {
                    .narrow => 1,
                    .wide => 2,
                };
            }

            pub fn appendDenseAllDocsFreqStream(self: VariableAllDocsFreqSlice, writer: *TextBufferedWriter) !u64 {
                return switch (self) {
                    .narrow => |freqs| appendDenseAllDocsFreqStreamFreqs(writer, freqs),
                    .wide => |freqs| appendDenseAllDocsFreqStreamFreqs(writer, freqs),
                };
            }

            pub fn appendDenseAllDocsFreqStreamWithStats(self: VariableAllDocsFreqSlice, writer: *TextBufferedWriter, stats: DenseAllDocsFreqStreamSizeStats) !u64 {
                return switch (self) {
                    .narrow => |freqs| appendDenseAllDocsFreqStreamFreqsWithStats(writer, freqs, stats),
                    .wide => |freqs| appendDenseAllDocsFreqStreamFreqsWithStats(writer, freqs, stats),
                };
            }

            pub fn sizeStats(self: VariableAllDocsFreqSlice) !DenseAllDocsFreqStreamSizeStats {
                return switch (self) {
                    .narrow => |freqs| denseAllDocsFreqStreamSizeStatsForFreqs(freqs),
                    .wide => |freqs| denseAllDocsFreqStreamSizeStatsForFreqs(freqs),
                };
            }
        };

        const VariableAllDocsFreqBuffer = union(enum) {
            narrow: std.ArrayList(u8),
            wide: std.ArrayList(u16),

            pub fn deinit(self: *VariableAllDocsFreqBuffer, allocator: std.mem.Allocator) void {
                switch (self.*) {
                    .narrow => |*freqs| freqs.deinit(allocator),
                    .wide => |*freqs| freqs.deinit(allocator),
                }
            }

            pub fn len(self: VariableAllDocsFreqBuffer) usize {
                return switch (self) {
                    .narrow => |freqs| freqs.items.len,
                    .wide => |freqs| freqs.items.len,
                };
            }

            pub fn at(self: VariableAllDocsFreqBuffer, index: usize) u32 {
                return switch (self) {
                    .narrow => |freqs| freqs.items[index],
                    .wide => |freqs| freqs.items[index],
                };
            }

            pub fn elementSize(self: VariableAllDocsFreqBuffer) usize {
                return switch (self) {
                    .narrow => 1,
                    .wide => 2,
                };
            }

            pub fn slice(self: VariableAllDocsFreqBuffer) VariableAllDocsFreqSlice {
                return switch (self) {
                    .narrow => |freqs| .{ .narrow = freqs.items },
                    .wide => |freqs| .{ .wide = freqs.items },
                };
            }

            pub fn appendDenseAllDocsFreqStream(self: VariableAllDocsFreqBuffer, writer: *TextBufferedWriter) !u64 {
                return self.slice().appendDenseAllDocsFreqStream(writer);
            }

            pub fn ensureTotalCapacityPrecise(self: *VariableAllDocsFreqBuffer, allocator: std.mem.Allocator, capacity: usize) !void {
                switch (self.*) {
                    .narrow => |*freqs| try freqs.ensureTotalCapacityPrecise(allocator, capacity),
                    .wide => |*freqs| try freqs.ensureTotalCapacityPrecise(allocator, capacity),
                }
            }

            pub fn ensureWide(self: *VariableAllDocsFreqBuffer, allocator: std.mem.Allocator) !void {
                switch (self.*) {
                    .wide => {},
                    .narrow => |*narrow| {
                        var wide = std.ArrayList(u16).empty;
                        errdefer wide.deinit(allocator);
                        try wide.ensureTotalCapacityPrecise(allocator, narrow.capacity);
                        for (narrow.items) |freq| wide.appendAssumeCapacity(freq);
                        narrow.deinit(allocator);
                        self.* = .{ .wide = wide };
                    },
                }
            }

            pub fn appendAssumeCapacity(self: *VariableAllDocsFreqBuffer, freq: u32) !void {
                const validated = try validateDenseAllDocsTextFreq(freq);
                switch (self.*) {
                    .narrow => |*freqs| {
                        if (validated > std.math.maxInt(u8)) return error.InvalidRecord;
                        freqs.appendAssumeCapacity(@intCast(validated));
                    },
                    .wide => |*freqs| freqs.appendAssumeCapacity(@intCast(validated)),
                }
            }

            pub fn append(self: *VariableAllDocsFreqBuffer, allocator: std.mem.Allocator, freq: u32) !void {
                const validated = try validateDenseAllDocsTextFreq(freq);
                if (validated > std.math.maxInt(u8)) try self.ensureWide(allocator);
                switch (self.*) {
                    .narrow => |*freqs| try freqs.append(allocator, @intCast(validated)),
                    .wide => |*freqs| try freqs.append(allocator, @intCast(validated)),
                }
            }
        };

        const VariableAllDocsRunCandidate = struct {
            freqs: VariableAllDocsFreqBuffer = .{ .narrow = .empty },
            last_seen_doc_id: u64,

            pub fn deinit(self: *VariableAllDocsRunCandidate, allocator: std.mem.Allocator) void {
                self.freqs.deinit(allocator);
            }
        };

        pub const AllDocsRunCandidate = union(enum) {
            virtual: VirtualAllDocsRunCandidate,
            variable: VariableAllDocsRunCandidate,

            pub fn deinit(self: *AllDocsRunCandidate, allocator: std.mem.Allocator) void {
                switch (self.*) {
                    .virtual => {},
                    .variable => |*candidate| candidate.deinit(allocator),
                }
            }
        };

        const text_posting_run_variable_all_docs_gb100_doc_budget: u64 = 182_000_000;
        const text_posting_run_variable_all_docs_gb100_term_budget: u64 = 32;
        pub const text_posting_run_variable_all_docs_max_freq_cells: u64 =
            text_posting_run_variable_all_docs_gb100_doc_budget * text_posting_run_variable_all_docs_gb100_term_budget;
        pub const text_posting_run_all_docs_candidate_sweep_interval: u64 = 4096;

        const CandidateByteSet = [4]u64;
        const CandidateByteFilter = [default_max_token_bytes + 1]CandidateByteSet;
        const text_posting_append_probe_sample_mask: u64 = 0xfff;
        const all_docs_candidate_cache_slots = 4096;
        comptime {
            if (!std.math.isPowerOfTwo(all_docs_candidate_cache_slots)) {
                @compileError("all-doc candidate cache slots must stay a power of two");
            }
        }
        const text_posting_run_chunk_term_cache_slots = 1024;
        comptime {
            if (!std.math.isPowerOfTwo(text_posting_run_chunk_term_cache_slots)) {
                @compileError("text posting run chunk term cache slots must stay a power of two");
            }
        }

        pub const AllDocsCandidateCacheSlot = struct {
            generation: u64 = 0,
            term_cache_key: u64 = 0,
            term_len: u8 = 0,
            key: []const u8 = &.{},
            value: *AllDocsRunCandidate = undefined,
        };

        const TextPostingRunChunkTermCacheSlot = struct {
            term_sort_prefix: u64 = 0,
            term_len: u8 = 0,
            term_offset: u32 = 0,
            occupied: bool = false,
        };

        fn setCandidateByte(filter: *CandidateByteFilter, len: usize, byte: u8) void {
            filter[len][byte / 64] |= @as(u64, 1) << @intCast(byte % 64);
        }

        fn candidateByteSetContains(set: CandidateByteSet, byte: u8) bool {
            return (set[byte / 64] & (@as(u64, 1) << @intCast(byte % 64))) != 0;
        }

        pub const TextPostingSyntheticRunSource = union(enum) {
            virtual_all_docs: struct {
                term: []const u8,
                text_freq: u32,
            },
            variable_all_docs: struct {
                term: []const u8,
                freqs: VariableAllDocsFreqBuffer,
                freq_stats: DenseAllDocsFreqStreamSizeStats,
            },

            pub fn term(self: TextPostingSyntheticRunSource) []const u8 {
                return switch (self) {
                    .virtual_all_docs => |source| source.term,
                    .variable_all_docs => |source| source.term,
                };
            }

            pub fn deinit(self: *TextPostingSyntheticRunSource, allocator: std.mem.Allocator) void {
                switch (self.*) {
                    .virtual_all_docs => |source| allocator.free(source.term),
                    .variable_all_docs => |*source| {
                        allocator.free(source.term);
                        source.freqs.deinit(allocator);
                    },
                }
            }
        };

        fn textPostingSyntheticRunSourceLessThan(_: void, lhs: TextPostingSyntheticRunSource, rhs: TextPostingSyntheticRunSource) bool {
            return std.mem.order(u8, lhs.term(), rhs.term()) == .lt;
        }

        const RepeatedTextTermSegment = struct {
            doc_ids: []const u32,
            text_freq: u32,
        };

        const RepeatedTextSegmentCursor = struct {
            segment: RepeatedTextTermSegment,
            index: usize = 0,
        };

        fn compareRepeatedTextSegmentCursor(_: void, lhs: RepeatedTextSegmentCursor, rhs: RepeatedTextSegmentCursor) std.math.Order {
            const lhs_doc = lhs.segment.doc_ids[lhs.index];
            const rhs_doc = rhs.segment.doc_ids[rhs.index];
            return switch (std.math.order(lhs_doc, rhs_doc)) {
                .eq => std.math.order(lhs.segment.text_freq, rhs.segment.text_freq),
                else => |order| order,
            };
        }

        fn stringSliceLessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
            return std.mem.order(u8, lhs, rhs) == .lt;
        }

        const repeated_text_direct_run_terms_per_file: usize = 16 * 1024;

        pub const TextPostingRunBuilder = struct {
            allocator: std.mem.Allocator,
            io: std.Io,
            base_path: []const u8,
            measure_chunks: bool = false,
            run_paths: std.ArrayList([]u8) = .empty,
            run_summaries: std.ArrayList(TextPostingRunSummaryFile) = .empty,
            chunk: std.ArrayList(TextPostingRunChunkRecord) = .empty,
            chunk_term_bytes: std.ArrayList(u8) = .empty,
            chunk_term_cache: [text_posting_run_chunk_term_cache_slots]TextPostingRunChunkTermCacheSlot = [_]TextPostingRunChunkTermCacheSlot{.{}} ** text_posting_run_chunk_term_cache_slots,
            chunk_sort_ns: u128 = 0,
            chunk_write_ns: u128 = 0,
            chunk_count: u64 = 0,
            chunk_records: u64 = 0,
            chunk_peak_record_bytes: u64 = 0,
            chunk_peak_term_bytes: u64 = 0,
            chunk_peak_scratch_bytes: u64 = 0,
            chunk_peak_record_capacity_bytes: u64 = 0,
            chunk_peak_term_capacity_bytes: u64 = 0,
            chunk_peak_scratch_capacity_bytes: u64 = 0,
            run_record_term_bytes: u64 = 0,
            run_record_inline_capacity_bytes: u64 = 0,
            run_record_term_slack_bytes: u64 = 0,
            run_record_term_cache_hits: u64 = 0,
            run_record_term_cache_saved_bytes: u64 = 0,
            run_record_long_term_count: u64 = 0,
            run_record_max_term_len: u64 = 0,
            inline_singleton_materialized_terms: u64 = 0,
            inline_singleton_materialized_records: u64 = 0,
            inline_singleton_materialized_bytes: u64 = 0,
            docs_posting_append_materialize_ns: u128 = 0,
            docs_posting_append_sweep_ns: u128 = 0,
            docs_posting_append_regular_sampled_ns: u128 = 0,
            docs_posting_append_candidate_lookup_sampled_ns: u128 = 0,
            docs_posting_append_candidate_hit_sampled_ns: u128 = 0,
            docs_posting_append_virtual_hit_sampled_ns: u128 = 0,
            docs_posting_append_variable_hit_sampled_ns: u128 = 0,
            docs_posting_append_variable_freq_sampled_ns: u128 = 0,
            docs_posting_append_term_count: u64 = 0,
            docs_posting_append_regular_record_count: u64 = 0,
            docs_posting_append_virtual_candidate_put_count: u64 = 0,
            docs_posting_append_virtual_candidate_hit_count: u64 = 0,
            docs_posting_append_variable_candidate_hit_count: u64 = 0,
            docs_posting_append_variable_freq_append_count: u64 = 0,
            docs_posting_append_candidate_filter_skip_count: u64 = 0,
            docs_posting_append_candidate_lookup_count: u64 = 0,
            docs_posting_append_candidate_cache_hit_count: u64 = 0,
            docs_posting_append_candidate_miss_count: u64 = 0,
            docs_posting_append_candidate_regularized_hit_count: u64 = 0,
            docs_posting_append_materialize_call_count: u64 = 0,
            docs_posting_append_sweep_count: u64 = 0,
            docs_posting_append_regular_sample_count: u64 = 0,
            docs_posting_append_candidate_lookup_sample_count: u64 = 0,
            docs_posting_append_candidate_hit_sample_count: u64 = 0,
            docs_posting_append_virtual_hit_sample_count: u64 = 0,
            docs_posting_append_variable_hit_sample_count: u64 = 0,
            docs_posting_append_variable_freq_sample_count: u64 = 0,
            doc_count: u64 = 0,
            all_docs_candidates: std.StringHashMap(AllDocsRunCandidate),
            all_docs_candidate_cache_generation: u64 = 1,
            all_docs_candidate_cache: [all_docs_candidate_cache_slots]AllDocsCandidateCacheSlot = [_]AllDocsCandidateCacheSlot{.{}} ** all_docs_candidate_cache_slots,
            all_docs_candidate_first_bytes: CandidateByteFilter = std.mem.zeroes(CandidateByteFilter),
            all_docs_candidate_second_bytes: CandidateByteFilter = std.mem.zeroes(CandidateByteFilter),
            all_docs_candidate_penultimate_bytes: CandidateByteFilter = std.mem.zeroes(CandidateByteFilter),
            all_docs_candidate_last_bytes: CandidateByteFilter = std.mem.zeroes(CandidateByteFilter),
            all_docs_candidate_shape_filter_dirty: bool = false,
            virtual_all_docs_failed_terms: std.ArrayList([]const u8) = .empty,
            variable_all_docs_failed_terms: std.ArrayList([]const u8) = .empty,
            virtual_all_docs_synthetic_records: u64 = 0,
            variable_all_docs_synthetic_records: u64 = 0,
            variable_all_docs_freq_cells: u64 = 0,
            variable_all_docs_disabled: bool = false,
            variable_all_docs_freq_stream_cells: u64 = 0,
            variable_all_docs_freq_stream_packed_bytes: u64 = 0,
            variable_all_docs_freq_stream_rle_bytes: u64 = 0,
            variable_all_docs_freq_stream_bitpacked_bytes: u64 = 0,
            variable_all_docs_freq_stream_rle_run_count: u64 = 0,
            variable_all_docs_freq_stream_max_freq: u32 = 0,
            synthetic_run_sources: std.ArrayList(TextPostingSyntheticRunSource) = .empty,
            run_paths_disjoint_term_ranges: bool = false,

            pub fn init(allocator: std.mem.Allocator, io: std.Io, base_path: []const u8) !TextPostingRunBuilder {
                return initWithChunkTiming(allocator, io, base_path, false);
            }

            pub fn initWithChunkTiming(allocator: std.mem.Allocator, io: std.Io, base_path: []const u8, measure_chunks: bool) !TextPostingRunBuilder {
                var builder = TextPostingRunBuilder{
                    .allocator = allocator,
                    .io = io,
                    .base_path = base_path,
                    .measure_chunks = measure_chunks,
                    .all_docs_candidates = std.StringHashMap(AllDocsRunCandidate).init(allocator),
                };
                errdefer builder.deinit();
                try builder.chunk.ensureTotalCapacityPrecise(allocator, text_posting_run_chunk_records);
                return builder;
            }

            pub fn deinit(self: *TextPostingRunBuilder) void {
                self.clearAllDocsCandidatesAndFree();
                self.all_docs_candidates.deinit();
                self.virtual_all_docs_failed_terms.deinit(self.allocator);
                self.variable_all_docs_failed_terms.deinit(self.allocator);
                for (self.synthetic_run_sources.items) |*source| source.deinit(self.allocator);
                self.synthetic_run_sources.deinit(self.allocator);
                for (self.run_summaries.items) |summary| {
                    std.Io.Dir.cwd().deleteFile(self.io, summary.path) catch {};
                    self.allocator.free(summary.path);
                }
                self.run_summaries.deinit(self.allocator);
                for (self.run_paths.items) |run_path| {
                    std.Io.Dir.cwd().deleteFile(self.io, run_path) catch {};
                    self.allocator.free(run_path);
                }
                self.run_paths.deinit(self.allocator);
                self.chunk_term_bytes.deinit(self.allocator);
                self.chunk.deinit(self.allocator);
            }

            pub fn clearAllDocsCandidatesAndFree(self: *TextPostingRunBuilder) void {
                var candidate_it = self.all_docs_candidates.iterator();
                while (candidate_it.next()) |entry| {
                    entry.value_ptr.deinit(self.allocator);
                    self.allocator.free(entry.key_ptr.*);
                }
                self.all_docs_candidates.clearAndFree();
                self.invalidateAllDocsCandidateCache();
                self.all_docs_candidate_first_bytes = std.mem.zeroes(CandidateByteFilter);
                self.all_docs_candidate_second_bytes = std.mem.zeroes(CandidateByteFilter);
                self.all_docs_candidate_penultimate_bytes = std.mem.zeroes(CandidateByteFilter);
                self.all_docs_candidate_last_bytes = std.mem.zeroes(CandidateByteFilter);
                self.all_docs_candidate_shape_filter_dirty = false;
                self.variable_all_docs_freq_cells = 0;
            }

            pub fn invalidateAllDocsCandidateCache(self: *TextPostingRunBuilder) void {
                self.all_docs_candidate_cache_generation +%= 1;
                if (self.all_docs_candidate_cache_generation == 0) self.all_docs_candidate_cache_generation = 1;
            }

            pub fn allDocsCandidateCacheKey(term: []const u8) u64 {
                const prefix = termSortPrefixKey(term);
                const suffix = if (term.len > @sizeOf(u64)) termSortTailKey(term) else prefix;
                return prefix ^ std.math.rotl(u64, suffix, 17) ^ (@as(u64, term.len) *% 0x9e3779b97f4a7c15);
            }

            pub fn allDocsCandidateCacheIndex(term_cache_key: u64) usize {
                var mixed = term_cache_key;
                mixed ^= mixed >> 32;
                mixed ^= mixed >> 16;
                mixed ^= mixed >> 8;
                return @intCast(mixed & (all_docs_candidate_cache_slots - 1));
            }

            pub fn cachedAllDocsCandidate(self: *TextPostingRunBuilder, term: []const u8, term_cache_key: u64) ?*AllDocsRunCandidate {
                if (term.len == 0 or term.len > default_max_token_bytes) return null;
                const slot_index = allDocsCandidateCacheIndex(term_cache_key);
                const slot = self.all_docs_candidate_cache[slot_index];
                if (slot.generation == self.all_docs_candidate_cache_generation and
                    slot.term_len == term.len and
                    slot.term_cache_key == term_cache_key and
                    std.mem.eql(u8, slot.key, term))
                {
                    if (self.measure_chunks) self.docs_posting_append_candidate_cache_hit_count += 1;
                    return slot.value;
                }
                return null;
            }

            pub fn rememberAllDocsCandidateCache(self: *TextPostingRunBuilder, term: []const u8, term_cache_key: u64, value: *AllDocsRunCandidate) void {
                if (term.len == 0 or term.len > default_max_token_bytes) return;
                self.all_docs_candidate_cache[allDocsCandidateCacheIndex(term_cache_key)] = .{
                    .generation = self.all_docs_candidate_cache_generation,
                    .term_cache_key = term_cache_key,
                    .term_len = @intCast(term.len),
                    .key = term,
                    .value = value,
                };
            }

            pub fn lookupAllDocsCandidate(self: *TextPostingRunBuilder, term: []const u8) ?*AllDocsRunCandidate {
                const term_cache_key = allDocsCandidateCacheKey(term);
                if (self.cachedAllDocsCandidate(term, term_cache_key)) |candidate| return candidate;
                const entry = self.all_docs_candidates.getEntry(term) orelse return null;
                self.rememberAllDocsCandidateCache(entry.key_ptr.*, term_cache_key, entry.value_ptr);
                return entry.value_ptr;
            }

            pub fn markAllDocsCandidateShape(self: *TextPostingRunBuilder, term: []const u8) void {
                if (term.len == 0 or term.len > default_max_token_bytes) return;
                setCandidateByte(&self.all_docs_candidate_first_bytes, term.len, term[0]);
                if (term.len > 1) {
                    setCandidateByte(&self.all_docs_candidate_second_bytes, term.len, term[1]);
                    setCandidateByte(&self.all_docs_candidate_penultimate_bytes, term.len, term[term.len - 2]);
                }
                setCandidateByte(&self.all_docs_candidate_last_bytes, term.len, term[term.len - 1]);
            }

            pub fn markAllDocsCandidateShapeFilterDirty(self: *TextPostingRunBuilder) void {
                self.all_docs_candidate_shape_filter_dirty = true;
            }

            pub fn rebuildAllDocsCandidateShapeFilter(self: *TextPostingRunBuilder) void {
                self.all_docs_candidate_first_bytes = std.mem.zeroes(CandidateByteFilter);
                self.all_docs_candidate_second_bytes = std.mem.zeroes(CandidateByteFilter);
                self.all_docs_candidate_penultimate_bytes = std.mem.zeroes(CandidateByteFilter);
                self.all_docs_candidate_last_bytes = std.mem.zeroes(CandidateByteFilter);
                var candidate_it = self.all_docs_candidates.iterator();
                while (candidate_it.next()) |entry| {
                    self.markAllDocsCandidateShape(entry.key_ptr.*);
                }
                self.all_docs_candidate_shape_filter_dirty = false;
            }

            pub fn mayMatchAllDocsCandidateShape(self: *TextPostingRunBuilder, term: []const u8) bool {
                if (self.all_docs_candidate_shape_filter_dirty) self.rebuildAllDocsCandidateShapeFilter();
                if (term.len == 0 or term.len > default_max_token_bytes) return true;
                if (!candidateByteSetContains(self.all_docs_candidate_first_bytes[term.len], term[0])) return false;
                if (!candidateByteSetContains(self.all_docs_candidate_last_bytes[term.len], term[term.len - 1])) return false;
                if (term.len > 1) {
                    if (!candidateByteSetContains(self.all_docs_candidate_second_bytes[term.len], term[1])) return false;
                    if (!candidateByteSetContains(self.all_docs_candidate_penultimate_bytes[term.len], term[term.len - 2])) return false;
                }
                return true;
            }

            pub fn chunkTermCacheIndex(term_sort_prefix: u64, term_len: usize) usize {
                var mixed = term_sort_prefix ^ (@as(u64, term_len) *% 0x517cc1b727220a95);
                mixed ^= mixed >> 33;
                mixed *%= 0xff51afd7ed558ccd;
                mixed ^= mixed >> 33;
                return @intCast(mixed & (text_posting_run_chunk_term_cache_slots - 1));
            }

            pub fn cachedChunkTermOffset(self: *const TextPostingRunBuilder, term: []const u8, term_sort_prefix: u64) ?u32 {
                if (term.len == 0 or term.len > default_max_token_bytes) return null;
                const slot = self.chunk_term_cache[chunkTermCacheIndex(term_sort_prefix, term.len)];
                if (!slot.occupied or slot.term_len != term.len or slot.term_sort_prefix != term_sort_prefix) return null;
                const offset: usize = slot.term_offset;
                const end = offset + term.len;
                if (end > self.chunk_term_bytes.items.len) return null;
                if (!std.mem.eql(u8, self.chunk_term_bytes.items[offset..end], term)) return null;
                return slot.term_offset;
            }

            pub fn rememberChunkTermOffset(self: *TextPostingRunBuilder, term: []const u8, term_sort_prefix: u64, term_offset: u32) void {
                if (term.len == 0 or term.len > default_max_token_bytes) return;
                self.chunk_term_cache[chunkTermCacheIndex(term_sort_prefix, term.len)] = .{
                    .term_sort_prefix = term_sort_prefix,
                    .term_len = @intCast(term.len),
                    .term_offset = term_offset,
                    .occupied = true,
                };
            }

            pub fn clearChunkTermCache(self: *TextPostingRunBuilder) void {
                self.chunk_term_cache = [_]TextPostingRunChunkTermCacheSlot{.{}} ** text_posting_run_chunk_term_cache_slots;
            }

            pub fn appendRegularRunRecord(self: *TextPostingRunBuilder, term: []const u8, posting: TextPostingRecord) !void {
                const sample = self.measure_chunks and ((self.docs_posting_append_regular_record_count & text_posting_append_probe_sample_mask) == 0);
                const sample_start = if (sample) textMonotonicNs(self.io) else 0;
                try self.appendTermPosting(term, posting);
                if (self.measure_chunks) {
                    self.docs_posting_append_regular_record_count += 1;
                    if (sample) {
                        self.docs_posting_append_regular_sampled_ns += textElapsedNs(self.io, sample_start);
                        self.docs_posting_append_regular_sample_count += 1;
                    }
                }
            }

            pub fn appendDocumentFreqs(self: *TextPostingRunBuilder, doc_id: u64, freqs: *std.StringHashMap(FieldTermFreq)) !void {
                if (doc_id != self.doc_count + 1) return error.InvalidRecord;
                self.doc_count = doc_id;
                var it = freqs.iterator();
                while (it.next()) |entry| {
                    if (self.measure_chunks) self.docs_posting_append_term_count += 1;
                    const posting = TextPostingRecord{
                        .doc_id = doc_id,
                        .text_freq = entry.value_ptr.text,
                        .kind_freq = entry.value_ptr.kind,
                    };

                    if (doc_id == 1) {
                        if (posting.kind_freq == 0 and posting.text_freq != 0) {
                            const owned_term = try self.allocator.dupe(u8, entry.key_ptr.*);
                            errdefer self.allocator.free(owned_term);
                            try self.all_docs_candidates.put(owned_term, .{ .virtual = .{
                                .text_freq = posting.text_freq,
                                .last_seen_doc_id = doc_id,
                            } });
                            self.invalidateAllDocsCandidateCache();
                            self.markAllDocsCandidateShape(entry.key_ptr.*);
                            if (self.measure_chunks) self.docs_posting_append_virtual_candidate_put_count += 1;
                            continue;
                        }
                    } else if (self.all_docs_candidates.count() == 0 or
                        !self.mayMatchAllDocsCandidateShape(entry.key_ptr.*))
                    {
                        if (self.measure_chunks) self.docs_posting_append_candidate_filter_skip_count += 1;
                        try self.appendRegularRunRecord(entry.key_ptr.*, posting);
                        continue;
                    } else {
                        if (self.measure_chunks) self.docs_posting_append_candidate_lookup_count += 1;
                        const lookup_sample = self.measure_chunks and ((self.docs_posting_append_candidate_lookup_count & text_posting_append_probe_sample_mask) == 0);
                        const lookup_start = if (lookup_sample) textMonotonicNs(self.io) else 0;
                        const candidate_ptr = self.lookupAllDocsCandidate(entry.key_ptr.*);
                        if (lookup_sample) {
                            self.docs_posting_append_candidate_lookup_sampled_ns += textElapsedNs(self.io, lookup_start);
                            self.docs_posting_append_candidate_lookup_sample_count += 1;
                        }
                        if (candidate_ptr) |candidate| {
                            const hit_sample = lookup_sample;
                            const hit_start = if (hit_sample) textMonotonicNs(self.io) else 0;
                            defer if (hit_sample) {
                                self.docs_posting_append_candidate_hit_sampled_ns += textElapsedNs(self.io, hit_start);
                                self.docs_posting_append_candidate_hit_sample_count += 1;
                            };
                            switch (candidate.*) {
                                .variable => |*variable| {
                                    const variable_hit_start = if (hit_sample) textMonotonicNs(self.io) else 0;
                                    defer if (hit_sample) {
                                        self.docs_posting_append_variable_hit_sampled_ns += textElapsedNs(self.io, variable_hit_start);
                                        self.docs_posting_append_variable_hit_sample_count += 1;
                                    };
                                    if (self.measure_chunks) self.docs_posting_append_variable_candidate_hit_count += 1;
                                    if (variable.last_seen_doc_id != doc_id - 1) {
                                        const materialize_start = if (self.measure_chunks) textMonotonicNs(self.io) else 0;
                                        try self.materializeFailedVariableAllDocsCandidate(entry.key_ptr.*);
                                        if (self.measure_chunks) {
                                            self.docs_posting_append_materialize_ns += textElapsedNs(self.io, materialize_start);
                                            self.docs_posting_append_materialize_call_count += 1;
                                        }
                                    } else if (posting.kind_freq == 0 and posting.text_freq != 0) {
                                        if (try self.appendVariableAllDocsRunCandidateFreq(variable, posting.text_freq)) {
                                            variable.last_seen_doc_id = doc_id;
                                            if (self.measure_chunks) self.docs_posting_append_variable_freq_append_count += 1;
                                            continue;
                                        }
                                        const materialize_start = if (self.measure_chunks) textMonotonicNs(self.io) else 0;
                                        try self.materializeAllVariableAllDocsCandidates();
                                        if (self.measure_chunks) {
                                            self.docs_posting_append_materialize_ns += textElapsedNs(self.io, materialize_start);
                                            self.docs_posting_append_materialize_call_count += 1;
                                        }
                                    } else {
                                        const materialize_start = if (self.measure_chunks) textMonotonicNs(self.io) else 0;
                                        try self.materializeFailedVariableAllDocsCandidate(entry.key_ptr.*);
                                        if (self.measure_chunks) {
                                            self.docs_posting_append_materialize_ns += textElapsedNs(self.io, materialize_start);
                                            self.docs_posting_append_materialize_call_count += 1;
                                        }
                                    }
                                },
                                .virtual => |*virtual| {
                                    const virtual_hit_start = if (hit_sample) textMonotonicNs(self.io) else 0;
                                    defer if (hit_sample) {
                                        self.docs_posting_append_virtual_hit_sampled_ns += textElapsedNs(self.io, virtual_hit_start);
                                        self.docs_posting_append_virtual_hit_sample_count += 1;
                                    };
                                    if (self.measure_chunks) self.docs_posting_append_virtual_candidate_hit_count += 1;
                                    if (virtual.last_seen_doc_id != doc_id - 1) {
                                        const materialize_start = if (self.measure_chunks) textMonotonicNs(self.io) else 0;
                                        try self.materializeFailedVirtualAllDocsCandidate(entry.key_ptr.*, virtual.last_seen_doc_id);
                                        if (self.measure_chunks) {
                                            self.docs_posting_append_materialize_ns += textElapsedNs(self.io, materialize_start);
                                            self.docs_posting_append_materialize_call_count += 1;
                                        }
                                    } else if (posting.kind_freq == 0 and posting.text_freq == virtual.text_freq) {
                                        virtual.last_seen_doc_id = doc_id;
                                        continue;
                                    } else if (posting.kind_freq == 0 and posting.text_freq != 0) {
                                        if (try self.convertVirtualAllDocsCandidateToVariable(entry.key_ptr.*, doc_id, posting.text_freq)) {
                                            if (self.measure_chunks) self.docs_posting_append_variable_freq_append_count += 1;
                                            continue;
                                        }
                                        const materialize_start = if (self.measure_chunks) textMonotonicNs(self.io) else 0;
                                        try self.materializeAllVariableAllDocsCandidates();
                                        if (self.measure_chunks) {
                                            self.docs_posting_append_materialize_ns += textElapsedNs(self.io, materialize_start);
                                            self.docs_posting_append_materialize_call_count += 1;
                                        }
                                    }
                                },
                            }
                            if (self.measure_chunks) self.docs_posting_append_candidate_regularized_hit_count += 1;
                        } else if (self.measure_chunks) {
                            self.docs_posting_append_candidate_miss_count += 1;
                        }
                    }

                    try self.appendRegularRunRecord(entry.key_ptr.*, posting);
                }
                if (doc_id % text_posting_run_all_docs_candidate_sweep_interval == 0) {
                    const sweep_start = if (self.measure_chunks) textMonotonicNs(self.io) else 0;
                    try self.materializeStaleVirtualAllDocsCandidates(doc_id);
                    try self.materializeStaleVariableAllDocsCandidates(doc_id);
                    if (self.measure_chunks) {
                        self.docs_posting_append_sweep_ns += textElapsedNs(self.io, sweep_start);
                        self.docs_posting_append_sweep_count += 1;
                    }
                }
            }

            pub fn noteSyntheticDocument(self: *TextPostingRunBuilder, doc_id: u64) !void {
                if (doc_id != self.doc_count + 1) return error.InvalidRecord;
                self.doc_count = doc_id;
            }

            pub fn appendRepeatedTextCacheRun(self: *TextPostingRunBuilder, cache: *TextRebuildTextFreqCache) !void {
                if (cache.entries.items.len == 0) return;
                const had_existing_run_paths = self.run_paths.items.len != 0;
                if (had_existing_run_paths) self.run_paths_disjoint_term_ranges = false;
                var groups = std.StringHashMap(std.ArrayList(RepeatedTextTermSegment)).init(self.allocator);
                defer {
                    var value_it = groups.valueIterator();
                    while (value_it.next()) |segments| segments.deinit(self.allocator);
                    groups.deinit();
                }

                for (cache.entries.items) |*name_entry| {
                    if (name_entry.doc_ids.items.len == 0) continue;
                    for (name_entry.terms) |term_freq| {
                        if (term_freq.freq.kind != 0 or term_freq.freq.text == 0) return error.InvalidRecord;
                        const group_entry = try groups.getOrPut(term_freq.term);
                        if (!group_entry.found_existing) {
                            group_entry.value_ptr.* = .empty;
                        }
                        try group_entry.value_ptr.append(self.allocator, .{
                            .doc_ids = name_entry.doc_ids.items,
                            .text_freq = term_freq.freq.text,
                        });
                    }
                }

                var terms = std.ArrayList([]const u8).empty;
                defer terms.deinit(self.allocator);
                try terms.ensureTotalCapacityPrecise(self.allocator, groups.count());
                var key_it = groups.keyIterator();
                while (key_it.next()) |term| terms.appendAssumeCapacity(term.*);
                std.mem.sort([]const u8, terms.items, {}, stringSliceLessThan);

                var queue = std.PriorityQueue(RepeatedTextSegmentCursor, void, compareRepeatedTextSegmentCursor).initContext({});
                defer queue.deinit(self.allocator);
                var previous_doc_id: u32 = 0;

                var term_start: usize = 0;
                while (term_start < terms.items.len) {
                    const term_end = @min(term_start + repeated_text_direct_run_terms_per_file, terms.items.len);
                    const file_ordinal = self.run_summaries.items.len;

                    const run_path = try std.fmt.allocPrint(self.allocator, "{s}.posting_run.{d}.tmp", .{ self.base_path, file_ordinal });
                    var run_path_owned = true;
                    errdefer {
                        std.Io.Dir.cwd().deleteFile(self.io, run_path) catch {};
                        if (run_path_owned) self.allocator.free(run_path);
                    }
                    const summary_path = try std.fmt.allocPrint(self.allocator, "{s}.posting_run.{d}.summary.tmp", .{ self.base_path, file_ordinal });
                    var summary_path_owned = true;
                    errdefer {
                        std.Io.Dir.cwd().deleteFile(self.io, summary_path) catch {};
                        if (summary_path_owned) self.allocator.free(summary_path);
                    }
                    const synthetic_summary_path = try std.fmt.allocPrint(self.allocator, "{s}.posting_run.{d}.synthetic.summary.tmp", .{ self.base_path, file_ordinal });
                    var synthetic_summary_path_owned = true;
                    errdefer {
                        std.Io.Dir.cwd().deleteFile(self.io, synthetic_summary_path) catch {};
                        if (synthetic_summary_path_owned) self.allocator.free(synthetic_summary_path);
                    }

                    var run_file = try std.Io.Dir.cwd().createFile(self.io, run_path, .{ .read = true, .truncate = true });
                    defer run_file.close(self.io);
                    var run_output = try TextBufferedWriter.init(self.allocator, self.io, run_file, text_write_buffer_bytes);
                    defer run_output.deinit();
                    var run_writer = TextPostingRunFrontCodedWriter{ .writer = &run_output };
                    var expected_run_size = try run_writer.writeHeader();

                    var summary_file = try std.Io.Dir.cwd().createFile(self.io, summary_path, .{ .read = true, .truncate = true });
                    defer summary_file.close(self.io);
                    var summary_writer = try TextPostingRunSummaryWriter.init(self.allocator, self.io, summary_file);
                    defer summary_writer.deinit();
                    var summary_context = CollectTextPostingRunSummaryContext{ .writer = &summary_writer };

                    var synthetic_summary_file = try std.Io.Dir.cwd().createFile(self.io, synthetic_summary_path, .{ .read = true, .truncate = true });
                    defer synthetic_summary_file.close(self.io);
                    var synthetic_summary_writer = try TextPostingRunSummaryWriter.init(self.allocator, self.io, synthetic_summary_file);
                    defer synthetic_summary_writer.deinit();
                    var synthetic_summary_context = CollectTextPostingRunSummaryContext{ .writer = &synthetic_summary_writer };

                    var regular_records_written: u64 = 0;
                    for (terms.items[term_start..term_end]) |term| {
                        const segments = groups.get(term) orelse return error.InvalidRecord;
                        if (try self.appendRepeatedTextAllDocsSyntheticTerm(term, segments.items, &synthetic_summary_context)) {
                            continue;
                        }
                        queue.clearRetainingCapacity();
                        try queue.ensureTotalCapacityPrecise(self.allocator, segments.items.len);
                        for (segments.items) |segment| {
                            if (segment.doc_ids.len == 0) return error.InvalidRecord;
                            try queue.push(self.allocator, .{ .segment = segment });
                        }
                        previous_doc_id = 0;
                        while (queue.pop()) |cursor| {
                            const doc_id = cursor.segment.doc_ids[cursor.index];
                            if (doc_id <= previous_doc_id) return error.InvalidRecord;
                            previous_doc_id = doc_id;
                            const posting = TextPostingRecord{
                                .doc_id = doc_id,
                                .text_freq = cursor.segment.text_freq,
                                .kind_freq = 0,
                            };
                            const encoded_len = try run_writer.appendCheckedTermPosting(term, posting);
                            expected_run_size = std.math.add(u64, expected_run_size, encoded_len) catch return error.RecordTooLarge;
                            try collectTextPostingRunSummaryFields(&summary_context, term, posting, encoded_len);
                            regular_records_written = std.math.add(u64, regular_records_written, 1) catch return error.RecordTooLarge;
                            if (self.measure_chunks) {
                                self.chunk_records = std.math.add(u64, self.chunk_records, 1) catch return error.RecordTooLarge;
                                self.run_record_term_bytes = std.math.add(u64, self.run_record_term_bytes, term.len) catch return error.RecordTooLarge;
                                self.run_record_inline_capacity_bytes = std.math.add(u64, self.run_record_inline_capacity_bytes, default_max_token_bytes) catch return error.RecordTooLarge;
                                self.run_record_term_slack_bytes = std.math.add(u64, self.run_record_term_slack_bytes, default_max_token_bytes - term.len) catch return error.RecordTooLarge;
                                if (term.len > text_posting_run_record_long_term_threshold) self.run_record_long_term_count += 1;
                                self.run_record_max_term_len = @max(self.run_record_max_term_len, @as(u64, @intCast(term.len)));
                            }
                            const next_index = cursor.index + 1;
                            if (next_index < cursor.segment.doc_ids.len) {
                                try queue.push(self.allocator, .{ .segment = cursor.segment, .index = next_index });
                            }
                        }
                    }
                    try flushTextPostingRunSummary(&summary_context);
                    try flushTextPostingRunSummary(&synthetic_summary_context);
                    try run_output.flush();
                    try summary_writer.flush();
                    try synthetic_summary_writer.flush();

                    const run_stat = try run_file.stat(self.io);
                    if (run_stat.kind != .file or run_stat.size != expected_run_size) return error.InvalidRecord;
                    const summary_stat = try summary_file.stat(self.io);
                    if (summary_stat.kind != .file or summary_stat.size != summary_writer.physical_bytes) return error.InvalidRecord;
                    summary_context.summary_file_bytes = summary_writer.physical_bytes;
                    const synthetic_summary_stat = try synthetic_summary_file.stat(self.io);
                    if (synthetic_summary_stat.kind != .file or synthetic_summary_stat.size != synthetic_summary_writer.physical_bytes) return error.InvalidRecord;
                    synthetic_summary_context.summary_file_bytes = synthetic_summary_writer.physical_bytes;

                    if (regular_records_written != 0) {
                        try self.run_paths.append(self.allocator, run_path);
                        run_path_owned = false;
                        try self.run_summaries.append(self.allocator, .{
                            .path = summary_path,
                            .term_count = summary_context.term_count,
                            .file_size = summary_context.summary_file_bytes,
                        });
                        summary_path_owned = false;
                    } else {
                        try std.Io.Dir.cwd().deleteFile(self.io, run_path);
                        self.allocator.free(run_path);
                        run_path_owned = false;
                        try std.Io.Dir.cwd().deleteFile(self.io, summary_path);
                        self.allocator.free(summary_path);
                        summary_path_owned = false;
                    }
                    if (synthetic_summary_context.term_count != 0) {
                        try self.run_summaries.append(self.allocator, .{
                            .path = synthetic_summary_path,
                            .term_count = synthetic_summary_context.term_count,
                            .file_size = synthetic_summary_context.summary_file_bytes,
                        });
                        synthetic_summary_path_owned = false;
                    } else {
                        try std.Io.Dir.cwd().deleteFile(self.io, synthetic_summary_path);
                        self.allocator.free(synthetic_summary_path);
                        synthetic_summary_path_owned = false;
                    }
                    if (self.measure_chunks) self.chunk_count += 1;
                    term_start = term_end;
                }
                if (!had_existing_run_paths and self.run_paths.items.len != 0) self.run_paths_disjoint_term_ranges = true;
            }

            pub fn appendRepeatedTextAllDocsSyntheticTerm(
                self: *TextPostingRunBuilder,
                term: []const u8,
                segments: []const RepeatedTextTermSegment,
                summary_context: *CollectTextPostingRunSummaryContext,
            ) !bool {
                if (self.doc_count == 0) return false;
                var total_postings: u64 = 0;
                for (segments) |segment| {
                    total_postings = std.math.add(u64, total_postings, @intCast(segment.doc_ids.len)) catch return error.RecordTooLarge;
                }
                if (total_postings != self.doc_count) return false;

                var queue = std.PriorityQueue(RepeatedTextSegmentCursor, void, compareRepeatedTextSegmentCursor).initContext({});
                defer queue.deinit(self.allocator);
                try queue.ensureTotalCapacityPrecise(self.allocator, segments.len);
                for (segments) |segment| {
                    if (segment.doc_ids.len == 0) return error.InvalidRecord;
                    try queue.push(self.allocator, .{ .segment = segment });
                }

                var freqs = VariableAllDocsFreqBuffer{ .narrow = .empty };
                var freqs_owned = true;
                errdefer if (freqs_owned) freqs.deinit(self.allocator);
                try freqs.ensureTotalCapacityPrecise(self.allocator, std.math.cast(usize, self.doc_count) orelse return error.RecordTooLarge);
                var expected_doc_id: u32 = 1;
                var constant_text_freq: u32 = 0;
                var constant = true;
                while (queue.pop()) |cursor| {
                    const doc_id = cursor.segment.doc_ids[cursor.index];
                    if (doc_id != expected_doc_id) {
                        freqs.deinit(self.allocator);
                        freqs_owned = false;
                        return false;
                    }
                    const text_freq = cursor.segment.text_freq;
                    if (constant_text_freq == 0) {
                        constant_text_freq = text_freq;
                    } else if (constant_text_freq != text_freq) {
                        constant = false;
                    }
                    try freqs.append(self.allocator, text_freq);
                    expected_doc_id += 1;
                    const next_index = cursor.index + 1;
                    if (next_index < cursor.segment.doc_ids.len) {
                        try queue.push(self.allocator, .{ .segment = cursor.segment, .index = next_index });
                    }
                }
                if (@as(u64, expected_doc_id) != self.doc_count + 1) {
                    freqs.deinit(self.allocator);
                    freqs_owned = false;
                    return false;
                }

                const summary_text_freq = if (constant) constant_text_freq else 0;
                const record = try TextPostingRunTermSummaryRecord.initWithFreqSummary(term, self.doc_count, summary_text_freq, true, self.doc_count == 1);
                try appendTextPostingRunSummaryRecord(summary_context, record);
                if (constant) {
                    freqs.deinit(self.allocator);
                    freqs_owned = false;
                    var source = TextPostingSyntheticRunSource{ .virtual_all_docs = .{
                        .term = try self.allocator.dupe(u8, term),
                        .text_freq = constant_text_freq,
                    } };
                    errdefer source.deinit(self.allocator);
                    try self.synthetic_run_sources.append(self.allocator, source);
                    self.virtual_all_docs_synthetic_records = std.math.add(u64, self.virtual_all_docs_synthetic_records, self.doc_count) catch return error.RecordTooLarge;
                } else {
                    const freq_stats = try freqs.slice().sizeStats();
                    if (self.measure_chunks) {
                        self.variable_all_docs_freq_stream_cells = std.math.add(u64, self.variable_all_docs_freq_stream_cells, @intCast(freqs.len())) catch return error.RecordTooLarge;
                        self.variable_all_docs_freq_stream_packed_bytes = std.math.add(u64, self.variable_all_docs_freq_stream_packed_bytes, freq_stats.packed_bytes) catch return error.RecordTooLarge;
                        self.variable_all_docs_freq_stream_rle_bytes = std.math.add(u64, self.variable_all_docs_freq_stream_rle_bytes, freq_stats.rle_bytes) catch return error.RecordTooLarge;
                        self.variable_all_docs_freq_stream_bitpacked_bytes = std.math.add(u64, self.variable_all_docs_freq_stream_bitpacked_bytes, freq_stats.bitpacked_bytes) catch return error.RecordTooLarge;
                        self.variable_all_docs_freq_stream_rle_run_count = std.math.add(u64, self.variable_all_docs_freq_stream_rle_run_count, freq_stats.rle_run_count) catch return error.RecordTooLarge;
                        self.variable_all_docs_freq_stream_max_freq = @max(self.variable_all_docs_freq_stream_max_freq, freq_stats.max_freq);
                    }
                    var source = TextPostingSyntheticRunSource{ .variable_all_docs = .{
                        .term = try self.allocator.dupe(u8, term),
                        .freqs = freqs,
                        .freq_stats = freq_stats,
                    } };
                    freqs_owned = false;
                    errdefer source.deinit(self.allocator);
                    try self.synthetic_run_sources.append(self.allocator, source);
                    self.variable_all_docs_synthetic_records = std.math.add(u64, self.variable_all_docs_synthetic_records, self.doc_count) catch return error.RecordTooLarge;
                }
                return true;
            }

            pub fn append(self: *TextPostingRunBuilder, record: TextPostingRunRecord) !void {
                try self.appendTermPosting(record.term(), try record.toPosting());
            }

            pub fn appendTermPosting(self: *TextPostingRunBuilder, term: []const u8, posting: TextPostingRecord) !void {
                self.run_paths_disjoint_term_ranges = false;
                if (self.chunk.items.len == text_posting_run_chunk_records) try self.flushRun();
                if (term.len == 0 or term.len > default_max_token_bytes) return error.InvalidRecord;
                try validateTextPostingFields(posting.doc_id, posting.text_freq, posting.kind_freq);
                const term_sort_prefix = termSortPrefixKey(term);
                var term_offset: u32 = undefined;
                if (self.cachedChunkTermOffset(term, term_sort_prefix)) |cached_offset| {
                    term_offset = cached_offset;
                    if (self.measure_chunks) {
                        self.run_record_term_cache_hits += 1;
                        self.run_record_term_cache_saved_bytes += term.len;
                    }
                } else {
                    if (self.chunk_term_bytes.items.len > std.math.maxInt(u32)) return error.RecordTooLarge;
                    term_offset = @intCast(self.chunk_term_bytes.items.len);
                    try self.chunk_term_bytes.appendSlice(self.allocator, term);
                    self.rememberChunkTermOffset(term, term_sort_prefix, term_offset);
                }
                const chunk_record = TextPostingRunChunkRecord{
                    .term_sort_prefix = term_sort_prefix,
                    .doc_id = @intCast(posting.doc_id),
                    .term_offset = term_offset,
                    .text_freq = @intCast(posting.text_freq),
                    .kind_freq = @intCast(posting.kind_freq),
                    .term_len = @intCast(term.len),
                };
                if (self.measure_chunks) {
                    const term_len: u64 = @intCast(term.len);
                    self.run_record_term_bytes += term_len;
                    self.run_record_inline_capacity_bytes += default_max_token_bytes;
                    self.run_record_term_slack_bytes += default_max_token_bytes - term_len;
                    if (term.len > text_posting_run_record_long_term_threshold) self.run_record_long_term_count += 1;
                    self.run_record_max_term_len = @max(self.run_record_max_term_len, term_len);
                }
                self.chunk.appendAssumeCapacity(chunk_record);
            }

            pub fn finish(self: *TextPostingRunBuilder) !void {
                textBenchTraceRunBuilder("run_builder_finish_materialize_virtual_start", self);
                self.materializeStaleVirtualAllDocsCandidates(self.doc_count) catch |err| {
                    textBenchTraceRunBuilder("run_builder_finish_materialize_virtual_error", self);
                    return err;
                };
                textBenchTraceRunBuilder("run_builder_finish_materialize_variable_start", self);
                self.materializeStaleVariableAllDocsCandidates(self.doc_count) catch |err| {
                    textBenchTraceRunBuilder("run_builder_finish_materialize_variable_error", self);
                    return err;
                };
                textBenchTraceRunBuilder("run_builder_finish_flush_run_start", self);
                self.flushRun() catch |err| {
                    textBenchTraceRunBuilder("run_builder_finish_flush_run_error", self);
                    return err;
                };
                textBenchTraceRunBuilder("run_builder_finish_compact_start", self);
                self.compactForFanIn() catch |err| {
                    textBenchTraceRunBuilder("run_builder_finish_compact_error", self);
                    return err;
                };
                textBenchTraceRunBuilder("run_builder_finish_flush_virtual_start", self);
                self.flushVirtualAllDocsCandidates() catch |err| {
                    textBenchTraceRunBuilder("run_builder_finish_flush_virtual_error", self);
                    return err;
                };
                textBenchTraceRunBuilder("run_builder_finish_flush_variable_start", self);
                self.flushVariableAllDocsCandidates() catch |err| {
                    textBenchTraceRunBuilder("run_builder_finish_flush_variable_error", self);
                    return err;
                };
                std.mem.sort(TextPostingSyntheticRunSource, self.synthetic_run_sources.items, {}, textPostingSyntheticRunSourceLessThan);
                textBenchTraceRunBuilder("run_builder_finish_coalesce_summaries_start", self);
                self.coalesceSummariesForFinalMerge() catch |err| {
                    textBenchTraceRunBuilder("run_builder_finish_coalesce_summaries_error", self);
                    return err;
                };
            }

            pub fn releaseBuildScratchAfterFinish(self: *TextPostingRunBuilder) void {
                self.chunk.deinit(self.allocator);
                self.chunk = .empty;
                self.chunk_term_bytes.deinit(self.allocator);
                self.chunk_term_bytes = .empty;
                self.virtual_all_docs_failed_terms.deinit(self.allocator);
                self.virtual_all_docs_failed_terms = .empty;
                self.variable_all_docs_failed_terms.deinit(self.allocator);
                self.variable_all_docs_failed_terms = .empty;
                self.clearAllDocsCandidatesAndFree();
            }

            pub fn materializeFailedVirtualAllDocsCandidate(self: *TextPostingRunBuilder, term: []const u8, last_doc_id: u64) !void {
                const candidate = switch (self.all_docs_candidates.get(term) orelse return error.InvalidRecord) {
                    .virtual => |candidate| candidate,
                    .variable => return error.InvalidRecord,
                };
                const removed = self.all_docs_candidates.fetchRemove(term) orelse return error.InvalidRecord;
                self.invalidateAllDocsCandidateCache();
                self.markAllDocsCandidateShapeFilterDirty();
                defer self.allocator.free(removed.key);
                var doc_id: u64 = 1;
                while (doc_id <= last_doc_id) : (doc_id += 1) {
                    try self.appendTermPosting(removed.key, .{
                        .doc_id = doc_id,
                        .text_freq = candidate.text_freq,
                        .kind_freq = 0,
                    });
                }
            }

            pub fn reserveVariableAllDocsFreqCells(self: *TextPostingRunBuilder, cells: u64) bool {
                if (self.variable_all_docs_disabled) return false;
                const next = std.math.add(u64, self.variable_all_docs_freq_cells, cells) catch {
                    self.variable_all_docs_disabled = true;
                    return false;
                };
                if (next > text_posting_run_variable_all_docs_max_freq_cells) {
                    self.variable_all_docs_disabled = true;
                    return false;
                }
                self.variable_all_docs_freq_cells = next;
                return true;
            }

            pub fn releaseVariableAllDocsFreqCells(self: *TextPostingRunBuilder, cells: u64) void {
                if (cells > self.variable_all_docs_freq_cells) {
                    self.variable_all_docs_freq_cells = 0;
                    return;
                }
                self.variable_all_docs_freq_cells -= cells;
            }

            pub fn convertVirtualAllDocsCandidateToVariable(self: *TextPostingRunBuilder, term: []const u8, doc_id: u64, text_freq: u32) !bool {
                const candidate_slot = self.all_docs_candidates.getPtr(term) orelse return error.InvalidRecord;
                const existing = switch (candidate_slot.*) {
                    .virtual => |candidate| candidate,
                    .variable => return error.InvalidRecord,
                };
                const prior_freq = try validateDenseAllDocsTextFreq(existing.text_freq);
                const next_freq = try validateDenseAllDocsTextFreq(text_freq);
                if (!self.reserveVariableAllDocsFreqCells(doc_id)) return false;
                errdefer self.releaseVariableAllDocsFreqCells(doc_id);
                var candidate = VariableAllDocsRunCandidate{ .last_seen_doc_id = doc_id };
                errdefer candidate.deinit(self.allocator);
                const prior_docs = std.math.cast(usize, doc_id - 1) orelse return error.RecordTooLarge;
                if (prior_freq > std.math.maxInt(u8) or next_freq > std.math.maxInt(u8)) try candidate.freqs.ensureWide(self.allocator);
                try candidate.freqs.ensureTotalCapacityPrecise(self.allocator, prior_docs + 1);
                var prior_doc_id: u64 = 1;
                while (prior_doc_id < doc_id) : (prior_doc_id += 1) {
                    try candidate.freqs.appendAssumeCapacity(prior_freq);
                }
                try candidate.freqs.appendAssumeCapacity(next_freq);
                candidate_slot.* = .{ .variable = candidate };
                return true;
            }

            pub fn appendVariableAllDocsRunCandidateFreq(self: *TextPostingRunBuilder, candidate: *VariableAllDocsRunCandidate, text_freq: u32) !bool {
                const sample = self.measure_chunks and ((self.docs_posting_append_variable_freq_append_count & text_posting_append_probe_sample_mask) == 0);
                const sample_start = if (sample) textMonotonicNs(self.io) else 0;
                if (!self.reserveVariableAllDocsFreqCells(1)) return false;
                errdefer self.releaseVariableAllDocsFreqCells(1);
                try candidate.freqs.append(self.allocator, text_freq);
                if (sample) {
                    self.docs_posting_append_variable_freq_sampled_ns += textElapsedNs(self.io, sample_start);
                    self.docs_posting_append_variable_freq_sample_count += 1;
                }
                return true;
            }

            pub fn materializeFailedVariableAllDocsCandidate(self: *TextPostingRunBuilder, term: []const u8) !void {
                const existing = switch (self.all_docs_candidates.get(term) orelse return error.InvalidRecord) {
                    .virtual => return error.InvalidRecord,
                    .variable => |candidate| candidate,
                };
                const candidate_cells: u64 = @intCast(existing.freqs.len());
                const removed = self.all_docs_candidates.fetchRemove(term) orelse return error.InvalidRecord;
                self.invalidateAllDocsCandidateCache();
                self.markAllDocsCandidateShapeFilterDirty();
                var candidate = switch (removed.value) {
                    .virtual => unreachable,
                    .variable => |candidate| candidate,
                };
                defer {
                    candidate.deinit(self.allocator);
                    self.allocator.free(removed.key);
                    self.releaseVariableAllDocsFreqCells(candidate_cells);
                }
                if (candidate_cells != candidate.last_seen_doc_id) return error.InvalidRecord;
                const freqs = candidate.freqs.slice();
                var index: usize = 0;
                while (index < freqs.len()) : (index += 1) {
                    try self.appendTermPosting(removed.key, .{
                        .doc_id = @intCast(index + 1),
                        .text_freq = freqs.at(index),
                        .kind_freq = 0,
                    });
                }
            }

            pub fn materializeAllVariableAllDocsCandidates(self: *TextPostingRunBuilder) !void {
                self.variable_all_docs_failed_terms.clearRetainingCapacity();
                var candidate_it = self.all_docs_candidates.iterator();
                while (candidate_it.next()) |entry| {
                    switch (entry.value_ptr.*) {
                        .virtual => {},
                        .variable => try self.variable_all_docs_failed_terms.append(self.allocator, entry.key_ptr.*),
                    }
                }
                for (self.variable_all_docs_failed_terms.items) |term| {
                    try self.materializeFailedVariableAllDocsCandidate(term);
                }
                self.variable_all_docs_failed_terms.clearRetainingCapacity();
            }

            pub fn materializeStaleVirtualAllDocsCandidates(self: *TextPostingRunBuilder, current_doc_id: u64) !void {
                self.virtual_all_docs_failed_terms.clearRetainingCapacity();
                var candidate_it = self.all_docs_candidates.iterator();
                while (candidate_it.next()) |entry| {
                    switch (entry.value_ptr.*) {
                        .virtual => |candidate| if (candidate.last_seen_doc_id != current_doc_id) {
                            try self.virtual_all_docs_failed_terms.append(self.allocator, entry.key_ptr.*);
                        },
                        .variable => {},
                    }
                }
                for (self.virtual_all_docs_failed_terms.items) |term| {
                    const candidate = switch (self.all_docs_candidates.get(term) orelse return error.InvalidRecord) {
                        .virtual => |candidate| candidate,
                        .variable => return error.InvalidRecord,
                    };
                    try self.materializeFailedVirtualAllDocsCandidate(term, candidate.last_seen_doc_id);
                }
                self.virtual_all_docs_failed_terms.clearRetainingCapacity();
            }

            pub fn materializeStaleVariableAllDocsCandidates(self: *TextPostingRunBuilder, current_doc_id: u64) !void {
                self.variable_all_docs_failed_terms.clearRetainingCapacity();
                var candidate_it = self.all_docs_candidates.iterator();
                while (candidate_it.next()) |entry| {
                    switch (entry.value_ptr.*) {
                        .virtual => {},
                        .variable => |candidate| if (candidate.last_seen_doc_id != current_doc_id) {
                            try self.variable_all_docs_failed_terms.append(self.allocator, entry.key_ptr.*);
                        },
                    }
                }
                for (self.variable_all_docs_failed_terms.items) |term| {
                    try self.materializeFailedVariableAllDocsCandidate(term);
                }
                self.variable_all_docs_failed_terms.clearRetainingCapacity();
            }

            const VirtualAllDocsSyntheticTerm = struct {
                term: []const u8,
                text_freq: u32,
            };

            pub fn virtualAllDocsSyntheticTermLessThan(_: void, lhs: VirtualAllDocsSyntheticTerm, rhs: VirtualAllDocsSyntheticTerm) bool {
                return std.mem.order(u8, lhs.term, rhs.term) == .lt;
            }

            const VariableAllDocsSyntheticTerm = struct {
                term: []const u8,
            };

            pub fn variableAllDocsSyntheticTermLessThan(_: void, lhs: VariableAllDocsSyntheticTerm, rhs: VariableAllDocsSyntheticTerm) bool {
                return std.mem.order(u8, lhs.term, rhs.term) == .lt;
            }

            pub fn flushVirtualAllDocsCandidates(self: *TextPostingRunBuilder) !void {
                var virtual_count: usize = 0;
                var count_it = self.all_docs_candidates.iterator();
                while (count_it.next()) |entry| {
                    switch (entry.value_ptr.*) {
                        .virtual => virtual_count += 1,
                        .variable => {},
                    }
                }
                if (virtual_count == 0) return;
                if (self.doc_count == 0) return error.InvalidRecord;

                var terms = std.ArrayList(VirtualAllDocsSyntheticTerm).empty;
                defer terms.deinit(self.allocator);
                try terms.ensureTotalCapacityPrecise(self.allocator, virtual_count);
                var candidate_it = self.all_docs_candidates.iterator();
                while (candidate_it.next()) |entry| {
                    switch (entry.value_ptr.*) {
                        .virtual => |candidate| {
                            if (candidate.last_seen_doc_id != self.doc_count) return error.InvalidRecord;
                            terms.appendAssumeCapacity(.{
                                .term = entry.key_ptr.*,
                                .text_freq = candidate.text_freq,
                            });
                        },
                        .variable => {},
                    }
                }
                std.mem.sort(VirtualAllDocsSyntheticTerm, terms.items, {}, virtualAllDocsSyntheticTermLessThan);

                const summary_path = try std.fmt.allocPrint(self.allocator, "{s}.virtual_all_docs.summary.tmp", .{self.base_path});
                var summary_path_owned = true;
                errdefer {
                    std.Io.Dir.cwd().deleteFile(self.io, summary_path) catch {};
                    if (summary_path_owned) self.allocator.free(summary_path);
                }

                var summary_file = try std.Io.Dir.cwd().createFile(self.io, summary_path, .{ .read = true, .truncate = true });
                defer summary_file.close(self.io);
                var summary_writer = try TextPostingRunSummaryWriter.init(self.allocator, self.io, summary_file);
                defer summary_writer.deinit();

                var summary_context = CollectTextPostingRunSummaryContext{ .writer = &summary_writer };
                for (terms.items) |term| {
                    const record = try TextPostingRunTermSummaryRecord.initWithFreqSummary(term.term, self.doc_count, term.text_freq, true, self.doc_count == 1);
                    try appendTextPostingRunSummaryRecord(&summary_context, record);

                    const removed = self.all_docs_candidates.fetchRemove(term.term) orelse return error.InvalidRecord;
                    self.invalidateAllDocsCandidateCache();
                    self.markAllDocsCandidateShapeFilterDirty();
                    const candidate = switch (removed.value) {
                        .virtual => |candidate| candidate,
                        .variable => return error.InvalidRecord,
                    };
                    if (candidate.last_seen_doc_id != self.doc_count or candidate.text_freq != term.text_freq) return error.InvalidRecord;
                    var source = TextPostingSyntheticRunSource{ .virtual_all_docs = .{
                        .term = removed.key,
                        .text_freq = candidate.text_freq,
                    } };
                    var source_owned = true;
                    errdefer if (source_owned) source.deinit(self.allocator);
                    try self.synthetic_run_sources.append(self.allocator, source);
                    source_owned = false;
                    self.virtual_all_docs_synthetic_records = std.math.add(u64, self.virtual_all_docs_synthetic_records, self.doc_count) catch return error.RecordTooLarge;
                }
                try summary_writer.flush();
                const summary_stat = try summary_file.stat(self.io);
                if (summary_stat.kind != .file or summary_stat.size != summary_writer.physical_bytes) return error.InvalidRecord;
                summary_context.summary_file_bytes = summary_writer.physical_bytes;

                try self.run_summaries.append(self.allocator, .{
                    .path = summary_path,
                    .term_count = summary_context.term_count,
                    .file_size = summary_context.summary_file_bytes,
                });
                summary_path_owned = false;
            }

            pub fn flushVariableAllDocsCandidates(self: *TextPostingRunBuilder) !void {
                var variable_count: usize = 0;
                var count_it = self.all_docs_candidates.iterator();
                while (count_it.next()) |entry| {
                    switch (entry.value_ptr.*) {
                        .virtual => {},
                        .variable => variable_count += 1,
                    }
                }
                if (variable_count == 0) return;
                if (self.doc_count == 0) return error.InvalidRecord;

                var terms = std.ArrayList(VariableAllDocsSyntheticTerm).empty;
                defer terms.deinit(self.allocator);
                try terms.ensureTotalCapacityPrecise(self.allocator, variable_count);
                var candidate_it = self.all_docs_candidates.iterator();
                while (candidate_it.next()) |entry| {
                    switch (entry.value_ptr.*) {
                        .virtual => {},
                        .variable => |candidate| {
                            if (candidate.last_seen_doc_id != self.doc_count) return error.InvalidRecord;
                            if (@as(u64, @intCast(candidate.freqs.len())) != self.doc_count) return error.InvalidRecord;
                            terms.appendAssumeCapacity(.{ .term = entry.key_ptr.* });
                        },
                    }
                }
                std.mem.sort(VariableAllDocsSyntheticTerm, terms.items, {}, variableAllDocsSyntheticTermLessThan);

                const summary_path = try std.fmt.allocPrint(self.allocator, "{s}.variable_all_docs.summary.tmp", .{self.base_path});
                var summary_path_owned = true;
                errdefer {
                    std.Io.Dir.cwd().deleteFile(self.io, summary_path) catch {};
                    if (summary_path_owned) self.allocator.free(summary_path);
                }

                var summary_file = try std.Io.Dir.cwd().createFile(self.io, summary_path, .{ .read = true, .truncate = true });
                defer summary_file.close(self.io);
                var summary_writer = try TextPostingRunSummaryWriter.init(self.allocator, self.io, summary_file);
                defer summary_writer.deinit();

                var summary_context = CollectTextPostingRunSummaryContext{ .writer = &summary_writer };
                for (terms.items) |term| {
                    const record = try TextPostingRunTermSummaryRecord.initWithFreqSummary(term.term, self.doc_count, 0, true, self.doc_count == 1);
                    try appendTextPostingRunSummaryRecord(&summary_context, record);

                    const removed = self.all_docs_candidates.fetchRemove(term.term) orelse return error.InvalidRecord;
                    self.invalidateAllDocsCandidateCache();
                    self.markAllDocsCandidateShapeFilterDirty();
                    const candidate = switch (removed.value) {
                        .virtual => return error.InvalidRecord,
                        .variable => |candidate| candidate,
                    };
                    if (candidate.last_seen_doc_id != self.doc_count) return error.InvalidRecord;
                    if (@as(u64, @intCast(candidate.freqs.len())) != self.doc_count) return error.InvalidRecord;
                    const freq_stats = try candidate.freqs.slice().sizeStats();
                    if (self.measure_chunks) {
                        self.variable_all_docs_freq_stream_cells = std.math.add(u64, self.variable_all_docs_freq_stream_cells, @intCast(candidate.freqs.len())) catch return error.RecordTooLarge;
                        self.variable_all_docs_freq_stream_packed_bytes = std.math.add(u64, self.variable_all_docs_freq_stream_packed_bytes, freq_stats.packed_bytes) catch return error.RecordTooLarge;
                        self.variable_all_docs_freq_stream_rle_bytes = std.math.add(u64, self.variable_all_docs_freq_stream_rle_bytes, freq_stats.rle_bytes) catch return error.RecordTooLarge;
                        self.variable_all_docs_freq_stream_bitpacked_bytes = std.math.add(u64, self.variable_all_docs_freq_stream_bitpacked_bytes, freq_stats.bitpacked_bytes) catch return error.RecordTooLarge;
                        self.variable_all_docs_freq_stream_rle_run_count = std.math.add(u64, self.variable_all_docs_freq_stream_rle_run_count, freq_stats.rle_run_count) catch return error.RecordTooLarge;
                        self.variable_all_docs_freq_stream_max_freq = @max(self.variable_all_docs_freq_stream_max_freq, freq_stats.max_freq);
                    }
                    var source = TextPostingSyntheticRunSource{ .variable_all_docs = .{
                        .term = removed.key,
                        .freqs = candidate.freqs,
                        .freq_stats = freq_stats,
                    } };
                    var source_owned = true;
                    errdefer if (source_owned) source.deinit(self.allocator);
                    try self.synthetic_run_sources.append(self.allocator, source);
                    source_owned = false;
                    self.variable_all_docs_synthetic_records = std.math.add(u64, self.variable_all_docs_synthetic_records, self.doc_count) catch return error.RecordTooLarge;
                }
                try summary_writer.flush();
                const summary_stat = try summary_file.stat(self.io);
                if (summary_stat.kind != .file or summary_stat.size != summary_writer.physical_bytes) return error.InvalidRecord;
                summary_context.summary_file_bytes = summary_writer.physical_bytes;

                try self.run_summaries.append(self.allocator, .{
                    .path = summary_path,
                    .term_count = summary_context.term_count,
                    .file_size = summary_context.summary_file_bytes,
                });
                summary_path_owned = false;
            }

            pub fn flushRun(self: *TextPostingRunBuilder) !void {
                if (self.chunk.items.len == 0) return;
                if (self.measure_chunks) {
                    const record_bytes = std.math.mul(u64, @intCast(self.chunk.items.len), @as(u64, @sizeOf(TextPostingRunChunkRecord))) catch return error.RecordTooLarge;
                    const term_bytes: u64 = @intCast(self.chunk_term_bytes.items.len);
                    const scratch_bytes = std.math.add(u64, record_bytes, term_bytes) catch return error.RecordTooLarge;
                    const record_capacity_bytes = std.math.mul(u64, @intCast(self.chunk.capacity), @as(u64, @sizeOf(TextPostingRunChunkRecord))) catch return error.RecordTooLarge;
                    const term_capacity_bytes: u64 = @intCast(self.chunk_term_bytes.capacity);
                    const scratch_capacity_bytes = std.math.add(u64, record_capacity_bytes, term_capacity_bytes) catch return error.RecordTooLarge;
                    self.chunk_peak_record_bytes = @max(self.chunk_peak_record_bytes, record_bytes);
                    self.chunk_peak_term_bytes = @max(self.chunk_peak_term_bytes, term_bytes);
                    self.chunk_peak_scratch_bytes = @max(self.chunk_peak_scratch_bytes, scratch_bytes);
                    self.chunk_peak_record_capacity_bytes = @max(self.chunk_peak_record_capacity_bytes, record_capacity_bytes);
                    self.chunk_peak_term_capacity_bytes = @max(self.chunk_peak_term_capacity_bytes, term_capacity_bytes);
                    self.chunk_peak_scratch_capacity_bytes = @max(self.chunk_peak_scratch_capacity_bytes, scratch_capacity_bytes);
                }
                const run_path = try std.fmt.allocPrint(self.allocator, "{s}.posting_run.{d}.tmp", .{ self.base_path, self.run_paths.items.len });
                var run_path_owned = true;
                errdefer {
                    std.Io.Dir.cwd().deleteFile(self.io, run_path) catch {};
                    if (run_path_owned) self.allocator.free(run_path);
                }
                const summary_path = try std.fmt.allocPrint(self.allocator, "{s}.posting_run.{d}.summary.tmp", .{ self.base_path, self.run_paths.items.len });
                var summary_path_owned = true;
                errdefer {
                    std.Io.Dir.cwd().deleteFile(self.io, summary_path) catch {};
                    if (summary_path_owned) self.allocator.free(summary_path);
                }
                if (self.chunk.items.len > std.math.maxInt(u32)) return error.RecordTooLarge;
                const sort_start = if (self.measure_chunks) textMonotonicNs(self.io) else 0;
                std.mem.sort(TextPostingRunChunkRecord, self.chunk.items, self.chunk_term_bytes.items, textPostingRunChunkRecordLessThan);
                if (self.measure_chunks) {
                    self.chunk_sort_ns += textElapsedNs(self.io, sort_start);
                }
                const write_start = if (self.measure_chunks) textMonotonicNs(self.io) else 0;
                const summary_stats = try writeSortedTextPostingRunChunkWithSummary(self.allocator, self.io, run_path, summary_path, self.chunk.items, self.chunk_term_bytes.items);
                if (self.measure_chunks) {
                    self.chunk_write_ns += textElapsedNs(self.io, write_start);
                    self.chunk_count = std.math.add(u64, self.chunk_count, 1) catch return error.RecordTooLarge;
                    self.chunk_records = std.math.add(u64, self.chunk_records, self.chunk.items.len) catch return error.RecordTooLarge;
                    self.inline_singleton_materialized_terms = std.math.add(u64, self.inline_singleton_materialized_terms, summary_stats.inline_singleton_materialized_terms) catch return error.RecordTooLarge;
                    self.inline_singleton_materialized_records = std.math.add(u64, self.inline_singleton_materialized_records, summary_stats.inline_singleton_materialized_records) catch return error.RecordTooLarge;
                    self.inline_singleton_materialized_bytes = std.math.add(u64, self.inline_singleton_materialized_bytes, summary_stats.inline_singleton_materialized_bytes) catch return error.RecordTooLarge;
                }
                try self.run_paths.append(self.allocator, run_path);
                run_path_owned = false;
                try self.run_summaries.append(self.allocator, .{
                    .path = summary_path,
                    .term_count = summary_stats.term_count,
                    .file_size = summary_stats.summary_file_bytes,
                });
                summary_path_owned = false;
                self.chunk_term_bytes.clearRetainingCapacity();
                self.chunk.clearRetainingCapacity();
                self.clearChunkTermCache();
            }

            pub fn compactForFanIn(self: *TextPostingRunBuilder) !void {
                try self.compactForFanInLimit(text_posting_run_direct_merge_fan_in);
            }

            pub fn compactForFanInLimit(self: *TextPostingRunBuilder, fan_in: usize) !void {
                if (fan_in == 0) return error.InvalidRecord;
                if (self.run_paths.items.len <= fan_in) return;

                var pass_index: usize = 0;
                while (self.run_paths.items.len > fan_in) : (pass_index += 1) {
                    var next_run_paths = std.ArrayList([]u8).empty;
                    errdefer {
                        for (next_run_paths.items) |path| {
                            std.Io.Dir.cwd().deleteFile(self.io, path) catch {};
                            self.allocator.free(path);
                        }
                        next_run_paths.deinit(self.allocator);
                    }
                    var next_summaries = std.ArrayList(TextPostingRunSummaryFile).empty;
                    errdefer {
                        for (next_summaries.items) |summary| {
                            std.Io.Dir.cwd().deleteFile(self.io, summary.path) catch {};
                            self.allocator.free(summary.path);
                        }
                        next_summaries.deinit(self.allocator);
                    }

                    var start: usize = 0;
                    var group_index: usize = 0;
                    while (start < self.run_paths.items.len) : (group_index += 1) {
                        const end = @min(start + fan_in, self.run_paths.items.len);
                        const out_path = try std.fmt.allocPrint(self.allocator, "{s}.posting_run.compact.{d}.{d}.tmp", .{ self.base_path, pass_index, group_index });
                        var out_path_owned = true;
                        errdefer {
                            std.Io.Dir.cwd().deleteFile(self.io, out_path) catch {};
                            if (out_path_owned) self.allocator.free(out_path);
                        }
                        const out_summary_path = try std.fmt.allocPrint(self.allocator, "{s}.posting_run.compact.{d}.{d}.summary.tmp", .{ self.base_path, pass_index, group_index });
                        var out_summary_path_owned = true;
                        errdefer {
                            std.Io.Dir.cwd().deleteFile(self.io, out_summary_path) catch {};
                            if (out_summary_path_owned) self.allocator.free(out_summary_path);
                        }

                        const summary_stats = try writeMergedTextPostingRunWithSummary(
                            self.allocator,
                            self.io,
                            self.run_paths.items[start..end],
                            out_path,
                            out_summary_path,
                            .none,
                        );
                        try next_run_paths.append(self.allocator, out_path);
                        out_path_owned = false;
                        try next_summaries.append(self.allocator, .{
                            .path = out_summary_path,
                            .term_count = summary_stats.term_count,
                            .file_size = summary_stats.summary_file_bytes,
                        });
                        out_summary_path_owned = false;

                        for (self.run_paths.items[start..end]) |path| {
                            std.Io.Dir.cwd().deleteFile(self.io, path) catch {};
                            self.allocator.free(path);
                        }
                        for (self.run_summaries.items[start..end]) |summary| {
                            std.Io.Dir.cwd().deleteFile(self.io, summary.path) catch {};
                            self.allocator.free(summary.path);
                        }
                        start = end;
                    }

                    self.run_paths.deinit(self.allocator);
                    self.run_paths = next_run_paths;
                    self.run_summaries.deinit(self.allocator);
                    self.run_summaries = next_summaries;
                }
            }

            pub fn coalesceSummariesForFinalMerge(self: *TextPostingRunBuilder) !void {
                try self.coalesceSummariesForFinalMergeLimit(text_posting_run_merge_fan_in);
            }

            pub fn coalesceSummariesForFinalMergeLimit(self: *TextPostingRunBuilder, fan_in: usize) !void {
                if (fan_in == 0) return error.InvalidRecord;
                if (self.run_summaries.items.len <= fan_in) return;

                const summary_path = try std.fmt.allocPrint(self.allocator, "{s}.posting_run.final.summary.tmp", .{self.base_path});
                var summary_path_owned = true;
                errdefer {
                    std.Io.Dir.cwd().deleteFile(self.io, summary_path) catch {};
                    if (summary_path_owned) self.allocator.free(summary_path);
                }
                var final_stats = TextPostingRunSummaryStats{};
                const summary_stats = try collectTextPostingRunTermSummariesFromFilesToFile(
                    self.allocator,
                    self.io,
                    self.run_summaries.items,
                    summary_path,
                    self.doc_count,
                    &final_stats,
                    .none,
                );

                for (self.run_summaries.items) |summary| {
                    std.Io.Dir.cwd().deleteFile(self.io, summary.path) catch {};
                    self.allocator.free(summary.path);
                }
                self.run_summaries.clearRetainingCapacity();
                try self.run_summaries.append(self.allocator, .{
                    .path = summary_path,
                    .term_count = summary_stats.term_count,
                    .file_size = summary_stats.summary_file_bytes,
                    .final_stats = final_stats,
                });
                summary_path_owned = false;
            }
        };

        test "posting run builder owner rejects zero fan-in without creating artifacts" {
            var builder = try TextPostingRunBuilder.init(std.testing.allocator, std.testing.io, "unused");
            defer builder.deinit();

            try std.testing.expectError(error.InvalidRecord, builder.compactForFanInLimit(0));
            try std.testing.expectError(error.InvalidRecord, builder.coalesceSummariesForFinalMergeLimit(0));
            try std.testing.expectEqual(@as(usize, 0), builder.run_paths.items.len);
            try std.testing.expectEqual(@as(usize, 0), builder.run_summaries.items.len);
        }

        test "posting run builder owner shares repeated chunk term bytes" {
            var builder = try TextPostingRunBuilder.initWithChunkTiming(std.testing.allocator, std.testing.io, "unused", true);
            defer builder.deinit();

            try builder.appendTermPosting("shared", .{ .doc_id = 1, .text_freq = 1, .kind_freq = 0 });
            try builder.appendTermPosting("shared", .{ .doc_id = 2, .text_freq = 1, .kind_freq = 0 });

            try std.testing.expectEqual(@as(usize, "shared".len), builder.chunk_term_bytes.items.len);
            try std.testing.expectEqual(builder.chunk.items[0].term_offset, builder.chunk.items[1].term_offset);
            try std.testing.expectEqual(@as(u64, 1), builder.run_record_term_cache_hits);
            try std.testing.expectEqual(@as(u64, "shared".len), builder.run_record_term_cache_saved_bytes);
        }

        test "posting run builder owner materializes surviving all-doc candidates on finish" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();

            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const base_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "posting-run-owner" });
            defer std.testing.allocator.free(base_path);

            var builder = try TextPostingRunBuilder.init(std.testing.allocator, std.testing.io, base_path);
            defer builder.deinit();
            var freqs = std.StringHashMap(FieldTermFreq).init(std.testing.allocator);
            defer freqs.deinit();
            try freqs.put("shared", .{ .text = 1, .kind = 0 });
            try builder.appendDocumentFreqs(1, &freqs);
            try builder.appendDocumentFreqs(2, &freqs);
            try builder.finish();

            try std.testing.expectEqual(@as(u64, 2), builder.doc_count);
            try std.testing.expect(builder.synthetic_run_sources.items.len > 0);
            try std.testing.expectEqual(@as(usize, 0), builder.chunk.items.len);
        }

        test "posting run builder owner removes owned summary artifacts on deinit" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();

            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const base_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "posting-run-owner" });
            defer std.testing.allocator.free(base_path);

            var builder = try TextPostingRunBuilder.init(std.testing.allocator, std.testing.io, base_path);
            var builder_live = true;
            defer if (builder_live) builder.deinit();
            var freqs = std.StringHashMap(FieldTermFreq).init(std.testing.allocator);
            defer freqs.deinit();
            try freqs.put("storage", .{ .text = 2, .kind = 0 });
            try builder.appendDocumentFreqs(1, &freqs);
            try builder.finish();
            try std.testing.expectEqual(@as(usize, 1), builder.run_summaries.items.len);

            const summary_path = try std.testing.allocator.dupe(u8, builder.run_summaries.items[0].path);
            defer std.testing.allocator.free(summary_path);
            builder.deinit();
            builder_live = false;

            try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(std.testing.io, summary_path, .{}));
        }
    };
}
