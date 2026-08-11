const std = @import("std");
const core = @import("../core.zig");
const graph_mod = @import("../graph.zig");
const index = @import("../index.zig");
const query_mod = @import("../query.zig");
const schema = @import("../schema.zig");
const storage = @import("../storage.zig");
const task_mod = @import("../task.zig");
const text_mod = @import("../text.zig");
const ast = @import("ast.zig");
const optimizer = @import("optimizer.zig");
const planner = @import("planner.zig");
const execution_result_mod = @import("executor/execution_result.zig");

const execution_result = execution_result_mod.ExecutionResult(
    core,
    index.QueryStats,
    optimizer.PhysicalPlan,
);

pub const Binding = execution_result.Binding;
pub const EdgeBinding = execution_result.EdgeBinding;
pub const PathBinding = execution_result.PathBinding;
pub const ScoreBinding = execution_result.ScoreBinding;
pub const Row = execution_result.Row;
pub const ResultTable = execution_result.ResultTable;
pub const OperatorTiming = execution_result.OperatorTiming;
pub const OperatorTimingRecorder = execution_result.OperatorTimingRecorder;
const execution_result_internal = execution_result.Internal;

const NodeView = struct {
    id: core.NodeId,
    kind: core.NodeKind,
    text: []const u8,
    owned_text: ?[]u8 = null,

    fn fromGraphNode(node: graph_mod.Node) NodeView {
        return .{
            .id = node.id,
            .kind = node.kind,
            .text = node.text,
        };
    }

    fn fromStoredNode(node: storage.StoredNode) NodeView {
        return .{
            .id = node.id,
            .kind = node.kind,
            .text = node.text,
            .owned_text = node.text,
        };
    }

    fn deinit(self: *NodeView, allocator: std.mem.Allocator) void {
        if (self.owned_text) |text_value| allocator.free(text_value);
    }
};

fn typeFilterIsAny(filter: schema.NodeTypeFilter) bool {
    return switch (filter) {
        .any => true,
        else => false,
    };
}

fn effectiveNodeTypeFilter(kind: ?core.NodeKind, filter: schema.NodeTypeFilter) schema.NodeTypeFilter {
    if (typeFilterIsAny(filter)) return schema.NodeTypeFilter.fromOptionalKind(kind);
    return filter;
}

fn relationFilterIsAny(filter: schema.RelationTypeFilter) bool {
    return switch (filter) {
        .any => true,
        else => false,
    };
}

fn effectiveRelationTypeFilter(rel: ?core.RelKind, filter: schema.RelationTypeFilter) schema.RelationTypeFilter {
    if (relationFilterIsAny(filter)) return schema.RelationTypeFilter.fromOptionalRel(rel);
    return filter;
}

fn nodeIdLessThan(_: void, lhs: core.NodeId, rhs: core.NodeId) bool {
    return lhs.toInt() < rhs.toInt();
}

fn sortNodeIds(ids: []core.NodeId) void {
    std.mem.sort(core.NodeId, ids, {}, nodeIdLessThan);
}

const NodeUintPropertySortContext = struct {
    allocator: std.mem.Allocator,
    graph: *const graph_mod.Graph,
    mem_index: *index.MemoryIndex,
    key: []const u8,
};

fn nodeUintPropertyLessThan(ctx: NodeUintPropertySortContext, lhs: core.NodeId, rhs: core.NodeId) bool {
    const lhs_node = ctx.mem_index.getNode(ctx.graph, lhs);
    const rhs_node = ctx.mem_index.getNode(ctx.graph, rhs);
    const lhs_value = if (lhs_node) |node| nodeUintPropertyValue(ctx.allocator, node.text, ctx.key) else null;
    const rhs_value = if (rhs_node) |node| nodeUintPropertyValue(ctx.allocator, node.text, ctx.key) else null;
    if (lhs_value == null and rhs_value == null) return nodeIdLessThan({}, lhs, rhs);
    if (lhs_value == null) return false;
    if (rhs_value == null) return true;
    if (lhs_value.? != rhs_value.?) return lhs_value.? < rhs_value.?;
    return nodeIdLessThan({}, lhs, rhs);
}

fn sortNodeIdsByUintProperty(allocator: std.mem.Allocator, graph: *const graph_mod.Graph, mem_index: *index.MemoryIndex, ids: []core.NodeId, key: []const u8) void {
    std.mem.sort(core.NodeId, ids, NodeUintPropertySortContext{
        .allocator = allocator,
        .graph = graph,
        .mem_index = mem_index,
        .key = key,
    }, nodeUintPropertyLessThan);
}

fn nodeStringPropertyValueAlloc(allocator: std.mem.Allocator, text: []const u8, key: []const u8) !?[]u8 {
    _ = allocator;
    _ = text;
    _ = key;
    return null;
}

fn nodeUintPropertySupported(key: []const u8) bool {
    return std.mem.eql(u8, key, "task_recorded_ns") or
        std.mem.eql(u8, key, "task_created_ns") or
        std.mem.eql(u8, key, "task_completed_ns") or
        std.mem.eql(u8, key, "claim_expires_ns") or
        std.mem.eql(u8, key, "task_event_ns") or
        std.mem.eql(u8, key, "task_root_id") or
        std.mem.eql(u8, key, "task_id");
}

fn nodeUintPropertyValue(allocator: std.mem.Allocator, text: []const u8, key: []const u8) ?u64 {
    _ = allocator;
    _ = text;
    _ = key;
    return null;
}

fn nodeMatchesStringProperty(allocator: std.mem.Allocator, text: []const u8, property_eq: planner.PropertyPredicate) !bool {
    if (property_eq.op != .eq) return false;
    const parsed_value = try nodeStringPropertyValueAlloc(allocator, text, property_eq.key);
    defer if (parsed_value) |concrete| allocator.free(concrete);
    return if (parsed_value) |concrete|
        std.mem.eql(u8, concrete, property_eq.value)
    else
        nodeStringPropertyMissingMatchesEmpty(property_eq);
}

fn nodeStringPropertyMissingMatchesEmpty(property_eq: planner.PropertyPredicate) bool {
    if (property_eq.op != .eq or property_eq.value.len != 0) return false;
    return std.mem.eql(u8, property_eq.key, "name") or
        std.mem.eql(u8, property_eq.key, "summary");
}

fn predicateMatchesUint(op: ast.PredicateOperator, concrete: u64, expected: u64) bool {
    return switch (op) {
        .eq => concrete == expected,
        .lt => concrete < expected,
        .lte => concrete <= expected,
        .gt => concrete > expected,
        .gte => concrete >= expected,
    };
}

fn uintPropertyRangeForPredicate(op: ast.PredicateOperator, expected: u64) storage.Store.UintPropertyRange {
    return switch (op) {
        .eq => .{ .min = expected, .max = expected },
        .lt => .{ .max = expected, .max_inclusive = false },
        .lte => .{ .max = expected, .max_inclusive = true },
        .gt => .{ .min = expected, .min_inclusive = false },
        .gte => .{ .min = expected, .min_inclusive = true },
    };
}

fn uintPropertyRangeForPlannerRange(range: planner.UintRangePredicate) ?storage.Store.UintPropertyRange {
    return .{
        .min = if (range.min_value) |value| std.fmt.parseInt(u64, value, 10) catch return null else null,
        .min_inclusive = range.min_inclusive,
        .max = if (range.max_value) |value| std.fmt.parseInt(u64, value, 10) catch return null else null,
        .max_inclusive = range.max_inclusive,
    };
}

fn uintPropertyRangeContains(range: storage.Store.UintPropertyRange, value: u64) bool {
    if (range.min) |min| {
        if (range.min_inclusive) {
            if (value < min) return false;
        } else if (value <= min) return false;
    }
    if (range.max) |max| {
        if (range.max_inclusive) {
            if (value > max) return false;
        } else if (value >= max) return false;
    }
    return true;
}

fn nodeMatchesProperty(allocator: std.mem.Allocator, text: []const u8, property_eq: planner.PropertyPredicate) !bool {
    if (nodeUintPropertySupported(property_eq.key)) {
        if (property_eq.uint_range) |planner_range| {
            const range = uintPropertyRangeForPlannerRange(planner_range) orelse return false;
            return if (nodeUintPropertyValue(allocator, text, property_eq.key)) |concrete| uintPropertyRangeContains(range, concrete) else false;
        }
        const expected = std.fmt.parseInt(u64, property_eq.value, 10) catch return false;
        return if (nodeUintPropertyValue(allocator, text, property_eq.key)) |concrete| predicateMatchesUint(property_eq.op, concrete, expected) else false;
    }
    return try nodeMatchesStringProperty(allocator, text, property_eq);
}

fn memoryNodeMatchesEffectiveStatus(kind: core.NodeKind, property_eq: planner.PropertyPredicate) bool {
    if (property_eq.op != .eq or kind != .task) return false;
    const expected = task_mod.Status.parse(property_eq.value) orelse return false;
    // The in-memory Graph has no property sidecar or lease clock. Tasks in
    // this compatibility executor therefore have the only representable
    // lifecycle state: open.
    return expected == .open;
}

fn edgeCursorMatchesStringProperty(edge_cursor: query_mod.EdgeCursor, allocator: std.mem.Allocator, edge_id: core.EdgeId, property_eq: planner.PropertyPredicate) !bool {
    if (property_eq.op != .eq) return false;
    const value = switch (edge_cursor) {
        .memory => return false,
        .store => |cursor| cursor.store.getStringProperty(allocator, .{ .edge = edge_id }, property_eq.key) catch |err| switch (err) {
            core.Error.InvalidId, core.Error.NotFound => return false,
            else => |e| return e,
        },
        .persistent_store => |cursor| cursor.store.getStringProperty(allocator, .{ .edge = edge_id }, property_eq.key) catch |err| switch (err) {
            core.Error.InvalidId, core.Error.NotFound => return false,
            else => |e| return e,
        },
    };
    defer if (value) |owned| allocator.free(owned);
    return if (value) |owned| std.mem.eql(u8, owned, property_eq.value) else false;
}

fn edgeIdSliceContains(sorted_ids: []const core.EdgeId, edge_id: core.EdgeId) bool {
    var lo: usize = 0;
    var hi: usize = sorted_ids.len;
    const needle = edge_id.toInt();
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const current = sorted_ids[mid].toInt();
        if (current < needle) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    return lo < sorted_ids.len and sorted_ids[lo].toInt() == needle;
}

fn lookupEdgeIdsByProperty(edge_cursor: query_mod.EdgeCursor, allocator: std.mem.Allocator, property_eq: planner.PropertyPredicate) !std.ArrayList(core.EdgeId) {
    if (property_eq.op != .eq) return std.ArrayList(core.EdgeId).empty;
    return switch (edge_cursor) {
        .memory => return std.ArrayList(core.EdgeId).empty,
        .store => |cursor| try cursor.store.lookupEdgeIdsByStringProperty(allocator, property_eq.key, property_eq.value, std.math.maxInt(usize)),
        .persistent_store => |cursor| try cursor.store.lookupEdgeIdsByStringProperty(allocator, property_eq.key, property_eq.value, std.math.maxInt(usize)),
    };
}

fn lookupStoreNodeIdsByProperty(store: storage.Store, allocator: std.mem.Allocator, property_eq: planner.PropertyPredicate, kind_filter: ?core.NodeKind, max_ids: usize) !std.ArrayList(core.NodeId) {
    if (nodeUintPropertySupported(property_eq.key)) {
        if (property_eq.uint_range) |planner_range| {
            const range = uintPropertyRangeForPlannerRange(planner_range) orelse return std.ArrayList(core.NodeId).empty;
            return try store.lookupNodeIdsByUintPropertyRange(allocator, property_eq.key, range, kind_filter, max_ids);
        }
        const expected = std.fmt.parseInt(u64, property_eq.value, 10) catch {
            return std.ArrayList(core.NodeId).empty;
        };
        if (property_eq.op != .eq) {
            return try store.lookupNodeIdsByUintPropertyRange(allocator, property_eq.key, uintPropertyRangeForPredicate(property_eq.op, expected), kind_filter, max_ids);
        }
        return try store.lookupNodeIdsByUintProperty(allocator, property_eq.key, expected, kind_filter, max_ids);
    }
    if (property_eq.op != .eq) return std.ArrayList(core.NodeId).empty;
    if (nodeStringPropertyMissingMatchesEmpty(property_eq)) {
        return try lookupStoreNodeIdsByMissingStringProperty(store, allocator, property_eq.key, kind_filter, max_ids);
    }
    return try store.lookupNodeIdsByStringProperty(allocator, property_eq.key, property_eq.value, kind_filter, max_ids);
}

const task_status_manifest_max_bytes: usize = 64 * 1024;
const task_status_schema_version: u32 = 3;

const TaskStatusStoreManifest = struct {
    store_manifest_version: ?u32 = null,
    storage_format_version: ?u32 = null,
    schema: ?struct {
        schema_version: ?u32 = null,
    } = null,
};

fn storeHasMaterializedTaskStatus(allocator: std.mem.Allocator, store: storage.Store) !bool {
    const path = try std.fs.path.join(allocator, &.{ store.dir_path, ".tinykg", "store-manifest.json" });
    defer allocator.free(path);
    const bytes = std.Io.Dir.cwd().readFileAlloc(store.io, path, allocator, .limited(task_status_manifest_max_bytes)) catch |err| switch (err) {
        error.FileNotFound, error.NotDir => return false,
        else => |e| return e,
    };
    defer allocator.free(bytes);
    var parsed = std.json.parseFromSlice(TaskStatusStoreManifest, allocator, bytes, .{
        .ignore_unknown_fields = true,
    }) catch return error.InvalidStoreManifest;
    defer parsed.deinit();
    if (parsed.value.store_manifest_version != 1) return false;
    if ((parsed.value.storage_format_version orelse 0) < 2) return false;
    return if (parsed.value.schema) |manifest_schema| (manifest_schema.schema_version orelse 0) >= task_status_schema_version else false;
}

fn currentStoreReadTimestampNs(store: storage.Store) u64 {
    const timestamp = std.Io.Clock.real.now(store.io).nanoseconds;
    return if (timestamp < 0) 0 else @intCast(timestamp);
}

fn appendNodeIdCandidates(allocator: std.mem.Allocator, out: *std.ArrayList(core.NodeId), candidates: *std.ArrayList(core.NodeId)) !void {
    defer candidates.deinit(allocator);
    try out.appendSlice(allocator, candidates.items);
}

fn appendRawTaskStatusCandidates(
    store: storage.Store,
    allocator: std.mem.Allocator,
    out: *std.ArrayList(core.NodeId),
    raw_status: task_mod.Status,
    candidate_limit: usize,
    candidates_saturated: *bool,
) !void {
    const probe_limit = try currentGenerationCandidateProbeLimit(candidate_limit);
    var candidates = try store.lookupNodeIdsByStringProperty(
        allocator,
        task_mod.status_property,
        @tagName(raw_status),
        .task,
        probe_limit,
    );
    if (candidates.items.len > candidate_limit) candidates_saturated.* = true;
    try appendNodeIdCandidates(allocator, out, &candidates);
}

fn deduplicateSortedNodeIds(ids: *std.ArrayList(core.NodeId)) void {
    if (ids.items.len < 2) return;
    sortNodeIds(ids.items);
    var write_index: usize = 1;
    for (ids.items[1..]) |id| {
        if (id == ids.items[write_index - 1]) continue;
        ids.items[write_index] = id;
        write_index += 1;
    }
    ids.shrinkRetainingCapacity(write_index);
}

/// `status` is virtual/effective even though its durable commit marker is
/// indexed. Build a bounded candidate union from the raw status and lease
/// indexes, then validate each row at the query's single read timestamp.
/// Pre-v3 stores can have tasks without a status marker, so only those stores
/// receive a bounded compatibility scan; migrated stores never fall back to
/// an O(task-count) read path.
fn lookupStoreTaskIdsByEffectiveStatus(
    store: storage.Store,
    allocator: std.mem.Allocator,
    edge_retention_registry: ?*storage.EdgeSegmentRetentionRegistry,
    type_filter: schema.NodeTypeFilter,
    property_eq: planner.PropertyPredicate,
    max_ids: usize,
    now_ns: u64,
) !std.ArrayList(core.NodeId) {
    var out = std.ArrayList(core.NodeId).empty;
    errdefer out.deinit(allocator);
    if (max_ids == 0 or property_eq.op != .eq or !type_filter.matches(.task)) return out;
    const expected = task_mod.Status.parse(property_eq.value) orelse return out;

    const candidate_limit = currentGenerationCandidateLimit(max_ids);
    var ids = std.ArrayList(core.NodeId).empty;
    defer ids.deinit(allocator);
    var candidates_saturated = false;
    switch (expected) {
        .completed, .failed => {
            try appendRawTaskStatusCandidates(store, allocator, &ids, expected, candidate_limit, &candidates_saturated);
        },
        .claimed => {
            if (now_ns == std.math.maxInt(u64)) return out;
            try appendRawTaskStatusCandidates(store, allocator, &ids, .claimed, candidate_limit, &candidates_saturated);
        },
        .open => {
            // Effective open is the union of raw open and expired raw claimed.
            // Selecting by lease alone also admits terminal tasks with stale
            // lease fields; enough of those could hide every valid result
            // before the bounded candidate limit.
            try appendRawTaskStatusCandidates(store, allocator, &ids, .open, candidate_limit, &candidates_saturated);
            try appendRawTaskStatusCandidates(store, allocator, &ids, .claimed, candidate_limit, &candidates_saturated);
        },
    }

    const materialized_task_status = try storeHasMaterializedTaskStatus(allocator, store);
    if (expected == .open and materialized_task_status) {
        // A schema-v3 manifest proves that a completed migration published all
        // existing status markers, but it cannot make a later node append and
        // property-delta append atomic. Include a bounded task scan so a crash
        // in that gap cannot silently hide an implicit-open task. Saturation
        // fails closed below unless the requested LIMIT is already satisfied.
        const probe_limit = try currentGenerationCandidateProbeLimit(candidate_limit);
        var implicit_open_candidates = try store.scanNodeIds(allocator, .task, probe_limit);
        if (implicit_open_candidates.items.len > candidate_limit) candidates_saturated = true;
        try appendNodeIdCandidates(allocator, &ids, &implicit_open_candidates);
    }

    if ((expected == .open or expected == .claimed) and !materialized_task_status) {
        // Small legacy stores preserve the pre-status behavior exactly. The
        // cap prevents one predicate from allocating/scanning an unbounded
        // task population; large legacy stores must use migrate-store-v2
        // --task-status-v1 before effective-status queries.
        const legacy_sentinel_limit = std.math.add(usize, candidate_limit, 1) catch return core.Error.BudgetExceeded;
        var legacy = try store.scanNodeIds(allocator, .task, legacy_sentinel_limit);
        if (legacy.items.len > candidate_limit) {
            legacy.deinit(allocator);
            return error.TaskStatusMigrationRequired;
        }
        try appendNodeIdCandidates(allocator, &ids, &legacy);
    }
    deduplicateSortedNodeIds(&ids);

    // Do not validate each candidate through three independent property point
    // lookups: every point lookup must validate the append-only delta, turning
    // a status query into O(candidates * delta).  One owner-bounded lifecycle
    // snapshot preserves the single read timestamp and amortizes that work.
    var status_snapshot = try task_mod.StatusSnapshot.initForNodeIds(allocator, store, ids.items);
    defer status_snapshot.deinit();
    var node_view = try store.openNodeRecordView();
    defer node_view.deinit();
    for (ids.items) |id| {
        if (out.items.len >= max_ids) break;
        if (!try nodeCursorStoreNodeIsCurrentGeneration(store, edge_retention_registry, id)) continue;
        var node = (try node_view.readNodeById(allocator, id)) orelse return error.InvalidRecord;
        defer node.deinit(allocator);
        if ((try status_snapshot.statusForStoredNode(node, now_ns)) != expected) continue;
        try out.append(allocator, id);
    }
    // A bounded lookup must never turn candidate pressure into a successful
    // but incomplete result.  Callers can raise the query budget/limit or
    // compact stale generations; silently returning fewer rows is incorrect.
    if (out.items.len < max_ids and candidates_saturated) return core.Error.BudgetExceeded;
    return out;
}

