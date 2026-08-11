const std = @import("std");

/// Persistent append-only event-log wire format. The caller owns Store file
/// I/O, transaction boundaries, mutation admission, repair/truncation, and
/// derived-index publication; this owner only encodes, validates, decodes, and
/// adapts already-decoded records to a supplied graph/deadline.
pub fn BinaryEventLogCodec(
    comptime core: type,
    comptime max_node_types: u16,
    comptime max_relation_types: u16,
) type {
    return struct {
        fn nodeTextLenFitsU16(text_len: usize) bool {
            return text_len != 0 and text_len <= std.math.maxInt(u16);
        }

        const edge_index_rel_kind_count = max_relation_types;

        fn edgeIndexDefaultRelFromCounts(counts: [edge_index_rel_kind_count]u64, total: u64) ?u16 {
            if (total == 0) return null;
            var best_index: usize = 0;
            var best_count: u64 = 0;
            for (counts, 0..) |count, index| {
                if (count > best_count) {
                    best_count = count;
                    best_index = index;
                }
            }
            if (best_count == 0 or total - best_count > 2) return null;
            const best_rel: u16 = @intCast(best_index);
            if (relKindFromInt(best_rel) == null) return null;
            return best_rel;
        }

        pub const BinaryRecordKind = enum(u8) {
            node = 'N',
            node_batch = 'M',
            edge = 'E',
            edge_batch = 'A',
            edge_delete = 'D',
            batch_begin = 'B',
            batch_commit = 'C',
        };

        pub const BinaryRecordHeader = struct {
            version: u8,
            kind: BinaryRecordKind,
            payload_len: u32,
            payload_checksum: ?u64 = null,

            pub const magic = [_]u8{ 'T', 'K', 'G', 'E' };
            pub const current_version: u8 = 2;
            pub const encoded_len: usize = 18;
            pub const max_payload_len: u32 = 64 * 1024 * 1024;

            pub fn decode(bytes: *const [encoded_len]u8) !BinaryRecordHeader {
                if (!std.mem.eql(u8, bytes[0..4], &magic)) return error.InvalidRecord;
                if (bytes[4] != current_version) return error.InvalidRecord;
                const kind: BinaryRecordKind = switch (bytes[5]) {
                    'N' => .node,
                    'M' => .node_batch,
                    'E' => .edge,
                    'A' => .edge_batch,
                    'D' => .edge_delete,
                    'B' => .batch_begin,
                    'C' => .batch_commit,
                    else => return error.InvalidRecord,
                };
                const payload_len = readU32(bytes[6..10]);
                if (payload_len > max_payload_len) return error.InvalidRecord;
                return .{
                    .version = bytes[4],
                    .kind = kind,
                    .payload_len = payload_len,
                    .payload_checksum = readU64(bytes[10..18]),
                };
            }
        };

        pub fn binaryPayloadChecksum(payload: []const u8) u64 {
            return std.hash.Wyhash.hash(0, payload);
        }

        pub fn validateBinaryChecksum(header: BinaryRecordHeader, payload: []const u8) !void {
            if (header.payload_checksum != null) {
                try validateBinaryChecksumValue(header, binaryPayloadChecksum(payload));
            }
        }

        pub fn validateBinaryChecksumValue(header: BinaryRecordHeader, checksum: u64) !void {
            if (header.payload_checksum) |expected| {
                if (expected != checksum) return error.InvalidRecord;
            }
        }

        pub fn ensureBinaryPayloadFits(file_size: u64, payload_offset: u64, payload_len: u32) !void {
            if (payload_offset > file_size) return error.InvalidRecord;
            if (@as(u64, payload_len) > file_size - payload_offset) return error.InvalidRecord;
        }

        pub fn appendBinaryHeader(out: *std.ArrayList(u8), allocator: std.mem.Allocator, kind: BinaryRecordKind, payload_len: usize, payload_checksum: u64) !void {
            if (payload_len > BinaryRecordHeader.max_payload_len) return error.RecordTooLarge;
            try out.appendSlice(allocator, &BinaryRecordHeader.magic);
            try out.append(allocator, BinaryRecordHeader.current_version);
            try out.append(allocator, @intFromEnum(kind));
            try appendU32(out, allocator, @intCast(payload_len));
            try appendU64(out, allocator, payload_checksum);
        }

        pub fn appendBinaryRecord(out: *std.ArrayList(u8), allocator: std.mem.Allocator, kind: BinaryRecordKind, payload: []const u8) !void {
            try appendBinaryHeader(out, allocator, kind, payload.len, binaryPayloadChecksum(payload));
            try out.appendSlice(allocator, payload);
        }

        pub const binary_edge_record_len: usize = BinaryRecordHeader.encoded_len + binary_edge_payload_len;
        pub const binary_edge_delete_record_len: usize = BinaryRecordHeader.encoded_len + binary_edge_delete_payload_len;

        pub fn encodeBinaryRecordHeader(out: *[BinaryRecordHeader.encoded_len]u8, kind: BinaryRecordKind, payload_len: u32, payload_checksum: u64) void {
            @memcpy(out[0..4], &BinaryRecordHeader.magic);
            out[4] = BinaryRecordHeader.current_version;
            out[5] = @intFromEnum(kind);
            std.mem.writeInt(u32, out[6..10], payload_len, .little);
            std.mem.writeInt(u64, out[10..18], payload_checksum, .little);
        }

        pub fn encodeBinaryNodeFixedPayload(out: *[binary_node_payload_len]u8, node: anytype, span: anytype) !u32 {
            if (node.text.len > maxBinaryNodeTextLen()) return error.RecordTooLarge;
            if (span.len != node.text.len) return error.InvalidRecord;
            std.mem.writeInt(u64, out[0..8], node.id.toInt(), .little);
            std.mem.writeInt(u16, out[8..10], @intFromEnum(node.kind), .little);
            std.mem.writeInt(u64, out[10..18], span.offset, .little);
            std.mem.writeInt(u32, out[18..22], span.len, .little);
            return binary_node_payload_len;
        }

        pub fn appendBinaryNodeRecordToWriter(writer: anytype, node: anytype, span: anytype) !void {
            var payload: [binary_node_payload_len]u8 = undefined;
            const payload_len = try encodeBinaryNodeFixedPayload(&payload, node, span);

            var header: [BinaryRecordHeader.encoded_len]u8 = undefined;
            encodeBinaryRecordHeader(&header, .node, payload_len, binaryPayloadChecksum(&payload));
            try writer.append(&header);
            try writer.append(&payload);
        }

        pub fn appendBinaryNodeBatchRecordToWriter(writer: anytype, allocator: std.mem.Allocator, nodes: anytype, spans: anytype) !void {
            if (nodes.len != spans.len) return error.InvalidRecord;
            const compact_dense_uniform = binaryNodeBatchCanUseDenseUniform(nodes);
            const short_text_len = compact_dense_uniform and binaryNodeBatchTextsFitU16(nodes);
            const derived_text_offset = compact_dense_uniform and binaryNodeBatchCanDeriveTextOffsets(nodes, spans);
            const payload_len = try binaryNodeBatchPayloadLen(nodes.len, compact_dense_uniform, short_text_len, derived_text_offset);
            const payload = try allocator.alloc(u8, payload_len);
            defer allocator.free(payload);

            std.mem.writeInt(u32, payload[0..4], @intCast(nodes.len), .little);
            if (compact_dense_uniform) {
                const flags = binary_node_batch_compact_flags |
                    (if (short_text_len) binary_node_batch_flag_short_text_len else 0) |
                    (if (derived_text_offset) binary_node_batch_flag_derived_text_offset else 0);
                std.mem.writeInt(u16, payload[4..6], flags, .little);
                std.mem.writeInt(u16, payload[6..8], @intFromEnum(nodes[0].kind), .little);
                std.mem.writeInt(u64, payload[8..16], nodes[0].id.toInt(), .little);
                var payload_offset: usize = binary_node_batch_compact_header_len;
                if (derived_text_offset) {
                    try writeU48(payload[payload_offset..][0..6], spans[0].offset);
                    payload_offset += binary_node_batch_derived_text_offset_header_extra_len;
                }
                const row_len = binaryNodeBatchCompactRowLen(short_text_len, derived_text_offset);
                for (nodes, spans) |node, span| {
                    if (node.text.len > maxBinaryNodeTextLen()) return error.RecordTooLarge;
                    if (span.len != node.text.len) return error.InvalidRecord;
                    if (derived_text_offset) {
                        if (short_text_len) {
                            std.mem.writeInt(u16, payload[payload_offset..][0..2], @intCast(span.len), .little);
                        } else {
                            std.mem.writeInt(u32, payload[payload_offset..][0..4], span.len, .little);
                        }
                    } else {
                        try writeU48(payload[payload_offset..][0..6], span.offset);
                        if (short_text_len) {
                            std.mem.writeInt(u16, payload[payload_offset + 6 ..][0..2], @intCast(span.len), .little);
                        } else {
                            std.mem.writeInt(u32, payload[payload_offset + 6 ..][0..4], span.len, .little);
                        }
                    }
                    payload_offset += row_len;
                }
            } else {
                std.mem.writeInt(u16, payload[4..6], 0, .little);
                var payload_offset: usize = binary_node_batch_base_header_len;
                for (nodes, spans) |node, span| {
                    _ = try encodeBinaryNodeFixedPayload(payload[payload_offset..][0..binary_node_payload_len], node, span);
                    payload_offset += binary_node_payload_len;
                }
            }

            var header: [BinaryRecordHeader.encoded_len]u8 = undefined;
            encodeBinaryRecordHeader(&header, .node_batch, payload_len, binaryPayloadChecksum(payload));
            try writer.append(&header);
            try writer.append(payload);
        }

        pub fn appendBinaryEdgeBatchRecordToWriter(writer: anytype, allocator: std.mem.Allocator, edges: anytype) !void {
            const compact_dense_derived_rel = binaryEdgeBatchDenseDerivedRelShape(edges);
            const payload_len = try binaryEdgeBatchPayloadLen(edges.len, compact_dense_derived_rel);
            const payload = try allocator.alloc(u8, payload_len);
            defer allocator.free(payload);

            std.mem.writeInt(u32, payload[0..4], @intCast(edges.len), .little);
            if (compact_dense_derived_rel) |shape| {
                const flags = binary_edge_batch_compact_flags |
                    (if (shape.compact_node_ids) binary_edge_batch_flag_u32_node_ids else 0) |
                    (if (shape.linear_endpoint_runs) binary_edge_batch_flag_linear_endpoints else 0);
                std.mem.writeInt(u16, payload[4..6], flags, .little);
                std.mem.writeInt(u16, payload[6..8], shape.default_rel, .little);
                std.mem.writeInt(u64, payload[8..16], shape.base_id, .little);
                payload[16] = shape.exception_count;
                const row_len: usize = if (shape.compact_node_ids) binary_edge_batch_compact_u32_row_len else binary_edge_batch_compact_row_len;
                var exception_offset: usize = binary_edge_batch_compact_fixed_header_len;
                var exception_index: usize = 0;
                while (exception_index < shape.exception_count) : (exception_index += 1) {
                    std.mem.writeInt(u32, payload[exception_offset..][0..4], shape.exception_ordinals[exception_index], .little);
                    std.mem.writeInt(u16, payload[exception_offset + 4 ..][0..2], shape.exception_rels[exception_index], .little);
                    exception_offset += binary_edge_batch_compact_exception_len;
                }
                var payload_offset = exception_offset;
                if (shape.linear_endpoint_runs) {
                    std.mem.writeInt(u32, payload[payload_offset..][0..4], shape.endpoint_run_count, .little);
                    payload_offset += 4;
                    for (edges, 0..) |edge, i| {
                        if (!binaryEdgeBatchEndpointStartsNewRun(edges, i)) continue;
                        std.mem.writeInt(u32, payload[payload_offset..][0..4], @intCast(edge.src.toInt()), .little);
                        std.mem.writeInt(u32, payload[payload_offset + 4 ..][0..4], @intCast(i), .little);
                        std.mem.writeInt(u32, payload[payload_offset + 8 ..][0..4], @intCast(edge.dst.toInt()), .little);
                        payload_offset += binary_edge_batch_endpoint_run_len;
                    }
                }
                for (edges) |edge| {
                    if (shape.linear_endpoint_runs) break;
                    if (shape.compact_node_ids) {
                        std.mem.writeInt(u32, payload[payload_offset..][0..4], @intCast(edge.src.toInt()), .little);
                        std.mem.writeInt(u32, payload[payload_offset + 4 ..][0..4], @intCast(edge.dst.toInt()), .little);
                    } else {
                        std.mem.writeInt(u64, payload[payload_offset..][0..8], edge.src.toInt(), .little);
                        std.mem.writeInt(u64, payload[payload_offset + 8 ..][0..8], edge.dst.toInt(), .little);
                    }
                    payload_offset += row_len;
                }
            } else {
                std.mem.writeInt(u16, payload[4..6], 0, .little);
                var payload_offset: usize = binary_edge_batch_base_header_len;
                for (edges) |edge| {
                    encodeBinaryEdgePayload(payload[payload_offset..][0..binary_edge_payload_len], edge);
                    payload_offset += binary_edge_payload_len;
                }
            }

            var header: [BinaryRecordHeader.encoded_len]u8 = undefined;
            encodeBinaryRecordHeader(&header, .edge_batch, payload_len, binaryPayloadChecksum(payload));
            try writer.append(&header);
            try writer.append(payload);
        }

        pub fn encodeBinaryEdgeRecord(out: *[binary_edge_record_len]u8, edge: anytype) void {
            const payload = out[BinaryRecordHeader.encoded_len..];
            encodeBinaryEdgePayload(payload[0..binary_edge_payload_len], edge);
            var header: [BinaryRecordHeader.encoded_len]u8 = undefined;
            encodeBinaryRecordHeader(&header, .edge, binary_edge_payload_len, binaryPayloadChecksum(payload));
            @memcpy(out[0..BinaryRecordHeader.encoded_len], &header);
        }

        pub fn encodeBinaryEdgePayload(out: *[binary_edge_payload_len]u8, edge: anytype) void {
            std.mem.writeInt(u64, out[0..8], edge.id.toInt(), .little);
            std.mem.writeInt(u64, out[8..16], edge.src.toInt(), .little);
            std.mem.writeInt(u16, out[16..18], @intFromEnum(edge.rel), .little);
            std.mem.writeInt(u64, out[18..26], edge.dst.toInt(), .little);
        }

        pub fn encodeBinaryEdgeDeleteRecord(out: *[binary_edge_delete_record_len]u8, edge_id: core.EdgeId) void {
            const payload = out[BinaryRecordHeader.encoded_len..];
            std.mem.writeInt(u64, payload[0..8], edge_id.toInt(), .little);
            var header: [BinaryRecordHeader.encoded_len]u8 = undefined;
            encodeBinaryRecordHeader(&header, .edge_delete, binary_edge_delete_payload_len, binaryPayloadChecksum(payload));
            @memcpy(out[0..BinaryRecordHeader.encoded_len], &header);
        }

        pub fn replayBinaryRecord(graph: anytype, kind: BinaryRecordKind, payload: []const u8, deadline: anytype) !void {
            if (deadline.expired()) return core.Error.BudgetExceeded;
            switch (kind) {
                .node, .node_batch => return error.InvalidRecord,
                .edge => {
                    const parsed = try validateBinaryEdgePayload(payload);
                    graph.addEdgeWithIdUnchecked(core.EdgeId.fromInt(parsed.id), core.NodeId.fromInt(parsed.src), parsed.rel, core.NodeId.fromInt(parsed.dst)) catch |err| switch (err) {
                        core.Error.InvalidId, core.Error.NotFound => return error.InvalidRecord,
                        else => |e| return e,
                    };
                },
                .edge_batch => {
                    const batch = try validateBinaryEdgeBatchHeader(payload);
                    var index: u32 = 0;
                    while (index < batch.count) : (index += 1) {
                        if (deadline.expired()) return core.Error.BudgetExceeded;
                        const parsed = try validateBinaryEdgeBatchEdge(payload, batch, index);
                        graph.addEdgeWithIdUnchecked(core.EdgeId.fromInt(parsed.id), core.NodeId.fromInt(parsed.src), parsed.rel, core.NodeId.fromInt(parsed.dst)) catch |err| switch (err) {
                            core.Error.InvalidId, core.Error.NotFound => return error.InvalidRecord,
                            else => |e| return e,
                        };
                    }
                },
                .edge_delete => {
                    const edge_id = try validateBinaryEdgeDeletePayload(payload);
                    graph.deleteEdgeById(edge_id) catch |err| switch (err) {
                        core.Error.InvalidId => return error.InvalidRecord,
                        else => |e| return e,
                    };
                },
                .batch_begin, .batch_commit => {},
            }
        }

        pub fn validateBinaryRecordPayload(kind: BinaryRecordKind, payload: []const u8) !void {
            switch (kind) {
                .node => _ = try validateBinaryNodePayload(payload),
                .node_batch => try validateBinaryNodeBatchPayload(payload),
                .edge => _ = try validateBinaryEdgePayload(payload),
                .edge_batch => try validateBinaryEdgeBatchPayload(payload),
                .edge_delete => _ = try validateBinaryEdgeDeletePayload(payload),
                .batch_begin, .batch_commit => if (payload.len != 0) return error.InvalidRecord,
            }
        }

        pub const ParsedBinaryNode = struct {
            id: u64,
            kind: core.NodeKind,
            text_offset: u64,
            text_len: u32,
        };

        pub const binary_node_payload_len: usize = 22;
        pub const binary_node_batch_base_header_len: usize = 6;
        pub const binary_node_batch_compact_header_len: usize = 16;
        pub const binary_node_batch_derived_text_offset_header_extra_len: usize = 6;
        pub const binary_node_batch_compact_row_len: usize = 10;
        pub const binary_node_batch_compact_short_text_len_row_len: usize = 8;
        pub const binary_node_batch_compact_derived_text_offset_row_len: usize = 4;
        pub const binary_node_batch_compact_short_derived_text_offset_row_len: usize = 2;
        pub const binary_node_batch_flag_dense_id: u16 = 1 << 0;
        pub const binary_node_batch_flag_uniform_kind: u16 = 1 << 1;
        pub const binary_node_batch_flag_short_text_len: u16 = 1 << 2;
        pub const binary_node_batch_flag_derived_text_offset: u16 = 1 << 3;
        pub const binary_node_batch_compact_flags: u16 = binary_node_batch_flag_dense_id | binary_node_batch_flag_uniform_kind;
        pub const binary_node_batch_known_flags: u16 = binary_node_batch_compact_flags | binary_node_batch_flag_short_text_len | binary_node_batch_flag_derived_text_offset;
        pub const binary_node_batch_max_count: usize = (BinaryRecordHeader.max_payload_len - binary_node_batch_base_header_len) / binary_node_payload_len;
        pub const binary_edge_payload_len: usize = 26;
        pub const binary_edge_batch_base_header_len: usize = 6;
        pub const binary_edge_batch_compact_fixed_header_len: usize = 17;
        pub const binary_edge_batch_compact_exception_len: usize = 6;
        pub const binary_edge_batch_endpoint_run_len: usize = 12;
        pub const binary_edge_batch_compact_row_len: usize = 16;
        pub const binary_edge_batch_compact_u32_row_len: usize = 8;
        pub const binary_edge_batch_flag_dense_id: u16 = 1 << 0;
        pub const binary_edge_batch_flag_derived_rel: u16 = 1 << 1;
        pub const binary_edge_batch_flag_u32_node_ids: u16 = 1 << 2;
        pub const binary_edge_batch_flag_linear_endpoints: u16 = 1 << 3;
        pub const binary_edge_batch_compact_flags: u16 = binary_edge_batch_flag_dense_id | binary_edge_batch_flag_derived_rel;
        pub const binary_edge_batch_known_flags: u16 = binary_edge_batch_compact_flags | binary_edge_batch_flag_u32_node_ids | binary_edge_batch_flag_linear_endpoints;
        pub const binary_edge_batch_max_rel_exceptions: usize = 2;
        pub const binary_edge_batch_max_count: usize = (BinaryRecordHeader.max_payload_len - binary_edge_batch_base_header_len) / binary_edge_payload_len;
        pub const binary_edge_delete_payload_len: usize = 8;
        pub const max_binary_count_payload_prefix_len: usize = @max(binary_node_payload_len, @max(binary_edge_payload_len, binary_edge_delete_payload_len));
        pub const binary_count_read_chunk_len: usize = 64 * 1024;

        pub fn maxBinaryNodeTextLen() usize {
            return std.math.maxInt(u32);
        }

        pub fn validateBinaryNodePayload(payload: []const u8) !ParsedBinaryNode {
            if (payload.len != binary_node_payload_len) return error.InvalidRecord;
            const id = readU64(payload[0..8]);
            const kind_int = readU16(payload[8..10]);
            const text_offset = readU64(payload[10..18]);
            const text_len = readU32(payload[18..22]);
            if (id == 0 or id == std.math.maxInt(u64)) return error.InvalidRecord;
            const node_kind = nodeKindFromInt(kind_int) orelse return error.InvalidRecord;
            return .{ .id = id, .kind = node_kind, .text_offset = text_offset, .text_len = text_len };
        }

        pub fn validateBinaryNodePayloadForCount(prefix: []const u8, payload_len: u32) !ParsedBinaryNode {
            if (prefix.len < binary_node_payload_len) return error.InvalidRecord;
            if (payload_len != binary_node_payload_len) return error.InvalidRecord;
            const id = readU64(prefix[0..8]);
            const kind_int = readU16(prefix[8..10]);
            const text_offset = readU64(prefix[10..18]);
            const text_len = readU32(prefix[18..22]);
            if (id == 0 or id == std.math.maxInt(u64)) return error.InvalidRecord;
            const node_kind = nodeKindFromInt(kind_int) orelse return error.InvalidRecord;
            return .{ .id = id, .kind = node_kind, .text_offset = text_offset, .text_len = text_len };
        }

        pub const ParsedBinaryNodeBatch = struct {
            count: u32,
            flags: u16,
            header_len: usize,
            row_len: usize,
            dense_base_id: u64 = 0,
            uniform_kind: ?core.NodeKind = null,
            short_text_len: bool = false,
            derived_text_offset: bool = false,
            base_text_offset: u64 = 0,
        };

        pub fn binaryNodeBatchCanUseDenseUniform(nodes: anytype) bool {
            if (nodes.len == 0) return false;
            const first_kind = nodes[0].kind;
            const base_id = nodes[0].id.toInt();
            if (base_id == 0 or base_id == std.math.maxInt(u64)) return false;
            for (nodes, 0..) |node, ordinal| {
                const expected_id = std.math.add(u64, base_id, @intCast(ordinal)) catch return false;
                if (expected_id == std.math.maxInt(u64)) return false;
                if (node.kind != first_kind) return false;
                if (node.id.toInt() != expected_id) return false;
            }
            return true;
        }

        pub fn binaryNodeBatchTextsFitU16(nodes: anytype) bool {
            for (nodes) |node| {
                if (!nodeTextLenFitsU16(node.text.len)) return false;
            }
            return true;
        }

        pub fn binaryNodeBatchCanDeriveTextOffsets(nodes: anytype, spans: anytype) bool {
            if (nodes.len == 0 or nodes.len != spans.len) return false;
            var expected_offset = spans[0].offset;
            for (nodes, spans) |node, span| {
                if (node.text.len > maxBinaryNodeTextLen()) return false;
                if (span.len != node.text.len) return false;
                if (span.offset != expected_offset) return false;
                expected_offset = std.math.add(u64, expected_offset, span.len) catch return false;
            }
            return true;
        }

        pub fn binaryNodeBatchCompactRowLen(short_text_len: bool, derived_text_offset: bool) usize {
            if (derived_text_offset) {
                return if (short_text_len) binary_node_batch_compact_short_derived_text_offset_row_len else binary_node_batch_compact_derived_text_offset_row_len;
            }
            return if (short_text_len) binary_node_batch_compact_short_text_len_row_len else binary_node_batch_compact_row_len;
        }

        pub fn binaryNodeBatchPayloadLen(node_count: usize, compact_dense_uniform: bool, short_text_len: bool, derived_text_offset: bool) !u32 {
            if (node_count == 0 or node_count > binary_node_batch_max_count) return error.RecordTooLarge;
            if (short_text_len and !compact_dense_uniform) return error.InvalidRecord;
            if (derived_text_offset and !compact_dense_uniform) return error.InvalidRecord;
            const header_len: usize = if (compact_dense_uniform)
                binary_node_batch_compact_header_len + if (derived_text_offset) binary_node_batch_derived_text_offset_header_extra_len else 0
            else
                binary_node_batch_base_header_len;
            const row_len: usize = if (compact_dense_uniform)
                binaryNodeBatchCompactRowLen(short_text_len, derived_text_offset)
            else
                binary_node_payload_len;
            const body_len = std.math.mul(usize, node_count, row_len) catch return error.RecordTooLarge;
            const payload_len = std.math.add(usize, header_len, body_len) catch return error.RecordTooLarge;
            if (payload_len > BinaryRecordHeader.max_payload_len) return error.RecordTooLarge;
            return @intCast(payload_len);
        }

        pub fn binaryNodeBatchCountFromPrefix(prefix: []const u8, payload_len: u32) !u32 {
            if (prefix.len < binary_node_batch_base_header_len) return error.InvalidRecord;
            const count = readU32(prefix[0..4]);
            if (count == 0 or count > binary_node_batch_max_count) return error.InvalidRecord;
            const flags = readU16(prefix[4..6]);
            var header_len: usize = binary_node_batch_base_header_len;
            var row_len: usize = binary_node_payload_len;
            if (flags == 0) {
                // Full rows carry id and kind per node.
            } else if ((flags & ~binary_node_batch_known_flags) == 0 and (flags & binary_node_batch_compact_flags) == binary_node_batch_compact_flags) {
                if (prefix.len < binary_node_batch_compact_header_len) return error.InvalidRecord;
                _ = nodeKindFromInt(readU16(prefix[6..8])) orelse return error.InvalidRecord;
                const base_id = readU64(prefix[8..16]);
                if (base_id == 0 or base_id == std.math.maxInt(u64)) return error.InvalidRecord;
                const last_id = std.math.add(u64, base_id, @as(u64, count) - 1) catch return error.InvalidRecord;
                if (last_id == std.math.maxInt(u64)) return error.InvalidRecord;
                const short_text_len = (flags & binary_node_batch_flag_short_text_len) != 0;
                const derived_text_offset = (flags & binary_node_batch_flag_derived_text_offset) != 0;
                header_len = binary_node_batch_compact_header_len + if (derived_text_offset) binary_node_batch_derived_text_offset_header_extra_len else 0;
                if (prefix.len < header_len) return error.InvalidRecord;
                row_len = binaryNodeBatchCompactRowLen(short_text_len, derived_text_offset);
            } else {
                return error.InvalidRecord;
            }
            const body_len = std.math.mul(usize, @intCast(count), row_len) catch return error.InvalidRecord;
            const expected_len = std.math.add(usize, header_len, body_len) catch return error.InvalidRecord;
            if (expected_len != payload_len) return error.InvalidRecord;
            return count;
        }

        pub fn validateBinaryNodeBatchHeader(payload: []const u8) !ParsedBinaryNodeBatch {
            if (payload.len < binary_node_batch_base_header_len) return error.InvalidRecord;
            const count = readU32(payload[0..4]);
            if (count == 0 or count > binary_node_batch_max_count) return error.InvalidRecord;
            const flags = readU16(payload[4..6]);
            var header = ParsedBinaryNodeBatch{
                .count = count,
                .flags = flags,
                .header_len = binary_node_batch_base_header_len,
                .row_len = binary_node_payload_len,
            };
            if (flags == 0) {
                // Full rows carry id and kind per node.
            } else if ((flags & ~binary_node_batch_known_flags) == 0 and (flags & binary_node_batch_compact_flags) == binary_node_batch_compact_flags) {
                if (payload.len < binary_node_batch_compact_header_len) return error.InvalidRecord;
                const kind_int = readU16(payload[6..8]);
                const node_kind = nodeKindFromInt(kind_int) orelse return error.InvalidRecord;
                const base_id = readU64(payload[8..16]);
                if (base_id == 0 or base_id == std.math.maxInt(u64)) return error.InvalidRecord;
                const last_offset: u64 = @as(u64, count) - 1;
                const last_id = std.math.add(u64, base_id, last_offset) catch return error.InvalidRecord;
                if (last_id == std.math.maxInt(u64)) return error.InvalidRecord;
                const short_text_len = (flags & binary_node_batch_flag_short_text_len) != 0;
                const derived_text_offset = (flags & binary_node_batch_flag_derived_text_offset) != 0;
                header.header_len = binary_node_batch_compact_header_len;
                if (derived_text_offset) {
                    header.header_len += binary_node_batch_derived_text_offset_header_extra_len;
                    if (payload.len < header.header_len) return error.InvalidRecord;
                    header.base_text_offset = readU48(payload[16..22]);
                }
                header.row_len = binaryNodeBatchCompactRowLen(short_text_len, derived_text_offset);
                header.dense_base_id = base_id;
                header.uniform_kind = node_kind;
                header.short_text_len = short_text_len;
                header.derived_text_offset = derived_text_offset;
            } else {
                return error.InvalidRecord;
            }
            const body_len = std.math.mul(usize, @intCast(count), header.row_len) catch return error.InvalidRecord;
            const expected_len = std.math.add(usize, header.header_len, body_len) catch return error.InvalidRecord;
            if (payload.len != expected_len) return error.InvalidRecord;
            return header;
        }

        pub fn validateBinaryNodeBatchNode(payload: []const u8, batch: ParsedBinaryNodeBatch, index: u32) !ParsedBinaryNode {
            if (index >= batch.count) return error.InvalidRecord;
            const row_offset = std.math.add(usize, batch.header_len, std.math.mul(usize, @intCast(index), batch.row_len) catch return error.InvalidRecord) catch return error.InvalidRecord;
            if (batch.flags == 0) {
                return validateBinaryNodePayload(payload[row_offset..][0..binary_node_payload_len]);
            }
            if ((batch.flags & binary_node_batch_compact_flags) != binary_node_batch_compact_flags) return error.InvalidRecord;
            const row = payload[row_offset..][0..batch.row_len];
            const id = std.math.add(u64, batch.dense_base_id, index) catch return error.InvalidRecord;
            if (batch.derived_text_offset) return error.InvalidRecord;
            const text_offset = readU48(row[0..6]);
            const text_len: u32 = if (batch.short_text_len) readU16(row[6..8]) else readU32(row[6..10]);
            return .{
                .id = id,
                .kind = batch.uniform_kind orelse return error.InvalidRecord,
                .text_offset = text_offset,
                .text_len = text_len,
            };
        }

        pub fn validateBinaryNodeBatchPayload(payload: []const u8) !void {
            var reader = try BinaryNodeBatchReader.init(payload);
            while (try reader.next()) |_| {}
        }

        pub const BinaryNodeBatchReader = struct {
            payload: []const u8,
            batch: ParsedBinaryNodeBatch,
            index: u32 = 0,
            next_text_offset: u64 = 0,

            pub fn init(payload: []const u8) !BinaryNodeBatchReader {
                const batch = try validateBinaryNodeBatchHeader(payload);
                return .{
                    .payload = payload,
                    .batch = batch,
                    .next_text_offset = batch.base_text_offset,
                };
            }

            pub fn next(self: *BinaryNodeBatchReader) !?ParsedBinaryNode {
                if (self.index >= self.batch.count) return null;
                const index = self.index;
                self.index += 1;
                if (self.batch.flags == 0) {
                    return try validateBinaryNodeBatchNode(self.payload, self.batch, index);
                }
                if ((self.batch.flags & binary_node_batch_compact_flags) != binary_node_batch_compact_flags) return error.InvalidRecord;
                const row_offset = std.math.add(usize, self.batch.header_len, std.math.mul(usize, @intCast(index), self.batch.row_len) catch return error.InvalidRecord) catch return error.InvalidRecord;
                const row = self.payload[row_offset..][0..self.batch.row_len];
                const id = std.math.add(u64, self.batch.dense_base_id, index) catch return error.InvalidRecord;
                const text_len: u32 = if (self.batch.derived_text_offset)
                    if (self.batch.short_text_len) readU16(row[0..2]) else readU32(row[0..4])
                else if (self.batch.short_text_len) readU16(row[6..8]) else readU32(row[6..10]);
                const text_offset = if (self.batch.derived_text_offset) offset: {
                    const current = self.next_text_offset;
                    self.next_text_offset = std.math.add(u64, self.next_text_offset, text_len) catch return error.InvalidRecord;
                    break :offset current;
                } else readU48(row[0..6]);
                return .{
                    .id = id,
                    .kind = self.batch.uniform_kind orelse return error.InvalidRecord,
                    .text_offset = text_offset,
                    .text_len = text_len,
                };
            }
        };

        pub const ParsedBinaryEdge = struct {
            id: u64,
            src: u64,
            rel: core.RelKind,
            dst: u64,
        };

        pub const BinaryEdgeBatchCompactShape = struct {
            default_rel: u16,
            base_id: u64,
            compact_node_ids: bool = false,
            linear_endpoint_runs: bool = false,
            endpoint_run_count: u32 = 0,
            exception_count: u8 = 0,
            exception_ordinals: [binary_edge_batch_max_rel_exceptions]u32 = [_]u32{0} ** binary_edge_batch_max_rel_exceptions,
            exception_rels: [binary_edge_batch_max_rel_exceptions]u16 = [_]u16{0} ** binary_edge_batch_max_rel_exceptions,
        };

        pub const ParsedBinaryEdgeBatch = struct {
            count: u32,
            flags: u16,
            header_len: usize,
            row_len: usize,
            dense_base_id: u64 = 0,
            compact_node_ids: bool = false,
            linear_endpoint_runs: bool = false,
            endpoint_run_count: u32 = 0,
            endpoint_runs_offset: usize = 0,
            default_rel: u16 = 0,
            exception_count: u8 = 0,
            exception_ordinals: [binary_edge_batch_max_rel_exceptions]u32 = [_]u32{0} ** binary_edge_batch_max_rel_exceptions,
            exception_rels: [binary_edge_batch_max_rel_exceptions]u16 = [_]u16{0} ** binary_edge_batch_max_rel_exceptions,
        };

        pub const BinaryEdgeBatchEndpointRun = struct {
            src_base: u32,
            start: u32,
            dst_base: u32,
        };

        pub fn validateBinaryEdgePayload(payload: []const u8) !ParsedBinaryEdge {
            if (payload.len != binary_edge_payload_len) return error.InvalidRecord;
            const id = readU64(payload[0..8]);
            const src = readU64(payload[8..16]);
            const rel_int = readU16(payload[16..18]);
            const dst = readU64(payload[18..26]);
            if (id == 0 or src == 0 or dst == 0) return error.InvalidRecord;
            if (id == std.math.maxInt(u64) or src == std.math.maxInt(u64) or dst == std.math.maxInt(u64)) return error.InvalidRecord;
            const rel = relKindFromInt(rel_int) orelse return error.InvalidRecord;
            return .{ .id = id, .src = src, .rel = rel, .dst = dst };
        }

        pub fn binaryEdgeBatchDenseDerivedRelShape(edges: anytype) ?BinaryEdgeBatchCompactShape {
            if (edges.len == 0) return null;
            const base_id = edges[0].id.toInt();
            if (base_id == 0 or base_id == std.math.maxInt(u64)) return null;
            var compact_node_ids = true;
            var counts: [edge_index_rel_kind_count]u64 = [_]u64{0} ** edge_index_rel_kind_count;
            for (edges, 0..) |edge, ordinal| {
                const expected_id = std.math.add(u64, base_id, @intCast(ordinal)) catch return null;
                if (expected_id == std.math.maxInt(u64) or edge.id.toInt() != expected_id) return null;
                if (edge.src.toInt() == 0 or edge.dst.toInt() == 0) return null;
                if (edge.src.toInt() == std.math.maxInt(u64) or edge.dst.toInt() == std.math.maxInt(u64)) return null;
                if (edge.src.toInt() > std.math.maxInt(u32) or edge.dst.toInt() > std.math.maxInt(u32)) compact_node_ids = false;
                counts[@intFromEnum(edge.rel)] += 1;
            }
            const default_rel = edgeIndexDefaultRelFromCounts(counts, @intCast(edges.len)) orelse return null;
            var shape = BinaryEdgeBatchCompactShape{
                .default_rel = default_rel,
                .base_id = base_id,
                .compact_node_ids = compact_node_ids,
            };
            if (compact_node_ids) {
                if (binaryEdgeBatchEndpointRunCount(edges)) |run_count| {
                    const run_bytes = std.math.add(usize, 4, std.math.mul(usize, @intCast(run_count), binary_edge_batch_endpoint_run_len) catch return null) catch return null;
                    const row_bytes = std.math.mul(usize, edges.len, binary_edge_batch_compact_u32_row_len) catch return null;
                    if (run_count != 0 and run_bytes < row_bytes) {
                        shape.linear_endpoint_runs = true;
                        shape.endpoint_run_count = run_count;
                    }
                }
            }
            for (edges, 0..) |edge, ordinal| {
                const rel: u16 = @intFromEnum(edge.rel);
                if (rel == default_rel) continue;
                if (shape.exception_count >= binary_edge_batch_max_rel_exceptions) return null;
                const exception_index = shape.exception_count;
                shape.exception_ordinals[exception_index] = @intCast(ordinal);
                shape.exception_rels[exception_index] = rel;
                shape.exception_count += 1;
            }
            return shape;
        }

        pub fn binaryEdgeBatchEndpointRunCount(edges: anytype) ?u32 {
            if (edges.len == 0) return 0;
            if (!binaryEdgeBatchEndpointCanStartRun(edges[0])) return null;
            var run_count: u64 = 1;
            for (edges[1..], 1..) |edge, i| {
                if (!binaryEdgeBatchEndpointCanStartRun(edge)) return null;
                if (binaryEdgeBatchEndpointContinuesRun(edges[i - 1], edge)) continue;
                run_count = std.math.add(u64, run_count, 1) catch return null;
            }
            if (run_count > std.math.maxInt(u32)) return null;
            return @intCast(run_count);
        }

        pub fn binaryEdgeBatchEndpointCanStartRun(edge: anytype) bool {
            const src = edge.src.toInt();
            const dst = edge.dst.toInt();
            return src != 0 and dst != 0 and src <= std.math.maxInt(u32) and dst <= std.math.maxInt(u32);
        }

        pub fn binaryEdgeBatchEndpointContinuesRun(previous: anytype, edge: anytype) bool {
            const expected_src = std.math.add(u64, previous.src.toInt(), 1) catch return false;
            const expected_dst = std.math.add(u64, previous.dst.toInt(), 1) catch return false;
            return edge.src.toInt() == expected_src and edge.dst.toInt() == expected_dst;
        }

        pub fn binaryEdgeBatchEndpointStartsNewRun(edges: anytype, index: usize) bool {
            if (index == 0) return true;
            return !binaryEdgeBatchEndpointContinuesRun(edges[index - 1], edges[index]);
        }

        pub fn binaryEdgeBatchPayloadLen(edge_count: usize, compact_dense_derived_rel: ?BinaryEdgeBatchCompactShape) !u32 {
            if (edge_count == 0 or edge_count > binary_edge_batch_max_count) return error.RecordTooLarge;
            const header_len: usize = if (compact_dense_derived_rel) |shape| header_len: {
                var len = binary_edge_batch_compact_fixed_header_len + @as(usize, shape.exception_count) * binary_edge_batch_compact_exception_len;
                if (shape.linear_endpoint_runs) {
                    len = std.math.add(usize, len, 4) catch return error.RecordTooLarge;
                    len = std.math.add(usize, len, std.math.mul(usize, @intCast(shape.endpoint_run_count), binary_edge_batch_endpoint_run_len) catch return error.RecordTooLarge) catch return error.RecordTooLarge;
                }
                break :header_len len;
            } else binary_edge_batch_base_header_len;
            const row_len: usize = if (compact_dense_derived_rel) |shape|
                if (shape.linear_endpoint_runs) 0 else if (shape.compact_node_ids) binary_edge_batch_compact_u32_row_len else binary_edge_batch_compact_row_len
            else
                binary_edge_payload_len;
            const body_len = std.math.mul(usize, edge_count, row_len) catch return error.RecordTooLarge;
            const payload_len = std.math.add(usize, header_len, body_len) catch return error.RecordTooLarge;
            if (payload_len > BinaryRecordHeader.max_payload_len) return error.RecordTooLarge;
            return @intCast(payload_len);
        }

        pub fn validateBinaryEdgeBatchHeader(payload: []const u8) !ParsedBinaryEdgeBatch {
            if (payload.len < binary_edge_batch_base_header_len) return error.InvalidRecord;
            const count = readU32(payload[0..4]);
            if (count == 0 or count > binary_edge_batch_max_count) return error.InvalidRecord;
            const flags = readU16(payload[4..6]);
            var header = ParsedBinaryEdgeBatch{
                .count = count,
                .flags = flags,
                .header_len = binary_edge_batch_base_header_len,
                .row_len = binary_edge_payload_len,
            };
            if (flags == 0) {
                // Full rows carry id and relation per edge.
            } else if ((flags & binary_edge_batch_compact_flags) == binary_edge_batch_compact_flags) {
                if ((flags & ~binary_edge_batch_known_flags) != 0) return error.InvalidRecord;
                if (payload.len < binary_edge_batch_compact_fixed_header_len) return error.InvalidRecord;
                const default_rel = readU16(payload[6..8]);
                if (relKindFromInt(default_rel) == null) return error.InvalidRecord;
                const base_id = readU64(payload[8..16]);
                if (base_id == 0 or base_id == std.math.maxInt(u64)) return error.InvalidRecord;
                const last_offset: u64 = @as(u64, count) - 1;
                const last_id = std.math.add(u64, base_id, last_offset) catch return error.InvalidRecord;
                if (last_id == std.math.maxInt(u64)) return error.InvalidRecord;
                const exception_count = payload[16];
                if (exception_count > binary_edge_batch_max_rel_exceptions) return error.InvalidRecord;
                header.header_len = binary_edge_batch_compact_fixed_header_len + @as(usize, exception_count) * binary_edge_batch_compact_exception_len;
                if (payload.len < header.header_len) return error.InvalidRecord;
                header.dense_base_id = base_id;
                header.compact_node_ids = (flags & binary_edge_batch_flag_u32_node_ids) != 0;
                header.linear_endpoint_runs = (flags & binary_edge_batch_flag_linear_endpoints) != 0;
                if (header.linear_endpoint_runs and !header.compact_node_ids) return error.InvalidRecord;
                header.row_len = if (header.linear_endpoint_runs) 0 else if (header.compact_node_ids) binary_edge_batch_compact_u32_row_len else binary_edge_batch_compact_row_len;
                header.default_rel = default_rel;
                header.exception_count = exception_count;
                var previous_ordinal: ?u32 = null;
                var exception_index: usize = 0;
                var exception_offset: usize = binary_edge_batch_compact_fixed_header_len;
                while (exception_index < exception_count) : (exception_index += 1) {
                    const ordinal = readU32(payload[exception_offset..][0..4]);
                    const rel = readU16(payload[exception_offset + 4 ..][0..2]);
                    if (ordinal >= count) return error.InvalidRecord;
                    if (previous_ordinal) |previous| {
                        if (ordinal <= previous) return error.InvalidRecord;
                    }
                    if (rel == default_rel or relKindFromInt(rel) == null) return error.InvalidRecord;
                    header.exception_ordinals[exception_index] = ordinal;
                    header.exception_rels[exception_index] = rel;
                    previous_ordinal = ordinal;
                    exception_offset += binary_edge_batch_compact_exception_len;
                }
                if (header.linear_endpoint_runs) {
                    if (payload.len < header.header_len + 4) return error.InvalidRecord;
                    header.endpoint_run_count = readU32(payload[header.header_len..][0..4]);
                    if (header.endpoint_run_count == 0 or header.endpoint_run_count > count) return error.InvalidRecord;
                    header.endpoint_runs_offset = header.header_len + 4;
                    const run_bytes = std.math.mul(usize, @intCast(header.endpoint_run_count), binary_edge_batch_endpoint_run_len) catch return error.InvalidRecord;
                    header.header_len = std.math.add(usize, header.endpoint_runs_offset, run_bytes) catch return error.InvalidRecord;
                    if (payload.len < header.header_len) return error.InvalidRecord;
                    var run_index: u32 = 0;
                    var previous_start: ?u32 = null;
                    while (run_index < header.endpoint_run_count) : (run_index += 1) {
                        const run = try readBinaryEdgeBatchEndpointRun(payload, header, run_index);
                        if (run_index == 0 and run.start != 0) return error.InvalidRecord;
                        if (run.start >= count) return error.InvalidRecord;
                        if (previous_start) |start| {
                            if (run.start <= start) return error.InvalidRecord;
                        }
                        const end = if (run_index + 1 < header.endpoint_run_count)
                            (try readBinaryEdgeBatchEndpointRun(payload, header, run_index + 1)).start
                        else
                            count;
                        if (end <= run.start) return error.InvalidRecord;
                        const last_delta = end - run.start - 1;
                        const last_src = std.math.add(u64, run.src_base, last_delta) catch return error.InvalidRecord;
                        const last_dst = std.math.add(u64, run.dst_base, last_delta) catch return error.InvalidRecord;
                        if (last_src > std.math.maxInt(u32) or last_dst > std.math.maxInt(u32)) return error.InvalidRecord;
                        previous_start = run.start;
                    }
                }
            } else {
                return error.InvalidRecord;
            }
            const body_len = std.math.mul(usize, @intCast(count), header.row_len) catch return error.InvalidRecord;
            const expected_len = std.math.add(usize, header.header_len, body_len) catch return error.InvalidRecord;
            if (payload.len != expected_len) return error.InvalidRecord;
            return header;
        }

        pub fn binaryEdgeBatchRelAt(batch: ParsedBinaryEdgeBatch, index: u32) !core.RelKind {
            if (index >= batch.count) return error.InvalidRecord;
            if (batch.flags == 0) return error.InvalidRecord;
            var rel = batch.default_rel;
            var exception_index: usize = 0;
            while (exception_index < batch.exception_count) : (exception_index += 1) {
                if (batch.exception_ordinals[exception_index] == index) {
                    rel = batch.exception_rels[exception_index];
                    break;
                }
            }
            return relKindFromInt(rel) orelse error.InvalidRecord;
        }

        pub fn readBinaryEdgeBatchEndpointRun(payload: []const u8, batch: ParsedBinaryEdgeBatch, run_index: u32) !BinaryEdgeBatchEndpointRun {
            if (!batch.linear_endpoint_runs or run_index >= batch.endpoint_run_count) return error.InvalidRecord;
            const offset = std.math.add(usize, batch.endpoint_runs_offset, std.math.mul(usize, @intCast(run_index), binary_edge_batch_endpoint_run_len) catch return error.InvalidRecord) catch return error.InvalidRecord;
            const end = std.math.add(usize, offset, binary_edge_batch_endpoint_run_len) catch return error.InvalidRecord;
            if (end > payload.len) return error.InvalidRecord;
            const bytes = payload[offset..][0..binary_edge_batch_endpoint_run_len];
            const src_base = readU32(bytes[0..4]);
            const start = readU32(bytes[4..8]);
            const dst_base = readU32(bytes[8..12]);
            if (src_base == 0 or dst_base == 0) return error.InvalidRecord;
            return .{
                .src_base = src_base,
                .start = start,
                .dst_base = dst_base,
            };
        }

        pub fn binaryEdgeBatchEndpointRunForIndex(payload: []const u8, batch: ParsedBinaryEdgeBatch, index: u32) !BinaryEdgeBatchEndpointRun {
            if (!batch.linear_endpoint_runs or index >= batch.count) return error.InvalidRecord;
            var lo: u32 = 0;
            var hi = batch.endpoint_run_count;
            while (lo < hi) {
                const mid = lo + (hi - lo) / 2;
                const run = try readBinaryEdgeBatchEndpointRun(payload, batch, mid);
                if (run.start <= index) {
                    lo = mid + 1;
                } else {
                    hi = mid;
                }
            }
            if (lo == 0) return error.InvalidRecord;
            return readBinaryEdgeBatchEndpointRun(payload, batch, lo - 1);
        }

        pub fn validateBinaryEdgeBatchEdge(payload: []const u8, batch: ParsedBinaryEdgeBatch, index: u32) !ParsedBinaryEdge {
            if (index >= batch.count) return error.InvalidRecord;
            const row_offset = std.math.add(usize, batch.header_len, std.math.mul(usize, @intCast(index), batch.row_len) catch return error.InvalidRecord) catch return error.InvalidRecord;
            if (batch.flags == 0) {
                return validateBinaryEdgePayload(payload[row_offset..][0..binary_edge_payload_len]);
            }
            if ((batch.flags & binary_edge_batch_compact_flags) != binary_edge_batch_compact_flags) return error.InvalidRecord;
            const id = std.math.add(u64, batch.dense_base_id, index) catch return error.InvalidRecord;
            const src: u64, const dst: u64 = if (batch.linear_endpoint_runs) endpoints: {
                const run = try binaryEdgeBatchEndpointRunForIndex(payload, batch, index);
                if (index < run.start) return error.InvalidRecord;
                const delta = index - run.start;
                break :endpoints .{
                    std.math.add(u64, run.src_base, delta) catch return error.InvalidRecord,
                    std.math.add(u64, run.dst_base, delta) catch return error.InvalidRecord,
                };
            } else endpoints: {
                const src = if (batch.compact_node_ids) src: {
                    const row = payload[row_offset..][0..binary_edge_batch_compact_u32_row_len];
                    break :src @as(u64, readU32(row[0..4]));
                } else src: {
                    const row = payload[row_offset..][0..binary_edge_batch_compact_row_len];
                    break :src readU64(row[0..8]);
                };
                const dst = if (batch.compact_node_ids) dst: {
                    const row = payload[row_offset..][0..binary_edge_batch_compact_u32_row_len];
                    break :dst @as(u64, readU32(row[4..8]));
                } else dst: {
                    const row = payload[row_offset..][0..binary_edge_batch_compact_row_len];
                    break :dst readU64(row[8..16]);
                };
                break :endpoints .{ src, dst };
            };
            if (src == 0 or dst == 0) return error.InvalidRecord;
            if (src == std.math.maxInt(u64) or dst == std.math.maxInt(u64)) return error.InvalidRecord;
            if (batch.compact_node_ids and (src > std.math.maxInt(u32) or dst > std.math.maxInt(u32))) return error.InvalidRecord;
            return .{
                .id = id,
                .src = src,
                .rel = try binaryEdgeBatchRelAt(batch, index),
                .dst = dst,
            };
        }

        pub fn validateBinaryEdgeBatchPayload(payload: []const u8) !void {
            const batch = try validateBinaryEdgeBatchHeader(payload);
            var index: u32 = 0;
            while (index < batch.count) : (index += 1) {
                _ = try validateBinaryEdgeBatchEdge(payload, batch, index);
            }
        }

        pub fn validateBinaryEdgeDeletePayload(payload: []const u8) !core.EdgeId {
            if (payload.len != binary_edge_delete_payload_len) return error.InvalidRecord;
            const id = readU64(payload[0..8]);
            if (id == 0 or id == std.math.maxInt(u64)) return error.InvalidRecord;
            return core.EdgeId.fromInt(id);
        }

        pub fn nodeKindFromInt(value: u16) ?core.NodeKind {
            if (value >= max_node_types) return null;
            return @enumFromInt(value);
        }

        pub fn relKindFromInt(value: u16) ?core.RelKind {
            if (value >= max_relation_types) return null;
            return @enumFromInt(value);
        }

        pub fn appendU16(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u16) !void {
            var bytes: [2]u8 = undefined;
            std.mem.writeInt(u16, &bytes, value, .little);
            try out.appendSlice(allocator, &bytes);
        }

        pub fn appendU32(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u32) !void {
            var bytes: [4]u8 = undefined;
            std.mem.writeInt(u32, &bytes, value, .little);
            try out.appendSlice(allocator, &bytes);
        }

        pub fn appendU64(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u64) !void {
            var bytes: [8]u8 = undefined;
            std.mem.writeInt(u64, &bytes, value, .little);
            try out.appendSlice(allocator, &bytes);
        }

        pub fn writeU48(bytes: []u8, value: u64) !void {
            std.debug.assert(bytes.len == 6);
            const packed_value = std.math.cast(u48, value) orelse return error.RecordTooLarge;
            std.mem.writeInt(u48, bytes[0..6], packed_value, .little);
        }

        pub fn writeU16(bytes: []u8, value: u16) void {
            std.mem.writeInt(u16, bytes[0..2], value, .little);
        }

        pub fn writeU32(bytes: []u8, value: u32) void {
            std.mem.writeInt(u32, bytes[0..4], value, .little);
        }

        pub fn writeU64(bytes: []u8, value: u64) void {
            std.mem.writeInt(u64, bytes[0..8], value, .little);
        }

        pub fn readU16(bytes: []const u8) u16 {
            return std.mem.readInt(u16, bytes[0..2], .little);
        }

        pub fn readU32(bytes: []const u8) u32 {
            return std.mem.readInt(u32, bytes[0..4], .little);
        }

        pub fn readU48(bytes: []const u8) u64 {
            std.debug.assert(bytes.len == 6);
            return @intCast(std.mem.readInt(u48, bytes[0..6], .little));
        }

        pub fn readU64(bytes: []const u8) u64 {
            return std.mem.readInt(u64, bytes[0..8], .little);
        }
    };
}

