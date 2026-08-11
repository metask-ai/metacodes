//! Host boundary for artifact verification and targeted repair governance.
//!
//! The external verifier owns semantic judgement. Lean only decides whether a
//! lifecycle transition is structurally and transactionally admissible. Zig
//! canonicalizes the observed state/proposal, invokes the hash-pinned kernel,
//! persists the exact evidence, then requires a fresh artifact observation
//! before a state CAS. This module deliberately does not call a provider or
//! mutate an artifact: provider durability and source-CAS execution require
//! separate native evidence on the real runner path.

const std = @import("std");
const builtin = @import("builtin");
const pfs = @import("platform").fs;
const runtime = @import("runtime.zig");
const provenance_mod = @import("provenance.zig");
const artifact_store = @import("artifact_store.zig");
const time = @import("../util/time.zig");
const AbortSignal = @import("../util/abort.zig").AbortSignal;

pub const SNAPSHOT_SCHEMA = "metacodes-artifact-state-snapshot-v1";
pub const PROPOSAL_SCHEMA = "metacodes-artifact-transition-proposal-v1";
pub const RECEIPT_SCHEMA = "metacodes-artifact-transition-receipt-v1";
pub const OPERATION = "artifact_transition";
const MAX_INPUT_BYTES: usize = 64 * 1024;
pub const MAX_ARTIFACT_BYTES: u64 = 64 * 1024 * 1024;

pub const Phase = enum {
    candidate,
    verification_requested,
    verified,
    defect_found,
    repair_authorized,
    repaired,
    failed,
};

pub const Event = enum {
    request_verification,
    mark_verified,
    report_defect,
    authorize_repair,
    record_repair,
    abandon,
};

pub const State = struct {
    phase: Phase,
    task_sha256: [64]u8,
    actor_run_sha256: [64]u8,
    artifact_sha256: [64]u8,
    artifact_revision: [64]u8,
    verifier_sha256: [64]u8,
    policy_sha256: [64]u8,
    budget_authority_sha256: [64]u8,
    active_provider_authorization_sha256: [64]u8,
    transition_revision: u64,
    repair_attempts: u32,
    max_repair_attempts: u32,
    semantic_verdict_sha256: [64]u8,
    defect_sha256: [64]u8,
    repair_proposal_sha256: [64]u8,
};

pub const Snapshot = struct {
    revision: [64]u8,
    state: State,
};

pub const Proposal = struct {
    event: Event,
    expected_phase: Phase,
    expected_next_phase: Phase,
    expected_snapshot_revision: [64]u8,
    next_snapshot_revision: [64]u8,
    provider_authorization_sha256: [64]u8,
    semantic_verdict_sha256: [64]u8,
    defect_sha256: [64]u8,
    repair_proposal_sha256: [64]u8,
    next_artifact_sha256: [64]u8,
    next_artifact_revision: [64]u8,
};

pub const StateCommitGate = enum {
    ready_for_state_cas,
    checker_blocked,
    provenance_invalid,
    stale_snapshot_revision,
    artifact_drift,
    cas_unavailable,
};

