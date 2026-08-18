//! Isolated, provider-backed authoring adapter for project-specific rules.
//!
//! This is deliberately not another agent loop.  The host derives one bounded
//! packet from a completed tool-observation Run, admits one request through a
//! deterministic trigger/budget/cooldown gate, and sends exactly one no-tools
//! provider request under a frozen role prompt.  A response is only evidence:
//! it becomes a non-authorizing `RuleCandidate` after an immutable author
//! receipt is persisted and can be reopened against every candidate field.
//!
//! The caller must provide an allocator compatible with the Provider's owned
//! stream events, matching the existing Provider consumer contract.  This
//! module never receives or mutates an actor Conversation or tool catalog.

const std = @import("std");
const pfs = @import("platform").fs;
const provider_mod = @import("../api/provider.zig");
const api_stream = @import("../api/stream.zig");
const types = @import("../types.zig");
const observation = @import("../tools/observation.zig");
const AbortSignal = @import("../util/abort.zig").AbortSignal;
const time = @import("../util/time.zig");
const journal_mod = @import("tool_observation_journal.zig");
const impact_stats = @import("rule_impact_stats.zig");
const source_receipt = @import("rule_source_receipt.zig");
const project_rule_spec = @import("project_rule_spec.zig");
const rule_candidate = @import("rule_candidate.zig");
const ontology_projection = @import("ontology_rule_projection.zig");

pub const SYSTEM_PROMPT = @embedFile("templates/rule_author/prompt.md");
pub const SYSTEM_PROMPT_V2 = @embedFile("templates/rule_author/prompt-v2.md");
pub fn systemPromptSha256() [64]u8 {
    return observation.sha256Hex(SYSTEM_PROMPT);
}
pub const PACKET_SCHEMA_VERSION = "metacodes-rule-author-packet-v1";
pub const PACKET_SCHEMA_VERSION_V2 = "metacodes-rule-author-packet-v2";
pub const RESPONSE_SCHEMA_VERSION = "metacodes-rule-author-response-v1";
pub const RECEIPT_SCHEMA_VERSION = "metacodes-rule-author-receipt-v1";
pub const RECEIPT_SCHEMA_VERSION_V2 = "metacodes-rule-author-receipt-v2";
pub const RECEIPT_FILE_PREFIX = "rule-author-receipt-";

pub const MAX_PACKET_BYTES: usize = 64 * 1024;
pub const MAX_RESPONSE_BYTES: usize = 64 * 1024;
pub const MAX_RECEIPT_BYTES: usize = 32 * 1024;
pub const MAX_MODEL_BYTES: usize = 256;
pub const MAX_REASON_BYTES: usize = 2048;
pub const MAX_EVIDENCE_ITEMS: usize = 16;
pub const MAX_EVIDENCE_SUMMARY_BYTES: usize = 4096;
pub const MAX_PACKET_V2_BYTES: usize = MAX_PACKET_BYTES + ontology_projection.MAX_PACKET_BYTES + 4096;

pub const Trigger = enum {
    user_correction,
    repeated_typed_failure,
    runtime_counterexample,
    drift_detected,
    stable_threshold,
    /// 过程信号轴(2026-08-18 selflearn-r1 判读:本 cohort 的死法是安静
    /// 做错——测试弱化/假闭合/终验失败,不是工具失败风暴)。全部由
    /// hash-bound journal 推导,拒绝调用者散文。
    process_signal,
};

pub const EvidenceKind = enum {
    user_correction,
    runtime_counterexample,
    typed_failure_summary,
    drift_report,
    benchmark_threshold,
};

/// One bounded evidence excerpt plus the immutable artifact/receipt that owns
/// it.  For host source receipts, prepare() reopens the receipt and requires
/// the excerpt hash to equal its exact subject hash.
pub const EvidenceItem = struct {
    kind: EvidenceKind,
    artifact_sha256: [64]u8,
    summary: []const u8,
};

pub const CallCaps = struct {
    max_cost_microusd: u64,
    max_input_tokens: u64,
    max_output_tokens: u64,
};

/// Integer price authority supplied by the paid-run manifest.  Rates are
/// micro-USD per one million tokens; the provenance digest commits the exact
/// table/version used by the caller.  Integer ceiling arithmetic keeps the
/// authorization envelope deterministic and conservative.
pub const PricingAuthority = struct {
    provenance_sha256: [64]u8,
    input_microusd_per_mtok: u64,
    output_microusd_per_mtok: u64,
    cache_read_microusd_per_mtok: u64,
    cache_write_microusd_per_mtok: u64,
};

/// Host-supplied expected identity for one already-persisted ontology
/// projection.  prepare() reopens the receipt and accepts none of the packet
/// prose from the caller.
pub const OntologyProjectionAuthority = struct {
    receipt_id: [64]u8,
    ontology_revision: [64]u8,
    ontology_snapshot_sha256: [64]u8,
    active_bundle_revision: u64,
    active_bundle_sha256: [64]u8,
};

pub const ProjectionBinding = struct {
    receipt_id: [64]u8,
    packet_sha256: [64]u8,
    ontology_revision: [64]u8,
    ontology_snapshot_sha256: [64]u8,
    active_bundle_revision: u64,
    active_bundle_sha256: [64]u8,
    generation_evidence_sha256: [64]u8,
    held_out_commitments_sha256: [64]u8,
};

pub const Protocol = union(enum) {
    v1,
    v2: ProjectionBinding,
};

pub const PrepareInput = struct {
    session_dir: []const u8,
    project_sha256: [64]u8,
    author_sha256: [64]u8,
    provider_sha256: [64]u8,
    budget_authorization_sha256: [64]u8,
    model: []const u8,
    observation: journal_mod.RunBinding,
    labels: impact_stats.RunLabels = .{},
    trigger: Trigger,
    evidence: []const EvidenceItem,
    caps: CallCaps,
    pricing: PricingAuthority,
    ontology_projection: ?OntologyProjectionAuthority = null,
};

const WireRun = struct {
    session_id: []const u8,
    run_id: []const u8,
    first_sequence: u64,
    last_sequence: u64,
    interval_sha256: []const u8,
};

const WireEvidence = struct {
    kind: EvidenceKind,
    artifact_sha256: []const u8,
    summary_sha256: []const u8,
    summary: []const u8,
};

const WirePacket = struct {
    schema_version: []const u8 = PACKET_SCHEMA_VERSION,
    project_sha256: []const u8,
    source: WireRun,
    trigger: Trigger,
    evidence: []const WireEvidence,
    impact: impact_stats.Snapshot,
};

const WireProjectionIdentity = struct {
    receipt_id: []const u8,
    packet_sha256: []const u8,
    ontology_revision: []const u8,
    ontology_snapshot_sha256: []const u8,
    active_bundle_revision: u64,
    active_bundle_sha256: []const u8,
    generation_evidence_sha256: []const u8,
    held_out_commitments_sha256: []const u8,
};

const WirePacketV2 = struct {
    schema_version: []const u8 = PACKET_SCHEMA_VERSION_V2,
    project_sha256: []const u8,
    source: WireRun,
    trigger: Trigger,
    evidence: []const WireEvidence,
    impact: impact_stats.Snapshot,
    ontology_projection_identity: WireProjectionIdentity,
    ontology_projection: std.json.Value,
};

