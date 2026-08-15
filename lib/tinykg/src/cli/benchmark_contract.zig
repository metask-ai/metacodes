const std = @import("std");

/// CLI benchmark request grammar and execution-mode compatibility contract.
///
/// Concrete storage, query, text, timing, and output work remains in the CLI
/// execution pipeline. This owner only turns argv into a validated request so
/// invalid mode combinations cannot reach side-effecting benchmark setup.
pub const BenchmarkContract = struct {
    pub const default_chunk_size: usize = 65_536;
    pub const default_edge_compact_threshold_entries: u32 = 0;

    pub const Workload = enum {
        synthetic_ring,
        realistic_agent_text,
        realistic_agent_diverse_text,
        metaknow_replay,
        metaknow_replay_shaped,
        kunshan_shaped_corpus,

        pub fn label(self: Workload) []const u8 {
            return switch (self) {
                .synthetic_ring => "synthetic-ring",
                .realistic_agent_text => "realistic-agent-text",
                .realistic_agent_diverse_text => "realistic-agent-diverse-text",
                .metaknow_replay => "metaknow-replay",
                .metaknow_replay_shaped => "metaknow-replay-shaped",
                .kunshan_shaped_corpus => "kunshan-shaped-corpus",
            };
        }

        pub fn shapeLabel(self: Workload) []const u8 {
            return switch (self) {
                .synthetic_ring => "code-agent-ring",
                .realistic_agent_text => "realistic-agent-text",
                .realistic_agent_diverse_text => "realistic-agent-diverse-text",
                .metaknow_replay => "metaknow-replay",
                .metaknow_replay_shaped => "metaknow-replay-shaped",
                .kunshan_shaped_corpus => "kunshan-shaped-corpus",
            };
        }

        pub fn usesMetaknowReplay(self: Workload) bool {
            return switch (self) {
                .metaknow_replay, .metaknow_replay_shaped => true,
                else => false,
            };
        }
    };

    pub const EdgeIdPattern = enum {
        sequential,
        gap_heavy,

        pub fn label(self: EdgeIdPattern) []const u8 {
            return switch (self) {
                .sequential => "sequential",
                .gap_heavy => "gap-heavy",
            };
        }
    };

    pub const NoRegressionGateLimits = struct {
        max_search_ns: ?u128 = null,
        max_neighbors_ns: ?u128 = null,
        max_tinyql_expand_p95_ns: ?u128 = null,
        max_tinyql_context_render_p95_ns: ?u128 = null,
        max_path_ns: ?u128 = null,
        max_store_overhead_bps: ?u128 = null,

        pub fn enabled(self: NoRegressionGateLimits) bool {
            return self.max_search_ns != null or
                self.max_neighbors_ns != null or
                self.max_tinyql_expand_p95_ns != null or
                self.max_tinyql_context_render_p95_ns != null or
                self.max_path_ns != null or
                self.max_store_overhead_bps != null;
        }
    };

    pub const Request = struct {
        db_path: []const u8,
        nodes: usize,
        edges: usize,
        chunk_size: usize = default_chunk_size,
        workload: Workload = .synthetic_ring,
        corpus_file_path: ?[]const u8 = null,
        corpus_dir_path: ?[]const u8 = null,
        edge_id_pattern: EdgeIdPattern = .sequential,
        edge_delta_stats: bool = false,
        edge_tombstone_probe: bool = false,
        storage_only: bool = false,
        agent_mixed: bool = false,
        edge_compact_batch_entries: u32 = 0,
        edge_compact_threshold_entries: u32 = default_edge_compact_threshold_entries,
        maintenance_every_ops: usize = 0,
        maintenance_max_segments: usize = 0,
        maintenance_max_edges: u64 = 0,
        maintenance_gc: bool = false,
        maintenance_node_text_every_ops: usize = 0,
        maintenance_node_text_max_records: u64 = 0,
        maintenance_node_text_runs_every_ops: usize = 0,
        maintenance_node_text_runs_max_records: u64 = 0,
        no_regression_gates: NoRegressionGateLimits = .{},
    };

    pub fn parseArguments(args: []const []const u8) !Request {
        if (args.len < 5) return error.MissingArgument;
        var request = Request{
            .db_path = args[2],
            .nodes = try parsePositiveCount(args[3]),
            .edges = try parsePositiveCount(args[4]),
        };
        var pos: usize = 5;
        while (pos < args.len) {
            const option = args[pos];
            if (std.mem.eql(u8, option, "--chunk")) {
                request.chunk_size = try parsePositiveCount(try optionValue(args, pos));
                pos += 2;
            } else if (std.mem.eql(u8, option, "--workload")) {
                request.workload = try parseWorkload(try optionValue(args, pos));
                pos += 2;
            } else if (std.mem.eql(u8, option, "--corpus-file")) {
                request.corpus_file_path = try optionValue(args, pos);
                pos += 2;
            } else if (std.mem.eql(u8, option, "--corpus-dir")) {
                request.corpus_dir_path = try optionValue(args, pos);
                pos += 2;
            } else if (std.mem.eql(u8, option, "--edge-id-pattern")) {
                request.edge_id_pattern = try parseEdgeIdPattern(try optionValue(args, pos));
                pos += 2;
            } else if (std.mem.eql(u8, option, "--edge-delta-stats")) {
                request.edge_delta_stats = true;
                pos += 1;
            } else if (std.mem.eql(u8, option, "--edge-tombstone-probe")) {
                request.edge_tombstone_probe = true;
                pos += 1;
            } else if (std.mem.eql(u8, option, "--edge-compact-batch")) {
                request.edge_compact_batch_entries = try parseU32(try optionValue(args, pos), true);
                pos += 2;
            } else if (std.mem.eql(u8, option, "--edge-compact-threshold")) {
                request.edge_compact_threshold_entries = try parseU32(try optionValue(args, pos), true);
                pos += 2;
            } else if (std.mem.eql(u8, option, "--maintenance-every")) {
                request.maintenance_every_ops = try parsePositiveCount(try optionValue(args, pos));
                pos += 2;
            } else if (std.mem.eql(u8, option, "--maintenance-max-segments")) {
                request.maintenance_max_segments = try parsePositiveCount(try optionValue(args, pos));
                pos += 2;
            } else if (std.mem.eql(u8, option, "--maintenance-max-edges")) {
                request.maintenance_max_edges = try parseU64(try optionValue(args, pos));
                pos += 2;
            } else if (std.mem.eql(u8, option, "--maintenance-gc")) {
                request.maintenance_gc = true;
                pos += 1;
            } else if (std.mem.eql(u8, option, "--maintenance-node-text-every")) {
                request.maintenance_node_text_every_ops = try parsePositiveCount(try optionValue(args, pos));
                pos += 2;
            } else if (std.mem.eql(u8, option, "--maintenance-node-text-max-records")) {
                request.maintenance_node_text_max_records = try parseU64(try optionValue(args, pos));
                pos += 2;
            } else if (std.mem.eql(u8, option, "--maintenance-node-text-runs-every")) {
                request.maintenance_node_text_runs_every_ops = try parsePositiveCount(try optionValue(args, pos));
                pos += 2;
            } else if (std.mem.eql(u8, option, "--maintenance-node-text-runs-max-records")) {
                request.maintenance_node_text_runs_max_records = try parseU64(try optionValue(args, pos));
                pos += 2;
            } else if (std.mem.eql(u8, option, "--max-search-ns")) {
                request.no_regression_gates.max_search_ns = try parsePositiveU128(try optionValue(args, pos));
                pos += 2;
            } else if (std.mem.eql(u8, option, "--max-neighbors-ns")) {
                request.no_regression_gates.max_neighbors_ns = try parsePositiveU128(try optionValue(args, pos));
                pos += 2;
            } else if (std.mem.eql(u8, option, "--max-tinyql-expand-p95-ns")) {
                request.no_regression_gates.max_tinyql_expand_p95_ns = try parsePositiveU128(try optionValue(args, pos));
                pos += 2;
            } else if (std.mem.eql(u8, option, "--max-tinyql-context-render-p95-ns")) {
                request.no_regression_gates.max_tinyql_context_render_p95_ns = try parsePositiveU128(try optionValue(args, pos));
                pos += 2;
            } else if (std.mem.eql(u8, option, "--max-path-ns")) {
                request.no_regression_gates.max_path_ns = try parsePositiveU128(try optionValue(args, pos));
                pos += 2;
            } else if (std.mem.eql(u8, option, "--max-store-overhead-bps")) {
                request.no_regression_gates.max_store_overhead_bps = try parsePositiveU128(try optionValue(args, pos));
                pos += 2;
            } else if (std.mem.eql(u8, option, "--storage-only")) {
                request.storage_only = true;
                pos += 1;
            } else if (std.mem.eql(u8, option, "--agent-mixed")) {
                request.agent_mixed = true;
                pos += 1;
            } else {
                return error.UnknownOption;
            }
        }
        try validateCompatibility(request);
        return request;
    }

    fn optionValue(args: []const []const u8, pos: usize) ![]const u8 {
        if (pos + 1 >= args.len) return error.MissingArgument;
        return args[pos + 1];
    }

    fn parsePositiveCount(value: []const u8) !usize {
        const parsed = std.fmt.parseInt(usize, value, 10) catch return error.InvalidLimit;
        if (parsed == 0) return error.InvalidLimit;
        return parsed;
    }

    fn parseU32(value: []const u8, allow_zero: bool) !u32 {
        const parsed = std.fmt.parseInt(u32, value, 10) catch return error.InvalidLimit;
        if (!allow_zero and parsed == 0) return error.InvalidLimit;
        return parsed;
    }

    fn parseU64(value: []const u8) !u64 {
        const parsed = std.fmt.parseInt(u64, value, 10) catch return error.InvalidLimit;
        if (parsed == 0) return error.InvalidLimit;
        return parsed;
    }

    fn parsePositiveU128(value: []const u8) !u128 {
        const parsed = std.fmt.parseInt(u128, value, 10) catch return error.InvalidLimit;
        if (parsed == 0) return error.InvalidLimit;
        return parsed;
    }

    fn parseWorkload(value: []const u8) !Workload {
        if (std.mem.eql(u8, value, "synthetic-ring")) return .synthetic_ring;
        if (std.mem.eql(u8, value, "realistic-agent-text")) return .realistic_agent_text;
        if (std.mem.eql(u8, value, "realistic-agent-diverse-text")) return .realistic_agent_diverse_text;
        if (std.mem.eql(u8, value, "metaknow-replay")) return .metaknow_replay;
        if (std.mem.eql(u8, value, "metaknow-replay-shaped")) return .metaknow_replay_shaped;
        if (std.mem.eql(u8, value, "kunshan-shaped-corpus")) return .kunshan_shaped_corpus;
        return error.InvalidLimit;
    }

    fn parseEdgeIdPattern(value: []const u8) !EdgeIdPattern {
        if (std.mem.eql(u8, value, "sequential")) return .sequential;
        if (std.mem.eql(u8, value, "gap-heavy")) return .gap_heavy;
        return error.InvalidLimit;
    }

    fn validateCompatibility(request: Request) !void {
        if (request.agent_mixed and request.storage_only) return error.Unsupported;
        if (request.edge_tombstone_probe and !request.storage_only) return error.Unsupported;
        if (request.maintenance_every_ops != 0 and !request.agent_mixed) return error.Unsupported;
        if ((request.maintenance_max_segments != 0 or request.maintenance_max_edges != 0) and request.maintenance_every_ops == 0) return error.Unsupported;
        if (request.maintenance_gc and request.maintenance_every_ops == 0) return error.Unsupported;
        if (request.maintenance_node_text_every_ops != 0 and !request.agent_mixed) return error.Unsupported;
        if (request.maintenance_node_text_max_records != 0 and request.maintenance_node_text_every_ops == 0) return error.Unsupported;
        if (request.maintenance_node_text_runs_every_ops != 0 and !request.agent_mixed) return error.Unsupported;
        if (request.maintenance_node_text_runs_max_records != 0 and request.maintenance_node_text_runs_every_ops == 0) return error.Unsupported;
        if (request.no_regression_gates.enabled() and (request.storage_only or request.agent_mixed)) return error.Unsupported;
        const needs_corpus_dir = request.workload.usesMetaknowReplay() or request.workload == .kunshan_shaped_corpus;
        if (needs_corpus_dir and request.corpus_dir_path == null) return error.MissingArgument;
        if (!needs_corpus_dir and request.corpus_dir_path != null) return error.Unsupported;
        if (request.workload.usesMetaknowReplay() and request.agent_mixed) return error.Unsupported;
        if (request.workload.usesMetaknowReplay() and request.edge_tombstone_probe) return error.Unsupported;
    }
};

