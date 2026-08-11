//! Host boundary for artifact verification and targeted repair governance.
//!
//! The external verifier owns semantic judgement. Lean only decides whether a
//! lifecycle transition is structurally and transactionally admissible. Zig
//! canonicalizes the observed state/proposal, invokes the hash-pinned kernel,
//! persists the exact evidence, then requires a fresh artifact observation
//! before a state CAS. Provider calls stay outside this module. A repair that
//! has already been authorized may, however, use the narrow source-CAS host
//! boundary below: one no-follow descriptor, pathname/inode re-observation,
//! durable rollback verification, and an exclusive state transaction.

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
    request_id: [64]u8,
    receipt: []u8,
    bundle_dir: []u8,
    manifest_sha256: [64]u8,
    index_persisted: bool,

    pub fn deinit(self: *PersistedEvidence) void {
        self.allocator.free(self.receipt);
        self.allocator.free(self.bundle_dir);
        self.* = undefined;
    }
};

pub const StateBeginError = error{
    Unavailable,
    Stale,
};

pub const StateCommitError = error{
    PreCommitFailed,
    CommitAmbiguous,
};

pub const StateAbortError = error{AbortFailed};

pub const StateAbortReason = enum {
    pre_mutation,
    artifact_restored,
    artifact_recovery_required,
};

/// Complete identity persisted before the host is allowed to change bytes.
/// `transaction_id` is the domain-separated hash of every remaining field.
pub const StateTransactionIdentity = struct {
    transaction_id: [64]u8,
    request_id: [64]u8,
    proposal_sha256: [64]u8,
    snapshot_sha256: [64]u8,
    evidence_event_id: [64]u8,
    evidence_manifest_sha256: [64]u8,
    prior_snapshot_revision: [64]u8,
    next_snapshot_revision: [64]u8,
    prior_artifact_sha256: [64]u8,
    prior_artifact_revision: [64]u8,
    next_artifact_sha256: [64]u8,
    next_artifact_revision: [64]u8,
    path_sha256: [64]u8,
    artifact_device: u64,
    artifact_inode: u64,
};

/// The implementation must hold one exclusive state lock from `begin` until
/// `commit` or `abort`. `PreCommitFailed` guarantees that canonical state was
/// not changed and leaves the transaction open for host rollback + `abort`.
/// `CommitAmbiguous` guarantees that a durable, non-retryable uncertainty was
/// recorded and the lock was released; the host must retain repaired bytes and
/// must not call `abort`. Native L2/fault injection, not Lean, verifies these
/// locking and durability contracts. The implementation must also serialize
/// every cooperative writer for the canonical artifact while this transaction
/// is open. Path/inode/hash re-observation detects injected swaps, but no local
/// API can make a file write and a separate state-store commit one OS-atomic
/// operation against an uncooperative external writer.
pub const StateTransaction = struct {
    ctx: ?*anyopaque,
    begin_fn: *const fn (
        ctx: ?*anyopaque,
        identity: *const StateTransactionIdentity,
    ) StateBeginError!void,
    commit_fn: *const fn (
        ctx: ?*anyopaque,
        identity: *const StateTransactionIdentity,
    ) StateCommitError![64]u8,
    abort_fn: *const fn (
        ctx: ?*anyopaque,
        identity: *const StateTransactionIdentity,
        reason: StateAbortReason,
    ) StateAbortError!void,
};

pub const RepairCommit = struct {
    transaction_id: [64]u8,
    evidence_manifest_sha256: [64]u8,
    state_receipt_sha256: [64]u8,
    prior_artifact_sha256: [64]u8,
    next_artifact_sha256: [64]u8,
    next_artifact_revision: [64]u8,
    path_sha256: [64]u8,
    bytes: u64,
};

pub const RepairAmbiguity = struct {
    transaction_id: [64]u8,
    evidence_manifest_sha256: [64]u8,
    next_artifact_sha256: [64]u8,
    next_artifact_revision: [64]u8,
    path_sha256: [64]u8,
    bytes: u64,
    ambiguity_recorded: bool,
};

/// Ambiguous state acknowledgement is data, not a retryable error: the new
/// artifact is deliberately retained and callers must reconcile the state
/// receipt before deciding anything else.
pub const RepairResult = union(enum) {
    committed: RepairCommit,
    commit_ambiguous: RepairAmbiguity,
};

const RepairAuthority = struct {
    request_id: [64]u8,
    proposal_sha256: [64]u8,
    snapshot_sha256: [64]u8,
    evidence_event_id: [64]u8,
    evidence_manifest_sha256: [64]u8,
    prior_snapshot_revision: [64]u8,
    next_snapshot_revision: [64]u8,
    prior_artifact_sha256: [64]u8,
    prior_artifact_revision: [64]u8,
    next_artifact_sha256: [64]u8,
    next_artifact_revision: [64]u8,
    repair_proposal_sha256: [64]u8,
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
    const parent = std.fs.path.dirname(index_path) orelse return error.InvalidArtifactTarget;
    const bundle_dir = try std.fmt.allocPrint(
        allocator,
        "{s}/{s}/{s}",
        .{ parent, artifact_store.ARTIFACT_DIR_NAME, event_id },
    );
    errdefer allocator.free(bundle_dir);
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
        .request_id = evaluation.request_id,
        .receipt = receipt,
        .bundle_dir = bundle_dir,
        .manifest_sha256 = persisted.manifest_sha256,
        .index_persisted = persisted.index_persisted,
    };
}