const TestId = struct {
    value: u64,

    pub fn fromInt(value: u64) TestId {
        return .{ .value = value };
    }

    pub fn toInt(self: TestId) u64 {
        return self.value;
    }
};

const TestCore = struct {
    pub const NodeId = TestId;
    pub const EdgeId = TestId;
    pub const NodeKind = enum(u16) {
        kind_0,
        kind_1,
        kind_2,
        kind_3,
    };
    pub const RelKind = enum(u16) {
        rel_0,
        rel_1,
        rel_2,
        rel_3,
        rel_4,
        rel_5,
        rel_6,
        rel_7,
    };
    pub const Error = error{
        BudgetExceeded,
        InvalidId,
        NotFound,
    };
};

const TestCodec = BinaryEventLogCodec(TestCore, 4, 8);

const TestNode = struct {
    id: TestId,
    kind: TestCore.NodeKind,
    text: []const u8,
};

const TestEdge = struct {
    id: TestId,
    src: TestId,
    rel: TestCore.RelKind,
    dst: TestId,
};

const TestSpan = struct {
    offset: u64,
    len: u32,
};

const TestWriter = struct {
    bytes: std.ArrayList(u8) = .empty,

    fn deinit(self: *TestWriter) void {
        self.bytes.deinit(std.testing.allocator);
    }

    pub fn append(self: *TestWriter, bytes: []const u8) !void {
        try self.bytes.appendSlice(std.testing.allocator, bytes);
    }
};

