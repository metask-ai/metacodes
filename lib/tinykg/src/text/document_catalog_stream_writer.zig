const std = @import("std");

/// Owns the two document-catalog streaming write paths. The stable Text
/// façade supplies storage, tokenizer, posting-builder, timing, and atomic
/// publication mechanics through a private compile-time backend.
pub fn DocumentCatalogStreamWriter(
    comptime core: type,
    comptime storage_mod: type,
    comptime Ops: type,
) type {
    return struct {
        const TextBufferedWriter = Ops.TextBufferedWriter_dep;
        const TextDocRecord = Ops.TextDocRecord_dep;
        const TextDocsHeader = Ops.TextDocsHeader_dep;
        const TextDocNodeIdOverflowRecord = Ops.TextDocNodeIdOverflowRecord_dep;
        const FieldTermFreq = Ops.FieldTermFreq_dep;
        const TextPostingRunBuilder = Ops.TextPostingRunBuilder_dep;
        const PersistentTermBuilder = Ops.PersistentTermBuilder_dep;
        const PersistentTextMeta = Ops.PersistentTextMeta_dep;
        const PersistentTextRebuildTimings = Ops.PersistentTextRebuildTimings_dep;
        const PersistentTextRebuildObserver = Ops.PersistentTextRebuildObserver_dep;
        const SearchableNodeMetadata = Ops.SearchableNodeMetadata_dep;
        const SearchableNodeMetadataSnapshot = Ops.SearchableNodeMetadataSnapshot_dep;
        const TextRebuildTextFreqCache = Ops.TextRebuildTextFreqCache_dep;
        const clearReusableArenaTermFreqs = Ops.clearReusableArenaTermFreqs_dep;
        const clearReusableTermFreqs = Ops.clearReusableTermFreqs_dep;
        const searchableNodeTextBytes = Ops.searchableNodeTextBytes_dep;
        const collectStreamingSearchableNodeTermFreqs = Ops.collectStreamingSearchableNodeTermFreqs_dep;
        const collectSearchableNodeTermFreqs = Ops.collectSearchableNodeTermFreqs_dep;
        const textMonotonicNs = Ops.textMonotonicNs_dep;
        const textElapsedNs = Ops.textElapsedNs_dep;
        const persistent_doc_max_field_tokens = Ops.persistent_doc_max_field_tokens_dep;
        const persistent_doc_node_id_inline_max = Ops.persistent_doc_node_id_inline_max_dep;
        const nextPersistentTextDocId = Ops.nextPersistentTextDocId_dep;
        const isDeletedNodeTombstoneText = Ops.isDeletedNodeTombstoneText_dep;
        const isDeletedNodeTombstoneNode = Ops.isDeletedNodeTombstoneNode_dep;
        const textDocsPath = Ops.textDocsPath_dep;
        const tmpPathFor = Ops.tmpPathFor_dep;
        const text_write_buffer_bytes = Ops.text_write_buffer_bytes_dep;
        const text_rebuild_observer_doc_sample_interval = Ops.text_rebuild_observer_doc_sample_interval_dep;
        const recordPersistentTextRebuildObserver = Ops.recordPersistentTextRebuildObserver_dep;
        const textOptionsNeedSync = Ops.textOptionsNeedSync_dep;
        const renameReplace = Ops.renameReplace_dep;

        fn appendRunTextDocFromNode(
            term_allocator: std.mem.Allocator,
            scratch_allocator: std.mem.Allocator,
            writer: *TextBufferedWriter,
            record_bytes: *[TextDocRecord.encoded_len]u8,
            docs_header: TextDocsHeader,
            overflow_records: *std.ArrayList(TextDocNodeIdOverflowRecord),
            freqs: *std.StringHashMap(FieldTermFreq),
            term_arena: *std.heap.ArenaAllocator,
            tokenizer_scratch: *std.ArrayList(u8),
            text_freq_cache: *TextRebuildTextFreqCache,
            run_builder: *TextPostingRunBuilder,
            text_meta: *PersistentTextMeta,
            timings: ?*PersistentTextRebuildTimings,
            node_id: core.NodeId,
            kind: core.NodeKind,
            text: []const u8,
            metadata: SearchableNodeMetadata,
        ) !void {
            clearReusableArenaTermFreqs(freqs, term_arena);

            if (timings) |t| {
                t.docs_node_count = std.math.add(u64, t.docs_node_count, 1) catch return error.RecordTooLarge;
                t.docs_text_bytes = std.math.add(u64, t.docs_text_bytes, try searchableNodeTextBytes(text, metadata)) catch return error.RecordTooLarge;
            }
            const doc_id = try nextPersistentTextDocId(text_meta.doc_count);
            const tokenize_start = if (timings != null) textMonotonicNs(run_builder.io) else 0;
            const can_use_text_freq_cache = metadata.name == null and metadata.summary == null;
            const text_tokens = if (can_use_text_freq_cache) tokens: {
                if (timings) |t| t.docs_freq_cache_lookup_count += 1;
                if (text_freq_cache.lookup(text)) |cached| {
                    try text_freq_cache.populateFreqs(freqs, cached);
                    if (timings) |t| t.docs_freq_cache_hit_count += 1;
                    break :tokens cached.text_tokens;
                }
                if (timings) |t| t.docs_freq_cache_miss_count += 1;
                const collected = try collectStreamingSearchableNodeTermFreqs(term_allocator, scratch_allocator, freqs, null, text, metadata, tokenizer_scratch);
                if (text_freq_cache.disabled) break :tokens collected;
                _ = text_freq_cache.store(text, collected, freqs) catch |err| switch (err) {
                    error.RecordTooLarge, error.InvalidRecord => if (text_freq_cache.disabled)
                        null
                    else
                        return err,
                    else => |e| return e,
                };
                break :tokens collected;
            } else try collectStreamingSearchableNodeTermFreqs(term_allocator, scratch_allocator, freqs, null, text, metadata, tokenizer_scratch);
            if (timings) |t| {
                t.docs_tokenize_ns += textElapsedNs(run_builder.io, tokenize_start);
                t.docs_token_count = std.math.add(u64, t.docs_token_count, text_tokens) catch return error.RecordTooLarge;
            }
            if (text_tokens > persistent_doc_max_field_tokens) return error.RecordTooLarge;

            text_meta.total_text_tokens = std.math.add(u64, text_meta.total_text_tokens, text_tokens) catch return error.RecordTooLarge;
            const record = TextDocRecord{
                .doc_id = doc_id,
                .node_id = node_id.toInt(),
                .kind = @intFromEnum(kind),
                .text_tokens = @intCast(text_tokens),
            };
            const append_start = if (timings != null) textMonotonicNs(run_builder.io) else 0;
            try run_builder.appendDocumentFreqs(doc_id, freqs);
            if (timings) |t| t.docs_posting_append_ns += textElapsedNs(run_builder.io, append_start);
            const write_start = if (timings != null) textMonotonicNs(run_builder.io) else 0;
            try record.encodeForHeader(docs_header, record_bytes[0..docs_header.recordLen()]);
            try writer.append(record_bytes[0..docs_header.recordLen()]);
            if (record.needsNodeIdOverflow()) {
                try overflow_records.append(scratch_allocator, try TextDocNodeIdOverflowRecord.init(record));
            }
            if (timings) |t| t.docs_write_ns += textElapsedNs(run_builder.io, write_start);
            text_meta.doc_count = doc_id;
        }

        fn appendBuilderTextDocFromNode(
            allocator: std.mem.Allocator,
            writer: *TextBufferedWriter,
            record_bytes: *[TextDocRecord.encoded_len]u8,
            docs_header: TextDocsHeader,
            overflow_records: *std.ArrayList(TextDocNodeIdOverflowRecord),
            freqs: *std.StringHashMap(FieldTermFreq),
            owned: *std.ArrayList([]u8),
            term_builder: *PersistentTermBuilder,
            text_meta: *PersistentTextMeta,
            timings: ?*PersistentTextRebuildTimings,
            io: std.Io,
            node_id: core.NodeId,
            kind: core.NodeKind,
            text: []const u8,
            metadata: SearchableNodeMetadata,
        ) !void {
            clearReusableTermFreqs(allocator, freqs, owned);

            if (timings) |t| {
                t.docs_node_count = std.math.add(u64, t.docs_node_count, 1) catch return error.RecordTooLarge;
                t.docs_text_bytes = std.math.add(u64, t.docs_text_bytes, try searchableNodeTextBytes(text, metadata)) catch return error.RecordTooLarge;
            }
            const tokenize_start = if (timings != null) textMonotonicNs(io) else 0;
            const text_tokens = try collectSearchableNodeTermFreqs(allocator, freqs, owned, text, metadata);
            if (timings) |t| {
                t.docs_tokenize_ns += textElapsedNs(io, tokenize_start);
                t.docs_token_count = std.math.add(u64, t.docs_token_count, text_tokens) catch return error.RecordTooLarge;
            }
            if (text_tokens > persistent_doc_max_field_tokens) return error.RecordTooLarge;
            const doc_id = try nextPersistentTextDocId(text_meta.doc_count);
            const append_start = if (timings != null) textMonotonicNs(io) else 0;
            try term_builder.addDocumentFreqs(doc_id, freqs);
            if (timings) |t| t.docs_posting_append_ns += textElapsedNs(io, append_start);

            text_meta.total_text_tokens = std.math.add(u64, text_meta.total_text_tokens, text_tokens) catch return error.RecordTooLarge;
            const record = TextDocRecord{
                .doc_id = doc_id,
                .node_id = node_id.toInt(),
                .kind = @intFromEnum(kind),
                .text_tokens = @intCast(text_tokens),
            };
            const write_start = if (timings != null) textMonotonicNs(io) else 0;
            try record.encodeForHeader(docs_header, record_bytes[0..docs_header.recordLen()]);
            try writer.append(record_bytes[0..docs_header.recordLen()]);
            if (record.needsNodeIdOverflow()) {
                try overflow_records.append(allocator, try TextDocNodeIdOverflowRecord.init(record));
            }
            if (timings) |t| t.docs_write_ns += textElapsedNs(io, write_start);
            text_meta.doc_count = doc_id;
        }

        const TextDocsTextSource = enum {
            inline_or_mapped,
            borrowed,
            allocated,
        };

        fn recordTextDocsTextSource(timings: ?*PersistentTextRebuildTimings, source: TextDocsTextSource, text_len: usize) void {
            const t = timings orelse return;
            const bytes: u64 = @intCast(text_len);
            switch (source) {
                .inline_or_mapped => {
                    t.docs_text_inline_count += 1;
                    t.docs_text_inline_bytes += bytes;
                },
                .borrowed => {
                    t.docs_text_borrowed_count += 1;
                    t.docs_text_borrowed_bytes += bytes;
                },
                .allocated => {
                    t.docs_text_alloc_count += 1;
                    t.docs_text_alloc_bytes += bytes;
                },
            }
        }

        fn detectTextDocsHeaderLayout(store: storage_mod.Store, deadline: core.QueryDeadline) !TextDocsHeader {
            if (deadline.expired()) return core.Error.BudgetExceeded;
            if (try store.searchableNodeIndexLayoutHint()) |hint| {
                if (hint.node_count != 0 and hint.dense_node_id_base != 0) {
                    if (hint.uniform_kind) |uniform_kind| {
                        const max_node_id = std.math.add(u64, hint.dense_node_id_base, hint.node_count - 1) catch return error.InvalidRecord;
                        if (max_node_id <= persistent_doc_node_id_inline_max) {
                            return TextDocsHeader.denseUniform(hint.node_count, hint.dense_node_id_base, uniform_kind);
                        }
                    }
                }
                return .{ .doc_count = hint.node_count };
            }

            var nodes = try store.nodeRecordsIterator(null);
            defer nodes.deinit();

            var doc_count: u64 = 0;
            var dense_base: u64 = 0;
            var dense_node_ids = true;
            var uniform_kind: ?core.NodeKind = null;
            var uniform_kind_ok = true;

            while (try nodes.nextRef()) |node| {
                if (deadline.expired()) return core.Error.BudgetExceeded;
                if (node.kind == .edit) {
                    if (node.text_bytes) |text| {
                        if (isDeletedNodeTombstoneText(text)) continue;
                    } else {
                        const text = try nodes.readRefTextAlloc(store.allocator, node);
                        defer store.allocator.free(text);
                        if (isDeletedNodeTombstoneText(text)) continue;
                    }
                }
                const node_id = node.id.toInt();
                if (doc_count == 0) {
                    dense_base = node_id;
                    uniform_kind = node.kind;
                } else {
                    if (uniform_kind.? != node.kind) uniform_kind_ok = false;
                }
                const expected_node_id = std.math.add(u64, dense_base, doc_count) catch {
                    dense_node_ids = false;
                    doc_count = std.math.add(u64, doc_count, 1) catch return error.RecordTooLarge;
                    continue;
                };
                if (node_id != expected_node_id or node_id > persistent_doc_node_id_inline_max) dense_node_ids = false;
                doc_count = std.math.add(u64, doc_count, 1) catch return error.RecordTooLarge;
            }

            if (doc_count != 0 and dense_node_ids and uniform_kind_ok and dense_base != 0 and dense_base <= std.math.maxInt(u32)) {
                return TextDocsHeader.denseUniform(doc_count, @intCast(dense_base), uniform_kind.?);
            }
            return .{ .doc_count = doc_count };
        }

        pub fn writeTextDocsFileFromStore(
            allocator: std.mem.Allocator,
            store: storage_mod.Store,
            deadline: core.QueryDeadline,
            run_builder: *TextPostingRunBuilder,
            text_meta: *PersistentTextMeta,
            timings: ?*PersistentTextRebuildTimings,
            observer: ?PersistentTextRebuildObserver,
        ) !void {
            const path = try textDocsPath(allocator, store);
            defer allocator.free(path);
            const tmp_path = try tmpPathFor(allocator, path);
            defer allocator.free(tmp_path);
            errdefer std.Io.Dir.cwd().deleteFile(store.io, tmp_path) catch {};
            const layout_start = if (timings != null) textMonotonicNs(store.io) else 0;
            const layout_header = try detectTextDocsHeaderLayout(store, deadline);
            if (timings) |t| t.docs_layout_ns = textElapsedNs(store.io, layout_start);

            {
                const include_metadata = text_meta.searchable_metadata_digest != 0;
                var metadata_snapshot: ?SearchableNodeMetadataSnapshot = if (include_metadata)
                    try SearchableNodeMetadataSnapshot.init(allocator, store)
                else
                    null;
                defer if (metadata_snapshot) |*snapshot| snapshot.deinit();
                var file = try std.Io.Dir.cwd().createFile(store.io, tmp_path, .{ .read = true, .truncate = true });
                defer file.close(store.io);
                var writer = try TextBufferedWriter.init(allocator, store.io, file, text_write_buffer_bytes);
                defer writer.deinit();

                var header_bytes: [TextDocsHeader.encoded_len]u8 = undefined;
                layout_header.encode(&header_bytes);
                try writer.append(&header_bytes);
                var record_bytes: [TextDocRecord.encoded_len]u8 = undefined;
                var overflow_records = std.ArrayList(TextDocNodeIdOverflowRecord).empty;
                defer overflow_records.deinit(allocator);
                var term_arena = std.heap.ArenaAllocator.init(allocator);
                defer term_arena.deinit();
                const term_allocator = term_arena.allocator();
                var tokenizer_scratch = std.ArrayList(u8).empty;
                defer tokenizer_scratch.deinit(allocator);
                var text_freq_cache = TextRebuildTextFreqCache.init(allocator);
                defer text_freq_cache.deinit();
                var freqs = std.StringHashMap(FieldTermFreq).init(allocator);
                defer freqs.deinit();

                var nodes = try store.nodeRecordsIterator(null);
                defer nodes.deinit();
                while (true) {
                    const iter_start = if (timings != null) textMonotonicNs(store.io) else 0;
                    const maybe_node = try nodes.nextRef();
                    if (timings) |t| t.docs_node_iter_ns += textElapsedNs(store.io, iter_start);
                    const node = maybe_node orelse break;
                    if (deadline.expired()) return core.Error.BudgetExceeded;
                    if (node.text_bytes) |text| {
                        recordTextDocsTextSource(timings, .inline_or_mapped, text.len);
                        if (isDeletedNodeTombstoneNode(node.kind, text)) continue;
                        const metadata = if (metadata_snapshot) |*snapshot| snapshot.get(node.id) else SearchableNodeMetadata{};
                        try appendRunTextDocFromNode(term_allocator, allocator, &writer, &record_bytes, layout_header, &overflow_records, &freqs, &term_arena, &tokenizer_scratch, &text_freq_cache, run_builder, text_meta, timings, node.id, node.kind, text, metadata);
                    } else {
                        const text_read_start = if (timings != null) textMonotonicNs(store.io) else 0;
                        const borrowed_text = try nodes.readRefTextBorrowed(node);
                        if (borrowed_text) |text| {
                            if (timings) |t| t.docs_text_read_ns += textElapsedNs(store.io, text_read_start);
                            recordTextDocsTextSource(timings, .borrowed, text.len);
                            if (isDeletedNodeTombstoneNode(node.kind, text)) continue;
                            const metadata = if (metadata_snapshot) |*snapshot| snapshot.get(node.id) else SearchableNodeMetadata{};
                            try appendRunTextDocFromNode(term_allocator, allocator, &writer, &record_bytes, layout_header, &overflow_records, &freqs, &term_arena, &tokenizer_scratch, &text_freq_cache, run_builder, text_meta, timings, node.id, node.kind, text, metadata);
                        } else {
                            const text = try nodes.readRefTextAlloc(allocator, node);
                            defer allocator.free(text);
                            if (timings) |t| t.docs_text_read_ns += textElapsedNs(store.io, text_read_start);
                            recordTextDocsTextSource(timings, .allocated, text.len);
                            if (isDeletedNodeTombstoneNode(node.kind, text)) continue;
                            const metadata = if (metadata_snapshot) |*snapshot| snapshot.get(node.id) else SearchableNodeMetadata{};
                            try appendRunTextDocFromNode(term_allocator, allocator, &writer, &record_bytes, layout_header, &overflow_records, &freqs, &term_arena, &tokenizer_scratch, &text_freq_cache, run_builder, text_meta, timings, node.id, node.kind, text, metadata);
                        }
                    }
                    if (observer) |obs| {
                        if (text_meta.doc_count % text_rebuild_observer_doc_sample_interval == 0) {
                            try recordPersistentTextRebuildObserver(obs, .docs_progress);
                        }
                    }
                }
                var overflow_bytes: [TextDocNodeIdOverflowRecord.encoded_len]u8 = undefined;
                for (overflow_records.items) |overflow| {
                    try overflow.encode(&overflow_bytes);
                    try writer.append(&overflow_bytes);
                }
                try writer.flush();
                try run_builder.appendRepeatedTextCacheRun(&text_freq_cache);

                if (timings) |t| {
                    t.docs_freq_cache_entry_count = @intCast(text_freq_cache.entries.items.len);
                    t.docs_freq_cache_text_bytes = @intCast(text_freq_cache.text_bytes);
                    t.docs_freq_cache_term_count = @intCast(text_freq_cache.term_count);
                    t.docs_freq_cache_term_bytes = @intCast(text_freq_cache.term_bytes);
                }

                if (text_meta.doc_count != layout_header.doc_count) return error.InvalidRecord;
                var final_header = layout_header;
                final_header.node_id_overflow_count = @intCast(overflow_records.items.len);
                try final_header.validateShape();
                final_header.encode(&header_bytes);
                try file.writePositionalAll(store.io, &header_bytes, 0);
                if (textOptionsNeedSync(store)) try file.sync(store.io);
            }
            try renameReplace(store.io, tmp_path, path);
        }

        pub fn writeTextDocsFileFromStoreWithTermBuilder(
            allocator: std.mem.Allocator,
            store: storage_mod.Store,
            deadline: core.QueryDeadline,
            term_builder: *PersistentTermBuilder,
            text_meta: *PersistentTextMeta,
            timings: ?*PersistentTextRebuildTimings,
        ) !void {
            const path = try textDocsPath(allocator, store);
            defer allocator.free(path);
            const tmp_path = try tmpPathFor(allocator, path);
            defer allocator.free(tmp_path);
            errdefer std.Io.Dir.cwd().deleteFile(store.io, tmp_path) catch {};
            const layout_start = if (timings != null) textMonotonicNs(store.io) else 0;
            const layout_header = try detectTextDocsHeaderLayout(store, deadline);
            if (timings) |t| t.docs_layout_ns = textElapsedNs(store.io, layout_start);

            {
                const include_metadata = text_meta.searchable_metadata_digest != 0;
                var metadata_snapshot: ?SearchableNodeMetadataSnapshot = if (include_metadata)
                    try SearchableNodeMetadataSnapshot.init(allocator, store)
                else
                    null;
                defer if (metadata_snapshot) |*snapshot| snapshot.deinit();
                var file = try std.Io.Dir.cwd().createFile(store.io, tmp_path, .{ .read = true, .truncate = true });
                defer file.close(store.io);
                var writer = try TextBufferedWriter.init(allocator, store.io, file, text_write_buffer_bytes);
                defer writer.deinit();

                var header_bytes: [TextDocsHeader.encoded_len]u8 = undefined;
                layout_header.encode(&header_bytes);
                try writer.append(&header_bytes);
                var record_bytes: [TextDocRecord.encoded_len]u8 = undefined;
                var overflow_records = std.ArrayList(TextDocNodeIdOverflowRecord).empty;
                defer overflow_records.deinit(allocator);
                var freqs = std.StringHashMap(FieldTermFreq).init(allocator);
                defer freqs.deinit();
                var owned = std.ArrayList([]u8).empty;
                defer {
                    for (owned.items) |term| allocator.free(term);
                    owned.deinit(allocator);
                }

                var nodes = try store.nodeRecordsIterator(null);
                defer nodes.deinit();
                while (true) {
                    const iter_start = if (timings != null) textMonotonicNs(store.io) else 0;
                    const maybe_node = try nodes.nextRef();
                    if (timings) |t| t.docs_node_iter_ns += textElapsedNs(store.io, iter_start);
                    const node = maybe_node orelse break;
                    if (deadline.expired()) return core.Error.BudgetExceeded;
                    if (node.text_bytes) |text| {
                        recordTextDocsTextSource(timings, .inline_or_mapped, text.len);
                        if (isDeletedNodeTombstoneNode(node.kind, text)) continue;
                        const metadata = if (metadata_snapshot) |*snapshot| snapshot.get(node.id) else SearchableNodeMetadata{};
                        try appendBuilderTextDocFromNode(allocator, &writer, &record_bytes, layout_header, &overflow_records, &freqs, &owned, term_builder, text_meta, timings, store.io, node.id, node.kind, text, metadata);
                    } else {
                        const text_read_start = if (timings != null) textMonotonicNs(store.io) else 0;
                        const borrowed_text = try nodes.readRefTextBorrowed(node);
                        if (borrowed_text) |text| {
                            if (timings) |t| t.docs_text_read_ns += textElapsedNs(store.io, text_read_start);
                            recordTextDocsTextSource(timings, .borrowed, text.len);
                            if (isDeletedNodeTombstoneNode(node.kind, text)) continue;
                            const metadata = if (metadata_snapshot) |*snapshot| snapshot.get(node.id) else SearchableNodeMetadata{};
                            try appendBuilderTextDocFromNode(allocator, &writer, &record_bytes, layout_header, &overflow_records, &freqs, &owned, term_builder, text_meta, timings, store.io, node.id, node.kind, text, metadata);
                        } else {
                            const text = try nodes.readRefTextAlloc(allocator, node);
                            defer allocator.free(text);
                            if (timings) |t| t.docs_text_read_ns += textElapsedNs(store.io, text_read_start);
                            recordTextDocsTextSource(timings, .allocated, text.len);
                            if (isDeletedNodeTombstoneNode(node.kind, text)) continue;
                            const metadata = if (metadata_snapshot) |*snapshot| snapshot.get(node.id) else SearchableNodeMetadata{};
                            try appendBuilderTextDocFromNode(allocator, &writer, &record_bytes, layout_header, &overflow_records, &freqs, &owned, term_builder, text_meta, timings, store.io, node.id, node.kind, text, metadata);
                        }
                    }
                }
                var overflow_bytes: [TextDocNodeIdOverflowRecord.encoded_len]u8 = undefined;
                for (overflow_records.items) |overflow| {
                    try overflow.encode(&overflow_bytes);
                    try writer.append(&overflow_bytes);
                }
                try writer.flush();

                if (text_meta.doc_count != layout_header.doc_count) return error.InvalidRecord;
                var final_header = layout_header;
                final_header.node_id_overflow_count = @intCast(overflow_records.items.len);
                try final_header.validateShape();
                final_header.encode(&header_bytes);
                try file.writePositionalAll(store.io, &header_bytes, 0);
                if (textOptionsNeedSync(store)) try file.sync(store.io);
            }
            try renameReplace(store.io, tmp_path, path);
        }

        pub const Internal = struct {
            pub const detectHeaderLayout = detectTextDocsHeaderLayout;
            pub const recordTextSource = recordTextDocsTextSource;
        };
    };
}

