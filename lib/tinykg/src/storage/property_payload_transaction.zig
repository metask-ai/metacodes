const std = @import("std");
const property_format = @import("property_format.zig");
const property_block_codec = @import("property_block_codec.zig");

const PropertyPayloadIndexHeader = property_format.PropertyPayloadIndexHeader;
const PropertyPayloadRedoJournalHeader = property_format.PropertyPayloadRedoJournalHeader;
const PropertyPayloadIndexRecord = property_format.PropertyPayloadIndexRecord;
const PropertyPayloadDeltaHeader = property_format.PropertyPayloadDeltaHeader;
const NodePropertyValueBlockHeader = property_format.NodePropertyValueBlockHeader;
const NodePropertyValueRecord = property_format.NodePropertyValueRecord;

const delta_header_len = property_format.property_payload_delta_header_len;
const delta_entry_len = property_format.property_payload_delta_entry_len;
const delta_digest_seed = property_format.property_payload_delta_digest_seed;
const delta_max_frame_bytes = property_format.property_payload_delta_max_frame_bytes;
const write_buffer_bytes: usize = 256 * 1024;
const redo_digest_seed: u64 = 0x544B_504A;
const value_digest_seed: u64 = 0x544B_5056;

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

    fn initAtOffset(allocator: std.mem.Allocator, io: std.Io, file: std.Io.File, capacity: usize, offset: u64) !BufferedWriter {
        var writer = try init(allocator, io, file, capacity);
        writer.offset = offset;
        return writer;
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
};

fn regularFileSize(io: std.Io, file: std.Io.File) !u64 {
    const stat = try file.stat(io);
    if (stat.kind != .file) return error.IsDir;
    return stat.size;
}

fn writeBufferCapacity(file_size: u64) !usize {
    const size = std.math.cast(usize, file_size) orelse return error.RecordTooLarge;
    return @min(write_buffer_bytes, size);
}

fn propertyPayloadIndexFileSize(record_count: u64) !u64 {
    const records_bytes = std.math.mul(u64, record_count, PropertyPayloadIndexRecord.encoded_len) catch return error.RecordTooLarge;
    return std.math.add(u64, PropertyPayloadIndexHeader.encoded_len, records_bytes) catch error.RecordTooLarge;
}

fn propertyPayloadValueFileSize(record_count: u64, payload_bytes: u64) !u64 {
    const record_bytes = std.math.mul(u64, record_count, NodePropertyValueRecord.encoded_len) catch return error.RecordTooLarge;
    const prefix = std.math.add(u64, NodePropertyValueBlockHeader.encoded_len, record_bytes) catch return error.RecordTooLarge;
    return std.math.add(u64, prefix, payload_bytes) catch error.RecordTooLarge;
}

fn recordLessThan(a: PropertyPayloadIndexRecord, b: PropertyPayloadIndexRecord) bool {
    if (a.key_hash != b.key_hash) return a.key_hash < b.key_hash;
    if (a.owner_kind != b.owner_kind) return a.owner_kind < b.owner_kind;
    if (a.owner_id != b.owner_id) return a.owner_id < b.owner_id;
    if (a.value_type != b.value_type) return a.value_type < b.value_type;
    return a.value_hash < b.value_hash;
}

