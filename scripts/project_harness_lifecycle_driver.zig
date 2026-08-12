//! Zero-provider lifecycle driver for governed project-Harness rule templates.
//!
//! `prepare` persists a transcript-backed project constraint and typed
//! candidate, then captures one real safe dispatch for later shadow replay.
//! `finalize` consumes an independently sandboxed Lean build, records the
//! production lifecycle, promotes through the fixed kernel, and exercises the
//! production RunControl.  The evolved flavor blocks an existing-file Write
//! direction and lowers it through a separately admitted exact Edit; the
//! static flavor admits a bounded Write and
//! requires a host-reobserved mutation.
//! `audit` is a separate-process, read-only reopening of the complete chain.

const std = @import("std");
const cc = @import("cc");

const PREPARE_SCHEMA = "metacodes-project-harness-lifecycle-prepare-v2";
const FINAL_SCHEMA = "metacodes-project-harness-lifecycle-final-v2";
const AUDIT_SCHEMA = "metacodes-project-harness-lifecycle-audit-v2";
const EVOLVED_CORRECTION = "In this project, never use Write to overwrite an existing regular file; use Edit for targeted changes.";
const STATIC_CORRECTION = "In this project, every successful Write must remain bounded, authoritative, and carry a host-reobserved file mutation.";
const EVOLVED_LEAN_SOURCE =
    \\def spec : RuleSpec := {
    \\  targetTool := "Write"
    \\  targetScope := .existingFile
    \\  denyTarget := true
    \\  maxInputBytes := 8192
    \\  maxAgentDepth := 4
    \\  authoritativeOnly := true
    \\  effectRequirement := .none
    \\}
    \\theorem spec_valid : valid spec = true := by rfl
;
const STATIC_LEAN_SOURCE =
    \\def spec : RuleSpec := {
    \\  targetTool := "Write"
    \\  targetScope := .all
    \\  denyTarget := false
    \\  maxInputBytes := 8192
    \\  maxAgentDepth := 4
    \\  authoritativeOnly := true
    \\  effectRequirement := .fileMutationV1Reobserved
    \\}
    \\theorem spec_valid : valid spec = true := by rfl
;
const CORRECTION_SID = "0123456789abcdef01234567";
const RUNTIME_SID = "fedcba9876543210fedcba98";

const Phase = enum { prepare, finalize, audit };
const RuleFlavor = enum { evolved, static };

const Options = struct {
    phase: Phase,
    root: []const u8,
    repo: ?[]const u8 = null,
    build_dir: ?[]const u8 = null,
    lake: ?[]const u8 = null,
    kernel_path: ?[]const u8 = null,
    kernel_sha256: ?[64]u8 = null,
    project_root: ?[]const u8 = null,
    home_root: ?[]const u8 = null,
    rule_flavor: RuleFlavor = .evolved,
};

const WireBinding = struct {
    session_id: []const u8,
    run_id: []const u8,
    first_sequence: u64,
    last_sequence: u64,
    interval_sha256: []const u8,
};

const PrepareResult = struct {
    schema_version: []const u8 = PREPARE_SCHEMA,
    phase: []const u8 = "prepare",
    quality_evidence: bool = false,
    provider_requests: u64 = 0,
    paid_cost_usd: f64 = 0,
    rule_flavor: []const u8,
    project_root: []const u8,
    home_root: []const u8,
    session_dir: []const u8,
    rules_dir: []const u8,
    candidate_path: []const u8,
    project_sha256: []const u8,
    issuer_sha256: []const u8,
    proposer_sha256: []const u8,
    correction_sha256: []const u8,
    source_receipt_id: []const u8,
    candidate_id: []const u8,
    shadow_dispatch_id: []const u8,
    shadow_input_bytes: usize,
    shadow_run: WireBinding,
};

const FinalResult = struct {
    schema_version: []const u8 = FINAL_SCHEMA,
    phase: []const u8 = "finalize",
    quality_evidence: bool = false,
    outcome_superiority_claimed: bool = false,
    provider_requests: u64 = 0,
    paid_cost_usd: f64 = 0,
    source_kind: []const u8 = "user_correction",
    real_isolated_lean_build: bool = true,
    synthetic_active_identity: bool = false,
    rule_flavor: []const u8,
    project_sha256: []const u8,
    source_receipt_id: []const u8,
    candidate_id: []const u8,
    build_manifest_sha256: []const u8,
    build_receipt_id: []const u8,
    axiom_receipt_id: []const u8,
    replay_corpus_sha256: []const u8,
    replay_results_sha256: []const u8,
    replay_receipt_id: []const u8,
    shadow_trace_sha256: []const u8,
    shadow_results_sha256: []const u8,
    shadow_receipt_id: []const u8,
    promotion_receipt_id: []const u8,
    bundle_sha256: []const u8,
    bundle_revision: u64,
    promotion_request_sha256: []const u8,
    promotion_verdict_sha256: []const u8,
    active_pointer_sha256: []const u8,
    runtime_blocked_before_dispatch: bool,
    runtime_task_succeeded: bool,
    runtime_recovery_succeeded: bool,
    runtime_journal_sha256: []const u8,
    runtime_run: WireBinding,
};

