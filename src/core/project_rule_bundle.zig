//! Content-addressed project rule bundles and crash-safe activation.
//!
//! A bundle is persisted inactive first. Only an admitted Lean promotion,
//! durable lifecycle receipt, and CAS publication of `active.json` make it
//! visible to tool dispatch. Orphaned bundles/receipts after a crash remain
//! inert and can be audited or garbage-collected explicitly.

const std = @import("std");
const pfs = @import("platform").fs;
const util_fs = @import("../util/fs.zig");
const observation = @import("../tools/observation.zig");
const candidate_mod = @import("rule_candidate.zig");
const lifecycle = @import("rule_lifecycle.zig");
const evaluation = @import("rule_evaluation.zig");
const build_bundle = @import("rule_build_bundle.zig");
const spec_mod = @import("project_rule_spec.zig");
const kernel = @import("../formal/project_harness_runtime.zig");

pub const BUNDLE_SCHEMA = "metacodes-project-rule-bundle-v1";
pub const ACTIVE_SCHEMA = "metacodes-project-rule-active-v1";
pub const BUNDLE_PREFIX = "project-rule-bundle-";
pub const REQUEST_PREFIX = "project-rule-promotion-request-";
pub const VERDICT_PREFIX = "project-rule-promotion-verdict-";
pub const ACTIVE_FILE = "active.json";
pub const ACTIVE_LOCK = "active.lock";
pub const ACTIVE_TEMP = "active.json.tmp";
pub const MAX_BUNDLE_BYTES: usize = 4 * 1024 * 1024;
pub const MAX_RULES: usize = 1024;
const ZERO_SHA = [_]u8{'0'} ** 64;

pub const RuleEntry = struct {
    candidate_id: []const u8,
    rule_spec: spec_mod.Wire,
};

const BundleBody = struct {
    schema_version: []const u8 = BUNDLE_SCHEMA,
    project_sha256: []const u8,
    revision: u64,
    previous_bundle_sha256: []const u8,
    kernel_sha256: []const u8,
    rules: []const RuleEntry,
};

const BundleRecord = struct {
    bundle_sha256: []const u8,
    body: BundleBody,
};

const ActiveBody = struct {
    schema_version: []const u8 = ACTIVE_SCHEMA,
    project_sha256: []const u8,
    bundle_sha256: []const u8,
    revision: u64,
    kernel_sha256: []const u8,
    promotion_receipt_id: []const u8,
    promotion_request_sha256: []const u8,
    promotion_verdict_sha256: []const u8,
};

const ActiveRecord = struct {
    pointer_sha256: []const u8,
    body: ActiveBody,
};

pub const PromoteInput = struct {
    evidence_dir: []const u8,
    /// Defaults to `evidence_dir`.  Kept explicit for an offline evaluator
    /// that publishes content-addressed artifacts into a separate trusted
    /// directory; promotion always reopens them before any active mutation.
    evaluation_dir: ?[]const u8 = null,
    project_rules_dir: []const u8,
    candidate_id: [64]u8,
    project_sha256: [64]u8,
    shadow_receipt_id: [64]u8,
    promoter_sha256: [64]u8,
    /// Current trusted toolchain/SDK identities.  Promotion reopens the
    /// manifest-addressed durable build bundle and compares it to both these
    /// files and the build/axiom lifecycle receipts.
    trusted_build_files: build_bundle.TrustedFiles,
    config: kernel.Config,
    abort: ?*const @import("../util/abort.zig").AbortSignal = null,
};

pub const PromoteResult = struct {
    bundle_sha256: [64]u8,
    revision: u64,
    promotion_receipt_id: [64]u8,
    request_sha256: [64]u8,
    verdict_sha256: [64]u8,
    active_pointer_sha256: [64]u8,
};

pub const LoadedActive = struct {
    arena: std.heap.ArenaAllocator,
    project_sha256: [64]u8,
    bundle_sha256: [64]u8,
    revision: u64,
    kernel_sha256: [64]u8,
    promotion_receipt_id: [64]u8,
    promotion_request_sha256: [64]u8,
    promotion_verdict_sha256: [64]u8,
    active_pointer_sha256: [64]u8,
    rules: []const RuleEntry,

    pub fn deinit(self: *LoadedActive) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub fn projectIdentity(project_root: []const u8) [64]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("metacodes-project-identity-v1\x00");
    hasher.update(project_root);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

pub fn hasActive(directory: []const u8) bool {
    var path_buffer: [std.fs.max_path_bytes + 1]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buffer, "{s}/{s}\x00", .{ directory, ACTIVE_FILE }) catch return true;
    // access(F_OK) follows symlinks, so a dangling active.json symlink would
    // otherwise look exactly like "never configured" and disable governance.
    if (pfs.isSymlink(@ptrCast(path.ptr))) return true;
    return pfs.exists(@ptrCast(path.ptr));
}

const OptionalActive = union(enum) {
    missing,
    loaded: LoadedActive,
};

