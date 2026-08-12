const std = @import("std");

/// Owns the complete primary node-text persistence protocol behind the Store
/// facade: raw and block-deflate formats, logical read views, resumable
/// finalize, append mutation, and the durable undo/commit journal. `Ops`
/// supplies only Store-specific paths, policy, index repair, atomic publish,
/// and mmap capabilities; persisted bytes and mutation ordering live here.
pub fn PrimaryNodeText(comptime Ops: type) type {
    return struct {
        const Self = @This();
        const StoreType = Ops.StoreType;

        pub const StorageFormat = enum {
            raw,
            block_deflate,
        };

        const block_deflate_magic = [_]u8{ 'T', 'K', 'N', 'Z' };
        pub const block_deflate_version: u16 = 5;
        pub const block_deflate_header_len: usize = 16;
        pub const block_deflate_entry_len: usize = 4;
        pub const block_deflate_block_bytes: u32 = 256 * 1024;
        pub const raw_mmap_max_bytes: u64 = 64 * 1024 * 1024;
        const block_deflate_flag_compressed: u16 = 1 << 0;
        const append_journal_magic = [_]u8{ 'T', 'K', 'N', 'A' };
        const append_journal_version: u16 = 3;
        pub const append_journal_checksummed_version: u16 = 2;
        const append_journal_legacy_version: u16 = 1;
        pub const append_journal_header_len: usize = 64;
        const append_journal_hash_seed: u64 = 0x544B_4E41;
        pub const append_journal_header_hash_seed: u64 = 0x544B_4E48;
        pub const deflate_progress_entry_len: usize = 20;
        pub const deflate_progress_hash_seed: u64 = 0x544B_4E50;

        // Keep synchronous ingestion at level 3. Deeper compression belongs
        // to an offline maintenance pass, not the foreground append path.
        pub const block_deflate_level_number: u8 = 3;
        pub const block_deflate_level = std.compress.flate.Compress.Options.level_3;

        pub const AppendJournalHeader = struct {
            original_size: u64,
            suffix_offset: u64,
            suffix_len: u64,
            suffix_hash: u64,
            original_header: [block_deflate_header_len]u8,
            original_format: StorageFormat = .block_deflate,
            committed: bool = false,

            pub fn decode(bytes: *const [append_journal_header_len]u8) !AppendJournalHeader {
                if (!std.mem.eql(u8, bytes[0..4], &append_journal_magic)) return error.InvalidRecord;
                const version = readU16(bytes[4..6]);
                if (version != append_journal_version and
                    version != append_journal_checksummed_version and
                    version != append_journal_legacy_version) return error.InvalidRecord;
                if (readU16(bytes[6..8]) != append_journal_header_len) return error.InvalidRecord;
                if (bytes[56] > 1) return error.InvalidRecord;
                if (version == append_journal_legacy_version) {
                    if (!allZero(bytes[57..64])) return error.InvalidRecord;
                } else {
                    var digest_bytes: [8]u8 = undefined;
                    writeU64(&digest_bytes, std.hash.Wyhash.hash(append_journal_header_hash_seed, bytes[0..57]));
                    if (!std.mem.eql(u8, bytes[57..64], digest_bytes[0..7])) return error.InvalidRecord;
                }
                var original_header: [block_deflate_header_len]u8 = undefined;
                @memcpy(&original_header, bytes[40..56]);
                const original_format: StorageFormat = if (version == append_journal_version and allZero(&original_header))
                    .raw
                else
                    .block_deflate;
                return .{
                    .original_size = readU64(bytes[8..16]),
                    .suffix_offset = readU64(bytes[16..24]),
                    .suffix_len = readU64(bytes[24..32]),
                    .suffix_hash = readU64(bytes[32..40]),
                    .original_header = original_header,
                    .original_format = original_format,
                    .committed = bytes[56] == 1,
                };
            }

            pub fn encode(self: AppendJournalHeader, out: *[append_journal_header_len]u8) !void {
                if (self.suffix_offset > self.original_size or self.suffix_len != self.original_size - self.suffix_offset) return error.InvalidRecord;
                switch (self.original_format) {
                    .raw => {
                        if (self.suffix_offset != self.original_size or self.suffix_len != 0) return error.InvalidRecord;
                        if (self.suffix_hash != std.hash.Wyhash.hash(append_journal_hash_seed, &.{})) return error.InvalidRecord;
                        if (!allZero(&self.original_header)) return error.InvalidRecord;
                    },
                    .block_deflate => {
                        if (self.original_size < block_deflate_header_len) return error.InvalidRecord;
                        _ = try BlockDeflateHeader.decode(&self.original_header);
                    },
                }
                @memcpy(out[0..4], &append_journal_magic);
                writeU16(out[4..6], append_journal_version);
                writeU16(out[6..8], append_journal_header_len);
                writeU64(out[8..16], self.original_size);
                writeU64(out[16..24], self.suffix_offset);
                writeU64(out[24..32], self.suffix_len);
                writeU64(out[32..40], self.suffix_hash);
                @memcpy(out[40..56], &self.original_header);
                out[56] = @intFromBool(self.committed);
                var digest_bytes: [8]u8 = undefined;
                writeU64(&digest_bytes, std.hash.Wyhash.hash(append_journal_header_hash_seed, out[0..57]));
                @memcpy(out[57..64], digest_bytes[0..7]);
            }
        };

        pub const BlockDeflateHeader = struct {
            logical_size: u64,

            pub fn decode(bytes: *const [block_deflate_header_len]u8) !BlockDeflateHeader {
                if (!std.mem.eql(u8, bytes[0..4], &block_deflate_magic)) return error.InvalidRecord;
                if (readU16(bytes[4..6]) != block_deflate_version) return error.InvalidRecord;
                if (readU16(bytes[6..8]) != block_deflate_header_len) return error.InvalidRecord;
                const header = BlockDeflateHeader{ .logical_size = readU64(bytes[8..16]) };
                try header.validate();
                return header;
            }

            pub fn encode(self: BlockDeflateHeader, out: *[block_deflate_header_len]u8) !void {
                try self.validate();
                @memcpy(out[0..4], &block_deflate_magic);
                writeU16(out[4..6], block_deflate_version);
                writeU16(out[6..8], block_deflate_header_len);
                writeU64(out[8..16], self.logical_size);
            }

            pub fn validate(self: BlockDeflateHeader) !void {
                if (self.logical_size == 0) return error.InvalidRecord;
                _ = try self.blockCount();
            }

            pub fn blockCount(self: BlockDeflateHeader) !u32 {
                const rounded_size = std.math.add(u64, self.logical_size, block_deflate_block_bytes - 1) catch return error.InvalidRecord;
                const count = rounded_size / block_deflate_block_bytes;
                if (count == 0) return error.InvalidRecord;
                return std.math.cast(u32, count) orelse return error.InvalidRecord;
            }

            pub fn tableBytes(self: BlockDeflateHeader) !u64 {
                return std.math.mul(u64, try self.blockCount(), block_deflate_entry_len) catch return error.InvalidRecord;
            }

            pub fn tableOffset(self: BlockDeflateHeader, physical_size: u64) !u64 {
                const table_bytes = try self.tableBytes();
                if (physical_size < block_deflate_header_len or table_bytes > physical_size - block_deflate_header_len) return error.InvalidRecord;
                const table_offset = physical_size - table_bytes;
                if (table_offset < block_deflate_header_len) return error.InvalidRecord;
                return table_offset;
            }

            pub fn payloadOffset(_: BlockDeflateHeader) u64 {
                return block_deflate_header_len;
            }

            pub fn rawLenForBlock(self: BlockDeflateHeader, block_index: usize) !u32 {
                const block_count = try self.blockCount();
                if (block_index >= block_count) return error.InvalidRecord;
                const logical_offset = std.math.mul(u64, @intCast(block_index), block_deflate_block_bytes) catch return error.InvalidRecord;
                const remaining = self.logical_size - logical_offset;
                return @intCast(@min(remaining, block_deflate_block_bytes));
            }
        };

        pub const BlockDeflateEntry = struct {
            physical_offset: u64,
            stored_len: u32,
            raw_len: u32,
            flags: u16,

            pub fn decode(bytes: *const [block_deflate_entry_len]u8, physical_offset: u64, raw_len: u32) !BlockDeflateEntry {
                const stored_len = readU32(bytes[0..4]);
                const entry = BlockDeflateEntry{
                    .physical_offset = physical_offset,
                    .stored_len = stored_len,
                    .raw_len = raw_len,
                    .flags = if (stored_len < raw_len) block_deflate_flag_compressed else 0,
                };
                try entry.validate();
                return entry;
            }

            pub fn encode(self: BlockDeflateEntry, out: *[block_deflate_entry_len]u8) !void {
                try self.validate();
                writeU32(out[0..4], self.stored_len);
            }

            pub fn validate(self: BlockDeflateEntry) !void {
                if (self.physical_offset == 0 or self.stored_len == 0 or self.raw_len == 0) return error.InvalidRecord;
                if (self.raw_len > block_deflate_block_bytes) return error.InvalidRecord;
                if ((self.flags & ~block_deflate_flag_compressed) != 0) return error.InvalidRecord;
                if ((self.flags & block_deflate_flag_compressed) == 0 and self.stored_len != self.raw_len) return error.InvalidRecord;
            }
        };

        const BlockCache = struct {
            block_index: ?usize = null,
            bytes: []u8 = &.{},

            fn deinit(self: *BlockCache, allocator: std.mem.Allocator) void {
                allocator.free(self.bytes);
                self.* = .{};
            }
        };

        pub const View = struct {
            store: StoreType,
            file: std.Io.File,
            map: ?std.Io.File.MemoryMap = null,
            size: u64,
            format: StorageFormat = .raw,
            blocks: []BlockDeflateEntry = &.{},
            block_cache: ?*BlockCache = null,

            pub fn open(store: StoreType) !View {
                _ = try Self.recoverAppendJournal(store);
                const io = Ops.io(store);
                const allocator = Ops.allocator(store);
                var file = try std.Io.Dir.cwd().openFile(io, Ops.nodeTextsPath(store), .{});
                errdefer file.close(io);
                const physical_size = try regularFileSize(io, file);
                if (physical_size >= block_deflate_header_len) {
                    var header_bytes: [block_deflate_header_len]u8 = undefined;
                    const n = try file.readPositionalAll(io, &header_bytes, 0);
                    if (n != header_bytes.len) return error.InvalidRecord;
                    const header_slice = header_bytes[0..];
                    if (std.mem.eql(u8, header_slice[0..4], &block_deflate_magic) and
                        readU16(header_slice[4..6]) == block_deflate_version and
                        readU16(header_slice[6..8]) == block_deflate_header_len)
                    {
                        const header = try BlockDeflateHeader.decode(header_slice[0..block_deflate_header_len]);
                        const block_count = try header.blockCount();
                        const payload_offset = header.payloadOffset();
                        const table_offset = try header.tableOffset(physical_size);
                        if (payload_offset > table_offset) return error.InvalidRecord;
                        const blocks = try allocator.alloc(BlockDeflateEntry, block_count);
                        errdefer allocator.free(blocks);
                        const table_bytes_len = std.math.cast(usize, try header.tableBytes()) orelse return error.RecordTooLarge;
                        const table_bytes = try allocator.alloc(u8, table_bytes_len);
                        defer allocator.free(table_bytes);
                        const table_n = try file.readPositionalAll(io, table_bytes, table_offset);
                        if (table_n != table_bytes.len) return error.InvalidRecord;
                        const block_cache = try allocator.create(BlockCache);
                        errdefer allocator.destroy(block_cache);
                        block_cache.* = .{};
                        var payload_cursor = payload_offset;
                        var logical_cursor: u64 = 0;
                        var i: usize = 0;
                        while (i < blocks.len) : (i += 1) {
                            const entry_offset = i * block_deflate_entry_len;
                            const entry_slice = table_bytes[entry_offset..][0..block_deflate_entry_len];
                            const entry = try BlockDeflateEntry.decode(entry_slice[0..block_deflate_entry_len], payload_cursor, try header.rawLenForBlock(i));
                            if (entry.physical_offset != payload_cursor) return error.InvalidRecord;
                            if (entry.physical_offset > table_offset or entry.stored_len > table_offset - entry.physical_offset) return error.InvalidRecord;
                            blocks[i] = entry;
                            payload_cursor = std.math.add(u64, payload_cursor, entry.stored_len) catch return error.InvalidRecord;
                            logical_cursor = std.math.add(u64, logical_cursor, entry.raw_len) catch return error.InvalidRecord;
                        }
                        if (payload_cursor != table_offset) return error.InvalidRecord;
                        if (logical_cursor != header.logical_size) return error.InvalidRecord;
                        return .{
                            .store = store,
                            .file = file,
                            .size = header.logical_size,
                            .format = .block_deflate,
                            .blocks = blocks,
                            .block_cache = block_cache,
                        };
                    }
                }
                var map = if (physical_size == 0 or physical_size > raw_mmap_max_bytes)
                    null
                else
                    Ops.openMap(store, file, physical_size) catch null;
                errdefer if (map) |*mapped| mapped.destroy(io);
                return .{ .store = store, .file = file, .map = map, .size = physical_size };
            }

            pub fn deinit(self: *View) void {
                const allocator = Ops.allocator(self.store);
                const io = Ops.io(self.store);
                if (self.block_cache) |cache| {
                    cache.deinit(allocator);
                    allocator.destroy(cache);
                }
                allocator.free(self.blocks);
                if (self.map) |*map| map.destroy(io);
                self.file.close(io);
            }

            pub fn mappedBytes(self: *const View, offset: u64, len: u32) !?[]const u8 {
                if (offset > self.size or len > self.size - offset) return error.InvalidRecord;
                if (self.format != .raw) return null;
                if (self.map) |*map| {
                    const start = std.math.cast(usize, offset) orelse return error.RecordTooLarge;
                    const end = std.math.add(usize, start, len) catch return error.InvalidRecord;
                    if (end > map.memory.len) return error.InvalidRecord;
                    return map.memory[start..end];
                }
                return null;
            }

            pub fn borrowedBytes(self: *const View, offset: u64, len: u32) !?[]const u8 {
                if (try self.mappedBytes(offset, len)) |bytes| return bytes;
                if (offset > self.size or len > self.size - offset) return error.InvalidRecord;
                if (len == 0) return &.{};
                if (self.format != .block_deflate) return null;
                const block_index = std.math.cast(usize, offset / block_deflate_block_bytes) orelse return error.RecordTooLarge;
                if (block_index >= self.blocks.len) return error.InvalidRecord;
                const entry = self.blocks[block_index];
                const in_block_offset: usize = @intCast(offset % block_deflate_block_bytes);
                if (in_block_offset > entry.raw_len) return error.InvalidRecord;
                if (len > @as(usize, entry.raw_len) - in_block_offset) return null;
                const block = try self.readCompressedBlock(block_index, entry);
                return block[in_block_offset..][0..len];
            }

            pub fn shouldCacheValidationHashes(self: *const View) bool {
                return self.format != .raw or self.map == null;
            }

            pub fn matches(self: *const View, offset: u64, len: u32, text: []const u8) !bool {
                if (len != text.len) return false;
                if (try self.mappedBytes(offset, len)) |bytes| return std.mem.eql(u8, bytes, text);
                return self.matchesPositional(offset, len, text);
            }

            pub fn matchesPositional(self: *const View, offset: u64, len: u32, text: []const u8) !bool {
                if (offset > self.size or len > self.size - offset) return error.InvalidRecord;
                var buf: [4096]u8 = undefined;
                var remaining: usize = len;
                var read_offset = offset;
                var text_pos: usize = 0;
                while (remaining > 0) {
                    const chunk_len = @min(remaining, buf.len);
                    try self.readInto(read_offset, buf[0..chunk_len]);
                    if (!std.mem.eql(u8, buf[0..chunk_len], text[text_pos .. text_pos + chunk_len])) return false;
                    remaining -= chunk_len;
                    read_offset += chunk_len;
                    text_pos += chunk_len;
                }
                return true;
            }

            pub fn hashMatches(self: *const View, record: anytype) !bool {
                return (try self.hashStoredText(record.text_offset, record.text_len)) == record.hash;
            }

            pub fn hashStoredText(self: *const View, text_offset: u64, text_len: u32) !u64 {
                var hasher = std.hash.Wyhash.init(0);
                if (try self.mappedBytes(text_offset, text_len)) |bytes| {
                    hasher.update(bytes);
                } else {
                    var buf: [4096]u8 = undefined;
                    var remaining: usize = text_len;
                    var offset = text_offset;
                    while (remaining > 0) {
                        const chunk_len = @min(remaining, buf.len);
                        try self.readInto(offset, buf[0..chunk_len]);
                        hasher.update(buf[0..chunk_len]);
                        remaining -= chunk_len;
                        offset += chunk_len;
                    }
                }
                return hasher.final();
            }

            pub fn digestStoredNode(self: *const View, id: u64, kind: anytype, offset: u64, len: u32) !u64 {
                var fixed: [14]u8 = undefined;
                std.mem.writeInt(u64, fixed[0..8], id, .little);
                std.mem.writeInt(u16, fixed[8..10], @intFromEnum(kind), .little);
                std.mem.writeInt(u32, fixed[10..14], len, .little);
                var hasher = std.hash.Wyhash.init(0);
                hasher.update(&fixed);
                try self.updateHasherFromStoredText(&hasher, offset, len);
                return hasher.final();
            }

            pub fn hashAndDigestStoredNode(self: *const View, id: u64, kind: anytype, offset: u64, len: u32) !struct { text_hash: u64, node_digest: u64 } {
                var fixed: [14]u8 = undefined;
                std.mem.writeInt(u64, fixed[0..8], id, .little);
                std.mem.writeInt(u16, fixed[8..10], @intFromEnum(kind), .little);
                std.mem.writeInt(u32, fixed[10..14], len, .little);
                var text_hasher = std.hash.Wyhash.init(0);
                var node_hasher = std.hash.Wyhash.init(0);
                node_hasher.update(&fixed);
                if (try self.mappedBytes(offset, len)) |bytes| {
                    text_hasher.update(bytes);
                    node_hasher.update(bytes);
                } else {
                    var remaining: usize = len;
                    var read_offset = offset;
                    var buf: [4096]u8 = undefined;
                    while (remaining != 0) {
                        const chunk_len = @min(remaining, buf.len);
                        try self.readInto(read_offset, buf[0..chunk_len]);
                        text_hasher.update(buf[0..chunk_len]);
                        node_hasher.update(buf[0..chunk_len]);
                        remaining -= chunk_len;
                        read_offset += chunk_len;
                    }
                }
                return .{ .text_hash = text_hasher.final(), .node_digest = node_hasher.final() };
            }

            pub fn validationHash(self: *const View, id: u64, kind: anytype, offset: u64, len: u32) !Ops.ValidationHashType {
                const computed = try self.hashAndDigestStoredNode(id, kind, offset, len);
                return .{ .text_hash = computed.text_hash, .node_digest = computed.node_digest };
            }

            pub fn readStoredNode(self: *const View, allocator: std.mem.Allocator, record: anytype) !Ops.StoredNodeType {
                // Preserve the façade's historical error priority: validate
                // the stored kind before allocating or reading text bytes.
                const kind = try Ops.nodeKind(record);
                const text = try self.readTextAlloc(allocator, record.text_offset, record.text_len);
                errdefer allocator.free(text);
                return Ops.makeStoredNode(record, kind, text);
            }

            pub fn readTextAlloc(self: *const View, allocator: std.mem.Allocator, offset: u64, len: u32) ![]u8 {
                const text = try allocator.alloc(u8, len);
                errdefer allocator.free(text);
                if (try self.mappedBytes(offset, len)) |bytes| @memcpy(text, bytes) else try self.readInto(offset, text);
                return text;
            }

            pub fn readInto(self: *const View, offset: u64, out: []u8) !void {
                if (offset > self.size or out.len > self.size - offset) return error.InvalidRecord;
                if (out.len == 0) return;
                if (try self.mappedBytes(offset, @intCast(out.len))) |bytes| {
                    @memcpy(out, bytes);
                    return;
                }
                switch (self.format) {
                    .raw => {
                        const n = try self.file.readPositionalAll(Ops.io(self.store), out, offset);
                        if (n != out.len) return error.InvalidRecord;
                    },
                    .block_deflate => try self.readCompressedInto(offset, out),
                }
            }

            fn updateHasherFromStoredText(self: *const View, hasher: anytype, offset: u64, len: u32) !void {
                if (try self.mappedBytes(offset, len)) |bytes| {
                    hasher.update(bytes);
                    return;
                }
                var remaining: usize = len;
                var read_offset = offset;
                var buf: [4096]u8 = undefined;
                while (remaining != 0) {
                    const chunk_len = @min(remaining, buf.len);
                    try self.readInto(read_offset, buf[0..chunk_len]);
                    hasher.update(buf[0..chunk_len]);
                    remaining -= chunk_len;
                    read_offset += chunk_len;
                }
            }

            fn readCompressedInto(self: *const View, offset: u64, out: []u8) !void {
                var remaining = out.len;
                var logical_offset = offset;
                var out_pos: usize = 0;
                while (remaining > 0) {
                    const block_index = std.math.cast(usize, logical_offset / block_deflate_block_bytes) orelse return error.RecordTooLarge;
                    if (block_index >= self.blocks.len) return error.InvalidRecord;
                    const entry = self.blocks[block_index];
                    const in_block_offset: usize = @intCast(logical_offset % block_deflate_block_bytes);
                    if (in_block_offset >= entry.raw_len) return error.InvalidRecord;
                    const take = @min(remaining, @as(usize, entry.raw_len) - in_block_offset);
                    const block = try self.readCompressedBlock(block_index, entry);
                    @memcpy(out[out_pos..][0..take], block[in_block_offset..][0..take]);
                    remaining -= take;
                    logical_offset += take;
                    out_pos += take;
                }
            }

            fn readCompressedBlock(self: *const View, block_index: usize, entry: BlockDeflateEntry) ![]const u8 {
                const cache = self.block_cache orelse return error.InvalidRecord;
                if (cache.block_index == block_index) return cache.bytes;
                const allocator = Ops.allocator(self.store);
                const io = Ops.io(self.store);
                const raw_len = std.math.cast(usize, entry.raw_len) orelse return error.RecordTooLarge;
                const stored_len = std.math.cast(usize, entry.stored_len) orelse return error.RecordTooLarge;
                var compressed_owned: ?[]u8 = null;
                defer if (compressed_owned) |buffer| allocator.free(buffer);
                const compressed: []const u8 = blk: {
                    if (self.map) |*map| {
                        const start = std.math.cast(usize, entry.physical_offset) orelse return error.RecordTooLarge;
                        const end = std.math.add(usize, start, stored_len) catch return error.InvalidRecord;
                        if (end > map.memory.len) return error.InvalidRecord;
                        break :blk map.memory[start..end];
                    }
                    const buffer = try allocator.alloc(u8, stored_len);
                    errdefer allocator.free(buffer);
                    const n = try self.file.readPositionalAll(io, buffer, entry.physical_offset);
                    if (n != buffer.len) return error.InvalidRecord;
                    compressed_owned = buffer;
                    break :blk buffer;
                };
                const out = try allocator.alloc(u8, raw_len);
                errdefer allocator.free(out);
                if ((entry.flags & block_deflate_flag_compressed) == 0) {
                    if (stored_len != raw_len) return error.InvalidRecord;
                    @memcpy(out, compressed);
                } else {
                    var input_reader: std.Io.Reader = .fixed(compressed);
                    const flate_buffer = try allocator.alloc(u8, std.compress.flate.max_window_len);
                    defer allocator.free(flate_buffer);
                    var decompressor = std.compress.flate.Decompress.init(&input_reader, .raw, flate_buffer);
                    try decompressor.reader.readSliceAll(out);
                }
                allocator.free(cache.bytes);
                cache.bytes = out;
                cache.block_index = block_index;
                return cache.bytes;
            }
        };

        const write_buffer_bytes: usize = 256 * 1024;

        const BufferedWriter = struct {
            io: std.Io,
            file: std.Io.File,
            allocator: std.mem.Allocator,
            buffer: []u8,
            len: usize = 0,
            offset: u64 = 0,

            fn initAtOffset(allocator: std.mem.Allocator, io: std.Io, file: std.Io.File, capacity: usize, offset: u64) !BufferedWriter {
                std.debug.assert(capacity > 0);
                return .{
                    .io = io,
                    .file = file,
                    .allocator = allocator,
                    .buffer = try allocator.alloc(u8, capacity),
                    .offset = offset,
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

        const FinalizePolicy = enum { always, only_if_smaller };
        pub const AppendRecovery = enum { none, rolled_back, committed };

        const Owner = struct {
            store: StoreType,
            allocator: std.mem.Allocator,
            io: std.Io,
            node_texts_path: []const u8,
            need_sync: bool,
            normal_write_mode: bool,

            fn init(store: StoreType) Owner {
                return .{
                    .store = store,
                    .allocator = Ops.allocator(store),
                    .io = Ops.io(store),
                    .node_texts_path = Ops.nodeTextsPath(store),
                    .need_sync = Ops.shouldSync(store),
                    .normal_write_mode = Ops.normalWriteMode(store),
                };
            }

            fn fileSizeOrZero(self: Owner, path: []const u8) !u64 {
                var file = std.Io.Dir.cwd().openFile(self.io, path, .{}) catch |err| switch (err) {
                    error.FileNotFound, error.NotDir => return 0,
                    error.IsDir => return error.IsDir,
                    else => |other| return other,
                };
                defer file.close(self.io);
                return regularFileSize(self.io, file);
            }

            fn tmpPathFor(self: Owner, path: []const u8) ![]u8 {
                return std.fmt.allocPrint(self.allocator, "{s}.tmp", .{path});
            }

            fn fileExists(self: Owner, path: []const u8) !bool {
                var file = std.Io.Dir.cwd().openFile(self.io, path, .{}) catch |err| switch (err) {
                    error.FileNotFound, error.NotDir, error.IsDir => return false,
                    else => |other| return other,
                };
                defer file.close(self.io);
                return (try file.stat(self.io)).kind == .file;
            }

            fn ensureRaw(self: Owner) !void {
                var texts = try View.open(self.store);
                var texts_open = true;
                errdefer if (texts_open) texts.deinit();
                if (texts.format == .raw) {
                    texts.deinit();
                    return;
                }
                const tmp_path = try self.tmpPathFor(self.node_texts_path);
                defer self.allocator.free(tmp_path);
                errdefer std.Io.Dir.cwd().deleteFile(self.io, tmp_path) catch {};
                {
                    var file = try std.Io.Dir.cwd().createFile(self.io, tmp_path, .{ .read = true, .truncate = true });
                    defer file.close(self.io);
                    var writer = try BufferedWriter.initAtOffset(self.allocator, self.io, file, write_buffer_bytes, 0);
                    defer writer.deinit();
                    const buffer = try self.allocator.alloc(u8, write_buffer_bytes);
                    defer self.allocator.free(buffer);
                    var offset: u64 = 0;
                    while (offset < texts.size) {
                        const remaining = texts.size - offset;
                        const want = @min(buffer.len, std.math.cast(usize, remaining) orelse buffer.len);
                        try texts.readInto(offset, buffer[0..want]);
                        try writer.append(buffer[0..want]);
                        offset = std.math.add(u64, offset, want) catch return error.RecordTooLarge;
                    }
                    try writer.flush();
                    if (try regularFileSize(self.io, file) != texts.size) return error.InvalidRecord;
                    if (self.need_sync) try file.sync(self.io);
                }
                texts.deinit();
                texts_open = false;
                try Ops.renameReplace(self.store, tmp_path, self.node_texts_path);
            }

            fn logicalSize(self: Owner) !u64 {
                var texts = try View.open(self.store);
                defer texts.deinit();
                return texts.size;
            }

            fn finalize(self: Owner, policy: FinalizePolicy) !Ops.CompressionResultType {
                const raw_size = try self.fileSizeOrZero(self.node_texts_path);
                if (raw_size == 0) return .{};

                const tmp_path = try std.fmt.allocPrint(self.allocator, "{s}.deflate.tmp", .{self.node_texts_path});
                defer self.allocator.free(tmp_path);
                const table_tmp_path = try std.fmt.allocPrint(self.allocator, "{s}.deflate.table.tmp", .{self.node_texts_path});
                defer self.allocator.free(table_tmp_path);

                var existing = try View.open(self.store);
                if (existing.format != .raw) {
                    const logical_size = existing.size;
                    existing.deinit();
                    self.removeFinalizeCheckpoints(tmp_path, table_tmp_path);
                    return .{ .before_bytes = raw_size, .after_bytes = raw_size, .logical_bytes = logical_size };
                }
                existing.deinit();

                var input_file = try std.Io.Dir.cwd().openFile(self.io, self.node_texts_path, .{});
                var input_file_open = true;
                defer if (input_file_open) input_file.close(self.io);
                var output_file = try std.Io.Dir.cwd().createFile(self.io, tmp_path, .{ .read = true, .truncate = false });
                var output_file_open = true;
                defer if (output_file_open) output_file.close(self.io);
                var table_file = try std.Io.Dir.cwd().createFile(self.io, table_tmp_path, .{ .read = true, .truncate = false });
                var table_file_open = true;
                defer if (table_file_open) table_file.close(self.io);

                const pending_header = BlockDeflateHeader{ .logical_size = raw_size };
                const block_count = try pending_header.blockCount();
                const table_bytes = std.math.mul(u64, block_count, block_deflate_entry_len) catch return error.RecordTooLarge;
                const payload_offset: u64 = block_deflate_header_len;
                const input = try self.allocator.alloc(u8, block_deflate_block_bytes);
                defer self.allocator.free(input);
                const compressed = try self.allocator.alloc(u8, @as(usize, block_deflate_block_bytes) * 2 + 1024);
                defer self.allocator.free(compressed);
                const flate_buffer = try self.allocator.alloc(u8, std.compress.flate.max_window_len);
                defer self.allocator.free(flate_buffer);

                var table_size = try regularFileSize(self.io, table_file);
                if (table_size % deflate_progress_entry_len != 0) {
                    table_size -= table_size % deflate_progress_entry_len;
                    try table_file.setLength(self.io, table_size);
                }
                const full_block_count = raw_size / block_deflate_block_bytes;
                var completed_blocks = table_size / deflate_progress_entry_len;
                if (completed_blocks > full_block_count) {
                    completed_blocks = 0;
                    table_size = 0;
                    try table_file.setLength(self.io, 0);
                    try output_file.setLength(self.io, payload_offset);
                }

                var payload_cursor = payload_offset;
                const progress_scan_entries: usize = 4096;
                var table_scan: [progress_scan_entries * deflate_progress_entry_len]u8 = undefined;
                var table_scan_offset: u64 = 0;
                var resume_block_index: u64 = 0;
                var resume_valid = true;
                while (table_scan_offset < table_size) {
                    const want: usize = @intCast(@min(@as(u64, table_scan.len), table_size - table_scan_offset));
                    const n = try table_file.readPositionalAll(self.io, table_scan[0..want], table_scan_offset);
                    if (n != want) return error.InvalidRecord;
                    var pos: usize = 0;
                    while (pos < want) : (pos += deflate_progress_entry_len) {
                        const stored_len = readU32(table_scan[pos..][0..block_deflate_entry_len]);
                        if (stored_len == 0 or stored_len > block_deflate_block_bytes) {
                            resume_valid = false;
                            break;
                        }
                        const raw_hash = readU64(table_scan[pos + block_deflate_entry_len ..][0..8]);
                        const stored_hash = readU64(table_scan[pos + block_deflate_entry_len + 8 ..][0..8]);
                        const raw_offset = std.math.mul(u64, resume_block_index, block_deflate_block_bytes) catch return error.RecordTooLarge;
                        const raw_n = try input_file.readPositionalAll(self.io, input, raw_offset);
                        if (raw_n != input.len or std.hash.Wyhash.hash(deflate_progress_hash_seed, input) != raw_hash) {
                            resume_valid = false;
                            break;
                        }
                        const stored_n = try output_file.readPositionalAll(self.io, compressed[0..stored_len], payload_cursor);
                        if (stored_n != stored_len or std.hash.Wyhash.hash(deflate_progress_hash_seed, compressed[0..stored_len]) != stored_hash) {
                            resume_valid = false;
                            break;
                        }
                        payload_cursor = std.math.add(u64, payload_cursor, stored_len) catch return error.RecordTooLarge;
                        resume_block_index += 1;
                    }
                    if (!resume_valid) break;
                    table_scan_offset += want;
                }
                const output_size = try regularFileSize(self.io, output_file);
                if (!resume_valid or output_size < payload_cursor) {
                    completed_blocks = 0;
                    table_size = 0;
                    payload_cursor = payload_offset;
                    try table_file.setLength(self.io, 0);
                    try output_file.setLength(self.io, payload_offset);
                } else if (output_size != payload_cursor) {
                    try output_file.setLength(self.io, payload_cursor);
                }

                var logical_offset = std.math.mul(u64, completed_blocks, block_deflate_block_bytes) catch return error.RecordTooLarge;
                const full_logical_end = std.math.mul(u64, full_block_count, block_deflate_block_bytes) catch return error.RecordTooLarge;
                const checkpoint_blocks: usize = 256;
                var checkpoint_entries: [checkpoint_blocks * deflate_progress_entry_len]u8 = undefined;
                var checkpoint_len: usize = 0;
                while (logical_offset < full_logical_end) {
                    const n = try input_file.readPositionalAll(self.io, input, logical_offset);
                    if (n != input.len) return error.InvalidRecord;
                    const compressed_len = deflateBlock(input, compressed, flate_buffer);
                    const stored = if (compressed_len < input.len) compressed[0..compressed_len] else input;
                    try output_file.writePositionalAll(self.io, stored, payload_cursor);
                    writeU32(checkpoint_entries[checkpoint_len..][0..block_deflate_entry_len], @intCast(stored.len));
                    writeU64(checkpoint_entries[checkpoint_len + block_deflate_entry_len ..][0..8], std.hash.Wyhash.hash(deflate_progress_hash_seed, input));
                    writeU64(checkpoint_entries[checkpoint_len + block_deflate_entry_len + 8 ..][0..8], std.hash.Wyhash.hash(deflate_progress_hash_seed, stored));
                    checkpoint_len += deflate_progress_entry_len;
                    payload_cursor = std.math.add(u64, payload_cursor, stored.len) catch return error.RecordTooLarge;
                    logical_offset = std.math.add(u64, logical_offset, input.len) catch return error.RecordTooLarge;
                    if (checkpoint_len == checkpoint_entries.len or logical_offset == full_logical_end) {
                        if (self.need_sync) try output_file.sync(self.io);
                        try table_file.writePositionalAll(self.io, checkpoint_entries[0..checkpoint_len], table_size);
                        table_size = std.math.add(u64, table_size, checkpoint_len) catch return error.RecordTooLarge;
                        if (self.need_sync) try table_file.sync(self.io);
                        checkpoint_len = 0;
                    }
                }
                if (table_size != std.math.mul(u64, full_block_count, deflate_progress_entry_len) catch return error.RecordTooLarge) return error.InvalidRecord;

                var partial_entry: [block_deflate_entry_len]u8 = undefined;
                var partial_entry_len: usize = 0;
                if (logical_offset < raw_size) {
                    const raw_len: usize = @intCast(raw_size - logical_offset);
                    const n = try input_file.readPositionalAll(self.io, input[0..raw_len], logical_offset);
                    if (n != raw_len) return error.InvalidRecord;
                    const compressed_len = deflateBlock(input[0..raw_len], compressed, flate_buffer);
                    const stored = if (compressed_len < raw_len) compressed[0..compressed_len] else input[0..raw_len];
                    try output_file.writePositionalAll(self.io, stored, payload_cursor);
                    writeU32(&partial_entry, @intCast(stored.len));
                    partial_entry_len = partial_entry.len;
                    payload_cursor = std.math.add(u64, payload_cursor, stored.len) catch return error.RecordTooLarge;
                    logical_offset = raw_size;
                }
                if (logical_offset != raw_size or try regularFileSize(self.io, input_file) != raw_size) return error.InvalidRecord;
                if (self.need_sync) try output_file.sync(self.io);

                const table_offset = payload_cursor;
                const final_size = std.math.add(u64, table_offset, table_bytes) catch return error.RecordTooLarge;
                table_scan_offset = 0;
                var table_write_offset = table_offset;
                var block_table_chunk: [progress_scan_entries * block_deflate_entry_len]u8 = undefined;
                while (table_scan_offset < table_size) {
                    const want: usize = @intCast(@min(@as(u64, table_scan.len), table_size - table_scan_offset));
                    const n = try table_file.readPositionalAll(self.io, table_scan[0..want], table_scan_offset);
                    if (n != want) return error.InvalidRecord;
                    var progress_pos: usize = 0;
                    var block_table_len: usize = 0;
                    while (progress_pos < want) : (progress_pos += deflate_progress_entry_len) {
                        @memcpy(block_table_chunk[block_table_len..][0..block_deflate_entry_len], table_scan[progress_pos..][0..block_deflate_entry_len]);
                        block_table_len += block_deflate_entry_len;
                    }
                    try output_file.writePositionalAll(self.io, block_table_chunk[0..block_table_len], table_write_offset);
                    table_scan_offset += want;
                    table_write_offset += block_table_len;
                }
                if (partial_entry_len != 0) {
                    try output_file.writePositionalAll(self.io, partial_entry[0..partial_entry_len], table_write_offset);
                    table_write_offset += partial_entry_len;
                }
                if (table_write_offset != final_size) return error.InvalidRecord;
                try output_file.setLength(self.io, final_size);
                const header = BlockDeflateHeader{ .logical_size = raw_size };
                var header_bytes: [block_deflate_header_len]u8 = undefined;
                try header.encode(&header_bytes);
                try output_file.writePositionalAll(self.io, &header_bytes, 0);
                if (self.need_sync) try output_file.sync(self.io);
                output_file.close(self.io);
                output_file_open = false;
                table_file.close(self.io);
                table_file_open = false;
                input_file.close(self.io);
                input_file_open = false;
                if (policy == .only_if_smaller and final_size >= raw_size) {
                    self.removeFinalizeCheckpoints(tmp_path, table_tmp_path);
                    return .{ .before_bytes = raw_size, .after_bytes = raw_size, .logical_bytes = raw_size };
                }
                try Ops.renameReplace(self.store, tmp_path, self.node_texts_path);
                self.removeFinalizeCheckpoints(tmp_path, table_tmp_path);
                return .{ .compressed = true, .before_bytes = raw_size, .after_bytes = final_size, .logical_bytes = raw_size };
            }

            fn removeFinalizeCheckpoints(self: Owner, tmp_path: []const u8, table_tmp_path: []const u8) void {
                var removed = false;
                std.Io.Dir.cwd().deleteFile(self.io, tmp_path) catch |err| switch (err) {
                    error.FileNotFound => {},
                    else => return,
                };
                removed = true;
                std.Io.Dir.cwd().deleteFile(self.io, table_tmp_path) catch |err| switch (err) {
                    error.FileNotFound => {},
                    else => return,
                };
                if (removed) Ops.syncParentDir(self.store, table_tmp_path) catch {};
            }

            fn mutateRawSlicesInPlace(
                self: Owner,
                file: std.Io.File,
                start: u64,
                slices: []const []const u8,
                spans: []Ops.SpanType,
            ) !u64 {
                if (slices.len != spans.len) return error.InvalidRecord;
                var writer = try BufferedWriter.initAtOffset(self.allocator, self.io, file, write_buffer_bytes, start);
                defer writer.deinit();
                for (slices, spans) |text, *span| {
                    if (text.len > std.math.maxInt(u32)) return error.RecordTooLarge;
                    const text_offset = try writer.position();
                    if (text.len != 0) try writer.append(text);
                    span.* = .{ .offset = text_offset, .len = @intCast(text.len) };
                }
                try writer.flush();
                const end = try writer.position();
                if (try regularFileSize(self.io, file) != end) return error.InvalidRecord;
                if (self.need_sync) try file.sync(self.io);
                return end;
            }

            fn appendRawSlices(self: Owner, slices: []const []const u8) ![]Ops.SpanType {
                const spans = try self.allocator.alloc(Ops.SpanType, slices.len);
                errdefer self.allocator.free(spans);
                try self.ensureRaw();
                var texts_file = try std.Io.Dir.cwd().createFile(self.io, self.node_texts_path, .{ .read = true, .truncate = false });
                var texts_file_open = true;
                defer if (texts_file_open) texts_file.close(self.io);
                const texts_start = try regularFileSize(self.io, texts_file);
                var append_bytes: u64 = 0;
                for (slices) |text| {
                    if (text.len > std.math.maxInt(u32)) return error.RecordTooLarge;
                    append_bytes = std.math.add(u64, append_bytes, text.len) catch return error.RecordTooLarge;
                }
                var append_journal_active = false;
                if (append_bytes != 0 and self.need_sync) {
                    try self.writeRawAppendJournal(texts_start);
                    append_journal_active = true;
                }
                const texts_end = self.mutateRawSlicesInPlace(texts_file, texts_start, slices, spans) catch |operation_err| {
                    if (append_journal_active) {
                        _ = self.recoverAppendJournal() catch |recovery_err| return recovery_err;
                    }
                    return operation_err;
                };
                if (append_journal_active) try self.commitAppendJournalAfterMutation();
                if (texts_start == 0 and texts_end != 0 and self.normal_write_mode) {
                    texts_file.close(self.io);
                    texts_file_open = false;
                    _ = try self.finalize(.always);
                }
                return spans;
            }

            fn appendOne(self: Owner, text: []const u8) !Ops.SpanType {
                if (text.len > std.math.maxInt(u32)) return error.RecordTooLarge;
                {
                    var texts = try View.open(self.store);
                    defer texts.deinit();
                    if (texts.format == .block_deflate) {
                        var one = [_][]const u8{text};
                        const spans = try self.appendCompressedSlices(&texts, &one);
                        defer self.allocator.free(spans);
                        return spans[0];
                    }
                }
                var one = [_][]const u8{text};
                const spans = try self.appendRawSlices(&one);
                defer self.allocator.free(spans);
                return spans[0];
            }

            fn appendBatch(self: Owner, nodes: anytype) ![]Ops.SpanType {
                {
                    var texts = try View.open(self.store);
                    defer texts.deinit();
                    if (texts.format == .block_deflate) {
                        const spans = try self.allocator.alloc(Ops.SpanType, nodes.len);
                        errdefer self.allocator.free(spans);
                        var unique_slices = std.ArrayList([]const u8).empty;
                        defer unique_slices.deinit(self.allocator);
                        const ordinals = try self.allocator.alloc(usize, nodes.len);
                        defer self.allocator.free(ordinals);
                        var intern = std.StringHashMap(usize).init(self.allocator);
                        defer intern.deinit();
                        try unique_slices.ensureTotalCapacity(self.allocator, @min(nodes.len, 8192));
                        try intern.ensureTotalCapacity(@intCast(@min(nodes.len, 8192)));
                        for (nodes, 0..) |node, index| {
                            if (node.text.len > std.math.maxInt(u32)) return error.RecordTooLarge;
                            if (intern.get(node.text)) |ordinal| {
                                ordinals[index] = ordinal;
                                continue;
                            }
                            const ordinal = unique_slices.items.len;
                            try unique_slices.append(self.allocator, node.text);
                            try intern.put(node.text, ordinal);
                            ordinals[index] = ordinal;
                        }
                        const unique_spans = try self.appendCompressedSlices(&texts, unique_slices.items);
                        defer self.allocator.free(unique_spans);
                        for (ordinals, 0..) |ordinal, index| spans[index] = unique_spans[ordinal];
                        return spans;
                    }
                }
                const slices = try self.allocator.alloc([]const u8, nodes.len);
                defer self.allocator.free(slices);
                for (nodes, 0..) |node, index| slices[index] = node.text;
                return self.appendRawSlices(slices);
            }

            fn journalPath(self: Owner, buffer: []u8) ![]const u8 {
                return std.fmt.bufPrint(buffer, "{s}.append-journal", .{self.node_texts_path});
            }

            fn writeAppendJournal(self: Owner, texts: *const View, suffix_offset: u64) !void {
                if (texts.format != .block_deflate or !self.need_sync) return error.InvalidRecord;
                const original_size = try regularFileSize(self.io, texts.file);
                if (suffix_offset < block_deflate_header_len or suffix_offset > original_size) return error.InvalidRecord;
                const suffix_len_u64 = original_size - suffix_offset;
                const suffix_len = std.math.cast(usize, suffix_len_u64) orelse return error.RecordTooLarge;
                const suffix = try self.allocator.alloc(u8, suffix_len);
                defer self.allocator.free(suffix);
                const suffix_n = try texts.file.readPositionalAll(self.io, suffix, suffix_offset);
                if (suffix_n != suffix.len) return error.InvalidRecord;
                var original_header: [block_deflate_header_len]u8 = undefined;
                const header_n = try texts.file.readPositionalAll(self.io, &original_header, 0);
                if (header_n != original_header.len) return error.InvalidRecord;
                _ = try BlockDeflateHeader.decode(&original_header);
                const journal_header = AppendJournalHeader{
                    .original_size = original_size,
                    .suffix_offset = suffix_offset,
                    .suffix_len = suffix_len_u64,
                    .suffix_hash = std.hash.Wyhash.hash(append_journal_hash_seed, suffix),
                    .original_header = original_header,
                };
                var journal_header_bytes: [append_journal_header_len]u8 = undefined;
                try journal_header.encode(&journal_header_bytes);
                var journal_path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
                const journal_path = try self.journalPath(&journal_path_buffer);
                const tmp_path = try self.tmpPathFor(journal_path);
                defer self.allocator.free(tmp_path);
                errdefer std.Io.Dir.cwd().deleteFile(self.io, tmp_path) catch {};
                {
                    var journal_file = try std.Io.Dir.cwd().createFile(self.io, tmp_path, .{ .read = true, .truncate = true });
                    defer journal_file.close(self.io);
                    try journal_file.writePositionalAll(self.io, &journal_header_bytes, 0);
                    if (suffix.len != 0) try journal_file.writePositionalAll(self.io, suffix, append_journal_header_len);
                    if (self.need_sync) try journal_file.sync(self.io);
                }
                try Ops.renameReplace(self.store, tmp_path, journal_path);
            }

            fn writeRawAppendJournal(self: Owner, original_size: u64) !void {
                if (!self.need_sync) return error.InvalidRecord;
                const journal_header = AppendJournalHeader{
                    .original_size = original_size,
                    .suffix_offset = original_size,
                    .suffix_len = 0,
                    .suffix_hash = std.hash.Wyhash.hash(append_journal_hash_seed, &.{}),
                    .original_header = @splat(0),
                    .original_format = .raw,
                };
                var journal_header_bytes: [append_journal_header_len]u8 = undefined;
                try journal_header.encode(&journal_header_bytes);
                var journal_path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
                const journal_path = try self.journalPath(&journal_path_buffer);
                const tmp_path = try self.tmpPathFor(journal_path);
                defer self.allocator.free(tmp_path);
                errdefer std.Io.Dir.cwd().deleteFile(self.io, tmp_path) catch {};
                {
                    var journal_file = try std.Io.Dir.cwd().createFile(self.io, tmp_path, .{ .read = true, .truncate = true });
                    defer journal_file.close(self.io);
                    try journal_file.writePositionalAll(self.io, &journal_header_bytes, 0);
                    if (self.need_sync) try journal_file.sync(self.io);
                }
                try Ops.renameReplace(self.store, tmp_path, journal_path);
            }

            fn cleanupJournalAfterRecovery(self: Owner, journal_path: []const u8) void {
                std.Io.Dir.cwd().deleteFile(self.io, journal_path) catch return;
                Ops.syncParentDir(self.store, journal_path) catch {};
            }

            fn cleanupCommittedJournal(self: Owner) void {
                var journal_path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
                const journal_path = self.journalPath(&journal_path_buffer) catch return;
                self.cleanupJournalAfterRecovery(journal_path);
            }

            fn markAppendJournalCommitted(self: Owner) !void {
                var journal_path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
                const journal_path = try self.journalPath(&journal_path_buffer);
                var journal_file = try std.Io.Dir.cwd().openFile(self.io, journal_path, .{ .allow_directory = false });
                var journal_file_open = true;
                defer if (journal_file_open) journal_file.close(self.io);
                const journal_size = try regularFileSize(self.io, journal_file);
                const journal_len = std.math.cast(usize, journal_size) orelse return error.RecordTooLarge;
                if (journal_len < append_journal_header_len) return error.InvalidRecord;
                const journal_bytes = try self.allocator.alloc(u8, journal_len);
                defer self.allocator.free(journal_bytes);
                const journal_n = try journal_file.readPositionalAll(self.io, journal_bytes, 0);
                if (journal_n != journal_bytes.len) return error.InvalidRecord;
                var header_bytes: [append_journal_header_len]u8 = undefined;
                @memcpy(&header_bytes, journal_bytes[0..append_journal_header_len]);
                var header = try AppendJournalHeader.decode(&header_bytes);
                if (journal_size != std.math.add(u64, append_journal_header_len, header.suffix_len) catch return error.InvalidRecord) return error.InvalidRecord;
                if (header.committed) return;
                header.committed = true;
                try header.encode(&header_bytes);
                @memcpy(journal_bytes[0..append_journal_header_len], &header_bytes);
                journal_file.close(self.io);
                journal_file_open = false;
                const tmp_path = try self.tmpPathFor(journal_path);
                defer self.allocator.free(tmp_path);
                errdefer std.Io.Dir.cwd().deleteFile(self.io, tmp_path) catch {};
                {
                    var committed_file = try std.Io.Dir.cwd().createFile(self.io, tmp_path, .{ .read = true, .truncate = true });
                    defer committed_file.close(self.io);
                    try committed_file.writePositionalAll(self.io, journal_bytes, 0);
                    if (self.need_sync) try committed_file.sync(self.io);
                }
                try Ops.renameReplace(self.store, tmp_path, journal_path);
            }

            fn commitAppendJournalAfterMutation(self: Owner) !void {
                self.markAppendJournalCommitted() catch |commit_err| {
                    const recovery = self.recoverAppendJournal() catch |recovery_err| return recovery_err;
                    if (recovery != .committed) return commit_err;
                };
            }

            fn recoverAppendJournal(self: Owner) !AppendRecovery {
                var journal_path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
                const journal_path = try self.journalPath(&journal_path_buffer);
                if (!try self.fileExists(journal_path)) return .none;
                var journal_file = try std.Io.Dir.cwd().openFile(self.io, journal_path, .{});
                var journal_file_open = true;
                defer if (journal_file_open) journal_file.close(self.io);
                const journal_size = try regularFileSize(self.io, journal_file);
                if (journal_size < append_journal_header_len) return error.InvalidRecord;
                var header_bytes: [append_journal_header_len]u8 = undefined;
                const header_n = try journal_file.readPositionalAll(self.io, &header_bytes, 0);
                if (header_n != header_bytes.len) return error.InvalidRecord;
                const header = try AppendJournalHeader.decode(&header_bytes);
                if (journal_size != std.math.add(u64, append_journal_header_len, header.suffix_len) catch return error.InvalidRecord) return error.InvalidRecord;
                switch (header.original_format) {
                    .raw => {
                        if (!allZero(&header.original_header)) return error.InvalidRecord;
                        if (header.suffix_offset != header.original_size or header.suffix_len != 0) return error.InvalidRecord;
                    },
                    .block_deflate => {
                        const original_header = try BlockDeflateHeader.decode(&header.original_header);
                        const table_bytes = try original_header.tableBytes();
                        if (header.suffix_offset < block_deflate_header_len or header.suffix_offset > header.original_size) return error.InvalidRecord;
                        if (header.suffix_len != header.original_size - header.suffix_offset) return error.InvalidRecord;
                        if (header.suffix_len < table_bytes or header.suffix_len > table_bytes + block_deflate_block_bytes) return error.InvalidRecord;
                    },
                }
                const suffix_len = std.math.cast(usize, header.suffix_len) orelse return error.RecordTooLarge;
                const suffix = try self.allocator.alloc(u8, suffix_len);
                defer self.allocator.free(suffix);
                const suffix_n = try journal_file.readPositionalAll(self.io, suffix, append_journal_header_len);
                if (suffix_n != suffix.len) return error.InvalidRecord;
                if (std.hash.Wyhash.hash(append_journal_hash_seed, suffix) != header.suffix_hash) return error.InvalidRecord;
                journal_file.close(self.io);
                journal_file_open = false;
                if (header.committed) {
                    try Ops.syncParentDir(self.store, journal_path);
                    return .committed;
                }
                var texts_file = try std.Io.Dir.cwd().openFile(self.io, self.node_texts_path, .{ .mode = .read_write, .allow_directory = false });
                defer texts_file.close(self.io);
                switch (header.original_format) {
                    .raw => try texts_file.setLength(self.io, header.original_size),
                    .block_deflate => {
                        try texts_file.setLength(self.io, header.suffix_offset);
                        if (suffix.len != 0) try texts_file.writePositionalAll(self.io, suffix, header.suffix_offset);
                        try texts_file.writePositionalAll(self.io, &header.original_header, 0);
                        try texts_file.setLength(self.io, header.original_size);
                    },
                }
                if (self.need_sync) try texts_file.sync(self.io);
                self.cleanupJournalAfterRecovery(journal_path);
                return .rolled_back;
            }

            fn appendCompressedSlices(self: Owner, texts: *const View, slices: []const []const u8) ![]Ops.SpanType {
                if (texts.format != .block_deflate) return error.InvalidRecord;
                const spans = try self.allocator.alloc(Ops.SpanType, slices.len);
                errdefer self.allocator.free(spans);
                var append_bytes: u64 = 0;
                for (slices, 0..) |text, index| {
                    if (text.len > std.math.maxInt(u32)) return error.RecordTooLarge;
                    const offset = std.math.add(u64, texts.size, append_bytes) catch return error.RecordTooLarge;
                    spans[index] = .{ .offset = offset, .len = @intCast(text.len) };
                    append_bytes = std.math.add(u64, append_bytes, text.len) catch return error.RecordTooLarge;
                }
                if (append_bytes == 0) return spans;
                const old_block_count = texts.blocks.len;
                if (old_block_count == 0) return error.InvalidRecord;
                const old_last = texts.blocks[old_block_count - 1];
                const old_payload_end = std.math.add(u64, old_last.physical_offset, old_last.stored_len) catch return error.InvalidRecord;
                const last_has_room = old_last.raw_len < block_deflate_block_bytes;
                const truncate_offset = if (last_has_room) old_last.physical_offset else old_payload_end;
                var append_journal_active = false;
                if (self.need_sync) {
                    try self.writeAppendJournal(texts, truncate_offset);
                    append_journal_active = true;
                }
                self.mutateCompressedSlicesInPlace(texts, slices, append_bytes) catch |operation_err| {
                    if (append_journal_active) _ = self.recoverAppendJournal() catch |recovery_err| return recovery_err;
                    return operation_err;
                };
                if (append_journal_active) try self.commitAppendJournalAfterMutation();
                return spans;
            }

            fn mutateCompressedSlicesInPlace(self: Owner, texts: *const View, slices: []const []const u8, append_bytes: u64) !void {
                const old_block_count = texts.blocks.len;
                if (old_block_count == 0) return error.InvalidRecord;
                const old_last = texts.blocks[old_block_count - 1];
                const old_payload_end = std.math.add(u64, old_last.physical_offset, old_last.stored_len) catch return error.InvalidRecord;
                const last_has_room = old_last.raw_len < block_deflate_block_bytes;
                const rewrite_from_block = if (last_has_room) old_block_count - 1 else old_block_count;
                const truncate_offset = if (last_has_room) old_last.physical_offset else old_payload_end;
                const new_logical_size = std.math.add(u64, texts.size, append_bytes) catch return error.RecordTooLarge;
                const new_header = BlockDeflateHeader{ .logical_size = new_logical_size };
                const new_block_count = try new_header.blockCount();
                const table_bytes = std.math.mul(u64, new_block_count, block_deflate_entry_len) catch return error.RecordTooLarge;
                const table_len = std.math.cast(usize, table_bytes) orelse return error.RecordTooLarge;
                const block_table = try self.allocator.alloc(u8, table_len);
                defer self.allocator.free(block_table);
                var block_index: usize = 0;
                while (block_index < rewrite_from_block) : (block_index += 1) {
                    var entry_bytes: [block_deflate_entry_len]u8 = undefined;
                    try texts.blocks[block_index].encode(&entry_bytes);
                    const entry_offset = block_index * block_deflate_entry_len;
                    @memcpy(block_table[entry_offset..][0..block_deflate_entry_len], &entry_bytes);
                }
                const pending = try self.allocator.alloc(u8, block_deflate_block_bytes);
                defer self.allocator.free(pending);
                var pending_len: usize = 0;
                if (last_has_room) {
                    pending_len = old_last.raw_len;
                    const last_logical_offset = std.math.mul(u64, @intCast(old_block_count - 1), block_deflate_block_bytes) catch return error.InvalidRecord;
                    try texts.readInto(last_logical_offset, pending[0..pending_len]);
                }
                const compressed = try self.allocator.alloc(u8, @as(usize, block_deflate_block_bytes) * 2 + 1024);
                defer self.allocator.free(compressed);
                const flate_buffer = try self.allocator.alloc(u8, std.compress.flate.max_window_len);
                defer self.allocator.free(flate_buffer);
                var file = try std.Io.Dir.cwd().openFile(self.io, self.node_texts_path, .{ .mode = .read_write, .allow_directory = false });
                defer file.close(self.io);
                try file.setLength(self.io, truncate_offset);
                var payload_cursor = truncate_offset;
                var output_block_index = rewrite_from_block;
                for (slices) |text| {
                    var pos: usize = 0;
                    while (pos < text.len) {
                        const available = @as(usize, block_deflate_block_bytes) - pending_len;
                        const take = @min(available, text.len - pos);
                        @memcpy(pending[pending_len..][0..take], text[pos..][0..take]);
                        pending_len += take;
                        pos += take;
                        if (pending_len == block_deflate_block_bytes) {
                            payload_cursor = try self.writeCompressedBlock(&file, pending[0..pending_len], payload_cursor, output_block_index, block_table, compressed, flate_buffer);
                            output_block_index += 1;
                            pending_len = 0;
                        }
                    }
                }
                if (pending_len != 0) {
                    payload_cursor = try self.writeCompressedBlock(&file, pending[0..pending_len], payload_cursor, output_block_index, block_table, compressed, flate_buffer);
                    output_block_index += 1;
                }
                if (output_block_index != new_block_count) return error.InvalidRecord;
                try file.writePositionalAll(self.io, block_table, payload_cursor);
                const final_size = std.math.add(u64, payload_cursor, table_bytes) catch return error.RecordTooLarge;
                try file.setLength(self.io, final_size);
                var header_bytes: [block_deflate_header_len]u8 = undefined;
                try new_header.encode(&header_bytes);
                try file.writePositionalAll(self.io, &header_bytes, 0);
                if (self.need_sync) try file.sync(self.io);
            }

            fn writeCompressedBlock(
                self: Owner,
                file: *std.Io.File,
                raw: []const u8,
                payload_cursor: u64,
                block_index: usize,
                block_table: []u8,
                compressed: []u8,
                flate_buffer: []u8,
            ) !u64 {
                const compressed_len = deflateBlock(raw, compressed, flate_buffer);
                const use_compressed = compressed_len < raw.len;
                const stored = if (use_compressed) compressed[0..compressed_len] else raw;
                try file.writePositionalAll(self.io, stored, payload_cursor);
                const entry = BlockDeflateEntry{
                    .physical_offset = payload_cursor,
                    .stored_len = @intCast(stored.len),
                    .raw_len = @intCast(raw.len),
                    .flags = if (use_compressed) block_deflate_flag_compressed else 0,
                };
                var entry_bytes: [block_deflate_entry_len]u8 = undefined;
                try entry.encode(&entry_bytes);
                const entry_offset = block_index * block_deflate_entry_len;
                @memcpy(block_table[entry_offset..][0..block_deflate_entry_len], &entry_bytes);
                return std.math.add(u64, payload_cursor, stored.len) catch return error.RecordTooLarge;
            }
        };

        pub fn ensureRaw(store: StoreType) !void {
            return Owner.init(store).ensureRaw();
        }

        pub fn compressIfSmaller(store: StoreType) !Ops.CompressionResultType {
            return Owner.init(store).finalize(.only_if_smaller);
        }

        pub fn finalize(store: StoreType) !Ops.CompressionResultType {
            return Owner.init(store).finalize(.always);
        }

        pub fn logicalSize(store: StoreType) !u64 {
            return Owner.init(store).logicalSize();
        }

        pub fn appendOne(store: StoreType, text: []const u8) !Ops.SpanType {
            return Owner.init(store).appendOne(text);
        }

        pub fn appendBatch(store: StoreType, nodes: anytype) ![]Ops.SpanType {
            return Owner.init(store).appendBatch(nodes);
        }

        pub fn reconcileBeforeAppend(store: StoreType) !void {
            const owner = Owner.init(store);
            if (try owner.recoverAppendJournal() == .committed) try Ops.repairPersistentIndexesFromLog(store);
        }

        pub fn appendJournalPath(store: StoreType, buffer: []u8) ![]const u8 {
            return Owner.init(store).journalPath(buffer);
        }

        pub fn writeAppendJournal(store: StoreType, texts: *const View, suffix_offset: u64) !void {
            return Owner.init(store).writeAppendJournal(texts, suffix_offset);
        }

        pub fn writeRawAppendJournal(store: StoreType, original_size: u64) !void {
            return Owner.init(store).writeRawAppendJournal(original_size);
        }

        pub fn cleanupCommittedAppendJournal(store: StoreType) void {
            Owner.init(store).cleanupCommittedJournal();
        }

        pub fn markAppendJournalCommitted(store: StoreType) !void {
            return Owner.init(store).markAppendJournalCommitted();
        }

        pub fn commitAppendJournalAfterMutation(store: StoreType) !void {
            return Owner.init(store).commitAppendJournalAfterMutation();
        }

        pub fn recoverAppendJournal(store: StoreType) !AppendRecovery {
            return Owner.init(store).recoverAppendJournal();
        }

        pub fn mutateCompressedSlicesInPlace(store: StoreType, texts: *const View, slices: []const []const u8, append_bytes: u64) !void {
            return Owner.init(store).mutateCompressedSlicesInPlace(texts, slices, append_bytes);
        }

        pub fn deflateBlock(input: []const u8, output: []u8, flate_buffer: []u8) usize {
            var fixed: std.Io.Writer = .fixed(output);
            var compressor = std.compress.flate.Compress.init(&fixed, flate_buffer, .raw, block_deflate_level) catch return input.len;
            compressor.writer.writeAll(input) catch return input.len;
            compressor.finish() catch return input.len;
            return fixed.buffered().len;
        }
    };
}

fn regularFileSize(io: std.Io, file: std.Io.File) !u64 {
    const stat = try file.stat(io);
    if (stat.kind != .file) return error.IsDir;
    return stat.size;
}

fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}

fn writeU16(bytes: []u8, value: u16) void {
    std.mem.writeInt(u16, bytes[0..2], value, .little);
}

fn writeU32(bytes: []u8, value: u32) void {
    std.mem.writeInt(u32, bytes[0..4], value, .little);
}

fn writeU64(bytes: []u8, value: u64) void {
    std.mem.writeInt(u64, bytes[0..8], value, .little);
}

fn readU16(bytes: []const u8) u16 {
    return std.mem.readInt(u16, bytes[0..2], .little);
}

fn readU32(bytes: []const u8) u32 {
    return std.mem.readInt(u32, bytes[0..4], .little);
}

fn readU64(bytes: []const u8) u64 {
    return std.mem.readInt(u64, bytes[0..8], .little);
}

const TestSpan = struct {
    offset: u64,
    len: u32,
};

const TestStoredNode = struct {
    id: u64,
    kind: u16,
    text: []u8,
};

const TestValidationHash = struct {
    text_hash: u64,
    node_digest: u64,
};

const TestCompressionResult = struct {
    compressed: bool = false,
    before_bytes: u64 = 0,
    after_bytes: u64 = 0,
    logical_bytes: u64 = 0,
};

const TestStore = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    node_texts_path: []const u8,
    need_sync: bool = true,
    normal_write_mode: bool = false,
    repair_count: *usize,
};

const TestOps = struct {
    pub const StoreType = TestStore;
    pub const SpanType = TestSpan;
    pub const StoredNodeType = TestStoredNode;
    pub const NodeKindType = u16;
    pub const ValidationHashType = TestValidationHash;
    pub const CompressionResultType = TestCompressionResult;

    pub fn allocator(store: TestStore) std.mem.Allocator {
        return store.allocator;
    }

    pub fn io(store: TestStore) std.Io {
        return store.io;
    }

    pub fn nodeTextsPath(store: TestStore) []const u8 {
        return store.node_texts_path;
    }

    pub fn shouldSync(store: TestStore) bool {
        return store.need_sync;
    }

    pub fn normalWriteMode(store: TestStore) bool {
        return store.normal_write_mode;
    }

    pub fn renameReplace(store: TestStore, tmp_path: []const u8, final_path: []const u8) !void {
        try std.Io.Dir.renameAbsolute(tmp_path, final_path, store.io);
    }

    pub fn syncParentDir(_: TestStore, _: []const u8) !void {}

    pub fn repairPersistentIndexesFromLog(store: TestStore) !void {
        store.repair_count.* += 1;
    }

    pub fn openMap(store: TestStore, file: std.Io.File, physical_size: u64) !std.Io.File.MemoryMap {
        return std.Io.File.MemoryMap.create(store.io, file, .{
            .len = std.math.cast(usize, physical_size) orelse return error.RecordTooLarge,
            .protection = .{ .read = true, .write = false },
            .populate = true,
        });
    }

    pub fn nodeKind(record: anytype) !u16 {
        if (record.kind == std.math.maxInt(u16)) return error.InvalidKind;
        return record.kind;
    }

    pub fn makeStoredNode(record: anytype, kind: u16, text: []u8) !TestStoredNode {
        return .{ .id = record.id, .kind = kind, .text = text };
    }
};

const test_primary = PrimaryNodeText(TestOps);

const TestLayout = struct {
    path: []u8,

    fn init(tmp: *std.testing.TmpDir, path_buffer: []u8) !TestLayout {
        const root_len = try tmp.dir.realPath(std.testing.io, path_buffer);
        return .{
            .path = try std.fs.path.join(std.testing.allocator, &.{ path_buffer[0..root_len], "node_texts.dat" }),
        };
    }

    fn deinit(self: *TestLayout) void {
        std.testing.allocator.free(self.path);
    }

    fn store(self: TestLayout, repairs: *usize) TestStore {
        return .{
            .allocator = std.testing.allocator,
            .io = std.testing.io,
            .node_texts_path = self.path,
            .repair_count = repairs,
        };
    }
};

fn writeTestFile(path: []const u8, bytes: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = path,
        .data = bytes,
        .flags = .{ .truncate = true },
    });
}

