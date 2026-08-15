const std = @import("std");
const tokenizer_mod = @import("tokenizer.zig");
const scoring_mod = @import("scoring.zig");
const search_contract_mod = @import("search_contract.zig");
const searchable_document_mod = @import("searchable_document.zig");

/// Mutable in-memory BM25 index and its graph/store materialization paths.
/// Persistent BM25 files and their optimized query implementation remain a
/// separate data plane owned by the text façade.
pub fn InMemoryIndex(
    comptime core: type,
    comptime schema: type,
    comptime graph: type,
    comptime storage: type,
    comptime TextQueryPlanStats: type,
) type {
    return struct {
        const tokenizer = tokenizer_mod;
        const scoring = scoring_mod;
        const search_contract = search_contract_mod.SearchContract(core, schema, tokenizer_mod, scoring_mod);
        const searchable_document = searchable_document_mod.SearchableDocument(core, storage);
        const Graph = graph.Graph;
        const Store = storage.Store;
        const TextDocument = searchable_document.TextDocument;
        const SearchableNodeMetadata = searchable_document.SearchableNodeMetadata;
        const SearchableNodeMetadataSnapshot = searchable_document.SearchableNodeMetadataSnapshot;
        const TextSearchOptions = search_contract.TextSearchOptions;
        const TextSearchHit = search_contract.TextSearchHit;

        pub const TextFieldWeights = struct {
            text: f32 = 4.0,
            kind: f32 = 0,
        };

        const IndexedDocument = struct {
            node_id: core.NodeId,
            kind: core.NodeKind,
            len: f32,
        };

        const Posting = struct {
            doc_index: u32,
            weighted_tf: f32,
            raw_tf: u32,
        };

        /// One term of the compacted immutable index: its bytes live in
        /// `compact_terms_blob` and its postings in `compact_postings`, so a
        /// finished index holds three exact-size allocations instead of one
        /// separately allocated term string and posting list per term.
        const CompactTermEntry = struct {
            term_off: u32,
            term_len: u32,
            postings_off: u32,
            postings_len: u32,
        };

        const PendingPostingTerm = struct {
            term: []u8,
            postings: std.ArrayList(Posting),
        };

        const WeightedTermFreq = struct {
            weighted: f32 = 0,
            raw: u32 = 0,
        };

        pub const TextIndex = struct {
            allocator: std.mem.Allocator,
            postings_by_term: std.StringHashMap(std.ArrayList(Posting)),
            doc_ids: std.AutoHashMap(u64, void),
            owned_terms: std.ArrayList([]u8),
            docs: std.ArrayList(IndexedDocument),
            total_doc_len: f32 = 0,
            field_weights: TextFieldWeights = .{},
            tokenizer_options: tokenizer.TokenizerOptions = .{},
            compacted: bool = false,
            compact_terms_blob: []u8 = &.{},
            compact_entries: []CompactTermEntry = &.{},
            compact_postings: []Posting = &.{},

            pub fn init(allocator: std.mem.Allocator) TextIndex {
                return .{
                    .allocator = allocator,
                    .postings_by_term = std.StringHashMap(std.ArrayList(Posting)).init(allocator),
                    .doc_ids = std.AutoHashMap(u64, void).init(allocator),
                    .owned_terms = .empty,
                    .docs = .empty,
                };
            }

            pub fn deinit(self: *TextIndex) void {
                var postings_it = self.postings_by_term.valueIterator();
                while (postings_it.next()) |postings| postings.deinit(self.allocator);
                self.postings_by_term.deinit();
                self.doc_ids.deinit();
                for (self.owned_terms.items) |term| self.allocator.free(term);
                self.owned_terms.deinit(self.allocator);
                self.docs.deinit(self.allocator);
                self.allocator.free(self.compact_terms_blob);
                self.allocator.free(self.compact_entries);
                self.allocator.free(self.compact_postings);
            }

            fn compactTermBytes(self: *const TextIndex, entry: CompactTermEntry) []const u8 {
                return self.compact_terms_blob[entry.term_off .. entry.term_off + entry.term_len];
            }

            /// Postings for one term regardless of representation. The
            /// compacted form binary-searches the sorted term table; the
            /// mutable form consults the hash map.
            fn lookupPostings(self: *const TextIndex, term: []const u8) ?[]const Posting {
                if (!self.compacted) {
                    const postings = self.postings_by_term.getPtr(term) orelse return null;
                    return postings.items;
                }
                var low: usize = 0;
                var high: usize = self.compact_entries.len;
                while (low < high) {
                    const middle = low + (high - low) / 2;
                    const entry = self.compact_entries[middle];
                    if (std.mem.order(u8, self.compactTermBytes(entry), term) == .lt) {
                        low = middle + 1;
                    } else {
                        high = middle;
                    }
                }
                if (low == self.compact_entries.len) return null;
                const entry = self.compact_entries[low];
                if (!std.mem.eql(u8, self.compactTermBytes(entry), term)) return null;
                return self.compact_postings[entry.postings_off .. entry.postings_off + entry.postings_len];
            }

            /// Build a frozen index directly from a complete graph with one
            /// tokenizer pass and exact-size final allocations: one term
            /// blob, one sorted term table, one flat postings array and one
            /// document array. Tokens and per-document scratch live in a
            /// bounded reused arena; per-term occurrences go to one flat log
            /// that is counting-sorted into the postings array. Document
            /// order, per-term posting order and every BM25 scoring input
            /// match the incremental addDocument path bit for bit; the
            /// result is immutable and addDocument fails closed.
            pub fn buildCompactFromGraph(
                allocator: std.mem.Allocator,
                source_graph: *const Graph,
            ) !TextIndex {
                const default_config = TextIndex.init(allocator);
                const field_weights = default_config.field_weights;
                const tokenizer_options = default_config.tokenizer_options;
                try tokenizer.validateTokenizerOptions(tokenizer_options);

                var scratch_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
                defer scratch_state.deinit();
                const scratch = scratch_state.allocator();
                var doc_scratch_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
                defer doc_scratch_state.deinit();

                const LogEntry = struct {
                    slot: u32,
                    doc_index: u32,
                    weighted_tf: f32,
                    raw_tf: u32,
                };
                var log = std.ArrayList(LogEntry).empty;
                defer log.deinit(allocator);
                var term_slots = std.StringHashMap(u32).init(scratch);
                var terms_by_slot = std.ArrayList([]const u8).empty;
                var postings_per_slot = std.ArrayList(u32).empty;
                var total_term_bytes: usize = 0;
                var docs = std.ArrayList(IndexedDocument).empty;
                errdefer docs.deinit(allocator);
                var total_doc_len: f32 = 0;
                // Reused across documents; keys are only valid within one
                // document and the table is cleared, not freed.
                var doc_terms = std.StringHashMap(WeightedTermFreq).init(scratch);

                for (source_graph.nodes.items) |node| {
                    if (node.status != .active) continue;
                    if (searchable_document.Internal.isDeletedNodeTombstoneNode(node.kind, node.text)) continue;
                    if (node.id == .none or node.id.toInt() == std.math.maxInt(u64)) return core.Error.InvalidId;
                    if (docs.items.len >= std.math.maxInt(u32)) return error.RecordTooLarge;
                    const doc_index: u32 = @intCast(docs.items.len);

                    _ = doc_scratch_state.reset(.retain_capacity);
                    doc_terms.clearRetainingCapacity();
                    var doc_len: f32 = 0;
                    var tokens = try tokenizer.tokenize(doc_scratch_state.allocator(), node.text, tokenizer_options);
                    defer tokens.deinit();
                    for (tokens.items.items) |term| {
                        const next_doc_len = doc_len + field_weights.text;
                        if (!std.math.isFinite(next_doc_len)) return core.Error.Unsupported;
                        doc_len = next_doc_len;
                        const entry = try doc_terms.getOrPut(term);
                        if (entry.found_existing) {
                            const next_weight = entry.value_ptr.weighted + field_weights.text;
                            if (!std.math.isFinite(next_weight)) return core.Error.Unsupported;
                            entry.value_ptr.weighted = next_weight;
                            entry.value_ptr.raw = std.math.add(u32, entry.value_ptr.raw, 1) catch return error.RecordTooLarge;
                        } else {
                            entry.value_ptr.* = .{ .weighted = field_weights.text, .raw = 1 };
                        }
                    }
                    if (doc_len <= 0) return core.Error.Unsupported;
                    const next_total_doc_len = total_doc_len + doc_len;
                    if (!std.math.isFinite(next_total_doc_len)) return core.Error.Unsupported;

                    var doc_term_it = doc_terms.iterator();
                    while (doc_term_it.next()) |entry| {
                        const slot_entry = try term_slots.getOrPut(entry.key_ptr.*);
                        if (!slot_entry.found_existing) {
                            if (terms_by_slot.items.len >= std.math.maxInt(u32)) return core.Error.Unsupported;
                            const owned_term = try scratch.dupe(u8, entry.key_ptr.*);
                            slot_entry.key_ptr.* = owned_term;
                            slot_entry.value_ptr.* = @intCast(terms_by_slot.items.len);
                            try terms_by_slot.append(scratch, owned_term);
                            try postings_per_slot.append(scratch, 0);
                            total_term_bytes += owned_term.len;
                        }
                        const slot = slot_entry.value_ptr.*;
                        postings_per_slot.items[slot] = std.math.add(u32, postings_per_slot.items[slot], 1) catch return core.Error.Unsupported;
                        try log.append(allocator, .{
                            .slot = slot,
                            .doc_index = doc_index,
                            .weighted_tf = entry.value_ptr.weighted,
                            .raw_tf = entry.value_ptr.raw,
                        });
                    }

                    try docs.append(allocator, .{ .node_id = node.id, .kind = node.kind, .len = doc_len });
                    total_doc_len = next_total_doc_len;
                }
                if (log.items.len > std.math.maxInt(u32) or total_term_bytes > std.math.maxInt(u32)) {
                    return core.Error.Unsupported;
                }

                // Sort terms, then counting-sort the log into exact postings.
                const term_count = terms_by_slot.items.len;
                const order = try scratch.alloc(u32, term_count);
                for (order, 0..) |*slot, position| slot.* = @intCast(position);
                const OrderContext = struct {
                    terms: []const []const u8,
                    fn lessThan(context: @This(), lhs: u32, rhs: u32) bool {
                        return std.mem.order(u8, context.terms[lhs], context.terms[rhs]) == .lt;
                    }
                };
                std.mem.sort(u32, order, OrderContext{ .terms = terms_by_slot.items }, OrderContext.lessThan);

                const terms_blob = try allocator.alloc(u8, total_term_bytes);
                errdefer allocator.free(terms_blob);
                const entries = try allocator.alloc(CompactTermEntry, term_count);
                errdefer allocator.free(entries);
                const postings = try allocator.alloc(Posting, log.items.len);
                errdefer allocator.free(postings);

                const position_of_slot = try scratch.alloc(u32, term_count);
                const cursors = try scratch.alloc(u32, term_count);
                var term_off: u32 = 0;
                var postings_off: u32 = 0;
                for (order, 0..) |slot, position| {
                    const term = terms_by_slot.items[slot];
                    @memcpy(terms_blob[term_off .. term_off + term.len], term);
                    entries[position] = .{
                        .term_off = term_off,
                        .term_len = @intCast(term.len),
                        .postings_off = postings_off,
                        .postings_len = postings_per_slot.items[slot],
                    };
                    position_of_slot[slot] = @intCast(position);
                    cursors[position] = postings_off;
                    term_off += @intCast(term.len);
                    postings_off += postings_per_slot.items[slot];
                }
                for (log.items) |entry| {
                    const position = position_of_slot[entry.slot];
                    postings[cursors[position]] = .{
                        .doc_index = entry.doc_index,
                        .weighted_tf = entry.weighted_tf,
                        .raw_tf = entry.raw_tf,
                    };
                    cursors[position] += 1;
                }

                const docs_exact = try docs.toOwnedSlice(allocator);
                return .{
                    .allocator = allocator,
                    .postings_by_term = std.StringHashMap(std.ArrayList(Posting)).init(allocator),
                    .doc_ids = std.AutoHashMap(u64, void).init(allocator),
                    .owned_terms = .empty,
                    .docs = std.ArrayList(IndexedDocument).fromOwnedSlice(docs_exact),
                    .total_doc_len = total_doc_len,
                    .field_weights = field_weights,
                    .tokenizer_options = tokenizer_options,
                    .compacted = true,
                    .compact_terms_blob = terms_blob,
                    .compact_entries = entries,
                    .compact_postings = postings,
                };
            }

            pub fn buildFromGraph(allocator: std.mem.Allocator, source_graph: *const Graph) !TextIndex {
                return buildFromGraphDeadline(allocator, source_graph, .none);
            }

            pub fn buildFromGraphDeadline(
                allocator: std.mem.Allocator,
                source_graph: *const Graph,
                deadline: core.QueryDeadline,
            ) !TextIndex {
                return buildFromGraphWithMetadataDeadline(allocator, source_graph, null, deadline);
            }

            fn buildFromGraphWithMetadataDeadline(
                allocator: std.mem.Allocator,
                source_graph: *const Graph,
                metadata: ?*const SearchableNodeMetadataSnapshot,
                deadline: core.QueryDeadline,
            ) !TextIndex {
                var index = TextIndex.init(allocator);
                errdefer index.deinit();
                for (source_graph.nodes.items) |node| {
                    if (deadline.expired()) return core.Error.BudgetExceeded;
                    if (node.status != .active) continue;
                    if (searchable_document.Internal.isDeletedNodeTombstoneNode(node.kind, node.text)) continue;
                    const node_metadata = if (metadata) |snapshot| snapshot.get(node.id) else SearchableNodeMetadata{};
                    try index.addDocument(.{
                        .node_id = node.id,
                        .kind = node.kind,
                        .text = node.text,
                        .name = node_metadata.name,
                        .summary = node_metadata.summary,
                    });
                }
                return index;
            }

            pub fn buildFromStore(allocator: std.mem.Allocator, store: Store) !TextIndex {
                return buildFromStoreOnce(allocator, store, .none) catch |err| switch (err) {
                    error.FileNotFound, error.InvalidRecord => retry: {
                        try store.repairPersistentIndexesFromLog();
                        break :retry try buildFromStoreOnce(allocator, store, .none);
                    },
                    else => |other| return other,
                };
            }

            /// Builds an ephemeral index without publishing graph repairs. A
            /// failed derived-index read may replay the canonical log in memory.
            pub fn buildFromStoreReadOnlyDeadline(
                allocator: std.mem.Allocator,
                store: Store,
                max_searchable_metadata_bytes: u64,
                max_searchable_property_scan_bytes: u64,
                deadline: core.QueryDeadline,
            ) !TextIndex {
                var metadata = try SearchableNodeMetadataSnapshot.initLimited(
                    allocator,
                    store,
                    max_searchable_metadata_bytes,
                    max_searchable_property_scan_bytes,
                    deadline,
                );
                defer metadata.deinit();
                return buildFromStoreOnceWithMetadata(allocator, store, &metadata, deadline) catch |err| switch (err) {
                    error.FileNotFound, error.InvalidRecord => {
                        var source_graph = try store.loadGraphDeadline(deadline);
                        defer source_graph.deinit();
                        return buildFromGraphWithMetadataDeadline(allocator, &source_graph, &metadata, deadline);
                    },
                    else => |other| return other,
                };
            }

            fn buildFromStoreOnce(
                allocator: std.mem.Allocator,
                store: Store,
                deadline: core.QueryDeadline,
            ) !TextIndex {
                var metadata = try SearchableNodeMetadataSnapshot.init(allocator, store);
                defer metadata.deinit();
                return buildFromStoreOnceWithMetadata(allocator, store, &metadata, deadline);
            }

            fn buildFromStoreOnceWithMetadata(
                allocator: std.mem.Allocator,
                store: Store,
                metadata: *const SearchableNodeMetadataSnapshot,
                deadline: core.QueryDeadline,
            ) !TextIndex {
                var index = TextIndex.init(allocator);
                errdefer index.deinit();

                var nodes = try store.nodeRecordsIterator(null);
                defer nodes.deinit();
                while (try nodes.nextRef()) |node| {
                    if (deadline.expired()) return core.Error.BudgetExceeded;
                    const node_metadata = metadata.get(node.id);
                    if (node.text_bytes) |text| {
                        if (searchable_document.Internal.isDeletedNodeTombstoneNode(node.kind, text)) continue;
                        try index.addDocument(.{ .node_id = node.id, .kind = node.kind, .text = text, .name = node_metadata.name, .summary = node_metadata.summary });
                    } else if (try nodes.readRefTextBorrowed(node)) |text| {
                        if (searchable_document.Internal.isDeletedNodeTombstoneNode(node.kind, text)) continue;
                        try index.addDocument(.{ .node_id = node.id, .kind = node.kind, .text = text, .name = node_metadata.name, .summary = node_metadata.summary });
                    } else {
                        const text = try nodes.readRefTextAlloc(allocator, node);
                        defer allocator.free(text);
                        if (searchable_document.Internal.isDeletedNodeTombstoneNode(node.kind, text)) continue;
                        try index.addDocument(.{ .node_id = node.id, .kind = node.kind, .text = text, .name = node_metadata.name, .summary = node_metadata.summary });
                    }
                }
                return index;
            }

            pub fn queryPlanStats(
                self: TextIndex,
                query: []const u8,
                options: TextSearchOptions,
            ) !TextQueryPlanStats {
                try search_contract.Internal.validateOptions(options);
                if (!search_contract.Internal.tokenizerOptionsEqual(options.tokenizer, self.tokenizer_options)) return core.Error.Unsupported;
                if (options.deadline.expired()) return core.Error.BudgetExceeded;

                var query_tokens = try tokenizer.tokenize(self.allocator, query, options.tokenizer);
                defer query_tokens.deinit();
                var unique_query_terms = std.StringHashMap(void).init(self.allocator);
                defer unique_query_terms.deinit();
                try unique_query_terms.ensureTotalCapacity(@intCast(query_tokens.items.items.len));

                var stats = TextQueryPlanStats{ .query_terms = query_tokens.items.items.len };
                for (query_tokens.items.items) |term| {
                    if (options.deadline.expired()) return core.Error.BudgetExceeded;
                    const entry = try unique_query_terms.getOrPut(term);
                    if (entry.found_existing) continue;
                    entry.value_ptr.* = {};
                    stats.unique_query_terms += 1;
                    if (self.lookupPostings(term)) |postings| {
                        stats.matched_terms += 1;
                        stats.postings_count_total = std.math.add(u64, stats.postings_count_total, postings.len) catch return error.RecordTooLarge;
                        stats.max_postings_count = @max(stats.max_postings_count, postings.len);
                    }
                }
                return stats;
            }

            pub fn addDocument(self: *TextIndex, doc: TextDocument) !void {
                if (self.compacted) return core.Error.Unsupported;
                try tokenizer.validateTokenizerOptions(self.tokenizer_options);
                if (doc.node_id == .none or doc.node_id.toInt() == std.math.maxInt(u64) or self.doc_ids.contains(doc.node_id.toInt())) return core.Error.InvalidId;
                if (self.docs.items.len >= std.math.maxInt(u32)) return error.RecordTooLarge;
                const doc_index: u32 = @intCast(self.docs.items.len);
                var term_weights = std.StringHashMap(WeightedTermFreq).init(self.allocator);
                defer term_weights.deinit();
                var owned_term_weights = std.ArrayList([]u8).empty;
                defer {
                    for (owned_term_weights.items) |term| self.allocator.free(term);
                    owned_term_weights.deinit(self.allocator);
                }

                var doc_len: f32 = 0;
                try self.collectFieldTerms(&term_weights, &owned_term_weights, doc.text, self.field_weights.text, &doc_len);
                if (doc.name) |name| try self.collectFieldTerms(&term_weights, &owned_term_weights, name, self.field_weights.text, &doc_len);
                if (doc.summary) |summary| try self.collectFieldTerms(&term_weights, &owned_term_weights, summary, self.field_weights.text, &doc_len);
                if (self.field_weights.kind != 0) {
                    var kind_label_buffer: [16]u8 = undefined;
                    try self.collectFieldTerms(&term_weights, &owned_term_weights, kindLabel(doc.kind, &kind_label_buffer), self.field_weights.kind, &doc_len);
                }
                if (doc_len <= 0) return core.Error.Unsupported;
                const next_total_doc_len = self.total_doc_len + doc_len;
                if (!std.math.isFinite(next_total_doc_len)) return core.Error.Unsupported;

                var pending_terms = std.ArrayList(PendingPostingTerm).empty;
                defer {
                    for (pending_terms.items) |*pending| {
                        self.allocator.free(pending.term);
                        pending.postings.deinit(self.allocator);
                    }
                    pending_terms.deinit(self.allocator);
                }

                var new_term_count: usize = 0;
                var term_it = term_weights.iterator();
                while (term_it.next()) |entry| {
                    if (!self.postings_by_term.contains(entry.key_ptr.*)) {
                        new_term_count += 1;
                        var postings = std.ArrayList(Posting).empty;
                        errdefer postings.deinit(self.allocator);
                        try postings.append(self.allocator, .{
                            .doc_index = doc_index,
                            .weighted_tf = entry.value_ptr.weighted,
                            .raw_tf = entry.value_ptr.raw,
                        });
                        const owned_term = try self.allocator.dupe(u8, entry.key_ptr.*);
                        errdefer self.allocator.free(owned_term);
                        try pending_terms.append(self.allocator, .{ .term = owned_term, .postings = postings });
                    }
                }

                try self.docs.ensureUnusedCapacity(self.allocator, 1);
                try self.doc_ids.ensureUnusedCapacity(1);
                try self.owned_terms.ensureUnusedCapacity(self.allocator, new_term_count);
                try self.postings_by_term.ensureUnusedCapacity(@intCast(new_term_count));

                term_it = term_weights.iterator();
                while (term_it.next()) |entry| {
                    if (self.postings_by_term.getPtr(entry.key_ptr.*)) |postings| {
                        try postings.ensureUnusedCapacity(self.allocator, 1);
                    }
                }

                self.docs.appendAssumeCapacity(.{ .node_id = doc.node_id, .kind = doc.kind, .len = doc_len });
                self.total_doc_len = next_total_doc_len;

                term_it = term_weights.iterator();
                while (term_it.next()) |entry| {
                    const posting = Posting{
                        .doc_index = doc_index,
                        .weighted_tf = entry.value_ptr.weighted,
                        .raw_tf = entry.value_ptr.raw,
                    };
                    if (self.postings_by_term.getPtr(entry.key_ptr.*)) |postings| postings.appendAssumeCapacity(posting);
                }

                for (pending_terms.items) |pending| {
                    self.owned_terms.appendAssumeCapacity(pending.term);
                    self.postings_by_term.putAssumeCapacityNoClobber(pending.term, pending.postings);
                }
                self.doc_ids.putAssumeCapacityNoClobber(doc.node_id.toInt(), {});
                pending_terms.clearRetainingCapacity();
            }

            pub fn search(
                self: TextIndex,
                query: []const u8,
                options: TextSearchOptions,
            ) !std.ArrayList(TextSearchHit) {
                try search_contract.Internal.validateOptions(options);
                if (!search_contract.Internal.tokenizerOptionsEqual(options.tokenizer, self.tokenizer_options)) return core.Error.Unsupported;
                if (options.deadline.expired()) return core.Error.BudgetExceeded;
                var hits = std.ArrayList(TextSearchHit).empty;
                if (options.limit == 0 or self.docs.items.len == 0) return hits;
                errdefer hits.deinit(self.allocator);
                try hits.ensureTotalCapacity(self.allocator, @min(options.limit, search_contract.Internal.preallocCapacity(options)));

                var query_tokens = try tokenizer.tokenize(self.allocator, query, options.tokenizer);
                defer query_tokens.deinit();
                if (query_tokens.items.items.len == 0) return hits;

                var unique_query_terms = std.StringHashMap(void).init(self.allocator);
                defer unique_query_terms.deinit();
                var scores = std.AutoHashMap(u32, f32).init(self.allocator);
                defer scores.deinit();
                var cjk_bigram_match_counts = std.AutoHashMap(u32, u32).init(self.allocator);
                defer cjk_bigram_match_counts.deinit();
                const prealloc = search_contract.Internal.preallocCapacity(options);
                try unique_query_terms.ensureTotalCapacity(@intCast(@min(query_tokens.items.items.len, prealloc)));
                try scores.ensureTotalCapacity(@intCast(prealloc));
                try cjk_bigram_match_counts.ensureTotalCapacity(@intCast(prealloc));

                var required_cjk_bigram_terms: u32 = 0;
                var query_has_non_cjk_term = false;
                var postings_scanned: usize = 0;
                for (query_tokens.items.items) |term| {
                    if (options.deadline.expired()) return core.Error.BudgetExceeded;
                    if (search_contract.Internal.termHasNonCjkCodepoint(term)) query_has_non_cjk_term = true;
                    const unique_entry = try unique_query_terms.getOrPut(term);
                    if (unique_entry.found_existing) continue;
                    unique_entry.value_ptr.* = {};
                    const cjk_bigram_query_term = search_contract.Internal.isCjkMultiCodepointTerm(term);
                    if (cjk_bigram_query_term) {
                        required_cjk_bigram_terms = std.math.add(u32, required_cjk_bigram_terms, 1) catch return error.RecordTooLarge;
                    }
                    const required_cjk_bigram_count = if (cjk_bigram_query_term)
                        try search_contract.Internal.countQueryTermOccurrences(query_tokens.items.items, term)
                    else
                        0;

                    const postings = self.lookupPostings(term) orelse continue;
                    // Incremental merge: rank both indexes on one scale by
                    // scoring with the combined corpus statistics.
                    const merged_doc_count: u64 = if (options.merge) |merge| merge.doc_count else @intCast(self.docs.items.len);
                    const merged_avg_doc_len: f32 = if (options.merge) |merge| blk: {
                        if (merge.doc_count == 0) break :blk 0;
                        break :blk @floatCast(merge.total_doc_len / @as(f64, @floatFromInt(merge.doc_count)));
                    } else self.avgDocLen();
                    var doc_freq: u64 = @intCast(postings.len);
                    if (options.merge) |merge| {
                        doc_freq = std.math.add(u64, doc_freq, merge.otherDf(merge.other_df_context, term)) catch return error.RecordTooLarge;
                    }
                    for (postings) |posting| {
                        if (options.deadline.expired()) return core.Error.BudgetExceeded;
                        try search_contract.Internal.chargePostingScan(&postings_scanned, options);
                        const doc = self.docs.items[posting.doc_index];
                        if (!search_contract.Internal.matchesNodeKind(options, doc.kind)) continue;
                        if (options.member_filter) |members| {
                            if (!members.contains(doc.node_id.toInt())) continue;
                        }
                        if (options.merge) |merge| {
                            if (merge.superseded_node_ids) |superseded| {
                                if (superseded.contains(doc.node_id.toInt())) continue;
                            }
                        }
                        if (cjk_bigram_query_term and posting.raw_tf >= required_cjk_bigram_count) {
                            const entry = try cjk_bigram_match_counts.getOrPut(posting.doc_index);
                            if (!entry.found_existing) entry.value_ptr.* = 0;
                            entry.value_ptr.* = std.math.add(u32, entry.value_ptr.*, 1) catch return error.RecordTooLarge;
                        }
                        const score = scoring.bm25WeightedTermScore(
                            posting.weighted_tf,
                            doc.len,
                            merged_avg_doc_len,
                            merged_doc_count,
                            doc_freq,
                            options.params,
                        );
                        const entry = try scores.getOrPut(posting.doc_index);
                        if (!entry.found_existing) entry.value_ptr.* = 0;
                        const next = entry.value_ptr.* + score;
                        if (!std.math.isFinite(next)) return core.Error.Unsupported;
                        entry.value_ptr.* = next;
                    }
                }

                var worst_hit_index: ?usize = null;
                var score_it = scores.iterator();
                while (score_it.next()) |entry| {
                    if (options.deadline.expired()) return core.Error.BudgetExceeded;
                    if (!std.math.isFinite(entry.value_ptr.*)) return core.Error.Unsupported;
                    if (entry.value_ptr.* < options.min_score) continue;
                    if (required_cjk_bigram_terms > 0 and !query_has_non_cjk_term and
                        (cjk_bigram_match_counts.get(entry.key_ptr.*) orelse 0) < search_contract.Internal.cjkBigramCoverageFloor(required_cjk_bigram_terms, options.cjk_coverage_ratio)) continue;
                    try search_contract.Internal.appendTopHitBoundedCachedWorst(self.allocator, &hits, options.limit, &worst_hit_index, .{
                        .node_id = self.docs.items[entry.key_ptr.*].node_id,
                        .kind = self.docs.items[entry.key_ptr.*].kind,
                        .score = entry.value_ptr.*,
                        .match_count = cjk_bigram_match_counts.get(entry.key_ptr.*) orelse 0,
                    });
                }

                std.mem.sort(TextSearchHit, hits.items, {}, search_contract.Internal.hitLessThan);
                return hits;
            }

            pub fn avgDocLen(self: TextIndex) f32 {
                if (self.docs.items.len == 0) return 0;
                const count: f32 = @floatFromInt(self.docs.items.len);
                return self.total_doc_len / count;
            }

            fn collectFieldTerms(
                self: TextIndex,
                term_weights: *std.StringHashMap(WeightedTermFreq),
                owned_term_weights: *std.ArrayList([]u8),
                text: []const u8,
                weight: f32,
                doc_len: *f32,
            ) !void {
                if (!std.math.isFinite(weight) or weight < 0) return core.Error.Unsupported;
                if (weight == 0) return;
                var tokens = try tokenizer.tokenize(self.allocator, text, self.tokenizer_options);
                defer tokens.deinit();
                for (tokens.items.items) |term| {
                    const next_doc_len = doc_len.* + weight;
                    if (!std.math.isFinite(next_doc_len)) return core.Error.Unsupported;
                    doc_len.* = next_doc_len;
                    if (term_weights.getPtr(term)) |current| {
                        const next_weight = current.weighted + weight;
                        if (!std.math.isFinite(next_weight)) return core.Error.Unsupported;
                        current.weighted = next_weight;
                        current.raw = std.math.add(u32, current.raw, 1) catch return error.RecordTooLarge;
                    } else {
                        const owned = try self.allocator.dupe(u8, term);
                        var registered = false;
                        errdefer if (!registered) self.allocator.free(owned);
                        try owned_term_weights.append(self.allocator, owned);
                        registered = true;
                        try term_weights.put(owned, .{ .weighted = weight, .raw = 1 });
                    }
                }
            }
        };

        fn kindLabel(kind: core.NodeKind, fallback_buffer: *[16]u8) []const u8 {
            inline for (@typeInfo(core.NodeKind).@"enum".fields) |field| {
                if (@intFromEnum(kind) == field.value) return field.name;
            }
            return std.fmt.bufPrint(fallback_buffer, "type#{}", .{@intFromEnum(kind)}) catch unreachable;
        }
    };
}

