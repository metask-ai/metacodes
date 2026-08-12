const std = @import("std");
const core = @import("core.zig");
const dag = @import("dag.zig");
const graph_mod = @import("graph.zig");
const index = @import("index.zig");
const query = @import("query.zig");
const schema = @import("schema.zig");
const storage = @import("storage.zig");

pub fn isDagRelation(rel: core.RelKind) bool {
    return dag.isDagRelation(rel);
}

pub fn wouldCreateCycle(graph: *const graph_mod.Graph, src: core.NodeId, dst: core.NodeId, rel: core.RelKind, budget: core.QueryBudget) !bool {
    return dag.wouldCreateCycle(graph, src, dst, rel, budget);
}

pub const ReadyState = enum {
    ready,
    blocked,
    missing_dependencies,
};

/// Task lifecycle is orthogonal to node kind.  A task keeps `.task` for its
/// whole lifetime so stable ids remain valid packet/ancestry anchors.
pub const Status = enum {
    open,
    claimed,
    completed,
    failed,

    pub fn parse(raw: []const u8) ?Status {
        inline for (std.meta.fields(Status)) |field| {
            if (std.mem.eql(u8, raw, field.name)) return @enumFromInt(field.value);
        }
        return null;
    }

    pub fn isTerminal(self: Status) bool {
        return self == .completed or self == .failed;
    }
};

test "task lifecycle enum matches the schema domain" {
    const fields = std.meta.fields(Status);
    try std.testing.expectEqual(fields.len, schema.task_status_enum_values.len);
    inline for (fields, schema.task_status_enum_values) |field, value| {
        try std.testing.expectEqualStrings(field.name, value);
    }
}

pub const status_property = "status";
pub const claimed_by_property = "claimed_by";
pub const claim_expires_ns_property = "claim_expires_ns";
pub const max_claim_holder_len = 128;

const task_created_ns_property = "task_created_ns";
const task_completed_ns_property = "task_completed_ns";