fn readTestFileAlloc(path: []const u8) ![]u8 {
    var file = try std.Io.Dir.cwd().openFile(std.testing.io, path, .{});
    defer file.close(std.testing.io);
    const size = try regularFileSize(std.testing.io, file);
    const bytes = try std.testing.allocator.alloc(u8, std.math.cast(usize, size) orelse return error.RecordTooLarge);
    errdefer std.testing.allocator.free(bytes);
    const n = try file.readPositionalAll(std.testing.io, bytes, 0);
    if (n != bytes.len) return error.InvalidRecord;
    return bytes;
}

test "primary node text append journal round trips raw and compressed origins" {
    const raw = test_primary.AppendJournalHeader{
        .original_size = 17,
        .suffix_offset = 17,
        .suffix_len = 0,
        .suffix_hash = std.hash.Wyhash.hash(0x544B_4E41, &.{}),
        .original_header = @splat(0),
        .original_format = .raw,
    };
    var raw_bytes: [test_primary.append_journal_header_len]u8 = undefined;
    try raw.encode(&raw_bytes);
    const decoded_raw = try test_primary.AppendJournalHeader.decode(&raw_bytes);
    try std.testing.expectEqual(test_primary.StorageFormat.raw, decoded_raw.original_format);
    try std.testing.expectEqual(raw.original_size, decoded_raw.original_size);

    const block_header = test_primary.BlockDeflateHeader{ .logical_size = 33 };
    var original_header: [test_primary.block_deflate_header_len]u8 = undefined;
    try block_header.encode(&original_header);
    const compressed = test_primary.AppendJournalHeader{
        .original_size = 32,
        .suffix_offset = 23,
        .suffix_len = 9,
        .suffix_hash = std.hash.Wyhash.hash(0x544B_4E41, "undo-tail"),
        .original_header = original_header,
    };
    var compressed_bytes: [test_primary.append_journal_header_len]u8 = undefined;
    try compressed.encode(&compressed_bytes);
    const decoded_compressed = try test_primary.AppendJournalHeader.decode(&compressed_bytes);
    try std.testing.expectEqual(test_primary.StorageFormat.block_deflate, decoded_compressed.original_format);
    try std.testing.expectEqualSlices(u8, &original_header, &decoded_compressed.original_header);
}

