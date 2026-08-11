const std = @import("std");

/// Persistent index-checkpoint bytes and the compact edge-id run summary
/// embedded in that checkpoint. File I/O, cache freshness, repair, and
/// publication remain owned by the storage facade.
pub const IndexMetaFormat = struct {
    pub const EdgeSegmentIdRunSummary = struct {
        run_count: u64 = 0,
        first_min: u64 = 0,
        first_max: u64 = 0,
        second_min: u64 = 0,
        second_max: u64 = 0,

        pub fn validate(self: EdgeSegmentIdRunSummary) !void {
            switch (self.run_count) {
                0 => {
                    if (self.first_min != 0 or self.first_max != 0 or self.second_min != 0 or self.second_max != 0) return error.InvalidRecord;
                },
                1 => {
                    if (self.first_min > self.first_max) return error.InvalidRecord;
                    if (self.second_min != 0 or self.second_max != 0) return error.InvalidRecord;
                },
                2 => {
                    if (self.first_min > self.first_max or self.second_min > self.second_max) return error.InvalidRecord;
                    if (self.first_max == std.math.maxInt(u64) or self.second_min <= self.first_max + 1) return error.InvalidRecord;
                },
                else => return error.InvalidRecord,
            }
        }

        pub fn contains(self: EdgeSegmentIdRunSummary, edge_id: u64) bool {
            if (self.run_count == 0) return false;
            if (edge_id >= self.first_min and edge_id <= self.first_max) return true;
            return self.run_count == 2 and edge_id >= self.second_min and edge_id <= self.second_max;
        }

        pub fn coveredCount(self: EdgeSegmentIdRunSummary) !u64 {
            try self.validate();
            if (self.run_count == 0) return 0;
            const first = std.math.add(u64, self.first_max - self.first_min, 1) catch return error.InvalidRecord;
            if (self.run_count == 1) return first;
            const second = std.math.add(u64, self.second_max - self.second_min, 1) catch return error.InvalidRecord;
            return std.math.add(u64, first, second) catch return error.InvalidRecord;
        }

        pub fn intersectsSortedIds(self: EdgeSegmentIdRunSummary, ids_by_id: []const u64) bool {
            if (self.run_count == 0 or ids_by_id.len == 0) return false;
            const first_start = lowerBoundU64(ids_by_id, self.first_min);
            if (first_start < ids_by_id.len and ids_by_id[first_start] <= self.first_max) return true;
            if (self.run_count != 2) return false;
            const second_start = lowerBoundU64(ids_by_id, self.second_min);
            return second_start < ids_by_id.len and ids_by_id[second_start] <= self.second_max;
        }

        pub fn intersectingSortedIdCount(self: EdgeSegmentIdRunSummary, ids_by_id: []const u64) usize {
            if (self.run_count == 0 or ids_by_id.len == 0) return 0;
            var count: usize = 0;
            const first_start = lowerBoundU64(ids_by_id, self.first_min);
            if (first_start < ids_by_id.len) {
                const first_end = upperBoundU64(ids_by_id, self.first_max);
                if (first_end > first_start) count += first_end - first_start;
            }
            if (self.run_count == 2) {
                const second_start = lowerBoundU64(ids_by_id, self.second_min);
                if (second_start < ids_by_id.len) {
                    const second_end = upperBoundU64(ids_by_id, self.second_max);
                    if (second_end > second_start) count += second_end - second_start;
                }
            }
            return count;
        }
    };

    pub const IndexMeta = struct {
        event_bytes: u64 = 0,
        nodes: u64 = 0,
        edges: u64 = 0,
        node_digest: u64 = 0,
        edge_digest: u64 = 0,
        node_by_text_order_digest: u64 = 0,
        edge_indexed_edges: u64 = 0,
        edge_index_digest: u64 = 0,
        edge_by_id_order_digest: u64 = 0,
        edge_by_src_order_digest: u64 = 0,
        edge_by_dst_order_digest: u64 = 0,
        max_edge_id_seen: u64 = 0,
        edge_by_id_runs: EdgeSegmentIdRunSummary = .{},
        edge_segment_edges: u64 = 0,
        edge_segment_manifest_digest: u64 = 0,
        edge_segment_id_runs: EdgeSegmentIdRunSummary = .{},
    };

    const magic = [_]u8{ 'T', 'K', 'G', 'I' };
    const version: u16 = 9;
    pub const encoded_len: usize = 200;

    pub fn encode(meta: IndexMeta, out: *[encoded_len]u8) void {
        @memcpy(out[0..4], &magic);
        std.mem.writeInt(u16, out[4..6], version, .little);
        std.mem.writeInt(u16, out[6..8], encoded_len, .little);
        std.mem.writeInt(u64, out[8..16], meta.event_bytes, .little);
        std.mem.writeInt(u64, out[16..24], meta.nodes, .little);
        std.mem.writeInt(u64, out[24..32], meta.edges, .little);
        std.mem.writeInt(u64, out[32..40], meta.node_digest, .little);
        std.mem.writeInt(u64, out[40..48], meta.edge_digest, .little);
        std.mem.writeInt(u64, out[48..56], meta.node_by_text_order_digest, .little);
        std.mem.writeInt(u64, out[56..64], meta.edge_indexed_edges, .little);
        std.mem.writeInt(u64, out[64..72], meta.edge_index_digest, .little);
        std.mem.writeInt(u64, out[72..80], meta.edge_by_id_order_digest, .little);
        std.mem.writeInt(u64, out[80..88], meta.edge_by_src_order_digest, .little);
        std.mem.writeInt(u64, out[88..96], meta.edge_by_dst_order_digest, .little);
        std.mem.writeInt(u64, out[96..104], meta.max_edge_id_seen, .little);
        std.mem.writeInt(u64, out[104..112], meta.edge_by_id_runs.run_count, .little);
        std.mem.writeInt(u64, out[112..120], meta.edge_by_id_runs.first_min, .little);
        std.mem.writeInt(u64, out[120..128], meta.edge_by_id_runs.first_max, .little);
        std.mem.writeInt(u64, out[128..136], meta.edge_by_id_runs.second_min, .little);
        std.mem.writeInt(u64, out[136..144], meta.edge_by_id_runs.second_max, .little);
        std.mem.writeInt(u64, out[144..152], meta.edge_segment_edges, .little);
        std.mem.writeInt(u64, out[152..160], meta.edge_segment_manifest_digest, .little);
        std.mem.writeInt(u64, out[160..168], meta.edge_segment_id_runs.run_count, .little);
        std.mem.writeInt(u64, out[168..176], meta.edge_segment_id_runs.first_min, .little);
        std.mem.writeInt(u64, out[176..184], meta.edge_segment_id_runs.first_max, .little);
        std.mem.writeInt(u64, out[184..192], meta.edge_segment_id_runs.second_min, .little);
        std.mem.writeInt(u64, out[192..200], meta.edge_segment_id_runs.second_max, .little);
    }

    pub fn decode(bytes: *const [encoded_len]u8) !IndexMeta {
        if (!std.mem.eql(u8, bytes[0..4], &magic)) return error.InvalidRecord;
        if (std.mem.readInt(u16, bytes[4..6], .little) != version) return error.InvalidRecord;
        if (std.mem.readInt(u16, bytes[6..8], .little) != encoded_len) return error.InvalidRecord;
        const edge_by_id_runs = EdgeSegmentIdRunSummary{
            .run_count = std.mem.readInt(u64, bytes[104..112], .little),
            .first_min = std.mem.readInt(u64, bytes[112..120], .little),
            .first_max = std.mem.readInt(u64, bytes[120..128], .little),
            .second_min = std.mem.readInt(u64, bytes[128..136], .little),
            .second_max = std.mem.readInt(u64, bytes[136..144], .little),
        };
        try edge_by_id_runs.validate();
        const edge_segment_id_runs = EdgeSegmentIdRunSummary{
            .run_count = std.mem.readInt(u64, bytes[160..168], .little),
            .first_min = std.mem.readInt(u64, bytes[168..176], .little),
            .first_max = std.mem.readInt(u64, bytes[176..184], .little),
            .second_min = std.mem.readInt(u64, bytes[184..192], .little),
            .second_max = std.mem.readInt(u64, bytes[192..200], .little),
        };
        try edge_segment_id_runs.validate();
        const edge_segment_edges = std.mem.readInt(u64, bytes[144..152], .little);
        if (edge_segment_edges == 0 and
            (std.mem.readInt(u64, bytes[152..160], .little) != 0 or edge_segment_id_runs.run_count != 0))
        {
            return error.InvalidRecord;
        }
        return .{
            .event_bytes = std.mem.readInt(u64, bytes[8..16], .little),
            .nodes = std.mem.readInt(u64, bytes[16..24], .little),
            .edges = std.mem.readInt(u64, bytes[24..32], .little),
            .node_digest = std.mem.readInt(u64, bytes[32..40], .little),
            .edge_digest = std.mem.readInt(u64, bytes[40..48], .little),
            .node_by_text_order_digest = std.mem.readInt(u64, bytes[48..56], .little),
            .edge_indexed_edges = std.mem.readInt(u64, bytes[56..64], .little),
            .edge_index_digest = std.mem.readInt(u64, bytes[64..72], .little),
            .edge_by_id_order_digest = std.mem.readInt(u64, bytes[72..80], .little),
            .edge_by_src_order_digest = std.mem.readInt(u64, bytes[80..88], .little),
            .edge_by_dst_order_digest = std.mem.readInt(u64, bytes[88..96], .little),
            .max_edge_id_seen = std.mem.readInt(u64, bytes[96..104], .little),
            .edge_by_id_runs = edge_by_id_runs,
            .edge_segment_edges = edge_segment_edges,
            .edge_segment_manifest_digest = std.mem.readInt(u64, bytes[152..160], .little),
            .edge_segment_id_runs = edge_segment_id_runs,
        };
    }

    fn lowerBoundU64(items: []const u64, needle: u64) usize {
        var lo: usize = 0;
        var hi: usize = items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (items[mid] < needle) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        return lo;
    }

    fn upperBoundU64(items: []const u64, needle: u64) usize {
        var lo: usize = 0;
        var hi: usize = items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (items[mid] <= needle) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        return lo;
    }
};

