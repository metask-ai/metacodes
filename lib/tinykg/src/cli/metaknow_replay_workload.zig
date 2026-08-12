const std = @import("std");
const core = @import("../core.zig");
const graph = @import("../graph.zig");
const schema = @import("../schema.zig");
const storage = @import("../storage.zig");

/// Shared Metaknow replay ingestion and shaping subsystem.  The benchmark and
/// the transactional CLI importer deliberately share this owner so parsing,
/// endpoint admission and batch materialization cannot drift independently.
pub const MetaknowReplayWorkload = struct {
    const jsonl_max_bytes: u64 = 256 * 1024 * 1024;
    const manifest_max_bytes: u64 = 1024 * 1024;
    const text_density_histogram_len: usize = 128 * 1024;

    const MetaknowNodeJson = struct {
        id: []const u8,
        kind: ?[]const u8 = null,
        title: ?[]const u8 = null,
        name: ?[]const u8 = null,
        summary: ?[]const u8 = null,
        description: ?[]const u8 = null,
        fragment: ?[]const u8 = null,
        properties: ?[]const u8 = null,
        text: ?[]const u8 = null,
    };

    const MetaknowEdgeJson = struct {
        src: []const u8,
        dst: []const u8,
        rel: ?[]const u8 = null,
        relation: ?[]const u8 = null,
    };

    const MetaknowDeferredBasedOnJson = struct {
        fragment_id: []const u8,
        dst_ids: []const []const u8 = &.{},
    };

    const MetaknowManifestJson = struct {
        based_on_materialize_threshold: ?usize = null,
        based_on_materialized_edges: ?usize = null,
        based_on_deferred_edges: ?usize = null,
        based_on_deferred_fragment_count: ?usize = null,
        based_on_document_container_skipped_edges: ?usize = null,
        deferred_based_on_rows: ?usize = null,
        deferred_based_on_bytes: ?usize = null,
    };

    const NativeJsonlNodeJson = struct {
        id: u64,
        kind: []const u8,
        text: []const u8,
    };

    const NativeJsonlEdgeJson = struct {
        id: u64,
        src: u64,
        rel: []const u8,
        dst: u64,
    };

    const NativeJsonlDeferredBasedOnJson = struct {
        src: u64,
        dst: u64,
    };

    const InputShape = enum {
        metaknow_export,
        native_jsonl,
    };

    const LineFile = struct {
        bytes: []u8 = &.{},
        records: []const []const u8 = &.{},

        fn deinit(self: LineFile, allocator: std.mem.Allocator) void {
            if (self.records.len != 0) allocator.free(self.records);
            if (self.bytes.len != 0) allocator.free(self.bytes);
        }
    };

    pub const ManifestStats = struct {
        based_on_materialize_threshold: usize = 0,
        based_on_materialized_edges: usize = 0,
        based_on_deferred_edges: usize = 0,
        based_on_deferred_fragment_count: usize = 0,
        based_on_document_container_skipped_edges: usize = 0,
        deferred_based_on_rows: usize = 0,
        deferred_based_on_bytes: usize = 0,
    };

    pub const Node = struct {
        original_id: []u8,
        kind: core.NodeKind,
        text: []u8,

        fn deinit(self: Node, allocator: std.mem.Allocator) void {
            allocator.free(self.original_id);
            allocator.free(self.text);
        }
    };

    pub const Edge = struct {
        src_original_id: []u8,
        dst_original_id: []u8,
        rel: core.RelKind,

        fn deinit(self: Edge, allocator: std.mem.Allocator) void {
            allocator.free(self.src_original_id);
            allocator.free(self.dst_original_id);
        }
    };

    pub const DeferredBasedOnRow = struct {
        fragment_original_id: []u8,
        dst_original_ids: [][]u8,

        fn deinit(self: DeferredBasedOnRow, allocator: std.mem.Allocator) void {
            allocator.free(self.fragment_original_id);
            for (self.dst_original_ids) |id| allocator.free(id);
            if (self.dst_original_ids.len != 0) allocator.free(self.dst_original_ids);
        }
    };

    pub const OutputStats = struct {
        nodes_loaded: usize = 0,
        edges_loaded: usize = 0,
        nodes_used: usize = 0,
        manifest: ManifestStats = .{},
    };

    pub const EdgeStats = struct {
        edges_used: usize = 0,
        edges_skipped_missing_endpoint: usize = 0,
        relation_contains: usize = 0,
        relation_mentions: usize = 0,
        relation_depends_on: usize = 0,
        relation_blocks: usize = 0,
        relation_evidences: usize = 0,
        relation_based_on: usize = 0,
        relation_references: usize = 0,
        relation_precedes: usize = 0,
        relation_related_to: usize = 0,
        relation_other: usize = 0,
        deferred_based_on_binary_sources: usize = 0,
        deferred_based_on_binary_links: usize = 0,
        deferred_based_on_binary_bytes: u64 = 0,

        pub fn recordRelation(self: *EdgeStats, rel: core.RelKind) void {
            switch (rel) {
                .contains => self.relation_contains += 1,
                .mentions => self.relation_mentions += 1,
                .depends_on => self.relation_depends_on += 1,
                .blocks => self.relation_blocks += 1,
                .evidences => self.relation_evidences += 1,
                .based_on => self.relation_based_on += 1,
                .references => self.relation_references += 1,
                .precedes => self.relation_precedes += 1,
                .related_to => self.relation_related_to += 1,
                else => self.relation_other += 1,
            }
        }
    };

    pub const Replay = struct {
        nodes: []Node = &.{},
        edges: []Edge = &.{},
        deferred_based_on: []DeferredBasedOnRow = &.{},
        manifest: ManifestStats = .{},

        pub fn deinit(self: Replay, allocator: std.mem.Allocator) void {
            for (self.nodes) |node| node.deinit(allocator);
            for (self.edges) |edge| edge.deinit(allocator);
            for (self.deferred_based_on) |row| row.deinit(allocator);
            if (self.nodes.len != 0) allocator.free(self.nodes);
            if (self.edges.len != 0) allocator.free(self.edges);
            if (self.deferred_based_on.len != 0) allocator.free(self.deferred_based_on);
        }

        pub fn statsForOutput(self: Replay, nodes_used: usize, shaped: bool) OutputStats {
            return .{
                .nodes_loaded = self.nodes.len,
                .edges_loaded = self.edges.len,
                .nodes_used = if (shaped) nodes_used else @min(nodes_used, self.nodes.len),
                .manifest = self.manifest,
            };
        }
    };

    pub const NodeLoadTimings = struct {
        generate_texts_ns: u128 = 0,
        store_append_ns: u128 = 0,
    };

    pub const TextDensityStats = struct {
        node_count: u64 = 0,
        meaningful_text_bytes: u64 = 0,
        max_meaningful_text_bytes: u64 = 0,
        histogram: [text_density_histogram_len]u32 = [_]u32{0} ** text_density_histogram_len,

        pub fn record(self: *TextDensityStats, byte_len: usize) !void {
            self.node_count = std.math.add(u64, self.node_count, 1) catch return error.RecordTooLarge;
            self.meaningful_text_bytes = std.math.add(u64, self.meaningful_text_bytes, @intCast(byte_len)) catch return error.RecordTooLarge;
            self.max_meaningful_text_bytes = @max(self.max_meaningful_text_bytes, @as(u64, @intCast(byte_len)));
            const bucket = @min(byte_len, text_density_histogram_len - 1);
            self.histogram[bucket] = std.math.add(u32, self.histogram[bucket], 1) catch return error.RecordTooLarge;
        }

        pub fn percentile(self: TextDensityStats, percentile_value: u64) u64 {
            if (self.node_count == 0) return 0;
            const rank = ((self.node_count - 1) * percentile_value) / 100;
            var seen: u64 = 0;
            for (self.histogram, 0..) |count, byte_len| {
                if (count == 0) continue;
                seen += count;
                if (seen > rank) return @intCast(byte_len);
            }
            return text_density_histogram_len - 1;
        }
    };

    pub fn load(allocator: std.mem.Allocator, io: std.Io, dir_path: []const u8) !Replay {
        const nodes_path = try std.fs.path.join(allocator, &.{ dir_path, "nodes.jsonl" });
        defer allocator.free(nodes_path);
        const edges_path = try std.fs.path.join(allocator, &.{ dir_path, "edges.jsonl" });
        defer allocator.free(edges_path);
        const manifest_path = try std.fs.path.join(allocator, &.{ dir_path, "manifest.json" });
        defer allocator.free(manifest_path);
        const deferred_based_on_path = try std.fs.path.join(allocator, &.{ dir_path, "deferred_based_on.jsonl" });
        defer allocator.free(deferred_based_on_path);

        const node_lines = try loadLineFile(allocator, io, nodes_path, jsonl_max_bytes);
        defer node_lines.deinit(allocator);
        const edge_lines = try loadLineFile(allocator, io, edges_path, jsonl_max_bytes);
        defer edge_lines.deinit(allocator);
        const input_shape = try detectInputShape(allocator, node_lines.records, edge_lines.records);
        const manifest = if (try fileExists(io, manifest_path))
            try loadManifest(allocator, io, manifest_path)
        else switch (input_shape) {
            .native_jsonl => ManifestStats{},
            .metaknow_export => return error.FileNotFound,
        };

        var nodes = std.ArrayList(Node).empty;
        errdefer {
            for (nodes.items) |node| node.deinit(allocator);
            nodes.deinit(allocator);
        }
        try nodes.ensureTotalCapacity(allocator, node_lines.records.len);

        var seen_ids = std.StringHashMap(void).init(allocator);
        defer seen_ids.deinit();
        try seen_ids.ensureTotalCapacity(@intCast(node_lines.records.len));

        for (node_lines.records) |line| {
            switch (input_shape) {
                .metaknow_export => {
                    var parsed = try std.json.parseFromSlice(MetaknowNodeJson, allocator, line, .{
                        .ignore_unknown_fields = true,
                        .allocate = .alloc_always,
                    });
                    defer parsed.deinit();
                    if (parsed.value.id.len == 0 or seen_ids.contains(parsed.value.id)) return error.InvalidRecord;
                    const original_id = try allocator.dupe(u8, parsed.value.id);
                    errdefer allocator.free(original_id);
                    try seen_ids.put(original_id, {});
                    const text = try metaknowNodeText(allocator, parsed.value);
                    errdefer allocator.free(text);
                    if (text.len == 0) return error.InvalidRecord;
                    try nodes.append(allocator, .{
                        .original_id = original_id,
                        .kind = metaknowNodeKind(parsed.value.kind),
                        .text = text,
                    });
                },
                .native_jsonl => {
                    var parsed = try std.json.parseFromSlice(NativeJsonlNodeJson, allocator, line, .{
                        .ignore_unknown_fields = true,
                        .allocate = .alloc_always,
                    });
                    defer parsed.deinit();
                    if (parsed.value.id == 0 or parsed.value.text.len == 0) return error.InvalidRecord;
                    const original_id = try replayIdFromU64(allocator, parsed.value.id);
                    errdefer allocator.free(original_id);
                    if (seen_ids.contains(original_id)) return error.InvalidRecord;
                    try seen_ids.put(original_id, {});
                    const text = try allocator.dupe(u8, parsed.value.text);
                    errdefer allocator.free(text);
                    try nodes.append(allocator, .{
                        .original_id = original_id,
                        .kind = parseNodeKind(parsed.value.kind) orelse return error.InvalidNodeKind,
                        .text = text,
                    });
                },
            }
        }

        var edges = std.ArrayList(Edge).empty;
        errdefer {
            for (edges.items) |edge| edge.deinit(allocator);
            edges.deinit(allocator);
        }
        try edges.ensureTotalCapacity(allocator, edge_lines.records.len);

        for (edge_lines.records) |line| {
            switch (input_shape) {
                .metaknow_export => {
                    var parsed = try std.json.parseFromSlice(MetaknowEdgeJson, allocator, line, .{
                        .ignore_unknown_fields = true,
                        .allocate = .alloc_always,
                    });
                    defer parsed.deinit();
                    if (parsed.value.src.len == 0 or parsed.value.dst.len == 0) return error.InvalidRecord;
                    const src = try allocator.dupe(u8, parsed.value.src);
                    errdefer allocator.free(src);
                    const dst = try allocator.dupe(u8, parsed.value.dst);
                    errdefer allocator.free(dst);
                    try edges.append(allocator, .{
                        .src_original_id = src,
                        .dst_original_id = dst,
                        .rel = metaknowRelKind(parsed.value.rel orelse parsed.value.relation),
                    });
                },
                .native_jsonl => {
                    var parsed = try std.json.parseFromSlice(NativeJsonlEdgeJson, allocator, line, .{
                        .ignore_unknown_fields = true,
                        .allocate = .alloc_always,
                    });
                    defer parsed.deinit();
                    if (parsed.value.id == 0 or parsed.value.src == 0 or parsed.value.dst == 0) return error.InvalidRecord;
                    const src = try replayIdFromU64(allocator, parsed.value.src);
                    errdefer allocator.free(src);
                    const dst = try replayIdFromU64(allocator, parsed.value.dst);
                    errdefer allocator.free(dst);
                    try edges.append(allocator, .{
                        .src_original_id = src,
                        .dst_original_id = dst,
                        .rel = parseRelKind(parsed.value.rel) orelse return error.InvalidRelKind,
                    });
                },
            }
        }

        var deferred_based_on = std.ArrayList(DeferredBasedOnRow).empty;
        errdefer {
            for (deferred_based_on.items) |row| row.deinit(allocator);
            deferred_based_on.deinit(allocator);
        }
        if (manifest.deferred_based_on_rows != 0 or (input_shape == .native_jsonl and try fileExists(io, deferred_based_on_path))) {
            const deferred_lines = try loadLineFile(allocator, io, deferred_based_on_path, jsonl_max_bytes);
            defer deferred_lines.deinit(allocator);
            if (input_shape == .metaknow_export and deferred_lines.records.len != manifest.deferred_based_on_rows) return error.InvalidRecord;
            try deferred_based_on.ensureTotalCapacity(allocator, deferred_lines.records.len);
            for (deferred_lines.records) |line| {
                switch (input_shape) {
                    .metaknow_export => try appendMetaknowDeferredRow(allocator, &deferred_based_on, line),
                    .native_jsonl => try appendNativeDeferredRow(allocator, &deferred_based_on, line),
                }
            }
        }

        const native_deferred_rows = deferred_based_on.items.len;
        const native_deferred_bytes = if (input_shape == .native_jsonl and manifest.deferred_based_on_rows == 0 and native_deferred_rows != 0)
            try fileSize(io, deferred_based_on_path)
        else
            0;
        var result = Replay{};
        errdefer result.deinit(allocator);
        result.nodes = try nodes.toOwnedSlice(allocator);
        result.edges = try edges.toOwnedSlice(allocator);
        result.deferred_based_on = try deferred_based_on.toOwnedSlice(allocator);
        result.manifest = if (native_deferred_bytes != 0) updated: {
            var next = manifest;
            next.deferred_based_on_rows = native_deferred_rows;
            next.deferred_based_on_bytes = @intCast(native_deferred_bytes);
            break :updated next;
        } else manifest;
        return result;
    }

    pub fn planEdges(allocator: std.mem.Allocator, replay: *const Replay) !EdgeStats {
        var id_map = try buildNodeIdMap(allocator, replay);
        defer id_map.deinit();
        var stats = EdgeStats{};
        for (replay.edges) |edge| {
            if (!id_map.contains(edge.src_original_id) or !id_map.contains(edge.dst_original_id)) {
                stats.edges_skipped_missing_endpoint += 1;
                continue;
            }
            stats.edges_used += 1;
            stats.recordRelation(edge.rel);
        }
        return stats;
    }

    pub fn buildNodeIdMap(allocator: std.mem.Allocator, replay: *const Replay) !std.StringHashMap(u64) {
        var map = std.StringHashMap(u64).init(allocator);
        errdefer map.deinit();
        try map.ensureTotalCapacity(@intCast(replay.nodes.len));
        for (replay.nodes, 0..) |node, index| try map.put(node.original_id, @intCast(index + 1));
        return map;
    }

    pub fn appendNodesChunked(
        allocator: std.mem.Allocator,
        store: storage.Store,
        replay: *const Replay,
        node_count: usize,
        chunk_size: usize,
        shaped: bool,
        text_density: *TextDensityStats,
        timings: *NodeLoadTimings,
    ) !void {
        if (replay.nodes.len == 0 or chunk_size == 0) return error.InvalidRecord;
        if (!shaped and node_count > replay.nodes.len) return error.InvalidRecord;
        var nodes = std.ArrayList(graph.Node).empty;
        defer nodes.deinit(allocator);
        try nodes.ensureTotalCapacity(allocator, @min(node_count, chunk_size));
        var text_spans = std.ArrayList(TextSpan).empty;
        defer text_spans.deinit(allocator);
        try text_spans.ensureTotalCapacity(allocator, @min(node_count, chunk_size));
        var text_bytes = std.ArrayList(u8).empty;
        defer text_bytes.deinit(allocator);
        const materialize_shaped_texts = shaped and node_count > replay.nodes.len;

        var next_id: usize = 1;
        while (next_id <= node_count) {
            nodes.clearRetainingCapacity();
            text_spans.clearRetainingCapacity();
            text_bytes.clearRetainingCapacity();
            const take = @min(chunk_size, node_count - next_id + 1);
            const end = next_id + take - 1;
            const generate_start = monotonicNs(store.io);
            var id = next_id;
            while (id <= end) : (id += 1) {
                const source_index = nodeIndexForOrdinal(id, node_count, replay.nodes.len, shaped);
                const replay_node = replay.nodes[source_index];
                if (materialize_shaped_texts) {
                    const text_offset = text_bytes.items.len;
                    try appendShapedNodeText(allocator, &text_bytes, replay_node.text, id, source_index);
                    const text_len = text_bytes.items.len - text_offset;
                    try text_density.record(text_len);
                    try text_spans.append(allocator, .{ .offset = text_offset, .len = text_len });
                } else {
                    try text_density.record(replay_node.text.len);
                }
            }
            for (0..take) |index| {
                const node_id = next_id + index;
                const source_index = nodeIndexForOrdinal(node_id, node_count, replay.nodes.len, shaped);
                const replay_node = replay.nodes[source_index];
                try nodes.append(allocator, .{
                    .id = core.NodeId.fromInt(@intCast(node_id)),
                    .kind = replay_node.kind,
                    .text = if (materialize_shaped_texts) text: {
                        const span = text_spans.items[index];
                        break :text text_bytes.items[span.offset..][0..span.len];
                    } else replay_node.text,
                });
            }
            timings.generate_texts_ns += elapsedNs(store.io, generate_start);
            const append_start = monotonicNs(store.io);
            try store.appendNodesBatch(nodes.items);
            timings.store_append_ns += elapsedNs(store.io, append_start);
            next_id = end + 1;
        }
    }

    pub fn appendEdgesChunked(
        allocator: std.mem.Allocator,
        store: storage.Store,
        replay: *const Replay,
        node_count: usize,
        edge_count: usize,
        chunk_size: usize,
        shaped: bool,
    ) !EdgeStats {
        if (replay.nodes.len == 0 or replay.edges.len == 0 or chunk_size == 0) return error.InvalidRecord;
        if (!shaped and edge_count > replay.edges.len) return error.InvalidRecord;
        var id_map = try buildNodeIdMap(allocator, replay);
        defer id_map.deinit();

        var stats = EdgeStats{};
        var edges = std.ArrayList(graph.Edge).empty;
        defer edges.deinit(allocator);
        try edges.ensureTotalCapacity(allocator, @min(edge_count, chunk_size));

        var next_id: usize = 1;
        while (next_id <= edge_count) {
            edges.clearRetainingCapacity();
            while (next_id <= edge_count and edges.items.len < chunk_size) : (next_id += 1) {
                const replay_edge = replay.edges[(next_id - 1) % replay.edges.len];
                const src = id_map.get(replay_edge.src_original_id) orelse {
                    stats.edges_skipped_missing_endpoint += 1;
                    continue;
                };
                const dst = id_map.get(replay_edge.dst_original_id) orelse {
                    stats.edges_skipped_missing_endpoint += 1;
                    continue;
                };
                if (!shaped and (src > node_count or dst > node_count)) {
                    stats.edges_skipped_missing_endpoint += 1;
                    continue;
                }
                stats.recordRelation(replay_edge.rel);
                try edges.append(allocator, .{
                    .id = core.EdgeId.fromInt(@intCast(next_id)),
                    .src = if (shaped) try shapedNodeId(src, next_id, replay.nodes.len, replay.edges.len, node_count) else core.NodeId.fromInt(src),
                    .rel = replay_edge.rel,
                    .dst = if (shaped) try shapedNodeId(dst, next_id, replay.nodes.len, replay.edges.len, node_count) else core.NodeId.fromInt(dst),
                });
            }
            if (edges.items.len != 0) {
                try store.appendEdgesBatch(edges.items);
                stats.edges_used += edges.items.len;
            }
        }
        return stats;
    }

    pub fn nodeIndexForOrdinal(node_ordinal: usize, node_count: usize, replay_node_count: usize, shaped: bool) usize {
        if (!shaped or node_count >= replay_node_count) return (node_ordinal - 1) % replay_node_count;
        return ((node_ordinal - 1) * replay_node_count) / node_count;
    }

    pub fn appendShapedNodeText(
        allocator: std.mem.Allocator,
        out: *std.ArrayList(u8),
        source_text: []const u8,
        node_ordinal: usize,
        source_index: usize,
    ) !void {
        _ = node_ordinal;
        _ = source_index;
        var token_start: ?usize = null;
        for (source_text, 0..) |byte, index| {
            if (shapeTokenByte(byte)) {
                if (token_start == null) token_start = index;
                continue;
            }
            if (token_start) |start| {
                try appendShapedToken(allocator, out, source_text, start, index);
                token_start = null;
            }
            try out.append(allocator, byte);
        }
        if (token_start) |start| try appendShapedToken(allocator, out, source_text, start, source_text.len);
    }

    pub fn probeTermIsStructural(text: []const u8, start: usize, end: usize) bool {
        const term = text[start..end];
        var next = end;
        while (next < text.len and (text[next] == ' ' or text[next] == '\t')) : (next += 1) {}
        if (next < text.len and text[next] == '=') return true;
        if (structuralTerm(term)) return true;
        if (start != 0 and text[start - 1] == '_') return true;
        if (end < text.len and text[end] == '_') return true;
        return false;
    }

    fn appendMetaknowDeferredRow(allocator: std.mem.Allocator, rows: *std.ArrayList(DeferredBasedOnRow), line: []const u8) !void {
        var parsed = try std.json.parseFromSlice(MetaknowDeferredBasedOnJson, allocator, line, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
        defer parsed.deinit();
        if (parsed.value.fragment_id.len == 0 or parsed.value.dst_ids.len == 0) return error.InvalidRecord;
        const fragment_original_id = try allocator.dupe(u8, parsed.value.fragment_id);
        errdefer allocator.free(fragment_original_id);
        const dst_original_ids = try allocator.alloc([]u8, parsed.value.dst_ids.len);
        errdefer allocator.free(dst_original_ids);
        var copied: usize = 0;
        errdefer for (dst_original_ids[0..copied]) |id| allocator.free(id);
        for (parsed.value.dst_ids, 0..) |id, index| {
            if (id.len == 0) return error.InvalidRecord;
            dst_original_ids[index] = try allocator.dupe(u8, id);
            copied += 1;
        }
        try rows.append(allocator, .{
            .fragment_original_id = fragment_original_id,
            .dst_original_ids = dst_original_ids,
        });
    }

    fn appendNativeDeferredRow(allocator: std.mem.Allocator, rows: *std.ArrayList(DeferredBasedOnRow), line: []const u8) !void {
        var parsed = try std.json.parseFromSlice(NativeJsonlDeferredBasedOnJson, allocator, line, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
        defer parsed.deinit();
        if (parsed.value.src == 0 or parsed.value.dst == 0) return error.InvalidRecord;
        const fragment_original_id = try replayIdFromU64(allocator, parsed.value.src);
        errdefer allocator.free(fragment_original_id);
        const dst_original_ids = try allocator.alloc([]u8, 1);
        errdefer allocator.free(dst_original_ids);
        const dst_original_id = try replayIdFromU64(allocator, parsed.value.dst);
        errdefer allocator.free(dst_original_id);
        dst_original_ids[0] = dst_original_id;
        try rows.append(allocator, .{
            .fragment_original_id = fragment_original_id,
            .dst_original_ids = dst_original_ids,
        });
    }

    fn detectInputShape(allocator: std.mem.Allocator, node_lines: []const []const u8, edge_lines: []const []const u8) !InputShape {
        if (node_lines.len == 0 or edge_lines.len == 0) return error.InvalidRecord;
        if (std.json.parseFromSlice(NativeJsonlNodeJson, allocator, node_lines[0], .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        })) |parsed_node| {
            defer parsed_node.deinit();
            if (std.json.parseFromSlice(NativeJsonlEdgeJson, allocator, edge_lines[0], .{
                .ignore_unknown_fields = true,
                .allocate = .alloc_always,
            })) |parsed_edge| {
                defer parsed_edge.deinit();
                if (parsed_node.value.id != 0 and parsed_node.value.text.len != 0 and parsed_edge.value.id != 0 and parsed_edge.value.src != 0 and parsed_edge.value.dst != 0) return .native_jsonl;
            } else |_| {}
        } else |_| {}
        return .metaknow_export;
    }

    fn loadLineFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8, max_bytes: u64) !LineFile {
        const stat = try std.Io.Dir.cwd().statFile(io, path, .{});
        if (stat.kind != .file or stat.size == 0 or stat.size > max_bytes) return error.InvalidRecord;
        const bytes = try allocator.alloc(u8, @intCast(stat.size));
        errdefer allocator.free(bytes);
        var file = try std.Io.Dir.cwd().openFile(io, path, .{});
        defer file.close(io);
        if (try file.readPositionalAll(io, bytes, 0) != bytes.len) return error.InvalidRecord;
        var records = std.ArrayList([]const u8).empty;
        errdefer records.deinit(allocator);
        var lines = std.mem.splitScalar(u8, bytes, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len != 0) try records.append(allocator, trimmed);
        }
        if (records.items.len == 0) return error.InvalidRecord;
        return .{ .bytes = bytes, .records = try records.toOwnedSlice(allocator) };
    }

    fn loadManifest(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !ManifestStats {
        const stat = try std.Io.Dir.cwd().statFile(io, path, .{});
        if (stat.kind != .file or stat.size == 0 or stat.size > manifest_max_bytes) return error.InvalidRecord;
        const bytes = try allocator.alloc(u8, @intCast(stat.size));
        defer allocator.free(bytes);
        var file = try std.Io.Dir.cwd().openFile(io, path, .{});
        defer file.close(io);
        if (try file.readPositionalAll(io, bytes, 0) != bytes.len) return error.InvalidRecord;
        var parsed = try std.json.parseFromSlice(MetaknowManifestJson, allocator, bytes, .{
            .ignore_unknown_fields = true,
            .allocate = .alloc_always,
        });
        defer parsed.deinit();
        return .{
            .based_on_materialize_threshold = parsed.value.based_on_materialize_threshold orelse 0,
            .based_on_materialized_edges = parsed.value.based_on_materialized_edges orelse 0,
            .based_on_deferred_edges = parsed.value.based_on_deferred_edges orelse 0,
            .based_on_deferred_fragment_count = parsed.value.based_on_deferred_fragment_count orelse 0,
            .based_on_document_container_skipped_edges = parsed.value.based_on_document_container_skipped_edges orelse 0,
            .deferred_based_on_rows = parsed.value.deferred_based_on_rows orelse 0,
            .deferred_based_on_bytes = parsed.value.deferred_based_on_bytes orelse 0,
        };
    }

    fn fileExists(io: std.Io, path: []const u8) !bool {
        const stat = std.Io.Dir.cwd().statFile(io, path, .{}) catch |err| switch (err) {
            error.FileNotFound, error.NotDir => return false,
            else => |e| return e,
        };
        return stat.kind == .file;
    }

    fn fileSize(io: std.Io, path: []const u8) !u64 {
        const stat = try std.Io.Dir.cwd().statFile(io, path, .{});
        if (stat.kind != .file) return error.InvalidRecord;
        return stat.size;
    }

    fn replayIdFromU64(allocator: std.mem.Allocator, value: u64) ![]u8 {
        if (value == 0 or value == std.math.maxInt(u64)) return error.InvalidRecord;
        return try std.fmt.allocPrint(allocator, "{d}", .{value});
    }

    fn metaknowNodeText(allocator: std.mem.Allocator, node: MetaknowNodeJson) ![]u8 {
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(allocator);
        try appendTextPart(&out, allocator, "kind", node.kind);
        try appendTextPart(&out, allocator, "title", node.title orelse node.text);
        try appendTextPart(&out, allocator, "summary", node.summary);
        try appendTextPart(&out, allocator, "description", node.description);
        try appendTextPart(&out, allocator, "properties", node.properties);
        try appendTextPart(&out, allocator, "fragment_text", node.fragment);
        try appendTextPart(&out, allocator, "text", node.text);
        return try out.toOwnedSlice(allocator);
    }

    fn appendTextPart(out: *std.ArrayList(u8), allocator: std.mem.Allocator, label: []const u8, value: ?[]const u8) !void {
        const bytes = value orelse return;
        if (bytes.len == 0) return;
        if (out.items.len != 0) try out.appendSlice(allocator, " ");
        try out.appendSlice(allocator, label);
        try out.appendSlice(allocator, "=\"");
        try out.appendSlice(allocator, bytes);
        try out.appendSlice(allocator, "\"");
    }

    fn metaknowNodeKind(raw: ?[]const u8) core.NodeKind {
        const value = raw orelse return .concept;
        if (core.parseNodeKind(value)) |kind| return kind;
        if (std.ascii.eqlIgnoreCase(value, "note")) return .observation;
        if (std.ascii.eqlIgnoreCase(value, "knowledge_node") or std.ascii.eqlIgnoreCase(value, "entity")) return .concept;
        if (std.ascii.eqlIgnoreCase(value, "fragment")) return .document_section;
        if (std.ascii.eqlIgnoreCase(value, "error")) return .error_event;
        return .concept;
    }

    fn metaknowRelKind(raw: ?[]const u8) core.RelKind {
        const value = raw orelse return .related_to;
        if (core.parseRelKind(value)) |rel| return rel;
        if (std.ascii.eqlIgnoreCase(value, "supports") or std.ascii.eqlIgnoreCase(value, "supported_by") or std.ascii.eqlIgnoreCase(value, "support")) return .evidences;
        if (std.ascii.eqlIgnoreCase(value, "dependency") or std.ascii.eqlIgnoreCase(value, "depends")) return .depends_on;
        return .related_to;
    }

    fn parseNodeKind(label: []const u8) ?core.NodeKind {
        if (core.parseNodeKind(label)) |kind| return kind;
        if (std.ascii.eqlIgnoreCase(label, "note")) return .observation;
        if (std.mem.startsWith(u8, label, "type#")) {
            const id = std.fmt.parseInt(u16, label["type#".len..], 10) catch return null;
            return @enumFromInt(id);
        }
        return null;
    }

    fn parseRelKind(label: []const u8) ?core.RelKind {
        if (core.parseRelKind(label)) |rel| return rel;
        if (schema.markdownProjectionRelationIdByName(label)) |id| return @enumFromInt(id);
        if (std.ascii.eqlIgnoreCase(label, "supports")) return .evidences;
        if (std.mem.startsWith(u8, label, "rel#")) {
            const id = std.fmt.parseInt(u16, label["rel#".len..], 10) catch return null;
            return @enumFromInt(id);
        }
        return null;
    }

    const TextSpan = struct { offset: usize, len: usize };

    fn shapeTokenByte(byte: u8) bool {
        return std.ascii.isAlphanumeric(byte) or byte == '_';
    }

    fn appendShapedToken(allocator: std.mem.Allocator, out: *std.ArrayList(u8), source_text: []const u8, start: usize, end: usize) !void {
        const term = source_text[start..end];
        if (probeTermIsStructural(source_text, start, end)) {
            try out.appendSlice(allocator, term);
            return;
        }
        const alphabet = "abcdefghijklmnopqrstuvwxyz";
        var state = std.hash.Wyhash.hash(0x544B_475F_5348_5031, term);
        for (0..term.len) |index| {
            state = state *% 6364136223846793005 +% 1442695040888963407 +% @as(u64, @intCast(index));
            try out.append(allocator, alphabet[@intCast(state % alphabet.len)]);
        }
    }

    fn structuralTerm(term: []const u8) bool {
        const structural = [_][]const u8{
            "kind",  "title",   "summary", "description", "fragment", "fragment_text", "text",     "properties", "props",
            "task",  "concept", "file",    "function",    "note",     "observation",   "document", "section",    "document_section",
            "error", "event",   "agent",   "node",        "metaknow", "tinykg",
        };
        for (structural) |value| if (std.ascii.eqlIgnoreCase(term, value)) return true;
        return false;
    }

    fn shapedNodeId(base_id: u64, edge_ordinal: usize, replay_node_count: usize, replay_edge_count: usize, node_count: usize) !core.NodeId {
        if (base_id == 0 or edge_ordinal == 0 or replay_node_count == 0 or replay_edge_count == 0 or node_count == 0) return error.InvalidRecord;
        const edge_cycle = (edge_ordinal - 1) / replay_edge_count;
        const zero_based = (base_id - 1 + @as(u64, @intCast(edge_cycle)) * @as(u64, @intCast(replay_node_count))) % @as(u64, @intCast(node_count));
        return core.NodeId.fromInt(zero_based + 1);
    }

    fn monotonicNs(io: std.Io) u128 {
        const timestamp = std.Io.Clock.awake.now(io).nanoseconds;
        return if (timestamp < 0) 0 else @intCast(timestamp);
    }

    fn elapsedNs(io: std.Io, start: u128) u128 {
        const now = monotonicNs(io);
        return if (now >= start) now - start else 0;
    }
};

