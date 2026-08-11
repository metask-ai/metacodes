const std = @import("std");

/// Owns edge-index and tombstone read views, bounded public iterators, and the
/// two sequential record readers used by repair/merge paths. Persisted codecs
/// and concrete Store I/O are injected by the Storage root.
pub fn EdgeIndexReadViews(comptime Ops: type) type {
    const Store = Ops.dep_Store;
    const core = Ops.dep_core;
    const support = Ops.dep_support;
    const EdgeIndexHeader = Ops.dep_EdgeIndexHeader;
    const EdgeIndexOrder = Ops.dep_EdgeIndexOrder;
    const EdgeIndexRecord = Ops.dep_EdgeIndexRecord;

    return struct {
        pub const EdgeTombstoneIndexView = struct {
            store: Store,
            file: std.Io.File,
            map: ?std.Io.File.MemoryMap = null,
            count: u64,

            pub fn open(store: Store) !EdgeTombstoneIndexView {
                var file = try std.Io.Dir.cwd().openFile(store.io, store.edge_tombstones_path, .{});
                errdefer file.close(store.io);
                const header = try Ops.readEdgeTombstoneHeaderFromFile(store, file);
                const expected_size = try support.edgeTombstoneFileSize(header.count);
                if (try Ops.regularFileSize(store, file) != expected_size) return error.InvalidRecord;
                var map = Ops.openReadOnlyMemoryMap(store.io, file, expected_size) catch null;
                errdefer if (map) |*mapped| mapped.destroy(store.io);
                return .{
                    .store = store,
                    .file = file,
                    .map = map,
                    .count = header.count,
                };
            }

            pub fn deinit(self: *EdgeTombstoneIndexView) void {
                if (self.map) |*map| map.destroy(self.store.io);
                self.file.close(self.store.io);
            }

            pub fn contains(self: *EdgeTombstoneIndexView, edge_id: u64) !bool {
                var lo: u64 = 0;
                var hi: u64 = self.count;
                while (lo < hi) {
                    const mid = lo + (hi - lo) / 2;
                    const record = try self.readRecordAt(mid);
                    if (record.edge_id < edge_id) {
                        lo = mid + 1;
                    } else {
                        hi = mid;
                    }
                }
                if (lo >= self.count) return false;
                const record = try self.readRecordAt(lo);
                return record.edge_id == edge_id;
            }

            fn readRecordAt(self: *EdgeTombstoneIndexView, index: u64) !support.EdgeTombstoneRecord {
                if (self.map) |*map| return Ops.readEdgeTombstoneRecordFromMap(map, index);
                return Ops.readEdgeTombstoneRecordAt(self.store, self.file, index);
            }
        };

        pub const EdgeIndexRecordIterator = struct {
            store: Store,
            file: std.Io.File,
            map: ?std.Io.File.MemoryMap = null,
            header: EdgeIndexHeader,
            order: EdgeIndexOrder,
            key: u64,
            rel_filter: ?u16 = null,
            tombstones: ?EdgeTombstoneIndexView = null,
            pos: u64,
            end: u64,
            physical_records_scanned: u64 = 0,
            max_physical_records: ?u64 = null,
            done: bool = false,

            pub fn deinit(self: *EdgeIndexRecordIterator) void {
                if (self.tombstones) |*tombstones| tombstones.deinit();
                if (self.map) |*map| map.destroy(self.store.io);
                self.file.close(self.store.io);
            }

            pub fn next(self: *EdgeIndexRecordIterator) !?EdgeIndexRecord {
                while (!self.done and self.pos < self.end) {
                    if (self.max_physical_records) |limit| {
                        if (self.physical_records_scanned >= limit) return core.Error.BudgetExceeded;
                    }
                    const record = try self.readRecordAt(self.pos);
                    self.pos += 1;
                    self.physical_records_scanned += 1;
                    if (support.edgeIndexRecordKey(record, self.order) != self.key) {
                        self.done = true;
                        return null;
                    }
                    if (self.rel_filter) |rel| {
                        if (record.rel != rel) {
                            self.done = true;
                            return null;
                        }
                    }
                    if (self.tombstones) |*tombstones| {
                        if (try tombstones.contains(record.edge_id)) continue;
                    }
                    return record;
                }
                return null;
            }

            fn readRecordAt(self: *EdgeIndexRecordIterator, index: u64) !EdgeIndexRecord {
                if (self.map) |*map| return Ops.readEdgeIndexRecordFromMap(self.header, map, index);
                return Ops.readEdgeIndexRecordAt(self.store, self.file, self.header, index);
            }
        };

        pub const VisibleEdgeIndexRecordIterator = struct {
            reader: support.EdgeIndexRecordReader,
            tombstones: ?EdgeTombstoneIndexView = null,
            pos: u64 = 0,

            pub fn deinit(self: *VisibleEdgeIndexRecordIterator) void {
                if (self.tombstones) |*tombstones| tombstones.deinit();
                self.reader.deinit();
            }

            pub fn next(self: *VisibleEdgeIndexRecordIterator) !?EdgeIndexRecord {
                while (self.pos < self.reader.edge_count) {
                    const record = try self.reader.read(self.pos);
                    self.pos += 1;
                    if (self.tombstones) |*tombstones| {
                        if (try tombstones.contains(record.edge_id)) continue;
                    }
                    return record;
                }
                return null;
            }
        };

        pub const EdgeIndexKeyRunBounds = struct {
            start: u64,
            end: u64,
        };

        pub const EdgeIndexSequentialRecordReader = struct {
            store: Store,
            file: std.Io.File,
            header: EdgeIndexHeader,
            run_index: u64 = 0,
            current_run: ?support.EdgeIndexKeyRunRecord = null,
            next_run: ?support.EdgeIndexKeyRunRecord = null,

            pub fn init(store: Store, file: std.Io.File, header: EdgeIndexHeader) !EdgeIndexSequentialRecordReader {
                var out = EdgeIndexSequentialRecordReader{
                    .store = store,
                    .file = file,
                    .header = header,
                };
                if (header.hasKeyRuns()) {
                    out.current_run = try Ops.readEdgeIndexKeyRunAt(store, file, header, 0);
                    if (out.current_run.?.start != 0) return error.InvalidRecord;
                    if (header.key_run_count > 1) {
                        out.next_run = try Ops.readEdgeIndexKeyRunAt(store, file, header, 1);
                        try support.validateAdjacentEdgeIndexKeyRuns(header, out.current_run.?, out.next_run.?);
                    }
                }
                return out;
            }

            pub fn read(self: *EdgeIndexSequentialRecordReader, index: u64) !EdgeIndexRecord {
                if (!self.header.hasKeyRuns()) return Ops.readEdgeIndexRecordAt(self.store, self.file, self.header, index);
                if (index >= self.header.edge_count) return error.InvalidRecord;
                while (self.next_run) |next| {
                    if (index < next.start) break;
                    self.current_run = next;
                    self.run_index += 1;
                    if (self.run_index + 1 < self.header.key_run_count) {
                        self.next_run = try Ops.readEdgeIndexKeyRunAt(self.store, self.file, self.header, self.run_index + 1);
                        try support.validateAdjacentEdgeIndexKeyRuns(self.header, self.current_run.?, self.next_run.?);
                    } else {
                        self.next_run = null;
                    }
                }
                const run = self.current_run orelse return error.InvalidRecord;
                if (index < run.start) return error.InvalidRecord;

                var bytes: [EdgeIndexRecord.encoded_len]u8 = undefined;
                const record_bytes = bytes[0..self.header.record_len];
                const offset = try support.edgeIndexRecordOffsetForHeader(self.header, index);
                const n = try self.file.readPositionalAll(self.store.io, record_bytes, offset);
                if (n != record_bytes.len) return error.InvalidRecord;
                return EdgeIndexRecord.decodeSliceAtForHeader(self.header, index, record_bytes, run);
            }
        };

        pub const ExplicitEdgeIndexSequentialReader = struct {
            allocator: std.mem.Allocator,
            io: std.Io,
            file: std.Io.File,
            header: EdgeIndexHeader,
            buffer: []u8,
            file_offset: u64,
            cursor: usize = 0,
            len: usize = 0,
            next_index: u64 = 0,

            pub fn init(allocator: std.mem.Allocator, io: std.Io, file: std.Io.File, header: EdgeIndexHeader) !ExplicitEdgeIndexSequentialReader {
                if (header.hasKeyRuns()) return error.InvalidRecord;
                const body_bytes = std.math.mul(u64, header.edge_count, header.record_len) catch return error.RecordTooLarge;
                const buffer = try allocator.alloc(u8, try support.storageWriteBufferCapacity(body_bytes));
                return .{
                    .allocator = allocator,
                    .io = io,
                    .file = file,
                    .header = header,
                    .buffer = buffer,
                    .file_offset = EdgeIndexHeader.encoded_len,
                };
            }

            pub fn deinit(self: *ExplicitEdgeIndexSequentialReader) void {
                self.allocator.free(self.buffer);
                self.buffer = &.{};
            }

            fn refill(self: *ExplicitEdgeIndexSequentialReader) !void {
                const n = try self.file.readPositionalAll(self.io, self.buffer, self.file_offset);
                if (n == 0) return error.InvalidRecord;
                self.file_offset = std.math.add(u64, self.file_offset, n) catch return error.InvalidRecord;
                self.cursor = 0;
                self.len = n;
            }

            fn readRecordBytes(self: *ExplicitEdgeIndexSequentialReader, out: []u8) !void {
                var written: usize = 0;
                while (written < out.len) {
                    if (self.cursor == self.len) try self.refill();
                    const available = self.len - self.cursor;
                    const take = @min(available, out.len - written);
                    @memcpy(out[written .. written + take], self.buffer[self.cursor .. self.cursor + take]);
                    self.cursor += take;
                    written += take;
                }
            }

            pub fn next(self: *ExplicitEdgeIndexSequentialReader) !?EdgeIndexRecord {
                if (self.next_index >= self.header.edge_count) return null;
                var bytes: [EdgeIndexRecord.encoded_len]u8 = undefined;
                const encoded = bytes[0..self.header.record_len];
                try self.readRecordBytes(encoded);
                const record = try EdgeIndexRecord.decodeSliceAtForHeader(self.header, self.next_index, encoded, null);
                self.next_index += 1;
                return record;
            }
        };
    };
}

