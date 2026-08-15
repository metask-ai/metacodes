const std = @import("std");
const core = @import("../core.zig");
const graph = @import("../graph.zig");
const storage = @import("../storage.zig");
const format = @import("format.zig");
const checkpoint_snapshot = @import("snapshot.zig");
const checkpoint_store = @import("store.zig");

const PropertyStream = struct {
    properties: []const format.Property,
    position: usize = 0,

    fn next(raw: *anyopaque) anyerror!?storage.SortedPropertyPayloadEntry {
        const self: *@This() = @ptrCast(@alignCast(raw));
        if (self.position == self.properties.len) return null;
        const property = self.properties[self.position];
        self.position += 1;
        const owner: storage.PropertyOwner = switch (property.owner_type) {
            1 => .{ .node = core.NodeId.fromInt(property.owner_id) },
            2 => .{ .edge = core.EdgeId.fromInt(property.owner_id) },
            else => return error.InvalidRecord,
        };
        return .{
            .owner = owner,
            .key_hash = property.key_hash,
            .value = switch (property.value_kind) {
                .string => .{ .string = property.string_value },
                .uint => .{ .uint = property.uint_value },
            },
        };
    }
};

fn edgeIdLessThan(_: void, lhs: graph.Edge, rhs: graph.Edge) bool {
    return lhs.id.toInt() < rhs.id.toInt();
}

/// Materialize a decoded checkpoint into an isolated legacy Store. This is a
/// semantic recovery oracle and migration bridge, not the final compressed
/// daemon layout: callers must not count the expanded target as a <20% Store.
pub fn materializeDirectory(
    allocator: std.mem.Allocator,
    io: std.Io,
    directory: []const u8,
    snapshot: format.Snapshot,
    options: storage.StorageOptions,
) !void {
    if (snapshot.nodes.len == 0 or snapshot.catalog.len == 0 or snapshot.schema.len == 0 or snapshot.profiles.len != 0) return error.InvalidRecord;
    // Validate control metadata before creating any target bytes.
    var catalog = try @import("../catalog.zig").decodeCatalog(allocator, snapshot.catalog);
    catalog.deinit();
    const manifest = std.json.parseFromSlice(std.json.Value, allocator, snapshot.schema, .{}) catch return error.InvalidStoreManifest;
    defer manifest.deinit();
    if (manifest.value != .object) return error.InvalidStoreManifest;

    var store = try storage.Store.initWithOptions(allocator, io, directory, options);
    defer store.deinit();
    try store.createEmpty();

    const nodes = try allocator.alloc(graph.Node, snapshot.nodes.len);
    defer allocator.free(nodes);
    for (snapshot.nodes, nodes) |source, *target| target.* = .{
        .id = core.NodeId.fromInt(source.id),
        .kind = @enumFromInt(source.kind),
        .text = source.text,
    };
    try store.appendNodesBatch(nodes);

    const edges = try allocator.alloc(graph.Edge, snapshot.edges.len);
    defer allocator.free(edges);
    for (snapshot.edges, edges) |source, *target| target.* = .{
        .id = core.EdgeId.fromInt(source.id),
        .src = core.NodeId.fromInt(source.src),
        .rel = @enumFromInt(source.rel),
        .dst = core.NodeId.fromInt(source.dst),
    };
    std.mem.sort(graph.Edge, edges, {}, edgeIdLessThan);
    try store.appendEdgesBatch(edges);

    if (snapshot.edge_orders.len != 0) {
        var edge_by_id = std.AutoHashMap(u64, graph.Edge).init(allocator);
        defer edge_by_id.deinit();
        try edge_by_id.ensureTotalCapacity(std.math.cast(u32, edges.len) orelse return error.RecordTooLarge);
        for (edges) |edge| try edge_by_id.putNoClobber(edge.id.toInt(), edge);
        const orders = try allocator.alloc(storage.EdgeOrderRecord, snapshot.edge_orders.len);
        defer allocator.free(orders);
        for (snapshot.edge_orders, orders) |source, *target| {
            const edge = edge_by_id.get(source.edge_id) orelse return error.InvalidRecord;
            target.* = .{
                .src = edge.src.toInt(),
                .rel = @intFromEnum(edge.rel),
                .edge_id = source.edge_id,
                .order_key = source.order_key,
            };
        }
        try store.upsertEdgeOrderRecordsBatch(allocator, orders);
    }

    var property_stream = PropertyStream{ .properties = snapshot.properties };
    try store.replaceEmptyPropertyPayloadFromSortedStream(snapshot.properties.len, &property_stream, PropertyStream.next);
    if (property_stream.position != snapshot.properties.len) return error.InvalidRecord;
    try store.restoreCatalogBytes(snapshot.catalog);

    const metadata_directory = try std.fs.path.join(allocator, &.{ directory, ".tinykg" });
    defer allocator.free(metadata_directory);
    try std.Io.Dir.cwd().createDirPath(io, metadata_directory);
    const manifest_path = try std.fs.path.join(allocator, &.{ metadata_directory, "store-manifest.json" });
    defer allocator.free(manifest_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = manifest_path, .data = snapshot.schema });
}

