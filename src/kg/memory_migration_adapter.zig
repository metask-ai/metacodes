//! Metacodes-owned atomic memory-migration transaction controller.
//!
//! This module is deliberately transport-agnostic: the caller supplies the
//! narrow versioned TinyKG storage primitives and this adapter owns ordering,
//! schema validation, hash binding, Lean invocation, full snapshot
//! re-observation, commit receipt audit, and post-state audit.  It never falls
//! back to ordinary `add-edge` or property commands.

const std = @import("std");
const formal = @import("../formal/memory_migration.zig");
const runtime = @import("../formal/runtime.zig");
const provenance = @import("../formal/provenance.zig");
const artifact_store = @import("../formal/artifact_store.zig");
const time = @import("../util/time.zig");
const AbortSignal = @import("../util/abort.zig").AbortSignal;

pub const SNAPSHOT_CAPABILITY = "tinykg-memory-migration-snapshot-v1";
pub const COMMIT_CAPABILITY = "tinykg-memory-migration-commit-v1";
pub const ROLLBACK_CAPABILITY = "tinykg-memory-migration-rollback-v1";
pub const COMMIT_REQUEST_SCHEMA = "tinykg-memory-migration-commit-v1";
pub const COMMIT_RECEIPT_SCHEMA = "tinykg-memory-migration-receipt-v1";
pub const POST_STATE_SCHEMA = "tinykg-memory-migration-post-state-v1";
pub const PIPELINE_RECEIPT_SCHEMA = "metacodes-memory-migration-transaction-receipt-v1";
const MAX_PAYLOAD_BYTES: usize = 64 * 1024;

pub const Source = struct {
    source_id: u64,
    replacement_id: u64,
    evidence_id: u64,
};

/// Narrow storage actuator supplied by TinyKG. Atomicity here means the final
/// conditional mutation is indivisible at one Store generation; Metacodes
/// still owns the complete governed transaction around it.
pub const StoragePrimitives = struct {
    ptr: *anyopaque,
    capabilities_fn: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) anyerror![]u8,
    snapshot_fn: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, source: Source) anyerror![]u8,
    commit_fn: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, request: []const u8) anyerror![]u8,
    post_state_fn: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, rollback_token: []const u8) anyerror![]u8,

    pub fn capabilities(self: StoragePrimitives, allocator: std.mem.Allocator) ![]u8 {
        return self.capabilities_fn(self.ptr, allocator);
    }
    pub fn snapshot(self: StoragePrimitives, allocator: std.mem.Allocator, source: Source) ![]u8 {
        return self.snapshot_fn(self.ptr, allocator, source);
    }
    pub fn commit(self: StoragePrimitives, allocator: std.mem.Allocator, request: []const u8) ![]u8 {
        return self.commit_fn(self.ptr, allocator, request);
    }
    pub fn postState(self: StoragePrimitives, allocator: std.mem.Allocator, rollback_token: []const u8) ![]u8 {
        return self.post_state_fn(self.ptr, allocator, rollback_token);
    }
};

pub const Result = struct {
    allocator: std.mem.Allocator,
    initial_snapshot: []u8,
    proposal: []u8,
    reobserved_snapshot: []u8,
    commit_request: []u8,
    commit_receipt: []u8,
    post_state: []u8,
    pipeline_receipt: []u8,
    evaluation: formal.Evaluation,

    pub fn deinit(self: *Result) void {
        self.evaluation.deinit();
        self.allocator.free(self.initial_snapshot);
        self.allocator.free(self.proposal);
        self.allocator.free(self.reobserved_snapshot);
        self.allocator.free(self.commit_request);
        self.allocator.free(self.commit_receipt);
        self.allocator.free(self.post_state);
        self.allocator.free(self.pipeline_receipt);
        self.* = undefined;
    }
};