const TestCore = struct {
    pub const Error = error{BudgetExceeded};
};

const TestOrder = enum { by_key };

const TestHeader = struct {
    pub const encoded_len: u64 = 0;
    edge_count: u64,
    key_run_count: u64 = 0,
    record_len: u16 = TestRecord.encoded_len,
    pub fn hasKeyRuns(self: @This()) bool {
        return self.key_run_count != 0;
    }
};

const TestRecord = struct {
    pub const encoded_len: u16 = 24;
    key: u64,
    edge_id: u64,
    rel: u16,

    pub fn decodeSliceAtForHeader(_: TestHeader, _: u64, bytes: []const u8, _: ?TestSupport.EdgeIndexKeyRunRecord) !@This() {
        if (bytes.len != encoded_len) return error.InvalidRecord;
        return .{
            .key = std.mem.readInt(u64, bytes[0..8], .little),
            .edge_id = std.mem.readInt(u64, bytes[8..16], .little),
            .rel = std.mem.readInt(u16, bytes[16..18], .little),
        };
    }
};

const TestSupport = struct {
    pub const EdgeTombstoneRecord = struct { edge_id: u64 };
    pub const EdgeIndexKeyRunRecord = struct { start: u64 };
    pub const EdgeIndexRecordReader = struct {
        records: []const TestRecord,
        edge_count: u64,
        pub fn read(self: *@This(), index: u64) !TestRecord {
            if (index >= self.records.len) return error.InvalidRecord;
            return self.records[@intCast(index)];
        }
        pub fn deinit(_: *@This()) void {}
    };
    pub fn edgeTombstoneFileSize(count: u64) !u64 {
        return count * 8;
    }
    pub fn edgeIndexRecordKey(record: TestRecord, _: TestOrder) u64 {
        return record.key;
    }
    pub fn validateAdjacentEdgeIndexKeyRuns(header: TestHeader, current: EdgeIndexKeyRunRecord, next: EdgeIndexKeyRunRecord) !void {
        if (current.start >= next.start or next.start >= header.edge_count) return error.InvalidRecord;
    }
    pub fn edgeIndexRecordOffsetForHeader(header: TestHeader, index: u64) !u64 {
        return std.math.mul(u64, index, header.record_len) catch return error.InvalidRecord;
    }
    pub fn storageWriteBufferCapacity(bytes: u64) !usize {
        return @intCast(@max(bytes, 1));
    }
};