const TestCore = struct {
    pub const default_max_text_postings_scanned: usize = 100;
    pub const Error = error{ InvalidId, Unsupported, BudgetExceeded };
    pub const NodeKind = enum(u16) { task, observation, edit };
    pub const NodeId = enum(u64) {
        none = 0,
        _,

        pub fn fromInt(value: u64) NodeId {
            return @enumFromInt(value);
        }

        pub fn toInt(self: NodeId) u64 {
            return @intFromEnum(self);
        }
    };
    pub const QueryDeadline = enum {
        none,
        immediate,

        pub fn expired(self: QueryDeadline) bool {
            return self == .immediate;
        }
    };
};

const TestSchema = struct {
    pub const NodeTypeSet = struct {
        task: bool = false,
        observation: bool = false,
        edit: bool = false,

        pub fn containsNodeKind(self: NodeTypeSet, kind: TestCore.NodeKind) bool {
            return switch (kind) {
                .task => self.task,
                .observation => self.observation,
                .edit => self.edit,
            };
        }
    };
};

const TestGraphModule = struct {
    pub const Graph = struct {
        allocator: std.mem.Allocator,
        nodes: std.ArrayList(Node) = .empty,

        pub const Node = struct {
            id: TestCore.NodeId,
            kind: TestCore.NodeKind,
            text: []const u8,
            status: enum { active, deleted } = .active,
        };

        pub fn init(allocator: std.mem.Allocator) Graph {
            return .{ .allocator = allocator };
        }

        pub fn deinit(self: *Graph) void {
            self.nodes.deinit(self.allocator);
        }

        pub fn add(self: *Graph, node: Node) !void {
            try self.nodes.append(self.allocator, node);
        }
    };
};

