//! Runtime adapter from a verified active bundle to the fixed Lean kernel.
//! Zig may erase target-tool mismatches using one fixed-kernel equivalence
//! theorem, but it never reimplements an applicable rule's authorization.

const std = @import("std");
const bundle_mod = @import("project_rule_bundle.zig");
const spec_mod = @import("project_rule_spec.zig");
const kernel = @import("../formal/project_harness_runtime.zig");
const protocol = @import("../tools/project_rule_gate.zig");
const observation = @import("../tools/observation.zig");
const pfs = @import("platform").fs;
const sync = @import("platform").sync;

pub const RUNTIME_VERDICT_PREFIX = "project-rule-runtime-verdict-";
pub const RUNTIME_BATCH_VERDICT_PREFIX = "project-rule-runtime-batch-verdict-";

const BatchDecision = struct {
    result: protocol.Result,
    recovery_action: protocol.RecoveryAction = .none,
    recovery_rule_index: ?usize = null,
    recovery_rule_result: ?protocol.Result = null,
};

const MAX_EXACT_EDIT_OBLIGATIONS: usize = 32;
const MAX_INFLIGHT_EXACT_EDITS: usize = 32;

const ExactEditObligation = struct {
    rule_index: usize,
    target_sha256: [64]u8,
    source_content_sha256: [64]u8,
    blocked_content_sha256: [64]u8,
};

const InflightExactEdit = struct {
    dispatch_sha256: [64]u8,
    target_sha256: [64]u8,
    pre: spec_mod.RecoveryPreSignal,
};

const RecoveryMatch = struct {
    obligation: ExactEditObligation,
    pre: spec_mod.RecoveryPreSignal,
};

