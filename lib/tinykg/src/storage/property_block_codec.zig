const std = @import("std");

/// Logical byte view used by the v3 property base pair.  The container keeps
/// independently checksummed 64 KiB blocks so point and key-range reads touch
/// only the blocks intersecting the requested logical range.  Incompressible
/// blocks are stored verbatim; callers never need an unbounded whole-file
/// decompression buffer.
const magic = [_]u8{ 'T', 'K', 'P', 'B' };
const version: u16 = 3;
const legacy_version: u16 = 2;
const legacy_header_len: usize = 48;
const logical_prefix_len: usize = 64;
pub const header_len: usize = 128;
pub const directory_entry_len: usize = 48;
pub const block_bytes: u32 = 64 * 1024;
pub const compression_level_number: u8 = 3;
const compression_level = std.compress.flate.Compress.Options.level_3;
const logical_digest_seed: u64 = 0x544B_5042;
const block_digest_seed: u64 = 0x544B_5043;
const prefix_digest_seed: u64 = 0x544B_5050;
const header_digest_seed: u64 = 0x544B_5048;
pub const raw_fallback_enabled = true;
pub const per_block_checksum_enabled = true;
pub const logical_checksum_enabled = true;
pub const cache_block_count: u8 = 2;
pub const maximum_range_boundary_overhead_blocks: u8 = 1;
const flag_property_index_anchors: u32 = 1 << 0;
const flag_record_shuffle: u32 = 1 << 1;
const flag_record_delta: u32 = 1 << 2;

const PropertyIndexAnchor = struct {
    record_index: u32,
    key_hash: u64,
    owner_id: u64,
    owner_kind: u8,

    pub fn lessThanTarget(self: PropertyIndexAnchor, key_hash: u64, owner_kind: u8, owner_id: u64) bool {
        if (self.key_hash != key_hash) return self.key_hash < key_hash;
        if (self.owner_kind != owner_kind) return self.owner_kind < owner_kind;
        return self.owner_id < owner_id;
    }

    pub fn atMostTarget(self: PropertyIndexAnchor, key_hash: u64, owner_kind: u8, owner_id: u64) bool {
        return !targetLessThanAnchor(key_hash, owner_kind, owner_id, self);
    }
};

pub const PropertyIndexLayout = struct {
    header_len: u32,
    record_len: u32,
    key_hash_offset: u32,
    owner_id_offset: u32,
    owner_kind_offset: u32,
};

pub const EncodeOptions = struct {
    property_index: ?PropertyIndexLayout = null,
    record_shuffle: bool = false,
    record_delta: bool = false,
};

const RecordShuffleLayout = struct {
    kind: enum { property_index, property_values },
    header_len: u64,
    record_len: usize,
    record_count: u64,

    fn tableEnd(self: RecordShuffleLayout) !u64 {
        const records_bytes = std.math.mul(u64, self.record_count, self.record_len) catch return error.InvalidRecord;
        return std.math.add(u64, self.header_len, records_bytes) catch error.InvalidRecord;
    }
};

const RecordShuffleDirection = enum { encode, decode };

fn recordShuffleLayoutFromPrefix(prefix: []const u8) !RecordShuffleLayout {
    if (prefix.len < 16) return error.InvalidRecord;
    const layout = if (std.mem.eql(u8, prefix[0..4], "TKPX") and
        std.mem.readInt(u16, prefix[4..6], .little) == 1 and
        std.mem.readInt(u16, prefix[6..8], .little) == 40)
        RecordShuffleLayout{ .kind = .property_index, .header_len = 40, .record_len = 32, .record_count = std.mem.readInt(u64, prefix[8..16], .little) }
    else if (std.mem.eql(u8, prefix[0..4], "TKPV") and
        std.mem.readInt(u16, prefix[4..6], .little) == 1 and
        std.mem.readInt(u16, prefix[6..8], .little) == 56)
        RecordShuffleLayout{ .kind = .property_values, .header_len = 56, .record_len = 16, .record_count = std.mem.readInt(u64, prefix[8..16], .little) }
    else
        return error.InvalidRecord;
    _ = try layout.tableEnd();
    return layout;
}

fn transformRecordBlock(
    bytes: []u8,
    scratch: []u8,
    block_offset: u64,
    layout: RecordShuffleLayout,
    direction: RecordShuffleDirection,
    delta: bool,
) !void {
    const block_end = std.math.add(u64, block_offset, bytes.len) catch return error.InvalidRecord;
    const table_end = try layout.tableEnd();
    const range_start = @max(block_offset, layout.header_len);
    const range_end = @min(block_end, table_end);
    if (range_end <= range_start) return;
    const relative_start = range_start - layout.header_len;
    const first_record = (relative_start + layout.record_len - 1) / layout.record_len;
    const last_record = (range_end - layout.header_len) / layout.record_len;
    if (last_record <= first_record) return;
    const first_offset = layout.header_len + first_record * layout.record_len;
    const byte_count_u64 = (last_record - first_record) * layout.record_len;
    const local_offset = std.math.cast(usize, first_offset - block_offset) orelse return error.InvalidRecord;
    const byte_count = std.math.cast(usize, byte_count_u64) orelse return error.InvalidRecord;
    if (local_offset + byte_count > bytes.len or scratch.len < byte_count) return error.InvalidRecord;
    const record_count = byte_count / layout.record_len;
    @memcpy(scratch[0..byte_count], bytes[local_offset..][0..byte_count]);
    switch (direction) {
        .encode => {
            if (delta) try transformRecordColumnsDelta(scratch[0..byte_count], layout, record_count, .encode);
            for (0..layout.record_len) |column| {
                for (0..record_count) |row| {
                    bytes[local_offset + column * record_count + row] = scratch[row * layout.record_len + column];
                }
            }
        },
        .decode => {
            for (0..record_count) |row| {
                for (0..layout.record_len) |column| {
                    bytes[local_offset + row * layout.record_len + column] = scratch[column * record_count + row];
                }
            }
            if (delta) try transformRecordColumnsDelta(bytes[local_offset..][0..byte_count], layout, record_count, .decode);
        },
    }
}

fn transformRecordColumnsDelta(
    records: []u8,
    layout: RecordShuffleLayout,
    record_count: usize,
    direction: RecordShuffleDirection,
) !void {
    switch (layout.kind) {
        .property_index => {
            try transformU64ColumnDelta(records, layout.record_len, record_count, 0, direction);
            try transformU64ColumnDelta(records, layout.record_len, record_count, 8, direction);
            try transformU64ColumnDelta(records, layout.record_len, record_count, 16, direction);
        },
        .property_values => {
            try transformU64ColumnDelta(records, layout.record_len, record_count, 0, direction);
            try transformU32ColumnDelta(records, layout.record_len, record_count, 8, direction);
        },
    }
}

fn transformU64ColumnDelta(records: []u8, record_len: usize, record_count: usize, field_offset: usize, direction: RecordShuffleDirection) !void {
    var previous: u64 = 0;
    for (0..record_count) |row| {
        const offset = row * record_len + field_offset;
        if (offset + 8 > records.len) return error.InvalidRecord;
        const stored = std.mem.readInt(u64, records[offset..][0..8], .little);
        const value = switch (direction) {
            .encode => stored -% previous,
            .decode => stored +% previous,
        };
        std.mem.writeInt(u64, records[offset..][0..8], value, .little);
        previous = if (direction == .encode) stored else value;
    }
}

