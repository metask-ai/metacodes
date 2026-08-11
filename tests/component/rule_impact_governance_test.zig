const std = @import("std");
const cc = @import("cc");

const candidate_id = [_]u8{'a'} ** 64;
const project_id = [_]u8{'b'} ** 64;
const bundle_id = [_]u8{'c'} ** 64;
const kernel_id = [_]u8{'d'} ** 64;
const issuer_id = [_]u8{'e'} ** 64;

const Fixture = struct {
    root: []const u8,
    binding: cc.tool_observation_journal.RunBinding,
    evidence_binding: cc.rule_impact_evidence.Binding,
};

fn rootPath(tmp: *std.testing.TmpDir, buffer: []u8) ![]const u8 {
    const len = try tmp.dir.realPath(std.testing.io, buffer);
    return buffer[0..len];
}

fn formalEvent(
    dispatch_id: []const u8,
    phase: cc.tools.tool_observation.FormalPhase,
    result: cc.tools.tool_observation.FormalResult,
    actuation: cc.tools.tool_observation.FormalActuation,
) cc.tools.tool_observation.Event {
    const call = if (phase == .pre) [_]u8{'1'} ** 64 else [_]u8{'2'} ** 64;
    return .{ .formal_decision = .{
        .dispatch_id = dispatch_id,
        .phase = phase,
        .actuation = actuation,
        .result = result,
        .candidate_id = candidate_id,
        .project_sha256 = project_id,
        .bundle_sha256 = bundle_id,
        .bundle_revision = 1,
        .kernel_sha256 = kernel_id,
        .request_sha256 = if (phase == .pre) .{'3'} ** 64 else .{'4'} ** 64,
        .checker_call_sha256 = call,
        .checker_verdict_sha256 = if (result == .fault) null else call,
        .verdict_sha256 = if (result == .fault) null else call,
        .checker_failure = if (result == .fault) "timeout" else null,
        .checker_elapsed_ns = 10,
        .checker_bytes = 1024,
    } };
}

fn dispatchStarted(id: []const u8) cc.tools.tool_observation.Event {
    return .{ .dispatch_started = .{
        .id = id,
        .requested_name = "Read",
        .dispatched_name = "Read",
        .origin = .authoritative,
        .agent_depth = 0,
        .input_bytes = 2,
        .input_sha256 = cc.tools.tool_observation.sha256Hex("{}"),
    } };
}

fn dispatchFinished(id: []const u8) cc.tools.tool_observation.Event {
    return .{ .dispatch_finished = .{
        .id = id,
        .requested_name = "Read",
        .dispatched_name = "Read",
        .origin = .authoritative,
        .agent_depth = 0,
        .outcome = .succeeded,
        .error_code = null,
        .elapsed_ms = 1,
        .result_present = true,
        .result_bytes = 2,
        .result_sha256 = cc.tools.tool_observation.sha256Hex("ok"),
        .effect = null,
        .effect_valid = true,
    } };
}

fn completedFixture(
    tmp: *std.testing.TmpDir,
    buffer: []u8,
    formal_result: cc.tools.tool_observation.FormalResult,
) !Fixture {
    const root = try rootPath(tmp, buffer);
    const sid = cc.session_id.SessionId.fromSlice("0123456789abcdef01234567").?;
    var journal = try cc.tool_observation_journal.Journal.init(root, sid);
    const sink = journal.sink();
    if (formal_result == .fault) {
        try std.testing.expect(sink.emit(formalEvent("impact-fault", .pre, .fault, .enforced)));
    } else {
        try std.testing.expect(sink.emit(formalEvent("impact-ok", .pre, formal_result, .shadow)));
        try std.testing.expect(sink.emit(dispatchStarted("impact-ok")));
        try std.testing.expect(sink.emit(formalEvent("impact-ok", .post, formal_result, .shadow)));
        try std.testing.expect(sink.emit(dispatchFinished("impact-ok")));
    }
    try journal.finishRun("end_turn");
    const binding = try journal.runBinding();
    journal.deinit();
    const validated = try cc.tool_observation_journal.validateRunBinding(root, binding);
    return .{
        .root = root,
        .binding = binding,
        .evidence_binding = .{
            .project_sha256 = project_id,
            .issuer_sha256 = issuer_id,
            .observation = binding,
            .interval_sha256 = validated.interval_sha256,
        },
    };
}