const TestDeadline = struct {
    is_expired: bool = false,

    pub fn expired(self: TestDeadline) bool {
        return self.is_expired;
    }
};

const TestGraph = struct {
    edges: [8]TestEdge = undefined,
    edge_count: usize = 0,
    deleted_edge_id: u64 = 0,

    pub fn addEdgeWithIdUnchecked(
        self: *TestGraph,
        id: TestId,
        src: TestId,
        rel: TestCore.RelKind,
        dst: TestId,
    ) TestCore.Error!void {
        if (id.toInt() == 0 or src.toInt() == 0 or dst.toInt() == 0) return error.InvalidId;
        self.edges[self.edge_count] = .{ .id = id, .src = src, .rel = rel, .dst = dst };
        self.edge_count += 1;
    }

    pub fn deleteEdgeById(self: *TestGraph, id: TestId) TestCore.Error!void {
        if (id.toInt() == 0) return error.InvalidId;
        self.deleted_edge_id = id.toInt();
    }
};

test "binary event log header and checksum reject corrupt records" {
    const payload = "payload";
    var bytes: [TestCodec.BinaryRecordHeader.encoded_len]u8 = undefined;
    TestCodec.encodeBinaryRecordHeader(&bytes, .edge, payload.len, TestCodec.binaryPayloadChecksum(payload));

    const header = try TestCodec.BinaryRecordHeader.decode(&bytes);
    try std.testing.expectEqual(TestCodec.BinaryRecordKind.edge, header.kind);
    try std.testing.expectEqual(@as(u32, payload.len), header.payload_len);
    try TestCodec.validateBinaryChecksum(header, payload);
    try std.testing.expectError(error.InvalidRecord, TestCodec.validateBinaryChecksum(header, "payloae"));

    var corrupt = bytes;
    corrupt[0] ^= 1;
    try std.testing.expectError(error.InvalidRecord, TestCodec.BinaryRecordHeader.decode(&corrupt));
    corrupt = bytes;
    corrupt[5] = '?';
    try std.testing.expectError(error.InvalidRecord, TestCodec.BinaryRecordHeader.decode(&corrupt));
    try std.testing.expectError(error.InvalidRecord, TestCodec.ensureBinaryPayloadFits(20, 18, 3));
}

