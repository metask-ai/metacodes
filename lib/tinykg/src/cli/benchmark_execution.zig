const std = @import("std");
const builtin = @import("builtin");
const agent = @import("../agent.zig");
const core = @import("../core.zig");
const dag = @import("../dag.zig");
const graph = @import("../graph.zig");
const query = @import("../query.zig");
const query_index = @import("../index.zig");
const ql = @import("../ql.zig");
const catalog_mod = @import("../catalog.zig");
const schema = @import("../schema.zig");
const segment_mod = @import("../segment.zig");
const segment_node_index = @import("../segment_node_index.zig");
const storage = @import("../storage.zig");
const task = @import("../task.zig");
const text_search = @import("../text.zig");
const benchmark_contract_mod = @import("benchmark_contract.zig");
const metaknow_replay_workload_mod = @import("metaknow_replay_workload.zig");
const runtime_environment = @import("runtime_environment.zig");

const benchmark_contract = benchmark_contract_mod.BenchmarkContract;
const metaknow_replay_workload = metaknow_replay_workload_mod.MetaknowReplayWorkload;
const default_bench_edge_compact_threshold_entries = benchmark_contract.default_edge_compact_threshold_entries;

fn envVar(name: []const u8) ?[]const u8 {
    if (runtime_environment.hasMap()) return runtime_environment.get(name);
    if (!builtin.link_libc) return null;
    if (std.mem.eql(u8, name, "TINYKG_BENCH_TRACE")) {
        if (std.c.getenv("TINYKG_BENCH_TRACE")) |raw| return std.mem.span(raw);
    }
    return null;
}

fn benchTrace(comptime label: []const u8) void {
    if (envVar("TINYKG_BENCH_TRACE") == null) return;
    std.debug.print("bench_trace={s}\n", .{label});
}

fn benchTraceOp(comptime label: []const u8, op: usize) void {
    if (envVar("TINYKG_BENCH_TRACE") == null) return;
    std.debug.print("bench_trace={s} op={}\n", .{ label, op });
}

const BenchNoRegressionGateLimits = benchmark_contract.NoRegressionGateLimits;

const BenchNoRegressionGateResult = struct {
    search_passed: bool = true,
    neighbors_passed: bool = true,
    tinyql_expand_passed: bool = true,
    tinyql_context_render_passed: bool = true,
    path_passed: bool = true,
    store_overhead_passed: bool = true,

    fn passed(self: BenchNoRegressionGateResult) bool {
        return self.search_passed and
            self.neighbors_passed and
            self.tinyql_expand_passed and
            self.tinyql_context_render_passed and
            self.path_passed and
            self.store_overhead_passed;
    }
};

const BenchWorkload = benchmark_contract.Workload;

const BenchEdgeIdPattern = benchmark_contract.EdgeIdPattern;

const bench_corpus_file_max_bytes: u64 = 64 * 1024 * 1024;

const BenchCorpus = struct {
    bytes: []u8 = &.{},
    records: []const []const u8 = &.{},

    fn deinit(self: BenchCorpus, allocator: std.mem.Allocator) void {
        if (self.records.len != 0) allocator.free(self.records);
        if (self.bytes.len != 0) allocator.free(self.bytes);
    }
};

const BenchTextSource = struct {
    workload: BenchWorkload,
    corpus: ?*const BenchCorpus = null,
    shards: ?*const BenchShardPool = null,

    fn corpusRecordCount(self: BenchTextSource) usize {
        return if (self.corpus) |corpus| corpus.records.len else 0;
    }
};

const BenchMetaknowReplayManifestStats = metaknow_replay_workload.ManifestStats;
const BenchMetaknowReplayOutputStats = metaknow_replay_workload.OutputStats;
const BenchMetaknowReplayEdgeStats = metaknow_replay_workload.EdgeStats;
const BenchMetaknowReplay = metaknow_replay_workload.Replay;
const BenchNodeLoadTimings = metaknow_replay_workload.NodeLoadTimings;
const BenchTextDensityStats = metaknow_replay_workload.TextDensityStats;
const loadBenchMetaknowReplay = metaknow_replay_workload.load;
const appendBenchMetaknowNodesChunked = metaknow_replay_workload.appendNodesChunked;
const appendBenchMetaknowEdgesChunked = metaknow_replay_workload.appendEdgesChunked;
const appendBenchMetaknowReplayShapedNodeText = metaknow_replay_workload.appendShapedNodeText;
const benchMetaknowReplayNodeIndexForOrdinal = metaknow_replay_workload.nodeIndexForOrdinal;
const benchMetaknowReplayProbeTermIsStructural = metaknow_replay_workload.probeTermIsStructural;

fn buildBenchMetaknowNodeIdMap(allocator: std.mem.Allocator, replay: *const BenchMetaknowReplay, node_count: usize) !std.StringHashMap(u64) {
    _ = node_count;
    return metaknow_replay_workload.buildNodeIdMap(allocator, replay);
}

const BenchMetaknowReplayWarmStats = struct {
    enabled: bool = false,
    lookup_p95_ns: u128 = 0,
    lookup_rows_last: usize = 0,
    text_search_p95_ns: u128 = 0,
    text_search_hits_last: usize = 0,
    text_search_query_bytes: usize = 0,
    text_search_query_terms: usize = 0,
    text_search_unique_terms: usize = 0,
    text_search_matched_terms: usize = 0,
    text_search_postings: u64 = 0,
    text_search_max_postings: u64 = 0,
    neighbors_p95_ns: u128 = 0,
    neighbors_rows_last: usize = 0,
    neighbors_edges_visited_last: u64 = 0,
    deferred_based_on_neighbors_p95_ns: u128 = 0,
    deferred_based_on_neighbors_rows_last: usize = 0,
};

const BenchEdgePostLoadMaintenanceStats = struct {
    ns: u128 = 0,
    compactions: u64 = 0,
};

const BenchEdgeTombstoneProbeStats = struct {
    requested: u64 = 0,
    deleted: u64 = 0,
    ns: u128 = 0,
    visible_edges: u64 = 0,
    physical_edges: u64 = 0,
    tombstone_edges: u64 = 0,
    tombstone_ratio_bps: u64 = 0,
};

fn benchWorkloadUsesMetaknowReplay(workload: BenchWorkload) bool {
    return workload.usesMetaknowReplay();
}

fn fileExists(io: std.Io, path: []const u8) !bool {
    var file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        error.NotDir => return false,
        error.IsDir => return false,
        // Free-text commands probe their first token to distinguish an
        // optional database path from query text.  TinyQL labels contain ':';
        // that is valid query syntax but an invalid Windows filename.
        error.BadPathName, error.NameTooLong => return false,
        else => |e| return e,
    };
    defer file.close(io);
    return (try file.stat(io)).kind == .file;
}

fn storeFileSize(allocator: std.mem.Allocator, io: std.Io, db_path: []const u8, file_name: []const u8) !?u64 {
    const path = try std.fs.path.join(allocator, &.{ db_path, file_name });
    defer allocator.free(path);
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return null,
        else => |e| return e,
    };
    if (stat.kind != .file) return null;
    return stat.size;
}

fn loadBenchCorpusFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !BenchCorpus {
    return loadBenchLineFile(allocator, io, path, bench_corpus_file_max_bytes);
}

fn loadBenchLineFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8, max_bytes: u64) !BenchCorpus {
    const stat = try std.Io.Dir.cwd().statFile(io, path, .{});
    if (stat.kind != .file or stat.size == 0 or stat.size > max_bytes) return error.InvalidRecord;

    const size: usize = @intCast(stat.size);
    const bytes = try allocator.alloc(u8, size);
    errdefer allocator.free(bytes);

    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const read = try file.readPositionalAll(io, bytes, 0);
    if (read != bytes.len) return error.InvalidRecord;

    var records = std.ArrayList([]const u8).empty;
    errdefer records.deinit(allocator);
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        try records.append(allocator, trimmed);
    }
    if (records.items.len == 0) return error.InvalidRecord;

    return .{
        .bytes = bytes,
        .records = try records.toOwnedSlice(allocator),
    };
}

const metaknow_deferred_based_on_file = query.metaknow_deferred_based_on_file;

const metaknow_deferred_based_on_magic = query.metaknow_deferred_based_on_magic;

const metaknow_deferred_based_on_header_len = query.metaknow_deferred_based_on_header_len;

const metaknow_deferred_based_on_index_record_len = query.metaknow_deferred_based_on_index_record_len;

const metaknow_deferred_based_on_target_record_len = query.metaknow_deferred_based_on_target_record_len;

const metaknow_deferred_based_on_edge_id_base = query.metaknow_deferred_based_on_edge_id_base;

const MetaknowDeferredBasedOnBuildStats = struct {
    sources: usize = 0,
    links: usize = 0,
    bytes: u64 = 0,
};

const MetaknowDeferredBasedOnPair = struct {
    src: u64,
    dst: u64,
};

const MetaknowDeferredBasedOnSidecarPairs = struct {
    present: bool = false,
    pairs: std.ArrayList(MetaknowDeferredBasedOnPair) = .empty,

    fn deinit(self: *MetaknowDeferredBasedOnSidecarPairs, allocator: std.mem.Allocator) void {
        self.pairs.deinit(allocator);
        self.* = .{};
    }
};

fn normalizeMetaknowDeferredBasedOnPairs(snapshot: *MetaknowDeferredBasedOnSidecarPairs) void {
    std.mem.sort(MetaknowDeferredBasedOnPair, snapshot.pairs.items, {}, struct {
        fn lessThan(_: void, a: MetaknowDeferredBasedOnPair, b: MetaknowDeferredBasedOnPair) bool {
            if (a.src != b.src) return a.src < b.src;
            return a.dst < b.dst;
        }
    }.lessThan);
    var write_index: usize = 0;
    var previous: ?MetaknowDeferredBasedOnPair = null;
    for (snapshot.pairs.items) |pair| {
        if (previous) |last| {
            if (last.src == pair.src and last.dst == pair.dst) continue;
        }
        snapshot.pairs.items[write_index] = pair;
        write_index += 1;
        previous = pair;
    }
    snapshot.pairs.shrinkRetainingCapacity(write_index);
}

fn metaknowDeferredBasedOnPath(allocator: std.mem.Allocator, store: storage.Store) ![]u8 {
    return query.metaknowDeferredBasedOnPath(allocator, store);
}

fn metaknowDeferredBasedOnPathForDb(allocator: std.mem.Allocator, db_path: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ db_path, metaknow_deferred_based_on_file });
}

fn writeBenchMetaknowDeferredBasedOnSidecar(
    allocator: std.mem.Allocator,
    store: storage.Store,
    replay: *const BenchMetaknowReplay,
    node_count: usize,
) !MetaknowDeferredBasedOnBuildStats {
    if (replay.deferred_based_on.len == 0) return .{};
    var id_map = try buildBenchMetaknowNodeIdMap(allocator, replay, node_count);
    defer id_map.deinit();

    var pairs = std.ArrayList(MetaknowDeferredBasedOnPair).empty;
    defer pairs.deinit(allocator);
    for (replay.deferred_based_on) |row| {
        const fragment_id = id_map.get(row.fragment_original_id) orelse continue;
        for (row.dst_original_ids) |dst_original_id| {
            const source_id = id_map.get(dst_original_id) orelse continue;
            try pairs.append(allocator, .{ .src = source_id, .dst = fragment_id });
        }
    }
    return try writeMetaknowDeferredBasedOnForwardPairsSidecar(allocator, store, pairs.items, node_count);
}

fn writeMetaknowDeferredBasedOnForwardPairsSidecar(
    allocator: std.mem.Allocator,
    store: storage.Store,
    forward_pairs: []const MetaknowDeferredBasedOnPair,
    node_count: usize,
) !MetaknowDeferredBasedOnBuildStats {
    if (forward_pairs.len == 0) return .{};
    var pairs = std.ArrayList(MetaknowDeferredBasedOnPair).empty;
    defer pairs.deinit(allocator);
    try pairs.ensureTotalCapacity(allocator, forward_pairs.len);
    pairs.appendSliceAssumeCapacity(forward_pairs);

    std.mem.sort(MetaknowDeferredBasedOnPair, pairs.items, {}, struct {
        fn lessThan(_: void, a: MetaknowDeferredBasedOnPair, b: MetaknowDeferredBasedOnPair) bool {
            if (a.src != b.src) return a.src < b.src;
            return a.dst < b.dst;
        }
    }.lessThan);

    var deduped = std.ArrayList(MetaknowDeferredBasedOnPair).empty;
    defer deduped.deinit(allocator);
    try deduped.ensureTotalCapacity(allocator, pairs.items.len);
    var previous: ?MetaknowDeferredBasedOnPair = null;
    for (pairs.items) |pair| {
        if (previous) |last| {
            if (last.src == pair.src and last.dst == pair.dst) continue;
        }
        try deduped.append(allocator, pair);
        previous = pair;
    }

    var reverse_pairs = std.ArrayList(MetaknowDeferredBasedOnPair).empty;
    defer reverse_pairs.deinit(allocator);
    try reverse_pairs.ensureTotalCapacity(allocator, deduped.items.len);
    for (deduped.items) |pair| {
        reverse_pairs.appendAssumeCapacity(.{ .src = pair.dst, .dst = pair.src });
    }
    std.mem.sort(MetaknowDeferredBasedOnPair, reverse_pairs.items, {}, struct {
        fn lessThan(_: void, a: MetaknowDeferredBasedOnPair, b: MetaknowDeferredBasedOnPair) bool {
            if (a.src != b.src) return a.src < b.src;
            return a.dst < b.dst;
        }
    }.lessThan);

    const forward_source_count = metaknowDeferredBasedOnGroupCount(deduped.items);
    const reverse_source_count = metaknowDeferredBasedOnGroupCount(reverse_pairs.items);
    try ensureMetaknowDeferredBasedOnU32Sized(deduped.items, forward_source_count);
    try ensureMetaknowDeferredBasedOnU32Sized(reverse_pairs.items, reverse_source_count);

    const forward_index_bytes = try std.math.mul(usize, forward_source_count, metaknow_deferred_based_on_index_record_len);
    const forward_target_bytes = try std.math.mul(usize, deduped.items.len, metaknow_deferred_based_on_target_record_len);
    const reverse_index_bytes = try std.math.mul(usize, reverse_source_count, metaknow_deferred_based_on_index_record_len);
    const reverse_target_bytes = try std.math.mul(usize, reverse_pairs.items.len, metaknow_deferred_based_on_target_record_len);
    const forward_target_offset = metaknow_deferred_based_on_header_len + forward_index_bytes;
    const reverse_index_offset = forward_target_offset + forward_target_bytes;
    const reverse_target_offset = reverse_index_offset + reverse_index_bytes;
    const total_bytes = try std.math.add(usize, reverse_target_offset, reverse_target_bytes);
    var bytes = try allocator.alloc(u8, total_bytes);
    defer allocator.free(bytes);
    @memset(bytes, 0);
    @memcpy(bytes[0..8], &metaknow_deferred_based_on_magic);
    std.mem.writeInt(u64, bytes[8..16], @intCast(forward_source_count), .little);
    std.mem.writeInt(u64, bytes[16..24], @intCast(deduped.items.len), .little);
    std.mem.writeInt(u64, bytes[24..32], @intCast(forward_target_offset), .little);
    std.mem.writeInt(u64, bytes[32..40], metaknow_deferred_based_on_edge_id_base, .little);
    std.mem.writeInt(u64, bytes[40..48], @intCast(node_count), .little);
    std.mem.writeInt(u64, bytes[48..56], @intCast(reverse_source_count), .little);
    std.mem.writeInt(u64, bytes[56..64], @intCast(reverse_pairs.items.len), .little);
    std.mem.writeInt(u64, bytes[64..72], @intCast(reverse_target_offset), .little);

    writeMetaknowDeferredBasedOnGroups(bytes, deduped.items, metaknow_deferred_based_on_header_len, forward_target_offset);
    writeMetaknowDeferredBasedOnGroups(bytes, reverse_pairs.items, reverse_index_offset, reverse_target_offset);

    const path = try metaknowDeferredBasedOnPath(allocator, store);
    defer allocator.free(path);
    var file = try std.Io.Dir.cwd().createFile(store.io, path, .{ .truncate = true });
    defer file.close(store.io);
    try file.writePositionalAll(store.io, bytes, 0);
    try file.setLength(store.io, @intCast(bytes.len));

    return .{
        .sources = forward_source_count,
        .links = deduped.items.len,
        .bytes = @intCast(bytes.len),
    };
}

fn writeMetaknowDeferredBasedOnGroups(
    bytes: []u8,
    pairs: []const MetaknowDeferredBasedOnPair,
    index_offset: usize,
    target_offset: usize,
) void {
    var index_cursor: usize = index_offset;
    var target_cursor: usize = target_offset;
    var pair_index: usize = 0;
    while (pair_index < pairs.len) {
        const src = pairs[pair_index].src;
        const start = pair_index;
        while (pair_index < pairs.len and pairs[pair_index].src == src) : (pair_index += 1) {
            std.mem.writeInt(u32, bytes[target_cursor..][0..4], @intCast(pairs[pair_index].dst), .little);
            target_cursor += metaknow_deferred_based_on_target_record_len;
        }
        std.mem.writeInt(u32, bytes[index_cursor..][0..4], @intCast(src), .little);
        std.mem.writeInt(u32, bytes[index_cursor + 4 ..][0..4], @intCast(start), .little);
        std.mem.writeInt(u32, bytes[index_cursor + 8 ..][0..4], @intCast(pair_index - start), .little);
        index_cursor += metaknow_deferred_based_on_index_record_len;
    }
}

fn ensureMetaknowDeferredBasedOnU32Sized(pairs: []const MetaknowDeferredBasedOnPair, source_count: usize) !void {
    if (pairs.len > std.math.maxInt(u32)) return error.RecordTooLarge;
    if (source_count > std.math.maxInt(u32)) return error.RecordTooLarge;
    for (pairs) |pair| {
        if (pair.src > std.math.maxInt(u32) or pair.dst > std.math.maxInt(u32)) return error.RecordTooLarge;
    }
}

const QueryOutputWriter = struct {
    allocator: std.mem.Allocator,
    buffer: std.ArrayList(u8) = .empty,
    max_bytes: usize = default_cli_output_byte_limit,

    pub fn writeAll(self: *QueryOutputWriter, bytes: []const u8) !void {
        const remaining = if (self.buffer.items.len <= self.max_bytes) self.max_bytes - self.buffer.items.len else 0;
        if (bytes.len > remaining) return error.RecordTooLarge;
        try self.buffer.appendSlice(self.allocator, bytes);
    }

    pub fn print(self: *QueryOutputWriter, comptime fmt: []const u8, args: anytype) !void {
        const text = try std.fmt.allocPrint(self.allocator, fmt, args);
        defer self.allocator.free(text);
        try self.writeAll(text);
    }
};

fn appendTextRebuildTimings(out: *QueryOutputWriter, timings: text_search.PersistentTextRebuildTimings) !void {
    try out.print(
        "text_rebuild_docs_ns={} text_rebuild_term_builder_trim_ns={} text_rebuild_run_finish_ns={} text_rebuild_run_chunk_sort_ns={} text_rebuild_run_chunk_write_ns={} text_rebuild_run_chunk_count={} text_rebuild_run_chunk_records={} text_rebuild_run_term_count={} text_rebuild_run_block_count={} text_rebuild_run_top_hit_term_count={} text_rebuild_run_top_hit_candidate_records={} text_rebuild_run_top_hit_side_stream_candidate_records={} text_rebuild_run_top_hit_local_side_stream_candidate_records={} text_rebuild_run_virtual_all_docs_term_count={} text_rebuild_run_virtual_all_docs_candidate_records={} text_rebuild_run_virtual_all_docs_top_hit_cache_doc_scans={} text_rebuild_run_virtual_all_docs_synthetic_records={} text_rebuild_run_dense_all_docs_freq_stream_term_count={} text_rebuild_run_dense_all_docs_freq_stream_candidate_records={} text_rebuild_run_variable_all_docs_synthetic_records={} text_rebuild_open_docs_ns={} text_rebuild_catalog_ns={} text_rebuild_run_summary_ns={} text_rebuild_run_derived_ns={} text_rebuild_catalog_publish_ns={}\n",
        .{
            timings.docs_ns,
            timings.term_builder_trim_ns,
            timings.run_finish_ns,
            timings.run_chunk_sort_ns,
            timings.run_chunk_write_ns,
            timings.run_chunk_count,
            timings.run_chunk_records,
            timings.run_term_count,
            timings.run_block_count,
            timings.run_top_hit_term_count,
            timings.run_top_hit_candidate_records,
            timings.run_top_hit_side_stream_candidate_records,
            timings.run_top_hit_local_side_stream_candidate_records,
            timings.run_virtual_all_docs_term_count,
            timings.run_virtual_all_docs_candidate_records,
            timings.run_virtual_all_docs_top_hit_cache_doc_scans,
            timings.run_virtual_all_docs_synthetic_records,
            timings.run_dense_all_docs_freq_stream_term_count,
            timings.run_dense_all_docs_freq_stream_candidate_records,
            timings.run_variable_all_docs_synthetic_records,
            timings.open_docs_ns,
            timings.catalog_ns,
            timings.run_summary_ns,
            timings.run_derived_ns,
            textCatalogPublishNs(timings),
        },
    );
    try out.print(
        "text_rebuild_docs_layout_ns={} text_rebuild_docs_node_iter_ns={} text_rebuild_docs_text_read_ns={} text_rebuild_docs_tokenize_ns={} text_rebuild_docs_posting_append_ns={} text_rebuild_docs_write_ns={} text_rebuild_docs_node_count={} text_rebuild_docs_text_bytes={} text_rebuild_docs_token_count={}\n",
        .{
            timings.docs_layout_ns,
            timings.docs_node_iter_ns,
            timings.docs_text_read_ns,
            timings.docs_tokenize_ns,
            timings.docs_posting_append_ns,
            timings.docs_write_ns,
            timings.docs_node_count,
            timings.docs_text_bytes,
            timings.docs_token_count,
        },
    );
    try out.print(
        "text_rebuild_docs_text_inline_count={} text_rebuild_docs_text_inline_bytes={} text_rebuild_docs_text_borrowed_count={} text_rebuild_docs_text_borrowed_bytes={} text_rebuild_docs_text_alloc_count={} text_rebuild_docs_text_alloc_bytes={}\n",
        .{
            timings.docs_text_inline_count,
            timings.docs_text_inline_bytes,
            timings.docs_text_borrowed_count,
            timings.docs_text_borrowed_bytes,
            timings.docs_text_alloc_count,
            timings.docs_text_alloc_bytes,
        },
    );
    try out.print(
        "text_rebuild_docs_freq_cache_lookup_count={} text_rebuild_docs_freq_cache_hit_count={} text_rebuild_docs_freq_cache_miss_count={} text_rebuild_docs_freq_cache_entry_count={} text_rebuild_docs_freq_cache_text_bytes={} text_rebuild_docs_freq_cache_term_count={} text_rebuild_docs_freq_cache_term_bytes={}\n",
        .{
            timings.docs_freq_cache_lookup_count,
            timings.docs_freq_cache_hit_count,
            timings.docs_freq_cache_miss_count,
            timings.docs_freq_cache_entry_count,
            timings.docs_freq_cache_text_bytes,
            timings.docs_freq_cache_term_count,
            timings.docs_freq_cache_term_bytes,
        },
    );
    try out.print(
        "text_rebuild_run_tmp_regular_file_count={} text_rebuild_run_tmp_summary_file_count={} text_rebuild_run_tmp_synthetic_source_count={} text_rebuild_run_tmp_regular_bytes={} text_rebuild_run_tmp_summary_bytes={} text_rebuild_run_tmp_total_bytes={} text_rebuild_run_derived_tmp_postings_bytes={} text_rebuild_run_derived_tmp_terms_bytes={} text_rebuild_run_derived_tmp_blocks_bytes={} text_rebuild_run_derived_tmp_impacts_bytes={} text_rebuild_run_derived_tmp_top_hits_bytes={} text_rebuild_run_derived_tmp_total_bytes={}\n",
        .{
            timings.run_tmp_regular_file_count,
            timings.run_tmp_summary_file_count,
            timings.run_tmp_synthetic_source_count,
            timings.run_tmp_regular_bytes,
            timings.run_tmp_summary_bytes,
            timings.run_tmp_total_bytes,
            timings.run_derived_tmp_postings_bytes,
            timings.run_derived_tmp_terms_bytes,
            timings.run_derived_tmp_blocks_bytes,
            timings.run_derived_tmp_impacts_bytes,
            timings.run_derived_tmp_top_hits_bytes,
            timings.run_derived_tmp_total_bytes,
        },
    );
    try out.print(
        "text_rebuild_run_record_term_bytes={} text_rebuild_run_record_inline_capacity_bytes={} text_rebuild_run_record_term_slack_bytes={} text_rebuild_run_record_term_cache_hits={} text_rebuild_run_record_term_cache_saved_bytes={} text_rebuild_run_record_long_term_count={} text_rebuild_run_record_max_term_len={}\n",
        .{
            timings.run_record_term_bytes,
            timings.run_record_inline_capacity_bytes,
            timings.run_record_term_slack_bytes,
            timings.run_record_term_cache_hits,
            timings.run_record_term_cache_saved_bytes,
            timings.run_record_long_term_count,
            timings.run_record_max_term_len,
        },
    );
    try out.print(
        "text_rebuild_run_chunk_peak_record_bytes={} text_rebuild_run_chunk_peak_term_bytes={} text_rebuild_run_chunk_peak_scratch_bytes={} text_rebuild_run_chunk_peak_record_capacity_bytes={} text_rebuild_run_chunk_peak_term_capacity_bytes={} text_rebuild_run_chunk_peak_scratch_capacity_bytes={}\n",
        .{
            timings.run_chunk_peak_record_bytes,
            timings.run_chunk_peak_term_bytes,
            timings.run_chunk_peak_scratch_bytes,
            timings.run_chunk_peak_record_capacity_bytes,
            timings.run_chunk_peak_term_capacity_bytes,
            timings.run_chunk_peak_scratch_capacity_bytes,
        },
    );
    try out.print(
        "text_rebuild_run_variable_all_docs_freq_stream_cells={} text_rebuild_run_variable_all_docs_freq_stream_packed_bytes={} text_rebuild_run_variable_all_docs_freq_stream_rle_bytes={} text_rebuild_run_variable_all_docs_freq_stream_bitpacked_bytes={} text_rebuild_run_variable_all_docs_freq_stream_rle_run_count={} text_rebuild_run_variable_all_docs_freq_stream_max_freq={}\n",
        .{
            timings.run_variable_all_docs_freq_stream_cells,
            timings.run_variable_all_docs_freq_stream_packed_bytes,
            timings.run_variable_all_docs_freq_stream_rle_bytes,
            timings.run_variable_all_docs_freq_stream_bitpacked_bytes,
            timings.run_variable_all_docs_freq_stream_rle_run_count,
            timings.run_variable_all_docs_freq_stream_max_freq,
        },
    );
    try out.print(
        "text_rebuild_run_inline_singleton_materialized_terms={} text_rebuild_run_inline_singleton_materialized_records={} text_rebuild_run_inline_singleton_materialized_bytes={}\n",
        .{
            timings.run_inline_singleton_materialized_terms,
            timings.run_inline_singleton_materialized_records,
            timings.run_inline_singleton_materialized_bytes,
        },
    );
    try out.print(
        "text_rebuild_docs_posting_append_materialize_ns={} text_rebuild_docs_posting_append_sweep_ns={} text_rebuild_docs_posting_append_regular_sampled_ns={} text_rebuild_docs_posting_append_candidate_lookup_sampled_ns={} text_rebuild_docs_posting_append_candidate_hit_sampled_ns={} text_rebuild_docs_posting_append_virtual_hit_sampled_ns={} text_rebuild_docs_posting_append_variable_hit_sampled_ns={} text_rebuild_docs_posting_append_variable_freq_sampled_ns={} text_rebuild_docs_posting_append_term_count={} text_rebuild_docs_posting_append_regular_record_count={} text_rebuild_docs_posting_append_virtual_candidate_put_count={} text_rebuild_docs_posting_append_virtual_candidate_hit_count={} text_rebuild_docs_posting_append_variable_candidate_hit_count={} text_rebuild_docs_posting_append_variable_freq_append_count={} text_rebuild_docs_posting_append_candidate_filter_skip_count={} text_rebuild_docs_posting_append_candidate_lookup_count={} text_rebuild_docs_posting_append_candidate_cache_hit_count={} text_rebuild_docs_posting_append_candidate_miss_count={} text_rebuild_docs_posting_append_candidate_regularized_hit_count={} text_rebuild_docs_posting_append_materialize_call_count={} text_rebuild_docs_posting_append_sweep_count={} text_rebuild_docs_posting_append_regular_sample_count={} text_rebuild_docs_posting_append_candidate_lookup_sample_count={} text_rebuild_docs_posting_append_candidate_hit_sample_count={} text_rebuild_docs_posting_append_virtual_hit_sample_count={} text_rebuild_docs_posting_append_variable_hit_sample_count={} text_rebuild_docs_posting_append_variable_freq_sample_count={}\n",
        .{
            timings.docs_posting_append_materialize_ns,
            timings.docs_posting_append_sweep_ns,
            timings.docs_posting_append_regular_sampled_ns,
            timings.docs_posting_append_candidate_lookup_sampled_ns,
            timings.docs_posting_append_candidate_hit_sampled_ns,
            timings.docs_posting_append_virtual_hit_sampled_ns,
            timings.docs_posting_append_variable_hit_sampled_ns,
            timings.docs_posting_append_variable_freq_sampled_ns,
            timings.docs_posting_append_term_count,
            timings.docs_posting_append_regular_record_count,
            timings.docs_posting_append_virtual_candidate_put_count,
            timings.docs_posting_append_virtual_candidate_hit_count,
            timings.docs_posting_append_variable_candidate_hit_count,
            timings.docs_posting_append_variable_freq_append_count,
            timings.docs_posting_append_candidate_filter_skip_count,
            timings.docs_posting_append_candidate_lookup_count,
            timings.docs_posting_append_candidate_cache_hit_count,
            timings.docs_posting_append_candidate_miss_count,
            timings.docs_posting_append_candidate_regularized_hit_count,
            timings.docs_posting_append_materialize_call_count,
            timings.docs_posting_append_sweep_count,
            timings.docs_posting_append_regular_sample_count,
            timings.docs_posting_append_candidate_lookup_sample_count,
            timings.docs_posting_append_candidate_hit_sample_count,
            timings.docs_posting_append_virtual_hit_sample_count,
            timings.docs_posting_append_variable_hit_sample_count,
            timings.docs_posting_append_variable_freq_sample_count,
        },
    );
    try out.print(
        "text_rebuild_run_derived_regular_ns={} text_rebuild_run_derived_next_sampled_ns={} text_rebuild_run_derived_next_reader_sampled_ns={} text_rebuild_run_derived_next_queue_sampled_ns={} text_rebuild_run_derived_next_child_probe_count={} text_rebuild_run_derived_next_queue_compare_count={} text_rebuild_run_derived_inline_singleton_next_sampled_ns={} text_rebuild_run_derived_inline_singleton_publish_sampled_ns={} text_rebuild_run_derived_encode_sampled_ns={} text_rebuild_run_derived_write_sampled_ns={} text_rebuild_run_derived_block_stats_sampled_ns={} text_rebuild_run_derived_top_hit_sampled_ns={} text_rebuild_run_derived_block_flush_sampled_ns={} text_rebuild_run_derived_global_doc_rank_ns={} text_rebuild_run_derived_virtual_top_docs_ns={} text_rebuild_run_derived_virtual_ns={} text_rebuild_run_derived_dense_ns={} text_rebuild_run_derived_flush_ns={} text_rebuild_run_derived_rename_ns={} text_rebuild_run_derived_virtual_source_terms={} text_rebuild_run_derived_dense_source_terms={} text_rebuild_run_terms_ns={} text_rebuild_meta_write_ns={}\n",
        .{
            timings.run_derived_regular_ns,
            timings.run_derived_next_sampled_ns,
            timings.run_derived_next_reader_sampled_ns,
            timings.run_derived_next_queue_sampled_ns,
            timings.run_derived_next_child_probe_count,
            timings.run_derived_next_queue_compare_count,
            timings.run_derived_inline_singleton_next_sampled_ns,
            timings.run_derived_inline_singleton_publish_sampled_ns,
            timings.run_derived_encode_sampled_ns,
            timings.run_derived_write_sampled_ns,
            timings.run_derived_block_stats_sampled_ns,
            timings.run_derived_top_hit_sampled_ns,
            timings.run_derived_block_flush_sampled_ns,
            timings.run_derived_global_doc_rank_ns,
            timings.run_derived_virtual_top_docs_ns,
            timings.run_derived_virtual_ns,
            timings.run_derived_dense_ns,
            timings.run_derived_flush_ns,
            timings.run_derived_rename_ns,
            timings.run_derived_virtual_source_terms,
            timings.run_derived_dense_source_terms,
            timings.run_terms_ns,
            timings.meta_write_ns,
        },
    );
    try out.print(
        "text_rebuild_run_derived_inline_singleton_terms={} text_rebuild_run_derived_virtual_terms={} text_rebuild_run_derived_dense_terms={} text_rebuild_run_derived_block_terms={} text_rebuild_run_derived_inline_singleton_records={} text_rebuild_run_derived_virtual_records={} text_rebuild_run_derived_dense_records={} text_rebuild_run_derived_block_records={} text_rebuild_run_derived_top_hit_block_evals={} text_rebuild_run_derived_top_hit_block_skips={} text_rebuild_run_derived_top_hit_block_not_full_evals={} text_rebuild_run_derived_top_hit_block_ready_evals={} text_rebuild_run_derived_top_hit_block_upper_lt_2x_worst={} text_rebuild_run_derived_top_hit_block_upper_lt_4x_worst={} text_rebuild_run_derived_top_hit_block_upper_gte_4x_worst={} text_rebuild_run_derived_top_hit_candidate_evals={} text_rebuild_run_derived_top_hit_doc_reads={} text_rebuild_run_derived_top_hit_regular_candidate_evals={} text_rebuild_run_derived_top_hit_regular_doc_reads={} text_rebuild_run_derived_top_hit_virtual_candidate_evals={} text_rebuild_run_derived_top_hit_virtual_doc_reads={} text_rebuild_run_derived_top_hit_dense_candidate_evals={} text_rebuild_run_derived_top_hit_dense_doc_reads={} text_rebuild_run_derived_top_hit_dense_scan_records={} text_rebuild_run_derived_top_hit_dense_freq_bound_skips={} text_rebuild_run_derived_top_hit_dense_freq_bound_skip_runs={}\n",
        .{
            timings.run_derived_inline_singleton_terms,
            timings.run_derived_virtual_terms,
            timings.run_derived_dense_terms,
            timings.run_derived_block_terms,
            timings.run_derived_inline_singleton_records,
            timings.run_derived_virtual_records,
            timings.run_derived_dense_records,
            timings.run_derived_block_records,
            timings.run_derived_top_hit_block_evals,
            timings.run_derived_top_hit_block_skips,
            timings.run_derived_top_hit_block_not_full_evals,
            timings.run_derived_top_hit_block_ready_evals,
            timings.run_derived_top_hit_block_upper_lt_2x_worst,
            timings.run_derived_top_hit_block_upper_lt_4x_worst,
            timings.run_derived_top_hit_block_upper_gte_4x_worst,
            timings.run_derived_top_hit_candidate_evals,
            timings.run_derived_top_hit_doc_reads,
            timings.run_derived_top_hit_regular_candidate_evals,
            timings.run_derived_top_hit_regular_doc_reads,
            timings.run_derived_top_hit_virtual_candidate_evals,
            timings.run_derived_top_hit_virtual_doc_reads,
            timings.run_derived_top_hit_dense_candidate_evals,
            timings.run_derived_top_hit_dense_doc_reads,
            timings.run_derived_top_hit_dense_scan_records,
            timings.run_derived_top_hit_dense_freq_bound_skips,
            timings.run_derived_top_hit_dense_freq_bound_skip_runs,
        },
    );
    try out.print(
        "text_rebuild_run_derived_top_hit_regular_term_count={} text_rebuild_run_derived_top_hit_regular_doc_read_term_count={} text_rebuild_run_derived_top_hit_regular_top1_doc_reads={} text_rebuild_run_derived_top_hit_regular_top4_doc_reads={} text_rebuild_run_derived_top_hit_regular_top8_doc_reads={} text_rebuild_run_derived_top_hit_regular_top1_candidate_evals={} text_rebuild_run_derived_top_hit_regular_top4_candidate_evals={} text_rebuild_run_derived_top_hit_regular_top8_candidate_evals={} text_rebuild_run_derived_top_hit_regular_heaviest_doc_read_term_postings={} text_rebuild_run_derived_top_hit_regular_heaviest_doc_read_term_block_evals={} text_rebuild_run_derived_top_hit_regular_heaviest_doc_read_term_candidate_evals={} text_rebuild_run_derived_top_hit_regular_constant_terms={} text_rebuild_run_derived_top_hit_regular_constant_resolved_terms={} text_rebuild_run_derived_top_hit_regular_constant_unresolved_terms={} text_rebuild_run_derived_top_hit_regular_constant_candidate_evals={} text_rebuild_run_derived_top_hit_regular_constant_doc_reads={} text_rebuild_run_derived_top_hit_regular_nonconstant_candidate_evals={} text_rebuild_run_derived_top_hit_regular_nonconstant_doc_reads={} text_rebuild_run_derived_top_hit_regular_constant_resolved_candidate_skips={}\n",
        .{
            timings.run_derived_top_hit_regular_term_count,
            timings.run_derived_top_hit_regular_doc_read_term_count,
            timings.run_derived_top_hit_regular_top1_doc_reads,
            timings.run_derived_top_hit_regular_top4_doc_reads,
            timings.run_derived_top_hit_regular_top8_doc_reads,
            timings.run_derived_top_hit_regular_top1_candidate_evals,
            timings.run_derived_top_hit_regular_top4_candidate_evals,
            timings.run_derived_top_hit_regular_top8_candidate_evals,
            timings.run_derived_top_hit_regular_heaviest_doc_read_term_postings,
            timings.run_derived_top_hit_regular_heaviest_doc_read_term_block_evals,
            timings.run_derived_top_hit_regular_heaviest_doc_read_term_candidate_evals,
            timings.run_derived_top_hit_regular_constant_terms,
            timings.run_derived_top_hit_regular_constant_resolved_terms,
            timings.run_derived_top_hit_regular_constant_unresolved_terms,
            timings.run_derived_top_hit_regular_constant_candidate_evals,
            timings.run_derived_top_hit_regular_constant_doc_reads,
            timings.run_derived_top_hit_regular_nonconstant_candidate_evals,
            timings.run_derived_top_hit_regular_nonconstant_doc_reads,
            timings.run_derived_top_hit_regular_constant_resolved_candidate_skips,
        },
    );
}

fn appendNodeBatchAppendTimings(
    out: *QueryOutputWriter,
    load_timings: BenchNodeLoadTimings,
    batch_timings: storage.NodeBatchAppendTimings,
) !void {
    try out.print(
        "bench_node_generate_texts_ns={} bench_node_store_append_ns={} node_batch_batches={} node_batch_nodes={} node_batch_repair_retry_count={} node_batch_repair_ns={} node_batch_read_meta_ns={} node_batch_validate_ns={} node_batch_append_texts_ns={} node_batch_append_event_records_ns={} node_batch_by_id_index_ns={} node_batch_node_text_index_ns={} node_batch_meta_write_ns={}\n",
        .{
            load_timings.generate_texts_ns,
            load_timings.store_append_ns,
            batch_timings.batches,
            batch_timings.nodes,
            batch_timings.repair_retry_count,
            batch_timings.repair_ns,
            batch_timings.read_meta_ns,
            batch_timings.validate_ns,
            batch_timings.append_texts_ns,
            batch_timings.append_event_records_ns,
            batch_timings.by_id_index_ns,
            batch_timings.node_text_index_ns,
            batch_timings.meta_write_ns,
        },
    );
}

fn appendNodeAppendTimings(
    out: *QueryOutputWriter,
    timings: storage.NodeAppendTimings,
) !void {
    try out.print(
        "node_append_nodes={} node_append_next_id_ns={} node_append_validate_ns={} node_append_event_bytes_ns={} node_append_append_texts_ns={} node_append_append_record_ns={} node_append_by_id_index_ns={} node_append_node_text_index_ns={} node_append_meta_write_ns={}\n",
        .{
            timings.nodes,
            timings.next_id_ns,
            timings.validate_ns,
            timings.event_bytes_ns,
            timings.append_texts_ns,
            timings.append_record_ns,
            timings.by_id_index_ns,
            timings.node_text_index_ns,
            timings.meta_write_ns,
        },
    );
}

fn renderBenchOutput(
    allocator: std.mem.Allocator,
    io: std.Io,
    db_path: []const u8,
    node_count: usize,
    edge_count: usize,
    chunk_size: usize,
    workload: BenchWorkload,
    corpus_file_path: ?[]const u8,
    corpus_dir_path: ?[]const u8,
    edge_id_pattern: BenchEdgeIdPattern,
    edge_delta_stats_enabled: bool,
    edge_tombstone_probe_enabled: bool,
    storage_only: bool,
    agent_mixed: bool,
    edge_compact_batch_entries: u32,
    edge_compact_threshold_entries: u32,
    maintenance_every_ops: usize,
    maintenance_max_segments: usize,
    maintenance_max_edges: u64,
    maintenance_gc: bool,
    maintenance_node_text_every_ops: usize,
    maintenance_node_text_max_records: u64,
    maintenance_node_text_runs_every_ops: usize,
    maintenance_node_text_runs_max_records: u64,
    no_regression_gates: BenchNoRegressionGateLimits,
) ![]u8 {
    var out = QueryOutputWriter{ .allocator = allocator };
    errdefer out.buffer.deinit(allocator);

    var store = try storage.Store.initWithOptions(allocator, io, db_path, .{
        .durability = .fast,
        .primary_text_write_mode = .bulk_ingest,
        .validate_indexes_on_read = false,
        .auto_compact_edge_segment_entries = 0,
        .auto_compact_edge_segment_batch_entries = edge_compact_batch_entries,
        .auto_gc_edge_segments = true,
    });
    var edge_delta_stats = storage.EdgeBatchSegmentDeltaStats{};
    store.edge_batch_segment_delta_stats = &edge_delta_stats;
    var node_batch_timings = storage.NodeBatchAppendTimings{};
    store.node_batch_append_timings = &node_batch_timings;
    var node_append_timings = storage.NodeAppendTimings{};
    store.node_append_timings = &node_append_timings;
    var store_live = true;
    defer if (store_live) store.deinit();
    const text_build_search_prebuilt = benchPrebuildsTextCatalogForSearch(node_count);
    var node_texts_pre_edge_compress_ns: u128 = 0;
    const corpus = if (corpus_file_path) |path| try loadBenchCorpusFile(allocator, io, path) else BenchCorpus{};
    defer corpus.deinit(allocator);
    var shard_pool: BenchShardPool = undefined;
    const shard_pool_loaded = workload == .kunshan_shaped_corpus;
    if (shard_pool_loaded) {
        shard_pool = try loadBenchShardPool(allocator, io, corpus_dir_path orelse return error.MissingArgument);
    }
    defer if (shard_pool_loaded) shard_pool.deinit(allocator);
    const text_source = BenchTextSource{
        .workload = workload,
        .corpus = if (corpus_file_path == null) null else &corpus,
        .shards = if (shard_pool_loaded) &shard_pool else null,
    };
    const replay = if (benchWorkloadUsesMetaknowReplay(workload)) try loadBenchMetaknowReplay(allocator, io, corpus_dir_path orelse return error.MissingArgument) else BenchMetaknowReplay{};
    defer replay.deinit(allocator);

    const create_start = monotonicNs(io);
    benchTrace("create_start");
    try store.createEmpty();
    const create_ns = elapsedNs(io, create_start);
    benchTrace("create_done");
    const create_rss = try benchRssSample();
    var bench_phase_store_bytes = BenchPhaseStoreBytes{};
    bench_phase_store_bytes.create = try storeDirBytes(allocator, io, db_path);

    const node_start = monotonicNs(io);
    var text_density = BenchTextDensityStats{};
    var node_load_timings = BenchNodeLoadTimings{};
    benchTrace("initial_nodes_start");
    if (benchWorkloadUsesMetaknowReplay(workload)) {
        try appendBenchMetaknowNodesChunked(allocator, store, &replay, node_count, chunk_size, workload == .metaknow_replay_shaped, &text_density, &node_load_timings);
    } else {
        try appendBenchNodesChunked(allocator, store, node_count, chunk_size, text_source, &text_density, &node_load_timings);
    }
    const add_node_ns = elapsedNs(io, node_start);
    benchTrace("initial_nodes_done");
    const add_node_rss = try benchRssSample();
    const compress_start = monotonicNs(io);
    try store.finalizePrimaryTextStorage();
    node_texts_pre_edge_compress_ns = elapsedNs(io, compress_start);
    bench_phase_store_bytes.add_node = try storeDirBytes(allocator, io, db_path);

    const edge_start = monotonicNs(io);
    benchTrace("initial_edges_start");
    var replay_edge_stats = BenchMetaknowReplayEdgeStats{};
    if (benchWorkloadUsesMetaknowReplay(workload)) {
        replay_edge_stats = try appendBenchMetaknowEdgesChunked(allocator, store, &replay, node_count, edge_count, chunk_size, workload == .metaknow_replay_shaped);
        const deferred_stats = try writeBenchMetaknowDeferredBasedOnSidecar(allocator, store, &replay, node_count);
        replay_edge_stats.deferred_based_on_binary_sources = deferred_stats.sources;
        replay_edge_stats.deferred_based_on_binary_links = deferred_stats.links;
        replay_edge_stats.deferred_based_on_binary_bytes = deferred_stats.bytes;
    } else {
        try appendBenchEdgesChunked(allocator, store, node_count, edge_count, chunk_size, edge_id_pattern);
    }
    const add_edge_total_ns = elapsedNs(io, edge_start);
    benchTrace("initial_edges_done");
    const edge_segment_synchronous_ns = edge_delta_stats.segment_publish_ns + edge_delta_stats.segment_maintenance_ns;
    const add_edge_ns = saturatingSubNs(add_edge_total_ns, edge_segment_synchronous_ns);
    const add_edge_rss = try benchRssSample();
    bench_phase_store_bytes.add_edge = try storeDirBytes(allocator, io, db_path);
    const edge_post_load_maintenance = try runBenchEdgePostLoadMaintenance(io, &store, edge_compact_threshold_entries, edge_compact_batch_entries);
    benchTrace("edge_post_load_maintenance_done");
    const edge_post_load_maintenance_rss = try benchRssSample();
    bench_phase_store_bytes.edge_maintenance = try storeDirBytes(allocator, io, db_path);
    const edge_tombstone_probe = if (edge_tombstone_probe_enabled)
        try runBenchEdgeTombstoneProbe(allocator, io, store, edge_count, edge_id_pattern)
    else
        BenchEdgeTombstoneProbeStats{};

    if (agent_mixed) {
        benchTrace("agent_mixed_start");
        return renderBenchAgentMixedOutput(
            allocator,
            io,
            store,
            db_path,
            node_count,
            edge_count,
            chunk_size,
            workload,
            text_source,
            corpus_file_path,
            corpus_dir_path,
            &text_density,
            edge_id_pattern,
            edge_compact_batch_entries,
            edge_compact_threshold_entries,
            maintenance_every_ops,
            maintenance_max_segments,
            maintenance_max_edges,
            maintenance_gc,
            maintenance_node_text_every_ops,
            maintenance_node_text_max_records,
            maintenance_node_text_runs_every_ops,
            maintenance_node_text_runs_max_records,
            create_ns,
            add_node_ns,
            add_edge_ns,
            create_rss,
            add_node_rss,
            add_edge_rss,
            edge_post_load_maintenance_rss,
            edge_post_load_maintenance,
            node_load_timings,
            node_batch_timings,
        );
    }

    if (storage_only) {
        const stats_out = try store.stats();
        store.deinit();
        store_live = false;
        const store_deinit_rss = try benchRssSample();
        bench_phase_store_bytes.store_deinit = try storeDirBytes(allocator, io, db_path);

        const open_start = monotonicNs(io);
        var reopened = try storage.Store.openWithOptions(allocator, io, db_path, .{
            .durability = .fast,
            .validate_indexes_on_read = false,
        });
        const open_ns = elapsedNs(io, open_start);
        const open_rss = try benchRssSample();
        bench_phase_store_bytes.open = try storeDirBytes(allocator, io, db_path);
        defer reopened.deinit();

        var validate_timings = storage.PersistentValidateTimings{};
        const validate_start = monotonicNs(io);
        try reopened.validatePersistentIndexesWithTimings(&validate_timings);
        const validate_ns = elapsedNs(io, validate_start);
        const validate_rss = try benchRssSample();
        bench_phase_store_bytes.validate = try storeDirBytes(allocator, io, db_path);
        const validate_rss_bytes = validate_rss.peak_bytes;
        const validate_current_rss_bytes = validate_rss.current_bytes;

        var repair_timings = storage.PersistentRepairTimings{};
        const repair_start = monotonicNs(io);
        try reopened.repairPersistentIndexesFromLogWithTimings(&repair_timings);
        const repair_ns = elapsedNs(io, repair_start);
        const repair_rss = try benchRssSample();
        bench_phase_store_bytes.repair = try storeDirBytes(allocator, io, db_path);
        const repair_rss_bytes = repair_rss.peak_bytes;
        const repair_current_rss_bytes = repair_rss.current_bytes;
        const ordered_edge_traversal = try benchOrderedEdgeTraversalProbe(allocator, io, reopened);

        const text_rebuild_start = monotonicNs(io);
        var text_rebuild_timings = text_search.PersistentTextRebuildTimings{};
        var text_rebuild_phase_rss = BenchTextRebuildPhaseRss{};
        const runs_base_path = try benchTextPostingRunsBasePath(allocator, db_path);
        defer allocator.free(runs_base_path);
        const result = rebuildPersistentTextCatalogForBenchWithPhaseRss(allocator, reopened, runs_base_path, &text_rebuild_phase_rss) catch |err|
            return benchBudgetPhase(err, error.BenchStorageOnlyTextRebuildBudgetExceeded);
        text_rebuild_timings = result.timings;
        const text_rebuild_ns = elapsedNs(io, text_rebuild_start);
        const text_rebuild_rss = try benchRssSample();
        bench_phase_store_bytes.text_rebuild = try storeDirBytes(allocator, io, db_path);
        const text_rebuild_rss_bytes = text_rebuild_rss.peak_bytes;
        const text_rebuild_current_rss_bytes = text_rebuild_rss.current_bytes;
        const text_index_bytes = try benchTextIndexBytes(allocator, io, db_path);
        const edge_segments_bytes = try benchEdgeSegmentBytes(allocator, io, db_path);
        const node_texts_compression = try benchNodeTextsCompressionEstimate(allocator, io, db_path);
        const posting_compression = try text_search.estimatePersistentPostingCompression(allocator, reopened);
        const density_breakdown = try benchDensityBreakdown(allocator, io, db_path, reopened, stats_out);
        const replay_warm_stats = if (benchWorkloadUsesMetaknowReplay(workload))
            try benchMetaknowReplayWarmStats(allocator, io, reopened, &replay, node_count, edge_count, workload == .metaknow_replay_shaped)
        else
            BenchMetaknowReplayWarmStats{};

        const total_bytes = try storeDirBytes(allocator, io, db_path);
        const edge_order_bytes = try benchEdgeOrderBytes(allocator, io, db_path);
        const rss_bytes = try peakRssBytes();
        const current_rss_bytes = try currentRssBytes();
        const current_footprint_bytes = try currentFootprintBytes();
        const footprint_samples = [_]BenchRssSample{
            create_rss,
            add_node_rss,
            add_edge_rss,
            edge_post_load_maintenance_rss,
            store_deinit_rss,
            open_rss,
            validate_rss,
            repair_rss,
            text_rebuild_rss,
            .{ .peak_bytes = rss_bytes, .current_bytes = current_rss_bytes, .footprint_bytes = current_footprint_bytes },
        };
        const footprint_peak_bytes = maxBenchFootprintBytes(&footprint_samples, text_rebuild_phase_rss);
        try out.print(
            "shape={s}\nbench_workload={s}\nbuild_optimize={s}\nmode=storage-only\ntext_rebuild_mode={s}\nnodes={} edges={} bytes={} rss_bytes={} current_rss_bytes={} footprint_peak_bytes={} current_footprint_bytes={} chunk={} edge_id_pattern={s} edge_compact_batch={} edge_compact_threshold={} edge_auto_gc=1\n",
            .{
                workload.shapeLabel(),
                workload.label(),
                buildOptimizeLabel(),
                "runs",
                stats_out.nodes,
                stats_out.edges,
                total_bytes,
                rss_bytes,
                current_rss_bytes,
                footprint_peak_bytes,
                current_footprint_bytes,
                chunk_size,
                edge_id_pattern.label(),
                edge_compact_batch_entries,
                edge_compact_threshold_entries,
            },
        );
        try out.print(
            "bench_corpus_file={s}\nbench_corpus_dir={s}\nbench_corpus_records={}\n",
            .{ corpus_file_path orelse "", corpus_dir_path orelse "", text_source.corpusRecordCount() },
        );
        try appendBenchMetaknowReplayStats(&out, replay.statsForOutput(node_count, workload == .metaknow_replay_shaped), replay_edge_stats, replay_warm_stats);
        try out.print(
            "edge_tombstone_probe_enabled={} edge_tombstone_probe_requested={} edge_tombstone_probe_deleted={} edge_tombstone_probe_ns={}\nedge_tombstone_probe_visible_edges={} edge_tombstone_probe_physical_edges={} edge_tombstone_probe_tombstone_edges={} edge_tombstone_probe_tombstone_ratio_bps={}\n",
            .{
                @intFromBool(edge_tombstone_probe_enabled),
                edge_tombstone_probe.requested,
                edge_tombstone_probe.deleted,
                edge_tombstone_probe.ns,
                edge_tombstone_probe.visible_edges,
                edge_tombstone_probe.physical_edges,
                edge_tombstone_probe.tombstone_edges,
                edge_tombstone_probe.tombstone_ratio_bps,
            },
        );
        try out.print(
            "create_ns={}\nadd_node_ns={} add_node_ns_per={} node_texts_pre_edge_compress_ns={}\nadd_edge_ns={} add_edge_ns_per={} add_edge_total_ns={} add_edge_total_ns_per={} edge_segment_synchronous_ns={} edge_segment_publish_ns={} edge_segment_maintenance_ns={}\n",
            .{
                create_ns,
                add_node_ns,
                perOpNs(add_node_ns, node_count),
                node_texts_pre_edge_compress_ns,
                add_edge_ns,
                perOpNs(add_edge_ns, edge_count),
                add_edge_total_ns,
                perOpNs(add_edge_total_ns, edge_count),
                edge_segment_synchronous_ns,
                edge_delta_stats.segment_publish_ns,
                edge_delta_stats.segment_maintenance_ns,
            },
        );
        try out.print(
            "open_ns={} validate_ns={} validate_stats_ns={} validate_index_files_ns={} repair_ns={} text_rebuild_ns={}\n",
            .{
                open_ns,
                validate_ns,
                validate_timings.stats_ns,
                validate_timings.index_files_ns,
                repair_ns,
                text_rebuild_ns,
            },
        );
        try out.print(
            "validate_rss_bytes={} validate_current_rss_bytes={} repair_rss_bytes={} repair_current_rss_bytes={} text_rebuild_rss_bytes={} text_rebuild_current_rss_bytes={}\n",
            .{
                validate_rss_bytes,
                validate_current_rss_bytes,
                repair_rss_bytes,
                repair_current_rss_bytes,
                text_rebuild_rss_bytes,
                text_rebuild_current_rss_bytes,
            },
        );
        try appendBenchPhaseRss(
            &out,
            create_rss,
            add_node_rss,
            add_edge_rss,
            edge_post_load_maintenance_rss,
            null,
            store_deinit_rss,
            open_rss,
            validate_rss,
            repair_rss,
            text_rebuild_rss,
        );
        try appendBenchPhaseStoreBytes(&out, bench_phase_store_bytes);
        try appendBenchOrderedEdgeMetrics(&out, edge_order_bytes, ordered_edge_traversal);
        try out.print(
            "edge_post_load_maintenance_ns={} edge_post_load_maintenance_compactions={}\n",
            .{ edge_post_load_maintenance.ns, edge_post_load_maintenance.compactions },
        );
        try appendNodeBatchAppendTimings(&out, node_load_timings, node_batch_timings);
        try appendBenchDensityMetrics(&out, &text_density, total_bytes, text_index_bytes, edge_segments_bytes, node_texts_compression, posting_compression, density_breakdown);
        if (edge_delta_stats_enabled) try appendEdgeDeltaStats(&out, edge_delta_stats);
        try appendValidateTimings(&out, validate_timings);
        try appendRepairTimings(&out, repair_timings);
        try appendTextRebuildTimings(&out, text_rebuild_timings);
        try appendTextRebuildPhaseRss(&out, text_rebuild_phase_rss);
        return out.buffer.toOwnedSlice(allocator);
    }

    var text_rebuild_timings = text_search.PersistentTextRebuildTimings{};
    var text_rebuild_ns: u128 = 0;
    var text_rebuild_rss_bytes: usize = 0;
    var text_rebuild_current_rss_bytes: usize = 0;
    var text_rebuild_rss = BenchRssSample{ .peak_bytes = 0, .current_bytes = 0, .footprint_bytes = 0 };
    var text_rebuild_phase_rss = BenchTextRebuildPhaseRss{};
    var repair_timings = storage.PersistentRepairTimings{};
    var repair_ns: u128 = 0;
    var repair_final_compress_ns: u128 = 0;
    var repair_rss = BenchRssSample{ .peak_bytes = 0, .current_bytes = 0, .footprint_bytes = 0 };
    var repair_rss_bytes: u64 = 0;
    var repair_current_rss_bytes: u64 = 0;
    if (text_build_search_prebuilt) {
        benchTrace("pre_search_repair_start");
        const repair_start = monotonicNs(io);
        try store.repairPersistentIndexesFromLogWithTimings(&repair_timings);
        repair_ns = elapsedNs(io, repair_start);
        repair_rss = try benchRssSample();
        bench_phase_store_bytes.repair = try storeDirBytes(allocator, io, db_path);
        repair_rss_bytes = repair_rss.peak_bytes;
        repair_current_rss_bytes = repair_rss.current_bytes;
        benchTrace("pre_search_repair_done");
    }

    const lookup_node_id = try benchExactTextLookupNodeId(node_count, text_source);
    const lookup_text = try benchNodeText(allocator, lookup_node_id, text_source);
    defer allocator.free(lookup_text);
    const lookup_base_text = try benchNodeText(allocator, 1, text_source);
    defer allocator.free(lookup_base_text);
    benchTraceOp("lookup_node_id", lookup_node_id);
    benchTrace("lookup_start");
    var lookup_full_timing_breakdown = storage.Store.NodeTextLookupTimings{};
    const lookup_start = monotonicNs(io);
    var matches = store.lookupNodesByTextLimitedWithTimings(allocator, .file, lookup_text, 1, &lookup_full_timing_breakdown) catch |err| {
        benchTrace("lookup_graph_error");
        return err;
    };
    const lookup_ns = elapsedNs(io, lookup_start);
    benchTraceOp("lookup_graph_rows", matches.items.len);
    if (matches.items.len != 1) {
        for (matches.items) |*node| node.deinit(allocator);
        matches.deinit(allocator);
        return error.InvalidRecord;
    }
    for (matches.items) |*node| node.deinit(allocator);
    matches.deinit(allocator);
    benchTrace("lookup_graph_done");

    var lookup_open_timing_breakdown = storage.Store.NodeTextLookupOpenTimings{};
    const lookup_view_open_start = monotonicNs(io);
    var lookup_view = try store.openNodeTextLookupViewWithTimings(allocator, &lookup_open_timing_breakdown);
    const lookup_view_open_ns = elapsedNs(io, lookup_view_open_start);
    defer lookup_view.deinit();
    benchTrace("lookup_view_open_done");

    var lookup_timing_breakdown = storage.Store.NodeTextLookupTimings{};
    const lookup_ids_retained_start = monotonicNs(io);
    var lookup_ids_retained = try lookup_view.lookupIdsWithTimings(allocator, .file, lookup_text, 1, &lookup_timing_breakdown);
    const lookup_ids_retained_ns = elapsedNs(io, lookup_ids_retained_start);
    if (lookup_ids_retained.items.len != 1) {
        lookup_ids_retained.deinit(allocator);
        return error.InvalidRecord;
    }
    lookup_ids_retained.deinit(allocator);

    const lookup_ids_retained_hot_start = monotonicNs(io);
    var lookup_ids_retained_hot = try lookup_view.lookupIds(allocator, .file, lookup_text, 1);
    const lookup_ids_retained_hot_ns = elapsedNs(io, lookup_ids_retained_hot_start);
    if (lookup_ids_retained_hot.items.len != 1) {
        lookup_ids_retained_hot.deinit(allocator);
        return error.InvalidRecord;
    }
    lookup_ids_retained_hot.deinit(allocator);

    var lookup_retained_samples: [bench_tinyql_suite_samples]u128 = undefined;
    var lookup_retained_rows_last: usize = 0;
    for (&lookup_retained_samples) |*sample| {
        const sample_start = monotonicNs(io);
        var lookup_retained = try lookup_view.lookupIds(allocator, .file, lookup_text, 1);
        sample.* = elapsedNs(io, sample_start);
        if (lookup_retained.items.len != 1) {
            lookup_retained.deinit(allocator);
            return error.InvalidRecord;
        }
        lookup_retained_rows_last = lookup_retained.items.len;
        lookup_retained.deinit(allocator);
    }
    const lookup_retained_stats = latencyStats(&lookup_retained_samples);

    var lookup_base_timing_breakdown = storage.Store.NodeTextLookupTimings{};
    const lookup_base_first = try lookup_view.lookupFirstIdWithTimings(.file, lookup_base_text, &lookup_base_timing_breakdown);
    if (lookup_base_first == null or lookup_base_first.?.toInt() != 1) return error.InvalidRecord;
    var lookup_base_retained_samples: [bench_tinyql_suite_samples]u128 = undefined;
    var lookup_base_retained_rows_last: usize = 0;
    for (&lookup_base_retained_samples) |*sample| {
        const sample_start = monotonicNs(io);
        const base_id = try lookup_view.lookupFirstId(.file, lookup_base_text);
        sample.* = elapsedNs(io, sample_start);
        if (base_id == null or base_id.?.toInt() != 1) return error.InvalidRecord;
        lookup_base_retained_rows_last = 1;
    }
    const lookup_base_retained_stats = latencyStats(&lookup_base_retained_samples);
    benchTrace("lookup_retained_done");

    const lookup_ids_public_start = monotonicNs(io);
    var lookup_ids_public_timing_breakdown = storage.Store.NodeTextLookupTimings{};
    var lookup_ids_public = try store.lookupNodeIdsByTextLimitedWithTimings(allocator, .file, lookup_text, 1, &lookup_ids_public_timing_breakdown);
    const lookup_ids_public_ns = elapsedNs(io, lookup_ids_public_start);
    if (lookup_ids_public.items.len != 1) {
        lookup_ids_public.deinit(allocator);
        return error.InvalidRecord;
    }
    lookup_ids_public.deinit(allocator);
    var lookup_base_public_timing_breakdown = storage.Store.NodeTextLookupTimings{};
    const lookup_base_public_start = monotonicNs(io);
    var lookup_base_public = try store.lookupNodeIdsByTextLimitedWithTimings(allocator, .file, lookup_base_text, 1, &lookup_base_public_timing_breakdown);
    const lookup_base_public_ns = elapsedNs(io, lookup_base_public_start);
    if (lookup_base_public.items.len != 1 or lookup_base_public.items[0].toInt() != 1) {
        lookup_base_public.deinit(allocator);
        return error.InvalidRecord;
    }
    lookup_base_public.deinit(allocator);

    var lookup_first_public_timing_breakdown = storage.Store.NodeTextLookupTimings{};
    const lookup_first_public_start = monotonicNs(io);
    const lookup_first_public = try store.lookupFirstNodeIdByTextWithTimings(allocator, .file, lookup_text, &lookup_first_public_timing_breakdown);
    const lookup_first_public_ns = elapsedNs(io, lookup_first_public_start);
    if (lookup_first_public == null) return error.InvalidRecord;

    var lookup_base_first_public_timing_breakdown = storage.Store.NodeTextLookupTimings{};
    const lookup_base_first_public_start = monotonicNs(io);
    const lookup_base_first_public = try store.lookupFirstNodeIdByTextWithTimings(allocator, .file, lookup_base_text, &lookup_base_first_public_timing_breakdown);
    const lookup_base_first_public_ns = elapsedNs(io, lookup_base_first_public_start);
    if (lookup_base_first_public == null or lookup_base_first_public.?.toInt() != 1) return error.InvalidRecord;

    const lookup_ids_public_samples = try benchPublicNodeTextIdLookupSamples(allocator, io, store, .file, lookup_text, null);
    const lookup_base_public_samples = try benchPublicNodeTextIdLookupSamples(allocator, io, store, .file, lookup_base_text, 1);
    const lookup_first_public_samples = try benchPublicNodeTextFirstIdLookupSamples(allocator, io, store, .file, lookup_text, null);
    const lookup_base_first_public_samples = try benchPublicNodeTextFirstIdLookupSamples(allocator, io, store, .file, lookup_base_text, 1);
    benchTrace("lookup_public_done");

    const neighbors_start = monotonicNs(io);
    var neighbors = query.neighborsWithPersistentStore(allocator, store, .fromInt(1), .mentions, .{}) catch |err|
        return benchBudgetPhase(err, error.BenchNeighborsBudgetExceeded);
    const neighbors_ns = elapsedNs(io, neighbors_start);
    if (neighbors.stats.budget_exceeded) {
        neighbors.deinit(allocator);
        return error.BenchNeighborsBudgetExceeded;
    }
    const neighbors_len = neighbors.neighbors.items.len;
    const neighbors_nodes_visited = neighbors.stats.nodes_visited;
    const neighbors_edges_visited = neighbors.stats.edges_visited;
    neighbors.deinit(allocator);
    benchTrace("neighbors_hit_done");

    const neighbors_rel_miss_start = monotonicNs(io);
    var neighbors_rel_miss = query.neighborsWithPersistentStore(allocator, store, .fromInt(1), .defines, .{}) catch |err|
        return benchBudgetPhase(err, error.BenchNeighborsRelMissBudgetExceeded);
    const neighbors_rel_miss_ns = elapsedNs(io, neighbors_rel_miss_start);
    if (neighbors_rel_miss.stats.budget_exceeded) {
        neighbors_rel_miss.deinit(allocator);
        return error.BenchNeighborsRelMissBudgetExceeded;
    }
    const neighbors_rel_miss_len = neighbors_rel_miss.neighbors.items.len;
    const neighbors_rel_miss_nodes_visited = neighbors_rel_miss.stats.nodes_visited;
    const neighbors_rel_miss_edges_visited = neighbors_rel_miss.stats.edges_visited;
    neighbors_rel_miss.deinit(allocator);
    if (neighbors_rel_miss_len != 0) return error.InvalidRecord;
    benchTrace("neighbors_miss_done");

    const ordered_edge_traversal = try benchOrderedEdgeTraversalProbe(allocator, io, store);
    benchTrace("ordered_edge_traversal_done");

    const search_query = try benchSearchQuery(allocator, node_count);
    defer allocator.free(search_query);
    if (text_build_search_prebuilt) {
        benchTrace("text_rebuild_pre_search_start");
        const text_rebuild_start = monotonicNs(io);
        const runs_base_path = try benchTextPostingRunsBasePath(allocator, db_path);
        defer allocator.free(runs_base_path);
        const result = rebuildPersistentTextCatalogForBenchWithPhaseRss(allocator, store, runs_base_path, &text_rebuild_phase_rss) catch |err|
            return benchBudgetPhase(err, error.BenchTextRebuildBudgetExceeded);
        text_rebuild_timings = result.timings;
        text_rebuild_ns = elapsedNs(io, text_rebuild_start);
        text_rebuild_rss = try benchRssSample();
        bench_phase_store_bytes.text_rebuild = try storeDirBytes(allocator, io, db_path);
        text_rebuild_rss_bytes = text_rebuild_rss.peak_bytes;
        text_rebuild_current_rss_bytes = text_rebuild_rss.current_bytes;
        benchTrace("text_rebuild_pre_search_done");
    }
    const text_build_search_start = monotonicNs(io);
    var cold_hits = text_search.searchText(allocator, store, search_query, .{ .limit = 8 }) catch |err|
        return benchBudgetPhase(err, error.BenchTextBuildSearchBudgetExceeded);
    const text_build_search_ns = elapsedNs(io, text_build_search_start);
    if (cold_hits.items.len == 0) {
        cold_hits.deinit(allocator);
        return error.InvalidRecord;
    }
    cold_hits.deinit(allocator);

    const search_start = monotonicNs(io);
    var hits = text_search.searchText(allocator, store, search_query, .{ .limit = 8 }) catch |err|
        return benchBudgetPhase(err, error.BenchTextWarmSearchBudgetExceeded);
    const search_ns = elapsedNs(io, search_start);
    const search_hits = hits.items.len;
    hits.deinit(allocator);
    if (search_hits == 0) return error.InvalidRecord;

    // The warm text probes gate the product read path: a published catalog
    // (plus any appended tail) serves queries, and the catalog-less bounded
    // scan above stays measured by text_build_search. Publish before probing
    // when the large-bench path has not already done so; the destructive
    // repair probes later corrupt and republish their own state.
    if (!text_build_search_prebuilt) {
        const probe_runs_base_path = try benchTextPostingRunsBasePath(allocator, db_path);
        defer allocator.free(probe_runs_base_path);
        var probe_rebuild_phase_rss = BenchTextRebuildPhaseRss{};
        _ = rebuildPersistentTextCatalogForBenchWithPhaseRss(allocator, store, probe_runs_base_path, &probe_rebuild_phase_rss) catch |err|
            return benchBudgetPhase(err, error.BenchTextRebuildBudgetExceeded);
    }

    const path_query = try benchPathSearchQuery(allocator, node_count);
    defer allocator.free(path_query);
    const text_code = benchTextProbe(allocator, store, "parseInvalidRecord") catch |err|
        return benchBudgetPhase(err, error.BenchTextCodeBudgetExceeded);
    const text_path = benchTextProbe(allocator, store, path_query) catch |err|
        return benchBudgetPhase(err, error.BenchTextPathBudgetExceeded);
    const text_english = benchTextProbe(allocator, store, "agent latency budget") catch |err|
        return benchBudgetPhase(err, error.BenchTextEnglishBudgetExceeded);
    const text_cjk = benchTextProbe(allocator, store, "错误记录") catch |err|
        return benchBudgetPhase(err, error.BenchTextCjkBudgetExceeded);
    const text_japanese = benchTextProbe(allocator, store, "エラー解析") catch |err|
        return benchBudgetPhase(err, error.BenchTextJapaneseBudgetExceeded);
    const text_korean = benchTextProbe(allocator, store, "오류") catch |err|
        return benchBudgetPhase(err, error.BenchTextKoreanBudgetExceeded);
    const text_highfreq = benchTextProbe(allocator, store, "common") catch |err|
        return benchBudgetPhase(err, error.BenchTextHighfreqBudgetExceeded);

    const tinyql_lookup_query = try benchTinyQlLookupQuery(allocator, lookup_text);
    defer allocator.free(tinyql_lookup_query);
    const tinyql_path_query = try benchTinyQlPathQuery(allocator, lookup_text);
    defer allocator.free(tinyql_path_query);
    const reachable_from_text = try benchNodeText(allocator, 1, text_source);
    defer allocator.free(reachable_from_text);
    const reachable_to_text = try benchNodeText(allocator, @min(node_count, 3), text_source);
    defer allocator.free(reachable_to_text);
    const tinyql_context_render_query = try benchTinyQlContextQuery(allocator, lookup_text);
    defer allocator.free(tinyql_context_render_query);
    const tinyql_reachable_render_query = try benchTinyQlReachableQuery(allocator, reachable_from_text, reachable_to_text, benchHasPositiveReachableFixture(node_count, edge_count));
    defer allocator.free(tinyql_reachable_render_query);
    const tinyql_text_context_render_query = try benchTinyQlTextContextQuery(allocator, "benchdoc1");
    defer allocator.free(tinyql_text_context_render_query);
    const tinyql_text_path_render_query = try benchTinyQlTextPathQuery(allocator, "benchdoc1");
    defer allocator.free(tinyql_text_path_render_query);
    const tinyql_text_reachable_render_query = try benchTinyQlTextReachableQuery(allocator, "benchdoc1", reachable_to_text, benchHasPositiveReachableFixture(node_count, edge_count));
    defer allocator.free(tinyql_text_reachable_render_query);
    const tinyql_text_unreachable_render_query = try benchTinyQlTextUnreachableQuery(allocator, "benchdoc1", benchHasPositiveReachableFixture(node_count, edge_count));
    defer allocator.free(tinyql_text_unreachable_render_query);
    const tinyql_text_mixed_render_query = try benchTinyQlTextMixedRenderQuery(allocator, "benchdoc1", reachable_to_text, benchHasPositiveReachableFixture(node_count, edge_count));
    defer allocator.free(tinyql_text_mixed_render_query);
    const tinyql_lookup = benchTinyQlProbe(allocator, io, store, tinyql_lookup_query) catch |err|
        return benchBudgetPhase(err, error.BenchTinyQlLookupBudgetExceeded);
    const tinyql_text = benchTinyQlProbe(allocator, io, store, "MATCH TEXT \"错误记录\" AS f:file RETURN f LIMIT 8") catch |err|
        return benchBudgetPhase(err, error.BenchTinyQlTextBudgetExceeded);
    const tinyql_expand = benchTinyQlProbe(allocator, io, store, "MATCH TEXT \"benchdoc1\" AS f:file MATCH (f)-[:mentions]->(n:file) RETURN n LIMIT 8") catch |err|
        return benchBudgetPhase(err, error.BenchTinyQlExpandBudgetExceeded);
    const tinyql_path_probe = benchTinyQlProbe(allocator, io, store, tinyql_path_query) catch |err|
        return benchBudgetPhase(err, error.BenchTinyQlPathBudgetExceeded);
    const tinyql_lookup_suite = benchTinyQlSuite(allocator, io, store, tinyql_lookup_query) catch |err|
        return benchBudgetPhase(err, error.BenchTinyQlLookupSuiteBudgetExceeded);
    const tinyql_text_suite = benchTinyQlSuite(allocator, io, store, "MATCH TEXT \"错误记录\" AS f:file RETURN f LIMIT 8") catch |err|
        return benchBudgetPhase(err, error.BenchTinyQlTextSuiteBudgetExceeded);
    const tinyql_expand_suite = benchTinyQlSuite(allocator, io, store, "MATCH TEXT \"benchdoc1\" AS f:file MATCH (f)-[:mentions]->(n:file) RETURN n LIMIT 8") catch |err|
        return benchBudgetPhase(err, error.BenchTinyQlExpandSuiteBudgetExceeded);
    const tinyql_path_suite = benchTinyQlSuite(allocator, io, store, tinyql_path_query) catch |err|
        return benchBudgetPhase(err, error.BenchTinyQlPathSuiteBudgetExceeded);
    const tinyql_path_render_suite = benchTinyQlRenderSuite(allocator, io, store, tinyql_path_query) catch |err|
        return benchBudgetPhase(err, error.BenchTinyQlPathRenderBudgetExceeded);
    const tinyql_context_render_suite = benchTinyQlRenderSuite(allocator, io, store, tinyql_context_render_query) catch |err|
        return benchBudgetPhase(err, error.BenchTinyQlContextRenderBudgetExceeded);
    const tinyql_reachable_render_suite = benchTinyQlRenderSuite(allocator, io, store, tinyql_reachable_render_query) catch |err|
        return benchBudgetPhase(err, error.BenchTinyQlReachableRenderBudgetExceeded);
    const tinyql_text_context_render_suite = benchTinyQlRenderSuite(allocator, io, store, tinyql_text_context_render_query) catch |err|
        return benchBudgetPhase(err, error.BenchTinyQlTextContextRenderBudgetExceeded);
    const tinyql_text_path_render_suite = benchTinyQlRenderSuite(allocator, io, store, tinyql_text_path_render_query) catch |err|
        return benchBudgetPhase(err, error.BenchTinyQlTextPathRenderBudgetExceeded);
    const tinyql_text_reachable_render_suite = benchTinyQlRenderSuite(allocator, io, store, tinyql_text_reachable_render_query) catch |err|
        return benchBudgetPhase(err, error.BenchTinyQlTextReachableRenderBudgetExceeded);
    const tinyql_text_unreachable_render_suite = benchTinyQlRenderSuite(allocator, io, store, tinyql_text_unreachable_render_query) catch |err|
        return benchBudgetPhase(err, error.BenchTinyQlTextUnreachableRenderBudgetExceeded);
    const tinyql_text_mixed_render_suite = benchTinyQlRenderSuite(allocator, io, store, tinyql_text_mixed_render_query) catch |err|
        return benchBudgetPhase(err, error.BenchTinyQlTextMixedRenderBudgetExceeded);

    const path_to = core.NodeId.fromInt(@intCast(@min(node_count, 4)));
    const path_start = monotonicNs(io);
    var path = query.pathWithPersistentStore(allocator, store, .fromInt(1), path_to, .mentions, .{
        .max_depth = 4,
        .max_results = 8,
    }) catch |err| return benchBudgetPhase(err, error.BenchPathBudgetExceeded);
    const path_ns = elapsedNs(io, path_start);
    if (path.stats.budget_exceeded) {
        path.deinit(allocator);
        return error.BenchPathBudgetExceeded;
    }
    const path_nodes_len = path.nodes.items.len;
    const path_nodes_visited = path.stats.nodes_visited;
    const path_edges_visited = path.stats.edges_visited;
    path.deinit(allocator);
    if (path_nodes_len == 0) return error.InvalidRecord;
    const query_rss = try benchRssSample();
    bench_phase_store_bytes.query = try storeDirBytes(allocator, io, db_path);

    const stats_out = try store.stats();
    store.deinit();
    store_live = false;
    const store_deinit_rss = try benchRssSample();
    bench_phase_store_bytes.store_deinit = try storeDirBytes(allocator, io, db_path);

    const open_start = monotonicNs(io);
    var reopened = try storage.Store.openWithOptions(allocator, io, db_path, .{
        .durability = .fast,
        .validate_indexes_on_read = false,
    });
    const open_ns = elapsedNs(io, open_start);
    const open_rss = try benchRssSample();
    bench_phase_store_bytes.open = try storeDirBytes(allocator, io, db_path);
    defer reopened.deinit();

    var validate_timings = storage.PersistentValidateTimings{};
    const validate_start = monotonicNs(io);
    try reopened.validatePersistentIndexesWithTimings(&validate_timings);
    const validate_ns = elapsedNs(io, validate_start);
    const validate_rss = try benchRssSample();
    bench_phase_store_bytes.validate = try storeDirBytes(allocator, io, db_path);
    const validate_rss_bytes = validate_rss.peak_bytes;
    const validate_current_rss_bytes = validate_rss.current_bytes;

    if (!text_build_search_prebuilt) {
        const repair_start = monotonicNs(io);
        try reopened.repairPersistentIndexesFromLogWithTimings(&repair_timings);
        repair_ns = elapsedNs(io, repair_start);
        repair_rss = try benchRssSample();
        bench_phase_store_bytes.repair = try storeDirBytes(allocator, io, db_path);
        repair_rss_bytes = repair_rss.peak_bytes;
        repair_current_rss_bytes = repair_rss.current_bytes;
    } else {
        const repair_start = monotonicNs(io);
        try reopened.finalizePrimaryTextStorage();
        repair_final_compress_ns = elapsedNs(io, repair_start);
        repair_ns += repair_final_compress_ns;
        repair_rss = try benchRssSample();
        bench_phase_store_bytes.repair = try storeDirBytes(allocator, io, db_path);
        repair_rss_bytes = repair_rss.peak_bytes;
        repair_current_rss_bytes = repair_rss.current_bytes;
    }

    if (!text_build_search_prebuilt) {
        const text_rebuild_start = monotonicNs(io);
        const runs_base_path = try benchTextPostingRunsBasePath(allocator, db_path);
        defer allocator.free(runs_base_path);
        const result = rebuildPersistentTextCatalogForBenchWithPhaseRss(allocator, reopened, runs_base_path, &text_rebuild_phase_rss) catch |err|
            return benchBudgetPhase(err, error.BenchTextRebuildBudgetExceeded);
        text_rebuild_timings = result.timings;
        text_rebuild_ns = elapsedNs(io, text_rebuild_start);
        text_rebuild_rss = try benchRssSample();
        bench_phase_store_bytes.text_rebuild = try storeDirBytes(allocator, io, db_path);
        text_rebuild_rss_bytes = text_rebuild_rss.peak_bytes;
        text_rebuild_current_rss_bytes = text_rebuild_rss.current_bytes;
    }
    const post_repair_lookup = try benchNodeTextLookupProbe(allocator, io, reopened, lookup_text, lookup_base_text);
    const text_index_bytes = try benchTextIndexBytes(allocator, io, db_path);
    const edge_segments_bytes = try benchEdgeSegmentBytes(allocator, io, db_path);
    const node_texts_compression = try benchNodeTextsCompressionEstimate(allocator, io, db_path);
    const posting_compression = try text_search.estimatePersistentPostingCompression(allocator, reopened);
    const density_breakdown = try benchDensityBreakdown(allocator, io, db_path, reopened, stats_out);

    var text_repair_search_ns: u128 = 0;
    var text_stale_search_ns: u128 = 0;
    const text_repair_search_skipped = !benchRunsDestructiveTextRepairProbes(node_count);
    const text_stale_search_skipped = text_repair_search_skipped;
    if (!text_repair_search_skipped) {
        try corruptBenchTextPostings(allocator, io, db_path);
        const text_repair_search_start = monotonicNs(io);
        var repaired_hits = text_search.searchText(allocator, reopened, search_query, .{ .limit = 8 }) catch |err|
            return benchBudgetPhase(err, error.BenchTextRepairSearchBudgetExceeded);
        text_repair_search_ns = elapsedNs(io, text_repair_search_start);
        const repaired_hits_len = repaired_hits.items.len;
        repaired_hits.deinit(allocator);
        if (repaired_hits_len == 0) return error.InvalidRecord;

        try staleBenchTextMeta(allocator, io, db_path);
        const text_stale_search_start = monotonicNs(io);
        var stale_hits = text_search.searchText(allocator, reopened, search_query, .{ .limit = 8 }) catch |err|
            return benchBudgetPhase(err, error.BenchTextStaleSearchBudgetExceeded);
        text_stale_search_ns = elapsedNs(io, text_stale_search_start);
        const stale_hits_len = stale_hits.items.len;
        stale_hits.deinit(allocator);
        if (stale_hits_len == 0) return error.InvalidRecord;
    }

    const total_bytes = try storeDirBytes(allocator, io, db_path);
    const edge_order_bytes = try benchEdgeOrderBytes(allocator, io, db_path);
    const rss_bytes = try peakRssBytes();
    const current_rss_bytes = try currentRssBytes();
    const current_footprint_bytes = try currentFootprintBytes();
    const footprint_samples = [_]BenchRssSample{
        create_rss,
        add_node_rss,
        add_edge_rss,
        edge_post_load_maintenance_rss,
        query_rss,
        store_deinit_rss,
        open_rss,
        validate_rss,
        repair_rss,
        text_rebuild_rss,
        .{ .peak_bytes = rss_bytes, .current_bytes = current_rss_bytes, .footprint_bytes = current_footprint_bytes },
    };
    const footprint_peak_bytes = maxBenchFootprintBytes(&footprint_samples, text_rebuild_phase_rss);

    try out.print(
        "shape={s}\nbench_workload={s}\nbuild_optimize={s}\nnodes={} edges={} bytes={} rss_bytes={} current_rss_bytes={} footprint_peak_bytes={} current_footprint_bytes={} chunk={} edge_id_pattern={s} edge_compact_batch={} edge_compact_threshold={} edge_auto_gc=1\n",
        .{
            workload.shapeLabel(),
            workload.label(),
            buildOptimizeLabel(),
            stats_out.nodes,
            stats_out.edges,
            total_bytes,
            rss_bytes,
            current_rss_bytes,
            footprint_peak_bytes,
            current_footprint_bytes,
            chunk_size,
            edge_id_pattern.label(),
            edge_compact_batch_entries,
            edge_compact_threshold_entries,
        },
    );
    try out.print(
        "bench_corpus_file={s}\nbench_corpus_dir={s}\nbench_corpus_records={}\n",
        .{ corpus_file_path orelse "", corpus_dir_path orelse "", text_source.corpusRecordCount() },
    );
    try appendBenchMetaknowReplayStats(&out, replay.statsForOutput(node_count, workload == .metaknow_replay_shaped), replay_edge_stats, .{});
    try out.print(
        "create_ns={}\nadd_node_ns={} add_node_ns_per={} node_texts_pre_edge_compress_ns={}\nadd_edge_ns={} add_edge_ns_per={} add_edge_total_ns={} add_edge_total_ns_per={} edge_segment_synchronous_ns={} edge_segment_publish_ns={} edge_segment_maintenance_ns={}\n",
        .{
            create_ns,
            add_node_ns,
            perOpNs(add_node_ns, node_count),
            node_texts_pre_edge_compress_ns,
            add_edge_ns,
            perOpNs(add_edge_ns, edge_count),
            add_edge_total_ns,
            perOpNs(add_edge_total_ns, edge_count),
            edge_segment_synchronous_ns,
            edge_delta_stats.segment_publish_ns,
            edge_delta_stats.segment_maintenance_ns,
        },
    );
    try out.print(
        "lookup_ns={}\nlookup_view_open_ns={} lookup_view_open_meta_ns={} lookup_view_open_delta_header_ns={} lookup_view_open_manifest_ns={} lookup_view_open_base_open_ns={} lookup_view_open_validate_ns={} lookup_view_open_delta_open_ns={} lookup_view_open_runs_open_ns={} lookup_ids_retained_ns={} lookup_ids_retained_hot_ns={} lookup_ids_public_ns={} lookup_base_public_ns={}\n",
        .{
            lookup_ns,
            lookup_view_open_ns,
            lookup_open_timing_breakdown.meta_ns,
            lookup_open_timing_breakdown.delta_header_ns,
            lookup_open_timing_breakdown.manifest_ns,
            lookup_open_timing_breakdown.base_open_ns,
            lookup_open_timing_breakdown.validate_ns,
            lookup_open_timing_breakdown.delta_open_ns,
            lookup_open_timing_breakdown.runs_open_ns,
            lookup_ids_retained_ns,
            lookup_ids_retained_hot_ns,
            lookup_ids_public_ns,
            lookup_base_public_ns,
        },
    );
    try out.print(
        "lookup_first_public_ns={} lookup_base_first_public_ns={}\n",
        .{
            lookup_first_public_ns,
            lookup_base_first_public_ns,
        },
    );
    try out.print(
        "lookup_lazy_open_meta_ns={} lookup_lazy_open_delta_header_ns={} lookup_lazy_open_manifest_ns={} lookup_lazy_open_base_ns={} lookup_lazy_open_validate_ns={} lookup_lazy_open_delta_ns={} lookup_lazy_open_runs_ns={}\nlookup_lazy_search_texts_view_ns={} lookup_lazy_search_node_view_ns={} lookup_lazy_hash_ns={} lookup_lazy_lower_bound_ns={} lookup_lazy_lower_bound_probe_count={} lookup_lazy_scan_ns={} lookup_lazy_scan_record_count={} lookup_lazy_span_view_ns={} lookup_lazy_record_decode_ns={} lookup_lazy_text_view_ns={} lookup_lazy_text_match_ns={} lookup_lazy_text_compare_ns={} lookup_lazy_by_id_validate_ns={} lookup_materialize_ns={} lookup_lazy_run_count={} lookup_lazy_range_skip_count={}\n",
        .{
            lookup_full_timing_breakdown.lazy_open_meta_ns,
            lookup_full_timing_breakdown.lazy_open_delta_header_ns,
            lookup_full_timing_breakdown.lazy_open_manifest_ns,
            lookup_full_timing_breakdown.lazy_open_base_ns,
            lookup_full_timing_breakdown.lazy_open_validate_ns,
            lookup_full_timing_breakdown.lazy_open_delta_ns,
            lookup_full_timing_breakdown.lazy_open_runs_ns,
            lookup_full_timing_breakdown.search_texts_view_ns,
            lookup_full_timing_breakdown.search_node_view_ns,
            lookup_full_timing_breakdown.hash_ns,
            lookup_full_timing_breakdown.lower_bound_ns,
            lookup_full_timing_breakdown.lower_bound_probe_count,
            lookup_full_timing_breakdown.scan_ns,
            lookup_full_timing_breakdown.scan_record_count,
            lookup_full_timing_breakdown.span_view_ns,
            lookup_full_timing_breakdown.record_decode_ns,
            lookup_full_timing_breakdown.text_view_ns,
            lookup_full_timing_breakdown.text_match_ns,
            lookup_full_timing_breakdown.text_compare_ns,
            lookup_full_timing_breakdown.by_id_validate_ns,
            lookup_full_timing_breakdown.materialize_ns,
            lookup_full_timing_breakdown.run_count,
            lookup_full_timing_breakdown.range_skip_count,
        },
    );
    try out.print(
        "lookup_search_texts_view_ns={} lookup_search_node_view_ns={} lookup_lower_bound_ns={} lookup_lower_bound_probe_count={} lookup_scan_ns={} lookup_scan_record_count={} lookup_span_view_ns={} lookup_record_decode_ns={} lookup_text_view_ns={} lookup_text_match_ns={} lookup_text_compare_ns={} lookup_by_id_validate_ns={} lookup_run_count={} lookup_range_skip_count={}\n",
        .{
            lookup_timing_breakdown.search_texts_view_ns,
            lookup_timing_breakdown.search_node_view_ns,
            lookup_timing_breakdown.lower_bound_ns,
            lookup_timing_breakdown.lower_bound_probe_count,
            lookup_timing_breakdown.scan_ns,
            lookup_timing_breakdown.scan_record_count,
            lookup_timing_breakdown.span_view_ns,
            lookup_timing_breakdown.record_decode_ns,
            lookup_timing_breakdown.text_view_ns,
            lookup_timing_breakdown.text_match_ns,
            lookup_timing_breakdown.text_compare_ns,
            lookup_timing_breakdown.by_id_validate_ns,
            lookup_timing_breakdown.run_count,
            lookup_timing_breakdown.range_skip_count,
        },
    );
    try out.print(
        "lookup_ids_public_lazy_open_meta_ns={} lookup_ids_public_lazy_open_delta_header_ns={} lookup_ids_public_lazy_open_manifest_ns={} lookup_ids_public_lazy_open_base_ns={} lookup_ids_public_lazy_open_validate_ns={} lookup_ids_public_lazy_open_delta_ns={} lookup_ids_public_lazy_open_runs_ns={}\nlookup_ids_public_search_texts_view_ns={} lookup_ids_public_search_node_view_ns={} lookup_ids_public_lower_bound_ns={} lookup_ids_public_lower_bound_probe_count={} lookup_ids_public_scan_ns={} lookup_ids_public_scan_record_count={} lookup_ids_public_span_view_ns={} lookup_ids_public_record_decode_ns={} lookup_ids_public_text_view_ns={} lookup_ids_public_text_match_ns={} lookup_ids_public_text_compare_ns={} lookup_ids_public_by_id_validate_ns={} lookup_ids_public_run_count={} lookup_ids_public_range_skip_count={}\n",
        .{
            lookup_ids_public_timing_breakdown.lazy_open_meta_ns,
            lookup_ids_public_timing_breakdown.lazy_open_delta_header_ns,
            lookup_ids_public_timing_breakdown.lazy_open_manifest_ns,
            lookup_ids_public_timing_breakdown.lazy_open_base_ns,
            lookup_ids_public_timing_breakdown.lazy_open_validate_ns,
            lookup_ids_public_timing_breakdown.lazy_open_delta_ns,
            lookup_ids_public_timing_breakdown.lazy_open_runs_ns,
            lookup_ids_public_timing_breakdown.search_texts_view_ns,
            lookup_ids_public_timing_breakdown.search_node_view_ns,
            lookup_ids_public_timing_breakdown.lower_bound_ns,
            lookup_ids_public_timing_breakdown.lower_bound_probe_count,
            lookup_ids_public_timing_breakdown.scan_ns,
            lookup_ids_public_timing_breakdown.scan_record_count,
            lookup_ids_public_timing_breakdown.span_view_ns,
            lookup_ids_public_timing_breakdown.record_decode_ns,
            lookup_ids_public_timing_breakdown.text_view_ns,
            lookup_ids_public_timing_breakdown.text_match_ns,
            lookup_ids_public_timing_breakdown.text_compare_ns,
            lookup_ids_public_timing_breakdown.by_id_validate_ns,
            lookup_ids_public_timing_breakdown.run_count,
            lookup_ids_public_timing_breakdown.range_skip_count,
        },
    );
    try out.print(
        "lookup_first_public_lazy_open_meta_ns={} lookup_first_public_lazy_open_delta_header_ns={} lookup_first_public_lazy_open_manifest_ns={} lookup_first_public_lazy_open_base_ns={} lookup_first_public_lazy_open_validate_ns={} lookup_first_public_lazy_open_delta_ns={} lookup_first_public_lazy_open_runs_ns={}\nlookup_first_public_search_texts_view_ns={} lookup_first_public_search_node_view_ns={} lookup_first_public_lower_bound_ns={} lookup_first_public_lower_bound_probe_count={} lookup_first_public_scan_ns={} lookup_first_public_scan_record_count={} lookup_first_public_span_view_ns={} lookup_first_public_record_decode_ns={} lookup_first_public_text_view_ns={} lookup_first_public_text_match_ns={} lookup_first_public_text_compare_ns={} lookup_first_public_by_id_validate_ns={} lookup_first_public_run_count={} lookup_first_public_range_skip_count={}\n",
        .{
            lookup_first_public_timing_breakdown.lazy_open_meta_ns,
            lookup_first_public_timing_breakdown.lazy_open_delta_header_ns,
            lookup_first_public_timing_breakdown.lazy_open_manifest_ns,
            lookup_first_public_timing_breakdown.lazy_open_base_ns,
            lookup_first_public_timing_breakdown.lazy_open_validate_ns,
            lookup_first_public_timing_breakdown.lazy_open_delta_ns,
            lookup_first_public_timing_breakdown.lazy_open_runs_ns,
            lookup_first_public_timing_breakdown.search_texts_view_ns,
            lookup_first_public_timing_breakdown.search_node_view_ns,
            lookup_first_public_timing_breakdown.lower_bound_ns,
            lookup_first_public_timing_breakdown.lower_bound_probe_count,
            lookup_first_public_timing_breakdown.scan_ns,
            lookup_first_public_timing_breakdown.scan_record_count,
            lookup_first_public_timing_breakdown.span_view_ns,
            lookup_first_public_timing_breakdown.record_decode_ns,
            lookup_first_public_timing_breakdown.text_view_ns,
            lookup_first_public_timing_breakdown.text_match_ns,
            lookup_first_public_timing_breakdown.text_compare_ns,
            lookup_first_public_timing_breakdown.by_id_validate_ns,
            lookup_first_public_timing_breakdown.run_count,
            lookup_first_public_timing_breakdown.range_skip_count,
        },
    );
    try out.print(
        "lookup_base_public_lazy_open_meta_ns={} lookup_base_public_lazy_open_delta_header_ns={} lookup_base_public_lazy_open_manifest_ns={} lookup_base_public_lazy_open_base_ns={} lookup_base_public_lazy_open_validate_ns={} lookup_base_public_lazy_open_delta_ns={} lookup_base_public_lazy_open_runs_ns={}\nlookup_base_public_search_texts_view_ns={} lookup_base_public_search_node_view_ns={} lookup_base_public_lower_bound_ns={} lookup_base_public_lower_bound_probe_count={} lookup_base_public_scan_ns={} lookup_base_public_scan_record_count={} lookup_base_public_span_view_ns={} lookup_base_public_record_decode_ns={} lookup_base_public_text_view_ns={} lookup_base_public_text_match_ns={} lookup_base_public_text_compare_ns={} lookup_base_public_by_id_validate_ns={} lookup_base_public_run_count={} lookup_base_public_range_skip_count={}\n",
        .{
            lookup_base_public_timing_breakdown.lazy_open_meta_ns,
            lookup_base_public_timing_breakdown.lazy_open_delta_header_ns,
            lookup_base_public_timing_breakdown.lazy_open_manifest_ns,
            lookup_base_public_timing_breakdown.lazy_open_base_ns,
            lookup_base_public_timing_breakdown.lazy_open_validate_ns,
            lookup_base_public_timing_breakdown.lazy_open_delta_ns,
            lookup_base_public_timing_breakdown.lazy_open_runs_ns,
            lookup_base_public_timing_breakdown.search_texts_view_ns,
            lookup_base_public_timing_breakdown.search_node_view_ns,
            lookup_base_public_timing_breakdown.lower_bound_ns,
            lookup_base_public_timing_breakdown.lower_bound_probe_count,
            lookup_base_public_timing_breakdown.scan_ns,
            lookup_base_public_timing_breakdown.scan_record_count,
            lookup_base_public_timing_breakdown.span_view_ns,
            lookup_base_public_timing_breakdown.record_decode_ns,
            lookup_base_public_timing_breakdown.text_view_ns,
            lookup_base_public_timing_breakdown.text_match_ns,
            lookup_base_public_timing_breakdown.text_compare_ns,
            lookup_base_public_timing_breakdown.by_id_validate_ns,
            lookup_base_public_timing_breakdown.run_count,
            lookup_base_public_timing_breakdown.range_skip_count,
        },
    );
    try out.print(
        "lookup_base_first_public_lazy_open_meta_ns={} lookup_base_first_public_lazy_open_delta_header_ns={} lookup_base_first_public_lazy_open_manifest_ns={} lookup_base_first_public_lazy_open_base_ns={} lookup_base_first_public_lazy_open_validate_ns={} lookup_base_first_public_lazy_open_delta_ns={} lookup_base_first_public_lazy_open_runs_ns={}\nlookup_base_first_public_search_texts_view_ns={} lookup_base_first_public_search_node_view_ns={} lookup_base_first_public_lower_bound_ns={} lookup_base_first_public_lower_bound_probe_count={} lookup_base_first_public_scan_ns={} lookup_base_first_public_scan_record_count={} lookup_base_first_public_span_view_ns={} lookup_base_first_public_record_decode_ns={} lookup_base_first_public_text_view_ns={} lookup_base_first_public_text_match_ns={} lookup_base_first_public_text_compare_ns={} lookup_base_first_public_by_id_validate_ns={} lookup_base_first_public_run_count={} lookup_base_first_public_range_skip_count={}\n",
        .{
            lookup_base_first_public_timing_breakdown.lazy_open_meta_ns,
            lookup_base_first_public_timing_breakdown.lazy_open_delta_header_ns,
            lookup_base_first_public_timing_breakdown.lazy_open_manifest_ns,
            lookup_base_first_public_timing_breakdown.lazy_open_base_ns,
            lookup_base_first_public_timing_breakdown.lazy_open_validate_ns,
            lookup_base_first_public_timing_breakdown.lazy_open_delta_ns,
            lookup_base_first_public_timing_breakdown.lazy_open_runs_ns,
            lookup_base_first_public_timing_breakdown.search_texts_view_ns,
            lookup_base_first_public_timing_breakdown.search_node_view_ns,
            lookup_base_first_public_timing_breakdown.lower_bound_ns,
            lookup_base_first_public_timing_breakdown.lower_bound_probe_count,
            lookup_base_first_public_timing_breakdown.scan_ns,
            lookup_base_first_public_timing_breakdown.scan_record_count,
            lookup_base_first_public_timing_breakdown.span_view_ns,
            lookup_base_first_public_timing_breakdown.record_decode_ns,
            lookup_base_first_public_timing_breakdown.text_view_ns,
            lookup_base_first_public_timing_breakdown.text_match_ns,
            lookup_base_first_public_timing_breakdown.text_compare_ns,
            lookup_base_first_public_timing_breakdown.by_id_validate_ns,
            lookup_base_first_public_timing_breakdown.run_count,
            lookup_base_first_public_timing_breakdown.range_skip_count,
        },
    );
    try out.print(
        "neighbors_ns={} neighbors={} nodes_visited={} edges_visited={}\nneighbors_rel_miss_ns={} neighbors_rel_miss={} neighbors_rel_miss_nodes_visited={} neighbors_rel_miss_edges_visited={}\n",
        .{
            neighbors_ns,
            neighbors_len,
            neighbors_nodes_visited,
            neighbors_edges_visited,
            neighbors_rel_miss_ns,
            neighbors_rel_miss_len,
            neighbors_rel_miss_nodes_visited,
            neighbors_rel_miss_edges_visited,
        },
    );
    try out.print(
        "edge_post_load_maintenance_ns={} edge_post_load_maintenance_compactions={}\n",
        .{ edge_post_load_maintenance.ns, edge_post_load_maintenance.compactions },
    );
    try appendBenchPhaseRss(
        &out,
        create_rss,
        add_node_rss,
        add_edge_rss,
        edge_post_load_maintenance_rss,
        query_rss,
        store_deinit_rss,
        open_rss,
        validate_rss,
        repair_rss,
        text_rebuild_rss,
    );
    try appendBenchPhaseStoreBytes(&out, bench_phase_store_bytes);
    try appendBenchOrderedEdgeMetrics(&out, edge_order_bytes, ordered_edge_traversal);
    try appendNodeBatchAppendTimings(&out, node_load_timings, node_batch_timings);
    try appendBenchDensityMetrics(&out, &text_density, total_bytes, text_index_bytes, edge_segments_bytes, node_texts_compression, posting_compression, density_breakdown);
    if (edge_delta_stats_enabled) try appendEdgeDeltaStats(&out, edge_delta_stats);
    try appendRepairTimings(&out, repair_timings);
    try out.print(
        "text_build_search_ns={} text_build_search_prebuilt={} search_ns={} search_hits={}\ntext_code_ns={} text_code_hits={} text_path_ns={} text_path_hits={} text_english_ns={} text_english_hits={}\ntext_cjk_ns={} text_cjk_hits={} text_japanese_ns={} text_japanese_hits={} text_korean_ns={} text_korean_hits={} text_highfreq_ns={} text_highfreq_hits={}\n",
        .{
            text_build_search_ns,
            text_build_search_prebuilt,
            search_ns,
            search_hits,
            text_code.ns,
            text_code.hits,
            text_path.ns,
            text_path.hits,
            text_english.ns,
            text_english.hits,
            text_cjk.ns,
            text_cjk.hits,
            text_japanese.ns,
            text_japanese.hits,
            text_korean.ns,
            text_korean.hits,
            text_highfreq.ns,
            text_highfreq.hits,
        },
    );
    try out.print(
        "text_code_query_terms={} text_code_unique_terms={} text_code_matched_terms={} text_code_postings={} text_code_max_postings={}\ntext_path_query_terms={} text_path_unique_terms={} text_path_matched_terms={} text_path_postings={} text_path_max_postings={}\ntext_english_query_terms={} text_english_unique_terms={} text_english_matched_terms={} text_english_postings={} text_english_max_postings={}\ntext_cjk_query_terms={} text_cjk_unique_terms={} text_cjk_matched_terms={} text_cjk_postings={} text_cjk_max_postings={}\n",
        .{
            text_code.query_terms,
            text_code.unique_terms,
            text_code.matched_terms,
            text_code.postings,
            text_code.max_postings,
            text_path.query_terms,
            text_path.unique_terms,
            text_path.matched_terms,
            text_path.postings,
            text_path.max_postings,
            text_english.query_terms,
            text_english.unique_terms,
            text_english.matched_terms,
            text_english.postings,
            text_english.max_postings,
            text_cjk.query_terms,
            text_cjk.unique_terms,
            text_cjk.matched_terms,
            text_cjk.postings,
            text_cjk.max_postings,
        },
    );
    try out.print(
        "text_japanese_query_terms={} text_japanese_unique_terms={} text_japanese_matched_terms={} text_japanese_postings={} text_japanese_max_postings={}\ntext_korean_query_terms={} text_korean_unique_terms={} text_korean_matched_terms={} text_korean_postings={} text_korean_max_postings={}\ntext_highfreq_query_terms={} text_highfreq_unique_terms={} text_highfreq_matched_terms={} text_highfreq_postings={} text_highfreq_max_postings={}\n",
        .{
            text_japanese.query_terms,
            text_japanese.unique_terms,
            text_japanese.matched_terms,
            text_japanese.postings,
            text_japanese.max_postings,
            text_korean.query_terms,
            text_korean.unique_terms,
            text_korean.matched_terms,
            text_korean.postings,
            text_korean.max_postings,
            text_highfreq.query_terms,
            text_highfreq.unique_terms,
            text_highfreq.matched_terms,
            text_highfreq.postings,
            text_highfreq.max_postings,
        },
    );
    try out.print(
        "lookup_retained_samples={} lookup_retained_p50_ns={} lookup_retained_p95_ns={} lookup_retained_p99_ns={} lookup_retained_max_ns={} lookup_retained_rows_last={}\nlookup_base_retained_samples={} lookup_base_retained_p50_ns={} lookup_base_retained_p95_ns={} lookup_base_retained_p99_ns={} lookup_base_retained_max_ns={} lookup_base_retained_rows_last={} lookup_base_run_count={} lookup_base_lower_bound_probe_count={} lookup_base_range_skip_count={}\n",
        .{
            lookup_retained_samples.len,
            lookup_retained_stats.p50_ns,
            lookup_retained_stats.p95_ns,
            lookup_retained_stats.p99_ns,
            lookup_retained_stats.max_ns,
            lookup_retained_rows_last,
            lookup_base_retained_samples.len,
            lookup_base_retained_stats.p50_ns,
            lookup_base_retained_stats.p95_ns,
            lookup_base_retained_stats.p99_ns,
            lookup_base_retained_stats.max_ns,
            lookup_base_retained_rows_last,
            lookup_base_timing_breakdown.run_count,
            lookup_base_timing_breakdown.lower_bound_probe_count,
            lookup_base_timing_breakdown.range_skip_count,
        },
    );
    try out.print(
        "lookup_ids_public_samples={} lookup_ids_public_p50_ns={} lookup_ids_public_p95_ns={} lookup_ids_public_p99_ns={} lookup_ids_public_max_ns={} lookup_ids_public_open_p95_ns={} lookup_ids_public_body_p95_ns={} lookup_ids_public_lower_bound_p95_ns={} lookup_ids_public_rows_last={}\nlookup_base_public_samples={} lookup_base_public_p50_ns={} lookup_base_public_p95_ns={} lookup_base_public_p99_ns={} lookup_base_public_max_ns={} lookup_base_public_open_p95_ns={} lookup_base_public_body_p95_ns={} lookup_base_public_lower_bound_p95_ns={} lookup_base_public_rows_last={}\n",
        .{
            bench_tinyql_suite_samples,
            lookup_ids_public_samples.stats.p50_ns,
            lookup_ids_public_samples.stats.p95_ns,
            lookup_ids_public_samples.stats.p99_ns,
            lookup_ids_public_samples.stats.max_ns,
            lookup_ids_public_samples.open_stats.p95_ns,
            lookup_ids_public_samples.body_stats.p95_ns,
            lookup_ids_public_samples.lower_bound_stats.p95_ns,
            lookup_ids_public_samples.rows_last,
            bench_tinyql_suite_samples,
            lookup_base_public_samples.stats.p50_ns,
            lookup_base_public_samples.stats.p95_ns,
            lookup_base_public_samples.stats.p99_ns,
            lookup_base_public_samples.stats.max_ns,
            lookup_base_public_samples.open_stats.p95_ns,
            lookup_base_public_samples.body_stats.p95_ns,
            lookup_base_public_samples.lower_bound_stats.p95_ns,
            lookup_base_public_samples.rows_last,
        },
    );
    try out.print(
        "lookup_first_public_samples={} lookup_first_public_p50_ns={} lookup_first_public_p95_ns={} lookup_first_public_p99_ns={} lookup_first_public_max_ns={} lookup_first_public_open_p95_ns={} lookup_first_public_body_p95_ns={} lookup_first_public_lower_bound_p95_ns={} lookup_first_public_rows_last={}\nlookup_base_first_public_samples={} lookup_base_first_public_p50_ns={} lookup_base_first_public_p95_ns={} lookup_base_first_public_p99_ns={} lookup_base_first_public_max_ns={} lookup_base_first_public_open_p95_ns={} lookup_base_first_public_body_p95_ns={} lookup_base_first_public_lower_bound_p95_ns={} lookup_base_first_public_rows_last={}\n",
        .{
            bench_tinyql_suite_samples,
            lookup_first_public_samples.stats.p50_ns,
            lookup_first_public_samples.stats.p95_ns,
            lookup_first_public_samples.stats.p99_ns,
            lookup_first_public_samples.stats.max_ns,
            lookup_first_public_samples.open_stats.p95_ns,
            lookup_first_public_samples.body_stats.p95_ns,
            lookup_first_public_samples.lower_bound_stats.p95_ns,
            lookup_first_public_samples.rows_last,
            bench_tinyql_suite_samples,
            lookup_base_first_public_samples.stats.p50_ns,
            lookup_base_first_public_samples.stats.p95_ns,
            lookup_base_first_public_samples.stats.p99_ns,
            lookup_base_first_public_samples.stats.max_ns,
            lookup_base_first_public_samples.open_stats.p95_ns,
            lookup_base_first_public_samples.body_stats.p95_ns,
            lookup_base_first_public_samples.lower_bound_stats.p95_ns,
            lookup_base_first_public_samples.rows_last,
        },
    );
    try appendPostRepairNodeTextLookupProbe(&out, post_repair_lookup);
    try out.print(
        "tinyql_lookup_ns={} tinyql_lookup_rows={} tinyql_lookup_nodes_visited={} tinyql_lookup_edges_visited={}\ntinyql_text_ns={} tinyql_text_rows={} tinyql_text_nodes_visited={} tinyql_text_edges_visited={}\ntinyql_expand_ns={} tinyql_expand_rows={} tinyql_expand_nodes_visited={} tinyql_expand_edges_visited={}\ntinyql_path_ns={} tinyql_path_rows={} tinyql_path_nodes_visited={} tinyql_path_edges_visited={}\n",
        .{
            tinyql_lookup.ns,
            tinyql_lookup.rows,
            tinyql_lookup.nodes_visited,
            tinyql_lookup.edges_visited,
            tinyql_text.ns,
            tinyql_text.rows,
            tinyql_text.nodes_visited,
            tinyql_text.edges_visited,
            tinyql_expand.ns,
            tinyql_expand.rows,
            tinyql_expand.nodes_visited,
            tinyql_expand.edges_visited,
            tinyql_path_probe.ns,
            tinyql_path_probe.rows,
            tinyql_path_probe.nodes_visited,
            tinyql_path_probe.edges_visited,
        },
    );
    try out.print(
        "tinyql_suite_samples={} tinyql_suite_warmups={}\ntinyql_lookup_p50_ns={} tinyql_lookup_p95_ns={} tinyql_lookup_p99_ns={} tinyql_lookup_max_ns={} tinyql_lookup_rows_last={} tinyql_lookup_nodes_visited_last={} tinyql_lookup_edges_visited_last={}\ntinyql_text_p50_ns={} tinyql_text_p95_ns={} tinyql_text_p99_ns={} tinyql_text_max_ns={} tinyql_text_rows_last={} tinyql_text_nodes_visited_last={} tinyql_text_edges_visited_last={}\ntinyql_expand_p50_ns={} tinyql_expand_p95_ns={} tinyql_expand_p99_ns={} tinyql_expand_max_ns={} tinyql_expand_rows_last={} tinyql_expand_nodes_visited_last={} tinyql_expand_edges_visited_last={}\ntinyql_path_p50_ns={} tinyql_path_p95_ns={} tinyql_path_p99_ns={} tinyql_path_max_ns={} tinyql_path_rows_last={} tinyql_path_nodes_visited_last={} tinyql_path_edges_visited_last={}\n",
        .{
            bench_tinyql_suite_samples,
            bench_tinyql_suite_warmups,
            tinyql_lookup_suite.stats.p50_ns,
            tinyql_lookup_suite.stats.p95_ns,
            tinyql_lookup_suite.stats.p99_ns,
            tinyql_lookup_suite.stats.max_ns,
            tinyql_lookup_suite.rows_last,
            tinyql_lookup_suite.nodes_visited_last,
            tinyql_lookup_suite.edges_visited_last,
            tinyql_text_suite.stats.p50_ns,
            tinyql_text_suite.stats.p95_ns,
            tinyql_text_suite.stats.p99_ns,
            tinyql_text_suite.stats.max_ns,
            tinyql_text_suite.rows_last,
            tinyql_text_suite.nodes_visited_last,
            tinyql_text_suite.edges_visited_last,
            tinyql_expand_suite.stats.p50_ns,
            tinyql_expand_suite.stats.p95_ns,
            tinyql_expand_suite.stats.p99_ns,
            tinyql_expand_suite.stats.max_ns,
            tinyql_expand_suite.rows_last,
            tinyql_expand_suite.nodes_visited_last,
            tinyql_expand_suite.edges_visited_last,
            tinyql_path_suite.stats.p50_ns,
            tinyql_path_suite.stats.p95_ns,
            tinyql_path_suite.stats.p99_ns,
            tinyql_path_suite.stats.max_ns,
            tinyql_path_suite.rows_last,
            tinyql_path_suite.nodes_visited_last,
            tinyql_path_suite.edges_visited_last,
        },
    );
    try out.print(
        "tinyql_context_render_p50_ns={} tinyql_context_render_p95_ns={} tinyql_context_render_p99_ns={} tinyql_context_render_max_ns={} tinyql_context_render_rows_last={} tinyql_context_render_nodes_visited_last={} tinyql_context_render_edges_visited_last={} tinyql_context_render_bytes_last={}\ntinyql_reachable_render_p50_ns={} tinyql_reachable_render_p95_ns={} tinyql_reachable_render_p99_ns={} tinyql_reachable_render_max_ns={} tinyql_reachable_render_rows_last={} tinyql_reachable_render_nodes_visited_last={} tinyql_reachable_render_edges_visited_last={} tinyql_reachable_render_bytes_last={}\ntinyql_text_context_render_p50_ns={} tinyql_text_context_render_p95_ns={} tinyql_text_context_render_p99_ns={} tinyql_text_context_render_max_ns={} tinyql_text_context_render_rows_last={} tinyql_text_context_render_nodes_visited_last={} tinyql_text_context_render_edges_visited_last={} tinyql_text_context_render_bytes_last={}\ntinyql_text_reachable_render_p50_ns={} tinyql_text_reachable_render_p95_ns={} tinyql_text_reachable_render_p99_ns={} tinyql_text_reachable_render_max_ns={} tinyql_text_reachable_render_rows_last={} tinyql_text_reachable_render_nodes_visited_last={} tinyql_text_reachable_render_edges_visited_last={} tinyql_text_reachable_render_bytes_last={}\n",
        .{
            tinyql_context_render_suite.stats.p50_ns,
            tinyql_context_render_suite.stats.p95_ns,
            tinyql_context_render_suite.stats.p99_ns,
            tinyql_context_render_suite.stats.max_ns,
            tinyql_context_render_suite.rows_last,
            tinyql_context_render_suite.nodes_visited_last,
            tinyql_context_render_suite.edges_visited_last,
            tinyql_context_render_suite.render_bytes_last,
            tinyql_reachable_render_suite.stats.p50_ns,
            tinyql_reachable_render_suite.stats.p95_ns,
            tinyql_reachable_render_suite.stats.p99_ns,
            tinyql_reachable_render_suite.stats.max_ns,
            tinyql_reachable_render_suite.rows_last,
            tinyql_reachable_render_suite.nodes_visited_last,
            tinyql_reachable_render_suite.edges_visited_last,
            tinyql_reachable_render_suite.render_bytes_last,
            tinyql_text_context_render_suite.stats.p50_ns,
            tinyql_text_context_render_suite.stats.p95_ns,
            tinyql_text_context_render_suite.stats.p99_ns,
            tinyql_text_context_render_suite.stats.max_ns,
            tinyql_text_context_render_suite.rows_last,
            tinyql_text_context_render_suite.nodes_visited_last,
            tinyql_text_context_render_suite.edges_visited_last,
            tinyql_text_context_render_suite.render_bytes_last,
            tinyql_text_reachable_render_suite.stats.p50_ns,
            tinyql_text_reachable_render_suite.stats.p95_ns,
            tinyql_text_reachable_render_suite.stats.p99_ns,
            tinyql_text_reachable_render_suite.stats.max_ns,
            tinyql_text_reachable_render_suite.rows_last,
            tinyql_text_reachable_render_suite.nodes_visited_last,
            tinyql_text_reachable_render_suite.edges_visited_last,
            tinyql_text_reachable_render_suite.render_bytes_last,
        },
    );
    try out.print(
        "tinyql_text_unreachable_render_p50_ns={} tinyql_text_unreachable_render_p95_ns={} tinyql_text_unreachable_render_p99_ns={} tinyql_text_unreachable_render_max_ns={} tinyql_text_unreachable_render_rows_last={} tinyql_text_unreachable_render_nodes_visited_last={} tinyql_text_unreachable_render_edges_visited_last={} tinyql_text_unreachable_render_bytes_last={}\n",
        .{
            tinyql_text_unreachable_render_suite.stats.p50_ns,
            tinyql_text_unreachable_render_suite.stats.p95_ns,
            tinyql_text_unreachable_render_suite.stats.p99_ns,
            tinyql_text_unreachable_render_suite.stats.max_ns,
            tinyql_text_unreachable_render_suite.rows_last,
            tinyql_text_unreachable_render_suite.nodes_visited_last,
            tinyql_text_unreachable_render_suite.edges_visited_last,
            tinyql_text_unreachable_render_suite.render_bytes_last,
        },
    );
    try out.print(
        "tinyql_path_render_p50_ns={} tinyql_path_render_p95_ns={} tinyql_path_render_p99_ns={} tinyql_path_render_max_ns={} tinyql_path_render_rows_last={} tinyql_path_render_nodes_visited_last={} tinyql_path_render_edges_visited_last={} tinyql_path_render_bytes_last={}\ntinyql_text_path_render_p50_ns={} tinyql_text_path_render_p95_ns={} tinyql_text_path_render_p99_ns={} tinyql_text_path_render_max_ns={} tinyql_text_path_render_rows_last={} tinyql_text_path_render_nodes_visited_last={} tinyql_text_path_render_edges_visited_last={} tinyql_text_path_render_bytes_last={}\n",
        .{
            tinyql_path_render_suite.stats.p50_ns,
            tinyql_path_render_suite.stats.p95_ns,
            tinyql_path_render_suite.stats.p99_ns,
            tinyql_path_render_suite.stats.max_ns,
            tinyql_path_render_suite.rows_last,
            tinyql_path_render_suite.nodes_visited_last,
            tinyql_path_render_suite.edges_visited_last,
            tinyql_path_render_suite.render_bytes_last,
            tinyql_text_path_render_suite.stats.p50_ns,
            tinyql_text_path_render_suite.stats.p95_ns,
            tinyql_text_path_render_suite.stats.p99_ns,
            tinyql_text_path_render_suite.stats.max_ns,
            tinyql_text_path_render_suite.rows_last,
            tinyql_text_path_render_suite.nodes_visited_last,
            tinyql_text_path_render_suite.edges_visited_last,
            tinyql_text_path_render_suite.render_bytes_last,
        },
    );
    try out.print(
        "tinyql_text_mixed_render_p50_ns={} tinyql_text_mixed_render_p95_ns={} tinyql_text_mixed_render_p99_ns={} tinyql_text_mixed_render_max_ns={} tinyql_text_mixed_render_rows_last={} tinyql_text_mixed_render_nodes_visited_last={} tinyql_text_mixed_render_edges_visited_last={} tinyql_text_mixed_render_bytes_last={}\n",
        .{
            tinyql_text_mixed_render_suite.stats.p50_ns,
            tinyql_text_mixed_render_suite.stats.p95_ns,
            tinyql_text_mixed_render_suite.stats.p99_ns,
            tinyql_text_mixed_render_suite.stats.max_ns,
            tinyql_text_mixed_render_suite.rows_last,
            tinyql_text_mixed_render_suite.nodes_visited_last,
            tinyql_text_mixed_render_suite.edges_visited_last,
            tinyql_text_mixed_render_suite.render_bytes_last,
        },
    );
    try out.print(
        "path_ns={} path_nodes={} path_nodes_visited={} path_edges_visited={}\nopen_ns={} validate_ns={} validate_stats_ns={} validate_index_files_ns={} validate_rss_bytes={} validate_current_rss_bytes={} repair_ns={} repair_before_text_rebuild={} repair_final_compress_ns={} repair_rss_bytes={} repair_current_rss_bytes={} text_rebuild_ns={} text_rebuild_pre_search={} text_rebuild_rss_bytes={} text_rebuild_current_rss_bytes={} text_repair_search_ns={} text_repair_search_skipped={} text_stale_search_ns={} text_stale_search_skipped={}\n",
        .{
            path_ns,
            path_nodes_len,
            path_nodes_visited,
            path_edges_visited,
            open_ns,
            validate_ns,
            validate_timings.stats_ns,
            validate_timings.index_files_ns,
            validate_rss_bytes,
            validate_current_rss_bytes,
            repair_ns,
            text_build_search_prebuilt,
            repair_final_compress_ns,
            repair_rss_bytes,
            repair_current_rss_bytes,
            text_rebuild_ns,
            text_build_search_prebuilt,
            text_rebuild_rss_bytes,
            text_rebuild_current_rss_bytes,
            text_repair_search_ns,
            text_repair_search_skipped,
            text_stale_search_ns,
            text_stale_search_skipped,
        },
    );
    try appendValidateTimings(&out, validate_timings);
    try appendTextRebuildTimings(&out, text_rebuild_timings);
    try appendTextRebuildPhaseRss(&out, text_rebuild_phase_rss);
    const store_overhead_bps = try benchStoreOverheadBps(total_bytes, text_density.meaningful_text_bytes, stats_out.edges);
    const no_regression_gate = evaluateBenchNoRegressionGates(
        no_regression_gates,
        search_ns,
        neighbors_ns,
        tinyql_expand_suite.stats.p95_ns,
        tinyql_context_render_suite.stats.p95_ns,
        path_ns,
        store_overhead_bps,
    );
    try appendBenchNoRegressionGateMetrics(
        &out,
        no_regression_gates,
        no_regression_gate,
        search_ns,
        neighbors_ns,
        tinyql_expand_suite.stats.p95_ns,
        tinyql_context_render_suite.stats.p95_ns,
        path_ns,
        store_overhead_bps,
    );
    if (!no_regression_gate.passed()) return core.Error.BudgetExceeded;
    return out.buffer.toOwnedSlice(allocator);
}

fn benchBudgetPhase(err: anyerror, comptime phase_error: anyerror) anyerror {
    return switch (err) {
        core.Error.BudgetExceeded => phase_error,
        else => err,
    };
}

const BenchAgentMixedPlan = struct {
    append_ops: usize,
    node_batch_size: usize,
    node_batch_ops: usize,
    query_every: usize,
};

const bench_agent_mixed_production_plan = BenchAgentMixedPlan{
    .append_ops = 1000,
    .node_batch_size = 8,
    .node_batch_ops = 125,
    .query_every = 10,
};

// Direct boundary tests exercise every phase without turning a contributor's
// local architecture gate into a production-scale benchmark. Release builds
// retain the operator-facing production plan above.
const bench_agent_mixed_test_plan = BenchAgentMixedPlan{
    .append_ops = 20,
    .node_batch_size = 3,
    .node_batch_ops = 4,
    .query_every = 5,
};

const bench_agent_mixed_plan = if (builtin.is_test) bench_agent_mixed_test_plan else bench_agent_mixed_production_plan;

const bench_agent_mixed_append_ops: usize = bench_agent_mixed_plan.append_ops;

const bench_agent_mixed_node_batch_size: usize = bench_agent_mixed_plan.node_batch_size;

const bench_agent_mixed_node_batch_ops: usize = bench_agent_mixed_plan.node_batch_ops;

const bench_agent_mixed_query_every: usize = bench_agent_mixed_plan.query_every;

const bench_agent_mixed_query_ops: usize = bench_agent_mixed_append_ops / bench_agent_mixed_query_every;

const bench_agent_property_shape_digest = "properties-v1-n8-k40-s4-u4-compaction-reopen";
const bench_agent_properties_per_node: usize = 8;
const bench_agent_property_group_count: usize = 5;
const bench_agent_property_keys = [_][]const u8{
    "agent_project",        "agent_workspace",    "agent_role",          "agent_state",
    "agent_revision",       "agent_priority",     "agent_generation",    "agent_budget",
    "memory_profile",       "memory_namespace",   "memory_source",       "memory_lifecycle",
    "memory_epoch",         "memory_rank",        "memory_window",       "memory_score",
    "task_owner",           "task_queue",         "task_phase",          "task_result",
    "task_attempt",         "task_depth",         "task_sequence",       "task_weight",
    "evidence_origin",      "evidence_kind",      "evidence_quality",    "evidence_state",
    "evidence_revision",    "evidence_count",     "evidence_generation", "evidence_score",
    "retrieval_domain",     "retrieval_strategy", "retrieval_language",  "retrieval_state",
    "retrieval_generation", "retrieval_limit",    "retrieval_window",    "retrieval_score",
};

comptime {
    std.debug.assert(bench_agent_property_keys.len == bench_agent_properties_per_node * bench_agent_property_group_count);
}

const BenchAgentPropertyKey = struct {
    name: []const u8,
    natural_index: usize,
    hash: u64,
};

const BenchAgentPropertyStream = struct {
    node_count: u64,
    keys: [bench_agent_property_keys.len]BenchAgentPropertyKey,
    key_position: usize = 0,
    next_node_id: u64 = 0,
    value_buffer: [128]u8 = undefined,

    fn init(node_count: usize) !BenchAgentPropertyStream {
        var stream = BenchAgentPropertyStream{
            .node_count = std.math.cast(u64, node_count) orelse return error.RecordTooLarge,
            .keys = undefined,
        };
        for (bench_agent_property_keys, 0..) |name, natural_index| stream.keys[natural_index] = .{
            .name = name,
            .natural_index = natural_index,
            .hash = storage.propertyKeyHashForLookup(name),
        };
        std.mem.sort(BenchAgentPropertyKey, &stream.keys, {}, struct {
            fn lessThan(_: void, a: BenchAgentPropertyKey, b: BenchAgentPropertyKey) bool {
                return a.hash < b.hash;
            }
        }.lessThan);
        for (stream.keys[1..], stream.keys[0 .. stream.keys.len - 1]) |current, previous| {
            if (current.hash == previous.hash) return error.InvalidRecord;
        }
        return stream;
    }

    fn restart(raw_context: *anyopaque) anyerror!void {
        const self: *BenchAgentPropertyStream = @ptrCast(@alignCast(raw_context));
        self.key_position = 0;
        self.next_node_id = 0;
    }

    fn next(raw_context: *anyopaque) anyerror!?storage.SortedPropertyPayloadEntry {
        const self: *BenchAgentPropertyStream = @ptrCast(@alignCast(raw_context));
        while (self.key_position < self.keys.len) {
            const key = self.keys[self.key_position];
            const group = key.natural_index / bench_agent_properties_per_node;
            if (self.next_node_id == 0) self.next_node_id = group + 1;
            if (self.next_node_id <= self.node_count) {
                const node_id = self.next_node_id;
                self.next_node_id += bench_agent_property_group_count;
                return .{
                    .owner = .{ .node = .fromInt(node_id) },
                    .key_hash = key.hash,
                    .value = try benchAgentPropertyValue(&self.value_buffer, key.natural_index, node_id),
                };
            }
            self.key_position += 1;
            self.next_node_id = 0;
        }
        return null;
    }
};

fn benchAgentPropertyKeyIndex(node_id: u64, slot: usize) usize {
    std.debug.assert(node_id != 0 and slot < bench_agent_properties_per_node);
    const group: usize = @intCast((node_id - 1) % bench_agent_property_group_count);
    return group * bench_agent_properties_per_node + slot;
}

fn benchAgentPropertyValue(buffer: *[128]u8, key_index: usize, node_id: u64) !storage.PropertyPayloadValue {
    return if (key_index % 2 == 0)
        .{ .string = try std.fmt.bufPrint(buffer, "agent-memory:workspace-{d}:state-{d}:owner-class-{d}", .{
            node_id % 64,
            node_id % 7,
            (node_id + key_index) % 13,
        }) }
    else
        .{ .uint = (node_id % 4096) * 64 + key_index };
}

fn writeBenchAgentPropertiesForNodes(
    allocator: std.mem.Allocator,
    store: storage.Store,
    first_node_id: u64,
    node_count: usize,
) !void {
    var writes: [bench_agent_properties_per_node * bench_agent_mixed_node_batch_size]storage.PropertyPayloadWrite = undefined;
    var value_buffers: [bench_agent_properties_per_node * bench_agent_mixed_node_batch_size][128]u8 = undefined;
    if (node_count > bench_agent_mixed_node_batch_size) return error.InvalidRecord;
    var write_count: usize = 0;
    for (0..node_count) |node_offset| {
        const node_id = first_node_id + node_offset;
        for (0..bench_agent_properties_per_node) |slot| {
            const key_index = benchAgentPropertyKeyIndex(node_id, slot);
            writes[write_count] = .{
                .owner = .{ .node = .fromInt(node_id) },
                .key = bench_agent_property_keys[key_index],
                .value = try benchAgentPropertyValue(&value_buffers[write_count], key_index, node_id),
            };
            write_count += 1;
        }
    }
    const result = try store.upsertPropertiesBatch(allocator, writes[0..write_count]);
    if (result.writes_applied != write_count or result.payload_publish_count != 1) return error.InvalidRecord;
}

fn probeBenchAgentProperty(
    allocator: std.mem.Allocator,
    store: storage.Store,
    node_id: u64,
    slot: usize,
) !void {
    const key_index = benchAgentPropertyKeyIndex(node_id, slot);
    const key = bench_agent_property_keys[key_index];
    var expected_buffer: [128]u8 = undefined;
    const expected = try benchAgentPropertyValue(&expected_buffer, key_index, node_id);
    switch (expected) {
        .string => |expected_value| {
            const actual = (try store.getNodeStringProperty(allocator, .fromInt(node_id), key)) orelse return error.InvalidRecord;
            defer allocator.free(actual);
            if (!std.mem.eql(u8, actual, expected_value)) return error.InvalidRecord;
        },
        .uint => |expected_value| {
            if ((try store.getUintProperty(allocator, .{ .node = .fromInt(node_id) }, key)) != expected_value) return error.InvalidRecord;
        },
    }
}

const bench_tinyql_suite_samples: usize = 32;

const bench_tinyql_suite_warmups: usize = 1;

const bench_destructive_text_probe_max_nodes: usize = 250_000;

fn benchRunsDestructiveTextRepairProbes(node_count: usize) bool {
    return node_count <= bench_destructive_text_probe_max_nodes;
}

fn benchPrebuildsTextCatalogForSearch(node_count: usize) bool {
    return !benchRunsDestructiveTextRepairProbes(node_count);
}

fn benchGeneratedNodeTextIsLong(node_id: usize, text_source: BenchTextSource) bool {
    if (text_source.corpus) |corpus| {
        if (corpus.records.len != 0) return node_id % 113 == 0;
    }
    return switch (text_source.workload) {
        .synthetic_ring => false,
        .realistic_agent_text => node_id % 64 == 0,
        .realistic_agent_diverse_text => node_id % 97 == 0,
        .metaknow_replay => false,
        .metaknow_replay_shaped => false,
        // long docs come from the audited length percentile curve instead
        .kunshan_shaped_corpus => false,
    };
}

fn benchExactTextLookupNodeId(node_count: usize, text_source: BenchTextSource) !usize {
    if (node_count == 0) return error.InvalidRecord;
    var node_id = node_count;
    while (node_id > 1 and benchGeneratedNodeTextIsLong(node_id, text_source)) {
        node_id -= 1;
    }
    return node_id;
}

const BenchLatencyStats = struct {
    p50_ns: u128,
    p95_ns: u128,
    p99_ns: u128,
    max_ns: u128,
};

const BenchNodeTextLookupProbe = struct {
    lookup_ns: u128 = 0,
    lookup_view_open_ns: u128 = 0,
    lookup_open_timing_breakdown: storage.Store.NodeTextLookupOpenTimings = .{},
    lookup_ids_retained_ns: u128 = 0,
    lookup_ids_retained_hot_ns: u128 = 0,
    lookup_ids_public_ns: u128 = 0,
    lookup_base_public_ns: u128 = 0,
    lookup_ids_public_timing_breakdown: storage.Store.NodeTextLookupTimings = .{},
    lookup_base_public_timing_breakdown: storage.Store.NodeTextLookupTimings = .{},
    lookup_first_public_ns: u128 = 0,
    lookup_base_first_public_ns: u128 = 0,
    lookup_first_public_timing_breakdown: storage.Store.NodeTextLookupTimings = .{},
    lookup_base_first_public_timing_breakdown: storage.Store.NodeTextLookupTimings = .{},
    lookup_ids_public_stats: BenchLatencyStats = .{ .p50_ns = 0, .p95_ns = 0, .p99_ns = 0, .max_ns = 0 },
    lookup_ids_public_open_stats: BenchLatencyStats = .{ .p50_ns = 0, .p95_ns = 0, .p99_ns = 0, .max_ns = 0 },
    lookup_ids_public_body_stats: BenchLatencyStats = .{ .p50_ns = 0, .p95_ns = 0, .p99_ns = 0, .max_ns = 0 },
    lookup_ids_public_lower_bound_stats: BenchLatencyStats = .{ .p50_ns = 0, .p95_ns = 0, .p99_ns = 0, .max_ns = 0 },
    lookup_ids_public_rows_last: usize = 0,
    lookup_first_public_stats: BenchLatencyStats = .{ .p50_ns = 0, .p95_ns = 0, .p99_ns = 0, .max_ns = 0 },
    lookup_first_public_open_stats: BenchLatencyStats = .{ .p50_ns = 0, .p95_ns = 0, .p99_ns = 0, .max_ns = 0 },
    lookup_first_public_body_stats: BenchLatencyStats = .{ .p50_ns = 0, .p95_ns = 0, .p99_ns = 0, .max_ns = 0 },
    lookup_first_public_lower_bound_stats: BenchLatencyStats = .{ .p50_ns = 0, .p95_ns = 0, .p99_ns = 0, .max_ns = 0 },
    lookup_first_public_rows_last: usize = 0,
    lookup_base_public_stats: BenchLatencyStats = .{ .p50_ns = 0, .p95_ns = 0, .p99_ns = 0, .max_ns = 0 },
    lookup_base_public_open_stats: BenchLatencyStats = .{ .p50_ns = 0, .p95_ns = 0, .p99_ns = 0, .max_ns = 0 },
    lookup_base_public_body_stats: BenchLatencyStats = .{ .p50_ns = 0, .p95_ns = 0, .p99_ns = 0, .max_ns = 0 },
    lookup_base_public_lower_bound_stats: BenchLatencyStats = .{ .p50_ns = 0, .p95_ns = 0, .p99_ns = 0, .max_ns = 0 },
    lookup_base_public_rows_last: usize = 0,
    lookup_base_first_public_stats: BenchLatencyStats = .{ .p50_ns = 0, .p95_ns = 0, .p99_ns = 0, .max_ns = 0 },
    lookup_base_first_public_open_stats: BenchLatencyStats = .{ .p50_ns = 0, .p95_ns = 0, .p99_ns = 0, .max_ns = 0 },
    lookup_base_first_public_body_stats: BenchLatencyStats = .{ .p50_ns = 0, .p95_ns = 0, .p99_ns = 0, .max_ns = 0 },
    lookup_base_first_public_lower_bound_stats: BenchLatencyStats = .{ .p50_ns = 0, .p95_ns = 0, .p99_ns = 0, .max_ns = 0 },
    lookup_base_first_public_rows_last: usize = 0,
    lookup_full_timing_breakdown: storage.Store.NodeTextLookupTimings = .{},
    lookup_timing_breakdown: storage.Store.NodeTextLookupTimings = .{},
    lookup_retained_stats: BenchLatencyStats = .{ .p50_ns = 0, .p95_ns = 0, .p99_ns = 0, .max_ns = 0 },
    lookup_retained_rows_last: usize = 0,
    lookup_base_timing_breakdown: storage.Store.NodeTextLookupTimings = .{},
    lookup_base_retained_stats: BenchLatencyStats = .{ .p50_ns = 0, .p95_ns = 0, .p99_ns = 0, .max_ns = 0 },
    lookup_base_retained_rows_last: usize = 0,
};

fn benchNodeTextLookupProbe(
    allocator: std.mem.Allocator,
    io: std.Io,
    store: storage.Store,
    lookup_text: []const u8,
    lookup_base_text: []const u8,
) !BenchNodeTextLookupProbe {
    var probe = BenchNodeTextLookupProbe{};

    const lookup_start = monotonicNs(io);
    var matches = try store.lookupNodesByTextLimitedWithTimings(allocator, .file, lookup_text, 1, &probe.lookup_full_timing_breakdown);
    probe.lookup_ns = elapsedNs(io, lookup_start);
    if (matches.items.len != 1) {
        for (matches.items) |*node| node.deinit(allocator);
        matches.deinit(allocator);
        return error.InvalidRecord;
    }
    for (matches.items) |*node| node.deinit(allocator);
    matches.deinit(allocator);

    const lookup_view_open_start = monotonicNs(io);
    var lookup_view = try store.openNodeTextLookupViewWithTimings(allocator, &probe.lookup_open_timing_breakdown);
    probe.lookup_view_open_ns = elapsedNs(io, lookup_view_open_start);
    defer lookup_view.deinit();

    const lookup_ids_retained_start = monotonicNs(io);
    var lookup_ids_retained = try lookup_view.lookupIdsWithTimings(allocator, .file, lookup_text, 1, &probe.lookup_timing_breakdown);
    probe.lookup_ids_retained_ns = elapsedNs(io, lookup_ids_retained_start);
    if (lookup_ids_retained.items.len != 1) {
        lookup_ids_retained.deinit(allocator);
        return error.InvalidRecord;
    }
    lookup_ids_retained.deinit(allocator);

    const lookup_ids_retained_hot_start = monotonicNs(io);
    var lookup_ids_retained_hot = try lookup_view.lookupIds(allocator, .file, lookup_text, 1);
    probe.lookup_ids_retained_hot_ns = elapsedNs(io, lookup_ids_retained_hot_start);
    if (lookup_ids_retained_hot.items.len != 1) {
        lookup_ids_retained_hot.deinit(allocator);
        return error.InvalidRecord;
    }
    lookup_ids_retained_hot.deinit(allocator);

    var lookup_retained_samples: [bench_tinyql_suite_samples]u128 = undefined;
    for (&lookup_retained_samples) |*sample| {
        const sample_start = monotonicNs(io);
        var lookup_retained = try lookup_view.lookupIds(allocator, .file, lookup_text, 1);
        sample.* = elapsedNs(io, sample_start);
        if (lookup_retained.items.len != 1) {
            lookup_retained.deinit(allocator);
            return error.InvalidRecord;
        }
        probe.lookup_retained_rows_last = lookup_retained.items.len;
        lookup_retained.deinit(allocator);
    }
    probe.lookup_retained_stats = latencyStats(&lookup_retained_samples);

    const lookup_base_first = try lookup_view.lookupFirstIdWithTimings(.file, lookup_base_text, &probe.lookup_base_timing_breakdown);
    if (lookup_base_first == null or lookup_base_first.?.toInt() != 1) return error.InvalidRecord;
    var lookup_base_retained_samples: [bench_tinyql_suite_samples]u128 = undefined;
    for (&lookup_base_retained_samples) |*sample| {
        const sample_start = monotonicNs(io);
        const base_id = try lookup_view.lookupFirstId(.file, lookup_base_text);
        sample.* = elapsedNs(io, sample_start);
        if (base_id == null or base_id.?.toInt() != 1) return error.InvalidRecord;
        probe.lookup_base_retained_rows_last = 1;
    }
    probe.lookup_base_retained_stats = latencyStats(&lookup_base_retained_samples);

    const lookup_ids_public_start = monotonicNs(io);
    var lookup_ids_public = try store.lookupNodeIdsByTextLimitedWithTimings(allocator, .file, lookup_text, 1, &probe.lookup_ids_public_timing_breakdown);
    probe.lookup_ids_public_ns = elapsedNs(io, lookup_ids_public_start);
    if (lookup_ids_public.items.len != 1) {
        lookup_ids_public.deinit(allocator);
        return error.InvalidRecord;
    }
    lookup_ids_public.deinit(allocator);

    const lookup_base_public_start = monotonicNs(io);
    var lookup_base_public = try store.lookupNodeIdsByTextLimitedWithTimings(allocator, .file, lookup_base_text, 1, &probe.lookup_base_public_timing_breakdown);
    probe.lookup_base_public_ns = elapsedNs(io, lookup_base_public_start);
    if (lookup_base_public.items.len != 1 or lookup_base_public.items[0].toInt() != 1) {
        lookup_base_public.deinit(allocator);
        return error.InvalidRecord;
    }
    lookup_base_public.deinit(allocator);

    const lookup_first_public_start = monotonicNs(io);
    const lookup_first_public = try store.lookupFirstNodeIdByTextWithTimings(allocator, .file, lookup_text, &probe.lookup_first_public_timing_breakdown);
    probe.lookup_first_public_ns = elapsedNs(io, lookup_first_public_start);
    if (lookup_first_public == null) return error.InvalidRecord;

    const lookup_base_first_public_start = monotonicNs(io);
    const lookup_base_first_public = try store.lookupFirstNodeIdByTextWithTimings(allocator, .file, lookup_base_text, &probe.lookup_base_first_public_timing_breakdown);
    probe.lookup_base_first_public_ns = elapsedNs(io, lookup_base_first_public_start);
    if (lookup_base_first_public == null or lookup_base_first_public.?.toInt() != 1) return error.InvalidRecord;

    const lookup_ids_public_samples = try benchPublicNodeTextIdLookupSamples(allocator, io, store, .file, lookup_text, null);
    probe.lookup_ids_public_stats = lookup_ids_public_samples.stats;
    probe.lookup_ids_public_open_stats = lookup_ids_public_samples.open_stats;
    probe.lookup_ids_public_body_stats = lookup_ids_public_samples.body_stats;
    probe.lookup_ids_public_lower_bound_stats = lookup_ids_public_samples.lower_bound_stats;
    probe.lookup_ids_public_rows_last = lookup_ids_public_samples.rows_last;
    const lookup_first_public_samples = try benchPublicNodeTextFirstIdLookupSamples(allocator, io, store, .file, lookup_text, null);
    probe.lookup_first_public_stats = lookup_first_public_samples.stats;
    probe.lookup_first_public_open_stats = lookup_first_public_samples.open_stats;
    probe.lookup_first_public_body_stats = lookup_first_public_samples.body_stats;
    probe.lookup_first_public_lower_bound_stats = lookup_first_public_samples.lower_bound_stats;
    probe.lookup_first_public_rows_last = lookup_first_public_samples.rows_last;
    const lookup_base_public_samples = try benchPublicNodeTextIdLookupSamples(allocator, io, store, .file, lookup_base_text, 1);
    probe.lookup_base_public_stats = lookup_base_public_samples.stats;
    probe.lookup_base_public_open_stats = lookup_base_public_samples.open_stats;
    probe.lookup_base_public_body_stats = lookup_base_public_samples.body_stats;
    probe.lookup_base_public_lower_bound_stats = lookup_base_public_samples.lower_bound_stats;
    probe.lookup_base_public_rows_last = lookup_base_public_samples.rows_last;
    const lookup_base_first_public_samples = try benchPublicNodeTextFirstIdLookupSamples(allocator, io, store, .file, lookup_base_text, 1);
    probe.lookup_base_first_public_stats = lookup_base_first_public_samples.stats;
    probe.lookup_base_first_public_open_stats = lookup_base_first_public_samples.open_stats;
    probe.lookup_base_first_public_body_stats = lookup_base_first_public_samples.body_stats;
    probe.lookup_base_first_public_lower_bound_stats = lookup_base_first_public_samples.lower_bound_stats;
    probe.lookup_base_first_public_rows_last = lookup_base_first_public_samples.rows_last;

    return probe;
}

const BenchPublicNodeTextLookupSamples = struct {
    stats: BenchLatencyStats,
    open_stats: BenchLatencyStats,
    body_stats: BenchLatencyStats,
    lower_bound_stats: BenchLatencyStats,
    rows_last: usize,
};

fn nodeTextLookupOpenTimingNs(timings: storage.Store.NodeTextLookupTimings) u128 {
    return timings.lazy_open_meta_ns +
        timings.lazy_open_delta_header_ns +
        timings.lazy_open_manifest_ns +
        timings.lazy_open_base_ns +
        timings.lazy_open_validate_ns +
        timings.lazy_open_delta_ns +
        timings.lazy_open_runs_ns;
}

fn nodeTextLookupBodyTimingNs(timings: storage.Store.NodeTextLookupTimings) u128 {
    return timings.search_texts_view_ns +
        timings.search_node_view_ns +
        timings.hash_ns +
        timings.lower_bound_ns +
        timings.scan_ns +
        timings.span_view_ns +
        timings.record_decode_ns +
        timings.text_view_ns +
        timings.text_match_ns +
        timings.text_compare_ns +
        timings.by_id_validate_ns +
        timings.materialize_ns;
}

fn benchPublicNodeTextIdLookupSamples(
    allocator: std.mem.Allocator,
    io: std.Io,
    store: storage.Store,
    kind_filter: ?core.NodeKind,
    text: []const u8,
    expected_id: ?u64,
) !BenchPublicNodeTextLookupSamples {
    var samples: [bench_tinyql_suite_samples]u128 = undefined;
    var open_samples: [bench_tinyql_suite_samples]u128 = undefined;
    var body_samples: [bench_tinyql_suite_samples]u128 = undefined;
    var lower_bound_samples: [bench_tinyql_suite_samples]u128 = undefined;
    var rows_last: usize = 0;
    for (&samples) |*sample| {
        const sample_start = monotonicNs(io);
        var ids = try store.lookupNodeIdsByTextLimited(allocator, kind_filter, text, 1);
        sample.* = elapsedNs(io, sample_start);
        if (expected_id) |id| {
            if (ids.items.len != 1 or ids.items[0].toInt() != id) {
                ids.deinit(allocator);
                return error.InvalidRecord;
            }
        } else if (ids.items.len != 1) {
            ids.deinit(allocator);
            return error.InvalidRecord;
        }
        rows_last = ids.items.len;
        ids.deinit(allocator);
    }
    for (&open_samples, &body_samples, &lower_bound_samples) |*open_sample, *body_sample, *lower_bound_sample| {
        var timings = storage.Store.NodeTextLookupTimings{};
        var ids = try store.lookupNodeIdsByTextLimitedWithTimings(allocator, kind_filter, text, 1, &timings);
        open_sample.* = nodeTextLookupOpenTimingNs(timings);
        body_sample.* = nodeTextLookupBodyTimingNs(timings);
        lower_bound_sample.* = timings.lower_bound_ns;
        if (expected_id) |id| {
            if (ids.items.len != 1 or ids.items[0].toInt() != id) {
                ids.deinit(allocator);
                return error.InvalidRecord;
            }
        } else if (ids.items.len != 1) {
            ids.deinit(allocator);
            return error.InvalidRecord;
        }
        ids.deinit(allocator);
    }
    return .{
        .stats = latencyStats(&samples),
        .open_stats = latencyStats(&open_samples),
        .body_stats = latencyStats(&body_samples),
        .lower_bound_stats = latencyStats(&lower_bound_samples),
        .rows_last = rows_last,
    };
}

fn benchPublicNodeTextFirstIdLookupSamples(
    allocator: std.mem.Allocator,
    io: std.Io,
    store: storage.Store,
    kind_filter: ?core.NodeKind,
    text: []const u8,
    expected_id: ?u64,
) !BenchPublicNodeTextLookupSamples {
    var samples: [bench_tinyql_suite_samples]u128 = undefined;
    var open_samples: [bench_tinyql_suite_samples]u128 = undefined;
    var body_samples: [bench_tinyql_suite_samples]u128 = undefined;
    var lower_bound_samples: [bench_tinyql_suite_samples]u128 = undefined;
    var rows_last: usize = 0;
    for (&samples) |*sample| {
        const sample_start = monotonicNs(io);
        const id = try store.lookupFirstNodeIdByText(allocator, kind_filter, text);
        sample.* = elapsedNs(io, sample_start);
        if (expected_id) |expected| {
            if (id == null or id.?.toInt() != expected) return error.InvalidRecord;
        } else if (id == null) {
            return error.InvalidRecord;
        }
        rows_last = 1;
    }
    for (&open_samples, &body_samples, &lower_bound_samples) |*open_sample, *body_sample, *lower_bound_sample| {
        var timings = storage.Store.NodeTextLookupTimings{};
        const id = try store.lookupFirstNodeIdByTextWithTimings(allocator, kind_filter, text, &timings);
        open_sample.* = nodeTextLookupOpenTimingNs(timings);
        body_sample.* = nodeTextLookupBodyTimingNs(timings);
        lower_bound_sample.* = timings.lower_bound_ns;
        if (expected_id) |expected| {
            if (id == null or id.?.toInt() != expected) return error.InvalidRecord;
        } else if (id == null) {
            return error.InvalidRecord;
        }
    }
    return .{
        .stats = latencyStats(&samples),
        .open_stats = latencyStats(&open_samples),
        .body_stats = latencyStats(&body_samples),
        .lower_bound_stats = latencyStats(&lower_bound_samples),
        .rows_last = rows_last,
    };
}

fn appendEdgeDeltaStats(out: *QueryOutputWriter, stats: storage.EdgeBatchSegmentDeltaStats) !void {
    try out.print(
        "edge_delta_fast_path_batches={} edge_delta_slow_path_batches={} edge_delta_slow_path_sorted_batches={} edge_delta_slow_path_candidate_ids={} edge_segment_publish_batches={} edge_segment_publish_edges={} edge_segment_publish_ns={} edge_segment_publish_manifest_read_ns={} edge_segment_publish_segment_write_ns={} edge_segment_publish_manifest_write_ns={} edge_segment_maintenance_calls={} edge_segment_maintenance_ns={} edge_delta_base_id_checks={} edge_delta_base_id_check_ns={} edge_delta_overlay_checks={} edge_delta_overlay_check_ns={} edge_delta_overlay_entries_considered={} edge_delta_overlay_entries_range_skipped={} edge_delta_overlay_sidecar_checks={} edge_delta_overlay_csr_fallbacks={}\n",
        .{
            stats.fast_path_batches,
            stats.slow_path_batches,
            stats.slow_path_sorted_batches,
            stats.slow_path_candidate_ids,
            stats.segment_publish_batches,
            stats.segment_publish_edges,
            stats.segment_publish_ns,
            stats.segment_publish_manifest_read_ns,
            stats.segment_publish_segment_write_ns,
            stats.segment_publish_manifest_write_ns,
            stats.segment_maintenance_calls,
            stats.segment_maintenance_ns,
            stats.base_id_checks,
            stats.base_id_check_ns,
            stats.overlay_checks,
            stats.overlay_check_ns,
            stats.overlay_entries_considered,
            stats.overlay_entries_range_skipped,
            stats.overlay_sidecar_checks,
            stats.overlay_csr_fallbacks,
        },
    );
}

fn buildOptimizeLabel() []const u8 {
    return switch (builtin.mode) {
        .Debug => "Debug",
        .ReleaseSafe => "ReleaseSafe",
        .ReleaseFast => "ReleaseFast",
        .ReleaseSmall => "ReleaseSmall",
    };
}

fn appendTextRebuildPhaseRss(out: *QueryOutputWriter, samples: BenchTextRebuildPhaseRss) !void {
    try out.print(
        "text_rebuild_phase_docs_progress_max_rss_bytes={} text_rebuild_phase_docs_rss_bytes={} text_rebuild_phase_run_finish_rss_bytes={} text_rebuild_phase_scratch_release_rss_bytes={} text_rebuild_phase_open_docs_rss_bytes={} text_rebuild_phase_catalog_rss_bytes={} text_rebuild_phase_meta_rss_bytes={}\n",
        .{
            samples.docs_progress_max.peak_bytes,
            samples.docs.peak_bytes,
            samples.run_finish.peak_bytes,
            samples.scratch_release.peak_bytes,
            samples.open_docs.peak_bytes,
            samples.catalog.peak_bytes,
            samples.meta.peak_bytes,
        },
    );
    try out.print(
        "text_rebuild_phase_docs_progress_max_current_rss_bytes={} text_rebuild_phase_docs_current_rss_bytes={} text_rebuild_phase_run_finish_current_rss_bytes={} text_rebuild_phase_scratch_release_current_rss_bytes={} text_rebuild_phase_open_docs_current_rss_bytes={} text_rebuild_phase_catalog_current_rss_bytes={} text_rebuild_phase_meta_current_rss_bytes={}\n",
        .{
            samples.docs_progress_max.current_bytes,
            samples.docs.current_bytes,
            samples.run_finish.current_bytes,
            samples.scratch_release.current_bytes,
            samples.open_docs.current_bytes,
            samples.catalog.current_bytes,
            samples.meta.current_bytes,
        },
    );
    try out.print(
        "text_rebuild_phase_docs_progress_max_footprint_bytes={} text_rebuild_phase_docs_footprint_bytes={} text_rebuild_phase_run_finish_footprint_bytes={} text_rebuild_phase_scratch_release_footprint_bytes={} text_rebuild_phase_open_docs_footprint_bytes={} text_rebuild_phase_catalog_footprint_bytes={} text_rebuild_phase_meta_footprint_bytes={}\n",
        .{
            samples.docs_progress_max.footprint_bytes,
            samples.docs.footprint_bytes,
            samples.run_finish.footprint_bytes,
            samples.scratch_release.footprint_bytes,
            samples.open_docs.footprint_bytes,
            samples.catalog.footprint_bytes,
            samples.meta.footprint_bytes,
        },
    );
}

fn appendValidateTimings(out: *QueryOutputWriter, timings: storage.PersistentValidateTimings) !void {
    try out.print(
        "validate_node_index_ns={} validate_node_by_id_scan_ns={} validate_node_by_text_scan_ns={} validate_node_text_delta_scan_ns={} validate_node_text_run_scan_ns={} validate_node_text_meta_ns={} validate_node_text_hash_cache_enabled={} validate_node_text_hash_cache_bytes={} validate_edge_by_id_ns={} validate_edge_by_src_ns={} validate_edge_by_dst_ns={} validate_edge_consistency_ns={} validate_edge_tombstone_ns={} validate_edge_meta_ns={} validate_edge_segment_manifest_read_ns={} validate_edge_segment_open_ns={} validate_edge_segment_digest_ns={}\n",
        .{
            timings.node_index_ns,
            timings.node_by_id_scan_ns,
            timings.node_by_text_scan_ns,
            timings.node_text_delta_scan_ns,
            timings.node_text_run_scan_ns,
            timings.node_text_meta_ns,
            timings.node_text_hash_cache_enabled,
            timings.node_text_hash_cache_bytes,
            timings.edge_by_id_ns,
            timings.edge_by_src_ns,
            timings.edge_by_dst_ns,
            timings.edge_consistency_ns,
            timings.edge_tombstone_ns,
            timings.edge_meta_ns,
            timings.edge_segment_manifest_read_ns,
            timings.edge_segment_open_ns,
            timings.edge_segment_digest_ns,
        },
    );
}

fn appendRepairTimings(out: *QueryOutputWriter, timings: storage.PersistentRepairTimings) !void {
    try out.print(
        "repair_truncate_ns={} repair_rebuild_total_ns={} repair_reuse_attempt_ns={} repair_retry_rebuild_ns={} repair_replay_events_ns={} repair_spool_flush_ns={} repair_node_by_id_finalize_ns={} repair_primary_rename_ns={} repair_node_texts_compress_ns={} repair_node_text_index_ns={} repair_edge_index_ns={} repair_edge_id_index_ns={} repair_edge_src_index_ns={} repair_edge_dst_index_ns={} repair_tombstone_index_ns={} repair_meta_write_ns={} repair_drop_overlay_ns={} repair_reuse_failed={} repair_nodes={} repair_edges={} repair_node_text_records={} repair_edge_records={} repair_tombstone_records={}\n",
        .{
            timings.truncate_ns,
            timings.rebuild_total_ns,
            timings.reuse_attempt_ns,
            timings.retry_rebuild_ns,
            timings.replay_events_ns,
            timings.spool_flush_ns,
            timings.node_by_id_finalize_ns,
            timings.primary_rename_ns,
            timings.node_texts_compress_ns,
            timings.node_text_index_ns,
            timings.edge_index_ns,
            timings.edge_id_index_ns,
            timings.edge_src_index_ns,
            timings.edge_dst_index_ns,
            timings.tombstone_index_ns,
            timings.meta_write_ns,
            timings.drop_overlay_ns,
            timings.reuse_failed,
            timings.nodes,
            timings.edges,
            timings.node_text_records,
            timings.edge_records,
            timings.tombstone_records,
        },
    );
}

fn appendBenchMetaknowReplayStats(
    out: *QueryOutputWriter,
    replay: BenchMetaknowReplayOutputStats,
    edges: BenchMetaknowReplayEdgeStats,
    warm: BenchMetaknowReplayWarmStats,
) !void {
    try out.print(
        "metaknow_replay_nodes_loaded={} metaknow_replay_edges_loaded={} metaknow_replay_nodes_used={} metaknow_replay_edges_used={} metaknow_replay_edges_skipped_missing_endpoint={}\nmetaknow_replay_rel_contains={} metaknow_replay_rel_mentions={} metaknow_replay_rel_depends_on={} metaknow_replay_rel_blocks={} metaknow_replay_rel_evidences={} metaknow_replay_rel_based_on={} metaknow_replay_rel_references={} metaknow_replay_rel_precedes={} metaknow_replay_rel_related_to={} metaknow_replay_rel_other={}\nmetaknow_replay_based_on_materialize_threshold={} metaknow_replay_based_on_materialized_edges={} metaknow_replay_based_on_deferred_edges={} metaknow_replay_based_on_deferred_fragment_count={} metaknow_replay_based_on_document_container_skipped_edges={} metaknow_replay_deferred_based_on_rows={} metaknow_replay_deferred_based_on_bytes={} metaknow_replay_deferred_based_on_binary_sources={} metaknow_replay_deferred_based_on_binary_links={} metaknow_replay_deferred_based_on_binary_bytes={}\n",
        .{
            replay.nodes_loaded,
            replay.edges_loaded,
            replay.nodes_used,
            edges.edges_used,
            edges.edges_skipped_missing_endpoint,
            edges.relation_contains,
            edges.relation_mentions,
            edges.relation_depends_on,
            edges.relation_blocks,
            edges.relation_evidences,
            edges.relation_based_on,
            edges.relation_references,
            edges.relation_precedes,
            edges.relation_related_to,
            edges.relation_other,
            replay.manifest.based_on_materialize_threshold,
            replay.manifest.based_on_materialized_edges,
            replay.manifest.based_on_deferred_edges,
            replay.manifest.based_on_deferred_fragment_count,
            replay.manifest.based_on_document_container_skipped_edges,
            replay.manifest.deferred_based_on_rows,
            replay.manifest.deferred_based_on_bytes,
            edges.deferred_based_on_binary_sources,
            edges.deferred_based_on_binary_links,
            edges.deferred_based_on_binary_bytes,
        },
    );
    try out.print(
        "metaknow_replay_warm_query_enabled={} metaknow_replay_warm_lookup_p95_ns={} metaknow_replay_warm_lookup_rows_last={} metaknow_replay_warm_text_search_p95_ns={} metaknow_replay_warm_text_search_hits_last={} metaknow_replay_warm_text_search_query_bytes={} metaknow_replay_warm_text_search_query_terms={} metaknow_replay_warm_text_search_unique_terms={} metaknow_replay_warm_text_search_matched_terms={} metaknow_replay_warm_text_search_postings={} metaknow_replay_warm_text_search_max_postings={} metaknow_replay_warm_neighbors_p95_ns={} metaknow_replay_warm_neighbors_rows_last={} metaknow_replay_warm_neighbors_edges_visited_last={}\n",
        .{
            @intFromBool(warm.enabled),
            warm.lookup_p95_ns,
            warm.lookup_rows_last,
            warm.text_search_p95_ns,
            warm.text_search_hits_last,
            warm.text_search_query_bytes,
            warm.text_search_query_terms,
            warm.text_search_unique_terms,
            warm.text_search_matched_terms,
            warm.text_search_postings,
            warm.text_search_max_postings,
            warm.neighbors_p95_ns,
            warm.neighbors_rows_last,
            warm.neighbors_edges_visited_last,
        },
    );
    try out.print(
        "metaknow_replay_warm_deferred_based_on_neighbors_p95_ns={} metaknow_replay_warm_deferred_based_on_neighbors_rows_last={}\n",
        .{
            warm.deferred_based_on_neighbors_p95_ns,
            warm.deferred_based_on_neighbors_rows_last,
        },
    );
}

const bench_metaknow_replay_warm_samples: usize = 16;

fn benchMetaknowReplayWarmStats(
    allocator: std.mem.Allocator,
    io: std.Io,
    store: storage.Store,
    replay: *const BenchMetaknowReplay,
    node_count: usize,
    edge_count: usize,
    shaped: bool,
) !BenchMetaknowReplayWarmStats {
    if (node_count == 0 or replay.nodes.len == 0) return .{};
    const lookup_node_id = @min(node_count, replay.nodes.len);
    const lookup_index = benchMetaknowReplayNodeIndexForOrdinal(lookup_node_id, node_count, replay.nodes.len, shaped);
    const lookup_node = replay.nodes[lookup_index];
    var lookup_text_buffer = std.ArrayList(u8).empty;
    defer lookup_text_buffer.deinit(allocator);
    const lookup_text = if (shaped and node_count > replay.nodes.len) text: {
        try appendBenchMetaknowReplayShapedNodeText(allocator, &lookup_text_buffer, lookup_node.text, lookup_node_id, lookup_index);
        break :text lookup_text_buffer.items;
    } else lookup_node.text;
    var text_probe = try benchMetaknowReplayTextProbe(allocator, store, replay, node_count, shaped);
    defer text_probe.deinit(allocator);

    {
        var ids = try store.lookupNodeIdsByTextLimited(allocator, lookup_node.kind, lookup_text, 1);
        defer ids.deinit(allocator);
        const valid = ids.items.len == 1 and (shaped or ids.items[0].toInt() == lookup_node_id);
        if (!valid) return error.InvalidRecord;
    }

    var lookup_samples: [bench_metaknow_replay_warm_samples]u128 = undefined;
    var lookup_rows_last: usize = 0;
    for (&lookup_samples) |*sample| {
        const start = monotonicNs(io);
        var ids = try store.lookupNodeIdsByTextLimited(allocator, lookup_node.kind, lookup_text, 1);
        sample.* = elapsedNs(io, start);
        const valid = ids.items.len == 1 and (shaped or ids.items[0].toInt() == lookup_node_id);
        lookup_rows_last = ids.items.len;
        ids.deinit(allocator);
        if (!valid) return error.InvalidRecord;
    }

    {
        var hits = try text_search.searchText(allocator, store, text_probe.text, .{ .limit = 8 });
        defer hits.deinit(allocator);
        if (hits.items.len == 0) return error.InvalidRecord;
    }

    var text_samples: [bench_metaknow_replay_warm_samples]u128 = undefined;
    var text_hits_last: usize = 0;
    for (&text_samples) |*sample| {
        const start = monotonicNs(io);
        var hits = try text_search.searchText(allocator, store, text_probe.text, .{ .limit = 8 });
        sample.* = elapsedNs(io, start);
        const valid = hits.items.len != 0;
        text_hits_last = hits.items.len;
        hits.deinit(allocator);
        if (!valid) return error.InvalidRecord;
    }

    var warm = BenchMetaknowReplayWarmStats{
        .enabled = true,
        .lookup_p95_ns = latencyStats(&lookup_samples).p95_ns,
        .lookup_rows_last = lookup_rows_last,
        .text_search_p95_ns = latencyStats(&text_samples).p95_ns,
        .text_search_hits_last = text_hits_last,
        .text_search_query_bytes = text_probe.text.len,
        .text_search_query_terms = text_probe.query_terms,
        .text_search_unique_terms = text_probe.unique_terms,
        .text_search_matched_terms = text_probe.matched_terms,
        .text_search_postings = text_probe.postings,
        .text_search_max_postings = text_probe.max_postings,
    };

    if (try firstBenchMetaknowReplayEdgeWithinNodePrefix(allocator, replay, node_count, edge_count)) |edge| {
        {
            var neighbors = try query.neighborsWithPersistentStore(allocator, store, edge.src, edge.rel, .{});
            defer neighbors.deinit(allocator);
            if (neighbors.stats.budget_exceeded) return core.Error.BudgetExceeded;
            if (neighbors.neighbors.items.len == 0) return error.InvalidRecord;
        }

        var neighbor_samples: [bench_metaknow_replay_warm_samples]u128 = undefined;
        var neighbors_rows_last: usize = 0;
        var neighbors_edges_visited_last: u64 = 0;
        for (&neighbor_samples) |*sample| {
            const start = monotonicNs(io);
            var neighbors = try query.neighborsWithPersistentStore(allocator, store, edge.src, edge.rel, .{});
            sample.* = elapsedNs(io, start);
            const budget_exceeded = neighbors.stats.budget_exceeded;
            const valid = neighbors.neighbors.items.len != 0;
            neighbors_rows_last = neighbors.neighbors.items.len;
            neighbors_edges_visited_last = neighbors.stats.edges_visited;
            neighbors.deinit(allocator);
            if (budget_exceeded) return core.Error.BudgetExceeded;
            if (!valid) return error.InvalidRecord;
        }
        warm.neighbors_p95_ns = latencyStats(&neighbor_samples).p95_ns;
        warm.neighbors_rows_last = neighbors_rows_last;
        warm.neighbors_edges_visited_last = neighbors_edges_visited_last;
    }

    if (try firstBenchMetaknowReplayDeferredSource(allocator, replay, node_count)) |source| {
        const path = try metaknowDeferredBasedOnPath(allocator, store);
        defer allocator.free(path);
        {
            var deferred = try query.readMetaknowDeferredBasedOnTargets(allocator, io, path, source, (core.QueryBudget{}).max_results, .forward);
            defer deferred.deinit(allocator);
            if (deferred.targets.len == 0 or deferred.total_count > (core.QueryBudget{}).max_results) return error.InvalidRecord;
        }

        var deferred_samples: [bench_metaknow_replay_warm_samples]u128 = undefined;
        var deferred_rows_last: usize = 0;
        for (&deferred_samples) |*sample| {
            const start = monotonicNs(io);
            var deferred = try query.readMetaknowDeferredBasedOnTargets(allocator, io, path, source, (core.QueryBudget{}).max_results, .forward);
            sample.* = elapsedNs(io, start);
            const valid = deferred.targets.len != 0 and deferred.total_count <= (core.QueryBudget{}).max_results;
            deferred_rows_last = deferred.targets.len;
            deferred.deinit(allocator);
            if (!valid) return error.InvalidRecord;
        }
        warm.deferred_based_on_neighbors_p95_ns = latencyStats(&deferred_samples).p95_ns;
        warm.deferred_based_on_neighbors_rows_last = deferred_rows_last;
    }

    return warm;
}

const BenchMetaknowReplayTextProbe = struct {
    text: []const u8,
    owned_text: ?[]u8 = null,
    query_terms: usize,
    unique_terms: usize,
    matched_terms: usize,
    postings: u64,
    max_postings: u64,

    fn deinit(self: BenchMetaknowReplayTextProbe, allocator: std.mem.Allocator) void {
        if (self.owned_text) |text| allocator.free(text);
    }
};

fn benchMetaknowReplayTextProbe(
    allocator: std.mem.Allocator,
    store: storage.Store,
    replay: *const BenchMetaknowReplay,
    node_count: usize,
    shaped: bool,
) !BenchMetaknowReplayTextProbe {
    const max_probe_len: usize = 64;
    const node_limit = @min(node_count, replay.nodes.len);
    var structural_fallback: ?BenchMetaknowReplayTextProbe = null;

    for (replay.nodes[0..node_limit], 0..) |node, index| {
        const node_ordinal = index + 1;
        var shaped_text_buffer = std.ArrayList(u8).empty;
        defer shaped_text_buffer.deinit(allocator);
        const probe_text = if (shaped and node_count > replay.nodes.len) text: {
            try appendBenchMetaknowReplayShapedNodeText(allocator, &shaped_text_buffer, node.text, node_ordinal, index);
            break :text shaped_text_buffer.items;
        } else node.text;

        var start: ?usize = null;
        for (probe_text, 0..) |byte, i| {
            const is_word = std.ascii.isAlphabetic(byte);
            if (is_word) {
                if (start == null) start = i;
                continue;
            }
            if (start) |s| {
                if (i - s >= 3) {
                    const candidate = probe_text[s..@min(i, s + max_probe_len)];
                    const structural = benchMetaknowReplayProbeTermIsStructural(probe_text, s, i);
                    var probe = try benchMetaknowReplayProbePlan(allocator, store, candidate);
                    if (probe.matched_terms != 0) {
                        if (structural) {
                            if (structural_fallback == null) {
                                structural_fallback = probe;
                            } else {
                                probe.deinit(allocator);
                            }
                        } else {
                            if (structural_fallback) |fallback| fallback.deinit(allocator);
                            return probe;
                        }
                    } else {
                        probe.deinit(allocator);
                    }
                }
                start = null;
            }
        }
        if (start) |s| {
            if (probe_text.len - s >= 3) {
                const candidate = probe_text[s..@min(probe_text.len, s + max_probe_len)];
                const structural = benchMetaknowReplayProbeTermIsStructural(probe_text, s, probe_text.len);
                var probe = try benchMetaknowReplayProbePlan(allocator, store, candidate);
                if (probe.matched_terms != 0) {
                    if (structural) {
                        if (structural_fallback == null) {
                            structural_fallback = probe;
                        } else {
                            probe.deinit(allocator);
                        }
                    } else {
                        if (structural_fallback) |fallback| fallback.deinit(allocator);
                        return probe;
                    }
                } else {
                    probe.deinit(allocator);
                }
            }
        }
    }
    if (structural_fallback) |probe| return probe;
    return error.InvalidRecord;
}

fn benchMetaknowReplayProbePlan(
    allocator: std.mem.Allocator,
    store: storage.Store,
    candidate: []const u8,
) !BenchMetaknowReplayTextProbe {
    const text = try allocator.dupe(u8, candidate);
    errdefer allocator.free(text);
    const plan = try text_search.textQueryPlanStats(allocator, store, candidate, .{ .limit = 8 });
    return .{
        .text = text,
        .owned_text = text,
        .query_terms = plan.query_terms,
        .unique_terms = plan.unique_query_terms,
        .matched_terms = plan.matched_terms,
        .postings = plan.postings_count_total,
        .max_postings = plan.max_postings_count,
    };
}

const BenchMetaknowReplayWarmEdge = struct {
    src: core.NodeId,
    rel: core.RelKind,
};

fn firstBenchMetaknowReplayDeferredSource(
    allocator: std.mem.Allocator,
    replay: *const BenchMetaknowReplay,
    node_count: usize,
) !?core.NodeId {
    if (replay.deferred_based_on.len == 0) return null;
    var id_map = try buildBenchMetaknowNodeIdMap(allocator, replay, node_count);
    defer id_map.deinit();
    for (replay.deferred_based_on) |row| {
        for (row.dst_original_ids) |dst_original_id| {
            if (id_map.get(dst_original_id)) |source_id| return core.NodeId.fromInt(source_id);
        }
    }
    return null;
}

fn firstBenchMetaknowReplayEdgeWithinNodePrefix(
    allocator: std.mem.Allocator,
    replay: *const BenchMetaknowReplay,
    node_count: usize,
    edge_count: usize,
) !?BenchMetaknowReplayWarmEdge {
    if (edge_count == 0 or replay.edges.len == 0) return null;
    var id_map = try buildBenchMetaknowNodeIdMap(allocator, replay, node_count);
    defer id_map.deinit();
    const edge_limit = @min(edge_count, replay.edges.len);
    for (replay.edges[0..edge_limit]) |edge| {
        if (std.mem.startsWith(u8, edge.src_original_id, "schema_root:") or
            std.mem.startsWith(u8, edge.dst_original_id, "schema_root:"))
        {
            continue;
        }
        const src = id_map.get(edge.src_original_id) orelse continue;
        _ = id_map.get(edge.dst_original_id) orelse continue;
        return .{ .src = core.NodeId.fromInt(src), .rel = edge.rel };
    }
    return null;
}

fn renderBenchAgentMixedOutput(
    allocator: std.mem.Allocator,
    io: std.Io,
    store_in: storage.Store,
    db_path: []const u8,
    initial_node_count: usize,
    initial_edge_count: usize,
    chunk_size: usize,
    workload: BenchWorkload,
    text_source: BenchTextSource,
    corpus_file_path: ?[]const u8,
    corpus_dir_path: ?[]const u8,
    text_density: *BenchTextDensityStats,
    edge_id_pattern: BenchEdgeIdPattern,
    edge_compact_batch_entries: u32,
    edge_compact_threshold_entries: u32,
    maintenance_every_ops: usize,
    maintenance_max_segments: usize,
    maintenance_max_edges: u64,
    maintenance_gc: bool,
    maintenance_node_text_every_ops: usize,
    maintenance_node_text_max_records: u64,
    maintenance_node_text_runs_every_ops: usize,
    maintenance_node_text_runs_max_records: u64,
    create_ns: u128,
    initial_add_node_ns: u128,
    initial_add_edge_ns: u128,
    create_rss: BenchRssSample,
    initial_add_node_rss: BenchRssSample,
    initial_add_edge_rss: BenchRssSample,
    edge_post_load_maintenance_rss: BenchRssSample,
    edge_post_load_maintenance: BenchEdgePostLoadMaintenanceStats,
    initial_node_load_timings: BenchNodeLoadTimings,
    node_batch_timings: storage.NodeBatchAppendTimings,
) ![]u8 {
    var out = QueryOutputWriter{ .allocator = allocator };
    errdefer out.buffer.deinit(allocator);

    var store = store_in;
    var node_append_timings = storage.NodeAppendTimings{};
    store.node_append_timings = &node_append_timings;

    const initial_property_count = std.math.mul(usize, initial_node_count, bench_agent_properties_per_node) catch return error.RecordTooLarge;
    var initial_property_stream = try BenchAgentPropertyStream.init(initial_node_count);
    const initial_property_write_start = monotonicNs(io);
    try store.replaceEmptyPropertyPayloadFromRestartableSortedStream(
        initial_property_count,
        &initial_property_stream,
        BenchAgentPropertyStream.restart,
        BenchAgentPropertyStream.next,
    );
    const initial_property_write_ns = elapsedNs(io, initial_property_write_start);

    var append_node_samples: [bench_agent_mixed_append_ops]u128 = undefined;
    var append_edge_samples: [bench_agent_mixed_append_ops]u128 = undefined;
    var append_property_samples: [bench_agent_mixed_append_ops]u128 = undefined;
    var append_node_batch_samples: [bench_agent_mixed_node_batch_ops]u128 = undefined;
    var append_property_batch_samples: [bench_agent_mixed_node_batch_ops]u128 = undefined;
    var property_lookup_samples: [bench_agent_mixed_query_ops]u128 = undefined;
    var neighbors_samples: [bench_agent_mixed_query_ops]u128 = undefined;
    var lookup_samples: [bench_agent_mixed_query_ops]u128 = undefined;
    var lookup_untimed_samples: [bench_agent_mixed_query_ops]u128 = undefined;
    var lookup_timing_probe_overhead_samples: [bench_agent_mixed_query_ops]u128 = undefined;
    var lookup_open_samples: [bench_agent_mixed_query_ops]u128 = undefined;
    var lookup_unattributed_samples: [bench_agent_mixed_query_ops]u128 = undefined;
    var lookup_lazy_open_meta_samples: [bench_agent_mixed_query_ops]u128 = undefined;
    var lookup_lazy_open_delta_header_samples: [bench_agent_mixed_query_ops]u128 = undefined;
    var lookup_lazy_open_manifest_samples: [bench_agent_mixed_query_ops]u128 = undefined;
    var lookup_lazy_open_base_samples: [bench_agent_mixed_query_ops]u128 = undefined;
    var lookup_lazy_open_validate_samples: [bench_agent_mixed_query_ops]u128 = undefined;
    var lookup_lazy_open_delta_samples: [bench_agent_mixed_query_ops]u128 = undefined;
    var lookup_lazy_open_runs_samples: [bench_agent_mixed_query_ops]u128 = undefined;
    var lookup_hash_samples: [bench_agent_mixed_query_ops]u128 = undefined;
    var lookup_cleanup_samples: [bench_agent_mixed_query_ops]u128 = undefined;
    var lookup_body_samples: [bench_agent_mixed_query_ops]u128 = undefined;
    var lookup_lower_bound_samples: [bench_agent_mixed_query_ops]u128 = undefined;
    var lookup_rows_last: usize = 0;
    var lookup_run_count_last: u64 = 0;
    var lookup_range_skip_count_last: u64 = 0;
    var lookup_lower_bound_max_run_ns: u128 = 0;
    var lookup_lower_bound_max_run_records: u64 = 0;
    var lookup_lower_bound_max_run_record_len: u16 = 0;
    var lookup_lower_bound_max_run_flags: u16 = 0;
    var lookup_lower_bound_max_run_filter_bytes: u64 = 0;
    var lookup_lower_bound_max_run_min_node_id: u64 = 0;
    var lookup_first_base_probe_count: u64 = 0;
    var lookup_first_delta_probe_count: u64 = 0;
    var lookup_first_run_probe_count: u64 = 0;
    var lookup_first_base_hit_count: u64 = 0;
    var lookup_first_delta_hit_count: u64 = 0;
    var lookup_first_run_hit_count: u64 = 0;
    var lookup_first_base_miss_before_later_hit_count: u64 = 0;
    var lookup_first_base_filter_skip_count: u64 = 0;
    var neighbors_rows_last: usize = 0;
    var neighbors_nodes_visited_last: u64 = 0;
    var neighbors_edges_visited_last: u64 = 0;
    var neighbors_budget_exceeded: usize = 0;
    var query_sample_index: usize = 0;
    var maintenance_ns: u128 = 0;
    var edge_retention_registry = storage.EdgeSegmentRetentionRegistry.init(allocator);
    defer edge_retention_registry.deinit();
    var node_text_retention_registry = storage.NodeTextRunRetentionRegistry.init(allocator);
    defer node_text_retention_registry.deinit();
    var write_session = agent.AgentWriteSession.init(store, .{
        .edge_l0_every_ops = maintenance_every_ops,
        .edge_l0_max_segments = maintenance_max_segments,
        .edge_l0_max_edges = maintenance_max_edges,
        .edge_gc_every_ops = if (maintenance_gc) maintenance_every_ops else 0,
        .node_text_delta_every_ops = maintenance_node_text_every_ops,
        .node_text_delta_max_records = maintenance_node_text_max_records,
        .node_text_run_every_ops = maintenance_node_text_runs_every_ops,
        .node_text_run_max_records = maintenance_node_text_runs_max_records,
    });

    var op: usize = 0;
    benchTrace("agent_mixed_append_loop_start");
    while (op < bench_agent_mixed_append_ops) : (op += 1) {
        benchTraceOp("agent_mixed_append_op_start", op);
        const logical_node_id = initial_node_count + op + 1;
        const text = try benchNodeText(allocator, logical_node_id, text_source);
        defer allocator.free(text);
        try text_density.record(text.len);

        const node_start = monotonicNs(io);
        const node_id = try store.addNode(.file, text);
        append_node_samples[op] = elapsedNs(io, node_start);
        benchTraceOp("agent_mixed_append_node_done", op);

        const property_start = monotonicNs(io);
        try writeBenchAgentPropertiesForNodes(allocator, store, node_id.toInt(), 1);
        append_property_samples[op] = elapsedNs(io, property_start);

        const edge_start = monotonicNs(io);
        _ = try dag.addEdgeCheckedWithPersistentStore(allocator, store, .fromInt(1), .mentions, node_id, .{});
        append_edge_samples[op] = elapsedNs(io, edge_start);
        benchTraceOp("agent_mixed_append_edge_done", op);

        if ((op + 1) % bench_agent_mixed_query_every == 0) {
            var lookup_timings = storage.Store.NodeTextLookupTimings{};
            const lookup_start = monotonicNs(io);
            const lookup_id = try store.lookupFirstNodeIdByTextWithTimings(allocator, .file, text, &lookup_timings);
            const lookup_elapsed = elapsedNs(io, lookup_start);
            const lookup_open_ns = nodeTextLookupOpenTimingNs(lookup_timings);
            const lookup_body_ns = nodeTextLookupBodyTimingNs(lookup_timings);
            const lookup_cleanup_ns = lookup_timings.cleanup_ns;
            lookup_samples[query_sample_index] = lookup_elapsed;
            lookup_open_samples[query_sample_index] = lookup_open_ns;
            lookup_unattributed_samples[query_sample_index] = lookup_elapsed -| (lookup_open_ns +| lookup_body_ns +| lookup_cleanup_ns);
            lookup_lazy_open_meta_samples[query_sample_index] = lookup_timings.lazy_open_meta_ns;
            lookup_lazy_open_delta_header_samples[query_sample_index] = lookup_timings.lazy_open_delta_header_ns;
            lookup_lazy_open_manifest_samples[query_sample_index] = lookup_timings.lazy_open_manifest_ns;
            lookup_lazy_open_base_samples[query_sample_index] = lookup_timings.lazy_open_base_ns;
            lookup_lazy_open_validate_samples[query_sample_index] = lookup_timings.lazy_open_validate_ns;
            lookup_lazy_open_delta_samples[query_sample_index] = lookup_timings.lazy_open_delta_ns;
            lookup_lazy_open_runs_samples[query_sample_index] = lookup_timings.lazy_open_runs_ns;
            lookup_hash_samples[query_sample_index] = lookup_timings.hash_ns;
            lookup_cleanup_samples[query_sample_index] = lookup_cleanup_ns;
            lookup_body_samples[query_sample_index] = lookup_body_ns;
            lookup_lower_bound_samples[query_sample_index] = lookup_timings.lower_bound_ns;
            lookup_first_base_probe_count += lookup_timings.first_base_probe_count;
            lookup_first_delta_probe_count += lookup_timings.first_delta_probe_count;
            lookup_first_run_probe_count += lookup_timings.first_run_probe_count;
            lookup_first_base_hit_count += lookup_timings.first_base_hit_count;
            lookup_first_delta_hit_count += lookup_timings.first_delta_hit_count;
            lookup_first_run_hit_count += lookup_timings.first_run_hit_count;
            lookup_first_base_miss_before_later_hit_count += lookup_timings.first_base_miss_before_later_hit_count;
            lookup_first_base_filter_skip_count += lookup_timings.first_base_filter_skip_count;
            if (lookup_timings.lower_bound_max_run_ns > lookup_lower_bound_max_run_ns) {
                lookup_lower_bound_max_run_ns = lookup_timings.lower_bound_max_run_ns;
                lookup_lower_bound_max_run_records = lookup_timings.lower_bound_max_run_records;
                lookup_lower_bound_max_run_record_len = lookup_timings.lower_bound_max_run_record_len;
                lookup_lower_bound_max_run_flags = lookup_timings.lower_bound_max_run_flags;
                lookup_lower_bound_max_run_filter_bytes = lookup_timings.lower_bound_max_run_filter_bytes;
                lookup_lower_bound_max_run_min_node_id = lookup_timings.lower_bound_max_run_min_node_id;
            }
            lookup_rows_last = if (lookup_id == null) 0 else 1;
            lookup_run_count_last = lookup_timings.run_count;
            lookup_range_skip_count_last = lookup_timings.range_skip_count;
            if (lookup_id == null or lookup_id.?.toInt() != node_id.toInt()) return error.InvalidRecord;

            const lookup_untimed_start = monotonicNs(io);
            const lookup_untimed_id = try store.lookupFirstNodeIdByText(allocator, .file, text);
            const lookup_untimed_elapsed = elapsedNs(io, lookup_untimed_start);
            lookup_untimed_samples[query_sample_index] = lookup_untimed_elapsed;
            lookup_timing_probe_overhead_samples[query_sample_index] = lookup_elapsed -| lookup_untimed_elapsed;
            if (lookup_untimed_id == null or lookup_untimed_id.?.toInt() != node_id.toInt()) return error.InvalidRecord;

            const property_lookup_start = monotonicNs(io);
            try probeBenchAgentProperty(allocator, store, node_id.toInt(), query_sample_index % bench_agent_properties_per_node);
            property_lookup_samples[query_sample_index] = elapsedNs(io, property_lookup_start);

            const neighbors_start = monotonicNs(io);
            var neighbors = try query.neighborsWithPersistentStoreRetained(allocator, store, &edge_retention_registry, .fromInt(1), .mentions, .{
                .max_results = 4096,
                .max_visited_edges = 4096,
            });
            neighbors_samples[query_sample_index] = elapsedNs(io, neighbors_start);
            if (neighbors.stats.budget_exceeded) neighbors_budget_exceeded += 1;
            neighbors_rows_last = neighbors.neighbors.items.len;
            neighbors_nodes_visited_last = neighbors.stats.nodes_visited;
            neighbors_edges_visited_last = neighbors.stats.edges_visited;
            neighbors.deinit(allocator);
            query_sample_index += 1;
        }

        const next_append_ops = write_session.stats.append_ops + 1;
        const will_maintain_edge_l0 = write_session.policy.shouldMaintainEdgeL0(next_append_ops);
        const will_maintain_edge_gc = write_session.policy.shouldMaintainEdgeGc(next_append_ops);
        const will_maintain_node_text_delta = write_session.policy.shouldMaintainNodeTextDelta(next_append_ops);
        const will_maintain_node_text_runs = write_session.policy.shouldMaintainNodeTextRuns(next_append_ops);
        const will_maintain = will_maintain_edge_l0 or will_maintain_edge_gc or will_maintain_node_text_delta or will_maintain_node_text_runs;
        const maintenance_start = if (will_maintain) monotonicNs(io) else 0;
        const maintenance_result = try write_session.recordAppendAndMaintainWithRetentionRegistries(&edge_retention_registry, &node_text_retention_registry);
        if (will_maintain) {
            maintenance_ns += elapsedNs(io, maintenance_start);
            if (will_maintain_edge_l0 != maintenance_result.edge_l0_ran) return error.InvalidRecord;
            if (will_maintain_edge_gc != maintenance_result.edge_gc_ran) return error.InvalidRecord;
            if (will_maintain_node_text_delta != maintenance_result.node_text_delta_ran) return error.InvalidRecord;
            if (will_maintain_node_text_runs != maintenance_result.node_text_runs_ran) return error.InvalidRecord;
        } else if (maintenance_result.edge_l0_ran or maintenance_result.edge_gc_ran or maintenance_result.node_text_delta_ran or maintenance_result.node_text_runs_ran) {
            return error.InvalidRecord;
        }
    }
    if (query_sample_index != bench_agent_mixed_query_ops) return error.InvalidRecord;
    benchTrace("agent_mixed_append_loop_done");

    var batch_nodes = std.ArrayList(graph.Node).empty;
    defer batch_nodes.deinit(allocator);
    try batch_nodes.ensureTotalCapacity(allocator, bench_agent_mixed_node_batch_size);
    var batch_op: usize = 0;
    benchTrace("agent_mixed_batch_nodes_start");
    while (batch_op < bench_agent_mixed_node_batch_ops) : (batch_op += 1) {
        batch_nodes.clearRetainingCapacity();
        var texts_owned = true;
        errdefer if (texts_owned) freeBenchNodeTexts(allocator, batch_nodes.items);
        const first_logical_node_id = initial_node_count + bench_agent_mixed_append_ops + batch_op * bench_agent_mixed_node_batch_size + 1;
        var i: usize = 0;
        while (i < bench_agent_mixed_node_batch_size) : (i += 1) {
            const logical_node_id = first_logical_node_id + i;
            const text = try benchNodeText(allocator, logical_node_id, text_source);
            errdefer allocator.free(text);
            try text_density.record(text.len);
            try batch_nodes.append(allocator, .{
                .id = core.NodeId.fromInt(@intCast(logical_node_id)),
                .kind = .file,
                .text = text,
            });
        }

        const batch_start = monotonicNs(io);
        try store.appendNodesBatch(batch_nodes.items);
        append_node_batch_samples[batch_op] = elapsedNs(io, batch_start);

        const property_batch_start = monotonicNs(io);
        try writeBenchAgentPropertiesForNodes(allocator, store, first_logical_node_id, bench_agent_mixed_node_batch_size);
        append_property_batch_samples[batch_op] = elapsedNs(io, property_batch_start);

        freeBenchNodeTexts(allocator, batch_nodes.items);
        texts_owned = false;
    }
    benchTrace("agent_mixed_batch_nodes_done");

    const append_node_stats = latencyStats(append_node_samples[0..]);
    const append_edge_stats = latencyStats(append_edge_samples[0..]);
    const append_property_stats = latencyStats(append_property_samples[0..]);
    const append_node_batch_stats = latencyStats(append_node_batch_samples[0..]);
    const append_property_batch_stats = latencyStats(append_property_batch_samples[0..]);
    const property_lookup_stats = latencyStats(property_lookup_samples[0..]);
    const lookup_stats = latencyStats(lookup_samples[0..]);
    const lookup_untimed_stats = latencyStats(lookup_untimed_samples[0..]);
    const lookup_timing_probe_overhead_stats = latencyStats(lookup_timing_probe_overhead_samples[0..]);
    const lookup_open_stats = latencyStats(lookup_open_samples[0..]);
    const lookup_unattributed_stats = latencyStats(lookup_unattributed_samples[0..]);
    const lookup_lazy_open_meta_stats = latencyStats(lookup_lazy_open_meta_samples[0..]);
    const lookup_lazy_open_delta_header_stats = latencyStats(lookup_lazy_open_delta_header_samples[0..]);
    const lookup_lazy_open_manifest_stats = latencyStats(lookup_lazy_open_manifest_samples[0..]);
    const lookup_lazy_open_base_stats = latencyStats(lookup_lazy_open_base_samples[0..]);
    const lookup_lazy_open_validate_stats = latencyStats(lookup_lazy_open_validate_samples[0..]);
    const lookup_lazy_open_delta_stats = latencyStats(lookup_lazy_open_delta_samples[0..]);
    const lookup_lazy_open_runs_stats = latencyStats(lookup_lazy_open_runs_samples[0..]);
    const lookup_hash_stats = latencyStats(lookup_hash_samples[0..]);
    const lookup_cleanup_stats = latencyStats(lookup_cleanup_samples[0..]);
    const lookup_body_stats = latencyStats(lookup_body_samples[0..]);
    const lookup_lower_bound_stats = latencyStats(lookup_lower_bound_samples[0..]);
    const neighbors_stats = latencyStats(neighbors_samples[0..]);

    const property_compact_start = monotonicNs(io);
    const property_compaction = try store.compactPropertyPayloadDelta(allocator);
    const property_compact_ns = elapsedNs(io, property_compact_start);
    if (!property_compaction.compacted or property_compaction.cleanup_pending or property_compaction.delta_bytes == 0) return error.InvalidRecord;
    const property_compact_ns_per_record = if (property_compaction.live_entries == 0)
        0
    else
        property_compact_ns / @as(u128, property_compaction.live_entries);

    const property_reopen_start = monotonicNs(io);
    var property_reopened = try storage.Store.openWithOptions(allocator, io, db_path, .{
        .durability = .fast,
        .validate_indexes_on_read = false,
    });
    const property_reopen_ns = elapsedNs(io, property_reopen_start);
    defer property_reopened.deinit();
    const property_reopen_probe_node_id: u64 = initial_node_count + bench_agent_mixed_append_ops;
    const property_reopen_lookup_start = monotonicNs(io);
    try probeBenchAgentProperty(allocator, property_reopened, property_reopen_probe_node_id, 3);
    const property_reopen_lookup_ns = elapsedNs(io, property_reopen_lookup_start);

    const retained_lookup_node_id = initial_node_count + bench_agent_mixed_append_ops + bench_agent_mixed_node_batch_ops * bench_agent_mixed_node_batch_size;
    const retained_lookup_text = try benchNodeText(allocator, retained_lookup_node_id, text_source);
    defer allocator.free(retained_lookup_text);
    const retained_base_text = try benchNodeText(allocator, 1, text_source);
    defer allocator.free(retained_base_text);

    var lookup_view_open_timing_breakdown = storage.Store.NodeTextLookupOpenTimings{};
    var lookup_view_open_ns: u128 = 0;
    var retained_lookup_timing_breakdown = storage.Store.NodeTextLookupTimings{};
    var lookup_ids_retained_ns: u128 = 0;
    var lookup_ids_retained_hot_ns: u128 = 0;
    var lookup_retained_stats = BenchLatencyStats{ .p50_ns = 0, .p95_ns = 0, .p99_ns = 0, .max_ns = 0 };
    var lookup_retained_rows_last: usize = 0;
    var lookup_base_timing_breakdown = storage.Store.NodeTextLookupTimings{};
    var lookup_base_retained_stats = BenchLatencyStats{ .p50_ns = 0, .p95_ns = 0, .p99_ns = 0, .max_ns = 0 };
    var lookup_base_retained_rows_last: usize = 0;
    {
        const lookup_view_open_start = monotonicNs(io);
        var retained_lookup_view = try store.openNodeTextLookupViewWithTimings(allocator, &lookup_view_open_timing_breakdown);
        lookup_view_open_ns = elapsedNs(io, lookup_view_open_start);
        defer retained_lookup_view.deinit();

        const lookup_ids_retained_start = monotonicNs(io);
        var lookup_ids_retained = try retained_lookup_view.lookupIdsWithTimings(allocator, .file, retained_lookup_text, 1, &retained_lookup_timing_breakdown);
        lookup_ids_retained_ns = elapsedNs(io, lookup_ids_retained_start);
        if (lookup_ids_retained.items.len != 1 or lookup_ids_retained.items[0].toInt() != retained_lookup_node_id) {
            lookup_ids_retained.deinit(allocator);
            return error.InvalidRecord;
        }
        lookup_ids_retained.deinit(allocator);

        const lookup_ids_retained_hot_start = monotonicNs(io);
        var lookup_ids_retained_hot = try retained_lookup_view.lookupIds(allocator, .file, retained_lookup_text, 1);
        lookup_ids_retained_hot_ns = elapsedNs(io, lookup_ids_retained_hot_start);
        if (lookup_ids_retained_hot.items.len != 1 or lookup_ids_retained_hot.items[0].toInt() != retained_lookup_node_id) {
            lookup_ids_retained_hot.deinit(allocator);
            return error.InvalidRecord;
        }
        lookup_ids_retained_hot.deinit(allocator);

        var lookup_retained_samples: [bench_tinyql_suite_samples]u128 = undefined;
        for (&lookup_retained_samples) |*sample| {
            const sample_start = monotonicNs(io);
            var retained = try retained_lookup_view.lookupIds(allocator, .file, retained_lookup_text, 1);
            sample.* = elapsedNs(io, sample_start);
            if (retained.items.len != 1 or retained.items[0].toInt() != retained_lookup_node_id) {
                retained.deinit(allocator);
                return error.InvalidRecord;
            }
            lookup_retained_rows_last = retained.items.len;
            retained.deinit(allocator);
        }
        lookup_retained_stats = latencyStats(lookup_retained_samples[0..]);

        var lookup_base_retained_once = try retained_lookup_view.lookupIdsWithTimings(allocator, .file, retained_base_text, 1, &lookup_base_timing_breakdown);
        if (lookup_base_retained_once.items.len != 1 or lookup_base_retained_once.items[0].toInt() != 1) {
            lookup_base_retained_once.deinit(allocator);
            return error.InvalidRecord;
        }
        lookup_base_retained_once.deinit(allocator);

        var lookup_base_retained_samples: [bench_tinyql_suite_samples]u128 = undefined;
        for (&lookup_base_retained_samples) |*sample| {
            const sample_start = monotonicNs(io);
            var retained_base = try retained_lookup_view.lookupIds(allocator, .file, retained_base_text, 1);
            sample.* = elapsedNs(io, sample_start);
            if (retained_base.items.len != 1 or retained_base.items[0].toInt() != 1) {
                retained_base.deinit(allocator);
                return error.InvalidRecord;
            }
            lookup_base_retained_rows_last = retained_base.items.len;
            retained_base.deinit(allocator);
        }
        lookup_base_retained_stats = latencyStats(lookup_base_retained_samples[0..]);
    }

    const agent_workload_rss = try benchRssSample();

    const text_rebuild_start = monotonicNs(io);
    benchTrace("agent_mixed_text_rebuild_start");
    var text_rebuild_timings = text_search.PersistentTextRebuildTimings{};
    var text_rebuild_phase_rss = BenchTextRebuildPhaseRss{};
    {
        const runs_base_path = try benchTextPostingRunsBasePath(allocator, db_path);
        defer allocator.free(runs_base_path);
        const result = try rebuildPersistentTextCatalogForBenchWithPhaseRss(allocator, store, runs_base_path, &text_rebuild_phase_rss);
        text_rebuild_timings = result.timings;
    }
    const text_rebuild_ns = elapsedNs(io, text_rebuild_start);
    benchTrace("agent_mixed_text_rebuild_done");
    const text_rebuild_rss = try benchRssSample();
    const text_rebuild_rss_bytes = text_rebuild_rss.peak_bytes;
    const text_rebuild_current_rss_bytes = text_rebuild_rss.current_bytes;

    // Warm persistent-BM25 product gates. The agent-mixed lane must prove the
    // text read path at every rung, not only write/point-lookup paths; these
    // reuse the standard lane's probe names so the shared per-rung latency
    // thresholds apply unchanged.
    benchTrace("agent_mixed_text_probe_start");
    const text_code = benchTextProbe(allocator, store, "parseInvalidRecord") catch |err|
        return benchBudgetPhase(err, error.BenchTextCodeBudgetExceeded);
    const text_english = benchTextProbe(allocator, store, "agent latency budget") catch |err|
        return benchBudgetPhase(err, error.BenchTextEnglishBudgetExceeded);
    const text_cjk = benchTextProbe(allocator, store, "错误记录") catch |err|
        return benchBudgetPhase(err, error.BenchTextCjkBudgetExceeded);
    const text_highfreq = benchTextProbe(allocator, store, "common") catch |err|
        return benchBudgetPhase(err, error.BenchTextHighfreqBudgetExceeded);
    benchTrace("agent_mixed_text_probe_done");

    try out.print(
        "text_code_ns={} text_code_hits={} text_english_ns={} text_english_hits={} text_cjk_ns={} text_cjk_hits={} text_highfreq_ns={} text_highfreq_hits={}\n",
        .{
            text_code.ns,
            text_code.hits,
            text_english.ns,
            text_english.hits,
            text_cjk.ns,
            text_cjk.hits,
            text_highfreq.ns,
            text_highfreq.hits,
        },
    );

    benchTrace("agent_mixed_stats_start");
    const stats_out = try store.stats();
    benchTrace("agent_mixed_stats_done");
    const total_bytes = try storeDirBytes(allocator, io, db_path);
    const rss_bytes = try peakRssBytes();
    const current_rss_bytes = try currentRssBytes();
    const current_footprint_bytes = try currentFootprintBytes();
    const footprint_samples = [_]BenchRssSample{
        create_rss,
        initial_add_node_rss,
        initial_add_edge_rss,
        edge_post_load_maintenance_rss,
        agent_workload_rss,
        text_rebuild_rss,
        .{ .peak_bytes = rss_bytes, .current_bytes = current_rss_bytes, .footprint_bytes = current_footprint_bytes },
    };
    const footprint_peak_bytes = maxBenchFootprintBytes(&footprint_samples, text_rebuild_phase_rss);

    try out.print(
        "shape={s}\nbench_workload={s}\nbuild_optimize={s}\nmode=agent-mixed\ninitial_nodes={} initial_edges={} nodes={} edges={} bytes={} rss_bytes={} current_rss_bytes={} footprint_peak_bytes={} current_footprint_bytes={} chunk={} edge_id_pattern={s} edge_compact_batch={} edge_compact_threshold={} maintenance_every_ops={} maintenance_max_segments={} maintenance_max_edges={} maintenance_gc={} maintenance_node_text_every_ops={} maintenance_node_text_max_records={} maintenance_node_text_runs_every_ops={} maintenance_node_text_runs_max_records={}\n",
        .{
            workload.shapeLabel(),
            workload.label(),
            buildOptimizeLabel(),
            initial_node_count,
            initial_edge_count,
            stats_out.nodes,
            stats_out.edges,
            total_bytes,
            rss_bytes,
            current_rss_bytes,
            footprint_peak_bytes,
            current_footprint_bytes,
            chunk_size,
            edge_id_pattern.label(),
            edge_compact_batch_entries,
            edge_compact_threshold_entries,
            maintenance_every_ops,
            maintenance_max_segments,
            maintenance_max_edges,
            @intFromBool(maintenance_gc),
            maintenance_node_text_every_ops,
            maintenance_node_text_max_records,
            maintenance_node_text_runs_every_ops,
            maintenance_node_text_runs_max_records,
        },
    );
    try out.print(
        "bench_corpus_file={s}\nbench_corpus_dir={s}\nbench_corpus_records={}\n",
        .{ corpus_file_path orelse "", corpus_dir_path orelse "", text_source.corpusRecordCount() },
    );
    benchTrace("agent_mixed_density_start");
    const text_index_bytes = try benchTextIndexBytes(allocator, io, db_path);
    const edge_segments_bytes = try benchEdgeSegmentBytes(allocator, io, db_path);
    const node_texts_compression = try benchNodeTextsCompressionEstimate(allocator, io, db_path);
    const posting_compression = try text_search.estimatePersistentPostingCompression(allocator, store);
    const density_breakdown = try benchDensityBreakdown(allocator, io, db_path, store, stats_out);
    const size_snapshot = try store.refreshSizeSnapshot();
    const expected_property_count = std.math.mul(u64, stats_out.nodes, bench_agent_properties_per_node) catch return error.RecordTooLarge;
    if (size_snapshot.property_count != expected_property_count) return error.InvalidRecord;
    benchTrace("agent_mixed_density_done");
    // Product-order availability gate: one write after the final text
    // publication, then an immediate search. Measurement order must equal
    // product usage order — today a single write takes full-text search
    // offline on stores past the bounded stale-scan size, so this gate stays
    // red above that size until incremental text indexing (task 11999) lands.
    benchTrace("agent_mixed_write_then_search_start");
    var text_after_write_available: u64 = 0;
    var text_after_write_search_ns: u128 = 0;
    {
        const probe_node_id = try store.nextNodeId();
        try store.appendNode(.{
            .id = probe_node_id,
            .kind = .observation,
            .text = "write then search availability probe: benchwriteprobetoken common agent latency budget entry",
        });
        // Available means the written node itself is served back, not that
        // some older document happens to match; the probe term exists only in
        // the appended node.
        const search_start = monotonicNs(io);
        if (text_search.searchText(allocator, store, "benchwriteprobetoken", .{ .limit = 8 })) |hits_value| {
            var hits = hits_value;
            defer hits.deinit(allocator);
            for (hits.items) |hit| {
                if (hit.node_id == probe_node_id) {
                    text_after_write_available = 1;
                    text_after_write_search_ns = elapsedNs(io, search_start);
                    break;
                }
            }
        } else |err| switch (err) {
            error.OutOfMemory => return err,
            else => {},
        }
    }
    benchTrace("agent_mixed_write_then_search_done");
    try out.print(
        "text_after_write_available={} text_after_write_search_ns={}\n",
        .{ text_after_write_available, text_after_write_search_ns },
    );

    try appendBenchDensityMetrics(&out, text_density, total_bytes, text_index_bytes, edge_segments_bytes, node_texts_compression, posting_compression, density_breakdown);
    try out.print(
        "property_shape_digest={s}\nproperties_per_node={} property_distinct_keys={} property_count={} logical_property_value_bytes={} property_physical_bytes={} property_physical_over_logical_value_ratio=",
        .{
            bench_agent_property_shape_digest,
            bench_agent_properties_per_node,
            bench_agent_property_keys.len,
            size_snapshot.property_count,
            size_snapshot.logical_property_value_bytes,
            try density_breakdown.propertyPayloadBytes(),
        },
    );
    try appendRatioValue(&out, try density_breakdown.propertyPayloadBytes(), @max(size_snapshot.logical_property_value_bytes, 1));
    try out.print("logical_content_bytes={} physical_over_logical_content_ratio=", .{size_snapshot.logical_content_bytes});
    try appendRatioValue(&out, size_snapshot.physical_bytes, @max(size_snapshot.logical_content_bytes, 1));
    try out.print(
        "text_rebuild_ns={} text_rebuild_rss_bytes={} text_rebuild_current_rss_bytes={} text_rebuild_footprint_bytes={}\n",
        .{ text_rebuild_ns, text_rebuild_rss_bytes, text_rebuild_current_rss_bytes, text_rebuild_rss.footprint_bytes },
    );
    try appendTextRebuildTimings(&out, text_rebuild_timings);
    try appendTextRebuildPhaseRss(&out, text_rebuild_phase_rss);
    try out.print(
        "create_ns={}\ninitial_add_node_ns={} initial_add_node_ns_per={}\ninitial_add_edge_ns={} initial_add_edge_ns_per={}\nappend_ops={} batch_node_ops={} batch_node_size={} query_every={} query_ops={}\n",
        .{
            create_ns,
            initial_add_node_ns,
            perOpNs(initial_add_node_ns, initial_node_count),
            initial_add_edge_ns,
            perOpNs(initial_add_edge_ns, initial_edge_count),
            bench_agent_mixed_append_ops,
            bench_agent_mixed_node_batch_ops,
            bench_agent_mixed_node_batch_size,
            bench_agent_mixed_query_every,
            bench_agent_mixed_query_ops,
        },
    );
    try out.print(
        "initial_property_write_ns={} property_compact_ns={} property_compact_records={} property_compact_ns_per_record={} property_reopen_ns={} property_reopen_lookup_ns={}\nappend_property_p50_ns={} append_property_p95_ns={} append_property_p99_ns={} append_property_max_ns={}\nappend_property_batch_p50_ns={} append_property_batch_p95_ns={} append_property_batch_p99_ns={} append_property_batch_max_ns={}\nproperty_lookup_p50_ns={} property_lookup_p95_ns={} property_lookup_p99_ns={} property_lookup_max_ns={}\n",
        .{
            initial_property_write_ns,
            property_compact_ns,
            property_compaction.live_entries,
            property_compact_ns_per_record,
            property_reopen_ns,
            property_reopen_lookup_ns,
            append_property_stats.p50_ns,
            append_property_stats.p95_ns,
            append_property_stats.p99_ns,
            append_property_stats.max_ns,
            append_property_batch_stats.p50_ns,
            append_property_batch_stats.p95_ns,
            append_property_batch_stats.p99_ns,
            append_property_batch_stats.max_ns,
            property_lookup_stats.p50_ns,
            property_lookup_stats.p95_ns,
            property_lookup_stats.p99_ns,
            property_lookup_stats.max_ns,
        },
    );
    try out.print(
        "edge_post_load_maintenance_ns={} edge_post_load_maintenance_compactions={}\n",
        .{ edge_post_load_maintenance.ns, edge_post_load_maintenance.compactions },
    );
    const final_node_batch_timings = if (store.node_batch_append_timings) |timings| timings.* else node_batch_timings;
    try appendNodeBatchAppendTimings(&out, initial_node_load_timings, final_node_batch_timings);
    const final_node_append_timings = if (store.node_append_timings) |timings| timings.* else node_append_timings;
    try appendNodeAppendTimings(&out, final_node_append_timings);
    try out.print(
        "append_node_p50_ns={} append_node_p95_ns={} append_node_p99_ns={} append_node_max_ns={}\nappend_node_batch_p50_ns={} append_node_batch_p95_ns={} append_node_batch_p99_ns={} append_node_batch_max_ns={}\nappend_edge_p50_ns={} append_edge_p95_ns={} append_edge_p99_ns={} append_edge_max_ns={}\n",
        .{
            append_node_stats.p50_ns,
            append_node_stats.p95_ns,
            append_node_stats.p99_ns,
            append_node_stats.max_ns,
            append_node_batch_stats.p50_ns,
            append_node_batch_stats.p95_ns,
            append_node_batch_stats.p99_ns,
            append_node_batch_stats.max_ns,
            append_edge_stats.p50_ns,
            append_edge_stats.p95_ns,
            append_edge_stats.p99_ns,
            append_edge_stats.max_ns,
        },
    );
    try out.print(
        "lookup_p50_ns={} lookup_p95_ns={} lookup_p99_ns={} lookup_max_ns={} lookup_untimed_p95_ns={} lookup_timing_probe_overhead_p95_ns={} lookup_rows_last={} lookup_open_p95_ns={} lookup_body_p95_ns={} lookup_unattributed_p50_ns={} lookup_unattributed_p95_ns={} lookup_unattributed_p99_ns={} lookup_unattributed_max_ns={} lookup_lower_bound_p95_ns={} lookup_run_count_last={} lookup_range_skip_count_last={}\n",
        .{
            lookup_stats.p50_ns,
            lookup_stats.p95_ns,
            lookup_stats.p99_ns,
            lookup_stats.max_ns,
            lookup_untimed_stats.p95_ns,
            lookup_timing_probe_overhead_stats.p95_ns,
            lookup_rows_last,
            lookup_open_stats.p95_ns,
            lookup_body_stats.p95_ns,
            lookup_unattributed_stats.p50_ns,
            lookup_unattributed_stats.p95_ns,
            lookup_unattributed_stats.p99_ns,
            lookup_unattributed_stats.max_ns,
            lookup_lower_bound_stats.p95_ns,
            lookup_run_count_last,
            lookup_range_skip_count_last,
        },
    );
    try out.print(
        "lookup_lazy_open_meta_p95_ns={} lookup_lazy_open_delta_header_p95_ns={} lookup_lazy_open_manifest_p95_ns={} lookup_lazy_open_base_p95_ns={} lookup_lazy_open_validate_p95_ns={} lookup_lazy_open_delta_p95_ns={} lookup_lazy_open_runs_p95_ns={} lookup_hash_p95_ns={} lookup_cleanup_p95_ns={} lookup_lower_bound_max_run_ns={} lookup_lower_bound_max_run_records={} lookup_lower_bound_max_run_record_len={} lookup_lower_bound_max_run_flags={} lookup_lower_bound_max_run_filter_bytes={} lookup_lower_bound_max_run_min_node_id={}\n",
        .{
            lookup_lazy_open_meta_stats.p95_ns,
            lookup_lazy_open_delta_header_stats.p95_ns,
            lookup_lazy_open_manifest_stats.p95_ns,
            lookup_lazy_open_base_stats.p95_ns,
            lookup_lazy_open_validate_stats.p95_ns,
            lookup_lazy_open_delta_stats.p95_ns,
            lookup_lazy_open_runs_stats.p95_ns,
            lookup_hash_stats.p95_ns,
            lookup_cleanup_stats.p95_ns,
            lookup_lower_bound_max_run_ns,
            lookup_lower_bound_max_run_records,
            lookup_lower_bound_max_run_record_len,
            lookup_lower_bound_max_run_flags,
            lookup_lower_bound_max_run_filter_bytes,
            lookup_lower_bound_max_run_min_node_id,
        },
    );
    try out.print(
        "lookup_first_base_probe_count={} lookup_first_delta_probe_count={} lookup_first_run_probe_count={} lookup_first_base_hit_count={} lookup_first_delta_hit_count={} lookup_first_run_hit_count={} lookup_first_base_miss_before_later_hit_count={} lookup_first_base_filter_skip_count={}\n",
        .{
            lookup_first_base_probe_count,
            lookup_first_delta_probe_count,
            lookup_first_run_probe_count,
            lookup_first_base_hit_count,
            lookup_first_delta_hit_count,
            lookup_first_run_hit_count,
            lookup_first_base_miss_before_later_hit_count,
            lookup_first_base_filter_skip_count,
        },
    );
    try out.print(
        "lookup_view_open_ns={} lookup_view_open_meta_ns={} lookup_view_open_delta_header_ns={} lookup_view_open_manifest_ns={} lookup_view_open_base_open_ns={} lookup_view_open_validate_ns={} lookup_view_open_delta_open_ns={} lookup_view_open_runs_open_ns={} lookup_view_open_run_entries={} lookup_view_open_runs_open_count={}\nlookup_ids_retained_ns={} lookup_ids_retained_hot_ns={}\nlookup_retained_samples={} lookup_retained_p50_ns={} lookup_retained_p95_ns={} lookup_retained_p99_ns={} lookup_retained_max_ns={} lookup_retained_rows_last={} lookup_retained_run_count={} lookup_retained_lower_bound_probe_count={} lookup_retained_range_skip_count={}\nlookup_base_retained_samples={} lookup_base_retained_p50_ns={} lookup_base_retained_p95_ns={} lookup_base_retained_p99_ns={} lookup_base_retained_max_ns={} lookup_base_retained_rows_last={} lookup_base_run_count={} lookup_base_lower_bound_probe_count={} lookup_base_range_skip_count={}\n",
        .{
            lookup_view_open_ns,
            lookup_view_open_timing_breakdown.meta_ns,
            lookup_view_open_timing_breakdown.delta_header_ns,
            lookup_view_open_timing_breakdown.manifest_ns,
            lookup_view_open_timing_breakdown.base_open_ns,
            lookup_view_open_timing_breakdown.validate_ns,
            lookup_view_open_timing_breakdown.delta_open_ns,
            lookup_view_open_timing_breakdown.runs_open_ns,
            lookup_view_open_timing_breakdown.run_entries,
            lookup_view_open_timing_breakdown.runs_open_count,
            lookup_ids_retained_ns,
            lookup_ids_retained_hot_ns,
            bench_tinyql_suite_samples,
            lookup_retained_stats.p50_ns,
            lookup_retained_stats.p95_ns,
            lookup_retained_stats.p99_ns,
            lookup_retained_stats.max_ns,
            lookup_retained_rows_last,
            retained_lookup_timing_breakdown.run_count,
            retained_lookup_timing_breakdown.lower_bound_probe_count,
            retained_lookup_timing_breakdown.range_skip_count,
            bench_tinyql_suite_samples,
            lookup_base_retained_stats.p50_ns,
            lookup_base_retained_stats.p95_ns,
            lookup_base_retained_stats.p99_ns,
            lookup_base_retained_stats.max_ns,
            lookup_base_retained_rows_last,
            lookup_base_timing_breakdown.run_count,
            lookup_base_timing_breakdown.lower_bound_probe_count,
            lookup_base_timing_breakdown.range_skip_count,
        },
    );
    try out.print(
        "neighbors_p50_ns={} neighbors_p95_ns={} neighbors_p99_ns={} neighbors_max_ns={} neighbors_rows_last={} neighbors_nodes_visited_last={} neighbors_edges_visited_last={} neighbors_budget_exceeded={}\n",
        .{
            neighbors_stats.p50_ns,
            neighbors_stats.p95_ns,
            neighbors_stats.p99_ns,
            neighbors_stats.max_ns,
            neighbors_rows_last,
            neighbors_nodes_visited_last,
            neighbors_edges_visited_last,
            neighbors_budget_exceeded,
        },
    );
    if (store.edge_batch_segment_delta_stats) |delta_stats| try appendEdgeDeltaStats(&out, delta_stats.*);
    try out.print(
        "maintenance_ops={} maintenance_compactions={} maintenance_compacted_edges={} maintenance_compacted_segments={} maintenance_gc_deleted_segments={} maintenance_gc_deleted_manifests={} maintenance_ns={} maintenance_entries_before_last={} maintenance_entries_after_last={}\n",
        .{
            write_session.stats.maintenance_ops,
            write_session.stats.maintenance_compactions,
            write_session.stats.maintenance_compacted_edges,
            write_session.stats.maintenance_compacted_segments,
            write_session.stats.maintenance_gc_deleted_segments,
            write_session.stats.maintenance_gc_deleted_manifests,
            maintenance_ns,
            write_session.stats.maintenance_entries_before_last,
            write_session.stats.maintenance_entries_after_last,
        },
    );
    try out.print(
        "node_text_delta_compactions={} node_text_delta_records_compacted={} node_text_delta_records_before_last={} node_text_delta_records_after_last={} node_text_run_compactions={} node_text_run_records_compacted={} node_text_run_entries_before_last={} node_text_run_entries_after_last={} node_text_run_records_before_last={} node_text_run_records_after_last={} node_text_run_gc_deleted_runs={}\n",
        .{
            write_session.stats.node_text_delta_compactions,
            write_session.stats.node_text_delta_records_compacted,
            write_session.stats.node_text_delta_records_before_last,
            write_session.stats.node_text_delta_records_after_last,
            write_session.stats.node_text_run_compactions,
            write_session.stats.node_text_run_records_compacted,
            write_session.stats.node_text_run_entries_before_last,
            write_session.stats.node_text_run_entries_after_last,
            write_session.stats.node_text_run_records_before_last,
            write_session.stats.node_text_run_records_after_last,
            write_session.stats.node_text_run_gc_deleted_runs,
        },
    );
    return out.buffer.toOwnedSlice(allocator);
}

fn latencyStats(samples: []u128) BenchLatencyStats {
    std.mem.sort(u128, samples, {}, u128LessThan);
    return .{
        .p50_ns = percentileNs(samples, 50, 100),
        .p95_ns = percentileNs(samples, 95, 100),
        .p99_ns = percentileNs(samples, 99, 100),
        .max_ns = samples[samples.len - 1],
    };
}

fn percentileNs(samples: []const u128, numerator: usize, denominator: usize) u128 {
    std.debug.assert(samples.len > 0);
    std.debug.assert(numerator > 0 and numerator <= denominator);
    const rank = ((samples.len * numerator) + denominator - 1) / denominator;
    return samples[@min(rank - 1, samples.len - 1)];
}

fn u128LessThan(_: void, a: u128, b: u128) bool {
    return a < b;
}

const BenchTextProbe = struct {
    ns: u128,
    hits: usize,
    query_terms: usize,
    unique_terms: usize,
    matched_terms: usize,
    postings: u64,
    max_postings: u64,
};

fn benchTextProbe(allocator: std.mem.Allocator, store: storage.Store, query_text: []const u8) !BenchTextProbe {
    // The ladder tracks warm query latency; plan stats fault term-catalog pages
    // and the untimed search warms candidate doc/name pages before timing.
    const plan = try text_search.textQueryPlanStats(allocator, store, query_text, .{ .limit = 8 });
    var warmup_hits = try text_search.searchText(allocator, store, query_text, .{ .limit = 8 });
    defer warmup_hits.deinit(allocator);
    if (warmup_hits.items.len == 0) return error.InvalidRecord;
    const start = monotonicNs(store.io);
    var hits = try text_search.searchText(allocator, store, query_text, .{ .limit = 8 });
    const ns = elapsedNs(store.io, start);
    defer hits.deinit(allocator);
    if (hits.items.len == 0) return error.InvalidRecord;
    return .{
        .ns = ns,
        .hits = hits.items.len,
        .query_terms = plan.query_terms,
        .unique_terms = plan.unique_query_terms,
        .matched_terms = plan.matched_terms,
        .postings = plan.postings_count_total,
        .max_postings = plan.max_postings_count,
    };
}

const BenchTinyQlProbe = struct {
    ns: u128,
    rows: usize,
    nodes_visited: u64,
    edges_visited: u64,
};

const BenchTinyQlSuite = struct {
    stats: BenchLatencyStats,
    rows_last: usize,
    nodes_visited_last: u64,
    edges_visited_last: u64,
    render_bytes_last: usize = 0,
};

fn benchTinyQlProbe(
    allocator: std.mem.Allocator,
    io: std.Io,
    store: storage.Store,
    source: []const u8,
) !BenchTinyQlProbe {
    const start = monotonicNs(io);
    const ast_query = try ql.parser.parse(allocator, source);
    defer ql.ast.freeQuery(allocator, ast_query);
    var type_env = try ql.typecheck.check(allocator, ast_query);
    defer type_env.deinit(allocator);
    var logical = try ql.planner.plan(allocator, ast_query);
    defer logical.deinit(allocator);
    var physical = try ql.optimizer.optimize(allocator, logical);
    defer physical.deinit(allocator);

    var edge_retention_registry = storage.EdgeSegmentRetentionRegistry.init(allocator);
    defer edge_retention_registry.deinit();
    var node_text_retention_registry = storage.NodeTextRunRetentionRegistry.init(allocator);
    defer node_text_retention_registry.deinit();
    var table = try ql.executor.executeWithPersistentStoreAndIoRetainedIndexes(allocator, io, store, &edge_retention_registry, &node_text_retention_registry, physical, .{
        .max_results = 8,
        .timeout_ms = std.math.maxInt(u64),
    });
    const ns = elapsedNs(io, start);
    defer table.deinit(allocator);
    if (table.stats.budget_exceeded) return core.Error.BudgetExceeded;
    if (table.rows.items.len == 0) return error.InvalidRecord;
    return .{
        .ns = ns,
        .rows = table.rows.items.len,
        .nodes_visited = table.stats.nodes_visited,
        .edges_visited = table.stats.edges_visited,
    };
}

fn benchTinyQlSuite(
    allocator: std.mem.Allocator,
    io: std.Io,
    store: storage.Store,
    source: []const u8,
) !BenchTinyQlSuite {
    const ast_query = try ql.parser.parse(allocator, source);
    defer ql.ast.freeQuery(allocator, ast_query);
    var type_env = try ql.typecheck.check(allocator, ast_query);
    defer type_env.deinit(allocator);
    var logical = try ql.planner.plan(allocator, ast_query);
    defer logical.deinit(allocator);
    var physical = try ql.optimizer.optimize(allocator, logical);
    defer physical.deinit(allocator);

    var samples: [bench_tinyql_suite_samples]u128 = undefined;
    var rows_last: usize = 0;
    var nodes_visited_last: u64 = 0;
    var edges_visited_last: u64 = 0;
    var session = ql.executor.PersistentStoreQuerySession.init(allocator, store);
    defer session.deinit();
    try warmTinyQlSession(allocator, io, &session, physical);
    for (&samples) |*sample| {
        const start = monotonicNs(io);
        var table = try session.execute(io, physical, .{
            .max_results = 8,
            .timeout_ms = std.math.maxInt(u64),
        });
        sample.* = elapsedNs(io, start);
        if (table.stats.budget_exceeded) {
            table.deinit(allocator);
            return core.Error.BudgetExceeded;
        }
        if (table.rows.items.len == 0) {
            table.deinit(allocator);
            return error.InvalidRecord;
        }
        rows_last = table.rows.items.len;
        nodes_visited_last = table.stats.nodes_visited;
        edges_visited_last = table.stats.edges_visited;
        table.deinit(allocator);
    }

    return .{
        .stats = latencyStats(&samples),
        .rows_last = rows_last,
        .nodes_visited_last = nodes_visited_last,
        .edges_visited_last = edges_visited_last,
    };
}

fn benchTinyQlRenderSuite(
    allocator: std.mem.Allocator,
    io: std.Io,
    store: storage.Store,
    source: []const u8,
) !BenchTinyQlSuite {
    const ast_query = try ql.parser.parse(allocator, source);
    defer ql.ast.freeQuery(allocator, ast_query);
    var type_env = try ql.typecheck.check(allocator, ast_query);
    defer type_env.deinit(allocator);
    var logical = try ql.planner.plan(allocator, ast_query);
    defer logical.deinit(allocator);
    var physical = try ql.optimizer.optimize(allocator, logical);
    defer physical.deinit(allocator);
    const projections = physicalProjections(physical) orelse return error.InvalidPlan;

    var samples: [bench_tinyql_suite_samples]u128 = undefined;
    var rows_last: usize = 0;
    var nodes_visited_last: u64 = 0;
    var edges_visited_last: u64 = 0;
    var render_bytes_last: usize = 0;
    var session = ql.executor.PersistentStoreQuerySession.init(allocator, store);
    defer session.deinit();
    try warmTinyQlSession(allocator, io, &session, physical);
    for (&samples) |*sample| {
        const start = monotonicNs(io);
        var table = try session.execute(io, physical, .{
            .max_results = 8,
            .timeout_ms = std.math.maxInt(u64),
        });
        defer table.deinit(allocator);
        if (table.stats.budget_exceeded) return core.Error.BudgetExceeded;
        if (table.rows.items.len == 0) return error.InvalidRecord;

        var merged_stats = table.stats;
        var sink = CountingProjectionSink{ .allocator = allocator };
        var node_view: ?storage.Store.NodeRecordView = null;
        defer if (node_view) |*view| view.deinit();
        if (projectionsNeedPersistentNodes(projections)) {
            node_view = try store.openNodeRecordView();
        }
        var status_snapshot = try initTaskStatusProjectionSnapshot(
            allocator,
            store,
            if (node_view) |*view| view else null,
            table.rows.items,
            projections,
        );
        defer if (status_snapshot) |*snapshot| snapshot.deinit();
        const read_timestamp_ns = table.read_timestamp_ns orelse try u128ToU64(persistentNowNs(io));
        for (table.rows.items) |row| {
            for (projections) |projection| {
                var projection_stats: query_index.QueryStats = .{};
                try writeProjectionPersistent(&sink, allocator, store, session.edgeRetentionRegistry(), if (node_view) |*view| view else null, if (status_snapshot) |*snapshot| snapshot else null, read_timestamp_ns, row, projection, .{
                    .max_results = 8,
                    .timeout_ms = std.math.maxInt(u64),
                }, &projection_stats);
                try mergeProjectionStats(&merged_stats, projection_stats);
            }
        }
        sample.* = elapsedNs(io, start);
        rows_last = table.rows.items.len;
        nodes_visited_last = merged_stats.nodes_visited;
        edges_visited_last = merged_stats.edges_visited;
        render_bytes_last = sink.bytes;
    }

    return .{
        .stats = latencyStats(&samples),
        .rows_last = rows_last,
        .nodes_visited_last = nodes_visited_last,
        .edges_visited_last = edges_visited_last,
        .render_bytes_last = render_bytes_last,
    };
}

fn warmTinyQlSession(
    allocator: std.mem.Allocator,
    io: std.Io,
    session: *ql.executor.PersistentStoreQuerySession,
    physical: ql.optimizer.PhysicalPlan,
) !void {
    var warmup: usize = 0;
    while (warmup < bench_tinyql_suite_warmups) : (warmup += 1) {
        var table = try session.execute(io, physical, .{
            .max_results = 8,
            .timeout_ms = std.math.maxInt(u64),
        });
        if (table.stats.budget_exceeded) {
            table.deinit(allocator);
            return core.Error.BudgetExceeded;
        }
        if (table.rows.items.len == 0) {
            table.deinit(allocator);
            return error.InvalidRecord;
        }
        table.deinit(allocator);
    }
}

fn benchTinyQlLookupQuery(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out = QueryOutputWriter{ .allocator = allocator };
    errdefer out.buffer.deinit(allocator);

    try out.writeAll("MATCH (f:file) WHERE f.text = ");
    try writeTinyQlStringLiteral(&out, text);
    try out.writeAll(" RETURN f LIMIT 1");
    return out.buffer.toOwnedSlice(allocator);
}

fn benchTinyQlPathQuery(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out = QueryOutputWriter{ .allocator = allocator };
    errdefer out.buffer.deinit(allocator);

    try out.writeAll("MATCH (f:file)-[:mentions*1..3]->(n:file) WHERE f.text = ");
    try writeTinyQlStringLiteral(&out, text);
    try out.writeAll(" RETURN path(f,n) LIMIT 8");
    return out.buffer.toOwnedSlice(allocator);
}

fn benchTinyQlTextPathQuery(allocator: std.mem.Allocator, text_query: []const u8) ![]u8 {
    var out = QueryOutputWriter{ .allocator = allocator };
    errdefer out.buffer.deinit(allocator);

    try out.writeAll("MATCH TEXT ");
    try writeTinyQlStringLiteral(&out, text_query);
    try out.writeAll(" AS f:file MATCH (f)-[:mentions*1..3]->(n:file) RETURN path(f,n) LIMIT 8");
    return out.buffer.toOwnedSlice(allocator);
}

fn benchTinyQlContextQuery(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out = QueryOutputWriter{ .allocator = allocator };
    errdefer out.buffer.deinit(allocator);

    try out.writeAll("MATCH (f:file) WHERE f.text = ");
    try writeTinyQlStringLiteral(&out, text);
    try out.writeAll(" RETURN context(f) LIMIT 1");
    return out.buffer.toOwnedSlice(allocator);
}

fn benchTinyQlTextContextQuery(allocator: std.mem.Allocator, text_query: []const u8) ![]u8 {
    var out = QueryOutputWriter{ .allocator = allocator };
    errdefer out.buffer.deinit(allocator);

    try out.writeAll("MATCH TEXT ");
    try writeTinyQlStringLiteral(&out, text_query);
    try out.writeAll(" AS f:file RETURN context(f) LIMIT 1");
    return out.buffer.toOwnedSlice(allocator);
}

fn benchTinyQlReachableQuery(allocator: std.mem.Allocator, from_name: []const u8, to_name: []const u8, positive_traversal: bool) ![]u8 {
    var out = QueryOutputWriter{ .allocator = allocator };
    errdefer out.buffer.deinit(allocator);

    if (positive_traversal) {
        try out.writeAll("MATCH (f:file)-[:mentions*1..3]->(n:file) WHERE f.text = ");
        try writeTinyQlStringLiteral(&out, from_name);
        try out.writeAll(" RETURN reachable(f,n,DEPENDS_ON) LIMIT 1");
    } else {
        _ = to_name;
        try out.writeAll("MATCH (f:file) WHERE f.text = ");
        try writeTinyQlStringLiteral(&out, from_name);
        try out.writeAll(" RETURN reachable(f,f,DEPENDS_ON) LIMIT 1");
    }
    return out.buffer.toOwnedSlice(allocator);
}

fn benchTinyQlTextReachableQuery(allocator: std.mem.Allocator, text_query: []const u8, to_name: []const u8, positive_traversal: bool) ![]u8 {
    var out = QueryOutputWriter{ .allocator = allocator };
    errdefer out.buffer.deinit(allocator);

    try out.writeAll("MATCH TEXT ");
    try writeTinyQlStringLiteral(&out, text_query);
    if (positive_traversal) {
        _ = to_name;
        try out.writeAll(" AS f:file MATCH (f)-[:mentions*1..3]->(n:file) RETURN reachable(f,n,DEPENDS_ON) LIMIT 1");
    } else {
        _ = to_name;
        try out.writeAll(" AS f:file RETURN reachable(f,f,DEPENDS_ON) LIMIT 1");
    }
    return out.buffer.toOwnedSlice(allocator);
}

fn benchTinyQlTextUnreachableQuery(allocator: std.mem.Allocator, text_query: []const u8, positive_fixture: bool) ![]u8 {
    var out = QueryOutputWriter{ .allocator = allocator };
    errdefer out.buffer.deinit(allocator);

    try out.writeAll("MATCH TEXT ");
    try writeTinyQlStringLiteral(&out, text_query);
    if (positive_fixture) {
        try out.writeAll(" AS f:file MATCH (f)-[:mentions]->(n:file) RETURN reachable(n,f,DEPENDS_ON) LIMIT 1");
    } else {
        try out.writeAll(" AS f:file RETURN reachable(f,f,DEPENDS_ON) LIMIT 1");
    }
    return out.buffer.toOwnedSlice(allocator);
}

fn benchTinyQlTextMixedRenderQuery(allocator: std.mem.Allocator, text_query: []const u8, to_name: []const u8, positive_traversal: bool) ![]u8 {
    var out = QueryOutputWriter{ .allocator = allocator };
    errdefer out.buffer.deinit(allocator);

    try out.writeAll("MATCH TEXT ");
    try writeTinyQlStringLiteral(&out, text_query);
    if (positive_traversal) {
        _ = to_name;
        try out.writeAll(" AS f:file MATCH (f)-[:mentions*1..3]->(n:file) RETURN context(f), path(f,n), reachable(f,n,DEPENDS_ON) LIMIT 1");
    } else {
        _ = to_name;
        try out.writeAll(" AS f:file RETURN context(f), reachable(f,f,DEPENDS_ON) LIMIT 1");
    }
    return out.buffer.toOwnedSlice(allocator);
}

fn writeTinyQlStringLiteral(writer: anytype, text: []const u8) !void {
    try writer.writeAll("\"");
    for (text) |byte| {
        switch (byte) {
            '\\' => try writer.writeAll("\\\\"),
            '"' => try writer.writeAll("\\\""),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.writeAll(&.{byte}),
        }
    }
    try writer.writeAll("\"");
}

fn appendBenchNodesChunked(
    allocator: std.mem.Allocator,
    store: storage.Store,
    node_count: usize,
    chunk_size: usize,
    text_source: BenchTextSource,
    text_density: *BenchTextDensityStats,
    timings: *BenchNodeLoadTimings,
) !void {
    var nodes = std.ArrayList(graph.Node).empty;
    defer nodes.deinit(allocator);
    try nodes.ensureTotalCapacity(allocator, @min(node_count, chunk_size));
    var text_spans = std.ArrayList(BenchGeneratedTextSpan).empty;
    defer text_spans.deinit(allocator);
    try text_spans.ensureTotalCapacity(allocator, @min(node_count, chunk_size));
    var text_bytes = std.ArrayList(u8).empty;
    defer text_bytes.deinit(allocator);

    var next_id: usize = 1;
    while (next_id <= node_count) {
        {
            nodes.clearRetainingCapacity();
            text_spans.clearRetainingCapacity();
            text_bytes.clearRetainingCapacity();

            const take = @min(chunk_size, node_count - next_id + 1);
            const end = next_id + take - 1;
            var id = next_id;
            const generate_start = monotonicNs(store.io);
            while (id <= end) : (id += 1) {
                const offset = text_bytes.items.len;
                try appendBenchNodeTextBytes(allocator, &text_bytes, id, text_source);
                const len = text_bytes.items.len - offset;
                try text_density.record(len);
                try text_spans.append(allocator, .{ .offset = offset, .len = len });
            }
            for (text_spans.items, 0..) |span, index| {
                const node_id = next_id + index;
                try nodes.append(allocator, .{
                    .id = core.NodeId.fromInt(@intCast(node_id)),
                    .kind = .file,
                    .text = text_bytes.items[span.offset..][0..span.len],
                });
            }
            timings.generate_texts_ns += elapsedNs(store.io, generate_start);
            const append_start = monotonicNs(store.io);
            try store.appendNodesBatch(nodes.items);
            timings.store_append_ns += elapsedNs(store.io, append_start);
            next_id = end + 1;
        }
    }
}

fn appendBenchEdgesChunked(
    allocator: std.mem.Allocator,
    store: storage.Store,
    node_count: usize,
    edge_count: usize,
    chunk_size: usize,
    edge_id_pattern: BenchEdgeIdPattern,
) !void {
    var edges = std.ArrayList(graph.Edge).empty;
    defer edges.deinit(allocator);
    try edges.ensureTotalCapacity(allocator, @min(edge_count, chunk_size));

    var next_id: usize = 1;
    while (next_id <= edge_count) {
        edges.clearRetainingCapacity();
        const take = @min(chunk_size, edge_count - next_id + 1);
        const end = next_id + take - 1;
        var id = next_id;
        while (id <= end) : (id += 1) {
            try edges.append(allocator, try benchEdgeForId(node_count, edge_count, id, edge_id_pattern));
        }
        try store.appendEdgesBatch(edges.items);
        next_id = end + 1;
    }
}

fn runBenchEdgePostLoadMaintenance(
    io: std.Io,
    store: *storage.Store,
    edge_compact_threshold_entries: u32,
    edge_compact_batch_entries: u32,
) !BenchEdgePostLoadMaintenanceStats {
    store.options.auto_compact_edge_segment_entries = edge_compact_threshold_entries;
    store.options.auto_compact_edge_segment_batch_entries = edge_compact_batch_entries;
    if (edge_compact_threshold_entries == 0) return .{};

    const start = monotonicNs(io);
    var stats = BenchEdgePostLoadMaintenanceStats{};
    while (try store.autoCompactEdgeSegmentsIfNeeded()) {
        stats.compactions = std.math.add(u64, stats.compactions, 1) catch return error.RecordTooLarge;
        if (stats.compactions > std.math.maxInt(u32)) return error.RecordTooLarge;
    }
    stats.ns = elapsedNs(io, start);
    return stats;
}

fn runBenchEdgeTombstoneProbe(
    allocator: std.mem.Allocator,
    io: std.Io,
    store: storage.Store,
    edge_count: usize,
    edge_id_pattern: BenchEdgeIdPattern,
) !BenchEdgeTombstoneProbeStats {
    var stats = BenchEdgeTombstoneProbeStats{
        .requested = @intCast(edge_count / 2),
    };

    var edge_ids = std.ArrayList(core.EdgeId).empty;
    defer edge_ids.deinit(allocator);
    try edge_ids.ensureTotalCapacityPrecise(allocator, @intCast(stats.requested));

    const start = monotonicNs(io);
    var ordinal: usize = 1;
    while (ordinal <= edge_count and stats.deleted < stats.requested) : (ordinal += 1) {
        const edge_id = try benchEdgeIdForPattern(edge_count, ordinal, edge_id_pattern);
        edge_ids.appendAssumeCapacity(core.EdgeId.fromInt(@intCast(edge_id)));
        stats.deleted += 1;
    }
    try store.deleteEdgesBatch(edge_ids.items);
    stats.ns = elapsedNs(io, start);

    const store_stats = try store.stats();
    stats.visible_edges = store_stats.edges;
    stats.tombstone_edges = try store.edgeTombstoneCount();
    stats.physical_edges = std.math.add(u64, stats.visible_edges, stats.tombstone_edges) catch return error.InvalidRecord;
    stats.tombstone_ratio_bps = if (stats.physical_edges == 0)
        0
    else
        @intCast((@as(u128, stats.tombstone_edges) * 10_000) / @as(u128, stats.physical_edges));
    return stats;
}

fn benchEdgeForId(node_count: usize, edge_count: usize, id: usize, edge_id_pattern: BenchEdgeIdPattern) !graph.Edge {
    const edge_id = core.EdgeId.fromInt(@intCast(try benchEdgeIdForPattern(edge_count, id, edge_id_pattern)));
    if (benchHasPositiveReachableFixture(node_count, edge_count)) {
        if (id == edge_count - 1) {
            return .{
                .id = edge_id,
                .src = .fromInt(1),
                .rel = .depends_on,
                .dst = .fromInt(2),
            };
        }
        if (id == edge_count) {
            return .{
                .id = edge_id,
                .src = .fromInt(2),
                .rel = .depends_on,
                .dst = .fromInt(3),
            };
        }
    }
    const src = ((id - 1) % node_count) + 1;
    const dst = (id % node_count) + 1;
    return .{
        .id = edge_id,
        .src = core.NodeId.fromInt(@intCast(src)),
        .rel = .mentions,
        .dst = core.NodeId.fromInt(@intCast(dst)),
    };
}

fn benchEdgeIdForPattern(edge_count: usize, ordinal: usize, pattern: BenchEdgeIdPattern) !usize {
    return switch (pattern) {
        .sequential => ordinal,
        .gap_heavy => if ((ordinal & 1) == 1)
            std.math.add(usize, edge_count, (ordinal + 1) / 2) catch return error.RecordTooLarge
        else
            ordinal / 2,
    };
}

fn benchHasPositiveReachableFixture(node_count: usize, edge_count: usize) bool {
    return node_count >= 3 and edge_count >= 4;
}

/// Shard pool for the kunshan-shaped-corpus workload: prose shards extracted
/// offline from real API documentation (scripts/build_kunshan_shape_corpus.py).
/// Node texts are novel recombinations with word-level mutation, so repeated
/// byte spans stay bounded by the shard size cap instead of whole templates.
const BenchShardPool = struct {
    en_bytes: []u8,
    en_offsets: []u32,
    zh_bytes: []u8,
    zh_offsets: []u32,

    fn deinit(self: *BenchShardPool, allocator: std.mem.Allocator) void {
        allocator.free(self.en_bytes);
        allocator.free(self.en_offsets);
        allocator.free(self.zh_bytes);
        allocator.free(self.zh_offsets);
        self.* = undefined;
    }

    fn shardCount(offsets: []const u32) usize {
        return offsets.len - 1;
    }

    fn shard(bytes: []const u8, offsets: []const u32, index: usize) []const u8 {
        return bytes[offsets[index]..offsets[index + 1]];
    }
};

const bench_shard_pool_max_bytes: u64 = 512 * 1024 * 1024;

fn loadBenchShardPoolFile(allocator: std.mem.Allocator, io: std.Io, dir_path: []const u8, name: []const u8) ![]u8 {
    const path = try std.fs.path.join(allocator, &.{ dir_path, name });
    defer allocator.free(path);
    const stat = try std.Io.Dir.cwd().statFile(io, path, .{});
    if (stat.kind != .file or stat.size == 0 or stat.size > bench_shard_pool_max_bytes) return error.InvalidRecord;
    const bytes = try allocator.alloc(u8, @intCast(stat.size));
    errdefer allocator.free(bytes);
    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    if (try file.readPositionalAll(io, bytes, 0) != bytes.len) return error.InvalidRecord;
    return bytes;
}

fn loadBenchShardPoolOffsets(allocator: std.mem.Allocator, io: std.Io, dir_path: []const u8, name: []const u8, pool_len: usize) ![]u32 {
    const raw = try loadBenchShardPoolFile(allocator, io, dir_path, name);
    defer allocator.free(raw);
    if (raw.len % 4 != 0 or raw.len < 8) return error.InvalidRecord;
    const count = raw.len / 4;
    const offsets = try allocator.alloc(u32, count);
    errdefer allocator.free(offsets);
    var previous: u32 = 0;
    for (offsets, 0..) |*slot, i| {
        const value = std.mem.readInt(u32, raw[i * 4 ..][0..4], .little);
        if (value < previous or value > pool_len) return error.InvalidRecord;
        slot.* = value;
        previous = value;
    }
    if (offsets[0] != 0 or offsets[count - 1] != pool_len) return error.InvalidRecord;
    return offsets;
}

fn loadBenchShardPool(allocator: std.mem.Allocator, io: std.Io, dir_path: []const u8) !BenchShardPool {
    const en_bytes = try loadBenchShardPoolFile(allocator, io, dir_path, "shards_en.bin");
    errdefer allocator.free(en_bytes);
    const en_offsets = try loadBenchShardPoolOffsets(allocator, io, dir_path, "shards_en.idx", en_bytes.len);
    errdefer allocator.free(en_offsets);
    const zh_bytes = try loadBenchShardPoolFile(allocator, io, dir_path, "shards_zh.bin");
    errdefer allocator.free(zh_bytes);
    const zh_offsets = try loadBenchShardPoolOffsets(allocator, io, dir_path, "shards_zh.idx", zh_bytes.len);
    errdefer allocator.free(zh_offsets);
    if (BenchShardPool.shardCount(en_offsets) == 0 or BenchShardPool.shardCount(zh_offsets) == 0) return error.InvalidRecord;
    return .{ .en_bytes = en_bytes, .en_offsets = en_offsets, .zh_bytes = zh_bytes, .zh_offsets = zh_offsets };
}

fn benchKunshanSplitMix(state: *u64) u64 {
    state.* +%= 0x9E3779B97F4A7C15;
    var z = state.*;
    z = (z ^ (z >> 30)) *% 0xBF58476D1CE4E5B9;
    z = (z ^ (z >> 27)) *% 0x94D049BB133111EB;
    return z ^ (z >> 31);
}

/// Kunshan replay node-text length percentiles (docs/bench-ladder.md audit):
/// p50 606, p90 1523, p99 2971, max 8683 bytes; mean ≈ 759. The points are
/// pre-deflated (~0.8×) because the composer overshoots its target by up to
/// one shard plus the fixed header; the same-scale audit pinned the output
/// percentiles onto the real curve at these settings.
const bench_kunshan_len_points = [_][2]f64{
    .{ 0.00, 76 },
    .{ 0.50, 485 },
    .{ 0.90, 1360 },
    .{ 0.99, 2820 },
    .{ 1.00, 8620 },
};

fn benchKunshanTargetLen(rng_state: *u64) usize {
    const unit = @as(f64, @floatFromInt(benchKunshanSplitMix(rng_state) >> 11)) / @as(f64, @floatFromInt(@as(u64, 1) << 53));
    var i: usize = 1;
    while (i < bench_kunshan_len_points.len) : (i += 1) {
        const lo = bench_kunshan_len_points[i - 1];
        const hi = bench_kunshan_len_points[i];
        if (unit <= hi[0]) {
            const t = (unit - lo[0]) / (hi[0] - lo[0]);
            return @intFromFloat(lo[1] + t * (hi[1] - lo[1]));
        }
    }
    return @intFromFloat(bench_kunshan_len_points[bench_kunshan_len_points.len - 1][1]);
}

// Short CJK narrative fragments composed per sentence around English shards
// and identifiers, mirroring agent work-log phrasing. Fragments are word- to
// phrase-sized, so the CJK layer never repeats long byte spans even though
// its bigram vocabulary is deliberately bounded like real agent narrative.
const bench_kunshan_zh_subjects = [_][]const u8{
    "回归测试", "部署预检", "根因分析", "压测结果", "增量索引", "控制面探针", "快照校验",
    "迁移脚本", "日志采样", "内存曲线", "延迟分位", "回滚锚点", "验证节点", "任务前沿",
    "属性负载", "词表构建", "段合并", "守护进程", "检查点导出", "写放大观测", "接口契约",
    "错误记录", "调用链路", "配置漂移", "租约续期", "证据链",
};
const bench_kunshan_zh_verbs = [_][]const u8{
    "确认", "收敛于", "阻塞在", "回退到", "覆盖了", "暴露出", "稳定在", "超过阈值",
    "低于预期", "记录为", "归档到", "验证通过", "失败于", "重跑后恢复", "需要复查",
    "已修复", "待观察", "偏离基线", "对齐到", "触发了",
};
const bench_kunshan_zh_tails = [_][]const u8{
    "后续跟进", "证据已挂接", "另见工单", "与预期一致", "偏差显著", "样本充分",
    "采样不足", "需扩容", "保持观察", "已达标", "尚未闭环", "结论可复用",
};

fn benchKunshanAppendZhSentence(out: *std.ArrayList(u8), allocator: std.mem.Allocator, rng_state: *u64, pool: *const BenchShardPool) !void {
    const subject = bench_kunshan_zh_subjects[benchKunshanSplitMix(rng_state) % bench_kunshan_zh_subjects.len];
    const verb = bench_kunshan_zh_verbs[benchKunshanSplitMix(rng_state) % bench_kunshan_zh_verbs.len];
    try out.appendSlice(allocator, subject);
    try out.appendSlice(allocator, verb);
    switch (benchKunshanSplitMix(rng_state) % 4) {
        0 => {
            // real CJK shard keeps the narrative vocabulary from being purely tabular
            const index = @as(usize, @intCast(benchKunshanSplitMix(rng_state) % BenchShardPool.shardCount(pool.zh_offsets)));
            const shard = BenchShardPool.shard(pool.zh_bytes, pool.zh_offsets, index);
            var take_len = @min(shard.len, 160);
            if (take_len < shard.len) {
                // cut before the codepoint that byte take_len falls inside of
                while (take_len > 0 and (shard[take_len] & 0xC0) == 0x80) take_len -= 1;
            }
            try out.appendSlice(allocator, shard[0..take_len]);
        },
        1 => {
            var buf: [24]u8 = undefined;
            const value = benchKunshanSplitMix(rng_state) % 100_000;
            try out.appendSlice(allocator, std.fmt.bufPrint(&buf, "{d}ms", .{value}) catch unreachable);
        },
        else => {
            const tail = bench_kunshan_zh_tails[benchKunshanSplitMix(rng_state) % bench_kunshan_zh_tails.len];
            try out.appendSlice(allocator, tail);
        },
    }
    try out.appendSlice(allocator, "。");
}

/// Append one English shard with word-level mutation: digit runs re-rolled,
/// roughly one in twenty-four alphabetic words replaced by a seeded token, so
/// heavy shard reuse at gb10 scale never repeats the exact byte span.
fn benchKunshanAppendMutatedEnShard(out: *std.ArrayList(u8), allocator: std.mem.Allocator, rng_state: *u64, pool: *const BenchShardPool) !void {
    const index = @as(usize, @intCast(benchKunshanSplitMix(rng_state) % BenchShardPool.shardCount(pool.en_offsets)));
    const shard = BenchShardPool.shard(pool.en_bytes, pool.en_offsets, index);
    var i: usize = 0;
    while (i < shard.len) {
        const byte = shard[i];
        if (std.ascii.isDigit(byte)) {
            var end = i;
            while (end < shard.len and std.ascii.isDigit(shard[end])) end += 1;
            var digit = i;
            while (digit < end) : (digit += 1) {
                try out.append(allocator, '0' + @as(u8, @intCast(benchKunshanSplitMix(rng_state) % 10)));
            }
            i = end;
            continue;
        }
        if (std.ascii.isAlphabetic(byte)) {
            var end = i;
            while (end < shard.len and std.ascii.isAlphabetic(shard[end])) end += 1;
            if (end - i >= 4 and benchKunshanSplitMix(rng_state) % 48 == 0) {
                var buf: [16]u8 = undefined;
                const token = std.fmt.bufPrint(&buf, "w{x:0>6}", .{benchKunshanSplitMix(rng_state) & 0xFF_FFFF}) catch unreachable;
                try out.appendSlice(allocator, token);
            } else {
                try out.appendSlice(allocator, shard[i..end]);
            }
            i = end;
            continue;
        }
        try out.append(allocator, byte);
        i += 1;
    }
}

fn benchKunshanAppendUniqueRef(out: *std.ArrayList(u8), allocator: std.mem.Allocator, rng_state: *u64) !void {
    var buf: [40]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, " ref=run-{x:0>10}", .{benchKunshanSplitMix(rng_state) & 0xFF_FFFF_FFFF}) catch unreachable;
    try out.appendSlice(allocator, text);
}

/// kunshan-shaped-corpus node text: real-doc shard recombination shaped to the
/// audited Kunshan profile (length percentiles, ~31% CJK byte share, unique
/// per-node identity). The two per-node marker tokens and the sparse probe
/// vocabulary seeded by fixed moduli keep every existing bench probe and gate
/// meaningful without reintroducing template-scale repetition.
fn appendBenchKunshanShapedNodeText(out: *std.ArrayList(u8), allocator: std.mem.Allocator, node_id: usize, pool: *const BenchShardPool) !void {
    var rng_state: u64 = 0x544B_4753 ^ (@as(u64, @intCast(node_id)) *% 0x9E3779B97F4A7C15);
    const start_len = out.items.len;
    const target_len = benchKunshanTargetLen(&rng_state);

    var header_buf: [64]u8 = undefined;
    const header = std.fmt.bufPrint(&header_buf, "benchdoc{d} file/{d}.zig ", .{ node_id, node_id }) catch unreachable;
    try out.appendSlice(allocator, header);
    if (node_id % 3 != 2) try out.appendSlice(allocator, "common ");
    if (node_id % 89 == 0) try out.appendSlice(allocator, "parseInvalidRecord InvalidRecord ");
    if (node_id % 97 == 0) try out.appendSlice(allocator, "错误记录 ");
    if (node_id % 101 == 0) try out.appendSlice(allocator, "エラー解析 ");
    if (node_id % 103 == 0) try out.appendSlice(allocator, "오류 ");
    if (node_id % 107 == 0) try out.appendSlice(allocator, "agent latency budget ");

    while (out.items.len - start_len < target_len) {
        switch (benchKunshanSplitMix(&rng_state) % 16) {
            // Byte-share tuning knob: CJK sentences average far fewer bytes
            // than an English shard, so five double-sentence CJK rounds per
            // sixteen land the audited ~31% non-ASCII byte share.
            0, 1, 2, 3, 4 => {
                try benchKunshanAppendZhSentence(out, allocator, &rng_state, pool);
                try benchKunshanAppendZhSentence(out, allocator, &rng_state, pool);
                try benchKunshanAppendZhSentence(out, allocator, &rng_state, pool);
            },
            5, 6, 7, 8, 9, 10, 11, 12, 13 => {
                try benchKunshanAppendMutatedEnShard(out, allocator, &rng_state, pool);
                try out.append(allocator, ' ');
            },
            else => try benchKunshanAppendUniqueRef(out, allocator, &rng_state),
        }
    }
}

fn benchNodeText(allocator: std.mem.Allocator, node_id: usize, text_source: BenchTextSource) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try appendBenchNodeTextBytes(allocator, &out, node_id, text_source);
    return out.toOwnedSlice(allocator);
}

const BenchGeneratedTextSpan = struct {
    offset: usize,
    len: usize,
};

fn appendBenchNodeTextBytes(allocator: std.mem.Allocator, out: *std.ArrayList(u8), node_id: usize, text_source: BenchTextSource) !void {
    if (text_source.shards) |pool| return appendBenchKunshanShapedNodeText(out, allocator, node_id, pool);
    if (text_source.corpus) |corpus| {
        if (corpus.records.len != 0) return appendBenchCorpusBackedNodeText(out, allocator, node_id, text_source.workload, corpus);
    }
    return switch (text_source.workload) {
        .synthetic_ring => appendBenchSyntheticNodeText(out, allocator, node_id),
        .realistic_agent_text => appendBenchRealisticAgentTextNodeText(out, allocator, node_id),
        .realistic_agent_diverse_text => appendBenchRealisticAgentDiverseTextNodeText(out, allocator, node_id),
        .metaknow_replay => core.Error.Unsupported,
        .metaknow_replay_shaped => core.Error.Unsupported,
        // requires the shard pool; reaching here means it was not loaded
        .kunshan_shaped_corpus => core.Error.Unsupported,
    };
}

fn appendBenchCorpusBackedNodeText(out: *std.ArrayList(u8), allocator: std.mem.Allocator, node_id: usize, workload: BenchWorkload, corpus: *const BenchCorpus) !void {
    const start_len = out.items.len;
    const target_len: usize = if (node_id % 113 == 0) 4096 + ((node_id * 29) % 4096) else 220 + (node_id % 80);
    try out.ensureTotalCapacity(allocator, start_len + target_len + 512);

    var header_buf: [256]u8 = undefined;
    const header = try std.fmt.bufPrint(
        &header_buf,
        "corpus_file=true workload={s} benchdoc{d} name=corpus_case_{x} source=corpus record_count={d} ",
        .{ workload.label(), node_id, node_id, corpus.records.len },
    );
    try out.appendSlice(allocator, header);

    var record_index = (node_id - 1) % corpus.records.len;
    var copied: usize = 0;
    while (out.items.len - start_len < target_len) : ({
        record_index = (record_index + 1) % corpus.records.len;
        copied += 1;
    }) {
        var remaining = target_len - (out.items.len - start_len);
        if (copied != 0) {
            const separator = " | ";
            if (remaining <= separator.len) break;
            try out.appendSlice(allocator, separator);
            remaining -= separator.len;
        }
        const appended = try appendUtf8PrefixAtMost(out, allocator, corpus.records[record_index], remaining);
        if (appended == 0) break;
    }

    var footer_buf: [512]u8 = undefined;
    const footer = try std.fmt.bufPrint(
        &footer_buf,
        " corpus-backed sample node_id={d} common InvalidRecord parseInvalidRecord 错误记录 エラー解析 오류기록.",
        .{node_id},
    );
    try out.appendSlice(allocator, footer);
}

fn appendUtf8PrefixAtMost(out: *std.ArrayList(u8), allocator: std.mem.Allocator, bytes: []const u8, max_bytes: usize) !usize {
    if (max_bytes == 0 or bytes.len == 0) return 0;
    var end = @min(bytes.len, max_bytes);
    while (end > 0 and end < bytes.len and (bytes[end] & 0b1100_0000) == 0b1000_0000) {
        end -= 1;
    }
    if (end == 0) return 0;
    try out.appendSlice(allocator, bytes[0..end]);
    return end;
}

fn appendBenchSyntheticNodeText(out: *std.ArrayList(u8), allocator: std.mem.Allocator, node_id: usize) !void {
    const cjk_suffix: []const u8 = if (benchNodeHasCjkTerms(node_id))
        " 错误-记录 エラー・解析 오류기록 哈哈哈"
    else
        "";
    const english_suffix: []const u8 = if (benchNodeHasEnglishTerms(node_id))
        " agent latency budget retry plan"
    else
        "";
    var buf: [512]u8 = undefined;
    const text = try std.fmt.bufPrint(
        &buf,
        "file/{d}.zig benchdoc{d} common InvalidRecord parseInvalidRecord{s}{s}",
        .{ node_id, node_id, cjk_suffix, english_suffix },
    );
    try out.appendSlice(allocator, text);
}

fn appendBenchRealisticAgentTextNodeText(out: *std.ArrayList(u8), allocator: std.mem.Allocator, node_id: usize) !void {
    if (node_id % 64 == 0) return appendBenchRealisticAgentTextLongNodeText(out, allocator, node_id);

    const cjk_suffix: []const u8 = if (benchNodeHasCjkTerms(node_id))
        " cjk=错误-记录 エラー解析 오류기록;"
    else
        " cjk=none;";
    const english_suffix: []const u8 = if (benchNodeHasEnglishTerms(node_id))
        " agent latency budget retry plan;"
    else
        " checkpoint stable query budget;";
    const decision = switch (node_id % 4) {
        0 => "decision=keep streaming postings for bounded RSS",
        1 => "decision=compress high frequency terms first",
        2 => "decision=selectively index noisy command output",
        else => "decision=record failed bench before ladder change",
    };
    const command = switch (node_id % 3) {
        0 => "cmd=zig build test",
        1 => "cmd=bench_ladder cpu_guard",
        else => "cmd=query MATCH TEXT benchdoc",
    };
    var buf: [1024]u8 = undefined;
    const text = try std.fmt.bufPrint(
        &buf,
        "file/{d}.zig benchdoc{d} common InvalidRecord parseInvalidRecord name=agent_task_{d}. {s}; error=InvalidRecord src/text.zig:{d}; {s} task: reduce BM25 persistent bytes. observation: text_postings.dat and text_terms.idx grew; {s}; test_output: {s}; next: compare meaningful_text_bytes to text_index_overhead_ratio.",
        .{ node_id, node_id, node_id, decision, 1000 + (node_id % 997), english_suffix, cjk_suffix, command },
    );
    try out.appendSlice(allocator, text);
}

fn appendBenchRealisticAgentTextLongNodeText(out: *std.ArrayList(u8), allocator: std.mem.Allocator, node_id: usize) !void {
    const start_len = out.items.len;
    const target_len: usize = 4096 + (node_id % 4096);
    try out.ensureTotalCapacity(allocator, start_len + target_len + 256);

    var header_buf: [256]u8 = undefined;
    const header = try std.fmt.bufPrint(
        &header_buf,
        "file/{d}.zig benchdoc{d} common InvalidRecord parseInvalidRecord name=agent_task_{d} long_context=true source=agent-observation error=InvalidRecord src/text.zig:{d}; ",
        .{ node_id, node_id, node_id, 1000 + (node_id % 997) },
    );
    try out.appendSlice(allocator, header);

    var repeat: usize = 0;
    while (out.items.len - start_len < target_len) : (repeat += 1) {
        var segment_buf: [256]u8 = undefined;
        const segment = try std.fmt.bufPrint(
            &segment_buf,
            " observation_{d}=command zig build test failed with InvalidRecord; path src/text.zig:{d}; decision keep persistent bytes per meaningful_text_bytes bounded; test_output line {d}: expected postings compression and text doc catalog to stay repairable; ",
            .{ repeat, 1200 + ((node_id + repeat) % 997), repeat },
        );
        try out.appendSlice(allocator, segment);
    }
    try out.appendSlice(allocator, " agent retained a long command output and debugging transcript; next compare text_index_overhead_ratio, p99 text bytes, and max text bytes.");
}

fn appendBenchRealisticAgentDiverseTextNodeText(out: *std.ArrayList(u8), allocator: std.mem.Allocator, node_id: usize) !void {
    if (node_id % 97 == 0) return appendBenchRealisticAgentDiverseLongNodeText(out, allocator, node_id);

    const subsystem = switch (node_id % 7) {
        0 => "subsystem=text-index",
        1 => "subsystem=edge-segment",
        2 => "subsystem=repair-export",
        3 => "subsystem=tinyql-render",
        4 => "subsystem=node-texts",
        5 => "subsystem=bench-ladder",
        else => "subsystem=manifest-gc",
    };
    const symptom = switch ((node_id / 7) % 6) {
        0 => "symptom=sporadic p95 lookup spike",
        1 => "symptom=postings temp files grow",
        2 => "symptom=csr endpoint pattern non-affine",
        3 => "symptom=export bundle high rss",
        4 => "symptom=repair rereads manifest",
        else => "symptom=unicode tokenizer fanout",
    };
    const action = switch ((node_id / 17) % 5) {
        0 => "action=rerun guarded local bench",
        1 => "action=price derived catalog field",
        2 => "action=compare naive raw text store",
        3 => "action=keep rejected probe evidence",
        else => "action=validate retained session api",
    };
    const cjk = if (benchNodeHasCjkTerms(node_id))
        " note=错误记录 エラー解析 오류기록;"
    else
        " note=ascii-only trace;";
    var buf: [1024]u8 = undefined;
    const text = try std.fmt.bufPrint(
        &buf,
        "repo=tinykg path=src/{d}/mod_{d}.zig benchdoc{d} name=agent_case_{x}. {s}; {s}; ticket=KG-{d}; symbol=fn_{x}_repair; hash={x:0>8}; {s} observation: {s}; stack: src/storage.zig:{d} -> src/text.zig:{d}; command: zig build test --seed {d}; output: expected density and warm p95 to hold while real text varies; next: {s}.",
        .{
            node_id % 113,
            node_id % 4099,
            node_id,
            node_id,
            subsystem,
            symptom,
            10000 + (node_id % 90000),
            node_id % 65521,
            @as(u64, node_id) *% 2654435761,
            cjk,
            action,
            200 + (node_id % 7000),
            900 + ((node_id * 13) % 7000),
            node_id % 1000003,
            action,
        },
    );
    try out.appendSlice(allocator, text);
}

fn appendBenchRealisticAgentDiverseLongNodeText(out: *std.ArrayList(u8), allocator: std.mem.Allocator, node_id: usize) !void {
    const start_len = out.items.len;
    const target_len: usize = 4096 + ((node_id * 37) % 4096);
    try out.ensureTotalCapacity(allocator, start_len + target_len + 256);

    var header_buf: [256]u8 = undefined;
    const header = try std.fmt.bufPrint(
        &header_buf,
        "repo=tinykg path=incident/{d}/session_{d}.log benchdoc{d} name=agent_long_case_{x} long_context=true source=mixed-agent-session; ",
        .{ node_id % 251, node_id % 8191, node_id, node_id },
    );
    try out.appendSlice(allocator, header);

    var repeat: usize = 0;
    while (out.items.len - start_len < target_len) : (repeat += 1) {
        const lane = switch ((node_id + repeat) % 6) {
            0 => "lookup retained session reopened after manifest publish",
            1 => "csr endpoint stream changed from affine to sparse ids",
            2 => "BM25 term payload mixed code identifiers and stderr",
            3 => "repair export must avoid holding bundle text in RSS",
            4 => "operator noted battery run cannot promote GB10 evidence",
            else => "CJK tokenizer emitted 错误记录 エラー解析 오류기록 tokens",
        };
        var segment_buf: [320]u8 = undefined;
        const segment = try std.fmt.bufPrint(
            &segment_buf,
            " event_{d}=node {d} {s}; file src/{d}/case_{d}.zig line {d}; digest={x:0>8}; command_output='zig test shard {d} failed then passed'; decision=derive predictable facts only when query and repair can synthesize them; ",
            .{
                repeat,
                node_id,
                lane,
                (node_id + repeat) % 197,
                (node_id * 31 + repeat) % 10007,
                100 + ((node_id + repeat * 7) % 9000),
                (@as(u64, node_id) *% 11400714819323198485) +% repeat,
                repeat % 128,
            },
        );
        try out.appendSlice(allocator, segment);
    }
    try out.appendSlice(allocator, " long mixed trace with code, logs, decisions, observations, and repair/export notes; keep p99 and max meaningful_text_bytes visible.");
}

fn benchSearchQuery(allocator: std.mem.Allocator, node_id: usize) ![]u8 {
    return std.fmt.allocPrint(allocator, "benchdoc{d}", .{node_id});
}

fn benchPathSearchQuery(allocator: std.mem.Allocator, node_id: usize) ![]u8 {
    return std.fmt.allocPrint(allocator, "file/{d}.zig", .{node_id});
}

fn benchNodeHasCjkTerms(node_id: usize) bool {
    return node_id == 1 or node_id % 257 == 0;
}

fn benchNodeHasEnglishTerms(node_id: usize) bool {
    return node_id == 1 or node_id % 263 == 0;
}

fn freeBenchNodeTexts(allocator: std.mem.Allocator, nodes: []const graph.Node) void {
    for (nodes) |node| allocator.free(node.text);
}

fn corruptBenchTextPostings(allocator: std.mem.Allocator, io: std.Io, db_path: []const u8) !void {
    const postings_path = try std.fs.path.join(allocator, &.{ db_path, "text_postings.dat" });
    defer allocator.free(postings_path);
    try std.Io.Dir.cwd().writeFile(io, .{
        .sub_path = postings_path,
        .data = "bad",
        .flags = .{ .truncate = true },
    });
}

fn staleBenchTextMeta(allocator: std.mem.Allocator, io: std.Io, db_path: []const u8) !void {
    const meta_path = try std.fs.path.join(allocator, &.{ db_path, "text_meta.idx" });
    defer allocator.free(meta_path);

    var file = try std.Io.Dir.cwd().openFile(io, meta_path, .{ .mode = .read_write });
    defer file.close(io);

    var node_digest: [8]u8 = [_]u8{0} ** 8;
    try file.writePositionalAll(io, &node_digest, 8);
}

fn monotonicNs(io: std.Io) u128 {
    const timestamp = std.Io.Clock.awake.now(io).nanoseconds;
    return if (timestamp < 0) 0 else @intCast(timestamp);
}

fn persistentNowNs(io: std.Io) u128 {
    const timestamp = std.Io.Clock.real.now(io).nanoseconds;
    return if (timestamp < 0) 0 else @intCast(timestamp);
}

fn elapsedNs(io: std.Io, start: u128) u128 {
    const now = monotonicNs(io);
    return if (now >= start) now - start else 0;
}

const BenchRssSample = struct {
    peak_bytes: u64,
    current_bytes: u64,
    footprint_bytes: u64,
};

const BenchTextRebuildPhaseRss = struct {
    docs_progress_max: BenchRssSample = .{ .peak_bytes = 0, .current_bytes = 0, .footprint_bytes = 0 },
    docs: BenchRssSample = .{ .peak_bytes = 0, .current_bytes = 0, .footprint_bytes = 0 },
    run_finish: BenchRssSample = .{ .peak_bytes = 0, .current_bytes = 0, .footprint_bytes = 0 },
    scratch_release: BenchRssSample = .{ .peak_bytes = 0, .current_bytes = 0, .footprint_bytes = 0 },
    open_docs: BenchRssSample = .{ .peak_bytes = 0, .current_bytes = 0, .footprint_bytes = 0 },
    catalog: BenchRssSample = .{ .peak_bytes = 0, .current_bytes = 0, .footprint_bytes = 0 },
    meta: BenchRssSample = .{ .peak_bytes = 0, .current_bytes = 0, .footprint_bytes = 0 },
};

const BenchOrderedEdgeTraversalStats = struct {
    ns: u128 = 0,
    rows: usize = 0,
};

const BenchPhaseStoreBytes = struct {
    create: u64 = 0,
    add_node: u64 = 0,
    add_edge: u64 = 0,
    edge_maintenance: u64 = 0,
    query: u64 = 0,
    store_deinit: u64 = 0,
    open: u64 = 0,
    validate: u64 = 0,
    repair: u64 = 0,
    text_rebuild: u64 = 0,
};

fn maxBenchRssSample(lhs: BenchRssSample, rhs: BenchRssSample) BenchRssSample {
    return .{
        .peak_bytes = @max(lhs.peak_bytes, rhs.peak_bytes),
        .current_bytes = @max(lhs.current_bytes, rhs.current_bytes),
        .footprint_bytes = @max(lhs.footprint_bytes, rhs.footprint_bytes),
    };
}

fn maxTextRebuildPhaseFootprintBytes(samples: BenchTextRebuildPhaseRss) u64 {
    var max_bytes: u64 = 0;
    inline for (&[_]BenchRssSample{
        samples.docs_progress_max,
        samples.docs,
        samples.run_finish,
        samples.scratch_release,
        samples.open_docs,
        samples.catalog,
        samples.meta,
    }) |sample| {
        max_bytes = @max(max_bytes, sample.footprint_bytes);
    }
    return max_bytes;
}

fn maxBenchFootprintBytes(samples: []const BenchRssSample, text_rebuild_phase_rss: BenchTextRebuildPhaseRss) u64 {
    var max_bytes = maxTextRebuildPhaseFootprintBytes(text_rebuild_phase_rss);
    for (samples) |sample| max_bytes = @max(max_bytes, sample.footprint_bytes);
    return max_bytes;
}

fn benchRssSample() !BenchRssSample {
    return .{
        .peak_bytes = try peakRssBytes(),
        .current_bytes = try currentRssBytes(),
        .footprint_bytes = try currentFootprintBytes(),
    };
}

fn sampleTextRebuildPhaseRss(context: *anyopaque, phase: text_search.PersistentTextRebuildPhase) !void {
    const samples: *BenchTextRebuildPhaseRss = @ptrCast(@alignCast(context));
    const sample = try benchRssSample();
    switch (phase) {
        .docs_progress => samples.docs_progress_max = maxBenchRssSample(samples.docs_progress_max, sample),
        .docs => {
            samples.docs = sample;
            samples.docs_progress_max = maxBenchRssSample(samples.docs_progress_max, sample);
        },
        .run_finish => samples.run_finish = sample,
        .scratch_release => samples.scratch_release = sample,
        .open_docs => samples.open_docs = sample,
        .catalog => samples.catalog = sample,
        .meta => samples.meta = sample,
    }
}

fn rebuildPersistentTextCatalogForBenchWithPhaseRss(
    allocator: std.mem.Allocator,
    store: storage.Store,
    runs_base_path: []const u8,
    phase_rss: *BenchTextRebuildPhaseRss,
) !text_search.PersistentTextRebuildBenchResult {
    return try text_search.rebuildPersistentTextCatalogWithTimingsAndObserverForBench(allocator, store, runs_base_path, .{
        .context = phase_rss,
        .observe = sampleTextRebuildPhaseRss,
    });
}

fn benchOrderedEdgeTraversalProbe(allocator: std.mem.Allocator, io: std.Io, store: storage.Store) !BenchOrderedEdgeTraversalStats {
    const start = monotonicNs(io);
    var records = try store.readEdgeIndexRecordsByNodeOrdered(allocator, .fromInt(1));
    defer records.deinit(allocator);
    return .{
        .ns = elapsedNs(io, start),
        .rows = records.items.len,
    };
}

fn benchEdgeOrderBytes(allocator: std.mem.Allocator, io: std.Io, db_path: []const u8) !u64 {
    const path = try std.fs.path.join(allocator, &.{ db_path, "edge_order.idx" });
    defer allocator.free(path);
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return 0,
        else => |e| return e,
    };
    if (stat.kind != .file) return error.InvalidRecord;
    return stat.size;
}

fn appendBenchOrderedEdgeMetrics(out: *QueryOutputWriter, edge_order_bytes: u64, ordered_edge_traversal: BenchOrderedEdgeTraversalStats) !void {
    const overhead = if (edge_order_bytes >= storage.edge_order_header_bytes) edge_order_bytes - storage.edge_order_header_bytes else 0;
    try out.print(
        "edge_order_bytes={} edge_order_header_bytes={} edge_order_overhead_bytes={} ordered_edge_traversal_ns={} ordered_edge_traversal_rows={}\n",
        .{
            edge_order_bytes,
            storage.edge_order_header_bytes,
            overhead,
            ordered_edge_traversal.ns,
            ordered_edge_traversal.rows,
        },
    );
}

fn benchTextPostingRunsBasePath(allocator: std.mem.Allocator, db_path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}.text_posting_runs", .{db_path});
}

fn appendBenchPhaseRss(
    out: *QueryOutputWriter,
    create_rss: BenchRssSample,
    add_node_rss: BenchRssSample,
    add_edge_rss: BenchRssSample,
    edge_post_load_maintenance_rss: BenchRssSample,
    query_rss: ?BenchRssSample,
    store_deinit_rss: BenchRssSample,
    open_rss: BenchRssSample,
    validate_rss: BenchRssSample,
    repair_rss: BenchRssSample,
    text_rebuild_rss: BenchRssSample,
) !void {
    const query_peak = if (query_rss) |sample| sample.peak_bytes else 0;
    const query_current = if (query_rss) |sample| sample.current_bytes else 0;
    const query_footprint = if (query_rss) |sample| sample.footprint_bytes else 0;
    try out.print(
        "bench_phase_create_rss_bytes={} bench_phase_create_current_rss_bytes={} bench_phase_add_node_rss_bytes={} bench_phase_add_node_current_rss_bytes={} bench_phase_add_edge_rss_bytes={} bench_phase_add_edge_current_rss_bytes={} bench_phase_edge_maintenance_rss_bytes={} bench_phase_edge_maintenance_current_rss_bytes={} bench_phase_query_rss_bytes={} bench_phase_query_current_rss_bytes={} bench_phase_store_deinit_rss_bytes={} bench_phase_store_deinit_current_rss_bytes={} bench_phase_open_rss_bytes={} bench_phase_open_current_rss_bytes={} bench_phase_validate_rss_bytes={} bench_phase_validate_current_rss_bytes={} bench_phase_repair_rss_bytes={} bench_phase_repair_current_rss_bytes={} bench_phase_text_rebuild_rss_bytes={} bench_phase_text_rebuild_current_rss_bytes={}\n",
        .{
            create_rss.peak_bytes,
            create_rss.current_bytes,
            add_node_rss.peak_bytes,
            add_node_rss.current_bytes,
            add_edge_rss.peak_bytes,
            add_edge_rss.current_bytes,
            edge_post_load_maintenance_rss.peak_bytes,
            edge_post_load_maintenance_rss.current_bytes,
            query_peak,
            query_current,
            store_deinit_rss.peak_bytes,
            store_deinit_rss.current_bytes,
            open_rss.peak_bytes,
            open_rss.current_bytes,
            validate_rss.peak_bytes,
            validate_rss.current_bytes,
            repair_rss.peak_bytes,
            repair_rss.current_bytes,
            text_rebuild_rss.peak_bytes,
            text_rebuild_rss.current_bytes,
        },
    );
    try out.print(
        "bench_phase_create_footprint_bytes={} bench_phase_add_node_footprint_bytes={} bench_phase_add_edge_footprint_bytes={} bench_phase_edge_maintenance_footprint_bytes={} bench_phase_query_footprint_bytes={} bench_phase_store_deinit_footprint_bytes={} bench_phase_open_footprint_bytes={} bench_phase_validate_footprint_bytes={} bench_phase_repair_footprint_bytes={} bench_phase_text_rebuild_footprint_bytes={}\n",
        .{
            create_rss.footprint_bytes,
            add_node_rss.footprint_bytes,
            add_edge_rss.footprint_bytes,
            edge_post_load_maintenance_rss.footprint_bytes,
            query_footprint,
            store_deinit_rss.footprint_bytes,
            open_rss.footprint_bytes,
            validate_rss.footprint_bytes,
            repair_rss.footprint_bytes,
            text_rebuild_rss.footprint_bytes,
        },
    );
}

fn appendBenchPhaseStoreBytes(out: *QueryOutputWriter, samples: BenchPhaseStoreBytes) !void {
    try out.print(
        "bench_phase_create_store_dir_bytes={} bench_phase_add_node_store_dir_bytes={} bench_phase_add_edge_store_dir_bytes={} bench_phase_edge_maintenance_store_dir_bytes={} bench_phase_query_store_dir_bytes={} bench_phase_store_deinit_store_dir_bytes={} bench_phase_open_store_dir_bytes={} bench_phase_validate_store_dir_bytes={} bench_phase_repair_store_dir_bytes={} bench_phase_text_rebuild_store_dir_bytes={}\n",
        .{
            samples.create,
            samples.add_node,
            samples.add_edge,
            samples.edge_maintenance,
            samples.query,
            samples.store_deinit,
            samples.open,
            samples.validate,
            samples.repair,
            samples.text_rebuild,
        },
    );
}

fn saturatingSubNs(total: u128, subtrahend: u128) u128 {
    return if (total >= subtrahend) total - subtrahend else 0;
}

fn perOpNs(total_ns: u128, count: usize) u128 {
    if (count == 0) return 0;
    return total_ns / @as(u128, @intCast(count));
}

fn benchStoreOverheadBps(store_bytes: u64, meaningful_text_bytes: u64, edge_count: u64) !u128 {
    const logical_edge_bytes = std.math.mul(u64, edge_count, 16) catch return error.RecordTooLarge;
    const denominator = std.math.add(u64, meaningful_text_bytes, logical_edge_bytes) catch return error.RecordTooLarge;
    return ratioBpsU128(store_bytes, @max(denominator, 1));
}

const BenchDensityBreakdown = struct {
    total_edge_count: u64 = 0,
    projection_edge_count: u64 = 0,
    domain_edge_count: u64 = 0,
    tombstone_edge_count: u64 = 0,
    node_property_bytes: u64 = 0,
    edge_property_bytes: u64 = 0,
    property_payload_index_bytes: u64 = 0,
    property_payload_value_bytes: u64 = 0,
    property_payload_delta_bytes: u64 = 0,

    fn logicalEdgeBytes(count: u64) !u64 {
        return std.math.mul(u64, count, 16) catch return error.RecordTooLarge;
    }

    fn propertyPayloadBytes(self: BenchDensityBreakdown) !u64 {
        var total = self.node_property_bytes;
        total = std.math.add(u64, total, self.edge_property_bytes) catch return error.RecordTooLarge;
        total = std.math.add(u64, total, self.property_payload_index_bytes) catch return error.RecordTooLarge;
        total = std.math.add(u64, total, self.property_payload_value_bytes) catch return error.RecordTooLarge;
        total = std.math.add(u64, total, self.property_payload_delta_bytes) catch return error.RecordTooLarge;
        return total;
    }
};

fn benchDensityBreakdown(
    allocator: std.mem.Allocator,
    io: std.Io,
    db_path: []const u8,
    store: storage.Store,
    stats_out: storage.StoreStats,
) !BenchDensityBreakdown {
    var breakdown = BenchDensityBreakdown{
        .total_edge_count = stats_out.edges,
        .tombstone_edge_count = try store.edgeTombstoneCount(),
    };

    const EdgeContext = struct {
        breakdown: *BenchDensityBreakdown,

        fn visit(raw: *anyopaque, record: storage.EdgeIndexRecord) !void {
            const context: *@This() = @ptrCast(@alignCast(raw));
            const rel = try record.relKind();
            if (isMarkdownProjectionRel(rel)) {
                context.breakdown.projection_edge_count = std.math.add(u64, context.breakdown.projection_edge_count, 1) catch return error.RecordTooLarge;
            } else {
                context.breakdown.domain_edge_count = std.math.add(u64, context.breakdown.domain_edge_count, 1) catch return error.RecordTooLarge;
            }
        }
    };
    var edge_context = EdgeContext{ .breakdown = &breakdown };
    _ = try store.scanVisibleEdgeIndexRecords(allocator, &edge_context, EdgeContext.visit);

    breakdown.node_property_bytes += try benchStoreFileSizeOrZero(allocator, io, db_path, "node_props.idx");
    breakdown.node_property_bytes += try benchStoreFileSizeOrZero(allocator, io, db_path, "node_props.values");
    breakdown.node_property_bytes += try benchStoreFileSizeOrZero(allocator, io, db_path, "node_props_overlay.idx");
    breakdown.node_property_bytes += try benchStoreFileSizeOrZero(allocator, io, db_path, "node_props_overlay.values");
    breakdown.edge_property_bytes += try benchStoreFileSizeOrZero(allocator, io, db_path, "edge_props_overlay.idx");
    breakdown.edge_property_bytes += try benchStoreFileSizeOrZero(allocator, io, db_path, "edge_props_overlay.values");
    breakdown.property_payload_index_bytes = try benchStoreFileSizeOrZero(allocator, io, db_path, "property_payload.idx");
    breakdown.property_payload_value_bytes = try benchStoreFileSizeOrZero(allocator, io, db_path, "property_payload.values");
    breakdown.property_payload_delta_bytes = try benchStoreFileSizeOrZero(allocator, io, db_path, "property_payload.delta");
    return breakdown;
}

fn benchStoreFileSizeOrZero(allocator: std.mem.Allocator, io: std.Io, db_path: []const u8, file_name: []const u8) !u64 {
    return (try storeFileSize(allocator, io, db_path, file_name)) orelse 0;
}

fn evaluateBenchNoRegressionGates(
    limits: BenchNoRegressionGateLimits,
    search_ns: u128,
    neighbors_ns: u128,
    tinyql_expand_p95_ns: u128,
    tinyql_context_render_p95_ns: u128,
    path_ns: u128,
    store_overhead_bps: u128,
) BenchNoRegressionGateResult {
    return .{
        .search_passed = if (limits.max_search_ns) |max_ns| search_ns <= max_ns else true,
        .neighbors_passed = if (limits.max_neighbors_ns) |max_ns| neighbors_ns <= max_ns else true,
        .tinyql_expand_passed = if (limits.max_tinyql_expand_p95_ns) |max_ns| tinyql_expand_p95_ns <= max_ns else true,
        .tinyql_context_render_passed = if (limits.max_tinyql_context_render_p95_ns) |max_ns| tinyql_context_render_p95_ns <= max_ns else true,
        .path_passed = if (limits.max_path_ns) |max_ns| path_ns <= max_ns else true,
        .store_overhead_passed = if (limits.max_store_overhead_bps) |max_bps| store_overhead_bps <= max_bps else true,
    };
}

fn appendBenchNoRegressionGateMetrics(
    out: *QueryOutputWriter,
    limits: BenchNoRegressionGateLimits,
    result: BenchNoRegressionGateResult,
    search_ns: u128,
    neighbors_ns: u128,
    tinyql_expand_p95_ns: u128,
    tinyql_context_render_p95_ns: u128,
    path_ns: u128,
    store_overhead_bps: u128,
) !void {
    try out.print(
        "no_regression_gate enabled={} search_ns={} max_search_ns_enabled={} max_search_ns={} search_passed={} neighbors_ns={} max_neighbors_ns_enabled={} max_neighbors_ns={} neighbors_passed={} tinyql_expand_p95_ns={} max_tinyql_expand_p95_ns_enabled={} max_tinyql_expand_p95_ns={} tinyql_expand_passed={} tinyql_context_render_p95_ns={} max_tinyql_context_render_p95_ns_enabled={} max_tinyql_context_render_p95_ns={} tinyql_context_render_passed={} path_ns={} max_path_ns_enabled={} max_path_ns={} path_passed={} store_overhead_bps={} max_store_overhead_bps_enabled={} max_store_overhead_bps={} store_overhead_passed={} passed={}\n",
        .{
            @intFromBool(limits.enabled()),
            search_ns,
            @intFromBool(limits.max_search_ns != null),
            limits.max_search_ns orelse 0,
            @intFromBool(result.search_passed),
            neighbors_ns,
            @intFromBool(limits.max_neighbors_ns != null),
            limits.max_neighbors_ns orelse 0,
            @intFromBool(result.neighbors_passed),
            tinyql_expand_p95_ns,
            @intFromBool(limits.max_tinyql_expand_p95_ns != null),
            limits.max_tinyql_expand_p95_ns orelse 0,
            @intFromBool(result.tinyql_expand_passed),
            tinyql_context_render_p95_ns,
            @intFromBool(limits.max_tinyql_context_render_p95_ns != null),
            limits.max_tinyql_context_render_p95_ns orelse 0,
            @intFromBool(result.tinyql_context_render_passed),
            path_ns,
            @intFromBool(limits.max_path_ns != null),
            limits.max_path_ns orelse 0,
            @intFromBool(result.path_passed),
            store_overhead_bps,
            @intFromBool(limits.max_store_overhead_bps != null),
            limits.max_store_overhead_bps orelse 0,
            @intFromBool(result.store_overhead_passed),
            @intFromBool(result.passed()),
        },
    );
}

fn appendBenchDensityMetrics(
    out: *QueryOutputWriter,
    text_density: *const BenchTextDensityStats,
    store_bytes: u64,
    text_index_bytes: BenchTextIndexBytes,
    edge_segments_bytes: BenchEdgeSegmentBytes,
    node_texts_compression: BenchNodeTextsCompressionEstimate,
    posting_compression: text_search.PersistentPostingCompressionEstimate,
    density_breakdown: BenchDensityBreakdown,
) !void {
    const logical_edge_bytes = try BenchDensityBreakdown.logicalEdgeBytes(density_breakdown.total_edge_count);
    const logical_projection_edge_bytes = try BenchDensityBreakdown.logicalEdgeBytes(density_breakdown.projection_edge_count);
    const logical_domain_edge_bytes = try BenchDensityBreakdown.logicalEdgeBytes(density_breakdown.domain_edge_count);
    const logical_tombstone_edge_bytes = try BenchDensityBreakdown.logicalEdgeBytes(density_breakdown.tombstone_edge_count);
    const property_payload_bytes = try density_breakdown.propertyPayloadBytes();
    const meaningful_plus_edges = std.math.add(u64, text_density.meaningful_text_bytes, logical_edge_bytes) catch return error.RecordTooLarge;
    const edge_segment_control_bytes = try edge_segments_bytes.controlBytes();
    const edge_segment_physical_bytes = try edge_segments_bytes.physicalBytes();
    const node_texts_deflate_store_bytes = if (store_bytes >= node_texts_compression.raw_bytes)
        std.math.add(u64, store_bytes - node_texts_compression.raw_bytes, node_texts_compression.total_bytes) catch return error.RecordTooLarge
    else
        store_bytes;
    try out.print(
        "meaningful_text_bytes={}\nmeaningful_text_bytes_per_node_p10={}\nmeaningful_text_bytes_per_node_p50={}\nmeaningful_text_bytes_per_node_p90={}\nmeaningful_text_bytes_per_node_p99={}\nmeaningful_text_bytes_per_node_max={}\ntext_index_bytes={}\nedge_segments_bytes={}\nlogical_edge_bytes={}\nprojection_edge_count={} logical_projection_edge_bytes={}\ndomain_edge_count={} logical_domain_edge_bytes={}\ntombstone_edge_count={} logical_tombstone_edge_bytes={}\nproperty_payload_bytes={} node_property_bytes={} edge_property_bytes={} property_payload_index_bytes={} property_payload_value_bytes={} property_payload_delta_bytes={}\n",
        .{
            text_density.meaningful_text_bytes,
            text_density.percentile(10),
            text_density.percentile(50),
            text_density.percentile(90),
            text_density.percentile(99),
            text_density.max_meaningful_text_bytes,
            text_index_bytes.total,
            edge_segments_bytes.total,
            logical_edge_bytes,
            density_breakdown.projection_edge_count,
            logical_projection_edge_bytes,
            density_breakdown.domain_edge_count,
            logical_domain_edge_bytes,
            density_breakdown.tombstone_edge_count,
            logical_tombstone_edge_bytes,
            property_payload_bytes,
            density_breakdown.node_property_bytes,
            density_breakdown.edge_property_bytes,
            density_breakdown.property_payload_index_bytes,
            density_breakdown.property_payload_value_bytes,
            density_breakdown.property_payload_delta_bytes,
        },
    );
    try out.print(
        "edge_segments_data_bytes={} edge_segments_sidecar_bytes={} edge_segments_other_bytes={} edge_segments_files={} edge_segments_dirs={}\n",
        .{
            edge_segments_bytes.data,
            edge_segments_bytes.sidecar,
            edge_segments_bytes.other,
            edge_segments_bytes.files,
            edge_segments_bytes.dirs,
        },
    );
    try out.print(
        "edge_segment_manifest_bytes={} edge_segment_current_bytes={} edge_segment_control_bytes={} edge_segment_physical_bytes={} edge_segment_manifest_files={} edge_segment_current_files={}\n",
        .{
            edge_segments_bytes.manifest,
            edge_segments_bytes.current,
            edge_segment_control_bytes,
            edge_segment_physical_bytes,
            edge_segments_bytes.manifest_files,
            edge_segments_bytes.current_files,
        },
    );
    try out.print(
        "edge_segment_csr_header_bytes={} edge_segment_csr_vertex_bytes={} edge_segment_csr_relation_bytes={} edge_segment_csr_edge_bytes={} edge_segment_csr_files={} edge_segment_csr_edge_count={} edge_segment_csr_vertex_count={} edge_segment_csr_relation_count={} edge_segment_csr_derived_edge_id_files={} edge_segment_csr_split_derived_edge_id_files={} edge_segment_csr_derived_vertex_id_files={} edge_segment_csr_split_derived_vertex_id_files={} edge_segment_csr_derived_edge_other_node_files={} edge_segment_csr_split_derived_edge_other_node_files={}\n",
        .{
            edge_segments_bytes.csr_header,
            edge_segments_bytes.csr_vertex,
            edge_segments_bytes.csr_relation,
            edge_segments_bytes.csr_edge,
            edge_segments_bytes.csr_files,
            edge_segments_bytes.csr_edge_count,
            edge_segments_bytes.csr_vertex_count,
            edge_segments_bytes.csr_relation_count,
            edge_segments_bytes.csr_derived_edge_id_files,
            edge_segments_bytes.csr_split_derived_edge_id_files,
            edge_segments_bytes.csr_derived_vertex_id_files,
            edge_segments_bytes.csr_split_derived_vertex_id_files,
            edge_segments_bytes.csr_derived_edge_other_node_files,
            edge_segments_bytes.csr_split_derived_edge_other_node_files,
        },
    );
    try out.print(
        "node_texts_bytes={} node_texts_logical_bytes={} node_texts_deflate_block_bytes={} node_texts_deflate_block_payload_bytes={} node_texts_deflate_block_count={} node_texts_deflate_block_saved_bytes={} node_texts_deflate_block_size={} node_texts_deflate_level={}\n",
        .{
            node_texts_compression.raw_bytes,
            node_texts_compression.logical_bytes,
            node_texts_compression.total_bytes,
            node_texts_compression.payload_bytes,
            node_texts_compression.block_count,
            node_texts_compression.saved_bytes,
            bench_node_texts_deflate_block_bytes,
            storage.Store.node_texts_block_deflate_level_number,
        },
    );
    try out.print(
        "text_index_meta_bytes={} text_index_docs_bytes={} text_index_terms_bytes={} text_index_postings_bytes={} text_index_blocks_bytes={} text_index_impacts_bytes={} text_index_top_hits_bytes={}\n",
        .{
            text_index_bytes.meta,
            text_index_bytes.docs,
            text_index_bytes.terms,
            text_index_bytes.postings,
            text_index_bytes.blocks,
            text_index_bytes.impacts,
            text_index_bytes.top_hits,
        },
    );
    try out.print(
        "text_terms_header_bytes={} text_terms_entry_bytes={} text_terms_front_coded_bytes={} text_terms_offset_checkpoint_bytes={} text_terms_exception_bytes={} text_terms_singleton_checkpoint_bytes={} text_terms_singleton_payload_bytes={} text_terms_term_count={} text_terms_exception_count={} text_terms_singleton_count={} text_terms_offset_checkpoint_count={} text_terms_singleton_checkpoint_count={}\n",
        .{
            text_index_bytes.terms_header,
            text_index_bytes.terms_entries,
            text_index_bytes.terms_front_coded,
            text_index_bytes.terms_offset_checkpoints,
            text_index_bytes.terms_exceptions,
            text_index_bytes.terms_singleton_checkpoints,
            text_index_bytes.terms_singleton_payload,
            text_index_bytes.terms_term_count,
            text_index_bytes.terms_exception_count,
            text_index_bytes.terms_singleton_count,
            text_index_bytes.terms_offset_checkpoint_count,
            text_index_bytes.terms_singleton_checkpoint_count,
        },
    );
    try out.print(
        "text_postings_fixed_record_bytes={} text_postings_delta_varint_estimated_bytes={} text_postings_delta_varint_doc_bytes={} text_postings_elias_fano_doc_estimated_bytes={} text_postings_hybrid_doc_estimated_bytes={} text_postings_material_field_tag_bits_estimated_bytes={} text_postings_material_block_jump_checkpoint_bytes={} text_postings_material_hybrid_format_bits_bytes={} text_postings_material_elias_fano_select_checkpoint_bytes={} text_postings_material_hybrid_select_checkpoint_bytes={} text_postings_elias_fano_material_estimated_bytes={} text_postings_hybrid_material_estimated_bytes={} text_postings_elias_fano_material_with_select_estimated_bytes={} text_postings_hybrid_material_with_select_estimated_bytes={} text_postings_hybrid_select_aware_doc_with_select_estimated_bytes={} text_postings_hybrid_select_aware_material_estimated_bytes={} text_postings_hybrid_select_aware_ef_terms={} text_postings_hybrid_select_aware_delta_terms={} text_postings_singleton_inline_count={} text_postings_singleton_inline_saved_bytes={} text_postings_virtual_all_docs_terms={} text_postings_virtual_all_docs_saved_bytes={}\n",
        .{
            posting_compression.fixed_record_bytes,
            posting_compression.delta_varint_estimated_bytes,
            posting_compression.delta_varint_doc_bytes,
            posting_compression.elias_fano_doc_estimated_bytes,
            posting_compression.hybrid_doc_estimated_bytes,
            posting_compression.material_field_tag_bits_estimated_bytes,
            posting_compression.material_block_jump_checkpoint_bytes,
            posting_compression.material_hybrid_format_bits_bytes,
            posting_compression.material_elias_fano_select_checkpoint_bytes,
            posting_compression.material_hybrid_select_checkpoint_bytes,
            posting_compression.elias_fano_material_estimated_bytes,
            posting_compression.hybrid_material_estimated_bytes,
            posting_compression.elias_fano_material_with_select_estimated_bytes,
            posting_compression.hybrid_material_with_select_estimated_bytes,
            posting_compression.hybrid_select_aware_doc_with_select_estimated_bytes,
            posting_compression.hybrid_select_aware_material_estimated_bytes,
            posting_compression.hybrid_select_aware_ef_term_count,
            posting_compression.hybrid_select_aware_delta_term_count,
            posting_compression.singleton_inline_posting_count,
            posting_compression.singleton_inline_saved_bytes,
            posting_compression.virtual_all_docs_term_count,
            posting_compression.virtual_all_docs_saved_bytes,
        },
    );
    try out.print(
        "text_postings_dense_all_docs_freq_stream_terms={} text_postings_dense_all_docs_freq_stream_saved_bytes={} text_postings_elias_fano_better_terms={} text_postings_elias_fano_worse_terms={} text_postings_delta_varint_field_mask_bytes={} text_postings_delta_varint_text_freq_bytes={} text_postings_delta_varint_kind_freq_bytes={} text_postings_max_doc_delta={} text_postings_max_text_freq={} text_postings_max_kind_freq={} text_postings_doc_delta_over_u16={} text_postings_text_freq_over_u8={}\n",
        .{
            posting_compression.dense_all_docs_freq_stream_term_count,
            posting_compression.dense_all_docs_freq_stream_saved_bytes,
            posting_compression.elias_fano_better_term_count,
            posting_compression.elias_fano_worse_term_count,
            posting_compression.delta_varint_field_mask_bytes,
            posting_compression.delta_varint_text_freq_bytes,
            posting_compression.delta_varint_kind_freq_bytes,
            posting_compression.max_doc_delta,
            posting_compression.max_text_freq,
            posting_compression.max_kind_freq,
            posting_compression.doc_delta_over_u16_count,
            posting_compression.text_freq_over_u8_count,
        },
    );
    try appendRatioMetric(out, "text_index_overhead_ratio", text_index_bytes.total, @max(text_density.meaningful_text_bytes, 1));
    try appendRatioMetric(out, "edge_segments_over_logical_edge_ratio", edge_segments_bytes.total, @max(logical_edge_bytes, 1));
    try appendRatioMetric(out, "edge_segment_physical_over_logical_edge_ratio", edge_segment_physical_bytes, @max(logical_edge_bytes, 1));
    try appendRatioMetric(out, "node_texts_physical_over_logical_ratio", node_texts_compression.raw_bytes, @max(node_texts_compression.logical_bytes, 1));
    try appendRatioMetric(out, "node_texts_deflate_overhead_ratio", node_texts_compression.total_bytes, @max(node_texts_compression.logical_bytes, 1));
    try appendRatioMetric(out, "store_overhead_ratio", store_bytes, @max(meaningful_plus_edges, 1));
    try appendRatioMetric(out, "store_overhead_ratio_if_node_texts_deflate", node_texts_deflate_store_bytes, @max(meaningful_plus_edges, 1));
}

fn appendRatioMetric(out: *QueryOutputWriter, comptime key: []const u8, numerator: u64, denominator: u64) !void {
    try out.print("{s}=", .{key});
    try appendRatioValue(out, numerator, denominator);
}

fn appendRatioValue(out: *QueryOutputWriter, numerator: u64, denominator: u64) !void {
    const scale: u128 = 1_000_000;
    const scaled = (@as(u128, numerator) * scale) / @as(u128, denominator);
    try out.print("{d}.{d:0>6}\n", .{ scaled / scale, scaled % scale });
}

fn isStoreControlEntry(name: []const u8) bool {
    return std.mem.eql(u8, name, cli_store_lock_suffix) or
        std.mem.eql(u8, name, backup_transaction_marker_file) or
        std.mem.eql(u8, name, import_transaction_marker_file) or
        std.mem.eql(u8, name, restore_transaction_marker_file) or
        std.mem.eql(u8, name, store_migration_transaction_marker_file) or
        std.mem.eql(u8, name, schema_migration_transaction_marker_file) or
        std.mem.eql(u8, name, backup_transaction_marker_file ++ ".tmp") or
        std.mem.eql(u8, name, import_transaction_marker_file ++ ".tmp") or
        std.mem.eql(u8, name, restore_transaction_marker_file ++ ".tmp") or
        std.mem.eql(u8, name, store_migration_transaction_marker_file ++ ".tmp") or
        std.mem.eql(u8, name, schema_migration_transaction_marker_file ++ ".tmp");
}

const NativeJsonlNodeJson = struct {
    id: u64,
    kind: []const u8,
    text: []const u8,
    schema_type: ?[]const u8 = null,
    status: ?[]const u8 = null,
    claimed_by: ?[]const u8 = null,
    claim_expires_ns: ?u64 = null,
    task_recorded_ns: ?u64 = null,
    task_created_ns: ?u64 = null,
    task_completed_ns: ?u64 = null,
};

const NativeJsonlEdgeJson = struct {
    id: u64,
    src: u64,
    rel: []const u8,
    dst: u64,
};

const CountingProjectionSink = struct {
    allocator: std.mem.Allocator,
    bytes: usize = 0,

    fn writeAll(self: *CountingProjectionSink, bytes: []const u8) !void {
        self.bytes = std.math.add(usize, self.bytes, bytes.len) catch return error.RecordTooLarge;
    }

    fn print(self: *CountingProjectionSink, comptime fmt: []const u8, args: anytype) !void {
        const text = try std.fmt.allocPrint(self.allocator, fmt, args);
        defer self.allocator.free(text);
        try self.writeAll(text);
    }
};

fn parseCliNodeKind(label: []const u8) ?core.NodeKind {
    if (core.parseNodeKind(label)) |kind| return kind;
    if (std.ascii.eqlIgnoreCase(label, "note")) return .observation;
    if (std.mem.startsWith(u8, label, "type#")) {
        const id = std.fmt.parseInt(u16, label["type#".len..], 10) catch return null;
        return @enumFromInt(id);
    }
    return null;
}

fn projectionsNeedPersistentNodes(projections: []const ql.ast.Projection) bool {
    for (projections) |projection| {
        switch (projection) {
            .variable, .property, .path, .context => return true,
            .reachable, .score => {},
        }
    }
    return false;
}

fn parseCliRelKind(label: []const u8) ?core.RelKind {
    if (core.parseRelKind(label)) |rel| return rel;
    if (schema.markdownProjectionRelationIdByName(label)) |id| return @enumFromInt(id);
    if (std.ascii.eqlIgnoreCase(label, "supports")) return .evidences;
    if (std.mem.startsWith(u8, label, "rel#")) {
        const id = std.fmt.parseInt(u16, label["rel#".len..], 10) catch return null;
        return @enumFromInt(id);
    }
    return null;
}

fn initTaskStatusProjectionSnapshot(
    allocator: std.mem.Allocator,
    store: storage.Store,
    node_view: ?*storage.Store.NodeRecordView,
    rows: []const ql.executor.Row,
    projections: []const ql.ast.Projection,
) !?task.StatusSnapshot {
    var status_vars = std.ArrayList([]const u8).empty;
    defer status_vars.deinit(allocator);
    for (projections) |projection| switch (projection) {
        .property => |property| {
            if (std.mem.eql(u8, property.property, task.status_property)) {
                try status_vars.append(allocator, property.var_name);
            }
        },
        else => {},
    };
    if (status_vars.items.len == 0 or rows.len == 0) return null;

    const view = node_view orelse return error.InvalidPlan;
    var seen = std.AutoHashMap(u64, void).init(allocator);
    defer seen.deinit();
    var task_ids = std.ArrayList(core.NodeId).empty;
    defer task_ids.deinit(allocator);
    for (rows) |row| {
        for (status_vars.items) |var_name| {
            const node_id = row.get(var_name) orelse continue;
            const entry = try seen.getOrPut(node_id.toInt());
            if (entry.found_existing) continue;
            const node_ref = (try view.readNodeRefById(node_id)) orelse return error.InvalidRecord;
            if (node_ref.kind == .task) try task_ids.append(allocator, node_id);
        }
    }
    if (task_ids.items.len == 0) return null;
    return try task.StatusSnapshot.initForNodeIds(allocator, store, task_ids.items);
}

const NativeJsonlDeferredBasedOnJson = struct {
    src: u64,
    dst: u64,
};

fn u128ToU64(value: u128) !u64 {
    return std.math.cast(u64, value) orelse error.RecordTooLarge;
}

fn writeProjectionPersistent(
    writer: anytype,
    allocator: std.mem.Allocator,
    store: storage.Store,
    edge_retention_registry: ?*storage.EdgeSegmentRetentionRegistry,
    node_view: ?*storage.Store.NodeRecordView,
    status_snapshot: ?*const task.StatusSnapshot,
    read_timestamp_ns: u64,
    row: ql.executor.Row,
    projection: ql.ast.Projection,
    budget: core.QueryBudget,
    projection_stats: ?*query_index.QueryStats,
) !void {
    switch (projection) {
        .variable => |var_name| {
            const id = row.get(var_name) orelse {
                try writer.writeAll("null");
                return;
            };
            var node = (try readRenderNodeById(allocator, store, node_view, id)) orelse return error.InvalidRecord;
            defer node.deinit(allocator);
            try writer.print("{}:", .{node.id.toInt()});
            try writeNodeKindName(writer, node.kind);
            try writer.writeAll(":");
            try writeEscapedText(writer, markdownProjectionVisibleText(node.text));
        },
        .property => |property| {
            const id = row.get(property.var_name) orelse {
                try writer.writeAll("null");
                return;
            };
            var node = (try readRenderNodeById(allocator, store, node_view, id)) orelse return error.InvalidRecord;
            defer node.deinit(allocator);
            if (std.mem.eql(u8, property.property, "text")) {
                try writeEscapedText(writer, node.text);
            } else if (std.mem.eql(u8, property.property, task.status_property)) {
                if (node.kind == .task) {
                    const lifecycle = if (status_snapshot) |snapshot| lifecycle: {
                        if (!snapshot.covers(id)) return error.InvalidRecord;
                        break :lifecycle try snapshot.statusForStoredNode(node, read_timestamp_ns);
                    } else try task.statusForStoredNode(allocator, store, node, read_timestamp_ns);
                    try writer.writeAll(@tagName(lifecycle));
                } else {
                    const string_value = try store.getNodeStringProperty(allocator, id, property.property);
                    defer if (string_value) |owned| allocator.free(owned);
                    if (string_value) |owned| {
                        try writeEscapedText(writer, owned);
                    } else if (try store.getUintProperty(allocator, .{ .node = id }, property.property)) |uint_value| {
                        try writer.print("{}", .{uint_value});
                    } else {
                        try writer.writeAll("null");
                    }
                }
            } else if (std.mem.eql(u8, property.property, "name") or
                std.mem.eql(u8, property.property, "summary") or
                std.mem.eql(u8, property.property, "retrieval_hints") or
                std.mem.eql(u8, property.property, "schema_type") or
                std.mem.eql(u8, property.property, "claimed_by") or
                std.mem.eql(u8, property.property, "external_key") or
                std.mem.eql(u8, property.property, "content_hash") or
                std.mem.eql(u8, property.property, "task_event_type") or
                std.mem.eql(u8, property.property, "dependency_relation"))
            {
                const value = try store.getNodeStringProperty(allocator, id, property.property);
                defer if (value) |owned| allocator.free(owned);
                if (value) |owned| {
                    try writeEscapedText(writer, owned);
                } else if (std.mem.eql(u8, property.property, "name") or std.mem.eql(u8, property.property, "summary")) {
                    try writer.writeAll("");
                } else {
                    try writer.writeAll("null");
                }
            } else if (std.mem.eql(u8, property.property, "task_recorded_ns") or
                std.mem.eql(u8, property.property, "task_created_ns") or
                std.mem.eql(u8, property.property, "task_completed_ns") or
                std.mem.eql(u8, property.property, "claim_expires_ns") or
                std.mem.eql(u8, property.property, "task_event_ns") or
                std.mem.eql(u8, property.property, "task_root_id") or
                std.mem.eql(u8, property.property, "task_id"))
            {
                if (try store.getUintProperty(allocator, .{ .node = id }, property.property)) |value| {
                    try writer.print("{}", .{value});
                } else {
                    try writer.writeAll("null");
                }
            } else {
                const string_value = try store.getNodeStringProperty(allocator, id, property.property);
                defer if (string_value) |owned| allocator.free(owned);
                if (string_value) |owned| {
                    try writeEscapedText(writer, owned);
                } else if (try store.getUintProperty(allocator, .{ .node = id }, property.property)) |uint_value| {
                    try writer.print("{}", .{uint_value});
                } else {
                    try writer.writeAll("null");
                }
            }
        },
        .path => |path| {
            const nodes = row.getPath(path.from_var, path.to_var) orelse {
                try writer.writeAll("null");
                return;
            };
            for (nodes, 0..) |node_id, i| {
                var node = (try readRenderNodeById(allocator, store, node_view, node_id)) orelse return error.InvalidRecord;
                node.deinit(allocator);
                if (i > 0) try writer.writeAll(" -> ");
                try writer.print("{}", .{node_id.toInt()});
            }
        },
        .reachable => |reachable| {
            const from = row.get(reachable.from_var) orelse {
                try writer.writeAll("null");
                return;
            };
            const to = row.get(reachable.to_var) orelse {
                try writer.writeAll("null");
                return;
            };
            const value = if (projection_stats) |stats| blk: {
                if (edge_retention_registry) |registry| {
                    break :blk try dag.reachableWithPersistentStoreMeasuredRetained(allocator, store, registry, from, to, reachable.rel, budget, stats);
                }
                break :blk try dag.reachableWithPersistentStoreMeasured(allocator, store, from, to, reachable.rel, budget, stats);
            } else blk: {
                if (edge_retention_registry) |registry| {
                    break :blk try dag.reachableWithPersistentStoreRetained(allocator, store, registry, from, to, reachable.rel, budget);
                }
                break :blk try dag.reachableWithPersistentStore(allocator, store, from, to, reachable.rel, budget);
            };
            try writer.writeAll(if (value) "true" else "false");
        },
        .context => |context| {
            const focus = row.get(context.var_name) orelse {
                try writer.writeAll("null");
                return;
            };
            var packet = if (projection_stats) |stats| blk: {
                if (edge_retention_registry) |registry| {
                    break :blk try agent.contextPacketWithPersistentStoreMeasuredRetained(allocator, store, registry, focus, 8, budget, stats);
                }
                break :blk try agent.contextPacketWithPersistentStoreMeasured(allocator, store, focus, 8, budget, stats);
            } else blk: {
                if (edge_retention_registry) |registry| {
                    break :blk try agent.contextPacketWithPersistentStoreBudgetRetained(allocator, store, registry, focus, 8, budget);
                }
                break :blk try agent.contextPacketWithPersistentStoreBudget(allocator, store, focus, 8, budget);
            };
            defer packet.deinit(allocator);
            var emitted: usize = 0;
            for (packet.facts.items) |fact| {
                {
                    var node = (try readRenderNodeById(allocator, store, node_view, fact.node_id)) orelse return error.InvalidRecord;
                    defer node.deinit(allocator);
                    if (emitted > 0) try writer.writeAll(",");
                    try writeRelKindName(writer, fact.rel);
                    try writer.print(":{s}:{}:", .{ @tagName(fact.direction), fact.node_id.toInt() });
                    try writeEscapedText(writer, node.text);
                    try writer.print(":{}", .{
                        fact.score,
                    });
                    emitted += 1;
                }
            }
        },
        .score => |score| {
            if (row.getScore(score.var_name)) |value| {
                try writer.print("{d:.6}", .{value});
            } else {
                try writer.writeAll("null");
            }
        },
    }
}

fn readRenderNodeById(
    allocator: std.mem.Allocator,
    store: storage.Store,
    node_view: ?*storage.Store.NodeRecordView,
    id: core.NodeId,
) !?storage.StoredNode {
    if (node_view) |view| return try view.readNodeById(allocator, id);
    return try store.readNodeById(allocator, id);
}

fn writeNodeKindName(writer: anytype, kind: core.NodeKind) !void {
    inline for (@typeInfo(core.NodeKind).@"enum".fields) |field| {
        if (@intFromEnum(kind) == field.value) return writer.writeAll(field.name);
    }
    try writer.print("type#{}", .{@intFromEnum(kind)});
}

fn writeEscapedText(writer: anytype, text: []const u8) !void {
    for (text) |byte| {
        switch (byte) {
            '\\' => try writer.writeAll("\\\\"),
            ':' => try writer.writeAll("\\:"),
            ',' => try writer.writeAll("\\,"),
            '\t' => try writer.writeAll("\\t"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            0x00...0x08, 0x0b...0x0c, 0x0e...0x1f, 0x7f => try writer.print("\\x{x:0>2}", .{byte}),
            else => try writer.writeAll(&.{byte}),
        }
    }
}

fn markdownProjectionVisibleText(text: []const u8) []const u8 {
    return text;
}

fn writeRelKindName(writer: anytype, rel: core.RelKind) !void {
    inline for (@typeInfo(core.RelKind).@"enum".fields) |field| {
        if (@intFromEnum(rel) == field.value) return writer.writeAll(field.name);
    }
    if (schema.markdownProjectionRelationNameById(@intFromEnum(rel))) |name| return writer.writeAll(name);
    try writer.print("rel#{}", .{@intFromEnum(rel)});
}

fn storeDirBytesAtDepth(allocator: std.mem.Allocator, io: std.Io, db_path: []const u8, is_root: bool) !u64 {
    var dir = try std.Io.Dir.cwd().openDir(io, db_path, .{ .iterate = true });
    defer dir.close(io);
    var iter = dir.iterate();
    var total: u64 = 0;
    while (try iter.next(io)) |entry| {
        if (is_root and isStoreControlEntry(entry.name)) continue;
        const full_path = try std.fs.path.join(allocator, &.{ db_path, entry.name });
        defer allocator.free(full_path);
        switch (entry.kind) {
            .file => {
                const stat = try std.Io.Dir.cwd().statFile(io, full_path, .{});
                total = std.math.add(u64, total, stat.size) catch return error.RecordTooLarge;
            },
            .directory => {
                const child_total = try storeDirBytesAtDepth(allocator, io, full_path, false);
                total = std.math.add(u64, total, child_total) catch return error.RecordTooLarge;
            },
            else => {},
        }
    }
    return total;
}

fn storeDirBytes(allocator: std.mem.Allocator, io: std.Io, db_path: []const u8) !u64 {
    return storeDirBytesAtDepth(allocator, io, db_path, true);
}

const BenchEdgeSegmentBytes = struct {
    total: u64 = 0,
    data: u64 = 0,
    sidecar: u64 = 0,
    other: u64 = 0,
    manifest: u64 = 0,
    current: u64 = 0,
    files: u64 = 0,
    dirs: u64 = 0,
    manifest_files: u64 = 0,
    current_files: u64 = 0,
    csr_header: u64 = 0,
    csr_vertex: u64 = 0,
    csr_relation: u64 = 0,
    csr_edge: u64 = 0,
    csr_edge_count: u64 = 0,
    csr_vertex_count: u64 = 0,
    csr_relation_count: u64 = 0,
    csr_files: u64 = 0,
    csr_derived_edge_id_files: u64 = 0,
    csr_split_derived_edge_id_files: u64 = 0,
    csr_derived_vertex_id_files: u64 = 0,
    csr_split_derived_vertex_id_files: u64 = 0,
    csr_derived_edge_other_node_files: u64 = 0,
    csr_split_derived_edge_other_node_files: u64 = 0,

    fn controlBytes(self: BenchEdgeSegmentBytes) !u64 {
        return std.math.add(u64, self.manifest, self.current) catch return error.RecordTooLarge;
    }

    fn physicalBytes(self: BenchEdgeSegmentBytes) !u64 {
        return std.math.add(u64, self.total, try self.controlBytes()) catch return error.RecordTooLarge;
    }

    fn addSegmentFile(self: *BenchEdgeSegmentBytes, leaf: []const u8, size: u64) !void {
        self.total = std.math.add(u64, self.total, size) catch return error.RecordTooLarge;
        self.files = std.math.add(u64, self.files, 1) catch return error.RecordTooLarge;
        if (std.mem.eql(u8, leaf, "edge_ids.idx")) {
            self.sidecar = std.math.add(u64, self.sidecar, size) catch return error.RecordTooLarge;
        } else if (std.mem.eql(u8, leaf, "edge_fwd.csr") or std.mem.eql(u8, leaf, "edge_rev.csr")) {
            self.data = std.math.add(u64, self.data, size) catch return error.RecordTooLarge;
        } else {
            self.other = std.math.add(u64, self.other, size) catch return error.RecordTooLarge;
        }
    }

    fn addCsrStats(self: *BenchEdgeSegmentBytes, stats: segment_mod.CsrFileByteStats) !void {
        self.csr_header = std.math.add(u64, self.csr_header, stats.header_bytes) catch return error.RecordTooLarge;
        self.csr_vertex = std.math.add(u64, self.csr_vertex, stats.vertex_bytes) catch return error.RecordTooLarge;
        self.csr_relation = std.math.add(u64, self.csr_relation, stats.relation_bytes) catch return error.RecordTooLarge;
        self.csr_edge = std.math.add(u64, self.csr_edge, stats.edge_bytes) catch return error.RecordTooLarge;
        self.csr_edge_count = std.math.add(u64, self.csr_edge_count, stats.edge_count) catch return error.RecordTooLarge;
        self.csr_vertex_count = std.math.add(u64, self.csr_vertex_count, stats.vertex_count) catch return error.RecordTooLarge;
        self.csr_relation_count = std.math.add(u64, self.csr_relation_count, stats.relation_count) catch return error.RecordTooLarge;
        self.csr_files = std.math.add(u64, self.csr_files, 1) catch return error.RecordTooLarge;
        if (stats.derived_edge_ids) {
            self.csr_derived_edge_id_files = std.math.add(u64, self.csr_derived_edge_id_files, 1) catch return error.RecordTooLarge;
        }
        if (stats.split_derived_edge_ids) {
            self.csr_split_derived_edge_id_files = std.math.add(u64, self.csr_split_derived_edge_id_files, 1) catch return error.RecordTooLarge;
        }
        if (stats.derived_vertex_ids) {
            self.csr_derived_vertex_id_files = std.math.add(u64, self.csr_derived_vertex_id_files, 1) catch return error.RecordTooLarge;
        }
        if (stats.split_derived_vertex_ids) {
            self.csr_split_derived_vertex_id_files = std.math.add(u64, self.csr_split_derived_vertex_id_files, 1) catch return error.RecordTooLarge;
        }
        if (stats.derived_edge_other_nodes) {
            self.csr_derived_edge_other_node_files = std.math.add(u64, self.csr_derived_edge_other_node_files, 1) catch return error.RecordTooLarge;
        }
        if (stats.split_derived_edge_other_nodes) {
            self.csr_split_derived_edge_other_node_files = std.math.add(u64, self.csr_split_derived_edge_other_node_files, 1) catch return error.RecordTooLarge;
        }
    }
};

fn benchEdgeSegmentBytes(allocator: std.mem.Allocator, io: std.Io, db_path: []const u8) !BenchEdgeSegmentBytes {
    var bytes = BenchEdgeSegmentBytes{};
    const edge_segments_path = try std.fs.path.join(allocator, &.{ db_path, "edge_segments" });
    defer allocator.free(edge_segments_path);
    try benchEdgeSegmentSubtreeBytes(allocator, io, edge_segments_path, &bytes);
    try benchEdgeSegmentControlBytes(allocator, io, db_path, &bytes);
    return bytes;
}

fn benchEdgeSegmentSubtreeBytes(allocator: std.mem.Allocator, io: std.Io, path: []const u8, bytes: *BenchEdgeSegmentBytes) !void {
    var dir = std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => |e| return e,
    };
    defer dir.close(io);

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        const full_path = try std.fs.path.join(allocator, &.{ path, entry.name });
        defer allocator.free(full_path);
        switch (entry.kind) {
            .file => {
                const stat = try std.Io.Dir.cwd().statFile(io, full_path, .{});
                try bytes.addSegmentFile(entry.name, stat.size);
                if (std.mem.eql(u8, entry.name, "edge_fwd.csr") or std.mem.eql(u8, entry.name, "edge_rev.csr")) {
                    const stats = segment_mod.csrFileByteStats(io, full_path) catch |err| switch (err) {
                        error.InvalidRecord => null,
                        else => |e| return e,
                    };
                    if (stats) |csr_stats| try bytes.addCsrStats(csr_stats);
                }
            },
            .directory => {
                bytes.dirs = std.math.add(u64, bytes.dirs, 1) catch return error.RecordTooLarge;
                try benchEdgeSegmentSubtreeBytes(allocator, io, full_path, bytes);
            },
            else => {},
        }
    }
}

fn benchEdgeSegmentControlBytes(allocator: std.mem.Allocator, io: std.Io, db_path: []const u8, bytes: *BenchEdgeSegmentBytes) !void {
    var dir = std.Io.Dir.cwd().openDir(io, db_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => |e| return e,
    };
    defer dir.close(io);

    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const full_path = try std.fs.path.join(allocator, &.{ db_path, entry.name });
        defer allocator.free(full_path);
        const stat = try std.Io.Dir.cwd().statFile(io, full_path, .{});
        if (std.mem.eql(u8, entry.name, "edge_segment_current")) {
            bytes.current = std.math.add(u64, bytes.current, stat.size) catch return error.RecordTooLarge;
            bytes.current_files = std.math.add(u64, bytes.current_files, 1) catch return error.RecordTooLarge;
        } else if (std.mem.eql(u8, entry.name, "edge_segment.manifest") or std.mem.startsWith(u8, entry.name, "edge_segment.manifest.")) {
            bytes.manifest = std.math.add(u64, bytes.manifest, stat.size) catch return error.RecordTooLarge;
            bytes.manifest_files = std.math.add(u64, bytes.manifest_files, 1) catch return error.RecordTooLarge;
        }
    }
}

const BenchTextIndexFileKind = enum {
    meta,
    docs,
    terms,
    postings,
    blocks,
    impacts,
    top_hits,
};

const BenchTextIndexFile = struct {
    name: []const u8,
    kind: BenchTextIndexFileKind,
};

const bench_text_index_files = [_]BenchTextIndexFile{
    .{ .name = "text_meta.idx", .kind = .meta },
    .{ .name = "text_docs.idx", .kind = .docs },
    .{ .name = "text_terms.idx", .kind = .terms },
    .{ .name = "text_postings.dat", .kind = .postings },
    .{ .name = "text_posting_blocks.idx", .kind = .blocks },
    .{ .name = "text_posting_block_impacts.idx", .kind = .impacts },
    .{ .name = "text_term_top_hits.idx", .kind = .top_hits },
};

const BenchTextIndexBytes = struct {
    total: u64 = 0,
    meta: u64 = 0,
    docs: u64 = 0,
    terms: u64 = 0,
    postings: u64 = 0,
    blocks: u64 = 0,
    impacts: u64 = 0,
    top_hits: u64 = 0,
    terms_header: u64 = 0,
    terms_entries: u64 = 0,
    terms_front_coded: u64 = 0,
    terms_offset_checkpoints: u64 = 0,
    terms_exceptions: u64 = 0,
    terms_singleton_checkpoints: u64 = 0,
    terms_singleton_payload: u64 = 0,
    terms_term_count: u64 = 0,
    terms_exception_count: u64 = 0,
    terms_singleton_count: u64 = 0,
    terms_offset_checkpoint_count: u64 = 0,
    terms_singleton_checkpoint_count: u64 = 0,
};

const bench_node_texts_deflate_block_bytes: usize = storage.Store.node_texts_block_deflate_block_bytes;

const bench_node_texts_deflate_block_header_len: usize = 16;

const bench_node_texts_deflate_block_header_bytes: u64 = bench_node_texts_deflate_block_header_len;

const bench_node_texts_deflate_block_index_entry_bytes: u64 = 4;

const BenchNodeTextsCompressionEstimate = struct {
    raw_bytes: u64 = 0,
    logical_bytes: u64 = 0,
    payload_bytes: u64 = 0,
    total_bytes: u64 = 0,
    block_count: u64 = 0,
    saved_bytes: u64 = 0,
};

const bench_node_texts_deflate_magic = [_]u8{ 'T', 'K', 'N', 'Z' };

const bench_node_texts_deflate_version: u16 = storage.Store.node_texts_block_deflate_version;

fn benchTextIndexBytes(allocator: std.mem.Allocator, io: std.Io, db_path: []const u8) !BenchTextIndexBytes {
    var bytes = BenchTextIndexBytes{};
    for (bench_text_index_files) |file_info| {
        const full_path = try std.fs.path.join(allocator, &.{ db_path, file_info.name });
        defer allocator.free(full_path);
        const stat = std.Io.Dir.cwd().statFile(io, full_path, .{}) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        bytes.total = std.math.add(u64, bytes.total, stat.size) catch return error.RecordTooLarge;
        switch (file_info.kind) {
            .meta => bytes.meta = stat.size,
            .docs => bytes.docs = stat.size,
            .terms => {
                bytes.terms = stat.size;
                const stats = try text_search.readPersistentTextTermsByteStatsAtPath(io, full_path);
                bytes.terms_header = stats.header_bytes;
                bytes.terms_entries = stats.entry_bytes;
                bytes.terms_front_coded = stats.front_coded_bytes;
                bytes.terms_offset_checkpoints = stats.offset_checkpoint_bytes;
                bytes.terms_exceptions = stats.exception_bytes;
                bytes.terms_singleton_checkpoints = stats.singleton_checkpoint_bytes;
                bytes.terms_singleton_payload = stats.singleton_payload_bytes;
                bytes.terms_term_count = stats.term_count;
                bytes.terms_exception_count = stats.exception_count;
                bytes.terms_singleton_count = stats.singleton_count;
                bytes.terms_offset_checkpoint_count = stats.offset_checkpoint_count;
                bytes.terms_singleton_checkpoint_count = stats.singleton_checkpoint_count;
            },
            .postings => bytes.postings = stat.size,
            .blocks => bytes.blocks = stat.size,
            .impacts => bytes.impacts = stat.size,
            .top_hits => bytes.top_hits = stat.size,
        }
    }
    return bytes;
}

fn benchNodeTextsCompressionEstimate(allocator: std.mem.Allocator, io: std.Io, db_path: []const u8) !BenchNodeTextsCompressionEstimate {
    const path = try std.fs.path.join(allocator, &.{ db_path, "node_texts.dat" });
    defer allocator.free(path);
    const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return .{},
        else => return err,
    };
    if (stat.size == 0) return .{};

    var file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    if (try benchCompressedNodeTextsEstimate(io, file, stat.size)) |estimate| return estimate;

    var input = try allocator.alloc(u8, bench_node_texts_deflate_block_bytes);
    defer allocator.free(input);
    const output = try allocator.alloc(u8, bench_node_texts_deflate_block_bytes * 2 + 1024);
    defer allocator.free(output);
    const flate_buffer = try allocator.alloc(u8, std.compress.flate.max_window_len);
    defer allocator.free(flate_buffer);

    var estimate = BenchNodeTextsCompressionEstimate{
        .raw_bytes = stat.size,
        .logical_bytes = stat.size,
    };
    var offset: u64 = 0;
    while (offset < stat.size) {
        const remaining = stat.size - offset;
        const want: usize = @intCast(@min(remaining, bench_node_texts_deflate_block_bytes));
        const n = try file.readPositionalAll(io, input[0..want], offset);
        if (n != want) return error.InvalidRecord;
        const compressed_len = benchDeflateBlockLen(input[0..want], output, flate_buffer);
        const stored_len = @min(compressed_len, want);
        estimate.payload_bytes = std.math.add(u64, estimate.payload_bytes, @intCast(stored_len)) catch return error.RecordTooLarge;
        estimate.block_count = std.math.add(u64, estimate.block_count, 1) catch return error.RecordTooLarge;
        offset = std.math.add(u64, offset, want) catch return error.RecordTooLarge;
    }
    const block_dir_bytes = std.math.mul(u64, estimate.block_count, bench_node_texts_deflate_block_index_entry_bytes) catch return error.RecordTooLarge;
    const metadata_bytes = std.math.add(u64, bench_node_texts_deflate_block_header_bytes, block_dir_bytes) catch return error.RecordTooLarge;
    estimate.total_bytes = std.math.add(u64, estimate.payload_bytes, metadata_bytes) catch return error.RecordTooLarge;
    estimate.saved_bytes = if (estimate.raw_bytes > estimate.total_bytes) estimate.raw_bytes - estimate.total_bytes else 0;
    return estimate;
}

fn benchCompressedNodeTextsEstimate(io: std.Io, file: std.Io.File, file_size: u64) !?BenchNodeTextsCompressionEstimate {
    if (file_size < bench_node_texts_deflate_block_header_bytes) return null;
    var header: [bench_node_texts_deflate_block_header_len]u8 = undefined;
    const n = try file.readPositionalAll(io, &header, 0);
    if (n != header.len) return error.InvalidRecord;
    if (!std.mem.eql(u8, header[0..4], &bench_node_texts_deflate_magic)) return null;
    if (std.mem.readInt(u16, header[4..6], .little) != bench_node_texts_deflate_version) return null;
    if (std.mem.readInt(u16, header[6..8], .little) != bench_node_texts_deflate_block_header_bytes) return null;

    const logical_bytes = std.mem.readInt(u64, header[8..16], .little);
    const block_count: u64 = if (logical_bytes == 0)
        0
    else
        (std.math.add(u64, logical_bytes, bench_node_texts_deflate_block_bytes - 1) catch return error.RecordTooLarge) / bench_node_texts_deflate_block_bytes;
    const directory_bytes = std.math.mul(u64, block_count, bench_node_texts_deflate_block_index_entry_bytes) catch return error.RecordTooLarge;
    const metadata_bytes = std.math.add(u64, bench_node_texts_deflate_block_header_bytes, directory_bytes) catch return error.RecordTooLarge;
    if (file_size < metadata_bytes) return error.InvalidRecord;
    return .{
        .raw_bytes = file_size,
        .logical_bytes = logical_bytes,
        .payload_bytes = file_size - metadata_bytes,
        .total_bytes = file_size,
        .block_count = block_count,
        .saved_bytes = if (logical_bytes > file_size) logical_bytes - file_size else 0,
    };
}

fn benchDeflateBlockLen(input: []const u8, output: []u8, flate_buffer: []u8) usize {
    var fixed: std.Io.Writer = .fixed(output);
    var compressor = std.compress.flate.Compress.init(&fixed, flate_buffer, .raw, storage.Store.node_texts_block_deflate_level) catch return input.len;
    compressor.writer.writeAll(input) catch return input.len;
    compressor.finish() catch return input.len;
    return fixed.buffered().len;
}

fn peakRssBytes() !u64 {
    if (!builtin.link_libc) return 0;
    return switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos => peakRssFromGetrusage(.bytes),
        .linux, .freebsd, .openbsd, .netbsd, .dragonfly => peakRssFromGetrusage(.kib),
        else => 0,
    };
}

fn currentRssBytes() !u64 {
    if (!builtin.link_libc) return 0;
    return switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos => currentRssFromDarwinTaskInfo(),
        .linux => currentRssFromLinuxStatm(),
        else => 0,
    };
}

fn currentFootprintBytes() !u64 {
    return switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos => currentFootprintFromDarwinTaskInfo(),
        else => 0,
    };
}

const RssUnit = enum { bytes, kib };

fn peakRssFromGetrusage(unit: RssUnit) !u64 {
    var usage: std.c.rusage = undefined;
    if (std.c.getrusage(0, &usage) != 0) return error.SystemResourceUnavailable;
    if (usage.maxrss <= 0) return 0;
    const maxrss: u64 = @intCast(usage.maxrss);
    return switch (unit) {
        .bytes => maxrss,
        .kib => std.math.mul(u64, maxrss, 1024) catch return error.RecordTooLarge,
    };
}

fn currentRssFromDarwinTaskInfo() !u64 {
    const task_port = std.c.mach_task_self();
    if (task_port == std.c.TASK.NULL) return 0;
    var info_count = std.c.TASK.VM.INFO_COUNT;
    var vm_info: std.c.task_vm_info_data_t = undefined;
    const rc = std.c.task_info(
        task_port,
        std.c.TASK.VM.INFO,
        @as(std.c.task_info_t, @ptrCast(&vm_info)),
        &info_count,
    );
    if (rc != 0) return error.SystemResourceUnavailable;
    return @intCast(vm_info.resident_size);
}

fn currentFootprintFromDarwinTaskInfo() !u64 {
    const task_port = std.c.mach_task_self();
    if (task_port == std.c.TASK.NULL) return 0;
    var info_count = std.c.TASK.VM.INFO_COUNT;
    var vm_info: std.c.task_vm_info_data_t = undefined;
    const rc = std.c.task_info(
        task_port,
        std.c.TASK.VM.INFO,
        @as(std.c.task_info_t, @ptrCast(&vm_info)),
        &info_count,
    );
    if (rc != 0) return error.SystemResourceUnavailable;
    return @intCast(vm_info.phys_footprint);
}

fn currentRssFromLinuxStatm() !u64 {
    const file = std.c.fopen("/proc/self/statm", "rb") orelse return 0;
    defer _ = std.c.fclose(file);

    var buf: [128]u8 = undefined;
    const n = std.c.fread(buf[0..].ptr, 1, buf.len, file);
    var it = std.mem.tokenizeScalar(u8, buf[0..n], ' ');
    _ = it.next() orelse return error.InvalidRecord;
    const resident_pages_text = it.next() orelse return error.InvalidRecord;
    const resident_pages = std.fmt.parseInt(u64, resident_pages_text, 10) catch return error.InvalidRecord;
    return std.math.mul(u64, resident_pages, std.heap.pageSize()) catch return error.RecordTooLarge;
}

/// Full benchmark execution subsystem behind the stable CLI façade.
pub const BenchmarkExecution = struct {
    pub fn run(
        allocator: std.mem.Allocator,
        io: std.Io,
        request: benchmark_contract.Request,
    ) ![]u8 {
        return renderBenchOutput(
            allocator,
            io,
            request.db_path,
            request.nodes,
            request.edges,
            request.chunk_size,
            request.workload,
            request.corpus_file_path,
            request.corpus_dir_path,
            request.edge_id_pattern,
            request.edge_delta_stats,
            request.edge_tombstone_probe,
            request.storage_only,
            request.agent_mixed,
            request.edge_compact_batch_entries,
            request.edge_compact_threshold_entries,
            request.maintenance_every_ops,
            request.maintenance_max_segments,
            request.maintenance_max_edges,
            request.maintenance_gc,
            request.maintenance_node_text_every_ops,
            request.maintenance_node_text_max_records,
            request.maintenance_node_text_runs_every_ops,
            request.maintenance_node_text_runs_max_records,
            request.no_regression_gates,
        );
    }
};

const cli_store_lock_suffix = ".tinykg-cli.lock";

const backup_transaction_marker_file = ".tinykg-backup-transaction.json";

const restore_transaction_marker_file = ".tinykg-restore-transaction.json";

const import_transaction_marker_file = ".tinykg-import-transaction.json";

const store_migration_transaction_marker_file = ".tinykg-migrate-store-v2-transaction.json";

const schema_migration_transaction_marker_file = ".tinykg-schema-migrate-transaction";

const default_cli_output_byte_limit: usize = 8 * 1024 * 1024;

fn metaknowDeferredBasedOnGroupCount(pairs: []const MetaknowDeferredBasedOnPair) usize {
    var count: usize = 0;
    var last_src: u64 = 0;
    for (pairs, 0..) |pair, index| {
        if (index == 0 or pair.src != last_src) {
            count += 1;
            last_src = pair.src;
        }
    }
    return count;
}

const md_rel_h1: core.RelKind = @enumFromInt(schema.md_rel_h1_id);

const md_rel_h2: core.RelKind = @enumFromInt(schema.md_rel_h2_id);

const md_rel_h3: core.RelKind = @enumFromInt(schema.md_rel_h3_id);

const md_rel_h4: core.RelKind = @enumFromInt(schema.md_rel_h4_id);

const md_rel_h5: core.RelKind = @enumFromInt(schema.md_rel_h5_id);

const md_rel_h6: core.RelKind = @enumFromInt(schema.md_rel_h6_id);

const md_rel_paragraph: core.RelKind = @enumFromInt(schema.md_rel_paragraph_id);

const md_rel_code_block: core.RelKind = @enumFromInt(schema.md_rel_code_block_id);

const md_rel_image: core.RelKind = @enumFromInt(schema.md_rel_image_id);

const md_rel_list: core.RelKind = @enumFromInt(schema.md_rel_list_id);

const md_rel_blockquote: core.RelKind = @enumFromInt(schema.md_rel_blockquote_id);

const md_rel_html_block: core.RelKind = @enumFromInt(schema.md_rel_html_block_id);

const md_rel_footnote_def: core.RelKind = @enumFromInt(schema.md_rel_footnote_def_id);

const md_rel_link_reference: core.RelKind = @enumFromInt(schema.md_rel_link_reference_id);

const md_rel_thematic_break: core.RelKind = @enumFromInt(schema.md_rel_thematic_break_id);

const md_rel_raw_block: core.RelKind = @enumFromInt(schema.md_rel_raw_block_id);

const md_rel_table: core.RelKind = @enumFromInt(schema.md_rel_table_id);

const md_rel_table_row: core.RelKind = @enumFromInt(schema.md_rel_table_row_id);

const md_rel_table_cell: core.RelKind = @enumFromInt(schema.md_rel_table_cell_id);

const md_rel_text_chunk: core.RelKind = @enumFromInt(schema.md_rel_text_chunk_id);

fn ceilDivU128(numerator: u128, denominator: u128) u128 {
    if (denominator == 0) return std.math.maxInt(u128);
    return numerator / denominator + @intFromBool(numerator % denominator != 0);
}

fn ratioBpsU128(numerator: u128, denominator: u128) u128 {
    if (denominator == 0) return if (numerator == 0) 0 else std.math.maxInt(u128);
    const scaled = std.math.mul(u128, numerator, 10_000) catch return std.math.maxInt(u128);
    return ceilDivU128(scaled, denominator);
}

fn mdHeadingLevelFromRel(rel: core.RelKind) ?usize {
    if (rel == md_rel_h1) return 1;
    if (rel == md_rel_h2) return 2;
    if (rel == md_rel_h3) return 3;
    if (rel == md_rel_h4) return 4;
    if (rel == md_rel_h5) return 5;
    if (rel == md_rel_h6) return 6;
    return null;
}

fn isMarkdownProjectionRel(rel: core.RelKind) bool {
    return mdHeadingLevelFromRel(rel) != null or
        rel == md_rel_paragraph or
        rel == md_rel_code_block or
        rel == md_rel_image or
        rel == md_rel_table or
        rel == md_rel_table_row or
        rel == md_rel_table_cell or
        rel == md_rel_text_chunk or
        isMarkdownRawTextProjectionRel(rel);
}

fn isMarkdownRawTextProjectionRel(rel: core.RelKind) bool {
    return rel == md_rel_list or
        rel == md_rel_blockquote or
        rel == md_rel_html_block or
        rel == md_rel_footnote_def or
        rel == md_rel_link_reference or
        rel == md_rel_thematic_break or
        rel == md_rel_raw_block;
}

fn textCatalogPublishNs(timings: text_search.PersistentTextRebuildTimings) u128 {
    if (std.math.maxInt(u128) - timings.run_summary_ns < timings.run_derived_ns) return 0;
    const accounted = timings.run_summary_ns + timings.run_derived_ns;
    return if (timings.catalog_ns > accounted) timings.catalog_ns - accounted else 0;
}

fn physicalProjections(physical: ql.optimizer.PhysicalPlan) ?[]const ql.ast.Projection {
    for (physical.ops.items) |op| {
        switch (op) {
            .project => |project| return project,
            else => {},
        }
    }
    return null;
}

fn mergeProjectionStats(stats: *query_index.QueryStats, projection_stats: query_index.QueryStats) !void {
    const nodes_visited = std.math.add(usize, stats.nodes_visited, projection_stats.nodes_visited) catch return error.RecordTooLarge;
    const edges_visited = std.math.add(usize, stats.edges_visited, projection_stats.edges_visited) catch return error.RecordTooLarge;
    stats.nodes_visited = nodes_visited;
    stats.edges_visited = edges_visited;
}

test "bench edge segments bytes returns edge segment subtree only" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const db_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(db_path);
    const segments_path = try std.fs.path.join(std.testing.allocator, &.{ db_path, "edge_segments", "0001" });
    defer std.testing.allocator.free(segments_path);
    const segment_file_path = try std.fs.path.join(std.testing.allocator, &.{ segments_path, "edge_fwd.csr" });
    defer std.testing.allocator.free(segment_file_path);
    const outside_file_path = try std.fs.path.join(std.testing.allocator, &.{ db_path, "events.bin" });
    defer std.testing.allocator.free(outside_file_path);

    try std.Io.Dir.cwd().createDirPath(std.testing.io, segments_path);
    {
        var file = try std.Io.Dir.cwd().createFile(std.testing.io, segment_file_path, .{});
        defer file.close(std.testing.io);
        try file.writePositionalAll(std.testing.io, "segment-bytes", 0);
    }
    {
        var file = try std.Io.Dir.cwd().createFile(std.testing.io, outside_file_path, .{});
        defer file.close(std.testing.io);
        try file.writePositionalAll(std.testing.io, "outside", 0);
    }

    const bytes = try benchEdgeSegmentBytes(std.testing.allocator, std.testing.io, db_path);
    try std.testing.expectEqual(@as(u64, 13), bytes.total);
    try std.testing.expectEqual(@as(u64, 13), bytes.data);
    try std.testing.expectEqual(@as(u64, 0), bytes.sidecar);
    try std.testing.expectEqual(@as(u64, 1), bytes.files);
    try std.testing.expectEqual(@as(u64, 1), bytes.dirs);
}

test "bench edge segment bytes classify sidecar and control files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const db_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(db_path);
    const segments_path = try std.fs.path.join(std.testing.allocator, &.{ db_path, "edge_segments", "0001" });
    defer std.testing.allocator.free(segments_path);
    const fwd_path = try std.fs.path.join(std.testing.allocator, &.{ segments_path, "edge_fwd.csr" });
    defer std.testing.allocator.free(fwd_path);
    const rev_path = try std.fs.path.join(std.testing.allocator, &.{ segments_path, "edge_rev.csr" });
    defer std.testing.allocator.free(rev_path);
    const ids_path = try std.fs.path.join(std.testing.allocator, &.{ segments_path, "edge_ids.idx" });
    defer std.testing.allocator.free(ids_path);
    const other_path = try std.fs.path.join(std.testing.allocator, &.{ segments_path, "notes.bin" });
    defer std.testing.allocator.free(other_path);
    const manifest_path = try std.fs.path.join(std.testing.allocator, &.{ db_path, "edge_segment.manifest.4.abcd" });
    defer std.testing.allocator.free(manifest_path);
    const current_path = try std.fs.path.join(std.testing.allocator, &.{ db_path, "edge_segment_current" });
    defer std.testing.allocator.free(current_path);

    try std.Io.Dir.cwd().createDirPath(std.testing.io, segments_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = fwd_path, .data = "ffff" });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = rev_path, .data = "rrrrr" });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = ids_path, .data = "ids" });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = other_path, .data = "xx" });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = manifest_path, .data = "manifest" });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = current_path, .data = "current" });

    const bytes = try benchEdgeSegmentBytes(std.testing.allocator, std.testing.io, db_path);
    try std.testing.expectEqual(@as(u64, 14), bytes.total);
    try std.testing.expectEqual(@as(u64, 9), bytes.data);
    try std.testing.expectEqual(@as(u64, 3), bytes.sidecar);
    try std.testing.expectEqual(@as(u64, 2), bytes.other);
    try std.testing.expectEqual(@as(u64, 8), bytes.manifest);
    try std.testing.expectEqual(@as(u64, 7), bytes.current);
    try std.testing.expectEqual(@as(u64, 15), try bytes.controlBytes());
    try std.testing.expectEqual(@as(u64, 29), try bytes.physicalBytes());
}

test "bench phase rss output includes footprint counters" {
    var out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer out.buffer.deinit(std.testing.allocator);

    try appendBenchPhaseRss(
        &out,
        .{ .peak_bytes = 1, .current_bytes = 2, .footprint_bytes = 3 },
        .{ .peak_bytes = 4, .current_bytes = 5, .footprint_bytes = 6 },
        .{ .peak_bytes = 7, .current_bytes = 8, .footprint_bytes = 9 },
        .{ .peak_bytes = 10, .current_bytes = 11, .footprint_bytes = 12 },
        .{ .peak_bytes = 13, .current_bytes = 14, .footprint_bytes = 15 },
        .{ .peak_bytes = 16, .current_bytes = 17, .footprint_bytes = 18 },
        .{ .peak_bytes = 19, .current_bytes = 20, .footprint_bytes = 21 },
        .{ .peak_bytes = 22, .current_bytes = 23, .footprint_bytes = 24 },
        .{ .peak_bytes = 25, .current_bytes = 26, .footprint_bytes = 27 },
        .{ .peak_bytes = 28, .current_bytes = 29, .footprint_bytes = 30 },
    );

    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "bench_phase_query_current_rss_bytes=14") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "bench_phase_create_footprint_bytes=3") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "bench_phase_query_footprint_bytes=15") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "bench_phase_text_rebuild_footprint_bytes=30") != null);
}

test "bench phase store dir output includes lifecycle counters" {
    var out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer out.buffer.deinit(std.testing.allocator);

    try appendBenchPhaseStoreBytes(&out, .{
        .create = 1,
        .add_node = 2,
        .add_edge = 3,
        .edge_maintenance = 4,
        .query = 5,
        .store_deinit = 6,
        .open = 7,
        .validate = 8,
        .repair = 9,
        .text_rebuild = 10,
    });

    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "bench_phase_add_node_store_dir_bytes=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "bench_phase_query_store_dir_bytes=5") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "bench_phase_text_rebuild_store_dir_bytes=10") != null);
}

test "bench ordered edge metrics report sidecar overhead and traversal" {
    var out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer out.buffer.deinit(std.testing.allocator);

    try appendBenchOrderedEdgeMetrics(&out, storage.edge_order_header_bytes, .{
        .ns = 123,
        .rows = 4,
    });
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "edge_order_bytes=16") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "edge_order_header_bytes=16") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "edge_order_overhead_bytes=0") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "ordered_edge_traversal_ns=123") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "ordered_edge_traversal_rows=4") != null);
}

test "bench text rebuild phase rss output includes footprint counters" {
    var out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer out.buffer.deinit(std.testing.allocator);

    try appendTextRebuildPhaseRss(&out, .{
        .docs_progress_max = .{ .peak_bytes = 19, .current_bytes = 20, .footprint_bytes = 21 },
        .docs = .{ .peak_bytes = 1, .current_bytes = 2, .footprint_bytes = 3 },
        .run_finish = .{ .peak_bytes = 4, .current_bytes = 5, .footprint_bytes = 6 },
        .scratch_release = .{ .peak_bytes = 7, .current_bytes = 8, .footprint_bytes = 9 },
        .open_docs = .{ .peak_bytes = 10, .current_bytes = 11, .footprint_bytes = 12 },
        .catalog = .{ .peak_bytes = 13, .current_bytes = 14, .footprint_bytes = 15 },
        .meta = .{ .peak_bytes = 16, .current_bytes = 17, .footprint_bytes = 18 },
    });

    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_phase_docs_rss_bytes=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_phase_scratch_release_current_rss_bytes=8") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_phase_meta_footprint_bytes=18") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_phase_docs_progress_max_current_rss_bytes=20") != null);
}

test "bench footprint peak includes text rebuild progress samples" {
    const ordinary_samples = [_]BenchRssSample{
        .{ .peak_bytes = 1, .current_bytes = 2, .footprint_bytes = 30 },
        .{ .peak_bytes = 3, .current_bytes = 4, .footprint_bytes = 50 },
    };
    try std.testing.expectEqual(@as(u64, 90), maxBenchFootprintBytes(&ordinary_samples, .{
        .docs_progress_max = .{ .peak_bytes = 5, .current_bytes = 6, .footprint_bytes = 90 },
        .docs = .{ .peak_bytes = 7, .current_bytes = 8, .footprint_bytes = 40 },
    }));
}

test "bench build optimize label is explicit" {
    const label = buildOptimizeLabel();
    try std.testing.expect(std.mem.eql(u8, label, "Debug") or
        std.mem.eql(u8, label, "ReleaseSafe") or
        std.mem.eql(u8, label, "ReleaseFast") or
        std.mem.eql(u8, label, "ReleaseSmall"));
}

test "bench tinyql suite uses explicit warmup" {
    try std.testing.expectEqual(@as(usize, 32), bench_tinyql_suite_samples);
    try std.testing.expectEqual(@as(usize, 1), bench_tinyql_suite_warmups);
}

test "bench text rebuild timing output includes phase counters" {
    var out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer out.buffer.deinit(std.testing.allocator);

    try appendTextRebuildTimings(&out, .{
        .docs_ns = 11,
        .docs_layout_ns = 12,
        .docs_node_iter_ns = 13,
        .docs_text_read_ns = 14,
        .docs_tokenize_ns = 15,
        .docs_posting_append_ns = 16,
        .docs_posting_append_materialize_ns = 513,
        .docs_posting_append_sweep_ns = 514,
        .docs_posting_append_regular_sampled_ns = 527,
        .docs_posting_append_candidate_lookup_sampled_ns = 528,
        .docs_posting_append_candidate_hit_sampled_ns = 529,
        .docs_posting_append_virtual_hit_sampled_ns = 530,
        .docs_posting_append_variable_hit_sampled_ns = 531,
        .docs_posting_append_variable_freq_sampled_ns = 532,
        .docs_write_ns = 17,
        .docs_node_count = 18,
        .docs_text_bytes = 19,
        .docs_text_inline_count = 546,
        .docs_text_inline_bytes = 547,
        .docs_text_borrowed_count = 548,
        .docs_text_borrowed_bytes = 549,
        .docs_text_alloc_count = 550,
        .docs_text_alloc_bytes = 551,
        .docs_token_count = 20,
        .docs_posting_append_term_count = 515,
        .docs_posting_append_regular_record_count = 516,
        .docs_posting_append_virtual_candidate_put_count = 517,
        .docs_posting_append_virtual_candidate_hit_count = 518,
        .docs_posting_append_variable_candidate_hit_count = 519,
        .docs_posting_append_variable_freq_append_count = 520,
        .docs_posting_append_candidate_filter_skip_count = 523,
        .docs_posting_append_candidate_lookup_count = 524,
        .docs_posting_append_candidate_cache_hit_count = 539,
        .docs_posting_append_candidate_miss_count = 525,
        .docs_posting_append_candidate_regularized_hit_count = 526,
        .docs_posting_append_materialize_call_count = 521,
        .docs_posting_append_sweep_count = 522,
        .docs_posting_append_regular_sample_count = 533,
        .docs_posting_append_candidate_lookup_sample_count = 534,
        .docs_posting_append_candidate_hit_sample_count = 535,
        .docs_posting_append_virtual_hit_sample_count = 536,
        .docs_posting_append_variable_hit_sample_count = 537,
        .docs_posting_append_variable_freq_sample_count = 538,
        .run_record_term_bytes = 539,
        .run_record_inline_capacity_bytes = 540,
        .run_record_term_slack_bytes = 541,
        .run_record_term_cache_hits = 544,
        .run_record_term_cache_saved_bytes = 545,
        .run_record_long_term_count = 542,
        .run_record_max_term_len = 543,
        .run_chunk_peak_record_bytes = 552,
        .run_chunk_peak_term_bytes = 553,
        .run_chunk_peak_scratch_bytes = 554,
        .run_chunk_peak_record_capacity_bytes = 555,
        .run_chunk_peak_term_capacity_bytes = 556,
        .run_chunk_peak_scratch_capacity_bytes = 557,
        .run_chunk_sort_ns = 22,
        .run_top_hit_candidate_records = 33,
        .run_top_hit_side_stream_candidate_records = 44,
        .run_virtual_all_docs_term_count = 45,
        .run_virtual_all_docs_candidate_records = 46,
        .run_virtual_all_docs_top_hit_cache_doc_scans = 47,
        .run_virtual_all_docs_synthetic_records = 48,
        .run_dense_all_docs_freq_stream_term_count = 49,
        .run_dense_all_docs_freq_stream_candidate_records = 50,
        .run_variable_all_docs_synthetic_records = 51,
        .run_variable_all_docs_freq_stream_cells = 512,
        .run_variable_all_docs_freq_stream_packed_bytes = 513,
        .run_variable_all_docs_freq_stream_rle_bytes = 514,
        .run_variable_all_docs_freq_stream_bitpacked_bytes = 515,
        .run_variable_all_docs_freq_stream_rle_run_count = 516,
        .run_variable_all_docs_freq_stream_max_freq = 517,
        .run_inline_singleton_materialized_terms = 52,
        .run_inline_singleton_materialized_records = 53,
        .run_inline_singleton_materialized_bytes = 54,
        .catalog_ns = 200,
        .run_summary_ns = 66,
        .run_derived_ns = 77,
        .run_derived_regular_ns = 88,
        .run_derived_next_sampled_ns = 89,
        .run_derived_next_reader_sampled_ns = 891,
        .run_derived_next_queue_sampled_ns = 892,
        .run_derived_next_child_probe_count = 893,
        .run_derived_next_queue_compare_count = 894,
        .run_derived_inline_singleton_next_sampled_ns = 896,
        .run_derived_inline_singleton_publish_sampled_ns = 897,
        .run_derived_encode_sampled_ns = 90,
        .run_derived_write_sampled_ns = 91,
        .run_derived_block_stats_sampled_ns = 92,
        .run_derived_top_hit_sampled_ns = 93,
        .run_derived_block_flush_sampled_ns = 94,
        .run_derived_global_doc_rank_ns = 95,
        .run_derived_virtual_top_docs_ns = 96,
        .run_derived_virtual_ns = 99,
        .run_derived_dense_ns = 111,
        .run_derived_flush_ns = 122,
        .run_derived_rename_ns = 133,
        .run_derived_virtual_source_terms = 144,
        .run_derived_dense_source_terms = 155,
        .run_derived_inline_singleton_terms = 166,
        .run_derived_virtual_terms = 177,
        .run_derived_dense_terms = 188,
        .run_derived_block_terms = 199,
        .run_derived_inline_singleton_records = 211,
        .run_derived_virtual_records = 222,
        .run_derived_dense_records = 233,
        .run_derived_block_records = 244,
        .run_derived_top_hit_block_evals = 255,
        .run_derived_top_hit_block_skips = 266,
        .run_derived_top_hit_block_not_full_evals = 267,
        .run_derived_top_hit_block_ready_evals = 268,
        .run_derived_top_hit_block_upper_lt_2x_worst = 269,
        .run_derived_top_hit_block_upper_lt_4x_worst = 270,
        .run_derived_top_hit_block_upper_gte_4x_worst = 271,
        .run_derived_top_hit_candidate_evals = 277,
        .run_derived_top_hit_doc_reads = 288,
        .run_derived_top_hit_regular_candidate_evals = 299,
        .run_derived_top_hit_regular_doc_reads = 311,
        .run_derived_top_hit_virtual_candidate_evals = 322,
        .run_derived_top_hit_virtual_doc_reads = 333,
        .run_derived_top_hit_dense_candidate_evals = 344,
        .run_derived_top_hit_dense_doc_reads = 355,
        .run_derived_top_hit_dense_scan_records = 356,
        .run_derived_top_hit_dense_freq_bound_skips = 357,
        .run_derived_top_hit_dense_freq_bound_skip_runs = 358,
        .run_derived_top_hit_regular_term_count = 366,
        .run_derived_top_hit_regular_doc_read_term_count = 377,
        .run_derived_top_hit_regular_top1_doc_reads = 388,
        .run_derived_top_hit_regular_top4_doc_reads = 399,
        .run_derived_top_hit_regular_top8_doc_reads = 411,
        .run_derived_top_hit_regular_top1_candidate_evals = 422,
        .run_derived_top_hit_regular_top4_candidate_evals = 433,
        .run_derived_top_hit_regular_top8_candidate_evals = 444,
        .run_derived_top_hit_regular_heaviest_doc_read_term_postings = 455,
        .run_derived_top_hit_regular_heaviest_doc_read_term_block_evals = 466,
        .run_derived_top_hit_regular_heaviest_doc_read_term_candidate_evals = 477,
        .run_derived_top_hit_regular_constant_terms = 488,
        .run_derived_top_hit_regular_constant_resolved_terms = 499,
        .run_derived_top_hit_regular_constant_unresolved_terms = 511,
        .run_derived_top_hit_regular_constant_candidate_evals = 522,
        .run_derived_top_hit_regular_constant_doc_reads = 533,
        .run_derived_top_hit_regular_nonconstant_candidate_evals = 544,
        .run_derived_top_hit_regular_nonconstant_doc_reads = 555,
        .run_derived_top_hit_regular_constant_resolved_candidate_skips = 566,
    });

    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_docs_ns=11") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_docs_layout_ns=12") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_docs_node_iter_ns=13") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_docs_text_read_ns=14") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_docs_tokenize_ns=15") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_docs_posting_append_ns=16") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_docs_write_ns=17") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_docs_node_count=18") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_docs_text_bytes=19") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_docs_token_count=20") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_docs_text_inline_count=546") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_docs_text_inline_bytes=547") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_docs_text_borrowed_count=548") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_docs_text_borrowed_bytes=549") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_docs_text_alloc_count=550") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_docs_text_alloc_bytes=551") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_docs_posting_append_materialize_ns=513") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_docs_posting_append_sweep_ns=514") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_docs_posting_append_regular_sampled_ns=527") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_docs_posting_append_candidate_lookup_sampled_ns=528") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_docs_posting_append_candidate_hit_sampled_ns=529") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_docs_posting_append_virtual_hit_sampled_ns=530") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_docs_posting_append_variable_hit_sampled_ns=531") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_docs_posting_append_variable_freq_sampled_ns=532") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_docs_posting_append_term_count=515") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_docs_posting_append_regular_record_count=516") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_docs_posting_append_virtual_candidate_put_count=517") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_docs_posting_append_virtual_candidate_hit_count=518") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_docs_posting_append_variable_candidate_hit_count=519") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_docs_posting_append_variable_freq_append_count=520") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_docs_posting_append_candidate_filter_skip_count=523") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_docs_posting_append_candidate_lookup_count=524") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_docs_posting_append_candidate_cache_hit_count=539") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_docs_posting_append_candidate_miss_count=525") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_docs_posting_append_candidate_regularized_hit_count=526") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_docs_posting_append_materialize_call_count=521") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_docs_posting_append_sweep_count=522") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_docs_posting_append_regular_sample_count=533") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_docs_posting_append_candidate_lookup_sample_count=534") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_docs_posting_append_candidate_hit_sample_count=535") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_docs_posting_append_virtual_hit_sample_count=536") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_docs_posting_append_variable_hit_sample_count=537") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_docs_posting_append_variable_freq_sample_count=538") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_run_record_term_bytes=539") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_run_record_inline_capacity_bytes=540") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_run_record_term_slack_bytes=541") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_run_record_term_cache_hits=544") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_run_record_term_cache_saved_bytes=545") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_run_record_long_term_count=542") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_run_record_max_term_len=543") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_run_chunk_peak_record_bytes=552") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_run_chunk_peak_term_bytes=553") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_run_chunk_peak_scratch_bytes=554") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_run_chunk_peak_record_capacity_bytes=555") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_run_chunk_peak_term_capacity_bytes=556") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_run_chunk_peak_scratch_capacity_bytes=557") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_run_chunk_sort_ns=22") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_run_top_hit_candidate_records=33") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_run_top_hit_side_stream_candidate_records=44") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_run_virtual_all_docs_term_count=45") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_run_virtual_all_docs_candidate_records=46") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_run_virtual_all_docs_top_hit_cache_doc_scans=47") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_run_virtual_all_docs_synthetic_records=48") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_run_dense_all_docs_freq_stream_term_count=49") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_run_dense_all_docs_freq_stream_candidate_records=50") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_run_variable_all_docs_synthetic_records=51") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_run_variable_all_docs_freq_stream_cells=512") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_run_variable_all_docs_freq_stream_packed_bytes=513") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_run_variable_all_docs_freq_stream_rle_bytes=514") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_run_variable_all_docs_freq_stream_bitpacked_bytes=515") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_run_variable_all_docs_freq_stream_rle_run_count=516") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_run_variable_all_docs_freq_stream_max_freq=517") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_run_inline_singleton_materialized_terms=52") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_run_inline_singleton_materialized_records=53") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_run_inline_singleton_materialized_bytes=54") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_catalog_ns=200") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_run_summary_ns=66") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_run_derived_ns=77") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_catalog_publish_ns=57") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_run_derived_regular_ns=88") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_run_derived_next_sampled_ns=89") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_run_derived_next_reader_sampled_ns=891") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_run_derived_next_queue_sampled_ns=892") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_run_derived_next_child_probe_count=893") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_run_derived_next_queue_compare_count=894") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_run_derived_inline_singleton_next_sampled_ns=896") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_run_derived_inline_singleton_publish_sampled_ns=897") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_run_derived_encode_sampled_ns=90") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_run_derived_write_sampled_ns=91") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_run_derived_block_stats_sampled_ns=92") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_run_derived_top_hit_sampled_ns=93") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_run_derived_block_flush_sampled_ns=94") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_run_derived_global_doc_rank_ns=95") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_run_derived_virtual_top_docs_ns=96") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_run_derived_virtual_ns=99") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_run_derived_dense_ns=111") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_run_derived_flush_ns=122") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_run_derived_rename_ns=133") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_run_derived_virtual_source_terms=144") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_run_derived_dense_source_terms=155") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_run_derived_inline_singleton_terms=166") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_run_derived_virtual_terms=177") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_run_derived_dense_terms=188") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_run_derived_block_terms=199") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_run_derived_inline_singleton_records=211") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_run_derived_virtual_records=222") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_run_derived_dense_records=233") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_run_derived_block_records=244") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_run_derived_top_hit_block_evals=255") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_run_derived_top_hit_block_skips=266") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_run_derived_top_hit_block_not_full_evals=267") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_run_derived_top_hit_block_ready_evals=268") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_run_derived_top_hit_block_upper_lt_2x_worst=269") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_run_derived_top_hit_block_upper_lt_4x_worst=270") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_run_derived_top_hit_block_upper_gte_4x_worst=271") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_run_derived_top_hit_candidate_evals=277") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_run_derived_top_hit_doc_reads=288") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_run_derived_top_hit_regular_candidate_evals=299") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_run_derived_top_hit_regular_doc_reads=311") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_run_derived_top_hit_virtual_candidate_evals=322") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_run_derived_top_hit_virtual_doc_reads=333") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_run_derived_top_hit_dense_candidate_evals=344") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_run_derived_top_hit_dense_doc_reads=355") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_run_derived_top_hit_dense_scan_records=356") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_run_derived_top_hit_dense_freq_bound_skips=357") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_run_derived_top_hit_dense_freq_bound_skip_runs=358") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_run_derived_top_hit_regular_term_count=366") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_run_derived_top_hit_regular_doc_read_term_count=377") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_run_derived_top_hit_regular_top1_doc_reads=388") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_run_derived_top_hit_regular_top4_doc_reads=399") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_run_derived_top_hit_regular_top8_doc_reads=411") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_run_derived_top_hit_regular_top1_candidate_evals=422") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_run_derived_top_hit_regular_top4_candidate_evals=433") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_run_derived_top_hit_regular_top8_candidate_evals=444") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_run_derived_top_hit_regular_heaviest_doc_read_term_postings=455") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_run_derived_top_hit_regular_heaviest_doc_read_term_block_evals=466") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_run_derived_top_hit_regular_heaviest_doc_read_term_candidate_evals=477") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_run_derived_top_hit_regular_constant_terms=488") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_run_derived_top_hit_regular_constant_resolved_terms=499") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_run_derived_top_hit_regular_constant_unresolved_terms=511") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_run_derived_top_hit_regular_constant_candidate_evals=522") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_run_derived_top_hit_regular_constant_doc_reads=533") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_run_derived_top_hit_regular_nonconstant_candidate_evals=544") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_run_derived_top_hit_regular_nonconstant_doc_reads=555") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_rebuild_run_derived_top_hit_regular_constant_resolved_candidate_skips=566") != null);
}

test "bench text rebuild catalog publish timing saturates" {
    try std.testing.expectEqual(@as(u128, 57), textCatalogPublishNs(.{
        .catalog_ns = 200,
        .run_summary_ns = 66,
        .run_derived_ns = 77,
    }));
    try std.testing.expectEqual(@as(u128, 0), textCatalogPublishNs(.{
        .catalog_ns = 100,
        .run_summary_ns = 66,
        .run_derived_ns = 77,
    }));
    try std.testing.expectEqual(@as(u128, 0), textCatalogPublishNs(.{
        .catalog_ns = std.math.maxInt(u128),
        .run_summary_ns = std.math.maxInt(u128),
        .run_derived_ns = 1,
    }));
}

test "bench repair timing output includes edge index phase counters" {
    var out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer out.buffer.deinit(std.testing.allocator);

    try appendRepairTimings(&out, .{
        .edge_index_ns = 10,
        .edge_id_index_ns = 11,
        .edge_src_index_ns = 12,
        .edge_dst_index_ns = 13,
    });

    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "repair_edge_index_ns=10") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "repair_edge_id_index_ns=11") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "repair_edge_src_index_ns=12") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "repair_edge_dst_index_ns=13") != null);
}

test "bench prebuilds text catalog only beyond destructive repair probe scale" {
    try std.testing.expect(benchRunsDestructiveTextRepairProbes(bench_destructive_text_probe_max_nodes));
    try std.testing.expect(!benchPrebuildsTextCatalogForSearch(bench_destructive_text_probe_max_nodes));
    try std.testing.expect(!benchRunsDestructiveTextRepairProbes(bench_destructive_text_probe_max_nodes + 1));
    try std.testing.expect(benchPrebuildsTextCatalogForSearch(bench_destructive_text_probe_max_nodes + 1));
}

test "bench density metrics include text index file breakdown" {
    var out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer out.buffer.deinit(std.testing.allocator);

    var density = BenchTextDensityStats{};
    try density.record(300);
    try appendBenchDensityMetrics(&out, &density, 8000, .{
        .total = 3000,
        .meta = 10,
        .docs = 20,
        .terms = 30,
        .postings = 40,
        .blocks = 50,
        .impacts = 60,
        .top_hits = 70,
        .terms_header = 1,
        .terms_entries = 2,
        .terms_front_coded = 3,
        .terms_offset_checkpoints = 4,
        .terms_exceptions = 5,
        .terms_singleton_checkpoints = 6,
        .terms_singleton_payload = 7,
        .terms_term_count = 8,
        .terms_exception_count = 9,
        .terms_singleton_count = 10,
        .terms_offset_checkpoint_count = 11,
        .terms_singleton_checkpoint_count = 12,
    }, .{
        .total = 160,
        .data = 100,
        .sidecar = 40,
        .other = 20,
        .manifest = 16,
        .current = 4,
        .files = 3,
        .dirs = 1,
        .manifest_files = 1,
        .current_files = 1,
        .csr_header = 5,
        .csr_vertex = 15,
        .csr_relation = 25,
        .csr_edge = 55,
        .csr_edge_count = 9,
        .csr_vertex_count = 3,
        .csr_relation_count = 3,
        .csr_files = 2,
        .csr_derived_edge_id_files = 2,
        .csr_split_derived_edge_id_files = 1,
        .csr_derived_vertex_id_files = 2,
        .csr_split_derived_vertex_id_files = 1,
        .csr_derived_edge_other_node_files = 2,
        .csr_split_derived_edge_other_node_files = 1,
    }, .{
        .raw_bytes = 300,
        .logical_bytes = 300,
        .payload_bytes = 120,
        .total_bytes = 140,
        .block_count = 1,
        .saved_bytes = 160,
    }, .{
        .posting_count = 10,
        .fixed_record_bytes = 70,
        .delta_varint_estimated_bytes = 21,
        .delta_varint_doc_bytes = 10,
        .elias_fano_doc_estimated_bytes = 8,
        .hybrid_doc_estimated_bytes = 7,
        .material_field_tag_bits_estimated_bytes = 4,
        .material_block_jump_checkpoint_bytes = 3,
        .material_hybrid_format_bits_bytes = 2,
        .material_elias_fano_select_checkpoint_bytes = 6,
        .material_hybrid_select_checkpoint_bytes = 5,
        .elias_fano_material_estimated_bytes = 24,
        .hybrid_material_estimated_bytes = 25,
        .elias_fano_material_with_select_estimated_bytes = 30,
        .hybrid_material_with_select_estimated_bytes = 31,
        .hybrid_select_aware_doc_with_select_estimated_bytes = 26,
        .hybrid_select_aware_material_estimated_bytes = 32,
        .hybrid_select_aware_ef_term_count = 4,
        .hybrid_select_aware_delta_term_count = 5,
        .singleton_inline_posting_count = 6,
        .singleton_inline_saved_bytes = 7,
        .virtual_all_docs_term_count = 8,
        .virtual_all_docs_saved_bytes = 10,
        .dense_all_docs_freq_stream_term_count = 11,
        .dense_all_docs_freq_stream_saved_bytes = 12,
        .elias_fano_better_term_count = 2,
        .elias_fano_worse_term_count = 3,
        .delta_varint_field_mask_bytes = 0,
        .delta_varint_text_freq_bytes = 9,
        .delta_varint_kind_freq_bytes = 2,
        .max_doc_delta = 12,
        .max_text_freq = 3,
        .max_kind_freq = 1,
        .doc_delta_over_u16_count = 0,
        .text_freq_over_u8_count = 0,
    }, .{
        .total_edge_count = 10,
        .projection_edge_count = 3,
        .domain_edge_count = 7,
        .tombstone_edge_count = 2,
        .node_property_bytes = 13,
        .edge_property_bytes = 17,
        .property_payload_index_bytes = 19,
        .property_payload_value_bytes = 23,
        .property_payload_delta_bytes = 29,
    });

    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_index_bytes=3000") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "edge_segments_bytes=160") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "logical_edge_bytes=160") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "projection_edge_count=3 logical_projection_edge_bytes=48") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "domain_edge_count=7 logical_domain_edge_bytes=112") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "tombstone_edge_count=2 logical_tombstone_edge_bytes=32") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "property_payload_bytes=101") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "node_property_bytes=13") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "edge_property_bytes=17") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "property_payload_index_bytes=19") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "property_payload_value_bytes=23") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "property_payload_delta_bytes=29") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "edge_segments_data_bytes=100") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "edge_segments_sidecar_bytes=40") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "edge_segments_other_bytes=20") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "edge_segments_files=3") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "edge_segments_dirs=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "edge_segment_manifest_bytes=16") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "edge_segment_current_bytes=4") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "edge_segment_control_bytes=20") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "edge_segment_physical_bytes=180") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "edge_segment_csr_header_bytes=5") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "edge_segment_csr_vertex_bytes=15") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "edge_segment_csr_relation_bytes=25") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "edge_segment_csr_edge_bytes=55") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "edge_segment_csr_files=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "edge_segment_csr_edge_count=9") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "edge_segment_csr_vertex_count=3") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "edge_segment_csr_relation_count=3") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "edge_segment_csr_derived_edge_id_files=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "edge_segment_csr_split_derived_edge_id_files=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "edge_segment_csr_derived_vertex_id_files=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "edge_segment_csr_split_derived_vertex_id_files=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "edge_segment_csr_derived_edge_other_node_files=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "edge_segment_csr_split_derived_edge_other_node_files=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_index_meta_bytes=10") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_index_docs_bytes=20") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_index_terms_bytes=30") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_index_postings_bytes=40") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_index_blocks_bytes=50") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_index_impacts_bytes=60") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_index_top_hits_bytes=70") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_terms_header_bytes=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_terms_entry_bytes=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_terms_front_coded_bytes=3") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_terms_offset_checkpoint_bytes=4") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_terms_exception_bytes=5") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_terms_singleton_checkpoint_bytes=6") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_terms_singleton_payload_bytes=7") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_terms_term_count=8") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_terms_exception_count=9") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_terms_singleton_count=10") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_terms_offset_checkpoint_count=11") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_terms_singleton_checkpoint_count=12") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "node_texts_bytes=300") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "node_texts_logical_bytes=300") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "node_texts_deflate_block_bytes=140") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "node_texts_deflate_block_payload_bytes=120") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "node_texts_deflate_block_count=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "node_texts_deflate_block_saved_bytes=160") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "node_texts_deflate_level=3") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_postings_fixed_record_bytes=70") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_postings_delta_varint_estimated_bytes=21") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_postings_delta_varint_doc_bytes=10") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_postings_elias_fano_doc_estimated_bytes=8") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_postings_hybrid_doc_estimated_bytes=7") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_postings_material_field_tag_bits_estimated_bytes=4") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_postings_material_block_jump_checkpoint_bytes=3") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_postings_material_hybrid_format_bits_bytes=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_postings_material_elias_fano_select_checkpoint_bytes=6") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_postings_material_hybrid_select_checkpoint_bytes=5") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_postings_elias_fano_material_estimated_bytes=24") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_postings_hybrid_material_estimated_bytes=25") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_postings_elias_fano_material_with_select_estimated_bytes=30") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_postings_hybrid_material_with_select_estimated_bytes=31") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_postings_hybrid_select_aware_doc_with_select_estimated_bytes=26") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_postings_hybrid_select_aware_material_estimated_bytes=32") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_postings_hybrid_select_aware_ef_terms=4") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_postings_hybrid_select_aware_delta_terms=5") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_postings_singleton_inline_count=6") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_postings_singleton_inline_saved_bytes=7") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_postings_virtual_all_docs_terms=8") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_postings_virtual_all_docs_saved_bytes=10") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_postings_dense_all_docs_freq_stream_terms=11") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_postings_dense_all_docs_freq_stream_saved_bytes=12") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_postings_elias_fano_better_terms=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_postings_elias_fano_worse_terms=3") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_postings_delta_varint_field_mask_bytes=0") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_postings_max_doc_delta=12") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "text_index_overhead_ratio=10.000000") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "edge_segments_over_logical_edge_ratio=1.000000") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "edge_segment_physical_over_logical_edge_ratio=1.125000") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "node_texts_physical_over_logical_ratio=1.000000") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "node_texts_deflate_overhead_ratio=0.466666") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "store_overhead_ratio_if_node_texts_deflate=17.043478") != null);
}

test "bench density streams sparse ids and visible edge overlays" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage.Store.initWithOptions(std.testing.allocator, std.testing.io, store_path, .{
        .durability = .fast,
        .validate_indexes_on_read = false,
    });
    defer store.deinit();
    try store.createEmpty();
    try store.appendNodesBatch(&.{
        .{ .id = .fromInt(10_000), .kind = .document, .text = "sparse source" },
        .{ .id = .fromInt(20_000), .kind = .document, .text = "sparse target" },
    });

    var base_edges = std.ArrayList(graph.Edge).empty;
    defer base_edges.deinit(std.testing.allocator);
    try base_edges.ensureTotalCapacity(std.testing.allocator, 1024);
    var edge_id: u64 = 1;
    while (edge_id <= 1024) : (edge_id += 1) {
        base_edges.appendAssumeCapacity(.{
            .id = .fromInt(edge_id),
            .src = .fromInt(10_000),
            .rel = .mentions,
            .dst = .fromInt(20_000),
        });
    }
    try store.appendEdgesBatch(base_edges.items);
    try store.appendEdgesBatch(&.{.{
        .id = .fromInt(2000),
        .src = .fromInt(10_000),
        .rel = md_rel_paragraph,
        .dst = .fromInt(20_000),
    }});

    const stats_out = try store.stats();
    const breakdown = try benchDensityBreakdown(std.testing.allocator, std.testing.io, store_path, store, stats_out);
    try std.testing.expectEqual(@as(u64, 1025), breakdown.total_edge_count);
    try std.testing.expectEqual(@as(u64, 1024), breakdown.domain_edge_count);
    try std.testing.expectEqual(@as(u64, 1), breakdown.projection_edge_count);
}

test "bench no-regression gates report pass and failure states" {
    const limits = BenchNoRegressionGateLimits{
        .max_search_ns = 10,
        .max_neighbors_ns = 20,
        .max_tinyql_expand_p95_ns = 30,
        .max_tinyql_context_render_p95_ns = 40,
        .max_path_ns = 50,
        .max_store_overhead_bps = 60_000,
    };
    const passing = evaluateBenchNoRegressionGates(limits, 10, 20, 30, 40, 50, 50_000);
    try std.testing.expect(passing.passed());

    const failing = evaluateBenchNoRegressionGates(limits, 11, 20, 31, 40, 50, 70_000);
    try std.testing.expect(!failing.search_passed);
    try std.testing.expect(!failing.tinyql_expand_passed);
    try std.testing.expect(!failing.store_overhead_passed);
    try std.testing.expect(!failing.passed());

    var out = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer out.buffer.deinit(std.testing.allocator);
    try appendBenchNoRegressionGateMetrics(&out, limits, failing, 11, 20, 31, 40, 50, 70_000);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "no_regression_gate enabled=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "search_passed=0") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "tinyql_expand_passed=0") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "store_overhead_passed=0") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.buffer.items, "passed=0") != null);
}

test "bench text density percentiles preserve replay-sized long tail" {
    var density = BenchTextDensityStats{};
    var small: usize = 0;
    while (small < 98) : (small += 1) try density.record(512);
    try density.record(68_304);
    try density.record(68_808);

    try std.testing.expectEqual(@as(u64, 100), density.node_count);
    try std.testing.expectEqual(@as(u64, 512), density.percentile(90));
    try std.testing.expectEqual(@as(u64, 68_304), density.percentile(99));
    try std.testing.expectEqual(@as(u64, 68_808), density.max_meaningful_text_bytes);
}

test "bench node texts compression estimate prices primary text blocks" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const db_path = path_buf[0..root_len];

    const bytes = try std.testing.allocator.alloc(u8, bench_node_texts_deflate_block_bytes + 4096);
    defer std.testing.allocator.free(bytes);
    @memset(bytes, 'a');
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "node_texts.dat",
        .data = bytes,
        .flags = .{ .truncate = true },
    });

    const estimate = try benchNodeTextsCompressionEstimate(std.testing.allocator, std.testing.io, db_path);
    try std.testing.expectEqual(@as(u64, bytes.len), estimate.raw_bytes);
    try std.testing.expectEqual(@as(u64, bytes.len), estimate.logical_bytes);
    try std.testing.expectEqual(@as(u64, 2), estimate.block_count);
    try std.testing.expectEqual(
        estimate.payload_bytes + bench_node_texts_deflate_block_header_bytes + 2 * bench_node_texts_deflate_block_index_entry_bytes,
        estimate.total_bytes,
    );
    try std.testing.expect(estimate.total_bytes < estimate.raw_bytes);
    try std.testing.expectEqual(estimate.raw_bytes - estimate.total_bytes, estimate.saved_bytes);
}

test "bench node texts compression estimate recognizes existing block deflate storage" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const db_path = path_buf[0..root_len];

    const logical_bytes: u64 = bench_node_texts_deflate_block_bytes + 17;
    const block_count: u64 = 2;
    const payload_bytes: u64 = 123;
    var file_bytes = std.ArrayList(u8).empty;
    defer file_bytes.deinit(std.testing.allocator);
    try file_bytes.resize(
        std.testing.allocator,
        @intCast(bench_node_texts_deflate_block_header_bytes + block_count * bench_node_texts_deflate_block_index_entry_bytes + payload_bytes),
    );
    @memset(file_bytes.items, 0);
    @memcpy(file_bytes.items[0..4], &bench_node_texts_deflate_magic);
    std.mem.writeInt(u16, file_bytes.items[4..6], bench_node_texts_deflate_version, .little);
    std.mem.writeInt(u16, file_bytes.items[6..8], bench_node_texts_deflate_block_header_bytes, .little);
    std.mem.writeInt(u64, file_bytes.items[8..16], logical_bytes, .little);
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "node_texts.dat",
        .data = file_bytes.items,
        .flags = .{ .truncate = true },
    });

    const estimate = try benchNodeTextsCompressionEstimate(std.testing.allocator, std.testing.io, db_path);
    try std.testing.expectEqual(@as(u64, file_bytes.items.len), estimate.raw_bytes);
    try std.testing.expectEqual(logical_bytes, estimate.logical_bytes);
    try std.testing.expectEqual(block_count, estimate.block_count);
    try std.testing.expectEqual(payload_bytes, estimate.payload_bytes);
    try std.testing.expectEqual(@as(u64, file_bytes.items.len), estimate.total_bytes);
    try std.testing.expectEqual(logical_bytes - file_bytes.items.len, estimate.saved_bytes);

    var density = BenchTextDensityStats{};
    density.meaningful_text_bytes = logical_bytes;
    var output = QueryOutputWriter{ .allocator = std.testing.allocator };
    defer output.buffer.deinit(std.testing.allocator);
    try appendBenchDensityMetrics(
        &output,
        &density,
        file_bytes.items.len,
        .{},
        .{},
        estimate,
        .{},
        .{},
    );
    const scaled_ratio = (@as(u128, file_bytes.items.len) * 1_000_000) / logical_bytes;
    const physical_ratio = try std.fmt.allocPrint(
        std.testing.allocator,
        "node_texts_physical_over_logical_ratio=0.{d:0>6}",
        .{scaled_ratio},
    );
    defer std.testing.allocator.free(physical_ratio);
    const deflate_ratio = try std.fmt.allocPrint(
        std.testing.allocator,
        "node_texts_deflate_overhead_ratio=0.{d:0>6}",
        .{scaled_ratio},
    );
    defer std.testing.allocator.free(deflate_ratio);
    try std.testing.expect(std.mem.indexOf(u8, output.buffer.items, physical_ratio) != null);
    try std.testing.expect(std.mem.indexOf(u8, output.buffer.items, deflate_ratio) != null);
}

test "bench node texts compression estimate treats non-header TKNZ prefix as raw" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const db_path = path_buf[0..root_len];

    const bytes = "TKNZ raw user supplied node text that is not a compressed node_texts header";
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "node_texts.dat",
        .data = bytes,
        .flags = .{ .truncate = true },
    });

    const estimate = try benchNodeTextsCompressionEstimate(std.testing.allocator, std.testing.io, db_path);
    try std.testing.expectEqual(@as(u64, bytes.len), estimate.raw_bytes);
    try std.testing.expectEqual(@as(u64, bytes.len), estimate.logical_bytes);
    try std.testing.expectEqual(@as(u64, 1), estimate.block_count);
    try std.testing.expect(estimate.total_bytes <= estimate.raw_bytes + bench_node_texts_deflate_block_header_bytes + bench_node_texts_deflate_block_index_entry_bytes);
}

test "bench storage-only edge tombstone probe reports deterministic pressure" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const db_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "bench.kg" });
    defer std.testing.allocator.free(db_path);

    const request = try benchmark_contract.parseArguments(&.{ "tinykg", "bench", db_path, "6", "6", "--chunk", "3", "--storage-only", "--edge-tombstone-probe" });
    const output = try BenchmarkExecution.run(std.testing.allocator, std.testing.io, request);
    defer std.testing.allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "mode=storage-only") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "edge_tombstone_probe_enabled=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "edge_tombstone_probe_requested=3") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "edge_tombstone_probe_deleted=3") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "edge_tombstone_probe_visible_edges=3") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "edge_tombstone_probe_physical_edges=6") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "edge_tombstone_probe_tombstone_edges=3") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "edge_tombstone_probe_tombstone_ratio_bps=5000") != null);
}

test "metaknow replay storage-only bench runs on small fixture" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "nodes.jsonl",
        .data =
        \\{"id":"node-1","kind":"task","title":"Replay task one","summary":"Investigate TinyKG metaknow replay bench","description":"Meaningful agent memory with command output, decisions, and BM25 terms."}
        \\{"id":"node-2","kind":"file","title":"src/cli.zig replay fixture","summary":"Parser and workload argument implementation","fragment":"zig test src/cli.zig -O ReleaseFast passed for replay fixture."}
        \\{"id":"node-3","kind":"concept","title":"Persistent density target","summary":"text_index_overhead_ratio and store_overhead_ratio must be reported for real replay text."}
        \\{"id":"node-4","kind":"error","title":"Replay edge endpoint skip","summary":"Missing endpoints are counted instead of fabricating structure."}
        \\
        ,
        .flags = .{ .truncate = true },
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "edges.jsonl",
        .data =
        \\{"src":"node-1","dst":"node-2","rel":"mentions"}
        \\{"src":"node-2","dst":"node-3","rel":"depends_on"}
        \\{"src":"node-4","dst":"node-1","rel":"blocks"}
        \\
        ,
        .flags = .{ .truncate = true },
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "manifest.json",
        .data =
        \\{"based_on_materialize_threshold":32,"based_on_materialized_edges":2,"based_on_deferred_edges":3,"based_on_deferred_fragment_count":1,"based_on_document_container_skipped_edges":4,"deferred_based_on_rows":1,"deferred_based_on_bytes":123}
        ,
        .flags = .{ .truncate = true },
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "deferred_based_on.jsonl",
        .data =
        \\{"fragment_id":"node-3","dst_ids":["node-2","node-4"]}
        \\
        ,
        .flags = .{ .truncate = true },
    });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const dir_path = path_buf[0..dir_path_len];
    const db_path = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "bench.kg" });
    defer std.testing.allocator.free(db_path);

    const output = try renderBenchOutput(
        std.testing.allocator,
        std.testing.io,
        db_path,
        4,
        3,
        2,
        .metaknow_replay,
        null,
        dir_path,
        .sequential,
        false,
        false,
        true,
        false,
        0,
        default_bench_edge_compact_threshold_entries,
        0,
        0,
        0,
        false,
        0,
        0,
        0,
        0,
        .{},
    );
    defer std.testing.allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "bench_workload=metaknow-replay") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "mode=storage-only") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "bench_corpus_dir=") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "metaknow_replay_nodes_loaded=4") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "metaknow_replay_edges_used=3") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "metaknow_replay_rel_contains=") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "metaknow_replay_based_on_materialize_threshold=32") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "metaknow_replay_based_on_materialized_edges=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "metaknow_replay_based_on_deferred_edges=3") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "metaknow_replay_based_on_deferred_fragment_count=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "metaknow_replay_based_on_document_container_skipped_edges=4") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "metaknow_replay_deferred_based_on_rows=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "metaknow_replay_deferred_based_on_bytes=123") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "metaknow_replay_deferred_based_on_binary_sources=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "metaknow_replay_deferred_based_on_binary_links=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "metaknow_replay_deferred_based_on_binary_bytes=132") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "metaknow_replay_warm_query_enabled=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "metaknow_replay_warm_lookup_rows_last=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "metaknow_replay_warm_text_search_hits_last=") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "metaknow_replay_warm_text_search_query_bytes=") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "metaknow_replay_warm_text_search_max_postings=") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "metaknow_replay_warm_neighbors_rows_last=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "metaknow_replay_warm_deferred_based_on_neighbors_rows_last=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "meaningful_text_bytes=") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "text_index_overhead_ratio=") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "store_overhead_ratio=") != null);
}

test "benchmark execution runs the agent mixed phase machine end to end" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const db_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "agent-mixed.kg" });
    defer std.testing.allocator.free(db_path);

    const output = try renderBenchOutput(
        std.testing.allocator,
        std.testing.io,
        db_path,
        3,
        3,
        16,
        .synthetic_ring,
        null,
        null,
        .sequential,
        false,
        false,
        false,
        true,
        0,
        default_bench_edge_compact_threshold_entries,
        0,
        0,
        0,
        false,
        0,
        0,
        0,
        0,
        .{},
    );
    defer std.testing.allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "mode=agent-mixed") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "append_ops=20") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "batch_node_ops=4") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "query_ops=4") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "append_node_p95_ns=") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "property_shape_digest=properties-v1-n8-k40-s4-u4-compaction-reopen") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "properties_per_node=8 property_distinct_keys=40 property_count=280") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "append_property_p95_ns=") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "property_lookup_p95_ns=") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "property_compact_ns=") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "property_compact_ns_per_record=") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "property_reopen_lookup_ns=") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "lookup_p95_ns=") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "neighbors_p95_ns=") != null);
}

test "benchmark execution keeps the production agent mixed scale explicit" {
    try std.testing.expectEqual(@as(usize, 1000), bench_agent_mixed_production_plan.append_ops);
    try std.testing.expectEqual(@as(usize, 8), bench_agent_mixed_production_plan.node_batch_size);
    try std.testing.expectEqual(@as(usize, 125), bench_agent_mixed_production_plan.node_batch_ops);
    try std.testing.expectEqual(@as(usize, 10), bench_agent_mixed_production_plan.query_every);
}

test "metaknow replay shaped bench materializes distinct scaled node text" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "nodes.jsonl",
        .data =
        \\{"id":"node-1","kind":"task","title":"Replay task one","summary":"agent memory source one"}
        \\{"id":"node-2","kind":"evidence","title":"Replay evidence two","summary":"agent memory source two"}
        \\
        ,
        .flags = .{ .truncate = true },
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "edges.jsonl",
        .data =
        \\{"src":"node-1","dst":"node-2","rel":"based_on"}
        \\{"src":"node-2","dst":"node-1","rel":"references"}
        \\
        ,
        .flags = .{ .truncate = true },
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "manifest.json",
        .data = "{}",
        .flags = .{ .truncate = true },
    });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir_path_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const dir_path = path_buf[0..dir_path_len];
    const db_path = try std.fs.path.join(std.testing.allocator, &.{ dir_path, "shaped.kg" });
    defer std.testing.allocator.free(db_path);

    const output = try renderBenchOutput(
        std.testing.allocator,
        std.testing.io,
        db_path,
        6,
        12,
        4,
        .metaknow_replay_shaped,
        null,
        dir_path,
        .sequential,
        false,
        false,
        true,
        false,
        0,
        default_bench_edge_compact_threshold_entries,
        0,
        0,
        0,
        false,
        0,
        0,
        0,
        0,
        .{},
    );
    defer std.testing.allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "metaknow_replay_nodes_loaded=2") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "metaknow_replay_nodes_used=6") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "metaknow_replay_edges_used=12") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "metaknow_replay_rel_based_on=6") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "metaknow_replay_rel_references=6") != null);

    var store = try storage.Store.open(std.testing.allocator, std.testing.io, db_path);
    defer store.deinit();
    var node = (try store.readNodeById(std.testing.allocator, .fromInt(3))) orelse return error.NotFound;
    defer node.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, node.text, "Replay task one") == null);
    try std.testing.expect(std.mem.indexOf(u8, node.text, "agent memory source one") == null);
    try std.testing.expect(node.text.len < "Replay task one agent memory source one props_text=\"synthetic_replay_shape=token-v1\" shape_instance=\",,\"".len);

    var visible_edges = try store.visibleEdgeIndexRecordsIterator(.id);
    defer visible_edges.deinit();
    var edge_rows: usize = 0;
    var based_on_edges: usize = 0;
    var references_edges: usize = 0;
    while (try visible_edges.next()) |edge| {
        edge_rows += 1;
        try std.testing.expect(edge.src >= 1 and edge.src <= 6);
        try std.testing.expect(edge.dst >= 1 and edge.dst <= 6);
        switch (try edge.relKind()) {
            .based_on => based_on_edges += 1,
            .references => references_edges += 1,
            else => return error.InvalidRecord,
        }
    }
    try std.testing.expectEqual(@as(usize, 12), edge_rows);
    try std.testing.expectEqual(@as(usize, 6), based_on_edges);
    try std.testing.expectEqual(@as(usize, 6), references_edges);
}

test "bench corpus carries distinct BM25 probe terms" {
    const synthetic_source = BenchTextSource{ .workload = .synthetic_ring };
    const realistic_source = BenchTextSource{ .workload = .realistic_agent_text };
    const diverse_source = BenchTextSource{ .workload = .realistic_agent_diverse_text };

    const plain = try benchNodeText(std.testing.allocator, 2, synthetic_source);
    defer std.testing.allocator.free(plain);
    try std.testing.expect(std.mem.indexOf(u8, plain, "parseInvalidRecord") != null);
    try std.testing.expect(std.mem.indexOf(u8, plain, "benchdoc2") != null);
    try std.testing.expect(std.mem.indexOf(u8, plain, "agent latency budget") == null);
    try std.testing.expect(std.mem.indexOf(u8, plain, "错误") == null);

    const english = try benchNodeText(std.testing.allocator, 263, synthetic_source);
    defer std.testing.allocator.free(english);
    try std.testing.expect(std.mem.indexOf(u8, english, "agent latency budget retry plan") != null);

    const cjk = try benchNodeText(std.testing.allocator, 257, synthetic_source);
    defer std.testing.allocator.free(cjk);
    try std.testing.expect(std.mem.indexOf(u8, cjk, "错误-记录") != null);

    const rich = try benchNodeText(std.testing.allocator, 1, realistic_source);
    defer std.testing.allocator.free(rich);
    try std.testing.expect(rich.len >= 300);
    try std.testing.expect(rich.len <= 500);
    try std.testing.expect(std.mem.indexOf(u8, rich, "props_text=") == null);
    try std.testing.expect(std.mem.indexOf(u8, rich, "fragment_text=") == null);
    try std.testing.expect(std.mem.indexOf(u8, rich, "benchdoc1") != null);
    try std.testing.expect(std.mem.indexOf(u8, rich, "错误-记录") != null);

    const long_rich = try benchNodeText(std.testing.allocator, 64, realistic_source);
    defer std.testing.allocator.free(long_rich);
    try std.testing.expect(long_rich.len >= 4096);
    try std.testing.expect(long_rich.len <= 8500);
    try std.testing.expect(std.mem.indexOf(u8, long_rich, "long_context=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, long_rich, "test_output line") != null);
    try std.testing.expect(benchGeneratedNodeTextIsLong(64, realistic_source));
    try std.testing.expect(!benchGeneratedNodeTextIsLong(63, realistic_source));
    try std.testing.expectEqual(@as(usize, 63), try benchExactTextLookupNodeId(64, realistic_source));
    try std.testing.expectEqual(@as(usize, 65), try benchExactTextLookupNodeId(65, realistic_source));

    const diverse = try benchNodeText(std.testing.allocator, 2, diverse_source);
    defer std.testing.allocator.free(diverse);
    try std.testing.expect(diverse.len >= 300);
    try std.testing.expect(diverse.len <= 700);
    try std.testing.expect(std.mem.indexOf(u8, diverse, "benchdoc2") != null);
    try std.testing.expect(std.mem.indexOf(u8, diverse, "subsystem=") != null);
    try std.testing.expect(std.mem.indexOf(u8, diverse, "hash=") != null);
    try std.testing.expect(std.mem.indexOf(u8, diverse, "stack:") != null);

    const long_diverse = try benchNodeText(std.testing.allocator, 97, diverse_source);
    defer std.testing.allocator.free(long_diverse);
    try std.testing.expect(long_diverse.len >= 4096);
    try std.testing.expect(long_diverse.len <= 8500);
    try std.testing.expect(std.mem.indexOf(u8, long_diverse, "mixed-agent-session") != null);
    try std.testing.expect(std.mem.indexOf(u8, long_diverse, "command_output=") != null);
    try std.testing.expect(benchGeneratedNodeTextIsLong(97, diverse_source));
    try std.testing.expect(!benchGeneratedNodeTextIsLong(96, diverse_source));
    try std.testing.expectEqual(@as(usize, 96), try benchExactTextLookupNodeId(97, diverse_source));

    var appended = std.ArrayList(u8).empty;
    defer appended.deinit(std.testing.allocator);
    try appendBenchNodeTextBytes(std.testing.allocator, &appended, 1, realistic_source);
    const appended_long_start = appended.items.len;
    try appendBenchNodeTextBytes(std.testing.allocator, &appended, 64, realistic_source);
    const appended_long = appended.items[appended_long_start..];
    try std.testing.expect(appended_long.len >= 4096);
    try std.testing.expect(appended_long.len <= 8500);
    try std.testing.expect(std.mem.indexOf(u8, appended_long, "long_context=true") != null);

    const corpus_bytes = try std.testing.allocator.dupe(u8, "real repository paragraph with API decisions and command output\nsecond record mentions storage density and export RSS\n");
    const corpus_records = try std.testing.allocator.alloc([]const u8, 2);
    corpus_records[0] = corpus_bytes[0.."real repository paragraph with API decisions and command output".len];
    corpus_records[1] = corpus_bytes["real repository paragraph with API decisions and command output\n".len.."real repository paragraph with API decisions and command output\nsecond record mentions storage density and export RSS".len];
    const corpus = BenchCorpus{ .bytes = corpus_bytes, .records = corpus_records };
    defer corpus.deinit(std.testing.allocator);
    const corpus_source = BenchTextSource{ .workload = .realistic_agent_diverse_text, .corpus = &corpus };
    const corpus_text = try benchNodeText(std.testing.allocator, 1, corpus_source);
    defer std.testing.allocator.free(corpus_text);
    try std.testing.expect(corpus_text.len >= 300);
    try std.testing.expect(corpus_text.len <= 500);
    try std.testing.expect(std.mem.indexOf(u8, corpus_text, "corpus_file=true") != null);
    try std.testing.expect(std.mem.indexOf(u8, corpus_text, "real repository paragraph") != null);
    try std.testing.expect(std.mem.indexOf(u8, corpus_text, "benchdoc1") != null);
    const long_corpus_text = try benchNodeText(std.testing.allocator, 113, corpus_source);
    defer std.testing.allocator.free(long_corpus_text);
    try std.testing.expect(long_corpus_text.len >= 4096);
    try std.testing.expect(long_corpus_text.len <= 9000);
    try std.testing.expect(benchGeneratedNodeTextIsLong(113, corpus_source));
    try std.testing.expect(!benchGeneratedNodeTextIsLong(112, corpus_source));
    try std.testing.expectEqual(@as(usize, 112), try benchExactTextLookupNodeId(113, corpus_source));

    const huge_corpus_bytes = try std.testing.allocator.alloc(u8, 2048);
    @memset(huge_corpus_bytes, 'x');
    const huge_corpus_records = try std.testing.allocator.alloc([]const u8, 1);
    huge_corpus_records[0] = huge_corpus_bytes;
    const huge_corpus = BenchCorpus{ .bytes = huge_corpus_bytes, .records = huge_corpus_records };
    defer huge_corpus.deinit(std.testing.allocator);
    const huge_corpus_source = BenchTextSource{ .workload = .realistic_agent_diverse_text, .corpus = &huge_corpus };
    const huge_corpus_text = try benchNodeText(std.testing.allocator, 1, huge_corpus_source);
    defer std.testing.allocator.free(huge_corpus_text);
    try std.testing.expect(huge_corpus_text.len >= 300);
    try std.testing.expect(huge_corpus_text.len <= 500);
    try std.testing.expect(std.mem.indexOf(u8, huge_corpus_text, "benchdoc1") != null);

    const path_query = try benchPathSearchQuery(std.testing.allocator, 42);
    defer std.testing.allocator.free(path_query);
    try std.testing.expectEqualStrings("file/42.zig", path_query);

    const context_query = try benchTinyQlContextQuery(std.testing.allocator, "file/42.zig");
    defer std.testing.allocator.free(context_query);
    try std.testing.expect(std.mem.indexOf(u8, context_query, "RETURN context(f) LIMIT 1") != null);

    const tinyql_path_query = try benchTinyQlPathQuery(std.testing.allocator, "file/42.zig");
    defer std.testing.allocator.free(tinyql_path_query);
    try std.testing.expect(std.mem.indexOf(u8, tinyql_path_query, "MATCH (f:file)-[:mentions*1..3]->(n:file)") != null);
    try std.testing.expect(std.mem.indexOf(u8, tinyql_path_query, "RETURN path(f,n) LIMIT 8") != null);

    const text_path_query = try benchTinyQlTextPathQuery(std.testing.allocator, "benchdoc1");
    defer std.testing.allocator.free(text_path_query);
    try std.testing.expect(std.mem.indexOf(u8, text_path_query, "MATCH TEXT \"benchdoc1\" AS f:file MATCH (f)-[:mentions*1..3]->(n:file)") != null);
    try std.testing.expect(std.mem.indexOf(u8, text_path_query, "RETURN path(f,n) LIMIT 8") != null);

    const reachable_query = try benchTinyQlReachableQuery(std.testing.allocator, "file/1.zig", "file/3.zig", true);
    defer std.testing.allocator.free(reachable_query);
    try std.testing.expect(std.mem.indexOf(u8, reachable_query, "MATCH (f:file)-[:mentions*1..3]->(n:file) WHERE f.text = \"file/1.zig\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, reachable_query, "n.text = ") == null);
    try std.testing.expect(std.mem.indexOf(u8, reachable_query, "RETURN reachable(f,n,DEPENDS_ON) LIMIT 1") != null);
    const unreachable_query = try benchTinyQlTextUnreachableQuery(std.testing.allocator, "benchdoc1", true);
    defer std.testing.allocator.free(unreachable_query);
    try std.testing.expect(std.mem.indexOf(u8, unreachable_query, "MATCH TEXT \"benchdoc1\" AS f:file MATCH (f)-[:mentions]->(n:file)") != null);
    try std.testing.expect(std.mem.indexOf(u8, unreachable_query, "RETURN reachable(n,f,DEPENDS_ON) LIMIT 1") != null);

    const mixed_query = try benchTinyQlTextMixedRenderQuery(std.testing.allocator, "benchdoc1", "file/3.zig", true);
    defer std.testing.allocator.free(mixed_query);
    try std.testing.expect(std.mem.indexOf(u8, mixed_query, "MATCH TEXT \"benchdoc1\" AS f:file MATCH (f)-[:mentions*1..3]->(n:file)") != null);
    try std.testing.expect(std.mem.indexOf(u8, mixed_query, "n.text = ") == null);
    try std.testing.expect(std.mem.indexOf(u8, mixed_query, "RETURN context(f), path(f,n), reachable(f,n,DEPENDS_ON) LIMIT 1") != null);

    const depends_a = try benchEdgeForId(3, 8, 7, .sequential);
    try std.testing.expectEqual(core.RelKind.depends_on, depends_a.rel);
    try std.testing.expectEqual(@as(u64, 7), depends_a.id.toInt());
    try std.testing.expectEqual(@as(u64, 1), depends_a.src.toInt());
    try std.testing.expectEqual(@as(u64, 2), depends_a.dst.toInt());

    const depends_b = try benchEdgeForId(3, 8, 8, .sequential);
    try std.testing.expectEqual(core.RelKind.depends_on, depends_b.rel);
    try std.testing.expectEqual(@as(u64, 8), depends_b.id.toInt());
    try std.testing.expectEqual(@as(u64, 2), depends_b.src.toInt());
    try std.testing.expectEqual(@as(u64, 3), depends_b.dst.toInt());

    const tiny_edge = try benchEdgeForId(3, 3, 3, .sequential);
    try std.testing.expectEqual(core.RelKind.mentions, tiny_edge.rel);

    const gap_first = try benchEdgeForId(3, 8, 1, .gap_heavy);
    try std.testing.expectEqual(@as(u64, 9), gap_first.id.toInt());
    const gap_second = try benchEdgeForId(3, 8, 2, .gap_heavy);
    try std.testing.expectEqual(@as(u64, 1), gap_second.id.toInt());
    try std.testing.expectEqual(core.RelKind.mentions, gap_second.rel);
}

fn appendPostRepairNodeTextLookupProbe(out: *QueryOutputWriter, probe: BenchNodeTextLookupProbe) !void {
    try out.print(
        "post_repair_lookup_ns={}\npost_repair_lookup_view_open_ns={} post_repair_lookup_view_open_meta_ns={} post_repair_lookup_view_open_delta_header_ns={} post_repair_lookup_view_open_manifest_ns={} post_repair_lookup_view_open_base_open_ns={} post_repair_lookup_view_open_validate_ns={} post_repair_lookup_view_open_delta_open_ns={} post_repair_lookup_view_open_runs_open_ns={} post_repair_lookup_ids_retained_ns={} post_repair_lookup_ids_retained_hot_ns={} post_repair_lookup_ids_public_ns={} post_repair_lookup_base_public_ns={}\n",
        .{
            probe.lookup_ns,
            probe.lookup_view_open_ns,
            probe.lookup_open_timing_breakdown.meta_ns,
            probe.lookup_open_timing_breakdown.delta_header_ns,
            probe.lookup_open_timing_breakdown.manifest_ns,
            probe.lookup_open_timing_breakdown.base_open_ns,
            probe.lookup_open_timing_breakdown.validate_ns,
            probe.lookup_open_timing_breakdown.delta_open_ns,
            probe.lookup_open_timing_breakdown.runs_open_ns,
            probe.lookup_ids_retained_ns,
            probe.lookup_ids_retained_hot_ns,
            probe.lookup_ids_public_ns,
            probe.lookup_base_public_ns,
        },
    );
    try out.print(
        "post_repair_lookup_first_public_ns={} post_repair_lookup_base_first_public_ns={}\n",
        .{
            probe.lookup_first_public_ns,
            probe.lookup_base_first_public_ns,
        },
    );
    try out.print(
        "post_repair_lookup_lazy_open_meta_ns={} post_repair_lookup_lazy_open_delta_header_ns={} post_repair_lookup_lazy_open_manifest_ns={} post_repair_lookup_lazy_open_base_ns={} post_repair_lookup_lazy_open_validate_ns={} post_repair_lookup_lazy_open_delta_ns={} post_repair_lookup_lazy_open_runs_ns={}\npost_repair_lookup_lazy_search_texts_view_ns={} post_repair_lookup_lazy_search_node_view_ns={} post_repair_lookup_lazy_hash_ns={} post_repair_lookup_lazy_lower_bound_ns={} post_repair_lookup_lazy_lower_bound_probe_count={} post_repair_lookup_lazy_scan_ns={} post_repair_lookup_lazy_scan_record_count={} post_repair_lookup_lazy_span_view_ns={} post_repair_lookup_lazy_record_decode_ns={} post_repair_lookup_lazy_text_view_ns={} post_repair_lookup_lazy_text_match_ns={} post_repair_lookup_lazy_text_compare_ns={} post_repair_lookup_lazy_by_id_validate_ns={} post_repair_lookup_materialize_ns={} post_repair_lookup_lazy_run_count={} post_repair_lookup_lazy_range_skip_count={}\n",
        .{
            probe.lookup_full_timing_breakdown.lazy_open_meta_ns,
            probe.lookup_full_timing_breakdown.lazy_open_delta_header_ns,
            probe.lookup_full_timing_breakdown.lazy_open_manifest_ns,
            probe.lookup_full_timing_breakdown.lazy_open_base_ns,
            probe.lookup_full_timing_breakdown.lazy_open_validate_ns,
            probe.lookup_full_timing_breakdown.lazy_open_delta_ns,
            probe.lookup_full_timing_breakdown.lazy_open_runs_ns,
            probe.lookup_full_timing_breakdown.search_texts_view_ns,
            probe.lookup_full_timing_breakdown.search_node_view_ns,
            probe.lookup_full_timing_breakdown.hash_ns,
            probe.lookup_full_timing_breakdown.lower_bound_ns,
            probe.lookup_full_timing_breakdown.lower_bound_probe_count,
            probe.lookup_full_timing_breakdown.scan_ns,
            probe.lookup_full_timing_breakdown.scan_record_count,
            probe.lookup_full_timing_breakdown.span_view_ns,
            probe.lookup_full_timing_breakdown.record_decode_ns,
            probe.lookup_full_timing_breakdown.text_view_ns,
            probe.lookup_full_timing_breakdown.text_match_ns,
            probe.lookup_full_timing_breakdown.text_compare_ns,
            probe.lookup_full_timing_breakdown.by_id_validate_ns,
            probe.lookup_full_timing_breakdown.materialize_ns,
            probe.lookup_full_timing_breakdown.run_count,
            probe.lookup_full_timing_breakdown.range_skip_count,
        },
    );
    try out.print(
        "post_repair_lookup_search_texts_view_ns={} post_repair_lookup_search_node_view_ns={} post_repair_lookup_lower_bound_ns={} post_repair_lookup_lower_bound_probe_count={} post_repair_lookup_scan_ns={} post_repair_lookup_scan_record_count={} post_repair_lookup_span_view_ns={} post_repair_lookup_record_decode_ns={} post_repair_lookup_text_view_ns={} post_repair_lookup_text_match_ns={} post_repair_lookup_text_compare_ns={} post_repair_lookup_by_id_validate_ns={} post_repair_lookup_run_count={} post_repair_lookup_range_skip_count={}\n",
        .{
            probe.lookup_timing_breakdown.search_texts_view_ns,
            probe.lookup_timing_breakdown.search_node_view_ns,
            probe.lookup_timing_breakdown.lower_bound_ns,
            probe.lookup_timing_breakdown.lower_bound_probe_count,
            probe.lookup_timing_breakdown.scan_ns,
            probe.lookup_timing_breakdown.scan_record_count,
            probe.lookup_timing_breakdown.span_view_ns,
            probe.lookup_timing_breakdown.record_decode_ns,
            probe.lookup_timing_breakdown.text_view_ns,
            probe.lookup_timing_breakdown.text_match_ns,
            probe.lookup_timing_breakdown.text_compare_ns,
            probe.lookup_timing_breakdown.by_id_validate_ns,
            probe.lookup_timing_breakdown.run_count,
            probe.lookup_timing_breakdown.range_skip_count,
        },
    );
    try out.print(
        "post_repair_lookup_ids_public_lazy_open_meta_ns={} post_repair_lookup_ids_public_lazy_open_delta_header_ns={} post_repair_lookup_ids_public_lazy_open_manifest_ns={} post_repair_lookup_ids_public_lazy_open_base_ns={} post_repair_lookup_ids_public_lazy_open_validate_ns={} post_repair_lookup_ids_public_lazy_open_delta_ns={} post_repair_lookup_ids_public_lazy_open_runs_ns={}\npost_repair_lookup_ids_public_search_texts_view_ns={} post_repair_lookup_ids_public_search_node_view_ns={} post_repair_lookup_ids_public_lower_bound_ns={} post_repair_lookup_ids_public_lower_bound_probe_count={} post_repair_lookup_ids_public_scan_ns={} post_repair_lookup_ids_public_scan_record_count={} post_repair_lookup_ids_public_span_view_ns={} post_repair_lookup_ids_public_record_decode_ns={} post_repair_lookup_ids_public_text_view_ns={} post_repair_lookup_ids_public_text_match_ns={} post_repair_lookup_ids_public_text_compare_ns={} post_repair_lookup_ids_public_by_id_validate_ns={} post_repair_lookup_ids_public_run_count={} post_repair_lookup_ids_public_range_skip_count={}\n",
        .{
            probe.lookup_ids_public_timing_breakdown.lazy_open_meta_ns,
            probe.lookup_ids_public_timing_breakdown.lazy_open_delta_header_ns,
            probe.lookup_ids_public_timing_breakdown.lazy_open_manifest_ns,
            probe.lookup_ids_public_timing_breakdown.lazy_open_base_ns,
            probe.lookup_ids_public_timing_breakdown.lazy_open_validate_ns,
            probe.lookup_ids_public_timing_breakdown.lazy_open_delta_ns,
            probe.lookup_ids_public_timing_breakdown.lazy_open_runs_ns,
            probe.lookup_ids_public_timing_breakdown.search_texts_view_ns,
            probe.lookup_ids_public_timing_breakdown.search_node_view_ns,
            probe.lookup_ids_public_timing_breakdown.lower_bound_ns,
            probe.lookup_ids_public_timing_breakdown.lower_bound_probe_count,
            probe.lookup_ids_public_timing_breakdown.scan_ns,
            probe.lookup_ids_public_timing_breakdown.scan_record_count,
            probe.lookup_ids_public_timing_breakdown.span_view_ns,
            probe.lookup_ids_public_timing_breakdown.record_decode_ns,
            probe.lookup_ids_public_timing_breakdown.text_view_ns,
            probe.lookup_ids_public_timing_breakdown.text_match_ns,
            probe.lookup_ids_public_timing_breakdown.text_compare_ns,
            probe.lookup_ids_public_timing_breakdown.by_id_validate_ns,
            probe.lookup_ids_public_timing_breakdown.run_count,
            probe.lookup_ids_public_timing_breakdown.range_skip_count,
        },
    );
    try out.print(
        "post_repair_lookup_first_public_lazy_open_meta_ns={} post_repair_lookup_first_public_lazy_open_delta_header_ns={} post_repair_lookup_first_public_lazy_open_manifest_ns={} post_repair_lookup_first_public_lazy_open_base_ns={} post_repair_lookup_first_public_lazy_open_validate_ns={} post_repair_lookup_first_public_lazy_open_delta_ns={} post_repair_lookup_first_public_lazy_open_runs_ns={}\npost_repair_lookup_first_public_search_texts_view_ns={} post_repair_lookup_first_public_search_node_view_ns={} post_repair_lookup_first_public_lower_bound_ns={} post_repair_lookup_first_public_lower_bound_probe_count={} post_repair_lookup_first_public_scan_ns={} post_repair_lookup_first_public_scan_record_count={} post_repair_lookup_first_public_span_view_ns={} post_repair_lookup_first_public_record_decode_ns={} post_repair_lookup_first_public_text_view_ns={} post_repair_lookup_first_public_text_match_ns={} post_repair_lookup_first_public_text_compare_ns={} post_repair_lookup_first_public_by_id_validate_ns={} post_repair_lookup_first_public_run_count={} post_repair_lookup_first_public_range_skip_count={}\n",
        .{
            probe.lookup_first_public_timing_breakdown.lazy_open_meta_ns,
            probe.lookup_first_public_timing_breakdown.lazy_open_delta_header_ns,
            probe.lookup_first_public_timing_breakdown.lazy_open_manifest_ns,
            probe.lookup_first_public_timing_breakdown.lazy_open_base_ns,
            probe.lookup_first_public_timing_breakdown.lazy_open_validate_ns,
            probe.lookup_first_public_timing_breakdown.lazy_open_delta_ns,
            probe.lookup_first_public_timing_breakdown.lazy_open_runs_ns,
            probe.lookup_first_public_timing_breakdown.search_texts_view_ns,
            probe.lookup_first_public_timing_breakdown.search_node_view_ns,
            probe.lookup_first_public_timing_breakdown.lower_bound_ns,
            probe.lookup_first_public_timing_breakdown.lower_bound_probe_count,
            probe.lookup_first_public_timing_breakdown.scan_ns,
            probe.lookup_first_public_timing_breakdown.scan_record_count,
            probe.lookup_first_public_timing_breakdown.span_view_ns,
            probe.lookup_first_public_timing_breakdown.record_decode_ns,
            probe.lookup_first_public_timing_breakdown.text_view_ns,
            probe.lookup_first_public_timing_breakdown.text_match_ns,
            probe.lookup_first_public_timing_breakdown.text_compare_ns,
            probe.lookup_first_public_timing_breakdown.by_id_validate_ns,
            probe.lookup_first_public_timing_breakdown.run_count,
            probe.lookup_first_public_timing_breakdown.range_skip_count,
        },
    );
    try out.print(
        "post_repair_lookup_base_public_lazy_open_meta_ns={} post_repair_lookup_base_public_lazy_open_delta_header_ns={} post_repair_lookup_base_public_lazy_open_manifest_ns={} post_repair_lookup_base_public_lazy_open_base_ns={} post_repair_lookup_base_public_lazy_open_validate_ns={} post_repair_lookup_base_public_lazy_open_delta_ns={} post_repair_lookup_base_public_lazy_open_runs_ns={}\npost_repair_lookup_base_public_search_texts_view_ns={} post_repair_lookup_base_public_search_node_view_ns={} post_repair_lookup_base_public_lower_bound_ns={} post_repair_lookup_base_public_lower_bound_probe_count={} post_repair_lookup_base_public_scan_ns={} post_repair_lookup_base_public_scan_record_count={} post_repair_lookup_base_public_span_view_ns={} post_repair_lookup_base_public_record_decode_ns={} post_repair_lookup_base_public_text_view_ns={} post_repair_lookup_base_public_text_match_ns={} post_repair_lookup_base_public_text_compare_ns={} post_repair_lookup_base_public_by_id_validate_ns={} post_repair_lookup_base_public_run_count={} post_repair_lookup_base_public_range_skip_count={}\n",
        .{
            probe.lookup_base_public_timing_breakdown.lazy_open_meta_ns,
            probe.lookup_base_public_timing_breakdown.lazy_open_delta_header_ns,
            probe.lookup_base_public_timing_breakdown.lazy_open_manifest_ns,
            probe.lookup_base_public_timing_breakdown.lazy_open_base_ns,
            probe.lookup_base_public_timing_breakdown.lazy_open_validate_ns,
            probe.lookup_base_public_timing_breakdown.lazy_open_delta_ns,
            probe.lookup_base_public_timing_breakdown.lazy_open_runs_ns,
            probe.lookup_base_public_timing_breakdown.search_texts_view_ns,
            probe.lookup_base_public_timing_breakdown.search_node_view_ns,
            probe.lookup_base_public_timing_breakdown.lower_bound_ns,
            probe.lookup_base_public_timing_breakdown.lower_bound_probe_count,
            probe.lookup_base_public_timing_breakdown.scan_ns,
            probe.lookup_base_public_timing_breakdown.scan_record_count,
            probe.lookup_base_public_timing_breakdown.span_view_ns,
            probe.lookup_base_public_timing_breakdown.record_decode_ns,
            probe.lookup_base_public_timing_breakdown.text_view_ns,
            probe.lookup_base_public_timing_breakdown.text_match_ns,
            probe.lookup_base_public_timing_breakdown.text_compare_ns,
            probe.lookup_base_public_timing_breakdown.by_id_validate_ns,
            probe.lookup_base_public_timing_breakdown.run_count,
            probe.lookup_base_public_timing_breakdown.range_skip_count,
        },
    );
    try out.print(
        "post_repair_lookup_base_first_public_lazy_open_meta_ns={} post_repair_lookup_base_first_public_lazy_open_delta_header_ns={} post_repair_lookup_base_first_public_lazy_open_manifest_ns={} post_repair_lookup_base_first_public_lazy_open_base_ns={} post_repair_lookup_base_first_public_lazy_open_validate_ns={} post_repair_lookup_base_first_public_lazy_open_delta_ns={} post_repair_lookup_base_first_public_lazy_open_runs_ns={}\npost_repair_lookup_base_first_public_search_texts_view_ns={} post_repair_lookup_base_first_public_search_node_view_ns={} post_repair_lookup_base_first_public_lower_bound_ns={} post_repair_lookup_base_first_public_lower_bound_probe_count={} post_repair_lookup_base_first_public_scan_ns={} post_repair_lookup_base_first_public_scan_record_count={} post_repair_lookup_base_first_public_span_view_ns={} post_repair_lookup_base_first_public_record_decode_ns={} post_repair_lookup_base_first_public_text_view_ns={} post_repair_lookup_base_first_public_text_match_ns={} post_repair_lookup_base_first_public_text_compare_ns={} post_repair_lookup_base_first_public_by_id_validate_ns={} post_repair_lookup_base_first_public_run_count={} post_repair_lookup_base_first_public_range_skip_count={}\n",
        .{
            probe.lookup_base_first_public_timing_breakdown.lazy_open_meta_ns,
            probe.lookup_base_first_public_timing_breakdown.lazy_open_delta_header_ns,
            probe.lookup_base_first_public_timing_breakdown.lazy_open_manifest_ns,
            probe.lookup_base_first_public_timing_breakdown.lazy_open_base_ns,
            probe.lookup_base_first_public_timing_breakdown.lazy_open_validate_ns,
            probe.lookup_base_first_public_timing_breakdown.lazy_open_delta_ns,
            probe.lookup_base_first_public_timing_breakdown.lazy_open_runs_ns,
            probe.lookup_base_first_public_timing_breakdown.search_texts_view_ns,
            probe.lookup_base_first_public_timing_breakdown.search_node_view_ns,
            probe.lookup_base_first_public_timing_breakdown.lower_bound_ns,
            probe.lookup_base_first_public_timing_breakdown.lower_bound_probe_count,
            probe.lookup_base_first_public_timing_breakdown.scan_ns,
            probe.lookup_base_first_public_timing_breakdown.scan_record_count,
            probe.lookup_base_first_public_timing_breakdown.span_view_ns,
            probe.lookup_base_first_public_timing_breakdown.record_decode_ns,
            probe.lookup_base_first_public_timing_breakdown.text_view_ns,
            probe.lookup_base_first_public_timing_breakdown.text_match_ns,
            probe.lookup_base_first_public_timing_breakdown.text_compare_ns,
            probe.lookup_base_first_public_timing_breakdown.by_id_validate_ns,
            probe.lookup_base_first_public_timing_breakdown.run_count,
            probe.lookup_base_first_public_timing_breakdown.range_skip_count,
        },
    );
    try out.print(
        "post_repair_lookup_retained_samples={} post_repair_lookup_retained_p50_ns={} post_repair_lookup_retained_p95_ns={} post_repair_lookup_retained_p99_ns={} post_repair_lookup_retained_max_ns={} post_repair_lookup_retained_rows_last={}\npost_repair_lookup_base_retained_samples={} post_repair_lookup_base_retained_p50_ns={} post_repair_lookup_base_retained_p95_ns={} post_repair_lookup_base_retained_p99_ns={} post_repair_lookup_base_retained_max_ns={} post_repair_lookup_base_retained_rows_last={} post_repair_lookup_base_run_count={} post_repair_lookup_base_lower_bound_probe_count={} post_repair_lookup_base_range_skip_count={}\n",
        .{
            bench_tinyql_suite_samples,
            probe.lookup_retained_stats.p50_ns,
            probe.lookup_retained_stats.p95_ns,
            probe.lookup_retained_stats.p99_ns,
            probe.lookup_retained_stats.max_ns,
            probe.lookup_retained_rows_last,
            bench_tinyql_suite_samples,
            probe.lookup_base_retained_stats.p50_ns,
            probe.lookup_base_retained_stats.p95_ns,
            probe.lookup_base_retained_stats.p99_ns,
            probe.lookup_base_retained_stats.max_ns,
            probe.lookup_base_retained_rows_last,
            probe.lookup_base_timing_breakdown.run_count,
            probe.lookup_base_timing_breakdown.lower_bound_probe_count,
            probe.lookup_base_timing_breakdown.range_skip_count,
        },
    );
    try out.print(
        "post_repair_lookup_ids_public_samples={} post_repair_lookup_ids_public_p50_ns={} post_repair_lookup_ids_public_p95_ns={} post_repair_lookup_ids_public_p99_ns={} post_repair_lookup_ids_public_max_ns={} post_repair_lookup_ids_public_open_p95_ns={} post_repair_lookup_ids_public_body_p95_ns={} post_repair_lookup_ids_public_lower_bound_p95_ns={} post_repair_lookup_ids_public_rows_last={}\npost_repair_lookup_base_public_samples={} post_repair_lookup_base_public_p50_ns={} post_repair_lookup_base_public_p95_ns={} post_repair_lookup_base_public_p99_ns={} post_repair_lookup_base_public_max_ns={} post_repair_lookup_base_public_open_p95_ns={} post_repair_lookup_base_public_body_p95_ns={} post_repair_lookup_base_public_lower_bound_p95_ns={} post_repair_lookup_base_public_rows_last={}\n",
        .{
            bench_tinyql_suite_samples,
            probe.lookup_ids_public_stats.p50_ns,
            probe.lookup_ids_public_stats.p95_ns,
            probe.lookup_ids_public_stats.p99_ns,
            probe.lookup_ids_public_stats.max_ns,
            probe.lookup_ids_public_open_stats.p95_ns,
            probe.lookup_ids_public_body_stats.p95_ns,
            probe.lookup_ids_public_lower_bound_stats.p95_ns,
            probe.lookup_ids_public_rows_last,
            bench_tinyql_suite_samples,
            probe.lookup_base_public_stats.p50_ns,
            probe.lookup_base_public_stats.p95_ns,
            probe.lookup_base_public_stats.p99_ns,
            probe.lookup_base_public_stats.max_ns,
            probe.lookup_base_public_open_stats.p95_ns,
            probe.lookup_base_public_body_stats.p95_ns,
            probe.lookup_base_public_lower_bound_stats.p95_ns,
            probe.lookup_base_public_rows_last,
        },
    );
    try out.print(
        "post_repair_lookup_first_public_samples={} post_repair_lookup_first_public_p50_ns={} post_repair_lookup_first_public_p95_ns={} post_repair_lookup_first_public_p99_ns={} post_repair_lookup_first_public_max_ns={} post_repair_lookup_first_public_open_p95_ns={} post_repair_lookup_first_public_body_p95_ns={} post_repair_lookup_first_public_lower_bound_p95_ns={} post_repair_lookup_first_public_rows_last={}\npost_repair_lookup_base_first_public_samples={} post_repair_lookup_base_first_public_p50_ns={} post_repair_lookup_base_first_public_p95_ns={} post_repair_lookup_base_first_public_p99_ns={} post_repair_lookup_base_first_public_max_ns={} post_repair_lookup_base_first_public_open_p95_ns={} post_repair_lookup_base_first_public_body_p95_ns={} post_repair_lookup_base_first_public_lower_bound_p95_ns={} post_repair_lookup_base_first_public_rows_last={}\n",
        .{
            bench_tinyql_suite_samples,
            probe.lookup_first_public_stats.p50_ns,
            probe.lookup_first_public_stats.p95_ns,
            probe.lookup_first_public_stats.p99_ns,
            probe.lookup_first_public_stats.max_ns,
            probe.lookup_first_public_open_stats.p95_ns,
            probe.lookup_first_public_body_stats.p95_ns,
            probe.lookup_first_public_lower_bound_stats.p95_ns,
            probe.lookup_first_public_rows_last,
            bench_tinyql_suite_samples,
            probe.lookup_base_first_public_stats.p50_ns,
            probe.lookup_base_first_public_stats.p95_ns,
            probe.lookup_base_first_public_stats.p99_ns,
            probe.lookup_base_first_public_stats.max_ns,
            probe.lookup_base_first_public_open_stats.p95_ns,
            probe.lookup_base_first_public_body_stats.p95_ns,
            probe.lookup_base_first_public_lower_bound_stats.p95_ns,
            probe.lookup_base_first_public_rows_last,
        },
    );
}