const AuditResult = struct {
    schema_version: []const u8 = AUDIT_SCHEMA,
    phase: []const u8 = "audit",
    quality_evidence: bool = false,
    provider_requests: u64 = 0,
    paid_cost_usd: f64 = 0,
    audit_passed: bool = true,
    source_is_host_bound: bool = true,
    lifecycle_chain_reopened: bool = true,
    active_bundle_reattested: bool = true,
    runtime_journal_reopened: bool = true,
    rule_flavor: []const u8,
    candidate_id: []const u8,
    promotion_receipt_id: []const u8,
    bundle_sha256: []const u8,
    runtime_journal_sha256: []const u8,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    const options = try parseOptions(args);
    if (!std.fs.path.isAbsolute(options.root)) return error.AbsolutePathRequired;
    if ((options.project_root != null and !std.fs.path.isAbsolute(options.project_root.?)) or
        (options.home_root != null and !std.fs.path.isAbsolute(options.home_root.?)))
        return error.AbsolutePathRequired;
    switch (options.phase) {
        .prepare => try prepare(init, allocator, options),
        .finalize => try finalize(init, allocator, options),
        .audit => try audit(init, allocator, options),
    }
}

fn prepare(init: std.process.Init, allocator: std.mem.Allocator, options: Options) !void {
    const result_path = try std.fmt.allocPrint(allocator, "{s}/lifecycle-prepare.json", .{options.root});
    if (try pathExists(init.io, result_path)) return error.ResultAlreadyExists;
    const project_root = options.project_root orelse
        try std.fmt.allocPrint(allocator, "{s}/project", .{options.root});
    const home_root = options.home_root orelse
        try std.fmt.allocPrint(allocator, "{s}/home", .{options.root});
    const correction = correctionFor(options.rule_flavor);
    try cc.util_fs.mkdirParents(project_root);
    try cc.util_fs.mkdirParents(home_root);
    const sid = cc.session_id.SessionId.fromSlice(CORRECTION_SID).?;
    var conversation = cc.conversation.Conversation.init(allocator);
    defer conversation.deinit();
    try conversation.appendText(.user, correction);
    var writer = try cc.transcript.Writer.init(
        allocator,
        project_root,
        home_root,
        if (options.rule_flavor == .evolved) "e2-zero-provider" else "e3-static-template",
        sid,
    );
    defer writer.deinit();
    writer.flush(&conversation);

    const project = cc.project_rule_bundle.projectIdentity(project_root);
    const issuer = actor("metacodes-e2-user-authority-v1");
    const proposer = actor("metacodes-e2-candidate-proposer-v1");
    const correction_sha = cc.tools.tool_observation.sha256Hex(correction);
    const source = try cc.rule_source_receipt.persistUserCorrection(writer.dir, .{
        .project_sha256 = project,
        .issuer_sha256 = issuer,
        .session_id = sid,
        .transcript_line_index = 0,
        .correction = correction,
    });
    const candidate = try cc.rule_candidate.persist(writer.dir, .{
        .project_sha256 = project,
        .proposer_sha256 = proposer,
        .invariant = invariantFor(options.rule_flavor),
        .rule_spec = specFor(options.rule_flavor),
        .lean_source = leanSourceFor(options.rule_flavor),
        .source = .{ .user_correction = .{
            .receipt_id = source.receipt_id,
            .correction_sha256 = correction_sha,
            .authority_sha256 = issuer,
        } },
    });

    const safe_path = try std.fmt.allocPrint(allocator, "{s}/shadow-safe.txt", .{project_root});
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = safe_path, .data = "safe" });
    const safe_input = try std.json.Stringify.valueAlloc(allocator, .{ .file_path = safe_path }, .{});
    var journal = try cc.tool_observation_journal.Journal.init(writer.dir, sid);
    var journal_live = true;
    defer if (journal_live) journal.deinit();
    var ctx = cc.tool_context.ToolContext.simple(allocator);
    ctx.cwd_abs = project_root;
    ctx.home_dir = home_root;
    ctx.tool_observer = journal.sink();
    const read_outcome = try cc.tool_exec.executeOne(
        &ctx,
        "Read",
        safe_input,
        "shadow-safe-read",
        allocator,
        .{ .bytes = [_]u8{'e'} ** 12 },
    );
    try requireToolSuccess(allocator, read_outcome);
    try journal.finishRun("end_turn");
    const binding = try journal.runBinding();
    journal.deinit();
    journal_live = false;
    const validated = try cc.tool_observation_journal.validateRunBinding(writer.dir, binding);
    if (!validated.summary.complete) return error.ShadowRunIncomplete;

    var candidate_name: [96]u8 = undefined;
    const file_name = try cc.rule_candidate.fileName(candidate.candidate_id, &candidate_name);
    const candidate_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ writer.dir, file_name });
    const state_root = std.fs.path.dirname(writer.dir) orelse return error.InvalidSessionDirectory;
    const rules_dir = try std.fmt.allocPrint(allocator, "{s}/project-rules", .{state_root});
    const result = PrepareResult{
        .rule_flavor = @tagName(options.rule_flavor),
        .project_root = project_root,
        .home_root = home_root,
        .session_dir = writer.dir,
        .rules_dir = rules_dir,
        .candidate_path = candidate_path,
        .project_sha256 = project[0..],
        .issuer_sha256 = issuer[0..],
        .proposer_sha256 = proposer[0..],
        .correction_sha256 = correction_sha[0..],
        .source_receipt_id = source.receipt_id[0..],
        .candidate_id = candidate.candidate_id[0..],
        .shadow_dispatch_id = "shadow-safe-read",
        .shadow_input_bytes = safe_input.len,
        .shadow_run = wireBinding(&binding, &validated.interval_sha256),
    };
    try writeJson(init.io, allocator, result_path, result);
}