const TestStore = struct {
    io: std.Io = std.testing.io,
    edge_tombstones_path: []const u8 = "unused",
    records: []const TestRecord = &.{},
    tombstones: []const TestSupport.EdgeTombstoneRecord = &.{},
    runs: []const TestSupport.EdgeIndexKeyRunRecord = &.{},

    pub fn readEdgeIndexRecordAt(self: @This(), _: std.Io.File, _: TestHeader, index: u64) !TestRecord {
        if (index >= self.records.len) return error.InvalidRecord;
        return self.records[@intCast(index)];
    }
    pub fn readEdgeTombstoneRecordAt(self: @This(), _: std.Io.File, index: u64) !TestSupport.EdgeTombstoneRecord {
        if (index >= self.tombstones.len) return error.InvalidRecord;
        return self.tombstones[@intCast(index)];
    }
    pub fn readEdgeIndexKeyRunAt(self: @This(), _: std.Io.File, _: TestHeader, index: u64) !TestSupport.EdgeIndexKeyRunRecord {
        if (index >= self.runs.len) return error.InvalidRecord;
        return self.runs[@intCast(index)];
    }
};

const TestOps = struct {
    pub const dep_Store = TestStore;
    pub const dep_core = TestCore;
    pub const dep_support = TestSupport;
    pub const dep_EdgeIndexHeader = TestHeader;
    pub const dep_EdgeIndexOrder = TestOrder;
    pub const dep_EdgeIndexRecord = TestRecord;
    pub fn readEdgeTombstoneRecordFromMap(_: *const std.Io.File.MemoryMap, _: u64) !TestSupport.EdgeTombstoneRecord {
        return error.InvalidRecord;
    }
    pub fn readEdgeIndexRecordFromMap(_: TestHeader, _: *const std.Io.File.MemoryMap, _: u64) !TestRecord {
        return error.InvalidRecord;
    }
    pub fn readEdgeTombstoneHeaderFromFile(_: TestStore, _: std.Io.File) !struct { count: u64 } {
        return error.InvalidRecord;
    }
    pub fn regularFileSize(_: TestStore, _: std.Io.File) !u64 {
        return error.InvalidRecord;
    }
    pub fn readEdgeTombstoneRecordAt(store: TestStore, file: std.Io.File, index: u64) !TestSupport.EdgeTombstoneRecord {
        return store.readEdgeTombstoneRecordAt(file, index);
    }
    pub fn readEdgeIndexRecordAt(store: TestStore, file: std.Io.File, header: TestHeader, index: u64) !TestRecord {
        return store.readEdgeIndexRecordAt(file, header, index);
    }
    pub fn readEdgeIndexKeyRunAt(store: TestStore, file: std.Io.File, header: TestHeader, index: u64) !TestSupport.EdgeIndexKeyRunRecord {
        return store.readEdgeIndexKeyRunAt(file, header, index);
    }
    pub fn openReadOnlyMemoryMap(_: std.Io, _: std.Io.File, _: u64) !std.Io.File.MemoryMap {
        return error.Unsupported;
    }
};

