const std = @import("std");

/// Owns read-only node catalog views, streaming node-id/record iterators, and
/// the small edge-batch existence cache. Persisted codecs and concrete Store
/// I/O enter through one injected capability boundary.
pub fn NodeCatalogReadViews(comptime Ops: type) type {
    const Store = Ops.dep_Store;
    const core = Ops.dep_core;
    const support = Ops.dep_support;
    const IndexMeta = Ops.dep_IndexMeta;
    const NodeByIdHeader = Ops.dep_NodeByIdHeader;
    const NodeByIdRecord = Ops.dep_NodeByIdRecord;
    const NodeTextsView = Ops.dep_NodeTextsView;
    const StoredNode = Ops.dep_StoredNode;

    return struct {
        pub const NodeIdIterator = struct {
            store: Store,
            file: std.Io.File,
            map: ?std.Io.File.MemoryMap = null,
            kind_filter: ?core.NodeKind,
            header: NodeByIdHeader,
            next_id: u64,
            max_node_id: u64,
            expected_nodes: u64,
            seen_nodes: u64 = 0,

            pub fn deinit(self: *NodeIdIterator) void {
                if (self.map) |*map| map.destroy(self.store.io);
                self.file.close(self.store.io);
            }

            pub fn next(self: *NodeIdIterator) !?core.NodeId {
                while (self.next_id <= self.max_node_id) : (self.next_id += 1) {
                    const id = self.next_id;
                    const record = if (self.map) |*map|
                        try Ops.readNodeByIdRecordFromMap(self.header, map, id)
                    else
                        try Ops.readNodeByIdRecordAt(self.store, self.file, self.header, id);
                    if (record.id == 0) continue;
                    if (record.id != id) return error.InvalidRecord;
                    if (self.seen_nodes >= self.expected_nodes) return error.InvalidRecord;
                    self.seen_nodes += 1;
                    if (self.kind_filter) |filter| {
                        if ((try record.nodeKind()) != filter) continue;
                    }
                    self.next_id += 1;
                    return core.NodeId.fromInt(record.id);
                }
                if (self.seen_nodes != self.expected_nodes) return error.InvalidRecord;
                return null;
            }
        };

        pub const NodeByIdIndexView = struct {
            store: Store,
            file: std.Io.File,
            map: ?std.Io.File.MemoryMap = null,
            header: NodeByIdHeader,
            max_node_id: u64,
            node_count: u64,

            pub fn open(store: Store, meta: IndexMeta) !NodeByIdIndexView {
                var file = try std.Io.Dir.cwd().openFile(store.io, store.node_by_id_path, .{});
                errdefer file.close(store.io);
                const header = try Ops.readNodeByIdHeaderFromFile(store, file);
                if (header.node_count != meta.nodes) return error.InvalidRecord;
                if (header.node_digest != meta.node_digest) return error.InvalidRecord;
                if (header.node_count > header.max_node_id) return error.InvalidRecord;
                const expected_size = try Ops.nodeByIdFileSizeForHeaderStore(store, header);
                if (try Ops.regularFileSize(store, file) != expected_size) return error.InvalidRecord;
                var map = Ops.openReadOnlyMemoryMap(store.io, file, expected_size) catch null;
                errdefer if (map) |*mapped| mapped.destroy(store.io);
                return .{
                    .store = store,
                    .file = file,
                    .map = map,
                    .header = header,
                    .max_node_id = header.max_node_id,
                    .node_count = header.node_count,
                };
            }

            pub fn deinit(self: *NodeByIdIndexView) void {
                if (self.map) |*map| map.destroy(self.store.io);
                self.file.close(self.store.io);
            }

            pub fn nodeExists(self: *const NodeByIdIndexView, node_id: core.NodeId) !bool {
                if (support.isReservedNodeId(node_id)) return core.Error.InvalidId;
                return (try self.readOptionalRecord(node_id.toInt())) != null;
            }

            pub fn nodeKind(self: *const NodeByIdIndexView, node_id: core.NodeId) !?core.NodeKind {
                if (support.isReservedNodeId(node_id)) return core.Error.InvalidId;
                const record = (try self.readOptionalRecord(node_id.toInt())) orelse return null;
                return try record.nodeKind();
            }

            pub fn readRecord(self: *const NodeByIdIndexView, node_id: u64) !NodeByIdRecord {
                if (node_id == 0 or node_id > self.max_node_id) return error.InvalidRecord;
                if (self.map) |*map| return Ops.readNodeByIdRecordFromMap(self.header, map, node_id);
                return Ops.readNodeByIdRecordAt(self.store, self.file, self.header, node_id);
            }

            pub fn readOptionalRecord(self: *const NodeByIdIndexView, node_id: u64) !?NodeByIdRecord {
                if (node_id == 0) return error.InvalidRecord;
                if (node_id > self.max_node_id) return null;
                const record = try self.readRecord(node_id);
                if (record.id == 0) {
                    if (self.node_count == self.max_node_id) return error.InvalidRecord;
                    return null;
                }
                if (record.id != node_id) return error.InvalidRecord;
                return record;
            }
        };

        pub const EdgeBatchNodeExistenceCache = struct {
            const Entry = struct {
                id: u64 = 0,
                exists: bool = false,
            };

            entries: [support.edge_batch_node_cache_slots]Entry = [_]Entry{.{}} ** support.edge_batch_node_cache_slots,

            pub fn nodeExists(self: *EdgeBatchNodeExistenceCache, view: *const NodeByIdIndexView, node_id: u64) !bool {
                const slot = node_id & (support.edge_batch_node_cache_slots - 1);
                const entry = &self.entries[@intCast(slot)];
                if (entry.id == node_id) return entry.exists;
                const exists = try view.nodeExists(core.NodeId.fromInt(node_id));
                entry.* = .{ .id = node_id, .exists = exists };
                return exists;
            }
        };

        pub const NodeRecordView = struct {
            by_id: NodeByIdIndexView,
            texts: NodeTextsView,

            pub const NodeRef = struct {
                id: core.NodeId,
                kind: core.NodeKind,
                text_offset: u64,
                text_len: u32,
                text_bytes: ?[]const u8 = null,
            };

            pub fn open(store: Store, meta: IndexMeta) !NodeRecordView {
                var by_id = try NodeByIdIndexView.open(store, meta);
                errdefer by_id.deinit();
                var texts = try NodeTextsView.open(store);
                errdefer texts.deinit();
                return .{
                    .by_id = by_id,
                    .texts = texts,
                };
            }

            pub fn deinit(self: *NodeRecordView) void {
                self.texts.deinit();
                self.by_id.deinit();
            }

            pub fn readNodeById(self: *const NodeRecordView, allocator: std.mem.Allocator, node_id: core.NodeId) !?StoredNode {
                if (support.isReservedNodeId(node_id)) return core.Error.InvalidId;
                const record = (try self.by_id.readOptionalRecord(node_id.toInt())) orelse return null;
                return try self.texts.readStoredNode(allocator, record);
            }

            pub fn readNodeRefById(self: *const NodeRecordView, node_id: core.NodeId) !?NodeRef {
                if (support.isReservedNodeId(node_id)) return core.Error.InvalidId;
                const record = (try self.by_id.readOptionalRecord(node_id.toInt())) orelse return null;
                return try self.nodeRefFromRecord(record);
            }

            fn nodeRefFromRecord(self: *const NodeRecordView, record: NodeByIdRecord) !NodeRef {
                return .{
                    .id = core.NodeId.fromInt(record.id),
                    .kind = try record.nodeKind(),
                    .text_offset = record.text_offset,
                    .text_len = record.text_len,
                    .text_bytes = try self.texts.mappedBytes(record.text_offset, record.text_len),
                };
            }

            pub fn readNodeRefTextAlloc(self: *const NodeRecordView, allocator: std.mem.Allocator, node_ref: NodeRef) ![]u8 {
                if (node_ref.text_bytes) |bytes| return allocator.dupe(u8, bytes);
                return self.texts.readTextAlloc(allocator, node_ref.text_offset, node_ref.text_len);
            }

            pub fn readNodeRefTextBorrowed(self: *const NodeRecordView, node_ref: NodeRef) !?[]const u8 {
                if (node_ref.text_bytes) |bytes| return bytes;
                return self.texts.borrowedBytes(node_ref.text_offset, node_ref.text_len);
            }

            pub fn matchNode(self: *const NodeRecordView, node_id: core.NodeId, kind_filter: ?core.NodeKind, text_eq: ?[]const u8) !?bool {
                if (support.isReservedNodeId(node_id)) return core.Error.InvalidId;
                const record = (try self.by_id.readOptionalRecord(node_id.toInt())) orelse return null;
                if (kind_filter) |filter| {
                    if ((try record.nodeKind()) != filter) return false;
                }
                if (text_eq) |text| {
                    if (!try self.texts.matches(record.text_offset, record.text_len, text)) return false;
                }
                return true;
            }
        };

        pub const NodeRecordIterator = struct {
            view: NodeRecordView,
            kind_filter: ?core.NodeKind,
            next_id: u64 = 1,
            seen_nodes: u64 = 0,

            pub fn deinit(self: *NodeRecordIterator) void {
                self.view.deinit();
            }

            pub fn next(self: *NodeRecordIterator, allocator: std.mem.Allocator) !?StoredNode {
                while (self.next_id <= self.view.by_id.max_node_id) : (self.next_id += 1) {
                    const id = self.next_id;
                    const record = try self.view.by_id.readRecord(id);
                    if (record.id == 0) continue;
                    if (record.id != id) return error.InvalidRecord;
                    if (self.seen_nodes >= self.view.by_id.node_count) return error.InvalidRecord;
                    self.seen_nodes += 1;
                    if (self.kind_filter) |filter| {
                        if ((try record.nodeKind()) != filter) continue;
                    }
                    self.next_id += 1;
                    return try self.view.texts.readStoredNode(allocator, record);
                }
                if (self.seen_nodes != self.view.by_id.node_count) return error.InvalidRecord;
                return null;
            }

            pub fn nextRef(self: *NodeRecordIterator) !?NodeRecordView.NodeRef {
                while (self.next_id <= self.view.by_id.max_node_id) : (self.next_id += 1) {
                    const id = self.next_id;
                    const record = try self.view.by_id.readRecord(id);
                    if (record.id == 0) continue;
                    if (record.id != id) return error.InvalidRecord;
                    if (self.seen_nodes >= self.view.by_id.node_count) return error.InvalidRecord;
                    self.seen_nodes += 1;
                    if (self.kind_filter) |filter| {
                        if ((try record.nodeKind()) != filter) continue;
                    }
                    self.next_id += 1;
                    return try self.view.nodeRefFromRecord(record);
                }
                if (self.seen_nodes != self.view.by_id.node_count) return error.InvalidRecord;
                return null;
            }

            pub fn readRefTextAlloc(self: *const NodeRecordIterator, allocator: std.mem.Allocator, node_ref: NodeRecordView.NodeRef) ![]u8 {
                return self.view.readNodeRefTextAlloc(allocator, node_ref);
            }

            pub fn readRefTextBorrowed(self: *const NodeRecordIterator, node_ref: NodeRecordView.NodeRef) !?[]const u8 {
                return self.view.readNodeRefTextBorrowed(node_ref);
            }
        };
    };
}