/// Execute the authority-bearing repair selected by Lean. The replacement is
/// already provider-produced host data; the actor is never asked to reconstruct
/// Edit arguments. The caller must persist `evidence` before entering here.
pub fn applyAuthorizedSingleFileRepair(
    allocator: std.mem.Allocator,
    evaluation: *const Evaluation,
    evidence: *const PersistedEvidence,
    transaction: StateTransaction,
    path: []const u8,
    replacement: []const u8,
    max_bytes: u64,
) !RepairResult {
    if (!evaluation.checkerAdmitted() or
        !std.mem.eql(u8, &evidence.request_id, &evaluation.request_id) or
        isZero(evidence.event_id) or isZero(evidence.manifest_sha256) or
        evaluation.proposal.event != .record_repair or
        evaluation.snapshot.state.phase != .repair_authorized or
        evaluation.proposal.expected_phase != .repair_authorized or
        evaluation.proposal.expected_next_phase != .repaired)
        return error.RepairNotAuthorized;
    verifyPersistedMechanismEvidence(allocator, evaluation, evidence) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.PersistedEvidenceInvalid,
    };
    const replacement_sha256 = sha256Hex(replacement);
    if (!std.mem.eql(u8, &replacement_sha256, &evaluation.proposal.next_artifact_sha256) or
        std.mem.eql(u8, &replacement_sha256, &evaluation.snapshot.state.artifact_sha256))
        return error.ReplacementIdentityMismatch;
    const authority: RepairAuthority = .{
        .request_id = evaluation.request_id,
        .proposal_sha256 = evaluation.proposal_sha256,
        .snapshot_sha256 = evaluation.snapshot_sha256,
        .evidence_event_id = evidence.event_id,
        .evidence_manifest_sha256 = evidence.manifest_sha256,
        .prior_snapshot_revision = evaluation.snapshot.revision,
        .next_snapshot_revision = evaluation.proposal.next_snapshot_revision,
        .prior_artifact_sha256 = evaluation.snapshot.state.artifact_sha256,
        .prior_artifact_revision = evaluation.snapshot.state.artifact_revision,
        .next_artifact_sha256 = replacement_sha256,
        .next_artifact_revision = evaluation.proposal.next_artifact_revision,
        .repair_proposal_sha256 = evaluation.snapshot.state.repair_proposal_sha256,
    };
    return applyAuthorizedRepairWithFaults(
        allocator,
        authority,
        transaction,
        path,
        replacement,
        max_bytes,
        .{},
    );
}

const MechanismReceipt = struct {
    schema_version: []const u8,
    evidence_layer: []const u8,
    stage: []const u8,
    operation: []const u8,
    event: []const u8,
    event_id: []const u8,
    identity: struct {
        request_id: []const u8,
        proposal_sha256: []const u8,
        snapshot_sha256: []const u8,
        snapshot_revision: []const u8,
        expected_next_phase: []const u8,
        next_snapshot_revision: []const u8,
    },
    checker: struct {
        admitted: bool,
        provenance_valid: bool,
    },
};

fn verifyPersistedMechanismEvidence(
    allocator: std.mem.Allocator,
    evaluation: *const Evaluation,
    evidence: *const PersistedEvidence,
) !void {
    if (!std.fs.path.isAbsolute(evidence.bundle_dir)) return error.InvalidEvidenceBundle;
    const verified = try artifact_store.verifyBundle(allocator, evidence.bundle_dir);
    if (!std.mem.eql(u8, &verified.event_id, &evidence.event_id) or
        !std.mem.eql(u8, &verified.manifest_sha256, &evidence.manifest_sha256) or
        !std.mem.eql(u8, &verified.receipt_sha256, &sha256Hex(evidence.receipt)))
        return error.InvalidEvidenceBundle;
    var parsed = std.json.parseFromSlice(MechanismReceipt, allocator, evidence.receipt, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidEvidenceReceipt,
    };
    defer parsed.deinit();
    const receipt = parsed.value;
    if (!std.mem.eql(u8, receipt.schema_version, RECEIPT_SCHEMA) or
        !std.mem.eql(u8, receipt.evidence_layer, "mechanism") or
        !std.mem.eql(u8, receipt.stage, "pre_state_cas") or
        !std.mem.eql(u8, receipt.operation, OPERATION) or
        !std.mem.eql(u8, receipt.event, eventName(evaluation.proposal.event)) or
        !std.mem.eql(u8, receipt.event_id, &evidence.event_id) or
        !std.mem.eql(u8, receipt.identity.request_id, &evaluation.request_id) or
        !std.mem.eql(u8, receipt.identity.proposal_sha256, &evaluation.proposal_sha256) or
        !std.mem.eql(u8, receipt.identity.snapshot_sha256, &evaluation.snapshot_sha256) or
        !std.mem.eql(u8, receipt.identity.snapshot_revision, &evaluation.snapshot.revision) or
        !std.mem.eql(u8, receipt.identity.expected_next_phase, phaseName(evaluation.proposal.expected_next_phase)) or
        !std.mem.eql(u8, receipt.identity.next_snapshot_revision, &evaluation.proposal.next_snapshot_revision) or
        !receipt.checker.admitted or !receipt.checker.provenance_valid)
        return error.InvalidEvidenceReceipt;
}

/// Bind an artifact version to the exact repaired bytes, the next canonical
/// state revision, canonical source path, and the repair intent that authorized
/// provider execution. V2 deliberately differs from the earlier path-blind
/// derivation: equal bytes at two paths are not interchangeable authorities.
pub fn deriveArtifactRevision(
    artifact_sha256: [64]u8,
    next_snapshot_revision: [64]u8,
    repair_proposal_sha256: [64]u8,
    path_sha256: [64]u8,
) [64]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("metacodes-artifact-revision-v2\x00");
    hash.update(&artifact_sha256);
    hash.update(&next_snapshot_revision);
    hash.update(&repair_proposal_sha256);
    hash.update(&path_sha256);
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

/// Canonical path adapter for proposal builders. Callers must not duplicate
/// the host's realpath rules when preparing a path-bound repair proposal.
pub fn deriveArtifactRevisionForPath(
    allocator: std.mem.Allocator,
    artifact_sha256: [64]u8,
    next_snapshot_revision: [64]u8,
    repair_proposal_sha256: [64]u8,
    path: []const u8,
) ![64]u8 {
    if (!pfs.atomic_final_nofollow or !std.fs.path.isAbsolute(path) or path.len == 0)
        return error.InvalidArtifactPath;
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const canonical_path = try canonicalExistingPath(allocator, path_z.ptr);
    defer allocator.free(canonical_path);
    return deriveArtifactRevision(
        artifact_sha256,
        next_snapshot_revision,
        repair_proposal_sha256,
        sha256Hex(canonical_path),
    );
}

const RepairFaults = struct {
    force_post_write_observation_failure: bool = false,
    force_rollback_failure: bool = false,
    after_begin_ctx: ?*anyopaque = null,
    after_begin_fn: ?*const fn (?*anyopaque, []const u8) void = null,
    after_write_ctx: ?*anyopaque = null,
    after_write_fn: ?*const fn (?*anyopaque, []const u8) void = null,
};

