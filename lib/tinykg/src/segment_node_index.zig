const std = @import("std");
const core = @import("core.zig");
const segment_catalog_summary = @import("segment_catalog_summary.zig");
const segment_manifest = @import("segment_manifest.zig");
const segment_executor = @import("ql/segment_executor.zig");

pub const exact_texts_leaf = "segment_node_texts.idx";
pub const nodes_by_id_leaf = "segment_nodes_by_id.idx";
pub const texts_leaf = "segment_node_texts.dat";

const max_nodes = segment_catalog_summary.max_nodes;
const max_text_bytes: u32 = 64 * 1024;
const max_texts_file_bytes = segment_catalog_summary.max_texts_file_bytes;
const max_index_file_bytes: u64 = 256 * 1024 * 1024;
const catalog_id_run_chunk_records: usize = 64 * 1024;
const catalog_id_run_read_buffer_bytes: usize = 256 * 1024;

pub const OwnedCatalog = struct {
    texts: []u8,
    exact_texts: []segment_executor.ExactTextEntry,
    nodes_by_id: []segment_executor.NodeInfoEntry,

    pub fn deinit(self: *OwnedCatalog, allocator: std.mem.Allocator) void {
        allocator.free(self.nodes_by_id);
        allocator.free(self.exact_texts);
        allocator.free(self.texts);
    }

    pub fn catalog(self: OwnedCatalog) segment_executor.SegmentNodeCatalog {
        return .{
            .exact_texts = self.exact_texts,
            .nodes_by_id = self.nodes_by_id,
            .validated = true,
        };
    }
};

pub const CatalogSummary = segment_catalog_summary.CatalogSummary;

pub const MappedCatalog = struct {
    io: std.Io,
    texts: MappedFileView,
    nodes_by_id: MappedFileView,
    exact_texts: MappedFileView,
    nodes_header: IndexHeader,
    exact_header: IndexHeader,
    validated: bool = true,

    pub fn open(io: std.Io, dir_path: []const u8) !MappedCatalog {
        var texts_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const texts_path = try std.fmt.bufPrint(&texts_buf, "{s}/" ++ texts_leaf, .{dir_path});
        var nodes_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const nodes_path = try std.fmt.bufPrint(&nodes_buf, "{s}/" ++ nodes_by_id_leaf, .{dir_path});
        var exact_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const exact_path = try std.fmt.bufPrint(&exact_buf, "{s}/" ++ exact_texts_leaf, .{dir_path});

        var texts = try MappedFileView.open(io, texts_path, max_texts_file_bytes);
        errdefer texts.deinit();
        const texts_digest = std.hash.Wyhash.hash(0x544B_4E53, texts.bytes());

        var nodes_by_id = try MappedFileView.open(io, nodes_path, max_index_file_bytes);
        errdefer nodes_by_id.deinit();
        const nodes_header = try decodeNodeByIdIndexHeader(nodes_by_id.bytes(), texts.bytes().len, texts_digest);
        try validateNodeByIdRecordDigest(nodes_by_id.bytes(), nodes_header);

        var exact_texts = try MappedFileView.open(io, exact_path, max_index_file_bytes);
        errdefer exact_texts.deinit();
        const exact_header = try decodeIndexHeader(exact_texts.bytes(), ExactTextRecord.magic, 0, texts.bytes().len, texts_digest);
        try validateExactTextHeader(exact_header, nodes_header);
        try validateExactRecordDigest(exact_texts.bytes(), exact_header);

        var catalog = MappedCatalog{
            .io = io,
            .texts = texts,
            .nodes_by_id = nodes_by_id,
            .exact_texts = exact_texts,
            .nodes_header = nodes_header,
            .exact_header = exact_header,
        };
        try catalog.validate();
        return catalog;
    }

    pub fn openTrusted(io: std.Io, dir_path: []const u8, expected: CatalogSummary) !MappedCatalog {
        try expected.validate();
        var texts_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const texts_path = try std.fmt.bufPrint(&texts_buf, "{s}/" ++ texts_leaf, .{dir_path});
        var nodes_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const nodes_path = try std.fmt.bufPrint(&nodes_buf, "{s}/" ++ nodes_by_id_leaf, .{dir_path});
        var exact_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const exact_path = try std.fmt.bufPrint(&exact_buf, "{s}/" ++ exact_texts_leaf, .{dir_path});

        var texts = try MappedFileView.open(io, texts_path, max_texts_file_bytes);
        errdefer texts.deinit();
        if (texts.bytes().len != expected.texts_bytes) return error.InvalidRecord;

        var nodes_by_id = try MappedFileView.open(io, nodes_path, max_index_file_bytes);
        errdefer nodes_by_id.deinit();
        const texts_len = std.math.cast(usize, expected.texts_bytes) orelse return error.RecordTooLarge;
        const nodes_header = try decodeNodeByIdIndexHeader(nodes_by_id.bytes(), texts_len, expected.texts_digest);
        if (nodes_header.node_count != expected.node_count or
            nodes_header.id_base != expected.node_id_base or
            nodes_header.record_digest != expected.nodes_record_digest)
        {
            return error.InvalidRecord;
        }

        var exact_texts = try MappedFileView.open(io, exact_path, max_index_file_bytes);
        errdefer exact_texts.deinit();
        const exact_header = try decodeIndexHeader(exact_texts.bytes(), ExactTextRecord.magic, 0, texts_len, expected.texts_digest);
        try validateExactTextHeader(exact_header, nodes_header);
        if (exact_header.node_count != expected.node_count or exact_header.record_digest != expected.exact_record_digest) return error.InvalidRecord;

        return .{
            .io = io,
            .texts = texts,
            .nodes_by_id = nodes_by_id,
            .exact_texts = exact_texts,
            .nodes_header = nodes_header,
            .exact_header = exact_header,
        };
    }

    pub fn deinit(self: *MappedCatalog) void {
        self.exact_texts.deinit();
        self.nodes_by_id.deinit();
        self.texts.deinit();
    }

    pub fn summary(self: *const MappedCatalog) CatalogSummary {
        return .{
            .node_count = self.nodes_header.node_count,
            .node_id_base = self.nodes_header.id_base,
            .texts_bytes = self.nodes_header.texts_bytes,
            .texts_digest = self.nodes_header.texts_digest,
            .nodes_record_digest = self.nodes_header.record_digest,
            .exact_record_digest = self.exact_header.record_digest,
        };
    }

    pub fn lookupExact(self: *const MappedCatalog, allocator: std.mem.Allocator, kind: ?core.NodeKind, text: []const u8, max_ids: usize) !std.ArrayList(core.NodeId) {
        var out = std.ArrayList(core.NodeId).empty;
        errdefer out.deinit(allocator);
        if (max_ids == 0) return out;
        const filter = kind orelse return error.Unsupported;
        var index_pos = try self.lowerBoundExactText(filter, text);
        while (index_pos < self.exact_header.node_count) : (index_pos += 1) {
            const entry = try self.exactTextAt(index_pos);
            const key = try self.exactTextKey(entry);
            if (compareExactTextKey(key.kind, key.text, filter, text) != .eq) break;
            try out.append(allocator, key.id);
            if (out.items.len >= max_ids) break;
        }
        return out;
    }

    pub fn matchNode(self: *const MappedCatalog, id: core.NodeId, kind: ?core.NodeKind, text: ?[]const u8) !?bool {
        const index_pos = try self.lowerBoundNodeId(id);
        if (index_pos >= self.nodes_header.node_count) return null;
        const entry = try self.nodeByIdAt(index_pos);
        if (entry.id != id) return null;
        if (kind) |filter| {
            if (entry.kind != filter) return false;
        }
        if (text) |expected| {
            const actual = try self.textSlice(entry.text_offset, entry.text_len);
            if (!std.mem.eql(u8, actual, expected)) return false;
        }
        return true;
    }

    pub fn nodeInfo(self: *const MappedCatalog, id: core.NodeId) !?segment_executor.NodeInfoEntry {
        const index_pos = try self.lowerBoundNodeId(id);
        if (index_pos >= self.nodes_header.node_count) return null;
        const entry = try self.nodeByIdAt(index_pos);
        if (entry.id != id) return null;
        return .{
            .id = entry.id,
            .kind = entry.kind,
            .text = try self.textSlice(entry.text_offset, entry.text_len),
        };
    }

    pub fn validate(self: *const MappedCatalog) !void {
        if (self.exact_header.node_count != self.nodes_header.node_count) return error.InvalidRecord;

        var i: u64 = 0;
        var previous_node: ?NodeByIdRecord = null;
        while (i < self.nodes_header.node_count) : (i += 1) {
            const record = try self.nodeByIdAt(i);
            if (!validNodeId(record.id)) return error.InvalidRecord;
            _ = try self.textSlice(record.text_offset, record.text_len);
            if (previous_node) |previous| {
                if (previous.id.toInt() >= record.id.toInt()) return error.InvalidRecord;
            }
            previous_node = record;
        }

        i = 0;
        var previous_exact: ?ExactTextKey = null;
        while (i < self.exact_header.node_count) : (i += 1) {
            const record = try self.exactTextAt(i);
            if (!validNodeId(record.id)) return error.InvalidRecord;
            const key = try self.exactTextKey(record);
            if (previous_exact) |previous| {
                if (compareExactTextRecordKeys(previous, key) != .lt) return error.InvalidRecord;
            }
            previous_exact = key;
        }
    }

    fn lowerBoundExactText(self: *const MappedCatalog, kind: core.NodeKind, text: []const u8) !u64 {
        var low: u64 = 0;
        var high = self.exact_header.node_count;
        while (low < high) {
            const mid = low + (high - low) / 2;
            const entry = try self.exactTextAt(mid);
            const key = try self.exactTextKey(entry);
            if (compareExactTextKey(key.kind, key.text, kind, text) == .lt) {
                low = mid + 1;
            } else {
                high = mid;
            }
        }
        return low;
    }

    fn lowerBoundNodeId(self: *const MappedCatalog, id: core.NodeId) !u64 {
        if (nodeByIdHeaderUsesDenseIds(self.nodes_header)) {
            const target = id.toInt();
            const base = self.nodes_header.id_base;
            if (target < base) return 0;
            const index = target - base;
            if (index >= self.nodes_header.node_count) return self.nodes_header.node_count;
            return index;
        }
        var low: u64 = 0;
        var high = self.nodes_header.node_count;
        const target = id.toInt();
        while (low < high) {
            const mid = low + (high - low) / 2;
            const entry = try self.nodeByIdAt(mid);
            if (entry.id.toInt() < target) {
                low = mid + 1;
            } else {
                high = mid;
            }
        }
        return low;
    }

    fn nodeByIdAt(self: *const MappedCatalog, index: u64) !NodeByIdRecord {
        if (index >= self.nodes_header.node_count) return error.InvalidRecord;
        const offset = try recordOffset(index, self.nodes_header.record_len);
        const bytes = switch (self.nodes_header.record_len) {
            NodeByIdRecord.dense_uniform_kind_encoded_len => try self.nodes_by_id.bytesAt(NodeByIdRecord.dense_uniform_kind_encoded_len, offset),
            NodeByIdRecord.dense_encoded_len => try self.nodes_by_id.bytesAt(NodeByIdRecord.dense_encoded_len, offset),
            NodeByIdRecord.sparse_uniform_kind_encoded_len => try self.nodes_by_id.bytesAt(NodeByIdRecord.sparse_uniform_kind_encoded_len, offset),
            NodeByIdRecord.sparse_encoded_len => try self.nodes_by_id.bytesAt(NodeByIdRecord.sparse_encoded_len, offset),
            else => return error.InvalidRecord,
        };
        return decodeNodeByIdRecord(bytes, self.nodes_header, index);
    }

    fn exactTextAt(self: *const MappedCatalog, index: u64) !ExactTextRecord {
        if (index >= self.exact_header.node_count) return error.InvalidRecord;
        const offset = try recordOffset(index, self.exact_header.record_len);
        const bytes = switch (self.exact_header.record_len) {
            ExactTextRecord.dense_ordinal_encoded_len => try self.exact_texts.bytesAt(ExactTextRecord.dense_ordinal_encoded_len, offset),
            ExactTextRecord.id_encoded_len => try self.exact_texts.bytesAt(ExactTextRecord.id_encoded_len, offset),
            else => return error.InvalidRecord,
        };
        return decodeExactTextRecord(bytes, self.exact_header);
    }

    fn exactTextKey(self: *const MappedCatalog, record: ExactTextRecord) !ExactTextKey {
        const index_pos = try self.lowerBoundNodeId(record.id);
        if (index_pos >= self.nodes_header.node_count) return error.InvalidRecord;
        const node = try self.nodeByIdAt(index_pos);
        if (node.id != record.id) return error.InvalidRecord;
        return .{
            .id = record.id,
            .kind = node.kind,
            .text = try self.textSlice(node.text_offset, node.text_len),
        };
    }

    fn textSlice(self: *const MappedCatalog, offset: u64, len: u32) ![]const u8 {
        return nameBytesSlice(self.texts.bytes(), offset, len);
    }
};

pub fn openTrustedFromManifestEntry(
    allocator: std.mem.Allocator,
    io: std.Io,
    segment_root_dir: []const u8,
    entry: segment_manifest.Entry,
) !MappedCatalog {
    if (entry.kind != .node) return error.InvalidRecord;
    if (!segment_manifest.safeRelativePath(entry.path)) return error.InvalidRecord;
    const summary = entry.node_catalog_summary orelse return error.InvalidRecord;
    try summary.validate();
    if (entry.node_count != summary.node_count) return error.InvalidRecord;
    if (summary.node_id_base != 0 and summary.node_id_base != entry.node_range.min) return error.InvalidRecord;

    const dir_path = try std.fs.path.join(allocator, &.{ segment_root_dir, entry.path });
    defer allocator.free(dir_path);
    return try MappedCatalog.openTrusted(io, dir_path, summary);
}

