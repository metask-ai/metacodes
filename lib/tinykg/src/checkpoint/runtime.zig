const std = @import("std");
const core = @import("../core.zig");
const graph_mod = @import("../graph.zig");
const index_mod = @import("../index.zig");
const query_mod = @import("../query.zig");
const text_mod = @import("../text.zig");
const repository_mod = @import("repository.zig");
const checkpoint_mutation = @import("mutation.zig");
const checkpoint_delta = @import("delta.zig");
const checkpoint_store = @import("store.zig");
const wal_mod = @import("wal.zig");

pub const LogicalBreakdown = struct {
    content_bytes: u64,
    node_text_bytes: u64,
    property_value_bytes: u64,
    edge_bytes: u64,
    property_count: u64,
};

pub const PublicationReceipt = struct {
    old_operational_bytes: u64,
    replacement_wal_bytes: u64,
    peak_operational_bytes: u64,
    committed_operational_bytes: u64,
    peak_logical_content_bytes: u64,
};

/// Daemon-resident canonical checkpoint state and rebuildable query indexes.
/// The decoded snapshot is the single owner of node strings and metadata:
/// Graph and MemoryIndex borrow that text, and TextIndex is compacted into
/// exact-size derived arrays, so resident memory holds one copy of canonical
/// strings plus derived index structures only.
pub const Runtime = struct {
    allocator: std.mem.Allocator,
    repository: repository_mod.Repository,
    current: repository_mod.Current,
    loaded: repository_mod.Loaded,
    wal: wal_mod.Wal,
    query_view: query_mod.CheckpointView,
    graph: graph_mod.Graph,
    graph_index: index_mod.MemoryIndex,
    text_index: text_mod.TextIndex,
    /// Startup repair receipt. Non-zero values mean the previous process
    /// crossed a durable publication point but did not finish post-commit GC.
    /// The receipt keeps that recovery visible to daemon/control-plane
    /// callers instead of silently hiding a crash-window cleanup.
    startup_collection: repository_mod.Collection,
    startup_wal_truncated_bytes: u64,
    footprint: repository_mod.Footprint,
    logical_breakdown: LogicalBreakdown,
    last_publication: ?PublicationReceipt,

    pub fn open(
        allocator: std.mem.Allocator,
        io: std.Io,
        directory: []const u8,
        durable: bool,
    ) !Runtime {
        var repository = try repository_mod.Repository.init(allocator, io, directory, durable);
        errdefer repository.deinit();
        const current = (try repository.readCurrent()) orelse return error.FileNotFound;
        var wal = try wal_mod.Wal.openGeneration(allocator, io, directory, current.generation, durable);
        errdefer wal.deinit();
        const startup_wal_truncated_bytes = try wal.recoverCrashTail();
        var loaded = (try repository.loadCurrent()).?;
        errdefer loaded.deinit(allocator);

        const query_view = try query_mod.CheckpointView.init(
            loaded.checkpoint.snapshot.properties,
            loaded.checkpoint.snapshot.edge_orders,
        );

        var graph = try graphFromSnapshot(allocator, loaded.checkpoint.snapshot);
        errdefer graph.deinit();
        // Resident indexes are built directly into frozen exact-size arrays;
        // construction scratch is bounded and freed, so neither open nor
        // rebuild leaves per-node or per-term allocator retention behind.
        var graph_index = try index_mod.MemoryIndex.initCompactFromGraph(allocator, &graph);
        errdefer graph_index.deinit();
        var text_index = try text_mod.TextIndex.buildCompactFromGraph(allocator, &graph);
        errdefer text_index.deinit();

        // CURRENT, its checkpoint, the recovered WAL and every resident query
        // index are valid at this point. Only now may obsolete generations and
        // publication temporaries be removed. This closes the crash window
        // after CURRENT rename but before the normal post-commit GC without
        // risking deletion when the selected generation is corrupt.
        const startup_collection = try repository.collectObsoleteAfterVerifiedCurrent(current);
        const logical_breakdown = try measureLogicalBreakdown(loaded.checkpoint.snapshot);
        const footprint = try repository.measureFootprintAfterVerifiedCurrent(current, logical_breakdown.content_bytes);
        return .{
            .allocator = allocator,
            .repository = repository,
            .current = current,
            .loaded = loaded,
            .wal = wal,
            .query_view = query_view,
            .graph = graph,
            .graph_index = graph_index,
            .text_index = text_index,
            .startup_collection = startup_collection,
            .startup_wal_truncated_bytes = startup_wal_truncated_bytes,
            .footprint = footprint,
            .logical_breakdown = logical_breakdown,
            .last_publication = null,
        };
    }

    pub fn deinit(self: *Runtime) void {
        self.text_index.deinit();
        self.graph_index.deinit();
        self.graph.deinit();
        self.wal.deinit();
        self.loaded.deinit(self.allocator);
        self.repository.deinit();
        self.* = undefined;
    }

    pub fn generation(self: Runtime) u64 {
        return self.loaded.generation;
    }

    pub fn snapshot(self: *const Runtime) *const repository_mod.Loaded {
        return &self.loaded;
    }

    pub fn startupRecovery(self: *const Runtime) repository_mod.Collection {
        return self.startup_collection;
    }

    pub fn startupWalTruncatedBytes(self: *const Runtime) u64 {
        return self.startup_wal_truncated_bytes;
    }

    pub fn cachedFootprint(self: *const Runtime) repository_mod.Footprint {
        return self.footprint;
    }

    pub fn cachedLogicalBreakdown(self: *const Runtime) LogicalBreakdown {
        return self.logical_breakdown;
    }

    pub fn lastPublication(self: *const Runtime) ?PublicationReceipt {
        return self.last_publication;
    }

    pub fn refreshFootprint(self: *Runtime) !repository_mod.Footprint {
        self.footprint = try self.repository.measureFootprintAfterVerifiedCurrent(
            self.current,
            self.logical_breakdown.content_bytes,
        );
        return self.footprint;
    }

    pub fn execute(
        self: *Runtime,
        io: std.Io,
        plan: @import("../ql/optimizer.zig").PhysicalPlan,
        budget: core.QueryBudget,
    ) !@import("../ql/executor.zig").ResultTable {
        return @import("../ql/executor.zig").executeWithResidentIndexesAndIo(
            self.allocator,
            io,
            &self.graph,
            &self.graph_index,
            &self.text_index,
            self.query_view,
            plan,
            budget,
        );
    }

    pub fn executeExplain(
        self: *Runtime,
        io: std.Io,
        plan: @import("../ql/optimizer.zig").PhysicalPlan,
        budget: core.QueryBudget,
        timings: *@import("../ql/executor.zig").OperatorTimingRecorder,
    ) !@import("../ql/executor.zig").ResultTable {
        return @import("../ql/executor.zig").executeWithResidentIndexesAndIoExplain(
            self.allocator,
            io,
            &self.graph,
            &self.graph_index,
            &self.text_index,
            self.query_view,
            plan,
            budget,
            timings,
        );
    }

    pub const CommitMode = enum {
        wal,
        wal_compacted,
    };

    /// Apply one canonical transaction to the resident generation. Candidate
    /// state and all derived RAM indexes are built before the durability point.
    /// A transaction that cannot append is collapsed against the immutable
    /// checkpoint into one minimal semantic WAL frame. The old WAL and staged
    /// replacement are both charged during admission, so no publication phase
    /// may cross the global ratio. A transaction whose compact delta still
    /// cannot fit fails closed; Runtime never copies the whole checkpoint.
    pub fn applyMutation(
        self: *Runtime,
        operations: []const checkpoint_mutation.Operation,
    ) !CommitMode {
        var prepared = try checkpoint_mutation.prepareAlloc(
            self.allocator,
            self.loaded.checkpoint.snapshot,
            operations,
        );
        defer prepared.deinit(self.allocator);
        var candidate = try CandidateState.init(self.allocator, &prepared.after);
        defer candidate.deinit();
        const after_logical = try measureLogicalBreakdown(prepared.after);

        _ = try self.repository.collectObsoleteAfterVerifiedCurrent(self.current);
        const footprint = try self.repository.measureFootprintAfterVerifiedCurrent(
            self.current,
            self.logical_breakdown.content_bytes,
        );
        const after_logical_bytes = after_logical.content_bytes;
        var encoded_append = try wal_mod.encodePayloadAlloc(self.allocator, prepared.bytes);
        defer encoded_append.deinit();
        const framed_bytes = try encoded_append.framedBytes();
        const append_total = std.math.add(u64, footprint.total_operational_bytes, framed_bytes) catch return error.RecordTooLarge;
        const append_fits = blk: {
            self.wal.preflightEncoded(encoded_append) catch |err| switch (err) {
                error.CheckpointRequired => break :blk false,
                else => |other| return other,
            };
            break :blk true;
        };
        if (append_fits and underTwentyPercent(append_total, after_logical_bytes)) {
            var next_replay = try replayAfterAppend(
                self.allocator,
                self.loaded.wal,
                prepared.bytes,
                framed_bytes,
            );
            errdefer next_replay.deinit();
            var next_footprint = footprint;
            next_footprint.logical_content_bytes = after_logical_bytes;
            next_footprint.current_wal_bytes = std.math.add(
                u64,
                next_footprint.current_wal_bytes,
                framed_bytes,
            ) catch return error.RecordTooLarge;
            next_footprint.total_operational_bytes = append_total;
            const sequence = try self.wal.appendEncoded(.mutation, encoded_append);
            if (sequence != next_replay.records.len) return error.InvalidRecord;
            self.loaded.wal.deinit();
            self.loaded.wal = next_replay;
            self.installPrepared(&prepared, &candidate, null);
            self.footprint = next_footprint;
            self.logical_breakdown = after_logical;
            self.last_publication = null;
            return .wal;
        }

        var base = try self.repository.loadCheckpointBase(self.current);
        defer base.snapshot.deinitOwned(self.allocator);
        const delta_operations = try checkpoint_delta.operationsAlloc(
            self.allocator,
            base.snapshot,
            prepared.after,
        );
        defer self.allocator.free(delta_operations);

        var compact_payload: ?[]u8 = null;
        defer if (compact_payload) |bytes| self.allocator.free(bytes);
        if (delta_operations.len != 0) {
            var compact = try checkpoint_mutation.prepareAlloc(
                self.allocator,
                base.snapshot,
                delta_operations,
            );
            defer compact.deinit(self.allocator);
            const expected_digest = try checkpoint_store.canonicalDigestAlloc(self.allocator, prepared.after);
            const compact_digest = try checkpoint_store.canonicalDigestAlloc(self.allocator, compact.after);
            if (!std.mem.eql(u8, &expected_digest, &compact_digest)) return error.SemanticMismatch;
            compact_payload = try self.allocator.dupe(u8, compact.bytes);
        } else {
            const base_digest = try checkpoint_store.canonicalDigestAlloc(self.allocator, base.snapshot);
            const expected_digest = try checkpoint_store.canonicalDigestAlloc(self.allocator, prepared.after);
            if (!std.mem.eql(u8, &base_digest, &expected_digest)) return error.SemanticMismatch;
        }

        var encoded_compact: ?wal_mod.EncodedPayload = if (compact_payload) |bytes|
            try wal_mod.encodePayloadAlloc(self.allocator, bytes)
        else
            null;
        defer if (encoded_compact) |*value| value.deinit();
        const replacement_bytes = try wal_mod.Wal.replacementBytes(if (encoded_compact) |value| value.bytes.len else null);
        // The replacement is first a regular .tmp file while the complete old
        // WAL remains durable. This is the actual publication peak, not the
        // smaller post-rename steady state.
        const publication_peak = std.math.add(
            u64,
            footprint.total_operational_bytes,
            replacement_bytes,
        ) catch return error.RecordTooLarge;
        // Until rename, readers still observe the old WAL. Do not enlarge the
        // denominator early when a transaction adds logical content.
        const publication_logical_bytes = @min(
            self.logical_breakdown.content_bytes,
            after_logical_bytes,
        );
        if (!underTwentyPercent(publication_peak, publication_logical_bytes)) {
            return error.PublicationPeakCompressionTargetMissed;
        }
        const committed_total = std.math.sub(
            u64,
            footprint.total_operational_bytes,
            footprint.current_wal_bytes,
        ) catch return error.InvalidRecord;
        const committed_with_wal = std.math.add(u64, committed_total, replacement_bytes) catch return error.RecordTooLarge;
        if (!underTwentyPercent(committed_with_wal, after_logical_bytes)) return error.CompressionTargetMissed;

        // Build every owned in-memory byte before the durability point. After
        // commit, installing state is allocation-free and cannot turn a
        // successful disk mutation into an ordinary allocation error.
        var next_replay = try replacementReplay(
            self.allocator,
            self.generation(),
            if (compact_payload) |bytes| bytes else null,
            replacement_bytes,
        );
        errdefer next_replay.deinit();
        var staged = try self.wal.stageReplacementEncoded(if (encoded_compact) |value| value else null);
        defer staged.deinit();
        if (staged.replacement_bytes != replacement_bytes) return error.InvalidRecord;
        const measured_peak = try self.repository.measureFootprintAfterVerifiedCurrent(
            self.current,
            publication_logical_bytes,
        );
        if (measured_peak.total_operational_bytes != publication_peak or
            !measured_peak.underTwentyPercent())
        {
            return error.PublicationPeakCompressionTargetMissed;
        }
        try staged.commit();
        try staged.verifyCommitted();
        self.loaded.wal.deinit();
        self.loaded.wal = next_replay;
        self.installPrepared(&prepared, &candidate, null);
        // Keep the rollback file until the new WAL and CURRENT-bound base have
        // both been admitted. Cleanup failure is safe: the retained rollback
        // remains charged and the already-measured peak is still <20%.
        _ = self.repository.collectObsoleteAfterVerifiedCurrent(self.current) catch {};
        const committed_footprint = self.repository.measureFootprintAfterVerifiedCurrent(
            self.current,
            after_logical_bytes,
        ) catch blk: {
            var conservative = footprint;
            conservative.logical_content_bytes = after_logical_bytes;
            conservative.current_wal_bytes = replacement_bytes;
            conservative.temporary_bytes = std.math.add(
                u64,
                conservative.temporary_bytes,
                footprint.current_wal_bytes,
            ) catch return error.RecordTooLarge;
            conservative.total_operational_bytes = publication_peak;
            break :blk conservative;
        };
        if (!committed_footprint.underTwentyPercent()) return error.PostCommitCompressionTargetMissed;
        self.footprint = committed_footprint;
        self.logical_breakdown = after_logical;
        self.last_publication = .{
            .old_operational_bytes = footprint.total_operational_bytes,
            .replacement_wal_bytes = replacement_bytes,
            .peak_operational_bytes = measured_peak.total_operational_bytes,
            .committed_operational_bytes = committed_footprint.total_operational_bytes,
            .peak_logical_content_bytes = publication_logical_bytes,
        };
        return .wal_compacted;
    }

    fn installPrepared(
        self: *Runtime,
        prepared: *checkpoint_mutation.Prepared,
        candidate: *CandidateState,
        header: ?checkpoint_store.Header,
    ) void {
        self.text_index.deinit();
        self.graph_index.deinit();
        self.graph.deinit();
        self.loaded.checkpoint.snapshot.deinitOwned(self.allocator);
        self.loaded.checkpoint.snapshot = prepared.after;
        prepared.after = .{ .nodes = &.{}, .edges = &.{}, .properties = &.{} };
        if (header) |value| self.loaded.checkpoint.header = value;
        self.query_view = candidate.query_view;
        self.graph = candidate.graph;
        self.graph_index = candidate.graph_index;
        self.text_index = candidate.text_index;
        candidate.moved = true;
    }
};