test "binary event log fixed node and edge records preserve bytes" {
    const node = TestNode{ .id = TestId.fromInt(7), .kind = .kind_2, .text = "node" };
    const span = TestSpan{ .offset = 19, .len = 4 };
    var node_payload: [TestCodec.binary_node_payload_len]u8 = undefined;
    try std.testing.expectEqual(
        @as(u32, TestCodec.binary_node_payload_len),
        try TestCodec.encodeBinaryNodeFixedPayload(&node_payload, node, span),
    );
    try std.testing.expectEqualDeep(
        TestCodec.ParsedBinaryNode{ .id = 7, .kind = .kind_2, .text_offset = 19, .text_len = 4 },
        try TestCodec.validateBinaryNodePayload(&node_payload),
    );

    const edge = TestEdge{
        .id = TestId.fromInt(11),
        .src = TestId.fromInt(7),
        .rel = .rel_3,
        .dst = TestId.fromInt(9),
    };
    var fixed: [TestCodec.binary_edge_record_len]u8 = undefined;
    TestCodec.encodeBinaryEdgeRecord(&fixed, edge);
    const header = try TestCodec.BinaryRecordHeader.decode(fixed[0..TestCodec.BinaryRecordHeader.encoded_len]);
    const payload = fixed[TestCodec.BinaryRecordHeader.encoded_len..];
    try TestCodec.validateBinaryChecksum(header, payload);
    try std.testing.expectEqualDeep(
        TestCodec.ParsedBinaryEdge{ .id = 11, .src = 7, .rel = .rel_3, .dst = 9 },
        try TestCodec.validateBinaryEdgePayload(payload),
    );

    var generic: std.ArrayList(u8) = .empty;
    defer generic.deinit(std.testing.allocator);
    try TestCodec.appendBinaryRecord(&generic, std.testing.allocator, .edge, payload);
    try std.testing.expectEqualSlices(u8, &fixed, generic.items);
}

