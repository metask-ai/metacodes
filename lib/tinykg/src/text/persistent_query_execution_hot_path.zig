const std = @import("std");
const scoring_mod = @import("scoring.zig");
const search_contract_mod = @import("search_contract.zig");

fn singleUniqueQueryTerm(query_terms: anytype) ?[]const u8 {
    if (query_terms.len == 0) return null;
    const first = query_terms[0];
    for (query_terms[1..]) |term| {
        if (!std.mem.eql(u8, first, term)) return null;
    }
    return first;
}

fn persistentQueryTermPlansExceedPostingsBudget(plans: anytype, max_postings_scanned: usize) !bool {
    var remaining = max_postings_scanned;
    for (plans) |plan| {
        const count = std.math.cast(usize, plan.lookup.entry.postings_count) orelse return error.RecordTooLarge;
        if (count > remaining) return true;
        remaining -= count;
    }
    return false;
}

const PersistentMultiTermCandidateMode = enum { top_hits_only, allow_cjk_anchor };

fn persistentCandidateTermFreqKey(max_doc_id: u64, doc_id: u64, query_term_index: usize) !u64 {
    if (doc_id == 0 or doc_id > max_doc_id) return error.InvalidRecord;
    if (query_term_index > std.math.maxInt(u16)) return error.RecordTooLarge;
    return (doc_id << 16) | @as(u64, @intCast(query_term_index));
}

const PostingBlockSeenSet = union(enum) {
    inline_bits: struct { bits: u64 = 0, seen_count: u64 = 0 },
    heap_bits: struct { bits: std.DynamicBitSetUnmanaged, seen_count: u64 = 0 },

    fn init(allocator: std.mem.Allocator, block_count: u64) !PostingBlockSeenSet {
        if (block_count <= 64) return .{ .inline_bits = .{} };
        return .{ .heap_bits = .{
            .bits = try std.DynamicBitSetUnmanaged.initEmpty(allocator, std.math.cast(usize, block_count) orelse return error.RecordTooLarge),
        } };
    }

    fn deinit(self: *PostingBlockSeenSet, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .inline_bits => {},
            .heap_bits => |*heap| heap.bits.deinit(allocator),
        }
    }

    fn mark(self: *PostingBlockSeenSet, index: usize) !void {
        switch (self.*) {
            .inline_bits => |*inline_bits| {
                if (index >= 64) return error.InvalidRecord;
                const mask = @as(u64, 1) << @intCast(index);
                if ((inline_bits.bits & mask) != 0) return error.InvalidRecord;
                inline_bits.bits |= mask;
                inline_bits.seen_count += 1;
            },
            .heap_bits => |*heap| {
                if (heap.bits.isSet(index)) return error.InvalidRecord;
                heap.bits.set(index);
                heap.seen_count += 1;
            },
        }
    }

    fn count(self: *const PostingBlockSeenSet) u64 {
        return switch (self.*) {
            .inline_bits => |inline_bits| inline_bits.seen_count,
            .heap_bits => |heap| heap.seen_count,
        };
    }
};

test "persistent query hot path recognizes one unique term" {
    const terms = [_][]const u8{ "tinykg", "tinykg" };
    try std.testing.expectEqualStrings("tinykg", singleUniqueQueryTerm(&terms).?);
    const mixed = [_][]const u8{ "tinykg", "metacodes" };
    try std.testing.expect(singleUniqueQueryTerm(&mixed) == null);
}

test "persistent query hot path fails closed when a posting plan exceeds budget" {
    const FakePlan = struct { lookup: struct { entry: struct { postings_count: u64 } } };
    const plans = [_]FakePlan{
        .{ .lookup = .{ .entry = .{ .postings_count = 4 } } },
        .{ .lookup = .{ .entry = .{ .postings_count = 7 } } },
    };
    try std.testing.expect(try persistentQueryTermPlansExceedPostingsBudget(&plans, 10));
    try std.testing.expect(!(try persistentQueryTermPlansExceedPostingsBudget(&plans, 11)));
}

test "persistent query hot path candidate keys isolate query terms" {
    const first = try persistentCandidateTermFreqKey(1024, 17, 0);
    const second = try persistentCandidateTermFreqKey(1024, 17, 1);
    try std.testing.expect(first != second);
    try std.testing.expectError(error.InvalidRecord, persistentCandidateTermFreqKey(1024, 0, 0));
}

test "persistent query hot path block seen set rejects duplicate blocks" {
    var seen = try PostingBlockSeenSet.init(std.testing.allocator, 64);
    defer seen.deinit(std.testing.allocator);
    try seen.mark(0);
    try seen.mark(63);
    try std.testing.expectEqual(@as(u64, 2), seen.count());
    try std.testing.expectError(error.InvalidRecord, seen.mark(63));
}

