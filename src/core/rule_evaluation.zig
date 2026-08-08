//! Deterministic replay and shadow evidence for project rules.
//!
//! Replay uses reviewed positive and negative decision cases. Shadow binds
//! decision-only observations to one completed real Run interval; it never
//! dispatches a tool. Both artifacts are content-addressed, fsynced, reopened,
//! and only then converted into lifecycle receipts.

const std = @import("std");
const pfs = @import("platform").fs;
const observation = @import("../tools/observation.zig");
const candidate_mod = @import("rule_candidate.zig");
const lifecycle = @import("rule_lifecycle.zig");
const spec_mod = @import("project_rule_spec.zig");
const journal_mod = @import("tool_observation_journal.zig");
const kernel = @import("../formal/project_harness_runtime.zig");

pub const REPLAY_CORPUS_SCHEMA = "metacodes-project-rule-replay-corpus-v1";
pub const REPLAY_RESULT_SCHEMA = "metacodes-project-rule-replay-result-v1";
pub const SHADOW_TRACE_SCHEMA = "metacodes-project-rule-shadow-trace-v1";
pub const SHADOW_RESULT_SCHEMA = "metacodes-project-rule-shadow-result-v1";
/// Project rules begin deliberately narrow.  Keeping one reviewed evaluation
/// set bounded also limits promotion-time native checker invocations until the
/// protocol grows a machine-checked batch operation.
pub const MAX_CASES: usize = 128;
pub const MAX_ARTIFACT_BYTES: usize = 8 * 1024 * 1024;

pub const DecisionSignal = union(enum) {
    pre: spec_mod.PreSignal,
    post: spec_mod.PostSignal,
};

pub const ReplayCase = struct {
    case_id: []const u8,
    expected_admit: bool,
    signal: DecisionSignal,
};

pub const ShadowDecision = struct {
    decision_id: []const u8,
    dispatch_id: []const u8,
    observed_admit: bool,
    signal: DecisionSignal,
};

const DecisionResult = struct {
    decision_id: []const u8,
    expected_admit: bool,
    actual_admit: bool,
};

const ReplayCorpusBody = struct {
    schema_version: []const u8 = REPLAY_CORPUS_SCHEMA,
    candidate_id: []const u8,
    project_sha256: []const u8,
    cases: []const ReplayCase,
};

const ReplayCorpusRecord = struct {
    corpus_sha256: []const u8,
    body: ReplayCorpusBody,
};

const ReplayResultBody = struct {
    schema_version: []const u8 = REPLAY_RESULT_SCHEMA,
    candidate_id: []const u8,
    project_sha256: []const u8,
    corpus_sha256: []const u8,
    positive_cases: u32,
    negative_cases: u32,
    false_positive_count: u32,
    false_negative_count: u32,
    decisions: []const DecisionResult,
};

const ReplayResultRecord = struct {
    results_sha256: []const u8,
    body: ReplayResultBody,
};

const ShadowTraceBody = struct {
    schema_version: []const u8 = SHADOW_TRACE_SCHEMA,
    candidate_id: []const u8,
    project_sha256: []const u8,
    session_id: []const u8,
    run_id: []const u8,
    first_sequence: u64,
    last_sequence: u64,
    interval_sha256: []const u8,
    decisions: []const ShadowDecision,
};

const ShadowTraceRecord = struct {
    trace_sha256: []const u8,
    body: ShadowTraceBody,
};

const ShadowResultBody = struct {
    schema_version: []const u8 = SHADOW_RESULT_SCHEMA,
    candidate_id: []const u8,
    project_sha256: []const u8,
    trace_sha256: []const u8,
    interval_sha256: []const u8,
    observed_decisions: u32,
    divergence_count: u32,
    side_effect_count: u32 = 0,
    decisions: []const DecisionResult,
};

const ShadowResultRecord = struct {
    results_sha256: []const u8,
    body: ShadowResultBody,
};

pub const ReplayRecorded = struct {
    corpus_sha256: [64]u8,
    results_sha256: [64]u8,
    receipt_id: [64]u8,
};

pub const ShadowRecorded = struct {
    trace_sha256: [64]u8,
    results_sha256: [64]u8,
    receipt_id: [64]u8,
};

pub const RevalidationSummary = struct {
    replay_cases: u32,
    shadow_decisions: u32,
    shadow_interval_sha256: [64]u8,
};