test "metaknow replay workload loads export shape and canonicalizes semantics" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "nodes.jsonl",
        .data =
        \\{"id":"node-a","kind":"task","title":"First task","summary":"agent memory"}
        \\{"id":"node-b","kind":"fragment","name":"Section","fragment":"raw 中文 fragment","properties":"priority=high"}
        \\
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "edges.jsonl",
        .data =
        \\{"src":"node-a","dst":"node-b","rel":"supports"}
        \\{"src":"node-b","dst":"node-a","relation":"depends"}
        \\
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "manifest.json",
        .data = "{\"based_on_materialized_edges\":3,\"deferred_based_on_rows\":1,\"deferred_based_on_bytes\":24}",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "deferred_based_on.jsonl",
        .data = "{\"fragment_id\":\"node-b\",\"dst_ids\":[\"node-a\"]}\n",
    });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const replay = try MetaknowReplayWorkload.load(std.testing.allocator, std.testing.io, path_buf[0..path_len]);
    defer replay.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), replay.nodes.len);
    try std.testing.expectEqual(core.NodeKind.task, replay.nodes[0].kind);
    try std.testing.expectEqual(core.NodeKind.document_section, replay.nodes[1].kind);
    try std.testing.expect(std.mem.indexOf(u8, replay.nodes[1].text, "raw 中文 fragment") != null);
    try std.testing.expect(std.mem.indexOf(u8, replay.nodes[1].text, "properties=\"priority=high\"") != null);
    try std.testing.expectEqual(core.RelKind.evidences, replay.edges[0].rel);
    try std.testing.expectEqual(core.RelKind.depends_on, replay.edges[1].rel);
    try std.testing.expectEqual(@as(usize, 3), replay.manifest.based_on_materialized_edges);
    try std.testing.expectEqualStrings("node-a", replay.deferred_based_on[0].dst_original_ids[0]);
}