const MappedFileView = struct {
    io: std.Io,
    file: std.Io.File,
    map: ?std.Io.File.MemoryMap,

    fn open(io: std.Io, path: []const u8, max_size: u64) !MappedFileView {
        var file = try std.Io.Dir.cwd().openFile(io, path, .{ .allow_directory = false });
        errdefer file.close(io);
        const stat = try file.stat(io);
        if (stat.kind != .file) return error.InvalidRecord;
        if (stat.size > max_size) return error.RecordTooLarge;
        const len = std.math.cast(usize, stat.size) orelse return error.RecordTooLarge;
        const map = if (len == 0) null else try std.Io.File.MemoryMap.create(io, file, .{
            .len = len,
            .protection = .{ .read = true, .write = false },
            .populate = false,
        });
        return .{
            .io = io,
            .file = file,
            .map = map,
        };
    }

    fn deinit(self: *MappedFileView) void {
        if (self.map) |*map| map.destroy(self.io);
        self.file.close(self.io);
    }

    fn bytes(self: *const MappedFileView) []const u8 {
        const map = self.map orelse return &.{};
        return map.memory;
    }

    fn bytesAt(self: *const MappedFileView, comptime len: usize, offset: u64) ![]const u8 {
        const end = std.math.add(u64, offset, len) catch return error.InvalidRecord;
        const mapped = self.bytes();
        if (end > mapped.len) return error.InvalidRecord;
        const start = std.math.cast(usize, offset) orelse return error.RecordTooLarge;
        return mapped[start .. start + len];
    }
};

const BuildRecord = struct {
    id: core.NodeId,
    kind: core.NodeKind,
    text: []const u8,
    text_offset: u64,
};

pub const CatalogRecord = struct {
    id: core.NodeId,
    kind: core.NodeKind,
    text_offset: u64,
    text_len: u32,
};

pub const CatalogStreamInfo = struct {
    range: segment_manifest.IdRange,
    summary: CatalogSummary,
};

const TextStreamInfo = struct {
    bytes: u64,
    digest: u64,
};

const NodeByIdStreamInfo = struct {
    range: segment_manifest.IdRange,
    id_base: u64,
    record_digest: u64,
};

const NodeByIdPhysicalLayout = struct {
    dense: bool,
    uniform_kind: ?core.NodeKind,
    id_base: u64,
    range_min: u64,

    fn recordLen(self: NodeByIdPhysicalLayout) u16 {
        if (self.uniform_kind != null) {
            return if (self.dense) NodeByIdRecord.dense_uniform_kind_encoded_len else NodeByIdRecord.sparse_uniform_kind_encoded_len;
        }
        return if (self.dense) NodeByIdRecord.dense_encoded_len else NodeByIdRecord.sparse_encoded_len;
    }
};

const SliceBytesStream = struct {
    bytes: []const u8,
    emitted: bool = false,

    fn reset(self: *SliceBytesStream) !void {
        self.emitted = false;
    }

    fn next(self: *SliceBytesStream) !?[]const u8 {
        if (self.emitted) return null;
        self.emitted = true;
        return self.bytes;
    }
};

const IndexHeader = struct {
    const version: u16 = 7;
    const encoded_len: usize = 56;
    const flag_uniform_kind: u16 = 1;

    magic: [4]u8,
    record_len: u16,
    flags: u16 = 0,
    uniform_kind: ?core.NodeKind = null,
    node_count: u64,
    texts_bytes: u64,
    record_digest: u64,
    texts_digest: u64,
    id_base: u64 = 0,
};

const NodeByIdRecord = struct {
    const magic = [_]u8{ 'T', 'K', 'N', 'I' };
    const dense_uniform_kind_encoded_len: usize = 6;
    const dense_encoded_len: usize = 8;
    const sparse_uniform_kind_encoded_len: usize = 14;
    const sparse_encoded_len: usize = 16;
    const logical_encoded_len: usize = 24;

    id: core.NodeId,
    kind: core.NodeKind,
    text_offset: u64,
    text_len: u32,
};

const ExactTextRecord = struct {
    const magic = [_]u8{ 'T', 'K', 'N', 'E' };
    const dense_ordinal_encoded_len: usize = 4;
    const id_encoded_len: usize = 8;
    const logical_encoded_len: usize = id_encoded_len;

    id: core.NodeId,
};

const ExactTextKey = struct {
    id: core.NodeId,
    kind: core.NodeKind,
    text: []const u8,
};

pub fn writeCatalog(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir_path: []const u8,
    nodes: []const segment_executor.NodeInfoEntry,
) !void {
    if (nodes.len > max_nodes) return error.RecordTooLarge;
    try std.Io.Dir.cwd().createDirPath(io, dir_path);

    var build = std.ArrayList(BuildRecord).empty;
    defer build.deinit(allocator);
    try build.ensureTotalCapacity(allocator, nodes.len);

    var texts = std.ArrayList(u8).empty;
    defer texts.deinit(allocator);
    for (nodes) |node| {
        try validateNode(node);
        const offset: u64 = @intCast(texts.items.len);
        try texts.appendSlice(allocator, node.text);
        build.appendAssumeCapacity(.{
            .id = node.id,
            .kind = node.kind,
            .text = node.text,
            .text_offset = offset,
        });
    }

    const texts_path = try std.fs.path.join(allocator, &.{ dir_path, texts_leaf });
    defer allocator.free(texts_path);
    try writeFileSynced(allocator, io, texts_path, texts.items);

    const texts_digest = std.hash.Wyhash.hash(0x544B_4E53, texts.items);
    const node_id_base = try writeNodesById(allocator, io, dir_path, build.items, texts.items.len, texts_digest);
    try writeExactTexts(allocator, io, dir_path, build.items, texts.items.len, texts_digest, node_id_base);
}

pub fn writeCatalogFromOrderedStreams(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir_path: []const u8,
    texts: []const u8,
    node_count: u64,
    nodes_context: anytype,
    comptime nodes_reset: fn (@TypeOf(nodes_context)) anyerror!void,
    comptime nodes_next: fn (@TypeOf(nodes_context)) anyerror!?CatalogRecord,
    exact_context: anytype,
    comptime exact_reset: fn (@TypeOf(exact_context)) anyerror!void,
    comptime exact_next: fn (@TypeOf(exact_context)) anyerror!?CatalogRecord,
) !CatalogStreamInfo {
    if (node_count == 0 or node_count > max_nodes) return error.RecordTooLarge;
    if (texts.len == 0 or texts.len > max_texts_file_bytes) return error.RecordTooLarge;
    var texts_stream = SliceBytesStream{ .bytes = texts };
    return try writeCatalogFromStreamedTextsAndOrderedRecords(
        allocator,
        io,
        dir_path,
        node_count,
        &texts_stream,
        SliceBytesStream.reset,
        SliceBytesStream.next,
        nodes_context,
        nodes_reset,
        nodes_next,
        exact_context,
        exact_reset,
        exact_next,
    );
}

pub fn writeCatalogFromStreamedTextsAndOrderedRecords(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir_path: []const u8,
    node_count: u64,
    texts_context: anytype,
    comptime texts_reset: fn (@TypeOf(texts_context)) anyerror!void,
    comptime texts_next: fn (@TypeOf(texts_context)) anyerror!?[]const u8,
    nodes_context: anytype,
    comptime nodes_reset: fn (@TypeOf(nodes_context)) anyerror!void,
    comptime nodes_next: fn (@TypeOf(nodes_context)) anyerror!?CatalogRecord,
    exact_context: anytype,
    comptime exact_reset: fn (@TypeOf(exact_context)) anyerror!void,
    comptime exact_next: fn (@TypeOf(exact_context)) anyerror!?CatalogRecord,
) !CatalogStreamInfo {
    if (node_count == 0 or node_count > max_nodes) return error.RecordTooLarge;
    try std.Io.Dir.cwd().createDirPath(io, dir_path);

    const texts_path = try std.fs.path.join(allocator, &.{ dir_path, texts_leaf });
    defer allocator.free(texts_path);
    const texts_info = try writeTextsFromStream(
        allocator,
        io,
        texts_path,
        texts_context,
        texts_reset,
        texts_next,
    );

    const nodes_info = try writeNodesByIdOrderedStream(
        allocator,
        io,
        dir_path,
        texts_path,
        texts_info.bytes,
        texts_info.digest,
        node_count,
        nodes_context,
        nodes_reset,
        nodes_next,
    );
    const exact_record_digest = try writeExactTextsOrderedStream(
        allocator,
        io,
        dir_path,
        texts_path,
        texts_info.bytes,
        texts_info.digest,
        node_count,
        nodes_info.id_base,
        exact_context,
        exact_reset,
        exact_next,
    );
    return .{
        .range = nodes_info.range,
        .summary = .{
            .node_count = node_count,
            .node_id_base = nodes_info.id_base,
            .texts_bytes = texts_info.bytes,
            .texts_digest = texts_info.digest,
            .nodes_record_digest = nodes_info.record_digest,
            .exact_record_digest = exact_record_digest,
        },
    };
}

pub fn openCatalog(allocator: std.mem.Allocator, io: std.Io, dir_path: []const u8) !OwnedCatalog {
    const texts_path = try std.fs.path.join(allocator, &.{ dir_path, texts_leaf });
    defer allocator.free(texts_path);
    const texts = try readRegularFile(allocator, io, texts_path, max_texts_file_bytes);
    errdefer allocator.free(texts);
    const texts_digest = std.hash.Wyhash.hash(0x544B_4E53, texts);

    const nodes_path = try std.fs.path.join(allocator, &.{ dir_path, nodes_by_id_leaf });
    defer allocator.free(nodes_path);
    const exact_path = try std.fs.path.join(allocator, &.{ dir_path, exact_texts_leaf });
    defer allocator.free(exact_path);

    const nodes_by_id = try readNodesById(allocator, io, nodes_path, texts, texts_digest);
    errdefer allocator.free(nodes_by_id);
    const exact_texts = try readExactTexts(allocator, io, exact_path, texts, texts_digest, nodes_by_id);
    errdefer allocator.free(exact_texts);

    const catalog = segment_executor.SegmentNodeCatalog{
        .exact_texts = exact_texts,
        .nodes_by_id = nodes_by_id,
        .validated = true,
    };
    try catalog.validate();
    try validateCatalogCrossLinks(catalog);
    if (exact_texts.len != nodes_by_id.len) return error.InvalidRecord;
    return .{
        .texts = texts,
        .exact_texts = exact_texts,
        .nodes_by_id = nodes_by_id,
    };
}

fn writeTextsFromStream(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    context: anytype,
    comptime reset: fn (@TypeOf(context)) anyerror!void,
    comptime next: fn (@TypeOf(context)) anyerror!?[]const u8,
) !TextStreamInfo {
    const tmp_path = try tmpPath(allocator, path);
    defer allocator.free(tmp_path);
    errdefer std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};

    var file = try std.Io.Dir.cwd().createFile(io, tmp_path, .{ .read = true, .truncate = true });
    defer file.close(io);

    try reset(context);
    var digest = std.hash.Wyhash.init(0x544B_4E53);
    var offset: u64 = 0;
    while (true) {
        const chunk = (try next(context)) orelse break;
        if (chunk.len == 0) return error.InvalidRecord;
        if (std.mem.indexOfScalar(u8, chunk, 0) != null) return error.InvalidRecord;
        const next_offset = std.math.add(u64, offset, chunk.len) catch return error.RecordTooLarge;
        if (next_offset > max_texts_file_bytes) return error.RecordTooLarge;
        digest.update(chunk);
        try file.writePositionalAll(io, chunk, offset);
        offset = next_offset;
    }
    if (offset == 0) return error.RecordTooLarge;

    try file.sync(io);
    try renameReplace(io, tmp_path, path);
    return .{
        .bytes = offset,
        .digest = digest.final(),
    };
}

fn analyzeNodeByIdOrderedStream(
    io: std.Io,
    texts_file: std.Io.File,
    texts_bytes: u64,
    node_count: u64,
    context: anytype,
    comptime reset: fn (@TypeOf(context)) anyerror!void,
    comptime next: fn (@TypeOf(context)) anyerror!?CatalogRecord,
) !NodeByIdPhysicalLayout {
    try reset(context);
    var previous: ?CatalogRecord = null;
    var id_base: u64 = 0;
    var dense = true;
    var uniform_kind: ?core.NodeKind = null;
    var text_buf: [max_text_bytes]u8 = undefined;
    var written: u64 = 0;
    while (written < node_count) : (written += 1) {
        const record = (try next(context)) orelse return error.InvalidRecord;
        _ = try readCatalogRecordText(record, texts_file, io, texts_bytes, &text_buf);
        const record_id = record.id.toInt();
        if (!validNodeId(record.id)) return error.InvalidRecord;
        if (written == 0) {
            id_base = record_id;
        } else if (previous) |prev| {
            if (prev.id.toInt() >= record_id) return error.InvalidRecord;
        }
        if (std.math.add(u64, id_base, written) catch std.math.maxInt(u64) != record_id) dense = false;
        if (written == 0) {
            uniform_kind = record.kind;
        } else if (uniform_kind) |kind| {
            if (kind != record.kind) uniform_kind = null;
        }
        previous = record;
    }
    if ((try next(context)) != null) return error.InvalidRecord;
    return .{ .dense = dense, .uniform_kind = uniform_kind, .id_base = if (dense) id_base else 0, .range_min = id_base };
}

fn nodeByIdLayoutFromBuildRecords(records: []const BuildRecord) NodeByIdPhysicalLayout {
    if (records.len == 0) return .{ .dense = false, .uniform_kind = null, .id_base = 0, .range_min = 0 };
    const id_base = records[0].id.toInt();
    var dense = true;
    var uniform_kind: ?core.NodeKind = records[0].kind;
    for (records, 0..) |record, index| {
        if (std.math.add(u64, id_base, @intCast(index)) catch std.math.maxInt(u64) != record.id.toInt()) {
            dense = false;
        }
        if (uniform_kind) |kind| {
            if (kind != record.kind) uniform_kind = null;
        }
    }
    return .{ .dense = dense, .uniform_kind = uniform_kind, .id_base = if (dense) id_base else 0, .range_min = id_base };
}

