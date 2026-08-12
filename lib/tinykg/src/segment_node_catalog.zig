const std = @import("std");
const core = @import("core.zig");

/// One exact-text key projected by an in-memory or mapped segment catalog.
pub const ExactTextEntry = struct {
    kind: core.NodeKind,
    text: []const u8,
    id: core.NodeId,
};

/// One node identity record shared by catalog persistence and QL execution.
pub const NodeInfoEntry = struct {
    id: core.NodeId,
    kind: core.NodeKind,
    text: []const u8,
};

/// Storage-independent node catalog contract consumed by segment execution.
/// Persistence owners may expose the same lookup and match surface without
/// importing the QL executor or the Storage façade.
pub const SegmentNodeCatalog = struct {
    exact_texts: []const ExactTextEntry,
    nodes_by_id: []const NodeInfoEntry,
    validated: bool = false,

    pub fn lookupExact(self: SegmentNodeCatalog, allocator: std.mem.Allocator, kind: ?core.NodeKind, text_value: []const u8, max_ids: usize) !std.ArrayList(core.NodeId) {
        var out = std.ArrayList(core.NodeId).empty;
        errdefer out.deinit(allocator);
        if (max_ids == 0) return out;
        const filter = kind orelse return error.Unsupported;
        var index_pos = lowerBoundExactText(self.exact_texts, filter, text_value);
        while (index_pos < self.exact_texts.len) : (index_pos += 1) {
            const entry = self.exact_texts[index_pos];
            if (compareExactTextKey(entry.kind, entry.text, filter, text_value) != .eq) break;
            const matches = (try self.matchNode(entry.id, entry.kind, entry.text)) orelse return error.InvalidRecord;
            if (!matches) return error.InvalidRecord;
            try out.append(allocator, entry.id);
            if (out.items.len >= max_ids) break;
        }
        return out;
    }

    pub fn matchNode(self: SegmentNodeCatalog, id: core.NodeId, kind: ?core.NodeKind, text: ?[]const u8) !?bool {
        const index_pos = lowerBoundNodeId(self.nodes_by_id, id);
        if (index_pos >= self.nodes_by_id.len or self.nodes_by_id[index_pos].id != id) return null;
        const entry = self.nodes_by_id[index_pos];
        if (kind) |filter| {
            if (entry.kind != filter) return false;
        }
        if (text) |expected| {
            if (!std.mem.eql(u8, entry.text, expected)) return false;
        }
        return true;
    }

    pub fn validate(self: SegmentNodeCatalog) !void {
        if (self.exact_texts.len != self.nodes_by_id.len) return error.InvalidRecord;
        for (self.exact_texts) |entry| {
            if (!validNodeId(entry.id)) return error.InvalidRecord;
            if (!validText(entry.text)) return error.InvalidRecord;
        }
        for (self.nodes_by_id) |entry| {
            if (!validNodeId(entry.id)) return error.InvalidRecord;
            if (!validText(entry.text)) return error.InvalidRecord;
        }
        var index_pos: usize = 1;
        while (index_pos < self.exact_texts.len) : (index_pos += 1) {
            if (compareExactTextEntry(self.exact_texts[index_pos - 1], self.exact_texts[index_pos]) != .lt) return error.InvalidRecord;
        }
        index_pos = 1;
        while (index_pos < self.nodes_by_id.len) : (index_pos += 1) {
            if (self.nodes_by_id[index_pos - 1].id.toInt() >= self.nodes_by_id[index_pos].id.toInt()) return error.InvalidRecord;
        }
        for (self.exact_texts) |entry| {
            const matches = (try self.matchNode(entry.id, entry.kind, entry.text)) orelse return error.InvalidRecord;
            if (!matches) return error.InvalidRecord;
        }
    }
};

