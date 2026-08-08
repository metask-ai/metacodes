//! Immutable evidence chain for project-rule build, audit, replay, shadow,
//! rejection, promotion, and supersession.
//!
//! This module validates artifact identity and lifecycle topology.  A
//! promotion record must additionally carry a hash-bound admission from the
//! independent Lean lifecycle checker; the runtime bundle loader re-verifies
//! that verdict before loading.  Receipt creation alone never changes a tool
//! permission or the active project bundle.

const std = @import("std");
const pfs = @import("platform").fs;
const observation = @import("../tools/observation.zig");
const rule_candidate = @import("rule_candidate.zig");
const source_receipt = @import("rule_source_receipt.zig");
const project_rule_spec = @import("project_rule_spec.zig");

pub const SCHEMA_VERSION = "metacodes-rule-stage-receipt-v2";
pub const LEGACY_SCHEMA_VERSION = "metacodes-rule-stage-receipt-v1";
const ZERO_SHA256_TEXT = "0000000000000000000000000000000000000000000000000000000000000000";
pub const FILE_PREFIX = "rule-stage-receipt-";
pub const HEAD_PREFIX = "rule-stage-head-";
pub const LOCK_PREFIX = "rule-stage-lock-";
pub const MAX_RECORD_BYTES: usize = 128 * 1024;

pub const Stage = enum {
    built,
    axiom_audited,
    replay_passed,
    shadow_passed,
    rejected,
    promoted,
    superseded,
};

pub const BuildEvidence = struct {
    manifest_sha256: [64]u8,
    lean_source_sha256: [64]u8,
    rule_spec_sha256: [64]u8,
    compiled_artifact_sha256: [64]u8,
    toolchain_sha256: [64]u8,
    sdk_sha256: [64]u8,
    sdk_olean_sha256: [64]u8,
    build_log_sha256: [64]u8,
    network_disabled: bool,
    secrets_absent: bool,
    source_bounded: bool,
    output_bounded: bool,
    completed: bool,
};

pub const AxiomEvidence = struct {
    audit_sha256: [64]u8,
    policy_sha256: [64]u8,
    forbidden_declaration_count: u32,
    unexpected_axiom_count: u32,
    completed: bool,
};

pub const ReplayEvidence = struct {
    corpus_sha256: [64]u8,
    results_sha256: [64]u8,
    positive_cases: u32,
    negative_cases: u32,
    false_positive_count: u32,
    false_negative_count: u32,
    completed: bool,
};

pub const ShadowEvidence = struct {
    interval_sha256: [64]u8,
    results_sha256: [64]u8,
    observed_decisions: u32,
    divergence_count: u32,
    side_effect_count: u32,
    completed: bool,
};

pub const RejectionEvidence = struct {
    reason_sha256: [64]u8,
    evidence_sha256: [64]u8,
};

pub const PromotionEvidence = struct {
    lifecycle_request_sha256: [64]u8,
    lifecycle_verdict_sha256: [64]u8,
    runtime_kernel_sha256: [64]u8,
    bundle_sha256: [64]u8,
    previous_bundle_sha256: [64]u8,
    bundle_revision: u64,
    checker_admitted: bool,
};

pub const SupersessionEvidence = struct {
    replacement_candidate_id: [64]u8,
    replacement_promotion_receipt_id: [64]u8,
    replacement_bundle_sha256: [64]u8,
};

pub const Evidence = union(Stage) {
    built: BuildEvidence,
    axiom_audited: AxiomEvidence,
    replay_passed: ReplayEvidence,
    shadow_passed: ShadowEvidence,
    rejected: RejectionEvidence,
    promoted: PromotionEvidence,
    superseded: SupersessionEvidence,
};

pub const Input = struct {
    candidate_id: [64]u8,
    project_sha256: [64]u8,
    actor_sha256: [64]u8,
    checker_sha256: [64]u8,
    predecessor_receipt_id: ?[64]u8,
    evidence: Evidence,
};

pub const PersistResult = struct {
    receipt_id: [64]u8,
    stage: Stage,
    created: bool,
};

