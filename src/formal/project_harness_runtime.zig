//! Fail-closed native boundary for the fixed Lean project-harness kernel.
//!
//! Candidate Lean code is build evidence only. Production decisions pass the
//! candidate's bounded `RuleSpec` as data to this hash-pinned executable. The
//! host verifies the binary before and after each call and binds the verdict to
//! the exact project, bundle, candidate, revision, operation, and request id.

const std = @import("std");
const pfs = @import("platform").fs;
const process = @import("platform").process;
const time = @import("../util/time.zig");
const observation = @import("../tools/observation.zig");
const spec_mod = @import("../core/project_rule_spec.zig");
const impact_receipt = @import("../core/rule_impact_receipt.zig");
const impact_aggregate = @import("../core/rule_impact_aggregate_receipt.zig");
const AbortSignal = @import("../util/abort.zig").AbortSignal;
const toolchain = @import("../util/toolchain.zig");
const build_options = @import("project_harness_build_options");
const test_paths = @import("platform").paths;

pub const REQUEST_SCHEMA = "metacodes-project-harness-request-v3";
pub const VERDICT_SCHEMA = "metacodes-project-harness-verdict-v3";
pub const BATCH_REQUEST_SCHEMA = "metacodes-project-harness-batch-request-v3";
pub const BATCH_VERDICT_SCHEMA = "metacodes-project-harness-batch-verdict-v3";
pub const CHECKER_VERSION = "metacodes-project-harness-kernel-v3";
pub const IMPACT_REQUEST_SCHEMA = "metacodes-rule-impact-governance-request-v1";
pub const IMPACT_VERDICT_SCHEMA = "metacodes-rule-impact-governance-verdict-v1";
pub const IMPACT_AGGREGATE_REQUEST_SCHEMA = "metacodes-rule-impact-aggregate-governance-request-v1";
pub const IMPACT_AGGREGATE_VERDICT_SCHEMA = "metacodes-rule-impact-aggregate-governance-verdict-v1";
pub const MAX_REQUEST_BYTES: usize = 128 * 1024;
pub const MAX_OUTPUT_BYTES: usize = 128 * 1024;
pub const MAX_BATCH_BYTES: usize = 4 * 1024 * 1024;
pub const MAX_BATCH_REQUESTS: usize = 1024;
pub const MAX_CHECKER_BYTES: u64 = 128 * 1024 * 1024;

pub const Config = struct {
    checker_path: []const u8,
    expected_sha256: [64]u8,
    timeout_ms: u64 = 5_000,
    source: Source = .env,
};

pub const Source = enum { env, adjacent };

pub const ConfigLoad = union(enum) { missing, invalid, configured: Config };

pub fn loadConfigFromEnv() ConfigLoad {
    const raw_path = std.c.getenv("METACODES_PROJECT_KERNEL_PATH");
    const raw_hash = std.c.getenv("METACODES_PROJECT_KERNEL_SHA256");
    if (raw_path == null and raw_hash == null) return .missing;
    if (raw_path == null or raw_hash == null) return .invalid;
    const path = std.mem.span(raw_path.?);
    const expected = parseLowerHex64(std.mem.span(raw_hash.?)) orelse return .invalid;
    if (!std.fs.path.isAbsolute(path)) return .invalid;
    var timeout_ms: u64 = 5_000;
    if (std.c.getenv("METACODES_PROJECT_KERNEL_TIMEOUT_MS")) |raw_timeout| {
        timeout_ms = std.fmt.parseInt(u64, std.mem.span(raw_timeout), 10) catch return .invalid;
        if (timeout_ms < 100 or timeout_ms > 30_000) return .invalid;
    }
    return .{ .configured = .{
        .checker_path = path,
        .expected_sha256 = expected,
        .timeout_ms = timeout_ms,
        .source = .env,
    } };
}

pub fn loadConfig() ConfigLoad {
    const path_set = std.c.getenv("METACODES_PROJECT_KERNEL_PATH") != null;
    const hash_set = std.c.getenv("METACODES_PROJECT_KERNEL_SHA256") != null;
    if (path_set or hash_set) return loadConfigFromEnv();
    const expected_raw = build_options.project_kernel_expected_sha256 orelse return .missing;
    const path = toolchain.kernelAdjacentPath(.project) orelse return .missing;
    const expected = parseLowerHex64(expected_raw) orelse return .missing;
    var timeout_ms: u64 = 5_000;
    if (std.c.getenv("METACODES_PROJECT_KERNEL_TIMEOUT_MS")) |raw_timeout| {
        timeout_ms = std.fmt.parseInt(u64, std.mem.span(raw_timeout), 10) catch return .invalid;
        if (timeout_ms < 100 or timeout_ms > 30_000) return .invalid;
    }
    return .{ .configured = .{
        .checker_path = path,
        .expected_sha256 = expected,
        .timeout_ms = timeout_ms,
        .source = .adjacent,
    } };
}