pub const Prepared = struct {
    allocator: std.mem.Allocator,
    source: Source,
    build_id: []u8,
    initial_snapshot: []u8,
    proposal: []u8,
    reobserved_snapshot: []u8,
    commit_request: []u8,
    evaluation: formal.Evaluation,
    /// Once the host crosses into TinyKG's mutating primitive, the outcome is
    /// no longer safely replayable from this value.  Keep the prepared bytes
    /// for audit/deinit, but reject every second side-effect attempt.
    commit_attempted: bool = false,
    transferred: bool = false,

    pub fn deinit(self: *Prepared) void {
        if (self.transferred) {
            self.* = undefined;
            return;
        }
        self.evaluation.deinit();
        self.allocator.free(self.build_id);
        self.allocator.free(self.initial_snapshot);
        self.allocator.free(self.proposal);
        self.allocator.free(self.reobserved_snapshot);
        self.allocator.free(self.commit_request);
        self.* = undefined;
    }
};

pub const PersistedEvidence = struct {
    allocator: std.mem.Allocator,
    event_id: [64]u8,
    manifest_sha256: [64]u8,
    receipt_sha256: [64]u8,
    index_persisted: bool,

    pub fn deinit(self: *PersistedEvidence) void {
        self.* = undefined;
    }
};

/// Persist the complete successful transaction as one immutable paper-data
/// bundle. `pipeline_receipt` is explicitly mechanism evidence and never
/// claims a task-quality improvement by itself.
pub fn persistEvidence(
    allocator: std.mem.Allocator,
    index_path: []const u8,
    result: *const Result,
    started_wall_ns: i128,
    started_monotonic_ns: i128,
) !PersistedEvidence {
    const event_id = artifact_store.newEventId(
        started_wall_ns,
        started_monotonic_ns,
        result.evaluation.request_id[0..],
    );
    const persisted = try artifact_store.persist(
        allocator,
        index_path,
        event_id,
        result.pipeline_receipt,
        .{
            .snapshot = result.initial_snapshot,
            .proposal = result.proposal,
            .request = result.evaluation.request,
            .verdict = result.evaluation.invocation.verdict_payload,
            .checker_stdout = result.evaluation.invocation.stdout,
            .checker_stderr = result.evaluation.invocation.stderr,
            .checker_provenance = if (result.evaluation.provenance) |loaded| loaded.raw else null,
            .checker_build_receipt = if (result.evaluation.provenance) |loaded| loaded.build_receipt_raw else null,
            .reobserved_snapshot = result.reobserved_snapshot,
            .commit_request = result.commit_request,
            .commit_receipt = result.commit_receipt,
            .post_state = result.post_state,
        },
        .{
            .started_wall_ns = started_wall_ns,
            .request_id = result.evaluation.request_id[0..],
            .snapshot_revision = result.evaluation.snapshot_revision[0..],
            .pipeline_admitted = true,
            .failure_kind = "none",
        },
    );
    return .{
        .allocator = allocator,
        .event_id = event_id,
        .manifest_sha256 = persisted.manifest_sha256,
        .receipt_sha256 = persisted.receipt_sha256,
        .index_persisted = persisted.index_persisted,
    };
}

const CapabilityDocument = struct {
    schema_version: []const u8,
    capabilities: []const []const u8,
    build_id: []const u8,
};