const TestViews = EdgeIndexReadViews(TestOps);

fn testIterator(records: []const TestRecord) TestViews.EdgeIndexRecordIterator {
    return .{
        .store = .{ .records = records },
        .file = undefined,
        .header = .{ .edge_count = records.len },
        .order = .by_key,
        .key = 7,
        .pos = 0,
        .end = records.len,
    };
}

test "edge index iterator enforces physical scan budget before read" {
    const records = [_]TestRecord{.{ .key = 7, .edge_id = 1, .rel = 2 }};
    var iterator = testIterator(&records);
    iterator.max_physical_records = 0;
    try std.testing.expectError(TestCore.Error.BudgetExceeded, iterator.next());
    try std.testing.expectEqual(@as(u64, 0), iterator.physical_records_scanned);
}

test "edge index iterator stops at key and relation boundaries" {
    const records = [_]TestRecord{
        .{ .key = 7, .edge_id = 1, .rel = 2 },
        .{ .key = 7, .edge_id = 2, .rel = 3 },
        .{ .key = 8, .edge_id = 3, .rel = 2 },
    };
    var relation_iterator = testIterator(&records);
    relation_iterator.rel_filter = 2;
    try std.testing.expectEqual(@as(u64, 1), (try relation_iterator.next()).?.edge_id);
    try std.testing.expect((try relation_iterator.next()) == null);
    try std.testing.expect(relation_iterator.done);

    var key_iterator = testIterator(records[2..]);
    try std.testing.expect((try key_iterator.next()) == null);
    try std.testing.expect(key_iterator.done);
}

