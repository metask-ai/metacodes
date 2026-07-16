const std = @import("std");
const segment_catalog_summary = @import("segment_catalog_summary.zig");

pub const SegmentKind = enum(u16) {
    node = 1,
    edge = 2,
    text = 3,
    task = 4,
    delta = 5,
    compacted = 6,
};

pub const IdRange = struct {
    min: u64 = 0,
    max: u64 = 0,
};

pub const Entry = struct {
    kind: SegmentKind,
    generation: u64,
    node_count: u64 = 0,
    edge_count: u64 = 0,
    node_digest: u64 = 0,
    node_range: IdRange = .{},
    edge_range: IdRange = .{},
    segment_digest: u64 = 0,
    hotness_hint: u32 = 0,
    node_catalog_summary: ?segment_catalog_summary.CatalogSummary = null,
    path: []const u8,
};

pub const OwnedEntry = struct {
    kind: SegmentKind,
    generation: u64,
    node_count: u64 = 0,
    edge_count: u64 = 0,
    node_digest: u64 = 0,
    node_range: IdRange = .{},
    edge_range: IdRange = .{},
    segment_digest: u64 = 0,
    hotness_hint: u32 = 0,
    node_catalog_summary: ?segment_catalog_summary.CatalogSummary = null,
    path: []u8,

    pub fn deinit(self: *OwnedEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
    }

    pub fn asEntry(self: OwnedEntry) Entry {
        return .{
            .kind = self.kind,
            .generation = self.generation,
            .node_count = self.node_count,
            .edge_count = self.edge_count,
            .node_digest = self.node_digest,
            .node_range = self.node_range,
            .edge_range = self.edge_range,
            .segment_digest = self.segment_digest,
            .hotness_hint = self.hotness_hint,
            .node_catalog_summary = self.node_catalog_summary,
            .path = self.path,
        };
    }
};

pub const Snapshot = struct {
    generation: u64,
    wal_checkpoint_bytes: u64,
    manifest_path: []u8,
    entries: std.ArrayList(OwnedEntry) = .empty,

    pub fn deinit(self: *Snapshot, allocator: std.mem.Allocator) void {
        for (self.entries.items) |*entry| entry.deinit(allocator);
        self.entries.deinit(allocator);
        allocator.free(self.manifest_path);
    }

    pub fn totalEdges(self: Snapshot) !u64 {
        var total: u64 = 0;
        for (self.entries.items) |entry| {
            total = try std.math.add(u64, total, entry.edge_count);
        }
        return total;
    }

    pub fn totalNodes(self: Snapshot) !u64 {
        var total: u64 = 0;
        for (self.entries.items) |entry| {
            total = try std.math.add(u64, total, entry.node_count);
        }
        return total;
    }
};

pub const GcResult = struct {
    deleted_manifests: u64 = 0,
};

pub const WalRecordKind = enum(u16) {
    node = 1,
    edge = 2,
    tombstone = 3,
    segment_flush = 4,
};

pub const WalTailRecord = struct {
    kind: WalRecordKind,
    offset: u64,
    payload_offset: u64,
    payload_len: u32,
    payload_digest: u64,
    next_offset: u64,
};

pub const WalTailReplayPlan = struct {
    snapshot: Snapshot,
    checkpoint_bytes: u64,
    end_bytes: u64,
    records: std.ArrayList(WalTailRecord) = .empty,

    pub fn deinit(self: *WalTailReplayPlan, allocator: std.mem.Allocator) void {
        self.records.deinit(allocator);
        self.snapshot.deinit(allocator);
    }

    pub fn tailBytes(self: WalTailReplayPlan) !u64 {
        if (self.end_bytes < self.checkpoint_bytes) return error.InvalidRecord;
        return self.end_bytes - self.checkpoint_bytes;
    }
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    dir_path: []u8,
    current_path: []u8,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, dir_path: []const u8) !Store {
        const owned_dir = try allocator.dupe(u8, dir_path);
        errdefer allocator.free(owned_dir);
        const current_path = try std.fs.path.join(allocator, &.{ owned_dir, current_leaf });
        errdefer allocator.free(current_path);
        try std.Io.Dir.cwd().createDirPath(io, owned_dir);
        return .{
            .allocator = allocator,
            .io = io,
            .dir_path = owned_dir,
            .current_path = current_path,
        };
    }

    pub fn deinit(self: *Store) void {
        self.allocator.free(self.current_path);
        self.allocator.free(self.dir_path);
    }

    pub fn publish(self: Store, wal_checkpoint_bytes: u64, entries: []const Entry) !u64 {
        const next_generation = try self.nextGeneration();
        try self.publishExpectedGeneration(next_generation, wal_checkpoint_bytes, entries);
        return next_generation;
    }

    pub fn publishExpectedGeneration(self: Store, expected_generation: u64, wal_checkpoint_bytes: u64, entries: []const Entry) !void {
        const next_generation = try self.nextGeneration();
        if (next_generation != expected_generation) return error.InvalidRecord;
        try validateEntries(next_generation, entries);

        const leaf = try manifestLeaf(self.allocator, next_generation);
        defer self.allocator.free(leaf);
        const path = try std.fs.path.join(self.allocator, &.{ self.dir_path, leaf });
        defer self.allocator.free(path);

        try self.writeManifestFile(path, next_generation, wal_checkpoint_bytes, entries);
        try self.writeCurrent(leaf);
    }

    pub fn nextGeneration(self: Store) !u64 {
        const current_generation = self.readVerifiedCurrentGeneration() catch |err| switch (err) {
            error.FileNotFound => 0,
            else => |e| return e,
        };
        const next_generation = try std.math.add(u64, current_generation, 1);
        if (next_generation == 0) return error.RecordTooLarge;
        return next_generation;
    }

    pub fn pinCurrent(self: Store) !Snapshot {
        const leaf = try self.readCurrentLeaf();
        defer self.allocator.free(leaf);
        const path = try std.fs.path.join(self.allocator, &.{ self.dir_path, leaf });
        defer self.allocator.free(path);
        const snapshot = self.readManifestFile(path) catch |err| switch (err) {
            error.FileNotFound => return error.InvalidRecord,
            else => |e| return e,
        };
        const leaf_generation = parseManifestLeaf(leaf) orelse return error.InvalidRecord;
        if (snapshot.generation != leaf_generation) {
            var mutable = snapshot;
            mutable.deinit(self.allocator);
            return error.InvalidRecord;
        }
        if (!std.mem.eql(u8, std.fs.path.basename(snapshot.manifest_path), leaf)) {
            var mutable = snapshot;
            mutable.deinit(self.allocator);
            return error.InvalidRecord;
        }
        return snapshot;
    }

    pub fn gcUnpinned(self: Store, pinned: []const Snapshot) !GcResult {
        const current_generation = self.readVerifiedCurrentGeneration() catch |err| switch (err) {
            error.FileNotFound => 0,
            else => |e| return e,
        };
        var result = GcResult{};
        var dir = try std.Io.Dir.cwd().openDir(self.io, self.dir_path, .{ .iterate = true });
        defer dir.close(self.io);
        var iter = dir.iterate();
        while (try iter.next(self.io)) |entry| {
            if (entry.kind != .file) continue;
            const generation = parseManifestLeaf(entry.name) orelse continue;
            if (generation == current_generation or snapshotPinned(generation, pinned)) continue;
            const path = try std.fs.path.join(self.allocator, &.{ self.dir_path, entry.name });
            errdefer self.allocator.free(path);
            try std.Io.Dir.cwd().deleteFile(self.io, path);
            self.allocator.free(path);
            result.deleted_manifests = try std.math.add(u64, result.deleted_manifests, 1);
        }
        return result;
    }

    pub fn planWalTailRecovery(self: Store, wal_path: []const u8) !WalTailReplayPlan {
        const snapshot = try self.pinCurrent();
        return try readWalTailReplayPlan(self.allocator, self.io, wal_path, snapshot);
    }

    fn readVerifiedCurrentGeneration(self: Store) !u64 {
        var snapshot = try self.pinCurrent();
        defer snapshot.deinit(self.allocator);
        return snapshot.generation;
    }

    fn readCurrentLeaf(self: Store) ![]u8 {
        var file = try std.Io.Dir.cwd().openFile(self.io, self.current_path, .{});
        defer file.close(self.io);
        const stat = try file.stat(self.io);
        if (stat.kind != .file) return error.InvalidRecord;
        if (stat.size == 0 or stat.size > max_current_bytes) return error.InvalidRecord;
        const len = std.math.cast(usize, stat.size) orelse return error.RecordTooLarge;
        const leaf = try self.allocator.alloc(u8, len);
        errdefer self.allocator.free(leaf);
        if (try file.readPositionalAll(self.io, leaf, 0) != leaf.len) return error.InvalidRecord;
        if (parseManifestLeaf(leaf) == null) return error.InvalidRecord;
        return leaf;
    }

    fn writeCurrent(self: Store, leaf: []const u8) !void {
        if (parseManifestLeaf(leaf) == null) return error.InvalidRecord;
        const tmp_path = try tmpPath(self.allocator, self.current_path);
        defer self.allocator.free(tmp_path);
        errdefer std.Io.Dir.cwd().deleteFile(self.io, tmp_path) catch {};
        {
            var file = try std.Io.Dir.cwd().createFile(self.io, tmp_path, .{ .read = true, .truncate = true });
            defer file.close(self.io);
            try file.writePositionalAll(self.io, leaf, 0);
            try file.sync(self.io);
        }
        try renameReplace(self.io, tmp_path, self.current_path);
    }

    fn writeManifestFile(self: Store, path: []const u8, generation: u64, wal_checkpoint_bytes: u64, entries: []const Entry) !void {
        const tmp = try tmpPath(self.allocator, path);
        defer self.allocator.free(tmp);
        errdefer std.Io.Dir.cwd().deleteFile(self.io, tmp) catch {};

        var bytes = std.ArrayList(u8).empty;
        defer bytes.deinit(self.allocator);
        try encodeManifest(self.allocator, &bytes, generation, wal_checkpoint_bytes, entries);
        {
            var file = try std.Io.Dir.cwd().createFile(self.io, tmp, .{ .read = true, .truncate = true });
            defer file.close(self.io);
            try file.writePositionalAll(self.io, bytes.items, 0);
            try file.sync(self.io);
        }
        try renameReplace(self.io, tmp, path);
    }

    fn readManifestFile(self: Store, path: []const u8) !Snapshot {
        var file = try std.Io.Dir.cwd().openFile(self.io, path, .{});
        defer file.close(self.io);
        const stat = try file.stat(self.io);
        if (stat.kind != .file) return error.InvalidRecord;
        if (stat.size < ManifestHeader.encoded_len or stat.size > max_manifest_file_bytes) return error.InvalidRecord;
        const size = std.math.cast(usize, stat.size) orelse return error.RecordTooLarge;
        const bytes = try self.allocator.alloc(u8, size);
        defer self.allocator.free(bytes);
        if (try file.readPositionalAll(self.io, bytes, 0) != bytes.len) return error.InvalidRecord;
        return try decodeManifest(self.allocator, path, bytes);
    }
};

