const std = @import("std");

/// CSR v23 persisted byte contracts for immutable adjacency segments.
///
/// The facade injects graph identities so this owner remains format-only and
/// can be tested without file, mmap, writer, or query lifetime state.
pub fn CsrFormat(
    comptime core: type,
    comptime Direction: type,
    comptime EdgeRecord: type,
    comptime max_relation_types: u16,
) type {
    return struct {
        pub const SegmentHeader = struct {
            magic: [4]u8 = .{ 'T', 'K', 'A', 'S' },
            version: u16 = current_version,
            header_len: u16 = encoded_len,
            order: Direction,
            edge_count: u64,
            vertex_count: u64,
            relation_count: u64,
            flags: u16 = 0,
            edge_record_len: u16 = StoredEdgeRecord.encoded_len,
            uniform_relation: u16 = 0,
            uniform_single_relation_edge_count: u32 = 0,
            derived_edge_id_base: u64 = 0,
            derived_edge_id_step: u32 = 0,
            derived_edge_id_split_index: u64 = 0,
            derived_edge_id_second_base: u64 = 0,
            derived_edge_id_second_step: u32 = 0,
            derived_vertex_id_base: u64 = 0,
            derived_vertex_id_step: u32 = 0,
            derived_vertex_id_split_index: u64 = 0,
            derived_vertex_id_second_base: u64 = 0,
            derived_vertex_id_second_step: u32 = 0,
            derived_edge_other_node_base: u64 = 0,
            derived_edge_other_node_step: u32 = 0,
            derived_edge_other_node_split_index: u64 = 0,
            derived_edge_other_node_second_base: u64 = 0,
            derived_edge_other_node_second_step: u32 = 0,

            pub const current_version: u16 = 23;
            pub const encoded_len: usize = 129;
            pub const flag_u32_edge_records: u16 = 1 << 0;
            pub const flag_u32_vertex_records: u16 = 1 << 1;
            pub const flag_u16_relation_counts: u16 = 1 << 2;
            pub const flag_uniform_relation: u16 = 1 << 3;
            pub const flag_single_relation_per_vertex: u16 = 1 << 4;
            pub const flag_u24_node_u32_edge_records: u16 = 1 << 5;
            pub const flag_u24_node_u32_vertex_records: u16 = 1 << 6;
            pub const flag_u8_relation_counts: u16 = 1 << 7;
            pub const flag_uniform_relation_value_shift: u4 = 8;
            pub const flag_uniform_relation_value_mask: u16 = 0xff << flag_uniform_relation_value_shift;

            comptime {
                for (@typeInfo(core.RelKind).@"enum".fields) |field| {
                    if (field.value > 0xff) @compileError("CSR single-relation vertex rows require RelKind values <= 255");
                }
            }

            pub fn encode(self: SegmentHeader, out: *[encoded_len]u8) void {
                @memcpy(out[0..4], &self.magic);
                std.mem.writeInt(u16, out[4..6], self.version, .little);
                std.mem.writeInt(u16, out[6..8], self.header_len, .little);
                out[8] = switch (self.order) {
                    .forward => 'F',
                    .reverse => 'R',
                };
                std.mem.writeInt(u16, out[9..11], self.flags, .little);
                std.mem.writeInt(u16, out[11..13], self.edge_record_len, .little);
                std.mem.writeInt(u64, out[13..21], self.vertex_count, .little);
                std.mem.writeInt(u32, out[21..25], self.uniform_single_relation_edge_count, .little);
                std.mem.writeInt(u64, out[25..33], self.derived_edge_id_base, .little);
                std.mem.writeInt(u32, out[33..37], self.derived_edge_id_step, .little);
                std.mem.writeInt(u64, out[37..45], self.derived_edge_id_split_index, .little);
                std.mem.writeInt(u64, out[45..53], self.derived_edge_id_second_base, .little);
                std.mem.writeInt(u32, out[53..57], self.derived_edge_id_second_step, .little);
                std.mem.writeInt(u64, out[57..65], self.derived_vertex_id_base, .little);
                std.mem.writeInt(u32, out[65..69], self.derived_vertex_id_step, .little);
                std.mem.writeInt(u64, out[69..77], self.derived_vertex_id_split_index, .little);
                std.mem.writeInt(u64, out[77..85], self.derived_vertex_id_second_base, .little);
                std.mem.writeInt(u32, out[85..89], self.derived_vertex_id_second_step, .little);
                std.mem.writeInt(u64, out[89..97], self.derived_edge_other_node_base, .little);
                std.mem.writeInt(u32, out[97..101], self.derived_edge_other_node_step, .little);
                std.mem.writeInt(u64, out[101..109], self.derived_edge_other_node_split_index, .little);
                std.mem.writeInt(u64, out[109..117], self.derived_edge_other_node_second_base, .little);
                std.mem.writeInt(u32, out[117..121], self.derived_edge_other_node_second_step, .little);
                std.mem.writeInt(u64, out[121..129], self.edge_count, .little);
            }

            pub fn decode(bytes: []const u8) !SegmentHeader {
                if (bytes.len != encoded_len) return error.InvalidRecord;
                if (!std.mem.eql(u8, bytes[0..4], "TKAS")) return error.InvalidRecord;
                if (std.mem.readInt(u16, bytes[4..6], .little) != current_version) return error.InvalidRecord;
                if (std.mem.readInt(u16, bytes[6..8], .little) != encoded_len) return error.InvalidRecord;
                const order: Direction = switch (bytes[8]) {
                    'F' => .forward,
                    'R' => .reverse,
                    else => return error.InvalidRecord,
                };
                const flags = std.mem.readInt(u16, bytes[9..11], .little);
                const header = SegmentHeader{
                    .order = order,
                    .vertex_count = std.mem.readInt(u64, bytes[13..21], .little),
                    .relation_count = 0,
                    .flags = flags,
                    .edge_record_len = std.mem.readInt(u16, bytes[11..13], .little),
                    .uniform_relation = uniformRelationValueFromFlags(flags),
                    .uniform_single_relation_edge_count = std.mem.readInt(u32, bytes[21..25], .little),
                    .derived_edge_id_base = std.mem.readInt(u64, bytes[25..33], .little),
                    .derived_edge_id_step = std.mem.readInt(u32, bytes[33..37], .little),
                    .derived_edge_id_split_index = std.mem.readInt(u64, bytes[37..45], .little),
                    .derived_edge_id_second_base = std.mem.readInt(u64, bytes[45..53], .little),
                    .derived_edge_id_second_step = std.mem.readInt(u32, bytes[53..57], .little),
                    .derived_vertex_id_base = std.mem.readInt(u64, bytes[57..65], .little),
                    .derived_vertex_id_step = std.mem.readInt(u32, bytes[65..69], .little),
                    .derived_vertex_id_split_index = std.mem.readInt(u64, bytes[69..77], .little),
                    .derived_vertex_id_second_base = std.mem.readInt(u64, bytes[77..85], .little),
                    .derived_vertex_id_second_step = std.mem.readInt(u32, bytes[85..89], .little),
                    .derived_edge_other_node_base = std.mem.readInt(u64, bytes[89..97], .little),
                    .derived_edge_other_node_step = std.mem.readInt(u32, bytes[97..101], .little),
                    .derived_edge_other_node_split_index = std.mem.readInt(u64, bytes[101..109], .little),
                    .derived_edge_other_node_second_base = std.mem.readInt(u64, bytes[109..117], .little),
                    .derived_edge_other_node_second_step = std.mem.readInt(u32, bytes[117..121], .little),
                    .edge_count = std.mem.readInt(u64, bytes[121..129], .little),
                };
                try header.validateShape();
                return header;
            }

            pub fn validateShape(self: SegmentHeader) !void {
                const known_flags = flag_u32_edge_records |
                    flag_u32_vertex_records |
                    flag_u16_relation_counts |
                    flag_uniform_relation |
                    flag_single_relation_per_vertex |
                    flag_u24_node_u32_edge_records |
                    flag_u24_node_u32_vertex_records |
                    flag_u8_relation_counts |
                    flag_uniform_relation_value_mask;
                if ((self.flags & ~known_flags) != 0) return error.InvalidRecord;
                if (self.hasU32EdgeRecords() and self.hasU24NodeU32EdgeRecords()) return error.InvalidRecord;
                if (self.hasU32VertexRecords() and self.hasU24NodeU32VertexRecords()) return error.InvalidRecord;
                if (self.hasU8RelationCounts() and self.hasU16RelationCounts()) return error.InvalidRecord;
                if (self.edge_record_len != self.expectedEdgeRecordLen()) return error.InvalidRecord;
                if (self.hasUniformRelation()) {
                    if (self.uniform_relation != uniformRelationValueFromFlags(self.flags)) return error.InvalidRecord;
                    if (relFromInt(self.uniform_relation) == null) return error.InvalidRecord;
                } else {
                    if ((self.flags & flag_uniform_relation_value_mask) != 0) return error.InvalidRecord;
                    if (self.uniform_relation != 0) return error.InvalidRecord;
                }
                if (self.hasUniformSingleRelationEdgeCount() and !self.hasSingleRelationPerVertex()) return error.InvalidRecord;
                if (self.hasDerivedEdgeIds()) {
                    if (self.derived_edge_id_base == 0 or self.derived_edge_id_base == std.math.maxInt(u64)) return error.InvalidRecord;
                    if (self.derived_edge_id_split_index == 0) {
                        if (self.derived_edge_id_second_base != 0 or self.derived_edge_id_second_step != 0) return error.InvalidRecord;
                    } else {
                        if (self.derived_edge_id_second_base == 0 or self.derived_edge_id_second_base == std.math.maxInt(u64)) return error.InvalidRecord;
                        if (self.derived_edge_id_second_step == 0) return error.InvalidRecord;
                    }
                } else if (self.derived_edge_id_base != 0) {
                    return error.InvalidRecord;
                } else if (self.derived_edge_id_split_index != 0 or self.derived_edge_id_second_base != 0 or self.derived_edge_id_second_step != 0) {
                    return error.InvalidRecord;
                }
                if (self.hasDerivedVertexIds()) {
                    if (!self.hasSingleRelationPerVertex() or !self.hasUniformRelation() or !self.hasUniformSingleRelationEdgeCount()) return error.InvalidRecord;
                    if (self.derived_vertex_id_base == 0 or self.derived_vertex_id_base == std.math.maxInt(u64)) return error.InvalidRecord;
                    if (self.derived_vertex_id_split_index == 0) {
                        if (self.derived_vertex_id_second_base != 0 or self.derived_vertex_id_second_step != 0) return error.InvalidRecord;
                    } else {
                        if (self.derived_vertex_id_second_base == 0 or self.derived_vertex_id_second_base == std.math.maxInt(u64)) return error.InvalidRecord;
                        if (self.derived_vertex_id_second_step == 0) return error.InvalidRecord;
                    }
                } else if (self.derived_vertex_id_base != 0) {
                    return error.InvalidRecord;
                } else if (self.derived_vertex_id_split_index != 0 or self.derived_vertex_id_second_base != 0 or self.derived_vertex_id_second_step != 0) {
                    return error.InvalidRecord;
                }
                if (self.hasDerivedEdgeOtherNodes()) {
                    if (!self.hasDerivedEdgeIds()) return error.InvalidRecord;
                    if (self.derived_edge_other_node_base == 0 or self.derived_edge_other_node_base == std.math.maxInt(u64)) return error.InvalidRecord;
                    if (self.derived_edge_other_node_split_index == 0) {
                        if (self.derived_edge_other_node_second_base != 0 or self.derived_edge_other_node_second_step != 0) return error.InvalidRecord;
                    } else {
                        if (self.derived_edge_other_node_second_base == 0 or self.derived_edge_other_node_second_base == std.math.maxInt(u64)) return error.InvalidRecord;
                        if (self.derived_edge_other_node_second_step == 0) return error.InvalidRecord;
                    }
                } else if (self.derived_edge_other_node_base != 0) {
                    return error.InvalidRecord;
                } else if (self.derived_edge_other_node_split_index != 0 or self.derived_edge_other_node_second_base != 0 or self.derived_edge_other_node_second_step != 0) {
                    return error.InvalidRecord;
                }
            }

            pub fn hasU32EdgeRecords(self: SegmentHeader) bool {
                return (self.flags & flag_u32_edge_records) != 0;
            }

            pub fn hasU24NodeU32EdgeRecords(self: SegmentHeader) bool {
                return (self.flags & flag_u24_node_u32_edge_records) != 0;
            }

            pub fn hasU32VertexRecords(self: SegmentHeader) bool {
                return (self.flags & flag_u32_vertex_records) != 0;
            }

            pub fn hasU24NodeU32VertexRecords(self: SegmentHeader) bool {
                return (self.flags & flag_u24_node_u32_vertex_records) != 0;
            }

            pub fn hasU16RelationCounts(self: SegmentHeader) bool {
                return (self.flags & flag_u16_relation_counts) != 0;
            }

            pub fn hasU8RelationCounts(self: SegmentHeader) bool {
                return (self.flags & flag_u8_relation_counts) != 0;
            }

            pub fn hasUniformRelation(self: SegmentHeader) bool {
                return (self.flags & flag_uniform_relation) != 0;
            }

            pub fn hasSingleRelationPerVertex(self: SegmentHeader) bool {
                return (self.flags & flag_single_relation_per_vertex) != 0;
            }

            pub fn hasUniformSingleRelationEdgeCount(self: SegmentHeader) bool {
                return self.uniform_single_relation_edge_count != 0;
            }

            pub fn hasDerivedEdgeIds(self: SegmentHeader) bool {
                return self.derived_edge_id_step != 0;
            }

            pub fn hasDerivedVertexIds(self: SegmentHeader) bool {
                return self.derived_vertex_id_step != 0;
            }

            pub fn hasDerivedEdgeOtherNodes(self: SegmentHeader) bool {
                return self.derived_edge_other_node_step != 0;
            }

            pub fn uniformRelationValueFromFlags(flags: u16) u16 {
                return (flags & flag_uniform_relation_value_mask) >> flag_uniform_relation_value_shift;
            }

            pub fn expectedEdgeRecordLen(self: SegmentHeader) u16 {
                if (self.hasDerivedEdgeOtherNodes()) return 0;
                if (self.hasDerivedEdgeIds()) {
                    if (self.hasU24NodeU32EdgeRecords()) return StoredEdgeRecord.u24_node_only_encoded_len;
                    return if (self.hasU32EdgeRecords()) StoredEdgeRecord.u32_node_only_encoded_len else StoredEdgeRecord.node_only_encoded_len;
                }
                if (self.hasU24NodeU32EdgeRecords()) return StoredEdgeRecord.u24_node_u32_edge_encoded_len;
                return if (self.hasU32EdgeRecords()) StoredEdgeRecord.u32_encoded_len else StoredEdgeRecord.encoded_len;
            }

            pub fn vertexRecordLen(self: SegmentHeader) u16 {
                if (self.hasDerivedVertexIds()) return 0;
                if (self.hasSingleRelationPerVertex()) {
                    if (self.hasUniformSingleRelationEdgeCount()) {
                        if (self.hasUniformRelation()) {
                            if (self.hasU24NodeU32VertexRecords()) return VertexRecord.single_relation_uniform_edges_u24_node_encoded_len;
                            return if (self.hasU32VertexRecords()) VertexRecord.single_relation_uniform_edges_u32_encoded_len else VertexRecord.single_relation_uniform_edges_encoded_len;
                        }
                        if (self.hasU24NodeU32VertexRecords()) return VertexRecord.single_relation_rel_uniform_edges_u24_node_encoded_len;
                        return if (self.hasU32VertexRecords()) VertexRecord.single_relation_rel_uniform_edges_u32_encoded_len else VertexRecord.single_relation_rel_uniform_edges_encoded_len;
                    }
                    if (self.hasUniformRelation()) {
                        if (self.hasU24NodeU32VertexRecords()) return VertexRecord.single_relation_u24_node_u32_encoded_len;
                        return if (self.hasU32VertexRecords()) VertexRecord.single_relation_u32_encoded_len else VertexRecord.single_relation_encoded_len;
                    }
                    if (self.hasU24NodeU32VertexRecords()) return VertexRecord.single_relation_rel_u24_node_u32_encoded_len;
                    return if (self.hasU32VertexRecords()) VertexRecord.single_relation_rel_u32_encoded_len else VertexRecord.single_relation_rel_encoded_len;
                }
                if (self.hasU24NodeU32VertexRecords()) return VertexRecord.u24_node_u32_encoded_len;
                return if (self.hasU32VertexRecords()) VertexRecord.u32_encoded_len else VertexRecord.encoded_len;
            }

            pub fn relationRecordLen(self: SegmentHeader) u16 {
                if (self.hasSingleRelationPerVertex()) return 0;
                if (self.hasUniformRelation()) {
                    if (self.hasU8RelationCounts()) return RelationRangeRecord.uniform_u8_encoded_len;
                    return if (self.hasU16RelationCounts()) RelationRangeRecord.uniform_u16_encoded_len else RelationRangeRecord.uniform_encoded_len;
                }
                if (self.hasU8RelationCounts()) return RelationRangeRecord.u8_encoded_len;
                return if (self.hasU16RelationCounts()) RelationRangeRecord.u16_encoded_len else RelationRangeRecord.encoded_len;
            }

            pub fn withShape(order: Direction, edge_count: u64, vertex_count: u64, relation_count: u64, u24_node_u32_edge_records: bool, u32_edge_records: bool, u24_node_u32_vertex_records: bool, u32_vertex_records: bool, u8_relation_counts: bool, u16_relation_counts: bool, uniform_relation: ?core.RelKind, single_relation_per_vertex: bool, uniform_single_relation_edge_count: ?u32, derived_edge_ids: ?DerivedEdgeIdShape, derived_vertex_ids: ?DerivedVertexIdShape, derived_edge_other_nodes: ?DerivedEdgeOtherNodeShape) SegmentHeader {
                var header = SegmentHeader{
                    .order = order,
                    .edge_count = edge_count,
                    .vertex_count = vertex_count,
                    .relation_count = relation_count,
                };
                const has_derived_edge_other_nodes = derived_edge_other_nodes != null;
                if (u24_node_u32_edge_records and !has_derived_edge_other_nodes) {
                    header.flags |= flag_u24_node_u32_edge_records;
                } else if (u32_edge_records and !has_derived_edge_other_nodes) {
                    header.flags |= flag_u32_edge_records;
                }
                const has_derived_vertex_ids = derived_vertex_ids != null;
                if (u24_node_u32_vertex_records and !has_derived_vertex_ids) {
                    header.flags |= flag_u24_node_u32_vertex_records;
                } else if (u32_vertex_records and !has_derived_vertex_ids) {
                    header.flags |= flag_u32_vertex_records;
                }
                if (u8_relation_counts) {
                    header.flags |= flag_u8_relation_counts;
                } else if (u16_relation_counts) {
                    header.flags |= flag_u16_relation_counts;
                }
                if (uniform_relation) |rel| {
                    const rel_value: u16 = @intFromEnum(rel);
                    if (rel_value <= 0xff) {
                        header.flags |= flag_uniform_relation;
                        header.uniform_relation = rel_value;
                        header.flags |= header.uniform_relation << flag_uniform_relation_value_shift;
                    }
                }
                if (single_relation_per_vertex) header.flags |= flag_single_relation_per_vertex;
                if (uniform_single_relation_edge_count) |count| header.uniform_single_relation_edge_count = count;
                if (derived_edge_ids) |shape| {
                    header.derived_edge_id_base = shape.base;
                    header.derived_edge_id_step = shape.step;
                    header.derived_edge_id_split_index = shape.split_index;
                    header.derived_edge_id_second_base = shape.second_base;
                    header.derived_edge_id_second_step = shape.second_step;
                }
                if (derived_vertex_ids) |shape| {
                    header.derived_vertex_id_base = shape.base;
                    header.derived_vertex_id_step = shape.step;
                    header.derived_vertex_id_split_index = shape.split_index;
                    header.derived_vertex_id_second_base = shape.second_base;
                    header.derived_vertex_id_second_step = shape.second_step;
                }
                if (derived_edge_other_nodes) |shape| {
                    header.derived_edge_other_node_base = shape.base;
                    header.derived_edge_other_node_step = shape.step;
                    header.derived_edge_other_node_split_index = shape.split_index;
                    header.derived_edge_other_node_second_base = shape.second_base;
                    header.derived_edge_other_node_second_step = shape.second_step;
                }
                header.edge_record_len = header.expectedEdgeRecordLen();
                return header;
            }
        };

        pub const DerivedEdgeIdShape = struct {
            base: u64,
            step: u32,
            split_index: u64 = 0,
            second_base: u64 = 0,
            second_step: u32 = 0,
        };

        pub const DerivedVertexIdShape = struct {
            base: u64,
            step: u32,
            split_index: u64 = 0,
            second_base: u64 = 0,
            second_step: u32 = 0,
        };

        pub const DerivedEdgeOtherNodeShape = struct {
            base: u64,
            step: u32,
            split_index: u64 = 0,
            second_base: u64 = 0,
            second_step: u32 = 0,
        };

        pub fn derivedEdgeIdAt(header: SegmentHeader, index: u64) !u64 {
            if (!header.hasDerivedEdgeIds()) return error.InvalidRecord;
            const base, const step, const run_index = if (header.derived_edge_id_split_index != 0 and index >= header.derived_edge_id_split_index)
                .{ header.derived_edge_id_second_base, header.derived_edge_id_second_step, index - header.derived_edge_id_split_index }
            else
                .{ header.derived_edge_id_base, header.derived_edge_id_step, index };
            const delta = std.math.mul(u64, run_index, step) catch return error.RecordTooLarge;
            const edge_id = std.math.add(u64, base, delta) catch return error.RecordTooLarge;
            if (edge_id == 0 or edge_id == std.math.maxInt(u64)) return error.InvalidRecord;
            return edge_id;
        }

        pub fn derivedEdgeIdShapesEqual(lhs: ?DerivedEdgeIdShape, rhs: ?DerivedEdgeIdShape) bool {
            if (lhs) |left| {
                const right = rhs orelse return false;
                return left.base == right.base and
                    left.step == right.step and
                    left.split_index == right.split_index and
                    left.second_base == right.second_base and
                    left.second_step == right.second_step;
            }
            return rhs == null;
        }

        pub fn derivedVertexIdAt(header: SegmentHeader, index: u64) !u64 {
            if (!header.hasDerivedVertexIds()) return error.InvalidRecord;
            const base, const step, const run_index = if (header.derived_vertex_id_split_index != 0 and index >= header.derived_vertex_id_split_index)
                .{ header.derived_vertex_id_second_base, header.derived_vertex_id_second_step, index - header.derived_vertex_id_split_index }
            else
                .{ header.derived_vertex_id_base, header.derived_vertex_id_step, index };
            const delta = std.math.mul(u64, run_index, step) catch return error.RecordTooLarge;
            const node_id = std.math.add(u64, base, delta) catch return error.RecordTooLarge;
            if (node_id == 0 or node_id == std.math.maxInt(u64)) return error.InvalidRecord;
            return node_id;
        }

        pub fn derivedVertexIdShapesEqual(lhs: ?DerivedVertexIdShape, rhs: ?DerivedVertexIdShape) bool {
            if (lhs) |left| {
                const right = rhs orelse return false;
                return left.base == right.base and
                    left.step == right.step and
                    left.split_index == right.split_index and
                    left.second_base == right.second_base and
                    left.second_step == right.second_step;
            }
            return rhs == null;
        }

        pub fn derivedEdgeOtherNodeAt(header: SegmentHeader, index: u64) !u64 {
            if (!header.hasDerivedEdgeOtherNodes()) return error.InvalidRecord;
            const base, const step, const run_index = if (header.derived_edge_other_node_split_index != 0 and index >= header.derived_edge_other_node_split_index)
                .{ header.derived_edge_other_node_second_base, header.derived_edge_other_node_second_step, index - header.derived_edge_other_node_split_index }
            else
                .{ header.derived_edge_other_node_base, header.derived_edge_other_node_step, index };
            const delta = std.math.mul(u64, run_index, step) catch return error.RecordTooLarge;
            const node_id = std.math.add(u64, base, delta) catch return error.RecordTooLarge;
            if (node_id == 0 or node_id == std.math.maxInt(u64)) return error.InvalidRecord;
            return node_id;
        }

        pub fn derivedEdgeOtherNodeShapesEqual(lhs: ?DerivedEdgeOtherNodeShape, rhs: ?DerivedEdgeOtherNodeShape) bool {
            if (lhs) |left| {
                const right = rhs orelse return false;
                return left.base == right.base and
                    left.step == right.step and
                    left.split_index == right.split_index and
                    left.second_base == right.second_base and
                    left.second_step == right.second_step;
            }
            return rhs == null;
        }

        pub const VertexRecord = struct {
            node_id: u64,
            relation_offset: u64,
            relation_count: u64,
            edge_offset: u64,
            single_relation_rel: u16 = 0,

            pub const encoded_len: usize = 32;
            pub const u32_encoded_len: usize = 16;
            pub const u24_node_u32_encoded_len: usize = 15;
            pub const single_relation_encoded_len: usize = 16;
            pub const single_relation_u32_encoded_len: usize = 8;
            pub const single_relation_u24_node_u32_encoded_len: usize = 7;
            pub const single_relation_rel_encoded_len: usize = 18;
            pub const single_relation_rel_u32_encoded_len: usize = 10;
            pub const single_relation_rel_u24_node_u32_encoded_len: usize = 9;
            pub const single_relation_uniform_edges_encoded_len: usize = 8;
            pub const single_relation_uniform_edges_u32_encoded_len: usize = 4;
            pub const single_relation_uniform_edges_u24_node_encoded_len: usize = 3;
            pub const single_relation_rel_uniform_edges_encoded_len: usize = 10;
            pub const single_relation_rel_uniform_edges_u32_encoded_len: usize = 6;
            pub const single_relation_rel_uniform_edges_u24_node_encoded_len: usize = 5;
            pub const u24_node_max: u64 = (1 << 24) - 1;

            pub fn hasU32Shape(self: VertexRecord) bool {
                return self.node_id <= std.math.maxInt(u32) and
                    self.relation_offset <= std.math.maxInt(u32) and
                    self.relation_count <= std.math.maxInt(u32) and
                    self.edge_offset <= std.math.maxInt(u32);
            }

            pub fn hasU24NodeU32Shape(self: VertexRecord) bool {
                return self.node_id <= u24_node_max and
                    self.relation_offset <= std.math.maxInt(u32) and
                    self.relation_count <= std.math.maxInt(u32) and
                    self.edge_offset <= std.math.maxInt(u32);
            }

            pub fn encode(self: VertexRecord, out: *[encoded_len]u8) void {
                std.mem.writeInt(u64, out[0..8], self.node_id, .little);
                std.mem.writeInt(u64, out[8..16], self.relation_offset, .little);
                std.mem.writeInt(u64, out[16..24], self.relation_count, .little);
                std.mem.writeInt(u64, out[24..32], self.edge_offset, .little);
            }

            pub fn encodeForHeaderAt(self: VertexRecord, header: SegmentHeader, index: u64, out: []u8) !void {
                try header.validateShape();
                if (out.len != header.vertexRecordLen()) return error.InvalidRecord;
                if (header.hasDerivedVertexIds()) {
                    if (out.len != 0) return error.InvalidRecord;
                    if (self.node_id != try derivedVertexIdAt(header, index)) return error.InvalidRecord;
                    if (self.relation_offset != index or self.relation_count != 1) return error.InvalidRecord;
                    if (self.edge_offset != try uniformSingleRelationEdgeOffset(header, index)) return error.InvalidRecord;
                    if (self.single_relation_rel != header.uniform_relation) return error.InvalidRecord;
                    return;
                }
                if (header.hasSingleRelationPerVertex()) {
                    if (self.relation_count != 1) return error.InvalidRecord;
                    const stores_relation = !header.hasUniformRelation();
                    const stores_edge_offset = !header.hasUniformSingleRelationEdgeCount();
                    if (stores_relation and relFromInt(self.single_relation_rel) == null) return error.InvalidRecord;
                    if (header.hasU24NodeU32VertexRecords()) {
                        if (self.node_id > u24_node_max or (stores_edge_offset and self.edge_offset > std.math.maxInt(u32))) return error.RecordTooLarge;
                        std.mem.writeInt(u24, out[0..3], @intCast(self.node_id), .little);
                        if (stores_relation) {
                            std.mem.writeInt(u16, out[3..5], self.single_relation_rel, .little);
                            if (stores_edge_offset) std.mem.writeInt(u32, out[5..9], @intCast(self.edge_offset), .little);
                        } else if (stores_edge_offset) {
                            std.mem.writeInt(u32, out[3..7], @intCast(self.edge_offset), .little);
                        }
                    } else if (header.hasU32VertexRecords()) {
                        if (self.node_id > std.math.maxInt(u32) or (stores_edge_offset and self.edge_offset > std.math.maxInt(u32))) return error.RecordTooLarge;
                        std.mem.writeInt(u32, out[0..4], @intCast(self.node_id), .little);
                        if (stores_relation) {
                            std.mem.writeInt(u16, out[4..6], self.single_relation_rel, .little);
                            if (stores_edge_offset) std.mem.writeInt(u32, out[6..10], @intCast(self.edge_offset), .little);
                        } else if (stores_edge_offset) {
                            std.mem.writeInt(u32, out[4..8], @intCast(self.edge_offset), .little);
                        }
                    } else {
                        std.mem.writeInt(u64, out[0..8], self.node_id, .little);
                        if (stores_relation) {
                            std.mem.writeInt(u16, out[8..10], self.single_relation_rel, .little);
                            if (stores_edge_offset) std.mem.writeInt(u64, out[10..18], self.edge_offset, .little);
                        } else if (stores_edge_offset) {
                            std.mem.writeInt(u64, out[8..16], self.edge_offset, .little);
                        }
                    }
                } else if (header.hasU24NodeU32VertexRecords()) {
                    if (!self.hasU24NodeU32Shape()) return error.RecordTooLarge;
                    std.mem.writeInt(u24, out[0..3], @intCast(self.node_id), .little);
                    std.mem.writeInt(u32, out[3..7], @intCast(self.relation_offset), .little);
                    std.mem.writeInt(u32, out[7..11], @intCast(self.relation_count), .little);
                    std.mem.writeInt(u32, out[11..15], @intCast(self.edge_offset), .little);
                } else if (header.hasU32VertexRecords()) {
                    if (!self.hasU32Shape()) return error.RecordTooLarge;
                    std.mem.writeInt(u32, out[0..4], @intCast(self.node_id), .little);
                    std.mem.writeInt(u32, out[4..8], @intCast(self.relation_offset), .little);
                    std.mem.writeInt(u32, out[8..12], @intCast(self.relation_count), .little);
                    std.mem.writeInt(u32, out[12..16], @intCast(self.edge_offset), .little);
                } else {
                    var full: [encoded_len]u8 = undefined;
                    self.encode(&full);
                    @memcpy(out, full[0..]);
                }
            }

            pub fn decode(bytes: []const u8) !VertexRecord {
                if (bytes.len != encoded_len) return error.InvalidRecord;
                return .{
                    .node_id = std.mem.readInt(u64, bytes[0..8], .little),
                    .relation_offset = std.mem.readInt(u64, bytes[8..16], .little),
                    .relation_count = std.mem.readInt(u64, bytes[16..24], .little),
                    .edge_offset = std.mem.readInt(u64, bytes[24..32], .little),
                };
            }

            pub fn decodeForHeaderAt(header: SegmentHeader, index: u64, bytes: []const u8) !VertexRecord {
                try header.validateShape();
                if (bytes.len != header.vertexRecordLen()) return error.InvalidRecord;
                if (header.hasDerivedVertexIds()) {
                    return .{
                        .node_id = try derivedVertexIdAt(header, index),
                        .relation_offset = index,
                        .relation_count = 1,
                        .edge_offset = try uniformSingleRelationEdgeOffset(header, index),
                        .single_relation_rel = header.uniform_relation,
                    };
                }
                if (header.hasSingleRelationPerVertex()) {
                    const edge_offset = if (header.hasUniformSingleRelationEdgeCount())
                        try uniformSingleRelationEdgeOffset(header, index)
                    else
                        null;
                    if (header.hasU24NodeU32VertexRecords()) return .{
                        .node_id = std.mem.readInt(u24, bytes[0..3], .little),
                        .relation_offset = index,
                        .relation_count = 1,
                        .edge_offset = edge_offset orelse if (header.hasUniformRelation())
                            std.mem.readInt(u32, bytes[3..7], .little)
                        else
                            std.mem.readInt(u32, bytes[5..9], .little),
                        .single_relation_rel = if (header.hasUniformRelation()) header.uniform_relation else std.mem.readInt(u16, bytes[3..5], .little),
                    };
                    return if (header.hasU32VertexRecords()) .{
                        .node_id = std.mem.readInt(u32, bytes[0..4], .little),
                        .relation_offset = index,
                        .relation_count = 1,
                        .edge_offset = edge_offset orelse if (header.hasUniformRelation())
                            std.mem.readInt(u32, bytes[4..8], .little)
                        else
                            std.mem.readInt(u32, bytes[6..10], .little),
                        .single_relation_rel = if (header.hasUniformRelation()) header.uniform_relation else std.mem.readInt(u16, bytes[4..6], .little),
                    } else .{
                        .node_id = std.mem.readInt(u64, bytes[0..8], .little),
                        .relation_offset = index,
                        .relation_count = 1,
                        .edge_offset = edge_offset orelse if (header.hasUniformRelation())
                            std.mem.readInt(u64, bytes[8..16], .little)
                        else
                            std.mem.readInt(u64, bytes[10..18], .little),
                        .single_relation_rel = if (header.hasUniformRelation()) header.uniform_relation else std.mem.readInt(u16, bytes[8..10], .little),
                    };
                }
                if (header.hasU24NodeU32VertexRecords()) {
                    return .{
                        .node_id = std.mem.readInt(u24, bytes[0..3], .little),
                        .relation_offset = std.mem.readInt(u32, bytes[3..7], .little),
                        .relation_count = std.mem.readInt(u32, bytes[7..11], .little),
                        .edge_offset = std.mem.readInt(u32, bytes[11..15], .little),
                    };
                }
                if (header.hasU32VertexRecords()) {
                    return .{
                        .node_id = std.mem.readInt(u32, bytes[0..4], .little),
                        .relation_offset = std.mem.readInt(u32, bytes[4..8], .little),
                        .relation_count = std.mem.readInt(u32, bytes[8..12], .little),
                        .edge_offset = std.mem.readInt(u32, bytes[12..16], .little),
                    };
                }
                return decode(bytes);
            }
        };

        pub const RelationRangeRecord = struct {
            rel: u16,
            edge_offset: u64,
            edge_count: u64,

            pub const encoded_len: usize = 10;
            pub const u16_encoded_len: usize = 4;
            pub const u8_encoded_len: usize = 3;
            pub const uniform_encoded_len: usize = 8;
            pub const uniform_u16_encoded_len: usize = 2;
            pub const uniform_u8_encoded_len: usize = 1;

            pub fn hasU16Count(self: RelationRangeRecord) bool {
                return self.edge_count <= std.math.maxInt(u16);
            }

            pub fn hasU8Count(self: RelationRangeRecord) bool {
                return self.edge_count <= std.math.maxInt(u8);
            }

            pub fn encode(self: RelationRangeRecord, out: *[encoded_len]u8) void {
                std.mem.writeInt(u16, out[0..2], self.rel, .little);
                std.mem.writeInt(u64, out[2..10], self.edge_count, .little);
            }

            pub fn encodeForHeader(self: RelationRangeRecord, header: SegmentHeader, out: []u8) !void {
                try header.validateShape();
                if (out.len != header.relationRecordLen()) return error.InvalidRecord;
                if (header.hasUniformRelation()) {
                    if (self.rel != header.uniform_relation) return error.InvalidRecord;
                    if (header.hasU8RelationCounts()) {
                        if (!self.hasU8Count()) return error.RecordTooLarge;
                        out[0] = @intCast(self.edge_count);
                    } else if (header.hasU16RelationCounts()) {
                        if (!self.hasU16Count()) return error.RecordTooLarge;
                        std.mem.writeInt(u16, out[0..2], @intCast(self.edge_count), .little);
                    } else {
                        std.mem.writeInt(u64, out[0..8], self.edge_count, .little);
                    }
                } else if (header.hasU8RelationCounts()) {
                    if (!self.hasU8Count()) return error.RecordTooLarge;
                    std.mem.writeInt(u16, out[0..2], self.rel, .little);
                    out[2] = @intCast(self.edge_count);
                } else if (header.hasU16RelationCounts()) {
                    if (!self.hasU16Count()) return error.RecordTooLarge;
                    std.mem.writeInt(u16, out[0..2], self.rel, .little);
                    std.mem.writeInt(u16, out[2..4], @intCast(self.edge_count), .little);
                } else {
                    var full: [encoded_len]u8 = undefined;
                    self.encode(&full);
                    @memcpy(out, full[0..]);
                }
            }

            pub fn decode(bytes: []const u8) !RelationRangeRecord {
                if (bytes.len != encoded_len) return error.InvalidRecord;
                return .{
                    .rel = std.mem.readInt(u16, bytes[0..2], .little),
                    .edge_offset = 0,
                    .edge_count = std.mem.readInt(u64, bytes[2..10], .little),
                };
            }

            pub fn decodeForHeader(header: SegmentHeader, bytes: []const u8) !RelationRangeRecord {
                try header.validateShape();
                if (bytes.len != header.relationRecordLen()) return error.InvalidRecord;
                if (header.hasUniformRelation()) {
                    return .{
                        .rel = header.uniform_relation,
                        .edge_offset = 0,
                        .edge_count = if (header.hasU8RelationCounts())
                            bytes[0]
                        else if (header.hasU16RelationCounts())
                            std.mem.readInt(u16, bytes[0..2], .little)
                        else
                            std.mem.readInt(u64, bytes[0..8], .little),
                    };
                }
                if (header.hasU8RelationCounts()) {
                    return .{
                        .rel = std.mem.readInt(u16, bytes[0..2], .little),
                        .edge_offset = 0,
                        .edge_count = bytes[2],
                    };
                }
                if (header.hasU16RelationCounts()) {
                    return .{
                        .rel = std.mem.readInt(u16, bytes[0..2], .little),
                        .edge_offset = 0,
                        .edge_count = std.mem.readInt(u16, bytes[2..4], .little),
                    };
                }
                return decode(bytes);
            }
        };

        pub const StoredEdgeRecord = struct {
            other_node: u64,
            edge_id: u64,

            pub const encoded_len: usize = 16;
            pub const u32_encoded_len: usize = 8;
            pub const u24_node_u32_edge_encoded_len: usize = 7;
            pub const node_only_encoded_len: usize = 8;
            pub const u32_node_only_encoded_len: usize = 4;
            pub const u24_node_only_encoded_len: usize = 3;
            pub const u24_node_max: u64 = (1 << 24) - 1;

            pub fn fromEdge(edge: EdgeRecord, direction: Direction) StoredEdgeRecord {
                return .{
                    .other_node = edgeOtherNodeForDirection(edge, direction),
                    .edge_id = edge.edge_id.toInt(),
                };
            }

            pub fn toEdgeInRelation(self: StoredEdgeRecord, direction: Direction, owner_node: u64, relation_rel: u16) !EdgeRecord {
                if (owner_node == 0 or self.other_node == 0 or self.edge_id == 0) return error.InvalidRecord;
                if (owner_node == std.math.maxInt(u64) or self.other_node == std.math.maxInt(u64) or self.edge_id == std.math.maxInt(u64)) return error.InvalidRecord;
                const rel = relFromInt(relation_rel) orelse return error.InvalidRecord;
                return switch (direction) {
                    .forward => .{
                        .src = core.NodeId.fromInt(owner_node),
                        .dst = core.NodeId.fromInt(self.other_node),
                        .edge_id = core.EdgeId.fromInt(self.edge_id),
                        .rel = rel,
                    },
                    .reverse => .{
                        .src = core.NodeId.fromInt(self.other_node),
                        .dst = core.NodeId.fromInt(owner_node),
                        .edge_id = core.EdgeId.fromInt(self.edge_id),
                        .rel = rel,
                    },
                };
            }

            pub fn hasU32Shape(self: StoredEdgeRecord) bool {
                return self.other_node <= std.math.maxInt(u32) and self.edge_id <= std.math.maxInt(u32);
            }

            pub fn hasU24NodeU32EdgeShape(self: StoredEdgeRecord) bool {
                return self.other_node <= u24_node_max and self.edge_id <= std.math.maxInt(u32);
            }

            pub fn encode(self: StoredEdgeRecord, out: *[encoded_len]u8) void {
                std.mem.writeInt(u64, out[0..8], self.other_node, .little);
                std.mem.writeInt(u64, out[8..16], self.edge_id, .little);
            }

            pub fn encodeForHeaderAt(self: StoredEdgeRecord, header: SegmentHeader, index: u64, out: []u8) !void {
                try header.validateShape();
                if (out.len != header.edge_record_len) return error.InvalidRecord;
                if (header.hasDerivedEdgeIds()) {
                    if (self.edge_id != try derivedEdgeIdAt(header, index)) return error.InvalidRecord;
                    if (header.hasDerivedEdgeOtherNodes()) {
                        if (self.other_node != try derivedEdgeOtherNodeAt(header, index)) return error.InvalidRecord;
                        if (out.len != 0) return error.InvalidRecord;
                        return;
                    }
                    if (header.hasU24NodeU32EdgeRecords()) {
                        if (self.other_node > u24_node_max) return error.InvalidRecord;
                        std.mem.writeInt(u24, out[0..3], @intCast(self.other_node), .little);
                    } else if (header.hasU32EdgeRecords()) {
                        if (self.other_node > std.math.maxInt(u32)) return error.InvalidRecord;
                        std.mem.writeInt(u32, out[0..4], @intCast(self.other_node), .little);
                    } else {
                        std.mem.writeInt(u64, out[0..8], self.other_node, .little);
                    }
                    return;
                }
                if (header.hasU24NodeU32EdgeRecords()) {
                    if (!self.hasU24NodeU32EdgeShape()) return error.InvalidRecord;
                    std.mem.writeInt(u24, out[0..3], @intCast(self.other_node), .little);
                    std.mem.writeInt(u32, out[3..7], @intCast(self.edge_id), .little);
                } else if (header.hasU32EdgeRecords()) {
                    if (self.other_node > std.math.maxInt(u32) or self.edge_id > std.math.maxInt(u32)) return error.InvalidRecord;
                    std.mem.writeInt(u32, out[0..4], @intCast(self.other_node), .little);
                    std.mem.writeInt(u32, out[4..8], @intCast(self.edge_id), .little);
                } else {
                    std.mem.writeInt(u64, out[0..8], self.other_node, .little);
                    std.mem.writeInt(u64, out[8..16], self.edge_id, .little);
                }
            }

            pub fn decode(bytes: []const u8) !StoredEdgeRecord {
                if (bytes.len != encoded_len) return error.InvalidRecord;
                return .{
                    .other_node = std.mem.readInt(u64, bytes[0..8], .little),
                    .edge_id = std.mem.readInt(u64, bytes[8..16], .little),
                };
            }

            pub fn decodeForHeaderAt(header: SegmentHeader, index: u64, bytes: []const u8) !StoredEdgeRecord {
                try header.validateShape();
                if (bytes.len != header.edge_record_len) return error.InvalidRecord;
                if (header.hasDerivedEdgeIds()) {
                    if (header.hasDerivedEdgeOtherNodes()) {
                        return .{
                            .other_node = try derivedEdgeOtherNodeAt(header, index),
                            .edge_id = try derivedEdgeIdAt(header, index),
                        };
                    }
                    if (header.hasU24NodeU32EdgeRecords()) {
                        return .{
                            .other_node = std.mem.readInt(u24, bytes[0..3], .little),
                            .edge_id = try derivedEdgeIdAt(header, index),
                        };
                    }
                    if (header.hasU32EdgeRecords()) {
                        return .{
                            .other_node = std.mem.readInt(u32, bytes[0..4], .little),
                            .edge_id = try derivedEdgeIdAt(header, index),
                        };
                    }
                    return .{
                        .other_node = std.mem.readInt(u64, bytes[0..8], .little),
                        .edge_id = try derivedEdgeIdAt(header, index),
                    };
                }
                if (header.hasU24NodeU32EdgeRecords()) {
                    return .{
                        .other_node = std.mem.readInt(u24, bytes[0..3], .little),
                        .edge_id = std.mem.readInt(u32, bytes[3..7], .little),
                    };
                }
                if (header.hasU32EdgeRecords()) {
                    return .{
                        .other_node = std.mem.readInt(u32, bytes[0..4], .little),
                        .edge_id = std.mem.readInt(u32, bytes[4..8], .little),
                    };
                }
                return decode(bytes);
            }
        };

        pub fn deriveEdgeCountFromFileSize(file_size: u64, declared_edge_count: u64, vertex_count: u64, relation_count: u64, vertex_record_len: u16, relation_record_len: u16, edge_record_len: u16) !u64 {
            const vertex_bytes = std.math.mul(u64, vertex_count, vertex_record_len) catch return error.RecordTooLarge;
            const relation_bytes = std.math.mul(u64, relation_count, relation_record_len) catch return error.RecordTooLarge;
            const with_vertices = std.math.add(u64, SegmentHeader.encoded_len, vertex_bytes) catch return error.RecordTooLarge;
            const edge_base = std.math.add(u64, with_vertices, relation_bytes) catch return error.RecordTooLarge;
            if (file_size < edge_base) return error.InvalidRecord;
            const edge_bytes = file_size - edge_base;
            if (edge_record_len == 0) {
                if (edge_bytes != 0) return error.InvalidRecord;
                return declared_edge_count;
            }
            if (edge_bytes % edge_record_len != 0) return error.InvalidRecord;
            const derived_edge_count = edge_bytes / edge_record_len;
            if (declared_edge_count != derived_edge_count) return error.InvalidRecord;
            return derived_edge_count;
        }

        pub fn fileSizeFor(vertex_count: u64, relation_count: u64, edge_count: u64) !u64 {
            return fileSizeForRecordLen(vertex_count, relation_count, edge_count, StoredEdgeRecord.encoded_len);
        }

        pub fn fileSizeForHeader(header: SegmentHeader) !u64 {
            return fileSizeForRecordLens(header.vertex_count, header.relation_count, header.edge_count, header.vertexRecordLen(), header.relationRecordLen(), header.edge_record_len);
        }

        pub fn fileSizeForRecordLen(vertex_count: u64, relation_count: u64, edge_count: u64, edge_record_len: u16) !u64 {
            return fileSizeForRecordLens(vertex_count, relation_count, edge_count, VertexRecord.encoded_len, RelationRangeRecord.encoded_len, edge_record_len);
        }

        pub fn fileSizeForRecordLens(vertex_count: u64, relation_count: u64, edge_count: u64, vertex_record_len: u16, relation_record_len: u16, edge_record_len: u16) !u64 {
            const vertex_bytes = std.math.mul(u64, vertex_count, vertex_record_len) catch return error.RecordTooLarge;
            const relation_bytes = std.math.mul(u64, relation_count, relation_record_len) catch return error.RecordTooLarge;
            const edge_bytes = std.math.mul(u64, edge_count, edge_record_len) catch return error.RecordTooLarge;
            const with_vertices = std.math.add(u64, SegmentHeader.encoded_len, vertex_bytes) catch return error.RecordTooLarge;
            const with_relations = std.math.add(u64, with_vertices, relation_bytes) catch return error.RecordTooLarge;
            return std.math.add(u64, with_relations, edge_bytes) catch return error.RecordTooLarge;
        }

        pub fn vertexRecordOffsetForHeader(header: SegmentHeader, index: u64) !u64 {
            const bytes = std.math.mul(u64, index, header.vertexRecordLen()) catch return error.RecordTooLarge;
            return std.math.add(u64, SegmentHeader.encoded_len, bytes) catch return error.RecordTooLarge;
        }

        pub fn relationRecordOffset(header: SegmentHeader, index: u64) !u64 {
            const bytes = std.math.mul(u64, index, header.relationRecordLen()) catch return error.RecordTooLarge;
            const relation_base = try relationBaseOffsetForHeader(header);
            return std.math.add(u64, relation_base, bytes) catch return error.RecordTooLarge;
        }

        pub fn relationBaseOffsetForHeader(header: SegmentHeader) !u64 {
            const vertex_bytes = std.math.mul(u64, header.vertex_count, header.vertexRecordLen()) catch return error.RecordTooLarge;
            return std.math.add(u64, SegmentHeader.encoded_len, vertex_bytes) catch return error.RecordTooLarge;
        }

        pub fn edgeBaseOffsetForHeader(header: SegmentHeader) !u64 {
            const vertex_bytes = std.math.mul(u64, header.vertex_count, header.vertexRecordLen()) catch return error.RecordTooLarge;
            const relation_bytes = std.math.mul(u64, header.relation_count, header.relationRecordLen()) catch return error.RecordTooLarge;
            const with_vertices = std.math.add(u64, SegmentHeader.encoded_len, vertex_bytes) catch return error.RecordTooLarge;
            return std.math.add(u64, with_vertices, relation_bytes) catch return error.RecordTooLarge;
        }

        pub fn storedEdgeRangeOffset(edge_base: u64, edge_offset: u64, edge_record_len: usize) !u64 {
            const byte_index = std.math.mul(u64, edge_offset, edge_record_len) catch return error.RecordTooLarge;
            return std.math.add(u64, edge_base, byte_index) catch return error.RecordTooLarge;
        }

        pub fn uniformSingleRelationEdgeOffset(header: SegmentHeader, index: u64) !u64 {
            if (!header.hasUniformSingleRelationEdgeCount()) return error.InvalidRecord;
            return std.math.mul(u64, index, header.uniform_single_relation_edge_count) catch return error.RecordTooLarge;
        }

        pub fn storedEdgeOtherNodeFieldLen(header: SegmentHeader) usize {
            return if (header.hasU24NodeU32EdgeRecords()) 3 else if (header.hasU32EdgeRecords()) 4 else 8;
        }

        pub fn storedEdgeIdFieldOffset(header: SegmentHeader) usize {
            std.debug.assert(!header.hasDerivedEdgeIds());
            return storedEdgeOtherNodeFieldLen(header);
        }

        pub fn vertexEdgeOffsetFieldOffset(header: SegmentHeader) usize {
            std.debug.assert(!header.hasUniformSingleRelationEdgeCount());
            if (header.hasSingleRelationPerVertex()) {
                if (header.hasUniformRelation()) {
                    return if (header.hasU24NodeU32VertexRecords()) 3 else if (header.hasU32VertexRecords()) 4 else 8;
                }
                return if (header.hasU24NodeU32VertexRecords()) 5 else if (header.hasU32VertexRecords()) 6 else 10;
            }
            return if (header.hasU24NodeU32VertexRecords()) 11 else if (header.hasU32VertexRecords()) 12 else 24;
        }

        pub fn vertexEdgeOffsetFieldLen(header: SegmentHeader) usize {
            std.debug.assert(!header.hasUniformSingleRelationEdgeCount());
            return if (header.hasU24NodeU32VertexRecords() or header.hasU32VertexRecords()) 4 else 8;
        }

        pub fn edgeOtherNodeForDirection(edge: EdgeRecord, direction: Direction) u64 {
            return switch (direction) {
                .forward => edge.dst.toInt(),
                .reverse => edge.src.toInt(),
            };
        }

        pub fn relFromInt(value: u16) ?core.RelKind {
            if (value >= max_relation_types) return null;
            return @enumFromInt(value);
        }
    };
}