pub const StatusSnapshot = struct {
    allocator: std.mem.Allocator,
    properties: storage.PropertySnapshot,
    by_node: std.AutoHashMap(u64, LifecycleFields),
    covered_nodes: std.AutoHashMap(u64, void),
    covers_all: bool,

    pub const LifecycleFields = struct {
        // `status` is a common application property name.  A global lifecycle
        // snapshot can therefore encounter non-task values such as
        // "published".  Preserve the raw bytes here and only parse them after
        // the caller has proved that the owner is a task node.
        stored_status_raw: ?[]const u8 = null,
        claimed_by: ?[]const u8 = null,
        claim_expires_ns: ?u64 = null,
        task_recorded_ns: ?u64 = null,
        task_created_ns: ?u64 = null,
        task_completed_ns: ?u64 = null,
        /// Property names are global hashes, but task lifecycle semantics are
        /// not.  A non-task schema may legally use `status` (or another
        /// lifecycle-shaped name) with a different value type.  Preserve the
        /// mismatch and reject it only after the owner is known to be a task;
        /// otherwise one unrelated node could poison every global task
        /// snapshot used by export and migration.
        invalid_value_type: bool = false,
    };

    pub const Claim = struct {
        holder: ?[]const u8 = null,
        expires_ns: u64 = 0,

        pub fn active(self: Claim, now_ns: u64) bool {
            return self.holder != null and self.holder.?.len != 0 and self.expires_ns > now_ns;
        }
    };

    pub fn init(allocator: std.mem.Allocator, store: storage.Store) !StatusSnapshot {
        const properties = try store.loadNodePropertySnapshotForKeys(allocator, &.{
            status_property,
            claimed_by_property,
            claim_expires_ns_property,
            "task_recorded_ns",
            task_created_ns_property,
            task_completed_ns_property,
        });
        return try initFromProperties(allocator, properties, &.{}, true);
    }

    pub fn initForNodeIds(allocator: std.mem.Allocator, store: storage.Store, node_ids: []const core.NodeId) !StatusSnapshot {
        const properties = try store.loadNodePropertySnapshotForNodeIds(allocator, node_ids, &.{
            status_property,
            claimed_by_property,
            claim_expires_ns_property,
            "task_recorded_ns",
            task_created_ns_property,
            task_completed_ns_property,
        });
        return try initFromProperties(allocator, properties, node_ids, false);
    }

    fn initFromProperties(
        allocator: std.mem.Allocator,
        owned_properties: storage.PropertySnapshot,
        covered_node_ids: []const core.NodeId,
        covers_all: bool,
    ) !StatusSnapshot {
        var properties = owned_properties;
        errdefer properties.deinit(allocator);
        var by_node = std.AutoHashMap(u64, LifecycleFields).init(allocator);
        errdefer by_node.deinit();
        var covered_nodes = std.AutoHashMap(u64, void).init(allocator);
        errdefer covered_nodes.deinit();
        try covered_nodes.ensureTotalCapacity(std.math.cast(u32, covered_node_ids.len) orelse return error.RecordTooLarge);
        for (covered_node_ids) |node_id| try covered_nodes.put(node_id.toInt(), {});

        const status_hash = storage.propertyKeyHashForLookup(status_property);
        const claimed_by_hash = storage.propertyKeyHashForLookup(claimed_by_property);
        const claim_expires_hash = storage.propertyKeyHashForLookup(claim_expires_ns_property);
        const recorded_hash = storage.propertyKeyHashForLookup("task_recorded_ns");
        const created_hash = storage.propertyKeyHashForLookup(task_created_ns_property);
        const completed_hash = storage.propertyKeyHashForLookup(task_completed_ns_property);
        for (properties.entries) |entry| {
            const node_id = switch (entry.owner) {
                .node => |id| id.toInt(),
                .edge => continue,
            };
            const slot = try by_node.getOrPut(node_id);
            if (!slot.found_existing) slot.value_ptr.* = .{};
            if (entry.key_hash == status_hash) {
                if (entry.value_kind == .string) {
                    slot.value_ptr.stored_status_raw = entry.string_value;
                } else {
                    slot.value_ptr.invalid_value_type = true;
                }
            } else if (entry.key_hash == claimed_by_hash) {
                if (entry.value_kind == .string) {
                    slot.value_ptr.claimed_by = entry.string_value;
                } else {
                    slot.value_ptr.invalid_value_type = true;
                }
            } else if (entry.key_hash == claim_expires_hash) {
                if (entry.value_kind == .uint) {
                    slot.value_ptr.claim_expires_ns = entry.uint_value;
                } else {
                    slot.value_ptr.invalid_value_type = true;
                }
            } else if (entry.key_hash == recorded_hash) {
                if (entry.value_kind == .uint) {
                    slot.value_ptr.task_recorded_ns = entry.uint_value;
                } else {
                    slot.value_ptr.invalid_value_type = true;
                }
            } else if (entry.key_hash == created_hash) {
                if (entry.value_kind == .uint) {
                    slot.value_ptr.task_created_ns = entry.uint_value;
                } else {
                    slot.value_ptr.invalid_value_type = true;
                }
            } else if (entry.key_hash == completed_hash) {
                if (entry.value_kind == .uint) {
                    slot.value_ptr.task_completed_ns = entry.uint_value;
                } else {
                    slot.value_ptr.invalid_value_type = true;
                }
            }
        }
        return .{
            .allocator = allocator,
            .properties = properties,
            .by_node = by_node,
            .covered_nodes = covered_nodes,
            .covers_all = covers_all,
        };
    }

    pub fn deinit(self: *StatusSnapshot) void {
        self.covered_nodes.deinit();
        self.by_node.deinit();
        self.properties.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn fields(self: *const StatusSnapshot, node_id: core.NodeId) LifecycleFields {
        return self.by_node.get(node_id.toInt()) orelse .{};
    }

    pub fn covers(self: *const StatusSnapshot, node_id: core.NodeId) bool {
        return self.covers_all or self.covered_nodes.contains(node_id.toInt());
    }

    pub fn claim(self: *const StatusSnapshot, node_id: core.NodeId) Claim {
        const lifecycle = self.fields(node_id);
        return .{ .holder = lifecycle.claimed_by, .expires_ns = lifecycle.claim_expires_ns orelse 0 };
    }

    pub fn isLegacyClosedTaskNode(self: *const StatusSnapshot, node: storage.StoredNode) bool {
        if (node.kind != .verification and node.kind != .fix) return false;
        return lifecycleFieldsRepresentLegacyClosedTask(self.fields(node.id));
    }

    pub fn statusForStoredNode(self: *const StatusSnapshot, node: storage.StoredNode, now_ns: u64) !Status {
        const lifecycle = self.fields(node.id);
        if (node.kind != .task) {
            if (self.isLegacyClosedTaskNode(node)) return .completed;
            return core.Error.InvalidId;
        }
        return effectiveStatusForLifecycleFields(lifecycle, now_ns, .strict);
    }
};

/// Recognize the pre-status task-close encoding without converting a record
/// that the canonical task lifecycle reader would reject after migration.
/// A legacy closed task has no explicit status marker, but every lifecycle
/// field that is present must still satisfy the terminal-task invariants.
pub fn lifecycleFieldsRepresentLegacyClosedTask(lifecycle: StatusSnapshot.LifecycleFields) bool {
    if (lifecycle.invalid_value_type or lifecycle.stored_status_raw != null) return false;
    if (lifecycle.claimed_by) |holder| {
        if (holder.len == 0 or holder.len > max_claim_holder_len) return false;
    }
    inline for (.{ lifecycle.task_recorded_ns, lifecycle.task_created_ns, lifecycle.task_completed_ns }) |timestamp| {
        if (timestamp != null and timestamp.? == 0) return false;
    }
    const created_ns = lifecycle.task_created_ns orelse return false;
    const completed_ns = lifecycle.task_completed_ns orelse return false;
    return completed_ns >= created_ns;
}

pub const LifecycleReadPolicy = enum {
    strict,
    migration_repair_nonterminal_completion,
};

/// Interpret one task lifecycle record without losing whether `status` was
/// actually present.  A live lease is a compatibility status source only for
/// pre-status tasks; once a writer explicitly commits `status=open`, a future
/// expiry is contradictory rather than an implicit claim.
pub fn effectiveStatusForLifecycleFields(
    lifecycle: StatusSnapshot.LifecycleFields,
    now_ns: u64,
    policy: LifecycleReadPolicy,
) !Status {
    if (lifecycle.invalid_value_type) return error.InvalidTaskLifecycle;
    const has_explicit_status = lifecycle.stored_status_raw != null;
    const stored = if (lifecycle.stored_status_raw) |raw|
        Status.parse(raw) orelse return error.InvalidTaskLifecycle
    else
        Status.open;

    if (lifecycle.claimed_by) |holder| {
        if (holder.len == 0 or holder.len > max_claim_holder_len) return error.InvalidTaskLifecycle;
    }
    // Runtime reads and import must enforce one lifecycle model.  Without
    // these checks a raw writer or torn legacy producer can create states
    // such as `open + task_completed_ns`, which then poison frontier and
    // completion metrics while still looking executable.
    inline for (.{ lifecycle.task_recorded_ns, lifecycle.task_created_ns, lifecycle.task_completed_ns }) |timestamp| {
        if (timestamp != null and timestamp.? == 0) return error.InvalidTaskLifecycle;
    }
    if (stored.isTerminal()) {
        const completed_ns = lifecycle.task_completed_ns orelse return error.InvalidTaskLifecycle;
        if (lifecycle.task_created_ns) |created_ns| {
            if (completed_ns < created_ns) return error.InvalidTaskLifecycle;
        }
        return stored;
    }
    if (lifecycle.task_completed_ns != null and policy == .strict) return error.InvalidTaskLifecycle;

    const lease_expires_ns = lifecycle.claim_expires_ns orelse 0;
    if (stored == .claimed) {
        if (lifecycle.claimed_by == null or lease_expires_ns == 0) return error.InvalidTaskLifecycle;
        return if (lease_expires_ns > now_ns) .claimed else .open;
    }
    if (lease_expires_ns > now_ns) {
        if (has_explicit_status or lifecycle.claimed_by == null) return error.InvalidTaskLifecycle;
        return .claimed;
    }
    return .open;
}

/// Compatibility rule for pre-status stores.  Only verification/fix nodes
/// carrying both task lifecycle timestamps are legacy closed tasks; ordinary
/// verification evidence must never be reclassified by kind alone.
pub fn isLegacyClosedTask(
    allocator: std.mem.Allocator,
    store: storage.Store,
    node: storage.StoredNode,
) !bool {
    if (node.kind != .verification and node.kind != .fix) return false;
    // Use the same typed snapshot interpretation as batched callers.  Point
    // getters reject a different value type as storage corruption, but these
    // globally named properties can legally belong to a non-task vocabulary.
    var snapshot = try StatusSnapshot.initForNodeIds(allocator, store, &.{node.id});
    defer snapshot.deinit();
    return snapshot.isLegacyClosedTaskNode(node);
}

/// Return the effective status at a single read timestamp.  `claimed` is
/// lease-backed: an expired claim reads as open even if a crash left the
/// status commit marker at `claimed`.  Conversely, a live legacy lease reads
/// as claimed before the explicit status migration has run.
pub fn statusForStoredNode(
    allocator: std.mem.Allocator,
    store: storage.Store,
    node: storage.StoredNode,
    now_ns: u64,
) !Status {
    var snapshot = try StatusSnapshot.initForNodeIds(allocator, store, &.{node.id});
    defer snapshot.deinit();
    return snapshot.statusForStoredNode(node, now_ns);
}

pub fn statusWithPersistentStoreAt(
    allocator: std.mem.Allocator,
    store: storage.Store,
    task_id: core.NodeId,
    now_ns: u64,
) !Status {
    if (isReservedNodeId(task_id)) return core.Error.InvalidId;
    var node = (try store.readNodeById(allocator, task_id)) orelse return core.Error.NotFound;
    defer node.deinit(allocator);
    return statusForStoredNode(allocator, store, node, now_ns);
}

pub fn statusWithPersistentStore(
    allocator: std.mem.Allocator,
    store: storage.Store,
    task_id: core.NodeId,
) !Status {
    const timestamp = std.Io.Clock.real.now(store.io).nanoseconds;
    const now_ns: u64 = if (timestamp < 0) 0 else @intCast(timestamp);
    return statusWithPersistentStoreAt(allocator, store, task_id, now_ns);
}

test "claimed status is lease backed and malformed status is rejected" {
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
        .{ .id = .fromInt(1), .kind = .task, .text = "leased" },
        .{ .id = .fromInt(2), .kind = .task, .text = "broken" },
    });
    try store.setNodeStringProperty(std.testing.allocator, .fromInt(1), status_property, @tagName(Status.claimed));
    try store.setNodeStringProperty(std.testing.allocator, .fromInt(1), claimed_by_property, "agent-a");
    try store.setUintProperty(std.testing.allocator, .{ .node = .fromInt(1) }, claim_expires_ns_property, 100);
    try std.testing.expectEqual(Status.claimed, try statusWithPersistentStoreAt(std.testing.allocator, store, .fromInt(1), 99));
    try std.testing.expectEqual(Status.open, try statusWithPersistentStoreAt(std.testing.allocator, store, .fromInt(1), 100));

    try store.setNodeStringProperty(std.testing.allocator, .fromInt(2), status_property, "done-ish");
    try std.testing.expectError(error.InvalidTaskLifecycle, statusWithPersistentStoreAt(std.testing.allocator, store, .fromInt(2), 0));
}

