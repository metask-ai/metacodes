const std = @import("std");
const core = @import("core.zig");
const schema = @import("schema.zig");
const read_only_memory_map = @import("read_only_memory_map.zig");
const csr_format_mod = @import("segment/csr_format.zig");

const dense_edge_id_validation_factor: u64 = 2;
const dense_edge_id_validation_min: u64 = 4096;
const dense_edge_id_validation_cap: u64 = 512 * 1024 * 1024;

pub const Direction = enum {
    forward,
    reverse,
};

pub const EdgeRecord = struct {
    src: core.NodeId,
    dst: core.NodeId,
    edge_id: core.EdgeId,
    rel: core.RelKind,
};

pub const CsrFileByteStats = struct {
    total_bytes: u64 = 0,
    header_bytes: u64 = 0,
    vertex_bytes: u64 = 0,
    relation_bytes: u64 = 0,
    edge_bytes: u64 = 0,
    edge_count: u64 = 0,
    vertex_count: u64 = 0,
    relation_count: u64 = 0,
    edge_record_len: u16 = 0,
    vertex_record_len: u16 = 0,
    relation_record_len: u16 = 0,
    derived_edge_ids: bool = false,
    split_derived_edge_ids: bool = false,
    derived_vertex_ids: bool = false,
    split_derived_vertex_ids: bool = false,
    derived_edge_other_nodes: bool = false,
    split_derived_edge_other_nodes: bool = false,
};

const csr_format = csr_format_mod.CsrFormat(
    core,
    Direction,
    EdgeRecord,
    schema.max_relation_types,
);

const SegmentHeader = csr_format.SegmentHeader;
const DerivedEdgeIdShape = csr_format.DerivedEdgeIdShape;
const DerivedVertexIdShape = csr_format.DerivedVertexIdShape;
const DerivedEdgeOtherNodeShape = csr_format.DerivedEdgeOtherNodeShape;
const VertexRecord = csr_format.VertexRecord;
const RelationRangeRecord = csr_format.RelationRangeRecord;
const StoredEdgeRecord = csr_format.StoredEdgeRecord;
const derivedEdgeIdAt = csr_format.derivedEdgeIdAt;
const derivedEdgeIdShapesEqual = csr_format.derivedEdgeIdShapesEqual;
const derivedVertexIdAt = csr_format.derivedVertexIdAt;
const derivedVertexIdShapesEqual = csr_format.derivedVertexIdShapesEqual;
const derivedEdgeOtherNodeAt = csr_format.derivedEdgeOtherNodeAt;
const derivedEdgeOtherNodeShapesEqual = csr_format.derivedEdgeOtherNodeShapesEqual;
const deriveEdgeCountFromFileSize = csr_format.deriveEdgeCountFromFileSize;
const fileSizeFor = csr_format.fileSizeFor;
const fileSizeForHeader = csr_format.fileSizeForHeader;
const fileSizeForRecordLen = csr_format.fileSizeForRecordLen;
const fileSizeForRecordLens = csr_format.fileSizeForRecordLens;
const vertexRecordOffsetForHeader = csr_format.vertexRecordOffsetForHeader;
const relationRecordOffset = csr_format.relationRecordOffset;
const relationBaseOffsetForHeader = csr_format.relationBaseOffsetForHeader;
const edgeBaseOffsetForHeader = csr_format.edgeBaseOffsetForHeader;
const storedEdgeRangeOffset = csr_format.storedEdgeRangeOffset;
const uniformSingleRelationEdgeOffset = csr_format.uniformSingleRelationEdgeOffset;
const storedEdgeOtherNodeFieldLen = csr_format.storedEdgeOtherNodeFieldLen;
const storedEdgeIdFieldOffset = csr_format.storedEdgeIdFieldOffset;
const vertexEdgeOffsetFieldOffset = csr_format.vertexEdgeOffsetFieldOffset;
const vertexEdgeOffsetFieldLen = csr_format.vertexEdgeOffsetFieldLen;
const relFromInt = csr_format.relFromInt;
const CsrFileView = struct {
    io: std.Io,
    file: std.Io.File,
    size: u64,
    map: ?std.Io.File.MemoryMap = null,

    fn open(io: std.Io, path: []const u8) !CsrFileView {
        var file = try std.Io.Dir.cwd().openFile(io, path, .{});
        errdefer file.close(io);

        const stat = try file.stat(io);
        if (stat.kind != .file) return error.InvalidRecord;
        const len = std.math.cast(usize, stat.size) orelse return error.RecordTooLarge;

        const map = if (len == 0) null else read_only_memory_map.create(io, file, len) catch null;

        return .{
            .io = io,
            .file = file,
            .size = stat.size,
            .map = map,
        };
    }

    fn deinit(self: *CsrFileView) void {
        if (self.map) |*map| map.destroy(self.io);
        self.file.close(self.io);
    }

    fn mappedBytesAt(self: *CsrFileView, comptime len: usize, offset: u64) !?[]const u8 {
        return self.mappedBytesAtLen(len, offset);
    }

    fn mappedBytesAtLen(self: *CsrFileView, len: usize, offset: u64) !?[]const u8 {
        const end = std.math.add(u64, offset, len) catch return error.InvalidRecord;
        if (end > self.size) return error.InvalidRecord;
        const map = self.map orelse return null;
        const start = std.math.cast(usize, offset) orelse return error.RecordTooLarge;
        return map.memory[start .. start + len];
    }

    fn mappedRecordRangeAt(self: *CsrFileView, comptime record_len: usize, offset: u64, record_count: u64) !?[]const u8 {
        return self.mappedRecordRangeAtLen(record_len, offset, record_count);
    }

    fn mappedRecordRangeAtLen(self: *CsrFileView, record_len: usize, offset: u64, record_count: u64) !?[]const u8 {
        const byte_len = std.math.mul(u64, record_count, record_len) catch return error.RecordTooLarge;
        const end = std.math.add(u64, offset, byte_len) catch return error.InvalidRecord;
        if (end > self.size) return error.InvalidRecord;
        const map = self.map orelse return null;
        const start = std.math.cast(usize, offset) orelse return error.RecordTooLarge;
        const len = std.math.cast(usize, byte_len) orelse return error.RecordTooLarge;
        return map.memory[start .. start + len];
    }

    fn readAt(self: *CsrFileView, comptime len: usize, offset: u64) ![len]u8 {
        const end = std.math.add(u64, offset, len) catch return error.InvalidRecord;
        if (end > self.size) return error.InvalidRecord;
        var bytes: [len]u8 = undefined;
        const n = try self.file.readPositionalAll(self.io, &bytes, offset);
        if (n != bytes.len) return error.InvalidRecord;
        return bytes;
    }

    fn readInto(self: *CsrFileView, buffer: []u8, offset: u64) !void {
        const end = std.math.add(u64, offset, buffer.len) catch return error.InvalidRecord;
        if (end > self.size) return error.InvalidRecord;
        const n = try self.file.readPositionalAll(self.io, buffer, offset);
        if (n != buffer.len) return error.InvalidRecord;
    }
};

const CsrViewInfo = struct {
    header: SegmentHeader,
    edge_base: u64,
    validation: SegmentValidation,
    validation_complete: bool = false,
};

const csr_write_buffer_bytes: usize = 256 * 1024;
const csr_scan_buffer_bytes: usize = 256 * 1024;