pub const Evaluation = struct {
    allocator: std.mem.Allocator,
    snapshot: Snapshot,
    proposal: Proposal,
    canonical_snapshot: []u8,
    canonical_proposal: []u8,
    request: []u8,
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

    /// A Lean verdict authorizes only the state transition. The host must
    /// reobserve the real artifact and exact state revision before CAS.
    pub fn stateCommitGate(
        self: *const Evaluation,
        reobserved_snapshot_revision: []const u8,
        reobserved_artifact_sha256: []const u8,
        reobserved_artifact_revision: []const u8,
        cas_available: bool,
    ) StateCommitGate {
        if (self.invocation.failure != .none or !self.invocation.checkerAdmitted())
            return .checker_blocked;
        if (self.provenance == null) return .provenance_invalid;
        if (!std.mem.eql(u8, reobserved_snapshot_revision, self.snapshot.revision[0..]))
            return .stale_snapshot_revision;
        if (!std.mem.eql(u8, reobserved_artifact_sha256, self.snapshot.state.artifact_sha256[0..]) or
            !std.mem.eql(u8, reobserved_artifact_revision, self.snapshot.state.artifact_revision[0..]))
            return .artifact_drift;
        if (!cas_available) return .cas_unavailable;
        return .ready_for_state_cas;
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

pub const ArtifactObservation = struct {
    sha256: [64]u8,
    bytes: u64,
};

/// Observe one authoritative artifact without exposing its bytes. Two complete
/// reads from the same no-follow descriptor must agree, so an ordinary
/// concurrent in-place rewrite fails closed instead of producing a torn hash.
/// Parent-component swaps remain the workspace sandbox's responsibility.
pub fn observeRegularArtifact(
    allocator: std.mem.Allocator,
    path: []const u8,
    max_bytes: u64,
) !ArtifactObservation {
    if (!std.fs.path.isAbsolute(path) or path.len == 0 or
        max_bytes == 0 or max_bytes > MAX_ARTIFACT_BYTES)
        return error.InvalidArtifactPath;
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const fd = pfs.open(path_z.ptr, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true }, 0);
    if (fd < 0) return error.ArtifactOpenFailed;
    defer _ = pfs.close(fd);
    try pfs.makeCloseOnExec(fd);
    const before = try pfs.fileInfo(fd);
    if (!before.is_regular or before.link_count != 1 or before.size > max_bytes)
        return error.ArtifactUnsafe;
    const first = try hashOpenArtifact(fd, before.size, max_bytes);
    const middle = try pfs.fileInfo(fd);
    if (!middle.is_regular or middle.link_count != 1 or middle.size != before.size)
        return error.ArtifactChangedDuringRead;
    const second = try hashOpenArtifact(fd, middle.size, max_bytes);
    const after = try pfs.fileInfo(fd);
    if (!after.is_regular or after.link_count != 1 or after.size != middle.size or
        first.bytes != second.bytes or !std.mem.eql(u8, &first.sha256, &second.sha256))
        return error.ArtifactChangedDuringRead;
    return second;
}

fn hashOpenArtifact(fd: pfs.Fd, expected_bytes: u64, max_bytes: u64) !ArtifactObservation {
    if (pfs.lseek(fd, 0, .set) != 0) return error.ArtifactReadFailed;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var total: u64 = 0;
    var buffer: [64 * 1024]u8 = undefined;
    while (true) {
        const count = try pfs.readZ(fd, &buffer);
        if (count == 0) break;
        total = std.math.add(u64, total, count) catch return error.ArtifactTooLarge;
        if (total > max_bytes) return error.ArtifactTooLarge;
        hasher.update(buffer[0..count]);
    }
    if (total != expected_bytes) return error.ArtifactChangedDuringRead;
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return .{ .sha256 = std.fmt.bytesToHex(digest, .lower), .bytes = total };
}

const RawState = struct {
    phase: []const u8,
    task_sha256: []const u8,
    actor_run_sha256: []const u8,
    artifact_sha256: []const u8,
    artifact_revision: []const u8,
    verifier_sha256: []const u8,
    policy_sha256: []const u8,
    budget_authority_sha256: []const u8,
    active_provider_authorization_sha256: []const u8,
    transition_revision: u64,
    repair_attempts: u32,
    max_repair_attempts: u32,
    semantic_verdict_sha256: []const u8,
    defect_sha256: []const u8,
    repair_proposal_sha256: []const u8,
};

const RawSnapshot = struct {
    schema_version: []const u8,
    revision: []const u8,
    state: RawState,
};

const RawProposal = struct {
    schema_version: []const u8,
    operation: []const u8,
    event: []const u8,
    expected_phase: []const u8,
    expected_next_phase: []const u8,
    expected_snapshot_revision: []const u8,
    next_snapshot_revision: []const u8,
    provider_authorization_sha256: []const u8,
    semantic_verdict_sha256: []const u8,
    defect_sha256: []const u8,
    repair_proposal_sha256: []const u8,
    next_artifact_sha256: []const u8,
    next_artifact_revision: []const u8,
};

pub fn evaluate(
    allocator: std.mem.Allocator,
    encoded_snapshot: []const u8,
    encoded_proposal: []const u8,
    config: runtime.Config,
    abort: ?*const AbortSignal,
) !Evaluation {
    if (encoded_snapshot.len == 0 or encoded_snapshot.len > MAX_INPUT_BYTES)
        return error.InvalidArtifactSnapshot;
    if (encoded_proposal.len == 0 or encoded_proposal.len > MAX_INPUT_BYTES)
        return error.InvalidArtifactProposal;

    var parsed_snapshot = std.json.parseFromSlice(RawSnapshot, allocator, encoded_snapshot, .{
        .ignore_unknown_fields = false,
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidArtifactSnapshot,
    };
    defer parsed_snapshot.deinit();
    const snapshot = try validateSnapshot(parsed_snapshot.value);

    var parsed_proposal = std.json.parseFromSlice(RawProposal, allocator, encoded_proposal, .{
        .ignore_unknown_fields = false,
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidArtifactProposal,
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
        .next_snapshot_revision = proposal.next_snapshot_revision,
        .expected_next_phase = phaseName(proposal.expected_next_phase),
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
        .snapshot = snapshot,
        .proposal = proposal,
        .canonical_snapshot = canonical_snapshot,
        .canonical_proposal = canonical_proposal,
        .request = request,
        .snapshot_sha256 = snapshot_sha256,
        .proposal_sha256 = proposal_sha256,
        .request_id = request_id,
        .invocation = invocation,
        .provenance = loaded,
    };
}

/// Persist immutable pre-CAS evidence. This receipt cannot be represented as
/// a completed verification or committed repair.
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
            .snapshot_revision = evaluation.snapshot.revision[0..],
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
        "{{\"schema_version\":\"{s}\",\"evidence_layer\":\"mechanism\",\"stage\":\"pre_state_cas\",\"statistical_claim\":\"none\",\"semantic_truth_claim\":false,\"operation\":\"{s}\",\"event\":\"{s}\",\"event_id\":\"{s}\",\"started_wall_ns\":{d},\"finished_wall_ns\":{d},\"identity\":{{\"request_id\":\"{s}\",\"proposal_sha256\":\"{s}\",\"snapshot_sha256\":\"{s}\",\"snapshot_revision\":\"{s}\",\"expected_next_phase\":\"{s}\",\"next_snapshot_revision\":\"{s}\"}},",
        .{ RECEIPT_SCHEMA, OPERATION, eventName(evaluation.proposal.event), event_id[0..], started_wall_ns, time.nowWallNs(), evaluation.request_id[0..], evaluation.proposal_sha256[0..], evaluation.snapshot_sha256[0..], evaluation.snapshot.revision[0..], phaseName(evaluation.proposal.expected_next_phase), evaluation.proposal.next_snapshot_revision[0..] },
    );
    try writer.print(
        "\"checker\":{{\"version\":\"{s}\",\"runtime_failure_kind\":\"{s}\",\"admitted\":{s},\"provenance_valid\":{s},\"checker_elapsed_ns\":{d},\"reason_codes\":[",
        .{ runtime.CHECKER_VERSION, @tagName(evaluation.invocation.failure), boolText(evaluation.invocation.checkerAdmitted()), boolText(evaluation.provenance != null), evaluation.invocation.checker_elapsed_ns },
    );
    if (evaluation.invocation.verdict) |verdict| {
        for (verdict.reasons, 0..) |reason, index| {
            if (index != 0) try writer.writeAll(",");
            try writer.print("\"{s}\"", .{@tagName(reason)});
        }
    }
    try writer.writeAll("]},");
    try writer.writeAll(
        "\"trust_boundary\":{\"lean\":\"lifecycle_and_governance_only\",\"semantic_verdict\":\"external_verifier_evidence\",\"provider_authorization_durability\":\"host_evidence_required\",\"artifact_observation\":\"host_reobserve_required\"}," ++
            "\"transaction\":{\"state_reobserve\":\"not_performed_precommit_only\",\"state_cas\":\"not_performed_precommit_only\",\"artifact_source_cas\":\"not_performed_precommit_only\"}," ++
            "\"artifact_bundle\":{\"schema_version\":\"metacodes-formal-artifact-bundle-v1\",\"completion_rule\":\"manifest_hash_validation\"}," ++
            "\"paid_experiment_cost_usd\":0}",
    );
    return out.toOwnedSlice();
}

fn validateSnapshot(raw: RawSnapshot) !Snapshot {
    if (!std.mem.eql(u8, raw.schema_version, SNAPSHOT_SCHEMA))
        return error.InvalidArtifactSnapshot;
    const revision = parseHash(raw.revision) orelse return error.InvalidArtifactSnapshot;
    if (isZero(revision)) return error.InvalidArtifactSnapshot;
    return .{ .revision = revision, .state = try validateState(raw.state) };
}

fn validateState(raw: RawState) !State {
    if (raw.max_repair_attempts == 0 or raw.max_repair_attempts > 16 or
        raw.repair_attempts > raw.max_repair_attempts)
        return error.InvalidArtifactSnapshot;
    return .{
        .phase = std.meta.stringToEnum(Phase, raw.phase) orelse return error.InvalidArtifactSnapshot,
        .task_sha256 = parseHash(raw.task_sha256) orelse return error.InvalidArtifactSnapshot,
        .actor_run_sha256 = parseHash(raw.actor_run_sha256) orelse return error.InvalidArtifactSnapshot,
        .artifact_sha256 = parseHash(raw.artifact_sha256) orelse return error.InvalidArtifactSnapshot,
        .artifact_revision = parseHash(raw.artifact_revision) orelse return error.InvalidArtifactSnapshot,
        .verifier_sha256 = parseHash(raw.verifier_sha256) orelse return error.InvalidArtifactSnapshot,
        .policy_sha256 = parseHash(raw.policy_sha256) orelse return error.InvalidArtifactSnapshot,
        .budget_authority_sha256 = parseHash(raw.budget_authority_sha256) orelse return error.InvalidArtifactSnapshot,
        .active_provider_authorization_sha256 = parseHash(raw.active_provider_authorization_sha256) orelse return error.InvalidArtifactSnapshot,
        .transition_revision = raw.transition_revision,
        .repair_attempts = raw.repair_attempts,
        .max_repair_attempts = raw.max_repair_attempts,
        .semantic_verdict_sha256 = parseHash(raw.semantic_verdict_sha256) orelse return error.InvalidArtifactSnapshot,
        .defect_sha256 = parseHash(raw.defect_sha256) orelse return error.InvalidArtifactSnapshot,
        .repair_proposal_sha256 = parseHash(raw.repair_proposal_sha256) orelse return error.InvalidArtifactSnapshot,
    };
}

fn validateProposal(raw: RawProposal) !Proposal {
    if (!std.mem.eql(u8, raw.schema_version, PROPOSAL_SCHEMA) or
        !std.mem.eql(u8, raw.operation, OPERATION))
        return error.InvalidArtifactProposal;
    return .{
        .event = std.meta.stringToEnum(Event, raw.event) orelse return error.InvalidArtifactProposal,
        .expected_phase = std.meta.stringToEnum(Phase, raw.expected_phase) orelse return error.InvalidArtifactProposal,
        .expected_next_phase = std.meta.stringToEnum(Phase, raw.expected_next_phase) orelse return error.InvalidArtifactProposal,
        .expected_snapshot_revision = parseHash(raw.expected_snapshot_revision) orelse return error.InvalidArtifactProposal,
        .next_snapshot_revision = parseHash(raw.next_snapshot_revision) orelse return error.InvalidArtifactProposal,
        .provider_authorization_sha256 = parseHash(raw.provider_authorization_sha256) orelse return error.InvalidArtifactProposal,
        .semantic_verdict_sha256 = parseHash(raw.semantic_verdict_sha256) orelse return error.InvalidArtifactProposal,
        .defect_sha256 = parseHash(raw.defect_sha256) orelse return error.InvalidArtifactProposal,
        .repair_proposal_sha256 = parseHash(raw.repair_proposal_sha256) orelse return error.InvalidArtifactProposal,
        .next_artifact_sha256 = parseHash(raw.next_artifact_sha256) orelse return error.InvalidArtifactProposal,
        .next_artifact_revision = parseHash(raw.next_artifact_revision) orelse return error.InvalidArtifactProposal,
    };
}

fn renderSnapshot(allocator: std.mem.Allocator, snapshot: Snapshot) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try out.writer.print(
        "{{\"schema_version\":\"{s}\",\"revision\":\"{s}\",\"state\":",
        .{ SNAPSHOT_SCHEMA, snapshot.revision[0..] },
    );
    try writeState(&out.writer, snapshot.state);
    try out.writer.writeAll("}");
    return out.toOwnedSlice();
}