const RecoveryDisposition = struct {
    restored: bool,
    abort_recorded: bool,
};

fn applyAuthorizedRepairWithFaults(
    allocator: std.mem.Allocator,
    authority: RepairAuthority,
    transaction: StateTransaction,
    path: []const u8,
    replacement: []const u8,
    max_bytes: u64,
    faults: RepairFaults,
) !RepairResult {
    if (!std.fs.path.isAbsolute(path) or path.len == 0 or
        max_bytes == 0 or max_bytes > MAX_ARTIFACT_BYTES or replacement.len > max_bytes)
        return error.InvalidArtifactPath;
    if (!pfs.atomic_final_nofollow) return error.AtomicNoFollowUnavailable;
    if (!std.mem.eql(u8, &sha256Hex(replacement), &authority.next_artifact_sha256) or
        std.mem.eql(u8, &authority.next_artifact_sha256, &authority.prior_artifact_sha256))
        return error.ReplacementIdentityMismatch;

    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const canonical_path = try canonicalExistingPath(allocator, path_z.ptr);
    defer allocator.free(canonical_path);
    const path_sha256 = sha256Hex(canonical_path);
    const expected_revision = deriveArtifactRevision(
        authority.next_artifact_sha256,
        authority.next_snapshot_revision,
        authority.repair_proposal_sha256,
        path_sha256,
    );
    if (!std.mem.eql(u8, &expected_revision, &authority.next_artifact_revision))
        return error.ReplacementIdentityMismatch;

    const fd = pfs.open(path_z.ptr, .{ .ACCMODE = .RDWR, .NOFOLLOW = true }, 0);
    if (fd < 0) return error.RepairTargetUnavailable;
    defer _ = pfs.close(fd);
    try pfs.makeCloseOnExec(fd);
    const before = try pfs.fileInfo(fd);
    if (!safeRegular(before, max_bytes)) return error.RepairTargetUnavailable;
    const original = try readOpenArtifact(allocator, fd, before.size, max_bytes);
    defer allocator.free(original);
    const after_read = try pfs.fileInfo(fd);
    if (!sameOpenFile(before, after_read) or !safeRegular(after_read, max_bytes) or
        after_read.size != before.size or
        !std.mem.eql(u8, &sha256Hex(original), &authority.prior_artifact_sha256))
        return error.RepairSourceChanged;

    var identity: StateTransactionIdentity = .{
        .transaction_id = undefined,
        .request_id = authority.request_id,
        .proposal_sha256 = authority.proposal_sha256,
        .snapshot_sha256 = authority.snapshot_sha256,
        .evidence_event_id = authority.evidence_event_id,
        .evidence_manifest_sha256 = authority.evidence_manifest_sha256,
        .prior_snapshot_revision = authority.prior_snapshot_revision,
        .next_snapshot_revision = authority.next_snapshot_revision,
        .prior_artifact_sha256 = authority.prior_artifact_sha256,
        .prior_artifact_revision = authority.prior_artifact_revision,
        .next_artifact_sha256 = authority.next_artifact_sha256,
        .next_artifact_revision = expected_revision,
        .path_sha256 = path_sha256,
        .artifact_device = before.device,
        .artifact_inode = before.inode,
    };
    identity.transaction_id = deriveStateTransactionId(identity);

    transaction.begin_fn(transaction.ctx, &identity) catch |err| switch (err) {
        error.Unavailable => return error.StateTransactionUnavailable,
        error.Stale => return error.StateTransactionStale,
    };
    if (faults.after_begin_fn) |hook|
        hook(faults.after_begin_ctx, path);

    const source_still_current = pathReferencesOpenArtifact(
        path_z.ptr,
        fd,
        authority.prior_artifact_sha256,
        before.size,
        max_bytes,
    ) catch false;
    if (!source_still_current or !canonicalPathMatches(path_z.ptr, path_sha256)) {
        const abort_recorded = recordAbort(transaction, &identity, .pre_mutation);
        if (!abort_recorded) return error.StateAbortFailed;
        return error.RepairSourceChanged;
    }

    replaceOpenArtifact(fd, replacement) catch {
        const recovery = recoverOriginalAndAbort(
            transaction,
            &identity,
            path_z.ptr,
            fd,
            original,
            max_bytes,
            faults,
        );
        if (!recovery.restored) return error.ArtifactRecoveryRequired;
        if (!recovery.abort_recorded) return error.StateAbortFailed;
        return error.RepairWriteFailed;
    };

    if (faults.after_write_fn) |hook|
        hook(faults.after_write_ctx, path);
    const post_write_current = if (faults.force_post_write_observation_failure)
        false
    else
        pathReferencesOpenArtifact(
            path_z.ptr,
            fd,
            authority.next_artifact_sha256,
            replacement.len,
            max_bytes,
        ) catch false;
    if (!post_write_current or !canonicalPathMatches(path_z.ptr, path_sha256)) {
        const recovery = recoverOriginalAndAbort(
            transaction,
            &identity,
            path_z.ptr,
            fd,
            original,
            max_bytes,
            faults,
        );
        if (!recovery.restored) return error.ArtifactRecoveryRequired;
        if (!recovery.abort_recorded) return error.StateAbortFailed;
        return error.RepairWriteFailed;
    }

    const state_receipt_sha256 = transaction.commit_fn(transaction.ctx, &identity) catch |err| switch (err) {
        error.PreCommitFailed => {
            const recovery = recoverOriginalAndAbort(
                transaction,
                &identity,
                path_z.ptr,
                fd,
                original,
                max_bytes,
                faults,
            );
            if (!recovery.restored) return error.ArtifactRecoveryRequired;
            if (!recovery.abort_recorded) return error.StateAbortFailed;
            return error.StateCommitFailed;
        },
        error.CommitAmbiguous => {
            return .{ .commit_ambiguous = ambiguityResult(
                identity,
                replacement.len,
                true,
            ) };
        },
    };
    if (!validPresentHash(state_receipt_sha256)) {
        // The state implementation claimed success but returned no usable
        // receipt. Rolling back would risk diverging from an already committed
        // canonical state, so retain the replacement and require reconciliation.
        return .{ .commit_ambiguous = ambiguityResult(
            identity,
            replacement.len,
            false,
        ) };
    }
    return .{ .committed = .{
        .transaction_id = identity.transaction_id,
        .evidence_manifest_sha256 = authority.evidence_manifest_sha256,
        .state_receipt_sha256 = state_receipt_sha256,
        .prior_artifact_sha256 = authority.prior_artifact_sha256,
        .next_artifact_sha256 = authority.next_artifact_sha256,
        .next_artifact_revision = expected_revision,
        .path_sha256 = path_sha256,
        .bytes = replacement.len,
    } };
}