/// `status` is a task lifecycle virtual property only for physical task
/// nodes.  Other catalog types are allowed to define an unrelated property
/// with the same name (for example `ticket.status = published`).  Preserve
/// those ordinary indexed values while merging effective task candidates for
/// filters that can match both domains.
fn lookupStoreNodeIdsByStatusProperty(
    store: storage.Store,
    allocator: std.mem.Allocator,
    edge_retention_registry: ?*storage.EdgeSegmentRetentionRegistry,
    type_filter: schema.NodeTypeFilter,
    property_eq: planner.PropertyPredicate,
    max_ids: usize,
    now_ns: u64,
) !std.ArrayList(core.NodeId) {
    var merged = std.ArrayList(core.NodeId).empty;
    errdefer merged.deinit(allocator);
    if (max_ids == 0 or property_eq.op != .eq) return merged;

    var task_candidates_saturated = false;
    var task_status_migration_required = false;
    if (type_filter.matches(.task)) {
        // A mixed-domain query may use `status` both as the virtual task
        // lifecycle and as an ordinary catalog property.  Candidate pressure
        // in the task subdomain must not fail the whole unordered LIMIT before
        // the non-task subdomain gets a chance to satisfy it completely.
        var tasks = lookupStoreTaskIdsByEffectiveStatus(store, allocator, edge_retention_registry, type_filter, property_eq, max_ids, now_ns) catch |err| switch (err) {
            core.Error.BudgetExceeded => blk: {
                task_candidates_saturated = true;
                break :blk std.ArrayList(core.NodeId).empty;
            },
            error.TaskStatusMigrationRequired => blk: {
                task_candidates_saturated = true;
                task_status_migration_required = true;
                break :blk std.ArrayList(core.NodeId).empty;
            },
            else => |e| return e,
        };
        defer tasks.deinit(allocator);
        try merged.appendSlice(allocator, tasks.items);
    }

    const candidate_limit = currentGenerationCandidateLimit(max_ids);
    const probe_limit = try currentGenerationCandidateProbeLimit(candidate_limit);
    var raw_candidates_saturated = false;
    if (typeFilterIsAny(type_filter)) {
        var ids = try lookupStoreNodeIdsByProperty(store, allocator, property_eq, null, probe_limit);
        defer ids.deinit(allocator);
        if (ids.items.len > candidate_limit) raw_candidates_saturated = true;
        var node_view = try store.openNodeRecordView();
        defer node_view.deinit();
        for (ids.items) |id| {
            var node = (try node_view.readNodeById(allocator, id)) orelse return error.InvalidRecord;
            defer node.deinit(allocator);
            if (node.kind == .task or !type_filter.matches(node.kind)) continue;
            try merged.append(allocator, id);
        }
    } else if (type_filter.asSingle()) |kind| {
        if (kind != .task) {
            var ids = try lookupStoreNodeIdsByProperty(store, allocator, property_eq, kind, probe_limit);
            defer ids.deinit(allocator);
            if (ids.items.len > candidate_limit) raw_candidates_saturated = true;
            try merged.appendSlice(allocator, ids.items);
        }
    } else {
        for (0..schema.max_node_types) |raw_id| {
            const kind: core.NodeKind = @enumFromInt(@as(u16, @intCast(raw_id)));
            if (kind == .task or !type_filter.matches(kind)) continue;
            var ids = try lookupStoreNodeIdsByProperty(store, allocator, property_eq, kind, probe_limit);
            defer ids.deinit(allocator);
            if (ids.items.len > candidate_limit) raw_candidates_saturated = true;
            try merged.appendSlice(allocator, ids.items);
        }
    }

    deduplicateSortedNodeIds(&merged);
    var write_index: usize = 0;
    for (merged.items) |id| {
        if (write_index >= max_ids) break;
        if (!try nodeCursorStoreNodeIsCurrentGeneration(store, edge_retention_registry, id)) continue;
        merged.items[write_index] = id;
        write_index += 1;
    }
    merged.shrinkRetainingCapacity(write_index);
    if (merged.items.len < max_ids and task_status_migration_required) return error.TaskStatusMigrationRequired;
    if (merged.items.len < max_ids and (raw_candidates_saturated or task_candidates_saturated)) return core.Error.BudgetExceeded;
    return merged;
}

fn lookupStoreNodeIdsByMissingStringProperty(store: storage.Store, allocator: std.mem.Allocator, key: []const u8, kind_filter: ?core.NodeKind, max_ids: usize) !std.ArrayList(core.NodeId) {
    var out = std.ArrayList(core.NodeId).empty;
    errdefer out.deinit(allocator);
    if (max_ids == 0) return out;
    var ids = try store.scanNodeIds(allocator, kind_filter, max_ids);
    defer ids.deinit(allocator);
    for (ids.items) |node_id| {
        const value = store.getNodeStringProperty(allocator, node_id, key) catch |err| switch (err) {
            core.Error.InvalidId, core.Error.NotFound => continue,
            else => |e| return e,
        };
        defer if (value) |owned| allocator.free(owned);
        if (value) |owned| {
            if (owned.len != 0) continue;
        }
        try out.append(allocator, node_id);
    }
    return out;
}

fn visibleNodeText(text: []const u8) []const u8 {
    return text;
}

fn visibleNodeTextEquals(text: []const u8, expected: []const u8) bool {
    return std.mem.eql(u8, text, expected);
}

fn appendUniqueNodeId(allocator: std.mem.Allocator, out: *std.ArrayList(core.NodeId), node_id: core.NodeId) !void {
    for (out.items) |existing| {
        if (existing == node_id) return;
    }
    try out.append(allocator, node_id);
}

const NodeCursor = union(enum) {
    memory: struct {
        graph: *const graph_mod.Graph,
        mem_index: *index.MemoryIndex,
    },
    store: struct {
        allocator: std.mem.Allocator,
        store: storage.Store,
        state: ?*PersistentNodeCursorState = null,
    },

    fn get(self: NodeCursor, allocator: std.mem.Allocator, id: core.NodeId) !?NodeView {
        return switch (self) {
            .memory => |cursor| blk: {
                const node = cursor.mem_index.getNode(cursor.graph, id) orelse break :blk null;
                break :blk NodeView.fromGraphNode(node);
            },
            .store => |cursor| blk: {
                const node = if (cursor.state) |state|
                    (try state.readNodeById(allocator, id)) orelse break :blk null
                else
                    (try cursor.store.readNodeById(allocator, id)) orelse break :blk null;
                break :blk NodeView.fromStoredNode(node);
            },
        };
    }

    fn matchNode(self: NodeCursor, allocator: std.mem.Allocator, id: core.NodeId, kind_filter: ?core.NodeKind, text_eq: ?[]const u8) !?bool {
        return self.matchNodeFilter(allocator, id, schema.NodeTypeFilter.fromOptionalKind(kind_filter), text_eq);
    }

    fn matchNodeFilter(self: NodeCursor, allocator: std.mem.Allocator, id: core.NodeId, type_filter: schema.NodeTypeFilter, text_eq: ?[]const u8) !?bool {
        return switch (self) {
            .memory => |cursor| blk: {
                const node = cursor.mem_index.getNode(cursor.graph, id) orelse break :blk null;
                if (!nodeCursorMemoryNodeIsCurrentGeneration(cursor.graph, id)) break :blk false;
                if (!type_filter.matches(node.kind)) break :blk false;
                if (text_eq) |text| {
                    if (!visibleNodeTextEquals(node.text, text)) break :blk false;
                }
                break :blk true;
            },
            .store => |cursor| blk: {
                if (cursor.state) |state| {
                    break :blk try state.matchNodeFilter(id, type_filter, text_eq);
                }
                var node = (try cursor.store.readNodeById(allocator, id)) orelse break :blk null;
                defer node.deinit(allocator);
                if (!try nodeCursorStoreNodeIsCurrentGeneration(cursor.store, null, id)) break :blk false;
                if (!type_filter.matches(node.kind)) break :blk false;
                if (text_eq) |text| {
                    if (!visibleNodeTextEquals(node.text, text)) break :blk false;
                }
                break :blk true;
            },
        };
    }

    fn lookupByText(self: NodeCursor, allocator: std.mem.Allocator, kind_filter: ?core.NodeKind, text: []const u8, max_ids: usize) !std.ArrayList(core.NodeId) {
        return self.lookupByTextFilter(allocator, schema.NodeTypeFilter.fromOptionalKind(kind_filter), text, max_ids);
    }

    fn lookupByTextFilter(self: NodeCursor, allocator: std.mem.Allocator, type_filter: schema.NodeTypeFilter, text: []const u8, max_ids: usize) !std.ArrayList(core.NodeId) {
        var out = std.ArrayList(core.NodeId).empty;
        errdefer out.deinit(allocator);
        if (max_ids == 0) return out;
        const candidate_limit = currentGenerationCandidateLimit(max_ids);
        const probe_limit = try currentGenerationCandidateProbeLimit(candidate_limit);
        if (type_filter.asSingle()) |kind| {
            switch (self) {
                .memory => |cursor| {
                    for (try cursor.mem_index.lookupByText(kind, text)) |id| {
                        if (out.items.len >= max_ids) break;
                        if (!nodeCursorMemoryNodeIsCurrentGeneration(cursor.graph, id)) continue;
                        try appendUniqueNodeId(allocator, &out, id);
                    }
                },
                .store => |cursor| {
                    var ids = if (cursor.state) |state|
                        try state.lookupByText(allocator, kind, text, probe_limit)
                    else
                        try cursor.store.lookupNodeIdsByTextLimited(allocator, kind, text, probe_limit);
                    defer ids.deinit(allocator);
                    try nodeCursorRetainStoreCurrentGeneration(cursor.store, if (cursor.state) |state| state.edge_retention_registry else null, &ids, candidate_limit, max_ids);
                    for (ids.items) |id| try appendUniqueNodeId(allocator, &out, id);
                },
            }
            return out;
        }
        switch (self) {
            .memory => |cursor| {
                for (try cursor.mem_index.lookupByText(null, text)) |id| {
                    if (out.items.len >= max_ids) break;
                    if (!nodeCursorMemoryNodeIsCurrentGeneration(cursor.graph, id)) continue;
                    const node = cursor.mem_index.getNode(cursor.graph, id) orelse continue;
                    if (!type_filter.matches(node.kind)) continue;
                    try appendUniqueNodeId(allocator, &out, id);
                }
            },
            .store => |cursor| {
                if (typeFilterIsAny(type_filter)) {
                    var ids = if (cursor.state) |state|
                        try state.lookupByText(allocator, null, text, probe_limit)
                    else
                        try cursor.store.lookupNodeIdsByTextLimited(allocator, null, text, probe_limit);
                    defer ids.deinit(allocator);
                    try nodeCursorRetainStoreCurrentGeneration(cursor.store, if (cursor.state) |state| state.edge_retention_registry else null, &ids, candidate_limit, max_ids);
                    for (ids.items) |id| try appendUniqueNodeId(allocator, &out, id);
                    return out;
                }
                var merged = std.ArrayList(core.NodeId).empty;
                errdefer merged.deinit(allocator);
                defer merged.deinit(allocator);
                var candidates_saturated = false;
                for (0..schema.max_node_types) |raw_id| {
                    const kind: core.NodeKind = @enumFromInt(@as(u16, @intCast(raw_id)));
                    if (!type_filter.matches(kind)) continue;
                    var ids = if (cursor.state) |state|
                        try state.lookupByText(allocator, kind, text, probe_limit)
                    else
                        try cursor.store.lookupNodeIdsByTextLimited(allocator, kind, text, probe_limit);
                    defer ids.deinit(allocator);
                    if (ids.items.len > candidate_limit) candidates_saturated = true;
                    try merged.appendSlice(allocator, ids.items);
                }
                sortNodeIds(merged.items);
                for (merged.items) |id| {
                    if (out.items.len >= max_ids) break;
                    if (!try nodeCursorStoreNodeIsCurrentGeneration(cursor.store, if (cursor.state) |state| state.edge_retention_registry else null, id)) continue;
                    try appendUniqueNodeId(allocator, &out, id);
                }
                if (out.items.len < max_ids and candidates_saturated) return core.Error.BudgetExceeded;
            },
        }
        return out;
    }

    fn lookupByPropertyFilter(self: NodeCursor, allocator: std.mem.Allocator, type_filter: schema.NodeTypeFilter, property_eq: planner.PropertyPredicate, max_ids: usize) !std.ArrayList(core.NodeId) {
        var out = std.ArrayList(core.NodeId).empty;
        errdefer out.deinit(allocator);
        if (max_ids == 0) return out;
        const candidate_limit = currentGenerationCandidateLimit(max_ids);
        const probe_limit = try currentGenerationCandidateProbeLimit(candidate_limit);
        switch (self) {
            .memory => |cursor| {
                const needs_uint_order = nodeUintPropertySupported(property_eq.key);
                for (cursor.graph.nodes.items) |node| {
                    if (!needs_uint_order and out.items.len >= max_ids) break;
                    if (node.status != .active) continue;
                    if (!nodeCursorMemoryNodeIsCurrentGeneration(cursor.graph, node.id)) continue;
                    if (!type_filter.matches(node.kind)) continue;
                    const matches = if (node.kind == .task and std.mem.eql(u8, property_eq.key, task_mod.status_property))
                        memoryNodeMatchesEffectiveStatus(node.kind, property_eq)
                    else
                        try nodeMatchesProperty(allocator, node.text, property_eq);
                    if (!matches) continue;
                    try out.append(allocator, node.id);
                }
                if (needs_uint_order) {
                    sortNodeIdsByUintProperty(allocator, cursor.graph, cursor.mem_index, out.items, property_eq.key);
                    if (out.items.len > max_ids) out.shrinkRetainingCapacity(max_ids);
                }
            },
            .store => |cursor| {
                if (std.mem.eql(u8, property_eq.key, task_mod.status_property)) {
                    const now_ns = if (cursor.state) |state| state.read_timestamp_ns else currentStoreReadTimestampNs(cursor.store);
                    return try lookupStoreNodeIdsByStatusProperty(cursor.store, allocator, if (cursor.state) |state| state.edge_retention_registry else null, type_filter, property_eq, max_ids, now_ns);
                }
                if (type_filter.asSingle()) |kind| {
                    var ids = try lookupStoreNodeIdsByProperty(cursor.store, allocator, property_eq, kind, probe_limit);
                    errdefer ids.deinit(allocator);
                    try nodeCursorRetainStoreCurrentGeneration(cursor.store, if (cursor.state) |state| state.edge_retention_registry else null, &ids, candidate_limit, max_ids);
                    return ids;
                }
                if (typeFilterIsAny(type_filter)) {
                    var ids = try lookupStoreNodeIdsByProperty(cursor.store, allocator, property_eq, null, probe_limit);
                    errdefer ids.deinit(allocator);
                    try nodeCursorRetainStoreCurrentGeneration(cursor.store, if (cursor.state) |state| state.edge_retention_registry else null, &ids, candidate_limit, max_ids);
                    return ids;
                }
                var merged = std.ArrayList(core.NodeId).empty;
                errdefer merged.deinit(allocator);
                defer merged.deinit(allocator);
                var candidates_saturated = false;
                for (0..schema.max_node_types) |raw_id| {
                    const kind: core.NodeKind = @enumFromInt(@as(u16, @intCast(raw_id)));
                    if (!type_filter.matches(kind)) continue;
                    var ids = try lookupStoreNodeIdsByProperty(cursor.store, allocator, property_eq, kind, probe_limit);
                    defer ids.deinit(allocator);
                    if (ids.items.len > candidate_limit) candidates_saturated = true;
                    try merged.appendSlice(allocator, ids.items);
                }
                sortNodeIds(merged.items);
                for (merged.items) |id| {
                    if (out.items.len >= max_ids) break;
                    if (!try nodeCursorStoreNodeIsCurrentGeneration(cursor.store, if (cursor.state) |state| state.edge_retention_registry else null, id)) continue;
                    try out.append(allocator, id);
                }
                if (out.items.len < max_ids and candidates_saturated) return core.Error.BudgetExceeded;
            },
        }
        return out;
    }

    fn matchStringProperty(self: NodeCursor, allocator: std.mem.Allocator, id: core.NodeId, property_eq: planner.PropertyPredicate) !?bool {
        var node = (try self.get(allocator, id)) orelse return null;
        defer node.deinit(allocator);
        if (nodeUintPropertySupported(property_eq.key)) {
            return switch (self) {
                .memory => try nodeMatchesProperty(allocator, node.text, property_eq),
                .store => |cursor| blk: {
                    const concrete = try cursor.store.getUintProperty(allocator, .{ .node = id }, property_eq.key) orelse break :blk false;
                    if (property_eq.uint_range) |planner_range| {
                        const range = uintPropertyRangeForPlannerRange(planner_range) orelse break :blk false;
                        break :blk uintPropertyRangeContains(range, concrete);
                    }
                    const expected = std.fmt.parseInt(u64, property_eq.value, 10) catch break :blk false;
                    break :blk predicateMatchesUint(property_eq.op, concrete, expected);
                },
            };
        }
        if (property_eq.op != .eq) return false;
        return switch (self) {
            .memory => if (node.kind == .task and std.mem.eql(u8, property_eq.key, task_mod.status_property))
                memoryNodeMatchesEffectiveStatus(node.kind, property_eq)
            else
                try nodeMatchesStringProperty(allocator, node.text, property_eq),
            .store => |cursor| blk: {
                if (std.mem.eql(u8, property_eq.key, task_mod.status_property) and node.kind == .task) {
                    const now_ns = if (cursor.state) |state| state.read_timestamp_ns else currentStoreReadTimestampNs(cursor.store);
                    const lifecycle = try task_mod.statusWithPersistentStoreAt(allocator, cursor.store, id, now_ns);
                    break :blk std.mem.eql(u8, @tagName(lifecycle), property_eq.value);
                }
                const value = cursor.store.getNodeStringProperty(allocator, id, property_eq.key) catch |err| switch (err) {
                    core.Error.InvalidId, core.Error.NotFound => break :blk null,
                    else => |e| return e,
                };
                defer if (value) |owned| allocator.free(owned);
                break :blk if (value) |owned|
                    std.mem.eql(u8, owned, property_eq.value)
                else
                    nodeStringPropertyMissingMatchesEmpty(property_eq);
            },
        };
    }

    fn uintProperty(self: NodeCursor, allocator: std.mem.Allocator, id: core.NodeId, key: []const u8) !?u64 {
        if (!nodeUintPropertySupported(key)) return null;
        return switch (self) {
            .memory => blk: {
                var node = (try self.get(allocator, id)) orelse return null;
                defer node.deinit(allocator);
                break :blk nodeUintPropertyValue(allocator, node.text, key);
            },
            .store => |cursor| try cursor.store.getUintProperty(allocator, .{ .node = id }, key),
        };
    }

    fn scan(self: NodeCursor, allocator: std.mem.Allocator, kind_filter: ?core.NodeKind, max_ids: usize) !std.ArrayList(core.NodeId) {
        return self.scanFilter(allocator, schema.NodeTypeFilter.fromOptionalKind(kind_filter), max_ids);
    }

    fn scanFilter(self: NodeCursor, allocator: std.mem.Allocator, type_filter: schema.NodeTypeFilter, max_ids: usize) !std.ArrayList(core.NodeId) {
        return switch (self) {
            .memory => |cursor| blk: {
                var out = std.ArrayList(core.NodeId).empty;
                errdefer out.deinit(allocator);
                for (cursor.graph.nodes.items) |node| {
                    if (out.items.len >= max_ids) break;
                    if (node.status != .active) continue;
                    if (!nodeCursorMemoryNodeIsCurrentGeneration(cursor.graph, node.id)) continue;
                    if (!type_filter.matches(node.kind)) continue;
                    try out.append(allocator, node.id);
                }
                break :blk out;
            },
            .store => |cursor| blk: {
                const candidate_limit = currentGenerationCandidateLimit(max_ids);
                const probe_limit = try currentGenerationCandidateProbeLimit(candidate_limit);
                if (type_filter.asSingle()) |kind| {
                    var ids = try cursor.store.scanNodeIds(allocator, kind, probe_limit);
                    errdefer ids.deinit(allocator);
                    try nodeCursorRetainStoreCurrentGeneration(cursor.store, if (cursor.state) |state| state.edge_retention_registry else null, &ids, candidate_limit, max_ids);
                    break :blk ids;
                }
                if (typeFilterIsAny(type_filter)) {
                    var ids = try cursor.store.scanNodeIds(allocator, null, probe_limit);
                    errdefer ids.deinit(allocator);
                    try nodeCursorRetainStoreCurrentGeneration(cursor.store, if (cursor.state) |state| state.edge_retention_registry else null, &ids, candidate_limit, max_ids);
                    break :blk ids;
                }
                var merged = std.ArrayList(core.NodeId).empty;
                errdefer merged.deinit(allocator);
                var candidates_saturated = false;
                for (0..schema.max_node_types) |raw_id| {
                    const kind: core.NodeKind = @enumFromInt(@as(u16, @intCast(raw_id)));
                    if (!type_filter.matches(kind)) continue;
                    var ids = try cursor.store.scanNodeIds(allocator, kind, probe_limit);
                    defer ids.deinit(allocator);
                    if (ids.items.len > candidate_limit) candidates_saturated = true;
                    try merged.appendSlice(allocator, ids.items);
                }
                sortNodeIds(merged.items);
                var write_index: usize = 0;
                for (merged.items) |id| {
                    if (write_index >= max_ids) break;
                    if (!try nodeCursorStoreNodeIsCurrentGeneration(cursor.store, if (cursor.state) |state| state.edge_retention_registry else null, id)) continue;
                    merged.items[write_index] = id;
                    write_index += 1;
                }
                merged.shrinkRetainingCapacity(write_index);
                if (merged.items.len < max_ids and candidates_saturated) return core.Error.BudgetExceeded;
                break :blk merged;
            },
        };
    }

    fn searchText(
        self: NodeCursor,
        allocator: std.mem.Allocator,
        query: []const u8,
        type_filter: schema.NodeTypeFilter,
        max_ids: usize,
        max_postings_scanned: usize,
        deadline: core.QueryDeadline,
    ) !std.ArrayList(text_mod.TextSearchHit) {
        const kind_filter = type_filter.asSingle();
        var kind_set_storage: schema.NodeTypeSet = undefined;
        const kind_set_filter: ?*const schema.NodeTypeSet = switch (type_filter) {
            .set => |set| blk: {
                kind_set_storage = set;
                break :blk &kind_set_storage;
            },
            else => null,
        };
        return switch (self) {
            .memory => |cursor| blk: {
                var text_index = try text_mod.TextIndex.buildFromGraphDeadline(allocator, cursor.graph, deadline);
                defer text_index.deinit();
                break :blk try text_index.search(query, .{
                    .kind_filter = kind_filter,
                    .kind_set_filter = kind_set_filter,
                    .limit = max_ids,
                    .max_postings_scanned = max_postings_scanned,
                    .deadline = deadline,
                });
            },
            .store => |cursor| blk: {
                const candidate_limit = textSearchCandidateLimitForLatest(max_ids);
                var hits = try text_mod.searchText(allocator, cursor.store, query, .{
                    .kind_filter = kind_filter,
                    .kind_set_filter = kind_set_filter,
                    .limit = try currentGenerationCandidateProbeLimit(candidate_limit),
                    .max_postings_scanned = max_postings_scanned,
                    .deadline = deadline,
                });
                errdefer hits.deinit(allocator);
                try retainCurrentGenerationTextHits(cursor.store, if (cursor.state) |state| state.edge_retention_registry else null, &hits, candidate_limit, max_ids);
                break :blk hits;
            },
        };
    }
};