const TestDirection = enum {
    forward,
    reverse,
};

const TestId = struct {
    value: u64,

    pub fn fromInt(value: u64) TestId {
        return .{ .value = value };
    }

    pub fn toInt(self: TestId) u64 {
        return self.value;
    }
};

const TestRelKind = enum(u16) {
    contain = 0,
    related_to = 1,
    _,
};

const TestCore = struct {
    pub const NodeId = TestId;
    pub const EdgeId = TestId;
    pub const RelKind = TestRelKind;
};

const TestEdgeRecord = struct {
    src: TestCore.NodeId,
    dst: TestCore.NodeId,
    edge_id: TestCore.EdgeId,
    rel: TestCore.RelKind,
};

const test_format = CsrFormat(TestCore, TestDirection, TestEdgeRecord, 2);

test "csr format header preserves stable bytes and rejects corrupt identity" {
    const header = test_format.SegmentHeader{
        .order = .forward,
        .edge_count = 7,
        .vertex_count = 3,
        .relation_count = 2,
    };
    var bytes: [test_format.SegmentHeader.encoded_len]u8 = undefined;
    header.encode(&bytes);

    const decoded = try test_format.SegmentHeader.decode(&bytes);
    try std.testing.expectEqual(TestDirection.forward, decoded.order);
    try std.testing.expectEqual(@as(u64, 7), decoded.edge_count);
    try std.testing.expectEqual(@as(u64, 3), decoded.vertex_count);

    var corrupt = bytes;
    corrupt[0] = 'X';
    try std.testing.expectError(error.InvalidRecord, test_format.SegmentHeader.decode(&corrupt));
}