const current_leaf = "CURRENT";
const manifest_prefix = "MANIFEST-";
const manifest_version: u16 = 7;
const wal_record_version: u16 = 1;
const max_entries: usize = 4096;
const max_path_bytes: u32 = 64 * 1024;
const max_current_bytes: u64 = 128;
const max_manifest_file_bytes: u64 = 16 * 1024 * 1024;
const max_wal_tail_records: usize = 1_000_000;
const wal_read_chunk_bytes: usize = 64 * 1024;

const ManifestHeader = struct {
    const magic = [_]u8{ 'T', 'K', 'M', 'F' };
    const encoded_len: usize = 56;
};

const EntryHeader = struct {
    const encoded_len: usize = 12;

    kind: SegmentKind,
    path_len: u32,
    generation: u64,
    node_count: u64,
    edge_count: u64,
    node_digest: u64,
    node_range: IdRange,
    edge_range: IdRange,
    segment_digest: u64,
    hotness_hint: u32,
    metadata_flags: u32,
    node_catalog_summary: ?segment_catalog_summary.CatalogSummary,
};

const entry_metadata_node_catalog_summary: u32 = 1 << 0;
const entry_metadata_node_count_explicit: u32 = 1 << 1;
const entry_metadata_edge_count_explicit: u32 = 1 << 2;
const entry_metadata_node_range_explicit: u32 = 1 << 3;
const entry_metadata_edge_range_explicit: u32 = 1 << 4;
const entry_metadata_node_digest_explicit: u32 = 1 << 5;
const entry_metadata_segment_digest_explicit: u32 = 1 << 6;
const entry_metadata_generation_explicit: u32 = 1 << 7;
const entry_metadata_hotness_explicit: u32 = 1 << 8;
const entry_metadata_known_flags: u32 =
    entry_metadata_node_catalog_summary |
    entry_metadata_node_count_explicit |
    entry_metadata_edge_count_explicit |
    entry_metadata_node_range_explicit |
    entry_metadata_edge_range_explicit |
    entry_metadata_node_digest_explicit |
    entry_metadata_segment_digest_explicit |
    entry_metadata_generation_explicit |
    entry_metadata_hotness_explicit;
const entry_node_catalog_summary_extra_len: usize = 40;

const WalRecordHeader = struct {
    const magic = [_]u8{ 'T', 'K', 'W', 'R' };
    const encoded_len: usize = 24;
    const max_payload_len: u32 = 64 * 1024 * 1024;
};

pub fn appendWalRecord(io: std.Io, wal_path: []const u8, kind: WalRecordKind, payload: []const u8) !u64 {
    if (payload.len > WalRecordHeader.max_payload_len) return error.RecordTooLarge;
    var file = try std.Io.Dir.cwd().openFile(io, wal_path, .{ .mode = .read_write, .allow_directory = false });
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.kind != .file) return error.InvalidRecord;
    const offset = stat.size;
    const next_offset = try std.math.add(u64, offset, WalRecordHeader.encoded_len + payload.len);
    var header: [WalRecordHeader.encoded_len]u8 = undefined;
    encodeWalRecordHeader(&header, kind, @intCast(payload.len), std.hash.Wyhash.hash(0, payload));
    try file.writePositionalAll(io, &header, offset);
    try file.writePositionalAll(io, payload, offset + WalRecordHeader.encoded_len);
    try file.sync(io);
    return next_offset;
}

