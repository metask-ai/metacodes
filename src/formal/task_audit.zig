//! First read-only vertical through the native formal control plane.
//!
//! TinyKG supplies a bounded task snapshot.  Zig validates and measures that
//! real state, binds a no-mutation proposal to its revision, calls the
//! precompiled Lean kernel, and emits an append-only engineering receipt.
//! Reobserve/CAS/rollback are explicit `not_applicable_read_only`; this module
//! must not imply that the later mutation transaction already exists.

const std = @import("std");
const runtime = @import("runtime.zig");
const artifact_store = @import("artifact_store.zig");
const provenance = @import("provenance.zig");
const projection = @import("../kg/task_projection.zig");
const ToolContext = @import("../tools/context.zig").ToolContext;
const pfs = @import("platform").fs;
const time = @import("../util/time.zig");

pub const RECEIPT_SCHEMA = "metacodes-formal-audit-receipt-v1";
pub const PROPOSAL_SCHEMA = "metacodes-formal-proposal-v1";
pub const TELEMETRY_SCHEMA = artifact_store.INDEX_SCHEMA;
const MAX_RECEIPT_BYTES: usize = 64 * 1024;

const PipelineFailure = enum {
    none,
    config_missing,
    config_invalid,
    tinykg_unavailable,
    snapshot_fetch_failed,
    snapshot_invalid,
    runtime_failure,
    checker_provenance_invalid,
    checker_blocked,
    telemetry_not_persisted,
};

pub const Facts = struct {
    schema_supported: bool,
    snapshot_bounded: bool,
    task_count: usize,
    open_count: usize,
    claimed_count: usize,
    completed_count: usize,
    failed_count: usize,
    claimed_with_owner_count: usize,
    reachable_task_count: usize,
    terminal_with_evidence_count: usize,
    invalid_reference_count: usize,
    truncated: bool,
    proposal_bound: bool,
    preserves_tasks: bool,
    preserves_evidence: bool,
    preserves_recovery: bool,
    preserves_schema: bool,
    contradiction_safe: bool,
    reversible: bool,
};

const AuditIdentity = struct {
    root_task_id: u64,
    snapshot_revision: [64]u8,
    snapshot_sha256: [64]u8,
    proposal_sha256: [64]u8,
    request_id: [64]u8,
    snapshot_bytes: usize,
    proposal_bytes: usize,
    facts: Facts,
};

const Receipt = struct {
    event_id: [64]u8 = [_]u8{'0'} ** 64,
    started_wall_ns: i128,
    finished_wall_ns: i128,
    monotonic_elapsed_ns: u64 = 0,
    snapshot_fetch_elapsed_ns: u64 = 0,
    sensor_elapsed_ns: u64 = 0,
    identity: ?AuditIdentity = null,
    config: ?runtime.Config = null,
    invocation: ?*const runtime.Invocation = null,
    provenance: ?*const provenance.Loaded = null,
    provenance_elapsed_ns: u64 = 0,
    pipeline_failure: PipelineFailure,
    source_error: ?[]const u8 = null,
    source_detail: ?[]const u8 = null,
    telemetry_configured: bool,
    telemetry_persisted: bool,

    fn pipelineAdmitted(self: Receipt) bool {
        return self.pipeline_failure == .none and self.telemetry_persisted and
            self.invocation != null and self.invocation.?.checkerAdmitted();
    }
};

const Args = struct {
    root_task_id: u64,
};

pub fn execute(ctx: *const ToolContext, args_json: []const u8) anyerror![]u8 {
    return switch (runtime.loadConfigFromEnv()) {
        .configured => |config| executeWithConfig(ctx, args_json, config, null),
        .missing => renderPreflight(ctx, args_json, .config_missing, null),
        .invalid => renderPreflight(ctx, args_json, .config_invalid, null),
    };
}

/// Testable/product-neutral entry: callers inject a deployment-pinned config;
/// the model-facing tool never accepts checker path or digest as arguments.
pub fn executeWithConfig(
    ctx: *const ToolContext,
    args_json: []const u8,
    config: runtime.Config,
    telemetry_override: ?[]const u8,
) anyerror![]u8 {
    const args = try parseArgs(ctx.allocator, args_json);
    const started_wall_ns = time.nowWallNs();
    const started_monotonic_ns = time.nowNs();
    const telemetry_path = try resolveTelemetryPath(ctx.allocator, ctx.home_dir, telemetry_override);
    defer if (telemetry_path) |path| ctx.allocator.free(path);

    const kg = ctx.kg orelse return finalizePreflight(ctx.allocator, .{
        .started_wall_ns = started_wall_ns,
        .finished_wall_ns = time.nowWallNs(),
        .monotonic_elapsed_ns = elapsedSince(started_monotonic_ns),
        .config = config,
        .pipeline_failure = .tinykg_unavailable,
        .telemetry_configured = telemetry_path != null,
        .telemetry_persisted = false,
    }, telemetry_path, .{});
    if (!kg.ready) return finalizePreflight(ctx.allocator, .{
        .started_wall_ns = started_wall_ns,
        .finished_wall_ns = time.nowWallNs(),
        .monotonic_elapsed_ns = elapsedSince(started_monotonic_ns),
        .config = config,
        .pipeline_failure = .tinykg_unavailable,
        .telemetry_configured = telemetry_path != null,
        .telemetry_persisted = false,
    }, telemetry_path, .{});
    kg.setAbort(ctx.abort);

    const snapshot_fetch_started = time.nowNs();
    const encoded_snapshot = kg.taskSnapshot(args.root_task_id) catch |err| {
        const detail = kg.detail();
        return finalizePreflight(ctx.allocator, .{
            .started_wall_ns = started_wall_ns,
            .finished_wall_ns = time.nowWallNs(),
            .monotonic_elapsed_ns = elapsedSince(started_monotonic_ns),
            .snapshot_fetch_elapsed_ns = elapsedSince(snapshot_fetch_started),
            .config = config,
            .pipeline_failure = .snapshot_fetch_failed,
            .source_error = @errorName(err),
            .source_detail = if (detail.len != 0)
                detail
            else
                "TinyKG task-snapshot failed; verify the deployed binary exposes the tinykg-task-snapshot-v1 capability and inspect host logs",
            .telemetry_configured = telemetry_path != null,
            .telemetry_persisted = false,
        }, telemetry_path, .{});
    };
    defer kg.allocator.free(encoded_snapshot);
    return auditSnapshotTimed(
        ctx.allocator,
        args.root_task_id,
        encoded_snapshot,
        config,
        telemetry_path,
        ctx.abort,
        started_wall_ns,
        started_monotonic_ns,
        elapsedSince(snapshot_fetch_started),
    );
}

