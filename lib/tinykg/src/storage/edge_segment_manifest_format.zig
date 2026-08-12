const std = @import("std");
const index_meta_format = @import("index_meta_format.zig").IndexMetaFormat;

/// Persistent edge-segment manifest v14 contracts parameterized by the public
/// core and segment namespaces. Store-root path transformation, positional
/// file I/O, CURRENT/cache/publication, virtual-edge materialization, GC,
/// compaction, and query orchestration remain in storage.zig.
pub fn EdgeSegmentManifestFormat(comptime core: type, comptime segment_mod: type) type {
    return struct {
        const Self = @This();

        pub const EdgeSegmentIdRunSummary = index_meta_format.EdgeSegmentIdRunSummary;

        pub const Entry = struct {
            pub const full_node_range = segment_mod.ImmutableAdjacencySegment.NodeIdRange{
                .min = 1,
                .max = std.math.maxInt(u64) - 1,
            };

            edge_count: u64,
            edge_digest: u64,
            edge_id_range: segment_mod.ImmutableAdjacencySegment.EdgeIdRange,
            edge_id_digest: u64,
            edge_id_order_digest: u64 = 0,
            edge_id_runs: EdgeSegmentIdRunSummary = .{},
            src_node_range: segment_mod.ImmutableAdjacencySegment.NodeIdRange = full_node_range,
            dst_node_range: segment_mod.ImmutableAdjacencySegment.NodeIdRange = full_node_range,
            singleton_rel: ?core.RelKind = null,
            path: []const u8,
        };

        pub const OwnedEntry = struct {
            edge_count: u64,
            edge_digest: u64 = 0,
            edge_id_range: segment_mod.ImmutableAdjacencySegment.EdgeIdRange,
            edge_id_digest: u64,
            edge_id_order_digest: u64 = 0,
            edge_id_runs: EdgeSegmentIdRunSummary = .{},
            src_node_range: segment_mod.ImmutableAdjacencySegment.NodeIdRange,
            dst_node_range: segment_mod.ImmutableAdjacencySegment.NodeIdRange,
            singleton_rel: ?core.RelKind = null,
            path: []u8,

            pub fn deinit(self: *OwnedEntry, allocator: std.mem.Allocator) void {
                allocator.free(self.path);
            }
        };

        pub const Manifest = struct {
            pub const multi_magic = [_]u8{ 'T', 'K', 'M', 'S' };
            pub const version: u16 = 14;
            pub const header_len: usize = 24;
            pub const entry_header_len: usize = 24;

            entries: std.ArrayList(OwnedEntry) = .empty,
            ranges_trusted: bool = false,

            pub fn deinit(self: *Manifest, allocator: std.mem.Allocator) void {
                for (self.entries.items) |*entry| entry.deinit(allocator);
                self.entries.deinit(allocator);
            }

            pub fn totalEdgeCount(self: Manifest) u64 {
                var total: u64 = 0;
                for (self.entries.items) |entry| {
                    total = std.math.add(u64, total, entry.edge_count) catch return std.math.maxInt(u64);
                }
                return total;
            }
        };

        pub const run_from_range: u32 = 1 << 0;
        pub const run_two_split: u32 = 1 << 1;
        pub const src_single: u32 = 1 << 2;
        pub const src_full: u32 = 1 << 3;
        pub const dst_single: u32 = 1 << 4;
        pub const dst_full: u32 = 1 << 5;
        pub const edge_digest_explicit: u32 = 1 << 6;
        pub const edge_count_explicit: u32 = 1 << 7;
        pub const order_digest_explicit: u32 = 1 << 8;
        pub const path_relative: u32 = 1 << 9;
        pub const virtual_singleton: u32 = 1 << 10;
        pub const known_run_flags: u32 = run_from_range | run_two_split;
        pub const endpoint_flags: u32 = src_single | src_full | dst_single | dst_full;
        pub const known_flags: u32 = known_run_flags |
            endpoint_flags |
            edge_digest_explicit |
            edge_count_explicit |
            order_digest_explicit |
            path_relative |
            virtual_singleton;

        pub const RunEncoding = struct {
            flags: u32,
            first_max: u64,
            second_min: u64,
        };

        pub const EndpointEncoding = struct {
            flags: u32,
            src_min: u64,
            src_max: u64,
            dst_min: u64,
            dst_max: u64,
        };

        pub const PathEncoding = struct {
            flags: u32,
            bytes: []const u8,
        };

        pub const Header = struct {
            segment_count: u32,
            total_edges: u64,
        };

        pub const EntryHeader = struct {
            path_len: u32,
            edge_id_range: segment_mod.ImmutableAdjacencySegment.EdgeIdRange,
            entry_flags: u32,
        };

        pub const EndpointRanges = struct {
            src_node_range: segment_mod.ImmutableAdjacencySegment.NodeIdRange,
            dst_node_range: segment_mod.ImmutableAdjacencySegment.NodeIdRange,
        };

        pub fn safeRelativePath(path: []const u8) bool {
            if (path.len == 0) return false;
            if (std.fs.path.isAbsolute(path)) return false;
            if (std.mem.indexOfScalar(u8, path, 0) != null) return false;
            // Validate both separator spellings independent of the current
            // host so manifests remain portable across POSIX and Windows.
            if (path[0] == '/' or path[0] == '\\') return false;
            if (path.len >= 2 and std.ascii.isAlphabetic(path[0]) and path[1] == ':') return false;
            var part_start: usize = 0;
            for (path, 0..) |byte, index| {
                if (byte != '/' and byte != '\\') continue;
                const part = path[part_start..index];
                if (part.len == 0) return false;
                if (std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
                part_start = index + 1;
            }
            const final_part = path[part_start..];
            if (final_part.len == 0) return false;
            if (std.mem.eql(u8, final_part, ".") or std.mem.eql(u8, final_part, "..")) return false;
            return true;
        }

        pub fn entryMayContainNode(entry: OwnedEntry, direction: segment_mod.Direction, node_id: u64) bool {
            const range = switch (direction) {
                .forward => entry.src_node_range,
                .reverse => entry.dst_node_range,
            };
            return node_id >= range.min and node_id <= range.max;
        }

        pub fn entryIsVirtual(entry: anytype) bool {
            return entry.singleton_rel != null;
        }

        pub fn rangeCount(range: segment_mod.ImmutableAdjacencySegment.EdgeIdRange) !u64 {
            if (range.min > range.max) return error.InvalidRecord;
            return std.math.add(u64, range.max - range.min, 1) catch return error.InvalidRecord;
        }

        pub fn nodeRangeCount(range: segment_mod.ImmutableAdjacencySegment.NodeIdRange) !u64 {
            if (range.min == 0 or range.max == std.math.maxInt(u64) or range.min > range.max) return error.InvalidRecord;
            return std.math.add(u64, range.max - range.min, 1) catch return error.InvalidRecord;
        }

        pub fn runsCoverEntry(
            edge_count: u64,
            edge_id_range: segment_mod.ImmutableAdjacencySegment.EdgeIdRange,
            runs: EdgeSegmentIdRunSummary,
        ) bool {
            if (runs.run_count == 0 or runs.run_count > 2) return false;
            if (runs.first_min == 0 or runs.first_max == std.math.maxInt(u64) or runs.first_min > runs.first_max) return false;
            var represented = std.math.add(u64, runs.first_max - runs.first_min, 1) catch return false;
            if (runs.run_count == 1) {
                if (runs.second_min != 0 or runs.second_max != 0) return false;
            } else {
                if (runs.second_min == 0 or runs.second_max == std.math.maxInt(u64) or runs.second_min > runs.second_max) return false;
                if (runs.second_min <= runs.first_max) return false;
                const second_count = std.math.add(u64, runs.second_max - runs.second_min, 1) catch return false;
                represented = std.math.add(u64, represented, second_count) catch return false;
            }
            if (represented != edge_count) return false;
            if (runs.first_min != edge_id_range.min) return false;
            const max = if (runs.run_count == 2) runs.second_max else runs.first_max;
            return max == edge_id_range.max;
        }

        pub fn canDeriveEdgeIdDigest(entry: anytype) bool {
            if (entry.edge_id_order_digest != 0) return false;
            return runsCoverEntry(entry.edge_count, entry.edge_id_range, entry.edge_id_runs);
        }

        pub fn canDeriveEdgeCount(entry: anytype) bool {
            return runsCoverEntry(entry.edge_count, entry.edge_id_range, entry.edge_id_runs);
        }

        pub fn logicalEdgeIdDigest(entry: anytype) u64 {
            return if (canDeriveEdgeIdDigest(entry)) 0 else entry.edge_id_digest;
        }

        pub fn validateVirtualEntryShape(entry: anytype) !void {
            _ = entry.singleton_rel orelse return error.InvalidRecord;
            if (entry.edge_count == 0) return error.InvalidRecord;
            if (entry.path.len != 0) return error.InvalidRecord;
            if (entry.edge_id_order_digest != 0) return error.InvalidRecord;
            if (!runsCoverEntry(entry.edge_count, entry.edge_id_range, entry.edge_id_runs)) return error.InvalidRecord;
            if (try rangeCount(entry.edge_id_range) != entry.edge_count) return error.InvalidRecord;
            if (try nodeRangeCount(entry.dst_node_range) != entry.edge_count) return error.InvalidRecord;
        }

        pub fn totalEdges(entries: []const Entry) !u64 {
            var total_edges: u64 = 0;
            for (entries) |entry| {
                if (entry.path.len > std.math.maxInt(u32)) return error.RecordTooLarge;
                if (entryIsVirtual(entry)) {
                    try validateVirtualEntryShape(entry);
                } else if (entry.path.len == 0) return error.RecordTooLarge;
                if (entry.edge_count == 0 or
                    entry.edge_id_range.min > entry.edge_id_range.max or
                    entry.src_node_range.min > entry.src_node_range.max or
                    entry.dst_node_range.min > entry.dst_node_range.max)
                {
                    return error.InvalidRecord;
                }
                total_edges = std.math.add(u64, total_edges, entry.edge_count) catch return error.RecordTooLarge;
            }
            return total_edges;
        }

        pub fn ownedTotalEdges(entries: []const OwnedEntry) ?u64 {
            var total: u64 = 0;
            for (entries) |entry| {
                if (entryIsVirtual(entry)) {
                    validateVirtualEntryShape(entry) catch return null;
                } else if (entry.path.len == 0) return null;
                if (entry.edge_count == 0 or
                    entry.edge_id_range.min > entry.edge_id_range.max or
                    entry.src_node_range.min > entry.src_node_range.max or
                    entry.dst_node_range.min > entry.dst_node_range.max)
                {
                    return null;
                }
                total = std.math.add(u64, total, entry.edge_count) catch return null;
            }
            return total;
        }

        pub fn encodeHeader(entries: []const Entry, out: *[Manifest.header_len]u8) !void {
            if (entries.len == 0 or entries.len > std.math.maxInt(u32)) return error.RecordTooLarge;
            @memcpy(out[0..4], &Manifest.multi_magic);
            std.mem.writeInt(u16, out[4..6], Manifest.version, .little);
            std.mem.writeInt(u16, out[6..8], Manifest.header_len, .little);
            std.mem.writeInt(u32, out[8..12], @intCast(entries.len), .little);
            std.mem.writeInt(u16, out[12..14], Manifest.entry_header_len, .little);
            @memset(out[14..16], 0);
            std.mem.writeInt(u64, out[16..24], try totalEdges(entries), .little);
        }

        pub fn decodeHeader(bytes: *const [Manifest.header_len]u8) !Header {
            if (!std.mem.eql(u8, bytes[0..4], &Manifest.multi_magic)) return error.InvalidRecord;
            if (std.mem.readInt(u16, bytes[4..6], .little) != Manifest.version) return error.InvalidRecord;
            if (std.mem.readInt(u16, bytes[6..8], .little) != Manifest.header_len) return error.InvalidRecord;
            if (std.mem.readInt(u16, bytes[12..14], .little) != Manifest.entry_header_len) return error.InvalidRecord;
            if (!allZero(bytes[14..16])) return error.InvalidRecord;
            const segment_count = std.mem.readInt(u32, bytes[8..12], .little);
            if (segment_count == 0) return error.InvalidRecord;
            return .{
                .segment_count = segment_count,
                .total_edges = std.mem.readInt(u64, bytes[16..24], .little),
            };
        }

        pub fn encodeRun(entry: Entry) !RunEncoding {
            try entry.edge_id_runs.validate();
            const covered_count = try entry.edge_id_runs.coveredCount();
            if (covered_count != 0 and covered_count != entry.edge_count) return error.InvalidRecord;
            switch (entry.edge_id_runs.run_count) {
                0 => return .{ .flags = 0, .first_max = 0, .second_min = 0 },
                1 => {
                    if (entry.edge_id_runs.first_min != entry.edge_id_range.min) return error.InvalidRecord;
                    if (entry.edge_id_runs.first_max != entry.edge_id_range.max) return error.InvalidRecord;
                    if (try rangeCount(entry.edge_id_range) != entry.edge_count) return error.InvalidRecord;
                    return .{ .flags = run_from_range, .first_max = 0, .second_min = 0 };
                },
                2 => {
                    if (entry.edge_id_runs.first_min != entry.edge_id_range.min) return error.InvalidRecord;
                    if (entry.edge_id_runs.second_max != entry.edge_id_range.max) return error.InvalidRecord;
                    return .{
                        .flags = run_two_split,
                        .first_max = entry.edge_id_runs.first_max,
                        .second_min = entry.edge_id_runs.second_min,
                    };
                },
                else => return error.InvalidRecord,
            }
        }

        pub fn decodeRun(
            edge_count: u64,
            edge_id_range: segment_mod.ImmutableAdjacencySegment.EdgeIdRange,
            flags: u32,
            first_max: u64,
            second_min: u64,
        ) !EdgeSegmentIdRunSummary {
            if ((flags & ~known_flags) != 0) return error.InvalidRecord;
            const run_flags = flags & known_run_flags;
            if ((run_flags & run_from_range) != 0 and (run_flags & run_two_split) != 0) return error.InvalidRecord;
            if (run_flags == 0) {
                if (first_max != 0 or second_min != 0) return error.InvalidRecord;
                return .{};
            }
            if ((run_flags & run_from_range) != 0) {
                if (first_max != 0 or second_min != 0) return error.InvalidRecord;
                if (try rangeCount(edge_id_range) != edge_count) return error.InvalidRecord;
                return .{ .run_count = 1, .first_min = edge_id_range.min, .first_max = edge_id_range.max };
            }
            if (first_max == 0 or second_min == 0) return error.InvalidRecord;
            if (edge_id_range.min > first_max or second_min > edge_id_range.max) return error.InvalidRecord;
            if (first_max == std.math.maxInt(u64) or second_min <= first_max + 1) return error.InvalidRecord;
            const first_count = std.math.add(u64, first_max - edge_id_range.min, 1) catch return error.InvalidRecord;
            const second_count = std.math.add(u64, edge_id_range.max - second_min, 1) catch return error.InvalidRecord;
            if ((std.math.add(u64, first_count, second_count) catch return error.InvalidRecord) != edge_count) return error.InvalidRecord;
            return .{
                .run_count = 2,
                .first_min = edge_id_range.min,
                .first_max = first_max,
                .second_min = second_min,
                .second_max = edge_id_range.max,
            };
        }

        pub fn deriveEdgeCount(
            edge_id_range: segment_mod.ImmutableAdjacencySegment.EdgeIdRange,
            flags: u32,
            first_max: u64,
            second_min: u64,
        ) !u64 {
            if ((flags & ~known_flags) != 0) return error.InvalidRecord;
            const run_flags = flags & known_run_flags;
            if ((run_flags & run_from_range) != 0 and (run_flags & run_two_split) != 0) return error.InvalidRecord;
            if ((flags & edge_count_explicit) != 0) return error.InvalidRecord;
            if ((run_flags & run_from_range) != 0) {
                if (first_max != 0 or second_min != 0) return error.InvalidRecord;
                return rangeCount(edge_id_range);
            }
            if ((run_flags & run_two_split) != 0) {
                if (first_max == 0 or second_min == 0) return error.InvalidRecord;
                if (edge_id_range.min > first_max or second_min > edge_id_range.max) return error.InvalidRecord;
                if (first_max == std.math.maxInt(u64) or second_min <= first_max + 1) return error.InvalidRecord;
                const first_count = std.math.add(u64, first_max - edge_id_range.min, 1) catch return error.InvalidRecord;
                const second_count = std.math.add(u64, edge_id_range.max - second_min, 1) catch return error.InvalidRecord;
                return std.math.add(u64, first_count, second_count) catch return error.InvalidRecord;
            }
            return error.InvalidRecord;
        }

        pub fn orderDigestExtraLen(flags: u32) !usize {
            try validateKnownFlags(flags);
            return if ((flags & order_digest_explicit) != 0) 8 else 0;
        }

        pub fn runExtraLen(flags: u32) !usize {
            try validateKnownFlags(flags);
            const run_flags = flags & known_run_flags;
            if ((run_flags & run_from_range) != 0 and (run_flags & run_two_split) != 0) return error.InvalidRecord;
            return if ((run_flags & run_two_split) != 0) 16 else 0;
        }

        pub fn edgeCountExtraLen(flags: u32) !usize {
            try validateKnownFlags(flags);
            const run_flags = flags & known_run_flags;
            if ((run_flags & run_from_range) != 0 and (run_flags & run_two_split) != 0) return error.InvalidRecord;
            const explicit = (flags & edge_count_explicit) != 0;
            if (explicit and run_flags != 0) return error.InvalidRecord;
            if (!explicit and run_flags == 0) return error.InvalidRecord;
            return if (explicit) 8 else 0;
        }

        pub fn digestExtraLen(flags: u32) !usize {
            try validateKnownFlags(flags);
            return if ((flags & edge_digest_explicit) != 0) 8 else 0;
        }

        pub fn singletonRelExtraLen(flags: u32) !usize {
            try validateKnownFlags(flags);
            if ((flags & virtual_singleton) == 0) return 0;
            if ((flags & path_relative) != 0) return error.InvalidRecord;
            return 2;
        }

        pub fn nodeRangeIsFull(range: segment_mod.ImmutableAdjacencySegment.NodeIdRange) bool {
            return range.min == Entry.full_node_range.min and range.max == Entry.full_node_range.max;
        }

        pub fn encodeEndpoints(entry: Entry) !EndpointEncoding {
            if (entry.src_node_range.min > entry.src_node_range.max or entry.dst_node_range.min > entry.dst_node_range.max) return error.InvalidRecord;
            var encoding = EndpointEncoding{
                .flags = 0,
                .src_min = entry.src_node_range.min,
                .src_max = entry.src_node_range.max,
                .dst_min = entry.dst_node_range.min,
                .dst_max = entry.dst_node_range.max,
            };
            if (nodeRangeIsFull(entry.src_node_range)) {
                encoding.flags |= src_full;
                encoding.src_min = 0;
                encoding.src_max = 0;
            } else if (entry.src_node_range.min == entry.src_node_range.max) {
                encoding.flags |= src_single;
                encoding.src_max = 0;
            }
            if (nodeRangeIsFull(entry.dst_node_range)) {
                encoding.flags |= dst_full;
                encoding.dst_min = 0;
                encoding.dst_max = 0;
            } else if (entry.dst_node_range.min == entry.dst_node_range.max) {
                encoding.flags |= dst_single;
                encoding.dst_max = 0;
            }
            return encoding;
        }

        pub fn endpointExtraLen(flags: u32) !usize {
            try validateKnownFlags(flags);
            if ((flags & src_single) != 0 and (flags & src_full) != 0) return error.InvalidRecord;
            if ((flags & dst_single) != 0 and (flags & dst_full) != 0) return error.InvalidRecord;
            var len: usize = 0;
            if ((flags & src_full) == 0) len += 8;
            if ((flags & (src_single | src_full)) == 0) len += 8;
            if ((flags & dst_full) == 0) len += 8;
            if ((flags & (dst_single | dst_full)) == 0) len += 8;
            return len;
        }

        pub fn decodeEndpoints(flags: u32, src_min: u64, dst_min: u64, src_max_extra: u64, dst_max_extra: u64) !EndpointRanges {
            _ = try endpointExtraLen(flags);
            const src_node_range = if ((flags & src_full) != 0) blk: {
                if (src_min != 0 or src_max_extra != 0) return error.InvalidRecord;
                break :blk Entry.full_node_range;
            } else if ((flags & src_single) != 0) blk: {
                if (src_min == 0 or src_max_extra != 0) return error.InvalidRecord;
                break :blk segment_mod.ImmutableAdjacencySegment.NodeIdRange{ .min = src_min, .max = src_min };
            } else blk: {
                if (src_min == 0 or src_max_extra < src_min) return error.InvalidRecord;
                break :blk segment_mod.ImmutableAdjacencySegment.NodeIdRange{ .min = src_min, .max = src_max_extra };
            };
            const dst_node_range = if ((flags & dst_full) != 0) blk: {
                if (dst_min != 0 or dst_max_extra != 0) return error.InvalidRecord;
                break :blk Entry.full_node_range;
            } else if ((flags & dst_single) != 0) blk: {
                if (dst_min == 0 or dst_max_extra != 0) return error.InvalidRecord;
                break :blk segment_mod.ImmutableAdjacencySegment.NodeIdRange{ .min = dst_min, .max = dst_min };
            } else blk: {
                if (dst_min == 0 or dst_max_extra < dst_min) return error.InvalidRecord;
                break :blk segment_mod.ImmutableAdjacencySegment.NodeIdRange{ .min = dst_min, .max = dst_max_extra };
            };
            return .{ .src_node_range = src_node_range, .dst_node_range = dst_node_range };
        }

        pub fn encodeEntryHeader(entry: Entry, out: *[Manifest.entry_header_len]u8) !void {
            return encodeEntryHeaderForPath(entry, entry.path.len, 0, out);
        }

        pub fn encodeEntryHeaderForPath(entry: Entry, encoded_path_len: usize, extra_flags: u32, out: *[Manifest.entry_header_len]u8) !void {
            if ((extra_flags & ~path_relative) != 0) return error.InvalidRecord;
            if (encoded_path_len > std.math.maxInt(u32)) return error.RecordTooLarge;
            const virtual_entry = entryIsVirtual(entry);
            if (virtual_entry) {
                try validateVirtualEntryShape(entry);
                if (encoded_path_len != 0 or (extra_flags & path_relative) != 0) return error.InvalidRecord;
            } else if (encoded_path_len == 0) return error.RecordTooLarge;
            if (entry.edge_count == 0 or
                entry.edge_id_range.min > entry.edge_id_range.max or
                entry.src_node_range.min > entry.src_node_range.max or
                entry.dst_node_range.min > entry.dst_node_range.max)
            {
                return error.InvalidRecord;
            }
            const run_encoding = try encodeRun(entry);
            const endpoint_encoding = try encodeEndpoints(entry);
            var entry_flags = run_encoding.flags | endpoint_encoding.flags | extra_flags;
            if (virtual_entry) entry_flags |= virtual_singleton;
            if (!canDeriveEdgeCount(entry)) entry_flags |= edge_count_explicit;
            if (!canDeriveEdgeIdDigest(entry)) entry_flags |= edge_digest_explicit;
            if (entry.edge_id_order_digest != 0) entry_flags |= order_digest_explicit;
            std.mem.writeInt(u32, out[0..4], @intCast(encoded_path_len), .little);
            std.mem.writeInt(u32, out[4..8], entry_flags, .little);
            std.mem.writeInt(u64, out[8..16], entry.edge_id_range.min, .little);
            std.mem.writeInt(u64, out[16..24], entry.edge_id_range.max, .little);
        }

        pub fn decodeEntryHeader(bytes: *const [Manifest.entry_header_len]u8) !EntryHeader {
            const entry_flags = std.mem.readInt(u32, bytes[4..8], .little);
            try validateEntryFlags(entry_flags);
            const path_len = std.mem.readInt(u32, bytes[0..4], .little);
            if ((entry_flags & virtual_singleton) != 0) {
                if (path_len != 0) return error.InvalidRecord;
            } else if (path_len == 0) return error.InvalidRecord;
            const edge_id_min = std.mem.readInt(u64, bytes[8..16], .little);
            const edge_id_max = std.mem.readInt(u64, bytes[16..24], .little);
            if (edge_id_min > edge_id_max) return error.InvalidRecord;
            return .{
                .path_len = path_len,
                .edge_id_range = .{ .min = edge_id_min, .max = edge_id_max },
                .entry_flags = entry_flags,
            };
        }

        pub fn updateDigestFields(hasher: *std.hash.Wyhash, entry: anytype) void {
            var bytes: [8]u8 = undefined;
            const values = [_]u64{
                entry.edge_count,
                entry.edge_digest,
                entry.edge_id_range.min,
                entry.edge_id_range.max,
                logicalEdgeIdDigest(entry),
                entry.edge_id_order_digest,
                entry.edge_id_runs.run_count,
                entry.edge_id_runs.first_min,
                entry.edge_id_runs.first_max,
                entry.edge_id_runs.second_min,
                entry.edge_id_runs.second_max,
                entry.src_node_range.min,
                entry.src_node_range.max,
                entry.dst_node_range.min,
                entry.dst_node_range.max,
                if (entry.singleton_rel) |rel| @as(u64, @intFromEnum(rel)) else std.math.maxInt(u64),
            };
            for (values) |value| {
                std.mem.writeInt(u64, &bytes, value, .little);
                hasher.update(&bytes);
            }
        }

        pub fn updateDigestEncodedPath(hasher: *std.hash.Wyhash, path_encoding: PathEncoding) void {
            var bytes: [4]u8 = undefined;
            std.mem.writeInt(u32, &bytes, path_encoding.flags, .little);
            hasher.update(&bytes);
            hasher.update(path_encoding.bytes);
        }

        pub fn ownedLegacyDigest(entries: []const OwnedEntry) u64 {
            var hasher = std.hash.Wyhash.init(0x544B_4D46);
            for (entries) |entry| {
                updateDigestFields(&hasher, entry);
                hasher.update(entry.path);
            }
            return hasher.final();
        }

        fn validateKnownFlags(flags: u32) !void {
            if ((flags & ~known_flags) != 0) return error.InvalidRecord;
        }

        fn validateEntryFlags(flags: u32) !void {
            try validateKnownFlags(flags);
            _ = try orderDigestExtraLen(flags);
            _ = try runExtraLen(flags);
            _ = try edgeCountExtraLen(flags);
            _ = try digestExtraLen(flags);
            _ = try endpointExtraLen(flags);
            _ = try singletonRelExtraLen(flags);
        }

        fn allZero(bytes: []const u8) bool {
            for (bytes) |byte| if (byte != 0) return false;
            return true;
        }
    };
}

const TestCore = struct {
    pub const RelKind = enum(u16) {
        likes = 1,
        follows = 2,
    };
};

const TestSegment = struct {
    pub const Direction = enum { forward, reverse };
    pub const ImmutableAdjacencySegment = struct {
        pub const EdgeIdRange = struct { min: u64, max: u64 };
        pub const NodeIdRange = struct { min: u64, max: u64 };
    };
};

const TestFormat = EdgeSegmentManifestFormat(TestCore, TestSegment);

fn physicalEntry() TestFormat.Entry {
    return .{
        .edge_count = 3,
        .edge_digest = 0x11,
        .edge_id_range = .{ .min = 7, .max = 9 },
        .edge_id_digest = 0x22,
        .edge_id_runs = .{ .run_count = 1, .first_min = 7, .first_max = 9 },
        .path = "/store/edge_segments/segment-1",
    };
}

fn virtualEntry() TestFormat.Entry {
    return .{
        .edge_count = 3,
        .edge_digest = 0x33,
        .edge_id_range = .{ .min = 10, .max = 12 },
        .edge_id_digest = 0x44,
        .edge_id_runs = .{ .run_count = 1, .first_min = 10, .first_max = 12 },
        .src_node_range = .{ .min = 4, .max = 4 },
        .dst_node_range = .{ .min = 20, .max = 22 },
        .singleton_rel = .likes,
        .path = "",
    };
}

test "edge-segment manifest v14 header preserves stable bytes" {
    const entry = physicalEntry();
    var bytes: [TestFormat.Manifest.header_len]u8 = undefined;
    try TestFormat.encodeHeader(&.{entry}, &bytes);
    try std.testing.expectEqualSlices(u8, "TKMS", bytes[0..4]);
    try std.testing.expectEqual(@as(u16, 14), std.mem.readInt(u16, bytes[4..6], .little));
    try std.testing.expectEqual(@as(u16, 24), std.mem.readInt(u16, bytes[6..8], .little));
    try std.testing.expectEqual(@as(u32, 1), std.mem.readInt(u32, bytes[8..12], .little));
    try std.testing.expectEqual(@as(u16, 24), std.mem.readInt(u16, bytes[12..14], .little));
    const decoded = try TestFormat.decodeHeader(&bytes);
    try std.testing.expectEqual(@as(u32, 1), decoded.segment_count);
    try std.testing.expectEqual(@as(u64, 3), decoded.total_edges);
    try std.testing.expectError(error.RecordTooLarge, TestFormat.encodeHeader(&.{}, &bytes));
}

test "edge-segment manifest header rejects corrupt identity and reserved bytes" {
    var bytes: [TestFormat.Manifest.header_len]u8 = undefined;
    try TestFormat.encodeHeader(&.{physicalEntry()}, &bytes);
    var corrupt = bytes;
    corrupt[0] = 'X';
    try std.testing.expectError(error.InvalidRecord, TestFormat.decodeHeader(&corrupt));
    corrupt = bytes;
    corrupt[14] = 1;
    try std.testing.expectError(error.InvalidRecord, TestFormat.decodeHeader(&corrupt));
    corrupt = bytes;
    std.mem.writeInt(u32, corrupt[8..12], 0, .little);
    try std.testing.expectError(error.InvalidRecord, TestFormat.decodeHeader(&corrupt));
}

test "edge-segment manifest entry derives one-run compact fields" {
    const entry = physicalEntry();
    var bytes: [TestFormat.Manifest.entry_header_len]u8 = undefined;
    try TestFormat.encodeEntryHeader(entry, &bytes);
    const decoded = try TestFormat.decodeEntryHeader(&bytes);
    try std.testing.expectEqual(entry.path.len, decoded.path_len);
    try std.testing.expectEqual(entry.edge_id_range.min, decoded.edge_id_range.min);
    try std.testing.expectEqual(entry.edge_id_range.max, decoded.edge_id_range.max);
    try std.testing.expect((decoded.entry_flags & TestFormat.run_from_range) != 0);
    try std.testing.expect((decoded.entry_flags & TestFormat.src_full) != 0);
    try std.testing.expect((decoded.entry_flags & TestFormat.dst_full) != 0);
    try std.testing.expectEqual(@as(usize, 0), try TestFormat.runExtraLen(decoded.entry_flags));
    try std.testing.expectEqual(@as(usize, 0), try TestFormat.edgeCountExtraLen(decoded.entry_flags));
    try std.testing.expectEqual(@as(usize, 0), try TestFormat.digestExtraLen(decoded.entry_flags));
}

test "edge-segment manifest entry separates two-run and explicit fields" {
    var entry = physicalEntry();
    entry.edge_count = 4;
    entry.edge_id_range = .{ .min = 7, .max = 12 };
    entry.edge_id_runs = .{
        .run_count = 2,
        .first_min = 7,
        .first_max = 8,
        .second_min = 11,
        .second_max = 12,
    };
    entry.edge_id_order_digest = 0x55;
    const run = try TestFormat.encodeRun(entry);
    try std.testing.expectEqual(TestFormat.run_two_split, run.flags);
    try std.testing.expectEqual(@as(u64, 8), run.first_max);
    try std.testing.expectEqual(@as(u64, 11), run.second_min);
    const decoded_runs = try TestFormat.decodeRun(entry.edge_count, entry.edge_id_range, run.flags, run.first_max, run.second_min);
    try std.testing.expectEqualDeep(entry.edge_id_runs, decoded_runs);

    var bytes: [TestFormat.Manifest.entry_header_len]u8 = undefined;
    try TestFormat.encodeEntryHeader(entry, &bytes);
    const flags = std.mem.readInt(u32, bytes[4..8], .little);
    try std.testing.expectEqual(@as(usize, 16), try TestFormat.runExtraLen(flags));
    try std.testing.expectEqual(@as(usize, 0), try TestFormat.edgeCountExtraLen(flags));
    try std.testing.expectEqual(@as(usize, 8), try TestFormat.digestExtraLen(flags));
    try std.testing.expectEqual(@as(usize, 8), try TestFormat.orderDigestExtraLen(flags));

    entry.edge_id_runs = .{};
    entry.edge_id_order_digest = 0;
    try TestFormat.encodeEntryHeader(entry, &bytes);
    const explicit_flags = std.mem.readInt(u32, bytes[4..8], .little);
    try std.testing.expectEqual(@as(usize, 8), try TestFormat.edgeCountExtraLen(explicit_flags));
    try std.testing.expectEqual(@as(usize, 8), try TestFormat.digestExtraLen(explicit_flags));
    try std.testing.expectError(error.InvalidRecord, TestFormat.runExtraLen(TestFormat.run_from_range | TestFormat.run_two_split));
}

test "edge-segment manifest endpoint encoding preserves full singleton and ranges" {
    var entry = physicalEntry();
    const full = try TestFormat.encodeEndpoints(entry);
    try std.testing.expectEqual(TestFormat.src_full | TestFormat.dst_full, full.flags);
    const full_decoded = try TestFormat.decodeEndpoints(full.flags, full.src_min, full.dst_min, full.src_max, full.dst_max);
    try std.testing.expectEqualDeep(entry.src_node_range, full_decoded.src_node_range);
    try std.testing.expectEqualDeep(entry.dst_node_range, full_decoded.dst_node_range);

    entry.src_node_range = .{ .min = 4, .max = 4 };
    entry.dst_node_range = .{ .min = 20, .max = 30 };
    const mixed = try TestFormat.encodeEndpoints(entry);
    try std.testing.expect((mixed.flags & TestFormat.src_single) != 0);
    try std.testing.expectEqual(@as(usize, 24), try TestFormat.endpointExtraLen(mixed.flags));
    const decoded = try TestFormat.decodeEndpoints(mixed.flags, mixed.src_min, mixed.dst_min, mixed.src_max, mixed.dst_max);
    try std.testing.expectEqualDeep(entry.src_node_range, decoded.src_node_range);
    try std.testing.expectEqualDeep(entry.dst_node_range, decoded.dst_node_range);
    try std.testing.expectError(error.InvalidRecord, TestFormat.endpointExtraLen(TestFormat.src_single | TestFormat.src_full));
}

test "edge-segment manifest relative paths reject cross-platform traversal" {
    try std.testing.expect(TestFormat.safeRelativePath("segment-1/data.bin"));
    try std.testing.expect(TestFormat.safeRelativePath("segment-1\\data.bin"));
    try std.testing.expect(!TestFormat.safeRelativePath(""));
    try std.testing.expect(!TestFormat.safeRelativePath("/absolute"));
    try std.testing.expect(!TestFormat.safeRelativePath("C:\\absolute"));
    try std.testing.expect(!TestFormat.safeRelativePath("segment/../escape"));
    try std.testing.expect(!TestFormat.safeRelativePath("segment\\..\\escape"));
    try std.testing.expect(!TestFormat.safeRelativePath("segment//double"));
    try std.testing.expect(!TestFormat.safeRelativePath("segment/"));
}

test "edge-segment manifest virtual shape rejects paths order and range drift" {
    var entry = virtualEntry();
    try TestFormat.validateVirtualEntryShape(entry);
    var bytes: [TestFormat.Manifest.entry_header_len]u8 = undefined;
    try TestFormat.encodeEntryHeader(entry, &bytes);
    const decoded = try TestFormat.decodeEntryHeader(&bytes);
    try std.testing.expect((decoded.entry_flags & TestFormat.virtual_singleton) != 0);
    try std.testing.expectEqual(@as(u32, 0), decoded.path_len);
    try std.testing.expectEqual(@as(usize, 2), try TestFormat.singletonRelExtraLen(decoded.entry_flags));

    entry.path = "not-empty";
    try std.testing.expectError(error.InvalidRecord, TestFormat.validateVirtualEntryShape(entry));
    entry = virtualEntry();
    entry.edge_id_order_digest = 1;
    try std.testing.expectError(error.InvalidRecord, TestFormat.validateVirtualEntryShape(entry));
    entry = virtualEntry();
    entry.dst_node_range.max += 1;
    try std.testing.expectError(error.InvalidRecord, TestFormat.validateVirtualEntryShape(entry));
}

test "edge-segment manifest digest normalizes derived ids and encodes path shape" {
    const first = physicalEntry();
    var second = first;
    second.edge_id_digest +%= 1;
    var first_hasher = std.hash.Wyhash.init(0x544B_4D46);
    TestFormat.updateDigestFields(&first_hasher, first);
    TestFormat.updateDigestEncodedPath(&first_hasher, .{ .flags = TestFormat.path_relative, .bytes = "segment-1" });
    var second_hasher = std.hash.Wyhash.init(0x544B_4D46);
    TestFormat.updateDigestFields(&second_hasher, second);
    TestFormat.updateDigestEncodedPath(&second_hasher, .{ .flags = TestFormat.path_relative, .bytes = "segment-1" });
    try std.testing.expectEqual(first_hasher.final(), second_hasher.final());

    second.edge_id_order_digest = 1;
    var explicit_hasher = std.hash.Wyhash.init(0x544B_4D46);
    TestFormat.updateDigestFields(&explicit_hasher, second);
    TestFormat.updateDigestEncodedPath(&explicit_hasher, .{ .flags = TestFormat.path_relative, .bytes = "segment-1" });
    try std.testing.expect(first_hasher.final() != explicit_hasher.final());

    const first_path = try std.testing.allocator.dupe(u8, first.path);
    defer std.testing.allocator.free(first_path);
    const owned = TestFormat.OwnedEntry{
        .edge_count = first.edge_count,
        .edge_digest = first.edge_digest,
        .edge_id_range = first.edge_id_range,
        .edge_id_digest = first.edge_id_digest,
        .edge_id_runs = first.edge_id_runs,
        .src_node_range = first.src_node_range,
        .dst_node_range = first.dst_node_range,
        .path = first_path,
    };
    try std.testing.expect(TestFormat.ownedLegacyDigest(&.{owned}) != first_hasher.final());
}

test "edge-segment manifest owns paths and validates aggregate totals" {
    var manifest = TestFormat.Manifest{};
    defer manifest.deinit(std.testing.allocator);
    const entry = physicalEntry();
    try manifest.entries.append(std.testing.allocator, .{
        .edge_count = entry.edge_count,
        .edge_digest = entry.edge_digest,
        .edge_id_range = entry.edge_id_range,
        .edge_id_digest = entry.edge_id_digest,
        .edge_id_runs = entry.edge_id_runs,
        .src_node_range = entry.src_node_range,
        .dst_node_range = entry.dst_node_range,
        .path = try std.testing.allocator.dupe(u8, entry.path),
    });
    try std.testing.expectEqual(@as(u64, 3), manifest.totalEdgeCount());
    try std.testing.expectEqual(@as(?u64, 3), TestFormat.ownedTotalEdges(manifest.entries.items));

    const empty_path = try std.testing.allocator.alloc(u8, 0);
    defer std.testing.allocator.free(empty_path);
    var invalid = manifest.entries.items[0];
    invalid.path = empty_path;
    try std.testing.expectEqual(@as(?u64, null), TestFormat.ownedTotalEdges(&.{invalid}));
}
