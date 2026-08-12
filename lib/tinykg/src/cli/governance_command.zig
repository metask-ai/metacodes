const std = @import("std");
const core = @import("../core.zig");
const query = @import("../query.zig");
const schema = @import("../schema.zig");
const segment_mod = @import("../segment.zig");
const storage = @import("../storage.zig");
const text_search = @import("../text.zig");
const schema_commands_mod = @import("schema_commands.zig");

const schema_arguments = schema_commands_mod.SchemaArguments;

const governance_sample_limit: usize = 8;
const governance_high_fanout_threshold: u64 = 128;
const governance_navigation_fanout_target_min: u64 = 5;
const governance_navigation_fanout_target_max: u64 = 32;
const governance_navigation_fanout_warn_threshold: u64 = 64;
const governance_high_fanout_name_sample_bytes: usize = 256;

fn monotonicNs(io: std.Io) u128 {
    const timestamp = std.Io.Clock.awake.now(io).nanoseconds;
    return if (timestamp < 0) 0 else @intCast(timestamp);
}

fn elapsedNs(io: std.Io, start: u128) u128 {
    const now = monotonicNs(io);
    return if (now >= start) now - start else 0;
}

const BufferWriter = struct {
    allocator: std.mem.Allocator,
    buffer: std.ArrayList(u8) = .empty,

    pub fn writeAll(self: *BufferWriter, bytes: []const u8) !void {
        try self.buffer.appendSlice(self.allocator, bytes);
    }

    pub fn print(self: *BufferWriter, comptime fmt: []const u8, args: anytype) !void {
        const rendered = try std.fmt.allocPrint(self.allocator, fmt, args);
        defer self.allocator.free(rendered);
        try self.writeAll(rendered);
    }
};