const RawCommitReceipt = struct {
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

const RawPostState = struct {
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

const SnapshotSourceBinding = struct {
    source: struct { id: u64 },
    replacement: struct { id: u64 },
    evidence: struct { id: u64 },
};

const ParsedReceipt = std.json.Parsed(RawCommitReceipt);
const ParsedPostState = std.json.Parsed(RawPostState);

/// Execute the complete transaction.  Every failure before `commit_fn` has no
/// TinyKG side effect.  A transport error after `commit_fn` is intentionally
/// surfaced as an indeterminate commit; callers must inspect by request id and
/// must never issue a fresh semantic migration automatically.
pub fn execute(
    allocator: std.mem.Allocator,
    transport: StoragePrimitives,
    source: Source,
    config: runtime.Config,
    abort: ?*const AbortSignal,
) !Result {
    var prepared = try prepare(allocator, transport, source, config, abort);
    defer prepared.deinit();
    return commitPrepared(transport, &prepared);
}

/// Complete every read-only and Lean-governed step and produce the exact
/// commit bytes. A host can persist these bytes before calling
/// `commitPrepared`, giving crash recovery an immutable request id instead of
/// asking an LLM to reconstruct a proposal.
pub fn prepare(
    allocator: std.mem.Allocator,
    transport: StoragePrimitives,
    source: Source,
    config: runtime.Config,
    abort: ?*const AbortSignal,
) !Prepared {
    if (source.source_id == 0 or source.replacement_id == 0 or source.evidence_id == 0 or
        source.source_id == source.replacement_id or source.source_id == source.evidence_id or
        source.replacement_id == source.evidence_id)
        return error.InvalidMigrationSource;

    const capability_bytes = try transport.capabilities(allocator);
    defer allocator.free(capability_bytes);
    const build_id = try validateCapabilities(allocator, capability_bytes);
    errdefer allocator.free(build_id);

    const initial_raw = try transport.snapshot(allocator, source);
    defer allocator.free(initial_raw);
    const initial_snapshot = try formal.canonicalizeSnapshot(allocator, initial_raw);
    errdefer allocator.free(initial_snapshot);
    try validateSourceBinding(allocator, initial_snapshot, source);
    const proposal = try formal.buildProposalForSnapshot(allocator, initial_snapshot);
    errdefer allocator.free(proposal);

    var evaluation = try formal.evaluate(allocator, initial_snapshot, proposal, config, abort);
    errdefer evaluation.deinit();
    if (!evaluation.checkerAdmitted()) return error.CheckerBlocked;

    const reobserved_raw = try transport.snapshot(allocator, source);
    defer allocator.free(reobserved_raw);
    const reobserved_snapshot = try formal.canonicalizeSnapshot(allocator, reobserved_raw);
    errdefer allocator.free(reobserved_snapshot);
    const gate = try evaluation.commitGateSnapshot(allocator, reobserved_snapshot, true);
    if (gate != .ready_for_cas) return gateError(gate);

    const commit_request = try renderCommitRequest(allocator, &evaluation, source, build_id);
    errdefer allocator.free(commit_request);
    return .{
        .allocator = allocator,
        .source = source,
        .build_id = build_id,
        .initial_snapshot = initial_snapshot,
        .proposal = proposal,
        .reobserved_snapshot = reobserved_snapshot,
        .commit_request = commit_request,
        .evaluation = evaluation,
    };
}

/// Execute only the atomic side-effect boundary using a prepared request.
/// Any failure from the first call into TinyKG onward is indeterminate and
/// must be resolved by request-id inspection/rollback, never automatic retry.
pub fn commitPrepared(
    transport: StoragePrimitives,
    prepared: *Prepared,
) !Result {
    if (prepared.transferred or prepared.commit_attempted)
        return error.PreparedAlreadyConsumed;
    // Set this before entering the transport.  A returned error may mean the
    // provider/TinyKG accepted the mutation and the response was lost.
    prepared.commit_attempted = true;
    const allocator = prepared.allocator;
    const source = prepared.source;
    const build_id = prepared.build_id;
    const evaluation = &prepared.evaluation;
    const commit_request = prepared.commit_request;
    const commit_receipt_raw = transport.commit(allocator, commit_request) catch
        return error.IndeterminateCommit;
    defer allocator.free(commit_receipt_raw);
    const commit_receipt = canonicalizeAndValidateReceipt(
        allocator,
        commit_receipt_raw,
        evaluation,
        source,
        build_id,
    ) catch return error.IndeterminateCommit;
    errdefer allocator.free(commit_receipt);
    var parsed_receipt = parseReceipt(allocator, commit_receipt) catch
        return error.IndeterminateCommit;
    defer parsed_receipt.deinit();

    const post_state_raw = transport.postState(allocator, parsed_receipt.value.rollback_token) catch
        return error.IndeterminateCommit;
    defer allocator.free(post_state_raw);
    const post_state = canonicalizeAndValidatePostState(
        allocator,
        post_state_raw,
        parsed_receipt.value,
        source,
        build_id,
    ) catch return error.IndeterminateCommit;
    errdefer allocator.free(post_state);
    const pipeline_receipt = renderPipelineReceipt(
        allocator,
        evaluation,
        commit_request,
        commit_receipt,
        post_state,
        build_id,
    ) catch return error.IndeterminateCommit;
    errdefer allocator.free(pipeline_receipt);

    const result: Result = .{
        .allocator = allocator,
        .initial_snapshot = prepared.initial_snapshot,
        .proposal = prepared.proposal,
        .reobserved_snapshot = prepared.reobserved_snapshot,
        .commit_request = prepared.commit_request,
        .commit_receipt = commit_receipt,
        .post_state = post_state,
        .pipeline_receipt = pipeline_receipt,
        .evaluation = prepared.evaluation,
    };
    // Transfer all prepared ownership into Result only after the complete
    // post-state has been audited successfully.
    allocator.free(prepared.build_id);
    prepared.build_id = &.{};
    prepared.initial_snapshot = &.{};
    prepared.proposal = &.{};
    prepared.reobserved_snapshot = &.{};
    prepared.commit_request = &.{};
    prepared.evaluation = undefined;
    prepared.transferred = true;
    return result;
}

fn validateCapabilities(allocator: std.mem.Allocator, encoded: []const u8) ![]u8 {
    if (encoded.len == 0 or encoded.len > MAX_PAYLOAD_BYTES) return error.InvalidCapabilities;
    var parsed = std.json.parseFromSlice(CapabilityDocument, allocator, encoded, .{
        .ignore_unknown_fields = false,
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    }) catch return error.InvalidCapabilities;
    defer parsed.deinit();
    if (!std.mem.eql(u8, parsed.value.schema_version, "tinykg-capabilities-v1") or
        !validBuildId(parsed.value.build_id)) return error.InvalidCapabilities;
    var snapshot = false;
    var commit = false;
    var rollback = false;
    for (parsed.value.capabilities, 0..) |candidate, index| {
        for (parsed.value.capabilities[0..index]) |prior| {
            if (std.mem.eql(u8, prior, candidate)) return error.InvalidCapabilities;
        }
        if (std.mem.eql(u8, candidate, SNAPSHOT_CAPABILITY)) snapshot = true;
        if (std.mem.eql(u8, candidate, COMMIT_CAPABILITY)) commit = true;
        if (std.mem.eql(u8, candidate, ROLLBACK_CAPABILITY)) rollback = true;
    }
    if (!snapshot or !commit or !rollback) return error.AtomicMigrationUnavailable;
    // Do not return a slice owned by the parser arena.
    return allocator.dupe(u8, parsed.value.build_id);
}

fn validateSourceBinding(
    allocator: std.mem.Allocator,
    canonical_snapshot: []const u8,
    source: Source,
) !void {
    var parsed = std.json.parseFromSlice(SnapshotSourceBinding, allocator, canonical_snapshot, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidSnapshot,
    };
    defer parsed.deinit();
    if (parsed.value.source.id != source.source_id or
        parsed.value.replacement.id != source.replacement_id or
        parsed.value.evidence.id != source.evidence_id)
        return error.SnapshotSourceMismatch;
}

fn renderCommitRequest(
    allocator: std.mem.Allocator,
    evaluation: *const formal.Evaluation,
    source: Source,
    build_id: []const u8,
) ![]u8 {
    const verdict_payload = evaluation.invocation.verdict_payload orelse return error.MissingCheckerVerdict;
    const verdict_sha256 = formal.payloadSha256(verdict_payload);
    return std.fmt.allocPrint(
        allocator,
        "{{\"schema_version\":\"{s}\",\"operation\":\"{s}\",\"request_id\":\"{s}\",\"expected_revision\":\"{s}\",\"snapshot_sha256\":\"{s}\",\"proposal_sha256\":\"{s}\",\"checker_verdict_sha256\":\"{s}\",\"source_id\":{d},\"replacement_id\":{d},\"evidence_id\":{d},\"effect\":\"{s}\",\"rollback\":\"{s}\",\"expected_build_id\":\"{s}\"}}",
        .{ COMMIT_REQUEST_SCHEMA, formal.OPERATION, evaluation.request_id[0..], evaluation.snapshot_revision[0..], evaluation.snapshot_sha256[0..], evaluation.proposal_sha256[0..], verdict_sha256[0..], source.source_id, source.replacement_id, source.evidence_id, formal.EFFECT, formal.ROLLBACK, build_id },
    );
}

fn parseReceipt(allocator: std.mem.Allocator, encoded: []const u8) !ParsedReceipt {
    if (encoded.len == 0 or encoded.len > MAX_PAYLOAD_BYTES) return error.InvalidCommitReceipt;
    return std.json.parseFromSlice(RawCommitReceipt, allocator, encoded, .{
        .ignore_unknown_fields = false,
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    }) catch return error.InvalidCommitReceipt;
}

fn canonicalizeAndValidateReceipt(
    allocator: std.mem.Allocator,
    encoded: []const u8,
    evaluation: *const formal.Evaluation,
    source: Source,
    build_id: []const u8,
) ![]u8 {
    var parsed = try parseReceipt(allocator, encoded);
    defer parsed.deinit();
    const receipt = parsed.value;
    const verdict_payload = evaluation.invocation.verdict_payload orelse return error.MissingCheckerVerdict;
    const verdict_sha256 = formal.payloadSha256(verdict_payload);
    if (!std.mem.eql(u8, receipt.schema_version, COMMIT_RECEIPT_SCHEMA) or
        !std.mem.eql(u8, receipt.operation, formal.OPERATION) or
        !std.mem.eql(u8, receipt.request_id, evaluation.request_id[0..]) or
        !std.mem.eql(u8, receipt.proposal_sha256, evaluation.proposal_sha256[0..]) or
        !std.mem.eql(u8, receipt.checker_verdict_sha256, verdict_sha256[0..]) or
        !std.mem.eql(u8, receipt.snapshot_sha256, evaluation.snapshot_sha256[0..]) or
        !std.mem.eql(u8, receipt.previous_revision, evaluation.snapshot_revision[0..]) or
        parseHex64(receipt.revision) == null or
        std.mem.eql(u8, receipt.revision, receipt.previous_revision) or
        receipt.source_id != source.source_id or receipt.replacement_id != source.replacement_id or
        receipt.evidence_id != source.evidence_id or
        !std.mem.eql(u8, receipt.effect, formal.EFFECT) or
        !std.mem.eql(u8, receipt.rollback, formal.ROLLBACK) or !receipt.committed or
        !validToken(receipt.rollback_token, 128) or
        !std.mem.eql(u8, receipt.build_id, build_id)) return error.InvalidCommitReceipt;
    return renderCommitReceipt(allocator, receipt);
}

fn renderCommitReceipt(allocator: std.mem.Allocator, receipt: RawCommitReceipt) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"schema_version\":\"{s}\",\"operation\":\"{s}\",\"request_id\":\"{s}\",\"proposal_sha256\":\"{s}\",\"checker_verdict_sha256\":\"{s}\",\"snapshot_sha256\":\"{s}\",\"previous_revision\":\"{s}\",\"revision\":\"{s}\",\"source_id\":{d},\"replacement_id\":{d},\"evidence_id\":{d},\"effect\":\"{s}\",\"rollback\":\"{s}\",\"committed\":{s},\"rollback_token\":\"{s}\",\"build_id\":\"{s}\"}}",
        .{ receipt.schema_version, receipt.operation, receipt.request_id, receipt.proposal_sha256, receipt.checker_verdict_sha256, receipt.snapshot_sha256, receipt.previous_revision, receipt.revision, receipt.source_id, receipt.replacement_id, receipt.evidence_id, receipt.effect, receipt.rollback, boolText(receipt.committed), receipt.rollback_token, receipt.build_id },
    );
}