const CandidateState = struct {
    graph: graph_mod.Graph,
    graph_index: index_mod.MemoryIndex,
    text_index: text_mod.TextIndex,
    query_view: query_mod.CheckpointView,
    moved: bool = false,

    fn init(allocator: std.mem.Allocator, snapshot: *const @import("format.zig").Snapshot) !CandidateState {
        const query_view = try query_mod.CheckpointView.init(snapshot.properties, snapshot.edge_orders);
        var graph = try graphFromSnapshot(allocator, snapshot.*);
        errdefer graph.deinit();
        // Same discipline as Runtime.open: candidate indexes are frozen
        // exact-size builds, so mutations leave no per-round retention.
        var graph_index = try index_mod.MemoryIndex.initCompactFromGraph(allocator, &graph);
        errdefer graph_index.deinit();
        var text_index = try text_mod.TextIndex.buildCompactFromGraph(allocator, &graph);
        errdefer text_index.deinit();
        return .{ .graph = graph, .graph_index = graph_index, .text_index = text_index, .query_view = query_view };
    }

    fn deinit(self: *CandidateState) void {
        if (self.moved) return;
        self.text_index.deinit();
        self.graph_index.deinit();
        self.graph.deinit();
    }
};

fn underTwentyPercent(physical_bytes: u64, logical_bytes: u64) bool {
    if (logical_bytes == 0 or physical_bytes > std.math.maxInt(u64) / 5) return false;
    return physical_bytes * 5 < logical_bytes;
}

