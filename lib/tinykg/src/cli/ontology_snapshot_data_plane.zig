const std = @import("std");
const core = @import("../core.zig");
const storage = @import("../storage.zig");

/// Canonical exporter for `tinykg-ontology-rule-snapshot-v1`
/// (docs/frommetacodes/ontology-rule-snapshot-v1.md): one consistent read of
/// a project's governed ontology candidates, serialized as deterministic
/// canonical JSON with layered digests. Strictly read-only; every violation
/// is a typed error with no success body.
///
/// Storage mapping (the write-side contract metacodes populates):
/// - item nodes live in the project root's contain scope with
///   `schema_type` in {proposition, prescription, concept, intent};
/// - `ontology_authority` string property carries the authority enum;
/// - `ontology_falsifier` string property carries the falsifier text;
/// - `ontology_provenance` string property carries the canonical
///   `tinykg-ontology-provenance-v1` JSON body verbatim;
/// - `ontology_contradicted` / `retrieval_excluded` uint properties (0/1);
/// - deprecation is the physical `deprecated_by` outbound edge — the same
///   fact the memory-migration primitive commits;
/// - the project root carries `project_sha256` and `project_key` string
///   properties as its persistent identity.
pub const schema_version = "tinykg-ontology-rule-snapshot-v1";
pub const capability = "tinykg-ontology-rule-snapshot-v1";
pub const provenance_schema_version = "tinykg-ontology-provenance-v1";

pub const default_max_items: u64 = 48;
pub const default_max_chars: u64 = 200_000;
pub const hard_max_items: u64 = 512;
pub const hard_max_chars: u64 = 4 * 1024 * 1024;
pub const max_provenance_refs: usize = 16;

pub const Budgets = struct {
    max_items: u64 = default_max_items,
    max_chars: u64 = default_max_chars,

    pub fn validate(self: Budgets) !void {
        if (self.max_items == 0 or self.max_items > hard_max_items) return error.InvalidLimit;
        if (self.max_chars == 0 or self.max_chars > hard_max_chars) return error.InvalidLimit;
    }
};

const ontology_kinds = [_][]const u8{ "proposition", "prescription", "concept", "intent" };
const authority_values = [_][]const u8{ "user", "host_observed", "external_evidence", "agent_hypothesis" };
const provenance_kinds = [_][]const u8{ "user_correction", "host_observation", "external_evidence", "derived_claim" };

fn indexOfString(values: []const []const u8, needle: []const u8) ?usize {
    for (values, 0..) |value, index| {
        if (std.mem.eql(u8, value, needle)) return index;
    }
    return null;
}

const ProvenanceRef = struct {
    kind: []const u8,
    node_id: u64,
    evidence_sha256: []const u8,
};

const ProvenanceBody = struct {
    schema_version: []const u8,
    refs: []const ProvenanceRef,
};

const OntologyItem = struct {
    node_id: u64,
    kind: []const u8,
    scope: []const u8,
    authority: []const u8,
    summary: []const u8,
    summary_sha256: []const u8,
    provenance: []const ProvenanceRef,
    provenance_sha256: []const u8,
    falsifier: []const u8,
    falsifier_sha256: []const u8,
    contradicted: bool,
    deprecated: bool,
    retrieval_excluded: bool,
};

fn SnapshotBody(comptime with_revision: bool, comptime with_snapshot_digest: bool) type {
    _ = with_snapshot_digest;
    if (with_revision) {
        return struct {
            schema_version: []const u8,
            capability: []const u8,
            tinykg_build_id: []const u8,
            project_node_id: u64,
            project_sha256: []const u8,
            project_key: []const u8,
            revision: []const u8,
            bounded: bool,
            truncated: bool,
            max_items: u64,
            max_chars: u64,
            used_chars: u64,
            ontology: []const OntologyItem,
        };
    }
    return struct {
        schema_version: []const u8,
        capability: []const u8,
        tinykg_build_id: []const u8,
        project_node_id: u64,
        project_sha256: []const u8,
        project_key: []const u8,
        bounded: bool,
        truncated: bool,
        max_items: u64,
        max_chars: u64,
        used_chars: u64,
        ontology: []const OntologyItem,
    };
}