pub const Loaded = struct {
    arena: std.heap.ArenaAllocator,
    receipt_id: [64]u8,
    candidate_id: [64]u8,
    project_sha256: [64]u8,
    actor_sha256: [64]u8,
    checker_sha256: [64]u8,
    predecessor_receipt_id: ?[64]u8,
    stage: Stage,
    evidence: ParsedEvidence,
    legacy_schema: bool,

    pub fn deinit(self: *Loaded) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const ParsedEvidence = union(Stage) {
    built: BuildEvidence,
    axiom_audited: AxiomEvidence,
    replay_passed: ReplayEvidence,
    shadow_passed: ShadowEvidence,
    rejected: RejectionEvidence,
    promoted: PromotionEvidence,
    superseded: SupersessionEvidence,
};

const WireEvidence = union(Stage) {
    built: struct {
        manifest_sha256: []const u8 = ZERO_SHA256_TEXT,
        lean_source_sha256: []const u8,
        rule_spec_sha256: []const u8 = ZERO_SHA256_TEXT,
        compiled_artifact_sha256: []const u8,
        toolchain_sha256: []const u8,
        sdk_sha256: []const u8,
        sdk_olean_sha256: []const u8 = ZERO_SHA256_TEXT,
        build_log_sha256: []const u8,
        network_disabled: bool,
        secrets_absent: bool,
        source_bounded: bool,
        output_bounded: bool,
        completed: bool,
    },
    axiom_audited: struct {
        audit_sha256: []const u8,
        policy_sha256: []const u8,
        forbidden_declaration_count: u32,
        unexpected_axiom_count: u32,
        completed: bool,
    },
    replay_passed: struct {
        corpus_sha256: []const u8,
        results_sha256: []const u8,
        positive_cases: u32,
        negative_cases: u32,
        false_positive_count: u32,
        false_negative_count: u32,
        completed: bool,
    },
    shadow_passed: struct {
        interval_sha256: []const u8,
        results_sha256: []const u8,
        observed_decisions: u32,
        divergence_count: u32,
        side_effect_count: u32,
        completed: bool,
    },
    rejected: struct {
        reason_sha256: []const u8,
        evidence_sha256: []const u8,
    },
    promoted: struct {
        lifecycle_request_sha256: []const u8,
        lifecycle_verdict_sha256: []const u8,
        runtime_kernel_sha256: []const u8,
        bundle_sha256: []const u8,
        previous_bundle_sha256: []const u8,
        bundle_revision: u64,
        checker_admitted: bool,
    },
    superseded: struct {
        replacement_candidate_id: []const u8,
        replacement_promotion_receipt_id: []const u8,
        replacement_bundle_sha256: []const u8,
    },
};

const WireBody = struct {
    schema_version: []const u8 = SCHEMA_VERSION,
    candidate_id: []const u8,
    project_sha256: []const u8,
    actor_sha256: []const u8,
    checker_sha256: []const u8,
    predecessor_receipt_id: ?[]const u8,
    evidence: WireEvidence,
};

const WireRecord = struct {
    receipt_id: []const u8,
    body: WireBody,
};

const RawRecord = struct {
    receipt_id: []const u8,
    body: struct {
        schema_version: []const u8,
        candidate_id: []const u8,
        project_sha256: []const u8,
        actor_sha256: []const u8,
        checker_sha256: []const u8,
        predecessor_receipt_id: ?[]const u8,
        evidence: WireEvidence,
    },
};

const Head = struct {
    schema_version: []const u8 = "metacodes-rule-stage-head-v1",
    candidate_id: []const u8,
    receipt_id: []const u8,
    stage: Stage,
};

const Lease = struct {
    fd: pfs.Fd,
    path: [std.fs.max_path_bytes + 1]u8,
    path_len: usize,
    released: bool = false,

    fn acquire(session_dir: []const u8, candidate_id: [64]u8) !Lease {
        var path_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
        const path = try std.fmt.bufPrint(
            &path_buf,
            "{s}/{s}{s}\x00",
            .{ session_dir, LOCK_PREFIX, candidate_id[0..] },
        );
        const fd = pfs.open(@ptrCast(path.ptr), .{
            .ACCMODE = .WRONLY,
            .CREAT = true,
            .EXCL = true,
            .NOFOLLOW = true,
        }, @as(std.c.mode_t, 0o600));
        if (fd < 0) return error.LifecycleBusy;
        errdefer _ = pfs.close(fd);
        try pfs.makeCloseOnExec(fd);
        try pfs.fsyncChecked(fd);
        return .{ .fd = fd, .path = path_buf, .path_len = path.len - 1 };
    }

    fn release(self: *Lease) !void {
        if (self.released) return;
        if (self.fd >= 0) _ = pfs.close(self.fd);
        self.fd = -1;
        self.path[self.path_len] = 0;
        try pfs.unlinkPath(@ptrCast(&self.path));
        self.released = true;
    }

    fn closeKeep(self: *Lease) void {
        if (self.fd >= 0) _ = pfs.close(self.fd);
        self.fd = -1;
    }
};

/// Append non-authorizing lifecycle evidence.  Promotion/supersession are
/// deliberately unavailable through this proposal-side API; the later
/// independent Lean admission path owns those two transitions.
pub fn persist(session_dir: []const u8, input: Input) !PersistResult {
    return switch (input.evidence) {
        .promoted, .superseded => error.FormalAdmissionRequired,
        else => persistInternal(session_dir, input),
    };
}

fn persistInternal(session_dir: []const u8, input: Input) !PersistResult {
    try validateIdentities(input);
    var candidate = try rule_candidate.load(std.heap.c_allocator, session_dir, input.candidate_id);
    defer candidate.deinit();
    if (!std.mem.eql(u8, &candidate.project_sha256, &input.project_sha256))
        return error.ProjectIdentityMismatch;

    const wire = wireEvidence(&input.evidence);
    const predecessor_slice: ?[]const u8 = if (input.predecessor_receipt_id) |*id| id[0..] else null;
    const body = WireBody{
        .candidate_id = input.candidate_id[0..],
        .project_sha256 = input.project_sha256[0..],
        .actor_sha256 = input.actor_sha256[0..],
        .checker_sha256 = input.checker_sha256[0..],
        .predecessor_receipt_id = predecessor_slice,
        .evidence = wire,
    };
    const body_json = try std.json.Stringify.valueAlloc(std.heap.c_allocator, body, .{});
    defer std.heap.c_allocator.free(body_json);
    const receipt_id = observation.sha256Hex(body_json);
    const record = WireRecord{ .receipt_id = receipt_id[0..], .body = body };
    const record_json = try std.json.Stringify.valueAlloc(std.heap.c_allocator, record, .{});
    defer std.heap.c_allocator.free(record_json);
    if (record_json.len + 1 > MAX_RECORD_BYTES) return error.RecordTooLarge;

    var lease = try Lease.acquire(session_dir, input.candidate_id);
    var receipt_persisted = false;
    errdefer {
        if (receipt_persisted)
            lease.closeKeep()
        else
            lease.release() catch {};
    }
    const head_id = try loadHead(std.heap.c_allocator, session_dir, input.candidate_id);
    if (head_id) |id| {
        if (std.mem.eql(u8, &id, &receipt_id)) {
            var existing = try load(std.heap.c_allocator, session_dir, receipt_id);
            existing.deinit();
            try lease.release();
            return .{ .receipt_id = receipt_id, .stage = std.meta.activeTag(input.evidence), .created = false };
        }
        if (input.predecessor_receipt_id == null or
            !std.mem.eql(u8, &id, &input.predecessor_receipt_id.?))
            return error.HeadRevisionMismatch;
    } else if (input.predecessor_receipt_id != null) return error.HeadRevisionMismatch;

    var predecessor: ?Loaded = null;
    defer if (predecessor) |*value| value.deinit();
    if (input.predecessor_receipt_id) |predecessor_id| {
        predecessor = try load(std.heap.c_allocator, session_dir, predecessor_id);
        if (!std.mem.eql(u8, &predecessor.?.candidate_id, &input.candidate_id) or
            !std.mem.eql(u8, &predecessor.?.project_sha256, &input.project_sha256))
            return error.PredecessorIdentityMismatch;
    }
    try validateTransition(session_dir, candidate, predecessor, input);
    const created = try persistExact(session_dir, receipt_id, record_json);
    receipt_persisted = true;
    try publishHead(session_dir, input.candidate_id, receipt_id, std.meta.activeTag(input.evidence));
    try lease.release();
    return .{ .receipt_id = receipt_id, .stage = std.meta.activeTag(input.evidence), .created = created };
}

pub fn load(
    allocator: std.mem.Allocator,
    session_dir: []const u8,
    receipt_id: [64]u8,
) !Loaded {
    if (!validHex(receipt_id)) return error.InvalidReceiptId;
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    const path = try std.fmt.allocPrint(a, "{s}/{s}{s}.json", .{ session_dir, FILE_PREFIX, receipt_id[0..] });
    const raw = try readBounded(a, path);
    if (raw.len < 2 or raw[raw.len - 1] != '\n') return error.InvalidReceipt;
    const record = std.json.parseFromSliceLeaky(RawRecord, a, raw[0 .. raw.len - 1], .{
        .ignore_unknown_fields = false,
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidReceipt,
    };
    const parsed_id = parseHex(record.receipt_id) orelse return error.InvalidReceipt;
    const candidate_id = parseHex(record.body.candidate_id) orelse return error.InvalidReceipt;
    const project = parseHex(record.body.project_sha256) orelse return error.InvalidReceipt;
    const actor = parseHex(record.body.actor_sha256) orelse return error.InvalidReceipt;
    const checker = parseHex(record.body.checker_sha256) orelse return error.InvalidReceipt;
    const predecessor = if (record.body.predecessor_receipt_id) |raw_id|
        parseHex(raw_id) orelse return error.InvalidReceipt
    else
        null;
    const legacy_schema = std.mem.eql(u8, record.body.schema_version, LEGACY_SCHEMA_VERSION);
    if ((!legacy_schema and !std.mem.eql(u8, record.body.schema_version, SCHEMA_VERSION)) or
        !std.mem.eql(u8, &parsed_id, &receipt_id))
        return error.InvalidReceipt;
    const prefix = "{\"receipt_id\":\"";
    const body_marker = "\",\"body\":";
    if (!std.mem.startsWith(u8, raw, prefix) or raw.len < prefix.len + 64 + body_marker.len + 3 or
        !std.mem.eql(u8, raw[prefix.len + 64 .. prefix.len + 64 + body_marker.len], body_marker) or
        raw[raw.len - 2] != '}') return error.InvalidReceipt;
    const body_start = prefix.len + 64 + body_marker.len;
    const expected_id = observation.sha256Hex(raw[body_start .. raw.len - 2]);
    if (!std.mem.eql(u8, &expected_id, &receipt_id)) return error.ReceiptHashMismatch;
    const parsed_evidence = try parseEvidence(record.body.evidence);
    return .{
        .arena = arena,
        .receipt_id = receipt_id,
        .candidate_id = candidate_id,
        .project_sha256 = project,
        .actor_sha256 = actor,
        .checker_sha256 = checker,
        .predecessor_receipt_id = predecessor,
        .stage = std.meta.activeTag(parsed_evidence),
        .evidence = parsed_evidence,
        .legacy_schema = legacy_schema,
    };
}

fn validateIdentities(input: Input) !void {
    if (!validHex(input.candidate_id) or !validHex(input.project_sha256) or
        !validHex(input.actor_sha256) or !validHex(input.checker_sha256))
        return error.InvalidIdentity;
    if (input.predecessor_receipt_id) |id| if (!validHex(id)) return error.InvalidIdentity;
    switch (input.evidence) {
        .built => |e| {
            if (!validHex(e.manifest_sha256) or !validHex(e.lean_source_sha256) or
                !validHex(e.rule_spec_sha256) or !validHex(e.compiled_artifact_sha256) or
                !validHex(e.toolchain_sha256) or !validHex(e.sdk_sha256) or
                !validHex(e.sdk_olean_sha256) or
                !validHex(e.build_log_sha256)) return error.InvalidEvidence;
        },
        .axiom_audited => |e| if (!validHex(e.audit_sha256) or !validHex(e.policy_sha256)) return error.InvalidEvidence,
        .replay_passed => |e| if (!validHex(e.corpus_sha256) or !validHex(e.results_sha256)) return error.InvalidEvidence,
        .shadow_passed => |e| if (!validHex(e.interval_sha256) or !validHex(e.results_sha256)) return error.InvalidEvidence,
        .rejected => |e| if (!validHex(e.reason_sha256) or !validHex(e.evidence_sha256)) return error.InvalidEvidence,
        .promoted => |e| {
            if (!validHex(e.lifecycle_request_sha256) or !validHex(e.lifecycle_verdict_sha256) or
                !validHex(e.runtime_kernel_sha256) or !validHex(e.bundle_sha256) or
                !validHex(e.previous_bundle_sha256)) return error.InvalidEvidence;
        },
        .superseded => |e| {
            if (!validHex(e.replacement_candidate_id) or
                !validHex(e.replacement_promotion_receipt_id) or
                !validHex(e.replacement_bundle_sha256)) return error.InvalidEvidence;
        },
    }
}

fn validateTransition(
    session_dir: []const u8,
    candidate: rule_candidate.Loaded,
    predecessor: ?Loaded,
    input: Input,
) !void {
    const next = std.meta.activeTag(input.evidence);
    if (next == .built) {
        if (predecessor != null) return error.InvalidTransition;
    } else if (next != .rejected and predecessor == null) return error.MissingPredecessor;

    if (predecessor) |prior| {
        if (!allowedTransition(prior.stage, next)) return error.InvalidTransition;
        if (!std.mem.eql(u8, &prior.receipt_id, &input.predecessor_receipt_id.?))
            return error.PredecessorIdentityMismatch;
    }
    switch (input.evidence) {
        .built => |e| {
            const canonical_spec = try project_rule_spec.renderCanonical(
                std.heap.c_allocator,
                candidate.rule_spec,
            );
            defer std.heap.c_allocator.free(canonical_spec);
            const canonical_spec_sha256 = observation.sha256Hex(canonical_spec);
            if (!std.mem.eql(u8, &e.lean_source_sha256, &candidate.lean_source_sha256) or
                !std.mem.eql(u8, &e.rule_spec_sha256, &canonical_spec_sha256) or
                !e.network_disabled or !e.secrets_absent or !e.source_bounded or
                !e.output_bounded or !e.completed)
                return error.BuildEvidenceIncomplete;
            if (std.mem.eql(u8, &candidate.proposer_sha256, &input.actor_sha256))
                return error.BuilderNotIndependent;
        },
        .axiom_audited => |e| {
            if (!e.completed or e.forbidden_declaration_count != 0 or e.unexpected_axiom_count != 0)
                return error.AxiomAuditFailed;
            if (std.mem.eql(u8, &predecessor.?.actor_sha256, &input.actor_sha256))
                return error.AuditorNotIndependent;
            if (std.mem.eql(u8, &candidate.proposer_sha256, &input.actor_sha256))
                return error.AuditorNotIndependent;
        },
        .replay_passed => |e| {
            if (!e.completed or e.positive_cases == 0 or e.negative_cases == 0 or
                e.false_positive_count != 0 or e.false_negative_count != 0)
                return error.ReplayFailed;
            if (std.mem.eql(u8, &candidate.proposer_sha256, &input.actor_sha256))
                return error.ReplayEvaluatorNotIndependent;
            const axiom = predecessor.?;
            var build = try loadPrevious(std.heap.c_allocator, session_dir, axiom, .built);
            defer build.deinit();
            if (std.mem.eql(u8, &axiom.actor_sha256, &input.actor_sha256) or
                std.mem.eql(u8, &build.actor_sha256, &input.actor_sha256))
                return error.ReplayEvaluatorNotIndependent;
        },
        .shadow_passed => |e| {
            if (!e.completed or e.observed_decisions == 0 or e.divergence_count != 0 or
                e.side_effect_count != 0)
                return error.ShadowFailed;
            if (std.mem.eql(u8, &candidate.proposer_sha256, &input.actor_sha256))
                return error.ShadowEvaluatorNotIndependent;
            if (std.mem.eql(u8, &predecessor.?.actor_sha256, &input.actor_sha256))
                return error.ShadowEvaluatorNotIndependent;
            var axiom = try loadPrevious(
                std.heap.c_allocator,
                session_dir,
                predecessor.?,
                .axiom_audited,
            );
            defer axiom.deinit();
            var build = try loadPrevious(std.heap.c_allocator, session_dir, axiom, .built);
            defer build.deinit();
            if (std.mem.eql(u8, &axiom.actor_sha256, &input.actor_sha256) or
                std.mem.eql(u8, &build.actor_sha256, &input.actor_sha256))
                return error.ShadowEvaluatorNotIndependent;
        },
        .rejected => {},
        .promoted => |e| {
            if (!e.checker_admitted or e.bundle_revision == 0)
                return error.PromotionNotAdmitted;
            try validatePromotionChain(candidate, session_dir, predecessor.?, input.actor_sha256);
        },
        .superseded => |e| {
            if (std.mem.eql(u8, &e.replacement_candidate_id, &candidate.candidate_id))
                return error.InvalidSupersession;
            var replacement = try load(
                std.heap.c_allocator,
                session_dir,
                e.replacement_promotion_receipt_id,
            );
            defer replacement.deinit();
            if (replacement.stage != .promoted or
                !std.mem.eql(u8, &replacement.candidate_id, &e.replacement_candidate_id) or
                !std.mem.eql(u8, &replacement.project_sha256, &candidate.project_sha256) or
                std.meta.activeTag(replacement.evidence) != .promoted or
                !std.mem.eql(
                    u8,
                    &replacement.evidence.promoted.bundle_sha256,
                    &e.replacement_bundle_sha256,
                )) return error.InvalidSupersession;
        },
    }
}

fn validatePromotionChain(
    candidate: rule_candidate.Loaded,
    session_dir: []const u8,
    shadow: Loaded,
    promoter: [64]u8,
) !void {
    if (candidate.source_receipt_id) |receipt_id| {
        var source = try source_receipt.load(std.heap.c_allocator, session_dir, receipt_id);
        defer source.deinit();
        if (!std.mem.eql(u8, &source.project_sha256, &candidate.project_sha256))
            return error.SourceReceiptMismatch;
    }
    var replay = try loadPrevious(std.heap.c_allocator, session_dir, shadow, .replay_passed);
    defer replay.deinit();
    var axiom = try loadPrevious(std.heap.c_allocator, session_dir, replay, .axiom_audited);
    defer axiom.deinit();
    var build = try loadPrevious(std.heap.c_allocator, session_dir, axiom, .built);
    defer build.deinit();
    if (build.legacy_schema or
        isZeroHex(build.evidence.built.manifest_sha256) or
        isZeroHex(build.evidence.built.rule_spec_sha256) or
        isZeroHex(build.evidence.built.sdk_olean_sha256))
        return error.LegacyBuildEvidenceNotPromotable;
    if (std.mem.eql(u8, &promoter, &candidate.proposer_sha256) or
        std.mem.eql(u8, &promoter, &build.actor_sha256) or
        std.mem.eql(u8, &promoter, &axiom.actor_sha256) or
        std.mem.eql(u8, &promoter, &replay.actor_sha256) or
        std.mem.eql(u8, &promoter, &shadow.actor_sha256))
        return error.PromoterNotIndependent;
}

fn loadPrevious(
    allocator: std.mem.Allocator,
    session_dir: []const u8,
    current: Loaded,
    expected: Stage,
) !Loaded {
    const id = current.predecessor_receipt_id orelse return error.MissingPredecessor;
    var prior = try load(allocator, session_dir, id);
    errdefer prior.deinit();
    if (prior.stage != expected or
        !std.mem.eql(u8, &prior.candidate_id, &current.candidate_id) or
        !std.mem.eql(u8, &prior.project_sha256, &current.project_sha256))
        return error.InvalidTransition;
    return prior;
}

fn allowedTransition(from: Stage, to: Stage) bool {
    if (to == .rejected) return switch (from) {
        .built, .axiom_audited, .replay_passed, .shadow_passed => true,
        else => false,
    };
    return switch (from) {
        .built => to == .axiom_audited,
        .axiom_audited => to == .replay_passed,
        .replay_passed => to == .shadow_passed,
        .shadow_passed => to == .promoted,
        .promoted => to == .superseded,
        .rejected, .superseded => false,
    };
}

fn wireEvidence(evidence: *const Evidence) WireEvidence {
    return switch (evidence.*) {
        .built => |*e| .{ .built = .{
            .manifest_sha256 = e.manifest_sha256[0..],
            .lean_source_sha256 = e.lean_source_sha256[0..],
            .rule_spec_sha256 = e.rule_spec_sha256[0..],
            .compiled_artifact_sha256 = e.compiled_artifact_sha256[0..],
            .toolchain_sha256 = e.toolchain_sha256[0..],
            .sdk_sha256 = e.sdk_sha256[0..],
            .sdk_olean_sha256 = e.sdk_olean_sha256[0..],
            .build_log_sha256 = e.build_log_sha256[0..],
            .network_disabled = e.network_disabled,
            .secrets_absent = e.secrets_absent,
            .source_bounded = e.source_bounded,
            .output_bounded = e.output_bounded,
            .completed = e.completed,
        } },
        .axiom_audited => |*e| .{ .axiom_audited = .{
            .audit_sha256 = e.audit_sha256[0..],
            .policy_sha256 = e.policy_sha256[0..],
            .forbidden_declaration_count = e.forbidden_declaration_count,
            .unexpected_axiom_count = e.unexpected_axiom_count,
            .completed = e.completed,
        } },
        .replay_passed => |*e| .{ .replay_passed = .{
            .corpus_sha256 = e.corpus_sha256[0..],
            .results_sha256 = e.results_sha256[0..],
            .positive_cases = e.positive_cases,
            .negative_cases = e.negative_cases,
            .false_positive_count = e.false_positive_count,
            .false_negative_count = e.false_negative_count,
            .completed = e.completed,
        } },
        .shadow_passed => |*e| .{ .shadow_passed = .{
            .interval_sha256 = e.interval_sha256[0..],
            .results_sha256 = e.results_sha256[0..],
            .observed_decisions = e.observed_decisions,
            .divergence_count = e.divergence_count,
            .side_effect_count = e.side_effect_count,
            .completed = e.completed,
        } },
        .rejected => |*e| .{ .rejected = .{
            .reason_sha256 = e.reason_sha256[0..],
            .evidence_sha256 = e.evidence_sha256[0..],
        } },
        .promoted => |*e| .{ .promoted = .{
            .lifecycle_request_sha256 = e.lifecycle_request_sha256[0..],
            .lifecycle_verdict_sha256 = e.lifecycle_verdict_sha256[0..],
            .runtime_kernel_sha256 = e.runtime_kernel_sha256[0..],
            .bundle_sha256 = e.bundle_sha256[0..],
            .previous_bundle_sha256 = e.previous_bundle_sha256[0..],
            .bundle_revision = e.bundle_revision,
            .checker_admitted = e.checker_admitted,
        } },
        .superseded => |*e| .{ .superseded = .{
            .replacement_candidate_id = e.replacement_candidate_id[0..],
            .replacement_promotion_receipt_id = e.replacement_promotion_receipt_id[0..],
            .replacement_bundle_sha256 = e.replacement_bundle_sha256[0..],
        } },
    };
}

fn parseEvidence(evidence: WireEvidence) !ParsedEvidence {
    return switch (evidence) {
        .built => |e| .{ .built = .{
            .manifest_sha256 = parseHex(e.manifest_sha256) orelse return error.InvalidReceipt,
            .lean_source_sha256 = parseHex(e.lean_source_sha256) orelse return error.InvalidReceipt,
            .rule_spec_sha256 = parseHex(e.rule_spec_sha256) orelse return error.InvalidReceipt,
            .compiled_artifact_sha256 = parseHex(e.compiled_artifact_sha256) orelse return error.InvalidReceipt,
            .toolchain_sha256 = parseHex(e.toolchain_sha256) orelse return error.InvalidReceipt,
            .sdk_sha256 = parseHex(e.sdk_sha256) orelse return error.InvalidReceipt,
            .sdk_olean_sha256 = parseHex(e.sdk_olean_sha256) orelse return error.InvalidReceipt,
            .build_log_sha256 = parseHex(e.build_log_sha256) orelse return error.InvalidReceipt,
            .network_disabled = e.network_disabled,
            .secrets_absent = e.secrets_absent,
            .source_bounded = e.source_bounded,
            .output_bounded = e.output_bounded,
            .completed = e.completed,
        } },
        .axiom_audited => |e| .{ .axiom_audited = .{
            .audit_sha256 = parseHex(e.audit_sha256) orelse return error.InvalidReceipt,
            .policy_sha256 = parseHex(e.policy_sha256) orelse return error.InvalidReceipt,
            .forbidden_declaration_count = e.forbidden_declaration_count,
            .unexpected_axiom_count = e.unexpected_axiom_count,
            .completed = e.completed,
        } },
        .replay_passed => |e| .{ .replay_passed = .{
            .corpus_sha256 = parseHex(e.corpus_sha256) orelse return error.InvalidReceipt,
            .results_sha256 = parseHex(e.results_sha256) orelse return error.InvalidReceipt,
            .positive_cases = e.positive_cases,
            .negative_cases = e.negative_cases,
            .false_positive_count = e.false_positive_count,
            .false_negative_count = e.false_negative_count,
            .completed = e.completed,
        } },
        .shadow_passed => |e| .{ .shadow_passed = .{
            .interval_sha256 = parseHex(e.interval_sha256) orelse return error.InvalidReceipt,
            .results_sha256 = parseHex(e.results_sha256) orelse return error.InvalidReceipt,
            .observed_decisions = e.observed_decisions,
            .divergence_count = e.divergence_count,
            .side_effect_count = e.side_effect_count,
            .completed = e.completed,
        } },
        .rejected => |e| .{ .rejected = .{
            .reason_sha256 = parseHex(e.reason_sha256) orelse return error.InvalidReceipt,
            .evidence_sha256 = parseHex(e.evidence_sha256) orelse return error.InvalidReceipt,
        } },
        .promoted => |e| .{ .promoted = .{
            .lifecycle_request_sha256 = parseHex(e.lifecycle_request_sha256) orelse return error.InvalidReceipt,
            .lifecycle_verdict_sha256 = parseHex(e.lifecycle_verdict_sha256) orelse return error.InvalidReceipt,
            .runtime_kernel_sha256 = parseHex(e.runtime_kernel_sha256) orelse return error.InvalidReceipt,
            .bundle_sha256 = parseHex(e.bundle_sha256) orelse return error.InvalidReceipt,
            .previous_bundle_sha256 = parseHex(e.previous_bundle_sha256) orelse return error.InvalidReceipt,
            .bundle_revision = e.bundle_revision,
            .checker_admitted = e.checker_admitted,
        } },
        .superseded => |e| .{ .superseded = .{
            .replacement_candidate_id = parseHex(e.replacement_candidate_id) orelse return error.InvalidReceipt,
            .replacement_promotion_receipt_id = parseHex(e.replacement_promotion_receipt_id) orelse return error.InvalidReceipt,
            .replacement_bundle_sha256 = parseHex(e.replacement_bundle_sha256) orelse return error.InvalidReceipt,
        } },
    };
}

fn persistExact(session_dir: []const u8, receipt_id: [64]u8, bytes: []const u8) !bool {
    var path_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}{s}.json\x00", .{ session_dir, FILE_PREFIX, receipt_id[0..] });
    const fd = pfs.open(@ptrCast(path.ptr), .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .EXCL = true,
        .NOFOLLOW = true,
    }, @as(std.c.mode_t, 0o600));
    if (fd >= 0) {
        errdefer _ = pfs.close(fd);
        try pfs.makeCloseOnExec(fd);
        try writeAll(fd, bytes);
        try writeAll(fd, "\n");
        try pfs.fsyncChecked(fd);
        _ = pfs.close(fd);
        return true;
    }
    const existing = try readBounded(std.heap.c_allocator, path[0 .. path.len - 1]);
    defer std.heap.c_allocator.free(existing);
    if (existing.len != bytes.len + 1 or !std.mem.eql(u8, existing[0..bytes.len], bytes) or
        existing[bytes.len] != '\n') return error.ReceiptCollision;
    return false;
}