/// Pure sensor boundary plus real sidecar invocation.  Exposed for L2 fixtures
/// so protocol, hashing, native execution, and telemetry can be exercised
/// without fabricating a KgClient implementation.
pub fn auditSnapshot(
    allocator: std.mem.Allocator,
    root_task_id: u64,
    encoded_snapshot: []const u8,
    config: runtime.Config,
    telemetry_path: ?[]const u8,
    abort: ?*const @import("../util/abort.zig").AbortSignal,
    started_wall_ns: i128,
    started_monotonic_ns: i128,
) anyerror![]u8 {
    return auditSnapshotTimed(
        allocator,
        root_task_id,
        encoded_snapshot,
        config,
        telemetry_path,
        abort,
        started_wall_ns,
        started_monotonic_ns,
        0,
    );
}

fn auditSnapshotTimed(
    allocator: std.mem.Allocator,
    root_task_id: u64,
    encoded_snapshot: []const u8,
    config: runtime.Config,
    telemetry_path: ?[]const u8,
    abort: ?*const @import("../util/abort.zig").AbortSignal,
    started_wall_ns: i128,
    started_monotonic_ns: i128,
    snapshot_fetch_elapsed_ns: u64,
) anyerror![]u8 {
    const sensor_started = time.nowNs();
    var graph = projection.parseSnapshot(
        allocator,
        projection.TaskId.fromInt(root_task_id),
        encoded_snapshot,
    ) catch |err| {
        return finalizePreflight(allocator, .{
            .started_wall_ns = started_wall_ns,
            .finished_wall_ns = time.nowWallNs(),
            .monotonic_elapsed_ns = elapsedSince(started_monotonic_ns),
            .snapshot_fetch_elapsed_ns = snapshot_fetch_elapsed_ns,
            .sensor_elapsed_ns = elapsedSince(sensor_started),
            .config = config,
            .pipeline_failure = .snapshot_invalid,
            .source_error = @errorName(err),
            .telemetry_configured = telemetry_path != null,
            .telemetry_persisted = false,
        }, telemetry_path, .{ .snapshot_source = encoded_snapshot });
    };
    defer graph.deinit();

    const canonical_snapshot = try graph.canonicalJson(allocator);
    defer allocator.free(canonical_snapshot);
    const proposal = try buildProposal(allocator, root_task_id, graph.revision);
    defer allocator.free(proposal);
    const facts = measureFacts(&graph);
    const snapshot_sha256 = sha256Hex(canonical_snapshot);
    const proposal_sha256 = sha256Hex(proposal);
    const request_id = requestId(proposal_sha256, snapshot_sha256, graph.revision);
    const identity = AuditIdentity{
        .root_task_id = root_task_id,
        .snapshot_revision = graph.revision,
        .snapshot_sha256 = snapshot_sha256,
        .proposal_sha256 = proposal_sha256,
        .request_id = request_id,
        .snapshot_bytes = canonical_snapshot.len,
        .proposal_bytes = proposal.len,
        .facts = facts,
    };
    const request = try buildRequest(allocator, identity);
    defer allocator.free(request);
    const sensor_elapsed_ns = elapsedSince(sensor_started);
    var invocation = try runtime.invoke(allocator, config, request, .{
        .operation = "task_audit",
        .request_id = request_id,
        .proposal_sha256 = proposal_sha256,
        .snapshot_sha256 = snapshot_sha256,
        .snapshot_revision = graph.revision,
    }, abort);
    defer invocation.deinit(allocator);

    var checker_provenance: ?provenance.Loaded = null;
    defer if (checker_provenance) |*loaded| loaded.deinit();
    var provenance_error: ?[]const u8 = null;
    var provenance_elapsed_ns: u64 = 0;
    if (invocation.failure == .none) {
        const provenance_started = time.nowNs();
        if (provenance.loadAdjacent(
            allocator,
            config.checker_path,
            invocation.actual_checker_sha256,
            invocation.checker_bytes,
        )) |loaded| {
            checker_provenance = loaded;
        } else |err| {
            provenance_error = @errorName(err);
        }
        provenance_elapsed_ns = elapsedSince(provenance_started);
    }

    const pipeline_failure: PipelineFailure = if (invocation.failure != .none)
        .runtime_failure
    else if (checker_provenance == null)
        .checker_provenance_invalid
    else if (!invocation.checkerAdmitted())
        .checker_blocked
    else
        .none;
    return finalizePreflight(allocator, .{
        .started_wall_ns = started_wall_ns,
        .finished_wall_ns = time.nowWallNs(),
        .monotonic_elapsed_ns = elapsedSince(started_monotonic_ns),
        .snapshot_fetch_elapsed_ns = snapshot_fetch_elapsed_ns,
        .sensor_elapsed_ns = sensor_elapsed_ns,
        .identity = identity,
        .config = config,
        .invocation = &invocation,
        .provenance = if (checker_provenance) |*loaded| loaded else null,
        .provenance_elapsed_ns = provenance_elapsed_ns,
        .pipeline_failure = pipeline_failure,
        .source_error = provenance_error,
        .telemetry_configured = telemetry_path != null,
        .telemetry_persisted = false,
    }, telemetry_path, .{
        .snapshot_source = encoded_snapshot,
        .snapshot = canonical_snapshot,
        .proposal = proposal,
        .request = request,
        .verdict = if (invocation.verdict != null) invocation.verdict_payload else null,
        .checker_stdout = invocation.stdout,
        .checker_stderr = invocation.stderr,
        .checker_provenance = if (checker_provenance) |*loaded| loaded.raw else null,
    });
}

