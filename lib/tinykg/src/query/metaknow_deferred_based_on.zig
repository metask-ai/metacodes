const std = @import("std");

/// Owns the persisted deferred `based_on` sidecar layout, bounded lookup, and
/// projection into the query layer's stable edge representation.
pub fn MetaknowDeferredBasedOn(
    comptime core: type,
    comptime index: type,
    comptime storage: type,
) type {
    return struct {
        pub const metaknow_deferred_based_on_file = "metaknow_deferred_based_on.bin";
        pub const metaknow_deferred_based_on_magic = [_]u8{ 'T', 'K', 'D', 'B', 'O', 'N', '3', '\n' };
        pub const metaknow_deferred_based_on_header_len: usize = 80;
        pub const metaknow_deferred_based_on_index_record_len: usize = 12;
        pub const metaknow_deferred_based_on_target_record_len: usize = 4;
        pub const metaknow_deferred_based_on_edge_id_base: u64 = 1_000_000_000_000;

        pub const MetaknowDeferredBasedOnDirection = enum {
            forward,
            reverse,
        };

        pub const MetaknowDeferredBasedOnQueryResult = struct {
            targets: []u64 = &.{},
            edge_id_base: u64 = 0,
            target_start: u64 = 0,
            total_count: usize = 0,

            pub fn deinit(self: *MetaknowDeferredBasedOnQueryResult, allocator: std.mem.Allocator) void {
                if (self.targets.len != 0) allocator.free(self.targets);
            }
        };

        const MetaknowDeferredBasedOnIndexRecord = struct {
            source: u64,
            target_start: u64,
            count: u64,
        };

        pub fn metaknowDeferredBasedOnPath(allocator: std.mem.Allocator, store: storage.Store) ![]u8 {
            return std.fs.path.join(allocator, &.{ store.dir_path, metaknow_deferred_based_on_file });
        }

        pub fn readMetaknowDeferredBasedOnTargets(
            allocator: std.mem.Allocator,
            io: std.Io,
            sidecar_path: []const u8,
            node_id: core.NodeId,
            max_results: usize,
            direction: MetaknowDeferredBasedOnDirection,
        ) !MetaknowDeferredBasedOnQueryResult {
            const stat = std.Io.Dir.cwd().statFile(io, sidecar_path, .{}) catch |err| switch (err) {
                error.FileNotFound => return .{},
                else => |e| return e,
            };
            if (stat.kind != .file or stat.size < metaknow_deferred_based_on_header_len) return error.InvalidRecord;
            var file = try std.Io.Dir.cwd().openFile(io, sidecar_path, .{});
            defer file.close(io);

            var header: [metaknow_deferred_based_on_header_len]u8 = undefined;
            if (try file.readPositionalAll(io, &header, 0) != header.len) return error.InvalidRecord;
            if (!std.mem.eql(u8, header[0..8], &metaknow_deferred_based_on_magic)) return error.InvalidRecord;
            const forward_source_count = std.mem.readInt(u64, header[8..16], .little);
            const forward_link_count = std.mem.readInt(u64, header[16..24], .little);
            const forward_target_offset = std.mem.readInt(u64, header[24..32], .little);
            const edge_id_base = std.mem.readInt(u64, header[32..40], .little);
            const reverse_source_count = std.mem.readInt(u64, header[48..56], .little);
            const reverse_link_count = std.mem.readInt(u64, header[56..64], .little);
            const reverse_target_offset = std.mem.readInt(u64, header[64..72], .little);

            const forward_index_bytes = try std.math.mul(u64, forward_source_count, metaknow_deferred_based_on_index_record_len);
            const forward_target_bytes = try std.math.mul(u64, forward_link_count, metaknow_deferred_based_on_target_record_len);
            const reverse_index_bytes = try std.math.mul(u64, reverse_source_count, metaknow_deferred_based_on_index_record_len);
            const reverse_target_bytes = try std.math.mul(u64, reverse_link_count, metaknow_deferred_based_on_target_record_len);
            const expected_forward_target_offset = try std.math.add(u64, metaknow_deferred_based_on_header_len, forward_index_bytes);
            if (forward_target_offset != expected_forward_target_offset) return error.InvalidRecord;
            const reverse_index_offset = try std.math.add(u64, forward_target_offset, forward_target_bytes);
            const expected_reverse_target_offset = try std.math.add(u64, reverse_index_offset, reverse_index_bytes);
            if (reverse_target_offset != expected_reverse_target_offset) return error.InvalidRecord;
            const expected_size = try std.math.add(u64, reverse_target_offset, reverse_target_bytes);
            if (stat.size != expected_size) return error.InvalidRecord;

            const source_count = switch (direction) {
                .forward => forward_source_count,
                .reverse => reverse_source_count,
            };
            const link_count = switch (direction) {
                .forward => forward_link_count,
                .reverse => reverse_link_count,
            };
            const index_offset = switch (direction) {
                .forward => @as(u64, metaknow_deferred_based_on_header_len),
                .reverse => reverse_index_offset,
            };
            const target_offset = switch (direction) {
                .forward => forward_target_offset,
                .reverse => reverse_target_offset,
            };
            const result_edge_id_base = switch (direction) {
                .forward => edge_id_base,
                .reverse => try std.math.add(u64, edge_id_base, forward_link_count),
            };
            if (source_count > std.math.maxInt(usize)) return error.RecordTooLarge;

            const source_count_usize: usize = @intCast(source_count);
            const wanted = node_id.toInt();
            var low: usize = 0;
            var high: usize = source_count_usize;
            while (low < high) {
                const mid = low + (high - low) / 2;
                const record = try readMetaknowDeferredBasedOnIndexRecord(&file, io, index_offset, mid);
                if (record.source < wanted) {
                    low = mid + 1;
                } else {
                    high = mid;
                }
            }
            if (low >= source_count_usize) return .{};
            const found = try readMetaknowDeferredBasedOnIndexRecord(&file, io, index_offset, low);
            if (found.source != wanted) return .{};
            const target_start = found.target_start;
            const total_count_u64 = found.count;
            if (target_start > link_count or total_count_u64 > link_count - target_start) return error.InvalidRecord;
            const total_count: usize = @intCast(total_count_u64);
            const take = @min(max_results, total_count);
            const targets = try allocator.alloc(u64, take);
            errdefer allocator.free(targets);
            const targets_bytes_len = try std.math.mul(usize, take, metaknow_deferred_based_on_target_record_len);
            const targets_bytes = try allocator.alloc(u8, targets_bytes_len);
            defer allocator.free(targets_bytes);
            const target_read_offset = try std.math.add(u64, target_offset, try std.math.mul(u64, target_start, metaknow_deferred_based_on_target_record_len));
            if (targets_bytes_len != 0 and try file.readPositionalAll(io, targets_bytes, target_read_offset) != targets_bytes_len) return error.InvalidRecord;
            for (targets, 0..) |*target, index_pos| {
                target.* = std.mem.readInt(u32, targets_bytes[index_pos * metaknow_deferred_based_on_target_record_len ..][0..4], .little);
            }
            return .{
                .targets = targets,
                .edge_id_base = result_edge_id_base,
                .target_start = target_start,
                .total_count = total_count,
            };
        }

        pub fn forEachEdgeRef(
            allocator: std.mem.Allocator,
            store: storage.Store,
            order: storage.EdgeIndexOrder,
            node_id: core.NodeId,
            context: anytype,
            comptime callback: fn (@TypeOf(context), index.EdgeRef) anyerror!bool,
        ) !bool {
            const direction: MetaknowDeferredBasedOnDirection = switch (order) {
                .src => .forward,
                .dst => .reverse,
                .id => return core.Error.Unsupported,
            };
            const sidecar_path = try metaknowDeferredBasedOnPath(allocator, store);
            defer allocator.free(sidecar_path);
            var deferred = try readMetaknowDeferredBasedOnTargets(allocator, store.io, sidecar_path, node_id, (core.QueryBudget{}).max_visited_edges, direction);
            defer deferred.deinit(allocator);
            if (deferred.total_count > deferred.targets.len) return core.Error.BudgetExceeded;
            for (deferred.targets, 0..) |target, index_pos| {
                const target_id = core.NodeId.fromInt(target);
                const edge_id = core.EdgeId.fromInt(deferred.edge_id_base + deferred.target_start + index_pos + 1);
                const edge: index.EdgeRef = switch (direction) {
                    .forward => .{ .src = node_id, .dst = target_id, .edge_id = edge_id, .rel = .based_on },
                    .reverse => .{ .src = target_id, .dst = node_id, .edge_id = edge_id, .rel = .based_on },
                };
                if (try callback(context, edge)) return true;
            }
            return false;
        }

        fn readMetaknowDeferredBasedOnIndexRecord(file: *std.Io.File, io: std.Io, index_offset: u64, index_pos: usize) !MetaknowDeferredBasedOnIndexRecord {
            const record_byte_offset = try std.math.add(
                u64,
                index_offset,
                try std.math.mul(u64, @intCast(index_pos), metaknow_deferred_based_on_index_record_len),
            );
            var bytes: [metaknow_deferred_based_on_index_record_len]u8 = undefined;
            if (try file.readPositionalAll(io, &bytes, record_byte_offset) != bytes.len) return error.InvalidRecord;
            return .{
                .source = std.mem.readInt(u32, bytes[0..4], .little),
                .target_start = std.mem.readInt(u32, bytes[4..8], .little),
                .count = std.mem.readInt(u32, bytes[8..12], .little),
            };
        }
    };
}

