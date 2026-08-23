//! Production read-only TinyKG -> ontology rule-author projection adapter.
//!
//! TinyKG owns one consistent read primitive and its semantic revision;
//! metacodes owns the surrounding transaction/control loop. It verifies the
//! exact source wire, merges only locally authenticated generation evidence
//! and sealed held-out commitments, re-observes the source, then persists the
//! existing content-addressed projection receipt. No actor Conversation,
//! system prompt, tool schema, provider, or TinyKG write path is accepted by
//! this API.

const std = @import("std");
const projection = @import("../core/ontology_rule_projection.zig");
const observation = @import("../tools/observation.zig");
const kg_client = @import("client.zig");

pub const CAPABILITY = projection.SOURCE_CAPABILITY;
pub const SOURCE_SCHEMA = "tinykg-ontology-rule-snapshot-v1";
pub const MAX_SOURCE_BYTES: usize = projection.MAX_SNAPSHOT_BYTES;
pub const MAX_PROVENANCE_REFS: usize = 16;

pub const ProvenanceKind = enum {
    user_correction,
    host_observation,
    external_evidence,
    derived_claim,
};

pub const ProvenanceRef = struct {
    kind: ProvenanceKind,
    node_id: u64,
    evidence_sha256: []const u8,
};

const ProvenanceBody = struct {
    schema_version: []const u8 = "tinykg-ontology-provenance-v1",
    refs: []const ProvenanceRef,
};

pub const ActiveRules = struct {
    bundle_revision: u64,
    bundle_sha256: [64]u8,
};

pub const Request = struct {
    project_node_id: u64,
    project_sha256: [64]u8,
    project_key: []const u8,
    active_rules: ActiveRules,
    generation_evidence: []const projection.GenerationEvidence,
    held_out_commitments: []const projection.HeldOutCommitment,
};

pub const ReadTransport = struct {
    ptr: *anyopaque,
    build_sha256_fn: *const fn (*anyopaque) anyerror![64]u8,
    snapshot_fn: *const fn (*anyopaque, std.mem.Allocator, u64, [64]u8, []const u8) anyerror![]u8,

    pub fn buildSha256(self: ReadTransport) ![64]u8 {
        return self.build_sha256_fn(self.ptr);
    }

    pub fn snapshotIdentity(
        self: ReadTransport,
        allocator: std.mem.Allocator,
        project_node_id: u64,
        project_sha256: [64]u8,
        project_key: []const u8,
    ) ![]u8 {
        return self.snapshot_fn(
            self.ptr,
            allocator,
            project_node_id,
            project_sha256,
            project_key,
        );
    }
};

pub const KgClientTransport = struct {
    client: *kg_client.KgClient,

    pub fn transport(self: *KgClientTransport) ReadTransport {
        return .{
            .ptr = self,
            .build_sha256_fn = buildSha256,
            .snapshot_fn = snapshot,
        };
    }

    fn cast(ptr: *anyopaque) *KgClientTransport {
        return @ptrCast(@alignCast(ptr));
    }

    fn buildSha256(ptr: *anyopaque) ![64]u8 {
        return cast(ptr).client.controlPlaneBuildSha256();
    }

    fn snapshot(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        project_node_id: u64,
        project_sha256: [64]u8,
        project_key: []const u8,
    ) ![]u8 {
        const client = cast(ptr).client;
        const raw = try client.ontologyRuleSnapshot(
            project_node_id,
            project_sha256,
            project_key,
        );
        defer client.allocator.free(raw);
        return allocator.dupe(u8, raw);
    }
};

pub const Prepared = struct {
    allocator: std.mem.Allocator,
    project_node_id: u64,
    project_key: []u8,
    source_snapshot: []u8,
    rendered_snapshot: []u8,
    projected: projection.Projection,

    pub fn deinit(self: *Prepared) void {
        self.projected.deinit();
        self.allocator.free(self.project_key);
        self.allocator.free(self.source_snapshot);
        self.allocator.free(self.rendered_snapshot);
        self.* = undefined;
    }
};