/// Promotion-time trust boundary.  Lifecycle receipts are indices, never
/// authority by themselves: reopen every raw artifact, reconstruct shadow
/// signals from the exact host journal interval, and ask the pinned Lean kernel
/// to recompute every decision before promotion may proceed.
pub fn revalidateForPromotion(
    allocator: std.mem.Allocator,
    session_dir: []const u8,
    artifact_dir: []const u8,
    candidate_id: [64]u8,
    project_sha256: [64]u8,
    replay_evidence: lifecycle.ReplayEvidence,
    shadow_evidence: lifecycle.ShadowEvidence,
    config: kernel.Config,
    abort: ?*const @import("../util/abort.zig").AbortSignal,
) !RevalidationSummary {
    var candidate = try candidate_mod.load(allocator, session_dir, candidate_id);
    defer candidate.deinit();
    if (!std.mem.eql(u8, &candidate.project_sha256, &project_sha256))
        return error.ProjectIdentityMismatch;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const corpus_bytes = try readAddressed(
        a,
        artifact_dir,
        "rule-replay-corpus-",
        replay_evidence.corpus_sha256,
    );
    const corpus = std.json.parseFromSliceLeaky(ReplayCorpusRecord, a, corpus_bytes, .{
        .ignore_unknown_fields = false,
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    }) catch return error.InvalidReplayCorpus;
    const canonical_corpus = try std.json.Stringify.valueAlloc(a, corpus, .{});
    const corpus_body_json = try std.json.Stringify.valueAlloc(a, corpus.body, .{});
    if (!std.mem.eql(u8, corpus_bytes, canonical_corpus) or
        !std.mem.eql(u8, corpus.body.schema_version, REPLAY_CORPUS_SCHEMA) or
        !equalHex(corpus.corpus_sha256, replay_evidence.corpus_sha256) or
        !std.mem.eql(u8, &observation.sha256Hex(corpus_body_json), &replay_evidence.corpus_sha256) or
        !equalHex(corpus.body.candidate_id, candidate_id) or
        !equalHex(corpus.body.project_sha256, project_sha256))
        return error.InvalidReplayCorpus;
    try validateCases(corpus.body.cases);

    const replay_decisions = try a.alloc(DecisionResult, corpus.body.cases.len);
    var replay_positive: u32 = 0;
    var replay_negative: u32 = 0;
    var false_positive: u32 = 0;
    var false_negative: u32 = 0;
    for (corpus.body.cases, 0..) |item, index| {
        const actual = try invokeDecision(
            allocator,
            config,
            candidate_id,
            project_sha256,
            replay_evidence.corpus_sha256,
            candidate.rule_spec,
            item.signal,
            abort,
        );
        if (item.expected_admit) replay_positive += 1 else replay_negative += 1;
        if (actual and !item.expected_admit) false_positive += 1;
        if (!actual and item.expected_admit) false_negative += 1;
        replay_decisions[index] = .{
            .decision_id = item.case_id,
            .expected_admit = item.expected_admit,
            .actual_admit = actual,
        };
    }
    const expected_replay_body = ReplayResultBody{
        .candidate_id = candidate_id[0..],
        .project_sha256 = project_sha256[0..],
        .corpus_sha256 = replay_evidence.corpus_sha256[0..],
        .positive_cases = replay_positive,
        .negative_cases = replay_negative,
        .false_positive_count = false_positive,
        .false_negative_count = false_negative,
        .decisions = replay_decisions,
    };
    const replay_body_json = try std.json.Stringify.valueAlloc(a, expected_replay_body, .{});
    const expected_replay_sha = observation.sha256Hex(replay_body_json);
    const expected_replay_record = ReplayResultRecord{
        .results_sha256 = expected_replay_sha[0..],
        .body = expected_replay_body,
    };
    const expected_replay_json = try std.json.Stringify.valueAlloc(a, expected_replay_record, .{});
    const replay_result_bytes = try readAddressed(
        a,
        artifact_dir,
        "rule-replay-result-",
        replay_evidence.results_sha256,
    );
    if (!std.mem.eql(u8, &expected_replay_sha, &replay_evidence.results_sha256) or
        !std.mem.eql(u8, expected_replay_json, replay_result_bytes) or
        replay_positive != replay_evidence.positive_cases or
        replay_negative != replay_evidence.negative_cases or
        false_positive != replay_evidence.false_positive_count or
        false_negative != replay_evidence.false_negative_count or
        !replay_evidence.completed)
        return error.ReplayRevalidationFailed;

    const shadow_result_bytes = try readAddressed(
        a,
        artifact_dir,
        "rule-shadow-result-",
        shadow_evidence.results_sha256,
    );
    const shadow_result = std.json.parseFromSliceLeaky(ShadowResultRecord, a, shadow_result_bytes, .{
        .ignore_unknown_fields = false,
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    }) catch return error.InvalidShadowResult;
    const canonical_shadow_result = try std.json.Stringify.valueAlloc(a, shadow_result, .{});
    const parsed_shadow_body = try std.json.Stringify.valueAlloc(a, shadow_result.body, .{});
    const trace_sha256 = parseHex(shadow_result.body.trace_sha256) orelse
        return error.InvalidShadowResult;
    if (!std.mem.eql(u8, shadow_result_bytes, canonical_shadow_result) or
        !std.mem.eql(u8, shadow_result.body.schema_version, SHADOW_RESULT_SCHEMA) or
        !equalHex(shadow_result.results_sha256, shadow_evidence.results_sha256) or
        !std.mem.eql(u8, &observation.sha256Hex(parsed_shadow_body), &shadow_evidence.results_sha256) or
        !equalHex(shadow_result.body.candidate_id, candidate_id) or
        !equalHex(shadow_result.body.project_sha256, project_sha256) or
        !equalHex(shadow_result.body.interval_sha256, shadow_evidence.interval_sha256))
        return error.InvalidShadowResult;

    const trace_bytes = try readAddressed(
        a,
        artifact_dir,
        "rule-shadow-trace-",
        trace_sha256,
    );
    const trace = std.json.parseFromSliceLeaky(ShadowTraceRecord, a, trace_bytes, .{
        .ignore_unknown_fields = false,
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    }) catch return error.InvalidShadowTrace;
    const canonical_trace = try std.json.Stringify.valueAlloc(a, trace, .{});
    const trace_body_json = try std.json.Stringify.valueAlloc(a, trace.body, .{});
    if (!std.mem.eql(u8, trace_bytes, canonical_trace) or
        !std.mem.eql(u8, trace.body.schema_version, SHADOW_TRACE_SCHEMA) or
        !equalHex(trace.trace_sha256, trace_sha256) or
        !std.mem.eql(u8, &observation.sha256Hex(trace_body_json), &trace_sha256) or
        !equalHex(trace.body.candidate_id, candidate_id) or
        !equalHex(trace.body.project_sha256, project_sha256) or
        !equalHex(trace.body.interval_sha256, shadow_evidence.interval_sha256))
        return error.InvalidShadowTrace;
    if (trace.body.first_sequence > trace.body.last_sequence)
        return error.InvalidShadowTrace;
    const session_id = @import("session_id.zig").SessionId.fromSlice(trace.body.session_id) orelse
        return error.InvalidShadowTrace;
    const run_id = @import("session_id.zig").SessionId.fromSlice(trace.body.run_id) orelse
        return error.InvalidShadowTrace;
    const binding = journal_mod.RunBinding{
        .session_id = session_id,
        .run_id = run_id,
        .first_sequence = trace.body.first_sequence,
        .last_sequence = trace.body.last_sequence,
    };
    var run = try journal_mod.loadRunDispatches(allocator, session_dir, binding);
    defer run.deinit();
    if (!std.mem.eql(u8, &run.interval_sha256, &shadow_evidence.interval_sha256))
        return error.ShadowIntervalMismatch;
    try validateDecisionIds(trace.body.decisions);
    try validateShadowDecisions(run.dispatches, trace.body.decisions);

    const shadow_decisions = try a.alloc(DecisionResult, trace.body.decisions.len);
    var divergence: u32 = 0;
    for (trace.body.decisions, 0..) |item, index| {
        const actual = try invokeDecision(
            allocator,
            config,
            candidate_id,
            project_sha256,
            trace_sha256,
            candidate.rule_spec,
            item.signal,
            abort,
        );
        if (actual != item.observed_admit) divergence += 1;
        shadow_decisions[index] = .{
            .decision_id = item.decision_id,
            .expected_admit = item.observed_admit,
            .actual_admit = actual,
        };
    }
    const expected_shadow_body = ShadowResultBody{
        .candidate_id = candidate_id[0..],
        .project_sha256 = project_sha256[0..],
        .trace_sha256 = trace_sha256[0..],
        .interval_sha256 = run.interval_sha256[0..],
        .observed_decisions = @intCast(trace.body.decisions.len),
        .divergence_count = divergence,
        .decisions = shadow_decisions,
    };
    const shadow_body_json = try std.json.Stringify.valueAlloc(a, expected_shadow_body, .{});
    const expected_shadow_sha = observation.sha256Hex(shadow_body_json);
    const expected_shadow_record = ShadowResultRecord{
        .results_sha256 = expected_shadow_sha[0..],
        .body = expected_shadow_body,
    };
    const expected_shadow_json = try std.json.Stringify.valueAlloc(a, expected_shadow_record, .{});
    if (!std.mem.eql(u8, &expected_shadow_sha, &shadow_evidence.results_sha256) or
        !std.mem.eql(u8, expected_shadow_json, shadow_result_bytes) or
        @as(u32, @intCast(trace.body.decisions.len)) != shadow_evidence.observed_decisions or
        divergence != shadow_evidence.divergence_count or
        shadow_evidence.side_effect_count != 0 or !shadow_evidence.completed)
        return error.ShadowRevalidationFailed;
    return .{
        .replay_cases = @intCast(corpus.body.cases.len),
        .shadow_decisions = @intCast(trace.body.decisions.len),
        .shadow_interval_sha256 = run.interval_sha256,
    };
}

