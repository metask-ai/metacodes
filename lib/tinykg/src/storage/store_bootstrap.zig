const std = @import("std");

/// Owns the create-or-repair control plane for an empty-capable store. The
/// storage facade keeps concrete paths, file probes, codecs, publication, and
/// repair mechanics behind `Ops`; this controller owns which mutations are
/// admissible and their ordering.
pub fn StoreBootstrap(comptime Ops: type) type {
    return struct {
        pub fn ensure(context: anytype) !void {
            if (!try Ops.eventLogExists(context)) {
                if (try Ops.anyDerivedGraphCatalogPathExists(context)) {
                    return error.InvalidRecord;
                }
                try Ops.createEventLog(context);
            }

            if (!Ops.validateIndexesOnRead(context) and
                try Ops.fastPersistentIndexesCurrent(context))
            {
                return;
            }

            const stats = try Ops.stats(context);
            const node_catalogs = try Ops.inspectNodeCatalogs(context);

            if (node_catalogs.missing_node_by_id and stats.nodes == 0) {
                try Ops.writeEmptyNodeIndexes(context);
            }
            if (node_catalogs.missing_node_texts and
                stats.nodes == 0 and
                !node_catalogs.missing_node_by_id)
            {
                try Ops.writeEmptyNodeTexts(context);
            }
            if (node_catalogs.missing_node_by_text and
                stats.nodes == 0 and
                !node_catalogs.missing_node_by_id)
            {
                try Ops.writeEmptyNodeTextIndex(context);
            }
            if (node_catalogs.missing_node_by_text_delta and
                stats.nodes == 0 and
                !node_catalogs.missing_node_by_id)
            {
                try Ops.writeEmptyNodeTextDelta(context);
            }
            if (node_catalogs.missing_external_key_index and
                stats.nodes == 0 and
                !node_catalogs.missing_node_by_id)
            {
                try Ops.writeEmptyExternalKeyIndex(context);
            }
            if ((node_catalogs.missing_node_props_index or
                node_catalogs.missing_node_props_values) and
                stats.nodes == 0 and
                !node_catalogs.missing_node_by_id)
            {
                try Ops.writeEmptyNodePropertyIndex(context);
            }
            if (node_catalogs.missing_edge_external_key_index and
                stats.edges == 0 and
                !node_catalogs.missing_node_by_id)
            {
                try Ops.writeEmptyEdgeExternalKeyIndex(context);
            }
            if ((node_catalogs.missing_node_by_id or
                node_catalogs.missing_node_texts or
                node_catalogs.missing_node_by_text or
                node_catalogs.missing_node_by_text_delta or
                node_catalogs.missing_node_props_index or
                node_catalogs.missing_node_props_values) and
                stats.nodes != 0)
            {
                return Ops.repairPersistentIndexes(context);
            }

            const edge_catalogs = try Ops.inspectEdgeCatalogs(context);
            if (edge_catalogs.missing_id and stats.edges == 0) {
                try Ops.writeEmptyEdgeIdIndex(context);
            }
            if (edge_catalogs.missing_src and stats.edges == 0) {
                try Ops.writeEmptyEdgeSrcIndex(context);
            }
            if (edge_catalogs.missing_dst and stats.edges == 0) {
                try Ops.writeEmptyEdgeDstIndex(context);
            }
            if (edge_catalogs.missing_order) {
                try Ops.writeEmptyEdgeOrderIndex(context);
            }
            if (edge_catalogs.missing_tombstones and stats.edges == 0) {
                try Ops.writeEmptyEdgeTombstoneIndex(context);
            }
            if ((edge_catalogs.missing_id or
                edge_catalogs.missing_src or
                edge_catalogs.missing_dst or
                edge_catalogs.missing_tombstones) and
                stats.edges != 0)
            {
                return Ops.repairPersistentIndexes(context);
            }

            if (node_catalogs.missing_meta) {
                try Ops.writeIndexMetaFromStats(context, stats);
            }
            if (!try Ops.persistentIndexesCurrent(context, stats)) {
                try Ops.repairPersistentIndexes(context);
            }

            if (!try Ops.catalogExists(context)) {
                Ops.writeKernelCatalog(context) catch {};
            }
        }
    };
}

const TestStats = struct {
    nodes: usize = 0,
    edges: usize = 0,
};

const TestNodeCatalogs = struct {
    missing_meta: bool = false,
    missing_node_by_id: bool = false,
    missing_node_texts: bool = false,
    missing_node_by_text: bool = false,
    missing_node_by_text_delta: bool = false,
    missing_external_key_index: bool = false,
    missing_node_props_index: bool = false,
    missing_node_props_values: bool = false,
    missing_edge_external_key_index: bool = false,
};

const TestEdgeCatalogs = struct {
    missing_id: bool = false,
    missing_src: bool = false,
    missing_dst: bool = false,
    missing_order: bool = false,
    missing_tombstones: bool = false,
};

