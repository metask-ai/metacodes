const std = @import("std");

/// Owns full and bounded-stale validation for the persistent text catalog,
/// including document/header agreement, term/posting shape, block impacts,
/// sparse top-hit indexes, and publication anchor identity.
pub fn PersistentCatalogValidation(comptime core: type, comptime storage_mod: type, comptime Ops: type) type {
    return struct {
        const PersistentTextMeta = Ops.PersistentTextMeta_dep;
        const TextDocsHeader = Ops.TextDocsHeader_dep;
        const TextDocRecord = Ops.TextDocRecord_dep;
        const TextPostingsFileView = Ops.TextPostingsFileView_dep;
        const TextPostingsHeader = Ops.TextPostingsHeader_dep;
        const TextPostingBlocksHeader = Ops.TextPostingBlocksHeader_dep;
        const TextPostingBlockImpactsHeader = Ops.TextPostingBlockImpactsHeader_dep;
        const TextTermTopHitsHeader = Ops.TextTermTopHitsHeader_dep;
        const TextTermsHeader = Ops.TextTermsHeader_dep;
        const TextPostingBlockStats = Ops.TextPostingBlockStats_dep;
        const readPersistentTextMeta = Ops.readPersistentTextMeta_dep;
        const currentPersistentTextMetaAnchor = Ops.currentPersistentTextMetaAnchor_dep;
        const textDocsPath = Ops.textDocsPath_dep;
        const regularFileSize = Ops.regularFileSize_dep;
        const readTextDocsHeaderFromFile = Ops.readTextDocsHeaderFromFile_dep;
        const textDocsFileSizeForHeader = Ops.textDocsFileSizeForHeader_dep;
        const stale_store_scan_max_property_delta_bytes = Ops.stale_store_scan_max_property_delta_bytes_dep;
        const readTextDocRecordAtWithHeader = Ops.readTextDocRecordAtWithHeader_dep;
        const readTextDocNodeIdOverflowRecordAt = Ops.readTextDocNodeIdOverflowRecordAt_dep;
        const textDocRecordOffsetForHeader = Ops.textDocRecordOffsetForHeader_dep;
        const persistent_doc_node_id_overflow_marker = Ops.persistent_doc_node_id_overflow_marker_dep;
        const isDeletedNodeTombstoneNode = Ops.isDeletedNodeTombstoneNode_dep;
        const readSearchableNodeMetadata = Ops.readSearchableNodeMetadata_dep;
        const validateTextDocAgainstNodeRefCached = Ops.validateTextDocAgainstNodeRefCached_dep;
        const textTermsPath = Ops.textTermsPath_dep;
        const readTextTermsHeaderFromFile = Ops.readTextTermsHeaderFromFile_dep;
        const textTermsFileSizeForHeader = Ops.textTermsFileSizeForHeader_dep;
        const textPostingsPath = Ops.textPostingsPath_dep;
        const textPostingsFileSize = Ops.textPostingsFileSize_dep;
        const readTextPostingsHeaderFromFile = Ops.readTextPostingsHeaderFromFile_dep;
        const textPostingBlocksPath = Ops.textPostingBlocksPath_dep;
        const readTextPostingBlocksHeaderFromFile = Ops.readTextPostingBlocksHeaderFromFile_dep;
        const persistent_posting_block_size = Ops.persistent_posting_block_size_dep;
        const textPostingBlocksFileSize = Ops.textPostingBlocksFileSize_dep;
        const textPostingBlockImpactsPath = Ops.textPostingBlockImpactsPath_dep;
        const readTextPostingBlockImpactsHeaderFromFile = Ops.readTextPostingBlockImpactsHeaderFromFile_dep;
        const textPostingBlockImpactsFileSize = Ops.textPostingBlockImpactsFileSize_dep;
        const persistentAvgDocLen = Ops.persistentAvgDocLen_dep;
        const textTermTopHitsPath = Ops.textTermTopHitsPath_dep;
        const readTextTermTopHitsHeaderFromFile = Ops.readTextTermTopHitsHeaderFromFile_dep;
        const persistent_term_top_hit_capacity = Ops.persistent_term_top_hit_capacity_dep;
        const textTermTopHitsFileSize = Ops.textTermTopHitsFileSize_dep;
        const readTextTermTopHitTermRecordAt = Ops.readTextTermTopHitTermRecordAt_dep;
        const readTextTermEntryAt = Ops.readTextTermEntryAt_dep;
        const termEntryHasInlinePosting = Ops.termEntryHasInlinePosting_dep;
        const termEntryVirtualAllDocsTextFreq = Ops.termEntryVirtualAllDocsTextFreq_dep;
        const termEntryDenseAllDocsFreqStreamOffset = Ops.termEntryDenseAllDocsFreqStreamOffset_dep;
        const persistent_term_byte_offset_checkpoint_terms = Ops.persistent_term_byte_offset_checkpoint_terms_dep;
        const readTextTermByteOffsetCheckpointAt = Ops.readTextTermByteOffsetCheckpointAt_dep;
        const readFrontCodedTermAtOffset = Ops.readFrontCodedTermAtOffset_dep;
        const persistent_posting_block_offset_checkpoint_terms = Ops.persistent_posting_block_offset_checkpoint_terms_dep;
        const readTextPostingBlockOffsetCheckpointAt = Ops.readTextPostingBlockOffsetCheckpointAt_dep;
        const publishedPostingBlockCountForEntry = Ops.publishedPostingBlockCountForEntry_dep;
        const SkipTextPostingContext = Ops.SkipTextPostingContext_dep;
        const scanPersistentTermPostings = Ops.scanPersistentTermPostings_dep;
        const skipTextPosting = Ops.skipTextPosting_dep;
        const scanPersistentPostingBlocks = Ops.scanPersistentPostingBlocks_dep;
        const textTermExceptionMembershipBytes = Ops.textTermExceptionMembershipBytes_dep;
        const readTextTermExceptionMembershipByteAt = Ops.readTextTermExceptionMembershipByteAt_dep;
        const persistent_term_exception_rank_checkpoint_terms = Ops.persistent_term_exception_rank_checkpoint_terms_dep;
        const readTextTermExceptionRankCheckpointAt = Ops.readTextTermExceptionRankCheckpointAt_dep;
        const readTextTermExceptionRecordAt = Ops.readTextTermExceptionRecordAt_dep;
        const readTextPostingImpactBlockIndexAt = Ops.readTextPostingImpactBlockIndexAt_dep;
        const readTextPostingBlockRecordAt = Ops.readTextPostingBlockRecordAt_dep;
        const bm25WeightedTermScore = Ops.bm25WeightedTermScore_dep;
        const textPostingBlockRecordConservativelyMatches = Ops.textPostingBlockRecordConservativelyMatches_dep;
        const textPostingBlockRecordFromStats = Ops.textPostingBlockRecordFromStats_dep;
        const persistent_posting_block_byte_offset_checkpoint_blocks = Ops.persistent_posting_block_byte_offset_checkpoint_blocks_dep;
        const readTextPostingBlockByteOffsetCheckpointAt = Ops.readTextPostingBlockByteOffsetCheckpointAt_dep;

        pub fn persistentTextMetaAnchorStale(text_meta: PersistentTextMeta, index_meta: storage_mod.IndexMeta, searchable_metadata_digest: u64) bool {
            return persistentTextGraphAnchorStale(text_meta, index_meta) or
                text_meta.searchable_metadata_digest != searchable_metadata_digest;
        }

        pub fn persistentTextGraphAnchorStale(text_meta: PersistentTextMeta, index_meta: storage_mod.IndexMeta) bool {
            return text_meta.node_digest != index_meta.node_digest or
                text_meta.node_by_text_order_digest != index_meta.node_by_text_order_digest;
        }

        pub fn persistentTextCatalogStale(allocator: std.mem.Allocator, store: storage_mod.Store) !bool {
            return persistentTextCatalogStaleDeadline(allocator, store, .none);
        }

        /// Cheap enough for status/reporting paths: validates the publication anchors
        /// and file headers without scanning every document/posting.  A true result
        /// means callers must not treat the on-disk BM25 files as current.
        pub fn persistentTextCatalogQuickStale(allocator: std.mem.Allocator, store: storage_mod.Store) !bool {
            return persistentTextCatalogQuickStaleDeadline(allocator, store, .none);
        }

        pub fn persistentTextCatalogStaleDeadline(allocator: std.mem.Allocator, store: storage_mod.Store, deadline: core.QueryDeadline) !bool {
            if (deadline.expired()) return core.Error.BudgetExceeded;
            const text_meta = readPersistentTextMeta(allocator, store) catch |err| switch (err) {
                error.FileNotFound, error.InvalidRecord => return true,
                else => |e| return e,
            };
            if (deadline.expired()) return core.Error.BudgetExceeded;
            const index_meta = currentPersistentTextMetaAnchor(store) catch |err| switch (err) {
                error.FileNotFound, error.InvalidRecord => return true,
                else => |e| return e,
            };
            if (persistentTextGraphAnchorStale(text_meta, index_meta)) return true;
            const searchable_metadata_digest = store.searchableNodeMetadataDigest(allocator) catch |err| switch (err) {
                error.FileNotFound, error.InvalidRecord => return true,
                else => |e| return e,
            };
            if (persistentTextMetaAnchorStale(text_meta, index_meta, searchable_metadata_digest)) return true;

            const docs_path = try textDocsPath(allocator, store);
            defer allocator.free(docs_path);
            var docs_file = std.Io.Dir.cwd().openFile(store.io, docs_path, .{}) catch |err| switch (err) {
                error.FileNotFound => return true,
                else => |e| return e,
            };
            defer docs_file.close(store.io);
            const docs_size = try regularFileSize(store, docs_file);
            const header = readTextDocsHeaderFromFile(store, docs_file) catch |err| switch (err) {
                error.InvalidRecord => return true,
                else => |e| return e,
            };
            if (header.doc_count != text_meta.doc_count) return true;
            const expected_size = textDocsFileSizeForHeader(header) catch |err| switch (err) {
                error.RecordTooLarge => return true,
                else => |e| return e,
            };
            if (docs_size != expected_size) return true;
            if (try persistentTextDocsInvalid(allocator, store, docs_file, header, text_meta, deadline)) return true;
            if (persistentTermsOrPostingsStale(allocator, store, text_meta, deadline)) |stale| {
                if (stale) return true;
            } else |err| switch (err) {
                error.FileNotFound, error.InvalidRecord => return true,
                else => |e| return e,
            }
            return false;
        }

        pub fn persistentTextCatalogQuickStaleDeadline(allocator: std.mem.Allocator, store: storage_mod.Store, deadline: core.QueryDeadline) !bool {
            if (deadline.expired()) return core.Error.BudgetExceeded;
            const text_meta = readPersistentTextMeta(allocator, store) catch |err| switch (err) {
                error.FileNotFound, error.InvalidRecord => return true,
                else => |e| return e,
            };
            if (deadline.expired()) return core.Error.BudgetExceeded;
            const index_meta = currentPersistentTextMetaAnchor(store) catch |err| switch (err) {
                error.FileNotFound, error.InvalidRecord => return true,
                else => |e| return e,
            };
            if (persistentTextGraphAnchorStale(text_meta, index_meta)) return true;
            const searchable_metadata_digest = store.searchableNodeMetadataDigestLimitedDeadline(allocator, stale_store_scan_max_property_delta_bytes, deadline) catch |err| switch (err) {
                error.SearchableMetadataBudgetExceeded => return error.TextIndexMaintenanceRequired,
                error.FileNotFound, error.InvalidRecord => return true,
                else => |e| return e,
            };
            if (persistentTextMetaAnchorStale(text_meta, index_meta, searchable_metadata_digest)) return true;
            if (try persistentTextDocsHeaderStale(allocator, store, text_meta)) return true;
            if (persistentTermsOrPostingsHeaderStale(allocator, store, text_meta)) |stale| {
                if (stale) return true;
            } else |err| switch (err) {
                error.FileNotFound, error.InvalidRecord => return true,
                else => |e| return e,
            }
            return false;
        }

        pub fn persistentTextDocsHeaderStale(allocator: std.mem.Allocator, store: storage_mod.Store, text_meta: PersistentTextMeta) !bool {
            const docs_path = try textDocsPath(allocator, store);
            defer allocator.free(docs_path);
            var docs_file = std.Io.Dir.cwd().openFile(store.io, docs_path, .{}) catch |err| switch (err) {
                error.FileNotFound => return true,
                else => |e| return e,
            };
            defer docs_file.close(store.io);
            const docs_size = try regularFileSize(store, docs_file);
            const header = readTextDocsHeaderFromFile(store, docs_file) catch |err| switch (err) {
                error.InvalidRecord => return true,
                else => |e| return e,
            };
            if (header.doc_count != text_meta.doc_count) return true;
            const expected_size = textDocsFileSizeForHeader(header) catch |err| switch (err) {
                error.RecordTooLarge => return true,
                else => |e| return e,
            };
            return docs_size != expected_size;
        }

        pub fn persistentTextDocsInvalid(
            allocator: std.mem.Allocator,
            store: storage_mod.Store,
            docs_file: std.Io.File,
            header: TextDocsHeader,
            meta: PersistentTextMeta,
            deadline: core.QueryDeadline,
        ) !bool {
            var total_text_tokens: u64 = 0;
            var node_view = store.openNodeRecordView() catch |err| switch (err) {
                error.InvalidRecord => return true,
                else => |e| return e,
            };
            defer node_view.deinit();
            var index: u64 = 0;
            while (index < header.doc_count) : (index += 1) {
                if (deadline.expired()) return core.Error.BudgetExceeded;
                const doc = readTextDocRecordAtWithHeader(store, docs_file, header, index) catch |err| switch (err) {
                    error.InvalidRecord => return true,
                    else => |e| return e,
                };
                if (doc.doc_id != index + 1) return true;
                const node_ref = (node_view.readNodeRefById(core.NodeId.fromInt(doc.node_id)) catch |err| switch (err) {
                    error.InvalidRecord => return true,
                    else => |e| return e,
                }) orelse return true;
                var owned_node: ?storage_mod.StoredNode = null;
                defer if (owned_node) |*node| node.deinit(allocator);
                const text = if (node_ref.text_bytes) |bytes| bytes else blk: {
                    owned_node = (node_view.readNodeById(allocator, core.NodeId.fromInt(doc.node_id)) catch |err| switch (err) {
                        error.InvalidRecord => return true,
                        else => |e| return e,
                    }) orelse return true;
                    break :blk owned_node.?.text;
                };
                if (isDeletedNodeTombstoneNode(node_ref.kind, text)) return true;
                var metadata = readSearchableNodeMetadata(allocator, store, core.NodeId.fromInt(doc.node_id)) catch |err| switch (err) {
                    error.InvalidRecord => return true,
                    else => |e| return e,
                };
                defer metadata.deinit(allocator);
                validateTextDocAgainstNodeRefCached(allocator, doc, node_ref, text, metadata) catch |err| switch (err) {
                    error.InvalidRecord => return true,
                    else => |e| return e,
                };
                total_text_tokens = std.math.add(u64, total_text_tokens, doc.text_tokens) catch return true;
            }
            var overflow_index: u64 = 0;
            var previous_overflow_doc_id: u64 = 0;
            while (overflow_index < header.node_id_overflow_count) : (overflow_index += 1) {
                if (deadline.expired()) return core.Error.BudgetExceeded;
                const overflow = readTextDocNodeIdOverflowRecordAt(store, docs_file, header, overflow_index) catch |err| switch (err) {
                    error.InvalidRecord => return true,
                    else => |e| return e,
                };
                if (overflow.doc_id > header.doc_count or overflow.doc_id <= previous_overflow_doc_id) return true;
                previous_overflow_doc_id = overflow.doc_id;
                if (header.hasDenseUniformRecords()) return true;
                var bytes: [TextDocRecord.encoded_len]u8 = undefined;
                const n = try docs_file.readPositionalAll(store.io, &bytes, try textDocRecordOffsetForHeader(header, overflow.doc_id - 1));
                if (n != bytes.len) return true;
                if (std.mem.readInt(u32, bytes[0..4], .little) != persistent_doc_node_id_overflow_marker) return true;
            }
            return total_text_tokens != meta.total_text_tokens;
        }

        pub fn persistentTermsOrPostingsStale(allocator: std.mem.Allocator, store: storage_mod.Store, meta: PersistentTextMeta, deadline: core.QueryDeadline) !bool {
            if (deadline.expired()) return core.Error.BudgetExceeded;
            const terms_path = try textTermsPath(allocator, store);
            defer allocator.free(terms_path);
            var terms_file = try std.Io.Dir.cwd().openFile(store.io, terms_path, .{});
            defer terms_file.close(store.io);
            const terms_size = try regularFileSize(store, terms_file);
            const terms_header = try readTextTermsHeaderFromFile(store, terms_file);
            if (terms_header.term_count != meta.term_count) return true;
            if (terms_header.term_bytes != meta.term_bytes) return true;
            const expected_terms_size = textTermsFileSizeForHeader(terms_header) catch |err| switch (err) {
                error.RecordTooLarge => return true,
                else => |e| return e,
            };
            if (terms_size != expected_terms_size) return true;
            if (try textTermExceptionTableInvalid(store, terms_file, terms_header)) return true;

            const postings_path = try textPostingsPath(allocator, store);
            defer allocator.free(postings_path);
            var postings_view = try TextPostingsFileView.open(store, postings_path);
            defer postings_view.deinit();
            const postings_size = postings_view.size;
            const postings_header = try postings_view.readHeader();
            if (postings_header.posting_count != meta.posting_count) return true;
            const expected_postings_size = textPostingsFileSize(postings_header.body_bytes) catch |err| switch (err) {
                error.RecordTooLarge => return true,
                else => |e| return e,
            };
            if (postings_size != expected_postings_size) return true;

            const blocks_path = try textPostingBlocksPath(allocator, store);
            defer allocator.free(blocks_path);
            var blocks_file = try std.Io.Dir.cwd().openFile(store.io, blocks_path, .{});
            defer blocks_file.close(store.io);
            const blocks_size = try regularFileSize(store, blocks_file);
            const blocks_header = try readTextPostingBlocksHeaderFromFile(store, blocks_file);
            if (blocks_header.term_count != terms_header.term_count) return true;
            if (blocks_header.posting_count != postings_header.posting_count) return true;
            if (blocks_header.block_size != persistent_posting_block_size) return true;
            const expected_blocks_size = textPostingBlocksFileSize(blocks_header.term_count, blocks_header.block_count) catch |err| switch (err) {
                error.RecordTooLarge => return true,
                else => |e| return e,
            };
            if (blocks_size != expected_blocks_size) return true;

            const impacts_path = try textPostingBlockImpactsPath(allocator, store);
            defer allocator.free(impacts_path);
            var impacts_file = try std.Io.Dir.cwd().openFile(store.io, impacts_path, .{});
            defer impacts_file.close(store.io);
            const impacts_size = try regularFileSize(store, impacts_file);
            const impacts_header = try readTextPostingBlockImpactsHeaderFromFile(store, impacts_file);
            if (impacts_header.term_count != terms_header.term_count) return true;
            if (impacts_header.block_count != blocks_header.block_count) return true;
            const expected_impacts_size = textPostingBlockImpactsFileSize(impacts_header.term_count, impacts_header.block_count) catch |err| switch (err) {
                error.RecordTooLarge => return true,
                else => |e| return e,
            };
            if (impacts_size != expected_impacts_size) return true;

            const invalid_terms = persistentTermDictionaryInvalid(allocator, store, terms_file, terms_header, &postings_view, postings_header, blocks_file, blocks_header, impacts_file, impacts_header, persistentAvgDocLen(meta), meta.doc_count, deadline) catch |err| switch (err) {
                error.InvalidRecord, error.RecordTooLarge => return true,
                else => |e| return e,
            };
            if (invalid_terms) return true;
            return false;
        }

        pub fn persistentTermsOrPostingsHeaderStale(allocator: std.mem.Allocator, store: storage_mod.Store, meta: PersistentTextMeta) !bool {
            const terms_path = try textTermsPath(allocator, store);
            defer allocator.free(terms_path);
            var terms_file = try std.Io.Dir.cwd().openFile(store.io, terms_path, .{});
            defer terms_file.close(store.io);
            const terms_size = try regularFileSize(store, terms_file);
            const terms_header = try readTextTermsHeaderFromFile(store, terms_file);
            if (terms_header.term_count != meta.term_count) return true;
            if (terms_header.term_bytes != meta.term_bytes) return true;
            const expected_terms_size = textTermsFileSizeForHeader(terms_header) catch |err| switch (err) {
                error.RecordTooLarge => return true,
                else => |e| return e,
            };
            if (terms_size != expected_terms_size) return true;
            // Keep the warm-query quick-stale path bounded by headers and file sizes.
            // Full validation owns O(term_count) exception-table and dictionary scans.

            const postings_path = try textPostingsPath(allocator, store);
            defer allocator.free(postings_path);
            var postings_file = try std.Io.Dir.cwd().openFile(store.io, postings_path, .{});
            defer postings_file.close(store.io);
            const postings_size = try regularFileSize(store, postings_file);
            const postings_header = try readTextPostingsHeaderFromFile(store, postings_file);
            if (postings_header.posting_count != meta.posting_count) return true;
            const expected_postings_size = textPostingsFileSize(postings_header.body_bytes) catch |err| switch (err) {
                error.RecordTooLarge => return true,
                else => |e| return e,
            };
            if (postings_size != expected_postings_size) return true;

            const blocks_path = try textPostingBlocksPath(allocator, store);
            defer allocator.free(blocks_path);
            var blocks_file = try std.Io.Dir.cwd().openFile(store.io, blocks_path, .{});
            defer blocks_file.close(store.io);
            const blocks_size = try regularFileSize(store, blocks_file);
            const blocks_header = try readTextPostingBlocksHeaderFromFile(store, blocks_file);
            if (blocks_header.term_count != terms_header.term_count) return true;
            if (blocks_header.posting_count != postings_header.posting_count) return true;
            if (blocks_header.block_size != persistent_posting_block_size) return true;
            const expected_blocks_size = textPostingBlocksFileSize(blocks_header.term_count, blocks_header.block_count) catch |err| switch (err) {
                error.RecordTooLarge => return true,
                else => |e| return e,
            };
            if (blocks_size != expected_blocks_size) return true;

            const impacts_path = try textPostingBlockImpactsPath(allocator, store);
            defer allocator.free(impacts_path);
            var impacts_file = try std.Io.Dir.cwd().openFile(store.io, impacts_path, .{});
            defer impacts_file.close(store.io);
            const impacts_size = try regularFileSize(store, impacts_file);
            const impacts_header = try readTextPostingBlockImpactsHeaderFromFile(store, impacts_file);
            if (impacts_header.term_count != terms_header.term_count) return true;
            if (impacts_header.block_count != blocks_header.block_count) return true;
            const expected_impacts_size = textPostingBlockImpactsFileSize(impacts_header.term_count, impacts_header.block_count) catch |err| switch (err) {
                error.RecordTooLarge => return true,
                else => |e| return e,
            };
            if (impacts_size != expected_impacts_size) return true;

            const top_hits_path = try textTermTopHitsPath(allocator, store);
            defer allocator.free(top_hits_path);
            var top_hits_file = try std.Io.Dir.cwd().openFile(store.io, top_hits_path, .{});
            defer top_hits_file.close(store.io);
            const top_hits_size = try regularFileSize(store, top_hits_file);
            const top_hits_header = try readTextTermTopHitsHeaderFromFile(store, top_hits_file);
            if (top_hits_header.term_count != terms_header.term_count) return true;
            if (top_hits_header.capacity != persistent_term_top_hit_capacity) return true;
            const expected_top_hits_size = textTermTopHitsFileSize(top_hits_header.hit_count, top_hits_header.hit_term_count) catch |err| switch (err) {
                error.RecordTooLarge => return true,
                else => |e| return e,
            };
            if (top_hits_size != expected_top_hits_size) return true;
            return try persistentTermTopHitsSparseIndexInvalid(store, top_hits_file, top_hits_header);
        }

        pub fn persistentTermTopHitsSparseIndexInvalid(store: storage_mod.Store, file: std.Io.File, header: TextTermTopHitsHeader) !bool {
            var previous_term_index: ?u64 = null;
            var expected_hit_offset: u64 = 0;
            var pos: u64 = 0;
            while (pos < header.hit_term_count) : (pos += 1) {
                const record = readTextTermTopHitTermRecordAt(store, file, header, pos) catch return true;
                if (record.term_index >= header.term_count) return true;
                if (previous_term_index) |previous| {
                    if (record.term_index <= previous) return true;
                }
                previous_term_index = record.term_index;
                if (record.hit_count > header.capacity) return true;
                if (record.hit_offset != expected_hit_offset) return true;
                expected_hit_offset = std.math.add(u64, expected_hit_offset, record.hit_count) catch return true;
            }
            return expected_hit_offset != header.hit_count;
        }

        pub fn persistentTermDictionaryInvalid(
            allocator: std.mem.Allocator,
            store: storage_mod.Store,
            terms_file: std.Io.File,
            terms_header: TextTermsHeader,
            postings_view: *TextPostingsFileView,
            postings_header: TextPostingsHeader,
            blocks_file: std.Io.File,
            blocks_header: TextPostingBlocksHeader,
            impacts_file: std.Io.File,
            impacts_header: TextPostingBlockImpactsHeader,
            avg_doc_len: f32,
            doc_count: u64,
            deadline: core.QueryDeadline,
        ) !bool {
            if (try textTermExceptionTableInvalid(store, terms_file, terms_header)) return true;
            var previous_term: ?[]u8 = null;
            defer if (previous_term) |term| allocator.free(term);
            var expected_term_offset: u64 = 0;
            var expected_postings_offset: u64 = 0;
            var expected_block_offset: u64 = 0;

            var pos: u64 = 0;
            while (pos < terms_header.term_count) : (pos += 1) {
                if (deadline.expired()) return core.Error.BudgetExceeded;
                const entry = try readTextTermEntryAt(store, terms_file, terms_header, pos);
                if (termEntryHasInlinePosting(entry)) {
                    if (entry.postings_count != 1) return true;
                } else if (termEntryVirtualAllDocsTextFreq(entry) != null) {
                    if (entry.postings_count != doc_count) return true;
                } else if (termEntryDenseAllDocsFreqStreamOffset(entry)) |posting_offset| {
                    if (entry.postings_count != doc_count) return true;
                    if (posting_offset != expected_postings_offset) return true;
                    if (posting_offset > postings_header.body_bytes) return true;
                } else {
                    if (entry.postings_offset != expected_postings_offset) return true;
                    if (entry.postings_offset > postings_header.body_bytes) return true;
                }

                if (pos % persistent_term_byte_offset_checkpoint_terms == 0) {
                    const checkpoint_index = pos / persistent_term_byte_offset_checkpoint_terms;
                    const stored_term_offset = readTextTermByteOffsetCheckpointAt(store, terms_file, terms_header, checkpoint_index) catch |err| switch (err) {
                        error.InvalidRecord, error.RecordTooLarge => return true,
                        else => |e| return e,
                    };
                    if (stored_term_offset != expected_term_offset) return true;
                }

                const term_result = try readFrontCodedTermAtOffset(allocator, store, terms_file, terms_header, pos, expected_term_offset, entry, previous_term);
                const term = term_result.term;
                if (previous_term) |prev| {
                    if (std.mem.order(u8, prev, term) != .lt) {
                        allocator.free(term);
                        return true;
                    }
                    allocator.free(prev);
                }
                previous_term = term;

                if (pos % persistent_posting_block_offset_checkpoint_terms == 0) {
                    const checkpoint_index = pos / persistent_posting_block_offset_checkpoint_terms;
                    const stored_term_block_offset = readTextPostingBlockOffsetCheckpointAt(store, blocks_file, blocks_header.block_count, checkpoint_index) catch |err| switch (err) {
                        error.InvalidRecord => return true,
                        else => |e| return e,
                    };
                    if (stored_term_block_offset != expected_block_offset) return true;
                }

                var block_context = ValidatePostingBlocksContext{
                    .allocator = allocator,
                    .store = store,
                    .blocks_file = blocks_file,
                    .blocks_header = blocks_header,
                    .impacts_file = impacts_file,
                    .impacts_header = impacts_header,
                    .expected_block_offset = &expected_block_offset,
                    .avg_doc_len = avg_doc_len,
                    .doc_count = doc_count,
                    .doc_freq = entry.postings_count,
                };
                const term_block_count = publishedPostingBlockCountForEntry(entry, blocks_header.block_size) catch return true;
                if (term_block_count == 0) {
                    var skip_context = SkipTextPostingContext{};
                    const next_postings_offset = scanPersistentTermPostings(postings_view, entry, doc_count, .{ .deadline = deadline }, &skip_context, skipTextPosting) catch |err| switch (err) {
                        error.InvalidRecord, error.RecordTooLarge => return true,
                        else => |e| return e,
                    };
                    if (!termEntryHasInlinePosting(entry) and termEntryVirtualAllDocsTextFreq(entry) == null) expected_postings_offset = next_postings_offset;
                } else {
                    if (termEntryHasInlinePosting(entry)) return true;
                    try block_context.beginTerm(entry.postings_offset, expected_block_offset, term_block_count);
                    defer block_context.endTerm();
                    expected_postings_offset = scanPersistentPostingBlocks(
                        postings_view,
                        entry.postings_offset,
                        entry.postings_count,
                        doc_count,
                        blocks_header.block_size,
                        .{ .deadline = deadline },
                        &block_context,
                        validatePostingBlockRecord,
                    ) catch |err| switch (err) {
                        error.InvalidRecord, error.RecordTooLarge => return true,
                        else => |e| return e,
                    };
                    if (!try block_context.validateImpacts()) return true;
                }

                expected_term_offset = std.math.add(u64, expected_term_offset, term_result.encoded_len) catch return true;
            }

            return expected_term_offset != terms_header.term_bytes or
                expected_postings_offset != postings_header.body_bytes or
                expected_block_offset != blocks_header.block_count;
        }

        pub fn textTermExceptionTableInvalid(store: storage_mod.Store, terms_file: std.Io.File, terms_header: TextTermsHeader) !bool {
            if (terms_header.term_exception_count > terms_header.term_count) return true;
            var exceptions_seen: u64 = 0;
            var term_index: u64 = 0;
            var byte_index: u64 = 0;
            while (byte_index < (try textTermExceptionMembershipBytes(terms_header.term_count))) : (byte_index += 1) {
                const membership_byte = readTextTermExceptionMembershipByteAt(store, terms_file, terms_header, byte_index) catch |err| switch (err) {
                    error.InvalidRecord, error.RecordTooLarge => return true,
                    else => |e| return e,
                };
                var bit: u8 = 0;
                while (bit < 8 and term_index < terms_header.term_count) : ({
                    bit += 1;
                    term_index += 1;
                }) {
                    if (term_index % persistent_term_exception_rank_checkpoint_terms == 0) {
                        const checkpoint = readTextTermExceptionRankCheckpointAt(store, terms_file, terms_header, term_index / persistent_term_exception_rank_checkpoint_terms) catch |err| switch (err) {
                            error.InvalidRecord, error.RecordTooLarge => return true,
                            else => |e| return e,
                        };
                        if (checkpoint != exceptions_seen) return true;
                    }
                    if ((membership_byte & (@as(u8, 1) << @as(u3, @intCast(bit)))) == 0) continue;
                    _ = readTextTermExceptionRecordAt(store, terms_file, terms_header, exceptions_seen) catch |err| switch (err) {
                        error.InvalidRecord, error.RecordTooLarge => return true,
                        else => |e| return e,
                    };
                    exceptions_seen = std.math.add(u64, exceptions_seen, 1) catch return true;
                    if (exceptions_seen > terms_header.term_exception_count) return true;
                }
            }
            if (exceptions_seen != terms_header.term_exception_count) return true;
            if (terms_header.term_count != 0 and (terms_header.term_count & 7) != 0) {
                const last_byte = readTextTermExceptionMembershipByteAt(store, terms_file, terms_header, (terms_header.term_count - 1) / 8) catch |err| switch (err) {
                    error.InvalidRecord, error.RecordTooLarge => return true,
                    else => |e| return e,
                };
                const used_bits: u3 = @intCast(terms_header.term_count & 7);
                const padding_mask = ~((@as(u8, 1) << used_bits) - 1);
                if ((last_byte & padding_mask) != 0) return true;
            }
            return false;
        }

        pub const ValidatePostingBlocksContext = struct {
            allocator: std.mem.Allocator,
            store: storage_mod.Store,
            blocks_file: std.Io.File,
            blocks_header: TextPostingBlocksHeader,
            impacts_file: std.Io.File,
            impacts_header: TextPostingBlockImpactsHeader,
            expected_block_offset: *u64,
            avg_doc_len: f32,
            doc_count: u64,
            doc_freq: u64,
            term_posting_offset: u64 = 0,
            term_block_start: u64 = 0,
            term_block_count: u64 = 0,
            impact_seen: std.DynamicBitSetUnmanaged = .{},

            fn beginTerm(self: *ValidatePostingBlocksContext, term_posting_offset: u64, term_block_start: u64, term_block_count: u64) !void {
                self.term_posting_offset = term_posting_offset;
                self.term_block_start = term_block_start;
                self.term_block_count = term_block_count;
                self.impact_seen = try std.DynamicBitSetUnmanaged.initEmpty(self.allocator, std.math.cast(usize, term_block_count) orelse return error.RecordTooLarge);
            }

            fn endTerm(self: *ValidatePostingBlocksContext) void {
                self.impact_seen.deinit(self.allocator);
                self.impact_seen = .{};
            }

            fn validateImpacts(self: *ValidatePostingBlocksContext) !bool {
                if (self.term_block_start > self.impacts_header.block_count) return false;
                if (self.term_block_count > self.impacts_header.block_count - self.term_block_start) return false;
                var previous_upper: ?f32 = null;
                var pos: u64 = 0;
                while (pos < self.term_block_count) : (pos += 1) {
                    const global_pos = std.math.add(u64, self.term_block_start, pos) catch return false;
                    const block_index = readTextPostingImpactBlockIndexAt(self.store, self.impacts_file, self.impacts_header.term_count, global_pos) catch |err| switch (err) {
                        error.InvalidRecord, error.RecordTooLarge => return false,
                        else => |e| return e,
                    };
                    if (block_index < self.term_block_start) return false;
                    const local_index = block_index - self.term_block_start;
                    if (local_index >= self.term_block_count) return false;
                    const local_usize = std.math.cast(usize, local_index) orelse return false;
                    if (self.impact_seen.isSet(local_usize)) return false;
                    self.impact_seen.set(local_usize);

                    const block = readTextPostingBlockRecordAt(self.store, self.blocks_file, self.blocks_header.term_count, block_index) catch |err| switch (err) {
                        error.InvalidRecord, error.RecordTooLarge => return false,
                        else => |e| return e,
                    };
                    const upper = bm25WeightedTermScore(
                        block.max_weighted_tf,
                        block.min_doc_len,
                        self.avg_doc_len,
                        self.doc_count,
                        self.doc_freq,
                        .{},
                    );
                    if (!std.math.isFinite(upper)) return false;
                    if (previous_upper) |prev| {
                        if (prev < upper) return false;
                    }
                    previous_upper = upper;
                }
                return self.impact_seen.count() == self.term_block_count;
            }
        };

        pub fn validatePostingBlockRecord(context: *ValidatePostingBlocksContext, stats: TextPostingBlockStats) !void {
            if (context.expected_block_offset.* >= context.blocks_header.block_count) return error.InvalidRecord;
            const stored = try readTextPostingBlockRecordAt(context.store, context.blocks_file, context.blocks_header.term_count, context.expected_block_offset.*);
            if (!textPostingBlockRecordConservativelyMatches(stored, try textPostingBlockRecordFromStats(stats))) return error.InvalidRecord;
            if (context.expected_block_offset.* % persistent_posting_block_byte_offset_checkpoint_blocks == 0) {
                if (stats.posting_offset < context.term_posting_offset) return error.InvalidRecord;
                const relative_posting_offset = stats.posting_offset - context.term_posting_offset;
                const checkpoint_index = context.expected_block_offset.* / persistent_posting_block_byte_offset_checkpoint_blocks;
                const stored_relative_posting_offset = try readTextPostingBlockByteOffsetCheckpointAt(context.store, context.blocks_file, context.blocks_header.term_count, context.blocks_header.block_count, checkpoint_index);
                if (stored_relative_posting_offset != relative_posting_offset) return error.InvalidRecord;
            }
            context.expected_block_offset.* = std.math.add(u64, context.expected_block_offset.*, 1) catch return error.RecordTooLarge;
        }

        const anchorStaleForTest = persistentTextMetaAnchorStale;
        const graphAnchorStaleForTest = persistentTextGraphAnchorStale;
        pub const Internal = struct {
            pub const anchorStale = anchorStaleForTest;
            pub const graphAnchorStale = graphAnchorStaleForTest;
        };
    };
}

