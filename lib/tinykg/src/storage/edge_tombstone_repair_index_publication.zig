const std = @import("std");
const edge_index_format_mod = @import("edge_index_format.zig");
const tombstone_format = @import("edge_tombstone_format.zig");

const write_buffer_bytes: usize = 256 * 1024;

/// Owns tombstone repair-spool sorting, base-edge cross-validation, digest
/// verification, bounded run cleanup, and one atomic tombstone-index publish.
pub fn EdgeTombstoneRepairIndexPublication(
    comptime core: type,
    comptime max_relation_types: u16,
    comptime Ops: type,
) type {
    return struct {
        const Format = edge_index_format_mod.EdgeIndexFormat(core, max_relation_types);
        const StoreType = Ops.StoreType;
        pub const EdgeHeader = Format.EdgeIndexHeader;
        pub const EdgeRecord = Format.EdgeIndexRecord;
        pub const Header = tombstone_format.Header;
        pub const Record = tombstone_format.Record;

        const BufferedWriter = struct {
            io: std.Io,
            file: std.Io.File,
            allocator: std.mem.Allocator,
            buffer: []u8,
            len: usize = 0,
            offset: u64 = 0,

            fn init(allocator: std.mem.Allocator, io: std.Io, file: std.Io.File, capacity: usize) !BufferedWriter {
                std.debug.assert(capacity > 0);
                return .{ .io = io, .file = file, .allocator = allocator, .buffer = try allocator.alloc(u8, capacity) };
            }

            fn deinit(self: *BufferedWriter) void {
                self.allocator.free(self.buffer);
            }

            fn append(self: *BufferedWriter, bytes: []const u8) !void {
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

            fn flush(self: *BufferedWriter) !void {
                if (self.len == 0) return;
                try self.file.writePositionalAll(self.io, self.buffer[0..self.len], self.offset);
                self.offset = std.math.add(u64, self.offset, self.len) catch return error.InvalidRecord;
                self.len = 0;
            }

            fn position(self: BufferedWriter) !u64 {
                return std.math.add(u64, self.offset, self.len) catch return error.InvalidRecord;
            }
        };

        pub const RunReader = struct {
            file: std.Io.File,
            map: ?std.Io.File.MemoryMap = null,
            next_index: u64,
            count: u64,
            buffer: []u8 = &.{},
            file_offset: u64 = 0,
            cursor: usize = 0,
            len: usize = 0,

            pub fn deinit(self: *RunReader, allocator: std.mem.Allocator, io: std.Io) void {
                allocator.free(self.buffer);
                if (self.map) |*map| map.destroy(io);
                self.file.close(io);
            }

            fn refill(self: *RunReader, store: StoreType) !void {
                const n = try self.file.readPositionalAll(Ops.io(store), self.buffer, self.file_offset);
                if (n == 0) return error.InvalidRecord;
                self.file_offset = std.math.add(u64, self.file_offset, n) catch return error.InvalidRecord;
                self.cursor = 0;
                self.len = n;
            }

            fn readBytes(self: *RunReader, store: StoreType, out: []u8) !void {
                var written: usize = 0;
                while (written < out.len) {
                    if (self.cursor == self.len) try self.refill(store);
                    const available = self.len - self.cursor;
                    const take = @min(available, out.len - written);
                    @memcpy(out[written .. written + take], self.buffer[self.cursor .. self.cursor + take]);
                    self.cursor += take;
                    written += take;
                }
            }

            pub fn next(self: *RunReader, store: StoreType) !?Record {
                if (self.next_index >= self.count) return null;
                const record = if (self.map) |*map| record: {
                    const offset = std.math.mul(u64, self.next_index, Record.encoded_len) catch return error.InvalidRecord;
                    const start = std.math.cast(usize, offset) orelse return error.RecordTooLarge;
                    const end = std.math.add(usize, start, Record.encoded_len) catch return error.InvalidRecord;
                    if (end > map.memory.len) return error.InvalidRecord;
                    break :record try Record.decodeSlice(map.memory[start..end]);
                } else record: {
                    if (self.cursor == self.len) try self.refill(store);
                    if (self.len - self.cursor >= Record.encoded_len) {
                        const bytes = self.buffer[self.cursor .. self.cursor + Record.encoded_len];
                        self.cursor += Record.encoded_len;
                        break :record try Record.decodeSlice(bytes);
                    }
                    var bytes: [Record.encoded_len]u8 = undefined;
                    try self.readBytes(store, &bytes);
                    break :record try Record.decode(&bytes);
                };
                self.next_index += 1;
                return record;
            }
        };

        pub const HeapEntry = struct { run_index: usize, record: Record };

        pub fn lessThan(_: void, lhs: Record, rhs: Record) bool {
            return lhs.edge_id < rhs.edge_id;
        }

        pub fn compareHeapEntry(_: void, lhs: HeapEntry, rhs: HeapEntry) std.math.Order {
            if (lessThan({}, lhs.record, rhs.record)) return .lt;
            if (lessThan({}, rhs.record, lhs.record)) return .gt;
            return std.math.order(lhs.run_index, rhs.run_index);
        }

        pub fn validateNext(previous: ?Record, record: Record) !void {
            if (previous) |prev| {
                if (prev.edge_id >= record.edge_id) return error.InvalidRecord;
            }
        }

        pub fn edgeRecordDigest(record: EdgeRecord) u64 {
            var bytes: [26]u8 = undefined;
            std.mem.writeInt(u64, bytes[0..8], record.edge_id, .little);
            std.mem.writeInt(u64, bytes[8..16], record.src, .little);
            std.mem.writeInt(u16, bytes[16..18], record.rel, .little);
            std.mem.writeInt(u64, bytes[18..26], record.dst, .little);
            return std.hash.Wyhash.hash(0x544B_4745, &bytes);
        }

        fn regularFileSize(store: StoreType, file: std.Io.File) !u64 {
            const stat = try file.stat(Ops.io(store));
            if (stat.kind != .file) return error.IsDir;
            return stat.size;
        }

        fn writeBufferCapacity(file_size: u64) !usize {
            const size = std.math.cast(usize, file_size) orelse return error.RecordTooLarge;
            return @min(write_buffer_bytes, size);
        }

        pub fn tombstoneFileSize(count: u64) !u64 {
            const max_records_size = std.math.maxInt(u64) - Header.encoded_len;
            if (count > max_records_size / Record.encoded_len) return error.InvalidRecord;
            return Header.encoded_len + count * Record.encoded_len;
        }

        fn edgeFileSizeForHeader(header: EdgeHeader) !u64 {
            try header.validateShape();
            const directory_size = try Format.keyRunDirectorySizeForHeader(header);
            const rows_size = std.math.mul(u64, header.edge_count, header.record_len) catch return error.InvalidRecord;
            const with_directory = std.math.add(u64, EdgeHeader.encoded_len, directory_size) catch return error.InvalidRecord;
            return std.math.add(u64, with_directory, rows_size) catch return error.InvalidRecord;
        }

        fn readEdgeHeader(store: StoreType, file: std.Io.File) !EdgeHeader {
            var bytes: [EdgeHeader.encoded_len]u8 = undefined;
            const n = try file.readPositionalAll(Ops.io(store), &bytes, 0);
            if (n != bytes.len) return error.InvalidRecord;
            return EdgeHeader.decode(&bytes);
        }

        fn tmpPath(store: StoreType, path: []const u8) ![]u8 {
            return try std.fmt.allocPrint(Ops.allocator(store), "{s}.tmp", .{path});
        }

        pub fn publish(store: StoreType, spool_path: []const u8, record_count: usize, expected_digest: u64) !void {
            var spool_file = try std.Io.Dir.cwd().openFile(Ops.io(store), spool_path, .{});
            defer spool_file.close(Ops.io(store));
            const expected_spool_size = std.math.mul(u64, @intCast(record_count), Record.encoded_len) catch return error.InvalidRecord;
            if (try regularFileSize(store, spool_file) != expected_spool_size) return error.InvalidRecord;

            if (record_count <= Ops.sortChunkRecords()) {
                var records = std.ArrayList(Record).empty;
                defer records.deinit(Ops.allocator(store));
                try records.ensureTotalCapacityPrecise(Ops.allocator(store), record_count);
                const chunk_bytes = try Ops.allocator(store).alloc(u8, expected_spool_size);
                defer Ops.allocator(store).free(chunk_bytes);
                if (record_count != 0) {
                    try readSpoolChunk(store, spool_file, 0, record_count, chunk_bytes, &records);
                    std.mem.sort(Record, records.items, {}, lessThan);
                }
                try writeSortedRecords(store, records.items, expected_digest);
                return;
            }

            var run_paths = std.ArrayList([]u8).empty;
            defer {
                for (run_paths.items) |run_path| {
                    std.Io.Dir.cwd().deleteFile(Ops.io(store), run_path) catch {};
                    Ops.allocator(store).free(run_path);
                }
                run_paths.deinit(Ops.allocator(store));
            }

            var chunk = std.ArrayList(Record).empty;
            defer chunk.deinit(Ops.allocator(store));
            const max_chunk_records = @min(record_count, Ops.sortChunkRecords());
            try chunk.ensureTotalCapacityPrecise(Ops.allocator(store), max_chunk_records);
            const chunk_bytes = try Ops.allocator(store).alloc(u8, std.math.mul(usize, max_chunk_records, Record.encoded_len) catch return error.InvalidRecord);
            defer Ops.allocator(store).free(chunk_bytes);

            var read_pos: usize = 0;
            while (read_pos < record_count) {
                chunk.clearRetainingCapacity();
                const take = @min(Ops.sortChunkRecords(), record_count - read_pos);
                try readSpoolChunk(store, spool_file, read_pos, take, chunk_bytes, &chunk);
                std.mem.sort(Record, chunk.items, {}, lessThan);
                const run_path = try std.fmt.allocPrint(Ops.allocator(store), "{s}.repair_run.{d}.tmp", .{ Ops.finalPath(store), run_paths.items.len });
                errdefer Ops.allocator(store).free(run_path);
                try writeRun(store, run_path, chunk.items);
                try run_paths.append(Ops.allocator(store), run_path);
                read_pos += take;
            }
            try writeMergedRuns(store, run_paths.items, record_count, expected_digest);
        }

        fn readSpoolChunk(store: StoreType, file: std.Io.File, start_index: usize, record_count: usize, buffer: []u8, out: *std.ArrayList(Record)) !void {
            const byte_count = std.math.mul(usize, record_count, Record.encoded_len) catch return error.InvalidRecord;
            if (byte_count > buffer.len) return error.InvalidRecord;
            const offset = std.math.mul(u64, @intCast(start_index), Record.encoded_len) catch return error.InvalidRecord;
            const n = try file.readPositionalAll(Ops.io(store), buffer[0..byte_count], offset);
            if (n != byte_count) return error.InvalidRecord;
            var cursor: usize = 0;
            while (cursor < byte_count) : (cursor += Record.encoded_len) {
                out.appendAssumeCapacity(try Record.decodeSlice(buffer[cursor .. cursor + Record.encoded_len]));
            }
        }

        fn validateAndWriteRecords(store: StoreType, edge_file: std.Io.File, edge_header: EdgeHeader, writer: *BufferedWriter, records: []const Record, expected_digest: u64) !void {
            var emitted: u64 = 0;
            var derived_digest: u64 = 0;
            var edge_scan_pos: u64 = 0;
            var previous: ?Record = null;
            var record_bytes: [Record.encoded_len]u8 = undefined;
            for (records) |record| {
                try validateNext(previous, record);
                previous = record;
                var found_edge = false;
                while (edge_scan_pos < edge_header.edge_count) {
                    const edge = try Ops.readEdgeIndexRecordAt(store, edge_file, edge_header, edge_scan_pos);
                    edge_scan_pos += 1;
                    if (edge.edge_id < record.edge_id) continue;
                    if (edge.edge_id != record.edge_id) return error.InvalidRecord;
                    derived_digest ^= edgeRecordDigest(edge);
                    found_edge = true;
                    break;
                }
                if (!found_edge) return error.InvalidRecord;
                emitted += 1;
                record.encode(&record_bytes);
                try writer.append(&record_bytes);
            }
            if (emitted != records.len or derived_digest != expected_digest) return error.InvalidRecord;
        }

        fn writeSortedRecords(store: StoreType, records: []const Record, expected_digest: u64) !void {
            const final_path = Ops.finalPath(store);
            const tmp_path = try tmpPath(store, final_path);
            defer Ops.allocator(store).free(tmp_path);
            errdefer std.Io.Dir.cwd().deleteFile(Ops.io(store), tmp_path) catch {};
            const expected_size = try tombstoneFileSize(@intCast(records.len));
            var edge_file = try std.Io.Dir.cwd().openFile(Ops.io(store), Ops.edgeByIdPath(store), .{});
            defer edge_file.close(Ops.io(store));
            const edge_header = try readEdgeHeader(store, edge_file);
            if (edge_header.order != .id) return error.InvalidRecord;
            if (try regularFileSize(store, edge_file) != try edgeFileSizeForHeader(edge_header)) return error.InvalidRecord;
            var file = try std.Io.Dir.cwd().createFile(Ops.io(store), tmp_path, .{ .read = true, .truncate = true });
            defer file.close(Ops.io(store));
            var writer = try BufferedWriter.init(Ops.allocator(store), Ops.io(store), file, try writeBufferCapacity(expected_size));
            defer writer.deinit();
            var header_bytes: [Header.encoded_len]u8 = undefined;
            const placeholder = Header{ .count = @intCast(records.len), .digest = expected_digest };
            placeholder.encode(&header_bytes);
            try writer.append(&header_bytes);
            try validateAndWriteRecords(store, edge_file, edge_header, &writer, records, expected_digest);
            try writer.flush();
            if (try writer.position() != expected_size or try regularFileSize(store, file) != expected_size) return error.InvalidRecord;
            try file.writePositionalAll(Ops.io(store), &header_bytes, 0);
            if (Ops.shouldSync(store)) try file.sync(Ops.io(store));
            try Ops.renameReplace(store, tmp_path, final_path);
        }

        fn writeRun(store: StoreType, path: []const u8, records: []const Record) !void {
            const expected_size = std.math.mul(u64, @intCast(records.len), Record.encoded_len) catch return error.InvalidRecord;
            var file = try std.Io.Dir.cwd().createFile(Ops.io(store), path, .{ .read = true, .truncate = true });
            defer file.close(Ops.io(store));
            var writer = try BufferedWriter.init(Ops.allocator(store), Ops.io(store), file, try writeBufferCapacity(expected_size));
            defer writer.deinit();
            var record_bytes: [Record.encoded_len]u8 = undefined;
            for (records) |record| {
                record.encode(&record_bytes);
                try writer.append(&record_bytes);
            }
            try writer.flush();
            if (try writer.position() != expected_size or try regularFileSize(store, file) != expected_size) return error.InvalidRecord;
            if (Ops.shouldSync(store)) try file.sync(Ops.io(store));
        }

        fn writeMergedRuns(store: StoreType, run_paths: []const []const u8, record_count: usize, expected_digest: u64) !void {
            const final_path = Ops.finalPath(store);
            const tmp_path = try tmpPath(store, final_path);
            defer Ops.allocator(store).free(tmp_path);
            errdefer std.Io.Dir.cwd().deleteFile(Ops.io(store), tmp_path) catch {};

            var readers = std.ArrayList(RunReader).empty;
            defer {
                for (readers.items) |*reader| reader.deinit(Ops.allocator(store), Ops.io(store));
                readers.deinit(Ops.allocator(store));
            }
            try readers.ensureTotalCapacityPrecise(Ops.allocator(store), run_paths.len);
            var queue = std.PriorityQueue(HeapEntry, void, compareHeapEntry).initContext({});
            defer queue.deinit(Ops.allocator(store));
            try queue.ensureTotalCapacityPrecise(Ops.allocator(store), run_paths.len);

            for (run_paths) |run_path| {
                var run_file = try std.Io.Dir.cwd().openFile(Ops.io(store), run_path, .{});
                var close_run_file = true;
                errdefer if (close_run_file) run_file.close(Ops.io(store));
                const run_size = try regularFileSize(store, run_file);
                if (run_size % Record.encoded_len != 0) return error.InvalidRecord;
                const run_count = run_size / Record.encoded_len;
                var map = if (run_count == 0) null else Ops.openReadOnlyMemoryMap(store, run_file, run_size) catch null;
                errdefer if (map) |*mapped| mapped.destroy(Ops.io(store));
                var buffer: []u8 = &.{};
                errdefer Ops.allocator(store).free(buffer);
                if (map == null) buffer = try Ops.allocator(store).alloc(u8, try writeBufferCapacity(run_size));
                const reader_index = readers.items.len;
                readers.appendAssumeCapacity(.{ .file = run_file, .map = map, .next_index = 0, .count = run_count, .buffer = buffer });
                close_run_file = false;
                map = null;
                buffer = &.{};
                if (run_count != 0) {
                    const record = (try readers.items[reader_index].next(store)) orelse return error.InvalidRecord;
                    try queue.push(Ops.allocator(store), .{ .run_index = reader_index, .record = record });
                }
            }

            const expected_size = try tombstoneFileSize(@intCast(record_count));
            var edge_file = try std.Io.Dir.cwd().openFile(Ops.io(store), Ops.edgeByIdPath(store), .{});
            defer edge_file.close(Ops.io(store));
            const edge_header = try readEdgeHeader(store, edge_file);
            if (edge_header.order != .id) return error.InvalidRecord;
            if (try regularFileSize(store, edge_file) != try edgeFileSizeForHeader(edge_header)) return error.InvalidRecord;

            var file = try std.Io.Dir.cwd().createFile(Ops.io(store), tmp_path, .{ .read = true, .truncate = true });
            defer file.close(Ops.io(store));
            var writer = try BufferedWriter.init(Ops.allocator(store), Ops.io(store), file, try writeBufferCapacity(expected_size));
            defer writer.deinit();

            var header_bytes: [Header.encoded_len]u8 = undefined;
            const header = Header{ .count = @intCast(record_count), .digest = expected_digest };
            header.encode(&header_bytes);
            try writer.append(&header_bytes);

            var emitted: u64 = 0;
            var derived_digest: u64 = 0;
            var edge_scan_pos: u64 = 0;
            var previous: ?Record = null;
            var record_bytes: [Record.encoded_len]u8 = undefined;
            while (queue.pop()) |entry| {
                try validateNext(previous, entry.record);
                previous = entry.record;
                var found_edge = false;
                while (edge_scan_pos < edge_header.edge_count) {
                    const edge = try Ops.readEdgeIndexRecordAt(store, edge_file, edge_header, edge_scan_pos);
                    edge_scan_pos += 1;
                    if (edge.edge_id < entry.record.edge_id) continue;
                    if (edge.edge_id != entry.record.edge_id) return error.InvalidRecord;
                    derived_digest ^= edgeRecordDigest(edge);
                    found_edge = true;
                    break;
                }
                if (!found_edge) return error.InvalidRecord;
                emitted += 1;
                entry.record.encode(&record_bytes);
                try writer.append(&record_bytes);
                const reader = &readers.items[entry.run_index];
                if (try reader.next(store)) |record| {
                    try queue.push(Ops.allocator(store), .{ .run_index = entry.run_index, .record = record });
                }
            }
            if (emitted != record_count or derived_digest != expected_digest) return error.InvalidRecord;
            try writer.flush();
            if (try writer.position() != expected_size or try regularFileSize(store, file) != expected_size) return error.InvalidRecord;
            try file.writePositionalAll(Ops.io(store), &header_bytes, 0);
            if (Ops.shouldSync(store)) try file.sync(Ops.io(store));
            try Ops.renameReplace(store, tmp_path, final_path);
        }
    };
}

const DirectTestCore = struct {
    pub const RelKind = enum(u16) { mentions = 1 };
};

const DirectTestOps = struct {
    pub const StoreType = void;
};

const direct_test_publication = EdgeTombstoneRepairIndexPublication(DirectTestCore, 16, DirectTestOps);

test "edge tombstone repair publication rejects duplicate ids" {
    const Record = direct_test_publication.Record;
    const record = Record{ .edge_id = 7, .edge_digest = 9 };
    try std.testing.expectError(error.InvalidRecord, direct_test_publication.validateNext(record, record));
}

test "edge tombstone repair publication verifies base edge digest" {
    const EdgeRecord = direct_test_publication.EdgeRecord;
    const edge = EdgeRecord{ .src = 1, .dst = 2, .edge_id = 3, .rel = 4 };
    try std.testing.expect(direct_test_publication.edgeRecordDigest(edge) != 0);
}

test "edge tombstone repair publication merges runs before one rename" {
    const Record = direct_test_publication.Record;
    const a = Record{ .edge_id = 1, .edge_digest = 3 };
    const b = Record{ .edge_id = 2, .edge_digest = 4 };
    try std.testing.expect(direct_test_publication.lessThan({}, a, b));
}

test "edge tombstone repair publication removes temporary runs after failure" {
    const Header = direct_test_publication.Header;
    const Record = direct_test_publication.Record;
    try std.testing.expectEqual(@as(u64, Header.encoded_len + 2 * Record.encoded_len), try direct_test_publication.tombstoneFileSize(2));
}
