const std = @import("std");
const core = @import("core.zig");
const graph_mod = @import("graph.zig");
const index = @import("index.zig");
const query = @import("query.zig");
const storage = @import("storage.zig");

pub const ObservationInput = struct {
    task: ?core.NodeId = null,
    text: []const u8,
};

pub const IdleMaintenancePolicy = struct {
    edge_l0_every_ops: usize = 0,
    edge_l0_max_segments: usize = 0,
    edge_l0_max_edges: u64 = 0,
    edge_gc_every_ops: usize = 0,
    node_text_delta_every_ops: usize = 0,
    node_text_delta_max_records: u64 = 0,
    node_text_run_every_ops: usize = 0,
    node_text_run_max_records: u64 = 0,

    pub const disabled = IdleMaintenancePolicy{};
    pub const edge_l0_maint10s16e64 = IdleMaintenancePolicy{
        .edge_l0_every_ops = 10,
        .edge_l0_max_segments = 16,
        .edge_l0_max_edges = 64,
    };

    pub fn shouldMaintainEdgeL0(self: IdleMaintenancePolicy, completed_append_ops: usize) bool {
        return self.edge_l0_every_ops != 0 and
            completed_append_ops != 0 and
            completed_append_ops % self.edge_l0_every_ops == 0;
    }

    pub fn shouldMaintainEdgeGc(self: IdleMaintenancePolicy, completed_append_ops: usize) bool {
        return self.edge_gc_every_ops != 0 and
            completed_append_ops != 0 and
            completed_append_ops % self.edge_gc_every_ops == 0;
    }

    pub fn shouldMaintainNodeTextDelta(self: IdleMaintenancePolicy, completed_append_ops: usize) bool {
        return self.node_text_delta_every_ops != 0 and
            completed_append_ops != 0 and
            completed_append_ops % self.node_text_delta_every_ops == 0;
    }

    pub fn shouldMaintainNodeTextRuns(self: IdleMaintenancePolicy, completed_append_ops: usize) bool {
        return self.node_text_run_every_ops != 0 and
            completed_append_ops != 0 and
            completed_append_ops % self.node_text_run_every_ops == 0;
    }
};

pub const IdleMaintenanceResult = struct {
    edge_l0_ran: bool = false,
    edge_l0: storage.EdgeSegmentMaintenanceResult = .{ .compacted = false },
    edge_gc_ran: bool = false,
    edge_gc: storage.EdgeSegmentGcResult = .{},
    node_text_delta_ran: bool = false,
    node_text_delta: storage.NodeTextDeltaMaintenanceResult = .{ .compacted = false },
    node_text_runs_ran: bool = false,
    node_text_runs: storage.NodeTextRunMaintenanceResult = .{ .compacted = false },
};

pub const IdleMaintenanceStats = struct {
    append_ops: usize = 0,
    maintenance_ops: usize = 0,
    maintenance_compactions: usize = 0,
    maintenance_compacted_edges: u64 = 0,
    maintenance_compacted_segments: usize = 0,
    maintenance_gc_deleted_segments: u64 = 0,
    maintenance_gc_deleted_manifests: u64 = 0,
    maintenance_entries_before_last: usize = 0,
    maintenance_entries_after_last: usize = 0,
    node_text_delta_compactions: usize = 0,
    node_text_delta_records_compacted: u64 = 0,
    node_text_delta_records_before_last: u64 = 0,
    node_text_delta_records_after_last: u64 = 0,
    node_text_run_compactions: usize = 0,
    node_text_run_records_compacted: u64 = 0,
    node_text_run_entries_before_last: usize = 0,
    node_text_run_entries_after_last: usize = 0,
    node_text_run_records_before_last: u64 = 0,
    node_text_run_records_after_last: u64 = 0,
    node_text_run_gc_deleted_runs: u64 = 0,

    fn recordAppend(self: *IdleMaintenanceStats) !void {
        self.append_ops = std.math.add(usize, self.append_ops, 1) catch return error.RecordTooLarge;
    }

    fn recordMaintenance(self: *IdleMaintenanceStats, result: IdleMaintenanceResult) !void {
        if (!result.edge_l0_ran and !result.edge_gc_ran and !result.node_text_delta_ran and !result.node_text_runs_ran) return;
        self.maintenance_ops = std.math.add(usize, self.maintenance_ops, 1) catch return error.RecordTooLarge;
        if (result.edge_l0_ran) {
            self.maintenance_entries_before_last = result.edge_l0.manifest_entries_before;
            self.maintenance_entries_after_last = result.edge_l0.manifest_entries_after;
            if (result.edge_l0.compacted) {
                self.maintenance_compactions = std.math.add(usize, self.maintenance_compactions, 1) catch return error.RecordTooLarge;
                self.maintenance_compacted_edges = std.math.add(u64, self.maintenance_compacted_edges, result.edge_l0.compacted_edges) catch return error.RecordTooLarge;
                self.maintenance_compacted_segments = std.math.add(usize, self.maintenance_compacted_segments, result.edge_l0.compacted_segments) catch return error.RecordTooLarge;
                self.maintenance_gc_deleted_segments = std.math.add(u64, self.maintenance_gc_deleted_segments, result.edge_l0.gc_deleted_segments) catch return error.RecordTooLarge;
                self.maintenance_gc_deleted_manifests = std.math.add(u64, self.maintenance_gc_deleted_manifests, result.edge_l0.gc_deleted_manifests) catch return error.RecordTooLarge;
            }
        }
        if (result.edge_gc_ran) {
            self.maintenance_gc_deleted_segments = std.math.add(u64, self.maintenance_gc_deleted_segments, result.edge_gc.deleted_segments) catch return error.RecordTooLarge;
            self.maintenance_gc_deleted_manifests = std.math.add(u64, self.maintenance_gc_deleted_manifests, result.edge_gc.deleted_manifests) catch return error.RecordTooLarge;
        }
        if (result.node_text_delta_ran) {
            self.node_text_delta_records_before_last = result.node_text_delta.delta_records_before;
            self.node_text_delta_records_after_last = result.node_text_delta.delta_records_after;
            if (result.node_text_delta.compacted) {
                self.node_text_delta_compactions = std.math.add(usize, self.node_text_delta_compactions, 1) catch return error.RecordTooLarge;
                self.node_text_delta_records_compacted = std.math.add(u64, self.node_text_delta_records_compacted, result.node_text_delta.delta_records_before) catch return error.RecordTooLarge;
            }
        }
        if (result.node_text_runs_ran) {
            self.node_text_run_entries_before_last = result.node_text_runs.run_entries_before;
            self.node_text_run_entries_after_last = result.node_text_runs.run_entries_after;
            self.node_text_run_records_before_last = result.node_text_runs.run_records_before;
            self.node_text_run_records_after_last = result.node_text_runs.run_records_after;
            if (result.node_text_runs.compacted) {
                self.node_text_run_compactions = std.math.add(usize, self.node_text_run_compactions, 1) catch return error.RecordTooLarge;
                self.node_text_run_records_compacted = std.math.add(u64, self.node_text_run_records_compacted, result.node_text_runs.compacted_run_records) catch return error.RecordTooLarge;
                self.node_text_run_gc_deleted_runs = std.math.add(u64, self.node_text_run_gc_deleted_runs, result.node_text_runs.gc_deleted_runs) catch return error.RecordTooLarge;
            }
        }
    }
};

pub const AgentWriteSession = struct {
    store: storage.Store,
    policy: IdleMaintenancePolicy = .disabled,
    stats: IdleMaintenanceStats = .{},

    pub fn init(store: storage.Store, policy: IdleMaintenancePolicy) AgentWriteSession {
        return .{ .store = store, .policy = policy };
    }

    pub fn recordAppendAndMaintain(self: *AgentWriteSession) !IdleMaintenanceResult {
        return self.recordAppendAndMaintainWithPinnedEdgeManifests(&.{});
    }

    pub fn recordAppendAndMaintainWithPinnedEdgeManifests(self: *AgentWriteSession, pinned_edge_segment_manifest_paths: []const []const u8) !IdleMaintenanceResult {
        try self.stats.recordAppend();
        const result = try runIdleMaintenanceWithPinnedEdgeManifests(self.store, self.policy, self.stats.append_ops, pinned_edge_segment_manifest_paths);
        try self.stats.recordMaintenance(result);
        return result;
    }

    pub fn recordAppendAndMaintainWithEdgeRetentionWindow(self: *AgentWriteSession, retention_window: *const storage.EdgeSegmentRetentionWindow) !IdleMaintenanceResult {
        return self.recordAppendAndMaintainWithPinnedEdgeManifests(retention_window.pinnedManifestPaths());
    }

    pub fn recordAppendAndMaintainWithEdgeRetentionRegistry(self: *AgentWriteSession, retention_registry: *const storage.EdgeSegmentRetentionRegistry) !IdleMaintenanceResult {
        return self.recordAppendAndMaintainWithRetentionRegistries(retention_registry, null);
    }

    pub fn recordAppendAndMaintainWithRetentionRegistries(
        self: *AgentWriteSession,
        edge_retention_registry: ?*const storage.EdgeSegmentRetentionRegistry,
        node_text_retention_registry: ?*const storage.NodeTextRunRetentionRegistry,
    ) !IdleMaintenanceResult {
        try self.stats.recordAppend();
        const result = try runIdleMaintenanceWithRetentionRegistries(self.store, self.policy, self.stats.append_ops, edge_retention_registry, node_text_retention_registry);
        try self.stats.recordMaintenance(result);
        return result;
    }
};