/// Owns the complete durable mutation boundary for canonical property payloads:
/// append-only delta publication and replay, immutable index/value pair staging
/// and redo recovery, bounded sorted-stream replacement, and compaction commit
/// ordering. Lookup, snapshot projection, CRUD admission, and owner existence
/// validation remain in the Store façade and enter only through narrow `Ops`.
pub fn PropertyPayloadTransaction(comptime Ops: type) type {
    return struct {
        const Self = @This();
        const StoreType = Ops.StoreType;
        const Entry = Ops.EntryType;
        const Write = Ops.WriteType;
        const DeltaScan = Ops.DeltaScanType;
        const DeltaRecovery = Ops.DeltaRecoveryType;
        const CompactionResult = Ops.CompactionResultType;

        const OwnerKey = struct {
            owner_kind: u8,
            owner_id: u64,
            key_hash: u64,
        };

        const ConcreteDeltaBackend = struct {
            fn writeJournal(store: StoreType, frame: []const u8) !void {
                try Self.writeDeltaJournal(store, frame);
            }

            fn appendFrame(store: StoreType, frame: []const u8, expected_offset: u64) !void {
                try Self.appendDeltaFrame(store, frame, expected_offset);
            }

            fn recover(store: StoreType) !DeltaRecovery {
                return try Self.recoverDeltaJournal(store);
            }

            fn deleteJournal(store: StoreType) !void {
                try Self.deleteDeltaJournal(store);
            }
        };

        const ConcreteBaseBackend = struct {
            fn writeRedo(store: StoreType, index_stage_path: []const u8, values_stage_path: []const u8) !void {
                try Self.writeBaseRedoJournal(store, index_stage_path, values_stage_path);
            }

            fn publishValues(store: StoreType, values_stage_path: []const u8) !void {
                try Ops.renameReplace(store, values_stage_path, Ops.valuesPath(store));
            }

            fn publishIndex(store: StoreType, index_stage_path: []const u8) !void {
                try Ops.renameReplace(store, index_stage_path, Ops.indexPath(store));
            }

            fn deleteRedo(store: StoreType) !void {
                try Self.deleteBaseRedoJournal(store);
            }
        };

        fn entryLessThan(_: void, a: Entry, b: Entry) bool {
            return recordLessThan(a.record, b.record);
        }

        fn deltaJournalPath(store: StoreType) ![]u8 {
            return try std.fmt.allocPrint(Ops.allocator(store), "{s}.redo", .{Ops.deltaPath(store)});
        }

        fn baseRedoJournalPath(store: StoreType) ![]u8 {
            return try std.fmt.allocPrint(Ops.allocator(store), "{s}.redo", .{Ops.indexPath(store)});
        }

        fn encodeDeltaFrame(allocator: std.mem.Allocator, sequence: u64, writes: []const Write) ![]u8 {
            if (writes.len == 0) return error.InvalidRecord;
            var payload = std.ArrayList(u8).empty;
            defer payload.deinit(allocator);
            var frame_keys = std.AutoHashMap(OwnerKey, void).init(allocator);
            defer frame_keys.deinit();
            try frame_keys.ensureTotalCapacity(std.math.cast(u32, writes.len) orelse return error.RecordTooLarge);
            for (writes) |write| {
                const key_len = std.math.cast(u16, write.key.len) orelse return error.RecordTooLarge;
                if (!Ops.keyNameValid(write.key)) return error.InvalidRecord;
                const owner_kind = Ops.ownerKind(write.owner);
                const owner_id = Ops.ownerId(write.owner);
                const key_hash = Ops.keyHash(write.key);
                const frame_key = try frame_keys.getOrPut(.{
                    .owner_kind = owner_kind,
                    .owner_id = owner_id,
                    .key_hash = key_hash,
                });
                if (frame_key.found_existing) return error.InvalidRecord;
                const value_len: u32 = switch (write.value) {
                    .string => |value| std.math.cast(u32, value.len) orelse return error.RecordTooLarge,
                    .uint => 0,
                };
                const value_hash: u64 = switch (write.value) {
                    .string => |value| blk: {
                        if (value.len == 0) return error.InvalidRecord;
                        break :blk Ops.valueHash(value);
                    },
                    .uint => |value| value,
                };
                var entry_bytes: [delta_entry_len]u8 = [_]u8{0} ** delta_entry_len;
                entry_bytes[0] = owner_kind;
                entry_bytes[1] = switch (write.value) {
                    .string => PropertyPayloadIndexRecord.value_type_string,
                    .uint => PropertyPayloadIndexRecord.value_type_uint,
                };
                std.mem.writeInt(u16, entry_bytes[2..4], key_len, .little);
                std.mem.writeInt(u32, entry_bytes[4..8], value_len, .little);
                std.mem.writeInt(u64, entry_bytes[8..16], owner_id, .little);
                std.mem.writeInt(u64, entry_bytes[16..24], key_hash, .little);
                std.mem.writeInt(u64, entry_bytes[24..32], value_hash, .little);
                try payload.appendSlice(allocator, &entry_bytes);
                try payload.appendSlice(allocator, write.key);
                switch (write.value) {
                    .string => |value| try payload.appendSlice(allocator, value),
                    .uint => {},
                }
            }
            const payload_len = std.math.cast(u32, payload.items.len) orelse return error.RecordTooLarge;
            if (payload_len > delta_max_frame_bytes) return error.RecordTooLarge;
            const frame_len = std.math.add(usize, delta_header_len, payload.items.len) catch return error.RecordTooLarge;
            const frame = try allocator.alloc(u8, frame_len);
            errdefer allocator.free(frame);
            const header = PropertyPayloadDeltaHeader{
                .sequence = sequence,
                .write_count = std.math.cast(u32, writes.len) orelse return error.RecordTooLarge,
                .payload_len = payload_len,
                .payload_digest = std.hash.Wyhash.hash(delta_digest_seed, payload.items),
            };
            var header_bytes: [delta_header_len]u8 = undefined;
            try header.encode(&header_bytes);
            @memcpy(frame[0..delta_header_len], &header_bytes);
            @memcpy(frame[delta_header_len..], payload.items);
            return frame;
        }

        fn writeDeltaJournal(store: StoreType, frame: []const u8) !void {
            const allocator = Ops.allocator(store);
            const io = Ops.io(store);
            const journal_path = try deltaJournalPath(store);
            defer allocator.free(journal_path);
            const tmp_path = try Ops.tmpPath(store, journal_path);
            defer allocator.free(tmp_path);
            errdefer std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
            {
                var file = try std.Io.Dir.cwd().createFile(io, tmp_path, .{ .read = true, .truncate = true });
                defer file.close(io);
                try file.writePositionalAll(io, frame, 0);
                if (Ops.shouldSync(store)) try file.sync(io);
            }
            try Ops.renameReplace(store, tmp_path, journal_path);
        }

        fn deleteDeltaJournal(store: StoreType) !void {
            const allocator = Ops.allocator(store);
            const io = Ops.io(store);
            const journal_path = try deltaJournalPath(store);
            defer allocator.free(journal_path);
            try std.Io.Dir.cwd().deleteFile(io, journal_path);
            try Ops.syncParentDir(store, journal_path);
        }

        fn appendDeltaFrame(store: StoreType, frame: []const u8, expected_offset: u64) !void {
            const io = Ops.io(store);
            const delta_path = Ops.deltaPath(store);
            const existed = try Ops.fileExists(store, delta_path);
            {
                var file = try std.Io.Dir.cwd().createFile(io, delta_path, .{ .read = true, .truncate = false });
                defer file.close(io);
                if (try regularFileSize(io, file) != expected_offset) return error.InvalidRecord;
                try file.writePositionalAll(io, frame, expected_offset);
                if (Ops.shouldSync(store)) try file.sync(io);
            }
            if (!existed) try Ops.syncParentDir(store, delta_path);
        }

        pub fn recoverDeltaJournal(store: StoreType) !DeltaRecovery {
            const allocator = Ops.allocator(store);
            const io = Ops.io(store);
            const journal_path = try deltaJournalPath(store);
            defer allocator.free(journal_path);
            const frame = std.Io.Dir.cwd().readFileAlloc(io, journal_path, allocator, .limited(delta_header_len + delta_max_frame_bytes)) catch |err| switch (err) {
                // No journal means no interrupted append. Full delta validation
                // remains lazy until the first property operation.
                error.FileNotFound => return .no_journal,
                else => |other| return other,
            };
            defer allocator.free(frame);
            if (frame.len < delta_header_len) return error.InvalidRecord;
            var header_bytes: [delta_header_len]u8 = undefined;
            @memcpy(&header_bytes, frame[0..delta_header_len]);
            const header = try PropertyPayloadDeltaHeader.decode(&header_bytes);
            if (frame.len != delta_header_len + header.payload_len) return error.InvalidRecord;
            try Ops.validateDeltaFrame(store, header, frame[delta_header_len..]);

            var scan = try Ops.scanDelta(store, allocator, true);
            if (scan.trailing_partial) {
                if (header.sequence != std.math.add(u64, scan.last_sequence, 1) catch return error.InvalidRecord) return error.InvalidRecord;
                {
                    var delta = try std.Io.Dir.cwd().openFile(io, Ops.deltaPath(store), .{ .mode = .read_write, .allow_directory = false });
                    defer delta.close(io);
                    const delta_len = try regularFileSize(io, delta);
                    if (delta_len < scan.valid_bytes) return error.InvalidRecord;
                    const tail_len_u64 = delta_len - scan.valid_bytes;
                    if (tail_len_u64 > frame.len) return error.InvalidRecord;
                    const tail_len: usize = @intCast(tail_len_u64);
                    const tail = try allocator.alloc(u8, tail_len);
                    defer allocator.free(tail);
                    const tail_n = try delta.readPositionalAll(io, tail, scan.valid_bytes);
                    if (tail_n != tail.len or !std.mem.eql(u8, tail, frame[0..tail.len])) return error.InvalidRecord;
                    try delta.setLength(io, scan.valid_bytes);
                    if (Ops.shouldSync(store)) try delta.sync(io);
                }
                scan.trailing_partial = false;
            }
            if (scan.last_sequence == header.sequence) {
                if (scan.last_digest != header.payload_digest or scan.valid_bytes < frame.len) return error.InvalidRecord;
                var delta = try std.Io.Dir.cwd().openFile(io, Ops.deltaPath(store), .{ .mode = .read_write, .allow_directory = false });
                defer delta.close(io);
                const frame_offset = scan.valid_bytes - frame.len;
                const published = try allocator.alloc(u8, frame.len);
                defer allocator.free(published);
                const published_n = try delta.readPositionalAll(io, published, frame_offset);
                if (published_n != published.len or !std.mem.eql(u8, published, frame)) return error.InvalidRecord;
                if (Ops.shouldSync(store)) try delta.sync(io);
            } else {
                if (header.sequence != std.math.add(u64, scan.last_sequence, 1) catch return error.InvalidRecord) return error.InvalidRecord;
                try appendDeltaFrame(store, frame, scan.valid_bytes);
            }
            try deleteDeltaJournal(store);
            return .committed;
        }

        fn publishDeltaUsing(
            comptime Backend: type,
            store: StoreType,
            allocator: std.mem.Allocator,
            writes: []const Write,
            scan: DeltaScan,
        ) !void {
            if (scan.trailing_partial) return error.InvalidRecord;
            const sequence = std.math.add(u64, scan.last_sequence, 1) catch return error.RecordTooLarge;
            const frame = try encodeDeltaFrame(allocator, sequence, writes);
            defer allocator.free(frame);
            try Backend.writeJournal(store, frame);
            Backend.appendFrame(store, frame, scan.valid_bytes) catch |append_error| {
                const recovery = Backend.recover(store) catch |recovery_error| return recovery_error;
                if (recovery == .committed) return;
                return append_error;
            };
            try Backend.deleteJournal(store);
        }

        pub fn publishDelta(store: StoreType, allocator: std.mem.Allocator, writes: []const Write, scan: DeltaScan) !void {
            return publishDeltaUsing(ConcreteDeltaBackend, store, allocator, writes, scan);
        }

        fn appendFileToJournal(
            store: StoreType,
            source: std.Io.File,
            source_len: u64,
            writer: *BufferedWriter,
            hasher: *std.hash.Wyhash,
        ) !void {
            const io = Ops.io(store);
            var offset: u64 = 0;
            var buffer: [write_buffer_bytes]u8 = undefined;
            while (offset < source_len) {
                const remaining = source_len - offset;
                const chunk_len: usize = @intCast(@min(remaining, buffer.len));
                const chunk = buffer[0..chunk_len];
                const n = try source.readPositionalAll(io, chunk, offset);
                if (n != chunk.len) return error.InvalidRecord;
                hasher.update(chunk);
                try writer.append(chunk);
                offset = std.math.add(u64, offset, chunk.len) catch return error.RecordTooLarge;
            }
        }

        fn writeBaseRedoJournal(store: StoreType, index_stage_path: []const u8, values_stage_path: []const u8) !void {
            const allocator = Ops.allocator(store);
            const io = Ops.io(store);
            var index_file = try std.Io.Dir.cwd().openFile(io, index_stage_path, .{ .allow_directory = false });
            defer index_file.close(io);
            const index_len = try regularFileSize(io, index_file);
            var values_file = try std.Io.Dir.cwd().openFile(io, values_stage_path, .{ .allow_directory = false });
            defer values_file.close(io);
            const values_len = try regularFileSize(io, values_file);
            const body_len = std.math.add(u64, index_len, values_len) catch return error.RecordTooLarge;
            const journal_len = std.math.add(u64, PropertyPayloadRedoJournalHeader.encoded_len, body_len) catch return error.RecordTooLarge;

            const journal_path = try baseRedoJournalPath(store);
            defer allocator.free(journal_path);
            const tmp_path = try Ops.tmpPath(store, journal_path);
            defer allocator.free(tmp_path);
            errdefer std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};
            {
                var journal_file = try std.Io.Dir.cwd().createFile(io, tmp_path, .{ .read = true, .truncate = true });
                defer journal_file.close(io);
                var writer = try BufferedWriter.init(allocator, io, journal_file, try writeBufferCapacity(journal_len));
                defer writer.deinit();
                var placeholder: [PropertyPayloadRedoJournalHeader.encoded_len]u8 = [_]u8{0} ** PropertyPayloadRedoJournalHeader.encoded_len;
                try writer.append(&placeholder);
                var index_hasher = std.hash.Wyhash.init(redo_digest_seed);
                var values_hasher = std.hash.Wyhash.init(redo_digest_seed);
                try appendFileToJournal(store, index_file, index_len, &writer, &index_hasher);
                try appendFileToJournal(store, values_file, values_len, &writer, &values_hasher);
                try writer.flush();

                const header = PropertyPayloadRedoJournalHeader{
                    .index_len = index_len,
                    .values_len = values_len,
                    .index_digest = index_hasher.final(),
                    .values_digest = values_hasher.final(),
                };
                var header_bytes: [PropertyPayloadRedoJournalHeader.encoded_len]u8 = undefined;
                header.encode(&header_bytes);
                try journal_file.writePositionalAll(io, &header_bytes, 0);
                if (try regularFileSize(io, journal_file) != journal_len) return error.InvalidRecord;
                if (Ops.shouldSync(store)) try journal_file.sync(io);
            }
            try Ops.renameReplace(store, tmp_path, journal_path);
        }

        fn restoreJournalRange(
            store: StoreType,
            journal_file: std.Io.File,
            journal_offset: u64,
            byte_len: u64,
            expected_digest: u64,
            stage_path: []const u8,
        ) !void {
            const allocator = Ops.allocator(store);
            const io = Ops.io(store);
            var stage_file = try std.Io.Dir.cwd().createFile(io, stage_path, .{ .read = true, .truncate = true });
            defer stage_file.close(io);
            var writer = try BufferedWriter.init(allocator, io, stage_file, try writeBufferCapacity(byte_len));
            defer writer.deinit();
            var hasher = std.hash.Wyhash.init(redo_digest_seed);
            var copied: u64 = 0;
            var buffer: [write_buffer_bytes]u8 = undefined;
            while (copied < byte_len) {
                const remaining = byte_len - copied;
                const chunk_len: usize = @intCast(@min(remaining, buffer.len));
                const chunk = buffer[0..chunk_len];
                const offset = std.math.add(u64, journal_offset, copied) catch return error.InvalidRecord;
                const n = try journal_file.readPositionalAll(io, chunk, offset);
                if (n != chunk.len) return error.InvalidRecord;
                hasher.update(chunk);
                try writer.append(chunk);
                copied = std.math.add(u64, copied, chunk.len) catch return error.RecordTooLarge;
            }
            try writer.flush();
            if (hasher.final() != expected_digest) return error.InvalidRecord;
            if (try regularFileSize(io, stage_file) != byte_len) return error.InvalidRecord;
            if (Ops.shouldSync(store)) try stage_file.sync(io);
        }

        pub fn recoverBaseRedoJournal(store: StoreType) !void {
            const allocator = Ops.allocator(store);
            const io = Ops.io(store);
            const journal_path = try baseRedoJournalPath(store);
            defer allocator.free(journal_path);
            var journal_file = std.Io.Dir.cwd().openFile(io, journal_path, .{ .allow_directory = false }) catch |err| switch (err) {
                error.FileNotFound => return,
                else => |other| return other,
            };
            var journal_file_open = true;
            defer if (journal_file_open) journal_file.close(io);
            const journal_size = try regularFileSize(io, journal_file);
            var header_bytes: [PropertyPayloadRedoJournalHeader.encoded_len]u8 = undefined;
            const header_n = try journal_file.readPositionalAll(io, &header_bytes, 0);
            if (header_n != header_bytes.len) return error.InvalidRecord;
            const header = try PropertyPayloadRedoJournalHeader.decode(&header_bytes);
            const body_len = std.math.add(u64, header.index_len, header.values_len) catch return error.InvalidRecord;
            const expected_size = std.math.add(u64, PropertyPayloadRedoJournalHeader.encoded_len, body_len) catch return error.InvalidRecord;
            if (journal_size != expected_size) return error.InvalidRecord;

            const index_tmp_path = try Ops.tmpPath(store, Ops.indexPath(store));
            defer allocator.free(index_tmp_path);
            errdefer std.Io.Dir.cwd().deleteFile(io, index_tmp_path) catch {};
            const values_tmp_path = try Ops.tmpPath(store, Ops.valuesPath(store));
            defer allocator.free(values_tmp_path);
            errdefer std.Io.Dir.cwd().deleteFile(io, values_tmp_path) catch {};
            try restoreJournalRange(
                store,
                journal_file,
                PropertyPayloadRedoJournalHeader.encoded_len,
                header.index_len,
                header.index_digest,
                index_tmp_path,
            );
            const values_offset = std.math.add(u64, PropertyPayloadRedoJournalHeader.encoded_len, header.index_len) catch return error.InvalidRecord;
            try restoreJournalRange(
                store,
                journal_file,
                values_offset,
                header.values_len,
                header.values_digest,
                values_tmp_path,
            );
            journal_file.close(io);
            journal_file_open = false;
            try Ops.validateRestoredBasePair(store, index_tmp_path, values_tmp_path);
            try Ops.renameReplace(store, values_tmp_path, Ops.valuesPath(store));
            try Ops.renameReplace(store, index_tmp_path, Ops.indexPath(store));
            try std.Io.Dir.cwd().deleteFile(io, journal_path);
            try Ops.syncParentDir(store, journal_path);
        }

        fn deleteBaseRedoJournal(store: StoreType) !void {
            const allocator = Ops.allocator(store);
            const io = Ops.io(store);
            const journal_path = try baseRedoJournalPath(store);
            defer allocator.free(journal_path);
            try std.Io.Dir.cwd().deleteFile(io, journal_path);
            try Ops.syncParentDir(store, journal_path);
        }

        fn writeIndexStage(store: StoreType, path: []const u8, entries: []const Entry) !void {
            const allocator = Ops.allocator(store);
            const io = Ops.io(store);
            var file = try std.Io.Dir.cwd().createFile(io, path, .{ .read = true, .truncate = true });
            defer file.close(io);
            const file_size = try propertyPayloadIndexFileSize(@intCast(entries.len));
            var writer = try BufferedWriter.init(allocator, io, file, try writeBufferCapacity(file_size));
            defer writer.deinit();
            const header = PropertyPayloadIndexHeader{
                .record_count = @intCast(entries.len),
                .owner_count = 0,
                .owner_digest = 0,
                .flags = PropertyPayloadIndexHeader.flag_string_value_hash_derived,
            };
            var header_bytes: [PropertyPayloadIndexHeader.encoded_len]u8 = undefined;
            header.encode(&header_bytes);
            try writer.append(&header_bytes);
            var previous: ?PropertyPayloadIndexRecord = null;
            for (entries) |entry| {
                const record = entry.record;
                if (previous) |prior| {
                    if (!recordLessThan(prior, record)) return error.InvalidRecord;
                }
                var record_bytes: [PropertyPayloadIndexRecord.encoded_len]u8 = undefined;
                var stored_record = record;
                if (stored_record.value_type == PropertyPayloadIndexRecord.value_type_string) stored_record.value_hash = 0;
                try stored_record.encode(&record_bytes);
                try writer.append(&record_bytes);
                previous = record;
            }
            try writer.flush();
            if (try regularFileSize(io, file) != file_size) return error.InvalidRecord;
            if (Ops.shouldSync(store)) try file.sync(io);
        }

        fn writeValueStage(store: StoreType, path: []const u8, entries: []const Entry) !void {
            const allocator = Ops.allocator(store);
            const io = Ops.io(store);
            const value_records = try allocator.alloc(NodePropertyValueRecord, entries.len);
            defer allocator.free(value_records);
            var payload_bytes: u64 = 0;
            var payload_digest: u64 = 0;
            var digest_bytes: [8]u8 = undefined;
            for (entries, 0..) |entry, i| {
                if (entry.record.value_type == PropertyPayloadIndexRecord.value_type_string) {
                    const value = entry.value orelse return error.InvalidRecord;
                    if (value.len == 0 or Ops.valueHash(value) != entry.record.value_hash) return error.InvalidRecord;
                    const len_u32 = std.math.cast(u32, value.len) orelse return error.RecordTooLarge;
                    value_records[i] = .{ .offset = payload_bytes, .len = len_u32 };
                    std.mem.writeInt(u64, &digest_bytes, entry.record.key_hash, .little);
                    payload_digest ^= std.hash.Wyhash.hash(value_digest_seed, &digest_bytes);
                    std.mem.writeInt(u64, &digest_bytes, entry.record.value_hash, .little);
                    payload_digest ^= std.hash.Wyhash.hash(value_digest_seed, &digest_bytes);
                    payload_digest ^= std.hash.Wyhash.hash(value_digest_seed, value);
                    payload_bytes = std.math.add(u64, payload_bytes, value.len) catch return error.RecordTooLarge;
                } else if (entry.record.value_type == PropertyPayloadIndexRecord.value_type_uint) {
                    if (entry.value != null) return error.InvalidRecord;
                    value_records[i] = .{ .offset = 0, .len = 0 };
                } else {
                    return error.InvalidRecord;
                }
            }
            var file = try std.Io.Dir.cwd().createFile(io, path, .{ .read = true, .truncate = true });
            defer file.close(io);
            const file_size = try propertyPayloadValueFileSize(@intCast(entries.len), payload_bytes);
            var writer = try BufferedWriter.init(allocator, io, file, try writeBufferCapacity(file_size));
            defer writer.deinit();
            const header = NodePropertyValueBlockHeader{
                .record_count = @intCast(entries.len),
                .node_count = 0,
                .node_digest = 0,
                .payload_bytes = payload_bytes,
                .payload_digest = payload_digest,
                .flags = NodePropertyValueBlockHeader.flag_string_value_hash_derived,
            };
            var header_bytes: [NodePropertyValueBlockHeader.encoded_len]u8 = undefined;
            header.encode(&header_bytes);
            try writer.append(&header_bytes);
            var value_record_bytes: [NodePropertyValueRecord.encoded_len]u8 = undefined;
            for (value_records) |record| {
                record.encode(&value_record_bytes);
                try writer.append(&value_record_bytes);
            }
            for (entries) |entry| {
                if (entry.record.value_type == PropertyPayloadIndexRecord.value_type_string) {
                    try writer.append(entry.value.?);
                }
            }
            try writer.flush();
            if (try regularFileSize(io, file) != file_size) return error.InvalidRecord;
            if (Ops.shouldSync(store)) try file.sync(io);
        }

        fn encodeStageWithBlockCodec(store: StoreType, raw_path: []const u8, encoded_path: []const u8, options: property_block_codec.EncodeOptions) !void {
            const allocator = Ops.allocator(store);
            const io = Ops.io(store);
            var raw_file = try std.Io.Dir.cwd().openFile(io, raw_path, .{ .allow_directory = false });
            defer raw_file.close(io);
            const logical_size = try regularFileSize(io, raw_file);
            var encoded_file = try std.Io.Dir.cwd().createFile(io, encoded_path, .{ .read = true, .truncate = true });
            defer encoded_file.close(io);
            _ = try property_block_codec.encodeFileWithOptions(allocator, io, raw_file, logical_size, encoded_file, options);
            if (Ops.shouldSync(store)) try encoded_file.sync(io);
        }

        const index_stage_encode_options = property_block_codec.EncodeOptions{ .property_index = .{
            .header_len = PropertyPayloadIndexHeader.encoded_len,
            .record_len = PropertyPayloadIndexRecord.encoded_len,
            .key_hash_offset = 0,
            .owner_id_offset = 16,
            .owner_kind_offset = 24,
        }, .record_shuffle = true, .record_delta = true };
        const values_stage_encode_options = property_block_codec.EncodeOptions{
            .record_shuffle = true,
            .record_delta = true,
        };

        /// Replace a raw staged file with its block-encoded form and delete
        /// the raw bytes immediately, so at most one raw stage exists at a
        /// time. On real GB-scale stores the raw stages are the dominant
        /// transient disk cost of a base publication (roughly the logical
        /// property bytes each), so their lifetime bounds the store's peak
        /// on-disk footprint during compaction.
        fn encodeStageInPlace(store: StoreType, stage_path: []const u8, options: property_block_codec.EncodeOptions) !void {
            const allocator = Ops.allocator(store);
            const io = Ops.io(store);
            const raw_path = try std.fmt.allocPrint(allocator, "{s}.raw", .{stage_path});
            defer allocator.free(raw_path);
            errdefer std.Io.Dir.cwd().deleteFile(io, raw_path) catch {};
            try Ops.renameReplace(store, stage_path, raw_path);
            errdefer Ops.renameReplace(store, raw_path, stage_path) catch {};
            try encodeStageWithBlockCodec(store, raw_path, stage_path, options);
            try std.Io.Dir.cwd().deleteFile(io, raw_path);
        }

        fn encodeBasePairStages(store: StoreType, index_stage_path: []const u8, values_stage_path: []const u8) !void {
            try encodeStageInPlace(store, index_stage_path, index_stage_encode_options);
            try encodeStageInPlace(store, values_stage_path, values_stage_encode_options);
        }

        fn publishPreparedBaseUsing(
            comptime Backend: type,
            store: StoreType,
            index_stage_path: []const u8,
            values_stage_path: []const u8,
        ) !void {
            try Backend.writeRedo(store, index_stage_path, values_stage_path);
            try Backend.publishValues(store, values_stage_path);
            try Backend.publishIndex(store, index_stage_path);
            try Backend.deleteRedo(store);
        }

        fn publishPreparedBase(store: StoreType, index_stage_path: []const u8, values_stage_path: []const u8) !void {
            return publishPreparedBaseUsing(ConcreteBaseBackend, store, index_stage_path, values_stage_path);
        }

        pub fn publishBase(store: StoreType, entries: []Entry) !void {
            const allocator = Ops.allocator(store);
            const io = Ops.io(store);
            std.mem.sort(Entry, entries, {}, entryLessThan);
            const index_stage_path = try Ops.tmpPath(store, Ops.indexPath(store));
            defer allocator.free(index_stage_path);
            errdefer std.Io.Dir.cwd().deleteFile(io, index_stage_path) catch {};
            const values_stage_path = try Ops.tmpPath(store, Ops.valuesPath(store));
            defer allocator.free(values_stage_path);
            errdefer std.Io.Dir.cwd().deleteFile(io, values_stage_path) catch {};
            // Write and encode one stage at a time: the raw index and raw
            // value stages are each roughly logical-size, and letting them
            // coexist would double the peak on-disk footprint of compaction.
            try writeIndexStage(store, index_stage_path, entries);
            try encodeStageInPlace(store, index_stage_path, index_stage_encode_options);
            try writeValueStage(store, values_stage_path, entries);
            try encodeStageInPlace(store, values_stage_path, values_stage_encode_options);
            try publishPreparedBase(store, index_stage_path, values_stage_path);
        }

        pub fn replaceEmptyBaseFromSortedStream(
            store: StoreType,
            expected_count: u64,
            context: *anyopaque,
            next: Ops.SortedNextType,
        ) !void {
            const allocator = Ops.allocator(store);
            const io = Ops.io(store);
            const index_stage_path = try Ops.tmpPath(store, Ops.indexPath(store));
            defer allocator.free(index_stage_path);
            errdefer std.Io.Dir.cwd().deleteFile(io, index_stage_path) catch {};
            const values_stage_path = try Ops.tmpPath(store, Ops.valuesPath(store));
            defer allocator.free(values_stage_path);
            errdefer std.Io.Dir.cwd().deleteFile(io, values_stage_path) catch {};

            var record_count: u64 = 0;
            var payload_bytes: u64 = 0;
            var payload_digest: u64 = 0;
            {
                var index_file = try std.Io.Dir.cwd().createFile(io, index_stage_path, .{ .read = true, .truncate = true });
                defer index_file.close(io);
                var values_file = try std.Io.Dir.cwd().createFile(io, values_stage_path, .{ .read = true, .truncate = true });
                defer values_file.close(io);
                var index_writer = try BufferedWriter.initAtOffset(
                    allocator,
                    io,
                    index_file,
                    write_buffer_bytes,
                    PropertyPayloadIndexHeader.encoded_len,
                );
                defer index_writer.deinit();
                var value_record_writer = try BufferedWriter.initAtOffset(
                    allocator,
                    io,
                    values_file,
                    write_buffer_bytes,
                    NodePropertyValueBlockHeader.encoded_len,
                );
                defer value_record_writer.deinit();
                const payload_offset = std.math.add(
                    u64,
                    NodePropertyValueBlockHeader.encoded_len,
                    std.math.mul(u64, expected_count, NodePropertyValueRecord.encoded_len) catch return error.RecordTooLarge,
                ) catch return error.RecordTooLarge;
                var value_writer = try BufferedWriter.initAtOffset(
                    allocator,
                    io,
                    values_file,
                    write_buffer_bytes,
                    payload_offset,
                );
                defer value_writer.deinit();

                var previous: ?PropertyPayloadIndexRecord = null;
                var digest_bytes: [8]u8 = undefined;
                while (try next(context)) |entry| {
                    if (record_count >= expected_count) return error.InvalidRecord;
                    const owner_id = Ops.ownerId(entry.owner);
                    const owner_kind = Ops.ownerKind(entry.owner);
                    const value_type: u8 = switch (entry.value) {
                        .string => PropertyPayloadIndexRecord.value_type_string,
                        .uint => PropertyPayloadIndexRecord.value_type_uint,
                    };
                    const value_hash: u64 = switch (entry.value) {
                        .string => |value| blk: {
                            if (value.len == 0) return error.InvalidRecord;
                            break :blk Ops.valueHash(value);
                        },
                        .uint => |value| value,
                    };
                    const record = PropertyPayloadIndexRecord{
                        .key_hash = entry.key_hash,
                        .value_hash = value_hash,
                        .owner_id = owner_id,
                        .owner_kind = owner_kind,
                        .value_type = value_type,
                    };
                    if (previous) |prior| {
                        if (!recordLessThan(prior, record)) return error.InvalidRecord;
                    }
                    var record_bytes: [PropertyPayloadIndexRecord.encoded_len]u8 = undefined;
                    var stored_record = record;
                    if (stored_record.value_type == PropertyPayloadIndexRecord.value_type_string) stored_record.value_hash = 0;
                    try stored_record.encode(&record_bytes);
                    try index_writer.append(&record_bytes);

                    var value_record: NodePropertyValueRecord = .{ .offset = 0, .len = 0 };
                    switch (entry.value) {
                        .string => |value| {
                            value_record = .{
                                .offset = payload_bytes,
                                .len = std.math.cast(u32, value.len) orelse return error.RecordTooLarge,
                            };
                            std.mem.writeInt(u64, &digest_bytes, entry.key_hash, .little);
                            payload_digest ^= std.hash.Wyhash.hash(value_digest_seed, &digest_bytes);
                            std.mem.writeInt(u64, &digest_bytes, value_hash, .little);
                            payload_digest ^= std.hash.Wyhash.hash(value_digest_seed, &digest_bytes);
                            payload_digest ^= std.hash.Wyhash.hash(value_digest_seed, value);
                            try value_writer.append(value);
                            payload_bytes = std.math.add(u64, payload_bytes, value.len) catch return error.RecordTooLarge;
                        },
                        .uint => {},
                    }
                    var value_record_bytes: [NodePropertyValueRecord.encoded_len]u8 = undefined;
                    value_record.encode(&value_record_bytes);
                    try value_record_writer.append(&value_record_bytes);
                    record_count = std.math.add(u64, record_count, 1) catch return error.RecordTooLarge;
                    previous = record;
                }
                if (record_count != expected_count) return error.InvalidRecord;
                try index_writer.flush();
                try value_record_writer.flush();
                try value_writer.flush();

                var index_header_bytes: [PropertyPayloadIndexHeader.encoded_len]u8 = undefined;
                (PropertyPayloadIndexHeader{
                    .record_count = record_count,
                    .owner_count = 0,
                    .owner_digest = 0,
                    .flags = PropertyPayloadIndexHeader.flag_string_value_hash_derived,
                }).encode(&index_header_bytes);
                try index_file.writePositionalAll(io, &index_header_bytes, 0);
                var values_header_bytes: [NodePropertyValueBlockHeader.encoded_len]u8 = undefined;
                (NodePropertyValueBlockHeader{
                    .record_count = record_count,
                    .node_count = 0,
                    .node_digest = 0,
                    .payload_bytes = payload_bytes,
                    .payload_digest = payload_digest,
                    .flags = NodePropertyValueBlockHeader.flag_string_value_hash_derived,
                }).encode(&values_header_bytes);
                try values_file.writePositionalAll(io, &values_header_bytes, 0);

                if (try regularFileSize(io, index_file) != try propertyPayloadIndexFileSize(record_count)) return error.InvalidRecord;
                if (try regularFileSize(io, values_file) != try propertyPayloadValueFileSize(record_count, payload_bytes)) return error.InvalidRecord;
                if (Ops.shouldSync(store)) {
                    try index_file.sync(io);
                    try values_file.sync(io);
                }
            }
            try encodeBasePairStages(store, index_stage_path, values_stage_path);
            try publishPreparedBase(store, index_stage_path, values_stage_path);
        }

        const StreamPassSummary = struct {
            record_count: u64 = 0,
            payload_bytes: u64 = 0,
            digest: u64 = 0,

            fn addRecord(self: *@This(), record: PropertyPayloadIndexRecord, value: ?[]const u8) !void {
                var record_identity: [33]u8 = undefined;
                std.mem.writeInt(u64, record_identity[0..8], record.key_hash, .little);
                std.mem.writeInt(u64, record_identity[8..16], record.value_hash, .little);
                std.mem.writeInt(u64, record_identity[16..24], record.owner_id, .little);
                std.mem.writeInt(u64, record_identity[24..32], self.record_count, .little);
                record_identity[32] = record.value_type;
                self.digest ^= std.hash.Wyhash.hash(record.owner_kind, &record_identity);
                if (value) |bytes| {
                    self.digest ^= std.hash.Wyhash.hash(value_digest_seed, bytes);
                    self.payload_bytes = std.math.add(u64, self.payload_bytes, bytes.len) catch return error.RecordTooLarge;
                }
                self.record_count = std.math.add(u64, self.record_count, 1) catch return error.RecordTooLarge;
            }

            fn matches(self: @This(), other: @This()) bool {
                return self.record_count == other.record_count and
                    self.payload_bytes == other.payload_bytes and
                    self.digest == other.digest;
            }
        };

        /// Two-pass variant of `replaceEmptyBaseFromSortedStream` for streams
        /// that can be restarted from the beginning. Each raw stage is
        /// written, block-encoded, and deleted before the next stage is
        /// produced, so peak on-disk staging is one raw stage instead of two;
        /// on GB-scale property loads that halves the store's transient disk
        /// peak. The second pass must replay the identical stream: record
        /// count, payload bytes and a per-record content digest are compared
        /// and any drift fails closed before publication.
        pub fn replaceEmptyBaseFromRestartableSortedStream(
            store: StoreType,
            expected_count: u64,
            context: *anyopaque,
            restart: *const fn (context: *anyopaque) anyerror!void,
            next: Ops.SortedNextType,
        ) !void {
            const allocator = Ops.allocator(store);
            const io = Ops.io(store);
            const index_stage_path = try Ops.tmpPath(store, Ops.indexPath(store));
            defer allocator.free(index_stage_path);
            errdefer std.Io.Dir.cwd().deleteFile(io, index_stage_path) catch {};
            const values_stage_path = try Ops.tmpPath(store, Ops.valuesPath(store));
            defer allocator.free(values_stage_path);
            errdefer std.Io.Dir.cwd().deleteFile(io, values_stage_path) catch {};

            var index_pass = StreamPassSummary{};
            {
                var index_file = try std.Io.Dir.cwd().createFile(io, index_stage_path, .{ .read = true, .truncate = true });
                defer index_file.close(io);
                var index_writer = try BufferedWriter.initAtOffset(
                    allocator,
                    io,
                    index_file,
                    write_buffer_bytes,
                    PropertyPayloadIndexHeader.encoded_len,
                );
                defer index_writer.deinit();
                var previous: ?PropertyPayloadIndexRecord = null;
                while (try next(context)) |entry| {
                    if (index_pass.record_count >= expected_count) return error.InvalidRecord;
                    const record = try sortedStreamIndexRecord(entry);
                    if (previous) |prior| {
                        if (!recordLessThan(prior, record)) return error.InvalidRecord;
                    }
                    var record_bytes: [PropertyPayloadIndexRecord.encoded_len]u8 = undefined;
                    var stored_record = record;
                    if (stored_record.value_type == PropertyPayloadIndexRecord.value_type_string) stored_record.value_hash = 0;
                    try stored_record.encode(&record_bytes);
                    try index_writer.append(&record_bytes);
                    try index_pass.addRecord(record, switch (entry.value) {
                        .string => |value| value,
                        .uint => null,
                    });
                    previous = record;
                }
                if (index_pass.record_count != expected_count) return error.InvalidRecord;
                try index_writer.flush();
                var index_header_bytes: [PropertyPayloadIndexHeader.encoded_len]u8 = undefined;
                (PropertyPayloadIndexHeader{
                    .record_count = index_pass.record_count,
                    .owner_count = 0,
                    .owner_digest = 0,
                    .flags = PropertyPayloadIndexHeader.flag_string_value_hash_derived,
                }).encode(&index_header_bytes);
                try index_file.writePositionalAll(io, &index_header_bytes, 0);
                if (try regularFileSize(io, index_file) != try propertyPayloadIndexFileSize(index_pass.record_count)) return error.InvalidRecord;
                if (Ops.shouldSync(store)) try index_file.sync(io);
            }
            try encodeStageInPlace(store, index_stage_path, index_stage_encode_options);

            try restart(context);
            var values_pass = StreamPassSummary{};
            var payload_digest: u64 = 0;
            {
                var values_file = try std.Io.Dir.cwd().createFile(io, values_stage_path, .{ .read = true, .truncate = true });
                defer values_file.close(io);
                var value_record_writer = try BufferedWriter.initAtOffset(
                    allocator,
                    io,
                    values_file,
                    write_buffer_bytes,
                    NodePropertyValueBlockHeader.encoded_len,
                );
                defer value_record_writer.deinit();
                const payload_offset = std.math.add(
                    u64,
                    NodePropertyValueBlockHeader.encoded_len,
                    std.math.mul(u64, expected_count, NodePropertyValueRecord.encoded_len) catch return error.RecordTooLarge,
                ) catch return error.RecordTooLarge;
                var value_writer = try BufferedWriter.initAtOffset(
                    allocator,
                    io,
                    values_file,
                    write_buffer_bytes,
                    payload_offset,
                );
                defer value_writer.deinit();

                var digest_bytes: [8]u8 = undefined;
                while (try next(context)) |entry| {
                    if (values_pass.record_count >= expected_count) return error.InvalidRecord;
                    const record = try sortedStreamIndexRecord(entry);
                    var value_record: NodePropertyValueRecord = .{ .offset = 0, .len = 0 };
                    switch (entry.value) {
                        .string => |value| {
                            value_record = .{
                                .offset = values_pass.payload_bytes,
                                .len = std.math.cast(u32, value.len) orelse return error.RecordTooLarge,
                            };
                            std.mem.writeInt(u64, &digest_bytes, entry.key_hash, .little);
                            payload_digest ^= std.hash.Wyhash.hash(value_digest_seed, &digest_bytes);
                            std.mem.writeInt(u64, &digest_bytes, record.value_hash, .little);
                            payload_digest ^= std.hash.Wyhash.hash(value_digest_seed, &digest_bytes);
                            payload_digest ^= std.hash.Wyhash.hash(value_digest_seed, value);
                            try value_writer.append(value);
                        },
                        .uint => {},
                    }
                    var value_record_bytes: [NodePropertyValueRecord.encoded_len]u8 = undefined;
                    value_record.encode(&value_record_bytes);
                    try value_record_writer.append(&value_record_bytes);
                    try values_pass.addRecord(record, switch (entry.value) {
                        .string => |value| value,
                        .uint => null,
                    });
                }
                if (!index_pass.matches(values_pass)) return error.InvalidRecord;
                try value_record_writer.flush();
                try value_writer.flush();
                var values_header_bytes: [NodePropertyValueBlockHeader.encoded_len]u8 = undefined;
                (NodePropertyValueBlockHeader{
                    .record_count = values_pass.record_count,
                    .node_count = 0,
                    .node_digest = 0,
                    .payload_bytes = values_pass.payload_bytes,
                    .payload_digest = payload_digest,
                    .flags = NodePropertyValueBlockHeader.flag_string_value_hash_derived,
                }).encode(&values_header_bytes);
                try values_file.writePositionalAll(io, &values_header_bytes, 0);
                if (try regularFileSize(io, values_file) != try propertyPayloadValueFileSize(values_pass.record_count, values_pass.payload_bytes)) return error.InvalidRecord;
                if (Ops.shouldSync(store)) try values_file.sync(io);
            }
            try encodeStageInPlace(store, values_stage_path, values_stage_encode_options);
            try publishPreparedBase(store, index_stage_path, values_stage_path);
        }

        fn sortedStreamIndexRecord(entry: anytype) !PropertyPayloadIndexRecord {
            const value_type: u8 = switch (entry.value) {
                .string => PropertyPayloadIndexRecord.value_type_string,
                .uint => PropertyPayloadIndexRecord.value_type_uint,
            };
            const value_hash: u64 = switch (entry.value) {
                .string => |value| blk: {
                    if (value.len == 0) return error.InvalidRecord;
                    break :blk Ops.valueHash(value);
                },
                .uint => |value| value,
            };
            return .{
                .key_hash = entry.key_hash,
                .value_hash = value_hash,
                .owner_id = Ops.ownerId(entry.owner),
                .owner_kind = Ops.ownerKind(entry.owner),
                .value_type = value_type,
            };
        }

        fn cleanupDeltaAfterCompaction(store: StoreType) bool {
            Ops.deleteDeltaFile(store) catch return false;
            Ops.syncParentDir(store, Ops.deltaPath(store)) catch return false;
            return true;
        }

        pub fn compactDelta(store: StoreType, allocator: std.mem.Allocator) !CompactionResult {
            _ = try recoverDeltaJournal(store);
            const scan = try Ops.scanDelta(store, allocator, false);
            if (scan.valid_bytes == 0) return .{};
            // Stream the merged base+delta state through the restartable
            // two-pass publication instead of materializing every live entry:
            // compaction memory stays O(delta + one record) and peak staging
            // stays one raw file, while commit ordering is unchanged.
            var merge = try Ops.openCompactionMerge(store, allocator);
            defer Ops.closeCompactionMerge(store, &merge);
            const live_entries = Ops.compactionMergeExpectedCount(&merge);
            try replaceEmptyBaseFromRestartableSortedStream(
                store,
                live_entries,
                Ops.compactionMergeContext(&merge),
                Ops.compactionMergeRestart,
                Ops.compactionMergeNext,
            );
            const cleanup_pending = !cleanupDeltaAfterCompaction(store);
            return .{
                .compacted = true,
                .cleanup_pending = cleanup_pending,
                .delta_bytes = scan.valid_bytes,
                .delta_frames = scan.last_sequence,
                .live_entries = live_entries,
            };
        }

        /// Explicit crash-window construction hooks for the Store integration
        /// tests. Production callers use only the complete transaction entry
        /// points above; keeping partial publication operations under this
        /// namespace prevents them from masquerading as supported workflows.
        pub const Testing = struct {
            pub fn deltaRedoPath(store: StoreType) ![]u8 {
                return deltaJournalPath(store);
            }

            pub fn baseRedoPath(store: StoreType) ![]u8 {
                return baseRedoJournalPath(store);
            }

            pub fn encodeDelta(allocator: std.mem.Allocator, sequence: u64, writes: []const Write) ![]u8 {
                return encodeDeltaFrame(allocator, sequence, writes);
            }

            pub fn writeDeltaRedo(store: StoreType, frame: []const u8) !void {
                return writeDeltaJournal(store, frame);
            }

            pub fn appendDelta(store: StoreType, frame: []const u8, expected_offset: u64) !void {
                return appendDeltaFrame(store, frame, expected_offset);
            }

            pub fn writeIndexStage(store: StoreType, path: []const u8, entries: []const Entry) !void {
                return Self.writeIndexStage(store, path, entries);
            }

            pub fn writeValueStage(store: StoreType, path: []const u8, entries: []const Entry) !void {
                return Self.writeValueStage(store, path, entries);
            }

            pub fn writeBaseRedo(store: StoreType, index_stage_path: []const u8, values_stage_path: []const u8) !void {
                return writeBaseRedoJournal(store, index_stage_path, values_stage_path);
            }

            pub fn cleanupCompactedDelta(store: StoreType) bool {
                return cleanupDeltaAfterCompaction(store);
            }
        };
    };
}