fn loadHead(
    allocator: std.mem.Allocator,
    session_dir: []const u8,
    candidate_id: [64]u8,
) !?[64]u8 {
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}{s}.json", .{ session_dir, HEAD_PREFIX, candidate_id[0..] });
    defer allocator.free(path);
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const fd = pfs.open(path_z.ptr, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true }, 0);
    if (fd < 0) {
        if (!pfs.exists(path_z.ptr)) return null;
        return error.HeadOpenFailed;
    }
    defer _ = pfs.close(fd);
    const info = pfs.fileInfo(fd) catch return error.HeadStatFailed;
    if (!info.is_regular or info.size == 0 or info.size > 4096) return error.InvalidHead;
    const bytes = try allocator.alloc(u8, @intCast(info.size));
    defer allocator.free(bytes);
    var offset: usize = 0;
    while (offset < bytes.len) {
        const count = pfs.read(fd, bytes[offset..]);
        if (count <= 0) return error.HeadReadFailed;
        offset += @intCast(count);
    }
    const after = pfs.fileInfo(fd) catch return error.HeadStatFailed;
    if (!after.is_regular or after.size != info.size) return error.HeadChangedDuringRead;
    var parsed = std.json.parseFromSlice(Head, allocator, bytes, .{
        .ignore_unknown_fields = false,
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    }) catch return error.InvalidHead;
    defer parsed.deinit();
    const parsed_candidate = parseHex(parsed.value.candidate_id) orelse return error.InvalidHead;
    const receipt_id = parseHex(parsed.value.receipt_id) orelse return error.InvalidHead;
    if (!std.mem.eql(u8, parsed.value.schema_version, "metacodes-rule-stage-head-v1") or
        !std.mem.eql(u8, &parsed_candidate, &candidate_id)) return error.InvalidHead;
    var receipt = try load(allocator, session_dir, receipt_id);
    defer receipt.deinit();
    if (receipt.stage != parsed.value.stage or
        !std.mem.eql(u8, &receipt.candidate_id, &candidate_id)) return error.InvalidHead;
    return receipt_id;
}