pub fn evaluateAndRecordReplay(
    allocator: std.mem.Allocator,
    session_dir: []const u8,
    artifact_dir: []const u8,
    candidate_id: [64]u8,
    project_sha256: [64]u8,
    predecessor_receipt_id: [64]u8,
    evaluator_sha256: [64]u8,
    config: kernel.Config,
    cases: []const ReplayCase,
) !ReplayRecorded {
    try validateCases(cases);
    var candidate = try candidate_mod.load(allocator, session_dir, candidate_id);
    defer candidate.deinit();
    if (!std.mem.eql(u8, &candidate.project_sha256, &project_sha256))
        return error.ProjectIdentityMismatch;

    const corpus_body = ReplayCorpusBody{
        .candidate_id = candidate_id[0..],
        .project_sha256 = project_sha256[0..],
        .cases = cases,
    };
    const corpus_body_json = try std.json.Stringify.valueAlloc(allocator, corpus_body, .{});
    defer allocator.free(corpus_body_json);
    const corpus_sha256 = observation.sha256Hex(corpus_body_json);
    const corpus_record = ReplayCorpusRecord{
        .corpus_sha256 = corpus_sha256[0..],
        .body = corpus_body,
    };
    const corpus_json = try std.json.Stringify.valueAlloc(allocator, corpus_record, .{});
    defer allocator.free(corpus_json);
    try persistAndReopen(
        allocator,
        artifact_dir,
        "rule-replay-corpus-",
        corpus_sha256,
        corpus_json,
    );

    const results = try allocator.alloc(DecisionResult, cases.len);
    defer allocator.free(results);
    var positive: u32 = 0;
    var negative: u32 = 0;
    var false_positive: u32 = 0;
    var false_negative: u32 = 0;
    for (cases, 0..) |item, index| {
        const actual = try invokeDecision(
            allocator,
            config,
            candidate_id,
            project_sha256,
            corpus_sha256,
            candidate.rule_spec,
            item.signal,
            null,
        );
        if (item.expected_admit) positive += 1 else negative += 1;
        if (actual and !item.expected_admit) false_positive += 1;
        if (!actual and item.expected_admit) false_negative += 1;
        results[index] = .{
            .decision_id = item.case_id,
            .expected_admit = item.expected_admit,
            .actual_admit = actual,
        };
    }
    const result_body = ReplayResultBody{
        .candidate_id = candidate_id[0..],
        .project_sha256 = project_sha256[0..],
        .corpus_sha256 = corpus_sha256[0..],
        .positive_cases = positive,
        .negative_cases = negative,
        .false_positive_count = false_positive,
        .false_negative_count = false_negative,
        .decisions = results,
    };
    const result_body_json = try std.json.Stringify.valueAlloc(allocator, result_body, .{});
    defer allocator.free(result_body_json);
    const results_sha256 = observation.sha256Hex(result_body_json);
    const result_record = ReplayResultRecord{
        .results_sha256 = results_sha256[0..],
        .body = result_body,
    };
    const result_json = try std.json.Stringify.valueAlloc(allocator, result_record, .{});
    defer allocator.free(result_json);
    try persistAndReopen(
        allocator,
        artifact_dir,
        "rule-replay-result-",
        results_sha256,
        result_json,
    );

    const receipt = try lifecycle.persist(session_dir, .{
        .candidate_id = candidate_id,
        .project_sha256 = project_sha256,
        .actor_sha256 = evaluator_sha256,
        .checker_sha256 = config.expected_sha256,
        .predecessor_receipt_id = predecessor_receipt_id,
        .evidence = .{ .replay_passed = .{
            .corpus_sha256 = corpus_sha256,
            .results_sha256 = results_sha256,
            .positive_cases = positive,
            .negative_cases = negative,
            .false_positive_count = false_positive,
            .false_negative_count = false_negative,
            .completed = true,
        } },
    });
    return .{
        .corpus_sha256 = corpus_sha256,
        .results_sha256 = results_sha256,
        .receipt_id = receipt.receipt_id,
    };
}

