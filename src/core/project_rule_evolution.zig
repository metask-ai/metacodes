//! Governed TinyKG ontology -> project Lean candidate orchestration.
//!
//! The product boundary is intentionally explicit and two-phase. `prepare`
//! performs no provider request: it verifies a completed Run/trigger, replays
//! the current active bundle, snapshots TinyKG twice, persists a sanitized
//! ontology projection, and prepares a v2 rule-author request. `authorOnce`
//! is the sole provider side-effect; immediately before and after it, the host
//! re-observes both TinyKG and the active bundle. A proposal already known to
//! be stale therefore neither spends a provider request nor persists a
//! RuleCandidate. The inert candidate remains versioned evidence rather than
//! authority; later lifecycle/promotion must still reopen its source.
//!
//! This module receives neither actor Conversation nor actor provider. It
//! therefore cannot perturb the cacheable actor prefix, tool ordering, or
//! context management. Scheduling, budget-journal durability, later isolated
//! build/replay/shadow/promotion, and TinyKG mutation remain separate owners.

const std = @import("std");
const kg_client = @import("../kg/client.zig");
const ontology_adapter = @import("../kg/ontology_rule_snapshot_adapter.zig");
const ontology_projection = @import("ontology_rule_projection.zig");
const rule_author = @import("rule_author.zig");
const rule_candidate = @import("rule_candidate.zig");
const rule_impact_stats = @import("rule_impact_stats.zig");
const journal = @import("tool_observation_journal.zig");
const bundle = @import("project_rule_bundle.zig");
const kernel = @import("../formal/project_harness_runtime.zig");
const AbortSignal = @import("../util/abort.zig").AbortSignal;

const ZERO_SHA = [_]u8{'0'} ** 64;

pub const PrepareInput = struct {
    session_dir: []const u8,
    project_root: []const u8,
    project_rules_dir: []const u8,
    ontology_source: ProjectOntologySource,
    /// Required only when an active bundle exists. Its executable/hash are
    /// replayed before and after authoring; absence never weakens an active
    /// configuration into an unverified identity.
    kernel_config: ?kernel.Config = null,

    author_sha256: [64]u8,
    /// Host-attested actor provider identity. Comparing it with the author
    /// identity prevents an accidental same-role configuration, but this raw
    /// digest is not itself proof that endpoint or credential provenance was
    /// independently derived. The provider factory owns that stronger claim.
    actor_provider_sha256: [64]u8,
    provider_sha256: [64]u8,
    budget_authorization_sha256: [64]u8,
    model: []const u8,
    observation: journal.RunBinding,
    labels: rule_impact_stats.RunLabels = .{},
    trigger: rule_author.Trigger,
    evidence: []const rule_author.EvidenceItem,
    caps: rule_author.CallCaps,
    pricing: rule_author.PricingAuthority,
    generation_evidence: []const ontology_projection.GenerationEvidence,
    held_out_commitments: []const ontology_projection.HeldOutCommitment,
};

pub const ActiveBinding = struct {
    bundle_revision: u64,
    bundle_sha256: [64]u8,
};

/// Narrow read-only source required by rule evolution.  Production binds all
/// three operations to one KgClient/local daemon; tests can inject canonical
/// snapshots without inventing a second TinyKG implementation. The source is
/// borrowed and must outlive Prepared.
pub const ProjectOntologySource = struct {
    ptr: *anyopaque,
    project_node_id_fn: *const fn (*anyopaque) anyerror!?u64,
    project_key_fn: *const fn (*anyopaque) []const u8,
    read_transport_fn: *const fn (*anyopaque) ontology_adapter.ReadTransport,

    pub fn reobserveProjectNodeId(self: ProjectOntologySource) !?u64 {
        return self.project_node_id_fn(self.ptr);
    }

    pub fn projectKey(self: ProjectOntologySource) []const u8 {
        return self.project_key_fn(self.ptr);
    }

    pub fn readTransport(self: ProjectOntologySource) ontology_adapter.ReadTransport {
        return self.read_transport_fn(self.ptr);
    }
};