fn readWalTailReplayPlan(allocator: std.mem.Allocator, io: std.Io, wal_path: []const u8, snapshot: Snapshot) !WalTailReplayPlan {
    var plan = WalTailReplayPlan{
        .snapshot = snapshot,
        .checkpoint_bytes = snapshot.wal_checkpoint_bytes,
        .end_bytes = 0,
    };
    errdefer plan.deinit(allocator);

    var file = try std.Io.Dir.cwd().openFile(io, wal_path, .{ .allow_directory = false });
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.kind != .file) return error.InvalidRecord;
    if (plan.checkpoint_bytes > stat.size) return error.InvalidRecord;
    plan.end_bytes = stat.size;

    var offset = plan.checkpoint_bytes;
    while (offset < stat.size) {
        if (plan.records.items.len >= max_wal_tail_records) return error.RecordTooLarge;
        if (stat.size - offset < WalRecordHeader.encoded_len) return error.InvalidRecord;
        var header_bytes: [WalRecordHeader.encoded_len]u8 = undefined;
        if (try file.readPositionalAll(io, &header_bytes, offset) != header_bytes.len) return error.InvalidRecord;
        const header = try decodeWalRecordHeader(&header_bytes);
        const payload_offset = try std.math.add(u64, offset, WalRecordHeader.encoded_len);
        const next_offset = try std.math.add(u64, payload_offset, header.payload_len);
        if (next_offset > stat.size) return error.InvalidRecord;
        const digest = try walPayloadDigest(io, file, payload_offset, header.payload_len);
        if (digest != header.payload_digest) return error.InvalidRecord;
        try plan.records.append(allocator, .{
            .kind = header.kind,
            .offset = offset,
            .payload_offset = payload_offset,
            .payload_len = header.payload_len,
            .payload_digest = digest,
            .next_offset = next_offset,
        });
        offset = next_offset;
    }

    return plan;
}

fn encodeWalRecordHeader(out: *[WalRecordHeader.encoded_len]u8, kind: WalRecordKind, payload_len: u32, payload_digest: u64) void {
    @memset(out, 0);
    @memcpy(out[0..4], &WalRecordHeader.magic);
    std.mem.writeInt(u16, out[4..6], wal_record_version, .little);
    std.mem.writeInt(u16, out[6..8], WalRecordHeader.encoded_len, .little);
    std.mem.writeInt(u16, out[8..10], @intFromEnum(kind), .little);
    std.mem.writeInt(u32, out[12..16], payload_len, .little);
    std.mem.writeInt(u64, out[16..24], payload_digest, .little);
}

fn decodeWalRecordHeader(bytes: *const [WalRecordHeader.encoded_len]u8) !struct {
    kind: WalRecordKind,
    payload_len: u32,
    payload_digest: u64,
} {
    if (!std.mem.eql(u8, bytes[0..4], &WalRecordHeader.magic)) return error.InvalidRecord;
    if (std.mem.readInt(u16, bytes[4..6], .little) != wal_record_version) return error.InvalidRecord;
    if (std.mem.readInt(u16, bytes[6..8], .little) != WalRecordHeader.encoded_len) return error.InvalidRecord;
    const kind = walKindFromInt(std.mem.readInt(u16, bytes[8..10], .little)) orelse return error.InvalidRecord;
    if (std.mem.readInt(u16, bytes[10..12], .little) != 0) return error.InvalidRecord;
    const payload_len = std.mem.readInt(u32, bytes[12..16], .little);
    if (payload_len > WalRecordHeader.max_payload_len) return error.InvalidRecord;
    return .{
        .kind = kind,
        .payload_len = payload_len,
        .payload_digest = std.mem.readInt(u64, bytes[16..24], .little),
    };
}

fn walPayloadDigest(io: std.Io, file: std.Io.File, payload_offset: u64, payload_len: u32) !u64 {
    var hasher = std.hash.Wyhash.init(0);
    var remaining: u64 = payload_len;
    var offset = payload_offset;
    var buffer: [wal_read_chunk_bytes]u8 = undefined;
    while (remaining > 0) {
        const chunk_len: usize = @intCast(@min(remaining, @as(u64, wal_read_chunk_bytes)));
        if (try file.readPositionalAll(io, buffer[0..chunk_len], offset) != chunk_len) return error.InvalidRecord;
        hasher.update(buffer[0..chunk_len]);
        offset = try std.math.add(u64, offset, chunk_len);
        remaining -= chunk_len;
    }
    return hasher.final();
}

fn encodeManifest(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    generation: u64,
    wal_checkpoint_bytes: u64,
    entries: []const Entry,
) !void {
    try validateEntries(generation, entries);
    try out.ensureTotalCapacity(allocator, ManifestHeader.encoded_len + entries.len * EntryHeader.encoded_len);
    const digest = manifestEntriesDigest(entries);
    var header: [ManifestHeader.encoded_len]u8 = undefined;
    @memcpy(header[0..4], &ManifestHeader.magic);
    std.mem.writeInt(u16, header[4..6], manifest_version, .little);
    std.mem.writeInt(u16, header[6..8], ManifestHeader.encoded_len, .little);
    std.mem.writeInt(u64, header[8..16], generation, .little);
    std.mem.writeInt(u64, header[16..24], wal_checkpoint_bytes, .little);
    std.mem.writeInt(u64, header[24..32], entries.len, .little);
    std.mem.writeInt(u64, header[32..40], digest, .little);
    @memset(header[40..56], 0);
    try out.appendSlice(allocator, &header);

    var entry_header: [EntryHeader.encoded_len]u8 = undefined;
    for (entries) |entry| {
        encodeEntryHeader(generation, entry, &entry_header);
        try out.appendSlice(allocator, &entry_header);
        try encodeEntryCommonExtras(allocator, out, generation, entry);
        try encodeEntryNodeCatalogSummaryExtra(allocator, out, entry);
        try encodeEntryRangeExtras(allocator, out, entry);
        try encodeEntryDigestExtras(allocator, out, entry);
        try encodeEntryCountExtras(allocator, out, entry);
        try out.appendSlice(allocator, entry.path);
    }
}

fn decodeManifest(allocator: std.mem.Allocator, path: []const u8, bytes: []const u8) !Snapshot {
    if (bytes.len < ManifestHeader.encoded_len) return error.InvalidRecord;
    if (!std.mem.eql(u8, bytes[0..4], &ManifestHeader.magic)) return error.InvalidRecord;
    if (std.mem.readInt(u16, bytes[4..6], .little) != manifest_version) return error.InvalidRecord;
    if (std.mem.readInt(u16, bytes[6..8], .little) != ManifestHeader.encoded_len) return error.InvalidRecord;
    const generation = std.mem.readInt(u64, bytes[8..16], .little);
    if (generation == 0) return error.InvalidRecord;
    const wal_checkpoint_bytes = std.mem.readInt(u64, bytes[16..24], .little);
    const entry_count = std.mem.readInt(u64, bytes[24..32], .little);
    if (entry_count > max_entries) return error.InvalidRecord;
    const expected_digest = std.mem.readInt(u64, bytes[32..40], .little);
    for (bytes[40..56]) |byte| {
        if (byte != 0) return error.InvalidRecord;
    }

    var snapshot = Snapshot{
        .generation = generation,
        .wal_checkpoint_bytes = wal_checkpoint_bytes,
        .manifest_path = try allocator.dupe(u8, path),
    };
    errdefer snapshot.deinit(allocator);
    try snapshot.entries.ensureTotalCapacity(allocator, @intCast(entry_count));

    var digest_hasher = std.hash.Wyhash.init(0x544B_4D46);
    var offset: usize = ManifestHeader.encoded_len;
    var pos: u64 = 0;
    while (pos < entry_count) : (pos += 1) {
        if (offset > bytes.len or bytes.len - offset < EntryHeader.encoded_len) return error.InvalidRecord;
        var header = try decodeEntryHeader(generation, bytes[offset .. offset + EntryHeader.encoded_len]);
        offset += EntryHeader.encoded_len;
        const common = try decodeEntryCommonExtras(bytes, &offset, header.metadata_flags, generation);
        header.generation = common.generation;
        header.hotness_hint = common.hotness_hint;
        header.node_catalog_summary = try decodeEntryNodeCatalogSummaryExtra(bytes, &offset, header.metadata_flags);
        const ranges = try decodeEntryRangeExtras(bytes, &offset, header.metadata_flags);
        const digests = try decodeEntryDigestExtras(bytes, &offset, header.metadata_flags);
        header.node_range = ranges.node_range;
        header.edge_range = ranges.edge_range;
        header.node_digest = digests.node_digest;
        header.segment_digest = digests.segment_digest;
        const counts = try decodeEntryCountExtras(bytes, &offset, header);
        if (header.path_len == 0 or header.path_len > max_path_bytes) return error.InvalidRecord;
        const path_len = std.math.cast(usize, header.path_len) orelse return error.RecordTooLarge;
        if (offset > bytes.len or bytes.len - offset < path_len) return error.InvalidRecord;
        const entry_path = try allocator.dupe(u8, bytes[offset .. offset + path_len]);
        errdefer allocator.free(entry_path);
        offset += path_len;
        const entry = OwnedEntry{
            .kind = header.kind,
            .generation = header.generation,
            .node_count = counts.node_count,
            .edge_count = counts.edge_count,
            .node_digest = header.node_digest,
            .node_range = header.node_range,
            .edge_range = header.edge_range,
            .segment_digest = header.segment_digest,
            .hotness_hint = header.hotness_hint,
            .node_catalog_summary = if (header.node_catalog_summary) |summary| .{
                .node_count = counts.node_count,
                .node_id_base = summary.node_id_base,
                .texts_bytes = summary.texts_bytes,
                .texts_digest = summary.texts_digest,
                .nodes_record_digest = summary.nodes_record_digest,
                .exact_record_digest = summary.exact_record_digest,
            } else null,
            .path = entry_path,
        };
        try validateEntry(generation, entry.asEntry());
        updateEntryDigest(&digest_hasher, entry.asEntry());
        snapshot.entries.appendAssumeCapacity(entry);
    }
    if (offset != bytes.len) return error.InvalidRecord;
    if (digest_hasher.final() != expected_digest) return error.InvalidRecord;
    return snapshot;
}