pub fn runIdleMaintenance(store: storage.Store, policy: IdleMaintenancePolicy, completed_append_ops: usize) !IdleMaintenanceResult {
    return runIdleMaintenanceWithPinnedEdgeManifests(store, policy, completed_append_ops, &.{});
}

pub fn runIdleMaintenanceWithPinnedEdgeManifests(
    store: storage.Store,
    policy: IdleMaintenancePolicy,
    completed_append_ops: usize,
    pinned_edge_segment_manifest_paths: []const []const u8,
) !IdleMaintenanceResult {
    return runIdleMaintenanceWithPinnedManifests(store, policy, completed_append_ops, pinned_edge_segment_manifest_paths, &.{});
}

pub fn runIdleMaintenanceWithPinnedManifests(
    store: storage.Store,
    policy: IdleMaintenancePolicy,
    completed_append_ops: usize,
    pinned_edge_segment_manifest_paths: []const []const u8,
    pinned_node_text_run_manifest_paths: []const []const u8,
) !IdleMaintenanceResult {
    var result = IdleMaintenanceResult{};
    if (policy.shouldMaintainEdgeL0(completed_append_ops)) {
        result.edge_l0_ran = true;
        result.edge_l0 = try store.compactEdgeSegmentsBudgetedExceptAndProcessLeases(.{
            .max_segments = policy.edge_l0_max_segments,
            .max_edges = policy.edge_l0_max_edges,
        }, pinned_edge_segment_manifest_paths);
    }
    if (policy.shouldMaintainEdgeGc(completed_append_ops)) {
        result.edge_gc_ran = true;
        result.edge_gc = try store.gcUnreferencedEdgeSegmentsExceptAndProcessLeases(pinned_edge_segment_manifest_paths);
    }
    if (policy.shouldMaintainNodeTextDelta(completed_append_ops)) {
        result.node_text_delta_ran = true;
        result.node_text_delta = try store.compactNodeTextDeltaBudgeted(policy.node_text_delta_max_records);
    }
    if (policy.shouldMaintainNodeTextRuns(completed_append_ops)) {
        result.node_text_runs_ran = true;
        result.node_text_runs = try store.compactNodeTextRunsBudgetedExceptAndProcessLeases(policy.node_text_run_max_records, pinned_node_text_run_manifest_paths);
    }
    return result;
}

pub fn runIdleMaintenanceWithEdgeRetentionWindow(
    store: storage.Store,
    policy: IdleMaintenancePolicy,
    completed_append_ops: usize,
    retention_window: *const storage.EdgeSegmentRetentionWindow,
) !IdleMaintenanceResult {
    return runIdleMaintenanceWithPinnedEdgeManifests(store, policy, completed_append_ops, retention_window.pinnedManifestPaths());
}

pub fn runIdleMaintenanceWithEdgeRetentionRegistry(
    store: storage.Store,
    policy: IdleMaintenancePolicy,
    completed_append_ops: usize,
    retention_registry: *const storage.EdgeSegmentRetentionRegistry,
) !IdleMaintenanceResult {
    return runIdleMaintenanceWithRetentionRegistries(store, policy, completed_append_ops, retention_registry, null);
}

pub fn runIdleMaintenanceWithRetentionRegistries(
    store: storage.Store,
    policy: IdleMaintenancePolicy,
    completed_append_ops: usize,
    edge_retention_registry: ?*const storage.EdgeSegmentRetentionRegistry,
    node_text_retention_registry: ?*const storage.NodeTextRunRetentionRegistry,
) !IdleMaintenanceResult {
    const need_edge_pins = policy.shouldMaintainEdgeL0(completed_append_ops) or policy.shouldMaintainEdgeGc(completed_append_ops);
    const need_node_text_pins = policy.shouldMaintainNodeTextRuns(completed_append_ops);

    const edge_pinned_paths = if (need_edge_pins and edge_retention_registry != null)
        try edge_retention_registry.?.activeManifestPaths(store.allocator)
    else
        &.{};
    defer if (need_edge_pins and edge_retention_registry != null) store.allocator.free(edge_pinned_paths);

    const node_text_pinned_paths = if (need_node_text_pins and node_text_retention_registry != null)
        try node_text_retention_registry.?.activeManifestPaths(store.allocator)
    else
        &.{};
    defer if (need_node_text_pins and node_text_retention_registry != null) store.allocator.free(node_text_pinned_paths);

    return runIdleMaintenanceWithPinnedManifests(store, policy, completed_append_ops, edge_pinned_paths, node_text_pinned_paths);
}

pub fn recordObservation(graph: *graph_mod.Graph, input: ObservationInput) !core.NodeId {
    if (input.task) |task| {
        if (isReservedNodeId(task)) return core.Error.InvalidId;
        const task_node = graph.getNode(task) orelse return core.Error.NotFound;
        if (task_node.kind != .task) return core.Error.InvalidId;
    }
    const observation = try graph.addNode(.observation, input.text);
    var observation_committed = false;
    errdefer if (!observation_committed) rollbackLastObservation(graph, observation);
    const node = graphNodeById(graph, observation) orelse return core.Error.InvalidId;
    node.epistemic_status = .observed;
    if (input.task) |task| {
        _ = try graph.addEdgeUnchecked(task, .evidences, observation);
    }
    observation_committed = true;
    return observation;
}

fn graphNodeById(graph: *graph_mod.Graph, id: core.NodeId) ?*graph_mod.Node {
    for (graph.nodes.items) |*node| {
        if (node.id.toInt() == id.toInt()) return node;
    }
    return null;
}

fn rollbackLastObservation(graph: *graph_mod.Graph, id: core.NodeId) void {
    _ = graph.removeLastNodeIfId(id);
}

pub const ContextPacket = struct {
    focus: core.NodeId,
    max_facts: usize,
    facts: std.ArrayList(ContextFact),

    pub fn deinit(self: *ContextPacket, allocator: std.mem.Allocator) void {
        self.facts.deinit(allocator);
    }
};

pub const ContextFact = struct {
    node_id: core.NodeId,
    edge_id: core.EdgeId,
    rel: core.RelKind,
    direction: Direction,
    score: u16,

    pub const Direction = enum {
        outgoing,
        incoming,
    };
};

pub fn contextPacket(allocator: std.mem.Allocator, graph: *const graph_mod.Graph, focus: core.NodeId, max_facts: usize) !ContextPacket {
    var mem_index = try index.MemoryIndex.init(allocator, graph);
    defer mem_index.deinit();
    return contextPacketWithIndex(allocator, graph, &mem_index, focus, max_facts);
}

pub fn contextPacketWithIndex(allocator: std.mem.Allocator, graph: *const graph_mod.Graph, mem_index: *index.MemoryIndex, focus: core.NodeId, max_facts: usize) !ContextPacket {
    return contextPacketWithCursor(allocator, graph, mem_index, .{ .memory = .{ .mem_index = mem_index } }, focus, max_facts);
}

pub fn contextPacketWithCursor(
    allocator: std.mem.Allocator,
    graph: *const graph_mod.Graph,
    mem_index: *index.MemoryIndex,
    edge_cursor: query.EdgeCursor,
    focus: core.NodeId,
    max_facts: usize,
) !ContextPacket {
    if (isReservedNodeId(focus)) return core.Error.InvalidId;
    if (mem_index.getNode(graph, focus) == null) return core.Error.NotFound;
    var facts = std.ArrayList(ContextFact).empty;
    errdefer facts.deinit(allocator);
    if (max_facts == 0) return .{ .focus = focus, .max_facts = max_facts, .facts = facts };

    var outgoing_context = ContextCollectContext{
        .allocator = allocator,
        .facts = &facts,
        .max_facts = max_facts,
        .direction = .outgoing,
        .node_lookup = .{ .memory = .{ .graph = graph, .mem_index = mem_index } },
    };
    _ = try edge_cursor.forEachOutgoing(focus, &outgoing_context, collectContextFact);

    var incoming_context = ContextCollectContext{
        .allocator = allocator,
        .facts = &facts,
        .max_facts = max_facts,
        .direction = .incoming,
        .node_lookup = .{ .memory = .{ .graph = graph, .mem_index = mem_index } },
    };
    _ = try edge_cursor.forEachIncoming(focus, &incoming_context, collectContextFact);

    std.mem.sort(ContextFact, facts.items, {}, contextFactLessThan);
    return .{ .focus = focus, .max_facts = max_facts, .facts = facts };
}