fn canonicalizeAndValidatePostState(
    allocator: std.mem.Allocator,
    encoded: []const u8,
    receipt: RawCommitReceipt,
    source: Source,
    build_id: []const u8,
) ![]u8 {
    if (encoded.len == 0 or encoded.len > MAX_PAYLOAD_BYTES) return error.InvalidPostState;
    var parsed = std.json.parseFromSlice(RawPostState, allocator, encoded, .{
        .ignore_unknown_fields = false,
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    }) catch return error.InvalidPostState;
    defer parsed.deinit();
    const post = parsed.value;
    if (!std.mem.eql(u8, post.schema_version, POST_STATE_SCHEMA) or
        !std.mem.eql(u8, post.revision, receipt.revision) or
        post.source_id != source.source_id or post.replacement_id != source.replacement_id or
        post.evidence_id != source.evidence_id or !post.deprecated_edge_exists or
        !post.source_retrieval_excluded or !post.replacement_current_generation or
        !post.evidence_present or !std.mem.eql(u8, post.rollback_token, receipt.rollback_token) or
        !std.mem.eql(u8, post.build_id, build_id)) return error.InvalidPostState;
    return std.fmt.allocPrint(
        allocator,
        "{{\"schema_version\":\"{s}\",\"revision\":\"{s}\",\"source_id\":{d},\"replacement_id\":{d},\"evidence_id\":{d},\"deprecated_edge_exists\":true,\"source_retrieval_excluded\":true,\"replacement_current_generation\":true,\"evidence_present\":true,\"rollback_token\":\"{s}\",\"build_id\":\"{s}\"}}",
        .{ POST_STATE_SCHEMA, post.revision, post.source_id, post.replacement_id, post.evidence_id, post.rollback_token, post.build_id },
    );
}

