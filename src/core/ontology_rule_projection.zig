//! Bounded, read-only TinyKG ontology projection for the isolated rule author.
//!
//! TinyKG owns the canonical graph and the semantic revision.  This module
//! consumes a host-exported, versioned snapshot; it never opens or mutates a
//! store.  The projection deliberately separates three things which an LLM
//! must not be allowed to conflate:
//! - ontology hypotheses/context, which may guide candidate generation;
//! - generation evidence, which is visible to the author and must remain
//!   independently reopenable by its owning host adapter; and
//! - held-out commitments, whose results are hidden until replay/shadow or
//!   impact evaluation and therefore cannot leak into candidate generation.
//!
//! The returned JSON is canonical for the concrete wire structs below.  Its
//! digest is suitable for binding a RuleAuthor permit/receipt, but it grants no
//! mutation, build, promotion, or runtime authority.
//!
//! Artifact paths are anchored below a session-owned private directory.  Final
//! components are opened with no-follow semantics and verified as single-link
//! regular files.  Callers must not place this control evidence under an
//! attacker-writable parent; a future shared-directory API must accept an
//! already-open directory fd/handle instead of re-resolving a pathname.

const std = @import("std");
const pfs = @import("platform").fs;
const observation = @import("../tools/observation.zig");
const source_receipt = @import("rule_source_receipt.zig");
const impact_receipt = @import("rule_impact_receipt.zig");

pub const SNAPSHOT_SCHEMA_VERSION = "tinykg-ontology-rule-projection-v1";
pub const PACKET_SCHEMA_VERSION = "metacodes-ontology-to-rule-packet-v1";
pub const RECEIPT_SCHEMA_VERSION = "metacodes-ontology-rule-projection-receipt-v1";
pub const HELD_OUT_COMMITMENT_SCHEMA_VERSION = "metacodes-held-out-window-commitment-v1";
pub const RULE_IMPACT_SUMMARY_SCHEMA_VERSION = "metacodes-rule-impact-generation-summary-v1";
pub const SNAPSHOT_FILE_PREFIX = "ontology-rule-snapshot-";
pub const RECEIPT_FILE_PREFIX = "ontology-rule-projection-receipt-";

pub const MAX_SNAPSHOT_BYTES: usize = 256 * 1024;
pub const MAX_PACKET_BYTES: usize = 48 * 1024;
pub const MAX_PROJECT_KEY_BYTES: usize = 512;
pub const MAX_SCOPE_BYTES: usize = 256;
pub const MAX_SUMMARY_BYTES: usize = 2048;
pub const MAX_FALSIFIER_BYTES: usize = 2048;
pub const MAX_ONTOLOGY_ITEMS: usize = 48;
pub const MAX_GENERATION_EVIDENCE: usize = 16;
pub const MAX_HELD_OUT_COMMITMENTS: usize = 64;
pub const MAX_RECEIPT_BYTES: usize = 16 * 1024;
const ZERO_SHA = [_]u8{'0'} ** 64;

pub const OntologyKind = enum {
    proposition,
    prescription,
    concept,
    intent,
};

pub const Authority = enum {
    user,
    host_observed,
    external_evidence,
    agent_hypothesis,
};

pub const EvidenceKind = enum {
    user_correction,
    runtime_counterexample,
    rule_impact,
};

pub const ActiveRules = struct {
    bundle_revision: u64,
    bundle_sha256: []const u8,
};

pub const OntologyItem = struct {
    node_id: u64,
    kind: OntologyKind,
    scope: []const u8,
    authority: Authority,
    summary: []const u8,
    summary_sha256: []const u8,
    provenance_sha256: []const u8,
    falsifier: []const u8,
    contradicted: bool,
    deprecated: bool,
    retrieval_excluded: bool,
};

pub const GenerationEvidence = struct {
    receipt_sha256: []const u8,
    kind: EvidenceKind,
    subject_sha256: []const u8,
    interval_sha256: ?[]const u8,
    /// Opaque identity in the host's frozen split namespace.  This is not a
    /// result or prompt; it exists solely so generation and held-out member
    /// sets can be checked for exact disjointness before authoring.
    window_member_sha256: []const u8,
    summary: []const u8,
    summary_sha256: []const u8,
};

pub const HeldOutCommitment = struct {
    commitment_sha256: []const u8,
    suite_sha256: []const u8,
    case_count: u64,
    member_sha256: []const []const u8,
    sealed: bool,
};

pub const SnapshotInput = struct {
    project_sha256: [64]u8,
    project_key: []const u8,
    revision: [64]u8,
    bounded: bool = true,
    truncated: bool = false,
    active_bundle_revision: u64,
    active_bundle_sha256: [64]u8,
    ontology: []const OntologyItem,
    generation_evidence: []const GenerationEvidence,
    held_out_commitments: []const HeldOutCommitment,
};

const SnapshotCommitmentBody = struct {
    schema_version: []const u8,
    project_sha256: []const u8,
    project_key: []const u8,
    revision: []const u8,
    bounded: bool,
    truncated: bool,
    active_rules: ActiveRules,
    ontology: []const OntologyItem,
    generation_evidence: []const GenerationEvidence,
    held_out_commitments: []const HeldOutCommitment,
};

const RawSnapshot = struct {
    schema_version: []const u8,
    project_sha256: []const u8,
    project_key: []const u8,
    revision: []const u8,
    snapshot_sha256: []const u8,
    bounded: bool,
    truncated: bool,
    active_rules: ActiveRules,
    ontology: []const OntologyItem,
    generation_evidence: []const GenerationEvidence,
    held_out_commitments: []const HeldOutCommitment,
};

pub const RenderedSnapshot = struct {
    bytes: []u8,
    snapshot_sha256: [64]u8,
};

