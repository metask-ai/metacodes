const std = @import("std");
const tokenizer_mod = @import("tokenizer.zig");
const scoring_mod = @import("scoring.zig");
const search_contract_mod = @import("search_contract.zig");

/// Owns the public query control plane while the façade-provided `Ops` keeps
/// persistent BM25 and ephemeral `TextIndex` representations private.  The
/// boundary is deliberately about routing, admission, and fallback semantics;
/// it does not merge the two independent query data planes.
pub fn QueryExecution(
    comptime core: type,
    comptime schema: type,
    comptime storage: type,
    comptime Ops: type,
) type {
    return struct {
        const tokenizer = tokenizer_mod;
        const search_contract = search_contract_mod.SearchContract(core, schema, tokenizer_mod, scoring_mod);
        const Store = storage.Store;

        pub const TextSearchOptions = search_contract.TextSearchOptions;
        pub const TextSearchHit = search_contract.TextSearchHit;

        pub const TextQueryPlanStats = struct {
            query_terms: usize = 0,
            unique_query_terms: usize = 0,
            matched_terms: usize = 0,
            postings_count_total: u64 = 0,
            max_postings_count: u64 = 0,
        };

        /// A stale persistent catalog may use an ephemeral, read-only index
        /// only while scanning the canonical store remains predictably bounded.
        pub const stale_store_scan_max_nodes: u64 = 100_000;
        pub const stale_store_scan_max_text_bytes: u64 = 128 * 1024 * 1024;
        pub const stale_store_scan_max_event_bytes: u64 = 64 * 1024 * 1024;
        pub const stale_store_scan_max_property_delta_bytes: u64 = 64 * 1024 * 1024;

        pub fn searchText(
            allocator: std.mem.Allocator,
            store: Store,
            query: []const u8,
            options: TextSearchOptions,
        ) !std.ArrayList(TextSearchHit) {
            try Internal.validatePersistentOptions(options);
            if (options.deadline.expired()) return core.Error.BudgetExceeded;
            if (options.limit == 0) return std.ArrayList(TextSearchHit).empty;

            var query_tokens = try tokenizer.tokenize(allocator, query, options.tokenizer);
            defer query_tokens.deinit();
            if (query_tokens.items.items.len == 0) return std.ArrayList(TextSearchHit).empty;

            const stale = try Ops.persistentCatalogQuickStaleDeadline(allocator, store, options.deadline);
            if (stale) return Internal.searchStoreScan(allocator, store, query, options);
            return Ops.searchPersistentTokens(allocator, store, query_tokens.items.items, options) catch |err| switch (err) {
                error.FileNotFound, error.InvalidRecord => Internal.searchStoreScan(allocator, store, query, options),
                else => |other| return other,
            };
        }

        pub fn textQueryPlanStats(
            allocator: std.mem.Allocator,
            store: Store,
            query: []const u8,
            options: TextSearchOptions,
        ) !TextQueryPlanStats {
            try Internal.validatePersistentOptions(options);
            if (options.deadline.expired()) return core.Error.BudgetExceeded;

            var query_tokens = try tokenizer.tokenize(allocator, query, options.tokenizer);
            defer query_tokens.deinit();
            if (query_tokens.items.items.len == 0) return .{};

            const stale = try Ops.persistentCatalogQuickStaleDeadline(allocator, store, options.deadline);
            if (stale) return Internal.planStatsStoreScan(allocator, store, query, options);

            var stats = TextQueryPlanStats{ .query_terms = query_tokens.items.items.len };
            Ops.fillPersistentPlanStats(allocator, store, query_tokens.items.items, &stats) catch |err| switch (err) {
                error.FileNotFound, error.InvalidRecord => return Internal.planStatsStoreScan(allocator, store, query, options),
                else => |other| return other,
            };
            return stats;
        }

        pub const Internal = struct {
            pub fn validatePersistentOptions(options: TextSearchOptions) !void {
                try search_contract.Internal.validateOptions(options);
                if (!search_contract.Internal.tokenizerOptionsEqual(options.tokenizer, .{})) {
                    return core.Error.Unsupported;
                }
            }

            pub fn staleStoreScanAllowed(
                node_count: u64,
                logical_text_bytes: u64,
                event_bytes: u64,
                property_delta_bytes: u64,
            ) bool {
                return node_count <= stale_store_scan_max_nodes and
                    logical_text_bytes <= stale_store_scan_max_text_bytes and
                    event_bytes <= stale_store_scan_max_event_bytes and
                    property_delta_bytes <= stale_store_scan_max_property_delta_bytes;
            }

            pub fn admitStaleStoreScan(store: Store, deadline: core.QueryDeadline) !u64 {
                if (deadline.expired()) return core.Error.BudgetExceeded;

                // IndexMeta may lag the canonical event log after a crash.  Bound
                // canonical inputs before the façade builds an ephemeral index.
                const event_bytes = try store.eventByteCount();
                if (event_bytes > stale_store_scan_max_event_bytes) return error.TextIndexMaintenanceRequired;
                const node_count = try store.nodeEventCountUpTo(stale_store_scan_max_nodes);
                if (node_count > stale_store_scan_max_nodes) return error.TextIndexMaintenanceRequired;
                const logical_text_bytes = try store.primaryNodeTextLogicalBytes();
                const property_delta_bytes = try store.propertyPayloadDeltaByteCount();
                if (!staleStoreScanAllowed(node_count, logical_text_bytes, event_bytes, property_delta_bytes)) {
                    return error.TextIndexMaintenanceRequired;
                }
                return stale_store_scan_max_text_bytes - logical_text_bytes;
            }

            pub fn searchStoreScan(
                allocator: std.mem.Allocator,
                store: Store,
                query: []const u8,
                options: TextSearchOptions,
            ) !std.ArrayList(TextSearchHit) {
                const max_metadata_bytes = try admitStaleStoreScan(store, options.deadline);
                return Ops.searchStoreScan(
                    allocator,
                    store,
                    query,
                    options,
                    max_metadata_bytes,
                    stale_store_scan_max_property_delta_bytes,
                ) catch |err| switch (err) {
                    error.SearchableMetadataBudgetExceeded => return error.TextIndexMaintenanceRequired,
                    else => |other| return other,
                };
            }

            pub fn planStatsStoreScan(
                allocator: std.mem.Allocator,
                store: Store,
                query: []const u8,
                options: TextSearchOptions,
            ) !TextQueryPlanStats {
                const max_metadata_bytes = try admitStaleStoreScan(store, options.deadline);
                var stats = TextQueryPlanStats{};
                Ops.fillStoreScanPlanStats(
                    allocator,
                    store,
                    query,
                    options,
                    max_metadata_bytes,
                    stale_store_scan_max_property_delta_bytes,
                    &stats,
                ) catch |err| switch (err) {
                    error.SearchableMetadataBudgetExceeded => return error.TextIndexMaintenanceRequired,
                    else => |other| return other,
                };
                return stats;
            }
        };
    };
}

