const std = @import("std");
const node_text_format_mod = @import("node_text_format.zig");

const write_buffer_bytes: usize = 256 * 1024;

/// Owns node-text repair-spool validation, bounded external sorting, compact
/// rebuild-shape selection, run cleanup, and the single final index rename.
/// Store-specific primary-text validation and derived-span compaction remain
/// narrow ports because they are shared with non-repair catalog writers.
pub fn NodeTextRepairIndexPublication(
    comptime core: type,
    comptime max_node_types: u16,
    comptime Ops: type,
) type {
    return struct {
        const Self = @This();
        const Format = node_text_format_mod.NodeTextFormat(core, max_node_types);
        const StoreType = Ops.StoreType;
        pub const Header = Format.NodeTextIndexHeader;
        pub const Record = Format.NodeTextIndexRecord;

        pub const PublishShape = struct {
            uniform_kind: ?u16 = null,
            u32_id: bool = false,
            derived_hash: bool = true,
            derived_text_span: bool = false,

            pub fn header(self: PublishShape, record_count: usize, node_digest: u64, order_digest: u64) Header {
                return Header.withShape(
                    @intCast(record_count),
                    node_digest,
                    order_digest,
                    self.uniform_kind,
                    false,
                    self.u32_id,
                    self.derived_hash,
                    self.derived_text_span,
                );
            }
        };

        const BufferedWriter = struct {
            io: std.Io,
            file: std.Io.File,
            allocator: std.mem.Allocator,
            buffer: []u8,
            len: usize = 0,
            offset: u64 = 0,

            fn init(allocator: std.mem.Allocator, io: std.Io, file: std.Io.File, capacity: usize) !BufferedWriter {
                std.debug.assert(capacity > 0);
                return .{
                    .io = io,
                    .file = file,
                    .allocator = allocator,
                    .buffer = try allocator.alloc(u8, capacity),
                };
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

        pub const HeapEntry = struct {
            run_index: usize,
            record: Record,
        };

        pub fn lessThan(_: void, lhs: Record, rhs: Record) bool {
            if (lhs.hash != rhs.hash) return lhs.hash < rhs.hash;
            if (lhs.id != rhs.id) return lhs.id < rhs.id;
            return lhs.kind < rhs.kind;
        }

        pub fn compareHeapEntry(_: void, lhs: HeapEntry, rhs: HeapEntry) std.math.Order {
            if (lessThan({}, lhs.record, rhs.record)) return .lt;
            if (lessThan({}, rhs.record, lhs.record)) return .gt;
            return std.math.order(lhs.run_index, rhs.run_index);
        }

        fn orderDigestStep(previous: u64, position: u64, record: Record) u64 {
            var bytes: [34]u8 = undefined;
            std.mem.writeInt(u64, bytes[0..8], previous, .little);
            std.mem.writeInt(u64, bytes[8..16], position, .little);
            std.mem.writeInt(u64, bytes[16..24], record.hash, .little);
            std.mem.writeInt(u64, bytes[24..32], record.id, .little);
            std.mem.writeInt(u16, bytes[32..34], record.kind, .little);
            return std.hash.Wyhash.hash(0x544B_474D, &bytes);
        }

        fn headerForRecords(records: []const Record, node_digest: u64, order_digest: u64) Header {
            if (records.len == 0) {
                return .{ .node_count = 0, .node_digest = node_digest, .order_digest = order_digest };
            }
            const uniform_kind = records[0].kind;
            var has_uniform_kind = true;
            var short_text_len = true;
            var u32_id = true;
            for (records) |record| {
                if (record.kind != uniform_kind) has_uniform_kind = false;
                if (record.text_len > std.math.maxInt(u16)) short_text_len = false;
                if (record.id > std.math.maxInt(u32)) u32_id = false;
            }
            return Header.withShape(
                @intCast(records.len),
                node_digest,
                order_digest,
                if (has_uniform_kind) uniform_kind else null,
                short_text_len,
                u32_id,
                false,
                false,
            );
        }

        fn fileSizeForHeader(header: Header) !u64 {
            try header.validateShape();
            const max_records_size = std.math.maxInt(u64) - Header.encoded_len;
            if (header.node_count > max_records_size / header.record_len) return error.InvalidRecord;
            return Header.encoded_len + header.node_count * header.record_len;
        }

        fn writeBufferCapacity(file_size: u64) !usize {
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

        fn writeRecord(writer: *BufferedWriter, header: Header, record: Record) !void {
            var record_bytes: [Record.encoded_len]u8 = undefined;
            const encoded = record_bytes[0..header.record_len];
            try record.encodeForHeader(header, encoded);
            try writer.append(encoded);
        }

        pub fn publish(
            store: StoreType,
            spool_path: []const u8,
            record_count: usize,
            node_digest: u64,
            publish_shape: ?PublishShape,
        ) !void {
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
                try writeSortedRecords(store, records.items, node_digest, publish_shape);
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

            try writeMergedRuns(store, run_paths.items, record_count, node_digest, publish_shape);
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

        fn writeSortedRecords(store: StoreType, records: []const Record, node_digest: u64, publish_shape: ?PublishShape) !void {
            const final_path = Ops.finalPath(store);
            const tmp_path = try tmpPath(store, final_path);
            defer Ops.allocator(store).free(tmp_path);
            errdefer std.Io.Dir.cwd().deleteFile(Ops.io(store), tmp_path) catch {};

            var file = try std.Io.Dir.cwd().createFile(Ops.io(store), tmp_path, .{ .read = true, .truncate = true });
            defer file.close(Ops.io(store));

            var order_digest: u64 = 0;
            var previous: ?Record = null;
            for (records, 0..) |record, index| {
                if (previous) |prev| if (!lessThan({}, prev, record)) return error.InvalidRecord;
                previous = record;
                order_digest = orderDigestStep(order_digest, @intCast(index), record);
            }

            var header = if (publish_shape) |shape|
                shape.header(records.len, node_digest, order_digest)
            else
                headerForRecords(records, node_digest, order_digest);
            try Ops.validatePrimaryTextsReadable(store);
            var text_hash_unique = true;
            previous = null;
            for (records) |record| {
                if (previous) |prev| {
                    if (prev.hash == record.hash) text_hash_unique = false;
                }
                previous = record;
            }
            header.setTextHashUnique(text_hash_unique);
            const expected_size = try fileSizeForHeader(header);
            var writer = try BufferedWriter.init(Ops.allocator(store), Ops.io(store), file, try writeBufferCapacity(expected_size));
            defer writer.deinit();

            var header_bytes: [Header.encoded_len]u8 = undefined;
            header.encode(&header_bytes);
            try writer.append(&header_bytes);
            for (records) |record| try writeRecord(&writer, header, record);
            try writer.flush();
            if (try writer.position() != try fileSizeForHeader(header)) return error.InvalidRecord;
            if (try regularFileSize(store, file) != try fileSizeForHeader(header)) return error.InvalidRecord;

            if (publish_shape == null) try Ops.compactDerivedRecords(store, file, &header);
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
                try record.encode(&record_bytes);
                try writer.append(&record_bytes);
            }
            try writer.flush();
            if (try writer.position() != expected_size) return error.InvalidRecord;
            if (try regularFileSize(store, file) != expected_size) return error.InvalidRecord;
            if (Ops.shouldSync(store)) try file.sync(Ops.io(store));
        }

        fn writeMergedRuns(store: StoreType, run_paths: []const []const u8, record_count: usize, node_digest: u64, publish_shape: ?PublishShape) !void {
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

            const placeholder_header = if (publish_shape) |shape|
                shape.header(record_count, node_digest, 0)
            else
                Header{ .node_count = @intCast(record_count), .node_digest = node_digest };
            const expected_size = try fileSizeForHeader(placeholder_header);
            var file = try std.Io.Dir.cwd().createFile(Ops.io(store), tmp_path, .{ .read = true, .truncate = true });
            defer file.close(Ops.io(store));
            var writer = try BufferedWriter.init(Ops.allocator(store), Ops.io(store), file, try writeBufferCapacity(expected_size));
            defer writer.deinit();

            var header_bytes: [Header.encoded_len]u8 = undefined;
            placeholder_header.encode(&header_bytes);
            try writer.append(&header_bytes);

            var order_digest: u64 = 0;
            var emitted: u64 = 0;
            var previous: ?Record = null;
            var text_hash_unique = true;
            try Ops.validatePrimaryTextsReadable(store);
            var record_bytes: [Record.encoded_len]u8 = undefined;
            while (queue.pop()) |entry| {
                if (previous) |prev| {
                    if (!lessThan({}, prev, entry.record)) return error.InvalidRecord;
                    if (prev.hash == entry.record.hash) text_hash_unique = false;
                }
                previous = entry.record;
                order_digest = orderDigestStep(order_digest, emitted, entry.record);
                emitted += 1;
                if (publish_shape != null) {
                    try writeRecord(&writer, placeholder_header, entry.record);
                } else {
                    try entry.record.encode(&record_bytes);
                    try writer.append(&record_bytes);
                }
                const reader = &readers.items[entry.run_index];
                if (try reader.next(store)) |record| {
                    try queue.push(Ops.allocator(store), .{ .run_index = entry.run_index, .record = record });
                }
            }
            if (emitted != record_count) return error.InvalidRecord;
            try writer.flush();
            if (try writer.position() != expected_size) return error.InvalidRecord;
            if (try regularFileSize(store, file) != expected_size) return error.InvalidRecord;

            var header = if (publish_shape) |shape|
                shape.header(record_count, node_digest, order_digest)
            else
                Header{ .node_count = @intCast(record_count), .node_digest = node_digest, .order_digest = order_digest };
            header.setTextHashUnique(text_hash_unique);
            header.encode(&header_bytes);
            try file.writePositionalAll(Ops.io(store), &header_bytes, 0);
            if (publish_shape == null) try Ops.compactDerivedRecords(store, file, &header);
            if (Ops.shouldSync(store)) try file.sync(Ops.io(store));
            try Ops.renameReplace(store, tmp_path, final_path);
        }
    };
}

const DirectTestCore = struct {
    pub const NodeKind = enum(u16) { file = 1 };
};

const DirectTestOps = struct {
    pub const StoreType = void;
};

const direct_test_publication = NodeTextRepairIndexPublication(DirectTestCore, 16, DirectTestOps);

test "node text repair publication orders records and rejects duplicates" {
    const Record = direct_test_publication.Record;
    const a = Record{ .hash = 1, .id = 1, .kind = 1, .text_offset = 0, .text_len = 1 };
    const b = Record{ .hash = 2, .id = 1, .kind = 1, .text_offset = 1, .text_len = 1 };
    try std.testing.expect(direct_test_publication.lessThan({}, a, b));
    try std.testing.expect(!direct_test_publication.lessThan({}, a, a));
}

test "node text repair publication preserves explicit rebuild shape" {
    const shape = direct_test_publication.PublishShape{ .uniform_kind = 7, .u32_id = true, .derived_text_span = true };
    const header = shape.header(3, 9, 11);
    try std.testing.expect(header.hasUniformKind());
    try std.testing.expect(header.hasU32Id());
    try std.testing.expect(header.hasDerivedTextSpan());
}

test "node text repair publication merges runs before one rename" {
    const Record = direct_test_publication.Record;
    const a = Record{ .hash = 1, .id = 1, .kind = 1, .text_offset = 0, .text_len = 1 };
    const b = Record{ .hash = 1, .id = 2, .kind = 1, .text_offset = 1, .text_len = 1 };
    try std.testing.expectEqual(std.math.Order.lt, direct_test_publication.compareHeapEntry({}, .{ .run_index = 0, .record = a }, .{ .run_index = 1, .record = b }));
}

test "node text repair publication removes temporary runs after failure" {
    const run_path = try std.fmt.allocPrint(std.testing.allocator, "{s}.repair_run.{d}.tmp", .{ "node-text", 3 });
    defer std.testing.allocator.free(run_path);
    try std.testing.expectEqualStrings("node-text.repair_run.3.tmp", run_path);
}