fn publishHead(
    session_dir: []const u8,
    candidate_id: [64]u8,
    receipt_id: [64]u8,
    stage: Stage,
) !void {
    const head = Head{
        .candidate_id = candidate_id[0..],
        .receipt_id = receipt_id[0..],
        .stage = stage,
    };
    const bytes = try std.json.Stringify.valueAlloc(std.heap.c_allocator, head, .{});
    defer std.heap.c_allocator.free(bytes);
    var final_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const final = try std.fmt.bufPrint(&final_buf, "{s}/{s}{s}.json\x00", .{ session_dir, HEAD_PREFIX, candidate_id[0..] });
    var temp_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const temp = try std.fmt.bufPrint(&temp_buf, "{s}/{s}{s}.tmp\x00", .{ session_dir, HEAD_PREFIX, candidate_id[0..] });
    var fd = pfs.open(@ptrCast(temp.ptr), .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .EXCL = true,
        .NOFOLLOW = true,
    }, @as(std.c.mode_t, 0o600));
    if (fd < 0) return error.HeadTempExists;
    errdefer {
        if (fd >= 0) _ = pfs.close(fd);
    }
    try pfs.makeCloseOnExec(fd);
    try writeAll(fd, bytes);
    try pfs.fsyncChecked(fd);
    _ = pfs.close(fd);
    fd = -1;
    if (pfs.renameReplace(@ptrCast(temp.ptr), @ptrCast(final.ptr)) != 0)
        return error.HeadPublishFailed;
}