pub fn promote(allocator: std.mem.Allocator, input: PromoteInput) !PromoteResult {
    try validatePromoteInput(input);
    try util_fs.mkdirParents(input.project_rules_dir);
    var candidate = try candidate_mod.load(allocator, input.evidence_dir, input.candidate_id);
    defer candidate.deinit();
    if (!std.mem.eql(u8, &candidate.project_sha256, &input.project_sha256))
        return error.ProjectIdentityMismatch;

    var shadow = try lifecycle.load(allocator, input.evidence_dir, input.shadow_receipt_id);
    defer shadow.deinit();
    if (shadow.stage != .shadow_passed or
        !std.mem.eql(u8, &shadow.candidate_id, &input.candidate_id) or
        !std.mem.eql(u8, &shadow.project_sha256, &input.project_sha256))
        return error.InvalidLifecycleChain;
    var replay = try loadPredecessor(allocator, input.evidence_dir, shadow, .replay_passed);
    defer replay.deinit();
    var axiom = try loadPredecessor(allocator, input.evidence_dir, replay, .axiom_audited);
    defer axiom.deinit();
    var built = try loadPredecessor(allocator, input.evidence_dir, axiom, .built);
    defer built.deinit();

    const verified_build = try build_bundle.verifyStored(
        allocator,
        input.evidence_dir,
        built.evidence.built.manifest_sha256,
        input.candidate_id,
        input.project_sha256,
        input.trusted_build_files,
    );
    if (!std.mem.eql(u8, &verified_build.manifest_sha256, &built.evidence.built.manifest_sha256) or
        !std.mem.eql(u8, &verified_build.lean_source_sha256, &built.evidence.built.lean_source_sha256) or
        !std.mem.eql(u8, &verified_build.rule_spec_sha256, &built.evidence.built.rule_spec_sha256) or
        !std.mem.eql(u8, &verified_build.compiled_artifact_sha256, &built.evidence.built.compiled_artifact_sha256) or
        !std.mem.eql(u8, &verified_build.toolchain_sha256, &built.evidence.built.toolchain_sha256) or
        !std.mem.eql(u8, &verified_build.sdk_sha256, &built.evidence.built.sdk_sha256) or
        !std.mem.eql(u8, &verified_build.sdk_olean_sha256, &built.evidence.built.sdk_olean_sha256) or
        !std.mem.eql(u8, &verified_build.build_log_sha256, &built.evidence.built.build_log_sha256) or
        !std.mem.eql(u8, &verified_build.audit_sha256, &axiom.evidence.axiom_audited.audit_sha256) or
        !std.mem.eql(u8, &verified_build.policy_sha256, &axiom.evidence.axiom_audited.policy_sha256))
        return error.BuildLifecycleEvidenceMismatch;

    _ = try evaluation.revalidateForPromotion(
        allocator,
        input.evidence_dir,
        input.evaluation_dir orelse input.evidence_dir,
        input.candidate_id,
        input.project_sha256,
        replay.evidence.replay_passed,
        shadow.evidence.shadow_passed,
        input.config,
        input.abort,
    );

    // Serialize the whole state-dependent promotion, not merely the final
    // rename. Acquiring the lease after reading the prior bundle allowed two
    // valid promoters to both persist a `promoted` lifecycle head before one
    // lost the late CAS, leaving a candidate permanently promoted-but-inert.
    var active_lease = try ActiveLease.acquire(input.project_rules_dir);
    defer active_lease.deinit();

    var prior_optional = try loadActiveWithoutPromotionReplay(
        allocator,
        input.project_rules_dir,
        input.project_sha256,
        input.config.expected_sha256,
    );
    defer switch (prior_optional) {
        .loaded => |*active| active.deinit(),
        .missing => {},
    };
    // Extending a structurally valid pointer is not enough: otherwise a
    // missing/tampered prior request or verdict could be laundered into a new
    // revision whose fresh receipt only authenticates the newly added rule.
    // Re-execute the prior promotion under the same active lease before any
    // new bundle is constructed.
    switch (prior_optional) {
        .loaded => |*active| try reattestPromotion(
            allocator,
            input.project_rules_dir,
            active,
            input.config,
            input.abort,
        ),
        .missing => {},
    }
    const previous_revision: u64 = switch (prior_optional) {
        .missing => 0,
        .loaded => |active| active.revision,
    };
    const previous_sha: [64]u8 = switch (prior_optional) {
        .missing => ZERO_SHA,
        .loaded => |active| active.bundle_sha256,
    };
    const previous_rules: []const RuleEntry = switch (prior_optional) {
        .missing => &.{},
        .loaded => |active| active.rules,
    };
    if (previous_rules.len >= MAX_RULES) return error.TooManyProjectRules;
    for (previous_rules) |entry| {
        if (equalHex(entry.candidate_id, input.candidate_id)) return error.CandidateAlreadyActive;
    }

    const rules = try allocator.alloc(RuleEntry, previous_rules.len + 1);
    defer allocator.free(rules);
    @memcpy(rules[0..previous_rules.len], previous_rules);
    rules[previous_rules.len] = .{
        .candidate_id = input.candidate_id[0..],
        .rule_spec = spec_mod.toWire(candidate.rule_spec),
    };
    const revision = std.math.add(u64, previous_revision, 1) catch return error.RevisionOverflow;
    const bundle_body = BundleBody{
        .project_sha256 = input.project_sha256[0..],
        .revision = revision,
        .previous_bundle_sha256 = previous_sha[0..],
        .kernel_sha256 = input.config.expected_sha256[0..],
        .rules = rules,
    };
    const bundle_body_json = try std.json.Stringify.valueAlloc(allocator, bundle_body, .{});
    defer allocator.free(bundle_body_json);
    const bundle_sha256 = observation.sha256Hex(bundle_body_json);
    const bundle_record = BundleRecord{ .bundle_sha256 = bundle_sha256[0..], .body = bundle_body };
    const bundle_json = try std.json.Stringify.valueAlloc(allocator, bundle_record, .{});
    defer allocator.free(bundle_json);
    try persistAddressed(input.project_rules_dir, BUNDLE_PREFIX, bundle_sha256, bundle_json);

    const source_bound = try candidate.sourceIsBound(
        allocator,
        input.evidence_dir,
    );
    const facts = kernel.PromotionFacts{
        .source_kind = switch (candidate.source_kind) {
            .user_correction => .user_correction,
            .agent_reflection => .agent_reflection,
            .runtime_counterexample => .runtime_counterexample,
        },
        .source_receipt_bound = source_bound,
        .proposer = candidate.proposer_sha256[0..],
        .builder = built.actor_sha256[0..],
        .auditor = axiom.actor_sha256[0..],
        .replay_evaluator = replay.actor_sha256[0..],
        .shadow_evaluator = shadow.actor_sha256[0..],
        .promoter = input.promoter_sha256[0..],
        .replay_checker = replay.checker_sha256[0..],
        .shadow_checker = shadow.checker_sha256[0..],
        .build_receipt = built.receipt_id[0..],
        .axiom_predecessor = (axiom.predecessor_receipt_id orelse return error.InvalidLifecycleChain)[0..],
        .axiom_receipt = axiom.receipt_id[0..],
        .replay_predecessor = (replay.predecessor_receipt_id orelse return error.InvalidLifecycleChain)[0..],
        .replay_receipt = replay.receipt_id[0..],
        .shadow_predecessor = (shadow.predecessor_receipt_id orelse return error.InvalidLifecycleChain)[0..],
        .build_manifest = built.evidence.built.manifest_sha256[0..],
        .rule_spec_sha256 = built.evidence.built.rule_spec_sha256[0..],
        .sdk_olean = built.evidence.built.sdk_olean_sha256[0..],
        .build_completed = built.evidence.built.completed,
        .axiom_completed = axiom.evidence.axiom_audited.completed,
        .forbidden_declaration_count = axiom.evidence.axiom_audited.forbidden_declaration_count,
        .unexpected_axiom_count = axiom.evidence.axiom_audited.unexpected_axiom_count,
        .replay_completed = replay.evidence.replay_passed.completed,
        .replay_positive_cases = replay.evidence.replay_passed.positive_cases,
        .replay_negative_cases = replay.evidence.replay_passed.negative_cases,
        .replay_false_positive_count = replay.evidence.replay_passed.false_positive_count,
        .replay_false_negative_count = replay.evidence.replay_passed.false_negative_count,
        .shadow_completed = shadow.evidence.shadow_passed.completed,
        .shadow_observed_decisions = shadow.evidence.shadow_passed.observed_decisions,
        .shadow_divergence_count = shadow.evidence.shadow_passed.divergence_count,
        .shadow_side_effect_count = shadow.evidence.shadow_passed.side_effect_count,
        .previous_revision = previous_revision,
        .previous_bundle_sha256 = previous_sha[0..],
        .previous_rule_count = @intCast(previous_rules.len),
        .bundle_rule_count = @intCast(rules.len),
        .candidate_occurrences = 1,
    };
    const facts_json = try std.json.Stringify.valueAlloc(allocator, facts, .{});
    defer allocator.free(facts_json);
    const request_id = kernel.requestId(.promote, input.candidate_id, bundle_sha256, revision, facts_json);
    const request = kernel.Request{
        .request_id = request_id[0..],
        .operation = .promote,
        .kernel_sha256 = input.config.expected_sha256[0..],
        .candidate_id = input.candidate_id[0..],
        .project_sha256 = input.project_sha256[0..],
        .bundle_sha256 = bundle_sha256[0..],
        .bundle_revision = revision,
        .rule_spec = spec_mod.toWire(candidate.rule_spec),
        .payload = .{ .promotion = facts },
    };
    var invocation = try kernel.invoke(allocator, input.config, request, .{
        .request_id = request_id,
        .operation = .promote,
        .kernel_sha256 = input.config.expected_sha256,
        .candidate_id = input.candidate_id,
        .project_sha256 = input.project_sha256,
        .bundle_sha256 = bundle_sha256,
        .bundle_revision = revision,
    }, input.abort);
    defer invocation.deinit(allocator);
    if (invocation.failure != .none) return error.PromotionCheckerFailed;
    if (!invocation.checkerAdmitted()) return error.PromotionBlocked;
    const verdict_sha256 = invocation.verdict_sha256 orelse return error.PromotionCheckerFailed;
    const promotion = try lifecycle.persistPromotion(input.evidence_dir, .{
        .candidate_id = input.candidate_id,
        .project_sha256 = input.project_sha256,
        .actor_sha256 = input.promoter_sha256,
        .checker_sha256 = input.config.expected_sha256,
        .predecessor_receipt_id = input.shadow_receipt_id,
        .evidence = .{ .promoted = .{
            .lifecycle_request_sha256 = invocation.request_sha256,
            .lifecycle_verdict_sha256 = verdict_sha256,
            .runtime_kernel_sha256 = input.config.expected_sha256,
            .bundle_sha256 = bundle_sha256,
            .previous_bundle_sha256 = previous_sha,
            .bundle_revision = revision,
            .checker_admitted = true,
            .checker_elapsed_ns = invocation.checker_elapsed_ns,
            .checker_bytes = invocation.checker_bytes,
        } },
    }, &invocation);

    const request_json = try kernel.renderRequest(allocator, request);
    defer allocator.free(request_json);
    try persistAddressed(input.project_rules_dir, REQUEST_PREFIX, invocation.request_sha256, request_json);
    try persistAddressed(input.project_rules_dir, VERDICT_PREFIX, verdict_sha256, invocation.verdict_payload.?);
    try copyLifecycleReceipt(
        allocator,
        input.evidence_dir,
        input.project_rules_dir,
        promotion.receipt_id,
    );
    const active_body = ActiveBody{
        .project_sha256 = input.project_sha256[0..],
        .bundle_sha256 = bundle_sha256[0..],
        .revision = revision,
        .kernel_sha256 = input.config.expected_sha256[0..],
        .promotion_receipt_id = promotion.receipt_id[0..],
        .promotion_request_sha256 = invocation.request_sha256[0..],
        .promotion_verdict_sha256 = verdict_sha256[0..],
    };
    const body_json = try std.json.Stringify.valueAlloc(allocator, active_body, .{});
    defer allocator.free(body_json);
    const pointer_sha256 = observation.sha256Hex(body_json);
    const record = ActiveRecord{ .pointer_sha256 = pointer_sha256[0..], .body = active_body };
    const record_json = try std.json.Stringify.valueAlloc(allocator, record, .{});
    defer allocator.free(record_json);
    try publishActiveCasHeld(
        allocator,
        input.project_rules_dir,
        &active_lease,
        previous_revision,
        previous_sha,
        input.project_sha256,
        input.config.expected_sha256,
        record_json,
    );
    return .{
        .bundle_sha256 = bundle_sha256,
        .revision = revision,
        .promotion_receipt_id = promotion.receipt_id,
        .request_sha256 = invocation.request_sha256,
        .verdict_sha256 = verdict_sha256,
        .active_pointer_sha256 = pointer_sha256,
    };
}