test "project Kernel loadConfig preserves an environment pair" {
    test_paths.unsetEnv("METACODES_PROJECT_KERNEL_PATH");
    test_paths.unsetEnv("METACODES_PROJECT_KERNEL_SHA256");
    test_paths.unsetEnv("METACODES_PROJECT_KERNEL_TIMEOUT_MS");
    defer test_paths.unsetEnv("METACODES_PROJECT_KERNEL_PATH");
    defer test_paths.unsetEnv("METACODES_PROJECT_KERNEL_SHA256");
    defer test_paths.unsetEnv("METACODES_PROJECT_KERNEL_TIMEOUT_MS");
    test_paths.setEnv("METACODES_PROJECT_KERNEL_PATH", "/tmp/project-kernel-test");
    test_paths.setEnv("METACODES_PROJECT_KERNEL_SHA256", "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb");
    switch (loadConfig()) {
        .configured => |config| {
            try std.testing.expectEqualStrings("/tmp/project-kernel-test", config.checker_path);
            try std.testing.expectEqual(Source.env, config.source);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "project Kernel loadConfig stays missing without compiled digest" {
    test_paths.unsetEnv("METACODES_PROJECT_KERNEL_PATH");
    test_paths.unsetEnv("METACODES_PROJECT_KERNEL_SHA256");
    // The test build intentionally exports no project digest, so adjacency is
    // fail-closed even if a file happens to exist beside the test executable.
    try std.testing.expectEqual(ConfigLoad.missing, loadConfig());
}

pub const Operation = enum {
    promote,
    pre_decision,
    post_decision,
    recovery_pre_decision,
    recovery_post_decision,
};
pub const SourceKind = enum {
    user_correction,
    agent_reflection,
    runtime_counterexample,
    rule_author,
};

pub const ImpactOperation = enum { promote, demote, quarantine };
pub const ImpactRuleState = enum { shadowed, promoted, quarantined };

pub const ImpactPolicy = struct {
    min_exposures: u64,
    max_formal_faults: u64,
    max_shadow_divergences: u64,
    max_false_interventions: u64,
    max_regressions: u64,
    max_provider_requests: u64,
    max_metered_tokens: u64,
    max_cost_microusd: u64,
    max_wall_elapsed_ns: u64,
};

const ImpactFacts = struct {
    completed_run: bool,
    evidence_authenticated: bool,
    window_occurrences: u64,
    formal_decisions: u64,
    formal_faults: u64,
    exposures: u64,
    admits: u64,
    blocks: u64,
    faults: u64,
    shadow_divergences: u64,
    task_success: bool,
    trustworthy_success: bool,
    drift_detected: bool,
    false_interventions: u64,
    regressions: u64,
    physical_checker_calls: u64,
    checker_elapsed_ns: u64,
    provider_requests: u64,
    input_tokens: u64,
    output_tokens: u64,
    cache_read_tokens: u64,
    cache_write_tokens: u64,
    metered_tokens: u64,
    cost_microusd: u64,
    wall_elapsed_ns: u64,
};

const ImpactRequest = struct {
    schema_version: []const u8 = IMPACT_REQUEST_SCHEMA,
    request_id: []const u8,
    operation: ImpactOperation,
    expected_checker_version: []const u8 = CHECKER_VERSION,
    kernel_sha256: []const u8,
    candidate_id: []const u8,
    project_sha256: []const u8,
    issuer_sha256: []const u8,
    bundle_sha256: []const u8,
    bundle_revision: u64,
    current_state: ImpactRuleState,
    source_interval_sha256: []const u8,
    label_receipt_sha256: []const u8,
    outcome_evidence_sha256: []const u8,
    usage_evidence_sha256: []const u8,
    facts: ImpactFacts,
    policy: ImpactPolicy,
};

pub const ImpactInput = struct {
    session_dir: []const u8,
    receipt_id: [64]u8,
    expected_issuer_sha256: [64]u8,
    rule_index: usize,
    operation: ImpactOperation,
    current_state: ImpactRuleState,
    policy: ImpactPolicy,
};

const ImpactAggregateWindow = struct {
    project_sha256: []const u8,
    issuer_sha256: []const u8,
    candidate_id: []const u8,
    bundle_sha256: []const u8,
    bundle_revision: u64,
    session_id: []const u8,
    run_id: []const u8,
    first_sequence: u64,
    last_sequence: u64,
    source_interval_sha256: []const u8,
    label_receipt_sha256: []const u8,
    outcome_evidence_sha256: []const u8,
    usage_evidence_sha256: []const u8,
    facts: impact_aggregate.Facts,
};

const ImpactAggregateRequest = struct {
    schema_version: []const u8 = IMPACT_AGGREGATE_REQUEST_SCHEMA,
    request_id: []const u8,
    operation: ImpactOperation,
    expected_checker_version: []const u8 = CHECKER_VERSION,
    kernel_sha256: []const u8,
    candidate_id: []const u8,
    project_sha256: []const u8,
    issuer_sha256: []const u8,
    bundle_sha256: []const u8,
    bundle_revision: u64,
    current_state: ImpactRuleState,
    policy_epoch: u64,
    expected_policy_epoch: u64,
    aggregate_receipt_sha256: []const u8,
    members_sha256: []const u8,
    source_intervals_sha256: []const u8,
    outcome_evidence_sha256: []const u8,
    usage_evidence_sha256: []const u8,
    facts: impact_aggregate.Facts,
    members: []const ImpactAggregateWindow,
    policy: ImpactPolicy,
};

pub const ImpactAggregateInput = struct {
    aggregate_dir: []const u8,
    receipt_id: [64]u8,
    expected_issuer_sha256: [64]u8,
    expected_policy_epoch: u64,
    operation: ImpactOperation,
    current_state: ImpactRuleState,
    policy: ImpactPolicy,
};

pub const ImpactBindings = struct {
    request_id: [64]u8,
    operation: ImpactOperation,
    kernel_sha256: [64]u8,
    candidate_id: [64]u8,
    project_sha256: [64]u8,
    issuer_sha256: [64]u8,
    bundle_sha256: [64]u8,
    bundle_revision: u64,
    source_interval_sha256: [64]u8,
    label_receipt_sha256: [64]u8,
    outcome_evidence_sha256: [64]u8,
    usage_evidence_sha256: [64]u8,
};

pub const ImpactAggregateBindings = struct {
    request_id: [64]u8,
    operation: ImpactOperation,
    kernel_sha256: [64]u8,
    candidate_id: [64]u8,
    project_sha256: [64]u8,
    issuer_sha256: [64]u8,
    bundle_sha256: [64]u8,
    bundle_revision: u64,
    policy_epoch: u64,
    aggregate_receipt_sha256: [64]u8,
    members_sha256: [64]u8,
    source_intervals_sha256: [64]u8,
    outcome_evidence_sha256: [64]u8,
    usage_evidence_sha256: [64]u8,
};

pub const ImpactChecks = struct {
    bindings_valid: bool,
    evidence_valid: bool,
    counts_consistent: bool,
    usage_consistent: bool,
    lifecycle_valid: bool,
    policy_satisfied: bool,

    pub fn all(self: ImpactChecks) bool {
        return self.bindings_valid and self.evidence_valid and self.counts_consistent and
            self.usage_consistent and
            self.lifecycle_valid and self.policy_satisfied;
    }
};

pub const ImpactAggregateChecks = struct {
    bindings_valid: bool,
    evidence_valid: bool,
    members_valid: bool,
    aggregate_exact: bool,
    counts_consistent: bool,
    usage_consistent: bool,
    lifecycle_valid: bool,
    policy_satisfied: bool,

    pub fn all(self: ImpactAggregateChecks) bool {
        return self.bindings_valid and self.evidence_valid and self.members_valid and
            self.aggregate_exact and self.counts_consistent and self.usage_consistent and
            self.lifecycle_valid and self.policy_satisfied;
    }
};

pub const ImpactAggregateVerdict = struct {
    admitted: bool,
    checks: ImpactAggregateChecks,
};

pub const ImpactAggregateInvocation = struct {
    bindings: ImpactAggregateBindings,
    failure: FailureKind = .none,
    actual_checker_sha256: [64]u8 = [_]u8{'0'} ** 64,
    request_sha256: [64]u8 = [_]u8{'0'} ** 64,
    verdict_sha256: ?[64]u8 = null,
    checker_bytes: u64 = 0,
    request_bytes: u64 = 0,
    observer_elapsed_ns: u64 = 0,
    checker_elapsed_ns: u64 = 0,
    stdout: ?[]u8 = null,
    stderr: ?[]u8 = null,
    verdict_payload: ?[]const u8 = null,
    verdict: ?ImpactAggregateVerdict = null,

    pub fn deinit(self: *ImpactAggregateInvocation, allocator: std.mem.Allocator) void {
        if (self.stdout) |bytes| allocator.free(bytes);
        if (self.stderr) |bytes| allocator.free(bytes);
        self.* = undefined;
    }

    pub fn checkerAdmitted(self: *const ImpactAggregateInvocation) bool {
        return self.failure == .none and self.verdict != null and self.verdict.?.admitted;
    }
};

pub const ImpactVerdict = struct {
    admitted: bool,
    checks: ImpactChecks,
};

pub const ImpactInvocation = struct {
    bindings: ImpactBindings,
    failure: FailureKind = .none,
    actual_checker_sha256: [64]u8 = [_]u8{'0'} ** 64,
    request_sha256: [64]u8 = [_]u8{'0'} ** 64,
    verdict_sha256: ?[64]u8 = null,
    checker_bytes: u64 = 0,
    checker_elapsed_ns: u64 = 0,
    stdout: ?[]u8 = null,
    stderr: ?[]u8 = null,
    verdict_payload: ?[]const u8 = null,
    verdict: ?ImpactVerdict = null,

    pub fn deinit(self: *ImpactInvocation, allocator: std.mem.Allocator) void {
        if (self.stdout) |bytes| allocator.free(bytes);
        if (self.stderr) |bytes| allocator.free(bytes);
        self.* = undefined;
    }

    pub fn checkerAdmitted(self: *const ImpactInvocation) bool {
        return self.failure == .none and self.verdict != null and self.verdict.?.admitted;
    }
};

const RawImpactVerdict = struct {
    schema_version: []const u8,
    checker_version: []const u8,
    request_id: []const u8,
    operation: ImpactOperation,
    kernel_sha256: []const u8,
    candidate_id: []const u8,
    project_sha256: []const u8,
    issuer_sha256: []const u8,
    bundle_sha256: []const u8,
    bundle_revision: u64,
    source_interval_sha256: []const u8,
    label_receipt_sha256: []const u8,
    outcome_evidence_sha256: []const u8,
    usage_evidence_sha256: []const u8,
    decision: []const u8,
    admitted: bool,
    reason_codes: [][]const u8,
    checks: ImpactChecks,
};

const RawImpactAggregateVerdict = struct {
    schema_version: []const u8,
    checker_version: []const u8,
    request_id: []const u8,
    operation: ImpactOperation,
    kernel_sha256: []const u8,
    candidate_id: []const u8,
    project_sha256: []const u8,
    issuer_sha256: []const u8,
    bundle_sha256: []const u8,
    bundle_revision: u64,
    policy_epoch: u64,
    aggregate_receipt_sha256: []const u8,
    members_sha256: []const u8,
    source_intervals_sha256: []const u8,
    outcome_evidence_sha256: []const u8,
    usage_evidence_sha256: []const u8,
    decision: []const u8,
    admitted: bool,
    reason_codes: [][]const u8,
    checks: ImpactAggregateChecks,
};

pub const PromotionFacts = struct {
    source_kind: SourceKind,
    source_receipt_bound: bool,
    proposer: []const u8,
    builder: []const u8,
    auditor: []const u8,
    replay_evaluator: []const u8,
    shadow_evaluator: []const u8,
    promoter: []const u8,
    replay_checker: []const u8,
    shadow_checker: []const u8,
    build_receipt: []const u8,
    axiom_predecessor: []const u8,
    axiom_receipt: []const u8,
    replay_predecessor: []const u8,
    replay_receipt: []const u8,
    shadow_predecessor: []const u8,
    build_manifest: []const u8,
    rule_spec_sha256: []const u8,
    sdk_olean: []const u8,
    build_completed: bool,
    axiom_completed: bool,
    forbidden_declaration_count: u32,
    unexpected_axiom_count: u32,
    replay_completed: bool,
    replay_positive_cases: u32,
    replay_negative_cases: u32,
    replay_false_positive_count: u32,
    replay_false_negative_count: u32,
    shadow_completed: bool,
    shadow_observed_decisions: u32,
    shadow_divergence_count: u32,
    shadow_side_effect_count: u32,
    previous_revision: u64,
    previous_bundle_sha256: []const u8,
    previous_rule_count: u32,
    bundle_rule_count: u32,
    candidate_occurrences: u32,
};

pub const Payload = union(enum) {
    promotion: PromotionFacts,
    pre: spec_mod.PreSignal,
    post: spec_mod.PostSignal,
    recovery_pre: spec_mod.RecoveryPreSignal,
    recovery_post: spec_mod.RecoveryPostSignal,
};

pub const Request = struct {
    schema_version: []const u8 = REQUEST_SCHEMA,
    request_id: []const u8,
    operation: Operation,
    expected_checker_version: []const u8 = CHECKER_VERSION,
    kernel_sha256: []const u8,
    candidate_id: []const u8,
    project_sha256: []const u8,
    bundle_sha256: []const u8,
    bundle_revision: u64,
    rule_spec: spec_mod.Wire,
    payload: Payload,
};

const BatchRequest = struct {
    schema_version: []const u8 = BATCH_REQUEST_SCHEMA,
    requests: []const Request,
};

pub const Bindings = struct {
    request_id: [64]u8,
    operation: Operation,
    kernel_sha256: [64]u8,
    candidate_id: [64]u8,
    project_sha256: [64]u8,
    bundle_sha256: [64]u8,
    bundle_revision: u64,
};

pub const Checks = struct {
    request_valid: bool,
    rule_valid: bool,
    lifecycle_valid: bool,
    decision_valid: bool,

    pub fn all(self: Checks) bool {
        return self.request_valid and self.rule_valid and
            self.lifecycle_valid and self.decision_valid;
    }
};

/// Recovery is proof-carrying output from the hash-pinned Lean kernel. The
/// native gate turns it into an exact-edit obligation; it is never an
/// authorization bypass.
pub const RecoveryAction = enum {
    none,
    edit_existing_file_exact,
};

pub const FailureKind = enum {
    none,
    request_oversize,
    config_invalid,
    checker_open_failed,
    checker_not_regular,
    checker_size_invalid,
    checker_read_failed,
    checker_changed_during_hash,
    checker_hash_mismatch,
    spawn_failed,
    pipe_failed,
    read_failed,
    timeout,
    aborted,
    output_capped,
    checker_nonzero,
    checker_stderr,
    checker_changed_after_execution,
    malformed_verdict,
    verdict_schema_mismatch,
    checker_version_mismatch,
    verdict_binding_mismatch,
    inconsistent_verdict,
};

pub const Verdict = struct {
    admitted: bool,
    checks: Checks,
    recovery_action: RecoveryAction = .none,
};

pub const Invocation = struct {
    /// Exact bindings supplied to the native verifier.  Keeping them beside
    /// the verdict prevents a caller from reusing an admitted pre/post
    /// invocation as promotion evidence for another candidate or revision.
    bindings: ?Bindings = null,
    failure: FailureKind = .none,
    actual_checker_sha256: [64]u8 = [_]u8{'0'} ** 64,
    request_sha256: [64]u8 = [_]u8{'0'} ** 64,
    checker_call_sha256: ?[64]u8 = null,
    checker_verdict_sha256: ?[64]u8 = null,
    checker_batch_size: u32 = 1,
    verdict_sha256: ?[64]u8 = null,
    checker_bytes: u64 = 0,
    checker_elapsed_ns: u64 = 0,
    stdout: ?[]u8 = null,
    stderr: ?[]u8 = null,
    verdict_payload: ?[]const u8 = null,
    verdict: ?Verdict = null,

    pub fn deinit(self: *Invocation, allocator: std.mem.Allocator) void {
        if (self.stdout) |bytes| allocator.free(bytes);
        if (self.stderr) |bytes| allocator.free(bytes);
        self.* = undefined;
    }

    pub fn checkerAdmitted(self: *const Invocation) bool {
        return self.failure == .none and self.verdict != null and
            self.verdict.?.admitted;
    }
};

pub const BatchInvocation = struct {
    invocations: []Invocation,
    stdout: ?[]u8 = null,
    stderr: ?[]u8 = null,
    verdict_payload: ?[]const u8 = null,
    verdict_sha256: ?[64]u8 = null,

    pub fn deinit(self: *BatchInvocation, allocator: std.mem.Allocator) void {
        for (self.invocations) |*invocation| invocation.deinit(allocator);
        allocator.free(self.invocations);
        if (self.stdout) |bytes| allocator.free(bytes);
        if (self.stderr) |bytes| allocator.free(bytes);
        self.* = undefined;
    }
};

const RawVerdict = struct {
    schema_version: []const u8,
    checker_version: []const u8,
    request_id: []const u8,
    operation: Operation,
    kernel_sha256: []const u8,
    candidate_id: []const u8,
    project_sha256: []const u8,
    bundle_sha256: []const u8,
    bundle_revision: u64,
    decision: []const u8,
    admitted: bool,
    reason_codes: [][]const u8,
    checks: Checks,
};

const RawBatchVerdict = struct {
    schema_version: []const u8,
    checker_version: []const u8,
    verdicts: []RawVerdict,
};

pub fn requestId(
    operation: Operation,
    candidate_id: [64]u8,
    bundle_sha256: [64]u8,
    revision: u64,
    signal_json: []const u8,
) [64]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("metacodes-project-harness-request-id-v1\x00");
    hasher.update(@tagName(operation));
    hasher.update("\x00");
    hasher.update(&candidate_id);
    hasher.update(&bundle_sha256);
    var revision_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &revision_bytes, revision, .big);
    hasher.update(&revision_bytes);
    hasher.update(signal_json);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

pub fn renderRequest(allocator: std.mem.Allocator, request: Request) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, request, .{});
}