fn renderPipelineReceipt(
    allocator: std.mem.Allocator,
    evaluation: *const formal.Evaluation,
    commit_request: []const u8,
    commit_receipt: []const u8,
    post_state: []const u8,
    build_id: []const u8,
) ![]u8 {
    const verdict_payload = evaluation.invocation.verdict_payload orelse return error.MissingCheckerVerdict;
    const verdict_sha256 = formal.payloadSha256(verdict_payload);
    const request_sha256 = formal.payloadSha256(commit_request);
    const receipt_sha256 = formal.payloadSha256(commit_receipt);
    const post_sha256 = formal.payloadSha256(post_state);
    const checker_binary_sha256 = evaluation.invocation.actual_checker_sha256;
    return std.fmt.allocPrint(
        allocator,
        "{{\"schema_version\":\"{s}\",\"operation\":\"{s}\",\"request_id\":\"{s}\",\"snapshot_sha256\":\"{s}\",\"proposal_sha256\":\"{s}\",\"checker_verdict_sha256\":\"{s}\",\"checker_binary_sha256\":\"{s}\",\"tinykg_build_id\":\"{s}\",\"commit_request_sha256\":\"{s}\",\"commit_receipt_sha256\":\"{s}\",\"post_state_sha256\":\"{s}\",\"lean_admitted\":true,\"snapshot_reobserved\":true,\"atomic_commit_verified\":true,\"post_state_verified\":true,\"rollback_ready\":true,\"quality_evidence\":false}}",
        .{ PIPELINE_RECEIPT_SCHEMA, formal.OPERATION, evaluation.request_id[0..], evaluation.snapshot_sha256[0..], evaluation.proposal_sha256[0..], verdict_sha256[0..], checker_binary_sha256[0..], build_id, request_sha256[0..], receipt_sha256[0..], post_sha256[0..] },
    );
}

fn gateError(gate: formal.CommitGate) anyerror {
    return switch (gate) {
        .ready_for_cas => unreachable,
        .checker_blocked => error.CheckerBlocked,
        .provenance_invalid => error.ProvenanceInvalid,
        .stale_revision => error.StaleRevision,
        .snapshot_drift => error.SnapshotDrift,
        .cas_unavailable => error.AtomicMigrationUnavailable,
    };
}

fn parseHex64(value: []const u8) ?[64]u8 {
    if (value.len != 64) return null;
    var result: [64]u8 = undefined;
    for (value, 0..) |byte, index| {
        if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return null;
        result[index] = byte;
    }
    return result;
}

fn validBuildId(value: []const u8) bool {
    return value.len == 71 and std.mem.startsWith(u8, value, "sha256:") and parseHex64(value[7..]) != null;
}

fn validToken(value: []const u8, max: usize) bool {
    if (value.len == 0 or value.len > max) return false;
    for (value) |byte| switch (byte) {
        'a'...'z', 'A'...'Z', '0'...'9', '-', '_', '.', ':' => {},
        else => return false,
    };
    return true;
}

fn boolText(value: bool) []const u8 {
    return if (value) "true" else "false";
}