/// Load and re-attest an active pointer before it can become a runtime gate.
/// The promotion request is executed again by the pinned kernel and must yield
/// the same verdict hash carried by both active pointer and lifecycle receipt.
pub fn loadVerifiedActive(
    allocator: std.mem.Allocator,
    directory: []const u8,
    expected_project: [64]u8,
    config: kernel.Config,
    abort: ?*const @import("../util/abort.zig").AbortSignal,
) !?LoadedActive {
    if (controlEntryPresent(directory, ACTIVE_LOCK)) return error.ActivePointerBusy;
    if (controlEntryPresent(directory, ACTIVE_TEMP)) return error.IncompleteActivePublish;
    var active_optional = try loadActiveWithoutPromotionReplay(
        allocator,
        directory,
        expected_project,
        config.expected_sha256,
    );
    switch (active_optional) {
        .missing => return null,
        .loaded => |*active| {
            errdefer active.deinit();
            try reattestPromotion(allocator, directory, active, config, abort);
            return active_optional.loaded;
        },
    }
}

fn reattestPromotion(
    allocator: std.mem.Allocator,
    directory: []const u8,
    active: *LoadedActive,
    config: kernel.Config,
    abort: ?*const @import("../util/abort.zig").AbortSignal,
) !void {
    const request_bytes = try readAddressed(
        active.arena.allocator(),
        directory,
        REQUEST_PREFIX,
        active.promotion_request_sha256,
        kernel.MAX_REQUEST_BYTES,
    );
    if (!std.mem.eql(u8, &observation.sha256Hex(request_bytes), &active.promotion_request_sha256))
        return error.PromotionRequestHashMismatch;
    const verdict_bytes = try readAddressed(
        active.arena.allocator(),
        directory,
        VERDICT_PREFIX,
        active.promotion_verdict_sha256,
        kernel.MAX_OUTPUT_BYTES,
    );
    if (!std.mem.eql(u8, &observation.sha256Hex(verdict_bytes), &active.promotion_verdict_sha256))
        return error.PromotionVerdictHashMismatch;
    var parsed = std.json.parseFromSlice(kernel.Request, active.arena.allocator(), request_bytes, .{
        .ignore_unknown_fields = false,
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    }) catch return error.InvalidPromotionRequest;
    defer parsed.deinit();
    const request_id = parseHex(parsed.value.request_id) orelse return error.InvalidPromotionRequest;
    const candidate_id = parseHex(parsed.value.candidate_id) orelse return error.InvalidPromotionRequest;
    var invocation = try kernel.invoke(allocator, config, parsed.value, .{
        .request_id = request_id,
        .operation = .promote,
        .kernel_sha256 = config.expected_sha256,
        .candidate_id = candidate_id,
        .project_sha256 = active.project_sha256,
        .bundle_sha256 = active.bundle_sha256,
        .bundle_revision = active.revision,
    }, abort);
    defer invocation.deinit(allocator);
    if (!invocation.checkerAdmitted() or invocation.verdict_sha256 == null or
        !std.mem.eql(u8, &invocation.verdict_sha256.?, &active.promotion_verdict_sha256) or
        invocation.verdict_payload == null or
        !std.mem.eql(u8, invocation.verdict_payload.?, verdict_bytes))
        return error.PromotionReattestationFailed;
}