fn deriveStateTransactionId(identity: StateTransactionIdentity) [64]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("metacodes-artifact-state-transaction-v1\x00");
    hash.update(&identity.request_id);
    hash.update(&identity.proposal_sha256);
    hash.update(&identity.snapshot_sha256);
    hash.update(&identity.evidence_event_id);
    hash.update(&identity.evidence_manifest_sha256);
    hash.update(&identity.prior_snapshot_revision);
    hash.update(&identity.next_snapshot_revision);
    hash.update(&identity.prior_artifact_sha256);
    hash.update(&identity.prior_artifact_revision);
    hash.update(&identity.next_artifact_sha256);
    hash.update(&identity.next_artifact_revision);
    hash.update(&identity.path_sha256);
    var numeric: [16]u8 = undefined;
    std.mem.writeInt(u64, numeric[0..8], identity.artifact_device, .little);
    std.mem.writeInt(u64, numeric[8..16], identity.artifact_inode, .little);
    hash.update(&numeric);
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

fn ambiguityResult(
    identity: StateTransactionIdentity,
    bytes: usize,
    ambiguity_recorded: bool,
) RepairAmbiguity {
    return .{
        .transaction_id = identity.transaction_id,
        .evidence_manifest_sha256 = identity.evidence_manifest_sha256,
        .next_artifact_sha256 = identity.next_artifact_sha256,
        .next_artifact_revision = identity.next_artifact_revision,
        .path_sha256 = identity.path_sha256,
        .bytes = bytes,
        .ambiguity_recorded = ambiguity_recorded,
    };
}

fn recordAbort(
    transaction: StateTransaction,
    identity: *const StateTransactionIdentity,
    reason: StateAbortReason,
) bool {
    transaction.abort_fn(transaction.ctx, identity, reason) catch return false;
    return true;
}

fn recoverOriginalAndAbort(
    transaction: StateTransaction,
    identity: *const StateTransactionIdentity,
    path_z: [*:0]const u8,
    fd: pfs.Fd,
    original: []const u8,
    max_bytes: u64,
    faults: RepairFaults,
) RecoveryDisposition {
    const restored = if (faults.force_rollback_failure)
        false
    else blk: {
        restoreOpenArtifact(fd, original) catch break :blk false;
        if (!canonicalPathMatches(path_z, identity.path_sha256)) break :blk false;
        break :blk pathReferencesOpenArtifact(
            path_z,
            fd,
            identity.prior_artifact_sha256,
            original.len,
            max_bytes,
        ) catch false;
    };
    return .{
        .restored = restored,
        .abort_recorded = recordAbort(
            transaction,
            identity,
            if (restored) .artifact_restored else .artifact_recovery_required,
        ),
    };
}

fn canonicalExistingPath(
    allocator: std.mem.Allocator,
    path_z: [*:0]const u8,
) ![]u8 {
    var buffer: [std.fs.max_path_bytes + 1]u8 = undefined;
    const resolved = pfs.realpath(path_z, &buffer) orelse return error.RepairTargetUnavailable;
    const value = std.mem.span(resolved);
    if (value.len == 0 or value.len > std.fs.max_path_bytes)
        return error.RepairTargetUnavailable;
    return allocator.dupe(u8, value);
}

fn canonicalPathMatches(path_z: [*:0]const u8, expected: [64]u8) bool {
    var buffer: [std.fs.max_path_bytes + 1]u8 = undefined;
    const resolved = pfs.realpath(path_z, &buffer) orelse return false;
    return std.mem.eql(u8, &sha256Hex(std.mem.span(resolved)), &expected);
}

fn safeRegular(info: pfs.FileInfo, max_bytes: u64) bool {
    return info.is_regular and info.link_count == 1 and info.size <= max_bytes;
}

fn sameOpenFile(lhs: pfs.FileInfo, rhs: pfs.FileInfo) bool {
    return lhs.device == rhs.device and lhs.inode == rhs.inode;
}

fn pathReferencesOpenArtifact(
    path_z: [*:0]const u8,
    authoritative_fd: pfs.Fd,
    expected_sha256: [64]u8,
    expected_bytes: u64,
    max_bytes: u64,
) !bool {
    const authoritative = try pfs.fileInfo(authoritative_fd);
    if (!safeRegular(authoritative, max_bytes) or authoritative.size != expected_bytes)
        return false;
    const observed_fd = pfs.open(path_z, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true }, 0);
    if (observed_fd < 0) return false;
    defer _ = pfs.close(observed_fd);
    try pfs.makeCloseOnExec(observed_fd);
    const observed = try pfs.fileInfo(observed_fd);
    if (!safeRegular(observed, max_bytes) or observed.size != expected_bytes or
        !sameOpenFile(authoritative, observed)) return false;
    const hashed = try hashOpenArtifact(observed_fd, expected_bytes, max_bytes);
    return std.mem.eql(u8, &hashed.sha256, &expected_sha256);
}

fn validPresentHash(hash: [64]u8) bool {
    if (isZero(hash)) return false;
    for (hash) |byte|
        if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return false;
    return true;
}

fn readOpenArtifact(
    allocator: std.mem.Allocator,
    fd: pfs.Fd,
    expected_bytes: u64,
    max_bytes: u64,
) ![]u8 {
    if (expected_bytes > max_bytes or expected_bytes > std.math.maxInt(usize))
        return error.ArtifactTooLarge;
    if (pfs.lseek(fd, 0, .set) != 0) return error.ArtifactReadFailed;
    const result = try allocator.alloc(u8, @intCast(expected_bytes));
    errdefer allocator.free(result);
    var offset: usize = 0;
    while (offset < result.len) {
        const count = try pfs.readZ(fd, result[offset..]);
        if (count == 0) return error.ArtifactChangedDuringRead;
        offset += count;
    }
    var probe: [1]u8 = undefined;
    if (try pfs.readZ(fd, &probe) != 0) return error.ArtifactChangedDuringRead;
    return result;
}