fn textSearchCandidateLimitForLatest(max_ids: usize) usize {
    if (max_ids == 0) return 0;
    const max_candidate_limit: usize = 4096;
    const expanded = std.math.add(usize, std.math.mul(usize, max_ids, 4) catch max_candidate_limit, 32) catch max_candidate_limit;
    return @max(max_ids, @min(max_candidate_limit, expanded));
}

fn retainCurrentGenerationTextHits(store: storage.Store, edge_retention_registry: ?*storage.EdgeSegmentRetentionRegistry, hits: *std.ArrayList(text_mod.TextSearchHit), candidate_limit: usize, max_ids: usize) !void {
    const candidate_count = hits.items.len;
    var write_index: usize = 0;
    for (hits.items) |hit| {
        if (write_index >= max_ids) break;
        if (!try nodeCursorStoreNodeIsCurrentGeneration(store, edge_retention_registry, hit.node_id)) continue;
        hits.items[write_index] = hit;
        write_index += 1;
    }
    hits.shrinkRetainingCapacity(write_index);
    if (hits.items.len < max_ids and candidate_count > candidate_limit) return core.Error.BudgetExceeded;
}

fn currentGenerationCandidateLimit(max_ids: usize) usize {
    if (max_ids == 0) return 0;
    const max_candidate_limit: usize = 4096;
    const expanded = std.math.add(usize, std.math.mul(usize, max_ids, 4) catch max_candidate_limit, 32) catch max_candidate_limit;
    // Cap only speculative overfetch. An explicit result request larger than
    // the cap must still be allowed to return the requested number of rows.
    return @max(max_ids, @min(max_candidate_limit, expanded));
}

fn currentGenerationCandidateProbeLimit(candidate_limit: usize) !usize {
    return std.math.add(usize, candidate_limit, 1) catch core.Error.BudgetExceeded;
}

fn nodeCursorRetainStoreCurrentGeneration(store: storage.Store, edge_retention_registry: ?*storage.EdgeSegmentRetentionRegistry, ids: *std.ArrayList(core.NodeId), candidate_limit: usize, max_ids: usize) !void {
    const candidate_count = ids.items.len;
    var write_index: usize = 0;
    for (ids.items) |id| {
        if (write_index >= max_ids) break;
        if (!try nodeCursorStoreNodeIsCurrentGeneration(store, edge_retention_registry, id)) continue;
        ids.items[write_index] = id;
        write_index += 1;
    }
    ids.shrinkRetainingCapacity(write_index);
    if (ids.items.len < max_ids and candidate_count > candidate_limit) return core.Error.BudgetExceeded;
}

fn nodeCursorStoreNodeIsCurrentGeneration(store: storage.Store, edge_retention_registry: ?*storage.EdgeSegmentRetentionRegistry, node_id: core.NodeId) !bool {
    const Visitor = struct {
        fn visit(_: void, record: storage.EdgeIndexRecord) !bool {
            _ = record;
            return true;
        }
    };
    const found = if (edge_retention_registry) |registry|
        try store.forEachVisibleEdgeIndexRecordByNodeRetained(store.allocator, registry, .src, node_id, .deprecated_by, 1, {}, Visitor.visit)
    else
        try store.forEachVisibleEdgeIndexRecordByNode(store.allocator, .src, node_id, .deprecated_by, 1, {}, Visitor.visit);
    return !found;
}

fn nodeCursorMemoryNodeIsCurrentGeneration(graph: *const graph_mod.Graph, node_id: core.NodeId) bool {
    for (graph.edges.items) |edge| {
        if (edge.status != .active) continue;
        if (edge.src == node_id and edge.rel == .deprecated_by) return false;
    }
    return true;
}

const PersistentNodeCursorState = struct {
    // Avoid paying mmap/open setup for tiny result sets; switch after repeated node materialization.
    const direct_reads_before_view: usize = 8;

    store: storage.Store,
    edge_retention_registry: ?*storage.EdgeSegmentRetentionRegistry = null,
    node_text_retention_registry: ?*storage.NodeTextRunRetentionRegistry = null,
    node_view: ?storage.Store.NodeRecordView = null,
    node_id_view: ?storage.Store.NodeByIdIndexView = null,
    node_text_lookup_view: ?storage.Store.NodeTextLookupView = null,
    direct_reads: usize = 0,
    read_timestamp_ns: u64 = 0,

    fn deinit(self: *PersistentNodeCursorState) void {
        if (self.node_text_lookup_view) |*view| view.deinit();
        if (self.node_view) |*view| view.deinit();
        if (self.node_id_view) |*view| view.deinit();
    }

    fn readNodeById(self: *PersistentNodeCursorState, allocator: std.mem.Allocator, id: core.NodeId) !?storage.StoredNode {
        if (self.node_view == null and self.direct_reads < direct_reads_before_view) {
            self.direct_reads += 1;
            return try self.store.readNodeById(allocator, id);
        }
        if (self.node_view == null) self.node_view = try self.store.openNodeRecordView();
        return try self.node_view.?.readNodeById(allocator, id);
    }

    fn matchNode(self: *PersistentNodeCursorState, id: core.NodeId, kind_filter: ?core.NodeKind, text_eq: ?[]const u8) !?bool {
        return self.matchNodeFilter(id, schema.NodeTypeFilter.fromOptionalKind(kind_filter), text_eq);
    }

    fn matchNodeFilter(self: *PersistentNodeCursorState, id: core.NodeId, type_filter: schema.NodeTypeFilter, text_eq: ?[]const u8) !?bool {
        if (!try nodeCursorStoreNodeIsCurrentGeneration(self.store, self.edge_retention_registry, id)) return false;
        if (text_eq == null) {
            if (self.node_id_view == null) self.node_id_view = try self.store.openNodeByIdIndexView();
            const kind = (try self.node_id_view.?.nodeKind(id)) orelse return null;
            if (!type_filter.matches(kind)) return false;
            return true;
        }
        if (self.node_view == null) self.node_view = try self.store.openNodeRecordView();
        var node = (try self.node_view.?.readNodeById(self.store.allocator, id)) orelse return null;
        defer node.deinit(self.store.allocator);
        if (!type_filter.matches(node.kind)) return false;
        return visibleNodeTextEquals(node.text, text_eq.?);
    }

    fn lookupByText(self: *PersistentNodeCursorState, allocator: std.mem.Allocator, kind_filter: ?core.NodeKind, text: []const u8, max_ids: usize) !std.ArrayList(core.NodeId) {
        if (self.node_text_lookup_view == null) {
            self.node_text_lookup_view = if (self.node_text_retention_registry) |registry|
                try self.store.openNodeTextLookupViewRetained(allocator, registry)
            else
                try self.store.openNodeTextLookupView(allocator);
        }
        return try self.node_text_lookup_view.?.lookupIds(allocator, kind_filter, text, max_ids);
    }
};

pub const PersistentStoreQuerySession = struct {
    allocator: std.mem.Allocator,
    store: storage.Store,
    edge_retention_registry: storage.EdgeSegmentRetentionRegistry,
    node_text_retention_registry: storage.NodeTextRunRetentionRegistry,
    node_state: PersistentNodeCursorState,
    read_timestamp_ns: u64 = 0,

    pub fn init(allocator: std.mem.Allocator, store: storage.Store) PersistentStoreQuerySession {
        return .{
            .allocator = allocator,
            .store = store,
            .edge_retention_registry = storage.EdgeSegmentRetentionRegistry.init(allocator),
            .node_text_retention_registry = storage.NodeTextRunRetentionRegistry.init(allocator),
            .node_state = .{ .store = store },
        };
    }

    pub fn deinit(self: *PersistentStoreQuerySession) void {
        self.node_state.deinit();
        self.node_text_retention_registry.deinit();
        self.edge_retention_registry.deinit();
    }

    pub fn execute(
        self: *PersistentStoreQuerySession,
        io: std.Io,
        plan: optimizer.PhysicalPlan,
        budget: core.QueryBudget,
    ) !ResultTable {
        self.read_timestamp_ns = currentStoreReadTimestampNs(self.store);
        var repaired = false;
        while (true) {
            self.bindNodeState();
            return executeWithCursorDeadline(
                self.allocator,
                .{ .store = .{ .allocator = self.allocator, .store = self.store, .state = &self.node_state } },
                .{ .persistent_store = .{ .allocator = self.allocator, .store = self.store, .edge_retention_registry = &self.edge_retention_registry } },
                plan,
                budget,
                core.QueryDeadline.fromIo(io, budget.timeout_ms),
                null,
            ) catch |err| switch (err) {
                error.FileNotFound, error.InvalidRecord => {
                    if (repaired) return err;
                    repaired = true;
                    self.node_state.deinit();
                    self.resetNodeState();
                    try self.store.repairPersistentIndexesFromLog();
                    continue;
                },
                else => |e| return e,
            };
        }
    }

    pub fn edgeRetentionRegistry(self: *PersistentStoreQuerySession) *storage.EdgeSegmentRetentionRegistry {
        return &self.edge_retention_registry;
    }

    fn bindNodeState(self: *PersistentStoreQuerySession) void {
        self.node_state.store = self.store;
        self.node_state.edge_retention_registry = &self.edge_retention_registry;
        self.node_state.node_text_retention_registry = &self.node_text_retention_registry;
        self.node_state.read_timestamp_ns = self.read_timestamp_ns;
    }

    fn resetNodeState(self: *PersistentStoreQuerySession) void {
        self.node_state = .{
            .store = self.store,
            .edge_retention_registry = &self.edge_retention_registry,
            .node_text_retention_registry = &self.node_text_retention_registry,
            .read_timestamp_ns = self.read_timestamp_ns,
        };
    }
};

pub fn execute(allocator: std.mem.Allocator, graph: *const graph_mod.Graph, plan: optimizer.PhysicalPlan) !ResultTable {
    return executeWithBudget(allocator, graph, plan, .{});
}

pub fn executeWithBudget(allocator: std.mem.Allocator, graph: *const graph_mod.Graph, plan: optimizer.PhysicalPlan, budget: @import("../core.zig").QueryBudget) !ResultTable {
    var mem_index = try index.MemoryIndex.init(allocator, graph);
    defer mem_index.deinit();
    return executeWithIndex(allocator, graph, &mem_index, plan, budget);
}

pub fn executeWithIndex(
    allocator: std.mem.Allocator,
    graph: *const graph_mod.Graph,
    mem_index: *index.MemoryIndex,
    plan: optimizer.PhysicalPlan,
    budget: @import("../core.zig").QueryBudget,
) !ResultTable {
    return executeWithIndexDeadline(allocator, graph, mem_index, plan, budget, core.QueryDeadline.immediateOrNone(budget.timeout_ms));
}

pub fn executeWithIndexAndIo(
    allocator: std.mem.Allocator,
    io: std.Io,
    graph: *const graph_mod.Graph,
    mem_index: *index.MemoryIndex,
    plan: optimizer.PhysicalPlan,
    budget: @import("../core.zig").QueryBudget,
) !ResultTable {
    return executeWithIndexDeadline(allocator, graph, mem_index, plan, budget, core.QueryDeadline.fromIo(io, budget.timeout_ms));
}

pub fn executeWithStoreAndIo(
    allocator: std.mem.Allocator,
    io: std.Io,
    store: storage.Store,
    graph: *const graph_mod.Graph,
    mem_index: *index.MemoryIndex,
    plan: optimizer.PhysicalPlan,
    budget: @import("../core.zig").QueryBudget,
) !ResultTable {
    return executeWithCursorDeadline(
        allocator,
        .{ .memory = .{ .graph = graph, .mem_index = mem_index } },
        .{ .store = .{ .allocator = allocator, .store = store, .graph = graph } },
        plan,
        budget,
        core.QueryDeadline.fromIo(io, budget.timeout_ms),
        null,
    );
}

pub fn executeWithPersistentStoreAndIo(
    allocator: std.mem.Allocator,
    io: std.Io,
    store: storage.Store,
    plan: optimizer.PhysicalPlan,
    budget: @import("../core.zig").QueryBudget,
) !ResultTable {
    return executeWithPersistentStoreAndIoMaybeRetained(allocator, io, store, null, plan, budget);
}

pub fn executeWithPersistentStoreAndIoRetained(
    allocator: std.mem.Allocator,
    io: std.Io,
    store: storage.Store,
    edge_retention_registry: *storage.EdgeSegmentRetentionRegistry,
    plan: optimizer.PhysicalPlan,
    budget: @import("../core.zig").QueryBudget,
) !ResultTable {
    return executeWithPersistentStoreAndIoMaybeRetained(allocator, io, store, edge_retention_registry, plan, budget);
}

pub fn executeWithPersistentStoreAndIoRetainedIndexes(
    allocator: std.mem.Allocator,
    io: std.Io,
    store: storage.Store,
    edge_retention_registry: *storage.EdgeSegmentRetentionRegistry,
    node_text_retention_registry: *storage.NodeTextRunRetentionRegistry,
    plan: optimizer.PhysicalPlan,
    budget: @import("../core.zig").QueryBudget,
) !ResultTable {
    return executeWithPersistentStoreAndIoMaybeRetainedIndexes(allocator, io, store, edge_retention_registry, node_text_retention_registry, plan, budget);
}

pub fn executeWithPersistentStoreAndIoRetainedIndexesExplain(
    allocator: std.mem.Allocator,
    io: std.Io,
    store: storage.Store,
    edge_retention_registry: ?*storage.EdgeSegmentRetentionRegistry,
    node_text_retention_registry: ?*storage.NodeTextRunRetentionRegistry,
    plan: optimizer.PhysicalPlan,
    budget: @import("../core.zig").QueryBudget,
    timings: *OperatorTimingRecorder,
) !ResultTable {
    return executeWithPersistentStoreAndIoMaybeRetainedIndexesTimed(allocator, io, store, edge_retention_registry, node_text_retention_registry, plan, budget, timings);
}

fn executeWithPersistentStoreAndIoMaybeRetained(
    allocator: std.mem.Allocator,
    io: std.Io,
    store: storage.Store,
    edge_retention_registry: ?*storage.EdgeSegmentRetentionRegistry,
    plan: optimizer.PhysicalPlan,
    budget: @import("../core.zig").QueryBudget,
) !ResultTable {
    return executeWithPersistentStoreAndIoMaybeRetainedIndexes(allocator, io, store, edge_retention_registry, null, plan, budget);
}

fn executeWithPersistentStoreAndIoMaybeRetainedIndexes(
    allocator: std.mem.Allocator,
    io: std.Io,
    store: storage.Store,
    edge_retention_registry: ?*storage.EdgeSegmentRetentionRegistry,
    node_text_retention_registry: ?*storage.NodeTextRunRetentionRegistry,
    plan: optimizer.PhysicalPlan,
    budget: @import("../core.zig").QueryBudget,
) !ResultTable {
    return executeWithPersistentStoreAndIoMaybeRetainedIndexesTimed(allocator, io, store, edge_retention_registry, node_text_retention_registry, plan, budget, null);
}

fn executeWithPersistentStoreAndIoMaybeRetainedIndexesTimed(
    allocator: std.mem.Allocator,
    io: std.Io,
    store: storage.Store,
    edge_retention_registry: ?*storage.EdgeSegmentRetentionRegistry,
    node_text_retention_registry: ?*storage.NodeTextRunRetentionRegistry,
    plan: optimizer.PhysicalPlan,
    budget: @import("../core.zig").QueryBudget,
    timings: ?*OperatorTimingRecorder,
) !ResultTable {
    if (timings) |recorder| try recorder.ensureCapacityForPlan(plan);
    const read_timestamp_ns = currentStoreReadTimestampNs(store);
    var repaired = false;
    while (true) {
        if (timings) |recorder| recorder.clearRetainingCapacity();
        var node_state = PersistentNodeCursorState{
            .store = store,
            .edge_retention_registry = edge_retention_registry,
            .node_text_retention_registry = node_text_retention_registry,
            .read_timestamp_ns = read_timestamp_ns,
        };
        defer node_state.deinit();
        return executeWithCursorDeadline(
            allocator,
            .{ .store = .{ .allocator = allocator, .store = store, .state = &node_state } },
            .{ .persistent_store = .{ .allocator = allocator, .store = store, .edge_retention_registry = edge_retention_registry } },
            plan,
            budget,
            core.QueryDeadline.fromIo(io, budget.timeout_ms),
            timings,
        ) catch |err| switch (err) {
            error.FileNotFound, error.InvalidRecord => {
                if (repaired) return err;
                repaired = true;
                try store.repairPersistentIndexesFromLog();
                continue;
            },
            else => |e| return e,
        };
    }
}