fn loadActiveWithoutPromotionReplay(
    allocator: std.mem.Allocator,
    directory: []const u8,
    expected_project: [64]u8,
    expected_kernel: [64]u8,
) !OptionalActive {
    var path_buffer: [std.fs.max_path_bytes + 1]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/{s}\x00", .{ directory, ACTIVE_FILE });
    if (!pfs.exists(@ptrCast(path.ptr))) return .missing;
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    const active = try readActiveRecord(a, directory);
    const pointer_sha = parseHex(active.pointer_sha256) orelse return error.InvalidActivePointer;
    const body_json = try std.json.Stringify.valueAlloc(a, active.body, .{});
    if (!std.mem.eql(u8, &observation.sha256Hex(body_json), &pointer_sha) or
        !std.mem.eql(u8, active.body.schema_version, ACTIVE_SCHEMA) or
        !equalHex(active.body.project_sha256, expected_project) or
        !equalHex(active.body.kernel_sha256, expected_kernel) or active.body.revision == 0)
        return error.InvalidActivePointer;
    const bundle_sha = parseHex(active.body.bundle_sha256) orelse return error.InvalidActivePointer;
    const receipt_id = parseHex(active.body.promotion_receipt_id) orelse return error.InvalidActivePointer;
    const request_sha = parseHex(active.body.promotion_request_sha256) orelse return error.InvalidActivePointer;
    const verdict_sha = parseHex(active.body.promotion_verdict_sha256) orelse return error.InvalidActivePointer;
    const bundle_bytes = try readAddressed(a, directory, BUNDLE_PREFIX, bundle_sha, MAX_BUNDLE_BYTES);
    var parsed_bundle = std.json.parseFromSlice(BundleRecord, a, bundle_bytes, .{
        .ignore_unknown_fields = false,
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    }) catch return error.InvalidBundle;
    defer parsed_bundle.deinit();
    const canonical_bundle = try std.json.Stringify.valueAlloc(a, parsed_bundle.value, .{});
    if (!std.mem.eql(u8, canonical_bundle, bundle_bytes) or
        !equalHex(parsed_bundle.value.bundle_sha256, bundle_sha) or
        !std.mem.eql(u8, &observation.sha256Hex(try std.json.Stringify.valueAlloc(a, parsed_bundle.value.body, .{})), &bundle_sha) or
        !std.mem.eql(u8, parsed_bundle.value.body.schema_version, BUNDLE_SCHEMA) or
        !equalHex(parsed_bundle.value.body.project_sha256, expected_project) or
        !equalHex(parsed_bundle.value.body.kernel_sha256, expected_kernel) or
        parsed_bundle.value.body.revision != active.body.revision or
        parsed_bundle.value.body.rules.len == 0 or parsed_bundle.value.body.rules.len > MAX_RULES)
        return error.InvalidBundle;
    for (parsed_bundle.value.body.rules) |entry| {
        if (parseHex(entry.candidate_id) == null) return error.InvalidBundle;
        _ = spec_mod.fromWire(entry.rule_spec) catch return error.InvalidBundle;
    }
    var receipt = try lifecycle.load(a, directory, receipt_id);
    defer receipt.deinit();
    if (receipt.stage != .promoted or receipt.legacy_schema or
        !std.mem.eql(u8, &receipt.project_sha256, &expected_project) or
        !std.mem.eql(u8, &receipt.checker_sha256, &expected_kernel) or
        receipt.evidence.promoted.bundle_revision != active.body.revision or
        !std.mem.eql(u8, &receipt.evidence.promoted.bundle_sha256, &bundle_sha) or
        !std.mem.eql(u8, &receipt.evidence.promoted.runtime_kernel_sha256, &expected_kernel) or
        !equalHex(active.body.promotion_request_sha256, receipt.evidence.promoted.lifecycle_request_sha256) or
        !equalHex(active.body.promotion_verdict_sha256, receipt.evidence.promoted.lifecycle_verdict_sha256) or
        !receipt.evidence.promoted.checker_admitted or
        receipt.evidence.promoted.checker_bytes == 0)
        return error.InvalidPromotionReceipt;
    var promoted_candidate_occurrences: usize = 0;
    for (parsed_bundle.value.body.rules) |entry| {
        if (equalHex(entry.candidate_id, receipt.candidate_id))
            promoted_candidate_occurrences += 1;
    }
    if (promoted_candidate_occurrences != 1) return error.InvalidPromotionReceipt;
    return .{ .loaded = .{
        .arena = arena,
        .project_sha256 = expected_project,
        .bundle_sha256 = bundle_sha,
        .revision = active.body.revision,
        .kernel_sha256 = expected_kernel,
        .promotion_receipt_id = receipt_id,
        .promotion_request_sha256 = request_sha,
        .promotion_verdict_sha256 = verdict_sha,
        .active_pointer_sha256 = pointer_sha,
        .rules = parsed_bundle.value.body.rules,
    } };
}