const contract = BenchmarkContract;

test "benchmark contract requires explicit positive scale and preserves defaults" {
    const request = try contract.parseArguments(&.{ "tinykg", "bench", "kg", "10", "20" });
    try std.testing.expectEqualStrings("kg", request.db_path);
    try std.testing.expectEqual(@as(usize, 10), request.nodes);
    try std.testing.expectEqual(@as(usize, 20), request.edges);
    try std.testing.expectEqual(contract.default_chunk_size, request.chunk_size);
    try std.testing.expectEqual(contract.Workload.synthetic_ring, request.workload);
    try std.testing.expectEqual(contract.EdgeIdPattern.sequential, request.edge_id_pattern);
    try std.testing.expect(!request.edge_delta_stats);
    try std.testing.expect(!request.storage_only);
    try std.testing.expect(!request.agent_mixed);
    try std.testing.expectError(error.MissingArgument, contract.parseArguments(&.{ "tinykg", "bench", "kg", "10" }));
    try std.testing.expectError(error.InvalidLimit, contract.parseArguments(&.{ "tinykg", "bench", "kg", "0", "20" }));
    try std.testing.expectError(error.InvalidLimit, contract.parseArguments(&.{ "tinykg", "bench", "kg", "10", "nope" }));
}

test "benchmark contract parses workload corpus edge pattern and compaction options" {
    const request = try contract.parseArguments(&.{
        "tinykg",          "bench",                    "kg",         "10",                           "20",
        "--chunk",         "7",                        "--workload", "realistic-agent-diverse-text", "--corpus-file",
        "docs/sample.txt", "--edge-id-pattern",        "gap-heavy",  "--edge-delta-stats",           "--edge-compact-batch",
        "32",              "--edge-compact-threshold", "256",
    });
    try std.testing.expectEqual(@as(usize, 7), request.chunk_size);
    try std.testing.expectEqual(contract.Workload.realistic_agent_diverse_text, request.workload);
    try std.testing.expectEqualStrings("docs/sample.txt", request.corpus_file_path.?);
    try std.testing.expectEqual(contract.EdgeIdPattern.gap_heavy, request.edge_id_pattern);
    try std.testing.expect(request.edge_delta_stats);
    try std.testing.expectEqual(@as(u32, 32), request.edge_compact_batch_entries);
    try std.testing.expectEqual(@as(u32, 256), request.edge_compact_threshold_entries);
    try std.testing.expectEqualStrings("realistic-agent-diverse-text", request.workload.label());
    try std.testing.expectEqualStrings("gap-heavy", request.edge_id_pattern.label());
}