fn executeWithIndexDeadline(
    allocator: std.mem.Allocator,
    graph: *const graph_mod.Graph,
    mem_index: *index.MemoryIndex,
    plan: optimizer.PhysicalPlan,
    budget: @import("../core.zig").QueryBudget,
    deadline: core.QueryDeadline,
) !ResultTable {
    return executeWithCursorDeadline(
        allocator,
        .{ .memory = .{ .graph = graph, .mem_index = mem_index } },
        .{ .memory = .{ .mem_index = mem_index } },
        plan,
        budget,
        deadline,
        null,
    );
}

fn executeWithCursorDeadline(
    allocator: std.mem.Allocator,
    node_cursor: NodeCursor,
    edge_cursor: query_mod.EdgeCursor,
    plan: optimizer.PhysicalPlan,
    budget: @import("../core.zig").QueryBudget,
    deadline: core.QueryDeadline,
    timings: ?*OperatorTimingRecorder,
) !ResultTable {
    var table = ResultTable.init();
    table.read_timestamp_ns = switch (node_cursor) {
        .memory => null,
        .store => |cursor| if (cursor.state) |state| state.read_timestamp_ns else currentStoreReadTimestampNs(cursor.store),
    };
    errdefer table.deinit(allocator);
    const limit: ?usize = effectiveLimit(plan, budget);
    if (limit != null and limit.? == 0) return table;
    if (deadline.expired()) {
        table.stats.budget_exceeded = true;
        return table;
    }
    const store_scores = shouldStoreScores(plan);

    for (plan.ops.items, 0..) |op, op_index| {
        const can_apply_result_limit = !hasLaterExpandOrBlockingOrder(plan, op_index, op);
        const timing_start_ns = if (timings) |recorder| recorder.nowNs() else 0;
        const timing_input_rows = table.rows.items.len;
        const timing_input_nodes = table.stats.nodes_visited;
        const timing_input_edges = table.stats.edges_visited;
        defer if (timings) |recorder| {
            const timing_end_ns = recorder.nowNs();
            recorder.recordAssumeCapacity(.{
                .op_index = op_index,
                .op_name = physicalOpName(op),
                .elapsed_ns = if (timing_end_ns >= timing_start_ns) timing_end_ns - timing_start_ns else 0,
                .input_rows = timing_input_rows,
                .output_rows = table.rows.items.len,
                .nodes_visited_delta = table.stats.nodes_visited -| timing_input_nodes,
                .edges_visited_delta = table.stats.edges_visited -| timing_input_edges,
                .budget_exceeded = table.stats.budget_exceeded,
            });
        };
        switch (op) {
            .text_search => |text_search| {
                if (nodeBudgetExhausted(&table, budget)) break;
                const can_cap_text_candidates = can_apply_result_limit and text_search.text_eq == null;
                const text_limit = if (can_cap_text_candidates) (limit orelse text_search.limit) else null;
                const text_type_filter = effectiveNodeTypeFilter(text_search.kind, text_search.type_filter);
                const maybe_hits: ?std.ArrayList(text_mod.TextSearchHit) = node_cursor.searchText(allocator, text_search.query, text_type_filter, seedCap(can_cap_text_candidates, text_limit, budget), budget.max_text_postings_scanned, deadline) catch |err| switch (err) {
                    core.Error.BudgetExceeded => blk: {
                        table.stats.budget_exceeded = true;
                        break :blk null;
                    },
                    else => |e| return e,
                };
                var hits = maybe_hits orelse continue;
                defer hits.deinit(allocator);
                try reserveSeedRows(allocator, &table, hits.items.len, can_apply_result_limit, limit);
                for (hits.items) |hit| {
                    if (deadline.expired()) {
                        table.stats.budget_exceeded = true;
                        break;
                    }
                    if (can_apply_result_limit) if (limit) |max| {
                        if (table.rows.items.len >= max) break;
                    };
                    if (table.stats.nodes_visited >= budget.max_visited_nodes) {
                        table.stats.budget_exceeded = true;
                        break;
                    }
                    try index.addVisitedNodes(&table.stats, 1);
                    if (text_search.text_eq) |text| {
                        const matches = (try node_cursor.matchNodeFilter(allocator, hit.node_id, text_type_filter, text)) orelse {
                            try missingCandidateNode(node_cursor);
                            continue;
                        };
                        if (!matches) continue;
                    }
                    var row = if (store_scores)
                        try Row.initBindingScore(allocator, text_search.var_name, hit.node_id, hit.score)
                    else
                        try Row.initBinding(allocator, text_search.var_name, hit.node_id);
                    var row_owned = true;
                    errdefer if (row_owned) row.deinit(allocator);
                    try table.rows.append(allocator, row);
                    row_owned = false;
                    table.stats.results = table.rows.items.len;
                }
            },
            .node_lookup_by_text => |lookup| {
                if (nodeBudgetExhausted(&table, budget)) break;
                const lookup_type_filter = effectiveNodeTypeFilter(lookup.kind, lookup.type_filter);
                var node_ids = try node_cursor.lookupByTextFilter(allocator, lookup_type_filter, lookup.text, seedCap(can_apply_result_limit, limit, budget));
                defer node_ids.deinit(allocator);
                try reserveSeedRows(allocator, &table, node_ids.items.len, can_apply_result_limit, limit);
                for (node_ids.items) |node_id| {
                    if (deadline.expired()) {
                        table.stats.budget_exceeded = true;
                        break;
                    }
                    if (can_apply_result_limit) if (limit) |max| {
                        if (table.rows.items.len >= max) break;
                    };
                    if (table.stats.nodes_visited >= budget.max_visited_nodes) {
                        table.stats.budget_exceeded = true;
                        break;
                    }
                    try index.addVisitedNodes(&table.stats, 1);
                    if (lookup.property_eq) |property_eq| {
                        const matches = (try node_cursor.matchStringProperty(allocator, node_id, property_eq)) orelse {
                            try missingCandidateNode(node_cursor);
                            continue;
                        };
                        if (!matches) continue;
                    }
                    var row = try Row.initBinding(allocator, lookup.var_name, node_id);
                    var row_owned = true;
                    errdefer if (row_owned) row.deinit(allocator);
                    try table.rows.append(allocator, row);
                    row_owned = false;
                    table.stats.results = table.rows.items.len;
                }
            },
            .node_lookup_by_property => |lookup| {
                if (nodeBudgetExhausted(&table, budget)) break;
                const lookup_type_filter = effectiveNodeTypeFilter(lookup.kind, lookup.type_filter);
                var node_ids = try node_cursor.lookupByPropertyFilter(allocator, lookup_type_filter, lookup.property_eq, seedCap(can_apply_result_limit, limit, budget));
                defer node_ids.deinit(allocator);
                try reserveSeedRows(allocator, &table, node_ids.items.len, can_apply_result_limit, limit);
                for (node_ids.items) |node_id| {
                    if (deadline.expired()) {
                        table.stats.budget_exceeded = true;
                        break;
                    }
                    if (can_apply_result_limit) if (limit) |max| {
                        if (table.rows.items.len >= max) break;
                    };
                    if (table.stats.nodes_visited >= budget.max_visited_nodes) {
                        table.stats.budget_exceeded = true;
                        break;
                    }
                    try index.addVisitedNodes(&table.stats, 1);
                    var row = try Row.initBinding(allocator, lookup.var_name, node_id);
                    var row_owned = true;
                    errdefer if (row_owned) row.deinit(allocator);
                    try table.rows.append(allocator, row);
                    row_owned = false;
                    table.stats.results = table.rows.items.len;
                }
            },
            .node_scan => |scan| {
                if (nodeBudgetExhausted(&table, budget)) break;
                const can_cap_scan_candidates = can_apply_result_limit and scan.text_eq == null;
                const scan_type_filter = effectiveNodeTypeFilter(scan.kind, scan.type_filter);
                var node_ids = try node_cursor.scanFilter(allocator, scan_type_filter, seedCap(can_cap_scan_candidates, if (can_cap_scan_candidates) limit else null, budget));
                defer node_ids.deinit(allocator);
                try reserveSeedRows(allocator, &table, node_ids.items.len, can_apply_result_limit, limit);
                for (node_ids.items) |node_id| {
                    if (deadline.expired()) {
                        table.stats.budget_exceeded = true;
                        break;
                    }
                    if (can_apply_result_limit) if (limit) |max| {
                        if (table.rows.items.len >= max) break;
                    };
                    if (table.stats.nodes_visited >= budget.max_visited_nodes) {
                        table.stats.budget_exceeded = true;
                        break;
                    }
                    try index.addVisitedNodes(&table.stats, 1);
                    if (scan.text_eq) |text| {
                        const matches = (try node_cursor.matchNodeFilter(allocator, node_id, scan_type_filter, text)) orelse {
                            try missingCandidateNode(node_cursor);
                            continue;
                        };
                        if (!matches) continue;
                    }
                    if (scan.property_eq) |property_eq| {
                        const matches = (try node_cursor.matchStringProperty(allocator, node_id, property_eq)) orelse {
                            try missingCandidateNode(node_cursor);
                            continue;
                        };
                        if (!matches) continue;
                    }
                    var row = try Row.initBinding(allocator, scan.var_name, node_id);
                    var row_owned = true;
                    errdefer if (row_owned) row.deinit(allocator);
                    try table.rows.append(allocator, row);
                    row_owned = false;
                    table.stats.results = table.rows.items.len;
                }
            },
            .expand => |expand| {
                var next = ResultTable.init();
                next.stats = table.stats;
                next.read_timestamp_ns = table.read_timestamp_ns;
                errdefer next.deinit(allocator);
                try reserveExpandRows(allocator, &next, can_apply_result_limit, limit);
                var edge_property_candidate_ids = if (expand.edge_property_eq) |property_eq|
                    try lookupEdgeIdsByProperty(edge_cursor, allocator, property_eq)
                else
                    std.ArrayList(core.EdgeId).empty;
                defer edge_property_candidate_ids.deinit(allocator);
                const edge_property_filter: ?[]const core.EdgeId = if (expand.edge_property_eq != null)
                    edge_property_candidate_ids.items
                else
                    null;
                const store_paths = shouldStoreExpandPath(plan, expand);
                const left_binding_index = commonBindingIndex(table.rows.items, expand.left_var);
                const right_var_absent = !anyRowHasBinding(table.rows.items, expand.right_var);
                for (table.rows.items) |row| {
                    if (can_apply_result_limit) if (limit) |max| {
                        if (next.rows.items.len >= max) break;
                    };
                    const left_id = execution_result_internal.rowGetAt(row, left_binding_index, expand.left_var) orelse continue;
                    const limit_reached = try expandFromRow(allocator, node_cursor, edge_cursor, row, expand, left_id, &next, if (can_apply_result_limit) limit else null, budget, deadline, store_paths, right_var_absent, store_scores, edge_property_filter);
                    if (limit_reached) break;
                }
                next.stats.results = next.rows.items.len;
                table.deinit(allocator);
                table = next;
            },
            .order_by => |order_by| try sortResultTableByOrder(allocator, node_cursor, &table, order_by),
            .project => {},
            .limit => |max| {
                if (table.rows.items.len > max) {
                    var i: usize = max;
                    while (i < table.rows.items.len) : (i += 1) {
                        table.rows.items[i].deinit(allocator);
                    }
                    table.rows.shrinkRetainingCapacity(max);
                }
                table.stats.results = table.rows.items.len;
            },
        }
    }
    return table;
}

fn nodeBudgetExhausted(table: *ResultTable, budget: core.QueryBudget) bool {
    if (table.stats.nodes_visited < budget.max_visited_nodes) return false;
    table.stats.budget_exceeded = true;
    return true;
}

fn effectiveLimit(plan: optimizer.PhysicalPlan, budget: core.QueryBudget) ?usize {
    var out: ?usize = budget.max_results;
    for (plan.ops.items) |op| {
        if (op == .limit) {
            out = if (out) |current| @min(current, op.limit) else op.limit;
        }
    }
    return out;
}

fn seedCap(can_apply_result_limit: bool, limit: ?usize, budget: core.QueryBudget) usize {
    if (!can_apply_result_limit) return std.math.add(usize, budget.max_visited_nodes, 1) catch std.math.maxInt(usize);
    const by_results = limit orelse budget.max_results;
    if (budget.max_visited_nodes < by_results) {
        const sentinel_cap = std.math.add(usize, budget.max_visited_nodes, 1) catch std.math.maxInt(usize);
        return @min(by_results, sentinel_cap);
    }
    return by_results;
}

fn reserveSeedRows(allocator: std.mem.Allocator, table: *ResultTable, candidate_count: usize, can_apply_result_limit: bool, limit: ?usize) !void {
    if (candidate_count == 0) return;
    var reserve_count = candidate_count;
    if (can_apply_result_limit) if (limit) |max| {
        if (table.rows.items.len >= max) return;
        reserve_count = @min(reserve_count, max - table.rows.items.len);
    };
    try table.rows.ensureUnusedCapacity(allocator, reserve_count);
}

fn reserveExpandRows(allocator: std.mem.Allocator, table: *ResultTable, can_apply_result_limit: bool, limit: ?usize) !void {
    if (!can_apply_result_limit) return;
    const max = limit orelse return;
    if (table.rows.items.len >= max) return;
    try table.rows.ensureUnusedCapacity(allocator, max - table.rows.items.len);
}

const OrderByRowKey = struct {
    index: usize,
    has_value: bool,
    value: u64 = 0,
    node_id: core.NodeId = .none,
};

const OrderByRowKeyContext = struct {
    direction: ast.OrderDirection,
};

fn orderByRowKeyLessThan(ctx: OrderByRowKeyContext, lhs: OrderByRowKey, rhs: OrderByRowKey) bool {
    if (lhs.has_value != rhs.has_value) return lhs.has_value;
    if (lhs.has_value and lhs.value != rhs.value) {
        return switch (ctx.direction) {
            .asc => lhs.value < rhs.value,
            .desc => lhs.value > rhs.value,
        };
    }
    if (lhs.node_id.toInt() != rhs.node_id.toInt()) return lhs.node_id.toInt() < rhs.node_id.toInt();
    return lhs.index < rhs.index;
}

fn orderByValueForRow(node_cursor: NodeCursor, allocator: std.mem.Allocator, row: Row, order_by: ast.OrderBy) !OrderByRowKey {
    const node_id = row.get(order_by.var_name) orelse return .{ .index = 0, .has_value = false };
    const value = (try node_cursor.uintProperty(allocator, node_id, order_by.property)) orelse return .{ .index = 0, .has_value = false, .node_id = node_id };
    return .{ .index = 0, .has_value = true, .value = value, .node_id = node_id };
}

fn sortResultTableByOrder(allocator: std.mem.Allocator, node_cursor: NodeCursor, table: *ResultTable, order_by: ast.OrderBy) !void {
    if (table.rows.items.len <= 1) return;
    var keys = std.ArrayList(OrderByRowKey).empty;
    defer keys.deinit(allocator);
    try keys.ensureTotalCapacity(allocator, table.rows.items.len);
    for (table.rows.items, 0..) |row, index_pos| {
        var key = try orderByValueForRow(node_cursor, allocator, row, order_by);
        key.index = index_pos;
        keys.appendAssumeCapacity(key);
    }
    std.mem.sort(OrderByRowKey, keys.items, OrderByRowKeyContext{ .direction = order_by.direction }, orderByRowKeyLessThan);

    var ordered_rows = std.ArrayList(Row).empty;
    errdefer ordered_rows.deinit(allocator);
    try ordered_rows.ensureTotalCapacity(allocator, table.rows.items.len);
    for (keys.items) |key| {
        ordered_rows.appendAssumeCapacity(table.rows.items[key.index]);
    }
    var old_rows = table.rows;
    table.rows = ordered_rows;
    old_rows.deinit(allocator);
}

fn hasLaterExpand(plan: optimizer.PhysicalPlan, op_index: usize) bool {
    for (plan.ops.items[op_index + 1 ..]) |op| {
        if (op == .expand) return true;
    }
    return false;
}

fn hasLaterExpandOrBlockingOrder(plan: optimizer.PhysicalPlan, op_index: usize, op: optimizer.PhysicalOp) bool {
    if (hasLaterExpand(plan, op_index)) return true;
    const order_by = laterOrderBy(plan, op_index) orelse return false;
    return !opStreamSatisfiesOrder(op, order_by);
}

fn laterOrderBy(plan: optimizer.PhysicalPlan, op_index: usize) ?ast.OrderBy {
    for (plan.ops.items[op_index + 1 ..]) |op| {
        if (op == .order_by) return op.order_by;
    }
    return null;
}

fn opStreamSatisfiesOrder(op: optimizer.PhysicalOp, order_by: ast.OrderBy) bool {
    if (order_by.direction != .asc) return false;
    return switch (op) {
        .node_lookup_by_property => |lookup| std.mem.eql(u8, lookup.var_name, order_by.var_name) and
            std.mem.eql(u8, lookup.property_eq.key, order_by.property) and
            nodeUintPropertySupported(order_by.property),
        else => false,
    };
}

fn shouldStoreExpandPath(plan: optimizer.PhysicalPlan, expand: planner.Expand) bool {
    var saw_project = false;
    for (plan.ops.items) |op| {
        switch (op) {
            .project => |projections| {
                saw_project = true;
                for (projections) |projection| {
                    switch (projection) {
                        .path => |path| {
                            if (std.mem.eql(u8, path.from_var, expand.left_var) and
                                std.mem.eql(u8, path.to_var, expand.right_var))
                            {
                                return true;
                            }
                        },
                        else => {},
                    }
                }
            },
            else => {},
        }
    }
    return !saw_project;
}

fn shouldStoreScores(plan: optimizer.PhysicalPlan) bool {
    var saw_project = false;
    for (plan.ops.items) |op| {
        switch (op) {
            .project => |projections| {
                saw_project = true;
                for (projections) |projection| {
                    if (projection == .score) return true;
                }
            },
            else => {},
        }
    }
    return !saw_project;
}

fn physicalOpName(op: optimizer.PhysicalOp) []const u8 {
    return switch (op) {
        .text_search => "text_search",
        .node_lookup_by_text => "node_lookup_by_text",
        .node_lookup_by_property => "node_lookup_by_property",
        .node_scan => "node_scan",
        .expand => "expand",
        .order_by => "order_by",
        .project => "project",
        .limit => "limit",
    };
}

fn commonBindingIndex(rows: []const Row, name: []const u8) ?usize {
    if (rows.len == 0) return null;
    for (rows[0].bindings.items, 0..) |binding, index_pos| {
        if (!std.mem.eql(u8, binding.name, name)) continue;
        for (rows[1..]) |row| {
            if (index_pos >= row.bindings.items.len) return null;
            if (!std.mem.eql(u8, row.bindings.items[index_pos].name, name)) return null;
        }
        return index_pos;
    }
    return null;
}

fn anyRowHasBinding(rows: []const Row, name: []const u8) bool {
    for (rows) |row| {
        if (row.get(name) != null) return true;
    }
    return false;
}