const TestOwner = union(enum) {
    node: u64,
    edge: u64,
};

const TestValue = union(enum) {
    string: []const u8,
    uint: u64,
};

const TestWrite = struct {
    owner: TestOwner,
    key: []const u8,
    value: TestValue,
};

const TestSortedEntry = struct {
    owner: TestOwner,
    key_hash: u64,
    value: TestValue,
};

const TestSortedNext = *const fn (context: *anyopaque) anyerror!?TestSortedEntry;

const TestEntry = struct {
    record: PropertyPayloadIndexRecord,
    value: ?[]u8 = null,
};

const TestCompactionMerge = struct {
    entries: std.ArrayList(TestEntry),
    entries_allocator: std.mem.Allocator,
    index: usize = 0,

    fn restart(context: *anyopaque) anyerror!void {
        const self: *TestCompactionMerge = @ptrCast(@alignCast(context));
        self.index = 0;
    }

    fn next(context: *anyopaque) anyerror!?TestSortedEntry {
        const self: *TestCompactionMerge = @ptrCast(@alignCast(context));
        if (self.index >= self.entries.items.len) return null;
        const entry = self.entries.items[self.index];
        self.index += 1;
        const owner: TestOwner = switch (entry.record.owner_kind) {
            1 => .{ .node = entry.record.owner_id },
            2 => .{ .edge = entry.record.owner_id },
            else => return error.InvalidRecord,
        };
        const value: TestValue = if (entry.record.value_type == PropertyPayloadIndexRecord.value_type_string)
            .{ .string = entry.value orelse return error.InvalidRecord }
        else
            .{ .uint = entry.record.value_hash };
        return .{ .owner = owner, .key_hash = entry.record.key_hash, .value = value };
    }
};

