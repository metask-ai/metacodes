const std = @import("std");
const core = @import("../core.zig");
const storage = @import("../storage.zig");
const task = @import("../task.zig");

/// Canonical exporter for `tinykg-task-snapshot-v1`
/// (docs/frommetacodes/task-snapshot-v1.md): one consistent read of a task
/// root's contain subtree, its dependencies, and its verified_by evidence,
/// serialized as deterministic canonical JSON with a semantic revision
/// digest. The caller owns the store lock lifetime; everything here is
/// strictly read-only. Production success never truncates: any budget or
/// integrity violation is a typed error with no success body.
pub const schema_version = "tinykg-task-snapshot-v1";
pub const capability = "tinykg-task-snapshot-v1";

pub const default_max_tasks: u64 = 256;
pub const default_max_edges: u64 = 1024;
pub const default_max_chars: u64 = 200_000;
/// Hard ceilings: caller budgets are clamped-by-rejection, not silently.
pub const hard_max_tasks: u64 = 4096;
pub const hard_max_edges: u64 = 16384;
pub const hard_max_chars: u64 = 4 * 1024 * 1024;

pub const Budgets = struct {
    max_tasks: u64 = default_max_tasks,
    max_edges: u64 = default_max_edges,
    max_chars: u64 = default_max_chars,

    pub fn validate(self: Budgets) !void {
        if (self.max_tasks == 0 or self.max_tasks > hard_max_tasks) return error.InvalidLimit;
        if (self.max_edges == 0 or self.max_edges > hard_max_edges) return error.InvalidLimit;
        if (self.max_chars == 0 or self.max_chars > hard_max_chars) return error.InvalidLimit;
    }
};

const TaskItem = struct {
    id: u64,
    status: []const u8,
    claimed_by: ?[]const u8,
    text: []const u8,
};

const HierarchyEdge = struct {
    src: u64,
    dst: u64,
};

const DependencyEdge = struct {
    src: u64,
    relation: []const u8,
    dst: u64,
};

const EvidenceItem = struct {
    id: u64,
    kind: []const u8,
    text: []const u8,
};

const VerifiedByEdge = struct {
    src: u64,
    rel: []const u8,
    dst: u64,
};

const Summary = struct {
    task_count: u64,
    hierarchy_edge_count: u64,
    dependency_edge_count: u64,
    evidence_count: u64,
    verified_by_edge_count: u64,
    used_text_bytes: u64,
    truncated: bool,
    truncate_reason: ?[]const u8,
    max_tasks: u64,
    max_edges: u64,
    max_chars: u64,
};

/// Field order here IS the canonical wire order; std.json emits struct
/// fields in declaration order deterministically.
fn SnapshotBody(comptime with_revision: bool) type {
    if (with_revision) {
        return struct {
            schema_version: []const u8,
            root_id: u64,
            revision: []const u8,
            summary: Summary,
            tasks: []const TaskItem,
            hierarchy: []const HierarchyEdge,
            dependencies: []const DependencyEdge,
            evidence: []const EvidenceItem,
            verified_by: []const VerifiedByEdge,
        };
    }
    return struct {
        schema_version: []const u8,
        root_id: u64,
        summary: Summary,
        tasks: []const TaskItem,
        hierarchy: []const HierarchyEdge,
        dependencies: []const DependencyEdge,
        evidence: []const EvidenceItem,
        verified_by: []const VerifiedByEdge,
    };
}

fn dependencyRelationName(order: u8) []const u8 {
    return switch (order) {
        0 => "depends_on",
        1 => "blocks",
        2 => "precedes",
        else => unreachable,
    };
}

const DependencyKey = struct {
    src: u64,
    order: u8,
    dst: u64,

    fn lessThan(_: void, a: DependencyKey, b: DependencyKey) bool {
        if (a.src != b.src) return a.src < b.src;
        if (a.order != b.order) return a.order < b.order;
        return a.dst < b.dst;
    }

    fn eql(a: DependencyKey, b: DependencyKey) bool {
        return a.src == b.src and a.order == b.order and a.dst == b.dst;
    }
};