const TestStoreTrace = struct {
    iterator_attempts: usize = 0,
    repairs: usize = 0,
    graph_loads: usize = 0,
};

const TestStorage = struct {
    const ValueKind = enum { string };
    const Owner = union(enum) { node: TestCore.NodeId, edge: u64 };
    const Entry = struct {
        owner: Owner,
        key_hash: u64,
        value_kind: ValueKind = .string,
        string_value: []const u8,
    };

    pub const PropertySnapshot = struct {
        entries: []const Entry,
        pub fn deinit(_: *PropertySnapshot, _: std.mem.Allocator) void {}
    };

    pub fn propertyKeyHashForLookup(key: []const u8) u64 {
        return if (std.mem.eql(u8, key, "name")) 1 else 2;
    }

    pub const Store = struct {
        allocator: std.mem.Allocator,
        records: []const Record,
        metadata: []const Entry = &.{},
        trace: *TestStoreTrace,
        fail_first_iterator: bool = false,

        const Record = struct { id: TestCore.NodeId, kind: TestCore.NodeKind, text: []const u8 };
        const NodeRef = struct { id: TestCore.NodeId, kind: TestCore.NodeKind, text_bytes: ?[]const u8 };
        const Iterator = struct {
            records: []const Record,
            index: usize = 0,

            pub fn deinit(_: *Iterator) void {}
            pub fn nextRef(self: *Iterator) !?NodeRef {
                if (self.index >= self.records.len) return null;
                const record = self.records[self.index];
                self.index += 1;
                return .{ .id = record.id, .kind = record.kind, .text_bytes = record.text };
            }
            pub fn readRefTextBorrowed(_: *Iterator, _: NodeRef) !?[]const u8 {
                return null;
            }
            pub fn readRefTextAlloc(_: *Iterator, allocator: std.mem.Allocator, node: NodeRef) ![]u8 {
                return allocator.dupe(u8, node.text_bytes orelse "");
            }
        };

        pub fn loadSearchableNodeMetadataSnapshot(self: Store, _: std.mem.Allocator) !PropertySnapshot {
            return .{ .entries = self.metadata };
        }
        pub fn loadSearchableNodeMetadataSnapshotWithLimitsDeadline(
            self: Store,
            _: std.mem.Allocator,
            _: u64,
            _: u64,
            deadline: TestCore.QueryDeadline,
        ) !PropertySnapshot {
            if (deadline.expired()) return TestCore.Error.BudgetExceeded;
            return .{ .entries = self.metadata };
        }
        pub fn getNodeStringProperty(_: Store, _: std.mem.Allocator, _: TestCore.NodeId, _: []const u8) !?[]u8 {
            return null;
        }
        pub fn nodeRecordsIterator(self: Store, _: ?void) anyerror!Iterator {
            const attempt = self.trace.iterator_attempts;
            self.trace.iterator_attempts += 1;
            if (self.fail_first_iterator and attempt == 0) return error.InvalidRecord;
            return .{ .records = self.records };
        }
        pub fn repairPersistentIndexesFromLog(self: Store) !void {
            self.trace.repairs += 1;
        }
        pub fn loadGraphDeadline(self: Store, deadline: TestCore.QueryDeadline) !TestGraphModule.Graph {
            if (deadline.expired()) return TestCore.Error.BudgetExceeded;
            self.trace.graph_loads += 1;
            var result = TestGraphModule.Graph.init(self.allocator);
            errdefer result.deinit();
            for (self.records) |record| try result.add(.{ .id = record.id, .kind = record.kind, .text = record.text });
            return result;
        }
    };
};

