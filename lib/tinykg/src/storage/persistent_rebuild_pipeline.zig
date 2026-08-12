const std = @import("std");

const repair_dense_edge_digest_max_id: u64 = 64 * 1024 * 1024;

/// Replay-only identity and digest state shared by full event counting and the
/// persistent rebuild backend. It deliberately owns no Store, file, format, or
/// publication representation.
pub const ReplayState = struct {
    pub const dense_edge_digest_max_id = repair_dense_edge_digest_max_id;

    pub const IdBitSet = struct {
        bits: std.ArrayList(u8) = .empty,

        pub fn deinit(self: *IdBitSet, allocator: std.mem.Allocator) void {
            self.bits.deinit(allocator);
        }

        pub fn put(self: *IdBitSet, allocator: std.mem.Allocator, id: u64) !bool {
            const bit = try bitIndex(id);
            const byte_index = std.math.cast(usize, bit / 8) orelse return error.RecordTooLarge;
            if (byte_index >= self.bits.items.len) {
                const old_len = self.bits.items.len;
                const min_len = byte_index + 1;
                const doubled = std.math.mul(usize, @max(old_len, 4096), 2) catch return error.RecordTooLarge;
                const next_len = @max(min_len, doubled);
                try self.bits.resize(allocator, next_len);
                @memset(self.bits.items[old_len..], 0);
            }
            const mask = @as(u8, 1) << @intCast(bit % 8);
            const occupied = (self.bits.items[byte_index] & mask) != 0;
            self.bits.items[byte_index] |= mask;
            return occupied;
        }

        pub fn contains(self: IdBitSet, id: u64) !bool {
            const bit = try bitIndex(id);
            const byte_index = std.math.cast(usize, bit / 8) orelse return error.RecordTooLarge;
            if (byte_index >= self.bits.items.len) return false;
            const mask = @as(u8, 1) << @intCast(bit % 8);
            return (self.bits.items[byte_index] & mask) != 0;
        }

        fn bitIndex(id: u64) !u64 {
            if (id == 0 or id == std.math.maxInt(u64)) return error.InvalidRecord;
            return id - 1;
        }
    };

    pub const EdgeDigestIndex = struct {
        digests: std.ArrayList(u64) = .empty,
        seen_dense: IdBitSet = .{},
        deleted_dense: IdBitSet = .{},
        overflow: std.AutoHashMap(u64, u64),
        overflow_deleted: std.AutoHashMap(u64, void),

        pub fn init(allocator: std.mem.Allocator) EdgeDigestIndex {
            return .{
                .overflow = std.AutoHashMap(u64, u64).init(allocator),
                .overflow_deleted = std.AutoHashMap(u64, void).init(allocator),
            };
        }

        pub fn deinit(self: *EdgeDigestIndex, allocator: std.mem.Allocator) void {
            self.overflow_deleted.deinit();
            self.overflow.deinit();
            self.deleted_dense.deinit(allocator);
            self.seen_dense.deinit(allocator);
            self.digests.deinit(allocator);
        }

        pub fn put(
            self: *EdgeDigestIndex,
            allocator: std.mem.Allocator,
            edge_id: u64,
            digest: u64,
            record_count_so_far: usize,
        ) !bool {
            if (edge_id == 0 or edge_id == std.math.maxInt(u64)) return error.InvalidRecord;
            const dense_limit = try denseLimitForRecordCount(record_count_so_far);
            if (edge_id <= dense_limit) {
                if (self.overflow.contains(edge_id)) return true;
                const occupied = try self.seen_dense.put(allocator, edge_id);
                if (occupied) return true;
                const index = std.math.cast(usize, edge_id - 1) orelse return error.RecordTooLarge;
                if (index >= self.digests.items.len) {
                    const old_len = self.digests.items.len;
                    const min_len = index + 1;
                    const doubled = std.math.mul(usize, @max(old_len, 4096), 2) catch return error.RecordTooLarge;
                    const next_len = @max(min_len, doubled);
                    try self.digests.resize(allocator, next_len);
                }
                self.digests.items[index] = digest;
                return false;
            }

            const entry = try self.overflow.getOrPut(edge_id);
            if (entry.found_existing) return true;
            entry.value_ptr.* = digest;
            return false;
        }

        pub fn delete(self: *EdgeDigestIndex, allocator: std.mem.Allocator, edge_id: u64) !?u64 {
            if (edge_id == 0 or edge_id == std.math.maxInt(u64)) return error.InvalidRecord;
            if (edge_id <= repair_dense_edge_digest_max_id) {
                if (try self.seen_dense.contains(edge_id)) {
                    if (try self.deleted_dense.put(allocator, edge_id)) return error.InvalidRecord;
                    const index = std.math.cast(usize, edge_id - 1) orelse return error.RecordTooLarge;
                    if (index >= self.digests.items.len) return error.InvalidRecord;
                    return self.digests.items[index];
                }
            }

            const digest = self.overflow.get(edge_id) orelse return null;
            const deleted = try self.overflow_deleted.getOrPut(edge_id);
            if (deleted.found_existing) return error.InvalidRecord;
            return digest;
        }

        fn denseLimitForRecordCount(record_count_so_far: usize) !u64 {
            const count = std.math.add(u64, @intCast(record_count_so_far), 1) catch return error.RecordTooLarge;
            const expanded = std.math.mul(u64, count, 2) catch return error.RecordTooLarge;
            return @min(repair_dense_edge_digest_max_id, @max(@as(u64, 4096), expanded));
        }
    };

    pub fn DirectNodeLayout(comptime NodeKind: type) type {
        return struct {
            const Self = @This();

            lengths: std.ArrayList(u16) = .empty,
            possible: bool = true,
            expected_id: u64 = 1,
            expected_text_offset: u64 = 0,
            kind: ?NodeKind = null,

            pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
                self.lengths.deinit(allocator);
            }

            pub fn observe(
                self: *Self,
                allocator: std.mem.Allocator,
                id: u64,
                kind: NodeKind,
                text_offset: u64,
                text_len: u32,
            ) !void {
                if (!self.possible) return;
                const short_len = std.math.cast(u16, text_len) orelse {
                    self.possible = false;
                    return;
                };
                if (id != self.expected_id or text_offset != self.expected_text_offset) {
                    self.possible = false;
                    return;
                }
                if (self.kind) |prior| {
                    if (prior != kind) {
                        self.possible = false;
                        return;
                    }
                } else {
                    self.kind = kind;
                }
                try self.lengths.append(allocator, short_len);
                self.expected_id = std.math.add(u64, self.expected_id, 1) catch return error.InvalidRecord;
                self.expected_text_offset = std.math.add(u64, self.expected_text_offset, text_len) catch return error.InvalidRecord;
            }

            pub fn canRewrite(
                self: Self,
                kind: NodeKind,
                node_count: u64,
                max_node_id: u64,
                node_texts_logical_size: u64,
            ) bool {
                return self.possible and
                    self.kind == kind and
                    node_count == max_node_id and
                    self.lengths.items.len == node_count and
                    self.expected_text_offset == node_texts_logical_size;
            }
        };
    }
};

