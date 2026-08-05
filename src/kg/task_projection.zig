//! Read-only TinyKG task-subgraph projection.
//!
//! TinyKG owns graph collection and the semantic revision. metacodes owns the
//! consumer boundary: strict wire validation, identity-preserving types, and a
//! deterministic human-readable Markdown view. Markdown contains a canonical
//! JSON envelope so `graph -> typed -> Markdown -> typed` is lossless, but it is
//! deliberately not an edit/write-back protocol.

const std = @import("std");

pub const SNAPSHOT_SCHEMA = "tinykg-task-snapshot-v1";
pub const MARKDOWN_SCHEMA = "metacodes-task-projection-v1";

const MAX_SNAPSHOT_BYTES: usize = 8 * 1024 * 1024;
const MAX_TASKS: usize = 4096;
const MAX_EDGES: usize = 8 * 1024;
const MAX_TEXT_BYTES: usize = 512 * 1024;
const NO_EDGE = std.math.maxInt(usize);

pub const Error = error{
    OutOfMemory,
    InvalidJson,
    UnsupportedSchema,
    RootMismatch,
    MissingRoot,
    InvalidRevision,
    TruncatedSnapshot,
    InvalidSummary,
    ResourceLimit,
    InvalidText,
    InvalidLifecycle,
    DuplicateId,
    DuplicateEdge,
    NonCanonicalOrder,
    ReferentialIntegrity,
    HierarchyCycle,
    DisconnectedTask,
    InvalidMarkdown,
    NonCanonicalMarkdown,
    StaleRevision,
};

pub const TaskId = enum(u64) {
    _,

    pub fn fromInt(value: u64) TaskId {
        return @enumFromInt(value);
    }

    pub fn toInt(self: TaskId) u64 {
        return @intFromEnum(self);
    }
};

pub const EvidenceId = enum(u64) {
    _,

    pub fn fromInt(value: u64) EvidenceId {
        return @enumFromInt(value);
    }

    pub fn toInt(self: EvidenceId) u64 {
        return @intFromEnum(self);
    }
};

/// `claimed` carries its holder, so an impossible claimed-without-owner state
/// cannot escape the wire parser.
pub const Lifecycle = union(enum) {
    open,
    claimed: []const u8,
    completed,
    failed,

    pub fn statusName(self: Lifecycle) []const u8 {
        return switch (self) {
            .open => "open",
            .claimed => "claimed",
            .completed => "completed",
            .failed => "failed",
        };
    }

    pub fn claimedBy(self: Lifecycle) ?[]const u8 {
        return switch (self) {
            .claimed => |holder| holder,
            else => null,
        };
    }
};

pub const Task = struct {
    id: TaskId,
    lifecycle: Lifecycle,
    text: []const u8,
};

pub const HierarchyEdge = struct {
    src: TaskId,
    dst: TaskId,
};

/// Values follow TinyKG v1's stable semantic sort order.
pub const DependencyRel = enum(u8) {
    depends_on,
    blocks,
    precedes,
};

pub const DependencyEdge = struct {
    /// Either endpoint may name a task outside the hierarchy snapshot. The
    /// relation-specific local endpoint is checked during parsing.
    src: TaskId,
    rel: DependencyRel,
    dst: TaskId,
};

pub const Evidence = struct {
    id: EvidenceId,
    kind: []const u8,
    text: []const u8,
};

pub const VerifiedByEdge = struct {
    task: TaskId,
    evidence: EvidenceId,
};

pub const Summary = struct {
    used_text_bytes: usize,
    max_tasks: usize,
    max_edges: usize,
    max_chars: usize,
};