test "primary node text append journal rejects checksum and shape corruption" {
    const header = test_primary.AppendJournalHeader{
        .original_size = 4,
        .suffix_offset = 4,
        .suffix_len = 0,
        .suffix_hash = std.hash.Wyhash.hash(0x544B_4E41, &.{}),
        .original_header = @splat(0),
        .original_format = .raw,
    };
    var bytes: [test_primary.append_journal_header_len]u8 = undefined;
    try header.encode(&bytes);
    bytes[63] ^= 0x80;
    try std.testing.expectError(error.InvalidRecord, test_primary.AppendJournalHeader.decode(&bytes));

    var invalid = header;
    invalid.suffix_offset = 3;
    try std.testing.expectError(error.InvalidRecord, invalid.encode(&bytes));
    invalid = header;
    invalid.original_header[0] = 1;
    try std.testing.expectError(error.InvalidRecord, invalid.encode(&bytes));
}

test "primary node text recovery rolls back raw and preserves committed mutations" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var layout = try TestLayout.init(&tmp, &path_buffer);
    defer layout.deinit();
    var repairs: usize = 0;
    const store = layout.store(&repairs);

    try writeTestFile(layout.path, "base");
    try test_primary.writeRawAppendJournal(store, 4);
    var file = try std.Io.Dir.cwd().openFile(std.testing.io, layout.path, .{ .mode = .read_write });
    try file.writePositionalAll(std.testing.io, "orphan", 4);
    file.close(std.testing.io);
    try std.testing.expectEqual(test_primary.AppendRecovery.rolled_back, try test_primary.recoverAppendJournal(store));
    const rolled_back = try readTestFileAlloc(layout.path);
    defer std.testing.allocator.free(rolled_back);
    try std.testing.expectEqualStrings("base", rolled_back);

    try test_primary.writeRawAppendJournal(store, 4);
    file = try std.Io.Dir.cwd().openFile(std.testing.io, layout.path, .{ .mode = .read_write });
    try file.writePositionalAll(std.testing.io, "kept", 4);
    file.close(std.testing.io);
    try test_primary.markAppendJournalCommitted(store);
    try std.testing.expectEqual(test_primary.AppendRecovery.committed, try test_primary.recoverAppendJournal(store));
    const committed = try readTestFileAlloc(layout.path);
    defer std.testing.allocator.free(committed);
    try std.testing.expectEqualStrings("basekept", committed);
    test_primary.cleanupCommittedAppendJournal(store);
}