pub const RuntimeGate = struct {
    mutex: sync.Mutex = .{},
    allocator: std.mem.Allocator,
    active: *const bundle_mod.LoadedActive,
    config: kernel.Config,
    abort: ?*const @import("../util/abort.zig").AbortSignal,
    /// Production construction leaves this at `enforced`.  Evaluation-only
    /// callers may select `shadow`: the same kernel call and durable verdict
    /// are produced, but the protocol result is projected to `admit` so the
    /// counterfactual decision cannot change the observed tool trajectory.
    actuation: observation.FormalActuation = .enforced,
    evidence_dir: ?[]const u8 = null,
    observation_sink: ?observation.Sink = null,
    /// Product construction enables deterministic host synthesis of the
    /// Lean-selected exact Edit.  Direct/embedding construction defaults off
    /// so adopting a RuntimeGate does not silently change tool-call shape.
    /// The synthesized call still re-enters this gate and cannot dispatch
    /// without a separate recovery-pre admission.
    auto_exact_edit_recovery: bool = false,
    exact_edit_obligations: [MAX_EXACT_EDIT_OBLIGATIONS]ExactEditObligation = undefined,
    exact_edit_obligations_len: usize = 0,
    inflight_exact_edits: [MAX_INFLIGHT_EXACT_EDITS]InflightExactEdit = undefined,
    inflight_exact_edits_len: usize = 0,

    pub fn protocolGate(self: *RuntimeGate) protocol.Gate {
        return .{
            .ctx = @ptrCast(self),
            .preFn = preThunk,
            .postFn = postThunk,
            .cancelPreFn = cancelPreThunk,
        };
    }

    fn preThunk(raw: *anyopaque, signal: protocol.PreSignal) protocol.PreResult {
        const self: *RuntimeGate = @ptrCast(@alignCast(raw));
        self.mutex.lock();
        defer self.mutex.unlock();
        if (signal.exact_edit_material.writeNeedsEdit() and
            self.exact_edit_obligations_len == self.exact_edit_obligations.len)
        {
            const target = signal.exact_edit_material.target_sha256.?;
            if (self.findExactEditObligation(target) == null) return .fault;
        }
        if (self.recoveryPreFacts(signal)) |facts| {
            const dispatch_sha256 = observation.sha256Hex(signal.dispatch_id);
            if (self.findInflightDispatch(dispatch_sha256) != null or
                self.findInflightTarget(facts.obligation.target_sha256) != null or
                self.inflight_exact_edits_len == self.inflight_exact_edits.len)
                return .fault;
            const decision = self.decideExactRecoveryPre(signal, facts) catch
                return .fault;
            const actuated = self.actuatePre(decision);
            if (self.actuation == .enforced and actuated == .admit) {
                if (decision.recovery_rule_result != .admit) return .fault;
                self.inflight_exact_edits[self.inflight_exact_edits_len] = .{
                    .dispatch_sha256 = dispatch_sha256,
                    .target_sha256 = facts.obligation.target_sha256,
                    .pre = facts.pre,
                };
                self.inflight_exact_edits_len += 1;
                return .admit_exact_edit;
            }
            // A recovery-pre block without the same bounded recovery direction
            // means the source-bound obligation is no longer retryable (most
            // importantly, the source snapshot drifted).  Do not leave stale
            // authority in memory that could become usable again if bytes later
            // happen to cycle back to the old digest.  A retry-eligible typo is
            // the only blocking result that preserves the obligation.
            if (self.actuation == .enforced and
                decision.result == .block and
                decision.recovery_action != .edit_existing_file_exact)
            {
                const obligation_index = self.findExactEditObligation(
                    facts.obligation.target_sha256,
                ) orelse return .fault;
                self.removeExactEditObligation(obligation_index);
            }
            return actuated;
        }
        const decision = self.decidePre(signal) catch return .fault;
        const actuated = self.actuatePre(decision);
        if (self.actuation == .enforced and decision.result == .block and
            decision.recovery_action == .edit_existing_file_exact)
        {
            const material = signal.exact_edit_material;
            const rule_index = decision.recovery_rule_index orelse return .fault;
            if (!material.writeNeedsEdit()) return .fault;
            const obligation = ExactEditObligation{
                .rule_index = rule_index,
                .target_sha256 = material.target_sha256.?,
                .source_content_sha256 = material.current_sha256.?,
                .blocked_content_sha256 = material.write_content_sha256.?,
            };
            if (self.findInflightTarget(obligation.target_sha256) != null or
                !self.installExactEditObligation(obligation))
                return .fault;
            if (self.auto_exact_edit_recovery)
                return .synthesize_exact_edit;
        }
        return actuated;
    }

    fn postThunk(raw: *anyopaque, signal: protocol.PostSignal) protocol.Result {
        const self: *RuntimeGate = @ptrCast(@alignCast(raw));
        self.mutex.lock();
        defer self.mutex.unlock();
        const dispatch_sha256 = observation.sha256Hex(signal.pre.dispatch_id);
        if (self.findInflightDispatch(dispatch_sha256)) |inflight_index| {
            const inflight = self.inflight_exact_edits[inflight_index];
            defer self.removeInflightExactEdit(inflight_index);
            const obligation_index = self.findExactEditObligation(
                inflight.target_sha256,
            ) orelse return .fault;
            const obligation = self.exact_edit_obligations[obligation_index];
            // `admit_exact_edit` is a linear, single-dispatch capability. Once
            // the real dispatcher has started, consume the source-bound
            // obligation regardless of tool outcome, post-checker failure, or
            // re-observation result. Retaining it after a failed/raced dispatch
            // would permit an old authorization to become usable again after
            // an ABA content cycle. A retry must begin with a fresh Write,
            // fresh host observation, and fresh Lean pre-admission.
            defer self.removeExactEditObligation(obligation_index);
            const observed_matches = observedMatchesBlocked(
                signal.effect,
                obligation.target_sha256,
                obligation.blocked_content_sha256,
            );
            const recovery_post = spec_mod.RecoveryPostSignal{
                .pre = inflight.pre,
                .succeeded = signal.outcome == .succeeded,
                .effect_valid = signal.effect_valid,
                .has_file_mutation_v1 = hasFileMutation(signal.effect),
                .post_reobserved = postReobserved(signal.effect),
                .observed_matches_blocked = observed_matches,
            };
            const decision = self.decideExactRecoveryPost(
                signal,
                obligation.rule_index,
                recovery_post,
            ) catch return .fault;
            return self.actuateResult(decision.result);
        }
        const decision = self.decidePost(signal) catch return .fault;
        return self.actuateResult(decision.result);
    }

    fn cancelPreThunk(raw: *anyopaque, signal: protocol.PreSignal) bool {
        const self: *RuntimeGate = @ptrCast(@alignCast(raw));
        self.mutex.lock();
        defer self.mutex.unlock();
        const dispatch_sha256 = observation.sha256Hex(signal.dispatch_id);
        const inflight_index = self.findInflightDispatch(dispatch_sha256) orelse
            return false;
        const target_sha256 = self.inflight_exact_edits[inflight_index].target_sha256;
        const obligation_index = self.findExactEditObligation(target_sha256) orelse {
            self.removeInflightExactEdit(inflight_index);
            return false;
        };
        self.removeInflightExactEdit(inflight_index);
        // A rejected evidence start poisons the governed Run. Do not leave the
        // already-issued recovery capability available to a caller that
        // incorrectly continues after the host-fatal result.
        self.removeExactEditObligation(obligation_index);
        return true;
    }

    fn actuateResult(self: *const RuntimeGate, decision: protocol.Result) protocol.Result {
        return if (self.actuation == .shadow) .admit else decision;
    }

    fn actuatePre(self: *const RuntimeGate, decision: BatchDecision) protocol.PreResult {
        if (self.actuation == .shadow) return .admit;
        return switch (decision.result) {
            .admit => .admit,
            .block => .{ .block = decision.recovery_action },
            .fault => .fault,
        };
    }

    fn decidePre(self: *RuntimeGate, signal: protocol.PreSignal) !BatchDecision {
        const formal_signal = spec_mod.PreSignal{
            .tool = signal.tool,
            .input_bytes = signal.input_bytes,
            .agent_depth = signal.agent_depth,
            .authoritative = signal.authoritative,
            .file_target_state = signal.file_target_state,
            .exact_recovery_material_ready = signal.exact_edit_material.writeNeedsEdit(),
        };
        const matching = self.matchingRuleCount(signal.tool);
        if (matching == 0) {
            if (!self.recordRuleFilter(signal.dispatch_id, .pre, .ordinary, 0))
                return .{ .result = .fault };
            return .{ .result = .admit };
        }
        const signal_json = try std.json.Stringify.valueAlloc(self.allocator, formal_signal, .{});
        defer self.allocator.free(signal_json);
        const requests = try self.allocator.alloc(kernel.Request, matching);
        defer self.allocator.free(requests);
        const bindings = try self.allocator.alloc(kernel.Bindings, matching);
        defer self.allocator.free(bindings);
        const request_ids = try self.allocator.alloc([64]u8, matching);
        defer self.allocator.free(request_ids);
        var index: usize = 0;
        for (self.active.rules) |entry| {
            if (!std.mem.eql(u8, entry.rule_spec.target_tool, signal.tool)) continue;
            const candidate_id = parseHex(entry.candidate_id) orelse return error.InvalidCandidateId;
            request_ids[index] = kernel.requestId(
                .pre_decision,
                candidate_id,
                self.active.bundle_sha256,
                self.active.revision,
                signal_json,
            );
            requests[index] = .{
                .request_id = request_ids[index][0..],
                .operation = .pre_decision,
                .kernel_sha256 = self.active.kernel_sha256[0..],
                .candidate_id = entry.candidate_id,
                .project_sha256 = self.active.project_sha256[0..],
                .bundle_sha256 = self.active.bundle_sha256[0..],
                .bundle_revision = self.active.revision,
                .rule_spec = entry.rule_spec,
                .payload = .{ .pre = formal_signal },
            };
            bindings[index] = .{
                .request_id = request_ids[index],
                .operation = .pre_decision,
                .kernel_sha256 = self.active.kernel_sha256,
                .candidate_id = candidate_id,
                .project_sha256 = self.active.project_sha256,
                .bundle_sha256 = self.active.bundle_sha256,
                .bundle_revision = self.active.revision,
            };
            index += 1;
        }
        std.debug.assert(index == matching);
        var batch = try kernel.invokeBatch(
            self.allocator,
            self.config,
            requests,
            bindings,
            self.abort,
        );
        defer batch.deinit(self.allocator);
        return self.recordBatch(
            signal.dispatch_id,
            .pre,
            signal.file_target_state,
            &batch,
            .ordinary,
        );
    }

    fn decidePost(self: *RuntimeGate, signal: protocol.PostSignal) !BatchDecision {
        const formal_pre = spec_mod.PreSignal{
            .tool = signal.pre.tool,
            .input_bytes = signal.pre.input_bytes,
            .agent_depth = signal.pre.agent_depth,
            .authoritative = signal.pre.authoritative,
            .file_target_state = signal.pre.file_target_state,
            .exact_recovery_material_ready = signal.pre.exact_edit_material.writeNeedsEdit(),
        };
        const formal_signal = spec_mod.PostSignal{
            .pre = formal_pre,
            .succeeded = signal.outcome == .succeeded,
            .effect_valid = signal.effect_valid,
            .has_file_mutation_v1 = hasFileMutation(signal.effect),
            .post_reobserved = postReobserved(signal.effect),
        };
        const matching = self.matchingRuleCount(signal.pre.tool);
        if (matching == 0) {
            if (!self.recordRuleFilter(signal.pre.dispatch_id, .post, .ordinary, 0))
                return .{ .result = .fault };
            // Admitting here is correct — no rule claims this tool — but if the
            // dispatch nevertheless produced a governed effect, the obligation
            // was met by nobody. Report the gap; do not change the verdict, so
            // instrumentation can never become a covert enforcement path.
            if (governedEffectClass(signal.effect)) |effect_class| {
                if (!self.recordCoverageGap(
                    signal.pre.dispatch_id,
                    signal.pre.tool,
                    effect_class,
                )) return .{ .result = .fault };
            }
            return .{ .result = .admit };
        }
        const signal_json = try std.json.Stringify.valueAlloc(self.allocator, formal_signal, .{});
        defer self.allocator.free(signal_json);
        const requests = try self.allocator.alloc(kernel.Request, matching);
        defer self.allocator.free(requests);
        const bindings = try self.allocator.alloc(kernel.Bindings, matching);
        defer self.allocator.free(bindings);
        const request_ids = try self.allocator.alloc([64]u8, matching);
        defer self.allocator.free(request_ids);
        var index: usize = 0;
        for (self.active.rules) |entry| {
            if (!std.mem.eql(u8, entry.rule_spec.target_tool, signal.pre.tool)) continue;
            const candidate_id = parseHex(entry.candidate_id) orelse return error.InvalidCandidateId;
            request_ids[index] = kernel.requestId(
                .post_decision,
                candidate_id,
                self.active.bundle_sha256,
                self.active.revision,
                signal_json,
            );
            requests[index] = .{
                .request_id = request_ids[index][0..],
                .operation = .post_decision,
                .kernel_sha256 = self.active.kernel_sha256[0..],
                .candidate_id = entry.candidate_id,
                .project_sha256 = self.active.project_sha256[0..],
                .bundle_sha256 = self.active.bundle_sha256[0..],
                .bundle_revision = self.active.revision,
                .rule_spec = entry.rule_spec,
                .payload = .{ .post = formal_signal },
            };
            bindings[index] = .{
                .request_id = request_ids[index],
                .operation = .post_decision,
                .kernel_sha256 = self.active.kernel_sha256,
                .candidate_id = candidate_id,
                .project_sha256 = self.active.project_sha256,
                .bundle_sha256 = self.active.bundle_sha256,
                .bundle_revision = self.active.revision,
            };
            index += 1;
        }
        std.debug.assert(index == matching);
        var batch = try kernel.invokeBatch(
            self.allocator,
            self.config,
            requests,
            bindings,
            self.abort,
        );
        defer batch.deinit(self.allocator);
        return self.recordBatch(
            signal.pre.dispatch_id,
            .post,
            signal.pre.file_target_state,
            &batch,
            .ordinary,
        );
    }

    fn recoveryPreFacts(
        self: *const RuntimeGate,
        signal: protocol.PreSignal,
    ) ?RecoveryMatch {
        if (!std.mem.eql(u8, signal.tool, "Edit")) return null;
        const material = signal.exact_edit_material;
        const target = material.target_sha256 orelse return null;
        const obligation_index = self.findExactEditObligation(target) orelse return null;
        const obligation = self.exact_edit_obligations[obligation_index];
        const current = material.current_sha256;
        const old = material.edit_old_sha256;
        const new = material.edit_new_sha256;
        return .{ .obligation = obligation, .pre = .{
            .tool = signal.tool,
            .input_bytes = signal.input_bytes,
            .agent_depth = signal.agent_depth,
            .authoritative = signal.authoritative,
            .target_matches = true,
            .material_available = material.editReady(),
            .current_matches_source = current != null and std.mem.eql(
                u8,
                &current.?,
                &obligation.source_content_sha256,
            ),
            .old_matches_current = current != null and old != null and
                std.mem.eql(u8, &current.?, &old.?),
            .new_matches_blocked = new != null and
                std.mem.eql(u8, &new.?, &obligation.blocked_content_sha256),
        } };
    }

    /// Evaluate the recovery transition and every Edit-targeted active rule in
    /// one physical checker call. The obligation's source Write rule changes
    /// operation and is retained explicitly; target-mismatched ordinary rules
    /// are erased by the same theorem-backed relevance pass as normal tools.
    fn decideExactRecoveryPre(
        self: *RuntimeGate,
        signal: protocol.PreSignal,
        recovery: RecoveryMatch,
    ) !BatchDecision {
        if (recovery.obligation.rule_index >= self.active.rules.len)
            return error.InvalidRecoveryRule;
        const ordinary = spec_mod.PreSignal{
            .tool = signal.tool,
            .input_bytes = signal.input_bytes,
            .agent_depth = signal.agent_depth,
            .authoritative = signal.authoritative,
            .file_target_state = signal.file_target_state,
            .exact_recovery_material_ready = false,
        };
        const ordinary_json = try std.json.Stringify.valueAlloc(
            self.allocator,
            ordinary,
            .{},
        );
        defer self.allocator.free(ordinary_json);
        const recovery_json = try std.json.Stringify.valueAlloc(
            self.allocator,
            recovery.pre,
            .{},
        );
        defer self.allocator.free(recovery_json);
        return self.decideMixed(
            signal.dispatch_id,
            signal.file_target_state,
            .pre,
            recovery.obligation.rule_index,
            .pre_decision,
            .{ .pre = ordinary },
            ordinary_json,
            .recovery_pre_decision,
            .{ .recovery_pre = recovery.pre },
            recovery_json,
        );
    }

    fn decideExactRecoveryPost(
        self: *RuntimeGate,
        signal: protocol.PostSignal,
        rule_index: usize,
        recovery: spec_mod.RecoveryPostSignal,
    ) !BatchDecision {
        if (rule_index >= self.active.rules.len) return error.InvalidRecoveryRule;
        const ordinary_pre = spec_mod.PreSignal{
            .tool = signal.pre.tool,
            .input_bytes = signal.pre.input_bytes,
            .agent_depth = signal.pre.agent_depth,
            .authoritative = signal.pre.authoritative,
            .file_target_state = signal.pre.file_target_state,
            .exact_recovery_material_ready = false,
        };
        const ordinary = spec_mod.PostSignal{
            .pre = ordinary_pre,
            .succeeded = signal.outcome == .succeeded,
            .effect_valid = signal.effect_valid,
            .has_file_mutation_v1 = hasFileMutation(signal.effect),
            .post_reobserved = postReobserved(signal.effect),
        };
        const ordinary_json = try std.json.Stringify.valueAlloc(
            self.allocator,
            ordinary,
            .{},
        );
        defer self.allocator.free(ordinary_json);
        const recovery_json = try std.json.Stringify.valueAlloc(
            self.allocator,
            recovery,
            .{},
        );
        defer self.allocator.free(recovery_json);
        return self.decideMixed(
            signal.pre.dispatch_id,
            signal.pre.file_target_state,
            .post,
            rule_index,
            .post_decision,
            .{ .post = ordinary },
            ordinary_json,
            .recovery_post_decision,
            .{ .recovery_post = recovery },
            recovery_json,
        );
    }

    fn decideMixed(
        self: *RuntimeGate,
        dispatch_id: []const u8,
        file_target_state: observation.FileTargetState,
        phase: observation.FormalPhase,
        rule_index: usize,
        ordinary_operation: kernel.Operation,
        ordinary_payload: kernel.Payload,
        ordinary_signal_json: []const u8,
        recovery_operation: kernel.Operation,
        recovery_payload: kernel.Payload,
        recovery_signal_json: []const u8,
    ) !BatchDecision {
        if (rule_index >= self.active.rules.len) return error.InvalidRecoveryRule;
        var checker_rule_count: usize = 1;
        for (self.active.rules, 0..) |entry, index| {
            if (index != rule_index and
                std.mem.eql(u8, entry.rule_spec.target_tool, ordinaryTool(ordinary_payload)))
                checker_rule_count += 1;
        }
        const requests = try self.allocator.alloc(kernel.Request, checker_rule_count);
        defer self.allocator.free(requests);
        const bindings = try self.allocator.alloc(kernel.Bindings, checker_rule_count);
        defer self.allocator.free(bindings);
        const request_ids = try self.allocator.alloc([64]u8, checker_rule_count);
        defer self.allocator.free(request_ids);
        var request_index: usize = 0;
        // The source-bound recovery obligation is the prerequisite for this
        // host-synthesized transition, so it must be the first recorded
        // verdict even when an older Edit rule precedes it in bundle order.
        // The remaining applicable rules preserve their relative order.
        for (0..2) |pass| {
            for (self.active.rules, 0..) |entry, index| {
                const is_recovery = index == rule_index;
                if ((pass == 0) != is_recovery) continue;
                if (!is_recovery and
                    !std.mem.eql(u8, entry.rule_spec.target_tool, ordinaryTool(ordinary_payload)))
                    continue;
                const candidate_id = parseHex(entry.candidate_id) orelse
                    return error.InvalidCandidateId;
                const operation = if (is_recovery) recovery_operation else ordinary_operation;
                const payload = if (is_recovery) recovery_payload else ordinary_payload;
                const signal_json = if (is_recovery) recovery_signal_json else ordinary_signal_json;
                request_ids[request_index] = kernel.requestId(
                    operation,
                    candidate_id,
                    self.active.bundle_sha256,
                    self.active.revision,
                    signal_json,
                );
                requests[request_index] = .{
                    .request_id = request_ids[request_index][0..],
                    .operation = operation,
                    .kernel_sha256 = self.active.kernel_sha256[0..],
                    .candidate_id = entry.candidate_id,
                    .project_sha256 = self.active.project_sha256[0..],
                    .bundle_sha256 = self.active.bundle_sha256[0..],
                    .bundle_revision = self.active.revision,
                    .rule_spec = entry.rule_spec,
                    .payload = payload,
                };
                bindings[request_index] = .{
                    .request_id = request_ids[request_index],
                    .operation = operation,
                    .kernel_sha256 = self.active.kernel_sha256,
                    .candidate_id = candidate_id,
                    .project_sha256 = self.active.project_sha256,
                    .bundle_sha256 = self.active.bundle_sha256,
                    .bundle_revision = self.active.revision,
                };
                request_index += 1;
            }
        }
        std.debug.assert(request_index == checker_rule_count);
        var batch = try kernel.invokeBatch(
            self.allocator,
            self.config,
            requests,
            bindings,
            self.abort,
        );
        defer batch.deinit(self.allocator);
        return self.recordBatch(
            dispatch_id,
            phase,
            file_target_state,
            &batch,
            .exact_edit_recovery,
        );
    }

    fn recordBatch(
        self: *RuntimeGate,
        dispatch_id: []const u8,
        phase: observation.FormalPhase,
        file_target_state: observation.FileTargetState,
        batch: *const kernel.BatchInvocation,
        filter_operation: observation.RuleFilterOperation,
    ) BatchDecision {
        // A production gate must publish both the payload and its journal
        // binding.  Test-only direct gates may deliberately configure neither.
        if ((self.evidence_dir != null) != (self.observation_sink != null))
            return .{ .result = .fault };
        if (!self.recordRuleFilter(
            dispatch_id,
            phase,
            filter_operation,
            batch.invocations.len,
        )) return .{ .result = .fault };
        var decision_count: usize = 0;
        var result = protocol.Result.admit;
        var recovery_action = protocol.RecoveryAction.none;
        var recovery_rule_index: ?usize = null;
        var recovery_rule_result: ?protocol.Result = null;
        for (batch.invocations) |invocation| {
            decision_count += 1;
            if (invocation.failure != .none or invocation.verdict == null) {
                result = .fault;
                if (invocation.bindings) |bindings| {
                    if (isRecoveryOperation(bindings.operation))
                        recovery_rule_result = .fault;
                }
                break;
            }
            if (invocation.bindings) |bindings| {
                if (isRecoveryOperation(bindings.operation)) {
                    recovery_rule_result = if (invocation.verdict.?.admitted)
                        .admit
                    else
                        .block;
                }
            }
            if (!invocation.verdict.?.admitted) {
                result = .block;
                recovery_action = switch (invocation.verdict.?.recovery_action) {
                    .none => .none,
                    .edit_existing_file_exact => .edit_existing_file_exact,
                };
                if (recovery_action != .none and invocation.bindings != null)
                    recovery_rule_index = self.ruleIndex(invocation.bindings.?.candidate_id);
                break;
            }
        }
        if (decision_count == 0) return .{ .result = .fault };
        if (self.evidence_dir) |directory| {
            if (batch.verdict_payload) |payload| {
                const verdict_sha = batch.verdict_sha256 orelse return .{ .result = .fault };
                persistRuntimeBatchVerdict(directory, verdict_sha, payload) catch
                    return .{ .result = .fault };
            }
        }
        const sink = self.observation_sink orelse return .{
            .result = result,
            .recovery_action = recovery_action,
            .recovery_rule_index = recovery_rule_index,
            .recovery_rule_result = recovery_rule_result,
        };
        const decisions = self.allocator.alloc(observation.FormalCandidateDecision, decision_count) catch
            return .{ .result = .fault };
        defer self.allocator.free(decisions);
        for (batch.invocations[0..decision_count], decisions) |invocation, *decision| {
            decision.* = .{
                .operation = formalOperation(invocation.bindings.?.operation),
                .result = if (invocation.failure != .none)
                    .fault
                else if (invocation.verdict != null and invocation.verdict.?.admitted)
                    .admit
                else
                    .block,
                .recovery_action = if (invocation.verdict) |verdict| switch (verdict.recovery_action) {
                    .none => .none,
                    .edit_existing_file_exact => .edit_existing_file_exact,
                } else .none,
                .candidate_id = invocation.bindings.?.candidate_id,
                .request_sha256 = invocation.request_sha256,
                .verdict_sha256 = invocation.verdict_sha256,
                .checker_failure = if (invocation.failure == .none)
                    null
                else
                    @tagName(invocation.failure),
            };
        }
        const first = &batch.invocations[0];
        const checker_call_sha256 = physicalCheckerCallIdentity(
            first.checker_call_sha256 orelse return .{ .result = .fault },
            dispatch_id,
            phase,
        );
        if (!sink.emit(.{ .formal_decision_batch = .{
            .dispatch_id = dispatch_id,
            .phase = phase,
            .actuation = self.actuation,
            .file_target_state = file_target_state,
            .project_sha256 = self.active.project_sha256,
            .bundle_sha256 = self.active.bundle_sha256,
            .bundle_revision = self.active.revision,
            .kernel_sha256 = self.active.kernel_sha256,
            .checker_call_sha256 = checker_call_sha256,
            .checker_verdict_sha256 = batch.verdict_sha256,
            .checker_batch_size = first.checker_batch_size,
            .checker_elapsed_ns = first.checker_elapsed_ns,
            .checker_bytes = first.checker_bytes,
            .decisions = decisions,
        } })) return .{ .result = .fault };
        return .{
            .result = result,
            .recovery_action = recovery_action,
            .recovery_rule_index = recovery_rule_index,
            .recovery_rule_result = recovery_rule_result,
        };
    }

    fn ruleIndex(self: *const RuntimeGate, candidate_id: [64]u8) ?usize {
        for (self.active.rules, 0..) |entry, index| {
            const parsed = parseHex(entry.candidate_id) orelse continue;
            if (std.mem.eql(u8, &parsed, &candidate_id)) return index;
        }
        return null;
    }

    /// Governed effect classes. A rule bundle expresses obligations about the
    /// *effect* ("do not rewrite an existing file out from under its reader"),
    /// but rule applicability is keyed on the tool name. Any other route to the
    /// same effect is therefore outside every rule's reach — not denied, simply
    /// never evaluated. Name the class so the gap is reportable.
    fn governedEffectClass(effect: ?observation.Effect) ?[]const u8 {
        const value = effect orelse return null;
        const mutation = switch (value) {
            .file_mutation_v1 => |m| m,
            .file_mutation_v2 => |m| m.mutation,
        };
        if (mutation.before_state == .known and mutation.change == .changed)
            return "existing_file_rewritten";
        return null;
    }

    fn matchingRuleCount(self: *const RuntimeGate, tool: []const u8) usize {
        var count: usize = 0;
        for (self.active.rules) |entry| {
            if (std.mem.eql(u8, entry.rule_spec.target_tool, tool)) count += 1;
        }
        return count;
    }

    /// Report a dispatch that produced a governed effect while zero active
    /// rules targeted its tool. This is the signal that an advisory plane
    /// (memory/prompt) has routed work around the enforced plane: the rule
    /// never fired because it was never consulted. Without it the bypass is
    /// only recoverable by reading transcripts after the fact.
    fn recordCoverageGap(
        self: *const RuntimeGate,
        dispatch_id: []const u8,
        tool: []const u8,
        effect_class: []const u8,
    ) bool {
        if ((self.evidence_dir != null) != (self.observation_sink != null)) return false;
        const sink = self.observation_sink orelse return true;
        if (self.active.rules.len > std.math.maxInt(u32)) return false;
        return sink.emit(.{ .rule_coverage_gap = .{
            .dispatch_id = dispatch_id,
            .tool = tool,
            .effect_class = effect_class,
            .project_sha256 = self.active.project_sha256,
            .bundle_sha256 = self.active.bundle_sha256,
            .bundle_revision = self.active.revision,
            .active_rule_count = @intCast(self.active.rules.len),
        } });
    }

    fn recordRuleFilter(
        self: *const RuntimeGate,
        dispatch_id: []const u8,
        phase: observation.FormalPhase,
        operation: observation.RuleFilterOperation,
        checker_rule_count: usize,
    ) bool {
        if ((self.evidence_dir != null) != (self.observation_sink != null)) return false;
        const sink = self.observation_sink orelse return true;
        if (self.active.rules.len > std.math.maxInt(u32) or
            checker_rule_count > self.active.rules.len)
            return false;
        const active: u32 = @intCast(self.active.rules.len);
        const checker: u32 = @intCast(checker_rule_count);
        return sink.emit(.{ .rule_filter = .{
            .dispatch_id = dispatch_id,
            .phase = phase,
            .operation = operation,
            .project_sha256 = self.active.project_sha256,
            .bundle_sha256 = self.active.bundle_sha256,
            .bundle_revision = self.active.revision,
            .kernel_sha256 = self.active.kernel_sha256,
            .active_rule_count = active,
            .checker_rule_count = checker,
            .statically_pruned_rule_count = active - checker,
        } });
    }

    fn findExactEditObligation(
        self: *const RuntimeGate,
        target_sha256: [64]u8,
    ) ?usize {
        for (self.exact_edit_obligations[0..self.exact_edit_obligations_len], 0..) |item, index| {
            if (std.mem.eql(u8, &item.target_sha256, &target_sha256)) return index;
        }
        return null;
    }

    fn installExactEditObligation(
        self: *RuntimeGate,
        obligation: ExactEditObligation,
    ) bool {
        if (self.findExactEditObligation(obligation.target_sha256)) |index| {
            self.exact_edit_obligations[index] = obligation;
            return true;
        }
        if (self.exact_edit_obligations_len == self.exact_edit_obligations.len)
            return false;
        self.exact_edit_obligations[self.exact_edit_obligations_len] = obligation;
        self.exact_edit_obligations_len += 1;
        return true;
    }

    fn removeExactEditObligation(self: *RuntimeGate, index: usize) void {
        std.debug.assert(index < self.exact_edit_obligations_len);
        self.exact_edit_obligations_len -= 1;
        if (index != self.exact_edit_obligations_len)
            self.exact_edit_obligations[index] =
                self.exact_edit_obligations[self.exact_edit_obligations_len];
    }

    fn findInflightDispatch(
        self: *const RuntimeGate,
        dispatch_sha256: [64]u8,
    ) ?usize {
        for (self.inflight_exact_edits[0..self.inflight_exact_edits_len], 0..) |item, index| {
            if (std.mem.eql(u8, &item.dispatch_sha256, &dispatch_sha256)) return index;
        }
        return null;
    }

    fn findInflightTarget(
        self: *const RuntimeGate,
        target_sha256: [64]u8,
    ) ?usize {
        for (self.inflight_exact_edits[0..self.inflight_exact_edits_len], 0..) |item, index| {
            if (std.mem.eql(u8, &item.target_sha256, &target_sha256)) return index;
        }
        return null;
    }

    fn removeInflightExactEdit(self: *RuntimeGate, index: usize) void {
        std.debug.assert(index < self.inflight_exact_edits_len);
        self.inflight_exact_edits_len -= 1;
        if (index != self.inflight_exact_edits_len)
            self.inflight_exact_edits[index] =
                self.inflight_exact_edits[self.inflight_exact_edits_len];
    }
};