fn finalize(init: std.process.Init, allocator: std.mem.Allocator, options: Options) !void {
    const required = try requiredOptions(options);
    const prepare_path = try std.fmt.allocPrint(allocator, "{s}/lifecycle-prepare.json", .{options.root});
    const final_path = try std.fmt.allocPrint(allocator, "{s}/lifecycle-final.json", .{options.root});
    if (try pathExists(init.io, final_path)) return error.ResultAlreadyExists;
    const prepared = try loadPrepare(init.io, allocator, options, prepare_path);
    const flavor = std.meta.stringToEnum(RuleFlavor, prepared.rule_flavor) orelse
        return error.InvalidPrepareResult;
    const project = parseHex(prepared.project_sha256) orelse return error.InvalidPrepareIdentity;
    const candidate_id = parseHex(prepared.candidate_id) orelse return error.InvalidPrepareIdentity;
    const source_receipt_id = parseHex(prepared.source_receipt_id) orelse return error.InvalidPrepareIdentity;
    const shadow_binding = try parseBinding(prepared.shadow_run);
    const config = cc.project_harness_runtime.Config{
        .checker_path = required.kernel_path,
        .expected_sha256 = required.kernel_sha256,
    };
    try requireEnvironmentConfig(config);
    const trusted = trustedFiles(allocator, required.repo, required.lake) catch return error.InvalidTrustedFiles;

    var source = try cc.rule_source_receipt.load(allocator, prepared.session_dir, source_receipt_id);
    defer source.deinit();
    if (source.kind != .user_correction or !std.mem.eql(u8, &source.project_sha256, &project))
        return error.SourceReceiptMismatch;
    var candidate = try cc.rule_candidate.load(allocator, prepared.session_dir, candidate_id);
    defer candidate.deinit();
    if (candidate.source_kind != .user_correction or
        !try candidate.sourceIsBound(allocator, prepared.session_dir))
        return error.SourceReceiptMismatch;

    const recorded = try cc.rule_build_bundle.verifyAndRecord(
        allocator,
        prepared.session_dir,
        required.build_dir,
        candidate_id,
        project,
        trusted,
        .{
            .builder_sha256 = actor("metacodes-e2-builder-v1"),
            .build_checker_sha256 = actor("metacodes-e2-build-checker-v1"),
            .auditor_sha256 = actor("metacodes-e2-axiom-auditor-v1"),
            .axiom_checker_sha256 = actor("metacodes-e2-axiom-checker-v1"),
        },
    );
    const replay_cases = replayCases(flavor);
    const replay = try cc.rule_evaluation.evaluateAndRecordReplay(
        allocator,
        prepared.session_dir,
        prepared.session_dir,
        candidate_id,
        project,
        recorded.axiom_receipt_id,
        actor("metacodes-e2-replay-evaluator-v1"),
        config,
        &replay_cases,
    );
    const shadow_decisions = [_]cc.rule_evaluation.ShadowDecision{.{
        .decision_id = "safe-read-remains-admitted",
        .dispatch_id = prepared.shadow_dispatch_id,
        .observed_admit = true,
        .signal = .{ .pre = .{
            .tool = "Read",
            .input_bytes = prepared.shadow_input_bytes,
            .agent_depth = 0,
            .authoritative = true,
        } },
    }};
    const shadow = try cc.rule_evaluation.evaluateAndRecordShadow(
        allocator,
        prepared.session_dir,
        prepared.session_dir,
        candidate_id,
        project,
        replay.receipt_id,
        actor("metacodes-e2-shadow-evaluator-v1"),
        config,
        shadow_binding,
        &shadow_decisions,
    );
    const promoted = try cc.project_rule_bundle.promote(allocator, .{
        .evidence_dir = prepared.session_dir,
        .project_rules_dir = prepared.rules_dir,
        .candidate_id = candidate_id,
        .project_sha256 = project,
        .shadow_receipt_id = shadow.receipt_id,
        .promoter_sha256 = actor("metacodes-e2-independent-promoter-v1"),
        .trusted_build_files = trusted,
        .config = config,
    });

    const protected_path = try std.fmt.allocPrint(allocator, "{s}/protected.txt", .{prepared.project_root});
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = protected_path, .data = "old" });
    const state_root = std.fs.path.dirname(prepared.session_dir) orelse return error.InvalidSessionDirectory;
    const runtime_dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ state_root, RUNTIME_SID });
    try cc.util_fs.mkdirParents(runtime_dir);
    const runtime_sid = cc.session_id.SessionId.fromSlice(RUNTIME_SID).?;
    const control = try cc.project_rule_activation.RunControl.init(
        allocator,
        runtime_dir,
        runtime_sid,
        prepared.project_root,
        null,
    );
    var control_live = true;
    defer if (control_live) control.deinit();
    var ctx = cc.tool_context.ToolContext.simple(allocator);
    ctx.cwd_abs = prepared.project_root;
    ctx.home_dir = prepared.home_root;
    ctx.tool_observer = control.observer();
    ctx.project_rule_gate = control.formalGate();
    const write_input = try std.json.Stringify.valueAlloc(allocator, .{
        .file_path = protected_path,
        .content = "new",
    }, .{});
    const write_outcome = try cc.tool_exec.executeOne(
        &ctx,
        "Write",
        write_input,
        "runtime-write",
        allocator,
        .{ .bytes = [_]u8{'e'} ** 12 },
    );
    const blocked = switch (flavor) {
        .evolved => blk: {
            // Production auto-recovery keeps the model's original tool id but
            // returns the successful native exact-Edit result. The durable
            // journal below, not a model-facing error string, proves that the
            // ordinary Write direction was blocked before this dispatch.
            try requireToolSuccess(allocator, write_outcome);
            break :blk true;
        },
        .static => blk: {
            try requireToolSuccess(allocator, write_outcome);
            break :blk false;
        },
    };
    try control.finishRun("end_turn");
    const runtime_binding = try control.journal.runBinding();
    control.deinit();
    control_live = false;
    const runtime_validated = try cc.tool_observation_journal.validateRunBinding(
        runtime_dir,
        runtime_binding,
    );
    if (!runtime_validated.summary.complete or
        !try fileEquals(init.io, allocator, protected_path, "new"))
        return error.RuntimeRecoveryFailed;
    try verifyRuntimeRun(allocator, runtime_dir, runtime_binding, candidate_id, flavor);

    const result = FinalResult{
        .rule_flavor = @tagName(flavor),
        .project_sha256 = project[0..],
        .source_receipt_id = source_receipt_id[0..],
        .candidate_id = candidate_id[0..],
        .build_manifest_sha256 = recorded.verified.manifest_sha256[0..],
        .build_receipt_id = recorded.build_receipt_id[0..],
        .axiom_receipt_id = recorded.axiom_receipt_id[0..],
        .replay_corpus_sha256 = replay.corpus_sha256[0..],
        .replay_results_sha256 = replay.results_sha256[0..],
        .replay_receipt_id = replay.receipt_id[0..],
        .shadow_trace_sha256 = shadow.trace_sha256[0..],
        .shadow_results_sha256 = shadow.results_sha256[0..],
        .shadow_receipt_id = shadow.receipt_id[0..],
        .promotion_receipt_id = promoted.promotion_receipt_id[0..],
        .bundle_sha256 = promoted.bundle_sha256[0..],
        .bundle_revision = promoted.revision,
        .promotion_request_sha256 = promoted.request_sha256[0..],
        .promotion_verdict_sha256 = promoted.verdict_sha256[0..],
        .active_pointer_sha256 = promoted.active_pointer_sha256[0..],
        .runtime_blocked_before_dispatch = blocked,
        .runtime_task_succeeded = true,
        .runtime_recovery_succeeded = flavor == .evolved,
        .runtime_journal_sha256 = runtime_validated.summary.artifact_sha256[0..],
        .runtime_run = wireBinding(&runtime_binding, &runtime_validated.interval_sha256),
    };
    try writeJson(init.io, allocator, final_path, result);
}