fn encodeEntryHeader(manifest_generation: u64, entry: Entry, out: *[EntryHeader.encoded_len]u8) void {
    @memset(out, 0);
    std.mem.writeInt(u16, out[0..2], @intFromEnum(entry.kind), .little);
    std.mem.writeInt(u32, out[4..8], @intCast(entry.path.len), .little);
    var flags: u32 = 0;
    if (entry.node_catalog_summary != null) flags |= entry_metadata_node_catalog_summary;
    if (!entryRangeEmpty(entry.node_range)) flags |= entry_metadata_node_range_explicit;
    if (!entryRangeEmpty(entry.edge_range)) flags |= entry_metadata_edge_range_explicit;
    if (entry.node_digest != 0) flags |= entry_metadata_node_digest_explicit;
    if (entry.segment_digest != 0) flags |= entry_metadata_segment_digest_explicit;
    if (!entryCountDerivable(entry.node_count, entry.node_range)) flags |= entry_metadata_node_count_explicit;
    if (!entryCountDerivable(entry.edge_count, entry.edge_range)) flags |= entry_metadata_edge_count_explicit;
    if (entry.generation != manifest_generation) flags |= entry_metadata_generation_explicit;
    if (entry.hotness_hint != 0) flags |= entry_metadata_hotness_explicit;
    std.mem.writeInt(u32, out[8..12], flags, .little);
}

fn decodeEntryHeader(manifest_generation: u64, bytes: []const u8) !EntryHeader {
    if (bytes.len != EntryHeader.encoded_len) return error.InvalidRecord;
    if (std.mem.readInt(u16, bytes[2..4], .little) != 0) return error.InvalidRecord;
    const metadata_flags = std.mem.readInt(u32, bytes[8..12], .little);
    if ((metadata_flags & ~entry_metadata_known_flags) != 0) return error.InvalidRecord;
    const kind = kindFromInt(std.mem.readInt(u16, bytes[0..2], .little)) orelse return error.InvalidRecord;
    return .{
        .kind = kind,
        .path_len = std.mem.readInt(u32, bytes[4..8], .little),
        .generation = manifest_generation,
        .node_count = 0,
        .edge_count = 0,
        .node_digest = 0,
        .node_range = .{},
        .edge_range = .{},
        .segment_digest = 0,
        .hotness_hint = 0,
        .metadata_flags = metadata_flags,
        .node_catalog_summary = null,
    };
}

fn encodeEntryCommonExtras(allocator: std.mem.Allocator, out: *std.ArrayList(u8), manifest_generation: u64, entry: Entry) !void {
    var generation_bytes: [8]u8 = undefined;
    if (entry.generation != manifest_generation) {
        std.mem.writeInt(u64, &generation_bytes, entry.generation, .little);
        try out.appendSlice(allocator, &generation_bytes);
    }
    var hotness_bytes: [4]u8 = undefined;
    if (entry.hotness_hint != 0) {
        std.mem.writeInt(u32, &hotness_bytes, entry.hotness_hint, .little);
        try out.appendSlice(allocator, &hotness_bytes);
    }
}

fn decodeEntryCommonExtras(bytes: []const u8, offset: *usize, flags: u32, manifest_generation: u64) !struct { generation: u64, hotness_hint: u32 } {
    var generation = manifest_generation;
    if ((flags & entry_metadata_generation_explicit) != 0) {
        if (offset.* > bytes.len or bytes.len - offset.* < 8) return error.InvalidRecord;
        generation = std.mem.readInt(u64, bytes[offset.*..][0..8], .little);
        offset.* += 8;
        if (generation == 0 or generation == manifest_generation) return error.InvalidRecord;
    }
    var hotness_hint: u32 = 0;
    if ((flags & entry_metadata_hotness_explicit) != 0) {
        if (offset.* > bytes.len or bytes.len - offset.* < 4) return error.InvalidRecord;
        hotness_hint = std.mem.readInt(u32, bytes[offset.*..][0..4], .little);
        offset.* += 4;
        if (hotness_hint == 0) return error.InvalidRecord;
    }
    return .{ .generation = generation, .hotness_hint = hotness_hint };
}

fn encodeEntryNodeCatalogSummaryExtra(allocator: std.mem.Allocator, out: *std.ArrayList(u8), entry: Entry) !void {
    const summary = entry.node_catalog_summary orelse return;
    var bytes: [entry_node_catalog_summary_extra_len]u8 = undefined;
    std.mem.writeInt(u64, bytes[0..8], summary.node_id_base, .little);
    std.mem.writeInt(u64, bytes[8..16], summary.texts_bytes, .little);
    std.mem.writeInt(u64, bytes[16..24], summary.texts_digest, .little);
    std.mem.writeInt(u64, bytes[24..32], summary.nodes_record_digest, .little);
    std.mem.writeInt(u64, bytes[32..40], summary.exact_record_digest, .little);
    try out.appendSlice(allocator, &bytes);
}

fn decodeEntryNodeCatalogSummaryExtra(bytes: []const u8, offset: *usize, flags: u32) !?segment_catalog_summary.CatalogSummary {
    if ((flags & entry_metadata_node_catalog_summary) == 0) return null;
    if (offset.* > bytes.len or bytes.len - offset.* < entry_node_catalog_summary_extra_len) return error.InvalidRecord;
    const base = offset.*;
    const summary = segment_catalog_summary.CatalogSummary{
        .node_count = 0,
        .node_id_base = std.mem.readInt(u64, bytes[base..][0..8], .little),
        .texts_bytes = std.mem.readInt(u64, bytes[base + 8 ..][0..8], .little),
        .texts_digest = std.mem.readInt(u64, bytes[base + 16 ..][0..8], .little),
        .nodes_record_digest = std.mem.readInt(u64, bytes[base + 24 ..][0..8], .little),
        .exact_record_digest = std.mem.readInt(u64, bytes[base + 32 ..][0..8], .little),
    };
    offset.* += entry_node_catalog_summary_extra_len;
    return summary;
}