test "runtime distinguishes legacy live leases from explicit open contradictions" {
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
        .{ .id = .fromInt(1), .kind = .task, .text = "legacy live lease" },
        .{ .id = .fromInt(2), .kind = .task, .text = "explicit open live lease" },
        .{ .id = .fromInt(3), .kind = .task, .text = "future expiry without holder" },
        .{ .id = .fromInt(4), .kind = .task, .text = "oversized holder" },
    });
    const oversized_holder = [_]u8{'x'} ** (max_claim_holder_len + 1);
    _ = try store.upsertPropertiesBatch(std.testing.allocator, &.{
        .{ .owner = .{ .node = .fromInt(1) }, .key = claimed_by_property, .value = .{ .string = "legacy-agent" } },
        .{ .owner = .{ .node = .fromInt(1) }, .key = claim_expires_ns_property, .value = .{ .uint = 100 } },
        .{ .owner = .{ .node = .fromInt(2) }, .key = status_property, .value = .{ .string = "open" } },
        .{ .owner = .{ .node = .fromInt(2) }, .key = claimed_by_property, .value = .{ .string = "agent-a" } },
        .{ .owner = .{ .node = .fromInt(2) }, .key = claim_expires_ns_property, .value = .{ .uint = 100 } },
        .{ .owner = .{ .node = .fromInt(3) }, .key = claim_expires_ns_property, .value = .{ .uint = 100 } },
        .{ .owner = .{ .node = .fromInt(4) }, .key = status_property, .value = .{ .string = "open" } },
        .{ .owner = .{ .node = .fromInt(4) }, .key = claimed_by_property, .value = .{ .string = &oversized_holder } },
        .{ .owner = .{ .node = .fromInt(4) }, .key = claim_expires_ns_property, .value = .{ .uint = 1 } },
    });

    {
        var node = (try store.readNodeById(std.testing.allocator, .fromInt(1))).?;
        defer node.deinit(std.testing.allocator);
        try std.testing.expectEqual(Status.claimed, try statusForStoredNode(std.testing.allocator, store, node, 99));
        try std.testing.expectEqual(Status.open, try statusForStoredNode(std.testing.allocator, store, node, 100));
    }
    {
        var node = (try store.readNodeById(std.testing.allocator, .fromInt(2))).?;
        defer node.deinit(std.testing.allocator);
        try std.testing.expectError(error.InvalidTaskLifecycle, statusForStoredNode(std.testing.allocator, store, node, 99));
        try std.testing.expectEqual(Status.open, try statusForStoredNode(std.testing.allocator, store, node, 100));
    }
    inline for (.{ 3, 4 }) |raw_id| {
        var node = (try store.readNodeById(std.testing.allocator, .fromInt(raw_id))).?;
        defer node.deinit(std.testing.allocator);
        try std.testing.expectError(error.InvalidTaskLifecycle, statusForStoredNode(std.testing.allocator, store, node, 99));
    }
}

test "migration lifecycle repair does not hide explicit open live leases" {
    const stale_completion: StatusSnapshot.LifecycleFields = .{
        .stored_status_raw = "claimed",
        .claimed_by = "agent-a",
        .claim_expires_ns = 1,
        .task_completed_ns = 42,
    };
    try std.testing.expectError(error.InvalidTaskLifecycle, effectiveStatusForLifecycleFields(stale_completion, 99, .strict));
    try std.testing.expectEqual(Status.open, try effectiveStatusForLifecycleFields(stale_completion, 99, .migration_repair_nonterminal_completion));

    const explicit_open_live: StatusSnapshot.LifecycleFields = .{
        .stored_status_raw = "open",
        .claimed_by = "agent-a",
        .claim_expires_ns = 100,
    };
    try std.testing.expectError(error.InvalidTaskLifecycle, effectiveStatusForLifecycleFields(explicit_open_live, 99, .migration_repair_nonterminal_completion));

    const legacy_live: StatusSnapshot.LifecycleFields = .{
        .claimed_by = "legacy-agent",
        .claim_expires_ns = 100,
    };
    try std.testing.expectEqual(Status.claimed, try effectiveStatusForLifecycleFields(legacy_live, 99, .migration_repair_nonterminal_completion));
}

test "runtime task status enforces terminal timestamp invariants" {
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
        .{ .id = .fromInt(1), .kind = .task, .text = "open with completion" },
        .{ .id = .fromInt(2), .kind = .task, .text = "terminal without completion" },
        .{ .id = .fromInt(3), .kind = .task, .text = "backwards completion" },
        .{ .id = .fromInt(4), .kind = .task, .text = "valid terminal" },
        .{ .id = .fromInt(5), .kind = .task, .text = "claimed without lease" },
    });
    _ = try store.upsertPropertiesBatch(std.testing.allocator, &.{
        .{ .owner = .{ .node = .fromInt(1) }, .key = status_property, .value = .{ .string = "open" } },
        .{ .owner = .{ .node = .fromInt(1) }, .key = task_completed_ns_property, .value = .{ .uint = 10 } },
        .{ .owner = .{ .node = .fromInt(2) }, .key = status_property, .value = .{ .string = "completed" } },
        .{ .owner = .{ .node = .fromInt(3) }, .key = status_property, .value = .{ .string = "completed" } },
        .{ .owner = .{ .node = .fromInt(3) }, .key = task_created_ns_property, .value = .{ .uint = 11 } },
        .{ .owner = .{ .node = .fromInt(3) }, .key = task_completed_ns_property, .value = .{ .uint = 10 } },
        .{ .owner = .{ .node = .fromInt(4) }, .key = status_property, .value = .{ .string = "failed" } },
        .{ .owner = .{ .node = .fromInt(4) }, .key = task_created_ns_property, .value = .{ .uint = 10 } },
        .{ .owner = .{ .node = .fromInt(4) }, .key = task_completed_ns_property, .value = .{ .uint = 11 } },
        .{ .owner = .{ .node = .fromInt(5) }, .key = status_property, .value = .{ .string = "claimed" } },
    });

    var snapshot = try StatusSnapshot.initForNodeIds(std.testing.allocator, store, &.{ .fromInt(1), .fromInt(2), .fromInt(3), .fromInt(4), .fromInt(5) });
    defer snapshot.deinit();
    inline for (1..6) |raw_id| {
        var node = (try store.readNodeById(std.testing.allocator, .fromInt(raw_id))).?;
        defer node.deinit(std.testing.allocator);
        if (raw_id == 4) {
            try std.testing.expectEqual(Status.failed, try snapshot.statusForStoredNode(node, 0));
        } else {
            try std.testing.expectError(error.InvalidTaskLifecycle, snapshot.statusForStoredNode(node, 0));
        }
    }
}

test "task status snapshot is owner bounded and preserves lease semantics" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();
    const target = try store.addNode(.task, "target");
    const unrelated = try store.addNode(.task, "unrelated");
    const huge_holder = [_]u8{'x'} ** (64 * 1024);
    try store.appendPropertiesBatch(std.testing.allocator, &.{
        .{ .owner = .{ .node = target }, .key = status_property, .value = .{ .string = "claimed" } },
        .{ .owner = .{ .node = target }, .key = claimed_by_property, .value = .{ .string = "agent-a" } },
        .{ .owner = .{ .node = target }, .key = claim_expires_ns_property, .value = .{ .uint = 100 } },
        .{ .owner = .{ .node = unrelated }, .key = status_property, .value = .{ .string = "open" } },
        .{ .owner = .{ .node = unrelated }, .key = claimed_by_property, .value = .{ .string = &huge_holder } },
    });

    var scratch: [16 * 1024]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&scratch);
    var snapshot = try StatusSnapshot.initForNodeIds(fixed.allocator(), store, &.{target});
    defer snapshot.deinit();
    try std.testing.expect(snapshot.covers(target));
    try std.testing.expect(!snapshot.covers(unrelated));
    const claim = snapshot.claim(target);
    try std.testing.expectEqualStrings("agent-a", claim.holder.?);
    try std.testing.expect(claim.active(99));
    try std.testing.expect(!claim.active(100));

    var node = (try store.readNodeById(std.testing.allocator, target)).?;
    defer node.deinit(std.testing.allocator);
    try std.testing.expectEqual(Status.claimed, try snapshot.statusForStoredNode(node, 99));
    try std.testing.expectEqual(Status.open, try snapshot.statusForStoredNode(node, 100));
}

test "global task status snapshot ignores non-task status vocabularies" {
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
        .{ .id = .fromInt(1), .kind = .concept, .text = "published article" },
        .{ .id = .fromInt(2), .kind = .task, .text = "malformed task" },
        .{ .id = .fromInt(3), .kind = .concept, .text = "numeric workflow state" },
        .{ .id = .fromInt(4), .kind = .task, .text = "wrong lifecycle value type" },
    });
    try store.setNodeStringProperty(std.testing.allocator, .fromInt(1), status_property, "published");
    try store.setNodeStringProperty(std.testing.allocator, .fromInt(2), status_property, "done-ish");
    try store.setUintProperty(std.testing.allocator, .{ .node = .fromInt(3) }, status_property, 7);
    try store.setUintProperty(std.testing.allocator, .{ .node = .fromInt(3) }, claimed_by_property, 42);
    try store.setNodeStringProperty(std.testing.allocator, .fromInt(3), claim_expires_ns_property, "later");
    try store.setUintProperty(std.testing.allocator, .{ .node = .fromInt(4) }, status_property, 1);

    var snapshot = try StatusSnapshot.init(std.testing.allocator, store);
    defer snapshot.deinit();
    var concept = (try store.readNodeById(std.testing.allocator, .fromInt(1))).?;
    defer concept.deinit(std.testing.allocator);
    try std.testing.expectError(core.Error.InvalidId, snapshot.statusForStoredNode(concept, 0));
    var malformed_task = (try store.readNodeById(std.testing.allocator, .fromInt(2))).?;
    defer malformed_task.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidTaskLifecycle, snapshot.statusForStoredNode(malformed_task, 0));
    var numeric_concept = (try store.readNodeById(std.testing.allocator, .fromInt(3))).?;
    defer numeric_concept.deinit(std.testing.allocator);
    try std.testing.expectError(core.Error.InvalidId, snapshot.statusForStoredNode(numeric_concept, 0));
    var wrong_type_task = (try store.readNodeById(std.testing.allocator, .fromInt(4))).?;
    defer wrong_type_task.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidTaskLifecycle, snapshot.statusForStoredNode(wrong_type_task, 0));
}