const CsrBufferedWriter = struct {
    io: std.Io,
    file: std.Io.File,
    allocator: std.mem.Allocator,
    buffer: []u8,
    len: usize = 0,
    offset: u64 = 0,

    fn init(allocator: std.mem.Allocator, io: std.Io, file: std.Io.File, capacity: usize) !CsrBufferedWriter {
        std.debug.assert(capacity > 0);
        return .{
            .io = io,
            .file = file,
            .allocator = allocator,
            .buffer = try allocator.alloc(u8, capacity),
        };
    }

    fn deinit(self: *CsrBufferedWriter) void {
        self.allocator.free(self.buffer);
    }

    fn append(self: *CsrBufferedWriter, bytes: []const u8) !void {
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

    fn flush(self: *CsrBufferedWriter) !void {
        if (self.len == 0) return;
        try self.file.writePositionalAll(self.io, self.buffer[0..self.len], self.offset);
        self.offset = std.math.add(u64, self.offset, self.len) catch return error.RecordTooLarge;
        self.len = 0;
    }
};

pub const ImmutableAdjacencySegment = struct {
    pub const EdgeIdRange = struct {
        min: u64,
        max: u64,
    };

    pub const NodeIdRange = struct {
        min: u64,
        max: u64,
    };

    pub const EdgeIdSummary = struct {
        count: u64,
        range: EdgeIdRange,
        digest: u64,
    };

    pub const WrittenEdgeStreamSummary = struct {
        edge_count: u64,
        edge_digest: u64,
        edge_id_summary: EdgeIdSummary,
        node_range: NodeIdRange,
    };

    pub const EndpointSummary = struct {
        src_range: NodeIdRange,
        dst_range: NodeIdRange,
    };

    pub const WrittenSegmentSummary = struct {
        edge_count: u64,
        edge_digest: u64,
        edge_id_summary: EdgeIdSummary,
        endpoint_summary: EndpointSummary,
    };

    allocator: std.mem.Allocator,
    io: std.Io,
    dir_path: []u8,
    fwd_path: []u8,
    rev_path: []u8,
    fwd_view: ?CsrFileView = null,
    rev_view: ?CsrFileView = null,
    fwd_info: ?CsrViewInfo = null,
    rev_info: ?CsrViewInfo = null,

    pub fn build(
        allocator: std.mem.Allocator,
        io: std.Io,
        dir_path: []const u8,
        edges: []const EdgeRecord,
    ) !ImmutableAdjacencySegment {
        if (edges.len > std.math.maxInt(u32)) return error.RecordTooLarge;
        const order = try allocator.alloc(u32, edges.len);
        defer allocator.free(order);
        for (order, 0..) |*slot, index| slot.* = @intCast(index);

        std.mem.sort(u32, order, edges, edgeIndexIdLessThan);
        try validateEdgesSortedByIdOrder(edges, order);

        try std.Io.Dir.cwd().createDirPath(io, dir_path);
        var segment = try initPaths(allocator, io, dir_path);
        errdefer segment.deinit();

        const context = OrderedEdgeIndexReader{ .edges = edges, .order = order };
        std.mem.sort(u32, order, edges, edgeIndexForwardLessThan);
        const forward_validation = try writeCsrFileReader(segment, segment.fwd_path, .forward, @intCast(order.len), context, OrderedEdgeIndexReader.read);

        std.mem.sort(u32, order, edges, edgeIndexReverseLessThan);
        const reverse_validation = try writeCsrFileReader(segment, segment.rev_path, .reverse, @intCast(order.len), context, OrderedEdgeIndexReader.read);
        try segment.openWrittenViewsWithValidation(forward_validation, reverse_validation);
        return segment;
    }

    pub fn buildFromOrderedDirections(
        allocator: std.mem.Allocator,
        io: std.Io,
        dir_path: []const u8,
        forward: []const EdgeRecord,
        reverse: []const EdgeRecord,
    ) !ImmutableAdjacencySegment {
        try std.Io.Dir.cwd().createDirPath(io, dir_path);
        var segment = try initPaths(allocator, io, dir_path);
        errdefer segment.deinit();

        const forward_validation = try writeCsrFile(segment, segment.fwd_path, .forward, forward);
        const reverse_validation = try writeCsrFile(segment, segment.rev_path, .reverse, reverse);
        try segment.openWrittenViewsWithValidation(forward_validation, reverse_validation);
        return segment;
    }

    pub fn buildFromOrderedRecords(
        allocator: std.mem.Allocator,
        io: std.Io,
        dir_path: []const u8,
        comptime Record: type,
        forward: []const Record,
        reverse: []const Record,
        comptime toEdge: fn (Record) anyerror!EdgeRecord,
    ) !ImmutableAdjacencySegment {
        try std.Io.Dir.cwd().createDirPath(io, dir_path);
        var segment = try initPaths(allocator, io, dir_path);
        errdefer segment.deinit();

        const forward_validation = try writeCsrFileRecords(segment, segment.fwd_path, .forward, Record, forward, toEdge);
        const reverse_validation = try writeCsrFileRecords(segment, segment.rev_path, .reverse, Record, reverse, toEdge);
        try segment.openWrittenViewsWithValidation(forward_validation, reverse_validation);
        return segment;
    }

    pub fn initEmpty(allocator: std.mem.Allocator, io: std.Io, dir_path: []const u8) !ImmutableAdjacencySegment {
        try std.Io.Dir.cwd().createDirPath(io, dir_path);
        return try initPaths(allocator, io, dir_path);
    }

    pub fn writeOrderedRecords(
        self: ImmutableAdjacencySegment,
        direction: Direction,
        comptime Record: type,
        records: []const Record,
        comptime toEdge: fn (Record) anyerror!EdgeRecord,
    ) !void {
        const path = switch (direction) {
            .forward => self.fwd_path,
            .reverse => self.rev_path,
        };
        _ = try writeCsrFileRecords(self, path, direction, Record, records, toEdge);
    }

    pub fn writeOrderedRecordsSummary(
        self: ImmutableAdjacencySegment,
        direction: Direction,
        comptime Record: type,
        records: []const Record,
        comptime toEdge: fn (Record) anyerror!EdgeRecord,
    ) !WrittenEdgeStreamSummary {
        const path = switch (direction) {
            .forward => self.fwd_path,
            .reverse => self.rev_path,
        };
        return try writtenEdgeStreamSummaryFromValidation(try writeCsrFileRecords(self, path, direction, Record, records, toEdge));
    }

    pub fn writeOrderedRecordReader(
        self: ImmutableAdjacencySegment,
        direction: Direction,
        record_count: u64,
        context: anytype,
        comptime readEdgeAt: fn (@TypeOf(context), u64) anyerror!EdgeRecord,
    ) !void {
        const path = switch (direction) {
            .forward => self.fwd_path,
            .reverse => self.rev_path,
        };
        _ = try writeCsrFileReader(self, path, direction, record_count, context, readEdgeAt);
    }

    pub fn writeOrderedRecordReaderSummary(
        self: ImmutableAdjacencySegment,
        direction: Direction,
        record_count: u64,
        context: anytype,
        comptime readEdgeAt: fn (@TypeOf(context), u64) anyerror!EdgeRecord,
    ) !WrittenEdgeStreamSummary {
        const path = switch (direction) {
            .forward => self.fwd_path,
            .reverse => self.rev_path,
        };
        return try writtenEdgeStreamSummaryFromValidation(try writeCsrFileReader(self, path, direction, record_count, context, readEdgeAt));
    }

    pub fn writeOrderedEdgeStream(
        self: ImmutableAdjacencySegment,
        direction: Direction,
        record_count: u64,
        context: anytype,
        comptime reset: fn (@TypeOf(context)) anyerror!void,
        comptime next: fn (@TypeOf(context)) anyerror!?EdgeRecord,
    ) !void {
        const path = switch (direction) {
            .forward => self.fwd_path,
            .reverse => self.rev_path,
        };
        _ = try writeCsrFileStream(self, path, direction, record_count, true, context, reset, next);
    }

    pub fn writeTrustedOrderedEdgeStreamSummary(
        self: ImmutableAdjacencySegment,
        direction: Direction,
        record_count: u64,
        context: anytype,
        comptime reset: fn (@TypeOf(context)) anyerror!void,
        comptime next: fn (@TypeOf(context)) anyerror!?EdgeRecord,
    ) !WrittenEdgeStreamSummary {
        const path = switch (direction) {
            .forward => self.fwd_path,
            .reverse => self.rev_path,
        };
        const validation = try writeCsrFileStream(self, path, direction, record_count, false, context, reset, next);
        return try writtenEdgeStreamSummaryFromValidation(validation);
    }

    pub fn openWrittenViewsWithSummaries(
        self: *ImmutableAdjacencySegment,
        forward_summary: WrittenEdgeStreamSummary,
        reverse_summary: WrittenEdgeStreamSummary,
    ) !void {
        try self.openWrittenViewsWithValidation(
            try validationFromWrittenEdgeStreamSummary(forward_summary),
            try validationFromWrittenEdgeStreamSummary(reverse_summary),
        );
    }

    pub fn summarizeWrittenEdgeStreams(
        forward_summary: WrittenEdgeStreamSummary,
        reverse_summary: WrittenEdgeStreamSummary,
    ) !WrittenSegmentSummary {
        if (forward_summary.edge_count == 0 or reverse_summary.edge_count == 0) return error.InvalidRecord;
        if (forward_summary.edge_count != reverse_summary.edge_count) return error.InvalidRecord;
        if (forward_summary.edge_digest != reverse_summary.edge_digest) return error.InvalidRecord;
        if (forward_summary.edge_id_summary.count != forward_summary.edge_count) return error.InvalidRecord;
        if (reverse_summary.edge_id_summary.count != reverse_summary.edge_count) return error.InvalidRecord;
        if (forward_summary.edge_id_summary.digest != reverse_summary.edge_id_summary.digest) return error.InvalidRecord;
        if (forward_summary.edge_id_summary.range.min != reverse_summary.edge_id_summary.range.min) return error.InvalidRecord;
        if (forward_summary.edge_id_summary.range.max != reverse_summary.edge_id_summary.range.max) return error.InvalidRecord;
        return .{
            .edge_count = forward_summary.edge_count,
            .edge_digest = forward_summary.edge_digest,
            .edge_id_summary = forward_summary.edge_id_summary,
            .endpoint_summary = .{
                .src_range = forward_summary.node_range,
                .dst_range = reverse_summary.node_range,
            },
        };
    }

    pub fn openWrittenViews(self: *ImmutableAdjacencySegment) !void {
        try self.openViews();
    }

    pub fn open(allocator: std.mem.Allocator, io: std.Io, dir_path: []const u8) !ImmutableAdjacencySegment {
        var segment = try initPaths(allocator, io, dir_path);
        errdefer segment.deinit();
        try segment.openViews();
        return segment;
    }

    pub fn openTrustedForQuery(allocator: std.mem.Allocator, io: std.Io, dir_path: []const u8, expected_edge_count: u64) !ImmutableAdjacencySegment {
        var segment = try initPaths(allocator, io, dir_path);
        errdefer segment.deinit();
        try segment.openTrustedViews(expected_edge_count);
        return segment;
    }

    pub fn openTrustedDirectionForQuery(
        allocator: std.mem.Allocator,
        io: std.Io,
        dir_path: []const u8,
        direction: Direction,
        expected_edge_count: u64,
    ) !ImmutableAdjacencySegment {
        var segment = try initPaths(allocator, io, dir_path);
        errdefer segment.deinit();
        try segment.openTrustedView(direction, expected_edge_count);
        return segment;
    }

    pub fn deinit(self: *ImmutableAdjacencySegment) void {
        if (self.rev_view) |*view| view.deinit();
        if (self.fwd_view) |*view| view.deinit();
        self.allocator.free(self.rev_path);
        self.allocator.free(self.fwd_path);
        self.allocator.free(self.dir_path);
    }

    pub fn edgeCount(self: ImmutableAdjacencySegment) !u64 {
        const forward = self.fwd_info orelse return error.InvalidRecord;
        const reverse = self.rev_info orelse return error.InvalidRecord;
        if (forward.header.edge_count != reverse.header.edge_count) return error.InvalidRecord;
        return forward.header.edge_count;
    }

    pub fn relationDirectoryBytes(self: ImmutableAdjacencySegment, direction: Direction) !u64 {
        const info = switch (direction) {
            .forward => self.fwd_info,
            .reverse => self.rev_info,
        } orelse return error.InvalidRecord;
        return std.math.mul(u64, info.header.relation_count, info.header.relationRecordLen()) catch return error.RecordTooLarge;
    }

    pub fn edgeDigest(self: ImmutableAdjacencySegment) !u64 {
        const forward = self.fwd_info orelse return error.InvalidRecord;
        const reverse = self.rev_info orelse return error.InvalidRecord;
        if (!forward.validation_complete or !reverse.validation_complete) return error.InvalidRecord;
        if (!forward.validation.eql(reverse.validation)) return error.InvalidRecord;
        return forward.validation.edge_digest;
    }

    pub fn edgeIdRange(self: ImmutableAdjacencySegment) !?EdgeIdRange {
        const summary = (try self.edgeIdSummary()) orelse return null;
        return summary.range;
    }

    pub fn edgeIdSummary(self: ImmutableAdjacencySegment) !?EdgeIdSummary {
        const forward = self.fwd_info orelse return error.InvalidRecord;
        const reverse = self.rev_info orelse return error.InvalidRecord;
        if (!forward.validation_complete or !reverse.validation_complete) return error.InvalidRecord;
        if (!forward.validation.eql(reverse.validation)) return error.InvalidRecord;
        if (forward.validation.edge_count == 0) return null;
        return .{
            .count = forward.validation.edge_count,
            .range = .{
                .min = forward.validation.edge_id_min,
                .max = forward.validation.edge_id_max,
            },
            .digest = forward.validation.edge_id_digest,
        };
    }

    pub fn endpointSummary(self: ImmutableAdjacencySegment) !EndpointSummary {
        const forward = self.fwd_info orelse return error.InvalidRecord;
        const reverse = self.rev_info orelse return error.InvalidRecord;
        if (!forward.validation_complete or !reverse.validation_complete) return error.InvalidRecord;
        if (forward.validation.edge_count == 0 or reverse.validation.edge_count == 0) return error.InvalidRecord;
        return .{
            .src_range = .{
                .min = forward.validation.node_id_min,
                .max = forward.validation.node_id_max,
            },
            .dst_range = .{
                .min = reverse.validation.node_id_min,
                .max = reverse.validation.node_id_max,
            },
        };
    }

    pub fn mayContainEdgeId(self: ImmutableAdjacencySegment, edge_id: u64) !bool {
        const range = (try self.edgeIdRange()) orelse return false;
        return edge_id >= range.min and edge_id <= range.max;
    }

    pub fn edgeIdRangeMayIntersect(self: ImmutableAdjacencySegment, min_edge_id: u64, max_edge_id: u64) !bool {
        const range = (try self.edgeIdRange()) orelse return false;
        return max_edge_id >= range.min and min_edge_id <= range.max;
    }

    fn openViews(self: *ImmutableAdjacencySegment) !void {
        std.debug.assert(self.fwd_view == null);
        std.debug.assert(self.rev_view == null);

        var forward_view = try CsrFileView.open(self.io, self.fwd_path);
        errdefer forward_view.deinit();
        var reverse_view = try CsrFileView.open(self.io, self.rev_path);
        errdefer reverse_view.deinit();

        const forward = try validateCsrView(self, &forward_view, .forward);
        const reverse = try validateCsrView(self, &reverse_view, .reverse);
        if (!forward.validation.eql(reverse.validation)) return error.InvalidRecord;

        self.fwd_info = .{
            .header = forward.header,
            .edge_base = forward.edge_base,
            .validation = forward.validation,
            .validation_complete = true,
        };
        self.rev_info = .{
            .header = reverse.header,
            .edge_base = reverse.edge_base,
            .validation = reverse.validation,
            .validation_complete = true,
        };
        self.fwd_view = forward_view;
        self.rev_view = reverse_view;
    }

    fn openTrustedViews(self: *ImmutableAdjacencySegment, expected_edge_count: u64) !void {
        std.debug.assert(self.fwd_view == null);
        std.debug.assert(self.rev_view == null);

        var forward_view = try CsrFileView.open(self.io, self.fwd_path);
        errdefer forward_view.deinit();
        var reverse_view = try CsrFileView.open(self.io, self.rev_path);
        errdefer reverse_view.deinit();

        const forward = try trustCsrViewHeader(&forward_view, .forward, expected_edge_count);
        const reverse = try trustCsrViewHeader(&reverse_view, .reverse, expected_edge_count);

        self.fwd_info = forward;
        self.rev_info = reverse;
        self.fwd_view = forward_view;
        self.rev_view = reverse_view;
    }

    fn openWrittenViewsWithValidation(
        self: *ImmutableAdjacencySegment,
        forward_validation: SegmentValidation,
        reverse_validation: SegmentValidation,
    ) !void {
        std.debug.assert(self.fwd_view == null);
        std.debug.assert(self.rev_view == null);
        if (!forward_validation.eql(reverse_validation)) return error.InvalidRecord;

        var forward_view = try CsrFileView.open(self.io, self.fwd_path);
        errdefer forward_view.deinit();
        var reverse_view = try CsrFileView.open(self.io, self.rev_path);
        errdefer reverse_view.deinit();

        var forward = try trustCsrViewHeader(&forward_view, .forward, forward_validation.edge_count);
        var reverse = try trustCsrViewHeader(&reverse_view, .reverse, reverse_validation.edge_count);
        forward.validation = forward_validation;
        forward.validation_complete = true;
        reverse.validation = reverse_validation;
        reverse.validation_complete = true;

        self.fwd_info = forward;
        self.rev_info = reverse;
        self.fwd_view = forward_view;
        self.rev_view = reverse_view;
    }

    fn openTrustedView(self: *ImmutableAdjacencySegment, direction: Direction, expected_edge_count: u64) !void {
        std.debug.assert(self.fwd_view == null);
        std.debug.assert(self.rev_view == null);

        switch (direction) {
            .forward => {
                var forward_view = try CsrFileView.open(self.io, self.fwd_path);
                errdefer forward_view.deinit();
                const forward = try trustCsrViewHeader(&forward_view, .forward, expected_edge_count);
                self.fwd_info = forward;
                self.fwd_view = forward_view;
            },
            .reverse => {
                var reverse_view = try CsrFileView.open(self.io, self.rev_path);
                errdefer reverse_view.deinit();
                const reverse = try trustCsrViewHeader(&reverse_view, .reverse, expected_edge_count);
                self.rev_info = reverse;
                self.rev_view = reverse_view;
            },
        }
    }

    pub fn neighbors(
        self: *ImmutableAdjacencySegment,
        allocator: std.mem.Allocator,
        direction: Direction,
        node_id: core.NodeId,
        rel_filter: ?core.RelKind,
        max_edges: usize,
    ) !std.ArrayList(EdgeRecord) {
        var out = std.ArrayList(EdgeRecord).empty;
        errdefer out.deinit(allocator);

        var context = NeighborCollectContext{
            .allocator = allocator,
            .out = &out,
        };
        _ = try self.forEachNeighbor(direction, node_id, rel_filter, max_edges, &context, collectNeighbor);
        return out;
    }

    pub fn forEachNeighbor(
        self: *ImmutableAdjacencySegment,
        direction: Direction,
        node_id: core.NodeId,
        rel_filter: ?core.RelKind,
        max_edges: usize,
        context: anytype,
        comptime callback: fn (@TypeOf(context), EdgeRecord) anyerror!bool,
    ) !bool {
        if (node_id == .none or node_id.toInt() == std.math.maxInt(u64)) return core.Error.InvalidId;

        const view = self.viewForDirection(direction);
        const info = self.infoForDirection(direction);
        const header = try self.validateCachedHeader(view, info, direction);

        const vertex = (try self.findVertex(view, header, node_id.toInt())) orelse return false;
        const edge_base = info.edge_base;
        var emitted: usize = 0;
        if (rel_filter) |rel| {
            const relation = (try self.findRelation(view, header, vertex, rel)) orelse return false;
            return try self.forEachEdgeFromRange(view, header, direction, edge_base, vertex.node_id, relation, max_edges, &emitted, context, callback);
        } else {
            var pos: u64 = 0;
            var relation_edge_offset = vertex.edge_offset;
            while (pos < vertex.relation_count) : (pos += 1) {
                const relation = try self.readRelationAt(view, header, vertex.relation_offset + pos, relation_edge_offset);
                if (try self.forEachEdgeFromRange(view, header, direction, edge_base, vertex.node_id, relation, max_edges, &emitted, context, callback)) return true;
                relation_edge_offset = std.math.add(u64, relation_edge_offset, relation.edge_count) catch return error.InvalidRecord;
            }
            return false;
        }
    }

    pub const NeighborIterator = struct {
        segment: *ImmutableAdjacencySegment,
        direction: Direction,
        view: *CsrFileView,
        header: SegmentHeader,
        edge_base: u64,
        vertex: VertexRecord,
        relation_pos: u64 = 0,
        relation_count: u64,
        next_relation_edge_offset: u64 = 0,
        current_edge: u64 = 0,
        current_edge_end: u64 = 0,
        current_relation_rel: u16 = 0,
        exhausted: bool = false,

        pub fn next(self: *NeighborIterator) !?EdgeRecord {
            if (self.exhausted) return null;
            while (self.current_edge >= self.current_edge_end) {
                if (!try self.loadNextRelation()) {
                    self.exhausted = true;
                    return null;
                }
            }
            const record = try self.segment.readStoredEdgeAt(self.view, self.header, self.edge_base, self.current_edge);
            self.current_edge += 1;
            return try record.toEdgeInRelation(self.direction, self.vertex.node_id, self.current_relation_rel);
        }

        fn loadNextRelation(self: *NeighborIterator) !bool {
            if (self.relation_pos >= self.relation_count) return false;
            const relation = try self.segment.readRelationAt(self.view, self.header, self.vertex.relation_offset + self.relation_pos, self.next_relation_edge_offset);
            self.relation_pos += 1;
            self.current_edge = relation.edge_offset;
            self.current_edge_end = std.math.add(u64, relation.edge_offset, relation.edge_count) catch return error.InvalidRecord;
            self.current_relation_rel = relation.rel;
            self.next_relation_edge_offset = std.math.add(u64, self.next_relation_edge_offset, relation.edge_count) catch return error.InvalidRecord;
            return true;
        }
    };

    pub const EdgeIterator = struct {
        segment: *ImmutableAdjacencySegment,
        direction: Direction,
        view: *CsrFileView,
        header: SegmentHeader,
        edge_base: u64,
        vertex_pos: u64 = 0,
        relation_pos: u64 = 0,
        next_relation_edge_offset: u64 = 0,
        current_edge: u64 = 0,
        current_edge_end: u64 = 0,
        current_owner_node: u64 = 0,
        current_relation_rel: u16 = 0,
        exhausted: bool = false,

        pub fn next(self: *EdgeIterator) !?EdgeRecord {
            if (self.exhausted) return null;
            while (self.current_edge >= self.current_edge_end) {
                if (!try self.loadNextRelation()) {
                    self.exhausted = true;
                    return null;
                }
            }
            const record = try self.segment.readStoredEdgeAt(self.view, self.header, self.edge_base, self.current_edge);
            self.current_edge += 1;
            return try record.toEdgeInRelation(self.direction, self.current_owner_node, self.current_relation_rel);
        }

        fn loadNextRelation(self: *EdgeIterator) !bool {
            while (self.vertex_pos < self.header.vertex_count) {
                const vertex = try self.segment.readVertexAt(self.view, self.header, self.vertex_pos);
                if (self.relation_pos < vertex.relation_count) {
                    if (self.relation_pos == 0) self.next_relation_edge_offset = vertex.edge_offset;
                    const relation = try self.segment.readRelationAt(self.view, self.header, vertex.relation_offset + self.relation_pos, self.next_relation_edge_offset);
                    self.relation_pos += 1;
                    self.current_owner_node = vertex.node_id;
                    self.current_relation_rel = relation.rel;
                    self.current_edge = relation.edge_offset;
                    self.current_edge_end = std.math.add(u64, relation.edge_offset, relation.edge_count) catch return error.InvalidRecord;
                    self.next_relation_edge_offset = std.math.add(u64, self.next_relation_edge_offset, relation.edge_count) catch return error.InvalidRecord;
                    return true;
                }
                self.vertex_pos += 1;
                self.relation_pos = 0;
            }
            return false;
        }
    };

    pub fn edgeIterator(self: *ImmutableAdjacencySegment, direction: Direction) !EdgeIterator {
        const view = self.viewForDirection(direction);
        const info = self.infoForDirection(direction);
        const header = try self.validateCachedHeader(view, info, direction);
        return .{
            .segment = self,
            .direction = direction,
            .view = view,
            .header = header,
            .edge_base = info.edge_base,
        };
    }

    pub fn neighborIterator(
        self: *ImmutableAdjacencySegment,
        direction: Direction,
        node_id: core.NodeId,
        rel_filter: ?core.RelKind,
    ) !?NeighborIterator {
        if (node_id == .none or node_id.toInt() == std.math.maxInt(u64)) return core.Error.InvalidId;

        const view = self.viewForDirection(direction);
        const info = self.infoForDirection(direction);
        const header = try self.validateCachedHeader(view, info, direction);
        const vertex = (try self.findVertex(view, header, node_id.toInt())) orelse return null;
        if (rel_filter) |rel| {
            const relation = (try self.findRelation(view, header, vertex, rel)) orelse return null;
            const next_relation_edge_offset = std.math.add(u64, relation.edge_offset, relation.edge_count) catch return error.InvalidRecord;
            return .{
                .segment = self,
                .direction = direction,
                .view = view,
                .header = header,
                .edge_base = info.edge_base,
                .vertex = .{
                    .node_id = vertex.node_id,
                    .relation_offset = vertex.relation_offset,
                    .relation_count = 1,
                    .edge_offset = relation.edge_offset,
                },
                .relation_pos = 1,
                .relation_count = 1,
                .next_relation_edge_offset = next_relation_edge_offset,
                .current_edge = relation.edge_offset,
                .current_edge_end = next_relation_edge_offset,
                .current_relation_rel = relation.rel,
            };
        }
        return .{
            .segment = self,
            .direction = direction,
            .view = view,
            .header = header,
            .edge_base = info.edge_base,
            .vertex = vertex,
            .relation_count = vertex.relation_count,
            .next_relation_edge_offset = vertex.edge_offset,
        };
    }

    fn viewForDirection(self: *ImmutableAdjacencySegment, direction: Direction) *CsrFileView {
        return switch (direction) {
            .forward => &self.fwd_view.?,
            .reverse => &self.rev_view.?,
        };
    }

    fn infoForDirection(self: *ImmutableAdjacencySegment, direction: Direction) CsrViewInfo {
        return switch (direction) {
            .forward => self.fwd_info.?,
            .reverse => self.rev_info.?,
        };
    }

    fn validateCachedHeader(_: *ImmutableAdjacencySegment, view: *CsrFileView, info: CsrViewInfo, direction: Direction) !SegmentHeader {
        const header = try readHeader(view);
        if (header.order != direction) return error.InvalidRecord;
        if (header.edge_count != info.header.edge_count or
            header.vertex_count != info.header.vertex_count or
            header.relation_count != info.header.relation_count)
        {
            return error.InvalidRecord;
        }
        return header;
    }

    fn findVertex(self: *ImmutableAdjacencySegment, view: *CsrFileView, header: SegmentHeader, node_id: u64) !?VertexRecord {
        var lo: u64 = 0;
        var hi: u64 = header.vertex_count;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const record = try self.readVertexAt(view, header, mid);
            if (record.node_id < node_id) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        if (lo >= header.vertex_count) return null;
        const record = try self.readVertexAt(view, header, lo);
        if (record.node_id != node_id) return null;
        return record;
    }

    fn readVertexAt(_: *ImmutableAdjacencySegment, view: *CsrFileView, header: SegmentHeader, index: u64) !VertexRecord {
        const offset = try vertexRecordOffsetForHeader(header, index);
        const vertex_record_len = header.vertexRecordLen();
        if (vertex_record_len == 0) return try VertexRecord.decodeForHeaderAt(header, index, &.{});
        if (vertex_record_len <= VertexRecord.u32_encoded_len) {
            var buffer: [VertexRecord.u32_encoded_len]u8 = undefined;
            if (try view.mappedBytesAtLen(vertex_record_len, offset)) |bytes| {
                return try VertexRecord.decodeForHeaderAt(header, index, bytes);
            }
            try view.readInto(buffer[0..vertex_record_len], offset);
            return try VertexRecord.decodeForHeaderAt(header, index, buffer[0..vertex_record_len]);
        }
        if (try view.mappedBytesAtLen(vertex_record_len, offset)) |bytes| {
            return try VertexRecord.decodeForHeaderAt(header, index, bytes);
        }
        var buffer: [VertexRecord.encoded_len]u8 = undefined;
        try view.readInto(buffer[0..vertex_record_len], offset);
        return try VertexRecord.decodeForHeaderAt(header, index, buffer[0..vertex_record_len]);
    }

    fn findRelation(self: *ImmutableAdjacencySegment, view: *CsrFileView, header: SegmentHeader, vertex: VertexRecord, rel: core.RelKind) !?RelationRangeRecord {
        const rel_value: u16 = @intFromEnum(rel);
        var lo: u64 = 0;
        var hi: u64 = vertex.relation_count;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            const record = try self.readRelationAt(view, header, vertex.relation_offset + mid, 0);
            if (record.rel < rel_value) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        if (lo >= vertex.relation_count) return null;
        const relation_edge_offset = try self.relationEdgeOffsetAt(view, header, vertex, lo);
        const record = try self.readRelationAt(view, header, vertex.relation_offset + lo, relation_edge_offset);
        if (record.rel != rel_value) return null;
        return record;
    }

    fn relationEdgeOffsetAt(self: *ImmutableAdjacencySegment, view: *CsrFileView, header: SegmentHeader, vertex: VertexRecord, relation_pos: u64) !u64 {
        var edge_offset = vertex.edge_offset;
        var pos: u64 = 0;
        while (pos < relation_pos) : (pos += 1) {
            const relation = try self.readRelationAt(view, header, vertex.relation_offset + pos, 0);
            edge_offset = std.math.add(u64, edge_offset, relation.edge_count) catch return error.InvalidRecord;
        }
        return edge_offset;
    }

    fn readRelationAt(self: *ImmutableAdjacencySegment, view: *CsrFileView, header: SegmentHeader, index: u64, edge_offset: u64) !RelationRangeRecord {
        if (header.hasSingleRelationPerVertex()) {
            if (index >= header.vertex_count) return error.InvalidRecord;
            if (header.hasUniformSingleRelationEdgeCount()) {
                const current_edge_offset = try uniformSingleRelationEdgeOffset(header, index);
                const rel = if (header.hasUniformRelation()) header.uniform_relation else rel: {
                    const current_vertex = try self.readVertexAt(view, header, index);
                    break :rel current_vertex.single_relation_rel;
                };
                if (relFromInt(rel) == null) return error.InvalidRecord;
                return .{
                    .rel = rel,
                    .edge_offset = current_edge_offset,
                    .edge_count = header.uniform_single_relation_edge_count,
                };
            }
            const next_edge_offset = if (index + 1 < header.vertex_count) next: {
                const next_vertex = try self.readVertexAt(view, header, index + 1);
                break :next next_vertex.edge_offset;
            } else header.edge_count;
            const current_edge_offset, const rel = if (header.hasUniformRelation()) .{
                edge_offset,
                header.uniform_relation,
            } else current: {
                const current_vertex = try self.readVertexAt(view, header, index);
                break :current .{ current_vertex.edge_offset, current_vertex.single_relation_rel };
            };
            if (next_edge_offset <= current_edge_offset) return error.InvalidRecord;
            if (relFromInt(rel) == null) return error.InvalidRecord;
            return .{
                .rel = rel,
                .edge_offset = current_edge_offset,
                .edge_count = next_edge_offset - current_edge_offset,
            };
        }
        const offset = try relationRecordOffset(header, index);
        var record: RelationRangeRecord = undefined;
        const relation_record_len: usize = header.relationRecordLen();
        if (try view.mappedBytesAtLen(relation_record_len, offset)) |bytes| {
            record = try RelationRangeRecord.decodeForHeader(header, bytes);
        } else {
            var bytes: [RelationRangeRecord.encoded_len]u8 = undefined;
            try view.readInto(bytes[0..relation_record_len], offset);
            record = try RelationRangeRecord.decodeForHeader(header, bytes[0..relation_record_len]);
        }
        if (relFromInt(record.rel) == null) return error.InvalidRecord;
        record.edge_offset = edge_offset;
        return record;
    }

    fn forEachEdgeFromRange(
        self: *ImmutableAdjacencySegment,
        view: *CsrFileView,
        header: SegmentHeader,
        direction: Direction,
        edge_base: u64,
        owner_node: u64,
        relation: RelationRangeRecord,
        max_edges: usize,
        emitted: *usize,
        context: anytype,
        comptime callback: fn (@TypeOf(context), EdgeRecord) anyerror!bool,
    ) !bool {
        if (relation.edge_count == 0) return false;
        if (emitted.* >= max_edges) return core.Error.BudgetExceeded;
        const remaining_budget: u64 = @intCast(max_edges - emitted.*);
        const scan_count = @min(relation.edge_count, remaining_budget);
        const edge_record_len: usize = header.edge_record_len;
        if (edge_record_len == 0) {
            var index = relation.edge_offset;
            const end = relation.edge_offset + scan_count;
            while (index < end) : (index += 1) {
                const record = try StoredEdgeRecord.decodeForHeaderAt(header, index, &.{});
                emitted.* += 1;
                if (try callback(context, try record.toEdgeInRelation(direction, owner_node, relation.rel))) return true;
            }
            if (scan_count < relation.edge_count) return core.Error.BudgetExceeded;
            return false;
        }
        const range_offset = try storedEdgeRangeOffset(edge_base, relation.edge_offset, edge_record_len);
        if (try view.mappedRecordRangeAtLen(edge_record_len, range_offset, scan_count)) |bytes| {
            var cursor: usize = 0;
            var index = relation.edge_offset;
            while (cursor < bytes.len) : (cursor += edge_record_len) {
                const record = try StoredEdgeRecord.decodeForHeaderAt(header, index, bytes[cursor .. cursor + edge_record_len]);
                index += 1;
                emitted.* += 1;
                if (try callback(context, try record.toEdgeInRelation(direction, owner_node, relation.rel))) return true;
            }
            if (scan_count < relation.edge_count) return core.Error.BudgetExceeded;
            return false;
        }

        if (try self.forEachUnmappedEdgeRange(view, header, direction, range_offset, relation.edge_offset, owner_node, relation.rel, scan_count, emitted, context, callback)) return true;
        if (scan_count < relation.edge_count) return core.Error.BudgetExceeded;
        return false;
    }

    fn forEachUnmappedEdgeRange(
        self: *ImmutableAdjacencySegment,
        view: *CsrFileView,
        header: SegmentHeader,
        direction: Direction,
        range_offset: u64,
        edge_start: u64,
        owner_node: u64,
        relation_rel: u16,
        record_count: u64,
        emitted: *usize,
        context: anytype,
        comptime callback: fn (@TypeOf(context), EdgeRecord) anyerror!bool,
    ) !bool {
        if (record_count == 0) return false;
        const edge_record_len: usize = header.edge_record_len;
        const max_buffer_records = @max(@as(usize, 1), csr_scan_buffer_bytes / edge_record_len);
        const scan_count = std.math.cast(usize, record_count) orelse return error.RecordTooLarge;
        const buffer_records = @min(max_buffer_records, scan_count);
        const buffer_len = std.math.mul(usize, buffer_records, edge_record_len) catch return error.RecordTooLarge;
        var buffer = try self.allocator.alloc(u8, buffer_len);
        defer self.allocator.free(buffer);

        var remaining = record_count;
        var offset = range_offset;
        var index = edge_start;
        while (remaining > 0) {
            const records_this_chunk = @min(remaining, @as(u64, @intCast(buffer_records)));
            const records_this_chunk_usize = std.math.cast(usize, records_this_chunk) orelse return error.RecordTooLarge;
            const bytes_this_chunk = std.math.mul(usize, records_this_chunk_usize, edge_record_len) catch return error.RecordTooLarge;
            if (try view.file.readPositionalAll(view.io, buffer[0..bytes_this_chunk], offset) != bytes_this_chunk) return error.InvalidRecord;

            var cursor: usize = 0;
            while (cursor < bytes_this_chunk) : (cursor += edge_record_len) {
                const record = try StoredEdgeRecord.decodeForHeaderAt(header, index, buffer[cursor .. cursor + edge_record_len]);
                index += 1;
                emitted.* += 1;
                if (try callback(context, try record.toEdgeInRelation(direction, owner_node, relation_rel))) return true;
            }
            remaining -= records_this_chunk;
            offset = std.math.add(u64, offset, bytes_this_chunk) catch return error.RecordTooLarge;
        }
        return false;
    }

    fn readStoredEdgeAt(_: *ImmutableAdjacencySegment, view: *CsrFileView, header: SegmentHeader, edge_base: u64, index: u64) !StoredEdgeRecord {
        const edge_record_len: usize = header.edge_record_len;
        if (edge_record_len == 0) return try StoredEdgeRecord.decodeForHeaderAt(header, index, &.{});
        const byte_index = std.math.mul(u64, index, edge_record_len) catch return error.RecordTooLarge;
        const offset = std.math.add(u64, edge_base, byte_index) catch return error.RecordTooLarge;
        if (try view.mappedBytesAtLen(edge_record_len, offset)) |bytes| {
            return try StoredEdgeRecord.decodeForHeaderAt(header, index, bytes);
        }
        var bytes: [StoredEdgeRecord.encoded_len]u8 = undefined;
        try view.readInto(bytes[0..edge_record_len], offset);
        return try StoredEdgeRecord.decodeForHeaderAt(header, index, bytes[0..edge_record_len]);
    }
};

fn initPaths(allocator: std.mem.Allocator, io: std.Io, dir_path: []const u8) !ImmutableAdjacencySegment {
    const owned_dir = try allocator.dupe(u8, dir_path);
    errdefer allocator.free(owned_dir);
    const fwd_path = try std.fs.path.join(allocator, &.{ owned_dir, "edge_fwd.csr" });
    errdefer allocator.free(fwd_path);
    const rev_path = try std.fs.path.join(allocator, &.{ owned_dir, "edge_rev.csr" });
    errdefer allocator.free(rev_path);
    return .{
        .allocator = allocator,
        .io = io,
        .dir_path = owned_dir,
        .fwd_path = fwd_path,
        .rev_path = rev_path,
    };
}

const NeighborCollectContext = struct {
    allocator: std.mem.Allocator,
    out: *std.ArrayList(EdgeRecord),
};

fn collectNeighbor(context: *NeighborCollectContext, edge: EdgeRecord) !bool {
    try context.out.append(context.allocator, edge);
    return false;
}

fn validateEdgesSortedById(edges_by_id: []const EdgeRecord) !void {
    var previous_edge_id: u64 = 0;
    for (edges_by_id, 0..) |edge, index| {
        const src = edge.src.toInt();
        const dst = edge.dst.toInt();
        const edge_id = edge.edge_id.toInt();
        if (src == 0 or dst == 0 or edge_id == 0) return core.Error.InvalidId;
        if (src == std.math.maxInt(u64) or dst == std.math.maxInt(u64) or edge_id == std.math.maxInt(u64)) return core.Error.InvalidId;
        if (index != 0 and edge_id <= previous_edge_id) return core.Error.InvalidId;
        previous_edge_id = edge_id;
    }
}

fn validateEdgesSortedByIdOrder(edges: []const EdgeRecord, order: []const u32) !void {
    if (edges.len != order.len) return error.InvalidRecord;
    var previous_edge_id: u64 = 0;
    for (order, 0..) |edge_index, index| {
        const edge_pos: usize = @intCast(edge_index);
        if (edge_pos >= edges.len) return error.InvalidRecord;
        const edge = edges[edge_pos];
        const src = edge.src.toInt();
        const dst = edge.dst.toInt();
        const edge_id = edge.edge_id.toInt();
        if (src == 0 or dst == 0 or edge_id == 0) return core.Error.InvalidId;
        if (src == std.math.maxInt(u64) or dst == std.math.maxInt(u64) or edge_id == std.math.maxInt(u64)) return core.Error.InvalidId;
        if (index != 0 and edge_id <= previous_edge_id) return core.Error.InvalidId;
        previous_edge_id = edge_id;
    }
}

fn edgeRecordIdentity(edge: EdgeRecord) !EdgeRecord {
    return edge;
}

const OrderedEdgeIndexReader = struct {
    edges: []const EdgeRecord,
    order: []const u32,

    fn read(context: OrderedEdgeIndexReader, index: u64) !EdgeRecord {
        const pos = std.math.cast(usize, index) orelse return error.RecordTooLarge;
        if (pos >= context.order.len) return error.InvalidRecord;
        const edge_index = context.order[pos];
        const edge_pos: usize = @intCast(edge_index);
        if (edge_pos >= context.edges.len) return error.InvalidRecord;
        return context.edges[edge_pos];
    }
};

fn writeCsrFile(segment: ImmutableAdjacencySegment, path: []const u8, direction: Direction, edges: []const EdgeRecord) !SegmentValidation {
    return writeCsrFileRecords(segment, path, direction, EdgeRecord, edges, edgeRecordIdentity);
}

fn writeCsrFileRecords(
    segment: ImmutableAdjacencySegment,
    path: []const u8,
    direction: Direction,
    comptime Record: type,
    records: []const Record,
    comptime toEdge: fn (Record) anyerror!EdgeRecord,
) !SegmentValidation {
    const SliceContext = struct {
        records: []const Record,
        toEdge: *const fn (Record) anyerror!EdgeRecord,
    };
    const SliceReader = struct {
        fn read(context: SliceContext, index: u64) !EdgeRecord {
            const pos = std.math.cast(usize, index) orelse return error.RecordTooLarge;
            if (pos >= context.records.len) return error.InvalidRecord;
            return try context.toEdge(context.records[pos]);
        }
    };
    return writeCsrFileReader(segment, path, direction, @intCast(records.len), SliceContext{
        .records = records,
        .toEdge = toEdge,
    }, SliceReader.read);
}

fn writtenEdgeStreamSummaryFromValidation(validation: SegmentValidation) !ImmutableAdjacencySegment.WrittenEdgeStreamSummary {
    if (validation.edge_count == 0) return error.InvalidRecord;
    return .{
        .edge_count = validation.edge_count,
        .edge_digest = validation.edge_digest,
        .edge_id_summary = .{
            .count = validation.edge_count,
            .range = .{
                .min = validation.edge_id_min,
                .max = validation.edge_id_max,
            },
            .digest = validation.edge_id_digest,
        },
        .node_range = .{
            .min = validation.node_id_min,
            .max = validation.node_id_max,
        },
    };
}

fn validationFromWrittenEdgeStreamSummary(summary: ImmutableAdjacencySegment.WrittenEdgeStreamSummary) !SegmentValidation {
    if (summary.edge_count == 0) return error.InvalidRecord;
    if (summary.edge_id_summary.count != summary.edge_count) return error.InvalidRecord;
    if (summary.edge_id_summary.range.min == 0 or summary.edge_id_summary.range.max == 0) return error.InvalidRecord;
    if (summary.edge_id_summary.range.min > summary.edge_id_summary.range.max) return error.InvalidRecord;
    if (summary.edge_id_summary.range.max == std.math.maxInt(u64)) return error.InvalidRecord;
    if (summary.node_range.min == 0 or summary.node_range.max == 0) return error.InvalidRecord;
    if (summary.node_range.min > summary.node_range.max) return error.InvalidRecord;
    if (summary.node_range.max == std.math.maxInt(u64)) return error.InvalidRecord;
    return .{
        .edge_count = summary.edge_count,
        .edge_digest = summary.edge_digest,
        .edge_id_min = summary.edge_id_summary.range.min,
        .edge_id_max = summary.edge_id_summary.range.max,
        .edge_id_digest = summary.edge_id_summary.digest,
        .node_id_min = summary.node_range.min,
        .node_id_max = summary.node_range.max,
    };
}

fn writeCsrFileReader(
    segment: ImmutableAdjacencySegment,
    path: []const u8,
    direction: Direction,
    record_count: u64,
    context: anytype,
    comptime readEdgeAt: fn (@TypeOf(context), u64) anyerror!EdgeRecord,
) !SegmentValidation {
    const counts = try countCsrDirectoryRecords(direction, record_count, context, readEdgeAt);
    var validation: SegmentValidation = .{};

    const tmp_path = try std.fmt.allocPrint(segment.allocator, "{s}.tmp", .{path});
    defer segment.allocator.free(tmp_path);
    errdefer std.Io.Dir.cwd().deleteFile(segment.io, tmp_path) catch {};
    {
        var file = try std.Io.Dir.cwd().createFile(segment.io, tmp_path, .{ .read = true, .truncate = true });
        defer file.close(segment.io);
        const header = SegmentHeader.withShape(direction, record_count, counts.vertex_count, counts.relation_count, counts.u24EdgeRecordShape(), counts.u32EdgeRecordShape(), counts.u24_node_u32_vertex_records, counts.u32_vertex_records, counts.u8_relation_counts, counts.u16_relation_counts, counts.uniformRelation(), counts.hasSingleRelationPerVertex(), counts.uniformSingleRelationEdgeCount(), counts.derivedEdgeIds(), counts.derivedVertexIds(), counts.derivedEdgeOtherNodes());
        const buffer_capacity = try csrWriteBufferCapacityForHeader(header);
        var writer = try CsrBufferedWriter.init(segment.allocator, segment.io, file, buffer_capacity);
        defer writer.deinit();

        var header_bytes: [SegmentHeader.encoded_len]u8 = undefined;
        header.encode(&header_bytes);
        try writer.append(&header_bytes);

        try appendCsrVertexDirectory(&writer, header, direction, record_count, counts.vertex_count, counts.relation_count, context, readEdgeAt);
        try appendCsrRelationDirectory(&writer, header, direction, record_count, counts.relation_count, context, readEdgeAt);
        validation = try appendCsrEdges(&writer, header, direction, record_count, context, readEdgeAt);
        try writer.flush();
        const expected_size = try fileSizeForHeader(header);
        if (writer.offset != expected_size) return error.InvalidRecord;
    }
    if (std.fs.path.isAbsolute(path)) {
        try std.Io.Dir.renameAbsolute(tmp_path, path, segment.io);
    } else {
        try std.Io.Dir.rename(.cwd(), tmp_path, .cwd(), path, segment.io);
    }
    return validation;
}

fn writeCsrFileStream(
    segment: ImmutableAdjacencySegment,
    path: []const u8,
    direction: Direction,
    record_count: u64,
    comptime prove_shape: bool,
    context: anytype,
    comptime reset: fn (@TypeOf(context)) anyerror!void,
    comptime next: fn (@TypeOf(context)) anyerror!?EdgeRecord,
) !SegmentValidation {
    var counts = try countCsrDirectoryRecordsStream(direction, record_count, context, reset, next);
    var proof_validation: ?SegmentValidation = null;
    if (prove_shape) {
        const proof = try countCsrDirectoryRecordsStreamWithValidation(direction, record_count, context, reset, next);
        try counts.keepOnlyStableStreamShape(proof.counts);
        proof_validation = proof.validation;
    } else {
        counts.clearSynthesizedRelationShape();
        counts.clearDerivedEdgeIdShape();
        counts.clearDerivedVertexIdShape();
        counts.clearDerivedEdgeOtherNodeShape();
        // Trusted merge streams are already ordered by contract, but their
        // reset path is not a byte-for-byte proof of every relation run length.
        // Keep the older u16/u64 lanes there; reserve u8 counts for proven
        // streams and random-access readers. Derived edge IDs are likewise
        // reserved for paths that prove the same sequence twice.
        counts.u8_relation_counts = false;
    }
    var validation: SegmentValidation = .{};

    const tmp_path = try std.fmt.allocPrint(segment.allocator, "{s}.tmp", .{path});
    defer segment.allocator.free(tmp_path);
    errdefer std.Io.Dir.cwd().deleteFile(segment.io, tmp_path) catch {};
    {
        var file = try std.Io.Dir.cwd().createFile(segment.io, tmp_path, .{ .read = true, .truncate = true });
        defer file.close(segment.io);
        const header = SegmentHeader.withShape(direction, record_count, counts.vertex_count, counts.relation_count, counts.u24EdgeRecordShape(), counts.u32EdgeRecordShape(), counts.u24_node_u32_vertex_records, counts.u32_vertex_records, counts.u8_relation_counts, counts.u16_relation_counts, counts.uniformRelation(), counts.hasSingleRelationPerVertex(), counts.uniformSingleRelationEdgeCount(), counts.derivedEdgeIds(), counts.derivedVertexIds(), counts.derivedEdgeOtherNodes());
        const buffer_capacity = try csrWriteBufferCapacityForHeader(header);
        var writer = try CsrBufferedWriter.init(segment.allocator, segment.io, file, buffer_capacity);
        defer writer.deinit();

        var header_bytes: [SegmentHeader.encoded_len]u8 = undefined;
        header.encode(&header_bytes);
        try writer.append(&header_bytes);

        try appendCsrVertexDirectoryStream(&writer, header, direction, record_count, counts.vertex_count, counts.relation_count, context, reset, next);
        try appendCsrRelationDirectoryStream(&writer, header, direction, record_count, counts.relation_count, context, reset, next);
        validation = try appendCsrEdgesStream(&writer, header, direction, record_count, context, reset, next);
        if (proof_validation) |proof| {
            if (!validation.eql(proof)) return error.InvalidRecord;
        }
        try writer.flush();
        const expected_size = try fileSizeForHeader(header);
        if (writer.offset != expected_size) return error.InvalidRecord;
    }
    if (std.fs.path.isAbsolute(path)) {
        try std.Io.Dir.renameAbsolute(tmp_path, path, segment.io);
    } else {
        try std.Io.Dir.rename(.cwd(), tmp_path, .cwd(), path, segment.io);
    }
    return validation;
}

fn takeStreamEdge(
    context: anytype,
    comptime next: fn (@TypeOf(context)) anyerror!?EdgeRecord,
    pending: *?EdgeRecord,
    emitted: *u64,
) !?EdgeRecord {
    if (pending.*) |edge| {
        pending.* = null;
        return edge;
    }
    const edge = (try next(context)) orelse return null;
    emitted.* = std.math.add(u64, emitted.*, 1) catch return error.RecordTooLarge;
    return edge;
}

const CsrDirectoryCounts = struct {
    vertex_count: u64 = 0,
    relation_count: u64 = 0,
    u24_node_u32_edge_records: bool = true,
    u32_edge_records: bool = true,
    u24_node_edge_records: bool = true,
    u32_node_edge_records: bool = true,
    u24_node_u32_vertex_records: bool = true,
    u32_vertex_records: bool = true,
    u8_relation_counts: bool = true,
    u16_relation_counts: bool = true,
    uniform_relation: ?core.RelKind = null,
    uniform_relation_valid: bool = true,
    single_relation_per_vertex: bool = true,
    uniform_single_relation_edge_count: ?u32 = null,
    uniform_single_relation_edge_count_valid: bool = true,
    derived_edge_id_valid: bool = true,
    derived_edge_id_base: u64 = 0,
    derived_edge_id_step: u32 = 0,
    derived_edge_id_last: u64 = 0,
    derived_edge_id_count: u64 = 0,
    derived_edge_id_split_index: u64 = 0,
    derived_edge_id_second_base: u64 = 0,
    derived_edge_id_second_step: u32 = 0,
    derived_edge_id_second_last: u64 = 0,
    derived_edge_id_second_count: u64 = 0,
    derived_vertex_id_valid: bool = true,
    derived_vertex_id_base: u64 = 0,
    derived_vertex_id_step: u32 = 0,
    derived_vertex_id_last: u64 = 0,
    derived_vertex_id_count: u64 = 0,
    derived_vertex_id_split_index: u64 = 0,
    derived_vertex_id_second_base: u64 = 0,
    derived_vertex_id_second_step: u32 = 0,
    derived_vertex_id_second_last: u64 = 0,
    derived_vertex_id_second_count: u64 = 0,
    derived_edge_other_node_valid: bool = true,
    derived_edge_other_node_base: u64 = 0,
    derived_edge_other_node_step: u32 = 0,
    derived_edge_other_node_last: u64 = 0,
    derived_edge_other_node_count: u64 = 0,
    derived_edge_other_node_split_index: u64 = 0,
    derived_edge_other_node_second_base: u64 = 0,
    derived_edge_other_node_second_step: u32 = 0,
    derived_edge_other_node_second_last: u64 = 0,
    derived_edge_other_node_second_count: u64 = 0,

    fn addEdge(self: *CsrDirectoryCounts, edge: EdgeRecord, direction: Direction) void {
        const stored = StoredEdgeRecord.fromEdge(edge, direction);
        if (self.u24_node_u32_edge_records and !stored.hasU24NodeU32EdgeShape()) {
            self.u24_node_u32_edge_records = false;
        }
        if (self.u32_edge_records and !stored.hasU32Shape()) {
            self.u32_edge_records = false;
        }
        if (self.u24_node_edge_records and stored.other_node > StoredEdgeRecord.u24_node_max) {
            self.u24_node_edge_records = false;
        }
        if (self.u32_node_edge_records and stored.other_node > std.math.maxInt(u32)) {
            self.u32_node_edge_records = false;
        }
        self.addDerivedEdgeId(edge.edge_id.toInt());
        self.addDerivedEdgeOtherNode(stored.other_node);
    }

    fn addVertex(self: *CsrDirectoryCounts, vertex: VertexRecord) void {
        if (self.u24_node_u32_vertex_records and !vertex.hasU24NodeU32Shape()) {
            self.u24_node_u32_vertex_records = false;
        }
        if (self.u32_vertex_records and !vertex.hasU32Shape()) {
            self.u32_vertex_records = false;
        }
        self.addDerivedVertexId(vertex.node_id);
    }

    fn addRelation(self: *CsrDirectoryCounts, rel: core.RelKind, edge_count: u64) void {
        if (self.u8_relation_counts and edge_count > std.math.maxInt(u8)) {
            self.u8_relation_counts = false;
        }
        if (self.u16_relation_counts and edge_count > std.math.maxInt(u16)) {
            self.u16_relation_counts = false;
        }
        if (std.math.cast(u32, edge_count)) |edge_count_u32| {
            if (edge_count_u32 == 0) {
                self.uniform_single_relation_edge_count = null;
                self.uniform_single_relation_edge_count_valid = false;
            } else if (self.uniform_single_relation_edge_count_valid) {
                if (self.uniform_single_relation_edge_count) |first_count| {
                    if (first_count != edge_count_u32) {
                        self.uniform_single_relation_edge_count = null;
                        self.uniform_single_relation_edge_count_valid = false;
                    }
                } else {
                    self.uniform_single_relation_edge_count = edge_count_u32;
                }
            }
        } else {
            self.uniform_single_relation_edge_count = null;
            self.uniform_single_relation_edge_count_valid = false;
        }
        if (self.uniform_relation_valid) {
            if (self.uniform_relation) |first_rel| {
                if (first_rel != rel) {
                    self.uniform_relation = null;
                    self.uniform_relation_valid = false;
                }
            } else {
                self.uniform_relation = rel;
            }
        }
    }

    fn uniformRelation(self: CsrDirectoryCounts) ?core.RelKind {
        if (!self.uniform_relation_valid) return null;
        const rel = self.uniform_relation orelse return null;
        return if (@intFromEnum(rel) <= 0xff) rel else null;
    }

    fn addVertexRelationCount(self: *CsrDirectoryCounts, relation_count: u64) void {
        if (relation_count != 1) self.single_relation_per_vertex = false;
    }

    fn hasSingleRelationPerVertex(self: CsrDirectoryCounts) bool {
        return self.single_relation_per_vertex and
            self.relation_count == self.vertex_count;
    }

    fn uniformSingleRelationEdgeCount(self: CsrDirectoryCounts) ?u32 {
        return if (self.hasSingleRelationPerVertex() and self.uniform_single_relation_edge_count_valid)
            self.uniform_single_relation_edge_count
        else
            null;
    }

    fn addDerivedEdgeId(self: *CsrDirectoryCounts, edge_id: u64) void {
        if (!self.derived_edge_id_valid) return;
        if (edge_id == 0 or edge_id == std.math.maxInt(u64)) {
            self.clearDerivedEdgeIdShape();
            return;
        }
        if (self.derived_edge_id_count == 0) {
            self.derived_edge_id_base = edge_id;
            self.derived_edge_id_last = edge_id;
            self.derived_edge_id_count += 1;
            return;
        }
        if (self.derived_edge_id_split_index == 0) {
            if (tryExtendDerivedIdRun(edge_id, &self.derived_edge_id_last, &self.derived_edge_id_step, self.derived_edge_id_count)) {
                self.derived_edge_id_count += 1;
                return;
            }
            self.derived_edge_id_split_index = self.derived_edge_id_count;
            self.derived_edge_id_second_base = edge_id;
            self.derived_edge_id_second_last = edge_id;
            self.derived_edge_id_second_count = 1;
            self.derived_edge_id_count += 1;
            return;
        }
        if (!tryExtendDerivedIdRun(edge_id, &self.derived_edge_id_second_last, &self.derived_edge_id_second_step, self.derived_edge_id_second_count)) {
            self.clearDerivedEdgeIdShape();
            return;
        }
        self.derived_edge_id_second_count += 1;
        self.derived_edge_id_count += 1;
    }

    fn derivedEdgeIds(self: CsrDirectoryCounts) ?DerivedEdgeIdShape {
        if (!self.derived_edge_id_valid or self.derived_edge_id_count == 0) return null;
        const step = if (self.derived_edge_id_split_index == 0 and self.derived_edge_id_count == 1)
            @as(u32, 1)
        else if (self.derived_edge_id_split_index != 0 and self.derived_edge_id_split_index == 1)
            @as(u32, 1)
        else
            self.derived_edge_id_step;
        if (step == 0) return null;
        if (self.derived_edge_id_split_index == 0) return .{ .base = self.derived_edge_id_base, .step = step };
        const second_step = if (self.derived_edge_id_second_count == 1) @as(u32, 1) else self.derived_edge_id_second_step;
        if (second_step == 0) return null;
        return .{
            .base = self.derived_edge_id_base,
            .step = step,
            .split_index = self.derived_edge_id_split_index,
            .second_base = self.derived_edge_id_second_base,
            .second_step = second_step,
        };
    }

    fn usesDerivedEdgeIds(self: CsrDirectoryCounts) bool {
        return self.derivedEdgeIds() != null;
    }

    fn addDerivedVertexId(self: *CsrDirectoryCounts, node_id: u64) void {
        if (!self.derived_vertex_id_valid) return;
        if (node_id == 0 or node_id == std.math.maxInt(u64)) {
            self.clearDerivedVertexIdShape();
            return;
        }
        if (self.derived_vertex_id_count == 0) {
            self.derived_vertex_id_base = node_id;
            self.derived_vertex_id_last = node_id;
            self.derived_vertex_id_count += 1;
            return;
        }
        if (self.derived_vertex_id_split_index == 0) {
            if (tryExtendDerivedIdRun(node_id, &self.derived_vertex_id_last, &self.derived_vertex_id_step, self.derived_vertex_id_count)) {
                self.derived_vertex_id_count += 1;
                return;
            }
            self.derived_vertex_id_split_index = self.derived_vertex_id_count;
            self.derived_vertex_id_second_base = node_id;
            self.derived_vertex_id_second_last = node_id;
            self.derived_vertex_id_second_count = 1;
            self.derived_vertex_id_count += 1;
            return;
        }
        if (!tryExtendDerivedIdRun(node_id, &self.derived_vertex_id_second_last, &self.derived_vertex_id_second_step, self.derived_vertex_id_second_count)) {
            self.clearDerivedVertexIdShape();
            return;
        }
        self.derived_vertex_id_second_count += 1;
        self.derived_vertex_id_count += 1;
    }

    fn derivedVertexIds(self: CsrDirectoryCounts) ?DerivedVertexIdShape {
        if (!self.derived_vertex_id_valid or self.derived_vertex_id_count == 0) return null;
        if (!self.hasSingleRelationPerVertex() or self.uniformRelation() == null or self.uniformSingleRelationEdgeCount() == null) return null;
        const step = if (self.derived_vertex_id_split_index == 0 and self.derived_vertex_id_count == 1)
            @as(u32, 1)
        else if (self.derived_vertex_id_split_index != 0 and self.derived_vertex_id_split_index == 1)
            @as(u32, 1)
        else
            self.derived_vertex_id_step;
        if (step == 0) return null;
        if (self.derived_vertex_id_split_index == 0) return .{ .base = self.derived_vertex_id_base, .step = step };
        const second_step = if (self.derived_vertex_id_second_count == 1) @as(u32, 1) else self.derived_vertex_id_second_step;
        if (second_step == 0) return null;
        return .{
            .base = self.derived_vertex_id_base,
            .step = step,
            .split_index = self.derived_vertex_id_split_index,
            .second_base = self.derived_vertex_id_second_base,
            .second_step = second_step,
        };
    }

    fn addDerivedEdgeOtherNode(self: *CsrDirectoryCounts, node_id: u64) void {
        if (!self.derived_edge_other_node_valid) return;
        if (node_id == 0 or node_id == std.math.maxInt(u64)) {
            self.clearDerivedEdgeOtherNodeShape();
            return;
        }
        if (self.derived_edge_other_node_count == 0) {
            self.derived_edge_other_node_base = node_id;
            self.derived_edge_other_node_last = node_id;
            self.derived_edge_other_node_count += 1;
            return;
        }
        if (self.derived_edge_other_node_split_index == 0) {
            if (tryExtendDerivedIdRun(node_id, &self.derived_edge_other_node_last, &self.derived_edge_other_node_step, self.derived_edge_other_node_count)) {
                self.derived_edge_other_node_count += 1;
                return;
            }
            self.derived_edge_other_node_split_index = self.derived_edge_other_node_count;
            self.derived_edge_other_node_second_base = node_id;
            self.derived_edge_other_node_second_last = node_id;
            self.derived_edge_other_node_second_count = 1;
            self.derived_edge_other_node_count += 1;
            return;
        }
        if (!tryExtendDerivedIdRun(node_id, &self.derived_edge_other_node_second_last, &self.derived_edge_other_node_second_step, self.derived_edge_other_node_second_count)) {
            self.clearDerivedEdgeOtherNodeShape();
            return;
        }
        self.derived_edge_other_node_second_count += 1;
        self.derived_edge_other_node_count += 1;
    }

    fn derivedEdgeOtherNodes(self: CsrDirectoryCounts) ?DerivedEdgeOtherNodeShape {
        if (self.derivedEdgeIds() == null) return null;
        if (!self.derived_edge_other_node_valid or self.derived_edge_other_node_count == 0) return null;
        const step = if (self.derived_edge_other_node_split_index == 0 and self.derived_edge_other_node_count == 1)
            @as(u32, 1)
        else if (self.derived_edge_other_node_split_index != 0 and self.derived_edge_other_node_split_index == 1)
            @as(u32, 1)
        else
            self.derived_edge_other_node_step;
        if (step == 0) return null;
        if (self.derived_edge_other_node_split_index == 0) return .{ .base = self.derived_edge_other_node_base, .step = step };
        const second_step = if (self.derived_edge_other_node_second_count == 1) @as(u32, 1) else self.derived_edge_other_node_second_step;
        if (second_step == 0) return null;
        return .{
            .base = self.derived_edge_other_node_base,
            .step = step,
            .split_index = self.derived_edge_other_node_split_index,
            .second_base = self.derived_edge_other_node_second_base,
            .second_step = second_step,
        };
    }

    fn u24EdgeRecordShape(self: CsrDirectoryCounts) bool {
        return if (self.usesDerivedEdgeIds()) self.u24_node_edge_records else self.u24_node_u32_edge_records;
    }

    fn u32EdgeRecordShape(self: CsrDirectoryCounts) bool {
        return if (self.usesDerivedEdgeIds()) self.u32_node_edge_records else self.u32_edge_records;
    }

    fn clearSynthesizedRelationShape(self: *CsrDirectoryCounts) void {
        self.uniform_relation = null;
        self.uniform_relation_valid = false;
        self.single_relation_per_vertex = false;
        self.uniform_single_relation_edge_count = null;
        self.uniform_single_relation_edge_count_valid = false;
    }

    fn clearDerivedEdgeIdShape(self: *CsrDirectoryCounts) void {
        self.derived_edge_id_valid = false;
        self.derived_edge_id_base = 0;
        self.derived_edge_id_step = 0;
        self.derived_edge_id_last = 0;
        self.derived_edge_id_count = 0;
        self.derived_edge_id_split_index = 0;
        self.derived_edge_id_second_base = 0;
        self.derived_edge_id_second_step = 0;
        self.derived_edge_id_second_last = 0;
        self.derived_edge_id_second_count = 0;
    }

    fn clearDerivedVertexIdShape(self: *CsrDirectoryCounts) void {
        self.derived_vertex_id_valid = false;
        self.derived_vertex_id_base = 0;
        self.derived_vertex_id_step = 0;
        self.derived_vertex_id_last = 0;
        self.derived_vertex_id_count = 0;
        self.derived_vertex_id_split_index = 0;
        self.derived_vertex_id_second_base = 0;
        self.derived_vertex_id_second_step = 0;
        self.derived_vertex_id_second_last = 0;
        self.derived_vertex_id_second_count = 0;
    }

    fn clearDerivedEdgeOtherNodeShape(self: *CsrDirectoryCounts) void {
        self.derived_edge_other_node_valid = false;
        self.derived_edge_other_node_base = 0;
        self.derived_edge_other_node_step = 0;
        self.derived_edge_other_node_last = 0;
        self.derived_edge_other_node_count = 0;
        self.derived_edge_other_node_split_index = 0;
        self.derived_edge_other_node_second_base = 0;
        self.derived_edge_other_node_second_step = 0;
        self.derived_edge_other_node_second_last = 0;
        self.derived_edge_other_node_second_count = 0;
    }

    fn keepOnlyStableStreamShape(self: *CsrDirectoryCounts, proof: CsrDirectoryCounts) !void {
        if (self.vertex_count != proof.vertex_count or
            self.relation_count != proof.relation_count or
            self.u24_node_u32_edge_records != proof.u24_node_u32_edge_records or
            self.u32_edge_records != proof.u32_edge_records or
            self.u24_node_edge_records != proof.u24_node_edge_records or
            self.u32_node_edge_records != proof.u32_node_edge_records or
            self.u24_node_u32_vertex_records != proof.u24_node_u32_vertex_records or
            self.u32_vertex_records != proof.u32_vertex_records or
            self.u8_relation_counts != proof.u8_relation_counts or
            self.u16_relation_counts != proof.u16_relation_counts)
        {
            return error.InvalidRecord;
        }
        if (self.uniformRelation() != proof.uniformRelation() or
            self.hasSingleRelationPerVertex() != proof.hasSingleRelationPerVertex() or
            self.uniformSingleRelationEdgeCount() != proof.uniformSingleRelationEdgeCount())
        {
            self.clearSynthesizedRelationShape();
        }
        if (!derivedEdgeIdShapesEqual(self.derivedEdgeIds(), proof.derivedEdgeIds())) {
            self.clearDerivedEdgeIdShape();
        }
        if (!derivedVertexIdShapesEqual(self.derivedVertexIds(), proof.derivedVertexIds())) {
            self.clearDerivedVertexIdShape();
        }
        if (!derivedEdgeOtherNodeShapesEqual(self.derivedEdgeOtherNodes(), proof.derivedEdgeOtherNodes())) {
            self.clearDerivedEdgeOtherNodeShape();
        }
    }
};

fn tryExtendDerivedIdRun(id: u64, last: *u64, step_slot: *u32, count: u64) bool {
    if (id <= last.*) return false;
    const diff = id - last.*;
    const step = std.math.cast(u32, diff) orelse return false;
    if (step == 0) return false;
    if (count == 1) {
        step_slot.* = step;
    } else if (step_slot.* != step) {
        return false;
    }
    last.* = id;
    return true;
}

fn countCsrDirectoryRecords(
    direction: Direction,
    record_count: u64,
    context: anytype,
    comptime readEdgeAt: fn (@TypeOf(context), u64) anyerror!EdgeRecord,
) !CsrDirectoryCounts {
    var counts: CsrDirectoryCounts = .{};
    var pos: u64 = 0;
    while (pos < record_count) {
        const first = try readEdgeAt(context, pos);
        const node_id = edgeNodeForDirection(first, direction);
        const vertex_edge_offset = pos;
        const vertex_relation_offset = counts.relation_count;

        while (pos < record_count) {
            const relation_first = try readEdgeAt(context, pos);
            if (edgeNodeForDirection(relation_first, direction) != node_id) break;

            const rel = relation_first.rel;
            const edge_start = pos;
            counts.relation_count = std.math.add(u64, counts.relation_count, 1) catch return error.RecordTooLarge;

            while (pos < record_count) {
                const edge = try readEdgeAt(context, pos);
                if (edgeNodeForDirection(edge, direction) != node_id or edge.rel != rel) break;
                counts.addEdge(edge, direction);
                pos += 1;
            }
            counts.addRelation(rel, pos - edge_start);
        }
        const vertex = VertexRecord{
            .node_id = node_id,
            .relation_offset = vertex_relation_offset,
            .relation_count = counts.relation_count - vertex_relation_offset,
            .edge_offset = vertex_edge_offset,
        };
        counts.addVertexRelationCount(vertex.relation_count);
        counts.addVertex(vertex);
        counts.vertex_count = std.math.add(u64, counts.vertex_count, 1) catch return error.RecordTooLarge;
    }
    if (record_count == 0) {
        counts.u24_node_u32_edge_records = false;
        counts.u32_edge_records = false;
        counts.u24_node_edge_records = false;
        counts.u32_node_edge_records = false;
        counts.u24_node_u32_vertex_records = false;
        counts.u32_vertex_records = false;
        counts.u8_relation_counts = false;
        counts.u16_relation_counts = false;
        counts.single_relation_per_vertex = false;
        counts.clearDerivedEdgeIdShape();
        counts.clearDerivedVertexIdShape();
        counts.clearDerivedEdgeOtherNodeShape();
    }
    return counts;
}

fn countCsrDirectoryRecordsStream(
    direction: Direction,
    record_count: u64,
    context: anytype,
    comptime reset: fn (@TypeOf(context)) anyerror!void,
    comptime next: fn (@TypeOf(context)) anyerror!?EdgeRecord,
) !CsrDirectoryCounts {
    try reset(context);
    var counts: CsrDirectoryCounts = .{};
    var emitted: u64 = 0;
    var pending: ?EdgeRecord = null;

    while (try takeStreamEdge(context, next, &pending, &emitted)) |first| {
        const node_id = edgeNodeForDirection(first, direction);
        const vertex_edge_offset = emitted - 1;
        const vertex_relation_offset = counts.relation_count;

        var relation_first: ?EdgeRecord = first;
        while (relation_first) |rel_first| {
            if (edgeNodeForDirection(rel_first, direction) != node_id) {
                pending = rel_first;
                break;
            }
            const rel = rel_first.rel;
            var relation_edge_count: u64 = 1;
            counts.relation_count = std.math.add(u64, counts.relation_count, 1) catch return error.RecordTooLarge;
            counts.addEdge(rel_first, direction);

            while (try takeStreamEdge(context, next, &pending, &emitted)) |edge| {
                if (edgeNodeForDirection(edge, direction) != node_id or edge.rel != rel) {
                    relation_first = edge;
                    break;
                }
                counts.addEdge(edge, direction);
                relation_edge_count = std.math.add(u64, relation_edge_count, 1) catch return error.RecordTooLarge;
            } else {
                relation_first = null;
                break;
            }
            counts.addRelation(rel, relation_edge_count);
        }
        const vertex = VertexRecord{
            .node_id = node_id,
            .relation_offset = vertex_relation_offset,
            .relation_count = counts.relation_count - vertex_relation_offset,
            .edge_offset = vertex_edge_offset,
        };
        counts.addVertexRelationCount(vertex.relation_count);
        counts.addVertex(vertex);
        counts.vertex_count = std.math.add(u64, counts.vertex_count, 1) catch return error.RecordTooLarge;
    }
    if (emitted != record_count) return error.InvalidRecord;
    if (record_count == 0) {
        counts.u24_node_u32_edge_records = false;
        counts.u32_edge_records = false;
        counts.u24_node_edge_records = false;
        counts.u32_node_edge_records = false;
        counts.u24_node_u32_vertex_records = false;
        counts.u32_vertex_records = false;
        counts.u8_relation_counts = false;
        counts.u16_relation_counts = false;
        counts.single_relation_per_vertex = false;
        counts.clearDerivedEdgeIdShape();
        counts.clearDerivedVertexIdShape();
        counts.clearDerivedEdgeOtherNodeShape();
    }
    return counts;
}

const CsrStreamShapeProof = struct {
    counts: CsrDirectoryCounts,
    validation: SegmentValidation,
};

fn addProofEdge(validation: *SegmentValidation, direction: Direction, edge: EdgeRecord, previous_edge: *?EdgeRecord) !void {
    try validateWritableEdge(edge);
    if (previous_edge.*) |previous| {
        if (edgeLessThan(direction, edge, previous)) return error.InvalidRecord;
    }
    previous_edge.* = edge;
    validation.addNode(edgeNodeForDirection(edge, direction));
    try validation.addEdge(edge);
}

fn countCsrDirectoryRecordsStreamWithValidation(
    direction: Direction,
    record_count: u64,
    context: anytype,
    comptime reset: fn (@TypeOf(context)) anyerror!void,
    comptime next: fn (@TypeOf(context)) anyerror!?EdgeRecord,
) !CsrStreamShapeProof {
    try reset(context);
    var counts: CsrDirectoryCounts = .{};
    var validation: SegmentValidation = .{};
    var previous_edge: ?EdgeRecord = null;
    var emitted: u64 = 0;
    var pending: ?EdgeRecord = null;

    while (try takeStreamEdge(context, next, &pending, &emitted)) |first| {
        const node_id = edgeNodeForDirection(first, direction);
        const vertex_edge_offset = emitted - 1;
        const vertex_relation_offset = counts.relation_count;

        var relation_first: ?EdgeRecord = first;
        while (relation_first) |rel_first| {
            if (edgeNodeForDirection(rel_first, direction) != node_id) {
                pending = rel_first;
                break;
            }
            try addProofEdge(&validation, direction, rel_first, &previous_edge);
            const rel = rel_first.rel;
            var relation_edge_count: u64 = 1;
            counts.relation_count = std.math.add(u64, counts.relation_count, 1) catch return error.RecordTooLarge;
            counts.addEdge(rel_first, direction);

            while (try takeStreamEdge(context, next, &pending, &emitted)) |edge| {
                if (edgeNodeForDirection(edge, direction) != node_id or edge.rel != rel) {
                    relation_first = edge;
                    break;
                }
                try addProofEdge(&validation, direction, edge, &previous_edge);
                counts.addEdge(edge, direction);
                relation_edge_count = std.math.add(u64, relation_edge_count, 1) catch return error.RecordTooLarge;
            } else {
                relation_first = null;
                break;
            }
            counts.addRelation(rel, relation_edge_count);
        }
        const vertex = VertexRecord{
            .node_id = node_id,
            .relation_offset = vertex_relation_offset,
            .relation_count = counts.relation_count - vertex_relation_offset,
            .edge_offset = vertex_edge_offset,
        };
        counts.addVertexRelationCount(vertex.relation_count);
        counts.addVertex(vertex);
        counts.vertex_count = std.math.add(u64, counts.vertex_count, 1) catch return error.RecordTooLarge;
    }
    if (emitted != record_count or validation.edge_count != record_count) return error.InvalidRecord;
    if (record_count == 0) {
        counts.u24_node_u32_edge_records = false;
        counts.u32_edge_records = false;
        counts.u24_node_edge_records = false;
        counts.u32_node_edge_records = false;
        counts.u24_node_u32_vertex_records = false;
        counts.u32_vertex_records = false;
        counts.u8_relation_counts = false;
        counts.u16_relation_counts = false;
        counts.single_relation_per_vertex = false;
        counts.clearDerivedEdgeIdShape();
        counts.clearDerivedVertexIdShape();
        counts.clearDerivedEdgeOtherNodeShape();
    }
    return .{
        .counts = counts,
        .validation = validation,
    };
}

fn appendCsrVertexDirectory(
    writer: *CsrBufferedWriter,
    header: SegmentHeader,
    direction: Direction,
    record_count: u64,
    expected_vertex_count: u64,
    expected_relation_count: u64,
    context: anytype,
    comptime readEdgeAt: fn (@TypeOf(context), u64) anyerror!EdgeRecord,
) !void {
    var pos: u64 = 0;
    var vertex_count: u64 = 0;
    var relation_offset: u64 = 0;
    var vertex_bytes: [VertexRecord.encoded_len]u8 = undefined;
    const encoded_vertex = vertex_bytes[0..header.vertexRecordLen()];

    while (pos < record_count) {
        const first = try readEdgeAt(context, pos);
        const node_id = edgeNodeForDirection(first, direction);
        const vertex_edge_offset = pos;
        const vertex_relation_offset = relation_offset;
        var single_relation_rel: u16 = 0;

        while (pos < record_count) {
            const relation_first = try readEdgeAt(context, pos);
            if (edgeNodeForDirection(relation_first, direction) != node_id) break;

            const rel = relation_first.rel;
            if (relation_offset == vertex_relation_offset) single_relation_rel = @intFromEnum(rel);
            relation_offset = std.math.add(u64, relation_offset, 1) catch return error.RecordTooLarge;

            while (pos < record_count) {
                const edge = try readEdgeAt(context, pos);
                if (edgeNodeForDirection(edge, direction) != node_id or edge.rel != rel) break;
                pos += 1;
            }
        }

        vertex_count = std.math.add(u64, vertex_count, 1) catch return error.RecordTooLarge;
        const relation_count = relation_offset - vertex_relation_offset;
        const vertex = VertexRecord{
            .node_id = node_id,
            .relation_offset = vertex_relation_offset,
            .relation_count = relation_count,
            .edge_offset = vertex_edge_offset,
            .single_relation_rel = single_relation_rel,
        };
        try vertex.encodeForHeaderAt(header, vertex_count - 1, encoded_vertex);
        try writer.append(encoded_vertex);
    }

    if (vertex_count != expected_vertex_count or relation_offset != expected_relation_count) return error.InvalidRecord;
}

fn appendCsrVertexDirectoryStream(
    writer: *CsrBufferedWriter,
    header: SegmentHeader,
    direction: Direction,
    record_count: u64,
    expected_vertex_count: u64,
    expected_relation_count: u64,
    context: anytype,
    comptime reset: fn (@TypeOf(context)) anyerror!void,
    comptime next: fn (@TypeOf(context)) anyerror!?EdgeRecord,
) !void {
    try reset(context);
    var emitted: u64 = 0;
    var pending: ?EdgeRecord = null;
    var vertex_count: u64 = 0;
    var relation_offset: u64 = 0;
    var vertex_bytes: [VertexRecord.encoded_len]u8 = undefined;
    const encoded_vertex = vertex_bytes[0..header.vertexRecordLen()];

    while (try takeStreamEdge(context, next, &pending, &emitted)) |first| {
        const node_id = edgeNodeForDirection(first, direction);
        const vertex_edge_offset = emitted - 1;
        const vertex_relation_offset = relation_offset;
        var single_relation_rel: u16 = 0;

        var relation_first: ?EdgeRecord = first;
        while (relation_first) |rel_first| {
            if (edgeNodeForDirection(rel_first, direction) != node_id) {
                pending = rel_first;
                break;
            }
            const rel = rel_first.rel;
            if (relation_offset == vertex_relation_offset) single_relation_rel = @intFromEnum(rel);
            relation_offset = std.math.add(u64, relation_offset, 1) catch return error.RecordTooLarge;

            while (try takeStreamEdge(context, next, &pending, &emitted)) |edge| {
                if (edgeNodeForDirection(edge, direction) != node_id or edge.rel != rel) {
                    relation_first = edge;
                    break;
                }
            } else {
                relation_first = null;
                break;
            }
        }

        vertex_count = std.math.add(u64, vertex_count, 1) catch return error.RecordTooLarge;
        const vertex = VertexRecord{
            .node_id = node_id,
            .relation_offset = vertex_relation_offset,
            .relation_count = relation_offset - vertex_relation_offset,
            .edge_offset = vertex_edge_offset,
            .single_relation_rel = single_relation_rel,
        };
        try vertex.encodeForHeaderAt(header, vertex_count - 1, encoded_vertex);
        try writer.append(encoded_vertex);
    }

    if (emitted != record_count or vertex_count != expected_vertex_count or relation_offset != expected_relation_count) return error.InvalidRecord;
}

fn appendCsrRelationDirectory(
    writer: *CsrBufferedWriter,
    header: SegmentHeader,
    direction: Direction,
    record_count: u64,
    expected_relation_count: u64,
    context: anytype,
    comptime readEdgeAt: fn (@TypeOf(context), u64) anyerror!EdgeRecord,
) !void {
    var pos: u64 = 0;
    var relation_count: u64 = 0;
    var relation_bytes: [RelationRangeRecord.encoded_len]u8 = undefined;
    const encoded_relation = relation_bytes[0..header.relationRecordLen()];

    while (pos < record_count) {
        const first = try readEdgeAt(context, pos);
        const node_id = edgeNodeForDirection(first, direction);

        while (pos < record_count) {
            const relation_first = try readEdgeAt(context, pos);
            if (edgeNodeForDirection(relation_first, direction) != node_id) break;

            const rel = relation_first.rel;
            const edge_start = pos;
            while (pos < record_count) {
                const edge = try readEdgeAt(context, pos);
                if (edgeNodeForDirection(edge, direction) != node_id or edge.rel != rel) break;
                pos += 1;
            }

            relation_count = std.math.add(u64, relation_count, 1) catch return error.RecordTooLarge;
            if (header.hasSingleRelationPerVertex()) continue;
            const relation = RelationRangeRecord{
                .rel = @intFromEnum(rel),
                .edge_offset = 0,
                .edge_count = pos - edge_start,
            };
            try relation.encodeForHeader(header, encoded_relation);
            try writer.append(encoded_relation);
        }
    }

    if (relation_count != expected_relation_count) return error.InvalidRecord;
}

fn appendCsrRelationDirectoryStream(
    writer: *CsrBufferedWriter,
    header: SegmentHeader,
    direction: Direction,
    record_count: u64,
    expected_relation_count: u64,
    context: anytype,
    comptime reset: fn (@TypeOf(context)) anyerror!void,
    comptime next: fn (@TypeOf(context)) anyerror!?EdgeRecord,
) !void {
    try reset(context);
    var relation_count: u64 = 0;
    var relation_bytes: [RelationRangeRecord.encoded_len]u8 = undefined;
    const encoded_relation = relation_bytes[0..header.relationRecordLen()];
    var current_node: u64 = 0;
    var current_rel: core.RelKind = undefined;
    var current_count: u64 = 0;

    var emitted: u64 = 0;
    while (try next(context)) |edge| {
        const node_id = edgeNodeForDirection(edge, direction);
        if (current_count == 0) {
            current_node = node_id;
            current_rel = edge.rel;
        } else if (node_id != current_node or edge.rel != current_rel) {
            relation_count = try appendCsrRelationRecord(writer, header, current_rel, current_count, relation_count, encoded_relation);
            current_node = node_id;
            current_rel = edge.rel;
            current_count = 0;
        }
        current_count = std.math.add(u64, current_count, 1) catch return error.RecordTooLarge;
        emitted = std.math.add(u64, emitted, 1) catch return error.RecordTooLarge;
    }
    if (current_count != 0) {
        relation_count = try appendCsrRelationRecord(writer, header, current_rel, current_count, relation_count, encoded_relation);
    }

    if (emitted != record_count or relation_count != expected_relation_count) return error.InvalidRecord;
}

fn appendCsrRelationRecord(
    writer: *CsrBufferedWriter,
    header: SegmentHeader,
    rel: core.RelKind,
    edge_count: u64,
    relation_count: u64,
    relation_bytes: []u8,
) !u64 {
    if (header.hasSingleRelationPerVertex()) {
        return std.math.add(u64, relation_count, 1) catch return error.RecordTooLarge;
    }
    const relation = RelationRangeRecord{
        .rel = @intFromEnum(rel),
        .edge_offset = 0,
        .edge_count = edge_count,
    };
    try relation.encodeForHeader(header, relation_bytes);
    try writer.append(relation_bytes);
    return std.math.add(u64, relation_count, 1) catch return error.RecordTooLarge;
}

fn appendCsrEdges(
    writer: *CsrBufferedWriter,
    header: SegmentHeader,
    direction: Direction,
    record_count: u64,
    context: anytype,
    comptime readEdgeAt: fn (@TypeOf(context), u64) anyerror!EdgeRecord,
) !SegmentValidation {
    var validation: SegmentValidation = .{};
    var edge_bytes: [StoredEdgeRecord.encoded_len]u8 = undefined;
    const encoded = edge_bytes[0..header.edge_record_len];
    var previous_edge: ?EdgeRecord = null;
    var pos: u64 = 0;
    while (pos < record_count) : (pos += 1) {
        const edge = try readEdgeAt(context, pos);
        try validateWritableEdge(edge);
        if (previous_edge) |previous| {
            if (edgeLessThan(direction, edge, previous)) return error.InvalidRecord;
        }
        previous_edge = edge;
        validation.addNode(edgeNodeForDirection(edge, direction));
        try validation.addEdge(edge);
        try StoredEdgeRecord.fromEdge(edge, direction).encodeForHeaderAt(header, pos, encoded);
        try writer.append(encoded);
    }
    return validation;
}

fn validateWritableEdge(edge: EdgeRecord) !void {
    const src = edge.src.toInt();
    const dst = edge.dst.toInt();
    const edge_id = edge.edge_id.toInt();
    if (src == 0 or dst == 0 or edge_id == 0) return error.InvalidRecord;
    if (src == std.math.maxInt(u64) or dst == std.math.maxInt(u64) or edge_id == std.math.maxInt(u64)) return error.InvalidRecord;
}

fn appendCsrEdgesStream(
    writer: *CsrBufferedWriter,
    header: SegmentHeader,
    direction: Direction,
    record_count: u64,
    context: anytype,
    comptime reset: fn (@TypeOf(context)) anyerror!void,
    comptime next: fn (@TypeOf(context)) anyerror!?EdgeRecord,
) !SegmentValidation {
    try reset(context);
    var validation: SegmentValidation = .{};
    var edge_bytes: [StoredEdgeRecord.encoded_len]u8 = undefined;
    const encoded = edge_bytes[0..header.edge_record_len];
    var emitted: u64 = 0;
    var previous_edge: ?EdgeRecord = null;
    while (try next(context)) |edge| {
        emitted = std.math.add(u64, emitted, 1) catch return error.RecordTooLarge;
        try validateWritableEdge(edge);
        if (previous_edge) |previous| {
            if (edgeLessThan(direction, edge, previous)) return error.InvalidRecord;
        }
        previous_edge = edge;
        validation.addNode(edgeNodeForDirection(edge, direction));
        try validation.addEdge(edge);
        try StoredEdgeRecord.fromEdge(edge, direction).encodeForHeaderAt(header, emitted - 1, encoded);
        try writer.append(encoded);
    }
    if (emitted != record_count) return error.InvalidRecord;
    return validation;
}

const SegmentValidation = struct {
    edge_count: u64 = 0,
    edge_digest: u64 = 0,
    edge_id_min: u64 = std.math.maxInt(u64),
    edge_id_max: u64 = 0,
    edge_id_digest: u64 = 0,
    node_id_min: u64 = std.math.maxInt(u64),
    node_id_max: u64 = 0,

    fn addNode(self: *SegmentValidation, node_id: u64) void {
        self.node_id_min = @min(self.node_id_min, node_id);
        self.node_id_max = @max(self.node_id_max, node_id);
    }

    fn addEdge(self: *SegmentValidation, edge: EdgeRecord) !void {
        const edge_id = edge.edge_id.toInt();
        self.edge_id_min = @min(self.edge_id_min, edge_id);
        self.edge_id_max = @max(self.edge_id_max, edge_id);
        self.edge_count = std.math.add(u64, self.edge_count, 1) catch return error.InvalidRecord;
        self.edge_digest ^= edgeRecordDigest(edge);
        self.edge_id_digest ^= edgeIdDigest(edge_id);
    }

    fn eql(self: SegmentValidation, other: SegmentValidation) bool {
        return self.edge_count == other.edge_count and
            self.edge_digest == other.edge_digest and
            self.edge_id_min == other.edge_id_min and
            self.edge_id_max == other.edge_id_max and
            self.edge_id_digest == other.edge_id_digest;
    }
};

const ValidatedCsrView = struct {
    header: SegmentHeader,
    edge_base: u64,
    validation: SegmentValidation,
};

fn validateCsrView(segment: *ImmutableAdjacencySegment, view: *CsrFileView, direction: Direction) !ValidatedCsrView {
    const header = try readHeader(view);
    if (header.order != direction) return error.InvalidRecord;
    try validateFileSize(view, header);

    var previous_node: u64 = 0;
    var expected_relation_offset: u64 = 0;
    var expected_edge_offset: u64 = 0;
    const edge_base = try edgeBaseOffsetForHeader(header);
    var previous_edge: ?EdgeRecord = null;
    var seen_edge_ids = try SegmentEdgeIdSet.init(segment.allocator, header.edge_count);
    defer seen_edge_ids.deinit();
    var validation = SegmentValidation{};
    var pos: u64 = 0;
    while (pos < header.vertex_count) : (pos += 1) {
        const vertex = try segment.readVertexAt(view, header, pos);
        if (vertex.node_id == 0 or vertex.node_id == std.math.maxInt(u64)) return error.InvalidRecord;
        if (pos != 0 and vertex.node_id <= previous_node) return error.InvalidRecord;
        if (vertex.relation_offset != expected_relation_offset) return error.InvalidRecord;
        if (vertex.edge_offset != expected_edge_offset) return error.InvalidRecord;
        if (vertex.relation_count == 0) return error.InvalidRecord;
        validation.addNode(vertex.node_id);
        var previous_rel: ?u16 = null;
        var rel_pos: u64 = 0;
        while (rel_pos < vertex.relation_count) : (rel_pos += 1) {
            const relation = try segment.readRelationAt(view, header, vertex.relation_offset + rel_pos, expected_edge_offset);
            if (previous_rel) |prev| {
                if (relation.rel <= prev) return error.InvalidRecord;
            }
            if (relation.edge_count == 0) return error.InvalidRecord;
            try validateRelationEdges(segment, view, header, edge_base, direction, vertex.node_id, relation, &previous_edge, &seen_edge_ids, &validation);
            expected_edge_offset = std.math.add(u64, expected_edge_offset, relation.edge_count) catch return error.InvalidRecord;
            previous_rel = relation.rel;
        }
        expected_relation_offset = std.math.add(u64, expected_relation_offset, vertex.relation_count) catch return error.InvalidRecord;
        previous_node = vertex.node_id;
    }
    if (expected_relation_offset != header.relation_count) return error.InvalidRecord;
    if (expected_edge_offset != header.edge_count) return error.InvalidRecord;
    if (seen_edge_ids.count != header.edge_count) return error.InvalidRecord;
    if (validation.edge_count != header.edge_count) return error.InvalidRecord;
    return .{
        .header = header,
        .edge_base = edge_base,
        .validation = validation,
    };
}

fn trustCsrViewHeader(view: *CsrFileView, direction: Direction, expected_edge_count: u64) !CsrViewInfo {
    const header = try readHeader(view);
    if (header.order != direction) return error.InvalidRecord;
    if (header.edge_count != expected_edge_count) return error.InvalidRecord;
    try validateFileSize(view, header);
    const edge_base = try edgeBaseOffsetForHeader(header);
    return .{
        .header = header,
        .edge_base = edge_base,
        .validation = .{
            .edge_count = header.edge_count,
        },
    };
}

fn validateRelationEdges(
    segment: *ImmutableAdjacencySegment,
    view: *CsrFileView,
    header: SegmentHeader,
    edge_base: u64,
    direction: Direction,
    node_id: u64,
    relation: RelationRangeRecord,
    previous_edge: *?EdgeRecord,
    seen_edge_ids: *SegmentEdgeIdSet,
    validation: *SegmentValidation,
) !void {
    const edge_end = std.math.add(u64, relation.edge_offset, relation.edge_count) catch return error.InvalidRecord;
    if (edge_end > header.edge_count) return error.InvalidRecord;

    const edge_record_len: usize = header.edge_record_len;
    if (edge_record_len == 0) {
        var index = relation.edge_offset;
        while (index < edge_end) : (index += 1) {
            const edge = try (try StoredEdgeRecord.decodeForHeaderAt(header, index, &.{})).toEdgeInRelation(direction, node_id, relation.rel);
            try validateRelationEdge(direction, node_id, relation.rel, edge, previous_edge, seen_edge_ids, validation);
        }
        return;
    }
    const range_offset = try storedEdgeRangeOffset(edge_base, relation.edge_offset, edge_record_len);
    if (try view.mappedRecordRangeAtLen(edge_record_len, range_offset, relation.edge_count)) |bytes| {
        var cursor: usize = 0;
        var index = relation.edge_offset;
        while (cursor < bytes.len) : (cursor += edge_record_len) {
            const record = try StoredEdgeRecord.decodeForHeaderAt(header, index, bytes[cursor .. cursor + edge_record_len]);
            index += 1;
            const edge = try record.toEdgeInRelation(direction, node_id, relation.rel);
            try validateRelationEdge(direction, node_id, relation.rel, edge, previous_edge, seen_edge_ids, validation);
        }
        return;
    }

    var index = relation.edge_offset;
    while (index < edge_end) : (index += 1) {
        const edge = try (try segment.readStoredEdgeAt(view, header, edge_base, index)).toEdgeInRelation(direction, node_id, relation.rel);
        try validateRelationEdge(direction, node_id, relation.rel, edge, previous_edge, seen_edge_ids, validation);
    }
}

fn validateRelationEdge(
    direction: Direction,
    node_id: u64,
    rel: u16,
    edge: EdgeRecord,
    previous_edge: *?EdgeRecord,
    seen_edge_ids: *SegmentEdgeIdSet,
    validation: *SegmentValidation,
) !void {
    if (edgeNodeForDirection(edge, direction) != node_id) return error.InvalidRecord;
    if (@intFromEnum(edge.rel) != rel) return error.InvalidRecord;
    if (try seen_edge_ids.put(edge.edge_id.toInt())) return error.InvalidRecord;
    if (previous_edge.*) |previous| {
        if (edgeLessThan(direction, edge, previous)) return error.InvalidRecord;
    }
    previous_edge.* = edge;
    try validation.addEdge(edge);
}

const SegmentEdgeIdSet = struct {
    allocator: std.mem.Allocator,
    dense_limit: u64,
    dense_bits: std.ArrayList(u8) = .empty,
    overflow: std.AutoHashMap(u64, void),
    count: u64 = 0,

    fn init(allocator: std.mem.Allocator, edge_count: u64) !SegmentEdgeIdSet {
        return .{
            .allocator = allocator,
            .dense_limit = try denseEdgeIdValidationLimit(edge_count),
            .overflow = std.AutoHashMap(u64, void).init(allocator),
        };
    }

    fn deinit(self: *SegmentEdgeIdSet) void {
        self.overflow.deinit();
        self.dense_bits.deinit(self.allocator);
    }

    fn put(self: *SegmentEdgeIdSet, edge_id: u64) !bool {
        if (edge_id == 0 or edge_id == std.math.maxInt(u64)) return error.InvalidRecord;
        const duplicate = if (edge_id <= self.dense_limit)
            try self.putDense(edge_id)
        else
            try self.putOverflow(edge_id);
        if (!duplicate) self.count = std.math.add(u64, self.count, 1) catch return error.InvalidRecord;
        return duplicate;
    }

    fn putDense(self: *SegmentEdgeIdSet, edge_id: u64) !bool {
        const bit = edge_id - 1;
        const byte_index = std.math.cast(usize, bit / 8) orelse return error.RecordTooLarge;
        if (byte_index >= self.dense_bits.items.len) {
            const old_len = self.dense_bits.items.len;
            const min_len = byte_index + 1;
            const doubled = std.math.mul(usize, @max(old_len, 4096), 2) catch return error.RecordTooLarge;
            const next_len = @max(min_len, doubled);
            try self.dense_bits.resize(self.allocator, next_len);
            @memset(self.dense_bits.items[old_len..], 0);
        }
        const mask = @as(u8, 1) << @intCast(bit % 8);
        const duplicate = (self.dense_bits.items[byte_index] & mask) != 0;
        self.dense_bits.items[byte_index] |= mask;
        return duplicate;
    }

    fn putOverflow(self: *SegmentEdgeIdSet, edge_id: u64) !bool {
        const entry = try self.overflow.getOrPut(edge_id);
        return entry.found_existing;
    }
};

fn denseEdgeIdValidationLimit(edge_count: u64) !u64 {
    const scaled = std.math.mul(u64, edge_count, dense_edge_id_validation_factor) catch dense_edge_id_validation_cap;
    return @min(@max(scaled, dense_edge_id_validation_min), dense_edge_id_validation_cap);
}

fn edgeRecordDigest(edge: EdgeRecord) u64 {
    var bytes: [26]u8 = undefined;
    std.mem.writeInt(u64, bytes[0..8], edge.edge_id.toInt(), .little);
    std.mem.writeInt(u64, bytes[8..16], edge.src.toInt(), .little);
    std.mem.writeInt(u16, bytes[16..18], @intFromEnum(edge.rel), .little);
    std.mem.writeInt(u64, bytes[18..26], edge.dst.toInt(), .little);
    return std.hash.Wyhash.hash(0x544B_4745, &bytes);
}

fn edgeIdDigest(edge_id: u64) u64 {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, edge_id, .little);
    return std.hash.Wyhash.hash(0x544B_4549, &bytes);
}