fn encodeEntryRangeExtras(allocator: std.mem.Allocator, out: *std.ArrayList(u8), entry: Entry) !void {
    var bytes: [16]u8 = undefined;
    if (!entryRangeEmpty(entry.node_range)) {
        encodeEntryRangeExtra(entry.node_range, &bytes);
        try out.appendSlice(allocator, &bytes);
    }
    if (!entryRangeEmpty(entry.edge_range)) {
        encodeEntryRangeExtra(entry.edge_range, &bytes);
        try out.appendSlice(allocator, &bytes);
    }
}

fn decodeEntryRangeExtras(bytes: []const u8, offset: *usize, flags: u32) !struct { node_range: IdRange, edge_range: IdRange } {
    const node_range = try decodeEntryRangeExtra(bytes, offset, flags, entry_metadata_node_range_explicit);
    const edge_range = try decodeEntryRangeExtra(bytes, offset, flags, entry_metadata_edge_range_explicit);
    return .{ .node_range = node_range, .edge_range = edge_range };
}

fn encodeEntryRangeExtra(range: IdRange, out: *[16]u8) void {
    std.mem.writeInt(u64, out[0..8], range.min, .little);
    std.mem.writeInt(u64, out[8..16], range.max, .little);
}

fn decodeEntryRangeExtra(bytes: []const u8, offset: *usize, flags: u32, explicit_flag: u32) !IdRange {
    if ((flags & explicit_flag) == 0) return .{};
    if (offset.* > bytes.len or bytes.len - offset.* < 16) return error.InvalidRecord;
    const range = IdRange{
        .min = std.mem.readInt(u64, bytes[offset.* .. offset.* + 8][0..8], .little),
        .max = std.mem.readInt(u64, bytes[offset.* + 8 .. offset.* + 16][0..8], .little),
    };
    offset.* += 16;
    if (entryRangeEmpty(range)) return error.InvalidRecord;
    _ = try entryRangeCount(range);
    return range;
}

fn encodeEntryDigestExtras(allocator: std.mem.Allocator, out: *std.ArrayList(u8), entry: Entry) !void {
    var bytes: [8]u8 = undefined;
    if (entry.node_digest != 0) {
        std.mem.writeInt(u64, &bytes, entry.node_digest, .little);
        try out.appendSlice(allocator, &bytes);
    }
    if (entry.segment_digest != 0) {
        std.mem.writeInt(u64, &bytes, entry.segment_digest, .little);
        try out.appendSlice(allocator, &bytes);
    }
}

fn decodeEntryDigestExtras(bytes: []const u8, offset: *usize, flags: u32) !struct { node_digest: u64, segment_digest: u64 } {
    const node_digest = try decodeEntryDigestExtra(bytes, offset, flags, entry_metadata_node_digest_explicit);
    const segment_digest = try decodeEntryDigestExtra(bytes, offset, flags, entry_metadata_segment_digest_explicit);
    return .{ .node_digest = node_digest, .segment_digest = segment_digest };
}

fn decodeEntryDigestExtra(bytes: []const u8, offset: *usize, flags: u32, explicit_flag: u32) !u64 {
    if ((flags & explicit_flag) == 0) return 0;
    if (offset.* > bytes.len or bytes.len - offset.* < 8) return error.InvalidRecord;
    const digest = std.mem.readInt(u64, bytes[offset.* .. offset.* + 8][0..8], .little);
    offset.* += 8;
    if (digest == 0) return error.InvalidRecord;
    return digest;
}

fn encodeEntryCountExtras(allocator: std.mem.Allocator, out: *std.ArrayList(u8), entry: Entry) !void {
    var bytes: [8]u8 = undefined;
    if (!entryCountDerivable(entry.node_count, entry.node_range)) {
        std.mem.writeInt(u64, &bytes, entry.node_count, .little);
        try out.appendSlice(allocator, &bytes);
    }
    if (!entryCountDerivable(entry.edge_count, entry.edge_range)) {
        std.mem.writeInt(u64, &bytes, entry.edge_count, .little);
        try out.appendSlice(allocator, &bytes);
    }
}

fn decodeEntryCountExtras(bytes: []const u8, offset: *usize, header: EntryHeader) !struct { node_count: u64, edge_count: u64 } {
    const node_count = try decodeEntryCountExtra(bytes, offset, header.metadata_flags, entry_metadata_node_count_explicit, header.node_range);
    const edge_count = try decodeEntryCountExtra(bytes, offset, header.metadata_flags, entry_metadata_edge_count_explicit, header.edge_range);
    return .{ .node_count = node_count, .edge_count = edge_count };
}

fn decodeEntryCountExtra(bytes: []const u8, offset: *usize, flags: u32, explicit_flag: u32, range: IdRange) !u64 {
    const derived = try entryRangeCount(range);
    if ((flags & explicit_flag) == 0) return derived;
    if (offset.* > bytes.len or bytes.len - offset.* < 8) return error.InvalidRecord;
    const count = std.mem.readInt(u64, bytes[offset.* .. offset.* + 8][0..8], .little);
    offset.* += 8;
    if (count == 0 or count == derived) return error.InvalidRecord;
    return count;
}

fn entryCountDerivable(count: u64, range: IdRange) bool {
    return count == (entryRangeCount(range) catch return false);
}

fn entryRangeEmpty(range: IdRange) bool {
    return range.min == 0 and range.max == 0;
}

fn entryRangeCount(range: IdRange) !u64 {
    if (range.min == 0 and range.max == 0) return 0;
    if (range.min == 0 or range.max == 0 or range.min > range.max) return error.InvalidRecord;
    if (range.max == std.math.maxInt(u64)) return error.InvalidRecord;
    return std.math.add(u64, range.max - range.min, 1) catch return error.InvalidRecord;
}

fn validateEntries(manifest_generation: u64, entries: []const Entry) !void {
    if (manifest_generation == 0) return error.InvalidRecord;
    if (entries.len > max_entries) return error.InvalidRecord;
    for (entries) |entry| try validateEntry(manifest_generation, entry);
}

fn validateEntry(manifest_generation: u64, entry: Entry) !void {
    if (entry.generation == 0 or entry.generation > manifest_generation) return error.InvalidRecord;
    if (entry.path.len == 0 or entry.path.len > max_path_bytes) return error.InvalidRecord;
    if (!safeRelativePath(entry.path)) return error.InvalidRecord;
    try validateRange(entry.node_count, entry.node_range);
    try validateRange(entry.edge_count, entry.edge_range);
    if (entry.node_digest != 0 and entry.kind != .node) return error.InvalidRecord;
    if (entry.node_catalog_summary) |summary| {
        if (entry.kind != .node) return error.InvalidRecord;
        try summary.validate();
        if (entry.node_count != summary.node_count) return error.InvalidRecord;
        if (summary.node_id_base != 0 and summary.node_id_base != entry.node_range.min) return error.InvalidRecord;
    }
}

fn validateRange(count: u64, range: IdRange) !void {
    if (count == 0) {
        if (range.min != 0 or range.max != 0) return error.InvalidRecord;
        return;
    }
    if (range.min == 0 or range.max == 0 or range.min > range.max) return error.InvalidRecord;
    if (range.min == std.math.maxInt(u64) or range.max == std.math.maxInt(u64)) return error.InvalidRecord;
}