const TestCore = struct {
    pub const default_max_text_postings_scanned: usize = 100;
    pub const Error = error{ Unsupported, BudgetExceeded };

    pub const QueryDeadline = enum {
        none,
        immediate,

        pub fn expired(self: QueryDeadline) bool {
            return self == .immediate;
        }
    };

    pub const NodeKind = enum(u16) { task, observation };
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
};

const TestSchema = struct {
    pub const NodeTypeSet = struct {
        pub fn containsNodeKind(_: NodeTypeSet, _: TestCore.NodeKind) bool {
            return false;
        }
    };
};

const TestTrace = struct {
    quick_stale_calls: usize = 0,
    persistent_search_calls: usize = 0,
    store_scan_search_calls: usize = 0,
    persistent_plan_calls: usize = 0,
    store_scan_plan_calls: usize = 0,
    admitted_metadata_bytes: u64 = 0,
    admitted_property_delta_bytes: u64 = 0,
};

const TestPersistentFailure = enum { none, missing, invalid, denied };

const TestStorage = struct {
    pub const Store = struct {
        trace: *TestTrace,
        stale: bool = false,
        persistent_failure: TestPersistentFailure = .none,
        node_count: u64 = 1,
        logical_text_bytes: u64 = 1,
        event_bytes: u64 = 1,
        property_delta_bytes: u64 = 1,

        pub fn eventByteCount(self: Store) !u64 {
            return self.event_bytes;
        }

        pub fn nodeEventCountUpTo(self: Store, _: u64) !u64 {
            return self.node_count;
        }

        pub fn primaryNodeTextLogicalBytes(self: Store) !u64 {
            return self.logical_text_bytes;
        }

        pub fn propertyPayloadDeltaByteCount(self: Store) !u64 {
            return self.property_delta_bytes;
        }
    };
};