const TestNodeId = struct {
    value: u64,

    fn fromInt(value: u64) TestNodeId {
        return .{ .value = value };
    }

    fn toInt(self: TestNodeId) u64 {
        return self.value;
    }
};

const TestEdgeId = struct {
    value: u64,

    fn fromInt(value: u64) TestEdgeId {
        return .{ .value = value };
    }

    fn toInt(self: TestEdgeId) u64 {
        return self.value;
    }
};

const TestCore = struct {
    const NodeId = TestNodeId;
    const EdgeId = TestEdgeId;
    const RelKind = enum { based_on };
    const Error = error{ Unsupported, BudgetExceeded };
    const QueryBudget = struct {
        max_visited_edges: usize = 64,
    };
};

const TestIndex = struct {
    const EdgeRef = struct {
        src: TestNodeId,
        dst: TestNodeId,
        edge_id: TestEdgeId,
        rel: TestCore.RelKind,
    };
};

const TestStorage = struct {
    const EdgeIndexOrder = enum { id, src, dst };
    const Store = struct {
        dir_path: []const u8,
        io: std.Io,
    };
};

const TestDeferredBasedOn = MetaknowDeferredBasedOn(TestCore, TestIndex, TestStorage);

fn testSidecarPath(dir: std.Io.Dir, path_buf: []u8) ![]u8 {
    const root_len = try dir.realPath(std.testing.io, path_buf);
    return std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], TestDeferredBasedOn.metaknow_deferred_based_on_file });
}