pub fn evaluateAndRecordShadow(
    allocator: std.mem.Allocator,
    session_dir: []const u8,
    artifact_dir: []const u8,
    candidate_id: [64]u8,
    project_sha256: [64]u8,
    predecessor_receipt_id: [64]u8,
    evaluator_sha256: [64]u8,
    config: kernel.Config,
    binding: journal_mod.RunBinding,
    decisions: []const ShadowDecision,
) !ShadowRecorded {
    if (decisions.len == 0 or decisions.len > MAX_CASES) return error.InvalidShadowTrace;
    try validateDecisionIds(decisions);
    var candidate = try candidate_mod.load(allocator, session_dir, candidate_id);
    defer candidate.deinit();
    if (!std.mem.eql(u8, &candidate.project_sha256, &project_sha256))
        return error.ProjectIdentityMismatch;
    var run = try journal_mod.loadRunDispatches(allocator, session_dir, binding);
    defer run.deinit();
    try validateShadowDecisions(run.dispatches, decisions);

    const trace_body = ShadowTraceBody{
        .candidate_id = candidate_id[0..],
        .project_sha256 = project_sha256[0..],
        .session_id = binding.session_id.asSlice(),
        .run_id = binding.run_id.asSlice(),
        .first_sequence = binding.first_sequence,
        .last_sequence = binding.last_sequence,
        .interval_sha256 = run.interval_sha256[0..],
        .decisions = decisions,
    };
    const trace_body_json = try std.json.Stringify.valueAlloc(allocator, trace_body, .{});
    defer allocator.free(trace_body_json);
    const trace_sha256 = observation.sha256Hex(trace_body_json);
    const trace_record = ShadowTraceRecord{ .trace_sha256 = trace_sha256[0..], .body = trace_body };
    const trace_json = try std.json.Stringify.valueAlloc(allocator, trace_record, .{});
    defer allocator.free(trace_json);
    try persistAndReopen(
        allocator,
        artifact_dir,
        "rule-shadow-trace-",
        trace_sha256,
        trace_json,
    );

    const results = try allocator.alloc(DecisionResult, decisions.len);
    defer allocator.free(results);
    var divergence: u32 = 0;
    for (decisions, 0..) |item, index| {
        const actual = try invokeDecision(
            allocator,
            config,
            candidate_id,
            project_sha256,
            trace_sha256,
            candidate.rule_spec,
            item.signal,
            null,
        );
        if (actual != item.observed_admit) divergence += 1;
        results[index] = .{
            .decision_id = item.decision_id,
            .expected_admit = item.observed_admit,
            .actual_admit = actual,
        };
    }
    const result_body = ShadowResultBody{
        .candidate_id = candidate_id[0..],
        .project_sha256 = project_sha256[0..],
        .trace_sha256 = trace_sha256[0..],
        .interval_sha256 = run.interval_sha256[0..],
        .observed_decisions = @intCast(decisions.len),
        .divergence_count = divergence,
        .decisions = results,
    };
    const result_body_json = try std.json.Stringify.valueAlloc(allocator, result_body, .{});
    defer allocator.free(result_body_json);
    const results_sha256 = observation.sha256Hex(result_body_json);
    const result_record = ShadowResultRecord{ .results_sha256 = results_sha256[0..], .body = result_body };
    const result_json = try std.json.Stringify.valueAlloc(allocator, result_record, .{});
    defer allocator.free(result_json);
    try persistAndReopen(
        allocator,
        artifact_dir,
        "rule-shadow-result-",
        results_sha256,
        result_json,
    );

    const receipt = try lifecycle.persist(session_dir, .{
        .candidate_id = candidate_id,
        .project_sha256 = project_sha256,
        .actor_sha256 = evaluator_sha256,
        .checker_sha256 = config.expected_sha256,
        .predecessor_receipt_id = predecessor_receipt_id,
        .evidence = .{ .shadow_passed = .{
            .interval_sha256 = run.interval_sha256,
            .results_sha256 = results_sha256,
            .observed_decisions = @intCast(decisions.len),
            .divergence_count = divergence,
            .side_effect_count = 0,
            .completed = true,
        } },
    });
    return .{
        .trace_sha256 = trace_sha256,
        .results_sha256 = results_sha256,
        .receipt_id = receipt.receipt_id,
    };
}