fn transformU32ColumnDelta(records: []u8, record_len: usize, record_count: usize, field_offset: usize, direction: RecordShuffleDirection) !void {
    var previous: u32 = 0;
    for (0..record_count) |row| {
        const offset = row * record_len + field_offset;
        if (offset + 4 > records.len) return error.InvalidRecord;
        const stored = std.mem.readInt(u32, records[offset..][0..4], .little);
        const value = switch (direction) {
            .encode => stored -% previous,
            .decode => stored +% previous,
        };
        std.mem.writeInt(u32, records[offset..][0..4], value, .little);
        previous = if (direction == .encode) stored else value;
    }
}

pub const StorageFormat = enum {
    raw,
    block_deflate,
};

pub const Header = struct {
    logical_size: u64,
    logical_digest: u64,
    directory_offset: u64,
    block_count: u32,
    flags: u32 = 0,
    anchor_count: u32 = 0,
    logical_prefix: [logical_prefix_len]u8 = [_]u8{0} ** logical_prefix_len,

    pub fn encode(self: Header, out: *[header_len]u8) !void {
        try self.validate();
        @memset(out, 0);
        @memcpy(out[0..4], &magic);
        std.mem.writeInt(u16, out[4..6], version, .little);
        std.mem.writeInt(u16, out[6..8], header_len, .little);
        std.mem.writeInt(u64, out[8..16], self.logical_size, .little);
        std.mem.writeInt(u64, out[16..24], self.logical_digest, .little);
        std.mem.writeInt(u64, out[24..32], self.directory_offset, .little);
        std.mem.writeInt(u32, out[32..36], self.block_count, .little);
        std.mem.writeInt(u32, out[36..40], block_bytes, .little);
        std.mem.writeInt(u32, out[40..44], self.flags, .little);
        std.mem.writeInt(u32, out[44..48], self.anchor_count, .little);
        @memcpy(out[48..112], &self.logical_prefix);
        const prefix_len = @min(std.math.cast(usize, self.logical_size) orelse logical_prefix_len, logical_prefix_len);
        std.mem.writeInt(u64, out[112..120], std.hash.Wyhash.hash(prefix_digest_seed, self.logical_prefix[0..prefix_len]), .little);
        std.mem.writeInt(u64, out[120..128], std.hash.Wyhash.hash(header_digest_seed, out[0..120]), .little);
    }

    pub fn decode(bytes: *const [header_len]u8) !Header {
        if (!std.mem.eql(u8, bytes[0..4], &magic)) return error.InvalidRecord;
        if (std.mem.readInt(u64, bytes[120..128], .little) != std.hash.Wyhash.hash(header_digest_seed, bytes[0..120])) return error.InvalidRecord;
        if (std.mem.readInt(u16, bytes[4..6], .little) != version) return error.InvalidRecord;
        if (std.mem.readInt(u16, bytes[6..8], .little) != header_len) return error.InvalidRecord;
        if (std.mem.readInt(u32, bytes[36..40], .little) != block_bytes) return error.InvalidRecord;
        var prefix: [logical_prefix_len]u8 = undefined;
        @memcpy(&prefix, bytes[48..112]);
        const header = Header{
            .logical_size = std.mem.readInt(u64, bytes[8..16], .little),
            .logical_digest = std.mem.readInt(u64, bytes[16..24], .little),
            .directory_offset = std.mem.readInt(u64, bytes[24..32], .little),
            .block_count = std.mem.readInt(u32, bytes[32..36], .little),
            .flags = std.mem.readInt(u32, bytes[40..44], .little),
            .anchor_count = std.mem.readInt(u32, bytes[44..48], .little),
            .logical_prefix = prefix,
        };
        try header.validate();
        const prefix_len = @min(std.math.cast(usize, header.logical_size) orelse logical_prefix_len, logical_prefix_len);
        if (std.mem.readInt(u64, bytes[112..120], .little) != std.hash.Wyhash.hash(prefix_digest_seed, header.logical_prefix[0..prefix_len])) return error.InvalidRecord;
        return header;
    }

    pub fn validate(self: Header) !void {
        if (self.logical_size == 0 or self.directory_offset < header_len) return error.InvalidRecord;
        if (self.block_count != try blockCountForLogicalSize(self.logical_size)) return error.InvalidRecord;
        if ((self.flags & ~(flag_property_index_anchors | flag_record_shuffle | flag_record_delta)) != 0) return error.InvalidRecord;
        if ((self.flags & flag_record_delta) != 0 and (self.flags & flag_record_shuffle) == 0) return error.InvalidRecord;
        if ((self.flags & flag_property_index_anchors) == 0) {
            if (self.anchor_count != 0) return error.InvalidRecord;
        } else if (self.anchor_count == 0 or self.anchor_count > self.block_count) {
            return error.InvalidRecord;
        }
        const prefix_len = @min(std.math.cast(usize, self.logical_size) orelse logical_prefix_len, logical_prefix_len);
        if (!std.mem.allEqual(u8, self.logical_prefix[prefix_len..], 0)) return error.InvalidRecord;
    }

    pub fn physicalSize(self: Header) !u64 {
        const directory_bytes = std.math.mul(u64, self.block_count, directory_entry_len) catch return error.InvalidRecord;
        return std.math.add(u64, self.directory_offset, directory_bytes) catch error.InvalidRecord;
    }
};

const DecodedHeader = struct {
    header: Header,
    physical_header_len: u64,
    mirrored_prefix_len: usize,
};

fn decodeLegacyHeader(bytes: *const [legacy_header_len]u8) !Header {
    if (!std.mem.eql(u8, bytes[0..4], &magic)) return error.InvalidRecord;
    if (std.mem.readInt(u16, bytes[4..6], .little) != legacy_version or
        std.mem.readInt(u16, bytes[6..8], .little) != legacy_header_len or
        std.mem.readInt(u32, bytes[36..40], .little) != block_bytes) return error.InvalidRecord;
    const header = Header{
        .logical_size = std.mem.readInt(u64, bytes[8..16], .little),
        .logical_digest = std.mem.readInt(u64, bytes[16..24], .little),
        .directory_offset = std.mem.readInt(u64, bytes[24..32], .little),
        .block_count = std.mem.readInt(u32, bytes[32..36], .little),
        .flags = std.mem.readInt(u32, bytes[40..44], .little),
        .anchor_count = std.mem.readInt(u32, bytes[44..48], .little),
    };
    if (header.logical_size == 0 or header.directory_offset < legacy_header_len) return error.InvalidRecord;
    if (header.block_count != try blockCountForLogicalSize(header.logical_size)) return error.InvalidRecord;
    if ((header.flags & ~flag_property_index_anchors) != 0) return error.InvalidRecord;
    if ((header.flags & flag_property_index_anchors) == 0) {
        if (header.anchor_count != 0) return error.InvalidRecord;
    } else if (header.anchor_count == 0 or header.anchor_count > header.block_count) {
        return error.InvalidRecord;
    }
    return header;
}