fn measureLogicalBreakdown(snapshot: @import("format.zig").Snapshot) !LogicalBreakdown {
    const format = @import("format.zig");
    var node_text_bytes: u64 = 0;
    for (snapshot.nodes) |node| {
        node_text_bytes = std.math.add(u64, node_text_bytes, @intCast(node.text.len)) catch return error.RecordTooLarge;
    }
    var property_value_bytes: u64 = 0;
    for (snapshot.properties) |property| {
        const value_bytes: u64 = switch (property.value_kind) {
            .string => @intCast(property.string_value.len),
            .uint => 8,
        };
        property_value_bytes = std.math.add(u64, property_value_bytes, value_bytes) catch return error.RecordTooLarge;
    }
    const edge_bytes = std.math.mul(
        u64,
        @as(u64, @intCast(snapshot.edges.len)),
        format.logical_edge_bytes,
    ) catch return error.RecordTooLarge;
    const content_without_edges = std.math.add(u64, node_text_bytes, property_value_bytes) catch return error.RecordTooLarge;
    return .{
        .content_bytes = std.math.add(u64, content_without_edges, edge_bytes) catch return error.RecordTooLarge,
        .node_text_bytes = node_text_bytes,
        .property_value_bytes = property_value_bytes,
        .edge_bytes = edge_bytes,
        .property_count = @intCast(snapshot.properties.len),
    };
}