pub fn safeRelativePath(path: []const u8) bool {
    if (std.fs.path.isAbsolute(path)) return false;
    if (std.mem.indexOfScalar(u8, path, 0) != null) return false;
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |part| {
        if (part.len == 0) return false;
        if (std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    }
    return true;
}

fn manifestEntriesDigest(entries: []const Entry) u64 {
    var hasher = std.hash.Wyhash.init(0x544B_4D46);
    for (entries) |entry| updateEntryDigest(&hasher, entry);
    return hasher.final();
}

fn updateEntryDigest(hasher: *std.hash.Wyhash, entry: Entry) void {
    var bytes: [8]u8 = undefined;
    var small: [4]u8 = undefined;
    std.mem.writeInt(u16, small[0..2], @intFromEnum(entry.kind), .little);
    hasher.update(small[0..2]);
    std.mem.writeInt(u64, &bytes, entry.generation, .little);
    hasher.update(&bytes);
    std.mem.writeInt(u64, &bytes, entry.node_count, .little);
    hasher.update(&bytes);
    std.mem.writeInt(u64, &bytes, entry.edge_count, .little);
    hasher.update(&bytes);
    std.mem.writeInt(u64, &bytes, entry.node_digest, .little);
    hasher.update(&bytes);
    std.mem.writeInt(u64, &bytes, entry.node_range.min, .little);
    hasher.update(&bytes);
    std.mem.writeInt(u64, &bytes, entry.node_range.max, .little);
    hasher.update(&bytes);
    std.mem.writeInt(u64, &bytes, entry.edge_range.min, .little);
    hasher.update(&bytes);
    std.mem.writeInt(u64, &bytes, entry.edge_range.max, .little);
    hasher.update(&bytes);
    std.mem.writeInt(u64, &bytes, entry.segment_digest, .little);
    hasher.update(&bytes);
    std.mem.writeInt(u32, &small, entry.hotness_hint, .little);
    hasher.update(&small);
    const metadata_flags: u32 = if (entry.node_catalog_summary != null) entry_metadata_node_catalog_summary else 0;
    std.mem.writeInt(u32, &small, metadata_flags, .little);
    hasher.update(&small);
    const summary = entry.node_catalog_summary orelse segment_catalog_summary.CatalogSummary{
        .node_count = 0,
        .node_id_base = 0,
        .texts_bytes = 0,
        .texts_digest = 0,
        .nodes_record_digest = 0,
        .exact_record_digest = 0,
    };
    std.mem.writeInt(u64, &bytes, summary.node_id_base, .little);
    hasher.update(&bytes);
    std.mem.writeInt(u64, &bytes, summary.texts_bytes, .little);
    hasher.update(&bytes);
    std.mem.writeInt(u64, &bytes, summary.texts_digest, .little);
    hasher.update(&bytes);
    std.mem.writeInt(u64, &bytes, summary.nodes_record_digest, .little);
    hasher.update(&bytes);
    std.mem.writeInt(u64, &bytes, summary.exact_record_digest, .little);
    hasher.update(&bytes);
    hasher.update(entry.path);
}

fn kindFromInt(value: u16) ?SegmentKind {
    inline for (@typeInfo(SegmentKind).@"enum".fields) |field| {
        if (field.value == value) return @enumFromInt(value);
    }
    return null;
}

fn walKindFromInt(value: u16) ?WalRecordKind {
    inline for (@typeInfo(WalRecordKind).@"enum".fields) |field| {
        if (field.value == value) return @enumFromInt(value);
    }
    return null;
}

fn manifestLeaf(allocator: std.mem.Allocator, generation: u64) ![]u8 {
    if (generation == 0) return error.InvalidRecord;
    return std.fmt.allocPrint(allocator, "{s}{d}", .{ manifest_prefix, generation });
}

fn parseManifestLeaf(leaf: []const u8) ?u64 {
    if (!std.mem.startsWith(u8, leaf, manifest_prefix)) return null;
    const raw = leaf[manifest_prefix.len..];
    if (raw.len == 0) return null;
    for (raw) |byte| {
        if (byte < '0' or byte > '9') return null;
    }
    const generation = std.fmt.parseUnsigned(u64, raw, 10) catch return null;
    return if (generation == 0) null else generation;
}

fn snapshotPinned(generation: u64, pinned: []const Snapshot) bool {
    for (pinned) |snapshot| {
        if (snapshot.generation == generation) return true;
    }
    return false;
}

fn tmpPath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
}

fn renameReplace(io: std.Io, tmp_path: []const u8, final_path: []const u8) !void {
    if (std.fs.path.isAbsolute(final_path)) {
        try std.Io.Dir.renameAbsolute(tmp_path, final_path, io);
    } else {
        try std.Io.Dir.rename(.cwd(), tmp_path, .cwd(), final_path, io);
    }
}

test "segment manifest publishes current snapshots and preserves pinned generations during gc" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const manifest_dir = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "manifest" });
    defer std.testing.allocator.free(manifest_dir);

    var store = try Store.init(std.testing.allocator, std.testing.io, manifest_dir);
    defer store.deinit();

    const gen1 = try store.publish(128, &.{
        .{
            .kind = .edge,
            .generation = 1,
            .edge_count = 10,
            .edge_range = .{ .min = 1, .max = 10 },
            .segment_digest = 0x10,
            .path = "segments/edge-s000001",
        },
    });
    try std.testing.expectEqual(@as(u64, 1), gen1);

    var pinned = try store.pinCurrent();
    defer pinned.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 1), pinned.generation);
    try std.testing.expectEqual(@as(u64, 10), try pinned.totalEdges());

    const gen2 = try store.publish(256, &.{
        .{
            .kind = .edge,
            .generation = 2,
            .edge_count = 20,
            .edge_range = .{ .min = 11, .max = 30 },
            .segment_digest = 0x20,
            .path = "segments/edge-s000002",
        },
    });
    try std.testing.expectEqual(@as(u64, 2), gen2);

    const kept = try store.gcUnpinned(&.{pinned});
    try std.testing.expectEqual(@as(u64, 0), kept.deleted_manifests);

    const old_leaf = try manifestLeaf(std.testing.allocator, 1);
    defer std.testing.allocator.free(old_leaf);
    const old_path = try std.fs.path.join(std.testing.allocator, &.{ manifest_dir, old_leaf });
    defer std.testing.allocator.free(old_path);
    try std.testing.expectEqual(.file, (try std.Io.Dir.cwd().statFile(std.testing.io, old_path, .{})).kind);

    const deleted = try store.gcUnpinned(&.{});
    try std.testing.expectEqual(@as(u64, 1), deleted.deleted_manifests);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(std.testing.io, old_path, .{}));

    var current = try store.pinCurrent();
    defer current.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 2), current.generation);
    try std.testing.expectEqual(@as(u64, 256), current.wal_checkpoint_bytes);
}

test "segment manifest rejects unexpected publish generation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const manifest_dir = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "manifest" });
    defer std.testing.allocator.free(manifest_dir);

    var store = try Store.init(std.testing.allocator, std.testing.io, manifest_dir);
    defer store.deinit();

    try std.testing.expectError(error.InvalidRecord, store.publishExpectedGeneration(2, 0, &.{
        .{
            .kind = .edge,
            .generation = 2,
            .edge_count = 1,
            .edge_range = .{ .min = 1, .max = 1 },
            .segment_digest = 0x10,
            .path = "segments/edge-s000002",
        },
    }));

    try store.publishExpectedGeneration(1, 128, &.{
        .{
            .kind = .edge,
            .generation = 1,
            .edge_count = 1,
            .edge_range = .{ .min = 1, .max = 1 },
            .segment_digest = 0x10,
            .path = "segments/edge-s000001",
        },
    });

    try std.testing.expectError(error.InvalidRecord, store.publishExpectedGeneration(1, 256, &.{
        .{
            .kind = .edge,
            .generation = 1,
            .edge_count = 1,
            .edge_range = .{ .min = 2, .max = 2 },
            .segment_digest = 0x20,
            .path = "segments/edge-s000001-again",
        },
    }));
}