fn writeEscapedText(writer: anytype, value: []const u8) !void {
    for (value) |byte| {
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

fn writeEscapedTextPrefix(writer: anytype, value: []const u8, max_bytes: usize) !void {
    if (value.len <= max_bytes) return writeEscapedText(writer, value);
    var end: usize = 0;
    while (end < value.len and end < max_bytes) {
        const width = std.unicode.utf8ByteSequenceLength(value[end]) catch 1;
        if (end + width > value.len or end + width > max_bytes) break;
        end += width;
    }
    try writeEscapedText(writer, value[0..end]);
    try writer.writeAll("...");
}

fn writeNodeKindName(writer: anytype, kind: core.NodeKind) !void {
    inline for (@typeInfo(core.NodeKind).@"enum".fields) |field| {
        if (@intFromEnum(kind) == field.value) return writer.writeAll(field.name);
    }
    try writer.print("type#{}", .{@intFromEnum(kind)});
}

fn writeRelKindName(writer: anytype, rel: core.RelKind) !void {
    inline for (@typeInfo(core.RelKind).@"enum".fields) |field| {
        if (@intFromEnum(rel) == field.value) return writer.writeAll(field.name);
    }
    if (schema.markdownProjectionRelationNameById(@intFromEnum(rel))) |name| return writer.writeAll(name);
    try writer.print("rel#{}", .{@intFromEnum(rel)});
}

/// Complete Governance command and report owner behind the stable CLI façade.
///
/// Command admission, schema/catalog context lifetime, role and fanout scans,
/// schema/property/composition accounting, progress feedback, bounded samples,
/// and success-only report publication stay in this module. Shared database
/// probing, CLI locking, schema loading and lower-level endpoint validation
/// remain concrete façade ports because they are consumed by other commands.
pub fn GovernanceCommand(comptime Ops: type) type {
    return struct {
        pub fn run(
            args: []const []const u8,
            writer: anytype,
            allocator: std.mem.Allocator,
            io: std.Io,
        ) !void {
            const parsed = try Ops.parseDbArguments(allocator, io, args);
            const selection = try schema_arguments.parseOnlyRest(parsed.rest);
            var context = try Ops.Context.init(
                allocator,
                io,
                parsed.db_path,
                selection.schema_path,
                selection.profiles,
            );
            defer context.deinit();
            try renderGovernanceReport(
                Ops,
                allocator,
                io,
                parsed.db_path,
                context.storeHandle(),
                context.schemaRegistry(),
                writer,
            );
        }

        pub fn render(
            allocator: std.mem.Allocator,
            io: std.Io,
            db_path: []const u8,
            store: storage.Store,
            registry: ?schema.Registry,
            writer: anytype,
        ) !void {
            return renderGovernanceReport(Ops, allocator, io, db_path, store, registry, writer);
        }
    };
}

const governance_progress_interval: u64 = 1_000_000;

fn governanceProgress(writer: anytype, io: std.Io, phase: []const u8, status: []const u8, checked: u64, total: u64, phase_start_ns: u128, what: []const u8) !void {
    const elapsed_ms = elapsedNs(io, phase_start_ns) / 1_000_000;
    try writer.print(
        "governance_progress phase={s} status={s} checked={} total={} elapsed_ms={} what=\"{s}\"\n",
        .{ phase, status, checked, total, elapsed_ms, what },
    );
    const Writer = @TypeOf(writer);
    const writer_info = @typeInfo(Writer);
    const can_flush = comptime switch (writer_info) {
        .pointer => |pointer| @hasDecl(pointer.child, "flush"),
        else => @hasDecl(Writer, "flush"),
    };
    if (can_flush) {
        try writer.flush();
    }
}

fn governanceProgressMaybe(writer: anytype, io: std.Io, phase: []const u8, checked: u64, total: u64, phase_start_ns: u128, what: []const u8) !void {
    if (checked == 0) return;
    if (checked % governance_progress_interval != 0 and checked != total) return;
    try governanceProgress(writer, io, phase, "progress", checked, total, phase_start_ns, what);
}

fn renderGovernanceReport(comptime Ops: type, allocator: std.mem.Allocator, io: std.Io, db_path: []const u8, store: storage.Store, registry: ?schema.Registry, writer: anytype) !void {
    var phase_start_ns = monotonicNs(io);
    try governanceProgress(writer, io, "store_summary", "begin", 0, 0, phase_start_ns, "reading store stats, store size, and text index presence");
    const stats_out = try store.stats();
    const store_bytes = try Ops.storeDirBytes(allocator, io, db_path);
    const text_docs_exists = (try Ops.storeFileSize(allocator, io, db_path, "text_docs.idx")) != null;
    const text_terms_exists = (try Ops.storeFileSize(allocator, io, db_path, "text_terms.idx")) != null;
    const text_postings_exists = (try Ops.storeFileSize(allocator, io, db_path, "text_postings.dat")) != null;
    const text_files_present = text_docs_exists and text_terms_exists and text_postings_exists;
    const text_warm = text_files_present and !try text_search.persistentTextCatalogQuickStale(allocator, store);
    try governanceProgress(writer, io, "store_summary", "end", 1, 1, phase_start_ns, "store summary loaded");

    var isolated_nodes: u64 = 0;
    var tombstone_nodes: u64 = 0;
    var oversized_text_nodes: u64 = 0;
    var max_outgoing_edges: u64 = 0;
    var high_fanout_nodes: u64 = 0;
    var navigation_fanout_violations: u64 = 0;
    var isolated_samples: usize = 0;
    var tombstone_samples: usize = 0;
    var oversized_text_samples: usize = 0;
    var high_fanout_samples: usize = 0;
    var navigation_fanout_samples: usize = 0;
    const id_count = @as(usize, std.math.maxInt(u16)) + 1;
    const node_kind_counts = try allocator.alloc(u64, id_count);
    defer allocator.free(node_kind_counts);
    @memset(node_kind_counts, 0);
    const rel_kind_counts = try allocator.alloc(u64, id_count);
    defer allocator.free(rel_kind_counts);
    @memset(rel_kind_counts, 0);
    var role_index = GovernanceRoleIndex.init(allocator);
    defer role_index.deinit();

    phase_start_ns = monotonicNs(io);
    try governanceProgress(writer, io, "property_snapshot", "begin", 0, 0, phase_start_ns, "loading node and edge property snapshot for governance lookups");
    var property_snapshot = try GovernancePropertySnapshot.load(allocator, store);
    defer property_snapshot.deinit(allocator);
    const property_count: u64 = @intCast(property_snapshot.backing.entries.len);
    try governanceProgress(writer, io, "property_snapshot", "end", property_count, property_count, phase_start_ns, "property snapshot ready");

    var role_nodes = try store.nodeRecordsIterator(null);
    defer role_nodes.deinit();
    var sample_buffer = BufferWriter{ .allocator = allocator };
    defer sample_buffer.buffer.deinit(allocator);
    var outgoing_relation_counts: std.ArrayList(GovernanceRelationCount) = .empty;
    defer outgoing_relation_counts.deinit(allocator);

    phase_start_ns = monotonicNs(io);
    try governanceProgress(writer, io, "scan_nodes_roles", "begin", 0, stats_out.nodes, phase_start_ns, "scanning nodes for kind counts and governance roles");
    var scanned_nodes: u64 = 0;
    while (try role_nodes.next(allocator)) |stored_node| {
        var node = stored_node;
        defer node.deinit(allocator);
        node_kind_counts[@as(usize, @intFromEnum(node.kind))] += 1;
        try role_index.recordNode(&property_snapshot, node);
        scanned_nodes += 1;
        try governanceProgressMaybe(writer, io, "scan_nodes_roles", scanned_nodes, stats_out.nodes, phase_start_ns, "scanning nodes for kind counts and governance roles");
    }
    try governanceProgress(writer, io, "scan_nodes_roles", "end", scanned_nodes, stats_out.nodes, phase_start_ns, "node role scan complete");

    var fanout_by_src = std.AutoHashMap(u64, GovernanceFanoutStats).init(allocator);
    defer fanout_by_src.deinit();
    var incoming_nodes = std.AutoHashMap(u64, void).init(allocator);
    defer incoming_nodes.deinit();
    try fanout_by_src.ensureTotalCapacity(@intCast(@min(stats_out.edges, @as(u64, 65536))));
    try incoming_nodes.ensureTotalCapacity(@intCast(@min(stats_out.edges, @as(u64, 65536))));

    phase_start_ns = monotonicNs(io);
    try governanceProgress(writer, io, "scan_edges", "begin", 0, stats_out.edges, phase_start_ns, "scanning visible edges for relation counts, fanout, and incoming nodes");
    var scanned_edges: u64 = 0;
    const GovernanceEdgeScanContext = struct {
        allocator: std.mem.Allocator,
        registry: ?schema.Registry,
        properties: *const GovernancePropertySnapshot,
        roles: *GovernanceRoleIndex,
        fanout_by_src: *std.AutoHashMap(u64, GovernanceFanoutStats),
        incoming_nodes: *std.AutoHashMap(u64, void),
        rel_kind_counts: []u64,
        scanned_edges: *u64,
        writer: @TypeOf(writer),
        io: std.Io,
        total: u64,
        phase_start_ns: u128,

        fn visit(raw_context: *anyopaque, record: storage.EdgeIndexRecord) anyerror!void {
            const context: *@This() = @ptrCast(@alignCast(raw_context));
            const edge = storedEdgeRefFromIndexRecord(record);
            try recordGovernanceEdgeStats(
                context.allocator,
                context.registry,
                context.properties,
                context.roles,
                context.fanout_by_src,
                context.incoming_nodes,
                context.rel_kind_counts,
                edge,
            );
            context.scanned_edges.* = std.math.add(u64, context.scanned_edges.*, 1) catch return error.RecordTooLarge;
            try governanceProgressMaybe(
                context.writer,
                context.io,
                "scan_edges",
                context.scanned_edges.*,
                context.total,
                context.phase_start_ns,
                "scanning visible edges for relation counts, fanout, and incoming nodes",
            );
        }
    };
    var governance_edge_scan_context = GovernanceEdgeScanContext{
        .allocator = allocator,
        .registry = registry,
        .properties = &property_snapshot,
        .roles = &role_index,
        .fanout_by_src = &fanout_by_src,
        .incoming_nodes = &incoming_nodes,
        .rel_kind_counts = rel_kind_counts,
        .scanned_edges = &scanned_edges,
        .writer = writer,
        .io = io,
        .total = stats_out.edges,
        .phase_start_ns = phase_start_ns,
    };
    const scanned_visible_edges = try store.scanVisibleEdgeIndexRecords(allocator, &governance_edge_scan_context, GovernanceEdgeScanContext.visit);
    if (scanned_visible_edges != scanned_edges) return error.InvalidRecord;
    try governanceProgress(writer, io, "scan_edges", "end", scanned_edges, stats_out.edges, phase_start_ns, "edge scan complete");

    phase_start_ns = monotonicNs(io);
    try governanceProgress(writer, io, "deferred_sidecar", "begin", 0, 0, phase_start_ns, "reading deferred based_on sidecar edges");
    var deferred_based_on = try Ops.readDeferredBasedOnPairs(allocator, io, db_path);
    defer deferred_based_on.deinit(allocator);
    if (deferred_based_on.present) {
        for (deferred_based_on.pairs.items, 0..) |pair, index| {
            const edge = storage.StoredEdgeRef{
                .src = core.NodeId.fromInt(pair.src),
                .dst = core.NodeId.fromInt(pair.dst),
                .edge_id = core.EdgeId.fromInt(query.metaknow_deferred_based_on_edge_id_base + @as(u64, @intCast(index)) + 1),
                .rel = .based_on,
            };
            try recordGovernanceEdgeStats(allocator, registry, &property_snapshot, &role_index, &fanout_by_src, &incoming_nodes, rel_kind_counts, edge);
        }
    }
    try governanceProgress(writer, io, "deferred_sidecar", "end", deferred_based_on.pairs.items.len, deferred_based_on.pairs.items.len, phase_start_ns, "deferred sidecar scan complete");

    var nodes = try store.nodeRecordsIterator(null);
    defer nodes.deinit();
    phase_start_ns = monotonicNs(io);
    try governanceProgress(writer, io, "scan_nodes_health", "begin", 0, stats_out.nodes, phase_start_ns, "checking isolated nodes, tombstones, oversized text, and fanout samples");
    scanned_nodes = 0;
    while (try nodes.next(allocator)) |stored_node| {
        var node = stored_node;
        defer node.deinit(allocator);
        scanned_nodes += 1;
        try governanceProgressMaybe(writer, io, "scan_nodes_health", scanned_nodes, stats_out.nodes, phase_start_ns, "checking isolated nodes, tombstones, oversized text, and fanout samples");
        const fanout = fanout_by_src.get(node.id.toInt()) orelse GovernanceFanoutStats{};
        if (fanout.outgoing_edges > max_outgoing_edges) max_outgoing_edges = fanout.outgoing_edges;
        if (fanout.navigation_relation_edges > governance_navigation_fanout_warn_threshold) {
            navigation_fanout_violations += 1;
            if (navigation_fanout_samples < governance_sample_limit) {
                outgoing_relation_counts.clearRetainingCapacity();
                try collectGovernanceRelationCountsForNode(allocator, store, &outgoing_relation_counts, node.id);
                try sample_buffer.print("navigation_fanout_violation_sample id={} kind=", .{node.id.toInt()});
                try writeNodeKindName(&sample_buffer, node.kind);
                try sample_buffer.print(
                    " navigation_edges={} outgoing_edges={}",
                    .{ fanout.navigation_relation_edges, fanout.outgoing_edges },
                );
                try writeGovernanceRelationCountSummary(&sample_buffer, registry, outgoing_relation_counts.items);
                try sample_buffer.writeAll(" name=");
                try writeEscapedTextPrefix(&sample_buffer, node.text, governance_high_fanout_name_sample_bytes);
                try sample_buffer.writeAll("\n");
                navigation_fanout_samples += 1;
            }
        }
        if (fanout.outgoing_edges >= governance_high_fanout_threshold) {
            high_fanout_nodes += 1;
            if (high_fanout_samples < governance_sample_limit) {
                outgoing_relation_counts.clearRetainingCapacity();
                try collectGovernanceRelationCountsForNode(allocator, store, &outgoing_relation_counts, node.id);
                try sample_buffer.print("high_fanout_node_sample id={} kind=", .{node.id.toInt()});
                try writeNodeKindName(&sample_buffer, node.kind);
                try sample_buffer.print(" outgoing_edges={}", .{fanout.outgoing_edges});
                try writeGovernanceRelationCountSummary(&sample_buffer, registry, outgoing_relation_counts.items);
                try sample_buffer.writeAll(" name=");
                try writeEscapedTextPrefix(&sample_buffer, node.text, governance_high_fanout_name_sample_bytes);
                try sample_buffer.writeAll("\n");
                high_fanout_samples += 1;
            }
        }
        const is_tombstone = Ops.isDeletedNodeTombstone(node);
        if (is_tombstone) {
            tombstone_nodes += 1;
            if (tombstone_samples < governance_sample_limit) {
                try sample_buffer.print("tombstone_node_sample id={} kind=", .{node.id.toInt()});
                try writeNodeKindName(&sample_buffer, node.kind);
                try sample_buffer.writeAll(" name=");
                try writeEscapedText(&sample_buffer, node.text);
                try sample_buffer.writeAll("\n");
                tombstone_samples += 1;
            }
            continue;
        }
        const governance_visible_text = Ops.visibleNodeText(node.text);
        const node_text_chars = std.unicode.utf8CountCodepoints(governance_visible_text) catch 0;
        if (node_text_chars > Ops.nodeTextCharLimit()) {
            oversized_text_nodes += 1;
            if (oversized_text_samples < governance_sample_limit) {
                try sample_buffer.print("oversized_node_text_sample id={} kind=", .{node.id.toInt()});
                try writeNodeKindName(&sample_buffer, node.kind);
                try sample_buffer.print(" chars={} limit={} name=", .{ node_text_chars, Ops.nodeTextCharLimit() });
                try writeEscapedTextPrefix(&sample_buffer, governance_visible_text, governance_high_fanout_name_sample_bytes);
                try sample_buffer.writeAll("\n");
                oversized_text_samples += 1;
            }
        }
        if (fanout.outgoing_edges == 0 and !incoming_nodes.contains(node.id.toInt())) {
            isolated_nodes += 1;
            if (isolated_samples < governance_sample_limit) {
                try sample_buffer.print("isolated_node_sample id={} kind=", .{node.id.toInt()});
                try writeNodeKindName(&sample_buffer, node.kind);
                try sample_buffer.writeAll(" name=");
                try writeEscapedText(&sample_buffer, node.text);
                try sample_buffer.writeAll("\n");
                isolated_samples += 1;
            }
        }
    }
    try governanceProgress(writer, io, "scan_nodes_health", "end", scanned_nodes, stats_out.nodes, phase_start_ns, "node health scan complete");

    const active_nodes = stats_out.nodes - tombstone_nodes;
    const tombstone_node_ratio_bps: u64 = if (stats_out.nodes == 0)
        0
    else
        @intCast((@as(u128, tombstone_nodes) * 10_000) / @as(u128, stats_out.nodes));
    const tombstone_edges = try store.edgeTombstoneCount();
    const physical_edges = std.math.add(u64, stats_out.edges, tombstone_edges) catch return error.InvalidRecord;
    const tombstone_edge_ratio_bps: u64 = if (physical_edges == 0)
        0
    else
        @intCast((@as(u128, tombstone_edges) * 10_000) / @as(u128, physical_edges));

    try writer.print(
        "db={s}\nnodes={}\nactive_nodes={}\nedges={}\nphysical_edges={}\nstore_dir_bytes={}\ntext_warm={}\ntext_files_present={}\ntext_current={}\ntext_stale={}\nisolated_nodes={}\ntombstone_nodes={}\ntombstone_node_ratio_bps={}\ntombstone_edges={}\ntombstone_edge_ratio_bps={}\noversized_text_nodes={}\nnode_text_char_limit={}\nmax_outgoing_edges={}\nhigh_fanout_nodes={}\nhigh_fanout_threshold={}\nnavigation_entry_nodes={}\nnavigation_fanout_violations={}\nnavigation_fanout_target_min={}\nnavigation_fanout_target_max={}\nnavigation_fanout_warn_threshold={}\n",
        .{
            db_path,
            stats_out.nodes,
            active_nodes,
            stats_out.edges,
            physical_edges,
            store_bytes,
            @intFromBool(text_warm),
            @intFromBool(text_files_present),
            @intFromBool(text_warm),
            @intFromBool(!text_warm),
            isolated_nodes,
            tombstone_nodes,
            tombstone_node_ratio_bps,
            tombstone_edges,
            tombstone_edge_ratio_bps,
            oversized_text_nodes,
            Ops.nodeTextCharLimit(),
            max_outgoing_edges,
            high_fanout_nodes,
            governance_high_fanout_threshold,
            role_index.navigation_entry_nodes,
            navigation_fanout_violations,
            governance_navigation_fanout_target_min,
            governance_navigation_fanout_target_max,
            governance_navigation_fanout_warn_threshold,
        },
    );
    try renderGovernanceDistribution(writer, "node_kind_count", .node, registry, node_kind_counts);
    try renderGovernanceDistribution(writer, "traversable_relation_count", .relation, registry, rel_kind_counts);
    try renderGovernanceRoleStats(writer, &role_index);
    if (registry) |schema_registry| {
        var schema_stats = try governanceSchemaStats(Ops, allocator, store, schema_registry, &property_snapshot, stats_out.nodes, stats_out.edges, writer, io);
        defer schema_stats.deinit(allocator);
        try writer.print(
            "schema_edge_endpoint_violations={}\nschema_unknown_node_type_nodes={}\nschema_unknown_relation_type_edges={}\nschema_unknown_node_properties={}\nschema_unknown_edge_properties={}\nschema_missing_required_node_properties={}\nschema_invalid_property_type={}\nschema_agent_fillable_missing_fields={}\nschema_human_fillable_missing_fields={}\nschema_composition_orphans={}\nschema_composition_cardinality_violations={}\nschema_ordered_composition_missing_ordered_by={}\nschema_ordered_composition_order_source_conflicts={}\nschema_ordered_composition_invalid_order_bindings={}\nschema_duplicate_order_key={}\nschema_legacy_contains_edges={}\nschema_legacy_contains_task_hierarchy_edges={}\nschema_legacy_contains_project_membership_edges={}\nschema_legacy_contains_document_hierarchy_edges={}\nschema_legacy_contains_markdown_occurrence_edges={}\nschema_legacy_contains_unclassified_edges={}\nschema_relation_namespace_class_mismatches={}\nschema_namespaced_relation_endpoint_gaps={}\n",
            .{
                schema_stats.endpoint_violations,
                schema_stats.unknown_node_type_nodes,
                schema_stats.unknown_relation_type_edges,
                schema_stats.unknown_node_properties,
                schema_stats.unknown_edge_properties,
                schema_stats.missing_required_node_properties,
                schema_stats.invalid_property_type,
                schema_stats.agent_fillable_missing_fields,
                schema_stats.human_fillable_missing_fields,
                schema_stats.composition_orphans,
                schema_stats.composition_cardinality_violations,
                schema_stats.ordered_composition_missing_ordered_by,
                schema_stats.ordered_composition_order_source_conflicts,
                schema_stats.ordered_composition_invalid_order_bindings,
                schema_stats.duplicate_order_key,
                schema_stats.legacy_contains_edges,
                schema_stats.legacy_contains_task_hierarchy_edges,
                schema_stats.legacy_contains_project_membership_edges,
                schema_stats.legacy_contains_document_hierarchy_edges,
                schema_stats.legacy_contains_markdown_occurrence_edges,
                schema_stats.legacy_contains_unclassified_edges,
                schema_stats.relation_namespace_class_mismatches,
                schema_stats.namespaced_relation_endpoint_gaps,
            },
        );
        try renderGovernanceEndpointViolationDistribution(writer, schema_registry, &schema_stats.endpoint_violation_relation_counts);
        try renderGovernanceEndpointViolationPairDistribution(allocator, writer, schema_registry, &schema_stats.endpoint_violation_pair_counts);
        try renderGovernanceRelationClassDistribution(writer, schema_registry, rel_kind_counts);
        try writer.writeAll(schema_stats.samples.buffer.items);
    }
    try writer.writeAll(sample_buffer.buffer.items);
}

const GovernanceNodeRole = enum(u8) {
    unknown,
    navigation,
    content,
    entity,
};

const GovernanceRoleIndex = struct {
    allocator: std.mem.Allocator,
    node_roles: std.AutoHashMap(u64, GovernanceNodeRole),
    navigation_entry_nodes: u64 = 0,
    unattached_fact_edges: u64 = 0,
    samples: BufferWriter,

    fn init(allocator: std.mem.Allocator) GovernanceRoleIndex {
        return .{
            .allocator = allocator,
            .node_roles = std.AutoHashMap(u64, GovernanceNodeRole).init(allocator),
            .samples = .{ .allocator = allocator },
        };
    }

    fn deinit(self: *GovernanceRoleIndex) void {
        self.node_roles.deinit();
        self.samples.buffer.deinit(self.allocator);
    }

    fn recordNode(self: *GovernanceRoleIndex, properties: *const GovernancePropertySnapshot, node: storage.StoredNode) !void {
        const schema_type = properties.getString(.{ .node = node.id }, "schema_type");
        try self.recordNodeRole(node.id, governanceRoleForNode(node.kind, schema_type));
    }

    fn recordNodeRole(self: *GovernanceRoleIndex, node_id: core.NodeId, role: GovernanceNodeRole) !void {
        try self.node_roles.put(node_id.toInt(), role);
        if (role == .navigation) self.navigation_entry_nodes += 1;
    }

    fn recordEdge(self: *GovernanceRoleIndex, src: core.NodeId, rel: core.RelKind, dst: core.NodeId) !void {
        _ = self;
        _ = src;
        _ = rel;
        _ = dst;
    }
};

fn renderGovernanceRoleStats(writer: anytype, roles: *const GovernanceRoleIndex) !void {
    try writer.print(
        "unattached_fact_edges={}\n",
        .{roles.unattached_fact_edges},
    );
    try writer.writeAll(roles.samples.buffer.items);
}

const GovernanceDistributionKind = enum { node, relation };

fn renderGovernanceDistribution(writer: anytype, prefix: []const u8, kind: GovernanceDistributionKind, registry: ?schema.Registry, counts: []const u64) !void {
    for (counts, 0..) |count, id| {
        if (count == 0) continue;
        try writer.print("{s} ", .{prefix});
        switch (kind) {
            .node => try writeGovernanceNodeKindLabel(writer, registry, @intCast(id)),
            .relation => try writeGovernanceRelKindLabel(writer, registry, @intCast(id)),
        }
        try writer.print("={}\n", .{count});
    }
}

fn writeGovernanceNodeKindLabel(writer: anytype, registry: ?schema.Registry, id: u16) !void {
    if (registry) |loaded| {
        if (loaded.nodeTypeNameById(id)) |name| return writer.writeAll(name);
    }
    return writeNodeKindName(writer, @enumFromInt(id));
}

fn writeGovernanceRelKindLabel(writer: anytype, registry: ?schema.Registry, id: u16) !void {
    if (registry) |loaded| {
        if (loaded.relationTypeNameById(id)) |name| return writer.writeAll(name);
    }
    return writeRelKindName(writer, @enumFromInt(id));
}

fn renderGovernanceRelationClassDistribution(writer: anytype, registry: schema.Registry, counts: []const u64) !void {
    var class_counts = [_]u64{0} ** @typeInfo(schema.RelationClass).@"enum".fields.len;
    for (counts, 0..) |count, id| {
        if (count == 0) continue;
        const id16 = std.math.cast(u16, id) orelse continue;
        const relation_class = registry.relationClassById(id16) orelse continue;
        class_counts[@intFromEnum(relation_class)] += count;
    }
    inline for (@typeInfo(schema.RelationClass).@"enum".fields) |field| {
        const relation_class: schema.RelationClass = @enumFromInt(field.value);
        try writer.print("traversable_relation_class_count {s}={}\n", .{ relation_class.label(), class_counts[field.value] });
    }
}

fn renderGovernanceEndpointViolationDistribution(
    writer: anytype,
    registry: schema.Registry,
    counts: *const std.AutoHashMap(u16, u64),
) !void {
    var raw_id: usize = 0;
    while (raw_id < schema.max_relation_types) : (raw_id += 1) {
        const relation_id: u16 = @intCast(raw_id);
        const count = counts.get(relation_id) orelse continue;
        try writer.writeAll("schema_edge_endpoint_violation_relation_count ");
        if (registry.relationTypeNameById(relation_id)) |name| {
            try writer.writeAll(name);
        } else {
            try writer.print("rel#{}", .{relation_id});
        }
        try writer.print("={}\n", .{count});
    }
}

fn renderGovernanceEndpointViolationPairDistribution(
    allocator: std.mem.Allocator,
    writer: anytype,
    registry: schema.Registry,
    counts: *const std.AutoHashMap(GovernanceEndpointViolationPairKey, GovernanceEndpointViolationPairStats),
) !void {
    var entries = std.ArrayList(GovernanceEndpointViolationPairEntry).empty;
    defer entries.deinit(allocator);
    var iterator = counts.iterator();
    while (iterator.next()) |entry| {
        try entries.append(allocator, .{
            .key = entry.key_ptr.*,
            .stats = entry.value_ptr.*,
        });
    }
    std.mem.sort(GovernanceEndpointViolationPairEntry, entries.items, {}, governanceEndpointViolationPairEntryLessThan);
    for (entries.items) |entry| {
        try writer.writeAll("schema_edge_endpoint_violation_pair_count rel=");
        try writeGovernanceRelKindLabel(writer, registry, entry.key.relation_id);
        try writer.writeAll(" src=");
        try writeGovernanceNodeKindLabel(writer, registry, entry.key.src_kind_id);
        try writer.writeAll(" dst=");
        try writeGovernanceNodeKindLabel(writer, registry, entry.key.dst_kind_id);
        try writer.print(
            " count={} first_edge={} src_id={} dst_id={}\n",
            .{ entry.stats.count, entry.stats.first_edge_id, entry.stats.first_src_id, entry.stats.first_dst_id },
        );
    }
}

const GovernanceRelationCount = struct {
    rel: core.RelKind,
    count: u64,
};

const GovernanceFanoutStats = struct {
    outgoing_edges: u64 = 0,
    navigation_relation_edges: u64 = 0,
};

fn recordGovernanceRelationCount(allocator: std.mem.Allocator, counts: *std.ArrayList(GovernanceRelationCount), rel: core.RelKind) !void {
    return recordGovernanceRelationCountBy(allocator, counts, rel, 1);
}

fn recordGovernanceRelationCountBy(allocator: std.mem.Allocator, counts: *std.ArrayList(GovernanceRelationCount), rel: core.RelKind, amount: u64) !void {
    if (amount == 0) return;
    for (counts.items) |*entry| {
        if (entry.rel == rel) {
            entry.count = std.math.add(u64, entry.count, amount) catch return error.RecordTooLarge;
            return;
        }
    }
    try counts.append(allocator, .{ .rel = rel, .count = amount });
}

fn collectGovernanceRelationCountsForNode(
    allocator: std.mem.Allocator,
    store: storage.Store,
    counts: *std.ArrayList(GovernanceRelationCount),
    node_id: core.NodeId,
) !void {
    var opened = try store.openPublishedEdgeSegmentsForQueryForNode(allocator, .forward, node_id);
    defer if (opened) |*segments| segments.deinit();

    const include_base = if (opened) |*segments| segments.coverage == .delta else true;
    if (include_base) {
        var edges = try store.edgeIndexRecordsByNodeIterator(.src, node_id);
        defer edges.deinit();
        while (try edges.next()) |record| {
            try recordGovernanceRelationCount(allocator, counts, try record.relKind());
        }
    }
    if (opened) |*segments| {
        const Context = struct {
            allocator: std.mem.Allocator,
            counts: *std.ArrayList(GovernanceRelationCount),

            fn visit(context: *@This(), edge: segment_mod.EdgeRecord) !bool {
                try recordGovernanceRelationCount(context.allocator, context.counts, edge.rel);
                return false;
            }
        };
        var context = Context{ .allocator = allocator, .counts = counts };
        _ = if (segments.coverage == .visible_full)
            try segments.segments.forEachNeighbor(.forward, node_id, null, std.math.maxInt(usize), &context, Context.visit)
        else
            try store.forEachOpenedPublishedEdgeSegmentNeighbor(&segments.segments, .forward, node_id, null, std.math.maxInt(usize), &context, Context.visit);
    }

    const deferred_path = try query.metaknowDeferredBasedOnPath(allocator, store);
    defer allocator.free(deferred_path);
    var deferred = try query.readMetaknowDeferredBasedOnTargets(allocator, store.io, deferred_path, node_id, 0, .forward);
    defer deferred.deinit(allocator);
    if (deferred.targets.len != 0) return error.InvalidRecord;
    if (deferred.total_count != 0) {
        try recordGovernanceRelationCountBy(allocator, counts, .based_on, @intCast(deferred.total_count));
    }
}

fn storedEdgeRefFromIndexRecord(record: storage.EdgeIndexRecord) storage.StoredEdgeRef {
    return .{
        .src = core.NodeId.fromInt(record.src),
        .dst = core.NodeId.fromInt(record.dst),
        .edge_id = core.EdgeId.fromInt(record.edge_id),
        .rel = @enumFromInt(record.rel),
    };
}

fn recordGovernanceEdgeStats(
    allocator: std.mem.Allocator,
    registry: ?schema.Registry,
    properties: *const GovernancePropertySnapshot,
    roles: *GovernanceRoleIndex,
    fanout_by_src: *std.AutoHashMap(u64, GovernanceFanoutStats),
    incoming_nodes: *std.AutoHashMap(u64, void),
    rel_kind_counts: []u64,
    edge: storage.StoredEdgeRef,
) !void {
    _ = allocator;
    rel_kind_counts[@as(usize, @intFromEnum(edge.rel))] += 1;
    const fanout_entry = try fanout_by_src.getOrPut(edge.src.toInt());
    if (!fanout_entry.found_existing) fanout_entry.value_ptr.* = .{};
    fanout_entry.value_ptr.outgoing_edges += 1;
    const src_role = roles.node_roles.get(edge.src.toInt()) orelse .unknown;
    if (src_role == .navigation and isGovernanceNavigationRelation(edge.rel, registry)) {
        fanout_entry.value_ptr.navigation_relation_edges += 1;
    }
    try incoming_nodes.put(edge.dst.toInt(), {});

    try roles.recordEdge(edge.src, edge.rel, edge.dst);
    const dst_role = roles.node_roles.get(edge.dst.toInt()) orelse .unknown;
    if (isGovernanceUnattachedFactCandidate(edge.rel, registry, src_role, dst_role) and
        properties.getString(.{ .edge = edge.edge_id }, "projection_edge_id") == null)
    {
        roles.unattached_fact_edges += 1;
        if (roles.unattached_fact_edges <= governance_sample_limit) {
            try roles.samples.print("unattached_fact_edge_sample edge={} src={} rel=", .{ edge.edge_id.toInt(), edge.src.toInt() });
            try writeGovernanceRelKindLabel(&roles.samples, registry, @intFromEnum(edge.rel));
            try roles.samples.print(" dst={}\n", .{edge.dst.toInt()});
        }
    }
}

fn writeGovernanceRelationCountSummary(writer: anytype, registry: ?schema.Registry, counts: []const GovernanceRelationCount) !void {
    try writer.writeAll(" relation_counts=");
    if (counts.len == 0) {
        try writer.writeAll("<none>");
        return;
    }
    for (counts, 0..) |entry, index| {
        if (index != 0) try writer.writeAll(",");
        try writeGovernanceRelKindLabel(writer, registry, @intFromEnum(entry.rel));
        try writer.print(":{}", .{entry.count});
    }
}

fn isGovernanceUnattachedFactCandidate(rel: core.RelKind, registry: ?schema.Registry, src_role: GovernanceNodeRole, dst_role: GovernanceNodeRole) bool {
    if (schema.isMdProjectionRelId(@intFromEnum(rel))) return false;
    if (isGovernanceNavigationRelation(rel, registry)) return false;
    if (src_role == .navigation or dst_role == .navigation) return false;
    if (src_role == .unknown or dst_role == .unknown) return false;
    if (registry) |loaded| {
        const relation_class = loaded.relationClassById(@intFromEnum(rel)) orelse return false;
        if (relation_class != .domain) return false;
    }
    return true;
}

fn governanceRoleForNode(kind: core.NodeKind, schema_type: ?[]const u8) GovernanceNodeRole {
    if (schema_type) |type_label| {
        if (governanceSchemaTypeMatchesAny(type_label, &.{
            "navigation",
            "navigation_root",
            "root",
            "domain_root",
            "project",
            "project_root",
            "topic",
            "workstream",
            "phase",
            "cluster",
            "document_cluster",
            "task_group",
            "document",
        })) return .navigation;
        if (governanceSchemaTypeMatchesAny(type_label, &.{
            "decision",
            "evidence",
            "verification",
            "observation",
            "command",
            "error_event",
            "fix",
            "fragment",
            "memory",
            "content",
        })) return .content;
        if (governanceSchemaTypeMatchesAny(type_label, &.{
            "entity",
            "reference",
            "file",
            "symbol",
            "person",
            "system",
            "concept",
        })) return .entity;
    }
    return switch (kind) {
        .repo,
        .directory,
        .document,
        .document_section,
        .task,
        => .navigation,
        .decision,
        .evidence,
        .verification,
        .observation,
        .command,
        .error_event,
        .edit,
        .fix,
        => .content,
        .file,
        .symbol,
        .function,
        .type_decl,
        .image,
        .media,
        .concept,
        .user_preference,
        .relation_kind,
        .relation_policy,
        => .entity,
        else => .unknown,
    };
}

fn governanceSchemaTypeMatchesAny(schema_type: []const u8, candidates: []const []const u8) bool {
    for (candidates) |candidate| {
        if (std.ascii.eqlIgnoreCase(schema_type, candidate)) return true;
    }
    return false;
}

fn isGovernanceNavigationRelation(rel: core.RelKind, registry: ?schema.Registry) bool {
    switch (rel) {
        .contains => return true,
        else => {},
    }
    if (registry) |loaded| {
        if (loaded.relationTypeNameById(@intFromEnum(rel))) |name| {
            return governanceSchemaTypeMatchesAny(name, &.{
                "contains",
                "organizes",
                "has_child",
                "has_parent",
                "part_of",
            });
        }
    }
    return false;
}

const GovernanceSchemaStats = struct {
    endpoint_violations: u64 = 0,
    unknown_node_type_nodes: u64 = 0,
    unknown_relation_type_edges: u64 = 0,
    unknown_node_properties: u64 = 0,
    unknown_edge_properties: u64 = 0,
    missing_required_node_properties: u64 = 0,
    invalid_property_type: u64 = 0,
    composition_orphans: u64 = 0,
    composition_cardinality_violations: u64 = 0,
    ordered_composition_missing_ordered_by: u64 = 0,
    ordered_composition_order_source_conflicts: u64 = 0,
    ordered_composition_invalid_order_bindings: u64 = 0,
    duplicate_order_key: u64 = 0,
    legacy_contains_edges: u64 = 0,
    legacy_contains_task_hierarchy_edges: u64 = 0,
    legacy_contains_project_membership_edges: u64 = 0,
    legacy_contains_document_hierarchy_edges: u64 = 0,
    legacy_contains_markdown_occurrence_edges: u64 = 0,
    legacy_contains_unclassified_edges: u64 = 0,
    agent_fillable_missing_fields: u64 = 0,
    human_fillable_missing_fields: u64 = 0,
    relation_namespace_class_mismatches: u64 = 0,
    namespaced_relation_endpoint_gaps: u64 = 0,
    composition_owner_dst_types: schema.NodeTypeSet = schema.NodeTypeSet.empty(),
    endpoint_violation_relation_counts: std.AutoHashMap(u16, u64),
    endpoint_violation_pair_counts: std.AutoHashMap(GovernanceEndpointViolationPairKey, GovernanceEndpointViolationPairStats),
    composition_incoming_children: std.AutoHashMap(u64, void),
    composition_cardinality_counts: std.AutoHashMap(GovernanceCompositionCardinalityKey, u64),
    composition_order_keys_seen: std.AutoHashMap(GovernanceCompositionOrderKey, void),
    samples: BufferWriter,

    fn init(allocator: std.mem.Allocator) GovernanceSchemaStats {
        return .{
            .endpoint_violation_relation_counts = std.AutoHashMap(u16, u64).init(allocator),
            .endpoint_violation_pair_counts = std.AutoHashMap(GovernanceEndpointViolationPairKey, GovernanceEndpointViolationPairStats).init(allocator),
            .composition_incoming_children = std.AutoHashMap(u64, void).init(allocator),
            .composition_cardinality_counts = std.AutoHashMap(GovernanceCompositionCardinalityKey, u64).init(allocator),
            .composition_order_keys_seen = std.AutoHashMap(GovernanceCompositionOrderKey, void).init(allocator),
            .samples = .{ .allocator = allocator },
        };
    }

    fn deinit(self: GovernanceSchemaStats, allocator: std.mem.Allocator) void {
        var samples = self.samples;
        samples.buffer.deinit(allocator);
        var endpoint_counts = self.endpoint_violation_relation_counts;
        endpoint_counts.deinit();
        var endpoint_pair_counts = self.endpoint_violation_pair_counts;
        endpoint_pair_counts.deinit();
        var incoming = self.composition_incoming_children;
        incoming.deinit();
        var counts = self.composition_cardinality_counts;
        counts.deinit();
        var order_keys = self.composition_order_keys_seen;
        order_keys.deinit();
    }
};

const GovernanceEndpointViolationPairKey = struct {
    relation_id: u16,
    src_kind_id: u16,
    dst_kind_id: u16,
};

const GovernanceEndpointViolationPairStats = struct {
    count: u64,
    first_edge_id: u64,
    first_src_id: u64,
    first_dst_id: u64,
};

const GovernanceEndpointViolationPairEntry = struct {
    key: GovernanceEndpointViolationPairKey,
    stats: GovernanceEndpointViolationPairStats,
};

fn governanceEndpointViolationPairEntryLessThan(
    _: void,
    a: GovernanceEndpointViolationPairEntry,
    b: GovernanceEndpointViolationPairEntry,
) bool {
    if (a.key.relation_id != b.key.relation_id) return a.key.relation_id < b.key.relation_id;
    if (a.key.src_kind_id != b.key.src_kind_id) return a.key.src_kind_id < b.key.src_kind_id;
    return a.key.dst_kind_id < b.key.dst_kind_id;
}

const GovernanceCompositionCardinalityKey = struct {
    src: u64,
    rel_id: u16,
};

const GovernanceCompositionOrderKey = struct {
    src: u64,
    rel_id: u16,
    order_key: u64,
};

const GovernanceSchemaEdgeContext = struct {
    registry: schema.Registry,
    store: storage.Store,
    node_view: *storage.Store.NodeRecordView,
    properties: *GovernancePropertySnapshot,
    edge_orders: *const GovernanceEdgeOrderSnapshot,
    stats: *GovernanceSchemaStats,
};

const GovernanceEdgeOrderBinding = struct {
    src: u64,
    rel_id: u16,
    order_key: u64,
};

const GovernanceEdgeOrderSnapshot = struct {
    entries: std.AutoHashMap(u64, GovernanceEdgeOrderBinding),

    fn load(allocator: std.mem.Allocator, store: storage.Store) !GovernanceEdgeOrderSnapshot {
        var snapshot = GovernanceEdgeOrderSnapshot{
            .entries = std.AutoHashMap(u64, GovernanceEdgeOrderBinding).init(allocator),
        };
        errdefer snapshot.deinit();
        const LoadContext = struct {
            snapshot: *GovernanceEdgeOrderSnapshot,

            fn visit(raw_context: *anyopaque, record: storage.EdgeOrderRecord) anyerror!void {
                const context: *@This() = @ptrCast(@alignCast(raw_context));
                const entry = try context.snapshot.entries.getOrPut(record.edge_id);
                if (entry.found_existing) return error.InvalidRecord;
                entry.value_ptr.* = .{
                    .src = record.src,
                    .rel_id = record.rel,
                    .order_key = record.order_key,
                };
            }
        };
        var context = LoadContext{ .snapshot = &snapshot };
        _ = try store.scanEdgeOrderRecords(&context, LoadContext.visit);
        return snapshot;
    }

    fn deinit(self: *GovernanceEdgeOrderSnapshot) void {
        self.entries.deinit();
    }

    fn get(self: *const GovernanceEdgeOrderSnapshot, edge_id: core.EdgeId) ?GovernanceEdgeOrderBinding {
        return self.entries.get(edge_id.toInt());
    }
};

const GovernancePropertyLookupKey = struct {
    owner_kind: u8,
    owner_id: u64,
    key_hash: u64,
};

const GovernancePropertySnapshotValue = struct {
    value_kind: storage.PropertySnapshotValueKind,
    string_len: u32 = 0,
    string_value: []const u8 = &.{},
    uint_value: u64 = 0,
};

const GovernancePropertySnapshot = struct {
    backing: storage.PropertySnapshot,
    entries: std.AutoHashMap(GovernancePropertyLookupKey, GovernancePropertySnapshotValue),

    fn load(allocator: std.mem.Allocator, store: storage.Store) !GovernancePropertySnapshot {
        var snapshot = try store.loadPropertySnapshot(allocator);
        errdefer snapshot.deinit(allocator);

        var entries = std.AutoHashMap(GovernancePropertyLookupKey, GovernancePropertySnapshotValue).init(allocator);
        errdefer entries.deinit();
        try entries.ensureTotalCapacity(@intCast(snapshot.entries.len));
        for (snapshot.entries) |entry| {
            const key = governancePropertyLookupKey(entry.owner, entry.key_hash);
            try entries.put(key, .{
                .value_kind = entry.value_kind,
                .string_len = entry.string_len,
                .string_value = entry.string_value,
                .uint_value = entry.uint_value,
            });
        }
        return .{ .backing = snapshot, .entries = entries };
    }

    fn deinit(self: *GovernancePropertySnapshot, allocator: std.mem.Allocator) void {
        self.entries.deinit();
        self.backing.deinit(allocator);
    }

    fn get(self: *const GovernancePropertySnapshot, owner: storage.PropertyOwner, key: []const u8) ?GovernancePropertySnapshotValue {
        return self.entries.get(governancePropertyLookupKey(owner, storage.propertyKeyHashForLookup(key)));
    }

    fn getString(self: *const GovernancePropertySnapshot, owner: storage.PropertyOwner, key: []const u8) ?[]const u8 {
        const value = self.get(owner, key) orelse return null;
        if (value.value_kind != .string or value.string_len == 0) return null;
        return value.string_value;
    }
};

fn governancePropertyLookupKey(owner: storage.PropertyOwner, key_hash: u64) GovernancePropertyLookupKey {
    return switch (owner) {
        .node => |node_id| .{ .owner_kind = 1, .owner_id = node_id.toInt(), .key_hash = key_hash },
        .edge => |edge_id| .{ .owner_kind = 2, .owner_id = edge_id.toInt(), .key_hash = key_hash },
    };
}

const schema_governance_edge_string_properties = [_][]const u8{
    "markdown_attr",
    "render_flags",
    "source_span",
    "confidence",
    "created_by",
    "projection_edge_id",
    "fact_edge_id",
};

const schema_governance_edge_uint_properties = [_][]const u8{
    "order_key",
    "generation",
    "tombstone_generation",
};

fn governanceSchemaStats(
    comptime Ops: type,
    allocator: std.mem.Allocator,
    store: storage.Store,
    registry: schema.Registry,
    property_snapshot: *GovernancePropertySnapshot,
    node_total: u64,
    edge_total: u64,
    writer: anytype,
    io: std.Io,
) !GovernanceSchemaStats {
    var stats = GovernanceSchemaStats.init(allocator);
    errdefer stats.deinit(allocator);

    var phase_start_ns = monotonicNs(io);
    try governanceProgress(writer, io, "schema_static", "begin", 0, 0, phase_start_ns, "checking schema relation classes and composition owner dst types");
    try governanceSchemaRelationClassStats(Ops, registry, &stats);
    try governanceSchemaCompositionDstTypes(registry, &stats);
    try governanceProgress(writer, io, "schema_static", "end", 1, 1, phase_start_ns, "schema static metadata scan complete");

    var edge_orders = try GovernanceEdgeOrderSnapshot.load(allocator, store);
    defer edge_orders.deinit();

    var node_view = try store.openNodeRecordView();
    defer node_view.deinit();
    var nodes = try store.nodeRecordsIterator(null);
    defer nodes.deinit();
    var context = GovernanceSchemaEdgeContext{
        .registry = registry,
        .store = store,
        .node_view = &node_view,
        .properties = property_snapshot,
        .edge_orders = &edge_orders,
        .stats = &stats,
    };

    phase_start_ns = monotonicNs(io);
    try governanceProgress(writer, io, "schema_nodes", "begin", 0, node_total, phase_start_ns, "checking node type ids and node property schema states");
    var scanned_nodes: u64 = 0;
    while (try nodes.next(allocator)) |stored_node| {
        var node = stored_node;
        defer node.deinit(allocator);
        if (!registry.hasNodeTypeId(@intFromEnum(node.kind))) stats.unknown_node_type_nodes += 1;
        try governanceSchemaNodePropertyStats(registry, node, property_snapshot, &stats);
        scanned_nodes += 1;
        try governanceProgressMaybe(writer, io, "schema_nodes", scanned_nodes, node_total, phase_start_ns, "checking node type ids and node property schema states");
    }
    try governanceProgress(writer, io, "schema_nodes", "end", scanned_nodes, node_total, phase_start_ns, "schema node scan complete");

    phase_start_ns = monotonicNs(io);
    try governanceProgress(writer, io, "schema_edges", "begin", 0, edge_total, phase_start_ns, "checking relation endpoint rules, edge properties, and composition edge metadata");
    var scanned_edges: u64 = 0;
    const GovernanceSchemaEdgeScanContext = struct {
        schema_context: *GovernanceSchemaEdgeContext,
        scanned_edges: *u64,
        writer: @TypeOf(writer),
        io: std.Io,
        total: u64,
        phase_start_ns: u128,

        fn visit(raw_context: *anyopaque, record: storage.EdgeIndexRecord) anyerror!void {
            const scan_context: *@This() = @ptrCast(@alignCast(raw_context));
            _ = try governanceSchemaEdgeCallback(Ops, scan_context.schema_context, storedEdgeRefFromIndexRecord(record));
            scan_context.scanned_edges.* = std.math.add(u64, scan_context.scanned_edges.*, 1) catch return error.RecordTooLarge;
            try governanceProgressMaybe(
                scan_context.writer,
                scan_context.io,
                "schema_edges",
                scan_context.scanned_edges.*,
                scan_context.total,
                scan_context.phase_start_ns,
                "checking relation endpoint rules, edge properties, and composition edge metadata",
            );
        }
    };
    var governance_schema_edge_scan_context = GovernanceSchemaEdgeScanContext{
        .schema_context = &context,
        .scanned_edges = &scanned_edges,
        .writer = writer,
        .io = io,
        .total = edge_total,
        .phase_start_ns = phase_start_ns,
    };
    const scanned_visible_edges = try store.scanVisibleEdgeIndexRecords(allocator, &governance_schema_edge_scan_context, GovernanceSchemaEdgeScanContext.visit);
    if (scanned_visible_edges != scanned_edges) return error.InvalidRecord;
    try governanceProgress(writer, io, "schema_edges", "end", scanned_edges, edge_total, phase_start_ns, "schema edge scan complete");

    phase_start_ns = monotonicNs(io);
    try governanceProgress(writer, io, "schema_orphans", "begin", 0, node_total, phase_start_ns, "checking composition owner destination nodes for missing incoming owner edges");
    var orphan_nodes = try store.nodeRecordsIterator(null);
    defer orphan_nodes.deinit();
    scanned_nodes = 0;
    while (try orphan_nodes.next(allocator)) |stored_node| {
        var node = stored_node;
        defer node.deinit(allocator);
        scanned_nodes += 1;
        try governanceProgressMaybe(writer, io, "schema_orphans", scanned_nodes, node_total, phase_start_ns, "checking composition owner destination nodes for missing incoming owner edges");
        if (!stats.composition_owner_dst_types.containsNodeKind(node.kind)) continue;
        if (stats.composition_incoming_children.contains(node.id.toInt())) continue;
        stats.composition_orphans += 1;
        if (stats.composition_orphans <= governance_sample_limit) {
            try stats.samples.print("schema_composition_orphan_sample node={} kind=", .{node.id.toInt()});
            try writeNodeKindName(&stats.samples, node.kind);
            try stats.samples.writeAll("\n");
        }
    }
    try governanceProgress(writer, io, "schema_orphans", "end", scanned_nodes, node_total, phase_start_ns, "schema orphan scan complete");

    return stats;
}

fn governanceSchemaCompositionDstTypes(registry: schema.Registry, stats: *GovernanceSchemaStats) !void {
    var index: usize = 0;
    while (index < registry.relationTypeCount()) : (index += 1) {
        const info = registry.relationTypeInfo(index).?;
        const composition = registry.relationCompositionById(info.id) orelse continue;
        if (!composition.enabled or !composition.owner) continue;
        const rule = registry.relationEndpointRuleById(info.id) orelse continue;
        if (rule.dst) |dst| stats.composition_owner_dst_types.merge(dst);
    }
}

fn governanceSchemaNodePropertyStats(registry: schema.Registry, node: storage.StoredNode, properties: *const GovernancePropertySnapshot, stats: *GovernanceSchemaStats) !void {
    var property_index: usize = 0;
    while (property_index < registry.nodePropertyCount(@intFromEnum(node.kind))) : (property_index += 1) {
        const property = registry.nodePropertyInfo(@intFromEnum(node.kind), property_index) orelse continue;
        const state = governanceNodeSchemaPropertyState(properties, node, property);
        if (property.required and !state.present) {
            stats.missing_required_node_properties += 1;
            if (stats.missing_required_node_properties <= governance_sample_limit) {
                try stats.samples.print("schema_missing_required_node_property_sample node={} key={s}\n", .{ node.id.toInt(), property.name });
            }
        }
        if (state.present and !state.valid_type) {
            stats.invalid_property_type += 1;
            if (stats.invalid_property_type <= governance_sample_limit) {
                try stats.samples.print("schema_invalid_node_property_type_sample node={} key={s} expected={s}\n", .{ node.id.toInt(), property.name, property.value_type.label() });
            }
        }
        if (property.agent_fillable and !state.present) {
            stats.agent_fillable_missing_fields += 1;
            if (stats.agent_fillable_missing_fields <= governance_sample_limit) {
                try stats.samples.print("schema_agent_fillable_missing_field_sample node={} key={s}\n", .{ node.id.toInt(), property.name });
            }
        }
        if (property.human_fillable and !state.present) {
            stats.human_fillable_missing_fields += 1;
            if (stats.human_fillable_missing_fields <= governance_sample_limit) {
                try stats.samples.print("schema_human_fillable_missing_field_sample node={} key={s}\n", .{ node.id.toInt(), property.name });
            }
        }
    }
}

const GovernancePropertyState = struct {
    present: bool = false,
    valid_type: bool = true,
};

fn governanceNodeSchemaPropertyState(properties: *const GovernancePropertySnapshot, node: storage.StoredNode, property: schema.PropertyMeta) GovernancePropertyState {
    if (std.mem.eql(u8, property.name, "text")) {
        return .{ .present = true, .valid_type = property.value_type == .string };
    }
    const value = properties.get(.{ .node = node.id }, property.name) orelse return .{};
    if (property.value_type == .@"enum") {
        return .{
            .present = value.value_kind == .string and value.string_len != 0,
            .valid_type = value.value_kind == .string and property.enumAllows(value.string_value),
        };
    }
    if (property.value_type == .string or property.value_type == .json) {
        return .{
            .present = value.value_kind == .string and value.string_len != 0,
            .valid_type = value.value_kind == .string,
        };
    }
    if (property.value_type == .uint or property.value_type == .int) {
        return .{
            .present = value.value_kind == .uint,
            .valid_type = value.value_kind == .uint,
        };
    }
    return .{};
}

fn schemaJsonPropertyIsEmpty(value: std.json.Value) bool {
    return switch (value) {
        .null => true,
        .string => |text| text.len == 0,
        else => false,
    };
}

fn schemaJsonPropertyMatchesType(value: std.json.Value, property_type: schema.PropertyType) bool {
    return switch (property_type) {
        .string, .@"enum" => value == .string,
        .uint => value == .integer and value.integer >= 0,
        .int => value == .integer,
        .bool => value == .bool,
        .json => true,
    };
}

fn governanceSchemaRelationClassStats(comptime Ops: type, registry: schema.Registry, stats: *GovernanceSchemaStats) !void {
    var index: usize = 0;
    while (index < registry.relationTypeCount()) : (index += 1) {
        const info = registry.relationTypeInfo(index).?;
        const expected = Ops.relationClassNamespace(info.name) orelse continue;
        if (expected != info.class) {
            stats.relation_namespace_class_mismatches += 1;
            if (stats.relation_namespace_class_mismatches <= governance_sample_limit) {
                try stats.samples.print("schema_relation_namespace_class_mismatch_sample rel={s} expected_class={s} actual_class={s}\n", .{
                    info.name,
                    expected.label(),
                    info.class.label(),
                });
            }
        }
        const rule = registry.relationEndpointRuleById(info.id) orelse continue;
        if (rule.isEmpty()) {
            stats.namespaced_relation_endpoint_gaps += 1;
            if (stats.namespaced_relation_endpoint_gaps <= governance_sample_limit) {
                try stats.samples.print("schema_namespaced_relation_endpoint_gap_sample rel={s} class={s}\n", .{ info.name, info.class.label() });
            }
        }
    }
}

fn governanceSchemaEdgeCallback(comptime Ops: type, context: *GovernanceSchemaEdgeContext, edge: storage.StoredEdgeRef) !bool {
    const rel_id: u16 = @intFromEnum(edge.rel);
    const rule = context.registry.relationEndpointRuleById(rel_id) orelse {
        context.stats.unknown_relation_type_edges += 1;
        if (context.stats.unknown_relation_type_edges <= governance_sample_limit) {
            try context.stats.samples.print("schema_unknown_relation_edge_sample edge={} rel#{} src={} dst={}\n", .{
                edge.edge_id.toInt(),
                rel_id,
                edge.src.toInt(),
                edge.dst.toInt(),
            });
        }
        return false;
    };
    try governanceSchemaEdgePropertyStats(context, edge);
    try governanceSchemaLegacyContainsStats(context, edge);
    try governanceSchemaCompositionEdgeStats(context, edge);
    if (rule.isEmpty()) return false;

    // The node scan already reports types missing from the active schema.
    // Governance must keep scanning the remaining edges so it can produce a
    // complete debt report; UnknownNodeKind is only fatal on the write-time
    // validation path, where accepting an unregistered endpoint would make a
    // schema-constrained mutation ambiguous.
    const check = Ops.schemaEdgeEndpointCheck(context.node_view, context.registry, edge.src, edge.rel, edge.dst) catch |err| switch (err) {
        error.UnknownNodeKind => return false,
        else => |e| return e,
    };
    if (!check.violates) return false;

    context.stats.endpoint_violations += 1;
    const relation_count = try context.stats.endpoint_violation_relation_counts.getOrPut(rel_id);
    if (!relation_count.found_existing) relation_count.value_ptr.* = 0;
    relation_count.value_ptr.* = std.math.add(u64, relation_count.value_ptr.*, 1) catch return error.RecordTooLarge;
    const pair_count = try context.stats.endpoint_violation_pair_counts.getOrPut(.{
        .relation_id = rel_id,
        .src_kind_id = @intFromEnum(check.src_kind),
        .dst_kind_id = @intFromEnum(check.dst_kind),
    });
    if (!pair_count.found_existing) {
        pair_count.value_ptr.* = .{
            .count = 0,
            .first_edge_id = edge.edge_id.toInt(),
            .first_src_id = edge.src.toInt(),
            .first_dst_id = edge.dst.toInt(),
        };
    }
    pair_count.value_ptr.count = std.math.add(u64, pair_count.value_ptr.count, 1) catch return error.RecordTooLarge;
    if (context.stats.endpoint_violations <= governance_sample_limit) {
        try context.stats.samples.print("schema_edge_endpoint_violation_sample edge={} rel=", .{edge.edge_id.toInt()});
        try writeRelKindName(&context.stats.samples, edge.rel);
        try context.stats.samples.print(" src={} src_kind=", .{edge.src.toInt()});
        try writeNodeKindName(&context.stats.samples, check.src_kind);
        try context.stats.samples.print(" dst={} dst_kind=", .{edge.dst.toInt()});
        try writeNodeKindName(&context.stats.samples, check.dst_kind);
        try context.stats.samples.writeAll("\n");
    }
    return false;
}

fn governanceSchemaEdgePropertyStats(context: *GovernanceSchemaEdgeContext, edge: storage.StoredEdgeRef) !void {
    const rel_id: u16 = @intFromEnum(edge.rel);
    for (schema_governance_edge_string_properties) |key| {
        const value = context.properties.get(.{ .edge = edge.edge_id }, key) orelse continue;
        const property = context.registry.relationPropertyByTypeId(rel_id, key) orelse {
            try governanceSchemaUnknownEdgePropertySample(context, edge, key);
            continue;
        };
        if (value.value_kind != .string or
            (property.value_type != .string and property.value_type != .@"enum" and property.value_type != .json) or
            (property.value_type == .@"enum" and !property.enumAllows(value.string_value)))
        {
            try governanceSchemaInvalidEdgePropertyTypeSample(context, edge, key, property.value_type);
        }
    }
    for (schema_governance_edge_uint_properties) |key| {
        const value = context.properties.get(.{ .edge = edge.edge_id }, key) orelse continue;
        const property = context.registry.relationPropertyByTypeId(rel_id, key) orelse {
            try governanceSchemaUnknownEdgePropertySample(context, edge, key);
            continue;
        };
        if (value.value_kind != .uint or property.value_type != .uint) {
            try governanceSchemaInvalidEdgePropertyTypeSample(context, edge, key, property.value_type);
        }
    }
}

fn governanceSchemaUnknownEdgePropertySample(context: *GovernanceSchemaEdgeContext, edge: storage.StoredEdgeRef, key: []const u8) !void {
    context.stats.unknown_edge_properties += 1;
    if (context.stats.unknown_edge_properties <= governance_sample_limit) {
        try context.stats.samples.print("schema_unknown_edge_property_sample edge={} rel=", .{edge.edge_id.toInt()});
        try writeRelKindName(&context.stats.samples, edge.rel);
        try context.stats.samples.print(" key={s}\n", .{key});
    }
}

fn governanceSchemaInvalidEdgePropertyTypeSample(context: *GovernanceSchemaEdgeContext, edge: storage.StoredEdgeRef, key: []const u8, expected: schema.PropertyType) !void {
    context.stats.invalid_property_type += 1;
    if (context.stats.invalid_property_type <= governance_sample_limit) {
        try context.stats.samples.print("schema_invalid_edge_property_type_sample edge={} key={s} expected={s}\n", .{ edge.edge_id.toInt(), key, expected.label() });
    }
}

const GovernanceLegacyContainsClass = enum {
    task_hierarchy,
    project_membership,
    document_hierarchy,
    markdown_occurrence,
    unclassified,
};

fn governanceSchemaLegacyContainsStats(context: *GovernanceSchemaEdgeContext, edge: storage.StoredEdgeRef) !void {
    if (edge.rel != .contains) return;
    if (context.registry.relationCompositionById(@intFromEnum(core.RelKind.contains))) |composition| {
        if (composition.enabled) return;
    }

    const src = (try context.node_view.readNodeRefById(edge.src)) orelse return error.InvalidRecord;
    const dst = (try context.node_view.readNodeRefById(edge.dst)) orelse return error.InvalidRecord;
    const legacy_class: GovernanceLegacyContainsClass = if (src.kind == .task and dst.kind == .task)
        .task_hierarchy
    else if (src.kind == .project and dst.kind == .task)
        .project_membership
    else if (src.kind == .document and dst.kind == .document)
        .document_hierarchy
    else if ((src.kind == .document or src.kind == .document_section) and dst.kind == .document_section)
        .markdown_occurrence
    else
        .unclassified;

    context.stats.legacy_contains_edges += 1;
    switch (legacy_class) {
        .task_hierarchy => context.stats.legacy_contains_task_hierarchy_edges += 1,
        .project_membership => context.stats.legacy_contains_project_membership_edges += 1,
        .document_hierarchy => context.stats.legacy_contains_document_hierarchy_edges += 1,
        .markdown_occurrence => {
            context.stats.legacy_contains_markdown_occurrence_edges += 1;
            try context.stats.composition_incoming_children.put(edge.dst.toInt(), {});
        },
        .unclassified => context.stats.legacy_contains_unclassified_edges += 1,
    }
    if (context.stats.legacy_contains_edges <= governance_sample_limit) {
        try context.stats.samples.print("schema_legacy_contains_sample edge={} class={s} src={} src_kind=", .{
            edge.edge_id.toInt(),
            @tagName(legacy_class),
            edge.src.toInt(),
        });
        try writeNodeKindName(&context.stats.samples, src.kind);
        try context.stats.samples.print(" dst={} dst_kind=", .{edge.dst.toInt()});
        try writeNodeKindName(&context.stats.samples, dst.kind);
        try context.stats.samples.writeAll("\n");
    }
}

fn governanceSchemaCompositionEdgeStats(context: *GovernanceSchemaEdgeContext, edge: storage.StoredEdgeRef) !void {
    const rel_id: u16 = @intFromEnum(edge.rel);
    const composition = context.registry.relationCompositionById(rel_id) orelse return;
    if (!composition.enabled) return;
    if (composition.owner) {
        try context.stats.composition_incoming_children.put(edge.dst.toInt(), {});
    } else if (schema.isMdProjectionRelId(rel_id)) {
        // composition_occurrence_owner_kind=document_section: mixed md:*
        // relations can target reusable content or owned occurrence wrappers.
        const dst = (try context.node_view.readNodeRefById(edge.dst)) orelse return error.InvalidRecord;
        if (dst.kind == .document_section) {
            try context.stats.composition_incoming_children.put(edge.dst.toInt(), {});
        }
    }

    switch (composition.cardinality) {
        .one, .optional_one => {
            const key = GovernanceCompositionCardinalityKey{ .src = edge.src.toInt(), .rel_id = rel_id };
            const entry = try context.stats.composition_cardinality_counts.getOrPut(key);
            if (entry.found_existing) {
                entry.value_ptr.* += 1;
                context.stats.composition_cardinality_violations += 1;
                if (context.stats.composition_cardinality_violations <= governance_sample_limit) {
                    try context.stats.samples.print("schema_composition_cardinality_violation_sample src={} rel=", .{edge.src.toInt()});
                    try writeRelKindName(&context.stats.samples, edge.rel);
                    try context.stats.samples.print(" count={}\n", .{entry.value_ptr.*});
                }
            } else {
                entry.value_ptr.* = 1;
            }
        },
        .many => {},
    }

    if (composition.ordered_by) |ordered_by| {
        const resolved_order = try governanceResolvedCompositionOrder(context, edge, ordered_by);
        if (resolved_order == null) {
            context.stats.ordered_composition_missing_ordered_by += 1;
            if (context.stats.ordered_composition_missing_ordered_by <= governance_sample_limit) {
                try context.stats.samples.print("schema_ordered_composition_missing_ordered_by_sample edge={} rel=", .{edge.edge_id.toInt()});
                try writeRelKindName(&context.stats.samples, edge.rel);
                try context.stats.samples.print(" key={s}\n", .{ordered_by});
            }
            return;
        }
        const concrete = resolved_order.?;
        const order_key = GovernanceCompositionOrderKey{ .src = edge.src.toInt(), .rel_id = rel_id, .order_key = concrete };
        const order_entry = try context.stats.composition_order_keys_seen.getOrPut(order_key);
        // composition_duplicate_uses_resolved_order: duplicate detection must
        // consume the same sidecar-first value used by ordered traversal.
        if (order_entry.found_existing) {
            context.stats.duplicate_order_key += 1;
            if (context.stats.duplicate_order_key <= governance_sample_limit) {
                try context.stats.samples.print("schema_duplicate_order_key_sample src={} rel=", .{edge.src.toInt()});
                try writeRelKindName(&context.stats.samples, edge.rel);
                try context.stats.samples.print(" key={s} value={}\n", .{ ordered_by, concrete });
            }
        }
    }
}

const GovernanceCompositionOrderResolution = struct {
    value: ?u64,
    sidecar_order: ?u64,
    invalid_binding: bool,
    conflict: bool,
};

fn resolveGovernanceCompositionOrder(
    edge: storage.StoredEdgeRef,
    ordered_by: []const u8,
    property_order: ?u64,
    binding: ?GovernanceEdgeOrderBinding,
) GovernanceCompositionOrderResolution {
    if (!std.mem.eql(u8, ordered_by, "order_key")) {
        return .{
            .value = property_order,
            .sidecar_order = null,
            .invalid_binding = false,
            .conflict = false,
        };
    }

    var sidecar_order: ?u64 = null;
    var invalid_binding = false;
    if (binding) |concrete| {
        if (concrete.src != edge.src.toInt() or concrete.rel_id != @intFromEnum(edge.rel)) {
            invalid_binding = true;
        } else {
            sidecar_order = concrete.order_key;
        }
    }
    return .{
        .value = sidecar_order orelse property_order,
        .sidecar_order = sidecar_order,
        .invalid_binding = invalid_binding,
        .conflict = sidecar_order != null and property_order != null and sidecar_order.? != property_order.?,
    };
}

fn governanceResolvedCompositionOrder(
    context: *GovernanceSchemaEdgeContext,
    edge: storage.StoredEdgeRef,
    ordered_by: []const u8,
) !?u64 {
    const property = context.properties.get(.{ .edge = edge.edge_id }, ordered_by);
    const property_order: ?u64 = if (property) |value|
        if (value.value_kind == .uint) value.uint_value else null
    else
        null;
    const binding = context.edge_orders.get(edge.edge_id);
    const resolution = resolveGovernanceCompositionOrder(edge, ordered_by, property_order, binding);

    if (resolution.invalid_binding) {
        const concrete = binding.?;
        context.stats.ordered_composition_invalid_order_bindings += 1;
        if (context.stats.ordered_composition_invalid_order_bindings <= governance_sample_limit) {
            try context.stats.samples.print(
                "schema_ordered_composition_invalid_order_binding_sample edge={} rel=",
                .{edge.edge_id.toInt()},
            );
            try writeRelKindName(&context.stats.samples, edge.rel);
            try context.stats.samples.print(" sidecar_src={} sidecar_rel#{}\n", .{ concrete.src, concrete.rel_id });
        }
    }
    if (resolution.conflict) {
        context.stats.ordered_composition_order_source_conflicts += 1;
        if (context.stats.ordered_composition_order_source_conflicts <= governance_sample_limit) {
            try context.stats.samples.print(
                "schema_ordered_composition_order_source_conflict_sample edge={} sidecar={} property={}\n",
                .{ edge.edge_id.toInt(), resolution.sidecar_order.?, property_order.? },
            );
        }
    }

    // composition_order_property_fallback keeps explicitly property-ordered
    // custom/legacy stores readable; canonical Markdown traversal and
    // governance prefer the validated edge_order sidecar.
    return resolution.value;
}

const TestWriter = struct {
    allocator: std.mem.Allocator,
    buffer: std.ArrayList(u8) = .empty,
    flush_count: usize = 0,

    fn deinit(self: *TestWriter) void {
        self.buffer.deinit(self.allocator);
    }

    pub fn writeAll(self: *TestWriter, bytes: []const u8) !void {
        try self.buffer.appendSlice(self.allocator, bytes);
    }

    pub fn print(self: *TestWriter, comptime fmt: []const u8, args: anytype) !void {
        const rendered = try std.fmt.allocPrint(self.allocator, fmt, args);
        defer self.allocator.free(rendered);
        try self.writeAll(rendered);
    }

    pub fn flush(self: *TestWriter) !void {
        self.flush_count += 1;
    }
};

const FailingWriter = struct {
    pub fn writeAll(_: *FailingWriter, _: []const u8) error{OutputClosed}!void {
        return error.OutputClosed;
    }

    pub fn print(_: *FailingWriter, comptime _: []const u8, _: anytype) error{OutputClosed}!void {
        return error.OutputClosed;
    }
};

const TestDeferredPair = struct {
    src: u64,
    dst: u64,
};

const TestDeferredPairs = struct {
    present: bool = false,
    pairs: std.ArrayList(TestDeferredPair) = .empty,

    pub fn deinit(self: *TestDeferredPairs, allocator: std.mem.Allocator) void {
        self.pairs.deinit(allocator);
    }
};

const TestEndpointCheck = struct {
    src_kind: core.NodeKind,
    dst_kind: core.NodeKind,
    violates: bool,
};

const TestOps = struct {
    const Parsed = struct {
        db_path: []const u8,
        rest: []const []const u8,
    };

    var db_path: []const u8 = "";
    var context_live = false;
    var context_init_count: usize = 0;
    var context_deinit_count: usize = 0;
    var store_access_count: usize = 0;
    var last_schema_path: ?[]const u8 = null;
    var last_profiles: ?[]const u8 = null;

    fn reset(path: []const u8) void {
        db_path = path;
        context_live = false;
        context_init_count = 0;
        context_deinit_count = 0;
        store_access_count = 0;
        last_schema_path = null;
        last_profiles = null;
    }

    pub fn parseDbArguments(_: std.mem.Allocator, _: std.Io, args: []const []const u8) !Parsed {
        if (args.len < 2) return error.MissingArgument;
        return .{ .db_path = db_path, .rest = args[2..] };
    }

    pub const Context = struct {
        store: storage.Store,

        pub fn init(
            allocator: std.mem.Allocator,
            io: std.Io,
            path: []const u8,
            schema_path: ?[]const u8,
            profiles: ?[]const u8,
        ) !Context {
            std.debug.assert(!context_live);
            context_init_count += 1;
            last_schema_path = schema_path;
            last_profiles = profiles;
            const store = try storage.Store.open(allocator, io, path);
            context_live = true;
            return .{ .store = store };
        }

        pub fn deinit(self: *Context) void {
            std.debug.assert(context_live);
            self.store.deinit();
            context_live = false;
            context_deinit_count += 1;
            self.* = undefined;
        }

        pub fn storeHandle(self: *Context) storage.Store {
            std.debug.assert(context_live);
            store_access_count += 1;
            return self.store;
        }

        pub fn schemaRegistry(_: *Context) ?schema.Registry {
            std.debug.assert(context_live);
            return null;
        }
    };

    pub fn storeDirBytes(_: std.mem.Allocator, _: std.Io, _: []const u8) !u64 {
        return 0;
    }

    pub fn storeFileSize(_: std.mem.Allocator, _: std.Io, _: []const u8, _: []const u8) !?u64 {
        return null;
    }

    pub fn readDeferredBasedOnPairs(_: std.mem.Allocator, _: std.Io, _: []const u8) !TestDeferredPairs {
        return .{};
    }

    pub fn isDeletedNodeTombstone(node: storage.StoredNode) bool {
        return node.kind == .edit and std.mem.startsWith(u8, node.text, "__tinykg_deleted_node__ ");
    }

    pub fn visibleNodeText(text: []const u8) []const u8 {
        return text;
    }

    pub fn nodeTextCharLimit() usize {
        return 8 * 1024 + 512;
    }

    pub fn relationClassNamespace(name: []const u8) ?schema.RelationClass {
        if (std.mem.startsWith(u8, name, "md:")) return .md;
        if (std.mem.startsWith(u8, name, "prov:")) return .prov;
        if (std.mem.startsWith(u8, name, "task:")) return .task;
        if (std.mem.startsWith(u8, name, "sys:")) return .sys;
        if (std.mem.startsWith(u8, name, "domain:")) return .domain;
        return null;
    }

    pub fn schemaEdgeEndpointCheck(
        _: *storage.Store.NodeRecordView,
        _: schema.Registry,
        _: core.NodeId,
        _: core.RelKind,
        _: core.NodeId,
    ) error{ Unsupported, UnknownNodeKind }!TestEndpointCheck {
        return error.Unsupported;
    }
};

const test_governance_command = GovernanceCommand(TestOps);

fn testStorePath(tmp: *std.testing.TmpDir, buffer: *[std.Io.Dir.max_path_bytes]u8) ![]const u8 {
    const len = try tmp.dir.realPath(std.testing.io, buffer);
    return buffer[0..len];
}

test "governance command rejects schema syntax before context acquisition" {
    TestOps.reset("unused");
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();

    try std.testing.expectError(
        error.UnknownOption,
        test_governance_command.run(
            &.{ "tinykg", "governance", "--unknown" },
            &writer,
            std.testing.allocator,
            std.testing.io,
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), TestOps.context_init_count);
    try std.testing.expect(!TestOps.context_live);
    try std.testing.expectEqual(@as(usize, 0), writer.buffer.items.len);
}

test "governance command keeps one context live through report publication" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try testStorePath(&tmp, &path_buffer);
    var seed = try storage.Store.init(std.testing.allocator, std.testing.io, path);
    try seed.createEmpty();
    seed.deinit();

    TestOps.reset(path);
    var writer = TestWriter{ .allocator = std.testing.allocator };
    defer writer.deinit();
    try test_governance_command.run(
        &.{ "tinykg", "governance", "--profile", "agent-dag" },
        &writer,
        std.testing.allocator,
        std.testing.io,
    );

    try std.testing.expectEqual(@as(usize, 1), TestOps.context_init_count);
    try std.testing.expectEqual(@as(usize, 1), TestOps.context_deinit_count);
    try std.testing.expectEqual(@as(usize, 1), TestOps.store_access_count);
    try std.testing.expect(!TestOps.context_live);
    try std.testing.expectEqualStrings("agent-dag", TestOps.last_profiles.?);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffer.items, "governance_progress phase=store_summary status=begin") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffer.items, "nodes=0\n") != null);
    try std.testing.expect(writer.flush_count > 0);
}