fn writeArtifact(root: []const u8, name: []const u8, bytes: []const u8) !void {
    const path = try std.fs.path.join(std.testing.allocator, &.{ root, name });
    defer std.testing.allocator.free(path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = bytes });
}

fn writeEvidence(fixture: Fixture, outcome: cc.rule_impact_evidence.OutcomeInput) !void {
    const outcome_bytes = try cc.rule_impact_evidence.renderOutcome(std.testing.allocator, outcome);
    defer std.testing.allocator.free(outcome_bytes);
    const usage_bytes = try cc.rule_impact_evidence.renderUsage(std.testing.allocator, .{
        .binding = fixture.evidence_binding,
        .provider_requests = 1,
        .input_tokens = 400,
        .output_tokens = 100,
        .cache_read_tokens = 450,
        .cache_write_tokens = 50,
        .cost_microusd = 100,
        .wall_elapsed_ns = 10_000,
    });
    defer std.testing.allocator.free(usage_bytes);
    try writeArtifact(fixture.root, "outcome.json", outcome_bytes);
    try writeArtifact(fixture.root, "usage.json", usage_bytes);
}

fn persistReceipt(fixture: Fixture) !cc.rule_impact_receipt.PersistResult {
    return cc.rule_impact_receipt.persist(fixture.root, .{
        .project_sha256 = project_id,
        .issuer_sha256 = issuer_id,
        .observation = fixture.binding,
        .outcome_evidence_name = "outcome.json",
        .usage_evidence_name = "usage.json",
    });
}

fn successfulOutcome(fixture: Fixture) cc.rule_impact_evidence.OutcomeInput {
    return .{
        .binding = fixture.evidence_binding,
        .outcome_source = .grader,
        .task_success = true,
        .trustworthy_success = true,
        .drift_detected = false,
        .false_interventions = 0,
        .regressions = 0,
    };
}

fn testKernel() ?cc.project_harness_runtime.Config {
    return switch (cc.project_harness_runtime.loadConfigFromEnv()) {
        .configured => |config| config,
        .missing, .invalid => null,
    };
}

fn policy() cc.project_harness_runtime.ImpactPolicy {
    return .{
        .min_exposures = 2,
        .max_formal_faults = 0,
        .max_shadow_divergences = 0,
        .max_false_interventions = 0,
        .max_regressions = 0,
        .max_provider_requests = 2,
        .max_metered_tokens = 2_000,
        .max_cost_microusd = 200,
        .max_wall_elapsed_ns = 20_000,
    };
}

test "RuleImpact receipt derives all labels from canonical run-bound evidence" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const fixture = try completedFixture(&tmp, &root_buffer, .admit);
    try writeEvidence(fixture, successfulOutcome(fixture));

    const persisted = try persistReceipt(fixture);
    var authenticated = try cc.rule_impact_receipt.deriveImpact(
        std.testing.allocator,
        fixture.root,
        persisted.receipt_id,
    );
    defer authenticated.deinit(std.testing.allocator);
    try std.testing.expect(authenticated.snapshot.evidence.authenticated);
    try std.testing.expectEqual(@as(usize, 1), authenticated.snapshot.rules.len);
    try std.testing.expectEqual(@as(?u64, 450), authenticated.snapshot.labels.cache_read_tokens);
    try std.testing.expectEqual(@as(?u64, 50), authenticated.snapshot.labels.cache_write_tokens);
    try std.testing.expectEqual(@as(?u64, 1000), authenticated.snapshot.labels.metered_tokens);
    try std.testing.expectEqual(@as(?u64, 100), authenticated.snapshot.labels.cost_microusd);
}