fn renderPreflight(
    ctx: *const ToolContext,
    args_json: []const u8,
    failure: PipelineFailure,
    source_error: ?[]const u8,
) anyerror![]u8 {
    _ = try parseArgs(ctx.allocator, args_json);
    const path = try resolveTelemetryPath(ctx.allocator, ctx.home_dir, null);
    defer if (path) |owned| ctx.allocator.free(owned);
    const now = time.nowWallNs();
    const monotonic = time.nowNs();
    return finalizePreflight(ctx.allocator, .{
        .started_wall_ns = now,
        .finished_wall_ns = now,
        .monotonic_elapsed_ns = elapsedSince(monotonic),
        .pipeline_failure = failure,
        .source_error = source_error,
        .telemetry_configured = path != null,
        .telemetry_persisted = false,
    }, path, .{});
}

fn finalizePreflight(
    allocator: std.mem.Allocator,
    initial: Receipt,
    telemetry_path: ?[]const u8,
    artifacts: artifact_store.Artifacts,
) anyerror![]u8 {
    var persisted = initial;
    persisted.event_id = artifact_store.newEventId(
        persisted.started_wall_ns,
        @intCast(persisted.monotonic_elapsed_ns),
        if (persisted.identity) |identity| identity.request_id[0..] else null,
    );
    persisted.telemetry_persisted = telemetry_path != null;
    const line = try renderReceipt(allocator, persisted);
    var line_owned = true;
    errdefer if (line_owned) allocator.free(line);
    if (telemetry_path) |path| {
        const metadata = artifact_store.IndexMetadata{
            .started_wall_ns = persisted.started_wall_ns,
            .request_id = if (persisted.identity) |identity| identity.request_id[0..] else null,
            .snapshot_revision = if (persisted.identity) |identity| identity.snapshot_revision[0..] else null,
            .pipeline_admitted = persisted.pipelineAdmitted(),
            .failure_kind = @tagName(persisted.pipeline_failure),
        };
        if (artifact_store.persist(
            allocator,
            path,
            persisted.event_id,
            line,
            artifacts,
            metadata,
        )) |_| {
            line_owned = false; // returned to caller
            return line;
        } else |_| {
            allocator.free(line);
            line_owned = false;
            var failed = initial;
            failed.event_id = persisted.event_id;
            failed.telemetry_persisted = false;
            if (failed.pipeline_failure == .none) failed.pipeline_failure = .telemetry_not_persisted;
            return renderReceipt(allocator, failed);
        }
    }
    if (persisted.pipeline_failure == .none) persisted.pipeline_failure = .telemetry_not_persisted;
    persisted.telemetry_persisted = false;
    allocator.free(line);
    line_owned = false;
    return renderReceipt(allocator, persisted);
}

fn parseArgs(allocator: std.mem.Allocator, encoded: []const u8) !Args {
    var parsed = std.json.parseFromSlice(Args, allocator, encoded, .{
        .ignore_unknown_fields = false,
        .duplicate_field_behavior = .@"error",
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidArguments,
    };
    defer parsed.deinit();
    if (parsed.value.root_task_id == 0) return error.InvalidRootTaskId;
    return parsed.value;
}

fn measureFacts(graph: *const projection.Projection) Facts {
    var open_count: usize = 0;
    var claimed_count: usize = 0;
    var completed_count: usize = 0;
    var failed_count: usize = 0;
    var claimed_with_owner_count: usize = 0;
    var terminal_with_evidence_count: usize = 0;
    for (graph.tasks) |task| {
        switch (task.lifecycle) {
            .open => open_count += 1,
            .claimed => {
                claimed_count += 1;
                claimed_with_owner_count += 1;
            },
            .completed => {
                completed_count += 1;
                if (hasEvidence(graph, task.id)) terminal_with_evidence_count += 1;
            },
            .failed => {
                failed_count += 1;
                if (hasEvidence(graph, task.id)) terminal_with_evidence_count += 1;
            },
        }
    }
    return .{
        .schema_supported = true,
        .snapshot_bounded = true,
        .task_count = graph.tasks.len,
        .open_count = open_count,
        .claimed_count = claimed_count,
        .completed_count = completed_count,
        .failed_count = failed_count,
        .claimed_with_owner_count = claimed_with_owner_count,
        // parseSnapshot rejects disconnected hierarchy, bad references, and
        // truncated/over-budget snapshots before these facts can be emitted.
        .reachable_task_count = graph.tasks.len,
        .terminal_with_evidence_count = terminal_with_evidence_count,
        .invalid_reference_count = 0,
        .truncated = false,
        .proposal_bound = true,
        // task_audit is a read-only proposal.  These are true because its
        // mutation set is empty, not because Zig predicts a future migration.
        .preserves_tasks = true,
        .preserves_evidence = true,
        .preserves_recovery = true,
        .preserves_schema = true,
        .contradiction_safe = true,
        .reversible = true,
    };
}

fn hasEvidence(graph: *const projection.Projection, task_id: projection.TaskId) bool {
    for (graph.verified_by) |edge| if (edge.task == task_id) return true;
    return false;
}

fn buildProposal(allocator: std.mem.Allocator, root_task_id: u64, revision: [64]u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"schema_version\":\"{s}\",\"operation\":\"task_audit\",\"proposal_origin\":\"deterministic_zig_read_only_audit\",\"root_task_id\":{d},\"snapshot_revision\":\"{s}\",\"mutation\":\"none\"}}",
        .{ PROPOSAL_SCHEMA, root_task_id, revision[0..] },
    );
}