fn writeOpenArtifact(fd: pfs.Fd, content: []const u8) !void {
    if (pfs.lseek(fd, 0, .set) != 0) return error.ArtifactWriteFailed;
    var offset: usize = 0;
    while (offset < content.len) {
        const count = pfs.write(fd, content[offset..]);
        if (count <= 0 or @as(usize, @intCast(count)) > content.len - offset)
            return error.ArtifactWriteFailed;
        offset += @intCast(count);
    }
    try pfs.setSize(fd, @intCast(content.len));
}

fn replaceOpenArtifact(fd: pfs.Fd, replacement: []const u8) !void {
    try writeOpenArtifact(fd, replacement);
    try pfs.fsyncChecked(fd);
}

fn restoreOpenArtifact(fd: pfs.Fd, original: []const u8) !void {
    try writeOpenArtifact(fd, original);
    try pfs.fsyncChecked(fd);
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

const TestBeginMode = enum { success, stale, unavailable };
const TestCommitMode = enum { success, precommit_failed, ambiguous, invalid_receipt };

const TestStateTransaction = struct {
    begin_mode: TestBeginMode = .success,
    commit_mode: TestCommitMode = .success,
    abort_fails: bool = false,
    active: bool = false,
    lifecycle_invalid: bool = false,
    begin_count: usize = 0,
    commit_count: usize = 0,
    abort_count: usize = 0,
    last_abort_reason: ?StateAbortReason = null,
    identity: ?StateTransactionIdentity = null,

    fn transaction(self: *@This()) StateTransaction {
        return .{
            .ctx = self,
            .begin_fn = begin,
            .commit_fn = commit,
            .abort_fn = abort,
        };
    }

    fn begin(ctx: ?*anyopaque, identity: *const StateTransactionIdentity) StateBeginError!void {
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        self.begin_count += 1;
        switch (self.begin_mode) {
            .stale => return error.Stale,
            .unavailable => return error.Unavailable,
            .success => {},
        }
        if (self.active) self.lifecycle_invalid = true;
        self.active = true;
        self.identity = identity.*;
    }

    fn commit(ctx: ?*anyopaque, identity: *const StateTransactionIdentity) StateCommitError![64]u8 {
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        self.commit_count += 1;
        if (!self.active or self.identity == null or
            !std.meta.eql(self.identity.?, identity.*)) self.lifecycle_invalid = true;
        switch (self.commit_mode) {
            .precommit_failed => return error.PreCommitFailed,
            .ambiguous => {
                self.active = false;
                return error.CommitAmbiguous;
            },
            .invalid_receipt => {
                self.active = false;
                return [_]u8{'0'} ** 64;
            },
            .success => {
                self.active = false;
                return [_]u8{'9'} ** 64;
            },
        }
    }

    fn abort(
        ctx: ?*anyopaque,
        identity: *const StateTransactionIdentity,
        reason: StateAbortReason,
    ) StateAbortError!void {
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        self.abort_count += 1;
        self.last_abort_reason = reason;
        if (!self.active or self.identity == null or
            !std.meta.eql(self.identity.?, identity.*)) self.lifecycle_invalid = true;
        self.active = false;
        if (self.abort_fails) return error.AbortFailed;
    }
};

const TestPathSwap = struct {
    current: [*:0]const u8,
    alternate: [*:0]const u8,
    backup: [*:0]const u8,
    failed: bool = false,

    fn run(ctx: ?*anyopaque, _: []const u8) void {
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        if (pfs.renameReplace(self.current, self.backup) != 0 or
            pfs.renameReplace(self.alternate, self.current) != 0)
            self.failed = true;
    }
};

test "authorized artifact repair commits one path-bound state transaction" {
    if (!pfs.atomic_final_nofollow) return error.SkipZigTest;
    var fixture = try TestRepairFixture.init("original\n", "replacement\n");
    defer fixture.deinit();
    var transaction = TestStateTransaction{};
    const public_revision = try deriveArtifactRevisionForPath(
        std.testing.allocator,
        fixture.authority.next_artifact_sha256,
        fixture.authority.next_snapshot_revision,
        fixture.authority.repair_proposal_sha256,
        fixture.path,
    );
    try std.testing.expectEqualSlices(
        u8,
        &fixture.authority.next_artifact_revision,
        &public_revision,
    );
    try writeTestFile(std.testing.allocator, fixture.alternate, fixture.original);
    const alternate_revision = try deriveArtifactRevisionForPath(
        std.testing.allocator,
        fixture.authority.next_artifact_sha256,
        fixture.authority.next_snapshot_revision,
        fixture.authority.repair_proposal_sha256,
        fixture.alternate,
    );
    try std.testing.expect(!std.mem.eql(u8, &public_revision, &alternate_revision));

    const result = try applyAuthorizedRepairWithFaults(
        std.testing.allocator,
        fixture.authority,
        transaction.transaction(),
        fixture.path,
        fixture.replacement,
        1024,
        .{},
    );
    switch (result) {
        .committed => |receipt| {
            try std.testing.expectEqualSlices(u8, &([_]u8{'9'} ** 64), &receipt.state_receipt_sha256);
            try std.testing.expectEqualSlices(u8, &fixture.authority.next_artifact_revision, &receipt.next_artifact_revision);
            try std.testing.expectEqual(@as(u64, fixture.replacement.len), receipt.bytes);
        },
        .commit_ambiguous => return error.TestExpectedCommittedRepair,
    }
    try fixture.expectContent(fixture.replacement);
    try std.testing.expectEqual(@as(usize, 1), transaction.begin_count);
    try std.testing.expectEqual(@as(usize, 1), transaction.commit_count);
    try std.testing.expectEqual(@as(usize, 0), transaction.abort_count);
    try std.testing.expect(!transaction.active and !transaction.lifecycle_invalid);
}

test "authorized artifact repair rejects stale begin and mismatched replacement before mutation" {
    if (!pfs.atomic_final_nofollow) return error.SkipZigTest;
    var fixture = try TestRepairFixture.init("original\n", "replacement\n");
    defer fixture.deinit();
    var stale = TestStateTransaction{ .begin_mode = .stale };
    try std.testing.expectError(
        error.StateTransactionStale,
        applyAuthorizedRepairWithFaults(
            std.testing.allocator,
            fixture.authority,
            stale.transaction(),
            fixture.path,
            fixture.replacement,
            1024,
            .{},
        ),
    );
    try fixture.expectContent(fixture.original);
    try std.testing.expectEqual(@as(usize, 1), stale.begin_count);
    try std.testing.expectEqual(@as(usize, 0), stale.commit_count);
    try std.testing.expectEqual(@as(usize, 0), stale.abort_count);

    var mismatched_authority = fixture.authority;
    mismatched_authority.next_artifact_sha256 = [_]u8{'a'} ** 64;
    var never_started = TestStateTransaction{};
    try std.testing.expectError(
        error.ReplacementIdentityMismatch,
        applyAuthorizedRepairWithFaults(
            std.testing.allocator,
            mismatched_authority,
            never_started.transaction(),
            fixture.path,
            fixture.replacement,
            1024,
            .{},
        ),
    );
    try fixture.expectContent(fixture.original);
    try std.testing.expectEqual(@as(usize, 0), never_started.begin_count);
}

test "authorized artifact repair restores bytes before abort on definite commit failure" {
    if (!pfs.atomic_final_nofollow) return error.SkipZigTest;
    var fixture = try TestRepairFixture.init("original\n", "replacement\n");
    defer fixture.deinit();
    var transaction = TestStateTransaction{ .commit_mode = .precommit_failed };

    try std.testing.expectError(
        error.StateCommitFailed,
        applyAuthorizedRepairWithFaults(
            std.testing.allocator,
            fixture.authority,
            transaction.transaction(),
            fixture.path,
            fixture.replacement,
            1024,
            .{},
        ),
    );
    try fixture.expectContent(fixture.original);
    try std.testing.expectEqual(@as(usize, 1), transaction.commit_count);
    try std.testing.expectEqual(@as(usize, 1), transaction.abort_count);
    try std.testing.expectEqual(StateAbortReason.artifact_restored, transaction.last_abort_reason.?);
    try std.testing.expect(!transaction.active and !transaction.lifecycle_invalid);
}

test "authorized artifact repair retains bytes and forbids abort after ambiguous commit" {
    if (!pfs.atomic_final_nofollow) return error.SkipZigTest;
    var fixture = try TestRepairFixture.init("original\n", "replacement\n");
    defer fixture.deinit();
    var transaction = TestStateTransaction{ .commit_mode = .ambiguous };

    const result = try applyAuthorizedRepairWithFaults(
        std.testing.allocator,
        fixture.authority,
        transaction.transaction(),
        fixture.path,
        fixture.replacement,
        1024,
        .{},
    );
    switch (result) {
        .committed => return error.TestExpectedAmbiguousRepair,
        .commit_ambiguous => |ambiguity| try std.testing.expect(ambiguity.ambiguity_recorded),
    }
    try fixture.expectContent(fixture.replacement);
    try std.testing.expectEqual(@as(usize, 1), transaction.commit_count);
    try std.testing.expectEqual(@as(usize, 0), transaction.abort_count);
    try std.testing.expect(!transaction.active and !transaction.lifecycle_invalid);
}

test "authorized artifact repair treats an invalid success receipt as unrecorded ambiguity" {
    if (!pfs.atomic_final_nofollow) return error.SkipZigTest;
    var fixture = try TestRepairFixture.init("original\n", "replacement\n");
    defer fixture.deinit();
    var transaction = TestStateTransaction{ .commit_mode = .invalid_receipt };

    const result = try applyAuthorizedRepairWithFaults(
        std.testing.allocator,
        fixture.authority,
        transaction.transaction(),
        fixture.path,
        fixture.replacement,
        1024,
        .{},
    );
    switch (result) {
        .committed => return error.TestExpectedAmbiguousRepair,
        .commit_ambiguous => |ambiguity| try std.testing.expect(!ambiguity.ambiguity_recorded),
    }
    try fixture.expectContent(fixture.replacement);
    try std.testing.expectEqual(@as(usize, 0), transaction.abort_count);
    try std.testing.expect(!transaction.active and !transaction.lifecycle_invalid);
}

test "authorized artifact repair restores bytes after post-write observation failure" {
    if (!pfs.atomic_final_nofollow) return error.SkipZigTest;
    var fixture = try TestRepairFixture.init("original\n", "replacement\n");
    defer fixture.deinit();
    var transaction = TestStateTransaction{};

    try std.testing.expectError(
        error.RepairWriteFailed,
        applyAuthorizedRepairWithFaults(
            std.testing.allocator,
            fixture.authority,
            transaction.transaction(),
            fixture.path,
            fixture.replacement,
            1024,
            .{ .force_post_write_observation_failure = true },
        ),
    );
    try fixture.expectContent(fixture.original);
    try std.testing.expectEqual(@as(usize, 0), transaction.commit_count);
    try std.testing.expectEqual(@as(usize, 1), transaction.abort_count);
    try std.testing.expectEqual(StateAbortReason.artifact_restored, transaction.last_abort_reason.?);
    try std.testing.expect(!transaction.active and !transaction.lifecycle_invalid);
}

test "authorized artifact repair records recovery required when rollback cannot be verified" {
    if (!pfs.atomic_final_nofollow) return error.SkipZigTest;
    var fixture = try TestRepairFixture.init("original\n", "replacement\n");
    defer fixture.deinit();
    var transaction = TestStateTransaction{};

    try std.testing.expectError(
        error.ArtifactRecoveryRequired,
        applyAuthorizedRepairWithFaults(
            std.testing.allocator,
            fixture.authority,
            transaction.transaction(),
            fixture.path,
            fixture.replacement,
            1024,
            .{
                .force_post_write_observation_failure = true,
                .force_rollback_failure = true,
            },
        ),
    );
    try fixture.expectContent(fixture.replacement);
    try std.testing.expectEqual(@as(usize, 0), transaction.commit_count);
    try std.testing.expectEqual(@as(usize, 1), transaction.abort_count);
    try std.testing.expectEqual(StateAbortReason.artifact_recovery_required, transaction.last_abort_reason.?);
    try std.testing.expect(!transaction.active and !transaction.lifecycle_invalid);
}

test "authorized artifact repair rejects same-byte inode swap before writing" {
    if (!pfs.atomic_final_nofollow) return error.SkipZigTest;
    var fixture = try TestRepairFixture.init("original\n", "replacement\n");
    defer fixture.deinit();
    try writeTestFile(std.testing.allocator, fixture.alternate, fixture.original);
    var swap = fixture.pathSwap();
    var transaction = TestStateTransaction{};

    try std.testing.expectError(
        error.RepairSourceChanged,
        applyAuthorizedRepairWithFaults(
            std.testing.allocator,
            fixture.authority,
            transaction.transaction(),
            fixture.path,
            fixture.replacement,
            1024,
            .{ .after_begin_ctx = &swap, .after_begin_fn = TestPathSwap.run },
        ),
    );
    try std.testing.expect(!swap.failed);
    try fixture.expectContent(fixture.original);
    try std.testing.expectEqual(@as(usize, 0), transaction.commit_count);
    try std.testing.expectEqual(StateAbortReason.pre_mutation, transaction.last_abort_reason.?);
    try std.testing.expect(!transaction.active and !transaction.lifecycle_invalid);
}

test "authorized artifact repair fails closed on pathname swap after writing" {
    if (!pfs.atomic_final_nofollow) return error.SkipZigTest;
    var fixture = try TestRepairFixture.init("original\n", "replacement\n");
    defer fixture.deinit();
    try writeTestFile(std.testing.allocator, fixture.alternate, fixture.replacement);
    var swap = fixture.pathSwap();
    var transaction = TestStateTransaction{};

    try std.testing.expectError(
        error.ArtifactRecoveryRequired,
        applyAuthorizedRepairWithFaults(
            std.testing.allocator,
            fixture.authority,
            transaction.transaction(),
            fixture.path,
            fixture.replacement,
            1024,
            .{ .after_write_ctx = &swap, .after_write_fn = TestPathSwap.run },
        ),
    );
    try std.testing.expect(!swap.failed);
    try fixture.expectContent(fixture.replacement);
    try std.testing.expectEqual(@as(usize, 0), transaction.commit_count);
    try std.testing.expectEqual(StateAbortReason.artifact_recovery_required, transaction.last_abort_reason.?);
    try std.testing.expect(!transaction.active and !transaction.lifecycle_invalid);
}

test "L2 authorized artifact repair crosses persisted evidence Lean verdict and source CAS" {
    if (!pfs.atomic_final_nofollow) return error.SkipZigTest;
    const config = testKernel() orelse return error.SkipZigTest;
    var fixture = try TestRepairFixture.init("first,second\n1,2\n", "second,first\n2,1\n");
    defer fixture.deinit();
    const snapshot = try renderRepairTestSnapshot(std.testing.allocator, fixture.authority);
    defer std.testing.allocator.free(snapshot);
    const proposal = try renderRepairTestProposal(std.testing.allocator, fixture.authority);
    defer std.testing.allocator.free(proposal);
    var evaluation = try evaluate(std.testing.allocator, snapshot, proposal, config, null);
    defer evaluation.deinit();
    try std.testing.expect(evaluation.checkerAdmitted());

    const index_path = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}/formal-events.jsonl",
        .{std.fs.path.dirname(fixture.path).?},
    );
    defer std.testing.allocator.free(index_path);
    var evidence = try persistMechanismEvidence(
        std.testing.allocator,
        index_path,
        &evaluation,
        time.nowWallNs(),
        time.nowNs(),
    );
    defer evidence.deinit();
    const event_dir = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}/{s}/{s}",
        .{ std.fs.path.dirname(fixture.path).?, artifact_store.ARTIFACT_DIR_NAME, evidence.event_id },
    );
    defer std.testing.allocator.free(event_dir);
    const verified = try artifact_store.verifyBundle(std.testing.allocator, event_dir);
    try std.testing.expectEqualSlices(u8, &evidence.manifest_sha256, &verified.manifest_sha256);

    const original_receipt_byte = evidence.receipt[0];
    evidence.receipt[0] = if (original_receipt_byte == '{') '[' else '{';
    var rejected_transaction = TestStateTransaction{};
    try std.testing.expectError(
        error.PersistedEvidenceInvalid,
        applyAuthorizedSingleFileRepair(
            std.testing.allocator,
            &evaluation,
            &evidence,
            rejected_transaction.transaction(),
            fixture.path,
            fixture.replacement,
            1024,
        ),
    );
    evidence.receipt[0] = original_receipt_byte;
    try fixture.expectContent(fixture.original);
    try std.testing.expectEqual(@as(usize, 0), rejected_transaction.begin_count);

    var transaction = TestStateTransaction{};
    const result = try applyAuthorizedSingleFileRepair(
        std.testing.allocator,
        &evaluation,
        &evidence,
        transaction.transaction(),
        fixture.path,
        fixture.replacement,
        1024,
    );
    switch (result) {
        .committed => |receipt| {
            try std.testing.expectEqualSlices(u8, &evidence.manifest_sha256, &receipt.evidence_manifest_sha256);
            try std.testing.expectEqualSlices(u8, &fixture.authority.next_artifact_revision, &receipt.next_artifact_revision);
        },
        .commit_ambiguous => return error.TestExpectedCommittedRepair,
    }
    try fixture.expectContent(fixture.replacement);
    try std.testing.expectEqual(@as(usize, 1), transaction.begin_count);
    try std.testing.expectEqual(@as(usize, 1), transaction.commit_count);
    try std.testing.expect(!transaction.active and !transaction.lifecycle_invalid);
}