const TestCore = struct {
    pub const Error = error{InvalidId};
    pub const NodeKind = enum { file, function };
    pub const NodeId = struct {
        value: u64,
        pub fn fromInt(value: u64) @This() {
            return .{ .value = value };
        }
        pub fn toInt(self: @This()) u64 {
            return self.value;
        }
    };
};

const TestRecord = struct {
    id: u64,
    kind: TestCore.NodeKind = .file,
    text_offset: u64 = 0,
    text_len: u32 = 0,
    pub fn nodeKind(self: @This()) !TestCore.NodeKind {
        return self.kind;
    }
};

const TestHeader = struct {
    node_count: u64,
    max_node_id: u64,
    node_digest: u64 = 0,
};

const TestStore = struct {
    allocator: std.mem.Allocator = std.testing.allocator,
    io: std.Io = std.testing.io,
    node_by_id_path: []const u8 = "unused",
    records: []const TestRecord,

    pub fn readNodeByIdRecordAt(self: @This(), _: std.Io.File, _: TestHeader, id: u64) !TestRecord {
        if (id == 0 or id > self.records.len) return error.InvalidRecord;
        return self.records[@intCast(id - 1)];
    }
};

const TestTextsView = struct {
    bytes: []const u8,
    pub fn open(store: TestStore) !@This() {
        _ = store;
        return .{ .bytes = "" };
    }
    pub fn deinit(_: *@This()) void {}
    pub fn readStoredNode(self: *const @This(), allocator: std.mem.Allocator, record: TestRecord) !TestStoredNode {
        return .{
            .id = TestCore.NodeId.fromInt(record.id),
            .kind = try record.nodeKind(),
            .text = try self.readTextAlloc(allocator, record.text_offset, record.text_len),
        };
    }
    pub fn mappedBytes(self: *const @This(), offset: u64, len: u32) !?[]const u8 {
        const start = std.math.cast(usize, offset) orelse return error.InvalidRecord;
        const end = std.math.add(usize, start, len) catch return error.InvalidRecord;
        if (end > self.bytes.len) return error.InvalidRecord;
        return self.bytes[start..end];
    }
    pub fn readTextAlloc(self: *const @This(), allocator: std.mem.Allocator, offset: u64, len: u32) ![]u8 {
        return allocator.dupe(u8, (try self.mappedBytes(offset, len)).?);
    }
    pub fn borrowedBytes(self: *const @This(), offset: u64, len: u32) !?[]const u8 {
        return self.mappedBytes(offset, len);
    }
    pub fn matches(self: *const @This(), offset: u64, len: u32, expected: []const u8) !bool {
        return std.mem.eql(u8, (try self.mappedBytes(offset, len)).?, expected);
    }
};

