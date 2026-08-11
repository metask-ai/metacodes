/// Posting-run encoding, ordered merge, summary publication, and summary
/// aggregation owner. The Text facade supplies the persistent-format types and
/// policy helpers while this module owns the state transitions that turn
/// sorted postings into validated run and summary artifacts.
pub fn PostingRunCodecMerge(comptime Ops: type) type {
    return struct {
        const std = Ops.std;
        const core = Ops.core_dep;
        const default_max_token_bytes = Ops.default_max_token_bytes_dep;
        const text_posting_run_front_coded_prefix_tag_base = Ops.text_posting_run_front_coded_prefix_tag_base_dep;
        const text_write_buffer_bytes = Ops.text_write_buffer_bytes_dep;
        const persistent_term_top_hit_capacity = Ops.persistent_term_top_hit_capacity_dep;
        const persistent_posting_max_field_freq = Ops.persistent_posting_max_field_freq_dep;
        const persistent_posting_block_size = Ops.persistent_posting_block_size_dep;

        const TextPostingRecord = Ops.TextPostingRecord_dep;
        const TextPostingRunRecord = Ops.TextPostingRunRecord_dep;
        const TextPostingRunChunkRecord = Ops.TextPostingRunChunkRecord_dep;
        const TextPostingRunReader = Ops.TextPostingRunReader_dep;
        const DecodedFrontCodedTextPosting = Ops.DecodedFrontCodedTextPosting_dep;
        const DecodedRunTextPostingFields = Ops.DecodedRunTextPostingFields_dep;
        const TextBufferedWriter = Ops.TextBufferedWriter_dep;
        const TextPostingRunSummaryWriter = Ops.TextPostingRunSummaryWriter_dep;
        const CollectTextPostingRunSummaryContext = Ops.CollectTextPostingRunSummaryContext_dep;
        const TextPostingRunFrontCodedWriter = Ops.TextPostingRunFrontCodedWriter_dep;
        const TextPostingRunWriteMode = Ops.TextPostingRunWriteMode_dep;
        const TextPostingRunSummaryCollectMode = Ops.TextPostingRunSummaryCollectMode_dep;
        const TextPostingRunSummaryStats = Ops.TextPostingRunSummaryStats_dep;
        const TextPostingRunMerger = Ops.TextPostingRunMerger_dep;
        const TextPostingSyntheticRunSource = Ops.TextPostingSyntheticRunSource_dep;
        const TextSyntheticPostingRunCursor = Ops.TextSyntheticPostingRunCursor_dep;
        const TextPostingRunTermSummaryRecord = Ops.TextPostingRunTermSummaryRecord_dep;
        const TextPostingRunSummaryFile = Ops.TextPostingRunSummaryFile_dep;
        const TextPostingRunSummaryMerger = Ops.TextPostingRunSummaryMerger_dep;

        const readerReadByte = Ops.readerReadByte_dep;
        const readerReadBytes = Ops.readerReadBytes_dep;
        const readerMinEncodedPostingBytes = Ops.readerMinEncodedPostingBytes_dep;
        const readerReadTextPostingFields = Ops.readerReadTextPostingFields_dep;
        const readerReadDeltaTextPostingFields = Ops.readerReadDeltaTextPostingFields_dep;
        const termSortPrefixKey = Ops.termSortPrefixKey_dep;
        const validateTextPostingFields = Ops.validateTextPostingFields_dep;
        const collectTextPostingRunSummaryFields = Ops.collectTextPostingRunSummaryFields_dep;
        const collectTextPostingRunSummary = Ops.collectTextPostingRunSummary_dep;
        const collectTextPostingRunSummaryChecked = Ops.collectTextPostingRunSummaryChecked_dep;
        const textPostingRunRecordLessThan = Ops.textPostingRunRecordLessThan_dep;
        const textPostingRunSameTermAndDoc = Ops.textPostingRunSameTermAndDoc_dep;
        const persistentTermFrontCodedLen = Ops.persistentTermFrontCodedLen_dep;
        const textPostingRunSummaryLessThan = Ops.textPostingRunSummaryLessThan_dep;
        const textPostingRunSummarySameTerm = Ops.textPostingRunSummarySameTerm_dep;
        const canVirtualizeAllDocsConstantTextFreqTerm = Ops.canVirtualizeAllDocsConstantTextFreqTerm_dep;
        const canUseDenseAllDocsFreqStream = Ops.canUseDenseAllDocsFreqStream_dep;
        const publishedPostingBlockCount = Ops.publishedPostingBlockCount_dep;
        const persistentTermTopHitCountForPostingCount = Ops.persistentTermTopHitCountForPostingCount_dep;

        pub fn readNextFrontCodedTextPosting(self: *TextPostingRunReader) !?DecodedFrontCodedTextPosting {
            if (self.consumed_bytes == self.file_size) return null;
            if (self.consumed_bytes > self.file_size) return error.InvalidRecord;
            if (self.file_size - self.consumed_bytes < 2) return error.InvalidRecord;

            const tag = try readerReadByte(self);
            self.consumed_bytes = std.math.add(u64, self.consumed_bytes, 1) catch return error.InvalidRecord;
            var term_changed = false;
            if (tag == 0) {
                if (self.current_term_len == 0) return error.InvalidRecord;
            } else if (tag <= default_max_token_bytes) {
                const term_len: usize = tag;
                if (self.file_size - self.consumed_bytes < term_len + readerMinEncodedPostingBytes(self)) return error.InvalidRecord;
                try readerReadBytes(self, self.current_term[0..term_len]);
                self.consumed_bytes = std.math.add(u64, self.consumed_bytes, term_len) catch return error.InvalidRecord;
                self.current_term_len = term_len;
                term_changed = true;
            } else {
                if (tag == text_posting_run_front_coded_prefix_tag_base) return error.InvalidRecord;
                if (self.current_term_len == 0) return error.InvalidRecord;
                const prefix_len: usize = tag - text_posting_run_front_coded_prefix_tag_base;
                if (prefix_len > self.current_term_len) return error.InvalidRecord;
                if (self.file_size - self.consumed_bytes < 1 + readerMinEncodedPostingBytes(self)) return error.InvalidRecord;
                const suffix_len = try readerReadByte(self);
                self.consumed_bytes = std.math.add(u64, self.consumed_bytes, 1) catch return error.InvalidRecord;
                if (suffix_len == 0) return error.InvalidRecord;
                const term_len = std.math.add(usize, prefix_len, suffix_len) catch return error.InvalidRecord;
                if (term_len > default_max_token_bytes) return error.InvalidRecord;
                if (self.file_size - self.consumed_bytes < suffix_len + readerMinEncodedPostingBytes(self)) return error.InvalidRecord;
                try readerReadBytes(self, self.current_term[prefix_len..term_len]);
                self.consumed_bytes = std.math.add(u64, self.consumed_bytes, suffix_len) catch return error.InvalidRecord;
                self.current_term_len = term_len;
                term_changed = true;
            }
            if (term_changed) {
                self.current_term_sort_prefix = termSortPrefixKey(self.current_term[0..self.current_term_len]);
                self.previous_doc_id = 0;
            }

            const posting = switch (self.format) {
                .front_coded_terms_fixed_posting => posting: {
                    if (self.file_size - self.consumed_bytes < TextPostingRecord.encoded_len) return error.InvalidRecord;
                    const decoded = try readerReadTextPostingFields(self);
                    self.previous_doc_id = decoded.doc_id;
                    break :posting DecodedRunTextPostingFields{
                        .doc_id = decoded.doc_id,
                        .text_freq = decoded.text_freq,
                        .encoded_len = TextPostingRecord.encoded_len,
                    };
                },
                .front_coded_terms_delta_posting => try readerReadDeltaTextPostingFields(self),
            };
            self.consumed_bytes = std.math.add(u64, self.consumed_bytes, posting.encoded_len) catch return error.InvalidRecord;
            try validateTextPostingFields(posting.doc_id, posting.text_freq, 0);
            return .{
                .doc_id = posting.doc_id,
                .text_freq = posting.text_freq,
                .term_changed = term_changed,
            };
        }

        pub fn writeTextPostingRunChunkTrustedOrderWithSummary(
            allocator: std.mem.Allocator,
            io: std.Io,
            path: []const u8,
            summary_path: []const u8,
            records: []const TextPostingRunChunkRecord,
            term_bytes: []const u8,
            order: []const u32,
        ) !TextPostingRunSummaryStats {
            if (order.len != records.len) return error.InvalidRecord;
            var file = try std.Io.Dir.cwd().createFile(io, path, .{ .read = true, .truncate = true });
            defer file.close(io);
            var summary_file = try std.Io.Dir.cwd().createFile(io, summary_path, .{ .read = true, .truncate = true });
            defer summary_file.close(io);

            var writer = try TextBufferedWriter.init(allocator, io, file, text_write_buffer_bytes);
            defer writer.deinit();
            var summary_writer = try TextPostingRunSummaryWriter.init(allocator, io, summary_file);
            defer summary_writer.deinit();

            var summary_context = CollectTextPostingRunSummaryContext{ .writer = &summary_writer };
            var run_writer = TextPostingRunFrontCodedWriter{ .writer = &writer };
            var expected_size: u64 = try run_writer.writeHeader();
            for (order) |index| {
                if (index >= records.len) return error.InvalidRecord;
                const record = records[index];
                const term = try record.term(term_bytes);
                const posting = TextPostingRecord{
                    .doc_id = record.doc_id,
                    .text_freq = record.text_freq,
                    .kind_freq = record.kind_freq,
                };
                const encoded_len = try run_writer.appendTrustedRecordFields(term, record.doc_id, record.text_freq, record.kind_freq);
                expected_size = std.math.add(u64, expected_size, encoded_len) catch return error.RecordTooLarge;
                try collectTextPostingRunSummaryFields(&summary_context, term, posting, encoded_len);
            }
            try flushTextPostingRunSummary(&summary_context);
            try writer.flush();
            try summary_writer.flush();

            const stat = try file.stat(io);
            if (stat.kind != .file or stat.size != expected_size) return error.InvalidRecord;
            const summary_stat = try summary_file.stat(io);
            if (summary_stat.kind != .file or summary_stat.size != summary_writer.physical_bytes) return error.InvalidRecord;
            summary_context.summary_file_bytes = summary_writer.physical_bytes;
            return summaryStatsFromContext(summary_context);
        }

        pub fn writeSortedTextPostingRunChunkWithSummary(
            allocator: std.mem.Allocator,
            io: std.Io,
            path: []const u8,
            summary_path: []const u8,
            records: []const TextPostingRunChunkRecord,
            term_bytes: []const u8,
        ) !TextPostingRunSummaryStats {
            var file = try std.Io.Dir.cwd().createFile(io, path, .{ .read = true, .truncate = true });
            defer file.close(io);
            var summary_file = try std.Io.Dir.cwd().createFile(io, summary_path, .{ .read = true, .truncate = true });
            defer summary_file.close(io);

            var writer = try TextBufferedWriter.init(allocator, io, file, text_write_buffer_bytes);
            defer writer.deinit();
            var summary_writer = try TextPostingRunSummaryWriter.init(allocator, io, summary_file);
            defer summary_writer.deinit();

            var summary_context = CollectTextPostingRunSummaryContext{ .writer = &summary_writer };
            var run_writer = TextPostingRunFrontCodedWriter{ .writer = &writer };
            var expected_size: u64 = try run_writer.writeHeader();
            for (records) |record| {
                const term = try record.term(term_bytes);
                const posting = TextPostingRecord{
                    .doc_id = record.doc_id,
                    .text_freq = record.text_freq,
                    .kind_freq = record.kind_freq,
                };
                const encoded_len = try run_writer.appendTrustedRecordFields(term, record.doc_id, record.text_freq, record.kind_freq);
                expected_size = std.math.add(u64, expected_size, encoded_len) catch return error.RecordTooLarge;
                try collectTextPostingRunSummaryFields(&summary_context, term, posting, encoded_len);
            }
            try flushTextPostingRunSummary(&summary_context);
            try writer.flush();
            try summary_writer.flush();

            const stat = try file.stat(io);
            if (stat.kind != .file or stat.size != expected_size) return error.InvalidRecord;
            const summary_stat = try summary_file.stat(io);
            if (summary_stat.kind != .file or summary_stat.size != summary_writer.physical_bytes) return error.InvalidRecord;
            summary_context.summary_file_bytes = summary_writer.physical_bytes;
            return summaryStatsFromContext(summary_context);
        }

        fn summaryStatsFromContext(context: CollectTextPostingRunSummaryContext) TextPostingRunSummaryStats {
            return .{
                .term_count = context.term_count,
                .term_bytes_len = context.term_bytes_len,
                .term_exception_count = context.term_exception_count,
                .summary_file_bytes = context.summary_file_bytes,
                .posting_count = context.total_postings,
                .block_count = context.total_blocks,
                .hit_count = context.total_hits,
                .top_hit_term_count = context.top_hit_terms,
                .top_hit_candidate_postings = context.top_hit_candidate_postings,
                .top_hit_side_stream_candidates = context.top_hit_side_stream_candidates,
                .top_hit_local_side_stream_candidates = context.top_hit_local_side_stream_candidates,
                .inline_singleton_materialized_terms = context.inline_singleton_materialized_terms,
                .inline_singleton_materialized_records = context.inline_singleton_materialized_records,
                .inline_singleton_materialized_bytes = context.inline_singleton_materialized_bytes,
            };
        }

        pub fn writeTextPostingRunInOrderWithSummaryMode(
            allocator: std.mem.Allocator,
            io: std.Io,
            path: []const u8,
            summary_path: []const u8,
            records: []const TextPostingRunRecord,
            order: []const u32,
            mode: TextPostingRunWriteMode,
        ) !TextPostingRunSummaryStats {
            if (order.len != records.len) return error.InvalidRecord;
            var file = try std.Io.Dir.cwd().createFile(io, path, .{ .read = true, .truncate = true });
            defer file.close(io);
            var summary_file = try std.Io.Dir.cwd().createFile(io, summary_path, .{ .read = true, .truncate = true });
            defer summary_file.close(io);

            var writer = try TextBufferedWriter.init(allocator, io, file, text_write_buffer_bytes);
            defer writer.deinit();
            var summary_writer = try TextPostingRunSummaryWriter.init(allocator, io, summary_file);
            defer summary_writer.deinit();

            var summary_context = CollectTextPostingRunSummaryContext{ .writer = &summary_writer };
            var run_writer = TextPostingRunFrontCodedWriter{ .writer = &writer };
            var previous: ?TextPostingRunRecord = null;
            var expected_size: u64 = try run_writer.writeHeader();
            for (order) |index| {
                if (index >= records.len) return error.InvalidRecord;
                const record = records[index];
                if (mode == .checked and previous != null) {
                    const prev = previous.?;
                    if (!textPostingRunRecordLessThan({}, prev, record)) return error.InvalidRecord;
                }
                if (mode == .checked) previous = record;
                const encoded_len = switch (mode) {
                    .checked => try run_writer.append(record),
                    .trusted_sorted_records => try run_writer.appendTrusted(record),
                };
                expected_size = std.math.add(u64, expected_size, encoded_len) catch return error.RecordTooLarge;
                const summary_mode: TextPostingRunSummaryCollectMode = switch (mode) {
                    .checked => .checked,
                    .trusted_sorted_records => .trusted_record_fields,
                };
                try collectTextPostingRunSummary(&summary_context, record, summary_mode, encoded_len);
            }
            try flushTextPostingRunSummary(&summary_context);
            try writer.flush();
            try summary_writer.flush();

            const stat = try file.stat(io);
            if (stat.kind != .file or stat.size != expected_size) return error.InvalidRecord;
            const summary_stat = try summary_file.stat(io);
            if (summary_stat.kind != .file or summary_stat.size != summary_writer.physical_bytes) return error.InvalidRecord;
            summary_context.summary_file_bytes = summary_writer.physical_bytes;
            return summaryStatsFromContext(summary_context);
        }

        pub fn writeMergedTextPostingRunWithSummary(
            allocator: std.mem.Allocator,
            io: std.Io,
            run_paths: []const []const u8,
            path: []const u8,
            summary_path: []const u8,
            deadline: core.QueryDeadline,
        ) !TextPostingRunSummaryStats {
            var file = try std.Io.Dir.cwd().createFile(io, path, .{ .read = true, .truncate = true });
            defer file.close(io);
            var summary_file = try std.Io.Dir.cwd().createFile(io, summary_path, .{ .read = true, .truncate = true });
            defer summary_file.close(io);

            var writer = try TextBufferedWriter.init(allocator, io, file, text_write_buffer_bytes);
            defer writer.deinit();
            var summary_writer = try TextPostingRunSummaryWriter.init(allocator, io, summary_file);
            defer summary_writer.deinit();

            var merger = try TextPostingRunMerger.init(allocator, io, run_paths);
            defer merger.deinit();
            var summary_context = CollectTextPostingRunSummaryContext{ .writer = &summary_writer };
            var run_writer = TextPostingRunFrontCodedWriter{ .writer = &writer };
            var previous: ?TextPostingRunRecord = null;
            var expected_size: u64 = try run_writer.writeHeader();

            while (try merger.next()) |record| {
                if (deadline.expired()) return core.Error.BudgetExceeded;
                if (previous) |prev| {
                    if (!textPostingRunRecordLessThan({}, prev, record)) return error.InvalidRecord;
                }
                previous = record;
                const encoded_len = try run_writer.append(record);
                expected_size = std.math.add(u64, expected_size, encoded_len) catch return error.RecordTooLarge;
                try collectTextPostingRunSummary(&summary_context, record, .checked, encoded_len);
            }

            try flushTextPostingRunSummary(&summary_context);
            try writer.flush();
            try summary_writer.flush();
            const stat = try file.stat(io);
            if (stat.kind != .file or stat.size != expected_size) return error.InvalidRecord;
            const summary_stat = try summary_file.stat(io);
            if (summary_stat.kind != .file or summary_stat.size != summary_writer.physical_bytes) return error.InvalidRecord;
            summary_context.summary_file_bytes = summary_writer.physical_bytes;
            return summaryStatsFromContext(summary_context);
        }

        pub fn forEachMergedTextPostingRun(
            allocator: std.mem.Allocator,
            io: std.Io,
            run_paths: []const []const u8,
            deadline: core.QueryDeadline,
            context: anytype,
            comptime callback: fn (@TypeOf(context), TextPostingRunRecord) anyerror!void,
        ) !void {
            var merger = try TextPostingRunMerger.init(allocator, io, run_paths);
            defer merger.deinit();

            var previous: ?TextPostingRunRecord = null;
            while (try merger.next()) |record| {
                if (deadline.expired()) return core.Error.BudgetExceeded;
                if (previous) |prev| {
                    if (!textPostingRunRecordLessThan({}, prev, record)) return error.InvalidRecord;
                }
                previous = record;
                try callback(context, record);
            }
        }

        pub fn forEachMergedTextPostingRunWithSynthetic(
            allocator: std.mem.Allocator,
            io: std.Io,
            run_paths: []const []const u8,
            synthetic_sources: []const TextPostingSyntheticRunSource,
            doc_count: u64,
            deadline: core.QueryDeadline,
            context: anytype,
            comptime callback: fn (@TypeOf(context), TextPostingRunRecord) anyerror!void,
        ) !void {
            var merger = try TextPostingRunMerger.init(allocator, io, run_paths);
            defer merger.deinit();
            var synthetic_cursor = TextSyntheticPostingRunCursor{ .sources = synthetic_sources };

            var next_run_record = try merger.next();
            var next_synthetic_record = try synthetic_cursor.nextWithDocCount(doc_count);
            var previous: ?TextPostingRunRecord = null;

            while (next_run_record != null or next_synthetic_record != null) {
                if (deadline.expired()) return core.Error.BudgetExceeded;
                const take_synthetic = if (next_run_record) |run_record|
                    if (next_synthetic_record) |synthetic_record|
                        textPostingRunRecordLessThan({}, synthetic_record, run_record)
                    else
                        false
                else
                    true;
                const record = if (take_synthetic) blk: {
                    const current = next_synthetic_record orelse return error.InvalidRecord;
                    next_synthetic_record = try synthetic_cursor.nextWithDocCount(doc_count);
                    break :blk current;
                } else blk: {
                    const current = next_run_record orelse return error.InvalidRecord;
                    next_run_record = try merger.next();
                    break :blk current;
                };
                if (previous) |prev| {
                    if (!textPostingRunRecordLessThan({}, prev, record)) {
                        if (textPostingRunSameTermAndDoc(prev, record)) return error.InvalidRecord;
                        return error.InvalidRecord;
                    }
                }
                previous = record;
                try callback(context, record);
            }
        }

        pub fn appendTextPostingRunSummaryRecord(context: *CollectTextPostingRunSummaryContext, record: TextPostingRunTermSummaryRecord) !void {
            var header: [TextPostingRunTermSummaryRecord.header_len]u8 = undefined;
            record.encodeHeader(&header);
            try context.writer.append(&header);
            try context.writer.append(record.term());
            const previous_term: ?[]const u8 = if (context.have_previous_flushed_term)
                context.previous_flushed_term[0..context.previous_flushed_term_len]
            else
                null;
            const encoded_term_len = try persistentTermFrontCodedLen(context.term_count, previous_term, record.term());
            context.term_count = std.math.add(u64, context.term_count, 1) catch return error.RecordTooLarge;
            context.term_bytes_len = std.math.add(u64, context.term_bytes_len, encoded_term_len) catch return error.RecordTooLarge;
            context.summary_file_bytes = std.math.add(u64, context.summary_file_bytes, record.packedLen()) catch return error.RecordTooLarge;
            context.total_postings = std.math.add(u64, context.total_postings, record.postings_count) catch return error.RecordTooLarge;
            if (!record.inlineSingleton()) context.term_exception_count = std.math.add(u64, context.term_exception_count, 1) catch return error.RecordTooLarge;
            context.total_blocks = std.math.add(u64, context.total_blocks, record.block_count) catch return error.RecordTooLarge;
            context.total_hits = std.math.add(u64, context.total_hits, record.top_hit_count) catch return error.RecordTooLarge;
            context.top_hit_side_stream_candidates = std.math.add(u64, context.top_hit_side_stream_candidates, @min(record.postings_count, persistent_term_top_hit_capacity)) catch return error.RecordTooLarge;
            context.top_hit_local_side_stream_candidates = std.math.add(u64, context.top_hit_local_side_stream_candidates, record.top_hit_count) catch return error.RecordTooLarge;
            if (record.top_hit_count != 0) {
                context.top_hit_terms = std.math.add(u64, context.top_hit_terms, 1) catch return error.RecordTooLarge;
                context.top_hit_candidate_postings = std.math.add(u64, context.top_hit_candidate_postings, record.postings_count) catch return error.RecordTooLarge;
            }
            if (record.inlineSingleton()) {
                context.inline_singleton_materialized_terms = std.math.add(u64, context.inline_singleton_materialized_terms, 1) catch return error.RecordTooLarge;
                context.inline_singleton_materialized_records = std.math.add(u64, context.inline_singleton_materialized_records, record.postings_count) catch return error.RecordTooLarge;
                context.inline_singleton_materialized_bytes = std.math.add(u64, context.inline_singleton_materialized_bytes, context.current_term_materialized_bytes) catch return error.RecordTooLarge;
            }
            @memcpy(context.previous_flushed_term[0..record.term().len], record.term());
            context.previous_flushed_term_len = record.term().len;
            context.have_previous_flushed_term = true;
        }

        pub fn flushTextPostingRunSummary(context: *CollectTextPostingRunSummaryContext) !void {
            if (context.current_term_len == 0) return;
            const record = try TextPostingRunTermSummaryRecord.initWithFreqSummary(context.current_term[0..context.current_term_len], context.postings_count, context.constant_text_freq, context.all_text_freqs, context.inline_singleton);
            try appendTextPostingRunSummaryRecord(context, record);
            context.current_term_len = 0;
            context.postings_count = 0;
            context.constant_text_freq = 0;
            context.inline_singleton = false;
            context.current_term_materialized_bytes = 0;
            context.all_text_freqs = false;
        }

        pub fn collectTextPostingRunTermSummariesToFile(
            allocator: std.mem.Allocator,
            io: std.Io,
            run_paths: []const []const u8,
            summary_path: []const u8,
            deadline: core.QueryDeadline,
        ) !TextPostingRunSummaryStats {
            var file = try std.Io.Dir.cwd().createFile(io, summary_path, .{ .read = true, .truncate = true });
            defer file.close(io);
            var writer = try TextPostingRunSummaryWriter.init(allocator, io, file);
            defer writer.deinit();
            var context = CollectTextPostingRunSummaryContext{ .writer = &writer };
            try forEachMergedTextPostingRun(allocator, io, run_paths, deadline, &context, collectTextPostingRunSummaryChecked);
            try flushTextPostingRunSummary(&context);
            try writer.flush();
            const stat = try file.stat(io);
            if (stat.kind != .file or stat.size != writer.physical_bytes) return error.InvalidRecord;
            context.summary_file_bytes = writer.physical_bytes;
            return summaryStatsFromContext(context);
        }

        fn appendMergedTextPostingRunSummaryToFile(
            context: *CollectTextPostingRunSummaryContext,
            final_stats: ?*TextPostingRunSummaryStats,
            final_doc_count: ?u64,
            term: []const u8,
            postings_count: u64,
            constant_text_freq: u32,
            all_text_freqs: bool,
            inline_singleton: bool,
        ) !void {
            const record = try TextPostingRunTermSummaryRecord.initWithFreqSummary(term, postings_count, constant_text_freq, all_text_freqs, inline_singleton);
            try appendTextPostingRunSummaryRecord(context, record);
            if (final_stats) |stats| {
                const doc_count = final_doc_count orelse return error.InvalidRecord;
                try addMergedTextPostingRunSummaryStats(stats, term, postings_count, constant_text_freq, all_text_freqs, inline_singleton, doc_count);
            }
        }

        pub fn collectTextPostingRunTermSummariesFromFilesToFile(
            allocator: std.mem.Allocator,
            io: std.Io,
            summary_files: []const TextPostingRunSummaryFile,
            summary_path: []const u8,
            final_doc_count: ?u64,
            final_stats_out: ?*TextPostingRunSummaryStats,
            deadline: core.QueryDeadline,
        ) !TextPostingRunSummaryStats {
            if (final_stats_out != null and final_doc_count == null) return error.InvalidRecord;
            var file = try std.Io.Dir.cwd().createFile(io, summary_path, .{ .read = true, .truncate = true });
            defer file.close(io);
            var writer = try TextPostingRunSummaryWriter.init(allocator, io, file);
            defer writer.deinit();
            var context = CollectTextPostingRunSummaryContext{ .writer = &writer };
            var merger = try TextPostingRunSummaryMerger.init(allocator, io, summary_files);
            defer merger.deinit();

            var previous: ?TextPostingRunTermSummaryRecord = null;
            var side_stream_candidates: u64 = 0;
            var local_side_stream_candidates: u64 = 0;
            var final_stats = TextPostingRunSummaryStats{};
            const maybe_final_stats: ?*TextPostingRunSummaryStats = if (final_doc_count != null) &final_stats else null;
            var current_term: [default_max_token_bytes]u8 = [_]u8{0} ** default_max_token_bytes;
            var current_term_len: usize = 0;
            var postings_count: u64 = 0;
            var constant_text_freq: u32 = 0;
            var all_text_freqs = false;
            var inline_singleton = false;
            while (try merger.next()) |summary| {
                if (deadline.expired()) return core.Error.BudgetExceeded;
                if (previous) |prev| {
                    if (!textPostingRunSummaryLessThan({}, prev, summary) and !textPostingRunSummarySameTerm(prev, summary)) return error.InvalidRecord;
                }
                previous = summary;
                side_stream_candidates = std.math.add(u64, side_stream_candidates, @min(summary.postings_count, persistent_term_top_hit_capacity)) catch return error.RecordTooLarge;
                local_side_stream_candidates = std.math.add(u64, local_side_stream_candidates, summary.top_hit_count) catch return error.RecordTooLarge;
                if (current_term_len != 0) {
                    if (current_term_len == summary.term().len and std.mem.eql(u8, current_term[0..current_term_len], summary.term())) {
                        postings_count = std.math.add(u64, postings_count, summary.postings_count) catch return error.RecordTooLarge;
                        if (constant_text_freq != 0 and summary.constantTextFreq() != constant_text_freq) constant_text_freq = 0;
                        all_text_freqs = all_text_freqs and summary.allTextFreqs();
                        inline_singleton = false;
                        continue;
                    }
                    try appendMergedTextPostingRunSummaryToFile(&context, maybe_final_stats, final_doc_count, current_term[0..current_term_len], postings_count, constant_text_freq, all_text_freqs, inline_singleton);
                }
                @memcpy(current_term[0..summary.term().len], summary.term());
                current_term_len = summary.term().len;
                postings_count = summary.postings_count;
                constant_text_freq = summary.constantTextFreq();
                all_text_freqs = summary.allTextFreqs();
                inline_singleton = summary.inlineSingleton();
            }
            if (current_term_len != 0) try appendMergedTextPostingRunSummaryToFile(&context, maybe_final_stats, final_doc_count, current_term[0..current_term_len], postings_count, constant_text_freq, all_text_freqs, inline_singleton);
            try writer.flush();
            const stat = try file.stat(io);
            if (stat.kind != .file or stat.size != writer.physical_bytes) return error.InvalidRecord;
            context.summary_file_bytes = writer.physical_bytes;
            if (final_doc_count != null) {
                final_stats.top_hit_side_stream_candidates = side_stream_candidates;
                final_stats.top_hit_local_side_stream_candidates = local_side_stream_candidates;
                if (final_stats.term_count != context.term_count) return error.InvalidRecord;
                if (final_stats_out) |out| out.* = final_stats;
            }
            var stats = summaryStatsFromContext(context);
            stats.top_hit_side_stream_candidates = side_stream_candidates;
            stats.top_hit_local_side_stream_candidates = local_side_stream_candidates;
            return stats;
        }

        pub fn addMergedTextPostingRunSummaryStats(stats: *TextPostingRunSummaryStats, term: []const u8, postings_count: u64, constant_text_freq: u32, all_text_freqs: bool, inline_singleton: bool, doc_count: u64) !void {
            if (term.len == 0 or term.len > default_max_token_bytes) return error.InvalidRecord;
            if (postings_count == 0 or postings_count > std.math.maxInt(u32)) return error.InvalidRecord;
            if (inline_singleton and postings_count != 1) return error.InvalidRecord;
            if (constant_text_freq > persistent_posting_max_field_freq) return error.RecordTooLarge;
            if (constant_text_freq != 0 and !all_text_freqs) return error.InvalidRecord;
            const previous_term: ?[]const u8 = if (stats.have_previous_term) stats.previous_term[0..stats.previous_term_len] else null;
            const encoded_term_len = try persistentTermFrontCodedLen(stats.term_count, previous_term, term);
            const virtual_all_docs = canVirtualizeAllDocsConstantTextFreqTerm(postings_count, doc_count, constant_text_freq);
            const dense_all_docs_freq_stream = canUseDenseAllDocsFreqStream(postings_count, doc_count, all_text_freqs, constant_text_freq);
            const block_count: u64 = if (virtual_all_docs or dense_all_docs_freq_stream) 0 else try publishedPostingBlockCount(@intCast(postings_count), persistent_posting_block_size);
            const top_hit_count = persistentTermTopHitCountForPostingCount(postings_count);
            stats.term_count = std.math.add(u64, stats.term_count, 1) catch return error.RecordTooLarge;
            stats.term_bytes_len = std.math.add(u64, stats.term_bytes_len, encoded_term_len) catch return error.RecordTooLarge;
            stats.summary_file_bytes = std.math.add(u64, stats.summary_file_bytes, TextPostingRunTermSummaryRecord.header_len + @as(u64, term.len)) catch return error.RecordTooLarge;
            stats.posting_count = std.math.add(u64, stats.posting_count, postings_count) catch return error.RecordTooLarge;
            if (!inline_singleton) stats.term_exception_count = std.math.add(u64, stats.term_exception_count, 1) catch return error.RecordTooLarge;
            stats.block_count = std.math.add(u64, stats.block_count, block_count) catch return error.RecordTooLarge;
            stats.hit_count = std.math.add(u64, stats.hit_count, top_hit_count) catch return error.RecordTooLarge;
            if (top_hit_count != 0) {
                stats.top_hit_term_count = std.math.add(u64, stats.top_hit_term_count, 1) catch return error.RecordTooLarge;
                stats.top_hit_candidate_postings = std.math.add(u64, stats.top_hit_candidate_postings, postings_count) catch return error.RecordTooLarge;
            }
            if (top_hit_count != 0 and !virtual_all_docs and !dense_all_docs_freq_stream and constant_text_freq != 0) stats.regular_constant_top_hit_term_count = std.math.add(u64, stats.regular_constant_top_hit_term_count, 1) catch return error.RecordTooLarge;
            if (virtual_all_docs) {
                stats.virtual_all_docs_term_count = std.math.add(u64, stats.virtual_all_docs_term_count, 1) catch return error.RecordTooLarge;
                stats.virtual_all_docs_candidate_records = std.math.add(u64, stats.virtual_all_docs_candidate_records, postings_count) catch return error.RecordTooLarge;
            } else if (dense_all_docs_freq_stream) {
                stats.dense_all_docs_freq_stream_term_count = std.math.add(u64, stats.dense_all_docs_freq_stream_term_count, 1) catch return error.RecordTooLarge;
                stats.dense_all_docs_freq_stream_candidate_records = std.math.add(u64, stats.dense_all_docs_freq_stream_candidate_records, postings_count) catch return error.RecordTooLarge;
            }
            @memcpy(stats.previous_term[0..term.len], term);
            stats.previous_term_len = term.len;
            stats.have_previous_term = true;
        }

        pub fn collectTextPostingRunTermSummaryStatsFromFiles(
            allocator: std.mem.Allocator,
            io: std.Io,
            summary_files: []const TextPostingRunSummaryFile,
            doc_count: u64,
            deadline: core.QueryDeadline,
        ) !TextPostingRunSummaryStats {
            if (deadline.expired()) return core.Error.BudgetExceeded;
            if (summary_files.len == 1) {
                if (summary_files[0].final_stats) |stats| {
                    if (stats.term_count != summary_files[0].term_count) return error.InvalidRecord;
                    return stats;
                }
            }
            var merger = try TextPostingRunSummaryMerger.init(allocator, io, summary_files);
            defer merger.deinit();
            var stats = TextPostingRunSummaryStats{};
            var current_term: [default_max_token_bytes]u8 = [_]u8{0} ** default_max_token_bytes;
            var current_term_len: usize = 0;
            var postings_count: u64 = 0;
            var constant_text_freq: u32 = 0;
            var all_text_freqs = false;
            var inline_singleton = false;
            var previous: ?TextPostingRunTermSummaryRecord = null;
            while (try merger.next()) |summary| {
                if (deadline.expired()) return core.Error.BudgetExceeded;
                if (previous) |prev| {
                    if (!textPostingRunSummaryLessThan({}, prev, summary) and !textPostingRunSummarySameTerm(prev, summary)) return error.InvalidRecord;
                }
                previous = summary;
                stats.top_hit_side_stream_candidates = std.math.add(u64, stats.top_hit_side_stream_candidates, @min(summary.postings_count, persistent_term_top_hit_capacity)) catch return error.RecordTooLarge;
                stats.top_hit_local_side_stream_candidates = std.math.add(u64, stats.top_hit_local_side_stream_candidates, summary.top_hit_count) catch return error.RecordTooLarge;
                if (current_term_len != 0) {
                    if (current_term_len == summary.term().len and std.mem.eql(u8, current_term[0..current_term_len], summary.term())) {
                        postings_count = std.math.add(u64, postings_count, summary.postings_count) catch return error.RecordTooLarge;
                        if (constant_text_freq != 0 and summary.constantTextFreq() != constant_text_freq) constant_text_freq = 0;
                        all_text_freqs = all_text_freqs and summary.allTextFreqs();
                        inline_singleton = false;
                        continue;
                    }
                    try addMergedTextPostingRunSummaryStats(&stats, current_term[0..current_term_len], postings_count, constant_text_freq, all_text_freqs, inline_singleton, doc_count);
                }
                @memcpy(current_term[0..summary.term().len], summary.term());
                current_term_len = summary.term().len;
                postings_count = summary.postings_count;
                constant_text_freq = summary.constantTextFreq();
                all_text_freqs = summary.allTextFreqs();
                inline_singleton = summary.inlineSingleton();
            }
            if (current_term_len != 0) try addMergedTextPostingRunSummaryStats(&stats, current_term[0..current_term_len], postings_count, constant_text_freq, all_text_freqs, inline_singleton, doc_count);
            return stats;
        }

        test "posting run codec owner writes and reads ordered front-coded artifacts" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const run_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "owner.run" });
            defer std.testing.allocator.free(run_path);
            const summary_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "owner.summary" });
            defer std.testing.allocator.free(summary_path);

            const records = [_]TextPostingRunRecord{
                try TextPostingRunRecord.init("alpha", .{ .doc_id = 1, .text_freq = 1, .kind_freq = 0 }),
                try TextPostingRunRecord.init("beta", .{ .doc_id = 2, .text_freq = 2, .kind_freq = 0 }),
            };
            const order = [_]u32{ 0, 1 };
            const stats = try writeTextPostingRunInOrderWithSummaryMode(
                std.testing.allocator,
                std.testing.io,
                run_path,
                summary_path,
                &records,
                &order,
                .checked,
            );
            try std.testing.expectEqual(@as(u64, 2), stats.term_count);
            try std.testing.expectEqual(@as(u64, 2), stats.posting_count);

            var file = try std.Io.Dir.cwd().openFile(std.testing.io, run_path, .{});
            const stat = try file.stat(std.testing.io);
            var reader = try TextPostingRunReader.init(std.testing.allocator, std.testing.io, file, stat.size);
            defer reader.deinit();
            for (records) |expected| {
                const actual = (try reader.nextRecord()) orelse return error.InvalidRecord;
                try std.testing.expectEqualStrings(expected.term(), actual.term());
                try std.testing.expectEqual(expected.doc_id, actual.doc_id);
                try std.testing.expectEqual(expected.text_freq, actual.text_freq);
            }
            try std.testing.expect((try reader.nextRecord()) == null);
        }

        test "posting run codec owner aggregates summary statistics" {
            var stats = TextPostingRunSummaryStats{};
            try addMergedTextPostingRunSummaryStats(&stats, "alpha", 1, 1, true, true, 4);
            try addMergedTextPostingRunSummaryStats(&stats, "beta", 2, 0, true, false, 4);
            try std.testing.expectEqual(@as(u64, 2), stats.term_count);
            try std.testing.expectEqual(@as(u64, 3), stats.posting_count);
            try std.testing.expectEqual(@as(u64, 1), stats.term_exception_count);
            try std.testing.expect(stats.term_bytes_len > 0);
        }

        test "posting run codec owner enforces immediate summary deadline" {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
            const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
            const run_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "deadline.run" });
            defer std.testing.allocator.free(run_path);
            const initial_summary_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "deadline.initial.summary" });
            defer std.testing.allocator.free(initial_summary_path);
            const merged_summary_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "deadline.merged.summary" });
            defer std.testing.allocator.free(merged_summary_path);

            const records = [_]TextPostingRunRecord{
                try TextPostingRunRecord.init("storage", .{ .doc_id = 7, .text_freq = 1, .kind_freq = 0 }),
            };
            const order = [_]u32{0};
            _ = try writeTextPostingRunInOrderWithSummaryMode(
                std.testing.allocator,
                std.testing.io,
                run_path,
                initial_summary_path,
                &records,
                &order,
                .checked,
            );
            try std.testing.expectError(
                core.Error.BudgetExceeded,
                collectTextPostingRunTermSummariesToFile(
                    std.testing.allocator,
                    std.testing.io,
                    &.{run_path},
                    merged_summary_path,
                    .immediate,
                ),
            );
        }
    };
}