fn writeTestIndexRecord(bytes: []u8, index_offset: usize, index_pos: usize, source: u32, target_start: u32, count: u32) void {
    const record_offset = index_offset + index_pos * TestDeferredBasedOn.metaknow_deferred_based_on_index_record_len;
    std.mem.writeInt(u32, bytes[record_offset..][0..4], source, .little);
    std.mem.writeInt(u32, bytes[record_offset + 4 ..][0..4], target_start, .little);
    std.mem.writeInt(u32, bytes[record_offset + 8 ..][0..4], count, .little);
}

fn writeTestTarget(bytes: []u8, target_offset: usize, target_pos: usize, target: u32) void {
    const record_offset = target_offset + target_pos * TestDeferredBasedOn.metaknow_deferred_based_on_target_record_len;
    std.mem.writeInt(u32, bytes[record_offset..][0..4], target, .little);
}

fn writeTestSidecar(sidecar_path: []const u8) !void {
    const forward_source_count: usize = 2;
    const forward_link_count: usize = 3;
    const reverse_source_count: usize = 3;
    const reverse_link_count: usize = 3;
    const forward_target_offset = TestDeferredBasedOn.metaknow_deferred_based_on_header_len + forward_source_count * TestDeferredBasedOn.metaknow_deferred_based_on_index_record_len;
    const reverse_index_offset = forward_target_offset + forward_link_count * TestDeferredBasedOn.metaknow_deferred_based_on_target_record_len;
    const reverse_target_offset = reverse_index_offset + reverse_source_count * TestDeferredBasedOn.metaknow_deferred_based_on_index_record_len;
    const total_bytes = reverse_target_offset + reverse_link_count * TestDeferredBasedOn.metaknow_deferred_based_on_target_record_len;
    var bytes: [total_bytes]u8 = @splat(0);

    @memcpy(bytes[0..8], &TestDeferredBasedOn.metaknow_deferred_based_on_magic);
    std.mem.writeInt(u64, bytes[8..16], forward_source_count, .little);
    std.mem.writeInt(u64, bytes[16..24], forward_link_count, .little);
    std.mem.writeInt(u64, bytes[24..32], forward_target_offset, .little);
    std.mem.writeInt(u64, bytes[32..40], TestDeferredBasedOn.metaknow_deferred_based_on_edge_id_base, .little);
    std.mem.writeInt(u64, bytes[48..56], reverse_source_count, .little);
    std.mem.writeInt(u64, bytes[56..64], reverse_link_count, .little);
    std.mem.writeInt(u64, bytes[64..72], reverse_target_offset, .little);

    writeTestIndexRecord(&bytes, TestDeferredBasedOn.metaknow_deferred_based_on_header_len, 0, 11, 0, 2);
    writeTestIndexRecord(&bytes, TestDeferredBasedOn.metaknow_deferred_based_on_header_len, 1, 12, 2, 1);
    writeTestTarget(&bytes, forward_target_offset, 0, 21);
    writeTestTarget(&bytes, forward_target_offset, 1, 22);
    writeTestTarget(&bytes, forward_target_offset, 2, 23);

    writeTestIndexRecord(&bytes, reverse_index_offset, 0, 21, 0, 1);
    writeTestIndexRecord(&bytes, reverse_index_offset, 1, 22, 1, 1);
    writeTestIndexRecord(&bytes, reverse_index_offset, 2, 23, 2, 1);
    writeTestTarget(&bytes, reverse_target_offset, 0, 11);
    writeTestTarget(&bytes, reverse_target_offset, 1, 11);
    writeTestTarget(&bytes, reverse_target_offset, 2, 12);

    var file = try std.Io.Dir.cwd().createFile(std.testing.io, sidecar_path, .{ .truncate = true });
    defer file.close(std.testing.io);
    try file.writePositionalAll(std.testing.io, &bytes, 0);
}