pub const Projection = struct {
    arena: std.heap.ArenaAllocator,
    root_id: TaskId,
    revision: [64]u8,
    summary: Summary,
    tasks: []Task,
    hierarchy: []HierarchyEdge,
    dependencies: []DependencyEdge,
    evidence: []Evidence,
    verified_by: []VerifiedByEdge,

    pub fn deinit(self: *Projection) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn renderMarkdown(self: *const Projection, allocator: std.mem.Allocator) Error![]u8 {
        const canonical = try self.canonicalJson(allocator);
        defer allocator.free(canonical);

        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        const writer = &out.writer;

        try writeAll(writer, "# TinyKG task projection\n\n" ++
            "> This is a read-only projection of the TinyKG task graph. " ++
            "Editing this Markdown does not update the graph.\n\n");
        try print(writer, "- Root: `task:{d}`\n", .{self.root_id.toInt()});
        try print(writer, "- Revision: `{s}`\n", .{self.revision[0..]});
        try print(writer, "- Tasks: {d}; hierarchy edges: {d}; dependencies: {d}; evidence: {d}\n\n", .{
            self.tasks.len,
            self.hierarchy.len,
            self.dependencies.len,
            self.evidence.len,
        });

        try writeAll(writer, "## Tasks\n\n");

        for (self.tasks) |task| {
            const marker = switch (task.lifecycle) {
                .open => "[ ]",
                .claimed => "[-]",
                .completed => "[x]",
                .failed => "[!]",
            };
            try print(writer, "### {s} `task:{d}` · `{s}`", .{
                marker,
                task.id.toInt(),
                task.lifecycle.statusName(),
            });
            if (task.id == self.root_id) try writeAll(writer, " · root");
            try writeAll(writer, "\n\n");
            if (task.lifecycle.claimedBy()) |holder| {
                try writeAll(writer, "Claimed by: ");
                try jsonString(writer, holder);
                try writeAll(writer, "\n\n");
            }
            try writeIndentedText(writer, task.text);
            try writeAll(writer, "\n");
        }

        try writeAll(writer, "## Hierarchy\n\n");
        if (self.hierarchy.len == 0) {
            try writeAll(writer, "_None._\n\n");
        } else {
            for (self.hierarchy) |edge| {
                try print(writer, "- `task:{d}` --`contain`--> `task:{d}`\n", .{
                    edge.src.toInt(), edge.dst.toInt(),
                });
            }
            try writeAll(writer, "\n");
        }

        try writeAll(writer, "## Dependencies\n\n");
        if (self.dependencies.len == 0) {
            try writeAll(writer, "_None._\n\n");
        } else {
            for (self.dependencies) |edge| {
                try print(writer, "- `task:{d}` --`{s}`--> `task:{d}`\n", .{
                    edge.src.toInt(), @tagName(edge.rel), edge.dst.toInt(),
                });
            }
            try writeAll(writer, "\n");
        }

        try writeAll(writer, "## Evidence\n\n");
        if (self.evidence.len == 0) {
            try writeAll(writer, "_None._\n\n");
        } else {
            for (self.evidence) |item| {
                try print(writer, "### `evidence:{d}` · ", .{item.id.toInt()});
                try jsonString(writer, item.kind);
                try writeAll(writer, "\n\n");
                try writeIndentedText(writer, item.text);
                try writeAll(writer, "\n");
            }
        }

        try writeAll(writer, "## Verification links\n\n");
        if (self.verified_by.len == 0) {
            try writeAll(writer, "_None._\n");
        } else {
            for (self.verified_by) |edge| {
                try print(writer, "- `task:{d}` --`verified_by`--> `evidence:{d}`\n", .{
                    edge.task.toInt(), edge.evidence.toInt(),
                });
            }
        }
        try writeAll(writer, "\n## Machine envelope\n\n" ++
            "> Canonical data for exact read-only round trips. Human readers can ignore this block.\n\n");
        // One compact line: JSON-escaped task text cannot synthesize a closing
        // fence on its own line, so extraction remains unambiguous.
        try print(writer, "```json {s}\n", .{MARKDOWN_SCHEMA});
        try writeAll(writer, canonical);
        try writeAll(writer, "\n```\n");
        return out.toOwnedSlice() catch error.OutOfMemory;
    }

    pub fn canonicalJson(self: *const Projection, allocator: std.mem.Allocator) Error![]u8 {
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        const writer = &out.writer;
        try writeAll(writer, "{\"schema_version\":");
        try jsonString(writer, SNAPSHOT_SCHEMA);
        try print(writer, ",\"root_id\":{d},\"revision\":", .{self.root_id.toInt()});
        try jsonString(writer, self.revision[0..]);
        try print(writer, ",\"summary\":{{\"task_count\":{d},\"hierarchy_edge_count\":{d}," ++
            "\"dependency_edge_count\":{d},\"evidence_count\":{d}," ++
            "\"verified_by_edge_count\":{d},\"used_text_bytes\":{d}," ++
            "\"truncated\":false,\"truncate_reason\":null," ++
            "\"max_tasks\":{d},\"max_edges\":{d},\"max_chars\":{d}}},\"tasks\":[", .{
            self.tasks.len,
            self.hierarchy.len,
            self.dependencies.len,
            self.evidence.len,
            self.verified_by.len,
            self.summary.used_text_bytes,
            self.summary.max_tasks,
            self.summary.max_edges,
            self.summary.max_chars,
        });
        for (self.tasks, 0..) |task, index| {
            if (index != 0) try writeAll(writer, ",");
            try print(writer, "{{\"id\":{d},\"status\":", .{task.id.toInt()});
            try jsonString(writer, task.lifecycle.statusName());
            try writeAll(writer, ",\"claimed_by\":");
            if (task.lifecycle.claimedBy()) |holder|
                try jsonString(writer, holder)
            else
                try writeAll(writer, "null");
            try writeAll(writer, ",\"text\":");
            try jsonString(writer, task.text);
            try writeAll(writer, "}");
        }
        try writeAll(writer, "],\"hierarchy\":[");
        for (self.hierarchy, 0..) |edge, index| {
            if (index != 0) try writeAll(writer, ",");
            try print(writer, "{{\"src\":{d},\"rel\":\"contain\",\"dst\":{d}}}", .{
                edge.src.toInt(), edge.dst.toInt(),
            });
        }
        try writeAll(writer, "],\"dependencies\":[");
        for (self.dependencies, 0..) |edge, index| {
            if (index != 0) try writeAll(writer, ",");
            try print(writer, "{{\"src\":{d},\"rel\":", .{edge.src.toInt()});
            try jsonString(writer, @tagName(edge.rel));
            try print(writer, ",\"dst\":{d}}}", .{edge.dst.toInt()});
        }
        try writeAll(writer, "],\"evidence\":[");
        for (self.evidence, 0..) |item, index| {
            if (index != 0) try writeAll(writer, ",");
            try print(writer, "{{\"id\":{d},\"kind\":", .{item.id.toInt()});
            try jsonString(writer, item.kind);
            try writeAll(writer, ",\"text\":");
            try jsonString(writer, item.text);
            try writeAll(writer, "}");
        }
        try writeAll(writer, "],\"verified_by\":[");
        for (self.verified_by, 0..) |edge, index| {
            if (index != 0) try writeAll(writer, ",");
            try print(writer, "{{\"src\":{d},\"rel\":\"verified_by\",\"dst\":{d}}}", .{
                edge.task.toInt(), edge.evidence.toInt(),
            });
        }
        try writeAll(writer, "]}");
        return out.toOwnedSlice() catch error.OutOfMemory;
    }

    pub fn eql(self: *const Projection, other: *const Projection) bool {
        if (self.root_id != other.root_id or
            !std.mem.eql(u8, self.revision[0..], other.revision[0..]) or
            !std.meta.eql(self.summary, other.summary) or
            self.tasks.len != other.tasks.len or
            self.hierarchy.len != other.hierarchy.len or
            self.dependencies.len != other.dependencies.len or
            self.evidence.len != other.evidence.len or
            self.verified_by.len != other.verified_by.len)
            return false;

        for (self.tasks, other.tasks) |lhs, rhs| {
            if (lhs.id != rhs.id or !lifecycleEql(lhs.lifecycle, rhs.lifecycle) or
                !std.mem.eql(u8, lhs.text, rhs.text)) return false;
        }
        for (self.hierarchy, other.hierarchy) |lhs, rhs| {
            if (!std.meta.eql(lhs, rhs)) return false;
        }
        for (self.dependencies, other.dependencies) |lhs, rhs| {
            if (!std.meta.eql(lhs, rhs)) return false;
        }
        for (self.evidence, other.evidence) |lhs, rhs| {
            if (lhs.id != rhs.id or !std.mem.eql(u8, lhs.kind, rhs.kind) or
                !std.mem.eql(u8, lhs.text, rhs.text)) return false;
        }
        for (self.verified_by, other.verified_by) |lhs, rhs| {
            if (!std.meta.eql(lhs, rhs)) return false;
        }
        return true;
    }
};