test "metaknow replay workload accepts native jsonl without manifest" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "nodes.jsonl",
        .data =
        \\{"id":1,"kind":"task","text":"Native task"}
        \\{"id":2,"kind":"evidence","text":"Native evidence"}
        \\
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "edges.jsonl",
        .data =
        \\{"id":7,"src":1,"rel":"based_on","dst":2}
        \\{"id":8,"src":2,"rel":"references","dst":1}
        \\
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "deferred_based_on.jsonl",
        .data = "{\"src\":1,\"dst\":2}\n",
    });

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const replay = try MetaknowReplayWorkload.load(std.testing.allocator, std.testing.io, path_buf[0..path_len]);
    defer replay.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("1", replay.nodes[0].original_id);
    try std.testing.expectEqual(core.RelKind.based_on, replay.edges[0].rel);
    try std.testing.expectEqual(@as(usize, 1), replay.manifest.deferred_based_on_rows);
    try std.testing.expect(replay.manifest.deferred_based_on_bytes > 0);
}

test "metaknow replay workload rejects missing manifest and duplicate ids" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "nodes.jsonl",
        .data = "{\"id\":\"node-a\",\"kind\":\"concept\",\"title\":\"A\"}\n",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "edges.jsonl",
        .data = "{\"src\":\"node-a\",\"dst\":\"node-a\",\"rel\":\"related_to\"}\n",
    });
    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const dir_path = path_buf[0..path_len];
    try std.testing.expectError(error.FileNotFound, MetaknowReplayWorkload.load(std.testing.allocator, std.testing.io, dir_path));

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "manifest.json", .data = "{}" });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "nodes.jsonl",
        .data =
        \\{"id":"node-a","kind":"concept","title":"A"}
        \\{"id":"node-a","kind":"concept","title":"duplicate"}
        \\
        ,
    });
    try std.testing.expectError(error.InvalidRecord, MetaknowReplayWorkload.load(std.testing.allocator, std.testing.io, dir_path));
}

