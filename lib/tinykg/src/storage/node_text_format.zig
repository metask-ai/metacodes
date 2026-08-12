const std = @import("std");

/// Persistent node-text catalog contracts parameterized by the public core
/// namespace and the schema's accepted node-kind range. The explicit inputs
/// keep this module directly testable without importing through its facade.
pub fn NodeTextFormat(comptime core: type, comptime max_node_types: u16) type {
    return struct {
        fn nodeKindFromInt(value: u16) ?core.NodeKind {
            if (value >= max_node_types) return null;
            return @enumFromInt(value);
        }

        fn writeU16(bytes: []u8, value: u16) void {
            std.mem.writeInt(u16, bytes[0..2], value, .little);
        }

        fn writeU32(bytes: []u8, value: u32) void {
            std.mem.writeInt(u32, bytes[0..4], value, .little);
        }

        fn writeU48(bytes: []u8, value: u64) !void {
            std.debug.assert(bytes.len == 6);
            const packed_value = std.math.cast(u48, value) orelse return error.RecordTooLarge;
            std.mem.writeInt(u48, bytes[0..6], packed_value, .little);
        }

        fn readU16(bytes: []const u8) u16 {
            return std.mem.readInt(u16, bytes[0..2], .little);
        }

        fn readU32(bytes: []const u8) u32 {
            return std.mem.readInt(u32, bytes[0..4], .little);
        }

        fn readU48(bytes: []const u8) u64 {
            std.debug.assert(bytes.len == 6);
            return @intCast(std.mem.readInt(u48, bytes[0..6], .little));
        }

        fn readU64(bytes: []const u8) u64 {
            return std.mem.readInt(u64, bytes[0..8], .little);
        }

        pub const NodeByIdHeader = struct {
            max_node_id: u64,
            node_count: u64,
            node_digest: u64 = 0,
            flags: u16 = 0,
            record_len: u16 = NodeByIdRecord.encoded_len,
            uniform_kind: u16 = 0,

            const magic = [_]u8{ 'T', 'K', 'G', 'N' };
            const version: u16 = 7;
            pub const encoded_len: usize = 40;
            pub const flag_uniform_kind: u16 = 1 << 0;
            pub const flag_short_text_len: u16 = 1 << 1;
            pub const flag_derived_text_offset: u16 = 1 << 2;

            pub fn encode(self: NodeByIdHeader, out: *[encoded_len]u8) void {
                @memcpy(out[0..4], &magic);
                std.mem.writeInt(u16, out[4..6], version, .little);
                std.mem.writeInt(u16, out[6..8], encoded_len, .little);
                std.mem.writeInt(u64, out[8..16], self.max_node_id, .little);
                std.mem.writeInt(u64, out[16..24], self.node_count, .little);
                std.mem.writeInt(u64, out[24..32], self.node_digest, .little);
                std.mem.writeInt(u16, out[32..34], self.flags, .little);
                std.mem.writeInt(u16, out[34..36], self.record_len, .little);
                std.mem.writeInt(u16, out[36..38], self.uniform_kind, .little);
                std.mem.writeInt(u16, out[38..40], 0, .little);
            }

            pub fn decode(bytes: *const [encoded_len]u8) !NodeByIdHeader {
                if (!std.mem.eql(u8, bytes[0..4], &magic)) return error.InvalidRecord;
                if (std.mem.readInt(u16, bytes[4..6], .little) != version) return error.InvalidRecord;
                if (std.mem.readInt(u16, bytes[6..8], .little) != encoded_len) return error.InvalidRecord;
                if (std.mem.readInt(u16, bytes[38..40], .little) != 0) return error.InvalidRecord;
                const header = NodeByIdHeader{
                    .max_node_id = std.mem.readInt(u64, bytes[8..16], .little),
                    .node_count = std.mem.readInt(u64, bytes[16..24], .little),
                    .node_digest = std.mem.readInt(u64, bytes[24..32], .little),
                    .flags = std.mem.readInt(u16, bytes[32..34], .little),
                    .record_len = std.mem.readInt(u16, bytes[34..36], .little),
                    .uniform_kind = std.mem.readInt(u16, bytes[36..38], .little),
                };
                try header.validateShape();
                return header;
            }

            pub fn validateShape(self: NodeByIdHeader) !void {
                const known_flags = flag_uniform_kind | flag_short_text_len | flag_derived_text_offset;
                if ((self.flags & ~known_flags) != 0) return error.InvalidRecord;
                if (self.hasShortTextLen() and !self.hasUniformKind()) return error.InvalidRecord;
                if (self.hasDerivedTextOffset() and (!self.hasUniformKind() or !self.hasShortTextLen())) return error.InvalidRecord;
                if (self.hasDerivedTextOffset() and self.node_count != self.max_node_id) return error.InvalidRecord;
                if (self.hasUniformKind()) {
                    if (nodeKindFromInt(self.uniform_kind) == null) return error.InvalidRecord;
                } else if (self.uniform_kind != 0) {
                    return error.InvalidRecord;
                }
                if (self.record_len != self.expectedRecordLen()) return error.InvalidRecord;
                if (self.node_count > self.max_node_id) return error.InvalidRecord;
            }

            pub fn hasUniformKind(self: NodeByIdHeader) bool {
                return (self.flags & flag_uniform_kind) != 0;
            }

            pub fn hasShortTextLen(self: NodeByIdHeader) bool {
                return (self.flags & flag_short_text_len) != 0;
            }

            pub fn hasDerivedTextOffset(self: NodeByIdHeader) bool {
                return (self.flags & flag_derived_text_offset) != 0;
            }

            pub fn expectedRecordLen(self: NodeByIdHeader) u16 {
                var len: u16 = NodeByIdRecord.encoded_len;
                if (self.hasUniformKind()) len -= 2;
                if (self.hasShortTextLen()) len -= 2;
                if (self.hasDerivedTextOffset()) len -= 6;
                return len;
            }

            pub fn uniform(kind: core.NodeKind, short_text_len: bool) NodeByIdHeader {
                var header = NodeByIdHeader{
                    .max_node_id = 0,
                    .node_count = 0,
                    .flags = flag_uniform_kind,
                    .uniform_kind = @intFromEnum(kind),
                };
                if (short_text_len) header.flags |= flag_short_text_len;
                header.record_len = header.expectedRecordLen();
                return header;
            }
        };

        pub const NodeByIdRecord = struct {
            id: u64,
            kind: u16,
            text_offset: u64,
            text_len: u32,

            pub const encoded_len: usize = 12;
            pub const uniform_encoded_len: usize = 10;
            pub const uniform_short_text_len_encoded_len: usize = 8;
            pub const uniform_short_derived_offset_encoded_len: usize = 2;

            pub fn empty() NodeByIdRecord {
                return .{ .id = 0, .kind = 0, .text_offset = 0, .text_len = 0 };
            }

            pub fn encode(self: NodeByIdRecord, out: *[encoded_len]u8) !void {
                if (self.id == 0) {
                    std.mem.writeInt(u16, out[0..2], 0, .little);
                    @memset(out[2..12], 0);
                    return;
                }
                std.debug.assert(nodeKindFromInt(self.kind) != null);
                const stored_kind = std.math.add(u16, self.kind, 1) catch std.math.maxInt(u16);
                std.mem.writeInt(u16, out[0..2], stored_kind, .little);
                std.mem.writeInt(u32, out[2..6], self.text_len, .little);
                try writeU48(out[6..12], self.text_offset);
            }

            pub fn decodeAt(node_id: u64, bytes: *const [encoded_len]u8) !NodeByIdRecord {
                return decodeSliceAt(node_id, bytes);
            }

            pub fn decodeSliceAt(node_id: u64, bytes: []const u8) !NodeByIdRecord {
                if (bytes.len != encoded_len) return error.InvalidRecord;
                if (node_id == 0 or node_id == std.math.maxInt(u64)) return error.InvalidRecord;
                const stored_kind = std.mem.readInt(u16, bytes[0..2], .little);
                const text_len = std.mem.readInt(u32, bytes[2..6], .little);
                const text_offset = readU48(bytes[6..12]);
                if (stored_kind == 0) {
                    if (text_offset != 0 or text_len != 0) return error.InvalidRecord;
                    return empty();
                }
                const kind = stored_kind - 1;
                if (nodeKindFromInt(kind) == null) return error.InvalidRecord;
                return .{
                    .id = node_id,
                    .kind = kind,
                    .text_offset = text_offset,
                    .text_len = text_len,
                };
            }

            pub fn encodeForHeader(self: NodeByIdRecord, header: NodeByIdHeader, out: []u8) !void {
                try header.validateShape();
                if (out.len != header.record_len) return error.InvalidRecord;
                if (!header.hasUniformKind()) {
                    var full: [encoded_len]u8 = undefined;
                    try self.encode(&full);
                    @memcpy(out, &full);
                    return;
                }
                if (header.hasDerivedTextOffset()) {
                    if (self.id == 0) return error.InvalidRecord;
                    if (self.kind != header.uniform_kind) return error.InvalidRecord;
                    const short_len = std.math.cast(u16, self.text_len) orelse return error.RecordTooLarge;
                    std.mem.writeInt(u16, out[0..2], short_len, .little);
                    return;
                }
                if (self.id == 0) {
                    if (header.hasShortTextLen()) {
                        std.mem.writeInt(u16, out[0..2], 0, .little);
                        @memset(out[2..8], 0);
                    } else {
                        std.mem.writeInt(u32, out[0..4], 0, .little);
                        @memset(out[4..10], 0);
                    }
                    return;
                }
                if (self.kind != header.uniform_kind) return error.InvalidRecord;
                if (header.hasShortTextLen()) {
                    const short_len = std.math.cast(u16, self.text_len) orelse return error.RecordTooLarge;
                    std.mem.writeInt(u16, out[0..2], short_len, .little);
                    try writeU48(out[2..8], self.text_offset);
                } else {
                    std.mem.writeInt(u32, out[0..4], self.text_len, .little);
                    try writeU48(out[4..10], self.text_offset);
                }
            }

            pub fn decodeSliceAtForHeader(header: NodeByIdHeader, node_id: u64, bytes: []const u8) !NodeByIdRecord {
                try header.validateShape();
                if (bytes.len != header.record_len) return error.InvalidRecord;
                if (!header.hasUniformKind()) return decodeSliceAt(node_id, bytes);
                if (node_id == 0 or node_id == std.math.maxInt(u64)) return error.InvalidRecord;
                if (header.hasDerivedTextOffset()) return error.InvalidRecord;
                const text_len: u32 = if (header.hasShortTextLen())
                    std.mem.readInt(u16, bytes[0..2], .little)
                else
                    std.mem.readInt(u32, bytes[0..4], .little);
                const text_offset = if (header.hasShortTextLen()) readU48(bytes[2..8]) else readU48(bytes[4..10]);
                if (text_len == 0) {
                    if (text_offset != 0) return error.InvalidRecord;
                    return empty();
                }
                return .{
                    .id = node_id,
                    .kind = header.uniform_kind,
                    .text_offset = text_offset,
                    .text_len = text_len,
                };
            }

            pub fn nodeKind(self: NodeByIdRecord) !core.NodeKind {
                return nodeKindFromInt(self.kind) orelse error.InvalidRecord;
            }
        };

        pub const NodeTextIndexHeader = struct {
            node_count: u64,
            node_digest: u64 = 0,
            order_digest: u64 = 0,
            flags: u16 = 0,
            record_len: u16 = NodeTextIndexRecord.encoded_len,
            uniform_kind: u16 = 0,

            const magic = [_]u8{ 'T', 'K', 'G', 'M' };
            const version: u16 = 9;
            pub const encoded_len: usize = 40;
            pub const flag_uniform_kind: u16 = 1 << 0;
            pub const flag_short_text_len: u16 = 1 << 1;
            pub const flag_u32_id: u16 = 1 << 2;
            pub const flag_derived_hash: u16 = 1 << 3;
            pub const flag_derived_text_span: u16 = 1 << 4;
            pub const flag_text_hash_unique: u16 = 1 << 5;

            pub fn encode(self: NodeTextIndexHeader, out: *[encoded_len]u8) void {
                @memcpy(out[0..4], &magic);
                std.mem.writeInt(u16, out[4..6], version, .little);
                std.mem.writeInt(u16, out[6..8], encoded_len, .little);
                std.mem.writeInt(u64, out[8..16], self.node_count, .little);
                std.mem.writeInt(u64, out[16..24], self.node_digest, .little);
                std.mem.writeInt(u64, out[24..32], self.order_digest, .little);
                std.mem.writeInt(u16, out[32..34], self.flags, .little);
                std.mem.writeInt(u16, out[34..36], self.record_len, .little);
                std.mem.writeInt(u16, out[36..38], self.uniform_kind, .little);
                std.mem.writeInt(u16, out[38..40], 0, .little);
            }

            pub fn decode(bytes: *const [encoded_len]u8) !NodeTextIndexHeader {
                if (!std.mem.eql(u8, bytes[0..4], &magic)) return error.InvalidRecord;
                if (std.mem.readInt(u16, bytes[4..6], .little) != version) return error.InvalidRecord;
                if (std.mem.readInt(u16, bytes[6..8], .little) != encoded_len) return error.InvalidRecord;
                if (std.mem.readInt(u16, bytes[38..40], .little) != 0) return error.InvalidRecord;
                const header = NodeTextIndexHeader{
                    .node_count = std.mem.readInt(u64, bytes[8..16], .little),
                    .node_digest = std.mem.readInt(u64, bytes[16..24], .little),
                    .order_digest = std.mem.readInt(u64, bytes[24..32], .little),
                    .flags = std.mem.readInt(u16, bytes[32..34], .little),
                    .record_len = std.mem.readInt(u16, bytes[34..36], .little),
                    .uniform_kind = std.mem.readInt(u16, bytes[36..38], .little),
                };
                try header.validateShape();
                return header;
            }

            pub fn validateShape(self: NodeTextIndexHeader) !void {
                const known_flags = flag_uniform_kind | flag_short_text_len | flag_u32_id | flag_derived_hash | flag_derived_text_span | flag_text_hash_unique;
                if ((self.flags & ~known_flags) != 0) return error.InvalidRecord;
                if (self.hasDerivedTextSpan() and self.hasShortTextLen()) return error.InvalidRecord;
                if (self.hasUniformKind()) {
                    if (nodeKindFromInt(self.uniform_kind) == null) return error.InvalidRecord;
                } else if (self.uniform_kind != 0) {
                    return error.InvalidRecord;
                }
                if (self.record_len != self.expectedRecordLen()) return error.InvalidRecord;
            }

            pub fn hasUniformKind(self: NodeTextIndexHeader) bool {
                return (self.flags & flag_uniform_kind) != 0;
            }

            pub fn hasShortTextLen(self: NodeTextIndexHeader) bool {
                return (self.flags & flag_short_text_len) != 0;
            }

            pub fn hasU32Id(self: NodeTextIndexHeader) bool {
                return (self.flags & flag_u32_id) != 0;
            }

            pub fn hasDerivedHash(self: NodeTextIndexHeader) bool {
                return (self.flags & flag_derived_hash) != 0;
            }

            pub fn hasDerivedTextSpan(self: NodeTextIndexHeader) bool {
                return (self.flags & flag_derived_text_span) != 0;
            }

            pub fn hasTextHashUnique(self: NodeTextIndexHeader) bool {
                return (self.flags & flag_text_hash_unique) != 0;
            }

            pub fn setTextHashUnique(self: *NodeTextIndexHeader, enabled: bool) void {
                if (enabled) {
                    self.flags |= flag_text_hash_unique;
                } else {
                    self.flags &= ~flag_text_hash_unique;
                }
            }

            pub fn expectedRecordLen(self: NodeTextIndexHeader) u16 {
                var len: u16 = NodeTextIndexRecord.encoded_len;
                if (self.hasDerivedHash()) len -= 8;
                if (self.hasU32Id()) len -= 4;
                if (self.hasUniformKind()) len -= 2;
                if (self.hasDerivedTextSpan()) {
                    len -= 10;
                } else if (self.hasShortTextLen()) {
                    len -= 2;
                }
                return len;
            }

            pub fn withShape(node_count: u64, node_digest: u64, order_digest: u64, uniform_kind: ?u16, short_text_len: bool, u32_id: bool, derived_hash: bool, derived_text_span: bool) NodeTextIndexHeader {
                var header = NodeTextIndexHeader{
                    .node_count = node_count,
                    .node_digest = node_digest,
                    .order_digest = order_digest,
                };
                if (uniform_kind) |kind| {
                    header.flags |= flag_uniform_kind;
                    header.uniform_kind = kind;
                }
                if (short_text_len and !derived_text_span) header.flags |= flag_short_text_len;
                if (u32_id) header.flags |= flag_u32_id;
                if (derived_hash) header.flags |= flag_derived_hash;
                if (derived_text_span) header.flags |= flag_derived_text_span;
                header.record_len = header.expectedRecordLen();
                return header;
            }
        };

        pub const NodeTextIndexRecord = struct {
            hash: u64,
            id: u64,
            kind: u16,
            text_offset: u64,
            text_len: u32,

            pub const encoded_len: usize = 28;

            pub fn encode(self: NodeTextIndexRecord, out: *[encoded_len]u8) !void {
                std.mem.writeInt(u64, out[0..8], self.hash, .little);
                std.mem.writeInt(u64, out[8..16], self.id, .little);
                std.mem.writeInt(u16, out[16..18], self.kind, .little);
                std.mem.writeInt(u32, out[18..22], self.text_len, .little);
                try writeU48(out[22..28], self.text_offset);
            }

            pub fn decode(bytes: *const [encoded_len]u8) !NodeTextIndexRecord {
                return decodeSlice(bytes);
            }

            pub fn decodeSlice(bytes: []const u8) !NodeTextIndexRecord {
                if (bytes.len != encoded_len) return error.InvalidRecord;
                const id = std.mem.readInt(u64, bytes[8..16], .little);
                const kind = std.mem.readInt(u16, bytes[16..18], .little);
                if (nodeKindFromInt(kind) == null) return error.InvalidRecord;
                const text_len = std.mem.readInt(u32, bytes[18..22], .little);
                if (id == 0 or id == std.math.maxInt(u64)) return error.InvalidRecord;
                return .{
                    .hash = std.mem.readInt(u64, bytes[0..8], .little),
                    .id = id,
                    .kind = kind,
                    .text_offset = readU48(bytes[22..28]),
                    .text_len = text_len,
                };
            }

            pub fn encodeForHeader(self: NodeTextIndexRecord, header: NodeTextIndexHeader, out: []u8) !void {
                try header.validateShape();
                if (out.len != header.record_len) return error.InvalidRecord;
                var cursor: usize = 0;
                if (!header.hasDerivedHash()) {
                    std.mem.writeInt(u64, out[cursor..][0..8], self.hash, .little);
                    cursor += 8;
                }
                if (header.hasU32Id()) {
                    const short_id = std.math.cast(u32, self.id) orelse return error.RecordTooLarge;
                    writeU32(out[cursor .. cursor + 4], short_id);
                    cursor += 4;
                } else {
                    std.mem.writeInt(u64, out[cursor..][0..8], self.id, .little);
                    cursor += 8;
                }
                if (header.hasUniformKind()) {
                    if (self.kind != header.uniform_kind) return error.InvalidRecord;
                } else {
                    writeU16(out[cursor .. cursor + 2], self.kind);
                    cursor += 2;
                }
                if (!header.hasDerivedTextSpan()) {
                    if (header.hasShortTextLen()) {
                        const short_len = std.math.cast(u16, self.text_len) orelse return error.RecordTooLarge;
                        writeU16(out[cursor .. cursor + 2], short_len);
                        cursor += 2;
                    } else {
                        writeU32(out[cursor .. cursor + 4], self.text_len);
                        cursor += 4;
                    }
                    try writeU48(out[cursor .. cursor + 6], self.text_offset);
                }
            }

            pub fn decodeSliceForHeader(header: NodeTextIndexHeader, bytes: []const u8) !NodeTextIndexRecord {
                try header.validateShape();
                if (bytes.len != header.record_len) return error.InvalidRecord;
                var cursor: usize = 0;
                const hash = if (header.hasDerivedHash()) 0 else hash: {
                    const decoded = readU64(bytes[cursor .. cursor + 8]);
                    cursor += 8;
                    break :hash decoded;
                };
                const id: u64 = if (header.hasU32Id()) id: {
                    const decoded = readU32(bytes[cursor .. cursor + 4]);
                    cursor += 4;
                    break :id decoded;
                } else id: {
                    const decoded = readU64(bytes[cursor .. cursor + 8]);
                    cursor += 8;
                    break :id decoded;
                };
                const kind = if (header.hasUniformKind()) header.uniform_kind else kind: {
                    const decoded = readU16(bytes[cursor .. cursor + 2]);
                    cursor += 2;
                    break :kind decoded;
                };
                if (nodeKindFromInt(kind) == null) return error.InvalidRecord;
                const text_len: u32 = if (header.hasDerivedTextSpan()) 0 else if (header.hasShortTextLen()) len: {
                    const decoded = readU16(bytes[cursor .. cursor + 2]);
                    cursor += 2;
                    break :len decoded;
                } else len: {
                    const decoded = readU32(bytes[cursor .. cursor + 4]);
                    cursor += 4;
                    break :len decoded;
                };
                const text_offset = if (header.hasDerivedTextSpan()) 0 else readU48(bytes[cursor .. cursor + 6]);
                if (id == 0 or id == std.math.maxInt(u64)) return error.InvalidRecord;
                return .{
                    .hash = hash,
                    .id = id,
                    .kind = kind,
                    .text_offset = text_offset,
                    .text_len = text_len,
                };
            }

            pub fn nodeKind(self: NodeTextIndexRecord) !core.NodeKind {
                return nodeKindFromInt(self.kind) orelse error.InvalidRecord;
            }
        };
    };
}