fn expandFromRow(
    allocator: std.mem.Allocator,
    node_cursor: NodeCursor,
    edge_cursor: query_mod.EdgeCursor,
    row: Row,
    expand: planner.Expand,
    left_id: @import("../core.zig").NodeId,
    next: *ResultTable,
    limit: ?usize,
    budget: @import("../core.zig").QueryBudget,
    deadline: core.QueryDeadline,
    store_paths: bool,
    right_var_absent: bool,
    store_scores: bool,
    edge_property_candidate_ids: ?[]const core.EdgeId,
) !bool {
    const max_hops = @min(expand.max_hops, budget.max_depth);
    if (max_hops < expand.min_hops) {
        next.stats.budget_exceeded = true;
        return false;
    }
    if (max_hops == 1) {
        var initial_nodes = [_]core.NodeId{left_id};
        const current = FrontierItem{ .id = left_id, .depth = 0, .nodes = initial_nodes[0..] };
        if (expand.direction == .outgoing or expand.direction == .undirected) {
            var ctx = ExpandEdgeContext{
                .allocator = allocator,
                .node_cursor = node_cursor,
                .edge_cursor = edge_cursor,
                .row = row,
                .expand = expand,
                .current = current,
                .frontier = null,
                .next = next,
                .limit = limit,
                .budget = budget,
                .deadline = deadline,
                .direction = .outgoing,
                .max_hops = max_hops,
                .store_paths = store_paths,
                .right_var_absent = right_var_absent,
                .store_scores = store_scores,
                .edge_property_candidate_ids = edge_property_candidate_ids,
            };
            if (try forEachOutgoingRelationFilter(edge_cursor, current.id, effectiveRelationTypeFilter(expand.rel, expand.rel_filter), &ctx)) return true;
        }
        if (expand.direction == .incoming or expand.direction == .undirected) {
            var ctx = ExpandEdgeContext{
                .allocator = allocator,
                .node_cursor = node_cursor,
                .edge_cursor = edge_cursor,
                .row = row,
                .expand = expand,
                .current = current,
                .frontier = null,
                .next = next,
                .limit = limit,
                .budget = budget,
                .deadline = deadline,
                .direction = .incoming,
                .max_hops = max_hops,
                .store_paths = store_paths,
                .right_var_absent = right_var_absent,
                .store_scores = store_scores,
                .edge_property_candidate_ids = edge_property_candidate_ids,
            };
            if (try forEachIncomingRelationFilter(edge_cursor, current.id, effectiveRelationTypeFilter(expand.rel, expand.rel_filter), &ctx)) return true;
        }
        return false;
    }
    var frontier = std.ArrayList(FrontierItem).empty;
    defer {
        for (frontier.items) |item| allocator.free(item.nodes);
        frontier.deinit(allocator);
    }
    const initial_path = try allocator.dupe(core.NodeId, &.{left_id});
    var initial_path_owned = true;
    errdefer if (initial_path_owned) allocator.free(initial_path);
    try frontier.append(allocator, .{ .id = left_id, .depth = 0, .nodes = initial_path });
    initial_path_owned = false;
    var pos: usize = 0;
    while (pos < frontier.items.len) : (pos += 1) {
        const current = frontier.items[pos];
        if (deadline.expired()) {
            next.stats.budget_exceeded = true;
            return false;
        }
        if (current.depth >= max_hops) continue;
        if (expand.direction == .outgoing or expand.direction == .undirected) {
            var ctx = ExpandEdgeContext{
                .allocator = allocator,
                .node_cursor = node_cursor,
                .edge_cursor = edge_cursor,
                .row = row,
                .expand = expand,
                .current = current,
                .frontier = &frontier,
                .next = next,
                .limit = limit,
                .budget = budget,
                .deadline = deadline,
                .direction = .outgoing,
                .max_hops = max_hops,
                .store_paths = store_paths,
                .right_var_absent = right_var_absent,
                .store_scores = store_scores,
                .edge_property_candidate_ids = edge_property_candidate_ids,
            };
            if (try forEachOutgoingRelationFilter(edge_cursor, current.id, effectiveRelationTypeFilter(expand.rel, expand.rel_filter), &ctx)) return true;
        }
        if (expand.direction == .incoming or expand.direction == .undirected) {
            var ctx = ExpandEdgeContext{
                .allocator = allocator,
                .node_cursor = node_cursor,
                .edge_cursor = edge_cursor,
                .row = row,
                .expand = expand,
                .current = current,
                .frontier = &frontier,
                .next = next,
                .limit = limit,
                .budget = budget,
                .deadline = deadline,
                .direction = .incoming,
                .max_hops = max_hops,
                .store_paths = store_paths,
                .right_var_absent = right_var_absent,
                .store_scores = store_scores,
                .edge_property_candidate_ids = edge_property_candidate_ids,
            };
            if (try forEachIncomingRelationFilter(edge_cursor, current.id, effectiveRelationTypeFilter(expand.rel, expand.rel_filter), &ctx)) return true;
        }
    }
    return false;
}

const FrontierItem = struct { id: core.NodeId, depth: u8, nodes: []core.NodeId };

const ExpandEdgeContext = struct {
    allocator: std.mem.Allocator,
    node_cursor: NodeCursor,
    edge_cursor: query_mod.EdgeCursor,
    row: Row,
    expand: planner.Expand,
    current: FrontierItem,
    frontier: ?*std.ArrayList(FrontierItem),
    next: *ResultTable,
    limit: ?usize,
    budget: core.QueryBudget,
    deadline: core.QueryDeadline,
    direction: ast.EdgeDirection,
    max_hops: u8,
    store_paths: bool,
    right_var_absent: bool,
    store_scores: bool,
    edge_property_candidate_ids: ?[]const core.EdgeId,
};

fn forEachOutgoingRelationFilter(edge_cursor: query_mod.EdgeCursor, node_id: core.NodeId, rel_filter: schema.RelationTypeFilter, ctx: *ExpandEdgeContext) !bool {
    if (rel_filter.asSingle()) |rel| return try edge_cursor.forEachOutgoingRelation(node_id, rel, ctx, expandEdgeCallback);
    if (relationFilterIsAny(rel_filter)) return try edge_cursor.forEachOutgoingRelation(node_id, null, ctx, expandEdgeCallback);
    return try forEachRelationSet(edge_cursor, .outgoing, node_id, rel_filter, ctx);
}

fn forEachIncomingRelationFilter(edge_cursor: query_mod.EdgeCursor, node_id: core.NodeId, rel_filter: schema.RelationTypeFilter, ctx: *ExpandEdgeContext) !bool {
    if (rel_filter.asSingle()) |rel| return try edge_cursor.forEachIncomingRelation(node_id, rel, ctx, expandEdgeCallback);
    if (relationFilterIsAny(rel_filter)) return try edge_cursor.forEachIncomingRelation(node_id, null, ctx, expandEdgeCallback);
    return try forEachRelationSet(edge_cursor, .incoming, node_id, rel_filter, ctx);
}

fn forEachRelationSet(edge_cursor: query_mod.EdgeCursor, direction: ast.EdgeDirection, node_id: core.NodeId, rel_filter: schema.RelationTypeFilter, ctx: *ExpandEdgeContext) !bool {
    for (0..schema.max_relation_types) |raw_id| {
        const rel: core.RelKind = @enumFromInt(@as(u16, @intCast(raw_id)));
        if (!rel_filter.matches(rel)) continue;
        const stopped = switch (direction) {
            .outgoing => try edge_cursor.forEachOutgoingRelation(node_id, rel, ctx, expandEdgeCallback),
            .incoming => try edge_cursor.forEachIncomingRelation(node_id, rel, ctx, expandEdgeCallback),
            .undirected => return core.Error.Unsupported,
        };
        if (stopped) return true;
    }
    return false;
}

fn expandEdgeCallback(ctx: *ExpandEdgeContext, edge: index.EdgeRef) !bool {
    if (ctx.expand.direction == .undirected and ctx.direction == .incoming and edge.src.toInt() == edge.dst.toInt()) {
        return false;
    }
    if (ctx.deadline.expired()) {
        ctx.next.stats.budget_exceeded = true;
        return true;
    }
    if (ctx.next.stats.edges_visited >= ctx.budget.max_visited_edges) {
        ctx.next.stats.budget_exceeded = true;
        return true;
    }
    try index.addVisitedEdges(&ctx.next.stats, 1);
    if (ctx.expand.edge_property_eq) |property_eq| {
        if (ctx.edge_property_candidate_ids) |candidate_ids| {
            if (!edgeIdSliceContains(candidate_ids, edge.edge_id)) return false;
        } else if (!try edgeCursorMatchesStringProperty(ctx.edge_cursor, ctx.allocator, edge.edge_id, property_eq)) return false;
    }
    const next_id = switch (ctx.direction) {
        .outgoing => edge.dst,
        .incoming => edge.src,
        .undirected => return core.Error.Unsupported,
    };
    if (ctx.expand.max_hops > 1 and pathContains(ctx.current.nodes, next_id)) return false;
    const depth = ctx.current.depth + 1;
    if (ctx.next.stats.nodes_visited >= ctx.budget.max_visited_nodes) {
        ctx.next.stats.budget_exceeded = true;
        return true;
    }
    const can_return_at_depth = depth >= ctx.expand.min_hops;
    const match_type_filter = if (can_return_at_depth) effectiveNodeTypeFilter(ctx.expand.right_kind, ctx.expand.right_type_filter) else schema.NodeTypeFilter.any;
    const match_text = if (can_return_at_depth) ctx.expand.right_text_eq else null;
    const node_matches = (try ctx.node_cursor.matchNodeFilter(ctx.allocator, next_id, match_type_filter, match_text)) orelse return missingExpansionTarget(ctx.node_cursor);
    try index.addVisitedNodes(&ctx.next.stats, 1);
    var next_path_buf: [max_tinyql_expand_path_nodes]core.NodeId = undefined;
    var next_path: ?[]core.NodeId = null;
    if (depth < ctx.max_hops or ctx.store_paths) {
        const next_len = ctx.current.nodes.len + 1;
        if (next_len > next_path_buf.len) return error.RecordTooLarge;
        const path = next_path_buf[0..next_len];
        @memcpy(path[0..ctx.current.nodes.len], ctx.current.nodes);
        path[ctx.current.nodes.len] = next_id;
        next_path = path;
    }
    if (depth < ctx.max_hops) {
        const owned_path = try ctx.allocator.dupe(core.NodeId, next_path.?);
        var owned_path_transferred = false;
        errdefer if (!owned_path_transferred) ctx.allocator.free(owned_path);
        try ctx.frontier.?.append(ctx.allocator, .{
            .id = next_id,
            .depth = depth,
            .nodes = owned_path,
        });
        owned_path_transferred = true;
    } else if (depth < ctx.expand.max_hops) {
        ctx.next.stats.budget_exceeded = true;
    }
    if (!can_return_at_depth) return false;
    if (!node_matches) return false;
    var new_row = if (ctx.right_var_absent)
        try execution_result_internal.rowCloneAppendingBinding(ctx.row, ctx.allocator, ctx.expand.right_var, next_id, ctx.store_scores)
    else
        (try execution_result_internal.rowCloneWithBindingAndScores(ctx.row, ctx.allocator, ctx.expand.right_var, next_id, ctx.store_scores)) orelse return false;
    errdefer new_row.deinit(ctx.allocator);
    if (ctx.expand.edge_var) |edge_var| {
        if (!try new_row.putEdge(ctx.allocator, edge_var, edge.edge_id)) return false;
    }
    if (ctx.store_paths) try new_row.putPath(ctx.allocator, ctx.expand.left_var, ctx.expand.right_var, next_path.?);
    try ctx.next.rows.append(ctx.allocator, new_row);
    ctx.next.stats.results = ctx.next.rows.items.len;
    if (ctx.limit) |max| {
        if (ctx.next.rows.items.len >= max) return true;
    }
    return false;
}

fn missingExpansionTarget(node_cursor: NodeCursor) anyerror!bool {
    return switch (node_cursor) {
        .memory => false,
        .store => error.InvalidRecord,
    };
}

const max_tinyql_expand_path_nodes: usize = @as(usize, std.math.maxInt(u8)) + 1;

fn missingCandidateNode(node_cursor: NodeCursor) anyerror!void {
    return switch (node_cursor) {
        .memory => {},
        .store => error.InvalidRecord,
    };
}

fn pathContains(nodes: []const core.NodeId, id: core.NodeId) bool {
    for (nodes) |node| {
        if (node.toInt() == id.toInt()) return true;
    }
    return false;
}

test "seed row reservation respects result limit remainder" {
    var table = ResultTable.init();
    defer table.deinit(std.testing.allocator);

    try reserveSeedRows(std.testing.allocator, &table, 0, true, 4);
    try std.testing.expectEqual(@as(usize, 0), table.rows.capacity);

    try reserveSeedRows(std.testing.allocator, &table, 8, true, 3);
    try std.testing.expect(table.rows.capacity >= 3);

    var row = try Row.initBinding(std.testing.allocator, "n", .fromInt(1));
    var row_owned = true;
    errdefer if (row_owned) row.deinit(std.testing.allocator);
    try table.rows.append(std.testing.allocator, row);
    row_owned = false;

    const before = table.rows.capacity;
    try reserveSeedRows(std.testing.allocator, &table, 8, true, 1);
    try std.testing.expectEqual(before, table.rows.capacity);
}

test "expand row reservation is bounded by effective result limit" {
    var table = ResultTable.init();
    defer table.deinit(std.testing.allocator);

    try reserveExpandRows(std.testing.allocator, &table, false, 4);
    try std.testing.expectEqual(@as(usize, 0), table.rows.capacity);

    try reserveExpandRows(std.testing.allocator, &table, true, 4);
    try std.testing.expect(table.rows.capacity >= 4);

    var row = try Row.initBinding(std.testing.allocator, "n", .fromInt(1));
    var row_owned = true;
    errdefer if (row_owned) row.deinit(std.testing.allocator);
    try table.rows.append(std.testing.allocator, row);
    row_owned = false;

    const before = table.rows.capacity;
    try reserveExpandRows(std.testing.allocator, &table, true, 1);
    try std.testing.expectEqual(before, table.rows.capacity);
}

test "executor detects common binding slot for factorized expand input" {
    var first = try Row.initBinding(std.testing.allocator, "left", .fromInt(1));
    defer first.deinit(std.testing.allocator);
    try std.testing.expect(try first.put(std.testing.allocator, "other", .fromInt(9)));
    var second = try Row.initBinding(std.testing.allocator, "left", .fromInt(2));
    defer second.deinit(std.testing.allocator);
    try std.testing.expect(try second.put(std.testing.allocator, "other", .fromInt(10)));

    var rows = [_]Row{ first, second };
    try std.testing.expectEqual(@as(?usize, 0), commonBindingIndex(&rows, "left"));
    try std.testing.expectEqual(@as(u64, 2), execution_result_internal.rowGetAt(rows[1], commonBindingIndex(&rows, "left"), "left").?.toInt());
    try std.testing.expect(!anyRowHasBinding(&rows, "missing"));

    var mismatched = try Row.initBinding(std.testing.allocator, "other", .fromInt(3));
    defer mismatched.deinit(std.testing.allocator);
    try std.testing.expect(try mismatched.put(std.testing.allocator, "left", .fromInt(4)));
    var mixed = [_]Row{ first, mismatched };
    try std.testing.expectEqual(@as(?usize, null), commonBindingIndex(&mixed, "left"));
    try std.testing.expectEqual(@as(u64, 4), execution_result_internal.rowGetAt(mixed[1], commonBindingIndex(&mixed, "left"), "left").?.toInt());
}

test "executor expands outgoing edge" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    const file = try graph.addNode(.file, "a.zig");
    const func = try graph.addNode(.function, "main");
    _ = try graph.addEdgeUnchecked(file, .defines, func);

    var ops = std.ArrayList(optimizer.PhysicalOp).empty;
    defer ops.deinit(std.testing.allocator);
    try ops.append(std.testing.allocator, .{ .node_lookup_by_text = .{ .var_name = "f", .kind = .file, .text = "a.zig" } });
    try ops.append(std.testing.allocator, .{ .expand = .{ .left_var = "f", .rel = .defines, .right_var = "s", .right_kind = .function } });

    var table = try execute(std.testing.allocator, &graph, .{ .ops = ops });
    defer table.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), table.rows.items.len);
    try std.testing.expectEqual(func.toInt(), table.rows.items[0].get("s").?.toInt());
}

test "executor expand respects visited node budget" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    const file = try graph.addNode(.file, "a.zig");
    _ = try graph.addNode(.function, "main");
    _ = try graph.addEdgeUnchecked(file, .defines, core.NodeId.fromInt(2));

    var ops = std.ArrayList(optimizer.PhysicalOp).empty;
    defer ops.deinit(std.testing.allocator);
    try ops.append(std.testing.allocator, .{ .node_lookup_by_text = .{ .var_name = "f", .kind = .file, .text = "a.zig" } });
    try ops.append(std.testing.allocator, .{ .expand = .{ .left_var = "f", .rel = .defines, .right_var = "s", .right_kind = .function } });

    var table = try executeWithBudget(std.testing.allocator, &graph, .{ .ops = ops }, .{ .max_visited_nodes = 1 });
    defer table.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), table.rows.items.len);
    try std.testing.expect(table.stats.budget_exceeded);
}

test "executor expand uses relation-bounded edge budget" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    const file = try graph.addNode(.file, "a.zig");
    const doc = try graph.addNode(.document, "README");
    const func = try graph.addNode(.function, "main");
    _ = try graph.addEdgeUnchecked(file, .contains, doc);
    _ = try graph.addEdgeUnchecked(file, .defines, func);

    var ops = std.ArrayList(optimizer.PhysicalOp).empty;
    defer ops.deinit(std.testing.allocator);
    try ops.append(std.testing.allocator, .{ .node_lookup_by_text = .{ .var_name = "f", .kind = .file, .text = "a.zig" } });
    try ops.append(std.testing.allocator, .{ .expand = .{ .left_var = "f", .rel = .defines, .right_var = "s", .right_kind = .function } });

    var table = try executeWithBudget(std.testing.allocator, &graph, .{ .ops = ops }, .{ .max_visited_edges = 1 });
    defer table.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), table.rows.items.len);
    try std.testing.expectEqual(func.toInt(), table.rows.items[0].get("s").?.toInt());
    try std.testing.expect(!table.stats.budget_exceeded);
    try std.testing.expectEqual(@as(usize, 1), table.stats.edges_visited);
}

test "persistent executor expand uses relation-bounded edge budget" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    const file = core.NodeId.fromInt(1);
    const doc = core.NodeId.fromInt(2);
    const func = core.NodeId.fromInt(3);
    try store.appendNode(.{ .id = file, .kind = .file, .text = "a.zig" });
    try store.appendNode(.{ .id = doc, .kind = .document, .text = "README" });
    try store.appendNode(.{ .id = func, .kind = .function, .text = "main" });
    try store.appendEdge(.{ .id = .fromInt(1), .src = file, .rel = .contains, .dst = doc });
    try store.appendEdge(.{ .id = .fromInt(2), .src = file, .rel = .defines, .dst = func });

    var ops = std.ArrayList(optimizer.PhysicalOp).empty;
    defer ops.deinit(std.testing.allocator);
    try ops.append(std.testing.allocator, .{ .node_lookup_by_text = .{ .var_name = "f", .kind = .file, .text = "a.zig" } });
    try ops.append(std.testing.allocator, .{ .expand = .{ .left_var = "f", .rel = .defines, .right_var = "s", .right_kind = .function } });

    var table = try executeWithPersistentStoreAndIo(std.testing.allocator, std.testing.io, store, .{ .ops = ops }, .{ .max_visited_edges = 1 });
    defer table.deinit(std.testing.allocator);
    try std.testing.expect(table.read_timestamp_ns != null);
    try std.testing.expectEqual(@as(usize, 1), table.rows.items.len);
    try std.testing.expectEqual(func.toInt(), table.rows.items[0].get("s").?.toInt());
    try std.testing.expect(!table.stats.budget_exceeded);
    try std.testing.expectEqual(@as(usize, 1), table.stats.edges_visited);
}