test "csr format header rejects incompatible compact flags" {
    var edge_header = test_format.SegmentHeader{
        .order = .forward,
        .edge_count = 0,
        .vertex_count = 0,
        .relation_count = 0,
    };
    edge_header.flags = test_format.SegmentHeader.flag_u32_edge_records |
        test_format.SegmentHeader.flag_u24_node_u32_edge_records;
    try std.testing.expectError(error.InvalidRecord, edge_header.validateShape());

    var relation_header = edge_header;
    relation_header.flags = test_format.SegmentHeader.flag_u8_relation_counts |
        test_format.SegmentHeader.flag_u16_relation_counts;
    try std.testing.expectError(error.InvalidRecord, relation_header.validateShape());
}

test "csr format derived split shapes preserve ids and bounds" {
    const header = test_format.SegmentHeader{
        .order = .forward,
        .edge_count = 4,
        .vertex_count = 0,
        .relation_count = 0,
        .edge_record_len = test_format.StoredEdgeRecord.node_only_encoded_len,
        .derived_edge_id_base = 10,
        .derived_edge_id_step = 2,
        .derived_edge_id_split_index = 2,
        .derived_edge_id_second_base = 100,
        .derived_edge_id_second_step = 3,
    };
    try std.testing.expectEqual(@as(u64, 10), try test_format.derivedEdgeIdAt(header, 0));
    try std.testing.expectEqual(@as(u64, 12), try test_format.derivedEdgeIdAt(header, 1));
    try std.testing.expectEqual(@as(u64, 100), try test_format.derivedEdgeIdAt(header, 2));
    try std.testing.expectEqual(@as(u64, 103), try test_format.derivedEdgeIdAt(header, 3));

    var overflowing = header;
    overflowing.derived_edge_id_base = std.math.maxInt(u64) - 1;
    overflowing.derived_edge_id_split_index = 0;
    overflowing.derived_edge_id_second_base = 0;
    overflowing.derived_edge_id_second_step = 0;
    try std.testing.expectError(error.RecordTooLarge, test_format.derivedEdgeIdAt(overflowing, 1));
}