const TestDeltaScan = struct {
    valid_bytes: u64 = 0,
    last_sequence: u64 = 0,
    last_digest: u64 = 0,
    trailing_partial: bool = false,
};

const TestDeltaRecovery = enum {
    no_journal,
    committed,
};

const TestCompactionResult = struct {
    compacted: bool = false,
    cleanup_pending: bool = false,
    delta_bytes: u64 = 0,
    delta_frames: u64 = 0,
    live_entries: u64 = 0,
};

const TestPhase = enum {
    delta_journal_publish,
    delta_validate,
    delta_scan,
    delta_parent_sync,
    delta_cleanup,
    compaction_delta_cleanup,
    base_redo_publish,
    base_validate,
    values_publish,
    index_publish,
    base_cleanup,
    load_entries,
};

const TestState = struct {
    phases: [32]TestPhase = undefined,
    phase_count: usize = 0,
    fail_at: ?TestPhase = null,
    scan: TestDeltaScan = .{},
    scan_error: bool = false,
    entries: []const TestEntry = &.{},

    fn record(self: *TestState, phase: TestPhase) !void {
        self.phases[self.phase_count] = phase;
        self.phase_count += 1;
        if (self.fail_at == phase) return error.InjectedFailure;
    }

    fn recorded(self: *const TestState) []const TestPhase {
        return self.phases[0..self.phase_count];
    }

    fn reset(self: *TestState) void {
        const fail_at = self.fail_at;
        const scan = self.scan;
        const scan_error = self.scan_error;
        const entries = self.entries;
        self.* = .{
            .fail_at = fail_at,
            .scan = scan,
            .scan_error = scan_error,
            .entries = entries,
        };
    }
};