pub fn renderBatchRequest(allocator: std.mem.Allocator, requests: []const Request) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, BatchRequest{ .requests = requests }, .{});
}

const CheckerExecution = struct {
    failure: FailureKind = .none,
    actual_checker_sha256: [64]u8 = [_]u8{'0'} ** 64,
    checker_bytes: u64 = 0,
    checker_elapsed_ns: u64 = 0,
    stdout: ?[]u8 = null,
    stderr: ?[]u8 = null,

    fn deinit(self: *CheckerExecution, allocator: std.mem.Allocator) void {
        if (self.stdout) |bytes| allocator.free(bytes);
        if (self.stderr) |bytes| allocator.free(bytes);
        self.* = undefined;
    }
};

fn executeChecker(
    allocator: std.mem.Allocator,
    config: Config,
    input: []const u8,
    max_input_bytes: usize,
    max_output_bytes: usize,
    abort: ?*const AbortSignal,
) error{OutOfMemory}!CheckerExecution {
    var result = CheckerExecution{};
    errdefer result.deinit(allocator);
    if (input.len == 0 or input.len > max_input_bytes) {
        result.failure = .request_oversize;
        return result;
    }
    if (!std.fs.path.isAbsolute(config.checker_path) or
        parseLowerHex64(&config.expected_sha256) == null or
        config.timeout_ms < 100 or config.timeout_ms > 30_000)
    {
        result.failure = .config_invalid;
        return result;
    }

    const digest = hashChecker(allocator, config.checker_path) catch |err| {
        result.failure = switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.OpenFailed => .checker_open_failed,
            error.NotRegular => .checker_not_regular,
            error.SizeInvalid => .checker_size_invalid,
            error.ReadFailed => .checker_read_failed,
            error.ChangedDuringHash => .checker_changed_during_hash,
        };
        return result;
    };
    result.actual_checker_sha256 = digest.sha256;
    result.checker_bytes = digest.bytes;
    if (!std.mem.eql(u8, &digest.sha256, &config.expected_sha256)) {
        result.failure = .checker_hash_mismatch;
        return result;
    }

    const checker_z = allocator.dupeZ(u8, config.checker_path) catch return error.OutOfMemory;
    defer allocator.free(checker_z);
    const argv = [_]?[*:0]const u8{ checker_z.ptr, null };
    const started = time.nowNs();
    const captured = process.capture(&argv, allocator, .{
        .timeout_ms = config.timeout_ms,
        .max_bytes = max_output_bytes,
        .want_stderr = true,
        .stdin_data = input,
        .inherit_env = false,
        .abort_ctx = if (abort) |signal| @ptrCast(signal) else null,
        .abort_poll = if (abort != null) abortPoll else null,
    }) catch |err| {
        result.checker_elapsed_ns = elapsedNs(started);
        result.failure = switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.SpawnFailed => .spawn_failed,
            error.PipeFailed => .pipe_failed,
            error.ReadError => .read_failed,
            error.Timeout => .timeout,
            error.Aborted => .aborted,
        };
        return result;
    };
    result.stdout = captured.stdout;
    result.stderr = captured.stderr;
    result.checker_elapsed_ns = elapsedNs(started);
    if (captured.stdout.len >= max_output_bytes or captured.stderr.len >= max_output_bytes) {
        result.failure = .output_capped;
        return result;
    }
    if (captured.exit_code != 0) {
        result.failure = .checker_nonzero;
        return result;
    }
    if (captured.stderr.len != 0) {
        result.failure = .checker_stderr;
        return result;
    }

    const post_digest = hashChecker(allocator, config.checker_path) catch {
        result.failure = .checker_changed_after_execution;
        return result;
    };
    if (post_digest.bytes != digest.bytes or
        !std.mem.eql(u8, &post_digest.sha256, &digest.sha256) or
        !std.mem.eql(u8, &post_digest.sha256, &config.expected_sha256))
    {
        result.failure = .checker_changed_after_execution;
    }
    return result;
}

