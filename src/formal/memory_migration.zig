//! Host-side protocol for the first mutating formal-governance primitive.
//!
//! `memory_supersede_existing` never deletes data.  It proposes one
//! `deprecated_by(source,replacement)` edge plus retrieval exclusion of the
//! source.  Lean derives preservation/reversibility from the observed node
//! records and fixed operation semantics; Zig does not submit `preserves_*`
//! conclusions.  This module intentionally stops before mutation: a commit is
//! authorized only after a fresh matching revision and a TinyKG CAS primitive.
//! The required TinyKG commit envelope is `tinykg-memory-migration-commit-v1`:
//! it must bind expected revision, proposal SHA-256, checker verdict SHA-256,
//! and the fixed effect; its receipt must include pre/post revisions plus an
//! idempotent rollback token.  No sequence of ordinary add-edge/set-property
//! calls is an acceptable substitute for that single-lock transaction.

const std = @import("std");
const runtime = @import("runtime.zig");
const provenance_mod = @import("provenance.zig");
const artifact_store = @import("artifact_store.zig");
const time = @import("../util/time.zig");
const AbortSignal = @import("../util/abort.zig").AbortSignal;

pub const SNAPSHOT_SCHEMA = "tinykg-memory-migration-snapshot-v1";
pub const TINYKG_COMMIT_SCHEMA = "tinykg-memory-migration-commit-v1";
pub const TINYKG_RECEIPT_SCHEMA = "tinykg-memory-migration-receipt-v1";
pub const PROPOSAL_SCHEMA = "metacodes-memory-migration-proposal-v1";
pub const OPERATION = "memory_supersede_existing";
pub const EFFECT = "add_deprecated_by_and_exclude_source";
pub const ROLLBACK = "remove_deprecated_by_and_restore_source";
pub const RECEIPT_SCHEMA = "metacodes-memory-migration-receipt-v1";
const MAX_INPUT_BYTES: usize = 64 * 1024;

pub const NodeView = struct {
    id: u64,
    kind: []const u8,
    schema_type: []const u8,
    current_generation: bool,
    retrieval_excluded: bool,
    contradicted: bool,
};

pub const Snapshot = struct {
    revision: [64]u8,
    bounded: bool,
    truncated: bool,
    source: NodeView,
    replacement: NodeView,
    evidence: NodeView,
    deprecated_edge_exists: bool,
};

pub const Proposal = struct {
    source_id: u64,
    replacement_id: u64,
    evidence_id: u64,
    effect: []const u8,
    rollback: []const u8,
    snapshot_revision: [64]u8,
};

pub const CommitGate = enum {
    ready_for_cas,
    checker_blocked,
    provenance_invalid,
    stale_revision,
    snapshot_drift,
    cas_unavailable,
};