const TestMeta = struct {
    node_digest: u64,
    node_by_text_order_digest: u64,
    searchable_metadata_digest: u64,
};
const TestIndexMeta = struct {
    node_digest: u64,
    node_by_text_order_digest: u64,
};
const TestCore = struct {
    pub const Error = error{BudgetExceeded};
    pub const QueryDeadline = struct {};
    pub const NodeId = struct {};
};
const TestStorage = struct {
    pub const Store = void;
    pub const StoredNode = void;
    pub const IndexMeta = TestIndexMeta;
};
const TestOps = struct {
    pub const PersistentTextMeta_dep = TestMeta;
    pub const TextDocsHeader_dep = void;
    pub const TextDocRecord_dep = void;
    pub const TextPostingsFileView_dep = void;
    pub const TextPostingsHeader_dep = void;
    pub const TextPostingBlocksHeader_dep = void;
    pub const TextPostingBlockImpactsHeader_dep = void;
    pub const TextTermTopHitsHeader_dep = void;
    pub const TextTermsHeader_dep = void;
    pub const TextPostingBlockStats_dep = void;
    pub const readPersistentTextMeta_dep = void;
    pub const currentPersistentTextMetaAnchor_dep = void;
    pub const textDocsPath_dep = void;
    pub const regularFileSize_dep = void;
    pub const readTextDocsHeaderFromFile_dep = void;
    pub const textDocsFileSizeForHeader_dep = void;
    pub const stale_store_scan_max_property_delta_bytes_dep: u64 = 0;
    pub const readTextDocRecordAtWithHeader_dep = void;
    pub const readTextDocNodeIdOverflowRecordAt_dep = void;
    pub const textDocRecordOffsetForHeader_dep = void;
    pub const persistent_doc_node_id_overflow_marker_dep: u32 = 0;
    pub const isDeletedNodeTombstoneNode_dep = void;
    pub const readSearchableNodeMetadata_dep = void;
    pub const validateTextDocAgainstNodeRefCached_dep = void;
    pub const textTermsPath_dep = void;
    pub const readTextTermsHeaderFromFile_dep = void;
    pub const textTermsFileSizeForHeader_dep = void;
    pub const textPostingsPath_dep = void;
    pub const textPostingsFileSize_dep = void;
    pub const readTextPostingsHeaderFromFile_dep = void;
    pub const textPostingBlocksPath_dep = void;
    pub const readTextPostingBlocksHeaderFromFile_dep = void;
    pub const persistent_posting_block_size_dep: u64 = 128;
    pub const textPostingBlocksFileSize_dep = void;
    pub const textPostingBlockImpactsPath_dep = void;
    pub const readTextPostingBlockImpactsHeaderFromFile_dep = void;
    pub const textPostingBlockImpactsFileSize_dep = void;
    pub const persistentAvgDocLen_dep = void;
    pub const textTermTopHitsPath_dep = void;
    pub const readTextTermTopHitsHeaderFromFile_dep = void;
    pub const persistent_term_top_hit_capacity_dep: u64 = 64;
    pub const textTermTopHitsFileSize_dep = void;
    pub const readTextTermTopHitTermRecordAt_dep = void;
    pub const readTextTermEntryAt_dep = void;
    pub const termEntryHasInlinePosting_dep = void;
    pub const termEntryVirtualAllDocsTextFreq_dep = void;
    pub const termEntryDenseAllDocsFreqStreamOffset_dep = void;
    pub const persistent_term_byte_offset_checkpoint_terms_dep: u64 = 1;
    pub const readTextTermByteOffsetCheckpointAt_dep = void;
    pub const readFrontCodedTermAtOffset_dep = void;
    pub const persistent_posting_block_offset_checkpoint_terms_dep: u64 = 1;
    pub const readTextPostingBlockOffsetCheckpointAt_dep = void;
    pub const publishedPostingBlockCountForEntry_dep = void;
    pub const SkipTextPostingContext_dep = void;
    pub const scanPersistentTermPostings_dep = void;
    pub const skipTextPosting_dep = void;
    pub const scanPersistentPostingBlocks_dep = void;
    pub const textTermExceptionMembershipBytes_dep = void;
    pub const readTextTermExceptionMembershipByteAt_dep = void;
    pub const persistent_term_exception_rank_checkpoint_terms_dep: u64 = 1;
    pub const readTextTermExceptionRankCheckpointAt_dep = void;
    pub const readTextTermExceptionRecordAt_dep = void;
    pub const readTextPostingImpactBlockIndexAt_dep = void;
    pub const readTextPostingBlockRecordAt_dep = void;
    pub const bm25WeightedTermScore_dep = void;
    pub const textPostingBlockRecordConservativelyMatches_dep = void;
    pub const textPostingBlockRecordFromStats_dep = void;
    pub const persistent_posting_block_byte_offset_checkpoint_blocks_dep: u64 = 1;
    pub const readTextPostingBlockByteOffsetCheckpointAt_dep = void;
};
const test_owner = PersistentCatalogValidation(TestCore, TestStorage, TestOps);