fn readHeader(view: *CsrFileView) !SegmentHeader {
    var header = if (try view.mappedBytesAt(SegmentHeader.encoded_len, 0)) |bytes|
        try SegmentHeader.decode(bytes)
    else header: {
        const bytes = try view.readAt(SegmentHeader.encoded_len, 0);
        break :header try SegmentHeader.decode(&bytes);
    };
    header.relation_count = try deriveRelationCountFromVertexDirectory(view, header);
    header.edge_count = try deriveEdgeCountFromFileSize(view.size, header.edge_count, header.vertex_count, header.relation_count, header.vertexRecordLen(), header.relationRecordLen(), header.edge_record_len);
    try validateDerivedHeaderCounts(header);
    return header;
}

fn validateDerivedHeaderCounts(header: SegmentHeader) !void {
    if (header.vertex_count == 0) {
        if (header.relation_count != 0 or header.edge_count != 0) return error.InvalidRecord;
        if (header.hasUniformSingleRelationEdgeCount()) return error.InvalidRecord;
        if (header.hasDerivedEdgeIds()) return error.InvalidRecord;
        if (header.hasDerivedVertexIds()) return error.InvalidRecord;
        if (header.hasDerivedEdgeOtherNodes()) return error.InvalidRecord;
        return;
    }
    if (header.relation_count == 0 or header.edge_count == 0) return error.InvalidRecord;
    if (header.relation_count > header.edge_count) return error.InvalidRecord;
    if (header.hasSingleRelationPerVertex() and header.relation_count != header.vertex_count) return error.InvalidRecord;
    if (header.hasUniformSingleRelationEdgeCount()) {
        const derived_edge_count = std.math.mul(u64, header.vertex_count, header.uniform_single_relation_edge_count) catch return error.InvalidRecord;
        if (derived_edge_count != header.edge_count) return error.InvalidRecord;
    }
    if (header.hasDerivedEdgeIds()) {
        if (header.derived_edge_id_split_index != 0 and header.derived_edge_id_split_index >= header.edge_count) return error.InvalidRecord;
        _ = derivedEdgeIdAt(header, header.edge_count - 1) catch return error.InvalidRecord;
        if (header.derived_edge_id_split_index != 0) {
            _ = derivedEdgeIdAt(header, header.derived_edge_id_split_index - 1) catch return error.InvalidRecord;
            _ = derivedEdgeIdAt(header, header.derived_edge_id_split_index) catch return error.InvalidRecord;
        }
    }
    if (header.hasDerivedVertexIds()) {
        if (header.derived_vertex_id_split_index != 0 and header.derived_vertex_id_split_index >= header.vertex_count) return error.InvalidRecord;
        _ = derivedVertexIdAt(header, header.vertex_count - 1) catch return error.InvalidRecord;
        if (header.derived_vertex_id_split_index != 0) {
            _ = derivedVertexIdAt(header, header.derived_vertex_id_split_index - 1) catch return error.InvalidRecord;
            _ = derivedVertexIdAt(header, header.derived_vertex_id_split_index) catch return error.InvalidRecord;
        }
    }
    if (header.hasDerivedEdgeOtherNodes()) {
        if (header.derived_edge_other_node_split_index != 0 and header.derived_edge_other_node_split_index >= header.edge_count) return error.InvalidRecord;
        _ = derivedEdgeOtherNodeAt(header, header.edge_count - 1) catch return error.InvalidRecord;
        if (header.derived_edge_other_node_split_index != 0) {
            _ = derivedEdgeOtherNodeAt(header, header.derived_edge_other_node_split_index - 1) catch return error.InvalidRecord;
            _ = derivedEdgeOtherNodeAt(header, header.derived_edge_other_node_split_index) catch return error.InvalidRecord;
        }
    }
}