fn buildRequest(allocator: std.mem.Allocator, identity: AuditIdentity) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const writer = &out.writer;
    try writer.print(
        "{{\"schema_version\":\"{s}\",\"request_id\":\"{s}\",\"operation\":\"task_audit\",\"proposal_sha256\":\"{s}\",\"snapshot_sha256\":\"{s}\",\"snapshot_revision\":\"{s}\",\"expected_checker_version\":\"{s}\",\"facts\":{{",
        .{ runtime.REQUEST_SCHEMA, identity.request_id[0..], identity.proposal_sha256[0..], identity.snapshot_sha256[0..], identity.snapshot_revision[0..], runtime.CHECKER_VERSION },
    );
    try writeFacts(writer, identity.facts);
    try writer.writeAll("}}");
    return out.toOwnedSlice();
}

fn writeFacts(writer: *std.Io.Writer, facts: Facts) !void {
    try writer.print(
        "\"schema_supported\":{s},\"snapshot_bounded\":{s},\"task_count\":{d},\"open_count\":{d},\"claimed_count\":{d},\"completed_count\":{d},\"failed_count\":{d},\"claimed_with_owner_count\":{d},\"reachable_task_count\":{d},\"terminal_with_evidence_count\":{d},\"invalid_reference_count\":{d},\"truncated\":{s},\"proposal_bound\":{s},\"preserves_tasks\":{s},\"preserves_evidence\":{s},\"preserves_recovery\":{s},\"preserves_schema\":{s},\"contradiction_safe\":{s},\"reversible\":{s}",
        .{
            boolText(facts.schema_supported),   boolText(facts.snapshot_bounded), facts.task_count,
            facts.open_count,                   facts.claimed_count,              facts.completed_count,
            facts.failed_count,                 facts.claimed_with_owner_count,   facts.reachable_task_count,
            facts.terminal_with_evidence_count, facts.invalid_reference_count,    boolText(facts.truncated),
            boolText(facts.proposal_bound),     boolText(facts.preserves_tasks),  boolText(facts.preserves_evidence),
            boolText(facts.preserves_recovery), boolText(facts.preserves_schema), boolText(facts.contradiction_safe),
            boolText(facts.reversible),
        },
    );
}