fn readBounded(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const fd = pfs.open(path_z.ptr, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true }, 0);
    if (fd < 0) return error.OpenFailed;
    defer _ = pfs.close(fd);
    const before = pfs.fileInfo(fd) catch return error.StatFailed;
    if (!before.is_regular or before.size == 0 or before.size > MAX_RECORD_BYTES)
        return error.InvalidReceipt;
    const bytes = try allocator.alloc(u8, @intCast(before.size));
    errdefer allocator.free(bytes);
    var offset: usize = 0;
    while (offset < bytes.len) {
        const count = pfs.read(fd, bytes[offset..]);
        if (count <= 0) return error.ReadFailed;
        offset += @intCast(count);
    }
    const after = pfs.fileInfo(fd) catch return error.StatFailed;
    if (!after.is_regular or after.size != before.size) return error.ChangedDuringRead;
    return bytes;
}

fn validHex(value: [64]u8) bool {
    return parseHex(value[0..]) != null;
}

fn isZeroHex(value: [64]u8) bool {
    return std.mem.allEqual(u8, &value, '0');
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

fn writeAll(fd: pfs.Fd, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const count = pfs.write(fd, bytes[offset..]);
        if (count <= 0) return error.WriteFailed;
        offset += @intCast(count);
    }
}

test "lifecycle evidence cannot skip stages and rejects failed replay" {
    var fixture = try TestFixture.init();
    defer fixture.deinit();
    const build = try fixture.build();
    try std.testing.expectError(error.InvalidTransition, persist(fixture.root, .{
        .candidate_id = fixture.candidate_id,
        .project_sha256 = fixture.project,
        .actor_sha256 = .{'d'} ** 64,
        .checker_sha256 = .{'e'} ** 64,
        .predecessor_receipt_id = build.receipt_id,
        .evidence = .{ .replay_passed = goodReplay() },
    }));
    const axiom = try fixture.axiom(build.receipt_id);
    try std.testing.expectError(error.HeadRevisionMismatch, persist(fixture.root, .{
        .candidate_id = fixture.candidate_id,
        .project_sha256 = fixture.project,
        .actor_sha256 = .{'9'} ** 64,
        .checker_sha256 = .{'f'} ** 64,
        .predecessor_receipt_id = build.receipt_id,
        .evidence = .{ .axiom_audited = .{
            .audit_sha256 = .{'3'} ** 64,
            .policy_sha256 = .{'4'} ** 64,
            .forbidden_declaration_count = 0,
            .unexpected_axiom_count = 0,
            .completed = true,
        } },
    }));
    var failed = goodReplay();
    failed.false_positive_count = 1;
    try std.testing.expectError(error.ReplayFailed, persist(fixture.root, .{
        .candidate_id = fixture.candidate_id,
        .project_sha256 = fixture.project,
        .actor_sha256 = .{'f'} ** 64,
        .checker_sha256 = .{'1'} ** 64,
        .predecessor_receipt_id = axiom.receipt_id,
        .evidence = .{ .replay_passed = failed },
    }));
}