const DirectoryEntry = struct {
    physical_offset: u64,
    stored_len: u32,
    raw_len: u32,
    raw_digest: u64,
    anchor: ?PropertyIndexAnchor = null,

    pub fn encode(self: DirectoryEntry, out: *[directory_entry_len]u8) !void {
        try self.validate();
        std.mem.writeInt(u64, out[0..8], self.physical_offset, .little);
        std.mem.writeInt(u32, out[8..12], self.stored_len, .little);
        std.mem.writeInt(u32, out[12..16], self.raw_len, .little);
        std.mem.writeInt(u64, out[16..24], self.raw_digest, .little);
        if (self.anchor) |anchor| {
            std.mem.writeInt(u32, out[24..28], anchor.record_index, .little);
            out[28] = anchor.owner_kind;
            @memset(out[29..32], 0);
            std.mem.writeInt(u64, out[32..40], anchor.key_hash, .little);
            std.mem.writeInt(u64, out[40..48], anchor.owner_id, .little);
        } else {
            @memset(out[24..48], 0);
        }
    }

    pub fn decode(bytes: *const [directory_entry_len]u8) !DirectoryEntry {
        const entry = DirectoryEntry{
            .physical_offset = std.mem.readInt(u64, bytes[0..8], .little),
            .stored_len = std.mem.readInt(u32, bytes[8..12], .little),
            .raw_len = std.mem.readInt(u32, bytes[12..16], .little),
            .raw_digest = std.mem.readInt(u64, bytes[16..24], .little),
            .anchor = if (std.mem.allEqual(u8, bytes[24..48], 0)) null else .{
                .record_index = std.mem.readInt(u32, bytes[24..28], .little),
                .owner_kind = bytes[28],
                .key_hash = std.mem.readInt(u64, bytes[32..40], .little),
                .owner_id = std.mem.readInt(u64, bytes[40..48], .little),
            },
        };
        try entry.validate();
        return entry;
    }

    pub fn validate(self: DirectoryEntry) !void {
        if (self.physical_offset < legacy_header_len or self.stored_len == 0 or self.raw_len == 0) return error.InvalidRecord;
        if (self.raw_len > block_bytes or self.stored_len > self.raw_len) return error.InvalidRecord;
        if (self.anchor) |anchor| {
            if (anchor.owner_id == 0 or anchor.owner_id == std.math.maxInt(u64) or
                (anchor.owner_kind != 1 and anchor.owner_kind != 2)) return error.InvalidRecord;
        }
    }

    pub fn compressed(self: DirectoryEntry) bool {
        return self.stored_len < self.raw_len;
    }
};

fn targetLessThanAnchor(key_hash: u64, owner_kind: u8, owner_id: u64, anchor: PropertyIndexAnchor) bool {
    if (key_hash != anchor.key_hash) return key_hash < anchor.key_hash;
    if (owner_kind != anchor.owner_kind) return owner_kind < anchor.owner_kind;
    return owner_id < anchor.owner_id;
}

fn blockCountForLogicalSize(logical_size: u64) !u32 {
    if (logical_size == 0) return error.InvalidRecord;
    const rounded = std.math.add(u64, logical_size, block_bytes - 1) catch return error.InvalidRecord;
    return std.math.cast(u32, rounded / block_bytes) orelse error.InvalidRecord;
}

fn touchedBlockCount(offset: u64, len: u64) !u64 {
    if (len == 0) return 0;
    const last = std.math.add(u64, offset, len - 1) catch return error.InvalidRecord;
    return last / block_bytes - offset / block_bytes + 1;
}

fn maximumBlocksForRangeLength(len: u64) !u64 {
    if (len == 0) return 0;
    const rounded = std.math.add(u64, len, block_bytes - 1) catch return error.InvalidRecord;
    return std.math.add(u64, rounded / block_bytes, maximum_range_boundary_overhead_blocks) catch error.InvalidRecord;
}

const BlockCache = struct {
    block_index: ?usize = null,
    bytes: []u8 = &.{},
    last_used: u64 = 0,

    fn deinit(self: *BlockCache, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
        self.* = .{};
    }
};