test "legacy closed task detection rejects explicit status and backwards timestamps" {
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
        .{ .id = .fromInt(1), .kind = .verification, .text = "legacy closed task" },
        .{ .id = .fromInt(2), .kind = .verification, .text = "published verification" },
        .{ .id = .fromInt(3), .kind = .fix, .text = "backwards audit" },
        .{ .id = .fromInt(4), .kind = .fix, .text = "numeric workflow state" },
    });
    _ = try store.upsertPropertiesBatch(std.testing.allocator, &.{
        .{ .owner = .{ .node = .fromInt(1) }, .key = task_created_ns_property, .value = .{ .uint = 10 } },
        .{ .owner = .{ .node = .fromInt(1) }, .key = task_completed_ns_property, .value = .{ .uint = 20 } },
        .{ .owner = .{ .node = .fromInt(2) }, .key = status_property, .value = .{ .string = "published" } },
        .{ .owner = .{ .node = .fromInt(2) }, .key = task_created_ns_property, .value = .{ .uint = 10 } },
        .{ .owner = .{ .node = .fromInt(2) }, .key = task_completed_ns_property, .value = .{ .uint = 20 } },
        .{ .owner = .{ .node = .fromInt(3) }, .key = task_created_ns_property, .value = .{ .uint = 20 } },
        .{ .owner = .{ .node = .fromInt(3) }, .key = task_completed_ns_property, .value = .{ .uint = 10 } },
        .{ .owner = .{ .node = .fromInt(4) }, .key = status_property, .value = .{ .uint = 7 } },
        .{ .owner = .{ .node = .fromInt(4) }, .key = task_created_ns_property, .value = .{ .uint = 10 } },
        .{ .owner = .{ .node = .fromInt(4) }, .key = task_completed_ns_property, .value = .{ .uint = 20 } },
    });

    var snapshot = try StatusSnapshot.init(std.testing.allocator, store);
    defer snapshot.deinit();
    inline for (1..5) |raw_id| {
        var node = (try store.readNodeById(std.testing.allocator, .fromInt(raw_id))).?;
        defer node.deinit(std.testing.allocator);
        const expected = raw_id == 1;
        try std.testing.expectEqual(expected, snapshot.isLegacyClosedTaskNode(node));
        try std.testing.expectEqual(expected, try isLegacyClosedTask(std.testing.allocator, store, node));
        if (expected) {
            try std.testing.expectEqual(Status.completed, try snapshot.statusForStoredNode(node, 0));
        } else {
            try std.testing.expectError(core.Error.InvalidId, snapshot.statusForStoredNode(node, 0));
        }
    }
}

test "legacy closed task detection cannot manufacture invalid terminal lifecycles" {
    const valid: StatusSnapshot.LifecycleFields = .{
        .claimed_by = "legacy-agent",
        .claim_expires_ns = std.math.maxInt(u64),
        .task_recorded_ns = 9,
        .task_created_ns = 10,
        .task_completed_ns = 20,
    };
    try std.testing.expect(lifecycleFieldsRepresentLegacyClosedTask(valid));

    var oversized = valid;
    const oversized_holder = [_]u8{'x'} ** (max_claim_holder_len + 1);
    oversized.claimed_by = &oversized_holder;
    try std.testing.expect(!lifecycleFieldsRepresentLegacyClosedTask(oversized));

    var zero_recorded = valid;
    zero_recorded.task_recorded_ns = 0;
    try std.testing.expect(!lifecycleFieldsRepresentLegacyClosedTask(zero_recorded));
}

fn statusForReadyNode(
    allocator: std.mem.Allocator,
    store: storage.Store,
    node: storage.StoredNode,
    now_ns: u64,
) !Status {
    if (node.kind == .task) return statusForStoredNode(allocator, store, node, now_ns);
    // Preserve the pre-status DAG contract: verification evidence has always
    // satisfied a dependency edge even when it was never a rewritten task.
    // New task lifecycle transitions no longer create such nodes, but old
    // stores and non-task workflows still rely on this meaning.
    if (node.kind == .verification) return .completed;
    if (try isLegacyClosedTask(allocator, store, node)) return .completed;
    return .open;
}

fn statusForReadyNodeFromSnapshot(snapshot: *const StatusSnapshot, node: storage.StoredNode, now_ns: u64) !Status {
    if (node.kind == .task) return snapshot.statusForStoredNode(node, now_ns);
    if (node.kind == .verification) return .completed;
    if (snapshot.isLegacyClosedTaskNode(node)) return .completed;
    return .open;
}

fn isReservedNodeId(id: core.NodeId) bool {
    return id == .none or id.toInt() == std.math.maxInt(u64);
}

pub fn readyState(graph: *const graph_mod.Graph, task_id: core.NodeId) !ReadyState {
    var mem_index = try index.MemoryIndex.init(graph.allocator, graph);
    defer mem_index.deinit();
    return readyStateWithIndex(graph, &mem_index, task_id);
}

pub fn readyStateWithIndex(graph: *const graph_mod.Graph, mem_index: *index.MemoryIndex, task_id: core.NodeId) !ReadyState {
    return readyStateWithCursor(graph.allocator, graph, mem_index, .{ .memory = .{ .mem_index = mem_index } }, task_id);
}

pub fn readyStateWithCursor(
    allocator: std.mem.Allocator,
    graph: *const graph_mod.Graph,
    mem_index: *index.MemoryIndex,
    edge_cursor: query.EdgeCursor,
    task_id: core.NodeId,
) !ReadyState {
    _ = allocator;
    if (isReservedNodeId(task_id)) return core.Error.InvalidId;
    const task_node = mem_index.getNode(graph, task_id) orelse return core.Error.NotFound;
    if (task_node.kind != .task) return core.Error.InvalidId;

    var node_reader = ReadyNodeReader{ .memory = .{ .graph = graph, .mem_index = mem_index } };
    var blocker_ctx = ReadyBlockerContext{
        .node_reader = &node_reader,
        .blocked = false,
    };
    _ = try edge_cursor.forEachIncomingRelation(task_id, .blocks, &blocker_ctx, detectBlocker);
    if (blocker_ctx.blocked) return .blocked;

    var dep_ctx = ReadyDependencyContext{
        .node_reader = &node_reader,
        .has_missing_dep = false,
    };
    _ = try edge_cursor.forEachOutgoingRelation(task_id, .depends_on, &dep_ctx, detectMissingDependency);
    if (dep_ctx.has_missing_dep) return .missing_dependencies;

    var pred_ctx = ReadyPredecessorContext{
        .node_reader = &node_reader,
        .has_open_predecessor = false,
    };
    _ = try edge_cursor.forEachIncomingRelation(task_id, .precedes, &pred_ctx, detectOpenPredecessor);
    return if (pred_ctx.has_open_predecessor) .missing_dependencies else .ready;
}

const ReadyBlockerContext = struct {
    node_reader: *ReadyNodeReader,
    blocked: bool,
    budget: ?core.QueryBudget = null,
    nodes_visited: ?*usize = null,
    edges_visited: ?*usize = null,
    deadline: core.QueryDeadline = .none,
};

fn detectBlocker(ctx: *ReadyBlockerContext, edge: index.EdgeRef) !bool {
    try chargeReadyContextEdge(ctx.edges_visited, ctx.budget, ctx.deadline);
    if (edge.rel == .blocks) {
        try chargeReadyContextNode(ctx.nodes_visited, ctx.budget);
        const blocker = (try ctx.node_reader.read(edge.src)) orelse return false;
        defer blocker.deinit();
        if (blocker.kind != .task or blocker.status == .completed) return false;
        ctx.blocked = true;
        return true;
    }
    return false;
}

