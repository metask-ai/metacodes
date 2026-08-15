const std = @import("std");

/// Fixed-size, last-measured Store logical-content and physical-footprint
/// metadata.
///
/// Ordinary inspection reads exactly this file. Explicit refresh owns the
/// canonical semantic scans plus the recursive filesystem walk and atomically
/// replaces the snapshot only after every measurement succeeds.
const file_name = "store_size.meta";
const temporary_file_name = "store_size.meta.tmp";
const magic = [_]u8{ 'T', 'K', 'G', 'S' };
const version: u16 = 2;
const encoded_len: usize = 128;

/// GB10 ladder-compatible logical accounting. This is deliberately a stable
/// semantic accounting width, not a promise about any physical edge codec.
const logical_edge_accounting_version: u16 = 1;
const logical_edge_bytes_per_edge: u64 = 16;

const LogicalContent = struct {
    node_text_bytes: u64,
    property_value_bytes: u64,
    visible_edge_count: u64,
    node_count: u64,
    property_count: u64,

    pub fn edgeBytes(self: LogicalContent) !u64 {
        return std.math.mul(u64, self.visible_edge_count, logical_edge_bytes_per_edge) catch return error.RecordTooLarge;
    }

    pub fn totalBytes(self: LogicalContent) !u64 {
        var total = std.math.add(u64, self.node_text_bytes, self.property_value_bytes) catch return error.RecordTooLarge;
        total = std.math.add(u64, total, try self.edgeBytes()) catch return error.RecordTooLarge;
        return total;
    }
};

pub const Snapshot = struct {
    logical_content_bytes: u64,
    logical_node_text_bytes: u64,
    logical_property_value_bytes: u64,
    logical_edge_bytes: u64,
    physical_bytes: u64,
    regular_files: u64,
    node_count: u64,
    property_count: u64,
    visible_edge_count: u64,
    generation: u64,
    refreshed_ns: u64,
    logical_accounting_version: u16 = logical_edge_accounting_version,
};

const Scan = struct {
    physical_bytes: u64 = 0,
    regular_files: u64 = 0,

    fn addFile(self: *Scan, bytes: u64) !void {
        self.physical_bytes = std.math.add(u64, self.physical_bytes, bytes) catch return error.RecordTooLarge;
        self.regular_files = std.math.add(u64, self.regular_files, 1) catch return error.RecordTooLarge;
    }
};

fn encode(snapshot: Snapshot, out: *[encoded_len]u8) void {
    @memset(out, 0);
    @memcpy(out[0..4], &magic);
    std.mem.writeInt(u16, out[4..6], version, .little);
    std.mem.writeInt(u16, out[6..8], encoded_len, .little);
    std.mem.writeInt(u16, out[8..10], snapshot.logical_accounting_version, .little);
    std.mem.writeInt(u64, out[16..24], snapshot.logical_content_bytes, .little);
    std.mem.writeInt(u64, out[24..32], snapshot.logical_node_text_bytes, .little);
    std.mem.writeInt(u64, out[32..40], snapshot.logical_property_value_bytes, .little);
    std.mem.writeInt(u64, out[40..48], snapshot.logical_edge_bytes, .little);
    std.mem.writeInt(u64, out[48..56], snapshot.physical_bytes, .little);
    std.mem.writeInt(u64, out[56..64], snapshot.regular_files, .little);
    std.mem.writeInt(u64, out[64..72], snapshot.node_count, .little);
    std.mem.writeInt(u64, out[72..80], snapshot.property_count, .little);
    std.mem.writeInt(u64, out[80..88], snapshot.visible_edge_count, .little);
    std.mem.writeInt(u64, out[88..96], snapshot.generation, .little);
    std.mem.writeInt(u64, out[96..104], snapshot.refreshed_ns, .little);
    std.mem.writeInt(u64, out[104..112], checksum(out[0..104]), .little);
}