pub const PreparedRequest = struct {
    arena: std.heap.ArenaAllocator,
    project_sha256: [64]u8,
    author_sha256: [64]u8,
    provider_sha256: [64]u8,
    budget_authorization_sha256: [64]u8,
    model: []const u8,
    model_sha256: [64]u8,
    system_prompt_sha256: [64]u8,
    observation: journal_mod.RunBinding,
    interval_sha256: [64]u8,
    trigger: Trigger,
    packet: []const u8,
    packet_sha256: [64]u8,
    caps: CallCaps,
    pricing: PricingAuthority,
    protocol: Protocol = .v1,

    pub fn deinit(self: *PreparedRequest) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

/// Reopens the exact completed Run and derives the stats in-process.  A caller
/// cannot substitute a detached summary or an interval hash copied from a
/// different journal.
pub fn prepare(allocator: std.mem.Allocator, input: PrepareInput) !PreparedRequest {
    try validateIdentity(input.project_sha256);
    try validateIdentity(input.author_sha256);
    try validateIdentity(input.provider_sha256);
    try validateIdentity(input.budget_authorization_sha256);
    if (!validText(input.model, MAX_MODEL_BYTES)) return error.InvalidModel;
    try validateCaps(input.caps);
    try validatePricing(input.pricing);
    if (input.caps.max_cost_microusd < try worstCaseCost(input.caps, input.pricing))
        return error.CostCapCannotCoverTokenCaps;
    if (input.evidence.len > MAX_EVIDENCE_ITEMS)
        return error.InvalidEvidence;

    var run = try journal_mod.loadRunDispatches(
        allocator,
        input.session_dir,
        input.observation,
    );
    defer run.deinit();
    var snapshot = try impact_stats.derive(allocator, &run, input.labels);
    defer snapshot.deinit(allocator);
    if (!std.mem.eql(u8, &run.interval_sha256, &snapshot.source_interval_sha256))
        return error.ImpactIntervalMismatch;

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    const model = try a.dupe(u8, input.model);
    const wire_evidence = try buildEvidence(a, input, snapshot, run.interval_sha256);
    if (!triggerSatisfied(input.trigger, snapshot, input.evidence))
        return error.TriggerNotSatisfied;

    const source = WireRun{
        .session_id = input.observation.session_id.asSlice(),
        .run_id = input.observation.run_id.asSlice(),
        .first_sequence = input.observation.first_sequence,
        .last_sequence = input.observation.last_sequence,
        .interval_sha256 = run.interval_sha256[0..],
    };
    var protocol: Protocol = .v1;
    const packet = if (input.ontology_projection) |authority| blk: {
        var loaded = try loadProjectionAuthority(
            allocator,
            input.session_dir,
            input.project_sha256,
            authority,
        );
        defer loaded.deinit();
        const binding = projectionBinding(&loaded);
        protocol = .{ .v2 = binding };
        const ontology_value = std.json.parseFromSliceLeaky(
            std.json.Value,
            a,
            loaded.projection.packet,
            .{
                .ignore_unknown_fields = false,
                .allocate = .alloc_always,
                .duplicate_field_behavior = .@"error",
            },
        ) catch return error.InvalidOntologyProjectionPacket;
        break :blk try std.json.Stringify.valueAlloc(a, WirePacketV2{
            .project_sha256 = input.project_sha256[0..],
            .source = source,
            .trigger = input.trigger,
            .evidence = wire_evidence,
            .impact = snapshot,
            .ontology_projection_identity = wireProjectionIdentity(&binding),
            .ontology_projection = ontology_value,
        }, .{});
    } else try std.json.Stringify.valueAlloc(a, WirePacket{
        .project_sha256 = input.project_sha256[0..],
        .source = source,
        .trigger = input.trigger,
        .evidence = wire_evidence,
        .impact = snapshot,
    }, .{});
    const max_packet_bytes = switch (protocol) {
        .v1 => MAX_PACKET_BYTES,
        .v2 => MAX_PACKET_V2_BYTES,
    };
    if (packet.len == 0 or packet.len > max_packet_bytes) return error.PacketTooLarge;
    // Provider has no per-call input-token setter.  Reserving at least one
    // token per request byte is conservative for UTF-8 and avoids pretending
    // the adapter can enforce a smaller amount than it actually sends.
    const system_prompt = systemPrompt(protocol);
    const conservative_input = std.math.add(usize, packet.len, system_prompt.len) catch
        return error.PacketTooLarge;
    if (input.caps.max_input_tokens < conservative_input)
        return error.InputCapCannotCoverRequest;

    return .{
        .arena = arena,
        .project_sha256 = input.project_sha256,
        .author_sha256 = input.author_sha256,
        .provider_sha256 = input.provider_sha256,
        .budget_authorization_sha256 = input.budget_authorization_sha256,
        .model = model,
        .model_sha256 = observation.sha256Hex(model),
        .system_prompt_sha256 = systemPromptSha256For(protocol),
        .observation = input.observation,
        .interval_sha256 = run.interval_sha256,
        .trigger = input.trigger,
        .packet = packet,
        .packet_sha256 = observation.sha256Hex(packet),
        .caps = input.caps,
        .pricing = input.pricing,
        .protocol = protocol,
    };
}

fn systemPrompt(protocol: Protocol) []const u8 {
    return switch (protocol) {
        .v1 => SYSTEM_PROMPT,
        .v2 => SYSTEM_PROMPT_V2,
    };
}

fn systemPromptSha256For(protocol: Protocol) [64]u8 {
    return observation.sha256Hex(systemPrompt(protocol));
}

fn projectionBinding(loaded: *const ontology_projection.Loaded) ProjectionBinding {
    return .{
        .receipt_id = loaded.receipt_id,
        .packet_sha256 = loaded.projection.packet_sha256,
        .ontology_revision = loaded.projection.ontology_revision,
        .ontology_snapshot_sha256 = loaded.projection.ontology_snapshot_sha256,
        .active_bundle_revision = loaded.projection.active_bundle_revision,
        .active_bundle_sha256 = loaded.projection.active_bundle_sha256,
        .generation_evidence_sha256 = loaded.projection.generation_evidence_sha256,
        .held_out_commitments_sha256 = loaded.projection.held_out_commitments_sha256,
    };
}

fn wireProjectionIdentity(binding: *const ProjectionBinding) WireProjectionIdentity {
    return .{
        .receipt_id = binding.receipt_id[0..],
        .packet_sha256 = binding.packet_sha256[0..],
        .ontology_revision = binding.ontology_revision[0..],
        .ontology_snapshot_sha256 = binding.ontology_snapshot_sha256[0..],
        .active_bundle_revision = binding.active_bundle_revision,
        .active_bundle_sha256 = binding.active_bundle_sha256[0..],
        .generation_evidence_sha256 = binding.generation_evidence_sha256[0..],
        .held_out_commitments_sha256 = binding.held_out_commitments_sha256[0..],
    };
}

fn loadProjectionAuthority(
    allocator: std.mem.Allocator,
    session_dir: []const u8,
    project_sha256: [64]u8,
    authority: OntologyProjectionAuthority,
) !ontology_projection.Loaded {
    var loaded = try ontology_projection.loadBound(allocator, session_dir, authority.receipt_id);
    errdefer loaded.deinit();
    if (!std.mem.eql(u8, &loaded.projection.project_sha256, &project_sha256) or
        !std.mem.eql(u8, &loaded.projection.ontology_revision, &authority.ontology_revision) or
        !std.mem.eql(u8, &loaded.projection.ontology_snapshot_sha256, &authority.ontology_snapshot_sha256) or
        loaded.projection.active_bundle_revision != authority.active_bundle_revision or
        !std.mem.eql(u8, &loaded.projection.active_bundle_sha256, &authority.active_bundle_sha256))
        return error.OntologyProjectionIdentityMismatch;
    return loaded;
}

fn reopenProjectionBinding(
    allocator: std.mem.Allocator,
    session_dir: []const u8,
    project_sha256: [64]u8,
    binding: ProjectionBinding,
) !ontology_projection.Loaded {
    var loaded = try ontology_projection.loadBound(allocator, session_dir, binding.receipt_id);
    errdefer loaded.deinit();
    const observed = projectionBinding(&loaded);
    if (!std.mem.eql(u8, &loaded.projection.project_sha256, &project_sha256) or
        !std.meta.eql(observed, binding))
        return error.OntologyProjectionBindingMismatch;
    return loaded;
}

fn validateEvidence(
    session_dir: []const u8,
    project_sha256: [64]u8,
    interval_sha256: [64]u8,
    item: EvidenceItem,
) !void {
    try validateIdentity(item.artifact_sha256);
    if (!validText(item.summary, MAX_EVIDENCE_SUMMARY_BYTES))
        return error.InvalidEvidence;
    if (item.kind != .user_correction and item.kind != .runtime_counterexample)
        return;
    var receipt = try source_receipt.loadBound(
        std.heap.c_allocator,
        session_dir,
        item.artifact_sha256,
    );
    defer receipt.deinit();
    const expected_kind: source_receipt.Kind = if (item.kind == .user_correction)
        .user_correction
    else
        .runtime_counterexample;
    if (receipt.kind != expected_kind or
        !std.mem.eql(u8, &receipt.project_sha256, &project_sha256) or
        !std.mem.eql(u8, &receipt.subject_sha256, &observation.sha256Hex(item.summary)))
        return error.SourceReceiptMismatch;
    if (item.kind == .runtime_counterexample and
        (receipt.observation_interval_sha256 == null or
            !std.mem.eql(u8, &receipt.observation_interval_sha256.?, &interval_sha256)))
        return error.FutureOrForeignEvidence;
}

fn buildEvidence(
    allocator: std.mem.Allocator,
    input: PrepareInput,
    snapshot: impact_stats.Snapshot,
    interval_sha256: [64]u8,
) ![]const WireEvidence {
    switch (input.trigger) {
        .drift_detected, .stable_threshold => return error.UnsupportedTriggerSource,
        .process_signal => {
            if (input.evidence.len != 0) return error.UnsupportedEvidenceSource;
            const summary = try std.fmt.allocPrint(
                allocator,
                "test_weakening_candidates={}; weakening_with_failed_verification={}; " ++
                    "final_closure_tier0_with_mutations={}; known_failing={}; " ++
                    "authoritative_non_successes={}",
                .{
                    snapshot.test_weakening_candidates,
                    snapshot.weakening_with_failed_verification,
                    snapshot.final_closure_tier0_with_mutations,
                    snapshot.known_failing,
                    snapshot.authoritative_non_successes,
                },
            );
            const summary_sha256 = observation.sha256Hex(summary);
            const rows = try allocator.alloc(WireEvidence, 1);
            rows[0] = .{
                .kind = .typed_failure_summary,
                .artifact_sha256 = try allocator.dupe(u8, interval_sha256[0..]),
                .summary_sha256 = try allocator.dupe(u8, summary_sha256[0..]),
                .summary = summary,
            };
            return rows;
        },
        .repeated_typed_failure => {
            // This trigger is derived entirely from the hash-bound journal.
            // Reject caller prose so an evaluation case that occurred after
            // the interval cannot be smuggled into the author packet.
            if (input.evidence.len != 0) return error.UnsupportedEvidenceSource;
            const summary = try std.fmt.allocPrint(
                allocator,
                "authoritative_non_successes={}; reobservation_failures={}; invalid_effects={}",
                .{
                    snapshot.authoritative_non_successes,
                    snapshot.reobservation_failures,
                    snapshot.invalid_effects,
                },
            );
            const summary_sha256 = observation.sha256Hex(summary);
            const values = try allocator.alloc(WireEvidence, 1);
            values[0] = .{
                .kind = .typed_failure_summary,
                .artifact_sha256 = try allocator.dupe(u8, interval_sha256[0..]),
                .summary_sha256 = try allocator.dupe(u8, summary_sha256[0..]),
                .summary = summary,
            };
            return values;
        },
        .user_correction, .runtime_counterexample => {
            if (input.evidence.len != 1) return error.InvalidEvidence;
            const values = try allocator.alloc(WireEvidence, 1);
            const item = input.evidence[0];
            try validateEvidence(
                input.session_dir,
                input.project_sha256,
                interval_sha256,
                item,
            );
            const summary = try allocator.dupe(u8, item.summary);
            const summary_sha256 = observation.sha256Hex(summary);
            values[0] = .{
                .kind = item.kind,
                .artifact_sha256 = try allocator.dupe(u8, item.artifact_sha256[0..]),
                .summary_sha256 = try allocator.dupe(u8, summary_sha256[0..]),
                .summary = summary,
            };
            return values;
        },
    }
}

fn hasEvidence(evidence: []const EvidenceItem, kind: EvidenceKind) bool {
    for (evidence) |item| if (item.kind == kind) return true;
    return false;
}

/// 测试钩子:触发谓词是自演化剂量的第一因,必须可单测。
pub fn testTriggerSatisfied(
    trigger: Trigger,
    snapshot: impact_stats.Snapshot,
    evidence: []const EvidenceItem,
) bool {
    return triggerSatisfied(trigger, snapshot, evidence);
}

fn triggerSatisfied(
    trigger: Trigger,
    snapshot: impact_stats.Snapshot,
    evidence: []const EvidenceItem,
) bool {
    return switch (trigger) {
        .user_correction => hasEvidence(evidence, .user_correction),
        .repeated_typed_failure => evidence.len == 0 and
            snapshot.authoritative_non_successes >= 3,
        .process_signal => evidence.len == 0 and
            (snapshot.test_weakening_candidates >= 2 or
                snapshot.weakening_with_failed_verification >= 1 or
                snapshot.final_closure_tier0_with_mutations or
                snapshot.known_failing),
        .runtime_counterexample => hasEvidence(evidence, .runtime_counterexample) and
            (snapshot.enforced_pre_blocks_before_dispatch > 0 or snapshot.formal_faults > 0),
        .drift_detected, .stable_threshold => false,
    };
}

/// Local authority is deliberately explicit.  Ordinary completed runs do not
/// have an enabled authority and therefore cannot call a provider.
pub const BudgetAuthority = struct {
    enabled: bool = false,
    now_ns: i128,
    last_authorized_ns: ?i128 = null,
    cooldown_ns: u64,
    remaining_requests: u64,
    remaining_cost_microusd: u64,
    remaining_input_tokens: u64,
    remaining_output_tokens: u64,
};

const PermitBody = struct {
    prepared_sha256: []const u8,
    authorized_at_ns: i128,
    cooldown_ns: u64,
    max_cost_microusd: u64,
    max_input_tokens: u64,
    max_output_tokens: u64,
};

pub const Permit = struct {
    prepared_sha256: [64]u8,
    authorization_sha256: [64]u8,
    authorized_at_ns: i128,
    cooldown_ns: u64,
    caps: CallCaps,
};

pub fn authorize(prepared: *const PreparedRequest, authority: BudgetAuthority) !Permit {
    if (!authority.enabled) return error.AuthoringDisabled;
    if (authority.remaining_requests == 0 or
        prepared.caps.max_cost_microusd > authority.remaining_cost_microusd or
        prepared.caps.max_input_tokens > authority.remaining_input_tokens or
        prepared.caps.max_output_tokens > authority.remaining_output_tokens)
        return error.AuthorBudgetExceeded;
    if (authority.last_authorized_ns) |last| {
        if (authority.now_ns < last) return error.InvalidCooldownClock;
        const elapsed: u128 = @intCast(authority.now_ns - last);
        if (elapsed < authority.cooldown_ns) return error.AuthorCooldownActive;
    }
    const prepared_sha256 = try preparedIdentity(prepared);
    const body = PermitBody{
        .prepared_sha256 = prepared_sha256[0..],
        .authorized_at_ns = authority.now_ns,
        .cooldown_ns = authority.cooldown_ns,
        .max_cost_microusd = prepared.caps.max_cost_microusd,
        .max_input_tokens = prepared.caps.max_input_tokens,
        .max_output_tokens = prepared.caps.max_output_tokens,
    };
    const encoded = try std.json.Stringify.valueAlloc(std.heap.c_allocator, body, .{});
    defer std.heap.c_allocator.free(encoded);
    return .{
        .prepared_sha256 = prepared_sha256,
        .authorization_sha256 = observation.sha256Hex(encoded),
        .authorized_at_ns = authority.now_ns,
        .cooldown_ns = authority.cooldown_ns,
        .caps = prepared.caps,
    };
}

pub const BoundProvider = struct {
    provider: provider_mod.Provider,
    provider_sha256: [64]u8,
};

pub const Decision = enum { abstain, propose };

pub const Proposal = struct {
    invariant: []const u8,
    falsifier: []const u8,
    rule_spec: project_rule_spec.Spec,
    lean_source: []const u8,
};

pub const Usage = struct {
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    cache_read_input_tokens: u64 = 0,
    cache_creation_input_tokens: u64 = 0,
};

pub const AuthorResult = struct {
    arena: std.heap.ArenaAllocator,
    receipt_id: [64]u8,
    project_sha256: [64]u8,
    observation: journal_mod.RunBinding,
    interval_sha256: [64]u8,
    decision: Decision,
    reason: []const u8,
    proposal: ?Proposal,
    usage: Usage,
    provider_elapsed_ns: u64,
    protocol: Protocol = .v1,

    pub fn deinit(self: *AuthorResult) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

const ResponseWire = struct {
    schema_version: []const u8,
    decision: Decision,
    reason: []const u8,
    invariant: ?[]const u8,
    falsifier: ?[]const u8,
    rule_spec: ?project_rule_spec.Wire,
    lean_source: ?[]const u8,
};

/// Execute one admitted no-tools author request and durably persist its
/// content-addressed receipt.  Identity and permit drift are checked before
/// network I/O, then checked again before evidence is committed.
pub fn author(
    allocator: std.mem.Allocator,
    session_dir: []const u8,
    bound_provider: BoundProvider,
    prepared: *const PreparedRequest,
    permit: Permit,
    abort: ?*const AbortSignal,
) !AuthorResult {
    try validatePermit(prepared, permit);
    try validatePreparedProjection(allocator, session_dir, prepared);
    if (!std.mem.eql(u8, &bound_provider.provider_sha256, &prepared.provider_sha256))
        return error.ProviderIdentityMismatch;
    if (!std.mem.eql(u8, bound_provider.provider.model(), prepared.model))
        return error.ProviderModelMismatch;
    if (bound_provider.provider.maxTokens() > prepared.caps.max_output_tokens)
        return error.OutputCapNotEnforcedByProvider;

    const provider_started_ns = time.nowNs();
    const api_messages = [_]types.ApiMessage{.{
        .role = .user,
        .content = &[_]types.ApiContent{.{ .text = prepared.packet }},
    }};
    var stream = try bound_provider.provider.sendStream(
        &api_messages,
        systemPrompt(prepared.protocol),
        null,
        abort,
        null,
        null,
        "",
    );
    defer stream.deinit();
    const request_id = stream.requestId();

    var response: std.ArrayList(u8) = .empty;
    defer response.deinit(allocator);
    var usage = Usage{};
    var saw_done = false;
    while (try stream.next()) |event| switch (event) {
        .text => |bytes| {
            defer allocator.free(bytes);
            if (bytes.len > MAX_RESPONSE_BYTES -| response.items.len)
                return error.AuthorResponseTooLarge;
            try response.appendSlice(allocator, bytes);
        },
        // Reasoning is provider-private control output, not part of the
        // versioned RuleAuthor response.  In particular it must not be
        // concatenated into the strict JSON proposal or persisted as rule
        // evidence.  The final typed response remains the only admitted
        // author payload.
        .thinking => |bytes| allocator.free(bytes),
        .usage => |delta| try addUsage(&usage, delta),
        .done => saw_done = true,
        .tool_use_start => |tool| {
            allocator.free(tool.id);
            allocator.free(tool.name);
            allocator.free(tool.input_json);
            return error.AuthorToolEventForbidden;
        },
        .web_search_query => |query| {
            allocator.free(query);
            return error.AuthorToolEventForbidden;
        },
        .web_search_result => |result| {
            allocator.free(result.ui_text);
            allocator.free(result.content_json);
            return error.AuthorToolEventForbidden;
        },
    };
    if (!saw_done or stream.stopReason() != .end_turn)
        return error.AuthorResponseIncomplete;
    const provider_elapsed_ns = elapsedNs(provider_started_ns);
    try validatePermit(prepared, permit);
    // The provider may have run for minutes. Reopen the projection and every
    // bound generation receipt again before turning its response into durable
    // evidence; prepare-time validity is not commit-time validity.
    try validatePreparedProjection(allocator, session_dir, prepared);
    const metered_input = std.math.add(
        u64,
        usage.input_tokens,
        std.math.add(u64, usage.cache_read_input_tokens, usage.cache_creation_input_tokens) catch
            return error.UsageOverflow,
    ) catch return error.UsageOverflow;
    if (metered_input > prepared.caps.max_input_tokens or
        usage.output_tokens > prepared.caps.max_output_tokens)
        return error.ProviderUsageExceededPermit;

    var result = try parseResponse(allocator, response.items);
    errdefer result.deinit();
    result.project_sha256 = prepared.project_sha256;
    result.observation = prepared.observation;
    result.interval_sha256 = prepared.interval_sha256;
    result.usage = usage;
    result.provider_elapsed_ns = provider_elapsed_ns;
    result.protocol = prepared.protocol;
    result.receipt_id = try persistReceipt(
        session_dir,
        prepared,
        permit,
        request_id.bytes,
        response.items,
        &result,
    );
    var committed = try loadReceipt(allocator, session_dir, result.receipt_id);
    defer committed.deinit();
    if (!try receiptMatchesResult(allocator, &committed, &result))
        return error.AuthorReceiptResultMismatch;
    return result;
}

fn addUsage(total: *Usage, delta: api_stream.UsageDelta) !void {
    total.input_tokens = std.math.add(u64, total.input_tokens, delta.input_tokens) catch
        return error.UsageOverflow;
    total.output_tokens = std.math.add(u64, total.output_tokens, delta.output_tokens) catch
        return error.UsageOverflow;
    total.cache_read_input_tokens = std.math.add(
        u64,
        total.cache_read_input_tokens,
        delta.cache_read_input_tokens,
    ) catch return error.UsageOverflow;
    total.cache_creation_input_tokens = std.math.add(
        u64,
        total.cache_creation_input_tokens,
        delta.cache_creation_input_tokens,
    ) catch return error.UsageOverflow;
}

fn parseResponse(allocator: std.mem.Allocator, bytes: []const u8) !AuthorResult {
    if (bytes.len == 0 or bytes.len > MAX_RESPONSE_BYTES or
        !std.unicode.utf8ValidateSlice(bytes))
        return error.InvalidAuthorResponse;
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    var trimmed = std.mem.trim(u8, bytes, " \t\r\n");
    // 真模型常把 JSON 包进 markdown fence(```json … ```)——selflearn p1
    // 生产首开火即中 InvalidAuthorResponse。剥一层外围 fence 再解析;内容
    // 里的 ``` 都在 JSON 字符串内被转义,只有真正的收尾 fence 落在末尾。
    if (std.mem.startsWith(u8, trimmed, "```")) {
        if (std.mem.indexOfScalar(u8, trimmed, '\n')) |first_newline| {
            var inner = std.mem.trim(u8, trimmed[first_newline + 1 ..], " \t\r\n");
            if (std.mem.endsWith(u8, inner, "```"))
                inner = std.mem.trimEnd(u8, inner[0 .. inner.len - 3], " \t\r\n");
            trimmed = inner;
        }
    }
    const response = std.json.parseFromSliceLeaky(ResponseWire, a, trimmed, .{
        .ignore_unknown_fields = false,
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidAuthorResponse,
    };
    if (!std.mem.eql(u8, response.schema_version, RESPONSE_SCHEMA_VERSION) or
        !validText(response.reason, MAX_REASON_BYTES))
        return error.InvalidAuthorResponse;
    var proposal: ?Proposal = null;
    switch (response.decision) {
        .abstain => if (response.invariant != null or response.falsifier != null or
            response.rule_spec != null or response.lean_source != null)
            return error.InvalidAuthorResponse,
        .propose => {
            const invariant = response.invariant orelse return error.InvalidAuthorResponse;
            const falsifier = response.falsifier orelse return error.InvalidAuthorResponse;
            const wire_spec = response.rule_spec orelse return error.InvalidAuthorResponse;
            const lean_source = response.lean_source orelse return error.InvalidAuthorResponse;
            if (!validText(invariant, rule_candidate.MAX_INVARIANT_BYTES) or
                !validText(falsifier, rule_candidate.MAX_FALSIFIER_BYTES) or
                !validText(lean_source, rule_candidate.MAX_LEAN_SOURCE_BYTES))
                return error.InvalidAuthorResponse;
            const spec = project_rule_spec.fromWire(wire_spec) catch
                return error.InvalidAuthorResponse;
            const canonical_lean = try renderCanonicalLean(a, spec);
            if (!std.mem.eql(u8, lean_source, canonical_lean))
                return error.LeanSourceRuleSpecMismatch;
            proposal = .{
                .invariant = invariant,
                .falsifier = falsifier,
                .rule_spec = spec,
                .lean_source = lean_source,
            };
        },
    }
    return .{
        .arena = arena,
        .receipt_id = undefined,
        .project_sha256 = undefined,
        .observation = undefined,
        .interval_sha256 = undefined,
        .decision = response.decision,
        .reason = response.reason,
        .proposal = proposal,
        .usage = .{},
        .provider_elapsed_ns = 0,
        .protocol = .v1,
    };
}

fn validatePreparedProjection(
    allocator: std.mem.Allocator,
    session_dir: []const u8,
    prepared: *const PreparedRequest,
) !void {
    switch (prepared.protocol) {
        .v1 => {},
        .v2 => |binding| {
            var loaded = try reopenProjectionBinding(
                allocator,
                session_dir,
                prepared.project_sha256,
                binding,
            );
            loaded.deinit();
        },
    }
}

pub fn renderCanonicalLean(
    allocator: std.mem.Allocator,
    spec: project_rule_spec.Spec,
) ![]u8 {
    try project_rule_spec.validate(spec);
    const scope = switch (spec.target_scope) {
        .all => "all",
        .existing_file => "existingFile",
    };
    const effect = switch (spec.effect_requirement) {
        .none => "none",
        .file_mutation_v1_reobserved => "fileMutationV1Reobserved",
    };
    const target_expr = switch (spec.target) {
        .tool => |name| try std.fmt.allocPrint(allocator, ".tool \"{s}\"", .{name}),
        .effect_class => |cls| try std.fmt.allocPrint(allocator, ".effectClass .{s}", .{
            switch (cls) {
                .existing_file_rewrite => "existingFileRewrite",
            },
        }),
    };
    defer allocator.free(target_expr);
    return std.fmt.allocPrint(
        allocator,
        "def spec : RuleSpec := {{ target := {s}, targetScope := .{s}, denyTarget := {}, maxInputBytes := {}, maxAgentDepth := {}, authoritativeOnly := {}, effectRequirement := .{s} }}\ntheorem spec_valid : valid spec = true := by rfl",
        .{
            target_expr,
            scope,
            spec.deny_target,
            spec.max_input_bytes,
            spec.max_agent_depth,
            spec.authoritative_only,
            effect,
        },
    );
}

fn validatePermit(prepared: *const PreparedRequest, permit: Permit) !void {
    const prepared_sha256 = try preparedIdentity(prepared);
    if (!std.mem.eql(u8, &prepared_sha256, &permit.prepared_sha256) or
        !std.meta.eql(prepared.caps, permit.caps))
        return error.PermitIdentityMismatch;
    const body = PermitBody{
        .prepared_sha256 = permit.prepared_sha256[0..],
        .authorized_at_ns = permit.authorized_at_ns,
        .cooldown_ns = permit.cooldown_ns,
        .max_cost_microusd = permit.caps.max_cost_microusd,
        .max_input_tokens = permit.caps.max_input_tokens,
        .max_output_tokens = permit.caps.max_output_tokens,
    };
    const encoded = try std.json.Stringify.valueAlloc(std.heap.c_allocator, body, .{});
    defer std.heap.c_allocator.free(encoded);
    const expected = observation.sha256Hex(encoded);
    if (!std.mem.eql(u8, &expected, &permit.authorization_sha256))
        return error.PermitIdentityMismatch;
}

const PreparedIdentity = struct {
    project_sha256: []const u8,
    author_sha256: []const u8,
    provider_sha256: []const u8,
    budget_authorization_sha256: []const u8,
    model_sha256: []const u8,
    system_prompt_sha256: []const u8,
    packet_sha256: []const u8,
    interval_sha256: []const u8,
    trigger: Trigger,
    max_cost_microusd: u64,
    max_input_tokens: u64,
    max_output_tokens: u64,
    pricing_provenance_sha256: []const u8,
    input_microusd_per_mtok: u64,
    output_microusd_per_mtok: u64,
    cache_read_microusd_per_mtok: u64,
    cache_write_microusd_per_mtok: u64,
};

const PreparedIdentityV2 = struct {
    schema_version: []const u8 = "metacodes-rule-author-prepared-identity-v2",
    project_sha256: []const u8,
    author_sha256: []const u8,
    provider_sha256: []const u8,
    budget_authorization_sha256: []const u8,
    model_sha256: []const u8,
    system_prompt_sha256: []const u8,
    packet_sha256: []const u8,
    interval_sha256: []const u8,
    trigger: Trigger,
    max_cost_microusd: u64,
    max_input_tokens: u64,
    max_output_tokens: u64,
    pricing_provenance_sha256: []const u8,
    input_microusd_per_mtok: u64,
    output_microusd_per_mtok: u64,
    cache_read_microusd_per_mtok: u64,
    cache_write_microusd_per_mtok: u64,
    ontology_projection: WireProjectionIdentity,
};

fn preparedIdentity(prepared: *const PreparedRequest) ![64]u8 {
    if (!std.mem.eql(u8, &prepared.model_sha256, &observation.sha256Hex(prepared.model)) or
        !std.mem.eql(u8, &prepared.system_prompt_sha256, &systemPromptSha256For(prepared.protocol)) or
        !std.mem.eql(u8, &prepared.packet_sha256, &observation.sha256Hex(prepared.packet)))
        return error.PreparedRequestDrift;
    const encoded = switch (prepared.protocol) {
        .v1 => try std.json.Stringify.valueAlloc(std.heap.c_allocator, PreparedIdentity{
            .project_sha256 = prepared.project_sha256[0..],
            .author_sha256 = prepared.author_sha256[0..],
            .provider_sha256 = prepared.provider_sha256[0..],
            .budget_authorization_sha256 = prepared.budget_authorization_sha256[0..],
            .model_sha256 = prepared.model_sha256[0..],
            .system_prompt_sha256 = prepared.system_prompt_sha256[0..],
            .packet_sha256 = prepared.packet_sha256[0..],
            .interval_sha256 = prepared.interval_sha256[0..],
            .trigger = prepared.trigger,
            .max_cost_microusd = prepared.caps.max_cost_microusd,
            .max_input_tokens = prepared.caps.max_input_tokens,
            .max_output_tokens = prepared.caps.max_output_tokens,
            .pricing_provenance_sha256 = prepared.pricing.provenance_sha256[0..],
            .input_microusd_per_mtok = prepared.pricing.input_microusd_per_mtok,
            .output_microusd_per_mtok = prepared.pricing.output_microusd_per_mtok,
            .cache_read_microusd_per_mtok = prepared.pricing.cache_read_microusd_per_mtok,
            .cache_write_microusd_per_mtok = prepared.pricing.cache_write_microusd_per_mtok,
        }, .{}),
        .v2 => |binding| try std.json.Stringify.valueAlloc(std.heap.c_allocator, PreparedIdentityV2{
            .project_sha256 = prepared.project_sha256[0..],
            .author_sha256 = prepared.author_sha256[0..],
            .provider_sha256 = prepared.provider_sha256[0..],
            .budget_authorization_sha256 = prepared.budget_authorization_sha256[0..],
            .model_sha256 = prepared.model_sha256[0..],
            .system_prompt_sha256 = prepared.system_prompt_sha256[0..],
            .packet_sha256 = prepared.packet_sha256[0..],
            .interval_sha256 = prepared.interval_sha256[0..],
            .trigger = prepared.trigger,
            .max_cost_microusd = prepared.caps.max_cost_microusd,
            .max_input_tokens = prepared.caps.max_input_tokens,
            .max_output_tokens = prepared.caps.max_output_tokens,
            .pricing_provenance_sha256 = prepared.pricing.provenance_sha256[0..],
            .input_microusd_per_mtok = prepared.pricing.input_microusd_per_mtok,
            .output_microusd_per_mtok = prepared.pricing.output_microusd_per_mtok,
            .cache_read_microusd_per_mtok = prepared.pricing.cache_read_microusd_per_mtok,
            .cache_write_microusd_per_mtok = prepared.pricing.cache_write_microusd_per_mtok,
            .ontology_projection = wireProjectionIdentity(&binding),
        }, .{}),
    };
    defer std.heap.c_allocator.free(encoded);
    return observation.sha256Hex(encoded);
}

fn validateCaps(caps: CallCaps) !void {
    if (caps.max_cost_microusd == 0 or caps.max_input_tokens == 0 or
        caps.max_output_tokens == 0)
        return error.InvalidAuthorCaps;
}

fn validatePricing(pricing: PricingAuthority) !void {
    try validateIdentity(pricing.provenance_sha256);
    if (pricing.input_microusd_per_mtok == 0 or
        pricing.output_microusd_per_mtok == 0 or
        pricing.cache_read_microusd_per_mtok == 0 or
        pricing.cache_write_microusd_per_mtok == 0)
        return error.InvalidPricingAuthority;
}

fn ceilTokenCost(tokens: u64, rate_microusd_per_mtok: u64) !u64 {
    const product = std.math.mul(u128, tokens, rate_microusd_per_mtok) catch
        return error.CostOverflow;
    const rounded = std.math.add(u128, product, 999_999) catch return error.CostOverflow;
    const value = rounded / 1_000_000;
    if (value > std.math.maxInt(u64)) return error.CostOverflow;
    return @intCast(value);
}

pub fn worstCaseCost(caps: CallCaps, pricing: PricingAuthority) !u64 {
    try validateCaps(caps);
    try validatePricing(pricing);
    const worst_input_rate = @max(
        @max(pricing.input_microusd_per_mtok, pricing.cache_read_microusd_per_mtok),
        pricing.cache_write_microusd_per_mtok,
    );
    const input_cost = try ceilTokenCost(caps.max_input_tokens, worst_input_rate);
    const output_cost = try ceilTokenCost(caps.max_output_tokens, pricing.output_microusd_per_mtok);
    return std.math.add(u64, input_cost, output_cost) catch error.CostOverflow;
}

pub fn actualCost(usage: Usage, pricing: PricingAuthority) !u64 {
    try validatePricing(pricing);
    var total = try ceilTokenCost(usage.input_tokens, pricing.input_microusd_per_mtok);
    total = std.math.add(
        u64,
        total,
        try ceilTokenCost(usage.output_tokens, pricing.output_microusd_per_mtok),
    ) catch return error.CostOverflow;
    total = std.math.add(
        u64,
        total,
        try ceilTokenCost(usage.cache_read_input_tokens, pricing.cache_read_microusd_per_mtok),
    ) catch return error.CostOverflow;
    total = std.math.add(
        u64,
        total,
        try ceilTokenCost(usage.cache_creation_input_tokens, pricing.cache_write_microusd_per_mtok),
    ) catch return error.CostOverflow;
    return total;
}

fn validateIdentity(value: [64]u8) !void {
    for (value) |byte| if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f'))
        return error.InvalidIdentity;
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

fn validText(value: []const u8, max: usize) bool {
    return value.len > 0 and value.len <= max and
        std.unicode.utf8ValidateSlice(value) and
        std.mem.trim(u8, value, " \t\r\n").len > 0;
}

const ReceiptProposal = struct {
    invariant_sha256: []const u8,
    falsifier_sha256: []const u8,
    rule_spec_sha256: []const u8,
    lean_source_sha256: []const u8,
};

const ReceiptBody = struct {
    schema_version: []const u8 = RECEIPT_SCHEMA_VERSION,
    project_sha256: []const u8,
    author_sha256: []const u8,
    provider_sha256: []const u8,
    budget_authorization_sha256: []const u8,
    model: []const u8,
    model_sha256: []const u8,
    system_prompt_sha256: []const u8,
    packet_sha256: []const u8,
    response_sha256: []const u8,
    source: WireRun,
    trigger: Trigger,
    prepared_sha256: []const u8,
    authorization_sha256: []const u8,
    authorized_at_ns: i128,
    cooldown_ns: u64,
    request_id: []const u8,
    caps: CallCaps,
    pricing: PricingAuthority,
    usage: Usage,
    provider_elapsed_ns: u64,
    decision: Decision,
    reason_sha256: []const u8,
    proposal: ?ReceiptProposal,
};

const ReceiptRecord = struct {
    receipt_id: []const u8,
    body: ReceiptBody,
};

const ReceiptBodyV2 = struct {
    schema_version: []const u8 = RECEIPT_SCHEMA_VERSION_V2,
    project_sha256: []const u8,
    author_sha256: []const u8,
    provider_sha256: []const u8,
    budget_authorization_sha256: []const u8,
    model: []const u8,
    model_sha256: []const u8,
    system_prompt_sha256: []const u8,
    packet_sha256: []const u8,
    response_sha256: []const u8,
    source: WireRun,
    trigger: Trigger,
    prepared_sha256: []const u8,
    authorization_sha256: []const u8,
    authorized_at_ns: i128,
    cooldown_ns: u64,
    request_id: []const u8,
    caps: CallCaps,
    pricing: PricingAuthority,
    usage: Usage,
    provider_elapsed_ns: u64,
    decision: Decision,
    reason_sha256: []const u8,
    proposal: ?ReceiptProposal,
    ontology_projection: WireProjectionIdentity,
};

const ReceiptRecordV2 = struct {
    receipt_id: []const u8,
    body: ReceiptBodyV2,
};

const ReceiptSchemaProbe = struct {
    body: struct { schema_version: []const u8 },
};

pub const LoadedReceipt = struct {
    arena: std.heap.ArenaAllocator,
    receipt_id: [64]u8,
    project_sha256: [64]u8,
    author_sha256: [64]u8,
    provider_sha256: [64]u8,
    budget_authorization_sha256: [64]u8,
    model_sha256: [64]u8,
    system_prompt_sha256: [64]u8,
    packet_sha256: [64]u8,
    response_sha256: [64]u8,
    observation: journal_mod.RunBinding,
    interval_sha256: [64]u8,
    trigger: Trigger,
    prepared_sha256: [64]u8,
    authorization_sha256: [64]u8,
    authorized_at_ns: i128,
    cooldown_ns: u64,
    caps: CallCaps,
    pricing: PricingAuthority,
    usage: Usage,
    provider_elapsed_ns: u64,
    decision: Decision,
    reason_sha256: [64]u8,
    invariant_sha256: ?[64]u8,
    falsifier_sha256: ?[64]u8,
    rule_spec_sha256: ?[64]u8,
    lean_source_sha256: ?[64]u8,
    protocol: Protocol = .v1,

    pub fn deinit(self: *LoadedReceipt) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

fn persistReceipt(
    session_dir: []const u8,
    prepared: *const PreparedRequest,
    permit: Permit,
    request_id: [12]u8,
    response: []const u8,
    result: *const AuthorResult,
) ![64]u8 {
    // Close the post-response TOCTOU window as tightly as possible. This is
    // the final observation before the author verdict becomes durable.
    try validatePreparedProjection(std.heap.c_allocator, session_dir, prepared);
    var proposal: ?ReceiptProposal = null;
    var invariant_sha256: [64]u8 = undefined;
    var falsifier_sha256: [64]u8 = undefined;
    var proposal_rule_spec_sha256: [64]u8 = undefined;
    var lean_source_sha256: [64]u8 = undefined;
    var rule_spec_json: ?[]u8 = null;
    defer if (rule_spec_json) |bytes| std.heap.c_allocator.free(bytes);
    if (result.proposal) |value| {
        rule_spec_json = try project_rule_spec.renderCanonical(
            std.heap.c_allocator,
            value.rule_spec,
        );
        proposal_rule_spec_sha256 = observation.sha256Hex(rule_spec_json.?);
        invariant_sha256 = observation.sha256Hex(value.invariant);
        falsifier_sha256 = observation.sha256Hex(value.falsifier);
        lean_source_sha256 = observation.sha256Hex(value.lean_source);
        proposal = .{
            .invariant_sha256 = invariant_sha256[0..],
            .falsifier_sha256 = falsifier_sha256[0..],
            .rule_spec_sha256 = proposal_rule_spec_sha256[0..],
            .lean_source_sha256 = lean_source_sha256[0..],
        };
    }
    const response_sha256 = observation.sha256Hex(response);
    const reason_sha256 = observation.sha256Hex(result.reason);
    const source = WireRun{
        .session_id = prepared.observation.session_id.asSlice(),
        .run_id = prepared.observation.run_id.asSlice(),
        .first_sequence = prepared.observation.first_sequence,
        .last_sequence = prepared.observation.last_sequence,
        .interval_sha256 = prepared.interval_sha256[0..],
    };
    const record_json = switch (prepared.protocol) {
        .v1 => blk: {
            const body = ReceiptBody{
                .project_sha256 = prepared.project_sha256[0..],
                .author_sha256 = prepared.author_sha256[0..],
                .provider_sha256 = prepared.provider_sha256[0..],
                .budget_authorization_sha256 = prepared.budget_authorization_sha256[0..],
                .model = prepared.model,
                .model_sha256 = prepared.model_sha256[0..],
                .system_prompt_sha256 = prepared.system_prompt_sha256[0..],
                .packet_sha256 = prepared.packet_sha256[0..],
                .response_sha256 = response_sha256[0..],
                .source = source,
                .trigger = prepared.trigger,
                .prepared_sha256 = permit.prepared_sha256[0..],
                .authorization_sha256 = permit.authorization_sha256[0..],
                .authorized_at_ns = permit.authorized_at_ns,
                .cooldown_ns = permit.cooldown_ns,
                .request_id = request_id[0..],
                .caps = prepared.caps,
                .pricing = prepared.pricing,
                .usage = result.usage,
                .provider_elapsed_ns = result.provider_elapsed_ns,
                .decision = result.decision,
                .reason_sha256 = reason_sha256[0..],
                .proposal = proposal,
            };
            const body_json = try std.json.Stringify.valueAlloc(std.heap.c_allocator, body, .{});
            defer std.heap.c_allocator.free(body_json);
            const receipt_id = observation.sha256Hex(body_json);
            break :blk try std.json.Stringify.valueAlloc(
                std.heap.c_allocator,
                ReceiptRecord{ .receipt_id = receipt_id[0..], .body = body },
                .{},
            );
        },
        .v2 => |binding| blk: {
            const body = ReceiptBodyV2{
                .project_sha256 = prepared.project_sha256[0..],
                .author_sha256 = prepared.author_sha256[0..],
                .provider_sha256 = prepared.provider_sha256[0..],
                .budget_authorization_sha256 = prepared.budget_authorization_sha256[0..],
                .model = prepared.model,
                .model_sha256 = prepared.model_sha256[0..],
                .system_prompt_sha256 = prepared.system_prompt_sha256[0..],
                .packet_sha256 = prepared.packet_sha256[0..],
                .response_sha256 = response_sha256[0..],
                .source = source,
                .trigger = prepared.trigger,
                .prepared_sha256 = permit.prepared_sha256[0..],
                .authorization_sha256 = permit.authorization_sha256[0..],
                .authorized_at_ns = permit.authorized_at_ns,
                .cooldown_ns = permit.cooldown_ns,
                .request_id = request_id[0..],
                .caps = prepared.caps,
                .pricing = prepared.pricing,
                .usage = result.usage,
                .provider_elapsed_ns = result.provider_elapsed_ns,
                .decision = result.decision,
                .reason_sha256 = reason_sha256[0..],
                .proposal = proposal,
                .ontology_projection = wireProjectionIdentity(&binding),
            };
            const body_json = try std.json.Stringify.valueAlloc(std.heap.c_allocator, body, .{});
            defer std.heap.c_allocator.free(body_json);
            const receipt_id = observation.sha256Hex(body_json);
            break :blk try std.json.Stringify.valueAlloc(
                std.heap.c_allocator,
                ReceiptRecordV2{ .receipt_id = receipt_id[0..], .body = body },
                .{},
            );
        },
    };
    defer std.heap.c_allocator.free(record_json);
    if (record_json.len + 1 > MAX_RECEIPT_BYTES) return error.ReceiptTooLarge;

    // Extract the content-addressed id from the already canonical record. This
    // is not a trust decision; loadReceipt() will strictly parse and rehash it.
    var id_arena = std.heap.ArenaAllocator.init(std.heap.c_allocator);
    defer id_arena.deinit();
    const id_probe = std.json.parseFromSliceLeaky(struct { receipt_id: []const u8 }, id_arena.allocator(), record_json, .{
        .ignore_unknown_fields = true,
        .duplicate_field_behavior = .@"error",
    }) catch return error.InvalidAuthorReceipt;
    const receipt_id = parseHex(id_probe.receipt_id) orelse return error.InvalidAuthorReceipt;

    var path_buffer: [std.fs.max_path_bytes + 1]u8 = undefined;
    const path = try std.fmt.bufPrint(
        &path_buffer,
        "{s}/{s}{s}.json\x00",
        .{ session_dir, RECEIPT_FILE_PREFIX, receipt_id[0..] },
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
        try writeAll(write_fd, record_json);
        try writeAll(write_fd, "\n");
        try pfs.fsyncChecked(write_fd);
        _ = pfs.close(write_fd);
        write_fd = -1;
        try fsyncDirectory(session_dir);
        return receipt_id;
    }
    const existing = try readReceiptFile(std.heap.c_allocator, @ptrCast(path.ptr));
    defer std.heap.c_allocator.free(existing);
    if (existing.len != record_json.len + 1 or
        !std.mem.eql(u8, existing[0..record_json.len], record_json) or
        existing[record_json.len] != '\n')
        return error.ReceiptCollision;
    return receipt_id;
}

pub fn loadReceipt(
    allocator: std.mem.Allocator,
    session_dir: []const u8,
    receipt_id: [64]u8,
) !LoadedReceipt {
    try validateIdentity(receipt_id);
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    const path = try std.fmt.allocPrint(
        a,
        "{s}/{s}{s}.json",
        .{ session_dir, RECEIPT_FILE_PREFIX, receipt_id[0..] },
    );
    const path_z = try a.dupeZ(u8, path);
    const raw = try readReceiptFile(a, path_z.ptr);
    if (raw.len < 2 or raw[raw.len - 1] != '\n') return error.InvalidAuthorReceipt;
    const record_bytes = raw[0 .. raw.len - 1];
    const probe = std.json.parseFromSliceLeaky(ReceiptSchemaProbe, a, record_bytes, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidAuthorReceipt,
    };
    if (std.mem.eql(u8, probe.body.schema_version, RECEIPT_SCHEMA_VERSION)) {
        const record = std.json.parseFromSliceLeaky(ReceiptRecord, a, record_bytes, .{
            .ignore_unknown_fields = false,
            .allocate = .alloc_always,
            .duplicate_field_behavior = .@"error",
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidAuthorReceipt,
        };
        return validateLoadedReceipt(allocator, session_dir, &arena, receipt_id, record, .v1);
    }
    if (std.mem.eql(u8, probe.body.schema_version, RECEIPT_SCHEMA_VERSION_V2)) {
        const record = std.json.parseFromSliceLeaky(ReceiptRecordV2, a, record_bytes, .{
            .ignore_unknown_fields = false,
            .allocate = .alloc_always,
            .duplicate_field_behavior = .@"error",
        }) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidAuthorReceipt,
        };
        const binding = parseProjectionBinding(record.body.ontology_projection) orelse
            return error.InvalidAuthorReceipt;
        return validateLoadedReceipt(allocator, session_dir, &arena, receipt_id, record, .{ .v2 = binding });
    }
    return error.InvalidAuthorReceipt;
}

fn parseProjectionBinding(value: WireProjectionIdentity) ?ProjectionBinding {
    return .{
        .receipt_id = parseHex(value.receipt_id) orelse return null,
        .packet_sha256 = parseHex(value.packet_sha256) orelse return null,
        .ontology_revision = parseHex(value.ontology_revision) orelse return null,
        .ontology_snapshot_sha256 = parseHex(value.ontology_snapshot_sha256) orelse return null,
        .active_bundle_revision = value.active_bundle_revision,
        .active_bundle_sha256 = parseHex(value.active_bundle_sha256) orelse return null,
        .generation_evidence_sha256 = parseHex(value.generation_evidence_sha256) orelse return null,
        .held_out_commitments_sha256 = parseHex(value.held_out_commitments_sha256) orelse return null,
    };
}

fn validateLoadedReceipt(
    allocator: std.mem.Allocator,
    session_dir: []const u8,
    arena: *std.heap.ArenaAllocator,
    receipt_id: [64]u8,
    record: anytype,
    protocol: Protocol,
) !LoadedReceipt {
    const a = arena.allocator();
    const parsed_id = parseHex(record.receipt_id) orelse return error.InvalidAuthorReceipt;
    const project = parseHex(record.body.project_sha256) orelse return error.InvalidAuthorReceipt;
    const author_sha256 = parseHex(record.body.author_sha256) orelse return error.InvalidAuthorReceipt;
    const provider_sha256 = parseHex(record.body.provider_sha256) orelse return error.InvalidAuthorReceipt;
    const budget_authorization_sha256 = parseHex(record.body.budget_authorization_sha256) orelse
        return error.InvalidAuthorReceipt;
    const model_sha256 = parseHex(record.body.model_sha256) orelse return error.InvalidAuthorReceipt;
    const prompt_sha256 = parseHex(record.body.system_prompt_sha256) orelse return error.InvalidAuthorReceipt;
    const packet_sha256 = parseHex(record.body.packet_sha256) orelse return error.InvalidAuthorReceipt;
    const response_sha256 = parseHex(record.body.response_sha256) orelse return error.InvalidAuthorReceipt;
    const interval_sha256 = parseHex(record.body.source.interval_sha256) orelse
        return error.InvalidAuthorReceipt;
    const prepared_sha256 = parseHex(record.body.prepared_sha256) orelse
        return error.InvalidAuthorReceipt;
    const authorization_sha256 = parseHex(record.body.authorization_sha256) orelse
        return error.InvalidAuthorReceipt;
    const reason_sha256 = parseHex(record.body.reason_sha256) orelse return error.InvalidAuthorReceipt;
    const session_id = @import("session_id.zig").SessionId.fromSlice(record.body.source.session_id) orelse
        return error.InvalidAuthorReceipt;
    const run_id = @import("session_id.zig").SessionId.fromSlice(record.body.source.run_id) orelse
        return error.InvalidAuthorReceipt;
    const expected_schema = switch (protocol) {
        .v1 => RECEIPT_SCHEMA_VERSION,
        .v2 => RECEIPT_SCHEMA_VERSION_V2,
    };
    if (!std.mem.eql(u8, record.body.schema_version, expected_schema) or
        !std.mem.eql(u8, &parsed_id, &receipt_id) or
        record.body.source.first_sequence > record.body.source.last_sequence or
        !validText(record.body.model, MAX_MODEL_BYTES) or
        !std.mem.eql(u8, &model_sha256, &observation.sha256Hex(record.body.model)) or
        !validText(record.body.request_id, 64))
        return error.InvalidAuthorReceipt;
    try validateCaps(record.body.caps);
    try validatePricing(record.body.pricing);
    if (record.body.caps.max_cost_microusd < try worstCaseCost(
        record.body.caps,
        record.body.pricing,
    )) return error.InvalidAuthorReceipt;
    if (!std.mem.eql(u8, &prompt_sha256, &systemPromptSha256For(protocol)))
        return error.InvalidAuthorReceipt;
    const reconstructed_prepared_json = switch (protocol) {
        .v1 => try std.json.Stringify.valueAlloc(a, PreparedIdentity{
            .project_sha256 = record.body.project_sha256,
            .author_sha256 = record.body.author_sha256,
            .provider_sha256 = record.body.provider_sha256,
            .budget_authorization_sha256 = record.body.budget_authorization_sha256,
            .model_sha256 = record.body.model_sha256,
            .system_prompt_sha256 = record.body.system_prompt_sha256,
            .packet_sha256 = record.body.packet_sha256,
            .interval_sha256 = record.body.source.interval_sha256,
            .trigger = record.body.trigger,
            .max_cost_microusd = record.body.caps.max_cost_microusd,
            .max_input_tokens = record.body.caps.max_input_tokens,
            .max_output_tokens = record.body.caps.max_output_tokens,
            .pricing_provenance_sha256 = record.body.pricing.provenance_sha256[0..],
            .input_microusd_per_mtok = record.body.pricing.input_microusd_per_mtok,
            .output_microusd_per_mtok = record.body.pricing.output_microusd_per_mtok,
            .cache_read_microusd_per_mtok = record.body.pricing.cache_read_microusd_per_mtok,
            .cache_write_microusd_per_mtok = record.body.pricing.cache_write_microusd_per_mtok,
        }, .{}),
        .v2 => |binding| try std.json.Stringify.valueAlloc(a, PreparedIdentityV2{
            .project_sha256 = record.body.project_sha256,
            .author_sha256 = record.body.author_sha256,
            .provider_sha256 = record.body.provider_sha256,
            .budget_authorization_sha256 = record.body.budget_authorization_sha256,
            .model_sha256 = record.body.model_sha256,
            .system_prompt_sha256 = record.body.system_prompt_sha256,
            .packet_sha256 = record.body.packet_sha256,
            .interval_sha256 = record.body.source.interval_sha256,
            .trigger = record.body.trigger,
            .max_cost_microusd = record.body.caps.max_cost_microusd,
            .max_input_tokens = record.body.caps.max_input_tokens,
            .max_output_tokens = record.body.caps.max_output_tokens,
            .pricing_provenance_sha256 = record.body.pricing.provenance_sha256[0..],
            .input_microusd_per_mtok = record.body.pricing.input_microusd_per_mtok,
            .output_microusd_per_mtok = record.body.pricing.output_microusd_per_mtok,
            .cache_read_microusd_per_mtok = record.body.pricing.cache_read_microusd_per_mtok,
            .cache_write_microusd_per_mtok = record.body.pricing.cache_write_microusd_per_mtok,
            .ontology_projection = wireProjectionIdentity(&binding),
        }, .{}),
    };
    if (!std.mem.eql(
        u8,
        &prepared_sha256,
        &observation.sha256Hex(reconstructed_prepared_json),
    )) return error.InvalidAuthorReceipt;
    const reconstructed_permit = PermitBody{
        .prepared_sha256 = prepared_sha256[0..],
        .authorized_at_ns = record.body.authorized_at_ns,
        .cooldown_ns = record.body.cooldown_ns,
        .max_cost_microusd = record.body.caps.max_cost_microusd,
        .max_input_tokens = record.body.caps.max_input_tokens,
        .max_output_tokens = record.body.caps.max_output_tokens,
    };
    const reconstructed_permit_json = try std.json.Stringify.valueAlloc(
        a,
        reconstructed_permit,
        .{},
    );
    if (!std.mem.eql(
        u8,
        &authorization_sha256,
        &observation.sha256Hex(reconstructed_permit_json),
    )) return error.InvalidAuthorReceipt;
    const body_json = try std.json.Stringify.valueAlloc(a, record.body, .{});
    const expected_id = observation.sha256Hex(body_json);
    if (!std.mem.eql(u8, &expected_id, &receipt_id))
        return error.AuthorReceiptHashMismatch;

    var invariant_sha256: ?[64]u8 = null;
    var falsifier_sha256: ?[64]u8 = null;
    var rule_spec_sha256: ?[64]u8 = null;
    var lean_source_sha256: ?[64]u8 = null;
    if (record.body.proposal) |value| {
        invariant_sha256 = parseHex(value.invariant_sha256) orelse return error.InvalidAuthorReceipt;
        falsifier_sha256 = parseHex(value.falsifier_sha256) orelse return error.InvalidAuthorReceipt;
        rule_spec_sha256 = parseHex(value.rule_spec_sha256) orelse return error.InvalidAuthorReceipt;
        lean_source_sha256 = parseHex(value.lean_source_sha256) orelse return error.InvalidAuthorReceipt;
    }
    if ((record.body.decision == .propose) != (record.body.proposal != null))
        return error.InvalidAuthorReceipt;
    switch (protocol) {
        .v1 => {},
        .v2 => |binding| {
            var loaded_projection = try reopenProjectionBinding(
                allocator,
                session_dir,
                project,
                binding,
            );
            loaded_projection.deinit();
        },
    }
    return .{
        .arena = arena.*,
        .receipt_id = receipt_id,
        .project_sha256 = project,
        .author_sha256 = author_sha256,
        .provider_sha256 = provider_sha256,
        .budget_authorization_sha256 = budget_authorization_sha256,
        .model_sha256 = model_sha256,
        .system_prompt_sha256 = prompt_sha256,
        .packet_sha256 = packet_sha256,
        .response_sha256 = response_sha256,
        .observation = .{
            .session_id = session_id,
            .run_id = run_id,
            .first_sequence = record.body.source.first_sequence,
            .last_sequence = record.body.source.last_sequence,
        },
        .interval_sha256 = interval_sha256,
        .trigger = record.body.trigger,
        .prepared_sha256 = prepared_sha256,
        .authorization_sha256 = authorization_sha256,
        .authorized_at_ns = record.body.authorized_at_ns,
        .cooldown_ns = record.body.cooldown_ns,
        .caps = record.body.caps,
        .pricing = record.body.pricing,
        .usage = record.body.usage,
        .provider_elapsed_ns = record.body.provider_elapsed_ns,
        .decision = record.body.decision,
        .reason_sha256 = reason_sha256,
        .invariant_sha256 = invariant_sha256,
        .falsifier_sha256 = falsifier_sha256,
        .rule_spec_sha256 = rule_spec_sha256,
        .lean_source_sha256 = lean_source_sha256,
        .protocol = protocol,
    };
}

/// Persist the non-authorizing RuleCandidate only after reopening the author
/// receipt.  This does not build, audit, replay, promote, or activate a rule.
pub fn persistCandidate(
    allocator: std.mem.Allocator,
    session_dir: []const u8,
    result: *const AuthorResult,
) !rule_candidate.PersistResult {
    const proposal = result.proposal orelse return error.AuthorAbstained;
    var receipt = try loadReceipt(allocator, session_dir, result.receipt_id);
    defer receipt.deinit();
    if (!try receiptMatchesResult(allocator, &receipt, result))
        return error.AuthorReceiptResultMismatch;
    const persisted = try rule_candidate.persist(session_dir, .{
        .project_sha256 = result.project_sha256,
        // Independence checks must compare actor identities, not artifact
        // identities.  The immutable author receipt is bound separately by
        // the `rule_author` source; using its content hash as the proposer
        // would let the same author appear independent from its own build,
        // audit, replay, shadow, or promotion actor identity.
        .proposer_sha256 = receipt.author_sha256,
        .invariant = proposal.invariant,
        .rule_spec = proposal.rule_spec,
        .lean_source = proposal.lean_source,
        .source = .{ .rule_author = .{
            .receipt_id = result.receipt_id,
            .observation = result.observation,
            .falsifier = proposal.falsifier,
        } },
    });
    if (!try verifyCandidateBinding(
        allocator,
        session_dir,
        result.receipt_id,
        persisted.candidate_id,
    )) return error.AuthorCandidateBindingMismatch;
    return persisted;
}

fn receiptMatchesResult(
    allocator: std.mem.Allocator,
    receipt: *const LoadedReceipt,
    result: *const AuthorResult,
) !bool {
    if (!std.mem.eql(u8, &receipt.receipt_id, &result.receipt_id) or
        !std.mem.eql(u8, &receipt.project_sha256, &result.project_sha256) or
        !std.meta.eql(receipt.observation, result.observation) or
        !std.mem.eql(u8, &receipt.interval_sha256, &result.interval_sha256) or
        receipt.decision != result.decision or
        !std.meta.eql(receipt.usage, result.usage) or
        receipt.provider_elapsed_ns != result.provider_elapsed_ns or
        !std.meta.eql(receipt.protocol, result.protocol) or
        !std.mem.eql(u8, &receipt.reason_sha256, &observation.sha256Hex(result.reason)))
        return false;
    const proposal = result.proposal orelse return receipt.decision == .abstain;
    if (receipt.invariant_sha256 == null or receipt.falsifier_sha256 == null or
        receipt.rule_spec_sha256 == null or receipt.lean_source_sha256 == null)
        return false;
    const rule_spec_json = try project_rule_spec.renderCanonical(allocator, proposal.rule_spec);
    defer allocator.free(rule_spec_json);
    return std.mem.eql(u8, &receipt.invariant_sha256.?, &observation.sha256Hex(proposal.invariant)) and
        std.mem.eql(u8, &receipt.falsifier_sha256.?, &observation.sha256Hex(proposal.falsifier)) and
        std.mem.eql(u8, &receipt.rule_spec_sha256.?, &observation.sha256Hex(rule_spec_json)) and
        std.mem.eql(u8, &receipt.lean_source_sha256.?, &observation.sha256Hex(proposal.lean_source));
}

/// Reopen both immutable artifacts and compare every response-derived field.
/// Promotion callers can invoke this before accepting lifecycle evidence; the
/// existing lifecycle schema itself is intentionally unchanged in this slice.
pub fn verifyCandidateBinding(
    allocator: std.mem.Allocator,
    session_dir: []const u8,
    receipt_id: [64]u8,
    candidate_id: [64]u8,
) !bool {
    var receipt = try loadReceipt(allocator, session_dir, receipt_id);
    defer receipt.deinit();
    if (receipt.decision != .propose or receipt.invariant_sha256 == null or
        receipt.falsifier_sha256 == null or receipt.rule_spec_sha256 == null or
        receipt.lean_source_sha256 == null)
        return false;
    var candidate = try rule_candidate.load(allocator, session_dir, candidate_id);
    defer candidate.deinit();
    const rule_spec_json = try project_rule_spec.renderCanonical(allocator, candidate.rule_spec);
    defer allocator.free(rule_spec_json);
    return std.mem.eql(u8, &candidate.project_sha256, &receipt.project_sha256) and
        std.mem.eql(u8, &candidate.proposer_sha256, &receipt.author_sha256) and
        candidate.source_kind == .rule_author and
        candidate.source_receipt_id != null and
        std.mem.eql(u8, &candidate.source_receipt_id.?, &receipt.receipt_id) and
        candidate.source_observation != null and
        std.meta.eql(candidate.source_observation.?, receipt.observation) and
        candidate.source_interval_sha256 != null and
        std.mem.eql(u8, &candidate.source_interval_sha256.?, &receipt.interval_sha256) and
        candidate.source_falsifier_sha256 != null and
        std.mem.eql(u8, &candidate.source_falsifier_sha256.?, &receipt.falsifier_sha256.?) and
        std.mem.eql(u8, &candidate.invariant_sha256, &receipt.invariant_sha256.?) and
        std.mem.eql(u8, &candidate.lean_source_sha256, &receipt.lean_source_sha256.?) and
        std.mem.eql(u8, &observation.sha256Hex(rule_spec_json), &receipt.rule_spec_sha256.?) and
        try candidate.sourceEvidenceIsBound(session_dir);
}

fn readReceiptFile(allocator: std.mem.Allocator, path: [*:0]const u8) ![]u8 {
    const fd = pfs.open(path, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true }, 0);
    if (fd < 0) return error.OpenFailed;
    defer _ = pfs.close(fd);
    const before = pfs.fileInfo(fd) catch return error.StatFailed;
    if (!before.is_regular or before.link_count != 1 or before.size == 0 or
        before.size > MAX_RECEIPT_BYTES)
        return error.InvalidAuthorReceiptFile;
    const bytes = try allocator.alloc(u8, @intCast(before.size));
    errdefer allocator.free(bytes);
    var offset: usize = 0;
    while (offset < bytes.len) {
        const count = pfs.read(fd, bytes[offset..]);
        if (count <= 0) return error.ReadFailed;
        offset += @intCast(count);
    }
    const after = pfs.fileInfo(fd) catch return error.StatFailed;
    if (!after.is_regular or after.link_count != 1 or after.size != before.size)
        return error.ChangedDuringRead;
    return bytes;
}

fn writeAll(fd: pfs.Fd, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const count = pfs.write(fd, bytes[offset..]);
        if (count <= 0) return error.WriteFailed;
        offset += @intCast(count);
    }
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

fn elapsedNs(start: i128) u64 {
    const elapsed = time.nowNs() - start;
    return if (elapsed <= 0) 0 else @intCast(@min(elapsed, std.math.maxInt(u64)));
}

test "rule author gate is fail-closed and binds request identity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var prepared = PreparedRequest{
        .arena = arena,
        .project_sha256 = .{'a'} ** 64,
        .author_sha256 = .{'b'} ** 64,
        .provider_sha256 = .{'c'} ** 64,
        .budget_authorization_sha256 = .{'8'} ** 64,
        .model = "author-model",
        .model_sha256 = observation.sha256Hex("author-model"),
        .system_prompt_sha256 = systemPromptSha256(),
        .observation = undefined,
        .interval_sha256 = .{'d'} ** 64,
        .trigger = .user_correction,
        .packet = "{}",
        .packet_sha256 = observation.sha256Hex("{}"),
        .caps = .{ .max_cost_microusd = 1000, .max_input_tokens = 10000, .max_output_tokens = 8192 },
        .pricing = .{
            .provenance_sha256 = .{'9'} ** 64,
            .input_microusd_per_mtok = 1,
            .output_microusd_per_mtok = 1,
            .cache_read_microusd_per_mtok = 1,
            .cache_write_microusd_per_mtok = 1,
        },
    };
    try std.testing.expectError(error.AuthoringDisabled, authorize(&prepared, .{
        .now_ns = 100,
        .cooldown_ns = 10,
        .remaining_requests = 1,
        .remaining_cost_microusd = 1000,
        .remaining_input_tokens = 10000,
        .remaining_output_tokens = 8192,
    }));
    const permit = try authorize(&prepared, .{
        .enabled = true,
        .now_ns = 100,
        .last_authorized_ns = 80,
        .cooldown_ns = 10,
        .remaining_requests = 1,
        .remaining_cost_microusd = 1000,
        .remaining_input_tokens = 10000,
        .remaining_output_tokens = 8192,
    });
    try validatePermit(&prepared, permit);
    prepared.packet_sha256 = .{'e'} ** 64;
    try std.testing.expectError(error.PreparedRequestDrift, validatePermit(&prepared, permit));
}

test "v1 rule author prompt remains byte-compatible for cache and old receipts" {
    try std.testing.expectEqualStrings(
        "9e6affe7ae9548a90f9d52fc537956f334e3730828b80d512cc2f8ba8b063514",
        &systemPromptSha256(),
    );
    try std.testing.expectEqualStrings(SYSTEM_PROMPT, systemPrompt(.v1));
}

test "canonical Lean is deterministic and carries the full RuleSpec v3" {
    const source = try renderCanonicalLean(std.testing.allocator, .{
        .target = .{ .tool = "Write" },
        .target_scope = .existing_file,
        .deny_target = true,
        .max_input_bytes = 8192,
        .max_agent_depth = 4,
        .authoritative_only = true,
        .effect_requirement = .none,
    });
    defer std.testing.allocator.free(source);
    try std.testing.expectEqualStrings(
        "def spec : RuleSpec := { target := .tool \"Write\", targetScope := .existingFile, denyTarget := true, maxInputBytes := 8192, maxAgentDepth := 4, authoritativeOnly := true, effectRequirement := .none }\ntheorem spec_valid : valid spec = true := by rfl",
        source,
    );
}

test "rule author response parser rejects unknown and duplicate fields" {
    const valid =
        "{\"schema_version\":\"metacodes-rule-author-response-v1\",\"decision\":\"abstain\",\"reason\":\"insufficient evidence\",\"invariant\":null,\"falsifier\":null,\"rule_spec\":null,\"lean_source\":null}";
    var parsed = try parseResponse(std.testing.allocator, valid);
    parsed.deinit();
    const unknown =
        "{\"schema_version\":\"metacodes-rule-author-response-v1\",\"decision\":\"abstain\",\"reason\":\"insufficient evidence\",\"invariant\":null,\"falsifier\":null,\"rule_spec\":null,\"lean_source\":null,\"extra\":true}";
    try std.testing.expectError(
        error.InvalidAuthorResponse,
        parseResponse(std.testing.allocator, unknown),
    );
    const duplicate =
        "{\"schema_version\":\"metacodes-rule-author-response-v1\",\"decision\":\"abstain\",\"decision\":\"propose\",\"reason\":\"insufficient evidence\",\"invariant\":null,\"falsifier\":null,\"rule_spec\":null,\"lean_source\":null}";
    try std.testing.expectError(
        error.InvalidAuthorResponse,
        parseResponse(std.testing.allocator, duplicate),
    );
}

test "rule author response parser strips one markdown fence layer" {
    const body =
        "{\"schema_version\":\"metacodes-rule-author-response-v1\",\"decision\":\"abstain\",\"reason\":\"insufficient evidence\",\"invariant\":null,\"falsifier\":null,\"rule_spec\":null,\"lean_source\":null}";
    const fenced = "```json\n" ++ body ++ "\n```";
    var parsed = try parseResponse(std.testing.allocator, fenced);
    parsed.deinit();
    // 无语言标注的 fence 同样容忍。
    const bare_fence = "```\n" ++ body ++ "\n```\n";
    var parsed2 = try parseResponse(std.testing.allocator, bare_fence);
    parsed2.deinit();
    // fence 内不是合法响应仍然拒绝——剥壳不放宽内容校验。
    try std.testing.expectError(
        error.InvalidAuthorResponse,
        parseResponse(std.testing.allocator, "```json\n{\"nope\":1}\n```"),
    );
}

test "worst-case author cost uses integer ceiling and the most expensive input class" {
    const pricing = PricingAuthority{
        .provenance_sha256 = .{'9'} ** 64,
        .input_microusd_per_mtok = 3_000_000,
        .output_microusd_per_mtok = 15_000_000,
        .cache_read_microusd_per_mtok = 300_000,
        .cache_write_microusd_per_mtok = 3_750_000,
    };
    try std.testing.expectEqual(@as(u64, 19), try worstCaseCost(.{
        .max_cost_microusd = 19,
        .max_input_tokens = 1,
        .max_output_tokens = 1,
    }, pricing));
    try std.testing.expectEqual(@as(u64, 378_840), try worstCaseCost(.{
        .max_cost_microusd = 378_840,
        .max_input_tokens = 100_000,
        .max_output_tokens = 256,
    }, pricing));
}
