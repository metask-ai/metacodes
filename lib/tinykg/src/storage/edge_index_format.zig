const std = @import("std");

/// Persistent edge-index bytes and compact-shape interpretation. Sorting,
/// shape selection, file I/O, repair, merge, compaction, query, and publication
/// remain owned by the storage facade.
pub fn EdgeIndexFormat(comptime core: type, comptime max_relation_types: u16) type {
    return struct {
        fn relKindFromInt(value: u16) ?core.RelKind {
            if (value >= max_relation_types) return null;
            return @enumFromInt(value);
        }

        fn allZero(bytes: []const u8) bool {
            for (bytes) |byte| {
                if (byte != 0) return false;
            }
            return true;
        }

        pub const EdgeIndexOrder = enum(u8) {
            id = 'I',
            src = 'S',
            dst = 'D',
        };

        pub const EdgeIndexRelDerivation = struct {
            default_rel: u16,
            exception_count: u8 = 0,
            exception_edge_ids: [2]u64 = .{ 0, 0 },
            exception_rels: [2]u16 = .{ 0, 0 },
        };

        pub const EdgeIndexDenseKeyRunSpan = struct {
            run_start: u64,
            count: u64,
            key_base: u64,
            start_base: u64,
            start_step: u64,
            edge_id_base: u64,
            edge_id_base_step: u64,
        };

        pub const EdgeIndexHeader = struct {
            order: EdgeIndexOrder,
            edge_count: u64,
            edge_digest: u64 = 0,
            order_digest: u64 = 0,
            flags: u16 = 0,
            record_len: u16 = EdgeIndexRecord.encoded_len,
            default_rel: u16 = 0,
            rel_exception_count: u8 = 0,
            key_run_count: u32 = 0,
            key_run_opposite_mod: u64 = 0,
            key_run_edge_id_step: u64 = 0,
            key_run_dense_run_start: u64 = 0,
            key_run_dense_count: u64 = 0,
            key_run_dense_key_base: u64 = 0,
            key_run_dense_start_base: u64 = 0,
            key_run_dense_start_step: u64 = 0,
            key_run_dense_edge_id_base: u64 = 0,
            key_run_dense_edge_id_base_step: u64 = 0,
            rel_exception_edge_ids: [2]u64 = .{ 0, 0 },
            rel_exception_rels: [2]u16 = .{ 0, 0 },

            const magic = [_]u8{ 'T', 'K', 'G', 'X' };
            const version: u16 = 15;
            pub const encoded_len: usize = 112;
            const flag_dense_id: u16 = 1 << 0;
            const flag_derived_rel: u16 = 1 << 1;
            const flag_u32_node_ids: u16 = 1 << 2;
            const flag_u32_edge_ids: u16 = 1 << 3;
            const flag_key_runs: u16 = 1 << 4;
            const flag_key_run_linear_edge_ids: u16 = 1 << 5;
            const flag_key_run_constant_opposite: u16 = 1 << 6;
            const flag_key_run_ring_opposite: u16 = 1 << 7;
            const flag_key_run_uniform_edge_id_step: u16 = 1 << 8;
            const flag_key_run_dense_span: u16 = 1 << 9;

            pub fn encode(self: EdgeIndexHeader, out: *[encoded_len]u8) void {
                @memcpy(out[0..4], &magic);
                std.mem.writeInt(u16, out[4..6], version, .little);
                std.mem.writeInt(u16, out[6..8], encoded_len, .little);
                out[8] = @intFromEnum(self.order);
                out[9] = 0;
                std.mem.writeInt(u16, out[10..12], self.flags, .little);
                std.mem.writeInt(u16, out[12..14], self.record_len, .little);
                std.mem.writeInt(u16, out[14..16], self.default_rel, .little);
                std.mem.writeInt(u64, out[16..24], self.edge_count, .little);
                std.mem.writeInt(u64, out[24..32], self.edge_digest, .little);
                std.mem.writeInt(u64, out[32..40], self.order_digest, .little);
                out[40] = self.rel_exception_count;
                std.mem.writeInt(u32, out[41..45], self.key_run_count, .little);
                @memset(out[45..48], 0);
                std.mem.writeInt(u64, out[48..56], self.rel_exception_edge_ids[0], .little);
                std.mem.writeInt(u64, out[56..64], self.rel_exception_edge_ids[1], .little);
                std.mem.writeInt(u16, out[64..66], self.rel_exception_rels[0], .little);
                std.mem.writeInt(u16, out[66..68], self.rel_exception_rels[1], .little);
                @memset(out[68..72], 0);
                std.mem.writeInt(u32, out[72..76], @intCast(self.key_run_opposite_mod), .little);
                std.mem.writeInt(u32, out[76..80], @intCast(self.key_run_edge_id_step), .little);
                std.mem.writeInt(u32, out[80..84], @intCast(self.key_run_dense_run_start), .little);
                std.mem.writeInt(u32, out[84..88], @intCast(self.key_run_dense_count), .little);
                std.mem.writeInt(u32, out[88..92], @intCast(self.key_run_dense_key_base), .little);
                std.mem.writeInt(u32, out[92..96], @intCast(self.key_run_dense_start_base), .little);
                std.mem.writeInt(u32, out[96..100], @intCast(self.key_run_dense_start_step), .little);
                std.mem.writeInt(u32, out[100..104], @intCast(self.key_run_dense_edge_id_base), .little);
                std.mem.writeInt(u32, out[104..108], @intCast(self.key_run_dense_edge_id_base_step), .little);
                @memset(out[108..112], 0);
            }

            pub fn decode(bytes: *const [encoded_len]u8) !EdgeIndexHeader {
                if (!std.mem.eql(u8, bytes[0..4], &magic)) return error.InvalidRecord;
                if (std.mem.readInt(u16, bytes[4..6], .little) != version) return error.InvalidRecord;
                if (std.mem.readInt(u16, bytes[6..8], .little) != encoded_len) return error.InvalidRecord;
                const order: EdgeIndexOrder = switch (bytes[8]) {
                    'I' => .id,
                    'S' => .src,
                    'D' => .dst,
                    else => return error.InvalidRecord,
                };
                if (bytes[9] != 0) return error.InvalidRecord;
                const header = EdgeIndexHeader{
                    .order = order,
                    .edge_count = std.mem.readInt(u64, bytes[16..24], .little),
                    .edge_digest = std.mem.readInt(u64, bytes[24..32], .little),
                    .order_digest = std.mem.readInt(u64, bytes[32..40], .little),
                    .flags = std.mem.readInt(u16, bytes[10..12], .little),
                    .record_len = std.mem.readInt(u16, bytes[12..14], .little),
                    .default_rel = std.mem.readInt(u16, bytes[14..16], .little),
                    .rel_exception_count = bytes[40],
                    .key_run_count = std.mem.readInt(u32, bytes[41..45], .little),
                    .rel_exception_edge_ids = .{
                        std.mem.readInt(u64, bytes[48..56], .little),
                        std.mem.readInt(u64, bytes[56..64], .little),
                    },
                    .rel_exception_rels = .{
                        std.mem.readInt(u16, bytes[64..66], .little),
                        std.mem.readInt(u16, bytes[66..68], .little),
                    },
                    .key_run_opposite_mod = std.mem.readInt(u32, bytes[72..76], .little),
                    .key_run_edge_id_step = std.mem.readInt(u32, bytes[76..80], .little),
                    .key_run_dense_run_start = std.mem.readInt(u32, bytes[80..84], .little),
                    .key_run_dense_count = std.mem.readInt(u32, bytes[84..88], .little),
                    .key_run_dense_key_base = std.mem.readInt(u32, bytes[88..92], .little),
                    .key_run_dense_start_base = std.mem.readInt(u32, bytes[92..96], .little),
                    .key_run_dense_start_step = std.mem.readInt(u32, bytes[96..100], .little),
                    .key_run_dense_edge_id_base = std.mem.readInt(u32, bytes[100..104], .little),
                    .key_run_dense_edge_id_base_step = std.mem.readInt(u32, bytes[104..108], .little),
                };
                if (!allZero(bytes[45..48]) or !allZero(bytes[68..72]) or !allZero(bytes[108..112])) return error.InvalidRecord;
                try header.validateShape();
                return header;
            }

            pub fn validateShape(self: EdgeIndexHeader) !void {
                const known_flags = flag_dense_id | flag_derived_rel | flag_u32_node_ids | flag_u32_edge_ids | flag_key_runs | flag_key_run_linear_edge_ids | flag_key_run_constant_opposite | flag_key_run_ring_opposite | flag_key_run_uniform_edge_id_step | flag_key_run_dense_span;
                if ((self.flags & ~known_flags) != 0) return error.InvalidRecord;
                if (self.hasDenseId() and self.order != .id) return error.InvalidRecord;
                if (self.hasDenseId() and self.hasU32EdgeIds()) return error.InvalidRecord;
                if (self.hasKeyRuns()) {
                    if (self.edge_count == 0 or self.key_run_count == 0) return error.InvalidRecord;
                    if (self.key_run_count > self.edge_count) return error.InvalidRecord;
                    if (self.edge_count > std.math.maxInt(u32) and self.hasU32NodeIds()) return error.InvalidRecord;
                    if (self.order == .id) {
                        if (!self.hasDenseId()) return error.InvalidRecord;
                        if (!self.hasU32NodeIds()) return error.InvalidRecord;
                        if (!self.hasKeyRunConstantOpposite()) return error.InvalidRecord;
                        if (self.hasKeyRunLinearEdgeIds()) return error.InvalidRecord;
                    }
                } else if (self.key_run_count != 0) {
                    return error.InvalidRecord;
                }
                if (self.hasKeyRunLinearEdgeIds() and !self.hasKeyRuns()) return error.InvalidRecord;
                if (self.hasKeyRunConstantOpposite() and !self.hasKeyRuns()) return error.InvalidRecord;
                if (self.hasKeyRunRingOpposite()) {
                    if (!self.hasKeyRuns() or !self.hasKeyRunConstantOpposite()) return error.InvalidRecord;
                    if (self.order == .id) return error.InvalidRecord;
                    if (self.key_run_opposite_mod == 0 or self.key_run_opposite_mod > std.math.maxInt(u32)) return error.InvalidRecord;
                    if (self.hasU32NodeIds() and self.key_run_opposite_mod > std.math.maxInt(u32)) return error.InvalidRecord;
                } else if (self.key_run_opposite_mod != 0) {
                    return error.InvalidRecord;
                }
                if (self.hasKeyRunUniformEdgeIdStep()) {
                    if (!self.hasKeyRunLinearEdgeIds()) return error.InvalidRecord;
                    if (self.key_run_edge_id_step == 0 or self.key_run_edge_id_step > std.math.maxInt(u32)) return error.InvalidRecord;
                } else if (self.key_run_edge_id_step != 0) {
                    return error.InvalidRecord;
                }
                if (self.hasKeyRunDenseSpan()) {
                    if (!self.hasKeyRunRingOpposite() or !self.hasKeyRunUniformEdgeIdStep()) return error.InvalidRecord;
                    if (!self.hasU32NodeIds() or !self.hasU32EdgeIds()) return error.InvalidRecord;
                    if (self.key_run_dense_run_start >= self.key_run_count) return error.InvalidRecord;
                    if (self.key_run_dense_count == 0 or self.key_run_dense_count > self.key_run_count) return error.InvalidRecord;
                    const dense_run_end = std.math.add(u64, self.key_run_dense_run_start, self.key_run_dense_count) catch return error.InvalidRecord;
                    if (dense_run_end > self.key_run_count) return error.InvalidRecord;
                    if (self.key_run_dense_run_start > std.math.maxInt(u32)) return error.InvalidRecord;
                    if (self.key_run_dense_count > std.math.maxInt(u32)) return error.InvalidRecord;
                    if (self.key_run_dense_key_base == 0 or self.key_run_dense_key_base > std.math.maxInt(u32)) return error.InvalidRecord;
                    if (self.key_run_dense_start_base > std.math.maxInt(u32)) return error.InvalidRecord;
                    if (self.key_run_dense_start_step == 0 or self.key_run_dense_start_step > std.math.maxInt(u32)) return error.InvalidRecord;
                    if (self.key_run_dense_edge_id_base == 0 or self.key_run_dense_edge_id_base > std.math.maxInt(u32)) return error.InvalidRecord;
                    if (self.key_run_dense_edge_id_base_step == 0 or self.key_run_dense_edge_id_base_step > std.math.maxInt(u32)) return error.InvalidRecord;
                    const last_index = self.key_run_dense_count - 1;
                    const last_key_delta = std.math.mul(u64, last_index, 1) catch return error.InvalidRecord;
                    const last_key = std.math.add(u64, self.key_run_dense_key_base, last_key_delta) catch return error.InvalidRecord;
                    if (last_key > self.key_run_opposite_mod or last_key > std.math.maxInt(u32)) return error.InvalidRecord;
                    const last_start_delta = std.math.mul(u64, last_index, self.key_run_dense_start_step) catch return error.InvalidRecord;
                    const last_start = std.math.add(u64, self.key_run_dense_start_base, last_start_delta) catch return error.InvalidRecord;
                    if (last_start >= self.edge_count) return error.InvalidRecord;
                    const last_edge_base_delta = std.math.mul(u64, last_index, self.key_run_dense_edge_id_base_step) catch return error.InvalidRecord;
                    const last_edge_base = std.math.add(u64, self.key_run_dense_edge_id_base, last_edge_base_delta) catch return error.InvalidRecord;
                    if (last_edge_base > std.math.maxInt(u32)) return error.InvalidRecord;
                } else if (self.key_run_dense_run_start != 0 or self.key_run_dense_count != 0 or self.key_run_dense_key_base != 0 or self.key_run_dense_start_base != 0 or self.key_run_dense_start_step != 0 or self.key_run_dense_edge_id_base != 0 or self.key_run_dense_edge_id_base_step != 0) {
                    return error.InvalidRecord;
                }
                if (self.hasDerivedRel()) {
                    if (relKindFromInt(self.default_rel) == null) return error.InvalidRecord;
                    if (self.rel_exception_count > self.rel_exception_edge_ids.len) return error.InvalidRecord;
                    var previous_id: u64 = 0;
                    for (0..self.rel_exception_edge_ids.len) |i| {
                        const id = self.rel_exception_edge_ids[i];
                        const rel = self.rel_exception_rels[i];
                        if (i < self.rel_exception_count) {
                            if (id == 0 or id == std.math.maxInt(u64)) return error.InvalidRecord;
                            if (i != 0 and id <= previous_id) return error.InvalidRecord;
                            if (relKindFromInt(rel) == null) return error.InvalidRecord;
                            if (rel == self.default_rel) return error.InvalidRecord;
                            previous_id = id;
                        } else {
                            if (id != 0 or rel != 0) return error.InvalidRecord;
                        }
                    }
                } else {
                    if (self.default_rel != 0 or self.rel_exception_count != 0) return error.InvalidRecord;
                    if (self.rel_exception_edge_ids[0] != 0 or self.rel_exception_edge_ids[1] != 0) return error.InvalidRecord;
                    if (self.rel_exception_rels[0] != 0 or self.rel_exception_rels[1] != 0) return error.InvalidRecord;
                }
                if (self.record_len != self.expectedRecordLen()) return error.InvalidRecord;
            }

            pub fn hasDenseId(self: EdgeIndexHeader) bool {
                return (self.flags & flag_dense_id) != 0;
            }

            pub fn hasDerivedRel(self: EdgeIndexHeader) bool {
                return (self.flags & flag_derived_rel) != 0;
            }

            pub fn hasU32NodeIds(self: EdgeIndexHeader) bool {
                return (self.flags & flag_u32_node_ids) != 0;
            }

            pub fn hasU32EdgeIds(self: EdgeIndexHeader) bool {
                return (self.flags & flag_u32_edge_ids) != 0;
            }

            pub fn hasKeyRuns(self: EdgeIndexHeader) bool {
                return (self.flags & flag_key_runs) != 0;
            }

            pub fn hasKeyRunLinearEdgeIds(self: EdgeIndexHeader) bool {
                return (self.flags & flag_key_run_linear_edge_ids) != 0;
            }

            pub fn hasKeyRunConstantOpposite(self: EdgeIndexHeader) bool {
                return (self.flags & flag_key_run_constant_opposite) != 0;
            }

            pub fn hasKeyRunRingOpposite(self: EdgeIndexHeader) bool {
                return (self.flags & flag_key_run_ring_opposite) != 0;
            }

            pub fn hasKeyRunUniformEdgeIdStep(self: EdgeIndexHeader) bool {
                return (self.flags & flag_key_run_uniform_edge_id_step) != 0;
            }

            pub fn hasKeyRunDenseSpan(self: EdgeIndexHeader) bool {
                return (self.flags & flag_key_run_dense_span) != 0;
            }

            pub fn expectedRecordLen(self: EdgeIndexHeader) u16 {
                var len: u16 = EdgeIndexRecord.encoded_len;
                if (self.hasU32NodeIds()) len -= 8;
                if (self.hasKeyRuns()) len -= if (self.hasU32NodeIds()) 4 else 8;
                if (self.hasKeyRunConstantOpposite()) len -= if (self.hasU32NodeIds()) 4 else 8;
                if (self.hasDenseId() or self.hasKeyRunLinearEdgeIds()) {
                    len -= 8;
                } else if (self.hasU32EdgeIds()) {
                    len -= 4;
                }
                if (self.hasDerivedRel()) len -= 2;
                return len;
            }

            pub fn relForEdgeId(self: EdgeIndexHeader, edge_id: u64) !u16 {
                try self.validateShape();
                if (!self.hasDerivedRel()) return error.InvalidRecord;
                var pos: usize = 0;
                while (pos < self.rel_exception_count) : (pos += 1) {
                    if (edge_id == self.rel_exception_edge_ids[pos]) return self.rel_exception_rels[pos];
                }
                return self.default_rel;
            }

            pub fn withShape(order: EdgeIndexOrder, edge_count: u64, edge_digest: u64, order_digest: u64, dense_id: bool, u32_node_ids: bool, u32_edge_ids: bool, rel_derivation: ?EdgeIndexRelDerivation) EdgeIndexHeader {
                var header = EdgeIndexHeader{
                    .order = order,
                    .edge_count = edge_count,
                    .edge_digest = edge_digest,
                    .order_digest = order_digest,
                };
                if (dense_id) header.flags |= flag_dense_id;
                if (u32_node_ids) header.flags |= flag_u32_node_ids;
                if (!dense_id and u32_edge_ids) header.flags |= flag_u32_edge_ids;
                if (rel_derivation) |derived| {
                    header.flags |= flag_derived_rel;
                    header.default_rel = derived.default_rel;
                    header.rel_exception_count = derived.exception_count;
                    header.rel_exception_edge_ids = derived.exception_edge_ids;
                    header.rel_exception_rels = derived.exception_rels;
                }
                header.record_len = header.expectedRecordLen();
                return header;
            }

            pub fn withKeyRuns(self: EdgeIndexHeader, key_run_count: u32, constant_opposite: bool, linear_edge_ids: bool) EdgeIndexHeader {
                var header = self;
                header.flags |= flag_key_runs;
                header.flags &= ~flag_key_run_ring_opposite;
                header.flags &= ~flag_key_run_uniform_edge_id_step;
                header.flags &= ~flag_key_run_dense_span;
                if (constant_opposite) header.flags |= flag_key_run_constant_opposite;
                if (linear_edge_ids) header.flags |= flag_key_run_linear_edge_ids;
                header.key_run_count = key_run_count;
                header.key_run_opposite_mod = 0;
                header.key_run_edge_id_step = 0;
                header.key_run_dense_run_start = 0;
                header.key_run_dense_count = 0;
                header.key_run_dense_key_base = 0;
                header.key_run_dense_start_base = 0;
                header.key_run_dense_start_step = 0;
                header.key_run_dense_edge_id_base = 0;
                header.key_run_dense_edge_id_base_step = 0;
                header.record_len = header.expectedRecordLen();
                return header;
            }

            pub fn withKeyRunRingOpposite(self: EdgeIndexHeader, opposite_mod: u64) EdgeIndexHeader {
                var header = self;
                header.flags |= flag_key_run_ring_opposite;
                header.key_run_opposite_mod = opposite_mod;
                header.record_len = header.expectedRecordLen();
                return header;
            }

            pub fn withKeyRunUniformEdgeIdStep(self: EdgeIndexHeader, edge_id_step: u64) EdgeIndexHeader {
                var header = self;
                header.flags |= flag_key_run_uniform_edge_id_step;
                header.key_run_edge_id_step = edge_id_step;
                header.record_len = header.expectedRecordLen();
                return header;
            }

            pub fn withKeyRunDenseSpan(self: EdgeIndexHeader, dense: EdgeIndexDenseKeyRunSpan) EdgeIndexHeader {
                var header = self;
                header.flags |= flag_key_run_dense_span;
                header.key_run_dense_run_start = dense.run_start;
                header.key_run_dense_count = dense.count;
                header.key_run_dense_key_base = dense.key_base;
                header.key_run_dense_start_base = dense.start_base;
                header.key_run_dense_start_step = dense.start_step;
                header.key_run_dense_edge_id_base = dense.edge_id_base;
                header.key_run_dense_edge_id_base_step = dense.edge_id_base_step;
                header.record_len = header.expectedRecordLen();
                return header;
            }

            pub fn denseId(edge_count: u64, edge_digest: u64, order_digest: u64) EdgeIndexHeader {
                return withShape(.id, edge_count, edge_digest, order_digest, true, false, false, null);
            }
        };

        pub const EdgeIndexRecord = struct {
            src: u64,
            dst: u64,
            edge_id: u64,
            rel: u16,

            pub const encoded_len: usize = 26;
            pub const dense_id_encoded_len: usize = 18;
            pub const derived_rel_encoded_len: usize = 24;
            pub const dense_id_derived_rel_encoded_len: usize = 16;
            pub const u32_nodes_encoded_len: usize = 18;
            pub const u32_nodes_dense_id_encoded_len: usize = 10;
            pub const u32_nodes_derived_rel_encoded_len: usize = 16;
            pub const u32_nodes_dense_id_derived_rel_encoded_len: usize = 8;
            pub const u32_nodes_u32_edge_id_derived_rel_encoded_len: usize = 12;

            pub fn encode(self: EdgeIndexRecord, out: *[encoded_len]u8) void {
                std.mem.writeInt(u64, out[0..8], self.src, .little);
                std.mem.writeInt(u64, out[8..16], self.dst, .little);
                std.mem.writeInt(u64, out[16..24], self.edge_id, .little);
                std.mem.writeInt(u16, out[24..26], self.rel, .little);
            }

            pub fn decode(bytes: *const [encoded_len]u8) !EdgeIndexRecord {
                return decodeSlice(bytes);
            }

            pub fn decodeSlice(bytes: []const u8) !EdgeIndexRecord {
                if (bytes.len != encoded_len) return error.InvalidRecord;
                const rel = std.mem.readInt(u16, bytes[24..26], .little);
                if (relKindFromInt(rel) == null) return error.InvalidRecord;
                const src = std.mem.readInt(u64, bytes[0..8], .little);
                const dst = std.mem.readInt(u64, bytes[8..16], .little);
                const edge_id = std.mem.readInt(u64, bytes[16..24], .little);
                if (edge_id == 0 or src == 0 or dst == 0) return error.InvalidRecord;
                if (edge_id == std.math.maxInt(u64) or src == std.math.maxInt(u64) or dst == std.math.maxInt(u64)) return error.InvalidRecord;
                return .{
                    .src = src,
                    .dst = dst,
                    .edge_id = edge_id,
                    .rel = rel,
                };
            }

            pub fn encodeForHeader(self: EdgeIndexRecord, header: EdgeIndexHeader, index: u64, run: ?EdgeIndexKeyRunRecord, out: []u8) !void {
                try header.validateShape();
                if (out.len != header.record_len) return error.InvalidRecord;
                if (header.hasDenseId()) {
                    const expected_edge_id = std.math.add(u64, index, 1) catch return error.InvalidRecord;
                    if (self.edge_id != expected_edge_id) return error.InvalidRecord;
                }
                if (header.hasKeyRunLinearEdgeIds()) {
                    const current_run = run orelse return error.InvalidRecord;
                    if (index < current_run.start) return error.InvalidRecord;
                    const delta = index - current_run.start;
                    const scaled_delta = std.math.mul(u64, delta, current_run.edge_id_step) catch return error.InvalidRecord;
                    const expected_edge_id = std.math.add(u64, current_run.edge_id_base, scaled_delta) catch return error.InvalidRecord;
                    if (self.edge_id != expected_edge_id) return error.InvalidRecord;
                }
                if (header.hasDerivedRel() and self.rel != try header.relForEdgeId(self.edge_id)) return error.InvalidRecord;
                const endpoint_len: usize = storedEndpointLen(header);
                if (header.hasU32NodeIds()) {
                    if (self.src > std.math.maxInt(u32) or self.dst > std.math.maxInt(u32)) return error.InvalidRecord;
                    if (header.hasKeyRuns()) {
                        const stored = switch (header.order) {
                            .id => stored: {
                                const current_run = run orelse return error.InvalidRecord;
                                if (index < current_run.start) return error.InvalidRecord;
                                const delta = index - current_run.start;
                                const expected_src = std.math.add(u64, current_run.key, delta) catch return error.InvalidRecord;
                                const expected_dst = std.math.add(u64, current_run.opposite, delta) catch return error.InvalidRecord;
                                if (self.src != expected_src or self.dst != expected_dst) return error.InvalidRecord;
                                break :stored self.dst;
                            },
                            .src => self.dst,
                            .dst => self.src,
                        };
                        if (header.order == .id) {
                            if (!header.hasKeyRunConstantOpposite()) return error.InvalidRecord;
                        } else if (header.hasKeyRunConstantOpposite()) {
                            const current_run = run orelse return error.InvalidRecord;
                            if (current_run.opposite != stored) return error.InvalidRecord;
                        } else {
                            std.mem.writeInt(u32, out[0..4], @intCast(stored), .little);
                        }
                    } else {
                        std.mem.writeInt(u32, out[0..4], @intCast(self.src), .little);
                        std.mem.writeInt(u32, out[4..8], @intCast(self.dst), .little);
                    }
                } else {
                    if (header.hasKeyRuns()) {
                        const stored = switch (header.order) {
                            .id => return error.InvalidRecord,
                            .src => self.dst,
                            .dst => self.src,
                        };
                        if (header.hasKeyRunConstantOpposite()) {
                            const current_run = run orelse return error.InvalidRecord;
                            if (current_run.opposite != stored) return error.InvalidRecord;
                        } else {
                            std.mem.writeInt(u64, out[0..8], stored, .little);
                        }
                    } else {
                        std.mem.writeInt(u64, out[0..8], self.src, .little);
                        std.mem.writeInt(u64, out[8..16], self.dst, .little);
                    }
                }
                if (!header.hasDenseId() and !header.hasKeyRunLinearEdgeIds()) {
                    if (header.hasU32EdgeIds()) {
                        if (self.edge_id > std.math.maxInt(u32)) return error.InvalidRecord;
                        std.mem.writeInt(u32, out[endpoint_len..][0..4], @intCast(self.edge_id), .little);
                    } else {
                        std.mem.writeInt(u64, out[endpoint_len..][0..8], self.edge_id, .little);
                    }
                }
                if (!header.hasDerivedRel()) {
                    const edge_id_len: usize = storedEdgeIdLen(header);
                    const rel_offset = endpoint_len + edge_id_len;
                    std.mem.writeInt(u16, out[rel_offset..][0..2], self.rel, .little);
                }
            }

            pub fn decodeSliceAtForHeader(header: EdgeIndexHeader, index: u64, bytes: []const u8, run: ?EdgeIndexKeyRunRecord) !EdgeIndexRecord {
                try header.validateShape();
                if (bytes.len != header.record_len) return error.InvalidRecord;
                const endpoint_len: usize = storedEndpointLen(header);
                const edge_id = if (header.hasDenseId()) edge_id: {
                    break :edge_id std.math.add(u64, index, 1) catch return error.InvalidRecord;
                } else if (header.hasKeyRunLinearEdgeIds()) edge_id: {
                    const current_run = run orelse return error.InvalidRecord;
                    if (index < current_run.start) return error.InvalidRecord;
                    const scaled_delta = std.math.mul(u64, index - current_run.start, current_run.edge_id_step) catch return error.InvalidRecord;
                    break :edge_id std.math.add(u64, current_run.edge_id_base, scaled_delta) catch return error.InvalidRecord;
                } else if (header.hasU32EdgeIds()) edge_id: {
                    break :edge_id std.mem.readInt(u32, bytes[endpoint_len..][0..4], .little);
                } else edge_id: {
                    break :edge_id std.mem.readInt(u64, bytes[endpoint_len..][0..8], .little);
                };
                if (edge_id == 0 or edge_id == std.math.maxInt(u64)) return error.InvalidRecord;
                const rel = if (header.hasDerivedRel()) try header.relForEdgeId(edge_id) else rel: {
                    const edge_id_len: usize = storedEdgeIdLen(header);
                    const rel_offset = endpoint_len + edge_id_len;
                    break :rel std.mem.readInt(u16, bytes[rel_offset..][0..2], .little);
                };
                if (relKindFromInt(rel) == null) return error.InvalidRecord;
                const src: u64, const dst: u64 = if (header.hasKeyRuns()) endpoints: {
                    const current_run = run orelse return error.InvalidRecord;
                    const key = current_run.key;
                    if (header.order == .id) {
                        if (index < current_run.start) return error.InvalidRecord;
                        const delta = index - current_run.start;
                        break :endpoints .{
                            std.math.add(u64, key, delta) catch return error.InvalidRecord,
                            std.math.add(u64, current_run.opposite, delta) catch return error.InvalidRecord,
                        };
                    }
                    const stored: u64 = if (header.hasKeyRunConstantOpposite())
                        current_run.opposite
                    else if (header.hasU32NodeIds())
                        std.mem.readInt(u32, bytes[0..4], .little)
                    else
                        std.mem.readInt(u64, bytes[0..8], .little);
                    break :endpoints switch (header.order) {
                        .id => return error.InvalidRecord,
                        .src => .{ key, stored },
                        .dst => .{ stored, key },
                    };
                } else endpoints: {
                    break :endpoints .{
                        if (header.hasU32NodeIds())
                            std.mem.readInt(u32, bytes[0..4], .little)
                        else
                            std.mem.readInt(u64, bytes[0..8], .little),
                        if (header.hasU32NodeIds())
                            std.mem.readInt(u32, bytes[4..8], .little)
                        else
                            std.mem.readInt(u64, bytes[8..16], .little),
                    };
                };
                if (src == 0 or dst == 0) return error.InvalidRecord;
                if (src == std.math.maxInt(u64) or dst == std.math.maxInt(u64)) return error.InvalidRecord;
                if (header.hasU32NodeIds() and (src > std.math.maxInt(u32) or dst > std.math.maxInt(u32))) return error.InvalidRecord;
                return .{
                    .src = src,
                    .dst = dst,
                    .edge_id = edge_id,
                    .rel = rel,
                };
            }

            pub fn relKind(self: EdgeIndexRecord) !core.RelKind {
                return relKindFromInt(self.rel) orelse error.InvalidRecord;
            }
        };

        pub const EdgeIndexKeyRunRecord = struct {
            key: u64,
            start: u64,
            opposite: u64 = 0,
            edge_id_base: u64 = 0,
            edge_id_step: u64 = 0,

            pub fn encodeForHeader(self: EdgeIndexKeyRunRecord, header: EdgeIndexHeader, out: []u8) !void {
                try header.validateShape();
                if (!header.hasKeyRuns()) return error.InvalidRecord;
                if (out.len != keyRunRecordLen(header)) return error.InvalidRecord;
                if (self.key == 0 or self.key == std.math.maxInt(u64)) return error.InvalidRecord;
                if (self.start >= header.edge_count) return error.InvalidRecord;
                if (header.hasKeyRunConstantOpposite()) {
                    if (self.opposite == 0 or self.opposite == std.math.maxInt(u64)) return error.InvalidRecord;
                    if (header.hasKeyRunRingOpposite() and self.opposite != (try ringOppositeForKey(header, self.key))) return error.InvalidRecord;
                } else if (self.opposite != 0) {
                    return error.InvalidRecord;
                }
                if (header.hasU32NodeIds()) {
                    if (self.key > std.math.maxInt(u32) or self.start > std.math.maxInt(u32) or self.opposite > std.math.maxInt(u32)) return error.InvalidRecord;
                    std.mem.writeInt(u32, out[0..4], @intCast(self.key), .little);
                    std.mem.writeInt(u32, out[4..8], @intCast(self.start), .little);
                    var cursor: usize = 8;
                    if (header.hasKeyRunConstantOpposite() and !header.hasKeyRunRingOpposite()) {
                        std.mem.writeInt(u32, out[cursor..][0..4], @intCast(self.opposite), .little);
                        cursor += 4;
                    }
                    if (header.hasKeyRunLinearEdgeIds()) {
                        if (header.hasU32EdgeIds() and (self.edge_id_base > std.math.maxInt(u32) or self.edge_id_step > std.math.maxInt(u32))) return error.InvalidRecord;
                        if (header.hasKeyRunUniformEdgeIdStep() and self.edge_id_step != 0 and self.edge_id_step != header.key_run_edge_id_step) return error.InvalidRecord;
                        if (header.hasU32EdgeIds()) {
                            std.mem.writeInt(u32, out[cursor..][0..4], @intCast(self.edge_id_base), .little);
                            cursor += 4;
                        } else {
                            std.mem.writeInt(u64, out[cursor..][0..8], self.edge_id_base, .little);
                            cursor += 8;
                        }
                        if (!header.hasKeyRunUniformEdgeIdStep()) {
                            if (header.hasU32EdgeIds()) {
                                std.mem.writeInt(u32, out[cursor..][0..4], @intCast(self.edge_id_step), .little);
                            } else {
                                std.mem.writeInt(u64, out[cursor..][0..8], self.edge_id_step, .little);
                            }
                        }
                    } else if (self.edge_id_base != 0 or self.edge_id_step != 0) {
                        return error.InvalidRecord;
                    }
                } else {
                    std.mem.writeInt(u64, out[0..8], self.key, .little);
                    std.mem.writeInt(u64, out[8..16], self.start, .little);
                    var cursor: usize = 16;
                    if (header.hasKeyRunConstantOpposite() and !header.hasKeyRunRingOpposite()) {
                        std.mem.writeInt(u64, out[cursor..][0..8], self.opposite, .little);
                        cursor += 8;
                    }
                    if (header.hasKeyRunLinearEdgeIds()) {
                        if (header.hasU32EdgeIds() and (self.edge_id_base > std.math.maxInt(u32) or self.edge_id_step > std.math.maxInt(u32))) return error.InvalidRecord;
                        if (header.hasKeyRunUniformEdgeIdStep() and self.edge_id_step != 0 and self.edge_id_step != header.key_run_edge_id_step) return error.InvalidRecord;
                        if (header.hasU32EdgeIds()) {
                            std.mem.writeInt(u32, out[cursor..][0..4], @intCast(self.edge_id_base), .little);
                            cursor += 4;
                        } else {
                            std.mem.writeInt(u64, out[cursor..][0..8], self.edge_id_base, .little);
                            cursor += 8;
                        }
                        if (!header.hasKeyRunUniformEdgeIdStep()) {
                            if (header.hasU32EdgeIds()) {
                                std.mem.writeInt(u32, out[cursor..][0..4], @intCast(self.edge_id_step), .little);
                            } else {
                                std.mem.writeInt(u64, out[cursor..][0..8], self.edge_id_step, .little);
                            }
                        }
                    } else if (self.edge_id_base != 0 or self.edge_id_step != 0) {
                        return error.InvalidRecord;
                    }
                }
            }

            pub fn decodeSliceForHeader(header: EdgeIndexHeader, bytes: []const u8) !EdgeIndexKeyRunRecord {
                try header.validateShape();
                if (!header.hasKeyRuns()) return error.InvalidRecord;
                if (bytes.len != keyRunRecordLen(header)) return error.InvalidRecord;
                const key: u64, const start: u64 = .{
                    if (header.hasU32NodeIds())
                        std.mem.readInt(u32, bytes[0..4], .little)
                    else
                        std.mem.readInt(u64, bytes[0..8], .little),
                    if (header.hasU32NodeIds())
                        std.mem.readInt(u32, bytes[4..8], .little)
                    else
                        std.mem.readInt(u64, bytes[8..16], .little),
                };
                if (key == 0 or key == std.math.maxInt(u64)) return error.InvalidRecord;
                if (start >= header.edge_count) return error.InvalidRecord;
                var cursor: usize = if (header.hasU32NodeIds()) 8 else 16;
                const opposite: u64 = if (header.hasKeyRunConstantOpposite()) opposite: {
                    if (header.hasKeyRunRingOpposite()) break :opposite try ringOppositeForKey(header, key);
                    const value = if (header.hasU32NodeIds())
                        std.mem.readInt(u32, bytes[cursor..][0..4], .little)
                    else
                        std.mem.readInt(u64, bytes[cursor..][0..8], .little);
                    cursor += if (header.hasU32NodeIds()) 4 else 8;
                    break :opposite value;
                } else 0;
                const edge_id_base: u64 = if (header.hasKeyRunLinearEdgeIds()) edge_id_base: {
                    const value = if (header.hasU32EdgeIds())
                        std.mem.readInt(u32, bytes[cursor..][0..4], .little)
                    else
                        std.mem.readInt(u64, bytes[cursor..][0..8], .little);
                    cursor += if (header.hasU32EdgeIds()) 4 else 8;
                    break :edge_id_base value;
                } else 0;
                const edge_id_step: u64 = if (header.hasKeyRunLinearEdgeIds()) edge_id_step: {
                    if (header.hasKeyRunUniformEdgeIdStep()) break :edge_id_step header.key_run_edge_id_step;
                    break :edge_id_step if (header.hasU32EdgeIds())
                        std.mem.readInt(u32, bytes[cursor..][0..4], .little)
                    else
                        std.mem.readInt(u64, bytes[cursor..][0..8], .little);
                } else 0;
                if (header.hasKeyRunConstantOpposite() and (opposite == 0 or opposite == std.math.maxInt(u64))) return error.InvalidRecord;
                if (header.hasKeyRunLinearEdgeIds() and (edge_id_base == 0 or edge_id_base == std.math.maxInt(u64) or edge_id_step == std.math.maxInt(u64))) return error.InvalidRecord;
                return .{ .key = key, .start = start, .opposite = opposite, .edge_id_base = edge_id_base, .edge_id_step = edge_id_step };
            }
        };

        pub fn storedEndpointLen(header: EdgeIndexHeader) usize {
            if (header.hasKeyRunConstantOpposite()) return 0;
            if (header.hasKeyRuns()) return if (header.hasU32NodeIds()) 4 else 8;
            return if (header.hasU32NodeIds()) 8 else 16;
        }

        pub fn storedEdgeIdLen(header: EdgeIndexHeader) usize {
            if (header.hasDenseId() or header.hasKeyRunLinearEdgeIds()) return 0;
            return if (header.hasU32EdgeIds()) 4 else 8;
        }

        pub fn keyRunRecordLen(header: EdgeIndexHeader) usize {
            var len: usize = if (header.hasU32NodeIds()) 8 else 16;
            if (header.hasKeyRunConstantOpposite() and !header.hasKeyRunRingOpposite()) len += if (header.hasU32NodeIds()) 4 else 8;
            if (header.hasKeyRunLinearEdgeIds()) {
                len += if (header.hasU32EdgeIds()) 4 else 8;
                if (!header.hasKeyRunUniformEdgeIdStep()) len += if (header.hasU32EdgeIds()) 4 else 8;
            }
            return len;
        }

        pub fn keyRunDirectorySizeForHeader(header: EdgeIndexHeader) !u64 {
            if (!header.hasKeyRuns()) return 0;
            const explicit_runs = if (header.hasKeyRunDenseSpan())
                header.key_run_count - @as(u32, @intCast(header.key_run_dense_count))
            else
                header.key_run_count;
            return std.math.mul(u64, explicit_runs, keyRunRecordLen(header)) catch return error.InvalidRecord;
        }

        pub fn keyRunOffsetForHeader(header: EdgeIndexHeader, run_index: u64) !u64 {
            try header.validateShape();
            if (!header.hasKeyRuns() or run_index >= header.key_run_count) return error.InvalidRecord;
            const explicit_index = if (header.hasKeyRunDenseSpan()) explicit_index: {
                const dense_end = std.math.add(u64, header.key_run_dense_run_start, header.key_run_dense_count) catch return error.InvalidRecord;
                if (run_index >= header.key_run_dense_run_start and run_index < dense_end) return error.InvalidRecord;
                break :explicit_index if (run_index < header.key_run_dense_run_start)
                    run_index
                else
                    run_index - header.key_run_dense_count;
            } else run_index;
            const bytes = std.math.mul(u64, explicit_index, keyRunRecordLen(header)) catch return error.InvalidRecord;
            return std.math.add(u64, EdgeIndexHeader.encoded_len, bytes) catch return error.InvalidRecord;
        }

        pub fn ringOppositeForKey(header: EdgeIndexHeader, key: u64) !u64 {
            try header.validateShape();
            if (!header.hasKeyRunRingOpposite()) return error.InvalidRecord;
            if (key == 0 or key > header.key_run_opposite_mod) return error.InvalidRecord;
            return switch (header.order) {
                .id => error.InvalidRecord,
                .src => if (key == header.key_run_opposite_mod) 1 else key + 1,
                .dst => if (key == 1) header.key_run_opposite_mod else key - 1,
            };
        }
    };
}