fn audit(init: std.process.Init, allocator: std.mem.Allocator, options: Options) !void {
    const required = try requiredOptions(options);
    const prepare_path = try std.fmt.allocPrint(allocator, "{s}/lifecycle-prepare.json", .{options.root});
    const final_path = try std.fmt.allocPrint(allocator, "{s}/lifecycle-final.json", .{options.root});
    const audit_path = try std.fmt.allocPrint(allocator, "{s}/lifecycle-audit.json", .{options.root});
    if (try pathExists(init.io, audit_path)) return error.ResultAlreadyExists;
    const prepared = try loadPrepare(init.io, allocator, options, prepare_path);
    const final = try loadFinal(init.io, allocator, final_path);
    const flavor = std.meta.stringToEnum(RuleFlavor, prepared.rule_flavor) orelse
        return error.InvalidPrepareResult;
    const project = parseHex(final.project_sha256) orelse return error.InvalidFinalIdentity;
    const source_id = parseHex(final.source_receipt_id) orelse return error.InvalidFinalIdentity;
    const candidate_id = parseHex(final.candidate_id) orelse return error.InvalidFinalIdentity;
    const manifest = parseHex(final.build_manifest_sha256) orelse return error.InvalidFinalIdentity;
    if (!std.mem.eql(u8, final.project_sha256, prepared.project_sha256) or
        !std.mem.eql(u8, final.source_receipt_id, prepared.source_receipt_id) or
        !std.mem.eql(u8, final.rule_flavor, prepared.rule_flavor) or
        !std.mem.eql(u8, final.candidate_id, prepared.candidate_id))
        return error.FinalPrepareIdentityMismatch;
    const config = cc.project_harness_runtime.Config{
        .checker_path = required.kernel_path,
        .expected_sha256 = required.kernel_sha256,
    };
    try requireEnvironmentConfig(config);
    const trusted = trustedFiles(allocator, required.repo, required.lake) catch return error.InvalidTrustedFiles;

    var source = try cc.rule_source_receipt.load(allocator, prepared.session_dir, source_id);
    defer source.deinit();
    var candidate = try cc.rule_candidate.load(allocator, prepared.session_dir, candidate_id);
    defer candidate.deinit();
    if (source.kind != .user_correction or candidate.source_kind != .user_correction or
        !std.mem.eql(u8, &source.project_sha256, &project) or
        !try candidate.sourceIsBound(allocator, prepared.session_dir))
        return error.SourceReceiptMismatch;
    _ = try cc.rule_build_bundle.verifyStored(
        allocator,
        prepared.session_dir,
        manifest,
        candidate_id,
        project,
        trusted,
    );

    const receipt_ids = [_][64]u8{
        parseHex(final.build_receipt_id) orelse return error.InvalidFinalIdentity,
        parseHex(final.axiom_receipt_id) orelse return error.InvalidFinalIdentity,
        parseHex(final.replay_receipt_id) orelse return error.InvalidFinalIdentity,
        parseHex(final.shadow_receipt_id) orelse return error.InvalidFinalIdentity,
        parseHex(final.promotion_receipt_id) orelse return error.InvalidFinalIdentity,
    };
    const expected_stages = [_]cc.rule_lifecycle.Stage{
        .built, .axiom_audited, .replay_passed, .shadow_passed, .promoted,
    };
    var actors: [5][64]u8 = undefined;
    for (receipt_ids, expected_stages, 0..) |receipt_id, expected_stage, index| {
        var receipt = try cc.rule_lifecycle.load(allocator, prepared.session_dir, receipt_id);
        defer receipt.deinit();
        if (receipt.stage != expected_stage or
            !std.mem.eql(u8, &receipt.candidate_id, &candidate_id) or
            !std.mem.eql(u8, &receipt.project_sha256, &project) or
            (index == 0 and receipt.predecessor_receipt_id != null) or
            (index > 0 and (receipt.predecessor_receipt_id == null or
                !std.mem.eql(u8, &receipt.predecessor_receipt_id.?, &receipt_ids[index - 1]))))
            return error.InvalidLifecycleChain;
        actors[index] = receipt.actor_sha256;
    }
    for (actors, 0..) |current, index| {
        if (std.mem.eql(u8, &current, &candidate.proposer_sha256))
            return error.ActorIndependenceFailed;
        for (actors[0..index]) |prior| if (std.mem.eql(u8, &current, &prior))
            return error.ActorIndependenceFailed;
    }

    var active = (try cc.project_rule_bundle.loadVerifiedActive(
        allocator,
        prepared.rules_dir,
        project,
        config,
        null,
    )) orelse return error.MissingActiveBundle;
    defer active.deinit();
    const expected_bundle = parseHex(final.bundle_sha256) orelse return error.InvalidFinalIdentity;
    const expected_promotion = receipt_ids[4];
    if (active.revision != final.bundle_revision or
        !std.mem.eql(u8, &active.bundle_sha256, &expected_bundle) or
        !std.mem.eql(u8, &active.promotion_receipt_id, &expected_promotion) or
        active.rules.len != 1 or
        !std.mem.eql(u8, active.rules[0].candidate_id, &candidate_id))
        return error.ActiveIdentityMismatch;

    const runtime_binding = try parseBinding(final.runtime_run);
    const runtime_dir = try std.fmt.allocPrint(
        allocator,
        "{s}/{s}",
        .{ std.fs.path.dirname(prepared.session_dir) orelse return error.InvalidSessionDirectory, RUNTIME_SID },
    );
    const runtime_validated = try cc.tool_observation_journal.validateRunBinding(
        runtime_dir,
        runtime_binding,
    );
    const expected_journal = parseHex(final.runtime_journal_sha256) orelse return error.InvalidFinalIdentity;
    if (!runtime_validated.summary.complete or
        !std.mem.eql(u8, &runtime_validated.summary.artifact_sha256, &expected_journal))
        return error.RuntimeJournalMismatch;
    try verifyRuntimeRun(allocator, runtime_dir, runtime_binding, candidate_id, flavor);

    const result = AuditResult{
        .rule_flavor = @tagName(flavor),
        .candidate_id = candidate_id[0..],
        .promotion_receipt_id = expected_promotion[0..],
        .bundle_sha256 = expected_bundle[0..],
        .runtime_journal_sha256 = expected_journal[0..],
    };
    try writeJson(init.io, allocator, audit_path, result);
}