fn replayAfterAppend(
    allocator: std.mem.Allocator,
    previous: wal_mod.ReplayPlan,
    payload: []const u8,
    framed_bytes: u64,
) !wal_mod.ReplayPlan {
    const records = try allocator.alloc(wal_mod.Record, previous.records.len + 1);
    errdefer allocator.free(records);
    var initialized: usize = 0;
    errdefer for (records[0..initialized]) |record| allocator.free(record.payload);
    for (previous.records, 0..) |record, index| {
        records[index] = .{ .sequence = record.sequence, .kind = record.kind, .payload = try allocator.dupe(u8, record.payload) };
        initialized += 1;
    }
    records[previous.records.len] = .{
        .sequence = @intCast(previous.records.len + 1),
        .kind = .mutation,
        .payload = try allocator.dupe(u8, payload),
    };
    initialized += 1;
    return .{
        .allocator = allocator,
        .generation = previous.generation,
        .records = records,
        .valid_bytes = std.math.add(u64, previous.valid_bytes, framed_bytes) catch return error.RecordTooLarge,
        .truncated_tail_bytes = 0,
    };
}

fn replacementReplay(
    allocator: std.mem.Allocator,
    generation: u64,
    payload: ?[]const u8,
    replacement_bytes: u64,
) !wal_mod.ReplayPlan {
    const record_count: usize = if (payload == null) 0 else 1;
    const records = try allocator.alloc(wal_mod.Record, record_count);
    errdefer allocator.free(records);
    if (payload) |bytes| {
        records[0] = .{
            .sequence = 1,
            .kind = .mutation,
            .payload = try allocator.dupe(u8, bytes),
        };
    }
    return .{
        .allocator = allocator,
        .generation = generation,
        .records = records,
        .valid_bytes = replacement_bytes,
        .truncated_tail_bytes = 0,
    };
}

fn graphFromSnapshot(allocator: std.mem.Allocator, snapshot: @import("format.zig").Snapshot) !graph_mod.Graph {
    // The resident snapshot strictly outlives the graph (install and deinit
    // both tear indexes and graph down before the snapshot), so the graph
    // borrows node text instead of holding a second copy of every string.
    var graph = graph_mod.Graph.initBorrowedText(allocator);
    errdefer graph.deinit();
    for (snapshot.nodes) |node| try graph.addNodeWithId(
        core.NodeId.fromInt(node.id),
        @enumFromInt(node.kind),
        node.text,
    );
    for (snapshot.edges) |edge| try graph.addEdgeWithIdUnchecked(
        core.EdgeId.fromInt(edge.id),
        core.NodeId.fromInt(edge.src),
        @enumFromInt(edge.rel),
        core.NodeId.fromInt(edge.dst),
    );
    return graph;
}