fn writeNodesByIdOrderedStream(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir_path: []const u8,
    texts_path: []const u8,
    texts_bytes: u64,
    texts_digest: u64,
    node_count: u64,
    context: anytype,
    comptime reset: fn (@TypeOf(context)) anyerror!void,
    comptime next: fn (@TypeOf(context)) anyerror!?CatalogRecord,
) !NodeByIdStreamInfo {
    var texts_file = try std.Io.Dir.cwd().openFile(io, texts_path, .{});
    defer texts_file.close(io);

    const layout = try analyzeNodeByIdOrderedStream(
        io,
        texts_file,
        texts_bytes,
        node_count,
        context,
        reset,
        next,
    );

    const path = try std.fs.path.join(allocator, &.{ dir_path, nodes_by_id_leaf });
    defer allocator.free(path);
    const tmp_path = try tmpPath(allocator, path);
    defer allocator.free(tmp_path);
    errdefer std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};

    var file = try std.Io.Dir.cwd().createFile(io, tmp_path, .{ .read = true, .truncate = true });
    defer file.close(io);
    var offset: u64 = IndexHeader.encoded_len;
    try file.writePositionalAll(io, &([_]u8{0} ** IndexHeader.encoded_len), 0);

    try reset(context);
    var digest = std.hash.Wyhash.init(0x544B_4E49);
    var logical_bytes: [NodeByIdRecord.logical_encoded_len]u8 = undefined;
    var sparse_uniform_kind_bytes: [NodeByIdRecord.sparse_uniform_kind_encoded_len]u8 = undefined;
    var sparse_bytes: [NodeByIdRecord.sparse_encoded_len]u8 = undefined;
    var dense_uniform_kind_bytes: [NodeByIdRecord.dense_uniform_kind_encoded_len]u8 = undefined;
    var dense_bytes: [NodeByIdRecord.dense_encoded_len]u8 = undefined;
    var previous: ?CatalogRecord = null;
    var last_id: u64 = 0;
    var text_buf: [max_text_bytes]u8 = undefined;
    var written: u64 = 0;
    while (written < node_count) : (written += 1) {
        const record = (try next(context)) orelse return error.InvalidRecord;
        _ = try readCatalogRecordText(record, texts_file, io, texts_bytes, &text_buf);
        const record_id = record.id.toInt();
        last_id = record_id;
        if (previous) |prev| {
            if (prev.id.toInt() >= record_id) return error.InvalidRecord;
        }
        previous = record;
        const logical_record = NodeByIdRecord{
            .id = record.id,
            .kind = record.kind,
            .text_offset = record.text_offset,
            .text_len = record.text_len,
        };
        if (layout.uniform_kind) |kind| {
            if (logical_record.kind != kind) return error.InvalidRecord;
        }
        encodeNodeByIdLogicalRecord(logical_record, &logical_bytes);
        digest.update(&logical_bytes);
        const written_bytes = node_by_id_bytes: {
            if (layout.uniform_kind != null) {
                if (layout.dense) {
                    try encodeDenseUniformKindNodeByIdRecord(logical_record, &dense_uniform_kind_bytes);
                    break :node_by_id_bytes dense_uniform_kind_bytes[0..];
                }
                try encodeSparseUniformKindNodeByIdRecord(logical_record, &sparse_uniform_kind_bytes);
                break :node_by_id_bytes sparse_uniform_kind_bytes[0..];
            }
            if (layout.dense) {
                try encodeDenseNodeByIdRecord(logical_record, &dense_bytes);
                break :node_by_id_bytes dense_bytes[0..];
            }
            try encodeSparseNodeByIdRecord(logical_record, &sparse_bytes);
            break :node_by_id_bytes sparse_bytes[0..];
        };
        try file.writePositionalAll(io, written_bytes, offset);
        offset = try std.math.add(u64, offset, written_bytes.len);
    }
    if ((try next(context)) != null) return error.InvalidRecord;

    const record_digest = digest.final();
    var header_bytes: [IndexHeader.encoded_len]u8 = undefined;
    encodeIndexHeader(.{
        .magic = NodeByIdRecord.magic,
        .record_len = layout.recordLen(),
        .node_count = node_count,
        .texts_bytes = texts_bytes,
        .record_digest = record_digest,
        .texts_digest = texts_digest,
        .id_base = layout.id_base,
        .uniform_kind = layout.uniform_kind,
    }, &header_bytes);
    try file.writePositionalAll(io, &header_bytes, 0);
    try file.sync(io);
    try renameReplace(io, tmp_path, path);
    return .{
        .range = .{ .min = layout.range_min, .max = last_id },
        .id_base = layout.id_base,
        .record_digest = record_digest,
    };
}

fn writeExactTextsOrderedStream(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir_path: []const u8,
    texts_path: []const u8,
    texts_bytes: u64,
    texts_digest: u64,
    node_count: u64,
    node_id_base: u64,
    context: anytype,
    comptime reset: fn (@TypeOf(context)) anyerror!void,
    comptime next: fn (@TypeOf(context)) anyerror!?CatalogRecord,
) !u64 {
    var texts_file = try std.Io.Dir.cwd().openFile(io, texts_path, .{});
    defer texts_file.close(io);

    const path = try std.fs.path.join(allocator, &.{ dir_path, exact_texts_leaf });
    defer allocator.free(path);
    const tmp_path = try tmpPath(allocator, path);
    defer allocator.free(tmp_path);
    errdefer std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};

    var id_runs = try CatalogIdRunBuilder.init(allocator, io, path);
    defer id_runs.deinit();

    var file = try std.Io.Dir.cwd().createFile(io, tmp_path, .{ .read = true, .truncate = true });
    defer file.close(io);
    var offset: u64 = IndexHeader.encoded_len;
    try file.writePositionalAll(io, &([_]u8{0} ** IndexHeader.encoded_len), 0);

    try reset(context);
    var digest = std.hash.Wyhash.init(0x544B_4E45);
    const record_len = exactTextRecordLen(node_id_base);
    var logical_bytes: [ExactTextRecord.logical_encoded_len]u8 = undefined;
    var ordinal_bytes: [ExactTextRecord.dense_ordinal_encoded_len]u8 = undefined;
    var id_bytes: [ExactTextRecord.id_encoded_len]u8 = undefined;
    var previous: ?CatalogRecord = null;
    var text_buf: [max_text_bytes]u8 = undefined;
    var previous_text_buf: [max_text_bytes]u8 = undefined;
    var written: u64 = 0;
    while (written < node_count) : (written += 1) {
        const record = (try next(context)) orelse return error.InvalidRecord;
        const text = try readCatalogRecordText(record, texts_file, io, texts_bytes, &text_buf);
        if (previous) |prev| {
            const previous_text = try readCatalogRecordText(prev, texts_file, io, texts_bytes, &previous_text_buf);
            if (compareCatalogRecordsByExactText(prev, previous_text, record, text) != .lt) return error.InvalidRecord;
        }
        previous = record;
        try id_runs.append(.{
            .id = record.id,
            .kind = record.kind,
            .text_offset = record.text_offset,
            .text_len = record.text_len,
        });
        const exact_record = ExactTextRecord{ .id = record.id };
        encodeExactTextLogicalRecord(exact_record, &logical_bytes);
        digest.update(&logical_bytes);
        const written_bytes = if (record_len == ExactTextRecord.dense_ordinal_encoded_len) dense: {
            try encodeDenseOrdinalExactTextRecord(exact_record, node_id_base, &ordinal_bytes);
            break :dense ordinal_bytes[0..];
        } else full: {
            encodeExactTextLogicalRecord(exact_record, &id_bytes);
            break :full id_bytes[0..];
        };
        try file.writePositionalAll(io, written_bytes, offset);
        offset = try std.math.add(u64, offset, record_len);
    }
    if ((try next(context)) != null) return error.InvalidRecord;
    try id_runs.finish();

    const nodes_path = try std.fs.path.join(allocator, &.{ dir_path, nodes_by_id_leaf });
    defer allocator.free(nodes_path);
    if (id_runs.run_paths.items.len == 0) {
        try validateExactIdRecordsAgainstNodeIndex(allocator, io, nodes_path, node_count, id_runs.chunk.items);
    } else {
        try validateExactIdRunsAgainstNodeIndex(allocator, io, nodes_path, node_count, id_runs.run_paths.items);
    }

    const record_digest = digest.final();
    var header_bytes: [IndexHeader.encoded_len]u8 = undefined;
    encodeIndexHeader(.{
        .magic = ExactTextRecord.magic,
        .record_len = record_len,
        .node_count = node_count,
        .texts_bytes = texts_bytes,
        .record_digest = record_digest,
        .texts_digest = texts_digest,
        .id_base = if (record_len == ExactTextRecord.dense_ordinal_encoded_len) node_id_base else 0,
    }, &header_bytes);
    try file.writePositionalAll(io, &header_bytes, 0);
    try file.sync(io);
    try renameReplace(io, tmp_path, path);
    return record_digest;
}

const CatalogIdRunBuilder = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    base_path: []const u8,
    run_paths: std.ArrayList([]u8) = .empty,
    chunk: std.ArrayList(NodeByIdRecord) = .empty,

    fn init(allocator: std.mem.Allocator, io: std.Io, base_path: []const u8) !CatalogIdRunBuilder {
        var builder = CatalogIdRunBuilder{
            .allocator = allocator,
            .io = io,
            .base_path = base_path,
        };
        errdefer builder.deinit();
        try builder.chunk.ensureTotalCapacityPrecise(allocator, catalog_id_run_chunk_records);
        return builder;
    }

    fn deinit(self: *CatalogIdRunBuilder) void {
        for (self.run_paths.items) |run_path| {
            std.Io.Dir.cwd().deleteFile(self.io, run_path) catch {};
            self.allocator.free(run_path);
        }
        self.run_paths.deinit(self.allocator);
        self.chunk.deinit(self.allocator);
    }

    fn append(self: *CatalogIdRunBuilder, record: NodeByIdRecord) !void {
        if (self.chunk.items.len == catalog_id_run_chunk_records) try self.flushRun();
        self.chunk.appendAssumeCapacity(record);
    }

    fn finish(self: *CatalogIdRunBuilder) !void {
        if (self.run_paths.items.len == 0) {
            try self.sortChunk();
            return;
        }
        try self.flushRun();
    }

    fn flushRun(self: *CatalogIdRunBuilder) !void {
        if (self.chunk.items.len == 0) return;
        const run_path = try std.fmt.allocPrint(self.allocator, "{s}.id_run.{d}.tmp", .{ self.base_path, self.run_paths.items.len });
        var run_path_owned = true;
        errdefer {
            std.Io.Dir.cwd().deleteFile(self.io, run_path) catch {};
            if (run_path_owned) self.allocator.free(run_path);
        }

        try self.sortChunk();
        try writeCatalogIdRun(self.allocator, self.io, run_path, self.chunk.items);
        try self.run_paths.append(self.allocator, run_path);
        run_path_owned = false;
        self.chunk.clearRetainingCapacity();
    }

    fn sortChunk(self: *CatalogIdRunBuilder) !void {
        std.mem.sort(NodeByIdRecord, self.chunk.items, {}, catalogIdRunRecordLessThan);
        for (self.chunk.items[1..], self.chunk.items[0 .. self.chunk.items.len - 1]) |record, previous| {
            if (record.id.toInt() == previous.id.toInt()) return error.InvalidRecord;
        }
    }
};

fn catalogIdRunRecordLessThan(_: void, left: NodeByIdRecord, right: NodeByIdRecord) bool {
    return left.id.toInt() < right.id.toInt();
}

fn writeCatalogIdRun(allocator: std.mem.Allocator, io: std.Io, path: []const u8, records: []const NodeByIdRecord) !void {
    const expected_size = std.math.mul(u64, records.len, NodeByIdRecord.sparse_encoded_len) catch return error.RecordTooLarge;
    var file = try std.Io.Dir.cwd().createFile(io, path, .{ .read = true, .truncate = true });
    defer file.close(io);
    var writer = try CatalogBufferedWriter.init(allocator, io, file, try catalogIdRunWriteBufferCapacity(expected_size));
    defer writer.deinit();
    var bytes: [NodeByIdRecord.sparse_encoded_len]u8 = undefined;
    for (records) |record| {
        try encodeSparseNodeByIdRecord(record, &bytes);
        try writer.append(&bytes);
    }
    try writer.flush();
    try file.sync(io);
    const stat = try file.stat(io);
    if (stat.kind != .file or stat.size != expected_size) return error.InvalidRecord;
}

const CatalogBufferedWriter = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    file: std.Io.File,
    buffer: []u8,
    len: usize = 0,
    offset: u64 = 0,

    fn init(allocator: std.mem.Allocator, io: std.Io, file: std.Io.File, capacity: usize) !CatalogBufferedWriter {
        std.debug.assert(capacity > 0);
        return .{
            .allocator = allocator,
            .io = io,
            .file = file,
            .buffer = try allocator.alloc(u8, capacity),
        };
    }

    fn deinit(self: *CatalogBufferedWriter) void {
        self.allocator.free(self.buffer);
    }

    fn append(self: *CatalogBufferedWriter, bytes: []const u8) !void {
        if (bytes.len > self.buffer.len) {
            try self.flush();
            try self.file.writePositionalAll(self.io, bytes, self.offset);
            self.offset = std.math.add(u64, self.offset, bytes.len) catch return error.RecordTooLarge;
            return;
        }
        if (self.len + bytes.len > self.buffer.len) try self.flush();
        @memcpy(self.buffer[self.len .. self.len + bytes.len], bytes);
        self.len += bytes.len;
    }

    fn flush(self: *CatalogBufferedWriter) !void {
        if (self.len == 0) return;
        try self.file.writePositionalAll(self.io, self.buffer[0..self.len], self.offset);
        self.offset = std.math.add(u64, self.offset, self.len) catch return error.RecordTooLarge;
        self.len = 0;
    }
};

fn catalogIdRunWriteBufferCapacity(file_size: u64) !usize {
    const size = std.math.cast(usize, file_size) orelse return error.RecordTooLarge;
    return @max(NodeByIdRecord.sparse_encoded_len, @min(catalog_id_run_read_buffer_bytes, size));
}

fn catalogIdRunReadBufferCapacity(file_size: u64) !usize {
    const size = std.math.cast(usize, file_size) orelse return error.RecordTooLarge;
    return @max(NodeByIdRecord.sparse_encoded_len, @min(catalog_id_run_read_buffer_bytes, size));
}