pub const Evaluation = struct {
    allocator: std.mem.Allocator,
    canonical_snapshot: []u8,
    canonical_proposal: []u8,
    request: []u8,
    snapshot_revision: [64]u8,
    snapshot_sha256: [64]u8,
    proposal_sha256: [64]u8,
    request_id: [64]u8,
    invocation: runtime.Invocation,
    provenance: ?provenance_mod.Loaded = null,

    pub fn deinit(self: *Evaluation) void {
        if (self.provenance) |*loaded| loaded.deinit();
        self.invocation.deinit(self.allocator);
        self.allocator.free(self.canonical_snapshot);
        self.allocator.free(self.canonical_proposal);
        self.allocator.free(self.request);
        self.* = undefined;
    }

    pub fn checkerAdmitted(self: *const Evaluation) bool {
        return self.provenance != null and self.invocation.checkerAdmitted();
    }

    /// Admission is necessary but insufficient: the actuator must reobserve
    /// exactly this revision and use one atomic compare-and-swap mutation.
    pub fn commitGate(
        self: *const Evaluation,
        reobserved_revision: []const u8,
        cas_available: bool,
    ) CommitGate {
        if (self.invocation.failure != .none or !self.invocation.checkerAdmitted())
            return .checker_blocked;
        if (self.provenance == null) return .provenance_invalid;
        if (!std.mem.eql(u8, reobserved_revision, self.snapshot_revision[0..]))
            return .stale_revision;
        if (!cas_available) return .cas_unavailable;
        return .ready_for_cas;
    }

    /// Reopen the complete TinyKG snapshot immediately before commit.  A
    /// revision-only comparison is insufficient evidence when a broken or
    /// incompatible sensor could reuse a revision for different node facts.
    /// The actuator therefore requires both the semantic revision and the
    /// canonical snapshot hash to match the exact input checked by Lean.
    pub fn commitGateSnapshot(
        self: *const Evaluation,
        allocator: std.mem.Allocator,
        encoded_snapshot: []const u8,
        cas_available: bool,
    ) !CommitGate {
        if (self.invocation.failure != .none or !self.invocation.checkerAdmitted())
            return .checker_blocked;
        if (self.provenance == null) return .provenance_invalid;
        const canonical = try canonicalizeSnapshot(allocator, encoded_snapshot);
        defer allocator.free(canonical);
        var parsed = try parseSnapshot(allocator, canonical);
        defer parsed.deinit();
        if (!std.mem.eql(u8, parsed.value.revision[0..], self.snapshot_revision[0..]))
            return .stale_revision;
        const observed_hash = sha256Hex(canonical);
        if (!std.mem.eql(u8, observed_hash[0..], self.snapshot_sha256[0..]))
            return .snapshot_drift;
        if (!cas_available) return .cas_unavailable;
        return .ready_for_cas;
    }
};

pub const PersistedEvidence = struct {
    allocator: std.mem.Allocator,
    event_id: [64]u8,
    receipt: []u8,
    manifest_sha256: [64]u8,
    index_persisted: bool,

    pub fn deinit(self: *PersistedEvidence) void {
        self.allocator.free(self.receipt);
        self.* = undefined;
    }
};

const RawSnapshot = struct {
    schema_version: []const u8,
    revision: []const u8,
    bounded: bool,
    truncated: bool,
    source: NodeView,
    replacement: NodeView,
    evidence: NodeView,
    deprecated_edge_exists: bool,
};

const RawProposal = struct {
    schema_version: []const u8,
    operation: []const u8,
    source_id: u64,
    replacement_id: u64,
    evidence_id: u64,
    effect: []const u8,
    rollback: []const u8,
    snapshot_revision: []const u8,
};

const ParsedSnapshot = std.json.Parsed(Snapshot);

