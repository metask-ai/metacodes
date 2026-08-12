const std = @import("std");

/// Owns the canonical path layout and allocation lifetime of every path kept
/// by `storage.Store`. The owner façade may project these slices into its
/// stable public field layout, but filename derivation, rollback, and teardown
/// remain centralized here.
pub const OwnedPaths = struct {
    dir_path: []const u8,
    events_bin_path: []const u8,
    index_meta_path: []const u8,
    node_by_id_path: []const u8,
    node_texts_path: []const u8,
    node_by_text_path: []const u8,
    node_by_text_base_filter_path: []const u8,
    node_by_text_delta_path: []const u8,
    external_key_index_path: []const u8,
    node_props_index_path: []const u8,
    node_props_values_path: []const u8,
    node_props_overlay_index_path: []const u8,
    node_props_overlay_values_path: []const u8,
    edge_props_overlay_index_path: []const u8,
    edge_props_overlay_values_path: []const u8,
    property_payload_index_path: []const u8,
    property_payload_values_path: []const u8,
    property_payload_delta_path: []const u8,
    edge_external_key_index_path: []const u8,
    node_text_run_manifest_path: []const u8,
    node_text_run_current_path: []const u8,
    edge_by_id_path: []const u8,
    edge_by_src_path: []const u8,
    edge_by_dst_path: []const u8,
    edge_order_path: []const u8,
    edge_tombstones_path: []const u8,
    edge_segment_manifest_path: []const u8,
    edge_segment_current_path: []const u8,
    catalog_path: []const u8,

    pub fn init(allocator: std.mem.Allocator, dir_path: []const u8) !OwnedPaths {
        const owned_dir_path = try allocator.dupe(u8, dir_path);
        errdefer allocator.free(owned_dir_path);
        const events_bin_path = try joined(allocator, owned_dir_path, "events.bin");
        errdefer allocator.free(events_bin_path);
        const index_meta_path = try joined(allocator, owned_dir_path, "index.meta");
        errdefer allocator.free(index_meta_path);
        const node_by_id_path = try joined(allocator, owned_dir_path, "node_by_id.idx");
        errdefer allocator.free(node_by_id_path);
        const node_texts_path = try joined(allocator, owned_dir_path, "node_texts.dat");
        errdefer allocator.free(node_texts_path);
        const node_by_text_path = try joined(allocator, owned_dir_path, "node_by_text.idx");
        errdefer allocator.free(node_by_text_path);
        const node_by_text_base_filter_path = try std.fmt.allocPrint(allocator, "{s}.filter", .{node_by_text_path});
        errdefer allocator.free(node_by_text_base_filter_path);
        const node_by_text_delta_path = try joined(allocator, owned_dir_path, "node_by_text.delta");
        errdefer allocator.free(node_by_text_delta_path);
        const external_key_index_path = try joined(allocator, owned_dir_path, "external_keys.idx");
        errdefer allocator.free(external_key_index_path);
        const node_props_index_path = try joined(allocator, owned_dir_path, "node_props.idx");
        errdefer allocator.free(node_props_index_path);
        const node_props_values_path = try joined(allocator, owned_dir_path, "node_props.values");
        errdefer allocator.free(node_props_values_path);
        const node_props_overlay_index_path = try joined(allocator, owned_dir_path, "node_props_overlay.idx");
        errdefer allocator.free(node_props_overlay_index_path);
        const node_props_overlay_values_path = try joined(allocator, owned_dir_path, "node_props_overlay.values");
        errdefer allocator.free(node_props_overlay_values_path);
        const edge_props_overlay_index_path = try joined(allocator, owned_dir_path, "edge_props_overlay.idx");
        errdefer allocator.free(edge_props_overlay_index_path);
        const edge_props_overlay_values_path = try joined(allocator, owned_dir_path, "edge_props_overlay.values");
        errdefer allocator.free(edge_props_overlay_values_path);
        const property_payload_index_path = try joined(allocator, owned_dir_path, "property_payload.idx");
        errdefer allocator.free(property_payload_index_path);
        const property_payload_values_path = try joined(allocator, owned_dir_path, "property_payload.values");
        errdefer allocator.free(property_payload_values_path);
        const property_payload_delta_path = try joined(allocator, owned_dir_path, "property_payload.delta");
        errdefer allocator.free(property_payload_delta_path);
        const edge_external_key_index_path = try joined(allocator, owned_dir_path, "edge_external_keys.idx");
        errdefer allocator.free(edge_external_key_index_path);
        const node_text_run_manifest_path = try joined(allocator, owned_dir_path, "node_text_runs.manifest");
        errdefer allocator.free(node_text_run_manifest_path);
        const node_text_run_current_path = try joined(allocator, owned_dir_path, "node_text_runs.current");
        errdefer allocator.free(node_text_run_current_path);
        const edge_by_id_path = try joined(allocator, owned_dir_path, "edge_by_id.idx");
        errdefer allocator.free(edge_by_id_path);
        const edge_by_src_path = try joined(allocator, owned_dir_path, "edge_by_src.idx");
        errdefer allocator.free(edge_by_src_path);
        const edge_by_dst_path = try joined(allocator, owned_dir_path, "edge_by_dst.idx");
        errdefer allocator.free(edge_by_dst_path);
        const edge_order_path = try joined(allocator, owned_dir_path, "edge_order.idx");
        errdefer allocator.free(edge_order_path);
        const edge_tombstones_path = try joined(allocator, owned_dir_path, "edge_tombstones.idx");
        errdefer allocator.free(edge_tombstones_path);
        const edge_segment_manifest_path = try joined(allocator, owned_dir_path, "edge_segment.manifest");
        errdefer allocator.free(edge_segment_manifest_path);
        const edge_segment_current_path = try joined(allocator, owned_dir_path, "edge_segment_current");
        errdefer allocator.free(edge_segment_current_path);
        const catalog_path = try joined(allocator, owned_dir_path, "catalog.bin");
        errdefer allocator.free(catalog_path);

        return .{
            .dir_path = owned_dir_path,
            .events_bin_path = events_bin_path,
            .index_meta_path = index_meta_path,
            .node_by_id_path = node_by_id_path,
            .node_texts_path = node_texts_path,
            .node_by_text_path = node_by_text_path,
            .node_by_text_base_filter_path = node_by_text_base_filter_path,
            .node_by_text_delta_path = node_by_text_delta_path,
            .external_key_index_path = external_key_index_path,
            .node_props_index_path = node_props_index_path,
            .node_props_values_path = node_props_values_path,
            .node_props_overlay_index_path = node_props_overlay_index_path,
            .node_props_overlay_values_path = node_props_overlay_values_path,
            .edge_props_overlay_index_path = edge_props_overlay_index_path,
            .edge_props_overlay_values_path = edge_props_overlay_values_path,
            .property_payload_index_path = property_payload_index_path,
            .property_payload_values_path = property_payload_values_path,
            .property_payload_delta_path = property_payload_delta_path,
            .edge_external_key_index_path = edge_external_key_index_path,
            .node_text_run_manifest_path = node_text_run_manifest_path,
            .node_text_run_current_path = node_text_run_current_path,
            .edge_by_id_path = edge_by_id_path,
            .edge_by_src_path = edge_by_src_path,
            .edge_by_dst_path = edge_by_dst_path,
            .edge_order_path = edge_order_path,
            .edge_tombstones_path = edge_tombstones_path,
            .edge_segment_manifest_path = edge_segment_manifest_path,
            .edge_segment_current_path = edge_segment_current_path,
            .catalog_path = catalog_path,
        };
    }

    /// Projects a façade owner with the stable Store path field names back
    /// into the one teardown type. No ownership changes until `deinit` runs.
    pub fn borrowOwner(owner: anytype) OwnedPaths {
        return .{
            .dir_path = owner.dir_path,
            .events_bin_path = owner.events_bin_path,
            .index_meta_path = owner.index_meta_path,
            .node_by_id_path = owner.node_by_id_path,
            .node_texts_path = owner.node_texts_path,
            .node_by_text_path = owner.node_by_text_path,
            .node_by_text_base_filter_path = owner.node_by_text_base_filter_path,
            .node_by_text_delta_path = owner.node_by_text_delta_path,
            .external_key_index_path = owner.external_key_index_path,
            .node_props_index_path = owner.node_props_index_path,
            .node_props_values_path = owner.node_props_values_path,
            .node_props_overlay_index_path = owner.node_props_overlay_index_path,
            .node_props_overlay_values_path = owner.node_props_overlay_values_path,
            .edge_props_overlay_index_path = owner.edge_props_overlay_index_path,
            .edge_props_overlay_values_path = owner.edge_props_overlay_values_path,
            .property_payload_index_path = owner.property_payload_index_path,
            .property_payload_values_path = owner.property_payload_values_path,
            .property_payload_delta_path = owner.property_payload_delta_path,
            .edge_external_key_index_path = owner.edge_external_key_index_path,
            .node_text_run_manifest_path = owner.node_text_run_manifest_path,
            .node_text_run_current_path = owner.node_text_run_current_path,
            .edge_by_id_path = owner.edge_by_id_path,
            .edge_by_src_path = owner.edge_by_src_path,
            .edge_by_dst_path = owner.edge_by_dst_path,
            .edge_order_path = owner.edge_order_path,
            .edge_tombstones_path = owner.edge_tombstones_path,
            .edge_segment_manifest_path = owner.edge_segment_manifest_path,
            .edge_segment_current_path = owner.edge_segment_current_path,
            .catalog_path = owner.catalog_path,
        };
    }

    pub fn deinit(self: *OwnedPaths, allocator: std.mem.Allocator) void {
        allocator.free(self.edge_segment_current_path);
        allocator.free(self.catalog_path);
        allocator.free(self.edge_segment_manifest_path);
        allocator.free(self.edge_order_path);
        allocator.free(self.edge_by_dst_path);
        allocator.free(self.edge_by_src_path);
        allocator.free(self.edge_by_id_path);
        allocator.free(self.edge_tombstones_path);
        allocator.free(self.node_text_run_current_path);
        allocator.free(self.node_text_run_manifest_path);
        allocator.free(self.node_by_text_delta_path);
        allocator.free(self.external_key_index_path);
        allocator.free(self.node_props_index_path);
        allocator.free(self.node_props_values_path);
        allocator.free(self.node_props_overlay_index_path);
        allocator.free(self.node_props_overlay_values_path);
        allocator.free(self.edge_props_overlay_index_path);
        allocator.free(self.edge_props_overlay_values_path);
        allocator.free(self.property_payload_index_path);
        allocator.free(self.property_payload_values_path);
        allocator.free(self.property_payload_delta_path);
        allocator.free(self.edge_external_key_index_path);
        allocator.free(self.node_by_text_base_filter_path);
        allocator.free(self.node_by_text_path);
        allocator.free(self.node_texts_path);
        allocator.free(self.node_by_id_path);
        allocator.free(self.index_meta_path);
        allocator.free(self.events_bin_path);
        allocator.free(self.dir_path);
        self.* = undefined;
    }
};