fn deriveRelationCountFromVertexDirectory(view: *CsrFileView, header: SegmentHeader) !u64 {
    if (header.vertex_count == 0) {
        return 0;
    }

    const last_vertex_offset = try vertexRecordOffsetForHeader(header, header.vertex_count - 1);
    const vertex_record_len = header.vertexRecordLen();
    const last_vertex = vertex: {
        if (vertex_record_len == 0) break :vertex try VertexRecord.decodeForHeaderAt(header, header.vertex_count - 1, &.{});
        if (try view.mappedBytesAtLen(vertex_record_len, last_vertex_offset)) |bytes| {
            break :vertex try VertexRecord.decodeForHeaderAt(header, header.vertex_count - 1, bytes);
        }
        var buffer: [VertexRecord.encoded_len]u8 = undefined;
        try view.readInto(buffer[0..vertex_record_len], last_vertex_offset);
        break :vertex try VertexRecord.decodeForHeaderAt(header, header.vertex_count - 1, buffer[0..vertex_record_len]);
    };
    if (last_vertex.relation_count == 0) return error.InvalidRecord;
    return std.math.add(u64, last_vertex.relation_offset, last_vertex.relation_count) catch return error.InvalidRecord;
}

fn validateFileSize(view: *CsrFileView, header: SegmentHeader) !void {
    const expected = try fileSizeForHeader(header);
    if (view.size != expected) return error.InvalidRecord;
}