/// Owns one persistent rebuild attempt after repair-session admission: replay
/// workspace lifetime, fail-stop phase ordering, and publication with metadata
/// last. Store-specific formats, mmap views, external sorting, and filesystem
/// primitives remain behind the phase-shaped backend.
pub fn PersistentRebuildPipeline(comptime Ops: type) type {
    return struct {
        const Workspace = Ops.WorkspaceType;
        const NodeKind = Ops.NodeKindType;

        pub const DirectNodeLayout = ReplayState.DirectNodeLayout(NodeKind);

        pub fn rebuild(context: anytype, reuse_node_texts: bool, timings: anytype) !void {
            var workspace: Workspace = try Ops.prepareWorkspace(context, reuse_node_texts);
            defer Ops.deinitWorkspace(context, &workspace);

            try Ops.replayAndFinalizeArtifacts(context, &workspace, reuse_node_texts, timings);
            try Ops.publishPrimary(context, &workspace, timings);
            try Ops.finalizePrimaryText(context, timings);
            try Ops.publishNodeText(context, &workspace, timings);
            try Ops.publishEdges(context, &workspace, timings);
            try Ops.publishTombstones(context, &workspace, timings);
            try Ops.publishMetadataAndDerived(context, &workspace, timings);
        }
    };
}

const TestNodeKind = enum { task, observation };

