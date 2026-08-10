//! Deterministic internal observer for project-rule runtime impact.
//!
//! The durable tool-observation journal remains the source of truth. This
//! module folds one hash-bound completed Run into exact integer sufficient
//! statistics suitable for internal policy decisions and a future Lean
//! governance checker. It never writes model context, assigns semantic task
//! success, or treats a blocked action as causal benefit without an explicit
//! external outcome label.

const std = @import("std");
const journal_mod = @import("tool_observation_journal.zig");
const observation = @import("../tools/observation.zig");

pub const SCHEMA_VERSION = "metacodes-rule-impact-observation-v3";

pub const OutcomeSource = enum {
    unknown,
    grader,
    user_feedback,
    task_audit,
};

/// Semantic outcome labels are supplied by an external evidence producer.
/// Operational facts below are always derived from the host journal. Unknown
/// is a first-class value: an `end_turn` is not silently promoted to success.
pub const RunLabels = struct {
    outcome_source: OutcomeSource = .unknown,
    task_success: ?bool = null,
    trustworthy_success: ?bool = null,
    drift_detected: ?bool = null,
    cost_microusd: ?u64 = null,
    metered_tokens: ?u64 = null,

    pub fn valid(self: RunLabels) bool {
        if (self.outcome_source == .unknown and
            (self.task_success != null or self.trustworthy_success != null or
                self.drift_detected != null)) return false;
        if (self.trustworthy_success == true and self.task_success != true)
            return false;
        return true;
    }
};

pub const RuleIdentity = struct {
    candidate_id: [64]u8,
    project_sha256: [64]u8,
    bundle_sha256: [64]u8,
    bundle_revision: u64,
};

pub const RuleStats = struct {
    identity: RuleIdentity,
    exposures: u64 = 0,
    pre_exposures: u64 = 0,
    post_exposures: u64 = 0,
    admits: u64 = 0,
    blocks: u64 = 0,
    faults: u64 = 0,
    exact_edit_recovery_directions: u64 = 0,
    exact_edit_recovery_pre_admits: u64 = 0,
    exact_edit_recovery_pre_blocks: u64 = 0,
    exact_edit_recovery_post_admits: u64 = 0,
    exact_edit_recovery_post_blocks: u64 = 0,
    enforced_pre_blocks_before_dispatch: u64 = 0,
    enforced_pre_faults_before_dispatch: u64 = 0,
    shadow_pre_blocks_followed_by_dispatch: u64 = 0,
    shadow_pre_faults_followed_by_dispatch: u64 = 0,
    subsequent_authoritative_successes: u64 = 0,
};

/// Run-level facts are deliberately named as observations, not inferred task
/// outcomes. A later successful dispatch after a block is a recovery signal;
/// only an explicit RunLabels source may call the task recovered/successful.
pub const Snapshot = struct {
    schema_version: []const u8 = SCHEMA_VERSION,
    source_interval_sha256: [64]u8,
    formal_decisions: u64 = 0,
    formal_faults: u64 = 0,
    exact_edit_recovery_directions: u64 = 0,
    exact_edit_recovery_pre_admits: u64 = 0,
    exact_edit_recovery_pre_blocks: u64 = 0,
    exact_edit_recovery_post_admits: u64 = 0,
    exact_edit_recovery_post_blocks: u64 = 0,
    physical_checker_calls: u64 = 0,
    checker_elapsed_ns: u64 = 0,
    authoritative_dispatches: u64 = 0,
    authoritative_successes: u64 = 0,
    authoritative_non_successes: u64 = 0,
    speculative_dispatches: u64 = 0,
    realized_file_changes: u64 = 0,
    invalid_effects: u64 = 0,
    reobservation_failures: u64 = 0,
    enforced_pre_blocks_before_dispatch: u64 = 0,
    enforced_pre_faults_before_dispatch: u64 = 0,
    shadow_pre_blocks_followed_by_dispatch: u64 = 0,
    shadow_pre_faults_followed_by_dispatch: u64 = 0,
    subsequent_authoritative_successes: u64 = 0,
    labels: RunLabels,
    rules: []RuleStats,

    pub fn deinit(self: *Snapshot, allocator: std.mem.Allocator) void {
        allocator.free(self.rules);
        self.* = undefined;
    }
};

const RuleKey = struct {
    candidate_id: [64]u8,
    project_sha256: [64]u8,
    bundle_sha256: [64]u8,
    bundle_revision: u64,
};

const CheckerCall = struct {
    sha256: ?[64]u8,
    elapsed_ns: u64,
};

fn dispatchKey(id: []const u8) [32]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(id, &digest, .{});
    return digest;
}