pub const View = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    file: std.Io.File,
    format: StorageFormat,
    logical_size: u64,
    logical_digest: ?u64 = null,
    entries: []DirectoryEntry = &.{},
    caches: [cache_block_count]BlockCache = [_]BlockCache{.{}} ** cache_block_count,
    cache_clock: u64 = 0,
    stored_scratch: []u8 = &.{},
    flate_scratch: []u8 = &.{},
    transform_scratch: []u8 = &.{},
    block_load_count: u64 = 0,
    logical_prefix: [logical_prefix_len]u8 = [_]u8{0} ** logical_prefix_len,
    mirrored_prefix_len: usize = 0,
    record_shuffle: ?RecordShuffleLayout = null,
    record_delta: bool = false,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, file: std.Io.File) !View {
        const physical_size = try regularFileSize(io, file);
        if (physical_size < 4) return .{
            .allocator = allocator,
            .io = io,
            .file = file,
            .format = .raw,
            .logical_size = physical_size,
        };

        var prefix: [4]u8 = undefined;
        if (try file.readPositionalAll(io, &prefix, 0) != prefix.len) return error.InvalidRecord;
        if (!std.mem.eql(u8, &prefix, &magic)) return .{
            .allocator = allocator,
            .io = io,
            .file = file,
            .format = .raw,
            .logical_size = physical_size,
        };
        if (physical_size < 8) return error.InvalidRecord;

        var discriminator: [8]u8 = undefined;
        if (try file.readPositionalAll(io, &discriminator, 0) != discriminator.len) return error.InvalidRecord;
        const encoded_version = std.mem.readInt(u16, discriminator[4..6], .little);
        const encoded_header_len = std.mem.readInt(u16, discriminator[6..8], .little);
        const decoded: DecodedHeader = if (encoded_version == version and encoded_header_len == header_len) blk: {
            if (physical_size < header_len) return error.InvalidRecord;
            var header_bytes: [header_len]u8 = undefined;
            if (try file.readPositionalAll(io, &header_bytes, 0) != header_bytes.len) return error.InvalidRecord;
            break :blk .{ .header = try Header.decode(&header_bytes), .physical_header_len = @as(u64, header_len), .mirrored_prefix_len = logical_prefix_len };
        } else if (encoded_version == legacy_version and encoded_header_len == legacy_header_len) blk: {
            if (physical_size < legacy_header_len) return error.InvalidRecord;
            var header_bytes: [legacy_header_len]u8 = undefined;
            if (try file.readPositionalAll(io, &header_bytes, 0) != header_bytes.len) return error.InvalidRecord;
            const legacy = try decodeLegacyHeader(&header_bytes);
            break :blk .{ .header = legacy, .physical_header_len = @as(u64, legacy_header_len), .mirrored_prefix_len = @as(usize, 0) };
        } else return error.InvalidRecord;
        const header = decoded.header;
        if (try header.physicalSize() != physical_size) return error.InvalidRecord;
        const count = std.math.cast(usize, header.block_count) orelse return error.InvalidRecord;
        const entries = try allocator.alloc(DirectoryEntry, count);
        errdefer allocator.free(entries);

        var expected_physical_offset = decoded.physical_header_len;
        var logical_bytes: u64 = 0;
        var anchor_count: u32 = 0;
        var previous_anchor: ?PropertyIndexAnchor = null;
        var entry_bytes: [directory_entry_len]u8 = undefined;
        for (entries, 0..) |*entry, index| {
            const relative = std.math.mul(u64, index, directory_entry_len) catch return error.InvalidRecord;
            const entry_offset = std.math.add(u64, header.directory_offset, relative) catch return error.InvalidRecord;
            if (try file.readPositionalAll(io, &entry_bytes, entry_offset) != entry_bytes.len) return error.InvalidRecord;
            entry.* = try DirectoryEntry.decode(&entry_bytes);
            if (entry.anchor) |anchor| {
                anchor_count += 1;
                if (previous_anchor) |previous| {
                    if (!previous.lessThanTarget(anchor.key_hash, anchor.owner_kind, anchor.owner_id) or
                        previous.record_index >= anchor.record_index) return error.InvalidRecord;
                }
                previous_anchor = anchor;
            }
            if (entry.physical_offset != expected_physical_offset) return error.InvalidRecord;
            const expected_raw_len: u32 = @intCast(@min(@as(u64, block_bytes), header.logical_size - logical_bytes));
            if (entry.raw_len != expected_raw_len) return error.InvalidRecord;
            expected_physical_offset = std.math.add(u64, expected_physical_offset, entry.stored_len) catch return error.InvalidRecord;
            if (expected_physical_offset > header.directory_offset) return error.InvalidRecord;
            logical_bytes = std.math.add(u64, logical_bytes, entry.raw_len) catch return error.InvalidRecord;
        }
        if (expected_physical_offset != header.directory_offset or logical_bytes != header.logical_size) return error.InvalidRecord;
        if (anchor_count != header.anchor_count) return error.InvalidRecord;
        if ((header.flags & flag_property_index_anchors) != 0) {
            if (entries.len == 0 or entries[0].anchor == null or entries[0].anchor.?.record_index != 0) return error.InvalidRecord;
        } else {
            for (entries) |entry| {
                if (entry.anchor != null) return error.InvalidRecord;
            }
        }
        const record_shuffle = if ((header.flags & flag_record_shuffle) != 0)
            try recordShuffleLayoutFromPrefix(header.logical_prefix[0..@min(header.logical_size, logical_prefix_len)])
        else
            null;
        const record_delta = (header.flags & flag_record_delta) != 0;
        if (record_shuffle) |layout| {
            if (try layout.tableEnd() > header.logical_size) return error.InvalidRecord;
        }
        return .{
            .allocator = allocator,
            .io = io,
            .file = file,
            .format = .block_deflate,
            .logical_size = header.logical_size,
            .logical_digest = header.logical_digest,
            .entries = entries,
            .logical_prefix = header.logical_prefix,
            .mirrored_prefix_len = decoded.mirrored_prefix_len,
            .record_shuffle = record_shuffle,
            .record_delta = record_delta,
        };
    }

    pub fn propertyIndexRecordRange(
        self: *const View,
        key_hash: u64,
        owner_kind: u8,
        owner_id: u64,
        record_count: u64,
    ) !struct { start: u64, end: u64 } {
        if (self.format != .block_deflate or self.entries.len == 0 or self.entries[0].anchor == null) {
            return .{ .start = 0, .end = record_count };
        }
        var lo: usize = 0;
        var hi: usize = self.entries.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const anchor = self.entries[mid].anchor orelse return error.InvalidRecord;
            if (anchor.atMostTarget(key_hash, owner_kind, owner_id)) lo = mid + 1 else hi = mid;
        }
        const selected = if (lo == 0) 0 else lo - 1;
        const start = self.entries[selected].anchor.?.record_index;
        const end = if (selected + 1 < self.entries.len)
            self.entries[selected + 1].anchor.?.record_index
        else
            record_count;
        if (start > end or end > record_count) return error.InvalidRecord;
        return .{ .start = start, .end = end };
    }

    pub fn hasPropertyIndexAnchors(self: *const View) bool {
        return self.format == .block_deflate and self.entries.len != 0 and self.entries[0].anchor != null;
    }

    pub fn deinit(self: *View) void {
        self.allocator.free(self.entries);
        for (&self.caches) |*cache| cache.deinit(self.allocator);
        self.allocator.free(self.stored_scratch);
        self.allocator.free(self.flate_scratch);
        self.allocator.free(self.transform_scratch);
        self.* = undefined;
    }

    pub fn readAt(self: *View, offset: u64, out: []u8) !void {
        const end = std.math.add(u64, offset, out.len) catch return error.InvalidRecord;
        if (end > self.logical_size) return error.InvalidRecord;
        if (out.len == 0) return;
        if (self.format == .raw) {
            if (try self.file.readPositionalAll(self.io, out, offset) != out.len) return error.InvalidRecord;
            return;
        }

        var logical_offset = offset;
        var out_position: usize = 0;
        if (logical_offset < self.mirrored_prefix_len) {
            const prefix_offset = std.math.cast(usize, logical_offset) orelse return error.InvalidRecord;
            const available = @min(out.len, self.mirrored_prefix_len - prefix_offset);
            @memcpy(out[0..available], self.logical_prefix[prefix_offset..][0..available]);
            out_position = available;
            logical_offset += available;
        }
        while (out_position < out.len) {
            const block_index = std.math.cast(usize, logical_offset / block_bytes) orelse return error.InvalidRecord;
            if (block_index >= self.entries.len) return error.InvalidRecord;
            const entry = self.entries[block_index];
            const in_block_offset = std.math.cast(usize, logical_offset % block_bytes) orelse return error.InvalidRecord;
            if (in_block_offset >= entry.raw_len) return error.InvalidRecord;
            const take = @min(out.len - out_position, @as(usize, entry.raw_len) - in_block_offset);
            const block = try self.readBlock(block_index);
            @memcpy(out[out_position..][0..take], block[in_block_offset..][0..take]);
            out_position += take;
            logical_offset += take;
        }
    }

    pub fn validateAll(self: *View) !void {
        if (self.format == .raw) return;
        var hasher = std.hash.Wyhash.init(logical_digest_seed);
        for (self.entries, 0..) |_, index| hasher.update(try self.readBlock(index));
        if (hasher.final() != self.logical_digest.?) return error.InvalidRecord;
    }

    fn readBlock(self: *View, block_index: usize) ![]const u8 {
        if (block_index >= self.entries.len) return error.InvalidRecord;
        const entry = self.entries[block_index];
        const stored_len = std.math.cast(usize, entry.stored_len) orelse return error.InvalidRecord;
        const raw_len = std.math.cast(usize, entry.raw_len) orelse return error.InvalidRecord;
        self.cache_clock +%= 1;
        for (&self.caches) |*cache| {
            if (cache.block_index == block_index) {
                cache.last_used = self.cache_clock;
                return cache.bytes[0..raw_len];
            }
        }
        var victim = &self.caches[0];
        for (&self.caches) |*cache| {
            if (cache.block_index == null) {
                victim = cache;
                break;
            }
            if (cache.last_used < victim.last_used) victim = cache;
        }
        if (self.stored_scratch.len < stored_len) {
            self.stored_scratch = try self.allocator.realloc(self.stored_scratch, stored_len);
        }
        const stored = self.stored_scratch[0..stored_len];
        if (try self.file.readPositionalAll(self.io, stored, entry.physical_offset) != stored.len) return error.InvalidRecord;

        if (victim.bytes.len < raw_len) {
            victim.bytes = try self.allocator.realloc(victim.bytes, raw_len);
        }
        victim.block_index = null;
        const raw = victim.bytes[0..raw_len];
        if (entry.compressed()) {
            var input: std.Io.Reader = .fixed(stored);
            if (self.flate_scratch.len < std.compress.flate.max_window_len) {
                self.flate_scratch = try self.allocator.realloc(self.flate_scratch, std.compress.flate.max_window_len);
            }
            var decompressor = std.compress.flate.Decompress.init(&input, .raw, self.flate_scratch);
            decompressor.reader.readSliceAll(raw) catch return error.InvalidRecord;
        } else {
            @memcpy(raw, stored);
        }
        if (self.record_shuffle) |layout| {
            if (self.transform_scratch.len < raw_len) {
                self.transform_scratch = try self.allocator.realloc(self.transform_scratch, raw_len);
            }
            try transformRecordBlock(raw, self.transform_scratch, @as(u64, block_index) * block_bytes, layout, .decode, self.record_delta);
        }
        if (std.hash.Wyhash.hash(block_digest_seed, raw) != entry.raw_digest) return error.InvalidRecord;
        victim.block_index = block_index;
        victim.last_used = self.cache_clock;
        self.block_load_count = std.math.add(u64, self.block_load_count, 1) catch return error.InvalidRecord;
        return raw;
    }
};