fn parseSnapshot(allocator: std.mem.Allocator, encoded: []const u8) !ParsedSnapshot {
    if (encoded.len == 0 or encoded.len > MAX_INPUT_BYTES) return error.InvalidSnapshot;
    var parsed = std.json.parseFromSlice(RawSnapshot, allocator, encoded, .{
        .ignore_unknown_fields = false,
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidSnapshot,
    };
    errdefer parsed.deinit();
    const validated = try validateSnapshot(parsed.value);
    // Snapshot borrows the strings owned by `parsed`; transfer the arena while
    // changing only the statically known value type.
    return .{ .arena = parsed.arena, .value = validated };
}

/// Strictly validate and render the TinyKG sensor response.  This is shared by
/// the first observation and the pre-commit re-observation so callers cannot
/// accidentally compare raw JSON formatting instead of semantic bytes.
pub fn canonicalizeSnapshot(allocator: std.mem.Allocator, encoded: []const u8) ![]u8 {
    var parsed = try parseSnapshot(allocator, encoded);
    defer parsed.deinit();
    return renderSnapshot(allocator, parsed.value);
}

/// The model chooses the three role ids presented to the TinyKG snapshot
/// primitive.  The host then constructs the only supported mutation shape;
/// the model never supplies effect, rollback, or revision strings.
pub fn buildProposalForSnapshot(allocator: std.mem.Allocator, encoded_snapshot: []const u8) ![]u8 {
    var parsed = try parseSnapshot(allocator, encoded_snapshot);
    defer parsed.deinit();
    return renderProposal(allocator, .{
        .source_id = parsed.value.source.id,
        .replacement_id = parsed.value.replacement.id,
        .evidence_id = parsed.value.evidence.id,
        .effect = EFFECT,
        .rollback = ROLLBACK,
        .snapshot_revision = parsed.value.revision,
    });
}

pub fn payloadSha256(payload: []const u8) [64]u8 {
    return sha256Hex(payload);
}

pub fn evaluate(
    allocator: std.mem.Allocator,
    encoded_snapshot: []const u8,
    encoded_proposal: []const u8,
    config: runtime.Config,
    abort: ?*const AbortSignal,
) !Evaluation {
    if (encoded_snapshot.len == 0 or encoded_snapshot.len > MAX_INPUT_BYTES)
        return error.InvalidSnapshot;
    if (encoded_proposal.len == 0 or encoded_proposal.len > MAX_INPUT_BYTES)
        return error.InvalidProposal;

    var parsed_snapshot = try parseSnapshot(allocator, encoded_snapshot);
    defer parsed_snapshot.deinit();
    const snapshot = parsed_snapshot.value;

    var parsed_proposal = std.json.parseFromSlice(RawProposal, allocator, encoded_proposal, .{
        .ignore_unknown_fields = false,
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidProposal,
    };
    defer parsed_proposal.deinit();
    const proposal = try validateProposal(parsed_proposal.value);

    const canonical_snapshot = try renderSnapshot(allocator, snapshot);
    errdefer allocator.free(canonical_snapshot);
    const canonical_proposal = try renderProposal(allocator, proposal);
    errdefer allocator.free(canonical_proposal);
    const snapshot_sha256 = sha256Hex(canonical_snapshot);
    const proposal_sha256 = sha256Hex(canonical_proposal);
    const request_id = requestId(proposal_sha256, snapshot_sha256, snapshot.revision);
    const request = try renderRequest(
        allocator,
        snapshot,
        proposal,
        request_id,
        snapshot_sha256,
        proposal_sha256,
    );
    errdefer allocator.free(request);

    var invocation = try runtime.invoke(allocator, config, request, .{
        .operation = OPERATION,
        .request_id = request_id,
        .proposal_sha256 = proposal_sha256,
        .snapshot_sha256 = snapshot_sha256,
        .snapshot_revision = snapshot.revision,
    }, abort);
    errdefer invocation.deinit(allocator);

    var loaded: ?provenance_mod.Loaded = null;
    if (invocation.failure == .none) {
        loaded = provenance_mod.loadAdjacent(
            allocator,
            config.checker_path,
            invocation.actual_checker_sha256,
            invocation.checker_bytes,
        ) catch null;
    }
    return .{
        .allocator = allocator,
        .canonical_snapshot = canonical_snapshot,
        .canonical_proposal = canonical_proposal,
        .request = request,
        .snapshot_revision = snapshot.revision,
        .snapshot_sha256 = snapshot_sha256,
        .proposal_sha256 = proposal_sha256,
        .request_id = request_id,
        .invocation = invocation,
        .provenance = loaded,
    };
}

/// Freeze one pre-commit mechanism event.  The immutable manifest is the
/// completion marker; this receipt deliberately says that reobserve/CAS/
/// commit/rollback were not performed by this pre-commit checker.
pub fn persistMechanismEvidence(
    allocator: std.mem.Allocator,
    index_path: []const u8,
    evaluation: *const Evaluation,
    started_wall_ns: i128,
    started_monotonic_ns: i128,
) !PersistedEvidence {
    const event_id = artifact_store.newEventId(
        started_wall_ns,
        started_monotonic_ns,
        evaluation.request_id[0..],
    );
    const receipt = try renderReceipt(allocator, event_id, evaluation, started_wall_ns);
    errdefer allocator.free(receipt);
    const persisted = try artifact_store.persist(
        allocator,
        index_path,
        event_id,
        receipt,
        .{
            .snapshot = evaluation.canonical_snapshot,
            .proposal = evaluation.canonical_proposal,
            .request = evaluation.request,
            .verdict = evaluation.invocation.verdict_payload,
            .checker_stdout = evaluation.invocation.stdout,
            .checker_stderr = evaluation.invocation.stderr,
            .checker_provenance = if (evaluation.provenance) |loaded| loaded.raw else null,
            .checker_build_receipt = if (evaluation.provenance) |loaded| loaded.build_receipt_raw else null,
        },
        .{
            .started_wall_ns = started_wall_ns,
            .request_id = evaluation.request_id[0..],
            .snapshot_revision = evaluation.snapshot_revision[0..],
            .pipeline_admitted = evaluation.checkerAdmitted(),
            .failure_kind = @tagName(evaluation.invocation.failure),
        },
    );
    return .{
        .allocator = allocator,
        .event_id = event_id,
        .receipt = receipt,
        .manifest_sha256 = persisted.manifest_sha256,
        .index_persisted = persisted.index_persisted,
    };
}

fn renderReceipt(
    allocator: std.mem.Allocator,
    event_id: [64]u8,
    evaluation: *const Evaluation,
    started_wall_ns: i128,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const writer = &out.writer;
    try writer.print(
        "{{\"schema_version\":\"{s}\",\"evidence_layer\":\"mechanism\",\"stage\":\"engineering_validation\",\"statistical_claim\":\"none\",\"operation\":\"{s}\",\"event_id\":\"{s}\",\"started_wall_ns\":{d},\"finished_wall_ns\":{d},\"identity\":{{\"request_id\":\"{s}\",\"proposal_sha256\":\"{s}\",\"snapshot_sha256\":\"{s}\",\"snapshot_revision\":\"{s}\"}},",
        .{ RECEIPT_SCHEMA, OPERATION, event_id[0..], started_wall_ns, time.nowWallNs(), evaluation.request_id[0..], evaluation.proposal_sha256[0..], evaluation.snapshot_sha256[0..], evaluation.snapshot_revision[0..] },
    );
    try writer.print(
        "\"checker\":{{\"version\":\"{s}\",\"runtime_failure_kind\":\"{s}\",\"admitted\":{s},\"provenance_valid\":{s},\"checker_elapsed_ns\":{d},\"hash_elapsed_ns\":{d},\"post_hash_elapsed_ns\":{d},\"input_bytes\":{d},\"stdout_bytes\":{d},\"stderr_bytes\":{d},\"reason_codes\":[",
        .{ runtime.CHECKER_VERSION, @tagName(evaluation.invocation.failure), boolText(evaluation.invocation.checkerAdmitted()), boolText(evaluation.provenance != null), evaluation.invocation.checker_elapsed_ns, evaluation.invocation.hash_elapsed_ns, evaluation.invocation.post_hash_elapsed_ns, evaluation.invocation.input_bytes, evaluation.invocation.stdout_bytes, evaluation.invocation.stderr_bytes },
    );
    if (evaluation.invocation.verdict) |verdict| {
        for (verdict.reasons, 0..) |reason, index| {
            if (index != 0) try writer.writeAll(",");
            try writer.print("\"{s}\"", .{@tagName(reason)});
        }
    }
    try writer.writeAll("]},");
    try writer.writeAll(
        "\"transaction\":{\"proposal\":\"bound\",\"reobserve\":\"not_performed_precommit_only\",\"cas\":\"not_performed_precommit_only\",\"commit\":\"not_performed_precommit_only\",\"rollback\":\"not_performed_precommit_only\"}," ++
            "\"artifact_bundle\":{\"schema_version\":\"metacodes-formal-artifact-bundle-v1\",\"completion_rule\":\"manifest_hash_validation\"}," ++
            "\"measurement_layers\":{\"mechanism\":\"recorded\",\"outcome\":\"not_measured\",\"trajectory\":\"not_measured\"}," ++
            "\"checker_llm_usage\":{\"input_tokens\":0,\"output_tokens\":0,\"cost_usd\":0}," ++
            "\"paid_experiment_cost_usd\":0}",
    );
    return out.toOwnedSlice();
}

fn validateSnapshot(raw: RawSnapshot) !Snapshot {
    if (!std.mem.eql(u8, raw.schema_version, SNAPSHOT_SCHEMA)) return error.InvalidSnapshot;
    const revision = parseLowerHex64(raw.revision) orelse return error.InvalidSnapshot;
    try validateNode(raw.source);
    try validateNode(raw.replacement);
    try validateNode(raw.evidence);
    return .{
        .revision = revision,
        .bounded = raw.bounded,
        .truncated = raw.truncated,
        .source = raw.source,
        .replacement = raw.replacement,
        .evidence = raw.evidence,
        .deprecated_edge_exists = raw.deprecated_edge_exists,
    };
}

fn validateProposal(raw: RawProposal) !Proposal {
    if (!std.mem.eql(u8, raw.schema_version, PROPOSAL_SCHEMA) or
        !std.mem.eql(u8, raw.operation, OPERATION) or
        raw.source_id == 0 or raw.replacement_id == 0 or raw.evidence_id == 0 or
        !validToken(raw.effect, 64) or !validToken(raw.rollback, 64))
        return error.InvalidProposal;
    return .{
        .source_id = raw.source_id,
        .replacement_id = raw.replacement_id,
        .evidence_id = raw.evidence_id,
        .effect = raw.effect,
        .rollback = raw.rollback,
        .snapshot_revision = parseLowerHex64(raw.snapshot_revision) orelse return error.InvalidProposal,
    };
}

fn validateNode(node: NodeView) !void {
    if (node.id == 0 or !validKind(node.kind) or !validToken(node.schema_type, 64))
        return error.InvalidSnapshot;
}

fn validKind(kind: []const u8) bool {
    const allowed = [_][]const u8{
        "observation",  "decision", "user_preference", "concept", "document",
        "verification", "task",     "project",
    };
    for (allowed) |candidate| if (std.mem.eql(u8, kind, candidate)) return true;
    return false;
}

fn validToken(value: []const u8, max: usize) bool {
    if (value.len == 0 or value.len > max) return false;
    for (value) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-' and
            byte != ':' and byte != '.') return false;
    }
    return true;
}

