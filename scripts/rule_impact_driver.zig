//! Native bridge from host-graded Runs to authenticated RuleImpact governance.
//!
//! The paid-evaluation runner supplies semantic outcome/usage facts, while this
//! process reopens the completed observation journal, persists canonical
//! evidence, issues the single-Run receipt, rebuilds any aggregate from its
//! members, and invokes the hash-pinned Lean kernel.  It has no provider path.

const std = @import("std");
const cc = @import("cc");

const REQUEST_SCHEMA = "metacodes-rule-impact-driver-request-v1";
const ISSUE_RESULT_SCHEMA = "metacodes-rule-impact-driver-issue-result-v1";
const AGGREGATE_RESULT_SCHEMA = "metacodes-rule-impact-driver-aggregate-result-v1";
const MAX_REQUEST_BYTES: usize = 1024 * 1024;

const Command = enum { issue, aggregate };

const BindingWire = struct {
    session_id: []const u8,
    run_id: []const u8,
    first_sequence: u64,
    last_sequence: u64,
};

const OutcomeWire = struct {
    source: cc.rule_impact_evidence.OutcomeSource,
    task_success: bool,
    trustworthy_success: bool,
    drift_detected: bool,
    false_interventions: u64,
    regressions: u64,
};

const UsageWire = struct {
    provider_requests: u64,
    input_tokens: u64,
    output_tokens: u64,
    cache_read_tokens: u64,
    cache_write_tokens: u64,
    cost_microusd: u64,
    wall_elapsed_ns: u64,
};

const IssueWire = struct {
    session_dir: []const u8,
    project_sha256: []const u8,
    issuer_sha256: []const u8,
    observation: BindingWire,
    outcome: OutcomeWire,
    usage: UsageWire,
};

const MemberWire = struct {
    session_dir: []const u8,
    receipt_id: []const u8,
};

const AggregateWire = struct {
    aggregate_dir: []const u8,
    checker_path: []const u8,
    checker_sha256: []const u8,
    expected_issuer_sha256: []const u8,
    expected_policy_epoch: u64,
    policy_epoch: u64,
    candidate_id: []const u8,
    project_sha256: []const u8,
    bundle_sha256: []const u8,
    bundle_revision: u64,
    operation: cc.project_harness_runtime.ImpactOperation,
    current_state: cc.project_harness_runtime.ImpactRuleState,
    policy: cc.project_harness_runtime.ImpactPolicy,
    members: []const MemberWire,
};

const Request = struct {
    schema_version: []const u8,
    command: Command,
    issue: ?IssueWire,
    aggregate: ?AggregateWire,
};

const Options = struct {
    request_path: []const u8,
    output_path: []const u8,
};

const IssueResult = struct {
    schema_version: []const u8 = ISSUE_RESULT_SCHEMA,
    provider_requests_made_by_driver: u64 = 0,
    session_dir: []const u8,
    project_sha256: []const u8,
    issuer_sha256: []const u8,
    observation: BindingWire,
    source_interval_sha256: []const u8,
    outcome_evidence_name: []const u8,
    outcome_evidence_sha256: []const u8,
    usage_evidence_name: []const u8,
    usage_evidence_sha256: []const u8,
    receipt_id: []const u8,
    receipt_created: bool,
};

const ChecksWire = struct {
    bindings_valid: bool,
    evidence_valid: bool,
    members_valid: bool,
    aggregate_exact: bool,
    counts_consistent: bool,
    usage_consistent: bool,
    lifecycle_valid: bool,
    policy_satisfied: bool,
};