test "checkpoint runtime opens canonical graph and resident indexes without expanded Store" {
    const format = @import("format.zig");
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try temporary.dir.realPath(std.testing.io, &path_buffer);
    var repository = try repository_mod.Repository.init(std.testing.allocator, std.testing.io, path_buffer[0..root_len], false);
    defer repository.deinit();
    var nodes = [_]format.Node{
        .{ .id = 1, .kind = @intFromEnum(core.NodeKind.task), .text = "resident alpha" },
        .{ .id = 9, .kind = @intFromEnum(core.NodeKind.verification), .text = "resident beta" },
    };
    var edges = [_]format.Edge{.{ .id = 4, .src = 1, .rel = @intFromEnum(core.RelKind.verified_by), .dst = 9 }};
    _ = try repository.publishSnapshot(.{ .nodes = &nodes, .edges = &edges, .properties = &.{} });
    var runtime = try Runtime.open(std.testing.allocator, std.testing.io, path_buffer[0..root_len], false);
    defer runtime.deinit();
    try std.testing.expectEqual(@as(u64, 1), runtime.generation());
    try std.testing.expect(runtime.graph.getNode(.fromInt(9)) != null);
    try std.testing.expectEqual(@as(usize, 1), runtime.graph_index.outgoing(.fromInt(1)).len);
    var hits = try runtime.text_index.search("resident beta", .{ .limit = 8 });
    defer hits.deinit(std.testing.allocator);
    try std.testing.expect(hits.items.len >= 1);
    try std.testing.expectEqual(core.NodeId.fromInt(9), hits.items[0].node_id);
}

test "checkpoint runtime startup completes GC after CURRENT publication crash window" {
    const format = @import("format.zig");
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try temporary.dir.realPath(std.testing.io, &path_buffer);
    const root = path_buffer[0..root_len];
    var repository = try repository_mod.Repository.init(std.testing.allocator, std.testing.io, root, false);
    var first_nodes = [_]format.Node{.{ .id = 1, .kind = @intFromEnum(core.NodeKind.document), .text = "before publication" }};
    _ = try repository.publishSnapshot(.{ .nodes = &first_nodes, .edges = &.{}, .properties = &.{} });
    var second_nodes = [_]format.Node{.{ .id = 1, .kind = @intFromEnum(core.NodeKind.document), .text = "after publication" }};
    _ = try repository.publishSnapshot(.{ .nodes = &second_nodes, .edges = &.{}, .properties = &.{} });
    const before = try repository.measureFootprint();
    try std.testing.expect(before.obsolete_checkpoint_bytes > 0);
    try std.testing.expect(before.obsolete_wal_bytes > 0);
    repository.deinit();

    // This open simulates restart after CHECKPOINT-2/WAL-2/CURRENT were
    // durable but before the publishing process reached collectObsolete().
    var runtime = try Runtime.open(std.testing.allocator, std.testing.io, root, false);
    errdefer runtime.deinit();
    defer runtime.deinit();
    try std.testing.expectEqual(@as(u64, 2), runtime.generation());
    try std.testing.expectEqualStrings("after publication", runtime.loaded.checkpoint.snapshot.nodes[0].text);
    try std.testing.expectEqual(@as(u64, 1), runtime.startupRecovery().deleted_checkpoint_files);
    try std.testing.expectEqual(@as(u64, 1), runtime.startupRecovery().deleted_wal_files);
    const after = try runtime.repository.measureFootprint();
    try std.testing.expectEqual(@as(u64, 0), after.obsolete_checkpoint_bytes);
    try std.testing.expectEqual(@as(u64, 0), after.obsolete_wal_bytes);
    try std.testing.expectEqual(@as(u64, 3), after.regular_files);
}

test "checkpoint runtime startup never GC's rollback generation when CURRENT is corrupt" {
    const format = @import("format.zig");
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try temporary.dir.realPath(std.testing.io, &path_buffer);
    const root = path_buffer[0..root_len];
    var repository = try repository_mod.Repository.init(std.testing.allocator, std.testing.io, root, false);
    defer repository.deinit();
    var first_nodes = [_]format.Node{.{ .id = 1, .kind = @intFromEnum(core.NodeKind.document), .text = "rollback remains" }};
    _ = try repository.publishSnapshot(.{ .nodes = &first_nodes, .edges = &.{}, .properties = &.{} });
    var second_nodes = [_]format.Node{.{ .id = 1, .kind = @intFromEnum(core.NodeKind.document), .text = "corrupt current" }};
    _ = try repository.publishSnapshot(.{ .nodes = &second_nodes, .edges = &.{}, .properties = &.{} });

    const current_path = try std.fs.path.join(std.testing.allocator, &.{ root, "CHECKPOINT-2" });
    defer std.testing.allocator.free(current_path);
    {
        var current_file = try std.Io.Dir.cwd().openFile(std.testing.io, current_path, .{ .mode = .read_write });
        defer current_file.close(std.testing.io);
        var byte: [1]u8 = undefined;
        if (try current_file.readPositionalAll(std.testing.io, &byte, 88) != 1) return error.InvalidRecord;
        byte[0] ^= 0x5a;
        try current_file.writePositionalAll(std.testing.io, &byte, 88);
    }
    try std.testing.expectError(error.DigestMismatch, Runtime.open(std.testing.allocator, std.testing.io, root, false));

    // The failed startup must leave generation 1 available for an explicit
    // operator rollback; no cleanup may run before current validation.
    var retained = try repository.loadGeneration(1);
    defer retained.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("rollback remains", retained.checkpoint.snapshot.nodes[0].text);
}