test "benchmark contract rejects unknown missing and invalid option values" {
    try std.testing.expectError(error.UnknownOption, contract.parseArguments(&.{ "tinykg", "bench", "kg", "10", "20", "extra" }));
    try std.testing.expectError(error.UnknownOption, contract.parseArguments(&.{ "tinykg", "bench", "kg", "10", "20", "--bad", "7" }));
    try std.testing.expectError(error.MissingArgument, contract.parseArguments(&.{ "tinykg", "bench", "kg", "10", "20", "--chunk" }));
    try std.testing.expectError(error.InvalidLimit, contract.parseArguments(&.{ "tinykg", "bench", "kg", "10", "20", "--chunk", "0" }));
    try std.testing.expectError(error.InvalidLimit, contract.parseArguments(&.{ "tinykg", "bench", "kg", "10", "20", "--workload", "unknown" }));
    try std.testing.expectError(error.InvalidLimit, contract.parseArguments(&.{ "tinykg", "bench", "kg", "10", "20", "--edge-id-pattern", "unknown" }));
    try std.testing.expectError(error.InvalidLimit, contract.parseArguments(&.{ "tinykg", "bench", "kg", "10", "20", "--edge-compact-batch", "nope" }));
}

test "benchmark contract parses positive no regression gate limits" {
    const request = try contract.parseArguments(&.{
        "tinykg",                   "bench",                              "kg",                 "10",            "20",
        "--max-search-ns",          "1000",                               "--max-neighbors-ns", "2000",          "--max-tinyql-expand-p95-ns",
        "3000",                     "--max-tinyql-context-render-p95-ns", "4000",               "--max-path-ns", "5000",
        "--max-store-overhead-bps", "60000",
    });
    try std.testing.expect(request.no_regression_gates.enabled());
    try std.testing.expectEqual(@as(u128, 1000), request.no_regression_gates.max_search_ns.?);
    try std.testing.expectEqual(@as(u128, 2000), request.no_regression_gates.max_neighbors_ns.?);
    try std.testing.expectEqual(@as(u128, 3000), request.no_regression_gates.max_tinyql_expand_p95_ns.?);
    try std.testing.expectEqual(@as(u128, 4000), request.no_regression_gates.max_tinyql_context_render_p95_ns.?);
    try std.testing.expectEqual(@as(u128, 5000), request.no_regression_gates.max_path_ns.?);
    try std.testing.expectEqual(@as(u128, 60000), request.no_regression_gates.max_store_overhead_bps.?);
    try std.testing.expectError(error.InvalidLimit, contract.parseArguments(&.{ "tinykg", "bench", "kg", "10", "20", "--max-search-ns", "0" }));
}