const test_search_contract = search_contract_mod.SearchContract(TestCore, TestSchema, tokenizer_mod, scoring_mod);
const TestOps = struct {
    pub fn persistentCatalogQuickStaleDeadline(
        _: std.mem.Allocator,
        store: TestStorage.Store,
        _: TestCore.QueryDeadline,
    ) !bool {
        store.trace.quick_stale_calls += 1;
        return store.stale;
    }

    pub fn searchPersistentTokens(
        allocator: std.mem.Allocator,
        store: TestStorage.Store,
        _: []const []u8,
        _: test_search_contract.TextSearchOptions,
    ) anyerror!std.ArrayList(test_search_contract.TextSearchHit) {
        store.trace.persistent_search_calls += 1;
        switch (store.persistent_failure) {
            .none => {},
            .missing => return error.FileNotFound,
            .invalid => return error.InvalidRecord,
            .denied => return error.AccessDenied,
        }
        var hits = std.ArrayList(test_search_contract.TextSearchHit).empty;
        try hits.append(allocator, .{ .node_id = .fromInt(11), .kind = .task, .score = 2 });
        return hits;
    }

    pub fn searchStoreScan(
        allocator: std.mem.Allocator,
        store: TestStorage.Store,
        _: []const u8,
        _: test_search_contract.TextSearchOptions,
        max_metadata_bytes: u64,
        max_property_delta_bytes: u64,
    ) anyerror!std.ArrayList(test_search_contract.TextSearchHit) {
        store.trace.store_scan_search_calls += 1;
        store.trace.admitted_metadata_bytes = max_metadata_bytes;
        store.trace.admitted_property_delta_bytes = max_property_delta_bytes;
        var hits = std.ArrayList(test_search_contract.TextSearchHit).empty;
        try hits.append(allocator, .{ .node_id = .fromInt(22), .kind = .observation, .score = 1 });
        return hits;
    }

    pub fn fillPersistentPlanStats(
        _: std.mem.Allocator,
        store: TestStorage.Store,
        _: []const []u8,
        stats: anytype,
    ) anyerror!void {
        store.trace.persistent_plan_calls += 1;
        switch (store.persistent_failure) {
            .none => {},
            .missing => return error.FileNotFound,
            .invalid => return error.InvalidRecord,
            .denied => return error.AccessDenied,
        }
        stats.unique_query_terms = 2;
        stats.matched_terms = 1;
        stats.postings_count_total = 7;
        stats.max_postings_count = 7;
    }

    pub fn fillStoreScanPlanStats(
        _: std.mem.Allocator,
        store: TestStorage.Store,
        _: []const u8,
        _: test_search_contract.TextSearchOptions,
        max_metadata_bytes: u64,
        max_property_delta_bytes: u64,
        stats: anytype,
    ) anyerror!void {
        store.trace.store_scan_plan_calls += 1;
        store.trace.admitted_metadata_bytes = max_metadata_bytes;
        store.trace.admitted_property_delta_bytes = max_property_delta_bytes;
        stats.* = .{
            .query_terms = 3,
            .unique_query_terms = 2,
            .matched_terms = 2,
            .postings_count_total = 9,
            .max_postings_count = 6,
        };
    }
};

const test_query = QueryExecution(TestCore, TestSchema, TestStorage, TestOps);

test "query execution routes current catalog to persistent tokens" {
    var trace = TestTrace{};
    var hits = try test_query.searchText(std.testing.allocator, .{ .trace = &trace }, "alpha beta", .{});
    defer hits.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), trace.quick_stale_calls);
    try std.testing.expectEqual(@as(usize, 1), trace.persistent_search_calls);
    try std.testing.expectEqual(@as(usize, 0), trace.store_scan_search_calls);
    try std.testing.expectEqual(@as(u64, 11), hits.items[0].node_id.toInt());
}