test "checkpoint runtime startup removes only pre-CURRENT publication artifacts" {
    const format = @import("format.zig");
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try temporary.dir.realPath(std.testing.io, &path_buffer);
    const root = path_buffer[0..root_len];
    var repository = try repository_mod.Repository.init(std.testing.allocator, std.testing.io, root, false);
    var first_nodes = [_]format.Node{.{ .id = 1, .kind = @intFromEnum(core.NodeKind.document), .text = "selected generation" }};
    _ = try repository.publishSnapshot(.{ .nodes = &first_nodes, .edges = &.{}, .properties = &.{} });
    var second_nodes = [_]format.Node{.{ .id = 1, .kind = @intFromEnum(core.NodeKind.document), .text = "not selected" }};
    _ = try repository.publishSnapshot(.{ .nodes = &second_nodes, .edges = &.{}, .properties = &.{} });
    _ = try repository.rollbackTo(1);
    repository.deinit();

    // Cover checkpoint-write interruption, WAL-create interruption and
    // CURRENT temporary-write interruption. Only recognized publication
    // artifacts may be reclaimed; unrelated regular files stay charged.
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "CHECKPOINT-3.tmp", .data = "partial-checkpoint" });
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "WAL-3.tmp", .data = "partial-wal" });
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "CURRENT.tmp", .data = "partial-current" });
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "operator-note", .data = "retain-and-charge" });

    var runtime = try Runtime.open(std.testing.allocator, std.testing.io, root, false);
    defer runtime.deinit();
    try std.testing.expectEqual(@as(u64, 1), runtime.generation());
    try std.testing.expectEqualStrings("selected generation", runtime.loaded.checkpoint.snapshot.nodes[0].text);
    const recovery = runtime.startupRecovery();
    try std.testing.expectEqual(@as(u64, 1), recovery.deleted_checkpoint_files);
    try std.testing.expectEqual(@as(u64, 1), recovery.deleted_wal_files);
    try std.testing.expectEqual(@as(u64, 3), recovery.deleted_temporary_files);
    const footprint = runtime.cachedFootprint();
    try std.testing.expectEqual(@as(u64, 0), footprint.obsolete_checkpoint_bytes);
    try std.testing.expectEqual(@as(u64, 0), footprint.obsolete_wal_bytes);
    try std.testing.expectEqual(@as(u64, "retain-and-charge".len), footprint.unknown_regular_bytes);
}

test "checkpoint runtime recovers an incomplete WAL tail and reports exact repair bytes" {
    const format = @import("format.zig");
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try temporary.dir.realPath(std.testing.io, &path_buffer);
    const root = path_buffer[0..root_len];
    const text = try std.testing.allocator.alloc(u8, 400 * 1024);
    defer std.testing.allocator.free(text);
    const pattern = "WAL crash tail canonical payload ";
    for (text, 0..) |*byte, index_pos| byte.* = pattern[index_pos % pattern.len];
    var repository = try repository_mod.Repository.init(std.testing.allocator, std.testing.io, root, false);
    defer repository.deinit();
    var nodes = [_]format.Node{.{ .id = 1, .kind = @intFromEnum(core.NodeKind.document), .text = text }};
    _ = try repository.publishSnapshot(.{ .nodes = &nodes, .edges = &.{}, .properties = &.{}, .catalog = "before" });
    var runtime = try Runtime.open(std.testing.allocator, std.testing.io, root, false);
    errdefer runtime.deinit();
    try std.testing.expectEqual(Runtime.CommitMode.wal, try runtime.applyMutation(&.{.{ .catalog_replace = "committed" }}));
    const wal_path = try std.testing.allocator.dupe(u8, runtime.wal.path);
    runtime.deinit();
    defer std.testing.allocator.free(wal_path);
    {
        var file = try std.Io.Dir.cwd().openFile(std.testing.io, wal_path, .{ .mode = .read_write });
        defer file.close(std.testing.io);
        const stat = try file.stat(std.testing.io);
        try file.writePositionalAll(std.testing.io, "REC1-partial", stat.size);
    }

    var recovered = try Runtime.open(std.testing.allocator, std.testing.io, root, false);
    errdefer recovered.deinit();
    defer recovered.deinit();
    try std.testing.expectEqual(@as(u64, 12), recovered.startupWalTruncatedBytes());
    try std.testing.expectEqualStrings("committed", recovered.loaded.checkpoint.snapshot.catalog);
    try std.testing.expectEqual(recovered.loaded.wal.valid_bytes, recovered.cachedFootprint().current_wal_bytes);
}

test "checkpoint runtime rejects a corrupt complete WAL frame before startup GC" {
    const format = @import("format.zig");
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try temporary.dir.realPath(std.testing.io, &path_buffer);
    const root = path_buffer[0..root_len];
    var repository = try repository_mod.Repository.init(std.testing.allocator, std.testing.io, root, false);
    defer repository.deinit();
    var first_nodes = [_]format.Node{.{ .id = 1, .kind = @intFromEnum(core.NodeKind.document), .text = "rollback WAL generation" }};
    _ = try repository.publishSnapshot(.{ .nodes = &first_nodes, .edges = &.{}, .properties = &.{} });
    var second_nodes = [_]format.Node{.{ .id = 1, .kind = @intFromEnum(core.NodeKind.document), .text = "current WAL generation" }};
    _ = try repository.publishSnapshot(.{ .nodes = &second_nodes, .edges = &.{}, .properties = &.{}, .catalog = "before" });

    var generation_two = try repository.loadGeneration(2);
    defer generation_two.deinit(std.testing.allocator);
    var prepared = try checkpoint_mutation.prepareAlloc(
        std.testing.allocator,
        generation_two.checkpoint.snapshot,
        &.{.{ .catalog_replace = "complete-frame" }},
    );
    defer prepared.deinit(std.testing.allocator);
    var wal = try wal_mod.Wal.openGeneration(std.testing.allocator, std.testing.io, root, 2, false);
    _ = try wal.append(.mutation, prepared.bytes);
    const wal_path = try std.testing.allocator.dupe(u8, wal.path);
    wal.deinit();
    defer std.testing.allocator.free(wal_path);
    {
        var file = try std.Io.Dir.cwd().openFile(std.testing.io, wal_path, .{ .mode = .read_write });
        defer file.close(std.testing.io);
        var byte: [1]u8 = undefined;
        const payload_offset = wal_mod.file_header_len + wal_mod.record_header_len;
        if (try file.readPositionalAll(std.testing.io, &byte, payload_offset) != 1) return error.InvalidRecord;
        byte[0] ^= 0x5a;
        try file.writePositionalAll(std.testing.io, &byte, payload_offset);
    }
    try std.testing.expectError(error.DigestMismatch, Runtime.open(std.testing.allocator, std.testing.io, root, false));
    var retained = try repository.loadGeneration(1);
    defer retained.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("rollback WAL generation", retained.checkpoint.snapshot.nodes[0].text);
}