test "csr format vertex records round trip full compact and derived shapes" {
    const full_header = test_format.SegmentHeader{
        .order = .forward,
        .edge_count = 6,
        .vertex_count = 2,
        .relation_count = 2,
    };
    const record = test_format.VertexRecord{
        .node_id = 7,
        .relation_offset = 1,
        .relation_count = 1,
        .edge_offset = 3,
    };
    var full_bytes: [test_format.VertexRecord.encoded_len]u8 = undefined;
    try record.encodeForHeaderAt(full_header, 0, &full_bytes);
    const full = try test_format.VertexRecord.decodeForHeaderAt(full_header, 0, &full_bytes);
    try std.testing.expectEqual(record.node_id, full.node_id);
    try std.testing.expectEqual(record.edge_offset, full.edge_offset);

    var compact_header = full_header;
    compact_header.flags = test_format.SegmentHeader.flag_u32_vertex_records;
    var compact_bytes: [test_format.VertexRecord.u32_encoded_len]u8 = undefined;
    try record.encodeForHeaderAt(compact_header, 0, &compact_bytes);
    const compact = try test_format.VertexRecord.decodeForHeaderAt(compact_header, 0, &compact_bytes);
    try std.testing.expectEqual(record.relation_offset, compact.relation_offset);

    const derived_header = test_format.SegmentHeader{
        .order = .forward,
        .edge_count = 4,
        .vertex_count = 2,
        .relation_count = 2,
        .flags = test_format.SegmentHeader.flag_uniform_relation |
            test_format.SegmentHeader.flag_single_relation_per_vertex,
        .uniform_relation = @intFromEnum(TestRelKind.contain),
        .uniform_single_relation_edge_count = 2,
        .derived_vertex_id_base = 5,
        .derived_vertex_id_step = 2,
    };
    const derived_record = test_format.VertexRecord{
        .node_id = 7,
        .relation_offset = 1,
        .relation_count = 1,
        .edge_offset = 2,
        .single_relation_rel = @intFromEnum(TestRelKind.contain),
    };
    try derived_record.encodeForHeaderAt(derived_header, 1, &.{});
    const derived = try test_format.VertexRecord.decodeForHeaderAt(derived_header, 1, &.{});
    try std.testing.expectEqual(derived_record.node_id, derived.node_id);
    try std.testing.expectEqual(derived_record.edge_offset, derived.edge_offset);
}

