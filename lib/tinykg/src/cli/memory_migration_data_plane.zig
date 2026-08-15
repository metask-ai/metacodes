const std = @import("std");
const core = @import("../core.zig");
const storage = @import("../storage.zig");

/// Canonical data plane for `memory-migration-v1`
/// (docs/frommetacodes/memory-migration-v1.md): one fixed atomic effect —
/// supersede an existing memory by adding the `deprecated_by(source,
/// replacement)` edge and setting the source's retrieval exclusion — plus
/// the read surfaces that bind it: capabilities, consistent snapshot,
/// receipt inspection, post-state, and idempotent rollback.
///
/// Consistency boundary, stated honestly: the commit writes both facts
/// inside ONE event-log batch frame (durable truth is atomic; crash
/// recovery rolls the pair forward or discards it together), then
/// refreshes the derived indexes. Readers that consult derived indexes
/// directly can observe a microsecond-scale window where one index is
/// ahead of the other; the audited consumer path (receipt → post-state)
/// never reads inside that window. Snapshot-keyed readers (12045) close
/// it entirely.
pub const capabilities_schema_version = "tinykg-capabilities-v1";
pub const snapshot_schema_version = "tinykg-memory-migration-snapshot-v1";
pub const commit_schema_version = "tinykg-memory-migration-commit-v1";
pub const receipt_schema_version = "tinykg-memory-migration-receipt-v1";
pub const post_state_schema_version = "tinykg-memory-migration-post-state-v1";
pub const rollback_schema_version = "tinykg-memory-migration-rollback-v1";
pub const rollback_receipt_schema_version = "tinykg-memory-migration-rollback-receipt-v1";

pub const snapshot_capability = "tinykg-memory-migration-snapshot-v1";
pub const commit_capability = "tinykg-memory-migration-commit-v1";
pub const rollback_capability = "tinykg-memory-migration-rollback-v1";

pub const operation_name = "memory_supersede_existing";
pub const effect_name = "add_deprecated_by_and_exclude_source";
pub const rollback_name = "remove_deprecated_by_and_restore_source";

const CapabilitiesBody = struct {
    schema_version: []const u8,
    capabilities: []const []const u8,
    build_id: []const u8,
};

pub fn exportCapabilitiesAlloc(allocator: std.mem.Allocator, build_id: []const u8) ![]u8 {
    const body = CapabilitiesBody{
        .schema_version = capabilities_schema_version,
        .capabilities = &.{ snapshot_capability, commit_capability, rollback_capability },
        .build_id = build_id,
    };
    var out = std.Io.Writer.Allocating.init(allocator);
    errdefer out.deinit();
    try std.json.Stringify.value(body, .{}, &out.writer);
    return out.toOwnedSlice();
}

pub const NodeFacts = struct {
    id: u64,
    kind: []const u8,
    schema_type: ?[]const u8,
    current_generation: bool,
    retrieval_excluded: bool,
    contradicted: bool,
};

fn SnapshotJson(comptime with_revision: bool) type {
    if (with_revision) {
        return struct {
            schema_version: []const u8,
            revision: []const u8,
            bounded: bool,
            truncated: bool,
            source: NodeFacts,
            replacement: NodeFacts,
            evidence: NodeFacts,
            deprecated_edge_exists: bool,
        };
    }
    return struct {
        schema_version: []const u8,
        bounded: bool,
        truncated: bool,
        source: NodeFacts,
        replacement: NodeFacts,
        evidence: NodeFacts,
        deprecated_edge_exists: bool,
    };
}

pub const Snapshot = struct {
    source: NodeFacts,
    replacement: NodeFacts,
    evidence: NodeFacts,
    deprecated_edge_exists: bool,
    revision: [64]u8,
    /// Canonical response bytes exactly as the CLI prints them (no newline).
    canonical_bytes: []u8,

    pub fn deinit(self: *Snapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.canonical_bytes);
        self.* = undefined;
    }
};

pub const CurrentGenerationFn = *const fn (storage.Store, core.NodeId) anyerror!bool;

fn readNodeFacts(
    arena: std.mem.Allocator,
    store: storage.Store,
    id: u64,
    is_current_generation: CurrentGenerationFn,
) !NodeFacts {
    const node_id = core.NodeId.fromInt(id);
    var node = (try store.readNodeById(arena, node_id)) orelse return error.InvalidMigrationSource;
    const kind = node.kind;
    node.deinit(arena);
    const schema_type = try store.getNodeStringProperty(arena, node_id, "schema_type");
    const retrieval_excluded = ((try store.getUintProperty(arena, .{ .node = node_id }, "retrieval_excluded")) orelse 0) != 0;
    const contradicted = ((try store.getUintProperty(arena, .{ .node = node_id }, "ontology_contradicted")) orelse 0) != 0;
    const current_generation = try is_current_generation(store, node_id);
    return .{
        .id = id,
        .kind = @tagName(kind),
        .schema_type = schema_type,
        .current_generation = current_generation,
        .retrieval_excluded = retrieval_excluded,
        .contradicted = contradicted,
    };
}

