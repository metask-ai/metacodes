const std = @import("std");

/// Physical relation identities used by the task hierarchy compatibility
/// reader. New task decomposition uses `canonical`; `legacy` remains readable
/// for task-to-task edges written before the schema split and, only through
/// the packet-history policy, old non-task child rounds.
pub const RelationFlavor = enum {
    canonical,
    legacy,
};

/// One bounded owner for task hierarchy reads.
///
/// The façade supplies concrete Store, edge-record, and node-kind access via
/// `Ops`. This controller owns relation priority, the shared scan budget,
/// task-peer filtering, and peer de-duplication without importing storage or
/// schema representations.
pub fn TaskHierarchy(comptime Ops: type) type {
    return struct {
        const Self = @This();

        const PeerPolicy = enum {
            tasks_only,
            packet_history,
        };

        pub const Collection = struct {
            records: std.ArrayList(Ops.EdgeRecord) = .empty,
            truncated: bool = false,

            pub fn deinit(self: *Collection, allocator: std.mem.Allocator) void {
                self.records.deinit(allocator);
                self.* = undefined;
            }
        };

        /// Read canonical edges first, then legacy edges, under one physical
        /// edge-visit budget. A peer that appears in both forms is represented
        /// by its canonical record. Non-task peers still consume scan budget,
        /// but never become task parents or children.
        pub fn collectLimited(
            allocator: std.mem.Allocator,
            context: *Ops.Context,
            order: Ops.Order,
            owner_id: Ops.NodeId,
            max_records: usize,
        ) !Collection {
            return collectWithPolicy(allocator, context, order, owner_id, max_records, .tasks_only);
        }

        /// Task packets historically exposed non-task `contains` children as
        /// recent work rounds. Preserve that retrieval surface without
        /// admitting those records into lifecycle hierarchy. Canonical
        /// `contain` records remain task-only, while canonical/legacy task
        /// peers retain the same canonical-first de-duplication as ordinary
        /// hierarchy reads.
        pub fn collectPacketHistoryLimited(
            allocator: std.mem.Allocator,
            context: *Ops.Context,
            order: Ops.Order,
            owner_id: Ops.NodeId,
            max_records: usize,
        ) !Collection {
            return collectWithPolicy(allocator, context, order, owner_id, max_records, .packet_history);
        }

        fn collectWithPolicy(
            allocator: std.mem.Allocator,
            context: *Ops.Context,
            order: Ops.Order,
            owner_id: Ops.NodeId,
            max_records: usize,
            peer_policy: PeerPolicy,
        ) !Collection {
            var result = Collection{};
            errdefer result.deinit(allocator);
            var seen_peers = std.AutoHashMap(u64, void).init(allocator);
            defer seen_peers.deinit();

            // One extra physical record is the truncation lookahead. Giving
            // each relation its own allowance would silently double the task
            // command's worst-case I/O after enabling compatibility reads.
            var remaining_edge_visits = max_records +| 1;
            inline for ([_]RelationFlavor{ .canonical, .legacy }) |relation| {
                if (remaining_edge_visits == 0) {
                    result.truncated = true;
                    return result;
                }
                var collected = try Ops.collectRelation(
                    allocator,
                    context,
                    order,
                    owner_id,
                    relation,
                    remaining_edge_visits,
                );
                defer collected.records.deinit(allocator);
                remaining_edge_visits -= collected.records.items.len;
                if (collected.truncated) result.truncated = true;

                for (collected.records.items) |record| {
                    const peer_id = try Ops.peerNodeId(order, record);
                    const is_task_peer = try Ops.isTaskPeer(context, peer_id);
                    if (!is_task_peer) {
                        if (peer_policy != .packet_history or relation != .legacy) continue;
                        if (result.records.items.len >= max_records) {
                            result.truncated = true;
                            return result;
                        }
                        try result.records.append(allocator, record);
                        continue;
                    }
                    const entry = try seen_peers.getOrPut(Ops.nodeIdValue(peer_id));
                    if (entry.found_existing) continue;
                    if (result.records.items.len >= max_records) {
                        result.truncated = true;
                        return result;
                    }
                    try result.records.append(allocator, record);
                }
                if (collected.truncated) return result;
            }
            return result;
        }

        /// Lifecycle and invariant checks must never accept a truncated task
        /// hierarchy as complete.
        pub fn readComplete(
            allocator: std.mem.Allocator,
            context: *Ops.Context,
            order: Ops.Order,
            owner_id: Ops.NodeId,
            max_records: usize,
        ) !std.ArrayList(Ops.EdgeRecord) {
            var collected = try Self.collectLimited(allocator, context, order, owner_id, max_records);
            if (collected.truncated) {
                collected.deinit(allocator);
                return error.BudgetExceeded;
            }
            return collected.records;
        }

        /// Packet history is still a complete bounded read: omitting an old
        /// child round under edge pressure would make recovery depend on
        /// storage layout rather than the declared packet limit.
        pub fn readPacketHistory(
            allocator: std.mem.Allocator,
            context: *Ops.Context,
            order: Ops.Order,
            owner_id: Ops.NodeId,
            max_records: usize,
        ) !std.ArrayList(Ops.EdgeRecord) {
            var collected = try Self.collectPacketHistoryLimited(allocator, context, order, owner_id, max_records);
            if (collected.truncated) {
                collected.deinit(allocator);
                return error.BudgetExceeded;
            }
            return collected.records;
        }
    };
}

const TestEdgeRecord = struct {
    edge_id: u64,
    peer_id: u64,
    relation: RelationFlavor,
};

