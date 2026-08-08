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

pub const REPLAY_CORPUS_SCHEMA = "metacodes-project-rule-replay-corpus-v1";
pub const REPLAY_RESULT_SCHEMA = "metacodes-project-rule-replay-result-v1";
pub const SHADOW_TRACE_SCHEMA = "metacodes-project-rule-shadow-trace-v1";
pub const SHADOW_RESULT_SCHEMA = "metacodes-project-rule-shadow-result-v1";
pub const MAX_CASES: usize = 4096;
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

pub fn evaluateAndRecordReplay(
    allocator: std.mem.Allocator,
    session_dir: []const u8,
    artifact_dir: []const u8,
    candidate_id: [64]u8,
    project_sha256: [64]u8,
    predecessor_receipt_id: [64]u8,
    evaluator_sha256: [64]u8,
    checker_sha256: [64]u8,
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
        const actual = decide(candidate.rule_spec, item.signal);
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
        .checker_sha256 = checker_sha256,
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
    checker_sha256: [64]u8,
    binding: journal_mod.RunBinding,
    decisions: []const ShadowDecision,
) !ShadowRecorded {
    if (decisions.len == 0 or decisions.len > MAX_CASES) return error.InvalidShadowTrace;
    try validateDecisionIds(decisions);
    var candidate = try candidate_mod.load(allocator, session_dir, candidate_id);
    defer candidate.deinit();
    if (!std.mem.eql(u8, &candidate.project_sha256, &project_sha256))
        return error.ProjectIdentityMismatch;
    const binding_validation = try journal_mod.validateRunBinding(session_dir, binding);

    const trace_body = ShadowTraceBody{
        .candidate_id = candidate_id[0..],
        .project_sha256 = project_sha256[0..],
        .session_id = binding.session_id.asSlice(),
        .run_id = binding.run_id.asSlice(),
        .first_sequence = binding.first_sequence,
        .last_sequence = binding.last_sequence,
        .interval_sha256 = binding_validation.interval_sha256[0..],
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
        const actual = decide(candidate.rule_spec, item.signal);
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
        .interval_sha256 = binding_validation.interval_sha256[0..],
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
        .checker_sha256 = checker_sha256,
        .predecessor_receipt_id = predecessor_receipt_id,
        .evidence = .{ .shadow_passed = .{
            .interval_sha256 = binding_validation.interval_sha256,
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

pub fn decide(spec: spec_mod.Spec, signal: DecisionSignal) bool {
    return switch (signal) {
        .pre => |pre| spec_mod.preDecision(spec, pre),
        .post => |post| spec_mod.postDecision(spec, post),
    };
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
    for (decisions) |item| {
        try validateDecisionId(item.decision_id);
        const entry = try ids.getOrPut(item.decision_id);
        if (entry.found_existing) return error.DuplicateDecisionId;
    }
}

fn validateDecisionId(value: []const u8) !void {
    if (value.len == 0 or value.len > 128) return error.InvalidDecisionId;
    for (value) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-')
            return error.InvalidDecisionId;
    }
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
    }
    const reopened = try readExact(allocator, path);
    defer allocator.free(reopened);
    if (!std.mem.eql(u8, reopened, bytes)) return error.EvaluationArtifactCollision;
}

fn readExact(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const fd = pfs.open(path_z.ptr, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true }, 0);
    if (fd < 0) return error.EvaluationArtifactOpenFailed;
    defer _ = pfs.close(fd);
    const before = pfs.fileInfo(fd) catch return error.EvaluationArtifactStatFailed;
    if (!before.is_regular or before.size == 0 or before.size > MAX_ARTIFACT_BYTES)
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
    if (!after.is_regular or after.size != before.size) return error.EvaluationArtifactChanged;
    return bytes;
}

test "replay and shadow require mixed cases and a completed grounded interval" {
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
        .{'9'} ** 64,
        &cases,
    );
    const bad_shadow = [_]ShadowDecision{.{
        .decision_id = "actual-write",
        .observed_admit = false,
        .signal = .{ .pre = .{ .tool = "Write", .input_bytes = 10, .agent_depth = 0, .authoritative = true } },
    }};
    try std.testing.expectError(error.ShadowFailed, evaluateAndRecordShadow(
        std.testing.allocator,
        root,
        root,
        candidate_result.candidate_id,
        project,
        replay.receipt_id,
        .{'a'} ** 64,
        .{'b'} ** 64,
        binding,
        &bad_shadow,
    ));
    const good_shadow = [_]ShadowDecision{.{
        .decision_id = "actual-write",
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
        .{'b'} ** 64,
        binding,
        &good_shadow,
    );
    var loaded = try lifecycle.load(std.testing.allocator, root, shadow.receipt_id);
    defer loaded.deinit();
    try std.testing.expectEqual(lifecycle.Stage.shadow_passed, loaded.stage);
}