const TestRepairFixture = struct {
    tmp: std.testing.TmpDir,
    path: []u8,
    alternate: []u8,
    backup: []u8,
    path_z: [:0]u8,
    alternate_z: [:0]u8,
    backup_z: [:0]u8,
    original: []const u8,
    replacement: []const u8,
    authority: RepairAuthority,

    fn init(original: []const u8, replacement: []const u8) !@This() {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
        const root = root_buffer[0..root_len];
        const path = try std.fmt.allocPrint(std.testing.allocator, "{s}/artifact.txt", .{root});
        errdefer std.testing.allocator.free(path);
        const alternate = try std.fmt.allocPrint(std.testing.allocator, "{s}/alternate.txt", .{root});
        errdefer std.testing.allocator.free(alternate);
        const backup = try std.fmt.allocPrint(std.testing.allocator, "{s}/backup.txt", .{root});
        errdefer std.testing.allocator.free(backup);
        const path_z = try std.testing.allocator.dupeZ(u8, path);
        errdefer std.testing.allocator.free(path_z);
        const alternate_z = try std.testing.allocator.dupeZ(u8, alternate);
        errdefer std.testing.allocator.free(alternate_z);
        const backup_z = try std.testing.allocator.dupeZ(u8, backup);
        errdefer std.testing.allocator.free(backup_z);
        try writeTestFile(std.testing.allocator, path, original);
        return .{
            .tmp = tmp,
            .path = path,
            .alternate = alternate,
            .backup = backup,
            .path_z = path_z,
            .alternate_z = alternate_z,
            .backup_z = backup_z,
            .original = original,
            .replacement = replacement,
            .authority = testRepairAuthority(path, original, replacement),
        };
    }

    fn deinit(self: *@This()) void {
        std.testing.allocator.free(self.path_z);
        std.testing.allocator.free(self.alternate_z);
        std.testing.allocator.free(self.backup_z);
        std.testing.allocator.free(self.path);
        std.testing.allocator.free(self.alternate);
        std.testing.allocator.free(self.backup);
        self.tmp.cleanup();
        self.* = undefined;
    }

    fn pathSwap(self: *@This()) TestPathSwap {
        return .{
            .current = self.path_z.ptr,
            .alternate = self.alternate_z.ptr,
            .backup = self.backup_z.ptr,
        };
    }

    fn expectContent(self: *@This(), expected: []const u8) !void {
        const content = try readTestFile(std.testing.allocator, self.path);
        defer std.testing.allocator.free(content);
        try std.testing.expectEqualStrings(expected, content);
    }
};