const TestCore = struct {
    pub const NodeId = struct {
        value: u64,
        pub fn toInt(self: @This()) u64 {
            return self.value;
        }
    };
    pub const NodeKind = enum(u16) { note = 1, edit = 2 };
    pub const Error = error{BudgetExceeded};
    pub const QueryDeadline = struct {
        is_expired: bool = false,
        pub fn expired(self: @This()) bool {
            return self.is_expired;
        }
    };
};

const TestStore = struct {
    hint: ?LayoutHint,
    allocator: std.mem.Allocator = std.testing.allocator,
    pub const LayoutHint = struct {
        node_count: u64,
        dense_node_id_base: u64,
        uniform_kind: ?TestCore.NodeKind,
    };
    pub fn searchableNodeIndexLayoutHint(self: @This()) !?LayoutHint {
        return self.hint;
    }
    const Node = struct {
        id: TestCore.NodeId,
        kind: TestCore.NodeKind,
        text_bytes: ?[]const u8,
    };
    const Iterator = struct {
        pub fn deinit(_: *@This()) void {}
        pub fn nextRef(_: *@This()) !?Node {
            return null;
        }
        pub fn readRefTextAlloc(_: *@This(), allocator: std.mem.Allocator, _: Node) ![]u8 {
            return allocator.dupe(u8, "");
        }
    };
    pub fn nodeRecordsIterator(_: @This(), _: ?u64) !Iterator {
        return .{};
    }
};