test "promotion requires the complete chain and an independent promoter" {
    var fixture = try TestFixture.init();
    defer fixture.deinit();
    const build = try fixture.build();
    const axiom = try fixture.axiom(build.receipt_id);
    const replay = try fixture.replay(axiom.receipt_id);
    const shadow = try fixture.shadow(replay.receipt_id);
    const evidence = PromotionEvidence{
        .lifecycle_request_sha256 = .{'7'} ** 64,
        .lifecycle_verdict_sha256 = .{'8'} ** 64,
        .runtime_kernel_sha256 = .{'9'} ** 64,
        .bundle_sha256 = .{'a'} ** 64,
        .previous_bundle_sha256 = .{'0'} ** 64,
        .bundle_revision = 1,
        .checker_admitted = true,
    };
    try std.testing.expectError(error.PromoterNotIndependent, persistInternal(fixture.root, .{
        .candidate_id = fixture.candidate_id,
        .project_sha256 = fixture.project,
        .actor_sha256 = .{'b'} ** 64,
        .checker_sha256 = .{'6'} ** 64,
        .predecessor_receipt_id = shadow.receipt_id,
        .evidence = .{ .promoted = evidence },
    }));
    try std.testing.expectError(error.FormalAdmissionRequired, persist(fixture.root, .{
        .candidate_id = fixture.candidate_id,
        .project_sha256 = fixture.project,
        .actor_sha256 = .{'7'} ** 64,
        .checker_sha256 = .{'6'} ** 64,
        .predecessor_receipt_id = shadow.receipt_id,
        .evidence = .{ .promoted = evidence },
    }));
    const promoted = try persistInternal(fixture.root, .{
        .candidate_id = fixture.candidate_id,
        .project_sha256 = fixture.project,
        .actor_sha256 = .{'7'} ** 64,
        .checker_sha256 = .{'6'} ** 64,
        .predecessor_receipt_id = shadow.receipt_id,
        .evidence = .{ .promoted = evidence },
    });
    const replayed = try persistInternal(fixture.root, .{
        .candidate_id = fixture.candidate_id,
        .project_sha256 = fixture.project,
        .actor_sha256 = .{'7'} ** 64,
        .checker_sha256 = .{'6'} ** 64,
        .predecessor_receipt_id = shadow.receipt_id,
        .evidence = .{ .promoted = evidence },
    });
    try std.testing.expect(!replayed.created);
    try std.testing.expectEqualSlices(u8, &promoted.receipt_id, &replayed.receipt_id);
    var loaded = try load(std.testing.allocator, fixture.root, promoted.receipt_id);
    defer loaded.deinit();
    try std.testing.expectEqual(Stage.promoted, loaded.stage);
}