fn loadPredecessor(
    allocator: std.mem.Allocator,
    directory: []const u8,
    current: lifecycle.Loaded,
    expected: lifecycle.Stage,
) !lifecycle.Loaded {
    const id = current.predecessor_receipt_id orelse return error.InvalidLifecycleChain;
    var prior = try lifecycle.load(allocator, directory, id);
    errdefer prior.deinit();
    if (prior.stage != expected or
        !std.mem.eql(u8, &prior.candidate_id, &current.candidate_id) or
        !std.mem.eql(u8, &prior.project_sha256, &current.project_sha256))
        return error.InvalidLifecycleChain;
    return prior;
}

fn readActiveRecord(allocator: std.mem.Allocator, directory: []const u8) !ActiveRecord {
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ directory, ACTIVE_FILE });
    defer allocator.free(path);
    const raw = try readPath(allocator, path, MAX_BUNDLE_BYTES);
    var parsed = std.json.parseFromSlice(ActiveRecord, allocator, raw, .{
        .ignore_unknown_fields = false,
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    }) catch return error.InvalidActivePointer;
    defer parsed.deinit();
    const canonical = try std.json.Stringify.valueAlloc(allocator, parsed.value, .{});
    if (!std.mem.eql(u8, canonical, raw)) return error.InvalidActivePointer;
    // parsed.deinit would free strings, so clone through a leaky arena parse at
    // the caller's allocator after canonical validation.
    return std.json.parseFromSliceLeaky(ActiveRecord, allocator, raw, .{
        .ignore_unknown_fields = false,
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    }) catch return error.InvalidActivePointer;
}