pub fn heldOutCommitmentSha256(
    allocator: std.mem.Allocator,
    suite_sha256: [64]u8,
    member_sha256: []const []const u8,
) ![64]u8 {
    try requireNonzeroHex(suite_sha256);
    if (member_sha256.len == 0 or member_sha256.len > std.math.maxInt(u32))
        return error.InvalidHeldOutCommitment;
    var prior: ?[64]u8 = null;
    for (member_sha256) |raw_member| {
        const member = parseHex(raw_member) orelse return error.InvalidHeldOutCommitment;
        if (isZero(member) or (prior != null and orderHex(prior.?, member) != .lt))
            return error.InvalidHeldOutCommitment;
        prior = member;
    }
    const encoded = try std.json.Stringify.valueAlloc(allocator, HeldOutCommitmentBody{
        .suite_sha256 = suite_sha256[0..],
        .case_count = member_sha256.len,
        .member_sha256 = member_sha256,
    }, .{});
    defer allocator.free(encoded);
    return observation.sha256Hex(encoded);
}

const PacketActiveRules = struct {
    bundle_revision: u64,
    bundle_sha256: []const u8,
};

const PacketOntology = struct {
    node_id: u64,
    kind: OntologyKind,
    scope: []const u8,
    authority: Authority,
    summary: []const u8,
    summary_sha256: []const u8,
    provenance_sha256: []const u8,
    falsifier: []const u8,
    contradicted: bool,
};

const PacketEvidence = struct {
    receipt_sha256: []const u8,
    kind: EvidenceKind,
    subject_sha256: []const u8,
    interval_sha256: ?[]const u8,
    window_member_sha256: []const u8,
    summary: []const u8,
    summary_sha256: []const u8,
};

const PacketHeldOut = struct {
    commitment_sha256: []const u8,
    suite_sha256: []const u8,
    case_count: u64,
    member_sha256: []const []const u8,
};

const HeldOutCommitmentBody = struct {
    schema_version: []const u8 = HELD_OUT_COMMITMENT_SCHEMA_VERSION,
    suite_sha256: []const u8,
    case_count: u64,
    member_sha256: []const []const u8,
    results_visible: bool = false,
};

const RuleImpactSummary = struct {
    schema_version: []const u8 = RULE_IMPACT_SUMMARY_SCHEMA_VERSION,
    source_interval_sha256: []const u8,
    formal_decisions: u64,
    formal_faults: u64,
    authoritative_dispatches: u64,
    authoritative_successes: u64,
    authoritative_non_successes: u64,
    invalid_effects: u64,
    reobservation_failures: u64,
    enforced_pre_blocks_before_dispatch: u64,
    task_success: ?bool,
    trustworthy_success: ?bool,
    drift_detected: ?bool,
    false_interventions: ?u64,
    regressions: ?u64,
    provider_requests: ?u64,
    metered_tokens: ?u64,
    cost_microusd: ?u64,
    wall_elapsed_ns: ?u64,
};

const WirePacket = struct {
    schema_version: []const u8 = PACKET_SCHEMA_VERSION,
    project_sha256: []const u8,
    project_key: []const u8,
    ontology_revision: []const u8,
    ontology_snapshot_sha256: []const u8,
    active_rules: PacketActiveRules,
    ontology_context_is_authority: bool = false,
    promotion_evidence_included: bool = false,
    generation_evidence: []const PacketEvidence,
    ontology_context: []const PacketOntology,
    held_out: struct {
        results_visible: bool = false,
        commitments: []const PacketHeldOut,
    },
};