fn renderProposal(allocator: std.mem.Allocator, proposal: Proposal) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"schema_version\":\"{s}\",\"operation\":\"{s}\",\"event\":\"{s}\",\"expected_phase\":\"{s}\",\"expected_next_phase\":\"{s}\",\"expected_snapshot_revision\":\"{s}\",\"next_snapshot_revision\":\"{s}\",\"provider_authorization_sha256\":\"{s}\",\"semantic_verdict_sha256\":\"{s}\",\"defect_sha256\":\"{s}\",\"repair_proposal_sha256\":\"{s}\",\"next_artifact_sha256\":\"{s}\",\"next_artifact_revision\":\"{s}\"}}",
        .{ PROPOSAL_SCHEMA, OPERATION, eventName(proposal.event), phaseName(proposal.expected_phase), phaseName(proposal.expected_next_phase), proposal.expected_snapshot_revision[0..], proposal.next_snapshot_revision[0..], proposal.provider_authorization_sha256[0..], proposal.semantic_verdict_sha256[0..], proposal.defect_sha256[0..], proposal.repair_proposal_sha256[0..], proposal.next_artifact_sha256[0..], proposal.next_artifact_revision[0..] },
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
    try out.writer.print(
        "{{\"schema_version\":\"{s}\",\"request_id\":\"{s}\",\"operation\":\"{s}\",\"proposal_sha256\":\"{s}\",\"snapshot_sha256\":\"{s}\",\"snapshot_revision\":\"{s}\",\"expected_checker_version\":\"{s}\",\"state\":",
        .{ runtime.ARTIFACT_REQUEST_SCHEMA, request_id[0..], OPERATION, proposal_sha256[0..], snapshot_sha256[0..], snapshot.revision[0..], runtime.CHECKER_VERSION },
    );
    try writeState(&out.writer, snapshot.state);
    try out.writer.print(
        ",\"proposal\":{{\"event\":\"{s}\",\"expected_phase\":\"{s}\",\"expected_next_phase\":\"{s}\",\"expected_snapshot_revision\":\"{s}\",\"next_snapshot_revision\":\"{s}\",\"provider_authorization_sha256\":\"{s}\",\"semantic_verdict_sha256\":\"{s}\",\"defect_sha256\":\"{s}\",\"repair_proposal_sha256\":\"{s}\",\"next_artifact_sha256\":\"{s}\",\"next_artifact_revision\":\"{s}\"}}}}",
        .{ eventName(proposal.event), phaseName(proposal.expected_phase), phaseName(proposal.expected_next_phase), proposal.expected_snapshot_revision[0..], proposal.next_snapshot_revision[0..], proposal.provider_authorization_sha256[0..], proposal.semantic_verdict_sha256[0..], proposal.defect_sha256[0..], proposal.repair_proposal_sha256[0..], proposal.next_artifact_sha256[0..], proposal.next_artifact_revision[0..] },
    );
    return out.toOwnedSlice();
}