test "checkpoint runtime restores old WAL when compaction crashes in the rename gap" {
    const format = @import("format.zig");
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try temporary.dir.realPath(std.testing.io, &path_buffer);
    const root = path_buffer[0..root_len];
    var repository = try repository_mod.Repository.init(std.testing.allocator, std.testing.io, root, false);
    defer repository.deinit();
    var nodes = [_]format.Node{.{ .id = 1, .kind = @intFromEnum(core.NodeKind.document), .text = "wal rename gap" }};
    _ = try repository.publishSnapshot(.{ .nodes = &nodes, .edges = &.{}, .properties = &.{}, .catalog = "base" });
    var base = try repository.loadCheckpointBase((try repository.readCurrent()).?);
    defer base.snapshot.deinitOwned(std.testing.allocator);
    var old_mutation = try checkpoint_mutation.prepareAlloc(
        std.testing.allocator,
        base.snapshot,
        &.{.{ .catalog_replace = "old-committed" }},
    );
    defer old_mutation.deinit(std.testing.allocator);
    var wal = try wal_mod.Wal.openGeneration(std.testing.allocator, std.testing.io, root, 1, false);
    defer wal.deinit();
    _ = try wal.append(.mutation, old_mutation.bytes);
    var replacement = try checkpoint_mutation.prepareAlloc(
        std.testing.allocator,
        base.snapshot,
        &.{.{ .catalog_replace = "new-not-committed" }},
    );
    defer replacement.deinit(std.testing.allocator);
    var staged = try wal.stageReplacement(replacement.bytes);
    try std.Io.Dir.renameAbsolute(wal.path, staged.rollback_path, std.testing.io);
    // Simulate process death: leave both the rollback and staged file on disk.
    staged.committed = true;
    staged.deinit();

    var recovered = try Runtime.open(std.testing.allocator, std.testing.io, root, false);
    defer recovered.deinit();
    try std.testing.expectEqualStrings("old-committed", recovered.loaded.checkpoint.snapshot.catalog);
    try std.testing.expectEqual(@as(u64, 1), recovered.startupRecovery().deleted_temporary_files);
    try std.testing.expectEqual(@as(u64, 3), recovered.cachedFootprint().regular_files);
}

test "checkpoint runtime adopts verified replacement WAL then removes rollback" {
    const format = @import("format.zig");
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try temporary.dir.realPath(std.testing.io, &path_buffer);
    const root = path_buffer[0..root_len];
    var repository = try repository_mod.Repository.init(std.testing.allocator, std.testing.io, root, false);
    defer repository.deinit();
    var nodes = [_]format.Node{.{ .id = 1, .kind = @intFromEnum(core.NodeKind.document), .text = "wal post rename" }};
    _ = try repository.publishSnapshot(.{ .nodes = &nodes, .edges = &.{}, .properties = &.{}, .catalog = "base" });
    var base = try repository.loadCheckpointBase((try repository.readCurrent()).?);
    defer base.snapshot.deinitOwned(std.testing.allocator);
    var replacement = try checkpoint_mutation.prepareAlloc(
        std.testing.allocator,
        base.snapshot,
        &.{.{ .catalog_replace = "new-committed" }},
    );
    defer replacement.deinit(std.testing.allocator);
    var wal = try wal_mod.Wal.openGeneration(std.testing.allocator, std.testing.io, root, 1, false);
    defer wal.deinit();
    var staged = try wal.stageReplacement(replacement.bytes);
    defer staged.deinit();
    try staged.commit();

    var recovered = try Runtime.open(std.testing.allocator, std.testing.io, root, false);
    defer recovered.deinit();
    try std.testing.expectEqualStrings("new-committed", recovered.loaded.checkpoint.snapshot.catalog);
    try std.testing.expectEqual(@as(u64, 1), recovered.startupRecovery().deleted_temporary_files);
    try std.testing.expectEqual(@as(u64, 3), recovered.cachedFootprint().regular_files);
}

