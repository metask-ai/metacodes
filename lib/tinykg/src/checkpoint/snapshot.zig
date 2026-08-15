const std = @import("std");
const storage = @import("../storage.zig");
const format = @import("format.zig");

const maximum_manifest_bytes: usize = 64 * 1024;

const EdgeContext = struct {
    allocator: std.mem.Allocator,
    edges: *std.ArrayList(format.Edge),

    fn visit(raw: *anyopaque, record: storage.EdgeIndexRecord) anyerror!void {
        const context: *@This() = @ptrCast(@alignCast(raw));
        try context.edges.append(context.allocator, .{
            .id = record.edge_id,
            .src = record.src,
            .rel = @intFromEnum(try record.relKind()),
            .dst = record.dst,
        });
    }
};

const EdgeOrderContext = struct {
    allocator: std.mem.Allocator,
    orders: *std.ArrayList(format.EdgeOrder),

    fn visit(raw: *anyopaque, record: storage.EdgeOrderRecord) anyerror!void {
        const context: *@This() = @ptrCast(@alignCast(raw));
        try context.orders.append(context.allocator, .{
            .edge_id = record.edge_id,
            .order_key = record.order_key,
        });
    }
};

/// Capture every canonical Store component owned by checkpoint v2. The result
/// owns all slices and is released with `Snapshot.deinitOwned`.
pub fn captureAlloc(allocator: std.mem.Allocator, store: storage.Store) !format.Snapshot {
    var nodes = std.ArrayList(format.Node).empty;
    errdefer {
        for (nodes.items) |node| allocator.free(node.text);
        nodes.deinit(allocator);
    }
    var node_iterator = try store.nodeRecordsIterator(null);
    defer node_iterator.deinit();
    while (try node_iterator.next(allocator)) |node_value| {
        var node = node_value;
        defer node.deinit(allocator);
        const text = try allocator.dupe(u8, node.text);
        errdefer allocator.free(text);
        try nodes.append(allocator, .{
            .id = node.id.toInt(),
            .kind = @intFromEnum(node.kind),
            .text = text,
        });
    }

    var edges = std.ArrayList(format.Edge).empty;
    errdefer edges.deinit(allocator);
    var edge_context = EdgeContext{ .allocator = allocator, .edges = &edges };
    const edge_count = try store.scanVisibleEdgeIndexRecords(allocator, &edge_context, EdgeContext.visit);
    if (edge_count != edges.items.len) return error.InvalidRecord;

    var edge_orders = std.ArrayList(format.EdgeOrder).empty;
    errdefer edge_orders.deinit(allocator);
    var order_context = EdgeOrderContext{ .allocator = allocator, .orders = &edge_orders };
    const order_count = try store.scanEdgeOrderRecords(&order_context, EdgeOrderContext.visit);
    if (order_count != edge_orders.items.len) return error.InvalidRecord;

    var properties = std.ArrayList(format.Property).empty;
    errdefer {
        for (properties.items) |property| if (property.value_kind == .string) allocator.free(property.string_value);
        properties.deinit(allocator);
    }
    var property_snapshot = try store.loadPropertySnapshot(allocator);
    defer property_snapshot.deinit(allocator);
    try properties.ensureTotalCapacity(allocator, property_snapshot.entries.len);
    for (property_snapshot.entries) |property| {
        const owner = switch (property.owner) {
            .node => |id| .{ @as(u8, 1), id.toInt() },
            .edge => |id| .{ @as(u8, 2), id.toInt() },
        };
        var captured = format.Property{
            .owner_type = owner[0],
            .owner_id = owner[1],
            .key_hash = property.key_hash,
            .value_kind = switch (property.value_kind) {
                .string => .string,
                .uint => .uint,
            },
            .uint_value = property.uint_value,
        };
        if (property.value_kind == .string) captured.string_value = try allocator.dupe(u8, property.string_value);
        errdefer if (property.value_kind == .string) allocator.free(captured.string_value);
        properties.appendAssumeCapacity(captured);
    }

    const catalog = (try store.readCatalogBytesAlloc(allocator)) orelse return error.InvalidRecord;
    errdefer allocator.free(catalog);
    const manifest_path = try std.fs.path.join(allocator, &.{ store.dir_path, ".tinykg", "store-manifest.json" });
    defer allocator.free(manifest_path);
    const manifest = try std.Io.Dir.cwd().readFileAlloc(store.io, manifest_path, allocator, .limited(maximum_manifest_bytes));
    errdefer allocator.free(manifest);

    return .{
        .nodes = try nodes.toOwnedSlice(allocator),
        .edges = try edges.toOwnedSlice(allocator),
        .edge_orders = try edge_orders.toOwnedSlice(allocator),
        .properties = try properties.toOwnedSlice(allocator),
        .catalog = catalog,
        // Checkpoint v2 preserves the exact Store manifest in this metadata
        // slot. It includes storage/schema versions and enabled profiles.
        .schema = manifest,
        .profiles = &.{},
    };
}

test "checkpoint snapshot captures every legacy Store semantic owner" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try temporary.dir.realPath(std.testing.io, &path_buffer);
    const store_path = try std.fs.path.join(std.testing.allocator, &.{ path_buffer[0..root_len], "snapshot.kg" });
    defer std.testing.allocator.free(store_path);

    var store = try storage.Store.init(std.testing.allocator, std.testing.io, store_path);
    defer store.deinit();
    try store.createEmpty();
    try store.appendNodesBatch(&.{
        .{ .id = .fromInt(1), .kind = .task, .text = "snapshot task" },
        .{ .id = .fromInt(2), .kind = .document, .text = "snapshot evidence" },
    });
    try store.appendEdgeOrderedIndexed(
        .{ .id = .fromInt(3), .src = .fromInt(1), .rel = .verified_by, .dst = .fromInt(2) },
        1024,
    );
    try store.setNodeStringProperty(std.testing.allocator, .fromInt(1), "status", "open");
    const metadata_directory = try std.fs.path.join(std.testing.allocator, &.{ store_path, ".tinykg" });
    defer std.testing.allocator.free(metadata_directory);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, metadata_directory);
    const manifest_path = try std.fs.path.join(std.testing.allocator, &.{ metadata_directory, "store-manifest.json" });
    defer std.testing.allocator.free(manifest_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = manifest_path, .data =
        \\{"store_manifest_version":1,"storage_format_version":3,"schema":{"schema_version":3,"enabled_profiles":[]}}
    });

    var captured = try captureAlloc(std.testing.allocator, store);
    defer captured.deinitOwned(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), captured.nodes.len);
    try std.testing.expectEqual(@as(usize, 1), captured.edges.len);
    try std.testing.expectEqual(@as(usize, 1), captured.edge_orders.len);
    try std.testing.expectEqual(@as(usize, 1), captured.properties.len);
    try std.testing.expectEqualStrings("snapshot task", captured.nodes[0].text);
    try std.testing.expectEqual(@as(u64, 1024), captured.edge_orders[0].order_key);
    try std.testing.expectEqualStrings("open", captured.properties[0].string_value);
    try std.testing.expect(captured.catalog.len != 0 and captured.schema.len != 0);
}