const TestPlanStats = struct {
    query_terms: usize = 0,
    unique_query_terms: usize = 0,
    matched_terms: usize = 0,
    postings_count_total: u64 = 0,
    max_postings_count: u64 = 0,
};

const test_memory = InMemoryIndex(TestCore, TestSchema, TestGraphModule, TestStorage, TestPlanStats);
const TestTextIndex = test_memory.TextIndex;

test "in-memory index adds searches and reports plan stats" {
    var index = TestTextIndex.init(std.testing.allocator);
    defer index.deinit();
    try index.addDocument(.{ .node_id = .fromInt(2), .kind = .task, .text = "alpha beta" });
    try index.addDocument(.{ .node_id = .fromInt(1), .kind = .observation, .text = "alpha" });

    var hits = try index.search("alpha", .{ .limit = 2 });
    defer hits.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), hits.items.len);
    const stats = try index.queryPlanStats("alpha missing", .{});
    try std.testing.expectEqual(@as(usize, 2), stats.query_terms);
    try std.testing.expectEqual(@as(usize, 1), stats.matched_terms);
    try std.testing.expectEqual(@as(u64, 2), stats.postings_count_total);
}

test "in-memory index mutation validation leaves prior state searchable" {
    var index = TestTextIndex.init(std.testing.allocator);
    defer index.deinit();
    try index.addDocument(.{ .node_id = .fromInt(1), .kind = .task, .text = "stable" });
    try std.testing.expectError(TestCore.Error.InvalidId, index.addDocument(.{ .node_id = .fromInt(1), .kind = .task, .text = "duplicate" }));
    index.field_weights = .{ .text = -1 };
    try std.testing.expectError(TestCore.Error.Unsupported, index.addDocument(.{ .node_id = .fromInt(2), .kind = .task, .text = "invalid" }));
    index.field_weights = .{};
    var hits = try index.search("stable", .{});
    defer hits.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), hits.items.len);
}