const RawSummary = struct {
    task_count: usize,
    hierarchy_edge_count: usize,
    dependency_edge_count: usize,
    evidence_count: usize,
    verified_by_edge_count: usize,
    used_text_bytes: usize,
    truncated: bool,
    truncate_reason: ?[]const u8,
    max_tasks: usize,
    max_edges: usize,
    max_chars: usize,
};

const RawTask = struct {
    id: u64,
    status: []const u8,
    claimed_by: ?[]const u8,
    text: []const u8,
};

const RawEdge = struct {
    src: u64,
    rel: []const u8,
    dst: u64,
};

const RawEvidence = struct {
    id: u64,
    kind: []const u8,
    text: []const u8,
};

const RawSnapshot = struct {
    schema_version: []const u8,
    root_id: u64,
    revision: []const u8,
    summary: RawSummary,
    tasks: []RawTask,
    hierarchy: []RawEdge,
    dependencies: []RawEdge,
    evidence: []RawEvidence,
    verified_by: []RawEdge,
};

pub fn parseSnapshot(
    allocator: std.mem.Allocator,
    expected_root: TaskId,
    encoded: []const u8,
) Error!Projection {
    if (encoded.len == 0 or encoded.len > MAX_SNAPSHOT_BYTES) return error.ResourceLimit;
    if (!std.unicode.utf8ValidateSlice(encoded)) return error.InvalidJson;

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const arena_allocator = arena.allocator();
    const raw = std.json.parseFromSliceLeaky(RawSnapshot, arena_allocator, encoded, .{
        .ignore_unknown_fields = false,
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    }) catch |parse_error| switch (parse_error) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidJson,
    };

    if (!std.mem.eql(u8, raw.schema_version, SNAPSHOT_SCHEMA)) return error.UnsupportedSchema;
    if (raw.root_id == 0 or raw.root_id != expected_root.toInt()) return error.RootMismatch;
    const revision = try parseRevision(raw.revision);
    if (raw.summary.truncated) return error.TruncatedSnapshot;
    if (raw.summary.truncate_reason != null) return error.InvalidSummary;
    try validateSummary(raw);

    const tasks = arena_allocator.alloc(Task, raw.tasks.len) catch return error.OutOfMemory;
    var task_index = std.AutoHashMap(u64, usize).init(allocator);
    defer task_index.deinit();
    var used_text_bytes: usize = 0;
    for (raw.tasks, 0..) |item, index| {
        if (item.id == 0 or !std.unicode.utf8ValidateSlice(item.text)) return error.InvalidText;
        const entry = task_index.getOrPut(item.id) catch return error.OutOfMemory;
        if (entry.found_existing) return error.DuplicateId;
        entry.value_ptr.* = index;
        if (index > 0 and raw.tasks[index - 1].id > item.id) return error.NonCanonicalOrder;
        used_text_bytes = std.math.add(usize, used_text_bytes, item.text.len) catch return error.ResourceLimit;
        tasks[index] = .{
            .id = TaskId.fromInt(item.id),
            .lifecycle = try parseLifecycle(item.status, item.claimed_by),
            .text = item.text,
        };
    }
    const root_index = task_index.get(raw.root_id) orelse return error.MissingRoot;

    const hierarchy = arena_allocator.alloc(HierarchyEdge, raw.hierarchy.len) catch return error.OutOfMemory;
    for (raw.hierarchy, 0..) |edge, index| {
        if (!std.mem.eql(u8, edge.rel, "contain")) return error.ReferentialIntegrity;
        if (edge.src == 0 or edge.dst == 0 or edge.src == edge.dst or
            !task_index.contains(edge.src) or !task_index.contains(edge.dst))
            return error.ReferentialIntegrity;
        if (index > 0) {
            const previous = raw.hierarchy[index - 1];
            const order = edgeOrder(previous.src, previous.dst, edge.src, edge.dst);
            if (order == .eq) return error.DuplicateEdge;
            if (order == .gt) return error.NonCanonicalOrder;
        }
        hierarchy[index] = .{ .src = TaskId.fromInt(edge.src), .dst = TaskId.fromInt(edge.dst) };
    }
    try validateHierarchy(allocator, tasks.len, root_index, hierarchy, &task_index);

    const dependencies = arena_allocator.alloc(DependencyEdge, raw.dependencies.len) catch return error.OutOfMemory;
    for (raw.dependencies, 0..) |edge, index| {
        const rel = parseDependencyRel(edge.rel) orelse return error.ReferentialIntegrity;
        if (edge.src == 0 or edge.dst == 0 or edge.src == edge.dst) return error.ReferentialIntegrity;
        const src_local = task_index.contains(edge.src);
        const dst_local = task_index.contains(edge.dst);
        switch (rel) {
            .depends_on => if (!src_local) return error.ReferentialIntegrity,
            .blocks, .precedes => if (!dst_local) return error.ReferentialIntegrity,
        }
        if (index > 0) {
            const previous = raw.dependencies[index - 1];
            const previous_rel = parseDependencyRel(previous.rel) orelse return error.ReferentialIntegrity;
            const order = dependencyOrder(previous.src, previous_rel, previous.dst, edge.src, rel, edge.dst);
            if (order == .eq) return error.DuplicateEdge;
            if (order == .gt) return error.NonCanonicalOrder;
        }
        dependencies[index] = .{
            .src = TaskId.fromInt(edge.src),
            .rel = rel,
            .dst = TaskId.fromInt(edge.dst),
        };
    }

    const evidence = arena_allocator.alloc(Evidence, raw.evidence.len) catch return error.OutOfMemory;
    var evidence_index = std.AutoHashMap(u64, usize).init(allocator);
    defer evidence_index.deinit();
    for (raw.evidence, 0..) |item, index| {
        if (item.id == 0 or !validKind(item.kind) or !std.unicode.utf8ValidateSlice(item.text))
            return error.InvalidText;
        const entry = evidence_index.getOrPut(item.id) catch return error.OutOfMemory;
        if (entry.found_existing) return error.DuplicateId;
        entry.value_ptr.* = index;
        if (index > 0 and raw.evidence[index - 1].id > item.id) return error.NonCanonicalOrder;
        used_text_bytes = std.math.add(usize, used_text_bytes, item.text.len) catch return error.ResourceLimit;
        evidence[index] = .{
            .id = EvidenceId.fromInt(item.id),
            .kind = item.kind,
            .text = item.text,
        };
    }

    const verified_by = arena_allocator.alloc(VerifiedByEdge, raw.verified_by.len) catch return error.OutOfMemory;
    const evidence_referenced = allocator.alloc(bool, evidence.len) catch return error.OutOfMemory;
    defer allocator.free(evidence_referenced);
    @memset(evidence_referenced, false);
    for (raw.verified_by, 0..) |edge, index| {
        if (!std.mem.eql(u8, edge.rel, "verified_by") or !task_index.contains(edge.src))
            return error.ReferentialIntegrity;
        const evidence_slot = evidence_index.get(edge.dst) orelse return error.ReferentialIntegrity;
        if (index > 0) {
            const previous = raw.verified_by[index - 1];
            const order = edgeOrder(previous.src, previous.dst, edge.src, edge.dst);
            if (order == .eq) return error.DuplicateEdge;
            if (order == .gt) return error.NonCanonicalOrder;
        }
        evidence_referenced[evidence_slot] = true;
        verified_by[index] = .{
            .task = TaskId.fromInt(edge.src),
            .evidence = EvidenceId.fromInt(edge.dst),
        };
    }
    for (evidence_referenced) |referenced| {
        if (!referenced) return error.ReferentialIntegrity;
    }
    if (used_text_bytes != raw.summary.used_text_bytes) return error.InvalidSummary;

    return .{
        .arena = arena,
        .root_id = expected_root,
        .revision = revision,
        .summary = .{
            .used_text_bytes = used_text_bytes,
            .max_tasks = raw.summary.max_tasks,
            .max_edges = raw.summary.max_edges,
            .max_chars = raw.summary.max_chars,
        },
        .tasks = tasks,
        .hierarchy = hierarchy,
        .dependencies = dependencies,
        .evidence = evidence,
        .verified_by = verified_by,
    };
}