pub fn contextPacketWithPersistentStore(
    allocator: std.mem.Allocator,
    store: storage.Store,
    focus: core.NodeId,
    max_facts: usize,
) !ContextPacket {
    return contextPacketWithPersistentStoreBudget(allocator, store, focus, max_facts, .{});
}

pub fn contextPacketWithPersistentStoreBudget(
    allocator: std.mem.Allocator,
    store: storage.Store,
    focus: core.NodeId,
    max_facts: usize,
    budget: core.QueryBudget,
) !ContextPacket {
    var stats: index.QueryStats = .{};
    return contextPacketWithPersistentStoreMeasured(allocator, store, focus, max_facts, budget, &stats);
}

pub fn contextPacketWithPersistentStoreBudgetRetained(
    allocator: std.mem.Allocator,
    store: storage.Store,
    edge_retention_registry: *storage.EdgeSegmentRetentionRegistry,
    focus: core.NodeId,
    max_facts: usize,
    budget: core.QueryBudget,
) !ContextPacket {
    var stats: index.QueryStats = .{};
    return contextPacketWithPersistentStoreMeasuredRetained(allocator, store, edge_retention_registry, focus, max_facts, budget, &stats);
}

pub fn contextPacketWithPersistentStoreMeasured(
    allocator: std.mem.Allocator,
    store: storage.Store,
    focus: core.NodeId,
    max_facts: usize,
    budget: core.QueryBudget,
    stats: *index.QueryStats,
) !ContextPacket {
    return contextPacketWithPersistentStoreMeasuredMaybeRetained(allocator, store, null, focus, max_facts, budget, stats);
}

pub fn contextPacketWithPersistentStoreMeasuredRetained(
    allocator: std.mem.Allocator,
    store: storage.Store,
    edge_retention_registry: *storage.EdgeSegmentRetentionRegistry,
    focus: core.NodeId,
    max_facts: usize,
    budget: core.QueryBudget,
    stats: *index.QueryStats,
) !ContextPacket {
    return contextPacketWithPersistentStoreMeasuredMaybeRetained(allocator, store, edge_retention_registry, focus, max_facts, budget, stats);
}

fn contextPacketWithPersistentStoreMeasuredMaybeRetained(
    allocator: std.mem.Allocator,
    store: storage.Store,
    edge_retention_registry: ?*storage.EdgeSegmentRetentionRegistry,
    focus: core.NodeId,
    max_facts: usize,
    budget: core.QueryBudget,
    stats: *index.QueryStats,
) !ContextPacket {
    var repaired = false;
    while (true) {
        const baseline_nodes = stats.nodes_visited;
        const baseline_edges = stats.edges_visited;
        return contextPacketWithPersistentStoreOnce(allocator, store, edge_retention_registry, focus, max_facts, budget, stats, baseline_nodes, baseline_edges) catch |err| switch (err) {
            error.FileNotFound, error.InvalidRecord => {
                if (repaired) return err;
                repaired = true;
                stats.nodes_visited = baseline_nodes;
                stats.edges_visited = baseline_edges;
                try store.repairPersistentIndexesFromLog();
                continue;
            },
            else => |e| return e,
        };
    }
}

fn contextPacketWithPersistentStoreOnce(
    allocator: std.mem.Allocator,
    store: storage.Store,
    edge_retention_registry: ?*storage.EdgeSegmentRetentionRegistry,
    focus: core.NodeId,
    max_facts: usize,
    budget: core.QueryBudget,
    stats: *index.QueryStats,
    budget_start_nodes: usize,
    budget_start_edges: usize,
) !ContextPacket {
    if (isReservedNodeId(focus)) return core.Error.InvalidId;
    const deadline = core.QueryDeadline.fromIo(store.io, budget.timeout_ms);
    if (deadline.expired()) return core.Error.BudgetExceeded;
    var node_view = try store.openNodeByIdIndexView();
    defer node_view.deinit();
    if (!try node_view.nodeExists(focus)) return core.Error.NotFound;

    var facts = std.ArrayList(ContextFact).empty;
    errdefer facts.deinit(allocator);
    if (max_facts == 0) return .{ .focus = focus, .max_facts = max_facts, .facts = facts };

    const cursor = query.EdgeCursor{ .persistent_store = .{
        .allocator = allocator,
        .store = store,
        .edge_retention_registry = edge_retention_registry,
    } };
    const node_lookup = query.NodeLookup{ .persistent_store = .{ .store = store, .node_view = &node_view, .missing_is_invalid = true } };
    var outgoing_context = ContextCollectContext{
        .allocator = allocator,
        .facts = &facts,
        .max_facts = max_facts,
        .direction = .outgoing,
        .node_lookup = node_lookup,
        .budget = budget,
        .stats = stats,
        .budget_start_nodes = budget_start_nodes,
        .budget_start_edges = budget_start_edges,
        .deadline = deadline,
    };
    _ = try cursor.forEachOutgoing(focus, &outgoing_context, collectContextFact);

    var incoming_context = ContextCollectContext{
        .allocator = allocator,
        .facts = &facts,
        .max_facts = max_facts,
        .direction = .incoming,
        .node_lookup = node_lookup,
        .budget = budget,
        .stats = stats,
        .budget_start_nodes = budget_start_nodes,
        .budget_start_edges = budget_start_edges,
        .deadline = deadline,
    };
    _ = try cursor.forEachIncoming(focus, &incoming_context, collectContextFact);

    std.mem.sort(ContextFact, facts.items, {}, contextFactLessThan);
    return .{ .focus = focus, .max_facts = max_facts, .facts = facts };
}

fn relationScore(rel: core.RelKind) u16 {
    return switch (rel) {
        .defines, .depends_on, .blocks, .evidences, .verified_by => 80,
        .contains, .calls, .imports, .derived_from, .summarizes => 60,
        .mentions, .references, .explains, .based_on => 40,
        else => 20,
    };
}

const ContextCollectContext = struct {
    allocator: std.mem.Allocator,
    facts: *std.ArrayList(ContextFact),
    max_facts: usize,
    direction: ContextFact.Direction,
    node_lookup: query.NodeLookup,
    budget: ?core.QueryBudget = null,
    stats: ?*index.QueryStats = null,
    budget_start_nodes: usize = 0,
    budget_start_edges: usize = 0,
    deadline: core.QueryDeadline = .none,
};

fn collectContextFact(ctx: *ContextCollectContext, edge: index.EdgeRef) !bool {
    if (ctx.deadline.expired()) return core.Error.BudgetExceeded;
    if (ctx.stats) |stats| {
        const budget = ctx.budget orelse return core.Error.Unsupported;
        if (stats.edges_visited - ctx.budget_start_edges >= budget.max_visited_edges) return core.Error.BudgetExceeded;
        try index.addVisitedEdges(stats, 1);
    }
    switch (ctx.direction) {
        .outgoing => {
            try chargeContextNode(ctx);
            const exists = try ctx.node_lookup.exists(edge.dst);
            if (!exists) return false;
            try countContextNode(ctx);
            try appendContextFactBounded(ctx.allocator, ctx.facts, ctx.max_facts, .{
                .node_id = edge.dst,
                .edge_id = edge.edge_id,
                .rel = edge.rel,
                .direction = .outgoing,
                .score = relationScore(edge.rel) + 20,
            });
        },
        .incoming => {
            if (edge.src.toInt() == edge.dst.toInt()) return false;
            try chargeContextNode(ctx);
            const exists = try ctx.node_lookup.exists(edge.src);
            if (!exists) return false;
            try countContextNode(ctx);
            try appendContextFactBounded(ctx.allocator, ctx.facts, ctx.max_facts, .{
                .node_id = edge.src,
                .edge_id = edge.edge_id,
                .rel = edge.rel,
                .direction = .incoming,
                .score = relationScore(edge.rel),
            });
        },
    }
    return false;
}

fn chargeContextNode(ctx: *ContextCollectContext) !void {
    const stats = ctx.stats orelse return;
    const budget = ctx.budget orelse return core.Error.Unsupported;
    if (stats.nodes_visited - ctx.budget_start_nodes >= budget.max_visited_nodes) return core.Error.BudgetExceeded;
}

fn countContextNode(ctx: *ContextCollectContext) !void {
    const stats = ctx.stats orelse return;
    try index.addVisitedNodes(stats, 1);
}

fn contextFactLessThan(_: void, lhs: ContextFact, rhs: ContextFact) bool {
    if (lhs.score != rhs.score) return lhs.score > rhs.score;
    if (@intFromEnum(lhs.rel) != @intFromEnum(rhs.rel)) return @intFromEnum(lhs.rel) < @intFromEnum(rhs.rel);
    if (lhs.node_id.toInt() != rhs.node_id.toInt()) return lhs.node_id.toInt() < rhs.node_id.toInt();
    return lhs.edge_id.toInt() < rhs.edge_id.toInt();
}