test "in-memory index applies kind member limit and posting budgets" {
    var index = TestTextIndex.init(std.testing.allocator);
    defer index.deinit();
    try index.addDocument(.{ .node_id = .fromInt(1), .kind = .task, .text = "alpha" });
    try index.addDocument(.{ .node_id = .fromInt(2), .kind = .observation, .text = "alpha" });
    const kinds = TestSchema.NodeTypeSet{ .task = true };
    var hits = try index.search("alpha", .{ .kind_set_filter = &kinds, .limit = 1 });
    defer hits.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), hits.items.len);
    try std.testing.expectEqual(@as(u64, 1), hits.items[0].node_id.toInt());
    try std.testing.expectError(TestCore.Error.BudgetExceeded, index.search("alpha", .{ .max_postings_scanned = 1 }));
}

test "in-memory index preserves CJK coverage and tokenizer agreement" {
    var index = TestTextIndex.init(std.testing.allocator);
    defer index.deinit();
    try index.addDocument(.{ .node_id = .fromInt(1), .kind = .task, .text = "错误记录" });
    try index.addDocument(.{ .node_id = .fromInt(2), .kind = .task, .text = "错误" });
    var hits = try index.search("错误记录", .{});
    defer hits.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), hits.items.len);
    try std.testing.expectEqual(@as(u64, 1), hits.items[0].node_id.toInt());
    try std.testing.expect(hits.items[0].match_count > hits.items[1].match_count);
    try std.testing.expectError(TestCore.Error.Unsupported, index.search("错误", .{
        .tokenizer = .{ .max_token_bytes = tokenizer_mod.default_max_token_bytes - 1 },
    }));
}

