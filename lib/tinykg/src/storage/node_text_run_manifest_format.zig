const std = @import("std");
const builtin = @import("builtin");

/// Persistent node-text run-manifest contracts parameterized by the stable
/// node-text header type. File I/O, CURRENT publication, caching, epoch-path
/// validation, GC, compaction, and query orchestration remain in storage.zig.
pub fn NodeTextRunManifestFormat(comptime NodeTextIndexHeader: type) type {
    return struct {
        const Self = @This();

        pub const production_max_entries: usize = 4096;
        pub const test_max_entries: usize = 16;
        pub const max_entries: usize = if (builtin.is_test) test_max_entries else production_max_entries;
        pub const max_records: u64 = 65_536;
        pub const max_path_bytes: u64 = 64 * 1024;
        pub const hash_filter_min_records: u64 = 8;
        pub const hash_filter_min_bytes: usize = 64;
        pub const hash_filter_max_bytes: usize = 256 * 1024;
        pub const hash_filter_target_bytes_per_record: u64 = 1;
        pub const hash_filter_probes: usize = 7;

        pub const Entry = struct {
            node_count: u64,
            node_digest: u64,
            order_digest: u64,
            min_node_id: u64 = 0,
            max_node_id: u64 = 0,
            min_hash: u64 = 0,
            max_hash: u64 = 0,
            path: []const u8,
            hash_filter: []const u8 = &.{},
        };

        pub const OwnedEntry = struct {
            node_count: u64,
            node_digest: u64,
            order_digest: u64,
            min_node_id: u64 = 0,
            max_node_id: u64 = 0,
            min_hash: u64 = 0,
            max_hash: u64 = 0,
            path: []u8,
            path_digest: u64 = 0,
            has_path_digest: bool = false,
            hash_filter: []u8 = &.{},

            pub fn deinit(self: *OwnedEntry, allocator: std.mem.Allocator) void {
                allocator.free(self.path);
                allocator.free(self.hash_filter);
            }

            pub fn header(self: OwnedEntry) NodeTextIndexHeader {
                return .{
                    .node_count = self.node_count,
                    .node_digest = self.node_digest,
                    .order_digest = self.order_digest,
                };
            }
        };

        pub const Manifest = struct {
            pub const magic = [_]u8{ 'T', 'K', 'N', 'R' };
            pub const version: u16 = 5;
            pub const header_len: usize = 40;
            pub const entry_header_len: usize = 64;

            entries: std.ArrayList(OwnedEntry) = .empty,
            total_node_count: u64 = 0,
            node_digest: u64 = 0,
            aggregates_valid: bool = false,
            backing: []u8 = &.{},
            io: std.Io = undefined,
            file: ?std.Io.File = null,
            map: ?std.Io.File.MemoryMap = null,

            pub fn deinit(self: *Manifest, allocator: std.mem.Allocator) void {
                if (self.backing.len == 0) {
                    for (self.entries.items) |*entry| entry.deinit(allocator);
                }
                self.entries.deinit(allocator);
                if (self.map) |*map| {
                    map.destroy(self.io);
                    self.file.?.close(self.io);
                } else {
                    allocator.free(self.backing);
                }
            }

            pub fn totalNodeCount(self: Manifest) u64 {
                if (self.aggregates_valid) return self.total_node_count;
                return Self.totalNodesOwned(self.entries.items) orelse std.math.maxInt(u64);
            }

            pub fn nodeDigest(self: Manifest) u64 {
                if (self.aggregates_valid) return self.node_digest;
                return Self.digestOwned(self.entries.items);
            }

            pub fn combinedOrderDigest(self: Manifest, base: NodeTextIndexHeader, delta: NodeTextIndexHeader) u64 {
                var digest = Self.combinedOrderDigestBaseDelta(base, delta);
                for (self.entries.items) |run| {
                    const path_digest = if (run.has_path_digest) run.path_digest else std.hash.Wyhash.hash(0x544B_4E52, run.path);
                    digest = Self.combinedOrderDigestStep(digest, base.node_count, delta.node_count, run.node_count, run.node_digest, run.order_digest, path_digest);
                }
                return digest;
            }
        };

        pub const Header = struct {
            run_count: usize,
            total_nodes: u64,
            node_digest: u64,
            content_digest: u64,
        };

        pub const EntryHeader = struct {
            node_count: u64,
            node_digest: u64,
            order_digest: u64,
            min_node_id: u64,
            max_node_id: u64,
            min_hash: u64,
            max_hash: u64,
            path_len: u64,
            hash_filter_len: u64,
        };

        pub fn totalNodes(entries: []const Entry) !u64 {
            var total: u64 = 0;
            for (entries) |entry| {
                total = std.math.add(u64, total, entry.node_count) catch return error.RecordTooLarge;
            }
            return total;
        }

        pub fn totalNodesOwned(entries: []const OwnedEntry) ?u64 {
            var total: u64 = 0;
            for (entries) |entry| {
                total = std.math.add(u64, total, entry.node_count) catch return null;
            }
            return total;
        }

        pub fn digestOwned(entries: []const OwnedEntry) u64 {
            var digest: u64 = 0;
            for (entries) |entry| digest ^= entry.node_digest;
            return digest;
        }

        pub fn entryMayContainHash(entry: OwnedEntry, hash: u64) bool {
            return hash >= entry.min_hash and hash <= entry.max_hash and hashFilterMayContain(entry.hash_filter, hash);
        }

        pub fn hashFilterShouldBuild(record_count: u64) bool {
            return hashFilterLenForRecords(record_count) != 0;
        }

        pub fn hashFilterLenForRecords(record_count: u64) usize {
            if (record_count < hash_filter_min_records) return 0;
            const target_bytes = std.math.mul(u64, record_count, hash_filter_target_bytes_per_record) catch std.math.maxInt(u64);
            const clamped = @min(@max(target_bytes, hash_filter_min_bytes), hash_filter_max_bytes);
            const filter_len = std.math.ceilPowerOfTwoAssert(usize, @intCast(clamped));
            return @min(filter_len, hash_filter_max_bytes);
        }

        pub fn hashFilterLenValid(filter_len: u64) bool {
            if (filter_len == 0) return true;
            if (filter_len < hash_filter_min_bytes) return false;
            if (filter_len > hash_filter_max_bytes) return false;
            return std.math.isPowerOfTwo(filter_len);
        }

        fn hashFilterProbe(hash: u64, probe_index: usize, mask: u64) u64 {
            var delta = hash;
            delta ^= delta >> 33;
            delta *%= 0xff51afd7ed558ccd;
            delta ^= delta >> 33;
            delta *%= 0xc4ceb9fe1a85ec53;
            delta ^= delta >> 33;
            delta |= 1;
            return (hash +% (@as(u64, @intCast(probe_index)) *% delta)) & mask;
        }

        pub fn hashFilterSet(filter: []u8, hash: u64) void {
            // The probe math requires a power-of-two length at or above the
            // shared floor; upper byte-budget policy differs between run
            // filters and the larger node-text base filter and is enforced by
            // each caller's own length validator at its read/write
            // boundaries.
            std.debug.assert(filter.len >= hash_filter_min_bytes and std.math.isPowerOfTwo(filter.len));
            const mask: u64 = @intCast(filter.len * 8 - 1);
            var probe_index: usize = 0;
            while (probe_index < hash_filter_probes) : (probe_index += 1) {
                const bit = hashFilterProbe(hash, probe_index, mask);
                filter[@intCast(bit >> 3)] |= @as(u8, 1) << @intCast(bit & 7);
            }
        }

        pub fn hashFilterMayContain(filter: []const u8, hash: u64) bool {
            if (filter.len < hash_filter_min_bytes) return true;
            if (!std.math.isPowerOfTwo(filter.len)) return true;
            const mask: u64 = @intCast(filter.len * 8 - 1);
            var probe_index: usize = 0;
            while (probe_index < hash_filter_probes) : (probe_index += 1) {
                const bit = hashFilterProbe(hash, probe_index, mask);
                if ((filter[@intCast(bit >> 3)] & (@as(u8, 1) << @intCast(bit & 7))) == 0) return false;
            }
            return true;
        }

        fn digestFields(entries: anytype, include_hash_filter: bool) u64 {
            var hasher = std.hash.Wyhash.init(0x544B_4E52);
            var bytes: [8]u8 = undefined;
            for (entries) |entry| {
                std.mem.writeInt(u64, &bytes, entry.node_count, .little);
                hasher.update(&bytes);
                std.mem.writeInt(u64, &bytes, entry.node_digest, .little);
                hasher.update(&bytes);
                std.mem.writeInt(u64, &bytes, entry.order_digest, .little);
                hasher.update(&bytes);
                std.mem.writeInt(u64, &bytes, entry.min_node_id, .little);
                hasher.update(&bytes);
                std.mem.writeInt(u64, &bytes, entry.max_node_id, .little);
                hasher.update(&bytes);
                std.mem.writeInt(u64, &bytes, entry.min_hash, .little);
                hasher.update(&bytes);
                std.mem.writeInt(u64, &bytes, entry.max_hash, .little);
                hasher.update(&bytes);
                hasher.update(entry.path);
                if (include_hash_filter) hasher.update(entry.hash_filter);
            }
            return hasher.final();
        }

        pub fn epochDigest(entries: []const Entry) u64 {
            return digestFields(entries, false);
        }

        pub fn epochDigestOwned(entries: []const OwnedEntry) u64 {
            return digestFields(entries, false);
        }

        pub fn contentDigest(entries: []const Entry) u64 {
            return digestFields(entries, true);
        }

        pub fn contentDigestOwned(entries: []const OwnedEntry) u64 {
            return digestFields(entries, true);
        }

        pub fn encodeHeader(entries: []const Entry, out: *[Manifest.header_len]u8) !void {
            if (entries.len > max_entries) return error.BudgetExceeded;
            var total_nodes: u64 = 0;
            var node_digest: u64 = 0;
            for (entries) |entry| {
                try validateEntry(entry);
                total_nodes = std.math.add(u64, total_nodes, entry.node_count) catch return error.InvalidRecord;
                node_digest ^= entry.node_digest;
            }
            @memcpy(out[0..4], &Manifest.magic);
            std.mem.writeInt(u16, out[4..6], Manifest.version, .little);
            std.mem.writeInt(u16, out[6..8], Manifest.header_len, .little);
            std.mem.writeInt(u32, out[8..12], @intCast(entries.len), .little);
            @memset(out[12..16], 0);
            std.mem.writeInt(u64, out[16..24], total_nodes, .little);
            std.mem.writeInt(u64, out[24..32], node_digest, .little);
            std.mem.writeInt(u64, out[32..40], contentDigest(entries), .little);
        }

        pub fn decodeHeader(bytes: *const [Manifest.header_len]u8) !Header {
            if (!std.mem.eql(u8, bytes[0..4], &Manifest.magic)) return error.InvalidRecord;
            if (std.mem.readInt(u16, bytes[4..6], .little) != Manifest.version) return error.InvalidRecord;
            if (std.mem.readInt(u16, bytes[6..8], .little) != Manifest.header_len) return error.InvalidRecord;
            if (!allZero(bytes[12..16])) return error.InvalidRecord;
            const run_count = std.mem.readInt(u32, bytes[8..12], .little);
            if (run_count > max_entries) return error.InvalidRecord;
            return .{
                .run_count = @intCast(run_count),
                .total_nodes = std.mem.readInt(u64, bytes[16..24], .little),
                .node_digest = std.mem.readInt(u64, bytes[24..32], .little),
                .content_digest = std.mem.readInt(u64, bytes[32..40], .little),
            };
        }

        pub fn encodeEntryHeader(entry: Entry, out: *[Manifest.entry_header_len]u8) !void {
            try validateEntry(entry);
            std.mem.writeInt(u64, out[0..8], entry.node_count, .little);
            std.mem.writeInt(u64, out[8..16], entry.node_digest, .little);
            std.mem.writeInt(u64, out[16..24], entry.order_digest, .little);
            std.mem.writeInt(u64, out[24..32], entry.min_node_id, .little);
            std.mem.writeInt(u64, out[32..40], entry.max_node_id, .little);
            std.mem.writeInt(u64, out[40..48], entry.min_hash, .little);
            std.mem.writeInt(u64, out[48..56], entry.max_hash, .little);
            std.mem.writeInt(u32, out[56..60], @intCast(entry.path.len), .little);
            std.mem.writeInt(u32, out[60..64], @intCast(entry.hash_filter.len), .little);
        }

        pub fn decodeEntryHeader(bytes: *const [Manifest.entry_header_len]u8) !EntryHeader {
            const min_node_id = std.mem.readInt(u64, bytes[24..32], .little);
            const max_node_id = std.mem.readInt(u64, bytes[32..40], .little);
            if (min_node_id == 0 or max_node_id < min_node_id) return error.InvalidRecord;
            const min_hash = std.mem.readInt(u64, bytes[40..48], .little);
            const max_hash = std.mem.readInt(u64, bytes[48..56], .little);
            if (min_hash > max_hash) return error.InvalidRecord;
            return .{
                .node_count = std.mem.readInt(u64, bytes[0..8], .little),
                .node_digest = std.mem.readInt(u64, bytes[8..16], .little),
                .order_digest = std.mem.readInt(u64, bytes[16..24], .little),
                .min_node_id = min_node_id,
                .max_node_id = max_node_id,
                .min_hash = min_hash,
                .max_hash = max_hash,
                .path_len = std.mem.readInt(u32, bytes[56..60], .little),
                .hash_filter_len = std.mem.readInt(u32, bytes[60..64], .little),
            };
        }

        pub fn combinedOrderDigestBaseDelta(base: NodeTextIndexHeader, delta: NodeTextIndexHeader) u64 {
            if (delta.node_count == 0) return base.order_digest;
            var bytes: [48]u8 = undefined;
            std.mem.writeInt(u64, bytes[0..8], base.node_count, .little);
            std.mem.writeInt(u64, bytes[8..16], base.node_digest, .little);
            std.mem.writeInt(u64, bytes[16..24], base.order_digest, .little);
            std.mem.writeInt(u64, bytes[24..32], delta.node_count, .little);
            std.mem.writeInt(u64, bytes[32..40], delta.node_digest, .little);
            std.mem.writeInt(u64, bytes[40..48], delta.order_digest, .little);
            return std.hash.Wyhash.hash(0x544B_474C, &bytes);
        }

        pub fn combinedOrderDigestWithOwnedEntries(base: NodeTextIndexHeader, delta: NodeTextIndexHeader, runs: []const OwnedEntry) u64 {
            var digest = combinedOrderDigestBaseDelta(base, delta);
            for (runs) |run| {
                digest = combinedOrderDigestStep(
                    digest,
                    base.node_count,
                    delta.node_count,
                    run.node_count,
                    run.node_digest,
                    run.order_digest,
                    std.hash.Wyhash.hash(0x544B_4E52, run.path),
                );
            }
            return digest;
        }

        pub fn combinedOrderDigestWithEntries(base: NodeTextIndexHeader, delta: NodeTextIndexHeader, runs: []const Entry) u64 {
            var digest = combinedOrderDigestBaseDelta(base, delta);
            for (runs) |run| {
                digest = combinedOrderDigestStep(
                    digest,
                    base.node_count,
                    delta.node_count,
                    run.node_count,
                    run.node_digest,
                    run.order_digest,
                    std.hash.Wyhash.hash(0x544B_4E52, run.path),
                );
            }
            return digest;
        }

        fn combinedOrderDigestStep(previous: u64, base_count: u64, delta_count: u64, run_count: u64, run_digest: u64, run_order_digest: u64, path_digest: u64) u64 {
            var bytes: [56]u8 = undefined;
            std.mem.writeInt(u64, bytes[0..8], previous, .little);
            std.mem.writeInt(u64, bytes[8..16], base_count, .little);
            std.mem.writeInt(u64, bytes[16..24], delta_count, .little);
            std.mem.writeInt(u64, bytes[24..32], run_count, .little);
            std.mem.writeInt(u64, bytes[32..40], run_digest, .little);
            std.mem.writeInt(u64, bytes[40..48], run_order_digest, .little);
            std.mem.writeInt(u64, bytes[48..56], path_digest, .little);
            return std.hash.Wyhash.hash(0x544B_4E4D, &bytes);
        }

        fn validateEntry(entry: Entry) !void {
            if (entry.node_count == 0 or entry.node_count > max_records) return error.InvalidRecord;
            if (entry.min_node_id == 0 or entry.max_node_id < entry.min_node_id) return error.InvalidRecord;
            if (entry.min_hash > entry.max_hash) return error.InvalidRecord;
            if (entry.path.len == 0 or entry.path.len > max_path_bytes) return error.InvalidRecord;
            if (!hashFilterLenValid(entry.hash_filter.len)) return error.InvalidRecord;
        }

        fn allZero(bytes: []const u8) bool {
            for (bytes) |byte| {
                if (byte != 0) return false;
            }
            return true;
        }
    };
}