fn renderReceipt(allocator: std.mem.Allocator, receipt: Receipt) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const writer = &out.writer;
    try writer.print(
        "{{\"schema_version\":\"{s}\",\"evidence_layer\":\"mechanism\",\"stage\":\"engineering_validation\",\"statistical_claim\":\"none\",\"operation\":\"task_audit\",\"artifact_bundle\":{{\"schema_version\":\"{s}\",\"event_id\":\"{s}\",\"authoritative_raw_evidence\":{s},\"persisted\":{s},\"index_schema\":\"{s}\",\"index_role\":\"best_effort_discovery_cache\"}},\"started_wall_ns\":{d},\"finished_wall_ns\":{d},\"monotonic_elapsed_ns\":{d},\"latency_boundary\":\"tool_entry_through_last_completed_gate_before_evidence_persistence\",\"phase_latency_ns\":{{\"snapshot_fetch\":{d},\"sensor\":{d}}},",
        .{
            RECEIPT_SCHEMA,
            artifact_store.BUNDLE_SCHEMA,
            receipt.event_id[0..],
            boolText(receipt.telemetry_persisted),
            boolText(receipt.telemetry_persisted),
            artifact_store.INDEX_SCHEMA,
            receipt.started_wall_ns,
            receipt.finished_wall_ns,
            receipt.monotonic_elapsed_ns,
            receipt.snapshot_fetch_elapsed_ns,
            receipt.sensor_elapsed_ns,
        },
    );
    try writer.writeAll("\"identity\":");
    if (receipt.identity) |identity| {
        try writer.print(
            "{{\"root_task_id\":{d},\"request_id\":\"{s}\",\"proposal_origin\":\"deterministic_zig_read_only_audit\",\"proposal_sha256\":\"{s}\",\"snapshot_sha256\":\"{s}\",\"snapshot_revision\":\"{s}\",\"snapshot_bytes\":{d},\"proposal_bytes\":{d},\"facts\":{{",
            .{ identity.root_task_id, identity.request_id[0..], identity.proposal_sha256[0..], identity.snapshot_sha256[0..], identity.snapshot_revision[0..], identity.snapshot_bytes, identity.proposal_bytes },
        );
        try writeFacts(writer, identity.facts);
        try writer.writeAll("}}");
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"checker\":");
    if (receipt.config) |config| {
        try writer.print(
            "{{\"expected_version\":\"{s}\",\"expected_sha256\":\"{s}\",\"execution_binding\":\"path_pre_hash_exec_path_post_hash\",\"same_user_swap_back_resistant\":false,",
            .{ runtime.CHECKER_VERSION, config.expected_sha256[0..] },
        );
        if (receipt.invocation) |invocation| {
            const has_actual_hash = invocation.checker_bytes != 0;
            try writer.writeAll("\"actual_sha256\":");
            if (has_actual_hash)
                try writer.print("\"{s}\"", .{invocation.actual_checker_sha256[0..]})
            else
                try writer.writeAll("null");
            try writer.print(
                ",\"binary_bytes\":{d},\"hash_elapsed_ns\":{d},\"post_hash_elapsed_ns\":{d},\"checker_elapsed_ns\":{d},\"input_bytes\":{d},\"stdout_bytes\":{d},\"stderr_bytes\":{d},\"exit_code\":",
                .{ invocation.checker_bytes, invocation.hash_elapsed_ns, invocation.post_hash_elapsed_ns, invocation.checker_elapsed_ns, invocation.input_bytes, invocation.stdout_bytes, invocation.stderr_bytes },
            );
            if (invocation.exit_code) |code| try writer.print("{d}", .{code}) else try writer.writeAll("null");
            try writer.writeAll(",\"verdict_sha256\":");
            if (invocation.verdict_sha256) |hash|
                try writer.print("\"{s}\"", .{hash[0..]})
            else
                try writer.writeAll("null");
            try writer.print(",\"runtime_failure_kind\":\"{s}\",\"cpu_time_ns\":\"not_measured\",\"peak_rss_bytes\":\"not_measured\"", .{@tagName(invocation.failure)});
        } else {
            try writer.writeAll("\"actual_sha256\":null,\"binary_bytes\":null,\"hash_elapsed_ns\":null,\"post_hash_elapsed_ns\":null,\"checker_elapsed_ns\":null,\"input_bytes\":null,\"stdout_bytes\":null,\"stderr_bytes\":null,\"exit_code\":null,\"verdict_sha256\":null,\"runtime_failure_kind\":null,\"cpu_time_ns\":\"not_measured\",\"peak_rss_bytes\":\"not_measured\"");
        }
        try writer.print(",\"provenance_elapsed_ns\":{d},\"provenance\":", .{receipt.provenance_elapsed_ns});
        if (receipt.provenance) |loaded| {
            try writer.print(
                "{{\"schema_version\":\"{s}\",\"manifest_sha256\":\"{s}\",\"kernel_source_sha256\":\"{s}\",\"memory_kernel_source_sha256\":\"{s}\",\"main_source_sha256\":\"{s}\",\"axiom_audit_source_sha256\":\"{s}\",\"axiom_policy\":\"propext,Quot.sound\",\"axiom_audit\":\"passed\",\"source_identity_claim\":\"builder_reported_manifest_unpinned\",\"host_os\":",
                .{ provenance.MANIFEST_SCHEMA, loaded.manifest_sha256[0..], loaded.kernel_source_sha256[0..], loaded.memory_kernel_source_sha256[0..], loaded.main_source_sha256[0..], loaded.axiom_audit_source_sha256[0..] },
            );
            try std.json.Stringify.encodeJsonString(loaded.host_os, .{}, writer);
            try writer.writeAll(",\"host_arch\":");
            try std.json.Stringify.encodeJsonString(loaded.host_arch, .{}, writer);
            try writer.writeAll(",\"linker\":");
            try std.json.Stringify.encodeJsonString(loaded.linker, .{}, writer);
            try writer.writeAll(",\"lean_version\":");
            try std.json.Stringify.encodeJsonString(loaded.lean_version, .{}, writer);
            try writer.writeAll(",\"built_at_utc\":");
            try std.json.Stringify.encodeJsonString(loaded.built_at_utc, .{}, writer);
            try writer.writeAll(",\"integrity_model\":\"hash_linked_not_signed\"}");
        } else {
            try writer.writeAll("null");
        }
        try writer.writeAll("}");
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"verdict\":");
    if (receipt.invocation) |invocation| {
        if (invocation.verdict) |verdict| switch (verdict.checks) {
            .task_audit => |checks| {
                try writer.print("{{\"checker_admitted\":{s},\"reason_codes\":[", .{boolText(verdict.admitted)});
                for (verdict.reasons, 0..) |reason, index| {
                    if (index != 0) try writer.writeAll(",");
                    try writer.print("\"{s}\"", .{@tagName(reason)});
                }
                try writer.print(
                    "],\"checks\":{{\"counts_consistent\":{s},\"claims_owned\":{s},\"hierarchy_recoverable\":{s},\"terminal_evidence_preserved\":{s},\"references_valid\":{s},\"preservation_obligations\":{s}}}}}",
                    .{ boolText(checks.counts_consistent), boolText(checks.claims_owned), boolText(checks.hierarchy_recoverable), boolText(checks.terminal_evidence_preserved), boolText(checks.references_valid), boolText(checks.preservation_obligations) },
                );
            },
            .memory_supersede_existing => try writer.writeAll("null"),
        } else {
            try writer.writeAll("null");
        }
    } else {
        try writer.writeAll("null");
    }
    try writer.print(
        ",\"pipeline\":{{\"admitted\":{s},\"failure_kind\":\"{s}\",\"source_error\":",
        .{ boolText(receipt.pipelineAdmitted()), @tagName(receipt.pipeline_failure) },
    );
    if (receipt.source_error) |name|
        try std.json.Stringify.encodeJsonString(name, .{}, writer)
    else
        try writer.writeAll("null");
    try writer.writeAll(",\"source_detail\":");
    if (receipt.source_detail) |detail|
        try std.json.Stringify.encodeJsonString(boundedUtf8(detail, 4096), .{}, writer)
    else
        try writer.writeAll("null");
    try writer.print(
        ",\"telemetry_schema\":\"{s}\",\"telemetry_configured\":{s},\"telemetry_persisted\":{s}}},",
        .{ TELEMETRY_SCHEMA, boolText(receipt.telemetry_configured), boolText(receipt.telemetry_persisted) },
    );
    try writer.writeAll(
        "\"transaction\":{\"proposal\":\"bound\",\"reobserve\":\"not_applicable_read_only\",\"cas\":\"not_applicable_read_only\",\"commit\":\"not_applicable_read_only\",\"rollback\":\"not_applicable_read_only\"}," ++
            "\"measurement_layers\":{\"mechanism\":\"recorded\",\"outcome\":\"not_measured\",\"trajectory\":\"not_measured\",\"evaluator\":\"not_applicable\"}," ++
            "\"checker_llm_usage\":{\"input_tokens\":0,\"output_tokens\":0,\"cost_usd\":0}," ++
            "\"enclosing_agent_usage\":\"not_attributed_by_tool\",\"paid_experiment_cost_usd\":\"not_attributed_by_tool\"}",
    );
    const owned = try out.toOwnedSlice();
    if (owned.len > MAX_RECEIPT_BYTES) {
        allocator.free(owned);
        return error.ReceiptTooLarge;
    }
    return owned;
}