test "binary event log node batch compact lanes round trip" {
    const nodes = [_]TestNode{
        .{ .id = TestId.fromInt(20), .kind = .kind_1, .text = "a" },
        .{ .id = TestId.fromInt(21), .kind = .kind_1, .text = "bc" },
        .{ .id = TestId.fromInt(22), .kind = .kind_1, .text = "def" },
    };
    const spans = [_]TestSpan{
        .{ .offset = 100, .len = 1 },
        .{ .offset = 101, .len = 2 },
        .{ .offset = 103, .len = 3 },
    };
    var writer = TestWriter{};
    defer writer.deinit();
    try TestCodec.appendBinaryNodeBatchRecordToWriter(&writer, std.testing.allocator, &nodes, &spans);

    const header = try TestCodec.BinaryRecordHeader.decode(writer.bytes.items[0..TestCodec.BinaryRecordHeader.encoded_len]);
    try std.testing.expectEqual(TestCodec.BinaryRecordKind.node_batch, header.kind);
    const payload = writer.bytes.items[TestCodec.BinaryRecordHeader.encoded_len..];
    try TestCodec.validateBinaryChecksum(header, payload);
    var reader = try TestCodec.BinaryNodeBatchReader.init(payload);
    try std.testing.expect(reader.batch.short_text_len);
    try std.testing.expect(reader.batch.derived_text_offset);
    for (nodes, spans) |node, span| {
        const parsed = (try reader.next()).?;
        try std.testing.expectEqual(node.id.toInt(), parsed.id);
        try std.testing.expectEqual(node.kind, parsed.kind);
        try std.testing.expectEqual(span.offset, parsed.text_offset);
        try std.testing.expectEqual(span.len, parsed.text_len);
    }
    try std.testing.expect((try reader.next()) == null);
}