test "index meta round trips stable bytes" {
    const Format = IndexMetaFormat;
    const meta = Format.IndexMeta{
        .event_bytes = 1,
        .nodes = 2,
        .edges = 3,
        .node_digest = 4,
        .edge_digest = 5,
        .node_by_text_order_digest = 6,
        .edge_indexed_edges = 7,
        .edge_index_digest = 8,
        .edge_by_id_order_digest = 9,
        .edge_by_src_order_digest = 10,
        .edge_by_dst_order_digest = 11,
        .max_edge_id_seen = 12,
        .edge_by_id_runs = .{ .run_count = 2, .first_min = 1, .first_max = 3, .second_min = 8, .second_max = 9 },
        .edge_segment_edges = 5,
        .edge_segment_manifest_digest = 13,
        .edge_segment_id_runs = .{ .run_count = 1, .first_min = 20, .first_max = 24 },
    };
    var bytes: [Format.encoded_len]u8 = undefined;
    Format.encode(meta, &bytes);

    try std.testing.expectEqualSlices(u8, "TKGI", bytes[0..4]);
    try std.testing.expectEqual(@as(u16, 9), std.mem.readInt(u16, bytes[4..6], .little));
    try std.testing.expectEqual(@as(u16, Format.encoded_len), std.mem.readInt(u16, bytes[6..8], .little));
    try std.testing.expectEqualDeep(meta, try Format.decode(&bytes));
}