const TestStorage = struct {
    pub const Store = TestStore;
};
const TestHeader = struct {
    doc_count: u64 = 0,
    dense_node_id_base: u32 = 0,
    uniform_kind: ?TestCore.NodeKind = null,
    pub fn denseUniform(count: u64, base: u64, kind: TestCore.NodeKind) @This() {
        return .{ .doc_count = count, .dense_node_id_base = @intCast(base), .uniform_kind = kind };
    }
};
const TestTimings = struct {
    docs_text_inline_count: u64 = 0,
    docs_text_inline_bytes: u64 = 0,
    docs_text_borrowed_count: u64 = 0,
    docs_text_borrowed_bytes: u64 = 0,
    docs_text_alloc_count: u64 = 0,
    docs_text_alloc_bytes: u64 = 0,
};
const TestOps = struct {
    pub const TextBufferedWriter_dep = void;
    pub const TextDocRecord_dep = void;
    pub const TextDocsHeader_dep = TestHeader;
    pub const TextDocNodeIdOverflowRecord_dep = void;
    pub const FieldTermFreq_dep = void;
    pub const TextPostingRunBuilder_dep = void;
    pub const PersistentTermBuilder_dep = void;
    pub const PersistentTextMeta_dep = void;
    pub const PersistentTextRebuildTimings_dep = TestTimings;
    pub const PersistentTextRebuildObserver_dep = void;
    pub const SearchableNodeMetadata_dep = void;
    pub const SearchableNodeMetadataSnapshot_dep = void;
    pub const TextRebuildTextFreqCache_dep = void;
    pub const clearReusableArenaTermFreqs_dep = void;
    pub const clearReusableTermFreqs_dep = void;
    pub const searchableNodeTextBytes_dep = void;
    pub const collectStreamingSearchableNodeTermFreqs_dep = void;
    pub const collectSearchableNodeTermFreqs_dep = void;
    pub const textMonotonicNs_dep = void;
    pub const textElapsedNs_dep = void;
    pub const persistent_doc_max_field_tokens_dep: u64 = 0;
    pub const persistent_doc_node_id_inline_max_dep: u64 = std.math.maxInt(u32);
    pub const nextPersistentTextDocId_dep = void;
    pub fn isDeletedNodeTombstoneText_dep(_: []const u8) bool {
        return false;
    }
    pub const isDeletedNodeTombstoneNode_dep = void;
    pub const textDocsPath_dep = void;
    pub const tmpPathFor_dep = void;
    pub const text_write_buffer_bytes_dep: usize = 0;
    pub const text_rebuild_observer_doc_sample_interval_dep: u64 = 1;
    pub const recordPersistentTextRebuildObserver_dep = void;
    pub const textOptionsNeedSync_dep = void;
    pub const renameReplace_dep = void;
};
const test_owner = DocumentCatalogStreamWriter(TestCore, TestStorage, TestOps);