fn csrWriteBufferCapacity(vertex_count: u64, relation_count: u64, edge_count: u64) !usize {
    const expected_size = try fileSizeFor(vertex_count, relation_count, edge_count);
    const size = std.math.cast(usize, expected_size) orelse return error.RecordTooLarge;
    return @min(csr_write_buffer_bytes, size);
}

fn csrWriteBufferCapacityForHeader(header: SegmentHeader) !usize {
    const expected_size = try fileSizeForHeader(header);
    const size = std.math.cast(usize, expected_size) orelse return error.RecordTooLarge;
    return @min(csr_write_buffer_bytes, size);
}

fn edgeNodeForDirection(edge: EdgeRecord, direction: Direction) u64 {
    return switch (direction) {
        .forward => edge.src.toInt(),
        .reverse => edge.dst.toInt(),
    };
}

fn edgeForwardLessThan(_: void, lhs: EdgeRecord, rhs: EdgeRecord) bool {
    if (lhs.src.toInt() != rhs.src.toInt()) return lhs.src.toInt() < rhs.src.toInt();
    if (@intFromEnum(lhs.rel) != @intFromEnum(rhs.rel)) return @intFromEnum(lhs.rel) < @intFromEnum(rhs.rel);
    if (lhs.dst.toInt() != rhs.dst.toInt()) return lhs.dst.toInt() < rhs.dst.toInt();
    return lhs.edge_id.toInt() < rhs.edge_id.toInt();
}