pub fn parseMarkdown(
    allocator: std.mem.Allocator,
    expected_root: TaskId,
    expected_revision: ?[]const u8,
    markdown: []const u8,
) Error!Projection {
    const start_marker = "```json " ++ MARKDOWN_SCHEMA ++ "\n";
    const start = findAtLineStart(markdown, start_marker) orelse return error.InvalidMarkdown;
    const payload_start = start + start_marker.len;
    const end_marker = "\n```";
    const relative_end = std.mem.indexOf(u8, markdown[payload_start..], end_marker) orelse
        return error.InvalidMarkdown;
    const payload_end = payload_start + relative_end;
    const after_fence = payload_end + end_marker.len;
    if (after_fence < markdown.len and markdown[after_fence] != '\n') return error.InvalidMarkdown;
    const payload = markdown[payload_start..payload_end];
    if (payload.len == 0 or std.mem.indexOfScalar(u8, payload, '\n') != null)
        return error.NonCanonicalMarkdown;

    var result = try parseSnapshot(allocator, expected_root, payload);
    errdefer result.deinit();
    if (expected_revision) |expected| {
        if (expected.len != result.revision.len or !std.mem.eql(u8, expected, result.revision[0..]))
            return error.StaleRevision;
    }
    const canonical = try result.canonicalJson(allocator);
    defer allocator.free(canonical);
    if (!std.mem.eql(u8, canonical, payload)) return error.NonCanonicalMarkdown;
    return result;
}