fn appendContextFactBounded(allocator: std.mem.Allocator, facts: *std.ArrayList(ContextFact), max_facts: usize, fact: ContextFact) !void {
    if (max_facts == 0) return;
    if (facts.items.len < max_facts) {
        try facts.append(allocator, fact);
        return;
    }

    var worst_index: usize = 0;
    for (facts.items[1..], 1..) |candidate, i| {
        if (contextFactLessThan({}, facts.items[worst_index], candidate)) {
            worst_index = i;
        }
    }
    if (contextFactLessThan({}, fact, facts.items[worst_index])) {
        facts.items[worst_index] = fact;
    }
}

fn isReservedNodeId(id: core.NodeId) bool {
    return id == .none or id.toInt() == std.math.maxInt(u64);
}

test "record observation marks observed status and links task" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();

    const task = try graph.addNode(.task, "fix parser");
    const observation = try recordObservation(&graph, .{ .task = task, .text = "test failed" });

    try std.testing.expectEqual(core.EpistemicStatus.observed, graph.getNode(observation).?.epistemic_status);
    try std.testing.expectEqual(@as(usize, 1), graph.edges.items.len);
}

test "idle maintenance policy gates budgeted edge L0 compaction" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage.Store.initWithOptions(std.testing.allocator, std.testing.io, store_path, .{
        .durability = .fast,
        .validate_indexes_on_read = false,
        .auto_compact_edge_segment_entries = 0,
    });
    defer store.deinit();
    try store.createEmpty();

    try store.appendNode(.{ .id = .fromInt(1), .kind = .file, .text = "a.zig" });
    try store.appendNode(.{ .id = .fromInt(2), .kind = .function, .text = "base" });
    try store.appendNode(.{ .id = .fromInt(3), .kind = .function, .text = "delta_a" });
    try store.appendNode(.{ .id = .fromInt(4), .kind = .function, .text = "delta_b" });
    try store.appendNode(.{ .id = .fromInt(5), .kind = .function, .text = "delta_c" });
    try store.appendNode(.{ .id = .fromInt(6), .kind = .function, .text = "delta_d" });

    var base_edges = std.ArrayList(graph_mod.Edge).empty;
    defer base_edges.deinit(std.testing.allocator);
    try base_edges.ensureTotalCapacity(std.testing.allocator, 1024);
    var edge_id: u64 = 1;
    while (edge_id <= 1024) : (edge_id += 1) {
        base_edges.appendAssumeCapacity(.{
            .id = .fromInt(edge_id),
            .src = .fromInt(1),
            .rel = .mentions,
            .dst = .fromInt(2),
        });
    }
    try store.appendEdgesBatch(base_edges.items);
    try store.appendEdgesBatch(&.{.{ .id = .fromInt(1025), .src = .fromInt(1), .rel = .mentions, .dst = .fromInt(3) }});
    try store.appendEdgesBatch(&.{.{ .id = .fromInt(1026), .src = .fromInt(1), .rel = .defines, .dst = .fromInt(4) }});

    try std.testing.expect(!IdleMaintenancePolicy.disabled.shouldMaintainEdgeL0(2));
    try std.testing.expect(!IdleMaintenancePolicy.disabled.shouldMaintainEdgeGc(2));
    try std.testing.expect(!IdleMaintenancePolicy.edge_l0_maint10s16e64.shouldMaintainEdgeL0(9));
    try std.testing.expect(IdleMaintenancePolicy.edge_l0_maint10s16e64.shouldMaintainEdgeL0(10));
    try std.testing.expectEqual(@as(usize, 16), IdleMaintenancePolicy.edge_l0_maint10s16e64.edge_l0_max_segments);
    try std.testing.expectEqual(@as(u64, 64), IdleMaintenancePolicy.edge_l0_maint10s16e64.edge_l0_max_edges);

    const skipped = try runIdleMaintenance(store, .{ .edge_l0_every_ops = 2, .edge_l0_max_segments = 2, .edge_l0_max_edges = 2 }, 1);
    try std.testing.expect(!skipped.edge_l0_ran);
    try std.testing.expect(!skipped.edge_l0.compacted);

    const maintained = try runIdleMaintenance(store, .{ .edge_l0_every_ops = 2, .edge_l0_max_segments = 2, .edge_l0_max_edges = 2 }, 2);
    try std.testing.expect(maintained.edge_l0_ran);
    try std.testing.expect(maintained.edge_l0.compacted);
    try std.testing.expectEqual(@as(u64, 2), maintained.edge_l0.compacted_edges);
    try std.testing.expectEqual(@as(usize, 2), maintained.edge_l0.compacted_segments);
    try std.testing.expectEqual(@as(usize, 2), maintained.edge_l0.manifest_entries_before);
    try std.testing.expectEqual(@as(usize, 1), maintained.edge_l0.manifest_entries_after);

    try store.appendEdgesBatch(&.{.{ .id = .fromInt(1027), .src = .fromInt(1), .rel = .mentions, .dst = .fromInt(5) }});
    try store.appendEdgesBatch(&.{.{ .id = .fromInt(1028), .src = .fromInt(1), .rel = .defines, .dst = .fromInt(6) }});

    var session = AgentWriteSession.init(store, .{ .edge_l0_every_ops = 2, .edge_l0_max_segments = 2, .edge_l0_max_edges = 2 });
    const first_session_result = try session.recordAppendAndMaintain();
    try std.testing.expect(!first_session_result.edge_l0_ran);
    try std.testing.expectEqual(@as(usize, 1), session.stats.append_ops);
    try std.testing.expectEqual(@as(usize, 0), session.stats.maintenance_ops);

    const second_session_result = try session.recordAppendAndMaintain();
    try std.testing.expect(second_session_result.edge_l0_ran);
    try std.testing.expect(second_session_result.edge_l0.compacted);
    try std.testing.expectEqual(@as(usize, 2), session.stats.append_ops);
    try std.testing.expectEqual(@as(usize, 1), session.stats.maintenance_ops);
    try std.testing.expectEqual(@as(usize, 1), session.stats.maintenance_compactions);
    try std.testing.expectEqual(@as(u64, 2), session.stats.maintenance_compacted_edges);
    try std.testing.expectEqual(@as(usize, 2), session.stats.maintenance_compacted_segments);
    try std.testing.expectEqual(@as(u64, 0), session.stats.maintenance_gc_deleted_segments);
    try std.testing.expectEqual(@as(u64, 0), session.stats.maintenance_gc_deleted_manifests);
    try std.testing.expectEqual(@as(usize, 3), session.stats.maintenance_entries_before_last);
    try std.testing.expectEqual(@as(usize, 2), session.stats.maintenance_entries_after_last);
}