const RequiredOptions = struct {
    repo: []const u8,
    build_dir: []const u8,
    lake: []const u8,
    kernel_path: []const u8,
    kernel_sha256: [64]u8,
};

fn requiredOptions(options: Options) !RequiredOptions {
    const repo = options.repo orelse return error.MissingRepo;
    const build_dir = options.build_dir orelse return error.MissingBuildDir;
    const lake = options.lake orelse return error.MissingLake;
    const kernel_path = options.kernel_path orelse return error.MissingKernel;
    if (!std.fs.path.isAbsolute(repo) or !std.fs.path.isAbsolute(build_dir) or
        !std.fs.path.isAbsolute(lake) or !std.fs.path.isAbsolute(kernel_path))
        return error.AbsolutePathRequired;
    return .{
        .repo = repo,
        .build_dir = build_dir,
        .lake = lake,
        .kernel_path = kernel_path,
        .kernel_sha256 = options.kernel_sha256 orelse return error.MissingKernelSha256,
    };
}

fn trustedFiles(
    allocator: std.mem.Allocator,
    repo: []const u8,
    lake: []const u8,
) !cc.rule_build_bundle.TrustedFiles {
    return .{
        .toolchain_path = lake,
        .sdk_source_path = try std.fmt.allocPrint(
            allocator,
            "{s}/control-plane/lean/MetaCodesControl/ProjectRule.lean",
            .{repo},
        ),
        .sdk_olean_path = try std.fmt.allocPrint(
            allocator,
            "{s}/control-plane/lean/.lake/build/lib/MetaCodesControl/ProjectRule.olean",
            .{repo},
        ),
    };
}