fn findAtLineStart(haystack: []const u8, needle: []const u8) ?usize {
    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, cursor, needle)) |position| {
        if (position == 0 or haystack[position - 1] == '\n') return position;
        cursor = position + 1;
    }
    return null;
}

fn validateSummary(raw: RawSnapshot) Error!void {
    const summary = raw.summary;
    if (summary.task_count != raw.tasks.len or
        summary.hierarchy_edge_count != raw.hierarchy.len or
        summary.dependency_edge_count != raw.dependencies.len or
        summary.evidence_count != raw.evidence.len or
        summary.verified_by_edge_count != raw.verified_by.len)
        return error.InvalidSummary;
    if (summary.max_tasks == 0 or summary.max_tasks > MAX_TASKS or
        summary.max_edges == 0 or summary.max_edges > MAX_EDGES or
        summary.max_chars == 0 or summary.max_chars > MAX_TEXT_BYTES)
        return error.ResourceLimit;
    if (raw.tasks.len > summary.max_tasks or summary.used_text_bytes > summary.max_chars)
        return error.ResourceLimit;
    const first_edges = std.math.add(usize, raw.hierarchy.len, raw.dependencies.len) catch return error.ResourceLimit;
    const edge_count = std.math.add(usize, first_edges, raw.verified_by.len) catch return error.ResourceLimit;
    if (edge_count > summary.max_edges) return error.ResourceLimit;
}