test "RuleImpact evidence rejects laundering, identity drift, tamper, symlink, and hardlink" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const fixture = try completedFixture(&tmp, &root_buffer, .admit);
    try writeEvidence(fixture, successfulOutcome(fixture));

    try writeArtifact(fixture.root, "unrelated.json", "{}\n");
    try std.testing.expectError(
        error.InvalidEvidence,
        cc.rule_impact_evidence.loadUsage(
            std.testing.allocator,
            fixture.root,
            "unrelated.json",
            fixture.evidence_binding,
        ),
    );
    try writeArtifact(fixture.root, "truncated.json", "{\"schema_version\":");
    try std.testing.expectError(
        error.InvalidEvidence,
        cc.rule_impact_evidence.loadUsage(
            std.testing.allocator,
            fixture.root,
            "truncated.json",
            fixture.evidence_binding,
        ),
    );

    const canonical_usage = try cc.rule_impact_evidence.renderUsage(std.testing.allocator, .{
        .binding = fixture.evidence_binding,
        .provider_requests = 1,
        .input_tokens = 400,
        .output_tokens = 100,
        .cache_read_tokens = 450,
        .cache_write_tokens = 50,
        .cost_microusd = 100,
        .wall_elapsed_ns = 10_000,
    });
    defer std.testing.allocator.free(canonical_usage);
    const noncanonical = try std.fmt.allocPrint(
        std.testing.allocator,
        " {s}",
        .{canonical_usage},
    );
    defer std.testing.allocator.free(noncanonical);
    try writeArtifact(fixture.root, "noncanonical.json", noncanonical);
    try std.testing.expectError(
        error.NonCanonicalEvidence,
        cc.rule_impact_evidence.loadUsage(
            std.testing.allocator,
            fixture.root,
            "noncanonical.json",
            fixture.evidence_binding,
        ),
    );
    const missing_cache = try std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        canonical_usage,
        "\"cache_write_tokens\":50,",
        "",
    );
    defer std.testing.allocator.free(missing_cache);
    try writeArtifact(fixture.root, "missing-cache.json", missing_cache);
    try std.testing.expectError(
        error.InvalidEvidence,
        cc.rule_impact_evidence.loadUsage(
            std.testing.allocator,
            fixture.root,
            "missing-cache.json",
            fixture.evidence_binding,
        ),
    );

    var wrong_binding = fixture.evidence_binding;
    wrong_binding.project_sha256 = .{'f'} ** 64;
    const wrong_usage = try cc.rule_impact_evidence.renderUsage(std.testing.allocator, .{
        .binding = wrong_binding,
        .provider_requests = 1,
        .input_tokens = 1,
        .output_tokens = 1,
        .cache_read_tokens = 1,
        .cache_write_tokens = 1,
        .cost_microusd = 1,
        .wall_elapsed_ns = 1,
    });
    defer std.testing.allocator.free(wrong_usage);
    try writeArtifact(fixture.root, "wrong-usage.json", wrong_usage);
    try std.testing.expectError(
        error.EvidenceBindingMismatch,
        cc.rule_impact_evidence.loadUsage(
            std.testing.allocator,
            fixture.root,
            "wrong-usage.json",
            fixture.evidence_binding,
        ),
    );

    const persisted = try persistReceipt(fixture);
    try writeArtifact(fixture.root, "usage.json", wrong_usage);
    try std.testing.expectError(
        error.EvidenceBindingMismatch,
        cc.rule_impact_receipt.deriveImpact(
            std.testing.allocator,
            fixture.root,
            persisted.receipt_id,
        ),
    );

    if (@import("builtin").os.tag != .windows) {
        const target = try std.fs.path.join(std.testing.allocator, &.{ fixture.root, "wrong-usage.json" });
        defer std.testing.allocator.free(target);
        const symlink_path = try std.fs.path.join(std.testing.allocator, &.{ fixture.root, "usage-link.json" });
        defer std.testing.allocator.free(symlink_path);
        try std.Io.Dir.symLinkAbsolute(std.testing.io, target, symlink_path, .{});
        try std.testing.expectError(
            error.EvidenceOpenFailed,
            cc.rule_impact_evidence.loadUsage(
                std.testing.allocator,
                fixture.root,
                "usage-link.json",
                wrong_binding,
            ),
        );
    }

    const source = try std.fs.path.join(std.testing.allocator, &.{ fixture.root, "wrong-usage.json" });
    defer std.testing.allocator.free(source);
    const linked = try std.fs.path.join(std.testing.allocator, &.{ fixture.root, "usage-hardlink.json" });
    defer std.testing.allocator.free(linked);
    try std.Io.Dir.hardLink(.cwd(), source, .cwd(), linked, std.testing.io, .{});
    try std.testing.expectError(
        error.InvalidEvidenceFile,
        cc.rule_impact_evidence.loadUsage(
            std.testing.allocator,
            fixture.root,
            "usage-hardlink.json",
            wrong_binding,
        ),
    );
}