fn renderSnapshot(allocator: std.mem.Allocator, snapshot: Snapshot) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const writer = &out.writer;
    try writer.print(
        "{{\"schema_version\":\"{s}\",\"revision\":\"{s}\",\"bounded\":{s},\"truncated\":{s},\"source\":",
        .{ SNAPSHOT_SCHEMA, snapshot.revision[0..], boolText(snapshot.bounded), boolText(snapshot.truncated) },
    );
    try writeNode(writer, snapshot.source);
    try writer.writeAll(",\"replacement\":");
    try writeNode(writer, snapshot.replacement);
    try writer.writeAll(",\"evidence\":");
    try writeNode(writer, snapshot.evidence);
    try writer.print(",\"deprecated_edge_exists\":{s}}}", .{boolText(snapshot.deprecated_edge_exists)});
    return out.toOwnedSlice();
}

fn renderProposal(allocator: std.mem.Allocator, proposal: Proposal) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"schema_version\":\"{s}\",\"operation\":\"{s}\",\"source_id\":{d},\"replacement_id\":{d},\"evidence_id\":{d},\"effect\":\"{s}\",\"rollback\":\"{s}\",\"snapshot_revision\":\"{s}\"}}",
        .{ PROPOSAL_SCHEMA, OPERATION, proposal.source_id, proposal.replacement_id, proposal.evidence_id, proposal.effect, proposal.rollback, proposal.snapshot_revision[0..] },
    );
}