fn parseRevision(raw: []const u8) Error![64]u8 {
    if (raw.len != 64) return error.InvalidRevision;
    var out: [64]u8 = undefined;
    for (raw, 0..) |byte, index| {
        if (!((byte >= '0' and byte <= '9') or (byte >= 'a' and byte <= 'f')))
            return error.InvalidRevision;
        out[index] = byte;
    }
    return out;
}

fn parseLifecycle(status: []const u8, claimed_by: ?[]const u8) Error!Lifecycle {
    if (std.mem.eql(u8, status, "claimed")) {
        const holder = claimed_by orelse return error.InvalidLifecycle;
        if (holder.len == 0 or holder.len > 1024 or !std.unicode.utf8ValidateSlice(holder))
            return error.InvalidLifecycle;
        return .{ .claimed = holder };
    }
    if (claimed_by != null) return error.InvalidLifecycle;
    if (std.mem.eql(u8, status, "open")) return .open;
    if (std.mem.eql(u8, status, "completed")) return .completed;
    if (std.mem.eql(u8, status, "failed")) return .failed;
    return error.InvalidLifecycle;
}

fn parseDependencyRel(raw: []const u8) ?DependencyRel {
    if (std.mem.eql(u8, raw, "depends_on")) return .depends_on;
    if (std.mem.eql(u8, raw, "blocks")) return .blocks;
    if (std.mem.eql(u8, raw, "precedes")) return .precedes;
    return null;
}