fn deprecatedEdgeExists(arena: std.mem.Allocator, store: storage.Store, source_id: u64, replacement_id: u64) !bool {
    var records = try store.readVisibleEdgeIndexRecordsByNodeForOrderedTraversal(arena, core.NodeId.fromInt(source_id));
    defer records.deinit(arena);
    for (records.items) |record| {
        if (record.rel == @intFromEnum(core.RelKind.deprecated_by) and record.dst == replacement_id) return true;
    }
    return false;
}

/// One consistent read of the three fixed nodes and the fixed edge fact.
/// Returned canonical bytes are owned by the caller.
pub fn exportSnapshotAlloc(
    allocator: std.mem.Allocator,
    store: storage.Store,
    source_id: u64,
    replacement_id: u64,
    evidence_id: u64,
    is_current_generation: CurrentGenerationFn,
) !Snapshot {
    if (source_id == 0 or replacement_id == 0 or evidence_id == 0) return error.InvalidMigrationSource;
    if (source_id == replacement_id or source_id == evidence_id or replacement_id == evidence_id) return error.InvalidMigrationSource;

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const source = try readNodeFacts(arena, store, source_id, is_current_generation);
    const replacement = try readNodeFacts(arena, store, replacement_id, is_current_generation);
    const evidence = try readNodeFacts(arena, store, evidence_id, is_current_generation);
    const edge_exists = try deprecatedEdgeExists(arena, store, source_id, replacement_id);

    const semantic = SnapshotJson(false){
        .schema_version = snapshot_schema_version,
        .bounded = true,
        .truncated = false,
        .source = source,
        .replacement = replacement,
        .evidence = evidence,
        .deprecated_edge_exists = edge_exists,
    };
    var semantic_bytes = std.Io.Writer.Allocating.init(arena);
    try std.json.Stringify.value(semantic, .{}, &semantic_bytes.writer);
    var revision: [64]u8 = undefined;
    sha256Hex(semantic_bytes.writer.buffered(), &revision);

    const response = SnapshotJson(true){
        .schema_version = snapshot_schema_version,
        .revision = &revision,
        .bounded = true,
        .truncated = false,
        .source = source,
        .replacement = replacement,
        .evidence = evidence,
        .deprecated_edge_exists = edge_exists,
    };
    var out = std.Io.Writer.Allocating.init(allocator);
    errdefer out.deinit();
    try std.json.Stringify.value(response, .{}, &out.writer);
    return .{
        .source = .{
            .id = source.id,
            .kind = source.kind,
            .schema_type = null,
            .current_generation = source.current_generation,
            .retrieval_excluded = source.retrieval_excluded,
            .contradicted = source.contradicted,
        },
        .replacement = .{
            .id = replacement.id,
            .kind = replacement.kind,
            .schema_type = null,
            .current_generation = replacement.current_generation,
            .retrieval_excluded = replacement.retrieval_excluded,
            .contradicted = replacement.contradicted,
        },
        .evidence = .{
            .id = evidence.id,
            .kind = evidence.kind,
            .schema_type = null,
            .current_generation = evidence.current_generation,
            .retrieval_excluded = evidence.retrieval_excluded,
            .contradicted = evidence.contradicted,
        },
        .deprecated_edge_exists = edge_exists,
        .revision = revision,
        .canonical_bytes = try out.toOwnedSlice(),
    };
}

pub fn sha256Hex(bytes: []const u8, out: *[64]u8) void {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    _ = std.fmt.bufPrint(out, "{x}", .{&digest}) catch unreachable;
}

pub fn isLowerHex64(value: []const u8) bool {
    if (value.len != 64) return false;
    for (value) |byte| switch (byte) {
        '0'...'9', 'a'...'f' => {},
        else => return false,
    };
    return true;
}

// ---------------------------------------------------------------------------
// Commit / receipt / rollback
// ---------------------------------------------------------------------------

pub const CommitRequest = struct {
    schema_version: []const u8,
    operation: []const u8,
    request_id: []const u8,
    expected_revision: []const u8,
    snapshot_sha256: []const u8,
    proposal_sha256: []const u8,
    checker_verdict_sha256: []const u8,
    source_id: u64,
    replacement_id: u64,
    evidence_id: u64,
    effect: []const u8,
    rollback: []const u8,
    expected_build_id: []const u8,
};

pub const Receipt = struct {
    schema_version: []const u8,
    operation: []const u8,
    request_id: []const u8,
    proposal_sha256: []const u8,
    checker_verdict_sha256: []const u8,
    snapshot_sha256: []const u8,
    previous_revision: []const u8,
    revision: []const u8,
    source_id: u64,
    replacement_id: u64,
    evidence_id: u64,
    effect: []const u8,
    rollback: []const u8,
    committed: bool,
    rollback_token: []const u8,
    build_id: []const u8,
};

pub const PostState = struct {
    schema_version: []const u8,
    revision: []const u8,
    source_id: u64,
    replacement_id: u64,
    evidence_id: u64,
    deprecated_edge_exists: bool,
    source_retrieval_excluded: bool,
    replacement_current_generation: bool,
    evidence_present: bool,
    rollback_token: []const u8,
    build_id: []const u8,
};