fn testRepairAuthority(path: []const u8, original: []const u8, replacement: []const u8) RepairAuthority {
    const next_snapshot_revision = [_]u8{'e'} ** 64;
    const repair_proposal_sha256 = [_]u8{'f'} ** 64;
    const path_sha256 = sha256Hex(path);
    const next_artifact_sha256 = sha256Hex(replacement);
    return .{
        .request_id = [_]u8{'a'} ** 64,
        .proposal_sha256 = [_]u8{'b'} ** 64,
        .snapshot_sha256 = [_]u8{'c'} ** 64,
        .evidence_event_id = [_]u8{'d'} ** 64,
        .evidence_manifest_sha256 = [_]u8{'e'} ** 64,
        .prior_snapshot_revision = [_]u8{'a'} ** 64,
        .next_snapshot_revision = next_snapshot_revision,
        .prior_artifact_sha256 = sha256Hex(original),
        .prior_artifact_revision = [_]u8{'b'} ** 64,
        .next_artifact_sha256 = next_artifact_sha256,
        .next_artifact_revision = deriveArtifactRevision(
            next_artifact_sha256,
            next_snapshot_revision,
            repair_proposal_sha256,
            path_sha256,
        ),
        .repair_proposal_sha256 = repair_proposal_sha256,
    };
}