const ReadyDependencyContext = struct {
    node_reader: *ReadyNodeReader,
    has_missing_dep: bool,
    budget: ?core.QueryBudget = null,
    nodes_visited: ?*usize = null,
    edges_visited: ?*usize = null,
    deadline: core.QueryDeadline = .none,
};

fn detectMissingDependency(ctx: *ReadyDependencyContext, edge: index.EdgeRef) !bool {
    try chargeReadyContextEdge(ctx.edges_visited, ctx.budget, ctx.deadline);
    if (edge.rel != .depends_on) return false;
    try chargeReadyContextNode(ctx.nodes_visited, ctx.budget);
    const dep = (try ctx.node_reader.read(edge.dst)) orelse return core.Error.NotFound;
    defer dep.deinit();
    if (dep.status == .completed) return false;
    ctx.has_missing_dep = true;
    return false;
}

const ReadyPredecessorContext = struct {
    node_reader: *ReadyNodeReader,
    has_open_predecessor: bool,
    budget: ?core.QueryBudget = null,
    nodes_visited: ?*usize = null,
    edges_visited: ?*usize = null,
    deadline: core.QueryDeadline = .none,
};

/// precedes 前驱调度语义(与 blocker 同风格:只有 task 参与调度)。
/// X ─precedes→ T 且 X 的 status 不是 completed → T 未就绪。
fn detectOpenPredecessor(ctx: *ReadyPredecessorContext, edge: index.EdgeRef) !bool {
    try chargeReadyContextEdge(ctx.edges_visited, ctx.budget, ctx.deadline);
    if (edge.rel != .precedes) return false;
    try chargeReadyContextNode(ctx.nodes_visited, ctx.budget);
    const pred = (try ctx.node_reader.read(edge.src)) orelse return false;
    defer pred.deinit();
    if (pred.kind != .task or pred.status == .completed) return false;
    ctx.has_open_predecessor = true;
    return true;
}

const ReadyNodeReader = union(enum) {
    const direct_reads_before_view = 2;

    memory: struct {
        graph: *const graph_mod.Graph,
        mem_index: *index.MemoryIndex,
    },
    persistent_store: struct {
        allocator: std.mem.Allocator,
        store: storage.Store,
        now_ns: u64,
        status_snapshot: ?*const StatusSnapshot = null,
        missing_is_invalid: bool = false,
        node_view: ?storage.Store.NodeRecordView = null,
        direct_reads: usize = 0,
    },

    const BorrowedNode = struct {
        kind: core.NodeKind,
        status: Status,
        stored: ?storage.StoredNode = null,
        allocator: ?std.mem.Allocator = null,

        fn deinit(self: BorrowedNode) void {
            if (self.stored) |stored| {
                var node = stored;
                node.deinit(self.allocator.?);
            }
        }
    };

    fn deinit(self: *ReadyNodeReader) void {
        switch (self.*) {
            .persistent_store => |*reader| {
                if (reader.node_view) |*view| view.deinit();
            },
            .memory => {},
        }
    }

    fn read(self: *ReadyNodeReader, id: core.NodeId) !?BorrowedNode {
        return switch (self.*) {
            .memory => |reader| {
                const node = reader.mem_index.getNode(reader.graph, id) orelse return null;
                // In-memory Graph has no property sidecar.  Keep legacy closed
                // kind support for this compatibility-only API; persistent
                // scheduling always reads the canonical status property.
                const node_status: Status = switch (node.kind) {
                    .verification, .fix => .completed,
                    else => .open,
                };
                return .{ .kind = node.kind, .status = node_status };
            },
            .persistent_store => |*reader| {
                if (reader.node_view == null and reader.direct_reads < direct_reads_before_view) {
                    reader.direct_reads += 1;
                    var stored = (try reader.store.readNodeById(reader.allocator, id)) orelse {
                        if (reader.missing_is_invalid) return error.InvalidRecord;
                        return null;
                    };
                    errdefer stored.deinit(reader.allocator);
                    const node_status = if (reader.status_snapshot) |snapshot| blk: {
                        if (snapshot.covers(stored.id)) break :blk try statusForReadyNodeFromSnapshot(snapshot, stored, reader.now_ns);
                        break :blk try statusForReadyNode(reader.allocator, reader.store, stored, reader.now_ns);
                    } else try statusForReadyNode(reader.allocator, reader.store, stored, reader.now_ns);
                    return .{ .kind = stored.kind, .status = node_status, .stored = stored, .allocator = reader.allocator };
                }
                if (reader.node_view == null) reader.node_view = try reader.store.openNodeRecordView();
                var stored = (try reader.node_view.?.readNodeById(reader.allocator, id)) orelse {
                    if (reader.missing_is_invalid) return error.InvalidRecord;
                    return null;
                };
                errdefer stored.deinit(reader.allocator);
                const node_status = if (reader.status_snapshot) |snapshot| blk: {
                    if (snapshot.covers(stored.id)) break :blk try statusForReadyNodeFromSnapshot(snapshot, stored, reader.now_ns);
                    break :blk try statusForReadyNode(reader.allocator, reader.store, stored, reader.now_ns);
                } else try statusForReadyNode(reader.allocator, reader.store, stored, reader.now_ns);
                return .{ .kind = stored.kind, .status = node_status, .stored = stored, .allocator = reader.allocator };
            },
        };
    }
};

pub fn readyStateWithPersistentStore(allocator: std.mem.Allocator, store: storage.Store, task_id: core.NodeId) !ReadyState {
    const timestamp = std.Io.Clock.real.now(store.io).nanoseconds;
    const now_ns: u64 = if (timestamp < 0) 0 else @intCast(timestamp);
    return readyStateWithPersistentStoreAt(allocator, store, task_id, now_ns);
}

pub fn readyStateWithPersistentStoreAt(allocator: std.mem.Allocator, store: storage.Store, task_id: core.NodeId, now_ns: u64) !ReadyState {
    return readyStateWithPersistentStoreBudgetAtSnapshot(allocator, store, task_id, .{}, now_ns, null);
}

pub fn readyStateWithPersistentStoreSnapshotAt(
    allocator: std.mem.Allocator,
    store: storage.Store,
    task_id: core.NodeId,
    now_ns: u64,
    status_snapshot: *const StatusSnapshot,
) !ReadyState {
    return readyStateWithPersistentStoreBudgetAtSnapshot(allocator, store, task_id, .{}, now_ns, status_snapshot);
}

pub const ReadyTraversalStats = struct {
    nodes_visited: usize = 0,
    edges_visited: usize = 0,
};

/// Readiness inspection with caller-visible traversal accounting. This is
/// used by aggregate callers that must enforce one budget across many task
/// rows instead of silently resetting the query budget for every row.
pub fn readyStateWithPersistentStoreSnapshotBudgetAt(
    allocator: std.mem.Allocator,
    store: storage.Store,
    task_id: core.NodeId,
    budget: core.QueryBudget,
    now_ns: u64,
    status_snapshot: *const StatusSnapshot,
    stats: *ReadyTraversalStats,
) !ReadyState {
    return readyStateWithPersistentStoreBudgetAtSnapshotTracked(allocator, store, task_id, budget, now_ns, status_snapshot, stats);
}

pub fn readyStateWithPersistentStoreBudget(allocator: std.mem.Allocator, store: storage.Store, task_id: core.NodeId, budget: core.QueryBudget) !ReadyState {
    const timestamp = std.Io.Clock.real.now(store.io).nanoseconds;
    const now_ns: u64 = if (timestamp < 0) 0 else @intCast(timestamp);
    return readyStateWithPersistentStoreBudgetAt(allocator, store, task_id, budget, now_ns);
}

pub fn readyStateWithPersistentStoreBudgetAt(allocator: std.mem.Allocator, store: storage.Store, task_id: core.NodeId, budget: core.QueryBudget, now_ns: u64) !ReadyState {
    return readyStateWithPersistentStoreBudgetAtSnapshot(allocator, store, task_id, budget, now_ns, null);
}