const TestCore = struct {
    pub const NodeKind = enum(u16) {
        repo,
        task,
        _,
    };
};

const test_format = NodeTextFormat(TestCore, 16);

test "node-by-id header round trips legacy and compact shapes" {
    const Header = test_format.NodeByIdHeader;
    const legacy = Header{ .max_node_id = 9, .node_count = 7, .node_digest = 0x1020_3040_5060_7080 };
    var bytes: [Header.encoded_len]u8 = undefined;
    legacy.encode(&bytes);
    try std.testing.expectEqualSlices(u8, "TKGN", bytes[0..4]);
    try std.testing.expectEqual(legacy, try Header.decode(&bytes));

    var compact = Header.uniform(.task, true);
    compact.max_node_id = 5;
    compact.node_count = 4;
    compact.node_digest = 11;
    compact.encode(&bytes);
    try std.testing.expectEqual(compact, try Header.decode(&bytes));
}

test "node-by-id header rejects invalid shape combinations" {
    const Header = test_format.NodeByIdHeader;
    var header = Header{ .max_node_id = 1, .node_count = 1 };
    header.flags = Header.flag_short_text_len;
    header.record_len = header.expectedRecordLen();
    try std.testing.expectError(error.InvalidRecord, header.validateShape());

    header = Header.uniform(.task, true);
    header.flags |= Header.flag_derived_text_offset;
    header.record_len = header.expectedRecordLen();
    header.max_node_id = 2;
    header.node_count = 1;
    try std.testing.expectError(error.InvalidRecord, header.validateShape());
}