const PairKey = struct {
    src: u64,
    dst: u64,

    fn lessThan(_: void, a: PairKey, b: PairKey) bool {
        if (a.src != b.src) return a.src < b.src;
        return a.dst < b.dst;
    }
};

fn u64LessThan(_: void, a: u64, b: u64) bool {
    return a < b;
}

/// Export the snapshot as canonical JSON bytes. `now_ns` resolves effective
/// task status (expired leases read as open) exactly once for the whole
/// snapshot. The returned slice is owned by the caller.
pub fn exportTaskSnapshotAlloc(
    allocator: std.mem.Allocator,
    store: storage.Store,
    root_id: core.NodeId,
    budgets: Budgets,
    now_ns: u64,
) ![]u8 {
    try budgets.validate();

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // --- root admission -------------------------------------------------
    {
        var root_node = (try store.readNodeById(arena, root_id)) orelse return error.InvalidTaskRoot;
        defer root_node.deinit(arena);
        if (root_node.kind != .task) return error.InvalidTaskRoot;
    }

    // --- contain subtree (BFS, duplicates per parent deduplicated, any
    // cross-parent revisit is a cycle/diamond and fails closed) ----------
    var member_set = std.AutoHashMap(u64, void).init(arena);
    var member_ids = std.ArrayList(u64).empty;
    var hierarchy_keys = std.ArrayList(PairKey).empty;
    var queue = std.ArrayList(u64).empty;

    try member_set.put(root_id.toInt(), {});
    try member_ids.append(arena, root_id.toInt());
    try queue.append(arena, root_id.toInt());

    var queue_index: usize = 0;
    while (queue_index < queue.items.len) : (queue_index += 1) {
        const parent = queue.items[queue_index];
        var records = try store.readVisibleEdgeIndexRecordsByNodeForOrderedTraversal(arena, core.NodeId.fromInt(parent));
        defer records.deinit(arena);
        var seen_children = std.AutoHashMap(u64, void).init(arena);
        defer seen_children.deinit();
        for (records.items) |record| {
            if (record.rel != @intFromEnum(core.RelKind.contain)) continue;
            if (record.dst == 0 or record.dst == parent) return error.TaskSnapshotReferentialIntegrity;
            // Duplicate physical edges between the same pair collapse to one
            // hierarchy fact.
            if (seen_children.contains(record.dst)) continue;
            try seen_children.put(record.dst, {});
            var child = (try store.readNodeById(arena, core.NodeId.fromInt(record.dst))) orelse return error.TaskSnapshotReferentialIntegrity;
            const child_is_task = child.kind == .task;
            child.deinit(arena);
            // Non-task containment (docs, memory anchors) is outside the
            // task snapshot's scope.
            if (!child_is_task) continue;
            if (member_set.contains(record.dst)) return error.TaskSnapshotCycle;
            try member_set.put(record.dst, {});
            try member_ids.append(arena, record.dst);
            try hierarchy_keys.append(arena, .{ .src = parent, .dst = record.dst });
            try queue.append(arena, record.dst);
            if (member_ids.items.len > budgets.max_tasks) return error.TaskSnapshotTooLarge;
        }
    }

    std.mem.sort(u64, member_ids.items, {}, u64LessThan);
    std.mem.sort(PairKey, hierarchy_keys.items, {}, PairKey.lessThan);

    // --- effective status in one lifecycle snapshot ---------------------
    var node_ids = try arena.alloc(core.NodeId, member_ids.items.len);
    for (member_ids.items, 0..) |id, index| node_ids[index] = core.NodeId.fromInt(id);
    var lifecycle_snapshot = try task.StatusSnapshot.initForNodeIds(arena, store, node_ids);
    defer lifecycle_snapshot.deinit();

    var used_text_bytes: u64 = 0;
    var tasks = try arena.alloc(TaskItem, member_ids.items.len);
    for (member_ids.items, 0..) |id, index| {
        const node_id = core.NodeId.fromInt(id);
        var node = (try store.readNodeById(arena, node_id)) orelse return error.TaskSnapshotReferentialIntegrity;
        if (node.kind != .task) return error.TaskSnapshotReferentialIntegrity;
        const lifecycle = try lifecycle_snapshot.statusForStoredNode(node, now_ns);
        const fields = lifecycle_snapshot.fields(node_id);
        const claimed_by: ?[]const u8 = if (lifecycle == .claimed)
            try arena.dupe(u8, fields.claimed_by orelse return error.InvalidTaskLifecycle)
        else
            null;
        if (claimed_by != null and claimed_by.?.len == 0) return error.InvalidTaskLifecycle;
        const text = try arena.dupe(u8, node.text);
        node.deinit(arena);
        used_text_bytes += text.len;
        tasks[index] = .{
            .id = id,
            .status = @tagName(lifecycle),
            .claimed_by = claimed_by,
            .text = text,
        };
    }

    // --- dependencies ----------------------------------------------------
    var dependency_keys = std.ArrayList(DependencyKey).empty;
    for (member_ids.items) |id| {
        const node_id = core.NodeId.fromInt(id);
        // Outbound depends_on: src is inside the subgraph by construction.
        var outbound = try store.readVisibleEdgeIndexRecordsByNodeForOrderedTraversal(arena, node_id);
        defer outbound.deinit(arena);
        for (outbound.items) |record| {
            if (record.rel != @intFromEnum(core.RelKind.depends_on)) continue;
            if (record.dst == 0 or record.dst == record.src) return error.TaskSnapshotReferentialIntegrity;
            try dependency_keys.append(arena, .{ .src = record.src, .order = 0, .dst = record.dst });
        }
        // Inbound blocks/precedes: dst is inside the subgraph.
        var inbound = try store.readVisibleEdgeIndexRecordsByNode(arena, .dst, node_id, null);
        defer inbound.deinit(arena);
        for (inbound.items) |record| {
            const order: u8 = if (record.rel == @intFromEnum(core.RelKind.blocks))
                1
            else if (record.rel == @intFromEnum(core.RelKind.precedes))
                2
            else
                continue;
            if (order == 0) continue; // inbound depends_on stays out of scope
            if (record.src == 0 or record.src == record.dst) return error.TaskSnapshotReferentialIntegrity;
            try dependency_keys.append(arena, .{ .src = record.src, .order = order, .dst = record.dst });
        }
    }
    std.mem.sort(DependencyKey, dependency_keys.items, {}, DependencyKey.lessThan);
    var dependencies = std.ArrayList(DependencyEdge).empty;
    {
        var previous: ?DependencyKey = null;
        for (dependency_keys.items) |key| {
            if (previous) |prev| {
                if (DependencyKey.eql(prev, key)) continue;
            }
            previous = key;
            try dependencies.append(arena, .{
                .src = key.src,
                .relation = dependencyRelationName(key.order),
                .dst = key.dst,
            });
        }
    }

    // --- evidence and verified_by ----------------------------------------
    var verified_keys = std.ArrayList(PairKey).empty;
    var evidence_set = std.AutoHashMap(u64, void).init(arena);
    var evidence_ids = std.ArrayList(u64).empty;
    for (member_ids.items) |id| {
        var outbound = try store.readVisibleEdgeIndexRecordsByNodeForOrderedTraversal(arena, core.NodeId.fromInt(id));
        defer outbound.deinit(arena);
        for (outbound.items) |record| {
            if (record.rel != @intFromEnum(core.RelKind.verified_by)) continue;
            if (record.dst == 0 or record.dst == record.src) return error.TaskSnapshotReferentialIntegrity;
            try verified_keys.append(arena, .{ .src = record.src, .dst = record.dst });
            if (!evidence_set.contains(record.dst)) {
                try evidence_set.put(record.dst, {});
                try evidence_ids.append(arena, record.dst);
            }
        }
    }
    std.mem.sort(PairKey, verified_keys.items, {}, PairKey.lessThan);
    var verified_by = std.ArrayList(VerifiedByEdge).empty;
    {
        var previous: ?PairKey = null;
        for (verified_keys.items) |key| {
            if (previous) |prev| {
                if (prev.src == key.src and prev.dst == key.dst) continue;
            }
            previous = key;
            try verified_by.append(arena, .{ .src = key.src, .rel = "verified_by", .dst = key.dst });
        }
    }
    std.mem.sort(u64, evidence_ids.items, {}, u64LessThan);
    var evidence = try arena.alloc(EvidenceItem, evidence_ids.items.len);
    for (evidence_ids.items, 0..) |id, index| {
        var node = (try store.readNodeById(arena, core.NodeId.fromInt(id))) orelse return error.TaskSnapshotReferentialIntegrity;
        const text = try arena.dupe(u8, node.text);
        const kind = node.kind;
        node.deinit(arena);
        used_text_bytes += text.len;
        evidence[index] = .{ .id = id, .kind = @tagName(kind), .text = text };
    }

    // --- budgets ----------------------------------------------------------
    const edge_total = hierarchy_keys.items.len + dependencies.items.len + verified_by.items.len;
    if (member_ids.items.len > budgets.max_tasks) return error.TaskSnapshotTooLarge;
    if (edge_total > budgets.max_edges) return error.TaskSnapshotTooLarge;
    if (used_text_bytes > budgets.max_chars) return error.TaskSnapshotTooLarge;

    var hierarchy = try arena.alloc(HierarchyEdge, hierarchy_keys.items.len);
    for (hierarchy_keys.items, 0..) |key, index| hierarchy[index] = .{ .src = key.src, .dst = key.dst };

    const summary = Summary{
        .task_count = member_ids.items.len,
        .hierarchy_edge_count = hierarchy.len,
        .dependency_edge_count = dependencies.items.len,
        .evidence_count = evidence.len,
        .verified_by_edge_count = verified_by.items.len,
        .used_text_bytes = used_text_bytes,
        .truncated = false,
        .truncate_reason = null,
        .max_tasks = budgets.max_tasks,
        .max_edges = budgets.max_edges,
        .max_chars = budgets.max_chars,
    };

    // --- revision = SHA-256 over the canonical semantic body --------------
    const semantic = SnapshotBody(false){
        .schema_version = schema_version,
        .root_id = root_id.toInt(),
        .summary = summary,
        .tasks = tasks,
        .hierarchy = hierarchy,
        .dependencies = dependencies.items,
        .evidence = evidence,
        .verified_by = verified_by.items,
    };
    var semantic_bytes = std.Io.Writer.Allocating.init(arena);
    try std.json.Stringify.value(semantic, .{}, &semantic_bytes.writer);
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(semantic_bytes.writer.buffered(), &digest, .{});
    var revision_hex: [64]u8 = undefined;
    _ = std.fmt.bufPrint(&revision_hex, "{x}", .{&digest}) catch unreachable;

    const response = SnapshotBody(true){
        .schema_version = schema_version,
        .root_id = root_id.toInt(),
        .revision = &revision_hex,
        .summary = summary,
        .tasks = tasks,
        .hierarchy = hierarchy,
        .dependencies = dependencies.items,
        .evidence = evidence,
        .verified_by = verified_by.items,
    };
    var out = std.Io.Writer.Allocating.init(allocator);
    errdefer out.deinit();
    try std.json.Stringify.value(response, .{}, &out.writer);
    return out.toOwnedSlice();
}