fn transferExecution(result: *Invocation, execution: *CheckerExecution) void {
    result.failure = execution.failure;
    result.actual_checker_sha256 = execution.actual_checker_sha256;
    result.checker_bytes = execution.checker_bytes;
    result.checker_elapsed_ns = execution.checker_elapsed_ns;
    result.stdout = execution.stdout;
    result.stderr = execution.stderr;
    execution.stdout = null;
    execution.stderr = null;
}

pub fn invoke(
    allocator: std.mem.Allocator,
    config: Config,
    request: Request,
    bindings: Bindings,
    abort: ?*const AbortSignal,
) error{OutOfMemory}!Invocation {
    var result = Invocation{ .bindings = bindings };
    errdefer result.deinit(allocator);
    const input = renderRequest(allocator, request) catch return error.OutOfMemory;
    defer allocator.free(input);
    result.request_sha256 = observation.sha256Hex(input);
    result.checker_call_sha256 = result.request_sha256;
    var execution = try executeChecker(
        allocator,
        config,
        input,
        MAX_REQUEST_BYTES,
        MAX_OUTPUT_BYTES,
        abort,
    );
    defer execution.deinit(allocator);
    transferExecution(&result, &execution);
    if (result.failure != .none) return result;

    const payload = verdictPayload(result.stdout.?) orelse {
        result.failure = .malformed_verdict;
        return result;
    };
    result.verdict_payload = payload;
    result.verdict_sha256 = observation.sha256Hex(payload);
    result.checker_verdict_sha256 = result.verdict_sha256;
    result.verdict = parseVerdict(allocator, payload, bindings) catch |err| {
        result.failure = switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidJson => .malformed_verdict,
            error.SchemaMismatch => .verdict_schema_mismatch,
            error.VersionMismatch => .checker_version_mismatch,
            error.BindingMismatch => .verdict_binding_mismatch,
            error.Inconsistent => .inconsistent_verdict,
        };
        return result;
    };
    return result;
}