pub const EncodeResult = struct {
    logical_bytes: u64,
    physical_bytes: u64,
    block_count: u32,
    compressed_blocks: u32,
    raw_blocks: u32,
};

fn encodeFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    input: std.Io.File,
    logical_size: u64,
    output: std.Io.File,
) !EncodeResult {
    return encodeFileWithOptions(allocator, io, input, logical_size, output, .{});
}

pub fn encodeFileWithOptions(
    allocator: std.mem.Allocator,
    io: std.Io,
    input: std.Io.File,
    logical_size: u64,
    output: std.Io.File,
    options: EncodeOptions,
) !EncodeResult {
    const input_size = try regularFileSize(io, input);
    if (input_size != logical_size or logical_size == 0) return error.InvalidRecord;
    if (options.record_delta and !options.record_shuffle) return error.InvalidRecord;
    const count = try blockCountForLogicalSize(logical_size);
    const entries = try allocator.alloc(DirectoryEntry, count);
    defer allocator.free(entries);
    const raw = try allocator.alloc(u8, block_bytes);
    defer allocator.free(raw);
    const compressed = try allocator.alloc(u8, @as(usize, block_bytes) * 2 + 1024);
    defer allocator.free(compressed);
    const transform_scratch = try allocator.alloc(u8, block_bytes);
    defer allocator.free(transform_scratch);
    const flate_buffer = try allocator.alloc(u8, std.compress.flate.max_window_len);
    defer allocator.free(flate_buffer);

    var logical_hasher = std.hash.Wyhash.init(logical_digest_seed);
    var logical_offset: u64 = 0;
    var physical_offset: u64 = header_len;
    var compressed_blocks: u32 = 0;
    var raw_blocks: u32 = 0;
    var anchor_count: u32 = 0;
    var shuffle_layout: ?RecordShuffleLayout = null;
    for (entries, 0..) |*entry, index| {
        const remaining = logical_size - logical_offset;
        const raw_len: usize = @intCast(@min(@as(u64, block_bytes), remaining));
        if (try input.readPositionalAll(io, raw[0..raw_len], logical_offset) != raw_len) return error.InvalidRecord;
        if (index == 0 and options.record_shuffle) {
            shuffle_layout = try recordShuffleLayoutFromPrefix(raw[0..raw_len]);
            if (try shuffle_layout.?.tableEnd() > logical_size) return error.InvalidRecord;
        }
        logical_hasher.update(raw[0..raw_len]);
        const raw_digest = std.hash.Wyhash.hash(block_digest_seed, raw[0..raw_len]);
        if (shuffle_layout) |layout| try transformRecordBlock(raw[0..raw_len], transform_scratch, logical_offset, layout, .encode, options.record_delta);
        const compressed_len = deflateBlock(raw[0..raw_len], compressed, flate_buffer);
        const stored = if (compressed_len < raw_len) compressed[0..compressed_len] else raw[0..raw_len];
        if (stored.ptr == compressed.ptr) compressed_blocks += 1 else raw_blocks += 1;
        try output.writePositionalAll(io, stored, physical_offset);
        entry.* = .{
            .physical_offset = physical_offset,
            .stored_len = std.math.cast(u32, stored.len) orelse return error.InvalidRecord,
            .raw_len = std.math.cast(u32, raw_len) orelse return error.InvalidRecord,
            .raw_digest = raw_digest,
        };
        if (options.property_index) |layout| {
            entry.anchor = try propertyIndexAnchorForBlock(input, io, logical_size, logical_offset, raw_len, layout);
            if (entry.anchor != null) anchor_count += 1;
        }
        physical_offset = std.math.add(u64, physical_offset, stored.len) catch return error.InvalidRecord;
        logical_offset = std.math.add(u64, logical_offset, raw_len) catch return error.InvalidRecord;
    }

    const directory_offset = physical_offset;
    var entry_bytes: [directory_entry_len]u8 = undefined;
    for (entries) |entry| {
        try entry.encode(&entry_bytes);
        try output.writePositionalAll(io, &entry_bytes, physical_offset);
        physical_offset = std.math.add(u64, physical_offset, entry_bytes.len) catch return error.InvalidRecord;
    }
    var logical_prefix: [logical_prefix_len]u8 = [_]u8{0} ** logical_prefix_len;
    const prefix_len = @min(std.math.cast(usize, logical_size) orelse logical_prefix_len, logical_prefix_len);
    if (try input.readPositionalAll(io, logical_prefix[0..prefix_len], 0) != prefix_len) return error.InvalidRecord;
    const header = Header{
        .logical_size = logical_size,
        .logical_digest = logical_hasher.final(),
        .directory_offset = directory_offset,
        .block_count = count,
        .flags = (if (anchor_count != 0) flag_property_index_anchors else 0) |
            (if (shuffle_layout != null) flag_record_shuffle else 0) |
            (if (options.record_delta) flag_record_delta else 0),
        .anchor_count = anchor_count,
        .logical_prefix = logical_prefix,
    };
    var header_bytes: [header_len]u8 = undefined;
    try header.encode(&header_bytes);
    try output.writePositionalAll(io, &header_bytes, 0);
    if (try regularFileSize(io, output) != physical_offset) return error.InvalidRecord;
    return .{
        .logical_bytes = logical_size,
        .physical_bytes = physical_offset,
        .block_count = count,
        .compressed_blocks = compressed_blocks,
        .raw_blocks = raw_blocks,
    };
}