const TestPhase = enum {
    event_log_exists,
    derived_catalog_exists,
    create_event_log,
    validate_indexes_on_read,
    fast_indexes_current,
    stats,
    inspect_node_catalogs,
    write_node_indexes,
    write_node_texts,
    write_node_text_index,
    write_node_text_delta,
    write_external_key_index,
    write_node_property_index,
    write_edge_external_key_index,
    inspect_edge_catalogs,
    write_edge_id_index,
    write_edge_src_index,
    write_edge_dst_index,
    write_edge_order_index,
    write_edge_tombstone_index,
    write_index_meta,
    persistent_indexes_current,
    repair_indexes,
    catalog_exists,
    write_kernel_catalog,
};

const TestContext = struct {
    phases: [32]TestPhase = undefined,
    phase_count: usize = 0,
    event_log_exists: bool = true,
    derived_catalog_exists: bool = false,
    validate_indexes: bool = true,
    fast_indexes_current: bool = false,
    stats_value: TestStats = .{},
    node_catalogs: TestNodeCatalogs = .{},
    edge_catalogs: TestEdgeCatalogs = .{},
    persistent_indexes_are_current: bool = true,
    catalog_exists: bool = true,
    catalog_write_fails: bool = false,

    fn record(self: *TestContext, phase: TestPhase) void {
        self.phases[self.phase_count] = phase;
        self.phase_count += 1;
    }

    fn recorded(self: *const TestContext) []const TestPhase {
        return self.phases[0..self.phase_count];
    }
};

const TestOps = struct {
    fn eventLogExists(context: *TestContext) !bool {
        context.record(.event_log_exists);
        return context.event_log_exists;
    }

    fn anyDerivedGraphCatalogPathExists(context: *TestContext) !bool {
        context.record(.derived_catalog_exists);
        return context.derived_catalog_exists;
    }

    fn createEventLog(context: *TestContext) !void {
        context.record(.create_event_log);
        context.event_log_exists = true;
    }

    fn validateIndexesOnRead(context: *TestContext) bool {
        context.record(.validate_indexes_on_read);
        return context.validate_indexes;
    }

    fn fastPersistentIndexesCurrent(context: *TestContext) !bool {
        context.record(.fast_indexes_current);
        return context.fast_indexes_current;
    }

    fn stats(context: *TestContext) !TestStats {
        context.record(.stats);
        return context.stats_value;
    }

    fn inspectNodeCatalogs(context: *TestContext) !TestNodeCatalogs {
        context.record(.inspect_node_catalogs);
        return context.node_catalogs;
    }

    fn writeEmptyNodeIndexes(context: *TestContext) !void {
        context.record(.write_node_indexes);
    }

    fn writeEmptyNodeTexts(context: *TestContext) !void {
        context.record(.write_node_texts);
    }

    fn writeEmptyNodeTextIndex(context: *TestContext) !void {
        context.record(.write_node_text_index);
    }

    fn writeEmptyNodeTextDelta(context: *TestContext) !void {
        context.record(.write_node_text_delta);
    }

    fn writeEmptyExternalKeyIndex(context: *TestContext) !void {
        context.record(.write_external_key_index);
    }

    fn writeEmptyNodePropertyIndex(context: *TestContext) !void {
        context.record(.write_node_property_index);
    }

    fn writeEmptyEdgeExternalKeyIndex(context: *TestContext) !void {
        context.record(.write_edge_external_key_index);
    }

    fn inspectEdgeCatalogs(context: *TestContext) !TestEdgeCatalogs {
        context.record(.inspect_edge_catalogs);
        return context.edge_catalogs;
    }

    fn writeEmptyEdgeIdIndex(context: *TestContext) !void {
        context.record(.write_edge_id_index);
    }

    fn writeEmptyEdgeSrcIndex(context: *TestContext) !void {
        context.record(.write_edge_src_index);
    }

    fn writeEmptyEdgeDstIndex(context: *TestContext) !void {
        context.record(.write_edge_dst_index);
    }

    fn writeEmptyEdgeOrderIndex(context: *TestContext) !void {
        context.record(.write_edge_order_index);
    }

    fn writeEmptyEdgeTombstoneIndex(context: *TestContext) !void {
        context.record(.write_edge_tombstone_index);
    }

    fn writeIndexMetaFromStats(context: *TestContext, stats_value: TestStats) !void {
        _ = stats_value;
        context.record(.write_index_meta);
    }

    fn persistentIndexesCurrent(context: *TestContext, stats_value: TestStats) !bool {
        _ = stats_value;
        context.record(.persistent_indexes_current);
        return context.persistent_indexes_are_current;
    }

    fn repairPersistentIndexes(context: *TestContext) !void {
        context.record(.repair_indexes);
    }

    fn catalogExists(context: *TestContext) !bool {
        context.record(.catalog_exists);
        return context.catalog_exists;
    }

    fn writeKernelCatalog(context: *TestContext) !void {
        context.record(.write_kernel_catalog);
        if (context.catalog_write_fails) return error.AccessDenied;
    }
};

const test_bootstrap = StoreBootstrap(TestOps);