const TestCore = struct {
    pub const RelKind = enum(u16) {
        relation_0,
        relation_1,
        relation_2,
        relation_3,
        relation_4,
        relation_5,
        relation_6,
        relation_7,
    };
};

const TestFormat = EdgeIndexFormat(TestCore, 8);

test "edge index header round trips stable bytes and rejects reserved bytes" {
    const header = TestFormat.EdgeIndexHeader.withShape(.src, 3, 11, 22, false, true, true, .{
        .default_rel = 2,
        .exception_count = 1,
        .exception_edge_ids = .{ 3, 0 },
        .exception_rels = .{ 4, 0 },
    });
    try header.validateShape();
    var bytes: [TestFormat.EdgeIndexHeader.encoded_len]u8 = undefined;
    header.encode(&bytes);

    try std.testing.expectEqualSlices(u8, "TKGX", bytes[0..4]);
    try std.testing.expectEqualDeep(header, try TestFormat.EdgeIndexHeader.decode(&bytes));
    bytes[45] = 1;
    try std.testing.expectError(error.InvalidRecord, TestFormat.EdgeIndexHeader.decode(&bytes));
}

test "edge index record round trips legacy and compact shapes" {
    const record = TestFormat.EdgeIndexRecord{ .src = 17, .dst = 23, .edge_id = 1, .rel = 2 };
    var legacy: [TestFormat.EdgeIndexRecord.encoded_len]u8 = undefined;
    record.encode(&legacy);
    try std.testing.expectEqualDeep(record, try TestFormat.EdgeIndexRecord.decode(&legacy));

    const compact = TestFormat.EdgeIndexHeader.withShape(.id, 1, 0, 0, true, true, false, .{ .default_rel = 2 });
    var encoded: [TestFormat.EdgeIndexRecord.u32_nodes_dense_id_derived_rel_encoded_len]u8 = undefined;
    try record.encodeForHeader(compact, 0, null, &encoded);
    try std.testing.expectEqualDeep(record, try TestFormat.EdgeIndexRecord.decodeSliceAtForHeader(compact, 0, &encoded, null));
}