test "csr format relation records round trip full and compact shapes" {
    const full_header = test_format.SegmentHeader{
        .order = .forward,
        .edge_count = 7,
        .vertex_count = 1,
        .relation_count = 1,
    };
    const record = test_format.RelationRangeRecord{
        .rel = @intFromEnum(TestRelKind.related_to),
        .edge_offset = 0,
        .edge_count = 7,
    };
    var full_bytes: [test_format.RelationRangeRecord.encoded_len]u8 = undefined;
    try record.encodeForHeader(full_header, &full_bytes);
    const full = try test_format.RelationRangeRecord.decodeForHeader(full_header, &full_bytes);
    try std.testing.expectEqual(record.rel, full.rel);
    try std.testing.expectEqual(record.edge_count, full.edge_count);

    var compact_header = full_header;
    compact_header.flags = test_format.SegmentHeader.flag_u8_relation_counts;
    var compact_bytes: [test_format.RelationRangeRecord.u8_encoded_len]u8 = undefined;
    try record.encodeForHeader(compact_header, &compact_bytes);
    const compact = try test_format.RelationRangeRecord.decodeForHeader(compact_header, &compact_bytes);
    try std.testing.expectEqual(record.edge_count, compact.edge_count);
}

test "csr format edge records round trip full compact and derived shapes" {
    const full_header = test_format.SegmentHeader{
        .order = .forward,
        .edge_count = 2,
        .vertex_count = 1,
        .relation_count = 1,
    };
    const record = test_format.StoredEdgeRecord{ .other_node = 9, .edge_id = 11 };
    var full_bytes: [test_format.StoredEdgeRecord.encoded_len]u8 = undefined;
    try record.encodeForHeaderAt(full_header, 0, &full_bytes);
    const full = try test_format.StoredEdgeRecord.decodeForHeaderAt(full_header, 0, &full_bytes);
    try std.testing.expectEqual(record.other_node, full.other_node);
    try std.testing.expectEqual(record.edge_id, full.edge_id);

    var compact_header = full_header;
    compact_header.flags = test_format.SegmentHeader.flag_u32_edge_records;
    compact_header.edge_record_len = test_format.StoredEdgeRecord.u32_encoded_len;
    var compact_bytes: [test_format.StoredEdgeRecord.u32_encoded_len]u8 = undefined;
    try record.encodeForHeaderAt(compact_header, 0, &compact_bytes);
    const compact = try test_format.StoredEdgeRecord.decodeForHeaderAt(compact_header, 0, &compact_bytes);
    try std.testing.expectEqual(record.edge_id, compact.edge_id);

    const derived_header = test_format.SegmentHeader{
        .order = .forward,
        .edge_count = 2,
        .vertex_count = 1,
        .relation_count = 1,
        .edge_record_len = 0,
        .derived_edge_id_base = 11,
        .derived_edge_id_step = 2,
        .derived_edge_other_node_base = 9,
        .derived_edge_other_node_step = 3,
    };
    try record.encodeForHeaderAt(derived_header, 0, &.{});
    const derived = try test_format.StoredEdgeRecord.decodeForHeaderAt(derived_header, 0, &.{});
    try std.testing.expectEqual(record.other_node, derived.other_node);
    try std.testing.expectEqual(record.edge_id, derived.edge_id);
}