const TestPhase = enum {
    prepare,
    replay_and_flush,
    publish_primary,
    finalize_primary_text,
    publish_node_text,
    publish_edges,
    publish_tombstones,
    publish_metadata,
    cleanup,
};

const TestWorkspace = struct { marker: u8 = 1 };

const TestContext = struct {
    phases: [16]TestPhase = undefined,
    phase_count: usize = 0,
    fail_at: ?TestPhase = null,

    fn record(self: *TestContext, phase: TestPhase) !void {
        self.phases[self.phase_count] = phase;
        self.phase_count += 1;
        if (self.fail_at == phase) return error.InjectedFailure;
    }

    fn cleanup(self: *TestContext) void {
        self.phases[self.phase_count] = .cleanup;
        self.phase_count += 1;
    }

    fn recorded(self: *const TestContext) []const TestPhase {
        return self.phases[0..self.phase_count];
    }
};

const TestOps = struct {
    pub const WorkspaceType = TestWorkspace;
    pub const NodeKindType = TestNodeKind;

    pub fn prepareWorkspace(context: *TestContext, _: bool) !TestWorkspace {
        try context.record(.prepare);
        return .{};
    }

    pub fn deinitWorkspace(context: *TestContext, workspace: *TestWorkspace) void {
        std.debug.assert(workspace.marker == 1);
        context.cleanup();
    }

    pub fn replayAndFinalizeArtifacts(context: *TestContext, _: *TestWorkspace, _: bool, _: anytype) !void {
        try context.record(.replay_and_flush);
    }

    pub fn publishPrimary(context: *TestContext, _: *TestWorkspace, _: anytype) !void {
        try context.record(.publish_primary);
    }

    pub fn finalizePrimaryText(context: *TestContext, _: anytype) !void {
        try context.record(.finalize_primary_text);
    }

    pub fn publishNodeText(context: *TestContext, _: *TestWorkspace, _: anytype) !void {
        try context.record(.publish_node_text);
    }

    pub fn publishEdges(context: *TestContext, _: *TestWorkspace, _: anytype) !void {
        try context.record(.publish_edges);
    }

    pub fn publishTombstones(context: *TestContext, _: *TestWorkspace, _: anytype) !void {
        try context.record(.publish_tombstones);
    }

    pub fn publishMetadataAndDerived(context: *TestContext, _: *TestWorkspace, _: anytype) !void {
        try context.record(.publish_metadata);
    }
};

const test_pipeline = PersistentRebuildPipeline(TestOps);

test "persistent rebuild pipeline sequences replay flush and publication" {
    var context = TestContext{};
    try test_pipeline.rebuild(&context, true, @as(?*u8, null));
    try std.testing.expectEqualSlices(TestPhase, &.{
        .prepare,
        .replay_and_flush,
        .publish_primary,
        .finalize_primary_text,
        .publish_node_text,
        .publish_edges,
        .publish_tombstones,
        .publish_metadata,
        .cleanup,
    }, context.recorded());
}

test "persistent rebuild pipeline deinitializes workspace after replay failure" {
    var context = TestContext{ .fail_at = .replay_and_flush };
    try std.testing.expectError(error.InjectedFailure, test_pipeline.rebuild(&context, true, @as(?*u8, null)));
    try std.testing.expectEqualSlices(TestPhase, &.{ .prepare, .replay_and_flush, .cleanup }, context.recorded());
}

test "persistent rebuild pipeline stops after primary publication failure" {
    var context = TestContext{ .fail_at = .publish_primary };
    try std.testing.expectError(error.InjectedFailure, test_pipeline.rebuild(&context, true, @as(?*u8, null)));
    try std.testing.expectEqualSlices(TestPhase, &.{ .prepare, .replay_and_flush, .publish_primary, .cleanup }, context.recorded());
}

