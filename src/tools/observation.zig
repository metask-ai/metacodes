//! UI-independent observations from the one real tool-dispatch seam.
//!
//! `tool_start` / `tool_result` describe a model attempt and its conversation
//! pairing. They are useful UI/evaluation events, but they are not proof that
//! the tool implementation actually ran. This protocol is emitted directly
//! around `tool_exec.executeOne`'s dispatch call instead.
//!
//! Tools may attach one versioned typed effect to the terminal observation.
//! Effects are evidence only: neither a tool nor an observation sink can grant
//! permission, promote a Lean rule, or authorize a follow-up mutation.

const std = @import("std");

pub const SCHEMA_VERSION = "metacodes-tool-observation-v1";
pub const FORMAL_SCHEMA_VERSION_V1 = "metacodes-project-formal-decision-v1";
pub const FORMAL_BATCH_SCHEMA_VERSION_V1 = "metacodes-project-formal-decision-batch-v1";
pub const FORMAL_SCHEMA_VERSION = "metacodes-project-formal-decision-v2";
pub const FORMAL_BATCH_SCHEMA_VERSION_V2 = "metacodes-project-formal-decision-batch-v2";
pub const FORMAL_BATCH_SCHEMA_VERSION_V3 = "metacodes-project-formal-decision-batch-v3";
pub const FORMAL_BATCH_SCHEMA_VERSION_V4 = "metacodes-project-formal-decision-batch-v4";
pub const FORMAL_BATCH_SCHEMA_VERSION = "metacodes-project-formal-decision-batch-v5";
pub const RULE_FILTER_SCHEMA_VERSION = "metacodes-project-rule-filter-v1";
pub const RULE_COVERAGE_GAP_SCHEMA_VERSION = "metacodes-project-rule-coverage-gap-v1";

pub const Origin = enum {
    authoritative,
    speculative_prefetch,
};

pub const Outcome = enum {
    succeeded,
    tool_error,
    pending,
    host_failed,
    host_rejected,
    host_fatal,
};

pub const FormalPhase = enum { pre, post };
pub const FormalResult = enum { admit, block, fault };

/// The exact fixed-kernel operation that produced a candidate verdict. Phase
/// alone is insufficient once a recovery transition and an ordinary rule are
/// evaluated in the same physical checker batch.
pub const FormalOperation = enum {
    pre_decision,
    post_decision,
    recovery_pre_decision,
    recovery_post_decision,

    pub fn phase(self: FormalOperation) FormalPhase {
        return switch (self) {
            .pre_decision, .recovery_pre_decision => .pre,
            .post_decision, .recovery_post_decision => .post,
        };
    }

    pub fn isRecovery(self: FormalOperation) bool {
        return switch (self) {
            .recovery_pre_decision, .recovery_post_decision => true,
            .pre_decision, .post_decision => false,
        };
    }
};

/// A bounded next-action direction selected by the fixed formal kernel.  It is
/// evidence about the verdict, not an authorization to bypass the ordinary
/// gate on the next tool call.
pub const FormalRecoveryAction = enum {
    none,
    edit_existing_file_exact,
};

/// Separates the fixed kernel's counterfactual decision from whether the host
/// applies it to the real dispatch.  Production gates are always `enforced`;
/// an isolated evaluation Run may use `shadow` to record the identical verdict
/// while deliberately leaving the tool trajectory unchanged.
pub const FormalActuation = enum { enforced, shadow };

/// Host-side relevance pruning is deliberately not a formal decision. It can
/// only erase candidates for which the fixed Lean theorem proves both phases
/// admit; every remaining candidate still traverses the sidecar.
pub const RuleFilterOperation = enum {
    ordinary,
    exact_edit_recovery,
};

/// Host-observed state of an operation's file target immediately before the
/// formal gate.  It is carried in the dispatch journal so a later replay can
/// reconstruct why the fixed kernel admitted or blocked without storing the
/// plaintext path.
pub const FileTargetState = enum {
    unobserved,
    missing,
    regular_existing,
    other_existing,
    unavailable,
};

pub const FormalCandidateDecision = struct {
    operation: FormalOperation = .pre_decision,
    result: FormalResult,
    recovery_action: FormalRecoveryAction = .none,
    candidate_id: [64]u8,
    request_sha256: [64]u8,
    verdict_sha256: ?[64]u8,
    checker_failure: ?[]const u8,
};

pub const BeforeState = enum {
    missing,
    known,
    unknown,
};

pub const ChangeState = enum {
    changed,
    unchanged,
    unknown,
};