test "benchmark contract isolates storage and agent mixed execution modes" {
    const storage_only = try contract.parseArguments(&.{ "tinykg", "bench", "kg", "10", "20", "--storage-only", "--edge-tombstone-probe" });
    try std.testing.expect(storage_only.storage_only);
    try std.testing.expect(storage_only.edge_tombstone_probe);
    const agent_mixed = try contract.parseArguments(&.{ "tinykg", "bench", "kg", "10", "20", "--agent-mixed" });
    try std.testing.expect(agent_mixed.agent_mixed);
    try std.testing.expectError(error.Unsupported, contract.parseArguments(&.{ "tinykg", "bench", "kg", "10", "20", "--storage-only", "--agent-mixed" }));
    try std.testing.expectError(error.Unsupported, contract.parseArguments(&.{ "tinykg", "bench", "kg", "10", "20", "--edge-tombstone-probe" }));
    try std.testing.expectError(error.Unsupported, contract.parseArguments(&.{ "tinykg", "bench", "kg", "10", "20", "--storage-only", "--max-search-ns", "1000" }));
    try std.testing.expectError(error.Unsupported, contract.parseArguments(&.{ "tinykg", "bench", "kg", "10", "20", "--agent-mixed", "--max-search-ns", "1000" }));
}

test "benchmark contract validates maintenance parent options and positive limits" {
    const request = try contract.parseArguments(&.{
        "tinykg",              "bench",                                    "kg",                         "10",                                  "20",                      "--agent-mixed",
        "--maintenance-every", "10",                                       "--maintenance-max-segments", "8",                                   "--maintenance-max-edges", "64",
        "--maintenance-gc",    "--maintenance-node-text-every",            "5",                          "--maintenance-node-text-max-records", "128",                     "--maintenance-node-text-runs-every",
        "6",                   "--maintenance-node-text-runs-max-records", "256",
    });
    try std.testing.expectEqual(@as(usize, 10), request.maintenance_every_ops);
    try std.testing.expectEqual(@as(usize, 8), request.maintenance_max_segments);
    try std.testing.expectEqual(@as(u64, 64), request.maintenance_max_edges);
    try std.testing.expect(request.maintenance_gc);
    try std.testing.expectEqual(@as(usize, 5), request.maintenance_node_text_every_ops);
    try std.testing.expectEqual(@as(u64, 128), request.maintenance_node_text_max_records);
    try std.testing.expectEqual(@as(usize, 6), request.maintenance_node_text_runs_every_ops);
    try std.testing.expectEqual(@as(u64, 256), request.maintenance_node_text_runs_max_records);
    try std.testing.expectError(error.Unsupported, contract.parseArguments(&.{ "tinykg", "bench", "kg", "10", "20", "--maintenance-every", "10" }));
    try std.testing.expectError(error.Unsupported, contract.parseArguments(&.{ "tinykg", "bench", "kg", "10", "20", "--agent-mixed", "--maintenance-max-segments", "8" }));
    try std.testing.expectError(error.InvalidLimit, contract.parseArguments(&.{ "tinykg", "bench", "kg", "10", "20", "--agent-mixed", "--maintenance-every", "0" }));
    try std.testing.expectError(error.InvalidLimit, contract.parseArguments(&.{ "tinykg", "bench", "kg", "10", "20", "--agent-mixed", "--maintenance-every", "10", "--maintenance-max-edges", "0" }));
}