fn edgeReverseLessThan(_: void, lhs: EdgeRecord, rhs: EdgeRecord) bool {
    if (lhs.dst.toInt() != rhs.dst.toInt()) return lhs.dst.toInt() < rhs.dst.toInt();
    if (@intFromEnum(lhs.rel) != @intFromEnum(rhs.rel)) return @intFromEnum(lhs.rel) < @intFromEnum(rhs.rel);
    if (lhs.src.toInt() != rhs.src.toInt()) return lhs.src.toInt() < rhs.src.toInt();
    return lhs.edge_id.toInt() < rhs.edge_id.toInt();
}

fn edgeIdLessThan(_: void, lhs: EdgeRecord, rhs: EdgeRecord) bool {
    return lhs.edge_id.toInt() < rhs.edge_id.toInt();
}

fn edgeIndexIdLessThan(edges: []const EdgeRecord, lhs: u32, rhs: u32) bool {
    return edgeIdLessThan({}, edges[@intCast(lhs)], edges[@intCast(rhs)]);
}

fn edgeIndexForwardLessThan(edges: []const EdgeRecord, lhs: u32, rhs: u32) bool {
    return edgeForwardLessThan({}, edges[@intCast(lhs)], edges[@intCast(rhs)]);
}

fn edgeIndexReverseLessThan(edges: []const EdgeRecord, lhs: u32, rhs: u32) bool {
    return edgeReverseLessThan({}, edges[@intCast(lhs)], edges[@intCast(rhs)]);
}

fn edgeLessThan(direction: Direction, lhs: EdgeRecord, rhs: EdgeRecord) bool {
    return switch (direction) {
        .forward => edgeForwardLessThan({}, lhs, rhs),
        .reverse => edgeReverseLessThan({}, lhs, rhs),
    };
}

pub fn csrFileByteStats(io: std.Io, path: []const u8) !CsrFileByteStats {
    var view = try CsrFileView.open(io, path);
    defer view.deinit();

    const header = try readHeader(&view);
    const vertex_record_len = header.vertexRecordLen();
    const relation_record_len = header.relationRecordLen();
    const vertex_bytes = std.math.mul(u64, header.vertex_count, vertex_record_len) catch return error.RecordTooLarge;
    const relation_bytes = std.math.mul(u64, header.relation_count, relation_record_len) catch return error.RecordTooLarge;
    const edge_bytes = std.math.mul(u64, header.edge_count, header.edge_record_len) catch return error.RecordTooLarge;
    return .{
        .total_bytes = view.size,
        .header_bytes = SegmentHeader.encoded_len,
        .vertex_bytes = vertex_bytes,
        .relation_bytes = relation_bytes,
        .edge_bytes = edge_bytes,
        .edge_count = header.edge_count,
        .vertex_count = header.vertex_count,
        .relation_count = header.relation_count,
        .edge_record_len = header.edge_record_len,
        .vertex_record_len = vertex_record_len,
        .relation_record_len = relation_record_len,
        .derived_edge_ids = header.hasDerivedEdgeIds(),
        .split_derived_edge_ids = header.derived_edge_id_split_index != 0,
        .derived_vertex_ids = header.hasDerivedVertexIds(),
        .split_derived_vertex_ids = header.derived_vertex_id_split_index != 0,
        .derived_edge_other_nodes = header.hasDerivedEdgeOtherNodes(),
        .split_derived_edge_other_nodes = header.derived_edge_other_node_split_index != 0,
    };
}

const TestNeighborCountContext = struct {
    count: usize = 0,
};

fn countNeighbor(context: *TestNeighborCountContext, _: EdgeRecord) !bool {
    context.count += 1;
    return false;
}

fn stopAfterFirstNeighbor(context: *TestNeighborCountContext, _: EdgeRecord) !bool {
    context.count += 1;
    return true;
}

test "csr write buffer capacity is bounded by file size and cap" {
    try std.testing.expectEqual(@as(usize, SegmentHeader.encoded_len), try csrWriteBufferCapacity(0, 0, 0));
    try std.testing.expectEqual(csr_write_buffer_bytes, try csrWriteBufferCapacity(1, 1, 20000));
}

test "csr file byte stats split header vertex relation and edge bytes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const segment_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "s000001" });
    defer std.testing.allocator.free(segment_path);

    var segment = try ImmutableAdjacencySegment.build(std.testing.allocator, std.testing.io, segment_path, &.{
        .{ .edge_id = .fromInt(1), .src = .fromInt(1), .rel = .mentions, .dst = .fromInt(2) },
        .{ .edge_id = .fromInt(2), .src = .fromInt(1), .rel = .mentions, .dst = .fromInt(3) },
    });
    defer segment.deinit();

    const stats = try csrFileByteStats(std.testing.io, segment.fwd_path);
    try std.testing.expectEqual(@as(u64, SegmentHeader.encoded_len), stats.header_bytes);
    try std.testing.expectEqual(@as(u64, 1), stats.vertex_count);
    try std.testing.expectEqual(@as(u64, 1), stats.relation_count);
    try std.testing.expectEqual(@as(u64, 2), stats.edge_count);
    try std.testing.expectEqual(@as(u64, stats.vertex_record_len), stats.vertex_bytes);
    try std.testing.expectEqual(@as(u64, stats.relation_record_len), stats.relation_bytes);
    try std.testing.expectEqual(@as(u64, stats.edge_record_len) * stats.edge_count, stats.edge_bytes);
    try std.testing.expectEqual(stats.total_bytes, stats.header_bytes + stats.vertex_bytes + stats.relation_bytes + stats.edge_bytes);
}

test "immutable adjacency segment reads forward and reverse neighbors without graph" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const segment_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "s000001" });
    defer std.testing.allocator.free(segment_path);

    var segment = try ImmutableAdjacencySegment.build(std.testing.allocator, std.testing.io, segment_path, &.{
        .{ .edge_id = .fromInt(3), .src = .fromInt(2), .rel = .mentions, .dst = .fromInt(1) },
        .{ .edge_id = .fromInt(1), .src = .fromInt(1), .rel = .defines, .dst = .fromInt(2) },
        .{ .edge_id = .fromInt(2), .src = .fromInt(1), .rel = .mentions, .dst = .fromInt(3) },
    });
    defer segment.deinit();

    var out = try segment.neighbors(std.testing.allocator, .forward, .fromInt(1), null, 10);
    defer out.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), out.items.len);
    try std.testing.expectEqual(core.RelKind.defines, out.items[0].rel);
    try std.testing.expectEqual(@as(u64, 2), out.items[0].dst.toInt());
    try std.testing.expectEqual(core.RelKind.mentions, out.items[1].rel);
    try std.testing.expectEqual(@as(u64, 3), out.items[1].dst.toInt());

    var reverse = try segment.neighbors(std.testing.allocator, .reverse, .fromInt(1), .mentions, 10);
    defer reverse.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), reverse.items.len);
    try std.testing.expectEqual(@as(u64, 2), reverse.items[0].src.toInt());
}

test "immutable adjacency segment derives relation edge offsets from vertex prefix" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const segment_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "s000001" });
    defer std.testing.allocator.free(segment_path);

    var segment = try ImmutableAdjacencySegment.build(std.testing.allocator, std.testing.io, segment_path, &.{
        .{ .edge_id = .fromInt(3), .src = .fromInt(2), .rel = .mentions, .dst = .fromInt(1) },
        .{ .edge_id = .fromInt(1), .src = .fromInt(1), .rel = .defines, .dst = .fromInt(2) },
        .{ .edge_id = .fromInt(2), .src = .fromInt(1), .rel = .mentions, .dst = .fromInt(3) },
    });
    defer segment.deinit();

    try std.testing.expectEqual(@as(usize, 32), VertexRecord.encoded_len);
    try std.testing.expectEqual(@as(usize, 16), VertexRecord.u32_encoded_len);
    try std.testing.expectEqual(@as(usize, 15), VertexRecord.u24_node_u32_encoded_len);
    try std.testing.expectEqual(@as(usize, 16), VertexRecord.single_relation_encoded_len);
    try std.testing.expectEqual(@as(usize, 8), VertexRecord.single_relation_u32_encoded_len);
    try std.testing.expectEqual(@as(usize, 7), VertexRecord.single_relation_u24_node_u32_encoded_len);
    try std.testing.expectEqual(@as(usize, 18), VertexRecord.single_relation_rel_encoded_len);
    try std.testing.expectEqual(@as(usize, 10), VertexRecord.single_relation_rel_u32_encoded_len);
    try std.testing.expectEqual(@as(usize, 9), VertexRecord.single_relation_rel_u24_node_u32_encoded_len);
    try std.testing.expectEqual(@as(usize, 8), VertexRecord.single_relation_uniform_edges_encoded_len);
    try std.testing.expectEqual(@as(usize, 4), VertexRecord.single_relation_uniform_edges_u32_encoded_len);
    try std.testing.expectEqual(@as(usize, 3), VertexRecord.single_relation_uniform_edges_u24_node_encoded_len);
    try std.testing.expectEqual(@as(usize, 10), VertexRecord.single_relation_rel_uniform_edges_encoded_len);
    try std.testing.expectEqual(@as(usize, 6), VertexRecord.single_relation_rel_uniform_edges_u32_encoded_len);
    try std.testing.expectEqual(@as(usize, 5), VertexRecord.single_relation_rel_uniform_edges_u24_node_encoded_len);
    try std.testing.expectEqual(@as(usize, 10), RelationRangeRecord.encoded_len);
    try std.testing.expectEqual(@as(usize, 4), RelationRangeRecord.u16_encoded_len);
    try std.testing.expectEqual(@as(usize, 3), RelationRangeRecord.u8_encoded_len);
    try std.testing.expectEqual(@as(usize, 8), RelationRangeRecord.uniform_encoded_len);
    try std.testing.expectEqual(@as(usize, 2), RelationRangeRecord.uniform_u16_encoded_len);
    try std.testing.expectEqual(@as(usize, 1), RelationRangeRecord.uniform_u8_encoded_len);

    const fwd_stat = try segment.fwd_view.?.file.stat(std.testing.io);
    const reverse_stat = try segment.rev_view.?.file.stat(std.testing.io);
    const fwd_size = fwd_stat.size;
    const reverse_size = reverse_stat.size;
    const fwd_header = try segment.validateCachedHeader(&segment.fwd_view.?, segment.fwd_info.?, .forward);
    const reverse_header = try segment.validateCachedHeader(&segment.rev_view.?, segment.rev_info.?, .reverse);
    try std.testing.expect(!fwd_header.hasU24NodeU32EdgeRecords());
    try std.testing.expect(reverse_header.hasU24NodeU32EdgeRecords());
    try std.testing.expect(!fwd_header.hasU32EdgeRecords());
    try std.testing.expect(!reverse_header.hasU32EdgeRecords());
    try std.testing.expect(fwd_header.hasDerivedEdgeIds());
    try std.testing.expect(reverse_header.hasDerivedEdgeIds());
    try std.testing.expect(fwd_header.hasDerivedEdgeOtherNodes());
    try std.testing.expect(!reverse_header.hasDerivedEdgeOtherNodes());
    try std.testing.expectEqual(@as(u64, 1), reverse_header.derived_edge_id_split_index);
    try std.testing.expectEqual(@as(u16, 0), fwd_header.edge_record_len);
    try std.testing.expectEqual(@as(u16, StoredEdgeRecord.u24_node_only_encoded_len), reverse_header.edge_record_len);
    try std.testing.expect(fwd_header.hasU24NodeU32VertexRecords());
    try std.testing.expect(reverse_header.hasU24NodeU32VertexRecords());
    try std.testing.expect(!fwd_header.hasU32VertexRecords());
    try std.testing.expect(!reverse_header.hasU32VertexRecords());
    try std.testing.expect(fwd_header.hasU8RelationCounts());
    try std.testing.expect(!fwd_header.hasU16RelationCounts());
    try std.testing.expect(reverse_header.hasU8RelationCounts());
    try std.testing.expect(!reverse_header.hasU16RelationCounts());
    try std.testing.expect(!fwd_header.hasUniformRelation());
    try std.testing.expect(!reverse_header.hasUniformRelation());
    try std.testing.expect(!fwd_header.hasSingleRelationPerVertex());
    try std.testing.expect(reverse_header.hasSingleRelationPerVertex());
    try std.testing.expect(!fwd_header.hasDerivedVertexIds());
    try std.testing.expect(!reverse_header.hasDerivedVertexIds());
    try std.testing.expect(reverse_header.hasUniformSingleRelationEdgeCount());
    try std.testing.expectEqual(@as(u32, 1), reverse_header.uniform_single_relation_edge_count);
    try std.testing.expectEqual(@as(u16, VertexRecord.single_relation_rel_uniform_edges_u24_node_encoded_len), reverse_header.vertexRecordLen());
    try std.testing.expectEqual(@as(u16, 0), reverse_header.relationRecordLen());
    try std.testing.expectEqual(try fileSizeForHeader(fwd_header), fwd_size);
    try std.testing.expectEqual(try fileSizeForHeader(reverse_header), reverse_size);
    try std.testing.expectEqual(@as(u64, 168), fwd_size);
    try std.testing.expectEqual(@as(u64, 153), reverse_size);

    try std.testing.expectEqual(@as(u64, 3), fwd_header.edge_count);
    try std.testing.expectEqual(@as(u64, 3), fwd_header.relation_count);
    const vertex = (try segment.findVertex(&segment.fwd_view.?, fwd_header, 1)).?;
    try std.testing.expectEqual(@as(u64, 0), vertex.edge_offset);
    const mentions = (try segment.findRelation(&segment.fwd_view.?, fwd_header, vertex, .mentions)).?;
    try std.testing.expectEqual(@as(u64, 1), mentions.edge_offset);
    try std.testing.expectEqual(@as(u64, 1), mentions.edge_count);
}

test "immutable adjacency segment derives single-relation vertex metadata from ordinal" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const segment_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "s000001" });
    defer std.testing.allocator.free(segment_path);

    var segment = try ImmutableAdjacencySegment.build(std.testing.allocator, std.testing.io, segment_path, &.{
        .{ .edge_id = .fromInt(1), .src = .fromInt(1), .rel = .mentions, .dst = .fromInt(3) },
        .{ .edge_id = .fromInt(2), .src = .fromInt(2), .rel = .mentions, .dst = .fromInt(4) },
    });
    defer segment.deinit();

    const fwd_header = try segment.validateCachedHeader(&segment.fwd_view.?, segment.fwd_info.?, .forward);
    try std.testing.expect(!fwd_header.hasU24NodeU32EdgeRecords());
    try std.testing.expect(!fwd_header.hasU32EdgeRecords());
    try std.testing.expect(fwd_header.hasDerivedEdgeIds());
    try std.testing.expect(fwd_header.hasDerivedEdgeOtherNodes());
    try std.testing.expectEqual(@as(u16, 0), fwd_header.edge_record_len);
    try std.testing.expect(fwd_header.hasUniformRelation());
    try std.testing.expect(fwd_header.hasSingleRelationPerVertex());
    try std.testing.expect(fwd_header.hasUniformSingleRelationEdgeCount());
    try std.testing.expectEqual(@as(u32, 1), fwd_header.uniform_single_relation_edge_count);
    try std.testing.expect(fwd_header.hasDerivedVertexIds());
    try std.testing.expect(!fwd_header.hasU24NodeU32VertexRecords());
    try std.testing.expect(!fwd_header.hasU32VertexRecords());
    try std.testing.expectEqual(@as(u16, 0), fwd_header.vertexRecordLen());
    try std.testing.expectEqual(@as(u64, 2), fwd_header.vertex_count);
    try std.testing.expectEqual(@as(u64, 2), fwd_header.relation_count);

    const fwd_stat = try segment.fwd_view.?.file.stat(std.testing.io);
    try std.testing.expectEqual(try fileSizeForHeader(fwd_header), fwd_stat.size);
    try std.testing.expectEqual(@as(u64, 129), fwd_stat.size);

    const second = (try segment.findVertex(&segment.fwd_view.?, fwd_header, 2)).?;
    try std.testing.expectEqual(@as(u64, 1), second.relation_offset);
    try std.testing.expectEqual(@as(u64, 1), second.relation_count);
    try std.testing.expectEqual(@as(u64, 1), second.edge_offset);

    const relation = (try segment.findRelation(&segment.fwd_view.?, fwd_header, second, .mentions)).?;
    try std.testing.expectEqual(@as(u64, 1), relation.edge_offset);
    try std.testing.expectEqual(@as(u64, 1), relation.edge_count);
}

test "immutable adjacency segment stores non-uniform single relation in vertex rows" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const segment_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "s000001" });
    defer std.testing.allocator.free(segment_path);

    var segment = try ImmutableAdjacencySegment.build(std.testing.allocator, std.testing.io, segment_path, &.{
        .{ .edge_id = .fromInt(1), .src = .fromInt(1), .rel = .defines, .dst = .fromInt(3) },
        .{ .edge_id = .fromInt(2), .src = .fromInt(2), .rel = .mentions, .dst = .fromInt(4) },
    });
    defer segment.deinit();

    const fwd_header = try segment.validateCachedHeader(&segment.fwd_view.?, segment.fwd_info.?, .forward);
    try std.testing.expect(fwd_header.hasDerivedEdgeIds());
    try std.testing.expect(fwd_header.hasDerivedEdgeOtherNodes());
    try std.testing.expect(!fwd_header.hasUniformRelation());
    try std.testing.expect(fwd_header.hasSingleRelationPerVertex());
    try std.testing.expect(fwd_header.hasUniformSingleRelationEdgeCount());
    try std.testing.expectEqual(@as(u32, 1), fwd_header.uniform_single_relation_edge_count);
    try std.testing.expect(!fwd_header.hasDerivedVertexIds());
    try std.testing.expect(fwd_header.hasU24NodeU32VertexRecords());
    try std.testing.expectEqual(@as(u16, VertexRecord.single_relation_rel_uniform_edges_u24_node_encoded_len), fwd_header.vertexRecordLen());
    try std.testing.expectEqual(@as(u16, 0), fwd_header.relationRecordLen());
    try std.testing.expectEqual(@as(u64, 2), fwd_header.vertex_count);
    try std.testing.expectEqual(@as(u64, 2), fwd_header.relation_count);

    const fwd_stat = try segment.fwd_view.?.file.stat(std.testing.io);
    try std.testing.expectEqual(try fileSizeForHeader(fwd_header), fwd_stat.size);
    try std.testing.expectEqual(@as(u64, 139), fwd_stat.size);

    const first = (try segment.findVertex(&segment.fwd_view.?, fwd_header, 1)).?;
    try std.testing.expectEqual(@as(u64, 0), first.relation_offset);
    try std.testing.expectEqual(@intFromEnum(core.RelKind.defines), first.single_relation_rel);
    const defines = (try segment.findRelation(&segment.fwd_view.?, fwd_header, first, .defines)).?;
    try std.testing.expectEqual(@as(u64, 0), defines.edge_offset);
    try std.testing.expectEqual(@as(u64, 1), defines.edge_count);
    try std.testing.expectEqual(null, try segment.findRelation(&segment.fwd_view.?, fwd_header, first, .mentions));

    const second = (try segment.findVertex(&segment.fwd_view.?, fwd_header, 2)).?;
    try std.testing.expectEqual(@intFromEnum(core.RelKind.mentions), second.single_relation_rel);
    const mentions = (try segment.findRelation(&segment.fwd_view.?, fwd_header, second, .mentions)).?;
    try std.testing.expectEqual(@as(u64, 1), mentions.edge_offset);
    try std.testing.expectEqual(@as(u64, 1), mentions.edge_count);
}

test "immutable adjacency segment keeps u64 edge rows for high ids" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const segment_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "s000001" });
    defer std.testing.allocator.free(segment_path);

    const high_node_id: u64 = @as(u64, std.math.maxInt(u32)) + 1;
    const high_edge_id: u64 = @as(u64, std.math.maxInt(u32)) + 7;
    var segment = try ImmutableAdjacencySegment.build(std.testing.allocator, std.testing.io, segment_path, &.{
        .{ .edge_id = .fromInt(high_edge_id), .src = .fromInt(1), .rel = .mentions, .dst = .fromInt(high_node_id) },
    });
    defer segment.deinit();

    const fwd_header = try segment.validateCachedHeader(&segment.fwd_view.?, segment.fwd_info.?, .forward);
    const rev_header = try segment.validateCachedHeader(&segment.rev_view.?, segment.rev_info.?, .reverse);
    try std.testing.expect(!fwd_header.hasU24NodeU32EdgeRecords());
    try std.testing.expect(!rev_header.hasU24NodeU32EdgeRecords());
    try std.testing.expect(!fwd_header.hasU32EdgeRecords());
    try std.testing.expect(!rev_header.hasU32EdgeRecords());
    try std.testing.expect(fwd_header.hasDerivedEdgeIds());
    try std.testing.expect(rev_header.hasDerivedEdgeIds());
    try std.testing.expect(fwd_header.hasDerivedEdgeOtherNodes());
    try std.testing.expect(rev_header.hasDerivedEdgeOtherNodes());
    try std.testing.expect(!fwd_header.hasU24NodeU32VertexRecords());
    try std.testing.expect(!fwd_header.hasU32VertexRecords());
    try std.testing.expect(!rev_header.hasU24NodeU32VertexRecords());
    try std.testing.expect(!rev_header.hasU32VertexRecords());
    try std.testing.expect(fwd_header.hasU8RelationCounts());
    try std.testing.expect(!fwd_header.hasU16RelationCounts());
    try std.testing.expect(rev_header.hasU8RelationCounts());
    try std.testing.expect(!rev_header.hasU16RelationCounts());
    try std.testing.expect(fwd_header.hasUniformRelation());
    try std.testing.expect(rev_header.hasUniformRelation());
    try std.testing.expect(fwd_header.hasSingleRelationPerVertex());
    try std.testing.expect(rev_header.hasSingleRelationPerVertex());
    try std.testing.expect(fwd_header.hasDerivedVertexIds());
    try std.testing.expect(rev_header.hasDerivedVertexIds());
    try std.testing.expectEqual(@as(u16, 0), fwd_header.edge_record_len);
    try std.testing.expectEqual(@as(u16, 0), rev_header.edge_record_len);
    try std.testing.expectEqual(@as(u16, 0), fwd_header.vertexRecordLen());
    try std.testing.expectEqual(@as(u16, 0), rev_header.vertexRecordLen());

    const fwd_stat = try segment.fwd_view.?.file.stat(std.testing.io);
    const rev_stat = try segment.rev_view.?.file.stat(std.testing.io);
    try std.testing.expectEqual(try fileSizeForHeader(fwd_header), fwd_stat.size);
    try std.testing.expectEqual(try fileSizeForHeader(rev_header), rev_stat.size);
    try std.testing.expectEqual(@as(u64, 129), fwd_stat.size);
    try std.testing.expectEqual(@as(u64, 129), rev_stat.size);

    var out = try segment.neighbors(std.testing.allocator, .forward, .fromInt(1), .mentions, 10);
    defer out.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expectEqual(high_edge_id, out.items[0].edge_id.toInt());
    try std.testing.expectEqual(high_node_id, out.items[0].dst.toInt());
}