test "primary node text block header and entries enforce physical bounds" {
    try std.testing.expectError(error.InvalidRecord, (test_primary.BlockDeflateHeader{ .logical_size = 0 }).validate());
    const header = test_primary.BlockDeflateHeader{ .logical_size = test_primary.block_deflate_block_bytes + 1 };
    try std.testing.expectEqual(@as(u32, 2), try header.blockCount());
    try std.testing.expectError(error.InvalidRecord, header.tableOffset(test_primary.block_deflate_header_len));

    try std.testing.expectError(error.InvalidRecord, (test_primary.BlockDeflateEntry{
        .physical_offset = 0,
        .stored_len = 1,
        .raw_len = 1,
        .flags = 0,
    }).validate());
    try std.testing.expectError(error.InvalidRecord, (test_primary.BlockDeflateEntry{
        .physical_offset = test_primary.block_deflate_header_len,
        .stored_len = 1,
        .raw_len = test_primary.block_deflate_block_bytes + 1,
        .flags = 1,
    }).validate());
}

test "primary node text finalize and append preserve the logical stream" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var layout = try TestLayout.init(&tmp, &path_buffer);
    defer layout.deinit();
    var repairs: usize = 0;
    const store = layout.store(&repairs);
    const original = "alpha alpha alpha alpha";
    try writeTestFile(layout.path, original);
    const result = try test_primary.finalize(store);
    try std.testing.expect(result.compressed);
    const span = try test_primary.appendOne(store, " + tail");
    try std.testing.expectEqual(@as(u64, original.len), span.offset);
    var view = try test_primary.View.open(store);
    defer view.deinit();
    const expected = original ++ " + tail";
    const actual = try std.testing.allocator.alloc(u8, expected.len);
    defer std.testing.allocator.free(actual);
    try view.readInto(0, actual);
    try std.testing.expectEqualStrings(expected, actual);
    try std.testing.expectEqual(test_primary.AppendRecovery.committed, try test_primary.recoverAppendJournal(store));
    test_primary.cleanupCommittedAppendJournal(store);
}