/// A checker request digest identifies bytes, not a physical execution. Two
/// legitimate tool calls can carry byte-identical signals (for example two
/// reads with the same input size), so publishing the request digest as the
/// call identity collapses distinct subprocess executions in the durable
/// journal. Bind the content digest to the host-observed dispatch and phase;
/// `request_sha256` remains available separately for content equality.
fn physicalCheckerCallIdentity(
    request_batch_sha256: [64]u8,
    dispatch_id: []const u8,
    phase: observation.FormalPhase,
) [64]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("metacodes-project-checker-call-v1\x00");
    hasher.update(&request_batch_sha256);
    hasher.update("\x00");
    hasher.update(@tagName(phase));
    hasher.update("\x00");
    hasher.update(dispatch_id);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

fn isRecoveryOperation(operation: kernel.Operation) bool {
    return switch (operation) {
        .recovery_pre_decision, .recovery_post_decision => true,
        .promote, .pre_decision, .post_decision => false,
    };
}

fn ordinaryTool(payload: kernel.Payload) []const u8 {
    return switch (payload) {
        .pre => |signal| signal.tool,
        .post => |signal| signal.pre.tool,
        .promotion, .recovery_pre, .recovery_post => unreachable,
    };
}

fn formalOperation(operation: kernel.Operation) observation.FormalOperation {
    return switch (operation) {
        .pre_decision => .pre_decision,
        .post_decision => .post_decision,
        .recovery_pre_decision => .recovery_pre_decision,
        .recovery_post_decision => .recovery_post_decision,
        .promote => unreachable,
    };
}