test "immutable adjacency segment falls back to u32 rows above u24 ids" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const segment_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "s000001" });
    defer std.testing.allocator.free(segment_path);

    const high_u24_node_id: u64 = VertexRecord.u24_node_max + 1;
    var segment = try ImmutableAdjacencySegment.build(std.testing.allocator, std.testing.io, segment_path, &.{
        .{ .edge_id = .fromInt(1), .src = .fromInt(high_u24_node_id), .rel = .mentions, .dst = .fromInt(high_u24_node_id + 1) },
    });
    defer segment.deinit();

    const fwd_header = try segment.validateCachedHeader(&segment.fwd_view.?, segment.fwd_info.?, .forward);
    const rev_header = try segment.validateCachedHeader(&segment.rev_view.?, segment.rev_info.?, .reverse);
    try std.testing.expect(!fwd_header.hasU24NodeU32EdgeRecords());
    try std.testing.expect(!rev_header.hasU24NodeU32EdgeRecords());
    try std.testing.expect(!fwd_header.hasU32EdgeRecords());
    try std.testing.expect(!rev_header.hasU32EdgeRecords());
    try std.testing.expect(fwd_header.hasDerivedEdgeIds());
    try std.testing.expect(rev_header.hasDerivedEdgeIds());
    try std.testing.expect(fwd_header.hasDerivedEdgeOtherNodes());
    try std.testing.expect(rev_header.hasDerivedEdgeOtherNodes());
    try std.testing.expect(!fwd_header.hasU24NodeU32VertexRecords());
    try std.testing.expect(!rev_header.hasU24NodeU32VertexRecords());
    try std.testing.expect(!fwd_header.hasU32VertexRecords());
    try std.testing.expect(!rev_header.hasU32VertexRecords());
    try std.testing.expect(fwd_header.hasDerivedVertexIds());
    try std.testing.expect(rev_header.hasDerivedVertexIds());
    try std.testing.expectEqual(@as(u16, 0), fwd_header.edge_record_len);
    try std.testing.expectEqual(@as(u16, 0), rev_header.edge_record_len);
    try std.testing.expectEqual(@as(u16, 0), fwd_header.vertexRecordLen());
    try std.testing.expectEqual(@as(u16, 0), rev_header.vertexRecordLen());
}

test "immutable adjacency segment keeps u64 relation count rows for large ranges" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const segment_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "s000001" });
    defer std.testing.allocator.free(segment_path);

    const edge_count = @as(usize, std.math.maxInt(u16)) + 1;
    const edges = try std.testing.allocator.alloc(EdgeRecord, edge_count);
    defer std.testing.allocator.free(edges);
    for (edges, 0..) |*edge, index| {
        edge.* = .{
            .edge_id = .fromInt(@as(u64, @intCast(index + 1))),
            .src = .fromInt(1),
            .rel = .mentions,
            .dst = .fromInt(2),
        };
    }

    var segment = try ImmutableAdjacencySegment.build(std.testing.allocator, std.testing.io, segment_path, edges);
    defer segment.deinit();

    const fwd_header = try segment.validateCachedHeader(&segment.fwd_view.?, segment.fwd_info.?, .forward);
    const rev_header = try segment.validateCachedHeader(&segment.rev_view.?, segment.rev_info.?, .reverse);
    try std.testing.expect(fwd_header.hasU24NodeU32EdgeRecords());
    try std.testing.expect(rev_header.hasU24NodeU32EdgeRecords());
    try std.testing.expect(!fwd_header.hasU32EdgeRecords());
    try std.testing.expect(!rev_header.hasU32EdgeRecords());
    try std.testing.expect(fwd_header.hasDerivedEdgeIds());
    try std.testing.expect(rev_header.hasDerivedEdgeIds());
    try std.testing.expect(!fwd_header.hasDerivedEdgeOtherNodes());
    try std.testing.expect(!rev_header.hasDerivedEdgeOtherNodes());
    try std.testing.expect(!fwd_header.hasU24NodeU32VertexRecords());
    try std.testing.expect(!rev_header.hasU24NodeU32VertexRecords());
    try std.testing.expect(!fwd_header.hasU32VertexRecords());
    try std.testing.expect(!rev_header.hasU32VertexRecords());
    try std.testing.expect(!fwd_header.hasU16RelationCounts());
    try std.testing.expect(!rev_header.hasU16RelationCounts());
    try std.testing.expect(fwd_header.hasUniformRelation());
    try std.testing.expect(rev_header.hasUniformRelation());
    try std.testing.expect(fwd_header.hasSingleRelationPerVertex());
    try std.testing.expect(rev_header.hasSingleRelationPerVertex());
    try std.testing.expect(fwd_header.hasDerivedVertexIds());
    try std.testing.expect(rev_header.hasDerivedVertexIds());
    try std.testing.expectEqual(@as(u16, StoredEdgeRecord.u24_node_only_encoded_len), fwd_header.edge_record_len);
    try std.testing.expectEqual(@as(u16, StoredEdgeRecord.u24_node_only_encoded_len), rev_header.edge_record_len);
    try std.testing.expectEqual(@as(u16, 0), fwd_header.vertexRecordLen());
    try std.testing.expectEqual(@as(u16, 0), rev_header.vertexRecordLen());
    try std.testing.expectEqual(@as(u64, 1), fwd_header.relation_count);
    try std.testing.expectEqual(@as(u64, 1), rev_header.relation_count);

    const fwd_stat = try segment.fwd_view.?.file.stat(std.testing.io);
    const rev_stat = try segment.rev_view.?.file.stat(std.testing.io);
    try std.testing.expectEqual(try fileSizeForHeader(fwd_header), fwd_stat.size);
    try std.testing.expectEqual(try fileSizeForHeader(rev_header), rev_stat.size);
    try std.testing.expectEqual(@as(u64, 196737), fwd_stat.size);
    try std.testing.expectEqual(@as(u64, 196737), rev_stat.size);
}

test "immutable adjacency segment falls back to u16 relation counts above u8 ranges" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const segment_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "s000001" });
    defer std.testing.allocator.free(segment_path);

    const edge_count = @as(usize, std.math.maxInt(u8)) + 2;
    const edges = try std.testing.allocator.alloc(EdgeRecord, edge_count);
    defer std.testing.allocator.free(edges);
    for (edges[0..256], 0..) |*edge, index| {
        edge.* = .{
            .edge_id = .fromInt(@as(u64, @intCast(index + 1))),
            .src = .fromInt(1),
            .rel = .defines,
            .dst = .fromInt(@as(u64, @intCast(index + 2))),
        };
    }
    edges[256] = .{
        .edge_id = .fromInt(257),
        .src = .fromInt(1),
        .rel = .mentions,
        .dst = .fromInt(258),
    };

    var segment = try ImmutableAdjacencySegment.build(std.testing.allocator, std.testing.io, segment_path, edges);
    defer segment.deinit();

    const fwd_header = try segment.validateCachedHeader(&segment.fwd_view.?, segment.fwd_info.?, .forward);
    try std.testing.expect(!fwd_header.hasU8RelationCounts());
    try std.testing.expect(fwd_header.hasU16RelationCounts());
    try std.testing.expect(!fwd_header.hasUniformRelation());
    try std.testing.expect(!fwd_header.hasSingleRelationPerVertex());
    try std.testing.expectEqual(@as(u16, RelationRangeRecord.u16_encoded_len), fwd_header.relationRecordLen());
}

test "immutable adjacency segment rejects relation count not derived from vertex directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const segment_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "s000001" });
    defer std.testing.allocator.free(segment_path);

    {
        var segment = try ImmutableAdjacencySegment.build(std.testing.allocator, std.testing.io, segment_path, &.{
            .{ .edge_id = .fromInt(1), .src = .fromInt(1), .rel = .defines, .dst = .fromInt(2) },
            .{ .edge_id = .fromInt(2), .src = .fromInt(1), .rel = .mentions, .dst = .fromInt(3) },
        });
        defer segment.deinit();
    }

    const fwd_path = try std.fs.path.join(std.testing.allocator, &.{ segment_path, "edge_fwd.csr" });
    defer std.testing.allocator.free(fwd_path);
    var file = try std.Io.Dir.cwd().openFile(std.testing.io, fwd_path, .{ .mode = .read_write });
    defer file.close(std.testing.io);
    const size = (try file.stat(std.testing.io)).size;
    try file.setLength(std.testing.io, size + 1);

    try std.testing.expectError(error.InvalidRecord, ImmutableAdjacencySegment.open(std.testing.allocator, std.testing.io, segment_path));
    try file.setLength(std.testing.io, size + RelationRangeRecord.encoded_len);
    try std.testing.expectError(error.InvalidRecord, ImmutableAdjacencySegment.openTrustedDirectionForQuery(std.testing.allocator, std.testing.io, segment_path, .forward, 2));
    try file.setLength(std.testing.io, size + StoredEdgeRecord.encoded_len);
    try std.testing.expectError(error.InvalidRecord, ImmutableAdjacencySegment.openTrustedDirectionForQuery(std.testing.allocator, std.testing.io, segment_path, .forward, 2));
    try std.testing.expectError(error.InvalidRecord, ImmutableAdjacencySegment.open(std.testing.allocator, std.testing.io, segment_path));
    try file.setLength(std.testing.io, size);
    var view = try CsrFileView.open(std.testing.io, fwd_path);
    const header = try readHeader(&view);
    const relation_count_field = try relationRecordOffset(header, 0) + 2;
    const relation_count_len: usize = if (header.hasU8RelationCounts()) 1 else if (header.hasU16RelationCounts()) 2 else 8;
    view.deinit();
    var zero_count: [8]u8 = @splat(0);
    try file.writePositionalAll(std.testing.io, zero_count[0..relation_count_len], relation_count_field);
    try std.testing.expectError(error.InvalidRecord, ImmutableAdjacencySegment.open(std.testing.allocator, std.testing.io, segment_path));
    try file.setLength(std.testing.io, SegmentHeader.encoded_len + StoredEdgeRecord.encoded_len);
    try std.testing.expectError(error.InvalidRecord, ImmutableAdjacencySegment.openTrustedDirectionForQuery(std.testing.allocator, std.testing.io, segment_path, .forward, 2));
}

test "immutable adjacency segment build keeps input edge order unchanged" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const segment_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "s000001" });
    defer std.testing.allocator.free(segment_path);

    var edges = [_]EdgeRecord{
        .{ .edge_id = .fromInt(3), .src = .fromInt(2), .rel = .mentions, .dst = .fromInt(1) },
        .{ .edge_id = .fromInt(1), .src = .fromInt(1), .rel = .defines, .dst = .fromInt(2) },
        .{ .edge_id = .fromInt(2), .src = .fromInt(1), .rel = .mentions, .dst = .fromInt(3) },
    };
    const original = edges;

    var segment = try ImmutableAdjacencySegment.build(std.testing.allocator, std.testing.io, segment_path, &edges);
    defer segment.deinit();

    try std.testing.expectEqual(original, edges);
    var out = try segment.neighbors(std.testing.allocator, .forward, .fromInt(1), null, 10);
    defer out.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), out.items.len);
}

test "immutable adjacency segment exposes edge id range for pruning" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const segment_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "s000001" });
    defer std.testing.allocator.free(segment_path);

    var segment = try ImmutableAdjacencySegment.build(std.testing.allocator, std.testing.io, segment_path, &.{
        .{ .edge_id = .fromInt(42), .src = .fromInt(2), .rel = .mentions, .dst = .fromInt(1) },
        .{ .edge_id = .fromInt(7), .src = .fromInt(1), .rel = .defines, .dst = .fromInt(2) },
        .{ .edge_id = .fromInt(19), .src = .fromInt(1), .rel = .mentions, .dst = .fromInt(3) },
    });
    defer segment.deinit();

    const range = (try segment.edgeIdRange()).?;
    try std.testing.expectEqual(@as(u64, 7), range.min);
    try std.testing.expectEqual(@as(u64, 42), range.max);
    try std.testing.expect(!try segment.mayContainEdgeId(6));
    try std.testing.expect(try segment.mayContainEdgeId(19));
    try std.testing.expect(!try segment.mayContainEdgeId(43));
    try std.testing.expect(!try segment.edgeIdRangeMayIntersect(1, 6));
    try std.testing.expect(try segment.edgeIdRangeMayIntersect(40, 100));
}

test "immutable adjacency segment keeps csr views open across queries" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const segment_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "s000001" });
    defer std.testing.allocator.free(segment_path);

    {
        var built = try ImmutableAdjacencySegment.build(std.testing.allocator, std.testing.io, segment_path, &.{
            .{ .edge_id = .fromInt(1), .src = .fromInt(1), .rel = .defines, .dst = .fromInt(2) },
        });
        defer built.deinit();
        try std.testing.expect(built.fwd_view != null);
        try std.testing.expect(built.rev_view != null);
    }

    var segment = try ImmutableAdjacencySegment.open(std.testing.allocator, std.testing.io, segment_path);
    defer segment.deinit();
    try std.testing.expect(segment.fwd_view != null);
    try std.testing.expect(segment.rev_view != null);

    var first = try segment.neighbors(std.testing.allocator, .forward, .fromInt(1), .defines, 1);
    defer first.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), first.items.len);

    var second = try segment.neighbors(std.testing.allocator, .reverse, .fromInt(2), .defines, 1);
    defer second.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), second.items.len);
}

test "immutable adjacency segment trusted query open skips full validation APIs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const segment_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "s000001" });
    defer std.testing.allocator.free(segment_path);

    {
        var built = try ImmutableAdjacencySegment.build(std.testing.allocator, std.testing.io, segment_path, &.{
            .{ .edge_id = .fromInt(1), .src = .fromInt(1), .rel = .defines, .dst = .fromInt(2) },
            .{ .edge_id = .fromInt(2), .src = .fromInt(1), .rel = .mentions, .dst = .fromInt(3) },
        });
        defer built.deinit();
    }

    var segment = try ImmutableAdjacencySegment.openTrustedForQuery(std.testing.allocator, std.testing.io, segment_path, 2);
    defer segment.deinit();

    var out = try segment.neighbors(std.testing.allocator, .forward, .fromInt(1), .mentions, 10);
    defer out.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expectEqual(@as(u64, 3), out.items[0].dst.toInt());

    try std.testing.expectError(error.InvalidRecord, segment.edgeDigest());
    try std.testing.expectError(error.InvalidRecord, segment.edgeIdSummary());
}

test "immutable adjacency segment trusted query derives edge relation from directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const segment_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "s000001" });
    defer std.testing.allocator.free(segment_path);

    {
        var built = try ImmutableAdjacencySegment.build(std.testing.allocator, std.testing.io, segment_path, &.{
            .{ .edge_id = .fromInt(1), .src = .fromInt(1), .rel = .defines, .dst = .fromInt(2) },
            .{ .edge_id = .fromInt(2), .src = .fromInt(1), .rel = .mentions, .dst = .fromInt(3) },
        });
        defer built.deinit();
    }

    var segment = try ImmutableAdjacencySegment.openTrustedForQuery(std.testing.allocator, std.testing.io, segment_path, 2);
    defer segment.deinit();
    const header = try segment.validateCachedHeader(&segment.fwd_view.?, segment.fwd_info.?, .forward);
    try std.testing.expect(!header.hasU24NodeU32EdgeRecords());
    try std.testing.expect(!header.hasU32EdgeRecords());
    try std.testing.expect(header.hasDerivedEdgeIds());
    try std.testing.expect(header.hasDerivedEdgeOtherNodes());
    try std.testing.expectEqual(@as(u16, 0), header.edge_record_len);

    var defines = try segment.neighbors(std.testing.allocator, .forward, .fromInt(1), .defines, 10);
    defer defines.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), defines.items.len);
    try std.testing.expectEqual(core.RelKind.defines, defines.items[0].rel);
    try std.testing.expectEqual(@as(u64, 2), defines.items[0].dst.toInt());

    var mentions = try segment.neighbors(std.testing.allocator, .forward, .fromInt(1), .mentions, 10);
    defer mentions.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), mentions.items.len);
    try std.testing.expectEqual(core.RelKind.mentions, mentions.items[0].rel);
    try std.testing.expectEqual(@as(u64, 3), mentions.items[0].dst.toInt());
}

test "immutable adjacency segment builds csr across buffered write flushes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const segment_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "s000001" });
    defer std.testing.allocator.free(segment_path);

    var edges = std.ArrayList(EdgeRecord).empty;
    defer edges.deinit(std.testing.allocator);
    try edges.ensureTotalCapacity(std.testing.allocator, 9000);
    for (0..9000) |idx| {
        edges.appendAssumeCapacity(.{
            .edge_id = .fromInt(@intCast(idx + 1)),
            .src = .fromInt(1),
            .rel = .mentions,
            .dst = .fromInt(@intCast(idx + 2)),
        });
    }

    var segment = try ImmutableAdjacencySegment.build(std.testing.allocator, std.testing.io, segment_path, edges.items);
    defer segment.deinit();

    var out = try segment.neighbors(std.testing.allocator, .forward, .fromInt(1), .mentions, edges.items.len);
    defer out.deinit(std.testing.allocator);
    try std.testing.expectEqual(edges.items.len, out.items.len);
    try std.testing.expectEqual(@as(u64, 2), out.items[0].dst.toInt());
    try std.testing.expectEqual(@as(u64, 9001), out.items[out.items.len - 1].dst.toInt());
}

test "immutable adjacency segment buffers unmapped neighbor range scans" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const segment_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "s000001" });
    defer std.testing.allocator.free(segment_path);

    var edges = std.ArrayList(EdgeRecord).empty;
    defer edges.deinit(std.testing.allocator);
    try edges.ensureTotalCapacity(std.testing.allocator, 9000);
    for (0..9000) |idx| {
        edges.appendAssumeCapacity(.{
            .edge_id = .fromInt(@intCast(idx + 1)),
            .src = .fromInt(1),
            .rel = .mentions,
            .dst = .fromInt(@intCast(idx + 2)),
        });
    }

    var segment = try ImmutableAdjacencySegment.build(std.testing.allocator, std.testing.io, segment_path, edges.items);
    defer segment.deinit();
    if (segment.fwd_view) |*view| {
        if (view.map) |*map| {
            map.destroy(view.io);
            view.map = null;
        }
    }

    var context = TestNeighborCountContext{};
    try std.testing.expect(!try segment.forEachNeighbor(.forward, .fromInt(1), .mentions, edges.items.len, &context, countNeighbor));
    try std.testing.expectEqual(edges.items.len, context.count);
}

test "immutable adjacency segment streams neighbors and can stop before materializing range" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const segment_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "s000001" });
    defer std.testing.allocator.free(segment_path);

    var segment = try ImmutableAdjacencySegment.build(std.testing.allocator, std.testing.io, segment_path, &.{
        .{ .edge_id = .fromInt(1), .src = .fromInt(1), .rel = .mentions, .dst = .fromInt(2) },
        .{ .edge_id = .fromInt(3), .src = .fromInt(1), .rel = .mentions, .dst = .fromInt(3) },
        .{ .edge_id = .fromInt(4), .src = .fromInt(1), .rel = .mentions, .dst = .fromInt(4) },
        .{ .edge_id = .fromInt(8), .src = .fromInt(1), .rel = .mentions, .dst = .fromInt(5) },
        .{ .edge_id = .fromInt(9), .src = .fromInt(1), .rel = .mentions, .dst = .fromInt(6) },
    });
    defer segment.deinit();

    {
        var file = try std.Io.Dir.cwd().openFile(std.testing.io, segment.fwd_path, .{ .mode = .read_write });
        defer file.close(std.testing.io);
        const header = try readHeader(&segment.fwd_view.?);
        try std.testing.expect(!header.hasDerivedEdgeIds());
        const second_edge_id = try edgeBaseOffsetForHeader(header) + header.edge_record_len + storedEdgeIdFieldOffset(header);
        var edge_id_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &edge_id_bytes, 0, .little);
        try file.writePositionalAll(std.testing.io, &edge_id_bytes, second_edge_id);
    }

    var stopped = TestNeighborCountContext{};
    try std.testing.expect(try segment.forEachNeighbor(.forward, .fromInt(1), .mentions, 10, &stopped, stopAfterFirstNeighbor));
    try std.testing.expectEqual(@as(usize, 1), stopped.count);

    var full = TestNeighborCountContext{};
    try std.testing.expectError(
        error.InvalidRecord,
        segment.forEachNeighbor(.forward, .fromInt(1), .mentions, 10, &full, countNeighbor),
    );
    try std.testing.expectEqual(@as(usize, 1), full.count);
}

test "immutable adjacency segment streaming enforces edge budget" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const segment_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "s000001" });
    defer std.testing.allocator.free(segment_path);

    var segment = try ImmutableAdjacencySegment.build(std.testing.allocator, std.testing.io, segment_path, &.{
        .{ .edge_id = .fromInt(2), .src = .fromInt(1), .rel = .mentions, .dst = .fromInt(2) },
        .{ .edge_id = .fromInt(1), .src = .fromInt(1), .rel = .mentions, .dst = .fromInt(3) },
    });
    defer segment.deinit();

    var context = TestNeighborCountContext{};
    try std.testing.expectError(
        core.Error.BudgetExceeded,
        segment.forEachNeighbor(.forward, .fromInt(1), .mentions, 1, &context, countNeighbor),
    );
    try std.testing.expectEqual(@as(usize, 1), context.count);
}