fn resolveTelemetryPath(
    allocator: std.mem.Allocator,
    home_dir: []const u8,
    override: ?[]const u8,
) !?[]u8 {
    if (override) |path| {
        if (!std.fs.path.isAbsolute(path)) return null;
        return try allocator.dupe(u8, path);
    }
    if (std.c.getenv("METACODES_FORMAL_TELEMETRY_PATH")) |raw| {
        const path = std.mem.span(raw);
        if (!std.fs.path.isAbsolute(path) or path.len == 0) return null;
        return try allocator.dupe(u8, path);
    }
    if (home_dir.len == 0) return null;
    return try std.fmt.allocPrint(
        allocator,
        "{s}/.metacodes/research/formal-control/events-v1.jsonl",
        .{home_dir},
    );
}

fn sha256Hex(bytes: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

fn requestId(proposal_sha256: [64]u8, snapshot_sha256: [64]u8, revision: [64]u8) [64]u8 {
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update("metacodes-formal-request-id-v1\x00");
    hash.update(&proposal_sha256);
    hash.update(&snapshot_sha256);
    hash.update(&revision);
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

fn boolText(value: bool) []const u8 {
    return if (value) "true" else "false";
}

fn boundedUtf8(value: []const u8, max_bytes: usize) []const u8 {
    if (!std.unicode.utf8ValidateSlice(value)) return "[invalid UTF-8 source detail]";
    var end = @min(value.len, max_bytes);
    while (end > 0 and !std.unicode.utf8ValidateSlice(value[0..end])) end -= 1;
    return value[0..end];
}

fn elapsedSince(started: i128) u64 {
    const finished = time.nowNs();
    if (started <= 0 or finished <= started) return 0;
    return @intCast(@min(finished - started, std.math.maxInt(u64)));
}

test "formal receipts do not claim authoritative evidence before persistence" {
    const receipt = try renderReceipt(std.testing.allocator, .{
        .started_wall_ns = 1,
        .finished_wall_ns = 2,
        .pipeline_failure = .config_missing,
        .telemetry_configured = false,
        .telemetry_persisted = false,
    });
    defer std.testing.allocator.free(receipt);
    const Probe = struct {
        artifact_bundle: struct {
            authoritative_raw_evidence: bool,
            persisted: bool,
        },
        paid_experiment_cost_usd: []const u8,
    };
    var parsed = try std.json.parseFromSlice(Probe, std.testing.allocator, receipt, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expect(!parsed.value.artifact_bundle.authoritative_raw_evidence);
    try std.testing.expect(!parsed.value.artifact_bundle.persisted);
    try std.testing.expectEqualStrings("not_attributed_by_tool", parsed.value.paid_experiment_cost_usd);
}

test "formal source detail truncation preserves UTF-8 boundaries" {
    const text = "abc世界";
    try std.testing.expectEqualStrings("abc", boundedUtf8(text, 4));
    try std.testing.expectEqualStrings("abc世", boundedUtf8(text, 6));
}

const audit_fixture =
    \\{"schema_version":"tinykg-task-snapshot-v1","root_id":1,"revision":"0000000000000000000000000000000000000000000000000000000000000000","summary":{"task_count":2,"hierarchy_edge_count":1,"dependency_edge_count":0,"evidence_count":1,"verified_by_edge_count":1,"used_text_bytes":10,"truncated":false,"truncate_reason":null,"max_tasks":256,"max_edges":1024,"max_chars":200000},"tasks":[{"id":1,"status":"open","claimed_by":null,"text":"root"},{"id":2,"status":"completed","claimed_by":null,"text":"done"}],"hierarchy":[{"src":1,"rel":"contain","dst":2}],"dependencies":[],"evidence":[{"id":9,"kind":"verification","text":"ok"}],"verified_by":[{"src":2,"rel":"verified_by","dst":9}]}
;

test "task audit facts require evidence for every terminal task" {
    var graph = try projection.parseSnapshot(std.testing.allocator, projection.TaskId.fromInt(1), audit_fixture);
    defer graph.deinit();
    const facts = measureFacts(&graph);
    try std.testing.expectEqual(@as(usize, 2), facts.task_count);
    try std.testing.expectEqual(@as(usize, 1), facts.completed_count);
    try std.testing.expectEqual(@as(usize, 1), facts.terminal_with_evidence_count);
}

test "native formal task audit binds sidecar verdict and persists mechanism receipt" {
    const raw_path = std.c.getenv("METACODES_TEST_FORMAL_KERNEL_PATH") orelse return error.SkipZigTest;
    const raw_hash = std.c.getenv("METACODES_TEST_FORMAL_KERNEL_SHA256") orelse return error.SkipZigTest;
    const checker_path = std.mem.span(raw_path);
    const hash_text = std.mem.span(raw_hash);
    if (hash_text.len != 64) return error.SkipZigTest;
    var expected_sha256: [64]u8 = undefined;
    @memcpy(&expected_sha256, hash_text);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const telemetry_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/formal-events.jsonl", .{root_buffer[0..root_len]});
    defer std.testing.allocator.free(telemetry_path);
    const result = try auditSnapshot(
        std.testing.allocator,
        1,
        audit_fixture,
        .{ .checker_path = checker_path, .expected_sha256 = expected_sha256 },
        telemetry_path,
        null,
        time.nowWallNs(),
        time.nowNs(),
    );
    defer std.testing.allocator.free(result);

    const ReceiptProbe = struct {
        schema_version: []const u8,
        evidence_layer: []const u8,
        statistical_claim: []const u8,
        paid_experiment_cost_usd: []const u8,
        enclosing_agent_usage: []const u8,
        artifact_bundle: struct {
            schema_version: []const u8,
            event_id: []const u8,
            authoritative_raw_evidence: bool,
            persisted: bool,
            index_role: []const u8,
        },
        identity: struct {
            request_id: []const u8,
            proposal_sha256: []const u8,
            snapshot_sha256: []const u8,
            snapshot_revision: []const u8,
        },
        checker: struct {
            verdict_sha256: []const u8,
            provenance: struct { manifest_sha256: []const u8 },
        },
        pipeline: struct {
            admitted: bool,
            failure_kind: []const u8,
            telemetry_persisted: bool,
        },
        transaction: struct {
            reobserve: []const u8,
            cas: []const u8,
            rollback: []const u8,
        },
    };
    var parsed = try std.json.parseFromSlice(ReceiptProbe, std.testing.allocator, result, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expectEqualStrings(RECEIPT_SCHEMA, parsed.value.schema_version);
    try std.testing.expectEqualStrings("mechanism", parsed.value.evidence_layer);
    try std.testing.expectEqualStrings("none", parsed.value.statistical_claim);
    try std.testing.expectEqualStrings("not_attributed_by_tool", parsed.value.enclosing_agent_usage);
    try std.testing.expectEqualStrings("not_attributed_by_tool", parsed.value.paid_experiment_cost_usd);
    try std.testing.expectEqualStrings(artifact_store.BUNDLE_SCHEMA, parsed.value.artifact_bundle.schema_version);
    try std.testing.expectEqualStrings("best_effort_discovery_cache", parsed.value.artifact_bundle.index_role);
    try std.testing.expect(parsed.value.artifact_bundle.authoritative_raw_evidence);
    try std.testing.expect(parsed.value.artifact_bundle.persisted);
    try std.testing.expect(parsed.value.pipeline.admitted);
    try std.testing.expectEqualStrings("none", parsed.value.pipeline.failure_kind);
    try std.testing.expect(parsed.value.pipeline.telemetry_persisted);
    try std.testing.expectEqualStrings("not_applicable_read_only", parsed.value.transaction.reobserve);
    try std.testing.expectEqualStrings("not_applicable_read_only", parsed.value.transaction.cas);
    try std.testing.expectEqualStrings("not_applicable_read_only", parsed.value.transaction.rollback);

    const index_bytes = try readSmallFile(std.testing.allocator, telemetry_path);
    defer std.testing.allocator.free(index_bytes);
    try std.testing.expectEqual(@as(u8, '\n'), index_bytes[index_bytes.len - 1]);
    const IndexProbe = struct {
        schema_version: []const u8,
        event_id: []const u8,
        bundle_rel: []const u8,
        bundle_schema: []const u8,
        manifest_sha256: []const u8,
        receipt_sha256: []const u8,
        started_wall_ns: i128,
        request_id: []const u8,
        snapshot_revision: []const u8,
        pipeline_admitted: bool,
        failure_kind: []const u8,
    };
    var index = try std.json.parseFromSlice(
        IndexProbe,
        std.testing.allocator,
        std.mem.trim(u8, index_bytes, "\r\n"),
        .{ .ignore_unknown_fields = false },
    );
    defer index.deinit();
    try std.testing.expectEqualStrings(artifact_store.INDEX_SCHEMA, index.value.schema_version);
    try std.testing.expectEqualStrings(artifact_store.BUNDLE_SCHEMA, index.value.bundle_schema);
    try std.testing.expectEqualStrings(parsed.value.artifact_bundle.event_id, index.value.event_id);
    try std.testing.expectEqualStrings(parsed.value.identity.request_id, index.value.request_id);
    try std.testing.expectEqualStrings(parsed.value.identity.snapshot_revision, index.value.snapshot_revision);
    try std.testing.expect(index.value.pipeline_admitted);
    const receipt_hash = artifact_store.sha256Hex(result);
    try std.testing.expectEqualStrings(receipt_hash[0..], index.value.receipt_sha256);

    const bundle_dir = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}/{s}",
        .{ root_buffer[0..root_len], index.value.bundle_rel },
    );
    defer std.testing.allocator.free(bundle_dir);
    const receipt_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/receipt.json", .{bundle_dir});
    defer std.testing.allocator.free(receipt_path);
    const stored_receipt = try readSmallFile(std.testing.allocator, receipt_path);
    defer std.testing.allocator.free(stored_receipt);
    try std.testing.expectEqualStrings(result, stored_receipt);

    const artifact_expectations = [_]struct { name: []const u8, expected_hash: ?[]const u8 }{
        .{ .name = "snapshot-source.bin", .expected_hash = null },
        .{ .name = "snapshot.json", .expected_hash = parsed.value.identity.snapshot_sha256 },
        .{ .name = "proposal.json", .expected_hash = parsed.value.identity.proposal_sha256 },
        .{ .name = "request.json", .expected_hash = null },
        .{ .name = "verdict.json", .expected_hash = parsed.value.checker.verdict_sha256 },
        .{ .name = "checker-stdout.bin", .expected_hash = null },
        .{ .name = "checker-stderr.bin", .expected_hash = null },
        .{ .name = "checker-provenance.json", .expected_hash = parsed.value.checker.provenance.manifest_sha256 },
        .{ .name = "manifest.json", .expected_hash = index.value.manifest_sha256 },
    };
    for (artifact_expectations) |expectation| {
        const path = try std.fmt.allocPrint(std.testing.allocator, "{s}/{s}", .{ bundle_dir, expectation.name });
        defer std.testing.allocator.free(path);
        const bytes = try readSmallFile(std.testing.allocator, path);
        defer std.testing.allocator.free(bytes);
        if (expectation.expected_hash) |expected| {
            const actual = artifact_store.sha256Hex(bytes);
            try std.testing.expectEqualStrings(expected, actual[0..]);
        }
    }
    const manifest_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/manifest.json", .{bundle_dir});
    defer std.testing.allocator.free(manifest_path);
    const manifest_bytes = try readSmallFile(std.testing.allocator, manifest_path);
    defer std.testing.allocator.free(manifest_bytes);
    const ManifestProbe = struct {
        schema_version: []const u8,
        event_id: []const u8,
        completion_marker: bool,
        files: []const struct { name: []const u8, bytes: usize, sha256: []const u8 },
    };
    var manifest = try std.json.parseFromSlice(ManifestProbe, std.testing.allocator, manifest_bytes, .{ .ignore_unknown_fields = true });
    defer manifest.deinit();
    try std.testing.expectEqualStrings(artifact_store.BUNDLE_SCHEMA, manifest.value.schema_version);
    try std.testing.expectEqualStrings(index.value.event_id, manifest.value.event_id);
    try std.testing.expect(manifest.value.completion_marker);
    try std.testing.expectEqual(@as(usize, 9), manifest.value.files.len);
    for (manifest.value.files) |record| {
        const path = try std.fmt.allocPrint(std.testing.allocator, "{s}/{s}", .{ bundle_dir, record.name });
        defer std.testing.allocator.free(path);
        const bytes = try readSmallFile(std.testing.allocator, path);
        defer std.testing.allocator.free(bytes);
        try std.testing.expectEqual(record.bytes, bytes.len);
        const actual = artifact_store.sha256Hex(bytes);
        try std.testing.expectEqualStrings(record.sha256, actual[0..]);
    }

    var tampered_hash = expected_sha256;
    tampered_hash[0] = if (tampered_hash[0] == '0') '1' else '0';
    const blocked = try auditSnapshot(
        std.testing.allocator,
        1,
        audit_fixture,
        .{ .checker_path = checker_path, .expected_sha256 = tampered_hash },
        telemetry_path,
        null,
        time.nowWallNs(),
        time.nowNs(),
    );
    defer std.testing.allocator.free(blocked);
    const BlockedProbe = struct {
        checker: struct { runtime_failure_kind: []const u8 },
        pipeline: struct { admitted: bool, failure_kind: []const u8, telemetry_persisted: bool },
    };
    var blocked_parsed = try std.json.parseFromSlice(BlockedProbe, std.testing.allocator, blocked, .{ .ignore_unknown_fields = true });
    defer blocked_parsed.deinit();
    try std.testing.expect(!blocked_parsed.value.pipeline.admitted);
    try std.testing.expectEqualStrings("runtime_failure", blocked_parsed.value.pipeline.failure_kind);
    try std.testing.expectEqualStrings("checker_hash_mismatch", blocked_parsed.value.checker.runtime_failure_kind);
    try std.testing.expect(blocked_parsed.value.pipeline.telemetry_persisted);
}

fn readSmallFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const fd = pfs.open(path_z.ptr, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true }, 0);
    if (fd < 0) return error.FileNotFound;
    defer _ = pfs.close(fd);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var buffer: [4096]u8 = undefined;
    while (true) {
        const count = try pfs.readZ(fd, &buffer);
        if (count == 0) break;
        if (out.items.len + count > MAX_RECEIPT_BYTES) return error.FileTooLarge;
        try out.appendSlice(allocator, buffer[0..count]);
    }
    return out.toOwnedSlice(allocator);
}