fn renderRepairTestSnapshot(allocator: std.mem.Allocator, authority: RepairAuthority) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"schema_version\":\"{s}\",\"revision\":\"{s}\",\"state\":{{\"phase\":\"repair_authorized\",\"task_sha256\":\"{s}\",\"actor_run_sha256\":\"{s}\",\"artifact_sha256\":\"{s}\",\"artifact_revision\":\"{s}\",\"verifier_sha256\":\"{s}\",\"policy_sha256\":\"{s}\",\"budget_authority_sha256\":\"{s}\",\"active_provider_authorization_sha256\":\"{s}\",\"transition_revision\":4,\"repair_attempts\":0,\"max_repair_attempts\":3,\"semantic_verdict_sha256\":\"{s}\",\"defect_sha256\":\"{s}\",\"repair_proposal_sha256\":\"{s}\"}}}}",
        .{
            SNAPSHOT_SCHEMA,
            authority.prior_snapshot_revision,
            [_]u8{'a'} ** 64,
            [_]u8{'b'} ** 64,
            authority.prior_artifact_sha256,
            authority.prior_artifact_revision,
            [_]u8{'a'} ** 64,
            [_]u8{'b'} ** 64,
            [_]u8{'c'} ** 64,
            [_]u8{'d'} ** 64,
            [_]u8{'a'} ** 64,
            [_]u8{'b'} ** 64,
            authority.repair_proposal_sha256,
        },
    );
}

fn renderRepairTestProposal(allocator: std.mem.Allocator, authority: RepairAuthority) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"schema_version\":\"{s}\",\"operation\":\"{s}\",\"event\":\"record_repair\",\"expected_phase\":\"repair_authorized\",\"expected_next_phase\":\"repaired\",\"expected_snapshot_revision\":\"{s}\",\"next_snapshot_revision\":\"{s}\",\"provider_authorization_sha256\":\"{s}\",\"semantic_verdict_sha256\":\"{s}\",\"defect_sha256\":\"{s}\",\"repair_proposal_sha256\":\"{s}\",\"next_artifact_sha256\":\"{s}\",\"next_artifact_revision\":\"{s}\"}}",
        .{
            PROPOSAL_SCHEMA,
            OPERATION,
            authority.prior_snapshot_revision,
            authority.next_snapshot_revision,
            zero_hash,
            zero_hash,
            zero_hash,
            zero_hash,
            authority.next_artifact_sha256,
            authority.next_artifact_revision,
        },
    );
}

fn readTestFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const fd = pfs.open(path_z.ptr, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true }, 0);
    if (fd < 0) return error.TestArtifactOpenFailed;
    defer _ = pfs.close(fd);
    const info = try pfs.fileInfo(fd);
    return readOpenArtifact(allocator, fd, info.size, MAX_ARTIFACT_BYTES);
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