test "store bootstrap rejects missing append log when derived catalogs exist" {
    var context = TestContext{
        .event_log_exists = false,
        .derived_catalog_exists = true,
    };

    try std.testing.expectError(error.InvalidRecord, test_bootstrap.ensure(&context));
    try std.testing.expectEqualSlices(TestPhase, &.{
        .event_log_exists,
        .derived_catalog_exists,
    }, context.recorded());
}

test "store bootstrap creates a missing append log before inspecting indexes" {
    var context = TestContext{
        .event_log_exists = false,
        .validate_indexes = false,
        .fast_indexes_current = true,
    };

    try test_bootstrap.ensure(&context);
    try std.testing.expectEqualSlices(TestPhase, &.{
        .event_log_exists,
        .derived_catalog_exists,
        .create_event_log,
        .validate_indexes_on_read,
        .fast_indexes_current,
    }, context.recorded());
}

test "store bootstrap fast path performs no stats or catalog mutations" {
    var context = TestContext{
        .validate_indexes = false,
        .fast_indexes_current = true,
    };

    try test_bootstrap.ensure(&context);
    try std.testing.expectEqualSlices(TestPhase, &.{
        .event_log_exists,
        .validate_indexes_on_read,
        .fast_indexes_current,
    }, context.recorded());
}

test "store bootstrap initializes empty catalogs in dependency order" {
    var context = TestContext{
        .node_catalogs = .{
            .missing_meta = true,
            .missing_node_texts = true,
            .missing_node_by_text = true,
            .missing_node_by_text_delta = true,
            .missing_external_key_index = true,
            .missing_node_props_index = true,
            .missing_node_props_values = true,
            .missing_edge_external_key_index = true,
        },
        .edge_catalogs = .{
            .missing_id = true,
            .missing_src = true,
            .missing_dst = true,
            .missing_order = true,
            .missing_tombstones = true,
        },
        .catalog_exists = false,
    };

    try test_bootstrap.ensure(&context);
    try std.testing.expectEqualSlices(TestPhase, &.{
        .event_log_exists,
        .validate_indexes_on_read,
        .stats,
        .inspect_node_catalogs,
        .write_node_texts,
        .write_node_text_index,
        .write_node_text_delta,
        .write_external_key_index,
        .write_node_property_index,
        .write_edge_external_key_index,
        .inspect_edge_catalogs,
        .write_edge_id_index,
        .write_edge_src_index,
        .write_edge_dst_index,
        .write_edge_order_index,
        .write_edge_tombstone_index,
        .write_index_meta,
        .persistent_indexes_current,
        .catalog_exists,
        .write_kernel_catalog,
    }, context.recorded());
}

test "store bootstrap lets canonical empty node indexes own their dependent files" {
    var context = TestContext{
        .node_catalogs = .{
            .missing_node_by_id = true,
            .missing_node_texts = true,
            .missing_node_by_text = true,
            .missing_node_by_text_delta = true,
            .missing_external_key_index = true,
            .missing_node_props_index = true,
            .missing_edge_external_key_index = true,
        },
    };

    try test_bootstrap.ensure(&context);
    try std.testing.expectEqualSlices(TestPhase, &.{
        .event_log_exists,
        .validate_indexes_on_read,
        .stats,
        .inspect_node_catalogs,
        .write_node_indexes,
        .inspect_edge_catalogs,
        .persistent_indexes_current,
        .catalog_exists,
    }, context.recorded());
}

test "store bootstrap repairs non-empty node catalogs before probing edge catalogs" {
    var context = TestContext{
        .stats_value = .{ .nodes = 3 },
        .node_catalogs = .{ .missing_node_texts = true },
    };

    try test_bootstrap.ensure(&context);
    try std.testing.expectEqualSlices(TestPhase, &.{
        .event_log_exists,
        .validate_indexes_on_read,
        .stats,
        .inspect_node_catalogs,
        .repair_indexes,
    }, context.recorded());
}

test "store bootstrap repairs non-empty edge catalogs before metadata publication" {
    var context = TestContext{
        .stats_value = .{ .edges = 2 },
        .node_catalogs = .{ .missing_meta = true },
        .edge_catalogs = .{ .missing_id = true },
    };

    try test_bootstrap.ensure(&context);
    try std.testing.expectEqualSlices(TestPhase, &.{
        .event_log_exists,
        .validate_indexes_on_read,
        .stats,
        .inspect_node_catalogs,
        .inspect_edge_catalogs,
        .repair_indexes,
    }, context.recorded());
}

test "store bootstrap repairs stale indexes and treats catalog creation as best effort" {
    var context = TestContext{
        .persistent_indexes_are_current = false,
        .catalog_exists = false,
        .catalog_write_fails = true,
    };

    try test_bootstrap.ensure(&context);
    try std.testing.expectEqualSlices(TestPhase, &.{
        .event_log_exists,
        .validate_indexes_on_read,
        .stats,
        .inspect_node_catalogs,
        .inspect_edge_catalogs,
        .persistent_indexes_current,
        .repair_indexes,
        .catalog_exists,
        .write_kernel_catalog,
    }, context.recorded());
}