const TestStore = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    index_path: []const u8,
    values_path: []const u8,
    delta_path: []const u8,
    state: *TestState,
};

const TestOps = struct {
    pub const StoreType = TestStore;
    pub const EntryType = TestEntry;
    pub const WriteType = TestWrite;
    pub const SortedNextType = TestSortedNext;
    pub const DeltaScanType = TestDeltaScan;
    pub const DeltaRecoveryType = TestDeltaRecovery;
    pub const CompactionResultType = TestCompactionResult;

    pub fn allocator(store: TestStore) std.mem.Allocator {
        return store.allocator;
    }

    pub fn io(store: TestStore) std.Io {
        return store.io;
    }

    pub fn indexPath(store: TestStore) []const u8 {
        return store.index_path;
    }

    pub fn valuesPath(store: TestStore) []const u8 {
        return store.values_path;
    }

    pub fn deltaPath(store: TestStore) []const u8 {
        return store.delta_path;
    }

    pub fn shouldSync(_: TestStore) bool {
        return false;
    }

    pub fn tmpPath(store: TestStore, path: []const u8) ![]u8 {
        return try std.fmt.allocPrint(store.allocator, "{s}.tmp", .{path});
    }

    fn pathPhase(store: TestStore, path: []const u8) !?TestPhase {
        const allocator_arg = store.allocator;
        const delta_redo = try std.fmt.allocPrint(allocator_arg, "{s}.redo", .{store.delta_path});
        defer allocator_arg.free(delta_redo);
        const base_redo = try std.fmt.allocPrint(allocator_arg, "{s}.redo", .{store.index_path});
        defer allocator_arg.free(base_redo);
        if (std.mem.eql(u8, path, delta_redo)) return .delta_journal_publish;
        if (std.mem.eql(u8, path, base_redo)) return .base_redo_publish;
        if (std.mem.eql(u8, path, store.values_path)) return .values_publish;
        if (std.mem.eql(u8, path, store.index_path)) return .index_publish;
        return null;
    }

    pub fn renameReplace(store: TestStore, tmp_path: []const u8, final_path: []const u8) !void {
        if (try pathPhase(store, final_path)) |phase| try store.state.record(phase);
        try std.Io.Dir.renameAbsolute(tmp_path, final_path, store.io);
    }

    pub fn syncParentDir(store: TestStore, path: []const u8) !void {
        const allocator_arg = store.allocator;
        const delta_redo = try std.fmt.allocPrint(allocator_arg, "{s}.redo", .{store.delta_path});
        defer allocator_arg.free(delta_redo);
        const base_redo = try std.fmt.allocPrint(allocator_arg, "{s}.redo", .{store.index_path});
        defer allocator_arg.free(base_redo);
        if (std.mem.eql(u8, path, delta_redo)) return store.state.record(.delta_cleanup);
        if (std.mem.eql(u8, path, base_redo)) return store.state.record(.base_cleanup);
        if (std.mem.eql(u8, path, store.delta_path)) return store.state.record(.delta_parent_sync);
    }

    pub fn fileExists(store: TestStore, path: []const u8) !bool {
        std.Io.Dir.cwd().access(store.io, path, .{}) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => |other| return other,
        };
        return true;
    }

    pub fn deleteDeltaFile(store: TestStore) !void {
        try store.state.record(.compaction_delta_cleanup);
        try std.Io.Dir.cwd().deleteFile(store.io, store.delta_path);
    }

    pub fn keyNameValid(key: []const u8) bool {
        return key.len > 0 and key.len <= 128;
    }

    pub fn keyHash(key: []const u8) u64 {
        return std.hash.Wyhash.hash(0x544B_504B, key);
    }

    pub fn valueHash(value: []const u8) u64 {
        return std.hash.Wyhash.hash(value_digest_seed, value);
    }

    pub fn ownerKind(owner: TestOwner) u8 {
        return switch (owner) {
            .node => PropertyPayloadIndexRecord.owner_kind_node,
            .edge => PropertyPayloadIndexRecord.owner_kind_edge,
        };
    }

    pub fn ownerId(owner: TestOwner) u64 {
        return switch (owner) {
            .node => |id| id,
            .edge => |id| id,
        };
    }

    pub fn validateDeltaFrame(store: TestStore, header: PropertyPayloadDeltaHeader, payload: []const u8) !void {
        try store.state.record(.delta_validate);
        if (payload.len != header.payload_len or std.hash.Wyhash.hash(delta_digest_seed, payload) != header.payload_digest) return error.InvalidRecord;
    }

    pub fn scanDelta(store: TestStore, _: std.mem.Allocator, _: bool) !TestDeltaScan {
        try store.state.record(.delta_scan);
        if (store.state.scan_error) return error.RecoveryInjected;
        return store.state.scan;
    }

    pub fn validateRestoredBasePair(store: TestStore, _: []const u8, _: []const u8) !void {
        try store.state.record(.base_validate);
    }

    pub fn readEntriesOrEmpty(store: TestStore, allocator_arg: std.mem.Allocator) !std.ArrayList(TestEntry) {
        try store.state.record(.load_entries);
        var entries = std.ArrayList(TestEntry).empty;
        errdefer entries.deinit(allocator_arg);
        try entries.appendSlice(allocator_arg, store.state.entries);
        return entries;
    }

    pub fn deinitEntries(allocator_arg: std.mem.Allocator, entries: *std.ArrayList(TestEntry)) void {
        entries.deinit(allocator_arg);
    }

    pub const CompactionMergeType = TestCompactionMerge;

    pub fn openCompactionMerge(store: TestStore, allocator_arg: std.mem.Allocator) !TestCompactionMerge {
        return .{
            .entries = try readEntriesOrEmpty(store, allocator_arg),
            .entries_allocator = allocator_arg,
        };
    }

    pub fn closeCompactionMerge(_: TestStore, merge: *TestCompactionMerge) void {
        merge.entries.deinit(merge.entries_allocator);
        merge.* = undefined;
    }

    pub fn compactionMergeExpectedCount(merge: *TestCompactionMerge) u64 {
        return @intCast(merge.entries.items.len);
    }

    pub fn compactionMergeContext(merge: *TestCompactionMerge) *anyopaque {
        return @ptrCast(merge);
    }

    pub const compactionMergeRestart = TestCompactionMerge.restart;
    pub const compactionMergeNext = TestCompactionMerge.next;
};