fn writeState(writer: *std.Io.Writer, state: State) !void {
    try writer.print(
        "{{\"phase\":\"{s}\",\"task_sha256\":\"{s}\",\"actor_run_sha256\":\"{s}\",\"artifact_sha256\":\"{s}\",\"artifact_revision\":\"{s}\",\"verifier_sha256\":\"{s}\",\"policy_sha256\":\"{s}\",\"budget_authority_sha256\":\"{s}\",\"active_provider_authorization_sha256\":\"{s}\",\"transition_revision\":{d},\"repair_attempts\":{d},\"max_repair_attempts\":{d},\"semantic_verdict_sha256\":\"{s}\",\"defect_sha256\":\"{s}\",\"repair_proposal_sha256\":\"{s}\"}}",
        .{ phaseName(state.phase), state.task_sha256[0..], state.actor_run_sha256[0..], state.artifact_sha256[0..], state.artifact_revision[0..], state.verifier_sha256[0..], state.policy_sha256[0..], state.budget_authority_sha256[0..], state.active_provider_authorization_sha256[0..], state.transition_revision, state.repair_attempts, state.max_repair_attempts, state.semantic_verdict_sha256[0..], state.defect_sha256[0..], state.repair_proposal_sha256[0..] },
    );
}

fn phaseName(phase: Phase) []const u8 {
    return @tagName(phase);
}

