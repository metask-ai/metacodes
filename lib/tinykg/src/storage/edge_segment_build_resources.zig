const std = @import("std");

/// Owns temporary edge-segment build artifacts and edge-id sidecar run
/// readers. Publication, manifest mutation, compaction policy, and GC remain
/// in their existing owners.
pub fn EdgeSegmentBuildResources(comptime Ops: type) type {
    const Store = Ops.dep_Store;
    const support = Ops.dep_support;
    const segment_mod = Ops.dep_segment_mod;

    return struct {
        pub const EdgeAppendTailSpool = struct {
            path: ?[]u8 = null,
            count: usize = 0,
            digest: u64 = 0,
            nonce: u64 = 0,

            pub fn deinit(self: *EdgeAppendTailSpool, store: Store) void {
                if (self.path) |path| {
                    std.Io.Dir.cwd().deleteFile(store.io, path) catch {};
                    store.allocator.free(path);
                    self.path = null;
                }
                self.count = 0;
                self.digest = 0;
                self.nonce = 0;
            }
        };

        pub const EdgeSortedRunSet = struct {
            allocator: std.mem.Allocator,
            store: Store,
            paths: std.ArrayList([]u8) = .empty,

            pub fn deinit(self: *EdgeSortedRunSet) void {
                for (self.paths.items) |path| {
                    std.Io.Dir.cwd().deleteFile(self.store.io, path) catch {};
                    self.allocator.free(path);
                }
                self.paths.deinit(self.allocator);
            }
        };

        pub const EdgeSegmentIdIndexSummary = struct {
            edge_digest: u64,
            edge_id_summary: segment_mod.ImmutableAdjacencySegment.EdgeIdSummary,
            endpoint_summary: segment_mod.ImmutableAdjacencySegment.EndpointSummary,
            edge_id_order_digest: u64,
            edge_id_runs: support.EdgeSegmentIdRunSummary,
        };

        pub const EdgeSegmentIdRunSet = struct {
            allocator: std.mem.Allocator,
            store: Store,
            paths: std.ArrayList([]u8) = .empty,

            pub fn deinit(self: *EdgeSegmentIdRunSet) void {
                for (self.paths.items) |path| {
                    std.Io.Dir.cwd().deleteFile(self.store.io, path) catch {};
                    self.allocator.free(path);
                }
                self.paths.deinit(self.allocator);
            }
        };

        pub const EdgeSegmentIdIndexRunReader = struct {
            file: ?std.Io.File = null,
            map: ?std.Io.File.MemoryMap = null,
            base_offset: u64 = support.EdgeSegmentIdIndex.header_len,
            next_index: u64,
            count: u64,
            buffer: []u8 = &.{},
            file_offset: u64 = support.EdgeSegmentIdIndex.header_len,
            cursor: usize = 0,
            len: usize = 0,
            synthetic_runs: support.EdgeSegmentIdRunSummary = .{},
            synthetic_next: u64 = 0,

            pub fn initSynthetic(runs: support.EdgeSegmentIdRunSummary, expected_count: u64) !EdgeSegmentIdIndexRunReader {
                try runs.validate();
                if (runs.run_count == 0) return error.InvalidRecord;
                if (try runs.coveredCount() != expected_count) return error.InvalidRecord;
                return .{
                    .next_index = 0,
                    .count = expected_count,
                    .synthetic_runs = runs,
                    .synthetic_next = runs.first_min,
                };
            }

            pub fn deinit(self: *EdgeSegmentIdIndexRunReader, allocator: std.mem.Allocator, io: std.Io) void {
                allocator.free(self.buffer);
                if (self.map) |*map| map.destroy(io);
                if (self.file) |file| file.close(io);
            }

            fn refill(self: *EdgeSegmentIdIndexRunReader, store: Store) !void {
                const file = self.file orelse return error.InvalidRecord;
                const n = try file.readPositionalAll(store.io, self.buffer, self.file_offset);
                if (n == 0) return error.InvalidRecord;
                self.file_offset = std.math.add(u64, self.file_offset, n) catch return error.InvalidRecord;
                self.cursor = 0;
                self.len = n;
            }

            fn readBytes(self: *EdgeSegmentIdIndexRunReader, store: Store, out: []u8) !void {
                var written: usize = 0;
                while (written < out.len) {
                    if (self.cursor == self.len) try self.refill(store);
                    const available = self.len - self.cursor;
                    const n = @min(available, out.len - written);
                    @memcpy(out[written .. written + n], self.buffer[self.cursor .. self.cursor + n]);
                    self.cursor += n;
                    written += n;
                }
            }

            pub fn next(self: *EdgeSegmentIdIndexRunReader, store: Store) !?u64 {
                if (self.next_index >= self.count) return null;
                if (self.synthetic_runs.run_count != 0) return try self.nextSynthetic();
                const edge_id = if (self.map) |*map| id: {
                    const byte_index = std.math.mul(u64, self.next_index, 8) catch return error.RecordTooLarge;
                    const offset = std.math.add(u64, self.base_offset, byte_index) catch return error.RecordTooLarge;
                    const start = std.math.cast(usize, offset) orelse return error.RecordTooLarge;
                    const end = std.math.add(usize, start, 8) catch return error.InvalidRecord;
                    if (end > map.memory.len) return error.InvalidRecord;
                    break :id std.mem.readInt(u64, map.memory[start..end][0..8], .little);
                } else id: {
                    if (self.cursor == self.len) try self.refill(store);
                    if (self.len - self.cursor >= 8) {
                        var id_bytes: [8]u8 = undefined;
                        @memcpy(&id_bytes, self.buffer[self.cursor .. self.cursor + 8]);
                        self.cursor += 8;
                        break :id std.mem.readInt(u64, &id_bytes, .little);
                    }
                    var id_bytes: [8]u8 = undefined;
                    try self.readBytes(store, &id_bytes);
                    break :id std.mem.readInt(u64, &id_bytes, .little);
                };
                self.next_index += 1;
                return edge_id;
            }

            fn nextSynthetic(self: *EdgeSegmentIdIndexRunReader) !?u64 {
                if (self.next_index >= self.count) return null;
                const runs = self.synthetic_runs;
                if (runs.run_count == 0) return error.InvalidRecord;
                const edge_id = self.synthetic_next;
                if (edge_id == 0 or edge_id == std.math.maxInt(u64)) return error.InvalidRecord;
                if (edge_id >= runs.first_min and edge_id <= runs.first_max) {
                    if (edge_id == runs.first_max and runs.run_count == 2) {
                        self.synthetic_next = runs.second_min;
                    } else if (edge_id != runs.first_max) {
                        self.synthetic_next = edge_id + 1;
                    }
                } else if (runs.run_count == 2 and edge_id >= runs.second_min and edge_id <= runs.second_max) {
                    if (edge_id != runs.second_max) self.synthetic_next = edge_id + 1;
                } else {
                    return error.InvalidRecord;
                }
                self.next_index += 1;
                return edge_id;
            }
        };

        pub const EdgeSegmentIdIndexRunHeapEntry = struct {
            run_index: usize,
            edge_id: u64,
        };
    };
}