fn readyStateWithPersistentStoreBudgetAtSnapshot(
    allocator: std.mem.Allocator,
    store: storage.Store,
    task_id: core.NodeId,
    budget: core.QueryBudget,
    now_ns: u64,
    status_snapshot: ?*const StatusSnapshot,
) !ReadyState {
    var stats = ReadyTraversalStats{};
    return readyStateWithPersistentStoreBudgetAtSnapshotTracked(allocator, store, task_id, budget, now_ns, status_snapshot, &stats);
}

fn readyStateWithPersistentStoreBudgetAtSnapshotTracked(
    allocator: std.mem.Allocator,
    store: storage.Store,
    task_id: core.NodeId,
    budget: core.QueryBudget,
    now_ns: u64,
    status_snapshot: ?*const StatusSnapshot,
    stats: *ReadyTraversalStats,
) !ReadyState {
    var repaired = false;
    while (true) {
        return readyStateWithPersistentStoreOnce(allocator, store, task_id, budget, now_ns, status_snapshot, stats) catch |err| switch (err) {
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

fn readyStateWithPersistentStoreOnce(
    allocator: std.mem.Allocator,
    store: storage.Store,
    task_id: core.NodeId,
    budget: core.QueryBudget,
    now_ns: u64,
    status_snapshot: ?*const StatusSnapshot,
    stats: *ReadyTraversalStats,
) !ReadyState {
    if (isReservedNodeId(task_id)) return core.Error.InvalidId;
    const deadline = core.QueryDeadline.fromIo(store.io, budget.timeout_ms);
    if (deadline.expired()) return core.Error.BudgetExceeded;
    try chargeReadyNode(&stats.nodes_visited, budget);
    var task_node = (try store.readNodeById(allocator, task_id)) orelse return core.Error.NotFound;
    defer task_node.deinit(allocator);
    if (task_node.kind != .task) return core.Error.InvalidId;

    const cursor = query.EdgeCursor{ .persistent_store = .{
        .allocator = allocator,
        .store = store,
    } };
    var node_reader = ReadyNodeReader{ .persistent_store = .{
        .allocator = allocator,
        .store = store,
        .now_ns = now_ns,
        .status_snapshot = status_snapshot,
        .missing_is_invalid = true,
    } };
    defer node_reader.deinit();
    var blocker_ctx = ReadyBlockerContext{
        .node_reader = &node_reader,
        .blocked = false,
        .budget = budget,
        .nodes_visited = &stats.nodes_visited,
        .edges_visited = &stats.edges_visited,
        .deadline = deadline,
    };
    _ = try cursor.forEachIncomingRelation(task_id, .blocks, &blocker_ctx, detectBlocker);
    if (blocker_ctx.blocked) return .blocked;

    var dep_ctx = ReadyDependencyContext{
        .node_reader = &node_reader,
        .has_missing_dep = false,
        .budget = budget,
        .nodes_visited = &stats.nodes_visited,
        .edges_visited = &stats.edges_visited,
        .deadline = deadline,
    };
    _ = try cursor.forEachOutgoingRelation(task_id, .depends_on, &dep_ctx, detectMissingDependency);
    if (dep_ctx.has_missing_dep) return .missing_dependencies;

    var pred_ctx = ReadyPredecessorContext{
        .node_reader = &node_reader,
        .has_open_predecessor = false,
        .budget = budget,
        .nodes_visited = &stats.nodes_visited,
        .edges_visited = &stats.edges_visited,
        .deadline = deadline,
    };
    _ = try cursor.forEachIncomingRelation(task_id, .precedes, &pred_ctx, detectOpenPredecessor);
    return if (pred_ctx.has_open_predecessor) .missing_dependencies else .ready;
}

fn chargeReadyContextNode(nodes_visited: ?*usize, budget: ?core.QueryBudget) !void {
    const visited = nodes_visited orelse return;
    try chargeReadyNode(visited, budget orelse return core.Error.Unsupported);
}

fn chargeReadyContextEdge(edges_visited: ?*usize, budget: ?core.QueryBudget, deadline: core.QueryDeadline) !void {
    if (deadline.expired()) return core.Error.BudgetExceeded;
    const visited = edges_visited orelse return;
    try chargeReadyEdge(visited, budget orelse return core.Error.Unsupported);
}

fn chargeReadyNode(nodes_visited: *usize, budget: core.QueryBudget) !void {
    if (nodes_visited.* >= budget.max_visited_nodes) return core.Error.BudgetExceeded;
    nodes_visited.* += 1;
}

fn chargeReadyEdge(edges_visited: *usize, budget: core.QueryBudget) !void {
    if (edges_visited.* >= budget.max_visited_edges) return core.Error.BudgetExceeded;
    edges_visited.* += 1;
}

test "DAG relation cycle check detects simple cycle" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();

    const a = try graph.addNode(.task, "a");
    const b = try graph.addNode(.task, "b");
    _ = try graph.addEdgeUnchecked(a, .depends_on, b);

    try std.testing.expect(try wouldCreateCycle(&graph, b, a, .depends_on, .{}));
    try std.testing.expect(!try wouldCreateCycle(&graph, b, a, .calls, .{}));
}

test "ready state detects blockers before dependencies" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();

    const task = try graph.addNode(.task, "ship");
    const dep = try graph.addNode(.task, "write tests");
    _ = try graph.addEdgeUnchecked(task, .depends_on, dep);
    try std.testing.expectEqual(ReadyState.missing_dependencies, try readyState(&graph, task));

    const blocker = try graph.addNode(.task, "blocked");
    _ = try graph.addEdgeUnchecked(blocker, .blocks, task);
    try std.testing.expectEqual(ReadyState.blocked, try readyState(&graph, task));
}

test "ready state does not treat tasks blocked by focus as blockers of focus" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();

    const task = try graph.addNode(.task, "ship");
    const blocked_other = try graph.addNode(.task, "blocked other");
    _ = try graph.addEdgeUnchecked(task, .blocks, blocked_other);

    try std.testing.expectEqual(ReadyState.ready, try readyState(&graph, task));
    try std.testing.expectEqual(ReadyState.blocked, try readyState(&graph, blocked_other));
}

test "ready state ignores non-task blocker endpoints" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();

    const task = try graph.addNode(.task, "ship");
    const file = try graph.addNode(.file, "src/main.zig");
    _ = try graph.addEdgeUnchecked(file, .blocks, task);

    try std.testing.expectEqual(ReadyState.ready, try readyState(&graph, task));
}

test "ready state skips dangling incoming blocker endpoints" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();

    const task = try graph.addNode(.task, "ship");
    try graph.edges.append(std.testing.allocator, .{
        .id = .fromInt(1),
        .src = .fromInt(99),
        .dst = task,
        .rel = .blocks,
    });

    try std.testing.expectEqual(ReadyState.ready, try readyState(&graph, task));
}

test "ready state streams edge cursor without materializing adjacency" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();

    const task = try graph.addNode(.task, "ship");
    const dep = try graph.addNode(.task, "write tests");
    _ = try graph.addEdgeUnchecked(task, .depends_on, dep);

    var mem_index = try index.MemoryIndex.init(std.testing.allocator, &graph);
    defer mem_index.deinit();
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectEqual(
        ReadyState.missing_dependencies,
        try readyStateWithCursor(failing.allocator(), &graph, &mem_index, .{ .memory = .{ .mem_index = &mem_index } }, task),
    );
    try std.testing.expectEqual(@as(usize, 0), failing.alloc_index);
}

test "ready state rejects non-task nodes" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();

    const file = try graph.addNode(.file, "src/main.zig");
    try std.testing.expectError(core.Error.InvalidId, readyState(&graph, file));
}

test "ready state rejects reserved task ids before missing-node checks" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();

    try std.testing.expectError(core.Error.InvalidId, readyState(&graph, .none));
    try std.testing.expectError(core.Error.InvalidId, readyState(&graph, .fromInt(std.math.maxInt(u64))));
    try std.testing.expectError(core.Error.NotFound, readyState(&graph, .fromInt(99)));
}