test "binary event log node batch rejects unknown and inconsistent flags" {
    var payload = [_]u8{0} ** (TestCodec.binary_node_batch_compact_header_len + TestCodec.binary_node_batch_compact_short_text_len_row_len);
    std.mem.writeInt(u32, payload[0..4], 1, .little);
    std.mem.writeInt(
        u16,
        payload[4..6],
        TestCodec.binary_node_batch_compact_flags | TestCodec.binary_node_batch_flag_short_text_len | (1 << 15),
        .little,
    );
    std.mem.writeInt(u16, payload[6..8], @intFromEnum(TestCore.NodeKind.kind_1), .little);
    std.mem.writeInt(u64, payload[8..16], 1, .little);
    try std.testing.expectError(error.InvalidRecord, TestCodec.validateBinaryNodeBatchHeader(&payload));
    try std.testing.expectError(error.InvalidRecord, TestCodec.binaryNodeBatchPayloadLen(1, false, true, false));
}

test "binary event log edge batch relation exceptions round trip" {
    const edges = [_]TestEdge{
        .{ .id = TestId.fromInt(30), .src = TestId.fromInt(1), .rel = .rel_1, .dst = TestId.fromInt(4) },
        .{ .id = TestId.fromInt(31), .src = TestId.fromInt(7), .rel = .rel_1, .dst = TestId.fromInt(2) },
        .{ .id = TestId.fromInt(32), .src = TestId.fromInt(3), .rel = .rel_2, .dst = TestId.fromInt(9) },
        .{ .id = TestId.fromInt(33), .src = TestId.fromInt(8), .rel = .rel_1, .dst = TestId.fromInt(5) },
    };
    var writer = TestWriter{};
    defer writer.deinit();
    try TestCodec.appendBinaryEdgeBatchRecordToWriter(&writer, std.testing.allocator, &edges);
    const header = try TestCodec.BinaryRecordHeader.decode(writer.bytes.items[0..TestCodec.BinaryRecordHeader.encoded_len]);
    const payload = writer.bytes.items[TestCodec.BinaryRecordHeader.encoded_len..];
    try TestCodec.validateBinaryChecksum(header, payload);
    const batch = try TestCodec.validateBinaryEdgeBatchHeader(payload);
    try std.testing.expectEqual(@as(u8, 1), batch.exception_count);
    try std.testing.expect(!batch.linear_endpoint_runs);
    for (edges, 0..) |edge, index| {
        const parsed = try TestCodec.validateBinaryEdgeBatchEdge(payload, batch, @intCast(index));
        try std.testing.expectEqual(edge.id.toInt(), parsed.id);
        try std.testing.expectEqual(edge.src.toInt(), parsed.src);
        try std.testing.expectEqual(edge.rel, parsed.rel);
        try std.testing.expectEqual(edge.dst.toInt(), parsed.dst);
    }
}