const TestHeader = struct {
    node_count: u64,
    node_digest: u64 = 0,
    order_digest: u64 = 0,
};

const TestFormat = NodeTextRunManifestFormat(TestHeader);

fn testEntry() TestFormat.Entry {
    return .{
        .node_count = 3,
        .node_digest = 0x1122,
        .order_digest = 0x3344,
        .min_node_id = 7,
        .max_node_id = 9,
        .min_hash = 10,
        .max_hash = 20,
        .path = "runs/0001.dat",
    };
}

test "node-text-run manifest v5 header and entry preserve stable bytes" {
    const entry = testEntry();
    var header_bytes: [TestFormat.Manifest.header_len]u8 = undefined;
    try TestFormat.encodeHeader(&.{entry}, &header_bytes);

    try std.testing.expectEqualSlices(u8, "TKNR", header_bytes[0..4]);
    try std.testing.expectEqual(@as(u16, 5), std.mem.readInt(u16, header_bytes[4..6], .little));
    try std.testing.expectEqual(@as(u16, 40), std.mem.readInt(u16, header_bytes[6..8], .little));
    const header = try TestFormat.decodeHeader(&header_bytes);
    try std.testing.expectEqual(@as(usize, 1), header.run_count);
    try std.testing.expectEqual(entry.node_count, header.total_nodes);
    try std.testing.expectEqual(entry.node_digest, header.node_digest);
    try std.testing.expectEqual(TestFormat.contentDigest(&.{entry}), header.content_digest);

    var entry_bytes: [TestFormat.Manifest.entry_header_len]u8 = undefined;
    try TestFormat.encodeEntryHeader(entry, &entry_bytes);
    const decoded = try TestFormat.decodeEntryHeader(&entry_bytes);
    try std.testing.expectEqual(entry.node_count, decoded.node_count);
    try std.testing.expectEqual(entry.node_digest, decoded.node_digest);
    try std.testing.expectEqual(entry.order_digest, decoded.order_digest);
    try std.testing.expectEqual(entry.min_node_id, decoded.min_node_id);
    try std.testing.expectEqual(entry.max_node_id, decoded.max_node_id);
    try std.testing.expectEqual(entry.min_hash, decoded.min_hash);
    try std.testing.expectEqual(entry.max_hash, decoded.max_hash);
    try std.testing.expectEqual(entry.path.len, decoded.path_len);
    try std.testing.expectEqual(@as(u64, 0), decoded.hash_filter_len);
}