/// Invoke the same hash-pinned project kernel for one authenticated RuleImpact
/// governance transition. This is intentionally outside the ordinary tool
/// dispatch path: missing observer evidence must block governance, not tasks.
pub fn invokeImpact(
    allocator: std.mem.Allocator,
    config: Config,
    input: ImpactInput,
    abort: ?*const AbortSignal,
) !ImpactInvocation {
    // Reopen the completed journal, receipt, and both evidence artifacts at the
    // only public checker boundary. A caller-constructed Snapshot is never an
    // authorization input, even if it copies `evidence.authenticated = true`.
    var authenticated = impact_receipt.deriveImpact(
        allocator,
        input.session_dir,
        input.receipt_id,
    ) catch return error.InvalidImpactEvidence;
    defer authenticated.deinit(allocator);
    const snapshot = &authenticated.snapshot;
    if (input.rule_index >= snapshot.rules.len or !snapshot.evidence.authenticated)
        return error.InvalidImpactInput;
    const rule = snapshot.rules[input.rule_index];
    if (!std.mem.eql(u8, &rule.identity.project_sha256, &authenticated.project_sha256) or
        !std.mem.eql(u8, &authenticated.issuer_sha256, &input.expected_issuer_sha256) or
        parseLowerHex64(&snapshot.source_interval_sha256) == null or
        parseLowerHex64(&snapshot.evidence.label_receipt_sha256) == null or
        parseLowerHex64(&snapshot.evidence.outcome_evidence_sha256) == null or
        parseLowerHex64(&snapshot.evidence.usage_evidence_sha256) == null)
        return error.InvalidImpactInput;
    const labels = snapshot.labels;
    const task_success = labels.task_success orelse return error.IncompleteImpactLabels;
    const trustworthy_success = labels.trustworthy_success orelse return error.IncompleteImpactLabels;
    const drift_detected = labels.drift_detected orelse return error.IncompleteImpactLabels;
    const false_interventions = labels.false_interventions orelse return error.IncompleteImpactLabels;
    const regressions = labels.regressions orelse return error.IncompleteImpactLabels;
    const provider_requests = labels.provider_requests orelse return error.IncompleteImpactLabels;
    const input_tokens = labels.input_tokens orelse return error.IncompleteImpactLabels;
    const output_tokens = labels.output_tokens orelse return error.IncompleteImpactLabels;
    const cache_read_tokens = labels.cache_read_tokens orelse return error.IncompleteImpactLabels;
    const cache_write_tokens = labels.cache_write_tokens orelse return error.IncompleteImpactLabels;
    const metered_tokens = labels.metered_tokens orelse return error.IncompleteImpactLabels;
    const cost_microusd = labels.cost_microusd orelse return error.IncompleteImpactLabels;
    const wall_elapsed_ns = labels.wall_elapsed_ns orelse return error.IncompleteImpactLabels;
    const shadow_divergences = std.math.add(
        u64,
        rule.shadow_pre_blocks_followed_by_dispatch,
        rule.shadow_pre_faults_followed_by_dispatch,
    ) catch return error.InvalidImpactInput;
    const facts = ImpactFacts{
        .completed_run = true,
        .evidence_authenticated = true,
        // One receipt authenticates exactly one completed Run. Cross-window
        // aggregation needs its own deterministic, deduplicating receipt and is
        // deliberately not caller-configurable in this stage-one adapter.
        .window_occurrences = 1,
        .formal_decisions = snapshot.formal_decisions,
        .formal_faults = snapshot.formal_faults,
        .exposures = rule.exposures,
        .admits = rule.admits,
        .blocks = rule.blocks,
        .faults = rule.faults,
        .shadow_divergences = shadow_divergences,
        .task_success = task_success,
        .trustworthy_success = trustworthy_success,
        .drift_detected = drift_detected,
        .false_interventions = false_interventions,
        .regressions = regressions,
        .physical_checker_calls = snapshot.physical_checker_calls,
        .checker_elapsed_ns = snapshot.checker_elapsed_ns,
        .provider_requests = provider_requests,
        .input_tokens = input_tokens,
        .output_tokens = output_tokens,
        .cache_read_tokens = cache_read_tokens,
        .cache_write_tokens = cache_write_tokens,
        .metered_tokens = metered_tokens,
        .cost_microusd = cost_microusd,
        .wall_elapsed_ns = wall_elapsed_ns,
    };
    const zero = [_]u8{'0'} ** 64;
    const provisional = ImpactRequest{
        .request_id = &zero,
        .operation = input.operation,
        .kernel_sha256 = &config.expected_sha256,
        .candidate_id = &rule.identity.candidate_id,
        .project_sha256 = &rule.identity.project_sha256,
        .issuer_sha256 = &authenticated.issuer_sha256,
        .bundle_sha256 = &rule.identity.bundle_sha256,
        .bundle_revision = rule.identity.bundle_revision,
        .current_state = input.current_state,
        .source_interval_sha256 = &snapshot.source_interval_sha256,
        .label_receipt_sha256 = &snapshot.evidence.label_receipt_sha256,
        .outcome_evidence_sha256 = &snapshot.evidence.outcome_evidence_sha256,
        .usage_evidence_sha256 = &snapshot.evidence.usage_evidence_sha256,
        .facts = facts,
        .policy = input.policy,
    };
    const provisional_json = try std.json.Stringify.valueAlloc(allocator, provisional, .{});
    defer allocator.free(provisional_json);
    const request_id = observation.sha256Hex(provisional_json);
    const request = ImpactRequest{
        .request_id = &request_id,
        .operation = input.operation,
        .kernel_sha256 = &config.expected_sha256,
        .candidate_id = &rule.identity.candidate_id,
        .project_sha256 = &rule.identity.project_sha256,
        .issuer_sha256 = &authenticated.issuer_sha256,
        .bundle_sha256 = &rule.identity.bundle_sha256,
        .bundle_revision = rule.identity.bundle_revision,
        .current_state = input.current_state,
        .source_interval_sha256 = &snapshot.source_interval_sha256,
        .label_receipt_sha256 = &snapshot.evidence.label_receipt_sha256,
        .outcome_evidence_sha256 = &snapshot.evidence.outcome_evidence_sha256,
        .usage_evidence_sha256 = &snapshot.evidence.usage_evidence_sha256,
        .facts = facts,
        .policy = input.policy,
    };
    const bindings = ImpactBindings{
        .request_id = request_id,
        .operation = input.operation,
        .kernel_sha256 = config.expected_sha256,
        .candidate_id = rule.identity.candidate_id,
        .project_sha256 = rule.identity.project_sha256,
        .issuer_sha256 = authenticated.issuer_sha256,
        .bundle_sha256 = rule.identity.bundle_sha256,
        .bundle_revision = rule.identity.bundle_revision,
        .source_interval_sha256 = snapshot.source_interval_sha256,
        .label_receipt_sha256 = snapshot.evidence.label_receipt_sha256,
        .outcome_evidence_sha256 = snapshot.evidence.outcome_evidence_sha256,
        .usage_evidence_sha256 = snapshot.evidence.usage_evidence_sha256,
    };
    var result = ImpactInvocation{ .bindings = bindings };
    errdefer result.deinit(allocator);
    const request_json = try std.json.Stringify.valueAlloc(allocator, request, .{});
    defer allocator.free(request_json);
    result.request_sha256 = observation.sha256Hex(request_json);
    var execution = try executeChecker(
        allocator,
        config,
        request_json,
        MAX_REQUEST_BYTES,
        MAX_OUTPUT_BYTES,
        abort,
    );
    defer execution.deinit(allocator);
    result.failure = execution.failure;
    result.actual_checker_sha256 = execution.actual_checker_sha256;
    result.checker_bytes = execution.checker_bytes;
    result.checker_elapsed_ns = execution.checker_elapsed_ns;
    result.stdout = execution.stdout;
    result.stderr = execution.stderr;
    execution.stdout = null;
    execution.stderr = null;
    if (result.failure != .none) return result;
    const payload = verdictPayload(result.stdout.?) orelse {
        result.failure = .malformed_verdict;
        return result;
    };
    result.verdict_payload = payload;
    result.verdict_sha256 = observation.sha256Hex(payload);
    result.verdict = parseImpactVerdict(allocator, payload, bindings) catch |err| {
        result.failure = switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidJson => .malformed_verdict,
            error.SchemaMismatch => .verdict_schema_mismatch,
            error.VersionMismatch => .checker_version_mismatch,
            error.BindingMismatch => .verdict_binding_mismatch,
            error.Inconsistent => .inconsistent_verdict,
        };
        return result;
    };
    return result;
}

/// Reauthenticate and govern a bounded, content-addressed cross-window
/// aggregate. The request carries every member's exact facts so Lean can
/// independently reject duplicate/overlapping windows and inexact sums.
pub fn invokeImpactAggregate(
    allocator: std.mem.Allocator,
    config: Config,
    input: ImpactAggregateInput,
    abort: ?*const AbortSignal,
) !ImpactAggregateInvocation {
    if (input.expected_policy_epoch == 0 or
        parseLowerHex64(&input.expected_issuer_sha256) == null)
        return error.InvalidImpactInput;
    const observer_started = time.nowNs();
    var aggregate = impact_aggregate.loadBound(
        allocator,
        input.aggregate_dir,
        input.receipt_id,
    ) catch return error.InvalidImpactEvidence;
    defer aggregate.deinit();
    if (!std.mem.eql(u8, &aggregate.issuer_sha256, &input.expected_issuer_sha256) or
        aggregate.members.len == 0 or aggregate.members.len > impact_aggregate.MAX_MEMBERS)
        return error.InvalidImpactInput;
    const windows = try allocator.alloc(ImpactAggregateWindow, aggregate.members.len);
    defer allocator.free(windows);
    for (aggregate.members, windows) |*member, *window| window.* = .{
        .project_sha256 = &member.project_sha256,
        .issuer_sha256 = &member.issuer_sha256,
        .candidate_id = &member.candidate_id,
        .bundle_sha256 = &member.bundle_sha256,
        .bundle_revision = member.bundle_revision,
        .session_id = member.session_id.asSlice(),
        .run_id = member.run_id.asSlice(),
        .first_sequence = member.first_sequence,
        .last_sequence = member.last_sequence,
        .source_interval_sha256 = &member.source_interval_sha256,
        .label_receipt_sha256 = &member.label_receipt_sha256,
        .outcome_evidence_sha256 = &member.outcome_evidence_sha256,
        .usage_evidence_sha256 = &member.usage_evidence_sha256,
        .facts = member.facts,
    };
    const zero = [_]u8{'0'} ** 64;
    const provisional = ImpactAggregateRequest{
        .request_id = &zero,
        .operation = input.operation,
        .kernel_sha256 = &config.expected_sha256,
        .candidate_id = &aggregate.identity.candidate_id,
        .project_sha256 = &aggregate.identity.project_sha256,
        .issuer_sha256 = &aggregate.issuer_sha256,
        .bundle_sha256 = &aggregate.identity.bundle_sha256,
        .bundle_revision = aggregate.identity.bundle_revision,
        .current_state = input.current_state,
        .policy_epoch = aggregate.policy_epoch,
        .expected_policy_epoch = input.expected_policy_epoch,
        .aggregate_receipt_sha256 = &aggregate.aggregate_receipt_id,
        .members_sha256 = &aggregate.members_sha256,
        .source_intervals_sha256 = &aggregate.source_intervals_sha256,
        .outcome_evidence_sha256 = &aggregate.outcome_evidence_sha256,
        .usage_evidence_sha256 = &aggregate.usage_evidence_sha256,
        .facts = aggregate.facts,
        .members = windows,
        .policy = input.policy,
    };
    const provisional_json = try std.json.Stringify.valueAlloc(allocator, provisional, .{});
    defer allocator.free(provisional_json);
    const request_id = observation.sha256Hex(provisional_json);
    const request = ImpactAggregateRequest{
        .request_id = &request_id,
        .operation = input.operation,
        .kernel_sha256 = &config.expected_sha256,
        .candidate_id = &aggregate.identity.candidate_id,
        .project_sha256 = &aggregate.identity.project_sha256,
        .issuer_sha256 = &aggregate.issuer_sha256,
        .bundle_sha256 = &aggregate.identity.bundle_sha256,
        .bundle_revision = aggregate.identity.bundle_revision,
        .current_state = input.current_state,
        .policy_epoch = aggregate.policy_epoch,
        .expected_policy_epoch = input.expected_policy_epoch,
        .aggregate_receipt_sha256 = &aggregate.aggregate_receipt_id,
        .members_sha256 = &aggregate.members_sha256,
        .source_intervals_sha256 = &aggregate.source_intervals_sha256,
        .outcome_evidence_sha256 = &aggregate.outcome_evidence_sha256,
        .usage_evidence_sha256 = &aggregate.usage_evidence_sha256,
        .facts = aggregate.facts,
        .members = windows,
        .policy = input.policy,
    };
    const bindings = ImpactAggregateBindings{
        .request_id = request_id,
        .operation = input.operation,
        .kernel_sha256 = config.expected_sha256,
        .candidate_id = aggregate.identity.candidate_id,
        .project_sha256 = aggregate.identity.project_sha256,
        .issuer_sha256 = aggregate.issuer_sha256,
        .bundle_sha256 = aggregate.identity.bundle_sha256,
        .bundle_revision = aggregate.identity.bundle_revision,
        .policy_epoch = aggregate.policy_epoch,
        .aggregate_receipt_sha256 = aggregate.aggregate_receipt_id,
        .members_sha256 = aggregate.members_sha256,
        .source_intervals_sha256 = aggregate.source_intervals_sha256,
        .outcome_evidence_sha256 = aggregate.outcome_evidence_sha256,
        .usage_evidence_sha256 = aggregate.usage_evidence_sha256,
    };
    var result = ImpactAggregateInvocation{
        .bindings = bindings,
    };
    errdefer result.deinit(allocator);
    const request_json = try std.json.Stringify.valueAlloc(allocator, request, .{});
    defer allocator.free(request_json);
    result.request_bytes = @intCast(request_json.len);
    result.observer_elapsed_ns = elapsedNs(observer_started);
    result.request_sha256 = observation.sha256Hex(request_json);
    var execution = try executeChecker(
        allocator,
        config,
        request_json,
        MAX_REQUEST_BYTES,
        MAX_OUTPUT_BYTES,
        abort,
    );
    defer execution.deinit(allocator);
    result.failure = execution.failure;
    result.actual_checker_sha256 = execution.actual_checker_sha256;
    result.checker_bytes = execution.checker_bytes;
    result.checker_elapsed_ns = execution.checker_elapsed_ns;
    result.stdout = execution.stdout;
    result.stderr = execution.stderr;
    execution.stdout = null;
    execution.stderr = null;
    if (result.failure != .none) return result;
    const payload = verdictPayload(result.stdout.?) orelse {
        result.failure = .malformed_verdict;
        return result;
    };
    result.verdict_payload = payload;
    result.verdict_sha256 = observation.sha256Hex(payload);
    result.verdict = parseImpactAggregateVerdict(allocator, payload, bindings) catch |err| {
        result.failure = switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidJson => .malformed_verdict,
            error.SchemaMismatch => .verdict_schema_mismatch,
            error.VersionMismatch => .checker_version_mismatch,
            error.BindingMismatch => .verdict_binding_mismatch,
            error.Inconsistent => .inconsistent_verdict,
        };
        return result;
    };
    return result;
}