fn propertyIndexAnchorForBlock(
    input: std.Io.File,
    io: std.Io,
    logical_size: u64,
    block_offset: u64,
    raw_len: usize,
    layout: PropertyIndexLayout,
) !?PropertyIndexAnchor {
    if (layout.record_len == 0 or layout.header_len > logical_size or
        layout.key_hash_offset + 8 > layout.record_len or
        layout.owner_id_offset + 8 > layout.record_len or
        layout.owner_kind_offset >= layout.record_len) return error.InvalidRecord;
    if (layout.header_len == logical_size) return null;
    const block_end = std.math.add(u64, block_offset, raw_len) catch return error.InvalidRecord;
    var record_index: u64 = 0;
    if (block_offset > layout.header_len) {
        const relative = block_offset - layout.header_len;
        record_index = (relative + layout.record_len - 1) / layout.record_len;
    }
    const record_offset = std.math.add(u64, layout.header_len, std.math.mul(u64, record_index, layout.record_len) catch return error.InvalidRecord) catch return error.InvalidRecord;
    const record_end = std.math.add(u64, record_offset, layout.record_len) catch return error.InvalidRecord;
    if (record_end > logical_size or record_end > block_end) return null;
    var bytes: [32]u8 = undefined;
    if (layout.record_len != bytes.len) return error.InvalidRecord;
    if (try input.readPositionalAll(io, &bytes, record_offset) != bytes.len) return error.InvalidRecord;
    return .{
        .record_index = std.math.cast(u32, record_index) orelse return error.RecordTooLarge,
        .key_hash = std.mem.readInt(u64, bytes[layout.key_hash_offset..][0..8], .little),
        .owner_id = std.mem.readInt(u64, bytes[layout.owner_id_offset..][0..8], .little),
        .owner_kind = bytes[layout.owner_kind_offset],
    };
}

fn deflateBlock(input: []const u8, output: []u8, flate_buffer: []u8) usize {
    var fixed: std.Io.Writer = .fixed(output);
    var compressor = std.compress.flate.Compress.init(&fixed, flate_buffer, .raw, compression_level) catch return input.len;
    compressor.writer.writeAll(input) catch return input.len;
    compressor.finish() catch return input.len;
    return fixed.buffered().len;
}

fn regularFileSize(io: std.Io, file: std.Io.File) !u64 {
    const stat = try file.stat(io);
    if (stat.kind != .file) return error.IsDir;
    return stat.size;
}

const EncodedFixture = struct {
    temporary: std.testing.TmpDir,
    input: std.Io.File,
    encoded: std.Io.File,
};

fn createEncodedFixtureWithOptions(bytes: []const u8, options: EncodeOptions) !EncodedFixture {
    var temporary = std.testing.tmpDir(.{});
    errdefer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "raw", .data = bytes });
    const input = try temporary.dir.openFile(std.testing.io, "raw", .{});
    errdefer input.close(std.testing.io);
    const encoded = try temporary.dir.createFile(std.testing.io, "encoded", .{ .read = true, .truncate = true });
    errdefer encoded.close(std.testing.io);
    _ = try encodeFileWithOptions(std.testing.allocator, std.testing.io, input, bytes.len, encoded, options);
    return .{ .temporary = temporary, .input = input, .encoded = encoded };
}

fn createEncodedFixture(bytes: []const u8) !EncodedFixture {
    return createEncodedFixtureWithOptions(bytes, .{});
}

fn propertyIndexFixtureBytes(record_count: usize) ![]u8 {
    const header_bytes: usize = 40;
    const record_bytes: usize = 32;
    const bytes = try std.testing.allocator.alloc(u8, header_bytes + record_count * record_bytes);
    @memset(bytes, 0);
    @memcpy(bytes[0..4], "TKPX");
    std.mem.writeInt(u16, bytes[4..6], 1, .little);
    std.mem.writeInt(u16, bytes[6..8], header_bytes, .little);
    std.mem.writeInt(u64, bytes[8..16], record_count, .little);
    for (0..record_count) |index| {
        const offset = header_bytes + index * record_bytes;
        std.mem.writeInt(u64, bytes[offset..][0..8], 0x1000 + index / 17, .little);
        std.mem.writeInt(u64, bytes[offset + 8 ..][0..8], 0x8000_0000_0000_0000 +% index *% 0x9e37_79b9, .little);
        std.mem.writeInt(u64, bytes[offset + 16 ..][0..8], index + 1, .little);
        bytes[offset + 24] = if (index % 2 == 0) 1 else 2;
        bytes[offset + 25] = if (index % 3 == 0) 1 else 2;
    }
    return bytes;
}

fn propertyValuesFixtureBytes(record_count: usize, payload_len: usize) ![]u8 {
    const header_bytes: usize = 56;
    const record_bytes: usize = 16;
    const table_bytes = header_bytes + record_count * record_bytes;
    const bytes = try std.testing.allocator.alloc(u8, table_bytes + payload_len);
    @memset(bytes, 0);
    @memcpy(bytes[0..4], "TKPV");
    std.mem.writeInt(u16, bytes[4..6], 1, .little);
    std.mem.writeInt(u16, bytes[6..8], header_bytes, .little);
    std.mem.writeInt(u64, bytes[8..16], record_count, .little);
    std.mem.writeInt(u64, bytes[32..40], payload_len, .little);
    var payload_offset: u64 = 0;
    for (0..record_count) |index| {
        const offset = header_bytes + index * record_bytes;
        const len: u32 = @intCast(8 + index % 41);
        std.mem.writeInt(u64, bytes[offset..][0..8], payload_offset, .little);
        std.mem.writeInt(u32, bytes[offset + 8 ..][0..4], len, .little);
        payload_offset += len;
    }
    var random = std.Random.DefaultPrng.init(0x544b_5042);
    random.fill(bytes[table_bytes..]);
    return bytes;
}

test "property block codec header and directory preserve stable layout" {
    const header = Header{
        .logical_size = block_bytes + 7,
        .logical_digest = 0x0102_0304_0506_0708,
        .directory_offset = 1234,
        .block_count = 2,
    };
    var header_bytes: [header_len]u8 = undefined;
    try header.encode(&header_bytes);
    try std.testing.expectEqualSlices(u8, "TKPB", header_bytes[0..4]);
    try std.testing.expectEqual(header, try Header.decode(&header_bytes));
    header_bytes[40] = 1;
    try std.testing.expectError(error.InvalidRecord, Header.decode(&header_bytes));

    const entry = DirectoryEntry{
        .physical_offset = header_len,
        .stored_len = 99,
        .raw_len = block_bytes,
        .raw_digest = 0x8877_6655_4433_2211,
    };
    var entry_bytes: [directory_entry_len]u8 = undefined;
    try entry.encode(&entry_bytes);
    try std.testing.expectEqual(entry, try DirectoryEntry.decode(&entry_bytes));
    std.mem.writeInt(u32, entry_bytes[8..12], block_bytes + 1, .little);
    try std.testing.expectError(error.InvalidRecord, DirectoryEntry.decode(&entry_bytes));
}