fn decode(bytes: *const [encoded_len]u8) !Snapshot {
    if (!std.mem.eql(u8, bytes[0..4], &magic)) return error.InvalidRecord;
    if (std.mem.readInt(u16, bytes[4..6], .little) != version) return error.InvalidRecord;
    if (std.mem.readInt(u16, bytes[6..8], .little) != encoded_len) return error.InvalidRecord;
    if (std.mem.readInt(u64, bytes[104..112], .little) != checksum(bytes[0..104])) return error.InvalidRecord;
    for (bytes[10..16]) |byte| if (byte != 0) return error.InvalidRecord;
    for (bytes[112..]) |byte| if (byte != 0) return error.InvalidRecord;
    const snapshot = Snapshot{
        .logical_accounting_version = std.mem.readInt(u16, bytes[8..10], .little),
        .logical_content_bytes = std.mem.readInt(u64, bytes[16..24], .little),
        .logical_node_text_bytes = std.mem.readInt(u64, bytes[24..32], .little),
        .logical_property_value_bytes = std.mem.readInt(u64, bytes[32..40], .little),
        .logical_edge_bytes = std.mem.readInt(u64, bytes[40..48], .little),
        .physical_bytes = std.mem.readInt(u64, bytes[48..56], .little),
        .regular_files = std.mem.readInt(u64, bytes[56..64], .little),
        .node_count = std.mem.readInt(u64, bytes[64..72], .little),
        .property_count = std.mem.readInt(u64, bytes[72..80], .little),
        .visible_edge_count = std.mem.readInt(u64, bytes[80..88], .little),
        .generation = std.mem.readInt(u64, bytes[88..96], .little),
        .refreshed_ns = std.mem.readInt(u64, bytes[96..104], .little),
    };
    if (snapshot.logical_accounting_version != logical_edge_accounting_version) return error.InvalidRecord;
    if (snapshot.regular_files == 0 or snapshot.generation == 0) return error.InvalidRecord;
    if (snapshot.physical_bytes < encoded_len) return error.InvalidRecord;
    const expected_edge_bytes = std.math.mul(u64, snapshot.visible_edge_count, logical_edge_bytes_per_edge) catch return error.InvalidRecord;
    if (snapshot.logical_edge_bytes != expected_edge_bytes) return error.InvalidRecord;
    var expected_total = std.math.add(u64, snapshot.logical_node_text_bytes, snapshot.logical_property_value_bytes) catch return error.InvalidRecord;
    expected_total = std.math.add(u64, expected_total, snapshot.logical_edge_bytes) catch return error.InvalidRecord;
    if (snapshot.logical_content_bytes != expected_total) return error.InvalidRecord;
    return snapshot;
}

pub fn read(allocator: std.mem.Allocator, io: std.Io, store_path: []const u8) !?Snapshot {
    const path = try std.fs.path.join(allocator, &.{ store_path, file_name });
    defer allocator.free(path);
    var file = std.Io.Dir.cwd().openFile(io, path, .{ .allow_directory = false }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => |e| return e,
    };
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.kind != .file or stat.size != encoded_len) return error.InvalidRecord;
    var bytes: [encoded_len]u8 = undefined;
    if (try file.readPositionalAll(io, &bytes, 0) != bytes.len) return error.InvalidRecord;
    return try decode(&bytes);
}