pub const RollbackRequest = struct {
    schema_version: []const u8,
    rollback_token: []const u8,
    expected_revision: []const u8,
    expected_build_id: []const u8,
};

pub const RollbackReceipt = struct {
    schema_version: []const u8,
    rollback_token: []const u8,
    request_id: []const u8,
    previous_revision: []const u8,
    revision: []const u8,
    source_id: u64,
    replacement_id: u64,
    evidence_id: u64,
    effect: []const u8,
    rolled_back: bool,
    build_id: []const u8,
};

/// Internal (non-wire) commit facts needed for exact rollback.
const InternalRecord = struct {
    request_id: []const u8,
    edge_id: u64,
    source_id: u64,
    replacement_id: u64,
    evidence_id: u64,
    previous_revision: []const u8,
    commit_revision: []const u8,
};

pub const migration_dir_name = ".tinykg-migration";

pub fn migrationPathAlloc(allocator: std.mem.Allocator, store: storage.Store, name: []const u8, suffix: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}/{s}.{s}", .{ store.dir_path, migration_dir_name, name, suffix });
}

pub fn writeFileDurablePublic(store: storage.Store, path: []const u8, bytes: []const u8) !void {
    return writeFileDurable(store, path, bytes);
}

fn writeFileDurable(store: storage.Store, path: []const u8, bytes: []const u8) !void {
    var buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const tmp_path = try std.fmt.bufPrint(&buffer, "{s}.tmp", .{path});
    if (std.fs.path.dirname(path)) |parent| try std.Io.Dir.cwd().createDirPath(store.io, parent);
    {
        var file = try std.Io.Dir.cwd().createFile(store.io, tmp_path, .{ .read = true, .truncate = true });
        defer file.close(store.io);
        try file.writePositionalAll(store.io, bytes, 0);
        try file.sync(store.io);
    }
    try std.Io.Dir.cwd().rename(tmp_path, std.Io.Dir.cwd(), path, store.io);
}

pub fn readFileIfExistsAlloc(allocator: std.mem.Allocator, store: storage.Store, path: []const u8) !?[]u8 {
    var file = std.Io.Dir.cwd().openFile(store.io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => |e| return e,
    };
    defer file.close(store.io);
    const stat = try file.stat(store.io);
    if (stat.size > 1024 * 1024) return error.InvalidCommitReceipt;
    const bytes = try allocator.alloc(u8, @intCast(stat.size));
    errdefer allocator.free(bytes);
    const n = try file.readPositionalAll(store.io, bytes, 0);
    if (n != bytes.len) return error.InvalidCommitReceipt;
    return bytes;
}

pub fn stringifyAlloc(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    errdefer out.deinit();
    try std.json.Stringify.value(value, .{}, &out.writer);
    return out.toOwnedSlice();
}

pub fn parseCommitRequest(arena: std.mem.Allocator, bytes: []const u8) !CommitRequest {
    const request = std.json.parseFromSliceLeaky(CommitRequest, arena, bytes, .{
        .ignore_unknown_fields = false,
        .duplicate_field_behavior = .@"error",
    }) catch return error.InvalidCommitRequest;
    if (!std.mem.eql(u8, request.schema_version, commit_schema_version)) return error.InvalidCommitRequest;
    if (!std.mem.eql(u8, request.operation, operation_name)) return error.InvalidCommitRequest;
    if (!std.mem.eql(u8, request.effect, effect_name)) return error.InvalidCommitRequest;
    if (!std.mem.eql(u8, request.rollback, rollback_name)) return error.InvalidCommitRequest;
    if (!isLowerHex64(request.request_id)) return error.InvalidCommitRequest;
    if (!isLowerHex64(request.expected_revision)) return error.InvalidCommitRequest;
    if (!isLowerHex64(request.snapshot_sha256)) return error.InvalidCommitRequest;
    if (!isLowerHex64(request.proposal_sha256)) return error.CheckerBindingMissing;
    if (!isLowerHex64(request.checker_verdict_sha256)) return error.CheckerBindingMissing;
    if (request.source_id == 0 or request.replacement_id == 0 or request.evidence_id == 0) return error.InvalidCommitRequest;
    if (request.source_id == request.replacement_id or request.source_id == request.evidence_id or request.replacement_id == request.evidence_id) return error.InvalidCommitRequest;
    if (!std.mem.startsWith(u8, request.expected_build_id, "sha256:") or request.expected_build_id.len != 7 + 64) return error.InvalidCommitRequest;
    return request;
}

pub fn rollbackTokenAlloc(allocator: std.mem.Allocator, request_id: []const u8, commit_revision: []const u8) ![]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("tinykg-migration-token:");
    hasher.update(request_id);
    hasher.update(":");
    hasher.update(commit_revision);
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hasher.final(&digest);
    return std.fmt.allocPrint(allocator, "{x}", .{&digest});
}