fn invokeDecision(
    allocator: std.mem.Allocator,
    config: kernel.Config,
    candidate_id: [64]u8,
    project_sha256: [64]u8,
    evaluation_sha256: [64]u8,
    spec: spec_mod.Spec,
    signal: DecisionSignal,
    abort: ?*const @import("../util/abort.zig").AbortSignal,
) !bool {
    const operation: kernel.Operation = switch (signal) {
        .pre => .pre_decision,
        .post => .post_decision,
    };
    const payload: kernel.Payload = switch (signal) {
        .pre => |value| .{ .pre = value },
        .post => |value| .{ .post = value },
    };
    const signal_json = try std.json.Stringify.valueAlloc(allocator, payload, .{});
    defer allocator.free(signal_json);
    const request_id = kernel.requestId(
        operation,
        candidate_id,
        evaluation_sha256,
        1,
        signal_json,
    );
    const request = kernel.Request{
        .request_id = request_id[0..],
        .operation = operation,
        .kernel_sha256 = config.expected_sha256[0..],
        .candidate_id = candidate_id[0..],
        .project_sha256 = project_sha256[0..],
        .bundle_sha256 = evaluation_sha256[0..],
        .bundle_revision = 1,
        .rule_spec = spec_mod.toWire(spec),
        .payload = payload,
    };
    var invocation = try kernel.invoke(allocator, config, request, .{
        .request_id = request_id,
        .operation = operation,
        .kernel_sha256 = config.expected_sha256,
        .candidate_id = candidate_id,
        .project_sha256 = project_sha256,
        .bundle_sha256 = evaluation_sha256,
        .bundle_revision = 1,
    }, abort);
    defer invocation.deinit(allocator);
    if (invocation.failure != .none or invocation.verdict == null)
        return error.EvaluationCheckerFailed;
    return invocation.verdict.?.admitted;
}