const test_transaction = PropertyPayloadTransaction(TestOps);

const TestLayout = struct {
    index_path: []u8,
    values_path: []u8,
    delta_path: []u8,

    fn init(tmp: *std.testing.TmpDir, path_buffer: []u8) !TestLayout {
        const root_len = try tmp.dir.realPath(std.testing.io, path_buffer);
        const root = path_buffer[0..root_len];
        const index_path = try std.fs.path.join(std.testing.allocator, &.{ root, "property_payload.idx" });
        errdefer std.testing.allocator.free(index_path);
        const values_path = try std.fs.path.join(std.testing.allocator, &.{ root, "property_payload.values" });
        errdefer std.testing.allocator.free(values_path);
        return .{
            .index_path = index_path,
            .values_path = values_path,
            .delta_path = try std.fs.path.join(std.testing.allocator, &.{ root, "property_payload.delta" }),
        };
    }

    fn deinit(self: *TestLayout) void {
        std.testing.allocator.free(self.index_path);
        std.testing.allocator.free(self.values_path);
        std.testing.allocator.free(self.delta_path);
    }

    fn store(self: TestLayout, state: *TestState) TestStore {
        return .{
            .allocator = std.testing.allocator,
            .io = std.testing.io,
            .index_path = self.index_path,
            .values_path = self.values_path,
            .delta_path = self.delta_path,
            .state = state,
        };
    }

    fn deltaRedoPath(self: TestLayout) ![]u8 {
        return try std.fmt.allocPrint(std.testing.allocator, "{s}.redo", .{self.delta_path});
    }

    fn baseRedoPath(self: TestLayout) ![]u8 {
        return try std.fmt.allocPrint(std.testing.allocator, "{s}.redo", .{self.index_path});
    }
};