test "in-memory index compact graph build matches incremental build bit for bit" {
    var source = TestGraphModule.Graph.init(std.testing.allocator);
    defer source.deinit();
    try source.add(.{ .id = .fromInt(3), .kind = .task, .text = "alpha beta alpha 错误记录 gamma" });
    try source.add(.{ .id = .fromInt(1), .kind = .observation, .text = "alpha shared body" });
    try source.add(.{ .id = .fromInt(7), .kind = .edit, .text = "alpha shared body" });
    try source.add(.{ .id = .fromInt(9), .kind = .task, .text = "错误 beta gamma delta" });

    var incremental = try TestTextIndex.buildFromGraph(std.testing.allocator, &source);
    defer incremental.deinit();
    var compact = try TestTextIndex.buildCompactFromGraph(std.testing.allocator, &source);
    defer compact.deinit();

    try std.testing.expect(compact.compacted);
    try std.testing.expectEqual(incremental.docs.items.len, compact.docs.items.len);
    try std.testing.expectEqual(incremental.total_doc_len, compact.total_doc_len);
    for (incremental.docs.items, compact.docs.items) |expected, actual| {
        try std.testing.expectEqual(expected.node_id, actual.node_id);
        try std.testing.expectEqual(expected.kind, actual.kind);
        try std.testing.expectEqual(expected.len, actual.len);
    }

    for ([_][]const u8{ "alpha", "alpha beta", "错误记录", "shared body", "gamma delta", "absent" }) |query| {
        var expected_hits = try incremental.search(query, .{ .limit = 8 });
        defer expected_hits.deinit(std.testing.allocator);
        var actual_hits = try compact.search(query, .{ .limit = 8 });
        defer actual_hits.deinit(std.testing.allocator);
        try std.testing.expectEqual(expected_hits.items.len, actual_hits.items.len);
        for (expected_hits.items, actual_hits.items) |expected, actual| {
            try std.testing.expectEqual(expected.node_id, actual.node_id);
            try std.testing.expectEqual(expected.kind, actual.kind);
            try std.testing.expectEqual(expected.score, actual.score);
            try std.testing.expectEqual(expected.match_count, actual.match_count);
        }
        const expected_stats = try incremental.queryPlanStats(query, .{});
        const actual_stats = try compact.queryPlanStats(query, .{});
        try std.testing.expectEqual(expected_stats.matched_terms, actual_stats.matched_terms);
        try std.testing.expectEqual(expected_stats.postings_count_total, actual_stats.postings_count_total);
        try std.testing.expectEqual(expected_stats.max_postings_count, actual_stats.max_postings_count);
    }

    try std.testing.expectError(
        TestCore.Error.Unsupported,
        compact.addDocument(.{ .node_id = .fromInt(11), .kind = .task, .text = "rejected" }),
    );
}