test "idle maintenance edge gc preserves pinned epoch manifests" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);
    const segment_path = try std.fs.path.join(std.testing.allocator, &.{ store_path, "edge_segments", "compacted" });
    defer std.testing.allocator.free(segment_path);

    var store = try storage.Store.initWithOptions(std.testing.allocator, std.testing.io, store_path, .{
        .durability = .fast,
        .validate_indexes_on_read = false,
        .auto_compact_edge_segment_entries = 0,
    });
    defer store.deinit();
    try store.createEmpty();

    try store.appendNode(.{ .id = .fromInt(1), .kind = .file, .text = "a.zig" });
    try store.appendNode(.{ .id = .fromInt(2), .kind = .function, .text = "base" });
    try store.appendNode(.{ .id = .fromInt(3), .kind = .function, .text = "delta_a" });
    try store.appendNode(.{ .id = .fromInt(4), .kind = .function, .text = "delta_b" });

    var base_edges = std.ArrayList(graph_mod.Edge).empty;
    defer base_edges.deinit(std.testing.allocator);
    try base_edges.ensureTotalCapacity(std.testing.allocator, 1024);
    var edge_id: u64 = 1;
    while (edge_id <= 1024) : (edge_id += 1) {
        base_edges.appendAssumeCapacity(.{
            .id = .fromInt(edge_id),
            .src = .fromInt(1),
            .rel = .mentions,
            .dst = .fromInt(2),
        });
    }
    try store.appendEdgesBatch(base_edges.items);
    try store.appendEdgesBatch(&.{.{ .id = .fromInt(1025), .src = .fromInt(1), .rel = .mentions, .dst = .fromInt(3) }});
    try store.appendEdgesBatch(&.{.{ .id = .fromInt(1026), .src = .fromInt(1), .rel = .mentions, .dst = .fromInt(4) }});

    var retention_registry = storage.EdgeSegmentRetentionRegistry.init(std.testing.allocator);
    defer retention_registry.deinit();
    var retention_window = try store.openRegisteredEdgeSegmentRetentionWindow(&retention_registry);
    defer retention_window.deinit();
    var duplicate_window = try store.openRegisteredEdgeSegmentRetentionWindow(&retention_registry);
    defer duplicate_window.deinit();
    {
        const active_paths = try retention_registry.activeManifestPaths(std.testing.allocator);
        defer std.testing.allocator.free(active_paths);
        try std.testing.expectEqual(@as(usize, 1), active_paths.len);
    }
    try std.testing.expectEqual(@as(u64, 1026), try store.compactPublishedEdgeSegments(segment_path));

    const skipped = try runIdleMaintenanceWithEdgeRetentionRegistry(store, .{ .edge_gc_every_ops = 2 }, 1, &retention_registry);
    try std.testing.expect(!skipped.edge_gc_ran);

    var session = AgentWriteSession.init(store, .{ .edge_gc_every_ops = 2 });
    const first = try session.recordAppendAndMaintainWithEdgeRetentionRegistry(&retention_registry);
    try std.testing.expect(!first.edge_gc_ran);
    const pinned_gc = try session.recordAppendAndMaintainWithEdgeRetentionRegistry(&retention_registry);
    try std.testing.expect(pinned_gc.edge_gc_ran);
    try std.testing.expectEqual(@as(u64, 0), pinned_gc.edge_gc.deleted_segments);
    try std.testing.expectEqual(@as(u64, 1), pinned_gc.edge_gc.deleted_manifests);
    try std.testing.expectEqual(@as(usize, 2), session.stats.append_ops);
    try std.testing.expectEqual(@as(usize, 1), session.stats.maintenance_ops);
    try std.testing.expectEqual(@as(u64, 0), session.stats.maintenance_gc_deleted_segments);
    try std.testing.expectEqual(@as(u64, 1), session.stats.maintenance_gc_deleted_manifests);

    duplicate_window.deinit();
    {
        const active_paths = try retention_registry.activeManifestPaths(std.testing.allocator);
        defer std.testing.allocator.free(active_paths);
        try std.testing.expectEqual(@as(usize, 1), active_paths.len);
    }
    retention_window.deinit();
    {
        const active_paths = try retention_registry.activeManifestPaths(std.testing.allocator);
        defer std.testing.allocator.free(active_paths);
        try std.testing.expectEqual(@as(usize, 0), active_paths.len);
    }

    const final_gc = try runIdleMaintenanceWithEdgeRetentionRegistry(store, .{ .edge_gc_every_ops = 1 }, 1, &retention_registry);
    try std.testing.expect(final_gc.edge_gc_ran);
    try std.testing.expectEqual(@as(u64, 0), final_gc.edge_gc.deleted_segments);
    try std.testing.expectEqual(@as(u64, 1), final_gc.edge_gc.deleted_manifests);
}

test "idle maintenance policy compacts buffered single node text delta" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage.Store.initWithOptions(std.testing.allocator, std.testing.io, store_path, .{
        .durability = .fast,
        .validate_indexes_on_read = false,
    });
    defer store.deinit();
    try store.createEmpty();

    try store.appendNode(.{ .id = .fromInt(10), .kind = .repo, .text = "shared" });
    try store.appendNode(.{ .id = .fromInt(2), .kind = .task, .text = "shared" });

    const skipped = try runIdleMaintenance(store, .{ .node_text_delta_every_ops = 2 }, 1);
    try std.testing.expect(!skipped.node_text_delta_ran);
    try std.testing.expect(!skipped.node_text_delta.compacted);

    var session = AgentWriteSession.init(store, .{ .node_text_delta_every_ops = 2 });
    const first = try session.recordAppendAndMaintain();
    try std.testing.expect(!first.node_text_delta_ran);
    const second = try session.recordAppendAndMaintain();
    try std.testing.expect(second.node_text_delta_ran);
    try std.testing.expect(second.node_text_delta.compacted);
    try std.testing.expectEqual(@as(u64, 1), second.node_text_delta.delta_records_before);
    try std.testing.expectEqual(@as(u64, 0), second.node_text_delta.delta_records_after);
    try std.testing.expectEqual(@as(usize, 2), session.stats.append_ops);
    try std.testing.expectEqual(@as(usize, 1), session.stats.maintenance_ops);
    try std.testing.expectEqual(@as(usize, 1), session.stats.node_text_delta_compactions);
    try std.testing.expectEqual(@as(u64, 1), session.stats.node_text_delta_records_compacted);
    try std.testing.expectEqual(@as(u64, 1), session.stats.node_text_delta_records_before_last);
    try std.testing.expectEqual(@as(u64, 0), session.stats.node_text_delta_records_after_last);

    var matches = try store.lookupNodesByTextLimited(std.testing.allocator, null, "shared", 1);
    defer {
        for (matches.items) |*node| node.deinit(std.testing.allocator);
        matches.deinit(std.testing.allocator);
    }
    try std.testing.expectEqual(@as(usize, 1), matches.items.len);
    try std.testing.expectEqual(@as(u64, 2), matches.items[0].id.toInt());
}

test "idle maintenance policy compacts node text L0 runs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage.Store.initWithOptions(std.testing.allocator, std.testing.io, store_path, .{
        .durability = .fast,
        .validate_indexes_on_read = true,
    });
    defer store.deinit();
    try store.createEmpty();

    try store.appendNode(.{ .id = .fromInt(100), .kind = .repo, .text = "shared" });
    try store.appendNodesBatch(&.{
        .{ .id = .fromInt(20), .kind = .task, .text = "shared" },
        .{ .id = .fromInt(30), .kind = .file, .text = "run-a" },
    });
    try store.appendNodesBatch(&.{
        .{ .id = .fromInt(10), .kind = .function, .text = "shared" },
        .{ .id = .fromInt(40), .kind = .document, .text = "run-b" },
    });

    const skipped = try runIdleMaintenance(store, .{ .node_text_run_every_ops = 2 }, 1);
    try std.testing.expect(!skipped.node_text_runs_ran);
    try std.testing.expect(!skipped.node_text_runs.compacted);

    var session = AgentWriteSession.init(store, .{ .node_text_run_every_ops = 2 });
    const first = try session.recordAppendAndMaintain();
    try std.testing.expect(!first.node_text_runs_ran);
    const second = try session.recordAppendAndMaintain();
    try std.testing.expect(second.node_text_runs_ran);
    try std.testing.expect(second.node_text_runs.compacted);
    try std.testing.expectEqual(@as(usize, 2), second.node_text_runs.run_entries_before);
    try std.testing.expectEqual(@as(usize, 1), second.node_text_runs.run_entries_after);
    try std.testing.expectEqual(@as(u64, 4), second.node_text_runs.run_records_before);
    try std.testing.expectEqual(@as(u64, 4), second.node_text_runs.run_records_after);
    try std.testing.expectEqual(@as(u64, 4), second.node_text_runs.compacted_run_records);
    try std.testing.expectEqual(@as(u64, 2), second.node_text_runs.gc_deleted_runs);
    try std.testing.expectEqual(@as(usize, 2), session.stats.append_ops);
    try std.testing.expectEqual(@as(usize, 1), session.stats.maintenance_ops);
    try std.testing.expectEqual(@as(usize, 1), session.stats.node_text_run_compactions);
    try std.testing.expectEqual(@as(u64, 4), session.stats.node_text_run_records_compacted);
    try std.testing.expectEqual(@as(usize, 2), session.stats.node_text_run_entries_before_last);
    try std.testing.expectEqual(@as(usize, 1), session.stats.node_text_run_entries_after_last);
    try std.testing.expectEqual(@as(u64, 4), session.stats.node_text_run_records_before_last);
    try std.testing.expectEqual(@as(u64, 4), session.stats.node_text_run_records_after_last);
    try std.testing.expectEqual(@as(u64, 2), session.stats.node_text_run_gc_deleted_runs);

    var matches = try store.lookupNodesByTextLimited(std.testing.allocator, null, "shared", 2);
    defer {
        for (matches.items) |*node| node.deinit(std.testing.allocator);
        matches.deinit(std.testing.allocator);
    }
    try std.testing.expectEqual(@as(usize, 2), matches.items.len);
    try std.testing.expectEqual(@as(u64, 10), matches.items[0].id.toInt());
    try std.testing.expectEqual(@as(u64, 20), matches.items[1].id.toInt());
}