test "node-text-run manifest rejects corrupt identity reserved bytes and entry bounds" {
    const entry = testEntry();
    var header_bytes: [TestFormat.Manifest.header_len]u8 = undefined;
    try TestFormat.encodeHeader(&.{entry}, &header_bytes);

    var corrupt = header_bytes;
    corrupt[0] = 'X';
    try std.testing.expectError(error.InvalidRecord, TestFormat.decodeHeader(&corrupt));
    corrupt = header_bytes;
    corrupt[12] = 1;
    try std.testing.expectError(error.InvalidRecord, TestFormat.decodeHeader(&corrupt));
    corrupt = header_bytes;
    std.mem.writeInt(u32, corrupt[8..12], TestFormat.max_entries + 1, .little);
    try std.testing.expectError(error.InvalidRecord, TestFormat.decodeHeader(&corrupt));

    var entry_bytes: [TestFormat.Manifest.entry_header_len]u8 = undefined;
    try TestFormat.encodeEntryHeader(entry, &entry_bytes);
    corrupt_entry: {
        var invalid = entry_bytes;
        std.mem.writeInt(u64, invalid[24..32], 0, .little);
        try std.testing.expectError(error.InvalidRecord, TestFormat.decodeEntryHeader(&invalid));
        invalid = entry_bytes;
        std.mem.writeInt(u64, invalid[40..48], 21, .little);
        try std.testing.expectError(error.InvalidRecord, TestFormat.decodeEntryHeader(&invalid));
        break :corrupt_entry;
    }

    var invalid_entry = entry;
    invalid_entry.node_count = 0;
    try std.testing.expectError(error.InvalidRecord, TestFormat.encodeEntryHeader(invalid_entry, &entry_bytes));
    invalid_entry = entry;
    invalid_entry.path = "";
    try std.testing.expectError(error.InvalidRecord, TestFormat.encodeEntryHeader(invalid_entry, &entry_bytes));
    var invalid_filter = [_]u8{0};
    invalid_entry = entry;
    invalid_entry.hash_filter = &invalid_filter;
    try std.testing.expectError(error.InvalidRecord, TestFormat.encodeEntryHeader(invalid_entry, &entry_bytes));
}