pub const Projection = struct {
    arena: std.heap.ArenaAllocator,
    project_sha256: [64]u8,
    ontology_revision: [64]u8,
    ontology_snapshot_sha256: [64]u8,
    raw_snapshot_sha256: [64]u8,
    active_bundle_revision: u64,
    active_bundle_sha256: [64]u8,
    generation_evidence_sha256: [64]u8,
    held_out_commitments_sha256: [64]u8,
    packet: []const u8,
    packet_sha256: [64]u8,

    pub fn deinit(self: *Projection) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const PersistResult = struct {
    receipt_id: [64]u8,
    created: bool,
};

pub const Loaded = struct {
    receipt_id: [64]u8,
    projection: Projection,

    pub fn deinit(self: *Loaded) void {
        self.projection.deinit();
        self.* = undefined;
    }
};

pub const DerivedGenerationEvidence = struct {
    arena: std.heap.ArenaAllocator,
    value: GenerationEvidence,

    pub fn deinit(self: *DerivedGenerationEvidence) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

const ReceiptBody = struct {
    schema_version: []const u8 = RECEIPT_SCHEMA_VERSION,
    project_sha256: []const u8,
    ontology_revision: []const u8,
    ontology_snapshot_sha256: []const u8,
    raw_snapshot_sha256: []const u8,
    snapshot_file: []const u8,
    active_bundle_revision: u64,
    active_bundle_sha256: []const u8,
    generation_evidence_sha256: []const u8,
    held_out_commitments_sha256: []const u8,
    packet_sha256: []const u8,
};

const ReceiptRecord = struct {
    receipt_id: []const u8,
    body: ReceiptBody,
};

/// Construct generation evidence only from a reopened host receipt.  The
/// caller supplies no prose and therefore cannot launder an authenticated
/// identity into a different semantic claim.
pub fn deriveGenerationEvidence(
    allocator: std.mem.Allocator,
    session_dir: []const u8,
    project_sha256: [64]u8,
    receipt_id: [64]u8,
    kind: EvidenceKind,
    window_member_sha256: [64]u8,
) !DerivedGenerationEvidence {
    try requireNonzeroHex(project_sha256);
    try requireNonzeroHex(receipt_id);
    try requireNonzeroHex(window_member_sha256);
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    var summary: []u8 = undefined;
    var subject: [64]u8 = undefined;
    var interval: ?[64]u8 = null;
    switch (kind) {
        .user_correction, .runtime_counterexample => {
            var receipt = try source_receipt.loadBound(a, session_dir, receipt_id);
            defer receipt.deinit();
            const expected_kind: source_receipt.Kind = if (kind == .user_correction)
                .user_correction
            else
                .runtime_counterexample;
            if (receipt.kind != expected_kind or
                !std.mem.eql(u8, &receipt.project_sha256, &project_sha256))
                return error.GenerationEvidenceBindingMismatch;
            subject = receipt.subject_sha256;
            interval = receipt.observation_interval_sha256;
            summary = if (kind == .user_correction)
                try a.dupe(u8, receipt.subject_text orelse return error.SourceArtifactChanged)
            else
                try renderRuntimeCounterexampleSummary(a, session_dir, &receipt);
        },
        .rule_impact => {
            var authenticated = try impact_receipt.deriveImpact(a, session_dir, receipt_id);
            defer authenticated.deinit(a);
            if (!std.mem.eql(u8, &authenticated.project_sha256, &project_sha256))
                return error.GenerationEvidenceBindingMismatch;
            subject = authenticated.snapshot.source_interval_sha256;
            interval = authenticated.snapshot.source_interval_sha256;
            summary = try renderRuleImpactSummary(a, authenticated.snapshot);
        },
    }
    const summary_sha = observation.sha256Hex(summary);
    return .{
        .arena = arena,
        .value = .{
            .receipt_sha256 = try a.dupe(u8, receipt_id[0..]),
            .kind = kind,
            .subject_sha256 = try a.dupe(u8, subject[0..]),
            .interval_sha256 = if (interval) |value| try a.dupe(u8, value[0..]) else null,
            .window_member_sha256 = try a.dupe(u8, window_member_sha256[0..]),
            .summary = summary,
            .summary_sha256 = try a.dupe(u8, summary_sha[0..]),
        },
    };
}

pub fn renderSnapshot(allocator: std.mem.Allocator, input: SnapshotInput) !RenderedSnapshot {
    try requireNonzeroHex(input.project_sha256);
    try requireNonzeroHex(input.revision);
    try requireHex(input.active_bundle_sha256);
    const active = ActiveRules{
        .bundle_revision = input.active_bundle_revision,
        .bundle_sha256 = input.active_bundle_sha256[0..],
    };
    const body = SnapshotCommitmentBody{
        .schema_version = SNAPSHOT_SCHEMA_VERSION,
        .project_sha256 = input.project_sha256[0..],
        .project_key = input.project_key,
        .revision = input.revision[0..],
        .bounded = input.bounded,
        .truncated = input.truncated,
        .active_rules = active,
        .ontology = input.ontology,
        .generation_evidence = input.generation_evidence,
        .held_out_commitments = input.held_out_commitments,
    };
    const body_json = try std.json.Stringify.valueAlloc(allocator, body, .{});
    defer allocator.free(body_json);
    const snapshot_sha256 = observation.sha256Hex(body_json);
    const bytes = try std.json.Stringify.valueAlloc(allocator, RawSnapshot{
        .schema_version = body.schema_version,
        .project_sha256 = body.project_sha256,
        .project_key = body.project_key,
        .revision = body.revision,
        .snapshot_sha256 = snapshot_sha256[0..],
        .bounded = body.bounded,
        .truncated = body.truncated,
        .active_rules = body.active_rules,
        .ontology = body.ontology,
        .generation_evidence = body.generation_evidence,
        .held_out_commitments = body.held_out_commitments,
    }, .{});
    errdefer allocator.free(bytes);
    var validated = try project(
        allocator,
        bytes,
        input.project_sha256,
        input.revision,
        snapshot_sha256,
        input.active_bundle_revision,
        input.active_bundle_sha256,
    );
    validated.deinit();
    return .{ .bytes = bytes, .snapshot_sha256 = snapshot_sha256 };
}

/// Parse, validate, and project one exact TinyKG snapshot.  `expected_*`
/// values come from the host/store handshake and active rule loader, not from
/// the snapshot itself; all identity mismatches fail before provider access.
pub fn project(
    allocator: std.mem.Allocator,
    raw_snapshot: []const u8,
    expected_project_sha256: [64]u8,
    expected_revision: [64]u8,
    expected_snapshot_sha256: [64]u8,
    expected_active_bundle_revision: u64,
    expected_active_bundle_sha256: [64]u8,
) !Projection {
    if (raw_snapshot.len == 0 or raw_snapshot.len > MAX_SNAPSHOT_BYTES)
        return error.InvalidOntologySnapshot;
    try requireNonzeroHex(expected_project_sha256);
    try requireNonzeroHex(expected_revision);
    try requireNonzeroHex(expected_snapshot_sha256);
    try requireHex(expected_active_bundle_sha256);
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    const parsed = std.json.parseFromSliceLeaky(RawSnapshot, a, raw_snapshot, .{
        .ignore_unknown_fields = false,
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidOntologySnapshot,
    };
    const canonical_raw = try std.json.Stringify.valueAlloc(a, parsed, .{});
    if (!std.mem.eql(u8, canonical_raw, raw_snapshot))
        return error.NonCanonicalOntologySnapshot;
    if (!std.mem.eql(u8, parsed.schema_version, SNAPSHOT_SCHEMA_VERSION) or
        !parsed.bounded or parsed.truncated or
        !validText(parsed.project_key, MAX_PROJECT_KEY_BYTES) or
        parsed.ontology.len == 0 or
        parsed.generation_evidence.len == 0 or
        parsed.held_out_commitments.len == 0 or
        parsed.ontology.len > MAX_ONTOLOGY_ITEMS or
        parsed.generation_evidence.len > MAX_GENERATION_EVIDENCE or
        parsed.held_out_commitments.len > MAX_HELD_OUT_COMMITMENTS)
        return error.InvalidOntologySnapshot;

    const project_sha256 = parseHex(parsed.project_sha256) orelse
        return error.InvalidOntologySnapshot;
    const revision = parseHex(parsed.revision) orelse return error.InvalidOntologySnapshot;
    const declared_snapshot = parseHex(parsed.snapshot_sha256) orelse
        return error.InvalidOntologySnapshot;
    const active_bundle = parseHex(parsed.active_rules.bundle_sha256) orelse
        return error.InvalidOntologySnapshot;
    const commitment_json = try std.json.Stringify.valueAlloc(a, SnapshotCommitmentBody{
        .schema_version = parsed.schema_version,
        .project_sha256 = parsed.project_sha256,
        .project_key = parsed.project_key,
        .revision = parsed.revision,
        .bounded = parsed.bounded,
        .truncated = parsed.truncated,
        .active_rules = parsed.active_rules,
        .ontology = parsed.ontology,
        .generation_evidence = parsed.generation_evidence,
        .held_out_commitments = parsed.held_out_commitments,
    }, .{});
    const observed_commitment = observation.sha256Hex(commitment_json);
    if (!std.mem.eql(u8, &declared_snapshot, &observed_commitment) or
        !std.mem.eql(u8, &declared_snapshot, &expected_snapshot_sha256))
        return error.OntologySnapshotHashMismatch;
    if (!std.mem.eql(u8, &project_sha256, &expected_project_sha256) or
        !std.mem.eql(u8, &revision, &expected_revision) or
        !std.mem.eql(u8, &declared_snapshot, &expected_snapshot_sha256) or
        parsed.active_rules.bundle_revision != expected_active_bundle_revision or
        !std.mem.eql(u8, &active_bundle, &expected_active_bundle_sha256))
        return error.OntologySnapshotIdentityMismatch;
    if ((parsed.active_rules.bundle_revision == 0) !=
        std.mem.eql(u8, &active_bundle, &ZERO_SHA))
        return error.InvalidActiveRuleIdentity;

    const ontology_context = try a.alloc(PacketOntology, parsed.ontology.len);
    var seen_nodes = std.AutoHashMap(u64, void).init(a);
    var prior_node_id: u64 = 0;
    for (parsed.ontology, ontology_context) |item, *output| {
        if (item.node_id == 0 or seen_nodes.contains(item.node_id) or
            item.node_id <= prior_node_id or
            item.deprecated or item.retrieval_excluded or
            !validText(item.scope, MAX_SCOPE_BYTES) or
            !validText(item.summary, MAX_SUMMARY_BYTES) or
            !validText(item.falsifier, MAX_FALSIFIER_BYTES))
            return error.InvalidOntologyItem;
        try seen_nodes.put(item.node_id, {});
        prior_node_id = item.node_id;
        const summary_sha = parseHex(item.summary_sha256) orelse
            return error.InvalidOntologyItem;
        const provenance_sha = parseHex(item.provenance_sha256) orelse
            return error.InvalidOntologyItem;
        if (isZero(summary_sha) or isZero(provenance_sha) or
            !std.mem.eql(u8, &summary_sha, &observation.sha256Hex(item.summary)))
            return error.OntologyItemBindingMismatch;
        output.* = .{
            .node_id = item.node_id,
            .kind = item.kind,
            .scope = item.scope,
            .authority = item.authority,
            .summary = item.summary,
            .summary_sha256 = item.summary_sha256,
            .provenance_sha256 = item.provenance_sha256,
            .falsifier = item.falsifier,
            .contradicted = item.contradicted,
        };
    }

    const generation_evidence = try a.alloc(PacketEvidence, parsed.generation_evidence.len);
    var seen_generation = std.AutoHashMap([64]u8, void).init(a);
    var generation_identities = std.AutoHashMap([64]u8, void).init(a);
    var generation_members = std.AutoHashMap([64]u8, void).init(a);
    var prior_generation: ?[64]u8 = null;
    for (parsed.generation_evidence, generation_evidence) |item, *output| {
        const receipt = parseHex(item.receipt_sha256) orelse return error.InvalidGenerationEvidence;
        const subject = parseHex(item.subject_sha256) orelse return error.InvalidGenerationEvidence;
        const member = parseHex(item.window_member_sha256) orelse return error.InvalidGenerationEvidence;
        const summary_sha = parseHex(item.summary_sha256) orelse return error.InvalidGenerationEvidence;
        if (isZero(receipt) or isZero(subject) or isZero(member) or isZero(summary_sha) or
            seen_generation.contains(receipt) or
            (prior_generation != null and orderHex(prior_generation.?, receipt) != .lt) or
            generation_members.contains(member) or
            !validText(item.summary, MAX_SUMMARY_BYTES) or
            !std.mem.eql(u8, &summary_sha, &observation.sha256Hex(item.summary)))
            return error.InvalidGenerationEvidence;
        try seen_generation.put(receipt, {});
        prior_generation = receipt;
        try generation_identities.put(receipt, {});
        try generation_identities.put(subject, {});
        try generation_members.put(member, {});
        if (item.interval_sha256) |raw_interval| {
            const interval = parseHex(raw_interval) orelse return error.InvalidGenerationEvidence;
            if (isZero(interval)) return error.InvalidGenerationEvidence;
            try generation_identities.put(interval, {});
        }
        output.* = .{
            .receipt_sha256 = item.receipt_sha256,
            .kind = item.kind,
            .subject_sha256 = item.subject_sha256,
            .interval_sha256 = item.interval_sha256,
            .window_member_sha256 = item.window_member_sha256,
            .summary = item.summary,
            .summary_sha256 = item.summary_sha256,
        };
    }

    const held_out = try a.alloc(PacketHeldOut, parsed.held_out_commitments.len);
    var seen_held_out = std.AutoHashMap([64]u8, void).init(a);
    var seen_held_out_members = std.AutoHashMap([64]u8, void).init(a);
    var prior_held_out: ?[64]u8 = null;
    for (parsed.held_out_commitments, held_out) |item, *output| {
        const commitment = parseHex(item.commitment_sha256) orelse
            return error.InvalidHeldOutCommitment;
        const suite = parseHex(item.suite_sha256) orelse return error.InvalidHeldOutCommitment;
        if (isZero(commitment) or isZero(suite) or !item.sealed or item.case_count == 0 or
            item.case_count != item.member_sha256.len or
            seen_held_out.contains(commitment) or seen_held_out.contains(suite) or
            (prior_held_out != null and orderHex(prior_held_out.?, commitment) != .lt) or
            generation_identities.contains(commitment) or generation_identities.contains(suite))
            return error.EvidenceWindowOverlap;
        var held_members = std.AutoHashMap([64]u8, void).init(a);
        var prior_member: ?[64]u8 = null;
        for (item.member_sha256) |raw_member| {
            const member = parseHex(raw_member) orelse return error.InvalidHeldOutCommitment;
            if (isZero(member) or held_members.contains(member) or
                seen_held_out_members.contains(member) or
                generation_members.contains(member) or generation_identities.contains(member) or
                (prior_member != null and orderHex(prior_member.?, member) != .lt))
                return error.EvidenceWindowOverlap;
            try held_members.put(member, {});
            try seen_held_out_members.put(member, {});
            prior_member = member;
        }
        const held_out_commitment_json = try std.json.Stringify.valueAlloc(a, HeldOutCommitmentBody{
            .suite_sha256 = item.suite_sha256,
            .case_count = item.case_count,
            .member_sha256 = item.member_sha256,
        }, .{});
        if (!std.mem.eql(u8, &commitment, &observation.sha256Hex(held_out_commitment_json)))
            return error.HeldOutCommitmentBindingMismatch;
        try seen_held_out.put(commitment, {});
        try seen_held_out.put(suite, {});
        prior_held_out = commitment;
        output.* = .{
            .commitment_sha256 = item.commitment_sha256,
            .suite_sha256 = item.suite_sha256,
            .case_count = item.case_count,
            .member_sha256 = item.member_sha256,
        };
    }

    const generation_json = try std.json.Stringify.valueAlloc(a, generation_evidence, .{});
    const held_out_json = try std.json.Stringify.valueAlloc(a, held_out, .{});
    const generation_sha256 = observation.sha256Hex(generation_json);
    const held_out_sha256 = observation.sha256Hex(held_out_json);
    const packet = try std.json.Stringify.valueAlloc(a, WirePacket{
        .project_sha256 = parsed.project_sha256,
        .project_key = parsed.project_key,
        .ontology_revision = parsed.revision,
        .ontology_snapshot_sha256 = parsed.snapshot_sha256,
        .active_rules = .{
            .bundle_revision = parsed.active_rules.bundle_revision,
            .bundle_sha256 = parsed.active_rules.bundle_sha256,
        },
        .generation_evidence = generation_evidence,
        .ontology_context = ontology_context,
        .held_out = .{ .commitments = held_out },
    }, .{});
    if (packet.len == 0 or packet.len > MAX_PACKET_BYTES) return error.OntologyPacketTooLarge;
    return .{
        .arena = arena,
        .project_sha256 = project_sha256,
        .ontology_revision = revision,
        .ontology_snapshot_sha256 = declared_snapshot,
        .raw_snapshot_sha256 = observation.sha256Hex(raw_snapshot),
        .active_bundle_revision = parsed.active_rules.bundle_revision,
        .active_bundle_sha256 = active_bundle,
        .generation_evidence_sha256 = generation_sha256,
        .held_out_commitments_sha256 = held_out_sha256,
        .packet = packet,
        .packet_sha256 = observation.sha256Hex(packet),
    };
}

/// Persist the canonical sanitized snapshot and a content-addressed receipt.
/// Generation evidence is reopened here; projection alone is deliberately not
/// enough to authorize a provider call.
pub fn persist(
    allocator: std.mem.Allocator,
    session_dir: []const u8,
    raw_snapshot: []const u8,
    projection: *const Projection,
) !PersistResult {
    if (!std.mem.eql(u8, &projection.raw_snapshot_sha256, &observation.sha256Hex(raw_snapshot)))
        return error.ProjectionSnapshotMismatch;
    var reprojected = try project(
        allocator,
        raw_snapshot,
        projection.project_sha256,
        projection.ontology_revision,
        projection.ontology_snapshot_sha256,
        projection.active_bundle_revision,
        projection.active_bundle_sha256,
    );
    defer reprojected.deinit();
    if (!projectionEqual(projection, &reprojected))
        return error.ProjectionStateDrift;
    try validateGenerationEvidence(allocator, session_dir, raw_snapshot, projection.project_sha256);

    var snapshot_name_buffer: [128]u8 = undefined;
    const snapshot_name = try std.fmt.bufPrint(&snapshot_name_buffer, "{s}{s}.json", .{
        SNAPSHOT_FILE_PREFIX, projection.ontology_snapshot_sha256[0..],
    });
    _ = try persistExactFile(session_dir, snapshot_name, raw_snapshot, MAX_SNAPSHOT_BYTES);
    const body = ReceiptBody{
        .project_sha256 = projection.project_sha256[0..],
        .ontology_revision = projection.ontology_revision[0..],
        .ontology_snapshot_sha256 = projection.ontology_snapshot_sha256[0..],
        .raw_snapshot_sha256 = projection.raw_snapshot_sha256[0..],
        .snapshot_file = snapshot_name,
        .active_bundle_revision = projection.active_bundle_revision,
        .active_bundle_sha256 = projection.active_bundle_sha256[0..],
        .generation_evidence_sha256 = projection.generation_evidence_sha256[0..],
        .held_out_commitments_sha256 = projection.held_out_commitments_sha256[0..],
        .packet_sha256 = projection.packet_sha256[0..],
    };
    const body_json = try std.json.Stringify.valueAlloc(allocator, body, .{});
    defer allocator.free(body_json);
    const receipt_id = observation.sha256Hex(body_json);
    const record = try std.json.Stringify.valueAlloc(allocator, ReceiptRecord{
        .receipt_id = receipt_id[0..],
        .body = body,
    }, .{});
    defer allocator.free(record);
    if (record.len > MAX_RECEIPT_BYTES) return error.ProjectionReceiptTooLarge;
    var receipt_name_buffer: [128]u8 = undefined;
    const receipt_name = try std.fmt.bufPrint(&receipt_name_buffer, "{s}{s}.json", .{
        RECEIPT_FILE_PREFIX, receipt_id[0..],
    });
    const created = try persistExactFile(session_dir, receipt_name, record, MAX_RECEIPT_BYTES);
    return .{ .receipt_id = receipt_id, .created = created };
}

pub fn loadBound(
    allocator: std.mem.Allocator,
    session_dir: []const u8,
    receipt_id: [64]u8,
) !Loaded {
    try requireHex(receipt_id);
    var receipt_name_buffer: [128]u8 = undefined;
    const receipt_name = try std.fmt.bufPrint(&receipt_name_buffer, "{s}{s}.json", .{
        RECEIPT_FILE_PREFIX, receipt_id[0..],
    });
    const raw_receipt = try readExactFile(allocator, session_dir, receipt_name, MAX_RECEIPT_BYTES);
    defer allocator.free(raw_receipt);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const parsed = std.json.parseFromSliceLeaky(ReceiptRecord, arena.allocator(), raw_receipt, .{
        .ignore_unknown_fields = false,
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    }) catch return error.InvalidProjectionReceipt;
    const parsed_id = parseHex(parsed.receipt_id) orelse return error.InvalidProjectionReceipt;
    const project_id = parseHex(parsed.body.project_sha256) orelse return error.InvalidProjectionReceipt;
    const revision = parseHex(parsed.body.ontology_revision) orelse return error.InvalidProjectionReceipt;
    const snapshot_sha = parseHex(parsed.body.ontology_snapshot_sha256) orelse return error.InvalidProjectionReceipt;
    const raw_sha = parseHex(parsed.body.raw_snapshot_sha256) orelse return error.InvalidProjectionReceipt;
    const active_sha = parseHex(parsed.body.active_bundle_sha256) orelse return error.InvalidProjectionReceipt;
    const generation_sha = parseHex(parsed.body.generation_evidence_sha256) orelse return error.InvalidProjectionReceipt;
    const held_out_sha = parseHex(parsed.body.held_out_commitments_sha256) orelse return error.InvalidProjectionReceipt;
    const packet_sha = parseHex(parsed.body.packet_sha256) orelse return error.InvalidProjectionReceipt;
    if (!std.mem.eql(u8, parsed.body.schema_version, RECEIPT_SCHEMA_VERSION) or
        !std.mem.eql(u8, &parsed_id, &receipt_id) or
        !validFileName(parsed.body.snapshot_file))
        return error.InvalidProjectionReceipt;
    const body_json = try std.json.Stringify.valueAlloc(arena.allocator(), parsed.body, .{});
    if (!std.mem.eql(u8, &observation.sha256Hex(body_json), &receipt_id))
        return error.ProjectionReceiptHashMismatch;
    const raw_snapshot = try readExactFile(
        allocator,
        session_dir,
        parsed.body.snapshot_file,
        MAX_SNAPSHOT_BYTES,
    );
    defer allocator.free(raw_snapshot);
    if (!std.mem.eql(u8, &observation.sha256Hex(raw_snapshot), &raw_sha))
        return error.ProjectionSnapshotChanged;
    var projection = try project(
        allocator,
        raw_snapshot,
        project_id,
        revision,
        snapshot_sha,
        parsed.body.active_bundle_revision,
        active_sha,
    );
    errdefer projection.deinit();
    if (!std.mem.eql(u8, &projection.generation_evidence_sha256, &generation_sha) or
        !std.mem.eql(u8, &projection.held_out_commitments_sha256, &held_out_sha) or
        !std.mem.eql(u8, &projection.packet_sha256, &packet_sha))
        return error.ProjectionReceiptBindingMismatch;
    try validateGenerationEvidence(allocator, session_dir, raw_snapshot, project_id);
    return .{ .receipt_id = receipt_id, .projection = projection };
}

fn validateGenerationEvidence(
    allocator: std.mem.Allocator,
    session_dir: []const u8,
    raw_snapshot: []const u8,
    project_sha256: [64]u8,
) !void {
    var parsed = std.json.parseFromSlice(RawSnapshot, allocator, raw_snapshot, .{
        .ignore_unknown_fields = false,
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    }) catch return error.InvalidOntologySnapshot;
    defer parsed.deinit();
    for (parsed.value.generation_evidence) |item| {
        const receipt_id = parseHex(item.receipt_sha256) orelse return error.InvalidGenerationEvidence;
        const subject = parseHex(item.subject_sha256) orelse return error.InvalidGenerationEvidence;
        switch (item.kind) {
            .user_correction, .runtime_counterexample => {
                var receipt = try source_receipt.loadBound(allocator, session_dir, receipt_id);
                defer receipt.deinit();
                const expected_kind: source_receipt.Kind = if (item.kind == .user_correction)
                    .user_correction
                else
                    .runtime_counterexample;
                if (receipt.kind != expected_kind or
                    !std.mem.eql(u8, &receipt.project_sha256, &project_sha256) or
                    !std.mem.eql(u8, &receipt.subject_sha256, &subject))
                    return error.GenerationEvidenceBindingMismatch;
                if (item.kind == .user_correction) {
                    if (!std.mem.eql(u8, &observation.sha256Hex(item.summary), &subject))
                        return error.GenerationEvidenceSummaryMismatch;
                } else {
                    const expected_summary = try renderRuntimeCounterexampleSummary(
                        allocator,
                        session_dir,
                        &receipt,
                    );
                    defer allocator.free(expected_summary);
                    if (!std.mem.eql(u8, item.summary, expected_summary))
                        return error.GenerationEvidenceSummaryMismatch;
                }
                if (item.interval_sha256) |raw_interval| {
                    const interval = parseHex(raw_interval) orelse return error.InvalidGenerationEvidence;
                    if (receipt.observation_interval_sha256 == null or
                        !std.mem.eql(u8, &receipt.observation_interval_sha256.?, &interval))
                        return error.GenerationEvidenceBindingMismatch;
                } else if (receipt.observation_interval_sha256 != null) {
                    return error.GenerationEvidenceBindingMismatch;
                }
            },
            .rule_impact => {
                var authenticated = try impact_receipt.deriveImpact(allocator, session_dir, receipt_id);
                defer authenticated.deinit(allocator);
                const raw_interval = item.interval_sha256 orelse return error.InvalidGenerationEvidence;
                const interval = parseHex(raw_interval) orelse return error.InvalidGenerationEvidence;
                if (!std.mem.eql(u8, &authenticated.project_sha256, &project_sha256) or
                    !std.mem.eql(u8, &authenticated.snapshot.source_interval_sha256, &interval) or
                    !std.mem.eql(u8, &authenticated.snapshot.source_interval_sha256, &subject))
                    return error.GenerationEvidenceBindingMismatch;
                const expected_summary = try renderRuleImpactSummary(allocator, authenticated.snapshot);
                defer allocator.free(expected_summary);
                if (!std.mem.eql(u8, item.summary, expected_summary))
                    return error.GenerationEvidenceSummaryMismatch;
            },
        }
    }
}

fn projectionEqual(left: *const Projection, right: *const Projection) bool {
    return std.mem.eql(u8, &left.project_sha256, &right.project_sha256) and
        std.mem.eql(u8, &left.ontology_revision, &right.ontology_revision) and
        std.mem.eql(u8, &left.ontology_snapshot_sha256, &right.ontology_snapshot_sha256) and
        std.mem.eql(u8, &left.raw_snapshot_sha256, &right.raw_snapshot_sha256) and
        left.active_bundle_revision == right.active_bundle_revision and
        std.mem.eql(u8, &left.active_bundle_sha256, &right.active_bundle_sha256) and
        std.mem.eql(u8, &left.generation_evidence_sha256, &right.generation_evidence_sha256) and
        std.mem.eql(u8, &left.held_out_commitments_sha256, &right.held_out_commitments_sha256) and
        std.mem.eql(u8, left.packet, right.packet) and
        std.mem.eql(u8, &left.packet_sha256, &right.packet_sha256);
}

const RuntimeCounterexampleSummary = struct {
    schema_version: []const u8 = "metacodes-runtime-counterexample-generation-summary-v1",
    source_interval_sha256: []const u8,
    verdict_sha256: []const u8,
    checker_sha256: []const u8,
    phase: observation.FormalPhase,
    operation: observation.FormalOperation,
    candidate_id: []const u8,
    bundle_sha256: []const u8,
    bundle_revision: u64,
    result: observation.FormalResult,
    actuation: observation.FormalActuation,
};

fn renderRuntimeCounterexampleSummary(
    allocator: std.mem.Allocator,
    session_dir: []const u8,
    receipt: *const source_receipt.Loaded,
) ![]u8 {
    const binding = receipt.observation orelse return error.InvalidGenerationEvidence;
    const interval = receipt.observation_interval_sha256 orelse return error.InvalidGenerationEvidence;
    const checker = receipt.checker_sha256 orelse return error.InvalidGenerationEvidence;
    var run = try @import("tool_observation_journal.zig").loadRunDispatches(
        allocator,
        session_dir,
        binding,
    );
    defer run.deinit();
    if (!std.mem.eql(u8, &run.interval_sha256, &interval))
        return error.GenerationEvidenceBindingMismatch;
    var matched: ?@import("tool_observation_journal.zig").RunFormalDecision = null;
    for (run.formal_decisions) |formal| {
        if (formal.actuation == .enforced and formal.result == .block and
            formal.verdict_sha256 != null and
            std.mem.eql(u8, &formal.kernel_sha256, &checker) and
            std.mem.eql(u8, &formal.project_sha256, &receipt.project_sha256) and
            std.mem.eql(u8, &formal.verdict_sha256.?, &receipt.subject_sha256))
        {
            if (matched != null) return error.AmbiguousGenerationEvidence;
            matched = formal;
        }
    }
    const formal = matched orelse return error.GenerationEvidenceBindingMismatch;
    return std.json.Stringify.valueAlloc(allocator, RuntimeCounterexampleSummary{
        .source_interval_sha256 = interval[0..],
        .verdict_sha256 = receipt.subject_sha256[0..],
        .checker_sha256 = checker[0..],
        .phase = formal.phase,
        .operation = formal.operation,
        .candidate_id = formal.candidate_id[0..],
        .bundle_sha256 = formal.bundle_sha256[0..],
        .bundle_revision = formal.bundle_revision,
        .result = formal.result,
        .actuation = formal.actuation,
    }, .{});
}

pub fn renderRuleImpactSummary(
    allocator: std.mem.Allocator,
    snapshot: @import("rule_impact_stats.zig").Snapshot,
) ![]u8 {
    if (!snapshot.evidence.authenticated) return error.UnauthenticatedRuleImpact;
    return std.json.Stringify.valueAlloc(allocator, RuleImpactSummary{
        .source_interval_sha256 = snapshot.source_interval_sha256[0..],
        .formal_decisions = snapshot.formal_decisions,
        .formal_faults = snapshot.formal_faults,
        .authoritative_dispatches = snapshot.authoritative_dispatches,
        .authoritative_successes = snapshot.authoritative_successes,
        .authoritative_non_successes = snapshot.authoritative_non_successes,
        .invalid_effects = snapshot.invalid_effects,
        .reobservation_failures = snapshot.reobservation_failures,
        .enforced_pre_blocks_before_dispatch = snapshot.enforced_pre_blocks_before_dispatch,
        .task_success = snapshot.labels.task_success,
        .trustworthy_success = snapshot.labels.trustworthy_success,
        .drift_detected = snapshot.labels.drift_detected,
        .false_interventions = snapshot.labels.false_interventions,
        .regressions = snapshot.labels.regressions,
        .provider_requests = snapshot.labels.provider_requests,
        .metered_tokens = snapshot.labels.metered_tokens,
        .cost_microusd = snapshot.labels.cost_microusd,
        .wall_elapsed_ns = snapshot.labels.wall_elapsed_ns,
    }, .{});
}

fn persistExactFile(
    directory: []const u8,
    name: []const u8,
    bytes: []const u8,
    maximum: usize,
) !bool {
    if (!validFileName(name) or bytes.len == 0 or bytes.len > maximum) return error.InvalidArtifact;
    var path_buffer: [std.fs.max_path_bytes + 1]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buffer, "{s}/{s}", .{ directory, name });
    const fd = pfs.open(path.ptr, .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .EXCL = true,
        .NOFOLLOW = true,
    }, @as(std.c.mode_t, 0o600));
    if (fd >= 0) {
        var write_fd = fd;
        errdefer {
            if (write_fd >= 0) _ = pfs.close(write_fd);
        }
        try pfs.makeCloseOnExec(write_fd);
        try writeAll(write_fd, bytes);
        try pfs.fsyncChecked(write_fd);
        _ = pfs.close(write_fd);
        write_fd = -1;
        try fsyncDirectory(directory);
        return true;
    }
    const existing = try readExactFile(std.heap.c_allocator, directory, name, maximum);
    defer std.heap.c_allocator.free(existing);
    if (!std.mem.eql(u8, existing, bytes)) return error.ArtifactCollision;
    return false;
}

fn readExactFile(
    allocator: std.mem.Allocator,
    directory: []const u8,
    name: []const u8,
    maximum: usize,
) ![]u8 {
    if (!validFileName(name)) return error.InvalidArtifactName;
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ directory, name });
    defer allocator.free(path);
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const fd = pfs.open(path_z.ptr, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true }, 0);
    if (fd < 0) return error.ArtifactOpenFailed;
    defer _ = pfs.close(fd);
    const before = pfs.fileInfo(fd) catch return error.ArtifactStatFailed;
    if (!before.is_regular or before.link_count != 1 or before.size == 0 or before.size > maximum or
        (@import("builtin").os.tag != .windows and (before.mode & 0o077) != 0))
        return error.InvalidArtifactFile;
    const bytes = try allocator.alloc(u8, @intCast(before.size));
    errdefer allocator.free(bytes);
    var offset: usize = 0;
    while (offset < bytes.len) {
        const count = pfs.read(fd, bytes[offset..]);
        if (count <= 0) return error.ArtifactReadFailed;
        offset += @intCast(count);
    }
    const after = pfs.fileInfo(fd) catch return error.ArtifactStatFailed;
    if (!after.is_regular or after.link_count != 1 or after.size != before.size or
        after.device != before.device or after.inode != before.inode)
        return error.ArtifactChangedDuringRead;
    return bytes;
}