test "property block codec round trips compressed and raw fallback blocks" {
    const bytes = try std.testing.allocator.alloc(u8, block_bytes * 2);
    defer std.testing.allocator.free(bytes);
    @memset(bytes[0..block_bytes], 'a');
    var random = std.Random.DefaultPrng.init(12345);
    random.fill(bytes[block_bytes..]);

    var fixture = try createEncodedFixture(bytes);
    defer fixture.temporary.cleanup();
    defer fixture.input.close(std.testing.io);
    defer fixture.encoded.close(std.testing.io);
    var view = try View.init(std.testing.allocator, std.testing.io, fixture.encoded);
    defer view.deinit();
    try std.testing.expectEqual(StorageFormat.block_deflate, view.format);
    try std.testing.expect(view.entries[0].compressed());
    try std.testing.expect(!view.entries[1].compressed());
    const decoded = try std.testing.allocator.alloc(u8, bytes.len);
    defer std.testing.allocator.free(decoded);
    try view.readAt(0, decoded);
    try std.testing.expectEqualSlices(u8, bytes, decoded);
    try view.validateAll();
}

test "property block codec delta shuffle round trips index records across block boundaries" {
    const bytes = try propertyIndexFixtureBytes(10_000);
    defer std.testing.allocator.free(bytes);
    var fixture = try createEncodedFixtureWithOptions(bytes, .{ .record_shuffle = true, .record_delta = true });
    defer fixture.temporary.cleanup();
    defer fixture.input.close(std.testing.io);
    defer fixture.encoded.close(std.testing.io);
    var view = try View.init(std.testing.allocator, std.testing.io, fixture.encoded);
    defer view.deinit();
    try std.testing.expect(view.record_shuffle != null);
    try std.testing.expect(view.record_delta);
    const decoded = try std.testing.allocator.alloc(u8, bytes.len);
    defer std.testing.allocator.free(decoded);
    try view.readAt(0, decoded);
    try std.testing.expectEqualSlices(u8, bytes, decoded);
    try view.validateAll();
}

test "property block codec delta shuffle preserves values raw fallback and detects corruption" {
    const bytes = try propertyValuesFixtureBytes(1, block_bytes * 2);
    defer std.testing.allocator.free(bytes);
    var fixture = try createEncodedFixtureWithOptions(bytes, .{ .record_shuffle = true, .record_delta = true });
    defer fixture.temporary.cleanup();
    defer fixture.input.close(std.testing.io);
    defer fixture.encoded.close(std.testing.io);

    var view = try View.init(std.testing.allocator, std.testing.io, fixture.encoded);
    var raw_block: ?usize = null;
    for (view.entries, 0..) |entry, index| {
        if (!entry.compressed()) {
            raw_block = index;
            break;
        }
    }
    try std.testing.expect(raw_block != null);
    const corrupt_offset = view.entries[raw_block.?].physical_offset;
    const decoded = try std.testing.allocator.alloc(u8, bytes.len);
    defer std.testing.allocator.free(decoded);
    try view.readAt(0, decoded);
    try std.testing.expectEqualSlices(u8, bytes, decoded);
    view.deinit();

    var byte: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), try fixture.encoded.readPositionalAll(std.testing.io, &byte, corrupt_offset));
    byte[0] ^= 0xff;
    try fixture.encoded.writePositionalAll(std.testing.io, &byte, corrupt_offset);
    var corrupt = try View.init(std.testing.allocator, std.testing.io, fixture.encoded);
    defer corrupt.deinit();
    try std.testing.expectError(error.InvalidRecord, corrupt.validateAll());
}

test "property block codec requires shuffle when delta is enabled" {
    const bytes = try propertyIndexFixtureBytes(1);
    defer std.testing.allocator.free(bytes);
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "raw", .data = bytes });
    var input = try temporary.dir.openFile(std.testing.io, "raw", .{});
    defer input.close(std.testing.io);
    var encoded = try temporary.dir.createFile(std.testing.io, "encoded", .{ .read = true, .truncate = true });
    defer encoded.close(std.testing.io);
    try std.testing.expectError(error.InvalidRecord, encodeFileWithOptions(
        std.testing.allocator,
        std.testing.io,
        input,
        bytes.len,
        encoded,
        .{ .record_delta = true },
    ));

    const invalid_header = Header{
        .logical_size = bytes.len,
        .logical_digest = 1,
        .directory_offset = header_len + bytes.len,
        .block_count = 1,
        .flags = flag_record_delta,
    };
    var header_bytes: [header_len]u8 = undefined;
    try std.testing.expectError(error.InvalidRecord, invalid_header.encode(&header_bytes));
}

test "property block codec point range touches at most two blocks and reuses a cached boundary" {
    const bytes = try std.testing.allocator.alloc(u8, block_bytes * 3);
    defer std.testing.allocator.free(bytes);
    for (bytes, 0..) |*byte, index| byte.* = @intCast(index % 251);
    var fixture = try createEncodedFixture(bytes);
    defer fixture.temporary.cleanup();
    defer fixture.input.close(std.testing.io);
    defer fixture.encoded.close(std.testing.io);
    var view = try View.init(std.testing.allocator, std.testing.io, fixture.encoded);
    defer view.deinit();

    var out: [64]u8 = undefined;
    const offset = block_bytes - 32;
    try std.testing.expectEqual(@as(u64, 2), try touchedBlockCount(offset, out.len));
    try std.testing.expect((try touchedBlockCount(offset, out.len)) <= try maximumBlocksForRangeLength(out.len));
    try view.readAt(offset, &out);
    try std.testing.expectEqual(@as(u64, 2), view.block_load_count);
    try std.testing.expectEqualSlices(u8, bytes[offset .. offset + out.len], &out);
    const loads = view.block_load_count;
    try view.readAt(block_bytes + 8, out[0..16]);
    try std.testing.expectEqual(loads, view.block_load_count);
}

test "property block codec retains two alternating blocks" {
    const bytes = try std.testing.allocator.alloc(u8, block_bytes * 3);
    defer std.testing.allocator.free(bytes);
    for (bytes, 0..) |*byte, index| byte.* = @intCast(index % 251);
    var fixture = try createEncodedFixture(bytes);
    defer fixture.temporary.cleanup();
    defer fixture.input.close(std.testing.io);
    defer fixture.encoded.close(std.testing.io);
    var view = try View.init(std.testing.allocator, std.testing.io, fixture.encoded);
    defer view.deinit();

    var out: [32]u8 = undefined;
    try view.readAt(128, &out);
    try view.readAt(block_bytes + 128, &out);
    const alternating_loads = view.block_load_count;
    try view.readAt(256, &out);
    try view.readAt(block_bytes + 256, &out);
    try std.testing.expectEqual(@as(u64, 2), alternating_loads);
    try std.testing.expectEqual(alternating_loads, view.block_load_count);

    try view.readAt(@as(u64, block_bytes) * 2 + 128, &out);
    try std.testing.expectEqual(@as(u64, 3), view.block_load_count);
}