test "node-text-run manifest separates epoch identity from content digest" {
    var first_filter = [_]u8{0} ** TestFormat.hash_filter_min_bytes;
    var second_filter = first_filter;
    second_filter[0] = 1;
    var first = testEntry();
    first.hash_filter = &first_filter;
    var second = first;
    second.hash_filter = &second_filter;

    try std.testing.expectEqual(TestFormat.epochDigest(&.{first}), TestFormat.epochDigest(&.{second}));
    try std.testing.expect(TestFormat.contentDigest(&.{first}) != TestFormat.contentDigest(&.{second}));
    second.path = "runs/0002.dat";
    try std.testing.expect(TestFormat.epochDigest(&.{first}) != TestFormat.epochDigest(&.{second}));
}

test "node-text-run manifest hash filter policy preserves inserted hashes" {
    try std.testing.expectEqual(@as(usize, 0), TestFormat.hashFilterLenForRecords(TestFormat.hash_filter_min_records - 1));
    try std.testing.expectEqual(TestFormat.hash_filter_min_bytes, TestFormat.hashFilterLenForRecords(TestFormat.hash_filter_min_records));
    try std.testing.expect(TestFormat.hashFilterLenValid(TestFormat.hash_filter_min_bytes));
    try std.testing.expect(!TestFormat.hashFilterLenValid(TestFormat.hash_filter_min_bytes - 1));

    var filter = [_]u8{0} ** TestFormat.hash_filter_min_bytes;
    const hash: u64 = 0x1234_5678_90ab_cdef;
    TestFormat.hashFilterSet(&filter, hash);
    try std.testing.expect(TestFormat.hashFilterMayContain(&filter, hash));
    try std.testing.expect(TestFormat.hashFilterMayContain(&.{}, hash));
    try std.testing.expect(TestFormat.hashFilterMayContain(&.{0}, hash));

    const path = try std.testing.allocator.dupe(u8, "runs/0001.dat");
    defer std.testing.allocator.free(path);
    const owned_filter = try std.testing.allocator.dupe(u8, &filter);
    defer std.testing.allocator.free(owned_filter);
    const owned = TestFormat.OwnedEntry{
        .node_count = 3,
        .node_digest = 1,
        .order_digest = 2,
        .min_node_id = 7,
        .max_node_id = 9,
        .min_hash = hash,
        .max_hash = hash,
        .path = path,
        .hash_filter = owned_filter,
    };
    try std.testing.expect(TestFormat.entryMayContainHash(owned, hash));
    try std.testing.expect(!TestFormat.entryMayContainHash(owned, hash - 1));
}