const TestOps = struct {
    pub const EdgeRecord = TestEdgeRecord;
    pub const NodeId = u64;
    pub const Order = enum { src, dst, id };
    pub const Context = struct {
        canonical: []const EdgeRecord,
        legacy: []const EdgeRecord,
        legacy_limit: usize = std.math.maxInt(usize),
    };

    pub fn collectRelation(
        allocator: std.mem.Allocator,
        context: *Context,
        _: Order,
        _: NodeId,
        relation: RelationFlavor,
        max_records: usize,
    ) !struct { records: std.ArrayList(EdgeRecord), truncated: bool } {
        const source = switch (relation) {
            .canonical => context.canonical,
            .legacy => context.legacy,
        };
        if (relation == .legacy) context.legacy_limit = max_records;
        var records = std.ArrayList(EdgeRecord).empty;
        errdefer records.deinit(allocator);
        const emitted = @min(source.len, max_records);
        try records.appendSlice(allocator, source[0..emitted]);
        return .{ .records = records, .truncated = source.len > emitted };
    }

    pub fn peerNodeId(order: Order, record: EdgeRecord) !NodeId {
        if (order == .id) return error.Unsupported;
        return record.peer_id;
    }

    pub fn isTaskPeer(_: *Context, peer_id: NodeId) !bool {
        return peer_id < 100;
    }

    pub fn nodeIdValue(node_id: NodeId) u64 {
        return node_id;
    }
};

const test_hierarchy = TaskHierarchy(TestOps);

test "task hierarchy prefers canonical peers and excludes non-task membership" {
    const canonical = [_]TestEdgeRecord{
        .{ .edge_id = 1, .peer_id = 100, .relation = .canonical },
        .{ .edge_id = 2, .peer_id = 2, .relation = .canonical },
        .{ .edge_id = 3, .peer_id = 2, .relation = .canonical },
    };
    const legacy = [_]TestEdgeRecord{
        .{ .edge_id = 4, .peer_id = 2, .relation = .legacy },
        .{ .edge_id = 5, .peer_id = 3, .relation = .legacy },
    };
    var context = TestOps.Context{ .canonical = &canonical, .legacy = &legacy };
    var collected = try test_hierarchy.collectLimited(std.testing.allocator, &context, .src, 1, 8);
    defer collected.deinit(std.testing.allocator);

    try std.testing.expect(!collected.truncated);
    try std.testing.expectEqual(@as(usize, 2), collected.records.items.len);
    try std.testing.expectEqual(@as(u64, 2), collected.records.items[0].edge_id);
    try std.testing.expectEqual(RelationFlavor.canonical, collected.records.items[0].relation);
    try std.testing.expectEqual(@as(u64, 5), collected.records.items[1].edge_id);
    try std.testing.expectEqual(RelationFlavor.legacy, collected.records.items[1].relation);
}

test "task hierarchy shares one bounded scan budget across relation forms" {
    const canonical = [_]TestEdgeRecord{
        .{ .edge_id = 1, .peer_id = 100, .relation = .canonical },
        .{ .edge_id = 2, .peer_id = 2, .relation = .canonical },
    };
    const legacy = [_]TestEdgeRecord{
        .{ .edge_id = 3, .peer_id = 3, .relation = .legacy },
        .{ .edge_id = 4, .peer_id = 4, .relation = .legacy },
    };
    var context = TestOps.Context{ .canonical = &canonical, .legacy = &legacy };
    var collected = try test_hierarchy.collectLimited(std.testing.allocator, &context, .dst, 1, 2);
    defer collected.deinit(std.testing.allocator);

    try std.testing.expect(collected.truncated);
    try std.testing.expectEqual(@as(usize, 1), context.legacy_limit);
    try std.testing.expectEqual(@as(usize, 2), collected.records.items.len);
    try std.testing.expectEqual(@as(u64, 2), collected.records.items[0].edge_id);
    try std.testing.expectEqual(@as(u64, 3), collected.records.items[1].edge_id);
}

test "task hierarchy complete reads fail closed on bounded samples" {
    const canonical = [_]TestEdgeRecord{
        .{ .edge_id = 1, .peer_id = 1, .relation = .canonical },
        .{ .edge_id = 2, .peer_id = 2, .relation = .canonical },
    };
    var context = TestOps.Context{ .canonical = &canonical, .legacy = &.{} };
    try std.testing.expectError(
        error.BudgetExceeded,
        test_hierarchy.readComplete(std.testing.allocator, &context, .src, 1, 1),
    );
}

test "task packet history preserves legacy non-task rounds without widening hierarchy" {
    const canonical = [_]TestEdgeRecord{
        .{ .edge_id = 1, .peer_id = 100, .relation = .canonical },
        .{ .edge_id = 2, .peer_id = 2, .relation = .canonical },
    };
    const legacy = [_]TestEdgeRecord{
        .{ .edge_id = 3, .peer_id = 2, .relation = .legacy },
        .{ .edge_id = 4, .peer_id = 101, .relation = .legacy },
    };
    var context = TestOps.Context{ .canonical = &canonical, .legacy = &legacy };
    var hierarchy = try test_hierarchy.collectLimited(std.testing.allocator, &context, .src, 1, 8);
    defer hierarchy.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), hierarchy.records.items.len);
    try std.testing.expectEqual(@as(u64, 2), hierarchy.records.items[0].edge_id);

    var history = try test_hierarchy.collectPacketHistoryLimited(std.testing.allocator, &context, .src, 1, 8);
    defer history.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), history.records.items.len);
    try std.testing.expectEqual(@as(u64, 2), history.records.items[0].edge_id);
    try std.testing.expectEqual(@as(u64, 4), history.records.items[1].edge_id);
}