test "deferred based_on reader resolves store path under owned root" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const store: TestStorage.Store = .{ .dir_path = path_buf[0..root_len], .io = std.testing.io };
    const actual = try TestDeferredBasedOn.metaknowDeferredBasedOnPath(std.testing.allocator, store);
    defer std.testing.allocator.free(actual);
    const expected = try std.fs.path.join(std.testing.allocator, &.{ store.dir_path, TestDeferredBasedOn.metaknow_deferred_based_on_file });
    defer std.testing.allocator.free(expected);

    try std.testing.expectEqualStrings(expected, actual);
}

test "deferred based_on reader reads one bounded forward source" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const sidecar_path = try testSidecarPath(tmp.dir, &path_buf);
    defer std.testing.allocator.free(sidecar_path);
    try writeTestSidecar(sidecar_path);

    var fixed_bytes: [128]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&fixed_bytes);
    var result = try TestDeferredBasedOn.readMetaknowDeferredBasedOnTargets(fixed.allocator(), std.testing.io, sidecar_path, .fromInt(12), 1, .forward);
    defer result.deinit(fixed.allocator());

    try std.testing.expectEqual(@as(usize, 1), result.targets.len);
    try std.testing.expectEqual(@as(usize, 1), result.total_count);
    try std.testing.expectEqual(@as(u64, 2), result.target_start);
    try std.testing.expectEqual(@as(u64, 23), result.targets[0]);
}

test "deferred based_on reader preserves reverse edge id range" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const sidecar_path = try testSidecarPath(tmp.dir, &path_buf);
    defer std.testing.allocator.free(sidecar_path);
    try writeTestSidecar(sidecar_path);

    var result = try TestDeferredBasedOn.readMetaknowDeferredBasedOnTargets(std.testing.allocator, std.testing.io, sidecar_path, .fromInt(22), 8, .reverse);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u64, TestDeferredBasedOn.metaknow_deferred_based_on_edge_id_base + 3), result.edge_id_base);
    try std.testing.expectEqual(@as(u64, 1), result.target_start);
    try std.testing.expectEqual(@as(u64, 11), result.targets[0]);
}