fn persistRuntimeBatchVerdict(
    directory: []const u8,
    verdict_sha256: [64]u8,
    payload: []const u8,
) !void {
    return persistRuntimeArtifact(
        directory,
        RUNTIME_BATCH_VERDICT_PREFIX,
        verdict_sha256,
        payload,
        kernel.MAX_BATCH_BYTES,
    );
}

fn persistRuntimeArtifact(
    directory: []const u8,
    prefix: []const u8,
    verdict_sha256: [64]u8,
    payload: []const u8,
    max_payload_bytes: usize,
) !void {
    if (payload.len == 0 or payload.len > max_payload_bytes or
        !std.mem.eql(u8, &observation.sha256Hex(payload), &verdict_sha256))
        return error.InvalidRuntimeVerdict;
    var path_buffer: [std.fs.max_path_bytes + 1]u8 = undefined;
    const path = try std.fmt.bufPrint(
        &path_buffer,
        "{s}/{s}{s}.json\x00",
        .{ directory, prefix, verdict_sha256[0..] },
    );
    const fd = pfs.open(@ptrCast(path.ptr), .{
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
        try writeAll(write_fd, payload);
        try pfs.fsyncChecked(write_fd);
        _ = pfs.close(write_fd);
        write_fd = -1;
        try fsyncDirectory(directory);
        return;
    }
    const existing = try readRuntimeArtifact(
        std.heap.c_allocator,
        directory,
        prefix,
        verdict_sha256,
        max_payload_bytes,
    );
    defer std.heap.c_allocator.free(existing);
    if (!std.mem.eql(u8, existing, payload)) return error.RuntimeVerdictCollision;
}

pub fn readRuntimeVerdict(
    allocator: std.mem.Allocator,
    directory: []const u8,
    verdict_sha256: [64]u8,
) ![]u8 {
    return readRuntimeArtifact(
        allocator,
        directory,
        RUNTIME_VERDICT_PREFIX,
        verdict_sha256,
        kernel.MAX_OUTPUT_BYTES,
    );
}

pub fn readRuntimeBatchVerdict(
    allocator: std.mem.Allocator,
    directory: []const u8,
    verdict_sha256: [64]u8,
) ![]u8 {
    return readRuntimeArtifact(
        allocator,
        directory,
        RUNTIME_BATCH_VERDICT_PREFIX,
        verdict_sha256,
        kernel.MAX_BATCH_BYTES,
    );
}

fn readRuntimeArtifact(
    allocator: std.mem.Allocator,
    directory: []const u8,
    prefix: []const u8,
    verdict_sha256: [64]u8,
    max_payload_bytes: usize,
) ![]u8 {
    var path_buffer: [std.fs.max_path_bytes + 1]u8 = undefined;
    const path = try std.fmt.bufPrint(
        &path_buffer,
        "{s}/{s}{s}.json\x00",
        .{ directory, prefix, verdict_sha256[0..] },
    );
    const fd = pfs.open(@ptrCast(path.ptr), .{ .ACCMODE = .RDONLY, .NOFOLLOW = true }, 0);
    if (fd < 0) return error.RuntimeVerdictOpenFailed;
    defer _ = pfs.close(fd);
    const before = pfs.fileInfo(fd) catch return error.RuntimeVerdictStatFailed;
    if (!before.is_regular or before.link_count != 1 or before.size == 0 or before.size > max_payload_bytes)
        return error.InvalidRuntimeVerdict;
    const bytes = try allocator.alloc(u8, @intCast(before.size));
    errdefer allocator.free(bytes);
    var offset: usize = 0;
    while (offset < bytes.len) {
        const count = pfs.read(fd, bytes[offset..]);
        if (count <= 0) return error.RuntimeVerdictReadFailed;
        offset += @intCast(count);
    }
    const after = pfs.fileInfo(fd) catch return error.RuntimeVerdictStatFailed;
    if (!after.is_regular or after.link_count != 1 or after.size != before.size or
        !std.mem.eql(u8, &observation.sha256Hex(bytes), &verdict_sha256))
        return error.InvalidRuntimeVerdict;
    return bytes;
}

fn writeAll(fd: pfs.Fd, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const count = pfs.write(fd, bytes[offset..]);
        if (count <= 0) return error.RuntimeVerdictWriteFailed;
        offset += @intCast(count);
    }
}