const CatalogIdRunReader = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    file: std.Io.File,
    buffer: []u8,
    cursor: usize = 0,
    len: usize = 0,
    file_offset: u64,
    next_index: u64 = 0,
    count: u64,

    fn init(allocator: std.mem.Allocator, io: std.Io, file: std.Io.File, count: u64, file_size: u64) !CatalogIdRunReader {
        return initAtOffset(allocator, io, file, count, file_size, 0);
    }

    fn initAtOffset(
        allocator: std.mem.Allocator,
        io: std.Io,
        file: std.Io.File,
        count: u64,
        file_size: u64,
        file_offset: u64,
    ) !CatalogIdRunReader {
        std.debug.assert(count != 0);
        if (file_offset > file_size) return error.InvalidRecord;
        return .{
            .allocator = allocator,
            .io = io,
            .file = file,
            .buffer = try allocator.alloc(u8, try catalogIdRunReadBufferCapacity(file_size - file_offset)),
            .file_offset = file_offset,
            .count = count,
        };
    }

    fn deinit(self: *CatalogIdRunReader) void {
        self.allocator.free(self.buffer);
        self.file.close(self.io);
    }

    fn refill(self: *CatalogIdRunReader) !void {
        const n = try self.file.readPositionalAll(self.io, self.buffer, self.file_offset);
        if (n == 0) return error.InvalidRecord;
        self.file_offset = std.math.add(u64, self.file_offset, n) catch return error.InvalidRecord;
        self.cursor = 0;
        self.len = n;
    }

    fn readBytes(self: *CatalogIdRunReader, out: []u8) !void {
        var written: usize = 0;
        while (written < out.len) {
            if (self.cursor == self.len) try self.refill();
            const available = self.len - self.cursor;
            const n = @min(available, out.len - written);
            @memcpy(out[written .. written + n], self.buffer[self.cursor .. self.cursor + n]);
            self.cursor += n;
            written += n;
        }
    }

    fn nextRecord(self: *CatalogIdRunReader) !?NodeByIdRecord {
        if (self.next_index >= self.count) return null;
        if (self.cursor == self.len) try self.refill();
        const record = if (self.len - self.cursor >= NodeByIdRecord.sparse_encoded_len) record: {
            const bytes = self.buffer[self.cursor .. self.cursor + NodeByIdRecord.sparse_encoded_len];
            self.cursor += NodeByIdRecord.sparse_encoded_len;
            break :record try decodeSparseNodeByIdRecord(bytes);
        } else record: {
            var bytes: [NodeByIdRecord.sparse_encoded_len]u8 = undefined;
            try self.readBytes(&bytes);
            break :record try decodeSparseNodeByIdRecord(&bytes);
        };
        self.next_index += 1;
        return record;
    }
};

fn compareCatalogIdRunReaderIndex(records: []const NodeByIdRecord, lhs: usize, rhs: usize) std.math.Order {
    if (catalogIdRunRecordLessThan({}, records[lhs], records[rhs])) return .lt;
    if (catalogIdRunRecordLessThan({}, records[rhs], records[lhs])) return .gt;
    return std.math.order(lhs, rhs);
}

const CatalogIdRunMerger = struct {
    allocator: std.mem.Allocator,
    readers: std.ArrayList(CatalogIdRunReader),
    current_records: std.ArrayList(NodeByIdRecord),
    queue: std.PriorityQueue(usize, []const NodeByIdRecord, compareCatalogIdRunReaderIndex),

    fn init(allocator: std.mem.Allocator, io: std.Io, run_paths: []const []const u8) !CatalogIdRunMerger {
        var readers = std.ArrayList(CatalogIdRunReader).empty;
        errdefer {
            for (readers.items) |*reader| reader.deinit();
            readers.deinit(allocator);
        }
        try readers.ensureTotalCapacityPrecise(allocator, run_paths.len);

        var current_records = std.ArrayList(NodeByIdRecord).empty;
        errdefer current_records.deinit(allocator);
        try current_records.ensureTotalCapacityPrecise(allocator, run_paths.len);

        for (run_paths) |run_path| {
            var run_file = try std.Io.Dir.cwd().openFile(io, run_path, .{});
            var run_file_owned = true;
            errdefer if (run_file_owned) run_file.close(io);
            const stat = try run_file.stat(io);
            if (stat.kind != .file or stat.size % NodeByIdRecord.sparse_encoded_len != 0) return error.InvalidRecord;
            const count = stat.size / NodeByIdRecord.sparse_encoded_len;
            if (count == 0) {
                run_file.close(io);
                run_file_owned = false;
                continue;
            }
            const reader_index = readers.items.len;
            readers.appendAssumeCapacity(try CatalogIdRunReader.init(allocator, io, run_file, count, stat.size));
            run_file_owned = false;
            const record = (try readers.items[reader_index].nextRecord()) orelse return error.InvalidRecord;
            current_records.appendAssumeCapacity(record);
        }

        var queue = std.PriorityQueue(usize, []const NodeByIdRecord, compareCatalogIdRunReaderIndex).initContext(current_records.items);
        errdefer queue.deinit(allocator);
        try queue.ensureTotalCapacityPrecise(allocator, current_records.items.len);
        for (current_records.items, 0..) |_, reader_index| {
            try queue.push(allocator, reader_index);
        }

        return .{
            .allocator = allocator,
            .readers = readers,
            .current_records = current_records,
            .queue = queue,
        };
    }

    fn deinit(self: *CatalogIdRunMerger) void {
        self.queue.deinit(self.allocator);
        self.current_records.deinit(self.allocator);
        for (self.readers.items) |*reader| reader.deinit();
        self.readers.deinit(self.allocator);
    }

    fn next(self: *CatalogIdRunMerger) !?NodeByIdRecord {
        const reader_index = self.queue.pop() orelse return null;
        const record = self.current_records.items[reader_index];
        const reader = &self.readers.items[reader_index];
        if (try reader.nextRecord()) |next_record| {
            self.current_records.items[reader_index] = next_record;
            try self.queue.push(self.allocator, reader_index);
        }
        return record;
    }
};

fn validateExactIdRunsAgainstNodeIndex(
    allocator: std.mem.Allocator,
    io: std.Io,
    nodes_path: []const u8,
    node_count: u64,
    run_paths: []const []const u8,
) !void {
    var merger = try CatalogIdRunMerger.init(allocator, io, run_paths);
    defer merger.deinit();

    var nodes_file = try std.Io.Dir.cwd().openFile(io, nodes_path, .{});
    var nodes_file_owned = true;
    errdefer if (nodes_file_owned) nodes_file.close(io);
    const nodes_stat = try nodes_file.stat(io);
    if (nodes_stat.kind != .file or nodes_stat.size > max_index_file_bytes) return error.InvalidRecord;
    const nodes_size = std.math.cast(usize, nodes_stat.size) orelse return error.RecordTooLarge;
    const nodes_bytes = try allocator.alloc(u8, nodes_size);
    defer allocator.free(nodes_bytes);
    if (try nodes_file.readPositionalAll(io, nodes_bytes, 0) != nodes_bytes.len) return error.InvalidRecord;
    nodes_file.close(io);
    nodes_file_owned = false;
    const nodes_header = try decodeNodeByIdIndexHeaderWithCount(nodes_bytes, node_count);

    var previous_id: ?u64 = null;
    var index: u64 = 0;
    while (index < node_count) : (index += 1) {
        const exact_record = (try merger.next()) orelse return error.InvalidRecord;
        const node_record = try decodeNodeByIdRecordAt(nodes_bytes, nodes_header, index);
        const exact_id = exact_record.id.toInt();
        if (previous_id) |previous| {
            if (previous >= exact_id) return error.InvalidRecord;
        }
        previous_id = exact_id;
        if (exact_record.id != node_record.id or
            exact_record.kind != node_record.kind or
            exact_record.text_offset != node_record.text_offset or
            exact_record.text_len != node_record.text_len)
        {
            return error.InvalidRecord;
        }
    }
    if ((try merger.next()) != null) return error.InvalidRecord;
}

fn validateExactIdRecordsAgainstNodeIndex(
    allocator: std.mem.Allocator,
    io: std.Io,
    nodes_path: []const u8,
    node_count: u64,
    records_by_id: []const NodeByIdRecord,
) !void {
    if (records_by_id.len != node_count) return error.InvalidRecord;

    var nodes_file = try std.Io.Dir.cwd().openFile(io, nodes_path, .{});
    var nodes_file_owned = true;
    errdefer if (nodes_file_owned) nodes_file.close(io);
    const nodes_stat = try nodes_file.stat(io);
    if (nodes_stat.kind != .file or nodes_stat.size > max_index_file_bytes) return error.InvalidRecord;
    const nodes_size = std.math.cast(usize, nodes_stat.size) orelse return error.RecordTooLarge;
    const nodes_bytes = try allocator.alloc(u8, nodes_size);
    defer allocator.free(nodes_bytes);
    if (try nodes_file.readPositionalAll(io, nodes_bytes, 0) != nodes_bytes.len) return error.InvalidRecord;
    nodes_file.close(io);
    nodes_file_owned = false;
    const nodes_header = try decodeNodeByIdIndexHeaderWithCount(nodes_bytes, node_count);

    for (records_by_id, 0..) |exact_record, index| {
        if (index != 0 and records_by_id[index - 1].id.toInt() >= exact_record.id.toInt()) return error.InvalidRecord;
        const node_record = try decodeNodeByIdRecordAt(nodes_bytes, nodes_header, @intCast(index));
        if (exact_record.id != node_record.id or
            exact_record.kind != node_record.kind or
            exact_record.text_offset != node_record.text_offset or
            exact_record.text_len != node_record.text_len)
        {
            return error.InvalidRecord;
        }
    }
}

fn readCatalogRecordText(
    record: CatalogRecord,
    file: std.Io.File,
    io: std.Io,
    texts_bytes: u64,
    buffer: []u8,
) ![]const u8 {
    if (!validNodeId(record.id)) return core.Error.InvalidId;
    if (record.text_len == 0 or record.text_len > max_text_bytes) return error.InvalidRecord;
    if (record.text_len > buffer.len) return error.InvalidRecord;
    const end = std.math.add(u64, record.text_offset, record.text_len) catch return error.InvalidRecord;
    if (end > texts_bytes) return error.InvalidRecord;
    const text = buffer[0..record.text_len];
    if (try file.readPositionalAll(io, text, record.text_offset) != text.len) return error.InvalidRecord;
    if (std.mem.indexOfScalar(u8, text, 0) != null) return error.InvalidRecord;
    return text;
}

fn writeNodesById(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir_path: []const u8,
    build_records: []const BuildRecord,
    texts_bytes: usize,
    texts_digest: u64,
) !u64 {
    const records = try allocator.dupe(BuildRecord, build_records);
    defer allocator.free(records);
    std.mem.sort(BuildRecord, records, {}, buildRecordIdLessThan);
    try rejectDuplicateIds(records);

    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    try out.resize(allocator, IndexHeader.encoded_len);
    var digest = std.hash.Wyhash.init(0x544B_4E49);
    const layout = nodeByIdLayoutFromBuildRecords(records);
    var logical_bytes: [NodeByIdRecord.logical_encoded_len]u8 = undefined;
    var sparse_uniform_kind_bytes: [NodeByIdRecord.sparse_uniform_kind_encoded_len]u8 = undefined;
    var sparse_bytes: [NodeByIdRecord.sparse_encoded_len]u8 = undefined;
    var dense_uniform_kind_bytes: [NodeByIdRecord.dense_uniform_kind_encoded_len]u8 = undefined;
    var dense_bytes: [NodeByIdRecord.dense_encoded_len]u8 = undefined;
    for (records) |record| {
        const logical_record = NodeByIdRecord{
            .id = record.id,
            .kind = record.kind,
            .text_offset = record.text_offset,
            .text_len = @intCast(record.text.len),
        };
        if (layout.uniform_kind) |kind| {
            if (logical_record.kind != kind) return error.InvalidRecord;
        }
        encodeNodeByIdLogicalRecord(logical_record, &logical_bytes);
        digest.update(&logical_bytes);
        if (layout.uniform_kind != null) {
            if (layout.dense) {
                try encodeDenseUniformKindNodeByIdRecord(logical_record, &dense_uniform_kind_bytes);
                try out.appendSlice(allocator, &dense_uniform_kind_bytes);
            } else {
                try encodeSparseUniformKindNodeByIdRecord(logical_record, &sparse_uniform_kind_bytes);
                try out.appendSlice(allocator, &sparse_uniform_kind_bytes);
            }
        } else if (layout.dense) {
            try encodeDenseNodeByIdRecord(logical_record, &dense_bytes);
            try out.appendSlice(allocator, &dense_bytes);
        } else {
            try encodeSparseNodeByIdRecord(logical_record, &sparse_bytes);
            try out.appendSlice(allocator, &sparse_bytes);
        }
    }
    encodeIndexHeader(.{
        .magic = NodeByIdRecord.magic,
        .record_len = layout.recordLen(),
        .node_count = @intCast(records.len),
        .texts_bytes = @intCast(texts_bytes),
        .record_digest = digest.final(),
        .texts_digest = texts_digest,
        .id_base = layout.id_base,
        .uniform_kind = layout.uniform_kind,
    }, out.items[0..IndexHeader.encoded_len]);

    const path = try std.fs.path.join(allocator, &.{ dir_path, nodes_by_id_leaf });
    defer allocator.free(path);
    try writeFileSynced(allocator, io, path, out.items);
    return layout.id_base;
}