/// Production binding: project lookup, key and canonical snapshot all come
/// from the same KgClient transport/store identity.
pub const KgClientSource = struct {
    client: *kg_client.KgClient,
    transport_adapter: ontology_adapter.KgClientTransport,

    pub fn init(client: *kg_client.KgClient) KgClientSource {
        return .{
            .client = client,
            .transport_adapter = .{ .client = client },
        };
    }

    pub fn source(self: *KgClientSource) ProjectOntologySource {
        return .{
            .ptr = self,
            .project_node_id_fn = projectNodeId,
            .project_key_fn = projectKey,
            .read_transport_fn = readTransport,
        };
    }

    fn cast(ptr: *anyopaque) *KgClientSource {
        return @ptrCast(@alignCast(ptr));
    }

    fn projectNodeId(ptr: *anyopaque) !?u64 {
        return cast(ptr).client.reobserveExistingProjectNodeId();
    }

    fn projectKey(ptr: *anyopaque) []const u8 {
        return cast(ptr).client.projectKey();
    }

    fn readTransport(ptr: *anyopaque) ontology_adapter.ReadTransport {
        return cast(ptr).transport_adapter.transport();
    }
};

pub const Prepared = struct {
    allocator: std.mem.Allocator,
    session_dir: []u8,
    project_rules_dir: []u8,
    ontology_source: ProjectOntologySource,
    kernel_path: ?[]u8,
    kernel_config: ?kernel.Config,
    active: ActiveBinding,
    ontology: ontology_adapter.Prepared,
    projection_receipt: ontology_adapter.Result,
    author_request: rule_author.PreparedRequest,
    author_attempted: bool = false,

    pub fn deinit(self: *Prepared) void {
        self.author_request.deinit();
        self.ontology.deinit();
        if (self.kernel_path) |path| self.allocator.free(path);
        self.allocator.free(self.session_dir);
        self.allocator.free(self.project_rules_dir);
        self.* = undefined;
    }

    /// Explicit permit derivation. Callers should normally back this authority
    /// with the durable single-machine paid-evaluation journal; this API does
    /// not claim that an in-memory value proves fsync or crash recovery.
    pub fn authorize(
        self: *const Prepared,
        authority: rule_author.BudgetAuthority,
    ) !rule_author.Permit {
        return rule_author.authorize(&self.author_request, authority);
    }
};

pub const Outcome = struct {
    author_receipt_id: [64]u8,
    decision: rule_author.Decision,
    candidate_id: ?[64]u8,
    candidate_created: bool,
    usage: rule_author.Usage,
    provider_elapsed_ns: u64,
    // 义务提案按值携带(authored 的 arena 在 authorOnce 内就释放;
    // 上限来自 self_evolution 的信封边界)。
    obligation_needle_buffer: [160]u8 = undefined,
    obligation_needle_len: usize = 0,
    obligation_reason_buffer: [300]u8 = undefined,
    obligation_reason_len: usize = 0,

    pub fn obligationNeedle(self: *const Outcome) ?[]const u8 {
        if (self.obligation_needle_len == 0) return null;
        return self.obligation_needle_buffer[0..self.obligation_needle_len];
    }
    pub fn obligationReason(self: *const Outcome) ?[]const u8 {
        if (self.obligation_reason_len == 0) return null;
        return self.obligation_reason_buffer[0..self.obligation_reason_len];
    }
};