fn validatePromoteInput(input: PromoteInput) !void {
    if (!validHex(input.candidate_id) or !validHex(input.project_sha256) or
        !validHex(input.shadow_receipt_id) or !validHex(input.promoter_sha256) or
        !validHex(input.config.expected_sha256) or
        !std.fs.path.isAbsolute(input.evidence_dir) or
        (input.evaluation_dir != null and !std.fs.path.isAbsolute(input.evaluation_dir.?)) or
        !std.fs.path.isAbsolute(input.project_rules_dir) or
        !std.fs.path.isAbsolute(input.config.checker_path) or
        !std.fs.path.isAbsolute(input.trusted_build_files.toolchain_path) or
        !std.fs.path.isAbsolute(input.trusted_build_files.sdk_source_path) or
        !std.fs.path.isAbsolute(input.trusted_build_files.sdk_olean_path))
        return error.InvalidPromotionInput;
}

fn publishActiveCas(
    allocator: std.mem.Allocator,
    directory: []const u8,
    expected_revision: u64,
    expected_bundle: [64]u8,
    expected_project: [64]u8,
    expected_kernel: [64]u8,
    bytes: []const u8,
) !void {
    var lease = try ActiveLease.acquire(directory);
    defer lease.deinit();
    try publishActiveCasHeld(
        allocator,
        directory,
        &lease,
        expected_revision,
        expected_bundle,
        expected_project,
        expected_kernel,
        bytes,
    );
}

const ActiveLease = struct {
    fd: pfs.Fd,
    path: [std.fs.max_path_bytes + 1]u8,
    path_len: usize,
    active_replaced: bool = false,
    active_durable: bool = false,

    fn acquire(directory: []const u8) !ActiveLease {
        var result: ActiveLease = undefined;
        const lock = try std.fmt.bufPrint(&result.path, "{s}/{s}\x00", .{ directory, ACTIVE_LOCK });
        result.path_len = lock.len - 1;
        result.active_replaced = false;
        result.active_durable = false;
        result.fd = pfs.open(@ptrCast(result.path[0..].ptr), .{
            .ACCMODE = .WRONLY,
            .CREAT = true,
            .EXCL = true,
            .NOFOLLOW = true,
        }, @as(std.c.mode_t, 0o600));
        if (result.fd < 0) return error.ActivePointerBusy;
        errdefer {
            _ = pfs.close(result.fd);
            pfs.unlinkPath(@ptrCast(result.path[0..].ptr)) catch {};
        }
        try pfs.makeCloseOnExec(result.fd);
        try pfs.fsyncChecked(result.fd);
        try fsyncDirectory(directory);
        return result;
    }

    fn deinit(self: *ActiveLease) void {
        _ = pfs.close(self.fd);
        // Before rename every failure is safely retryable. After rename, a
        // directory-fsync failure leaves an uncertain active pointer, so keep
        // the lock as a fail-closed poison marker for explicit audit.
        if (!self.active_replaced or self.active_durable)
            pfs.unlinkPath(@ptrCast(self.path[0..].ptr)) catch {};
        self.* = undefined;
    }
};