test "governance command closes context after report and writer failures" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path = try testStorePath(&tmp, &path_buffer);
    var seed = try storage.Store.init(std.testing.allocator, std.testing.io, path);
    try seed.createEmpty();
    seed.deinit();

    TestOps.reset(path);
    var writer = FailingWriter{};
    try std.testing.expectError(
        error.OutputClosed,
        test_governance_command.run(
            &.{ "tinykg", "governance" },
            &writer,
            std.testing.allocator,
            std.testing.io,
        ),
    );
    try std.testing.expectEqual(@as(usize, 1), TestOps.context_init_count);
    try std.testing.expectEqual(@as(usize, 1), TestOps.context_deinit_count);
    try std.testing.expectEqual(@as(usize, 1), TestOps.store_access_count);
    try std.testing.expect(!TestOps.context_live);
}

test "governance owner classifies navigation and fact roles" {
    try std.testing.expectEqual(GovernanceNodeRole.navigation, governanceRoleForNode(.task, null));
    try std.testing.expectEqual(GovernanceNodeRole.content, governanceRoleForNode(.concept, "verification"));
    try std.testing.expectEqual(GovernanceNodeRole.entity, governanceRoleForNode(.concept, null));
    try std.testing.expect(isGovernanceUnattachedFactCandidate(.defines, null, .content, .entity));
    try std.testing.expect(!isGovernanceUnattachedFactCandidate(.contains, null, .navigation, .content));
}