fn writeTestFile(path: []const u8, bytes: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = path,
        .data = bytes,
        .flags = .{ .truncate = true },
    });
}

fn testPathExists(path: []const u8) !bool {
    std.Io.Dir.cwd().access(std.testing.io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => |other| return other,
    };
    return true;
}

const one_test_write = [_]TestWrite{.{
    .owner = .{ .node = 1 },
    .key = "name",
    .value = .{ .string = "alpha" },
}};

fn initTestLayout(tmp: *std.testing.TmpDir, path_buffer: []u8, state: *TestState) !struct { TestLayout, TestStore } {
    const layout = try TestLayout.init(tmp, path_buffer);
    return .{ layout, layout.store(state) };
}

test "property payload transaction publishes delta journal append and cleanup in order" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var state = TestState{};
    const initialized = try initTestLayout(&tmp, &buffer, &state);
    var layout = initialized[0];
    defer layout.deinit();

    try test_transaction.publishDelta(initialized[1], std.testing.allocator, &one_test_write, .{});

    try std.testing.expectEqualSlices(TestPhase, &.{
        .delta_journal_publish,
        .delta_parent_sync,
        .delta_cleanup,
    }, state.recorded());
    try std.testing.expect(try testPathExists(layout.delta_path));
    const redo_path = try layout.deltaRedoPath();
    defer std.testing.allocator.free(redo_path);
    try std.testing.expect(!try testPathExists(redo_path));
}

test "property payload transaction recovers append errors before returning" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var state = TestState{ .scan = .{ .valid_bytes = 1 } };
    const initialized = try initTestLayout(&tmp, &buffer, &state);
    var layout = initialized[0];
    defer layout.deinit();
    try writeTestFile(layout.delta_path, "x");

    try test_transaction.publishDelta(initialized[1], std.testing.allocator, &one_test_write, .{});

    try std.testing.expectEqualSlices(TestPhase, &.{
        .delta_journal_publish,
        .delta_validate,
        .delta_scan,
        .delta_cleanup,
    }, state.recorded());
}

test "property payload transaction surfaces recovery error before append error" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var state = TestState{ .scan_error = true };
    const initialized = try initTestLayout(&tmp, &buffer, &state);
    var layout = initialized[0];
    defer layout.deinit();
    try writeTestFile(layout.delta_path, "x");

    try std.testing.expectError(
        error.RecoveryInjected,
        test_transaction.publishDelta(initialized[1], std.testing.allocator, &one_test_write, .{}),
    );
    try std.testing.expectEqualSlices(TestPhase, &.{
        .delta_journal_publish,
        .delta_validate,
        .delta_scan,
    }, state.recorded());
}

test "property payload transaction rejects partial scan before mutation" {
    var state = TestState{};
    const store = TestStore{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .index_path = "unused-index",
        .values_path = "unused-values",
        .delta_path = "unused-delta",
        .state = &state,
    };
    try std.testing.expectError(
        error.InvalidRecord,
        test_transaction.publishDelta(store, std.testing.allocator, &one_test_write, .{ .trailing_partial = true }),
    );
    try std.testing.expectEqual(@as(usize, 0), state.phase_count);
}

test "property payload transaction recovery skips scan without journal" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var state = TestState{};
    const initialized = try initTestLayout(&tmp, &buffer, &state);
    var layout = initialized[0];
    defer layout.deinit();

    try std.testing.expectEqual(TestDeltaRecovery.no_journal, try test_transaction.recoverDeltaJournal(initialized[1]));
    try std.testing.expectEqual(@as(usize, 0), state.phase_count);
}

fn uintTestEntry() TestEntry {
    return .{
        .record = .{
            .key_hash = TestOps.keyHash("rank"),
            .value_hash = 7,
            .owner_id = 1,
            .owner_kind = PropertyPayloadIndexRecord.owner_kind_node,
            .value_type = PropertyPayloadIndexRecord.value_type_uint,
        },
    };
}

test "property payload transaction publishes values before index and cleans redo last" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var state = TestState{};
    const initialized = try initTestLayout(&tmp, &buffer, &state);
    var layout = initialized[0];
    defer layout.deinit();
    var entries = [_]TestEntry{uintTestEntry()};

    try test_transaction.publishBase(initialized[1], &entries);

    try std.testing.expectEqualSlices(TestPhase, &.{
        .base_redo_publish,
        .values_publish,
        .index_publish,
        .base_cleanup,
    }, state.recorded());
    try std.testing.expect(try testPathExists(layout.index_path));
    try std.testing.expect(try testPathExists(layout.values_path));
}