fn fsyncDirectory(directory: []const u8) !void {
    if (@import("builtin").os.tag == .windows) return;
    var buffer: [std.fs.max_path_bytes + 1]u8 = undefined;
    const path = try std.fmt.bufPrint(&buffer, "{s}\x00", .{directory});
    const fd = pfs.open(@ptrCast(path.ptr), .{ .ACCMODE = .RDONLY, .NOFOLLOW = true }, 0);
    if (fd < 0) return error.DirectoryOpenFailed;
    defer _ = pfs.close(fd);
    try pfs.fsyncChecked(fd);
}

fn hasFileMutation(effect: ?observation.Effect) bool {
    const value = effect orelse return false;
    return switch (value) {
        .file_mutation_v1, .file_mutation_v2 => true,
    };
}

fn postReobserved(effect: ?observation.Effect) bool {
    const value = effect orelse return false;
    return switch (value) {
        .file_mutation_v1 => false,
        .file_mutation_v2 => |mutation| mutation.reobservation.state == .matched,
    };
}

fn observedMatchesBlocked(
    effect: ?observation.Effect,
    target_sha256: [64]u8,
    expected: [64]u8,
) bool {
    const value = effect orelse return false;
    return switch (value) {
        .file_mutation_v1 => false,
        .file_mutation_v2 => |mutation| std.mem.eql(
            u8,
            &mutation.mutation.path_sha256,
            &target_sha256,
        ) and mutation.reobservation.state == .matched and
            std.mem.eql(u8, &mutation.reobservation.observed_sha256, &expected),
    };
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

test "runtime post signal recognizes only matched host re-observation" {
    const mutation = observation.FileMutationV1{
        .path_sha256 = .{'a'} ** 64,
        .before_state = .missing,
        .before_sha256 = .{'0'} ** 64,
        .after_sha256 = .{'b'} ** 64,
        .before_bytes = 0,
        .after_bytes = 1,
        .change = .changed,
    };
    try std.testing.expect(!postReobserved(.{ .file_mutation_v1 = mutation }));
    try std.testing.expect(postReobserved(.{ .file_mutation_v2 = .{
        .mutation = mutation,
        .reobservation = .{
            .state = .matched,
            .observed_sha256 = .{'b'} ** 64,
            .observed_bytes = 1,
        },
    } }));
}

test "runtime batch verdict artifact exceeds the legacy single-verdict ceiling" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    const payload = try allocator.alloc(u8, kernel.MAX_OUTPUT_BYTES + 1);
    defer allocator.free(payload);
    @memset(payload, 'x');
    const sha256 = observation.sha256Hex(payload);

    try persistRuntimeBatchVerdict(root, sha256, payload);
    const reopened = try readRuntimeBatchVerdict(allocator, root, sha256);
    defer allocator.free(reopened);
    try std.testing.expectEqualSlices(u8, payload, reopened);
    try std.testing.expectError(
        error.InvalidRuntimeVerdict,
        persistRuntimeArtifact(
            root,
            RUNTIME_VERDICT_PREFIX,
            sha256,
            payload,
            kernel.MAX_OUTPUT_BYTES,
        ),
    );
}