test "governance owner resolves sidecar composition order before property fallback" {
    const edge = storage.StoredEdgeRef{
        .src = core.NodeId.fromInt(11),
        .dst = core.NodeId.fromInt(12),
        .edge_id = core.EdgeId.fromInt(13),
        .rel = .contains,
    };
    const sidecar_first = resolveGovernanceCompositionOrder(edge, "order_key", 19, .{
        .src = 11,
        .rel_id = @intFromEnum(core.RelKind.contains),
        .order_key = 17,
    });
    try std.testing.expectEqual(@as(?u64, 17), sidecar_first.value);
    try std.testing.expect(sidecar_first.conflict);
    try std.testing.expect(!sidecar_first.invalid_binding);

    const invalid_fallback = resolveGovernanceCompositionOrder(edge, "order_key", 19, .{
        .src = 99,
        .rel_id = @intFromEnum(core.RelKind.contains),
        .order_key = 17,
    });
    try std.testing.expectEqual(@as(?u64, 19), invalid_fallback.value);
    try std.testing.expect(invalid_fallback.invalid_binding);
    try std.testing.expect(!invalid_fallback.conflict);
}

test "governance owner keeps endpoint pair ordering deterministic" {
    const stats = GovernanceEndpointViolationPairStats{
        .count = 1,
        .first_edge_id = 1,
        .first_src_id = 1,
        .first_dst_id = 1,
    };
    var entries = [_]GovernanceEndpointViolationPairEntry{
        .{ .key = .{ .relation_id = 2, .src_kind_id = 1, .dst_kind_id = 1 }, .stats = stats },
        .{ .key = .{ .relation_id = 1, .src_kind_id = 3, .dst_kind_id = 1 }, .stats = stats },
        .{ .key = .{ .relation_id = 1, .src_kind_id = 2, .dst_kind_id = 4 }, .stats = stats },
    };
    std.mem.sort(GovernanceEndpointViolationPairEntry, &entries, {}, governanceEndpointViolationPairEntryLessThan);
    try std.testing.expectEqual(@as(u16, 1), entries[0].key.relation_id);
    try std.testing.expectEqual(@as(u16, 2), entries[0].key.src_kind_id);
    try std.testing.expectEqual(@as(u16, 3), entries[1].key.src_kind_id);
    try std.testing.expectEqual(@as(u16, 2), entries[2].key.relation_id);
}

test "governance owner bounds and escapes health samples" {
    var writer = BufferWriter{ .allocator = std.testing.allocator };
    defer writer.buffer.deinit(std.testing.allocator);
    try writeEscapedTextPrefix(&writer, "a:b,\nrest", 5);
    try std.testing.expectEqualStrings("a\\:b\\,\\n...", writer.buffer.items);
}