test "immutable adjacency segment enforces limits and validates ids" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const segment_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "s000001" });
    defer std.testing.allocator.free(segment_path);

    var segment = try ImmutableAdjacencySegment.build(std.testing.allocator, std.testing.io, segment_path, &.{
        .{ .edge_id = .fromInt(2), .src = .fromInt(1), .rel = .mentions, .dst = .fromInt(2) },
        .{ .edge_id = .fromInt(1), .src = .fromInt(1), .rel = .mentions, .dst = .fromInt(3) },
    });
    defer segment.deinit();

    try std.testing.expectError(
        core.Error.BudgetExceeded,
        segment.neighbors(std.testing.allocator, .forward, .fromInt(1), null, 1),
    );

    try std.testing.expectError(
        core.Error.BudgetExceeded,
        segment.neighbors(std.testing.allocator, .forward, .fromInt(1), null, 0),
    );

    try std.testing.expectError(
        core.Error.BudgetExceeded,
        segment.neighbors(std.testing.allocator, .forward, .fromInt(1), .mentions, 1),
    );

    var complete = try segment.neighbors(std.testing.allocator, .forward, .fromInt(1), null, 2);
    defer complete.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), complete.items.len);

    try std.testing.expectError(core.Error.InvalidId, segment.neighbors(std.testing.allocator, .forward, .none, null, 1));
    try std.testing.expectError(core.Error.InvalidId, ImmutableAdjacencySegment.build(std.testing.allocator, std.testing.io, segment_path, &.{
        .{ .edge_id = .fromInt(1), .src = .none, .rel = .mentions, .dst = .fromInt(2) },
    }));
}

test "immutable adjacency segment validates ids before creating directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const segment_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "invalid-segment" });
    defer std.testing.allocator.free(segment_path);

    try std.testing.expectError(core.Error.InvalidId, ImmutableAdjacencySegment.build(std.testing.allocator, std.testing.io, segment_path, &.{
        .{ .edge_id = .fromInt(2), .src = .fromInt(1), .rel = .mentions, .dst = .fromInt(2) },
        .{ .edge_id = .fromInt(2), .src = .fromInt(1), .rel = .defines, .dst = .fromInt(3) },
    }));
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().openDir(std.testing.io, segment_path, .{}));
}

test "immutable adjacency segment relation filter skips unrelated edge ranges" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const segment_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "s000001" });
    defer std.testing.allocator.free(segment_path);

    var segment = try ImmutableAdjacencySegment.build(std.testing.allocator, std.testing.io, segment_path, &.{
        .{ .edge_id = .fromInt(1), .src = .fromInt(1), .rel = .defines, .dst = .fromInt(2) },
        .{ .edge_id = .fromInt(2), .src = .fromInt(1), .rel = .defines, .dst = .fromInt(5) },
        .{ .edge_id = .fromInt(3), .src = .fromInt(1), .rel = .mentions, .dst = .fromInt(3) },
        .{ .edge_id = .fromInt(4), .src = .fromInt(1), .rel = .mentions, .dst = .fromInt(4) },
        .{ .edge_id = .fromInt(5), .src = .fromInt(1), .rel = .mentions, .dst = .fromInt(6) },
    });
    defer segment.deinit();

    {
        var file = try std.Io.Dir.cwd().openFile(std.testing.io, segment.fwd_path, .{ .mode = .read_write });
        defer file.close(std.testing.io);
        const header = try readHeader(&segment.fwd_view.?);
        try std.testing.expect(!header.hasDerivedEdgeOtherNodes());
        const first_edge_other_node = try edgeBaseOffsetForHeader(header);
        var node_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &node_bytes, 0, .little);
        try file.writePositionalAll(std.testing.io, node_bytes[0..storedEdgeOtherNodeFieldLen(header)], first_edge_other_node);
    }

    var mentions = try segment.neighbors(std.testing.allocator, .forward, .fromInt(1), .mentions, 10);
    defer mentions.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), mentions.items.len);
    try std.testing.expectEqual(@as(u64, 3), mentions.items[0].dst.toInt());

    try std.testing.expectError(error.InvalidRecord, segment.neighbors(std.testing.allocator, .forward, .fromInt(1), null, 10));
}

test "immutable adjacency segment rejects header mutation after open" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const segment_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "s000001" });
    defer std.testing.allocator.free(segment_path);

    var segment = try ImmutableAdjacencySegment.build(std.testing.allocator, std.testing.io, segment_path, &.{
        .{ .edge_id = .fromInt(1), .src = .fromInt(1), .rel = .mentions, .dst = .fromInt(2) },
    });
    defer segment.deinit();

    {
        var file = try std.Io.Dir.cwd().openFile(std.testing.io, segment.fwd_path, .{ .mode = .read_write });
        defer file.close(std.testing.io);
        var vertex_count: [8]u8 = undefined;
        std.mem.writeInt(u64, &vertex_count, 2, .little);
        try file.writePositionalAll(std.testing.io, &vertex_count, 9);
    }

    try std.testing.expectError(
        error.InvalidRecord,
        segment.neighbors(std.testing.allocator, .forward, .fromInt(1), .mentions, 1),
    );
}

test "immutable adjacency segment rejects corrupt uniform fanout header" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const segment_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "s000001" });
    defer std.testing.allocator.free(segment_path);

    var segment = try ImmutableAdjacencySegment.build(std.testing.allocator, std.testing.io, segment_path, &.{
        .{ .edge_id = .fromInt(1), .src = .fromInt(1), .rel = .mentions, .dst = .fromInt(3) },
        .{ .edge_id = .fromInt(2), .src = .fromInt(2), .rel = .mentions, .dst = .fromInt(4) },
    });
    segment.deinit();

    const fwd_path = try std.fs.path.join(std.testing.allocator, &.{ segment_path, "edge_fwd.csr" });
    defer std.testing.allocator.free(fwd_path);
    {
        var file = try std.Io.Dir.cwd().openFile(std.testing.io, fwd_path, .{ .mode = .read_write });
        defer file.close(std.testing.io);
        var fanout: [4]u8 = undefined;
        std.mem.writeInt(u32, &fanout, 2, .little);
        try file.writePositionalAll(std.testing.io, &fanout, 21);
    }

    try std.testing.expectError(error.InvalidRecord, ImmutableAdjacencySegment.open(std.testing.allocator, std.testing.io, segment_path));
}

test "immutable adjacency segment rejects corrupt derived edge id header" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const segment_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "s000001" });
    defer std.testing.allocator.free(segment_path);

    var segment = try ImmutableAdjacencySegment.build(std.testing.allocator, std.testing.io, segment_path, &.{
        .{ .edge_id = .fromInt(1), .src = .fromInt(1), .rel = .mentions, .dst = .fromInt(3) },
        .{ .edge_id = .fromInt(2), .src = .fromInt(2), .rel = .mentions, .dst = .fromInt(4) },
    });
    segment.deinit();

    const fwd_path = try std.fs.path.join(std.testing.allocator, &.{ segment_path, "edge_fwd.csr" });
    defer std.testing.allocator.free(fwd_path);
    {
        var file = try std.Io.Dir.cwd().openFile(std.testing.io, fwd_path, .{ .mode = .read_write });
        defer file.close(std.testing.io);
        var step: [4]u8 = undefined;
        std.mem.writeInt(u32, &step, 2, .little);
        try file.writePositionalAll(std.testing.io, &step, 33);
    }

    try std.testing.expectError(error.InvalidRecord, ImmutableAdjacencySegment.open(std.testing.allocator, std.testing.io, segment_path));
}

test "immutable adjacency segment summarizes written streams without opening views" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const segment_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "s000001" });
    defer std.testing.allocator.free(segment_path);

    var segment = try ImmutableAdjacencySegment.initEmpty(std.testing.allocator, std.testing.io, segment_path);
    defer segment.deinit();

    const forward = [_]EdgeRecord{
        .{ .edge_id = .fromInt(1), .src = .fromInt(1), .rel = .defines, .dst = .fromInt(3) },
        .{ .edge_id = .fromInt(2), .src = .fromInt(2), .rel = .mentions, .dst = .fromInt(4) },
    };
    const reverse = [_]EdgeRecord{
        .{ .edge_id = .fromInt(1), .src = .fromInt(1), .rel = .defines, .dst = .fromInt(3) },
        .{ .edge_id = .fromInt(2), .src = .fromInt(2), .rel = .mentions, .dst = .fromInt(4) },
    };

    const forward_summary = try segment.writeOrderedRecordsSummary(.forward, EdgeRecord, &forward, edgeRecordIdentity);
    var reverse_summary = try segment.writeOrderedRecordsSummary(.reverse, EdgeRecord, &reverse, edgeRecordIdentity);
    const summary = try ImmutableAdjacencySegment.summarizeWrittenEdgeStreams(forward_summary, reverse_summary);
    try std.testing.expectEqual(@as(u64, 2), summary.edge_count);
    try std.testing.expectEqual(@as(u64, 1), summary.endpoint_summary.src_range.min);
    try std.testing.expectEqual(@as(u64, 2), summary.endpoint_summary.src_range.max);
    try std.testing.expectEqual(@as(u64, 3), summary.endpoint_summary.dst_range.min);
    try std.testing.expectEqual(@as(u64, 4), summary.endpoint_summary.dst_range.max);

    reverse_summary.edge_id_summary.digest ^= 1;
    try std.testing.expectError(error.InvalidRecord, ImmutableAdjacencySegment.summarizeWrittenEdgeStreams(forward_summary, reverse_summary));
}

test "immutable adjacency segment open rejects corrupt headers" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const segment_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "s000001" });
    defer std.testing.allocator.free(segment_path);

    var segment = try ImmutableAdjacencySegment.build(std.testing.allocator, std.testing.io, segment_path, &.{
        .{ .edge_id = .fromInt(1), .src = .fromInt(1), .rel = .mentions, .dst = .fromInt(2) },
    });
    segment.deinit();

    const fwd_path = try std.fs.path.join(std.testing.allocator, &.{ segment_path, "edge_fwd.csr" });
    defer std.testing.allocator.free(fwd_path);
    var file = try std.Io.Dir.cwd().openFile(std.testing.io, fwd_path, .{ .mode = .read_write });
    try file.writePositionalAll(std.testing.io, "BAD!", 0);
    file.close(std.testing.io);

    try std.testing.expectError(error.InvalidRecord, ImmutableAdjacencySegment.open(std.testing.allocator, std.testing.io, segment_path));
}

test "immutable adjacency segment header rejects overlapping compact shapes" {
    var edge_header = SegmentHeader{ .order = .forward, .edge_count = 0, .vertex_count = 0, .relation_count = 0 };
    edge_header.flags = SegmentHeader.flag_u32_edge_records | SegmentHeader.flag_u24_node_u32_edge_records;
    edge_header.edge_record_len = StoredEdgeRecord.u24_node_u32_edge_encoded_len;
    try std.testing.expectError(error.InvalidRecord, edge_header.validateShape());

    var vertex_header = SegmentHeader{ .order = .forward, .edge_count = 0, .vertex_count = 0, .relation_count = 0 };
    vertex_header.flags = SegmentHeader.flag_u32_vertex_records | SegmentHeader.flag_u24_node_u32_vertex_records;
    try std.testing.expectError(error.InvalidRecord, vertex_header.validateShape());
}

test "immutable adjacency segment open rejects corrupt vertex edge offset" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const segment_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "s000001" });
    defer std.testing.allocator.free(segment_path);

    var segment = try ImmutableAdjacencySegment.build(std.testing.allocator, std.testing.io, segment_path, &.{
        .{ .edge_id = .fromInt(1), .src = .fromInt(1), .rel = .defines, .dst = .fromInt(2) },
        .{ .edge_id = .fromInt(2), .src = .fromInt(1), .rel = .mentions, .dst = .fromInt(3) },
    });
    segment.deinit();

    const fwd_path = try std.fs.path.join(std.testing.allocator, &.{ segment_path, "edge_fwd.csr" });
    defer std.testing.allocator.free(fwd_path);
    {
        var view = try CsrFileView.open(std.testing.io, fwd_path);
        const header = try readHeader(&view);
        const edge_offset_field = try vertexRecordOffsetForHeader(header, 0) + vertexEdgeOffsetFieldOffset(header);
        view.deinit();

        var file = try std.Io.Dir.cwd().openFile(std.testing.io, fwd_path, .{ .mode = .read_write });
        defer file.close(std.testing.io);
        var offset_bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &offset_bytes, 1, .little);
        try file.writePositionalAll(std.testing.io, offset_bytes[0..vertexEdgeOffsetFieldLen(header)], edge_offset_field);
    }

    try std.testing.expectError(error.InvalidRecord, ImmutableAdjacencySegment.open(std.testing.allocator, std.testing.io, segment_path));
}

test "immutable adjacency segment open rejects corrupt non-uniform single-relation vertex edge offset" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const segment_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "s000001" });
    defer std.testing.allocator.free(segment_path);

    var segment = try ImmutableAdjacencySegment.build(std.testing.allocator, std.testing.io, segment_path, &.{
        .{ .edge_id = .fromInt(1), .src = .fromInt(1), .rel = .defines, .dst = .fromInt(3) },
        .{ .edge_id = .fromInt(2), .src = .fromInt(1), .rel = .defines, .dst = .fromInt(5) },
        .{ .edge_id = .fromInt(3), .src = .fromInt(2), .rel = .mentions, .dst = .fromInt(4) },
    });
    segment.deinit();

    const fwd_path = try std.fs.path.join(std.testing.allocator, &.{ segment_path, "edge_fwd.csr" });
    defer std.testing.allocator.free(fwd_path);
    {
        var view = try CsrFileView.open(std.testing.io, fwd_path);
        const header = try readHeader(&view);
        try std.testing.expect(header.hasSingleRelationPerVertex());
        try std.testing.expect(!header.hasUniformRelation());
        try std.testing.expect(!header.hasUniformSingleRelationEdgeCount());
        const edge_offset_field = try vertexRecordOffsetForHeader(header, 0) + vertexEdgeOffsetFieldOffset(header);
        view.deinit();

        var file = try std.Io.Dir.cwd().openFile(std.testing.io, fwd_path, .{ .mode = .read_write });
        defer file.close(std.testing.io);
        var offset_bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &offset_bytes, 1, .little);
        try file.writePositionalAll(std.testing.io, offset_bytes[0..vertexEdgeOffsetFieldLen(header)], edge_offset_field);
    }

    try std.testing.expectError(error.InvalidRecord, ImmutableAdjacencySegment.open(std.testing.allocator, std.testing.io, segment_path));
}

test "immutable adjacency segment open rejects edge relation mismatch" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const segment_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "s000001" });
    defer std.testing.allocator.free(segment_path);

    var segment = try ImmutableAdjacencySegment.build(std.testing.allocator, std.testing.io, segment_path, &.{
        .{ .edge_id = .fromInt(1), .src = .fromInt(1), .rel = .defines, .dst = .fromInt(2) },
        .{ .edge_id = .fromInt(2), .src = .fromInt(1), .rel = .mentions, .dst = .fromInt(3) },
    });
    segment.deinit();

    const fwd_path = try std.fs.path.join(std.testing.allocator, &.{ segment_path, "edge_fwd.csr" });
    defer std.testing.allocator.free(fwd_path);
    {
        var view = try CsrFileView.open(std.testing.io, fwd_path);
        const header = try readHeader(&view);
        const first_relation_rel = try relationRecordOffset(header, 0);
        view.deinit();

        var file = try std.Io.Dir.cwd().openFile(std.testing.io, fwd_path, .{ .mode = .read_write });
        defer file.close(std.testing.io);
        var rel_bytes: [2]u8 = undefined;
        std.mem.writeInt(u16, &rel_bytes, @intFromEnum(core.RelKind.mentions), .little);
        try file.writePositionalAll(std.testing.io, &rel_bytes, first_relation_rel);
    }

    try std.testing.expectError(error.InvalidRecord, ImmutableAdjacencySegment.open(std.testing.allocator, std.testing.io, segment_path));
}

test "immutable adjacency segment open rejects unsorted edges" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const segment_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "s000001" });
    defer std.testing.allocator.free(segment_path);

    var segment = try ImmutableAdjacencySegment.build(std.testing.allocator, std.testing.io, segment_path, &.{
        .{ .edge_id = .fromInt(1), .src = .fromInt(1), .rel = .mentions, .dst = .fromInt(2) },
        .{ .edge_id = .fromInt(2), .src = .fromInt(1), .rel = .mentions, .dst = .fromInt(3) },
    });
    segment.deinit();

    const fwd_path = try std.fs.path.join(std.testing.allocator, &.{ segment_path, "edge_fwd.csr" });
    defer std.testing.allocator.free(fwd_path);
    {
        var view = try CsrFileView.open(std.testing.io, fwd_path);
        const header = try readHeader(&view);
        const first_edge_dst = try edgeBaseOffsetForHeader(header);
        view.deinit();

        var file = try std.Io.Dir.cwd().openFile(std.testing.io, fwd_path, .{ .mode = .read_write });
        defer file.close(std.testing.io);
        var dst_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &dst_bytes, 9, .little);
        try file.writePositionalAll(std.testing.io, &dst_bytes, first_edge_dst);
    }

    try std.testing.expectError(error.InvalidRecord, ImmutableAdjacencySegment.open(std.testing.allocator, std.testing.io, segment_path));
}

test "immutable adjacency segment open rejects duplicate edge ids" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const segment_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "s000001" });
    defer std.testing.allocator.free(segment_path);

    var segment = try ImmutableAdjacencySegment.build(std.testing.allocator, std.testing.io, segment_path, &.{
        .{ .edge_id = .fromInt(1), .src = .fromInt(1), .rel = .mentions, .dst = .fromInt(2) },
        .{ .edge_id = .fromInt(3), .src = .fromInt(1), .rel = .mentions, .dst = .fromInt(3) },
        .{ .edge_id = .fromInt(4), .src = .fromInt(1), .rel = .mentions, .dst = .fromInt(4) },
        .{ .edge_id = .fromInt(8), .src = .fromInt(1), .rel = .mentions, .dst = .fromInt(5) },
        .{ .edge_id = .fromInt(9), .src = .fromInt(1), .rel = .mentions, .dst = .fromInt(6) },
    });
    segment.deinit();

    const fwd_path = try std.fs.path.join(std.testing.allocator, &.{ segment_path, "edge_fwd.csr" });
    defer std.testing.allocator.free(fwd_path);
    {
        var view = try CsrFileView.open(std.testing.io, fwd_path);
        const header = try readHeader(&view);
        try std.testing.expect(!header.hasDerivedEdgeIds());
        const second_edge_id = try edgeBaseOffsetForHeader(header) + header.edge_record_len + storedEdgeIdFieldOffset(header);
        view.deinit();

        var file = try std.Io.Dir.cwd().openFile(std.testing.io, fwd_path, .{ .mode = .read_write });
        defer file.close(std.testing.io);
        var edge_id_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &edge_id_bytes, 1, .little);
        try file.writePositionalAll(std.testing.io, &edge_id_bytes, second_edge_id);
    }

    try std.testing.expectError(error.InvalidRecord, ImmutableAdjacencySegment.open(std.testing.allocator, std.testing.io, segment_path));
}

test "immutable adjacency segment open rejects sparse duplicate edge ids" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const segment_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "s000001" });
    defer std.testing.allocator.free(segment_path);

    var segment = try ImmutableAdjacencySegment.build(std.testing.allocator, std.testing.io, segment_path, &.{
        .{ .edge_id = .fromInt(9000), .src = .fromInt(1), .rel = .mentions, .dst = .fromInt(2) },
        .{ .edge_id = .fromInt(6000), .src = .fromInt(1), .rel = .mentions, .dst = .fromInt(2) },
        .{ .edge_id = .fromInt(5000), .src = .fromInt(1), .rel = .mentions, .dst = .fromInt(3) },
        .{ .edge_id = .fromInt(7000), .src = .fromInt(1), .rel = .mentions, .dst = .fromInt(4) },
        .{ .edge_id = .fromInt(5500), .src = .fromInt(1), .rel = .mentions, .dst = .fromInt(5) },
    });
    segment.deinit();

    const fwd_path = try std.fs.path.join(std.testing.allocator, &.{ segment_path, "edge_fwd.csr" });
    defer std.testing.allocator.free(fwd_path);
    {
        var view = try CsrFileView.open(std.testing.io, fwd_path);
        const header = try readHeader(&view);
        try std.testing.expect(!header.hasDerivedEdgeIds());
        const second_edge_id = try edgeBaseOffsetForHeader(header) + header.edge_record_len + storedEdgeIdFieldOffset(header);
        view.deinit();

        var file = try std.Io.Dir.cwd().openFile(std.testing.io, fwd_path, .{ .mode = .read_write });
        defer file.close(std.testing.io);
        var edge_id_bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &edge_id_bytes, 6000, .little);
        try file.writePositionalAll(std.testing.io, &edge_id_bytes, second_edge_id);
    }

    try std.testing.expectError(error.InvalidRecord, ImmutableAdjacencySegment.open(std.testing.allocator, std.testing.io, segment_path));
}

test "immutable adjacency segment open rejects mismatched forward reverse edge sets" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var path_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buf);
    const segment_path = try std.fs.path.join(std.testing.allocator, &.{ path_buf[0..root_len], "s000001" });
    defer std.testing.allocator.free(segment_path);

    var segment = try ImmutableAdjacencySegment.build(std.testing.allocator, std.testing.io, segment_path, &.{
        .{ .edge_id = .fromInt(1), .src = .fromInt(1), .rel = .mentions, .dst = .fromInt(2) },
        .{ .edge_id = .fromInt(2), .src = .fromInt(1), .rel = .mentions, .dst = .fromInt(3) },
    });
    segment.deinit();

    const rev_path = try std.fs.path.join(std.testing.allocator, &.{ segment_path, "edge_rev.csr" });
    defer std.testing.allocator.free(rev_path);
    {
        var view = try CsrFileView.open(std.testing.io, rev_path);
        const header = try readHeader(&view);
        const second_edge_src = try edgeBaseOffsetForHeader(header) + header.edge_record_len;
        view.deinit();

        var file = try std.Io.Dir.cwd().openFile(std.testing.io, rev_path, .{ .mode = .read_write });
        defer file.close(std.testing.io);
        var src_bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &src_bytes, 9, .little);
        try file.writePositionalAll(std.testing.io, src_bytes[0..storedEdgeOtherNodeFieldLen(header)], second_edge_src);
    }

    try std.testing.expectError(error.InvalidRecord, ImmutableAdjacencySegment.open(std.testing.allocator, std.testing.io, segment_path));
}