test "ready state uses store-backed edge cursor" {
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
    const task_id = try graph.addNode(.task, "ship");
    const dep = try graph.addNode(.task, "write tests");
    const blocker = try graph.addNode(.task, "blocked");
    const dep_edge = try graph.addEdgeUnchecked(task_id, .depends_on, dep);
    const block_edge = try graph.addEdgeUnchecked(blocker, .blocks, task_id);
    try store.appendNode(graph.nodes.items[0]);
    try store.appendNode(graph.nodes.items[1]);
    try store.appendNode(graph.nodes.items[2]);
    try store.appendEdge(graph.edges.items[dep_edge.toInt() - 1]);
    try store.appendEdge(graph.edges.items[block_edge.toInt() - 1]);

    var loaded = try store.loadGraph();
    defer loaded.deinit();
    var mem_index = try index.MemoryIndex.init(std.testing.allocator, &loaded);
    defer mem_index.deinit();

    const cursor: query.EdgeCursor = .{ .store = .{ .allocator = std.testing.allocator, .store = store, .graph = &loaded } };
    try std.testing.expectEqual(ReadyState.blocked, try readyStateWithCursor(std.testing.allocator, &loaded, &mem_index, cursor, task_id));
}

test "ready state can use persistent store without graph argument" {
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
    const task_id = try graph.addNode(.task, "ship");
    const dep = try graph.addNode(.task, "write tests");
    const blocker = try graph.addNode(.task, "blocked");
    const dep_edge = try graph.addEdgeUnchecked(task_id, .depends_on, dep);
    const block_edge = try graph.addEdgeUnchecked(blocker, .blocks, task_id);
    try store.appendNode(graph.nodes.items[0]);
    try store.appendNode(graph.nodes.items[1]);
    try store.appendNode(graph.nodes.items[2]);
    try store.appendEdge(graph.edges.items[dep_edge.toInt() - 1]);
    try store.appendEdge(graph.edges.items[block_edge.toInt() - 1]);
    try store.ensurePersistentEdgeIndexes(&graph);

    try std.testing.expectEqual(ReadyState.blocked, try readyStateWithPersistentStore(std.testing.allocator, store, task_id));
    try std.testing.expectError(core.Error.BudgetExceeded, readyStateWithPersistentStoreBudget(std.testing.allocator, store, task_id, .{ .timeout_ms = 0 }));
    try std.testing.expectError(core.Error.BudgetExceeded, readyStateWithPersistentStoreBudget(std.testing.allocator, store, task_id, .{ .max_visited_nodes = 0 }));
    try std.testing.expectError(core.Error.BudgetExceeded, readyStateWithPersistentStoreBudget(std.testing.allocator, store, task_id, .{ .max_visited_edges = 0 }));
}

test "malformed dependency lifecycle does not masquerade as index corruption" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();
    const task_id = try store.addNode(.task, "ship");
    const dependency_id = try store.addNode(.task, "broken dependency");
    try store.appendEdge(.{ .id = .fromInt(1), .src = task_id, .dst = dependency_id, .rel = .depends_on });
    try store.setNodeStringProperty(std.testing.allocator, dependency_id, status_property, "not-a-status");

    try std.testing.expectError(
        error.InvalidTaskLifecycle,
        readyStateWithPersistentStore(std.testing.allocator, store, task_id),
    );
}

test "persistent ready state routes blocker scan through published edge segment before index fallback" {
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

    const task_id = core.NodeId.fromInt(1);
    const blocker = core.NodeId.fromInt(2);
    try store.appendNode(.{ .id = task_id, .kind = .task, .text = "ship" });
    try store.appendNode(.{ .id = blocker, .kind = .task, .text = "blocked" });
    try store.appendEdge(.{ .id = .fromInt(1), .src = blocker, .dst = task_id, .rel = .blocks });
    try std.testing.expectEqual(@as(u64, 1), try store.publishEdgeAdjacencySegment(segment_path));

    try std.Io.Dir.cwd().deleteFile(std.testing.io, store.edge_by_dst_path);
    try std.testing.expectEqual(ReadyState.blocked, try readyStateWithPersistentStore(std.testing.allocator, store, task_id));
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().openFile(std.testing.io, store.edge_by_dst_path, .{}));
}

test "ready node reader opens persistent node view after direct read threshold" {
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
    try store.appendNode(.{ .id = .fromInt(1), .kind = .task, .text = "one" });
    try store.appendNode(.{ .id = .fromInt(2), .kind = .task, .text = "two" });
    try store.appendNode(.{ .id = .fromInt(3), .kind = .task, .text = "three" });

    var reader = ReadyNodeReader{ .persistent_store = .{ .allocator = std.testing.allocator, .store = store, .now_ns = 0 } };
    defer reader.deinit();

    var first = (try reader.read(.fromInt(1))).?;
    defer first.deinit();
    try std.testing.expectEqual(core.NodeKind.task, first.kind);
    try std.testing.expectEqual(@as(usize, 1), reader.persistent_store.direct_reads);
    try std.testing.expect(reader.persistent_store.node_view == null);

    var second = (try reader.read(.fromInt(2))).?;
    defer second.deinit();
    try std.testing.expectEqual(core.NodeKind.task, second.kind);
    try std.testing.expectEqual(@as(usize, 2), reader.persistent_store.direct_reads);
    try std.testing.expect(reader.persistent_store.node_view == null);

    var third = (try reader.read(.fromInt(3))).?;
    defer third.deinit();
    try std.testing.expectEqual(core.NodeKind.task, third.kind);
    try std.testing.expectEqual(@as(usize, 2), reader.persistent_store.direct_reads);
    try std.testing.expect(reader.persistent_store.node_view != null);
}

test "ready state persistent path uses relation-bounded incoming edge budget" {
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

    const task_id = core.NodeId.fromInt(1);
    const note = core.NodeId.fromInt(2);
    const blocker = core.NodeId.fromInt(3);
    try store.appendNode(.{ .id = task_id, .kind = .task, .text = "ship" });
    try store.appendNode(.{ .id = note, .kind = .task, .text = "note" });
    try store.appendNode(.{ .id = blocker, .kind = .task, .text = "blocked" });
    try store.appendEdge(.{ .id = .fromInt(1), .src = note, .dst = task_id, .rel = .mentions });
    try store.appendEdge(.{ .id = .fromInt(2), .src = blocker, .dst = task_id, .rel = .blocks });

    try std.testing.expectEqual(.blocked, try readyStateWithPersistentStoreBudget(std.testing.allocator, store, task_id, .{ .max_visited_edges = 1 }));
}

test "ready state persistent path uses relation-bounded outgoing edge budget" {
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

    const task_id = core.NodeId.fromInt(1);
    const note = core.NodeId.fromInt(2);
    const dep = core.NodeId.fromInt(3);
    try store.appendNode(.{ .id = task_id, .kind = .task, .text = "ship" });
    try store.appendNode(.{ .id = note, .kind = .task, .text = "note" });
    try store.appendNode(.{ .id = dep, .kind = .task, .text = "dependency" });
    try store.appendEdge(.{ .id = .fromInt(1), .src = task_id, .dst = note, .rel = .defines });
    try store.appendEdge(.{ .id = .fromInt(2), .src = task_id, .dst = dep, .rel = .depends_on });

    try std.testing.expectEqual(.missing_dependencies, try readyStateWithPersistentStoreBudget(std.testing.allocator, store, task_id, .{ .max_visited_edges = 1 }));
}

test "ready state persistent path ignores non-task blocker endpoints" {
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
    const task_id = try graph.addNode(.task, "ship");
    const file = try graph.addNode(.file, "src/main.zig");
    const edge = try graph.addEdgeUnchecked(file, .blocks, task_id);
    for (graph.nodes.items) |node| try store.appendNode(node);
    try store.appendEdge(graph.edges.items[edge.toInt() - 1]);
    try store.ensurePersistentEdgeIndexes(&graph);

    try std.testing.expectEqual(ReadyState.ready, try readyStateWithPersistentStore(std.testing.allocator, store, task_id));
}

test "ready state persistent path repairs dangling incoming blocker endpoint" {
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
    try store.appendNode(.{ .id = .fromInt(1), .kind = .task, .text = "ship" });
    try store.appendNode(.{ .id = .fromInt(2), .kind = .task, .text = "note source" });
    try store.appendEdge(.{ .id = .fromInt(1), .src = .fromInt(2), .dst = .fromInt(1), .rel = .mentions });

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
    std.mem.writeInt(u64, bytes[record_offset + 8 .. record_offset + 16], 1, .little);
    std.mem.writeInt(u64, bytes[record_offset + 16 .. record_offset + 24], 1, .little);
    std.mem.writeInt(u16, bytes[record_offset + 24 .. record_offset + 26], @intFromEnum(core.RelKind.blocks), .little);
    @memset(bytes[record_offset + 26 .. record_offset + 34], 0);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = store.edge_by_dst_path,
        .data = &bytes,
        .flags = .{ .truncate = true },
    });

    try std.testing.expectEqual(ReadyState.ready, try readyStateWithPersistentStore(std.testing.allocator, store, .fromInt(1)));
}