const AggregateResult = struct {
    schema_version: []const u8 = AGGREGATE_RESULT_SCHEMA,
    provider_requests_made_by_driver: u64 = 0,
    aggregate_dir: []const u8,
    aggregate_receipt_id: []const u8,
    aggregate_created: bool,
    member_count: u64,
    request_sha256: []const u8,
    verdict_sha256: ?[]const u8,
    actual_checker_sha256: []const u8,
    request_bytes: u64,
    observer_elapsed_ns: u64,
    checker_elapsed_ns: u64,
    failure: []const u8,
    checker_stdout: ?[]const u8,
    checker_stderr: ?[]const u8,
    admitted: bool,
    checks: ?ChecksWire,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    const options = try parseOptions(args);
    if (!std.fs.path.isAbsolute(options.request_path) or
        !std.fs.path.isAbsolute(options.output_path)) return error.AbsolutePathRequired;
    if (try pathExists(init.io, options.output_path)) return error.ResultAlreadyExists;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(
        init.io,
        options.request_path,
        allocator,
        .limited(MAX_REQUEST_BYTES),
    );
    const request = try std.json.parseFromSliceLeaky(Request, allocator, bytes, .{
        .ignore_unknown_fields = false,
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
    if (!std.mem.eql(u8, request.schema_version, REQUEST_SCHEMA))
        return error.UnsupportedRequestSchema;
    switch (request.command) {
        .issue => {
            if (request.aggregate != null) return error.InvalidRequestShape;
            try issue(init, allocator, options.output_path, request.issue orelse
                return error.InvalidRequestShape);
        },
        .aggregate => {
            if (request.issue != null) return error.InvalidRequestShape;
            try aggregate(init, allocator, options.output_path, request.aggregate orelse
                return error.InvalidRequestShape);
        },
    }
}

fn issue(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    output_path: []const u8,
    request: IssueWire,
) !void {
    if (!std.fs.path.isAbsolute(request.session_dir)) return error.AbsolutePathRequired;
    const project = parseHex64(request.project_sha256) orelse return error.InvalidIdentity;
    const issuer = parseHex64(request.issuer_sha256) orelse return error.InvalidIdentity;
    const binding = try parseBinding(request.observation);
    const validated = try cc.tool_observation_journal.validateRunBinding(
        request.session_dir,
        binding,
    );
    if (!validated.summary.complete) return error.IncompleteObservationJournal;
    const evidence_binding = cc.rule_impact_evidence.Binding{
        .project_sha256 = project,
        .issuer_sha256 = issuer,
        .observation = binding,
        .interval_sha256 = validated.interval_sha256,
    };
    const outcome = try cc.rule_impact_evidence.renderOutcome(allocator, .{
        .binding = evidence_binding,
        .outcome_source = request.outcome.source,
        .task_success = request.outcome.task_success,
        .trustworthy_success = request.outcome.trustworthy_success,
        .drift_detected = request.outcome.drift_detected,
        .false_interventions = request.outcome.false_interventions,
        .regressions = request.outcome.regressions,
    });
    const usage = try cc.rule_impact_evidence.renderUsage(allocator, .{
        .binding = evidence_binding,
        .provider_requests = request.usage.provider_requests,
        .input_tokens = request.usage.input_tokens,
        .output_tokens = request.usage.output_tokens,
        .cache_read_tokens = request.usage.cache_read_tokens,
        .cache_write_tokens = request.usage.cache_write_tokens,
        .cost_microusd = request.usage.cost_microusd,
        .wall_elapsed_ns = request.usage.wall_elapsed_ns,
    });
    const outcome_sha = cc.tools.tool_observation.sha256Hex(outcome);
    const usage_sha = cc.tools.tool_observation.sha256Hex(usage);
    const outcome_name = try std.fmt.allocPrint(
        allocator,
        "rule-impact-outcome-{s}.json",
        .{outcome_sha[0..]},
    );
    const usage_name = try std.fmt.allocPrint(
        allocator,
        "rule-impact-usage-{s}.json",
        .{usage_sha[0..]},
    );
    try persistEvidence(init.io, allocator, request.session_dir, outcome_name, outcome);
    try persistEvidence(init.io, allocator, request.session_dir, usage_name, usage);
    const receipt = try cc.rule_impact_receipt.persist(request.session_dir, .{
        .project_sha256 = project,
        .issuer_sha256 = issuer,
        .observation = binding,
        .outcome_evidence_name = outcome_name,
        .usage_evidence_name = usage_name,
    });
    try writeJson(init.io, allocator, output_path, IssueResult{
        .session_dir = request.session_dir,
        .project_sha256 = request.project_sha256,
        .issuer_sha256 = request.issuer_sha256,
        .observation = request.observation,
        .source_interval_sha256 = &validated.interval_sha256,
        .outcome_evidence_name = outcome_name,
        .outcome_evidence_sha256 = &outcome_sha,
        .usage_evidence_name = usage_name,
        .usage_evidence_sha256 = &usage_sha,
        .receipt_id = &receipt.receipt_id,
        .receipt_created = receipt.created,
    });
}

fn aggregate(
    init: std.process.Init,
    allocator: std.mem.Allocator,
    output_path: []const u8,
    request: AggregateWire,
) !void {
    if (!std.fs.path.isAbsolute(request.aggregate_dir) or
        !std.fs.path.isAbsolute(request.checker_path)) return error.AbsolutePathRequired;
    const checker_sha = parseHex64(request.checker_sha256) orelse return error.InvalidIdentity;
    const issuer = parseHex64(request.expected_issuer_sha256) orelse return error.InvalidIdentity;
    const identity = cc.rule_impact_aggregate_receipt.RuleIdentity{
        .candidate_id = parseHex64(request.candidate_id) orelse return error.InvalidIdentity,
        .project_sha256 = parseHex64(request.project_sha256) orelse return error.InvalidIdentity,
        .bundle_sha256 = parseHex64(request.bundle_sha256) orelse return error.InvalidIdentity,
        .bundle_revision = request.bundle_revision,
    };
    const members = try allocator.alloc(
        cc.rule_impact_aggregate_receipt.MemberRef,
        request.members.len,
    );
    for (request.members, members) |member, *parsed| {
        if (!std.fs.path.isAbsolute(member.session_dir)) return error.AbsolutePathRequired;
        parsed.* = .{
            .session_dir = member.session_dir,
            .receipt_id = parseHex64(member.receipt_id) orelse return error.InvalidIdentity,
        };
    }
    const persisted = try cc.rule_impact_aggregate_receipt.persist(
        allocator,
        request.aggregate_dir,
        .{
            .policy_epoch = request.policy_epoch,
            .expected_issuer_sha256 = issuer,
            .identity = identity,
            .members = members,
        },
    );
    var invocation = try cc.project_harness_runtime.invokeImpactAggregate(
        allocator,
        .{
            .checker_path = request.checker_path,
            .expected_sha256 = checker_sha,
        },
        .{
            .aggregate_dir = request.aggregate_dir,
            .receipt_id = persisted.receipt_id,
            .expected_issuer_sha256 = issuer,
            .expected_policy_epoch = request.expected_policy_epoch,
            .operation = request.operation,
            .current_state = request.current_state,
            .policy = request.policy,
        },
        null,
    );
    defer invocation.deinit(allocator);
    const verdict = invocation.verdict;
    const checks: ?ChecksWire = if (verdict) |value| .{
        .bindings_valid = value.checks.bindings_valid,
        .evidence_valid = value.checks.evidence_valid,
        .members_valid = value.checks.members_valid,
        .aggregate_exact = value.checks.aggregate_exact,
        .counts_consistent = value.checks.counts_consistent,
        .usage_consistent = value.checks.usage_consistent,
        .lifecycle_valid = value.checks.lifecycle_valid,
        .policy_satisfied = value.checks.policy_satisfied,
    } else null;
    try writeJson(init.io, allocator, output_path, AggregateResult{
        .aggregate_dir = request.aggregate_dir,
        .aggregate_receipt_id = &persisted.receipt_id,
        .aggregate_created = persisted.created,
        .member_count = persisted.member_count,
        .request_sha256 = &invocation.request_sha256,
        .verdict_sha256 = if (invocation.verdict_sha256) |*value| value else null,
        .actual_checker_sha256 = &invocation.actual_checker_sha256,
        .request_bytes = invocation.request_bytes,
        .observer_elapsed_ns = invocation.observer_elapsed_ns,
        .checker_elapsed_ns = invocation.checker_elapsed_ns,
        .failure = @tagName(invocation.failure),
        .checker_stdout = invocation.stdout,
        .checker_stderr = invocation.stderr,
        .admitted = if (verdict) |value| value.admitted else false,
        .checks = checks,
    });
}

fn parseBinding(wire: BindingWire) !cc.tool_observation_journal.RunBinding {
    return .{
        .session_id = cc.session_id.SessionId.fromSlice(wire.session_id) orelse
            return error.InvalidRunBinding,
        .run_id = cc.session_id.SessionId.fromSlice(wire.run_id) orelse
            return error.InvalidRunBinding,
        .first_sequence = wire.first_sequence,
        .last_sequence = wire.last_sequence,
    };
}

fn persistEvidence(
    io: std.Io,
    allocator: std.mem.Allocator,
    directory: []const u8,
    name: []const u8,
    bytes: []const u8,
) !void {
    const path = try std.fs.path.join(allocator, &.{ directory, name });
    var file = std.Io.Dir.cwd().createFile(io, path, .{ .exclusive = true }) catch |err| switch (err) {
        error.PathAlreadyExists => {
            const existing = try std.Io.Dir.cwd().readFileAlloc(
                io,
                path,
                allocator,
                .limited(cc.rule_impact_evidence.MAX_EVIDENCE_BYTES),
            );
            if (!std.mem.eql(u8, existing, bytes)) return error.EvidenceCollision;
            return;
        },
        else => return err,
    };
    defer file.close(io);
    try file.writeStreamingAll(io, bytes);
    try file.sync(io);
}

fn writeJson(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    value: anytype,
) !void {
    const json = try std.json.Stringify.valueAlloc(allocator, value, .{});
    const line = try std.fmt.allocPrint(allocator, "{s}\n", .{json});
    var file = try std.Io.Dir.cwd().createFile(io, path, .{ .exclusive = true });
    defer file.close(io);
    try file.writeStreamingAll(io, line);
    try file.sync(io);
}

fn parseOptions(args: []const []const u8) !Options {
    if (args.len != 5) return error.InvalidArguments;
    var request_path: ?[]const u8 = null;
    var output_path: ?[]const u8 = null;
    var index: usize = 1;
    while (index < args.len) : (index += 2) {
        if (std.mem.eql(u8, args[index], "--request")) {
            if (request_path != null) return error.DuplicateArgument;
            request_path = args[index + 1];
        } else if (std.mem.eql(u8, args[index], "--output")) {
            if (output_path != null) return error.DuplicateArgument;
            output_path = args[index + 1];
        } else {
            return error.InvalidArguments;
        }
    }
    return .{
        .request_path = request_path orelse return error.InvalidArguments,
        .output_path = output_path orelse return error.InvalidArguments,
    };
}

fn parseHex64(value: []const u8) ?[64]u8 {
    if (value.len != 64) return null;
    var result: [64]u8 = undefined;
    var nonzero = false;
    for (value, 0..) |byte, index| {
        if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return null;
        result[index] = byte;
        nonzero = nonzero or byte != '0';
    }
    return if (nonzero) result else null;
}

fn pathExists(io: std.Io, path: []const u8) !bool {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    file.close(io);
    return true;
}