test "in-memory index graph builder excludes inactive and tombstone nodes" {
    var source = TestGraphModule.Graph.init(std.testing.allocator);
    defer source.deinit();
    try source.add(.{ .id = .fromInt(1), .kind = .task, .text = "live" });
    try source.add(.{ .id = .fromInt(2), .kind = .task, .text = "inactive", .status = .deleted });
    try source.add(.{ .id = .fromInt(3), .kind = .edit, .text = "__tinykg_deleted_node__ 3" });
    var index = try TestTextIndex.buildFromGraph(std.testing.allocator, &source);
    defer index.deinit();
    var hits = try index.search("live inactive tinykg", .{});
    defer hits.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), hits.items.len);
    try std.testing.expectEqual(@as(u64, 1), hits.items[0].node_id.toInt());
}

test "in-memory index store builder repairs once before retry" {
    const records = [_]TestStorage.Store.Record{
        .{ .id = .fromInt(1), .kind = .task, .text = "repaired" },
    };
    var trace = TestStoreTrace{};
    var index = try TestTextIndex.buildFromStore(std.testing.allocator, .{
        .allocator = std.testing.allocator,
        .records = &records,
        .trace = &trace,
        .fail_first_iterator = true,
    });
    defer index.deinit();
    try std.testing.expectEqual(@as(usize, 2), trace.iterator_attempts);
    try std.testing.expectEqual(@as(usize, 1), trace.repairs);
}