test "persistent query session reuses node-text lookup view across executions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    const file = core.NodeId.fromInt(1);
    try store.appendNode(.{ .id = file, .kind = .file, .text = "a.zig" });

    var ops = std.ArrayList(optimizer.PhysicalOp).empty;
    defer ops.deinit(std.testing.allocator);
    try ops.append(std.testing.allocator, .{ .node_lookup_by_text = .{ .var_name = "f", .kind = .file, .text = "a.zig" } });

    var session = PersistentStoreQuerySession.init(std.testing.allocator, store);
    defer session.deinit();

    var first = try session.execute(std.testing.io, .{ .ops = ops }, .{});
    defer first.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), first.rows.items.len);
    try std.testing.expectEqual(file.toInt(), first.rows.items[0].get("f").?.toInt());
    try std.testing.expect(session.node_state.node_text_lookup_view != null);
    const retained_view = session.node_state.node_text_lookup_view.?;

    var second = try session.execute(std.testing.io, .{ .ops = ops }, .{});
    defer second.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), second.rows.items.len);
    try std.testing.expectEqual(file.toInt(), second.rows.items[0].get("f").?.toInt());
    try std.testing.expect(session.node_state.node_text_lookup_view != null);
    try std.testing.expectEqual(retained_view, session.node_state.node_text_lookup_view.?);
}

test "persistent executor lazily opens published edge segments by node range" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);
    const base_segment_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "base-segment" });
    defer std.testing.allocator.free(base_segment_path);

    var store = try storage.Store.initWithOptions(std.testing.allocator, std.testing.io, store_path, .{
        .durability = .fast,
        .validate_indexes_on_read = false,
    });
    defer store.deinit();
    try store.createEmpty();

    const file = core.NodeId.fromInt(1);
    const func = core.NodeId.fromInt(2);
    const unrelated_file = core.NodeId.fromInt(10);
    const unrelated_func = core.NodeId.fromInt(11);
    const delta_file = core.NodeId.fromInt(20);
    const delta_func = core.NodeId.fromInt(21);
    try store.appendNode(.{ .id = file, .kind = .file, .text = "a.zig" });
    try store.appendNode(.{ .id = func, .kind = .function, .text = "main" });
    try store.appendNode(.{ .id = unrelated_file, .kind = .file, .text = "b.zig" });
    try store.appendNode(.{ .id = unrelated_func, .kind = .function, .text = "helper" });
    try store.appendNode(.{ .id = delta_file, .kind = .file, .text = "c.zig" });
    try store.appendNode(.{ .id = delta_func, .kind = .function, .text = "delta" });

    var base_edges = std.ArrayList(graph_mod.Edge).empty;
    defer base_edges.deinit(std.testing.allocator);
    try base_edges.ensureTotalCapacity(std.testing.allocator, 1024);
    base_edges.appendAssumeCapacity(.{
        .id = .fromInt(1),
        .src = file,
        .rel = .defines,
        .dst = func,
    });
    var edge_id: u64 = 1;
    while (edge_id < 1024) : (edge_id += 1) {
        base_edges.appendAssumeCapacity(.{
            .id = .fromInt(edge_id + 1),
            .src = unrelated_file,
            .rel = .defines,
            .dst = unrelated_func,
        });
    }
    try store.appendEdgesBatch(base_edges.items);
    try std.testing.expectEqual(@as(u64, 1024), try store.publishEdgeAdjacencySegment(base_segment_path));

    try store.appendEdge(.{
        .id = .fromInt(1025),
        .src = delta_file,
        .rel = .defines,
        .dst = delta_func,
    });

    var base_query_segments = (try store.openPublishedEdgeSegmentsForQueryForNode(std.testing.allocator, .forward, file)).?;
    defer base_query_segments.deinit();
    try std.testing.expectEqual(@as(usize, 1), base_query_segments.segments.segments.items.len);
    try std.testing.expectEqual(@as(usize, 0), base_query_segments.segments.virtual_edges.items.len);

    var delta_query_segments = (try store.openPublishedEdgeSegmentsForQueryForNode(std.testing.allocator, .forward, delta_file)).?;
    defer delta_query_segments.deinit();
    try std.testing.expectEqual(@as(usize, 0), delta_query_segments.segments.segments.items.len);
    try std.testing.expectEqual(@as(usize, 1), delta_query_segments.segments.virtual_edges.items.len);

    var ops = std.ArrayList(optimizer.PhysicalOp).empty;
    defer ops.deinit(std.testing.allocator);
    try ops.append(std.testing.allocator, .{ .node_lookup_by_text = .{ .var_name = "f", .kind = .file, .text = "a.zig" } });
    try ops.append(std.testing.allocator, .{ .expand = .{ .left_var = "f", .rel = .defines, .right_var = "s", .right_kind = .function } });

    var table = try executeWithPersistentStoreAndIo(std.testing.allocator, std.testing.io, store, .{ .ops = ops }, .{});
    defer table.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), table.rows.items.len);
    try std.testing.expectEqual(func.toInt(), table.rows.items[0].get("s").?.toInt());
    try std.testing.expect(!table.stats.budget_exceeded);
}

test "persistent node filtering sees deprecated_by in published edge overlay" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);
    const base_segment_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "base-segment" });
    defer std.testing.allocator.free(base_segment_path);

    var store = try storage.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();
    try store.appendNodesBatch(&.{
        .{ .id = .fromInt(1), .kind = .file, .text = "overlay stale candidate" },
        .{ .id = .fromInt(2), .kind = .file, .text = "overlay current candidate" },
        .{ .id = .fromInt(3), .kind = .file, .text = "base source" },
        .{ .id = .fromInt(4), .kind = .file, .text = "base target" },
    });
    try store.appendEdge(.{ .id = .fromInt(1), .src = .fromInt(3), .rel = .references, .dst = .fromInt(4) });
    try std.testing.expectEqual(@as(u64, 1), try store.publishEdgeAdjacencySegment(base_segment_path));
    try store.appendEdge(.{ .id = .fromInt(2), .src = .fromInt(1), .rel = .deprecated_by, .dst = .fromInt(2) });

    const cursor = NodeCursor{ .store = .{ .allocator = std.testing.allocator, .store = store } };
    try std.testing.expectEqual(false, (try cursor.matchNode(std.testing.allocator, .fromInt(1), .file, null)).?);
    var stale = try cursor.lookupByText(std.testing.allocator, .file, "overlay stale candidate", 1);
    defer stale.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), stale.items.len);
    var current = try cursor.lookupByText(std.testing.allocator, .file, "overlay current candidate", 1);
    defer current.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), current.items.len);
    try std.testing.expectEqual(@as(u64, 2), current.items[0].toInt());

    var ops = std.ArrayList(optimizer.PhysicalOp).empty;
    defer ops.deinit(std.testing.allocator);
    try ops.append(std.testing.allocator, .{ .node_lookup_by_text = .{
        .var_name = "n",
        .kind = .file,
        .text = "overlay stale candidate",
    } });
    var edge_retention_registry = storage.EdgeSegmentRetentionRegistry.init(std.testing.allocator);
    defer edge_retention_registry.deinit();
    var result = try executeWithPersistentStoreAndIoRetained(std.testing.allocator, std.testing.io, store, &edge_retention_registry, .{ .ops = ops }, .{});
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), result.rows.items.len);
}

test "persistent executor expand kind filter avoids node text materialization" {
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

    const file = core.NodeId.fromInt(1);
    const func = core.NodeId.fromInt(2);
    try store.appendNode(.{ .id = file, .kind = .file, .text = "a.zig" });
    try store.appendNode(.{ .id = func, .kind = .function, .text = "main" });
    try store.appendEdge(.{ .id = .fromInt(1), .src = file, .rel = .defines, .dst = func });

    const names_path = try std.fs.path.join(std.testing.allocator, &.{ store_path, "node_texts.dat" });
    defer std.testing.allocator.free(names_path);
    try std.Io.Dir.cwd().deleteFile(std.testing.io, names_path);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, names_path);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, names_path) catch {};

    var ops = std.ArrayList(optimizer.PhysicalOp).empty;
    defer ops.deinit(std.testing.allocator);
    try ops.append(std.testing.allocator, .{ .node_scan = .{ .var_name = "f", .kind = .file } });
    try ops.append(std.testing.allocator, .{ .expand = .{ .left_var = "f", .rel = .defines, .right_var = "s", .right_kind = .function } });

    var table = try executeWithPersistentStoreAndIo(std.testing.allocator, std.testing.io, store, .{ .ops = ops }, .{});
    defer table.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), table.rows.items.len);
    try std.testing.expectEqual(func.toInt(), table.rows.items[0].get("s").?.toInt());
    try std.testing.expectEqual(@as(usize, 2), table.stats.nodes_visited);
}

test "executor expand with no matches keeps result stats in sync" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    const file = try graph.addNode(.file, "a.zig");
    const doc = try graph.addNode(.document, "README");
    _ = try graph.addEdgeUnchecked(file, .mentions, doc);

    var ops = std.ArrayList(optimizer.PhysicalOp).empty;
    defer ops.deinit(std.testing.allocator);
    try ops.append(std.testing.allocator, .{ .node_lookup_by_text = .{ .var_name = "f", .kind = .file, .text = "a.zig" } });
    try ops.append(std.testing.allocator, .{ .expand = .{ .left_var = "f", .rel = .defines, .right_var = "s", .right_kind = .function } });

    var table = try execute(std.testing.allocator, &graph, .{ .ops = ops });
    defer table.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), table.rows.items.len);
    try std.testing.expectEqual(@as(usize, 0), table.stats.results);
    try std.testing.expect(!table.stats.budget_exceeded);
}

test "executor expand edge budget stops matching relation" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    const file = try graph.addNode(.file, "a.zig");
    const func = try graph.addNode(.function, "main");
    _ = try graph.addEdgeUnchecked(file, .defines, func);

    var ops = std.ArrayList(optimizer.PhysicalOp).empty;
    defer ops.deinit(std.testing.allocator);
    try ops.append(std.testing.allocator, .{ .node_lookup_by_text = .{ .var_name = "f", .kind = .file, .text = "a.zig" } });
    try ops.append(std.testing.allocator, .{ .expand = .{ .left_var = "f", .rel = .defines, .right_var = "s", .right_kind = .function } });

    var table = try executeWithBudget(std.testing.allocator, &graph, .{ .ops = ops }, .{ .max_visited_edges = 0 });
    defer table.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), table.rows.items.len);
    try std.testing.expect(table.stats.budget_exceeded);
    try std.testing.expectEqual(@as(usize, 0), table.stats.edges_visited);
}

test "executor expand respects max depth budget" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    const a = try graph.addNode(.task, "a");
    const b = try graph.addNode(.task, "b");
    const c = try graph.addNode(.task, "c");
    _ = try graph.addEdgeUnchecked(a, .depends_on, b);
    _ = try graph.addEdgeUnchecked(b, .depends_on, c);

    var ops = std.ArrayList(optimizer.PhysicalOp).empty;
    defer ops.deinit(std.testing.allocator);
    try ops.append(std.testing.allocator, .{ .node_lookup_by_text = .{ .var_name = "a", .kind = .task, .text = "a" } });
    try ops.append(std.testing.allocator, .{ .expand = .{ .left_var = "a", .rel = .depends_on, .right_var = "t", .right_kind = .task, .min_hops = 1, .max_hops = 2 } });

    var table = try executeWithBudget(std.testing.allocator, &graph, .{ .ops = ops }, .{ .max_depth = 1 });
    defer table.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), table.rows.items.len);
    try std.testing.expectEqual(b.toInt(), table.rows.items[0].get("t").?.toInt());
    try std.testing.expect(table.stats.budget_exceeded);
}

test "executor variable-hop expansion uses simple node paths through cycles" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    const a = try graph.addNode(.task, "a");
    const b = try graph.addNode(.task, "b");
    const c = try graph.addNode(.task, "c");
    _ = try graph.addEdgeUnchecked(a, .depends_on, b);
    _ = try graph.addEdgeUnchecked(b, .depends_on, a);
    _ = try graph.addEdgeUnchecked(b, .depends_on, c);

    var ops = std.ArrayList(optimizer.PhysicalOp).empty;
    defer ops.deinit(std.testing.allocator);
    try ops.append(std.testing.allocator, .{ .node_lookup_by_text = .{ .var_name = "a", .kind = .task, .text = "a" } });
    try ops.append(std.testing.allocator, .{
        .expand = .{
            .left_var = "a",
            .rel = .depends_on,
            .right_var = "t",
            .right_kind = .task,
            .min_hops = 1,
            .max_hops = 3,
        },
    });

    var table = try execute(std.testing.allocator, &graph, .{ .ops = ops });
    defer table.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), table.rows.items.len);

    var saw_b = false;
    var saw_c = false;
    for (table.rows.items) |row| {
        const target = row.get("t").?;
        if (target.toInt() == b.toInt()) saw_b = true;
        if (target.toInt() == c.toInt()) saw_c = true;
        const path = row.getPath("a", "t").?;
        for (path, 0..) |node, i| {
            for (path[i + 1 ..]) |later| {
                try std.testing.expect(node.toInt() != later.toInt());
            }
        }
    }
    try std.testing.expect(saw_b);
    try std.testing.expect(saw_c);
}

test "executor variable-hop applies right predicates only at return depth" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    const start = try graph.addNode(.task, "start");
    const middle = try graph.addNode(.concept, "middle");
    const target = try graph.addNode(.task, "target");
    _ = try graph.addEdgeUnchecked(start, .depends_on, middle);
    _ = try graph.addEdgeUnchecked(middle, .depends_on, target);

    var ops = std.ArrayList(optimizer.PhysicalOp).empty;
    defer ops.deinit(std.testing.allocator);
    try ops.append(std.testing.allocator, .{ .node_lookup_by_text = .{ .var_name = "s", .kind = .task, .text = "start" } });
    try ops.append(std.testing.allocator, .{
        .expand = .{
            .left_var = "s",
            .rel = .depends_on,
            .right_var = "t",
            .right_kind = .task,
            .right_text_eq = "target",
            .min_hops = 2,
            .max_hops = 2,
        },
    });

    var table = try execute(std.testing.allocator, &graph, .{ .ops = ops });
    defer table.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), table.rows.items.len);
    try std.testing.expectEqual(target.toInt(), table.rows.items[0].get("t").?.toInt());
}

test "executor skips expand path binding when projection does not need it" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    const a = try graph.addNode(.task, "a");
    const b = try graph.addNode(.task, "b");
    _ = try graph.addEdgeUnchecked(a, .depends_on, b);

    const projections = [_]ast.Projection{.{ .variable = "t" }};
    var ops = std.ArrayList(optimizer.PhysicalOp).empty;
    defer ops.deinit(std.testing.allocator);
    try ops.append(std.testing.allocator, .{ .node_lookup_by_text = .{ .var_name = "a", .kind = .task, .text = "a" } });
    try ops.append(std.testing.allocator, .{ .expand = .{ .left_var = "a", .rel = .depends_on, .right_var = "t", .right_kind = .task } });
    try ops.append(std.testing.allocator, .{ .project = projections[0..] });

    var table = try execute(std.testing.allocator, &graph, .{ .ops = ops });
    defer table.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), table.rows.items.len);
    try std.testing.expectEqual(b.toInt(), table.rows.items[0].get("t").?.toInt());
    try std.testing.expect(table.rows.items[0].getPath("a", "t") == null);
}

test "executor keeps expand path binding when projection needs it" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    const a = try graph.addNode(.task, "a");
    const b = try graph.addNode(.task, "b");
    _ = try graph.addEdgeUnchecked(a, .depends_on, b);

    const projections = [_]ast.Projection{.{ .path = .{ .from_var = "a", .to_var = "t" } }};
    var ops = std.ArrayList(optimizer.PhysicalOp).empty;
    defer ops.deinit(std.testing.allocator);
    try ops.append(std.testing.allocator, .{ .node_lookup_by_text = .{ .var_name = "a", .kind = .task, .text = "a" } });
    try ops.append(std.testing.allocator, .{ .expand = .{ .left_var = "a", .rel = .depends_on, .right_var = "t", .right_kind = .task } });
    try ops.append(std.testing.allocator, .{ .project = projections[0..] });

    var table = try execute(std.testing.allocator, &graph, .{ .ops = ops });
    defer table.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), table.rows.items.len);
    const path = table.rows.items[0].getPath("a", "t").?;
    try std.testing.expectEqual(@as(usize, 2), path.len);
    try std.testing.expectEqual(a.toInt(), path[0].toInt());
    try std.testing.expectEqual(b.toInt(), path[1].toInt());
}

test "executor drops text score binding when projection does not need it across expand" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    const file = try graph.addNode(.file, "source file");
    const func = try graph.addNode(.function, "target");
    _ = try graph.addEdgeUnchecked(file, .defines, func);

    const projections = [_]ast.Projection{.{ .variable = "t" }};
    var ops = std.ArrayList(optimizer.PhysicalOp).empty;
    defer ops.deinit(std.testing.allocator);
    try ops.append(std.testing.allocator, .{ .text_search = .{ .var_name = "o", .query = "source", .kind = .file } });
    try ops.append(std.testing.allocator, .{ .expand = .{ .left_var = "o", .rel = .defines, .right_var = "t", .right_kind = .function } });
    try ops.append(std.testing.allocator, .{ .project = projections[0..] });

    var table = try execute(std.testing.allocator, &graph, .{ .ops = ops });
    defer table.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), table.rows.items.len);
    try std.testing.expectEqual(func.toInt(), table.rows.items[0].get("t").?.toInt());
    try std.testing.expect(table.rows.items[0].getScore("o") == null);
}

test "executor keeps text score binding when projection needs it across expand" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    const file = try graph.addNode(.file, "source file");
    const func = try graph.addNode(.function, "target");
    _ = try graph.addEdgeUnchecked(file, .defines, func);

    const projections = [_]ast.Projection{ .{ .variable = "t" }, .{ .score = .{ .var_name = "o" } } };
    var ops = std.ArrayList(optimizer.PhysicalOp).empty;
    defer ops.deinit(std.testing.allocator);
    try ops.append(std.testing.allocator, .{ .text_search = .{ .var_name = "o", .query = "source", .kind = .file } });
    try ops.append(std.testing.allocator, .{ .expand = .{ .left_var = "o", .rel = .defines, .right_var = "t", .right_kind = .function } });
    try ops.append(std.testing.allocator, .{ .project = projections[0..] });

    var table = try execute(std.testing.allocator, &graph, .{ .ops = ops });
    defer table.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), table.rows.items.len);
    try std.testing.expectEqual(func.toInt(), table.rows.items[0].get("t").?.toInt());
    try std.testing.expect(table.rows.items[0].getScore("o") != null);
}

test "executor text search applies schema descendant filter before result limit" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    const task_id = try graph.addNode(.task, "shared search term");
    const decision_id = try graph.addNode(.decision, "shared search term");
    _ = try graph.addNode(.file, "shared search term shared search term shared search term");

    var descendants = schema.NodeTypeSet.empty();
    try descendants.insert(@intFromEnum(core.NodeKind.task));
    try descendants.insert(@intFromEnum(core.NodeKind.decision));
    var ops = std.ArrayList(optimizer.PhysicalOp).empty;
    defer ops.deinit(std.testing.allocator);
    try ops.append(std.testing.allocator, .{ .text_search = .{
        .var_name = "n",
        .query = "shared search term",
        .kind = null,
        .type_filter = .{ .set = descendants },
        .limit = 2,
    } });

    var table = try execute(std.testing.allocator, &graph, .{ .ops = ops });
    defer table.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), table.rows.items.len);
    const first = table.rows.items[0].get("n").?;
    const second = table.rows.items[1].get("n").?;
    try std.testing.expect((first == task_id and second == decision_id) or
        (first == decision_id and second == task_id));
}