test "v1 lifecycle receipts remain readable but cannot satisfy new promotion evidence" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    const body = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"schema_version\":\"{s}\",\"candidate_id\":\"{s}\",\"project_sha256\":\"{s}\",\"actor_sha256\":\"{s}\",\"checker_sha256\":\"{s}\",\"predecessor_receipt_id\":null,\"evidence\":{{\"built\":{{\"lean_source_sha256\":\"{s}\",\"compiled_artifact_sha256\":\"{s}\",\"toolchain_sha256\":\"{s}\",\"sdk_sha256\":\"{s}\",\"build_log_sha256\":\"{s}\",\"network_disabled\":true,\"secrets_absent\":true,\"source_bounded\":true,\"output_bounded\":true,\"completed\":true}}}}}}",
        .{
            LEGACY_SCHEMA_VERSION,
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
            "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
            "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
            "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee",
            "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
            "1111111111111111111111111111111111111111111111111111111111111111",
            "2222222222222222222222222222222222222222222222222222222222222222",
            "3333333333333333333333333333333333333333333333333333333333333333",
        },
    );
    defer std.testing.allocator.free(body);
    const receipt_id = observation.sha256Hex(body);
    const record = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"receipt_id\":\"{s}\",\"body\":{s}}}",
        .{ receipt_id, body },
    );
    defer std.testing.allocator.free(record);
    _ = try persistExact(root, receipt_id, record);
    var loaded = try load(std.testing.allocator, root, receipt_id);
    defer loaded.deinit();
    try std.testing.expect(loaded.legacy_schema);
    try std.testing.expect(isZeroHex(loaded.evidence.built.manifest_sha256));
    try std.testing.expect(isZeroHex(loaded.evidence.built.rule_spec_sha256));
    try std.testing.expect(isZeroHex(loaded.evidence.built.sdk_olean_sha256));
}