fn lowerBoundExactText(entries: []const ExactTextEntry, kind: core.NodeKind, text: []const u8) usize {
    var low: usize = 0;
    var high = entries.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        if (compareExactTextKey(entries[mid].kind, entries[mid].text, kind, text) == .lt) {
            low = mid + 1;
        } else {
            high = mid;
        }
    }
    return low;
}

fn lowerBoundNodeId(entries: []const NodeInfoEntry, id: core.NodeId) usize {
    var low: usize = 0;
    var high = entries.len;
    const target = id.toInt();
    while (low < high) {
        const mid = low + (high - low) / 2;
        if (entries[mid].id.toInt() < target) {
            low = mid + 1;
        } else {
            high = mid;
        }
    }
    return low;
}

fn compareExactTextEntry(left: ExactTextEntry, right: ExactTextEntry) std.math.Order {
    const key_order = compareExactTextKey(left.kind, left.text, right.kind, right.text);
    if (key_order != .eq) return key_order;
    return std.math.order(left.id.toInt(), right.id.toInt());
}

fn compareExactTextKey(left_kind: core.NodeKind, left_text: []const u8, right_kind: core.NodeKind, right_text: []const u8) std.math.Order {
    const kind_order = std.math.order(@intFromEnum(left_kind), @intFromEnum(right_kind));
    if (kind_order != .eq) return kind_order;
    return std.mem.order(u8, left_text, right_text);
}

fn validNodeId(id: core.NodeId) bool {
    return id != .none and id.toInt() != std.math.maxInt(u64);
}

fn validText(text: []const u8) bool {
    return text.len != 0 and std.mem.indexOfScalar(u8, text, 0) == null;
}

test "segment node catalog validates and serves exact lookups" {
    const exact_texts = [_]ExactTextEntry{
        .{ .kind = .file, .text = "src/a.zig", .id = .fromInt(1) },
        .{ .kind = .file, .text = "src/a.zig", .id = .fromInt(2) },
        .{ .kind = .function, .text = "main", .id = .fromInt(3) },
    };
    const nodes = [_]NodeInfoEntry{
        .{ .id = .fromInt(1), .kind = .file, .text = "src/a.zig" },
        .{ .id = .fromInt(2), .kind = .file, .text = "src/a.zig" },
        .{ .id = .fromInt(3), .kind = .function, .text = "main" },
    };
    const catalog = SegmentNodeCatalog{ .exact_texts = &exact_texts, .nodes_by_id = &nodes };
    try catalog.validate();
    var ids = try catalog.lookupExact(std.testing.allocator, .file, "src/a.zig", 1);
    defer ids.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(core.NodeId, &.{.fromInt(1)}, ids.items);
    try std.testing.expectEqual(true, try catalog.matchNode(.fromInt(3), .function, "main"));
    try std.testing.expectEqual(false, try catalog.matchNode(.fromInt(3), .file, null));
    try std.testing.expectEqual(null, try catalog.matchNode(.fromInt(4), null, null));
}

test "segment node catalog rejects ordering and cross-link drift" {
    const nodes = [_]NodeInfoEntry{
        .{ .id = .fromInt(1), .kind = .file, .text = "a" },
        .{ .id = .fromInt(2), .kind = .function, .text = "b" },
    };
    const reversed_exact = [_]ExactTextEntry{
        .{ .kind = .function, .text = "b", .id = .fromInt(2) },
        .{ .kind = .file, .text = "a", .id = .fromInt(1) },
    };
    try std.testing.expectError(error.InvalidRecord, (SegmentNodeCatalog{
        .exact_texts = &reversed_exact,
        .nodes_by_id = &nodes,
    }).validate());

    const mismatched_exact = [_]ExactTextEntry{
        .{ .kind = .file, .text = "wrong", .id = .fromInt(1) },
        .{ .kind = .function, .text = "b", .id = .fromInt(2) },
    };
    try std.testing.expectError(error.InvalidRecord, (SegmentNodeCatalog{
        .exact_texts = &mismatched_exact,
        .nodes_by_id = &nodes,
    }).validate());
}