test "document catalog writer accepts dense uniform layout hints" {
    const header = try test_owner.Internal.detectHeaderLayout(.{
        .hint = .{ .node_count = 4, .dense_node_id_base = 7, .uniform_kind = .note },
    }, .{});
    try std.testing.expectEqual(@as(u64, 4), header.doc_count);
    try std.testing.expectEqual(@as(u32, 7), header.dense_node_id_base);
    try std.testing.expectEqual(TestCore.NodeKind.note, header.uniform_kind.?);
}

test "document catalog writer falls back from nonuniform layout hints" {
    const header = try test_owner.Internal.detectHeaderLayout(.{
        .hint = .{ .node_count = 4, .dense_node_id_base = 7, .uniform_kind = null },
    }, .{});
    try std.testing.expectEqual(@as(u64, 4), header.doc_count);
    try std.testing.expectEqual(@as(u32, 0), header.dense_node_id_base);
}

test "document catalog writer enforces deadline before layout discovery" {
    try std.testing.expectError(
        error.BudgetExceeded,
        test_owner.Internal.detectHeaderLayout(.{ .hint = null }, .{ .is_expired = true }),
    );
}

test "document catalog writer records each text ownership lane" {
    var timings = TestTimings{};
    test_owner.Internal.recordTextSource(&timings, .inline_or_mapped, 3);
    test_owner.Internal.recordTextSource(&timings, .borrowed, 5);
    test_owner.Internal.recordTextSource(&timings, .allocated, 7);
    try std.testing.expectEqual(@as(u64, 1), timings.docs_text_inline_count);
    try std.testing.expectEqual(@as(u64, 3), timings.docs_text_inline_bytes);
    try std.testing.expectEqual(@as(u64, 1), timings.docs_text_borrowed_count);
    try std.testing.expectEqual(@as(u64, 5), timings.docs_text_borrowed_bytes);
    try std.testing.expectEqual(@as(u64, 1), timings.docs_text_alloc_count);
    try std.testing.expectEqual(@as(u64, 7), timings.docs_text_alloc_bytes);
}