const TestStoredNode = struct {
    id: TestCore.NodeId,
    kind: TestCore.NodeKind,
    text: []u8,
    pub fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        allocator.free(self.text);
    }
};

const TestSupport = struct {
    pub const edge_batch_node_cache_slots = 4;
    pub fn isReservedNodeId(id: TestCore.NodeId) bool {
        return id.toInt() == 0;
    }
};

const TestOps = struct {
    pub const dep_Store = TestStore;
    pub const dep_core = TestCore;
    pub const dep_support = TestSupport;
    pub const dep_IndexMeta = struct { nodes: u64, node_digest: u64 };
    pub const dep_NodeByIdHeader = TestHeader;
    pub const dep_NodeByIdRecord = TestRecord;
    pub const dep_NodeTextsView = TestTextsView;
    pub const dep_StoredNode = TestStoredNode;
    pub fn readNodeByIdRecordFromMap(_: TestHeader, _: *const std.Io.File.MemoryMap, _: u64) !TestRecord {
        return error.InvalidRecord;
    }
    pub fn readNodeByIdRecordAt(store: TestStore, file: std.Io.File, header: TestHeader, id: u64) !TestRecord {
        return store.readNodeByIdRecordAt(file, header, id);
    }
    pub fn readNodeByIdHeaderFromFile(_: TestStore, _: std.Io.File) !TestHeader {
        return error.InvalidRecord;
    }
    pub fn nodeByIdFileSizeForHeaderStore(_: TestStore, _: TestHeader) !u64 {
        return error.InvalidRecord;
    }
    pub fn regularFileSize(_: TestStore, _: std.Io.File) !u64 {
        return error.InvalidRecord;
    }
    pub fn openReadOnlyMemoryMap(_: std.Io, _: std.Io.File, _: u64) !std.Io.File.MemoryMap {
        return error.Unsupported;
    }
};