test "metaknow replay workload plans only edges with admitted endpoints" {
    var replay = MetaknowReplayWorkload.Replay{
        .nodes = try std.testing.allocator.alloc(MetaknowReplayWorkload.Node, 2),
        .edges = try std.testing.allocator.alloc(MetaknowReplayWorkload.Edge, 3),
    };
    replay.nodes[0] = .{
        .original_id = try std.testing.allocator.dupe(u8, "node-a"),
        .kind = .task,
        .text = try std.testing.allocator.dupe(u8, "Task alpha"),
    };
    replay.nodes[1] = .{
        .original_id = try std.testing.allocator.dupe(u8, "node-b"),
        .kind = .evidence,
        .text = try std.testing.allocator.dupe(u8, "Evidence beta"),
    };
    replay.edges[0] = .{
        .src_original_id = try std.testing.allocator.dupe(u8, "node-a"),
        .dst_original_id = try std.testing.allocator.dupe(u8, "node-b"),
        .rel = .based_on,
    };
    replay.edges[1] = .{
        .src_original_id = try std.testing.allocator.dupe(u8, "node-b"),
        .dst_original_id = try std.testing.allocator.dupe(u8, "node-a"),
        .rel = .references,
    };
    replay.edges[2] = .{
        .src_original_id = try std.testing.allocator.dupe(u8, "missing"),
        .dst_original_id = try std.testing.allocator.dupe(u8, "node-a"),
        .rel = .blocks,
    };
    defer replay.deinit(std.testing.allocator);

    const stats = try MetaknowReplayWorkload.planEdges(std.testing.allocator, &replay);
    try std.testing.expectEqual(@as(usize, 2), stats.edges_used);
    try std.testing.expectEqual(@as(usize, 1), stats.edges_skipped_missing_endpoint);
    try std.testing.expectEqual(@as(usize, 1), stats.relation_based_on);
    try std.testing.expectEqual(@as(usize, 1), stats.relation_references);
    try std.testing.expectEqual(@as(usize, 0), stats.relation_blocks);
}