test "node-text-run manifest owns heap entries and derives aggregates" {
    var manifest = TestFormat.Manifest{};
    defer manifest.deinit(std.testing.allocator);
    try manifest.entries.append(std.testing.allocator, .{
        .node_count = 3,
        .node_digest = 0x55,
        .order_digest = 0x66,
        .min_node_id = 1,
        .max_node_id = 3,
        .path = try std.testing.allocator.dupe(u8, "runs/owned.dat"),
        .hash_filter = try std.testing.allocator.alloc(u8, 0),
    });
    try std.testing.expectEqual(@as(u64, 3), manifest.totalNodeCount());
    try std.testing.expectEqual(@as(u64, 0x55), manifest.nodeDigest());

    const overflow = [_]TestFormat.OwnedEntry{
        .{ .node_count = std.math.maxInt(u64), .node_digest = 1, .order_digest = 1, .path = &.{} },
        .{ .node_count = 1, .node_digest = 2, .order_digest = 2, .path = &.{} },
    };
    try std.testing.expectEqual(@as(?u64, null), TestFormat.totalNodesOwned(&overflow));
}

test "node-text-run manifest order digest accepts cached path identity" {
    const base = TestHeader{ .node_count = 5, .node_digest = 6, .order_digest = 7 };
    const delta = TestHeader{ .node_count = 2, .node_digest = 3, .order_digest = 4 };
    const path = try std.testing.allocator.dupe(u8, "runs/0001.dat");
    defer std.testing.allocator.free(path);
    const filter = try std.testing.allocator.alloc(u8, 0);
    defer std.testing.allocator.free(filter);
    var run = TestFormat.OwnedEntry{
        .node_count = 3,
        .node_digest = 8,
        .order_digest = 9,
        .min_node_id = 1,
        .max_node_id = 3,
        .path = path,
        .hash_filter = filter,
    };
    const derived = TestFormat.combinedOrderDigestWithOwnedEntries(base, delta, &.{run});
    run.path_digest = std.hash.Wyhash.hash(0x544B_4E52, path);
    run.has_path_digest = true;
    try std.testing.expectEqual(derived, TestFormat.combinedOrderDigestWithOwnedEntries(base, delta, &.{run}));

    var manifest = TestFormat.Manifest{};
    defer manifest.entries.deinit(std.testing.allocator);
    try manifest.entries.append(std.testing.allocator, run);
    try std.testing.expectEqual(derived, manifest.combinedOrderDigest(base, delta));
    manifest.entries.items[0].path_digest +%= 1;
    try std.testing.expectEqual(derived, TestFormat.combinedOrderDigestWithOwnedEntries(base, delta, manifest.entries.items));
    try std.testing.expect(derived != manifest.combinedOrderDigest(base, delta));
}