test "index meta rejects corrupt identity and run summaries" {
    const Format = IndexMetaFormat;
    var bytes: [Format.encoded_len]u8 = undefined;
    Format.encode(.{}, &bytes);

    var corrupt = bytes;
    corrupt[0] = 'X';
    try std.testing.expectError(error.InvalidRecord, Format.decode(&corrupt));

    corrupt = bytes;
    std.mem.writeInt(u64, corrupt[104..112], 3, .little);
    try std.testing.expectError(error.InvalidRecord, Format.decode(&corrupt));

    corrupt = bytes;
    std.mem.writeInt(u64, corrupt[152..160], 1, .little);
    try std.testing.expectError(error.InvalidRecord, Format.decode(&corrupt));
}

test "edge id run summary validates canonical ranges" {
    const Summary = IndexMetaFormat.EdgeSegmentIdRunSummary;
    try (Summary{}).validate();
    try std.testing.expectEqual(@as(u64, 0), try (Summary{}).coveredCount());
    try std.testing.expectEqual(@as(u64, 7), try (Summary{
        .run_count = 2,
        .first_min = 2,
        .first_max = 4,
        .second_min = 9,
        .second_max = 12,
    }).coveredCount());
    try std.testing.expectError(error.InvalidRecord, (Summary{ .run_count = 0, .first_min = 1 }).validate());
    try std.testing.expectError(error.InvalidRecord, (Summary{ .run_count = 1, .first_min = 2, .first_max = 1 }).validate());
    try std.testing.expectError(error.InvalidRecord, (Summary{ .run_count = 2, .first_min = 1, .first_max = 2, .second_min = 3, .second_max = 4 }).validate());
}

test "edge id run summary answers containment and intersections" {
    const summary = IndexMetaFormat.EdgeSegmentIdRunSummary{
        .run_count = 2,
        .first_min = 2,
        .first_max = 4,
        .second_min = 9,
        .second_max = 12,
    };
    try std.testing.expect(summary.contains(3));
    try std.testing.expect(!summary.contains(8));
    try std.testing.expect(summary.intersectsSortedIds(&.{ 1, 8, 10, 20 }));
    try std.testing.expect(!summary.intersectsSortedIds(&.{ 1, 8, 20 }));
    try std.testing.expectEqual(@as(usize, 4), summary.intersectingSortedIdCount(&.{ 1, 2, 4, 8, 9, 12, 20 }));
}