test "property block codec arbitrary ranges pay at most one boundary block" {
    const cases = [_]struct { offset: u64, len: u64 }{
        .{ .offset = 0, .len = 1 },
        .{ .offset = block_bytes - 1, .len = 1 },
        .{ .offset = block_bytes - 1, .len = block_bytes },
        .{ .offset = 17, .len = @as(u64, block_bytes) * 8 + 123 },
        .{ .offset = @as(u64, block_bytes) * 100 + 31, .len = @as(u64, block_bytes) * 257 },
    };
    for (cases) |case| {
        try std.testing.expect((try touchedBlockCount(case.offset, case.len)) <= try maximumBlocksForRangeLength(case.len));
    }
}

test "property block codec checksum corruption fails on the affected block" {
    const bytes = try std.testing.allocator.alloc(u8, block_bytes + 17);
    defer std.testing.allocator.free(bytes);
    @memset(bytes, 'z');
    var fixture = try createEncodedFixture(bytes);
    defer fixture.temporary.cleanup();
    defer fixture.input.close(std.testing.io);
    defer fixture.encoded.close(std.testing.io);

    var view = try View.init(std.testing.allocator, std.testing.io, fixture.encoded);
    const corrupt_offset = view.entries[0].physical_offset;
    view.deinit();
    var byte: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), try fixture.encoded.readPositionalAll(std.testing.io, &byte, corrupt_offset));
    byte[0] ^= 0xff;
    try fixture.encoded.writePositionalAll(std.testing.io, &byte, corrupt_offset);

    var corrupt = try View.init(std.testing.allocator, std.testing.io, fixture.encoded);
    defer corrupt.deinit();
    var out: [32]u8 = undefined;
    try corrupt.readAt(0, &out);
    try std.testing.expectEqualSlices(u8, bytes[0..out.len], &out);
    try std.testing.expectError(error.InvalidRecord, corrupt.readAt(logical_prefix_len, &out));
    try std.testing.expectError(error.InvalidRecord, corrupt.validateAll());
}

test "property block codec mirrors short logical files without loading a block" {
    const cases = [_][]const u8{
        "x",
        "short property base",
        "0123456789012345678901234567890123456789",
        "0123456789012345678901234567890123456789012345678901234",
    };
    for (cases) |bytes| {
        var fixture = try createEncodedFixture(bytes);
        defer fixture.temporary.cleanup();
        defer fixture.input.close(std.testing.io);
        defer fixture.encoded.close(std.testing.io);
        var view = try View.init(std.testing.allocator, std.testing.io, fixture.encoded);
        defer view.deinit();
        const decoded = try std.testing.allocator.alloc(u8, bytes.len);
        defer std.testing.allocator.free(decoded);
        try view.readAt(0, decoded);
        try std.testing.expectEqualSlices(u8, bytes, decoded);
        try std.testing.expectEqual(@as(u64, 0), view.block_load_count);
        try view.validateAll();
        try std.testing.expectEqual(@as(u64, 1), view.block_load_count);
    }
}

test "property block codec rejects corrupted mirrored logical prefix" {
    var fixture = try createEncodedFixture("property header bytes");
    defer fixture.temporary.cleanup();
    defer fixture.input.close(std.testing.io);
    defer fixture.encoded.close(std.testing.io);
    var byte: [1]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), try fixture.encoded.readPositionalAll(std.testing.io, &byte, 48));
    byte[0] ^= 0xff;
    try fixture.encoded.writePositionalAll(std.testing.io, &byte, 48);
    try std.testing.expectError(error.InvalidRecord, View.init(std.testing.allocator, std.testing.io, fixture.encoded));
}

test "property block codec rejects noncontiguous directory before payload reads" {
    var bytes: [128]u8 = undefined;
    @memset(&bytes, 'q');
    var fixture = try createEncodedFixture(&bytes);
    defer fixture.temporary.cleanup();
    defer fixture.input.close(std.testing.io);
    defer fixture.encoded.close(std.testing.io);
    var header_bytes: [header_len]u8 = undefined;
    try std.testing.expectEqual(header_bytes.len, try fixture.encoded.readPositionalAll(std.testing.io, &header_bytes, 0));
    const header = try Header.decode(&header_bytes);
    var entry_bytes: [directory_entry_len]u8 = undefined;
    try std.testing.expectEqual(entry_bytes.len, try fixture.encoded.readPositionalAll(std.testing.io, &entry_bytes, header.directory_offset));
    std.mem.writeInt(u64, entry_bytes[0..8], header_len + 1, .little);
    try fixture.encoded.writePositionalAll(std.testing.io, &entry_bytes, header.directory_offset);
    try std.testing.expectError(error.InvalidRecord, View.init(std.testing.allocator, std.testing.io, fixture.encoded));
}

test "property block codec retains legacy raw logical view" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "raw", .data = "TKPX legacy property bytes" });
    var file = try temporary.dir.openFile(std.testing.io, "raw", .{});
    defer file.close(std.testing.io);
    var view = try View.init(std.testing.allocator, std.testing.io, file);
    defer view.deinit();
    try std.testing.expectEqual(StorageFormat.raw, view.format);
    var out: [4]u8 = undefined;
    try view.readAt(0, &out);
    try std.testing.expectEqualSlices(u8, "TKPX", &out);
}

test "property block codec reads legacy v2 block containers" {
    const logical = "legacy v2 property payload remains readable";
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var file = try temporary.dir.createFile(std.testing.io, "legacy-v2", .{ .read = true, .truncate = true });
    defer file.close(std.testing.io);

    var header_bytes: [legacy_header_len]u8 = [_]u8{0} ** legacy_header_len;
    @memcpy(header_bytes[0..4], &magic);
    std.mem.writeInt(u16, header_bytes[4..6], legacy_version, .little);
    std.mem.writeInt(u16, header_bytes[6..8], legacy_header_len, .little);
    std.mem.writeInt(u64, header_bytes[8..16], logical.len, .little);
    std.mem.writeInt(u64, header_bytes[16..24], std.hash.Wyhash.hash(logical_digest_seed, logical), .little);
    std.mem.writeInt(u64, header_bytes[24..32], legacy_header_len + logical.len, .little);
    std.mem.writeInt(u32, header_bytes[32..36], 1, .little);
    std.mem.writeInt(u32, header_bytes[36..40], block_bytes, .little);
    try file.writePositionalAll(std.testing.io, &header_bytes, 0);
    try file.writePositionalAll(std.testing.io, logical, legacy_header_len);
    const entry = DirectoryEntry{
        .physical_offset = legacy_header_len,
        .stored_len = logical.len,
        .raw_len = logical.len,
        .raw_digest = std.hash.Wyhash.hash(block_digest_seed, logical),
    };
    var entry_bytes: [directory_entry_len]u8 = undefined;
    try entry.encode(&entry_bytes);
    try file.writePositionalAll(std.testing.io, &entry_bytes, legacy_header_len + logical.len);

    var view = try View.init(std.testing.allocator, std.testing.io, file);
    defer view.deinit();
    try std.testing.expectEqual(@as(usize, 0), view.mirrored_prefix_len);
    var decoded: [logical.len]u8 = undefined;
    try view.readAt(0, &decoded);
    try std.testing.expectEqualSlices(u8, logical, &decoded);
    try std.testing.expectEqual(@as(u64, 1), view.block_load_count);
    try view.validateAll();
}