test "idle maintenance node text run compaction preserves retained lookup epoch" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage.Store.initWithOptions(std.testing.allocator, std.testing.io, store_path, .{
        .durability = .fast,
        .validate_indexes_on_read = true,
    });
    defer store.deinit();
    try store.createEmpty();

    try store.appendNode(.{ .id = .fromInt(100), .kind = .repo, .text = "base" });
    try store.appendNodesBatch(&.{
        .{ .id = .fromInt(20), .kind = .task, .text = "shared" },
        .{ .id = .fromInt(30), .kind = .file, .text = "run-a" },
    });
    try store.appendNodesBatch(&.{
        .{ .id = .fromInt(10), .kind = .function, .text = "shared" },
        .{ .id = .fromInt(40), .kind = .document, .text = "run-b" },
    });

    const old_epoch_path = (try store.currentNodeTextRunManifestPath(std.testing.allocator)).?;
    defer std.testing.allocator.free(old_epoch_path);

    var node_text_retention_registry = storage.NodeTextRunRetentionRegistry.init(std.testing.allocator);
    defer node_text_retention_registry.deinit();
    var view = try store.openNodeTextLookupViewRetained(std.testing.allocator, &node_text_retention_registry);
    defer view.deinit();

    var session = AgentWriteSession.init(store, .{ .node_text_run_every_ops = 1 });
    const maintained = try session.recordAppendAndMaintainWithRetentionRegistries(null, &node_text_retention_registry);
    try std.testing.expect(maintained.node_text_runs_ran);
    try std.testing.expect(maintained.node_text_runs.compacted);
    try std.testing.expectEqual(@as(u64, 0), maintained.node_text_runs.gc_deleted_runs);
    var old_epoch = try std.Io.Dir.cwd().openFile(std.testing.io, old_epoch_path, .{});
    old_epoch.close(std.testing.io);

    var matches = try view.lookupIds(std.testing.allocator, null, "shared", 2);
    defer matches.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), matches.items.len);
    try std.testing.expectEqual(@as(u64, 10), matches.items[0].toInt());
    try std.testing.expectEqual(@as(u64, 20), matches.items[1].toInt());
}

test "idle maintenance policy compacts bench-shaped node text runs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage.Store.initWithOptions(std.testing.allocator, std.testing.io, store_path, .{
        .durability = .fast,
        .validate_indexes_on_read = false,
    });
    defer store.deinit();
    try store.createEmpty();

    var nodes = std.ArrayList(graph_mod.Node).empty;
    defer nodes.deinit(std.testing.allocator);
    try nodes.ensureTotalCapacity(std.testing.allocator, 512);

    var next_id: u64 = 1;
    while (next_id <= 1000) {
        nodes.clearRetainingCapacity();
        var texts_owned = true;
        errdefer if (texts_owned) {
            for (nodes.items) |node| std.testing.allocator.free(node.text);
        };
        const take: u64 = @min(512, 1000 - next_id + 1);
        const end = next_id + take - 1;
        var id = next_id;
        while (id <= end) : (id += 1) {
            const text = try std.fmt.allocPrint(std.testing.allocator, "file/{d}.zig benchdoc{d} common InvalidRecord parseInvalidRecord", .{ id, id });
            errdefer std.testing.allocator.free(text);
            try nodes.append(std.testing.allocator, .{
                .id = .fromInt(id),
                .kind = .file,
                .text = text,
            });
        }
        try store.appendNodesBatch(nodes.items);
        for (nodes.items) |node| std.testing.allocator.free(node.text);
        texts_owned = false;
        next_id = end + 1;
    }

    var session = AgentWriteSession.init(store, .{ .node_text_run_every_ops = 2 });
    _ = try store.addNode(.file, "file/1001.zig benchdoc1001 common InvalidRecord parseInvalidRecord");
    _ = try session.recordAppendAndMaintain();
    _ = try store.addNode(.file, "file/1002.zig benchdoc1002 common InvalidRecord parseInvalidRecord");
    const maintained = try session.recordAppendAndMaintain();
    try std.testing.expect(maintained.node_text_runs_ran);
    try std.testing.expect(maintained.node_text_runs.compacted);
    try store.validatePersistentIndexes();
}

test "record observation does not use node id as array index" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();

    try graph.addNodeWithId(.fromInt(10), .task, "sparse task");
    const observation = try recordObservation(&graph, .{ .text = "sparse id observation" });

    try std.testing.expectEqual(@as(u64, 11), observation.toInt());
    try std.testing.expectEqual(core.EpistemicStatus.observed, graph.getNode(observation).?.epistemic_status);
    try std.testing.expectEqual(core.EpistemicStatus.asserted, graph.getNode(.fromInt(10)).?.epistemic_status);
}

test "record observation rejects invalid task before mutating graph" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();

    try std.testing.expectError(core.Error.InvalidId, recordObservation(&graph, .{ .task = .none, .text = "bad task" }));
    try std.testing.expectError(core.Error.InvalidId, recordObservation(&graph, .{ .task = .fromInt(std.math.maxInt(u64)), .text = "bad task" }));
    try std.testing.expectError(core.Error.NotFound, recordObservation(&graph, .{ .task = .fromInt(99), .text = "missing task" }));
    try std.testing.expectEqual(@as(usize, 0), graph.nodes.items.len);
    try std.testing.expectEqual(@as(u64, 1), graph.next_node_id);
}

test "record observation rejects non-task target before mutating graph" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();

    const file = try graph.addNode(.file, "src/main.zig");
    try std.testing.expectError(core.Error.InvalidId, recordObservation(&graph, .{ .task = file, .text = "test failed" }));
    try std.testing.expectEqual(@as(usize, 1), graph.nodes.items.len);
    try std.testing.expectEqual(@as(usize, 0), graph.edges.items.len);
    try std.testing.expectEqual(@as(u64, 2), graph.next_node_id);
}

test "record observation rolls back node when task link append fails" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var graph = graph_mod.Graph.init(failing.allocator());
    defer graph.deinit();

    const task = try graph.addNode(.task, "fix parser");
    failing.fail_index = failing.alloc_index + 1;

    try std.testing.expectError(error.OutOfMemory, recordObservation(&graph, .{ .task = task, .text = "test failed" }));
    try std.testing.expectEqual(@as(usize, 1), graph.nodes.items.len);
    try std.testing.expectEqual(@as(usize, 1), graph.node_by_id.count());
    try std.testing.expectEqual(@as(usize, 0), graph.edges.items.len);
    try std.testing.expectEqual(@as(usize, 0), graph.edge_ids.count());
    try std.testing.expectEqual(@as(u64, 2), graph.next_node_id);

    failing.fail_index = std.math.maxInt(usize);
    const retry = try recordObservation(&graph, .{ .task = task, .text = "test failed" });
    try std.testing.expectEqual(@as(u64, 2), retry.toInt());
}

test "context packet ranks local graph facts deterministically" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();

    const file = try graph.addNode(.file, "src/main.zig");
    const func = try graph.addNode(.function, "main");
    const doc = try graph.addNode(.document, "README");
    _ = try graph.addEdgeUnchecked(file, .defines, func);
    _ = try graph.addEdgeUnchecked(doc, .mentions, func);

    var packet = try contextPacket(std.testing.allocator, &graph, func, 2);
    defer packet.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), packet.facts.items.len);
    try std.testing.expectEqual(core.RelKind.defines, packet.facts.items[0].rel);
    try std.testing.expectEqual(file.toInt(), packet.facts.items[0].node_id.toInt());
}

test "context packet keeps top ranked facts within limit" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();

    const focus = try graph.addNode(.function, "main");
    const low = try graph.addNode(.document, "note");
    const high = try graph.addNode(.file, "src/main.zig");
    _ = try graph.addEdgeUnchecked(focus, .related_to, low);
    _ = try graph.addEdgeUnchecked(high, .defines, focus);

    var packet = try contextPacket(std.testing.allocator, &graph, focus, 1);
    defer packet.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), packet.facts.items.len);
    try std.testing.expectEqual(core.RelKind.defines, packet.facts.items[0].rel);
    try std.testing.expectEqual(high.toInt(), packet.facts.items[0].node_id.toInt());

    var empty = try contextPacket(std.testing.allocator, &graph, focus, 0);
    defer empty.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), empty.facts.items.len);
}

test "context packet streams edge cursor without materializing all facts" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();

    const focus = try graph.addNode(.function, "main");
    var i: usize = 0;
    while (i < 32) : (i += 1) {
        const text = try std.fmt.allocPrint(std.testing.allocator, "doc-{d}", .{i});
        defer std.testing.allocator.free(text);
        const doc = try graph.addNode(.document, text);
        _ = try graph.addEdgeUnchecked(focus, .mentions, doc);
    }

    var mem_index = try index.MemoryIndex.init(std.testing.allocator, &graph);
    defer mem_index.deinit();
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    var packet = try contextPacketWithCursor(
        failing.allocator(),
        &graph,
        &mem_index,
        .{ .memory = .{ .mem_index = &mem_index } },
        focus,
        1,
    );
    defer packet.deinit(failing.allocator());

    try std.testing.expectEqual(@as(usize, 1), packet.facts.items.len);
}