test "node-by-id record preserves legacy and compact bytes" {
    const Header = test_format.NodeByIdHeader;
    const Record = test_format.NodeByIdRecord;
    const record = Record{ .id = 3, .kind = @intFromEnum(TestCore.NodeKind.task), .text_offset = 0x0605_0403_0201, .text_len = 17 };
    var full: [Record.encoded_len]u8 = undefined;
    try record.encode(&full);
    try std.testing.expectEqual(record, try Record.decodeAt(record.id, &full));

    var compact_header = Header.uniform(.task, true);
    compact_header.max_node_id = 3;
    compact_header.node_count = 3;
    var compact: [Record.uniform_short_text_len_encoded_len]u8 = undefined;
    try record.encodeForHeader(compact_header, &compact);
    try std.testing.expectEqual(record, try Record.decodeSliceAtForHeader(compact_header, record.id, &compact));
}

test "node-by-id record rejects invalid ids and 48-bit overflow" {
    const Record = test_format.NodeByIdRecord;
    const record = Record{ .id = 1, .kind = @intFromEnum(TestCore.NodeKind.repo), .text_offset = 1, .text_len = 1 };
    var bytes: [Record.encoded_len]u8 = undefined;
    try record.encode(&bytes);
    try std.testing.expectError(error.InvalidRecord, Record.decodeAt(0, &bytes));

    var too_wide = record;
    too_wide.text_offset = @as(u64, std.math.maxInt(u48)) + 1;
    try std.testing.expectError(error.RecordTooLarge, too_wide.encode(&bytes));
}