/// Prepare the complete provider-free half of one evolution attempt.
pub fn prepare(
    allocator: std.mem.Allocator,
    input: PrepareInput,
) !Prepared {
    if (!std.fs.path.isAbsolute(input.session_dir) or
        !std.fs.path.isAbsolute(input.project_root) or
        !std.fs.path.isAbsolute(input.project_rules_dir) or
        input.project_root.len == 0)
        return error.InvalidEvolutionPath;
    if (std.mem.eql(u8, &input.actor_provider_sha256, &input.provider_sha256))
        return error.RuleAuthorProviderNotIndependent;
    const project_sha256 = bundle.projectIdentity(input.project_root);

    // First derive/validate the sparse trigger from the authenticated Run.
    // Ordinary successful Runs stop here: zero TinyKG snapshot and zero
    // provider request. The temporary v1 packet is never persisted or sent.
    var trigger_probe = try rule_author.prepare(allocator, .{
        .session_dir = input.session_dir,
        .project_sha256 = project_sha256,
        .author_sha256 = input.author_sha256,
        .provider_sha256 = input.provider_sha256,
        .budget_authorization_sha256 = input.budget_authorization_sha256,
        .model = input.model,
        .observation = input.observation,
        .labels = input.labels,
        .trigger = input.trigger,
        .evidence = input.evidence,
        .caps = input.caps,
        .pricing = input.pricing,
    });
    trigger_probe.deinit();

    var owned_kernel_path: ?[]u8 = null;
    errdefer if (owned_kernel_path) |path| allocator.free(path);
    var owned_kernel_config: ?kernel.Config = null;
    if (input.kernel_config) |config| {
        const path = try allocator.dupe(u8, config.checker_path);
        owned_kernel_path = path;
        owned_kernel_config = .{
            .checker_path = path,
            .expected_sha256 = config.expected_sha256,
            .timeout_ms = config.timeout_ms,
        };
    }
    const active = try observeActive(
        allocator,
        input.project_rules_dir,
        project_sha256,
        owned_kernel_config,
        null,
    );

    const project_node_id = (try input.ontology_source.reobserveProjectNodeId()) orelse
        return error.ProjectOntologyMissing;
    const project_key = input.ontology_source.projectKey();
    if (project_key.len == 0) return error.ProjectOntologyMissing;
    var ontology = try ontology_adapter.prepare(
        allocator,
        input.ontology_source.readTransport(),
        .{
            .project_node_id = project_node_id,
            .project_sha256 = project_sha256,
            .project_key = project_key,
            .active_rules = .{
                .bundle_revision = active.bundle_revision,
                .bundle_sha256 = active.bundle_sha256,
            },
            .generation_evidence = input.generation_evidence,
            .held_out_commitments = input.held_out_commitments,
        },
    );
    errdefer ontology.deinit();
    const projection_receipt = try ontology_adapter.persist(
        allocator,
        input.session_dir,
        &ontology,
    );
    var author_request = try rule_author.prepare(allocator, .{
        .session_dir = input.session_dir,
        .project_sha256 = project_sha256,
        .author_sha256 = input.author_sha256,
        .provider_sha256 = input.provider_sha256,
        .budget_authorization_sha256 = input.budget_authorization_sha256,
        .model = input.model,
        .observation = input.observation,
        .labels = input.labels,
        .trigger = input.trigger,
        .evidence = input.evidence,
        .caps = input.caps,
        .pricing = input.pricing,
        .ontology_projection = .{
            .receipt_id = projection_receipt.receipt_id,
            .ontology_revision = projection_receipt.ontology_revision,
            .ontology_snapshot_sha256 = projection_receipt.ontology_snapshot_sha256,
            .active_bundle_revision = active.bundle_revision,
            .active_bundle_sha256 = active.bundle_sha256,
        },
    });
    errdefer author_request.deinit();
    const rules_dir = try allocator.dupe(u8, input.project_rules_dir);
    errdefer allocator.free(rules_dir);
    const session_dir = try allocator.dupe(u8, input.session_dir);
    errdefer allocator.free(session_dir);

    return .{
        .allocator = allocator,
        .session_dir = session_dir,
        .project_rules_dir = rules_dir,
        .ontology_source = input.ontology_source,
        .kernel_path = owned_kernel_path,
        .kernel_config = owned_kernel_config,
        .active = active,
        .ontology = ontology,
        .projection_receipt = projection_receipt,
        .author_request = author_request,
    };
}