pub fn invokeBatch(
    allocator: std.mem.Allocator,
    config: Config,
    requests: []const Request,
    bindings: []const Bindings,
    abort: ?*const AbortSignal,
) error{ OutOfMemory, InvalidBatch }!BatchInvocation {
    if (requests.len == 0 or requests.len != bindings.len or
        requests.len > MAX_BATCH_REQUESTS)
        return error.InvalidBatch;
    const invocations = allocator.alloc(Invocation, requests.len) catch return error.OutOfMemory;
    var initialized: usize = 0;
    errdefer {
        for (invocations[0..initialized]) |*invocation| invocation.deinit(allocator);
        allocator.free(invocations);
    }
    for (requests, bindings, 0..) |request, binding, index| {
        invocations[index] = .{ .bindings = binding };
        initialized += 1;
        const individual = renderRequest(allocator, request) catch return error.OutOfMemory;
        defer allocator.free(individual);
        invocations[index].request_sha256 = observation.sha256Hex(individual);
    }
    var result = BatchInvocation{ .invocations = invocations };
    errdefer result.deinit(allocator);
    const input = renderBatchRequest(allocator, requests) catch return error.OutOfMemory;
    defer allocator.free(input);
    const call_sha256 = observation.sha256Hex(input);
    const batch_size: u32 = @intCast(requests.len);
    for (result.invocations) |*invocation| {
        invocation.checker_call_sha256 = call_sha256;
        invocation.checker_batch_size = batch_size;
    }
    var execution = try executeChecker(
        allocator,
        config,
        input,
        MAX_BATCH_BYTES,
        MAX_BATCH_BYTES,
        abort,
    );
    defer execution.deinit(allocator);
    for (result.invocations) |*invocation| {
        invocation.failure = execution.failure;
        invocation.actual_checker_sha256 = execution.actual_checker_sha256;
        invocation.checker_bytes = execution.checker_bytes;
        invocation.checker_elapsed_ns = execution.checker_elapsed_ns;
    }
    result.stdout = execution.stdout;
    result.stderr = execution.stderr;
    execution.stdout = null;
    execution.stderr = null;
    if (execution.failure != .none) return result;
    const payload = verdictPayload(result.stdout.?) orelse {
        invalidateBatch(allocator, result.invocations, .malformed_verdict);
        return result;
    };
    var parsed = std.json.parseFromSlice(RawBatchVerdict, allocator, payload, .{
        .ignore_unknown_fields = false,
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            invalidateBatch(allocator, result.invocations, .malformed_verdict);
            return result;
        },
    };
    defer parsed.deinit();
    const canonical = std.json.Stringify.valueAlloc(allocator, parsed.value, .{}) catch
        return error.OutOfMemory;
    defer allocator.free(canonical);
    if (!std.mem.eql(u8, canonical, payload)) {
        invalidateBatch(allocator, result.invocations, .malformed_verdict);
        return result;
    }
    if (!std.mem.eql(u8, parsed.value.schema_version, BATCH_VERDICT_SCHEMA)) {
        invalidateBatch(allocator, result.invocations, .verdict_schema_mismatch);
        return result;
    }
    if (!std.mem.eql(u8, parsed.value.checker_version, CHECKER_VERSION)) {
        invalidateBatch(allocator, result.invocations, .checker_version_mismatch);
        return result;
    }
    if (parsed.value.verdicts.len != result.invocations.len) {
        invalidateBatch(allocator, result.invocations, .verdict_binding_mismatch);
        return result;
    }
    const batch_verdict_sha256 = observation.sha256Hex(payload);
    for (parsed.value.verdicts, result.invocations) |raw, *invocation| {
        invocation.verdict = validateRawVerdict(raw, invocation.bindings.?) catch |err| {
            invalidateBatch(allocator, result.invocations, parseFailure(err));
            return result;
        };
        const item_payload = std.json.Stringify.valueAlloc(allocator, raw, .{}) catch
            return error.OutOfMemory;
        invocation.stdout = item_payload;
        invocation.verdict_payload = item_payload;
        invocation.verdict_sha256 = observation.sha256Hex(item_payload);
    }
    // The outer payload is a verdict only after every member has passed its
    // exact binding check.  Publishing its hash earlier would let a
    // same-cardinality batch with one mismatched member look like durable
    // checker evidence even though the whole call must fail closed.
    result.verdict_payload = payload;
    result.verdict_sha256 = batch_verdict_sha256;
    for (result.invocations) |*invocation|
        invocation.checker_verdict_sha256 = batch_verdict_sha256;
    return result;
}

fn invalidateBatch(
    allocator: std.mem.Allocator,
    invocations: []Invocation,
    failure: FailureKind,
) void {
    for (invocations) |*invocation| {
        if (invocation.stdout) |bytes| allocator.free(bytes);
        if (invocation.stderr) |bytes| allocator.free(bytes);
        invocation.stdout = null;
        invocation.stderr = null;
        invocation.verdict_payload = null;
        invocation.verdict_sha256 = null;
        invocation.checker_verdict_sha256 = null;
        invocation.verdict = null;
        invocation.failure = failure;
    }
}