/// Recompute logical bytes from canonical current Store views before the
/// physical scan. The concrete Store and edge-record type are injected by the
/// storage façade so this owner remains independent of storage/root.zig.
pub fn refreshStore(
    comptime EdgeIndexRecord: type,
    store: anytype,
    durable: bool,
) !Snapshot {
    const PropertyKey = struct {
        owner_kind: u8,
        owner_id: u64,
        key_hash: u64,
    };
    const OwnerKey = struct {
        owner_kind: u8,
        owner_id: u64,
    };
    const OwnerMetrics = struct {
        value_bytes: u64 = 0,
        property_count: u64 = 0,
    };
    var properties = try store.loadPropertySnapshot(store.allocator);
    defer properties.deinit(store.allocator);
    var effective_property_bytes = std.AutoHashMap(PropertyKey, u64).init(store.allocator);
    defer effective_property_bytes.deinit();
    try effective_property_bytes.ensureTotalCapacity(std.math.cast(u32, properties.entries.len) orelse return error.RecordTooLarge);
    for (properties.entries) |property| {
        const owner = switch (property.owner) {
            .node => |id| .{ @as(u8, 1), id.toInt() },
            .edge => |id| .{ @as(u8, 2), id.toInt() },
        };
        try effective_property_bytes.put(.{
            .owner_kind = owner[0],
            .owner_id = owner[1],
            .key_hash = property.key_hash,
        }, switch (property.value_kind) {
            .string => property.string_len,
            .uint => @sizeOf(u64),
        });
    }
    var owner_metrics = std.AutoHashMap(OwnerKey, OwnerMetrics).init(store.allocator);
    defer owner_metrics.deinit();
    try owner_metrics.ensureTotalCapacity(std.math.cast(u32, effective_property_bytes.count()) orelse return error.RecordTooLarge);
    var effective_iterator = effective_property_bytes.iterator();
    while (effective_iterator.next()) |entry| {
        const owner = OwnerKey{
            .owner_kind = entry.key_ptr.owner_kind,
            .owner_id = entry.key_ptr.owner_id,
        };
        const aggregate = try owner_metrics.getOrPut(owner);
        if (!aggregate.found_existing) aggregate.value_ptr.* = .{};
        aggregate.value_ptr.value_bytes = std.math.add(u64, aggregate.value_ptr.value_bytes, entry.value_ptr.*) catch return error.RecordTooLarge;
        aggregate.value_ptr.property_count = std.math.add(u64, aggregate.value_ptr.property_count, 1) catch return error.RecordTooLarge;
    }

    var node_text_bytes: u64 = 0;
    var node_count: u64 = 0;
    var property_value_bytes: u64 = 0;
    var property_count: u64 = 0;
    var nodes = try store.nodeRecordsIterator(null);
    defer nodes.deinit();
    while (try nodes.nextRef()) |node| {
        node_text_bytes = std.math.add(u64, node_text_bytes, node.text_len) catch return error.RecordTooLarge;
        node_count = std.math.add(u64, node_count, 1) catch return error.RecordTooLarge;
        if (owner_metrics.get(.{ .owner_kind = 1, .owner_id = node.id.toInt() })) |metrics| {
            property_value_bytes = std.math.add(u64, property_value_bytes, metrics.value_bytes) catch return error.RecordTooLarge;
            property_count = std.math.add(u64, property_count, metrics.property_count) catch return error.RecordTooLarge;
        }
    }

    const EdgeCount = struct {
        owner_metrics: *const std.AutoHashMap(OwnerKey, OwnerMetrics),
        property_value_bytes: *u64,
        property_count: *u64,

        fn visit(raw: *anyopaque, edge: EdgeIndexRecord) anyerror!void {
            const context: *@This() = @ptrCast(@alignCast(raw));
            if (context.owner_metrics.get(.{ .owner_kind = 2, .owner_id = edge.edge_id })) |metrics| {
                context.property_value_bytes.* = std.math.add(u64, context.property_value_bytes.*, metrics.value_bytes) catch return error.RecordTooLarge;
                context.property_count.* = std.math.add(u64, context.property_count.*, metrics.property_count) catch return error.RecordTooLarge;
            }
        }
    };
    var edge_context = EdgeCount{
        .owner_metrics = &owner_metrics,
        .property_value_bytes = &property_value_bytes,
        .property_count = &property_count,
    };
    const visible_edge_count = try store.scanVisibleEdgeIndexRecords(store.allocator, &edge_context, EdgeCount.visit);
    return refresh(store.allocator, store.io, store.dir_path, durable, .{
        .node_text_bytes = node_text_bytes,
        .property_value_bytes = property_value_bytes,
        .visible_edge_count = visible_edge_count,
        .node_count = node_count,
        .property_count = property_count,
    });
}