test "visible edge iterator filters tombstones without reordering" {
    const records = [_]TestRecord{
        .{ .key = 7, .edge_id = 1, .rel = 2 },
        .{ .key = 7, .edge_id = 2, .rel = 2 },
    };
    const tombstones = [_]TestSupport.EdgeTombstoneRecord{.{ .edge_id = 1 }};
    var iterator = TestViews.VisibleEdgeIndexRecordIterator{
        .reader = .{ .records = &records, .edge_count = records.len },
        .tombstones = .{
            .store = .{ .tombstones = &tombstones },
            .file = undefined,
            .count = 1,
        },
    };
    try std.testing.expectEqual(@as(u64, 2), (try iterator.next()).?.edge_id);
    try std.testing.expect((try iterator.next()) == null);
}

test "explicit edge index reader rejects keyed headers" {
    try std.testing.expectError(
        error.InvalidRecord,
        TestViews.ExplicitEdgeIndexSequentialReader.init(
            std.testing.allocator,
            std.testing.io,
            undefined,
            .{ .edge_count = 1, .key_run_count = 1 },
        ),
    );
}

fn encodeTestRecord(out: *[TestRecord.encoded_len]u8, record: TestRecord) void {
    @memset(out, 0);
    std.mem.writeInt(u64, out[0..8], record.key, .little);
    std.mem.writeInt(u64, out[8..16], record.edge_id, .little);
    std.mem.writeInt(u16, out[16..18], record.rel, .little);
}

test "compact edge index reader advances validated key runs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "edge.bin" });
    defer std.testing.allocator.free(path);

    var file = try std.Io.Dir.cwd().createFile(std.testing.io, path, .{ .read = true, .truncate = true });
    defer file.close(std.testing.io);
    const records = [_]TestRecord{
        .{ .key = 7, .edge_id = 1, .rel = 2 },
        .{ .key = 7, .edge_id = 2, .rel = 2 },
        .{ .key = 8, .edge_id = 3, .rel = 2 },
    };
    for (records, 0..) |record, index| {
        var bytes: [TestRecord.encoded_len]u8 = undefined;
        encodeTestRecord(&bytes, record);
        try file.writePositionalAll(std.testing.io, &bytes, index * TestRecord.encoded_len);
    }
    const runs = [_]TestSupport.EdgeIndexKeyRunRecord{ .{ .start = 0 }, .{ .start = 2 } };
    var reader = try TestViews.EdgeIndexSequentialRecordReader.init(
        .{ .runs = &runs },
        file,
        .{ .edge_count = records.len, .key_run_count = runs.len },
    );
    try std.testing.expectEqual(@as(u64, 1), (try reader.read(0)).edge_id);
    try std.testing.expectEqual(@as(u64, 3), (try reader.read(2)).edge_id);
    try std.testing.expectEqual(@as(u64, 1), reader.run_index);
}