fn publishActiveCasHeld(
    allocator: std.mem.Allocator,
    directory: []const u8,
    lease: *ActiveLease,
    expected_revision: u64,
    expected_bundle: [64]u8,
    expected_project: [64]u8,
    expected_kernel: [64]u8,
    bytes: []const u8,
) !void {
    const current = try loadActiveIdentity(allocator, directory, expected_project, expected_kernel);
    if (current.revision != expected_revision or
        !std.mem.eql(u8, &current.bundle_sha256, &expected_bundle))
        return error.ActiveRevisionMismatch;

    var temp_path: [std.fs.max_path_bytes + 1]u8 = undefined;
    const temp = try std.fmt.bufPrint(&temp_path, "{s}/{s}\x00", .{ directory, ACTIVE_TEMP });
    const fd = pfs.open(@ptrCast(temp.ptr), .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .EXCL = true,
        .NOFOLLOW = true,
    }, @as(std.c.mode_t, 0o600));
    if (fd < 0) return error.IncompleteActivePublish;
    var closed = false;
    errdefer {
        if (!closed) _ = pfs.close(fd);
        pfs.unlinkPath(@ptrCast(temp.ptr)) catch {};
    }
    try pfs.makeCloseOnExec(fd);
    try writeAll(fd, bytes);
    try pfs.fsyncChecked(fd);
    _ = pfs.close(fd);
    closed = true;
    var final_path: [std.fs.max_path_bytes + 1]u8 = undefined;
    const final = try std.fmt.bufPrint(&final_path, "{s}/{s}\x00", .{ directory, ACTIVE_FILE });
    if (pfs.renameReplace(@ptrCast(temp.ptr), @ptrCast(final.ptr)) != 0)
        return error.ActiveRenameFailed;
    lease.active_replaced = true;
    try fsyncDirectory(directory);
    lease.active_durable = true;
}

const ActiveIdentity = struct { revision: u64, bundle_sha256: [64]u8 };

fn loadActiveIdentity(
    allocator: std.mem.Allocator,
    directory: []const u8,
    expected_project: [64]u8,
    expected_kernel: [64]u8,
) !ActiveIdentity {
    var path_buffer: [std.fs.max_path_bytes + 1]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/{s}\x00", .{ directory, ACTIVE_FILE });
    if (!pfs.exists(@ptrCast(path.ptr))) return .{ .revision = 0, .bundle_sha256 = ZERO_SHA };
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const record = try readActiveRecord(a, directory);
    const pointer_sha = parseHex(record.pointer_sha256) orelse return error.InvalidActivePointer;
    const body_json = try std.json.Stringify.valueAlloc(a, record.body, .{});
    if (!std.mem.eql(u8, &observation.sha256Hex(body_json), &pointer_sha) or
        !std.mem.eql(u8, record.body.schema_version, ACTIVE_SCHEMA) or
        !equalHex(record.body.project_sha256, expected_project) or
        !equalHex(record.body.kernel_sha256, expected_kernel) or
        record.body.revision == 0)
        return error.InvalidActivePointer;
    return .{
        .revision = record.body.revision,
        .bundle_sha256 = parseHex(record.body.bundle_sha256) orelse return error.InvalidActivePointer,
    };
}

fn persistAddressed(
    directory: []const u8,
    prefix: []const u8,
    identity: [64]u8,
    bytes: []const u8,
) !void {
    if (bytes.len == 0 or bytes.len > MAX_BUNDLE_BYTES) return error.ArtifactTooLarge;
    var path_buffer: [std.fs.max_path_bytes + 1]u8 = undefined;
    const path = try std.fmt.bufPrint(
        &path_buffer,
        "{s}/{s}{s}.json\x00",
        .{ directory, prefix, identity[0..] },
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
        try writeAll(write_fd, bytes);
        try pfs.fsyncChecked(write_fd);
        _ = pfs.close(write_fd);
        write_fd = -1;
        try fsyncDirectory(directory);
        return;
    }
    const existing = try readPathZ(std.heap.c_allocator, @ptrCast(path.ptr), MAX_BUNDLE_BYTES);
    defer std.heap.c_allocator.free(existing);
    if (!std.mem.eql(u8, existing, bytes)) return error.ArtifactCollision;
}

fn readAddressed(
    allocator: std.mem.Allocator,
    directory: []const u8,
    prefix: []const u8,
    identity: [64]u8,
    maximum: usize,
) ![]u8 {
    const path = try std.fmt.allocPrint(
        allocator,
        "{s}/{s}{s}.json",
        .{ directory, prefix, identity[0..] },
    );
    defer allocator.free(path);
    return readPath(allocator, path, maximum);
}