/// First operation-specific signal. Literal paths and file contents are not
/// included; the observation carries commitments and exact byte counts. A path
/// hash is a commitment, not an anonymity guarantee against dictionary attacks.
/// This effect describes the target file only, not every auxiliary side effect
/// of the surrounding tool (for example parent-directory creation).
pub const FileMutationV1 = struct {
    path_sha256: [64]u8,
    before_state: BeforeState,
    before_sha256: [64]u8,
    after_sha256: [64]u8,
    before_bytes: usize,
    after_bytes: usize,
    change: ChangeState,
};

pub const ReobservationState = enum {
    matched,
    mismatched,
    unavailable,
};

/// Host re-read performed after the tool implementation returned and before
/// its terminal dispatch observation was accepted. The plaintext path remains
/// in the per-dispatch slot and never enters the journal.
pub const FileReobservationV1 = struct {
    state: ReobservationState,
    observed_sha256: [64]u8,
    observed_bytes: usize,
};

pub const FileMutationV2 = struct {
    mutation: FileMutationV1,
    reobservation: FileReobservationV1,
};

pub const Effect = union(enum) {
    file_mutation_v1: FileMutationV1,
    file_mutation_v2: FileMutationV2,
};

/// Per-dispatch stack slot. A tool can publish at most one effect. A second
/// publication does not overwrite the first; it marks the evidence invalid so
/// the terminal observation cannot silently bless an ambiguous effect set.
pub const EffectSlot = struct {
    effect: ?Effect = null,
    valid: bool = true,
    /// Stable per-dispatch copy. Tool-local normalized path buffers are freed
    /// before dispatch returns, so retaining a borrowed slice here would make
    /// post-action re-observation read dangling memory.
    file_path: [std.fs.max_path_bytes]u8 = undefined,
    file_path_len: usize = 0,

    pub fn record(self: *EffectSlot, effect: Effect) void {
        if (self.effect != null) {
            self.valid = false;
            return;
        }
        self.effect = effect;
    }

    pub fn recordFileMutation(self: *EffectSlot, path: []const u8, effect: FileMutationV1) void {
        if (self.effect != null or self.file_path_len != 0 or path.len == 0 or path.len > self.file_path.len) {
            self.valid = false;
            return;
        }
        @memcpy(self.file_path[0..path.len], path);
        self.file_path_len = path.len;
        self.effect = .{ .file_mutation_v1 = effect };
    }

    pub fn filePath(self: *const EffectSlot) ?[]const u8 {
        if (self.file_path_len == 0) return null;
        return self.file_path[0..self.file_path_len];
    }
};

pub const Event = union(enum) {
    /// A dispatch produced a governed effect class while **zero** active rules
    /// targeted its tool. The rule plane did not fail here — it was never
    /// consulted, because rule applicability is keyed on the tool name while
    /// the obligation is about the effect. An advisory plane (memory, prompt)
    /// that shifts the action distribution can therefore move traffic off the
    /// enforced plane silently. Emit that as a first-class signal instead of
    /// leaving it to be reconstructed from transcripts after the fact.
    rule_coverage_gap: struct {
        schema_version: []const u8 = RULE_COVERAGE_GAP_SCHEMA_VERSION,
        dispatch_id: []const u8,
        tool: []const u8,
        effect_class: []const u8,
        project_sha256: [64]u8,
        bundle_sha256: [64]u8,
        bundle_revision: u64,
        active_rule_count: u32,
        /// Always zero when this event is emitted; kept explicit so a reader
        /// never has to infer the absence.
        matching_rule_count: u32 = 0,
    },
    rule_filter: struct {
        schema_version: []const u8 = RULE_FILTER_SCHEMA_VERSION,
        dispatch_id: []const u8,
        phase: FormalPhase,
        operation: RuleFilterOperation,
        project_sha256: [64]u8,
        bundle_sha256: [64]u8,
        bundle_revision: u64,
        kernel_sha256: [64]u8,
        active_rule_count: u32,
        checker_rule_count: u32,
        /// During exact-Edit recovery the source Write rule is deliberately
        /// retained despite its ordinary target mismatch. This is therefore a
        /// prune count, not the raw number of mismatching targets.
        statically_pruned_rule_count: u32,
        proof: []const u8 = "MetaCodesControl.ProjectRule.target_tool_mismatch_admits_both",
    },
    formal_decision: struct {
        // This is an additive journal event with a separate schema. Reusing
        // the dispatch-v1 label made a new authority-bearing payload look like
        // an old observation record and obscured forward-compatibility audits.
        schema_version: []const u8 = FORMAL_SCHEMA_VERSION,
        dispatch_id: []const u8,
        phase: FormalPhase,
        actuation: FormalActuation = .enforced,
        file_target_state: FileTargetState = .unobserved,
        result: FormalResult,
        candidate_id: [64]u8,
        project_sha256: [64]u8,
        bundle_sha256: [64]u8,
        bundle_revision: u64,
        kernel_sha256: [64]u8,
        request_sha256: [64]u8,
        /// Identity and cardinality of the physical checker process call.
        /// Single-request legacy events omit the identity and default to one;
        /// batch consumers deduplicate latency by this hash instead of
        /// incorrectly summing the same process time once per candidate.
        checker_call_sha256: ?[64]u8 = null,
        checker_verdict_sha256: ?[64]u8 = null,
        checker_batch_size: u32 = 1,
        verdict_sha256: ?[64]u8,
        checker_failure: ?[]const u8,
        checker_elapsed_ns: u64,
        checker_bytes: u64,
    },
    formal_decision_batch: struct {
        schema_version: []const u8 = FORMAL_BATCH_SCHEMA_VERSION,
        dispatch_id: []const u8,
        phase: FormalPhase,
        actuation: FormalActuation = .enforced,
        file_target_state: FileTargetState = .unobserved,
        project_sha256: [64]u8,
        bundle_sha256: [64]u8,
        bundle_revision: u64,
        kernel_sha256: [64]u8,
        checker_call_sha256: [64]u8,
        checker_verdict_sha256: ?[64]u8,
        checker_batch_size: u32,
        checker_elapsed_ns: u64,
        checker_bytes: u64,
        decisions: []const FormalCandidateDecision,
    },
    dispatch_started: struct {
        schema_version: []const u8 = SCHEMA_VERSION,
        id: []const u8,
        requested_name: []const u8,
        dispatched_name: []const u8,
        origin: Origin,
        agent_depth: u8,
        input_bytes: usize,
        input_sha256: [64]u8,
        file_target_state: FileTargetState = .unobserved,
    },
    dispatch_finished: struct {
        schema_version: []const u8 = SCHEMA_VERSION,
        id: []const u8,
        requested_name: []const u8,
        dispatched_name: []const u8,
        origin: Origin,
        agent_depth: u8,
        outcome: Outcome,
        error_code: ?[]const u8,
        elapsed_ms: u64,
        result_present: bool,
        result_bytes: usize,
        result_sha256: [64]u8,
        effect: ?Effect,
        effect_valid: bool,
    },
};

