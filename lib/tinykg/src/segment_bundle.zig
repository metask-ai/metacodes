const std = @import("std");
const core = @import("core.zig");
const segment = @import("segment.zig");
const segment_manifest = @import("segment_manifest.zig");
const segment_node_index = @import("segment_node_index.zig");
const optimizer = @import("ql/optimizer.zig");
const executor = @import("ql/executor.zig");
const segment_executor = @import("ql/segment_executor.zig");
const physical = @import("segment_bundle/storage.zig");

/// Stable public segment-bundle façade. Physical publication and opening live
/// in the lower storage-independent owner; QL execution is composed here so
/// Storage can depend on physical bundles without importing the QL executor.
pub const nodes_leaf = physical.nodes_leaf;
pub const edges_leaf = physical.edges_leaf;
pub const manifest_leaf = physical.manifest_leaf;
pub const PublishInput = physical.PublishInput;
pub const GcResult = physical.GcResult;
pub const EdgeSegmentSet = physical.EdgeSegmentSet;

pub const publish = physical.publish;
pub const publishOrderedEdgeStreams = physical.publishOrderedEdgeStreams;
pub const publishOrderedCatalogAndEdgeStreams = physical.publishOrderedCatalogAndEdgeStreams;
pub const publishTrustedOrderedCatalogAndEdgeStreams = physical.publishTrustedOrderedCatalogAndEdgeStreams;
pub const publishTrustedOrderedCatalogAndEdgeReaders = physical.publishTrustedOrderedCatalogAndEdgeReaders;
pub const publishTrustedOrderedEdgeStreamsWithNodeEntry = physical.publishTrustedOrderedEdgeStreamsWithNodeEntry;
pub const publishTrustedOrderedEdgeReadersWithNodeEntry = physical.publishTrustedOrderedEdgeReadersWithNodeEntry;
pub const publishEdgeDeltaWithExistingEntriesStreams = physical.publishEdgeDeltaWithExistingEntriesStreams;
pub const gcUnpinned = physical.gcUnpinned;

/// Preserves the existing public Opened shape and query methods while keeping
/// the physical owner free of QL and Storage façade dependencies.
pub const Opened = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    root_dir: []u8,
    snapshot: segment_manifest.Snapshot,
    catalog: segment_node_index.MappedCatalog,
    edge_segment: EdgeSegmentSet,

    pub fn deinit(self: *Opened) void {
        self.edge_segment.deinit();
        self.catalog.deinit();
        self.snapshot.deinit(self.allocator);
        self.allocator.free(self.root_dir);
    }

    pub fn executeExactTextPath(
        self: *Opened,
        allocator: std.mem.Allocator,
        plan: optimizer.PhysicalPlan,
        budget: core.QueryBudget,
    ) !executor.ResultTable {
        return segment_executor.executeExactTextPathWithCatalog(
            allocator,
            .{ .catalog = &self.catalog, .segment = &self.edge_segment },
            plan,
            budget,
        );
    }

    pub fn executeExactTextPathExplain(
        self: *Opened,
        allocator: std.mem.Allocator,
        plan: optimizer.PhysicalPlan,
        budget: core.QueryBudget,
        timings: *executor.OperatorTimingRecorder,
    ) !executor.ResultTable {
        return segment_executor.executeExactTextPathWithCatalogExplain(
            allocator,
            .{ .catalog = &self.catalog, .segment = &self.edge_segment },
            plan,
            budget,
            timings,
        );
    }
};

pub fn openTrusted(allocator: std.mem.Allocator, io: std.Io, root_dir: []const u8) !Opened {
    const opened = try physical.openTrusted(allocator, io, root_dir);
    return .{
        .allocator = opened.allocator,
        .io = opened.io,
        .root_dir = opened.root_dir,
        .snapshot = opened.snapshot,
        .catalog = opened.catalog,
        .edge_segment = opened.edge_segment,
    };
}

test "segment bundle facade preserves trusted open and exact QL execution" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buffer);
    const root_dir = path_buffer[0..root_len];
    const nodes = [_]segment_executor.NodeInfoEntry{
        .{ .id = .fromInt(10), .kind = .file, .text = "src/main.zig" },
        .{ .id = .fromInt(20), .kind = .function, .text = "main" },
    };
    const edges = [_]segment.EdgeRecord{
        .{ .edge_id = .fromInt(7), .src = .fromInt(10), .rel = .defines, .dst = .fromInt(20) },
    };
    try publish(std.testing.allocator, std.testing.io, root_dir, .{
        .nodes = &nodes,
        .edges = &edges,
        .wal_checkpoint_bytes = 128,
    });

    var opened = try openTrusted(std.testing.allocator, std.testing.io, root_dir);
    defer opened.deinit();
    var ops = std.ArrayList(optimizer.PhysicalOp).empty;
    defer ops.deinit(std.testing.allocator);
    try ops.append(std.testing.allocator, .{ .node_lookup_by_text = .{ .var_name = "f", .kind = .file, .text = "src/main.zig" } });
    try ops.append(std.testing.allocator, .{ .expand = .{
        .left_var = "f",
        .rel = .defines,
        .right_var = "s",
        .right_kind = .function,
    } });
    try ops.append(std.testing.allocator, .{ .project = &.{} });

    var table = try opened.executeExactTextPath(std.testing.allocator, .{ .ops = ops }, .{});
    defer table.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), table.rows.items.len);
    try std.testing.expectEqual(@as(u64, 10), table.rows.items[0].get("f").?.toInt());
    try std.testing.expectEqual(@as(u64, 20), table.rows.items[0].get("s").?.toInt());
}