fn validKind(kind: []const u8) bool {
    if (kind.len == 0 or kind.len > 64) return false;
    for (kind) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-' and byte != '#')
            return false;
    }
    return true;
}

fn validateHierarchy(
    allocator: std.mem.Allocator,
    task_count: usize,
    root_index: usize,
    edges: []const HierarchyEdge,
    task_index: *const std.AutoHashMap(u64, usize),
) Error!void {
    const heads = allocator.alloc(usize, task_count) catch return error.OutOfMemory;
    defer allocator.free(heads);
    const next = allocator.alloc(usize, edges.len) catch return error.OutOfMemory;
    defer allocator.free(next);
    const destinations = allocator.alloc(usize, edges.len) catch return error.OutOfMemory;
    defer allocator.free(destinations);
    const indegree = allocator.alloc(usize, task_count) catch return error.OutOfMemory;
    defer allocator.free(indegree);
    const queue = allocator.alloc(usize, task_count) catch return error.OutOfMemory;
    defer allocator.free(queue);
    const reachable = allocator.alloc(bool, task_count) catch return error.OutOfMemory;
    defer allocator.free(reachable);
    @memset(heads, NO_EDGE);
    @memset(indegree, 0);
    @memset(reachable, false);

    for (edges, 0..) |edge, index| {
        const src = task_index.get(edge.src.toInt()) orelse return error.ReferentialIntegrity;
        const dst = task_index.get(edge.dst.toInt()) orelse return error.ReferentialIntegrity;
        next[index] = heads[src];
        heads[src] = index;
        destinations[index] = dst;
        indegree[dst] = std.math.add(usize, indegree[dst], 1) catch return error.ResourceLimit;
    }

    var read: usize = 0;
    var write: usize = 0;
    for (indegree, 0..) |count, index| {
        if (count == 0) {
            queue[write] = index;
            write += 1;
        }
    }
    while (read < write) : (read += 1) {
        var edge_index = heads[queue[read]];
        while (edge_index != NO_EDGE) : (edge_index = next[edge_index]) {
            const dst = destinations[edge_index];
            indegree[dst] -= 1;
            if (indegree[dst] == 0) {
                queue[write] = dst;
                write += 1;
            }
        }
    }
    if (write != task_count) return error.HierarchyCycle;

    read = 0;
    write = 1;
    queue[0] = root_index;
    reachable[root_index] = true;
    while (read < write) : (read += 1) {
        var edge_index = heads[queue[read]];
        while (edge_index != NO_EDGE) : (edge_index = next[edge_index]) {
            const dst = destinations[edge_index];
            if (!reachable[dst]) {
                reachable[dst] = true;
                queue[write] = dst;
                write += 1;
            }
        }
    }
    for (reachable) |is_reachable| {
        if (!is_reachable) return error.DisconnectedTask;
    }
}