test "primary node text raw view maps and reads exact bytes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var layout = try TestLayout.init(&tmp, &path_buffer);
    defer layout.deinit();
    var repairs: usize = 0;
    const store = layout.store(&repairs);
    try writeTestFile(layout.path, "mapped-primary-text");
    var view = try test_primary.View.open(store);
    defer view.deinit();
    try std.testing.expectEqual(test_primary.StorageFormat.raw, view.format);
    const mapped = (try view.mappedBytes(7, 7)) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("primary", mapped);
    var exact: [4]u8 = undefined;
    try view.readInto(15, &exact);
    try std.testing.expectEqualStrings("text", &exact);
}

test "primary node text raw view treats near-magic prefixes as raw" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var layout = try TestLayout.init(&tmp, &path_buffer);
    defer layout.deinit();
    var repairs: usize = 0;
    const store = layout.store(&repairs);
    const raw = [_]u8{ 'T', 'K', 'N', 'Z', 4, 0, 16, 0, 8, 7, 6, 5, 4, 3, 2, 1 };
    try writeTestFile(layout.path, &raw);
    var view = try test_primary.View.open(store);
    defer view.deinit();
    try std.testing.expectEqual(test_primary.StorageFormat.raw, view.format);
    var actual: [raw.len]u8 = undefined;
    try view.readInto(0, &actual);
    try std.testing.expectEqualSlices(u8, &raw, &actual);
}