test "edge index key runs round trip ring and uniform edge ids" {
    const header = TestFormat.EdgeIndexHeader.withShape(.src, 3, 0, 0, false, true, true, .{ .default_rel = 2 })
        .withKeyRuns(2, true, true)
        .withKeyRunRingOpposite(3)
        .withKeyRunUniformEdgeIdStep(1);
    try header.validateShape();
    const run = TestFormat.EdgeIndexKeyRunRecord{ .key = 2, .start = 0, .opposite = 3, .edge_id_base = 1, .edge_id_step = 1 };
    var bytes: [12]u8 = undefined;
    try std.testing.expectEqual(bytes.len, TestFormat.keyRunRecordLen(header));
    try run.encodeForHeader(header, &bytes);
    try std.testing.expectEqualDeep(run, try TestFormat.EdgeIndexKeyRunRecord.decodeSliceForHeader(header, &bytes));

    const record = TestFormat.EdgeIndexRecord{ .src = 2, .dst = 3, .edge_id = 1, .rel = 2 };
    var row: [0]u8 = undefined;
    try record.encodeForHeader(header, 0, run, &row);
    try std.testing.expectEqualDeep(record, try TestFormat.EdgeIndexRecord.decodeSliceAtForHeader(header, 0, &row, run));
}

test "edge index header rejects inconsistent compact shapes" {
    var header = TestFormat.EdgeIndexHeader{ .order = .src, .edge_count = 1, .flags = 1 };
    try std.testing.expectError(error.InvalidRecord, header.validateShape());

    header = TestFormat.EdgeIndexHeader.withShape(.src, 1, 0, 0, false, true, true, null).withKeyRuns(1, true, true);
    header = header.withKeyRunUniformEdgeIdStep(0);
    try std.testing.expectError(error.InvalidRecord, header.validateShape());

    var record_bytes: [TestFormat.EdgeIndexRecord.encoded_len]u8 = [_]u8{0} ** TestFormat.EdgeIndexRecord.encoded_len;
    std.mem.writeInt(u16, record_bytes[24..26], 8, .little);
    try std.testing.expectError(error.InvalidRecord, TestFormat.EdgeIndexRecord.decode(&record_bytes));
}