test "metaknow replay workload materializes shaped nodes and repeated edges in bounded batches" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buf);
    const db_path = try std.fs.path.join(std.testing.allocator, &.{ root_buf[0..root_len], "kg" });
    defer std.testing.allocator.free(db_path);

    var replay = MetaknowReplayWorkload.Replay{
        .nodes = try std.testing.allocator.alloc(MetaknowReplayWorkload.Node, 2),
        .edges = try std.testing.allocator.alloc(MetaknowReplayWorkload.Edge, 2),
    };
    replay.nodes[0] = .{
        .original_id = try std.testing.allocator.dupe(u8, "node-a"),
        .kind = .task,
        .text = try std.testing.allocator.dupe(u8, "kind=\"task\" title=\"Semantic Alpha\""),
    };
    replay.nodes[1] = .{
        .original_id = try std.testing.allocator.dupe(u8, "node-b"),
        .kind = .evidence,
        .text = try std.testing.allocator.dupe(u8, "kind=\"evidence\" title=\"Semantic Beta\""),
    };
    replay.edges[0] = .{
        .src_original_id = try std.testing.allocator.dupe(u8, "node-a"),
        .dst_original_id = try std.testing.allocator.dupe(u8, "node-b"),
        .rel = .based_on,
    };
    replay.edges[1] = .{
        .src_original_id = try std.testing.allocator.dupe(u8, "node-b"),
        .dst_original_id = try std.testing.allocator.dupe(u8, "node-a"),
        .rel = .references,
    };
    defer replay.deinit(std.testing.allocator);

    var store = try storage.Store.initWithOptions(std.testing.allocator, std.testing.io, db_path, .{
        .durability = .fast,
        .validate_indexes_on_read = false,
    });
    defer store.deinit();
    try store.createEmpty();
    var density = MetaknowReplayWorkload.TextDensityStats{};
    var timings = MetaknowReplayWorkload.NodeLoadTimings{};
    try MetaknowReplayWorkload.appendNodesChunked(std.testing.allocator, store, &replay, 4, 2, true, &density, &timings);
    const edge_stats = try MetaknowReplayWorkload.appendEdgesChunked(std.testing.allocator, store, &replay, 4, 4, 2, true);

    try std.testing.expectEqual(@as(u64, 4), density.node_count);
    try std.testing.expectEqual(@as(usize, 4), edge_stats.edges_used);
    var third = (try store.readNodeById(std.testing.allocator, .fromInt(3))) orelse return error.NotFound;
    defer third.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, third.text, "Semantic Alpha") == null);
    try std.testing.expect(std.mem.indexOf(u8, third.text, "kind=") != null);
    const fourth_edge = try store.readEdgeById(.fromInt(4));
    try std.testing.expect(fourth_edge.src.toInt() >= 1 and fourth_edge.src.toInt() <= 4);
    try std.testing.expect(fourth_edge.dst.toInt() >= 1 and fourth_edge.dst.toInt() <= 4);
}

test "metaknow replay workload preserves structural tokens while shaping semantic terms" {
    const source = "kind=\"task\" title=\"SemanticAlpha\" tinykg governance";
    var shaped = std.ArrayList(u8).empty;
    defer shaped.deinit(std.testing.allocator);
    try MetaknowReplayWorkload.appendShapedNodeText(std.testing.allocator, &shaped, source, 3, 0);
    try std.testing.expect(std.mem.indexOf(u8, shaped.items, "kind=\"task\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, shaped.items, "title=") != null);
    try std.testing.expect(std.mem.indexOf(u8, shaped.items, "tinykg") != null);
    try std.testing.expect(std.mem.indexOf(u8, shaped.items, "SemanticAlpha") == null);
}