const FullResponse = struct {
    schema_version: []const u8,
    capability: []const u8,
    tinykg_build_id: []const u8,
    project_node_id: u64,
    project_sha256: []const u8,
    project_key: []const u8,
    revision: []const u8,
    bounded: bool,
    truncated: bool,
    max_items: u64,
    max_chars: u64,
    used_chars: u64,
    ontology: []const OntologyItem,
    snapshot_sha256: []const u8,
};

fn sha256Hex(bytes: []const u8, out: *[64]u8) void {
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    _ = std.fmt.bufPrint(out, "{x}", .{&digest}) catch unreachable;
}

fn u64LessThan(_: void, a: u64, b: u64) bool {
    return a < b;
}

/// Export the ontology snapshot as canonical JSON bytes; caller owns the
/// slice. `build_id` is the "sha256:<hex>" identity of the executing engine.
pub fn exportOntologySnapshotAlloc(
    allocator: std.mem.Allocator,
    store: storage.Store,
    project_node_id: core.NodeId,
    expected_project_sha256: []const u8,
    expected_project_key: []const u8,
    budgets: Budgets,
    build_id: []const u8,
) ![]u8 {
    try budgets.validate();
    if (expected_project_sha256.len != 64) return error.ProjectIdentityMismatch;
    for (expected_project_sha256) |byte| switch (byte) {
        '0'...'9', 'a'...'f' => {},
        else => return error.ProjectIdentityMismatch,
    };
    if (expected_project_key.len == 0) return error.ProjectIdentityMismatch;

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // --- project root admission and persistent identity -----------------
    {
        var root_node = (try store.readNodeById(arena, project_node_id)) orelse return error.NotFound;
        const is_project = root_node.kind == .project;
        root_node.deinit(arena);
        if (!is_project) return error.NotFound;
    }
    {
        const stored_sha = (try store.getNodeStringProperty(arena, project_node_id, "project_sha256")) orelse return error.ProjectIdentityMismatch;
        if (!std.mem.eql(u8, stored_sha, expected_project_sha256)) return error.ProjectIdentityMismatch;
        const stored_key = (try store.getNodeStringProperty(arena, project_node_id, "project_key")) orelse return error.ProjectIdentityMismatch;
        if (!std.mem.eql(u8, stored_key, expected_project_key)) return error.ProjectIdentityMismatch;
    }

    const scope = try std.fmt.allocPrint(arena, "project:{s}", .{expected_project_key});

    // --- containment scope walk (any node kind; cycles fail closed) -----
    var member_set = std.AutoHashMap(u64, void).init(arena);
    var candidate_ids = std.ArrayList(u64).empty;
    var queue = std.ArrayList(u64).empty;
    try member_set.put(project_node_id.toInt(), {});
    try queue.append(arena, project_node_id.toInt());
    var queue_index: usize = 0;
    while (queue_index < queue.items.len) : (queue_index += 1) {
        const parent = queue.items[queue_index];
        var records = try store.readVisibleEdgeIndexRecordsByNodeForOrderedTraversal(arena, core.NodeId.fromInt(parent));
        defer records.deinit(arena);
        var seen_children = std.AutoHashMap(u64, void).init(arena);
        defer seen_children.deinit();
        for (records.items) |record| {
            if (record.rel != @intFromEnum(core.RelKind.contain)) continue;
            if (record.dst == 0 or record.dst == parent) return error.ProjectScopeViolation;
            if (seen_children.contains(record.dst)) continue;
            try seen_children.put(record.dst, {});
            if (member_set.contains(record.dst)) continue;
            try member_set.put(record.dst, {});
            try candidate_ids.append(arena, record.dst);
            try queue.append(arena, record.dst);
        }
    }
    std.mem.sort(u64, candidate_ids.items, {}, u64LessThan);

    // --- item selection and field mapping --------------------------------
    var items = std.ArrayList(OntologyItem).empty;
    var used_chars: u64 = 0;
    for (candidate_ids.items) |id| {
        const node_id = core.NodeId.fromInt(id);
        const schema_type = (try store.getNodeStringProperty(arena, node_id, "schema_type")) orelse continue;
        if (indexOfString(&ontology_kinds, schema_type) == null) continue;

        // Governance flags first: v1 exports only current candidates.
        var deprecated = false;
        {
            var outbound = try store.readVisibleEdgeIndexRecordsByNodeForOrderedTraversal(arena, node_id);
            defer outbound.deinit(arena);
            for (outbound.items) |record| {
                if (record.rel == @intFromEnum(core.RelKind.deprecated_by)) {
                    deprecated = true;
                    break;
                }
            }
        }
        const retrieval_excluded = ((try store.getUintProperty(arena, .{ .node = node_id }, "retrieval_excluded")) orelse 0) != 0;
        if (deprecated or retrieval_excluded) continue;
        const contradicted = ((try store.getUintProperty(arena, .{ .node = node_id }, "ontology_contradicted")) orelse 0) != 0;

        const authority = (try store.getNodeStringProperty(arena, node_id, "ontology_authority")) orelse return error.InvalidOntologyAuthority;
        if (indexOfString(&authority_values, authority) == null) return error.InvalidOntologyAuthority;
        const falsifier = (try store.getNodeStringProperty(arena, node_id, "ontology_falsifier")) orelse return error.InvalidRecord;
        if (falsifier.len == 0) return error.InvalidRecord;

        var node = (try store.readNodeById(arena, node_id)) orelse return error.InvalidRecord;
        const summary = try arena.dupe(u8, node.text);
        node.deinit(arena);

        // Provenance: verbatim canonical body written by the governing
        // control plane, revalidated structurally on every export.
        const provenance_raw = (try store.getNodeStringProperty(arena, node_id, "ontology_provenance")) orelse return error.InvalidOntologyProvenance;
        const provenance = try parseProvenance(arena, store, provenance_raw);

        var summary_hash: [64]u8 = undefined;
        sha256Hex(summary, &summary_hash);
        var falsifier_hash: [64]u8 = undefined;
        sha256Hex(falsifier, &falsifier_hash);
        const provenance_body = ProvenanceBody{ .schema_version = provenance_schema_version, .refs = provenance };
        var provenance_bytes = std.Io.Writer.Allocating.init(arena);
        try std.json.Stringify.value(provenance_body, .{}, &provenance_bytes.writer);
        var provenance_hash: [64]u8 = undefined;
        sha256Hex(provenance_bytes.writer.buffered(), &provenance_hash);

        used_chars += summary.len + falsifier.len;
        try items.append(arena, .{
            .node_id = id,
            .kind = schema_type,
            .scope = scope,
            .authority = authority,
            .summary = summary,
            .summary_sha256 = try arena.dupe(u8, &summary_hash),
            .provenance = provenance,
            .provenance_sha256 = try arena.dupe(u8, &provenance_hash),
            .falsifier = falsifier,
            .falsifier_sha256 = try arena.dupe(u8, &falsifier_hash),
            .contradicted = contradicted,
            .deprecated = false,
            .retrieval_excluded = false,
        });
        if (items.items.len > budgets.max_items) return error.OntologySnapshotTooLarge;
    }
    if (used_chars > budgets.max_chars) return error.OntologySnapshotTooLarge;

    // --- layered digests --------------------------------------------------
    const semantic = SnapshotBody(false, false){
        .schema_version = schema_version,
        .capability = capability,
        .tinykg_build_id = build_id,
        .project_node_id = project_node_id.toInt(),
        .project_sha256 = expected_project_sha256,
        .project_key = expected_project_key,
        .bounded = true,
        .truncated = false,
        .max_items = budgets.max_items,
        .max_chars = budgets.max_chars,
        .used_chars = used_chars,
        .ontology = items.items,
    };
    var semantic_bytes = std.Io.Writer.Allocating.init(arena);
    try std.json.Stringify.value(semantic, .{}, &semantic_bytes.writer);
    var revision_hex: [64]u8 = undefined;
    sha256Hex(semantic_bytes.writer.buffered(), &revision_hex);

    const with_revision = SnapshotBody(true, false){
        .schema_version = schema_version,
        .capability = capability,
        .tinykg_build_id = build_id,
        .project_node_id = project_node_id.toInt(),
        .project_sha256 = expected_project_sha256,
        .project_key = expected_project_key,
        .revision = &revision_hex,
        .bounded = true,
        .truncated = false,
        .max_items = budgets.max_items,
        .max_chars = budgets.max_chars,
        .used_chars = used_chars,
        .ontology = items.items,
    };
    var body_bytes = std.Io.Writer.Allocating.init(arena);
    try std.json.Stringify.value(with_revision, .{}, &body_bytes.writer);
    var snapshot_hex: [64]u8 = undefined;
    sha256Hex(body_bytes.writer.buffered(), &snapshot_hex);

    const response = FullResponse{
        .schema_version = schema_version,
        .capability = capability,
        .tinykg_build_id = build_id,
        .project_node_id = project_node_id.toInt(),
        .project_sha256 = expected_project_sha256,
        .project_key = expected_project_key,
        .revision = &revision_hex,
        .bounded = true,
        .truncated = false,
        .max_items = budgets.max_items,
        .max_chars = budgets.max_chars,
        .used_chars = used_chars,
        .ontology = items.items,
        .snapshot_sha256 = &snapshot_hex,
    };
    var out = std.Io.Writer.Allocating.init(allocator);
    errdefer out.deinit();
    try std.json.Stringify.value(response, .{}, &out.writer);
    return out.toOwnedSlice();
}