fn renderRequest(
    allocator: std.mem.Allocator,
    snapshot: Snapshot,
    proposal: Proposal,
    request_id: [64]u8,
    snapshot_sha256: [64]u8,
    proposal_sha256: [64]u8,
) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const writer = &out.writer;
    try writer.print(
        "{{\"schema_version\":\"{s}\",\"request_id\":\"{s}\",\"operation\":\"{s}\",\"proposal_sha256\":\"{s}\",\"snapshot_sha256\":\"{s}\",\"snapshot_revision\":\"{s}\",\"expected_checker_version\":\"{s}\",\"snapshot\":{{\"bounded\":{s},\"truncated\":{s},\"source\":",
        .{ runtime.MEMORY_REQUEST_SCHEMA, request_id[0..], OPERATION, proposal_sha256[0..], snapshot_sha256[0..], snapshot.revision[0..], runtime.CHECKER_VERSION, boolText(snapshot.bounded), boolText(snapshot.truncated) },
    );
    try writeNode(writer, snapshot.source);
    try writer.writeAll(",\"replacement\":");
    try writeNode(writer, snapshot.replacement);
    try writer.writeAll(",\"evidence\":");
    try writeNode(writer, snapshot.evidence);
    try writer.print(",\"deprecated_edge_exists\":{s}}},\"proposal\":{{\"source_id\":{d},\"replacement_id\":{d},\"evidence_id\":{d},\"effect\":\"{s}\",\"rollback\":\"{s}\",\"snapshot_revision\":\"{s}\"}}}}", .{ boolText(snapshot.deprecated_edge_exists), proposal.source_id, proposal.replacement_id, proposal.evidence_id, proposal.effect, proposal.rollback, proposal.snapshot_revision[0..] });
    return out.toOwnedSlice();
}