fn joined(allocator: std.mem.Allocator, dir_path: []const u8, basename: []const u8) ![]u8 {
    return std.fs.path.join(allocator, &.{ dir_path, basename });
}

test "store paths derive every canonical basename under the owned root" {
    var paths = try OwnedPaths.init(std.testing.allocator, "store-root");
    defer paths.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("store-root", paths.dir_path);
    const cases = [_]struct { path: []const u8, basename: []const u8 }{
        .{ .path = paths.events_bin_path, .basename = "events.bin" },
        .{ .path = paths.index_meta_path, .basename = "index.meta" },
        .{ .path = paths.node_by_id_path, .basename = "node_by_id.idx" },
        .{ .path = paths.node_texts_path, .basename = "node_texts.dat" },
        .{ .path = paths.node_by_text_path, .basename = "node_by_text.idx" },
        .{ .path = paths.node_by_text_base_filter_path, .basename = "node_by_text.idx.filter" },
        .{ .path = paths.node_by_text_delta_path, .basename = "node_by_text.delta" },
        .{ .path = paths.external_key_index_path, .basename = "external_keys.idx" },
        .{ .path = paths.node_props_index_path, .basename = "node_props.idx" },
        .{ .path = paths.node_props_values_path, .basename = "node_props.values" },
        .{ .path = paths.node_props_overlay_index_path, .basename = "node_props_overlay.idx" },
        .{ .path = paths.node_props_overlay_values_path, .basename = "node_props_overlay.values" },
        .{ .path = paths.edge_props_overlay_index_path, .basename = "edge_props_overlay.idx" },
        .{ .path = paths.edge_props_overlay_values_path, .basename = "edge_props_overlay.values" },
        .{ .path = paths.property_payload_index_path, .basename = "property_payload.idx" },
        .{ .path = paths.property_payload_values_path, .basename = "property_payload.values" },
        .{ .path = paths.property_payload_delta_path, .basename = "property_payload.delta" },
        .{ .path = paths.edge_external_key_index_path, .basename = "edge_external_keys.idx" },
        .{ .path = paths.node_text_run_manifest_path, .basename = "node_text_runs.manifest" },
        .{ .path = paths.node_text_run_current_path, .basename = "node_text_runs.current" },
        .{ .path = paths.edge_by_id_path, .basename = "edge_by_id.idx" },
        .{ .path = paths.edge_by_src_path, .basename = "edge_by_src.idx" },
        .{ .path = paths.edge_by_dst_path, .basename = "edge_by_dst.idx" },
        .{ .path = paths.edge_order_path, .basename = "edge_order.idx" },
        .{ .path = paths.edge_tombstones_path, .basename = "edge_tombstones.idx" },
        .{ .path = paths.edge_segment_manifest_path, .basename = "edge_segment.manifest" },
        .{ .path = paths.edge_segment_current_path, .basename = "edge_segment_current" },
        .{ .path = paths.catalog_path, .basename = "catalog.bin" },
    };
    for (cases) |item| {
        try std.testing.expectEqualStrings(item.basename, std.fs.path.basename(item.path));
        try std.testing.expectEqualStrings(paths.dir_path, std.fs.path.dirname(item.path).?);
    }
}