fn validateCases(cases: []const ReplayCase) !void {
    if (cases.len == 0 or cases.len > MAX_CASES) return error.InvalidReplayCorpus;
    var positive: usize = 0;
    var negative: usize = 0;
    var ids = std.StringHashMap(void).init(std.heap.c_allocator);
    defer ids.deinit();
    for (cases) |item| {
        try validateDecisionId(item.case_id);
        const entry = try ids.getOrPut(item.case_id);
        if (entry.found_existing) return error.DuplicateDecisionId;
        if (item.expected_admit) positive += 1 else negative += 1;
    }
    if (positive == 0 or negative == 0) return error.ReplayNeedsPositiveAndNegativeCases;
}

fn validateDecisionIds(decisions: []const ShadowDecision) !void {
    var ids = std.StringHashMap(void).init(std.heap.c_allocator);
    defer ids.deinit();
    for (decisions, 0..) |item, index| {
        try validateDecisionId(item.decision_id);
        try validateDecisionId(item.dispatch_id);
        const entry = try ids.getOrPut(item.decision_id);
        if (entry.found_existing) return error.DuplicateDecisionId;
        if (!item.observed_admit) return error.ShadowDecisionNotObserved;
        for (decisions[0..index]) |prior| {
            if (std.mem.eql(u8, prior.dispatch_id, item.dispatch_id) and
                std.meta.activeTag(prior.signal) == std.meta.activeTag(item.signal))
                return error.DuplicateDispatchDecision;
        }
    }
}

fn validateShadowDecisions(
    dispatches: []const journal_mod.RunDispatch,
    decisions: []const ShadowDecision,
) !void {
    for (decisions) |decision| {
        const actual = findDispatch(dispatches, decision.dispatch_id) orelse
            return error.ShadowDispatchMissing;
        const matches = switch (decision.signal) {
            .pre => |signal| preMatches(actual, signal),
            .post => |signal| postMatches(actual, signal),
        };
        if (!matches) return error.ShadowSignalMismatch;
    }
}

fn findDispatch(
    dispatches: []const journal_mod.RunDispatch,
    id: []const u8,
) ?journal_mod.RunDispatch {
    var found: ?journal_mod.RunDispatch = null;
    for (dispatches) |dispatch| {
        if (!std.mem.eql(u8, dispatch.id, id)) continue;
        if (found != null) return null;
        found = dispatch;
    }
    return found;
}

fn preMatches(dispatch: journal_mod.RunDispatch, signal: spec_mod.PreSignal) bool {
    return std.mem.eql(u8, dispatch.dispatched_name, signal.tool) and
        dispatch.input_bytes == signal.input_bytes and
        dispatch.agent_depth == signal.agent_depth and
        (dispatch.origin == .authoritative) == signal.authoritative;
}

fn postMatches(dispatch: journal_mod.RunDispatch, signal: spec_mod.PostSignal) bool {
    if (!preMatches(dispatch, signal.pre) or
        (dispatch.outcome == .succeeded) != signal.succeeded or
        dispatch.effect_valid != signal.effect_valid)
        return false;
    const has_mutation = if (dispatch.effect) |effect| switch (effect) {
        .file_mutation_v1, .file_mutation_v2 => true,
    } else false;
    const reobserved = if (dispatch.effect) |effect| switch (effect) {
        .file_mutation_v1 => false,
        .file_mutation_v2 => |value| value.reobservation.state == .matched,
    } else false;
    return has_mutation == signal.has_file_mutation_v1 and
        reobserved == signal.post_reobserved;
}

fn validateDecisionId(value: []const u8) !void {
    if (value.len == 0 or value.len > 128) return error.InvalidDecisionId;
    for (value) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-')
            return error.InvalidDecisionId;
    }
}

fn readAddressed(
    allocator: std.mem.Allocator,
    directory: []const u8,
    prefix: []const u8,
    identity: [64]u8,
) ![]u8 {
    const path = try std.fmt.allocPrint(
        allocator,
        "{s}/{s}{s}.json",
        .{ directory, prefix, identity[0..] },
    );
    return readExact(allocator, path);
}