test "binary event log edge batch linear endpoint runs round trip" {
    const edges = [_]TestEdge{
        .{ .id = TestId.fromInt(40), .src = TestId.fromInt(10), .rel = .rel_4, .dst = TestId.fromInt(20) },
        .{ .id = TestId.fromInt(41), .src = TestId.fromInt(11), .rel = .rel_4, .dst = TestId.fromInt(21) },
        .{ .id = TestId.fromInt(42), .src = TestId.fromInt(12), .rel = .rel_4, .dst = TestId.fromInt(22) },
        .{ .id = TestId.fromInt(43), .src = TestId.fromInt(13), .rel = .rel_4, .dst = TestId.fromInt(23) },
    };
    const shape = TestCodec.binaryEdgeBatchDenseDerivedRelShape(&edges).?;
    try std.testing.expect(shape.linear_endpoint_runs);
    try std.testing.expectEqual(@as(u32, 1), shape.endpoint_run_count);

    var writer = TestWriter{};
    defer writer.deinit();
    try TestCodec.appendBinaryEdgeBatchRecordToWriter(&writer, std.testing.allocator, &edges);
    const payload = writer.bytes.items[TestCodec.BinaryRecordHeader.encoded_len..];
    const batch = try TestCodec.validateBinaryEdgeBatchHeader(payload);
    try std.testing.expect(batch.linear_endpoint_runs);
    try std.testing.expectEqual(@as(usize, 0), batch.row_len);
    for (edges, 0..) |edge, index| {
        const parsed = try TestCodec.validateBinaryEdgeBatchEdge(payload, batch, @intCast(index));
        try std.testing.expectEqual(edge.src.toInt(), parsed.src);
        try std.testing.expectEqual(edge.dst.toInt(), parsed.dst);
    }
}