const TestViews = NodeCatalogReadViews(TestOps);

fn testByIdView(records: []const TestRecord, node_count: u64) TestViews.NodeByIdIndexView {
    return .{
        .store = .{ .records = records },
        .file = undefined,
        .header = .{ .node_count = node_count, .max_node_id = records.len },
        .max_node_id = records.len,
        .node_count = node_count,
    };
}

test "node catalog view rejects reserved and mismatched record ids" {
    const records = [_]TestRecord{.{ .id = 2 }};
    const view = testByIdView(&records, 1);
    try std.testing.expectError(TestCore.Error.InvalidId, view.nodeExists(.fromInt(0)));
    try std.testing.expectError(error.InvalidRecord, view.readOptionalRecord(1));
}

test "node catalog iterator counts active records exactly" {
    const records = [_]TestRecord{ .{ .id = 1 }, .{ .id = 0 } };
    var iterator = TestViews.NodeIdIterator{
        .store = .{ .records = &records },
        .file = undefined,
        .kind_filter = null,
        .header = .{ .node_count = 2, .max_node_id = 2 },
        .next_id = 1,
        .max_node_id = 2,
        .expected_nodes = 2,
    };
    try std.testing.expectEqual(@as(u64, 1), (try iterator.next()).?.toInt());
    try std.testing.expectError(error.InvalidRecord, iterator.next());
}

test "node record view preserves borrowed text without allocation" {
    const records = [_]TestRecord{.{ .id = 1, .kind = .function, .text_offset = 2, .text_len = 4 }};
    const view = TestViews.NodeRecordView{
        .by_id = testByIdView(&records, 1),
        .texts = .{ .bytes = "xxnameyy" },
    };
    const node_ref = (try view.readNodeRefById(.fromInt(1))).?;
    try std.testing.expectEqualStrings("name", node_ref.text_bytes.?);
    try std.testing.expectEqualStrings("name", (try view.readNodeRefTextBorrowed(node_ref)).?);
}

test "node record iterator preserves holes filters and exact active count" {
    const records = [_]TestRecord{
        .{ .id = 1, .kind = .file, .text_offset = 0, .text_len = 1 },
        .{ .id = 0 },
        .{ .id = 3, .kind = .function, .text_offset = 1, .text_len = 2 },
    };
    var iterator = TestViews.NodeRecordIterator{
        .view = .{
            .by_id = testByIdView(&records, 2),
            .texts = .{ .bytes = "fok" },
        },
        .kind_filter = .function,
    };
    var node = (try iterator.next(std.testing.allocator)).?;
    defer node.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 3), node.id.toInt());
    try std.testing.expectEqualStrings("ok", node.text);
    try std.testing.expect((try iterator.next(std.testing.allocator)) == null);
}