fn validFileName(name: []const u8) bool {
    return name.len > 0 and name.len <= 192 and
        std.fs.path.basename(name).len == name.len and
        !std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, "..") and
        std.mem.indexOfAny(u8, name, "/\\\x00") == null;
}

fn writeAll(fd: pfs.Fd, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const count = pfs.write(fd, bytes[offset..]);
        if (count <= 0) return error.ArtifactWriteFailed;
        offset += @intCast(count);
    }
}

fn fsyncDirectory(directory: []const u8) !void {
    if (@import("builtin").os.tag == .windows) return;
    const path = try std.heap.c_allocator.dupeZ(u8, directory);
    defer std.heap.c_allocator.free(path);
    const fd = pfs.open(path.ptr, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true }, 0);
    if (fd < 0) return error.DirectoryOpenFailed;
    defer _ = pfs.close(fd);
    try pfs.fsyncChecked(fd);
}

fn requireHex(value: [64]u8) !void {
    if (parseHex(value[0..]) == null) return error.InvalidExpectedIdentity;
}

fn requireNonzeroHex(value: [64]u8) !void {
    try requireHex(value);
    if (isZero(value)) return error.InvalidExpectedIdentity;
}

fn orderHex(left: [64]u8, right: [64]u8) std.math.Order {
    return std.mem.order(u8, &left, &right);
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
    return std.mem.eql(u8, &value, &ZERO_SHA);
}

fn validText(value: []const u8, maximum: usize) bool {
    return value.len > 0 and value.len <= maximum and
        std.unicode.utf8ValidateSlice(value) and
        std.mem.trim(u8, value, " \t\r\n").len > 0;
}