test "ready state persistent path repairs dangling dependency endpoint" {
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
    try store.appendNode(.{ .id = .fromInt(1), .kind = .task, .text = "ship" });
    try store.appendNode(.{ .id = .fromInt(2), .kind = .task, .text = "tests pass" });
    try store.setNodeStringProperty(std.testing.allocator, .fromInt(2), status_property, @tagName(Status.completed));
    try store.setUintProperty(std.testing.allocator, .{ .node = .fromInt(2) }, task_completed_ns_property, 1);
    try store.appendEdge(.{ .id = .fromInt(1), .src = .fromInt(1), .dst = .fromInt(2), .rel = .depends_on });

    const edge_index_header_len = storage.EdgeIndexHeader.encoded_len;
    const edge_index_record_len = 34;
    var bytes: [edge_index_header_len + edge_index_record_len]u8 = undefined;
    @memcpy(bytes[0..4], "TKGX");
    std.mem.writeInt(u16, bytes[4..6], 2, .little);
    std.mem.writeInt(u16, bytes[6..8], edge_index_header_len, .little);
    bytes[8] = @intFromEnum(storage.EdgeIndexOrder.src);
    @memset(bytes[9..16], 0);
    std.mem.writeInt(u64, bytes[16..24], 1, .little);
    std.mem.writeInt(u64, bytes[24..32], 0, .little);
    const record_offset = edge_index_header_len;
    std.mem.writeInt(u64, bytes[record_offset + 0 .. record_offset + 8], 1, .little);
    std.mem.writeInt(u64, bytes[record_offset + 8 .. record_offset + 16], 99, .little);
    std.mem.writeInt(u64, bytes[record_offset + 16 .. record_offset + 24], 1, .little);
    std.mem.writeInt(u16, bytes[record_offset + 24 .. record_offset + 26], @intFromEnum(core.RelKind.depends_on), .little);
    @memset(bytes[record_offset + 26 .. record_offset + 34], 0);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = store.edge_by_src_path,
        .data = &bytes,
        .flags = .{ .truncate = true },
    });

    try std.testing.expectEqual(ReadyState.ready, try readyStateWithPersistentStore(std.testing.allocator, store, .fromInt(1)));
}

test "ready state persistent path repairs corrupt edge index" {
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
    const task_id = try graph.addNode(.task, "ship");
    const blocker = try graph.addNode(.task, "blocked");
    const block_edge = try graph.addEdgeUnchecked(blocker, .blocks, task_id);
    try store.appendNode(graph.nodes.items[0]);
    try store.appendNode(graph.nodes.items[1]);
    try store.appendEdge(graph.edges.items[block_edge.toInt() - 1]);

    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = store.edge_by_dst_path,
        .data = "bad",
        .flags = .{ .truncate = true },
    });
    try std.testing.expectError(
        error.InvalidRecord,
        store.readEdgeIndexRecordsByNode(std.testing.allocator, .dst, task_id),
    );

    try std.testing.expectEqual(ReadyState.blocked, try readyStateWithPersistentStore(std.testing.allocator, store, task_id));
}

test "ready state persistent path rejects non-task nodes" {
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
    try store.appendNode(.{ .id = .fromInt(1), .kind = .file, .text = "src/main.zig" });

    try std.testing.expectError(core.Error.InvalidId, readyStateWithPersistentStore(std.testing.allocator, store, .fromInt(1)));
}

test "ready state persistent path rejects reserved task ids before missing-node checks" {
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

    try std.testing.expectError(core.Error.InvalidId, readyStateWithPersistentStore(std.testing.allocator, store, .none));
    try std.testing.expectError(core.Error.InvalidId, readyStateWithPersistentStore(std.testing.allocator, store, .fromInt(std.math.maxInt(u64))));
    try std.testing.expectError(core.Error.NotFound, readyStateWithPersistentStore(std.testing.allocator, store, .fromInt(99)));
}

test "open precedes predecessor gates readiness on memory path" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();

    const pred = try graph.addNode(.task, "design schema");
    const succ = try graph.addNode(.task, "implement schema");
    _ = try graph.addEdgeUnchecked(pred, .precedes, succ);

    var mem_index = try index.MemoryIndex.init(std.testing.allocator, &graph);
    defer mem_index.deinit();
    try std.testing.expectEqual(ReadyState.missing_dependencies, try readyStateWithIndex(&graph, &mem_index, succ));
    // 前驱本身无前驱 → ready(precedes 只看入边)。
    try std.testing.expectEqual(ReadyState.ready, try readyStateWithIndex(&graph, &mem_index, pred));
}

test "closed precedes predecessor releases readiness on memory path" {
    var graph = graph_mod.Graph.init(std.testing.allocator);
    defer graph.deinit();

    // In-memory Graph has no property sidecar; keep legacy closed-kind support
    // only for this compatibility API.
    const pred = try graph.addNode(.verification, "design schema (closed)");
    const succ = try graph.addNode(.task, "implement schema");
    _ = try graph.addEdgeUnchecked(pred, .precedes, succ);

    var mem_index = try index.MemoryIndex.init(std.testing.allocator, &graph);
    defer mem_index.deinit();
    try std.testing.expectEqual(ReadyState.ready, try readyStateWithIndex(&graph, &mem_index, succ));
}

test "persistent readiness preserves verification dependencies and high confidence legacy fix closure" {
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
        .{ .id = .fromInt(1), .kind = .task, .text = "depends on evidence" },
        .{ .id = .fromInt(2), .kind = .verification, .text = "ordinary verification evidence" },
        .{ .id = .fromInt(3), .kind = .task, .text = "depends on unclosed fix" },
        .{ .id = .fromInt(4), .kind = .fix, .text = "ordinary fix note" },
        .{ .id = .fromInt(5), .kind = .task, .text = "depends on legacy closed fix" },
        .{ .id = .fromInt(6), .kind = .fix, .text = "legacy rewritten task" },
    });
    try store.appendEdgesBatch(&.{
        .{ .id = .fromInt(1), .src = .fromInt(1), .dst = .fromInt(2), .rel = .depends_on },
        .{ .id = .fromInt(2), .src = .fromInt(3), .dst = .fromInt(4), .rel = .depends_on },
        .{ .id = .fromInt(3), .src = .fromInt(5), .dst = .fromInt(6), .rel = .depends_on },
    });
    _ = try store.upsertPropertiesBatch(std.testing.allocator, &.{
        .{ .owner = .{ .node = .fromInt(6) }, .key = "task_created_ns", .value = .{ .uint = 1 } },
        .{ .owner = .{ .node = .fromInt(6) }, .key = "task_completed_ns", .value = .{ .uint = 2 } },
    });

    try std.testing.expectEqual(ReadyState.ready, try readyStateWithPersistentStoreAt(std.testing.allocator, store, .fromInt(1), 3));
    try std.testing.expectEqual(ReadyState.missing_dependencies, try readyStateWithPersistentStoreAt(std.testing.allocator, store, .fromInt(3), 3));
    try std.testing.expectEqual(ReadyState.ready, try readyStateWithPersistentStoreAt(std.testing.allocator, store, .fromInt(5), 3));
}

test "precedes predecessor gates readiness on persistent path both sides" {
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

    const open_pred = core.NodeId.fromInt(1);
    const gated = core.NodeId.fromInt(2);
    const closed_pred = core.NodeId.fromInt(3);
    const released = core.NodeId.fromInt(4);
    try store.appendNode(.{ .id = open_pred, .kind = .task, .text = "design" });
    try store.appendNode(.{ .id = gated, .kind = .task, .text = "implement" });
    try store.appendNode(.{ .id = closed_pred, .kind = .verification, .text = "design done" });
    try store.appendNode(.{ .id = released, .kind = .task, .text = "ship" });
    try store.appendEdge(.{ .id = .fromInt(1), .src = open_pred, .dst = gated, .rel = .precedes });
    try store.appendEdge(.{ .id = .fromInt(2), .src = closed_pred, .dst = released, .rel = .precedes });

    try std.testing.expectEqual(ReadyState.missing_dependencies, try readyStateWithPersistentStore(std.testing.allocator, store, gated));
    try std.testing.expectEqual(ReadyState.ready, try readyStateWithPersistentStore(std.testing.allocator, store, released));
}
