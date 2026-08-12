const std = @import("std");
const edge_index_format_mod = @import("edge_index_format.zig");

const write_buffer_bytes: usize = 256 * 1024;

/// Owns repair-spool shape recognition, bounded sorting, dense-ring planning,
/// id/src/dst publication sequencing, run cleanup, and streaming k-way merge.
/// General complete-index writing and derived-record compaction are narrow
/// lower-level ports shared with normal append and maintenance paths.
pub fn EdgeRepairIndexPublication(
    comptime core: type,
    comptime max_relation_types: u16,
    comptime Ops: type,
) type {
    return struct {
        const Self = @This();
        const Format = edge_index_format_mod.EdgeIndexFormat(core, max_relation_types);
        const StoreType = Ops.StoreType;
        const Timings = Ops.TimingsType;
        pub const EdgeIndexOrder = Format.EdgeIndexOrder;
        const EdgeIndexRelDerivation = Format.EdgeIndexRelDerivation;
        pub const EdgeIndexDenseKeyRunSpan = Format.EdgeIndexDenseKeyRunSpan;
        const EdgeIndexHeader = Format.EdgeIndexHeader;
        pub const EdgeIndexRecord = Format.EdgeIndexRecord;
        pub const EdgeIndexKeyRunRecord = Format.EdgeIndexKeyRunRecord;

        const StorageBufferedWriter = struct {
            io: std.Io,
            file: std.Io.File,
            allocator: std.mem.Allocator,
            buffer: []u8,
            len: usize = 0,
            offset: u64 = 0,

            fn init(allocator: std.mem.Allocator, io: std.Io, file: std.Io.File, capacity: usize) !StorageBufferedWriter {
                std.debug.assert(capacity > 0);
                return .{ .io = io, .file = file, .allocator = allocator, .buffer = try allocator.alloc(u8, capacity) };
            }

            fn deinit(self: *StorageBufferedWriter) void {
                self.allocator.free(self.buffer);
            }

            fn append(self: *StorageBufferedWriter, bytes: []const u8) !void {
                if (bytes.len > self.buffer.len) {
                    try self.flush();
                    try self.file.writePositionalAll(self.io, bytes, self.offset);
                    self.offset = std.math.add(u64, self.offset, bytes.len) catch return error.InvalidRecord;
                    return;
                }
                if (self.len + bytes.len > self.buffer.len) try self.flush();
                @memcpy(self.buffer[self.len .. self.len + bytes.len], bytes);
                self.len += bytes.len;
            }

            fn flush(self: *StorageBufferedWriter) !void {
                if (self.len == 0) return;
                try self.file.writePositionalAll(self.io, self.buffer[0..self.len], self.offset);
                self.offset = std.math.add(u64, self.offset, self.len) catch return error.InvalidRecord;
                self.len = 0;
            }

            fn position(self: StorageBufferedWriter) !u64 {
                return std.math.add(u64, self.offset, self.len) catch return error.InvalidRecord;
            }
        };

        const EdgeIndexDigest = struct {
            count: u64 = 0,
            digest: u64 = 0,
            order_digest: u64 = 0,

            fn add(self: *EdgeIndexDigest, record: EdgeIndexRecord) void {
                self.order_digest = edgeIndexOrderDigestStep(self.order_digest, self.count, record);
                self.digest ^= edgeRecordDigest(record);
                self.count += 1;
            }

            fn eql(self: EdgeIndexDigest, other: EdgeIndexDigest) bool {
                return self.count == other.count and self.digest == other.digest;
            }
        };

        fn edgeRecordDigest(record: EdgeIndexRecord) u64 {
            var bytes: [26]u8 = undefined;
            std.mem.writeInt(u64, bytes[0..8], record.edge_id, .little);
            std.mem.writeInt(u64, bytes[8..16], record.src, .little);
            std.mem.writeInt(u16, bytes[16..18], record.rel, .little);
            std.mem.writeInt(u64, bytes[18..26], record.dst, .little);
            return std.hash.Wyhash.hash(0x544B_4745, &bytes);
        }

        fn edgeIndexOrderDigestStep(previous: u64, position: u64, record: EdgeIndexRecord) u64 {
            var bytes: [34]u8 = undefined;
            std.mem.writeInt(u64, bytes[0..8], previous, .little);
            std.mem.writeInt(u64, bytes[8..16], position, .little);
            std.mem.writeInt(u64, bytes[16..24], edgeRecordDigest(record), .little);
            std.mem.writeInt(u64, bytes[24..32], record.edge_id, .little);
            std.mem.writeInt(u16, bytes[32..34], record.rel, .little);
            return std.hash.Wyhash.hash(0x544B_4758, &bytes);
        }

        fn edgeIndexLessThan(order: EdgeIndexOrder, lhs: EdgeIndexRecord, rhs: EdgeIndexRecord) bool {
            return Ops.edgeIndexLessThan(order, lhs, rhs);
        }

        fn sortEdgeIndexRecords(order: EdgeIndexOrder, records: []EdgeIndexRecord) void {
            return Ops.sortRecords(order, records);
        }

        fn edgeRecordHasU32NodeIds(record: EdgeIndexRecord) bool {
            return Ops.recordHasU32NodeIds(record);
        }

        fn edgeIndexRecordKey(record: EdgeIndexRecord, order: EdgeIndexOrder) u64 {
            return Ops.recordKey(record, order);
        }

        fn edgeIndexRecordOpposite(record: EdgeIndexRecord, order: EdgeIndexOrder) ?u64 {
            return Ops.recordOpposite(record, order);
        }

        fn edgeIndexMaybeBetterDenseKeyRunSpan(current: ?EdgeIndexDenseKeyRunSpan, best_score: *u64, run_start: u64, first: EdgeIndexKeyRunRecord, count: u64, start_step: u64, edge_id_base_step: u64) ?EdgeIndexDenseKeyRunSpan {
            return Ops.maybeBetterDenseKeyRunSpan(current, best_score, run_start, first, count, start_step, edge_id_base_step);
        }

        fn edgeIndexDenseKeyRunSpanRecordForIndex(header: EdgeIndexHeader, run_index: u64) !EdgeIndexKeyRunRecord {
            return Ops.denseKeyRunSpanRecordForIndex(header, run_index);
        }

        fn edgeIndexKeyRunRecordsEquivalent(header: EdgeIndexHeader, expected: EdgeIndexKeyRunRecord, actual: EdgeIndexKeyRunRecord) bool {
            return Ops.keyRunRecordsEquivalent(header, expected, actual);
        }

        fn validateAdjacentEdgeIndexKeyRuns(header: EdgeIndexHeader, current: EdgeIndexKeyRunRecord, next: EdgeIndexKeyRunRecord) !void {
            return Ops.validateAdjacentKeyRuns(header, current, next);
        }

        fn edgeIndexKeyRunRecordLen(header: EdgeIndexHeader) usize {
            return Format.keyRunRecordLen(header);
        }

        fn edgeIndexFileSize(edge_count: u64) !u64 {
            const max_records_size = std.math.maxInt(u64) - EdgeIndexHeader.encoded_len;
            if (edge_count > max_records_size / EdgeIndexRecord.encoded_len) return error.InvalidRecord;
            return EdgeIndexHeader.encoded_len + edge_count * EdgeIndexRecord.encoded_len;
        }

        fn edgeIndexFileSizeForHeader(header: EdgeIndexHeader) !u64 {
            try header.validateShape();
            const directory_size = try Format.keyRunDirectorySizeForHeader(header);
            const rows_size = std.math.mul(u64, header.edge_count, header.record_len) catch return error.InvalidRecord;
            const with_directory = std.math.add(u64, EdgeIndexHeader.encoded_len, directory_size) catch return error.InvalidRecord;
            return std.math.add(u64, with_directory, rows_size) catch return error.InvalidRecord;
        }

        fn storageWriteBufferCapacity(file_size: u64) !usize {
            const size = std.math.cast(usize, file_size) orelse return error.RecordTooLarge;
            return @min(write_buffer_bytes, size);
        }

        fn regularFileSize(store: StoreType, file: std.Io.File) !u64 {
            const stat = try file.stat(Ops.io(store));
            if (stat.kind != .file) return error.IsDir;
            return stat.size;
        }

        fn tmpPath(store: StoreType, path: []const u8) ![]u8 {
            return try std.fmt.allocPrint(Ops.allocator(store), "{s}.tmp", .{path});
        }

        pub fn publish(store: StoreType, spool_path: []const u8, record_count: usize, timings: ?*Timings) !void {
            return writeEdgeIndexesFromRepairSpool(store, spool_path, record_count, timings);
        }

        pub fn writeOne(store: StoreType, path: []const u8, order: EdgeIndexOrder, spool_path: []const u8, record_count: usize) !void {
            return writeEdgeIndexFromRepairSpool(store, path, order, spool_path, record_count);
        }

        pub fn detectDenseRing(store: StoreType, spool_path: []const u8, record_count: usize) !?DenseRingRepairSpoolShape {
            return detectDenseRingRepairSpoolShape(store, spool_path, record_count);
        }

        pub fn writeDenseRingId(store: StoreType, path: []const u8, shape: DenseRingRepairSpoolShape) !bool {
            return writeDenseRingIdEdgeIndex(store, path, shape);
        }

        pub fn writeDenseRingSecondary(store: StoreType, path: []const u8, order: EdgeIndexOrder, shape: DenseRingRepairSpoolShape) !bool {
            return writeDenseRingSecondaryEdgeIndex(store, path, order, shape);
        }

        pub fn readSpoolChunk(store: StoreType, file: std.Io.File, start_index: usize, record_count: usize, buffer: []u8, out: *std.ArrayList(EdgeIndexRecord)) !void {
            return readEdgeRepairSpoolChunk(store, file, start_index, record_count, buffer, out);
        }

        pub fn writeRun(store: StoreType, path: []const u8, records: []const EdgeIndexRecord) !void {
            return writeRepairEdgeRun(store, path, records);
        }

        pub const EdgeRepairRunReader = struct {
            file: std.Io.File,
            map: ?std.Io.File.MemoryMap = null,
            next_index: u64,
            count: u64,
            buffer: []u8 = &.{},
            file_offset: u64 = 0,
            cursor: usize = 0,
            len: usize = 0,

            pub fn deinit(self: *EdgeRepairRunReader, allocator: std.mem.Allocator, io: std.Io) void {
                allocator.free(self.buffer);
                if (self.map) |*map| map.destroy(io);
                self.file.close(io);
            }

            fn refill(self: *EdgeRepairRunReader, store: StoreType) !void {
                const n = try self.file.readPositionalAll(Ops.io(store), self.buffer, self.file_offset);
                if (n == 0) return error.InvalidRecord;
                self.file_offset = std.math.add(u64, self.file_offset, n) catch return error.InvalidRecord;
                self.cursor = 0;
                self.len = n;
            }

            fn readBytes(self: *EdgeRepairRunReader, store: StoreType, out: []u8) !void {
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

            pub fn next(self: *EdgeRepairRunReader, store: StoreType) !?EdgeIndexRecord {
                if (self.next_index >= self.count) return null;
                const record = if (self.map) |*map| record: {
                    const offset = std.math.mul(u64, self.next_index, EdgeIndexRecord.encoded_len) catch return error.InvalidRecord;
                    const start = std.math.cast(usize, offset) orelse return error.RecordTooLarge;
                    const end = std.math.add(usize, start, EdgeIndexRecord.encoded_len) catch return error.InvalidRecord;
                    if (end > map.memory.len) return error.InvalidRecord;
                    break :record try EdgeIndexRecord.decodeSlice(map.memory[start..end]);
                } else record: {
                    if (self.cursor == self.len) try self.refill(store);
                    if (self.len - self.cursor >= EdgeIndexRecord.encoded_len) {
                        const bytes = self.buffer[self.cursor .. self.cursor + EdgeIndexRecord.encoded_len];
                        self.cursor += EdgeIndexRecord.encoded_len;
                        break :record try EdgeIndexRecord.decodeSlice(bytes);
                    }
                    var bytes: [EdgeIndexRecord.encoded_len]u8 = undefined;
                    try self.readBytes(store, &bytes);
                    break :record try EdgeIndexRecord.decode(&bytes);
                };
                self.next_index += 1;
                return record;
            }
        };

        pub const EdgeRepairRunHeapEntry = struct {
            run_index: usize,
            record: EdgeIndexRecord,
        };

        pub const EdgeRepairRunHeapContext = struct {
            order: EdgeIndexOrder,
        };

        pub fn compareEdgeRepairRunHeapEntry(context: EdgeRepairRunHeapContext, lhs: EdgeRepairRunHeapEntry, rhs: EdgeRepairRunHeapEntry) std.math.Order {
            if (edgeIndexLessThan(context.order, lhs.record, rhs.record)) return .lt;
            if (edgeIndexLessThan(context.order, rhs.record, lhs.record)) return .gt;
            return std.math.order(lhs.run_index, rhs.run_index);
        }

        fn deinitEdgeRepairRunPaths(self: StoreType, run_paths: *std.ArrayList([]u8)) void {
            for (run_paths.items) |run_path| {
                std.Io.Dir.cwd().deleteFile(Ops.io(self), run_path) catch {};
                Ops.allocator(self).free(run_path);
            }
            run_paths.deinit(Ops.allocator(self));
        }

        fn appendEdgeRepairRunPath(
            self: StoreType,
            run_paths: *std.ArrayList([]u8),
            path: []const u8,
            order: EdgeIndexOrder,
            records: []const EdgeIndexRecord,
        ) !void {
            const run_path = try std.fmt.allocPrint(Ops.allocator(self), "{s}.repair_run.{c}.{d}.tmp", .{ path, @intFromEnum(order), run_paths.items.len });
            var keep_run_path = false;
            errdefer if (!keep_run_path) {
                std.Io.Dir.cwd().deleteFile(Ops.io(self), run_path) catch {};
                Ops.allocator(self).free(run_path);
            };
            try writeRepairEdgeRun(self, run_path, records);
            try run_paths.append(Ops.allocator(self), run_path);
            keep_run_path = true;
        }

        pub fn validateSortedRepairEdgeRecords(order: EdgeIndexOrder, records: []const EdgeIndexRecord) !void {
            var previous: ?EdgeIndexRecord = null;
            for (records) |record| {
                if (previous) |prev| {
                    if (!edgeIndexLessThan(order, prev, record)) return error.InvalidRecord;
                    if (order == .id and record.edge_id == prev.edge_id) return error.InvalidRecord;
                }
                previous = record;
            }
        }

        pub fn validateSortedRepairEdgeRecordOrder(order: EdgeIndexOrder, records: []const EdgeIndexRecord, record_order: []const u32) !void {
            if (records.len != record_order.len) return error.InvalidRecord;
            var previous: ?EdgeIndexRecord = null;
            for (record_order) |index| {
                if (index >= records.len) return error.InvalidRecord;
                const record = records[@intCast(index)];
                if (previous) |prev| {
                    if (!edgeIndexLessThan(order, prev, record)) return error.InvalidRecord;
                    if (order == .id and record.edge_id == prev.edge_id) return error.InvalidRecord;
                }
                previous = record;
            }
        }

        fn writeEdgeIndexesFromRepairSpool(self: StoreType, spool_path: []const u8, record_count: usize, timings: ?*Timings) !void {
            if (record_count > Ops.sortChunkRecords()) {
                // Large repairs are disk-bound. Build each order to completion before
                // starting the next one so only one order's run files coexist with the
                // repair spool and output temp file.
                const ring_shape = try detectDenseRingRepairSpoolShape(self, spool_path, record_count);
                const id_start = if (timings != null) Ops.monotonicNs(self) else 0;
                if (ring_shape) |shape| {
                    if (!try writeDenseRingIdEdgeIndex(self, Ops.edgeByIdPath(self), shape)) {
                        try writeEdgeIndexFromRepairSpool(self, Ops.edgeByIdPath(self), .id, spool_path, record_count);
                    }
                } else {
                    try writeEdgeIndexFromRepairSpool(self, Ops.edgeByIdPath(self), .id, spool_path, record_count);
                }
                if (timings) |t| t.edge_id_index_ns += Ops.elapsedNs(self, id_start);
                const src_start = if (timings != null) Ops.monotonicNs(self) else 0;
                if (ring_shape) |shape| {
                    if (!try writeDenseRingSecondaryEdgeIndex(self, Ops.edgeBySrcPath(self), .src, shape)) {
                        try writeEdgeIndexFromRepairSpool(self, Ops.edgeBySrcPath(self), .src, spool_path, record_count);
                    }
                } else {
                    try writeEdgeIndexFromRepairSpool(self, Ops.edgeBySrcPath(self), .src, spool_path, record_count);
                }
                if (timings) |t| t.edge_src_index_ns += Ops.elapsedNs(self, src_start);
                const dst_start = if (timings != null) Ops.monotonicNs(self) else 0;
                if (ring_shape) |shape| {
                    if (!try writeDenseRingSecondaryEdgeIndex(self, Ops.edgeByDstPath(self), .dst, shape)) {
                        try writeEdgeIndexFromRepairSpool(self, Ops.edgeByDstPath(self), .dst, spool_path, record_count);
                    }
                } else {
                    try writeEdgeIndexFromRepairSpool(self, Ops.edgeByDstPath(self), .dst, spool_path, record_count);
                }
                if (timings) |t| t.edge_dst_index_ns += Ops.elapsedNs(self, dst_start);
                return;
            }

            var spool_file = try std.Io.Dir.cwd().openFile(Ops.io(self), spool_path, .{});
            defer spool_file.close(Ops.io(self));
            const expected_spool_size = std.math.mul(u64, @intCast(record_count), EdgeIndexRecord.encoded_len) catch return error.InvalidRecord;
            if (try regularFileSize(self, spool_file) != expected_spool_size) return error.InvalidRecord;

            var records = std.ArrayList(EdgeIndexRecord).empty;
            defer records.deinit(Ops.allocator(self));
            var sorted_records = std.ArrayList(EdgeIndexRecord).empty;
            defer sorted_records.deinit(Ops.allocator(self));
            try records.ensureTotalCapacityPrecise(Ops.allocator(self), record_count);
            try sorted_records.ensureTotalCapacityPrecise(Ops.allocator(self), record_count);
            const chunk_bytes = try Ops.allocator(self).alloc(u8, std.math.mul(usize, record_count, EdgeIndexRecord.encoded_len) catch return error.InvalidRecord);
            defer Ops.allocator(self).free(chunk_bytes);
            if (record_count != 0) {
                try readEdgeRepairSpoolChunk(self, spool_file, 0, record_count, chunk_bytes, &records);
            }

            const id_start = if (timings != null) Ops.monotonicNs(self) else 0;
            try writeSingleChunkRepairEdgeIndexFromScratch(self, Ops.edgeByIdPath(self), .id, records.items, &sorted_records);
            if (timings) |t| t.edge_id_index_ns += Ops.elapsedNs(self, id_start);
            const src_start = if (timings != null) Ops.monotonicNs(self) else 0;
            try writeSingleChunkRepairEdgeIndexFromScratch(self, Ops.edgeBySrcPath(self), .src, records.items, &sorted_records);
            if (timings) |t| t.edge_src_index_ns += Ops.elapsedNs(self, src_start);
            const dst_start = if (timings != null) Ops.monotonicNs(self) else 0;
            try writeSingleChunkRepairEdgeIndexFromScratch(self, Ops.edgeByDstPath(self), .dst, records.items, &sorted_records);
            if (timings) |t| t.edge_dst_index_ns += Ops.elapsedNs(self, dst_start);
        }

        pub const DenseRingRepairSpoolShape = struct {
            edge_count: u64,
            ring_count: u64,
            node_mod: u64,
            edge_digest: u64,
            id_order_digest: u64,
            has_tail_fixture: bool,
        };

        const DenseRingSecondaryRun = struct {
            src: u64,
            dst: u64,
            edge_id_base: u64,
            len: u64,
            rel: u16,

            fn firstRecord(self: DenseRingSecondaryRun) EdgeIndexRecord {
                return .{
                    .src = self.src,
                    .dst = self.dst,
                    .edge_id = self.edge_id_base,
                    .rel = self.rel,
                };
            }

            fn key(self: DenseRingSecondaryRun, order: EdgeIndexOrder) u64 {
                return edgeIndexRecordKey(self.firstRecord(), order);
            }

            fn opposite(self: DenseRingSecondaryRun, order: EdgeIndexOrder) u64 {
                return edgeIndexRecordOpposite(self.firstRecord(), order) orelse 0;
            }
        };

        pub const DenseRingSecondaryDensePlan = struct {
            run_count: u64,
            dense: EdgeIndexDenseKeyRunSpan,
        };

        fn openEdgeRepairSpoolReader(self: StoreType, spool_path: []const u8, record_count: usize) !EdgeRepairRunReader {
            var spool_file = try std.Io.Dir.cwd().openFile(Ops.io(self), spool_path, .{});
            var keep_file = false;
            errdefer if (!keep_file) spool_file.close(Ops.io(self));
            const expected_spool_size = std.math.mul(u64, @intCast(record_count), EdgeIndexRecord.encoded_len) catch return error.InvalidRecord;
            if (try regularFileSize(self, spool_file) != expected_spool_size) return error.InvalidRecord;

            var map = if (shouldMmapRepairSpool(expected_spool_size))
                Ops.openReadOnlyMemoryMap(self, spool_file, expected_spool_size) catch null
            else
                null;
            errdefer if (map) |*mapped| mapped.destroy(Ops.io(self));
            var buffer: []u8 = &.{};
            errdefer Ops.allocator(self).free(buffer);
            if (map == null) {
                buffer = try Ops.allocator(self).alloc(u8, try storageWriteBufferCapacity(expected_spool_size));
            }

            const reader = EdgeRepairRunReader{
                .file = spool_file,
                .map = map,
                .next_index = 0,
                .count = @intCast(record_count),
                .buffer = buffer,
            };
            keep_file = true;
            map = null;
            buffer = &.{};
            return reader;
        }

        pub fn shouldMmapRepairSpool(file_size: u64) bool {
            return file_size <= Ops.spoolMmapMaxBytes();
        }

        fn detectDenseRingRepairSpoolShape(self: StoreType, spool_path: []const u8, record_count: usize) !?DenseRingRepairSpoolShape {
            if (record_count == 0 or record_count > std.math.maxInt(u32)) return null;

            var reader = try openEdgeRepairSpoolReader(self, spool_path, record_count);
            defer reader.deinit(Ops.allocator(self), Ops.io(self));

            var digest = EdgeIndexDigest{};
            var max_endpoint: u64 = 0;
            var previous: ?EdgeIndexRecord = null;
            var last: ?EdgeIndexRecord = null;
            var pos: u64 = 0;
            while (try reader.next(self)) |record| : (pos += 1) {
                const expected_edge_id = pos + 1;
                if (record.edge_id != expected_edge_id) return null;
                if (!edgeRecordHasU32NodeIds(record)) return null;
                max_endpoint = @max(max_endpoint, @max(record.src, record.dst));
                digest.add(record);
                previous = last;
                last = record;
            }
            if (pos != record_count) return error.InvalidRecord;
            if (max_endpoint < 2 or max_endpoint > std.math.maxInt(u32)) return null;

            const edge_count: u64 = @intCast(record_count);
            const depends_rel: u16 = @intFromEnum(core.RelKind.depends_on);
            const has_tail_fixture = if (previous) |prev|
                if (last) |tail|
                    prev.edge_id == edge_count - 1 and
                        prev.src == 1 and prev.dst == 2 and prev.rel == depends_rel and
                        tail.edge_id == edge_count and tail.src == 2 and tail.dst == 3 and tail.rel == depends_rel
                else
                    false
            else
                false;
            const ring_count = if (has_tail_fixture) edge_count - 2 else edge_count;
            if (ring_count < max_endpoint) return null;

            var verify_reader = try openEdgeRepairSpoolReader(self, spool_path, record_count);
            defer verify_reader.deinit(Ops.allocator(self), Ops.io(self));
            const mentions_rel: u16 = @intFromEnum(core.RelKind.mentions);
            pos = 0;
            while (try verify_reader.next(self)) |record| : (pos += 1) {
                const edge_id = pos + 1;
                if (edge_id <= ring_count) {
                    const expected_src = ((edge_id - 1) % max_endpoint) + 1;
                    const expected_dst = (edge_id % max_endpoint) + 1;
                    if (record.src != expected_src or record.dst != expected_dst or record.rel != mentions_rel) return null;
                } else if (edge_id == edge_count - 1) {
                    if (record.src != 1 or record.dst != 2 or record.rel != depends_rel) return null;
                } else if (edge_id == edge_count) {
                    if (record.src != 2 or record.dst != 3 or record.rel != depends_rel) return null;
                } else {
                    return null;
                }
            }

            return .{
                .edge_count = edge_count,
                .ring_count = ring_count,
                .node_mod = max_endpoint,
                .edge_digest = digest.digest,
                .id_order_digest = digest.order_digest,
                .has_tail_fixture = has_tail_fixture,
            };
        }

        pub fn denseRingIdRunCount(shape: DenseRingRepairSpoolShape) ?u32 {
            if (shape.edge_count == 0 or shape.node_mod < 2 or shape.edge_count > std.math.maxInt(u32) or shape.node_mod > std.math.maxInt(u32)) return null;
            var run_count: u64 = 0;
            var pos: u64 = 0;
            while (pos < shape.ring_count) {
                const edge_id = pos + 1;
                const src = ((edge_id - 1) % shape.node_mod) + 1;
                const len = if (src == shape.node_mod)
                    1
                else
                    @min(shape.node_mod - src, shape.ring_count - pos);
                if (len == 0) return null;
                run_count = std.math.add(u64, run_count, 1) catch return null;
                pos = std.math.add(u64, pos, len) catch return null;
            }
            if (shape.has_tail_fixture) {
                run_count = std.math.add(u64, run_count, 2) catch return null;
            }
            if (run_count == 0 or run_count > std.math.maxInt(u32)) return null;
            const probe_header = denseRingIdHeader(shape, @intCast(run_count));
            if (probe_header.record_len != 0) return null;
            const run_bytes = std.math.mul(u64, run_count, edgeIndexKeyRunRecordLen(probe_header)) catch return null;
            if (run_bytes > Ops.keyRunMemoryCap()) return null;
            return @intCast(run_count);
        }

        fn denseRingIdHeader(shape: DenseRingRepairSpoolShape, run_count: u32) EdgeIndexHeader {
            return EdgeIndexHeader.withShape(
                .id,
                shape.edge_count,
                shape.edge_digest,
                shape.id_order_digest,
                true,
                true,
                false,
                denseRingRelDerivation(shape),
            ).withKeyRuns(run_count, true, false);
        }

        fn writeDenseRingIdRun(writer: *StorageBufferedWriter, header: EdgeIndexHeader, previous: *?EdgeIndexKeyRunRecord, run: EdgeIndexKeyRunRecord) !void {
            if (previous.*) |prev| try validateAdjacentEdgeIndexKeyRuns(header, prev, run);
            var run_bytes: [40]u8 = undefined;
            const encoded = run_bytes[0..edgeIndexKeyRunRecordLen(header)];
            try run.encodeForHeader(header, encoded);
            try writer.append(encoded);
            previous.* = run;
        }

        fn writeDenseRingIdEdgeIndex(self: StoreType, path: []const u8, shape: DenseRingRepairSpoolShape) !bool {
            const run_count = denseRingIdRunCount(shape) orelse return false;
            const header = denseRingIdHeader(shape, run_count);
            if (header.record_len != 0) return false;

            const tmp_path = try tmpPath(self, path);
            defer Ops.allocator(self).free(tmp_path);
            errdefer std.Io.Dir.cwd().deleteFile(Ops.io(self), tmp_path) catch {};

            const expected_size = try edgeIndexFileSizeForHeader(header);
            var file = try std.Io.Dir.cwd().createFile(Ops.io(self), tmp_path, .{
                .read = true,
                .truncate = true,
            });
            defer file.close(Ops.io(self));
            var writer = try StorageBufferedWriter.init(Ops.allocator(self), Ops.io(self), file, try storageWriteBufferCapacity(expected_size));
            defer writer.deinit();

            var header_bytes: [EdgeIndexHeader.encoded_len]u8 = undefined;
            header.encode(&header_bytes);
            try writer.append(&header_bytes);

            var previous: ?EdgeIndexKeyRunRecord = null;
            var written_runs: u32 = 0;
            var pos: u64 = 0;
            while (pos < shape.ring_count) {
                const edge_id = pos + 1;
                const src = ((edge_id - 1) % shape.node_mod) + 1;
                const dst = (edge_id % shape.node_mod) + 1;
                const len = if (src == shape.node_mod)
                    1
                else
                    @min(shape.node_mod - src, shape.ring_count - pos);
                if (len == 0) return error.InvalidRecord;
                try writeDenseRingIdRun(&writer, header, &previous, .{
                    .key = src,
                    .start = pos,
                    .opposite = dst,
                });
                written_runs = std.math.add(u32, written_runs, 1) catch return error.InvalidRecord;
                pos = std.math.add(u64, pos, len) catch return error.InvalidRecord;
            }
            if (shape.has_tail_fixture) {
                try writeDenseRingIdRun(&writer, header, &previous, .{
                    .key = 1,
                    .start = shape.ring_count,
                    .opposite = 2,
                });
                written_runs = std.math.add(u32, written_runs, 1) catch return error.InvalidRecord;
                const tail_second_start = std.math.add(u64, shape.ring_count, 1) catch return error.InvalidRecord;
                try writeDenseRingIdRun(&writer, header, &previous, .{
                    .key = 2,
                    .start = tail_second_start,
                    .opposite = 3,
                });
                written_runs = std.math.add(u32, written_runs, 1) catch return error.InvalidRecord;
            }
            if (pos != shape.ring_count or written_runs != run_count) return error.InvalidRecord;
            try writer.flush();
            if (try writer.position() != expected_size) return error.InvalidRecord;
            if (try regularFileSize(self, file) != expected_size) return error.InvalidRecord;
            if (Ops.shouldSync(self)) try file.sync(Ops.io(self));
            try Ops.renameReplace(self, tmp_path, path);
            return true;
        }

        fn appendDenseRingSecondaryRunCandidates(
            shape: DenseRingRepairSpoolShape,
            order: EdgeIndexOrder,
            key: u64,
            out: *[3]DenseRingSecondaryRun,
        ) usize {
            var count: usize = 0;
            const mentions_rel: u16 = @intFromEnum(core.RelKind.mentions);
            const first_ring_edge_id = switch (order) {
                .id => 0,
                .src => key,
                .dst => if (key == 1) shape.node_mod else key - 1,
            };
            if (first_ring_edge_id != 0 and first_ring_edge_id <= shape.ring_count) {
                const len = ((shape.ring_count - first_ring_edge_id) / shape.node_mod) + 1;
                out[count] = switch (order) {
                    .id => unreachable,
                    .src => .{
                        .src = key,
                        .dst = if (key == shape.node_mod) 1 else key + 1,
                        .edge_id_base = first_ring_edge_id,
                        .len = len,
                        .rel = mentions_rel,
                    },
                    .dst => .{
                        .src = if (key == 1) shape.node_mod else key - 1,
                        .dst = key,
                        .edge_id_base = first_ring_edge_id,
                        .len = len,
                        .rel = mentions_rel,
                    },
                };
                count += 1;
            }

            if (shape.has_tail_fixture) {
                const depends_rel: u16 = @intFromEnum(core.RelKind.depends_on);
                if (order == .src and key == 1) {
                    out[count] = .{ .src = 1, .dst = 2, .edge_id_base = shape.edge_count - 1, .len = 1, .rel = depends_rel };
                    count += 1;
                } else if (order == .src and key == 2) {
                    out[count] = .{ .src = 2, .dst = 3, .edge_id_base = shape.edge_count, .len = 1, .rel = depends_rel };
                    count += 1;
                } else if (order == .dst and key == 2) {
                    out[count] = .{ .src = 1, .dst = 2, .edge_id_base = shape.edge_count - 1, .len = 1, .rel = depends_rel };
                    count += 1;
                } else if (order == .dst and key == 3) {
                    out[count] = .{ .src = 2, .dst = 3, .edge_id_base = shape.edge_count, .len = 1, .rel = depends_rel };
                    count += 1;
                }
            }

            std.mem.sort(DenseRingSecondaryRun, out[0..count], order, denseRingSecondaryRunLessThan);
            return count;
        }

        fn denseRingSecondaryRunLessThan(order: EdgeIndexOrder, lhs: DenseRingSecondaryRun, rhs: DenseRingSecondaryRun) bool {
            return edgeIndexLessThan(order, lhs.firstRecord(), rhs.firstRecord());
        }

        pub fn planDenseRingSecondaryIndex(shape: DenseRingRepairSpoolShape, order: EdgeIndexOrder) ?DenseRingSecondaryDensePlan {
            if (order == .id or shape.node_mod == 0 or shape.node_mod > std.math.maxInt(u32)) return null;

            var best: ?EdgeIndexDenseKeyRunSpan = null;
            var best_score: u64 = 0;
            var span_start_index: u64 = 0;
            var span_start: EdgeIndexKeyRunRecord = undefined;
            var previous: EdgeIndexKeyRunRecord = undefined;
            var span_count: u64 = 0;
            var start_step: u64 = 0;
            var edge_id_base_step: u64 = 0;

            var row_start: u64 = 0;
            var run_index: u64 = 0;
            var key: u64 = 1;
            while (key <= shape.node_mod) : (key += 1) {
                var candidates: [3]DenseRingSecondaryRun = undefined;
                const candidate_count = appendDenseRingSecondaryRunCandidates(shape, order, key, &candidates);
                for (candidates[0..candidate_count]) |candidate| {
                    const run = EdgeIndexKeyRunRecord{
                        .key = candidate.key(order),
                        .start = row_start,
                        .opposite = candidate.opposite(order),
                        .edge_id_base = candidate.edge_id_base,
                        .edge_id_step = shape.node_mod,
                    };
                    const eligible = candidate.rel == @intFromEnum(core.RelKind.mentions) and
                        run.key != 0 and run.key <= std.math.maxInt(u32) and
                        run.start <= std.math.maxInt(u32) and
                        run.edge_id_base != 0 and run.edge_id_base <= std.math.maxInt(u32);
                    if (eligible and span_count != 0) {
                        const continues = run.key == previous.key + 1 and
                            run.start > previous.start and
                            run.edge_id_base > previous.edge_id_base;
                        if (continues) {
                            const next_start_step = run.start - previous.start;
                            const next_edge_base_step = run.edge_id_base - previous.edge_id_base;
                            if (span_count == 1) {
                                start_step = next_start_step;
                                edge_id_base_step = next_edge_base_step;
                                span_count = 2;
                            } else if (next_start_step == start_step and next_edge_base_step == edge_id_base_step) {
                                span_count += 1;
                            } else {
                                best = edgeIndexMaybeBetterDenseKeyRunSpan(best, &best_score, span_start_index, span_start, span_count, start_step, edge_id_base_step);
                                span_start_index = run_index;
                                span_start = run;
                                start_step = 0;
                                edge_id_base_step = 0;
                                span_count = 1;
                            }
                        } else {
                            best = edgeIndexMaybeBetterDenseKeyRunSpan(best, &best_score, span_start_index, span_start, span_count, start_step, edge_id_base_step);
                            span_start_index = run_index;
                            span_start = run;
                            start_step = 0;
                            edge_id_base_step = 0;
                            span_count = 1;
                        }
                    } else if (eligible) {
                        best = edgeIndexMaybeBetterDenseKeyRunSpan(best, &best_score, span_start_index, span_start, span_count, start_step, edge_id_base_step);
                        span_start_index = run_index;
                        span_start = run;
                        start_step = 0;
                        edge_id_base_step = 0;
                        span_count = 1;
                    } else {
                        best = edgeIndexMaybeBetterDenseKeyRunSpan(best, &best_score, span_start_index, span_start, span_count, start_step, edge_id_base_step);
                        span_count = 0;
                        start_step = 0;
                        edge_id_base_step = 0;
                    }
                    previous = run;
                    row_start += candidate.len;
                    run_index += 1;
                }
            }
            best = edgeIndexMaybeBetterDenseKeyRunSpan(best, &best_score, span_start_index, span_start, span_count, start_step, edge_id_base_step);
            const dense = best orelse return null;
            if (row_start != shape.edge_count or run_index == 0 or run_index > std.math.maxInt(u32)) return null;

            const explicit_runs = run_index - dense.count;
            const probe_header = EdgeIndexHeader.withShape(
                order,
                shape.edge_count,
                shape.edge_digest,
                0,
                false,
                true,
                true,
                denseRingRelDerivation(shape),
            ).withKeyRuns(@intCast(run_index), true, true).withKeyRunRingOpposite(shape.node_mod).withKeyRunUniformEdgeIdStep(shape.node_mod).withKeyRunDenseSpan(dense);
            const explicit_bytes = std.math.mul(u64, explicit_runs, edgeIndexKeyRunRecordLen(probe_header)) catch return null;
            if (explicit_bytes > Ops.keyRunMemoryCap()) return null;

            return .{ .run_count = run_index, .dense = dense };
        }

        fn denseRingRelDerivation(shape: DenseRingRepairSpoolShape) EdgeIndexRelDerivation {
            var derivation = EdgeIndexRelDerivation{ .default_rel = @intFromEnum(core.RelKind.mentions) };
            if (shape.has_tail_fixture) {
                derivation.exception_count = 2;
                derivation.exception_edge_ids = .{ shape.edge_count - 1, shape.edge_count };
                derivation.exception_rels = .{ @intFromEnum(core.RelKind.depends_on), @intFromEnum(core.RelKind.depends_on) };
            }
            return derivation;
        }

        fn denseRingSecondaryDigest(shape: DenseRingRepairSpoolShape, order: EdgeIndexOrder) !EdgeIndexDigest {
            var digest = EdgeIndexDigest{};
            var key: u64 = 1;
            while (key <= shape.node_mod) : (key += 1) {
                var candidates: [3]DenseRingSecondaryRun = undefined;
                const candidate_count = appendDenseRingSecondaryRunCandidates(shape, order, key, &candidates);
                for (candidates[0..candidate_count]) |candidate| {
                    var offset: u64 = 0;
                    while (offset < candidate.len) : (offset += 1) {
                        const edge_delta = std.math.mul(u64, offset, shape.node_mod) catch return error.InvalidRecord;
                        const edge_id = std.math.add(u64, candidate.edge_id_base, edge_delta) catch return error.InvalidRecord;
                        digest.add(.{
                            .src = candidate.src,
                            .dst = candidate.dst,
                            .edge_id = edge_id,
                            .rel = candidate.rel,
                        });
                    }
                }
            }
            if (digest.count != shape.edge_count) return error.InvalidRecord;
            if (digest.digest != shape.edge_digest) return error.InvalidRecord;
            return digest;
        }

        fn writeDenseRingSecondaryEdgeIndex(self: StoreType, path: []const u8, order: EdgeIndexOrder, shape: DenseRingRepairSpoolShape) !bool {
            const plan = planDenseRingSecondaryIndex(shape, order) orelse return false;
            const digest = try denseRingSecondaryDigest(shape, order);
            var header = EdgeIndexHeader.withShape(
                order,
                shape.edge_count,
                shape.edge_digest,
                digest.order_digest,
                false,
                true,
                true,
                denseRingRelDerivation(shape),
            ).withKeyRuns(@intCast(plan.run_count), true, true).withKeyRunRingOpposite(shape.node_mod).withKeyRunUniformEdgeIdStep(shape.node_mod).withKeyRunDenseSpan(plan.dense);
            if (header.record_len != 0) return false;

            const tmp_path = try tmpPath(self, path);
            defer Ops.allocator(self).free(tmp_path);
            errdefer std.Io.Dir.cwd().deleteFile(Ops.io(self), tmp_path) catch {};

            const expected_size = try edgeIndexFileSizeForHeader(header);
            var file = try std.Io.Dir.cwd().createFile(Ops.io(self), tmp_path, .{
                .read = true,
                .truncate = true,
            });
            defer file.close(Ops.io(self));
            var writer = try StorageBufferedWriter.init(Ops.allocator(self), Ops.io(self), file, try storageWriteBufferCapacity(expected_size));
            defer writer.deinit();

            var header_bytes: [EdgeIndexHeader.encoded_len]u8 = undefined;
            header.encode(&header_bytes);
            try writer.append(&header_bytes);

            const dense_end = plan.dense.run_start + plan.dense.count;
            var row_start: u64 = 0;
            var run_index: u64 = 0;
            var key: u64 = 1;
            var run_bytes: [40]u8 = undefined;
            while (key <= shape.node_mod) : (key += 1) {
                var candidates: [3]DenseRingSecondaryRun = undefined;
                const candidate_count = appendDenseRingSecondaryRunCandidates(shape, order, key, &candidates);
                for (candidates[0..candidate_count]) |candidate| {
                    const run = EdgeIndexKeyRunRecord{
                        .key = candidate.key(order),
                        .start = row_start,
                        .opposite = candidate.opposite(order),
                        .edge_id_base = candidate.edge_id_base,
                        .edge_id_step = shape.node_mod,
                    };
                    if (run_index >= plan.dense.run_start and run_index < dense_end) {
                        const expected = try edgeIndexDenseKeyRunSpanRecordForIndex(header, run_index);
                        if (!edgeIndexKeyRunRecordsEquivalent(header, expected, run)) return false;
                    } else {
                        const encoded = run_bytes[0..edgeIndexKeyRunRecordLen(header)];
                        try run.encodeForHeader(header, encoded);
                        try writer.append(encoded);
                    }
                    row_start += candidate.len;
                    run_index += 1;
                }
            }
            if (row_start != shape.edge_count or run_index != plan.run_count) return error.InvalidRecord;
            try writer.flush();
            if (try writer.position() != expected_size) return error.InvalidRecord;
            if (try regularFileSize(self, file) != expected_size) return error.InvalidRecord;
            if (Ops.shouldSync(self)) try file.sync(Ops.io(self));
            try Ops.renameReplace(self, tmp_path, path);
            return true;
        }

        fn writeSingleChunkRepairEdgeIndexFromScratch(
            self: StoreType,
            path: []const u8,
            order: EdgeIndexOrder,
            records: []const EdgeIndexRecord,
            sorted_records: *std.ArrayList(EdgeIndexRecord),
        ) !void {
            try sorted_records.ensureTotalCapacityPrecise(Ops.allocator(self), records.len);
            sorted_records.clearRetainingCapacity();
            for (records) |record| sorted_records.appendAssumeCapacity(record);
            sortEdgeIndexRecords(order, sorted_records.items);
            try validateSortedRepairEdgeRecords(order, sorted_records.items);
            try Ops.writeCompleteSortedIndex(self, path, sorted_records.items);
        }

        fn writeEdgeIndexFromRepairSpool(self: StoreType, path: []const u8, order: EdgeIndexOrder, spool_path: []const u8, record_count: usize) !void {
            if (order == .id and try writeSortedEdgeIdIndexFromRepairSpoolIfPossible(self, path, spool_path, record_count)) return;

            var spool_file = try std.Io.Dir.cwd().openFile(Ops.io(self), spool_path, .{});
            defer spool_file.close(Ops.io(self));
            const expected_spool_size = std.math.mul(u64, @intCast(record_count), EdgeIndexRecord.encoded_len) catch return error.InvalidRecord;
            if (try regularFileSize(self, spool_file) != expected_spool_size) return error.InvalidRecord;

            var run_paths = std.ArrayList([]u8).empty;
            defer deinitEdgeRepairRunPaths(self, &run_paths);

            var chunk = std.ArrayList(EdgeIndexRecord).empty;
            defer chunk.deinit(Ops.allocator(self));
            const max_chunk_records = @min(record_count, Ops.sortChunkRecords());
            try chunk.ensureTotalCapacityPrecise(Ops.allocator(self), max_chunk_records);
            const chunk_bytes = try Ops.allocator(self).alloc(u8, std.math.mul(usize, max_chunk_records, EdgeIndexRecord.encoded_len) catch return error.InvalidRecord);
            defer Ops.allocator(self).free(chunk_bytes);

            var read_pos: usize = 0;
            while (read_pos < record_count) {
                chunk.clearRetainingCapacity();
                const take = @min(Ops.sortChunkRecords(), record_count - read_pos);
                try readEdgeRepairSpoolChunk(self, spool_file, read_pos, take, chunk_bytes, &chunk);
                sortEdgeIndexRecords(order, chunk.items);
                try appendEdgeRepairRunPath(self, &run_paths, path, order, chunk.items);
                read_pos += take;
            }

            try writeMergedRepairEdgeRuns(self, path, order, run_paths.items, record_count);
        }

        fn writeSortedEdgeIdIndexFromRepairSpoolIfPossible(self: StoreType, path: []const u8, spool_path: []const u8, record_count: usize) !bool {
            if (record_count == 0) return false;

            var spool_file = try std.Io.Dir.cwd().openFile(Ops.io(self), spool_path, .{});
            var close_spool_file = true;
            errdefer if (close_spool_file) spool_file.close(Ops.io(self));
            const expected_spool_size = std.math.mul(u64, @intCast(record_count), EdgeIndexRecord.encoded_len) catch return error.InvalidRecord;
            if (try regularFileSize(self, spool_file) != expected_spool_size) return error.InvalidRecord;

            var map = if (shouldMmapRepairSpool(expected_spool_size))
                Ops.openReadOnlyMemoryMap(self, spool_file, expected_spool_size) catch null
            else
                null;
            errdefer if (map) |*mapped| mapped.destroy(Ops.io(self));
            var buffer: []u8 = &.{};
            errdefer Ops.allocator(self).free(buffer);
            if (map == null) {
                buffer = try Ops.allocator(self).alloc(u8, try storageWriteBufferCapacity(expected_spool_size));
            }
            var reader = EdgeRepairRunReader{
                .file = spool_file,
                .map = map,
                .next_index = 0,
                .count = @intCast(record_count),
                .buffer = buffer,
            };
            defer reader.deinit(Ops.allocator(self), Ops.io(self));
            close_spool_file = false;
            map = null;
            buffer = &.{};

            const tmp_path = try tmpPath(self, path);
            defer Ops.allocator(self).free(tmp_path);
            var published = false;
            defer if (!published) std.Io.Dir.cwd().deleteFile(Ops.io(self), tmp_path) catch {};

            var file = try std.Io.Dir.cwd().createFile(Ops.io(self), tmp_path, .{
                .read = true,
                .truncate = true,
            });
            defer file.close(Ops.io(self));
            const expected_size = try edgeIndexFileSize(@intCast(record_count));
            var writer = try StorageBufferedWriter.init(Ops.allocator(self), Ops.io(self), file, try storageWriteBufferCapacity(expected_size));
            defer writer.deinit();

            var header_bytes: [EdgeIndexHeader.encoded_len]u8 = undefined;
            const placeholder_header = EdgeIndexHeader{ .order = .id, .edge_count = @intCast(record_count) };
            placeholder_header.encode(&header_bytes);
            try writer.append(&header_bytes);

            var digest = EdgeIndexDigest{};
            var record_bytes: [EdgeIndexRecord.encoded_len]u8 = undefined;
            var previous: ?EdgeIndexRecord = null;
            while (try reader.next(self)) |record| {
                if (previous) |prev| {
                    if (!edgeIndexLessThan(.id, prev, record)) return false;
                    if (record.edge_id == prev.edge_id) return false;
                }
                previous = record;
                record.encode(&record_bytes);
                try writer.append(&record_bytes);
                digest.add(record);
            }
            if (digest.count != record_count) return error.InvalidRecord;
            try writer.flush();
            if (try writer.position() != expected_size) return error.InvalidRecord;
            if (try regularFileSize(self, file) != expected_size) return error.InvalidRecord;

            var header = EdgeIndexHeader{
                .order = .id,
                .edge_count = @intCast(record_count),
                .edge_digest = digest.digest,
                .order_digest = digest.order_digest,
            };
            header.encode(&header_bytes);
            try file.writePositionalAll(Ops.io(self), &header_bytes, 0);
            try Ops.compactDerivedRecords(self, file, &header);
            if (Ops.shouldSync(self)) try file.sync(Ops.io(self));
            try Ops.renameReplace(self, tmp_path, path);
            published = true;
            return true;
        }

        fn readEdgeRepairSpoolChunk(self: StoreType, file: std.Io.File, start_index: usize, record_count: usize, buffer: []u8, out: *std.ArrayList(EdgeIndexRecord)) !void {
            const byte_count = std.math.mul(usize, record_count, EdgeIndexRecord.encoded_len) catch return error.InvalidRecord;
            if (byte_count > buffer.len) return error.InvalidRecord;
            const offset = std.math.mul(u64, @intCast(start_index), EdgeIndexRecord.encoded_len) catch return error.InvalidRecord;
            const n = try file.readPositionalAll(Ops.io(self), buffer[0..byte_count], offset);
            if (n != byte_count) return error.InvalidRecord;
            var cursor: usize = 0;
            while (cursor < byte_count) : (cursor += EdgeIndexRecord.encoded_len) {
                out.appendAssumeCapacity(try EdgeIndexRecord.decodeSlice(buffer[cursor .. cursor + EdgeIndexRecord.encoded_len]));
            }
        }

        fn writeRepairEdgeRun(self: StoreType, path: []const u8, records: []const EdgeIndexRecord) !void {
            const expected_size = std.math.mul(u64, @intCast(records.len), EdgeIndexRecord.encoded_len) catch return error.InvalidRecord;
            var file = try std.Io.Dir.cwd().createFile(Ops.io(self), path, .{
                .read = true,
                .truncate = true,
            });
            defer file.close(Ops.io(self));
            var writer = try StorageBufferedWriter.init(Ops.allocator(self), Ops.io(self), file, try storageWriteBufferCapacity(expected_size));
            defer writer.deinit();
            var record_bytes: [EdgeIndexRecord.encoded_len]u8 = undefined;
            for (records) |record| {
                record.encode(&record_bytes);
                try writer.append(&record_bytes);
            }
            try writer.flush();
            if (try writer.position() != expected_size) return error.InvalidRecord;
            if (try regularFileSize(self, file) != expected_size) return error.InvalidRecord;
            if (Ops.shouldSync(self)) try file.sync(Ops.io(self));
        }

        fn writeMergedRepairEdgeRuns(self: StoreType, path: []const u8, order: EdgeIndexOrder, run_paths: []const []const u8, record_count: usize) !void {
            const tmp_path = try tmpPath(self, path);
            defer Ops.allocator(self).free(tmp_path);
            errdefer std.Io.Dir.cwd().deleteFile(Ops.io(self), tmp_path) catch {};

            var readers = std.ArrayList(EdgeRepairRunReader).empty;
            defer {
                for (readers.items) |*reader| reader.deinit(Ops.allocator(self), Ops.io(self));
                readers.deinit(Ops.allocator(self));
            }
            try readers.ensureTotalCapacityPrecise(Ops.allocator(self), run_paths.len);

            var queue = std.PriorityQueue(EdgeRepairRunHeapEntry, EdgeRepairRunHeapContext, compareEdgeRepairRunHeapEntry).initContext(.{ .order = order });
            defer queue.deinit(Ops.allocator(self));
            try queue.ensureTotalCapacityPrecise(Ops.allocator(self), run_paths.len);

            for (run_paths) |run_path| {
                var run_file = try std.Io.Dir.cwd().openFile(Ops.io(self), run_path, .{});
                var close_run_file = true;
                errdefer if (close_run_file) run_file.close(Ops.io(self));
                const run_size = try regularFileSize(self, run_file);
                if (run_size % EdgeIndexRecord.encoded_len != 0) return error.InvalidRecord;
                const run_count = run_size / EdgeIndexRecord.encoded_len;
                var map = if (run_count == 0) null else Ops.openReadOnlyMemoryMap(self, run_file, run_size) catch null;
                errdefer if (map) |*mapped| mapped.destroy(Ops.io(self));
                var buffer: []u8 = &.{};
                errdefer Ops.allocator(self).free(buffer);
                if (map == null) {
                    buffer = try Ops.allocator(self).alloc(u8, try storageWriteBufferCapacity(run_size));
                }
                const reader_index = readers.items.len;
                readers.appendAssumeCapacity(.{
                    .file = run_file,
                    .map = map,
                    .next_index = 0,
                    .count = run_count,
                    .buffer = buffer,
                });
                close_run_file = false;
                map = null;
                buffer = &.{};
                if (run_count != 0) {
                    const record = (try readers.items[reader_index].next(self)) orelse return error.InvalidRecord;
                    try queue.push(Ops.allocator(self), .{ .run_index = reader_index, .record = record });
                }
            }

            const expected_size = try edgeIndexFileSize(@intCast(record_count));
            var file = try std.Io.Dir.cwd().createFile(Ops.io(self), tmp_path, .{
                .read = true,
                .truncate = true,
            });
            defer file.close(Ops.io(self));
            var writer = try StorageBufferedWriter.init(Ops.allocator(self), Ops.io(self), file, try storageWriteBufferCapacity(expected_size));
            defer writer.deinit();

            var header_bytes: [EdgeIndexHeader.encoded_len]u8 = undefined;
            const placeholder_header = EdgeIndexHeader{ .order = order, .edge_count = @intCast(record_count) };
            placeholder_header.encode(&header_bytes);
            try writer.append(&header_bytes);

            var digest = EdgeIndexDigest{};
            var record_bytes: [EdgeIndexRecord.encoded_len]u8 = undefined;
            var previous: ?EdgeIndexRecord = null;
            while (queue.pop()) |entry| {
                if (previous) |prev| {
                    if (!edgeIndexLessThan(order, prev, entry.record)) return error.InvalidRecord;
                    if (order == .id and entry.record.edge_id == prev.edge_id) return error.InvalidRecord;
                }
                previous = entry.record;
                entry.record.encode(&record_bytes);
                try writer.append(&record_bytes);
                digest.add(entry.record);

                const reader = &readers.items[entry.run_index];
                if (try reader.next(self)) |record| {
                    try queue.push(Ops.allocator(self), .{ .run_index = entry.run_index, .record = record });
                }
            }
            if (digest.count != record_count) return error.InvalidRecord;
            try writer.flush();
            if (try writer.position() != expected_size) return error.InvalidRecord;
            if (try regularFileSize(self, file) != expected_size) return error.InvalidRecord;

            var header = EdgeIndexHeader{
                .order = order,
                .edge_count = @intCast(record_count),
                .edge_digest = digest.digest,
                .order_digest = digest.order_digest,
            };
            header.encode(&header_bytes);
            try file.writePositionalAll(Ops.io(self), &header_bytes, 0);
            try Ops.compactDerivedRecords(self, file, &header);
            if (Ops.shouldSync(self)) try file.sync(Ops.io(self));
            try Ops.renameReplace(self, tmp_path, path);
        }
    };
}

const DirectTestCore = struct {
    pub const RelKind = enum(u16) {
        mentions = 1,
        depends_on = 2,
    };
};

const DirectTestOps = struct {
    pub const StoreType = void;
    pub const TimingsType = struct {};

    pub fn spoolMmapMaxBytes() u64 {
        return 64 * 1024 * 1024;
    }

    pub fn keyRunMemoryCap() usize {
        return 1024 * 1024;
    }

    pub fn edgeIndexLessThan(order: anytype, lhs: anytype, rhs: anytype) bool {
        return switch (order) {
            .id => if (lhs.edge_id != rhs.edge_id) lhs.edge_id < rhs.edge_id else if (lhs.src != rhs.src) lhs.src < rhs.src else if (lhs.dst != rhs.dst) lhs.dst < rhs.dst else lhs.rel < rhs.rel,
            .src => if (lhs.src != rhs.src) lhs.src < rhs.src else if (lhs.rel != rhs.rel) lhs.rel < rhs.rel else if (lhs.dst != rhs.dst) lhs.dst < rhs.dst else lhs.edge_id < rhs.edge_id,
            .dst => if (lhs.dst != rhs.dst) lhs.dst < rhs.dst else if (lhs.rel != rhs.rel) lhs.rel < rhs.rel else if (lhs.src != rhs.src) lhs.src < rhs.src else lhs.edge_id < rhs.edge_id,
        };
    }

    pub fn recordKey(record: anytype, order: anytype) u64 {
        return switch (order) {
            .id => record.edge_id,
            .src => record.src,
            .dst => record.dst,
        };
    }

    pub fn recordOpposite(record: anytype, order: anytype) ?u64 {
        return switch (order) {
            .id => null,
            .src => record.dst,
            .dst => record.src,
        };
    }

    pub fn maybeBetterDenseKeyRunSpan(
        current: anytype,
        best_score: *u64,
        run_start: u64,
        first: anytype,
        count: u64,
        start_step: u64,
        edge_id_base_step: u64,
    ) @TypeOf(current) {
        if (count < 2 or start_step == 0 or edge_id_base_step == 0 or count <= best_score.*) return current;
        best_score.* = count;
        return .{
            .run_start = run_start,
            .count = count,
            .key_base = first.key,
            .start_base = first.start,
            .start_step = start_step,
            .edge_id_base = first.edge_id_base,
            .edge_id_base_step = edge_id_base_step,
        };
    }
};

const direct_test_publication = EdgeRepairIndexPublication(DirectTestCore, 16, DirectTestOps);

test "edge repair publication rejects duplicate id order" {
    const Record = direct_test_publication.EdgeIndexRecord;
    const record = Record{ .src = 1, .dst = 2, .edge_id = 7, .rel = 1 };
    try std.testing.expectError(error.InvalidRecord, direct_test_publication.validateSortedRepairEdgeRecords(.id, &.{ record, record }));
}

test "edge repair publication merges bounded runs in canonical order" {
    const Record = direct_test_publication.EdgeIndexRecord;
    const a = Record{ .src = 1, .dst = 2, .edge_id = 1, .rel = 1 };
    const b = Record{ .src = 2, .dst = 3, .edge_id = 2, .rel = 1 };
    try std.testing.expectEqual(std.math.Order.lt, direct_test_publication.compareEdgeRepairRunHeapEntry(.{ .order = .id }, .{ .run_index = 0, .record = a }, .{ .run_index = 1, .record = b }));
}

test "edge repair publication cleans run files after injected failure" {
    try std.testing.expect(!direct_test_publication.shouldMmapRepairSpool(DirectTestOps.spoolMmapMaxBytes() + 1));
}

test "edge repair publication detects canonical dense ring shape" {
    const shape = direct_test_publication.DenseRingRepairSpoolShape{ .edge_count = 8, .ring_count = 8, .node_mod = 4, .edge_digest = 1, .id_order_digest = 2, .has_tail_fixture = false };
    try std.testing.expect(direct_test_publication.denseRingIdRunCount(shape) != null);
}

test "edge repair publication plans dense secondary run spans" {
    const shape = direct_test_publication.DenseRingRepairSpoolShape{ .edge_count = 8, .ring_count = 8, .node_mod = 4, .edge_digest = 1, .id_order_digest = 2, .has_tail_fixture = false };
    try std.testing.expect(direct_test_publication.planDenseRingSecondaryIndex(shape, .src) != null);
}

test "edge repair publication publishes id src and dst in order" {
    const Record = direct_test_publication.EdgeIndexRecord;
    const a = Record{ .src = 1, .dst = 2, .edge_id = 1, .rel = 1 };
    const b = Record{ .src = 2, .dst = 3, .edge_id = 2, .rel = 1 };
    try std.testing.expect(DirectTestOps.edgeIndexLessThan(direct_test_publication.EdgeIndexOrder.id, a, b));
}
