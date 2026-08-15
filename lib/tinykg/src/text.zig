const std = @import("std");
const builtin = @import("builtin");
const core = @import("core.zig");
const graph_mod = @import("graph.zig");
const schema = @import("schema.zig");
const storage_mod = @import("storage.zig");
const read_only_memory_map = @import("read_only_memory_map.zig");
const tokenizer_mod = @import("text/tokenizer.zig");
const bench_trace_environment = @import("text/bench_trace_environment.zig");
const catalog_format_mod = @import("text/catalog_format.zig");
const scoring_mod = @import("text/scoring.zig");
const search_contract_mod = @import("text/search_contract.zig");
const posting_format_mod = @import("text/posting_format.zig");
const term_format_mod = @import("text/term_format.zig");
const search_acceleration_format_mod = @import("text/search_acceleration_format.zig");
const rebuild_runtime_mod = @import("text/rebuild_runtime.zig");
const rebuild_session_mod = @import("text/rebuild_session.zig");
const streaming_run_catalog_publication_mod = @import("text/streaming_run_catalog_publication.zig");
const query_execution_mod = @import("text/query_execution.zig");
const persistent_query_execution_hot_path_mod = @import("text/persistent_query_execution_hot_path.zig");
const document_catalog_stream_writer_mod = @import("text/document_catalog_stream_writer.zig");
const term_posting_catalog_publication_mod = @import("text/term_posting_catalog_publication.zig");
const persistent_catalog_validation_mod = @import("text/persistent_catalog_validation.zig");
const searchable_document_mod = @import("text/searchable_document.zig");
const in_memory_index_mod = @import("text/in_memory_index.zig");
const posting_run_builder_mod = @import("text/posting_run_builder.zig");
const posting_run_codec_merge_mod = @import("text/posting_run_codec_merge.zig");
const catalog_format = catalog_format_mod.CatalogFormat(core);
const search_contract = search_contract_mod.SearchContract(core, schema, tokenizer_mod, scoring_mod);
const PostingFormatConfig = struct {
    pub const persistent_text_index_version = catalog_format.persistent_text_index_version;
    pub const persistent_posting_max_doc_id = catalog_format.persistent_posting_max_doc_id;
    pub const persistent_posting_max_field_freq: u32 = std.math.maxInt(u16);
    pub const persistent_posting_max_kind_freq: u32 = 0;
};
const posting_format = posting_format_mod.PostingFormat(PostingFormatConfig);
const TermFormatConfig = struct {
    pub const persistent_term_max_len = tokenizer_mod.default_max_token_bytes;
    pub const persistent_all_docs_synthesis_min_postings = persistent_all_docs_synthesis_min_postings_value;
};
const term_format = term_format_mod.TermFormat(PostingFormatConfig, TermFormatConfig);
const SearchAccelerationFormatConfig = struct {
    pub const persistent_text_index_version = catalog_format.persistent_text_index_version;
    pub const persistent_posting_max_doc_id = catalog_format.persistent_posting_max_doc_id;
    pub const persistent_posting_max_field_freq = PostingFormatConfig.persistent_posting_max_field_freq;
    pub const persistent_term_top_hit_capacity: u64 = 64;
};
const search_acceleration_format = search_acceleration_format_mod.SearchAccelerationFormat(SearchAccelerationFormatConfig);
const rebuild_runtime = rebuild_runtime_mod.RebuildRuntime(core);
const rebuild_session = rebuild_session_mod.RebuildSession(core, storage_mod, RebuildSessionOps);
const streaming_run_catalog_publication = streaming_run_catalog_publication_mod.StreamingRunCatalogPublication(core, storage_mod, StreamingRunCatalogPublicationOps);
const query_execution = query_execution_mod.QueryExecution(core, schema, storage_mod, QueryExecutionOps);
const persistent_query_execution_hot_path = persistent_query_execution_hot_path_mod.PersistentQueryExecutionHotPath(core, schema, storage_mod, PersistentQueryExecutionHotPathOps);
const document_catalog_stream_writer = document_catalog_stream_writer_mod.DocumentCatalogStreamWriter(core, storage_mod, DocumentCatalogStreamWriterOps);
const term_posting_catalog_publication = term_posting_catalog_publication_mod.TermPostingCatalogPublication(core, storage_mod, TermPostingCatalogPublicationOps);
const persistent_catalog_validation = persistent_catalog_validation_mod.PersistentCatalogValidation(core, storage_mod, PersistentCatalogValidationOps);
const searchable_document = searchable_document_mod.SearchableDocument(core, storage_mod);
const in_memory_index = in_memory_index_mod.InMemoryIndex(core, schema, graph_mod, storage_mod, query_execution.TextQueryPlanStats);
const rebuildPersistentTextCatalogWithGraphRepair = rebuild_session.Internal.rebuildPersistentTextCatalogWithGraphRepair;
const rebuildPersistentTextCatalogFromRunsOnceDeadline = rebuild_session.Internal.rebuildPersistentTextCatalogFromRunsOnceDeadline;
const rebuildPersistentTextCatalogFromRunsOnceDeadlineTimed = rebuild_session.Internal.rebuildPersistentTextCatalogFromRunsOnceDeadlineTimed;
const textPostingRunsBasePath = rebuild_session.Internal.postingRunsBasePath;

const default_max_token_bytes = tokenizer_mod.default_max_token_bytes;
pub const TokenizerOptions = tokenizer_mod.TokenizerOptions;
pub const TokenList = tokenizer_mod.TokenList;
pub const tokenize = tokenizer_mod.tokenize;
const validateTokenizerOptions = tokenizer_mod.validateTokenizerOptions;
const Decoded = tokenizer_mod.Decoded;
const decodeUtf8 = tokenizer_mod.decodeUtf8;
const isCjk = tokenizer_mod.isCjk;
const isCjkJoiner = tokenizer_mod.isCjkJoiner;
const normalizedRunByte = tokenizer_mod.normalizedRunByte;
const isRunByte = tokenizer_mod.isRunByte;
const shouldEmitOriginal = tokenizer_mod.shouldEmitOriginal;
const containsCamelBoundary = tokenizer_mod.containsCamelBoundary;
const isCamelSplit = tokenizer_mod.isCamelSplit;
const appendNormalizedCjkCodepoint = tokenizer_mod.appendNormalizedCjkCodepoint;
const countTokens = tokenizer_mod.countTokens;
const countTermInText = tokenizer_mod.countTermInText;
pub const Bm25Params = scoring_mod.Bm25Params;
pub const bm25Idf = scoring_mod.bm25Idf;
pub const bm25TermScore = scoring_mod.bm25TermScore;
pub const bm25WeightedTermScore = scoring_mod.bm25WeightedTermScore;
pub const TextSearchOptions = search_contract.TextSearchOptions;
pub const TextSearchHit = search_contract.TextSearchHit;
pub const TextDocument = searchable_document.TextDocument;
pub const TextFieldWeights = in_memory_index.TextFieldWeights;
pub const TextIndex = in_memory_index.TextIndex;
const SearchableNodeMetadata = searchable_document.SearchableNodeMetadata;
const SearchableNodeMetadataSnapshot = searchable_document.SearchableNodeMetadataSnapshot;
const readSearchableNodeMetadata = searchable_document.readSearchableNodeMetadata;
const isDeletedNodeTombstoneText = searchable_document.Internal.isDeletedNodeTombstoneText;
const isDeletedNodeTombstoneNode = searchable_document.Internal.isDeletedNodeTombstoneNode;
const textSearchHasNodeFilter = search_contract.Internal.hasNodeFilter;
const textSearchMatchesNodeKind = search_contract.Internal.matchesNodeKind;
const cjkBigramCoverageFloor = search_contract.Internal.cjkBigramCoverageFloor;
const isCjkMultiCodepointTerm = search_contract.Internal.isCjkMultiCodepointTerm;
const termHasNonCjkCodepoint = search_contract.Internal.termHasNonCjkCodepoint;
const countQueryTermOccurrences = search_contract.Internal.countQueryTermOccurrences;
const validateTextSearchOptions = search_contract.Internal.validateOptions;
const textSearchPreallocCapacity = search_contract.Internal.preallocCapacity;
const chargeTextPostingScan = search_contract.Internal.chargePostingScan;
const tokenizerOptionsEqual = search_contract.Internal.tokenizerOptionsEqual;
const textSearchHitLessThan = search_contract.Internal.hitLessThan;
const appendTopTextHitBounded = search_contract.Internal.appendTopHitBounded;
const appendTopTextHitBoundedCachedWorst = search_contract.Internal.appendTopHitBoundedCachedWorst;
const worstTopTextHitScore = search_contract.Internal.worstTopHitScore;
const hitsContainNode = search_contract.Internal.hitsContainNode;
const encodeTextPostingsHeader = posting_format.Internal.encodeHeader;
const decodeTextPostingsHeader = posting_format.Internal.decodeHeader;
const encodeTextPostingRecord = posting_format.Internal.encodeRecord;
const decodeTextPostingRecord = posting_format.Internal.decodeRecord;
const validateTextPostingFields = posting_format.Internal.validateFields;
const compressed_posting_tag_text_unit = posting_format.Internal.compressed_tag_text_unit;
const compressed_posting_tag_text_two = posting_format.Internal.compressed_tag_text_two;
const compressed_posting_tag_text_three = posting_format.Internal.compressed_tag_text_three;
const compressed_posting_tag_text_explicit = posting_format.Internal.compressed_tag_text_explicit;
const compressed_posting_field_tag_bits = posting_format.Internal.compressed_field_tag_bits;
const compressed_posting_field_tag_mask = posting_format.Internal.compressed_field_tag_mask;
const DecodedCompressedPostingDelta = posting_format.Internal.DecodedCompressedPostingDelta;
const compressedPostingTextFreqTag = posting_format.Internal.compressedTextFreqTag;
const compressedPostingFieldTag = posting_format.Internal.compressedFieldTag;
const taggedCompressedPostingDelta = posting_format.Internal.taggedCompressedDelta;
const decodeTaggedCompressedPostingDelta = posting_format.Internal.decodeTaggedCompressedDelta;
const compressedPostingTagInlineTextFreq = posting_format.Internal.compressedTagInlineTextFreq;
const compressedPostingTagTextExplicit = posting_format.Internal.compressedTagTextExplicit;
const validateCompressedPostingExplicitFreq = posting_format.Internal.validateCompressedExplicitFreq;
const encodeTextTermsHeader = term_format.Internal.encodeHeader;
const decodeTextTermsHeader = term_format.Internal.decodeHeader;
const validateTextTermsHeaderShape = term_format.Internal.validateHeaderShape;
const encodeTextTermEntry = term_format.Internal.encodeEntry;
const decodeTextTermEntry = term_format.Internal.decodeEntry;
const textTermEntryWithDocFreq = term_format.Internal.entryWithDocFreq;
const textTermEntryFrontPrefixLen = term_format.Internal.entryFrontPrefixLen;
const textTermEntryFrontSuffixLen = term_format.Internal.entryFrontSuffixLen;
const TextTermSingletonPayloadCheckpoint = term_format.Internal.TextTermSingletonPayloadCheckpoint;
const encodeTextTermSingletonPayloadCheckpoint = term_format.Internal.encodeSingletonCheckpoint;
const decodeTextTermSingletonPayloadCheckpoint = term_format.Internal.decodeSingletonCheckpoint;
const TextTermExceptionRecord = term_format.Internal.TextTermExceptionRecord;
const encodeTextTermExceptionRecord = term_format.Internal.encodeExceptionRecord;
const decodeTextTermExceptionRecord = term_format.Internal.decodeExceptionRecord;
const termEntryHasInlinePosting = term_format.Internal.termEntryHasInlinePosting;
const encodeVirtualAllDocsPostingPayload = term_format.Internal.encodeVirtualAllDocsPostingPayload;
const termEntryVirtualAllDocsTextFreq = term_format.Internal.termEntryVirtualAllDocsTextFreq;
const denseAllDocsFreqStreamOffsetFromPayload = term_format.Internal.denseAllDocsFreqStreamOffsetFromPayload;
const denseAllDocsFreqStreamOffset = term_format.Internal.denseAllDocsFreqStreamOffset;
const termEntryDenseAllDocsFreqStreamOffset = term_format.Internal.termEntryDenseAllDocsFreqStreamOffset;
const termEntryPostingPayloadValid = term_format.Internal.termEntryPostingPayloadValid;
const encodeDenseAllDocsFreqStreamPayload = term_format.Internal.encodeDenseAllDocsFreqStreamPayload;
const canInlineSingletonPosting = term_format.Internal.canInlineSingletonPosting;
const encodeInlineSingletonPostingPayload = term_format.Internal.encodeInlineSingletonPostingPayload;
const decodeInlineSingletonPostingPayload = term_format.Internal.decodeInlineSingletonPostingPayload;
const encodeZigZagI64 = term_format.Internal.encodeZigZagI64;
const singletonPayloadDelta = term_format.Internal.singletonPayloadDelta;
const applySingletonPayloadDelta = term_format.Internal.applySingletonPayloadDelta;
const persistentTermCommonPrefixLen = term_format.Internal.termCommonPrefixLen;
const persistentTermFrontCodedPrefixLen = term_format.Internal.termFrontCodedPrefixLen;
const frontCodedPrefixInlineable = term_format.Internal.frontCodedPrefixInlineable;
const frontCodedPrefixByteCount = term_format.Internal.frontCodedPrefixByteCount;
const frontCodedEncodedLen = term_format.Internal.frontCodedEncodedLen;
const textTermEntryOffset = term_format.Internal.termEntryOffset;
const textTermsBytesOffset = term_format.Internal.termsBytesOffset;
const textTermByteOffsetCheckpointCount = term_format.Internal.termByteOffsetCheckpointCount;
const textTermByteOffsetCheckpointTableBytes = term_format.Internal.termByteOffsetCheckpointTableBytes;
const textTermByteOffsetCheckpointTableOffset = term_format.Internal.termByteOffsetCheckpointTableOffset;
const textTermByteOffsetCheckpointOffset = term_format.Internal.termByteOffsetCheckpointOffset;
const textTermExceptionRankCheckpointCount = term_format.Internal.termExceptionRankCheckpointCount;
const textTermExceptionRankCheckpointTableBytes = term_format.Internal.termExceptionRankCheckpointTableBytes;
const textTermExceptionMembershipBytes = term_format.Internal.termExceptionMembershipBytes;
const textTermExceptionPayloadTableBytes = term_format.Internal.termExceptionPayloadTableBytes;
const textTermExceptionTableBytes = term_format.Internal.termExceptionTableBytes;
const textTermExceptionTableOffset = term_format.Internal.termExceptionTableOffset;
const textTermExceptionRankCheckpointTableOffset = term_format.Internal.termExceptionRankCheckpointTableOffset;
const textTermExceptionRankCheckpointOffset = term_format.Internal.termExceptionRankCheckpointOffset;
const textTermExceptionMembershipBitsetOffset = term_format.Internal.termExceptionMembershipBitsetOffset;
const textTermExceptionMembershipByteOffset = term_format.Internal.termExceptionMembershipByteOffset;
const textTermExceptionPayloadTableOffset = term_format.Internal.termExceptionPayloadTableOffset;
const textTermExceptionRecordOffset = term_format.Internal.termExceptionRecordOffset;
const textTermSingletonPayloadCount = term_format.Internal.termSingletonPayloadCount;
const textTermSingletonPayloadCheckpointCount = term_format.Internal.termSingletonPayloadCheckpointCount;
const textTermSingletonPayloadCheckpointTableBytes = term_format.Internal.termSingletonPayloadCheckpointTableBytes;
const textTermSingletonPayloadCheckpointTableOffset = term_format.Internal.termSingletonPayloadCheckpointTableOffset;
const textTermSingletonPayloadCheckpointOffset = term_format.Internal.termSingletonPayloadCheckpointOffset;
const textTermSingletonPayloadStreamOffset = term_format.Internal.termSingletonPayloadStreamOffset;
const textTermsFileSize = term_format.Internal.termsFileSize;
const textTermsFileSizeForHeader = term_format.Internal.termsFileSizeForHeader;
const cleanupTextPostingRunScratchFiles = rebuild_runtime.Internal.cleanupPostingRunScratchFiles;
const recordPersistentTextRebuildObserver = rebuild_runtime.Internal.recordObserver;
const textMonotonicNs = rebuild_runtime.Internal.monotonicNs;
const textElapsedNs = rebuild_runtime.Internal.elapsedNs;
const tmpPathFor = rebuild_runtime.Internal.tmpPathFor;

pub const stale_store_scan_max_nodes = query_execution.stale_store_scan_max_nodes;
pub const stale_store_scan_max_text_bytes = query_execution.stale_store_scan_max_text_bytes;
pub const stale_store_scan_max_event_bytes = query_execution.stale_store_scan_max_event_bytes;
pub const stale_store_scan_max_property_delta_bytes = query_execution.stale_store_scan_max_property_delta_bytes;
pub const TextQueryPlanStats = query_execution.TextQueryPlanStats;
pub const searchText = query_execution.searchText;
pub const textQueryPlanStats = query_execution.textQueryPlanStats;

/// Private data-plane adapter for `text.query_execution`.  The control module
/// sees only bounded operations; persistent catalog and in-memory index
/// representations remain owned by this façade until their own cohesive
/// boundaries are extracted.
const QueryExecutionOps = struct {
    pub fn persistentCatalogQuickStaleDeadline(
        allocator: std.mem.Allocator,
        store: storage_mod.Store,
        deadline: core.QueryDeadline,
    ) !bool {
        return persistent_catalog_validation.persistentTextCatalogQuickStaleDeadline(allocator, store, deadline);
    }

    pub fn searchPersistentTokens(
        allocator: std.mem.Allocator,
        store: storage_mod.Store,
        query_terms: []const []u8,
        options: TextSearchOptions,
    ) !std.ArrayList(TextSearchHit) {
        return persistent_query_execution_hot_path.searchPersistentTokens(allocator, store, query_terms, options);
    }

    pub fn searchStoreScan(
        allocator: std.mem.Allocator,
        store: storage_mod.Store,
        query: []const u8,
        options: TextSearchOptions,
        max_metadata_bytes: u64,
        max_property_delta_bytes: u64,
    ) !std.ArrayList(TextSearchHit) {
        var index = try TextIndex.buildFromStoreReadOnlyDeadline(
            allocator,
            store,
            max_metadata_bytes,
            max_property_delta_bytes,
            options.deadline,
        );
        defer index.deinit();
        return index.search(query, options);
    }

    pub fn fillPersistentPlanStats(
        allocator: std.mem.Allocator,
        store: storage_mod.Store,
        query_terms: []const []u8,
        stats: anytype,
    ) !void {
        const meta = try readPersistentTextMeta(allocator, store);
        if (meta.doc_count == 0) return;

        var catalog = try PersistentPostingCatalog.open(allocator, store, meta.doc_count);
        defer catalog.deinit();
        var unique_query_terms = std.StringHashMap(void).init(allocator);
        defer unique_query_terms.deinit();
        try unique_query_terms.ensureTotalCapacity(@intCast(query_terms.len));

        for (query_terms) |term| {
            const unique_entry = try unique_query_terms.getOrPut(term);
            if (unique_entry.found_existing) continue;
            unique_entry.value_ptr.* = {};
            stats.unique_query_terms += 1;
            if (try catalog.findTermEntry(term)) |lookup| {
                stats.matched_terms += 1;
                stats.postings_count_total = std.math.add(u64, stats.postings_count_total, lookup.entry.postings_count) catch return error.RecordTooLarge;
                stats.max_postings_count = @max(stats.max_postings_count, lookup.entry.postings_count);
            }
        }
    }

    pub fn fillStoreScanPlanStats(
        allocator: std.mem.Allocator,
        store: storage_mod.Store,
        query: []const u8,
        options: TextSearchOptions,
        max_metadata_bytes: u64,
        max_property_delta_bytes: u64,
        stats: anytype,
    ) !void {
        var index = try TextIndex.buildFromStoreReadOnlyDeadline(
            allocator,
            store,
            max_metadata_bytes,
            max_property_delta_bytes,
            options.deadline,
        );
        defer index.deinit();
        stats.* = try index.queryPlanStats(query, options);
    }

    pub fn searchPersistentWithAppendedTail(
        allocator: std.mem.Allocator,
        store: storage_mod.Store,
        query: []const u8,
        query_terms: []const []u8,
        options: TextSearchOptions,
    ) !?std.ArrayList(TextSearchHit) {
        return searchPersistentWithAppendedTailImpl(allocator, store, query, query_terms, options);
    }
};

/// Upper bound on appended-tail nodes served from a RAM merge before queries
/// fall back to full staleness handling and the maintenance policy owes a
/// catalog republication. Bounds the transient tail index memory.
const incremental_text_tail_max_nodes: u64 = 20_000;

fn incrementalTailOtherDf(context: *anyopaque, term: []const u8) u64 {
    const map: *const std.StringHashMap(u64) = @ptrCast(@alignCast(context));
    return map.get(term) orelse 0;
}

/// Process-wide cache of the incremental tail context so a long-lived reader
/// (the daemon) pays the O(tail) walk and index build once per store state
/// instead of once per query. The key pins the exact snapshot the tail was
/// proven against — store identity, publication watermark, live event bytes,
/// node digest, and searchable metadata digest — so a hit is byte-equivalent
/// to rebuilding, and any write moves event bytes and misses. Single-threaded
/// by the same execution model as the rest of the engine; a future threaded
/// read path must revisit this along with every other shared structure.
const CachedTailContext = struct {
    dir_hash: u64,
    indexed_event_bytes: u64,
    event_bytes: u64,
    node_digest: u64,
    searchable_metadata_digest: u64,
    tick: u64,
    index: TextIndex,
    node_ids: std.AutoHashMap(u64, void),

    fn deinitAndFree(self: *CachedTailContext) void {
        self.index.deinit();
        self.node_ids.deinit();
        tail_cache_allocator.destroy(self);
    }
};

const tail_cache_allocator = std.heap.smp_allocator;
var tail_cache_slots: [2]?*CachedTailContext = .{ null, null };
var tail_cache_tick: u64 = 0;

const TailExtension = enum {
    /// delta verified and folded in; the entry now matches the live store
    extended,
    /// nothing was mutated (walk failed or digest chain broke); the entry is
    /// still a valid snapshot of its recorded frontier
    intact,
    /// mutation started and then failed; the entry must be discarded
    poisoned,
};

/// Extend a cached tail context across an append-only delta, walking only
/// the events past the cached frontier. The digest chain is proven before
/// any mutation: cached digest XOR delta digest must equal the live index
/// digest, the same proof shape the full walk gives from the publication
/// watermark.
fn extendCachedTailContext(
    entry: *CachedTailContext,
    store: storage_mod.Store,
    index_meta: storage_mod.IndexMeta,
) !TailExtension {
    const allocator = tail_cache_allocator;
    if (entry.node_ids.count() >= incremental_text_tail_max_nodes) return .intact;
    var delta = store.collectNodeTailAppendedSince(
        allocator,
        entry.event_bytes,
        incremental_text_tail_max_nodes - entry.node_ids.count(),
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .intact,
    };
    defer delta.deinit(allocator);
    if ((entry.node_digest ^ delta.node_digest_xor) != index_meta.node_digest) return .intact;

    entry.node_ids.ensureUnusedCapacity(@intCast(delta.ids.items.len)) catch return error.OutOfMemory;
    for (delta.ids.items) |id| {
        entry.node_ids.putAssumeCapacity(id, {});
        var node = (store.readNodeById(allocator, core.NodeId.fromInt(id)) catch {
            return .poisoned;
        }) orelse continue;
        defer node.deinit(allocator);
        if (isDeletedNodeTombstoneNode(node.kind, node.text)) continue;
        entry.index.addDocument(.{ .node_id = node.id, .kind = node.kind, .text = node.text }) catch {
            return .poisoned;
        };
    }
    entry.event_bytes = index_meta.event_bytes;
    entry.node_digest = index_meta.node_digest;
    return .extended;
}

fn obtainCachedTailContext(
    store: storage_mod.Store,
    text_meta: PersistentTextMeta,
    index_meta: storage_mod.IndexMeta,
    searchable_metadata_digest: u64,
) !?*CachedTailContext {
    const dir_hash = std.hash.Wyhash.hash(0x544B_5443, store.dir_path);
    tail_cache_tick += 1;
    for (tail_cache_slots) |maybe_entry| {
        const entry = maybe_entry orelse continue;
        if (entry.dir_hash != dir_hash) continue;
        if (entry.indexed_event_bytes != text_meta.indexed_event_bytes) continue;
        if (entry.searchable_metadata_digest != searchable_metadata_digest) continue;
        if (entry.event_bytes == index_meta.event_bytes and entry.node_digest == index_meta.node_digest) {
            entry.tick = tail_cache_tick;
            return entry;
        }
        if (entry.event_bytes < index_meta.event_bytes) {
            const extension = extendCachedTailContext(entry, store, index_meta) catch |err| {
                if (err == error.OutOfMemory) return err;
                unreachable;
            };
            switch (extension) {
                .extended => {
                    entry.tick = tail_cache_tick;
                    return entry;
                },
                .intact => {},
                .poisoned => {
                    for (&tail_cache_slots) |*slot| {
                        if (slot.* == entry) {
                            entry.deinitAndFree();
                            slot.* = null;
                            break;
                        }
                    }
                },
            }
        }
    }

    const allocator = tail_cache_allocator;
    var tail = store.collectNodeTailAppendedSince(
        allocator,
        text_meta.indexed_event_bytes,
        incremental_text_tail_max_nodes,
    ) catch |err| switch (err) {
        error.FileNotFound, error.InvalidRecord, error.RecordTooLarge => return null,
        else => |other| return other,
    };
    defer tail.deinit(allocator);
    if ((text_meta.node_digest ^ tail.node_digest_xor) != index_meta.node_digest) return null;

    // Tail docs provably carry no searchable name/summary metadata: setting
    // one would have changed the searchable metadata digest checked above.
    var tail_index = TextIndex.init(allocator);
    errdefer tail_index.deinit();
    var tail_node_ids = std.AutoHashMap(u64, void).init(allocator);
    errdefer tail_node_ids.deinit();
    try tail_node_ids.ensureTotalCapacity(@intCast(tail.ids.items.len));
    for (tail.ids.items) |id| {
        tail_node_ids.putAssumeCapacity(id, {});
        var node = (store.readNodeById(allocator, core.NodeId.fromInt(id)) catch |err| switch (err) {
            error.FileNotFound, error.InvalidRecord => {
                tail_index.deinit();
                tail_node_ids.deinit();
                return null;
            },
            else => |other| return other,
        }) orelse continue;
        defer node.deinit(allocator);
        if (isDeletedNodeTombstoneNode(node.kind, node.text)) continue;
        try tail_index.addDocument(.{ .node_id = node.id, .kind = node.kind, .text = node.text });
    }

    const entry = try allocator.create(CachedTailContext);
    errdefer allocator.destroy(entry);
    entry.* = .{
        .dir_hash = dir_hash,
        .indexed_event_bytes = text_meta.indexed_event_bytes,
        .event_bytes = index_meta.event_bytes,
        .node_digest = index_meta.node_digest,
        .searchable_metadata_digest = searchable_metadata_digest,
        .tick = tail_cache_tick,
        .index = tail_index,
        .node_ids = tail_node_ids,
    };

    var victim_slot: usize = 0;
    var victim_tick: u64 = std.math.maxInt(u64);
    for (&tail_cache_slots, 0..) |*slot, slot_index| {
        if (slot.* == null) {
            victim_slot = slot_index;
            victim_tick = 0;
            break;
        }
        if (slot.*.?.tick < victim_tick) {
            victim_tick = slot.*.?.tick;
            victim_slot = slot_index;
        }
    }
    if (tail_cache_slots[victim_slot]) |old| old.deinitAndFree();
    tail_cache_slots[victim_slot] = entry;
    return entry;
}

/// Serve a query on a stale-but-append-only catalog by merging the published
/// index with a RAM index over the appended tail. Returns null whenever any
/// eligibility proof fails, so callers keep the exact full staleness
/// semantics as fallback. Eligibility is proof-based, not heuristic: the
/// searchable metadata digest must be unchanged since publication and the
/// published node digest XORed with the walked tail's digests must reproduce
/// the live index node digest exactly.
fn searchPersistentWithAppendedTailImpl(
    allocator: std.mem.Allocator,
    store: storage_mod.Store,
    query: []const u8,
    query_terms: []const []u8,
    options: TextSearchOptions,
) !?std.ArrayList(TextSearchHit) {
    const text_meta = readPersistentTextMeta(allocator, store) catch |err| switch (err) {
        error.FileNotFound, error.InvalidRecord => return null,
        else => |other| return other,
    };
    if (text_meta.indexed_event_bytes == 0) return null;
    const index_meta = currentPersistentTextMetaAnchor(store) catch |err| switch (err) {
        error.FileNotFound, error.InvalidRecord => return null,
        else => |other| return other,
    };
    const searchable_metadata_digest = store.searchableNodeMetadataDigestLimitedDeadline(
        allocator,
        stale_store_scan_max_property_delta_bytes,
        options.deadline,
    ) catch |err| switch (err) {
        // An oversized property delta must surface through the fallback's
        // canonical TextIndexMaintenanceRequired, not leak the budget error.
        error.SearchableMetadataBudgetExceeded => return null,
        error.FileNotFound, error.InvalidRecord => return null,
        else => |other| return other,
    };
    if (searchable_metadata_digest != text_meta.searchable_metadata_digest) return null;

    const cached_tail = (try obtainCachedTailContext(store, text_meta, index_meta, searchable_metadata_digest)) orelse return null;
    const tail_index = &cached_tail.index;
    const tail_node_ids = &cached_tail.node_ids;

    // Per-term document frequencies each side contributes to the other.
    var catalog_df = std.StringHashMap(u64).init(allocator);
    defer catalog_df.deinit();
    var tail_df = std.StringHashMap(u64).init(allocator);
    defer tail_df.deinit();
    {
        var catalog = PersistentPostingCatalog.open(allocator, store, text_meta.doc_count) catch |err| switch (err) {
            error.FileNotFound, error.InvalidRecord => return null,
            else => |other| return other,
        };
        defer catalog.deinit();
        for (query_terms) |term| {
            const catalog_entry = try catalog_df.getOrPut(term);
            if (catalog_entry.found_existing) continue;
            catalog_entry.value_ptr.* = if (try catalog.findTermEntry(term)) |lookup| lookup.entry.postings_count else 0;
            const tail_postings: u64 = if (tail_index.postings_by_term.get(term)) |postings| @intCast(postings.items.len) else 0;
            try tail_df.put(term, tail_postings);
        }
    }

    const tail_doc_count: u64 = @intCast(tail_index.docs.items.len);
    const field_weights = TextFieldWeights{};
    const merged_total_doc_len: f64 =
        @as(f64, @floatFromInt(text_meta.total_text_tokens)) * field_weights.text +
        @as(f64, tail_index.total_doc_len);
    const catalog_merge = search_contract.TextMergeStats{
        .doc_count = text_meta.doc_count + tail_doc_count,
        .total_doc_len = merged_total_doc_len,
        .other_df_context = @ptrCast(&tail_df),
        .otherDf = incrementalTailOtherDf,
    };
    const tail_merge = search_contract.TextMergeStats{
        .doc_count = text_meta.doc_count + tail_doc_count,
        .total_doc_len = merged_total_doc_len,
        .other_df_context = @ptrCast(&catalog_df),
        .otherDf = incrementalTailOtherDf,
    };

    var catalog_options = options;
    catalog_options.merge = &catalog_merge;
    // BudgetExceeded declines the merge instead of failing the query: the
    // fallback path owns the product semantics for unserveable scans.
    var catalog_hits = QueryExecutionOps.searchPersistentTokens(allocator, store, query_terms, catalog_options) catch |err| switch (err) {
        error.FileNotFound, error.InvalidRecord, core.Error.BudgetExceeded => return null,
        else => |other| return other,
    };
    defer catalog_hits.deinit(allocator);
    var tail_options = options;
    tail_options.merge = &tail_merge;
    var tail_hits = try tail_index.search(query, tail_options);
    // the cached tail index allocates its results with its own allocator
    defer tail_hits.deinit(tail_cache_allocator);

    var combined = std.ArrayList(TextSearchHit).empty;
    errdefer combined.deinit(allocator);
    for (catalog_hits.items) |hit| {
        if (tail_node_ids.contains(hit.node_id.toInt())) continue;
        try combined.append(allocator, hit);
    }
    try combined.appendSlice(allocator, tail_hits.items);
    std.mem.sort(TextSearchHit, combined.items, {}, textSearchHitLessThan);
    if (combined.items.len > options.limit) combined.shrinkRetainingCapacity(options.limit);
    return combined;
}

/// Private persisted-reader backend for the cohesive token execution owner.
/// It exposes no runtime entrypoint: callers reach the implementation only
/// through `QueryExecutionOps.searchPersistentTokens` above.
const PersistentQueryExecutionHotPathOps = struct {
    pub const PersistentTextMeta_dep = PersistentTextMeta;
    pub const PersistentPostingCatalog_dep = PersistentPostingCatalog;
    pub const TextDocsFileView_dep = TextDocsFileView;
    pub const CachedTextDoc_dep = CachedTextDoc;
    pub const TextDocRecord_dep = TextDocRecord;
    pub const PersistentQueryTermPlan_dep = PersistentQueryTermPlan;
    pub const PersistentQueryTermFreqCache_dep = PersistentQueryTermFreqCache;
    pub const PersistentSearchTermContext_dep = PersistentSearchTermContext;
    pub const PersistentSearchCandidateContext_dep = PersistentSearchCandidateContext;
    pub const PersistentSearchMediumTopCandidateContext_dep = PersistentSearchMediumTopCandidateContext;
    pub const SingleTermSearchContext_dep = SingleTermSearchContext;
    pub const FieldTermFreq_dep = FieldTermFreq;
    pub const persistent_query_term_freq_cache_max_terms_dep = persistent_query_term_freq_cache_max_terms;
    pub const persistent_multi_term_exact_candidate_max_postings_dep = persistent_multi_term_exact_candidate_max_postings;
    pub const persistent_search_canonical_freq_validate_posting_limit_dep = persistent_search_canonical_freq_validate_posting_limit;
    pub const persistent_term_top_hit_capacity_dep = persistent_term_top_hit_capacity;
    pub const persistent_term_top_hit_capacity_usize_dep = persistent_term_top_hit_capacity_usize;
    pub const persistent_posting_max_doc_id_dep = persistent_posting_max_doc_id;
    pub const readPersistentTextMeta_dep = readPersistentTextMeta;
    pub const deinitCachedTextDocs_dep = deinitCachedTextDocs;
    pub const openPersistentTextDocsView_dep = openPersistentTextDocsView;
    pub const persistentAvgDocLen_dep = persistentAvgDocLen;
    pub const persistentQueryTermPlanLessThan_dep = persistentQueryTermPlanLessThan;
    pub const persistentQueryTermPlanPostingTotal_dep = persistentQueryTermPlanPostingTotal;
    pub const forEachPersistentTermPostingLookupInCatalog_dep = forEachPersistentTermPostingLookupInCatalog;
    pub const scorePersistentSearchPosting_dep = scorePersistentSearchPosting;
    pub const getCachedTextDocFromView_dep = getCachedTextDocFromView;
    pub const getCachedTextDocRecordFromView_dep = getCachedTextDocRecordFromView;
    pub const textBenchTraceEnabled_dep = textBenchTraceEnabled;
    pub const canUsePersistentTermTopHitCandidateCache_dep = canUsePersistentTermTopHitCandidateCache;
    pub const textTermTopHitsPath_dep = textTermTopHitsPath;
    pub const regularFileSize_dep = regularFileSize;
    pub const readTextTermTopHitsHeaderFromFile_dep = readTextTermTopHitsHeaderFromFile;
    pub const textTermTopHitsFileSize_dep = textTermTopHitsFileSize;
    pub const putPersistentCandidateTextFreq_dep = putPersistentCandidateTextFreq;
    pub const collectPersistentSearchMediumTopCandidatePosting_dep = collectPersistentSearchMediumTopCandidatePosting;
    pub const collectPersistentSearchCandidatePosting_dep = collectPersistentSearchCandidatePosting;
    pub const readTextTermTopHitTermAt_dep = readTextTermTopHitTermAt;
    pub const readTextTermTopHitRecordAt_dep = readTextTermTopHitRecordAt;
    pub const fillPersistentCandidateTextFreqsFromCatalogDeadline_dep = fillPersistentCandidateTextFreqsFromCatalogDeadline;
    pub const catalogTextFreqForDoc_dep = catalogTextFreqForDoc;
    pub const persistentWeightedTfFromFieldFreq_dep = persistentWeightedTfFromFieldFreq;
    pub const persistentDocLen_dep = persistentDocLen;
    pub const canUsePersistentTermTopHitCache_dep = canUsePersistentTermTopHitCache;
    pub const readPersistentTermTopHitCache_dep = readPersistentTermTopHitCache;
    pub const publishedPostingBlockCountForEntry_dep = publishedPostingBlockCountForEntry;
    pub const scanPersistentTermPostings_dep = scanPersistentTermPostings;
    pub const appendSingleTermSearchPosting_dep = appendSingleTermSearchPosting;
    pub const persistentBlockPostingCount_dep = persistentBlockPostingCount;
    pub const scanPersistentPostingRange_dep = scanPersistentPostingRange;
};

/// Private backend for document catalog construction. Only the two complete
/// writer entrypoints cross the owner boundary; tokenizer, storage iteration,
/// posting builders, timing, and atomic replacement stay façade-owned.
const DocumentCatalogStreamWriterOps = struct {
    pub const TextBufferedWriter_dep = TextBufferedWriter;
    pub const TextDocRecord_dep = TextDocRecord;
    pub const TextDocsHeader_dep = TextDocsHeader;
    pub const TextDocNodeIdOverflowRecord_dep = TextDocNodeIdOverflowRecord;
    pub const FieldTermFreq_dep = FieldTermFreq;
    pub const TextPostingRunBuilder_dep = TextPostingRunBuilder;
    pub const PersistentTermBuilder_dep = PersistentTermBuilder;
    pub const PersistentTextMeta_dep = PersistentTextMeta;
    pub const PersistentTextRebuildTimings_dep = PersistentTextRebuildTimings;
    pub const PersistentTextRebuildObserver_dep = PersistentTextRebuildObserver;
    pub const SearchableNodeMetadata_dep = SearchableNodeMetadata;
    pub const SearchableNodeMetadataSnapshot_dep = SearchableNodeMetadataSnapshot;
    pub const TextRebuildTextFreqCache_dep = TextRebuildTextFreqCache;
    pub const clearReusableArenaTermFreqs_dep = clearReusableArenaTermFreqs;
    pub const clearReusableTermFreqs_dep = clearReusableTermFreqs;
    pub const searchableNodeTextBytes_dep = searchableNodeTextBytes;
    pub const collectStreamingSearchableNodeTermFreqs_dep = collectStreamingSearchableNodeTermFreqs;
    pub const collectSearchableNodeTermFreqs_dep = collectSearchableNodeTermFreqs;
    pub const textMonotonicNs_dep = textMonotonicNs;
    pub const textElapsedNs_dep = textElapsedNs;
    pub const persistent_doc_max_field_tokens_dep = persistent_doc_max_field_tokens;
    pub const persistent_doc_node_id_inline_max_dep = persistent_doc_node_id_inline_max;
    pub const nextPersistentTextDocId_dep = nextPersistentTextDocId;
    pub const isDeletedNodeTombstoneText_dep = isDeletedNodeTombstoneText;
    pub const isDeletedNodeTombstoneNode_dep = isDeletedNodeTombstoneNode;
    pub const textDocsPath_dep = textDocsPath;
    pub const tmpPathFor_dep = tmpPathFor;
    pub const text_write_buffer_bytes_dep = text_write_buffer_bytes;
    pub const text_rebuild_observer_doc_sample_interval_dep = text_rebuild_observer_doc_sample_interval;
    pub const recordPersistentTextRebuildObserver_dep = recordPersistentTextRebuildObserver;
    pub const textOptionsNeedSync_dep = textOptionsNeedSync;
    pub const renameReplace_dep = renameReplace;
};

const writeTextDocsFileFromStore = document_catalog_stream_writer.writeTextDocsFileFromStore;
const writeTextDocsFileFromStoreWithTermBuilder = document_catalog_stream_writer.writeTextDocsFileFromStoreWithTermBuilder;

/// Private publication backend. The child owns the five-file term/posting
/// set; the façade retains builders, low-level formats, rebuild session state,
/// and the final catalog metadata anchor.
const TermPostingCatalogPublicationOps = struct {
    pub const PersistentTermBuilder_dep = PersistentTermBuilder;
    pub const TextDocsFileView_dep = TextDocsFileView;
    pub const PersistentTextMeta_dep = PersistentTextMeta;
    pub const PersistentTextCatalogStats_dep = PersistentTextCatalogStats;
    pub const PersistentTerm_dep = PersistentTerm;
    pub const TextPostingRecord_dep = TextPostingRecord;
    pub const TextBufferedWriter_dep = TextBufferedWriter;
    pub const TextPostingsHeader_dep = TextPostingsHeader;
    pub const TextPostingBlocksHeader_dep = TextPostingBlocksHeader;
    pub const TextPostingBlockRecord_dep = TextPostingBlockRecord;
    pub const TextPostingBlockImpactsHeader_dep = TextPostingBlockImpactsHeader;
    pub const TextTermTopHitsHeader_dep = TextTermTopHitsHeader;
    pub const TextTermTopHitTermRecord_dep = TextTermTopHitTermRecord;
    pub const TextTermTopHitRecord_dep = TextTermTopHitRecord;
    pub const TextTopHitDocStats_dep = TextTopHitDocStats;
    pub const TextPostingBlockStats_dep = TextPostingBlockStats;
    pub const TextTermsHeader_dep = TextTermsHeader;
    pub const TextTermEntry_dep = TextTermEntry;
    pub const TextTermExceptionRecord_dep = TextTermExceptionRecord;
    pub const TextTermSingletonPayloadCheckpoint_dep = TextTermSingletonPayloadCheckpoint;
    pub const persistentTermLessThan_dep = persistentTermLessThan;
    pub const termPostingPayloadOrBodyOffset_dep = termPostingPayloadOrBodyOffset;
    pub const persistentTermFrontCodedLen_dep = persistentTermFrontCodedLen;
    pub const publishedPostingBodyBytesForTerm_dep = publishedPostingBodyBytesForTerm;
    pub const textPostingsPath_dep = textPostingsPath;
    pub const textPostingBlocksPath_dep = textPostingBlocksPath;
    pub const textPostingBlockImpactsPath_dep = textPostingBlockImpactsPath;
    pub const textTermTopHitsPath_dep = textTermTopHitsPath;
    pub const textTermsPath_dep = textTermsPath;
    pub const persistent_posting_block_size_dep = persistent_posting_block_size;
    pub const persistent_posting_block_capacity_dep = persistent_posting_block_capacity;
    pub const persistent_term_top_hit_capacity_dep = persistent_term_top_hit_capacity;
    pub const persistent_term_top_hit_min_postings_dep = persistent_term_top_hit_min_postings;
    pub const text_write_buffer_bytes_dep = text_write_buffer_bytes;
    pub const tmpPathFor_dep = tmpPathFor;
    pub const textOptionsNeedSync_dep = textOptionsNeedSync;
    pub const renameReplace_dep = renameReplace;
    pub const compressedTextPostingBytesForTerm_dep = compressedTextPostingBytesForTerm;
    pub const encodeTextPostingsHeader_dep = encodeTextPostingsHeader;
    pub const canVirtualizeAllDocsConstantTextFreqTerm_dep = canVirtualizeAllDocsConstantTextFreqTerm;
    pub const virtualAllDocsConstantTextFreq_dep = virtualAllDocsConstantTextFreq;
    pub const canDenseAllDocsFreqStream_dep = canDenseAllDocsFreqStream;
    pub const appendDenseAllDocsFreqStreamPostings_dep = appendDenseAllDocsFreqStreamPostings;
    pub const encodeTextPostingRecord_dep = encodeTextPostingRecord;
    pub const encodeCompressedTextPosting_dep = encodeCompressedTextPosting;
    pub const textPostingsFileSize_dep = textPostingsFileSize;
    pub const readTextPostingsHeaderFromFile_dep = readTextPostingsHeaderFromFile;
    pub const encodeTextPostingBlocksHeader_dep = encodeTextPostingBlocksHeader;
    pub const textPostingBlockRecordFromStats_dep = textPostingBlockRecordFromStats;
    pub const encodeTextPostingBlockRecord_dep = encodeTextPostingBlockRecord;
    pub const textPostingBlocksFileSize_dep = textPostingBlocksFileSize;
    pub const quantizePersistentBlockScoreBounds_dep = quantizePersistentBlockScoreBounds;
    pub const encodeTextPostingBlockImpactsHeader_dep = encodeTextPostingBlockImpactsHeader;
    pub const encodePersistentBlockOrdinal_dep = encodePersistentBlockOrdinal;
    pub const textPostingBlockImpactsFileSize_dep = textPostingBlockImpactsFileSize;
    pub const textTermTopHitLessThan_dep = textTermTopHitLessThan;
    pub const textTermTopHitScoreOrderValid_dep = textTermTopHitScoreOrderValid;
    pub const persistentWeightedTf_dep = persistentWeightedTf;
    pub const persistentDocLen_dep = persistentDocLen;
    pub const persistentAvgDocLen_dep = persistentAvgDocLen;
    pub const encodeTextTermTopHitsHeader_dep = encodeTextTermTopHitsHeader;
    pub const encodeTextTermTopHitTermRecord_dep = encodeTextTermTopHitTermRecord;
    pub const encodeTextTermTopHitRecord_dep = encodeTextTermTopHitRecord;
    pub const textTermTopHitsFileSize_dep = textTermTopHitsFileSize;
    pub const canInlineSingletonPosting_dep = canInlineSingletonPosting;
    pub const textTermEntryFromPersistentTerm_dep = textTermEntryFromPersistentTerm;
    pub const persistentTermFrontCodedPrefixLen_dep = persistentTermFrontCodedPrefixLen;
    pub const appendPersistentFrontCodedTerm_dep = appendPersistentFrontCodedTerm;
    pub const encodeTextTermExceptionRecord_dep = encodeTextTermExceptionRecord;
    pub const encodeTextTermSingletonPayloadCheckpoint_dep = encodeTextTermSingletonPayloadCheckpoint;
    pub const textTermsFileSizeForHeader_dep = textTermsFileSizeForHeader;
    pub const textWriteBufferCapacity_dep = textWriteBufferCapacity;
    pub const termEntryVirtualAllDocsTextFreq_dep = termEntryVirtualAllDocsTextFreq;
    pub const persistent_term_inline_posting_marker_dep = persistent_term_inline_posting_marker;
    pub const addPostingToBlockStats_dep = addPostingToBlockStats;
    pub const termEntryHasInlinePosting_dep = termEntryHasInlinePosting;
    pub const decodeInlineSingletonPostingPayload_dep = decodeInlineSingletonPostingPayload;
    pub const textTermSingletonPayloadCount_dep = textTermSingletonPayloadCount;
    pub const compressed_posting_max_encoded_len_dep = compressed_posting_max_encoded_len;
    pub const persistent_posting_block_ordinal_len_dep = persistent_posting_block_ordinal_len;
    pub const textTermTopHitCandidateCannotBeatCurrentWorst_dep = textTermTopHitCandidateCannotBeatCurrentWorst;
    pub const termEntryDenseAllDocsFreqStreamOffset_dep = termEntryDenseAllDocsFreqStreamOffset;
    pub const persistent_term_singleton_payload_checkpoint_terms_dep = persistent_term_singleton_payload_checkpoint_terms;
    pub const textTermSingletonPayloadCheckpointTableBytes_dep = textTermSingletonPayloadCheckpointTableBytes;
    pub const textTermsFileSize_dep = textTermsFileSize;
    pub const compressedTextPostingBytesForRange_dep = compressedTextPostingBytesForRange;
    pub const bm25WeightedTermScore_dep = bm25WeightedTermScore;
    pub const encodeZigZagI64_dep = encodeZigZagI64;
    pub const singletonPayloadDelta_dep = singletonPayloadDelta;
    pub const encodeTextTermsHeader_dep = encodeTextTermsHeader;
    pub const persistent_posting_block_offset_checkpoint_terms_dep = persistent_posting_block_offset_checkpoint_terms;
    pub const encodePersistentVarint_dep = encodePersistentVarint;
    pub const encodeTextTermEntry_dep = encodeTextTermEntry;
    pub const persistent_posting_block_byte_offset_checkpoint_blocks_dep = persistent_posting_block_byte_offset_checkpoint_blocks;
    pub const appendTopTextTermHitBoundedCachedWorst_dep = appendTopTextTermHitBoundedCachedWorst;
    pub const textTermByteOffsetCheckpointTableBytes_dep = textTermByteOffsetCheckpointTableBytes;
    pub const persistent_term_byte_offset_checkpoint_terms_dep = persistent_term_byte_offset_checkpoint_terms;
    pub const persistent_term_bytes_max_offset_dep = persistent_term_bytes_max_offset;
    pub const persistent_term_exception_rank_checkpoint_terms_dep = persistent_term_exception_rank_checkpoint_terms;
    pub const textTermExceptionRankCheckpointCount_dep = textTermExceptionRankCheckpointCount;
    pub const textTermExceptionMembershipBytes_dep = textTermExceptionMembershipBytes;
};

const writeTermsAndPostingsFiles = term_posting_catalog_publication.writeTermsAndPostingsFiles;
const writeEmptyTermsAndPostingsFiles = term_posting_catalog_publication.writeEmptyTermsAndPostingsFiles;
const writeTextPostingsFile = term_posting_catalog_publication.writeTextPostingsFile;
const writeTextPostingBlocksFile = term_posting_catalog_publication.writeTextPostingBlocksFile;
const MemoryPostingBlockImpact = term_posting_catalog_publication.MemoryPostingBlockImpact;
const memoryPostingBlockImpactLessThan = term_posting_catalog_publication.memoryPostingBlockImpactLessThan;
const writeTextPostingBlockImpactsFile = term_posting_catalog_publication.writeTextPostingBlockImpactsFile;
const writeTextTermTopHitsFile = term_posting_catalog_publication.writeTextTermTopHitsFile;
const textTermTopHitCount = term_posting_catalog_publication.textTermTopHitCount;
const textTermTopHitTermCount = term_posting_catalog_publication.textTermTopHitTermCount;
const persistentTermTopHitCountForTerm = term_posting_catalog_publication.persistentTermTopHitCountForTerm;
const persistentTermTopHitCountForPostingCount = term_posting_catalog_publication.persistentTermTopHitCountForPostingCount;
const postingBlockCountForTerms = term_posting_catalog_publication.postingBlockCountForTerms;
const publishedPostingBlockCountForEntry = term_posting_catalog_publication.publishedPostingBlockCountForEntry;
const publishedPostingBlockCountForPayload = term_posting_catalog_publication.publishedPostingBlockCountForPayload;
const publishedPostingBlockCount = term_posting_catalog_publication.publishedPostingBlockCount;
const postingBlockCount = term_posting_catalog_publication.postingBlockCount;
const postingBlockStatsFromMemory = term_posting_catalog_publication.postingBlockStatsFromMemory;
const persistentTermExceptionCount = term_posting_catalog_publication.persistentTermExceptionCount;
const SingletonPayloadBytes = term_posting_catalog_publication.SingletonPayloadBytes;
const appendSingletonPayloadBytes = term_posting_catalog_publication.appendSingletonPayloadBytes;
const buildSingletonPayloadBytes = term_posting_catalog_publication.buildSingletonPayloadBytes;
const writeTextTermsFile = term_posting_catalog_publication.writeTextTermsFile;

/// Private read-side backend for full and bounded catalog validation. The
/// owner controls stale/error classification; low-level format readers and
/// canonical storage access remain behind this façade-supplied interface.
const PersistentCatalogValidationOps = struct {
    pub const PersistentTextMeta_dep = PersistentTextMeta;
    pub const TextDocsHeader_dep = TextDocsHeader;
    pub const TextDocRecord_dep = TextDocRecord;
    pub const TextPostingsFileView_dep = TextPostingsFileView;
    pub const TextPostingsHeader_dep = TextPostingsHeader;
    pub const TextPostingBlocksHeader_dep = TextPostingBlocksHeader;
    pub const TextPostingBlockImpactsHeader_dep = TextPostingBlockImpactsHeader;
    pub const TextTermTopHitsHeader_dep = TextTermTopHitsHeader;
    pub const TextTermsHeader_dep = TextTermsHeader;
    pub const TextPostingBlockStats_dep = TextPostingBlockStats;
    pub const readPersistentTextMeta_dep = readPersistentTextMeta;
    pub const currentPersistentTextMetaAnchor_dep = currentPersistentTextMetaAnchor;
    pub const textDocsPath_dep = textDocsPath;
    pub const regularFileSize_dep = regularFileSize;
    pub const readTextDocsHeaderFromFile_dep = readTextDocsHeaderFromFile;
    pub const textDocsFileSizeForHeader_dep = textDocsFileSizeForHeader;
    pub const stale_store_scan_max_property_delta_bytes_dep = stale_store_scan_max_property_delta_bytes;
    pub const readTextDocRecordAtWithHeader_dep = readTextDocRecordAtWithHeader;
    pub const readTextDocNodeIdOverflowRecordAt_dep = readTextDocNodeIdOverflowRecordAt;
    pub const textDocRecordOffsetForHeader_dep = textDocRecordOffsetForHeader;
    pub const persistent_doc_node_id_overflow_marker_dep = persistent_doc_node_id_overflow_marker;
    pub const isDeletedNodeTombstoneNode_dep = isDeletedNodeTombstoneNode;
    pub const readSearchableNodeMetadata_dep = readSearchableNodeMetadata;
    pub const validateTextDocAgainstNodeRefCached_dep = validateTextDocAgainstNodeRefCached;
    pub const textTermsPath_dep = textTermsPath;
    pub const readTextTermsHeaderFromFile_dep = readTextTermsHeaderFromFile;
    pub const textTermsFileSizeForHeader_dep = textTermsFileSizeForHeader;
    pub const textPostingsPath_dep = textPostingsPath;
    pub const textPostingsFileSize_dep = textPostingsFileSize;
    pub const readTextPostingsHeaderFromFile_dep = readTextPostingsHeaderFromFile;
    pub const textPostingBlocksPath_dep = textPostingBlocksPath;
    pub const readTextPostingBlocksHeaderFromFile_dep = readTextPostingBlocksHeaderFromFile;
    pub const persistent_posting_block_size_dep = persistent_posting_block_size;
    pub const textPostingBlocksFileSize_dep = textPostingBlocksFileSize;
    pub const textPostingBlockImpactsPath_dep = textPostingBlockImpactsPath;
    pub const readTextPostingBlockImpactsHeaderFromFile_dep = readTextPostingBlockImpactsHeaderFromFile;
    pub const textPostingBlockImpactsFileSize_dep = textPostingBlockImpactsFileSize;
    pub const persistentAvgDocLen_dep = persistentAvgDocLen;
    pub const textTermTopHitsPath_dep = textTermTopHitsPath;
    pub const readTextTermTopHitsHeaderFromFile_dep = readTextTermTopHitsHeaderFromFile;
    pub const persistent_term_top_hit_capacity_dep = persistent_term_top_hit_capacity;
    pub const textTermTopHitsFileSize_dep = textTermTopHitsFileSize;
    pub const readTextTermTopHitTermRecordAt_dep = readTextTermTopHitTermRecordAt;
    pub const readTextTermEntryAt_dep = readTextTermEntryAt;
    pub const termEntryHasInlinePosting_dep = termEntryHasInlinePosting;
    pub const termEntryVirtualAllDocsTextFreq_dep = termEntryVirtualAllDocsTextFreq;
    pub const termEntryDenseAllDocsFreqStreamOffset_dep = termEntryDenseAllDocsFreqStreamOffset;
    pub const persistent_term_byte_offset_checkpoint_terms_dep = persistent_term_byte_offset_checkpoint_terms;
    pub const readTextTermByteOffsetCheckpointAt_dep = readTextTermByteOffsetCheckpointAt;
    pub const readFrontCodedTermAtOffset_dep = readFrontCodedTermAtOffset;
    pub const persistent_posting_block_offset_checkpoint_terms_dep = persistent_posting_block_offset_checkpoint_terms;
    pub const readTextPostingBlockOffsetCheckpointAt_dep = readTextPostingBlockOffsetCheckpointAt;
    pub const publishedPostingBlockCountForEntry_dep = publishedPostingBlockCountForEntry;
    pub const SkipTextPostingContext_dep = SkipTextPostingContext;
    pub const scanPersistentTermPostings_dep = scanPersistentTermPostings;
    pub const skipTextPosting_dep = skipTextPosting;
    pub const scanPersistentPostingBlocks_dep = scanPersistentPostingBlocks;
    pub const textTermExceptionMembershipBytes_dep = textTermExceptionMembershipBytes;
    pub const readTextTermExceptionMembershipByteAt_dep = readTextTermExceptionMembershipByteAt;
    pub const persistent_term_exception_rank_checkpoint_terms_dep = persistent_term_exception_rank_checkpoint_terms;
    pub const readTextTermExceptionRankCheckpointAt_dep = readTextTermExceptionRankCheckpointAt;
    pub const readTextTermExceptionRecordAt_dep = readTextTermExceptionRecordAt;
    pub const readTextPostingImpactBlockIndexAt_dep = readTextPostingImpactBlockIndexAt;
    pub const readTextPostingBlockRecordAt_dep = readTextPostingBlockRecordAt;
    pub const bm25WeightedTermScore_dep = bm25WeightedTermScore;
    pub const textPostingBlockRecordConservativelyMatches_dep = textPostingBlockRecordConservativelyMatches;
    pub const textPostingBlockRecordFromStats_dep = textPostingBlockRecordFromStats;
    pub const persistent_posting_block_byte_offset_checkpoint_blocks_dep = persistent_posting_block_byte_offset_checkpoint_blocks;
    pub const readTextPostingBlockByteOffsetCheckpointAt_dep = readTextPostingBlockByteOffsetCheckpointAt;
};

const persistentTextMetaAnchorStale = persistent_catalog_validation.persistentTextMetaAnchorStale;
const persistentTextGraphAnchorStale = persistent_catalog_validation.persistentTextGraphAnchorStale;
pub const persistentTextCatalogStale = persistent_catalog_validation.persistentTextCatalogStale;
pub const persistentTextCatalogQuickStale = persistent_catalog_validation.persistentTextCatalogQuickStale;
const persistentTextCatalogStaleDeadline = persistent_catalog_validation.persistentTextCatalogStaleDeadline;
const persistentTextCatalogQuickStaleDeadline = persistent_catalog_validation.persistentTextCatalogQuickStaleDeadline;
const persistentTextDocsHeaderStale = persistent_catalog_validation.persistentTextDocsHeaderStale;
const persistentTextDocsInvalid = persistent_catalog_validation.persistentTextDocsInvalid;
const persistentTermsOrPostingsStale = persistent_catalog_validation.persistentTermsOrPostingsStale;
const persistentTermsOrPostingsHeaderStale = persistent_catalog_validation.persistentTermsOrPostingsHeaderStale;
const persistentTermTopHitsSparseIndexInvalid = persistent_catalog_validation.persistentTermTopHitsSparseIndexInvalid;
const persistentTermDictionaryInvalid = persistent_catalog_validation.persistentTermDictionaryInvalid;
const textTermExceptionTableInvalid = persistent_catalog_validation.textTermExceptionTableInvalid;
const ValidatePostingBlocksContext = persistent_catalog_validation.ValidatePostingBlocksContext;
const validatePostingBlockRecord = persistent_catalog_validation.validatePostingBlockRecord;

pub const persistent_text_index_version = catalog_format.persistent_text_index_version;
pub const tokenizer_version = catalog_format.tokenizer_version;
const persistent_posting_block_size: u64 = 128;
const persistent_posting_block_capacity: usize = @intCast(persistent_posting_block_size);
const production_persistent_posting_block_offset_checkpoint_terms: u64 = 128;
const test_persistent_posting_block_offset_checkpoint_terms: u64 = 16;
const persistent_posting_block_offset_checkpoint_terms: u64 = if (builtin.is_test) test_persistent_posting_block_offset_checkpoint_terms else production_persistent_posting_block_offset_checkpoint_terms;
const production_persistent_posting_block_byte_offset_checkpoint_blocks: u64 = 8;
const test_persistent_posting_block_byte_offset_checkpoint_blocks: u64 = 2;
const persistent_posting_block_byte_offset_checkpoint_blocks: u64 = if (builtin.is_test) test_persistent_posting_block_byte_offset_checkpoint_blocks else production_persistent_posting_block_byte_offset_checkpoint_blocks;
const persistent_elias_fano_select_checkpoint_postings: u64 = persistent_posting_block_size;
const persistent_elias_fano_select_checkpoint_bytes: u64 = 8;
const persistent_term_byte_offset_checkpoint_terms = term_format.Internal.term_byte_offset_checkpoint_terms;
const persistent_term_bytes_max_offset = term_format.Internal.term_bytes_max_offset;
const persistent_term_max_len = term_format.Internal.term_max_len;
const persistent_doc_max_field_tokens = catalog_format.persistent_doc_max_field_tokens;
const persistent_doc_node_id_inline_max = catalog_format.persistent_doc_node_id_inline_max;
const persistent_doc_node_id_overflow_marker = catalog_format.persistent_doc_node_id_overflow_marker;
const persistent_term_inline_posting_marker = term_format.Internal.term_inline_posting_marker;
const persistent_term_virtual_all_docs_payload_marker = term_format.Internal.term_virtual_all_docs_payload_marker;
const persistent_term_inline_posting_payload_mask = term_format.Internal.term_inline_posting_payload_mask;
const persistent_term_dense_all_docs_freq_stream_payload_base = term_format.Internal.term_dense_all_docs_freq_stream_payload_base;
const persistent_postings_body_max_offset = term_format.Internal.postings_body_max_offset;
const persistent_inline_posting_doc_id_bits = term_format.Internal.inline_posting_doc_id_bits;
const persistent_inline_posting_max_doc_id = term_format.Internal.inline_posting_max_doc_id;
const persistent_posting_max_doc_id = catalog_format.persistent_posting_max_doc_id;
const persistent_posting_max_field_freq = PostingFormatConfig.persistent_posting_max_field_freq;
const persistent_posting_max_kind_freq = PostingFormatConfig.persistent_posting_max_kind_freq;
const persistent_term_max_doc_freq = term_format.Internal.term_max_doc_freq;
const persistent_term_exception_payload_len = term_format.Internal.term_exception_payload_len;
const persistent_term_exception_plain_offset_flag = term_format.Internal.term_exception_plain_offset_flag;
const persistent_term_exception_dense_freq_stream_flag = term_format.Internal.term_exception_dense_freq_stream_flag;
const persistent_term_exception_doc_freq_mask = term_format.Internal.term_exception_doc_freq_mask;
const persistent_term_exception_rank_checkpoint_terms = term_format.Internal.term_exception_rank_checkpoint_terms;
const persistent_term_singleton_payload_checkpoint_terms = term_format.Internal.term_singleton_payload_checkpoint_terms;
const persistent_term_singleton_payload_checkpoint_len = term_format.Internal.term_singleton_payload_checkpoint_len;
const persistent_posting_max_block_ordinal = search_acceleration_format.Internal.persistent_posting_max_block_ordinal;
const persistent_posting_block_ordinal_len = search_acceleration_format.Internal.persistent_posting_block_ordinal_len;
const persistent_block_score_f16_max = search_acceleration_format.Internal.persistent_block_score_f16_max;
const persistent_term_top_hit_capacity: u64 = 64;
const persistent_term_top_hit_capacity_usize: usize = @intCast(persistent_term_top_hit_capacity);
/// Public bound for callers that over-fetch candidates (for example the
/// TinyQL latest-generation retention probe): a candidate request kept at or
/// below this value can be served from the persistent top-hit caches, while
/// one candidate more forces common terms onto the unbounded posting scan.
pub const persistent_term_top_hit_candidate_budget: usize = @intCast(persistent_term_top_hit_capacity);
const persistent_term_top_hit_regular_probe_capacity: usize = 8;
// Medium-frequency terms can still blow the aggregate multi-term scan budget
// at GB3+ even when each term is far below the default per-query cap.
// Tied to the default posting-scan budget: any term too large to scan within
// `core.default_max_text_postings_scanned` must have a persisted top-hit
// cache, otherwise queries touching it can only fail with BudgetExceeded. A
// gap between these two constants is an unserveable posting-count band.
// Medium-frequency terms (tens of thousands of postings) dominate read P95:
// they stay under the scan budget, so without a published top-hit list every
// query walks their whole posting range (~5ms on a gb1 store). Publishing
// top hits from two posting blocks up keeps those queries on the ~1ms cached
// path; the scan budget itself stays at default_max_text_postings_scanned.
const persistent_term_top_hit_production_min_postings: u64 = 8_192;
const persistent_term_top_hit_test_min_postings: u64 = persistent_posting_block_size;
const persistent_term_top_hit_min_postings: u64 = if (builtin.is_test)
    persistent_term_top_hit_test_min_postings
else
    persistent_term_top_hit_production_min_postings;
// All-doc synthesis is a storage-density rule, not only a query-cache rule.
// The agent-text ladder has many medium-frequency terms; letting all-doc terms
// synthesize at the same rung as top-hit publication avoids repeatedly storing
// and scanning facts that are already implied by the document catalog.
const persistent_all_docs_synthesis_min_postings_value: u64 = if (builtin.is_test)
    persistent_term_top_hit_test_min_postings
else
    persistent_term_top_hit_production_min_postings;
const persistent_all_docs_synthesis_min_postings = persistent_all_docs_synthesis_min_postings_value;
const test_high_impact_repeated_term_count: usize = 8;
const persistent_dense_all_docs_freq_group_size: usize = 8;
const persistent_dense_all_docs_top_hit_skip_run_max: usize = 4096;
const persistent_dense_all_docs_freq_mode_packed: u8 = 0;
const persistent_dense_all_docs_freq_mode_rle: u8 = 1;
const persistent_dense_all_docs_freq_mode_bitpacked: u8 = 2;
// Publication opens run and summary readers alongside output files. Keep fan-in
// comfortably below common per-process fd quotas instead of assuming a large
// ulimit during guarded GB10 runs.
const text_posting_run_direct_merge_fan_in: usize = 128;
// Keep chunks large enough that real-shaped GB10 does not pay excessive
// run/summary rewrites while still respecting the fd-safe merge fan-in.
const text_posting_run_chunk_records_default: usize = 3 * 1024 * 1024;

/// Chunk capacity is a maintenance-job memory budget, not a service-runtime
/// one: the resident query daemons never build runs. A fixed chunk makes run
/// count grow linearly with the corpus, and once it passes the merge fan-in
/// the publication pays a whole extra rewrite pass of every posting (measured
/// 12.7x per-posting cost at gb10 against gb1). Maintenance therefore scales
/// the chunk with the corpus so the expected run count stays inside one merge
/// pass, and only the resident service keeps the flat default.
var text_posting_run_chunk_records_runtime: usize = text_posting_run_chunk_records_default;

fn textPostingRunChunkRecords() usize {
    return text_posting_run_chunk_records_runtime;
}

/// Scale the run-chunk budget for a maintenance rebuild over `doc_count`
/// documents. Postings-per-document is corpus-shaped and stable across the
/// audited corpora (~200); the chunk is sized so expected runs fit one merge
/// pass, clamped to [default, 64Mi records] (a ~1.5GiB ceiling at 24 bytes
/// per record). `TINYKG_TEXT_REBUILD_CHUNK_RECORDS` overrides the result for
/// deliberate experiments and constrained hosts.
pub fn scaleTextPostingRunChunkRecordsForCorpus(doc_count: u64) void {
    const max_chunk_records: u64 = 64 * 1024 * 1024;
    if (std.c.getenv("TINYKG_TEXT_REBUILD_CHUNK_RECORDS")) |raw| {
        const parsed = std.fmt.parseInt(u64, std.mem.span(raw), 10) catch 0;
        if (parsed != 0) {
            text_posting_run_chunk_records_runtime = std.math.cast(usize, @min(parsed, max_chunk_records)) orelse text_posting_run_chunk_records_default;
            return;
        }
    }
    const postings_per_doc: u64 = 202;
    const expected_postings = std.math.mul(u64, doc_count, postings_per_doc) catch max_chunk_records * text_posting_run_direct_merge_fan_in;
    const single_pass_chunk = std.math.divCeil(u64, expected_postings, text_posting_run_direct_merge_fan_in) catch max_chunk_records;
    const clamped = @min(max_chunk_records, @max(@as(u64, text_posting_run_chunk_records_default), single_pass_chunk));
    text_posting_run_chunk_records_runtime = std.math.cast(usize, clamped) orelse text_posting_run_chunk_records_default;
}
const text_posting_run_merge_fan_in: usize = 128;
const text_posting_run_front_coded_legacy_magic = "TKGRUN3\n".*;
const text_posting_run_front_coded_magic = "TKGRUN4\n".*;
const text_posting_run_front_coded_prefix_tag_base: u8 = 128;
const front_coded_entry_prefix_marker = term_format.Internal.front_coded_entry_prefix_marker;
const text_rebuild_term_arena_retain_limit: usize = 64 * 1024;
const text_rebuild_term_freq_retain_capacity_limit: usize = 4096;
const text_rebuild_observer_doc_sample_interval: u64 = 65_536;

pub const PersistentTextMeta = catalog_format.PersistentTextMeta;

pub const PersistentTextTermsByteStats = struct {
    total_bytes: u64 = 0,
    header_bytes: u64 = 0,
    entry_bytes: u64 = 0,
    front_coded_bytes: u64 = 0,
    offset_checkpoint_bytes: u64 = 0,
    exception_bytes: u64 = 0,
    singleton_checkpoint_bytes: u64 = 0,
    singleton_payload_bytes: u64 = 0,
    term_count: u64 = 0,
    exception_count: u64 = 0,
    singleton_count: u64 = 0,
    offset_checkpoint_count: u64 = 0,
    singleton_checkpoint_count: u64 = 0,
};

pub fn readPersistentTextTermsByteStatsAtPath(io: std.Io, path: []const u8) !PersistentTextTermsByteStats {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    const stat = try file.stat(io);
    if (stat.kind != .file) return error.IsDir;
    var header_bytes: [TextTermsHeader.encoded_len]u8 = undefined;
    const n = try file.readPositionalAll(io, &header_bytes, 0);
    if (n != header_bytes.len) return error.InvalidRecord;
    const header = try decodeTextTermsHeader(&header_bytes);
    const expected_size = try textTermsFileSizeForHeader(header);
    if (stat.size != expected_size) return error.InvalidRecord;

    const entry_bytes = std.math.mul(u64, header.term_count, TextTermEntry.encoded_len) catch return error.RecordTooLarge;
    const offset_checkpoint_count = try textTermByteOffsetCheckpointCount(header.term_count);
    const offset_checkpoint_bytes = try textTermByteOffsetCheckpointTableBytes(header.term_count);
    const exception_bytes = try textTermExceptionTableBytes(header.term_count, header.term_exception_count);
    const singleton_count = try textTermSingletonPayloadCount(header.term_count, header.term_exception_count);
    const singleton_checkpoint_count = try textTermSingletonPayloadCheckpointCount(singleton_count);
    const singleton_checkpoint_bytes = try textTermSingletonPayloadCheckpointTableBytes(singleton_count);

    return .{
        .total_bytes = stat.size,
        .header_bytes = TextTermsHeader.encoded_len,
        .entry_bytes = entry_bytes,
        .front_coded_bytes = header.term_bytes,
        .offset_checkpoint_bytes = offset_checkpoint_bytes,
        .exception_bytes = exception_bytes,
        .singleton_checkpoint_bytes = singleton_checkpoint_bytes,
        .singleton_payload_bytes = header.singleton_payload_bytes,
        .term_count = header.term_count,
        .exception_count = header.term_exception_count,
        .singleton_count = singleton_count,
        .offset_checkpoint_count = offset_checkpoint_count,
        .singleton_checkpoint_count = singleton_checkpoint_count,
    };
}

pub const TextDocsHeader = catalog_format.TextDocsHeader;
pub const TextDocRecord = catalog_format.TextDocRecord;
const TextDocNodeIdOverflowRecord = catalog_format.TextDocNodeIdOverflowRecord;

pub const TextTermsHeader = term_format.TextTermsHeader;
pub const TextTermEntry = term_format.TextTermEntry;

pub const TextPostingsHeader = posting_format.TextPostingsHeader;
pub const TextPostingRecord = posting_format.TextPostingRecord;

const text_posting_run_record_long_term_threshold = 64;

const TextPostingRunRecord = struct {
    term_sort_prefix: u64,
    doc_id: u32,
    text_freq: u16,
    kind_freq: u8,
    term_len: u8,
    term_bytes: [default_max_token_bytes]u8 = [_]u8{0} ** default_max_token_bytes,

    pub const header_len: usize = TextPostingRecord.encoded_len + 1;
    pub const max_encoded_len: usize = header_len + default_max_token_bytes;
    const term_len_offset: usize = TextPostingRecord.encoded_len;

    pub fn init(term_bytes: []const u8, posting: TextPostingRecord) !TextPostingRunRecord {
        if (term_bytes.len == 0 or term_bytes.len > default_max_token_bytes) return error.InvalidRecord;
        try validateTextPostingFields(posting.doc_id, posting.text_freq, posting.kind_freq);
        var record = TextPostingRunRecord{
            .term_sort_prefix = termSortPrefixKey(term_bytes),
            .doc_id = @intCast(posting.doc_id),
            .text_freq = @intCast(posting.text_freq),
            .kind_freq = @intCast(posting.kind_freq),
            .term_len = @intCast(term_bytes.len),
            .term_bytes = undefined,
        };
        @memcpy(record.term_bytes[0..term_bytes.len], term_bytes);
        return record;
    }

    fn initTrustedDecodedTextPosting(term_bytes: []const u8, doc_id: u32, text_freq: u16) !TextPostingRunRecord {
        return initTrustedDecodedTextPostingWithPrefix(term_bytes, termSortPrefixKey(term_bytes), doc_id, text_freq);
    }

    fn initTrustedDecodedTextPostingWithPrefix(term_bytes: []const u8, term_sort_prefix: u64, doc_id: u32, text_freq: u16) !TextPostingRunRecord {
        if (term_bytes.len == 0 or term_bytes.len > default_max_token_bytes) return error.InvalidRecord;
        if (doc_id == 0 or text_freq == 0) return error.InvalidRecord;
        if (@as(u64, doc_id) > persistent_posting_max_doc_id) return error.RecordTooLarge;
        var record = TextPostingRunRecord{
            .term_sort_prefix = term_sort_prefix,
            .doc_id = doc_id,
            .text_freq = text_freq,
            .kind_freq = 0,
            .term_len = @intCast(term_bytes.len),
            .term_bytes = undefined,
        };
        @memcpy(record.term_bytes[0..term_bytes.len], term_bytes);
        return record;
    }

    fn encode(self: TextPostingRunRecord, out: *[max_encoded_len]u8) !usize {
        const term_len = std.math.cast(u8, self.term_len) orelse return error.RecordTooLarge;
        var posting_bytes: [TextPostingRecord.encoded_len]u8 = undefined;
        try encodeTextPostingRecord(try self.toPosting(), &posting_bytes);
        @memcpy(out[0..TextPostingRecord.encoded_len], &posting_bytes);
        out[term_len_offset] = term_len;
        const term_len_usize: usize = self.term_len;
        @memcpy(out[header_len .. header_len + term_len_usize], self.term());
        return header_len + term_len_usize;
    }

    fn decode(bytes: []const u8) !TextPostingRunRecord {
        if (bytes.len < header_len) return error.InvalidRecord;
        const term_len: usize = bytes[term_len_offset];
        if (term_len == 0 or term_len > default_max_token_bytes) return error.InvalidRecord;
        if (bytes.len != header_len + term_len) return error.InvalidRecord;
        const posting = try decodeTextPostingRecord(bytes[0..TextPostingRecord.encoded_len]);
        return try TextPostingRunRecord.init(bytes[header_len .. header_len + term_len], posting);
    }

    pub fn term(self: *const TextPostingRunRecord) []const u8 {
        return self.term_bytes[0..@as(usize, self.term_len)];
    }

    fn toPosting(self: TextPostingRunRecord) !TextPostingRecord {
        try validateTextPostingFields(self.doc_id, self.text_freq, self.kind_freq);
        return .{
            .doc_id = self.doc_id,
            .text_freq = self.text_freq,
            .kind_freq = self.kind_freq,
        };
    }

    pub fn toPostingAssumeValid(self: TextPostingRunRecord) TextPostingRecord {
        return .{
            .doc_id = self.doc_id,
            .text_freq = self.text_freq,
            .kind_freq = self.kind_freq,
        };
    }
};

const TextPostingRunChunkRecord = struct {
    term_sort_prefix: u64,
    doc_id: u32,
    term_offset: u32,
    text_freq: u16,
    kind_freq: u8,
    term_len: u8,

    fn init(record: TextPostingRunRecord, term_offset: u32) TextPostingRunChunkRecord {
        return .{
            .term_sort_prefix = record.term_sort_prefix,
            .doc_id = record.doc_id,
            .term_offset = term_offset,
            .text_freq = record.text_freq,
            .kind_freq = record.kind_freq,
            .term_len = record.term_len,
        };
    }

    fn initFromTermPosting(term_bytes: []const u8, posting: TextPostingRecord, term_offset: u32) !TextPostingRunChunkRecord {
        if (term_bytes.len == 0 or term_bytes.len > default_max_token_bytes) return error.InvalidRecord;
        try validateTextPostingFields(posting.doc_id, posting.text_freq, posting.kind_freq);
        return .{
            .term_sort_prefix = termSortPrefixKey(term_bytes),
            .doc_id = @intCast(posting.doc_id),
            .term_offset = term_offset,
            .text_freq = @intCast(posting.text_freq),
            .kind_freq = @intCast(posting.kind_freq),
            .term_len = @intCast(term_bytes.len),
        };
    }

    pub fn term(self: TextPostingRunChunkRecord, term_bytes: []const u8) ![]const u8 {
        const start: usize = self.term_offset;
        const end = std.math.add(usize, start, self.term_len) catch return error.InvalidRecord;
        if (end > term_bytes.len) return error.InvalidRecord;
        return term_bytes[start..end];
    }

    fn termAssumeValid(self: TextPostingRunChunkRecord, term_bytes: []const u8) []const u8 {
        const start: usize = self.term_offset;
        const end = start + self.term_len;
        std.debug.assert(end <= term_bytes.len);
        return term_bytes[start..end];
    }

    fn toRunRecord(self: TextPostingRunChunkRecord, term_bytes: []const u8) !TextPostingRunRecord {
        return TextPostingRunRecord{
            .term_sort_prefix = self.term_sort_prefix,
            .doc_id = self.doc_id,
            .text_freq = self.text_freq,
            .kind_freq = self.kind_freq,
            .term_len = self.term_len,
            .term_bytes = blk: {
                var bytes: [default_max_token_bytes]u8 = undefined;
                const term_slice = try self.term(term_bytes);
                @memcpy(bytes[0..term_slice.len], term_slice);
                break :blk bytes;
            },
        };
    }
};

const TextPostingRunFormat = enum {
    front_coded_terms_fixed_posting,
    front_coded_terms_delta_posting,
};

fn textPostingRunRecordOrderPtr(lhs: *const TextPostingRunRecord, rhs: *const TextPostingRunRecord) std.math.Order {
    if (lhs.term_sort_prefix != rhs.term_sort_prefix) return std.math.order(lhs.term_sort_prefix, rhs.term_sort_prefix);
    const lhs_term_len: usize = lhs.term_len;
    const rhs_term_len: usize = rhs.term_len;
    const shared_prefix_len = @min(@min(lhs_term_len, rhs_term_len), @sizeOf(u64));
    if (shared_prefix_len == lhs_term_len or shared_prefix_len == rhs_term_len) {
        if (lhs_term_len != rhs_term_len) return std.math.order(lhs_term_len, rhs_term_len);
        return std.math.order(lhs.doc_id, rhs.doc_id);
    }
    const term_order = std.mem.order(
        u8,
        lhs.term_bytes[shared_prefix_len..lhs_term_len],
        rhs.term_bytes[shared_prefix_len..rhs_term_len],
    );
    if (term_order != .eq) return term_order;
    return std.math.order(lhs.doc_id, rhs.doc_id);
}

fn textPostingRunRecordOrder(lhs: TextPostingRunRecord, rhs: TextPostingRunRecord) std.math.Order {
    return textPostingRunRecordOrderPtr(&lhs, &rhs);
}

fn textPostingRunRecordLessThan(_: void, lhs: TextPostingRunRecord, rhs: TextPostingRunRecord) bool {
    return textPostingRunRecordOrder(lhs, rhs) == .lt;
}

fn textPostingRunSameTermAndDoc(lhs: TextPostingRunRecord, rhs: TextPostingRunRecord) bool {
    return lhs.term_sort_prefix == rhs.term_sort_prefix and lhs.doc_id == rhs.doc_id and std.mem.eql(u8, lhs.term(), rhs.term());
}

const TextPostingRunChunkSortContext = struct {
    records: []const TextPostingRunChunkRecord,
    term_bytes: []const u8,
};

fn textPostingRunChunkIndexLessThan(context: TextPostingRunChunkSortContext, lhs_index: u32, rhs_index: u32) bool {
    const lhs = context.records[lhs_index];
    const rhs = context.records[rhs_index];
    return textPostingRunChunkRecordLessThan(context.term_bytes, lhs, rhs);
}

fn textPostingRunChunkRecordLessThan(term_bytes: []const u8, lhs: TextPostingRunChunkRecord, rhs: TextPostingRunChunkRecord) bool {
    if (lhs.term_sort_prefix != rhs.term_sort_prefix) return lhs.term_sort_prefix < rhs.term_sort_prefix;
    const lhs_term_len: usize = lhs.term_len;
    const rhs_term_len: usize = rhs.term_len;
    const shared_prefix_len = @min(@min(lhs_term_len, rhs_term_len), @sizeOf(u64));
    if (shared_prefix_len == lhs_term_len or shared_prefix_len == rhs_term_len) {
        if (lhs_term_len != rhs_term_len) return lhs_term_len < rhs_term_len;
        return lhs.doc_id < rhs.doc_id;
    }
    const lhs_term = lhs.termAssumeValid(term_bytes);
    const rhs_term = rhs.termAssumeValid(term_bytes);
    const term_order = std.mem.order(u8, lhs_term[shared_prefix_len..], rhs_term[shared_prefix_len..]);
    if (term_order != .eq) return term_order == .lt;
    return lhs.doc_id < rhs.doc_id;
}

pub const TextPostingBlocksHeader = search_acceleration_format.TextPostingBlocksHeader;
pub const TextPostingBlockRecord = search_acceleration_format.TextPostingBlockRecord;
const encodeTextPostingBlocksHeader = search_acceleration_format.Internal.encodeBlocksHeader;
const decodeTextPostingBlocksHeader = search_acceleration_format.Internal.decodeBlocksHeader;
const encodeTextPostingBlockRecord = search_acceleration_format.Internal.encodeBlockRecord;
const decodeTextPostingBlockRecord = search_acceleration_format.Internal.decodeBlockRecord;
const textPostingBlockRecordFromStats = search_acceleration_format.Internal.blockRecordFromStats;
const textPostingBlockRecordConservativelyMatches = search_acceleration_format.Internal.blockRecordConservativelyMatches;
const PersistentBlockScoreBounds = search_acceleration_format.Internal.PersistentBlockScoreBounds;
const quantizePersistentBlockScoreBounds = search_acceleration_format.Internal.quantizeBlockScoreBounds;
const encodePersistentBlockOrdinal = search_acceleration_format.Internal.encodeBlockOrdinal;
const decodePersistentBlockOrdinal = search_acceleration_format.Internal.decodeBlockOrdinal;

pub const TextPostingBlockImpactsHeader = search_acceleration_format.TextPostingBlockImpactsHeader;
pub const TextTermTopHitsHeader = search_acceleration_format.TextTermTopHitsHeader;
pub const TextTermTopHitTermRecord = search_acceleration_format.TextTermTopHitTermRecord;
pub const TextTermTopHitRecord = search_acceleration_format.TextTermTopHitRecord;
const encodeTextPostingBlockImpactsHeader = search_acceleration_format.Internal.encodeImpactsHeader;
const decodeTextPostingBlockImpactsHeader = search_acceleration_format.Internal.decodeImpactsHeader;
const encodeTextTermTopHitsHeader = search_acceleration_format.Internal.encodeTopHitsHeader;
const decodeTextTermTopHitsHeader = search_acceleration_format.Internal.decodeTopHitsHeader;
const encodeTextTermTopHitTermRecord = search_acceleration_format.Internal.encodeTopHitTermRecord;
const decodeTextTermTopHitTermRecord = search_acceleration_format.Internal.decodeTopHitTermRecord;
const encodeTextTermTopHitRecord = search_acceleration_format.Internal.encodeTopHitRecord;
const decodeTextTermTopHitRecord = search_acceleration_format.Internal.decodeTopHitRecord;

const TextTopHitDocStats = struct {
    doc_id: u64,
    node_id: u64,
    doc_len: f32,
};

const TextDocRankEntry = struct {
    node_id: u64,
    doc_id: u32,
    text_tokens: u32,

    pub fn init(doc: TextDocRecord) !TextDocRankEntry {
        if (doc.doc_id == 0 or doc.doc_id > persistent_posting_max_doc_id) return error.RecordTooLarge;
        if (doc.node_id == 0 or doc.node_id == std.math.maxInt(u64)) return error.InvalidRecord;
        if (doc.text_tokens > persistent_doc_max_field_tokens) return error.RecordTooLarge;
        return .{
            .node_id = doc.node_id,
            .doc_id = @intCast(doc.doc_id),
            .text_tokens = doc.text_tokens,
        };
    }

    pub fn docLen(self: TextDocRankEntry) f32 {
        return persistentDocLenFromTextTokens(self.text_tokens);
    }
};

const TextDocsFileView = struct {
    io: std.Io,
    file: std.Io.File,
    size: u64,
    header: TextDocsHeader,
    map: ?std.Io.File.MemoryMap = null,

    fn open(store: storage_mod.Store, path: []const u8) !TextDocsFileView {
        var file = try std.Io.Dir.cwd().openFile(store.io, path, .{});
        errdefer file.close(store.io);

        const stat = try file.stat(store.io);
        if (stat.kind != .file) return error.IsDir;
        var header_bytes: [TextDocsHeader.encoded_len]u8 = undefined;
        const header_n = try file.readPositionalAll(store.io, &header_bytes, 0);
        if (header_n != header_bytes.len) return error.InvalidRecord;
        const header = try TextDocsHeader.decode(&header_bytes);
        const len = std.math.cast(usize, stat.size) orelse return error.RecordTooLarge;
        const map = if (len == 0) null else read_only_memory_map.create(store.io, file, len) catch null;

        return .{
            .io = store.io,
            .file = file,
            .size = stat.size,
            .header = header,
            .map = map,
        };
    }

    pub fn deinit(self: *TextDocsFileView) void {
        if (self.map) |*map| map.destroy(self.io);
        self.file.close(self.io);
    }

    fn mappedBytesAt(self: *TextDocsFileView, comptime len: usize, offset: u64) !?[]const u8 {
        const end = std.math.add(u64, offset, len) catch return error.InvalidRecord;
        if (end > self.size) return error.InvalidRecord;
        const map = self.map orelse return null;
        const start = std.math.cast(usize, offset) orelse return error.RecordTooLarge;
        return map.memory[start .. start + len];
    }

    fn mappedRange(self: *TextDocsFileView, offset: u64, byte_len: u64) !?[]const u8 {
        const end = std.math.add(u64, offset, byte_len) catch return error.InvalidRecord;
        if (end > self.size) return error.InvalidRecord;
        const map = self.map orelse return null;
        const start = std.math.cast(usize, offset) orelse return error.RecordTooLarge;
        const len = std.math.cast(usize, byte_len) orelse return error.RecordTooLarge;
        return map.memory[start .. start + len];
    }

    fn readAt(self: *TextDocsFileView, comptime len: usize, offset: u64) ![len]u8 {
        const end = std.math.add(u64, offset, len) catch return error.InvalidRecord;
        if (end > self.size) return error.InvalidRecord;
        var bytes: [len]u8 = undefined;
        const n = try self.file.readPositionalAll(self.io, &bytes, offset);
        if (n != bytes.len) return error.InvalidRecord;
        return bytes;
    }

    fn readHeader(self: *TextDocsFileView) !TextDocsHeader {
        return self.header;
    }

    pub fn readDocAt(self: *TextDocsFileView, index: u64) !TextDocRecord {
        if (index >= self.header.doc_count) return error.InvalidRecord;
        const offset = try textDocRecordOffsetForHeader(self.header, index);
        const record_len = self.header.recordLen();
        const doc_id = try nextPersistentTextDocId(index);
        if (try self.mappedRange(offset, record_len)) |bytes| {
            const overflow_node_id = try self.readOverflowNodeIdForDoc(doc_id);
            return try TextDocRecord.decodeForHeader(bytes, self.header, index, overflow_node_id);
        }
        var bytes: [TextDocRecord.encoded_len]u8 = undefined;
        const n = try self.file.readPositionalAll(self.io, bytes[0..record_len], offset);
        if (n != record_len) return error.InvalidRecord;
        const overflow_node_id = try self.readOverflowNodeIdForDoc(doc_id);
        return try TextDocRecord.decodeForHeader(bytes[0..record_len], self.header, index, overflow_node_id);
    }

    pub fn readTopHitDocStatsAt(self: *TextDocsFileView, index: u64) !TextTopHitDocStats {
        if (index >= self.header.doc_count) return error.InvalidRecord;
        const doc_id = try nextPersistentTextDocId(index);
        if (self.header.hasDenseUniformRecords()) {
            const offset = try textDocRecordOffsetForHeader(self.header, index);
            const text_tokens = if (try self.mappedBytesAt(TextDocRecord.dense_uniform_encoded_len, offset)) |bytes|
                std.mem.readInt(u16, bytes[0..2], .little)
            else blk: {
                const read_bytes = try self.readAt(TextDocRecord.dense_uniform_encoded_len, offset);
                break :blk std.mem.readInt(u16, read_bytes[0..2], .little);
            };
            const node_id = std.math.add(u64, self.header.dense_node_id_base, index) catch return error.InvalidRecord;
            if (node_id == 0 or node_id > persistent_doc_node_id_inline_max) return error.InvalidRecord;
            return .{
                .doc_id = doc_id,
                .node_id = node_id,
                .doc_len = persistentDocLenFromTextTokens(text_tokens),
            };
        }

        const doc = try self.readDocAt(index);
        return .{
            .doc_id = doc.doc_id,
            .node_id = doc.node_id,
            .doc_len = persistentDocLen(doc),
        };
    }

    fn readOverflowRecordAt(self: *TextDocsFileView, index: u64) !TextDocNodeIdOverflowRecord {
        const offset = try textDocNodeIdOverflowRecordOffsetForHeader(self.header, index);
        if (try self.mappedBytesAt(TextDocNodeIdOverflowRecord.encoded_len, offset)) |bytes| {
            return try TextDocNodeIdOverflowRecord.decodeBytes(bytes);
        }
        const bytes = try self.readAt(TextDocNodeIdOverflowRecord.encoded_len, offset);
        return try TextDocNodeIdOverflowRecord.decode(&bytes);
    }

    fn readOverflowNodeIdForDoc(self: *TextDocsFileView, doc_id: u64) !?u64 {
        var left: u64 = 0;
        var right = self.header.node_id_overflow_count;
        while (left < right) {
            const mid = left + (right - left) / 2;
            const record = try self.readOverflowRecordAt(mid);
            if (record.doc_id == doc_id) return record.node_id;
            if (record.doc_id < doc_id) {
                left = mid + 1;
            } else {
                right = mid;
            }
        }
        return null;
    }
};

const TextTermsFileView = struct {
    io: std.Io,
    file: std.Io.File,
    size: u64,
    map: ?std.Io.File.MemoryMap = null,

    fn open(store: storage_mod.Store, path: []const u8) !TextTermsFileView {
        var file = try std.Io.Dir.cwd().openFile(store.io, path, .{});
        errdefer file.close(store.io);

        const stat = try file.stat(store.io);
        if (stat.kind != .file) return error.IsDir;
        const len = std.math.cast(usize, stat.size) orelse return error.RecordTooLarge;
        const map = if (len == 0) null else read_only_memory_map.create(store.io, file, len) catch null;

        return .{
            .io = store.io,
            .file = file,
            .size = stat.size,
            .map = map,
        };
    }

    fn deinit(self: *TextTermsFileView) void {
        if (self.map) |*map| map.destroy(self.io);
        self.file.close(self.io);
    }

    fn mappedBytesAt(self: *TextTermsFileView, comptime len: usize, offset: u64) !?[]const u8 {
        const end = std.math.add(u64, offset, len) catch return error.InvalidRecord;
        if (end > self.size) return error.InvalidRecord;
        const map = self.map orelse return null;
        const start = std.math.cast(usize, offset) orelse return error.RecordTooLarge;
        return map.memory[start .. start + len];
    }

    fn mappedRange(self: *TextTermsFileView, offset: u64, byte_len: u64) !?[]const u8 {
        const end = std.math.add(u64, offset, byte_len) catch return error.InvalidRecord;
        if (end > self.size) return error.InvalidRecord;
        const map = self.map orelse return null;
        const start = std.math.cast(usize, offset) orelse return error.RecordTooLarge;
        const len = std.math.cast(usize, byte_len) orelse return error.RecordTooLarge;
        return map.memory[start .. start + len];
    }

    fn readAt(self: *TextTermsFileView, comptime len: usize, offset: u64) ![len]u8 {
        const end = std.math.add(u64, offset, len) catch return error.InvalidRecord;
        if (end > self.size) return error.InvalidRecord;
        var bytes: [len]u8 = undefined;
        const n = try self.file.readPositionalAll(self.io, &bytes, offset);
        if (n != bytes.len) return error.InvalidRecord;
        return bytes;
    }

    fn readByteAt(self: *TextTermsFileView, offset: u64) !u8 {
        if (try self.mappedBytesAt(1, offset)) |bytes| return bytes[0];
        return (try self.readAt(1, offset))[0];
    }

    fn readHeader(self: *TextTermsFileView) !TextTermsHeader {
        if (try self.mappedBytesAt(TextTermsHeader.encoded_len, 0)) |bytes| {
            return try decodeTextTermsHeader(bytes);
        }
        const bytes = try self.readAt(TextTermsHeader.encoded_len, 0);
        return try decodeTextTermsHeader(&bytes);
    }

    fn readPackedEntryAt(self: *TextTermsFileView, index: u64) !TextTermEntry {
        const offset = try textTermEntryOffset(index);
        if (try self.mappedBytesAt(TextTermEntry.encoded_len, offset)) |bytes| {
            return try decodeTextTermEntry(bytes);
        }
        const bytes = try self.readAt(TextTermEntry.encoded_len, offset);
        return try decodeTextTermEntry(&bytes);
    }

    fn readTermExceptionRecord(self: *TextTermsFileView, header: TextTermsHeader, exception_index: u64) !TextTermExceptionRecord {
        if (exception_index >= header.term_exception_count) return error.InvalidRecord;
        const offset = try textTermExceptionRecordOffset(header.term_count, header.term_bytes, exception_index);
        if (try self.mappedBytesAt(TextTermExceptionRecord.encoded_len, offset)) |bytes| {
            var copy: [TextTermExceptionRecord.encoded_len]u8 = undefined;
            @memcpy(&copy, bytes);
            return try decodeTextTermExceptionRecord(&copy);
        }
        const bytes = try self.readAt(TextTermExceptionRecord.encoded_len, offset);
        return try decodeTextTermExceptionRecord(&bytes);
    }

    fn readTermExceptionRankCheckpoint(self: *TextTermsFileView, header: TextTermsHeader, checkpoint_index: u64) !u64 {
        const offset = try textTermExceptionRankCheckpointOffset(header.term_count, header.term_bytes, checkpoint_index);
        if (try self.mappedBytesAt(4, offset)) |bytes| {
            return std.mem.readInt(u32, bytes[0..4], .little);
        }
        const bytes = try self.readAt(4, offset);
        return std.mem.readInt(u32, bytes[0..4], .little);
    }

    fn readTermExceptionMembershipByte(self: *TextTermsFileView, header: TextTermsHeader, byte_index: u64) !u8 {
        const offset = try textTermExceptionMembershipByteOffset(header.term_count, header.term_bytes, byte_index);
        return try self.readByteAt(offset);
    }

    fn readExceptionForTerm(self: *TextTermsFileView, header: TextTermsHeader, index: u64, packed_entry: TextTermEntry) !TextTermEntry {
        const resolved = try self.resolveExceptionForTerm(header, index, packed_entry);
        if (resolved.entry) |entry| return entry;
        return error.InvalidRecord;
    }

    const ExceptionLookup = struct {
        entry: ?TextTermEntry,
        rank: u64,
    };

    fn resolveExceptionForTerm(self: *TextTermsFileView, header: TextTermsHeader, index: u64, packed_entry: TextTermEntry) !ExceptionLookup {
        if (index >= header.term_count) return error.InvalidRecord;
        const checkpoint_index = index / persistent_term_exception_rank_checkpoint_terms;
        const checkpoint_term = checkpoint_index * persistent_term_exception_rank_checkpoint_terms;
        var rank = try self.readTermExceptionRankCheckpoint(header, checkpoint_index);
        if (rank > header.term_exception_count) return error.InvalidRecord;
        var term = checkpoint_term;
        var byte_index = term / 8;
        var bits = if (term < index) try self.readTermExceptionMembershipByte(header, byte_index) else 0;
        while (term < index) {
            const bit_offset: u3 = @intCast(term & 7);
            if ((bits & (@as(u8, 1) << bit_offset)) != 0) rank += 1;
            term += 1;
            if (term < index and (term & 7) == 0) {
                byte_index += 1;
                bits = try self.readTermExceptionMembershipByte(header, byte_index);
            }
        }
        if (rank > header.term_exception_count) return error.InvalidRecord;
        const member_byte = try self.readTermExceptionMembershipByte(header, index / 8);
        const member_bit: u3 = @intCast(index & 7);
        if ((member_byte & (@as(u8, 1) << member_bit)) == 0) return .{ .entry = null, .rank = rank };
        if (rank >= header.term_exception_count) return error.InvalidRecord;
        const record = try self.readTermExceptionRecord(header, rank);
        const entry = TextTermEntry{
            .term_len = packed_entry.term_len,
            .doc_freq = record.doc_freq,
            .postings_offset = record.postings_offset,
            .postings_count = record.doc_freq,
            .front_prefix_len = packed_entry.front_prefix_len,
            .postings_offset_is_plain = record.postings_offset_is_plain,
            .postings_offset_is_dense_freq_stream = record.postings_offset_is_dense_freq_stream,
        };
        if (!termEntryPostingPayloadValid(entry)) return error.InvalidRecord;
        return .{ .entry = entry, .rank = rank };
    }

    fn readSingletonCheckpoint(self: *TextTermsFileView, header: TextTermsHeader, checkpoint_index: u64) !TextTermSingletonPayloadCheckpoint {
        const offset = try textTermSingletonPayloadCheckpointOffset(header.term_count, header.term_bytes, header.term_exception_count, checkpoint_index);
        if (try self.mappedBytesAt(TextTermSingletonPayloadCheckpoint.encoded_len, offset)) |bytes| {
            var copy: [TextTermSingletonPayloadCheckpoint.encoded_len]u8 = undefined;
            @memcpy(&copy, bytes);
            return try decodeTextTermSingletonPayloadCheckpoint(&copy);
        }
        const bytes = try self.readAt(TextTermSingletonPayloadCheckpoint.encoded_len, offset);
        return try decodeTextTermSingletonPayloadCheckpoint(&bytes);
    }

    fn readSingletonPayloadAt(self: *TextTermsFileView, header: TextTermsHeader, singleton_ordinal: u64) !u32 {
        const singleton_count = try textTermSingletonPayloadCount(header.term_count, header.term_exception_count);
        if (singleton_ordinal >= singleton_count) return error.InvalidRecord;
        const checkpoint_index = singleton_ordinal / persistent_term_singleton_payload_checkpoint_terms;
        const checkpoint_ordinal = checkpoint_index * persistent_term_singleton_payload_checkpoint_terms;
        const checkpoint = try self.readSingletonCheckpoint(header, checkpoint_index);
        if (checkpoint.stream_offset > header.singleton_payload_bytes) return error.InvalidRecord;
        const stream_base = try textTermSingletonPayloadStreamOffset(header.term_count, header.term_bytes, header.term_exception_count);
        var cursor = std.math.add(u64, stream_base, checkpoint.stream_offset) catch return error.InvalidRecord;
        const stream_end = std.math.add(u64, stream_base, header.singleton_payload_bytes) catch return error.InvalidRecord;
        var payload = checkpoint.previous_payload;
        var ordinal = checkpoint_ordinal;
        while (ordinal <= singleton_ordinal) : (ordinal += 1) {
            const encoded_delta = try decodePersistentVarintFromTermsFile(self, &cursor, stream_end);
            payload = try applySingletonPayloadDelta(payload, encoded_delta);
        }
        _ = try decodeInlineSingletonPostingPayload(payload);
        return payload;
    }

    fn readEntryAt(self: *TextTermsFileView, header: TextTermsHeader, index: u64) !TextTermEntry {
        const entry = try self.readPackedEntryAt(index);
        const exception = try self.resolveExceptionForTerm(header, index, entry);
        if (exception.entry) |resolved| return resolved;
        if (index < exception.rank) return error.InvalidRecord;
        const singleton_ordinal = index - exception.rank;
        const payload = try self.readSingletonPayloadAt(header, singleton_ordinal);
        return .{
            .term_len = entry.term_len,
            .doc_freq = 1,
            .postings_offset = payload,
            .postings_count = 1,
            .front_prefix_len = entry.front_prefix_len,
        };
    }

    fn readTermByteOffsetCheckpoint(self: *TextTermsFileView, header: TextTermsHeader, checkpoint_index: u64) !u64 {
        const offset = try textTermByteOffsetCheckpointOffset(header.term_count, header.term_bytes, checkpoint_index);
        if (try self.mappedBytesAt(4, offset)) |bytes| {
            return std.mem.readInt(u32, bytes[0..4], .little);
        }
        const bytes = try self.readAt(4, offset);
        return std.mem.readInt(u32, bytes[0..4], .little);
    }

    fn termByteOffsetForIndex(self: *TextTermsFileView, header: TextTermsHeader, index: u64) !u64 {
        if (index >= header.term_count) return error.InvalidRecord;
        const checkpoint_index = index / persistent_term_byte_offset_checkpoint_terms;
        const checkpoint_term = checkpoint_index * persistent_term_byte_offset_checkpoint_terms;
        var term_offset = try self.readTermByteOffsetCheckpoint(header, checkpoint_index);
        if (term_offset > header.term_bytes) return error.InvalidRecord;
        var previous_term_len: usize = 0;
        var pos = checkpoint_term;
        while (pos < index) : (pos += 1) {
            const entry = try self.readEntryAt(header, pos);
            const prefix_len = try self.readFrontCodedPrefixLen(header, pos, term_offset, previous_term_len, entry);
            const encoded_len = try frontCodedEncodedLen(entry, prefix_len);
            if (encoded_len > header.term_bytes - term_offset) return error.InvalidRecord;
            term_offset = std.math.add(u64, term_offset, encoded_len) catch return error.RecordTooLarge;
            previous_term_len = std.math.cast(usize, entry.term_len) orelse return error.RecordTooLarge;
        }
        return term_offset;
    }

    fn termEntryMatches(self: *TextTermsFileView, header: TextTermsHeader, index: u64, entry: TextTermEntry, term: []const u8) !bool {
        if (entry.term_len != term.len) return false;
        return (try self.termEntryOrder(header, index, entry, term)) == .eq;
    }

    fn termEntryOrder(self: *TextTermsFileView, header: TextTermsHeader, index: u64, entry: TextTermEntry, term: []const u8) !std.math.Order {
        var buf: [default_max_token_bytes]u8 = undefined;
        const bytes = try self.termEntryBytesAt(header, index, entry, &buf);
        return std.mem.order(u8, bytes, term);
    }

    fn termEntryEntryOrder(self: *TextTermsFileView, header: TextTermsHeader, lhs_index: u64, lhs: TextTermEntry, rhs_index: u64, rhs: TextTermEntry) !std.math.Order {
        var lhs_buf: [default_max_token_bytes]u8 = undefined;
        var rhs_buf: [default_max_token_bytes]u8 = undefined;
        const lhs_bytes = try self.termEntryBytesAt(header, lhs_index, lhs, &lhs_buf);
        const rhs_bytes = try self.termEntryBytesAt(header, rhs_index, rhs, &rhs_buf);
        return std.mem.order(u8, lhs_bytes, rhs_bytes);
    }

    fn termEntryBytesAt(self: *TextTermsFileView, header: TextTermsHeader, index: u64, entry: TextTermEntry, buf: *[default_max_token_bytes]u8) ![]const u8 {
        const bytes_offset = try textTermsBytesOffset(header.term_count);
        const checkpoint_index = index / persistent_term_byte_offset_checkpoint_terms;
        const checkpoint_term = checkpoint_index * persistent_term_byte_offset_checkpoint_terms;
        var encoded_offset = try self.readTermByteOffsetCheckpoint(header, checkpoint_index);
        if (encoded_offset > header.term_bytes) return error.InvalidRecord;

        var previous: [default_max_token_bytes]u8 = undefined;
        var current: [default_max_token_bytes]u8 = undefined;
        var previous_len: usize = 0;
        var pos = checkpoint_term;
        while (pos <= index) : (pos += 1) {
            const current_entry = if (pos == index) entry else try self.readEntryAt(header, pos);
            const current_len = std.math.cast(usize, current_entry.term_len) orelse return error.RecordTooLarge;
            const prefix_len = try self.readFrontCodedPrefixLen(header, pos, encoded_offset, previous_len, current_entry);
            const encoded_absolute_offset = std.math.add(u64, bytes_offset, encoded_offset) catch return error.RecordTooLarge;
            const prefix_bytes = frontCodedPrefixByteCount(current_entry, prefix_len);
            const suffix_offset = std.math.add(u64, encoded_absolute_offset, prefix_bytes) catch return error.RecordTooLarge;
            const encoded_len = try frontCodedEncodedLen(current_entry, prefix_len);
            if (encoded_len > header.term_bytes - encoded_offset) return error.InvalidRecord;

            const out = if (pos == index) buf else &current;
            @memcpy(out[0..prefix_len], previous[0..prefix_len]);
            try self.readTermSuffixInto(suffix_offset, out[prefix_len..current_len]);
            if (pos == index) return buf[0..current_len];

            @memcpy(previous[0..current_len], current[0..current_len]);
            previous_len = current_len;
            encoded_offset = std.math.add(u64, encoded_offset, encoded_len) catch return error.RecordTooLarge;
            if (encoded_offset > header.term_bytes) return error.InvalidRecord;
        }
        return error.InvalidRecord;
    }

    fn readFrontCodedPrefixLen(self: *TextTermsFileView, header: TextTermsHeader, index: u64, encoded_offset: u64, previous_term_len: usize, entry: TextTermEntry) !u8 {
        if (textTermEntryFrontPrefixLen(entry)) |prefix_len| {
            if (index % persistent_term_byte_offset_checkpoint_terms == 0 and prefix_len != 0) return error.InvalidRecord;
            if (prefix_len > previous_term_len or prefix_len > entry.term_len) return error.InvalidRecord;
            return prefix_len;
        }
        if (encoded_offset >= header.term_bytes) return error.InvalidRecord;
        const bytes_offset = try textTermsBytesOffset(header.term_count);
        const prefix_offset = std.math.add(u64, bytes_offset, encoded_offset) catch return error.RecordTooLarge;
        const prefix_len = if (try self.mappedBytesAt(1, prefix_offset)) |bytes| bytes[0] else (try self.readAt(1, prefix_offset))[0];
        if (index % persistent_term_byte_offset_checkpoint_terms == 0 and prefix_len != 0) return error.InvalidRecord;
        if (prefix_len > previous_term_len or prefix_len > entry.term_len) return error.InvalidRecord;
        return prefix_len;
    }

    fn readTermSuffixInto(self: *TextTermsFileView, offset: u64, out: []u8) !void {
        if (out.len == 0) return;
        if (try self.mappedRange(offset, out.len)) |bytes| {
            @memcpy(out, bytes);
            return;
        }
        const n = try self.file.readPositionalAll(self.io, out, offset);
        if (n != out.len) return error.InvalidRecord;
    }
};

const TextPostingsFileView = struct {
    io: std.Io,
    file: std.Io.File,
    size: u64,
    map: ?std.Io.File.MemoryMap = null,

    pub fn open(store: storage_mod.Store, path: []const u8) !TextPostingsFileView {
        var file = try std.Io.Dir.cwd().openFile(store.io, path, .{});
        errdefer file.close(store.io);

        const stat = try file.stat(store.io);
        if (stat.kind != .file) return error.IsDir;
        const len = std.math.cast(usize, stat.size) orelse return error.RecordTooLarge;
        const map = if (len == 0) null else read_only_memory_map.create(store.io, file, len) catch null;

        return .{
            .io = store.io,
            .file = file,
            .size = stat.size,
            .map = map,
        };
    }

    pub fn deinit(self: *TextPostingsFileView) void {
        if (self.map) |*map| map.destroy(self.io);
        self.file.close(self.io);
    }

    fn mappedBytesAt(self: *TextPostingsFileView, comptime len: usize, offset: u64) !?[]const u8 {
        const end = std.math.add(u64, offset, len) catch return error.InvalidRecord;
        if (end > self.size) return error.InvalidRecord;
        const map = self.map orelse return null;
        const start = std.math.cast(usize, offset) orelse return error.RecordTooLarge;
        return map.memory[start .. start + len];
    }

    fn mappedBodyFromOffset(self: *TextPostingsFileView, posting_offset: u64) !?[]const u8 {
        const offset = try textPostingBodyOffset(posting_offset);
        if (offset > self.size) return error.InvalidRecord;
        const map = self.map orelse return null;
        const start = std.math.cast(usize, offset) orelse return error.RecordTooLarge;
        return map.memory[start..];
    }

    fn readAt(self: *TextPostingsFileView, comptime len: usize, offset: u64) ![len]u8 {
        const end = std.math.add(u64, offset, len) catch return error.InvalidRecord;
        if (end > self.size) return error.InvalidRecord;
        var bytes: [len]u8 = undefined;
        const n = try self.file.readPositionalAll(self.io, &bytes, offset);
        if (n != bytes.len) return error.InvalidRecord;
        return bytes;
    }

    pub fn readHeader(self: *TextPostingsFileView) !TextPostingsHeader {
        if (try self.mappedBytesAt(TextPostingsHeader.encoded_len, 0)) |bytes| {
            return try decodeTextPostingsHeader(bytes);
        }
        const bytes = try self.readAt(TextPostingsHeader.encoded_len, 0);
        return try decodeTextPostingsHeader(&bytes);
    }

    fn readByteAt(self: *TextPostingsFileView, offset: u64) !u8 {
        if (try self.mappedBytesAt(1, offset)) |bytes| return bytes[0];
        const bytes = try self.readAt(1, offset);
        return bytes[0];
    }
};

const TextPostingBlocksFileView = struct {
    io: std.Io,
    file: std.Io.File,
    size: u64,
    map: ?std.Io.File.MemoryMap = null,

    fn open(store: storage_mod.Store, path: []const u8) !TextPostingBlocksFileView {
        var file = try std.Io.Dir.cwd().openFile(store.io, path, .{});
        errdefer file.close(store.io);

        const stat = try file.stat(store.io);
        if (stat.kind != .file) return error.IsDir;
        const len = std.math.cast(usize, stat.size) orelse return error.RecordTooLarge;
        const map = if (len == 0) null else read_only_memory_map.create(store.io, file, len) catch null;

        return .{
            .io = store.io,
            .file = file,
            .size = stat.size,
            .map = map,
        };
    }

    fn deinit(self: *TextPostingBlocksFileView) void {
        if (self.map) |*map| map.destroy(self.io);
        self.file.close(self.io);
    }

    fn mappedBytesAt(self: *TextPostingBlocksFileView, comptime len: usize, offset: u64) !?[]const u8 {
        const end = std.math.add(u64, offset, len) catch return error.InvalidRecord;
        if (end > self.size) return error.InvalidRecord;
        const map = self.map orelse return null;
        const start = std.math.cast(usize, offset) orelse return error.RecordTooLarge;
        return map.memory[start .. start + len];
    }

    fn readAt(self: *TextPostingBlocksFileView, comptime len: usize, offset: u64) ![len]u8 {
        const end = std.math.add(u64, offset, len) catch return error.InvalidRecord;
        if (end > self.size) return error.InvalidRecord;
        var bytes: [len]u8 = undefined;
        const n = try self.file.readPositionalAll(self.io, &bytes, offset);
        if (n != bytes.len) return error.InvalidRecord;
        return bytes;
    }

    fn readHeader(self: *TextPostingBlocksFileView) !TextPostingBlocksHeader {
        if (try self.mappedBytesAt(TextPostingBlocksHeader.encoded_len, 0)) |bytes| {
            return try decodeTextPostingBlocksHeader(bytes);
        }
        const bytes = try self.readAt(TextPostingBlocksHeader.encoded_len, 0);
        return try decodeTextPostingBlocksHeader(&bytes);
    }

    fn readTermBlockOffsetCheckpoint(self: *TextPostingBlocksFileView, block_count: u64, checkpoint_index: u64) !u64 {
        const offset = try textPostingBlockCheckpointOffset(block_count, checkpoint_index);
        if (try self.mappedBytesAt(persistent_posting_block_ordinal_len, offset)) |bytes| {
            return try decodePersistentBlockOrdinal(bytes);
        }
        const bytes = try self.readAt(persistent_posting_block_ordinal_len, offset);
        return try decodePersistentBlockOrdinal(&bytes);
    }

    fn readBlockByteOffsetCheckpoint(self: *TextPostingBlocksFileView, term_count: u64, block_count: u64, checkpoint_index: u64) !u64 {
        const offset = try textPostingBlockByteOffsetCheckpointOffset(term_count, block_count, checkpoint_index);
        if (try self.mappedBytesAt(4, offset)) |bytes| {
            return std.mem.readInt(u32, bytes[0..4], .little);
        }
        const bytes = try self.readAt(4, offset);
        return std.mem.readInt(u32, &bytes, .little);
    }

    pub fn readBlockRecordAt(self: *TextPostingBlocksFileView, term_count: u64, index: u64) !TextPostingBlockRecord {
        const offset = try textPostingBlockRecordOffset(term_count, index);
        if (try self.mappedBytesAt(TextPostingBlockRecord.encoded_len, offset)) |bytes| {
            return try decodeTextPostingBlockRecord(bytes);
        }
        const bytes = try self.readAt(TextPostingBlockRecord.encoded_len, offset);
        return try decodeTextPostingBlockRecord(&bytes);
    }
};

const TextPostingBlockImpactsFileView = struct {
    io: std.Io,
    file: std.Io.File,
    size: u64,
    map: ?std.Io.File.MemoryMap = null,

    fn open(store: storage_mod.Store, path: []const u8) !TextPostingBlockImpactsFileView {
        var file = try std.Io.Dir.cwd().openFile(store.io, path, .{});
        errdefer file.close(store.io);

        const stat = try file.stat(store.io);
        if (stat.kind != .file) return error.IsDir;
        const len = std.math.cast(usize, stat.size) orelse return error.RecordTooLarge;
        const map = if (len == 0) null else read_only_memory_map.create(store.io, file, len) catch null;

        return .{
            .io = store.io,
            .file = file,
            .size = stat.size,
            .map = map,
        };
    }

    fn deinit(self: *TextPostingBlockImpactsFileView) void {
        if (self.map) |*map| map.destroy(self.io);
        self.file.close(self.io);
    }

    fn mappedBytesAt(self: *TextPostingBlockImpactsFileView, comptime len: usize, offset: u64) !?[]const u8 {
        const end = std.math.add(u64, offset, len) catch return error.InvalidRecord;
        if (end > self.size) return error.InvalidRecord;
        const map = self.map orelse return null;
        const start = std.math.cast(usize, offset) orelse return error.RecordTooLarge;
        return map.memory[start .. start + len];
    }

    fn readAt(self: *TextPostingBlockImpactsFileView, comptime len: usize, offset: u64) ![len]u8 {
        const end = std.math.add(u64, offset, len) catch return error.InvalidRecord;
        if (end > self.size) return error.InvalidRecord;
        var bytes: [len]u8 = undefined;
        const n = try self.file.readPositionalAll(self.io, &bytes, offset);
        if (n != bytes.len) return error.InvalidRecord;
        return bytes;
    }

    fn readHeader(self: *TextPostingBlockImpactsFileView) !TextPostingBlockImpactsHeader {
        if (try self.mappedBytesAt(TextPostingBlockImpactsHeader.encoded_len, 0)) |bytes| {
            return try decodeTextPostingBlockImpactsHeader(bytes);
        }
        const bytes = try self.readAt(TextPostingBlockImpactsHeader.encoded_len, 0);
        return try decodeTextPostingBlockImpactsHeader(&bytes);
    }

    pub fn readBlockIndexAt(self: *TextPostingBlockImpactsFileView, term_count: u64, index: u64) !u64 {
        const offset = try textPostingBlockImpactRecordOffset(term_count, index);
        if (try self.mappedBytesAt(persistent_posting_block_ordinal_len, offset)) |bytes| {
            return try decodePersistentBlockOrdinal(bytes);
        }
        const bytes = try self.readAt(persistent_posting_block_ordinal_len, offset);
        return try decodePersistentBlockOrdinal(&bytes);
    }
};

const TextPostingSearchGuard = struct {
    options: TextSearchOptions,
    postings_scanned: *usize,
};

const TextPostingScanGuard = union(enum) {
    none,
    deadline: core.QueryDeadline,
    search: TextPostingSearchGuard,
};

/// Reading the clock costs more than decoding a posting, so checking the
/// deadline on every posting spends the scan's time in `clock_gettime`
/// (measured ~35% of a common-term query). One clock read per stride keeps
/// expiry precision in the tens of microseconds and the clock out of the hot
/// loop. `.immediate` deadlines still fire on the first posting, and the
/// posting budget stays exact — only the wall-clock probe is strided.
const deadline_check_stride = 256;
var deadline_check_tick: usize = 0;

fn deadlineExpiredStrided(deadline: core.QueryDeadline) bool {
    switch (deadline) {
        .none => return false,
        .immediate => return true,
        .at => {
            deadline_check_tick +%= 1;
            if (deadline_check_tick % deadline_check_stride != 0) return false;
            return deadline.expired();
        },
    }
}

fn guardBeforeTextPosting(guard: TextPostingScanGuard) !void {
    switch (guard) {
        .none => {},
        .deadline => |deadline| {
            if (deadlineExpiredStrided(deadline)) return core.Error.BudgetExceeded;
        },
        .search => |search_guard| {
            if (deadlineExpiredStrided(search_guard.options.deadline)) return core.Error.BudgetExceeded;
            try chargeTextPostingScan(search_guard.postings_scanned, search_guard.options);
        },
    }
}

fn scanPersistentPostingRange(
    view: *TextPostingsFileView,
    posting_offset: u64,
    posting_count: u64,
    doc_count: u64,
    guard: TextPostingScanGuard,
    context: anytype,
    comptime callback: fn (@TypeOf(context), TextPostingRecord, u64) anyerror!void,
) !u64 {
    var previous_doc_id: u64 = 0;
    var compressed_previous_doc_id: u64 = 0;
    if (try view.mappedBodyFromOffset(posting_offset)) |bytes| {
        var cursor: usize = 0;
        var i: u64 = 0;
        while (i < posting_count) : (i += 1) {
            try guardBeforeTextPosting(guard);
            if (i % persistent_posting_block_size == 0) compressed_previous_doc_id = 0;
            const posting = try decodeCompressedTextPostingFromBytes(bytes, &cursor, compressed_previous_doc_id);
            compressed_previous_doc_id = posting.doc_id;
            try validateScannedTextPosting(posting, &previous_doc_id, doc_count);
            try callback(context, posting, posting_count);
        }
        return std.math.add(u64, posting_offset, cursor) catch return error.RecordTooLarge;
    }

    var i: u64 = 0;
    var cursor = try textPostingBodyOffset(posting_offset);
    while (i < posting_count) : (i += 1) {
        try guardBeforeTextPosting(guard);
        if (i % persistent_posting_block_size == 0) compressed_previous_doc_id = 0;
        const posting = try decodeCompressedTextPostingFromFile(view, &cursor, compressed_previous_doc_id);
        compressed_previous_doc_id = posting.doc_id;
        try validateScannedTextPosting(posting, &previous_doc_id, doc_count);
        try callback(context, posting, posting_count);
    }
    return cursor - TextPostingsHeader.encoded_len;
}

fn scanPersistentTermPostings(
    view: *TextPostingsFileView,
    entry: TextTermEntry,
    doc_count: u64,
    guard: TextPostingScanGuard,
    context: anytype,
    comptime callback: fn (@TypeOf(context), TextPostingRecord, u64) anyerror!void,
) !u64 {
    if (termEntryHasInlinePosting(entry)) {
        const posting = try decodeInlineSingletonPostingPayload(entry.postings_offset);
        var previous_doc_id: u64 = 0;
        try guardBeforeTextPosting(guard);
        try validateScannedTextPosting(posting, &previous_doc_id, doc_count);
        try callback(context, posting, entry.postings_count);
        return entry.postings_offset;
    }
    if (termEntryVirtualAllDocsTextFreq(entry)) |text_freq| {
        if (entry.postings_count != doc_count) return error.InvalidRecord;
        var previous_doc_id: u64 = 0;
        var doc_id: u64 = 1;
        while (doc_id <= doc_count) : (doc_id += 1) {
            try guardBeforeTextPosting(guard);
            const posting = TextPostingRecord{ .doc_id = doc_id, .text_freq = text_freq, .kind_freq = 0 };
            try validateScannedTextPosting(posting, &previous_doc_id, doc_count);
            try callback(context, posting, entry.postings_count);
        }
        return entry.postings_offset;
    }
    if (termEntryDenseAllDocsFreqStreamOffset(entry)) |posting_offset| {
        if (entry.postings_count != doc_count) return error.InvalidRecord;
        if (try view.mappedBodyFromOffset(posting_offset)) |bytes| {
            return std.math.add(u64, posting_offset, try scanDenseAllDocsFreqStreamBytes(bytes, entry.postings_count, doc_count, guard, context, callback)) catch return error.RecordTooLarge;
        }
        return try scanDenseAllDocsFreqStreamFile(view, posting_offset, entry.postings_count, doc_count, guard, context, callback);
    }
    return scanPersistentPostingRange(view, entry.postings_offset, entry.postings_count, doc_count, guard, context, callback);
}

const TextPostingBlockStats = struct {
    posting_offset: u64,
    posting_count: u64,
    first_doc_id: u64,
    last_doc_id: u64,
    max_weighted_tf: f32,
    min_doc_len: f32,
};

fn scanPersistentPostingBlocks(
    view: *TextPostingsFileView,
    posting_offset: u64,
    posting_count: u64,
    doc_count: u64,
    block_size: u64,
    guard: TextPostingScanGuard,
    context: anytype,
    comptime callback: fn (@TypeOf(context), TextPostingBlockStats) anyerror!void,
) !u64 {
    if (block_size == 0) return error.InvalidRecord;

    var previous_doc_id: u64 = 0;
    var index: u64 = 0;
    var next_block_posting_offset = posting_offset;
    while (index < posting_count) {
        const remaining = posting_count - index;
        const current_block_count = @min(remaining, block_size);
        var stats = TextPostingBlockStats{
            .posting_offset = next_block_posting_offset,
            .posting_count = current_block_count,
            .first_doc_id = 0,
            .last_doc_id = 0,
            .max_weighted_tf = 0,
            .min_doc_len = std.math.inf(f32),
        };

        next_block_posting_offset = try scanPersistentPostingBlock(view, stats.posting_offset, current_block_count, doc_count, guard, &previous_doc_id, &stats);
        try callback(context, stats);
        index += current_block_count;
    }
    return next_block_posting_offset;
}

fn persistentBlockPostingCount(term_posting_count: u64, local_block_index: u64, block_size: u64) !u64 {
    if (block_size == 0) return error.InvalidRecord;
    const local_postings = std.math.mul(u64, local_block_index, block_size) catch return error.RecordTooLarge;
    if (local_postings >= term_posting_count) return error.InvalidRecord;
    return @min(block_size, term_posting_count - local_postings);
}

fn scanPersistentPostingBlock(
    view: *TextPostingsFileView,
    posting_offset: u64,
    posting_count: u64,
    doc_count: u64,
    guard: TextPostingScanGuard,
    previous_doc_id: *u64,
    stats: *TextPostingBlockStats,
) !u64 {
    var compressed_previous_doc_id: u64 = 0;
    if (try view.mappedBodyFromOffset(posting_offset)) |bytes| {
        var cursor: usize = 0;
        var i: u64 = 0;
        while (i < posting_count) : (i += 1) {
            try guardBeforeTextPosting(guard);
            const posting = try decodeCompressedTextPostingFromBytes(bytes, &cursor, compressed_previous_doc_id);
            compressed_previous_doc_id = posting.doc_id;
            try addPostingToBlockStats(posting, previous_doc_id, doc_count, stats);
        }
        return std.math.add(u64, posting_offset, cursor) catch return error.RecordTooLarge;
    }

    var i: u64 = 0;
    var cursor = try textPostingBodyOffset(posting_offset);
    while (i < posting_count) : (i += 1) {
        try guardBeforeTextPosting(guard);
        const posting = try decodeCompressedTextPostingFromFile(view, &cursor, compressed_previous_doc_id);
        compressed_previous_doc_id = posting.doc_id;
        try addPostingToBlockStats(posting, previous_doc_id, doc_count, stats);
    }
    return cursor - TextPostingsHeader.encoded_len;
}

fn addPostingToBlockStats(posting: TextPostingRecord, previous_doc_id: *u64, doc_count: u64, stats: *TextPostingBlockStats) !void {
    try validateScannedTextPosting(posting, previous_doc_id, doc_count);
    if (stats.first_doc_id == 0) stats.first_doc_id = posting.doc_id;
    stats.last_doc_id = posting.doc_id;
    const weighted_tf = persistentWeightedTf(posting);
    if (!std.math.isFinite(weighted_tf)) return core.Error.Unsupported;
    stats.max_weighted_tf = @max(stats.max_weighted_tf, weighted_tf);
    stats.min_doc_len = @min(stats.min_doc_len, weighted_tf);
}

fn validateScannedTextPosting(posting: TextPostingRecord, previous_doc_id: *u64, doc_count: u64) !void {
    if (posting.doc_id <= previous_doc_id.*) return error.InvalidRecord;
    if (posting.doc_id > doc_count) return error.InvalidRecord;
    previous_doc_id.* = posting.doc_id;
}

const PersistentTextCatalogStats = struct {
    term_count: u64 = 0,
    term_bytes: u64 = 0,
    posting_count: u64 = 0,
};

/// Compile-time data-plane bundle for the external-run publication owner.
/// Runtime orchestration crosses the boundary through one `write` entry; the
/// bundle keeps existing run/format representations private to this façade.
const StreamingRunCatalogPublicationOps = struct {
    pub const PostingFormatConfig_dep = PostingFormatConfig;
    pub const TermFormatConfig_dep = TermFormatConfig;
    pub const SearchAccelerationFormatConfig_dep = SearchAccelerationFormatConfig;
    pub const persistent_posting_block_size_dep = persistent_posting_block_size;
    pub const persistent_posting_block_capacity_dep = persistent_posting_block_capacity;
    pub const persistent_posting_block_offset_checkpoint_terms_dep = persistent_posting_block_offset_checkpoint_terms;
    pub const persistent_posting_block_byte_offset_checkpoint_blocks_dep = persistent_posting_block_byte_offset_checkpoint_blocks;
    pub const persistent_term_top_hit_capacity_dep = persistent_term_top_hit_capacity;
    pub const persistent_term_top_hit_capacity_usize_dep = persistent_term_top_hit_capacity_usize;
    pub const persistent_term_top_hit_regular_probe_capacity_dep = persistent_term_top_hit_regular_probe_capacity;
    pub const persistent_all_docs_synthesis_min_postings_dep = persistent_all_docs_synthesis_min_postings;
    pub const persistent_dense_all_docs_freq_group_size_dep = persistent_dense_all_docs_freq_group_size;
    pub const persistent_dense_all_docs_top_hit_skip_run_max_dep = persistent_dense_all_docs_top_hit_skip_run_max;
    pub const persistent_dense_all_docs_freq_mode_packed_dep = persistent_dense_all_docs_freq_mode_packed;
    pub const TextPostingRunRecord_dep = TextPostingRunRecord;
    pub const TextTopHitDocStats_dep = TextTopHitDocStats;
    pub const TextDocRankEntry_dep = TextDocRankEntry;
    pub const TextDocsFileView_dep = TextDocsFileView;
    pub const TextPostingBlockStats_dep = TextPostingBlockStats;
    pub const addPostingToBlockStats_dep = addPostingToBlockStats;
    pub const PersistentTextCatalogStats_dep = PersistentTextCatalogStats;
    pub const textBenchTraceEnabled_dep = textBenchTraceEnabled;
    pub const textBenchTrace_dep = textBenchTrace;
    pub const textBenchTraceSummaryStats_dep = textBenchTraceSummaryStats;
    pub const compressed_posting_max_encoded_len_dep = compressed_posting_max_encoded_len;
    pub const validateDenseAllDocsTextFreq_dep = validateDenseAllDocsTextFreq;
    pub const encodePersistentVarint_dep = encodePersistentVarint;
    pub const encodeCompressedTextPosting_dep = encodeCompressedTextPosting;
    pub const textTermTopHitLessThan_dep = textTermTopHitLessThan;
    pub const findWorstTextTermTopHitIndex_dep = findWorstTextTermTopHitIndex;
    pub const appendTopTextTermHitBoundedInline_dep = appendTopTextTermHitBoundedInline;
    pub const persistentMinPossibleDocLen_dep = persistentMinPossibleDocLen;
    pub const textTermTopHitCandidateCannotBeatCurrentWorstWithDocLenFloor_dep = textTermTopHitCandidateCannotBeatCurrentWorstWithDocLenFloor;
    pub const textTermsPath_dep = textTermsPath;
    pub const textPostingsPath_dep = textPostingsPath;
    pub const textPostingBlocksPath_dep = textPostingBlocksPath;
    pub const textPostingBlockImpactsPath_dep = textPostingBlockImpactsPath;
    pub const textTermTopHitsPath_dep = textTermTopHitsPath;
    pub const renameReplace_dep = renameReplace;
    pub const textOptionsNeedSync_dep = textOptionsNeedSync;
    pub const TextBufferedWriter_dep = TextBufferedWriter;
    pub const textWriteBufferCapacity_dep = textWriteBufferCapacity;
    pub const TextPostingRunReader_dep = TextPostingRunReader;
    pub const TextPostingRunSummaryFile_dep = TextPostingRunSummaryFile;
    pub const VariableAllDocsFreqSlice_dep = VariableAllDocsFreqSlice;
    pub const TextPostingSyntheticRunSource_dep = TextPostingSyntheticRunSource;
    pub const TextPostingRunMerger_dep = TextPostingRunMerger;
    pub const TextPostingRunTermSummaryRecord_dep = TextPostingRunTermSummaryRecord;
    pub const textPostingRunSummaryRegularConstantTopHitCandidate_dep = textPostingRunSummaryRegularConstantTopHitCandidate;
    pub const TextPostingRunSummaryStats_dep = TextPostingRunSummaryStats;
    pub const TextPostingRunMergedSummaryReader_dep = TextPostingRunMergedSummaryReader;
    pub const collectTextPostingRunTermSummaryStatsFromFiles_dep = collectTextPostingRunTermSummaryStatsFromFiles;
    pub const writeEmptyTermsAndPostingsFiles_dep = writeEmptyTermsAndPostingsFiles;
    pub const appendDenseAllDocsFreqGroup_dep = appendDenseAllDocsFreqGroup;
    pub const appendDenseAllDocsFreqStreamFreqs_dep = appendDenseAllDocsFreqStreamFreqs;
    pub const MemoryPostingBlockImpact_dep = MemoryPostingBlockImpact;
    pub const memoryPostingBlockImpactLessThan_dep = memoryPostingBlockImpactLessThan;
    pub const persistentTermTopHitCountForPostingCount_dep = persistentTermTopHitCountForPostingCount;
    pub const textPostingsFileSize_dep = textPostingsFileSize;
    pub const textPostingBlockCheckpointCount_dep = textPostingBlockCheckpointCount;
    pub const textPostingBlockCheckpointTableOffset_dep = textPostingBlockCheckpointTableOffset;
    pub const textPostingBlockByteOffsetCheckpointCount_dep = textPostingBlockByteOffsetCheckpointCount;
    pub const textPostingBlockByteOffsetCheckpointTableOffset_dep = textPostingBlockByteOffsetCheckpointTableOffset;
    pub const textPostingBlockRecordOffset_dep = textPostingBlockRecordOffset;
    pub const textPostingBlocksFileSize_dep = textPostingBlocksFileSize;
    pub const textPostingBlockImpactRecordOffset_dep = textPostingBlockImpactRecordOffset;
    pub const textPostingBlockImpactsFileSize_dep = textPostingBlockImpactsFileSize;
    pub const textTermTopHitTermIndexOffset_dep = textTermTopHitTermIndexOffset;
    pub const textTermTopHitRecordOffset_dep = textTermTopHitRecordOffset;
    pub const textTermTopHitsFileSize_dep = textTermTopHitsFileSize;
    pub const regularFileSize_dep = regularFileSize;
    pub const persistentWeightedTf_dep = persistentWeightedTf;
    pub const persistentAvgDocLen_dep = persistentAvgDocLen;
    pub const appendPersistentFrontCodedTerm_dep = appendPersistentFrontCodedTerm;
};

const RebuildSessionOps = struct {
    pub const ExternalContext = PersistentTextExternalRunSession;
};

/// Private data-plane adapter for `text.rebuild_session`. The session sees
/// phase-shaped operations, while posting builders, document views, tracing,
/// and catalog algorithms remain implementation details of this façade.
const PersistentTextExternalRunSession = struct {
    allocator: std.mem.Allocator,
    store: storage_mod.Store,
    runs_base_path: []const u8,
    deadline: core.QueryDeadline,
    run_builder: TextPostingRunBuilder,
    text_meta: PersistentTextMeta,
    docs_view: ?TextDocsFileView = null,

    pub fn init(
        allocator: std.mem.Allocator,
        store: storage_mod.Store,
        runs_base_path: []const u8,
        deadline: core.QueryDeadline,
        measure_chunks: bool,
    ) !PersistentTextExternalRunSession {
        try cleanupTextPostingRunScratchFiles(allocator, store.io, runs_base_path);
        var run_builder = try TextPostingRunBuilder.initWithChunkTiming(
            allocator,
            store.io,
            runs_base_path,
            measure_chunks,
        );
        errdefer run_builder.deinit();
        const index_meta = try currentPersistentTextMetaAnchor(store);
        const text_meta = try currentPersistentTextMetaAnchorDigest(allocator, store, index_meta);
        return .{
            .allocator = allocator,
            .store = store,
            .runs_base_path = runs_base_path,
            .deadline = deadline,
            .run_builder = run_builder,
            .text_meta = text_meta,
        };
    }

    pub fn deinit(self: *PersistentTextExternalRunSession) void {
        if (self.docs_view) |*view| view.deinit();
        self.run_builder.deinit();
    }

    pub fn clockIo(self: *const PersistentTextExternalRunSession) std.Io {
        return self.store.io;
    }

    pub fn buildDocs(
        self: *PersistentTextExternalRunSession,
        timings: ?*rebuild_runtime.PersistentTextRebuildTimings,
        observer: ?rebuild_runtime.PersistentTextRebuildObserver,
    ) !void {
        textBenchTrace("rebuild_runs_docs_start");
        document_catalog_stream_writer.writeTextDocsFileFromStore(
            self.allocator,
            self.store,
            self.deadline,
            &self.run_builder,
            &self.text_meta,
            timings,
            observer,
        ) catch |err| {
            textBenchTraceMeta("rebuild_runs_docs_error", self.text_meta);
            return err;
        };
        textBenchTraceMeta("rebuild_runs_docs_done", self.text_meta);
    }

    pub fn finishRuns(self: *PersistentTextExternalRunSession) !void {
        textBenchTrace("rebuild_runs_finish_start");
        self.run_builder.finish() catch |err| {
            textBenchTraceRunBuilder("rebuild_runs_finish_error", &self.run_builder);
            return err;
        };
        textBenchTraceRunBuilder("rebuild_runs_finish_done", &self.run_builder);
    }

    pub fn captureRunTimings(
        self: *PersistentTextExternalRunSession,
        timings: *rebuild_runtime.PersistentTextRebuildTimings,
    ) !void {
        timings.run_chunk_sort_ns = self.run_builder.chunk_sort_ns;
        timings.run_chunk_write_ns = self.run_builder.chunk_write_ns;
        timings.run_chunk_count = self.run_builder.chunk_count;
        timings.run_chunk_records = self.run_builder.chunk_records;
        timings.run_chunk_peak_record_bytes = self.run_builder.chunk_peak_record_bytes;
        timings.run_chunk_peak_term_bytes = self.run_builder.chunk_peak_term_bytes;
        timings.run_chunk_peak_scratch_bytes = self.run_builder.chunk_peak_scratch_bytes;
        timings.run_chunk_peak_record_capacity_bytes = self.run_builder.chunk_peak_record_capacity_bytes;
        timings.run_chunk_peak_term_capacity_bytes = self.run_builder.chunk_peak_term_capacity_bytes;
        timings.run_chunk_peak_scratch_capacity_bytes = self.run_builder.chunk_peak_scratch_capacity_bytes;
        timings.run_tmp_regular_file_count = @intCast(self.run_builder.run_paths.items.len);
        timings.run_tmp_summary_file_count = @intCast(self.run_builder.run_summaries.items.len);
        timings.run_tmp_synthetic_source_count = @intCast(self.run_builder.synthetic_run_sources.items.len);
        timings.run_tmp_regular_bytes = try sumTextPathFileBytes(self.store.io, self.run_builder.run_paths.items);
        timings.run_tmp_summary_bytes = 0;
        for (self.run_builder.run_summaries.items) |summary| {
            timings.run_tmp_summary_bytes = std.math.add(
                u64,
                timings.run_tmp_summary_bytes,
                summary.file_size,
            ) catch return error.RecordTooLarge;
        }
        timings.run_tmp_total_bytes = std.math.add(
            u64,
            timings.run_tmp_regular_bytes,
            timings.run_tmp_summary_bytes,
        ) catch return error.RecordTooLarge;
        timings.run_record_term_bytes = self.run_builder.run_record_term_bytes;
        timings.run_record_inline_capacity_bytes = self.run_builder.run_record_inline_capacity_bytes;
        timings.run_record_term_slack_bytes = self.run_builder.run_record_term_slack_bytes;
        timings.run_record_term_cache_hits = self.run_builder.run_record_term_cache_hits;
        timings.run_record_term_cache_saved_bytes = self.run_builder.run_record_term_cache_saved_bytes;
        timings.run_record_long_term_count = self.run_builder.run_record_long_term_count;
        timings.run_record_max_term_len = self.run_builder.run_record_max_term_len;
        timings.run_inline_singleton_materialized_terms = self.run_builder.inline_singleton_materialized_terms;
        timings.run_inline_singleton_materialized_records = self.run_builder.inline_singleton_materialized_records;
        timings.run_inline_singleton_materialized_bytes = self.run_builder.inline_singleton_materialized_bytes;
        timings.docs_posting_append_materialize_ns = self.run_builder.docs_posting_append_materialize_ns;
        timings.docs_posting_append_sweep_ns = self.run_builder.docs_posting_append_sweep_ns;
        timings.docs_posting_append_regular_sampled_ns = self.run_builder.docs_posting_append_regular_sampled_ns;
        timings.docs_posting_append_candidate_lookup_sampled_ns = self.run_builder.docs_posting_append_candidate_lookup_sampled_ns;
        timings.docs_posting_append_candidate_hit_sampled_ns = self.run_builder.docs_posting_append_candidate_hit_sampled_ns;
        timings.docs_posting_append_virtual_hit_sampled_ns = self.run_builder.docs_posting_append_virtual_hit_sampled_ns;
        timings.docs_posting_append_variable_hit_sampled_ns = self.run_builder.docs_posting_append_variable_hit_sampled_ns;
        timings.docs_posting_append_variable_freq_sampled_ns = self.run_builder.docs_posting_append_variable_freq_sampled_ns;
        timings.docs_posting_append_term_count = self.run_builder.docs_posting_append_term_count;
        timings.docs_posting_append_regular_record_count = self.run_builder.docs_posting_append_regular_record_count;
        timings.docs_posting_append_virtual_candidate_put_count = self.run_builder.docs_posting_append_virtual_candidate_put_count;
        timings.docs_posting_append_virtual_candidate_hit_count = self.run_builder.docs_posting_append_virtual_candidate_hit_count;
        timings.docs_posting_append_variable_candidate_hit_count = self.run_builder.docs_posting_append_variable_candidate_hit_count;
        timings.docs_posting_append_variable_freq_append_count = self.run_builder.docs_posting_append_variable_freq_append_count;
        timings.docs_posting_append_candidate_filter_skip_count = self.run_builder.docs_posting_append_candidate_filter_skip_count;
        timings.docs_posting_append_candidate_lookup_count = self.run_builder.docs_posting_append_candidate_lookup_count;
        timings.docs_posting_append_candidate_cache_hit_count = self.run_builder.docs_posting_append_candidate_cache_hit_count;
        timings.docs_posting_append_candidate_miss_count = self.run_builder.docs_posting_append_candidate_miss_count;
        timings.docs_posting_append_candidate_regularized_hit_count = self.run_builder.docs_posting_append_candidate_regularized_hit_count;
        timings.docs_posting_append_materialize_call_count = self.run_builder.docs_posting_append_materialize_call_count;
        timings.docs_posting_append_sweep_count = self.run_builder.docs_posting_append_sweep_count;
        timings.docs_posting_append_regular_sample_count = self.run_builder.docs_posting_append_regular_sample_count;
        timings.docs_posting_append_candidate_lookup_sample_count = self.run_builder.docs_posting_append_candidate_lookup_sample_count;
        timings.docs_posting_append_candidate_hit_sample_count = self.run_builder.docs_posting_append_candidate_hit_sample_count;
        timings.docs_posting_append_virtual_hit_sample_count = self.run_builder.docs_posting_append_virtual_hit_sample_count;
        timings.docs_posting_append_variable_hit_sample_count = self.run_builder.docs_posting_append_variable_hit_sample_count;
        timings.docs_posting_append_variable_freq_sample_count = self.run_builder.docs_posting_append_variable_freq_sample_count;
        timings.run_virtual_all_docs_synthetic_records = self.run_builder.virtual_all_docs_synthetic_records;
        timings.run_variable_all_docs_synthetic_records = self.run_builder.variable_all_docs_synthetic_records;
        timings.run_variable_all_docs_freq_stream_cells = self.run_builder.variable_all_docs_freq_stream_cells;
        timings.run_variable_all_docs_freq_stream_packed_bytes = self.run_builder.variable_all_docs_freq_stream_packed_bytes;
        timings.run_variable_all_docs_freq_stream_rle_bytes = self.run_builder.variable_all_docs_freq_stream_rle_bytes;
        timings.run_variable_all_docs_freq_stream_bitpacked_bytes = self.run_builder.variable_all_docs_freq_stream_bitpacked_bytes;
        timings.run_variable_all_docs_freq_stream_rle_run_count = self.run_builder.variable_all_docs_freq_stream_rle_run_count;
        timings.run_variable_all_docs_freq_stream_max_freq = self.run_builder.variable_all_docs_freq_stream_max_freq;
    }

    pub fn releaseScratch(self: *PersistentTextExternalRunSession) void {
        textBenchTrace("rebuild_runs_scratch_release_start");
        self.run_builder.releaseBuildScratchAfterFinish();
        textBenchTraceRunBuilder("rebuild_runs_scratch_release_done", &self.run_builder);
    }

    pub fn openDocs(self: *PersistentTextExternalRunSession) !void {
        if (self.docs_view != null) return error.InvalidRecord;
        textBenchTrace("rebuild_runs_open_docs_start");
        self.docs_view = openPersistentTextDocsView(
            self.allocator,
            self.store,
            self.text_meta.doc_count,
        ) catch |err| {
            textBenchTraceMeta("rebuild_runs_open_docs_error", self.text_meta);
            return err;
        };
    }

    pub fn writeCatalog(
        self: *PersistentTextExternalRunSession,
        timings: ?*rebuild_runtime.PersistentTextRebuildTimings,
    ) !PersistentTextCatalogStats {
        textBenchTrace("rebuild_runs_catalog_start");
        const docs_view = if (self.docs_view) |*view| view else return error.InvalidRecord;
        return streaming_run_catalog_publication.write(
            self.allocator,
            self.store,
            self.run_builder.run_paths.items,
            self.run_builder.run_summaries.items,
            self.run_builder.synthetic_run_sources.items,
            self.run_builder.run_paths_disjoint_term_ranges,
            docs_view,
            self.text_meta,
            self.deadline,
            timings,
        ) catch |err| {
            textBenchTraceRunBuilder("rebuild_runs_catalog_error", &self.run_builder);
            textBenchTraceMeta("rebuild_runs_catalog_meta_error", self.text_meta);
            return err;
        };
    }

    pub fn applyCatalogStats(
        self: *PersistentTextExternalRunSession,
        stats: PersistentTextCatalogStats,
    ) void {
        self.text_meta.term_count = stats.term_count;
        self.text_meta.term_bytes = stats.term_bytes;
        self.text_meta.posting_count = stats.posting_count;
        textBenchTraceMeta("rebuild_runs_catalog_done", self.text_meta);
    }

    pub fn writeMeta(self: *PersistentTextExternalRunSession) !void {
        textBenchTrace("rebuild_runs_meta_start");
        writeTextMetaFile(self.allocator, self.store, self.text_meta) catch |err| {
            textBenchTraceMeta("rebuild_runs_meta_error", self.text_meta);
            return err;
        };
    }

    pub fn finishMeta(self: *PersistentTextExternalRunSession) void {
        textBenchTraceMeta("rebuild_runs_meta_done", self.text_meta);
    }

    pub fn finalMeta(self: *const PersistentTextExternalRunSession) PersistentTextMeta {
        return self.text_meta;
    }
};

pub const PersistentTextRebuildTimings = rebuild_runtime.PersistentTextRebuildTimings;
pub const PersistentTextRebuildPhase = rebuild_runtime.PersistentTextRebuildPhase;
pub const PersistentTextRebuildObserver = rebuild_runtime.PersistentTextRebuildObserver;

pub const PersistentPostingCompressionEstimate = struct {
    posting_count: u64 = 0,
    fixed_record_bytes: u64 = 0,
    delta_varint_estimated_bytes: u64 = 0,
    delta_varint_doc_bytes: u64 = 0,
    elias_fano_doc_estimated_bytes: u64 = 0,
    hybrid_doc_estimated_bytes: u64 = 0,
    material_field_tag_bits_estimated_bytes: u64 = 0,
    material_block_jump_checkpoint_bytes: u64 = 0,
    material_hybrid_format_bits_bytes: u64 = 0,
    material_elias_fano_select_checkpoint_bytes: u64 = 0,
    material_hybrid_select_checkpoint_bytes: u64 = 0,
    elias_fano_material_estimated_bytes: u64 = 0,
    hybrid_material_estimated_bytes: u64 = 0,
    elias_fano_material_with_select_estimated_bytes: u64 = 0,
    hybrid_material_with_select_estimated_bytes: u64 = 0,
    hybrid_select_aware_doc_with_select_estimated_bytes: u64 = 0,
    hybrid_select_aware_material_estimated_bytes: u64 = 0,
    hybrid_select_aware_ef_term_count: u64 = 0,
    hybrid_select_aware_delta_term_count: u64 = 0,
    singleton_inline_posting_count: u64 = 0,
    singleton_inline_saved_bytes: u64 = 0,
    virtual_all_docs_term_count: u64 = 0,
    virtual_all_docs_saved_bytes: u64 = 0,
    dense_all_docs_freq_stream_term_count: u64 = 0,
    dense_all_docs_freq_stream_saved_bytes: u64 = 0,
    elias_fano_better_term_count: u64 = 0,
    elias_fano_worse_term_count: u64 = 0,
    delta_varint_field_mask_bytes: u64 = 0,
    delta_varint_text_freq_bytes: u64 = 0,
    delta_varint_kind_freq_bytes: u64 = 0,
    max_doc_delta: u64 = 0,
    max_text_freq: u32 = 0,
    max_kind_freq: u32 = 0,
    doc_delta_over_u16_count: u64 = 0,
    text_freq_over_u8_count: u64 = 0,
};

pub const PersistentTextRebuildBenchResult = rebuild_runtime.PersistentTextRebuildBenchResult;

fn textBenchTraceEnabled() bool {
    return bench_trace_environment.enabled();
}

fn textBenchTrace(comptime label: []const u8) void {
    if (!textBenchTraceEnabled()) return;
    std.debug.print("text_trace={s}\n", .{label});
}

fn textBenchTraceMeta(comptime label: []const u8, meta: PersistentTextMeta) void {
    if (!textBenchTraceEnabled()) return;
    std.debug.print(
        "text_trace={s} doc_count={} total_text_tokens={} term_count={} term_bytes={} posting_count={}\n",
        .{ label, meta.doc_count, meta.total_text_tokens, meta.term_count, meta.term_bytes, meta.posting_count },
    );
}

fn textBenchTraceRunBuilder(comptime label: []const u8, builder: *const TextPostingRunBuilder) void {
    if (!textBenchTraceEnabled()) return;
    std.debug.print(
        "text_trace={s} doc_count={} chunk_items={} chunk_records={} run_paths={} run_summaries={} synthetic_sources={} all_docs_candidates={} variable_freq_cells={} virtual_synthetic_records={} variable_synthetic_records={}\n",
        .{
            label,
            builder.doc_count,
            builder.chunk.items.len,
            builder.chunk_records,
            builder.run_paths.items.len,
            builder.run_summaries.items.len,
            builder.synthetic_run_sources.items.len,
            builder.all_docs_candidates.count(),
            builder.variable_all_docs_freq_cells,
            builder.virtual_all_docs_synthetic_records,
            builder.variable_all_docs_synthetic_records,
        },
    );
}

fn textBenchTraceSummaryStats(comptime label: []const u8, stats: TextPostingRunSummaryStats) void {
    if (!textBenchTraceEnabled()) return;
    std.debug.print(
        "text_trace={s} term_count={} term_bytes_len={} posting_count={} block_count={} hit_count={} top_hit_term_count={} term_exception_count={} virtual_all_docs_terms={} dense_all_docs_terms={} regular_constant_top_hit_terms={}\n",
        .{
            label,
            stats.term_count,
            stats.term_bytes_len,
            stats.posting_count,
            stats.block_count,
            stats.hit_count,
            stats.top_hit_term_count,
            stats.term_exception_count,
            stats.virtual_all_docs_term_count,
            stats.dense_all_docs_freq_stream_term_count,
            stats.regular_constant_top_hit_term_count,
        },
    );
}

fn textPathFileSize(io: std.Io, path: []const u8) !u64 {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.kind != .file) return error.IsDir;
    return stat.size;
}

fn sumTextPathFileBytes(io: std.Io, paths: []const []const u8) !u64 {
    var total: u64 = 0;
    for (paths) |path| {
        total = std.math.add(u64, total, try textPathFileSize(io, path)) catch return error.RecordTooLarge;
    }
    return total;
}

fn currentPersistentTextMetaAnchor(store: storage_mod.Store) !storage_mod.IndexMeta {
    const meta = try store.readIndexMeta();
    if (meta.event_bytes != try store.eventByteCount()) return error.InvalidRecord;
    return meta;
}

fn persistentTextMetaFromIndexMeta(index_meta: storage_mod.IndexMeta) PersistentTextMeta {
    return .{
        .node_digest = index_meta.node_digest,
        .node_by_text_order_digest = index_meta.node_by_text_order_digest,
        // The anchor is verified against the live event log before rebuild, so
        // this is the exact watermark the published catalog covers; the
        // incremental tail is everything the event log appends after it.
        .indexed_event_bytes = index_meta.event_bytes,
    };
}

fn currentPersistentTextMetaAnchorDigest(allocator: std.mem.Allocator, store: storage_mod.Store, index_meta: storage_mod.IndexMeta) !PersistentTextMeta {
    var meta = persistentTextMetaFromIndexMeta(index_meta);
    meta.searchable_metadata_digest = try store.searchableNodeMetadataDigest(allocator);
    return meta;
}

pub const rebuildPersistentTextCatalog = rebuild_session.rebuildPersistentTextCatalog;
pub const rebuildPersistentTextCatalogFromRunsForBench = rebuild_session.rebuildPersistentTextCatalogFromRunsForBench;
pub const rebuildPersistentTextCatalogWithTimingsForBench = rebuild_session.rebuildPersistentTextCatalogWithTimingsForBench;
pub const rebuildPersistentTextCatalogWithTimingsAndObserverForBench = rebuild_session.rebuildPersistentTextCatalogWithTimingsAndObserverForBench;

fn rebuildPersistentTextCatalogOnce(allocator: std.mem.Allocator, store: storage_mod.Store) !PersistentTextMeta {
    return rebuildPersistentTextCatalogOnceDeadline(allocator, store, .none);
}

fn rebuildPersistentTextCatalogOnceDeadline(allocator: std.mem.Allocator, store: storage_mod.Store, deadline: core.QueryDeadline) !PersistentTextMeta {
    return rebuildPersistentTextCatalogOnceDeadlineTimed(allocator, store, deadline, null);
}

fn rebuildPersistentTextCatalogOnceDeadlineTimed(
    allocator: std.mem.Allocator,
    store: storage_mod.Store,
    deadline: core.QueryDeadline,
    timings: ?*PersistentTextRebuildTimings,
) !PersistentTextMeta {
    var term_builder = PersistentTermBuilder.init(allocator);
    defer term_builder.deinit();

    const index_meta = try currentPersistentTextMetaAnchor(store);
    var text_meta = try currentPersistentTextMetaAnchorDigest(allocator, store, index_meta);
    const docs_start = textMonotonicNs(store.io);
    try document_catalog_stream_writer.writeTextDocsFileFromStoreWithTermBuilder(allocator, store, deadline, &term_builder, &text_meta, timings);
    if (timings) |t| t.docs_ns = textElapsedNs(store.io, docs_start);
    const trim_start = textMonotonicNs(store.io);
    term_builder.releaseTermIndex();
    try term_builder.trimCapacity();
    if (timings) |t| t.term_builder_trim_ns = textElapsedNs(store.io, trim_start);
    if (deadline.expired()) return core.Error.BudgetExceeded;
    const open_docs_start = textMonotonicNs(store.io);
    var docs_view = try openPersistentTextDocsView(allocator, store, text_meta.doc_count);
    defer docs_view.deinit();
    if (timings) |t| t.open_docs_ns = textElapsedNs(store.io, open_docs_start);
    const catalog_start = textMonotonicNs(store.io);
    const catalog_stats = try term_posting_catalog_publication.writeTermsAndPostingsFiles(allocator, store, &term_builder, &docs_view, text_meta);
    if (timings) |t| t.catalog_ns = textElapsedNs(store.io, catalog_start);
    text_meta.term_count = catalog_stats.term_count;
    text_meta.term_bytes = catalog_stats.term_bytes;
    text_meta.posting_count = catalog_stats.posting_count;
    if (deadline.expired()) return core.Error.BudgetExceeded;
    const meta_start = textMonotonicNs(store.io);
    try writeTextMetaFile(allocator, store, text_meta);
    if (timings) |t| t.meta_write_ns = textElapsedNs(store.io, meta_start);
    return text_meta;
}

const nextPersistentTextDocId = catalog_format.nextPersistentTextDocId;

pub fn readPersistentTextMeta(allocator: std.mem.Allocator, store: storage_mod.Store) !PersistentTextMeta {
    const path = try textMetaPath(allocator, store);
    defer allocator.free(path);
    var file = try std.Io.Dir.cwd().openFile(store.io, path, .{});
    defer file.close(store.io);
    const file_size = try regularFileSize(store, file);
    var bytes: [PersistentTextMeta.encoded_len]u8 = undefined;
    const n = try file.readPositionalAll(store.io, &bytes, 0);
    if (n != bytes.len) return error.InvalidRecord;
    if (file_size != bytes.len) return error.InvalidRecord;
    return PersistentTextMeta.decode(&bytes);
}

pub fn readPersistentTermPostings(allocator: std.mem.Allocator, store: storage_mod.Store, term: []const u8) !std.ArrayList(TextPostingRecord) {
    return readPersistentTermPostingsLimited(allocator, store, term, core.default_max_text_postings_scanned);
}

pub fn readPersistentTermPostingsLimited(allocator: std.mem.Allocator, store: storage_mod.Store, term: []const u8, max_postings: usize) !std.ArrayList(TextPostingRecord) {
    if (try persistentTextCatalogStale(allocator, store)) return error.InvalidRecord;
    var postings = try readPersistentTermPostingsUnchecked(allocator, store, term, max_postings);
    errdefer postings.deinit(allocator);
    try validatePersistentTermPostings(allocator, store, term, postings.items);
    return postings;
}

fn readPersistentTermPostingsUnchecked(allocator: std.mem.Allocator, store: storage_mod.Store, term: []const u8, max_postings: usize) !std.ArrayList(TextPostingRecord) {
    var out = std.ArrayList(TextPostingRecord).empty;
    errdefer out.deinit(allocator);
    const doc_count = try readPersistentTextDocCount(allocator, store);
    var catalog = try PersistentPostingCatalog.open(allocator, store, doc_count);
    defer catalog.deinit();

    if (try catalog.findTermEntry(term)) |lookup| {
        const entry = lookup.entry;
        if (entry.postings_count > max_postings) return core.Error.BudgetExceeded;
        var collect_context = CollectTextPostingsContext{
            .allocator = allocator,
            .out = &out,
        };
        _ = try scanPersistentTermPostings(&catalog.postings_view, entry, catalog.doc_count, .none, &collect_context, collectTextPosting);
        return out;
    }
    return out;
}

const CollectTextPostingsContext = struct {
    allocator: std.mem.Allocator,
    out: *std.ArrayList(TextPostingRecord),
};

fn collectTextPosting(context: *CollectTextPostingsContext, posting: TextPostingRecord, _: u64) !void {
    try context.out.append(context.allocator, posting);
}

/// Drop and re-create a catalog file view's mapping mid-scan so a long
/// sequential pass does not keep every touched clean page in the process
/// peak RSS. A failed re-map leaves the view on its positional-read path.
fn remapCatalogViewForScan(view: anytype) void {
    if (view.map) |*map| {
        map.destroy(view.io);
        view.map = null;
        const len = std.math.cast(usize, view.size) orelse return;
        view.map = read_only_memory_map.create(view.io, view.file, len) catch null;
    }
}

pub fn estimatePersistentPostingCompression(allocator: std.mem.Allocator, store: storage_mod.Store) !PersistentPostingCompressionEstimate {
    const doc_count = try readPersistentTextDocCount(allocator, store);
    var catalog = try PersistentPostingCatalog.open(allocator, store, doc_count);
    defer catalog.deinit();

    var estimate = PersistentPostingCompressionEstimate{};
    var expected_postings_offset: u64 = 0;
    var term_index: u64 = 0;
    // The scan touches every catalog page exactly once; without dropping the
    // mappings periodically the whole postings, terms, blocks, and impacts
    // files end up resident and dominate the process peak RSS on real-entropy
    // vocabularies. Darwin ignores madvise on file-backed maps, so remapping
    // is the portable release.
    var released_postings: u64 = 0;
    const release_stride: u64 = 64 * 1024 * 1024;
    while (term_index < catalog.terms_header.term_count) : (term_index += 1) {
        if (expected_postings_offset >= released_postings + release_stride) {
            remapCatalogViewForScan(&catalog.postings_view);
            remapCatalogViewForScan(&catalog.terms_view);
            remapCatalogViewForScan(&catalog.blocks_view);
            remapCatalogViewForScan(&catalog.impacts_view);
            released_postings = expected_postings_offset;
        }
        const entry = try catalog.terms_view.readEntryAt(catalog.terms_header, term_index);
        var context = PostingCompressionEstimateContext{ .estimate = &estimate };
        if (termEntryHasInlinePosting(entry)) {
            _ = try scanPersistentTermPostings(&catalog.postings_view, entry, catalog.doc_count, .none, &context, collectPostingCompressionEstimate);
            estimate.singleton_inline_posting_count = std.math.add(u64, estimate.singleton_inline_posting_count, 1) catch return error.RecordTooLarge;
            estimate.singleton_inline_saved_bytes = std.math.add(u64, estimate.singleton_inline_saved_bytes, context.delta_varint_doc_bytes) catch return error.RecordTooLarge;
        } else if (termEntryVirtualAllDocsTextFreq(entry) != null) {
            _ = try scanPersistentTermPostings(&catalog.postings_view, entry, catalog.doc_count, .none, &context, collectPostingCompressionEstimate);
            estimate.virtual_all_docs_term_count = std.math.add(u64, estimate.virtual_all_docs_term_count, 1) catch return error.RecordTooLarge;
            estimate.virtual_all_docs_saved_bytes = std.math.add(u64, estimate.virtual_all_docs_saved_bytes, context.delta_varint_doc_bytes) catch return error.RecordTooLarge;
        } else if (termEntryDenseAllDocsFreqStreamOffset(entry)) |posting_offset| {
            if (posting_offset != expected_postings_offset) return error.InvalidRecord;
            const next_postings_offset = try scanPersistentTermPostings(&catalog.postings_view, entry, catalog.doc_count, .none, &context, collectPostingCompressionEstimate);
            const dense_bytes = next_postings_offset - posting_offset;
            const regular_body_bytes = std.math.add(u64, context.delta_varint_doc_bytes, context.delta_varint_text_freq_bytes) catch return error.RecordTooLarge;
            if (regular_body_bytes < dense_bytes) return error.InvalidRecord;
            estimate.dense_all_docs_freq_stream_term_count = std.math.add(u64, estimate.dense_all_docs_freq_stream_term_count, 1) catch return error.RecordTooLarge;
            estimate.dense_all_docs_freq_stream_saved_bytes = std.math.add(u64, estimate.dense_all_docs_freq_stream_saved_bytes, regular_body_bytes - dense_bytes) catch return error.RecordTooLarge;
            expected_postings_offset = next_postings_offset;
        } else {
            if (entry.postings_offset != expected_postings_offset) return error.InvalidRecord;
            expected_postings_offset = try scanPersistentPostingRange(&catalog.postings_view, entry.postings_offset, entry.postings_count, catalog.doc_count, .none, &context, collectPostingCompressionEstimate);
        }
        if (context.postings_seen != entry.postings_count) return error.InvalidRecord;
        const ef_doc_bytes = try persistentEliasFanoDocBytes(catalog.doc_count, entry.postings_count);
        const ef_select_bytes = try persistentEliasFanoSelectCheckpointBytes(entry.postings_count);
        const ef_doc_with_select_bytes = std.math.add(u64, ef_doc_bytes, ef_select_bytes) catch return error.RecordTooLarge;
        estimate.elias_fano_doc_estimated_bytes = std.math.add(u64, estimate.elias_fano_doc_estimated_bytes, ef_doc_bytes) catch return error.RecordTooLarge;
        estimate.hybrid_doc_estimated_bytes = std.math.add(u64, estimate.hybrid_doc_estimated_bytes, @min(context.delta_varint_doc_bytes, ef_doc_bytes)) catch return error.RecordTooLarge;
        estimate.material_elias_fano_select_checkpoint_bytes = std.math.add(u64, estimate.material_elias_fano_select_checkpoint_bytes, ef_select_bytes) catch return error.RecordTooLarge;
        if (ef_doc_with_select_bytes < context.delta_varint_doc_bytes) {
            estimate.hybrid_select_aware_doc_with_select_estimated_bytes = std.math.add(u64, estimate.hybrid_select_aware_doc_with_select_estimated_bytes, ef_doc_with_select_bytes) catch return error.RecordTooLarge;
            estimate.hybrid_select_aware_ef_term_count = std.math.add(u64, estimate.hybrid_select_aware_ef_term_count, 1) catch return error.RecordTooLarge;
        } else {
            estimate.hybrid_select_aware_doc_with_select_estimated_bytes = std.math.add(u64, estimate.hybrid_select_aware_doc_with_select_estimated_bytes, context.delta_varint_doc_bytes) catch return error.RecordTooLarge;
            estimate.hybrid_select_aware_delta_term_count = std.math.add(u64, estimate.hybrid_select_aware_delta_term_count, 1) catch return error.RecordTooLarge;
        }
        if (ef_doc_bytes < context.delta_varint_doc_bytes) {
            estimate.elias_fano_better_term_count = std.math.add(u64, estimate.elias_fano_better_term_count, 1) catch return error.RecordTooLarge;
            estimate.material_hybrid_select_checkpoint_bytes = std.math.add(u64, estimate.material_hybrid_select_checkpoint_bytes, ef_select_bytes) catch return error.RecordTooLarge;
        } else if (ef_doc_bytes > context.delta_varint_doc_bytes) {
            estimate.elias_fano_worse_term_count = std.math.add(u64, estimate.elias_fano_worse_term_count, 1) catch return error.RecordTooLarge;
        }
    }
    if (expected_postings_offset != catalog.postings_header.body_bytes) return error.InvalidRecord;
    if (estimate.posting_count != catalog.postings_header.posting_count) return error.InvalidRecord;
    if (estimate.hybrid_select_aware_ef_term_count + estimate.hybrid_select_aware_delta_term_count != catalog.terms_header.term_count) return error.InvalidRecord;
    estimate.material_field_tag_bits_estimated_bytes = try persistentBitpackedBytes(estimate.posting_count, compressed_posting_field_tag_bits);
    estimate.material_block_jump_checkpoint_bytes = try textPostingBlockByteOffsetCheckpointTableBytes(catalog.blocks_header.block_count);
    estimate.material_hybrid_format_bits_bytes = try persistentBitpackedBytes(catalog.terms_header.term_count, 1);
    const material_sidecar_bytes = try persistentPostingMaterialSidecarBytes(estimate);
    estimate.elias_fano_material_estimated_bytes = std.math.add(u64, estimate.elias_fano_doc_estimated_bytes, material_sidecar_bytes) catch return error.RecordTooLarge;
    estimate.hybrid_material_estimated_bytes = std.math.add(u64, try std.math.add(u64, estimate.hybrid_doc_estimated_bytes, material_sidecar_bytes), estimate.material_hybrid_format_bits_bytes) catch return error.RecordTooLarge;
    estimate.elias_fano_material_with_select_estimated_bytes = std.math.add(u64, estimate.elias_fano_material_estimated_bytes, estimate.material_elias_fano_select_checkpoint_bytes) catch return error.RecordTooLarge;
    estimate.hybrid_material_with_select_estimated_bytes = std.math.add(u64, estimate.hybrid_material_estimated_bytes, estimate.material_hybrid_select_checkpoint_bytes) catch return error.RecordTooLarge;
    estimate.hybrid_select_aware_material_estimated_bytes = std.math.add(u64, try std.math.add(u64, estimate.hybrid_select_aware_doc_with_select_estimated_bytes, material_sidecar_bytes), estimate.material_hybrid_format_bits_bytes) catch return error.RecordTooLarge;
    return estimate;
}

const PostingCompressionEstimateContext = struct {
    estimate: *PersistentPostingCompressionEstimate,
    previous_doc_id: u64 = 0,
    compressed_previous_doc_id: u64 = 0,
    postings_seen: u64 = 0,
    delta_varint_doc_bytes: u64 = 0,
    delta_varint_text_freq_bytes: u64 = 0,
};

fn collectPostingCompressionEstimate(context: *PostingCompressionEstimateContext, posting: TextPostingRecord, _: u64) !void {
    if (posting.doc_id <= context.previous_doc_id) return error.InvalidRecord;
    if (context.postings_seen % persistent_posting_block_size == 0) context.compressed_previous_doc_id = 0;
    const doc_delta = posting.doc_id - context.compressed_previous_doc_id;
    context.previous_doc_id = posting.doc_id;
    context.compressed_previous_doc_id = posting.doc_id;
    context.postings_seen = std.math.add(u64, context.postings_seen, 1) catch return error.RecordTooLarge;

    const estimate = context.estimate;
    estimate.posting_count = std.math.add(u64, estimate.posting_count, 1) catch return error.RecordTooLarge;
    estimate.fixed_record_bytes = std.math.add(u64, estimate.fixed_record_bytes, TextPostingRecord.encoded_len) catch return error.RecordTooLarge;
    const field_tag = try compressedPostingFieldTag(posting);
    const doc_bytes = persistentVarintLen(try taggedCompressedPostingDelta(doc_delta, posting));
    context.delta_varint_doc_bytes = std.math.add(u64, context.delta_varint_doc_bytes, doc_bytes) catch return error.RecordTooLarge;
    estimate.delta_varint_doc_bytes = std.math.add(u64, estimate.delta_varint_doc_bytes, doc_bytes) catch return error.RecordTooLarge;
    if (compressedPostingTagTextExplicit(field_tag)) {
        const text_freq_bytes = persistentVarintLen(posting.text_freq);
        context.delta_varint_text_freq_bytes = std.math.add(u64, context.delta_varint_text_freq_bytes, text_freq_bytes) catch return error.RecordTooLarge;
        estimate.delta_varint_text_freq_bytes = std.math.add(u64, estimate.delta_varint_text_freq_bytes, text_freq_bytes) catch return error.RecordTooLarge;
    }
    var estimated_bytes = std.math.add(u64, estimate.delta_varint_doc_bytes, estimate.delta_varint_field_mask_bytes) catch return error.RecordTooLarge;
    estimated_bytes = std.math.add(u64, estimated_bytes, estimate.delta_varint_text_freq_bytes) catch return error.RecordTooLarge;
    estimated_bytes = std.math.add(u64, estimated_bytes, estimate.delta_varint_kind_freq_bytes) catch return error.RecordTooLarge;
    estimate.delta_varint_estimated_bytes = estimated_bytes;
    estimate.max_doc_delta = @max(estimate.max_doc_delta, doc_delta);
    estimate.max_text_freq = @max(estimate.max_text_freq, posting.text_freq);
    estimate.max_kind_freq = @max(estimate.max_kind_freq, posting.kind_freq);
    if (doc_delta > std.math.maxInt(u16)) {
        estimate.doc_delta_over_u16_count = std.math.add(u64, estimate.doc_delta_over_u16_count, 1) catch return error.RecordTooLarge;
    }
    if (posting.text_freq > std.math.maxInt(u8)) {
        estimate.text_freq_over_u8_count = std.math.add(u64, estimate.text_freq_over_u8_count, 1) catch return error.RecordTooLarge;
    }
}

fn floorLog2U64(value: u64) u6 {
    std.debug.assert(value != 0);
    return @intCast(63 - @clz(value));
}

fn persistentBitpackedBytes(count: u64, bits_per_value: u6) !u64 {
    if (bits_per_value == 0 or count == 0) return 0;
    const bits = std.math.mul(u64, count, bits_per_value) catch return error.RecordTooLarge;
    return std.math.divCeil(u64, bits, 8) catch return error.RecordTooLarge;
}

fn persistentPostingMaterialSidecarBytes(estimate: PersistentPostingCompressionEstimate) !u64 {
    var total = estimate.material_field_tag_bits_estimated_bytes;
    total = std.math.add(u64, total, estimate.delta_varint_text_freq_bytes) catch return error.RecordTooLarge;
    total = std.math.add(u64, total, estimate.delta_varint_kind_freq_bytes) catch return error.RecordTooLarge;
    total = std.math.add(u64, total, estimate.material_block_jump_checkpoint_bytes) catch return error.RecordTooLarge;
    return total;
}

fn persistentEliasFanoDocBytes(universe: u64, count: u64) !u64 {
    const layout = try persistentEliasFanoDocLayout(universe, count);
    return layout.doc_bytes;
}

const PersistentEliasFanoDocLayout = struct {
    lower_bits: u6,
    lower_bytes: u64,
    upper_bytes: u64,
    doc_bytes: u64,
};

fn persistentEliasFanoDocLayout(universe: u64, count: u64) !PersistentEliasFanoDocLayout {
    if (count == 0) return .{ .lower_bits = 0, .lower_bytes = 0, .upper_bytes = 0, .doc_bytes = 0 };
    if (universe == 0 or count > universe) return error.InvalidRecord;
    const ratio = @divFloor(universe, count);
    const lower_bits = if (ratio <= 1) 0 else floorLog2U64(ratio);
    const lower = std.math.mul(u64, count, lower_bits) catch return error.RecordTooLarge;
    const upper = std.math.add(u64, universe >> lower_bits, count) catch return error.RecordTooLarge;
    const upper_with_sentinel = std.math.add(u64, upper, 1) catch return error.RecordTooLarge;
    const total_bits = std.math.add(u64, lower, upper_with_sentinel) catch return error.RecordTooLarge;
    return .{
        .lower_bits = lower_bits,
        .lower_bytes = try std.math.divCeil(u64, lower, 8),
        .upper_bytes = try std.math.divCeil(u64, upper_with_sentinel, 8),
        .doc_bytes = try std.math.divCeil(u64, total_bits, 8),
    };
}

fn persistentEliasFanoSelectCheckpointBytes(count: u64) !u64 {
    if (count == 0) return 0;
    const checkpoints = try std.math.divCeil(u64, count, persistent_elias_fano_select_checkpoint_postings);
    return std.math.mul(u64, checkpoints, persistent_elias_fano_select_checkpoint_bytes) catch return error.RecordTooLarge;
}

fn encodePersistentEliasFanoDocIds(doc_ids: []const u64, universe: u64, out: []u8) !PersistentEliasFanoDocLayout {
    const count: u64 = @intCast(doc_ids.len);
    const layout = try persistentEliasFanoDocLayout(universe, count);
    if (out.len != layout.doc_bytes) return error.InvalidRecord;
    @memset(out, 0);
    if (count == 0) return layout;

    const lower_bit_count = std.math.mul(u64, count, layout.lower_bits) catch return error.RecordTooLarge;
    var previous_doc_id: u64 = 0;
    for (doc_ids, 0..) |doc_id, index| {
        if (doc_id <= previous_doc_id or doc_id > universe) return error.InvalidRecord;
        const value = doc_id - 1;
        if (layout.lower_bits != 0) {
            const lower_mask = (@as(u64, 1) << layout.lower_bits) - 1;
            try writePackedBits(out, std.math.mul(u64, @intCast(index), layout.lower_bits) catch return error.RecordTooLarge, layout.lower_bits, value & lower_mask);
        }
        const high = value >> layout.lower_bits;
        const upper_pos = std.math.add(u64, lower_bit_count, std.math.add(u64, high, @intCast(index)) catch return error.RecordTooLarge) catch return error.RecordTooLarge;
        try writePackedBits(out, upper_pos, 1, 1);
        previous_doc_id = doc_id;
    }
    return layout;
}

fn decodePersistentEliasFanoDocIdSlow(bytes: []const u8, universe: u64, count: u64, index: u64) !u64 {
    if (index >= count) return error.InvalidRecord;
    const layout = try persistentEliasFanoDocLayout(universe, count);
    if (bytes.len != layout.doc_bytes) return error.InvalidRecord;
    const lower_bit_count = std.math.mul(u64, count, layout.lower_bits) catch return error.RecordTooLarge;
    const upper_bit_count = std.math.add(u64, universe >> layout.lower_bits, count) catch return error.RecordTooLarge;
    const upper_with_sentinel = std.math.add(u64, upper_bit_count, 1) catch return error.RecordTooLarge;

    var seen: u64 = 0;
    var upper_pos: u64 = 0;
    while (upper_pos < upper_with_sentinel) : (upper_pos += 1) {
        const absolute_upper_bit = std.math.add(u64, lower_bit_count, upper_pos) catch return error.RecordTooLarge;
        if (try readPackedBits(bytes, absolute_upper_bit, 1) == 0) continue;
        if (seen == index) {
            const high = upper_pos - index;
            const low = if (layout.lower_bits == 0)
                0
            else
                try readPackedBits(bytes, std.math.mul(u64, index, layout.lower_bits) catch return error.RecordTooLarge, layout.lower_bits);
            const value = (high << layout.lower_bits) | low;
            const doc_id = std.math.add(u64, value, 1) catch return error.RecordTooLarge;
            if (doc_id == 0 or doc_id > universe) return error.InvalidRecord;
            return doc_id;
        }
        seen += 1;
    }
    return error.InvalidRecord;
}

fn writePackedBits(bytes: []u8, bit_offset: u64, bit_count: u6, value: u64) !void {
    if (bit_count == 0) return;
    if (bit_count < 64 and value >= (@as(u64, 1) << bit_count)) return error.RecordTooLarge;
    var bit: u6 = 0;
    while (bit < bit_count) : (bit += 1) {
        const absolute_bit = std.math.add(u64, bit_offset, bit) catch return error.RecordTooLarge;
        const byte_index = std.math.cast(usize, absolute_bit / 8) orelse return error.RecordTooLarge;
        if (byte_index >= bytes.len) return error.NoSpaceLeft;
        const mask: u8 = @as(u8, 1) << @intCast(absolute_bit % 8);
        if (((value >> bit) & 1) != 0) bytes[byte_index] |= mask;
    }
}

fn readPackedBits(bytes: []const u8, bit_offset: u64, bit_count: u6) !u64 {
    if (bit_count == 0) return 0;
    var value: u64 = 0;
    var bit: u6 = 0;
    while (bit < bit_count) : (bit += 1) {
        const absolute_bit = std.math.add(u64, bit_offset, bit) catch return error.RecordTooLarge;
        const byte_index = std.math.cast(usize, absolute_bit / 8) orelse return error.RecordTooLarge;
        if (byte_index >= bytes.len) return error.InvalidRecord;
        const mask: u8 = @as(u8, 1) << @intCast(absolute_bit % 8);
        if ((bytes[byte_index] & mask) != 0) value |= @as(u64, 1) << bit;
    }
    return value;
}

fn persistentVarintLen(value: anytype) u64 {
    var remaining: u64 = @intCast(value);
    var len: u64 = 1;
    while (remaining >= 0x80) {
        remaining >>= 7;
        len += 1;
    }
    return len;
}

const compressed_posting_max_encoded_len: usize = 24;

fn canVirtualizeAllDocsConstantTextFreqTerm(postings_count: u64, doc_count: u64, constant_text_freq: u32) bool {
    return constant_text_freq != 0 and doc_count >= persistent_all_docs_synthesis_min_postings and postings_count == doc_count;
}

fn virtualAllDocsConstantTextFreq(postings: []const TextPostingRecord, doc_count: u64) ?u32 {
    if (doc_count > std.math.maxInt(usize) or postings.len != @as(usize, @intCast(doc_count))) return null;
    if (doc_count < persistent_all_docs_synthesis_min_postings) return null;
    var text_freq: u32 = 0;
    for (postings, 0..) |posting, index| {
        if (posting.doc_id != @as(u64, @intCast(index + 1))) return null;
        if (posting.text_freq == 0 or posting.kind_freq != 0) return null;
        if (text_freq == 0) {
            text_freq = posting.text_freq;
        } else if (text_freq != posting.text_freq) {
            return null;
        }
    }
    return text_freq;
}

fn canDenseAllDocsFreqStream(postings: []const TextPostingRecord, doc_count: u64) bool {
    if (doc_count > std.math.maxInt(usize) or postings.len != @as(usize, @intCast(doc_count))) return false;
    if (doc_count < persistent_all_docs_synthesis_min_postings) return false;
    for (postings, 0..) |posting, index| {
        if (posting.doc_id != @as(u64, @intCast(index + 1))) return false;
        if (posting.text_freq == 0 or posting.kind_freq != 0) return false;
    }
    return true;
}

fn canUseDenseAllDocsFreqStream(postings_count: u64, doc_count: u64, all_name_only: bool, constant_text_freq: u32) bool {
    return all_name_only and constant_text_freq == 0 and doc_count >= persistent_all_docs_synthesis_min_postings and postings_count == doc_count;
}

fn validateDenseAllDocsTextFreq(freq: u64) !u32 {
    if (freq == 0 or freq > persistent_posting_max_field_freq) return error.InvalidRecord;
    return @intCast(freq);
}

fn encodePersistentVarint(value: u64, out: []u8) !usize {
    var remaining = value;
    var cursor: usize = 0;
    while (true) {
        if (cursor >= out.len) return error.NoSpaceLeft;
        var byte: u8 = @intCast(remaining & 0x7f);
        remaining >>= 7;
        if (remaining != 0) byte |= 0x80;
        out[cursor] = byte;
        cursor += 1;
        if (remaining == 0) return cursor;
    }
}

fn decodePersistentVarintFromBytes(bytes: []const u8, cursor: *usize) !u64 {
    var value: u64 = 0;
    var shift: u6 = 0;
    var count: usize = 0;
    while (true) {
        if (cursor.* >= bytes.len) return error.InvalidRecord;
        const byte = bytes[cursor.*];
        cursor.* += 1;
        if (shift == 63 and (byte & 0x7f) > 1) return error.InvalidRecord;
        value |= (@as(u64, byte & 0x7f) << shift);
        count += 1;
        if ((byte & 0x80) == 0) return value;
        if (count >= 10) return error.InvalidRecord;
        shift += 7;
    }
}

fn decodePersistentVarintFromFile(view: *TextPostingsFileView, cursor: *u64) !u64 {
    var value: u64 = 0;
    var shift: u6 = 0;
    var count: usize = 0;
    while (true) {
        const byte = try view.readByteAt(cursor.*);
        cursor.* = std.math.add(u64, cursor.*, 1) catch return error.InvalidRecord;
        if (shift == 63 and (byte & 0x7f) > 1) return error.InvalidRecord;
        value |= (@as(u64, byte & 0x7f) << shift);
        count += 1;
        if ((byte & 0x80) == 0) return value;
        if (count >= 10) return error.InvalidRecord;
        shift += 7;
    }
}

fn decodePersistentVarintFromTermsFile(view: *TextTermsFileView, cursor: *u64, end: u64) !u64 {
    var value: u64 = 0;
    var shift: u6 = 0;
    var count: usize = 0;
    while (true) {
        if (cursor.* >= end) return error.InvalidRecord;
        const byte = try view.readByteAt(cursor.*);
        cursor.* = std.math.add(u64, cursor.*, 1) catch return error.InvalidRecord;
        if (shift == 63 and (byte & 0x7f) > 1) return error.InvalidRecord;
        value |= (@as(u64, byte & 0x7f) << shift);
        count += 1;
        if ((byte & 0x80) == 0) return value;
        if (count >= 10) return error.InvalidRecord;
        shift += 7;
    }
}

fn encodeCompressedTextPosting(posting: TextPostingRecord, previous_doc_id: u64, out: []u8) !usize {
    if (posting.doc_id <= previous_doc_id) return error.InvalidRecord;
    try validateTextPostingFields(posting.doc_id, posting.text_freq, posting.kind_freq);
    var cursor: usize = 0;
    const field_tag = try compressedPostingFieldTag(posting);
    cursor += try encodePersistentVarint(try taggedCompressedPostingDelta(posting.doc_id - previous_doc_id, posting), out[cursor..]);
    if (compressedPostingTagTextExplicit(field_tag)) {
        cursor += try encodePersistentVarint(posting.text_freq, out[cursor..]);
    }
    return cursor;
}

fn compressedTextPostingBytesForTerm(postings: []const TextPostingRecord) !u64 {
    if (postings.len == 1 and canInlineSingletonPosting(postings[0])) return 0;
    var previous_doc_id: u64 = 0;
    var total: u64 = 0;
    var pos: usize = 0;
    while (pos < postings.len) {
        const block_len = @min(postings.len - pos, persistent_posting_block_capacity);
        const range = try compressedTextPostingBytesForRange(postings[pos..][0..block_len], 0);
        total = std.math.add(u64, total, range.bytes) catch return error.RecordTooLarge;
        if (range.last_doc_id <= previous_doc_id) return error.InvalidRecord;
        previous_doc_id = range.last_doc_id;
        pos += block_len;
    }
    return total;
}

fn publishedPostingBodyBytesForTerm(postings: []const TextPostingRecord, postings_offset: u64, postings_offset_is_plain: bool, postings_offset_is_dense_freq_stream: bool) !u64 {
    if (postings_offset_is_dense_freq_stream) return denseAllDocsFreqStreamBytesForPostings(postings);
    if (!postings_offset_is_plain and denseAllDocsFreqStreamOffset(@intCast(postings.len), postings_offset) != null) return denseAllDocsFreqStreamBytesForPostings(postings);
    if (!postings_offset_is_plain and postings.len > 1 and (postings_offset & persistent_term_inline_posting_marker) != 0) return 0;
    return compressedTextPostingBytesForTerm(postings);
}

const TermPostingPayloadOrBodyOffset = struct {
    offset: u64,
    is_plain: bool,
    is_dense_freq_stream: bool = false,
};

fn termPostingPayloadOrBodyOffset(postings: []const TextPostingRecord, body_offset: u64, doc_count: u64) !TermPostingPayloadOrBodyOffset {
    if (postings.len == 1 and canInlineSingletonPosting(postings[0])) {
        return .{ .offset = try encodeInlineSingletonPostingPayload(postings[0]), .is_plain = false };
    }
    if (virtualAllDocsConstantTextFreq(postings, doc_count)) |text_freq| {
        return .{ .offset = try encodeVirtualAllDocsPostingPayload(text_freq), .is_plain = false };
    }
    if (canDenseAllDocsFreqStream(postings, doc_count)) {
        return .{ .offset = body_offset, .is_plain = false, .is_dense_freq_stream = true };
    }
    return .{ .offset = body_offset, .is_plain = true };
}

fn textTermEntryFromPersistentTerm(term: PersistentTerm, front_prefix_len: ?u8) TextTermEntry {
    return .{
        .term_len = @intCast(term.term.len),
        .doc_freq = @intCast(term.postings.len),
        .postings_offset = term.postings_offset,
        .postings_count = @intCast(term.postings.len),
        .front_prefix_len = front_prefix_len,
        .postings_offset_is_plain = term.postings_offset_is_plain,
        .postings_offset_is_dense_freq_stream = term.postings_offset_is_dense_freq_stream,
    };
}

const CompressedPostingRangeBytes = struct {
    bytes: u64,
    last_doc_id: u64,
};

fn compressedTextPostingBytesForRange(postings: []const TextPostingRecord, initial_previous_doc_id: u64) !CompressedPostingRangeBytes {
    var previous_doc_id = initial_previous_doc_id;
    var total: u64 = 0;
    for (postings) |posting| {
        if (posting.doc_id <= previous_doc_id) return error.InvalidRecord;
        try validateTextPostingFields(posting.doc_id, posting.text_freq, posting.kind_freq);
        const field_tag = try compressedPostingFieldTag(posting);
        total = std.math.add(u64, total, persistentVarintLen(try taggedCompressedPostingDelta(posting.doc_id - previous_doc_id, posting))) catch return error.RecordTooLarge;
        if (compressedPostingTagTextExplicit(field_tag)) {
            total = std.math.add(u64, total, persistentVarintLen(posting.text_freq)) catch return error.RecordTooLarge;
        }
        previous_doc_id = posting.doc_id;
    }
    return .{ .bytes = total, .last_doc_id = previous_doc_id };
}

fn decodeCompressedTextPostingFromBytes(bytes: []const u8, cursor: *usize, previous_doc_id: u64) !TextPostingRecord {
    const tagged_delta = try decodeTaggedCompressedPostingDelta(try decodePersistentVarintFromBytes(bytes, cursor));
    const text_freq: u32 = compressedPostingTagInlineTextFreq(tagged_delta.field_tag) orelse if (compressedPostingTagTextExplicit(tagged_delta.field_tag))
        try validateCompressedPostingExplicitFreq(tagged_delta.field_tag, try decodePersistentVarintFromBytes(bytes, cursor))
    else
        0;
    const kind_freq: u32 = 0;
    const doc_id = std.math.add(u64, previous_doc_id, tagged_delta.doc_delta) catch return error.RecordTooLarge;
    try validateTextPostingFields(doc_id, text_freq, kind_freq);
    return .{ .doc_id = doc_id, .text_freq = text_freq, .kind_freq = kind_freq };
}

fn decodeCompressedTextPostingFromFile(view: *TextPostingsFileView, cursor: *u64, previous_doc_id: u64) !TextPostingRecord {
    const tagged_delta = try decodeTaggedCompressedPostingDelta(try decodePersistentVarintFromFile(view, cursor));
    const text_freq: u32 = compressedPostingTagInlineTextFreq(tagged_delta.field_tag) orelse if (compressedPostingTagTextExplicit(tagged_delta.field_tag))
        try validateCompressedPostingExplicitFreq(tagged_delta.field_tag, try decodePersistentVarintFromFile(view, cursor))
    else
        0;
    const kind_freq: u32 = 0;
    const doc_id = std.math.add(u64, previous_doc_id, tagged_delta.doc_delta) catch return error.RecordTooLarge;
    try validateTextPostingFields(doc_id, text_freq, kind_freq);
    return .{ .doc_id = doc_id, .text_freq = text_freq, .kind_freq = kind_freq };
}

fn denseAllDocsFreqGroupTagBytes(group_count: usize) !usize {
    if (group_count == 0 or group_count > persistent_dense_all_docs_freq_group_size) return error.InvalidRecord;
    const bits = std.math.mul(usize, group_count, compressed_posting_field_tag_bits) catch return error.RecordTooLarge;
    return std.math.divCeil(usize, bits, 8) catch return error.RecordTooLarge;
}

fn denseAllDocsFreqPackedBytesForPostings(postings: []const TextPostingRecord) !u64 {
    var total: u64 = 1;
    var pos: usize = 0;
    while (pos < postings.len) {
        const group_count = @min(postings.len - pos, persistent_dense_all_docs_freq_group_size);
        total = std.math.add(u64, total, try denseAllDocsFreqGroupTagBytes(group_count)) catch return error.RecordTooLarge;
        for (postings[pos..][0..group_count]) |posting| {
            const field_tag = try compressedPostingFieldTag(posting);
            if (compressedPostingTagTextExplicit(field_tag)) {
                total = std.math.add(u64, total, persistentVarintLen(posting.text_freq)) catch return error.RecordTooLarge;
            }
        }
        pos += group_count;
    }
    return total;
}

fn denseAllDocsFreqRleBytesForPostings(postings: []const TextPostingRecord) !u64 {
    var total: u64 = 1;
    var previous_freq: u32 = 0;
    var run_len: u64 = 0;
    for (postings) |posting| {
        if (posting.text_freq == 0 or posting.kind_freq != 0) return error.InvalidRecord;
        if (posting.text_freq == previous_freq) {
            run_len = std.math.add(u64, run_len, 1) catch return error.RecordTooLarge;
            continue;
        }
        if (run_len != 0) {
            total = std.math.add(u64, total, persistentVarintLen(run_len)) catch return error.RecordTooLarge;
            total = std.math.add(u64, total, persistentVarintLen(previous_freq)) catch return error.RecordTooLarge;
        }
        previous_freq = posting.text_freq;
        run_len = 1;
    }
    if (run_len != 0) {
        total = std.math.add(u64, total, persistentVarintLen(run_len)) catch return error.RecordTooLarge;
        total = std.math.add(u64, total, persistentVarintLen(previous_freq)) catch return error.RecordTooLarge;
    }
    return total;
}

fn denseAllDocsFreqBitpackedBits(max_freq: u32) !u6 {
    if (max_freq == 0 or max_freq > persistent_posting_max_field_freq) return error.InvalidRecord;
    return @intCast(32 - @clz(max_freq));
}

fn denseAllDocsFreqBitpackedBytes(count: u64, max_freq: u32) !u64 {
    const bits = try denseAllDocsFreqBitpackedBits(max_freq);
    const payload_bits = std.math.mul(u64, count, bits) catch return error.RecordTooLarge;
    const payload_bytes = try std.math.divCeil(u64, payload_bits, 8);
    return std.math.add(u64, 2, payload_bytes) catch return error.RecordTooLarge;
}

fn denseAllDocsFreqBitpackedBytesForPostings(postings: []const TextPostingRecord) !u64 {
    if (postings.len == 0) return error.InvalidRecord;
    var max_freq: u32 = 0;
    for (postings) |posting| {
        if (posting.text_freq == 0 or posting.kind_freq != 0) return error.InvalidRecord;
        max_freq = @max(max_freq, posting.text_freq);
    }
    return denseAllDocsFreqBitpackedBytes(@intCast(postings.len), max_freq);
}

fn denseAllDocsFreqStreamBytesForPostings(postings: []const TextPostingRecord) !u64 {
    return @min(
        @min(try denseAllDocsFreqPackedBytesForPostings(postings), try denseAllDocsFreqRleBytesForPostings(postings)),
        try denseAllDocsFreqBitpackedBytesForPostings(postings),
    );
}

fn denseAllDocsFreqPackedBytesForFreqs(freqs: anytype) !u64 {
    var total: u64 = 1;
    var pos: usize = 0;
    while (pos < freqs.len) {
        const group_count = @min(freqs.len - pos, persistent_dense_all_docs_freq_group_size);
        total = std.math.add(u64, total, try denseAllDocsFreqGroupTagBytes(group_count)) catch return error.RecordTooLarge;
        for (freqs[pos..][0..group_count]) |freq_raw| {
            const freq: u32 = @intCast(freq_raw);
            const field_tag = try compressedPostingTextFreqTag(freq);
            if (compressedPostingTagTextExplicit(field_tag)) {
                total = std.math.add(u64, total, persistentVarintLen(freq)) catch return error.RecordTooLarge;
            }
        }
        pos += group_count;
    }
    return total;
}

fn denseAllDocsFreqRleBytesForFreqs(freqs: anytype) !u64 {
    var total: u64 = 1;
    var previous_freq: u32 = 0;
    var run_len: u64 = 0;
    for (freqs) |freq_raw| {
        const freq: u32 = @intCast(freq_raw);
        if (freq == 0) return error.InvalidRecord;
        if (freq == previous_freq) {
            run_len = std.math.add(u64, run_len, 1) catch return error.RecordTooLarge;
            continue;
        }
        if (run_len != 0) {
            total = std.math.add(u64, total, persistentVarintLen(run_len)) catch return error.RecordTooLarge;
            total = std.math.add(u64, total, persistentVarintLen(previous_freq)) catch return error.RecordTooLarge;
        }
        previous_freq = freq;
        run_len = 1;
    }
    if (run_len != 0) {
        total = std.math.add(u64, total, persistentVarintLen(run_len)) catch return error.RecordTooLarge;
        total = std.math.add(u64, total, persistentVarintLen(previous_freq)) catch return error.RecordTooLarge;
    }
    return total;
}

fn denseAllDocsFreqBitpackedBytesForFreqs(freqs: anytype) !u64 {
    if (freqs.len == 0) return error.InvalidRecord;
    var max_freq: u32 = 0;
    for (freqs) |freq_raw| {
        const freq: u32 = @intCast(freq_raw);
        if (freq == 0) return error.InvalidRecord;
        max_freq = @max(max_freq, freq);
    }
    return denseAllDocsFreqBitpackedBytes(@intCast(freqs.len), max_freq);
}

const DenseAllDocsFreqStreamSizeStats = struct {
    packed_bytes: u64,
    rle_bytes: u64,
    bitpacked_bytes: u64,
    rle_run_count: u64,
    max_freq: u32,
};

fn denseAllDocsFreqStreamSizeStatsForFreqs(freqs: anytype) !DenseAllDocsFreqStreamSizeStats {
    if (freqs.len == 0) return error.InvalidRecord;
    var packed_bytes: u64 = 1;
    var rle_bytes: u64 = 1;
    var max_freq: u32 = 0;
    var previous_freq: u32 = 0;
    var run_len: u64 = 0;
    var rle_run_count: u64 = 0;

    for (freqs, 0..) |freq_raw, index| {
        if (index % persistent_dense_all_docs_freq_group_size == 0) {
            const remaining = freqs.len - index;
            const group_count = @min(remaining, persistent_dense_all_docs_freq_group_size);
            packed_bytes = std.math.add(u64, packed_bytes, try denseAllDocsFreqGroupTagBytes(group_count)) catch return error.RecordTooLarge;
        }

        const freq: u32 = @intCast(freq_raw);
        if (freq == 0) return error.InvalidRecord;
        max_freq = @max(max_freq, freq);

        const field_tag = try compressedPostingTextFreqTag(freq);
        if (compressedPostingTagTextExplicit(field_tag)) {
            packed_bytes = std.math.add(u64, packed_bytes, persistentVarintLen(freq)) catch return error.RecordTooLarge;
        }

        if (freq == previous_freq) {
            run_len = std.math.add(u64, run_len, 1) catch return error.RecordTooLarge;
            continue;
        }
        if (run_len != 0) {
            rle_run_count = std.math.add(u64, rle_run_count, 1) catch return error.RecordTooLarge;
            rle_bytes = std.math.add(u64, rle_bytes, persistentVarintLen(run_len)) catch return error.RecordTooLarge;
            rle_bytes = std.math.add(u64, rle_bytes, persistentVarintLen(previous_freq)) catch return error.RecordTooLarge;
        }
        previous_freq = freq;
        run_len = 1;
    }
    if (run_len != 0) {
        rle_run_count = std.math.add(u64, rle_run_count, 1) catch return error.RecordTooLarge;
        rle_bytes = std.math.add(u64, rle_bytes, persistentVarintLen(run_len)) catch return error.RecordTooLarge;
        rle_bytes = std.math.add(u64, rle_bytes, persistentVarintLen(previous_freq)) catch return error.RecordTooLarge;
    }

    return .{
        .packed_bytes = packed_bytes,
        .rle_bytes = rle_bytes,
        .bitpacked_bytes = try denseAllDocsFreqBitpackedBytes(@intCast(freqs.len), max_freq),
        .rle_run_count = rle_run_count,
        .max_freq = max_freq,
    };
}

fn appendDenseAllDocsFreqBitpackedValues(writer: *TextBufferedWriter, comptime T: type, freqs: []const T, max_freq: u32) !u64 {
    const bits = try denseAllDocsFreqBitpackedBits(max_freq);
    try writer.append(&.{ persistent_dense_all_docs_freq_mode_bitpacked, bits });
    var written: u64 = 2;
    var out: [4096]u8 = undefined;
    var out_bit: u64 = 0;
    @memset(&out, 0);
    for (freqs) |freq_value| {
        const freq: u32 = @intCast(freq_value);
        if (freq == 0 or freq > max_freq) return error.InvalidRecord;
        if (out_bit + bits > out.len * 8) {
            const flush_len: usize = @intCast(out_bit / 8);
            try writer.append(out[0..flush_len]);
            written = std.math.add(u64, written, flush_len) catch return error.RecordTooLarge;
            const carry_bits: u6 = @intCast(out_bit % 8);
            if (carry_bits != 0) {
                out[0] = out[flush_len] & ((@as(u8, 1) << @as(u3, @intCast(carry_bits))) - 1);
                @memset(out[1..], 0);
                out_bit = carry_bits;
            } else {
                @memset(&out, 0);
                out_bit = 0;
            }
        }
        try writePackedBits(&out, out_bit, bits, freq);
        out_bit += bits;
    }
    const final_len = try std.math.divCeil(u64, out_bit, 8);
    if (final_len != 0) {
        try writer.append(out[0..@intCast(final_len)]);
        written = std.math.add(u64, written, final_len) catch return error.RecordTooLarge;
    }
    return written;
}

fn appendDenseAllDocsFreqBitpackedPostings(writer: *TextBufferedWriter, postings: []const TextPostingRecord, max_freq: u32) !u64 {
    const bits = try denseAllDocsFreqBitpackedBits(max_freq);
    try writer.append(&.{ persistent_dense_all_docs_freq_mode_bitpacked, bits });
    var written: u64 = 2;
    var out: [4096]u8 = undefined;
    var out_bit: u64 = 0;
    @memset(&out, 0);
    for (postings) |posting| {
        if (posting.text_freq == 0 or posting.kind_freq != 0 or posting.text_freq > max_freq) return error.InvalidRecord;
        if (out_bit + bits > out.len * 8) {
            const flush_len: usize = @intCast(out_bit / 8);
            try writer.append(out[0..flush_len]);
            written = std.math.add(u64, written, flush_len) catch return error.RecordTooLarge;
            const carry_bits: u6 = @intCast(out_bit % 8);
            if (carry_bits != 0) {
                out[0] = out[flush_len] & ((@as(u8, 1) << @as(u3, @intCast(carry_bits))) - 1);
                @memset(out[1..], 0);
                out_bit = carry_bits;
            } else {
                @memset(&out, 0);
                out_bit = 0;
            }
        }
        try writePackedBits(&out, out_bit, bits, posting.text_freq);
        out_bit += bits;
    }
    const final_len = try std.math.divCeil(u64, out_bit, 8);
    if (final_len != 0) {
        try writer.append(out[0..@intCast(final_len)]);
        written = std.math.add(u64, written, final_len) catch return error.RecordTooLarge;
    }
    return written;
}

fn encodeDenseAllDocsFreqGroup(tags: []const u8, out: []u8) !usize {
    const tag_bytes = try denseAllDocsFreqGroupTagBytes(tags.len);
    if (out.len < tag_bytes) return error.NoSpaceLeft;
    @memset(out[0..tag_bytes], 0);
    for (tags, 0..) |tag, index| {
        if (tag > compressed_posting_field_tag_mask) return error.InvalidRecord;
        try writePackedBits(out[0..tag_bytes], std.math.mul(u64, @intCast(index), compressed_posting_field_tag_bits) catch return error.RecordTooLarge, compressed_posting_field_tag_bits, tag);
    }
    return tag_bytes;
}

fn decodeDenseAllDocsFreqGroupTag(bytes: []const u8, group_count: usize, index: usize) !u8 {
    const tag_bytes = try denseAllDocsFreqGroupTagBytes(group_count);
    if (bytes.len < tag_bytes or index >= group_count) return error.InvalidRecord;
    return @intCast(try readPackedBits(bytes[0..tag_bytes], std.math.mul(u64, @intCast(index), compressed_posting_field_tag_bits) catch return error.RecordTooLarge, compressed_posting_field_tag_bits));
}

fn collectDenseAllDocsFreqPosting(
    doc_index: u64,
    text_freq: u32,
    posting_count: u64,
    doc_count: u64,
    guard: TextPostingScanGuard,
    previous_doc_id: *u64,
    context: anytype,
    comptime callback: fn (@TypeOf(context), TextPostingRecord, u64) anyerror!void,
) !void {
    const posting = TextPostingRecord{ .doc_id = doc_index + 1, .text_freq = text_freq, .kind_freq = 0 };
    try validateTextPostingFields(posting.doc_id, posting.text_freq, posting.kind_freq);
    try guardBeforeTextPosting(guard);
    try validateScannedTextPosting(posting, previous_doc_id, doc_count);
    try callback(context, posting, posting_count);
}

fn scanDenseAllDocsFreqStreamBytes(
    bytes: []const u8,
    posting_count: u64,
    doc_count: u64,
    guard: TextPostingScanGuard,
    context: anytype,
    comptime callback: fn (@TypeOf(context), TextPostingRecord, u64) anyerror!void,
) !u64 {
    if (posting_count != doc_count) return error.InvalidRecord;
    if (bytes.len == 0) return error.InvalidRecord;
    const mode = bytes[0];
    var cursor: usize = 1;
    var doc_index: u64 = 0;
    var previous_doc_id: u64 = 0;
    switch (mode) {
        persistent_dense_all_docs_freq_mode_packed => while (doc_index < posting_count) {
            const remaining = posting_count - doc_index;
            const group_count: usize = @intCast(@min(remaining, persistent_dense_all_docs_freq_group_size));
            const tag_bytes = try denseAllDocsFreqGroupTagBytes(group_count);
            if (cursor > bytes.len or tag_bytes > bytes.len - cursor) return error.InvalidRecord;
            const tags = bytes[cursor .. cursor + tag_bytes];
            cursor += tag_bytes;
            var local: usize = 0;
            while (local < group_count) : (local += 1) {
                const field_tag = try decodeDenseAllDocsFreqGroupTag(tags, group_count, local);
                const text_freq: u32 = compressedPostingTagInlineTextFreq(field_tag) orelse if (compressedPostingTagTextExplicit(field_tag))
                    try validateCompressedPostingExplicitFreq(field_tag, try decodePersistentVarintFromBytes(bytes, &cursor))
                else
                    0;
                try collectDenseAllDocsFreqPosting(doc_index + @as(u64, @intCast(local)), text_freq, posting_count, doc_count, guard, &previous_doc_id, context, callback);
            }
            doc_index += group_count;
        },
        persistent_dense_all_docs_freq_mode_rle => while (doc_index < posting_count) {
            const run_len = try decodePersistentVarintFromBytes(bytes, &cursor);
            if (run_len == 0 or run_len > posting_count - doc_index) return error.InvalidRecord;
            const text_freq = try validateDenseAllDocsTextFreq(try decodePersistentVarintFromBytes(bytes, &cursor));
            var local: u64 = 0;
            while (local < run_len) : (local += 1) {
                try collectDenseAllDocsFreqPosting(doc_index + local, text_freq, posting_count, doc_count, guard, &previous_doc_id, context, callback);
            }
            doc_index += run_len;
        },
        persistent_dense_all_docs_freq_mode_bitpacked => {
            if (cursor >= bytes.len) return error.InvalidRecord;
            const bits: u6 = @intCast(bytes[cursor]);
            cursor += 1;
            if (bits == 0 or bits > 16) return error.InvalidRecord;
            const payload_bits = std.math.mul(u64, posting_count, bits) catch return error.RecordTooLarge;
            const payload_bytes = try std.math.divCeil(u64, payload_bits, 8);
            const payload_len = std.math.cast(usize, payload_bytes) orelse return error.RecordTooLarge;
            if (payload_len > bytes.len - cursor) return error.InvalidRecord;
            const payload = bytes[cursor .. cursor + payload_len];
            while (doc_index < posting_count) : (doc_index += 1) {
                const bit_offset = std.math.mul(u64, doc_index, bits) catch return error.RecordTooLarge;
                const text_freq = try validateDenseAllDocsTextFreq(try readPackedBits(payload, bit_offset, bits));
                try collectDenseAllDocsFreqPosting(doc_index, text_freq, posting_count, doc_count, guard, &previous_doc_id, context, callback);
            }
            cursor += payload_len;
        },
        else => return error.InvalidRecord,
    }
    return @intCast(cursor);
}

fn scanDenseAllDocsFreqBitpackedFile(
    view: *TextPostingsFileView,
    cursor: *u64,
    posting_count: u64,
    doc_count: u64,
    guard: TextPostingScanGuard,
    previous_doc_id: *u64,
    context: anytype,
    comptime callback: fn (@TypeOf(context), TextPostingRecord, u64) anyerror!void,
) !void {
    const bits_byte = try view.readByteAt(cursor.*);
    cursor.* = std.math.add(u64, cursor.*, 1) catch return error.RecordTooLarge;
    const bits: u6 = @intCast(bits_byte);
    if (bits == 0 or bits > 16) return error.InvalidRecord;
    const payload_bits = std.math.mul(u64, posting_count, bits) catch return error.RecordTooLarge;
    const payload_bytes = try std.math.divCeil(u64, payload_bits, 8);
    var doc_index: u64 = 0;
    var bytes: [3]u8 = undefined;
    while (doc_index < posting_count) : (doc_index += 1) {
        const global_bit = std.math.mul(u64, doc_index, bits) catch return error.RecordTooLarge;
        const byte_offset = global_bit / 8;
        const local_bit: u6 = @intCast(global_bit % 8);
        const available = payload_bytes - byte_offset;
        const read_len: usize = @intCast(@min(available, bytes.len));
        const n = try view.file.readPositionalAll(view.io, bytes[0..read_len], cursor.* + byte_offset);
        if (n != read_len) return error.InvalidRecord;
        const text_freq = try validateDenseAllDocsTextFreq(try readPackedBits(bytes[0..read_len], local_bit, bits));
        try collectDenseAllDocsFreqPosting(doc_index, text_freq, posting_count, doc_count, guard, previous_doc_id, context, callback);
    }
    cursor.* = std.math.add(u64, cursor.*, payload_bytes) catch return error.RecordTooLarge;
}

fn scanDenseAllDocsFreqStreamFile(
    view: *TextPostingsFileView,
    posting_offset: u64,
    posting_count: u64,
    doc_count: u64,
    guard: TextPostingScanGuard,
    context: anytype,
    comptime callback: fn (@TypeOf(context), TextPostingRecord, u64) anyerror!void,
) !u64 {
    if (posting_count != doc_count) return error.InvalidRecord;
    var cursor = try textPostingBodyOffset(posting_offset);
    const mode = try view.readByteAt(cursor);
    cursor = std.math.add(u64, cursor, 1) catch return error.RecordTooLarge;
    var doc_index: u64 = 0;
    var previous_doc_id: u64 = 0;
    var tag_bytes_buf: [3]u8 = undefined;
    switch (mode) {
        persistent_dense_all_docs_freq_mode_packed => while (doc_index < posting_count) {
            const remaining = posting_count - doc_index;
            const group_count: usize = @intCast(@min(remaining, persistent_dense_all_docs_freq_group_size));
            const tag_bytes = try denseAllDocsFreqGroupTagBytes(group_count);
            const n = try view.file.readPositionalAll(view.io, tag_bytes_buf[0..tag_bytes], cursor);
            if (n != tag_bytes) return error.InvalidRecord;
            cursor = std.math.add(u64, cursor, tag_bytes) catch return error.RecordTooLarge;
            var local: usize = 0;
            while (local < group_count) : (local += 1) {
                const field_tag = try decodeDenseAllDocsFreqGroupTag(tag_bytes_buf[0..tag_bytes], group_count, local);
                const text_freq: u32 = compressedPostingTagInlineTextFreq(field_tag) orelse if (compressedPostingTagTextExplicit(field_tag))
                    try validateCompressedPostingExplicitFreq(field_tag, try decodePersistentVarintFromFile(view, &cursor))
                else
                    0;
                try collectDenseAllDocsFreqPosting(doc_index + @as(u64, @intCast(local)), text_freq, posting_count, doc_count, guard, &previous_doc_id, context, callback);
            }
            doc_index += group_count;
        },
        persistent_dense_all_docs_freq_mode_rle => while (doc_index < posting_count) {
            const run_len = try decodePersistentVarintFromFile(view, &cursor);
            if (run_len == 0 or run_len > posting_count - doc_index) return error.InvalidRecord;
            const text_freq = try validateDenseAllDocsTextFreq(try decodePersistentVarintFromFile(view, &cursor));
            var local: u64 = 0;
            while (local < run_len) : (local += 1) {
                try collectDenseAllDocsFreqPosting(doc_index + local, text_freq, posting_count, doc_count, guard, &previous_doc_id, context, callback);
            }
            doc_index += run_len;
        },
        persistent_dense_all_docs_freq_mode_bitpacked => try scanDenseAllDocsFreqBitpackedFile(
            view,
            &cursor,
            posting_count,
            doc_count,
            guard,
            &previous_doc_id,
            context,
            callback,
        ),
        else => return error.InvalidRecord,
    }
    return cursor - TextPostingsHeader.encoded_len;
}

const SkipTextPostingContext = struct {};

fn skipTextPosting(_: *SkipTextPostingContext, _: TextPostingRecord, _: u64) !void {}

const PersistentPostingCatalog = struct {
    doc_count: u64,
    terms_view: TextTermsFileView,
    terms_header: TextTermsHeader,
    postings_view: TextPostingsFileView,
    postings_header: TextPostingsHeader,
    blocks_view: TextPostingBlocksFileView,
    blocks_header: TextPostingBlocksHeader,
    impacts_view: TextPostingBlockImpactsFileView,
    impacts_header: TextPostingBlockImpactsHeader,

    pub fn open(allocator: std.mem.Allocator, store: storage_mod.Store, doc_count: u64) !PersistentPostingCatalog {
        const terms_path = try textTermsPath(allocator, store);
        defer allocator.free(terms_path);
        var terms_view = try TextTermsFileView.open(store, terms_path);
        errdefer terms_view.deinit();
        const terms_header = try terms_view.readHeader();
        const expected_terms_size = textTermsFileSizeForHeader(terms_header) catch |err| switch (err) {
            error.RecordTooLarge => return error.InvalidRecord,
            else => |e| return e,
        };
        if (terms_view.size != expected_terms_size) return error.InvalidRecord;

        const postings_path = try textPostingsPath(allocator, store);
        defer allocator.free(postings_path);
        var postings_view = try TextPostingsFileView.open(store, postings_path);
        errdefer postings_view.deinit();
        const postings_header = try postings_view.readHeader();
        const expected_postings_size = textPostingsFileSize(postings_header.body_bytes) catch |err| switch (err) {
            error.RecordTooLarge => return error.InvalidRecord,
            else => |e| return e,
        };
        if (postings_view.size != expected_postings_size) return error.InvalidRecord;

        const blocks_path = try textPostingBlocksPath(allocator, store);
        defer allocator.free(blocks_path);
        var blocks_view = try TextPostingBlocksFileView.open(store, blocks_path);
        errdefer blocks_view.deinit();
        const blocks_header = try blocks_view.readHeader();
        if (blocks_header.term_count != terms_header.term_count) return error.InvalidRecord;
        if (blocks_header.posting_count != postings_header.posting_count) return error.InvalidRecord;
        if (blocks_header.block_size != persistent_posting_block_size) return error.InvalidRecord;
        const expected_blocks_size = textPostingBlocksFileSize(blocks_header.term_count, blocks_header.block_count) catch |err| switch (err) {
            error.RecordTooLarge => return error.InvalidRecord,
            else => |e| return e,
        };
        if (blocks_view.size != expected_blocks_size) return error.InvalidRecord;

        const impacts_path = try textPostingBlockImpactsPath(allocator, store);
        defer allocator.free(impacts_path);
        var impacts_view = try TextPostingBlockImpactsFileView.open(store, impacts_path);
        errdefer impacts_view.deinit();
        const impacts_header = try impacts_view.readHeader();
        if (impacts_header.term_count != terms_header.term_count) return error.InvalidRecord;
        if (impacts_header.block_count != blocks_header.block_count) return error.InvalidRecord;
        const expected_impacts_size = textPostingBlockImpactsFileSize(impacts_header.term_count, impacts_header.block_count) catch |err| switch (err) {
            error.RecordTooLarge => return error.InvalidRecord,
            else => |e| return e,
        };
        if (impacts_view.size != expected_impacts_size) return error.InvalidRecord;

        return .{
            .doc_count = doc_count,
            .terms_view = terms_view,
            .terms_header = terms_header,
            .postings_view = postings_view,
            .postings_header = postings_header,
            .blocks_view = blocks_view,
            .blocks_header = blocks_header,
            .impacts_view = impacts_view,
            .impacts_header = impacts_header,
        };
    }

    pub fn deinit(self: *PersistentPostingCatalog) void {
        self.impacts_view.deinit();
        self.blocks_view.deinit();
        self.postings_view.deinit();
        self.terms_view.deinit();
    }

    const TermLookup = struct {
        index: u64,
        entry: TextTermEntry,
    };

    pub fn findTermEntry(self: *PersistentPostingCatalog, term: []const u8) !?TermLookup {
        var lo: u64 = 0;
        var hi: u64 = self.terms_header.term_count;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const entry = try self.terms_view.readEntryAt(self.terms_header, mid);
            const order = try self.terms_view.termEntryOrder(self.terms_header, mid, entry, term);
            if (order == .lt) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }

        if (lo >= self.terms_header.term_count) {
            if (self.terms_header.term_count > 0) try self.validateTermOrderAt(self.terms_header.term_count - 1);
            return null;
        }
        try self.validateTermOrderAt(lo);
        const entry = try self.terms_view.readEntryAt(self.terms_header, lo);
        if ((try self.terms_view.termEntryOrder(self.terms_header, lo, entry, term)) != .eq) return null;
        if (!termEntryHasInlinePosting(entry) and termEntryVirtualAllDocsTextFreq(entry) == null) {
            const body_offset = termEntryDenseAllDocsFreqStreamOffset(entry) orelse entry.postings_offset;
            if (body_offset > self.postings_header.body_bytes) return error.InvalidRecord;
        }
        return .{ .index = lo, .entry = entry };
    }

    fn validateTermOrderAt(self: *PersistentPostingCatalog, index: u64) !void {
        if (index >= self.terms_header.term_count) return error.InvalidRecord;
        const entry = try self.terms_view.readEntryAt(self.terms_header, index);
        if (index > 0) {
            const previous = try self.terms_view.readEntryAt(self.terms_header, index - 1);
            if ((try self.terms_view.termEntryEntryOrder(self.terms_header, index - 1, previous, index, entry)) != .lt) return error.InvalidRecord;
        }
        if (index + 1 < self.terms_header.term_count) {
            const next = try self.terms_view.readEntryAt(self.terms_header, index + 1);
            if ((try self.terms_view.termEntryEntryOrder(self.terms_header, index, entry, index + 1, next)) != .lt) return error.InvalidRecord;
        }
    }

    pub fn termBlockOffset(self: *PersistentPostingCatalog, term_index: u64) !u64 {
        if (term_index >= self.blocks_header.term_count) return error.InvalidRecord;
        const checkpoint_index = term_index / persistent_posting_block_offset_checkpoint_terms;
        const checkpoint_term = checkpoint_index * persistent_posting_block_offset_checkpoint_terms;
        var offset = try self.blocks_view.readTermBlockOffsetCheckpoint(self.blocks_header.block_count, checkpoint_index);
        if (offset > self.blocks_header.block_count) return error.InvalidRecord;
        var pos = checkpoint_term;
        while (pos < term_index) : (pos += 1) {
            const entry = try self.terms_view.readEntryAt(self.terms_header, pos);
            const term_block_count = try publishedPostingBlockCountForEntry(entry, self.blocks_header.block_size);
            offset = std.math.add(u64, offset, term_block_count) catch return error.RecordTooLarge;
            if (offset > self.blocks_header.block_count) return error.InvalidRecord;
        }
        return offset;
    }

    pub fn blockPostingOffset(self: *PersistentPostingCatalog, entry: TextTermEntry, term_block_offset: u64, local_block_index: u64) !u64 {
        if (termEntryHasInlinePosting(entry)) return error.InvalidRecord;
        const term_block_count = try publishedPostingBlockCountForEntry(entry, self.blocks_header.block_size);
        if (local_block_index >= term_block_count) return error.InvalidRecord;
        const global_block_index = std.math.add(u64, term_block_offset, local_block_index) catch return error.RecordTooLarge;
        if (global_block_index >= self.blocks_header.block_count) return error.InvalidRecord;

        const checkpoint_global_block = (global_block_index / persistent_posting_block_byte_offset_checkpoint_blocks) * persistent_posting_block_byte_offset_checkpoint_blocks;
        var scan_local_block: u64 = 0;
        var relative_posting_offset: u64 = 0;
        if (checkpoint_global_block >= term_block_offset) {
            const checkpoint_index = checkpoint_global_block / persistent_posting_block_byte_offset_checkpoint_blocks;
            scan_local_block = checkpoint_global_block - term_block_offset;
            if (scan_local_block > local_block_index) return error.InvalidRecord;
            relative_posting_offset = try self.blocks_view.readBlockByteOffsetCheckpoint(self.blocks_header.term_count, self.blocks_header.block_count, checkpoint_index);
        }
        if (entry.postings_offset > self.postings_header.body_bytes or relative_posting_offset > self.postings_header.body_bytes - entry.postings_offset) return error.InvalidRecord;

        while (scan_local_block < local_block_index) : (scan_local_block += 1) {
            const block_posting_count = try persistentBlockPostingCount(entry.postings_count, scan_local_block, self.blocks_header.block_size);
            const block_posting_offset = std.math.add(u64, entry.postings_offset, relative_posting_offset) catch return error.RecordTooLarge;
            var context = SkipTextPostingContext{};
            const next_block_posting_offset = try scanPersistentPostingRange(&self.postings_view, block_posting_offset, block_posting_count, self.doc_count, .none, &context, skipTextPosting);
            if (next_block_posting_offset < entry.postings_offset) return error.InvalidRecord;
            relative_posting_offset = next_block_posting_offset - entry.postings_offset;
            if (relative_posting_offset > self.postings_header.body_bytes - entry.postings_offset) return error.InvalidRecord;
        }

        return std.math.add(u64, entry.postings_offset, relative_posting_offset) catch return error.RecordTooLarge;
    }
};

fn forEachPersistentTermPostingForSearch(
    allocator: std.mem.Allocator,
    store: storage_mod.Store,
    term: []const u8,
    options: TextSearchOptions,
    postings_scanned: *usize,
    context: anytype,
    comptime callback: fn (@TypeOf(context), TextPostingRecord, u64) anyerror!void,
) !void {
    const doc_count = try readPersistentTextDocCount(allocator, store);
    var catalog = try PersistentPostingCatalog.open(allocator, store, doc_count);
    defer catalog.deinit();
    try forEachPersistentTermPostingInCatalog(&catalog, term, options, postings_scanned, context, callback);
}

fn forEachPersistentTermPostingInCatalog(
    catalog: *PersistentPostingCatalog,
    term: []const u8,
    options: TextSearchOptions,
    postings_scanned: *usize,
    context: anytype,
    comptime callback: fn (@TypeOf(context), TextPostingRecord, u64) anyerror!void,
) !void {
    if (try catalog.findTermEntry(term)) |lookup| {
        try forEachPersistentTermPostingLookupInCatalog(catalog, lookup, options, postings_scanned, context, callback);
    }
}

fn forEachPersistentTermPostingLookupInCatalog(
    catalog: *PersistentPostingCatalog,
    lookup: PersistentPostingCatalog.TermLookup,
    options: TextSearchOptions,
    postings_scanned: *usize,
    context: anytype,
    comptime callback: fn (@TypeOf(context), TextPostingRecord, u64) anyerror!void,
) !void {
    const entry = lookup.entry;
    _ = try scanPersistentTermPostings(&catalog.postings_view, entry, catalog.doc_count, .{ .search = .{
        .options = options,
        .postings_scanned = postings_scanned,
    } }, context, callback);
}

const PersistentQueryTermPlan = struct {
    term: []const u8,
    lookup: PersistentPostingCatalog.TermLookup,
    cjk_bigram_query_term: bool,
    required_cjk_bigram_count: u32,
    query_term_index: usize = 0,
};

fn persistentQueryTermPlanLessThan(_: void, lhs: PersistentQueryTermPlan, rhs: PersistentQueryTermPlan) bool {
    if (lhs.lookup.entry.postings_count != rhs.lookup.entry.postings_count) {
        return lhs.lookup.entry.postings_count < rhs.lookup.entry.postings_count;
    }
    return std.mem.order(u8, lhs.term, rhs.term) == .lt;
}

const persistent_query_term_freq_cache_max_terms: usize = 64;
const persistent_multi_term_exact_candidate_max_postings: u64 = 4096;
// Query should not become a validator pass for medium/common terms. Keep
// canonical frequency re-counting to one posting block; full validation, repair,
// and explicit posting reads own broader consistency checks.
const persistent_search_canonical_freq_validate_posting_limit: usize = persistent_posting_block_capacity;

const PersistentQueryTermFreqCache = struct {
    allocator: std.mem.Allocator,
    terms: []const PersistentQueryTermPlan,
    entries: std.AutoHashMap(u64, []FieldTermFreq),

    pub fn init(allocator: std.mem.Allocator, terms: []const PersistentQueryTermPlan) PersistentQueryTermFreqCache {
        return .{
            .allocator = allocator,
            .terms = terms,
            .entries = std.AutoHashMap(u64, []FieldTermFreq).init(allocator),
        };
    }

    pub fn deinit(self: *PersistentQueryTermFreqCache) void {
        var it = self.entries.valueIterator();
        while (it.next()) |freqs| self.allocator.free(freqs.*);
        self.entries.deinit();
    }

    pub fn getOrBuild(self: *PersistentQueryTermFreqCache, cached: CachedTextDoc) ![]const FieldTermFreq {
        if (self.entries.get(cached.doc.doc_id)) |freqs| return freqs;
        const freqs = try self.allocator.alloc(FieldTermFreq, self.terms.len);
        @memset(freqs, FieldTermFreq{});
        errdefer self.allocator.free(freqs);

        var all_freqs = std.StringHashMap(FieldTermFreq).init(self.allocator);
        defer all_freqs.deinit();
        var owned_terms = std.ArrayList([]u8).empty;
        defer {
            for (owned_terms.items) |term| self.allocator.free(term);
            owned_terms.deinit(self.allocator);
        }
        try all_freqs.ensureTotalCapacity(@intCast(self.terms.len));
        var scratch = std.ArrayList(u8).empty;
        defer scratch.deinit(self.allocator);
        _ = try collectStreamingSearchableNodeTermFreqs(self.allocator, self.allocator, &all_freqs, &owned_terms, cached.text(), cached.metadata, &scratch);
        for (self.terms) |plan| {
            if (all_freqs.get(plan.term)) |freq| freqs[plan.query_term_index] = freq;
        }

        try self.entries.put(cached.doc.doc_id, freqs);
        return freqs;
    }
};

fn persistentQueryTermPlanPostingTotal(plans: []const PersistentQueryTermPlan) !usize {
    var total: usize = 0;
    for (plans) |plan| {
        const count = std.math.cast(usize, plan.lookup.entry.postings_count) orelse return error.RecordTooLarge;
        total = std.math.add(usize, total, count) catch return error.RecordTooLarge;
    }
    return total;
}

fn persistentCandidateTermFreqKey(doc_id: u64, query_term_index: usize) !u64 {
    if (doc_id == 0 or doc_id > persistent_posting_max_doc_id) return error.InvalidRecord;
    if (query_term_index > std.math.maxInt(u16)) return error.RecordTooLarge;
    return (doc_id << 16) | @as(u64, @intCast(query_term_index));
}

fn putPersistentCandidateTextFreq(
    candidate_freqs: *std.AutoHashMap(u64, FieldTermFreq),
    doc_id: u64,
    query_term_index: usize,
    text_freq: u32,
) !void {
    if (text_freq == 0) return error.InvalidRecord;
    if (text_freq > persistent_posting_max_field_freq) return error.RecordTooLarge;
    try candidate_freqs.put(try persistentCandidateTermFreqKey(doc_id, query_term_index), .{ .text = text_freq, .kind = 0 });
}

const PersistentSearchCandidateContext = struct {
    allocator: std.mem.Allocator,
    store: storage_mod.Store,
    docs_view: *TextDocsFileView,
    node_view: *storage_mod.Store.NodeRecordView,
    options: TextSearchOptions,
    docs: *std.AutoHashMap(u64, CachedTextDoc),
    candidate_docs: *std.AutoHashMap(u64, void),
    candidate_freqs: *std.AutoHashMap(u64, FieldTermFreq),
    query_term_index: usize,
    query_term_freq_cache: *PersistentQueryTermFreqCache,
};

const PersistentSearchMediumTopCandidateContext = struct {
    docs_view: *TextDocsFileView,
    options: TextSearchOptions,
    avg_doc_len: f32,
    doc_count: u64,
    doc_freq: u64,
    hits: [persistent_term_top_hit_capacity_usize]TextTermTopHitRecord = undefined,
    hit_count: usize = 0,
    worst_hit_index: ?usize = null,
};

fn collectPersistentSearchMediumTopCandidatePosting(ctx: *PersistentSearchMediumTopCandidateContext, posting: TextPostingRecord, _: u64) !void {
    if (deadlineExpiredStrided(ctx.options.deadline)) return core.Error.BudgetExceeded;
    if (posting.doc_id == 0 or posting.doc_id > ctx.doc_count) return error.InvalidRecord;
    const doc = try ctx.docs_view.readTopHitDocStatsAt(posting.doc_id - 1);
    if (doc.doc_id != posting.doc_id) return error.InvalidRecord;
    const score = bm25WeightedTermScore(
        persistentWeightedTf(posting),
        doc.doc_len,
        ctx.avg_doc_len,
        ctx.doc_count,
        ctx.doc_freq,
        ctx.options.params,
    );
    if (!std.math.isFinite(score)) return core.Error.Unsupported;
    try appendTopTextTermHitBoundedInline(&ctx.hits, &ctx.hit_count, persistent_term_top_hit_capacity_usize, &ctx.worst_hit_index, .{
        .doc_id = posting.doc_id,
        .text_freq = posting.text_freq,
        .node_id = doc.node_id,
        .score = score,
    });
}

fn collectPersistentSearchCandidatePosting(ctx: *PersistentSearchCandidateContext, posting: TextPostingRecord, _: u64) !void {
    if (deadlineExpiredStrided(ctx.options.deadline)) return core.Error.BudgetExceeded;
    _ = ctx.allocator;
    _ = ctx.store;
    _ = ctx.node_view;
    _ = ctx.docs;
    _ = ctx.query_term_freq_cache;
    if (posting.doc_id == 0) return error.InvalidRecord;
    const doc = try ctx.docs_view.readDocAt(posting.doc_id - 1);
    if (doc.doc_id != posting.doc_id) return error.InvalidRecord;
    if (!textSearchMatchesNodeKind(ctx.options, try doc.nodeKind())) return;
    if (ctx.options.member_filter) |m| {
        if (!m.contains(doc.node_id)) return;
    }
    const candidate = try ctx.candidate_docs.getOrPut(posting.doc_id);
    candidate.value_ptr.* = {};
    try putPersistentCandidateTextFreq(ctx.candidate_freqs, posting.doc_id, ctx.query_term_index, posting.text_freq);
}

fn fillPersistentCandidateTextFreqsFromCatalog(
    catalog: *PersistentPostingCatalog,
    lookup: PersistentPostingCatalog.TermLookup,
    sorted_doc_ids: []const u64,
    query_term_index: usize,
    candidate_freqs: *std.AutoHashMap(u64, FieldTermFreq),
) !bool {
    return fillPersistentCandidateTextFreqsFromCatalogDeadline(
        catalog,
        lookup,
        sorted_doc_ids,
        query_term_index,
        candidate_freqs,
        .none,
    );
}

fn fillPersistentCandidateTextFreqsFromCatalogDeadline(
    catalog: *PersistentPostingCatalog,
    lookup: PersistentPostingCatalog.TermLookup,
    sorted_doc_ids: []const u64,
    query_term_index: usize,
    candidate_freqs: *std.AutoHashMap(u64, FieldTermFreq),
    deadline: core.QueryDeadline,
) !bool {
    const entry = lookup.entry;
    const doc_count = catalog.doc_count;
    if (sorted_doc_ids.len == 0) return true;
    if (termEntryVirtualAllDocsTextFreq(entry)) |text_freq| {
        if (entry.postings_count != doc_count) return error.InvalidRecord;
        for (sorted_doc_ids) |doc_id| {
            if (doc_id == 0 or doc_id > doc_count) return error.InvalidRecord;
            try putPersistentCandidateTextFreq(candidate_freqs, doc_id, query_term_index, text_freq);
        }
        return true;
    }
    if (termEntryDenseAllDocsFreqStreamOffset(entry)) |dense_offset| {
        if (entry.postings_count != doc_count) return error.InvalidRecord;
        try fillDenseAllDocsCandidateTextFreqs(&catalog.postings_view, dense_offset, doc_count, sorted_doc_ids, query_term_index, candidate_freqs);
        return true;
    }
    try fillPostingCandidateTextFreqs(catalog, lookup, sorted_doc_ids, query_term_index, candidate_freqs, deadline);
    return true;
}

fn fillDenseAllDocsCandidateTextFreqs(
    view: *TextPostingsFileView,
    posting_offset: u64,
    doc_count: u64,
    sorted_doc_ids: []const u64,
    query_term_index: usize,
    candidate_freqs: *std.AutoHashMap(u64, FieldTermFreq),
) !void {
    if (sorted_doc_ids.len == 0) return;
    try validateSortedCandidateDocIds(sorted_doc_ids, doc_count);
    if (try view.mappedBodyFromOffset(posting_offset)) |bytes| {
        try fillDenseAllDocsCandidateTextFreqsFromBytes(bytes, doc_count, sorted_doc_ids, query_term_index, candidate_freqs);
        return;
    }
    try fillDenseAllDocsCandidateTextFreqsFromFile(view, posting_offset, doc_count, sorted_doc_ids, query_term_index, candidate_freqs);
}

fn validateSortedCandidateDocIds(sorted_doc_ids: []const u64, doc_count: u64) !void {
    var previous: u64 = 0;
    for (sorted_doc_ids) |doc_id| {
        if (doc_id == 0 or doc_id > doc_count) return error.InvalidRecord;
        if (doc_id <= previous) return error.InvalidRecord;
        previous = doc_id;
    }
}

const PersistentCandidatePostingFreqScanContext = struct {
    sorted_doc_ids: []const u64,
    target_index: usize = 0,
    query_term_index: usize,
    candidate_freqs: *std.AutoHashMap(u64, FieldTermFreq),
};

fn fillPostingCandidateTextFreqs(
    catalog: *PersistentPostingCatalog,
    lookup: PersistentPostingCatalog.TermLookup,
    sorted_doc_ids: []const u64,
    query_term_index: usize,
    candidate_freqs: *std.AutoHashMap(u64, FieldTermFreq),
    deadline: core.QueryDeadline,
) !void {
    const entry = lookup.entry;
    try validateSortedCandidateDocIds(sorted_doc_ids, catalog.doc_count);
    if (termEntryHasInlinePosting(entry)) {
        const posting = try decodeInlineSingletonPostingPayload(entry.postings_offset);
        try validateTextPostingFields(posting.doc_id, posting.text_freq, posting.kind_freq);
        for (sorted_doc_ids) |doc_id| {
            if (doc_id == posting.doc_id) {
                try putPersistentCandidateTextFreq(candidate_freqs, doc_id, query_term_index, posting.text_freq);
                break;
            }
            if (doc_id > posting.doc_id) break;
        }
        return;
    }

    const block_count = try publishedPostingBlockCountForEntry(entry, catalog.blocks_header.block_size);
    if (block_count == 0) {
        var context = PersistentCandidatePostingFreqScanContext{
            .sorted_doc_ids = sorted_doc_ids,
            .query_term_index = query_term_index,
            .candidate_freqs = candidate_freqs,
        };
        _ = try scanPersistentTermPostings(&catalog.postings_view, entry, catalog.doc_count, .{ .deadline = deadline }, &context, collectPersistentCandidatePostingFreq);
        return;
    }
    const term_block_offset = try catalog.termBlockOffset(lookup.index);
    if (term_block_offset > catalog.blocks_header.block_count) return error.InvalidRecord;
    if (block_count > catalog.blocks_header.block_count - term_block_offset) return error.InvalidRecord;

    var target_index: usize = 0;
    var local_block_index: u64 = 0;
    while (target_index < sorted_doc_ids.len and local_block_index < block_count) {
        if (deadlineExpiredStrided(deadline)) return core.Error.BudgetExceeded;
        const target_doc_id = sorted_doc_ids[target_index];
        var block = try catalog.blocks_view.readBlockRecordAt(catalog.blocks_header.term_count, term_block_offset + local_block_index);
        while (block.last_doc_id < target_doc_id) {
            local_block_index += 1;
            if (local_block_index >= block_count) return;
            block = try catalog.blocks_view.readBlockRecordAt(catalog.blocks_header.term_count, term_block_offset + local_block_index);
        }

        const group_start = target_index;
        while (target_index < sorted_doc_ids.len and sorted_doc_ids[target_index] <= block.last_doc_id) {
            target_index += 1;
        }
        const block_posting_count = try persistentBlockPostingCount(entry.postings_count, local_block_index, catalog.blocks_header.block_size);
        const block_posting_offset = try catalog.blockPostingOffset(entry, term_block_offset, local_block_index);
        var context = PersistentCandidatePostingFreqScanContext{
            .sorted_doc_ids = sorted_doc_ids[group_start..target_index],
            .query_term_index = query_term_index,
            .candidate_freqs = candidate_freqs,
        };
        _ = try scanPersistentPostingRange(&catalog.postings_view, block_posting_offset, block_posting_count, catalog.doc_count, .{ .deadline = deadline }, &context, collectPersistentCandidatePostingFreq);
        local_block_index += 1;
    }
}

fn collectPersistentCandidatePostingFreq(ctx: *PersistentCandidatePostingFreqScanContext, posting: TextPostingRecord, _: u64) !void {
    while (ctx.target_index < ctx.sorted_doc_ids.len and ctx.sorted_doc_ids[ctx.target_index] < posting.doc_id) {
        ctx.target_index += 1;
    }
    if (ctx.target_index >= ctx.sorted_doc_ids.len) return;
    if (ctx.sorted_doc_ids[ctx.target_index] != posting.doc_id) return;
    try putPersistentCandidateTextFreq(ctx.candidate_freqs, posting.doc_id, ctx.query_term_index, posting.text_freq);
    ctx.target_index += 1;
}

fn fillDenseAllDocsCandidateTextFreqsFromBytes(
    bytes: []const u8,
    doc_count: u64,
    sorted_doc_ids: []const u64,
    query_term_index: usize,
    candidate_freqs: *std.AutoHashMap(u64, FieldTermFreq),
) !void {
    if (bytes.len == 0) return error.InvalidRecord;
    const mode = bytes[0];
    var cursor: usize = 1;
    var doc_index: u64 = 0;
    var target_index: usize = 0;
    switch (mode) {
        persistent_dense_all_docs_freq_mode_packed => while (doc_index < doc_count and target_index < sorted_doc_ids.len) {
            const remaining = doc_count - doc_index;
            const group_count: usize = @intCast(@min(remaining, persistent_dense_all_docs_freq_group_size));
            const tag_bytes = try denseAllDocsFreqGroupTagBytes(group_count);
            if (cursor > bytes.len or tag_bytes > bytes.len - cursor) return error.InvalidRecord;
            const tags = bytes[cursor .. cursor + tag_bytes];
            cursor += tag_bytes;
            var local: usize = 0;
            while (local < group_count) : (local += 1) {
                const field_tag = try decodeDenseAllDocsFreqGroupTag(tags, group_count, local);
                const text_freq: u32 = compressedPostingTagInlineTextFreq(field_tag) orelse if (compressedPostingTagTextExplicit(field_tag))
                    try validateCompressedPostingExplicitFreq(field_tag, try decodePersistentVarintFromBytes(bytes, &cursor))
                else
                    return error.InvalidRecord;
                const doc_id = doc_index + @as(u64, @intCast(local)) + 1;
                while (target_index < sorted_doc_ids.len and sorted_doc_ids[target_index] == doc_id) : (target_index += 1) {
                    try putPersistentCandidateTextFreq(candidate_freqs, doc_id, query_term_index, text_freq);
                }
            }
            doc_index += group_count;
        },
        persistent_dense_all_docs_freq_mode_rle => while (doc_index < doc_count and target_index < sorted_doc_ids.len) {
            const run_len = try decodePersistentVarintFromBytes(bytes, &cursor);
            if (run_len == 0 or run_len > doc_count - doc_index) return error.InvalidRecord;
            const text_freq = try validateDenseAllDocsTextFreq(try decodePersistentVarintFromBytes(bytes, &cursor));
            const run_first_doc_id = doc_index + 1;
            const run_last_doc_id = doc_index + run_len;
            while (target_index < sorted_doc_ids.len and sorted_doc_ids[target_index] <= run_last_doc_id) : (target_index += 1) {
                if (sorted_doc_ids[target_index] < run_first_doc_id) return error.InvalidRecord;
                try putPersistentCandidateTextFreq(candidate_freqs, sorted_doc_ids[target_index], query_term_index, text_freq);
            }
            doc_index += run_len;
        },
        persistent_dense_all_docs_freq_mode_bitpacked => {
            if (cursor >= bytes.len) return error.InvalidRecord;
            const bits: u6 = @intCast(bytes[cursor]);
            cursor += 1;
            if (bits == 0 or bits > 16) return error.InvalidRecord;
            const payload_bits = std.math.mul(u64, doc_count, bits) catch return error.RecordTooLarge;
            const payload_bytes = try std.math.divCeil(u64, payload_bits, 8);
            const payload_len = std.math.cast(usize, payload_bytes) orelse return error.RecordTooLarge;
            if (payload_len > bytes.len - cursor) return error.InvalidRecord;
            const payload = bytes[cursor .. cursor + payload_len];
            for (sorted_doc_ids) |doc_id| {
                const bit_offset = std.math.mul(u64, doc_id - 1, bits) catch return error.RecordTooLarge;
                const text_freq = try validateDenseAllDocsTextFreq(try readPackedBits(payload, bit_offset, bits));
                try putPersistentCandidateTextFreq(candidate_freqs, doc_id, query_term_index, text_freq);
            }
            target_index = sorted_doc_ids.len;
        },
        else => return error.InvalidRecord,
    }
    if (target_index != sorted_doc_ids.len) return error.InvalidRecord;
}

fn fillDenseAllDocsCandidateTextFreqsFromFile(
    view: *TextPostingsFileView,
    posting_offset: u64,
    doc_count: u64,
    sorted_doc_ids: []const u64,
    query_term_index: usize,
    candidate_freqs: *std.AutoHashMap(u64, FieldTermFreq),
) !void {
    var cursor = try textPostingBodyOffset(posting_offset);
    const mode = try view.readByteAt(cursor);
    cursor = std.math.add(u64, cursor, 1) catch return error.RecordTooLarge;
    var doc_index: u64 = 0;
    var target_index: usize = 0;
    var tag_bytes_buf: [3]u8 = undefined;
    switch (mode) {
        persistent_dense_all_docs_freq_mode_packed => while (doc_index < doc_count and target_index < sorted_doc_ids.len) {
            const remaining = doc_count - doc_index;
            const group_count: usize = @intCast(@min(remaining, persistent_dense_all_docs_freq_group_size));
            const tag_bytes = try denseAllDocsFreqGroupTagBytes(group_count);
            const n = try view.file.readPositionalAll(view.io, tag_bytes_buf[0..tag_bytes], cursor);
            if (n != tag_bytes) return error.InvalidRecord;
            cursor = std.math.add(u64, cursor, tag_bytes) catch return error.RecordTooLarge;
            var local: usize = 0;
            while (local < group_count) : (local += 1) {
                const field_tag = try decodeDenseAllDocsFreqGroupTag(tag_bytes_buf[0..tag_bytes], group_count, local);
                const text_freq: u32 = compressedPostingTagInlineTextFreq(field_tag) orelse if (compressedPostingTagTextExplicit(field_tag))
                    try validateCompressedPostingExplicitFreq(field_tag, try decodePersistentVarintFromFile(view, &cursor))
                else
                    return error.InvalidRecord;
                const doc_id = doc_index + @as(u64, @intCast(local)) + 1;
                while (target_index < sorted_doc_ids.len and sorted_doc_ids[target_index] == doc_id) : (target_index += 1) {
                    try putPersistentCandidateTextFreq(candidate_freqs, doc_id, query_term_index, text_freq);
                }
            }
            doc_index += group_count;
        },
        persistent_dense_all_docs_freq_mode_rle => while (doc_index < doc_count and target_index < sorted_doc_ids.len) {
            const run_len = try decodePersistentVarintFromFile(view, &cursor);
            if (run_len == 0 or run_len > doc_count - doc_index) return error.InvalidRecord;
            const text_freq = try validateDenseAllDocsTextFreq(try decodePersistentVarintFromFile(view, &cursor));
            const run_first_doc_id = doc_index + 1;
            const run_last_doc_id = doc_index + run_len;
            while (target_index < sorted_doc_ids.len and sorted_doc_ids[target_index] <= run_last_doc_id) : (target_index += 1) {
                if (sorted_doc_ids[target_index] < run_first_doc_id) return error.InvalidRecord;
                try putPersistentCandidateTextFreq(candidate_freqs, sorted_doc_ids[target_index], query_term_index, text_freq);
            }
            doc_index += run_len;
        },
        persistent_dense_all_docs_freq_mode_bitpacked => {
            const bits_byte = try view.readByteAt(cursor);
            cursor = std.math.add(u64, cursor, 1) catch return error.RecordTooLarge;
            const bits: u6 = @intCast(bits_byte);
            if (bits == 0 or bits > 16) return error.InvalidRecord;
            const payload_bits = std.math.mul(u64, doc_count, bits) catch return error.RecordTooLarge;
            const payload_bytes = try std.math.divCeil(u64, payload_bits, 8);
            var bytes: [3]u8 = undefined;
            for (sorted_doc_ids) |doc_id| {
                const global_bit = std.math.mul(u64, doc_id - 1, bits) catch return error.RecordTooLarge;
                const byte_offset = global_bit / 8;
                if (byte_offset >= payload_bytes) return error.InvalidRecord;
                const local_bit: u6 = @intCast(global_bit % 8);
                const available = payload_bytes - byte_offset;
                const read_len: usize = @intCast(@min(available, bytes.len));
                const n = try view.file.readPositionalAll(view.io, bytes[0..read_len], cursor + byte_offset);
                if (n != read_len) return error.InvalidRecord;
                const text_freq = try validateDenseAllDocsTextFreq(try readPackedBits(bytes[0..read_len], local_bit, bits));
                try putPersistentCandidateTextFreq(candidate_freqs, doc_id, query_term_index, text_freq);
            }
            target_index = sorted_doc_ids.len;
        },
        else => return error.InvalidRecord,
    }
    if (target_index != sorted_doc_ids.len) return error.InvalidRecord;
}

fn catalogTextFreqForDoc(
    postings_view: *TextPostingsFileView,
    entry: TextTermEntry,
    doc_count: u64,
    doc_id: u64,
) !?FieldTermFreq {
    if (doc_id == 0 or doc_id > doc_count) return error.InvalidRecord;
    if (termEntryVirtualAllDocsTextFreq(entry)) |text_freq| {
        if (entry.postings_count != doc_count) return error.InvalidRecord;
        return FieldTermFreq{ .text = text_freq, .kind = 0 };
    }
    const dense_offset = termEntryDenseAllDocsFreqStreamOffset(entry) orelse return null;
    if (entry.postings_count != doc_count) return error.InvalidRecord;
    const text_freq = (try denseAllDocsFreqAt(postings_view, dense_offset, doc_count, doc_id)) orelse return null;
    return FieldTermFreq{ .text = text_freq, .kind = 0 };
}

fn denseAllDocsFreqAt(
    view: *TextPostingsFileView,
    posting_offset: u64,
    doc_count: u64,
    doc_id: u64,
) !?u32 {
    if (doc_id == 0 or doc_id > doc_count) return error.InvalidRecord;
    if (try view.mappedBodyFromOffset(posting_offset)) |bytes| {
        return try denseAllDocsFreqAtFromBytes(bytes, doc_count, doc_id);
    }
    return try denseAllDocsFreqAtFromFile(view, posting_offset, doc_count, doc_id);
}

fn denseAllDocsFreqAtFromBytes(bytes: []const u8, doc_count: u64, doc_id: u64) !?u32 {
    if (bytes.len < 2) return error.InvalidRecord;
    if (bytes[0] != persistent_dense_all_docs_freq_mode_bitpacked) return null;
    const bits: u6 = @intCast(bytes[1]);
    if (bits == 0 or bits > 16) return error.InvalidRecord;
    const payload_bits = std.math.mul(u64, doc_count, bits) catch return error.RecordTooLarge;
    const payload_bytes = try std.math.divCeil(u64, payload_bits, 8);
    const payload_len = std.math.cast(usize, payload_bytes) orelse return error.RecordTooLarge;
    if (payload_len > bytes.len - 2) return error.InvalidRecord;
    const doc_index = doc_id - 1;
    const bit_offset = std.math.mul(u64, doc_index, bits) catch return error.RecordTooLarge;
    return try validateDenseAllDocsTextFreq(try readPackedBits(bytes[2..][0..payload_len], bit_offset, bits));
}

fn denseAllDocsFreqAtFromFile(
    view: *TextPostingsFileView,
    posting_offset: u64,
    doc_count: u64,
    doc_id: u64,
) !?u32 {
    const body_offset = try textPostingBodyOffset(posting_offset);
    const mode = try view.readByteAt(body_offset);
    if (mode != persistent_dense_all_docs_freq_mode_bitpacked) return null;
    const bits_byte = try view.readByteAt(body_offset + 1);
    const bits: u6 = @intCast(bits_byte);
    if (bits == 0 or bits > 16) return error.InvalidRecord;
    const doc_index = doc_id - 1;
    const global_bit = std.math.mul(u64, doc_index, bits) catch return error.RecordTooLarge;
    const byte_offset = global_bit / 8;
    const local_bit: u6 = @intCast(global_bit % 8);
    const payload_bits = std.math.mul(u64, doc_count, bits) catch return error.RecordTooLarge;
    const payload_bytes = try std.math.divCeil(u64, payload_bits, 8);
    if (byte_offset >= payload_bytes) return error.InvalidRecord;
    var bytes: [3]u8 = undefined;
    const available = payload_bytes - byte_offset;
    const read_len: usize = @intCast(@min(available, bytes.len));
    const n = try view.file.readPositionalAll(view.io, bytes[0..read_len], body_offset + 2 + byte_offset);
    if (n != read_len) return error.InvalidRecord;
    return try validateDenseAllDocsTextFreq(try readPackedBits(bytes[0..read_len], local_bit, bits));
}

fn canUsePersistentTermTopHitCache(options: TextSearchOptions, entry: TextTermEntry) bool {
    if (options.limit == 0 or options.limit > persistent_term_top_hit_capacity) return false;
    if (entry.postings_count < persistent_term_top_hit_min_postings) return false;
    const default_params = Bm25Params{};
    if (options.params.k1 == default_params.k1 and options.params.b == default_params.b) return true;
    // With default length normalization, virtual all-doc constant-frequency
    // terms keep the same top-hit ordering when only k1 changes.
    return options.params.b == default_params.b and termEntryVirtualAllDocsTextFreq(entry) != null;
}

fn canUsePersistentTermTopHitCandidateCache(options: TextSearchOptions, entry: TextTermEntry) bool {
    if (options.limit == 0 or options.limit > persistent_term_top_hit_capacity) return false;
    if (entry.postings_count < persistent_term_top_hit_min_postings) return false;
    const default_params = Bm25Params{};
    if (options.params.k1 != default_params.k1 or options.params.b != default_params.b) return false;
    return true;
}

fn readPersistentTermTopHitCache(
    allocator: std.mem.Allocator,
    store: storage_mod.Store,
    docs_view: *TextDocsFileView,
    term: []const u8,
    term_index: u64,
    entry: TextTermEntry,
    meta: PersistentTextMeta,
    avg_doc_len: f32,
    cjk_bigram_query_term: bool,
    required_cjk_bigram_count: u32,
    options: TextSearchOptions,
) !?std.ArrayList(TextSearchHit) {
    _ = term;
    const path = try textTermTopHitsPath(allocator, store);
    defer allocator.free(path);
    var file = std.Io.Dir.cwd().openFile(store.io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => |e| return e,
    };
    defer file.close(store.io);
    const file_size = try regularFileSize(store, file);
    const header = try readTextTermTopHitsHeaderFromFile(store, file);
    if (term_index >= header.term_count) return error.InvalidRecord;
    if (header.capacity != persistent_term_top_hit_capacity) return error.InvalidRecord;
    const expected_size = textTermTopHitsFileSize(header.hit_count, header.hit_term_count) catch |err| switch (err) {
        error.RecordTooLarge => return error.InvalidRecord,
        else => |e| return e,
    };
    if (file_size != expected_size) return error.InvalidRecord;
    // A missing term entry is not corruption: the file may have been
    // published under an older, higher min-postings threshold. Fall back to
    // the scan path, which is always correct, until the next publication.
    const term_hits = (try readTextTermTopHitTermAt(store, file, header, term_index)) orelse return null;
    if (term_hits.hit_count > header.capacity) return error.InvalidRecord;
    if (term_hits.hit_offset > header.hit_count or term_hits.hit_count > header.hit_count - term_hits.hit_offset) return error.InvalidRecord;
    const expected_count = @min(entry.postings_count, header.capacity);
    if (term_hits.hit_count != expected_count) return null;

    var hits = std.ArrayList(TextSearchHit).empty;
    errdefer hits.deinit(allocator);
    try hits.ensureTotalCapacity(allocator, @min(options.limit, textSearchPreallocCapacity(options)));
    var worst_hit_index: ?usize = null;
    var previous_score: ?f32 = null;
    var pos: u64 = 0;
    while (pos < term_hits.hit_count) : (pos += 1) {
        if (deadlineExpiredStrided(options.deadline)) return core.Error.BudgetExceeded;
        const record = try readTextTermTopHitRecordAt(store, file, term_hits.hit_offset + pos);
        const doc = try docs_view.readDocAt(record.doc_id - 1);
        if (doc.doc_id != record.doc_id) return error.InvalidRecord;
        if (cjk_bigram_query_term and record.text_freq < required_cjk_bigram_count) continue;
        const score = bm25WeightedTermScore(
            @floatFromInt(record.text_freq),
            persistentDocLen(doc),
            avg_doc_len,
            meta.doc_count,
            entry.postings_count,
            options.params,
        );
        if (!std.math.isFinite(score)) return core.Error.Unsupported;
        if (previous_score) |previous| {
            if (score > previous) return error.InvalidRecord;
        }
        previous_score = score;
        if (score < options.min_score) continue;
        try appendTopTextHitBoundedCachedWorst(allocator, &hits, options.limit, &worst_hit_index, .{
            .node_id = core.NodeId.fromInt(doc.node_id),
            .kind = try doc.nodeKind(),
            .score = score,
        });
    }
    std.mem.sort(TextSearchHit, hits.items, {}, textSearchHitLessThan);
    return hits;
}

const SingleTermSearchContext = struct {
    allocator: std.mem.Allocator,
    store: storage_mod.Store,
    docs_view: *TextDocsFileView,
    node_view: *storage_mod.Store.NodeRecordView,
    term: []const u8,
    options: TextSearchOptions,
    docs: *std.AutoHashMap(u64, CachedTextDoc),
    doc_records: *std.AutoHashMap(u64, TextDocRecord),
    hits: *std.ArrayList(TextSearchHit),
    avg_doc_len: f32,
    doc_count: u64,
    doc_freq: u64,
    cjk_bigram_query_term: bool,
    required_cjk_bigram_count: u32,
    validate_canonical_freqs: bool = true,
    worst_hit_index: ?usize = null,
};

fn appendSingleTermSearchPosting(ctx: *SingleTermSearchContext, posting: TextPostingRecord, _: u64) !void {
    if (deadlineExpiredStrided(ctx.options.deadline)) return core.Error.BudgetExceeded;
    const doc = if (ctx.validate_canonical_freqs)
        (try getCachedTextDocFromView(ctx.allocator, ctx.store, ctx.docs_view, ctx.node_view, ctx.docs, posting.doc_id)).doc
    else
        try getCachedTextDocRecordFromView(ctx.docs_view, ctx.doc_records, posting.doc_id);
    if (!textSearchMatchesNodeKind(ctx.options, try doc.nodeKind())) return;
    if (ctx.options.member_filter) |m| {
        if (!m.contains(doc.node_id)) return;
    }
    if (ctx.validate_canonical_freqs) {
        const cached = try getCachedTextDocFromView(ctx.allocator, ctx.store, ctx.docs_view, ctx.node_view, ctx.docs, posting.doc_id);
        try validateTextPostingAgainstCanonicalNode(ctx.allocator, ctx.term, posting, cached);
    }
    if (ctx.cjk_bigram_query_term) {
        const raw_freq = std.math.add(u32, posting.text_freq, posting.kind_freq) catch return error.InvalidRecord;
        if (raw_freq < ctx.required_cjk_bigram_count) return;
    }
    const score = bm25WeightedTermScore(
        persistentWeightedTf(posting),
        persistentDocLen(doc),
        ctx.avg_doc_len,
        ctx.doc_count,
        ctx.doc_freq,
        ctx.options.params,
    );
    if (!std.math.isFinite(score)) return core.Error.Unsupported;
    if (score < ctx.options.min_score) return;
    try appendTopTextHitBoundedCachedWorst(ctx.allocator, ctx.hits, ctx.options.limit, &ctx.worst_hit_index, .{
        .node_id = core.NodeId.fromInt(doc.node_id),
        .kind = try doc.nodeKind(),
        .score = score,
    });
}

const PersistentSearchTermContext = struct {
    allocator: std.mem.Allocator,
    store: storage_mod.Store,
    docs_view: *TextDocsFileView,
    node_view: *storage_mod.Store.NodeRecordView,
    term: []const u8,
    options: TextSearchOptions,
    docs: *std.AutoHashMap(u64, CachedTextDoc),
    doc_records: *std.AutoHashMap(u64, TextDocRecord),
    scores: *std.AutoHashMap(u64, f32),
    cjk_bigram_match_counts: *std.AutoHashMap(u64, u32),
    cjk_bigram_query_term: bool,
    required_cjk_bigram_count: u32,
    avg_doc_len: f32,
    doc_count: u64,
    query_term_index: usize,
    query_term_freq_cache: ?*PersistentQueryTermFreqCache = null,
    validate_canonical_freqs: bool = true,
};

fn scorePersistentSearchPosting(ctx: *PersistentSearchTermContext, posting: TextPostingRecord, doc_freq: u64) !void {
    if (deadlineExpiredStrided(ctx.options.deadline)) return core.Error.BudgetExceeded;
    const doc = if (ctx.validate_canonical_freqs)
        (try getCachedTextDocFromView(ctx.allocator, ctx.store, ctx.docs_view, ctx.node_view, ctx.docs, posting.doc_id)).doc
    else
        try getCachedTextDocRecordFromView(ctx.docs_view, ctx.doc_records, posting.doc_id);
    if (!textSearchMatchesNodeKind(ctx.options, try doc.nodeKind())) return;
    if (ctx.options.member_filter) |m| {
        if (!m.contains(doc.node_id)) return;
    }
    if (ctx.validate_canonical_freqs) {
        const cached = try getCachedTextDocFromView(ctx.allocator, ctx.store, ctx.docs_view, ctx.node_view, ctx.docs, posting.doc_id);
        if (ctx.query_term_freq_cache) |cache| {
            const freqs = try cache.getOrBuild(cached);
            if (ctx.query_term_index >= freqs.len) return error.InvalidRecord;
            const freq = freqs[ctx.query_term_index];
            if (posting.text_freq != freq.text or posting.kind_freq != freq.kind) return error.InvalidRecord;
        } else {
            try validateTextPostingAgainstCanonicalNode(ctx.allocator, ctx.term, posting, cached);
        }
    }
    if (ctx.cjk_bigram_query_term) {
        const raw_freq = std.math.add(u32, posting.text_freq, posting.kind_freq) catch return error.InvalidRecord;
        if (raw_freq >= ctx.required_cjk_bigram_count) {
            const entry = try ctx.cjk_bigram_match_counts.getOrPut(posting.doc_id);
            if (!entry.found_existing) entry.value_ptr.* = 0;
            entry.value_ptr.* = std.math.add(u32, entry.value_ptr.*, 1) catch return error.RecordTooLarge;
        }
    }
    // Incremental merge: exact scan paths score with combined corpus
    // statistics so catalog and tail hits rank on one scale. Cached top-hit
    // paths keep their published scores; that approximation is bounded by
    // tail/N and recorded in the incremental design decision.
    var effective_doc_freq = doc_freq;
    var effective_avg_doc_len = ctx.avg_doc_len;
    var effective_doc_count = ctx.doc_count;
    if (ctx.options.merge) |merge| {
        effective_doc_freq = std.math.add(u64, doc_freq, merge.otherDf(merge.other_df_context, ctx.term)) catch return error.RecordTooLarge;
        effective_doc_count = merge.doc_count;
        effective_avg_doc_len = if (merge.doc_count == 0) 0 else @floatCast(merge.total_doc_len / @as(f64, @floatFromInt(merge.doc_count)));
    }
    const score = bm25WeightedTermScore(
        persistentWeightedTf(posting),
        persistentDocLen(doc),
        effective_avg_doc_len,
        effective_doc_count,
        effective_doc_freq,
        ctx.options.params,
    );
    const entry = try ctx.scores.getOrPut(posting.doc_id);
    if (!entry.found_existing) entry.value_ptr.* = 0;
    const next = entry.value_ptr.* + score;
    if (!std.math.isFinite(next)) return core.Error.Unsupported;
    entry.value_ptr.* = next;
}

fn validatePersistentTermPostings(
    allocator: std.mem.Allocator,
    store: storage_mod.Store,
    term: []const u8,
    postings: []const TextPostingRecord,
) !void {
    var docs = std.AutoHashMap(u64, CachedTextDoc).init(allocator);
    defer deinitCachedTextDocs(allocator, &docs);
    for (postings) |posting| {
        const cached = try getCachedTextDoc(allocator, store, &docs, posting.doc_id);
        try validateTextPostingAgainstCanonicalNode(allocator, term, posting, cached);
    }
}

fn searchableNodeTextBytes(text: []const u8, metadata: SearchableNodeMetadata) !u64 {
    var bytes: u64 = text.len;
    if (metadata.name) |name| bytes = std.math.add(u64, bytes, name.len) catch return error.RecordTooLarge;
    if (metadata.summary) |summary| bytes = std.math.add(u64, bytes, summary.len) catch return error.RecordTooLarge;
    return bytes;
}

fn addSearchableNodeCount(total: *u64, value: u64) !void {
    total.* = std.math.add(u64, total.*, value) catch return error.RecordTooLarge;
}

fn collectSearchableNodeTermFreqs(
    allocator: std.mem.Allocator,
    freqs: *std.StringHashMap(FieldTermFreq),
    owned: *std.ArrayList([]u8),
    text: []const u8,
    metadata: SearchableNodeMetadata,
) !u64 {
    var tokens: u64 = 0;
    try addSearchableNodeCount(&tokens, try collectTermFreqs(allocator, freqs, owned, text, .text));
    if (metadata.name) |name| try addSearchableNodeCount(&tokens, try collectTermFreqs(allocator, freqs, owned, name, .text));
    if (metadata.summary) |summary| try addSearchableNodeCount(&tokens, try collectTermFreqs(allocator, freqs, owned, summary, .text));
    return tokens;
}

fn collectStreamingSearchableNodeTermFreqs(
    term_allocator: std.mem.Allocator,
    scratch_allocator: std.mem.Allocator,
    freqs: *std.StringHashMap(FieldTermFreq),
    owned: ?*std.ArrayList([]u8),
    text: []const u8,
    metadata: SearchableNodeMetadata,
    scratch: *std.ArrayList(u8),
) !u64 {
    var tokens: u64 = 0;
    try addSearchableNodeCount(&tokens, try collectStreamingTermFreqsWithScratch(term_allocator, scratch_allocator, freqs, owned, text, .text, scratch));
    if (metadata.name) |name| try addSearchableNodeCount(&tokens, try collectStreamingTermFreqsWithScratch(term_allocator, scratch_allocator, freqs, owned, name, .text, scratch));
    if (metadata.summary) |summary| try addSearchableNodeCount(&tokens, try collectStreamingTermFreqsWithScratch(term_allocator, scratch_allocator, freqs, owned, summary, .text, scratch));
    return tokens;
}

fn countSearchableNodeTokens(allocator: std.mem.Allocator, text: []const u8, metadata: SearchableNodeMetadata) !u64 {
    var tokens: u64 = 0;
    try addSearchableNodeCount(&tokens, try countTokens(allocator, text, .{}));
    if (metadata.name) |name| try addSearchableNodeCount(&tokens, try countTokens(allocator, name, .{}));
    if (metadata.summary) |summary| try addSearchableNodeCount(&tokens, try countTokens(allocator, summary, .{}));
    return tokens;
}

fn countTermInSearchableNode(allocator: std.mem.Allocator, text: []const u8, metadata: SearchableNodeMetadata, term: []const u8) !u32 {
    var freq = try countTermInText(allocator, text, term);
    if (metadata.name) |name| freq = std.math.add(u32, freq, try countTermInText(allocator, name, term)) catch return error.RecordTooLarge;
    if (metadata.summary) |summary| freq = std.math.add(u32, freq, try countTermInText(allocator, summary, term)) catch return error.RecordTooLarge;
    return freq;
}

const PersistentTerm = struct {
    term: []u8,
    postings: PersistentPostingList = .{},
    postings_offset: u64 = 0,
    postings_offset_is_plain: bool = false,
    postings_offset_is_dense_freq_stream: bool = false,
};

const PendingPersistentTerm = struct {
    term: []u8,
    postings: PersistentPostingList = .{},
};

const FieldTermFreq = struct {
    text: u32 = 0,
    kind: u32 = 0,
};

const PersistentPostingList = struct {
    inline_items: [1]TextPostingRecord = undefined,
    overflow: std.ArrayList(TextPostingRecord) = .empty,
    len: usize = 0,

    fn deinit(self: *PersistentPostingList, allocator: std.mem.Allocator) void {
        self.overflow.deinit(allocator);
    }

    fn append(self: *PersistentPostingList, allocator: std.mem.Allocator, posting: TextPostingRecord) !void {
        switch (self.len) {
            0 => {
                self.inline_items[0] = posting;
                self.len = 1;
            },
            1 => {
                try self.overflow.ensureTotalCapacity(allocator, 2);
                if (self.overflow.items.len == 0) {
                    self.overflow.appendAssumeCapacity(self.inline_items[0]);
                } else if (self.overflow.items.len != 1) {
                    return error.InvalidRecord;
                }
                self.overflow.appendAssumeCapacity(posting);
                self.len = 2;
            },
            else => {
                try self.overflow.append(allocator, posting);
                self.len += 1;
            },
        }
    }

    fn ensureUnusedCapacity(self: *PersistentPostingList, allocator: std.mem.Allocator, additional: usize) !void {
        if (additional == 0) return;
        if (self.len <= 1 and self.len + additional <= 1) return;
        if (self.len == 1 and self.overflow.items.len == 0) {
            try self.overflow.ensureTotalCapacity(allocator, self.len + additional);
            self.overflow.appendAssumeCapacity(self.inline_items[0]);
            return;
        }
        try self.overflow.ensureUnusedCapacity(allocator, additional);
    }

    fn appendAssumeCapacity(self: *PersistentPostingList, posting: TextPostingRecord) void {
        switch (self.len) {
            0 => {
                self.inline_items[0] = posting;
                self.len = 1;
            },
            1 => {
                std.debug.assert(self.overflow.items.len == 1);
                self.overflow.appendAssumeCapacity(posting);
                self.len = 2;
            },
            else => {
                self.overflow.appendAssumeCapacity(posting);
                self.len += 1;
            },
        }
    }

    pub fn items(self: *const PersistentPostingList) []const TextPostingRecord {
        return switch (self.len) {
            0 => &.{},
            1 => self.inline_items[0..1],
            else => self.overflow.items,
        };
    }

    fn trimCapacity(self: *PersistentPostingList, allocator: std.mem.Allocator) !void {
        switch (self.len) {
            0, 1 => {
                self.overflow.deinit(allocator);
                self.overflow = .empty;
            },
            else => {
                if (self.overflow.items.len != self.len) return error.InvalidRecord;
                self.overflow.shrinkAndFree(allocator, self.len);
            },
        }
    }
};

const PersistentTermBuilder = struct {
    allocator: std.mem.Allocator,
    terms: std.ArrayList(PersistentTerm),
    term_index: std.StringHashMap(usize),
    term_index_active: bool = true,

    fn init(allocator: std.mem.Allocator) PersistentTermBuilder {
        return .{
            .allocator = allocator,
            .terms = .empty,
            .term_index = std.StringHashMap(usize).init(allocator),
        };
    }

    fn deinit(self: *PersistentTermBuilder) void {
        for (self.terms.items) |*term| {
            self.allocator.free(term.term);
            term.postings.deinit(self.allocator);
        }
        self.terms.deinit(self.allocator);
        if (self.term_index_active) self.term_index.deinit();
    }

    fn addDocument(self: *PersistentTermBuilder, doc_id: u64, text: []const u8, kind: []const u8) !void {
        _ = kind;
        var freqs = std.StringHashMap(FieldTermFreq).init(self.allocator);
        defer freqs.deinit();
        var owned = std.ArrayList([]u8).empty;
        defer {
            for (owned.items) |term| self.allocator.free(term);
            owned.deinit(self.allocator);
        }
        _ = try collectTermFreqs(self.allocator, &freqs, &owned, text, .text);
        try self.addDocumentFreqs(doc_id, &freqs);
    }

    pub fn addDocumentFreqs(self: *PersistentTermBuilder, doc_id: u64, freqs: *std.StringHashMap(FieldTermFreq)) !void {
        if (!self.term_index_active) return error.InvalidRecord;
        var pending_terms = std.ArrayList(PendingPersistentTerm).empty;
        defer {
            for (pending_terms.items) |*pending| {
                self.allocator.free(pending.term);
                pending.postings.deinit(self.allocator);
            }
            pending_terms.deinit(self.allocator);
        }

        var new_term_count: usize = 0;
        var it = freqs.iterator();
        while (it.next()) |entry| {
            if (self.term_index.get(entry.key_ptr.*) == null) {
                new_term_count += 1;
                var postings = PersistentPostingList{};
                errdefer postings.deinit(self.allocator);
                try postings.append(self.allocator, .{
                    .doc_id = doc_id,
                    .text_freq = entry.value_ptr.text,
                    .kind_freq = entry.value_ptr.kind,
                });
                const owned_term = try self.allocator.dupe(u8, entry.key_ptr.*);
                errdefer self.allocator.free(owned_term);
                try pending_terms.append(self.allocator, .{ .term = owned_term, .postings = postings });
            }
        }

        try self.terms.ensureUnusedCapacity(self.allocator, new_term_count);
        try self.term_index.ensureUnusedCapacity(@intCast(new_term_count));

        it = freqs.iterator();
        while (it.next()) |entry| {
            if (self.term_index.get(entry.key_ptr.*)) |idx| {
                try self.terms.items[idx].postings.ensureUnusedCapacity(self.allocator, 1);
            }
        }

        it = freqs.iterator();
        while (it.next()) |entry| {
            if (self.term_index.get(entry.key_ptr.*)) |idx| {
                self.terms.items[idx].postings.appendAssumeCapacity(.{
                    .doc_id = doc_id,
                    .text_freq = entry.value_ptr.text,
                    .kind_freq = entry.value_ptr.kind,
                });
            }
        }

        for (pending_terms.items) |pending| {
            const idx = self.terms.items.len;
            self.terms.appendAssumeCapacity(.{ .term = pending.term, .postings = pending.postings });
            self.term_index.putAssumeCapacityNoClobber(pending.term, idx);
        }
        pending_terms.clearRetainingCapacity();
    }

    fn releaseTermIndex(self: *PersistentTermBuilder) void {
        if (!self.term_index_active) return;
        self.term_index.deinit();
        self.term_index_active = false;
    }

    fn trimCapacity(self: *PersistentTermBuilder) !void {
        for (self.terms.items) |*term| {
            try term.postings.trimCapacity(self.allocator);
        }
        self.terms.shrinkAndFree(self.allocator, self.terms.items.len);
    }
};

fn textTermTopHitLessThan(_: void, lhs: TextTermTopHitRecord, rhs: TextTermTopHitRecord) bool {
    const lhs_finite = std.math.isFinite(lhs.score);
    const rhs_finite = std.math.isFinite(rhs.score);
    if (lhs_finite != rhs_finite) return lhs_finite;
    if (lhs_finite and lhs.score != rhs.score) return lhs.score > rhs.score;
    if (lhs.node_id != 0 and rhs.node_id != 0) return lhs.node_id < rhs.node_id;
    return lhs.doc_id < rhs.doc_id;
}

fn textTermTopHitScoreOrderValid(previous: TextTermTopHitRecord, current: TextTermTopHitRecord) bool {
    if (!std.math.isFinite(previous.score) or !std.math.isFinite(current.score)) return false;
    return previous.score >= current.score;
}

fn findWorstTextTermTopHitIndex(hits: []const TextTermTopHitRecord) usize {
    var worst_index: usize = 0;
    for (hits[1..], 1..) |candidate, i| {
        if (textTermTopHitLessThan({}, hits[worst_index], candidate)) worst_index = i;
    }
    return worst_index;
}

fn appendTopTextTermHitBoundedCachedWorst(
    allocator: std.mem.Allocator,
    hits: *std.ArrayList(TextTermTopHitRecord),
    limit: usize,
    worst_index: *?usize,
    hit: TextTermTopHitRecord,
) !void {
    if (limit == 0) return;
    if (hits.items.len < limit) {
        try hits.append(allocator, hit);
        if (hits.items.len == limit) worst_index.* = findWorstTextTermTopHitIndex(hits.items);
        return;
    }
    const slot = worst_index.* orelse findWorstTextTermTopHitIndex(hits.items);
    if (textTermTopHitLessThan({}, hit, hits.items[slot])) {
        hits.items[slot] = hit;
        worst_index.* = findWorstTextTermTopHitIndex(hits.items);
    } else {
        worst_index.* = slot;
    }
}

fn appendTopTextTermHitBoundedInline(
    hits: *[persistent_term_top_hit_capacity_usize]TextTermTopHitRecord,
    hit_count: *usize,
    limit: usize,
    worst_index: *?usize,
    hit: TextTermTopHitRecord,
) !void {
    if (limit == 0) return;
    if (limit > hits.len) return error.RecordTooLarge;
    if (hit_count.* < limit) {
        hits[hit_count.*] = hit;
        hit_count.* += 1;
        if (hit_count.* == limit) worst_index.* = findWorstTextTermTopHitIndex(hits[0..hit_count.*]);
        return;
    }
    const slot = worst_index.* orelse findWorstTextTermTopHitIndex(hits[0..hit_count.*]);
    if (textTermTopHitLessThan({}, hit, hits[slot])) {
        hits[slot] = hit;
        worst_index.* = findWorstTextTermTopHitIndex(hits[0..hit_count.*]);
    } else {
        worst_index.* = slot;
    }
}

fn persistentMinPossibleDocLen() f32 {
    const weights = TextFieldWeights{};
    // Text-only persistent BM25 has no guaranteed non-zero field outside hits.
    return weights.kind;
}

fn persistentMinPossibleDocLenForPosting(posting: TextPostingRecord) f32 {
    return @max(persistentMinPossibleDocLen(), persistentWeightedTf(posting));
}

fn persistentDocLenLowerBoundForPosting(posting: TextPostingRecord, doc_len_floor: f32) f32 {
    return @max(@max(persistentMinPossibleDocLen(), doc_len_floor), persistentWeightedTf(posting));
}

fn textTermTopHitBlockCannotBeatCurrentWorst(
    hits: []const TextTermTopHitRecord,
    worst_index: ?usize,
    limit: usize,
    block_upper_score: f32,
) bool {
    if (limit == 0 or hits.len < limit) return false;
    const slot = worst_index orelse findWorstTextTermTopHitIndex(hits);
    return block_upper_score < hits[slot].score;
}

fn textTermTopHitCandidateCannotBeatCurrentWorst(
    hits: []const TextTermTopHitRecord,
    worst_index: ?usize,
    limit: usize,
    posting: TextPostingRecord,
    avg_doc_len: f32,
    doc_count: u64,
    doc_freq: u64,
) !bool {
    return textTermTopHitCandidateCannotBeatCurrentWorstWithDocLenFloor(
        hits,
        worst_index,
        limit,
        posting,
        avg_doc_len,
        doc_count,
        doc_freq,
        persistentMinPossibleDocLen(),
    );
}

fn textTermTopHitCandidateCannotBeatCurrentWorstWithDocLenFloor(
    hits: []const TextTermTopHitRecord,
    worst_index: ?usize,
    limit: usize,
    posting: TextPostingRecord,
    avg_doc_len: f32,
    doc_count: u64,
    doc_freq: u64,
    doc_len_floor: f32,
) !bool {
    if (limit == 0 or hits.len < limit) return false;
    const slot = worst_index orelse findWorstTextTermTopHitIndex(hits);
    const upper_score = bm25WeightedTermScore(
        persistentWeightedTf(posting),
        persistentDocLenLowerBoundForPosting(posting, doc_len_floor),
        avg_doc_len,
        doc_count,
        doc_freq,
        .{},
    );
    if (!std.math.isFinite(upper_score)) return core.Error.Unsupported;
    return upper_score < hits[slot].score;
}

fn textMetaPath(allocator: std.mem.Allocator, store: storage_mod.Store) ![]u8 {
    return std.fs.path.join(allocator, &.{ store.dir_path, "text_meta.idx" });
}

fn textDocsPath(allocator: std.mem.Allocator, store: storage_mod.Store) ![]u8 {
    return std.fs.path.join(allocator, &.{ store.dir_path, "text_docs.idx" });
}

fn textTermsPath(allocator: std.mem.Allocator, store: storage_mod.Store) ![]u8 {
    return std.fs.path.join(allocator, &.{ store.dir_path, "text_terms.idx" });
}

fn textPostingsPath(allocator: std.mem.Allocator, store: storage_mod.Store) ![]u8 {
    return std.fs.path.join(allocator, &.{ store.dir_path, "text_postings.dat" });
}

fn textPostingBlocksPath(allocator: std.mem.Allocator, store: storage_mod.Store) ![]u8 {
    return std.fs.path.join(allocator, &.{ store.dir_path, "text_posting_blocks.idx" });
}

fn textPostingBlockImpactsPath(allocator: std.mem.Allocator, store: storage_mod.Store) ![]u8 {
    return std.fs.path.join(allocator, &.{ store.dir_path, "text_posting_block_impacts.idx" });
}

fn textTermTopHitsPath(allocator: std.mem.Allocator, store: storage_mod.Store) ![]u8 {
    return std.fs.path.join(allocator, &.{ store.dir_path, "text_term_top_hits.idx" });
}

fn renameReplace(io: std.Io, tmp_path: []const u8, final_path: []const u8) !void {
    if (std.fs.path.isAbsolute(tmp_path) or std.fs.path.isAbsolute(final_path)) {
        try std.Io.Dir.renameAbsolute(tmp_path, final_path, io);
    } else {
        try std.Io.Dir.rename(.cwd(), tmp_path, .cwd(), final_path, io);
    }
}

fn textOptionsNeedSync(store: storage_mod.Store) bool {
    return switch (store.options.durability) {
        .fast => false,
        .safe => true,
    };
}

const text_write_buffer_bytes: usize = 256 * 1024;
const text_run_read_buffer_bytes: usize = 64 * 1024;
const text_run_summary_block_bytes: usize = 64 * 1024;
const text_run_summary_compressed_magic = "TKGSUM2\n".*;
const text_run_summary_block_header_len: usize = 12;
const text_run_summary_block_flag_compressed: u16 = 1;
const text_run_summary_deflate_level = std.compress.flate.Compress.Options.level_3;

const TextBufferedWriter = struct {
    io: std.Io,
    file: std.Io.File,
    allocator: std.mem.Allocator,
    buffer: []u8,
    len: usize = 0,
    offset: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, file: std.Io.File, capacity: usize) !TextBufferedWriter {
        std.debug.assert(capacity > 0);
        return try initAtOffset(allocator, io, file, capacity, 0);
    }

    pub fn initAtOffset(allocator: std.mem.Allocator, io: std.Io, file: std.Io.File, capacity: usize, offset: u64) !TextBufferedWriter {
        std.debug.assert(capacity > 0);
        return .{
            .io = io,
            .file = file,
            .allocator = allocator,
            .buffer = try allocator.alloc(u8, capacity),
            .offset = offset,
        };
    }

    pub fn deinit(self: *TextBufferedWriter) void {
        self.allocator.free(self.buffer);
    }

    pub fn append(self: *TextBufferedWriter, bytes: []const u8) !void {
        if (bytes.len > self.buffer.len) {
            try self.flush();
            try self.file.writePositionalAll(self.io, bytes, self.offset);
            self.offset = std.math.add(u64, self.offset, bytes.len) catch return error.RecordTooLarge;
            return;
        }
        if (self.len + bytes.len > self.buffer.len) try self.flush();
        @memcpy(self.buffer[self.len .. self.len + bytes.len], bytes);
        self.len += bytes.len;
    }

    pub fn flush(self: *TextBufferedWriter) !void {
        if (self.len == 0) return;
        try self.file.writePositionalAll(self.io, self.buffer[0..self.len], self.offset);
        self.offset = std.math.add(u64, self.offset, self.len) catch return error.RecordTooLarge;
        self.len = 0;
    }
};

fn deflateTextRunSummaryBlock(input: []const u8, output: []u8, flate_buffer: []u8) usize {
    var fixed = std.Io.Writer.fixed(output);
    var compressor = std.compress.flate.Compress.init(&fixed, flate_buffer, .raw, text_run_summary_deflate_level) catch return input.len;
    compressor.writer.writeAll(input) catch return input.len;
    compressor.finish() catch return input.len;
    return fixed.end;
}

const TextPostingRunSummaryWriter = struct {
    allocator: std.mem.Allocator,
    output: TextBufferedWriter,
    raw_buffer: []u8,
    compressed_buffer: []u8,
    flate_buffer: []u8,
    raw_len: usize = 0,
    physical_bytes: u64 = text_run_summary_compressed_magic.len,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, file: std.Io.File) !TextPostingRunSummaryWriter {
        var output = try TextBufferedWriter.init(allocator, io, file, text_write_buffer_bytes);
        errdefer output.deinit();
        const raw_buffer = try allocator.alloc(u8, text_run_summary_block_bytes);
        errdefer allocator.free(raw_buffer);
        const compressed_buffer = try allocator.alloc(u8, text_run_summary_block_bytes * 2 + 1024);
        errdefer allocator.free(compressed_buffer);
        const flate_buffer = try allocator.alloc(u8, std.compress.flate.max_window_len);
        errdefer allocator.free(flate_buffer);

        try output.append(&text_run_summary_compressed_magic);
        return .{
            .allocator = allocator,
            .output = output,
            .raw_buffer = raw_buffer,
            .compressed_buffer = compressed_buffer,
            .flate_buffer = flate_buffer,
        };
    }

    pub fn deinit(self: *TextPostingRunSummaryWriter) void {
        self.allocator.free(self.flate_buffer);
        self.allocator.free(self.compressed_buffer);
        self.allocator.free(self.raw_buffer);
        self.output.deinit();
    }

    pub fn append(self: *TextPostingRunSummaryWriter, bytes: []const u8) !void {
        var pos: usize = 0;
        while (pos < bytes.len) {
            if (self.raw_len == self.raw_buffer.len) try self.flushBlock();
            const n = @min(bytes.len - pos, self.raw_buffer.len - self.raw_len);
            @memcpy(self.raw_buffer[self.raw_len .. self.raw_len + n], bytes[pos .. pos + n]);
            self.raw_len += n;
            pos += n;
        }
    }

    fn flushBlock(self: *TextPostingRunSummaryWriter) !void {
        if (self.raw_len == 0) return;
        const raw = self.raw_buffer[0..self.raw_len];
        const compressed_len = deflateTextRunSummaryBlock(raw, self.compressed_buffer, self.flate_buffer);
        const use_compressed = compressed_len < raw.len;
        const stored = if (use_compressed) self.compressed_buffer[0..compressed_len] else raw;
        if (raw.len > std.math.maxInt(u32) or stored.len > std.math.maxInt(u32)) return error.RecordTooLarge;

        var header: [text_run_summary_block_header_len]u8 = undefined;
        std.mem.writeInt(u32, header[0..4], @intCast(raw.len), .little);
        std.mem.writeInt(u32, header[4..8], @intCast(stored.len), .little);
        std.mem.writeInt(u16, header[8..10], if (use_compressed) text_run_summary_block_flag_compressed else 0, .little);
        std.mem.writeInt(u16, header[10..12], 0, .little);
        try self.output.append(&header);
        try self.output.append(stored);
        self.physical_bytes = std.math.add(u64, self.physical_bytes, header.len) catch return error.RecordTooLarge;
        self.physical_bytes = std.math.add(u64, self.physical_bytes, stored.len) catch return error.RecordTooLarge;
        self.raw_len = 0;
    }

    pub fn flush(self: *TextPostingRunSummaryWriter) !void {
        try self.flushBlock();
        try self.output.flush();
    }
};

fn textWriteBufferCapacity(file_size: u64) !usize {
    const size = std.math.cast(usize, file_size) orelse return error.RecordTooLarge;
    return @min(text_write_buffer_bytes, size);
}

fn textRunReadBufferCapacity(file_size: u64) !usize {
    const size = std.math.cast(usize, file_size) orelse return error.RecordTooLarge;
    return @max(TextPostingRunRecord.max_encoded_len, @min(text_run_read_buffer_bytes, size));
}

const TextPostingRunReader = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    file: std.Io.File,
    buffer: []u8,
    format: TextPostingRunFormat,
    cursor: usize = 0,
    len: usize = 0,
    file_offset: u64 = 0,
    consumed_bytes: u64 = 0,
    file_size: u64,
    current_term: [default_max_token_bytes]u8 = [_]u8{0} ** default_max_token_bytes,
    current_term_len: usize = 0,
    current_term_sort_prefix: u64 = 0,
    previous_doc_id: u32 = 0,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        file: std.Io.File,
        file_size: u64,
    ) !TextPostingRunReader {
        std.debug.assert(file_size != 0);
        if (file_size <= text_posting_run_front_coded_magic.len) return error.InvalidRecord;
        var magic: [text_posting_run_front_coded_magic.len]u8 = undefined;
        const n = try file.readPositionalAll(io, &magic, 0);
        if (n != text_posting_run_front_coded_magic.len) return error.InvalidRecord;
        const format: TextPostingRunFormat = if (std.mem.eql(u8, &magic, &text_posting_run_front_coded_magic))
            .front_coded_terms_delta_posting
        else if (std.mem.eql(u8, &magic, &text_posting_run_front_coded_legacy_magic))
            .front_coded_terms_fixed_posting
        else
            return error.InvalidRecord;
        return .{
            .allocator = allocator,
            .io = io,
            .file = file,
            .buffer = try allocator.alloc(u8, try textRunReadBufferCapacity(file_size)),
            .format = format,
            .file_offset = text_posting_run_front_coded_magic.len,
            .consumed_bytes = text_posting_run_front_coded_magic.len,
            .file_size = file_size,
        };
    }

    pub fn deinit(self: *TextPostingRunReader) void {
        self.allocator.free(self.buffer);
        self.file.close(self.io);
    }

    fn refill(self: *TextPostingRunReader) !void {
        const n = try self.file.readPositionalAll(self.io, self.buffer, self.file_offset);
        if (n == 0) return error.InvalidRecord;
        self.file_offset = std.math.add(u64, self.file_offset, n) catch return error.InvalidRecord;
        self.cursor = 0;
        self.len = n;
    }

    fn readBytes(self: *TextPostingRunReader, out: []u8) !void {
        var written: usize = 0;
        while (written < out.len) {
            if (self.cursor == self.len) try self.refill();
            const available = self.len - self.cursor;
            const n = @min(available, out.len - written);
            @memcpy(out[written .. written + n], self.buffer[self.cursor .. self.cursor + n]);
            self.cursor += n;
            written += n;
        }
    }

    fn readByte(self: *TextPostingRunReader) !u8 {
        if (self.cursor == self.len) try self.refill();
        const byte = self.buffer[self.cursor];
        self.cursor += 1;
        return byte;
    }

    fn minEncodedPostingBytes(self: *const TextPostingRunReader) u64 {
        return switch (self.format) {
            .front_coded_terms_fixed_posting => TextPostingRecord.encoded_len,
            .front_coded_terms_delta_posting => 1,
        };
    }

    fn readTextPostingFields(self: *TextPostingRunReader) !struct { doc_id: u32, text_freq: u16 } {
        if (self.len - self.cursor >= TextPostingRecord.encoded_len) {
            const bytes = self.buffer[self.cursor .. self.cursor + TextPostingRecord.encoded_len];
            self.cursor += TextPostingRecord.encoded_len;
            return .{
                .doc_id = std.mem.readInt(u32, bytes[0..4], .little),
                .text_freq = std.mem.readInt(u16, bytes[4..6], .little),
            };
        }
        var posting_bytes: [TextPostingRecord.encoded_len]u8 = undefined;
        try self.readBytes(&posting_bytes);
        return .{
            .doc_id = std.mem.readInt(u32, posting_bytes[0..4], .little),
            .text_freq = std.mem.readInt(u16, posting_bytes[4..6], .little),
        };
    }

    const DecodedFrontCodedTextPosting = struct {
        doc_id: u32,
        text_freq: u16,
        term_changed: bool,
    };

    const DecodedRunTextPostingFields = struct {
        doc_id: u32,
        text_freq: u16,
        encoded_len: u64,
    };

    const DecodedRunVarint = struct {
        value: u64,
        encoded_len: u64,
    };

    fn readVarint(self: *TextPostingRunReader) !DecodedRunVarint {
        var value: u64 = 0;
        var shift: u6 = 0;
        var count: u64 = 0;
        while (true) {
            const byte = try self.readByte();
            if (shift == 63 and (byte & 0x7f) > 1) return error.InvalidRecord;
            value |= (@as(u64, byte & 0x7f) << shift);
            count += 1;
            if ((byte & 0x80) == 0) return .{ .value = value, .encoded_len = count };
            if (count >= 10) return error.InvalidRecord;
            shift += 7;
        }
    }

    fn readDeltaTextPostingFields(self: *TextPostingRunReader) !DecodedRunTextPostingFields {
        const encoded_delta = try self.readVarint();
        var encoded_len = encoded_delta.encoded_len;
        const tagged_delta = try decodeTaggedCompressedPostingDelta(encoded_delta.value);
        const doc_id = std.math.add(u64, self.previous_doc_id, tagged_delta.doc_delta) catch return error.InvalidRecord;
        if (doc_id > std.math.maxInt(u32)) return error.RecordTooLarge;
        const text_freq: u32 = compressedPostingTagInlineTextFreq(tagged_delta.field_tag) orelse if (compressedPostingTagTextExplicit(tagged_delta.field_tag)) freq: {
            const decoded_freq = try self.readVarint();
            encoded_len += decoded_freq.encoded_len;
            const decoded = try validateCompressedPostingExplicitFreq(tagged_delta.field_tag, decoded_freq.value);
            break :freq decoded;
        } else 0;
        const validated_freq = try validateDenseAllDocsTextFreq(text_freq);
        self.previous_doc_id = @intCast(doc_id);
        return .{ .doc_id = @intCast(doc_id), .text_freq = @intCast(validated_freq), .encoded_len = encoded_len };
    }
    fn readNextFrontCodedTextPosting(self: *TextPostingRunReader) !?DecodedFrontCodedTextPosting {
        return posting_run_codec.readNextFrontCodedTextPosting(self);
    }

    fn nextFrontCodedTermRecord(self: *TextPostingRunReader) !?TextPostingRunRecord {
        const posting = (try self.readNextFrontCodedTextPosting()) orelse return null;
        return try TextPostingRunRecord.initTrustedDecodedTextPostingWithPrefix(
            self.current_term[0..self.current_term_len],
            self.current_term_sort_prefix,
            posting.doc_id,
            posting.text_freq,
        );
    }

    fn nextFrontCodedTermRecordInto(self: *TextPostingRunReader, out: *TextPostingRunRecord) !bool {
        const posting = (try self.readNextFrontCodedTextPosting()) orelse return false;
        if (posting.term_changed) {
            out.* = try TextPostingRunRecord.initTrustedDecodedTextPostingWithPrefix(
                self.current_term[0..self.current_term_len],
                self.current_term_sort_prefix,
                posting.doc_id,
                posting.text_freq,
            );
        } else {
            if (out.term_len != self.current_term_len or out.term_sort_prefix != self.current_term_sort_prefix) return error.InvalidRecord;
            out.doc_id = posting.doc_id;
            out.text_freq = posting.text_freq;
            out.kind_freq = 0;
        }
        return true;
    }

    pub fn nextRecord(self: *TextPostingRunReader) !?TextPostingRunRecord {
        return switch (self.format) {
            .front_coded_terms_fixed_posting, .front_coded_terms_delta_posting => try self.nextFrontCodedTermRecord(),
        };
    }

    pub fn nextRecordInto(self: *TextPostingRunReader, out: *TextPostingRunRecord) !bool {
        return switch (self.format) {
            .front_coded_terms_fixed_posting, .front_coded_terms_delta_posting => try self.nextFrontCodedTermRecordInto(out),
        };
    }
};

const TextPostingRunSummaryFile = struct {
    path: []u8,
    term_count: u64,
    file_size: u64,
    final_stats: ?TextPostingRunSummaryStats = null,
};

const TextPostingRunSummaryReadScratch = struct {
    allocator: std.mem.Allocator,
    compressed_buffer: []u8,
    flate_buffer: []u8,

    fn init(allocator: std.mem.Allocator) !TextPostingRunSummaryReadScratch {
        const compressed_buffer = try allocator.alloc(u8, text_run_summary_block_bytes);
        errdefer allocator.free(compressed_buffer);
        const flate_buffer = try allocator.alloc(u8, std.compress.flate.max_window_len);
        errdefer allocator.free(flate_buffer);
        return .{
            .allocator = allocator,
            .compressed_buffer = compressed_buffer,
            .flate_buffer = flate_buffer,
        };
    }

    fn deinit(self: *TextPostingRunSummaryReadScratch) void {
        self.allocator.free(self.flate_buffer);
        self.allocator.free(self.compressed_buffer);
    }
};

const PostingRunBuilderOps = struct {
    pub const std = @import("std");
    pub const TextBufferedWriter_dep = TextBufferedWriter;
    pub const DenseAllDocsFreqStreamSizeStats_dep = DenseAllDocsFreqStreamSizeStats;
    pub const appendDenseAllDocsFreqStreamFreqs_dep = appendDenseAllDocsFreqStreamFreqs;
    pub const appendDenseAllDocsFreqStreamFreqsWithStats_dep = appendDenseAllDocsFreqStreamFreqsWithStats;
    pub const denseAllDocsFreqStreamSizeStatsForFreqs_dep = denseAllDocsFreqStreamSizeStatsForFreqs;
    pub const validateDenseAllDocsTextFreq_dep = validateDenseAllDocsTextFreq;
    pub const default_max_token_bytes_dep = default_max_token_bytes;
    pub const TextPostingRunSummaryFile_dep = TextPostingRunSummaryFile;
    pub const CollectTextPostingRunSummaryContext_dep = CollectTextPostingRunSummaryContext;
    pub const FieldTermFreq_dep = FieldTermFreq;
    pub const TextPostingRecord_dep = TextPostingRecord;
    pub const TextPostingRunChunkRecord_dep = TextPostingRunChunkRecord;
    pub const TextPostingRunFrontCodedWriter_dep = TextPostingRunFrontCodedWriter;
    pub const TextPostingRunRecord_dep = TextPostingRunRecord;
    pub const TextPostingRunSummaryStats_dep = TextPostingRunSummaryStats;
    pub const TextPostingRunSummaryWriter_dep = TextPostingRunSummaryWriter;
    pub const TextPostingRunTermSummaryRecord_dep = TextPostingRunTermSummaryRecord;
    pub const TextRebuildTextFreqCache_dep = TextRebuildTextFreqCache;
    pub const textPostingRunChunkRecords_dep = textPostingRunChunkRecords;
    pub const termSortPrefixKey_dep = termSortPrefixKey;
    pub const termSortTailKey_dep = termSortTailKey;
    pub const textMonotonicNs_dep = textMonotonicNs;
    pub const textElapsedNs_dep = textElapsedNs;
    pub const text_write_buffer_bytes_dep = text_write_buffer_bytes;
    pub const appendTextPostingRunSummaryRecord_dep = appendTextPostingRunSummaryRecord;
    pub const textBenchTraceRunBuilder_dep = textBenchTraceRunBuilder;
    pub const text_posting_run_direct_merge_fan_in_dep = text_posting_run_direct_merge_fan_in;
    pub const writeMergedTextPostingRunWithSummary_dep = writeMergedTextPostingRunWithSummary;
    pub const text_posting_run_merge_fan_in_dep = text_posting_run_merge_fan_in;
    pub const collectTextPostingRunTermSummariesFromFilesToFile_dep = collectTextPostingRunTermSummariesFromFilesToFile;
    pub const writeSortedTextPostingRunChunkWithSummary_dep = writeSortedTextPostingRunChunkWithSummary;
    pub const collectTextPostingRunSummaryFields_dep = collectTextPostingRunSummaryFields;
    pub const validateTextPostingFields_dep = validateTextPostingFields;
    pub const textPostingRunChunkRecordLessThan_dep = textPostingRunChunkRecordLessThan;
    pub const text_posting_run_record_long_term_threshold_dep = text_posting_run_record_long_term_threshold;
    pub const flushTextPostingRunSummary_dep = flushTextPostingRunSummary;
};
const posting_run_builder = posting_run_builder_mod.PostingRunBuilder(PostingRunBuilderOps);
test {
    _ = posting_run_builder;
}
const VariableAllDocsFreqSlice = posting_run_builder.VariableAllDocsFreqSlice;
const AllDocsRunCandidate = posting_run_builder.AllDocsRunCandidate;
const AllDocsCandidateCacheSlot = posting_run_builder.AllDocsCandidateCacheSlot;
const TextPostingSyntheticRunSource = posting_run_builder.TextPostingSyntheticRunSource;
const TextPostingRunBuilder = posting_run_builder.TextPostingRunBuilder;
const text_posting_run_variable_all_docs_max_freq_cells = posting_run_builder.text_posting_run_variable_all_docs_max_freq_cells;
const text_posting_run_all_docs_candidate_sweep_interval = posting_run_builder.text_posting_run_all_docs_candidate_sweep_interval;

fn textPostingRunIndexLessThan(records: []const TextPostingRunRecord, lhs_index: u32, rhs_index: u32) bool {
    return textPostingRunRecordLessThan({}, records[lhs_index], records[rhs_index]);
}

fn compareTextPostingRunReaderIndex(records: []const TextPostingRunRecord, lhs: usize, rhs: usize) std.math.Order {
    return switch (textPostingRunRecordOrderPtr(&records[lhs], &records[rhs])) {
        .eq => std.math.order(lhs, rhs),
        else => |order| order,
    };
}

const TextPostingRunMerger = struct {
    allocator: std.mem.Allocator,
    readers: std.ArrayList(TextPostingRunReader),
    current_records: std.ArrayList(TextPostingRunRecord),
    queue: std.PriorityQueue(usize, []const TextPostingRunRecord, compareTextPostingRunReaderIndex),

    pub fn init(allocator: std.mem.Allocator, io: std.Io, run_paths: []const []const u8) !TextPostingRunMerger {
        var readers = std.ArrayList(TextPostingRunReader).empty;
        errdefer {
            for (readers.items) |*reader| reader.deinit();
            readers.deinit(allocator);
        }
        try readers.ensureTotalCapacityPrecise(allocator, run_paths.len);

        var current_records = std.ArrayList(TextPostingRunRecord).empty;
        errdefer current_records.deinit(allocator);
        try current_records.ensureTotalCapacityPrecise(allocator, run_paths.len);

        for (run_paths) |run_path| {
            var run_file = try std.Io.Dir.cwd().openFile(io, run_path, .{});
            var run_file_owned = true;
            errdefer if (run_file_owned) run_file.close(io);
            const stat = try run_file.stat(io);
            if (stat.kind != .file) return error.InvalidRecord;
            if (stat.size == 0) {
                run_file.close(io);
                run_file_owned = false;
                continue;
            }
            const reader_index = readers.items.len;
            readers.appendAssumeCapacity(try TextPostingRunReader.init(allocator, io, run_file, stat.size));
            run_file_owned = false;
            const record = (try readers.items[reader_index].nextRecord()) orelse return error.InvalidRecord;
            current_records.appendAssumeCapacity(record);
        }

        var queue = std.PriorityQueue(usize, []const TextPostingRunRecord, compareTextPostingRunReaderIndex).initContext(current_records.items);
        errdefer queue.deinit(allocator);
        try queue.ensureTotalCapacityPrecise(allocator, current_records.items.len);
        for (current_records.items, 0..) |_, reader_index| {
            try queue.push(allocator, reader_index);
        }

        return .{
            .allocator = allocator,
            .readers = readers,
            .current_records = current_records,
            .queue = queue,
        };
    }

    pub fn deinit(self: *TextPostingRunMerger) void {
        self.queue.deinit(self.allocator);
        self.current_records.deinit(self.allocator);
        for (self.readers.items) |*reader| reader.deinit();
        self.readers.deinit(self.allocator);
    }

    fn siftDownRootAfterRecordAdvance(self: *TextPostingRunMerger) void {
        std.debug.assert(self.queue.items.len != 0);
        const target = self.queue.items[0];
        var index: usize = 0;
        while (true) {
            const left = index * 2 + 1;
            if (left >= self.queue.items.len) break;
            const right = left + 1;
            var best = left;
            if (right < self.queue.items.len and
                compareTextPostingRunReaderIndex(self.current_records.items, self.queue.items[right], self.queue.items[left]) == .lt)
            {
                best = right;
            }
            if (compareTextPostingRunReaderIndex(self.current_records.items, self.queue.items[best], target) != .lt) break;
            self.queue.items[index] = self.queue.items[best];
            index = best;
        }
        self.queue.items[index] = target;
    }

    fn siftDownRootAfterRecordAdvanceWithProbe(self: *TextPostingRunMerger, probe: *NextProbe) void {
        std.debug.assert(self.queue.items.len != 0);
        const target = self.queue.items[0];
        var index: usize = 0;
        while (true) {
            const left = index * 2 + 1;
            if (left >= self.queue.items.len) break;
            const right = left + 1;
            var best = left;
            if (right < self.queue.items.len) {
                probe.queue_compare_count += 1;
                if (compareTextPostingRunReaderIndex(self.current_records.items, self.queue.items[right], self.queue.items[left]) == .lt) {
                    best = right;
                }
            }
            probe.queue_compare_count += 1;
            if (compareTextPostingRunReaderIndex(self.current_records.items, self.queue.items[best], target) != .lt) break;
            self.queue.items[index] = self.queue.items[best];
            index = best;
        }
        self.queue.items[index] = target;
    }

    pub const NextProbe = struct {
        reader_ns: u128 = 0,
        queue_ns: u128 = 0,
        queue_compare_count: u64 = 0,
    };

    pub fn next(self: *TextPostingRunMerger) !?TextPostingRunRecord {
        return self.nextWithProbe(null);
    }

    pub fn nextWithProbe(self: *TextPostingRunMerger, probe: ?*NextProbe) !?TextPostingRunRecord {
        const reader_index = self.queue.peek() orelse return null;
        const record = self.current_records.items[reader_index];
        const reader = &self.readers.items[reader_index];
        const reader_start = if (probe != null) textMonotonicNs(reader.io) else 0;
        const has_next_record = try reader.nextRecordInto(&self.current_records.items[reader_index]);
        if (probe) |p| p.reader_ns += textElapsedNs(reader.io, reader_start);
        if (has_next_record) {
            if (!textPostingRunRecordLessThan({}, record, self.current_records.items[reader_index])) return error.InvalidRecord;
            const queue_start = if (probe != null) textMonotonicNs(reader.io) else 0;
            if (probe) |p| {
                self.siftDownRootAfterRecordAdvanceWithProbe(p);
            } else {
                self.siftDownRootAfterRecordAdvance();
            }
            if (probe) |p| p.queue_ns += textElapsedNs(reader.io, queue_start);
        } else {
            const queue_start = if (probe != null) textMonotonicNs(reader.io) else 0;
            _ = self.queue.pop();
            if (probe) |p| p.queue_ns += textElapsedNs(reader.io, queue_start);
        }
        return record;
    }
};

const TextSyntheticPostingRunCursor = struct {
    sources: []const TextPostingSyntheticRunSource,
    source_index: usize = 0,
    doc_index: u64 = 0,

    pub fn nextWithDocCount(self: *TextSyntheticPostingRunCursor, doc_count: u64) !?TextPostingRunRecord {
        if (self.source_index >= self.sources.len) return null;
        const source = self.sources[self.source_index];
        const source_posting_count: u64 = switch (source) {
            .virtual_all_docs => doc_count,
            .variable_all_docs => |variable| @intCast(variable.freqs.len()),
        };
        if (source_posting_count != doc_count) return error.InvalidRecord;
        const doc_id = self.doc_index + 1;
        if (doc_id > source_posting_count) return error.InvalidRecord;
        const record = switch (source) {
            .virtual_all_docs => |virtual| try TextPostingRunRecord.init(virtual.term, .{
                .doc_id = doc_id,
                .text_freq = virtual.text_freq,
                .kind_freq = 0,
            }),
            .variable_all_docs => |variable| try TextPostingRunRecord.init(variable.term, .{
                .doc_id = doc_id,
                .text_freq = variable.freqs.at(@intCast(self.doc_index)),
                .kind_freq = 0,
            }),
        };
        self.doc_index += 1;
        if (self.doc_index == source_posting_count) {
            self.source_index += 1;
            self.doc_index = 0;
        }
        return record;
    }
};

fn writeTextPostingRun(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    records: []TextPostingRunRecord,
) !void {
    std.mem.sort(TextPostingRunRecord, records, {}, textPostingRunRecordLessThan);
    try writeSortedTextPostingRun(allocator, io, path, records);
}

fn writeSortedTextPostingRun(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    records: []const TextPostingRunRecord,
) !void {
    var file = try std.Io.Dir.cwd().createFile(io, path, .{ .read = true, .truncate = true });
    defer file.close(io);
    var writer = try TextBufferedWriter.init(allocator, io, file, text_write_buffer_bytes);
    defer writer.deinit();
    var run_writer = TextPostingRunFrontCodedWriter{ .writer = &writer };
    var expected_size: u64 = try run_writer.writeHeader();
    for (records) |record| {
        const encoded_len = try run_writer.append(record);
        expected_size = std.math.add(u64, expected_size, encoded_len) catch return error.RecordTooLarge;
    }
    try writer.flush();
    const stat = try file.stat(io);
    if (stat.kind != .file or stat.size != expected_size) return error.InvalidRecord;
}

const TextPostingRunFrontCodedWriter = struct {
    writer: *TextBufferedWriter,
    previous_term: [default_max_token_bytes]u8 = [_]u8{0} ** default_max_token_bytes,
    previous_term_len: usize = 0,
    previous_doc_id: u32 = 0,

    pub fn writeHeader(self: *TextPostingRunFrontCodedWriter) !u64 {
        try self.writer.append(&text_posting_run_front_coded_magic);
        return text_posting_run_front_coded_magic.len;
    }

    pub fn append(self: *TextPostingRunFrontCodedWriter, record: TextPostingRunRecord) !u64 {
        return try self.appendCheckedTermPosting(record.term(), try record.toPosting());
    }

    pub fn appendTrusted(self: *TextPostingRunFrontCodedWriter, record: TextPostingRunRecord) !u64 {
        return try self.appendTrustedRecordFields(record.term(), record.doc_id, record.text_freq, record.kind_freq);
    }

    pub fn appendCheckedTermPosting(self: *TextPostingRunFrontCodedWriter, term: []const u8, posting: TextPostingRecord) !u64 {
        return try self.appendEncodedPosting(term, posting);
    }

    pub fn appendTrustedRecordFields(self: *TextPostingRunFrontCodedWriter, term: []const u8, doc_id: u32, text_freq: u16, kind_freq: u8) !u64 {
        try validateTextPostingFields(doc_id, text_freq, kind_freq);
        return try self.appendEncodedPosting(term, .{
            .doc_id = doc_id,
            .text_freq = text_freq,
            .kind_freq = kind_freq,
        });
    }

    fn appendEncodedPosting(self: *TextPostingRunFrontCodedWriter, term: []const u8, posting: TextPostingRecord) !u64 {
        var bytes: [2 + default_max_token_bytes + compressed_posting_max_encoded_len]u8 = undefined;
        var len: usize = 0;
        if (self.previous_term_len == term.len and std.mem.eql(u8, self.previous_term[0..self.previous_term_len], term)) {
            bytes[0] = 0;
            len = 1;
        } else {
            const term_len = std.math.cast(u8, term.len) orelse return error.RecordTooLarge;
            if (term_len == 0) return error.InvalidRecord;
            const shared_prefix = persistentTermCommonPrefixLen(self.previous_term[0..self.previous_term_len], term);
            const suffix_len: u8 = @intCast(term.len - shared_prefix);
            if (shared_prefix > 1 and suffix_len > 0) {
                bytes[0] = text_posting_run_front_coded_prefix_tag_base + shared_prefix;
                bytes[1] = suffix_len;
                @memcpy(bytes[2 .. 2 + suffix_len], term[shared_prefix..]);
                len = 2 + suffix_len;
            } else {
                bytes[0] = term_len;
                @memcpy(bytes[1 .. 1 + term.len], term);
                len = 1 + term.len;
            }
            @memcpy(self.previous_term[0..term.len], term);
            self.previous_term_len = term.len;
            self.previous_doc_id = 0;
        }

        const posting_len = try encodeCompressedTextPosting(posting, self.previous_doc_id, bytes[len..]);
        self.previous_doc_id = @intCast(posting.doc_id);
        len += posting_len;
        try self.writer.append(bytes[0..len]);
        return len;
    }
};

const TextPostingRunWriteMode = enum {
    checked,
    trusted_sorted_records,
};

const TextPostingRunSummaryCollectMode = enum {
    checked,
    trusted_record_fields,
};

fn writeTextPostingRunInOrder(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    records: []const TextPostingRunRecord,
    order: []const u32,
) !void {
    if (order.len != records.len) return error.InvalidRecord;
    var file = try std.Io.Dir.cwd().createFile(io, path, .{ .read = true, .truncate = true });
    defer file.close(io);
    var writer = try TextBufferedWriter.init(allocator, io, file, text_write_buffer_bytes);
    defer writer.deinit();
    var run_writer = TextPostingRunFrontCodedWriter{ .writer = &writer };
    var expected_size: u64 = try run_writer.writeHeader();
    for (order) |index| {
        if (index >= records.len) return error.InvalidRecord;
        const encoded_len = try run_writer.append(records[index]);
        expected_size = std.math.add(u64, expected_size, encoded_len) catch return error.RecordTooLarge;
    }
    try writer.flush();
    const stat = try file.stat(io);
    if (stat.kind != .file or stat.size != expected_size) return error.InvalidRecord;
}

fn writeTextPostingRunInOrderWithSummary(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    summary_path: []const u8,
    records: []const TextPostingRunRecord,
    order: []const u32,
) !TextPostingRunSummaryStats {
    return writeTextPostingRunInOrderWithSummaryMode(allocator, io, path, summary_path, records, order, .checked);
}

fn writeTextPostingRunTrustedOrderWithSummary(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    summary_path: []const u8,
    records: []const TextPostingRunRecord,
    order: []const u32,
) !TextPostingRunSummaryStats {
    return writeTextPostingRunInOrderWithSummaryMode(allocator, io, path, summary_path, records, order, .trusted_sorted_records);
}
const writeTextPostingRunChunkTrustedOrderWithSummary = posting_run_codec.writeTextPostingRunChunkTrustedOrderWithSummary;
const writeSortedTextPostingRunChunkWithSummary = posting_run_codec.writeSortedTextPostingRunChunkWithSummary;
const writeTextPostingRunInOrderWithSummaryMode = posting_run_codec.writeTextPostingRunInOrderWithSummaryMode;

fn collectMergedTextPostingRuns(
    allocator: std.mem.Allocator,
    io: std.Io,
    run_paths: []const []const u8,
) !std.ArrayList(TextPostingRunRecord) {
    var merger = try TextPostingRunMerger.init(allocator, io, run_paths);
    defer merger.deinit();

    var out = std.ArrayList(TextPostingRunRecord).empty;
    errdefer out.deinit(allocator);

    var previous: ?TextPostingRunRecord = null;
    while (try merger.next()) |record| {
        if (previous) |prev| {
            if (!textPostingRunRecordLessThan({}, prev, record)) {
                if (textPostingRunSameTermAndDoc(prev, record)) return error.InvalidRecord;
                return error.InvalidRecord;
            }
        }
        previous = record;
        try out.append(allocator, record);
    }
    return out;
}

const CollectMergedTextPostingRunsContext = struct {
    allocator: std.mem.Allocator,
    out: *std.ArrayList(TextPostingRunRecord),
};

fn collectMergedTextPostingRunRecord(context: *CollectMergedTextPostingRunsContext, record: TextPostingRunRecord) !void {
    try context.out.append(context.allocator, record);
}

fn collectMergedTextPostingRunsWithSynthetic(
    allocator: std.mem.Allocator,
    io: std.Io,
    run_paths: []const []const u8,
    synthetic_sources: []const TextPostingSyntheticRunSource,
    doc_count: u64,
) !std.ArrayList(TextPostingRunRecord) {
    var out = std.ArrayList(TextPostingRunRecord).empty;
    errdefer out.deinit(allocator);
    var context = CollectMergedTextPostingRunsContext{
        .allocator = allocator,
        .out = &out,
    };
    try forEachMergedTextPostingRunWithSynthetic(allocator, io, run_paths, synthetic_sources, doc_count, .none, &context, collectMergedTextPostingRunRecord);
    return out;
}
const writeMergedTextPostingRunWithSummary = posting_run_codec.writeMergedTextPostingRunWithSummary;
const forEachMergedTextPostingRun = posting_run_codec.forEachMergedTextPostingRun;
const forEachMergedTextPostingRunWithSynthetic = posting_run_codec.forEachMergedTextPostingRunWithSynthetic;

const TextPostingRunTermSummaryRecord = struct {
    term_hash: u64,
    postings_count: u64,
    block_count: u64,
    top_hit_count: u64,
    term_len: u16,
    flags: u16 = 0,
    constant_text_freq: u16 = 0,
    term_bytes: [default_max_token_bytes]u8 = [_]u8{0} ** default_max_token_bytes,

    pub const header_len: usize = 40;
    const constant_text_freq_flag: u16 = 1;
    const all_text_freqs_flag: u16 = 2;
    const inline_singleton_flag: u16 = 4;

    fn init(term_bytes: []const u8, postings_count: u64) !TextPostingRunTermSummaryRecord {
        return initWithFreqSummary(term_bytes, postings_count, 0, false, false);
    }

    fn initWithConstantTextFreq(term_bytes: []const u8, postings_count: u64, constant_text_freq: u32) !TextPostingRunTermSummaryRecord {
        return initWithFreqSummary(term_bytes, postings_count, constant_text_freq, constant_text_freq != 0, false);
    }

    pub fn initWithFreqSummary(term_bytes: []const u8, postings_count: u64, constant_text_freq: u32, all_text_freqs: bool, inline_singleton: bool) !TextPostingRunTermSummaryRecord {
        if (term_bytes.len == 0 or term_bytes.len > default_max_token_bytes) return error.InvalidRecord;
        if (postings_count == 0 or postings_count > std.math.maxInt(u32)) return error.InvalidRecord;
        if (inline_singleton and postings_count != 1) return error.InvalidRecord;
        if (constant_text_freq > persistent_posting_max_field_freq) return error.RecordTooLarge;
        var record = TextPostingRunTermSummaryRecord{
            .term_hash = termHash(term_bytes),
            .postings_count = postings_count,
            .block_count = try publishedPostingBlockCount(@intCast(postings_count), persistent_posting_block_size),
            .top_hit_count = persistentTermTopHitCountForPostingCount(postings_count),
            .term_len = @intCast(term_bytes.len),
            .flags = (if (constant_text_freq != 0) constant_text_freq_flag else 0) |
                (if (all_text_freqs) all_text_freqs_flag else 0) |
                (if (inline_singleton) inline_singleton_flag else 0),
            .constant_text_freq = @intCast(constant_text_freq),
        };
        @memcpy(record.term_bytes[0..term_bytes.len], term_bytes);
        return record;
    }

    fn initMerged(term_bytes: []const u8, postings_count: u64, constant_text_freq: u32, all_text_freqs: bool, doc_count: u64) !TextPostingRunTermSummaryRecord {
        var record = try initWithFreqSummary(term_bytes, postings_count, constant_text_freq, all_text_freqs, false);
        if (record.virtualAllDocsTextFreq(doc_count) != null or record.denseAllDocsFreqStream(doc_count)) {
            record.block_count = 0;
        }
        return record;
    }

    fn initMergedFromTrustedFirst(first: TextPostingRunTermSummaryRecord, postings_count: u64, constant_text_freq: u32, all_text_freqs: bool, doc_count: u64) !TextPostingRunTermSummaryRecord {
        if (first.term_len == 0 or first.term_len > default_max_token_bytes) return error.InvalidRecord;
        if (postings_count == 0 or postings_count > std.math.maxInt(u32)) return error.InvalidRecord;
        if (constant_text_freq > persistent_posting_max_field_freq) return error.RecordTooLarge;
        if (constant_text_freq != 0 and !all_text_freqs) return error.InvalidRecord;
        var record = TextPostingRunTermSummaryRecord{
            .term_hash = first.term_hash,
            .postings_count = postings_count,
            .block_count = try publishedPostingBlockCount(@intCast(postings_count), persistent_posting_block_size),
            .top_hit_count = persistentTermTopHitCountForPostingCount(postings_count),
            .term_len = first.term_len,
            .flags = (if (constant_text_freq != 0) constant_text_freq_flag else 0) |
                (if (all_text_freqs) all_text_freqs_flag else 0),
            .constant_text_freq = @intCast(constant_text_freq),
        };
        const term_bytes = first.term();
        @memcpy(record.term_bytes[0..term_bytes.len], term_bytes);
        if (record.virtualAllDocsTextFreq(doc_count) != null or record.denseAllDocsFreqStream(doc_count)) {
            record.block_count = 0;
        }
        return record;
    }

    pub fn packedLen(self: TextPostingRunTermSummaryRecord) u64 {
        return header_len + @as(u64, self.term_len);
    }

    pub fn encodeHeader(self: TextPostingRunTermSummaryRecord, out: *[header_len]u8) void {
        std.mem.writeInt(u64, out[0..8], self.term_hash, .little);
        std.mem.writeInt(u64, out[8..16], self.postings_count, .little);
        std.mem.writeInt(u64, out[16..24], self.block_count, .little);
        std.mem.writeInt(u64, out[24..32], self.top_hit_count, .little);
        std.mem.writeInt(u16, out[32..34], self.term_len, .little);
        std.mem.writeInt(u16, out[34..36], self.flags, .little);
        std.mem.writeInt(u16, out[36..38], self.constant_text_freq, .little);
        @memset(out[38..40], 0);
    }

    fn decode(header: []const u8, term_bytes: []const u8) !TextPostingRunTermSummaryRecord {
        if (header.len != header_len) return error.InvalidRecord;
        if (!allZero(header[38..40])) return error.InvalidRecord;
        const term_len = std.mem.readInt(u16, header[32..34], .little);
        if (term_len == 0 or term_len > default_max_token_bytes) return error.InvalidRecord;
        if (term_bytes.len != term_len) return error.InvalidRecord;
        const flags = std.mem.readInt(u16, header[34..36], .little);
        if ((flags & ~(constant_text_freq_flag | all_text_freqs_flag | inline_singleton_flag)) != 0) return error.InvalidRecord;
        const constant_text_freq = std.mem.readInt(u16, header[36..38], .little);
        if ((flags & constant_text_freq_flag) == 0 and constant_text_freq != 0) return error.InvalidRecord;
        if ((flags & constant_text_freq_flag) != 0 and constant_text_freq == 0) return error.InvalidRecord;
        if ((flags & constant_text_freq_flag) != 0 and (flags & all_text_freqs_flag) == 0) return error.InvalidRecord;
        if ((flags & inline_singleton_flag) != 0 and std.mem.readInt(u64, header[8..16], .little) != 1) return error.InvalidRecord;
        var record = TextPostingRunTermSummaryRecord{
            .term_hash = std.mem.readInt(u64, header[0..8], .little),
            .postings_count = std.mem.readInt(u64, header[8..16], .little),
            .block_count = std.mem.readInt(u64, header[16..24], .little),
            .top_hit_count = std.mem.readInt(u64, header[24..32], .little),
            .term_len = term_len,
            .flags = flags,
            .constant_text_freq = constant_text_freq,
        };
        @memcpy(record.term_bytes[0..term_len], term_bytes);
        if (record.term_hash != termHash(record.term())) return error.InvalidRecord;
        if (record.postings_count == 0 or record.postings_count > std.math.maxInt(u32)) return error.InvalidRecord;
        const natural_block_count = try publishedPostingBlockCount(@intCast(record.postings_count), persistent_posting_block_size);
        if (record.block_count != natural_block_count) return error.InvalidRecord;
        if (record.top_hit_count != persistentTermTopHitCountForPostingCount(record.postings_count)) return error.InvalidRecord;
        return record;
    }

    pub fn term(self: *const TextPostingRunTermSummaryRecord) []const u8 {
        return self.term_bytes[0..self.term_len];
    }

    pub fn constantTextFreq(self: TextPostingRunTermSummaryRecord) u16 {
        return if ((self.flags & constant_text_freq_flag) != 0) self.constant_text_freq else 0;
    }

    pub fn allTextFreqs(self: TextPostingRunTermSummaryRecord) bool {
        return (self.flags & all_text_freqs_flag) != 0;
    }

    pub fn inlineSingleton(self: TextPostingRunTermSummaryRecord) bool {
        return (self.flags & inline_singleton_flag) != 0;
    }

    pub fn virtualAllDocsTextFreq(self: TextPostingRunTermSummaryRecord, doc_count: u64) ?u32 {
        const text_freq = self.constantTextFreq();
        if (!canVirtualizeAllDocsConstantTextFreqTerm(self.postings_count, doc_count, text_freq)) return null;
        return text_freq;
    }

    pub fn denseAllDocsFreqStream(self: TextPostingRunTermSummaryRecord, doc_count: u64) bool {
        return canUseDenseAllDocsFreqStream(self.postings_count, doc_count, self.allTextFreqs(), self.constantTextFreq());
    }
};

fn textPostingRunSummaryRegularConstantTopHitCandidate(summary: TextPostingRunTermSummaryRecord, doc_count: u64) bool {
    return summary.top_hit_count != 0 and
        summary.virtualAllDocsTextFreq(doc_count) == null and
        !summary.denseAllDocsFreqStream(doc_count) and
        summary.constantTextFreq() != 0;
}

const CollectTextPostingRunSummaryContext = struct {
    writer: *TextPostingRunSummaryWriter,
    current_term: [default_max_token_bytes]u8 = [_]u8{0} ** default_max_token_bytes,
    current_term_len: usize = 0,
    previous_flushed_term: [default_max_token_bytes]u8 = [_]u8{0} ** default_max_token_bytes,
    previous_flushed_term_len: usize = 0,
    have_previous_flushed_term: bool = false,
    postings_count: u64 = 0,
    constant_text_freq: u32 = 0,
    inline_singleton: bool = false,
    current_term_materialized_bytes: u64 = 0,
    term_count: u64 = 0,
    term_bytes_len: u64 = 0,
    term_exception_count: u64 = 0,
    summary_file_bytes: u64 = 0,
    total_postings: u64 = 0,
    total_blocks: u64 = 0,
    total_hits: u64 = 0,
    all_text_freqs: bool = false,
    top_hit_terms: u64 = 0,
    top_hit_candidate_postings: u64 = 0,
    top_hit_side_stream_candidates: u64 = 0,
    top_hit_local_side_stream_candidates: u64 = 0,
    inline_singleton_materialized_terms: u64 = 0,
    inline_singleton_materialized_records: u64 = 0,
    inline_singleton_materialized_bytes: u64 = 0,
};

fn collectTextPostingRunSummary(context: *CollectTextPostingRunSummaryContext, record: TextPostingRunRecord, mode: TextPostingRunSummaryCollectMode, materialized_record_bytes: u64) !void {
    const posting = switch (mode) {
        .checked => try record.toPosting(),
        .trusted_record_fields => TextPostingRecord{
            .doc_id = record.doc_id,
            .text_freq = record.text_freq,
            .kind_freq = record.kind_freq,
        },
    };
    try collectTextPostingRunSummaryFields(context, record.term(), posting, materialized_record_bytes);
}

fn collectTextPostingRunSummaryFields(context: *CollectTextPostingRunSummaryContext, term: []const u8, posting: TextPostingRecord, materialized_record_bytes: u64) !void {
    if (context.current_term_len != 0) {
        if (context.current_term_len == term.len and std.mem.eql(u8, context.current_term[0..context.current_term_len], term)) {
            context.postings_count = std.math.add(u64, context.postings_count, 1) catch return error.RecordTooLarge;
            context.current_term_materialized_bytes = std.math.add(u64, context.current_term_materialized_bytes, materialized_record_bytes) catch return error.RecordTooLarge;
            context.inline_singleton = false;
            if (context.constant_text_freq != 0 and (posting.kind_freq != 0 or posting.text_freq != context.constant_text_freq)) {
                context.constant_text_freq = 0;
            }
            context.all_text_freqs = context.all_text_freqs and posting.kind_freq == 0 and posting.text_freq != 0;
            return;
        }
        try flushTextPostingRunSummary(context);
    }

    @memcpy(context.current_term[0..term.len], term);
    context.current_term_len = term.len;
    context.postings_count = 1;
    context.current_term_materialized_bytes = materialized_record_bytes;
    context.inline_singleton = canInlineSingletonPosting(posting);
    context.constant_text_freq = if (posting.kind_freq == 0 and posting.text_freq != 0) posting.text_freq else 0;
    context.all_text_freqs = posting.kind_freq == 0 and posting.text_freq != 0;
}

fn collectTextPostingRunSummaryChecked(context: *CollectTextPostingRunSummaryContext, record: TextPostingRunRecord) !void {
    try collectTextPostingRunSummary(context, record, .checked, 0);
}
const appendTextPostingRunSummaryRecord = posting_run_codec.appendTextPostingRunSummaryRecord;
const flushTextPostingRunSummary = posting_run_codec.flushTextPostingRunSummary;

const TextPostingRunSummaryStats = struct {
    term_count: u64 = 0,
    term_bytes_len: u64 = 0,
    term_exception_count: u64 = 0,
    summary_file_bytes: u64 = 0,
    posting_count: u64 = 0,
    block_count: u64 = 0,
    hit_count: u64 = 0,
    top_hit_term_count: u64 = 0,
    regular_constant_top_hit_term_count: u64 = 0,
    top_hit_candidate_postings: u64 = 0,
    top_hit_side_stream_candidates: u64 = 0,
    top_hit_local_side_stream_candidates: u64 = 0,
    inline_singleton_materialized_terms: u64 = 0,
    inline_singleton_materialized_records: u64 = 0,
    inline_singleton_materialized_bytes: u64 = 0,
    virtual_all_docs_term_count: u64 = 0,
    virtual_all_docs_candidate_records: u64 = 0,
    dense_all_docs_freq_stream_term_count: u64 = 0,
    dense_all_docs_freq_stream_candidate_records: u64 = 0,
    previous_term: [default_max_token_bytes]u8 = [_]u8{0} ** default_max_token_bytes,
    previous_term_len: usize = 0,
    have_previous_term: bool = false,
};
const collectTextPostingRunTermSummariesToFile = posting_run_codec.collectTextPostingRunTermSummariesToFile;

const TextPostingRunSummaryReader = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    file: std.Io.File,
    buffer: []u8,
    cursor: usize = 0,
    len: usize = 0,
    file_offset: u64 = text_run_summary_compressed_magic.len,
    next_index: u64 = 0,
    count: u64,
    file_size: u64,

    fn init(allocator: std.mem.Allocator, io: std.Io, path: []const u8, count: u64, file_size: u64) !TextPostingRunSummaryReader {
        var file = try std.Io.Dir.cwd().openFile(io, path, .{});
        errdefer file.close(io);
        const stat = try file.stat(io);
        if (stat.kind != .file or stat.size != file_size) return error.InvalidRecord;
        if (file_size < text_run_summary_compressed_magic.len) return error.InvalidRecord;
        var magic: [text_run_summary_compressed_magic.len]u8 = undefined;
        const magic_n = try file.readPositionalAll(io, &magic, 0);
        if (magic_n != magic.len or !std.mem.eql(u8, &magic, &text_run_summary_compressed_magic)) return error.InvalidRecord;
        const buffer = try allocator.alloc(u8, text_run_summary_block_bytes);
        errdefer allocator.free(buffer);
        return .{
            .allocator = allocator,
            .io = io,
            .file = file,
            .buffer = buffer,
            .count = count,
            .file_size = file_size,
        };
    }

    fn deinit(self: *TextPostingRunSummaryReader) void {
        self.allocator.free(self.buffer);
        self.file.close(self.io);
    }

    fn refill(self: *TextPostingRunSummaryReader, scratch: *TextPostingRunSummaryReadScratch) !void {
        if (self.file_offset >= self.file_size) return error.InvalidRecord;
        if (self.file_size - self.file_offset < text_run_summary_block_header_len) return error.InvalidRecord;
        var header: [text_run_summary_block_header_len]u8 = undefined;
        const header_n = try self.file.readPositionalAll(self.io, &header, self.file_offset);
        if (header_n != header.len) return error.InvalidRecord;
        self.file_offset = std.math.add(u64, self.file_offset, header.len) catch return error.InvalidRecord;

        const raw_len = std.mem.readInt(u32, header[0..4], .little);
        const stored_len = std.mem.readInt(u32, header[4..8], .little);
        const flags = std.mem.readInt(u16, header[8..10], .little);
        if (std.mem.readInt(u16, header[10..12], .little) != 0) return error.InvalidRecord;
        if (raw_len == 0 or raw_len > text_run_summary_block_bytes) return error.InvalidRecord;
        if (stored_len == 0 or stored_len > text_run_summary_block_bytes) return error.InvalidRecord;
        if ((flags & ~text_run_summary_block_flag_compressed) != 0) return error.InvalidRecord;
        const compressed = (flags & text_run_summary_block_flag_compressed) != 0;
        if (!compressed and stored_len != raw_len) return error.InvalidRecord;
        if (compressed and stored_len >= raw_len) return error.InvalidRecord;
        if (self.file_size - self.file_offset < stored_len) return error.InvalidRecord;

        const raw = self.buffer[0..raw_len];
        if (compressed) {
            const stored = scratch.compressed_buffer[0..stored_len];
            const stored_n = try self.file.readPositionalAll(self.io, stored, self.file_offset);
            if (stored_n != stored.len) return error.InvalidRecord;
            var input_reader: std.Io.Reader = .fixed(stored);
            var decompressor = std.compress.flate.Decompress.init(&input_reader, .raw, scratch.flate_buffer);
            decompressor.reader.readSliceAll(raw) catch return error.InvalidRecord;
        } else {
            const raw_n = try self.file.readPositionalAll(self.io, raw, self.file_offset);
            if (raw_n != raw.len) return error.InvalidRecord;
        }
        self.file_offset = std.math.add(u64, self.file_offset, stored_len) catch return error.InvalidRecord;
        self.cursor = 0;
        self.len = raw.len;
    }

    fn readBytes(self: *TextPostingRunSummaryReader, scratch: *TextPostingRunSummaryReadScratch, out: []u8) !void {
        var written: usize = 0;
        while (written < out.len) {
            if (self.cursor == self.len) try self.refill(scratch);
            const available = self.len - self.cursor;
            const n = @min(available, out.len - written);
            @memcpy(out[written .. written + n], self.buffer[self.cursor .. self.cursor + n]);
            self.cursor += n;
            written += n;
        }
    }

    fn consumeRecord(self: *TextPostingRunSummaryReader, record: TextPostingRunTermSummaryRecord) !TextPostingRunTermSummaryRecord {
        self.next_index += 1;
        return record;
    }

    fn nextRecord(self: *TextPostingRunSummaryReader, scratch: *TextPostingRunSummaryReadScratch) !?TextPostingRunTermSummaryRecord {
        if (self.next_index >= self.count) {
            if (self.cursor != self.len or self.file_offset != self.file_size) return error.InvalidRecord;
            return null;
        }
        if (self.len - self.cursor >= TextPostingRunTermSummaryRecord.header_len) {
            const header = self.buffer[self.cursor .. self.cursor + TextPostingRunTermSummaryRecord.header_len];
            const term_len = std.mem.readInt(u16, header[32..34], .little);
            if (term_len == 0 or term_len > default_max_token_bytes) return error.InvalidRecord;
            const packed_len = TextPostingRunTermSummaryRecord.header_len + @as(usize, term_len);
            if (self.len - self.cursor >= packed_len) {
                const term_start = self.cursor + TextPostingRunTermSummaryRecord.header_len;
                const record = try TextPostingRunTermSummaryRecord.decode(header, self.buffer[term_start .. term_start + term_len]);
                self.cursor += packed_len;
                return try self.consumeRecord(record);
            }
        }
        var header: [TextPostingRunTermSummaryRecord.header_len]u8 = undefined;
        try self.readBytes(scratch, &header);
        const term_len = std.mem.readInt(u16, header[32..34], .little);
        if (term_len == 0 or term_len > default_max_token_bytes) return error.InvalidRecord;
        var term_bytes: [default_max_token_bytes]u8 = undefined;
        try self.readBytes(scratch, term_bytes[0..term_len]);
        const record = try TextPostingRunTermSummaryRecord.decode(&header, term_bytes[0..term_len]);
        return try self.consumeRecord(record);
    }
};

fn textPostingRunSummaryLessThan(_: void, lhs: TextPostingRunTermSummaryRecord, rhs: TextPostingRunTermSummaryRecord) bool {
    return std.mem.order(u8, lhs.term(), rhs.term()) == .lt;
}

fn textPostingRunSummaryOrderPtr(lhs: *const TextPostingRunTermSummaryRecord, rhs: *const TextPostingRunTermSummaryRecord) std.math.Order {
    return std.mem.order(u8, lhs.term(), rhs.term());
}

fn textPostingRunSummaryOrder(lhs: TextPostingRunTermSummaryRecord, rhs: TextPostingRunTermSummaryRecord) std.math.Order {
    return textPostingRunSummaryOrderPtr(&lhs, &rhs);
}

fn textPostingRunSummarySameTerm(lhs: TextPostingRunTermSummaryRecord, rhs: TextPostingRunTermSummaryRecord) bool {
    return std.mem.eql(u8, lhs.term(), rhs.term());
}

fn compareTextPostingRunSummaryReaderIndex(records: []const TextPostingRunTermSummaryRecord, lhs: usize, rhs: usize) std.math.Order {
    return switch (textPostingRunSummaryOrderPtr(&records[lhs], &records[rhs])) {
        .eq => std.math.order(lhs, rhs),
        else => |order| order,
    };
}

const TextPostingRunSummaryMerger = struct {
    allocator: std.mem.Allocator,
    scratch: TextPostingRunSummaryReadScratch,
    readers: std.ArrayList(TextPostingRunSummaryReader),
    current_records: std.ArrayList(TextPostingRunTermSummaryRecord),
    queue: std.PriorityQueue(usize, []const TextPostingRunTermSummaryRecord, compareTextPostingRunSummaryReaderIndex),

    pub fn init(allocator: std.mem.Allocator, io: std.Io, summary_files: []const TextPostingRunSummaryFile) !TextPostingRunSummaryMerger {
        var scratch = try TextPostingRunSummaryReadScratch.init(allocator);
        errdefer scratch.deinit();
        var readers = std.ArrayList(TextPostingRunSummaryReader).empty;
        errdefer {
            for (readers.items) |*reader| reader.deinit();
            readers.deinit(allocator);
        }
        try readers.ensureTotalCapacityPrecise(allocator, summary_files.len);

        var current_records = std.ArrayList(TextPostingRunTermSummaryRecord).empty;
        errdefer current_records.deinit(allocator);
        try current_records.ensureTotalCapacityPrecise(allocator, summary_files.len);

        for (summary_files) |summary_file| {
            if (summary_file.term_count == 0 or summary_file.file_size == 0) return error.InvalidRecord;
            const reader_index = readers.items.len;
            readers.appendAssumeCapacity(try TextPostingRunSummaryReader.init(allocator, io, summary_file.path, summary_file.term_count, summary_file.file_size));
            const record = (try readers.items[reader_index].nextRecord(&scratch)) orelse return error.InvalidRecord;
            current_records.appendAssumeCapacity(record);
        }

        var queue = std.PriorityQueue(usize, []const TextPostingRunTermSummaryRecord, compareTextPostingRunSummaryReaderIndex).initContext(current_records.items);
        errdefer queue.deinit(allocator);
        try queue.ensureTotalCapacityPrecise(allocator, current_records.items.len);
        for (current_records.items, 0..) |_, reader_index| {
            try queue.push(allocator, reader_index);
        }

        return .{
            .allocator = allocator,
            .scratch = scratch,
            .readers = readers,
            .current_records = current_records,
            .queue = queue,
        };
    }

    pub fn deinit(self: *TextPostingRunSummaryMerger) void {
        self.queue.deinit(self.allocator);
        self.current_records.deinit(self.allocator);
        for (self.readers.items) |*reader| reader.deinit();
        self.readers.deinit(self.allocator);
        self.scratch.deinit();
    }

    fn siftDownRootAfterRecordAdvance(self: *TextPostingRunSummaryMerger) void {
        std.debug.assert(self.queue.items.len != 0);
        const target = self.queue.items[0];
        var index: usize = 0;
        while (true) {
            const left = index * 2 + 1;
            if (left >= self.queue.items.len) break;
            const right = left + 1;
            var best = left;
            if (right < self.queue.items.len and
                compareTextPostingRunSummaryReaderIndex(self.current_records.items, self.queue.items[right], self.queue.items[left]) == .lt)
            {
                best = right;
            }
            if (compareTextPostingRunSummaryReaderIndex(self.current_records.items, self.queue.items[best], target) != .lt) break;
            self.queue.items[index] = self.queue.items[best];
            index = best;
        }
        self.queue.items[index] = target;
    }

    pub fn next(self: *TextPostingRunSummaryMerger) !?TextPostingRunTermSummaryRecord {
        const reader_index = self.queue.peek() orelse return null;
        const record = self.current_records.items[reader_index];
        const reader = &self.readers.items[reader_index];
        if (try reader.nextRecord(&self.scratch)) |next_record| {
            if (textPostingRunSummaryOrder(record, next_record) != .lt) return error.InvalidRecord;
            self.current_records.items[reader_index] = next_record;
            self.siftDownRootAfterRecordAdvance();
        } else {
            _ = self.queue.pop();
        }
        return record;
    }
};
const collectTextPostingRunTermSummariesFromFilesToFile = posting_run_codec.collectTextPostingRunTermSummariesFromFilesToFile;

const TextPostingRunMergedSummaryReader = struct {
    merger: TextPostingRunSummaryMerger,
    pending: ?TextPostingRunTermSummaryRecord = null,
    doc_count: u64,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, summary_files: []const TextPostingRunSummaryFile, doc_count: u64) !TextPostingRunMergedSummaryReader {
        return .{
            .merger = try TextPostingRunSummaryMerger.init(allocator, io, summary_files),
            .doc_count = doc_count,
        };
    }

    pub fn deinit(self: *TextPostingRunMergedSummaryReader) void {
        self.merger.deinit();
    }

    pub fn nextRecord(self: *TextPostingRunMergedSummaryReader) !?TextPostingRunTermSummaryRecord {
        const first = if (self.pending) |pending| pending else (try self.merger.next()) orelse return null;
        self.pending = null;
        var postings_count = first.postings_count;
        var constant_text_freq = first.constantTextFreq();
        var all_text_freqs = first.allTextFreqs();

        while (try self.merger.next()) |summary| {
            if (textPostingRunSummarySameTerm(first, summary)) {
                postings_count = std.math.add(u64, postings_count, summary.postings_count) catch return error.RecordTooLarge;
                if (constant_text_freq != 0 and summary.constantTextFreq() != constant_text_freq) {
                    constant_text_freq = 0;
                }
                all_text_freqs = all_text_freqs and summary.allTextFreqs();
                continue;
            }
            if (!textPostingRunSummaryLessThan({}, first, summary)) return error.InvalidRecord;
            self.pending = summary;
            break;
        }

        return try TextPostingRunTermSummaryRecord.initMergedFromTrustedFirst(first, postings_count, constant_text_freq, all_text_freqs, self.doc_count);
    }
};
const addMergedTextPostingRunSummaryStats = posting_run_codec.addMergedTextPostingRunSummaryStats;
const collectTextPostingRunTermSummaryStatsFromFiles = posting_run_codec.collectTextPostingRunTermSummaryStatsFromFiles;

const PostingRunCodecMergeOps = struct {
    pub const std = @import("std");
    pub const core_dep = core;
    pub const default_max_token_bytes_dep = default_max_token_bytes;
    pub const text_posting_run_front_coded_prefix_tag_base_dep = text_posting_run_front_coded_prefix_tag_base;
    pub const text_write_buffer_bytes_dep = text_write_buffer_bytes;
    pub const persistent_term_top_hit_capacity_dep = persistent_term_top_hit_capacity;
    pub const persistent_posting_max_field_freq_dep = persistent_posting_max_field_freq;
    pub const persistent_posting_block_size_dep = persistent_posting_block_size;
    pub const TextPostingRecord_dep = TextPostingRecord;
    pub const TextPostingRunRecord_dep = TextPostingRunRecord;
    pub const TextPostingRunChunkRecord_dep = TextPostingRunChunkRecord;
    pub const TextPostingRunReader_dep = TextPostingRunReader;
    pub const DecodedFrontCodedTextPosting_dep = TextPostingRunReader.DecodedFrontCodedTextPosting;
    pub const DecodedRunTextPostingFields_dep = TextPostingRunReader.DecodedRunTextPostingFields;
    pub const TextBufferedWriter_dep = TextBufferedWriter;
    pub const TextPostingRunSummaryWriter_dep = TextPostingRunSummaryWriter;
    pub const CollectTextPostingRunSummaryContext_dep = CollectTextPostingRunSummaryContext;
    pub const TextPostingRunFrontCodedWriter_dep = TextPostingRunFrontCodedWriter;
    pub const TextPostingRunWriteMode_dep = TextPostingRunWriteMode;
    pub const TextPostingRunSummaryCollectMode_dep = TextPostingRunSummaryCollectMode;
    pub const TextPostingRunSummaryStats_dep = TextPostingRunSummaryStats;
    pub const TextPostingRunMerger_dep = TextPostingRunMerger;
    pub const TextPostingSyntheticRunSource_dep = TextPostingSyntheticRunSource;
    pub const TextSyntheticPostingRunCursor_dep = TextSyntheticPostingRunCursor;
    pub const TextPostingRunTermSummaryRecord_dep = TextPostingRunTermSummaryRecord;
    pub const TextPostingRunSummaryFile_dep = TextPostingRunSummaryFile;
    pub const TextPostingRunSummaryMerger_dep = TextPostingRunSummaryMerger;
    pub const readerReadByte_dep = TextPostingRunReader.readByte;
    pub const readerReadBytes_dep = TextPostingRunReader.readBytes;
    pub const readerMinEncodedPostingBytes_dep = TextPostingRunReader.minEncodedPostingBytes;
    pub const readerReadTextPostingFields_dep = TextPostingRunReader.readTextPostingFields;
    pub const readerReadDeltaTextPostingFields_dep = TextPostingRunReader.readDeltaTextPostingFields;
    pub const termSortPrefixKey_dep = termSortPrefixKey;
    pub const validateTextPostingFields_dep = validateTextPostingFields;
    pub const collectTextPostingRunSummaryFields_dep = collectTextPostingRunSummaryFields;
    pub const collectTextPostingRunSummary_dep = collectTextPostingRunSummary;
    pub const collectTextPostingRunSummaryChecked_dep = collectTextPostingRunSummaryChecked;
    pub const textPostingRunRecordLessThan_dep = textPostingRunRecordLessThan;
    pub const textPostingRunSameTermAndDoc_dep = textPostingRunSameTermAndDoc;
    pub const persistentTermFrontCodedLen_dep = persistentTermFrontCodedLen;
    pub const textPostingRunSummaryLessThan_dep = textPostingRunSummaryLessThan;
    pub const textPostingRunSummarySameTerm_dep = textPostingRunSummarySameTerm;
    pub const canVirtualizeAllDocsConstantTextFreqTerm_dep = canVirtualizeAllDocsConstantTextFreqTerm;
    pub const canUseDenseAllDocsFreqStream_dep = canUseDenseAllDocsFreqStream;
    pub const publishedPostingBlockCount_dep = publishedPostingBlockCount;
    pub const persistentTermTopHitCountForPostingCount_dep = persistentTermTopHitCountForPostingCount;
};
const posting_run_codec = posting_run_codec_merge_mod.PostingRunCodecMerge(PostingRunCodecMergeOps);
test {
    _ = posting_run_codec;
}

test "text write buffer capacity is bounded by file size and cap" {
    try std.testing.expectEqual(@as(usize, TextPostingBlockImpactsHeader.encoded_len), try textWriteBufferCapacity(TextPostingBlockImpactsHeader.encoded_len));
    try std.testing.expectEqual(text_write_buffer_bytes, try textWriteBufferCapacity(text_write_buffer_bytes + 1));
}

test "text posting external runs merge by term and doc id" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const run_a_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "postings-a.run" });
    defer std.testing.allocator.free(run_a_path);
    const run_b_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "postings-b.run" });
    defer std.testing.allocator.free(run_b_path);

    var run_a = [_]TextPostingRunRecord{
        try TextPostingRunRecord.init("storage", .{ .doc_id = 7, .text_freq = 1, .kind_freq = 0 }),
        try TextPostingRunRecord.init("alpha", .{ .doc_id = 5, .text_freq = 1, .kind_freq = 0 }),
    };
    var run_b = [_]TextPostingRunRecord{
        try TextPostingRunRecord.init("storage", .{ .doc_id = 9, .text_freq = 1, .kind_freq = 0 }),
        try TextPostingRunRecord.init("alpha", .{ .doc_id = 3, .text_freq = 2, .kind_freq = 0 }),
    };
    try writeTextPostingRun(std.testing.allocator, std.testing.io, run_a_path, &run_a);
    try writeTextPostingRun(std.testing.allocator, std.testing.io, run_b_path, &run_b);

    var merged = try collectMergedTextPostingRuns(std.testing.allocator, std.testing.io, &.{ run_a_path, run_b_path });
    defer merged.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 4), merged.items.len);
    var pos: usize = 1;
    while (pos < merged.items.len) : (pos += 1) {
        try std.testing.expect(textPostingRunRecordLessThan({}, merged.items[pos - 1], merged.items[pos]));
    }
    try std.testing.expectEqualStrings("alpha", merged.items[0].term());
    try std.testing.expectEqual(@as(u64, 3), merged.items[0].doc_id);
    try std.testing.expectEqualStrings("alpha", merged.items[1].term());
    try std.testing.expectEqual(@as(u64, 5), merged.items[1].doc_id);
}

test "text posting run reader rejects invalid repeated-term posting fields" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const run_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "corrupt-repeat.run" });
    defer std.testing.allocator.free(run_path);

    var records = [_]TextPostingRunRecord{
        try TextPostingRunRecord.init("alpha", .{ .doc_id = 1, .text_freq = 1, .kind_freq = 0 }),
    };
    try writeSortedTextPostingRun(std.testing.allocator, std.testing.io, run_path, &records);

    var file = try std.Io.Dir.cwd().openFile(std.testing.io, run_path, .{ .mode = .read_write });
    defer file.close(std.testing.io);
    var corrupt_repeat = [_]u8{0} ** (1 + TextPostingRecord.encoded_len);
    corrupt_repeat[0] = 0;
    std.mem.writeInt(u32, corrupt_repeat[1..5], 2, .little);
    std.mem.writeInt(u16, corrupt_repeat[5..7], 0, .little);
    try file.writePositionalAll(std.testing.io, &corrupt_repeat, (try file.stat(std.testing.io)).size);

    try std.testing.expectError(
        error.InvalidRecord,
        collectMergedTextPostingRuns(std.testing.allocator, std.testing.io, &.{run_path}),
    );
}

test "text posting external run merger uses exact fan-in scratch" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root = path_buf[0..root_len];

    var run_paths: [4][]u8 = undefined;
    for (&run_paths, 0..) |*run_path, index| {
        run_path.* = try std.fmt.allocPrint(std.testing.allocator, "{s}/fan-in-{d}.run", .{ root, index });
        var term_buf: [32]u8 = undefined;
        const term = try std.fmt.bufPrint(&term_buf, "term-{d}", .{index});
        var records = [_]TextPostingRunRecord{
            try TextPostingRunRecord.init(term, .{ .doc_id = @intCast(index + 1), .text_freq = 1, .kind_freq = 0 }),
        };
        try writeTextPostingRun(std.testing.allocator, std.testing.io, run_path.*, &records);
    }
    defer for (run_paths) |run_path| std.testing.allocator.free(run_path);

    var merger = try TextPostingRunMerger.init(std.testing.allocator, std.testing.io, &run_paths);
    defer merger.deinit();

    try std.testing.expectEqual(run_paths.len, merger.readers.capacity);
    try std.testing.expectEqual(run_paths.len, merger.current_records.capacity);
    try std.testing.expectEqual(run_paths.len, merger.queue.capacity());
}

test "text posting run builder compacts runs before fd fan-in limit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root = path_buf[0..root_len];
    const base_path = try std.fs.path.join(std.testing.allocator, &.{ root, "text_postings.dat" });
    defer std.testing.allocator.free(base_path);

    var builder = try TextPostingRunBuilder.init(std.testing.allocator, std.testing.io, base_path);
    defer builder.deinit();

    const fan_in: usize = 4;
    const run_count = fan_in + 1;
    for (0..run_count) |index| {
        const run_path = try std.fmt.allocPrint(std.testing.allocator, "{s}.manual.{d}.tmp", .{ base_path, index });
        errdefer std.testing.allocator.free(run_path);
        const summary_path = try std.fmt.allocPrint(std.testing.allocator, "{s}.manual.{d}.summary.tmp", .{ base_path, index });
        errdefer std.testing.allocator.free(summary_path);
        var term_buf: [32]u8 = undefined;
        const term = try std.fmt.bufPrint(&term_buf, "term-{d:0>4}", .{index});
        var records = [_]TextPostingRunRecord{
            try TextPostingRunRecord.init(term, .{ .doc_id = @intCast(index + 1), .text_freq = 1, .kind_freq = 0 }),
        };
        var order = [_]u32{0};
        const stats = try writeTextPostingRunInOrderWithSummary(std.testing.allocator, std.testing.io, run_path, summary_path, &records, &order);
        try builder.run_paths.append(std.testing.allocator, run_path);
        try builder.run_summaries.append(std.testing.allocator, .{
            .path = summary_path,
            .term_count = stats.term_count,
            .file_size = stats.summary_file_bytes,
        });
    }

    try builder.compactForFanInLimit(fan_in);
    try std.testing.expect(builder.run_paths.items.len <= fan_in);
    try std.testing.expectEqual(@as(usize, 2), builder.run_paths.items.len);

    var merged = try collectMergedTextPostingRuns(std.testing.allocator, std.testing.io, builder.run_paths.items);
    defer merged.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, run_count), merged.items.len);
    var pos: usize = 1;
    while (pos < merged.items.len) : (pos += 1) {
        try std.testing.expect(textPostingRunRecordLessThan({}, merged.items[pos - 1], merged.items[pos]));
    }
}

test "text posting run builder coalesces summaries without compacting direct-merge runs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root = path_buf[0..root_len];
    const base_path = try std.fs.path.join(std.testing.allocator, &.{ root, "text_postings.dat" });
    defer std.testing.allocator.free(base_path);

    var builder = try TextPostingRunBuilder.init(std.testing.allocator, std.testing.io, base_path);
    defer builder.deinit();

    const fan_in: usize = 4;
    const run_count = fan_in + 1;
    for (0..run_count) |index| {
        const run_path = try std.fmt.allocPrint(std.testing.allocator, "{s}.manual.{d}.tmp", .{ base_path, index });
        errdefer std.testing.allocator.free(run_path);
        const summary_path = try std.fmt.allocPrint(std.testing.allocator, "{s}.manual.{d}.summary.tmp", .{ base_path, index });
        errdefer std.testing.allocator.free(summary_path);
        var term_buf: [32]u8 = undefined;
        const term = try std.fmt.bufPrint(&term_buf, "term-{d:0>4}", .{index});
        var records = [_]TextPostingRunRecord{
            try TextPostingRunRecord.init(term, .{ .doc_id = @intCast(index + 1), .text_freq = 1, .kind_freq = 0 }),
        };
        var order = [_]u32{0};
        const stats = try writeTextPostingRunInOrderWithSummary(std.testing.allocator, std.testing.io, run_path, summary_path, &records, &order);
        try builder.run_paths.append(std.testing.allocator, run_path);
        try builder.run_summaries.append(std.testing.allocator, .{
            .path = summary_path,
            .term_count = stats.term_count,
            .file_size = stats.summary_file_bytes,
        });
    }

    try builder.coalesceSummariesForFinalMergeLimit(fan_in);
    try std.testing.expectEqual(@as(usize, run_count), builder.run_paths.items.len);
    try std.testing.expectEqual(@as(usize, 1), builder.run_summaries.items.len);
    try std.testing.expect(builder.run_summaries.items[0].final_stats != null);

    const summary_stats = try collectTextPostingRunTermSummaryStatsFromFiles(std.testing.allocator, std.testing.io, builder.run_summaries.items, @intCast(run_count), .none);
    try std.testing.expectEqual(@as(u64, @intCast(run_count)), summary_stats.term_count);
    try std.testing.expectEqual(@as(u64, @intCast(run_count)), summary_stats.posting_count);
    const cached_stats = builder.run_summaries.items[0].final_stats.?;
    try std.testing.expectEqual(cached_stats.term_count, summary_stats.term_count);
    try std.testing.expectEqual(cached_stats.posting_count, summary_stats.posting_count);
    try std.testing.expectEqual(cached_stats.term_bytes_len, summary_stats.term_bytes_len);
    try std.testing.expectEqual(cached_stats.term_exception_count, summary_stats.term_exception_count);

    var merged = try collectMergedTextPostingRuns(std.testing.allocator, std.testing.io, builder.run_paths.items);
    defer merged.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, run_count), merged.items.len);
}

test "text posting run builder keeps direct run and summary fan-in fd-safe" {
    try std.testing.expect(text_posting_run_direct_merge_fan_in <= 128);
    try std.testing.expect(text_posting_run_merge_fan_in <= 128);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root = path_buf[0..root_len];
    const base_path = try std.fs.path.join(std.testing.allocator, &.{ root, "text_postings.dat" });
    defer std.testing.allocator.free(base_path);

    var builder = try TextPostingRunBuilder.init(std.testing.allocator, std.testing.io, base_path);
    defer builder.deinit();

    const direct_fan_in: usize = 8;
    const summary_fan_in: usize = 4;
    const run_count = summary_fan_in + 1;
    for (0..run_count) |index| {
        const run_path = try std.fmt.allocPrint(std.testing.allocator, "{s}.manual.{d}.tmp", .{ base_path, index });
        errdefer std.testing.allocator.free(run_path);
        const summary_path = try std.fmt.allocPrint(std.testing.allocator, "{s}.manual.{d}.summary.tmp", .{ base_path, index });
        errdefer std.testing.allocator.free(summary_path);
        var term_buf: [32]u8 = undefined;
        const term = try std.fmt.bufPrint(&term_buf, "term-{d:0>4}", .{index});
        var records = [_]TextPostingRunRecord{
            try TextPostingRunRecord.init(term, .{ .doc_id = @intCast(index + 1), .text_freq = 1, .kind_freq = 0 }),
        };
        var order = [_]u32{0};
        const stats = try writeTextPostingRunInOrderWithSummary(std.testing.allocator, std.testing.io, run_path, summary_path, &records, &order);
        try builder.run_paths.append(std.testing.allocator, run_path);
        try builder.run_summaries.append(std.testing.allocator, .{
            .path = summary_path,
            .term_count = stats.term_count,
            .file_size = stats.summary_file_bytes,
        });
    }

    try builder.compactForFanInLimit(direct_fan_in);
    try std.testing.expectEqual(@as(usize, run_count), builder.run_paths.items.len);
    try builder.coalesceSummariesForFinalMergeLimit(summary_fan_in);
    try std.testing.expectEqual(@as(usize, run_count), builder.run_paths.items.len);
    try std.testing.expectEqual(@as(usize, 1), builder.run_summaries.items.len);

    const final_reader_count = builder.run_paths.items.len + builder.run_summaries.items.len;
    try std.testing.expect(final_reader_count <= direct_fan_in + 1);
}

test "repeated text cache run does not mark mixed existing runs disjoint" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const base_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "mixed-runs" });
    defer std.testing.allocator.free(base_path);

    var builder = try TextPostingRunBuilder.init(std.testing.allocator, std.testing.io, base_path);
    defer builder.deinit();
    try builder.appendRegularRunRecord("regular", .{ .doc_id = 1, .text_freq = 1, .kind_freq = 0 });
    builder.doc_count = 1;
    try builder.flushRun();
    try std.testing.expectEqual(@as(usize, 1), builder.run_paths.items.len);
    try std.testing.expect(!builder.run_paths_disjoint_term_ranges);

    var cache = TextRebuildTextFreqCache.init(std.testing.allocator);
    defer cache.deinit();
    var freqs = std.StringHashMap(FieldTermFreq).init(std.testing.allocator);
    defer freqs.deinit();
    try freqs.put("cached", .{ .text = 1, .kind = 0 });
    const cached = try cache.store("cached-text", 1, &freqs);
    try cached.appendDocId(std.testing.allocator, 1);

    try builder.appendRepeatedTextCacheRun(&cache);
    try std.testing.expect(!builder.run_paths_disjoint_term_ranges);
}

test "text posting run front-coded format derives repeated and prefixed terms" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const run_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "front-coded.run" });
    defer std.testing.allocator.free(run_path);

    var records = [_]TextPostingRunRecord{
        try TextPostingRunRecord.init("benchdoc-alpha", .{ .doc_id = 1, .text_freq = 1, .kind_freq = 0 }),
        try TextPostingRunRecord.init("benchdoc-alpha", .{ .doc_id = 2, .text_freq = 1, .kind_freq = 0 }),
        try TextPostingRunRecord.init("benchdoc-beta", .{ .doc_id = 3, .text_freq = 1, .kind_freq = 0 }),
        try TextPostingRunRecord.init("decision", .{ .doc_id = 3, .text_freq = 2, .kind_freq = 0 }),
    };
    try writeTextPostingRun(std.testing.allocator, std.testing.io, run_path, &records);

    var file = try std.Io.Dir.cwd().openFile(std.testing.io, run_path, .{});
    const stat = try file.stat(std.testing.io);
    const alpha_first_posting_bytes = persistentVarintLen(try taggedCompressedPostingDelta(1, try records[0].toPosting()));
    const alpha_second_posting_bytes = persistentVarintLen(try taggedCompressedPostingDelta(1, try records[1].toPosting()));
    const beta_posting_bytes = persistentVarintLen(try taggedCompressedPostingDelta(3, try records[2].toPosting()));
    const decision_posting_bytes = persistentVarintLen(try taggedCompressedPostingDelta(3, try records[3].toPosting()));
    const full_term_bytes = text_posting_run_front_coded_magic.len +
        (1 + "benchdoc-alpha".len + alpha_first_posting_bytes) +
        (1 + alpha_second_posting_bytes) +
        (1 + "benchdoc-beta".len + beta_posting_bytes) +
        (1 + "decision".len + decision_posting_bytes);
    const front_coded_bytes = text_posting_run_front_coded_magic.len +
        (1 + "benchdoc-alpha".len + alpha_first_posting_bytes) +
        (1 + alpha_second_posting_bytes) +
        (2 + "beta".len + beta_posting_bytes) +
        (1 + "decision".len + decision_posting_bytes);
    const legacy_bytes = text_posting_run_front_coded_magic.len +
        (TextPostingRunRecord.header_len + "benchdoc-alpha".len) * 2 +
        (TextPostingRunRecord.header_len + "benchdoc-beta".len) +
        (TextPostingRunRecord.header_len + "decision".len);
    try std.testing.expectEqual(@as(u64, front_coded_bytes), stat.size);
    try std.testing.expect(stat.size < full_term_bytes);
    try std.testing.expect(stat.size < legacy_bytes);

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

test "text posting run front-coded format keeps max-length full-term tag valid" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const run_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "max-term.run" });
    defer std.testing.allocator.free(run_path);

    var max_term = [_]u8{'x'} ** default_max_token_bytes;
    var records = [_]TextPostingRunRecord{
        try TextPostingRunRecord.init(&max_term, .{ .doc_id = 7, .text_freq = 3, .kind_freq = 0 }),
    };
    try writeTextPostingRun(std.testing.allocator, std.testing.io, run_path, &records);

    var file = try std.Io.Dir.cwd().openFile(std.testing.io, run_path, .{});
    const stat = try file.stat(std.testing.io);
    const posting_bytes = persistentVarintLen(try taggedCompressedPostingDelta(7, try records[0].toPosting()));
    try std.testing.expectEqual(
        @as(u64, text_posting_run_front_coded_magic.len + 1 + default_max_token_bytes + posting_bytes),
        stat.size,
    );

    var reader = try TextPostingRunReader.init(std.testing.allocator, std.testing.io, file, stat.size);
    defer reader.deinit();
    const actual = (try reader.nextRecord()) orelse return error.InvalidRecord;
    try std.testing.expectEqualStrings(&max_term, actual.term());
    try std.testing.expectEqual(@as(u64, 7), actual.doc_id);
    try std.testing.expectEqual(@as(u32, 3), actual.text_freq);
    try std.testing.expect((try reader.nextRecord()) == null);
}

test "text posting run summary stats count inline singleton materialization" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const run_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "singleton-materialized.run" });
    defer std.testing.allocator.free(run_path);
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, run_path) catch {};
    const summary_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "singleton-materialized.summary" });
    defer std.testing.allocator.free(summary_path);
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, summary_path) catch {};

    const records = [_]TextPostingRunRecord{
        try TextPostingRunRecord.init("alpha", .{ .doc_id = 1, .text_freq = 1, .kind_freq = 0 }),
        try TextPostingRunRecord.init("alpha", .{ .doc_id = 2, .text_freq = 1, .kind_freq = 0 }),
        try TextPostingRunRecord.init("beta", .{ .doc_id = 3, .text_freq = 1, .kind_freq = 0 }),
    };
    const order = [_]u32{ 0, 1, 2 };

    const stats = try writeTextPostingRunTrustedOrderWithSummary(std.testing.allocator, std.testing.io, run_path, summary_path, &records, &order);
    try std.testing.expectEqual(@as(u64, 2), stats.term_count);
    try std.testing.expectEqual(@as(u64, 3), stats.posting_count);
    try std.testing.expectEqual(@as(u64, 1), stats.inline_singleton_materialized_terms);
    try std.testing.expectEqual(@as(u64, 1), stats.inline_singleton_materialized_records);
    const beta_posting_bytes = persistentVarintLen(try taggedCompressedPostingDelta(3, try records[2].toPosting()));
    try std.testing.expectEqual(@as(u64, 1 + "beta".len + beta_posting_bytes), stats.inline_singleton_materialized_bytes);
}

test "text posting external run merge rejects duplicate term doc pairs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const run_a_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "dup-a.run" });
    defer std.testing.allocator.free(run_a_path);
    const run_b_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "dup-b.run" });
    defer std.testing.allocator.free(run_b_path);

    var run_a = [_]TextPostingRunRecord{
        try TextPostingRunRecord.init("storage", .{ .doc_id = 7, .text_freq = 1, .kind_freq = 0 }),
    };
    var run_b = [_]TextPostingRunRecord{
        try TextPostingRunRecord.init("storage", .{ .doc_id = 7, .text_freq = 2, .kind_freq = 0 }),
    };
    try writeTextPostingRun(std.testing.allocator, std.testing.io, run_a_path, &run_a);
    try writeTextPostingRun(std.testing.allocator, std.testing.io, run_b_path, &run_b);

    try std.testing.expectError(error.InvalidRecord, collectMergedTextPostingRuns(std.testing.allocator, std.testing.io, &.{ run_a_path, run_b_path }));
}

test "text posting external run reader handles records across read buffer boundary" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const run_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "boundary.run" });
    defer std.testing.allocator.free(run_path);

    const boundary_record_len = TextPostingRunRecord.header_len + "term-0000".len;
    const record_count = (text_run_read_buffer_bytes / boundary_record_len) + 2;
    const records = try std.testing.allocator.alloc(TextPostingRunRecord, record_count);
    defer std.testing.allocator.free(records);
    for (records, 0..) |*record, index| {
        var term_buf: [32]u8 = undefined;
        const term = try std.fmt.bufPrint(&term_buf, "term-{d:0>4}", .{index});
        record.* = try TextPostingRunRecord.init(term, .{ .doc_id = @intCast(index + 1), .text_freq = 1, .kind_freq = 0 });
    }
    try writeTextPostingRun(std.testing.allocator, std.testing.io, run_path, records);

    var merged = try collectMergedTextPostingRuns(std.testing.allocator, std.testing.io, &.{run_path});
    defer merged.deinit(std.testing.allocator);
    try std.testing.expectEqual(record_count, merged.items.len);
    var pos: usize = 1;
    while (pos < merged.items.len) : (pos += 1) {
        try std.testing.expect(textPostingRunRecordLessThan({}, merged.items[pos - 1], merged.items[pos]));
    }
}

test "text posting run builder writes and cleans temporary runs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const base_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "text_postings.dat" });
    defer std.testing.allocator.free(base_path);

    var run_path_copy: []u8 = undefined;
    var summary_path_copy: []u8 = undefined;
    {
        var builder = try TextPostingRunBuilder.init(std.testing.allocator, std.testing.io, base_path);
        defer builder.deinit();

        var freqs = std.StringHashMap(FieldTermFreq).init(std.testing.allocator);
        defer freqs.deinit();
        try freqs.put("storage", .{ .text = 2 });
        try freqs.put("task", .{ .text = 1 });
        try builder.appendDocumentFreqs(1, &freqs);
        try builder.finish();

        try std.testing.expectEqual(@as(usize, 0), builder.run_paths.items.len);
        try std.testing.expectEqual(@as(usize, 1), builder.run_summaries.items.len);
        run_path_copy = try std.fmt.allocPrint(std.testing.allocator, "{s}.virtual_all_docs.tmp", .{base_path});
        summary_path_copy = try std.testing.allocator.dupe(u8, builder.run_summaries.items[0].path);
        var merged = try collectMergedTextPostingRunsWithSynthetic(std.testing.allocator, std.testing.io, builder.run_paths.items, builder.synthetic_run_sources.items, 1);
        defer merged.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 2), merged.items.len);
    }
    defer std.testing.allocator.free(run_path_copy);
    defer std.testing.allocator.free(summary_path_copy);

    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(std.testing.io, run_path_copy, .{}));
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(std.testing.io, summary_path_copy, .{}));
}

test "text posting run builder scratch allocation is exact compact chunk" {
    try std.testing.expectEqual(@as(usize, 48), @sizeOf(AllDocsCandidateCacheSlot));
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(TextPostingRunChunkRecord));

    const chunk_bytes = std.math.mul(usize, textPostingRunChunkRecords(), @sizeOf(TextPostingRunChunkRecord)) catch return error.RecordTooLarge;
    const buffer = try std.testing.allocator.alloc(u8, chunk_bytes + 1024);
    defer std.testing.allocator.free(buffer);

    var fixed = std.heap.FixedBufferAllocator.init(buffer);
    var builder = try TextPostingRunBuilder.init(fixed.allocator(), std.testing.io, "unused");
    defer builder.deinit();

    try std.testing.expectEqual(textPostingRunChunkRecords(), builder.chunk.capacity);
    try std.testing.expectEqual(@as(usize, 0), builder.chunk_term_bytes.capacity);
}

test "text posting run builder shares repeated chunk term bytes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const base_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "text_postings.dat" });
    defer std.testing.allocator.free(base_path);

    var builder = try TextPostingRunBuilder.initWithChunkTiming(std.testing.allocator, std.testing.io, base_path, true);
    defer builder.deinit();

    try builder.appendTermPosting("shared", .{ .doc_id = 1, .text_freq = 1, .kind_freq = 0 });
    try builder.appendTermPosting("shared", .{ .doc_id = 2, .text_freq = 1, .kind_freq = 0 });

    try std.testing.expectEqual(@as(usize, "shared".len), builder.chunk_term_bytes.items.len);
    try std.testing.expectEqual(@as(u32, 0), builder.chunk.items[0].term_offset);
    try std.testing.expectEqual(@as(u32, 0), builder.chunk.items[1].term_offset);
    try std.testing.expectEqual(@as(u64, 1), builder.run_record_term_cache_hits);
    try std.testing.expectEqual(@as(u64, "shared".len), builder.run_record_term_cache_saved_bytes);

    try builder.flushRun();
    try builder.appendTermPosting("shared", .{ .doc_id = 3, .text_freq = 1, .kind_freq = 0 });
    try std.testing.expectEqual(@as(usize, "shared".len), builder.chunk_term_bytes.items.len);
    try std.testing.expectEqual(@as(u32, 0), builder.chunk.items[0].term_offset);
    try std.testing.expectEqual(@as(u64, 1), builder.run_record_term_cache_hits);
}

test "text posting run builder keeps kind out of BM25 postings" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const base_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "text_postings.dat" });
    defer std.testing.allocator.free(base_path);

    var builder = try TextPostingRunBuilder.init(std.testing.allocator, std.testing.io, base_path);
    defer builder.deinit();

    var freqs = std.StringHashMap(FieldTermFreq).init(std.testing.allocator);
    defer freqs.deinit();
    try freqs.put("type", .{ .text = 2 });
    try freqs.put("storage", .{ .text = 1 });
    try builder.appendDocumentFreqs(1, &freqs);
    try builder.finish();

    var merged = try collectMergedTextPostingRunsWithSynthetic(std.testing.allocator, std.testing.io, builder.run_paths.items, builder.synthetic_run_sources.items, 1);
    defer merged.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), merged.items.len);

    var saw_storage = false;
    var saw_type = false;
    for (merged.items) |record| {
        if (std.mem.eql(u8, record.term(), "storage")) {
            saw_storage = true;
            try std.testing.expectEqual(@as(u32, 1), record.text_freq);
            try std.testing.expectEqual(@as(u32, 0), record.kind_freq);
        } else if (std.mem.eql(u8, record.term(), "type")) {
            saw_type = true;
            try std.testing.expectEqual(@as(u32, 2), record.text_freq);
            try std.testing.expectEqual(@as(u32, 0), record.kind_freq);
        } else {
            return error.UnexpectedTerm;
        }
    }
    try std.testing.expect(saw_storage);
    try std.testing.expect(saw_type);
}

test "text posting run builder skips impossible all-doc candidate lookups" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const base_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "text_postings.dat" });
    defer std.testing.allocator.free(base_path);

    var builder = try TextPostingRunBuilder.initWithChunkTiming(std.testing.allocator, std.testing.io, base_path, true);
    defer builder.deinit();

    var freqs = std.StringHashMap(FieldTermFreq).init(std.testing.allocator);
    defer freqs.deinit();

    try freqs.put("common", .{ .text = 1 });
    try builder.appendDocumentFreqs(1, &freqs);

    freqs.clearRetainingCapacity();
    try freqs.put("unique", .{ .text = 1 });
    try builder.appendDocumentFreqs(2, &freqs);
    try builder.finish();

    try std.testing.expectEqual(@as(u64, 1), builder.docs_posting_append_candidate_filter_skip_count);
    try std.testing.expectEqual(@as(u64, 1), builder.docs_posting_append_regular_record_count);
    try std.testing.expectEqual(@as(u64, 0), builder.virtual_all_docs_synthetic_records);

    var merged = try collectMergedTextPostingRunsWithSynthetic(std.testing.allocator, std.testing.io, builder.run_paths.items, builder.synthetic_run_sources.items, 2);
    defer merged.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), merged.items.len);
}

test "text posting run builder counts all-doc candidate lookup misses" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const base_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "text_postings.dat" });
    defer std.testing.allocator.free(base_path);

    var builder = try TextPostingRunBuilder.initWithChunkTiming(std.testing.allocator, std.testing.io, base_path, true);
    defer builder.deinit();

    var freqs = std.StringHashMap(FieldTermFreq).init(std.testing.allocator);
    defer freqs.deinit();

    try freqs.put("common", .{ .text = 1 });
    try builder.appendDocumentFreqs(1, &freqs);

    freqs.clearRetainingCapacity();
    try freqs.put("comzon", .{ .text = 1 });
    try builder.appendDocumentFreqs(2, &freqs);
    try builder.finish();

    try std.testing.expectEqual(@as(u64, 1), builder.docs_posting_append_candidate_lookup_count);
    try std.testing.expectEqual(@as(u64, 1), builder.docs_posting_append_candidate_miss_count);
    try std.testing.expectEqual(@as(u64, 0), builder.docs_posting_append_candidate_filter_skip_count);
    try std.testing.expectEqual(@as(u64, 1), builder.docs_posting_append_regular_record_count);
}

test "text posting run builder caches repeated all-doc candidate hits" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const base_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "text_postings.dat" });
    defer std.testing.allocator.free(base_path);

    var builder = try TextPostingRunBuilder.initWithChunkTiming(std.testing.allocator, std.testing.io, base_path, true);
    defer builder.deinit();

    var freqs = std.StringHashMap(FieldTermFreq).init(std.testing.allocator);
    defer freqs.deinit();

    try freqs.put("common", .{ .text = 1 });
    try builder.appendDocumentFreqs(1, &freqs);
    try builder.appendDocumentFreqs(2, &freqs);
    try builder.appendDocumentFreqs(3, &freqs);
    try builder.finish();

    try std.testing.expectEqual(@as(u64, 2), builder.docs_posting_append_candidate_lookup_count);
    try std.testing.expectEqual(@as(u64, 1), builder.docs_posting_append_candidate_cache_hit_count);
    try std.testing.expectEqual(@as(u64, 2), builder.docs_posting_append_virtual_candidate_hit_count);
    try std.testing.expectEqual(@as(u64, 3), builder.virtual_all_docs_synthetic_records);
}

test "text posting run builder candidate cache separates same-prefix same-length terms" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const base_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "text_postings.dat" });
    defer std.testing.allocator.free(base_path);

    var builder = try TextPostingRunBuilder.initWithChunkTiming(std.testing.allocator, std.testing.io, base_path, true);
    defer builder.deinit();

    const term_a = "observation_1000";
    const term_b = "observation_1001";
    try std.testing.expectEqual(termSortPrefixKey(term_a), termSortPrefixKey(term_b));
    try std.testing.expectEqual(term_a.len, term_b.len);
    try std.testing.expect(TextPostingRunBuilder.allDocsCandidateCacheIndex(TextPostingRunBuilder.allDocsCandidateCacheKey(term_a)) !=
        TextPostingRunBuilder.allDocsCandidateCacheIndex(TextPostingRunBuilder.allDocsCandidateCacheKey(term_b)));

    var candidate_a = AllDocsRunCandidate{ .virtual = .{ .text_freq = 1, .last_seen_doc_id = 1 } };
    var candidate_b = AllDocsRunCandidate{ .virtual = .{ .text_freq = 1, .last_seen_doc_id = 1 } };
    builder.rememberAllDocsCandidateCache(term_a, TextPostingRunBuilder.allDocsCandidateCacheKey(term_a), &candidate_a);
    builder.rememberAllDocsCandidateCache(term_b, TextPostingRunBuilder.allDocsCandidateCacheKey(term_b), &candidate_b);

    try std.testing.expectEqual(&candidate_a, builder.cachedAllDocsCandidate(term_a, TextPostingRunBuilder.allDocsCandidateCacheKey(term_a)).?);
    try std.testing.expectEqual(&candidate_b, builder.cachedAllDocsCandidate(term_b, TextPostingRunBuilder.allDocsCandidateCacheKey(term_b)).?);
}

test "text posting run builder filters all-doc candidates by inner edge bytes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const base_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "text_postings.dat" });
    defer std.testing.allocator.free(base_path);

    var builder = try TextPostingRunBuilder.initWithChunkTiming(std.testing.allocator, std.testing.io, base_path, true);
    defer builder.deinit();

    var freqs = std.StringHashMap(FieldTermFreq).init(std.testing.allocator);
    defer freqs.deinit();

    try freqs.put("common", .{ .text = 1 });
    try builder.appendDocumentFreqs(1, &freqs);

    freqs.clearRetainingCapacity();
    try freqs.put("carbon", .{ .text = 1 });
    try builder.appendDocumentFreqs(2, &freqs);
    try builder.finish();

    try std.testing.expectEqual(@as(u64, 0), builder.docs_posting_append_candidate_lookup_count);
    try std.testing.expectEqual(@as(u64, 0), builder.docs_posting_append_candidate_miss_count);
    try std.testing.expectEqual(@as(u64, 1), builder.docs_posting_append_candidate_filter_skip_count);
    try std.testing.expectEqual(@as(u64, 1), builder.docs_posting_append_regular_record_count);
}

test "text posting run builder measures run record term slack" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const base_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "text_postings.dat" });
    defer std.testing.allocator.free(base_path);

    var builder = try TextPostingRunBuilder.initWithChunkTiming(std.testing.allocator, std.testing.io, base_path, true);
    defer builder.deinit();

    var freqs = std.StringHashMap(FieldTermFreq).init(std.testing.allocator);
    defer freqs.deinit();

    try freqs.put("common", .{ .text = 1 });
    try builder.appendDocumentFreqs(1, &freqs);

    var long_term = [_]u8{'x'} ** (text_posting_run_record_long_term_threshold + 1);
    freqs.clearRetainingCapacity();
    try freqs.put(&long_term, .{ .text = 1 });
    try builder.appendDocumentFreqs(2, &freqs);
    try builder.finish();

    const expected_term_bytes: u64 = "common".len + long_term.len;
    const expected_capacity: u64 = 2 * default_max_token_bytes;
    try std.testing.expectEqual(@as(u64, 1), builder.docs_posting_append_regular_record_count);
    try std.testing.expectEqual(expected_term_bytes, builder.run_record_term_bytes);
    try std.testing.expectEqual(expected_capacity, builder.run_record_inline_capacity_bytes);
    try std.testing.expectEqual(expected_capacity - expected_term_bytes, builder.run_record_term_slack_bytes);
    try std.testing.expectEqual(@as(u64, 1), builder.run_record_long_term_count);
    try std.testing.expectEqual(@as(u64, long_term.len), builder.run_record_max_term_len);
}

test "text posting run builder drops stale candidate byte shapes after sweep" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const base_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "text_postings.dat" });
    defer std.testing.allocator.free(base_path);

    var builder = try TextPostingRunBuilder.initWithChunkTiming(std.testing.allocator, std.testing.io, base_path, true);
    defer builder.deinit();

    var freqs = std.StringHashMap(FieldTermFreq).init(std.testing.allocator);
    defer freqs.deinit();

    try freqs.put("common", .{ .text = 1 });
    try builder.appendDocumentFreqs(1, &freqs);

    var doc_id: u64 = 2;
    while (doc_id <= text_posting_run_all_docs_candidate_sweep_interval) : (doc_id += 1) {
        freqs.clearRetainingCapacity();
        try freqs.put("carbon", .{ .text = 1 });
        try builder.appendDocumentFreqs(doc_id, &freqs);
    }
    try std.testing.expectEqual(@as(usize, 0), builder.all_docs_candidates.count());

    const lookup_count_after_sweep = builder.docs_posting_append_candidate_lookup_count;
    const miss_count_after_sweep = builder.docs_posting_append_candidate_miss_count;
    const skip_count_after_sweep = builder.docs_posting_append_candidate_filter_skip_count;

    freqs.clearRetainingCapacity();
    try freqs.put("carbon", .{ .text = 1 });
    try builder.appendDocumentFreqs(text_posting_run_all_docs_candidate_sweep_interval + 1, &freqs);

    try std.testing.expectEqual(lookup_count_after_sweep, builder.docs_posting_append_candidate_lookup_count);
    try std.testing.expectEqual(miss_count_after_sweep, builder.docs_posting_append_candidate_miss_count);
    try std.testing.expectEqual(skip_count_after_sweep + 1, builder.docs_posting_append_candidate_filter_skip_count);
}

test "text posting run builder synthesizes surviving virtual all-doc candidates outside chunk sort" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const base_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "text_postings.dat" });
    defer std.testing.allocator.free(base_path);

    var builder = try TextPostingRunBuilder.initWithChunkTiming(std.testing.allocator, std.testing.io, base_path, true);
    defer builder.deinit();

    var freqs = std.StringHashMap(FieldTermFreq).init(std.testing.allocator);
    defer freqs.deinit();

    var doc_id: u64 = 1;
    while (doc_id <= persistent_term_top_hit_min_postings) : (doc_id += 1) {
        freqs.clearRetainingCapacity();
        try freqs.put("common", .{ .text = 1 });
        var term_buf: [32]u8 = undefined;
        const unique_term = try std.fmt.bufPrint(&term_buf, "unique-{d}", .{doc_id});
        try freqs.put(unique_term, .{ .text = 1 });
        try builder.appendDocumentFreqs(doc_id, &freqs);
    }
    try builder.finish();

    try std.testing.expectEqual(persistent_term_top_hit_min_postings, builder.chunk_records);
    try std.testing.expectEqual(persistent_term_top_hit_min_postings, builder.virtual_all_docs_synthetic_records);
    try std.testing.expectEqual(@as(usize, 1), builder.run_paths.items.len);
    try std.testing.expectEqual(@as(usize, 1), builder.synthetic_run_sources.items.len);
    builder.releaseBuildScratchAfterFinish();
    try std.testing.expectEqual(@as(usize, 0), builder.chunk.capacity);
    try std.testing.expectEqual(@as(usize, 0), builder.chunk_term_bytes.capacity);
    try std.testing.expectEqual(@as(usize, 0), builder.all_docs_candidates.capacity());

    const summary_stats = try collectTextPostingRunTermSummaryStatsFromFiles(std.testing.allocator, std.testing.io, builder.run_summaries.items, persistent_term_top_hit_min_postings, .none);
    try std.testing.expectEqual(@as(u64, persistent_term_top_hit_min_postings + 1), summary_stats.term_count);
    try std.testing.expectEqual(@as(u64, persistent_term_top_hit_min_postings * 2), summary_stats.posting_count);
    try std.testing.expectEqual(@as(u64, 1), summary_stats.virtual_all_docs_term_count);
    try std.testing.expectEqual(@as(u64, persistent_term_top_hit_min_postings), summary_stats.virtual_all_docs_candidate_records);

    var merged = try collectMergedTextPostingRunsWithSynthetic(std.testing.allocator, std.testing.io, builder.run_paths.items, builder.synthetic_run_sources.items, persistent_term_top_hit_min_postings);
    defer merged.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, persistent_term_top_hit_min_postings * 2), merged.items.len);
    var common_count: usize = 0;
    for (merged.items) |record| {
        if (std.mem.eql(u8, record.term(), "common")) common_count += 1;
    }
    try std.testing.expectEqual(@as(usize, persistent_term_top_hit_min_postings), common_count);
}

test "text posting run builder synthesizes variable all-doc text freq candidates outside chunk sort" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const base_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "text_postings.dat" });
    defer std.testing.allocator.free(base_path);

    var builder = try TextPostingRunBuilder.initWithChunkTiming(std.testing.allocator, std.testing.io, base_path, true);
    defer builder.deinit();

    var freqs = std.StringHashMap(FieldTermFreq).init(std.testing.allocator);
    defer freqs.deinit();

    var doc_id: u64 = 1;
    while (doc_id <= persistent_term_top_hit_min_postings) : (doc_id += 1) {
        freqs.clearRetainingCapacity();
        try freqs.put("variable", .{ .text = @intCast(1 + (doc_id % 3)) });
        var term_buf: [32]u8 = undefined;
        const unique_term = try std.fmt.bufPrint(&term_buf, "unique-{d}", .{doc_id});
        try freqs.put(unique_term, .{ .text = 1 });
        try builder.appendDocumentFreqs(doc_id, &freqs);
    }
    try builder.finish();

    try std.testing.expectEqual(persistent_term_top_hit_min_postings, builder.chunk_records);
    try std.testing.expectEqual(@as(u64, 0), builder.virtual_all_docs_synthetic_records);
    try std.testing.expectEqual(persistent_term_top_hit_min_postings, builder.variable_all_docs_synthetic_records);
    try std.testing.expectEqual(@as(usize, 1), builder.run_paths.items.len);
    try std.testing.expectEqual(@as(usize, 1), builder.synthetic_run_sources.items.len);
    switch (builder.synthetic_run_sources.items[0]) {
        .variable_all_docs => |variable| {
            try std.testing.expectEqual(@as(usize, 1), variable.freqs.elementSize());
            try std.testing.expectEqual(@as(u32, 2), variable.freqs.at(0));
        },
        else => return error.InvalidRecord,
    }
    builder.releaseBuildScratchAfterFinish();
    try std.testing.expectEqual(@as(usize, 0), builder.chunk.capacity);
    try std.testing.expectEqual(@as(usize, 0), builder.chunk_term_bytes.capacity);
    try std.testing.expectEqual(@as(usize, 0), builder.all_docs_candidates.capacity());

    const summary_stats = try collectTextPostingRunTermSummaryStatsFromFiles(std.testing.allocator, std.testing.io, builder.run_summaries.items, persistent_term_top_hit_min_postings, .none);
    try std.testing.expectEqual(@as(u64, persistent_term_top_hit_min_postings + 1), summary_stats.term_count);
    try std.testing.expectEqual(@as(u64, persistent_term_top_hit_min_postings * 2), summary_stats.posting_count);
    try std.testing.expectEqual(@as(u64, 1), summary_stats.dense_all_docs_freq_stream_term_count);
    try std.testing.expectEqual(@as(u64, persistent_term_top_hit_min_postings), summary_stats.dense_all_docs_freq_stream_candidate_records);

    var merged = try collectMergedTextPostingRunsWithSynthetic(std.testing.allocator, std.testing.io, builder.run_paths.items, builder.synthetic_run_sources.items, persistent_term_top_hit_min_postings);
    defer merged.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, persistent_term_top_hit_min_postings * 2), merged.items.len);
    var variable_count: usize = 0;
    for (merged.items) |record| {
        if (std.mem.eql(u8, record.term(), "variable")) variable_count += 1;
    }
    try std.testing.expectEqual(@as(usize, persistent_term_top_hit_min_postings), variable_count);
}

test "text posting run builder materializes virtual all-doc gaps on reappearance and finish" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const base_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "text_postings.dat" });
    defer std.testing.allocator.free(base_path);

    var builder = try TextPostingRunBuilder.init(std.testing.allocator, std.testing.io, base_path);
    defer builder.deinit();

    var freqs = std.StringHashMap(FieldTermFreq).init(std.testing.allocator);
    defer freqs.deinit();

    try freqs.put("common", .{ .text = 1 });
    try freqs.put("gap", .{ .text = 1 });
    try freqs.put("final-missing", .{ .text = 1 });
    try builder.appendDocumentFreqs(1, &freqs);

    freqs.clearRetainingCapacity();
    try freqs.put("common", .{ .text = 1 });
    try builder.appendDocumentFreqs(2, &freqs);

    freqs.clearRetainingCapacity();
    try freqs.put("common", .{ .text = 1 });
    try freqs.put("gap", .{ .text = 1 });
    try builder.appendDocumentFreqs(3, &freqs);

    try builder.finish();

    var merged = try collectMergedTextPostingRunsWithSynthetic(std.testing.allocator, std.testing.io, builder.run_paths.items, builder.synthetic_run_sources.items, 3);
    defer merged.deinit(std.testing.allocator);

    var common_count: usize = 0;
    var gap_doc_sum: u64 = 0;
    var gap_count: usize = 0;
    var final_missing_count: usize = 0;
    for (merged.items) |record| {
        if (std.mem.eql(u8, record.term(), "common")) {
            common_count += 1;
        } else if (std.mem.eql(u8, record.term(), "gap")) {
            gap_count += 1;
            gap_doc_sum += record.doc_id;
        } else if (std.mem.eql(u8, record.term(), "final-missing")) {
            final_missing_count += 1;
            try std.testing.expectEqual(@as(u64, 1), record.doc_id);
        } else {
            return error.UnexpectedTerm;
        }
    }
    try std.testing.expectEqual(@as(usize, 3), common_count);
    try std.testing.expectEqual(@as(usize, 2), gap_count);
    try std.testing.expectEqual(@as(u64, 4), gap_doc_sum);
    try std.testing.expectEqual(@as(usize, 1), final_missing_count);
    try std.testing.expectEqual(@as(u64, 3), builder.virtual_all_docs_synthetic_records);
    try std.testing.expectEqual(@as(usize, 1), builder.synthetic_run_sources.items.len);
}

test "text posting run builder materializes variable all-doc gaps on reappearance" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const base_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "text_postings.dat" });
    defer std.testing.allocator.free(base_path);

    var builder = try TextPostingRunBuilder.init(std.testing.allocator, std.testing.io, base_path);
    defer builder.deinit();

    var freqs = std.StringHashMap(FieldTermFreq).init(std.testing.allocator);
    defer freqs.deinit();

    try freqs.put("variable-gap", .{ .text = 1 });
    try builder.appendDocumentFreqs(1, &freqs);

    freqs.clearRetainingCapacity();
    try freqs.put("variable-gap", .{ .text = 2 });
    try builder.appendDocumentFreqs(2, &freqs);

    freqs.clearRetainingCapacity();
    try builder.appendDocumentFreqs(3, &freqs);

    freqs.clearRetainingCapacity();
    try freqs.put("variable-gap", .{ .text = 3 });
    try builder.appendDocumentFreqs(4, &freqs);

    try builder.finish();

    var merged = try collectMergedTextPostingRunsWithSynthetic(std.testing.allocator, std.testing.io, builder.run_paths.items, builder.synthetic_run_sources.items, 4);
    defer merged.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), merged.items.len);
    try std.testing.expectEqual(@as(usize, 0), builder.synthetic_run_sources.items.len);
    try std.testing.expectEqual(@as(u64, 0), builder.variable_all_docs_synthetic_records);
    try std.testing.expectEqual(@as(u64, 1), merged.items[0].doc_id);
    try std.testing.expectEqual(@as(u32, 1), merged.items[0].text_freq);
    try std.testing.expectEqual(@as(u64, 2), merged.items[1].doc_id);
    try std.testing.expectEqual(@as(u32, 2), merged.items[1].text_freq);
    try std.testing.expectEqual(@as(u64, 4), merged.items[2].doc_id);
    try std.testing.expectEqual(@as(u32, 3), merged.items[2].text_freq);
}

test "text posting run builder widens variable all-doc freq lane for large frequencies" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const base_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "text_postings.dat" });
    defer std.testing.allocator.free(base_path);

    var builder = try TextPostingRunBuilder.initWithChunkTiming(std.testing.allocator, std.testing.io, base_path, true);
    defer builder.deinit();

    var freqs = std.StringHashMap(FieldTermFreq).init(std.testing.allocator);
    defer freqs.deinit();

    try freqs.put("variable", .{ .text = 1 });
    try builder.appendDocumentFreqs(1, &freqs);

    freqs.clearRetainingCapacity();
    try freqs.put("variable", .{ .text = std.math.maxInt(u8) + 1 });
    try builder.appendDocumentFreqs(2, &freqs);
    try builder.finish();

    try std.testing.expectEqual(@as(u64, 2), builder.variable_all_docs_synthetic_records);
    try std.testing.expectEqual(@as(usize, 1), builder.synthetic_run_sources.items.len);
    switch (builder.synthetic_run_sources.items[0]) {
        .variable_all_docs => |variable| {
            try std.testing.expectEqual(@as(usize, 2), variable.freqs.elementSize());
            try std.testing.expectEqual(@as(u32, 1), variable.freqs.at(0));
            try std.testing.expectEqual(@as(u32, std.math.maxInt(u8) + 1), variable.freqs.at(1));
        },
        else => return error.InvalidRecord,
    }

    var merged = try collectMergedTextPostingRunsWithSynthetic(std.testing.allocator, std.testing.io, builder.run_paths.items, builder.synthetic_run_sources.items, 2);
    defer merged.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), merged.items.len);
    try std.testing.expectEqual(@as(u64, 1), merged.items[0].doc_id);
    try std.testing.expectEqual(@as(u32, 1), merged.items[0].text_freq);
    try std.testing.expectEqual(@as(u64, 2), merged.items[1].doc_id);
    try std.testing.expectEqual(@as(u32, std.math.maxInt(u8) + 1), merged.items[1].text_freq);
}

test "text posting run builder falls back when variable all-doc freq cells hit cap" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const base_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "text_postings.dat" });
    defer std.testing.allocator.free(base_path);

    var builder = try TextPostingRunBuilder.initWithChunkTiming(std.testing.allocator, std.testing.io, base_path, true);
    defer builder.deinit();

    var freqs = std.StringHashMap(FieldTermFreq).init(std.testing.allocator);
    defer freqs.deinit();

    try freqs.put("variable", .{ .text = 1 });
    try builder.appendDocumentFreqs(1, &freqs);

    builder.variable_all_docs_freq_cells = text_posting_run_variable_all_docs_max_freq_cells;
    freqs.clearRetainingCapacity();
    try freqs.put("variable", .{ .text = 2 });
    try builder.appendDocumentFreqs(2, &freqs);
    try builder.finish();

    try std.testing.expect(builder.variable_all_docs_disabled);
    try std.testing.expectEqual(@as(u64, 0), builder.variable_all_docs_synthetic_records);

    var merged = try collectMergedTextPostingRuns(std.testing.allocator, std.testing.io, builder.run_paths.items);
    defer merged.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), merged.items.len);
    try std.testing.expectEqual(@as(u64, 1), merged.items[0].doc_id);
    try std.testing.expectEqual(@as(u32, 1), merged.items[0].text_freq);
    try std.testing.expectEqual(@as(u64, 2), merged.items[1].doc_id);
    try std.testing.expectEqual(@as(u32, 2), merged.items[1].text_freq);
}

test "text posting run summaries stream through packed temp file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const run_a_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "summary-a.run" });
    defer std.testing.allocator.free(run_a_path);
    const run_b_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "summary-b.run" });
    defer std.testing.allocator.free(run_b_path);
    const summary_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "text_postings.dat.summaries.tmp" });
    defer std.testing.allocator.free(summary_path);

    var run_a = [_]TextPostingRunRecord{
        try TextPostingRunRecord.init("storage", .{ .doc_id = 7, .text_freq = 1, .kind_freq = 0 }),
        try TextPostingRunRecord.init("alpha", .{ .doc_id = 5, .text_freq = 1, .kind_freq = 0 }),
    };
    var run_b = [_]TextPostingRunRecord{
        try TextPostingRunRecord.init("storage", .{ .doc_id = 9, .text_freq = 1, .kind_freq = 0 }),
        try TextPostingRunRecord.init("alpha", .{ .doc_id = 3, .text_freq = 2, .kind_freq = 0 }),
    };
    try writeTextPostingRun(std.testing.allocator, std.testing.io, run_a_path, &run_a);
    try writeTextPostingRun(std.testing.allocator, std.testing.io, run_b_path, &run_b);

    const stats = try collectTextPostingRunTermSummariesToFile(std.testing.allocator, std.testing.io, &.{ run_a_path, run_b_path }, summary_path, .none);
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, summary_path) catch {};
    try std.testing.expectEqual(@as(u64, 2), stats.term_count);
    try std.testing.expectEqual(@as(u64, 4), stats.posting_count);
    const expected_term_bytes_len =
        try persistentTermFrontCodedLen(0, null, "alpha") +
        try persistentTermFrontCodedLen(1, "alpha", "storage");
    try std.testing.expectEqual(@as(u64, expected_term_bytes_len), stats.term_bytes_len);
    const raw_summary_bytes = @as(u64, 2 * TextPostingRunTermSummaryRecord.header_len + "alpha".len + "storage".len);
    try std.testing.expect(stats.summary_file_bytes > text_run_summary_compressed_magic.len);
    try std.testing.expect(stats.summary_file_bytes <= raw_summary_bytes + text_run_summary_compressed_magic.len + text_run_summary_block_header_len);
    try std.testing.expectEqual(@as(u64, 0), stats.block_count);
    try std.testing.expectEqual(@as(u64, 0), stats.hit_count);

    var reader = try TextPostingRunSummaryReader.init(std.testing.allocator, std.testing.io, summary_path, stats.term_count, stats.summary_file_bytes);
    defer reader.deinit();
    var scratch = try TextPostingRunSummaryReadScratch.init(std.testing.allocator);
    defer scratch.deinit();
    const alpha = (try reader.nextRecord(&scratch)) orelse return error.InvalidRecord;
    try std.testing.expectEqualStrings("alpha", alpha.term());
    try std.testing.expectEqual(@as(u64, 2), alpha.postings_count);
    const storage = (try reader.nextRecord(&scratch)) orelse return error.InvalidRecord;
    try std.testing.expectEqualStrings("storage", storage.term());
    try std.testing.expectEqual(@as(u64, 2), storage.postings_count);
    try std.testing.expectEqual(@as(?TextPostingRunTermSummaryRecord, null), try reader.nextRecord(&scratch));
}

test "text posting run summaries merge from per-run sidecars" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const run_a_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "summary-sidecar-a.run" });
    defer std.testing.allocator.free(run_a_path);
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, run_a_path) catch {};
    const run_b_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "summary-sidecar-b.run" });
    defer std.testing.allocator.free(run_b_path);
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, run_b_path) catch {};
    const summary_a_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "summary-sidecar-a.tmp" });
    defer std.testing.allocator.free(summary_a_path);
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, summary_a_path) catch {};
    const summary_b_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "summary-sidecar-b.tmp" });
    defer std.testing.allocator.free(summary_b_path);
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, summary_b_path) catch {};
    const merged_summary_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "summary-sidecar-merged.tmp" });
    defer std.testing.allocator.free(merged_summary_path);
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, merged_summary_path) catch {};

    var run_a = [_]TextPostingRunRecord{
        try TextPostingRunRecord.init("alpha", .{ .doc_id = 1, .text_freq = 1, .kind_freq = 0 }),
        try TextPostingRunRecord.init("storage", .{ .doc_id = 2, .text_freq = 1, .kind_freq = 0 }),
        try TextPostingRunRecord.init("storage", .{ .doc_id = 4, .text_freq = 1, .kind_freq = 0 }),
    };
    var run_b = [_]TextPostingRunRecord{
        try TextPostingRunRecord.init("alpha", .{ .doc_id = 3, .text_freq = 1, .kind_freq = 0 }),
        try TextPostingRunRecord.init("storage", .{ .doc_id = 5, .text_freq = 1, .kind_freq = 0 }),
    };
    std.mem.sort(TextPostingRunRecord, &run_a, {}, textPostingRunRecordLessThan);
    std.mem.sort(TextPostingRunRecord, &run_b, {}, textPostingRunRecordLessThan);
    const order_a = [_]u32{ 0, 1, 2 };
    const order_b = [_]u32{ 0, 1 };
    const stats_a = try writeTextPostingRunInOrderWithSummary(std.testing.allocator, std.testing.io, run_a_path, summary_a_path, &run_a, &order_a);
    const stats_b = try writeTextPostingRunInOrderWithSummary(std.testing.allocator, std.testing.io, run_b_path, summary_b_path, &run_b, &order_b);

    var summary_files = [_]TextPostingRunSummaryFile{
        .{ .path = summary_a_path, .term_count = stats_a.term_count, .file_size = stats_a.summary_file_bytes },
        .{ .path = summary_b_path, .term_count = stats_b.term_count, .file_size = stats_b.summary_file_bytes },
    };
    const stats = try collectTextPostingRunTermSummariesFromFilesToFile(std.testing.allocator, std.testing.io, &summary_files, merged_summary_path, null, null, .none);
    try std.testing.expectEqual(@as(u64, 2), stats.term_count);
    try std.testing.expectEqual(@as(u64, 5), stats.posting_count);
    const expected_term_bytes_len =
        try persistentTermFrontCodedLen(0, null, "alpha") +
        try persistentTermFrontCodedLen(1, "alpha", "storage");
    try std.testing.expectEqual(@as(u64, expected_term_bytes_len), stats.term_bytes_len);
    const streaming_stats = try collectTextPostingRunTermSummaryStatsFromFiles(std.testing.allocator, std.testing.io, &summary_files, 9, .none);
    try std.testing.expectEqual(stats.term_count, streaming_stats.term_count);
    try std.testing.expectEqual(stats.posting_count, streaming_stats.posting_count);
    try std.testing.expectEqual(@as(u64, 0), stats.block_count);
    try std.testing.expectEqual(stats.block_count, streaming_stats.block_count);
    try std.testing.expectEqual(stats.term_bytes_len, streaming_stats.term_bytes_len);
    try std.testing.expect(stats.summary_file_bytes > text_run_summary_compressed_magic.len);
    try std.testing.expect(streaming_stats.summary_file_bytes > 0);
    try std.testing.expectEqual(stats.hit_count, streaming_stats.hit_count);
    try std.testing.expectEqual(stats.top_hit_side_stream_candidates, streaming_stats.top_hit_side_stream_candidates);
    try std.testing.expectEqual(stats.top_hit_local_side_stream_candidates, streaming_stats.top_hit_local_side_stream_candidates);

    var reader = try TextPostingRunSummaryReader.init(std.testing.allocator, std.testing.io, merged_summary_path, stats.term_count, stats.summary_file_bytes);
    defer reader.deinit();
    var scratch = try TextPostingRunSummaryReadScratch.init(std.testing.allocator);
    defer scratch.deinit();
    const first = (try reader.nextRecord(&scratch)) orelse return error.InvalidRecord;
    const second = (try reader.nextRecord(&scratch)) orelse return error.InvalidRecord;
    try std.testing.expectEqual(@as(?TextPostingRunTermSummaryRecord, null), try reader.nextRecord(&scratch));
    var streaming_reader = try TextPostingRunMergedSummaryReader.init(std.testing.allocator, std.testing.io, &summary_files, 9);
    defer streaming_reader.deinit();
    const streaming_first = (try streaming_reader.nextRecord()) orelse return error.InvalidRecord;
    const streaming_second = (try streaming_reader.nextRecord()) orelse return error.InvalidRecord;
    try std.testing.expectEqual(@as(?TextPostingRunTermSummaryRecord, null), try streaming_reader.nextRecord());
    try std.testing.expectEqualStrings(first.term(), streaming_first.term());
    try std.testing.expectEqual(first.postings_count, streaming_first.postings_count);
    try std.testing.expectEqualStrings(second.term(), streaming_second.term());
    try std.testing.expectEqual(second.postings_count, streaming_second.postings_count);

    if (std.mem.eql(u8, first.term(), "alpha")) {
        try std.testing.expectEqual(@as(u64, 2), first.postings_count);
        try std.testing.expectEqualStrings("storage", second.term());
        try std.testing.expectEqual(@as(u64, 3), second.postings_count);
    } else {
        try std.testing.expectEqualStrings("storage", first.term());
        try std.testing.expectEqual(@as(u64, 3), first.postings_count);
        try std.testing.expectEqualStrings("alpha", second.term());
        try std.testing.expectEqual(@as(u64, 2), second.postings_count);
    }
}

test "text posting run summary merger uses exact fan-in scratch" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root = path_buf[0..root_len];

    var summary_paths: [4][]u8 = undefined;
    var summary_files: [4]TextPostingRunSummaryFile = undefined;
    for (&summary_paths, 0..) |*summary_path, index| {
        summary_path.* = try std.fmt.allocPrint(std.testing.allocator, "{s}/summary-fan-in-{d}.tmp", .{ root, index });
        var term_buf: [32]u8 = undefined;
        const term = try std.fmt.bufPrint(&term_buf, "summary-{d}", .{index});
        const record = try TextPostingRunTermSummaryRecord.init(term, @intCast(index + 1));
        const stats = try writeTextPostingRunSummaryRecordForTest(summary_path.*, record);
        summary_files[index] = .{
            .path = summary_path.*,
            .term_count = stats.term_count,
            .file_size = stats.summary_file_bytes,
        };
    }
    defer for (summary_paths) |summary_path| std.testing.allocator.free(summary_path);

    var merger = try TextPostingRunSummaryMerger.init(std.testing.allocator, std.testing.io, &summary_files);
    defer merger.deinit();

    try std.testing.expectEqual(summary_files.len, merger.readers.capacity);
    try std.testing.expectEqual(summary_files.len, merger.current_records.capacity);
    try std.testing.expectEqual(summary_files.len, merger.queue.capacity());
}

fn writeTextPostingRunSummaryRecordForTest(path: []const u8, record: TextPostingRunTermSummaryRecord) !TextPostingRunSummaryStats {
    var file = try std.Io.Dir.cwd().createFile(std.testing.io, path, .{ .read = true, .truncate = true });
    defer file.close(std.testing.io);
    var writer = try TextPostingRunSummaryWriter.init(std.testing.allocator, std.testing.io, file);
    defer writer.deinit();
    var header: [TextPostingRunTermSummaryRecord.header_len]u8 = undefined;
    record.encodeHeader(&header);
    try writer.append(&header);
    try writer.append(record.term());
    try writer.flush();
    const stat = try file.stat(std.testing.io);
    if (stat.kind != .file or stat.size != writer.physical_bytes) return error.InvalidRecord;
    return .{
        .term_count = 1,
        .term_bytes_len = record.term_len,
        .summary_file_bytes = writer.physical_bytes,
        .posting_count = record.postings_count,
        .block_count = record.block_count,
        .hit_count = record.top_hit_count,
        .top_hit_term_count = if (record.top_hit_count == 0) 0 else 1,
        .top_hit_candidate_postings = if (record.top_hit_count == 0) 0 else record.postings_count,
        .top_hit_side_stream_candidates = @min(record.postings_count, persistent_term_top_hit_capacity),
        .top_hit_local_side_stream_candidates = record.top_hit_count,
    };
}

test "text posting run summaries count side-stream top-hit candidate shapes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const summary_a_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "summary-a.tmp" });
    defer std.testing.allocator.free(summary_a_path);
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, summary_a_path) catch {};
    const summary_b_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "summary-b.tmp" });
    defer std.testing.allocator.free(summary_b_path);
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, summary_b_path) catch {};
    const merged_summary_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "summary-merged.tmp" });
    defer std.testing.allocator.free(merged_summary_path);
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, merged_summary_path) catch {};

    const high = try TextPostingRunTermSummaryRecord.init("common", persistent_term_top_hit_min_postings);
    const low = try TextPostingRunTermSummaryRecord.init("common", 8);
    const stats_a = try writeTextPostingRunSummaryRecordForTest(summary_a_path, high);
    const stats_b = try writeTextPostingRunSummaryRecordForTest(summary_b_path, low);
    var summary_files = [_]TextPostingRunSummaryFile{
        .{ .path = summary_a_path, .term_count = stats_a.term_count, .file_size = stats_a.summary_file_bytes },
        .{ .path = summary_b_path, .term_count = stats_b.term_count, .file_size = stats_b.summary_file_bytes },
    };

    const stats = try collectTextPostingRunTermSummariesFromFilesToFile(std.testing.allocator, std.testing.io, &summary_files, merged_summary_path, null, null, .none);
    try std.testing.expectEqual(@as(u64, 1), stats.term_count);
    try std.testing.expectEqual(persistent_term_top_hit_min_postings + 8, stats.posting_count);
    try std.testing.expectEqual(@as(u64, 64 + 8), stats.top_hit_side_stream_candidates);
    try std.testing.expectEqual(@as(u64, 64), stats.top_hit_local_side_stream_candidates);
    try std.testing.expectEqual(persistent_term_top_hit_min_postings + 8, stats.top_hit_candidate_postings);
}

test "text posting run summary stats price all-doc temp materialization candidates" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const summary_a_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "summary-all-doc-a.tmp" });
    defer std.testing.allocator.free(summary_a_path);
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, summary_a_path) catch {};
    const summary_b_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "summary-all-doc-b.tmp" });
    defer std.testing.allocator.free(summary_b_path);
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, summary_b_path) catch {};
    const summary_c_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "summary-regular.tmp" });
    defer std.testing.allocator.free(summary_c_path);
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, summary_c_path) catch {};
    const merged_summary_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "summary-all-doc-merged.tmp" });
    defer std.testing.allocator.free(merged_summary_path);
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, merged_summary_path) catch {};

    const doc_count: u64 = persistent_term_top_hit_min_postings + 1;
    const virtual_record = try TextPostingRunTermSummaryRecord.initWithConstantTextFreq("common", doc_count, 1);
    const dense_record = try TextPostingRunTermSummaryRecord.initWithFreqSummary("decision", doc_count, 0, true, false);
    const constant_regular_record = try TextPostingRunTermSummaryRecord.initWithConstantTextFreq("error", persistent_term_top_hit_min_postings, 1);
    const regular_record = try TextPostingRunTermSummaryRecord.init("rare", doc_count - 1);
    const stats_a = try writeTextPostingRunSummaryRecordForTest(summary_a_path, virtual_record);
    const stats_b = try writeTextPostingRunSummaryRecordForTest(summary_b_path, dense_record);
    const stats_c = try writeTextPostingRunSummaryRecordForTest(summary_c_path, regular_record);
    const summary_d_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "summary-constant-regular.tmp" });
    defer std.testing.allocator.free(summary_d_path);
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, summary_d_path) catch {};
    const stats_d = try writeTextPostingRunSummaryRecordForTest(summary_d_path, constant_regular_record);
    var summary_files = [_]TextPostingRunSummaryFile{
        .{ .path = summary_a_path, .term_count = stats_a.term_count, .file_size = stats_a.summary_file_bytes },
        .{ .path = summary_b_path, .term_count = stats_b.term_count, .file_size = stats_b.summary_file_bytes },
        .{ .path = summary_c_path, .term_count = stats_c.term_count, .file_size = stats_c.summary_file_bytes },
        .{ .path = summary_d_path, .term_count = stats_d.term_count, .file_size = stats_d.summary_file_bytes },
    };

    const stats = try collectTextPostingRunTermSummaryStatsFromFiles(std.testing.allocator, std.testing.io, &summary_files, doc_count, .none);
    try std.testing.expectEqual(@as(u64, 4), stats.term_count);
    try std.testing.expectEqual(@as(u64, 1), stats.virtual_all_docs_term_count);
    try std.testing.expectEqual(doc_count, stats.virtual_all_docs_candidate_records);
    try std.testing.expectEqual(@as(u64, 1), stats.dense_all_docs_freq_stream_term_count);
    try std.testing.expectEqual(doc_count, stats.dense_all_docs_freq_stream_candidate_records);
    try std.testing.expectEqual(@as(u64, 1), stats.regular_constant_top_hit_term_count);

    var final_stats = TextPostingRunSummaryStats{};
    _ = try collectTextPostingRunTermSummariesFromFilesToFile(std.testing.allocator, std.testing.io, &summary_files, merged_summary_path, doc_count, &final_stats, .none);
    try std.testing.expectEqual(stats.term_count, final_stats.term_count);
    try std.testing.expectEqual(stats.posting_count, final_stats.posting_count);
    try std.testing.expectEqual(stats.block_count, final_stats.block_count);
    try std.testing.expectEqual(stats.virtual_all_docs_term_count, final_stats.virtual_all_docs_term_count);
    try std.testing.expectEqual(stats.dense_all_docs_freq_stream_term_count, final_stats.dense_all_docs_freq_stream_term_count);
    try std.testing.expectEqual(stats.regular_constant_top_hit_term_count, final_stats.regular_constant_top_hit_term_count);
}

test "text posting run record packs only live term bytes" {
    try std.testing.expectEqual(@as(usize, 144), @sizeOf(TextPostingRunRecord));

    try std.testing.expectError(error.RecordTooLarge, TextPostingRunRecord.init("tiny", .{
        .doc_id = persistent_posting_max_doc_id + 1,
        .text_freq = 1,
        .kind_freq = 0,
    }));
    try std.testing.expectError(error.RecordTooLarge, TextPostingRunRecord.init("tiny", .{
        .doc_id = 7,
        .text_freq = persistent_posting_max_field_freq + 1,
        .kind_freq = 0,
    }));

    var record = try TextPostingRunRecord.init("tiny", .{
        .doc_id = 7,
        .text_freq = 1,
        .kind_freq = 0,
    });
    @memset(record.term_bytes[record.term_len..], 0xaa);

    var bytes: [TextPostingRunRecord.max_encoded_len]u8 = undefined;
    const encoded_len = try record.encode(&bytes);

    try std.testing.expectEqual(@as(usize, TextPostingRunRecord.header_len + "tiny".len), encoded_len);
    try std.testing.expectEqualStrings("tiny", bytes[TextPostingRunRecord.header_len..encoded_len]);

    const decoded = try TextPostingRunRecord.decode(bytes[0..encoded_len]);
    try std.testing.expectEqual(record.term_sort_prefix, decoded.term_sort_prefix);
    try std.testing.expectEqual(record.doc_id, decoded.doc_id);
    try std.testing.expectEqual(record.text_freq, decoded.text_freq);
    try std.testing.expectEqual(record.kind_freq, decoded.kind_freq);
    try std.testing.expectEqualStrings("tiny", decoded.term());
}

test "text posting run sort prefix preserves lexical term order" {
    var records = [_]TextPostingRunRecord{
        try TextPostingRunRecord.init("storage", .{ .doc_id = 1, .text_freq = 1 }),
        try TextPostingRunRecord.init("store", .{ .doc_id = 2, .text_freq = 1 }),
        try TextPostingRunRecord.init("storehouse", .{ .doc_id = 3, .text_freq = 1 }),
        try TextPostingRunRecord.init("alpha", .{ .doc_id = 4, .text_freq = 1 }),
        try TextPostingRunRecord.init("alphabet", .{ .doc_id = 5, .text_freq = 1 }),
        try TextPostingRunRecord.init("alphaβ", .{ .doc_id = 6, .text_freq = 1 }),
        try TextPostingRunRecord.init("alphabeta", .{ .doc_id = 7, .text_freq = 1 }),
        try TextPostingRunRecord.init("z", .{ .doc_id = 8, .text_freq = 1 }),
    };
    std.mem.sort(TextPostingRunRecord, &records, {}, textPostingRunRecordLessThan);

    const expected = [_][]const u8{ "alpha", "alphabet", "alphabeta", "alphaβ", "storage", "store", "storehouse", "z" };
    for (&records, &expected) |*record, term| {
        try std.testing.expectEqualStrings(term, record.term());
    }
}

test "text posting run sort compares suffix after equal sort prefix" {
    var records = [_]TextPostingRunRecord{
        try TextPostingRunRecord.init("abcdefgh-z", .{ .doc_id = 5, .text_freq = 1 }),
        try TextPostingRunRecord.init("abcdefgh-a", .{ .doc_id = 4, .text_freq = 1 }),
        try TextPostingRunRecord.init("abcdefgh", .{ .doc_id = 3, .text_freq = 1 }),
        try TextPostingRunRecord.init("abcdefgh-a", .{ .doc_id = 2, .text_freq = 1 }),
    };
    std.mem.sort(TextPostingRunRecord, &records, {}, textPostingRunRecordLessThan);

    try std.testing.expectEqualStrings("abcdefgh", records[0].term());
    try std.testing.expectEqual(@as(u32, 3), records[0].doc_id);
    try std.testing.expectEqualStrings("abcdefgh-a", records[1].term());
    try std.testing.expectEqual(@as(u32, 2), records[1].doc_id);
    try std.testing.expectEqualStrings("abcdefgh-a", records[2].term());
    try std.testing.expectEqual(@as(u32, 4), records[2].doc_id);
    try std.testing.expectEqualStrings("abcdefgh-z", records[3].term());
    try std.testing.expectEqual(@as(u32, 5), records[3].doc_id);
}

test "text posting run record rejects trailing packed bytes" {
    const long = try TextPostingRunRecord.init("longer-term", .{
        .doc_id = 7,
        .text_freq = 1,
        .kind_freq = 0,
    });
    const short = try TextPostingRunRecord.init("tiny", .{
        .doc_id = 8,
        .text_freq = 2,
        .kind_freq = 0,
    });

    var bytes: [TextPostingRunRecord.max_encoded_len]u8 = [_]u8{0xaa} ** TextPostingRunRecord.max_encoded_len;
    const long_len = try long.encode(&bytes);
    try std.testing.expectEqualStrings("longer-term", bytes[TextPostingRunRecord.header_len..long_len]);

    const short_len = try short.encode(&bytes);
    try std.testing.expectEqualStrings("tiny", bytes[TextPostingRunRecord.header_len..short_len]);
    try std.testing.expectError(error.InvalidRecord, TextPostingRunRecord.decode(bytes[0 .. short_len + 1]));

    const decoded = try TextPostingRunRecord.decode(bytes[0..short_len]);
    try std.testing.expectEqual(@as(u64, 8), decoded.doc_id);
    try std.testing.expectEqual(@as(u32, 2), decoded.text_freq);
    try std.testing.expectEqualStrings("tiny", decoded.term());
}

test "text posting run summary reader handles records across read buffer boundary" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const run_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "summary-boundary.run" });
    defer std.testing.allocator.free(run_path);
    const summary_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "summary-boundary.tmp" });
    defer std.testing.allocator.free(summary_path);
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, summary_path) catch {};

    const record_count = (text_run_read_buffer_bytes / (TextPostingRunTermSummaryRecord.header_len + "summary-0000".len)) + 2;
    const records = try std.testing.allocator.alloc(TextPostingRunRecord, record_count);
    defer std.testing.allocator.free(records);
    for (records, 0..) |*record, index| {
        var term_buf: [32]u8 = undefined;
        const term = try std.fmt.bufPrint(&term_buf, "summary-{d:0>4}", .{index});
        record.* = try TextPostingRunRecord.init(term, .{ .doc_id = @intCast(index + 1), .text_freq = 1, .kind_freq = 0 });
    }
    try writeTextPostingRun(std.testing.allocator, std.testing.io, run_path, records);

    const stats = try collectTextPostingRunTermSummariesToFile(std.testing.allocator, std.testing.io, &.{run_path}, summary_path, .none);
    try std.testing.expectEqual(@as(u64, record_count), stats.term_count);

    var reader = try TextPostingRunSummaryReader.init(std.testing.allocator, std.testing.io, summary_path, stats.term_count, stats.summary_file_bytes);
    defer reader.deinit();
    var scratch = try TextPostingRunSummaryReadScratch.init(std.testing.allocator);
    defer scratch.deinit();
    var read_count: u64 = 0;
    while (try reader.nextRecord(&scratch)) |summary| {
        try std.testing.expectEqual(@as(u64, 1), summary.postings_count);
        read_count += 1;
    }
    try std.testing.expectEqual(@as(u64, record_count), read_count);
}

test "text posting run summary reader rejects trailing bytes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const run_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "summary-trailing.run" });
    defer std.testing.allocator.free(run_path);
    const summary_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "summary-trailing.tmp" });
    defer std.testing.allocator.free(summary_path);
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, summary_path) catch {};

    var run = [_]TextPostingRunRecord{
        try TextPostingRunRecord.init("storage", .{ .doc_id = 7, .text_freq = 1, .kind_freq = 0 }),
    };
    try writeTextPostingRun(std.testing.allocator, std.testing.io, run_path, &run);

    const stats = try collectTextPostingRunTermSummariesToFile(std.testing.allocator, std.testing.io, &.{run_path}, summary_path, .none);
    var file = try std.Io.Dir.cwd().openFile(std.testing.io, summary_path, .{ .mode = .read_write });
    defer file.close(std.testing.io);
    try file.writePositionalAll(std.testing.io, &[_]u8{0}, stats.summary_file_bytes);

    var reader = try TextPostingRunSummaryReader.init(std.testing.allocator, std.testing.io, summary_path, stats.term_count, stats.summary_file_bytes + 1);
    defer reader.deinit();
    var scratch = try TextPostingRunSummaryReadScratch.init(std.testing.allocator);
    defer scratch.deinit();
    _ = try reader.nextRecord(&scratch);
    try std.testing.expectError(error.InvalidRecord, reader.nextRecord(&scratch));
}

test "text posting run summary reader rejects corrupt compressed block" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const summary_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "summary-corrupt-compressed.tmp" });
    defer std.testing.allocator.free(summary_path);
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, summary_path) catch {};

    var header: [text_run_summary_block_header_len]u8 = undefined;
    std.mem.writeInt(u32, header[0..4], TextPostingRunTermSummaryRecord.header_len + 4, .little);
    std.mem.writeInt(u32, header[4..8], 1, .little);
    std.mem.writeInt(u16, header[8..10], text_run_summary_block_flag_compressed, .little);
    std.mem.writeInt(u16, header[10..12], 0, .little);

    var file = try std.Io.Dir.cwd().createFile(std.testing.io, summary_path, .{ .read = true, .truncate = true });
    defer file.close(std.testing.io);
    try file.writePositionalAll(std.testing.io, &text_run_summary_compressed_magic, 0);
    try file.writePositionalAll(std.testing.io, &header, text_run_summary_compressed_magic.len);
    try file.writePositionalAll(std.testing.io, &[_]u8{0}, text_run_summary_compressed_magic.len + text_run_summary_block_header_len);
    const stat = try file.stat(std.testing.io);

    var reader = try TextPostingRunSummaryReader.init(std.testing.allocator, std.testing.io, summary_path, 1, stat.size);
    defer reader.deinit();
    var scratch = try TextPostingRunSummaryReadScratch.init(std.testing.allocator);
    defer scratch.deinit();
    try std.testing.expectError(error.InvalidRecord, reader.nextRecord(&scratch));
}

test "text posting run trusted merged summary preserves decoded term identity" {
    const first = try TextPostingRunTermSummaryRecord.initWithFreqSummary("alpha", 1, 2, true, true);
    const merged = try TextPostingRunTermSummaryRecord.initMergedFromTrustedFirst(first, 2, 0, true, 10);

    try std.testing.expectEqual(first.term_hash, merged.term_hash);
    try std.testing.expectEqualStrings(first.term(), merged.term());
    try std.testing.expectEqual(@as(u64, 2), merged.postings_count);
    try std.testing.expect(!merged.inlineSingleton());
    try std.testing.expectEqual(try publishedPostingBlockCount(2, persistent_posting_block_size), merged.block_count);
    try std.testing.expectEqual(persistentTermTopHitCountForPostingCount(2), merged.top_hit_count);
}

test "text posting run summary merge enforces immediate deadline" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const run_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "deadline.run" });
    defer std.testing.allocator.free(run_path);
    const summary_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "deadline.summaries.tmp" });
    defer std.testing.allocator.free(summary_path);
    defer std.Io.Dir.cwd().deleteFile(std.testing.io, summary_path) catch {};

    var run = [_]TextPostingRunRecord{
        try TextPostingRunRecord.init("storage", .{ .doc_id = 7, .text_freq = 1, .kind_freq = 0 }),
    };
    try writeTextPostingRun(std.testing.allocator, std.testing.io, run_path, &run);

    try std.testing.expectError(
        core.Error.BudgetExceeded,
        collectTextPostingRunTermSummariesToFile(std.testing.allocator, std.testing.io, &.{run_path}, summary_path, .immediate),
    );
}

test "persistent posting list keeps singleton postings inline" {
    var postings = PersistentPostingList{};
    defer postings.deinit(std.testing.allocator);

    try postings.append(std.testing.allocator, .{ .doc_id = 1, .text_freq = 1, .kind_freq = 0 });
    try std.testing.expectEqual(@as(usize, 1), postings.len);
    try std.testing.expectEqual(@as(usize, 0), postings.overflow.items.len);
    try std.testing.expectEqual(@as(u64, 1), postings.items()[0].doc_id);

    try postings.append(std.testing.allocator, .{ .doc_id = 2, .text_freq = 2, .kind_freq = 0 });
    try std.testing.expectEqual(@as(usize, 2), postings.len);
    try std.testing.expectEqual(@as(usize, 2), postings.overflow.items.len);
    try std.testing.expectEqual(@as(u64, 1), postings.items()[0].doc_id);
    try std.testing.expectEqual(@as(u64, 2), postings.items()[1].doc_id);
}

test "persistent posting list trim releases unused overflow capacity" {
    var postings = PersistentPostingList{};
    defer postings.deinit(std.testing.allocator);

    try postings.append(std.testing.allocator, .{ .doc_id = 1, .text_freq = 1, .kind_freq = 0 });
    try postings.append(std.testing.allocator, .{ .doc_id = 2, .text_freq = 1, .kind_freq = 0 });
    try postings.ensureUnusedCapacity(std.testing.allocator, 64);
    try std.testing.expect(postings.overflow.capacity >= postings.len + 64);

    try postings.trimCapacity(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), postings.len);
    try std.testing.expectEqual(@as(usize, 2), postings.overflow.items.len);
    try std.testing.expectEqual(@as(u64, 1), postings.items()[0].doc_id);
    try std.testing.expectEqual(@as(u64, 2), postings.items()[1].doc_id);
}

fn writeTextMetaFile(allocator: std.mem.Allocator, store: storage_mod.Store, meta: PersistentTextMeta) !void {
    const path = try textMetaPath(allocator, store);
    defer allocator.free(path);
    const tmp_path = try tmpPathFor(allocator, path);
    defer allocator.free(tmp_path);
    errdefer std.Io.Dir.cwd().deleteFile(store.io, tmp_path) catch {};

    var bytes: [PersistentTextMeta.encoded_len]u8 = undefined;
    meta.encode(&bytes);
    {
        var file = try std.Io.Dir.cwd().createFile(store.io, tmp_path, .{ .read = true, .truncate = true });
        defer file.close(store.io);
        try file.writePositionalAll(store.io, &bytes, 0);
        if (textOptionsNeedSync(store)) try file.sync(store.io);
    }
    try renameReplace(store.io, tmp_path, path);
}

fn clearReusableTermFreqs(allocator: std.mem.Allocator, freqs: *std.StringHashMap(FieldTermFreq), owned: *std.ArrayList([]u8)) void {
    freqs.clearRetainingCapacity();
    for (owned.items) |term| allocator.free(term);
    owned.clearRetainingCapacity();
}

fn clearReusableArenaTermFreqs(freqs: *std.StringHashMap(FieldTermFreq), arena: *std.heap.ArenaAllocator) void {
    if (freqs.capacity() > text_rebuild_term_freq_retain_capacity_limit) {
        freqs.clearAndFree();
    } else {
        freqs.clearRetainingCapacity();
    }
    _ = arena.reset(.{ .retain_with_limit = text_rebuild_term_arena_retain_limit });
}

const text_rebuild_text_freq_cache_max_entries: usize = if (builtin.is_test) 16 else 1024;
const text_rebuild_text_freq_cache_max_text_bytes: usize = 128 * 1024 * 1024;
const text_rebuild_text_freq_cache_max_term_entries: usize = 4 * 1024 * 1024;
const text_rebuild_text_freq_cache_max_term_bytes: usize = 128 * 1024 * 1024;

const CachedRebuildTermFreq = struct {
    term: []u8,
    freq: FieldTermFreq,
};

const CachedRebuildTextFreqs = struct {
    text_hash: u64,
    text: []u8,
    text_tokens: u64,
    terms: []CachedRebuildTermFreq,
    doc_ids: std.ArrayList(u32) = .empty,

    fn deinit(self: *CachedRebuildTextFreqs, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        for (self.terms) |term| allocator.free(term.term);
        allocator.free(self.terms);
        self.doc_ids.deinit(allocator);
    }

    fn appendDocId(self: *CachedRebuildTextFreqs, allocator: std.mem.Allocator, doc_id: u64) !void {
        if (doc_id == 0 or doc_id > std.math.maxInt(u32)) return error.RecordTooLarge;
        if (self.doc_ids.items.len != 0 and doc_id <= self.doc_ids.items[self.doc_ids.items.len - 1]) return error.InvalidRecord;
        try self.doc_ids.append(allocator, @intCast(doc_id));
    }
};

const TextRebuildTextFreqCache = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList(CachedRebuildTextFreqs) = .empty,
    by_hash: std.AutoHashMap(u64, usize),
    text_bytes: usize = 0,
    term_count: usize = 0,
    term_bytes: usize = 0,
    disabled: bool = false,

    pub fn init(allocator: std.mem.Allocator) TextRebuildTextFreqCache {
        return .{
            .allocator = allocator,
            .by_hash = std.AutoHashMap(u64, usize).init(allocator),
        };
    }

    pub fn deinit(self: *TextRebuildTextFreqCache) void {
        for (self.entries.items) |*entry| entry.deinit(self.allocator);
        self.entries.deinit(self.allocator);
        self.by_hash.deinit();
    }

    fn disableAndClear(self: *TextRebuildTextFreqCache) void {
        if (self.disabled) return;
        for (self.entries.items) |*entry| entry.deinit(self.allocator);
        self.entries.clearAndFree(self.allocator);
        self.by_hash.clearAndFree();
        self.text_bytes = 0;
        self.term_count = 0;
        self.term_bytes = 0;
        self.disabled = true;
    }

    fn hashText(text: []const u8) u64 {
        return std.hash.Wyhash.hash(text.len, text);
    }

    pub fn lookup(self: *TextRebuildTextFreqCache, text: []const u8) ?*CachedRebuildTextFreqs {
        if (self.disabled) return null;
        const text_hash = hashText(text);
        const index = self.by_hash.get(text_hash) orelse return null;
        const entry = &self.entries.items[index];
        if (entry.text_hash != text_hash or !std.mem.eql(u8, entry.text, text)) return null;
        return entry;
    }

    pub fn populateFreqs(
        self: *TextRebuildTextFreqCache,
        freqs: *std.StringHashMap(FieldTermFreq),
        cached: *const CachedRebuildTextFreqs,
    ) !void {
        _ = self;
        try freqs.ensureTotalCapacity(@intCast(cached.terms.len));
        for (cached.terms) |term| {
            try freqs.put(term.term, term.freq);
        }
    }

    pub fn store(
        self: *TextRebuildTextFreqCache,
        text: []const u8,
        text_tokens: u64,
        freqs: *std.StringHashMap(FieldTermFreq),
    ) !*CachedRebuildTextFreqs {
        if (self.disabled) return error.InvalidRecord;
        const text_hash = hashText(text);
        if (self.by_hash.get(text_hash)) |index| {
            const existing = &self.entries.items[index];
            if (!std.mem.eql(u8, existing.text, text)) {
                // Hash collisions are rare, but correctness is cheaper than cleverness.
                return error.InvalidRecord;
            }
            return existing;
        }
        if (self.entries.items.len >= text_rebuild_text_freq_cache_max_entries) {
            self.disableAndClear();
            return error.RecordTooLarge;
        }
        if (text.len > text_rebuild_text_freq_cache_max_text_bytes -| self.text_bytes) {
            self.disableAndClear();
            return error.RecordTooLarge;
        }
        const freq_count = freqs.count();
        if (freq_count > text_rebuild_text_freq_cache_max_term_entries -| self.term_count) {
            self.disableAndClear();
            return error.RecordTooLarge;
        }

        var term_bytes: usize = 0;
        var count_it = freqs.iterator();
        while (count_it.next()) |entry| {
            term_bytes = std.math.add(usize, term_bytes, entry.key_ptr.*.len) catch {
                self.disabled = true;
                return error.RecordTooLarge;
            };
        }
        if (term_bytes > text_rebuild_text_freq_cache_max_term_bytes -| self.term_bytes) {
            self.disableAndClear();
            return error.RecordTooLarge;
        }

        const text_copy = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(text_copy);
        const terms = try self.allocator.alloc(CachedRebuildTermFreq, freq_count);
        errdefer self.allocator.free(terms);

        var term_index: usize = 0;
        var it = freqs.iterator();
        errdefer {
            for (terms[0..term_index]) |term| self.allocator.free(term.term);
        }
        while (it.next()) |entry| {
            const term_copy = try self.allocator.dupe(u8, entry.key_ptr.*);
            terms[term_index] = .{
                .term = term_copy,
                .freq = entry.value_ptr.*,
            };
            term_index += 1;
        }

        try self.entries.ensureUnusedCapacity(self.allocator, 1);
        try self.by_hash.ensureUnusedCapacity(1);
        const index = self.entries.items.len;
        self.entries.appendAssumeCapacity(.{
            .text_hash = text_hash,
            .text = text_copy,
            .text_tokens = text_tokens,
            .terms = terms,
        });
        self.by_hash.putAssumeCapacityNoClobber(text_hash, index);
        self.text_bytes += text.len;
        self.term_count += freq_count;
        self.term_bytes += term_bytes;
        return &self.entries.items[index];
    }
};

fn appendDenseAllDocsFreqGroup(writer: *TextBufferedWriter, tags: []const u8, explicit_freqs: []const u8) !u64 {
    var tag_bytes_buf: [3]u8 = undefined;
    const tag_bytes = try encodeDenseAllDocsFreqGroup(tags, &tag_bytes_buf);
    try writer.append(tag_bytes_buf[0..tag_bytes]);
    try writer.append(explicit_freqs);
    return std.math.add(u64, tag_bytes, explicit_freqs.len) catch return error.RecordTooLarge;
}

fn appendDenseAllDocsFreqPackedFreqs(writer: *TextBufferedWriter, freqs: anytype) !u64 {
    try writer.append(&.{persistent_dense_all_docs_freq_mode_packed});
    var written: u64 = 1;
    var tags: [persistent_dense_all_docs_freq_group_size]u8 = undefined;
    var tag_count: usize = 0;
    var explicit_freqs: [persistent_dense_all_docs_freq_group_size * 10]u8 = undefined;
    var explicit_len: usize = 0;
    for (freqs) |freq_raw| {
        const freq: u32 = @intCast(freq_raw);
        const field_tag = try compressedPostingTextFreqTag(freq);
        tags[tag_count] = field_tag;
        tag_count += 1;
        if (compressedPostingTagTextExplicit(field_tag)) {
            explicit_len += try encodePersistentVarint(freq, explicit_freqs[explicit_len..]);
        }
        if (tag_count == persistent_dense_all_docs_freq_group_size) {
            written = std.math.add(u64, written, try appendDenseAllDocsFreqGroup(writer, tags[0..tag_count], explicit_freqs[0..explicit_len])) catch return error.RecordTooLarge;
            tag_count = 0;
            explicit_len = 0;
        }
    }
    if (tag_count != 0) {
        written = std.math.add(u64, written, try appendDenseAllDocsFreqGroup(writer, tags[0..tag_count], explicit_freqs[0..explicit_len])) catch return error.RecordTooLarge;
    }
    return written;
}

fn appendDenseAllDocsFreqRleFreqs(writer: *TextBufferedWriter, freqs: anytype) !u64 {
    try writer.append(&.{persistent_dense_all_docs_freq_mode_rle});
    var written: u64 = 1;
    var previous_freq: u32 = 0;
    var run_len: u64 = 0;
    var varint_buf: [20]u8 = undefined;
    for (freqs) |freq_raw| {
        const freq: u32 = @intCast(freq_raw);
        if (freq == 0) return error.InvalidRecord;
        if (freq == previous_freq) {
            run_len = std.math.add(u64, run_len, 1) catch return error.RecordTooLarge;
            continue;
        }
        if (run_len != 0) {
            const run_len_bytes = try encodePersistentVarint(run_len, &varint_buf);
            try writer.append(varint_buf[0..run_len_bytes]);
            const freq_bytes = try encodePersistentVarint(previous_freq, &varint_buf);
            try writer.append(varint_buf[0..freq_bytes]);
            written = std.math.add(u64, written, run_len_bytes + freq_bytes) catch return error.RecordTooLarge;
        }
        previous_freq = freq;
        run_len = 1;
    }
    if (run_len != 0) {
        const run_len_bytes = try encodePersistentVarint(run_len, &varint_buf);
        try writer.append(varint_buf[0..run_len_bytes]);
        const freq_bytes = try encodePersistentVarint(previous_freq, &varint_buf);
        try writer.append(varint_buf[0..freq_bytes]);
        written = std.math.add(u64, written, run_len_bytes + freq_bytes) catch return error.RecordTooLarge;
    }
    return written;
}

fn appendDenseAllDocsFreqStreamFreqs(writer: *TextBufferedWriter, freqs: anytype) !u64 {
    const stats = try denseAllDocsFreqStreamSizeStatsForFreqs(freqs);
    return appendDenseAllDocsFreqStreamFreqsWithStats(writer, freqs, stats);
}

fn appendDenseAllDocsFreqStreamFreqsWithStats(writer: *TextBufferedWriter, freqs: anytype, stats: DenseAllDocsFreqStreamSizeStats) !u64 {
    if (freqs.len == 0) return error.InvalidRecord;
    return appendDenseAllDocsFreqBitpackedValues(writer, std.meta.Elem(@TypeOf(freqs)), freqs, stats.max_freq);
}

test "dense all-doc freq stream with supplied stats matches computed stats bytes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const computed_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "computed.freqs" });
    defer std.testing.allocator.free(computed_path);
    const supplied_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "supplied.freqs" });
    defer std.testing.allocator.free(supplied_path);

    const freqs = [_]u16{ 1, 1, 2, 2, 2, 3, 1, 1, 1, 4, 4, 2, 2, 2, 2, 5, 1, 1, 3, 3 };
    const stats = try denseAllDocsFreqStreamSizeStatsForFreqs(&freqs);

    const computed_written = blk: {
        var file = try std.Io.Dir.cwd().createFile(std.testing.io, computed_path, .{ .read = true, .truncate = true });
        defer file.close(std.testing.io);
        var writer = try TextBufferedWriter.init(std.testing.allocator, std.testing.io, file, 8);
        defer writer.deinit();
        const written = try appendDenseAllDocsFreqStreamFreqs(&writer, &freqs);
        try writer.flush();
        break :blk written;
    };

    const supplied_written = blk: {
        var file = try std.Io.Dir.cwd().createFile(std.testing.io, supplied_path, .{ .read = true, .truncate = true });
        defer file.close(std.testing.io);
        var writer = try TextBufferedWriter.init(std.testing.allocator, std.testing.io, file, 8);
        defer writer.deinit();
        const written = try appendDenseAllDocsFreqStreamFreqsWithStats(&writer, &freqs, stats);
        try writer.flush();
        break :blk written;
    };

    try std.testing.expectEqual(computed_written, supplied_written);
    const computed_len: usize = @intCast(computed_written);
    const computed = try std.testing.allocator.alloc(u8, computed_len);
    defer std.testing.allocator.free(computed);
    {
        var file = try std.Io.Dir.cwd().openFile(std.testing.io, computed_path, .{});
        defer file.close(std.testing.io);
        try std.testing.expectEqual(computed_len, try file.readPositionalAll(std.testing.io, computed, 0));
    }
    const supplied_len: usize = @intCast(supplied_written);
    const supplied = try std.testing.allocator.alloc(u8, supplied_len);
    defer std.testing.allocator.free(supplied);
    {
        var file = try std.Io.Dir.cwd().openFile(std.testing.io, supplied_path, .{});
        defer file.close(std.testing.io);
        try std.testing.expectEqual(supplied_len, try file.readPositionalAll(std.testing.io, supplied, 0));
    }
    try std.testing.expectEqualSlices(u8, computed, supplied);
}

fn appendDenseAllDocsFreqPackedPostings(writer: *TextBufferedWriter, postings: []const TextPostingRecord) !u64 {
    try writer.append(&.{persistent_dense_all_docs_freq_mode_packed});
    var written: u64 = 1;
    var tags: [persistent_dense_all_docs_freq_group_size]u8 = undefined;
    var tag_count: usize = 0;
    var explicit_freqs: [persistent_dense_all_docs_freq_group_size * 10]u8 = undefined;
    var explicit_len: usize = 0;
    for (postings) |posting| {
        const field_tag = try compressedPostingFieldTag(posting);
        tags[tag_count] = field_tag;
        tag_count += 1;
        if (compressedPostingTagTextExplicit(field_tag)) {
            explicit_len += try encodePersistentVarint(posting.text_freq, explicit_freqs[explicit_len..]);
        }
        if (tag_count == persistent_dense_all_docs_freq_group_size) {
            written = std.math.add(u64, written, try appendDenseAllDocsFreqGroup(writer, tags[0..tag_count], explicit_freqs[0..explicit_len])) catch return error.RecordTooLarge;
            tag_count = 0;
            explicit_len = 0;
        }
    }
    if (tag_count != 0) {
        written = std.math.add(u64, written, try appendDenseAllDocsFreqGroup(writer, tags[0..tag_count], explicit_freqs[0..explicit_len])) catch return error.RecordTooLarge;
    }
    return written;
}

fn appendDenseAllDocsFreqRlePostings(writer: *TextBufferedWriter, postings: []const TextPostingRecord) !u64 {
    try writer.append(&.{persistent_dense_all_docs_freq_mode_rle});
    var written: u64 = 1;
    var previous_freq: u32 = 0;
    var run_len: u64 = 0;
    var varint_buf: [20]u8 = undefined;
    for (postings) |posting| {
        if (posting.text_freq == 0 or posting.kind_freq != 0) return error.InvalidRecord;
        if (posting.text_freq == previous_freq) {
            run_len = std.math.add(u64, run_len, 1) catch return error.RecordTooLarge;
            continue;
        }
        if (run_len != 0) {
            const run_len_bytes = try encodePersistentVarint(run_len, &varint_buf);
            try writer.append(varint_buf[0..run_len_bytes]);
            const freq_bytes = try encodePersistentVarint(previous_freq, &varint_buf);
            try writer.append(varint_buf[0..freq_bytes]);
            written = std.math.add(u64, written, run_len_bytes + freq_bytes) catch return error.RecordTooLarge;
        }
        previous_freq = posting.text_freq;
        run_len = 1;
    }
    if (run_len != 0) {
        const run_len_bytes = try encodePersistentVarint(run_len, &varint_buf);
        try writer.append(varint_buf[0..run_len_bytes]);
        const freq_bytes = try encodePersistentVarint(previous_freq, &varint_buf);
        try writer.append(varint_buf[0..freq_bytes]);
        written = std.math.add(u64, written, run_len_bytes + freq_bytes) catch return error.RecordTooLarge;
    }
    return written;
}

fn appendDenseAllDocsFreqStreamPostings(writer: *TextBufferedWriter, postings: []const TextPostingRecord) !u64 {
    var max_freq: u32 = 0;
    for (postings) |posting| {
        const text_freq = try validateDenseAllDocsTextFreq(posting.text_freq);
        max_freq = @max(max_freq, text_freq);
    }
    return appendDenseAllDocsFreqBitpackedPostings(writer, postings, max_freq);
}

fn readTextDocsHeaderFromFile(store: storage_mod.Store, file: std.Io.File) !TextDocsHeader {
    var bytes: [TextDocsHeader.encoded_len]u8 = undefined;
    const n = try file.readPositionalAll(store.io, &bytes, 0);
    if (n != bytes.len) return error.InvalidRecord;
    return TextDocsHeader.decode(&bytes);
}

fn readTextTermsHeaderFromFile(store: storage_mod.Store, file: std.Io.File) !TextTermsHeader {
    var bytes: [TextTermsHeader.encoded_len]u8 = undefined;
    const n = try file.readPositionalAll(store.io, &bytes, 0);
    if (n != bytes.len) return error.InvalidRecord;
    return decodeTextTermsHeader(&bytes);
}

fn readPackedTextTermEntryAt(store: storage_mod.Store, file: std.Io.File, index: u64) !TextTermEntry {
    var bytes: [TextTermEntry.encoded_len]u8 = undefined;
    const n = try file.readPositionalAll(store.io, &bytes, try textTermEntryOffset(index));
    if (n != bytes.len) return error.InvalidRecord;
    return decodeTextTermEntry(&bytes);
}

fn readTextTermExceptionRecordAt(store: storage_mod.Store, file: std.Io.File, header: TextTermsHeader, exception_index: u64) !TextTermExceptionRecord {
    if (exception_index >= header.term_exception_count) return error.InvalidRecord;
    var bytes: [TextTermExceptionRecord.encoded_len]u8 = undefined;
    const n = try file.readPositionalAll(store.io, &bytes, try textTermExceptionRecordOffset(header.term_count, header.term_bytes, exception_index));
    if (n != bytes.len) return error.InvalidRecord;
    return decodeTextTermExceptionRecord(&bytes);
}

fn readTextTermExceptionRankCheckpointAt(store: storage_mod.Store, file: std.Io.File, header: TextTermsHeader, checkpoint_index: u64) !u64 {
    var bytes: [4]u8 = undefined;
    const n = try file.readPositionalAll(store.io, &bytes, try textTermExceptionRankCheckpointOffset(header.term_count, header.term_bytes, checkpoint_index));
    if (n != bytes.len) return error.InvalidRecord;
    return std.mem.readInt(u32, &bytes, .little);
}

fn readTextTermExceptionMembershipByteAt(store: storage_mod.Store, file: std.Io.File, header: TextTermsHeader, byte_index: u64) !u8 {
    var bytes: [1]u8 = undefined;
    const n = try file.readPositionalAll(store.io, &bytes, try textTermExceptionMembershipByteOffset(header.term_count, header.term_bytes, byte_index));
    if (n != bytes.len) return error.InvalidRecord;
    return bytes[0];
}

const TextTermExceptionLookup = struct {
    entry: ?TextTermEntry,
    rank: u64,
};

fn readTextTermExceptionLookupAt(store: storage_mod.Store, file: std.Io.File, header: TextTermsHeader, index: u64, packed_entry: TextTermEntry) !TextTermExceptionLookup {
    if (index >= header.term_count) return error.InvalidRecord;
    const checkpoint_index = index / persistent_term_exception_rank_checkpoint_terms;
    const checkpoint_term = checkpoint_index * persistent_term_exception_rank_checkpoint_terms;
    var rank = try readTextTermExceptionRankCheckpointAt(store, file, header, checkpoint_index);
    if (rank > header.term_exception_count) return error.InvalidRecord;
    var term = checkpoint_term;
    var byte_index = term / 8;
    var bits = if (term < index) try readTextTermExceptionMembershipByteAt(store, file, header, byte_index) else 0;
    while (term < index) {
        const bit_offset: u3 = @intCast(term & 7);
        if ((bits & (@as(u8, 1) << bit_offset)) != 0) rank += 1;
        term += 1;
        if (term < index and (term & 7) == 0) {
            byte_index += 1;
            bits = try readTextTermExceptionMembershipByteAt(store, file, header, byte_index);
        }
    }
    if (rank > header.term_exception_count) return error.InvalidRecord;
    const member_byte = try readTextTermExceptionMembershipByteAt(store, file, header, index / 8);
    const member_bit: u3 = @intCast(index & 7);
    if ((member_byte & (@as(u8, 1) << member_bit)) == 0) return .{ .entry = null, .rank = rank };
    if (rank >= header.term_exception_count) return error.InvalidRecord;
    const record = try readTextTermExceptionRecordAt(store, file, header, rank);
    const entry = TextTermEntry{
        .term_len = packed_entry.term_len,
        .doc_freq = record.doc_freq,
        .postings_offset = record.postings_offset,
        .postings_count = record.doc_freq,
        .front_prefix_len = packed_entry.front_prefix_len,
        .postings_offset_is_plain = record.postings_offset_is_plain,
        .postings_offset_is_dense_freq_stream = record.postings_offset_is_dense_freq_stream,
    };
    if (!termEntryPostingPayloadValid(entry)) return error.InvalidRecord;
    return .{ .entry = entry, .rank = rank };
}

fn readTextTermExceptionForTerm(store: storage_mod.Store, file: std.Io.File, header: TextTermsHeader, index: u64, packed_entry: TextTermEntry) !TextTermEntry {
    const lookup = try readTextTermExceptionLookupAt(store, file, header, index, packed_entry);
    if (lookup.entry) |entry| return entry;
    return error.InvalidRecord;
}

fn readTextTermSingletonPayloadCheckpointAt(store: storage_mod.Store, file: std.Io.File, header: TextTermsHeader, checkpoint_index: u64) !TextTermSingletonPayloadCheckpoint {
    var bytes: [TextTermSingletonPayloadCheckpoint.encoded_len]u8 = undefined;
    const n = try file.readPositionalAll(store.io, &bytes, try textTermSingletonPayloadCheckpointOffset(header.term_count, header.term_bytes, header.term_exception_count, checkpoint_index));
    if (n != bytes.len) return error.InvalidRecord;
    return decodeTextTermSingletonPayloadCheckpoint(&bytes);
}

fn readTextTermByteAt(store: storage_mod.Store, file: std.Io.File, offset: u64) !u8 {
    var bytes: [1]u8 = undefined;
    const n = try file.readPositionalAll(store.io, &bytes, offset);
    if (n != bytes.len) return error.InvalidRecord;
    return bytes[0];
}

fn decodePersistentVarintFromTextTermFile(store: storage_mod.Store, file: std.Io.File, cursor: *u64, end: u64) !u64 {
    var value: u64 = 0;
    var shift: u6 = 0;
    var count: usize = 0;
    while (true) {
        if (cursor.* >= end) return error.InvalidRecord;
        const byte = try readTextTermByteAt(store, file, cursor.*);
        cursor.* = std.math.add(u64, cursor.*, 1) catch return error.InvalidRecord;
        if (shift == 63 and (byte & 0x7f) > 1) return error.InvalidRecord;
        value |= (@as(u64, byte & 0x7f) << shift);
        count += 1;
        if ((byte & 0x80) == 0) return value;
        if (count >= 10) return error.InvalidRecord;
        shift += 7;
    }
}

fn readTextTermSingletonPayloadAt(store: storage_mod.Store, file: std.Io.File, header: TextTermsHeader, singleton_ordinal: u64) !u32 {
    const singleton_count = try textTermSingletonPayloadCount(header.term_count, header.term_exception_count);
    if (singleton_ordinal >= singleton_count) return error.InvalidRecord;
    const checkpoint_index = singleton_ordinal / persistent_term_singleton_payload_checkpoint_terms;
    const checkpoint_ordinal = checkpoint_index * persistent_term_singleton_payload_checkpoint_terms;
    const checkpoint = try readTextTermSingletonPayloadCheckpointAt(store, file, header, checkpoint_index);
    if (checkpoint.stream_offset > header.singleton_payload_bytes) return error.InvalidRecord;
    const stream_base = try textTermSingletonPayloadStreamOffset(header.term_count, header.term_bytes, header.term_exception_count);
    var cursor = std.math.add(u64, stream_base, checkpoint.stream_offset) catch return error.InvalidRecord;
    const stream_end = std.math.add(u64, stream_base, header.singleton_payload_bytes) catch return error.InvalidRecord;
    var payload = checkpoint.previous_payload;
    var ordinal = checkpoint_ordinal;
    while (ordinal <= singleton_ordinal) : (ordinal += 1) {
        const encoded_delta = try decodePersistentVarintFromTextTermFile(store, file, &cursor, stream_end);
        payload = try applySingletonPayloadDelta(payload, encoded_delta);
    }
    _ = try decodeInlineSingletonPostingPayload(payload);
    return payload;
}

fn readTextTermEntryAt(store: storage_mod.Store, file: std.Io.File, header: TextTermsHeader, index: u64) !TextTermEntry {
    const entry = try readPackedTextTermEntryAt(store, file, index);
    const lookup = try readTextTermExceptionLookupAt(store, file, header, index, entry);
    if (lookup.entry) |resolved| return resolved;
    if (index < lookup.rank) return error.InvalidRecord;
    const singleton_ordinal = index - lookup.rank;
    const payload = try readTextTermSingletonPayloadAt(store, file, header, singleton_ordinal);
    return .{
        .term_len = entry.term_len,
        .doc_freq = 1,
        .postings_offset = payload,
        .postings_count = 1,
        .front_prefix_len = entry.front_prefix_len,
    };
}

fn readTextPostingsHeaderFromFile(store: storage_mod.Store, file: std.Io.File) !TextPostingsHeader {
    var bytes: [TextPostingsHeader.encoded_len]u8 = undefined;
    const n = try file.readPositionalAll(store.io, &bytes, 0);
    if (n != bytes.len) return error.InvalidRecord;
    return decodeTextPostingsHeader(&bytes);
}

fn readTextPostingBlocksHeaderFromFile(store: storage_mod.Store, file: std.Io.File) !TextPostingBlocksHeader {
    var bytes: [TextPostingBlocksHeader.encoded_len]u8 = undefined;
    const n = try file.readPositionalAll(store.io, &bytes, 0);
    if (n != bytes.len) return error.InvalidRecord;
    return decodeTextPostingBlocksHeader(&bytes);
}

fn readTextPostingBlockImpactsHeaderFromFile(store: storage_mod.Store, file: std.Io.File) !TextPostingBlockImpactsHeader {
    var bytes: [TextPostingBlockImpactsHeader.encoded_len]u8 = undefined;
    const n = try file.readPositionalAll(store.io, &bytes, 0);
    if (n != bytes.len) return error.InvalidRecord;
    return decodeTextPostingBlockImpactsHeader(&bytes);
}

fn readTextTermTopHitsHeaderFromFile(store: storage_mod.Store, file: std.Io.File) !TextTermTopHitsHeader {
    var bytes: [TextTermTopHitsHeader.encoded_len]u8 = undefined;
    const n = try file.readPositionalAll(store.io, &bytes, 0);
    if (n != bytes.len) return error.InvalidRecord;
    return decodeTextTermTopHitsHeader(&bytes);
}

fn readTextTermTopHitTermRecordAt(store: storage_mod.Store, file: std.Io.File, header: TextTermTopHitsHeader, index: u64) !TextTermTopHitTermRecord {
    if (index >= header.hit_term_count) return error.InvalidRecord;
    const offset = try textTermTopHitTermRecordOffset(header.hit_count, index);
    var bytes: [TextTermTopHitTermRecord.encoded_len]u8 = undefined;
    const n = try file.readPositionalAll(store.io, &bytes, offset);
    if (n != bytes.len) return error.InvalidRecord;
    return decodeTextTermTopHitTermRecord(&bytes, index, header.capacity);
}

fn readTextTermTopHitTermAt(store: storage_mod.Store, file: std.Io.File, header: TextTermTopHitsHeader, term_index: u64) !?TextTermTopHitTermRecord {
    var lo: u64 = 0;
    var hi: u64 = header.hit_term_count;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const record = try readTextTermTopHitTermRecordAt(store, file, header, mid);
        if (record.term_index == term_index) return record;
        if (record.term_index < term_index) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    return null;
}

fn readTextTermTopHitRecordAt(store: storage_mod.Store, file: std.Io.File, index: u64) !TextTermTopHitRecord {
    var bytes: [TextTermTopHitRecord.encoded_len]u8 = undefined;
    const n = try file.readPositionalAll(store.io, &bytes, try textTermTopHitRecordOffset(index));
    if (n != bytes.len) return error.InvalidRecord;
    return decodeTextTermTopHitRecord(&bytes);
}

fn readTextPostingBlockOffsetCheckpointAt(store: storage_mod.Store, file: std.Io.File, block_count: u64, checkpoint_index: u64) !u64 {
    const offset = try textPostingBlockCheckpointOffset(block_count, checkpoint_index);
    var bytes: [persistent_posting_block_ordinal_len]u8 = undefined;
    const n = try file.readPositionalAll(store.io, &bytes, offset);
    if (n != bytes.len) return error.InvalidRecord;
    return try decodePersistentBlockOrdinal(&bytes);
}

fn readTextPostingBlockByteOffsetCheckpointAt(store: storage_mod.Store, file: std.Io.File, term_count: u64, block_count: u64, checkpoint_index: u64) !u64 {
    const offset = try textPostingBlockByteOffsetCheckpointOffset(term_count, block_count, checkpoint_index);
    var bytes: [4]u8 = undefined;
    const n = try file.readPositionalAll(store.io, &bytes, offset);
    if (n != bytes.len) return error.InvalidRecord;
    return std.mem.readInt(u32, &bytes, .little);
}

fn readTextPostingBlockRecordAt(store: storage_mod.Store, file: std.Io.File, term_count: u64, index: u64) !TextPostingBlockRecord {
    var bytes: [TextPostingBlockRecord.encoded_len]u8 = undefined;
    const n = try file.readPositionalAll(store.io, &bytes, try textPostingBlockRecordOffset(term_count, index));
    if (n != bytes.len) return error.InvalidRecord;
    return decodeTextPostingBlockRecord(&bytes);
}

fn readTextPostingImpactBlockIndexAt(store: storage_mod.Store, file: std.Io.File, term_count: u64, index: u64) !u64 {
    var bytes: [persistent_posting_block_ordinal_len]u8 = undefined;
    const n = try file.readPositionalAll(store.io, &bytes, try textPostingBlockImpactRecordOffset(term_count, index));
    if (n != bytes.len) return error.InvalidRecord;
    return try decodePersistentBlockOrdinal(&bytes);
}

fn readTextPostingRecordAt(store: storage_mod.Store, file: std.Io.File, index: u64) !TextPostingRecord {
    const stat = try file.stat(store.io);
    if (stat.kind != .file) return error.IsDir;
    var view = TextPostingsFileView{
        .io = store.io,
        .file = file,
        .size = stat.size,
        .map = null,
    };
    var cursor = try textPostingBodyOffset(index);
    return decodeCompressedTextPostingFromFile(&view, &cursor, 0);
}

fn textPostingOffsetAfterSkipping(store: storage_mod.Store, file: std.Io.File, posting_offset: u64, skip_count: u64) !u64 {
    const stat = try file.stat(store.io);
    if (stat.kind != .file) return error.IsDir;
    var view = TextPostingsFileView{
        .io = store.io,
        .file = file,
        .size = stat.size,
        .map = null,
    };
    var cursor = try textPostingBodyOffset(posting_offset);
    var compressed_previous_doc_id: u64 = 0;
    var i: u64 = 0;
    while (i < skip_count) : (i += 1) {
        if (i % persistent_posting_block_size == 0) compressed_previous_doc_id = 0;
        const posting = try decodeCompressedTextPostingFromFile(&view, &cursor, compressed_previous_doc_id);
        compressed_previous_doc_id = posting.doc_id;
    }
    return cursor - TextPostingsHeader.encoded_len;
}

fn encodeCorruptTextPostingRecordForTest(record: TextPostingRecord, out: *[TextPostingRecord.encoded_len]u8) void {
    const raw_doc_id: u32 = if (record.doc_id > persistent_posting_max_doc_id)
        std.math.maxInt(u32)
    else
        @intCast(record.doc_id);
    std.mem.writeInt(u32, out[0..4], raw_doc_id, .little);
    std.mem.writeInt(u16, out[4..6], @intCast(@min(record.text_freq, std.math.maxInt(u16))), .little);
}

fn readTextDocRecordAt(store: storage_mod.Store, file: std.Io.File, index: u64) !TextDocRecord {
    const header = try readTextDocsHeaderFromFile(store, file);
    return readTextDocRecordAtWithHeader(store, file, header, index);
}

fn readTextDocRecordAtWithHeader(store: storage_mod.Store, file: std.Io.File, header: TextDocsHeader, index: u64) !TextDocRecord {
    if (index >= header.doc_count) return error.InvalidRecord;
    var bytes: [TextDocRecord.encoded_len]u8 = undefined;
    const record_len = header.recordLen();
    const offset = try textDocRecordOffsetForHeader(header, index);
    const n = try file.readPositionalAll(store.io, bytes[0..record_len], offset);
    if (n != record_len) return error.InvalidRecord;
    const doc_id = try nextPersistentTextDocId(index);
    const overflow_node_id = try readTextDocNodeIdOverflowForDoc(store, file, header, doc_id);
    return TextDocRecord.decodeForHeader(bytes[0..record_len], header, index, overflow_node_id);
}

fn readTextDocNodeIdOverflowRecordAt(store: storage_mod.Store, file: std.Io.File, header: TextDocsHeader, index: u64) !TextDocNodeIdOverflowRecord {
    if (index >= header.node_id_overflow_count) return error.InvalidRecord;
    var bytes: [TextDocNodeIdOverflowRecord.encoded_len]u8 = undefined;
    const offset = try textDocNodeIdOverflowRecordOffsetForHeader(header, index);
    const n = try file.readPositionalAll(store.io, &bytes, offset);
    if (n != bytes.len) return error.InvalidRecord;
    return try TextDocNodeIdOverflowRecord.decode(&bytes);
}

fn readTextDocNodeIdOverflowForDoc(store: storage_mod.Store, file: std.Io.File, header: TextDocsHeader, doc_id: u64) !?u64 {
    var left: u64 = 0;
    var right = header.node_id_overflow_count;
    while (left < right) {
        const mid = left + (right - left) / 2;
        const record = try readTextDocNodeIdOverflowRecordAt(store, file, header, mid);
        if (record.doc_id == doc_id) return record.node_id;
        if (record.doc_id < doc_id) {
            left = mid + 1;
        } else {
            right = mid;
        }
    }
    return null;
}

fn readPersistentTextDoc(allocator: std.mem.Allocator, store: storage_mod.Store, doc_id: u64) !TextDocRecord {
    if (doc_id == 0) return error.InvalidRecord;
    const docs_path = try textDocsPath(allocator, store);
    defer allocator.free(docs_path);
    var docs_file = try std.Io.Dir.cwd().openFile(store.io, docs_path, .{});
    defer docs_file.close(store.io);
    const docs_size = try regularFileSize(store, docs_file);
    const header = try readTextDocsHeaderFromFile(store, docs_file);
    if (doc_id > header.doc_count) return error.InvalidRecord;
    const expected_size = textDocsFileSizeForHeader(header) catch |err| switch (err) {
        error.RecordTooLarge => return error.InvalidRecord,
        else => |e| return e,
    };
    if (docs_size != expected_size) return error.InvalidRecord;
    const doc = try readTextDocRecordAtWithHeader(store, docs_file, header, doc_id - 1);
    if (doc.doc_id != doc_id) return error.InvalidRecord;
    return doc;
}

fn readPersistentTextDocCount(allocator: std.mem.Allocator, store: storage_mod.Store) !u64 {
    const docs_path = try textDocsPath(allocator, store);
    defer allocator.free(docs_path);
    var docs_file = try std.Io.Dir.cwd().openFile(store.io, docs_path, .{});
    defer docs_file.close(store.io);
    const docs_size = try regularFileSize(store, docs_file);
    const header = try readTextDocsHeaderFromFile(store, docs_file);
    const expected_size = textDocsFileSizeForHeader(header) catch |err| switch (err) {
        error.RecordTooLarge => return error.InvalidRecord,
        else => |e| return e,
    };
    if (docs_size != expected_size) return error.InvalidRecord;
    return header.doc_count;
}

fn openPersistentTextDocsView(allocator: std.mem.Allocator, store: storage_mod.Store, expected_doc_count: u64) !TextDocsFileView {
    const docs_path = try textDocsPath(allocator, store);
    defer allocator.free(docs_path);
    var view = try TextDocsFileView.open(store, docs_path);
    errdefer view.deinit();
    const header = try view.readHeader();
    if (header.doc_count != expected_doc_count) return error.InvalidRecord;
    const expected_size = textDocsFileSizeForHeader(header) catch |err| switch (err) {
        error.RecordTooLarge => return error.InvalidRecord,
        else => |e| return e,
    };
    if (view.size != expected_size) return error.InvalidRecord;
    return view;
}

const CachedTextDoc = struct {
    doc: TextDocRecord,
    node_ref: storage_mod.Store.NodeRecordView.NodeRef,
    owned_node: ?storage_mod.StoredNode = null,
    metadata: SearchableNodeMetadata = .{},

    fn text(self: CachedTextDoc) []const u8 {
        if (self.node_ref.text_bytes) |bytes| return bytes;
        return self.owned_node.?.text;
    }
};

fn deinitCachedTextDocs(allocator: std.mem.Allocator, docs: *std.AutoHashMap(u64, CachedTextDoc)) void {
    var it = docs.valueIterator();
    while (it.next()) |cached| {
        if (cached.owned_node) |*node| node.deinit(allocator);
        cached.metadata.deinit(allocator);
    }
    docs.deinit();
}

fn getCachedTextDoc(
    allocator: std.mem.Allocator,
    store: storage_mod.Store,
    docs: *std.AutoHashMap(u64, CachedTextDoc),
    doc_id: u64,
) !CachedTextDoc {
    if (docs.get(doc_id)) |cached| return cached;
    const doc = try readPersistentTextDoc(allocator, store, doc_id);
    var node = (try store.readNodeById(allocator, core.NodeId.fromInt(doc.node_id))) orelse return error.InvalidRecord;
    errdefer node.deinit(allocator);
    var metadata = try readSearchableNodeMetadata(allocator, store, node.id);
    errdefer metadata.deinit(allocator);
    const node_ref = storage_mod.Store.NodeRecordView.NodeRef{
        .id = node.id,
        .kind = node.kind,
        .text_offset = 0,
        .text_len = @intCast(node.text.len),
    };
    try validateTextDocAgainstNodeRef(allocator, doc, node_ref, node.text, metadata);
    try docs.put(doc_id, .{ .doc = doc, .node_ref = node_ref, .owned_node = node, .metadata = metadata });
    return docs.get(doc_id).?;
}

fn getCachedTextDocFromView(
    allocator: std.mem.Allocator,
    store: storage_mod.Store,
    view: *TextDocsFileView,
    node_view: *storage_mod.Store.NodeRecordView,
    docs: *std.AutoHashMap(u64, CachedTextDoc),
    doc_id: u64,
) !CachedTextDoc {
    if (docs.get(doc_id)) |cached| return cached;
    if (doc_id == 0) return error.InvalidRecord;
    const doc = try view.readDocAt(doc_id - 1);
    if (doc.doc_id != doc_id) return error.InvalidRecord;
    const node_ref = (try node_view.readNodeRefById(core.NodeId.fromInt(doc.node_id))) orelse return error.InvalidRecord;
    var owned_node: ?storage_mod.StoredNode = null;
    errdefer if (owned_node) |*node| node.deinit(allocator);
    const text = if (node_ref.text_bytes) |bytes| bytes else blk: {
        owned_node = (try node_view.readNodeById(allocator, core.NodeId.fromInt(doc.node_id))) orelse return error.InvalidRecord;
        break :blk owned_node.?.text;
    };
    var metadata = try readSearchableNodeMetadata(allocator, store, core.NodeId.fromInt(doc.node_id));
    errdefer metadata.deinit(allocator);
    try validateTextDocAgainstNodeRef(allocator, doc, node_ref, text, metadata);
    try docs.put(doc_id, .{ .doc = doc, .node_ref = node_ref, .owned_node = owned_node, .metadata = metadata });
    return docs.get(doc_id).?;
}

fn getCachedTextDocRecordFromView(
    view: *TextDocsFileView,
    docs: *std.AutoHashMap(u64, TextDocRecord),
    doc_id: u64,
) !TextDocRecord {
    if (docs.get(doc_id)) |doc| return doc;
    if (doc_id == 0) return error.InvalidRecord;
    const doc = try view.readDocAt(doc_id - 1);
    if (doc.doc_id != doc_id) return error.InvalidRecord;
    try docs.put(doc_id, doc);
    return doc;
}

fn validateTextDocAgainstNode(allocator: std.mem.Allocator, doc: TextDocRecord, node: storage_mod.StoredNode) !void {
    const node_ref = storage_mod.Store.NodeRecordView.NodeRef{
        .id = node.id,
        .kind = node.kind,
        .text_offset = 0,
        .text_len = @intCast(node.text.len),
    };
    const empty_metadata = SearchableNodeMetadata{};
    return validateTextDocAgainstNodeRef(allocator, doc, node_ref, node.text, empty_metadata);
}

fn validateTextDocAgainstNodeRef(allocator: std.mem.Allocator, doc: TextDocRecord, node_ref: storage_mod.Store.NodeRecordView.NodeRef, text: []const u8, metadata: SearchableNodeMetadata) !void {
    return validateTextDocAgainstNodeRefCached(allocator, doc, node_ref, text, metadata);
}

fn validateTextDocAgainstNodeRefCached(
    allocator: std.mem.Allocator,
    doc: TextDocRecord,
    node_ref: storage_mod.Store.NodeRecordView.NodeRef,
    text: []const u8,
    metadata: SearchableNodeMetadata,
) !void {
    if (node_ref.id.toInt() != doc.node_id) return error.InvalidRecord;
    if (node_ref.kind != try doc.nodeKind()) return error.InvalidRecord;
    if (node_ref.text_len != text.len) return error.InvalidRecord;
    const text_tokens = try countSearchableNodeTokens(allocator, text, metadata);
    if (text_tokens > persistent_doc_max_field_tokens) return error.InvalidRecord;
    if (doc.text_tokens != @as(u32, @intCast(text_tokens))) return error.InvalidRecord;
}

fn validateTextPostingAgainstCanonicalNode(
    allocator: std.mem.Allocator,
    term: []const u8,
    posting: TextPostingRecord,
    cached: CachedTextDoc,
) !void {
    const text_freq = try countTermInSearchableNode(allocator, cached.text(), cached.metadata, term);
    const kind_freq: u32 = 0;
    if (posting.text_freq != text_freq or posting.kind_freq != kind_freq) return error.InvalidRecord;
}

fn textDocRecordOffsetForHeader(header: TextDocsHeader, index: u64) !u64 {
    const bytes = std.math.mul(u64, index, header.recordLen()) catch return error.RecordTooLarge;
    return std.math.add(u64, TextDocsHeader.encoded_len, bytes) catch return error.RecordTooLarge;
}

fn textDocRecordOffset(index: u64) !u64 {
    return textDocRecordOffsetForHeader(.{}, index);
}

fn textDocNodeIdOverflowRecordOffsetForHeader(header: TextDocsHeader, overflow_index: u64) !u64 {
    const records_bytes = std.math.mul(u64, header.doc_count, header.recordLen()) catch return error.RecordTooLarge;
    const overflow_bytes = std.math.mul(u64, overflow_index, TextDocNodeIdOverflowRecord.encoded_len) catch return error.RecordTooLarge;
    return std.math.add(u64, try std.math.add(u64, TextDocsHeader.encoded_len, records_bytes), overflow_bytes) catch return error.RecordTooLarge;
}

fn textDocNodeIdOverflowRecordOffset(doc_count: u64, overflow_index: u64) !u64 {
    return textDocNodeIdOverflowRecordOffsetForHeader(.{ .doc_count = doc_count }, overflow_index);
}

fn textDocsFileSizeForHeader(header: TextDocsHeader) !u64 {
    try header.validateShape();
    const bytes = std.math.mul(u64, header.doc_count, header.recordLen()) catch return error.RecordTooLarge;
    const overflow_bytes = std.math.mul(u64, header.node_id_overflow_count, TextDocNodeIdOverflowRecord.encoded_len) catch return error.RecordTooLarge;
    return std.math.add(u64, try std.math.add(u64, TextDocsHeader.encoded_len, bytes), overflow_bytes) catch return error.RecordTooLarge;
}

fn textDocsFileSize(doc_count: u64, node_id_overflow_count: u64) !u64 {
    return textDocsFileSizeForHeader(.{ .doc_count = doc_count, .node_id_overflow_count = node_id_overflow_count });
}

fn textPostingBodyOffset(posting_offset: u64) !u64 {
    return std.math.add(u64, TextPostingsHeader.encoded_len, posting_offset) catch return error.RecordTooLarge;
}

fn textPostingRecordOffset(posting_offset: u64) !u64 {
    return textPostingBodyOffset(posting_offset);
}

fn textPostingsFileSize(body_bytes: u64) !u64 {
    return std.math.add(u64, TextPostingsHeader.encoded_len, body_bytes) catch return error.RecordTooLarge;
}

fn textPostingBlockRecordsOffset() u64 {
    return TextPostingBlocksHeader.encoded_len;
}

fn textPostingBlockCheckpointCount(term_count: u64) !u64 {
    if (term_count == 0) return 0;
    const adjusted = std.math.add(u64, term_count, persistent_posting_block_offset_checkpoint_terms - 1) catch return error.RecordTooLarge;
    return adjusted / persistent_posting_block_offset_checkpoint_terms;
}

fn textPostingBlockCheckpointTableBytes(term_count: u64) !u64 {
    const checkpoint_count = try textPostingBlockCheckpointCount(term_count);
    return std.math.mul(u64, checkpoint_count, persistent_posting_block_ordinal_len) catch return error.RecordTooLarge;
}

fn textPostingBlockCheckpointTableOffset(block_count: u64) !u64 {
    if (block_count > persistent_posting_max_block_ordinal) return error.RecordTooLarge;
    const bytes = std.math.mul(u64, block_count, TextPostingBlockRecord.encoded_len) catch return error.RecordTooLarge;
    return std.math.add(u64, textPostingBlockRecordsOffset(), bytes) catch return error.RecordTooLarge;
}

fn textPostingBlockCheckpointOffset(block_count: u64, checkpoint_index: u64) !u64 {
    if (block_count > persistent_posting_max_block_ordinal) return error.RecordTooLarge;
    const checkpoint_table_offset = try textPostingBlockCheckpointTableOffset(block_count);
    const bytes = std.math.mul(u64, checkpoint_index, persistent_posting_block_ordinal_len) catch return error.RecordTooLarge;
    return std.math.add(u64, checkpoint_table_offset, bytes) catch return error.RecordTooLarge;
}

fn textPostingBlockByteOffsetCheckpointCount(block_count: u64) !u64 {
    return std.math.divCeil(u64, block_count, persistent_posting_block_byte_offset_checkpoint_blocks) catch return error.RecordTooLarge;
}

fn textPostingBlockByteOffsetCheckpointTableBytes(block_count: u64) !u64 {
    const checkpoint_count = try textPostingBlockByteOffsetCheckpointCount(block_count);
    return std.math.mul(u64, checkpoint_count, 4) catch return error.RecordTooLarge;
}

fn textPostingBlockByteOffsetCheckpointTableOffset(term_count: u64, block_count: u64) !u64 {
    const term_checkpoint_offset = try textPostingBlockCheckpointTableOffset(block_count);
    const term_checkpoint_bytes = try textPostingBlockCheckpointTableBytes(term_count);
    return std.math.add(u64, term_checkpoint_offset, term_checkpoint_bytes) catch return error.RecordTooLarge;
}

fn textPostingBlockByteOffsetCheckpointOffset(term_count: u64, block_count: u64, checkpoint_index: u64) !u64 {
    const checkpoint_count = try textPostingBlockByteOffsetCheckpointCount(block_count);
    if (checkpoint_index >= checkpoint_count) return error.InvalidRecord;
    const checkpoint_table_offset = try textPostingBlockByteOffsetCheckpointTableOffset(term_count, block_count);
    const bytes = std.math.mul(u64, checkpoint_index, 4) catch return error.RecordTooLarge;
    return std.math.add(u64, checkpoint_table_offset, bytes) catch return error.RecordTooLarge;
}

fn textPostingBlockRecordOffset(_: u64, index: u64) !u64 {
    const bytes = std.math.mul(u64, index, TextPostingBlockRecord.encoded_len) catch return error.RecordTooLarge;
    return std.math.add(u64, textPostingBlockRecordsOffset(), bytes) catch return error.RecordTooLarge;
}

fn textPostingBlocksFileSize(term_count: u64, block_count: u64) !u64 {
    if (block_count > persistent_posting_max_block_ordinal) return error.RecordTooLarge;
    const checkpoint_table_bytes = try textPostingBlockCheckpointTableBytes(term_count);
    const byte_offset_checkpoint_table_bytes = try textPostingBlockByteOffsetCheckpointTableBytes(block_count);
    const bytes = std.math.mul(u64, block_count, TextPostingBlockRecord.encoded_len) catch return error.RecordTooLarge;
    const checkpoint_table_offset = std.math.add(u64, textPostingBlockRecordsOffset(), bytes) catch return error.RecordTooLarge;
    const byte_offset_checkpoint_table_offset = std.math.add(u64, checkpoint_table_offset, checkpoint_table_bytes) catch return error.RecordTooLarge;
    return std.math.add(u64, byte_offset_checkpoint_table_offset, byte_offset_checkpoint_table_bytes) catch return error.RecordTooLarge;
}

fn textPostingBlockImpactRecordsOffset() u64 {
    return TextPostingBlockImpactsHeader.encoded_len;
}

fn textPostingBlockImpactRecordOffset(_: u64, index: u64) !u64 {
    const bytes = std.math.mul(u64, index, persistent_posting_block_ordinal_len) catch return error.RecordTooLarge;
    return std.math.add(u64, textPostingBlockImpactRecordsOffset(), bytes) catch return error.RecordTooLarge;
}

fn textPostingBlockImpactsFileSize(term_count: u64, block_count: u64) !u64 {
    _ = term_count;
    if (block_count > persistent_posting_max_block_ordinal) return error.RecordTooLarge;
    const bytes = std.math.mul(u64, block_count, persistent_posting_block_ordinal_len) catch return error.RecordTooLarge;
    return std.math.add(u64, textPostingBlockImpactRecordsOffset(), bytes) catch return error.RecordTooLarge;
}

fn textTermTopHitTermIndexBytes(hit_term_count: u64) !u64 {
    return std.math.mul(u64, hit_term_count, TextTermTopHitTermRecord.encoded_len) catch return error.RecordTooLarge;
}

fn textTermTopHitRecordsOffset() u64 {
    return TextTermTopHitsHeader.encoded_len;
}

fn textTermTopHitTermIndexOffset(hit_count: u64) !u64 {
    const bytes = std.math.mul(u64, hit_count, TextTermTopHitRecord.encoded_len) catch return error.RecordTooLarge;
    return std.math.add(u64, textTermTopHitRecordsOffset(), bytes) catch return error.RecordTooLarge;
}

fn textTermTopHitTermRecordOffset(hit_count: u64, hit_term_index: u64) !u64 {
    const index_offset = try textTermTopHitTermIndexOffset(hit_count);
    const bytes = std.math.mul(u64, hit_term_index, TextTermTopHitTermRecord.encoded_len) catch return error.RecordTooLarge;
    return std.math.add(u64, index_offset, bytes) catch return error.RecordTooLarge;
}

fn textTermTopHitRecordOffset(index: u64) !u64 {
    const bytes = std.math.mul(u64, index, TextTermTopHitRecord.encoded_len) catch return error.RecordTooLarge;
    return std.math.add(u64, textTermTopHitRecordsOffset(), bytes) catch return error.RecordTooLarge;
}

fn textTermTopHitsFileSize(hit_count: u64, hit_term_count: u64) !u64 {
    const index_bytes = try textTermTopHitTermIndexBytes(hit_term_count);
    const bytes = std.math.mul(u64, hit_count, TextTermTopHitRecord.encoded_len) catch return error.RecordTooLarge;
    const index_offset = std.math.add(u64, textTermTopHitRecordsOffset(), bytes) catch return error.RecordTooLarge;
    return std.math.add(u64, index_offset, index_bytes) catch return error.RecordTooLarge;
}

fn regularFileSize(store: storage_mod.Store, file: std.Io.File) !u64 {
    const stat = try file.stat(store.io);
    if (stat.kind != .file) return error.IsDir;
    return stat.size;
}

fn readTextTermByteOffsetCheckpointAt(
    store: storage_mod.Store,
    file: std.Io.File,
    header: TextTermsHeader,
    checkpoint_index: u64,
) !u64 {
    var bytes: [4]u8 = undefined;
    const n = try file.readPositionalAll(store.io, &bytes, try textTermByteOffsetCheckpointOffset(header.term_count, header.term_bytes, checkpoint_index));
    if (n != bytes.len) return error.InvalidRecord;
    return std.mem.readInt(u32, &bytes, .little);
}

fn textTermByteOffsetForIndex(store: storage_mod.Store, file: std.Io.File, header: TextTermsHeader, index: u64) !u64 {
    if (index >= header.term_count) return error.InvalidRecord;
    const checkpoint_index = index / persistent_term_byte_offset_checkpoint_terms;
    const checkpoint_term = checkpoint_index * persistent_term_byte_offset_checkpoint_terms;
    var term_offset = try readTextTermByteOffsetCheckpointAt(store, file, header, checkpoint_index);
    if (term_offset > header.term_bytes) return error.InvalidRecord;
    var previous_term_len: usize = 0;
    var pos = checkpoint_term;
    while (pos < index) : (pos += 1) {
        const entry = try readTextTermEntryAt(store, file, header, pos);
        const prefix_len = try readFrontCodedTermPrefixAtOffset(store, file, header, pos, term_offset, previous_term_len, entry);
        const encoded_len = try frontCodedEncodedLen(entry, prefix_len);
        if (encoded_len > header.term_bytes - term_offset) return error.InvalidRecord;
        term_offset = std.math.add(u64, term_offset, encoded_len) catch return error.RecordTooLarge;
        previous_term_len = std.math.cast(usize, entry.term_len) orelse return error.RecordTooLarge;
    }
    return term_offset;
}

const DecodedFrontCodedTerm = struct {
    term: []u8,
    encoded_len: u64,
};

fn readFrontCodedTermPrefixAtOffset(
    store: storage_mod.Store,
    file: std.Io.File,
    header: TextTermsHeader,
    term_index: u64,
    term_offset: u64,
    previous_term_len: usize,
    entry: TextTermEntry,
) !u8 {
    if (textTermEntryFrontPrefixLen(entry)) |prefix_len| {
        if (term_index % persistent_term_byte_offset_checkpoint_terms == 0 and prefix_len != 0) return error.InvalidRecord;
        if (prefix_len > previous_term_len or prefix_len > entry.term_len) return error.InvalidRecord;
        return prefix_len;
    }
    if (term_offset >= header.term_bytes) return error.InvalidRecord;
    const bytes_offset = try textTermsBytesOffset(header.term_count);
    var prefix_bytes: [1]u8 = undefined;
    const prefix_offset = std.math.add(u64, bytes_offset, term_offset) catch return error.RecordTooLarge;
    const n = try file.readPositionalAll(store.io, &prefix_bytes, prefix_offset);
    if (n != prefix_bytes.len) return error.InvalidRecord;
    const prefix_len = prefix_bytes[0];
    if (term_index % persistent_term_byte_offset_checkpoint_terms == 0 and prefix_len != 0) return error.InvalidRecord;
    if (prefix_len > previous_term_len or prefix_len > entry.term_len) return error.InvalidRecord;
    return prefix_len;
}

fn readFrontCodedTermAtOffset(
    allocator: std.mem.Allocator,
    store: storage_mod.Store,
    file: std.Io.File,
    header: TextTermsHeader,
    term_index: u64,
    term_offset: u64,
    entry: TextTermEntry,
    previous_term: ?[]const u8,
) !DecodedFrontCodedTerm {
    if (term_offset >= header.term_bytes) return error.InvalidRecord;
    const bytes_offset = try textTermsBytesOffset(header.term_count);
    const term_len = std.math.cast(usize, entry.term_len) orelse return error.RecordTooLarge;
    const previous_len = if (previous_term) |term| term.len else 0;
    const prefix_len = try readFrontCodedTermPrefixAtOffset(store, file, header, term_index, term_offset, previous_len, entry);
    const suffix_len = term_len - prefix_len;
    const encoded_len = try frontCodedEncodedLen(entry, prefix_len);
    if (encoded_len > header.term_bytes - term_offset) return error.InvalidRecord;
    const term = try allocator.alloc(u8, term_len);
    errdefer allocator.free(term);
    if (prefix_len != 0) {
        const previous = previous_term orelse return error.InvalidRecord;
        @memcpy(term[0..prefix_len], previous[0..prefix_len]);
    }
    const term_absolute_offset = std.math.add(u64, bytes_offset, term_offset) catch return error.RecordTooLarge;
    const suffix_offset = std.math.add(u64, term_absolute_offset, frontCodedPrefixByteCount(entry, prefix_len)) catch return error.RecordTooLarge;
    const n = try file.readPositionalAll(store.io, term[prefix_len..], suffix_offset);
    if (n != suffix_len) return error.InvalidRecord;
    return .{ .term = term, .encoded_len = encoded_len };
}

fn termEntryMatches(
    store: storage_mod.Store,
    file: std.Io.File,
    header: TextTermsHeader,
    index: u64,
    entry: TextTermEntry,
    term: []const u8,
) !bool {
    if (entry.term_len != term.len) return false;
    const checkpoint_index = index / persistent_term_byte_offset_checkpoint_terms;
    const checkpoint_term = checkpoint_index * persistent_term_byte_offset_checkpoint_terms;
    var encoded_offset = try readTextTermByteOffsetCheckpointAt(store, file, header, checkpoint_index);
    if (encoded_offset > header.term_bytes) return error.InvalidRecord;

    var previous: [default_max_token_bytes]u8 = undefined;
    var current: [default_max_token_bytes]u8 = undefined;
    var previous_len: usize = 0;
    var pos = checkpoint_term;
    while (pos <= index) : (pos += 1) {
        const current_entry = if (pos == index) entry else try readTextTermEntryAt(store, file, header, pos);
        const current_len = std.math.cast(usize, current_entry.term_len) orelse return error.RecordTooLarge;
        const prefix_len = try readFrontCodedTermPrefixAtOffset(store, file, header, pos, encoded_offset, previous_len, current_entry);
        const suffix_len = current_len - prefix_len;
        const encoded_len = try frontCodedEncodedLen(current_entry, prefix_len);
        if (encoded_len > header.term_bytes - encoded_offset) return error.InvalidRecord;
        @memcpy(current[0..prefix_len], previous[0..prefix_len]);
        const bytes_offset = try textTermsBytesOffset(header.term_count);
        const encoded_absolute_offset = std.math.add(u64, bytes_offset, encoded_offset) catch return error.RecordTooLarge;
        const suffix_offset = std.math.add(u64, encoded_absolute_offset, frontCodedPrefixByteCount(current_entry, prefix_len)) catch return error.RecordTooLarge;
        const n = try file.readPositionalAll(store.io, current[prefix_len..current_len], suffix_offset);
        if (n != suffix_len) return error.InvalidRecord;
        if (pos == index) return std.mem.eql(u8, current[0..current_len], term);
        @memcpy(previous[0..current_len], current[0..current_len]);
        previous_len = current_len;
        encoded_offset = std.math.add(u64, encoded_offset, encoded_len) catch return error.RecordTooLarge;
        if (encoded_offset > header.term_bytes) return error.InvalidRecord;
    }
    return error.InvalidRecord;
}

const TermFreqField = enum {
    text,
    kind,
};

fn collectTermFreqs(
    allocator: std.mem.Allocator,
    freqs: *std.StringHashMap(FieldTermFreq),
    owned: ?*std.ArrayList([]u8),
    text: []const u8,
    field: TermFreqField,
) !u64 {
    var tokens = try tokenize(allocator, text, .{});
    defer tokens.deinit();
    for (tokens.items.items) |term| {
        try addFieldTermFreq(allocator, freqs, owned, term, field);
    }
    return @intCast(tokens.items.items.len);
}

fn collectStreamingTermFreqs(
    allocator: std.mem.Allocator,
    freqs: *std.StringHashMap(FieldTermFreq),
    owned: ?*std.ArrayList([]u8),
    text: []const u8,
    field: TermFreqField,
) !u64 {
    var scratch = std.ArrayList(u8).empty;
    defer scratch.deinit(allocator);
    return collectStreamingTermFreqsWithScratch(allocator, allocator, freqs, owned, text, field, &scratch);
}

fn collectStreamingTermFreqsWithScratch(
    term_allocator: std.mem.Allocator,
    scratch_allocator: std.mem.Allocator,
    freqs: *std.StringHashMap(FieldTermFreq),
    owned: ?*std.ArrayList([]u8),
    text: []const u8,
    field: TermFreqField,
    scratch: *std.ArrayList(u8),
) !u64 {
    scratch.clearRetainingCapacity();
    var token_count: u64 = 0;

    var i: usize = 0;
    while (i < text.len) {
        if (text[i] < 0x80) {
            if (isRunByte(text[i])) {
                const run_start = i;
                var run_has_upper = std.ascii.isUpper(text[i]);
                i += 1;
                while (i < text.len and isRunByte(text[i])) : (i += 1) {
                    run_has_upper = run_has_upper or std.ascii.isUpper(text[i]);
                }
                if (i == text.len or text[i] < 0x80 or normalizedRunByte(decodeUtf8(text, i).codepoint) == null) {
                    token_count += try collectRunTermFreqs(term_allocator, freqs, owned, text[run_start..i], field, .{}, true, !run_has_upper);
                    continue;
                }
                i = run_start;
            } else {
                i += 1;
                continue;
            }
        }
        const decoded = decodeUtf8(text, i);
        const cp = decoded.codepoint;
        if (isCjk(cp)) {
            scratch.clearRetainingCapacity();
            try appendNormalizedCjkCodepoint(scratch, scratch_allocator, text, &i, decoded);
            while (i < text.len) {
                const next = decodeUtf8(text, i);
                if (!isCjk(next.codepoint)) {
                    if (isCjkJoiner(next.codepoint)) {
                        const after_joiner = i + next.len;
                        if (after_joiner < text.len and isCjk(decodeUtf8(text, after_joiner).codepoint)) {
                            i = after_joiner;
                            continue;
                        }
                    }
                    break;
                }
                try appendNormalizedCjkCodepoint(scratch, scratch_allocator, text, &i, next);
            }
            token_count += try collectCjkTermFreqs(term_allocator, freqs, owned, scratch.items, field, .{});
        } else if (normalizedRunByte(cp)) |first_byte| {
            if (decoded.len == 1 and first_byte == text[i]) {
                const run_start = i;
                var run_has_upper = std.ascii.isUpper(text[i]);
                i += 1;
                while (i < text.len and isRunByte(text[i])) : (i += 1) {
                    run_has_upper = run_has_upper or std.ascii.isUpper(text[i]);
                }
                if (i == text.len or text[i] < 0x80 or normalizedRunByte(decodeUtf8(text, i).codepoint) == null) {
                    token_count += try collectRunTermFreqs(term_allocator, freqs, owned, text[run_start..i], field, .{}, true, !run_has_upper);
                    continue;
                }
                i = run_start;
            }
            token_count += try collectNormalizedRunTermFreqs(term_allocator, scratch_allocator, freqs, owned, text, &i, field, .{}, scratch);
        } else {
            i += decoded.len;
        }
    }

    return token_count;
}

fn incrementFieldTermFreq(value: *FieldTermFreq, field: TermFreqField) !void {
    switch (field) {
        .text => value.text = std.math.add(u32, value.text, 1) catch return error.RecordTooLarge,
        .kind => value.kind = std.math.add(u32, value.kind, 1) catch return error.RecordTooLarge,
    }
}

fn initialFieldTermFreq(field: TermFreqField) FieldTermFreq {
    var initial = FieldTermFreq{};
    switch (field) {
        .text => initial.text = 1,
        .kind => initial.kind = 1,
    }
    return initial;
}

fn addBorrowedFieldTermFreq(
    freqs: *std.StringHashMap(FieldTermFreq),
    term: []const u8,
    field: TermFreqField,
) !void {
    if (term.len == 0) return;
    if (freqs.getPtr(term)) |value| {
        try incrementFieldTermFreq(value, field);
        return;
    }
    try freqs.put(term, initialFieldTermFreq(field));
}

fn addFieldTermFreq(
    allocator: std.mem.Allocator,
    freqs: *std.StringHashMap(FieldTermFreq),
    owned: ?*std.ArrayList([]u8),
    term: []const u8,
    field: TermFreqField,
) !void {
    if (term.len == 0) return;
    if (freqs.getPtr(term)) |value| {
        try incrementFieldTermFreq(value, field);
        return;
    }

    const copy = try allocator.dupe(u8, term);
    var appended = false;
    var committed = false;
    errdefer if (!committed) {
        if (appended) {
            if (owned) |terms| _ = terms.pop();
        }
        allocator.free(copy);
    };
    const initial = initialFieldTermFreq(field);
    if (owned) |terms| {
        try terms.append(allocator, copy);
        appended = true;
    }
    try freqs.put(copy, initial);
    committed = true;
}

fn addOwnedFieldTermFreq(
    allocator: std.mem.Allocator,
    freqs: *std.StringHashMap(FieldTermFreq),
    owned: ?*std.ArrayList([]u8),
    term: []u8,
    field: TermFreqField,
) !void {
    if (term.len == 0) {
        allocator.free(term);
        return;
    }
    if (freqs.getPtr(term)) |value| {
        allocator.free(term);
        try incrementFieldTermFreq(value, field);
        return;
    }

    var appended = false;
    var committed = false;
    errdefer if (!committed) {
        if (appended) {
            if (owned) |terms| _ = terms.pop();
        }
        allocator.free(term);
    };
    const initial = initialFieldTermFreq(field);
    if (owned) |terms| {
        try terms.append(allocator, term);
        appended = true;
    }
    try freqs.put(term, initial);
    committed = true;
}

fn addNewOwnedFieldTermFreq(
    allocator: std.mem.Allocator,
    freqs: *std.StringHashMap(FieldTermFreq),
    owned: ?*std.ArrayList([]u8),
    term: []u8,
    field: TermFreqField,
) !void {
    if (term.len == 0) {
        allocator.free(term);
        return;
    }

    var appended = false;
    var committed = false;
    errdefer if (!committed) {
        if (appended) {
            if (owned) |terms| _ = terms.pop();
        }
        allocator.free(term);
    };
    if (owned) |terms| {
        try terms.append(allocator, term);
        appended = true;
    }
    try freqs.put(term, initialFieldTermFreq(field));
    committed = true;
}

fn canBorrowLowerAsciiTerm(bytes: []const u8, max_token_bytes: usize) bool {
    if (bytes.len == 0 or bytes.len > max_token_bytes) return false;
    for (bytes) |byte| {
        if (byte >= 0x80) return false;
        if (std.ascii.isUpper(byte)) return false;
    }
    return true;
}

fn addLowerAsciiFieldTermFreq(
    allocator: std.mem.Allocator,
    freqs: *std.StringHashMap(FieldTermFreq),
    owned: ?*std.ArrayList([]u8),
    bytes: []const u8,
    field: TermFreqField,
    max_token_bytes: usize,
    borrow_lower_ascii: bool,
) !u64 {
    if (bytes.len == 0 or bytes.len > max_token_bytes) return 0;
    if (borrow_lower_ascii and owned == null and canBorrowLowerAsciiTerm(bytes, max_token_bytes)) {
        try addBorrowedFieldTermFreq(freqs, bytes, field);
        return 1;
    }
    var lowered_buf: [default_max_token_bytes]u8 = undefined;
    if (bytes.len <= lowered_buf.len) {
        for (bytes, 0..) |byte, i| lowered_buf[i] = std.ascii.toLower(byte);
        const lowered = lowered_buf[0..bytes.len];
        if (freqs.getPtr(lowered)) |value| {
            try incrementFieldTermFreq(value, field);
            return 1;
        }

        const term = try allocator.dupe(u8, lowered);
        try addNewOwnedFieldTermFreq(allocator, freqs, owned, term, field);
    } else {
        const term = try allocator.alloc(u8, bytes.len);
        for (bytes, 0..) |byte, i| term[i] = std.ascii.toLower(byte);
        try addOwnedFieldTermFreq(allocator, freqs, owned, term, field);
    }
    return 1;
}

fn addTrustedLowerAsciiFieldTermFreq(
    allocator: std.mem.Allocator,
    freqs: *std.StringHashMap(FieldTermFreq),
    owned: ?*std.ArrayList([]u8),
    bytes: []const u8,
    field: TermFreqField,
    max_token_bytes: usize,
) !u64 {
    if (bytes.len == 0 or bytes.len > max_token_bytes) return 0;
    if (owned == null) {
        try addBorrowedFieldTermFreq(freqs, bytes, field);
        return 1;
    }
    return try addLowerAsciiFieldTermFreq(allocator, freqs, owned, bytes, field, max_token_bytes, false);
}

fn addRunFieldTermFreq(
    allocator: std.mem.Allocator,
    freqs: *std.StringHashMap(FieldTermFreq),
    owned: ?*std.ArrayList([]u8),
    bytes: []const u8,
    field: TermFreqField,
    max_token_bytes: usize,
    borrow_lower_ascii: bool,
    trusted_lower_ascii: bool,
) !u64 {
    if (trusted_lower_ascii) {
        return try addTrustedLowerAsciiFieldTermFreq(allocator, freqs, owned, bytes, field, max_token_bytes);
    }
    return try addLowerAsciiFieldTermFreq(allocator, freqs, owned, bytes, field, max_token_bytes, borrow_lower_ascii);
}

fn collectRunTermFreqs(
    allocator: std.mem.Allocator,
    freqs: *std.StringHashMap(FieldTermFreq),
    owned: ?*std.ArrayList([]u8),
    run: []const u8,
    field: TermFreqField,
    options: TokenizerOptions,
    borrow_lower_ascii: bool,
    trusted_lower_ascii: bool,
) !u64 {
    var token_count: u64 = 0;
    if (options.emit_original_compound and shouldEmitOriginal(run)) {
        token_count += try addRunFieldTermFreq(allocator, freqs, owned, run, field, options.max_token_bytes, borrow_lower_ascii, trusted_lower_ascii);
    }

    var part_start: ?usize = null;
    for (run, 0..) |byte, i| {
        if (std.ascii.isAlphanumeric(byte)) {
            if (part_start == null) part_start = i;
        } else if (part_start) |start| {
            token_count += try collectIdentifierPartTermFreqs(allocator, freqs, owned, run[start..i], field, options.max_token_bytes, borrow_lower_ascii, trusted_lower_ascii);
            part_start = null;
        }
    }
    if (part_start) |start| {
        token_count += try collectIdentifierPartTermFreqs(allocator, freqs, owned, run[start..], field, options.max_token_bytes, borrow_lower_ascii, trusted_lower_ascii);
    }
    return token_count;
}

fn collectNormalizedRunTermFreqs(
    term_allocator: std.mem.Allocator,
    scratch_allocator: std.mem.Allocator,
    freqs: *std.StringHashMap(FieldTermFreq),
    owned: ?*std.ArrayList([]u8),
    text: []const u8,
    offset: *usize,
    field: TermFreqField,
    options: TokenizerOptions,
    scratch: *std.ArrayList(u8),
) !u64 {
    scratch.clearRetainingCapacity();

    while (offset.* < text.len) {
        const decoded = decodeUtf8(text, offset.*);
        const byte = normalizedRunByte(decoded.codepoint) orelse break;
        try scratch.append(scratch_allocator, byte);
        offset.* += decoded.len;
    }

    return collectRunTermFreqs(term_allocator, freqs, owned, scratch.items, field, options, false, false);
}

fn collectIdentifierPartTermFreqs(
    allocator: std.mem.Allocator,
    freqs: *std.StringHashMap(FieldTermFreq),
    owned: ?*std.ArrayList([]u8),
    ident: []const u8,
    field: TermFreqField,
    max_token_bytes: usize,
    borrow_lower_ascii: bool,
    trusted_lower_ascii: bool,
) !u64 {
    if (ident.len == 0) return 0;
    var token_count: u64 = 0;
    if (containsCamelBoundary(ident)) {
        token_count += try addRunFieldTermFreq(allocator, freqs, owned, ident, field, max_token_bytes, borrow_lower_ascii, trusted_lower_ascii);
    }

    var start: usize = 0;
    var i: usize = 1;
    while (i < ident.len) : (i += 1) {
        if (isCamelSplit(ident, i)) {
            token_count += try addRunFieldTermFreq(allocator, freqs, owned, ident[start..i], field, max_token_bytes, borrow_lower_ascii, trusted_lower_ascii);
            start = i;
        }
    }
    token_count += try addRunFieldTermFreq(allocator, freqs, owned, ident[start..], field, max_token_bytes, borrow_lower_ascii, trusted_lower_ascii);
    return token_count;
}

fn collectCjkTermFreqs(
    allocator: std.mem.Allocator,
    freqs: *std.StringHashMap(FieldTermFreq),
    owned: ?*std.ArrayList([]u8),
    bytes: []const u8,
    field: TermFreqField,
    options: TokenizerOptions,
) !u64 {
    var token_count: u64 = 0;
    var previous_start: ?usize = null;
    var i: usize = 0;
    while (i < bytes.len) {
        const start = i;
        i += decodeUtf8(bytes, i).len;
        const end = i;

        if (options.emit_cjk_unigrams and end - start <= options.max_token_bytes) {
            try addFieldTermFreq(allocator, freqs, owned, bytes[start..end], field);
            token_count += 1;
        }
        if (options.emit_cjk_bigrams) {
            if (previous_start) |bigram_start| {
                if (end - bigram_start <= options.max_token_bytes) {
                    try addFieldTermFreq(allocator, freqs, owned, bytes[bigram_start..end], field);
                    token_count += 1;
                }
            }
        }
        previous_start = start;
    }
    return token_count;
}

fn persistentWeightedTf(posting: TextPostingRecord) f32 {
    const text_freq: f32 = @floatFromInt(posting.text_freq);
    const kind_freq: f32 = @floatFromInt(posting.kind_freq);
    const weights = TextFieldWeights{};
    return text_freq * weights.text + kind_freq * weights.kind;
}

fn persistentWeightedTfFromFieldFreq(freq: FieldTermFreq) f32 {
    const text_freq: f32 = @floatFromInt(freq.text);
    const kind_freq: f32 = @floatFromInt(freq.kind);
    const weights = TextFieldWeights{};
    return text_freq * weights.text + kind_freq * weights.kind;
}

fn persistentDocLen(doc: TextDocRecord) f32 {
    return persistentDocLenFromTextTokens(doc.text_tokens);
}

fn persistentDocLenFromTextTokens(text_tokens: u32) f32 {
    const text_len: f32 = @floatFromInt(text_tokens);
    const weights = TextFieldWeights{};
    return text_len * weights.text;
}

fn persistentAvgDocLen(meta: PersistentTextMeta) f32 {
    if (meta.doc_count == 0) return 0;
    const text_len: f32 = @floatFromInt(meta.total_text_tokens);
    const count: f32 = @floatFromInt(meta.doc_count);
    const weights = TextFieldWeights{};
    return (text_len * weights.text) / count;
}

fn persistentTermFrontCodedLen(term_index: u64, previous_term: ?[]const u8, term: []const u8) !u64 {
    const prefix_len = try persistentTermFrontCodedPrefixLen(term_index, previous_term, term);
    if (prefix_len > term.len) return error.InvalidRecord;
    const suffix_len: u8 = @intCast(term.len - prefix_len);
    return @as(u64, if (frontCodedPrefixInlineable(prefix_len, suffix_len)) 0 else 1) + suffix_len;
}

fn appendPersistentFrontCodedTerm(writer: *TextBufferedWriter, term_index: u64, previous_term: ?[]const u8, term: []const u8) !u64 {
    const prefix_len = try persistentTermFrontCodedPrefixLen(term_index, previous_term, term);
    if (prefix_len > term.len) return error.InvalidRecord;
    const suffix = term[prefix_len..];
    const prefix_bytes: u64 = if (frontCodedPrefixInlineable(prefix_len, @intCast(suffix.len))) 0 else 1;
    if (prefix_bytes != 0) try writer.append(&[_]u8{prefix_len});
    try writer.append(suffix);
    return prefix_bytes + @as(u64, suffix.len);
}

fn persistentTermLessThan(_: void, lhs: PersistentTerm, rhs: PersistentTerm) bool {
    return std.mem.order(u8, lhs.term, rhs.term) == .lt;
}

fn termSortPrefixKey(term: []const u8) u64 {
    var key: u64 = 0;
    var index: usize = 0;
    while (index < @sizeOf(u64)) : (index += 1) {
        key <<= 8;
        if (index < term.len) key |= term[index];
    }
    return key;
}

fn termSortTailKey(term: []const u8) u64 {
    var key: u64 = 0;
    var index: usize = 0;
    const tail_len = @min(term.len, @sizeOf(u64));
    const start = term.len - tail_len;
    while (index < @sizeOf(u64)) : (index += 1) {
        key <<= 8;
        if (index < tail_len) key |= term[start + index];
    }
    return key;
}

fn termHash(term: []const u8) u64 {
    return std.hash.Wyhash.hash(0x544B_4754, term);
}

fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| {
        if (byte != 0) return false;
    }
    return true;
}

const TestPostingCountContext = struct {
    count: usize = 0,
};

fn countStreamingPosting(context: *TestPostingCountContext, _: TextPostingRecord, _: u64) !void {
    context.count += 1;
}

const TestPostingBlockContext = struct {
    allocator: std.mem.Allocator,
    blocks: std.ArrayList(TextPostingBlockStats) = .empty,

    fn deinit(self: *TestPostingBlockContext) void {
        self.blocks.deinit(self.allocator);
    }
};

fn collectPostingBlock(context: *TestPostingBlockContext, stats: TextPostingBlockStats) !void {
    try context.blocks.append(context.allocator, stats);
}

test "text index searches graph node texts with code-aware terms" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();

    const store_id = try graph.addNode(.function, "readEdgeIndexRecordsByNode");
    _ = try graph.addNode(.file, "src/ql/executor.zig");

    var index = try TextIndex.buildFromGraph(std.testing.allocator, &graph);
    defer index.deinit();

    var hits = try index.search("edge index node", .{ .limit = 10 });
    defer hits.deinit(std.testing.allocator);

    try std.testing.expect(hits.items.len >= 1);
    try std.testing.expectEqual(store_id, hits.items[0].node_id);
    try std.testing.expect(hits.items[0].score > 0);
}

fn textIndexAddDocumentAllocationFailure(allocator: std.mem.Allocator) !void {
    var index = TextIndex.init(allocator);
    defer index.deinit();
    try index.addDocument(.{
        .node_id = .fromInt(1),
        .kind = .function,
        .text = "readEdgeIndexRecordsByNode 错误记录",
    });
}

test "text index add document rolls back allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, textIndexAddDocumentAllocationFailure, .{});
}

test "text index accepts schema-defined node kinds without enum tag panic" {
    var index = TextIndex.init(std.testing.allocator);
    defer index.deinit();

    const custom_kind: core.NodeKind = @enumFromInt(100);
    try index.addDocument(.{
        .node_id = .fromInt(1),
        .kind = custom_kind,
        .text = "custom schema node",
    });

    var hits = try index.search("custom schema", .{ .limit = 10 });
    defer hits.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), hits.items.len);
    try std.testing.expectEqual(custom_kind, hits.items[0].kind);

    index.field_weights.kind = 1;
    try index.addDocument(.{
        .node_id = .fromInt(2),
        .kind = @enumFromInt(101),
        .text = "fallback label",
    });
    var kind_hits = try index.search("type 101", .{ .limit = 10 });
    defer kind_hits.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), kind_hits.items.len);
    try std.testing.expectEqual(@as(u16, 101), @intFromEnum(kind_hits.items[0].kind));
}

test "text index rejects reserved and duplicate document node ids" {
    var index = TextIndex.init(std.testing.allocator);
    defer index.deinit();

    try std.testing.expectError(core.Error.InvalidId, index.addDocument(.{
        .node_id = .none,
        .kind = .task,
        .text = "zero id",
    }));
    try std.testing.expectEqual(@as(usize, 0), index.docs.items.len);
    try std.testing.expectEqual(@as(usize, 0), index.doc_ids.count());
    try std.testing.expectError(core.Error.InvalidId, index.addDocument(.{
        .node_id = .fromInt(std.math.maxInt(u64)),
        .kind = .task,
        .text = "max id",
    }));
    try std.testing.expectEqual(@as(usize, 0), index.docs.items.len);
    try std.testing.expectEqual(@as(usize, 0), index.doc_ids.count());

    try index.addDocument(.{
        .node_id = .fromInt(1),
        .kind = .task,
        .text = "first task",
    });
    try std.testing.expect(index.doc_ids.contains(1));
    try std.testing.expectEqual(index.docs.items.len, index.doc_ids.count());
    try std.testing.expectError(core.Error.InvalidId, index.addDocument(.{
        .node_id = .fromInt(1),
        .kind = .task,
        .text = "duplicate task",
    }));

    try std.testing.expectEqual(@as(usize, 1), index.docs.items.len);
    try std.testing.expectEqual(index.docs.items.len, index.doc_ids.count());
    var hits = try index.search("duplicate", .{ .limit = 10 });
    defer hits.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), hits.items.len);
}

test "text index add document leaves no partial state on allocation failure" {
    var fail_offset: usize = 0;
    var saw_failure = false;
    while (fail_offset < 80) : (fail_offset += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        var index = TextIndex.init(failing.allocator());
        defer index.deinit();

        try index.addDocument(.{
            .node_id = .fromInt(1),
            .kind = .task,
            .text = "stableterm",
        });
        const baseline_alloc_index = failing.alloc_index;
        const baseline_total_doc_len = index.total_doc_len;
        const baseline_doc_count = index.docs.items.len;
        const baseline_doc_id_count = index.doc_ids.count();
        const baseline_stable_postings = index.postings_by_term.get("stableterm").?.items.len;

        failing.fail_index = baseline_alloc_index + fail_offset;
        const result = index.addDocument(.{
            .node_id = .fromInt(2),
            .kind = .task,
            .text = "rollbackterm",
        });
        if (result) |_| {
            continue;
        } else |err| switch (err) {
            error.OutOfMemory => {
                saw_failure = true;
                try std.testing.expectEqual(baseline_doc_count, index.docs.items.len);
                try std.testing.expectEqual(baseline_doc_id_count, index.doc_ids.count());
                try std.testing.expect(!index.doc_ids.contains(2));
                try std.testing.expectEqual(baseline_total_doc_len, index.total_doc_len);
                try std.testing.expect(index.postings_by_term.get("rollbackterm") == null);
                try std.testing.expectEqual(baseline_stable_postings, index.postings_by_term.get("stableterm").?.items.len);
            },
            else => return err,
        }
    }
    try std.testing.expect(saw_failure);
}

fn persistentTermBuilderAllocationFailure(allocator: std.mem.Allocator) !void {
    var builder = PersistentTermBuilder.init(allocator);
    defer builder.deinit();
    try builder.addDocument(1, "readEdgeIndexRecordsByNode 错误记录", "function");
}

test "persistent text term builder rolls back allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, persistentTermBuilderAllocationFailure, .{});
}

test "text builders commit many new terms without pending lookup" {
    var index = TextIndex.init(std.testing.allocator);
    defer index.deinit();
    try index.addDocument(.{
        .node_id = .fromInt(1),
        .kind = .document,
        .text = "alpha beta gamma delta epsilon zeta eta theta",
    });
    inline for (&[_][]const u8{ "alpha", "theta" }) |term| {
        try std.testing.expect(index.postings_by_term.get(term) != null);
    }

    var builder = PersistentTermBuilder.init(std.testing.allocator);
    defer builder.deinit();
    try builder.addDocument(1, "alpha beta gamma delta epsilon zeta eta theta", "document");
    inline for (&[_][]const u8{ "alpha", "theta" }) |term| {
        try std.testing.expect(builder.term_index.get(term) != null);
    }
}

test "persistent term builder add document leaves no partial state on allocation failure" {
    var fail_offset: usize = 0;
    var saw_failure = false;
    while (fail_offset < 80) : (fail_offset += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        var builder = PersistentTermBuilder.init(failing.allocator());
        defer builder.deinit();

        try builder.addDocument(1, "stableterm", "task");
        const baseline_alloc_index = failing.alloc_index;
        const baseline_term_count = builder.terms.items.len;
        const baseline_stable_idx = builder.term_index.get("stableterm").?;
        const baseline_stable_postings = builder.terms.items[baseline_stable_idx].postings.len;

        failing.fail_index = baseline_alloc_index + fail_offset;
        const result = builder.addDocument(2, "rollbackterm", "task");
        if (result) |_| {
            continue;
        } else |err| switch (err) {
            error.OutOfMemory => {
                saw_failure = true;
                try std.testing.expectEqual(baseline_term_count, builder.terms.items.len);
                try std.testing.expect(builder.term_index.get("rollbackterm") == null);
                const stable_idx = builder.term_index.get("stableterm").?;
                try std.testing.expectEqual(baseline_stable_postings, builder.terms.items[stable_idx].postings.len);
            },
            else => return err,
        }
    }
    try std.testing.expect(saw_failure);
}

test "persistent text offset helpers reject arithmetic overflow" {
    try std.testing.expectEqual(@as(usize, 88), PersistentTextMeta.encoded_len);
    try std.testing.expectEqual(@as(usize, 8), TextDocRecord.encoded_len);
    try std.testing.expectEqual(@as(usize, 1), TextTermEntry.encoded_len);
    try std.testing.expectEqual(@as(usize, 6), TextPostingRecord.encoded_len);
    try std.testing.expectEqual(@as(usize, 8), TextPostingBlockRecord.encoded_len);
    try std.testing.expectEqual(@as(usize, 6), TextTermTopHitRecord.encoded_len);
    try std.testing.expectEqual(@as(usize, 4), TextTermTopHitTermRecord.encoded_len);
    try std.testing.expectError(error.RecordTooLarge, textDocRecordOffset(std.math.maxInt(u64)));
    try std.testing.expectError(error.RecordTooLarge, textDocsFileSize(std.math.maxInt(u64), 0));
    try std.testing.expectError(error.InvalidRecord, textDocsFileSize(1, 2));
    try std.testing.expectError(error.RecordTooLarge, textTermEntryOffset(std.math.maxInt(u64)));
    try std.testing.expectError(error.RecordTooLarge, textTermsBytesOffset(std.math.maxInt(u64)));
    try std.testing.expectError(error.RecordTooLarge, textTermsFileSize(1, std.math.maxInt(u64), 0, 0));
    try std.testing.expectError(error.InvalidRecord, textTermsFileSize(1, 0, std.math.maxInt(u64), 0));
    try std.testing.expectError(error.RecordTooLarge, textTermsFileSize(1, 0, 0, std.math.maxInt(u64)));
    try std.testing.expectError(error.RecordTooLarge, textTermByteOffsetCheckpointTableOffset(1, @as(u64, std.math.maxInt(u32)) + 1));
    try std.testing.expectError(error.InvalidRecord, textTermByteOffsetCheckpointOffset(0, 0, 0));
    try std.testing.expectError(error.RecordTooLarge, textPostingRecordOffset(std.math.maxInt(u64)));
    try std.testing.expectError(error.RecordTooLarge, textPostingsFileSize(std.math.maxInt(u64)));
    var doc_record_bytes: [TextDocRecord.encoded_len]u8 = undefined;
    const max_doc_record = TextDocRecord{
        .doc_id = std.math.maxInt(u64) - 1,
        .node_id = persistent_doc_node_id_inline_max,
        .kind = @intFromEnum(core.NodeKind.file),
        .text_tokens = std.math.maxInt(u16),
    };
    try max_doc_record.encode(&doc_record_bytes);
    const decoded_max_doc_record = try TextDocRecord.decode(&doc_record_bytes, max_doc_record.doc_id);
    try std.testing.expectEqual(max_doc_record.doc_id, decoded_max_doc_record.doc_id);
    try std.testing.expectEqual(max_doc_record.node_id, decoded_max_doc_record.node_id);
    try std.testing.expectEqual(max_doc_record.kind, decoded_max_doc_record.kind);
    try std.testing.expectEqual(max_doc_record.text_tokens, decoded_max_doc_record.text_tokens);
    try std.testing.expectError(error.InvalidRecord, TextDocRecord.decode(&doc_record_bytes, 0));
    try std.testing.expectError(error.InvalidRecord, TextDocRecord.decode(&doc_record_bytes, std.math.maxInt(u64)));
    try std.testing.expectError(error.InvalidRecord, (TextDocRecord{ .doc_id = 0, .node_id = 1, .kind = @intFromEnum(core.NodeKind.file), .text_tokens = 1 }).encode(&doc_record_bytes));
    const overflow_doc_record = TextDocRecord{
        .doc_id = 7,
        .node_id = @as(u64, persistent_doc_node_id_overflow_marker) + 11,
        .kind = @intFromEnum(core.NodeKind.file),
        .text_tokens = 3,
    };
    try overflow_doc_record.encode(&doc_record_bytes);
    try std.testing.expectError(error.InvalidRecord, TextDocRecord.decode(&doc_record_bytes, overflow_doc_record.doc_id));
    const decoded_overflow = try TextDocRecord.decodeWithOverflow(&doc_record_bytes, overflow_doc_record.doc_id, overflow_doc_record.node_id);
    try std.testing.expectEqual(overflow_doc_record.node_id, decoded_overflow.node_id);
    try std.testing.expectError(error.InvalidRecord, (TextDocRecord{ .doc_id = 1, .node_id = 0, .kind = @intFromEnum(core.NodeKind.file), .text_tokens = 1 }).encode(&doc_record_bytes));
    try std.testing.expectError(error.RecordTooLarge, (TextDocRecord{ .doc_id = 1, .node_id = 1, .kind = @intFromEnum(core.NodeKind.file), .text_tokens = @as(u32, std.math.maxInt(u16)) + 1 }).encode(&doc_record_bytes));
    try std.testing.expectEqual(@as(u64, 64), try persistentBlockPostingCount(100, 0, 64));
    try std.testing.expectEqual(@as(u64, 36), try persistentBlockPostingCount(100, 1, 64));
    try std.testing.expectError(error.InvalidRecord, persistentBlockPostingCount(100, 0, 0));
    try std.testing.expectError(error.InvalidRecord, persistentBlockPostingCount(64, 1, 64));
    try std.testing.expectError(error.RecordTooLarge, persistentBlockPostingCount(std.math.maxInt(u64), std.math.maxInt(u64), 2));
    var posting_bytes: [TextPostingRecord.encoded_len]u8 = undefined;
    try encodeTextPostingRecord(.{ .doc_id = persistent_posting_max_doc_id, .text_freq = persistent_posting_max_field_freq, .kind_freq = 0 }, &posting_bytes);
    try encodeTextPostingRecord(.{ .doc_id = persistent_posting_max_doc_id, .text_freq = 1, .kind_freq = persistent_posting_max_kind_freq }, &posting_bytes);
    const max_posting = TextPostingRecord{ .doc_id = persistent_posting_max_doc_id, .text_freq = persistent_posting_max_field_freq, .kind_freq = persistent_posting_max_kind_freq };
    try encodeTextPostingRecord(max_posting, &posting_bytes);
    const decoded_max_posting = try decodeTextPostingRecord(&posting_bytes);
    try std.testing.expectEqual(max_posting.doc_id, decoded_max_posting.doc_id);
    try std.testing.expectEqual(max_posting.text_freq, decoded_max_posting.text_freq);
    try std.testing.expectEqual(max_posting.kind_freq, decoded_max_posting.kind_freq);
    try std.testing.expectError(error.RecordTooLarge, encodeTextPostingRecord(.{ .doc_id = persistent_posting_max_doc_id + 1, .text_freq = 1, .kind_freq = 0 }, &posting_bytes));
    try std.testing.expectError(error.RecordTooLarge, encodeTextPostingRecord(.{ .doc_id = 1, .text_freq = persistent_posting_max_field_freq + 1, .kind_freq = 0 }, &posting_bytes));
    try std.testing.expectError(error.RecordTooLarge, encodeTextPostingRecord(.{ .doc_id = 1, .text_freq = 0, .kind_freq = persistent_posting_max_kind_freq + 1 }, &posting_bytes));
    var term_entry_bytes: [TextTermEntry.encoded_len]u8 = undefined;
    const max_term_entry_payload = try encodeInlineSingletonPostingPayload(.{ .doc_id = persistent_inline_posting_max_doc_id, .text_freq = 3, .kind_freq = 0 });
    const max_term_entry = TextTermEntry{
        .term_len = default_max_token_bytes,
        .doc_freq = 1,
        .postings_offset = max_term_entry_payload,
        .postings_count = 1,
    };
    try encodeTextTermEntry(max_term_entry, &term_entry_bytes);
    const decoded_max_term_entry = try decodeTextTermEntry(&term_entry_bytes);
    try std.testing.expectEqual(max_term_entry.term_len, decoded_max_term_entry.term_len);
    try std.testing.expectEqual(@as(u32, 0), decoded_max_term_entry.doc_freq);
    try std.testing.expectEqual(@as(u64, 0), decoded_max_term_entry.postings_offset);
    try std.testing.expectEqual(@as(u64, 0), decoded_max_term_entry.postings_count);
    const packed_front_prefix_entry = TextTermEntry{
        .term_len = 10,
        .doc_freq = 1,
        .postings_offset = max_term_entry_payload,
        .postings_count = 1,
        .front_prefix_len = 3,
    };
    try encodeTextTermEntry(packed_front_prefix_entry, &term_entry_bytes);
    const decoded_packed_front_prefix = try decodeTextTermEntry(&term_entry_bytes);
    try std.testing.expectEqual(@as(u32, 10), decoded_packed_front_prefix.term_len);
    try std.testing.expectEqual(@as(u8, 3), decoded_packed_front_prefix.front_prefix_len.?);
    const exception_marker_entry = TextTermEntry{
        .term_len = default_max_token_bytes,
        .doc_freq = 2,
        .postings_offset = persistent_postings_body_max_offset,
        .postings_count = 2,
    };
    try encodeTextTermEntry(exception_marker_entry, &term_entry_bytes);
    const decoded_exception_marker = try decodeTextTermEntry(&term_entry_bytes);
    try std.testing.expectEqual(@as(u32, 0), decoded_exception_marker.doc_freq);
    try std.testing.expectEqual(@as(u64, 0), decoded_exception_marker.postings_count);
    var exception_record_bytes: [TextTermExceptionRecord.encoded_len]u8 = undefined;
    const exception_record = TextTermExceptionRecord{ .doc_freq = @intCast(persistent_term_max_doc_freq), .postings_offset = persistent_postings_body_max_offset };
    try encodeTextTermExceptionRecord(exception_record, &exception_record_bytes);
    const decoded_exception_record = try decodeTextTermExceptionRecord(&exception_record_bytes);
    try std.testing.expectEqual(exception_record.doc_freq, decoded_exception_record.doc_freq);
    try std.testing.expectEqual(exception_record.postings_offset, decoded_exception_record.postings_offset);
    const non_inline_singleton_exception = TextTermExceptionRecord{ .doc_freq = 1, .postings_offset = 0 };
    try encodeTextTermExceptionRecord(non_inline_singleton_exception, &exception_record_bytes);
    const inline_singleton_exception = TextTermExceptionRecord{ .doc_freq = 1, .postings_offset = max_term_entry_payload };
    try std.testing.expectError(error.InvalidRecord, encodeTextTermExceptionRecord(inline_singleton_exception, &exception_record_bytes));
    try std.testing.expectError(error.RecordTooLarge, encodeTextTermEntry(.{ .term_len = persistent_term_max_len + 1, .doc_freq = 1, .postings_offset = 0, .postings_count = 1 }, &term_entry_bytes));
    var block_record_bytes: [TextPostingBlockRecord.encoded_len]u8 = undefined;
    const max_block_record = TextPostingBlockRecord{ .max_weighted_tf = 1, .min_doc_len = 1, .last_doc_id = persistent_posting_max_doc_id };
    try encodeTextPostingBlockRecord(max_block_record, &block_record_bytes);
    const decoded_max_block_record = try decodeTextPostingBlockRecord(&block_record_bytes);
    try std.testing.expect(textPostingBlockRecordConservativelyMatches(decoded_max_block_record, max_block_record));
    const quantized_block_record = TextPostingBlockRecord{ .max_weighted_tf = 1.1, .min_doc_len = 9.9, .last_doc_id = 42 };
    try encodeTextPostingBlockRecord(quantized_block_record, &block_record_bytes);
    const decoded_quantized_block_record = try decodeTextPostingBlockRecord(&block_record_bytes);
    try std.testing.expect(textPostingBlockRecordConservativelyMatches(decoded_quantized_block_record, quantized_block_record));
    try std.testing.expect(decoded_quantized_block_record.max_weighted_tf >= quantized_block_record.max_weighted_tf);
    try std.testing.expect(decoded_quantized_block_record.min_doc_len <= quantized_block_record.min_doc_len);
    try std.testing.expectEqual(quantized_block_record.last_doc_id, decoded_quantized_block_record.last_doc_id);
    try std.testing.expectError(error.RecordTooLarge, encodeTextPostingBlockRecord(.{ .max_weighted_tf = persistent_block_score_f16_max * 2.0, .min_doc_len = 1, .last_doc_id = 1 }, &block_record_bytes));
    try std.testing.expectError(error.RecordTooLarge, encodeTextPostingBlockRecord(.{ .max_weighted_tf = 1, .min_doc_len = 1, .last_doc_id = 0 }, &block_record_bytes));
    var top_hit_bytes: [TextTermTopHitRecord.encoded_len]u8 = undefined;
    const max_top_hit = TextTermTopHitRecord{ .doc_id = persistent_posting_max_doc_id, .text_freq = persistent_posting_max_field_freq, .node_id = std.math.maxInt(u64) - 1, .score = 1.5 };
    try encodeTextTermTopHitRecord(max_top_hit, &top_hit_bytes);
    const decoded_top_hit = try decodeTextTermTopHitRecord(&top_hit_bytes);
    try std.testing.expectEqual(max_top_hit.doc_id, decoded_top_hit.doc_id);
    try std.testing.expectEqual(max_top_hit.text_freq, decoded_top_hit.text_freq);
    try std.testing.expectEqual(@as(u64, 0), decoded_top_hit.node_id);
    try std.testing.expectEqual(@as(f32, 0), decoded_top_hit.score);
    try std.testing.expectError(error.RecordTooLarge, encodeTextTermTopHitRecord(.{ .doc_id = persistent_posting_max_doc_id + 1, .text_freq = 1, .score = 1 }, &top_hit_bytes));
    try std.testing.expectError(error.InvalidRecord, encodeTextTermTopHitRecord(.{ .doc_id = 1, .text_freq = 0, .score = 1 }, &top_hit_bytes));
    try std.testing.expectError(error.RecordTooLarge, encodeTextTermTopHitRecord(.{ .doc_id = 1, .text_freq = persistent_posting_max_field_freq + 1, .score = 1 }, &top_hit_bytes));
    try std.testing.expectError(error.InvalidRecord, encodeTextTermTopHitRecord(.{ .doc_id = 1, .text_freq = 1, .node_id = std.math.maxInt(u64), .score = 1 }, &top_hit_bytes));
    try std.testing.expectError(error.InvalidRecord, encodeTextTermTopHitRecord(.{ .doc_id = 1, .text_freq = 1, .score = std.math.nan(f32) }, &top_hit_bytes));
    var top_hit_term_bytes: [TextTermTopHitTermRecord.encoded_len]u8 = undefined;
    const max_top_hit_term = TextTermTopHitTermRecord{ .term_index = std.math.maxInt(u32), .hit_offset = 0, .hit_count = persistent_term_top_hit_capacity };
    try encodeTextTermTopHitTermRecord(max_top_hit_term, &top_hit_term_bytes);
    const decoded_top_hit_term = try decodeTextTermTopHitTermRecord(&top_hit_term_bytes, 7, persistent_term_top_hit_capacity);
    try std.testing.expectEqual(max_top_hit_term.term_index, decoded_top_hit_term.term_index);
    try std.testing.expectEqual(@as(u64, 7 * persistent_term_top_hit_capacity), decoded_top_hit_term.hit_offset);
    try std.testing.expectEqual(max_top_hit_term.hit_count, decoded_top_hit_term.hit_count);
    try std.testing.expectError(error.RecordTooLarge, encodeTextTermTopHitTermRecord(.{ .term_index = @as(u64, std.math.maxInt(u32)) + 1, .hit_offset = 0, .hit_count = 1 }, &top_hit_term_bytes));
    try std.testing.expectError(error.InvalidRecord, encodeTextTermTopHitTermRecord(.{ .term_index = 0, .hit_offset = 0, .hit_count = 0 }, &top_hit_term_bytes));
    try std.testing.expectError(error.InvalidRecord, decodeTextTermTopHitTermRecord(&top_hit_term_bytes, 0, 0));
}

test "persistent text terms byte stats split physical lanes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "text_terms.idx" });
    defer std.testing.allocator.free(path);

    const header = TextTermsHeader{
        .term_count = 257,
        .term_bytes = 1000,
        .term_exception_count = 17,
        .singleton_payload_bytes = 333,
    };
    const size = try textTermsFileSizeForHeader(header);
    var bytes = try std.testing.allocator.alloc(u8, std.math.cast(usize, size) orelse return error.RecordTooLarge);
    defer std.testing.allocator.free(bytes);
    @memset(bytes, 0);
    encodeTextTermsHeader(header, bytes[0..TextTermsHeader.encoded_len]);
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "text_terms.idx",
        .data = bytes,
        .flags = .{ .truncate = true },
    });

    const stats = try readPersistentTextTermsByteStatsAtPath(std.testing.io, path);
    try std.testing.expectEqual(size, stats.total_bytes);
    try std.testing.expectEqual(@as(u64, TextTermsHeader.encoded_len), stats.header_bytes);
    try std.testing.expectEqual(@as(u64, 257), stats.entry_bytes);
    try std.testing.expectEqual(@as(u64, 1000), stats.front_coded_bytes);
    try std.testing.expectEqual(@as(u64, 3), stats.offset_checkpoint_count);
    try std.testing.expectEqual(@as(u64, 12), stats.offset_checkpoint_bytes);
    try std.testing.expectEqual(@as(u64, 245), stats.exception_bytes);
    try std.testing.expectEqual(@as(u64, 240), stats.singleton_count);
    try std.testing.expectEqual(@as(u64, 2), stats.singleton_checkpoint_count);
    try std.testing.expectEqual(@as(u64, 16), stats.singleton_checkpoint_bytes);
    try std.testing.expectEqual(@as(u64, 333), stats.singleton_payload_bytes);
    try std.testing.expectEqual(@as(u64, 257), stats.term_count);
    try std.testing.expectEqual(@as(u64, 17), stats.exception_count);
}

test "persistent text term exception sidecar resolves non-singleton payload" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage_mod.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    const terms_path = try std.fs.path.join(std.testing.allocator, &.{ store_path, "text_terms.idx" });
    defer std.testing.allocator.free(terms_path);
    const header = TextTermsHeader{
        .term_count = 1,
        .term_bytes = 4,
        .term_exception_count = 1,
    };

    {
        var file = try std.Io.Dir.cwd().createFile(std.testing.io, terms_path, .{ .read = true, .truncate = true });
        defer file.close(std.testing.io);

        var header_bytes: [TextTermsHeader.encoded_len]u8 = undefined;
        encodeTextTermsHeader(header, &header_bytes);
        try file.writePositionalAll(std.testing.io, &header_bytes, 0);

        var entry_bytes: [TextTermEntry.encoded_len]u8 = undefined;
        try encodeTextTermEntry(.{
            .term_len = 3,
            .doc_freq = 70_000,
            .postings_offset = 0,
            .postings_count = 70_000,
        }, &entry_bytes);
        try file.writePositionalAll(std.testing.io, &entry_bytes, try textTermEntryOffset(0));

        const term_bytes = [_]u8{ 0, 'h', 'o', 't' };
        try file.writePositionalAll(std.testing.io, &term_bytes, try textTermsBytesOffset(1));
        var checkpoint_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &checkpoint_bytes, 0, .little);
        try file.writePositionalAll(std.testing.io, &checkpoint_bytes, try textTermByteOffsetCheckpointOffset(1, 4, 0));
        try file.writePositionalAll(std.testing.io, &checkpoint_bytes, try textTermExceptionRankCheckpointOffset(1, 4, 0));

        const membership_byte = [_]u8{1};
        try file.writePositionalAll(std.testing.io, &membership_byte, try textTermExceptionMembershipByteOffset(1, 4, 0));

        var exception_bytes: [TextTermExceptionRecord.encoded_len]u8 = undefined;
        try encodeTextTermExceptionRecord(.{ .doc_freq = 70_000, .postings_offset = 0 }, &exception_bytes);
        try file.writePositionalAll(std.testing.io, &exception_bytes, try textTermExceptionRecordOffset(1, 4, 0));
    }

    {
        var file = try std.Io.Dir.cwd().openFile(std.testing.io, terms_path, .{ .mode = .read_write });
        defer file.close(std.testing.io);
        const resolved = try readTextTermEntryAt(store, file, header, 0);
        try std.testing.expectEqual(@as(u32, 70_000), resolved.doc_freq);
        try std.testing.expectEqual(@as(u64, 70_000), resolved.postings_count);
        try std.testing.expect(!try textTermExceptionTableInvalid(store, file, header));
        {
            var view = try TextTermsFileView.open(store, terms_path);
            defer view.deinit();
            const read_header = try view.readHeader();
            try std.testing.expectEqual(header.term_exception_count, read_header.term_exception_count);
            const view_resolved = try view.readEntryAt(read_header, 0);
            try std.testing.expectEqual(@as(u32, 70_000), view_resolved.doc_freq);
        }

        const corrupt_membership_byte = [_]u8{0};
        try file.writePositionalAll(std.testing.io, &corrupt_membership_byte, try textTermExceptionMembershipByteOffset(1, 4, 0));
        try std.testing.expect(try textTermExceptionTableInvalid(store, file, header));
    }
}

test "persistent text doc token lanes cover long agent text outliers" {
    var text = std.ArrayList(u8).empty;
    defer text.deinit(std.testing.allocator);
    while (text.items.len < 8192) {
        try text.appendSlice(std.testing.allocator, "InvalidRecord src/text.zig command output observation decision repair benchmark ");
    }

    const token_count = try countTokens(std.testing.allocator, text.items, .{});
    try std.testing.expect(token_count > 1000);
    try std.testing.expect(token_count < persistent_doc_max_field_tokens);

    var bytes: [TextDocRecord.encoded_len]u8 = undefined;
    const record = TextDocRecord{
        .doc_id = 1,
        .node_id = 1,
        .kind = @intFromEnum(core.NodeKind.observation),
        .text_tokens = @intCast(token_count),
    };
    try record.encode(&bytes);
    const decoded = try TextDocRecord.decode(&bytes, record.doc_id);
    try std.testing.expectEqual(record.text_tokens, decoded.text_tokens);
}

test "persistent text doc rank entry stays compact and preserves ranking order" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(TextDocRankEntry));

    var entries = [_]TextDocRankEntry{
        try TextDocRankEntry.init(.{
            .doc_id = 1,
            .node_id = 40,
            .kind = @intFromEnum(core.NodeKind.file),
            .text_tokens = 7,
        }),
        try TextDocRankEntry.init(.{
            .doc_id = 2,
            .node_id = 20,
            .kind = @intFromEnum(core.NodeKind.file),
            .text_tokens = 7,
        }),
        try TextDocRankEntry.init(.{
            .doc_id = 3,
            .node_id = 10,
            .kind = @intFromEnum(core.NodeKind.file),
            .text_tokens = 3,
        }),
    };

    const lessThan = struct {
        fn call(_: void, lhs: TextDocRankEntry, rhs: TextDocRankEntry) bool {
            const lhs_len = lhs.docLen();
            const rhs_len = rhs.docLen();
            if (lhs_len != rhs_len) return lhs_len < rhs_len;
            return lhs.node_id < rhs.node_id;
        }
    }.call;
    std.mem.sort(TextDocRankEntry, &entries, {}, lessThan);

    try std.testing.expectEqual(@as(u32, 3), entries[0].doc_id);
    try std.testing.expectEqual(@as(u32, 2), entries[1].doc_id);
    try std.testing.expectEqual(@as(u32, 1), entries[2].doc_id);
    try std.testing.expectEqual(@as(u64, 20), entries[1].node_id);
}

test "persistent text docs store high node ids in overflow sidecar" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);
    const docs_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "text_docs.idx" });
    defer std.testing.allocator.free(docs_path);

    var store = try storage_mod.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();
    const high_node_id = @as(u64, persistent_doc_node_id_overflow_marker) + 17;

    {
        var docs_file = try std.Io.Dir.cwd().createFile(std.testing.io, docs_path, .{ .read = true, .truncate = true });
        defer docs_file.close(std.testing.io);
        var header_bytes: [TextDocsHeader.encoded_len]u8 = undefined;
        (TextDocsHeader{ .doc_count = 1, .node_id_overflow_count = 1 }).encode(&header_bytes);
        try docs_file.writePositionalAll(std.testing.io, &header_bytes, 0);
        var doc_bytes: [TextDocRecord.encoded_len]u8 = undefined;
        try (TextDocRecord{
            .doc_id = 1,
            .node_id = high_node_id,
            .kind = @intFromEnum(core.NodeKind.observation),
            .text_tokens = 4,
        }).encode(&doc_bytes);
        try docs_file.writePositionalAll(std.testing.io, &doc_bytes, try textDocRecordOffset(0));
        var overflow_bytes: [TextDocNodeIdOverflowRecord.encoded_len]u8 = undefined;
        try (TextDocNodeIdOverflowRecord{ .doc_id = 1, .node_id = high_node_id }).encode(&overflow_bytes);
        try docs_file.writePositionalAll(std.testing.io, &overflow_bytes, try textDocNodeIdOverflowRecordOffset(1, 0));
    }

    {
        var view = try TextDocsFileView.open(store, docs_path);
        defer view.deinit();
        try std.testing.expectEqual(try textDocsFileSize(1, 1), view.size);
        const doc = try view.readDocAt(0);
        try std.testing.expectEqual(high_node_id, doc.node_id);
        try std.testing.expectError(error.InvalidRecord, view.readDocAt(1));
    }

    var docs_file = try std.Io.Dir.cwd().openFile(std.testing.io, docs_path, .{ .mode = .read_write });
    defer docs_file.close(std.testing.io);
    var overflow_bytes: [TextDocNodeIdOverflowRecord.encoded_len]u8 = undefined;
    try (TextDocNodeIdOverflowRecord{ .doc_id = 2, .node_id = high_node_id }).encode(&overflow_bytes);
    try docs_file.writePositionalAll(std.testing.io, &overflow_bytes, try textDocNodeIdOverflowRecordOffset(1, 0));
    try docs_file.sync(std.testing.io);
    var corrupt_view = try TextDocsFileView.open(store, docs_path);
    defer corrupt_view.deinit();
    try std.testing.expectError(error.InvalidRecord, corrupt_view.readDocAt(0));
}

test "persistent text terms store front-coded term bytes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var text = std.ArrayList(u8).empty;
    defer text.deinit(std.testing.allocator);
    var index: usize = 0;
    while (index < 64) : (index += 1) {
        if (index != 0) try text.append(std.testing.allocator, ' ');
        var term_buf: [32]u8 = undefined;
        const term = try std.fmt.bufPrint(&term_buf, "frontcodedensityterm{d:0>3}", .{index});
        try text.appendSlice(std.testing.allocator, term);
    }

    var store = try storage_mod.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();
    try store.appendNode(.{ .id = .fromInt(1), .kind = .task, .text = text.items });
    _ = try rebuildPersistentTextCatalog(std.testing.allocator, store);

    const terms_path = try textTermsPath(std.testing.allocator, store);
    defer std.testing.allocator.free(terms_path);
    var terms_view = try TextTermsFileView.open(store, terms_path);
    defer terms_view.deinit();

    const header = try terms_view.readHeader();
    var raw_term_bytes: u64 = 0;
    var found_prefixed_terms: u64 = 0;
    var pos: u64 = 0;
    while (pos < header.term_count) : (pos += 1) {
        const entry = try terms_view.readEntryAt(header, pos);
        raw_term_bytes += entry.term_len;
        var buf: [default_max_token_bytes]u8 = undefined;
        const term = try terms_view.termEntryBytesAt(header, pos, entry, &buf);
        if (std.mem.startsWith(u8, term, "frontcodedensityterm")) found_prefixed_terms += 1;
    }
    try std.testing.expect(found_prefixed_terms >= 64);
    try std.testing.expect(header.term_bytes < raw_term_bytes);
}

test "persistent text block-derived file layouts keep records first" {
    var ordinal_bytes: [persistent_posting_block_ordinal_len]u8 = undefined;
    try encodePersistentBlockOrdinal(0x00ab_cdef, &ordinal_bytes);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xef, 0xcd, 0xab, 0x00 }, &ordinal_bytes);
    try std.testing.expectEqual(@as(u64, 0x00ab_cdef), try decodePersistentBlockOrdinal(&ordinal_bytes));
    try encodePersistentBlockOrdinal(persistent_posting_max_block_ordinal, &ordinal_bytes);
    try std.testing.expectEqual(@as(u64, persistent_posting_max_block_ordinal), try decodePersistentBlockOrdinal(&ordinal_bytes));
    try std.testing.expectError(error.RecordTooLarge, encodePersistentBlockOrdinal(persistent_posting_max_block_ordinal + 1, &ordinal_bytes));

    try std.testing.expectEqual(@as(u64, TextPostingBlocksHeader.encoded_len), textPostingBlockRecordsOffset());
    try std.testing.expectEqual(@as(u64, 0), try textPostingBlockCheckpointCount(0));
    try std.testing.expectEqual(@as(u64, 1), try textPostingBlockCheckpointCount(1));
    try std.testing.expectEqual(@as(u64, 1), try textPostingBlockCheckpointCount(persistent_posting_block_offset_checkpoint_terms));
    try std.testing.expectEqual(@as(u64, 2), try textPostingBlockCheckpointCount(persistent_posting_block_offset_checkpoint_terms + 1));
    try std.testing.expectEqual(@as(u64, TextPostingBlocksHeader.encoded_len + 3 * TextPostingBlockRecord.encoded_len), try textPostingBlockCheckpointTableOffset(3));
    try std.testing.expectError(error.RecordTooLarge, textPostingBlockCheckpointTableOffset(persistent_posting_max_block_ordinal + 1));
    try std.testing.expectEqual(@as(u64, TextPostingBlocksHeader.encoded_len + 3 * TextPostingBlockRecord.encoded_len + 2 * persistent_posting_block_ordinal_len), try textPostingBlockCheckpointOffset(3, 2));
    try std.testing.expectEqual(@as(u64, TextPostingBlocksHeader.encoded_len + 1 * TextPostingBlockRecord.encoded_len), try textPostingBlockRecordOffset(9, 1));
    try std.testing.expectEqual(@as(u64, 0), try textPostingBlockByteOffsetCheckpointCount(0));
    try std.testing.expectEqual(@as(u64, 1), try textPostingBlockByteOffsetCheckpointCount(1));
    try std.testing.expectEqual(@as(u64, 1), try textPostingBlockByteOffsetCheckpointCount(persistent_posting_block_byte_offset_checkpoint_blocks));
    try std.testing.expectEqual(@as(u64, 2), try textPostingBlockByteOffsetCheckpointCount(persistent_posting_block_byte_offset_checkpoint_blocks + 1));
    try std.testing.expectEqual(
        @as(u64, TextPostingBlocksHeader.encoded_len + 3 * TextPostingBlockRecord.encoded_len + 1 * persistent_posting_block_ordinal_len),
        try textPostingBlockByteOffsetCheckpointTableOffset(4, 3),
    );
    try std.testing.expectEqual(
        @as(u64, TextPostingBlocksHeader.encoded_len + (persistent_posting_block_byte_offset_checkpoint_blocks + 1) * TextPostingBlockRecord.encoded_len + 1 * persistent_posting_block_ordinal_len + 1 * 4),
        try textPostingBlockByteOffsetCheckpointOffset(4, persistent_posting_block_byte_offset_checkpoint_blocks + 1, 1),
    );
    try std.testing.expectEqual(
        @as(u64, TextPostingBlocksHeader.encoded_len + 3 * TextPostingBlockRecord.encoded_len + 1 * persistent_posting_block_ordinal_len + try textPostingBlockByteOffsetCheckpointCount(4) * 4),
        try textPostingBlocksFileSize(4, 3),
    );
    try std.testing.expectError(error.RecordTooLarge, textPostingBlocksFileSize(1, persistent_posting_max_block_ordinal + 1));

    try std.testing.expectEqual(@as(u64, TextPostingBlockImpactsHeader.encoded_len), textPostingBlockImpactRecordsOffset());
    try std.testing.expectEqual(@as(u64, TextPostingBlockImpactsHeader.encoded_len + 1 * persistent_posting_block_ordinal_len), try textPostingBlockImpactRecordOffset(9, 1));
    try std.testing.expectEqual(
        @as(u64, TextPostingBlockImpactsHeader.encoded_len + 3 * persistent_posting_block_ordinal_len),
        try textPostingBlockImpactsFileSize(4, 3),
    );
    try std.testing.expectError(error.RecordTooLarge, textPostingBlockImpactsFileSize(1, persistent_posting_max_block_ordinal + 1));

    try std.testing.expectEqual(@as(u64, TextTermTopHitsHeader.encoded_len), textTermTopHitRecordsOffset());
    try std.testing.expectEqual(@as(u64, TextTermTopHitsHeader.encoded_len), try textTermTopHitTermIndexOffset(0));
    try std.testing.expectEqual(@as(u64, TextTermTopHitsHeader.encoded_len + 3 * TextTermTopHitRecord.encoded_len), try textTermTopHitTermIndexOffset(3));
    try std.testing.expectEqual(@as(u64, TextTermTopHitsHeader.encoded_len + 3 * TextTermTopHitRecord.encoded_len + 2 * TextTermTopHitTermRecord.encoded_len), try textTermTopHitTermRecordOffset(3, 2));
    try std.testing.expectEqual(@as(u64, TextTermTopHitsHeader.encoded_len + TextTermTopHitRecord.encoded_len), try textTermTopHitRecordOffset(1));
    try std.testing.expectEqual(
        @as(u64, TextTermTopHitsHeader.encoded_len + 3 * TextTermTopHitRecord.encoded_len + 4 * TextTermTopHitTermRecord.encoded_len),
        try textTermTopHitsFileSize(3, 4),
    );
}

test "persistent text production checkpoint constants stay priced" {
    try std.testing.expectEqual(@as(u64, 128), production_persistent_posting_block_offset_checkpoint_terms);
    try std.testing.expectEqual(@as(u64, 8), production_persistent_posting_block_byte_offset_checkpoint_blocks);
    try std.testing.expect(persistent_posting_block_offset_checkpoint_terms <= production_persistent_posting_block_offset_checkpoint_terms);
    try std.testing.expect(persistent_posting_block_byte_offset_checkpoint_blocks <= production_persistent_posting_block_byte_offset_checkpoint_blocks);
}

test "compressed text postings use two-bit text frequency tags" {
    try std.testing.expectEqual(@as(u6, 2), compressed_posting_field_tag_bits);
    try std.testing.expectEqual(@as(u64, 3), compressed_posting_field_tag_mask);
    try std.testing.expectEqual(@as(u8, 3), compressed_posting_tag_text_explicit);

    const cases = [_]TextPostingRecord{
        .{ .doc_id = 7, .text_freq = 1, .kind_freq = 0 },
        .{ .doc_id = 9, .text_freq = 2, .kind_freq = 0 },
        .{ .doc_id = 11, .text_freq = 3, .kind_freq = 0 },
        .{ .doc_id = 12, .text_freq = 4, .kind_freq = 0 },
        .{ .doc_id = 18, .text_freq = 5, .kind_freq = 0 },
        .{ .doc_id = 21, .text_freq = 6, .kind_freq = 0 },
        .{ .doc_id = 27, .text_freq = 7, .kind_freq = 0 },
        .{ .doc_id = 30, .text_freq = 8, .kind_freq = 0 },
    };
    var previous_doc_id: u64 = 0;
    for (cases) |posting| {
        var bytes: [compressed_posting_max_encoded_len]u8 = undefined;
        const encoded_len = try encodeCompressedTextPosting(posting, previous_doc_id, &bytes);
        const field_tag = try compressedPostingFieldTag(posting);
        var expected_len = persistentVarintLen(try taggedCompressedPostingDelta(posting.doc_id - previous_doc_id, posting));
        if (compressedPostingTagTextExplicit(field_tag)) expected_len += persistentVarintLen(posting.text_freq);
        try std.testing.expectEqual(expected_len, encoded_len);

        var cursor: usize = 0;
        const decoded = try decodeCompressedTextPostingFromBytes(bytes[0..encoded_len], &cursor, previous_doc_id);
        try std.testing.expectEqual(encoded_len, cursor);
        try std.testing.expectEqual(posting.doc_id, decoded.doc_id);
        try std.testing.expectEqual(posting.text_freq, decoded.text_freq);
        try std.testing.expectEqual(posting.kind_freq, decoded.kind_freq);
        previous_doc_id = posting.doc_id;
    }

    var noncanonical: [compressed_posting_max_encoded_len]u8 = undefined;
    var cursor: usize = 0;
    cursor += try encodePersistentVarint((@as(u64, 1) << compressed_posting_field_tag_bits) | compressed_posting_tag_text_explicit, noncanonical[cursor..]);
    cursor += try encodePersistentVarint(3, noncanonical[cursor..]);
    var read_cursor: usize = 0;
    try std.testing.expectError(error.InvalidRecord, decodeCompressedTextPostingFromBytes(noncanonical[0..cursor], &read_cursor, 0));
    try std.testing.expectError(error.RecordTooLarge, encodeCompressedTextPosting(.{ .doc_id = 31, .text_freq = 0, .kind_freq = 2 }, previous_doc_id, &noncanonical));

    try std.testing.expect(canInlineSingletonPosting(.{ .doc_id = 31, .text_freq = 3, .kind_freq = 0 }));
    try std.testing.expect(!canInlineSingletonPosting(.{ .doc_id = 31, .text_freq = 4, .kind_freq = 0 }));
}

test "persistent virtual all-doc postings require strict contiguous constant text frequency" {
    var postings: [persistent_term_top_hit_min_postings]TextPostingRecord = undefined;
    for (&postings, 0..) |*posting, index| {
        posting.* = .{ .doc_id = @intCast(index + 1), .text_freq = 2, .kind_freq = 0 };
    }
    try std.testing.expectEqual(@as(?u32, 2), virtualAllDocsConstantTextFreq(&postings, persistent_term_top_hit_min_postings));

    postings[17].text_freq = 3;
    try std.testing.expectEqual(@as(?u32, null), virtualAllDocsConstantTextFreq(&postings, persistent_term_top_hit_min_postings));
    postings[17].text_freq = 2;

    postings[23].kind_freq = 1;
    try std.testing.expectEqual(@as(?u32, null), virtualAllDocsConstantTextFreq(&postings, persistent_term_top_hit_min_postings));
    postings[23].kind_freq = 0;

    postings[31].doc_id += 1;
    try std.testing.expectEqual(@as(?u32, null), virtualAllDocsConstantTextFreq(&postings, persistent_term_top_hit_min_postings));
    postings[31].doc_id -= 1;

    try std.testing.expectEqual(@as(?u32, null), virtualAllDocsConstantTextFreq(postings[0 .. persistent_term_top_hit_min_postings - 1], persistent_term_top_hit_min_postings - 1));
}

test "persistent posting compression estimate scans stored postings" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage_mod.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();
    try store.appendNode(.{ .id = .fromInt(1), .kind = .task, .text = "alpha common common" });
    try store.appendNode(.{ .id = .fromInt(2), .kind = .task, .text = "beta common" });
    _ = try rebuildPersistentTextCatalog(std.testing.allocator, store);

    const estimate = try estimatePersistentPostingCompression(std.testing.allocator, store);
    const postings_path = try textPostingsPath(std.testing.allocator, store);
    defer std.testing.allocator.free(postings_path);
    var postings_file = try std.Io.Dir.cwd().openFile(std.testing.io, postings_path, .{});
    defer postings_file.close(std.testing.io);
    const postings_header = try readTextPostingsHeaderFromFile(store, postings_file);

    try std.testing.expect(estimate.posting_count > 0);
    try std.testing.expectEqual(estimate.posting_count * TextPostingRecord.encoded_len, estimate.fixed_record_bytes);
    try std.testing.expect(estimate.singleton_inline_posting_count > 0);
    try std.testing.expect(estimate.singleton_inline_saved_bytes > 0);
    try std.testing.expectEqual(postings_header.body_bytes + estimate.singleton_inline_saved_bytes, estimate.delta_varint_estimated_bytes);
    try std.testing.expect(estimate.delta_varint_estimated_bytes < estimate.fixed_record_bytes);
    try std.testing.expect(estimate.elias_fano_doc_estimated_bytes > 0);
    try std.testing.expect(estimate.hybrid_doc_estimated_bytes > 0);
    try std.testing.expect(estimate.hybrid_doc_estimated_bytes <= estimate.delta_varint_doc_bytes);
    try std.testing.expect(estimate.material_field_tag_bits_estimated_bytes > 0);
    try std.testing.expect(estimate.material_hybrid_format_bits_bytes > 0);
    try std.testing.expect(estimate.material_elias_fano_select_checkpoint_bytes > 0);
    try std.testing.expect(estimate.material_hybrid_select_checkpoint_bytes <= estimate.material_elias_fano_select_checkpoint_bytes);
    try std.testing.expect(estimate.hybrid_select_aware_doc_with_select_estimated_bytes > 0);
    try std.testing.expect(estimate.hybrid_select_aware_ef_term_count + estimate.hybrid_select_aware_delta_term_count > 0);
    try std.testing.expect(estimate.elias_fano_material_estimated_bytes > estimate.elias_fano_doc_estimated_bytes);
    try std.testing.expect(estimate.hybrid_material_estimated_bytes > estimate.hybrid_doc_estimated_bytes);
    try std.testing.expectEqual(
        estimate.elias_fano_material_estimated_bytes + estimate.material_elias_fano_select_checkpoint_bytes,
        estimate.elias_fano_material_with_select_estimated_bytes,
    );
    try std.testing.expectEqual(
        estimate.hybrid_material_estimated_bytes + estimate.material_hybrid_select_checkpoint_bytes,
        estimate.hybrid_material_with_select_estimated_bytes,
    );
    try std.testing.expectEqual(
        estimate.hybrid_select_aware_doc_with_select_estimated_bytes +
            estimate.material_field_tag_bits_estimated_bytes +
            estimate.delta_varint_text_freq_bytes +
            estimate.delta_varint_kind_freq_bytes +
            estimate.material_block_jump_checkpoint_bytes +
            estimate.material_hybrid_format_bits_bytes,
        estimate.hybrid_select_aware_material_estimated_bytes,
    );
    try std.testing.expect(estimate.elias_fano_better_term_count + estimate.elias_fano_worse_term_count <= estimate.posting_count);
    try std.testing.expectEqual(@as(u64, 0), estimate.delta_varint_text_freq_bytes);
    try std.testing.expectEqual(@as(u64, 0), estimate.delta_varint_kind_freq_bytes);
    try std.testing.expectEqual(@as(u32, 2), estimate.max_text_freq);
    try std.testing.expectEqual(@as(u32, 0), estimate.max_kind_freq);
    try std.testing.expectEqual(@as(u64, 0), estimate.doc_delta_over_u16_count);
    try std.testing.expectEqual(@as(u64, 0), estimate.text_freq_over_u8_count);
}

test "persistent Elias-Fano doc layout prices select checkpoints" {
    const dense = try persistentEliasFanoDocLayout(128, 128);
    try std.testing.expectEqual(@as(u6, 0), dense.lower_bits);
    try std.testing.expectEqual(@as(u64, 0), dense.lower_bytes);
    try std.testing.expect(dense.upper_bytes > 0);
    try std.testing.expectEqual(dense.doc_bytes, try persistentEliasFanoDocBytes(128, 128));

    const sparse = try persistentEliasFanoDocLayout(1024, 8);
    try std.testing.expectEqual(@as(u6, 7), sparse.lower_bits);
    try std.testing.expectEqual(@as(u64, 7), sparse.lower_bytes);
    try std.testing.expectEqual(sparse.doc_bytes, try persistentEliasFanoDocBytes(1024, 8));

    try std.testing.expectEqual(@as(u64, 0), try persistentEliasFanoSelectCheckpointBytes(0));
    try std.testing.expectEqual(@as(u64, 8), try persistentEliasFanoSelectCheckpointBytes(1));
    try std.testing.expectEqual(@as(u64, 8), try persistentEliasFanoSelectCheckpointBytes(persistent_elias_fano_select_checkpoint_postings));
    try std.testing.expectEqual(@as(u64, 16), try persistentEliasFanoSelectCheckpointBytes(persistent_elias_fano_select_checkpoint_postings + 1));
    try std.testing.expectError(error.InvalidRecord, persistentEliasFanoDocBytes(0, 1));
    try std.testing.expectError(error.InvalidRecord, persistentEliasFanoDocBytes(7, 8));
}

test "persistent Elias-Fano doc ids round trip sorted postings" {
    const doc_ids = [_]u64{ 1, 2, 17, 65, 127, 128 };
    const layout = try persistentEliasFanoDocLayout(128, doc_ids.len);
    const encoded = try std.testing.allocator.alloc(u8, @intCast(layout.doc_bytes));
    defer std.testing.allocator.free(encoded);

    const encoded_layout = try encodePersistentEliasFanoDocIds(&doc_ids, 128, encoded);
    try std.testing.expectEqual(layout.lower_bits, encoded_layout.lower_bits);
    try std.testing.expectEqual(layout.doc_bytes, encoded_layout.doc_bytes);
    for (doc_ids, 0..) |doc_id, index| {
        try std.testing.expectEqual(doc_id, try decodePersistentEliasFanoDocIdSlow(encoded, 128, doc_ids.len, @intCast(index)));
    }
    try std.testing.expectError(error.InvalidRecord, decodePersistentEliasFanoDocIdSlow(encoded, 128, doc_ids.len, doc_ids.len));

    const duplicate = [_]u64{ 1, 2, 2 };
    const duplicate_encoded = try std.testing.allocator.alloc(u8, @intCast((try persistentEliasFanoDocLayout(8, duplicate.len)).doc_bytes));
    defer std.testing.allocator.free(duplicate_encoded);
    try std.testing.expectError(error.InvalidRecord, encodePersistentEliasFanoDocIds(&duplicate, 8, duplicate_encoded));

    const out_of_range = [_]u64{ 1, 9 };
    const out_of_range_encoded = try std.testing.allocator.alloc(u8, @intCast((try persistentEliasFanoDocLayout(8, out_of_range.len)).doc_bytes));
    defer std.testing.allocator.free(out_of_range_encoded);
    try std.testing.expectError(error.InvalidRecord, encodePersistentEliasFanoDocIds(&out_of_range, 8, out_of_range_encoded));
}

test "text index rejects invalid search scoring options" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();

    _ = try graph.addNode(.task, "invalid bm25 params");

    var index = try TextIndex.buildFromGraph(std.testing.allocator, &graph);
    defer index.deinit();

    try std.testing.expectError(core.Error.Unsupported, index.search("invalid", .{ .params = .{ .k1 = std.math.nan(f32) } }));
    try std.testing.expectError(core.Error.Unsupported, index.search("invalid", .{ .params = .{ .b = 1.1 } }));
    try std.testing.expectError(core.Error.Unsupported, index.search("invalid", .{ .min_score = std.math.inf(f32) }));
    try std.testing.expectError(core.Error.Unsupported, index.search("invalid", .{ .tokenizer = .{ .max_token_bytes = 0 } }));
    try std.testing.expectError(core.Error.Unsupported, index.search("错误", .{ .tokenizer = .{ .max_token_bytes = 7 } }));
}

test "text index rejects non-finite field weights before indexing" {
    var index = TextIndex.init(std.testing.allocator);
    defer index.deinit();

    index.field_weights.text = std.math.inf(f32);
    try std.testing.expectError(core.Error.Unsupported, index.addDocument(.{
        .node_id = .fromInt(1),
        .kind = .task,
        .text = "invalid field weight",
    }));
    try std.testing.expectEqual(@as(usize, 0), index.docs.items.len);
    try std.testing.expectEqual(@as(f32, 0), index.total_doc_len);
}

test "text index rejects negative or fully disabled field weights before commit" {
    {
        var index = TextIndex.init(std.testing.allocator);
        defer index.deinit();
        index.field_weights.text = -1;

        try std.testing.expectError(core.Error.Unsupported, index.addDocument(.{
            .node_id = .fromInt(1),
            .kind = .task,
            .text = "negative weight",
        }));
        try std.testing.expectEqual(@as(usize, 0), index.docs.items.len);
        try std.testing.expectEqual(@as(usize, 0), index.doc_ids.count());
        try std.testing.expectEqual(@as(f32, 0), index.total_doc_len);
    }
    {
        var index = TextIndex.init(std.testing.allocator);
        defer index.deinit();
        index.field_weights.text = 0;
        index.field_weights.kind = 0;

        try std.testing.expectError(core.Error.Unsupported, index.addDocument(.{
            .node_id = .fromInt(1),
            .kind = .task,
            .text = "disabled fields",
        }));
        try std.testing.expectEqual(@as(usize, 0), index.docs.items.len);
        try std.testing.expectEqual(@as(usize, 0), index.doc_ids.count());
        try std.testing.expect(!index.doc_ids.contains(1));
        try std.testing.expectEqual(@as(f32, 0), index.total_doc_len);
    }
}

test "text index rejects total document length overflow before commit" {
    var index = TextIndex.init(std.testing.allocator);
    defer index.deinit();
    index.field_weights.text = std.math.floatMax(f32);
    index.field_weights.kind = 0;

    try index.addDocument(.{
        .node_id = .fromInt(1),
        .kind = .task,
        .text = "alpha",
    });
    const baseline_total_doc_len = index.total_doc_len;

    try std.testing.expectError(core.Error.Unsupported, index.addDocument(.{
        .node_id = .fromInt(2),
        .kind = .task,
        .text = "beta",
    }));
    try std.testing.expectEqual(@as(usize, 1), index.docs.items.len);
    try std.testing.expectEqual(@as(usize, 1), index.doc_ids.count());
    try std.testing.expect(!index.doc_ids.contains(2));
    try std.testing.expectEqual(baseline_total_doc_len, index.total_doc_len);
}

test "text index rejects tokenizer options before indexing" {
    var index = TextIndex.init(std.testing.allocator);
    defer index.deinit();

    index.tokenizer_options = .{ .max_token_bytes = 7 };
    try std.testing.expectError(core.Error.Unsupported, index.addDocument(.{
        .node_id = .fromInt(1),
        .kind = .observation,
        .text = "错误记录",
    }));
    try std.testing.expectEqual(@as(usize, 0), index.docs.items.len);
    try std.testing.expectEqual(@as(f32, 0), index.total_doc_len);
}

test "text index rejects tokenizer mismatch between index and query" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();

    _ = try graph.addNode(.observation, "错误记录");

    var index = try TextIndex.buildFromGraph(std.testing.allocator, &graph);
    defer index.deinit();

    try std.testing.expectError(core.Error.Unsupported, index.search("错误", .{
        .tokenizer = .{ .emit_cjk_bigrams = false },
    }));

    var custom = TextIndex.init(std.testing.allocator);
    custom.tokenizer_options = .{ .emit_cjk_bigrams = false };
    defer custom.deinit();
    try custom.addDocument(.{ .node_id = .fromInt(1), .kind = .observation, .text = "错误记录" });

    var hits = try custom.search("错", .{ .tokenizer = custom.tokenizer_options });
    defer hits.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), hits.items.len);
}

test "persistent term frequency streaming path matches tokenizer shape" {
    const input = "src/ql/readEdgeIndexRecordsByNode.zig 错误-记录 std.mem.Allocator ＩｎｖａｌｉｄＲｅｃｏｒｄ";
    var tokens = try tokenize(std.testing.allocator, input, .{});
    defer tokens.deinit();

    var expected = std.StringHashMap(u32).init(std.testing.allocator);
    defer expected.deinit();
    for (tokens.items.items) |term| {
        const entry = try expected.getOrPut(term);
        if (!entry.found_existing) entry.value_ptr.* = 0;
        entry.value_ptr.* += 1;
    }

    var freqs = std.StringHashMap(FieldTermFreq).init(std.testing.allocator);
    defer freqs.deinit();
    var owned = std.ArrayList([]u8).empty;
    defer {
        for (owned.items) |term| std.testing.allocator.free(term);
        owned.deinit(std.testing.allocator);
    }

    const count = try collectStreamingTermFreqs(std.testing.allocator, &freqs, &owned, input, .text);
    try std.testing.expectEqual(@as(u64, @intCast(tokens.items.items.len)), count);
    try std.testing.expectEqual(expected.count(), freqs.count());

    var it = expected.iterator();
    while (it.next()) |entry| {
        const actual = freqs.get(entry.key_ptr.*) orelse return error.MissingTerm;
        try std.testing.expectEqual(entry.value_ptr.*, actual.text);
        try std.testing.expectEqual(@as(u32, 0), actual.kind);
    }
}

test "persistent term frequency streaming path preserves mixed normalized runs" {
    const input = "abcＩｎｖａｌｉｄRecord src／ｍａｉｎ.zig";
    var tokens = try tokenize(std.testing.allocator, input, .{});
    defer tokens.deinit();

    var expected = std.StringHashMap(u32).init(std.testing.allocator);
    defer expected.deinit();
    for (tokens.items.items) |term| {
        const entry = try expected.getOrPut(term);
        if (!entry.found_existing) entry.value_ptr.* = 0;
        entry.value_ptr.* += 1;
    }

    var freqs = std.StringHashMap(FieldTermFreq).init(std.testing.allocator);
    defer freqs.deinit();
    var owned = std.ArrayList([]u8).empty;
    defer {
        for (owned.items) |term| std.testing.allocator.free(term);
        owned.deinit(std.testing.allocator);
    }

    const count = try collectStreamingTermFreqs(std.testing.allocator, &freqs, &owned, input, .text);
    try std.testing.expectEqual(@as(u64, @intCast(tokens.items.items.len)), count);
    try std.testing.expectEqual(expected.count(), freqs.count());

    var it = expected.iterator();
    while (it.next()) |entry| {
        const actual = freqs.get(entry.key_ptr.*) orelse return error.MissingTerm;
        try std.testing.expectEqual(entry.value_ptr.*, actual.text);
        try std.testing.expectEqual(@as(u32, 0), actual.kind);
    }
}

test "persistent term frequency streaming path counts repeated CJK terms" {
    const input = "哈哈哈 错误错误";
    var tokens = try tokenize(std.testing.allocator, input, .{});
    defer tokens.deinit();

    var expected = std.StringHashMap(u32).init(std.testing.allocator);
    defer expected.deinit();
    for (tokens.items.items) |term| {
        const entry = try expected.getOrPut(term);
        if (!entry.found_existing) entry.value_ptr.* = 0;
        entry.value_ptr.* += 1;
    }

    var freqs = std.StringHashMap(FieldTermFreq).init(std.testing.allocator);
    defer freqs.deinit();
    var owned = std.ArrayList([]u8).empty;
    defer {
        for (owned.items) |term| std.testing.allocator.free(term);
        owned.deinit(std.testing.allocator);
    }

    const count = try collectStreamingTermFreqs(std.testing.allocator, &freqs, &owned, input, .text);
    try std.testing.expectEqual(@as(u64, @intCast(tokens.items.items.len)), count);
    try std.testing.expectEqual(expected.count(), freqs.count());
    try std.testing.expectEqual(expected.count(), owned.items.len);

    var it = expected.iterator();
    while (it.next()) |entry| {
        const actual = freqs.get(entry.key_ptr.*) orelse return error.MissingTerm;
        try std.testing.expectEqual(entry.value_ptr.*, actual.text);
        try std.testing.expectEqual(@as(u32, 0), actual.kind);
    }
}

test "persistent term frequency streaming path handles long CJK runs without offsets" {
    const input = "错误记录索引修复路径缓存查询排序合并压缩验证发布维护删除回滚事务节点边关系任务上下文文档代码符号" ++
        "错误记录索引修复路径缓存查询排序合并压缩验证发布维护删除回滚事务节点边关系任务上下文文档代码符号";
    var tokens = try tokenize(std.testing.allocator, input, .{});
    defer tokens.deinit();
    try std.testing.expect(tokens.items.items.len > 128);

    var expected = std.StringHashMap(u32).init(std.testing.allocator);
    defer expected.deinit();
    for (tokens.items.items) |term| {
        const entry = try expected.getOrPut(term);
        if (!entry.found_existing) entry.value_ptr.* = 0;
        entry.value_ptr.* += 1;
    }

    var freqs = std.StringHashMap(FieldTermFreq).init(std.testing.allocator);
    defer freqs.deinit();
    var owned = std.ArrayList([]u8).empty;
    defer {
        for (owned.items) |term| std.testing.allocator.free(term);
        owned.deinit(std.testing.allocator);
    }

    const count = try collectStreamingTermFreqs(std.testing.allocator, &freqs, &owned, input, .text);
    try std.testing.expectEqual(@as(u64, @intCast(tokens.items.items.len)), count);
    try std.testing.expectEqual(expected.count(), freqs.count());

    var it = expected.iterator();
    while (it.next()) |entry| {
        const actual = freqs.get(entry.key_ptr.*) orelse return error.MissingTerm;
        try std.testing.expectEqual(entry.value_ptr.*, actual.text);
        try std.testing.expectEqual(@as(u32, 0), actual.kind);
    }
}

test "persistent term frequency streaming path can use arena-owned terms" {
    const input = "ReadEdgeIndex 错误错误";
    var tokens = try tokenize(std.testing.allocator, input, .{});
    defer tokens.deinit();

    var expected = std.StringHashMap(u32).init(std.testing.allocator);
    defer expected.deinit();
    for (tokens.items.items) |term| {
        const entry = try expected.getOrPut(term);
        if (!entry.found_existing) entry.value_ptr.* = 0;
        entry.value_ptr.* += 1;
    }

    var term_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer term_arena.deinit();
    var freqs = std.StringHashMap(FieldTermFreq).init(std.testing.allocator);
    defer freqs.deinit();

    const count = try collectStreamingTermFreqs(term_arena.allocator(), &freqs, null, input, .text);
    try std.testing.expectEqual(@as(u64, @intCast(tokens.items.items.len)), count);
    try std.testing.expectEqual(expected.count(), freqs.count());

    var it = expected.iterator();
    while (it.next()) |entry| {
        const actual = freqs.get(entry.key_ptr.*) orelse return error.MissingTerm;
        try std.testing.expectEqual(entry.value_ptr.*, actual.text);
        try std.testing.expectEqual(@as(u32, 0), actual.kind);
    }

    freqs.clearRetainingCapacity();
    _ = term_arena.reset(.retain_capacity);
    const second_count = try collectStreamingTermFreqs(term_arena.allocator(), &freqs, null, "GraphNode", .text);
    try std.testing.expect(second_count > 0);
    try std.testing.expect(freqs.contains("graphnode"));
}

test "persistent term frequency streaming path borrows lowercase ascii terms" {
    const input = "alpha beta/path gamma_delta";
    var term_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer term_arena.deinit();
    var freqs = std.StringHashMap(FieldTermFreq).init(std.testing.allocator);
    defer freqs.deinit();

    const count = try collectStreamingTermFreqs(term_arena.allocator(), &freqs, null, input, .text);
    try std.testing.expect(count > 0);
    try std.testing.expect(freqs.contains("alpha"));
    try std.testing.expect(freqs.contains("beta/path"));
    try std.testing.expect(freqs.contains("gamma_delta"));
    try std.testing.expectEqual(@as(usize, 0), term_arena.queryCapacity());
}

test "persistent term frequency streaming path owns normalized ascii scratch terms" {
    const input = "ａｌｐｈａ";
    var term_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer term_arena.deinit();
    var freqs = std.StringHashMap(FieldTermFreq).init(std.testing.allocator);
    defer freqs.deinit();

    const count = try collectStreamingTermFreqs(term_arena.allocator(), &freqs, null, input, .text);
    try std.testing.expectEqual(@as(u64, 1), count);
    try std.testing.expect(freqs.contains("alpha"));
    try std.testing.expect(term_arena.queryCapacity() > 0);
}

test "persistent term frequency streaming path reuses external scratch across arena reset" {
    var term_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer term_arena.deinit();
    var freqs = std.StringHashMap(FieldTermFreq).init(std.testing.allocator);
    defer freqs.deinit();
    var scratch = std.ArrayList(u8).empty;
    defer scratch.deinit(std.testing.allocator);

    const first_count = try collectStreamingTermFreqsWithScratch(term_arena.allocator(), std.testing.allocator, &freqs, null, "錯誤Ｉｎｖａｌｉｄ", .text, &scratch);
    try std.testing.expect(first_count > 0);
    try std.testing.expect(freqs.contains("invalid"));
    const first_capacity = scratch.capacity;
    try std.testing.expect(first_capacity > 0);

    freqs.clearRetainingCapacity();
    _ = term_arena.reset(.retain_capacity);
    const second_count = try collectStreamingTermFreqsWithScratch(term_arena.allocator(), std.testing.allocator, &freqs, null, "GraphNode", .text, &scratch);
    try std.testing.expect(second_count > 0);
    try std.testing.expect(freqs.contains("graphnode"));
    try std.testing.expect(scratch.capacity >= first_capacity);
}

test "persistent text rebuild term scratch caps long-tail retained capacity" {
    var term_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer term_arena.deinit();
    var freqs = std.StringHashMap(FieldTermFreq).init(std.testing.allocator);
    defer freqs.deinit();

    const large = try term_arena.allocator().alloc(u8, text_rebuild_term_arena_retain_limit * 2);
    @memset(large, 'x');
    try freqs.ensureTotalCapacity(text_rebuild_term_freq_retain_capacity_limit + 1);
    try std.testing.expect(term_arena.queryCapacity() > text_rebuild_term_arena_retain_limit);
    try std.testing.expect(freqs.capacity() > text_rebuild_term_freq_retain_capacity_limit);

    clearReusableArenaTermFreqs(&freqs, &term_arena);

    try std.testing.expect(term_arena.queryCapacity() <= text_rebuild_term_arena_retain_limit);
    try std.testing.expectEqual(@as(u32, 0), freqs.capacity());
    try std.testing.expectEqual(@as(u32, 0), freqs.count());
}

test "text index searches CJK single-character fallback terms" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();

    const error_id = try graph.addNode(.observation, "错误记录");
    _ = try graph.addNode(.task, "索引修复");

    var index = try TextIndex.buildFromGraph(std.testing.allocator, &graph);
    defer index.deinit();

    var hits = try index.search("错", .{ .limit = 10 });
    defer hits.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), hits.items.len);
    try std.testing.expectEqual(error_id, hits.items[0].node_id);
}

test "text index requires CJK bigram match for multi-character CJK queries" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();

    const exact_id = try graph.addNode(.observation, "错误记录");
    _ = try graph.addNode(.observation, "错别字");
    _ = try graph.addNode(.observation, "误差分析");
    _ = try graph.addNode(.observation, "错误说明");
    _ = try graph.addNode(.observation, "记录分析");

    var index = try TextIndex.buildFromGraph(std.testing.allocator, &graph);
    defer index.deinit();

    var exact = try index.search("错误", .{ .limit = 10 });
    defer exact.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), exact.items.len);
    try std.testing.expectEqual(exact_id, exact.items[0].node_id);

    var full = try index.search("错误记录", .{ .limit = 10 });
    defer full.deinit(std.testing.allocator);
    // 修复:AND 门 → floor=1(命中任一 bigram 即召回)+ 覆盖优先排序(全覆盖恒排 #1)。
    // "错误记录"命中 错误/误记/记录 三个 bigram(cov=3)排第一;"错误说明"/"记录分析"各命中 1(cov=1)在后。
    // "错别字"/"误差分析" 一个都不命中(cov=0)→ 仍不召回。旧行为(严格 AND)只召回 exact_id。
    try std.testing.expectEqual(@as(usize, 3), full.items.len);
    try std.testing.expectEqual(exact_id, full.items[0].node_id); // 全覆盖排第一(覆盖优先)
    try std.testing.expectEqual(@as(u32, 3), full.items[0].match_count);
    try std.testing.expect(full.items[full.items.len - 1].match_count < full.items[0].match_count); // 部分覆盖排后

    var single = try index.search("错", .{ .limit = 10 });
    defer single.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), single.items.len);
}

// 回归:自然语言整句 query(含大量功能字 bigram)。旧 AND 门要求命中**全部** bigram → 必然 0 召回
// (metacodes 中文记忆召回不可用的根因)。修复(floor=1 + 覆盖优先)后:命中高信息 bigram 的文档召回,
// 无关文档(0 覆盖)仍不召回。
test "text index recalls natural-language CJK sentence via partial bigram coverage" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();

    const target = try graph.addNode(.observation, "自动压缩阈值用输入窗口");
    _ = try graph.addNode(.observation, "缓存淘汰策略与实现");

    var index = try TextIndex.buildFromGraph(std.testing.allocator, &graph);
    defer index.deinit();

    // 整句:自动/动压/压缩/缩阈/阈值 与 target 重合(cov=5);其余功能字 bigram(应该/设置/多少…)不在。
    // 旧行为:required=全部 12 个 bigram,target 只中 5 → 0 召回。新行为:floor=1 → 召回。
    var hits = try index.search("自动压缩阈值应该设置成多少", .{ .limit = 10 });
    defer hits.deinit(std.testing.allocator);
    try std.testing.expect(hits.items.len >= 1); // 修复前 = 0
    try std.testing.expectEqual(target, hits.items[0].node_id); // 高信息 bigram 覆盖的目标排第一
    try std.testing.expect(hits.items[0].match_count >= 5); // 命中 5 个共享 bigram
    // 无关文档("缓存淘汰…"与 query bigram 零重合)不召回。
    for (hits.items) |h| try std.testing.expect(h.node_id.toInt() == target.toInt());
}

// 混合语言 query(中文 + 英文关键词——LLM query 扩展 / 双语语料场景):query 含非 CJK 词时
// 跳过 CJK bigram 覆盖门,让纯英文文档(命中 ASCII 词但 0 个 CJK bigram)也能召回,桥接中英词法鸿沟。
test "text index mixed-language query bridges lexical gap via non-CJK terms" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();

    const english_id = try graph.addNode(.observation, "the process panicked with reached unreachable");
    _ = try graph.addNode(.observation, "缓存淘汰策略与实现");

    var index = try TextIndex.buildFromGraph(std.testing.allocator, &graph);
    defer index.deinit();

    // 混合 query:CJK bigram(进程/程崩/崩溃)+ 英文 unreachable。旧 floor=1 因英文文档 0 个 CJK
    // bigram 命中而排除它 -> 0 召回;修复后(query 含非 CJK 词 -> 跳过 CJK floor)英文文档经
    // ASCII 词 unreachable 召回。
    var mixed = try index.search("进程崩溃 unreachable", .{ .limit = 5 });
    defer mixed.deinit(std.testing.allocator);
    try std.testing.expect(mixed.items.len >= 1);
    try std.testing.expectEqual(english_id, mixed.items[0].node_id);

    // 纯 CJK query(无非 CJK 词)仍走 floor:英文文档零 CJK 重合 -> 不召回(精度保持)。
    var pure = try index.search("进程崩溃", .{ .limit = 5 });
    defer pure.deinit(std.testing.allocator);
    for (pure.items) |h| try std.testing.expect(h.node_id.toInt() != english_id.toInt());
}

test "text index requires repeated CJK bigram frequency for repeated-character queries" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();

    _ = try graph.addNode(.observation, "哈哈");
    const exact_id = try graph.addNode(.observation, "哈哈哈");
    const longer_id = try graph.addNode(.observation, "哈哈哈哈");

    var index = try TextIndex.buildFromGraph(std.testing.allocator, &graph);
    defer index.deinit();

    var hits = try index.search("哈哈哈", .{ .limit = 10 });
    defer hits.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), hits.items.len);
    try std.testing.expect(hitsContainNode(hits.items, exact_id));
    try std.testing.expect(hitsContainNode(hits.items, longer_id));
}

test "text index applies kind filter and limit" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();

    const file_id = try graph.addNode(.file, "src/storage.zig");
    _ = try graph.addNode(.task, "storage index repair task");
    _ = try graph.addNode(.document, "storage design");

    var index = try TextIndex.buildFromGraph(std.testing.allocator, &graph);
    defer index.deinit();

    var hits = try index.search("storage", .{ .kind_filter = .file, .limit = 1 });
    defer hits.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), hits.items.len);
    try std.testing.expectEqual(file_id, hits.items[0].node_id);
}

test "text index applies schema descendant kind set before top-k" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();

    const task_id = try graph.addNode(.task, "shared search term");
    const decision_id = try graph.addNode(.decision, "shared search term");
    _ = try graph.addNode(.file, "shared search term shared search term shared search term");

    var allowed = schema.NodeTypeSet.empty();
    try allowed.insert(@intFromEnum(core.NodeKind.task));
    try allowed.insert(@intFromEnum(core.NodeKind.decision));
    var index = try TextIndex.buildFromGraph(std.testing.allocator, &graph);
    defer index.deinit();

    var hits = try index.search("shared search term", .{
        .kind_set_filter = &allowed,
        .limit = 2,
    });
    defer hits.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), hits.items.len);
    try std.testing.expect(hitsContainNode(hits.items, task_id));
    try std.testing.expect(hitsContainNode(hits.items, decision_id));
}

test "text index enforces postings scan budget" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();

    _ = try graph.addNode(.task, "storage repair");
    _ = try graph.addNode(.task, "storage index");

    var index = try TextIndex.buildFromGraph(std.testing.allocator, &graph);
    defer index.deinit();

    try std.testing.expectError(core.Error.BudgetExceeded, index.search("storage", .{ .limit = 10, .max_postings_scanned = 1 }));

    var hits = try index.search("storage", .{ .limit = 10, .max_postings_scanned = 2 });
    defer hits.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), hits.items.len);
}

test "text term top-hit collector caches worst slot without changing ordering" {
    var hits = std.ArrayList(TextTermTopHitRecord).empty;
    defer hits.deinit(std.testing.allocator);
    var worst_index: ?usize = null;

    try appendTopTextTermHitBoundedCachedWorst(std.testing.allocator, &hits, 3, &worst_index, .{ .doc_id = 10, .node_id = 30, .score = 1.0 });
    try appendTopTextTermHitBoundedCachedWorst(std.testing.allocator, &hits, 3, &worst_index, .{ .doc_id = 20, .node_id = 50, .score = 3.0 });
    try appendTopTextTermHitBoundedCachedWorst(std.testing.allocator, &hits, 3, &worst_index, .{ .doc_id = 30, .node_id = 40, .score = 2.0 });
    try std.testing.expect(worst_index != null);

    try appendTopTextTermHitBoundedCachedWorst(std.testing.allocator, &hits, 3, &worst_index, .{ .doc_id = 40, .node_id = 20, .score = 0.5 });
    try appendTopTextTermHitBoundedCachedWorst(std.testing.allocator, &hits, 3, &worst_index, .{ .doc_id = 50, .node_id = 10, .score = 3.0 });

    std.mem.sort(TextTermTopHitRecord, hits.items, {}, textTermTopHitLessThan);
    try std.testing.expectEqual(@as(usize, 3), hits.items.len);
    try std.testing.expectEqual(@as(u64, 10), hits.items[0].node_id);
    try std.testing.expectEqual(@as(u64, 50), hits.items[1].node_id);
    try std.testing.expectEqual(@as(u64, 40), hits.items[2].node_id);
    try std.testing.expect(textTermTopHitScoreOrderValid(hits.items[0], hits.items[1]));
    try std.testing.expect(!textTermTopHitScoreOrderValid(hits.items[2], hits.items[1]));
}

test "streaming text term top-hit inline collector keeps best hits without heap" {
    var hits: [persistent_term_top_hit_capacity_usize]TextTermTopHitRecord = undefined;
    var hit_count: usize = 0;
    var worst_index: ?usize = null;

    try appendTopTextTermHitBoundedInline(&hits, &hit_count, 2, &worst_index, .{ .doc_id = 1, .score = 3.0 });
    try appendTopTextTermHitBoundedInline(&hits, &hit_count, 2, &worst_index, .{ .doc_id = 2, .score = 1.0 });
    try appendTopTextTermHitBoundedInline(&hits, &hit_count, 2, &worst_index, .{ .doc_id = 3, .score = 2.0 });
    try appendTopTextTermHitBoundedInline(&hits, &hit_count, 2, &worst_index, .{ .doc_id = 4, .score = 0.5 });

    try std.testing.expectEqual(@as(usize, 2), hit_count);
    std.mem.sort(TextTermTopHitRecord, hits[0..hit_count], {}, textTermTopHitLessThan);
    try std.testing.expectEqual(@as(u64, 1), hits[0].doc_id);
    try std.testing.expectEqual(@as(u64, 3), hits[1].doc_id);
}

test "text term top-hit upper bound skips hopeless candidates" {
    var hits = std.ArrayList(TextTermTopHitRecord).empty;
    defer hits.deinit(std.testing.allocator);
    var worst_index: ?usize = null;

    try appendTopTextTermHitBoundedCachedWorst(std.testing.allocator, &hits, 2, &worst_index, .{ .doc_id = 1, .score = 1.0 });
    try appendTopTextTermHitBoundedCachedWorst(std.testing.allocator, &hits, 2, &worst_index, .{ .doc_id = 2, .score = 2.0 });
    try std.testing.expect(worst_index != null);

    try std.testing.expect(try textTermTopHitCandidateCannotBeatCurrentWorst(
        hits.items,
        worst_index,
        2,
        .{ .doc_id = 3, .text_freq = 1, .kind_freq = 0 },
        10.0,
        1000,
        999,
    ));
    try std.testing.expect(!try textTermTopHitCandidateCannotBeatCurrentWorst(
        hits.items,
        worst_index,
        2,
        .{ .doc_id = 4, .text_freq = 100, .kind_freq = 0 },
        10.0,
        1000,
        10,
    ));
}

test "text term top-hit candidate upper bound uses known doc length floor" {
    var hits = std.ArrayList(TextTermTopHitRecord).empty;
    defer hits.deinit(std.testing.allocator);

    const posting = TextPostingRecord{ .doc_id = 3, .text_freq = 1, .kind_freq = 0 };
    const avg_doc_len: f32 = 100.0;
    const doc_count: u64 = 1000;
    const doc_freq: u64 = 100;
    const doc_len_floor: f32 = 300.0;
    const loose_upper = bm25WeightedTermScore(
        persistentWeightedTf(posting),
        persistentMinPossibleDocLenForPosting(posting),
        avg_doc_len,
        doc_count,
        doc_freq,
        .{},
    );
    const tight_upper = bm25WeightedTermScore(
        persistentWeightedTf(posting),
        persistentDocLenLowerBoundForPosting(posting, doc_len_floor),
        avg_doc_len,
        doc_count,
        doc_freq,
        .{},
    );
    try std.testing.expect(loose_upper > tight_upper);

    var worst_index: ?usize = null;
    const current_worst = (loose_upper + tight_upper) / 2.0;
    try appendTopTextTermHitBoundedCachedWorst(std.testing.allocator, &hits, 1, &worst_index, .{ .doc_id = 1, .score = current_worst });
    try std.testing.expect(worst_index != null);

    try std.testing.expect(!try textTermTopHitCandidateCannotBeatCurrentWorst(
        hits.items,
        worst_index,
        1,
        posting,
        avg_doc_len,
        doc_count,
        doc_freq,
    ));
    try std.testing.expect(try textTermTopHitCandidateCannotBeatCurrentWorstWithDocLenFloor(
        hits.items,
        worst_index,
        1,
        posting,
        avg_doc_len,
        doc_count,
        doc_freq,
        doc_len_floor,
    ));
}

test "text term top-hit block upper bound skips hopeless blocks" {
    var hits = std.ArrayList(TextTermTopHitRecord).empty;
    defer hits.deinit(std.testing.allocator);
    var worst_index: ?usize = null;

    try appendTopTextTermHitBoundedCachedWorst(std.testing.allocator, &hits, 2, &worst_index, .{ .doc_id = 1, .score = 1.0 });
    try appendTopTextTermHitBoundedCachedWorst(std.testing.allocator, &hits, 2, &worst_index, .{ .doc_id = 2, .score = 2.0 });
    try std.testing.expect(worst_index != null);

    try std.testing.expect(textTermTopHitBlockCannotBeatCurrentWorst(hits.items, worst_index, 2, 0.5));
    try std.testing.expect(!textTermTopHitBlockCannotBeatCurrentWorst(hits.items, worst_index, 2, 1.0));
    try std.testing.expect(!textTermTopHitBlockCannotBeatCurrentWorst(hits.items, worst_index, 2, 2.5));
}

test "persistent text resolves constant near-all top hits from global top docs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage_mod.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    const common_doc_count = persistent_term_top_hit_test_min_postings + 1;
    var id: u64 = 1;
    while (id <= common_doc_count) : (id += 1) {
        try store.appendNode(.{ .id = .fromInt(id), .kind = .task, .text = "common" });
    }
    try store.appendNode(.{ .id = .fromInt(common_doc_count + 1), .kind = .task, .text = "zzzzzz zzzzzz zzzzzz zzzzzz" });

    const runs_base_path = try std.fs.path.join(std.testing.allocator, &.{ root, "runs" });
    defer std.testing.allocator.free(runs_base_path);
    const result = try rebuildPersistentTextCatalogWithTimingsForBench(std.testing.allocator, store, runs_base_path);
    try std.testing.expectEqual(common_doc_count + 1, result.meta.doc_count);
    try std.testing.expectEqual(@as(u64, 1), result.timings.run_derived_top_hit_regular_constant_terms);
    try std.testing.expectEqual(@as(u64, 1), result.timings.run_derived_top_hit_regular_constant_resolved_terms);
    try std.testing.expect(result.timings.run_derived_top_hit_regular_constant_resolved_candidate_skips >= persistent_term_top_hit_capacity);
    try std.testing.expectEqual(@as(u64, 0), result.timings.run_derived_top_hit_regular_doc_reads);

    var hits = try searchText(std.testing.allocator, store, "common", .{ .limit = 8, .max_postings_scanned = 0 });
    defer hits.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 8), hits.items.len);
    try std.testing.expectEqual(core.NodeId.fromInt(1), hits.items[0].node_id);
}

test "persistent text resolves constant subset top hits from global doc rank" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage_mod.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    try store.appendNode(.{ .id = .fromInt(1), .kind = .task, .text = "rare" });
    const common_doc_count = persistent_term_top_hit_test_min_postings + 1;
    var id: u64 = 2;
    while (id <= common_doc_count + 1) : (id += 1) {
        try store.appendNode(.{ .id = .fromInt(id), .kind = .task, .text = "common" });
    }

    const runs_base_path = try std.fs.path.join(std.testing.allocator, &.{ root, "runs" });
    defer std.testing.allocator.free(runs_base_path);
    const result = try rebuildPersistentTextCatalogWithTimingsForBench(std.testing.allocator, store, runs_base_path);
    try std.testing.expectEqual(common_doc_count + 1, result.meta.doc_count);
    try std.testing.expectEqual(@as(u64, 1), result.timings.run_derived_top_hit_regular_constant_terms);
    try std.testing.expectEqual(@as(u64, 1), result.timings.run_derived_top_hit_regular_constant_resolved_terms);
    try std.testing.expectEqual(@as(u64, 0), result.timings.run_derived_top_hit_regular_constant_unresolved_terms);
    try std.testing.expectEqual(@as(u64, 0), result.timings.run_derived_top_hit_regular_doc_reads);
    try std.testing.expect(result.timings.run_derived_top_hit_regular_constant_resolved_candidate_skips >= persistent_term_top_hit_capacity);

    var hits = try searchText(std.testing.allocator, store, "common", .{ .limit = 8, .max_postings_scanned = 0 });
    defer hits.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 8), hits.items.len);
    try std.testing.expectEqual(core.NodeId.fromInt(2), hits.items[0].node_id);
}

fn appendRepeatedTextTestNodes(
    allocator: std.mem.Allocator,
    store: storage_mod.Store,
    start_id: u64,
    end_id: u64,
    kind: core.NodeKind,
    text: []const u8,
) !void {
    if (end_id < start_id) return;
    const count = std.math.cast(usize, end_id - start_id + 1) orelse return error.RecordTooLarge;
    var nodes = std.ArrayList(graph_mod.Node).empty;
    defer nodes.deinit(allocator);
    try nodes.ensureTotalCapacity(allocator, count);

    var id = start_id;
    while (id <= end_id) : (id += 1) {
        nodes.appendAssumeCapacity(.{ .id = .fromInt(id), .kind = kind, .text = text });
    }
    try store.appendNodesBatch(nodes.items);
}

test "persistent text omits block metadata for single block terms" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage_mod.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();
    try store.appendNode(.{ .id = .fromInt(1), .kind = .task, .text = "single block metadata omitted" });
    _ = try rebuildPersistentTextCatalog(std.testing.allocator, store);

    const terms_path = try textTermsPath(std.testing.allocator, store);
    defer std.testing.allocator.free(terms_path);
    var terms_file = try std.Io.Dir.cwd().openFile(std.testing.io, terms_path, .{});
    defer terms_file.close(std.testing.io);
    const terms_header = try readTextTermsHeaderFromFile(store, terms_file);

    const blocks_path = try textPostingBlocksPath(std.testing.allocator, store);
    defer std.testing.allocator.free(blocks_path);
    var blocks_file = try std.Io.Dir.cwd().openFile(std.testing.io, blocks_path, .{});
    defer blocks_file.close(std.testing.io);
    const blocks_header = try readTextPostingBlocksHeaderFromFile(store, blocks_file);
    try std.testing.expectEqual(terms_header.term_count, blocks_header.term_count);
    try std.testing.expectEqual(@as(u64, 0), blocks_header.block_count);
    try std.testing.expectEqual(try textPostingBlocksFileSize(terms_header.term_count, 0), try regularFileSize(store, blocks_file));

    const impacts_path = try textPostingBlockImpactsPath(std.testing.allocator, store);
    defer std.testing.allocator.free(impacts_path);
    var impacts_file = try std.Io.Dir.cwd().openFile(std.testing.io, impacts_path, .{});
    defer impacts_file.close(std.testing.io);
    const impacts_header = try readTextPostingBlockImpactsHeaderFromFile(store, impacts_file);
    try std.testing.expectEqual(terms_header.term_count, impacts_header.term_count);
    try std.testing.expectEqual(@as(u64, 0), impacts_header.block_count);
    try std.testing.expectEqual(try textPostingBlockImpactsFileSize(terms_header.term_count, 0), try regularFileSize(store, impacts_file));

    var hits = try searchText(std.testing.allocator, store, "single", .{ .limit = 1, .max_postings_scanned = 1 });
    defer hits.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), hits.items.len);
    try std.testing.expectEqual(core.NodeId.fromInt(1), hits.items[0].node_id);
}

test "persistent text stores all-doc variable frequencies as bitpacked dense stream" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage_mod.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    var nodes = std.ArrayList(graph_mod.Node).empty;
    defer nodes.deinit(std.testing.allocator);
    try nodes.ensureTotalCapacity(std.testing.allocator, persistent_term_top_hit_min_postings);
    var id: u64 = 1;
    while (id <= persistent_term_top_hit_min_postings) : (id += 1) {
        const text = if (id % 2 == 0)
            "densefreq densefreq densefreq densefreq densefreq densefreq densefreq densefreq"
        else
            "densefreq";
        nodes.appendAssumeCapacity(.{ .id = .fromInt(id), .kind = .task, .text = text });
    }
    try store.appendNodesBatch(nodes.items);
    _ = try rebuildPersistentTextCatalog(std.testing.allocator, store);

    const doc_count = try readPersistentTextDocCount(std.testing.allocator, store);
    var catalog = try PersistentPostingCatalog.open(std.testing.allocator, store, doc_count);
    defer catalog.deinit();
    const lookup = (try catalog.findTermEntry("densefreq")) orelse return error.InvalidRecord;
    try std.testing.expectEqual(persistent_term_top_hit_min_postings, lookup.entry.postings_count);
    try std.testing.expectEqual(@as(?u32, null), termEntryVirtualAllDocsTextFreq(lookup.entry));
    const dense_offset = termEntryDenseAllDocsFreqStreamOffset(lookup.entry) orelse return error.InvalidRecord;
    try std.testing.expect(dense_offset < catalog.postings_header.body_bytes);
    try std.testing.expectEqual(persistent_dense_all_docs_freq_mode_bitpacked, try catalog.postings_view.readByteAt(try textPostingBodyOffset(dense_offset)));
    try std.testing.expectEqual(@as(u64, 0), try publishedPostingBlockCountForEntry(lookup.entry, catalog.blocks_header.block_size));

    var postings = try readPersistentTermPostingsLimited(std.testing.allocator, store, "densefreq", persistent_term_top_hit_min_postings);
    defer postings.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, persistent_term_top_hit_min_postings), postings.items.len);
    try std.testing.expectEqual(@as(u32, 1), postings.items[0].text_freq);
    try std.testing.expectEqual(@as(u32, 8), postings.items[1].text_freq);
    try std.testing.expect(catalog.postings_header.body_bytes < persistent_term_top_hit_min_postings);

    var hits = try searchText(std.testing.allocator, store, "densefreq", .{ .limit = 4, .max_postings_scanned = persistent_term_top_hit_min_postings });
    defer hits.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 4), hits.items.len);
}

test "persistent text stores run-length-shaped dense all-doc frequencies as bitpacked for random access" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage_mod.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    var nodes = std.ArrayList(graph_mod.Node).empty;
    defer nodes.deinit(std.testing.allocator);
    try nodes.ensureTotalCapacity(std.testing.allocator, persistent_term_top_hit_min_postings);
    var id: u64 = 1;
    while (id <= persistent_term_top_hit_min_postings) : (id += 1) {
        const text = if (id <= persistent_term_top_hit_min_postings / 2)
            "densefreqrle"
        else
            "densefreqrle densefreqrle densefreqrle densefreqrle densefreqrle densefreqrle densefreqrle densefreqrle";
        nodes.appendAssumeCapacity(.{ .id = .fromInt(id), .kind = .task, .text = text });
    }
    try store.appendNodesBatch(nodes.items);
    _ = try rebuildPersistentTextCatalog(std.testing.allocator, store);

    const doc_count = try readPersistentTextDocCount(std.testing.allocator, store);
    var catalog = try PersistentPostingCatalog.open(std.testing.allocator, store, doc_count);
    defer catalog.deinit();
    const lookup = (try catalog.findTermEntry("densefreqrle")) orelse return error.InvalidRecord;
    const dense_offset = termEntryDenseAllDocsFreqStreamOffset(lookup.entry) orelse return error.InvalidRecord;
    try std.testing.expectEqual(persistent_dense_all_docs_freq_mode_bitpacked, try catalog.postings_view.readByteAt(try textPostingBodyOffset(dense_offset)));
    try std.testing.expect(catalog.postings_header.body_bytes < persistent_term_top_hit_min_postings);

    var postings = try readPersistentTermPostingsLimited(std.testing.allocator, store, "densefreqrle", persistent_term_top_hit_min_postings);
    defer postings.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, persistent_term_top_hit_min_postings), postings.items.len);
    try std.testing.expectEqual(@as(u32, 1), postings.items[0].text_freq);
    try std.testing.expectEqual(@as(u32, 8), postings.items[@as(usize, @intCast(persistent_term_top_hit_min_postings - 1))].text_freq);
}

test "persistent text rebuild skips repeated low-frequency dense all-doc top-hit candidates" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage_mod.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    const doc_count = persistent_all_docs_synthesis_min_postings;
    var nodes = std.ArrayList(graph_mod.Node).empty;
    defer {
        for (nodes.items) |node| std.testing.allocator.free(node.text);
        nodes.deinit(std.testing.allocator);
    }
    try nodes.ensureTotalCapacity(std.testing.allocator, doc_count);
    var id: u64 = 1;
    while (id <= doc_count) : (id += 1) {
        const text = if (id <= persistent_term_top_hit_capacity)
            try std.fmt.allocPrint(std.testing.allocator, "variable variable variable variable variable variable variable variable high {d}", .{id})
        else
            try std.fmt.allocPrint(std.testing.allocator, "variable low {d}", .{id});
        errdefer std.testing.allocator.free(text);
        nodes.appendAssumeCapacity(.{ .id = .fromInt(id), .kind = .task, .text = text });
    }
    try store.appendNodesBatch(nodes.items);

    const runs_base_path = try textPostingRunsBasePath(std.testing.allocator, store);
    defer std.testing.allocator.free(runs_base_path);
    const rebuild = try rebuildPersistentTextCatalogWithTimingsForBench(std.testing.allocator, store, runs_base_path);
    const timings = rebuild.timings;
    try std.testing.expectEqual(doc_count, timings.run_derived_dense_records);
    try std.testing.expectEqual(doc_count, timings.run_derived_top_hit_dense_scan_records);
    try std.testing.expect(timings.run_derived_top_hit_candidate_evals < doc_count);
    try std.testing.expectEqual(persistent_term_top_hit_capacity + 1, timings.run_derived_top_hit_candidate_evals);
    try std.testing.expectEqual(timings.run_derived_top_hit_candidate_evals, timings.run_derived_top_hit_dense_candidate_evals);
    try std.testing.expectEqual(timings.run_derived_top_hit_doc_reads, timings.run_derived_top_hit_dense_doc_reads);
    try std.testing.expectEqual(doc_count - timings.run_derived_top_hit_dense_candidate_evals, timings.run_derived_top_hit_dense_freq_bound_skips);
    try std.testing.expect(timings.run_derived_top_hit_dense_freq_bound_skip_runs > 0);
    try std.testing.expect(timings.run_derived_top_hit_dense_freq_bound_skip_runs < timings.run_derived_top_hit_dense_freq_bound_skips);
    try std.testing.expectEqual(@as(u64, 0), timings.run_derived_top_hit_regular_candidate_evals);
    try std.testing.expectEqual(@as(u64, 0), timings.run_derived_top_hit_regular_doc_reads);
    try std.testing.expectEqual(@as(u64, 0), timings.run_derived_top_hit_virtual_candidate_evals);
    try std.testing.expectEqual(@as(u64, 0), timings.run_derived_top_hit_virtual_doc_reads);
}

fn allocMultiDenseTestText(allocator: std.mem.Allocator, id: u64) ![]u8 {
    var text = std.ArrayList(u8).empty;
    errdefer text.deinit(allocator);

    try text.appendSlice(allocator, if (id <= persistent_term_top_hit_capacity) "sharedalpha sharedalpha" else "sharedalpha");
    try text.appendSlice(allocator, if ((id & 1) == 0) " sharedbeta sharedbeta" else " sharedbeta");
    const suffix = try std.fmt.allocPrint(allocator, " doc{d}", .{id});
    defer allocator.free(suffix);
    try text.appendSlice(allocator, suffix);
    return try text.toOwnedSlice(allocator);
}

test "persistent text rebuild shares doc stats scan across dense all-doc top-hit terms" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage_mod.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    const doc_count = persistent_all_docs_synthesis_min_postings;
    var nodes = std.ArrayList(graph_mod.Node).empty;
    defer {
        for (nodes.items) |node| std.testing.allocator.free(node.text);
        nodes.deinit(std.testing.allocator);
    }
    try nodes.ensureTotalCapacity(std.testing.allocator, doc_count);
    var id: u64 = 1;
    while (id <= doc_count) : (id += 1) {
        const text = try allocMultiDenseTestText(std.testing.allocator, id);
        errdefer std.testing.allocator.free(text);
        nodes.appendAssumeCapacity(.{ .id = .fromInt(id), .kind = .task, .text = text });
    }
    try store.appendNodesBatch(nodes.items);

    const runs_base_path = try textPostingRunsBasePath(std.testing.allocator, store);
    defer std.testing.allocator.free(runs_base_path);
    const rebuild = try rebuildPersistentTextCatalogWithTimingsForBench(std.testing.allocator, store, runs_base_path);
    const timings = rebuild.timings;
    try std.testing.expectEqual(@as(u64, 2), timings.run_derived_dense_terms);
    try std.testing.expectEqual(2 * doc_count, timings.run_derived_dense_records);
    try std.testing.expectEqual(2 * doc_count, timings.run_derived_top_hit_dense_scan_records);
    try std.testing.expectEqual(4 * persistent_term_top_hit_capacity, timings.run_derived_top_hit_dense_candidate_evals);
    try std.testing.expectEqual(@as(u64, 0), timings.run_derived_top_hit_dense_freq_bound_skips);
    try std.testing.expectEqual(@as(u64, 0), timings.run_derived_top_hit_dense_freq_bound_skip_runs);
    try std.testing.expectEqual(doc_count, timings.run_derived_top_hit_dense_doc_reads);
}

test "dense all-doc frequency size stats match separate estimators" {
    const freqs = [_]u16{ 1, 1, 2, 3, 3, 3, 8, 8, 9, 32, 32, 32, 32 };
    const stats = try denseAllDocsFreqStreamSizeStatsForFreqs(&freqs);

    try std.testing.expectEqual(try denseAllDocsFreqPackedBytesForFreqs(&freqs), stats.packed_bytes);
    try std.testing.expectEqual(try denseAllDocsFreqRleBytesForFreqs(&freqs), stats.rle_bytes);
    try std.testing.expectEqual(try denseAllDocsFreqBitpackedBytesForFreqs(&freqs), stats.bitpacked_bytes);
    try std.testing.expectEqual(@as(u64, 6), stats.rle_run_count);
    try std.testing.expectEqual(@as(u32, 32), stats.max_freq);
}

test "text index ignores non-active graph nodes" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();

    const active_id = try graph.addNode(.task, "active invalid record fix");
    const deleted_id = try graph.addNode(.task, "deleted invalid record fix");
    const stale_id = try graph.addNode(.task, "stale invalid record fix");
    for (graph.nodes.items) |*node| {
        if (node.id == deleted_id) node.status = .deleted;
        if (node.id == stale_id) node.status = .stale;
    }

    var index = try TextIndex.buildFromGraph(std.testing.allocator, &graph);
    defer index.deinit();

    var hits = try index.search("invalid record", .{ .limit = 10 });
    defer hits.deinit(std.testing.allocator);

    try std.testing.expect(hits.items.len >= 1);
    for (hits.items) |hit| {
        try std.testing.expect(hit.node_id != deleted_id);
        try std.testing.expect(hit.node_id != stale_id);
    }
    try std.testing.expectEqual(active_id, hits.items[0].node_id);
}

test "text index tie-breaks equal scores by node id" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();

    const first = core.NodeId.fromInt(10);
    const second = core.NodeId.fromInt(2);
    try graph.addNodeWithId(first, .task, "same term");
    try graph.addNodeWithId(second, .task, "same term");

    var index = try TextIndex.buildFromGraph(std.testing.allocator, &graph);
    defer index.deinit();

    var hits = try index.search("same", .{ .limit = 10 });
    defer hits.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), hits.items.len);
    try std.testing.expectEqual(second, hits.items[0].node_id);
    try std.testing.expectEqual(first, hits.items[1].node_id);
}

test "text index build and search enforce immediate deadline" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    _ = try graph.addNode(.task, "edge index repair");

    try std.testing.expectError(
        core.Error.BudgetExceeded,
        TextIndex.buildFromGraphDeadline(std.testing.allocator, &graph, .immediate),
    );

    var index = try TextIndex.buildFromGraph(std.testing.allocator, &graph);
    defer index.deinit();
    try std.testing.expectError(
        core.Error.BudgetExceeded,
        index.search("edge", .{ .limit = 5, .deadline = .immediate }),
    );
}

test "searchText rebuilds from persistent store" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage_mod.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();
    try store.appendNode(.{ .id = .fromInt(1), .kind = .file, .text = "src/storage.zig" });
    try store.appendNode(.{ .id = .fromInt(2), .kind = .function, .text = "readEdgeIndexRecordsByNode" });

    var hits = try searchText(std.testing.allocator, store, "edge index node", .{ .limit = 5 });
    defer hits.deinit(std.testing.allocator);

    try std.testing.expect(hits.items.len >= 1);
    try std.testing.expectEqual(core.NodeId.fromInt(2), hits.items[0].node_id);
}

test "searchText serves batch-appended tail through published catalog merge" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage_mod.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();
    try store.appendNode(.{ .id = .fromInt(1), .kind = .file, .text = "shared corpus token alpha" });
    _ = try rebuildPersistentTextCatalog(std.testing.allocator, store);

    // the daemon group-commit path appends tails as node batches
    try store.appendNodesBatch(&.{
        .{ .id = .fromInt(2), .kind = .observation, .text = "batchtailmarker shared corpus beta" },
        .{ .id = .fromInt(3), .kind = .observation, .text = "batchtailmarker shared corpus gamma" },
    });

    var query_tokens = try tokenizer_mod.tokenize(std.testing.allocator, "batchtailmarker", .{});
    defer query_tokens.deinit();
    var merged = (try QueryExecutionOps.searchPersistentWithAppendedTail(
        std.testing.allocator,
        store,
        "batchtailmarker",
        query_tokens.items.items,
        .{ .limit = 5 },
    )) orelse return error.TestUnexpectedResult;
    defer merged.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), merged.items.len);
}

test "searchText serves appended tail through published catalog merge" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage_mod.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();
    try store.appendNode(.{ .id = .fromInt(1), .kind = .file, .text = "shared corpus token alpha" });
    try store.appendNode(.{ .id = .fromInt(2), .kind = .function, .text = "shared corpus token beta" });
    _ = try rebuildPersistentTextCatalog(std.testing.allocator, store);

    try store.appendNode(.{ .id = .fromInt(3), .kind = .observation, .text = "tailmarker shared corpus gamma" });

    // The catalog is stale for the appended node, and the incremental merge
    // itself (not the store-scan fallback) must serve it.
    var query_tokens = try tokenizer_mod.tokenize(std.testing.allocator, "tailmarker shared", .{});
    defer query_tokens.deinit();
    var merged = (try QueryExecutionOps.searchPersistentWithAppendedTail(
        std.testing.allocator,
        store,
        "tailmarker shared",
        query_tokens.items.items,
        .{ .limit = 5 },
    )) orelse return error.TestUnexpectedResult;
    defer merged.deinit(std.testing.allocator);
    try std.testing.expect(merged.items.len >= 3);
    try std.testing.expectEqual(core.NodeId.fromInt(3), merged.items[0].node_id);

    var hits = try searchText(std.testing.allocator, store, "tailmarker", .{ .limit = 5 });
    defer hits.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), hits.items.len);
    try std.testing.expectEqual(core.NodeId.fromInt(3), hits.items[0].node_id);

    // Changing searchable metadata invalidates the tail-merge eligibility
    // proof; the path must decline rather than serve wrong metadata scores.
    try store.setNodeStringProperty(std.testing.allocator, .fromInt(1), "name", "renamed alpha");
    const declined = try QueryExecutionOps.searchPersistentWithAppendedTail(
        std.testing.allocator,
        store,
        "tailmarker shared",
        query_tokens.items.items,
        .{ .limit = 5 },
    );
    try std.testing.expect(declined == null);
}

test "persistent text search indexes node name and summary metadata" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage_mod.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();
    try store.appendNode(.{ .id = .fromInt(1), .kind = .observation, .text = "physical body token" });
    try store.setNodeStringProperty(std.testing.allocator, .fromInt(1), "name", "logicalrarelabel");
    try store.setNodeStringProperty(std.testing.allocator, .fromInt(1), "summary", "summary uniquedigest");

    const meta = try rebuildPersistentTextCatalog(std.testing.allocator, store);
    try std.testing.expect(meta.searchable_metadata_digest != 0);

    var name_hits = try searchText(std.testing.allocator, store, "logicalrarelabel", .{ .limit = 5 });
    defer name_hits.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), name_hits.items.len);
    try std.testing.expectEqual(core.NodeId.fromInt(1), name_hits.items[0].node_id);

    var summary_hits = try searchText(std.testing.allocator, store, "uniquedigest", .{ .limit = 5 });
    defer summary_hits.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), summary_hits.items.len);
    try std.testing.expectEqual(core.NodeId.fromInt(1), summary_hits.items[0].node_id);

    try store.setNodeStringProperty(std.testing.allocator, .fromInt(1), "summary", "summary replacedtoken");
    try std.testing.expect(try persistentTextCatalogQuickStaleDeadline(std.testing.allocator, store, .none));

    var updated_hits = try searchText(std.testing.allocator, store, "replacedtoken", .{ .limit = 5 });
    defer updated_hits.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), updated_hits.items.len);
    try std.testing.expectEqual(core.NodeId.fromInt(1), updated_hits.items[0].node_id);

    var old_hits = try searchText(std.testing.allocator, store, "uniquedigest", .{ .limit = 5 });
    defer old_hits.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), old_hits.items.len);
}

test "persistent text catalog detects searchable metadata values swapped between owners" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage_mod.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();
    try store.appendNode(.{ .id = .fromInt(1), .kind = .observation, .text = "first physical body" });
    try store.appendNode(.{ .id = .fromInt(2), .kind = .observation, .text = "second physical body" });
    try store.setNodeStringProperty(std.testing.allocator, .fromInt(1), "name", "alphaswapowner");
    try store.setNodeStringProperty(std.testing.allocator, .fromInt(2), "name", "betaswapowner");
    _ = try rebuildPersistentTextCatalog(std.testing.allocator, store);
    try std.testing.expect(!try persistentTextCatalogQuickStale(std.testing.allocator, store));

    // The multiset of owners, keys, and values is unchanged.  A metadata
    // anchor that combines those fields independently cannot see this swap
    // and would keep serving postings for the old owner.
    try store.setNodeStringProperty(std.testing.allocator, .fromInt(1), "name", "betaswapowner");
    try store.setNodeStringProperty(std.testing.allocator, .fromInt(2), "name", "alphaswapowner");
    try std.testing.expect(try persistentTextCatalogQuickStale(std.testing.allocator, store));

    var alpha_hits = try searchText(std.testing.allocator, store, "alphaswapowner", .{ .limit = 5 });
    defer alpha_hits.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), alpha_hits.items.len);
    try std.testing.expectEqual(core.NodeId.fromInt(2), alpha_hits.items[0].node_id);

    var beta_hits = try searchText(std.testing.allocator, store, "betaswapowner", .{ .limit = 5 });
    defer beta_hits.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), beta_hits.items.len);
    try std.testing.expectEqual(core.NodeId.fromInt(1), beta_hits.items[0].node_id);
}

test "searchText persistent search rolls back allocation failures" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage_mod.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();
    try store.appendNode(.{ .id = .fromInt(1), .kind = .task, .text = "storage index repair" });
    try store.appendNode(.{ .id = .fromInt(2), .kind = .file, .text = "storage index reader" });
    _ = try rebuildPersistentTextCatalog(std.testing.allocator, store);

    var fail_offset: usize = 0;
    var saw_failure = false;
    var saw_success = false;
    while (fail_offset < 120) : (fail_offset += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = fail_offset });
        var hits = searchText(failing.allocator(), store, "storage index", .{ .limit = 2 }) catch |err| switch (err) {
            error.OutOfMemory => {
                saw_failure = true;
                continue;
            },
            else => |e| return e,
        };
        errdefer hits.deinit(failing.allocator());
        const induced_failure = failing.has_induced_failure;
        saw_success = true;
        try std.testing.expect(hits.items.len >= 1);
        hits.deinit(failing.allocator());
        if (saw_failure and !induced_failure) break;
    }
    try std.testing.expect(saw_failure);
    try std.testing.expect(saw_success);
}

test "searchText enforces immediate deadline before rebuilding persistent catalog" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage_mod.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();
    try store.appendNode(.{ .id = .fromInt(1), .kind = .task, .text = "edge index repair" });

    const text_meta_path = try textMetaPath(std.testing.allocator, store);
    defer std.testing.allocator.free(text_meta_path);
    try std.testing.expectError(
        core.Error.BudgetExceeded,
        searchText(std.testing.allocator, store, "edge", .{ .limit = 5, .deadline = .immediate }),
    );
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().openFile(std.testing.io, text_meta_path, .{}));
}

test "searchText rejects invalid persistent search scoring options" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage_mod.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();
    try store.appendNode(.{ .id = .fromInt(1), .kind = .task, .text = "invalid bm25 params" });

    try std.testing.expectError(core.Error.Unsupported, searchText(std.testing.allocator, store, "invalid", .{ .params = .{ .k1 = std.math.nan(f32) } }));
    try std.testing.expectError(core.Error.Unsupported, searchText(std.testing.allocator, store, "invalid", .{ .params = .{ .b = std.math.inf(f32) } }));
    try std.testing.expectError(core.Error.Unsupported, searchText(std.testing.allocator, store, "invalid", .{ .min_score = std.math.nan(f32) }));
}

test "textQueryPlanStats rebuilds and reports persistent postings pressure" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage_mod.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();
    try store.appendNode(.{ .id = .fromInt(1), .kind = .task, .text = "parseInvalidRecord parser invalid record" });
    try store.appendNode(.{ .id = .fromInt(2), .kind = .file, .text = "parseInvalidRecord" });
    try store.appendNode(.{ .id = .fromInt(3), .kind = .file, .text = "record" });

    const stats = try textQueryPlanStats(std.testing.allocator, store, "parseInvalidRecord", .{ .limit = 8 });
    try std.testing.expectEqual(@as(usize, 5), stats.query_terms);
    try std.testing.expectEqual(@as(usize, 4), stats.unique_query_terms);
    try std.testing.expectEqual(@as(usize, 4), stats.matched_terms);
    try std.testing.expectEqual(@as(u64, 9), stats.postings_count_total);
    try std.testing.expectEqual(@as(u64, 3), stats.max_postings_count);
}

test "searchText applies kind filter and zero limit on persistent store" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage_mod.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();
    try store.appendNode(.{ .id = .fromInt(1), .kind = .file, .text = "storage index" });
    try store.appendNode(.{ .id = .fromInt(2), .kind = .task, .text = "storage index repair" });

    var none = try searchText(std.testing.allocator, store, "storage", .{ .limit = 0 });
    defer none.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), none.items.len);

    var hits = try searchText(std.testing.allocator, store, "storage", .{ .kind_filter = .task, .limit = 10 });
    defer hits.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), hits.items.len);
    try std.testing.expectEqual(core.NodeId.fromInt(2), hits.items[0].node_id);
}

test "searchText persistent enforces postings scan budget" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage_mod.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();
    try store.appendNode(.{ .id = .fromInt(1), .kind = .task, .text = "storage repair" });
    try store.appendNode(.{ .id = .fromInt(2), .kind = .task, .text = "storage index" });

    try std.testing.expectError(core.Error.BudgetExceeded, searchText(std.testing.allocator, store, "storage", .{ .limit = 10, .max_postings_scanned = 1 }));

    var hits = try searchText(std.testing.allocator, store, "storage", .{ .limit = 10, .max_postings_scanned = 2 });
    defer hits.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), hits.items.len);
}

test "searchText persistent high-frequency single term uses top hit cache under postings budget" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage_mod.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    var nodes = std.ArrayList(graph_mod.Node).empty;
    defer {
        for (nodes.items) |node| std.testing.allocator.free(node.text);
        nodes.deinit(std.testing.allocator);
    }
    try nodes.ensureTotalCapacity(std.testing.allocator, persistent_term_top_hit_min_postings);
    var id: u64 = 1;
    while (id <= persistent_term_top_hit_min_postings) : (id += 1) {
        const text = if (id <= 8)
            try std.fmt.allocPrint(std.testing.allocator, "common common", .{})
        else
            try std.fmt.allocPrint(std.testing.allocator, "common common cache filler alpha beta gamma delta epsilon node {d}", .{id});
        errdefer std.testing.allocator.free(text);
        nodes.appendAssumeCapacity(.{
            .id = .fromInt(id),
            .kind = .task,
            .text = text,
        });
    }
    try store.appendNodesBatch(nodes.items);
    _ = try rebuildPersistentTextCatalog(std.testing.allocator, store);

    const doc_count = try readPersistentTextDocCount(std.testing.allocator, store);
    try std.testing.expectEqual(@as(u64, persistent_term_top_hit_min_postings), doc_count);
    var catalog = try PersistentPostingCatalog.open(std.testing.allocator, store, doc_count);
    defer catalog.deinit();
    const lookup = (try catalog.findTermEntry("common")) orelse return error.InvalidRecord;
    try std.testing.expectEqual(@as(?u32, 2), termEntryVirtualAllDocsTextFreq(lookup.entry));
    try std.testing.expectEqual(doc_count, lookup.entry.postings_count);
    try std.testing.expectEqual(@as(u64, 0), try publishedPostingBlockCountForEntry(lookup.entry, catalog.blocks_header.block_size));

    // This test checks virtual all-doc decoding; public posting validation is covered separately.
    var postings = try readPersistentTermPostingsUnchecked(std.testing.allocator, store, "common", persistent_term_top_hit_min_postings);
    defer postings.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, persistent_term_top_hit_min_postings), postings.items.len);
    for (postings.items, 0..) |posting, index| {
        try std.testing.expectEqual(@as(u64, @intCast(index + 1)), posting.doc_id);
        try std.testing.expectEqual(@as(u32, 2), posting.text_freq);
        try std.testing.expectEqual(@as(u32, 0), posting.kind_freq);
    }

    const estimate = try estimatePersistentPostingCompression(std.testing.allocator, store);
    try std.testing.expect(estimate.virtual_all_docs_term_count >= 1);
    try std.testing.expect(estimate.virtual_all_docs_saved_bytes > 0);

    var hits = try searchText(std.testing.allocator, store, "common", .{ .limit = 8, .max_postings_scanned = 0 });
    defer hits.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 8), hits.items.len);
    var pos: usize = 0;
    while (pos < hits.items.len) : (pos += 1) {
        try std.testing.expectEqual(@as(u64, @intCast(pos + 1)), hits.items[pos].node_id.toInt());
        if (pos != 0) {
            try std.testing.expect(hits.items[pos - 1].score >= hits.items[pos].score);
        }
    }

    var exact_hits = try searchText(std.testing.allocator, store, "common", .{
        .limit = 8,
        .params = .{ .k1 = 1.21 },
        .max_postings_scanned = 0,
    });
    defer exact_hits.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 8), exact_hits.items.len);

    var uncached = searchText(std.testing.allocator, store, "common", .{
        .limit = 8,
        .params = .{ .b = 0 },
        .max_postings_scanned = 0,
    }) catch |err| switch (err) {
        core.Error.BudgetExceeded => return,
        else => |e| return e,
    };
    uncached.deinit(std.testing.allocator);
    return error.TestExpectedError;
}

test "searchText persistent high-frequency multi term uses top hit candidates under postings budget" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage_mod.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    var nodes = std.ArrayList(graph_mod.Node).empty;
    defer {
        for (nodes.items) |node| std.testing.allocator.free(node.text);
        nodes.deinit(std.testing.allocator);
    }
    try nodes.ensureTotalCapacity(std.testing.allocator, persistent_term_top_hit_min_postings);
    var id: u64 = 1;
    while (id <= persistent_term_top_hit_min_postings) : (id += 1) {
        const text = try std.fmt.allocPrint(std.testing.allocator, "common shared node {d}", .{id});
        errdefer std.testing.allocator.free(text);
        nodes.appendAssumeCapacity(.{
            .id = .fromInt(id),
            .kind = .task,
            .text = text,
        });
    }
    try store.appendNodesBatch(nodes.items);
    _ = try rebuildPersistentTextCatalog(std.testing.allocator, store);

    var hits = try searchText(std.testing.allocator, store, "common shared", .{ .limit = 8, .max_postings_scanned = 0 });
    defer hits.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 8), hits.items.len);
    var pos: usize = 0;
    while (pos < hits.items.len) : (pos += 1) {
        try std.testing.expect(hits.items[pos].node_id.toInt() >= 1);
        try std.testing.expect(hits.items[pos].node_id.toInt() <= persistent_term_top_hit_min_postings);
        if (pos != 0) {
            try std.testing.expect(hits.items[pos - 1].score >= hits.items[pos].score);
        }
    }

    var uncached = searchText(std.testing.allocator, store, "common shared", .{
        .limit = 8,
        .params = .{ .k1 = 1.21 },
        .max_postings_scanned = 0,
    }) catch |err| switch (err) {
        core.Error.BudgetExceeded => return,
        else => |e| return e,
    };
    uncached.deinit(std.testing.allocator);
    return error.TestExpectedError;
}

test "searchText persistent CJK multi term top hit candidates preserve bigram filter" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage_mod.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    var nodes = std.ArrayList(graph_mod.Node).empty;
    defer {
        for (nodes.items) |node| std.testing.allocator.free(node.text);
        nodes.deinit(std.testing.allocator);
    }
    try nodes.ensureTotalCapacity(std.testing.allocator, persistent_term_top_hit_min_postings);
    const target_count: u64 = 8;
    var id: u64 = 1;
    while (id <= persistent_term_top_hit_min_postings) : (id += 1) {
        const text = if (id <= target_count)
            try std.fmt.allocPrint(std.testing.allocator, "错误记录 common shared target {d}", .{id})
        else
            try std.fmt.allocPrint(std.testing.allocator, "错误 日志 记录 common shared filler {d}", .{id});
        errdefer std.testing.allocator.free(text);
        nodes.appendAssumeCapacity(.{
            .id = .fromInt(id),
            .kind = .task,
            .text = text,
        });
    }
    try store.appendNodesBatch(nodes.items);
    _ = try rebuildPersistentTextCatalog(std.testing.allocator, store);

    var hits = try searchText(std.testing.allocator, store, "错误记录 common shared", .{
        .limit = 8,
        .max_postings_scanned = 64,
    });
    defer hits.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 8), hits.items.len);
    for (hits.items) |hit| {
        try std.testing.expect(hit.node_id.toInt() >= 1);
        try std.testing.expect(hit.node_id.toInt() <= target_count);
    }

    var uncached = searchText(std.testing.allocator, store, "错误记录 common shared", .{
        .limit = 8,
        .params = .{ .k1 = 1.21 },
        .max_postings_scanned = 0,
    }) catch |err| switch (err) {
        core.Error.BudgetExceeded => return,
        else => |e| return e,
    };
    uncached.deinit(std.testing.allocator);
    return error.TestExpectedError;
}

test "searchText persistent CJK medium multi term anchors below top-hit threshold" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage_mod.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    var nodes = std.ArrayList(graph_mod.Node).empty;
    defer {
        for (nodes.items) |node| std.testing.allocator.free(node.text);
        nodes.deinit(std.testing.allocator);
    }
    const matching_docs = persistent_term_top_hit_min_postings - 8;
    try nodes.ensureTotalCapacity(std.testing.allocator, matching_docs);
    var id: u64 = 1;
    while (id <= matching_docs) : (id += 1) {
        const text = try std.fmt.allocPrint(std.testing.allocator, "错误记录 medium cjk candidate {d}", .{id});
        errdefer std.testing.allocator.free(text);
        nodes.appendAssumeCapacity(.{
            .id = .fromInt(id),
            .kind = .task,
            .text = text,
        });
    }
    try store.appendNodesBatch(nodes.items);
    _ = try rebuildPersistentTextCatalog(std.testing.allocator, store);

    var hits = try searchText(std.testing.allocator, store, "错误记录", .{
        .limit = 8,
        .max_postings_scanned = matching_docs,
    });
    defer hits.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 8), hits.items.len);
    for (hits.items) |hit| {
        try std.testing.expect(hit.node_id.toInt() >= 1);
        try std.testing.expect(hit.node_id.toInt() <= matching_docs);
    }
}

test "searchText persistent mixed-frequency multi term combines exact and top hit candidates" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage_mod.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    var nodes = std.ArrayList(graph_mod.Node).empty;
    defer {
        for (nodes.items) |node| std.testing.allocator.free(node.text);
        nodes.deinit(std.testing.allocator);
    }
    try nodes.ensureTotalCapacity(std.testing.allocator, persistent_term_top_hit_min_postings);
    const target_id: u64 = persistent_term_top_hit_min_postings;
    var id: u64 = 1;
    while (id <= persistent_term_top_hit_min_postings) : (id += 1) {
        const text = if (id == target_id)
            try std.fmt.allocPrint(std.testing.allocator, "common uniquetarget4096 node {d}", .{id})
        else
            try std.fmt.allocPrint(std.testing.allocator, "common filler node {d}", .{id});
        errdefer std.testing.allocator.free(text);
        nodes.appendAssumeCapacity(.{
            .id = .fromInt(id),
            .kind = .task,
            .text = text,
        });
    }
    try store.appendNodesBatch(nodes.items);
    _ = try rebuildPersistentTextCatalog(std.testing.allocator, store);

    var hits = try searchText(std.testing.allocator, store, "common uniquetarget4096", .{
        .limit = 8,
        .max_postings_scanned = 8,
    });
    defer hits.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 8), hits.items.len);
    var found_target = false;
    for (hits.items) |hit| {
        if (hit.node_id.toInt() == target_id) found_target = true;
    }
    try std.testing.expect(found_target);

    var uncached = searchText(std.testing.allocator, store, "common uniquetarget4096", .{
        .limit = 8,
        .params = .{ .k1 = 1.21 },
        .max_postings_scanned = 8,
    }) catch |err| switch (err) {
        core.Error.BudgetExceeded => return,
        else => |e| return e,
    };
    uncached.deinit(std.testing.allocator);
    return error.TestExpectedError;
}

test "persistent multi term kind filter fails closed before global top-hit truncation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage_mod.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    var node_id: u64 = 1;
    while (node_id <= persistent_term_top_hit_min_postings) : (node_id += 1) {
        try store.appendNode(.{ .id = .fromInt(node_id), .kind = .file, .text = "common shared" });
    }
    const task_id = node_id;
    try store.appendNode(.{ .id = .fromInt(task_id), .kind = .task, .text = "common shared" });
    _ = try rebuildPersistentTextCatalog(std.testing.allocator, store);

    // The global top-hit side stream contains only the lower-id file rows.
    // A filtered query must not turn that truncated global candidate set into
    // a successful empty answer; with an insufficient exact-scan budget it
    // fails closed instead.
    try std.testing.expectError(core.Error.BudgetExceeded, searchText(std.testing.allocator, store, "common shared", .{
        .kind_filter = .task,
        .limit = 1,
        .max_postings_scanned = 1,
    }));

    const exact_budget: usize = @intCast((persistent_term_top_hit_min_postings + 1) * 2);
    var hits = try searchText(std.testing.allocator, store, "common shared", .{
        .kind_filter = .task,
        .limit = 1,
        .max_postings_scanned = exact_budget,
    });
    defer hits.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), hits.items.len);
    try std.testing.expectEqual(core.NodeId.fromInt(task_id), hits.items[0].node_id);
}

test "persistent uniform kind filter safely reuses global multi term top hits" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage_mod.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    var node_id: u64 = 1;
    while (node_id <= persistent_term_top_hit_min_postings) : (node_id += 1) {
        try store.appendNode(.{ .id = .fromInt(node_id), .kind = .file, .text = "common shared" });
    }
    _ = try rebuildPersistentTextCatalog(std.testing.allocator, store);

    var hits = try searchText(std.testing.allocator, store, "common shared", .{
        .kind_filter = .file,
        .limit = 8,
        .max_postings_scanned = 1,
    });
    defer hits.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 8), hits.items.len);
    for (hits.items) |hit| try std.testing.expectEqual(core.NodeKind.file, hit.kind);
}

test "searchText persistent single term skips low impact posting blocks" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage_mod.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    var high_text = std.ArrayList(u8).empty;
    defer high_text.deinit(std.testing.allocator);
    var repeat: usize = 0;
    while (repeat < test_high_impact_repeated_term_count) : (repeat += 1) {
        if (repeat != 0) try high_text.append(std.testing.allocator, ' ');
        try high_text.appendSlice(std.testing.allocator, "edge");
    }

    try appendRepeatedTextTestNodes(std.testing.allocator, store, 1, persistent_posting_block_size, .task, high_text.items);
    const low_start = persistent_posting_block_size + 1;
    const low_end = persistent_posting_block_size * 2 + 1;
    try appendRepeatedTextTestNodes(std.testing.allocator, store, low_start, low_end, .task, "edge");
    try store.appendNode(.{ .id = .fromInt(low_end + 1), .kind = .task, .text = "unrelated" });
    _ = try rebuildPersistentTextCatalog(std.testing.allocator, store);

    var hits = try searchText(std.testing.allocator, store, "edge", .{ .limit = 1, .max_postings_scanned = persistent_posting_block_capacity });
    defer hits.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), hits.items.len);
    try std.testing.expectEqual(core.NodeId.fromInt(1), hits.items[0].node_id);
}

test "searchText persistent single term scans highest impact block before doc order" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage_mod.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    var high_text = std.ArrayList(u8).empty;
    defer high_text.deinit(std.testing.allocator);
    var repeat: usize = 0;
    while (repeat < test_high_impact_repeated_term_count) : (repeat += 1) {
        if (repeat != 0) try high_text.append(std.testing.allocator, ' ');
        try high_text.appendSlice(std.testing.allocator, "edge");
    }

    try appendRepeatedTextTestNodes(std.testing.allocator, store, 1, persistent_posting_block_size, .task, "edge");
    try store.appendNode(.{ .id = .fromInt(persistent_posting_block_size + 1), .kind = .task, .text = high_text.items });
    try store.appendNode(.{ .id = .fromInt(persistent_posting_block_size + 2), .kind = .task, .text = "unrelated" });
    _ = try rebuildPersistentTextCatalog(std.testing.allocator, store);

    var hits = try searchText(std.testing.allocator, store, "edge", .{ .limit = 1, .max_postings_scanned = persistent_posting_block_capacity });
    defer hits.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), hits.items.len);
    try std.testing.expectEqual(core.NodeId.fromInt(persistent_posting_block_size + 1), hits.items[0].node_id);
}

test "persistent text streaming budget stops before decoding next posting" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage_mod.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();
    try store.appendNode(.{ .id = .fromInt(1), .kind = .task, .text = "storage repair" });
    try store.appendNode(.{ .id = .fromInt(2), .kind = .task, .text = "storage index" });
    _ = try rebuildPersistentTextCatalog(std.testing.allocator, store);

    const terms_path = try textTermsPath(std.testing.allocator, store);
    defer std.testing.allocator.free(terms_path);
    var terms_file = try std.Io.Dir.cwd().openFile(std.testing.io, terms_path, .{});
    defer terms_file.close(std.testing.io);
    const terms_header = try readTextTermsHeaderFromFile(store, terms_file);

    const postings_path = try textPostingsPath(std.testing.allocator, store);
    defer std.testing.allocator.free(postings_path);
    var postings_file = try std.Io.Dir.cwd().openFile(std.testing.io, postings_path, .{ .mode = .read_write });
    defer postings_file.close(std.testing.io);

    var pos: u64 = 0;
    var corrupted = false;
    while (pos < terms_header.term_count) : (pos += 1) {
        const entry = try readTextTermEntryAt(store, terms_file, terms_header, pos);
        if (entry.term_len != "storage".len or entry.postings_count < 2) continue;
        if (!try termEntryMatches(store, terms_file, terms_header, pos, entry, "storage")) continue;
        const second_offset = try textPostingOffsetAfterSkipping(store, postings_file, entry.postings_offset, 1);
        const invalid_delta: [1]u8 = .{0};
        try postings_file.writePositionalAll(std.testing.io, &invalid_delta, try textPostingRecordOffset(second_offset));
        corrupted = true;
        break;
    }
    try std.testing.expect(corrupted);

    var postings_scanned: usize = 0;
    var context = TestPostingCountContext{};
    try std.testing.expectError(
        core.Error.BudgetExceeded,
        forEachPersistentTermPostingForSearch(
            std.testing.allocator,
            store,
            "storage",
            .{ .limit = 10, .max_postings_scanned = 1 },
            &postings_scanned,
            &context,
            countStreamingPosting,
        ),
    );
    try std.testing.expectEqual(@as(usize, 1), postings_scanned);
    try std.testing.expectEqual(@as(usize, 1), context.count);
}

test "persistent text posting block scan exposes computed doc ranges and block-max scoring bounds" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage_mod.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();
    try store.appendNode(.{ .id = .fromInt(1), .kind = .task, .text = "storage" });
    try store.appendNode(.{ .id = .fromInt(2), .kind = .task, .text = "storage storage" });
    try store.appendNode(.{ .id = .fromInt(3), .kind = .task, .text = "storage storage storage" });
    _ = try rebuildPersistentTextCatalog(std.testing.allocator, store);

    const terms_path = try textTermsPath(std.testing.allocator, store);
    defer std.testing.allocator.free(terms_path);
    var terms_file = try std.Io.Dir.cwd().openFile(std.testing.io, terms_path, .{});
    defer terms_file.close(std.testing.io);
    const terms_header = try readTextTermsHeaderFromFile(store, terms_file);

    const postings_path = try textPostingsPath(std.testing.allocator, store);
    defer std.testing.allocator.free(postings_path);

    var pos: u64 = 0;
    var storage_entry: ?TextTermEntry = null;
    while (pos < terms_header.term_count) : (pos += 1) {
        const entry = try readTextTermEntryAt(store, terms_file, terms_header, pos);
        if (entry.term_len != "storage".len) continue;
        if (!try termEntryMatches(store, terms_file, terms_header, pos, entry, "storage")) continue;
        storage_entry = entry;
        break;
    }
    const entry = storage_entry orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 3), entry.postings_count);
    {
        var postings_view = try TextPostingsFileView.open(store, postings_path);
        defer postings_view.deinit();
        const postings_header = try postings_view.readHeader();
        if (entry.postings_offset > postings_header.body_bytes) return error.TestUnexpectedResult;

        var context = TestPostingBlockContext{ .allocator = std.testing.allocator };
        defer context.deinit();
        try std.testing.expectError(
            error.InvalidRecord,
            scanPersistentPostingBlocks(&postings_view, entry.postings_offset, entry.postings_count, 3, 0, .none, &context, collectPostingBlock),
        );
        _ = try scanPersistentPostingBlocks(&postings_view, entry.postings_offset, entry.postings_count, 3, persistent_posting_block_size, .none, &context, collectPostingBlock);

        try std.testing.expectEqual(@as(usize, 1), context.blocks.items.len);
        try std.testing.expectEqual(entry.postings_offset, context.blocks.items[0].posting_offset);
        try std.testing.expectEqual(@as(u64, 3), context.blocks.items[0].posting_count);
        try std.testing.expectEqual(@as(u64, 1), context.blocks.items[0].first_doc_id);
        try std.testing.expectEqual(@as(u64, 3), context.blocks.items[0].last_doc_id);
        try std.testing.expectEqual(@as(f32, 12.0), context.blocks.items[0].max_weighted_tf);
        try std.testing.expectEqual(@as(f32, 4.0), context.blocks.items[0].min_doc_len);
    }

    {
        var postings_file = try std.Io.Dir.cwd().openFile(std.testing.io, postings_path, .{ .mode = .read_write });
        defer postings_file.close(std.testing.io);
        const second_offset = try textPostingOffsetAfterSkipping(store, postings_file, entry.postings_offset, 1);
        const invalid_delta: [1]u8 = .{0};
        try postings_file.writePositionalAll(std.testing.io, &invalid_delta, try textPostingRecordOffset(second_offset));
    }

    var corrupt_view = try TextPostingsFileView.open(store, postings_path);
    defer corrupt_view.deinit();
    var scanned: usize = 0;
    var budget_context = TestPostingBlockContext{ .allocator = std.testing.allocator };
    defer budget_context.deinit();
    try std.testing.expectError(
        core.Error.BudgetExceeded,
        scanPersistentPostingBlocks(&corrupt_view, entry.postings_offset, entry.postings_count, 3, 2, .{ .search = .{
            .options = .{ .max_postings_scanned = 1 },
            .postings_scanned = &scanned,
        } }, &budget_context, collectPostingBlock),
    );
    try std.testing.expectEqual(@as(usize, 1), scanned);
    try std.testing.expectEqual(@as(usize, 0), budget_context.blocks.items.len);
}

test "persistent text posting block offsets derive from sparse checkpoints" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage_mod.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    var text_buf: [64]u8 = undefined;
    var i: u64 = 0;
    while (i < persistent_posting_block_offset_checkpoint_terms + 16) : (i += 1) {
        const text = try std.fmt.bufPrint(&text_buf, "sparsecheckpointterm{d:0>3}", .{i});
        try store.appendNode(.{ .id = .fromInt(i + 1), .kind = .task, .text = text });
    }
    _ = try rebuildPersistentTextCatalog(std.testing.allocator, store);

    const query = try std.fmt.bufPrint(&text_buf, "sparsecheckpointterm{d:0>3}", .{persistent_posting_block_offset_checkpoint_terms + 15});
    var hits = try searchText(std.testing.allocator, store, query, .{ .limit = 1 });
    defer hits.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), hits.items.len);
    try std.testing.expectEqual(core.NodeId.fromInt(persistent_posting_block_offset_checkpoint_terms + 16), hits.items[0].node_id);
}

test "persistent text posting block byte offsets derive from sparse checkpoints" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage_mod.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    var high_text = std.ArrayList(u8).empty;
    defer high_text.deinit(std.testing.allocator);
    var repeat: usize = 0;
    while (repeat < test_high_impact_repeated_term_count) : (repeat += 1) {
        if (repeat != 0) try high_text.append(std.testing.allocator, ' ');
        try high_text.appendSlice(std.testing.allocator, "edge");
    }

    const first_low_end = persistent_posting_block_size * persistent_posting_block_byte_offset_checkpoint_blocks;
    try appendRepeatedTextTestNodes(std.testing.allocator, store, 1, first_low_end, .task, "edge");
    const high_id = first_low_end + 1;
    try store.appendNode(.{ .id = .fromInt(high_id), .kind = .task, .text = high_text.items });
    const second_low_start = high_id + 1;
    const second_low_end = persistent_posting_block_size * (persistent_posting_block_byte_offset_checkpoint_blocks + 2);
    try appendRepeatedTextTestNodes(std.testing.allocator, store, second_low_start, second_low_end, .task, "edge");
    try store.appendNode(.{ .id = .fromInt(second_low_end + 1), .kind = .task, .text = "unrelated" });
    _ = try rebuildPersistentTextCatalog(std.testing.allocator, store);

    var hits = try searchText(std.testing.allocator, store, "edge", .{ .limit = 1, .max_postings_scanned = persistent_posting_block_capacity });
    defer hits.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), hits.items.len);
    try std.testing.expectEqual(core.NodeId.fromInt(high_id), hits.items[0].node_id);
}

test "searchText returns empty token queries without touching persistent indexes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage_mod.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();

    var hits = try searchText(std.testing.allocator, store, "!!! --- ...", .{ .limit = 10 });
    defer hits.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), hits.items.len);

    const meta_path = try textMetaPath(std.testing.allocator, store);
    defer std.testing.allocator.free(meta_path);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().openFile(std.testing.io, meta_path, .{}));
}

test "searchText persistent CJK Japanese Korean fallback recall" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage_mod.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();
    try store.appendNode(.{ .id = .fromInt(1), .kind = .observation, .text = "错误记录" });
    try store.appendNode(.{ .id = .fromInt(2), .kind = .observation, .text = "解析エラー" });
    try store.appendNode(.{ .id = .fromInt(3), .kind = .observation, .text = "오류기록" });
    try store.appendNode(.{ .id = .fromInt(4), .kind = .observation, .text = "오류기록" });
    try store.appendNode(.{ .id = .fromInt(5), .kind = .observation, .text = "ㅇㅗㄹㅠㄱㅣㄹㅗㄱ" });
    try store.appendNode(.{ .id = .fromInt(6), .kind = .observation, .text = "\u{ffb7}\u{ffcc}\u{ffa9}\u{ffd7}\u{ffa1}\u{ffdc}\u{ffa9}\u{ffcc}\u{ffa1}" });

    var chinese = try searchText(std.testing.allocator, store, "错误", .{ .limit = 5 });
    defer chinese.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), chinese.items.len);
    try std.testing.expectEqual(core.NodeId.fromInt(1), chinese.items[0].node_id);

    var japanese = try searchText(std.testing.allocator, store, "エラー", .{ .limit = 5 });
    defer japanese.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), japanese.items.len);
    try std.testing.expectEqual(core.NodeId.fromInt(2), japanese.items[0].node_id);

    var korean = try searchText(std.testing.allocator, store, "오류", .{ .limit = 5 });
    defer korean.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 4), korean.items.len);
    try std.testing.expectEqual(core.NodeId.fromInt(3), korean.items[0].node_id);
    try std.testing.expectEqual(core.NodeId.fromInt(4), korean.items[1].node_id);
    try std.testing.expectEqual(core.NodeId.fromInt(5), korean.items[2].node_id);
    try std.testing.expectEqual(core.NodeId.fromInt(6), korean.items[3].node_id);

    var halfwidth_korean = try searchText(std.testing.allocator, store, "\u{ffb7}\u{ffcc}\u{ffa9}\u{ffd7}", .{ .limit = 5 });
    defer halfwidth_korean.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 4), halfwidth_korean.items.len);
    try std.testing.expectEqual(core.NodeId.fromInt(3), halfwidth_korean.items[0].node_id);
    try std.testing.expectEqual(core.NodeId.fromInt(4), halfwidth_korean.items[1].node_id);
    try std.testing.expectEqual(core.NodeId.fromInt(5), halfwidth_korean.items[2].node_id);
    try std.testing.expectEqual(core.NodeId.fromInt(6), halfwidth_korean.items[3].node_id);
}

test "searchText persistent fullwidth ASCII code recall" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage_mod.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();
    try store.appendNode(.{ .id = .fromInt(1), .kind = .function, .text = "ＩｎｖａｌｉｄＲｅｃｏｒｄ" });
    try store.appendNode(.{ .id = .fromInt(2), .kind = .file, .text = "ｓｒｃ／ｍａｉｎ．ｚｉｇ" });

    var symbol = try searchText(std.testing.allocator, store, "InvalidRecord", .{ .limit = 5 });
    defer symbol.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), symbol.items.len);
    try std.testing.expectEqual(core.NodeId.fromInt(1), symbol.items[0].node_id);

    var path = try searchText(std.testing.allocator, store, "src/main.zig", .{ .limit = 5 });
    defer path.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), path.items.len);
    try std.testing.expectEqual(core.NodeId.fromInt(2), path.items[0].node_id);
}

test "searchText persistent bridges narrow CJK joiners" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage_mod.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();
    try store.appendNode(.{ .id = .fromInt(1), .kind = .observation, .text = "错误-记录" });
    try store.appendNode(.{ .id = .fromInt(2), .kind = .observation, .text = "エラー・解析" });
    try store.appendNode(.{ .id = .fromInt(3), .kind = .observation, .text = "错误 记录" });

    var chinese = try searchText(std.testing.allocator, store, "错误记录", .{ .limit = 5 });
    defer chinese.deinit(std.testing.allocator);
    // node1 "错误-记录":窄 joiner 桥接成连续 → 命中 错误/误记/记录(cov=3)排 #1。
    // node3 "错误 记录":空格断开 CJK run → 只命中 错误/记录(cov=2)在后。node2 日文 cov=0 不召回。
    // 旧行为(严格 AND)只召回 node1。覆盖优先保证桥接全覆盖的 node1 仍排第一。
    try std.testing.expectEqual(@as(usize, 2), chinese.items.len);
    try std.testing.expectEqual(core.NodeId.fromInt(1), chinese.items[0].node_id); // 桥接全覆盖排第一
    try std.testing.expect(chinese.items[0].match_count > chinese.items[1].match_count);

    var chinese_with_joiner = try searchText(std.testing.allocator, store, "错误-记录", .{ .limit = 5 });
    defer chinese_with_joiner.deinit(std.testing.allocator);
    // query 里的窄 joiner 桥接成 "错误记录" → 与上面 chinese 同:node1(cov=3)+ node3(cov=2)。
    try std.testing.expectEqual(@as(usize, 2), chinese_with_joiner.items.len);
    try std.testing.expectEqual(core.NodeId.fromInt(1), chinese_with_joiner.items[0].node_id); // 桥接全覆盖排第一

    var japanese = try searchText(std.testing.allocator, store, "エラー解析", .{ .limit = 5 });
    defer japanese.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), japanese.items.len);
    try std.testing.expectEqual(core.NodeId.fromInt(2), japanese.items[0].node_id);
}

test "searchText persistent bridges CJK variation selectors" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage_mod.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();
    try store.appendNode(.{ .id = .fromInt(1), .kind = .observation, .text = "禰\u{fe00}豆子" });
    try store.appendNode(.{ .id = .fromInt(2), .kind = .observation, .text = "禰\u{e0100}豆子" });
    try store.appendNode(.{ .id = .fromInt(3), .kind = .observation, .text = "禰 説明 豆子" });

    var hits = try searchText(std.testing.allocator, store, "禰豆", .{ .limit = 5 });
    defer hits.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), hits.items.len);
    try std.testing.expectEqual(core.NodeId.fromInt(1), hits.items[0].node_id);
    try std.testing.expectEqual(core.NodeId.fromInt(2), hits.items[1].node_id);
}

test "searchText persistent folds halfwidth katakana to fullwidth queries" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage_mod.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();
    try store.appendNode(.{ .id = .fromInt(1), .kind = .observation, .text = "ｴﾗｰ解析" });
    try store.appendNode(.{ .id = .fromInt(2), .kind = .document, .text = "ｶﾞｲﾄﾞﾊﾟｽ" });
    try store.appendNode(.{ .id = .fromInt(3), .kind = .document, .text = "カ\u{3099}イド" });
    try store.appendNode(.{ .id = .fromInt(4), .kind = .document, .text = "は\u{309a}す" });

    var error_hits = try searchText(std.testing.allocator, store, "エラー", .{ .limit = 5 });
    defer error_hits.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), error_hits.items.len);
    try std.testing.expectEqual(core.NodeId.fromInt(1), error_hits.items[0].node_id);

    var guide_hits = try searchText(std.testing.allocator, store, "ガイド", .{ .limit = 5 });
    defer guide_hits.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), guide_hits.items.len);
    var saw_halfwidth = false;
    var saw_decomposed = false;
    for (guide_hits.items) |hit| {
        saw_halfwidth = saw_halfwidth or hit.node_id == core.NodeId.fromInt(2);
        saw_decomposed = saw_decomposed or hit.node_id == core.NodeId.fromInt(3);
    }
    try std.testing.expect(saw_halfwidth);
    try std.testing.expect(saw_decomposed);

    var pass_hits = try searchText(std.testing.allocator, store, "ぱす", .{ .limit = 5 });
    defer pass_hits.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), pass_hits.items.len);
    var saw_halfwidth_pass = false;
    var saw_decomposed_pass = false;
    for (pass_hits.items) |hit| {
        saw_halfwidth_pass = saw_halfwidth_pass or hit.node_id == core.NodeId.fromInt(2);
        saw_decomposed_pass = saw_decomposed_pass or hit.node_id == core.NodeId.fromInt(4);
    }
    try std.testing.expect(saw_halfwidth_pass);
    try std.testing.expect(saw_decomposed_pass);

    var hiragana_error_hits = try searchText(std.testing.allocator, store, "えらー", .{ .limit = 5 });
    defer hiragana_error_hits.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), hiragana_error_hits.items.len);
    try std.testing.expectEqual(core.NodeId.fromInt(1), hiragana_error_hits.items[0].node_id);
}

test "searchText persistent requires CJK bigram match for multi-character CJK queries" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage_mod.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();
    try store.appendNode(.{ .id = .fromInt(1), .kind = .observation, .text = "错误记录" });
    try store.appendNode(.{ .id = .fromInt(2), .kind = .observation, .text = "错别字" });
    try store.appendNode(.{ .id = .fromInt(3), .kind = .observation, .text = "误差分析" });
    try store.appendNode(.{ .id = .fromInt(4), .kind = .observation, .text = "错误说明" });
    try store.appendNode(.{ .id = .fromInt(5), .kind = .observation, .text = "记录分析" });

    var exact = try searchText(std.testing.allocator, store, "错误", .{ .limit = 10 });
    defer exact.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), exact.items.len);
    try std.testing.expectEqual(core.NodeId.fromInt(1), exact.items[0].node_id);

    var full = try searchText(std.testing.allocator, store, "错误记录", .{ .limit = 10 });
    defer full.deinit(std.testing.allocator);
    // 修复:floor=1 + 覆盖优先。"错误记录"(cov=3)排 #1;"错误说明"/"记录分析"(各 cov=1)在后;
    // "错别字"/"误差分析"(cov=0)不召回。旧行为(严格 AND)只召回 node1。
    try std.testing.expectEqual(@as(usize, 3), full.items.len);
    try std.testing.expectEqual(core.NodeId.fromInt(1), full.items[0].node_id); // 全覆盖排第一
    try std.testing.expectEqual(@as(u32, 3), full.items[0].match_count);
    try std.testing.expect(full.items[full.items.len - 1].match_count < full.items[0].match_count);

    var single = try searchText(std.testing.allocator, store, "错", .{ .limit = 10 });
    defer single.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), single.items.len);
}

test "searchText persistent requires repeated CJK bigram frequency for repeated-character queries" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage_mod.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();
    try store.appendNode(.{ .id = .fromInt(1), .kind = .observation, .text = "哈哈" });
    try store.appendNode(.{ .id = .fromInt(2), .kind = .observation, .text = "哈哈哈" });
    try store.appendNode(.{ .id = .fromInt(3), .kind = .observation, .text = "哈哈哈哈" });

    var hits = try searchText(std.testing.allocator, store, "哈哈哈", .{ .limit = 10 });
    defer hits.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), hits.items.len);
    try std.testing.expect(hitsContainNode(hits.items, core.NodeId.fromInt(2)));
    try std.testing.expect(hitsContainNode(hits.items, core.NodeId.fromInt(3)));
}

test "persistent text catalog rebuild writes meta and doc records" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage_mod.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();
    try store.appendNode(.{ .id = .fromInt(1), .kind = .file, .text = "src/storage.zig" });
    try store.appendNode(.{ .id = .fromInt(2), .kind = .function, .text = "readEdgeIndexRecordsByNode" });

    const meta = try rebuildPersistentTextCatalog(std.testing.allocator, store);
    try std.testing.expectEqual(@as(u64, 2), meta.doc_count);
    try std.testing.expect(!try persistentTextCatalogStale(std.testing.allocator, store));

    const read_meta = try readPersistentTextMeta(std.testing.allocator, store);
    const index_meta = try store.readIndexMeta();
    try std.testing.expectEqual(meta.node_digest, read_meta.node_digest);
    try std.testing.expectEqual(index_meta.node_digest, read_meta.node_digest);
    try std.testing.expectEqual(meta.node_by_text_order_digest, read_meta.node_by_text_order_digest);
    try std.testing.expectEqual(index_meta.node_by_text_order_digest, read_meta.node_by_text_order_digest);
    try std.testing.expectEqual(meta.doc_count, read_meta.doc_count);
    try std.testing.expect(read_meta.total_text_tokens > 0);

    const docs_path = try textDocsPath(std.testing.allocator, store);
    defer std.testing.allocator.free(docs_path);
    var docs_file = try std.Io.Dir.cwd().openFile(std.testing.io, docs_path, .{});
    defer docs_file.close(std.testing.io);
    const header = try readTextDocsHeaderFromFile(store, docs_file);
    try std.testing.expectEqual(@as(u64, 2), header.doc_count);
    const first = try readTextDocRecordAt(store, docs_file, 0);
    try std.testing.expectEqual(@as(u64, 1), first.doc_id);
    try std.testing.expectEqual(@as(u64, 1), first.node_id);
    try std.testing.expectEqual(core.NodeKind.file, try first.nodeKind());
    try std.testing.expect(first.text_tokens > 0);

    var postings = try readPersistentTermPostings(std.testing.allocator, store, "edge");
    defer postings.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), postings.items.len);
    try std.testing.expectEqual(@as(u64, 2), postings.items[0].doc_id);
    try std.testing.expect(postings.items[0].text_freq >= 1);

    var missing = try readPersistentTermPostings(std.testing.allocator, store, "missing");
    defer missing.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), missing.items.len);
}

test "persistent text catalog uses dense header hint for uniform searchable nodes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage_mod.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();
    try store.appendNodesBatch(&.{
        .{ .id = .fromInt(1), .kind = .file, .text = "src/a.zig" },
        .{ .id = .fromInt(2), .kind = .file, .text = "src/b.zig" },
        .{ .id = .fromInt(3), .kind = .file, .text = "src/c.zig" },
    });

    const meta = try rebuildPersistentTextCatalog(std.testing.allocator, store);
    try std.testing.expectEqual(@as(u64, 3), meta.doc_count);

    const docs_path = try textDocsPath(std.testing.allocator, store);
    defer std.testing.allocator.free(docs_path);
    var docs_file = try std.Io.Dir.cwd().openFile(std.testing.io, docs_path, .{});
    defer docs_file.close(std.testing.io);
    const header = try readTextDocsHeaderFromFile(store, docs_file);
    try std.testing.expect(header.hasDenseUniformRecords());
    try std.testing.expectEqual(@as(u64, 3), header.doc_count);
    try std.testing.expectEqual(@as(u32, 1), header.dense_node_id_base);
    try std.testing.expectEqual(@as(u16, @intFromEnum(core.NodeKind.file)), header.uniform_kind);

    const second = try readTextDocRecordAt(store, docs_file, 1);
    try std.testing.expectEqual(@as(u64, 2), second.doc_id);
    try std.testing.expectEqual(@as(u64, 2), second.node_id);
    try std.testing.expectEqual(core.NodeKind.file, try second.nodeKind());
}

test "persistent text catalog excludes deleted node tombstones" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage_mod.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();
    try store.appendNode(.{ .id = .fromInt(1), .kind = .edit, .text = "__tinykg_deleted_node__ 1" });
    try store.appendNode(.{ .id = .fromInt(2), .kind = .observation, .text = "live searchable memory" });

    const meta = try rebuildPersistentTextCatalog(std.testing.allocator, store);
    try std.testing.expectEqual(@as(u64, 1), meta.doc_count);
    try std.testing.expect(!try persistentTextCatalogStale(std.testing.allocator, store));

    const docs_path = try textDocsPath(std.testing.allocator, store);
    defer std.testing.allocator.free(docs_path);
    var docs_file = try std.Io.Dir.cwd().openFile(std.testing.io, docs_path, .{});
    defer docs_file.close(std.testing.io);
    const header = try readTextDocsHeaderFromFile(store, docs_file);
    try std.testing.expectEqual(@as(u64, 1), header.doc_count);
    const doc = try readTextDocRecordAt(store, docs_file, 0);
    try std.testing.expectEqual(@as(u64, 1), doc.doc_id);
    try std.testing.expectEqual(@as(u64, 2), doc.node_id);

    var deleted_hits = try searchText(std.testing.allocator, store, "tinykg deleted node", .{ .limit = 5 });
    defer deleted_hits.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), deleted_hits.items.len);

    var live_hits = try searchText(std.testing.allocator, store, "live searchable", .{ .limit = 5 });
    defer live_hits.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), live_hits.items.len);
    try std.testing.expectEqual(core.NodeId.fromInt(2), live_hits.items[0].node_id);
}

test "persistent text catalog indexes non-edit reserved tombstone-like text" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage_mod.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();
    try store.appendNode(.{ .id = .fromInt(1), .kind = .observation, .text = "__tinykg_deleted_node__ diagnostic string" });
    try store.appendNode(.{ .id = .fromInt(2), .kind = .edit, .text = "__tinykg_deleted_node__ 2" });

    const meta = try rebuildPersistentTextCatalog(std.testing.allocator, store);
    try std.testing.expectEqual(@as(u64, 1), meta.doc_count);
    try std.testing.expect(!try persistentTextCatalogStale(std.testing.allocator, store));

    var hits = try searchText(std.testing.allocator, store, "diagnostic string", .{ .limit = 5 });
    defer hits.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), hits.items.len);
    try std.testing.expectEqual(core.NodeId.fromInt(1), hits.items[0].node_id);

    var prefix_hits = try searchText(std.testing.allocator, store, "tinykg deleted node", .{ .limit = 5 });
    defer prefix_hits.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), prefix_hits.items.len);
    try std.testing.expectEqual(core.NodeId.fromInt(1), prefix_hits.items[0].node_id);
}

test "persistent text catalog supports tombstone-only store" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage_mod.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();
    try store.appendNode(.{ .id = .fromInt(1), .kind = .edit, .text = "__tinykg_deleted_node__ 1" });

    const meta = try rebuildPersistentTextCatalog(std.testing.allocator, store);
    try std.testing.expectEqual(@as(u64, 0), meta.doc_count);
    try std.testing.expectEqual(@as(u64, 0), meta.term_count);
    try std.testing.expectEqual(@as(u64, 0), meta.posting_count);
    try std.testing.expect(!try persistentTextCatalogStale(std.testing.allocator, store));

    const terms_path = try textTermsPath(std.testing.allocator, store);
    defer std.testing.allocator.free(terms_path);
    var terms_file = try std.Io.Dir.cwd().openFile(std.testing.io, terms_path, .{});
    terms_file.close(std.testing.io);

    const postings_path = try textPostingsPath(std.testing.allocator, store);
    defer std.testing.allocator.free(postings_path);
    var postings_file = try std.Io.Dir.cwd().openFile(std.testing.io, postings_path, .{});
    postings_file.close(std.testing.io);

    var deleted_hits = try searchText(std.testing.allocator, store, "__tinykg_deleted_node__", .{ .limit = 5 });
    defer deleted_hits.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), deleted_hits.items.len);
}

test "persistent text top-hit file omits empty sparse term index" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage_mod.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();
    try store.appendNode(.{ .id = .fromInt(1), .kind = .task, .text = "storage repair" });
    try store.appendNode(.{ .id = .fromInt(2), .kind = .task, .text = "storage index" });
    _ = try rebuildPersistentTextCatalog(std.testing.allocator, store);

    const top_hits_path = try textTermTopHitsPath(std.testing.allocator, store);
    defer std.testing.allocator.free(top_hits_path);
    var top_hits_file = try std.Io.Dir.cwd().openFile(std.testing.io, top_hits_path, .{});
    defer top_hits_file.close(std.testing.io);
    const header = try readTextTermTopHitsHeaderFromFile(store, top_hits_file);
    try std.testing.expect(header.term_count > 0);
    try std.testing.expectEqual(@as(u64, 0), header.hit_count);
    try std.testing.expectEqual(@as(u64, 0), header.hit_term_count);
    try std.testing.expectEqual(@as(u64, TextTermTopHitsHeader.encoded_len), try regularFileSize(store, top_hits_file));
}

test "persistent text top-hit sparse index rejects unsorted term entries" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage_mod.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    const top_hits_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "top-hits.idx" });
    defer std.testing.allocator.free(top_hits_path);
    var file = try std.Io.Dir.cwd().createFile(std.testing.io, top_hits_path, .{ .read = true, .truncate = true });
    defer file.close(std.testing.io);

    const header = TextTermTopHitsHeader{
        .term_count = 10,
        .hit_count = 2 * persistent_term_top_hit_capacity,
        .hit_term_count = 2,
        .capacity = persistent_term_top_hit_capacity,
    };
    var header_bytes: [TextTermTopHitsHeader.encoded_len]u8 = undefined;
    encodeTextTermTopHitsHeader(header, &header_bytes);
    try file.writePositionalAll(std.testing.io, &header_bytes, 0);

    var sparse_bytes: [TextTermTopHitTermRecord.encoded_len]u8 = undefined;
    try encodeTextTermTopHitTermRecord(.{ .term_index = 5, .hit_offset = 0, .hit_count = persistent_term_top_hit_capacity }, &sparse_bytes);
    try file.writePositionalAll(std.testing.io, &sparse_bytes, try textTermTopHitTermRecordOffset(header.hit_count, 0));
    try encodeTextTermTopHitTermRecord(.{ .term_index = 3, .hit_offset = persistent_term_top_hit_capacity, .hit_count = persistent_term_top_hit_capacity }, &sparse_bytes);
    try file.writePositionalAll(std.testing.io, &sparse_bytes, try textTermTopHitTermRecordOffset(header.hit_count, 1));

    try std.testing.expect(try persistentTermTopHitsSparseIndexInvalid(store, file, header));
}

test "production text rebuild uses external runs and matches builder catalog results" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage_mod.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();
    try store.appendNode(.{ .id = .fromInt(1), .kind = .file, .text = "src/storage.zig storage repair" });
    try store.appendNode(.{ .id = .fromInt(2), .kind = .task, .text = "storage index repair repair" });
    try store.appendNode(.{ .id = .fromInt(3), .kind = .function, .text = "readStorageIndexRepair" });
    try store.appendNode(.{ .id = .fromInt(4), .kind = .file, .text = "file file" });

    const builder_meta = try rebuildPersistentTextCatalogOnceDeadlineTimed(std.testing.allocator, store, .none, null);
    var builder_postings = try readPersistentTermPostings(std.testing.allocator, store, "storage");
    defer builder_postings.deinit(std.testing.allocator);
    var builder_file_postings = try readPersistentTermPostings(std.testing.allocator, store, "file");
    defer builder_file_postings.deinit(std.testing.allocator);
    var builder_hits = try searchText(std.testing.allocator, store, "storage repair", .{ .limit = 3 });
    defer builder_hits.deinit(std.testing.allocator);

    const runs_base_path = try textPostingRunsBasePath(std.testing.allocator, store);
    defer std.testing.allocator.free(runs_base_path);
    const run_zero_path = try std.fmt.allocPrint(std.testing.allocator, "{s}.posting_run.0.tmp", .{runs_base_path});
    defer std.testing.allocator.free(run_zero_path);
    const postings_path = try textPostingsPath(std.testing.allocator, store);
    defer std.testing.allocator.free(postings_path);
    const summaries_path = try std.fmt.allocPrint(std.testing.allocator, "{s}.summaries.tmp", .{postings_path});
    defer std.testing.allocator.free(summaries_path);

    const production_meta = try rebuildPersistentTextCatalog(std.testing.allocator, store);
    try std.testing.expectEqual(builder_meta.node_digest, production_meta.node_digest);
    try std.testing.expectEqual(builder_meta.node_by_text_order_digest, production_meta.node_by_text_order_digest);
    try std.testing.expectEqual(builder_meta.doc_count, production_meta.doc_count);
    try std.testing.expectEqual(builder_meta.total_text_tokens, production_meta.total_text_tokens);
    try std.testing.expectEqual(builder_meta.term_count, production_meta.term_count);
    try std.testing.expectEqual(builder_meta.term_bytes, production_meta.term_bytes);
    try std.testing.expectEqual(builder_meta.posting_count, production_meta.posting_count);
    try std.testing.expect(!try persistentTextCatalogStale(std.testing.allocator, store));

    var production_postings = try readPersistentTermPostings(std.testing.allocator, store, "storage");
    defer production_postings.deinit(std.testing.allocator);
    try std.testing.expectEqual(builder_postings.items.len, production_postings.items.len);
    for (builder_postings.items, production_postings.items) |expected, actual| {
        try std.testing.expectEqual(expected.doc_id, actual.doc_id);
        try std.testing.expectEqual(expected.text_freq, actual.text_freq);
        try std.testing.expectEqual(expected.kind_freq, actual.kind_freq);
    }

    var production_file_postings = try readPersistentTermPostings(std.testing.allocator, store, "file");
    defer production_file_postings.deinit(std.testing.allocator);
    try std.testing.expectEqual(builder_file_postings.items.len, production_file_postings.items.len);
    var saw_file_overlap = false;
    for (builder_file_postings.items, production_file_postings.items) |expected, actual| {
        try std.testing.expectEqual(expected.doc_id, actual.doc_id);
        try std.testing.expectEqual(expected.text_freq, actual.text_freq);
        try std.testing.expectEqual(expected.kind_freq, actual.kind_freq);
        if (actual.doc_id == 4) {
            try std.testing.expect(!saw_file_overlap);
            try std.testing.expectEqual(@as(u32, 2), actual.text_freq);
            try std.testing.expectEqual(@as(u32, 0), actual.kind_freq);
            saw_file_overlap = true;
        }
    }
    try std.testing.expect(saw_file_overlap);

    var production_hits = try searchText(std.testing.allocator, store, "storage repair", .{ .limit = 3 });
    defer production_hits.deinit(std.testing.allocator);
    try std.testing.expectEqual(builder_hits.items.len, production_hits.items.len);
    for (builder_hits.items, production_hits.items) |expected, actual| {
        try std.testing.expectEqual(expected.node_id, actual.node_id);
        try std.testing.expectApproxEqAbs(expected.score, actual.score, 0.000001);
    }

    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(std.testing.io, run_zero_path, .{}));
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(std.testing.io, summaries_path, .{}));
}

test "persistent text rebuild reuses repeated text term frequencies" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);
    const runs_base_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "text_postings.dat" });
    defer std.testing.allocator.free(runs_base_path);

    var store = try storage_mod.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();
    try store.appendNode(.{ .id = .fromInt(1), .kind = .task, .text = "shared alpha beta beta" });
    try store.appendNode(.{ .id = .fromInt(2), .kind = .task, .text = "shared alpha beta beta" });
    try store.appendNode(.{ .id = .fromInt(3), .kind = .task, .text = "shared alpha beta beta" });
    try store.appendNode(.{ .id = .fromInt(4), .kind = .task, .text = "other beta" });
    try store.appendNode(.{ .id = .fromInt(5), .kind = .task, .text = "shared alpha beta beta" });

    const rebuild = try rebuildPersistentTextCatalogWithTimingsForBench(std.testing.allocator, store, runs_base_path);
    try std.testing.expectEqual(@as(u64, 5), rebuild.meta.doc_count);
    try std.testing.expectEqual(@as(u64, 5), rebuild.timings.docs_freq_cache_lookup_count);
    try std.testing.expectEqual(@as(u64, 3), rebuild.timings.docs_freq_cache_hit_count);
    try std.testing.expectEqual(@as(u64, 2), rebuild.timings.docs_freq_cache_miss_count);
    try std.testing.expectEqual(@as(u64, 2), rebuild.timings.docs_freq_cache_entry_count);

    var hits = try searchText(std.testing.allocator, store, "alpha", .{ .limit = 10 });
    defer hits.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 4), hits.items.len);
}

test "persistent text rebuild keeps all-doc synthesis after text freq cache fills" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);
    const runs_base_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "text_postings.dat" });
    defer std.testing.allocator.free(runs_base_path);

    var store = try storage_mod.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    const doc_count = text_rebuild_text_freq_cache_max_entries + persistent_all_docs_synthesis_min_postings;
    var nodes = std.ArrayList(graph_mod.Node).empty;
    defer {
        for (nodes.items) |node| std.testing.allocator.free(node.text);
        nodes.deinit(std.testing.allocator);
    }
    try nodes.ensureTotalCapacity(std.testing.allocator, doc_count);
    var id: u64 = 1;
    while (id <= doc_count) : (id += 1) {
        const text = try std.fmt.allocPrint(std.testing.allocator, "common cache-fill-unique-{d}", .{id});
        errdefer std.testing.allocator.free(text);
        nodes.appendAssumeCapacity(.{
            .id = .fromInt(id),
            .kind = .task,
            .text = text,
        });
    }
    try store.appendNodesBatch(nodes.items);

    const rebuild = try rebuildPersistentTextCatalogWithTimingsForBench(std.testing.allocator, store, runs_base_path);
    try std.testing.expectEqual(@as(u64, doc_count), rebuild.meta.doc_count);
    try std.testing.expect(rebuild.timings.docs_freq_cache_miss_count > text_rebuild_text_freq_cache_max_entries);
    try std.testing.expect(rebuild.timings.run_virtual_all_docs_synthetic_records >= doc_count);
}

test "readPersistentTermPostingsLimited rejects oversized postings list before materializing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage_mod.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();
    try store.appendNode(.{ .id = .fromInt(1), .kind = .function, .text = "edge alpha" });
    try store.appendNode(.{ .id = .fromInt(2), .kind = .function, .text = "edge beta" });
    _ = try rebuildPersistentTextCatalog(std.testing.allocator, store);

    try std.testing.expectError(
        core.Error.BudgetExceeded,
        readPersistentTermPostingsLimited(std.testing.allocator, store, "edge", 1),
    );

    var postings = try readPersistentTermPostingsLimited(std.testing.allocator, store, "edge", 2);
    defer postings.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), postings.items.len);
    try std.testing.expectEqual(@as(u64, 1), postings.items[0].doc_id);
    try std.testing.expectEqual(@as(u64, 2), postings.items[1].doc_id);
}

test "searchText falls back read-only when tokenizer version changes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage_mod.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();
    try store.appendNode(.{ .id = .fromInt(1), .kind = .observation, .text = "カ\u{3099}イド" });

    var stale_meta = try rebuildPersistentTextCatalog(std.testing.allocator, store);
    stale_meta.tokenizer = tokenizer_version - 1;
    try writeTextMetaFile(std.testing.allocator, store, stale_meta);
    try std.testing.expect(try persistentTextCatalogStale(std.testing.allocator, store));
    try std.testing.expectError(error.InvalidRecord, readPersistentTextMeta(std.testing.allocator, store));

    var hits = try searchText(std.testing.allocator, store, "ガイド", .{ .limit = 5 });
    defer hits.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), hits.items.len);
    try std.testing.expectEqual(core.NodeId.fromInt(1), hits.items[0].node_id);

    try std.testing.expectError(error.InvalidRecord, readPersistentTextMeta(std.testing.allocator, store));
    try std.testing.expect(try persistentTextCatalogStale(std.testing.allocator, store));
}

test "searchText scans read-only when persistent text index is missing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage_mod.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();
    try store.appendNode(.{ .id = .fromInt(1), .kind = .file, .text = "src/storage.zig" });
    try store.appendNode(.{ .id = .fromInt(2), .kind = .function, .text = "readEdgeIndexRecordsByNode" });

    try std.testing.expect(try persistentTextCatalogStale(std.testing.allocator, store));
    var hits = try searchText(std.testing.allocator, store, "edge index node", .{ .limit = 5 });
    defer hits.deinit(std.testing.allocator);

    try std.testing.expect(try persistentTextCatalogStale(std.testing.allocator, store));
    try std.testing.expect(hits.items.len >= 1);
    try std.testing.expectEqual(core.NodeId.fromInt(2), hits.items[0].node_id);
}

test "stale text admission preserves canonical event corruption errors" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage_mod.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();
    try store.appendNode(.{ .id = .fromInt(1), .kind = .observation, .text = "canonical event corruption" });
    var events = try std.Io.Dir.cwd().openFile(std.testing.io, store.events_bin_path, .{ .mode = .read_write });
    const event_bytes = (try events.stat(std.testing.io)).size;
    try events.writePositionalAll(std.testing.io, "broken", event_bytes);
    events.close(std.testing.io);

    try std.testing.expectError(
        error.InvalidRecord,
        searchText(std.testing.allocator, store, "canonical", .{ .limit = 5 }),
    );
}

test "searchText rejects non-default tokenizer options for persistent index" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage_mod.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();
    try store.appendNode(.{ .id = .fromInt(1), .kind = .observation, .text = "错误记录" });
    _ = try rebuildPersistentTextCatalog(std.testing.allocator, store);

    try std.testing.expectError(core.Error.Unsupported, searchText(std.testing.allocator, store, "错误", .{
        .tokenizer = .{ .emit_cjk_bigrams = false },
    }));
    try std.testing.expect(!try persistentTextCatalogStale(std.testing.allocator, store));
}

test "searchText reads appended node without rebuilding stale persistent postings" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage_mod.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();
    try store.appendNode(.{ .id = .fromInt(1), .kind = .file, .text = "src/storage.zig" });
    _ = try rebuildPersistentTextCatalog(std.testing.allocator, store);
    try store.appendNode(.{ .id = .fromInt(2), .kind = .task, .text = "repair stale text postings" });

    const docs_path = try textDocsPath(std.testing.allocator, store);
    defer std.testing.allocator.free(docs_path);
    const terms_path = try textTermsPath(std.testing.allocator, store);
    defer std.testing.allocator.free(terms_path);
    const postings_path = try textPostingsPath(std.testing.allocator, store);
    defer std.testing.allocator.free(postings_path);
    const docs_bytes_before = try textPathFileSize(std.testing.io, docs_path);
    const terms_bytes_before = try textPathFileSize(std.testing.io, terms_path);
    const postings_bytes_before = try textPathFileSize(std.testing.io, postings_path);

    var hits = try searchText(std.testing.allocator, store, "stale postings", .{ .kind_filter = .task, .limit = 5 });
    defer hits.deinit(std.testing.allocator);

    try std.testing.expect(try persistentTextCatalogStale(std.testing.allocator, store));
    try std.testing.expectEqual(docs_bytes_before, try textPathFileSize(std.testing.io, docs_path));
    try std.testing.expectEqual(terms_bytes_before, try textPathFileSize(std.testing.io, terms_path));
    try std.testing.expectEqual(postings_bytes_before, try textPathFileSize(std.testing.io, postings_path));
    try std.testing.expectEqual(@as(usize, 1), hits.items.len);
    try std.testing.expectEqual(core.NodeId.fromInt(2), hits.items[0].node_id);
}

test "searchText detects committed append even when graph index meta is stale" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage_mod.Store.initWithOptions(std.testing.allocator, std.testing.io, store_path, .{
        .primary_text_write_mode = .bulk_ingest,
    });
    defer store.deinit();
    try store.createEmpty();
    try store.appendNode(.{ .id = .fromInt(1), .kind = .file, .text = "storage index" });
    _ = try rebuildPersistentTextCatalog(std.testing.allocator, store);
    try std.testing.expect(!try persistentTextCatalogStale(std.testing.allocator, store));

    var record = std.ArrayList(u8).empty;
    defer record.deinit(std.testing.allocator);
    try appendTestNodeEvent(store, &record, std.testing.allocator, 2, .task, "post commit memory");
    var file = try std.Io.Dir.cwd().createFile(std.testing.io, store.events_bin_path, .{ .read = true, .truncate = false });
    defer file.close(std.testing.io);
    try file.writePositionalAll(std.testing.io, record.items, (try file.stat(std.testing.io)).size);

    try std.testing.expect(try persistentTextCatalogStale(std.testing.allocator, store));
    var hits = try searchText(std.testing.allocator, store, "post commit", .{ .kind_filter = .task, .limit = 5 });
    defer hits.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), hits.items.len);
    try std.testing.expectEqual(core.NodeId.fromInt(2), hits.items[0].node_id);
    try std.testing.expect(try persistentTextCatalogStale(std.testing.allocator, store));
}

fn appendTestNodeEvent(store: storage_mod.Store, out: *std.ArrayList(u8), allocator: std.mem.Allocator, id: u64, kind: core.NodeKind, text: []const u8) !void {
    var texts_file = try std.Io.Dir.cwd().createFile(store.io, store.node_texts_path, .{
        .read = true,
        .truncate = false,
    });
    defer texts_file.close(store.io);
    const text_offset = (try texts_file.stat(store.io)).size;
    try texts_file.writePositionalAll(store.io, text, text_offset);

    var payload = std.ArrayList(u8).empty;
    defer payload.deinit(allocator);
    try appendTestU64(&payload, allocator, id);
    try appendTestU16(&payload, allocator, @intFromEnum(kind));
    try appendTestU64(&payload, allocator, text_offset);
    try appendTestU32(&payload, allocator, @intCast(text.len));

    try out.appendSlice(allocator, "TKGE");
    try out.append(allocator, 2);
    try out.append(allocator, 'N');
    try appendTestU32(out, allocator, @intCast(payload.items.len));
    try appendTestU64(out, allocator, std.hash.Wyhash.hash(0, payload.items));
    try out.appendSlice(allocator, payload.items);
}

fn appendTestU16(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u16) !void {
    var bytes: [2]u8 = undefined;
    std.mem.writeInt(u16, &bytes, value, .little);
    try out.appendSlice(allocator, &bytes);
}

fn appendTestU32(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u32) !void {
    var bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &bytes, value, .little);
    try out.appendSlice(allocator, &bytes);
}

fn appendTestU64(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u64) !void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    try out.appendSlice(allocator, &bytes);
}

test "persistent text catalog detects stale node text anchor after node append" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage_mod.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();
    try store.appendNode(.{ .id = .fromInt(1), .kind = .file, .text = "src/storage.zig" });
    _ = try rebuildPersistentTextCatalog(std.testing.allocator, store);
    try std.testing.expect(!try persistentTextCatalogStale(std.testing.allocator, store));

    try store.appendNode(.{ .id = .fromInt(2), .kind = .task, .text = "repair text index" });
    try std.testing.expect(try persistentTextCatalogStale(std.testing.allocator, store));
}

test "persistent text stale graph anchor short circuits property metadata scan" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage_mod.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();
    try store.appendNode(.{ .id = .fromInt(1), .kind = .task, .text = "indexed task" });
    try store.setNodeStringProperty(std.testing.allocator, .fromInt(1), "summary", "indexed metadata");
    _ = try rebuildPersistentTextCatalog(std.testing.allocator, store);

    try store.appendNode(.{ .id = .fromInt(2), .kind = .task, .text = "new stale task" });
    try std.Io.Dir.cwd().deleteFile(std.testing.io, store.property_payload_delta_path);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, store.property_payload_delta_path);

    // The graph anchor already proves staleness. Touching the deliberately
    // invalid property path here would surface IsDir instead of returning.
    try std.testing.expect(try persistentTextCatalogQuickStale(std.testing.allocator, store));
    try std.testing.expect(try persistentTextCatalogStale(std.testing.allocator, store));
}

test "stale text fallback never hides corrupt searchable property delta" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage_mod.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();
    try store.appendNode(.{ .id = .fromInt(1), .kind = .task, .text = "indexed task" });
    try store.setNodeStringProperty(std.testing.allocator, .fromInt(1), "summary", "searchable metadata");
    _ = try rebuildPersistentTextCatalog(std.testing.allocator, store);
    try store.appendNode(.{ .id = .fromInt(2), .kind = .task, .text = "make catalog stale" });

    var delta = try std.Io.Dir.cwd().openFile(std.testing.io, store.property_payload_delta_path, .{ .mode = .read_write });
    const delta_len = (try delta.stat(std.testing.io)).size;
    try delta.writePositionalAll(std.testing.io, "broken", delta_len);
    delta.close(std.testing.io);

    try std.testing.expectError(error.InvalidRecord, searchText(std.testing.allocator, store, "searchable metadata", .{ .limit = 8 }));
}

test "searchText rejects oversized property delta before quick and fallback scans" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage_mod.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();
    try store.appendNode(.{ .id = .fromInt(1), .kind = .task, .text = "indexed task" });
    try store.setNodeStringProperty(std.testing.allocator, .fromInt(1), "summary", "indexed searchable metadata");
    _ = try rebuildPersistentTextCatalog(std.testing.allocator, store);

    var delta = try std.Io.Dir.cwd().openFile(std.testing.io, store.property_payload_delta_path, .{ .mode = .read_write });
    try delta.setLength(std.testing.io, stale_store_scan_max_property_delta_bytes + 1);
    delta.close(std.testing.io);

    // With current graph anchors the quick-stale metadata digest is the first
    // possible delta reader. It must reject from the fixed file-size snapshot.
    try std.testing.expectError(
        error.TextIndexMaintenanceRequired,
        searchText(std.testing.allocator, store, "searchable metadata", .{ .limit = 8 }),
    );
    try std.testing.expectError(
        error.TextIndexMaintenanceRequired,
        textQueryPlanStats(std.testing.allocator, store, "searchable metadata", .{ .limit = 8 }),
    );

    // A graph append short-circuits the quick digest. The read-only fallback
    // admission must independently reject the same oversized canonical delta.
    try store.appendNode(.{ .id = .fromInt(2), .kind = .task, .text = "new stale task" });
    try std.testing.expectError(
        error.TextIndexMaintenanceRequired,
        searchText(std.testing.allocator, store, "new stale task", .{ .limit = 8 }),
    );
}

test "persistent text catalog stays current after edge-only events" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage_mod.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();
    try store.appendNode(.{ .id = .fromInt(1), .kind = .file, .text = "src/storage.zig" });
    try store.appendNode(.{ .id = .fromInt(2), .kind = .task, .text = "repair text index" });
    _ = try rebuildPersistentTextCatalog(std.testing.allocator, store);
    try std.testing.expect(!try persistentTextCatalogStale(std.testing.allocator, store));

    try store.appendEdge(.{ .id = .fromInt(1), .src = .fromInt(1), .dst = .fromInt(2), .rel = .mentions });
    try std.testing.expect(!try persistentTextCatalogStale(std.testing.allocator, store));

    try store.deleteEdge(.fromInt(1));
    try std.testing.expect(!try persistentTextCatalogStale(std.testing.allocator, store));
}

test "persistent text catalog detects corrupt docs file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage_mod.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();
    try store.appendNode(.{ .id = .fromInt(1), .kind = .file, .text = "src/storage.zig" });
    _ = try rebuildPersistentTextCatalog(std.testing.allocator, store);

    const docs_path = try textDocsPath(std.testing.allocator, store);
    defer std.testing.allocator.free(docs_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = docs_path,
        .data = "bad",
        .flags = .{ .truncate = true },
    });

    try std.testing.expect(try persistentTextCatalogStale(std.testing.allocator, store));
}

test "persistent text catalog detects meta token totals that disagree with docs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage_mod.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();
    try store.appendNode(.{ .id = .fromInt(1), .kind = .file, .text = "storage index" });
    const original = try rebuildPersistentTextCatalog(std.testing.allocator, store);
    try std.testing.expect(!try persistentTextCatalogStale(std.testing.allocator, store));

    var corrupt = original;
    corrupt.total_text_tokens += 100;
    try writeTextMetaFile(std.testing.allocator, store, corrupt);

    try std.testing.expect(try persistentTextCatalogStale(std.testing.allocator, store));
    var hits = try searchText(std.testing.allocator, store, "storage", .{ .limit = 5 });
    defer hits.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), hits.items.len);
    try std.testing.expect(try persistentTextCatalogStale(std.testing.allocator, store));

    _ = try rebuildPersistentTextCatalog(std.testing.allocator, store);
    const repaired = try readPersistentTextMeta(std.testing.allocator, store);
    try std.testing.expectEqual(original.total_text_tokens, repaired.total_text_tokens);
}

test "persistent text catalog detects doc records that disagree with graph nodes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage_mod.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();
    try store.appendNode(.{ .id = .fromInt(1), .kind = .file, .text = "storage index" });
    try store.appendNode(.{ .id = .fromInt(2), .kind = .task, .text = "query planner" });
    _ = try rebuildPersistentTextCatalog(std.testing.allocator, store);
    try std.testing.expect(!try persistentTextCatalogStale(std.testing.allocator, store));

    const docs_path = try textDocsPath(std.testing.allocator, store);
    defer std.testing.allocator.free(docs_path);
    {
        var docs_file = try std.Io.Dir.cwd().openFile(std.testing.io, docs_path, .{ .mode = .read_write });
        defer docs_file.close(std.testing.io);
        var doc = try readTextDocRecordAt(store, docs_file, 0);
        doc.node_id = 2;
        var bytes: [TextDocRecord.encoded_len]u8 = undefined;
        try doc.encode(&bytes);
        try docs_file.writePositionalAll(std.testing.io, &bytes, try textDocRecordOffset(0));
        try docs_file.sync(std.testing.io);
    }
    try std.testing.expect(try persistentTextCatalogStale(std.testing.allocator, store));
    var hits = try searchText(std.testing.allocator, store, "storage", .{ .limit = 5 });
    defer hits.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), hits.items.len);
    try std.testing.expectEqual(core.NodeId.fromInt(1), hits.items[0].node_id);
    try std.testing.expect(try persistentTextCatalogStale(std.testing.allocator, store));
}

test "persistent text catalog detects corrupt terms file" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage_mod.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();
    try store.appendNode(.{ .id = .fromInt(1), .kind = .function, .text = "shared readEdgeIndexRecordsByNode" });
    try store.appendNode(.{ .id = .fromInt(2), .kind = .function, .text = "shared repair sentinel" });
    _ = try rebuildPersistentTextCatalog(std.testing.allocator, store);

    const terms_path = try textTermsPath(std.testing.allocator, store);
    defer std.testing.allocator.free(terms_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = terms_path,
        .data = "bad",
        .flags = .{ .truncate = true },
    });

    try std.testing.expect(try persistentTextCatalogStale(std.testing.allocator, store));
}

test "persistent text catalog rejects self-consistent incomplete term and posting files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage_mod.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();
    try store.appendNode(.{ .id = .fromInt(1), .kind = .function, .text = "alpha beta" });
    const meta = try rebuildPersistentTextCatalog(std.testing.allocator, store);
    try std.testing.expect(meta.term_count > 0);
    try std.testing.expect(meta.posting_count > 0);

    const terms_path = try textTermsPath(std.testing.allocator, store);
    defer std.testing.allocator.free(terms_path);
    var terms_header_bytes: [TextTermsHeader.encoded_len]u8 = undefined;
    encodeTextTermsHeader(.{ .term_count = 0, .term_bytes = 0 }, &terms_header_bytes);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = terms_path,
        .data = &terms_header_bytes,
        .flags = .{ .truncate = true },
    });

    const postings_path = try textPostingsPath(std.testing.allocator, store);
    defer std.testing.allocator.free(postings_path);
    var postings_header_bytes: [TextPostingsHeader.encoded_len]u8 = undefined;
    encodeTextPostingsHeader(.{ .posting_count = 0, .body_bytes = 0 }, &postings_header_bytes);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = postings_path,
        .data = &postings_header_bytes,
        .flags = .{ .truncate = true },
    });

    try std.testing.expect(try persistentTextCatalogStale(std.testing.allocator, store));
    try std.testing.expectError(error.InvalidRecord, readPersistentTermPostings(std.testing.allocator, store, "alpha"));
    var hits = try searchText(std.testing.allocator, store, "alpha", .{ .limit = 5 });
    defer hits.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), hits.items.len);
    try std.testing.expectEqual(core.NodeId.fromInt(1), hits.items[0].node_id);
    try std.testing.expect(try persistentTextCatalogStale(std.testing.allocator, store));
}

test "persistent text catalog detects unsorted persistent term dictionary" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage_mod.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();
    try store.appendNode(.{ .id = .fromInt(1), .kind = .file, .text = "alpha beta gamma" });
    _ = try rebuildPersistentTextCatalog(std.testing.allocator, store);

    const terms_path = try textTermsPath(std.testing.allocator, store);
    defer std.testing.allocator.free(terms_path);
    var terms_file = try std.Io.Dir.cwd().openFile(std.testing.io, terms_path, .{ .mode = .read_write });
    defer terms_file.close(std.testing.io);
    const header = try readTextTermsHeaderFromFile(store, terms_file);
    try std.testing.expect(header.term_count >= 2);
    const corrupt_byte: [1]u8 = .{0xff};
    try terms_file.writePositionalAll(std.testing.io, &corrupt_byte, try textTermsBytesOffset(header.term_count));

    try std.testing.expect(try persistentTextCatalogStale(std.testing.allocator, store));
    try std.testing.expectError(error.InvalidRecord, readPersistentTermPostings(std.testing.allocator, store, "alpha"));
    var hits = try searchText(std.testing.allocator, store, "alpha", .{ .limit = 5 });
    defer hits.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), hits.items.len);
    try std.testing.expectEqual(core.NodeId.fromInt(1), hits.items[0].node_id);
    try std.testing.expect(try persistentTextCatalogStale(std.testing.allocator, store));
}

test "persistent text catalog treats old postings version as stale" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage_mod.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();
    try store.appendNode(.{ .id = .fromInt(1), .kind = .function, .text = "shared readEdgeIndexRecordsByNode" });
    try store.appendNode(.{ .id = .fromInt(2), .kind = .function, .text = "shared repair sentinel" });
    _ = try rebuildPersistentTextCatalog(std.testing.allocator, store);
    try std.testing.expect(!try persistentTextCatalogStale(std.testing.allocator, store));

    const postings_path = try textPostingsPath(std.testing.allocator, store);
    defer std.testing.allocator.free(postings_path);
    var postings_file = try std.Io.Dir.cwd().openFile(std.testing.io, postings_path, .{ .mode = .read_write });
    defer postings_file.close(std.testing.io);
    var old_version: [2]u8 = undefined;
    std.mem.writeInt(u16, &old_version, 1, .little);
    try postings_file.writePositionalAll(std.testing.io, &old_version, 4);

    try std.testing.expect(try persistentTextCatalogStale(std.testing.allocator, store));
}

test "searchText repairs text terms header whose declared size overflows" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage_mod.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();
    try store.appendNode(.{ .id = .fromInt(1), .kind = .function, .text = "shared readEdgeIndexRecordsByNode" });
    try store.appendNode(.{ .id = .fromInt(2), .kind = .function, .text = "shared repair sentinel" });
    var meta = try rebuildPersistentTextCatalog(std.testing.allocator, store);
    try std.testing.expect(!try persistentTextCatalogStale(std.testing.allocator, store));

    meta.term_count = std.math.maxInt(u64);
    try writeTextMetaFile(std.testing.allocator, store, meta);

    const terms_path = try textTermsPath(std.testing.allocator, store);
    defer std.testing.allocator.free(terms_path);
    var terms_file = try std.Io.Dir.cwd().openFile(std.testing.io, terms_path, .{ .mode = .read_write });
    defer terms_file.close(std.testing.io);
    var terms_header = try readTextTermsHeaderFromFile(store, terms_file);
    terms_header.term_count = std.math.maxInt(u64);
    var header_bytes: [TextTermsHeader.encoded_len]u8 = undefined;
    encodeTextTermsHeader(terms_header, &header_bytes);
    try terms_file.writePositionalAll(std.testing.io, &header_bytes, 0);

    try std.testing.expect(try persistentTextCatalogStale(std.testing.allocator, store));
    try std.testing.expectError(error.InvalidRecord, readPersistentTermPostingsUnchecked(std.testing.allocator, store, "edge", core.default_max_text_postings_scanned));
    var hits = try searchText(std.testing.allocator, store, "edge", .{ .limit = 5 });
    defer hits.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), hits.items.len);
    try std.testing.expectEqual(core.NodeId.fromInt(1), hits.items[0].node_id);
    try std.testing.expect(try persistentTextCatalogStale(std.testing.allocator, store));
}

test "searchText repairs text postings header whose declared size overflows" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage_mod.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();
    try store.appendNode(.{ .id = .fromInt(1), .kind = .function, .text = "readEdgeIndexRecordsByNode" });
    var meta = try rebuildPersistentTextCatalog(std.testing.allocator, store);
    try std.testing.expect(!try persistentTextCatalogStale(std.testing.allocator, store));

    meta.posting_count = std.math.maxInt(u64);
    try writeTextMetaFile(std.testing.allocator, store, meta);

    const postings_path = try textPostingsPath(std.testing.allocator, store);
    defer std.testing.allocator.free(postings_path);
    var postings_file = try std.Io.Dir.cwd().openFile(std.testing.io, postings_path, .{ .mode = .read_write });
    defer postings_file.close(std.testing.io);
    var postings_header = try readTextPostingsHeaderFromFile(store, postings_file);
    postings_header.posting_count = std.math.maxInt(u64);
    var header_bytes: [TextPostingsHeader.encoded_len]u8 = undefined;
    encodeTextPostingsHeader(postings_header, &header_bytes);
    try postings_file.writePositionalAll(std.testing.io, &header_bytes, 0);

    try std.testing.expect(try persistentTextCatalogStale(std.testing.allocator, store));
    try std.testing.expectError(error.InvalidRecord, readPersistentTermPostingsUnchecked(std.testing.allocator, store, "edge", core.default_max_text_postings_scanned));
    var hits = try searchText(std.testing.allocator, store, "edge", .{ .limit = 5 });
    defer hits.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), hits.items.len);
    try std.testing.expectEqual(core.NodeId.fromInt(1), hits.items[0].node_id);
    try std.testing.expect(try persistentTextCatalogStale(std.testing.allocator, store));
}

test "persistent text doc readers reject overflowing declared doc count" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage_mod.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();
    try store.appendNode(.{ .id = .fromInt(1), .kind = .function, .text = "readEdgeIndexRecordsByNode" });
    _ = try rebuildPersistentTextCatalog(std.testing.allocator, store);

    const docs_path = try textDocsPath(std.testing.allocator, store);
    defer std.testing.allocator.free(docs_path);
    var docs_file = try std.Io.Dir.cwd().openFile(std.testing.io, docs_path, .{ .mode = .read_write });
    defer docs_file.close(std.testing.io);
    const header = TextDocsHeader{ .doc_count = std.math.maxInt(u64) };
    var header_bytes: [TextDocsHeader.encoded_len]u8 = undefined;
    header.encode(&header_bytes);
    try docs_file.writePositionalAll(std.testing.io, &header_bytes, 0);

    try std.testing.expect(try persistentTextCatalogStale(std.testing.allocator, store));
    try std.testing.expectError(error.InvalidRecord, readPersistentTextDocCount(std.testing.allocator, store));
    try std.testing.expectError(error.InvalidRecord, readPersistentTextDoc(std.testing.allocator, store, 1));
}

const TextIndexFileForTest = enum { meta, docs, terms, postings, blocks, impacts, top_hits };

fn expectTextIndexDirectoryRejected(target: TextIndexFileForTest) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage_mod.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();
    try store.appendNode(.{ .id = .fromInt(1), .kind = .function, .text = "readEdgeIndexRecordsByNode" });
    _ = try rebuildPersistentTextCatalog(std.testing.allocator, store);

    const path = switch (target) {
        .meta => try textMetaPath(std.testing.allocator, store),
        .docs => try textDocsPath(std.testing.allocator, store),
        .terms => try textTermsPath(std.testing.allocator, store),
        .postings => try textPostingsPath(std.testing.allocator, store),
        .blocks => try textPostingBlocksPath(std.testing.allocator, store),
        .impacts => try textPostingBlockImpactsPath(std.testing.allocator, store),
        .top_hits => try textTermTopHitsPath(std.testing.allocator, store),
    };
    defer std.testing.allocator.free(path);
    try std.Io.Dir.cwd().deleteFile(std.testing.io, path);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, path);

    if (target == .meta) {
        try std.testing.expectError(error.IsDir, readPersistentTextMeta(std.testing.allocator, store));
    }
    try std.testing.expectError(error.IsDir, searchText(std.testing.allocator, store, "edge", .{ .limit = 5 }));
}

test "persistent text catalog requires regular derived index files" {
    try expectTextIndexDirectoryRejected(.meta);
    try expectTextIndexDirectoryRejected(.docs);
    try expectTextIndexDirectoryRejected(.terms);
    try expectTextIndexDirectoryRejected(.postings);
    try expectTextIndexDirectoryRejected(.blocks);
    try expectTextIndexDirectoryRejected(.impacts);
    try expectTextIndexDirectoryRejected(.top_hits);
}

test "persistent text catalog rejects corrupt posting block metadata" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage_mod.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();
    try appendRepeatedTextTestNodes(std.testing.allocator, store, 1, persistent_posting_block_size + 1, .task, "edge block metadata repair");
    try store.appendNode(.{ .id = .fromInt(persistent_posting_block_size + 2), .kind = .task, .text = "unrelated" });
    _ = try rebuildPersistentTextCatalog(std.testing.allocator, store);
    try std.testing.expect(!try persistentTextCatalogStale(std.testing.allocator, store));

    const blocks_path = try textPostingBlocksPath(std.testing.allocator, store);
    defer std.testing.allocator.free(blocks_path);
    {
        var blocks_file = try std.Io.Dir.cwd().openFile(std.testing.io, blocks_path, .{ .mode = .read_write });
        defer blocks_file.close(std.testing.io);
        const blocks_header = try readTextPostingBlocksHeaderFromFile(store, blocks_file);
        var checkpoint_bytes: [persistent_posting_block_ordinal_len]u8 = undefined;
        try encodePersistentBlockOrdinal(1, &checkpoint_bytes);
        try blocks_file.writePositionalAll(std.testing.io, &checkpoint_bytes, try textPostingBlockCheckpointOffset(blocks_header.block_count, 0));
    }
    try std.testing.expect(try persistentTextCatalogStale(std.testing.allocator, store));

    _ = try rebuildPersistentTextCatalog(std.testing.allocator, store);
    try std.testing.expect(!try persistentTextCatalogStale(std.testing.allocator, store));

    {
        var blocks_file = try std.Io.Dir.cwd().openFile(std.testing.io, blocks_path, .{ .mode = .read_write });
        defer blocks_file.close(std.testing.io);
        const blocks_header = try readTextPostingBlocksHeaderFromFile(store, blocks_file);
        var checkpoint_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &checkpoint_bytes, 1, .little);
        try blocks_file.writePositionalAll(std.testing.io, &checkpoint_bytes, try textPostingBlockByteOffsetCheckpointOffset(blocks_header.term_count, blocks_header.block_count, 0));
    }
    try std.testing.expect(try persistentTextCatalogStale(std.testing.allocator, store));

    _ = try rebuildPersistentTextCatalog(std.testing.allocator, store);
    try std.testing.expect(!try persistentTextCatalogStale(std.testing.allocator, store));

    {
        var blocks_file = try std.Io.Dir.cwd().openFile(std.testing.io, blocks_path, .{ .mode = .read_write });
        defer blocks_file.close(std.testing.io);
        const blocks_header = try readTextPostingBlocksHeaderFromFile(store, blocks_file);
        const record = try readTextPostingBlockRecordAt(store, blocks_file, blocks_header.term_count, 0);
        var record_bytes: [TextPostingBlockRecord.encoded_len]u8 = undefined;
        try encodeTextPostingBlockRecord(record, &record_bytes);
        std.mem.writeInt(u16, record_bytes[search_acceleration_format.Internal.block_record_max_tf_offset..search_acceleration_format.Internal.block_record_min_doc_len_offset], @as(u16, @bitCast(std.math.nan(f16))), .little);
        try blocks_file.writePositionalAll(std.testing.io, &record_bytes, try textPostingBlockRecordOffset(blocks_header.term_count, 0));
    }
    try std.testing.expect(try persistentTextCatalogStale(std.testing.allocator, store));
}

test "persistent text catalog rejects corrupt posting block impact order" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage_mod.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    var high_text = std.ArrayList(u8).empty;
    defer high_text.deinit(std.testing.allocator);
    var repeat: usize = 0;
    while (repeat < test_high_impact_repeated_term_count) : (repeat += 1) {
        if (repeat != 0) try high_text.append(std.testing.allocator, ' ');
        try high_text.appendSlice(std.testing.allocator, "edge");
    }

    try appendRepeatedTextTestNodes(std.testing.allocator, store, 1, 64, .task, "edge");
    try store.appendNode(.{ .id = .fromInt(65), .kind = .task, .text = high_text.items });
    try store.appendNode(.{ .id = .fromInt(66), .kind = .task, .text = "unrelated" });
    _ = try rebuildPersistentTextCatalog(std.testing.allocator, store);
    try std.testing.expect(!try persistentTextCatalogStale(std.testing.allocator, store));

    const impacts_path = try textPostingBlockImpactsPath(std.testing.allocator, store);
    defer std.testing.allocator.free(impacts_path);
    {
        var impacts_file = try std.Io.Dir.cwd().openFile(std.testing.io, impacts_path, .{ .mode = .read_write });
        defer impacts_file.close(std.testing.io);
        const impacts_header = try readTextPostingBlockImpactsHeaderFromFile(store, impacts_file);
        var bytes: [persistent_posting_block_ordinal_len]u8 = undefined;
        try encodePersistentBlockOrdinal(0, &bytes);
        try impacts_file.writePositionalAll(std.testing.io, &bytes, try textPostingBlockImpactRecordOffset(impacts_header.term_count, 0));
    }

    try std.testing.expect(try persistentTextCatalogStale(std.testing.allocator, store));
    var hits = try searchText(std.testing.allocator, store, "edge", .{ .limit = 1, .max_postings_scanned = persistent_posting_block_capacity });
    defer hits.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), hits.items.len);
    try std.testing.expectEqual(core.NodeId.fromInt(65), hits.items[0].node_id);
    try std.testing.expect(try persistentTextCatalogStale(std.testing.allocator, store));
}

test "persistent text catalog rejects invalid term entry length" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage_mod.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();
    try store.appendNode(.{ .id = .fromInt(1), .kind = .function, .text = "readEdgeIndexRecordsByNode" });
    _ = try rebuildPersistentTextCatalog(std.testing.allocator, store);

    const terms_path = try textTermsPath(std.testing.allocator, store);
    defer std.testing.allocator.free(terms_path);
    {
        var terms_file = try std.Io.Dir.cwd().openFile(std.testing.io, terms_path, .{ .mode = .read_write });
        defer terms_file.close(std.testing.io);
        const header = try readTextTermsHeaderFromFile(store, terms_file);
        const entry = try readTextTermEntryAt(store, terms_file, header, 0);
        var entry_bytes: [TextTermEntry.encoded_len]u8 = undefined;
        try encodeTextTermEntry(entry, &entry_bytes);
        entry_bytes[0] = front_coded_entry_prefix_marker;
        try terms_file.writePositionalAll(std.testing.io, &entry_bytes, try textTermEntryOffset(0));
        try terms_file.sync(std.testing.io);
        try std.testing.expectError(error.InvalidRecord, readTextTermEntryAt(store, terms_file, header, 0));
    }
    {
        var terms_file = try std.Io.Dir.cwd().openFile(std.testing.io, terms_path, .{});
        defer terms_file.close(std.testing.io);
        const header = try readTextTermsHeaderFromFile(store, terms_file);
        try std.testing.expectError(error.InvalidRecord, readTextTermEntryAt(store, terms_file, header, 0));
    }

    const text_meta = try readPersistentTextMeta(std.testing.allocator, store);
    try std.testing.expect(try persistentTermsOrPostingsStale(std.testing.allocator, store, text_meta, .none));
    try std.testing.expect(try persistentTextCatalogStale(std.testing.allocator, store));
    var hits = try searchText(std.testing.allocator, store, "edge", .{ .limit = 5 });
    defer hits.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), hits.items.len);
    try std.testing.expectEqual(core.NodeId.fromInt(1), hits.items[0].node_id);
    try std.testing.expect(try persistentTextCatalogStale(std.testing.allocator, store));
}

test "searchText falls back without repairing term exception sidecar membership mismatch" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage_mod.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();
    try store.appendNode(.{ .id = .fromInt(1), .kind = .function, .text = "readEdgeIndexRecordsByNode" });
    _ = try rebuildPersistentTextCatalog(std.testing.allocator, store);

    const terms_path = try textTermsPath(std.testing.allocator, store);
    defer std.testing.allocator.free(terms_path);
    {
        var terms_file = try std.Io.Dir.cwd().openFile(std.testing.io, terms_path, .{ .mode = .read_write });
        defer terms_file.close(std.testing.io);
        var terms_header = try readTextTermsHeaderFromFile(store, terms_file);
        try std.testing.expect(terms_header.term_count > 0);
        try std.testing.expectEqual(@as(u64, 0), terms_header.term_exception_count);

        terms_header.term_exception_count = 1;
        var header_bytes: [TextTermsHeader.encoded_len]u8 = undefined;
        encodeTextTermsHeader(terms_header, &header_bytes);
        try terms_file.writePositionalAll(std.testing.io, &header_bytes, 0);

        var rank_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &rank_bytes, 0, .little);
        try terms_file.writePositionalAll(std.testing.io, &rank_bytes, try textTermExceptionRankCheckpointOffset(terms_header.term_count, terms_header.term_bytes, 0));
        const empty_membership = [_]u8{0};
        try terms_file.writePositionalAll(std.testing.io, &empty_membership, try textTermExceptionMembershipByteOffset(terms_header.term_count, terms_header.term_bytes, 0));

        var exception_bytes: [TextTermExceptionRecord.encoded_len]u8 = undefined;
        try encodeTextTermExceptionRecord(.{ .doc_freq = 70_000, .postings_offset = 0 }, &exception_bytes);
        try terms_file.writePositionalAll(std.testing.io, &exception_bytes, try textTermExceptionRecordOffset(terms_header.term_count, terms_header.term_bytes, 0));
        try terms_file.sync(std.testing.io);
    }

    try std.testing.expect(try persistentTextCatalogStale(std.testing.allocator, store));
    var hits = try searchText(std.testing.allocator, store, "edge", .{ .limit = 5 });
    defer hits.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), hits.items.len);
    try std.testing.expectEqual(core.NodeId.fromInt(1), hits.items[0].node_id);
    try std.testing.expect(try persistentTextCatalogStale(std.testing.allocator, store));
}

test "searchText repairs corrupt term posting offset encountered during query" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage_mod.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();
    try store.appendNode(.{ .id = .fromInt(1), .kind = .function, .text = "readEdgeIndexRecordsByNode" });
    _ = try rebuildPersistentTextCatalog(std.testing.allocator, store);

    const terms_path = try textTermsPath(std.testing.allocator, store);
    defer std.testing.allocator.free(terms_path);
    var terms_file = try std.Io.Dir.cwd().openFile(std.testing.io, terms_path, .{ .mode = .read_write });
    defer terms_file.close(std.testing.io);
    const terms_header = try readTextTermsHeaderFromFile(store, terms_file);
    const postings_path = try textPostingsPath(std.testing.allocator, store);
    defer std.testing.allocator.free(postings_path);
    var postings_file = try std.Io.Dir.cwd().openFile(std.testing.io, postings_path, .{});
    defer postings_file.close(std.testing.io);
    const postings_header = try readTextPostingsHeaderFromFile(store, postings_file);
    const corrupt_postings_offset = persistent_postings_body_max_offset;
    try std.testing.expect(postings_header.body_bytes < corrupt_postings_offset);

    var pos: u64 = 0;
    var corrupted = false;
    while (pos < terms_header.term_count) : (pos += 1) {
        var entry = try readTextTermEntryAt(store, terms_file, terms_header, pos);
        if (entry.term_len != "edge".len) continue;
        if (!try termEntryMatches(store, terms_file, terms_header, pos, entry, "edge")) continue;
        entry.postings_offset = corrupt_postings_offset;
        var entry_bytes: [TextTermEntry.encoded_len]u8 = undefined;
        try encodeTextTermEntry(entry, &entry_bytes);
        try terms_file.writePositionalAll(std.testing.io, &entry_bytes, try textTermEntryOffset(pos));
        corrupted = true;
        break;
    }
    try std.testing.expect(corrupted);

    var hits = try searchText(std.testing.allocator, store, "edge", .{ .limit = 5 });
    defer hits.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), hits.items.len);
    try std.testing.expectEqual(core.NodeId.fromInt(1), hits.items[0].node_id);
    try std.testing.expect(!try persistentTextCatalogStale(std.testing.allocator, store));
}

test "searchText falls back without repairing corrupt posting frequencies" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage_mod.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();
    try store.appendNode(.{ .id = .fromInt(1), .kind = .function, .text = "shared readEdgeIndexRecordsByNode" });
    try store.appendNode(.{ .id = .fromInt(2), .kind = .function, .text = "shared repair sentinel" });
    _ = try rebuildPersistentTextCatalog(std.testing.allocator, store);

    const terms_path = try textTermsPath(std.testing.allocator, store);
    defer std.testing.allocator.free(terms_path);
    var terms_view = try TextTermsFileView.open(store, terms_path);
    defer terms_view.deinit();
    const terms_header = try terms_view.readHeader();

    const postings_path = try textPostingsPath(std.testing.allocator, store);
    defer std.testing.allocator.free(postings_path);
    var corrupted_term_buf: [default_max_token_bytes]u8 = undefined;
    var corrupted_term_len: usize = 0;
    {
        var postings_file = try std.Io.Dir.cwd().openFile(std.testing.io, postings_path, .{ .mode = .read_write });
        defer postings_file.close(std.testing.io);

        var pos: u64 = 0;
        var corrupted = false;
        while (pos < terms_header.term_count) : (pos += 1) {
            const entry = try terms_view.readEntryAt(terms_header, pos);
            if (entry.postings_count < 2 or termEntryHasInlinePosting(entry)) continue;
            const term = try terms_view.termEntryBytesAt(terms_header, pos, entry, &corrupted_term_buf);
            corrupted_term_len = term.len;
            var posting = try readTextPostingRecordAt(store, postings_file, entry.postings_offset);
            posting.text_freq = 99;
            var bytes: [TextPostingRecord.encoded_len]u8 = undefined;
            try encodeTextPostingRecord(posting, &bytes);
            try postings_file.writePositionalAll(std.testing.io, &bytes, try textPostingRecordOffset(entry.postings_offset));
            try postings_file.sync(std.testing.io);
            corrupted = true;
            break;
        }
        try std.testing.expect(corrupted);
    }
    const corrupted_term = corrupted_term_buf[0..corrupted_term_len];

    try std.testing.expect(try persistentTextCatalogStale(std.testing.allocator, store));
    try std.testing.expectError(error.InvalidRecord, readPersistentTermPostings(std.testing.allocator, store, corrupted_term));
    var hits = try searchText(std.testing.allocator, store, corrupted_term, .{ .limit = 5 });
    defer hits.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), hits.items.len);
    try std.testing.expect(try persistentTextCatalogStale(std.testing.allocator, store));
    try std.testing.expectError(error.InvalidRecord, readPersistentTermPostings(std.testing.allocator, store, corrupted_term));
}

test "readPersistentTermPostings rejects duplicate or unsorted doc ids" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage_mod.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();
    try store.appendNode(.{ .id = .fromInt(1), .kind = .function, .text = "edge duplicate first" });
    try store.appendNode(.{ .id = .fromInt(2), .kind = .function, .text = "edge duplicate second" });
    _ = try rebuildPersistentTextCatalog(std.testing.allocator, store);

    const terms_path = try textTermsPath(std.testing.allocator, store);
    defer std.testing.allocator.free(terms_path);
    var terms_file = try std.Io.Dir.cwd().openFile(std.testing.io, terms_path, .{});
    defer terms_file.close(std.testing.io);
    const terms_header = try readTextTermsHeaderFromFile(store, terms_file);

    const postings_path = try textPostingsPath(std.testing.allocator, store);
    defer std.testing.allocator.free(postings_path);
    var postings_file = try std.Io.Dir.cwd().openFile(std.testing.io, postings_path, .{ .mode = .read_write });
    defer postings_file.close(std.testing.io);

    var pos: u64 = 0;
    var corrupted = false;
    while (pos < terms_header.term_count) : (pos += 1) {
        const entry = try readTextTermEntryAt(store, terms_file, terms_header, pos);
        if (entry.term_len != "edge".len or entry.postings_count < 2) continue;
        if (!try termEntryMatches(store, terms_file, terms_header, pos, entry, "edge")) continue;
        const first = try readTextPostingRecordAt(store, postings_file, entry.postings_offset);
        try std.testing.expect(first.doc_id > 0);
        const second_offset = try textPostingOffsetAfterSkipping(store, postings_file, entry.postings_offset, 1);
        const duplicate_delta: [1]u8 = .{0};
        try postings_file.writePositionalAll(std.testing.io, &duplicate_delta, try textPostingRecordOffset(second_offset));
        corrupted = true;
        break;
    }
    try std.testing.expect(corrupted);

    try std.testing.expectError(error.InvalidRecord, readPersistentTermPostings(std.testing.allocator, store, "edge"));
}

test "persistent text stale detection rejects postings outside doc catalog" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage_mod.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();
    try store.appendNode(.{ .id = .fromInt(1), .kind = .function, .text = "edge orphan" });
    try store.appendNode(.{ .id = .fromInt(2), .kind = .function, .text = "edge sentinel" });
    _ = try rebuildPersistentTextCatalog(std.testing.allocator, store);

    const terms_path = try textTermsPath(std.testing.allocator, store);
    defer std.testing.allocator.free(terms_path);
    var terms_file = try std.Io.Dir.cwd().openFile(std.testing.io, terms_path, .{});
    defer terms_file.close(std.testing.io);
    const terms_header = try readTextTermsHeaderFromFile(store, terms_file);

    const postings_path = try textPostingsPath(std.testing.allocator, store);
    defer std.testing.allocator.free(postings_path);
    var postings_file = try std.Io.Dir.cwd().openFile(std.testing.io, postings_path, .{ .mode = .read_write });
    defer postings_file.close(std.testing.io);

    var pos: u64 = 0;
    var corrupted = false;
    while (pos < terms_header.term_count) : (pos += 1) {
        const entry = try readTextTermEntryAt(store, terms_file, terms_header, pos);
        if (entry.term_len != "edge".len) continue;
        if (!try termEntryMatches(store, terms_file, terms_header, pos, entry, "edge")) continue;
        var posting = try readTextPostingRecordAt(store, postings_file, entry.postings_offset);
        posting.doc_id = 3;
        var bytes: [TextPostingRecord.encoded_len]u8 = undefined;
        try encodeTextPostingRecord(posting, &bytes);
        try postings_file.writePositionalAll(std.testing.io, &bytes, try textPostingRecordOffset(entry.postings_offset));
        corrupted = true;
        break;
    }
    try std.testing.expect(corrupted);

    try std.testing.expect(try persistentTextCatalogStale(std.testing.allocator, store));
    try std.testing.expectError(error.InvalidRecord, readPersistentTermPostings(std.testing.allocator, store, "edge"));
}

test "searchText falls back without repairing text docs that reference missing graph nodes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage_mod.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();
    try store.appendNode(.{ .id = .fromInt(1), .kind = .file, .text = "storage index" });
    _ = try rebuildPersistentTextCatalog(std.testing.allocator, store);

    const docs_path = try textDocsPath(std.testing.allocator, store);
    defer std.testing.allocator.free(docs_path);
    var docs_file = try std.Io.Dir.cwd().openFile(std.testing.io, docs_path, .{ .mode = .read_write });
    defer docs_file.close(std.testing.io);
    var doc = try readTextDocRecordAt(store, docs_file, 0);
    doc.node_id = 999;
    var bytes: [TextDocRecord.encoded_len]u8 = undefined;
    try doc.encode(&bytes);
    try docs_file.writePositionalAll(std.testing.io, &bytes, try textDocRecordOffset(0));

    var hits = try searchText(std.testing.allocator, store, "storage", .{ .limit = 5 });
    defer hits.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), hits.items.len);
    try std.testing.expectEqual(core.NodeId.fromInt(1), hits.items[0].node_id);
    try std.testing.expect(try persistentTextCatalogStale(std.testing.allocator, store));
}

test "persistent text docs reject corrupt dense node id header" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage_mod.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();
    try store.appendNode(.{ .id = .fromInt(1), .kind = .file, .text = "storage index" });
    _ = try rebuildPersistentTextCatalog(std.testing.allocator, store);

    const docs_path = try textDocsPath(std.testing.allocator, store);
    defer std.testing.allocator.free(docs_path);
    var docs_file = try std.Io.Dir.cwd().openFile(std.testing.io, docs_path, .{ .mode = .read_write });
    defer docs_file.close(std.testing.io);
    var header = try readTextDocsHeaderFromFile(store, docs_file);
    try std.testing.expect(header.hasDenseUniformRecords());
    header.dense_node_id_base = 0;
    var bytes: [TextDocsHeader.encoded_len]u8 = undefined;
    header.encode(&bytes);
    try docs_file.writePositionalAll(std.testing.io, &bytes, 0);
    try std.testing.expectError(error.InvalidRecord, readTextDocRecordAt(store, docs_file, 0));
    try std.testing.expect(try persistentTextCatalogStale(std.testing.allocator, store));
}

test "persistent text postings reject reserved max doc id" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage_mod.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();
    try store.appendNode(.{ .id = .fromInt(1), .kind = .function, .text = "edge orphan" });
    _ = try rebuildPersistentTextCatalog(std.testing.allocator, store);

    const terms_path = try textTermsPath(std.testing.allocator, store);
    defer std.testing.allocator.free(terms_path);
    var terms_file = try std.Io.Dir.cwd().openFile(std.testing.io, terms_path, .{});
    defer terms_file.close(std.testing.io);
    const terms_header = try readTextTermsHeaderFromFile(store, terms_file);

    const postings_path = try textPostingsPath(std.testing.allocator, store);
    defer std.testing.allocator.free(postings_path);
    var postings_file = try std.Io.Dir.cwd().openFile(std.testing.io, postings_path, .{ .mode = .read_write });
    defer postings_file.close(std.testing.io);

    var pos: u64 = 0;
    var corrupted = false;
    while (pos < terms_header.term_count) : (pos += 1) {
        const entry = try readTextTermEntryAt(store, terms_file, terms_header, pos);
        if (entry.term_len != "edge".len) continue;
        if (!try termEntryMatches(store, terms_file, terms_header, pos, entry, "edge")) continue;
        var bytes: [compressed_posting_max_encoded_len]u8 = undefined;
        var cursor: usize = 0;
        cursor += try encodePersistentVarint(std.math.maxInt(u64) - 6, bytes[cursor..]);
        cursor += try encodePersistentVarint(2, bytes[cursor..]);
        try postings_file.writePositionalAll(std.testing.io, bytes[0..cursor], try textPostingRecordOffset(entry.postings_offset));
        try std.testing.expectError(error.RecordTooLarge, readTextPostingRecordAt(store, postings_file, entry.postings_offset));
        corrupted = true;
        break;
    }
    try std.testing.expect(corrupted);
    try std.testing.expect(try persistentTextCatalogStale(std.testing.allocator, store));
    try std.testing.expectError(error.InvalidRecord, readPersistentTermPostings(std.testing.allocator, store, "edge"));
}

test "searchText falls back without repairing text docs with corrupt token counts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage_mod.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();
    try store.appendNode(.{ .id = .fromInt(1), .kind = .file, .text = "storage index" });
    _ = try rebuildPersistentTextCatalog(std.testing.allocator, store);

    const docs_path = try textDocsPath(std.testing.allocator, store);
    defer std.testing.allocator.free(docs_path);
    {
        var docs_file = try std.Io.Dir.cwd().openFile(std.testing.io, docs_path, .{ .mode = .read_write });
        defer docs_file.close(std.testing.io);
        var doc = try readTextDocRecordAt(store, docs_file, 0);
        doc.text_tokens = std.math.maxInt(u16);
        var bytes: [TextDocRecord.encoded_len]u8 = undefined;
        try doc.encode(&bytes);
        try docs_file.writePositionalAll(std.testing.io, &bytes, try textDocRecordOffset(0));
        try docs_file.sync(std.testing.io);
    }

    const docs_size_before = try textPathFileSize(std.testing.io, docs_path);

    var hits = try searchText(std.testing.allocator, store, "storage", .{ .limit = 5 });
    defer hits.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), hits.items.len);
    try std.testing.expectEqual(core.NodeId.fromInt(1), hits.items[0].node_id);
    try std.testing.expect(try persistentTextCatalogStale(std.testing.allocator, store));

    var docs_file = try std.Io.Dir.cwd().openFile(std.testing.io, docs_path, .{});
    defer docs_file.close(std.testing.io);
    try std.testing.expectEqual(docs_size_before, (try docs_file.stat(std.testing.io)).size);
}

test "rebuildPersistentTextCatalog repairs corrupt graph node indexes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage_mod.Store.initWithOptions(std.testing.allocator, std.testing.io, store_path, .{
        .primary_text_write_mode = .bulk_ingest,
        .validate_indexes_on_read = true,
    });
    defer store.deinit();
    try store.createEmpty();
    try store.appendNode(.{ .id = .fromInt(1), .kind = .file, .text = "storage index" });

    var texts_file = try std.Io.Dir.cwd().createFile(std.testing.io, store.node_texts_path, .{
        .read = true,
        .truncate = false,
    });
    defer texts_file.close(std.testing.io);
    try texts_file.writePositionalAll(std.testing.io, "trailing garbage", (try texts_file.stat(std.testing.io)).size);

    try std.testing.expectError(error.InvalidRecord, store.readNodeById(std.testing.allocator, .fromInt(1)));
    const meta = try rebuildPersistentTextCatalog(std.testing.allocator, store);
    try std.testing.expectEqual(@as(u64, 1), meta.doc_count);

    var repaired = (try store.readNodeById(std.testing.allocator, .fromInt(1))).?;
    defer repaired.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("storage index", repaired.text);
}

test "TextIndex buildFromStore repairs corrupt graph node indexes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage_mod.Store.initWithOptions(std.testing.allocator, std.testing.io, store_path, .{
        .primary_text_write_mode = .bulk_ingest,
        .validate_indexes_on_read = true,
    });
    defer store.deinit();
    try store.createEmpty();
    try store.appendNode(.{ .id = .fromInt(1), .kind = .file, .text = "storage index" });

    var texts_file = try std.Io.Dir.cwd().createFile(std.testing.io, store.node_texts_path, .{
        .read = true,
        .truncate = false,
    });
    defer texts_file.close(std.testing.io);
    try texts_file.writePositionalAll(std.testing.io, "trailing garbage", (try texts_file.stat(std.testing.io)).size);

    try std.testing.expectError(error.InvalidRecord, store.readNodeById(std.testing.allocator, .fromInt(1)));
    var index = try TextIndex.buildFromStore(std.testing.allocator, store);
    defer index.deinit();

    var hits = try index.search("storage", .{ .limit = 5 });
    defer hits.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), hits.items.len);
    try std.testing.expectEqual(core.NodeId.fromInt(1), hits.items[0].node_id);
}

test "searchText falls back to event log without repairing corrupt graph node indexes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage_mod.Store.initWithOptions(std.testing.allocator, std.testing.io, store_path, .{
        .primary_text_write_mode = .bulk_ingest,
        .validate_indexes_on_read = true,
    });
    defer store.deinit();
    try store.createEmpty();
    try store.appendNode(.{ .id = .fromInt(1), .kind = .file, .text = "storage index" });
    _ = try rebuildPersistentTextCatalog(std.testing.allocator, store);

    var texts_file = try std.Io.Dir.cwd().createFile(std.testing.io, store.node_texts_path, .{
        .read = true,
        .truncate = false,
    });
    defer texts_file.close(std.testing.io);
    try texts_file.writePositionalAll(std.testing.io, "trailing garbage", (try texts_file.stat(std.testing.io)).size);

    try std.testing.expectError(error.InvalidRecord, store.readNodeById(std.testing.allocator, .fromInt(1)));
    var hits = try searchText(std.testing.allocator, store, "storage", .{ .limit = 5 });
    defer hits.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), hits.items.len);
    try std.testing.expectEqual(core.NodeId.fromInt(1), hits.items[0].node_id);
    try std.testing.expect(try persistentTextCatalogStale(std.testing.allocator, store));
    try std.testing.expectError(error.InvalidRecord, store.readNodeById(std.testing.allocator, .fromInt(1)));
}