test "store paths own the caller directory slice and derive the filter path" {
    const allocator = std.testing.allocator;
    const input = try allocator.dupe(u8, "mutable-root");
    defer allocator.free(input);

    var paths = try OwnedPaths.init(allocator, input);
    defer paths.deinit(allocator);
    input[0] = 'X';

    try std.testing.expectEqualStrings("mutable-root", paths.dir_path);
    const expected_filter = try std.fmt.allocPrint(allocator, "{s}.filter", .{paths.node_by_text_path});
    defer allocator.free(expected_filter);
    try std.testing.expectEqualStrings(expected_filter, paths.node_by_text_base_filter_path);
}

test "store paths teardown releases every owned allocation" {
    var tracking = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const allocator = tracking.allocator();
    var paths = try OwnedPaths.init(allocator, "tracked-root");

    try std.testing.expect(tracking.allocated_bytes > 0);
    try std.testing.expect(tracking.allocated_bytes > tracking.freed_bytes);
    paths.deinit(allocator);

    try std.testing.expectEqual(tracking.allocations, tracking.deallocations);
    try std.testing.expectEqual(tracking.allocated_bytes, tracking.freed_bytes);
}

fn storePathsAllocationFailure(allocator: std.mem.Allocator) !void {
    var paths = try OwnedPaths.init(allocator, "allocation-failure-root");
    defer paths.deinit(allocator);
}

test "store paths roll back every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        storePathsAllocationFailure,
        .{},
    );
}