fn equalHex(value: []const u8, expected: [64]u8) bool {
    return value.len == expected.len and std.mem.eql(u8, value, &expected);
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

fn persistAndReopen(
    allocator: std.mem.Allocator,
    directory: []const u8,
    prefix: []const u8,
    identity: [64]u8,
    bytes: []const u8,
) !void {
    if (bytes.len == 0 or bytes.len > MAX_ARTIFACT_BYTES) return error.InvalidEvaluationArtifact;
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}{s}.json", .{ directory, prefix, identity[0..] });
    defer allocator.free(path);
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const fd = pfs.open(path_z.ptr, .{
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
        var offset: usize = 0;
        while (offset < bytes.len) {
            const count = pfs.write(write_fd, bytes[offset..]);
            if (count <= 0) return error.EvaluationArtifactWriteFailed;
            offset += @intCast(count);
        }
        try pfs.fsyncChecked(write_fd);
        _ = pfs.close(write_fd);
        write_fd = -1;
        try fsyncDirectory(directory);
    }
    const reopened = try readExact(allocator, path);
    defer allocator.free(reopened);
    if (!std.mem.eql(u8, reopened, bytes)) return error.EvaluationArtifactCollision;
}

fn fsyncDirectory(directory: []const u8) !void {
    if (@import("builtin").os.tag == .windows) return;
    const path_z = try std.heap.c_allocator.dupeZ(u8, directory);
    defer std.heap.c_allocator.free(path_z);
    const fd = pfs.open(path_z.ptr, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true }, 0);
    if (fd < 0) return error.DirectoryOpenFailed;
    defer _ = pfs.close(fd);
    try pfs.fsyncChecked(fd);
}

fn readExact(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const fd = pfs.open(path_z.ptr, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true }, 0);
    if (fd < 0) return error.EvaluationArtifactOpenFailed;
    defer _ = pfs.close(fd);
    const before = pfs.fileInfo(fd) catch return error.EvaluationArtifactStatFailed;
    if (!before.is_regular or before.link_count != 1 or before.size == 0 or before.size > MAX_ARTIFACT_BYTES)
        return error.InvalidEvaluationArtifact;
    const bytes = try allocator.alloc(u8, @intCast(before.size));
    errdefer allocator.free(bytes);
    var offset: usize = 0;
    while (offset < bytes.len) {
        const count = pfs.read(fd, bytes[offset..]);
        if (count <= 0) return error.EvaluationArtifactReadFailed;
        offset += @intCast(count);
    }
    const after = pfs.fileInfo(fd) catch return error.EvaluationArtifactStatFailed;
    if (!after.is_regular or after.link_count != 1 or after.size != before.size)
        return error.EvaluationArtifactChanged;
    return bytes;
}