fn writeExactTexts(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir_path: []const u8,
    build_records: []const BuildRecord,
    texts_bytes: usize,
    texts_digest: u64,
    node_id_base: u64,
) !void {
    const records = try allocator.dupe(BuildRecord, build_records);
    defer allocator.free(records);
    std.mem.sort(BuildRecord, records, {}, buildRecordExactTextLessThan);

    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    try out.resize(allocator, IndexHeader.encoded_len);
    var digest = std.hash.Wyhash.init(0x544B_4E45);
    const record_len = exactTextRecordLen(node_id_base);
    var logical_bytes: [ExactTextRecord.logical_encoded_len]u8 = undefined;
    var ordinal_bytes: [ExactTextRecord.dense_ordinal_encoded_len]u8 = undefined;
    var id_bytes: [ExactTextRecord.id_encoded_len]u8 = undefined;
    for (records) |record| {
        const exact_record = ExactTextRecord{ .id = record.id };
        encodeExactTextLogicalRecord(exact_record, &logical_bytes);
        digest.update(&logical_bytes);
        if (record_len == ExactTextRecord.dense_ordinal_encoded_len) {
            try encodeDenseOrdinalExactTextRecord(exact_record, node_id_base, &ordinal_bytes);
            try out.appendSlice(allocator, &ordinal_bytes);
        } else {
            encodeExactTextLogicalRecord(exact_record, &id_bytes);
            try out.appendSlice(allocator, &id_bytes);
        }
    }
    encodeIndexHeader(.{
        .magic = ExactTextRecord.magic,
        .record_len = record_len,
        .node_count = @intCast(records.len),
        .texts_bytes = @intCast(texts_bytes),
        .record_digest = digest.final(),
        .texts_digest = texts_digest,
        .id_base = if (record_len == ExactTextRecord.dense_ordinal_encoded_len) node_id_base else 0,
    }, out.items[0..IndexHeader.encoded_len]);

    const path = try std.fs.path.join(allocator, &.{ dir_path, exact_texts_leaf });
    defer allocator.free(path);
    try writeFileSynced(allocator, io, path, out.items);
}

fn readNodesById(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    texts: []u8,
    texts_digest: u64,
) ![]segment_executor.NodeInfoEntry {
    const bytes = try readRegularFile(allocator, io, path, max_index_file_bytes);
    defer allocator.free(bytes);
    const header = try decodeNodeByIdIndexHeader(bytes, texts.len, texts_digest);
    const records = try allocator.alloc(segment_executor.NodeInfoEntry, @intCast(header.node_count));
    errdefer allocator.free(records);
    try validateNodeByIdRecordDigest(bytes, header);
    for (records, 0..) |*out, index| {
        const record = try decodeNodeByIdRecordAt(bytes, header, @intCast(index));
        out.* = .{
            .id = record.id,
            .kind = record.kind,
            .text = try nameBytesSlice(texts, record.text_offset, record.text_len),
        };
    }
    return records;
}

fn readExactTexts(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    texts: []u8,
    texts_digest: u64,
    nodes_by_id: []const segment_executor.NodeInfoEntry,
) ![]segment_executor.ExactTextEntry {
    const bytes = try readRegularFile(allocator, io, path, max_index_file_bytes);
    defer allocator.free(bytes);
    const header = try decodeIndexHeader(bytes, ExactTextRecord.magic, 0, texts.len, texts_digest);
    try validateExactTextHeaderFromEntries(header, nodes_by_id);
    const records = try allocator.alloc(segment_executor.ExactTextEntry, @intCast(header.node_count));
    errdefer allocator.free(records);
    var digest = std.hash.Wyhash.init(0x544B_4E45);
    var logical_bytes: [ExactTextRecord.logical_encoded_len]u8 = undefined;
    var offset: usize = IndexHeader.encoded_len;
    for (records) |*out| {
        const record_len: usize = header.record_len;
        const record_bytes = bytes[offset..][0..record_len];
        const record = try decodeExactTextRecord(record_bytes, header);
        encodeExactTextLogicalRecord(record, &logical_bytes);
        digest.update(&logical_bytes);
        const node = nodeInfoById(nodes_by_id, record.id) orelse return error.InvalidRecord;
        out.* = .{
            .kind = node.kind,
            .text = node.text,
            .id = record.id,
        };
        offset += record_len;
    }
    if (digest.final() != header.record_digest) return error.InvalidRecord;
    return records;
}

fn encodeIndexHeader(header: IndexHeader, out: []u8) void {
    @memcpy(out[0..4], &header.magic);
    std.mem.writeInt(u16, out[4..6], IndexHeader.version, .little);
    std.mem.writeInt(u16, out[6..8], IndexHeader.encoded_len, .little);
    std.mem.writeInt(u16, out[8..10], header.record_len, .little);
    const flags: u16 = if (header.uniform_kind != null) header.flags | IndexHeader.flag_uniform_kind else header.flags;
    std.mem.writeInt(u16, out[10..12], flags, .little);
    std.mem.writeInt(u16, out[12..14], if (header.uniform_kind) |kind| @intFromEnum(kind) else 0, .little);
    @memset(out[14..16], 0);
    std.mem.writeInt(u64, out[16..24], header.node_count, .little);
    std.mem.writeInt(u64, out[24..32], header.texts_bytes, .little);
    std.mem.writeInt(u64, out[32..40], header.record_digest, .little);
    std.mem.writeInt(u64, out[40..48], header.texts_digest, .little);
    std.mem.writeInt(u64, out[48..56], header.id_base, .little);
}

fn decodeIndexHeader(bytes: []const u8, magic: [4]u8, record_len: usize, texts_len: usize, texts_digest: u64) !IndexHeader {
    if (bytes.len < IndexHeader.encoded_len) return error.InvalidRecord;
    if (!std.mem.eql(u8, bytes[0..4], &magic)) return error.InvalidRecord;
    if (std.mem.readInt(u16, bytes[4..6], .little) != IndexHeader.version) return error.InvalidRecord;
    if (std.mem.readInt(u16, bytes[6..8], .little) != IndexHeader.encoded_len) return error.InvalidRecord;
    const physical_record_len = std.mem.readInt(u16, bytes[8..10], .little);
    if (record_len != 0 and physical_record_len != record_len) return error.InvalidRecord;
    const flags = std.mem.readInt(u16, bytes[10..12], .little);
    const uniform_kind_value = std.mem.readInt(u16, bytes[12..14], .little);
    if (flags & IndexHeader.flag_uniform_kind == 0 and uniform_kind_value != 0) return error.InvalidRecord;
    if (!allZero(bytes[14..16])) return error.InvalidRecord;
    const node_count = std.mem.readInt(u64, bytes[16..24], .little);
    if (node_count > max_nodes) return error.RecordTooLarge;
    const texts_bytes = std.mem.readInt(u64, bytes[24..32], .little);
    if (texts_bytes != texts_len) return error.InvalidRecord;
    const payload_size = std.math.mul(usize, @intCast(node_count), physical_record_len) catch return error.RecordTooLarge;
    const expected_size = std.math.add(usize, IndexHeader.encoded_len, payload_size) catch return error.RecordTooLarge;
    if (bytes.len != expected_size) return error.InvalidRecord;
    const header = IndexHeader{
        .magic = magic,
        .record_len = physical_record_len,
        .flags = flags,
        .uniform_kind = if (flags & IndexHeader.flag_uniform_kind != 0) kindFromInt(uniform_kind_value) orelse return error.InvalidRecord else null,
        .node_count = node_count,
        .texts_bytes = texts_bytes,
        .record_digest = std.mem.readInt(u64, bytes[32..40], .little),
        .texts_digest = std.mem.readInt(u64, bytes[40..48], .little),
        .id_base = std.mem.readInt(u64, bytes[48..56], .little),
    };
    if (header.texts_digest != texts_digest) return error.InvalidRecord;
    try validateIndexHeaderFlags(header);
    return header;
}

fn decodeNodeByIdIndexHeader(bytes: []const u8, texts_len: usize, texts_digest: u64) !IndexHeader {
    const header = try decodeIndexHeader(bytes, NodeByIdRecord.magic, 0, texts_len, texts_digest);
    try validateNodeByIdHeaderRecordLen(header.record_len);
    try validateNodeByIdHeaderLayout(header);
    try validateNodeByIdDenseRange(header);
    if (!nodeByIdHeaderUsesDenseIds(header) and header.id_base != 0) return error.InvalidRecord;
    return header;
}

fn decodeNodeByIdIndexHeaderWithCount(bytes: []const u8, node_count: u64) !IndexHeader {
    if (bytes.len < IndexHeader.encoded_len) return error.InvalidRecord;
    if (!std.mem.eql(u8, bytes[0..4], &NodeByIdRecord.magic)) return error.InvalidRecord;
    if (std.mem.readInt(u16, bytes[4..6], .little) != IndexHeader.version) return error.InvalidRecord;
    if (std.mem.readInt(u16, bytes[6..8], .little) != IndexHeader.encoded_len) return error.InvalidRecord;
    const record_len = std.mem.readInt(u16, bytes[8..10], .little);
    try validateNodeByIdHeaderRecordLen(record_len);
    const flags = std.mem.readInt(u16, bytes[10..12], .little);
    const uniform_kind_value = std.mem.readInt(u16, bytes[12..14], .little);
    if (flags & IndexHeader.flag_uniform_kind == 0 and uniform_kind_value != 0) return error.InvalidRecord;
    if (!allZero(bytes[14..16])) return error.InvalidRecord;
    const header = IndexHeader{
        .magic = NodeByIdRecord.magic,
        .record_len = record_len,
        .flags = flags,
        .uniform_kind = if (flags & IndexHeader.flag_uniform_kind != 0) kindFromInt(uniform_kind_value) orelse return error.InvalidRecord else null,
        .node_count = std.mem.readInt(u64, bytes[16..24], .little),
        .texts_bytes = std.mem.readInt(u64, bytes[24..32], .little),
        .record_digest = std.mem.readInt(u64, bytes[32..40], .little),
        .texts_digest = std.mem.readInt(u64, bytes[40..48], .little),
        .id_base = std.mem.readInt(u64, bytes[48..56], .little),
    };
    try validateIndexHeaderFlags(header);
    if (header.node_count != node_count) return error.InvalidRecord;
    try validateNodeByIdHeaderLayout(header);
    try validateNodeByIdDenseRange(header);
    if (!nodeByIdHeaderUsesDenseIds(header) and header.id_base != 0) return error.InvalidRecord;
    const payload_size = std.math.mul(usize, @intCast(header.node_count), header.record_len) catch return error.RecordTooLarge;
    const expected_size = std.math.add(usize, IndexHeader.encoded_len, payload_size) catch return error.RecordTooLarge;
    if (bytes.len != expected_size) return error.InvalidRecord;
    return header;
}

fn validateNodeByIdHeaderRecordLen(record_len: u16) !void {
    if (record_len != NodeByIdRecord.dense_uniform_kind_encoded_len and
        record_len != NodeByIdRecord.dense_encoded_len and
        record_len != NodeByIdRecord.sparse_uniform_kind_encoded_len and
        record_len != NodeByIdRecord.sparse_encoded_len)
    {
        return error.InvalidRecord;
    }
}

fn validateIndexHeaderFlags(header: IndexHeader) !void {
    const known_flags = IndexHeader.flag_uniform_kind;
    if (header.flags & ~known_flags != 0) return error.InvalidRecord;
    if (header.uniform_kind == null and header.flags != 0) return error.InvalidRecord;
    if (header.uniform_kind != null and header.flags != IndexHeader.flag_uniform_kind) return error.InvalidRecord;
    if (header.uniform_kind != null and !std.mem.eql(u8, &header.magic, &NodeByIdRecord.magic)) return error.InvalidRecord;
}

fn validateNodeByIdHeaderLayout(header: IndexHeader) !void {
    if (nodeByIdHeaderUsesUniformKind(header)) {
        if (header.record_len != NodeByIdRecord.dense_uniform_kind_encoded_len and
            header.record_len != NodeByIdRecord.sparse_uniform_kind_encoded_len)
        {
            return error.InvalidRecord;
        }
    } else if (header.record_len != NodeByIdRecord.dense_encoded_len and
        header.record_len != NodeByIdRecord.sparse_encoded_len)
    {
        return error.InvalidRecord;
    }
}

fn nodeByIdHeaderUsesDenseIds(header: IndexHeader) bool {
    return header.record_len == NodeByIdRecord.dense_uniform_kind_encoded_len or header.record_len == NodeByIdRecord.dense_encoded_len;
}

fn nodeByIdHeaderUsesUniformKind(header: IndexHeader) bool {
    return header.uniform_kind != null;
}

fn validateNodeByIdDenseRange(header: IndexHeader) !void {
    if (!nodeByIdHeaderUsesDenseIds(header)) return;
    if (header.node_count == 0) return error.InvalidRecord;
    if (!validNodeId(core.NodeId.fromInt(header.id_base))) return error.InvalidRecord;
    const last_offset = header.node_count - 1;
    const last_id = std.math.add(u64, header.id_base, last_offset) catch return error.InvalidRecord;
    if (!validNodeId(core.NodeId.fromInt(last_id))) return error.InvalidRecord;
}

fn validateExactTextHeader(header: IndexHeader, nodes_header: IndexHeader) !void {
    if (header.record_len != ExactTextRecord.dense_ordinal_encoded_len and header.record_len != ExactTextRecord.id_encoded_len) return error.InvalidRecord;
    if (exactTextHeaderUsesDenseOrdinals(header)) {
        if (!nodeByIdHeaderUsesDenseIds(nodes_header)) return error.InvalidRecord;
        if (header.id_base != nodes_header.id_base) return error.InvalidRecord;
        if (!validNodeId(core.NodeId.fromInt(header.id_base))) return error.InvalidRecord;
    } else if (header.id_base != 0) {
        return error.InvalidRecord;
    }
}

fn validateExactTextHeaderFromEntries(header: IndexHeader, nodes_by_id: []const segment_executor.NodeInfoEntry) !void {
    if (header.record_len != ExactTextRecord.dense_ordinal_encoded_len and header.record_len != ExactTextRecord.id_encoded_len) return error.InvalidRecord;
    if (exactTextHeaderUsesDenseOrdinals(header)) {
        const id_base = nodeInfoEntriesDenseIdBase(nodes_by_id) orelse return error.InvalidRecord;
        if (header.id_base != id_base) return error.InvalidRecord;
    } else if (header.id_base != 0) {
        return error.InvalidRecord;
    }
}

fn nodeInfoEntriesDenseIdBase(entries: []const segment_executor.NodeInfoEntry) ?u64 {
    if (entries.len == 0) return null;
    const id_base = entries[0].id.toInt();
    if (!validNodeId(entries[0].id)) return null;
    for (entries, 0..) |entry, index| {
        const expected = std.math.add(u64, id_base, @intCast(index)) catch return null;
        if (expected != entry.id.toInt()) return null;
    }
    return id_base;
}