test "property payload transaction preserves redo after values rename failure" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var state = TestState{ .fail_at = .values_publish };
    const initialized = try initTestLayout(&tmp, &buffer, &state);
    var layout = initialized[0];
    defer layout.deinit();
    var entries = [_]TestEntry{uintTestEntry()};

    try std.testing.expectError(error.InjectedFailure, test_transaction.publishBase(initialized[1], &entries));

    const redo_path = try layout.baseRedoPath();
    defer std.testing.allocator.free(redo_path);
    try std.testing.expect(try testPathExists(redo_path));
    try std.testing.expect(!try testPathExists(layout.index_path));
}

test "property payload transaction validates recovered pair before renaming" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var state = TestState{ .fail_at = .values_publish };
    const initialized = try initTestLayout(&tmp, &buffer, &state);
    var layout = initialized[0];
    defer layout.deinit();
    var entries = [_]TestEntry{uintTestEntry()};
    try std.testing.expectError(error.InjectedFailure, test_transaction.publishBase(initialized[1], &entries));
    state.fail_at = null;
    state.reset();

    try test_transaction.recoverBaseRedoJournal(initialized[1]);

    try std.testing.expectEqualSlices(TestPhase, &.{
        .base_validate,
        .values_publish,
        .index_publish,
        .base_cleanup,
    }, state.recorded());
}

test "property payload transaction rejects corrupt redo before publication" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var state = TestState{};
    const initialized = try initTestLayout(&tmp, &buffer, &state);
    var layout = initialized[0];
    defer layout.deinit();
    const redo_path = try layout.baseRedoPath();
    defer std.testing.allocator.free(redo_path);
    try writeTestFile(redo_path, &([_]u8{0} ** PropertyPayloadRedoJournalHeader.encoded_len));

    try std.testing.expectError(error.InvalidRecord, test_transaction.recoverBaseRedoJournal(initialized[1]));
    try std.testing.expectEqual(@as(usize, 0), state.phase_count);
}

test "property payload transaction surfaces redo cleanup failure after commit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var state = TestState{ .fail_at = .base_cleanup };
    const initialized = try initTestLayout(&tmp, &buffer, &state);
    var layout = initialized[0];
    defer layout.deinit();
    var entries = [_]TestEntry{uintTestEntry()};

    try std.testing.expectError(error.InjectedFailure, test_transaction.publishBase(initialized[1], &entries));

    try std.testing.expect(try testPathExists(layout.index_path));
    try std.testing.expect(try testPathExists(layout.values_path));
    try std.testing.expectEqual(TestPhase.base_cleanup, state.recorded()[state.phase_count - 1]);
}

test "property payload transaction compacts base before retryable delta cleanup" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const entry = uintTestEntry();
    var state = TestState{
        .fail_at = .compaction_delta_cleanup,
        .scan = .{ .valid_bytes = 99, .last_sequence = 3 },
        .entries = &.{entry},
    };
    const initialized = try initTestLayout(&tmp, &buffer, &state);
    var layout = initialized[0];
    defer layout.deinit();
    try writeTestFile(layout.delta_path, "delta");

    const result = try test_transaction.compactDelta(initialized[1], std.testing.allocator);

    try std.testing.expect(result.compacted);
    try std.testing.expect(result.cleanup_pending);
    try std.testing.expectEqual(@as(u64, 99), result.delta_bytes);
    try std.testing.expectEqualSlices(TestPhase, &.{
        .delta_scan,
        .load_entries,
        .base_redo_publish,
        .values_publish,
        .index_publish,
        .base_cleanup,
        .compaction_delta_cleanup,
    }, state.recorded());
}

test "property payload transaction skips empty compaction without loading entries" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var state = TestState{};
    const initialized = try initTestLayout(&tmp, &buffer, &state);
    var layout = initialized[0];
    defer layout.deinit();

    const result = try test_transaction.compactDelta(initialized[1], std.testing.allocator);

    try std.testing.expect(!result.compacted);
    try std.testing.expectEqualSlices(TestPhase, &.{.delta_scan}, state.recorded());
}

const TestStream = struct {
    entries: []const TestSortedEntry,
    index: usize = 0,

    fn next(context: *anyopaque) anyerror!?TestSortedEntry {
        const self: *TestStream = @ptrCast(@alignCast(context));
        if (self.index >= self.entries.len) return null;
        defer self.index += 1;
        return self.entries[self.index];
    }
};

test "property payload transaction streams canonical base through one redo commit" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var state = TestState{};
    const initialized = try initTestLayout(&tmp, &buffer, &state);
    var layout = initialized[0];
    defer layout.deinit();
    var stream = TestStream{ .entries = &.{
        .{ .owner = .{ .node = 1 }, .key_hash = 1, .value = .{ .string = "alpha" } },
        .{ .owner = .{ .node = 2 }, .key_hash = 2, .value = .{ .uint = 9 } },
    } };

    try test_transaction.replaceEmptyBaseFromSortedStream(initialized[1], 2, &stream, TestStream.next);

    try std.testing.expectEqualSlices(TestPhase, &.{
        .base_redo_publish,
        .values_publish,
        .index_publish,
        .base_cleanup,
    }, state.recorded());
    var index_file = try std.Io.Dir.cwd().openFile(std.testing.io, layout.index_path, .{});
    defer index_file.close(std.testing.io);
    var index_view = try property_block_codec.View.init(std.testing.allocator, std.testing.io, index_file);
    defer index_view.deinit();
    var header_bytes: [PropertyPayloadIndexHeader.encoded_len]u8 = undefined;
    try index_view.readAt(0, &header_bytes);
    try std.testing.expectEqual(@as(u64, 2), (try PropertyPayloadIndexHeader.decode(&header_bytes)).record_count);
}

const RestartableTestStream = struct {
    entries: []const TestSortedEntry,
    drift_entries: ?[]const TestSortedEntry = null,
    index: usize = 0,
    passes: usize = 0,

    fn restart(context: *anyopaque) anyerror!void {
        const self: *RestartableTestStream = @ptrCast(@alignCast(context));
        self.index = 0;
        self.passes += 1;
        if (self.drift_entries) |drift| self.entries = drift;
    }

    fn next(context: *anyopaque) anyerror!?TestSortedEntry {
        const self: *RestartableTestStream = @ptrCast(@alignCast(context));
        if (self.index >= self.entries.len) return null;
        defer self.index += 1;
        return self.entries[self.index];
    }
};

test "property payload transaction restartable stream publishes one stage at a time" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var state = TestState{};
    const initialized = try initTestLayout(&tmp, &buffer, &state);
    var layout = initialized[0];
    defer layout.deinit();
    var stream = RestartableTestStream{ .entries = &.{
        .{ .owner = .{ .node = 1 }, .key_hash = 1, .value = .{ .string = "alpha" } },
        .{ .owner = .{ .node = 2 }, .key_hash = 2, .value = .{ .uint = 9 } },
        .{ .owner = .{ .node = 3 }, .key_hash = 3, .value = .{ .string = "gamma" } },
    } };

    try test_transaction.replaceEmptyBaseFromRestartableSortedStream(
        initialized[1],
        3,
        &stream,
        RestartableTestStream.restart,
        RestartableTestStream.next,
    );

    try std.testing.expectEqual(@as(usize, 1), stream.passes);
    try std.testing.expectEqualSlices(TestPhase, &.{
        .base_redo_publish,
        .values_publish,
        .index_publish,
        .base_cleanup,
    }, state.recorded());
    var index_file = try std.Io.Dir.cwd().openFile(std.testing.io, layout.index_path, .{});
    defer index_file.close(std.testing.io);
    var index_view = try property_block_codec.View.init(std.testing.allocator, std.testing.io, index_file);
    defer index_view.deinit();
    var header_bytes: [PropertyPayloadIndexHeader.encoded_len]u8 = undefined;
    try index_view.readAt(0, &header_bytes);
    try std.testing.expectEqual(@as(u64, 3), (try PropertyPayloadIndexHeader.decode(&header_bytes)).record_count);
    var values_file = try std.Io.Dir.cwd().openFile(std.testing.io, layout.values_path, .{});
    defer values_file.close(std.testing.io);
    var values_view = try property_block_codec.View.init(std.testing.allocator, std.testing.io, values_file);
    defer values_view.deinit();
    var values_header_bytes: [NodePropertyValueBlockHeader.encoded_len]u8 = undefined;
    try values_view.readAt(0, &values_header_bytes);
    const values_header = try NodePropertyValueBlockHeader.decode(&values_header_bytes);
    try std.testing.expectEqual(@as(u64, 3), values_header.record_count);
    try std.testing.expectEqual(@as(u64, "alpha".len + "gamma".len), values_header.payload_bytes);
}

test "property payload transaction restartable stream rejects second-pass drift" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var state = TestState{};
    const initialized = try initTestLayout(&tmp, &buffer, &state);
    var layout = initialized[0];
    defer layout.deinit();
    var stream = RestartableTestStream{
        .entries = &.{
            .{ .owner = .{ .node = 1 }, .key_hash = 1, .value = .{ .string = "alpha" } },
            .{ .owner = .{ .node = 2 }, .key_hash = 2, .value = .{ .uint = 9 } },
        },
        .drift_entries = &.{
            .{ .owner = .{ .node = 1 }, .key_hash = 1, .value = .{ .string = "alpha" } },
            .{ .owner = .{ .node = 2 }, .key_hash = 2, .value = .{ .uint = 10 } },
        },
    };

    try std.testing.expectError(error.InvalidRecord, test_transaction.replaceEmptyBaseFromRestartableSortedStream(
        initialized[1],
        2,
        &stream,
        RestartableTestStream.restart,
        RestartableTestStream.next,
    ));
    try std.testing.expectEqualSlices(TestPhase, &.{}, state.recorded());
}