fn eventName(event: Event) []const u8 {
    return @tagName(event);
}

fn parseHash(raw: []const u8) ?[64]u8 {
    if (raw.len != 64) return null;
    var result: [64]u8 = undefined;
    for (raw, 0..) |byte, index| {
        if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return null;
        result[index] = byte;
    }
    return result;
}

fn isZero(hash: [64]u8) bool {
    return std.mem.allEqual(u8, &hash, '0');
}

fn sha256Hex(bytes: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

fn requestId(proposal_sha256: [64]u8, snapshot_sha256: [64]u8, revision: [64]u8) [64]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("metacodes-artifact-transition-request-id-v1\x00");
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

const zero_hash = "0000000000000000000000000000000000000000000000000000000000000000";
const fixture_snapshot =
    \\{"schema_version":"metacodes-artifact-state-snapshot-v1","revision":"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd","state":{"phase":"candidate","task_sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","actor_run_sha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","artifact_sha256":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc","artifact_revision":"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd","verifier_sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","policy_sha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","budget_authority_sha256":"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc","active_provider_authorization_sha256":"0000000000000000000000000000000000000000000000000000000000000000","transition_revision":0,"repair_attempts":0,"max_repair_attempts":3,"semantic_verdict_sha256":"0000000000000000000000000000000000000000000000000000000000000000","defect_sha256":"0000000000000000000000000000000000000000000000000000000000000000","repair_proposal_sha256":"0000000000000000000000000000000000000000000000000000000000000000"}}
;
const fixture_proposal =
    \\{"schema_version":"metacodes-artifact-transition-proposal-v1","operation":"artifact_transition","event":"request_verification","expected_phase":"candidate","expected_next_phase":"verification_requested","expected_snapshot_revision":"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd","next_snapshot_revision":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","provider_authorization_sha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","semantic_verdict_sha256":"0000000000000000000000000000000000000000000000000000000000000000","defect_sha256":"0000000000000000000000000000000000000000000000000000000000000000","repair_proposal_sha256":"0000000000000000000000000000000000000000000000000000000000000000","next_artifact_sha256":"0000000000000000000000000000000000000000000000000000000000000000","next_artifact_revision":"0000000000000000000000000000000000000000000000000000000000000000"}
;

test "artifact transition host canonicalizes state and binds proof-carrying next phase" {
    var parsed_snapshot = try std.json.parseFromSlice(RawSnapshot, std.testing.allocator, fixture_snapshot, .{});
    defer parsed_snapshot.deinit();
    const snapshot = try validateSnapshot(parsed_snapshot.value);
    var parsed_proposal = try std.json.parseFromSlice(RawProposal, std.testing.allocator, fixture_proposal, .{});
    defer parsed_proposal.deinit();
    const proposal = try validateProposal(parsed_proposal.value);
    const canonical_snapshot = try renderSnapshot(std.testing.allocator, snapshot);
    defer std.testing.allocator.free(canonical_snapshot);
    const canonical_proposal = try renderProposal(std.testing.allocator, proposal);
    defer std.testing.allocator.free(canonical_proposal);
    const snapshot_sha256 = sha256Hex(canonical_snapshot);
    const proposal_sha256 = sha256Hex(canonical_proposal);
    const request_id = requestId(proposal_sha256, snapshot_sha256, snapshot.revision);
    const request = try renderRequest(
        std.testing.allocator,
        snapshot,
        proposal,
        request_id,
        snapshot_sha256,
        proposal_sha256,
    );
    defer std.testing.allocator.free(request);
    try std.testing.expectEqualStrings(fixture_snapshot, canonical_snapshot);
    try std.testing.expectEqualStrings(fixture_proposal, canonical_proposal);
    try std.testing.expect(std.mem.indexOf(u8, request, "\"expected_next_phase\":\"verification_requested\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, request, "semantic_truth") == null);
}

test "artifact host accepts zero only as a wire value for Lean to govern" {
    try std.testing.expect(parseHash(zero_hash) != null);
    var parsed = try std.json.parseFromSlice(RawSnapshot, std.testing.allocator, fixture_snapshot, .{});
    defer parsed.deinit();
    parsed.value.revision = zero_hash;
    try std.testing.expectError(error.InvalidArtifactSnapshot, validateSnapshot(parsed.value));
}

test "artifact host observes real regular bytes and rejects hardlinks" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    const path = try std.fmt.allocPrint(std.testing.allocator, "{s}/artifact.csv", .{root});
    defer std.testing.allocator.free(path);
    try writeTestFile(std.testing.allocator, path, "first,second\n1,2\n");
    const first = try observeRegularArtifact(std.testing.allocator, path, 1024);
    try std.testing.expectEqual(@as(u64, 17), first.bytes);
    try writeTestFile(std.testing.allocator, path, "second,first\n2,1\n");
    const second = try observeRegularArtifact(std.testing.allocator, path, 1024);
    try std.testing.expect(!std.mem.eql(u8, &first.sha256, &second.sha256));

    if (builtin.os.tag != .windows) {
        const alias = try std.fmt.allocPrint(std.testing.allocator, "{s}/alias.csv", .{root});
        defer std.testing.allocator.free(alias);
        const path_z = try std.testing.allocator.dupeZ(u8, path);
        defer std.testing.allocator.free(path_z);
        const alias_z = try std.testing.allocator.dupeZ(u8, alias);
        defer std.testing.allocator.free(alias_z);
        if (std.c.link(path_z.ptr, alias_z.ptr) != 0) return error.TestHardlinkFailed;
        try std.testing.expectError(
            error.ArtifactUnsafe,
            observeRegularArtifact(std.testing.allocator, path, 1024),
        );
    }
}

test "artifact host crosses canonical request pinned Lean verdict and reobserve gate" {
    const config = testKernel() orelse return error.SkipZigTest;
    var evaluation = try evaluate(
        std.testing.allocator,
        fixture_snapshot,
        fixture_proposal,
        config,
        null,
    );
    defer evaluation.deinit();
    try std.testing.expect(evaluation.checkerAdmitted());
    try std.testing.expectEqual(
        StateCommitGate.ready_for_state_cas,
        evaluation.stateCommitGate(
            evaluation.snapshot.revision[0..],
            evaluation.snapshot.state.artifact_sha256[0..],
            evaluation.snapshot.state.artifact_revision[0..],
            true,
        ),
    );
    try std.testing.expectEqual(
        StateCommitGate.stale_snapshot_revision,
        evaluation.stateCommitGate(
            ("eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"),
            evaluation.snapshot.state.artifact_sha256[0..],
            evaluation.snapshot.state.artifact_revision[0..],
            true,
        ),
    );
    try std.testing.expectEqual(
        StateCommitGate.artifact_drift,
        evaluation.stateCommitGate(
            evaluation.snapshot.revision[0..],
            ("eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"),
            evaluation.snapshot.state.artifact_revision[0..],
            true,
        ),
    );
}

fn testKernel() ?runtime.Config {
    if (builtin.os.tag == .windows) return null;
    const path_raw = std.c.getenv("METACODES_TEST_FORMAL_KERNEL_PATH") orelse return null;
    const hash_raw = std.c.getenv("METACODES_TEST_FORMAL_KERNEL_SHA256") orelse return null;
    const path = std.mem.span(path_raw);
    const hash = parseHash(std.mem.span(hash_raw)) orelse return null;
    if (!std.fs.path.isAbsolute(path)) return null;
    return .{ .checker_path = path, .expected_sha256 = hash };
}

fn writeTestFile(allocator: std.mem.Allocator, path: []const u8, content: []const u8) !void {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const fd = pfs.open(
        path_z.ptr,
        .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .NOFOLLOW = true },
        0o600,
    );
    if (fd < 0) return error.TestArtifactOpenFailed;
    defer _ = pfs.close(fd);
    var offset: usize = 0;
    while (offset < content.len) {
        const count = pfs.write(fd, content[offset..]);
        if (count <= 0) return error.TestArtifactWriteFailed;
        offset += @intCast(count);
    }
}