fn copyLifecycleReceipt(
    allocator: std.mem.Allocator,
    from: []const u8,
    to: []const u8,
    receipt_id: [64]u8,
) !void {
    const name = try std.fmt.allocPrint(
        allocator,
        "{s}{s}.json",
        .{ lifecycle.FILE_PREFIX, receipt_id[0..] },
    );
    defer allocator.free(name);
    const source = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ from, name });
    defer allocator.free(source);
    const bytes = try readPath(allocator, source, lifecycle.MAX_RECORD_BYTES);
    defer allocator.free(bytes);
    const destination_prefix = lifecycle.FILE_PREFIX;
    try persistAddressed(to, destination_prefix, receipt_id, bytes);
}

fn readPath(allocator: std.mem.Allocator, path: []const u8, maximum: usize) ![]u8 {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    return readPathZ(allocator, path_z.ptr, maximum);
}

fn readPathZ(allocator: std.mem.Allocator, path: [*:0]const u8, maximum: usize) ![]u8 {
    const fd = pfs.open(path, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true }, 0);
    if (fd < 0) return error.ArtifactOpenFailed;
    defer _ = pfs.close(fd);
    const before = pfs.fileInfo(fd) catch return error.ArtifactStatFailed;
    if (!before.is_regular or before.link_count != 1 or before.size == 0 or before.size > maximum)
        return error.InvalidArtifact;
    const bytes = try allocator.alloc(u8, @intCast(before.size));
    errdefer allocator.free(bytes);
    var offset: usize = 0;
    while (offset < bytes.len) {
        const count = pfs.read(fd, bytes[offset..]);
        if (count <= 0) return error.ArtifactReadFailed;
        offset += @intCast(count);
    }
    const after = pfs.fileInfo(fd) catch return error.ArtifactStatFailed;
    if (!after.is_regular or after.link_count != 1 or after.size != before.size)
        return error.ArtifactChangedDuringRead;
    return bytes;
}

fn writeAll(fd: pfs.Fd, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const count = pfs.write(fd, bytes[offset..]);
        if (count <= 0) return error.ArtifactWriteFailed;
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

fn parseHex(value: []const u8) ?[64]u8 {
    if (value.len != 64) return null;
    var result: [64]u8 = undefined;
    for (value, 0..) |byte, index| {
        if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return null;
        result[index] = byte;
    }
    return result;
}

fn validHex(value: [64]u8) bool {
    return parseHex(&value) != null;
}

fn equalHex(value: []const u8, expected: [64]u8) bool {
    const parsed = parseHex(value) orelse return false;
    return std.mem.eql(u8, &parsed, &expected);
}

fn controlEntryPresent(directory: []const u8, name: []const u8) bool {
    var path_buffer: [std.fs.max_path_bytes + 1]u8 = undefined;
    const path = std.fmt.bufPrint(&path_buffer, "{s}/{s}\x00", .{ directory, name }) catch return true;
    return pfs.isSymlink(@ptrCast(path.ptr)) or pfs.exists(@ptrCast(path.ptr));
}

test "inactive bundle without active pointer is not loadable authority" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    const loaded = try loadActiveWithoutPromotionReplay(
        std.testing.allocator,
        root,
        .{'a'} ** 64,
        .{'b'} ** 64,
    );
    try std.testing.expect(loaded == .missing);
}

test "active pointer publication rejects stale revision instead of overwriting it" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    const allocator = std.testing.allocator;
    const project = [_]u8{'a'} ** 64;
    const kernel_sha = [_]u8{'b'} ** 64;
    const bundle_sha = [_]u8{'c'} ** 64;
    const body = ActiveBody{
        .project_sha256 = project[0..],
        .bundle_sha256 = bundle_sha[0..],
        .revision = 1,
        .kernel_sha256 = kernel_sha[0..],
        .promotion_receipt_id = ([_]u8{'d'} ** 64)[0..],
        .promotion_request_sha256 = ([_]u8{'e'} ** 64)[0..],
        .promotion_verdict_sha256 = ([_]u8{'f'} ** 64)[0..],
    };
    const body_json = try std.json.Stringify.valueAlloc(allocator, body, .{});
    defer allocator.free(body_json);
    const pointer_sha = observation.sha256Hex(body_json);
    const record_json = try std.json.Stringify.valueAlloc(
        allocator,
        ActiveRecord{ .pointer_sha256 = pointer_sha[0..], .body = body },
        .{},
    );
    defer allocator.free(record_json);
    try publishActiveCas(allocator, root, 0, ZERO_SHA, project, kernel_sha, record_json);
    try std.testing.expectError(
        error.ActiveRevisionMismatch,
        publishActiveCas(allocator, root, 0, ZERO_SHA, project, kernel_sha, record_json),
    );
    const current = try loadActiveIdentity(allocator, root, project, kernel_sha);
    try std.testing.expectEqual(@as(u64, 1), current.revision);
    try std.testing.expectEqualSlices(u8, &bundle_sha, &current.bundle_sha256);
}

test "active promotion lease serializes the whole state-dependent transition" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    var first = try ActiveLease.acquire(root);
    try std.testing.expectError(error.ActivePointerBusy, ActiveLease.acquire(root));
    first.deinit();
    var after_release = try ActiveLease.acquire(root);
    after_release.deinit();
}