test "primary node text stored node validates kind before text IO" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var layout = try TestLayout.init(&tmp, &path_buffer);
    defer layout.deinit();
    var repairs: usize = 0;
    const store = layout.store(&repairs);
    try writeTestFile(layout.path, "x");
    var view = try test_primary.View.open(store);
    defer view.deinit();
    const invalid = .{
        .id = @as(u64, 1),
        .kind = std.math.maxInt(u16),
        .text_offset = @as(u64, 99),
        .text_len = @as(u32, 1),
    };
    try std.testing.expectError(error.InvalidKind, view.readStoredNode(std.testing.allocator, invalid));
}

test "primary node text block view decodes compressed and stored blocks" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var layout = try TestLayout.init(&tmp, &path_buffer);
    defer layout.deinit();
    var repairs: usize = 0;
    const store = layout.store(&repairs);
    const block_bytes: usize = test_primary.block_deflate_block_bytes;
    const raw = try std.testing.allocator.alloc(u8, block_bytes * 2);
    defer std.testing.allocator.free(raw);
    @memset(raw[0..block_bytes], 'a');
    var random = std.Random.DefaultPrng.init(0x544B_4E5A);
    random.fill(raw[block_bytes..]);
    try writeTestFile(layout.path, raw);
    _ = try test_primary.finalize(store);
    var view = try test_primary.View.open(store);
    defer view.deinit();
    try std.testing.expectEqual(test_primary.StorageFormat.block_deflate, view.format);
    try std.testing.expectEqual(@as(usize, 2), view.blocks.len);
    try std.testing.expect(view.blocks[0].stored_len < view.blocks[0].raw_len);
    try std.testing.expectEqual(view.blocks[1].stored_len, view.blocks[1].raw_len);
    const actual = try std.testing.allocator.alloc(u8, raw.len);
    defer std.testing.allocator.free(actual);
    try view.readInto(0, actual);
    try std.testing.expectEqualSlices(u8, raw, actual);
}