test "checkpoint materialization preserves complete canonical semantics" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try temporary.dir.realPath(std.testing.io, &path_buffer);
    const source_path = try std.fs.path.join(std.testing.allocator, &.{ path_buffer[0..root_len], "source.kg" });
    defer std.testing.allocator.free(source_path);
    const target_path = try std.fs.path.join(std.testing.allocator, &.{ path_buffer[0..root_len], "target.kg" });
    defer std.testing.allocator.free(target_path);

    var source = try storage.Store.init(std.testing.allocator, std.testing.io, source_path);
    var source_open = true;
    defer if (source_open) source.deinit();
    try source.createEmpty();
    try source.appendNodesBatch(&.{
        .{ .id = .fromInt(1), .kind = .document, .text = "ordered document" },
        .{ .id = .fromInt(7), .kind = .document_section, .text = "section" },
    });
    try source.appendEdgeOrderedIndexed(.{ .id = .fromInt(5), .src = .fromInt(1), .rel = .contain, .dst = .fromInt(7) }, 1024);
    try source.setNodeStringProperty(std.testing.allocator, .fromInt(1), "external_key", "doc:one");
    try source.setUintProperty(std.testing.allocator, .{ .edge = .fromInt(5) }, "order_key", 1024);
    const metadata_directory = try std.fs.path.join(std.testing.allocator, &.{ source_path, ".tinykg" });
    defer std.testing.allocator.free(metadata_directory);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, metadata_directory);
    const manifest_path = try std.fs.path.join(std.testing.allocator, &.{ metadata_directory, "store-manifest.json" });
    defer std.testing.allocator.free(manifest_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = manifest_path, .data =
        \\{"store_manifest_version":1,"storage_format_version":3,"schema":{"schema_version":3,"enabled_profiles":["markdown-document"]}}
    });
    var captured = try checkpoint_snapshot.captureAlloc(std.testing.allocator, source);
    defer captured.deinitOwned(std.testing.allocator);
    const original = try checkpoint_store.encodeAlloc(std.testing.allocator, captured);
    defer original.deinit(std.testing.allocator);
    source.deinit();
    source_open = false;

    try materializeDirectory(std.testing.allocator, std.testing.io, target_path, captured, .{});
    var target = try storage.Store.open(std.testing.allocator, std.testing.io, target_path);
    defer target.deinit();
    var restored = try checkpoint_snapshot.captureAlloc(std.testing.allocator, target);
    defer restored.deinitOwned(std.testing.allocator);
    const roundtrip = try checkpoint_store.encodeAlloc(std.testing.allocator, restored);
    defer roundtrip.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(u8, original.bytes, roundtrip.bytes);
}