/// Make the only provider request for this Prepared value. A failed or
/// ambiguous call cannot be retried through the same value. Candidate
/// persistence occurs only after post-provider TinyKG and active-bundle
/// re-observation. This is a fail-closed read/verify boundary, not a claim of
/// cross-store atomicity with TinyKG; candidates remain inert until the later
/// lifecycle and promotion gates reopen their evidence.
pub fn authorOnce(
    prepared: *Prepared,
    bound_provider: rule_author.BoundProvider,
    permit: rule_author.Permit,
    abort: ?*const AbortSignal,
) !Outcome {
    if (prepared.author_attempted) return error.AuthorAlreadyAttempted;
    prepared.author_attempted = true;
    // Do not spend a paid call on a proposal whose ontology or active rules
    // changed after prepare. This is deliberately repeated after the call:
    // the first check protects cost, the second protects candidate commit.
    try reobserveBindings(prepared, abort);
    var authored = try rule_author.author(
        prepared.allocator,
        prepared.session_dir,
        bound_provider,
        &prepared.author_request,
        permit,
        abort,
    );
    defer authored.deinit();
    try reobserveBindings(prepared, abort);

    var candidate_id: ?[64]u8 = null;
    var candidate_created = false;
    if (authored.decision == .propose) {
        const candidate = try rule_author.persistCandidate(
            prepared.allocator,
            prepared.session_dir,
            &authored,
        );
        candidate_id = candidate.candidate_id;
        candidate_created = candidate.created;
    }
    var outcome: Outcome = .{
        .author_receipt_id = authored.receipt_id,
        .decision = authored.decision,
        .candidate_id = candidate_id,
        .candidate_created = candidate_created,
        .usage = authored.usage,
        .provider_elapsed_ns = authored.provider_elapsed_ns,
    };
    if (authored.decision == .propose_obligation) {
        const proposal = authored.obligation orelse return error.InvalidAuthorResponse;
        if (proposal.command_needle.len > outcome.obligation_needle_buffer.len or
            proposal.reason.len > outcome.obligation_reason_buffer.len)
            return error.InvalidAuthorResponse;
        @memcpy(outcome.obligation_needle_buffer[0..proposal.command_needle.len], proposal.command_needle);
        outcome.obligation_needle_len = proposal.command_needle.len;
        @memcpy(outcome.obligation_reason_buffer[0..proposal.reason.len], proposal.reason);
        outcome.obligation_reason_len = proposal.reason.len;
    }
    return outcome;
}

fn reobserveBindings(prepared: *Prepared, abort: ?*const AbortSignal) !void {
    const project_node = (try prepared.ontology_source.reobserveProjectNodeId()) orelse
        return error.ProjectOntologyDisappeared;
    if (project_node != prepared.ontology.project_node_id or
        !std.mem.eql(u8, prepared.ontology_source.projectKey(), prepared.ontology.project_key))
        return error.ProjectOntologyIdentityDrift;
    try ontology_adapter.reobservePrepared(
        prepared.allocator,
        prepared.ontology_source.readTransport(),
        &prepared.ontology,
    );
    const expected_active = prepared.active.bundle_revision != 0 or
        !std.mem.eql(u8, &prepared.active.bundle_sha256, &ZERO_SHA);
    if (bundle.hasActive(prepared.project_rules_dir) != expected_active)
        return error.ActiveBundleDrift;
    const active = try observeActive(
        prepared.allocator,
        prepared.project_rules_dir,
        prepared.author_request.project_sha256,
        prepared.kernel_config,
        abort,
    );
    if (!std.meta.eql(active, prepared.active))
        return error.ActiveBundleDrift;
}

fn observeActive(
    allocator: std.mem.Allocator,
    project_rules_dir: []const u8,
    project_sha256: [64]u8,
    config: ?kernel.Config,
    abort: ?*const AbortSignal,
) !ActiveBinding {
    if (!bundle.hasActive(project_rules_dir)) return .{
        .bundle_revision = 0,
        .bundle_sha256 = ZERO_SHA,
    };
    const actual_config = config orelse return error.ActiveKernelConfigurationMissing;
    var active = (try bundle.loadVerifiedActive(
        allocator,
        project_rules_dir,
        project_sha256,
        actual_config,
        abort,
    )) orelse return error.ActivePointerDisappeared;
    defer active.deinit();
    return .{
        .bundle_revision = active.revision,
        .bundle_sha256 = active.bundle_sha256,
    };
}