fn correctionFor(flavor: RuleFlavor) []const u8 {
    return switch (flavor) {
        .evolved => EVOLVED_CORRECTION,
        .static => STATIC_CORRECTION,
    };
}

fn invariantFor(flavor: RuleFlavor) []const u8 {
    return switch (flavor) {
        .evolved => "Existing regular files are changed through Edit, never overwritten through Write.",
        .static => "Successful authoritative Write calls are bounded and retain host-reobserved mutation evidence.",
    };
}

fn leanSourceFor(flavor: RuleFlavor) []const u8 {
    return switch (flavor) {
        .evolved => EVOLVED_LEAN_SOURCE,
        .static => STATIC_LEAN_SOURCE,
    };
}

fn specFor(flavor: RuleFlavor) cc.project_rule_spec.Spec {
    return switch (flavor) {
        .evolved => .{
            .target_tool = "Write",
            .target_scope = .existing_file,
            .deny_target = true,
            .max_input_bytes = 8192,
            .max_agent_depth = 4,
            .authoritative_only = true,
            .effect_requirement = .none,
        },
        .static => .{
            .target_tool = "Write",
            .target_scope = .all,
            .deny_target = false,
            .max_input_bytes = 8192,
            .max_agent_depth = 4,
            .authoritative_only = true,
            .effect_requirement = .file_mutation_v1_reobserved,
        },
    };
}

fn replayCases(flavor: RuleFlavor) [5]cc.rule_evaluation.ReplayCase {
    return switch (flavor) {
        .evolved => .{
            .{ .case_id = "read-admitted", .expected_admit = true, .signal = .{ .pre = .{
                .tool = "Read",
                .input_bytes = 2,
                .agent_depth = 0,
                .authoritative = true,
            } } },
            .{ .case_id = "edit-admitted", .expected_admit = true, .signal = .{ .pre = .{
                .tool = "Edit",
                .input_bytes = 2,
                .agent_depth = 0,
                .authoritative = true,
            } } },
            .{ .case_id = "missing-write-admitted", .expected_admit = true, .signal = .{ .pre = .{
                .tool = "Write",
                .input_bytes = 2,
                .agent_depth = 0,
                .authoritative = true,
                .file_target_state = .missing,
            } } },
            .{ .case_id = "existing-write-blocked", .expected_admit = false, .signal = .{ .pre = .{
                .tool = "Write",
                .input_bytes = 2,
                .agent_depth = 0,
                .authoritative = true,
                .file_target_state = .regular_existing,
            } } },
            .{ .case_id = "ambiguous-write-blocked", .expected_admit = false, .signal = .{ .pre = .{
                .tool = "Write",
                .input_bytes = 2,
                .agent_depth = 0,
                .authoritative = true,
                .file_target_state = .unavailable,
            } } },
        },
        .static => .{
            .{ .case_id = "read-admitted", .expected_admit = true, .signal = .{ .pre = .{
                .tool = "Read",
                .input_bytes = 2,
                .agent_depth = 0,
                .authoritative = true,
            } } },
            .{ .case_id = "bounded-write-admitted", .expected_admit = true, .signal = .{ .pre = .{
                .tool = "Write",
                .input_bytes = 2,
                .agent_depth = 0,
                .authoritative = true,
            } } },
            .{ .case_id = "oversized-write-blocked", .expected_admit = false, .signal = .{ .pre = .{
                .tool = "Write",
                .input_bytes = 8193,
                .agent_depth = 0,
                .authoritative = true,
            } } },
            .{ .case_id = "deep-write-blocked", .expected_admit = false, .signal = .{ .pre = .{
                .tool = "Write",
                .input_bytes = 2,
                .agent_depth = 5,
                .authoritative = true,
            } } },
            .{ .case_id = "non-authoritative-write-blocked", .expected_admit = false, .signal = .{ .pre = .{
                .tool = "Write",
                .input_bytes = 2,
                .agent_depth = 0,
                .authoritative = false,
            } } },
        },
    };
}

fn verifyRuntimeRun(
    allocator: std.mem.Allocator,
    runtime_dir: []const u8,
    binding: cc.tool_observation_journal.RunBinding,
    candidate_id: [64]u8,
    flavor: RuleFlavor,
) !void {
    var run = try cc.tool_observation_journal.loadRunDispatches(allocator, runtime_dir, binding);
    defer run.deinit();
    const expected_id = "runtime-write";
    const expected_tool = if (flavor == .evolved) "Edit" else "Write";
    const expected_decisions: usize = if (flavor == .evolved) 3 else 2;
    if (run.dispatches.len != 1 or
        !std.mem.eql(u8, run.dispatches[0].id, expected_id) or
        !std.mem.eql(u8, run.dispatches[0].requested_name, "Write") or
        !std.mem.eql(u8, run.dispatches[0].dispatched_name, expected_tool) or
        run.dispatches[0].outcome != .succeeded or
        run.formal_decisions.len != expected_decisions)
        return error.InvalidRuntimeEvidence;
    var target_pre_blocks: usize = 0;
    var dispatched_admits: usize = 0;
    for (run.formal_decisions) |decision| {
        if (decision.actuation != .enforced or
            !std.mem.eql(u8, &decision.candidate_id, &candidate_id))
            return error.InvalidRuntimeEvidence;
        if (std.mem.eql(u8, decision.dispatch_id, "runtime-write") and
            decision.phase == .pre and decision.result == .block)
            target_pre_blocks += 1;
        if (std.mem.eql(u8, decision.dispatch_id, expected_id) and
            decision.result == .admit)
            dispatched_admits += 1;
    }
    if ((flavor == .evolved and (target_pre_blocks != 1 or dispatched_admits != 2)) or
        (flavor == .static and (target_pre_blocks != 0 or dispatched_admits != 2)))
        return error.InvalidRuntimeEvidence;
    const effect = run.dispatches[0].effect orelse return error.InvalidRuntimeEvidence;
    switch (effect) {
        .file_mutation_v2 => |mutation| if (mutation.reobservation.state != .matched)
            return error.InvalidRuntimeEvidence,
        else => return error.InvalidRuntimeEvidence,
    }
}