fn refresh(
    allocator: std.mem.Allocator,
    io: std.Io,
    store_path: []const u8,
    durable: bool,
    logical: LogicalContent,
) !Snapshot {
    const previous = read(allocator, io, store_path) catch |err| switch (err) {
        error.InvalidRecord => null,
        else => |e| return e,
    };
    var measured = try scanDirectory(allocator, io, store_path, true);
    // The scan deliberately excludes the old snapshot and its temporary
    // replacement. Account for the exact file that this refresh publishes.
    try measured.addFile(encoded_len);
    const timestamp = std.Io.Clock.real.now(io).nanoseconds;
    const generation = std.math.add(u64, if (previous) |value| value.generation else 0, 1) catch return error.RecordTooLarge;
    const snapshot = Snapshot{
        .logical_content_bytes = try logical.totalBytes(),
        .logical_node_text_bytes = logical.node_text_bytes,
        .logical_property_value_bytes = logical.property_value_bytes,
        .logical_edge_bytes = try logical.edgeBytes(),
        .physical_bytes = measured.physical_bytes,
        .regular_files = measured.regular_files,
        .node_count = logical.node_count,
        .property_count = logical.property_count,
        .visible_edge_count = logical.visible_edge_count,
        .generation = generation,
        .refreshed_ns = if (timestamp < 0) 0 else std.math.cast(u64, timestamp) orelse std.math.maxInt(u64),
    };
    try writeAtomic(allocator, io, store_path, snapshot, durable);
    return snapshot;
}

fn scanDirectory(allocator: std.mem.Allocator, io: std.Io, path: []const u8, is_root: bool) !Scan {
    var dir = try std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true });
    defer dir.close(io);
    var result: Scan = .{};
    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (is_root and excludedRootEntry(entry.name)) continue;
        const child_path = try std.fs.path.join(allocator, &.{ path, entry.name });
        defer allocator.free(child_path);
        switch (entry.kind) {
            .file => {
                const stat = try std.Io.Dir.cwd().statFile(io, child_path, .{});
                try result.addFile(stat.size);
            },
            .directory => {
                const child = try scanDirectory(allocator, io, child_path, false);
                result.physical_bytes = std.math.add(u64, result.physical_bytes, child.physical_bytes) catch return error.RecordTooLarge;
                result.regular_files = std.math.add(u64, result.regular_files, child.regular_files) catch return error.RecordTooLarge;
            },
            else => {},
        }
    }
    return result;
}

fn excludedRootEntry(name: []const u8) bool {
    if (std.mem.eql(u8, name, file_name) or std.mem.eql(u8, name, temporary_file_name)) return true;
    return std.mem.eql(u8, name, ".tinykg-cli.lock") or
        std.mem.eql(u8, name, ".tinykg-backup-transaction.json") or
        std.mem.eql(u8, name, ".tinykg-import-transaction.json") or
        std.mem.eql(u8, name, ".tinykg-restore-transaction.json") or
        std.mem.eql(u8, name, ".tinykg-migrate-store-v2-transaction.json") or
        std.mem.eql(u8, name, ".tinykg-schema-migrate-transaction") or
        std.mem.eql(u8, name, ".tinykg-backup-transaction.json.tmp") or
        std.mem.eql(u8, name, ".tinykg-import-transaction.json.tmp") or
        std.mem.eql(u8, name, ".tinykg-restore-transaction.json.tmp") or
        std.mem.eql(u8, name, ".tinykg-migrate-store-v2-transaction.json.tmp") or
        std.mem.eql(u8, name, ".tinykg-schema-migrate-transaction.tmp") or
        std.mem.eql(u8, name, ".tinykg-markdown-bootstrap-transaction") or
        std.mem.eql(u8, name, ".tinykg-markdown-bootstrap-transaction.tmp");
}