fn exactTextHeaderUsesDenseOrdinals(header: IndexHeader) bool {
    return header.record_len == ExactTextRecord.dense_ordinal_encoded_len;
}

fn exactTextRecordLen(node_id_base: u64) u16 {
    return if (node_id_base != 0) ExactTextRecord.dense_ordinal_encoded_len else ExactTextRecord.id_encoded_len;
}

fn encodeNodeByIdLogicalRecord(record: NodeByIdRecord, out: *[NodeByIdRecord.logical_encoded_len]u8) void {
    std.mem.writeInt(u64, out[0..8], record.id.toInt(), .little);
    std.mem.writeInt(u16, out[8..10], @intFromEnum(record.kind), .little);
    @memset(out[10..12], 0);
    std.mem.writeInt(u32, out[12..16], record.text_len, .little);
    std.mem.writeInt(u64, out[16..24], record.text_offset, .little);
}

fn encodeSparseNodeByIdRecord(record: NodeByIdRecord, out: *[NodeByIdRecord.sparse_encoded_len]u8) !void {
    std.mem.writeInt(u64, out[0..8], record.id.toInt(), .little);
    std.mem.writeInt(u16, out[8..10], @intFromEnum(record.kind), .little);
    std.mem.writeInt(u16, out[10..12], try encodeNodeTextLenMinusOne(record.text_len), .little);
    std.mem.writeInt(u32, out[12..16], try encodeNodeTextOffset(record.text_offset), .little);
}

fn encodeSparseUniformKindNodeByIdRecord(record: NodeByIdRecord, out: *[NodeByIdRecord.sparse_uniform_kind_encoded_len]u8) !void {
    std.mem.writeInt(u64, out[0..8], record.id.toInt(), .little);
    std.mem.writeInt(u16, out[8..10], try encodeNodeTextLenMinusOne(record.text_len), .little);
    std.mem.writeInt(u32, out[10..14], try encodeNodeTextOffset(record.text_offset), .little);
}

fn encodeDenseNodeByIdRecord(record: NodeByIdRecord, out: *[NodeByIdRecord.dense_encoded_len]u8) !void {
    std.mem.writeInt(u16, out[0..2], @intFromEnum(record.kind), .little);
    std.mem.writeInt(u16, out[2..4], try encodeNodeTextLenMinusOne(record.text_len), .little);
    std.mem.writeInt(u32, out[4..8], try encodeNodeTextOffset(record.text_offset), .little);
}

fn encodeDenseUniformKindNodeByIdRecord(record: NodeByIdRecord, out: *[NodeByIdRecord.dense_uniform_kind_encoded_len]u8) !void {
    std.mem.writeInt(u16, out[0..2], try encodeNodeTextLenMinusOne(record.text_len), .little);
    std.mem.writeInt(u32, out[2..6], try encodeNodeTextOffset(record.text_offset), .little);
}

fn encodeNodeTextLenMinusOne(text_len: u32) !u16 {
    if (text_len == 0 or text_len > max_text_bytes) return error.InvalidRecord;
    return @intCast(text_len - 1);
}

fn encodeNodeTextOffset(text_offset: u64) !u32 {
    return std.math.cast(u32, text_offset) orelse error.RecordTooLarge;
}

fn decodeNodeTextLen(encoded: u16) u32 {
    return @as(u32, encoded) + 1;
}

fn decodeSparseNodeByIdRecord(bytes: []const u8) !NodeByIdRecord {
    if (bytes.len != NodeByIdRecord.sparse_encoded_len) return error.InvalidRecord;
    return .{
        .id = core.NodeId.fromInt(std.mem.readInt(u64, bytes[0..8], .little)),
        .kind = kindFromInt(std.mem.readInt(u16, bytes[8..10], .little)) orelse return error.InvalidRecord,
        .text_len = decodeNodeTextLen(std.mem.readInt(u16, bytes[10..12], .little)),
        .text_offset = std.mem.readInt(u32, bytes[12..16], .little),
    };
}

fn decodeNodeByIdRecord(bytes: []const u8, header: IndexHeader, index: u64) !NodeByIdRecord {
    if (nodeByIdHeaderUsesDenseIds(header)) {
        if (nodeByIdHeaderUsesUniformKind(header)) {
            if (bytes.len != NodeByIdRecord.dense_uniform_kind_encoded_len) return error.InvalidRecord;
            const id = std.math.add(u64, header.id_base, index) catch return error.InvalidRecord;
            return .{
                .id = core.NodeId.fromInt(id),
                .kind = header.uniform_kind orelse return error.InvalidRecord,
                .text_len = decodeNodeTextLen(std.mem.readInt(u16, bytes[0..2], .little)),
                .text_offset = std.mem.readInt(u32, bytes[2..6], .little),
            };
        }
        if (bytes.len != NodeByIdRecord.dense_encoded_len) return error.InvalidRecord;
        const id = std.math.add(u64, header.id_base, index) catch return error.InvalidRecord;
        return .{
            .id = core.NodeId.fromInt(id),
            .kind = kindFromInt(std.mem.readInt(u16, bytes[0..2], .little)) orelse return error.InvalidRecord,
            .text_len = decodeNodeTextLen(std.mem.readInt(u16, bytes[2..4], .little)),
            .text_offset = std.mem.readInt(u32, bytes[4..8], .little),
        };
    }
    if (nodeByIdHeaderUsesUniformKind(header)) {
        if (bytes.len != NodeByIdRecord.sparse_uniform_kind_encoded_len) return error.InvalidRecord;
        return .{
            .id = core.NodeId.fromInt(std.mem.readInt(u64, bytes[0..8], .little)),
            .kind = header.uniform_kind orelse return error.InvalidRecord,
            .text_len = decodeNodeTextLen(std.mem.readInt(u16, bytes[8..10], .little)),
            .text_offset = std.mem.readInt(u32, bytes[10..14], .little),
        };
    }
    return try decodeSparseNodeByIdRecord(bytes);
}

fn decodeNodeByIdRecordAt(bytes: []const u8, header: IndexHeader, index: u64) !NodeByIdRecord {
    if (index >= header.node_count) return error.InvalidRecord;
    const offset = try recordOffset(index, header.record_len);
    const record_len: usize = header.record_len;
    return try decodeNodeByIdRecord(bytes[offset..][0..record_len], header, index);
}

fn validateNodeByIdRecordDigest(bytes: []const u8, header: IndexHeader) !void {
    var digest = std.hash.Wyhash.init(0x544B_4E49);
    var logical_bytes: [NodeByIdRecord.logical_encoded_len]u8 = undefined;
    var index: u64 = 0;
    while (index < header.node_count) : (index += 1) {
        const record = try decodeNodeByIdRecordAt(bytes, header, index);
        encodeNodeByIdLogicalRecord(record, &logical_bytes);
        digest.update(&logical_bytes);
    }
    if (digest.final() != header.record_digest) return error.InvalidRecord;
}

fn encodeExactTextLogicalRecord(record: ExactTextRecord, out: *[ExactTextRecord.logical_encoded_len]u8) void {
    std.mem.writeInt(u64, out[0..8], record.id.toInt(), .little);
}

fn encodeDenseOrdinalExactTextRecord(record: ExactTextRecord, id_base: u64, out: *[ExactTextRecord.dense_ordinal_encoded_len]u8) !void {
    const id = record.id.toInt();
    if (id < id_base) return error.InvalidRecord;
    const ordinal = id - id_base;
    if (ordinal > std.math.maxInt(u32)) return error.RecordTooLarge;
    std.mem.writeInt(u32, out[0..4], @intCast(ordinal), .little);
}

fn decodeExactTextRecord(bytes: []const u8, header: IndexHeader) !ExactTextRecord {
    if (exactTextHeaderUsesDenseOrdinals(header)) {
        if (bytes.len != ExactTextRecord.dense_ordinal_encoded_len) return error.InvalidRecord;
        const ordinal = std.mem.readInt(u32, bytes[0..4], .little);
        const id = std.math.add(u64, header.id_base, ordinal) catch return error.InvalidRecord;
        return .{ .id = core.NodeId.fromInt(id) };
    }
    if (bytes.len != ExactTextRecord.id_encoded_len) return error.InvalidRecord;
    return .{
        .id = core.NodeId.fromInt(std.mem.readInt(u64, bytes[0..8], .little)),
    };
}

fn validateNode(node: segment_executor.NodeInfoEntry) !void {
    if (node.id == .none or node.id.toInt() == std.math.maxInt(u64)) return core.Error.InvalidId;
    if (node.text.len == 0 or node.text.len > max_text_bytes) return error.InvalidRecord;
    if (std.mem.indexOfScalar(u8, node.text, 0) != null) return error.InvalidRecord;
}

fn validateCatalogRecord(record: CatalogRecord, texts: []const u8) ![]const u8 {
    if (!validNodeId(record.id)) return core.Error.InvalidId;
    return try nameBytesSlice(texts, record.text_offset, record.text_len);
}

fn rejectDuplicateIds(records: []const BuildRecord) !void {
    var i: usize = 1;
    while (i < records.len) : (i += 1) {
        if (records[i - 1].id == records[i].id) return error.InvalidRecord;
    }
}

fn nameBytesSlice(texts: []const u8, offset: u64, len: u32) ![]const u8 {
    if (len == 0 or len > max_text_bytes) return error.InvalidRecord;
    const start = std.math.cast(usize, offset) orelse return error.RecordTooLarge;
    const text_len: usize = @intCast(len);
    if (start > texts.len or text_len > texts.len - start) return error.InvalidRecord;
    const text = texts[start..][0..text_len];
    if (std.mem.indexOfScalar(u8, text, 0) != null) return error.InvalidRecord;
    return text;
}

fn validateCatalogCrossLinks(catalog: segment_executor.SegmentNodeCatalog) !void {
    for (catalog.exact_texts) |entry| {
        const matches = (try catalog.matchNode(entry.id, entry.kind, entry.text)) orelse return error.InvalidRecord;
        if (!matches) return error.InvalidRecord;
    }
}

fn nodeInfoById(entries: []const segment_executor.NodeInfoEntry, id: core.NodeId) ?segment_executor.NodeInfoEntry {
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
    if (low >= entries.len or entries[low].id != id) return null;
    return entries[low];
}

fn validateExactRecordDigest(bytes: []const u8, header: IndexHeader) !void {
    var digest = std.hash.Wyhash.init(0x544B_4E45);
    var logical_bytes: [ExactTextRecord.logical_encoded_len]u8 = undefined;
    var index: u64 = 0;
    while (index < header.node_count) : (index += 1) {
        const offset = try recordOffset(index, header.record_len);
        const record_len: usize = header.record_len;
        const record = try decodeExactTextRecord(bytes[offset..][0..record_len], header);
        encodeExactTextLogicalRecord(record, &logical_bytes);
        digest.update(&logical_bytes);
    }
    if (digest.final() != header.record_digest) return error.InvalidRecord;
}

fn recordOffset(index: u64, record_len: usize) !u64 {
    const payload_offset = std.math.mul(u64, index, record_len) catch return error.RecordTooLarge;
    return std.math.add(u64, IndexHeader.encoded_len, payload_offset) catch return error.RecordTooLarge;
}

fn validNodeId(id: core.NodeId) bool {
    return id != .none and id.toInt() != std.math.maxInt(u64);
}

fn compareExactTextRecordKeys(left: ExactTextKey, right: ExactTextKey) std.math.Order {
    const key_order = compareExactTextKey(left.kind, left.text, right.kind, right.text);
    if (key_order != .eq) return key_order;
    return std.math.order(left.id.toInt(), right.id.toInt());
}

fn compareExactTextKey(left_kind: core.NodeKind, left_name: []const u8, right_kind: core.NodeKind, right_name: []const u8) std.math.Order {
    const kind_order = std.math.order(@intFromEnum(left_kind), @intFromEnum(right_kind));
    if (kind_order != .eq) return kind_order;
    return std.mem.order(u8, left_name, right_name);
}

fn compareCatalogRecordsByExactText(left: CatalogRecord, left_name: []const u8, right: CatalogRecord, right_name: []const u8) std.math.Order {
    const key_order = compareExactTextKey(left.kind, left_name, right.kind, right_name);
    if (key_order != .eq) return key_order;
    return std.math.order(left.id.toInt(), right.id.toInt());
}

fn buildRecordIdLessThan(_: void, left: BuildRecord, right: BuildRecord) bool {
    return left.id.toInt() < right.id.toInt();
}

fn buildRecordExactTextLessThan(_: void, left: BuildRecord, right: BuildRecord) bool {
    const kind_order = std.math.order(@intFromEnum(left.kind), @intFromEnum(right.kind));
    if (kind_order != .eq) return kind_order == .lt;
    const text_order = std.mem.order(u8, left.text, right.text);
    if (text_order != .eq) return text_order == .lt;
    return left.id.toInt() < right.id.toInt();
}

fn readRegularFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8, max_size: ?u64) ![]u8 {
    var file = try std.Io.Dir.cwd().openFile(io, path, .{ .allow_directory = false });
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.kind != .file) return error.InvalidRecord;
    if (max_size) |limit| {
        if (stat.size > limit) return error.RecordTooLarge;
    }
    const len = std.math.cast(usize, stat.size) orelse return error.RecordTooLarge;
    const bytes = try allocator.alloc(u8, len);
    errdefer allocator.free(bytes);
    if (try file.readPositionalAll(io, bytes, 0) != bytes.len) return error.InvalidRecord;
    return bytes;
}

fn writeFileSynced(allocator: std.mem.Allocator, io: std.Io, path: []const u8, bytes: []const u8) !void {
    const tmp_path = try tmpPath(allocator, path);
    defer allocator.free(tmp_path);
    errdefer std.Io.Dir.cwd().deleteFile(io, tmp_path) catch {};

    {
        var file = try std.Io.Dir.cwd().createFile(io, tmp_path, .{ .read = true, .truncate = true });
        defer file.close(io);
        try file.writePositionalAll(io, bytes, 0);
        try file.sync(io);
    }
    try renameReplace(io, tmp_path, path);
}

fn tmpPath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}.tmp", .{path});
}