test "query execution admits bounded stale store scan" {
    var trace = TestTrace{};
    const store = TestStorage.Store{
        .trace = &trace,
        .stale = true,
        .logical_text_bytes = 17,
    };
    var hits = try test_query.searchText(std.testing.allocator, store, "alpha", .{});
    defer hits.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), trace.persistent_search_calls);
    try std.testing.expectEqual(@as(usize, 1), trace.store_scan_search_calls);
    try std.testing.expectEqual(test_query.stale_store_scan_max_text_bytes - 17, trace.admitted_metadata_bytes);
    try std.testing.expectEqual(test_query.stale_store_scan_max_property_delta_bytes, trace.admitted_property_delta_bytes);
    try std.testing.expectEqual(@as(u64, 22), hits.items[0].node_id.toInt());
}

test "query execution falls back only for recoverable persistent errors" {
    var missing_trace = TestTrace{};
    var fallback_hits = try test_query.searchText(std.testing.allocator, .{
        .trace = &missing_trace,
        .persistent_failure = .missing,
    }, "alpha", .{});
    defer fallback_hits.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), missing_trace.store_scan_search_calls);

    var denied_trace = TestTrace{};
    try std.testing.expectError(error.AccessDenied, test_query.searchText(std.testing.allocator, .{
        .trace = &denied_trace,
        .persistent_failure = .denied,
    }, "alpha", .{}));
    try std.testing.expectEqual(@as(usize, 0), denied_trace.store_scan_search_calls);
}

test "query execution rejects unbounded stale scans before data plane" {
    try std.testing.expect(test_query.Internal.staleStoreScanAllowed(
        test_query.stale_store_scan_max_nodes,
        test_query.stale_store_scan_max_text_bytes,
        test_query.stale_store_scan_max_event_bytes,
        test_query.stale_store_scan_max_property_delta_bytes,
    ));
    try std.testing.expect(!test_query.Internal.staleStoreScanAllowed(test_query.stale_store_scan_max_nodes + 1, 0, 0, 0));

    var trace = TestTrace{};
    try std.testing.expectError(error.TextIndexMaintenanceRequired, test_query.searchText(std.testing.allocator, .{
        .trace = &trace,
        .stale = true,
        .node_count = test_query.stale_store_scan_max_nodes + 1,
    }, "alpha", .{}));
    try std.testing.expectEqual(@as(usize, 0), trace.store_scan_search_calls);
}

test "query execution preserves deadline empty and tokenizer admission gates" {
    var trace = TestTrace{};
    try std.testing.expectError(TestCore.Error.BudgetExceeded, test_query.searchText(std.testing.allocator, .{ .trace = &trace }, "alpha", .{ .deadline = .immediate }));

    var empty_hits = try test_query.searchText(std.testing.allocator, .{ .trace = &trace }, "!!!", .{});
    defer empty_hits.deinit(std.testing.allocator);
    var limited_hits = try test_query.searchText(std.testing.allocator, .{ .trace = &trace }, "alpha", .{ .limit = 0 });
    defer limited_hits.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), trace.quick_stale_calls);

    try std.testing.expectError(TestCore.Error.Unsupported, test_query.searchText(std.testing.allocator, .{ .trace = &trace }, "alpha", .{
        .tokenizer = .{ .max_token_bytes = tokenizer_mod.default_max_token_bytes - 1 },
    }));
}

test "query execution plan stats preserve persistent and fallback routing" {
    var current_trace = TestTrace{};
    const current = try test_query.textQueryPlanStats(std.testing.allocator, .{ .trace = &current_trace }, "alpha beta", .{});
    try std.testing.expectEqual(@as(usize, 2), current.query_terms);
    try std.testing.expectEqual(@as(usize, 1), current_trace.persistent_plan_calls);
    try std.testing.expectEqual(@as(u64, 7), current.postings_count_total);

    var fallback_trace = TestTrace{};
    const fallback = try test_query.textQueryPlanStats(std.testing.allocator, .{
        .trace = &fallback_trace,
        .persistent_failure = .invalid,
    }, "alpha beta", .{});
    try std.testing.expectEqual(@as(usize, 1), fallback_trace.persistent_plan_calls);
    try std.testing.expectEqual(@as(usize, 1), fallback_trace.store_scan_plan_calls);
    try std.testing.expectEqual(@as(u64, 9), fallback.postings_count_total);
}