const TestRunSummary = struct {
    run_count: u8 = 0,
    first_min: u64 = 0,
    first_max: u64 = 0,
    second_min: u64 = 0,
    second_max: u64 = 0,

    pub fn validate(self: @This()) !void {
        if (self.run_count == 0) return;
        if (self.run_count > 2 or self.first_min == 0 or self.first_min > self.first_max) return error.InvalidRecord;
        if (self.run_count == 2 and (self.second_min <= self.first_max or self.second_min > self.second_max)) return error.InvalidRecord;
    }

    pub fn coveredCount(self: @This()) !u64 {
        try self.validate();
        if (self.run_count == 0) return 0;
        var count = self.first_max - self.first_min + 1;
        if (self.run_count == 2) count = try std.math.add(u64, count, self.second_max - self.second_min + 1);
        return count;
    }
};

const TestSupport = struct {
    pub const EdgeSegmentIdIndex = struct {
        pub const header_len: u64 = 0;
    };
    pub const EdgeSegmentIdRunSummary = TestRunSummary;
};

const TestSegment = struct {
    pub const ImmutableAdjacencySegment = struct {
        pub const EdgeIdSummary = struct { min: u64 = 0, max: u64 = 0 };
        pub const EndpointSummary = struct { min: u64 = 0, max: u64 = 0 };
    };
};

const TestStore = struct {
    allocator: std.mem.Allocator = std.testing.allocator,
    io: std.Io = std.testing.io,
};

const TestOps = struct {
    pub const dep_Store = TestStore;
    pub const dep_support = TestSupport;
    pub const dep_segment_mod = TestSegment;
};