test "executor does not push limit before expand scan candidates" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    const first_file = try graph.addNode(.file, "a.zig");
    const second_file = try graph.addNode(.file, "b.zig");
    const other = try graph.addNode(.function, "other");
    const target = try graph.addNode(.function, "target");
    _ = try graph.addEdgeUnchecked(first_file, .defines, other);
    _ = try graph.addEdgeUnchecked(second_file, .defines, target);

    var ops = std.ArrayList(optimizer.PhysicalOp).empty;
    defer ops.deinit(std.testing.allocator);
    try ops.append(std.testing.allocator, .{ .node_scan = .{ .var_name = "f", .kind = .file } });
    try ops.append(std.testing.allocator, .{ .expand = .{
        .left_var = "f",
        .rel = .defines,
        .right_var = "s",
        .right_kind = .function,
        .right_text_eq = "target",
    } });
    try ops.append(std.testing.allocator, .{ .limit = 1 });

    var table = try execute(std.testing.allocator, &graph, .{ .ops = ops });
    defer table.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), table.rows.items.len);
    try std.testing.expectEqual(second_file.toInt(), table.rows.items[0].get("f").?.toInt());
}

test "executor does not push limit before duplicate-text lookup expansion" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    const first_file = try graph.addNode(.file, "shared.zig");
    const second_file = try graph.addNode(.file, "shared.zig");
    const other = try graph.addNode(.function, "other");
    const target = try graph.addNode(.function, "target");
    _ = try graph.addEdgeUnchecked(first_file, .defines, other);
    _ = try graph.addEdgeUnchecked(second_file, .defines, target);

    var ops = std.ArrayList(optimizer.PhysicalOp).empty;
    defer ops.deinit(std.testing.allocator);
    try ops.append(std.testing.allocator, .{ .node_lookup_by_text = .{ .var_name = "f", .kind = .file, .text = "shared.zig" } });
    try ops.append(std.testing.allocator, .{ .expand = .{
        .left_var = "f",
        .rel = .defines,
        .right_var = "s",
        .right_kind = .function,
        .right_text_eq = "target",
    } });
    try ops.append(std.testing.allocator, .{ .limit = 1 });

    var table = try execute(std.testing.allocator, &graph, .{ .ops = ops });
    defer table.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), table.rows.items.len);
    try std.testing.expectEqual(second_file.toInt(), table.rows.items[0].get("f").?.toInt());
}

test "executor marks visited node budget truncation for scan candidates" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    _ = try graph.addNode(.file, "a.zig");
    _ = try graph.addNode(.file, "b.zig");

    var ops = std.ArrayList(optimizer.PhysicalOp).empty;
    defer ops.deinit(std.testing.allocator);
    try ops.append(std.testing.allocator, .{ .node_scan = .{ .var_name = "f", .kind = .file } });

    var table = try executeWithBudget(std.testing.allocator, &graph, .{ .ops = ops }, .{ .max_visited_nodes = 1 });
    defer table.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), table.rows.items.len);
    try std.testing.expectEqual(@as(usize, 1), table.stats.nodes_visited);
    try std.testing.expect(table.stats.budget_exceeded);
}

test "executor marks visited node budget truncation for exact-text lookup candidates" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    _ = try graph.addNode(.file, "shared.zig");
    _ = try graph.addNode(.file, "shared.zig");

    var ops = std.ArrayList(optimizer.PhysicalOp).empty;
    defer ops.deinit(std.testing.allocator);
    try ops.append(std.testing.allocator, .{ .node_lookup_by_text = .{ .var_name = "f", .kind = .file, .text = "shared.zig" } });

    var table = try executeWithBudget(std.testing.allocator, &graph, .{ .ops = ops }, .{ .max_visited_nodes = 1 });
    defer table.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), table.rows.items.len);
    try std.testing.expectEqual(@as(usize, 1), table.stats.nodes_visited);
    try std.testing.expect(table.stats.budget_exceeded);
}

test "executor result limit does not report budget truncation for scan candidates" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    _ = try graph.addNode(.file, "a.zig");
    _ = try graph.addNode(.file, "b.zig");

    var ops = std.ArrayList(optimizer.PhysicalOp).empty;
    defer ops.deinit(std.testing.allocator);
    try ops.append(std.testing.allocator, .{ .node_scan = .{ .var_name = "f", .kind = .file } });

    var table = try executeWithBudget(std.testing.allocator, &graph, .{ .ops = ops }, .{ .max_results = 1 });
    defer table.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), table.rows.items.len);
    try std.testing.expectEqual(@as(usize, 1), table.stats.nodes_visited);
    try std.testing.expect(!table.stats.budget_exceeded);
}

test "executor node scan hides non-active graph nodes" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    const active = try graph.addNode(.file, "active.zig");
    const stale = try graph.addNode(.file, "stale.zig");
    for (graph.nodes.items) |*node| {
        if (node.id == stale) node.status = .stale;
    }

    var ops = std.ArrayList(optimizer.PhysicalOp).empty;
    defer ops.deinit(std.testing.allocator);
    try ops.append(std.testing.allocator, .{ .node_scan = .{ .var_name = "f", .kind = .file } });

    var table = try execute(std.testing.allocator, &graph, .{ .ops = ops });
    defer table.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), table.rows.items.len);
    try std.testing.expectEqual(active.toInt(), table.rows.items[0].get("f").?.toInt());
}

test "executor memory status predicate exposes only representable open tasks" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    const task_id = try graph.addNode(.task, "open task");
    _ = try graph.addNode(.document, "not a task");

    var open_ops = std.ArrayList(optimizer.PhysicalOp).empty;
    defer open_ops.deinit(std.testing.allocator);
    try open_ops.append(std.testing.allocator, .{ .node_lookup_by_property = .{
        .var_name = "t",
        .kind = .task,
        .type_filter = .{ .single = .task },
        .property_eq = .{ .key = task_mod.status_property, .value = "open" },
    } });
    var open_table = try execute(std.testing.allocator, &graph, .{ .ops = open_ops });
    defer open_table.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), open_table.rows.items.len);
    try std.testing.expectEqual(task_id.toInt(), open_table.rows.items[0].get("t").?.toInt());

    inline for (&.{ "claimed", "completed", "failed" }) |status| {
        var terminal_ops = std.ArrayList(optimizer.PhysicalOp).empty;
        defer terminal_ops.deinit(std.testing.allocator);
        try terminal_ops.append(std.testing.allocator, .{ .node_lookup_by_property = .{
            .var_name = "t",
            .kind = .task,
            .type_filter = .{ .single = .task },
            .property_eq = .{ .key = task_mod.status_property, .value = status },
        } });
        var terminal_table = try execute(std.testing.allocator, &graph, .{ .ops = terminal_ops });
        defer terminal_table.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 0), terminal_table.rows.items.len);
    }
}

test "persistent effective task status uses bounded indexed candidates" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();
    try store.appendNodesBatch(&.{
        .{ .id = .fromInt(1), .kind = .task, .text = "open" },
        .{ .id = .fromInt(2), .kind = .task, .text = "live claim" },
        .{ .id = .fromInt(3), .kind = .task, .text = "expired claim" },
        .{ .id = .fromInt(4), .kind = .task, .text = "completed crash window" },
    });
    try store.setNodeStringProperty(std.testing.allocator, .fromInt(1), task_mod.status_property, "open");
    try store.setNodeStringProperty(std.testing.allocator, .fromInt(2), task_mod.status_property, "claimed");
    try store.setNodeStringProperty(std.testing.allocator, .fromInt(2), task_mod.claimed_by_property, "agent-a");
    try store.setUintProperty(std.testing.allocator, .{ .node = .fromInt(2) }, task_mod.claim_expires_ns_property, 101);
    try store.setNodeStringProperty(std.testing.allocator, .fromInt(3), task_mod.status_property, "claimed");
    try store.setNodeStringProperty(std.testing.allocator, .fromInt(3), task_mod.claimed_by_property, "agent-b");
    try store.setUintProperty(std.testing.allocator, .{ .node = .fromInt(3) }, task_mod.claim_expires_ns_property, 100);
    try store.setNodeStringProperty(std.testing.allocator, .fromInt(4), task_mod.status_property, "completed");
    try store.setUintProperty(std.testing.allocator, .{ .node = .fromInt(4) }, "task_completed_ns", 1);
    try store.setNodeStringProperty(std.testing.allocator, .fromInt(4), task_mod.claimed_by_property, "agent-c");
    try store.setUintProperty(std.testing.allocator, .{ .node = .fromInt(4) }, task_mod.claim_expires_ns_property, 999);

    const expected = [_]struct { status: []const u8, ids: []const u64 }{
        .{ .status = "open", .ids = &.{ 1, 3 } },
        .{ .status = "claimed", .ids = &.{2} },
        .{ .status = "completed", .ids = &.{4} },
        .{ .status = "failed", .ids = &.{} },
    };
    for (expected) |case| {
        var ids = try lookupStoreTaskIdsByEffectiveStatus(store, std.testing.allocator, null, .{ .single = .task }, .{
            .key = task_mod.status_property,
            .value = case.status,
        }, 8, 100);
        defer ids.deinit(std.testing.allocator);
        try std.testing.expectEqual(case.ids.len, ids.items.len);
        for (case.ids, ids.items) |want, got| try std.testing.expectEqual(want, got.toInt());
    }
}

test "schema v3 effective open status includes a task missing its crash-window marker" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();
    try store.appendNodesBatch(&.{
        .{ .id = .fromInt(1), .kind = .task, .text = "completed" },
        .{ .id = .fromInt(2), .kind = .task, .text = "implicit open after crash" },
    });
    try store.setNodeStringProperty(std.testing.allocator, .fromInt(1), task_mod.status_property, "completed");
    try store.setUintProperty(std.testing.allocator, .{ .node = .fromInt(1) }, "task_completed_ns", 1);

    const manifest_dir = try std.fs.path.join(std.testing.allocator, &.{ store_path, ".tinykg" });
    defer std.testing.allocator.free(manifest_dir);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, manifest_dir);
    const manifest_path = try std.fs.path.join(std.testing.allocator, &.{ manifest_dir, "store-manifest.json" });
    defer std.testing.allocator.free(manifest_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = manifest_path,
        .data = "{\"store_manifest_version\":1,\"storage_format_version\":2,\"schema\":{\"schema_version\":3}}",
        .flags = .{ .truncate = true },
    });

    var ids = try lookupStoreTaskIdsByEffectiveStatus(store, std.testing.allocator, null, .{ .single = .task }, .{
        .key = task_mod.status_property,
        .value = "open",
    }, 8, 100);
    defer ids.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), ids.items.len);
    try std.testing.expectEqual(@as(u64, 2), ids.items[0].toInt());
}

test "persistent effective task status ignores terminal leases and fails closed on saturated claims" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    const node_count: usize = 74;
    const nodes = try std.testing.allocator.alloc(graph_mod.Node, node_count);
    defer std.testing.allocator.free(nodes);
    for (nodes, 0..) |*node, index_pos| node.* = .{
        .id = .fromInt(index_pos + 1),
        .kind = .task,
        .text = "status candidate",
    };
    try store.appendNodesBatch(nodes);

    const manifest_dir = try std.fs.path.join(std.testing.allocator, &.{ store_path, ".tinykg" });
    defer std.testing.allocator.free(manifest_dir);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, manifest_dir);
    const manifest_path = try std.fs.path.join(std.testing.allocator, &.{ manifest_dir, "store-manifest.json" });
    defer std.testing.allocator.free(manifest_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = manifest_path,
        .data = "{\"store_manifest_version\":1,\"storage_format_version\":2,\"schema\":{\"schema_version\":3}}",
        .flags = .{ .truncate = true },
    });

    var initial_writes = try std.testing.allocator.alloc(storage.PropertyPayloadWrite, 36 * 3 + 3);
    defer std.testing.allocator.free(initial_writes);
    for (0..36) |index_pos| {
        const id: core.NodeId = .fromInt(index_pos + 1);
        initial_writes[index_pos * 3] = .{ .owner = .{ .node = id }, .key = task_mod.status_property, .value = .{ .string = "completed" } };
        initial_writes[index_pos * 3 + 1] = .{ .owner = .{ .node = id }, .key = "task_completed_ns", .value = .{ .uint = 1 } };
        initial_writes[index_pos * 3 + 2] = .{ .owner = .{ .node = id }, .key = task_mod.claim_expires_ns_property, .value = .{ .uint = 101 } };
    }
    initial_writes[108] = .{ .owner = .{ .node = .fromInt(37) }, .key = task_mod.status_property, .value = .{ .string = "claimed" } };
    initial_writes[109] = .{ .owner = .{ .node = .fromInt(37) }, .key = task_mod.claimed_by_property, .value = .{ .string = "agent-a" } };
    initial_writes[110] = .{ .owner = .{ .node = .fromInt(37) }, .key = task_mod.claim_expires_ns_property, .value = .{ .uint = 101 } };
    _ = try store.upsertPropertiesBatch(std.testing.allocator, initial_writes);

    // Terminal tasks retain stale lease fields after a crash window. They
    // must not consume the claimed-status candidate budget.
    var claimed = try lookupStoreTaskIdsByEffectiveStatus(store, std.testing.allocator, null, .{ .single = .task }, .{
        .key = task_mod.status_property,
        .value = "claimed",
    }, 1, 100);
    defer claimed.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), claimed.items.len);
    try std.testing.expectEqual(@as(u64, 37), claimed.items[0].toInt());

    // Fill the bounded raw-claimed window with expired leases and place a
    // live claim after it. Returning an empty success would be a false answer;
    // the executor must surface budget pressure instead.
    var pressure_writes = try std.testing.allocator.alloc(storage.PropertyPayloadWrite, (74 - 37 + 1) * 3);
    defer std.testing.allocator.free(pressure_writes);
    var write_index: usize = 0;
    for (37..75) |raw_id| {
        const id: core.NodeId = .fromInt(raw_id);
        pressure_writes[write_index] = .{ .owner = .{ .node = id }, .key = task_mod.status_property, .value = .{ .string = "claimed" } };
        pressure_writes[write_index + 1] = .{ .owner = .{ .node = id }, .key = task_mod.claimed_by_property, .value = .{ .string = "agent-a" } };
        pressure_writes[write_index + 2] = .{
            .owner = .{ .node = id },
            .key = task_mod.claim_expires_ns_property,
            .value = .{ .uint = if (raw_id == 74) 101 else 100 },
        };
        write_index += 3;
    }
    _ = try store.upsertPropertiesBatch(std.testing.allocator, pressure_writes);
    try std.testing.expectError(core.Error.BudgetExceeded, lookupStoreTaskIdsByEffectiveStatus(store, std.testing.allocator, null, .{ .single = .task }, .{
        .key = task_mod.status_property,
        .value = "claimed",
    }, 1, 100));

    try std.testing.expectEqual(@as(usize, 5000), currentGenerationCandidateLimit(5000));
    try std.testing.expectEqual(@as(usize, 5000), textSearchCandidateLimitForLatest(5000));
}

test "mixed status domain can satisfy limit despite saturated task candidates" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    const candidate_limit = currentGenerationCandidateLimit(1);
    const task_count = candidate_limit + 1;
    const nodes = try std.testing.allocator.alloc(graph_mod.Node, task_count + 1);
    defer std.testing.allocator.free(nodes);
    nodes[0] = .{ .id = .fromInt(1), .kind = .concept, .text = "ordinary claimed status" };
    for (nodes[1..], 0..) |*node, index_pos| node.* = .{
        .id = .fromInt(index_pos + 2),
        .kind = .task,
        .text = "expired task claim",
    };
    try store.appendNodesBatch(nodes);

    const writes = try std.testing.allocator.alloc(storage.PropertyPayloadWrite, 1 + task_count * 3);
    defer std.testing.allocator.free(writes);
    writes[0] = .{ .owner = .{ .node = .fromInt(1) }, .key = task_mod.status_property, .value = .{ .string = "claimed" } };
    var write_index: usize = 1;
    for (0..task_count) |index_pos| {
        const id: core.NodeId = .fromInt(index_pos + 2);
        writes[write_index] = .{ .owner = .{ .node = id }, .key = task_mod.status_property, .value = .{ .string = "claimed" } };
        writes[write_index + 1] = .{ .owner = .{ .node = id }, .key = task_mod.claimed_by_property, .value = .{ .string = "expired-agent" } };
        writes[write_index + 2] = .{ .owner = .{ .node = id }, .key = task_mod.claim_expires_ns_property, .value = .{ .uint = 100 } };
        write_index += 3;
    }
    try store.appendPropertiesBatch(std.testing.allocator, writes);

    const manifest_dir = try std.fs.path.join(std.testing.allocator, &.{ store_path, ".tinykg" });
    defer std.testing.allocator.free(manifest_dir);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, manifest_dir);
    const manifest_path = try std.fs.path.join(std.testing.allocator, &.{ manifest_dir, "store-manifest.json" });
    defer std.testing.allocator.free(manifest_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = manifest_path,
        .data = "{\"store_manifest_version\":1,\"storage_format_version\":2,\"schema\":{\"schema_version\":3}}",
        .flags = .{ .truncate = true },
    });

    var ids = try lookupStoreNodeIdsByStatusProperty(store, std.testing.allocator, null, .any, .{
        .key = task_mod.status_property,
        .value = "claimed",
    }, 1, 100);
    defer ids.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), ids.items.len);
    try std.testing.expectEqual(@as(u64, 1), ids.items[0].toInt());
}

test "mixed status domain can satisfy limit while legacy tasks require migration" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();
    // Size the legacy population against the larger request below.  Basing
    // this on LIMIT 1 only exercises the "ordinary property satisfies the
    // query" branch: LIMIT 2 has a larger overfetch budget and can otherwise
    // enumerate every legacy task without requiring migration.
    const legacy_task_count = currentGenerationCandidateLimit(2) + 1;
    const nodes = try std.testing.allocator.alloc(graph_mod.Node, legacy_task_count + 1);
    defer std.testing.allocator.free(nodes);
    nodes[0] = .{ .id = .fromInt(1), .kind = .concept, .text = "ordinary open status" };
    for (nodes[1..], 0..) |*node, index_pos| node.* = .{
        .id = .fromInt(index_pos + 2),
        .kind = .task,
        .text = "legacy implicit-open task",
    };
    try store.appendNodesBatch(nodes);
    try store.setNodeStringProperty(std.testing.allocator, .fromInt(1), task_mod.status_property, "open");

    var satisfied = try lookupStoreNodeIdsByStatusProperty(store, std.testing.allocator, null, .any, .{
        .key = task_mod.status_property,
        .value = "open",
    }, 1, 100);
    defer satisfied.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), satisfied.items.len);
    try std.testing.expectEqual(@as(u64, 1), satisfied.items[0].toInt());

    try std.testing.expectError(error.TaskStatusMigrationRequired, lookupStoreNodeIdsByStatusProperty(store, std.testing.allocator, null, .any, .{
        .key = task_mod.status_property,
        .value = "open",
    }, 2, 100));
}

test "malformed task status manifest is not reported as index corruption" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();
    try store.appendNode(.{ .id = .fromInt(1), .kind = .task, .text = "open task" });
    try store.setNodeStringProperty(std.testing.allocator, .fromInt(1), task_mod.status_property, "open");
    const manifest_dir = try std.fs.path.join(std.testing.allocator, &.{ store_path, ".tinykg" });
    defer std.testing.allocator.free(manifest_dir);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, manifest_dir);
    const manifest_path = try std.fs.path.join(std.testing.allocator, &.{ manifest_dir, "store-manifest.json" });
    defer std.testing.allocator.free(manifest_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = manifest_path,
        .data = "{not-json",
        .flags = .{ .truncate = true },
    });

    try std.testing.expectError(error.InvalidStoreManifest, lookupStoreTaskIdsByEffectiveStatus(store, std.testing.allocator, null, .{ .single = .task }, .{
        .key = task_mod.status_property,
        .value = "open",
    }, 1, 100));
}