fn writeAtomic(allocator: std.mem.Allocator, io: std.Io, store_path: []const u8, snapshot: Snapshot, durable: bool) !void {
    const final_path = try std.fs.path.join(allocator, &.{ store_path, file_name });
    defer allocator.free(final_path);
    const temporary_path = try std.fs.path.join(allocator, &.{ store_path, temporary_file_name });
    defer allocator.free(temporary_path);
    errdefer std.Io.Dir.cwd().deleteFile(io, temporary_path) catch {};

    var bytes: [encoded_len]u8 = undefined;
    encode(snapshot, &bytes);
    {
        var file = try std.Io.Dir.cwd().createFile(io, temporary_path, .{ .read = true, .truncate = true });
        defer file.close(io);
        try file.writePositionalAll(io, &bytes, 0);
        if (durable) try file.sync(io);
    }
    if (std.fs.path.isAbsolute(temporary_path)) {
        try std.Io.Dir.renameAbsolute(temporary_path, final_path, io);
    } else {
        try std.Io.Dir.rename(.cwd(), temporary_path, .cwd(), final_path, io);
    }
    if (durable and @import("builtin").os.tag != .windows) {
        var dir_file = if (std.fs.path.isAbsolute(store_path))
            try std.Io.Dir.openFileAbsolute(io, store_path, .{ .allow_directory = true })
        else
            try std.Io.Dir.cwd().openFile(io, store_path, .{ .allow_directory = true });
        defer dir_file.close(io);
        try dir_file.sync(io);
    }
}

fn checksum(bytes: []const u8) u64 {
    return std.hash.Wyhash.hash(0x544b4753, bytes);
}

test "store size metadata codec rejects corruption" {
    const snapshot = Snapshot{
        .logical_content_bytes = 103,
        .logical_node_text_bytes = 71,
        .logical_property_value_bytes = 16,
        .logical_edge_bytes = 16,
        .physical_bytes = 4096,
        .regular_files = 7,
        .node_count = 2,
        .property_count = 2,
        .visible_edge_count = 1,
        .generation = 3,
        .refreshed_ns = 11,
    };
    var bytes: [encoded_len]u8 = undefined;
    encode(snapshot, &bytes);
    try std.testing.expectEqualDeep(snapshot, try decode(&bytes));
    bytes[16] ^= 1;
    try std.testing.expectError(error.InvalidRecord, decode(&bytes));
}

test "store size refresh measures nested files and replaces a corrupt snapshot" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try temporary.dir.realPath(std.testing.io, &path_buffer);
    const root_path = path_buffer[0..root_len];
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "events.bin", .data = "12345" });
    try temporary.dir.createDir(std.testing.io, "segments", .default_dir);
    var segments = try temporary.dir.openDir(std.testing.io, "segments", .{});
    defer segments.close(std.testing.io);
    try segments.writeFile(std.testing.io, .{ .sub_path = "one", .data = "123" });

    const logical = LogicalContent{
        .node_text_bytes = 11,
        .property_value_bytes = 8,
        .visible_edge_count = 2,
        .node_count = 1,
        .property_count = 1,
    };
    const first = try refresh(std.testing.allocator, std.testing.io, root_path, false, logical);
    try std.testing.expectEqual(@as(u64, 5 + 3 + encoded_len), first.physical_bytes);
    try std.testing.expectEqual(@as(u64, 3), first.regular_files);
    try std.testing.expectEqual(@as(u64, 11 + 8 + 2 * logical_edge_bytes_per_edge), first.logical_content_bytes);
    try std.testing.expectEqual(@as(u64, 1), first.generation);
    try std.testing.expectEqualDeep(first, (try read(std.testing.allocator, std.testing.io, root_path)).?);

    var corrupt = try temporary.dir.openFile(std.testing.io, file_name, .{ .mode = .read_write });
    defer corrupt.close(std.testing.io);
    try corrupt.writePositionalAll(std.testing.io, &.{0}, 0);
    const repaired = try refresh(std.testing.allocator, std.testing.io, root_path, false, logical);
    try std.testing.expectEqual(@as(u64, 1), repaired.generation);
    try std.testing.expectEqual(@as(u64, 5 + 3 + encoded_len), repaired.physical_bytes);
}