test "checkpoint runtime compacts WAL and rejects a delta larger than the bounded log" {
    const format = @import("format.zig");
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try temporary.dir.realPath(std.testing.io, &path_buffer);
    const root = path_buffer[0..root_len];
    const text = try std.testing.allocator.alloc(u8, 400 * 1024);
    defer std.testing.allocator.free(text);
    const compressible_text = "resident checkpoint searchable payload ";
    for (text, 0..) |*byte, index_pos| byte.* = compressible_text[index_pos % compressible_text.len];
    var nodes = [_]format.Node{.{ .id = 1, .kind = @intFromEnum(core.NodeKind.document), .text = text }};
    var repository = try repository_mod.Repository.init(std.testing.allocator, std.testing.io, root, false);
    _ = try repository.publishSnapshot(.{ .nodes = &nodes, .edges = &.{}, .properties = &.{}, .catalog = "cat-1" });
    repository.deinit();

    var runtime = try Runtime.open(std.testing.allocator, std.testing.io, root, false);
    try std.testing.expectEqual(Runtime.CommitMode.wal, try runtime.applyMutation(&.{.{ .catalog_replace = "cat-2" }}));
    try std.testing.expectEqual(@as(u64, 1), runtime.generation());
    try std.testing.expectEqualStrings("cat-2", runtime.loaded.checkpoint.snapshot.catalog);
    runtime.deinit();

    var recovered = try Runtime.open(std.testing.allocator, std.testing.io, root, false);
    try std.testing.expectEqualStrings("cat-2", recovered.loaded.checkpoint.snapshot.catalog);
    const compact_catalog = try std.testing.allocator.alloc(u8, 20 * 1024);
    defer std.testing.allocator.free(compact_catalog);
    @memset(compact_catalog, 'c');
    try std.testing.expectEqual(Runtime.CommitMode.wal, try recovered.applyMutation(&.{.{ .catalog_replace = compact_catalog }}));
    try std.testing.expectEqual(Runtime.CommitMode.wal, try recovered.applyMutation(&.{.{ .catalog_replace = "small-final" }}));

    // Fill enough of the append log that the next frame cannot append. The
    // net state relative to the immutable checkpoint remains a small catalog
    // replacement, so Runtime can publish one equivalent compact WAL frame.
    const filler = try std.testing.allocator.alloc(u8, wal_mod.max_file_bytes);
    defer std.testing.allocator.free(filler);
    var random = std.Random.DefaultPrng.init(0x544b_4752_554e_5632);
    random.fill(filler);

    // Choose the largest incompressible prefix that actually fits the current
    // physical WAL. This keeps the test tied to v2's encoded-byte admission
    // instead of assuming logical length and stored length are equal.
    var replay_before_fill = try recovered.wal.replay();
    defer replay_before_fill.deinit();
    var low: usize = 0;
    var high: usize = filler.len + 1;
    while (low + 1 < high) {
        const middle = low + (high - low) / 2;
        var prepared = try checkpoint_mutation.prepareAlloc(
            std.testing.allocator,
            recovered.loaded.checkpoint.snapshot,
            &.{.{ .profiles_replace = filler[0..middle] }},
        );
        defer prepared.deinit(std.testing.allocator);
        var encoded = try wal_mod.encodePayloadAlloc(std.testing.allocator, prepared.bytes);
        defer encoded.deinit();
        if (replay_before_fill.valid_bytes + try encoded.framedBytes() <= wal_mod.max_file_bytes) {
            low = middle;
        } else {
            high = middle;
        }
    }
    if (low == 0) return error.WalBudgetNotExercised;
    try std.testing.expectEqual(Runtime.CommitMode.wal, try recovered.applyMutation(&.{.{ .profiles_replace = filler[0..low] }}));
    try std.testing.expectEqual(Runtime.CommitMode.wal_compacted, try recovered.applyMutation(&.{.{ .profiles_replace = "profile-final" }}));
    try std.testing.expectEqual(@as(u64, 1), recovered.generation());
    try std.testing.expectEqualStrings("small-final", recovered.loaded.checkpoint.snapshot.catalog);
    try std.testing.expectEqualStrings("profile-final", recovered.loaded.checkpoint.snapshot.profiles);
    const publication = recovered.lastPublication().?;
    try std.testing.expectEqual(
        publication.old_operational_bytes + publication.replacement_wal_bytes,
        publication.peak_operational_bytes,
    );
    try std.testing.expect(publication.peak_operational_bytes * 5 < publication.peak_logical_content_bytes);

    // A single semantic delta larger than the hard WAL bound has no safe
    // compact representation. It is rejected before any filesystem mutation.
    const large_schema = try std.testing.allocator.alloc(u8, 70 * 1024);
    defer std.testing.allocator.free(large_schema);
    random.fill(large_schema);
    try std.testing.expectError(error.CheckpointRequired, recovered.applyMutation(&.{.{ .schema_replace = large_schema }}));
    try std.testing.expectEqual(@as(u64, 1), recovered.generation());
    try std.testing.expectEqualStrings("", recovered.loaded.checkpoint.snapshot.schema);
    const footprint = try recovered.repository.measureFootprint();
    try std.testing.expectEqual(@as(u64, 3), footprint.regular_files);
    try std.testing.expectEqual(@as(u64, 0), footprint.obsolete_checkpoint_bytes);
    try std.testing.expectEqual(@as(u64, 0), footprint.obsolete_wal_bytes);
    try std.testing.expect(footprint.underTwentyPercent());
    recovered.deinit();

    var final = try Runtime.open(std.testing.allocator, std.testing.io, root, false);
    defer final.deinit();
    try std.testing.expectEqual(@as(u64, 1), final.generation());
    try std.testing.expectEqualStrings("small-final", final.loaded.checkpoint.snapshot.catalog);
    try std.testing.expectEqualStrings("profile-final", final.loaded.checkpoint.snapshot.profiles);
    try std.testing.expectEqualStrings("", final.loaded.checkpoint.snapshot.schema);
}