test "replay and shadow require mixed cases and a completed grounded interval" {
    const config = testKernelConfig() orelse return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    const project = [_]u8{'a'} ** 64;
    const proposer = [_]u8{'b'} ** 64;
    const sid = @import("session_id.zig").SessionId.fromSlice("0123456789abcdef01234567").?;
    var journal = try journal_mod.Journal.init(root, sid);
    const sink = journal.sink();
    try std.testing.expect(sink.emit(.{ .dispatch_started = .{
        .id = "shadow-write",
        .requested_name = "Write",
        .dispatched_name = "Write",
        .origin = .authoritative,
        .agent_depth = 0,
        .input_bytes = 10,
        .input_sha256 = observation.sha256Hex("input"),
    } }));
    try std.testing.expect(sink.emit(.{ .dispatch_finished = .{
        .id = "shadow-write",
        .requested_name = "Write",
        .dispatched_name = "Write",
        .origin = .authoritative,
        .agent_depth = 0,
        .outcome = .succeeded,
        .error_code = null,
        .elapsed_ms = 1,
        .result_present = true,
        .result_bytes = 2,
        .result_sha256 = observation.sha256Hex("ok"),
        .effect = null,
        .effect_valid = true,
    } }));
    try journal.finishRun("end_turn");
    const binding = try journal.runBinding();
    journal.deinit();
    const candidate_result = try candidate_mod.persist(root, .{
        .project_sha256 = project,
        .proposer_sha256 = proposer,
        .invariant = "Authoritative Write inputs stay within the project bound.",
        .rule_spec = .{
            .target_tool = "Write",
            .deny_target = false,
            .max_input_bytes = 100,
            .max_agent_depth = 2,
            .authoritative_only = true,
            .effect_requirement = .none,
        },
        .lean_source = "def spec : RuleSpec := { targetTool := \"Write\", denyTarget := false, maxInputBytes := 100, maxAgentDepth := 2, authoritativeOnly := true, effectRequirement := .none }; theorem spec_valid : valid spec = true := by rfl",
        .source = .{ .agent_reflection = .{
            .observation = binding,
            .reflector_sha256 = proposer,
            .falsifier = "An oversized authoritative Write is admitted.",
        } },
    });
    var candidate = try candidate_mod.load(std.testing.allocator, root, candidate_result.candidate_id);
    defer candidate.deinit();
    const canonical_spec = try spec_mod.renderCanonical(std.testing.allocator, candidate.rule_spec);
    defer std.testing.allocator.free(canonical_spec);
    const built = try lifecycle.persist(root, .{
        .candidate_id = candidate_result.candidate_id,
        .project_sha256 = project,
        .actor_sha256 = .{'c'} ** 64,
        .checker_sha256 = .{'d'} ** 64,
        .predecessor_receipt_id = null,
        .evidence = .{ .built = .{
            .manifest_sha256 = .{'0'} ** 64,
            .lean_source_sha256 = candidate.lean_source_sha256,
            .rule_spec_sha256 = observation.sha256Hex(canonical_spec),
            .compiled_artifact_sha256 = .{'1'} ** 64,
            .toolchain_sha256 = .{'2'} ** 64,
            .sdk_sha256 = .{'3'} ** 64,
            .sdk_olean_sha256 = .{'4'} ** 64,
            .build_log_sha256 = .{'5'} ** 64,
            .network_disabled = true,
            .secrets_absent = true,
            .source_bounded = true,
            .output_bounded = true,
            .completed = true,
        } },
    });
    const audited = try lifecycle.persist(root, .{
        .candidate_id = candidate_result.candidate_id,
        .project_sha256 = project,
        .actor_sha256 = .{'e'} ** 64,
        .checker_sha256 = .{'6'} ** 64,
        .predecessor_receipt_id = built.receipt_id,
        .evidence = .{ .axiom_audited = .{
            .audit_sha256 = .{'7'} ** 64,
            .policy_sha256 = .{'8'} ** 64,
            .forbidden_declaration_count = 0,
            .unexpected_axiom_count = 0,
            .completed = true,
        } },
    });
    const cases = [_]ReplayCase{
        .{
            .case_id = "within-bound",
            .expected_admit = true,
            .signal = .{ .pre = .{ .tool = "Write", .input_bytes = 10, .agent_depth = 0, .authoritative = true } },
        },
        .{
            .case_id = "over-bound",
            .expected_admit = false,
            .signal = .{ .pre = .{ .tool = "Write", .input_bytes = 101, .agent_depth = 0, .authoritative = true } },
        },
    };
    const replay = try evaluateAndRecordReplay(
        std.testing.allocator,
        root,
        root,
        candidate_result.candidate_id,
        project,
        audited.receipt_id,
        .{'f'} ** 64,
        config,
        &cases,
    );
    const bad_shadow = [_]ShadowDecision{.{
        .decision_id = "actual-write",
        .dispatch_id = "shadow-write",
        .observed_admit = false,
        .signal = .{ .pre = .{ .tool = "Write", .input_bytes = 10, .agent_depth = 0, .authoritative = true } },
    }};
    try std.testing.expectError(error.ShadowDecisionNotObserved, evaluateAndRecordShadow(
        std.testing.allocator,
        root,
        root,
        candidate_result.candidate_id,
        project,
        replay.receipt_id,
        .{'a'} ** 64,
        config,
        binding,
        &bad_shadow,
    ));
    const good_shadow = [_]ShadowDecision{.{
        .decision_id = "actual-write",
        .dispatch_id = "shadow-write",
        .observed_admit = true,
        .signal = .{ .pre = .{ .tool = "Write", .input_bytes = 10, .agent_depth = 0, .authoritative = true } },
    }};
    const shadow = try evaluateAndRecordShadow(
        std.testing.allocator,
        root,
        root,
        candidate_result.candidate_id,
        project,
        replay.receipt_id,
        .{'a'} ** 64,
        config,
        binding,
        &good_shadow,
    );
    var loaded = try lifecycle.load(std.testing.allocator, root, shadow.receipt_id);
    defer loaded.deinit();
    try std.testing.expectEqual(lifecycle.Stage.shadow_passed, loaded.stage);
}

fn testKernelConfig() ?kernel.Config {
    const path_raw = std.c.getenv("METACODES_TEST_PROJECT_KERNEL_PATH") orelse return null;
    const hash_raw = std.c.getenv("METACODES_TEST_PROJECT_KERNEL_SHA256") orelse return null;
    const hash = parseHex(std.mem.span(hash_raw)) orelse return null;
    const path = std.mem.span(path_raw);
    if (!std.fs.path.isAbsolute(path)) return null;
    return .{ .checker_path = path, .expected_sha256 = hash };
}