test "deferred based_on reader reports total count beyond limit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const sidecar_path = try testSidecarPath(tmp.dir, &path_buf);
    defer std.testing.allocator.free(sidecar_path);
    try writeTestSidecar(sidecar_path);

    var result = try TestDeferredBasedOn.readMetaknowDeferredBasedOnTargets(std.testing.allocator, std.testing.io, sidecar_path, .fromInt(11), 1, .forward);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), result.targets.len);
    try std.testing.expectEqual(@as(usize, 2), result.total_count);
    try std.testing.expectEqual(@as(u64, 21), result.targets[0]);
}

test "deferred based_on reader treats a missing sidecar as empty" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const sidecar_path = try testSidecarPath(tmp.dir, &path_buf);
    defer std.testing.allocator.free(sidecar_path);
    var result = try TestDeferredBasedOn.readMetaknowDeferredBasedOnTargets(std.testing.allocator, std.testing.io, sidecar_path, .fromInt(11), 8, .forward);
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), result.targets.len);
    try std.testing.expectEqual(@as(usize, 0), result.total_count);
}

test "deferred based_on reader rejects corrupt identity and layout" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const sidecar_path = try testSidecarPath(tmp.dir, &path_buf);
    defer std.testing.allocator.free(sidecar_path);
    try writeTestSidecar(sidecar_path);

    {
        var file = try std.Io.Dir.cwd().openFile(std.testing.io, sidecar_path, .{ .mode = .read_write });
        defer file.close(std.testing.io);
        try file.writePositionalAll(std.testing.io, "X", 0);
    }
    try std.testing.expectError(error.InvalidRecord, TestDeferredBasedOn.readMetaknowDeferredBasedOnTargets(std.testing.allocator, std.testing.io, sidecar_path, .fromInt(11), 8, .forward));

    try writeTestSidecar(sidecar_path);
    var invalid_offset: [8]u8 = undefined;
    std.mem.writeInt(u64, &invalid_offset, 0, .little);
    {
        var file = try std.Io.Dir.cwd().openFile(std.testing.io, sidecar_path, .{ .mode = .read_write });
        defer file.close(std.testing.io);
        try file.writePositionalAll(std.testing.io, &invalid_offset, 24);
    }
    try std.testing.expectError(error.InvalidRecord, TestDeferredBasedOn.readMetaknowDeferredBasedOnTargets(std.testing.allocator, std.testing.io, sidecar_path, .fromInt(11), 8, .forward));
}

test "deferred based_on projection emits stable edges and stops at callback" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const sidecar_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], TestDeferredBasedOn.metaknow_deferred_based_on_file });
    defer std.testing.allocator.free(sidecar_path);
    try writeTestSidecar(sidecar_path);

    var edges = std.ArrayList(TestIndex.EdgeRef).empty;
    defer edges.deinit(std.testing.allocator);
    const Context = struct {
        edges: *std.ArrayList(TestIndex.EdgeRef),

        fn visit(context: *@This(), edge: TestIndex.EdgeRef) !bool {
            try context.edges.append(std.testing.allocator, edge);
            return true;
        }
    };
    var context: Context = .{ .edges = &edges };
    const stopped = try TestDeferredBasedOn.forEachEdgeRef(
        std.testing.allocator,
        .{ .dir_path = path_buf[0..root_len], .io = std.testing.io },
        .src,
        .fromInt(11),
        &context,
        Context.visit,
    );

    try std.testing.expect(stopped);
    try std.testing.expectEqual(@as(usize, 1), edges.items.len);
    try std.testing.expectEqual(@as(u64, 11), edges.items[0].src.toInt());
    try std.testing.expectEqual(@as(u64, 21), edges.items[0].dst.toInt());
    try std.testing.expectEqual(TestDeferredBasedOn.metaknow_deferred_based_on_edge_id_base + 1, edges.items[0].edge_id.toInt());
    try std.testing.expectEqual(TestCore.RelKind.based_on, edges.items[0].rel);
}