test "L2 completed journal receipt invokes fixed Lean RuleImpact governance" {
    const config = testKernel() orelse return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const fixture = try completedFixture(&tmp, &root_buffer, .admit);
    try writeEvidence(fixture, successfulOutcome(fixture));
    const persisted = try persistReceipt(fixture);
    var invocation = try cc.project_harness_runtime.invokeImpact(
        std.testing.allocator,
        config,
        .{
            .session_dir = fixture.root,
            .receipt_id = persisted.receipt_id,
            .expected_issuer_sha256 = issuer_id,
            .rule_index = 0,
            .operation = .promote,
            .current_state = .shadowed,
            .policy = policy(),
        },
        null,
    );
    defer invocation.deinit(std.testing.allocator);
    try std.testing.expectEqual(cc.project_harness_runtime.FailureKind.none, invocation.failure);
    try std.testing.expect(invocation.checkerAdmitted());
    try std.testing.expect(invocation.verdict.?.checks.usage_consistent);

    try std.testing.expectError(
        error.InvalidImpactInput,
        cc.project_harness_runtime.invokeImpact(
            std.testing.allocator,
            .{
                .checker_path = "/definitely/not/a/checker",
                .expected_sha256 = .{'a'} ** 64,
            },
            .{
                .session_dir = fixture.root,
                .receipt_id = persisted.receipt_id,
                .expected_issuer_sha256 = .{'f'} ** 64,
                .rule_index = 0,
                .operation = .promote,
                .current_state = .shadowed,
                .policy = policy(),
            },
            null,
        ),
    );
}

test "RuleImpact missing receipt fails before checker inspection" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buffer);
    try std.testing.expectError(
        error.InvalidImpactEvidence,
        cc.project_harness_runtime.invokeImpact(
            std.testing.allocator,
            .{
                .checker_path = "/definitely/not/a/checker",
                .expected_sha256 = .{'a'} ** 64,
            },
            .{
                .session_dir = root,
                .receipt_id = .{'f'} ** 64,
                .expected_issuer_sha256 = issuer_id,
                .rule_index = 0,
                .operation = .promote,
                .current_state = .shadowed,
                .policy = policy(),
            },
            null,
        ),
    );
}

test "L2 drift blocks promotion and admits demotion" {
    const config = testKernel() orelse return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const fixture = try completedFixture(&tmp, &root_buffer, .admit);
    var outcome = successfulOutcome(fixture);
    outcome.drift_detected = true;
    outcome.regressions = 1;
    try writeEvidence(fixture, outcome);
    const persisted = try persistReceipt(fixture);
    var promotion = try cc.project_harness_runtime.invokeImpact(
        std.testing.allocator,
        config,
        .{
            .session_dir = fixture.root,
            .receipt_id = persisted.receipt_id,
            .expected_issuer_sha256 = issuer_id,
            .rule_index = 0,
            .operation = .promote,
            .current_state = .shadowed,
            .policy = policy(),
        },
        null,
    );
    defer promotion.deinit(std.testing.allocator);
    try std.testing.expect(!promotion.checkerAdmitted());
    try std.testing.expectEqual(cc.project_harness_runtime.FailureKind.none, promotion.failure);

    var demotion = try cc.project_harness_runtime.invokeImpact(
        std.testing.allocator,
        config,
        .{
            .session_dir = fixture.root,
            .receipt_id = persisted.receipt_id,
            .expected_issuer_sha256 = issuer_id,
            .rule_index = 0,
            .operation = .demote,
            .current_state = .promoted,
            .policy = policy(),
        },
        null,
    );
    defer demotion.deinit(std.testing.allocator);
    try std.testing.expect(demotion.checkerAdmitted());
}

test "L2 formal fault admits quarantine" {
    const config = testKernel() orelse return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const fixture = try completedFixture(&tmp, &root_buffer, .fault);
    var outcome = successfulOutcome(fixture);
    outcome.task_success = false;
    outcome.trustworthy_success = false;
    try writeEvidence(fixture, outcome);
    const persisted = try persistReceipt(fixture);
    var authenticated = try cc.rule_impact_receipt.deriveImpact(
        std.testing.allocator,
        fixture.root,
        persisted.receipt_id,
    );
    defer authenticated.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u64, 1), authenticated.snapshot.formal_faults);

    var quarantine = try cc.project_harness_runtime.invokeImpact(
        std.testing.allocator,
        config,
        .{
            .session_dir = fixture.root,
            .receipt_id = persisted.receipt_id,
            .expected_issuer_sha256 = issuer_id,
            .rule_index = 0,
            .operation = .quarantine,
            .current_state = .promoted,
            .policy = policy(),
        },
        null,
    );
    defer quarantine.deinit(std.testing.allocator);
    try std.testing.expect(quarantine.checkerAdmitted());
}