fn increment(value: *u64) !void {
    value.* = std.math.add(u64, value.*, 1) catch return error.StatsOverflow;
}

fn add(value: *u64, amount: u64) !void {
    value.* = std.math.add(u64, value.*, amount) catch return error.StatsOverflow;
}

fn isRealizedFileChange(effect: ?observation.Effect, effect_valid: bool) bool {
    if (!effect_valid) return false;
    const value = effect orelse return false;
    return switch (value) {
        .file_mutation_v1 => false,
        .file_mutation_v2 => |mutation| mutation.mutation.change == .changed and
            mutation.reobservation.state == .matched,
    };
}

fn reobservationFailed(effect: ?observation.Effect, effect_valid: bool) bool {
    if (!effect_valid) return false;
    const value = effect orelse return false;
    return switch (value) {
        .file_mutation_v1 => true,
        .file_mutation_v2 => |mutation| mutation.reobservation.state != .matched,
    };
}

/// Fold a fully validated, completed journal interval. The caller owns the
/// returned rule slice and can serialize this Snapshot as a bounded formal
/// observer input. The fixed-size identity key avoids slice-key lifetime bugs.
pub fn derive(
    allocator: std.mem.Allocator,
    run: *const journal_mod.LoadedRunDispatches,
    labels: RunLabels,
) !Snapshot {
    if (!labels.valid()) return error.InvalidRunLabels;
    var snapshot = Snapshot{
        .source_interval_sha256 = run.interval_sha256,
        .labels = labels,
        .rules = &.{},
    };
    errdefer if (snapshot.rules.len != 0) allocator.free(snapshot.rules);

    var dispatches = std.AutoHashMap([32]u8, usize).init(allocator);
    defer dispatches.deinit();
    for (run.dispatches, 0..) |dispatch, index| {
        try dispatches.put(dispatchKey(dispatch.id), index);
        if (dispatch.origin == .authoritative) {
            try increment(&snapshot.authoritative_dispatches);
            if (dispatch.outcome == .succeeded)
                try increment(&snapshot.authoritative_successes)
            else
                try increment(&snapshot.authoritative_non_successes);
        } else {
            try increment(&snapshot.speculative_dispatches);
        }
        if (!dispatch.effect_valid) try increment(&snapshot.invalid_effects);
        if (isRealizedFileChange(dispatch.effect, dispatch.effect_valid))
            try increment(&snapshot.realized_file_changes);
        if (reobservationFailed(dispatch.effect, dispatch.effect_valid))
            try increment(&snapshot.reobservation_failures);
    }

    var rules: std.ArrayList(RuleStats) = .empty;
    defer rules.deinit(allocator);
    var rule_indexes = std.AutoHashMap(RuleKey, usize).init(allocator);
    defer rule_indexes.deinit();
    // One formal journal event represents one physical checker process call;
    // all candidates in a batch share its sequence. Request bytes alone are
    // not a call id because two repeated calls may be byte-identical.
    var checker_calls = std.AutoHashMap(u64, CheckerCall).init(allocator);
    defer checker_calls.deinit();
    var earliest_enforced_stop: ?u64 = null;
    var rule_stop_sequences: std.ArrayList(?u64) = .empty;
    defer rule_stop_sequences.deinit(allocator);

    for (run.formal_decisions) |decision| {
        try increment(&snapshot.formal_decisions);
        if (decision.result == .fault) try increment(&snapshot.formal_faults);

        const checker = try checker_calls.getOrPut(decision.sequence);
        if (!checker.found_existing) {
            checker.value_ptr.* = .{
                .sha256 = decision.checker_call_sha256,
                .elapsed_ns = decision.checker_elapsed_ns,
            };
            try increment(&snapshot.physical_checker_calls);
            try add(&snapshot.checker_elapsed_ns, decision.checker_elapsed_ns);
        } else if (!std.meta.eql(checker.value_ptr.*, CheckerCall{
            .sha256 = decision.checker_call_sha256,
            .elapsed_ns = decision.checker_elapsed_ns,
        })) {
            return error.InconsistentCheckerCall;
        }

        const key = RuleKey{
            .candidate_id = decision.candidate_id,
            .project_sha256 = decision.project_sha256,
            .bundle_sha256 = decision.bundle_sha256,
            .bundle_revision = decision.bundle_revision,
        };
        const entry = try rule_indexes.getOrPut(key);
        if (!entry.found_existing) {
            entry.value_ptr.* = rules.items.len;
            try rules.append(allocator, .{ .identity = .{
                .candidate_id = key.candidate_id,
                .project_sha256 = key.project_sha256,
                .bundle_sha256 = key.bundle_sha256,
                .bundle_revision = key.bundle_revision,
            } });
            try rule_stop_sequences.append(allocator, null);
        }
        const rule_index = entry.value_ptr.*;
        const rule = &rules.items[rule_index];
        try increment(&rule.exposures);
        switch (decision.phase) {
            .pre => try increment(&rule.pre_exposures),
            .post => try increment(&rule.post_exposures),
        }
        switch (decision.result) {
            .admit => try increment(&rule.admits),
            .block => try increment(&rule.blocks),
            .fault => try increment(&rule.faults),
        }
        if (decision.recovery_action == .edit_existing_file_exact) {
            if (decision.phase != .pre or decision.result != .block)
                return error.InvalidRecoveryDirection;
            if (decision.operation == .pre_decision) {
                try increment(&rule.exact_edit_recovery_directions);
                try increment(&snapshot.exact_edit_recovery_directions);
            }
        }
        switch (decision.operation) {
            .recovery_pre_decision => switch (decision.result) {
                .admit => {
                    try increment(&rule.exact_edit_recovery_pre_admits);
                    try increment(&snapshot.exact_edit_recovery_pre_admits);
                },
                .block => {
                    try increment(&rule.exact_edit_recovery_pre_blocks);
                    try increment(&snapshot.exact_edit_recovery_pre_blocks);
                },
                .fault => {},
            },
            .recovery_post_decision => switch (decision.result) {
                .admit => {
                    try increment(&rule.exact_edit_recovery_post_admits);
                    try increment(&snapshot.exact_edit_recovery_post_admits);
                },
                .block => {
                    try increment(&rule.exact_edit_recovery_post_blocks);
                    try increment(&snapshot.exact_edit_recovery_post_blocks);
                },
                .fault => {},
            },
            .pre_decision, .post_decision => {},
        }

        if (decision.phase == .pre and decision.result != .admit) {
            const dispatched = dispatches.contains(dispatchKey(decision.dispatch_id));
            if (decision.actuation == .enforced and !dispatched) {
                if (decision.result == .block) {
                    try increment(&rule.enforced_pre_blocks_before_dispatch);
                    try increment(&snapshot.enforced_pre_blocks_before_dispatch);
                } else {
                    try increment(&rule.enforced_pre_faults_before_dispatch);
                    try increment(&snapshot.enforced_pre_faults_before_dispatch);
                }
                earliest_enforced_stop = if (earliest_enforced_stop) |current|
                    @min(current, decision.sequence)
                else
                    decision.sequence;
                rule_stop_sequences.items[rule_index] = if (rule_stop_sequences.items[rule_index]) |current|
                    @min(current, decision.sequence)
                else
                    decision.sequence;
            } else if (decision.actuation == .shadow and dispatched) {
                if (decision.result == .block) {
                    try increment(&rule.shadow_pre_blocks_followed_by_dispatch);
                    try increment(&snapshot.shadow_pre_blocks_followed_by_dispatch);
                } else {
                    try increment(&rule.shadow_pre_faults_followed_by_dispatch);
                    try increment(&snapshot.shadow_pre_faults_followed_by_dispatch);
                }
            }
        }
    }

    if (earliest_enforced_stop) |blocked_sequence| {
        for (run.dispatches) |dispatch| {
            if (dispatch.origin == .authoritative and dispatch.outcome == .succeeded and
                dispatch.started_sequence > blocked_sequence)
                try increment(&snapshot.subsequent_authoritative_successes);
        }
        for (rules.items, rule_stop_sequences.items) |*rule, maybe_stopped| {
            const stopped = maybe_stopped orelse continue;
            for (run.dispatches) |dispatch| {
                if (dispatch.origin == .authoritative and dispatch.outcome == .succeeded and
                    dispatch.started_sequence > stopped)
                    try increment(&rule.subsequent_authoritative_successes);
            }
        }
    }

    snapshot.rules = try rules.toOwnedSlice(allocator);
    return snapshot;
}

pub fn render(allocator: std.mem.Allocator, snapshot: Snapshot) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, snapshot, .{});
}

test "rule impact labels preserve unknown instead of guessing success" {
    try std.testing.expect((RunLabels{}).valid());
    try std.testing.expect(!((RunLabels{ .task_success = true }).valid()));
    try std.testing.expect(!((RunLabels{
        .outcome_source = .grader,
        .task_success = false,
        .trustworthy_success = true,
    }).valid()));
    try std.testing.expect((RunLabels{
        .outcome_source = .grader,
        .task_success = true,
        .trustworthy_success = true,
        .drift_detected = false,
        .cost_microusd = 123,
        .metered_tokens = 456,
    }).valid());
}