fn lifecycleEql(lhs: Lifecycle, rhs: Lifecycle) bool {
    return switch (lhs) {
        .open => rhs == .open,
        .completed => rhs == .completed,
        .failed => rhs == .failed,
        .claimed => |holder| switch (rhs) {
            .claimed => |other_holder| std.mem.eql(u8, holder, other_holder),
            else => false,
        },
    };
}

fn edgeOrder(lhs_src: u64, lhs_dst: u64, rhs_src: u64, rhs_dst: u64) std.math.Order {
    const src_order = std.math.order(lhs_src, rhs_src);
    if (src_order != .eq) return src_order;
    return std.math.order(lhs_dst, rhs_dst);
}

fn dependencyOrder(
    lhs_src: u64,
    lhs_rel: DependencyRel,
    lhs_dst: u64,
    rhs_src: u64,
    rhs_rel: DependencyRel,
    rhs_dst: u64,
) std.math.Order {
    const src_order = std.math.order(lhs_src, rhs_src);
    if (src_order != .eq) return src_order;
    const rel_order = std.math.order(@intFromEnum(lhs_rel), @intFromEnum(rhs_rel));
    if (rel_order != .eq) return rel_order;
    return std.math.order(lhs_dst, rhs_dst);
}

fn writeAll(writer: *std.Io.Writer, bytes: []const u8) Error!void {
    writer.writeAll(bytes) catch return error.OutOfMemory;
}

fn print(writer: *std.Io.Writer, comptime format: []const u8, args: anytype) Error!void {
    writer.print(format, args) catch return error.OutOfMemory;
}

fn jsonString(writer: *std.Io.Writer, bytes: []const u8) Error!void {
    std.json.Stringify.encodeJsonString(bytes, .{}, writer) catch return error.OutOfMemory;
}

fn writeIndentedText(writer: *std.Io.Writer, text: []const u8) Error!void {
    if (text.len == 0) {
        try writeAll(writer, "    (empty)\n");
        return;
    }
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        try writeAll(writer, "    ");
        for (line) |byte| {
            switch (byte) {
                '\t' => try writeAll(writer, "    "),
                0...0x08, 0x0b...0x1f, 0x7f => {
                    const hex = "0123456789abcdef";
                    const escaped = [_]u8{ '\\', 'u', '0', '0', hex[byte >> 4], hex[byte & 0x0f] };
                    try writeAll(writer, &escaped);
                },
                else => try writeAll(writer, &.{byte}),
            }
        }
        try writeAll(writer, "\n");
    }
}

const allocation_fixture =
    \\{"schema_version":"tinykg-task-snapshot-v1","root_id":1,"revision":"0000000000000000000000000000000000000000000000000000000000000000","summary":{"task_count":1,"hierarchy_edge_count":0,"dependency_edge_count":0,"evidence_count":0,"verified_by_edge_count":0,"used_text_bytes":4,"truncated":false,"truncate_reason":null,"max_tasks":256,"max_edges":1024,"max_chars":200000},"tasks":[{"id":1,"status":"open","claimed_by":null,"text":"root"}],"hierarchy":[],"dependencies":[],"evidence":[],"verified_by":[]}
;

fn allocationFailurePath(allocator: std.mem.Allocator) !void {
    var first = try parseSnapshot(allocator, TaskId.fromInt(1), allocation_fixture);
    defer first.deinit();
    const markdown = try first.renderMarkdown(allocator);
    defer allocator.free(markdown);
    var second = try parseMarkdown(allocator, TaskId.fromInt(1), first.revision[0..], markdown);
    defer second.deinit();
    if (!first.eql(&second)) return error.RoundTripMismatch;
}

test "task projection rolls back every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        allocationFailurePath,
        .{},
    );
}