test "node-text header round trips full and derived shapes" {
    const Header = test_format.NodeTextIndexHeader;
    const legacy = Header{ .node_count = 8, .node_digest = 9, .order_digest = 10 };
    var bytes: [Header.encoded_len]u8 = undefined;
    legacy.encode(&bytes);
    try std.testing.expectEqualSlices(u8, "TKGM", bytes[0..4]);
    try std.testing.expectEqual(legacy, try Header.decode(&bytes));

    const compact = Header.withShape(8, 9, 10, @intFromEnum(TestCore.NodeKind.task), false, true, true, true);
    compact.encode(&bytes);
    try std.testing.expectEqual(compact, try Header.decode(&bytes));
}

test "node-text header rejects flags and inconsistent record lengths" {
    const Header = test_format.NodeTextIndexHeader;
    var header = Header.withShape(1, 2, 3, null, true, false, false, false);
    header.flags |= Header.flag_derived_text_span;
    try std.testing.expectError(error.InvalidRecord, header.validateShape());
    header = .{ .node_count = 1, .record_len = 1 };
    try std.testing.expectError(error.InvalidRecord, header.validateShape());
}

test "node-text record round trips legacy and compact shapes" {
    const Header = test_format.NodeTextIndexHeader;
    const Record = test_format.NodeTextIndexRecord;
    const record = Record{
        .hash = 0x8877_6655_4433_2211,
        .id = 23,
        .kind = @intFromEnum(TestCore.NodeKind.task),
        .text_offset = 0x0605_0403_0201,
        .text_len = 29,
    };
    var legacy: [Record.encoded_len]u8 = undefined;
    try record.encode(&legacy);
    try std.testing.expectEqual(record, try Record.decode(&legacy));

    const compact_header = Header.withShape(1, 2, 3, record.kind, true, true, true, false);
    var compact: [12]u8 = undefined;
    try std.testing.expectEqual(@as(u16, compact.len), compact_header.record_len);
    try record.encodeForHeader(compact_header, &compact);
    const decoded = try Record.decodeSliceForHeader(compact_header, &compact);
    try std.testing.expectEqual(@as(u64, 0), decoded.hash);
    try std.testing.expectEqual(record.id, decoded.id);
    try std.testing.expectEqual(record.kind, decoded.kind);
    try std.testing.expectEqual(record.text_offset, decoded.text_offset);
    try std.testing.expectEqual(record.text_len, decoded.text_len);
}

test "node-text record rejects invalid kinds ids and 48-bit overflow" {
    const Record = test_format.NodeTextIndexRecord;
    var record = Record{ .hash = 1, .id = 2, .kind = @intFromEnum(TestCore.NodeKind.repo), .text_offset = 3, .text_len = 4 };
    var bytes: [Record.encoded_len]u8 = undefined;
    try record.encode(&bytes);
    std.mem.writeInt(u16, bytes[16..18], 16, .little);
    try std.testing.expectError(error.InvalidRecord, Record.decode(&bytes));
    std.mem.writeInt(u16, bytes[16..18], record.kind, .little);
    std.mem.writeInt(u64, bytes[8..16], 0, .little);
    try std.testing.expectError(error.InvalidRecord, Record.decode(&bytes));

    record.text_offset = @as(u64, std.math.maxInt(u48)) + 1;
    try std.testing.expectError(error.RecordTooLarge, record.encode(&bytes));
}