fn renameReplace(io: std.Io, tmp_path: []const u8, final_path: []const u8) !void {
    if (std.fs.path.isAbsolute(final_path)) {
        try std.Io.Dir.renameAbsolute(tmp_path, final_path, io);
    } else {
        try std.Io.Dir.rename(.cwd(), tmp_path, .cwd(), final_path, io);
    }
}

fn kindFromInt(value: u16) ?core.NodeKind {
    inline for (@typeInfo(core.NodeKind).@"enum".fields) |field| {
        if (field.value == value) return @enumFromInt(value);
    }
    return null;
}

fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| {
        if (byte != 0) return false;
    }
    return true;
}

const CatalogRecordStream = struct {
    records: []const CatalogRecord,
    pos: usize = 0,

    fn reset(self: *CatalogRecordStream) !void {
        self.pos = 0;
    }

    fn next(self: *CatalogRecordStream) !?CatalogRecord {
        if (self.pos >= self.records.len) return null;
        const record = self.records[self.pos];
        self.pos += 1;
        return record;
    }
};

test "segment node index writes durable catalog and drives one-hop segment executor" {
    const optimizer = @import("ql/optimizer.zig");

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const dir_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "segment" });
    defer std.testing.allocator.free(dir_path);

    const nodes = [_]segment_executor.NodeInfoEntry{
        .{ .id = .fromInt(3), .kind = .document, .text = "README" },
        .{ .id = .fromInt(1), .kind = .file, .text = "src/main.zig" },
        .{ .id = .fromInt(2), .kind = .function, .text = "main" },
    };
    try writeCatalog(std.testing.allocator, std.testing.io, dir_path, &nodes);

    const exact_path = try std.fs.path.join(std.testing.allocator, &.{ dir_path, exact_texts_leaf });
    defer std.testing.allocator.free(exact_path);
    const exact_stat = try std.Io.Dir.cwd().statFile(std.testing.io, exact_path, .{});
    try std.testing.expectEqual(@as(u64, IndexHeader.encoded_len + ExactTextRecord.dense_ordinal_encoded_len * nodes.len), exact_stat.size);

    var catalog = try openCatalog(std.testing.allocator, std.testing.io, dir_path);
    defer catalog.deinit(std.testing.allocator);
    var ids = try catalog.catalog().lookupExact(std.testing.allocator, .file, "src/main.zig", 8);
    defer ids.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), ids.items.len);
    try std.testing.expectEqual(@as(u64, 1), ids.items[0].toInt());

    var mapped_catalog = try MappedCatalog.open(std.testing.io, dir_path);
    defer mapped_catalog.deinit();
    const summary = mapped_catalog.summary();
    var mapped_ids = try mapped_catalog.lookupExact(std.testing.allocator, .file, "src/main.zig", 8);
    defer mapped_ids.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), mapped_ids.items.len);
    try std.testing.expectEqual(@as(u64, 1), mapped_ids.items[0].toInt());

    var trusted_catalog = try MappedCatalog.openTrusted(std.testing.io, dir_path, summary);
    defer trusted_catalog.deinit();
    var trusted_ids = try trusted_catalog.lookupExact(std.testing.allocator, .file, "src/main.zig", 8);
    defer trusted_ids.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), trusted_ids.items.len);
    try std.testing.expectEqual(@as(u64, 1), trusted_ids.items[0].toInt());

    var wrong_summary = summary;
    wrong_summary.node_count += 1;
    try std.testing.expectError(error.InvalidRecord, MappedCatalog.openTrusted(std.testing.io, dir_path, wrong_summary));

    const edges = [_]@import("segment.zig").EdgeRecord{
        .{ .edge_id = .fromInt(1), .src = .fromInt(1), .rel = .defines, .dst = .fromInt(2) },
    };
    var segment = try @import("segment.zig").ImmutableAdjacencySegment.build(std.testing.allocator, std.testing.io, dir_path, &edges);
    defer segment.deinit();

    const manifest_dir = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "manifest" });
    defer std.testing.allocator.free(manifest_dir);
    var manifest_store = try segment_manifest.Store.init(std.testing.allocator, std.testing.io, manifest_dir);
    defer manifest_store.deinit();
    _ = try manifest_store.publish(1024, &.{
        .{
            .kind = .node,
            .generation = 1,
            .node_count = summary.node_count,
            .node_range = .{ .min = 1, .max = 3 },
            .segment_digest = 0xfeed,
            .node_catalog_summary = summary,
            .path = "segment",
        },
    });
    var snapshot = try manifest_store.pinCurrent();
    defer snapshot.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), snapshot.entries.items.len);
    var manifest_trusted_catalog = try openTrustedFromManifestEntry(
        std.testing.allocator,
        std.testing.io,
        path_buf[0..root_len],
        snapshot.entries.items[0].asEntry(),
    );
    defer manifest_trusted_catalog.deinit();

    var ops = std.ArrayList(optimizer.PhysicalOp).empty;
    defer ops.deinit(std.testing.allocator);
    try ops.append(std.testing.allocator, .{ .node_lookup_by_text = .{ .var_name = "f", .kind = .file, .text = "src/main.zig" } });
    try ops.append(std.testing.allocator, .{ .expand = .{
        .left_var = "f",
        .rel = .defines,
        .right_var = "s",
        .right_kind = .function,
    } });
    try ops.append(std.testing.allocator, .{ .project = &.{} });

    var table = try segment_executor.executeExactTextPath(
        std.testing.allocator,
        .{ .catalog = catalog.catalog(), .segment = &segment },
        .{ .ops = ops },
        .{},
    );
    defer table.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), table.rows.items.len);
    try std.testing.expectEqual(@as(u64, 2), table.rows.items[0].get("s").?.toInt());

    var mapped_table = try segment_executor.executeExactTextPathWithCatalog(
        std.testing.allocator,
        .{ .catalog = &mapped_catalog, .segment = &segment },
        .{ .ops = ops },
        .{},
    );
    defer mapped_table.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), mapped_table.rows.items.len);
    try std.testing.expectEqual(@as(u64, 2), mapped_table.rows.items[0].get("s").?.toInt());

    var manifest_trusted_table = try segment_executor.executeExactTextPathWithCatalog(
        std.testing.allocator,
        .{ .catalog = &manifest_trusted_catalog, .segment = &segment },
        .{ .ops = ops },
        .{},
    );
    defer manifest_trusted_table.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), manifest_trusted_table.rows.items.len);
    try std.testing.expectEqual(@as(u64, 2), manifest_trusted_table.rows.items[0].get("s").?.toInt());
}

test "segment node index derives dense by-id records from header base and ordinal" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const dir_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "segment" });
    defer std.testing.allocator.free(dir_path);

    const nodes = [_]segment_executor.NodeInfoEntry{
        .{ .id = .fromInt(41), .kind = .file, .text = "a.zig" },
        .{ .id = .fromInt(40), .kind = .document, .text = "README" },
        .{ .id = .fromInt(42), .kind = .function, .text = "main" },
    };
    try writeCatalog(std.testing.allocator, std.testing.io, dir_path, &nodes);

    const nodes_path = try std.fs.path.join(std.testing.allocator, &.{ dir_path, nodes_by_id_leaf });
    defer std.testing.allocator.free(nodes_path);
    {
        var file = try std.Io.Dir.cwd().openFile(std.testing.io, nodes_path, .{});
        defer file.close(std.testing.io);
        const stat = try file.stat(std.testing.io);
        try std.testing.expectEqual(@as(u64, IndexHeader.encoded_len + NodeByIdRecord.dense_encoded_len * nodes.len), stat.size);
    }

    var catalog = try MappedCatalog.open(std.testing.io, dir_path);
    defer catalog.deinit();
    try std.testing.expect(nodeByIdHeaderUsesDenseIds(catalog.nodes_header));
    try std.testing.expectEqual(@as(u64, 40), catalog.nodes_header.id_base);
    try std.testing.expectEqual(true, (try catalog.matchNode(.fromInt(42), .function, "main")).?);
    const summary = catalog.summary();

    {
        var file = try std.Io.Dir.cwd().openFile(std.testing.io, nodes_path, .{ .mode = .read_write });
        defer file.close(std.testing.io);
        var corrupt_base: [8]u8 = undefined;
        std.mem.writeInt(u64, &corrupt_base, 41, .little);
        try file.writePositionalAll(std.testing.io, &corrupt_base, 48);
    }
    try std.testing.expectError(error.InvalidRecord, MappedCatalog.openTrusted(std.testing.io, dir_path, summary));
}

test "segment node index derives uniform-kind dense by-id records from header kind" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const dir_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "segment" });
    defer std.testing.allocator.free(dir_path);

    const nodes = [_]segment_executor.NodeInfoEntry{
        .{ .id = .fromInt(40), .kind = .file, .text = "a.zig" },
        .{ .id = .fromInt(41), .kind = .file, .text = "b.zig" },
        .{ .id = .fromInt(42), .kind = .file, .text = "c.zig" },
    };
    try writeCatalog(std.testing.allocator, std.testing.io, dir_path, &nodes);

    const nodes_path = try std.fs.path.join(std.testing.allocator, &.{ dir_path, nodes_by_id_leaf });
    defer std.testing.allocator.free(nodes_path);
    {
        var file = try std.Io.Dir.cwd().openFile(std.testing.io, nodes_path, .{});
        defer file.close(std.testing.io);
        const stat = try file.stat(std.testing.io);
        try std.testing.expectEqual(@as(u64, IndexHeader.encoded_len + NodeByIdRecord.dense_uniform_kind_encoded_len * nodes.len), stat.size);
    }

    var catalog = try MappedCatalog.open(std.testing.io, dir_path);
    defer catalog.deinit();
    try std.testing.expect(nodeByIdHeaderUsesDenseIds(catalog.nodes_header));
    try std.testing.expect(nodeByIdHeaderUsesUniformKind(catalog.nodes_header));
    try std.testing.expectEqual(core.NodeKind.file, catalog.nodes_header.uniform_kind.?);
    try std.testing.expectEqual(true, (try catalog.matchNode(.fromInt(42), .file, "c.zig")).?);
    const summary = catalog.summary();

    {
        var file = try std.Io.Dir.cwd().openFile(std.testing.io, nodes_path, .{ .mode = .read_write });
        defer file.close(std.testing.io);
        try file.writePositionalAll(std.testing.io, &.{ 0, 0 }, 10);
    }
    try std.testing.expectError(error.InvalidRecord, MappedCatalog.open(std.testing.io, dir_path));
    try std.testing.expectError(error.InvalidRecord, MappedCatalog.openTrusted(std.testing.io, dir_path, summary));
}

test "segment node index keeps sparse by-id records when ids are not ordinal dense" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const dir_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "segment" });
    defer std.testing.allocator.free(dir_path);

    const nodes = [_]segment_executor.NodeInfoEntry{
        .{ .id = .fromInt(10), .kind = .file, .text = "a.zig" },
        .{ .id = .fromInt(30), .kind = .function, .text = "main" },
    };
    try writeCatalog(std.testing.allocator, std.testing.io, dir_path, &nodes);

    const nodes_path = try std.fs.path.join(std.testing.allocator, &.{ dir_path, nodes_by_id_leaf });
    defer std.testing.allocator.free(nodes_path);
    var file = try std.Io.Dir.cwd().openFile(std.testing.io, nodes_path, .{});
    defer file.close(std.testing.io);
    const stat = try file.stat(std.testing.io);
    try std.testing.expectEqual(@as(u64, IndexHeader.encoded_len + NodeByIdRecord.sparse_encoded_len * nodes.len), stat.size);

    const exact_path = try std.fs.path.join(std.testing.allocator, &.{ dir_path, exact_texts_leaf });
    defer std.testing.allocator.free(exact_path);
    const exact_stat = try std.Io.Dir.cwd().statFile(std.testing.io, exact_path, .{});
    try std.testing.expectEqual(@as(u64, IndexHeader.encoded_len + ExactTextRecord.id_encoded_len * nodes.len), exact_stat.size);

    var catalog = try MappedCatalog.open(std.testing.io, dir_path);
    defer catalog.deinit();
    try std.testing.expect(!nodeByIdHeaderUsesDenseIds(catalog.nodes_header));
    try std.testing.expectEqual(@as(u64, 0), catalog.nodes_header.id_base);
    try std.testing.expectEqual(true, (try catalog.matchNode(.fromInt(30), .function, "main")).?);
}

test "segment node index derives uniform-kind sparse by-id records from header kind" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const dir_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "segment" });
    defer std.testing.allocator.free(dir_path);

    const nodes = [_]segment_executor.NodeInfoEntry{
        .{ .id = .fromInt(10), .kind = .file, .text = "a.zig" },
        .{ .id = .fromInt(30), .kind = .file, .text = "main.zig" },
    };
    try writeCatalog(std.testing.allocator, std.testing.io, dir_path, &nodes);

    const nodes_path = try std.fs.path.join(std.testing.allocator, &.{ dir_path, nodes_by_id_leaf });
    defer std.testing.allocator.free(nodes_path);
    var file = try std.Io.Dir.cwd().openFile(std.testing.io, nodes_path, .{});
    defer file.close(std.testing.io);
    const stat = try file.stat(std.testing.io);
    try std.testing.expectEqual(@as(u64, IndexHeader.encoded_len + NodeByIdRecord.sparse_uniform_kind_encoded_len * nodes.len), stat.size);

    var catalog = try MappedCatalog.open(std.testing.io, dir_path);
    defer catalog.deinit();
    try std.testing.expect(!nodeByIdHeaderUsesDenseIds(catalog.nodes_header));
    try std.testing.expect(nodeByIdHeaderUsesUniformKind(catalog.nodes_header));
    try std.testing.expectEqual(core.NodeKind.file, catalog.nodes_header.uniform_kind.?);
    try std.testing.expectEqual(true, (try catalog.matchNode(.fromInt(30), .file, "main.zig")).?);
}