test "benchmark contract keeps replay corpus gates and execution modes compatible" {
    const replay = try contract.parseArguments(&.{
        "tinykg",     "bench",                  "kg",           "10",                                  "20",
        "--workload", "metaknow-replay-shaped", "--corpus-dir", "docs/bench-fixtures/metaknow-export",
    });
    try std.testing.expect(replay.workload.usesMetaknowReplay());
    try std.testing.expectEqualStrings("metaknow-replay-shaped", replay.workload.shapeLabel());
    try std.testing.expectError(error.MissingArgument, contract.parseArguments(&.{ "tinykg", "bench", "kg", "10", "20", "--workload", "metaknow-replay" }));
    try std.testing.expectError(error.Unsupported, contract.parseArguments(&.{ "tinykg", "bench", "kg", "10", "20", "--corpus-dir", "docs/bench-fixtures/metaknow-export" }));
    try std.testing.expectError(error.Unsupported, contract.parseArguments(&.{ "tinykg", "bench", "kg", "10", "20", "--workload", "metaknow-replay", "--corpus-dir", "docs/bench-fixtures/metaknow-export", "--agent-mixed" }));
    try std.testing.expectError(error.Unsupported, contract.parseArguments(&.{ "tinykg", "bench", "kg", "10", "20", "--storage-only", "--edge-tombstone-probe", "--workload", "metaknow-replay", "--corpus-dir", "docs/bench-fixtures/metaknow-export" }));
}

test "benchmark contract accepts kunshan shaped corpus with a shard pool directory" {
    const shaped = try contract.parseArguments(&.{
        "tinykg",     "bench",                 "kg",           "10",          "20",
        "--workload", "kunshan-shaped-corpus", "--corpus-dir", "/tmp/shards",
    });
    try std.testing.expectEqual(contract.Workload.kunshan_shaped_corpus, shaped.workload);
    try std.testing.expect(!shaped.workload.usesMetaknowReplay());
    try std.testing.expectEqualStrings("kunshan-shaped-corpus", shaped.workload.label());
    // the shard pool is mandatory, and full query mode stays allowed
    try std.testing.expectError(error.MissingArgument, contract.parseArguments(&.{ "tinykg", "bench", "kg", "10", "20", "--workload", "kunshan-shaped-corpus" }));
    const mixed = try contract.parseArguments(&.{
        "tinykg",        "bench", "kg", "10", "20", "--workload", "kunshan-shaped-corpus", "--corpus-dir", "/tmp/shards",
        "--agent-mixed",
    });
    try std.testing.expect(mixed.agent_mixed);
}