const ParseError = error{ OutOfMemory, InvalidJson, SchemaMismatch, VersionMismatch, BindingMismatch, Inconsistent };

fn parseImpactVerdict(
    allocator: std.mem.Allocator,
    payload: []const u8,
    bindings: ImpactBindings,
) ParseError!ImpactVerdict {
    var parsed = std.json.parseFromSlice(RawImpactVerdict, allocator, payload, .{
        .ignore_unknown_fields = false,
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidJson,
    };
    defer parsed.deinit();
    const canonical = std.json.Stringify.valueAlloc(allocator, parsed.value, .{}) catch
        return error.OutOfMemory;
    defer allocator.free(canonical);
    if (!std.mem.eql(u8, canonical, payload)) return error.InvalidJson;
    const raw = parsed.value;
    if (!std.mem.eql(u8, raw.schema_version, IMPACT_VERDICT_SCHEMA)) return error.SchemaMismatch;
    if (!std.mem.eql(u8, raw.checker_version, CHECKER_VERSION)) return error.VersionMismatch;
    if (!equalHex(raw.request_id, bindings.request_id) or raw.operation != bindings.operation or
        !equalHex(raw.kernel_sha256, bindings.kernel_sha256) or
        !equalHex(raw.candidate_id, bindings.candidate_id) or
        !equalHex(raw.project_sha256, bindings.project_sha256) or
        !equalHex(raw.issuer_sha256, bindings.issuer_sha256) or
        !equalHex(raw.bundle_sha256, bindings.bundle_sha256) or
        raw.bundle_revision != bindings.bundle_revision or
        !equalHex(raw.source_interval_sha256, bindings.source_interval_sha256) or
        !equalHex(raw.label_receipt_sha256, bindings.label_receipt_sha256) or
        !equalHex(raw.outcome_evidence_sha256, bindings.outcome_evidence_sha256) or
        !equalHex(raw.usage_evidence_sha256, bindings.usage_evidence_sha256))
        return error.BindingMismatch;
    if ((!std.mem.eql(u8, raw.decision, "admit") and
        !std.mem.eql(u8, raw.decision, "block")) or
        raw.admitted != std.mem.eql(u8, raw.decision, "admit") or
        raw.admitted != raw.checks.all() or
        (raw.admitted and raw.reason_codes.len != 0) or
        (!raw.admitted and raw.reason_codes.len == 0))
        return error.Inconsistent;
    return .{ .admitted = raw.admitted, .checks = raw.checks };
}

fn parseImpactAggregateVerdict(
    allocator: std.mem.Allocator,
    payload: []const u8,
    bindings: ImpactAggregateBindings,
) ParseError!ImpactAggregateVerdict {
    var parsed = std.json.parseFromSlice(RawImpactAggregateVerdict, allocator, payload, .{
        .ignore_unknown_fields = false,
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidJson,
    };
    defer parsed.deinit();
    const canonical = std.json.Stringify.valueAlloc(allocator, parsed.value, .{}) catch
        return error.OutOfMemory;
    defer allocator.free(canonical);
    if (!std.mem.eql(u8, canonical, payload)) return error.InvalidJson;
    const raw = parsed.value;
    if (!std.mem.eql(u8, raw.schema_version, IMPACT_AGGREGATE_VERDICT_SCHEMA))
        return error.SchemaMismatch;
    if (!std.mem.eql(u8, raw.checker_version, CHECKER_VERSION)) return error.VersionMismatch;
    if (!equalHex(raw.request_id, bindings.request_id) or raw.operation != bindings.operation or
        !equalHex(raw.kernel_sha256, bindings.kernel_sha256) or
        !equalHex(raw.candidate_id, bindings.candidate_id) or
        !equalHex(raw.project_sha256, bindings.project_sha256) or
        !equalHex(raw.issuer_sha256, bindings.issuer_sha256) or
        !equalHex(raw.bundle_sha256, bindings.bundle_sha256) or
        raw.bundle_revision != bindings.bundle_revision or
        raw.policy_epoch != bindings.policy_epoch or
        !equalHex(raw.aggregate_receipt_sha256, bindings.aggregate_receipt_sha256) or
        !equalHex(raw.members_sha256, bindings.members_sha256) or
        !equalHex(raw.source_intervals_sha256, bindings.source_intervals_sha256) or
        !equalHex(raw.outcome_evidence_sha256, bindings.outcome_evidence_sha256) or
        !equalHex(raw.usage_evidence_sha256, bindings.usage_evidence_sha256))
        return error.BindingMismatch;
    if ((!std.mem.eql(u8, raw.decision, "admit") and
        !std.mem.eql(u8, raw.decision, "block")) or
        raw.admitted != std.mem.eql(u8, raw.decision, "admit") or
        raw.admitted != raw.checks.all() or
        (raw.admitted and raw.reason_codes.len != 0) or
        (!raw.admitted and raw.reason_codes.len == 0))
        return error.Inconsistent;
    return .{ .admitted = raw.admitted, .checks = raw.checks };
}

fn parseVerdict(allocator: std.mem.Allocator, payload: []const u8, bindings: Bindings) ParseError!Verdict {
    var parsed = std.json.parseFromSlice(RawVerdict, allocator, payload, .{
        .ignore_unknown_fields = false,
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidJson,
    };
    defer parsed.deinit();
    return validateRawVerdict(parsed.value, bindings);
}

fn validateRawVerdict(raw: RawVerdict, bindings: Bindings) ParseError!Verdict {
    if (!std.mem.eql(u8, raw.schema_version, VERDICT_SCHEMA)) return error.SchemaMismatch;
    if (!std.mem.eql(u8, raw.checker_version, CHECKER_VERSION)) return error.VersionMismatch;
    if (!equalHex(raw.request_id, bindings.request_id) or
        raw.operation != bindings.operation or
        !equalHex(raw.kernel_sha256, bindings.kernel_sha256) or
        !equalHex(raw.candidate_id, bindings.candidate_id) or
        !equalHex(raw.project_sha256, bindings.project_sha256) or
        !equalHex(raw.bundle_sha256, bindings.bundle_sha256) or
        raw.bundle_revision != bindings.bundle_revision)
        return error.BindingMismatch;
    if ((!std.mem.eql(u8, raw.decision, "admit") and
        !std.mem.eql(u8, raw.decision, "block")) or
        raw.admitted != std.mem.eql(u8, raw.decision, "admit") or
        !raw.checks.decision_valid or (raw.admitted and !raw.checks.all()))
        return error.Inconsistent;
    const recovery_count = countReason(raw.reason_codes, "recover_edit_existing_file_exact");
    const blocked_count = countReason(raw.reason_codes, "rule_precondition_blocked");
    if (recovery_count > 1 or
        (raw.admitted and raw.reason_codes.len != 0) or
        (recovery_count == 1 and
            ((raw.operation != .pre_decision and
                raw.operation != .recovery_pre_decision) or
                raw.admitted or blocked_count != 1 or
                raw.reason_codes.len != 2 or !raw.checks.all())))
        return error.Inconsistent;
    return .{
        .admitted = raw.admitted,
        .checks = raw.checks,
        .recovery_action = if (recovery_count == 1)
            .edit_existing_file_exact
        else
            .none,
    };
}

fn countReason(reasons: []const []const u8, expected: []const u8) usize {
    var count: usize = 0;
    for (reasons) |reason| {
        if (std.mem.eql(u8, reason, expected)) count += 1;
    }
    return count;
}

fn parseFailure(err: ParseError) FailureKind {
    return switch (err) {
        error.OutOfMemory => unreachable,
        error.InvalidJson => .malformed_verdict,
        error.SchemaMismatch => .verdict_schema_mismatch,
        error.VersionMismatch => .checker_version_mismatch,
        error.BindingMismatch => .verdict_binding_mismatch,
        error.Inconsistent => .inconsistent_verdict,
    };
}

/// Recover one exact candidate verdict from a canonical batch artifact. The
/// caller supplies the candidate verdict hash recorded in the durable journal;
/// a missing or duplicated member fails closed instead of trusting array order.
pub fn extractBatchVerdict(
    allocator: std.mem.Allocator,
    payload: []const u8,
    verdict_sha256: [64]u8,
) ![]u8 {
    var parsed = std.json.parseFromSlice(RawBatchVerdict, allocator, payload, .{
        .ignore_unknown_fields = false,
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    }) catch return error.InvalidBatchVerdict;
    defer parsed.deinit();
    const canonical = try std.json.Stringify.valueAlloc(allocator, parsed.value, .{});
    defer allocator.free(canonical);
    if (!std.mem.eql(u8, canonical, payload) or
        !std.mem.eql(u8, parsed.value.schema_version, BATCH_VERDICT_SCHEMA) or
        !std.mem.eql(u8, parsed.value.checker_version, CHECKER_VERSION) or
        parsed.value.verdicts.len == 0 or
        parsed.value.verdicts.len > MAX_BATCH_REQUESTS)
        return error.InvalidBatchVerdict;
    var found: ?[]u8 = null;
    errdefer if (found) |bytes| allocator.free(bytes);
    for (parsed.value.verdicts) |raw| {
        const item = try std.json.Stringify.valueAlloc(allocator, raw, .{});
        if (std.mem.eql(u8, &observation.sha256Hex(item), &verdict_sha256)) {
            if (found != null) {
                allocator.free(item);
                return error.DuplicateBatchVerdict;
            }
            found = item;
        } else {
            allocator.free(item);
        }
    }
    return found orelse error.BatchVerdictNotFound;
}

const HashError = error{ OutOfMemory, OpenFailed, NotRegular, SizeInvalid, ReadFailed, ChangedDuringHash };
const FileDigest = struct { sha256: [64]u8, bytes: u64 };

fn hashChecker(allocator: std.mem.Allocator, path: []const u8) HashError!FileDigest {
    const path_z = allocator.dupeZ(u8, path) catch return error.OutOfMemory;
    defer allocator.free(path_z);
    const fd = pfs.open(path_z.ptr, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true }, 0);
    if (fd < 0) return error.OpenFailed;
    defer _ = pfs.close(fd);
    const before = pfs.fileInfo(fd) catch return error.OpenFailed;
    if (!before.is_regular) return error.NotRegular;
    if (before.size == 0 or before.size > MAX_CHECKER_BYTES) return error.SizeInvalid;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var total: u64 = 0;
    var buffer: [64 * 1024]u8 = undefined;
    while (true) {
        const count = pfs.readZ(fd, &buffer) catch return error.ReadFailed;
        if (count == 0) break;
        total = std.math.add(u64, total, count) catch return error.SizeInvalid;
        if (total > MAX_CHECKER_BYTES) return error.SizeInvalid;
        hasher.update(buffer[0..count]);
    }
    const after = pfs.fileInfo(fd) catch return error.ChangedDuringHash;
    if (!after.is_regular or after.size != before.size or total != before.size)
        return error.ChangedDuringHash;
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return .{ .sha256 = std.fmt.bytesToHex(digest, .lower), .bytes = total };
}

fn verdictPayload(stdout: []const u8) ?[]const u8 {
    if (stdout.len < 2 or stdout[stdout.len - 1] != '\n') return null;
    const payload = stdout[0 .. stdout.len - 1];
    if (payload.len == 0 or std.mem.indexOfAny(u8, payload, "\r\n") != null) return null;
    return payload;
}

fn abortPoll(raw: ?*const anyopaque) bool {
    const signal: *const AbortSignal = @ptrCast(@alignCast(raw orelse return false));
    return signal.isAborted();
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

fn equalHex(raw: []const u8, expected: [64]u8) bool {
    const parsed = parseLowerHex64(raw) orelse return false;
    return std.mem.eql(u8, &parsed, &expected);
}

fn elapsedNs(start: i128) u64 {
    const elapsed = time.nowNs() - start;
    return if (elapsed <= 0) 0 else @intCast(@min(elapsed, std.math.maxInt(u64)));
}

test "project harness request rendering is byte-stable and identity-bound" {
    const signal = spec_mod.PreSignal{
        .tool = "Write",
        .input_bytes = 12,
        .agent_depth = 0,
        .authoritative = true,
    };
    const signal_json = try std.json.Stringify.valueAlloc(std.testing.allocator, signal, .{});
    defer std.testing.allocator.free(signal_json);
    const candidate = [_]u8{'a'} ** 64;
    const bundle = [_]u8{'b'} ** 64;
    const id = requestId(.pre_decision, candidate, bundle, 1, signal_json);
    const request = Request{
        .request_id = id[0..],
        .operation = .pre_decision,
        .kernel_sha256 = (&([_]u8{'d'} ** 64))[0..],
        .candidate_id = candidate[0..],
        .project_sha256 = (&([_]u8{'c'} ** 64))[0..],
        .bundle_sha256 = bundle[0..],
        .bundle_revision = 1,
        .rule_spec = spec_mod.toWire(.{
            .target = .{ .tool = "Write" },
            .deny_target = true,
            .max_input_bytes = 8192,
            .max_agent_depth = 4,
            .authoritative_only = true,
            .effect_requirement = .none,
        }),
        .payload = .{ .pre = signal },
    };
    const first = try renderRequest(std.testing.allocator, request);
    defer std.testing.allocator.free(first);
    const second = try renderRequest(std.testing.allocator, request);
    defer std.testing.allocator.free(second);
    try std.testing.expectEqualSlices(u8, first, second);
    try std.testing.expect(std.mem.indexOf(u8, first, "\"operation\":\"pre_decision\"") != null);
}

test "project harness verdict accepts only coherent Lean recovery reasons" {
    const request_id = [_]u8{'a'} ** 64;
    const kernel_sha256 = [_]u8{'b'} ** 64;
    const candidate_id = [_]u8{'c'} ** 64;
    const project_sha256 = [_]u8{'d'} ** 64;
    const bundle_sha256 = [_]u8{'e'} ** 64;
    const bindings = Bindings{
        .request_id = request_id,
        .operation = .pre_decision,
        .kernel_sha256 = kernel_sha256,
        .candidate_id = candidate_id,
        .project_sha256 = project_sha256,
        .bundle_sha256 = bundle_sha256,
        .bundle_revision = 1,
    };
    var reasons = [_][]const u8{
        "rule_precondition_blocked",
        "recover_edit_existing_file_exact",
    };
    var raw = RawVerdict{
        .schema_version = VERDICT_SCHEMA,
        .checker_version = CHECKER_VERSION,
        .request_id = &request_id,
        .operation = .pre_decision,
        .kernel_sha256 = &kernel_sha256,
        .candidate_id = &candidate_id,
        .project_sha256 = &project_sha256,
        .bundle_sha256 = &bundle_sha256,
        .bundle_revision = 1,
        .decision = "block",
        .admitted = false,
        .reason_codes = &reasons,
        .checks = .{
            .request_valid = true,
            .rule_valid = true,
            .lifecycle_valid = true,
            .decision_valid = true,
        },
    };
    const verdict = try validateRawVerdict(raw, bindings);
    try std.testing.expect(!verdict.admitted);
    try std.testing.expect(verdict.recovery_action == .edit_existing_file_exact);

    raw.operation = .post_decision;
    try std.testing.expectError(error.BindingMismatch, validateRawVerdict(raw, bindings));
    raw.operation = .pre_decision;
    raw.decision = "admit";
    raw.admitted = true;
    try std.testing.expectError(error.Inconsistent, validateRawVerdict(raw, bindings));
    raw.decision = "block";
    raw.admitted = false;
    reasons[0] = "unrelated_failure";
    try std.testing.expectError(error.Inconsistent, validateRawVerdict(raw, bindings));

    var extra_reasons = [_][]const u8{
        "rule_precondition_blocked",
        "recover_edit_existing_file_exact",
        "unexpected_extra_reason",
    };
    raw.reason_codes = &extra_reasons;
    try std.testing.expectError(error.Inconsistent, validateRawVerdict(raw, bindings));
    raw.reason_codes = &reasons;
    reasons[0] = "rule_precondition_blocked";
    raw.checks.request_valid = false;
    try std.testing.expectError(error.Inconsistent, validateRawVerdict(raw, bindings));
}