/// Owns persistent token execution after query admission has selected the
/// current on-disk catalog. The façade supplies private readers, catalog
/// codecs, and canonical-document validation through one compile-time backend;
/// the runtime surface remains one search operation.
pub fn PersistentQueryExecutionHotPath(
    comptime core: type,
    comptime schema: type,
    comptime storage_mod: type,
    comptime Ops: type,
) type {
    return struct {
        const search_contract = search_contract_mod.SearchContract(core, schema, @import("tokenizer.zig"), scoring_mod);
        const TextSearchOptions = search_contract.TextSearchOptions;
        const TextSearchHit = search_contract.TextSearchHit;
        const PersistentTextMeta = Ops.PersistentTextMeta_dep;
        const PersistentPostingCatalog = Ops.PersistentPostingCatalog_dep;
        const TextDocsFileView = Ops.TextDocsFileView_dep;
        const CachedTextDoc = Ops.CachedTextDoc_dep;
        const TextDocRecord = Ops.TextDocRecord_dep;
        const PersistentQueryTermPlan = Ops.PersistentQueryTermPlan_dep;
        const PersistentQueryTermFreqCache = Ops.PersistentQueryTermFreqCache_dep;
        const PersistentSearchTermContext = Ops.PersistentSearchTermContext_dep;
        const PersistentSearchCandidateContext = Ops.PersistentSearchCandidateContext_dep;
        const PersistentSearchMediumTopCandidateContext = Ops.PersistentSearchMediumTopCandidateContext_dep;
        const SingleTermSearchContext = Ops.SingleTermSearchContext_dep;
        const FieldTermFreq = Ops.FieldTermFreq_dep;

        const persistent_query_term_freq_cache_max_terms = Ops.persistent_query_term_freq_cache_max_terms_dep;
        const persistent_multi_term_exact_candidate_max_postings = Ops.persistent_multi_term_exact_candidate_max_postings_dep;
        const persistent_search_canonical_freq_validate_posting_limit = Ops.persistent_search_canonical_freq_validate_posting_limit_dep;
        const persistent_term_top_hit_capacity = Ops.persistent_term_top_hit_capacity_dep;
        const persistent_term_top_hit_capacity_usize = Ops.persistent_term_top_hit_capacity_usize_dep;

        const readPersistentTextMeta = Ops.readPersistentTextMeta_dep;
        const deinitCachedTextDocs = Ops.deinitCachedTextDocs_dep;
        const openPersistentTextDocsView = Ops.openPersistentTextDocsView_dep;
        const persistentAvgDocLen = Ops.persistentAvgDocLen_dep;
        const persistentQueryTermPlanLessThan = Ops.persistentQueryTermPlanLessThan_dep;
        const persistentQueryTermPlanPostingTotal = Ops.persistentQueryTermPlanPostingTotal_dep;
        const forEachPersistentTermPostingLookupInCatalog = Ops.forEachPersistentTermPostingLookupInCatalog_dep;
        const scorePersistentSearchPosting = Ops.scorePersistentSearchPosting_dep;
        const getCachedTextDocFromView = Ops.getCachedTextDocFromView_dep;
        const getCachedTextDocRecordFromView = Ops.getCachedTextDocRecordFromView_dep;
        const textBenchTraceEnabled = Ops.textBenchTraceEnabled_dep;
        const canUsePersistentTermTopHitCandidateCache = Ops.canUsePersistentTermTopHitCandidateCache_dep;
        const textTermTopHitsPath = Ops.textTermTopHitsPath_dep;
        const regularFileSize = Ops.regularFileSize_dep;
        const readTextTermTopHitsHeaderFromFile = Ops.readTextTermTopHitsHeaderFromFile_dep;
        const textTermTopHitsFileSize = Ops.textTermTopHitsFileSize_dep;
        const putPersistentCandidateTextFreq = Ops.putPersistentCandidateTextFreq_dep;
        const collectPersistentSearchMediumTopCandidatePosting = Ops.collectPersistentSearchMediumTopCandidatePosting_dep;
        const collectPersistentSearchCandidatePosting = Ops.collectPersistentSearchCandidatePosting_dep;
        const readTextTermTopHitTermAt = Ops.readTextTermTopHitTermAt_dep;
        const readTextTermTopHitRecordAt = Ops.readTextTermTopHitRecordAt_dep;
        const fillPersistentCandidateTextFreqsFromCatalogDeadline = Ops.fillPersistentCandidateTextFreqsFromCatalogDeadline_dep;
        const catalogTextFreqForDoc = Ops.catalogTextFreqForDoc_dep;
        const persistentWeightedTfFromFieldFreq = Ops.persistentWeightedTfFromFieldFreq_dep;
        const persistentDocLen = Ops.persistentDocLen_dep;
        const canUsePersistentTermTopHitCache = Ops.canUsePersistentTermTopHitCache_dep;
        const readPersistentTermTopHitCache = Ops.readPersistentTermTopHitCache_dep;
        const publishedPostingBlockCountForEntry = Ops.publishedPostingBlockCountForEntry_dep;
        const scanPersistentTermPostings = Ops.scanPersistentTermPostings_dep;
        const appendSingleTermSearchPosting = Ops.appendSingleTermSearchPosting_dep;
        const persistentBlockPostingCount = Ops.persistentBlockPostingCount_dep;
        const scanPersistentPostingRange = Ops.scanPersistentPostingRange_dep;

        const termHasNonCjkCodepoint = search_contract.Internal.termHasNonCjkCodepoint;
        const isCjkMultiCodepointTerm = search_contract.Internal.isCjkMultiCodepointTerm;
        const countQueryTermOccurrences = search_contract.Internal.countQueryTermOccurrences;
        const cjkBigramCoverageFloor = search_contract.Internal.cjkBigramCoverageFloor;
        const textSearchHasNodeFilter = search_contract.Internal.hasNodeFilter;
        const textSearchMatchesNodeKind = search_contract.Internal.matchesNodeKind;
        const textSearchPreallocCapacity = search_contract.Internal.preallocCapacity;
        const appendTopTextHitBoundedCachedWorst = search_contract.Internal.appendTopHitBoundedCachedWorst;
        const worstTopTextHitScore = search_contract.Internal.worstTopHitScore;
        const textSearchHitLessThan = search_contract.Internal.hitLessThan;
        const bm25WeightedTermScore = scoring_mod.bm25WeightedTermScore;

        fn textSearchFilterAdmitsEntireCatalog(options: TextSearchOptions, docs_view: *const TextDocsFileView) bool {
            if (options.member_filter != null) return false;
            if (!textSearchHasNodeFilter(options)) return true;
            if (!docs_view.header.hasUniformKind()) return false;
            const uniform_kind: core.NodeKind = @enumFromInt(docs_view.header.uniform_kind);
            return textSearchMatchesNodeKind(options, uniform_kind);
        }

        pub fn searchPersistentTokens(
            allocator: std.mem.Allocator,
            store: storage_mod.Store,
            query_terms: []const []u8,
            options: TextSearchOptions,
        ) !std.ArrayList(TextSearchHit) {
            if (options.deadline.expired()) return core.Error.BudgetExceeded;
            var hits = std.ArrayList(TextSearchHit).empty;
            errdefer hits.deinit(allocator);

            const meta = try readPersistentTextMeta(allocator, store);
            if (meta.doc_count == 0) return hits;

            var unique_query_terms = std.StringHashMap(void).init(allocator);
            defer unique_query_terms.deinit();
            var scores = std.AutoHashMap(u64, f32).init(allocator);
            defer scores.deinit();
            var cjk_bigram_match_counts = std.AutoHashMap(u64, u32).init(allocator);
            defer cjk_bigram_match_counts.deinit();
            var docs = std.AutoHashMap(u64, CachedTextDoc).init(allocator);
            defer deinitCachedTextDocs(allocator, &docs);
            var doc_records = std.AutoHashMap(u64, TextDocRecord).init(allocator);
            defer doc_records.deinit();
            const prealloc = textSearchPreallocCapacity(options);
            try docs.ensureTotalCapacity(@intCast(prealloc));
            try doc_records.ensureTotalCapacity(@intCast(prealloc));
            var docs_view = try openPersistentTextDocsView(allocator, store, meta.doc_count);
            defer docs_view.deinit();
            var catalog = try PersistentPostingCatalog.open(allocator, store, meta.doc_count);
            defer catalog.deinit();

            const avg_doc_len = persistentAvgDocLen(meta);
            if (singleUniqueQueryTerm(query_terms)) |single_term| {
                return try searchSinglePersistentTermWithBlocks(allocator, store, &docs_view, &catalog, &docs, meta, avg_doc_len, single_term, query_terms, options);
            }
            try hits.ensureTotalCapacity(allocator, @min(options.limit, textSearchPreallocCapacity(options)));
            try unique_query_terms.ensureTotalCapacity(@intCast(@min(query_terms.len, prealloc)));
            try scores.ensureTotalCapacity(@intCast(prealloc));
            try cjk_bigram_match_counts.ensureTotalCapacity(@intCast(prealloc));

            var required_cjk_bigram_terms: u32 = 0;
            var query_has_non_cjk_term = false;
            var query_term_plans = std.ArrayList(PersistentQueryTermPlan).empty;
            defer query_term_plans.deinit(allocator);
            try query_term_plans.ensureTotalCapacity(allocator, @min(query_terms.len, prealloc));
            for (query_terms) |term| {
                if (options.deadline.expired()) return core.Error.BudgetExceeded;
                if (termHasNonCjkCodepoint(term)) query_has_non_cjk_term = true;
                const unique_entry = try unique_query_terms.getOrPut(term);
                if (unique_entry.found_existing) continue;
                unique_entry.value_ptr.* = {};
                const cjk_bigram_query_term = isCjkMultiCodepointTerm(term);
                if (cjk_bigram_query_term) {
                    required_cjk_bigram_terms = std.math.add(u32, required_cjk_bigram_terms, 1) catch return error.RecordTooLarge;
                }
                const required_cjk_bigram_count = if (cjk_bigram_query_term)
                    try countQueryTermOccurrences(query_terms, term)
                else
                    0;

                const lookup = try catalog.findTermEntry(term);
                if (lookup) |found| {
                    try query_term_plans.append(allocator, .{
                        .term = term,
                        .lookup = found,
                        .cjk_bigram_query_term = cjk_bigram_query_term,
                        .required_cjk_bigram_count = required_cjk_bigram_count,
                    });
                }
            }
            std.mem.sort(PersistentQueryTermPlan, query_term_plans.items, {}, persistentQueryTermPlanLessThan);
            if (query_term_plans.items.len == 0) return hits;
            for (query_term_plans.items, 0..) |*plan, index| plan.query_term_index = index;

            var node_view = try store.openNodeRecordView();
            defer node_view.deinit();
            var query_term_freq_cache: ?PersistentQueryTermFreqCache = if (query_term_plans.items.len <= persistent_query_term_freq_cache_max_terms)
                PersistentQueryTermFreqCache.init(allocator, query_term_plans.items)
            else
                null;
            defer if (query_term_freq_cache) |*cache| cache.deinit();
            const validate_canonical_freqs = (try persistentQueryTermPlanPostingTotal(query_term_plans.items)) <= persistent_search_canonical_freq_validate_posting_limit;

            if (try persistentQueryTermPlansExceedPostingsBudget(query_term_plans.items, options.max_postings_scanned)) {
                if (query_term_freq_cache) |*cache| {
                    if (try searchPersistentMultiTermTopHitCandidates(allocator, store, &docs_view, &catalog, &node_view, &docs, query_term_plans.items, cache, meta, avg_doc_len, options, .top_hits_only)) |candidate_hits| {
                        hits.deinit(allocator);
                        return candidate_hits;
                    }
                    if (try searchPersistentMultiTermTopHitCandidates(allocator, store, &docs_view, &catalog, &node_view, &docs, query_term_plans.items, cache, meta, avg_doc_len, options, .allow_cjk_anchor)) |candidate_hits| {
                        hits.deinit(allocator);
                        return candidate_hits;
                    }
                }
            }

            var postings_scanned: usize = 0;
            for (query_term_plans.items) |plan| {
                if (options.deadline.expired()) return core.Error.BudgetExceeded;
                var term_context = PersistentSearchTermContext{
                    .allocator = allocator,
                    .store = store,
                    .docs_view = &docs_view,
                    .node_view = &node_view,
                    .term = plan.term,
                    .options = options,
                    .docs = &docs,
                    .doc_records = &doc_records,
                    .scores = &scores,
                    .cjk_bigram_match_counts = &cjk_bigram_match_counts,
                    .cjk_bigram_query_term = plan.cjk_bigram_query_term,
                    .required_cjk_bigram_count = plan.required_cjk_bigram_count,
                    .avg_doc_len = avg_doc_len,
                    .doc_count = meta.doc_count,
                    .query_term_index = plan.query_term_index,
                    .query_term_freq_cache = if (query_term_freq_cache) |*cache| cache else null,
                    .validate_canonical_freqs = validate_canonical_freqs,
                };
                try forEachPersistentTermPostingLookupInCatalog(&catalog, plan.lookup, options, &postings_scanned, &term_context, scorePersistentSearchPosting);
            }

            var worst_hit_index: ?usize = null;
            var score_it = scores.iterator();
            while (score_it.next()) |entry| {
                if (options.deadline.expired()) return core.Error.BudgetExceeded;
                if (!std.math.isFinite(entry.value_ptr.*)) return core.Error.Unsupported;
                if (entry.value_ptr.* < options.min_score) continue;
                if (required_cjk_bigram_terms > 0 and !query_has_non_cjk_term and (cjk_bigram_match_counts.get(entry.key_ptr.*) orelse 0) < cjkBigramCoverageFloor(required_cjk_bigram_terms, options.cjk_coverage_ratio)) continue;
                const doc = if (validate_canonical_freqs)
                    (try getCachedTextDocFromView(allocator, store, &docs_view, &node_view, &docs, entry.key_ptr.*)).doc
                else
                    try getCachedTextDocRecordFromView(&docs_view, &doc_records, entry.key_ptr.*);
                try appendTopTextHitBoundedCachedWorst(allocator, &hits, options.limit, &worst_hit_index, .{
                    .node_id = core.NodeId.fromInt(doc.node_id),
                    .kind = try doc.nodeKind(),
                    .score = entry.value_ptr.*,
                    .match_count = cjk_bigram_match_counts.get(entry.key_ptr.*) orelse 0,
                });
            }

            std.mem.sort(TextSearchHit, hits.items, {}, textSearchHitLessThan);
            return hits;
        }

        fn searchPersistentMultiTermTopHitCandidates(
            allocator: std.mem.Allocator,
            store: storage_mod.Store,
            docs_view: *TextDocsFileView,
            catalog: *PersistentPostingCatalog,
            node_view: *storage_mod.Store.NodeRecordView,
            docs: *std.AutoHashMap(u64, CachedTextDoc),
            query_term_plans: []const PersistentQueryTermPlan,
            query_term_freq_cache: *PersistentQueryTermFreqCache,
            meta: PersistentTextMeta,
            avg_doc_len: f32,
            options: TextSearchOptions,
            mode: PersistentMultiTermCandidateMode,
        ) !?std.ArrayList(TextSearchHit) {
            if (query_term_plans.len == 0 or query_term_plans.len > persistent_query_term_freq_cache_max_terms) return null;
            // Global top-hit candidates are truncated before node/member
            // filtering. They are exact only when no filter exists or the
            // persisted docs header proves that every document has one kind
            // admitted by the filter. Mixed catalogs and membership filters
            // continue to fail closed into the exact scan path.
            if (!textSearchFilterAdmitsEntireCatalog(options, docs_view)) return null;
            if (textBenchTraceEnabled()) {
                std.debug.print(
                    "text_trace=multi_top_hit_start terms={} max_postings={} limit={} mode={s}\n",
                    .{ query_term_plans.len, options.max_postings_scanned, options.limit, @tagName(mode) },
                );
            }
            var required_cjk_bigram_terms: u32 = 0;
            var query_has_non_cjk_term = false;
            var cjk_anchor_plan_index: ?usize = null;
            for (query_term_plans, 0..) |plan, index| {
                if (termHasNonCjkCodepoint(plan.term)) query_has_non_cjk_term = true;
                if (plan.cjk_bigram_query_term) {
                    required_cjk_bigram_terms = std.math.add(u32, required_cjk_bigram_terms, 1) catch return error.RecordTooLarge;
                    if (plan.lookup.entry.postings_count <= options.max_postings_scanned) {
                        if (cjk_anchor_plan_index) |anchor_index| {
                            if (plan.lookup.entry.postings_count < query_term_plans[anchor_index].lookup.entry.postings_count) {
                                cjk_anchor_plan_index = index;
                            }
                        } else {
                            cjk_anchor_plan_index = index;
                        }
                    }
                }
            }
            const use_cjk_anchor = mode == .allow_cjk_anchor and required_cjk_bigram_terms > 0 and cjk_anchor_plan_index != null;
            if (!use_cjk_anchor) {
                for (query_term_plans) |plan| {
                    if (!canUsePersistentTermTopHitCandidateCache(options, plan.lookup.entry) and plan.lookup.entry.postings_count > options.max_postings_scanned) {
                        if (textBenchTraceEnabled()) {
                            std.debug.print(
                                "text_trace=multi_top_hit_skip term=\"{s}\" postings={} max_postings={} limit={}\n",
                                .{ plan.term, plan.lookup.entry.postings_count, options.max_postings_scanned, options.limit },
                            );
                        }
                        return null;
                    }
                }
            }

            const path = try textTermTopHitsPath(allocator, store);
            defer allocator.free(path);
            var file = std.Io.Dir.cwd().openFile(store.io, path, .{}) catch |err| switch (err) {
                error.FileNotFound => return null,
                else => |e| return e,
            };
            defer file.close(store.io);
            const file_size = try regularFileSize(store, file);
            const header = try readTextTermTopHitsHeaderFromFile(store, file);
            if (header.capacity != persistent_term_top_hit_capacity) return error.InvalidRecord;
            const expected_size = textTermTopHitsFileSize(header.hit_count, header.hit_term_count) catch |err| switch (err) {
                error.RecordTooLarge => return error.InvalidRecord,
                else => |e| return e,
            };
            if (file_size != expected_size) return error.InvalidRecord;

            var candidate_docs = std.AutoHashMap(u64, void).init(allocator);
            defer candidate_docs.deinit();
            var candidate_freqs = std.AutoHashMap(u64, FieldTermFreq).init(allocator);
            defer candidate_freqs.deinit();
            var candidate_freq_terms_filled = [_]bool{false} ** persistent_query_term_freq_cache_max_terms;
            const top_hit_capacity = std.math.mul(usize, query_term_plans.len, persistent_term_top_hit_capacity_usize) catch return error.RecordTooLarge;
            try candidate_docs.ensureTotalCapacity(@intCast(top_hit_capacity));
            try candidate_freqs.ensureTotalCapacity(@intCast(top_hit_capacity));

            var fallback_postings_scanned: usize = 0;
            for (query_term_plans, 0..) |plan, index| {
                if (options.deadline.expired()) return core.Error.BudgetExceeded;
                if (use_cjk_anchor and index == cjk_anchor_plan_index.?) {
                    if (textBenchTraceEnabled()) {
                        std.debug.print(
                            "text_trace=multi_top_hit_cjk_anchor term=\"{s}\" postings={} bounded_candidates={}\n",
                            .{ plan.term, plan.lookup.entry.postings_count, persistent_term_top_hit_capacity },
                        );
                    }
                    var cjk_anchor_context = PersistentSearchMediumTopCandidateContext{
                        .docs_view = docs_view,
                        .options = options,
                        .avg_doc_len = avg_doc_len,
                        .doc_count = meta.doc_count,
                        .doc_freq = plan.lookup.entry.postings_count,
                    };
                    try forEachPersistentTermPostingLookupInCatalog(catalog, plan.lookup, options, &fallback_postings_scanned, &cjk_anchor_context, collectPersistentSearchMediumTopCandidatePosting);
                    for (cjk_anchor_context.hits[0..cjk_anchor_context.hit_count]) |hit| {
                        try candidate_docs.put(hit.doc_id, {});
                        try putPersistentCandidateTextFreq(&candidate_freqs, hit.doc_id, plan.query_term_index, hit.text_freq);
                    }
                    continue;
                }
                if (!canUsePersistentTermTopHitCandidateCache(options, plan.lookup.entry)) {
                    if (mode == .top_hits_only and required_cjk_bigram_terms > 0) return null;
                    if (use_cjk_anchor) continue;
                    if (mode == .top_hits_only and plan.lookup.entry.postings_count > persistent_multi_term_exact_candidate_max_postings) {
                        if (textBenchTraceEnabled()) {
                            std.debug.print(
                                "text_trace=multi_top_hit_medium_anchor term=\"{s}\" postings={} max_exact_anchor={}\n",
                                .{ plan.term, plan.lookup.entry.postings_count, persistent_multi_term_exact_candidate_max_postings },
                            );
                        }
                        var medium_context = PersistentSearchMediumTopCandidateContext{
                            .docs_view = docs_view,
                            .options = options,
                            .avg_doc_len = avg_doc_len,
                            .doc_count = meta.doc_count,
                            .doc_freq = plan.lookup.entry.postings_count,
                        };
                        var medium_postings_scanned: usize = 0;
                        try forEachPersistentTermPostingLookupInCatalog(catalog, plan.lookup, options, &medium_postings_scanned, &medium_context, collectPersistentSearchMediumTopCandidatePosting);
                        for (medium_context.hits[0..medium_context.hit_count]) |hit| {
                            try candidate_docs.put(hit.doc_id, {});
                            try putPersistentCandidateTextFreq(&candidate_freqs, hit.doc_id, plan.query_term_index, hit.text_freq);
                        }
                        continue;
                    }
                    if (textBenchTraceEnabled()) {
                        std.debug.print(
                            "text_trace=multi_top_hit_fallback_scan term=\"{s}\" postings={} mode={s}\n",
                            .{ plan.term, plan.lookup.entry.postings_count, @tagName(mode) },
                        );
                    }
                    var context = PersistentSearchCandidateContext{
                        .allocator = allocator,
                        .store = store,
                        .docs_view = docs_view,
                        .node_view = node_view,
                        .options = options,
                        .docs = docs,
                        .candidate_docs = &candidate_docs,
                        .candidate_freqs = &candidate_freqs,
                        .query_term_index = plan.query_term_index,
                        .query_term_freq_cache = query_term_freq_cache,
                    };
                    try forEachPersistentTermPostingLookupInCatalog(catalog, plan.lookup, options, &fallback_postings_scanned, &context, collectPersistentSearchCandidatePosting);
                    continue;
                }

                if (plan.lookup.index >= header.term_count) return error.InvalidRecord;
                const term_hits = (try readTextTermTopHitTermAt(store, file, header, plan.lookup.index)) orelse {
                    if (textBenchTraceEnabled()) {
                        std.debug.print(
                            "text_trace=multi_top_hit_missing term=\"{s}\" term_index={} postings={} hit_term_count={} hit_count={}\n",
                            .{ plan.term, plan.lookup.index, plan.lookup.entry.postings_count, header.hit_term_count, header.hit_count },
                        );
                    }
                    return null;
                };
                if (term_hits.hit_count > header.capacity) return error.InvalidRecord;
                if (term_hits.hit_offset > header.hit_count or term_hits.hit_count > header.hit_count - term_hits.hit_offset) return error.InvalidRecord;
                const expected_count = @min(plan.lookup.entry.postings_count, header.capacity);
                if (term_hits.hit_count != expected_count) return error.InvalidRecord;

                const cjk_top_hit_read_limit = @max(options.limit, @as(usize, 8));
                const term_hit_read_count = if (required_cjk_bigram_terms > 0)
                    @min(term_hits.hit_count, @as(u64, @intCast(cjk_top_hit_read_limit)))
                else
                    term_hits.hit_count;
                var pos: u64 = 0;
                while (pos < term_hit_read_count) : (pos += 1) {
                    if (options.deadline.expired()) return core.Error.BudgetExceeded;
                    const record = try readTextTermTopHitRecordAt(store, file, term_hits.hit_offset + pos);
                    try candidate_docs.put(record.doc_id, {});
                    try putPersistentCandidateTextFreq(&candidate_freqs, record.doc_id, plan.query_term_index, record.text_freq);
                }
            }
            if (textBenchTraceEnabled()) {
                std.debug.print("text_trace=multi_top_hit_candidates count={}\n", .{candidate_docs.count()});
            }
            if (candidate_docs.count() == 0) return null;

            var hits = std.ArrayList(TextSearchHit).empty;
            errdefer hits.deinit(allocator);
            try hits.ensureTotalCapacity(allocator, @min(options.limit, textSearchPreallocCapacity(options)));
            var worst_hit_index: ?usize = null;

            var candidate_doc_ids = std.ArrayList(u64).empty;
            defer candidate_doc_ids.deinit(allocator);
            try candidate_doc_ids.ensureTotalCapacity(allocator, candidate_docs.count());
            var candidate_it = candidate_docs.keyIterator();
            while (candidate_it.next()) |doc_id| candidate_doc_ids.appendAssumeCapacity(doc_id.*);
            std.mem.sort(u64, candidate_doc_ids.items, {}, std.sort.asc(u64));

            for (query_term_plans) |plan| {
                if (plan.query_term_index >= candidate_freq_terms_filled.len) return error.InvalidRecord;
                candidate_freq_terms_filled[plan.query_term_index] = try fillPersistentCandidateTextFreqsFromCatalogDeadline(
                    catalog,
                    plan.lookup,
                    candidate_doc_ids.items,
                    plan.query_term_index,
                    &candidate_freqs,
                    options.deadline,
                );
            }

            for (candidate_doc_ids.items) |candidate_doc_id| {
                if (options.deadline.expired()) return core.Error.BudgetExceeded;
                if (candidate_doc_id == 0) return error.InvalidRecord;
                const doc = try docs_view.readDocAt(candidate_doc_id - 1);
                if (doc.doc_id != candidate_doc_id) return error.InvalidRecord;
                if (!textSearchMatchesNodeKind(options, try doc.nodeKind())) continue;
                if (options.member_filter) |m| {
                    if (!m.contains(doc.node_id)) continue;
                }
                var freqs_storage: ?[]const FieldTermFreq = null;
                var score: f32 = 0;
                var cjk_bigram_matches: u32 = 0;
                for (query_term_plans) |plan| {
                    const freq = candidate_freqs.get(try persistentCandidateTermFreqKey(Ops.persistent_posting_max_doc_id_dep, candidate_doc_id, plan.query_term_index)) orelse
                        (try catalogTextFreqForDoc(&catalog.postings_view, plan.lookup.entry, meta.doc_count, candidate_doc_id)) orelse blk: {
                        if (candidate_freq_terms_filled[plan.query_term_index]) break :blk FieldTermFreq{};
                        if (freqs_storage == null) {
                            const cached = try getCachedTextDocFromView(allocator, store, docs_view, node_view, docs, candidate_doc_id);
                            freqs_storage = try query_term_freq_cache.getOrBuild(cached);
                        }
                        const freqs = freqs_storage.?;
                        if (plan.query_term_index >= freqs.len) return error.InvalidRecord;
                        break :blk freqs[plan.query_term_index];
                    };
                    if (freq.text == 0 and freq.kind == 0) continue;
                    if (plan.cjk_bigram_query_term) {
                        const raw_freq = std.math.add(u32, freq.text, freq.kind) catch return error.InvalidRecord;
                        if (raw_freq >= plan.required_cjk_bigram_count) {
                            cjk_bigram_matches = std.math.add(u32, cjk_bigram_matches, 1) catch return error.RecordTooLarge;
                        }
                    }
                    const term_score = bm25WeightedTermScore(
                        persistentWeightedTfFromFieldFreq(freq),
                        persistentDocLen(doc),
                        avg_doc_len,
                        meta.doc_count,
                        plan.lookup.entry.postings_count,
                        options.params,
                    );
                    score += term_score;
                    if (!std.math.isFinite(score)) return core.Error.Unsupported;
                }
                if (!query_has_non_cjk_term and cjk_bigram_matches < cjkBigramCoverageFloor(required_cjk_bigram_terms, options.cjk_coverage_ratio)) continue;
                if (score < options.min_score) continue;
                try appendTopTextHitBoundedCachedWorst(allocator, &hits, options.limit, &worst_hit_index, .{
                    .node_id = core.NodeId.fromInt(doc.node_id),
                    .kind = try doc.nodeKind(),
                    .score = score,
                    .match_count = cjk_bigram_matches,
                });
            }

            std.mem.sort(TextSearchHit, hits.items, {}, textSearchHitLessThan);
            if (textBenchTraceEnabled()) {
                std.debug.print("text_trace=multi_top_hit_done hits={}\n", .{hits.items.len});
            }
            if (mode == .top_hits_only and required_cjk_bigram_terms > 0 and hits.items.len < options.limit) {
                hits.deinit(allocator);
                return null;
            }
            return hits;
        }

        fn searchSinglePersistentTermWithBlocks(
            allocator: std.mem.Allocator,
            store: storage_mod.Store,
            docs_view: *TextDocsFileView,
            catalog: *PersistentPostingCatalog,
            docs: *std.AutoHashMap(u64, CachedTextDoc),
            meta: PersistentTextMeta,
            avg_doc_len: f32,
            term: []const u8,
            query_terms: []const []u8,
            options: TextSearchOptions,
        ) !std.ArrayList(TextSearchHit) {
            var hits = std.ArrayList(TextSearchHit).empty;
            errdefer hits.deinit(allocator);

            const lookup = (try catalog.findTermEntry(term)) orelse return hits;
            const entry = lookup.entry;
            const cjk_bigram_query_term = isCjkMultiCodepointTerm(term);
            const required_cjk_bigram_count = if (cjk_bigram_query_term)
                try countQueryTermOccurrences(query_terms, term)
            else
                0;
            const validate_canonical_freqs = entry.postings_count <= persistent_search_canonical_freq_validate_posting_limit;
            if (textSearchFilterAdmitsEntireCatalog(options, docs_view) and canUsePersistentTermTopHitCache(options, entry)) {
                if (try readPersistentTermTopHitCache(allocator, store, docs_view, term, lookup.index, entry, meta, avg_doc_len, cjk_bigram_query_term, required_cjk_bigram_count, options)) |cached_hits| {
                    return cached_hits;
                }
            }

            var node_view = try store.openNodeRecordView();
            defer node_view.deinit();
            var doc_records = std.AutoHashMap(u64, TextDocRecord).init(allocator);
            defer doc_records.deinit();
            try doc_records.ensureTotalCapacity(@intCast(@min(entry.postings_count, @as(u64, @intCast(textSearchPreallocCapacity(options))))));
            try hits.ensureTotalCapacity(allocator, @min(options.limit, textSearchPreallocCapacity(options)));

            const term_block_offset = try catalog.termBlockOffset(lookup.index);
            const block_count = try publishedPostingBlockCountForEntry(entry, catalog.blocks_header.block_size);
            if (term_block_offset > catalog.blocks_header.block_count) return error.InvalidRecord;
            if (block_count > catalog.blocks_header.block_count - term_block_offset) return error.InvalidRecord;
            const term_impact_offset = term_block_offset;
            if (block_count > catalog.impacts_header.block_count - term_impact_offset) return error.InvalidRecord;

            var postings_scanned: usize = 0;
            var context = SingleTermSearchContext{
                .allocator = allocator,
                .store = store,
                .docs_view = docs_view,
                .node_view = &node_view,
                .term = term,
                .options = options,
                .docs = docs,
                .doc_records = &doc_records,
                .hits = &hits,
                .avg_doc_len = avg_doc_len,
                .doc_count = meta.doc_count,
                .doc_freq = entry.postings_count,
                .cjk_bigram_query_term = cjk_bigram_query_term,
                .required_cjk_bigram_count = required_cjk_bigram_count,
                .validate_canonical_freqs = validate_canonical_freqs,
            };

            if (block_count == 0) {
                _ = try scanPersistentTermPostings(&catalog.postings_view, entry, catalog.doc_count, .{ .search = .{
                    .options = options,
                    .postings_scanned = &postings_scanned,
                } }, &context, appendSingleTermSearchPosting);
                std.mem.sort(TextSearchHit, hits.items, {}, textSearchHitLessThan);
                return hits;
            }

            var seen_blocks = try PostingBlockSeenSet.init(allocator, block_count);
            defer seen_blocks.deinit(allocator);
            var impact_pos: u64 = 0;
            while (impact_pos < block_count) : (impact_pos += 1) {
                if (options.deadline.expired()) return core.Error.BudgetExceeded;
                const impact_index = std.math.add(u64, term_impact_offset, impact_pos) catch return error.RecordTooLarge;
                const global_block_index = try catalog.impacts_view.readBlockIndexAt(catalog.impacts_header.term_count, impact_index);
                if (global_block_index < term_block_offset) return error.InvalidRecord;
                const local_block_index = global_block_index - term_block_offset;
                if (local_block_index >= block_count) return error.InvalidRecord;
                const local_usize = std.math.cast(usize, local_block_index) orelse return error.RecordTooLarge;
                try seen_blocks.mark(local_usize);

                const block = try catalog.blocks_view.readBlockRecordAt(catalog.blocks_header.term_count, global_block_index);
                const block_upper = bm25WeightedTermScore(
                    block.max_weighted_tf,
                    block.min_doc_len,
                    avg_doc_len,
                    meta.doc_count,
                    entry.postings_count,
                    options.params,
                );
                if (!std.math.isFinite(block_upper)) return core.Error.Unsupported;
                if (block_upper < options.min_score) continue;

                if (worstTopTextHitScore(hits.items, options.limit)) |threshold| {
                    if (block_upper < threshold) continue;
                }

                const block_posting_offset = try catalog.blockPostingOffset(entry, term_block_offset, local_block_index);
                if (block_posting_offset > catalog.postings_header.body_bytes) return error.InvalidRecord;
                const block_posting_count = try persistentBlockPostingCount(entry.postings_count, local_block_index, catalog.blocks_header.block_size);
                _ = try scanPersistentPostingRange(&catalog.postings_view, block_posting_offset, block_posting_count, catalog.doc_count, .{ .search = .{
                    .options = options,
                    .postings_scanned = &postings_scanned,
                } }, &context, appendSingleTermSearchPosting);
            }
            if (seen_blocks.count() != block_count) return error.InvalidRecord;

            std.mem.sort(TextSearchHit, hits.items, {}, textSearchHitLessThan);
            return hits;
        }
    };
}