test "segment node index compact text span encoding preserves max text length" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const dir_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "segment" });
    defer std.testing.allocator.free(dir_path);

    const text = try std.testing.allocator.alloc(u8, max_text_bytes);
    defer std.testing.allocator.free(text);
    @memset(text, 'x');

    const nodes = [_]segment_executor.NodeInfoEntry{
        .{ .id = .fromInt(1), .kind = .document, .text = text },
    };
    try writeCatalog(std.testing.allocator, std.testing.io, dir_path, &nodes);

    const nodes_path = try std.fs.path.join(std.testing.allocator, &.{ dir_path, nodes_by_id_leaf });
    defer std.testing.allocator.free(nodes_path);
    const nodes_stat = try std.Io.Dir.cwd().statFile(std.testing.io, nodes_path, .{});
    try std.testing.expectEqual(@as(u64, IndexHeader.encoded_len + NodeByIdRecord.dense_uniform_kind_encoded_len), nodes_stat.size);

    var catalog = try MappedCatalog.open(std.testing.io, dir_path);
    defer catalog.deinit();
    try std.testing.expectEqual(true, (try catalog.matchNode(.fromInt(1), .document, text)).?);
}

test "segment node index compact text span helpers reject impossible physical spans" {
    try std.testing.expectEqual(@as(u16, std.math.maxInt(u16)), try encodeNodeTextLenMinusOne(max_text_bytes));
    try std.testing.expectEqual(@as(u32, max_text_bytes), decodeNodeTextLen(std.math.maxInt(u16)));
    try std.testing.expectError(error.InvalidRecord, encodeNodeTextLenMinusOne(0));
    try std.testing.expectError(error.InvalidRecord, encodeNodeTextLenMinusOne(max_text_bytes + 1));
    try std.testing.expectEqual(@as(u32, std.math.maxInt(u32)), try encodeNodeTextOffset(std.math.maxInt(u32)));
    try std.testing.expectError(error.RecordTooLarge, encodeNodeTextOffset(@as(u64, std.math.maxInt(u32)) + 1));
}

test "segment node index writes catalog from independently ordered streams" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const dir_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "segment" });
    defer std.testing.allocator.free(dir_path);

    const texts = "READMEsrc/main.zigmain";
    const readme = CatalogRecord{ .id = .fromInt(1), .kind = .document, .text_offset = 0, .text_len = 6 };
    const file = CatalogRecord{ .id = .fromInt(2), .kind = .file, .text_offset = 6, .text_len = 12 };
    const function = CatalogRecord{ .id = .fromInt(3), .kind = .function, .text_offset = 18, .text_len = 4 };
    const by_id_records = [_]CatalogRecord{ readme, file, function };
    const by_text_records = [_]CatalogRecord{ file, function, readme };
    var by_id_stream = CatalogRecordStream{ .records = &by_id_records };
    var by_text_stream = CatalogRecordStream{ .records = &by_text_records };
    _ = try writeCatalogFromOrderedStreams(
        std.testing.allocator,
        std.testing.io,
        dir_path,
        texts,
        by_id_records.len,
        &by_id_stream,
        CatalogRecordStream.reset,
        CatalogRecordStream.next,
        &by_text_stream,
        CatalogRecordStream.reset,
        CatalogRecordStream.next,
    );

    var catalog = try MappedCatalog.open(std.testing.io, dir_path);
    defer catalog.deinit();
    var ids = try catalog.lookupExact(std.testing.allocator, .file, "src/main.zig", 8);
    defer ids.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), ids.items.len);
    try std.testing.expectEqual(@as(u64, 2), ids.items[0].toInt());
    try std.testing.expectEqual(true, (try catalog.matchNode(.fromInt(3), .function, "main")).?);

    const bad_dir_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "bad-segment" });
    defer std.testing.allocator.free(bad_dir_path);
    var bad_by_id_stream = CatalogRecordStream{ .records = &by_id_records };
    var bad_by_text_stream = CatalogRecordStream{ .records = &by_id_records };
    try std.testing.expectError(error.InvalidRecord, writeCatalogFromOrderedStreams(
        std.testing.allocator,
        std.testing.io,
        bad_dir_path,
        texts,
        by_id_records.len,
        &bad_by_id_stream,
        CatalogRecordStream.reset,
        CatalogRecordStream.next,
        &bad_by_text_stream,
        CatalogRecordStream.reset,
        CatalogRecordStream.next,
    ));

    const bad_cross_dir_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "bad-cross-segment" });
    defer std.testing.allocator.free(bad_cross_dir_path);
    const dangling_function = CatalogRecord{ .id = .fromInt(99), .kind = .function, .text_offset = 18, .text_len = 4 };
    const dangling_by_text_records = [_]CatalogRecord{ file, dangling_function, readme };
    var cross_by_id_stream = CatalogRecordStream{ .records = &by_id_records };
    var dangling_by_text_stream = CatalogRecordStream{ .records = &dangling_by_text_records };
    try std.testing.expectError(error.InvalidRecord, writeCatalogFromOrderedStreams(
        std.testing.allocator,
        std.testing.io,
        bad_cross_dir_path,
        texts,
        by_id_records.len,
        &cross_by_id_stream,
        CatalogRecordStream.reset,
        CatalogRecordStream.next,
        &dangling_by_text_stream,
        CatalogRecordStream.reset,
        CatalogRecordStream.next,
    ));
}

test "segment node catalog id run builder uses exact chunk scratch" {
    const chunk_bytes = std.math.mul(usize, catalog_id_run_chunk_records, @sizeOf(NodeByIdRecord)) catch return error.RecordTooLarge;
    const buffer = try std.testing.allocator.alloc(u8, chunk_bytes + 1024);
    defer std.testing.allocator.free(buffer);

    var fixed = std.heap.FixedBufferAllocator.init(buffer);
    var builder = try CatalogIdRunBuilder.init(fixed.allocator(), std.testing.io, "unused");
    defer builder.deinit();

    try std.testing.expectEqual(@as(usize, catalog_id_run_chunk_records), builder.chunk.capacity);
}

test "segment node catalog id run merger uses exact fan-in scratch" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root = path_buf[0..root_len];

    var run_paths: [4][]u8 = undefined;
    for (&run_paths, 0..) |*run_path, index| {
        run_path.* = try std.fmt.allocPrint(std.testing.allocator, "{s}/catalog-id-fan-in-{d}.run", .{ root, index });
        const records = [_]NodeByIdRecord{
            .{
                .id = core.NodeId.fromInt(@intCast(index + 1)),
                .kind = .file,
                .text_offset = @intCast(index * 16),
                .text_len = 8,
            },
        };
        try writeCatalogIdRun(std.testing.allocator, std.testing.io, run_path.*, &records);
    }
    defer for (run_paths) |run_path| std.testing.allocator.free(run_path);

    var merger = try CatalogIdRunMerger.init(std.testing.allocator, std.testing.io, &run_paths);
    defer merger.deinit();

    try std.testing.expectEqual(run_paths.len, merger.readers.capacity);
    try std.testing.expectEqual(run_paths.len, merger.current_records.capacity);
    try std.testing.expectEqual(run_paths.len, merger.queue.capacity());
}

test "segment node catalog single chunk validates exact ids without temp run" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const root = path_buf[0..root_len];
    const dir_path = try std.fs.path.join(std.testing.allocator, &.{ root, "catalog" });
    defer std.testing.allocator.free(dir_path);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, dir_path);

    const exact_path = try std.fs.path.join(std.testing.allocator, &.{ dir_path, exact_texts_leaf });
    defer std.testing.allocator.free(exact_path);
    const stale_run_dir = try std.fmt.allocPrint(std.testing.allocator, "{s}.id_run.0.tmp", .{exact_path});
    defer std.testing.allocator.free(stale_run_dir);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, stale_run_dir);

    const nodes = [_]segment_executor.NodeInfoEntry{
        .{ .id = core.NodeId.fromInt(3), .kind = .function, .text = "gamma" },
        .{ .id = core.NodeId.fromInt(1), .kind = .file, .text = "alpha" },
        .{ .id = core.NodeId.fromInt(2), .kind = .symbol, .text = "beta" },
    };
    try writeCatalog(std.testing.allocator, std.testing.io, dir_path, &nodes);

    const stat = try std.Io.Dir.cwd().statFile(std.testing.io, stale_run_dir, .{});
    try std.testing.expectEqual(std.Io.File.Kind.directory, stat.kind);

    var catalog = try MappedCatalog.open(std.testing.io, dir_path);
    defer catalog.deinit();
    try std.testing.expect((try catalog.matchNode(core.NodeId.fromInt(1), .file, "alpha")).?);
    try std.testing.expect((try catalog.matchNode(core.NodeId.fromInt(2), .symbol, "beta")).?);
    try std.testing.expect((try catalog.matchNode(core.NodeId.fromInt(3), .function, "gamma")).?);
}

test "segment node index rejects unsafe manifest trusted-open entries" {
    const summary = CatalogSummary{
        .node_count = 1,
        .texts_bytes = 8,
        .texts_digest = 0x11,
        .nodes_record_digest = 0x12,
        .exact_record_digest = 0x13,
    };
    try std.testing.expectError(error.InvalidRecord, openTrustedFromManifestEntry(
        std.testing.allocator,
        std.testing.io,
        ".",
        .{
            .kind = .edge,
            .generation = 1,
            .edge_count = 1,
            .edge_range = .{ .min = 1, .max = 1 },
            .node_catalog_summary = summary,
            .path = "segment",
        },
    ));
    try std.testing.expectError(error.InvalidRecord, openTrustedFromManifestEntry(
        std.testing.allocator,
        std.testing.io,
        ".",
        .{
            .kind = .node,
            .generation = 1,
            .node_count = 1,
            .node_range = .{ .min = 1, .max = 1 },
            .path = "segment",
        },
    ));
    try std.testing.expectError(error.InvalidRecord, openTrustedFromManifestEntry(
        std.testing.allocator,
        std.testing.io,
        ".",
        .{
            .kind = .node,
            .generation = 1,
            .node_count = 2,
            .node_range = .{ .min = 1, .max = 2 },
            .node_catalog_summary = summary,
            .path = "segment",
        },
    ));
    try std.testing.expectError(error.InvalidRecord, openTrustedFromManifestEntry(
        std.testing.allocator,
        std.testing.io,
        ".",
        .{
            .kind = .node,
            .generation = 1,
            .node_count = 1,
            .node_range = .{ .min = 1, .max = 1 },
            .node_catalog_summary = summary,
            .path = "../segment",
        },
    ));
}

test "segment node index rejects corrupted exact-text digest" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const dir_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "segment" });
    defer std.testing.allocator.free(dir_path);

    const nodes = [_]segment_executor.NodeInfoEntry{
        .{ .id = .fromInt(1), .kind = .file, .text = "src/main.zig" },
    };
    try writeCatalog(std.testing.allocator, std.testing.io, dir_path, &nodes);
    var valid_catalog = try MappedCatalog.open(std.testing.io, dir_path);
    const summary = valid_catalog.summary();
    valid_catalog.deinit();
    const exact_path = try std.fs.path.join(std.testing.allocator, &.{ dir_path, exact_texts_leaf });
    defer std.testing.allocator.free(exact_path);
    {
        var file = try std.Io.Dir.cwd().openFile(std.testing.io, exact_path, .{ .mode = .read_write });
        defer file.close(std.testing.io);
        try file.writePositionalAll(std.testing.io, &.{0xff}, IndexHeader.encoded_len);
    }
    try std.testing.expectError(error.InvalidRecord, openCatalog(std.testing.allocator, std.testing.io, dir_path));
    try std.testing.expectError(error.InvalidRecord, MappedCatalog.open(std.testing.io, dir_path));
    var trusted_catalog = try MappedCatalog.openTrusted(std.testing.io, dir_path, summary);
    defer trusted_catalog.deinit();
    try std.testing.expectError(error.InvalidRecord, trusted_catalog.lookupExact(std.testing.allocator, .file, "src/main.zig", 8));
}

test "segment node index trusted lookup rejects exact-text id without node cross-link" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const dir_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "segment" });
    defer std.testing.allocator.free(dir_path);

    const nodes = [_]segment_executor.NodeInfoEntry{
        .{ .id = .fromInt(1), .kind = .file, .text = "src/main.zig" },
    };
    try writeCatalog(std.testing.allocator, std.testing.io, dir_path, &nodes);
    var valid_catalog = try MappedCatalog.open(std.testing.io, dir_path);
    const summary = valid_catalog.summary();
    valid_catalog.deinit();

    const exact_path = try std.fs.path.join(std.testing.allocator, &.{ dir_path, exact_texts_leaf });
    defer std.testing.allocator.free(exact_path);
    {
        var file = try std.Io.Dir.cwd().openFile(std.testing.io, exact_path, .{ .mode = .read_write });
        defer file.close(std.testing.io);
        var ordinal_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &ordinal_bytes, 1, .little);
        try file.writePositionalAll(std.testing.io, &ordinal_bytes, IndexHeader.encoded_len);
    }

    try std.testing.expectError(error.InvalidRecord, openCatalog(std.testing.allocator, std.testing.io, dir_path));
    try std.testing.expectError(error.InvalidRecord, MappedCatalog.open(std.testing.io, dir_path));
    var trusted_catalog = try MappedCatalog.openTrusted(std.testing.io, dir_path, summary);
    defer trusted_catalog.deinit();
    try std.testing.expectError(error.InvalidRecord, trusted_catalog.lookupExact(std.testing.allocator, .file, "src/main.zig", 8));
}

test "segment node index rejects texts payload corruption through header digest" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const dir_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "segment" });
    defer std.testing.allocator.free(dir_path);

    const nodes = [_]segment_executor.NodeInfoEntry{
        .{ .id = .fromInt(1), .kind = .file, .text = "src/main.zig" },
        .{ .id = .fromInt(2), .kind = .function, .text = "main" },
    };
    try writeCatalog(std.testing.allocator, std.testing.io, dir_path, &nodes);
    const texts_path = try std.fs.path.join(std.testing.allocator, &.{ dir_path, texts_leaf });
    defer std.testing.allocator.free(texts_path);
    {
        var file = try std.Io.Dir.cwd().openFile(std.testing.io, texts_path, .{ .mode = .read_write });
        defer file.close(std.testing.io);
        try file.writePositionalAll(std.testing.io, "X", 0);
    }
    try std.testing.expectError(error.InvalidRecord, openCatalog(std.testing.allocator, std.testing.io, dir_path));
    try std.testing.expectError(error.InvalidRecord, MappedCatalog.open(std.testing.io, dir_path));
}