test "large pre-status store requires explicit task status migration" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();
    const legacy_count = currentGenerationCandidateLimit(1) + 1;
    const nodes = try std.testing.allocator.alloc(graph_mod.Node, legacy_count);
    defer std.testing.allocator.free(nodes);
    for (nodes, 0..) |*node, index_pos| node.* = .{
        .id = .fromInt(index_pos + 1),
        .kind = .task,
        .text = "legacy task",
    };
    try store.appendNodesBatch(nodes);

    try std.testing.expectError(
        error.TaskStatusMigrationRequired,
        lookupStoreTaskIdsByEffectiveStatus(store, std.testing.allocator, null, .{ .single = .task }, .{
            .key = task_mod.status_property,
            .value = "open",
        }, 1, 0),
    );
}

test "persistent node candidate overfetch never hides current generations" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    const candidate_limit = currentGenerationCandidateLimit(1);
    const node_count = candidate_limit + 2;
    const nodes = try std.testing.allocator.alloc(graph_mod.Node, node_count);
    defer std.testing.allocator.free(nodes);
    for (nodes, 0..) |*node, index_pos| node.* = .{
        .id = .fromInt(index_pos + 1),
        .kind = .file,
        .text = "generation pressure sentinel",
    };
    try store.appendNodesBatch(nodes);

    const edges = try std.testing.allocator.alloc(graph_mod.Edge, candidate_limit + 1);
    defer std.testing.allocator.free(edges);
    for (edges, 0..) |*edge, index_pos| edge.* = .{
        .id = .fromInt(index_pos + 1),
        .src = .fromInt(index_pos + 1),
        .dst = .fromInt(node_count),
        .rel = .deprecated_by,
    };
    // The first candidate_limit rows are stale. The +1 probe row is current,
    // so bounded lookup must still recover it instead of reporting pressure.
    try store.appendEdgesBatch(edges[0..candidate_limit]);

    const property_writes = try std.testing.allocator.alloc(storage.PropertyPayloadWrite, node_count);
    defer std.testing.allocator.free(property_writes);
    for (property_writes, 0..) |*write, index_pos| write.* = .{
        .owner = .{ .node = .fromInt(index_pos + 1) },
        .key = "schema_type",
        .value = .{ .string = "generation-pressure" },
    };
    try store.appendPropertiesBatch(std.testing.allocator, property_writes);

    const cursor = NodeCursor{ .store = .{ .allocator = std.testing.allocator, .store = store } };
    var recovered = try cursor.lookupByText(std.testing.allocator, .file, "generation pressure sentinel", 1);
    defer recovered.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), recovered.items.len);
    try std.testing.expectEqual(@as(u64, candidate_limit + 1), recovered.items[0].toInt());

    // Once the probe row is stale too, a matching current row exists beyond
    // the bounded window. Exact text, property and scan paths must all fail
    // closed instead of returning an empty successful result.
    try store.appendEdgesBatch(edges[candidate_limit .. candidate_limit + 1]);
    try std.testing.expectError(
        core.Error.BudgetExceeded,
        cursor.lookupByText(std.testing.allocator, .file, "generation pressure sentinel", 1),
    );
    try std.testing.expectError(
        core.Error.BudgetExceeded,
        cursor.lookupByPropertyFilter(std.testing.allocator, .{ .single = .file }, .{
            .key = "schema_type",
            .value = "generation-pressure",
        }, 1),
    );
    try std.testing.expectError(
        core.Error.BudgetExceeded,
        cursor.scan(std.testing.allocator, .file, 1),
    );
    try std.testing.expectError(
        core.Error.BudgetExceeded,
        cursor.searchText(
            std.testing.allocator,
            "generation pressure sentinel",
            .{ .single = .file },
            1,
            10_000,
            .none,
        ),
    );
}

test "executor applies node scan text predicate before result limit" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    _ = try graph.addNode(.file, "noise.zig");
    const target = try graph.addNode(.file, "target.zig");

    var ops = std.ArrayList(optimizer.PhysicalOp).empty;
    defer ops.deinit(std.testing.allocator);
    try ops.append(std.testing.allocator, .{ .node_scan = .{
        .var_name = "f",
        .kind = .file,
        .text_eq = "target.zig",
    } });
    try ops.append(std.testing.allocator, .{ .limit = 1 });

    var table = try execute(std.testing.allocator, &graph, .{ .ops = ops });
    defer table.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), table.rows.items.len);
    try std.testing.expectEqual(target.toInt(), table.rows.items[0].get("f").?.toInt());
    try std.testing.expectEqual(@as(usize, 2), table.stats.nodes_visited);
}

test "executor marks scan text predicate candidate truncation" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    _ = try graph.addNode(.file, "noise.zig");
    _ = try graph.addNode(.file, "target.zig");

    var ops = std.ArrayList(optimizer.PhysicalOp).empty;
    defer ops.deinit(std.testing.allocator);
    try ops.append(std.testing.allocator, .{ .node_scan = .{
        .var_name = "f",
        .kind = .file,
        .text_eq = "target.zig",
    } });
    try ops.append(std.testing.allocator, .{ .limit = 1 });

    var table = try executeWithBudget(std.testing.allocator, &graph, .{ .ops = ops }, .{ .max_visited_nodes = 1 });
    defer table.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), table.rows.items.len);
    try std.testing.expectEqual(@as(usize, 1), table.stats.nodes_visited);
    try std.testing.expect(table.stats.budget_exceeded);
}

test "executor limit keeps result stats in sync" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    _ = try graph.addNode(.file, "a.zig");
    _ = try graph.addNode(.file, "b.zig");

    var ops = std.ArrayList(optimizer.PhysicalOp).empty;
    defer ops.deinit(std.testing.allocator);
    try ops.append(std.testing.allocator, .{ .node_scan = .{ .var_name = "f", .kind = .file } });
    try ops.append(std.testing.allocator, .{ .limit = 1 });

    var table = try execute(std.testing.allocator, &graph, .{ .ops = ops });
    defer table.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), table.rows.items.len);
    try std.testing.expectEqual(@as(usize, 1), table.stats.results);
}

test "executor limit zero returns without scanning expand candidates" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    const file = try graph.addNode(.file, "a.zig");
    const func = try graph.addNode(.function, "main");
    _ = try graph.addEdgeUnchecked(file, .defines, func);

    var ops = std.ArrayList(optimizer.PhysicalOp).empty;
    defer ops.deinit(std.testing.allocator);
    try ops.append(std.testing.allocator, .{ .node_scan = .{ .var_name = "f", .kind = .file } });
    try ops.append(std.testing.allocator, .{ .expand = .{ .left_var = "f", .rel = .defines, .right_var = "s", .right_kind = .function } });
    try ops.append(std.testing.allocator, .{ .limit = 0 });

    var table = try execute(std.testing.allocator, &graph, .{ .ops = ops });
    defer table.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), table.rows.items.len);
    try std.testing.expectEqual(@as(usize, 0), table.stats.results);
    try std.testing.expectEqual(@as(usize, 0), table.stats.nodes_visited);
    try std.testing.expectEqual(@as(usize, 0), table.stats.edges_visited);
    try std.testing.expect(!table.stats.budget_exceeded);
}

test "executor immediate timeout returns before scanning candidates" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    _ = try graph.addNode(.file, "a.zig");
    _ = try graph.addNode(.file, "b.zig");

    var mem_index = try index.MemoryIndex.init(std.testing.allocator, &graph);
    defer mem_index.deinit();

    var ops = std.ArrayList(optimizer.PhysicalOp).empty;
    defer ops.deinit(std.testing.allocator);
    try ops.append(std.testing.allocator, .{ .node_scan = .{ .var_name = "f", .kind = .file } });

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var table = try executeWithIndex(failing.allocator(), &graph, &mem_index, .{ .ops = ops }, .{ .timeout_ms = 0 });
    defer table.deinit(failing.allocator());
    try std.testing.expectEqual(@as(usize, 0), table.rows.items.len);
    try std.testing.expectEqual(@as(usize, 0), table.stats.nodes_visited);
    try std.testing.expectEqual(@as(usize, 0), table.stats.edges_visited);
    try std.testing.expect(table.stats.budget_exceeded);
}

test "executor exhausted node budget returns before scanning candidates" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    _ = try graph.addNode(.file, "a.zig");
    _ = try graph.addNode(.file, "b.zig");

    var mem_index = try index.MemoryIndex.init(std.testing.allocator, &graph);
    defer mem_index.deinit();

    var ops = std.ArrayList(optimizer.PhysicalOp).empty;
    defer ops.deinit(std.testing.allocator);
    try ops.append(std.testing.allocator, .{ .node_scan = .{ .var_name = "f", .kind = .file } });

    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var table = try executeWithIndex(failing.allocator(), &graph, &mem_index, .{ .ops = ops }, .{ .max_visited_nodes = 0 });
    defer table.deinit(failing.allocator());
    try std.testing.expectEqual(@as(usize, 0), table.rows.items.len);
    try std.testing.expectEqual(@as(usize, 0), table.stats.nodes_visited);
    try std.testing.expectEqual(@as(usize, 0), table.stats.edges_visited);
    try std.testing.expect(table.stats.budget_exceeded);
}

test "executor expand stops outer rows once limit is reached" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    const first_file = try graph.addNode(.file, "a.zig");
    const second_file = try graph.addNode(.file, "b.zig");
    const first_func = try graph.addNode(.function, "a");
    const second_func = try graph.addNode(.function, "b");
    _ = try graph.addEdgeUnchecked(first_file, .defines, first_func);
    _ = try graph.addEdgeUnchecked(second_file, .defines, second_func);

    var ops = std.ArrayList(optimizer.PhysicalOp).empty;
    defer ops.deinit(std.testing.allocator);
    try ops.append(std.testing.allocator, .{ .node_scan = .{ .var_name = "f", .kind = .file } });
    try ops.append(std.testing.allocator, .{ .expand = .{
        .left_var = "f",
        .rel = .defines,
        .right_var = "s",
        .right_kind = .function,
    } });
    try ops.append(std.testing.allocator, .{ .limit = 1 });

    var table = try execute(std.testing.allocator, &graph, .{ .ops = ops });
    defer table.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), table.rows.items.len);
    try std.testing.expectEqual(@as(usize, 1), table.stats.edges_visited);
    try std.testing.expectEqual(first_func.toInt(), table.rows.items[0].get("s").?.toInt());
}

test "executor undirected self loop returns one binding" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    const concept = try graph.addNode(.concept, "self");
    _ = try graph.addEdgeUnchecked(concept, .related_to, concept);

    var ops = std.ArrayList(optimizer.PhysicalOp).empty;
    defer ops.deinit(std.testing.allocator);
    try ops.append(std.testing.allocator, .{ .node_lookup_by_text = .{ .var_name = "a", .kind = .concept, .text = "self" } });
    try ops.append(std.testing.allocator, .{ .expand = .{
        .left_var = "a",
        .rel = .related_to,
        .direction = .undirected,
        .right_var = "b",
        .right_kind = .concept,
    } });

    var table = try execute(std.testing.allocator, &graph, .{ .ops = ops });
    defer table.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), table.rows.items.len);
    try std.testing.expectEqual(concept.toInt(), table.rows.items[0].get("b").?.toInt());
}

fn executorScanAllocationFailure(allocator: std.mem.Allocator) !void {
    var graph = graph_mod.Graph.init(allocator);
    defer graph.deinit();
    _ = try graph.addNode(.file, "a.zig");

    var ops = std.ArrayList(optimizer.PhysicalOp).empty;
    defer ops.deinit(allocator);
    try ops.append(allocator, .{ .node_scan = .{ .var_name = "f", .kind = .file } });

    var table = try execute(allocator, &graph, .{ .ops = ops });
    defer table.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), table.rows.items.len);
}

test "executor scan rolls back allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, executorScanAllocationFailure, .{});
}

fn executorExpandPathAllocationFailure(allocator: std.mem.Allocator) !void {
    var graph = graph_mod.Graph.init(allocator);
    defer graph.deinit();
    const file = try graph.addNode(.file, "a.zig");
    const func = try graph.addNode(.function, "main");
    _ = try graph.addEdgeUnchecked(file, .defines, func);

    var ops = std.ArrayList(optimizer.PhysicalOp).empty;
    defer ops.deinit(allocator);
    try ops.append(allocator, .{ .node_lookup_by_text = .{ .var_name = "f", .kind = .file, .text = "a.zig" } });
    try ops.append(allocator, .{ .expand = .{
        .left_var = "f",
        .rel = .defines,
        .right_var = "s",
        .right_kind = .function,
    } });

    var table = try execute(allocator, &graph, .{ .ops = ops });
    defer table.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), table.rows.items.len);
}

test "executor expand rolls back allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, executorExpandPathAllocationFailure, .{});
}

fn executorExpandFrontierAllocationFailure(allocator: std.mem.Allocator) !void {
    var graph = graph_mod.Graph.init(allocator);
    defer graph.deinit();
    const a = try graph.addNode(.task, "a");
    const b = try graph.addNode(.task, "b");
    const c = try graph.addNode(.task, "c");
    _ = try graph.addEdgeUnchecked(a, .depends_on, b);
    _ = try graph.addEdgeUnchecked(b, .depends_on, c);

    var ops = std.ArrayList(optimizer.PhysicalOp).empty;
    defer ops.deinit(allocator);
    try ops.append(allocator, .{ .node_lookup_by_text = .{ .var_name = "a", .kind = .task, .text = "a" } });
    try ops.append(allocator, .{ .expand = .{
        .left_var = "a",
        .rel = .depends_on,
        .right_var = "t",
        .right_kind = .task,
        .min_hops = 2,
        .max_hops = 2,
    } });

    var table = try execute(allocator, &graph, .{ .ops = ops });
    defer table.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), table.rows.items.len);
}

test "executor expand frontier rolls back allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, executorExpandFrontierAllocationFailure, .{});
}

test "executor expand rejects min hops beyond max depth budget" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    const a = try graph.addNode(.task, "a");
    const b = try graph.addNode(.task, "b");
    _ = try graph.addEdgeUnchecked(a, .depends_on, b);

    var ops = std.ArrayList(optimizer.PhysicalOp).empty;
    defer ops.deinit(std.testing.allocator);
    try ops.append(std.testing.allocator, .{ .node_lookup_by_text = .{ .var_name = "a", .kind = .task, .text = "a" } });
    try ops.append(std.testing.allocator, .{ .expand = .{ .left_var = "a", .rel = .depends_on, .right_var = "t", .right_kind = .task, .min_hops = 2, .max_hops = 2 } });

    var table = try executeWithBudget(std.testing.allocator, &graph, .{ .ops = ops }, .{ .max_depth = 1 });
    defer table.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), table.rows.items.len);
    try std.testing.expect(table.stats.budget_exceeded);
    try std.testing.expectEqual(@as(usize, 0), table.stats.edges_visited);
}

test "executor classifies missing persistent candidates as invalid records" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    var mem_index = try index.MemoryIndex.init(std.testing.allocator, &graph);
    defer mem_index.deinit();

    try missingCandidateNode(.{ .memory = .{ .graph = &graph, .mem_index = &mem_index } });

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    try std.testing.expectError(
        error.InvalidRecord,
        missingCandidateNode(.{ .store = .{ .allocator = std.testing.allocator, .store = store } }),
    );
}

test "executor node scan accepts schema descendant type filter" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    const human_kind: core.NodeKind = @enumFromInt(100);
    const man_kind: core.NodeKind = @enumFromInt(101);
    const woman_kind: core.NodeKind = @enumFromInt(102);
    const human = try graph.addNode(human_kind, "human");
    const man = try graph.addNode(man_kind, "man");
    const woman = try graph.addNode(woman_kind, "woman");
    _ = try graph.addNode(.task, "task");

    var type_set = schema.NodeTypeSet.empty();
    try type_set.insert(100);
    try type_set.insert(101);
    try type_set.insert(102);

    var ops = std.ArrayList(optimizer.PhysicalOp).empty;
    defer ops.deinit(std.testing.allocator);
    try ops.append(std.testing.allocator, .{ .node_scan = .{
        .var_name = "n",
        .kind = null,
        .type_filter = schema.NodeTypeFilter.fromDescendants(type_set),
    } });

    var table = try execute(std.testing.allocator, &graph, .{ .ops = ops });
    defer table.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), table.rows.items.len);
    try std.testing.expectEqual(human.toInt(), table.rows.items[0].get("n").?.toInt());
    try std.testing.expectEqual(man.toInt(), table.rows.items[1].get("n").?.toInt());
    try std.testing.expectEqual(woman.toInt(), table.rows.items[2].get("n").?.toInt());
}

test "executor expand accepts schema descendant right type filter" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    const person_kind: core.NodeKind = @enumFromInt(100);
    const man_kind: core.NodeKind = @enumFromInt(101);
    const woman_kind: core.NodeKind = @enumFromInt(102);
    const root = try graph.addNode(.concept, "root");
    const man = try graph.addNode(man_kind, "man");
    const woman = try graph.addNode(woman_kind, "woman");
    const task = try graph.addNode(.task, "task");
    _ = try graph.addEdgeUnchecked(root, .mentions, man);
    _ = try graph.addEdgeUnchecked(root, .mentions, woman);
    _ = try graph.addEdgeUnchecked(root, .mentions, task);

    var type_set = schema.NodeTypeSet.empty();
    try type_set.insert(@intFromEnum(person_kind));
    try type_set.insert(@intFromEnum(man_kind));
    try type_set.insert(@intFromEnum(woman_kind));

    var ops = std.ArrayList(optimizer.PhysicalOp).empty;
    defer ops.deinit(std.testing.allocator);
    try ops.append(std.testing.allocator, .{ .node_lookup_by_text = .{ .var_name = "r", .kind = .concept, .text = "root" } });
    try ops.append(std.testing.allocator, .{ .expand = .{
        .left_var = "r",
        .rel = .mentions,
        .right_var = "p",
        .right_kind = null,
        .right_type_filter = schema.NodeTypeFilter.fromDescendants(type_set),
    } });

    var table = try execute(std.testing.allocator, &graph, .{ .ops = ops });
    defer table.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), table.rows.items.len);
    try std.testing.expectEqual(man.toInt(), table.rows.items[0].get("p").?.toInt());
    try std.testing.expectEqual(woman.toInt(), table.rows.items[1].get("p").?.toInt());
}

test "executor expand accepts schema descendant relation type filter" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    const supports_rel: core.RelKind = @enumFromInt(100);
    const proves_rel: core.RelKind = @enumFromInt(101);
    const root = try graph.addNode(.concept, "root");
    const evidence = try graph.addNode(.evidence, "evidence");
    const verification = try graph.addNode(.verification, "verification");
    const task = try graph.addNode(.task, "task");
    _ = try graph.addEdgeUnchecked(root, supports_rel, evidence);
    _ = try graph.addEdgeUnchecked(root, proves_rel, verification);
    _ = try graph.addEdgeUnchecked(root, .mentions, task);

    var rel_set = schema.RelationTypeSet.empty();
    try rel_set.insert(@intFromEnum(supports_rel));
    try rel_set.insert(@intFromEnum(proves_rel));

    var ops = std.ArrayList(optimizer.PhysicalOp).empty;
    defer ops.deinit(std.testing.allocator);
    try ops.append(std.testing.allocator, .{ .node_lookup_by_text = .{ .var_name = "r", .kind = .concept, .text = "root" } });
    try ops.append(std.testing.allocator, .{ .expand = .{
        .left_var = "r",
        .rel = null,
        .rel_filter = schema.RelationTypeFilter.fromDescendants(rel_set),
        .right_var = "n",
        .right_kind = null,
    } });

    var table = try execute(std.testing.allocator, &graph, .{ .ops = ops });
    defer table.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), table.rows.items.len);
    try std.testing.expectEqual(evidence.toInt(), table.rows.items[0].get("n").?.toInt());
    try std.testing.expectEqual(verification.toInt(), table.rows.items[1].get("n").?.toInt());
}