test "persistent catalog validation accepts matching graph anchors" {
    try std.testing.expect(!test_owner.Internal.graphAnchorStale(
        .{ .node_digest = 1, .node_by_text_order_digest = 2, .searchable_metadata_digest = 3 },
        .{ .node_digest = 1, .node_by_text_order_digest = 2 },
    ));
}

test "persistent catalog validation rejects node digest drift" {
    try std.testing.expect(test_owner.Internal.graphAnchorStale(
        .{ .node_digest = 1, .node_by_text_order_digest = 2, .searchable_metadata_digest = 3 },
        .{ .node_digest = 9, .node_by_text_order_digest = 2 },
    ));
}

test "persistent catalog validation rejects text order digest drift" {
    try std.testing.expect(test_owner.Internal.graphAnchorStale(
        .{ .node_digest = 1, .node_by_text_order_digest = 2, .searchable_metadata_digest = 3 },
        .{ .node_digest = 1, .node_by_text_order_digest = 9 },
    ));
}

test "persistent catalog validation rejects searchable metadata drift" {
    try std.testing.expect(test_owner.Internal.anchorStale(
        .{ .node_digest = 1, .node_by_text_order_digest = 2, .searchable_metadata_digest = 3 },
        .{ .node_digest = 1, .node_by_text_order_digest = 2 },
        9,
    ));
}