test "segment manifest stores node catalog summary metadata" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const manifest_dir = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "manifest" });
    defer std.testing.allocator.free(manifest_dir);

    var store = try Store.init(std.testing.allocator, std.testing.io, manifest_dir);
    defer store.deinit();

    const summary = segment_catalog_summary.CatalogSummary{
        .node_count = 3,
        .texts_bytes = 27,
        .texts_digest = 0xabc1,
        .nodes_record_digest = 0xabc2,
        .exact_record_digest = 0xabc3,
    };
    const node_path = "segments/node-s000001";
    _ = try store.publish(512, &.{
        .{
            .kind = .node,
            .generation = 1,
            .node_count = 3,
            .node_range = .{ .min = 10, .max = 12 },
            .segment_digest = 0x30,
            .node_catalog_summary = summary,
            .path = node_path,
        },
    });

    const leaf = try manifestLeaf(std.testing.allocator, 1);
    defer std.testing.allocator.free(leaf);
    const manifest_path = try std.fs.path.join(std.testing.allocator, &.{ manifest_dir, leaf });
    defer std.testing.allocator.free(manifest_path);
    const manifest_size = (try std.Io.Dir.cwd().statFile(std.testing.io, manifest_path, .{})).size;
    try std.testing.expectEqual(
        @as(u64, ManifestHeader.encoded_len + EntryHeader.encoded_len + entry_node_catalog_summary_extra_len + 16 + 8 + node_path.len),
        manifest_size,
    );

    var snapshot = try store.pinCurrent();
    defer snapshot.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), snapshot.entries.items.len);
    try std.testing.expect(snapshot.entries.items[0].node_catalog_summary != null);
    try std.testing.expectEqual(summary, snapshot.entries.items[0].node_catalog_summary.?);
}

test "segment manifest derives dense counts and stores sparse count extras" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const manifest_dir = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "manifest" });
    defer std.testing.allocator.free(manifest_dir);

    var store = try Store.init(std.testing.allocator, std.testing.io, manifest_dir);
    defer store.deinit();

    const node_path = "segments/node-s000001";
    const edge_path = "segments/edge-s000001";
    _ = try store.publish(512, &.{
        .{
            .kind = .node,
            .generation = 1,
            .node_count = 3,
            .node_range = .{ .min = 10, .max = 12 },
            .path = node_path,
        },
        .{
            .kind = .edge,
            .generation = 1,
            .edge_count = 3,
            .edge_range = .{ .min = 10, .max = 30 },
            .path = edge_path,
        },
    });

    const leaf = try manifestLeaf(std.testing.allocator, 1);
    defer std.testing.allocator.free(leaf);
    const manifest_path = try std.fs.path.join(std.testing.allocator, &.{ manifest_dir, leaf });
    defer std.testing.allocator.free(manifest_path);
    const manifest_size = (try std.Io.Dir.cwd().statFile(std.testing.io, manifest_path, .{})).size;
    try std.testing.expectEqual(
        @as(u64, ManifestHeader.encoded_len + EntryHeader.encoded_len + 16 + node_path.len + EntryHeader.encoded_len + 16 + 8 + edge_path.len),
        manifest_size,
    );

    var snapshot = try store.pinCurrent();
    defer snapshot.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), snapshot.entries.items.len);
    try std.testing.expectEqual(@as(u64, 3), snapshot.entries.items[0].node_count);
    try std.testing.expectEqual(@as(u64, 3), snapshot.entries.items[1].edge_count);
}

test "segment manifest stores explicit generation and hotness extras only for exceptions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const manifest_dir = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "manifest" });
    defer std.testing.allocator.free(manifest_dir);

    var store = try Store.init(std.testing.allocator, std.testing.io, manifest_dir);
    defer store.deinit();

    _ = try store.publish(128, &.{
        .{
            .kind = .edge,
            .generation = 1,
            .edge_count = 1,
            .edge_range = .{ .min = 1, .max = 1 },
            .path = "segments/edge-s000001",
        },
    });

    const edge_path = "segments/edge-s000001";
    try store.publishExpectedGeneration(2, 256, &.{
        .{
            .kind = .edge,
            .generation = 1,
            .edge_count = 1,
            .edge_range = .{ .min = 1, .max = 1 },
            .segment_digest = 0x20,
            .hotness_hint = 7,
            .path = edge_path,
        },
    });

    const leaf = try manifestLeaf(std.testing.allocator, 2);
    defer std.testing.allocator.free(leaf);
    const manifest_path = try std.fs.path.join(std.testing.allocator, &.{ manifest_dir, leaf });
    defer std.testing.allocator.free(manifest_path);
    const manifest_size = (try std.Io.Dir.cwd().statFile(std.testing.io, manifest_path, .{})).size;
    try std.testing.expectEqual(
        @as(u64, ManifestHeader.encoded_len + EntryHeader.encoded_len + 8 + 4 + 16 + 8 + edge_path.len),
        manifest_size,
    );

    var snapshot = try store.pinCurrent();
    defer snapshot.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 2), snapshot.generation);
    try std.testing.expectEqual(@as(u64, 1), snapshot.entries.items[0].generation);
    try std.testing.expectEqual(@as(u32, 7), snapshot.entries.items[0].hotness_hint);
}

test "segment manifest rejects redundant explicit count extras" {
    const entry = Entry{
        .kind = .edge,
        .generation = 1,
        .edge_count = 3,
        .edge_range = .{ .min = 10, .max = 12 },
        .path = "segments/edge-s000001",
    };
    var encoded: [EntryHeader.encoded_len]u8 = undefined;
    encodeEntryHeader(1, entry, &encoded);
    const flags = std.mem.readInt(u32, encoded[8..12], .little) | entry_metadata_edge_count_explicit;
    std.mem.writeInt(u32, encoded[8..12], flags, .little);
    var header = try decodeEntryHeader(1, &encoded);
    var raw_extra: [24]u8 = undefined;
    encodeEntryRangeExtra(entry.edge_range, raw_extra[0..16]);
    std.mem.writeInt(u64, raw_extra[16..24], 3, .little);
    var offset: usize = 0;
    const ranges = try decodeEntryRangeExtras(&raw_extra, &offset, header.metadata_flags);
    header.node_range = ranges.node_range;
    header.edge_range = ranges.edge_range;
    try std.testing.expectError(error.InvalidRecord, decodeEntryCountExtras(&raw_extra, &offset, header));
}

test "segment manifest rejects redundant explicit common extras" {
    var generation_extra: [8]u8 = undefined;
    std.mem.writeInt(u64, &generation_extra, 7, .little);
    var generation_offset: usize = 0;
    try std.testing.expectError(
        error.InvalidRecord,
        decodeEntryCommonExtras(&generation_extra, &generation_offset, entry_metadata_generation_explicit, 7),
    );

    var hotness_extra: [4]u8 = .{0} ** 4;
    var hotness_offset: usize = 0;
    try std.testing.expectError(
        error.InvalidRecord,
        decodeEntryCommonExtras(&hotness_extra, &hotness_offset, entry_metadata_hotness_explicit, 7),
    );
}

test "segment manifest rejects empty flagged range and digest extras" {
    var range_extra: [16]u8 = .{0} ** 16;
    var range_offset: usize = 0;
    try std.testing.expectError(
        error.InvalidRecord,
        decodeEntryRangeExtra(&range_extra, &range_offset, entry_metadata_edge_range_explicit, entry_metadata_edge_range_explicit),
    );

    var digest_extra: [8]u8 = .{0} ** 8;
    var digest_offset: usize = 0;
    try std.testing.expectError(
        error.InvalidRecord,
        decodeEntryDigestExtra(&digest_extra, &digest_offset, entry_metadata_segment_digest_explicit, entry_metadata_segment_digest_explicit),
    );
}