test "csr format layout arithmetic preserves section offsets" {
    const header = test_format.SegmentHeader{
        .order = .forward,
        .edge_count = 4,
        .vertex_count = 2,
        .relation_count = 3,
    };
    try std.testing.expectEqual(@as(u64, 287), try test_format.fileSizeForHeader(header));
    try std.testing.expectEqual(@as(u64, 161), try test_format.vertexRecordOffsetForHeader(header, 1));
    try std.testing.expectEqual(@as(u64, 193), try test_format.relationBaseOffsetForHeader(header));
    try std.testing.expectEqual(@as(u64, 213), try test_format.relationRecordOffset(header, 2));
    try std.testing.expectEqual(@as(u64, 223), try test_format.edgeBaseOffsetForHeader(header));
    try std.testing.expectEqual(@as(u64, 255), try test_format.storedEdgeRangeOffset(223, 2, 16));
    try std.testing.expectEqual(@as(u64, 4), try test_format.deriveEdgeCountFromFileSize(287, 4, 2, 3, 32, 10, 16));
}

test "csr format layout arithmetic rejects overflow and invalid ids" {
    try std.testing.expectError(
        error.RecordTooLarge,
        test_format.fileSizeForRecordLens(std.math.maxInt(u64), 0, 0, 32, 10, 16),
    );

    const zero_id_header = test_format.SegmentHeader{
        .order = .forward,
        .edge_count = 1,
        .vertex_count = 0,
        .relation_count = 0,
        .edge_record_len = test_format.StoredEdgeRecord.node_only_encoded_len,
        .derived_edge_id_base = 0,
        .derived_edge_id_step = 1,
    };
    try std.testing.expectError(error.InvalidRecord, test_format.derivedEdgeIdAt(zero_id_header, 0));

    const invalid_edge = test_format.StoredEdgeRecord{ .other_node = 2, .edge_id = 0 };
    try std.testing.expectError(
        error.InvalidRecord,
        invalid_edge.toEdgeInRelation(.forward, 1, @intFromEnum(TestRelKind.contain)),
    );
}