test "binary event log record validation covers deletes and batch markers" {
    var record: [TestCodec.binary_edge_delete_record_len]u8 = undefined;
    TestCodec.encodeBinaryEdgeDeleteRecord(&record, TestId.fromInt(55));
    const header = try TestCodec.BinaryRecordHeader.decode(record[0..TestCodec.BinaryRecordHeader.encoded_len]);
    const payload = record[TestCodec.BinaryRecordHeader.encoded_len..];
    try TestCodec.validateBinaryChecksum(header, payload);
    try TestCodec.validateBinaryRecordPayload(.edge_delete, payload);
    try std.testing.expectEqual(@as(u64, 55), (try TestCodec.validateBinaryEdgeDeletePayload(payload)).toInt());
    try TestCodec.validateBinaryRecordPayload(.batch_begin, &.{});
    try TestCodec.validateBinaryRecordPayload(.batch_commit, &.{});
    try std.testing.expectError(error.InvalidRecord, TestCodec.validateBinaryRecordPayload(.batch_begin, "x"));
}

test "binary event log replay adapter applies edges deletes and deadline" {
    const edge = TestEdge{
        .id = TestId.fromInt(70),
        .src = TestId.fromInt(3),
        .rel = .rel_2,
        .dst = TestId.fromInt(4),
    };
    var edge_payload: [TestCodec.binary_edge_payload_len]u8 = undefined;
    TestCodec.encodeBinaryEdgePayload(&edge_payload, edge);
    var graph = TestGraph{};
    try TestCodec.replayBinaryRecord(&graph, .edge, &edge_payload, TestDeadline{});
    try std.testing.expectEqual(@as(usize, 1), graph.edge_count);
    try std.testing.expectEqual(@as(u64, 70), graph.edges[0].id.toInt());

    var delete_payload: [TestCodec.binary_edge_delete_payload_len]u8 = undefined;
    std.mem.writeInt(u64, &delete_payload, 70, .little);
    try TestCodec.replayBinaryRecord(&graph, .edge_delete, &delete_payload, TestDeadline{});
    try std.testing.expectEqual(@as(u64, 70), graph.deleted_edge_id);
    try std.testing.expectError(
        error.BudgetExceeded,
        TestCodec.replayBinaryRecord(&graph, .batch_begin, &.{}, TestDeadline{ .is_expired = true }),
    );
    try std.testing.expectError(
        error.InvalidRecord,
        TestCodec.replayBinaryRecord(&graph, .node, &.{}, TestDeadline{}),
    );
}