/// The callback can be invoked concurrently by tool workers and speculative
/// prefetch. Implementations must synchronize their own state and consume all
/// borrowed slices before returning. `false` is a fail-closed control signal:
/// a rejected start prevents dispatch; a rejected finish poisons the run after
/// the already-observed real-world outcome.
pub const Sink = struct {
    ctx: *anyopaque,
    emitFn: *const fn (ctx: *anyopaque, event: Event) bool,

    pub fn emit(self: Sink, event: Event) bool {
        return self.emitFn(self.ctx, event);
    }
};

pub const BeforeContent = union(BeforeState) {
    missing,
    known: []const u8,
    unknown,
};

pub fn fileMutation(path: []const u8, before: BeforeContent, after: []const u8) Effect {
    var before_sha256 = [_]u8{'0'} ** 64;
    var before_bytes: usize = 0;
    const change: ChangeState = switch (before) {
        .missing => .changed,
        .unknown => .unknown,
        .known => |bytes| blk: {
            before_sha256 = sha256Hex(bytes);
            before_bytes = bytes.len;
            break :blk if (std.mem.eql(u8, bytes, after)) .unchanged else .changed;
        },
    };
    return .{ .file_mutation_v1 = .{
        .path_sha256 = sha256Hex(path),
        .before_state = std.meta.activeTag(before),
        .before_sha256 = before_sha256,
        .after_sha256 = sha256Hex(after),
        .before_bytes = before_bytes,
        .after_bytes = after.len,
        .change = change,
    } };
}

pub fn sha256Hex(bytes: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

test "tool observation: file mutation evidence preserves unknown pre-state" {
    const created = fileMutation("/private/a", .missing, "new").file_mutation_v1;
    try std.testing.expect(created.before_state == .missing);
    try std.testing.expect(created.change == .changed);
    try std.testing.expectEqual(@as(usize, 3), created.after_bytes);

    const unchanged = fileMutation("/private/a", .{ .known = "same" }, "same").file_mutation_v1;
    try std.testing.expect(unchanged.before_state == .known);
    try std.testing.expect(unchanged.change == .unchanged);
    try std.testing.expectEqualSlices(u8, &unchanged.before_sha256, &unchanged.after_sha256);

    const unknown = fileMutation("/private/a", .unknown, "new").file_mutation_v1;
    try std.testing.expect(unknown.before_state == .unknown);
    try std.testing.expect(unknown.change == .unknown);
}

test "tool observation: effect slot rejects ambiguous double publication" {
    var slot = EffectSlot{};
    slot.record(fileMutation("/a", .missing, "one"));
    slot.record(fileMutation("/a", .missing, "two"));
    try std.testing.expect(slot.effect != null);
    try std.testing.expect(!slot.valid);
}