fn requireToolSuccess(
    allocator: std.mem.Allocator,
    outcome: cc.tool_exec.OneResult,
) !void {
    switch (outcome) {
        .done => |done| {
            defer if (done.content) |bytes| allocator.free(bytes);
            if (done.is_error) return error.UnexpectedToolError;
        },
        else => return error.UnexpectedToolResult,
    }
}

fn requireEnvironmentConfig(config: cc.project_harness_runtime.Config) !void {
    const loaded = switch (cc.project_harness_runtime.loadConfigFromEnv()) {
        .configured => |value| value,
        .missing => return error.ProjectKernelConfigurationMissing,
        .invalid => return error.ProjectKernelConfigurationInvalid,
    };
    if (!std.mem.eql(u8, loaded.checker_path, config.checker_path) or
        !std.mem.eql(u8, &loaded.expected_sha256, &config.expected_sha256))
        return error.ProjectKernelConfigurationMismatch;
}

fn wireBinding(
    binding: *const cc.tool_observation_journal.RunBinding,
    interval_sha256: *const [64]u8,
) WireBinding {
    return .{
        .session_id = binding.session_id.asSlice(),
        .run_id = binding.run_id.asSlice(),
        .first_sequence = binding.first_sequence,
        .last_sequence = binding.last_sequence,
        .interval_sha256 = interval_sha256[0..],
    };
}

fn parseBinding(wire: WireBinding) !cc.tool_observation_journal.RunBinding {
    const session_id = cc.session_id.SessionId.fromSlice(wire.session_id) orelse
        return error.InvalidRunBinding;
    const run_id = cc.session_id.SessionId.fromSlice(wire.run_id) orelse
        return error.InvalidRunBinding;
    _ = parseHex(wire.interval_sha256) orelse return error.InvalidRunBinding;
    return .{
        .session_id = session_id,
        .run_id = run_id,
        .first_sequence = wire.first_sequence,
        .last_sequence = wire.last_sequence,
    };
}

fn loadPrepare(
    io: std.Io,
    allocator: std.mem.Allocator,
    options: Options,
    path: []const u8,
) !PrepareResult {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024));
    const parsed = try std.json.parseFromSliceLeaky(PrepareResult, allocator, bytes, .{
        .ignore_unknown_fields = false,
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
    if (!std.mem.eql(u8, parsed.schema_version, PREPARE_SCHEMA) or
        !std.mem.eql(u8, parsed.phase, "prepare") or parsed.quality_evidence or
        parsed.provider_requests != 0 or parsed.paid_cost_usd != 0)
        return error.InvalidPrepareResult;
    const expected_project = options.project_root orelse
        try std.fmt.allocPrint(allocator, "{s}/project", .{options.root});
    const expected_home = options.home_root orelse
        try std.fmt.allocPrint(allocator, "{s}/home", .{options.root});
    const expected_project_sha256 = cc.project_rule_bundle.projectIdentity(expected_project);
    const cwd_hash = cc.transcript.hashCwd(expected_project);
    const expected_state_root = try std.fmt.allocPrint(
        allocator,
        "{s}/.metacodes/projects/{s}",
        .{ expected_home, cwd_hash[0..] },
    );
    const expected_session = try std.fmt.allocPrint(
        allocator,
        "{s}/{s}",
        .{ expected_state_root, CORRECTION_SID },
    );
    const expected_rules = try std.fmt.allocPrint(
        allocator,
        "{s}/project-rules",
        .{expected_state_root},
    );
    const candidate_id = parseHex(parsed.candidate_id) orelse return error.InvalidPrepareResult;
    _ = parseHex(parsed.source_receipt_id) orelse return error.InvalidPrepareResult;
    var candidate_name_buffer: [96]u8 = undefined;
    const candidate_name = try cc.rule_candidate.fileName(candidate_id, &candidate_name_buffer);
    const expected_candidate = try std.fmt.allocPrint(
        allocator,
        "{s}/{s}",
        .{ expected_session, candidate_name },
    );
    if (!std.mem.eql(u8, parsed.project_root, expected_project) or
        !std.mem.eql(u8, parsed.rule_flavor, @tagName(options.rule_flavor)) or
        !std.mem.eql(u8, parsed.home_root, expected_home) or
        !std.mem.eql(u8, parsed.session_dir, expected_session) or
        !std.mem.eql(u8, parsed.rules_dir, expected_rules) or
        !std.mem.eql(u8, parsed.candidate_path, expected_candidate) or
        !std.mem.eql(u8, &expected_project_sha256, parsed.project_sha256) or
        !std.mem.eql(u8, parsed.shadow_dispatch_id, "shadow-safe-read") or
        parsed.shadow_input_bytes == 0)
        return error.InvalidPrepareResult;
    _ = try parseBinding(parsed.shadow_run);
    return parsed;
}

fn loadFinal(io: std.Io, allocator: std.mem.Allocator, path: []const u8) !FinalResult {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024));
    const parsed = try std.json.parseFromSliceLeaky(FinalResult, allocator, bytes, .{
        .ignore_unknown_fields = false,
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
    const flavor = std.meta.stringToEnum(RuleFlavor, parsed.rule_flavor) orelse
        return error.InvalidFinalResult;
    if (!std.mem.eql(u8, parsed.schema_version, FINAL_SCHEMA) or
        !std.mem.eql(u8, parsed.phase, "finalize") or parsed.quality_evidence or
        parsed.outcome_superiority_claimed or parsed.provider_requests != 0 or
        parsed.paid_cost_usd != 0 or !parsed.real_isolated_lean_build or
        parsed.synthetic_active_identity or
        parsed.runtime_blocked_before_dispatch != (flavor == .evolved) or
        !parsed.runtime_task_succeeded or
        parsed.runtime_recovery_succeeded != (flavor == .evolved))
        return error.InvalidFinalResult;
    return parsed;
}

fn writeJson(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    value: anytype,
) !void {
    const json = try std.json.Stringify.valueAlloc(allocator, value, .{});
    const with_newline = try std.fmt.allocPrint(allocator, "{s}\n", .{json});
    // Result files are experiment evidence, not authorization artifacts.  A
    // crash may leave an incomplete file, but exclusive creation makes that a
    // fail-closed poison marker instead of silently overwriting/retrying it.
    var file = try std.Io.Dir.cwd().createFile(io, path, .{ .exclusive = true });
    defer file.close(io);
    try file.writeStreamingAll(io, with_newline);
    try file.sync(io);
}

fn actor(label: []const u8) [64]u8 {
    return cc.tools.tool_observation.sha256Hex(label);
}

fn fileEquals(
    io: std.Io,
    allocator: std.mem.Allocator,
    path: []const u8,
    expected: []const u8,
) !bool {
    const bytes = std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        allocator,
        .limited(1024 * 1024),
    ) catch return false;
    return std.mem.eql(u8, bytes, expected);
}