test "segment manifest rejects invalid node catalog summary metadata" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const manifest_dir = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "manifest" });
    defer std.testing.allocator.free(manifest_dir);

    var store = try Store.init(std.testing.allocator, std.testing.io, manifest_dir);
    defer store.deinit();

    const summary = segment_catalog_summary.CatalogSummary{
        .node_count = 3,
        .texts_bytes = 27,
        .texts_digest = 0xabc1,
        .nodes_record_digest = 0xabc2,
        .exact_record_digest = 0xabc3,
    };
    try std.testing.expectError(error.InvalidRecord, store.publish(0, &.{
        .{
            .kind = .edge,
            .generation = 1,
            .edge_count = 3,
            .edge_range = .{ .min = 1, .max = 3 },
            .node_catalog_summary = summary,
            .path = "segments/edge-s000001",
        },
    }));
    try std.testing.expectError(error.InvalidRecord, store.publish(0, &.{
        .{
            .kind = .node,
            .generation = 1,
            .node_count = 2,
            .node_range = .{ .min = 10, .max = 11 },
            .node_catalog_summary = summary,
            .path = "segments/node-s000001",
        },
    }));
}

test "segment manifest fails closed for dangling current and unsafe paths" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const manifest_dir = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "manifest" });
    defer std.testing.allocator.free(manifest_dir);

    var store = try Store.init(std.testing.allocator, std.testing.io, manifest_dir);
    defer store.deinit();

    try std.testing.expectError(error.InvalidRecord, store.publish(0, &.{
        .{
            .kind = .edge,
            .generation = 1,
            .edge_count = 1,
            .edge_range = .{ .min = 1, .max = 1 },
            .path = "../escape",
        },
    }));

    _ = try store.publish(0, &.{
        .{
            .kind = .edge,
            .generation = 1,
            .edge_count = 1,
            .edge_range = .{ .min = 1, .max = 1 },
            .path = "segments/edge-s000001",
        },
    });
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = store.current_path,
        .data = "MANIFEST-999",
    });
    try std.testing.expectError(error.InvalidRecord, store.pinCurrent());
    try std.testing.expectError(error.InvalidRecord, store.publish(1, &.{
        .{
            .kind = .edge,
            .generation = 2,
            .edge_count = 1,
            .edge_range = .{ .min = 2, .max = 2 },
            .path = "segments/edge-s000002",
        },
    }));
    try std.testing.expectError(error.InvalidRecord, store.gcUnpinned(&.{}));
}

test "segment manifest rejects corrupted entry digest" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const manifest_dir = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "manifest" });
    defer std.testing.allocator.free(manifest_dir);

    var store = try Store.init(std.testing.allocator, std.testing.io, manifest_dir);
    defer store.deinit();
    _ = try store.publish(0, &.{
        .{
            .kind = .edge,
            .generation = 1,
            .edge_count = 1,
            .edge_range = .{ .min = 1, .max = 1 },
            .path = "segments/edge-s000001",
        },
    });

    const leaf = try manifestLeaf(std.testing.allocator, 1);
    defer std.testing.allocator.free(leaf);
    const manifest_path = try std.fs.path.join(std.testing.allocator, &.{ manifest_dir, leaf });
    defer std.testing.allocator.free(manifest_path);
    var file = try std.Io.Dir.cwd().openFile(std.testing.io, manifest_path, .{ .mode = .read_write });
    defer file.close(std.testing.io);
    try file.writePositionalAll(std.testing.io, &.{0xff}, ManifestHeader.encoded_len + EntryHeader.encoded_len + 16);

    try std.testing.expectError(error.InvalidRecord, store.pinCurrent());
}

test "segment manifest rejects corrupted node catalog summary digest" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const manifest_dir = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "manifest" });
    defer std.testing.allocator.free(manifest_dir);

    var store = try Store.init(std.testing.allocator, std.testing.io, manifest_dir);
    defer store.deinit();
    _ = try store.publish(0, &.{
        .{
            .kind = .node,
            .generation = 1,
            .node_count = 1,
            .node_range = .{ .min = 1, .max = 1 },
            .node_catalog_summary = .{
                .node_count = 1,
                .texts_bytes = 4,
                .texts_digest = 0x41,
                .nodes_record_digest = 0x42,
                .exact_record_digest = 0x43,
            },
            .path = "segments/node-s000001",
        },
    });

    const leaf = try manifestLeaf(std.testing.allocator, 1);
    defer std.testing.allocator.free(leaf);
    const manifest_path = try std.fs.path.join(std.testing.allocator, &.{ manifest_dir, leaf });
    defer std.testing.allocator.free(manifest_path);
    var file = try std.Io.Dir.cwd().openFile(std.testing.io, manifest_path, .{ .mode = .read_write });
    defer file.close(std.testing.io);
    try file.writePositionalAll(std.testing.io, &.{0xff}, ManifestHeader.encoded_len + EntryHeader.encoded_len + 32);

    try std.testing.expectError(error.InvalidRecord, store.pinCurrent());
}

test "segment manifest plans WAL tail recovery from checkpoint only" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const manifest_dir = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "manifest" });
    defer std.testing.allocator.free(manifest_dir);
    const wal_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "wal.bin" });
    defer std.testing.allocator.free(wal_path);

    const prefix = "checkpointed bytes are not parsed as WAL records";
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = wal_path,
        .data = prefix,
        .flags = .{ .truncate = true },
    });

    var store = try Store.init(std.testing.allocator, std.testing.io, manifest_dir);
    defer store.deinit();
    _ = try store.publish(prefix.len, &.{
        .{
            .kind = .edge,
            .generation = 1,
            .edge_count = 1,
            .edge_range = .{ .min = 1, .max = 1 },
            .path = "segments/edge-s000001",
        },
    });

    const after_node = try appendWalRecord(std.testing.io, wal_path, .node, "node tail");
    const after_edge = try appendWalRecord(std.testing.io, wal_path, .edge, "edge tail");

    var plan = try store.planWalTailRecovery(wal_path);
    defer plan.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 1), plan.snapshot.generation);
    try std.testing.expectEqual(@as(u64, prefix.len), plan.checkpoint_bytes);
    try std.testing.expectEqual(after_edge, plan.end_bytes);
    try std.testing.expectEqual(@as(usize, 2), plan.records.items.len);
    try std.testing.expectEqual(WalRecordKind.node, plan.records.items[0].kind);
    try std.testing.expectEqual(WalRecordKind.edge, plan.records.items[1].kind);
    try std.testing.expectEqual(@as(u64, prefix.len), plan.records.items[0].offset);
    try std.testing.expectEqual(after_node, plan.records.items[0].next_offset);
    try std.testing.expectEqual(after_edge - prefix.len, try plan.tailBytes());
}

test "segment manifest WAL tail recovery rejects checkpoint past end and bad tail checksum" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const manifest_dir = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "manifest" });
    defer std.testing.allocator.free(manifest_dir);
    const wal_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "wal.bin" });
    defer std.testing.allocator.free(wal_path);

    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = wal_path,
        .data = "",
        .flags = .{ .truncate = true },
    });

    var store = try Store.init(std.testing.allocator, std.testing.io, manifest_dir);
    defer store.deinit();
    _ = try store.publish(1, &.{});
    try std.testing.expectError(error.InvalidRecord, store.planWalTailRecovery(wal_path));

    _ = try store.publish(0, &.{});
    _ = try appendWalRecord(std.testing.io, wal_path, .edge, "valid payload");
    {
        var wal_file = try std.Io.Dir.cwd().openFile(std.testing.io, wal_path, .{ .mode = .read_write });
        defer wal_file.close(std.testing.io);
        try wal_file.writePositionalAll(std.testing.io, &.{0xff}, WalRecordHeader.encoded_len + 1);
    }
    try std.testing.expectError(error.InvalidRecord, store.planWalTailRecovery(wal_path));
}