fn writeNode(writer: *std.Io.Writer, node: NodeView) !void {
    try writer.print(
        "{{\"id\":{d},\"kind\":\"{s}\",\"schema_type\":\"{s}\",\"current_generation\":{s},\"retrieval_excluded\":{s},\"contradicted\":{s}}}",
        .{ node.id, node.kind, node.schema_type, boolText(node.current_generation), boolText(node.retrieval_excluded), boolText(node.contradicted) },
    );
}

fn parseLowerHex64(raw: []const u8) ?[64]u8 {
    if (raw.len != 64) return null;
    var result: [64]u8 = undefined;
    for (raw, 0..) |byte, index| {
        if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return null;
        result[index] = byte;
    }
    return result;
}

fn sha256Hex(bytes: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

fn requestId(proposal_sha256: [64]u8, snapshot_sha256: [64]u8, revision: [64]u8) [64]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("metacodes-memory-migration-request-id-v1\x00");
    hash.update(&proposal_sha256);
    hash.update(&snapshot_sha256);
    hash.update(&revision);
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

fn boolText(value: bool) []const u8 {
    return if (value) "true" else "false";
}

const fixture_snapshot =
    \\{"schema_version":"tinykg-memory-migration-snapshot-v1","revision":"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd","bounded":true,"truncated":false,"source":{"id":1,"kind":"observation","schema_type":"lesson","current_generation":true,"retrieval_excluded":false,"contradicted":false},"replacement":{"id":2,"kind":"observation","schema_type":"lesson","current_generation":true,"retrieval_excluded":false,"contradicted":false},"evidence":{"id":3,"kind":"verification","schema_type":"verification","current_generation":true,"retrieval_excluded":false,"contradicted":false},"deprecated_edge_exists":false}
;

const fixture_proposal =
    \\{"schema_version":"metacodes-memory-migration-proposal-v1","operation":"memory_supersede_existing","source_id":1,"replacement_id":2,"evidence_id":3,"effect":"add_deprecated_by_and_exclude_source","rollback":"remove_deprecated_by_and_restore_source","snapshot_revision":"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"}
;

test "memory migration protocol canonicalizes observed nodes without preservation booleans" {
    var parsed_snapshot = try std.json.parseFromSlice(RawSnapshot, std.testing.allocator, fixture_snapshot, .{});
    defer parsed_snapshot.deinit();
    const snapshot = try validateSnapshot(parsed_snapshot.value);
    const canonical = try renderSnapshot(std.testing.allocator, snapshot);
    defer std.testing.allocator.free(canonical);
    try std.testing.expect(std.mem.indexOf(u8, canonical, "preserves_tasks") == null);
    try std.testing.expect(std.mem.indexOf(u8, canonical, "\"source\":") != null);

    var parsed_proposal = try std.json.parseFromSlice(RawProposal, std.testing.allocator, fixture_proposal, .{});
    defer parsed_proposal.deinit();
    const proposal = try validateProposal(parsed_proposal.value);
    const request = try renderRequest(
        std.testing.allocator,
        snapshot,
        proposal,
        ("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa").*,
        ("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb").*,
        ("cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc").*,
    );
    defer std.testing.allocator.free(request);
    try std.testing.expect(std.mem.indexOf(u8, request, "preserves_evidence") == null);
    try std.testing.expect(std.mem.indexOf(u8, request, runtime.MEMORY_REQUEST_SCHEMA) != null);
}