fn pathExists(io: std.Io, path: []const u8) !bool {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    file.close(io);
    return true;
}

fn parseOptions(args: []const []const u8) !Options {
    if (args.len < 5 or args.len % 2 == 0) return error.InvalidArguments;
    var phase: ?Phase = null;
    var root: ?[]const u8 = null;
    var repo: ?[]const u8 = null;
    var build_dir: ?[]const u8 = null;
    var lake: ?[]const u8 = null;
    var kernel_path: ?[]const u8 = null;
    var kernel_sha256: ?[64]u8 = null;
    var project_root: ?[]const u8 = null;
    var home_root: ?[]const u8 = null;
    var rule_flavor: ?RuleFlavor = null;
    var index: usize = 1;
    while (index + 1 < args.len) : (index += 2) {
        const key = args[index];
        const value = args[index + 1];
        if (std.mem.eql(u8, key, "--phase")) {
            if (phase != null) return error.DuplicateArgument;
            phase = std.meta.stringToEnum(Phase, value) orelse return error.InvalidPhase;
        } else if (std.mem.eql(u8, key, "--root")) {
            if (root != null) return error.DuplicateArgument;
            root = value;
        } else if (std.mem.eql(u8, key, "--repo")) {
            if (repo != null) return error.DuplicateArgument;
            repo = value;
        } else if (std.mem.eql(u8, key, "--build-dir")) {
            if (build_dir != null) return error.DuplicateArgument;
            build_dir = value;
        } else if (std.mem.eql(u8, key, "--lake")) {
            if (lake != null) return error.DuplicateArgument;
            lake = value;
        } else if (std.mem.eql(u8, key, "--kernel")) {
            if (kernel_path != null) return error.DuplicateArgument;
            kernel_path = value;
        } else if (std.mem.eql(u8, key, "--kernel-sha256")) {
            if (kernel_sha256 != null) return error.DuplicateArgument;
            kernel_sha256 = parseHex(value) orelse return error.InvalidKernelSha256;
        } else if (std.mem.eql(u8, key, "--project-root")) {
            if (project_root != null) return error.DuplicateArgument;
            project_root = value;
        } else if (std.mem.eql(u8, key, "--home-root")) {
            if (home_root != null) return error.DuplicateArgument;
            home_root = value;
        } else if (std.mem.eql(u8, key, "--rule-flavor")) {
            if (rule_flavor != null) return error.DuplicateArgument;
            rule_flavor = std.meta.stringToEnum(RuleFlavor, value) orelse
                return error.InvalidRuleFlavor;
        } else return error.UnknownArgument;
    }
    return .{
        .phase = phase orelse return error.MissingPhase,
        .root = root orelse return error.MissingRoot,
        .repo = repo,
        .build_dir = build_dir,
        .lake = lake,
        .kernel_path = kernel_path,
        .kernel_sha256 = kernel_sha256,
        .project_root = project_root,
        .home_root = home_root,
        .rule_flavor = rule_flavor orelse .evolved,
    };
}

fn parseHex(value: []const u8) ?[64]u8 {
    if (value.len != 64) return null;
    var out: [64]u8 = undefined;
    for (value, 0..) |byte, index| {
        if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return null;
        out[index] = byte;
    }
    return out;
}