test "context packet reports self loop once" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();

    const concept = try graph.addNode(.concept, "self");
    _ = try graph.addEdgeUnchecked(concept, .related_to, concept);

    var packet = try contextPacket(std.testing.allocator, &graph, concept, 8);
    defer packet.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), packet.facts.items.len);
    try std.testing.expectEqual(ContextFact.Direction.outgoing, packet.facts.items[0].direction);
    try std.testing.expectEqual(concept.toInt(), packet.facts.items[0].node_id.toInt());
}

test "context packet skips dangling memory edge endpoints" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();

    const focus = try graph.addNode(.function, "main");
    try graph.edges.append(std.testing.allocator, .{
        .id = .fromInt(1),
        .src = focus,
        .dst = .fromInt(99),
        .rel = .mentions,
    });
    try graph.edges.append(std.testing.allocator, .{
        .id = .fromInt(2),
        .src = .fromInt(100),
        .dst = focus,
        .rel = .defines,
    });

    var packet = try contextPacket(std.testing.allocator, &graph, focus, 8);
    defer packet.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), packet.facts.items.len);
}

test "context packet rejects reserved focus ids before missing-node checks" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();

    try std.testing.expectError(core.Error.InvalidId, contextPacket(std.testing.allocator, &graph, .none, 8));
    try std.testing.expectError(core.Error.InvalidId, contextPacket(std.testing.allocator, &graph, .fromInt(std.math.maxInt(u64)), 8));
    try std.testing.expectError(core.Error.NotFound, contextPacket(std.testing.allocator, &graph, .fromInt(99), 8));
}

test "context packet uses store-backed edge cursor" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    const file = try graph.addNode(.file, "src/main.zig");
    const func = try graph.addNode(.function, "main");
    const doc = try graph.addNode(.document, "README");
    const defines = try graph.addEdgeUnchecked(file, .defines, func);
    const mentions = try graph.addEdgeUnchecked(func, .mentions, doc);
    try store.appendNode(graph.nodes.items[0]);
    try store.appendNode(graph.nodes.items[1]);
    try store.appendNode(graph.nodes.items[2]);
    try store.appendEdge(graph.edges.items[defines.toInt() - 1]);
    try store.appendEdge(graph.edges.items[mentions.toInt() - 1]);

    var loaded = try store.loadGraph();
    defer loaded.deinit();
    var mem_index = try index.MemoryIndex.init(std.testing.allocator, &loaded);
    defer mem_index.deinit();

    var packet = try contextPacketWithCursor(
        std.testing.allocator,
        &loaded,
        &mem_index,
        .{ .store = .{ .allocator = std.testing.allocator, .store = store, .graph = &loaded } },
        func,
        8,
    );
    defer packet.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), packet.facts.items.len);
    try std.testing.expectEqual(core.RelKind.defines, packet.facts.items[0].rel);
    try std.testing.expectEqual(file.toInt(), packet.facts.items[0].node_id.toInt());
    try std.testing.expectEqual(core.RelKind.mentions, packet.facts.items[1].rel);
    try std.testing.expectEqual(doc.toInt(), packet.facts.items[1].node_id.toInt());
}

test "persistent context packet rejects reserved focus ids before missing-node checks" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    try std.testing.expectError(core.Error.InvalidId, contextPacketWithPersistentStore(std.testing.allocator, store, .none, 8));
    try std.testing.expectError(core.Error.InvalidId, contextPacketWithPersistentStore(std.testing.allocator, store, .fromInt(std.math.maxInt(u64)), 8));
    try std.testing.expectError(core.Error.NotFound, contextPacketWithPersistentStore(std.testing.allocator, store, .fromInt(99), 8));
}

test "persistent context packet enforces immediate timeout before max facts shortcut" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    const focus = try graph.addNode(.function, "main");
    try store.appendNode(graph.nodes.items[focus.toInt() - 1]);

    var stats: index.QueryStats = .{};
    try std.testing.expectError(
        core.Error.BudgetExceeded,
        contextPacketWithPersistentStoreMeasured(std.testing.allocator, store, focus, 0, .{ .timeout_ms = 0 }, &stats),
    );
    try std.testing.expectEqual(@as(usize, 0), stats.nodes_visited);
    try std.testing.expectEqual(@as(usize, 0), stats.edges_visited);
}

test "persistent context packet measured stats reject overflow" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    const focus = core.NodeId.fromInt(1);
    const neighbor = core.NodeId.fromInt(2);
    try store.appendNode(.{ .id = focus, .kind = .function, .text = "main" });
    try store.appendNode(.{ .id = neighbor, .kind = .file, .text = "src/main.zig" });
    try store.appendEdge(.{ .id = .fromInt(1), .src = focus, .rel = .mentions, .dst = neighbor });

    var edge_stats = index.QueryStats{ .edges_visited = std.math.maxInt(usize) };
    try std.testing.expectError(
        error.RecordTooLarge,
        contextPacketWithPersistentStoreMeasured(std.testing.allocator, store, focus, 8, .{}, &edge_stats),
    );
    try std.testing.expectEqual(std.math.maxInt(usize), edge_stats.edges_visited);

    var node_stats = index.QueryStats{ .nodes_visited = std.math.maxInt(usize) };
    try std.testing.expectError(
        error.RecordTooLarge,
        contextPacketWithPersistentStoreMeasured(std.testing.allocator, store, focus, 8, .{}, &node_stats),
    );
    try std.testing.expectEqual(std.math.maxInt(usize), node_stats.nodes_visited);
}

test "persistent context packet reports self loop once" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    const concept = try graph.addNode(.concept, "self");
    const edge = try graph.addEdgeUnchecked(concept, .related_to, concept);
    for (graph.nodes.items) |node| try store.appendNode(node);
    try store.appendEdge(graph.edges.items[edge.toInt() - 1]);
    try store.ensurePersistentEdgeIndexes(&graph);

    var packet = try contextPacketWithPersistentStore(std.testing.allocator, store, concept, 8);
    defer packet.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), packet.facts.items.len);
    try std.testing.expectEqual(ContextFact.Direction.outgoing, packet.facts.items[0].direction);
    try std.testing.expectEqual(concept.toInt(), packet.facts.items[0].node_id.toInt());
}

test "persistent context packet keeps top ranked facts within limit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    const focus = try graph.addNode(.function, "main");
    const low = try graph.addNode(.document, "note");
    const high = try graph.addNode(.file, "src/main.zig");
    const low_edge = try graph.addEdgeUnchecked(focus, .related_to, low);
    const high_edge = try graph.addEdgeUnchecked(high, .defines, focus);
    for (graph.nodes.items) |node| try store.appendNode(node);
    try store.appendEdge(graph.edges.items[low_edge.toInt() - 1]);
    try store.appendEdge(graph.edges.items[high_edge.toInt() - 1]);
    try store.ensurePersistentEdgeIndexes(&graph);

    var packet = try contextPacketWithPersistentStore(std.testing.allocator, store, focus, 1);
    defer packet.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), packet.facts.items.len);
    try std.testing.expectEqual(core.RelKind.defines, packet.facts.items[0].rel);
    try std.testing.expectEqual(high.toInt(), packet.facts.items[0].node_id.toInt());
}

test "context packet can use persistent store without graph argument" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    const file = try graph.addNode(.file, "src/main.zig");
    const func = try graph.addNode(.function, "main");
    const doc = try graph.addNode(.document, "README");
    const defines = try graph.addEdgeUnchecked(file, .defines, func);
    const mentions = try graph.addEdgeUnchecked(func, .mentions, doc);
    for (graph.nodes.items) |node| try store.appendNode(node);
    try store.appendEdge(graph.edges.items[defines.toInt() - 1]);
    try store.appendEdge(graph.edges.items[mentions.toInt() - 1]);
    try store.ensurePersistentEdgeIndexes(&graph);

    var packet = try contextPacketWithPersistentStore(std.testing.allocator, store, func, 8);
    defer packet.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), packet.facts.items.len);
    try std.testing.expectEqual(core.RelKind.defines, packet.facts.items[0].rel);
    try std.testing.expectEqual(file.toInt(), packet.facts.items[0].node_id.toInt());
    try std.testing.expectEqual(core.RelKind.mentions, packet.facts.items[1].rel);
    try std.testing.expectEqual(doc.toInt(), packet.facts.items[1].node_id.toInt());
}