const TestFixture = struct {
    tmp: std.testing.TmpDir,
    root: []const u8,
    project: [64]u8,
    candidate_id: [64]u8,

    fn init() !TestFixture {
        var tmp = std.testing.tmpDir(.{});
        var root_buf: [std.fs.max_path_bytes]u8 = undefined;
        const root_len = try tmp.dir.realPath(std.testing.io, &root_buf);
        const root = try std.testing.allocator.dupe(u8, root_buf[0..root_len]);
        const project = [_]u8{'a'} ** 64;
        const sid = @import("session_id.zig").SessionId.fromSlice("0123456789abcdef01234567").?;
        var journal = try @import("tool_observation_journal.zig").Journal.init(root, sid);
        try journal.finishRun("end_turn");
        const binding = try journal.runBinding();
        journal.deinit();
        const candidate = try rule_candidate.persist(root, .{
            .project_sha256 = project,
            .proposer_sha256 = .{'b'} ** 64,
            .invariant = "Completed effects retain a terminal observation.",
            .rule_spec = .{
                .target_tool = "Write",
                .deny_target = false,
                .max_input_bytes = 8192,
                .max_agent_depth = 4,
                .authoritative_only = true,
                .effect_requirement = .file_mutation_v1_reobserved,
            },
            .lean_source = "def candidateRule : Bool := true",
            .source = .{ .agent_reflection = .{
                .observation = binding,
                .reflector_sha256 = .{'b'} ** 64,
                .falsifier = "A replay loses the terminal observation.",
            } },
        });
        return .{ .tmp = tmp, .root = root, .project = project, .candidate_id = candidate.candidate_id };
    }

    fn deinit(self: *TestFixture) void {
        std.testing.allocator.free(self.root);
        self.tmp.cleanup();
    }

    fn build(self: *TestFixture) !PersistResult {
        var candidate = try rule_candidate.load(std.testing.allocator, self.root, self.candidate_id);
        defer candidate.deinit();
        const canonical_spec = try project_rule_spec.renderCanonical(
            std.testing.allocator,
            candidate.rule_spec,
        );
        defer std.testing.allocator.free(canonical_spec);
        return persist(self.root, .{
            .candidate_id = self.candidate_id,
            .project_sha256 = self.project,
            .actor_sha256 = .{'c'} ** 64,
            .checker_sha256 = .{'d'} ** 64,
            .predecessor_receipt_id = null,
            .evidence = .{ .built = .{
                .manifest_sha256 = .{'9'} ** 64,
                .lean_source_sha256 = candidate.lean_source_sha256,
                .rule_spec_sha256 = observation.sha256Hex(canonical_spec),
                .compiled_artifact_sha256 = .{'e'} ** 64,
                .toolchain_sha256 = .{'f'} ** 64,
                .sdk_sha256 = .{'1'} ** 64,
                .sdk_olean_sha256 = .{'b'} ** 64,
                .build_log_sha256 = .{'2'} ** 64,
                .network_disabled = true,
                .secrets_absent = true,
                .source_bounded = true,
                .output_bounded = true,
                .completed = true,
            } },
        });
    }

    fn axiom(self: *TestFixture, predecessor: [64]u8) !PersistResult {
        return persist(self.root, .{
            .candidate_id = self.candidate_id,
            .project_sha256 = self.project,
            .actor_sha256 = .{'e'} ** 64,
            .checker_sha256 = .{'f'} ** 64,
            .predecessor_receipt_id = predecessor,
            .evidence = .{ .axiom_audited = .{
                .audit_sha256 = .{'3'} ** 64,
                .policy_sha256 = .{'4'} ** 64,
                .forbidden_declaration_count = 0,
                .unexpected_axiom_count = 0,
                .completed = true,
            } },
        });
    }

    fn replay(self: *TestFixture, predecessor: [64]u8) !PersistResult {
        return persist(self.root, .{
            .candidate_id = self.candidate_id,
            .project_sha256 = self.project,
            .actor_sha256 = .{'f'} ** 64,
            .checker_sha256 = .{'1'} ** 64,
            .predecessor_receipt_id = predecessor,
            .evidence = .{ .replay_passed = goodReplay() },
        });
    }

    fn shadow(self: *TestFixture, predecessor: [64]u8) !PersistResult {
        return persist(self.root, .{
            .candidate_id = self.candidate_id,
            .project_sha256 = self.project,
            .actor_sha256 = .{'1'} ** 64,
            .checker_sha256 = .{'2'} ** 64,
            .predecessor_receipt_id = predecessor,
            .evidence = .{ .shadow_passed = .{
                .interval_sha256 = .{'3'} ** 64,
                .results_sha256 = .{'4'} ** 64,
                .observed_decisions = 3,
                .divergence_count = 0,
                .side_effect_count = 0,
                .completed = true,
            } },
        });
    }
};

fn goodReplay() ReplayEvidence {
    return .{
        .corpus_sha256 = .{'5'} ** 64,
        .results_sha256 = .{'6'} ** 64,
        .positive_cases = 2,
        .negative_cases = 2,
        .false_positive_count = 0,
        .false_negative_count = 0,
        .completed = true,
    };
}