test "in-memory index read-only store fallback never publishes repair" {
    const records = [_]TestStorage.Store.Record{
        .{ .id = .fromInt(1), .kind = .task, .text = "fallback" },
    };
    var trace = TestStoreTrace{};
    var index = try TestTextIndex.buildFromStoreReadOnlyDeadline(std.testing.allocator, .{
        .allocator = std.testing.allocator,
        .records = &records,
        .trace = &trace,
        .fail_first_iterator = true,
    }, 1024, 1024, .none);
    defer index.deinit();
    try std.testing.expectEqual(@as(usize, 0), trace.repairs);
    try std.testing.expectEqual(@as(usize, 1), trace.graph_loads);
    var hits = try index.search("fallback", .{});
    defer hits.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), hits.items.len);
}

test "in-memory index graph build and search enforce deadline" {
    var source = TestGraphModule.Graph.init(std.testing.allocator);
    defer source.deinit();
    try source.add(.{ .id = .fromInt(1), .kind = .task, .text = "deadline" });
    try std.testing.expectError(TestCore.Error.BudgetExceeded, TestTextIndex.buildFromGraphDeadline(std.testing.allocator, &source, .immediate));
    var index = try TestTextIndex.buildFromGraph(std.testing.allocator, &source);
    defer index.deinit();
    try std.testing.expectError(TestCore.Error.BudgetExceeded, index.search("deadline", .{ .deadline = .immediate }));
}