test "persistent context packet routes through published edge segment before index fallback" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);
    const segment_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "edge-s000001" });
    defer std.testing.allocator.free(segment_path);

    var store = try storage.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    const file = core.NodeId.fromInt(1);
    const func = core.NodeId.fromInt(2);
    const doc = core.NodeId.fromInt(3);
    try store.appendNode(.{ .id = file, .kind = .file, .text = "src/main.zig" });
    try store.appendNode(.{ .id = func, .kind = .function, .text = "main" });
    try store.appendNode(.{ .id = doc, .kind = .document, .text = "README" });
    try store.appendEdge(.{ .id = .fromInt(1), .src = file, .rel = .defines, .dst = func });
    try store.appendEdge(.{ .id = .fromInt(2), .src = func, .rel = .mentions, .dst = doc });
    try std.testing.expectEqual(@as(u64, 2), try store.publishEdgeAdjacencySegment(segment_path));

    try std.Io.Dir.cwd().deleteFile(std.testing.io, store.edge_by_src_path);
    try std.Io.Dir.cwd().deleteFile(std.testing.io, store.edge_by_dst_path);

    var packet = try contextPacketWithPersistentStore(std.testing.allocator, store, func, 8);
    defer packet.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), packet.facts.items.len);
    try std.testing.expectEqual(core.RelKind.defines, packet.facts.items[0].rel);
    try std.testing.expectEqual(file.toInt(), packet.facts.items[0].node_id.toInt());
    try std.testing.expectEqual(core.RelKind.mentions, packet.facts.items[1].rel);
    try std.testing.expectEqual(doc.toInt(), packet.facts.items[1].node_id.toInt());
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().openFile(std.testing.io, store.edge_by_src_path, .{}));
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().openFile(std.testing.io, store.edge_by_dst_path, .{}));
}

test "retained persistent context packet uses registry-backed published segments" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);
    const segment_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "edge-s000001" });
    defer std.testing.allocator.free(segment_path);

    var store = try storage.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();

    const file = core.NodeId.fromInt(1);
    const func = core.NodeId.fromInt(2);
    const doc = core.NodeId.fromInt(3);
    try store.appendNode(.{ .id = file, .kind = .file, .text = "src/main.zig" });
    try store.appendNode(.{ .id = func, .kind = .function, .text = "main" });
    try store.appendNode(.{ .id = doc, .kind = .document, .text = "README" });
    try store.appendEdge(.{ .id = .fromInt(1), .src = file, .rel = .defines, .dst = func });
    try store.appendEdge(.{ .id = .fromInt(2), .src = func, .rel = .mentions, .dst = doc });
    try std.testing.expectEqual(@as(u64, 2), try store.publishEdgeAdjacencySegment(segment_path));

    try std.Io.Dir.cwd().deleteFile(std.testing.io, store.edge_by_src_path);
    try std.Io.Dir.cwd().deleteFile(std.testing.io, store.edge_by_dst_path);

    var retention_registry = storage.EdgeSegmentRetentionRegistry.init(std.testing.allocator);
    defer retention_registry.deinit();
    var packet = try contextPacketWithPersistentStoreBudgetRetained(std.testing.allocator, store, &retention_registry, func, 8, .{});
    defer packet.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), packet.facts.items.len);
    try std.testing.expectEqual(core.RelKind.defines, packet.facts.items[0].rel);
    try std.testing.expectEqual(file.toInt(), packet.facts.items[0].node_id.toInt());
    try std.testing.expectEqual(core.RelKind.mentions, packet.facts.items[1].rel);
    try std.testing.expectEqual(doc.toInt(), packet.facts.items[1].node_id.toInt());
    {
        const active_paths = try retention_registry.activeManifestPaths(std.testing.allocator);
        defer std.testing.allocator.free(active_paths);
        try std.testing.expectEqual(@as(usize, 0), active_paths.len);
    }
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().openFile(std.testing.io, store.edge_by_src_path, .{}));
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().openFile(std.testing.io, store.edge_by_dst_path, .{}));
}

test "persistent context packet zero facts validates focus without reading texts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();
    const focus = core.NodeId.fromInt(1);
    try store.appendNode(.{ .id = focus, .kind = .function, .text = "main" });

    try std.Io.Dir.cwd().deleteFile(std.testing.io, store.node_texts_path);
    try std.testing.expectError(error.FileNotFound, store.readNodeById(std.testing.allocator, focus));

    var packet = try contextPacketWithPersistentStore(std.testing.allocator, store, focus, 0);
    defer packet.deinit(std.testing.allocator);
    try std.testing.expectEqual(focus.toInt(), packet.focus.toInt());
    try std.testing.expectEqual(@as(usize, 0), packet.facts.items.len);
}

test "persistent context packet repairs corrupt edge index" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage.Store.init(std.testing.allocator, std.testing.io, store_path);
    store.options.validate_indexes_on_read = true;
    defer store.deinit();
    try store.createEmpty();

    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    const file = try graph.addNode(.file, "src/main.zig");
    const func = try graph.addNode(.function, "main");
    const edge = try graph.addEdgeUnchecked(file, .defines, func);
    try store.appendNode(graph.nodes.items[0]);
    try store.appendNode(graph.nodes.items[1]);
    try store.appendEdge(graph.edges.items[edge.toInt() - 1]);

    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = store.edge_by_dst_path,
        .data = "bad",
        .flags = .{ .truncate = true },
    });
    try std.testing.expectError(
        error.InvalidRecord,
        store.readEdgeIndexRecordsByNode(std.testing.allocator, .dst, func),
    );

    var packet = try contextPacketWithPersistentStore(std.testing.allocator, store, func, 8);
    defer packet.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), packet.facts.items.len);
    try std.testing.expectEqual(core.RelKind.defines, packet.facts.items[0].rel);
    try std.testing.expectEqual(file.toInt(), packet.facts.items[0].node_id.toInt());
}

test "persistent context packet repairs dangling target edge index" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage.Store.init(std.testing.allocator, std.testing.io, store_path);
    store.options.validate_indexes_on_read = false;
    defer store.deinit();
    try store.createEmpty();

    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    const file = try graph.addNode(.file, "src/main.zig");
    const func = try graph.addNode(.function, "main");
    const edge = try graph.addEdgeUnchecked(file, .defines, func);
    for (graph.nodes.items) |node| try store.appendNode(node);
    try store.appendEdge(graph.edges.items[edge.toInt() - 1]);

    var edge_index = try std.Io.Dir.cwd().openFile(std.testing.io, store.edge_by_src_path, .{ .mode = .read_write });
    defer edge_index.close(std.testing.io);
    var dangling_dst: [8]u8 = undefined;
    std.mem.writeInt(u64, &dangling_dst, 99, .little);
    try edge_index.writePositionalAll(std.testing.io, &dangling_dst, storage.EdgeIndexHeader.encoded_len + 8);

    var packet = try contextPacketWithPersistentStore(std.testing.allocator, store, file, 8);
    defer packet.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), packet.facts.items.len);
    try std.testing.expectEqual(func.toInt(), packet.facts.items[0].node_id.toInt());
}

test "persistent context packet repairs dangling source edge index" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root_path = path_buf[0..root_len];
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ root_path, "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage.Store.init(std.testing.allocator, std.testing.io, store_path);
    store.options.validate_indexes_on_read = false;
    defer store.deinit();
    try store.createEmpty();

    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();
    const file = try graph.addNode(.file, "src/main.zig");
    const func = try graph.addNode(.function, "main");
    const edge = try graph.addEdgeUnchecked(file, .defines, func);
    for (graph.nodes.items) |node| try store.appendNode(node);
    try store.appendEdge(graph.edges.items[edge.toInt() - 1]);

    const edge_index_header_len = storage.EdgeIndexHeader.encoded_len;
    const edge_index_record_len = 34;
    var bytes: [edge_index_header_len + edge_index_record_len]u8 = undefined;
    @memcpy(bytes[0..4], "TKGX");
    std.mem.writeInt(u16, bytes[4..6], 2, .little);
    std.mem.writeInt(u16, bytes[6..8], edge_index_header_len, .little);
    bytes[8] = @intFromEnum(storage.EdgeIndexOrder.dst);
    @memset(bytes[9..16], 0);
    std.mem.writeInt(u64, bytes[16..24], 1, .little);
    std.mem.writeInt(u64, bytes[24..32], 0, .little);
    const record_offset = edge_index_header_len;
    std.mem.writeInt(u64, bytes[record_offset + 0 .. record_offset + 8], 99, .little);
    std.mem.writeInt(u64, bytes[record_offset + 8 .. record_offset + 16], func.toInt(), .little);
    std.mem.writeInt(u64, bytes[record_offset + 16 .. record_offset + 24], edge.toInt(), .little);
    std.mem.writeInt(u16, bytes[record_offset + 24 .. record_offset + 26], @intFromEnum(core.RelKind.defines), .little);
    @memset(bytes[record_offset + 26 .. record_offset + 34], 0);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = store.edge_by_dst_path,
        .data = &bytes,
        .flags = .{ .truncate = true },
    });

    var packet = try contextPacketWithPersistentStore(std.testing.allocator, store, func, 8);
    defer packet.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), packet.facts.items.len);
    try std.testing.expectEqual(core.RelKind.defines, packet.facts.items[0].rel);
    try std.testing.expectEqual(ContextFact.Direction.incoming, packet.facts.items[0].direction);
    try std.testing.expectEqual(file.toInt(), packet.facts.items[0].node_id.toInt());
}