pub const Result = struct {
    receipt_id: [64]u8,
    created: bool,
    tinykg_build_sha256: [64]u8,
    source_semantic_snapshot_sha256: [64]u8,
    source_artifact_sha256: [64]u8,
    ontology_revision: [64]u8,
    ontology_snapshot_sha256: [64]u8,
    packet_sha256: [64]u8,
};

const SourceItem = struct {
    node_id: u64,
    kind: projection.OntologyKind,
    scope: []const u8,
    authority: projection.Authority,
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

const SourceDocument = struct {
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
    ontology: []const SourceItem,
    snapshot_sha256: []const u8,
};

const SourceCommitment = struct {
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
    ontology: []const SourceItem,
};

const ParsedSource = struct {
    arena: std.heap.ArenaAllocator,
    document: SourceDocument,
    revision: [64]u8,
    semantic_snapshot_sha256: [64]u8,
    artifact_sha256: [64]u8,
    items: []const projection.OntologyItem,

    fn deinit(self: *ParsedSource) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub fn prepare(
    allocator: std.mem.Allocator,
    transport: ReadTransport,
    request: Request,
) !Prepared {
    try validateRequest(request);
    const build_before = try transport.buildSha256();
    try requireNonzeroHex(build_before);
    const source = try transport.snapshotIdentity(
        allocator,
        request.project_node_id,
        request.project_sha256,
        request.project_key,
    );
    errdefer allocator.free(source);
    var parsed = try parseSource(allocator, source, request, build_before);
    defer parsed.deinit();

    const snapshot_input = projection.SnapshotInput{
        .project_sha256 = request.project_sha256,
        .project_key = request.project_key,
        .revision = parsed.revision,
        .source = .{
            .tinykg_build_id = parsed.document.tinykg_build_id,
            .semantic_snapshot_sha256 = parsed.semantic_snapshot_sha256[0..],
            .artifact_sha256 = parsed.artifact_sha256[0..],
        },
        .active_bundle_revision = request.active_rules.bundle_revision,
        .active_bundle_sha256 = request.active_rules.bundle_sha256,
        .ontology = parsed.items,
        .generation_evidence = request.generation_evidence,
        .held_out_commitments = request.held_out_commitments,
    };
    const rendered = try projection.renderSnapshot(allocator, &snapshot_input);
    errdefer allocator.free(rendered.bytes);
    var projected = try projection.project(
        allocator,
        rendered.bytes,
        request.project_sha256,
        parsed.revision,
        rendered.snapshot_sha256,
        request.active_rules.bundle_revision,
        request.active_rules.bundle_sha256,
        build_before,
        parsed.semantic_snapshot_sha256,
        parsed.artifact_sha256,
    );
    errdefer projected.deinit();

    const reobserved = try transport.snapshotIdentity(
        allocator,
        request.project_node_id,
        request.project_sha256,
        request.project_key,
    );
    defer allocator.free(reobserved);
    if (!std.mem.eql(u8, source, reobserved)) return error.OntologySourceDrift;
    const build_after = try transport.buildSha256();
    if (!std.mem.eql(u8, &build_before, &build_after)) return error.TinyKgBuildDrift;
    var reparsed = try parseSource(allocator, reobserved, request, build_after);
    reparsed.deinit();

    const project_key = try allocator.dupe(u8, request.project_key);
    errdefer allocator.free(project_key);
    return .{
        .allocator = allocator,
        .project_node_id = request.project_node_id,
        .project_key = project_key,
        .source_snapshot = source,
        .rendered_snapshot = rendered.bytes,
        .projected = projected,
    };
}

pub fn persist(
    allocator: std.mem.Allocator,
    session_dir: []const u8,
    prepared: *const Prepared,
) !Result {
    const persisted = try projection.persist(
        allocator,
        session_dir,
        prepared.source_snapshot,
        prepared.rendered_snapshot,
        &prepared.projected,
    );
    return .{
        .receipt_id = persisted.receipt_id,
        .created = persisted.created,
        .tinykg_build_sha256 = prepared.projected.tinykg_build_sha256,
        .source_semantic_snapshot_sha256 = prepared.projected.source_semantic_snapshot_sha256,
        .source_artifact_sha256 = prepared.projected.source_artifact_sha256,
        .ontology_revision = prepared.projected.ontology_revision,
        .ontology_snapshot_sha256 = prepared.projected.ontology_snapshot_sha256,
        .packet_sha256 = prepared.projected.packet_sha256,
    };
}

pub fn execute(
    allocator: std.mem.Allocator,
    session_dir: []const u8,
    transport: ReadTransport,
    request: Request,
) !Result {
    var prepared = try prepare(allocator, transport, request);
    defer prepared.deinit();
    return persist(allocator, session_dir, &prepared);
}

/// Re-observe the exact canonical TinyKG source after an external operation
/// such as rule authoring.  The initial validated bytes are the authority: a
/// matching revision string with different facts is still rejected.  Two
/// reads around the build identity close replacement/drift windows without
/// writing to TinyKG.
pub fn reobservePrepared(
    allocator: std.mem.Allocator,
    transport: ReadTransport,
    prepared: *const Prepared,
) !void {
    const first = try transport.snapshotIdentity(
        allocator,
        prepared.project_node_id,
        prepared.projected.project_sha256,
        prepared.project_key,
    );
    defer allocator.free(first);
    if (!std.mem.eql(u8, first, prepared.source_snapshot))
        return error.OntologySourceDrift;
    const build = try transport.buildSha256();
    if (!std.mem.eql(u8, &build, &prepared.projected.tinykg_build_sha256))
        return error.TinyKgBuildDrift;
    const second = try transport.snapshotIdentity(
        allocator,
        prepared.project_node_id,
        prepared.projected.project_sha256,
        prepared.project_key,
    );
    defer allocator.free(second);
    if (!std.mem.eql(u8, second, prepared.source_snapshot))
        return error.OntologySourceDrift;
}

fn parseSource(
    allocator: std.mem.Allocator,
    raw: []const u8,
    request: Request,
    expected_build: [64]u8,
) !ParsedSource {
    if (raw.len == 0 or raw.len > MAX_SOURCE_BYTES) return error.InvalidOntologySource;
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    const document = std.json.parseFromSliceLeaky(SourceDocument, a, raw, .{
        .ignore_unknown_fields = false,
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    }) catch return error.InvalidOntologySource;
    const canonical = try std.json.Stringify.valueAlloc(a, document, .{});
    if (!std.mem.eql(u8, canonical, raw)) return error.NonCanonicalOntologySource;
    if (!std.mem.eql(u8, document.schema_version, SOURCE_SCHEMA) or
        !std.mem.eql(u8, document.capability, CAPABILITY) or
        document.project_node_id != request.project_node_id or
        !std.mem.eql(u8, document.project_key, request.project_key) or
        !document.bounded or document.truncated or
        document.max_items != projection.MAX_ONTOLOGY_ITEMS or
        document.max_chars == 0 or document.max_chars > 200_000 or
        document.used_chars > document.max_chars or
        document.ontology.len > document.max_items)
        return error.InvalidOntologySource;
    const project = parseHex(document.project_sha256) orelse return error.InvalidOntologySource;
    const revision = parseHex(document.revision) orelse return error.InvalidOntologySource;
    const declared = parseHex(document.snapshot_sha256) orelse return error.InvalidOntologySource;
    const build = parseBuildId(document.tinykg_build_id) orelse return error.InvalidOntologySource;
    if (!std.mem.eql(u8, &project, &request.project_sha256) or
        !std.mem.eql(u8, &build, &expected_build) or isZero(revision) or isZero(declared))
        return error.OntologySourceIdentityMismatch;
    const commitment = try std.json.Stringify.valueAlloc(a, SourceCommitment{
        .schema_version = document.schema_version,
        .capability = document.capability,
        .tinykg_build_id = document.tinykg_build_id,
        .project_node_id = document.project_node_id,
        .project_sha256 = document.project_sha256,
        .project_key = document.project_key,
        .revision = document.revision,
        .bounded = document.bounded,
        .truncated = document.truncated,
        .max_items = document.max_items,
        .max_chars = document.max_chars,
        .used_chars = document.used_chars,
        .ontology = document.ontology,
    }, .{});
    if (!std.mem.eql(u8, &observation.sha256Hex(commitment), &declared))
        return error.OntologySourceHashMismatch;

    // Source snapshot structs have the exact same semantic field set as the
    // projection input. Keep one allocation but do not pointer-cast slices:
    // explicit copying lets Zig's type checker enforce future wire changes.
    const items = try a.alloc(projection.OntologyItem, document.ontology.len);
    var prior: u64 = 0;
    for (document.ontology, items) |item, *out| {
        if (item.node_id == 0 or item.node_id <= prior) return error.InvalidOntologySource;
        prior = item.node_id;
        if (item.provenance.len == 0 or item.provenance.len > MAX_PROVENANCE_REFS)
            return error.InvalidOntologyProvenance;
        var prior_ref: ?struct { kind: ProvenanceKind, node_id: u64 } = null;
        for (item.provenance) |ref| {
            const evidence = parseHex(ref.evidence_sha256) orelse
                return error.InvalidOntologyProvenance;
            if (ref.node_id == 0 or isZero(evidence)) return error.InvalidOntologyProvenance;
            if (prior_ref) |prior_value| {
                // Canonical ref order is the kind enum's declaration order
                // (user_correction < host_observation < external_evidence <
                // derived_claim — the wire spec's authority-first listing,
                // matched by TinyKG's exporter), then strictly ascending
                // node_id inside one kind. Not lexicographic tag spelling.
                if (@intFromEnum(ref.kind) < @intFromEnum(prior_value.kind) or
                    (ref.kind == prior_value.kind and ref.node_id <= prior_value.node_id))
                    return error.InvalidOntologyProvenance;
            }
            prior_ref = .{ .kind = ref.kind, .node_id = ref.node_id };
        }
        const declared_provenance = parseHex(item.provenance_sha256) orelse
            return error.InvalidOntologyProvenance;
        const provenance_json = try std.json.Stringify.valueAlloc(a, ProvenanceBody{
            .refs = item.provenance,
        }, .{});
        if (!std.mem.eql(u8, &declared_provenance, &observation.sha256Hex(provenance_json)))
            return error.OntologyProvenanceHashMismatch;
        out.* = .{
            .node_id = item.node_id,
            .kind = item.kind,
            .scope = item.scope,
            .authority = item.authority,
            .summary = item.summary,
            .summary_sha256 = item.summary_sha256,
            .provenance_sha256 = item.provenance_sha256,
            .falsifier = item.falsifier,
            .falsifier_sha256 = item.falsifier_sha256,
            .contradicted = item.contradicted,
            .deprecated = item.deprecated,
            .retrieval_excluded = item.retrieval_excluded,
        };
    }
    return .{
        .arena = arena,
        .document = document,
        .revision = revision,
        .semantic_snapshot_sha256 = declared,
        .artifact_sha256 = observation.sha256Hex(raw),
        .items = items,
    };
}

fn validateRequest(request: Request) !void {
    if (request.project_node_id == 0 or request.project_key.len == 0 or
        request.project_key.len > projection.MAX_PROJECT_KEY_BYTES or
        request.generation_evidence.len == 0 or
        request.generation_evidence.len > projection.MAX_GENERATION_EVIDENCE or
        request.held_out_commitments.len == 0 or
        request.held_out_commitments.len > projection.MAX_HELD_OUT_COMMITMENTS)
        return error.InvalidOntologyRequest;
    try requireNonzeroHex(request.project_sha256);
    if ((request.active_rules.bundle_revision == 0) != isZero(request.active_rules.bundle_sha256))
        return error.InvalidOntologyRequest;
}

fn requireNonzeroHex(value: [64]u8) !void {
    if (parseHex(value[0..]) == null or isZero(value)) return error.InvalidOntologyIdentity;
}

fn parseBuildId(value: []const u8) ?[64]u8 {
    const prefix = "sha256:";
    if (!std.mem.startsWith(u8, value, prefix)) return null;
    return parseHex(value[prefix.len..]);
}

fn parseHex(value: []const u8) ?[64]u8 {
    if (value.len != 64) return null;
    var result: [64]u8 = undefined;
    for (value, 0..) |byte, index| {
        if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return null;
        result[index] = byte;
    }
    return result;
}

fn isZero(value: [64]u8) bool {
    return std.mem.eql(u8, &value, &([_]u8{'0'} ** 64));
}