test "persistent rebuild pipeline stops after node text publication failure" {
    var context = TestContext{ .fail_at = .publish_node_text };
    try std.testing.expectError(error.InjectedFailure, test_pipeline.rebuild(&context, true, @as(?*u8, null)));
    try std.testing.expectEqualSlices(TestPhase, &.{
        .prepare,
        .replay_and_flush,
        .publish_primary,
        .finalize_primary_text,
        .publish_node_text,
        .cleanup,
    }, context.recorded());
}

test "persistent rebuild pipeline stops before metadata after edge failure" {
    var context = TestContext{ .fail_at = .publish_edges };
    try std.testing.expectError(error.InjectedFailure, test_pipeline.rebuild(&context, true, @as(?*u8, null)));
    try std.testing.expectEqualSlices(TestPhase, &.{
        .prepare,
        .replay_and_flush,
        .publish_primary,
        .finalize_primary_text,
        .publish_node_text,
        .publish_edges,
        .cleanup,
    }, context.recorded());
}

test "persistent rebuild pipeline publishes metadata last" {
    var context = TestContext{};
    try test_pipeline.rebuild(&context, false, @as(?*u8, null));
    const phases = context.recorded();
    try std.testing.expectEqual(TestPhase.publish_metadata, phases[phases.len - 2]);
    try std.testing.expectEqual(TestPhase.cleanup, phases[phases.len - 1]);
}

test "persistent rebuild id set rejects invalid ids and detects duplicates" {
    var ids = ReplayState.IdBitSet{};
    defer ids.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidRecord, ids.put(std.testing.allocator, 0));
    try std.testing.expect(!try ids.put(std.testing.allocator, 1));
    try std.testing.expect(!try ids.put(std.testing.allocator, 100_000));
    try std.testing.expect(try ids.put(std.testing.allocator, 1));
    try std.testing.expect(try ids.contains(100_000));
}

test "persistent rebuild digest index preserves sparse fallback duplicate" {
    var index = ReplayState.EdgeDigestIndex.init(std.testing.allocator);
    defer index.deinit(std.testing.allocator);
    const sparse_under_cap: u64 = 100_000;
    try std.testing.expect(!try index.put(std.testing.allocator, sparse_under_cap, 0x1234, 0));
    try std.testing.expect(try index.put(std.testing.allocator, sparse_under_cap, 0x5678, 100_000));
    try std.testing.expectEqual(@as(?u64, 0x1234), try index.delete(std.testing.allocator, sparse_under_cap));
    try std.testing.expectError(error.InvalidRecord, index.delete(std.testing.allocator, sparse_under_cap));
}

test "persistent rebuild direct node layout accepts one dense uniform stream" {
    var layout = test_pipeline.DirectNodeLayout{};
    defer layout.deinit(std.testing.allocator);
    try layout.observe(std.testing.allocator, 1, .task, 0, 3);
    try layout.observe(std.testing.allocator, 2, .task, 3, 5);
    try std.testing.expect(layout.canRewrite(.task, 2, 2, 8));
    try std.testing.expectEqualSlices(u16, &.{ 3, 5 }, layout.lengths.items);
}

test "persistent rebuild direct node layout rejects gaps kinds and offsets" {
    var gap = test_pipeline.DirectNodeLayout{};
    defer gap.deinit(std.testing.allocator);
    try gap.observe(std.testing.allocator, 2, .task, 0, 3);
    try std.testing.expect(!gap.canRewrite(.task, 1, 2, 3));

    var kind = test_pipeline.DirectNodeLayout{};
    defer kind.deinit(std.testing.allocator);
    try kind.observe(std.testing.allocator, 1, .task, 0, 3);
    try kind.observe(std.testing.allocator, 2, .observation, 3, 2);
    try std.testing.expect(!kind.canRewrite(.task, 2, 2, 5));

    var offset = test_pipeline.DirectNodeLayout{};
    defer offset.deinit(std.testing.allocator);
    try offset.observe(std.testing.allocator, 1, .task, 1, 3);
    try std.testing.expect(!offset.canRewrite(.task, 1, 1, 4));
}