fn parseProvenance(
    arena: std.mem.Allocator,
    store: storage.Store,
    raw: []const u8,
) ![]ProvenanceRef {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, raw, .{}) catch return error.InvalidOntologyProvenance;
    if (parsed != .object) return error.InvalidOntologyProvenance;
    const object = parsed.object;
    if (object.count() != 2) return error.InvalidOntologyProvenance;
    const declared_version = object.get("schema_version") orelse return error.InvalidOntologyProvenance;
    if (declared_version != .string or !std.mem.eql(u8, declared_version.string, provenance_schema_version)) return error.InvalidOntologyProvenance;
    const refs_value = object.get("refs") orelse return error.InvalidOntologyProvenance;
    if (refs_value != .array) return error.InvalidOntologyProvenance;
    const refs_json = refs_value.array.items;
    if (refs_json.len == 0 or refs_json.len > max_provenance_refs) return error.InvalidOntologyProvenance;

    var refs = try arena.alloc(ProvenanceRef, refs_json.len);
    var previous_kind_index: usize = 0;
    var previous_node_id: u64 = 0;
    var have_previous = false;
    for (refs_json, 0..) |ref_value, index| {
        if (ref_value != .object) return error.InvalidOntologyProvenance;
        const ref = ref_value.object;
        if (ref.count() != 3) return error.InvalidOntologyProvenance;
        const kind_value = ref.get("kind") orelse return error.InvalidOntologyProvenance;
        if (kind_value != .string) return error.InvalidOntologyProvenance;
        const kind_index = indexOfString(&provenance_kinds, kind_value.string) orelse return error.InvalidOntologyProvenance;
        const node_value = ref.get("node_id") orelse return error.InvalidOntologyProvenance;
        if (node_value != .integer or node_value.integer <= 0) return error.InvalidOntologyProvenance;
        const ref_node_id: u64 = @intCast(node_value.integer);
        const evidence_value = ref.get("evidence_sha256") orelse return error.InvalidOntologyProvenance;
        if (evidence_value != .string or evidence_value.string.len != 64) return error.InvalidOntologyProvenance;
        for (evidence_value.string) |byte| switch (byte) {
            '0'...'9', 'a'...'f' => {},
            else => return error.InvalidOntologyProvenance,
        };
        // Strict (kind, node_id) ascending order, no duplicates.
        if (have_previous) {
            if (kind_index < previous_kind_index) return error.InvalidOntologyProvenance;
            if (kind_index == previous_kind_index and ref_node_id <= previous_node_id) return error.InvalidOntologyProvenance;
        }
        previous_kind_index = kind_index;
        previous_node_id = ref_node_id;
        have_previous = true;
        // No dangling refs: the node must resolve inside this same snapshot.
        var referenced = (try store.readNodeById(arena, core.NodeId.fromInt(ref_node_id))) orelse return error.InvalidOntologyProvenance;
        referenced.deinit(arena);
        refs[index] = .{
            .kind = provenance_kinds[kind_index],
            .node_id = ref_node_id,
            .evidence_sha256 = try arena.dupe(u8, evidence_value.string),
        };
    }
    return refs;
}