const TestResources = EdgeSegmentBuildResources(TestOps);

fn testPath(allocator: std.mem.Allocator, dir: std.Io.Dir, name: []const u8) ![]u8 {
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try dir.realPath(std.testing.io, &path_buf);
    return std.fs.path.join(allocator, &.{ path_buf[0..root_len], name });
}

test "edge segment tail spool cleanup is idempotent" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try testPath(std.testing.allocator, tmp.dir, "tail.spool");
    const check_path = try std.testing.allocator.dupe(u8, path);
    defer std.testing.allocator.free(check_path);
    var file = try std.Io.Dir.cwd().createFile(std.testing.io, path, .{});
    file.close(std.testing.io);
    var spool = TestResources.EdgeAppendTailSpool{
        .path = path,
        .count = 3,
        .digest = 7,
        .nonce = 9,
    };
    spool.deinit(.{});
    spool.deinit(.{});
    try std.testing.expect(spool.path == null);
    try std.testing.expectEqual(@as(usize, 0), spool.count);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().openFile(std.testing.io, check_path, .{}));
}

test "edge segment sorted run cleanup releases every owned path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const first = try testPath(std.testing.allocator, tmp.dir, "first.run");
    const second = try testPath(std.testing.allocator, tmp.dir, "second.run");
    const first_check = try std.testing.allocator.dupe(u8, first);
    defer std.testing.allocator.free(first_check);
    const second_check = try std.testing.allocator.dupe(u8, second);
    defer std.testing.allocator.free(second_check);
    for ([_][]const u8{ first, second }) |path| {
        var file = try std.Io.Dir.cwd().createFile(std.testing.io, path, .{});
        file.close(std.testing.io);
    }
    var runs = TestResources.EdgeSortedRunSet{ .allocator = std.testing.allocator, .store = .{} };
    try runs.paths.append(std.testing.allocator, first);
    try runs.paths.append(std.testing.allocator, second);
    runs.deinit();
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().openFile(std.testing.io, first_check, .{}));
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().openFile(std.testing.io, second_check, .{}));
}

test "edge segment synthetic id reader streams one and two runs" {
    var reader = try TestResources.EdgeSegmentIdIndexRunReader.initSynthetic(.{
        .run_count = 2,
        .first_min = 1,
        .first_max = 2,
        .second_min = 5,
        .second_max = 6,
    }, 4);
    try std.testing.expectEqual(@as(u64, 1), (try reader.next(.{})).?);
    try std.testing.expectEqual(@as(u64, 2), (try reader.next(.{})).?);
    try std.testing.expectEqual(@as(u64, 5), (try reader.next(.{})).?);
    try std.testing.expectEqual(@as(u64, 6), (try reader.next(.{})).?);
    try std.testing.expect((try reader.next(.{})) == null);
}

test "edge segment synthetic id reader rejects malformed coverage" {
    try std.testing.expectError(
        error.InvalidRecord,
        TestResources.EdgeSegmentIdIndexRunReader.initSynthetic(.{
            .run_count = 2,
            .first_min = 1,
            .first_max = 2,
            .second_min = 5,
            .second_max = 6,
        }, 3),
    );
    try std.testing.expectError(
        error.InvalidRecord,
        TestResources.EdgeSegmentIdIndexRunReader.initSynthetic(.{
            .run_count = 2,
            .first_min = 1,
            .first_max = 3,
            .second_min = 3,
            .second_max = 4,
        }, 5),
    );
}

test "edge segment id run reader rejects truncated buffered input" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try testPath(std.testing.allocator, tmp.dir, "ids.bin");
    defer std.testing.allocator.free(path);
    var file = try std.Io.Dir.cwd().createFile(std.testing.io, path, .{ .read = true, .truncate = true });
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, 7, .little);
    try file.writePositionalAll(std.testing.io, &bytes, 0);
    const buffer = try std.testing.allocator.alloc(u8, 3);
    var reader = TestResources.EdgeSegmentIdIndexRunReader{
        .file = file,
        .next_index = 0,
        .count = 2,
        .buffer = buffer,
    };
    defer reader.deinit(std.testing.allocator, std.testing.io);
    try std.testing.expectEqual(@as(u64, 7), (try reader.next(.{})).?);
    try std.testing.expectError(error.InvalidRecord, reader.next(.{}));
}
