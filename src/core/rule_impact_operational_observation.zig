//! Post-Run, host-derived operational observer for an active project rule bundle.
//!
//! This artifact is deliberately not a RuleImpact label receipt. It contains
//! only facts reproducible from the durable tool-observation journal and fixes
//! all outcome/usage authentication and promotion flags to false. A completed
//! Run, including one ending in `end_turn`, is never interpreted as task
//! success. Authenticated outcome and provider-usage evidence must continue to
//! enter through `rule_impact_receipt.zig` before Lean may authorize promotion.

const std = @import("std");
const pfs = @import("platform").fs;
const observation = @import("../tools/observation.zig");
const journal_mod = @import("tool_observation_journal.zig");
const impact = @import("rule_impact_stats.zig");
const bundle = @import("project_rule_bundle.zig");
const session_id_mod = @import("session_id.zig");

pub const SCHEMA_VERSION = "metacodes-rule-impact-operational-observation-v1";
pub const FILE_PREFIX = "rule-impact-operational-observation-";
pub const MAX_RECORD_BYTES: usize = 4 * 1024 * 1024;

pub const ActiveIdentity = struct {
    project_sha256: [64]u8,
    bundle_sha256: [64]u8,
    bundle_revision: u64,
};

pub const Input = struct {
    session_dir: []const u8,
    observation: journal_mod.RunBinding,
    active: ActiveIdentity,
};

pub const PersistResult = struct {
    observation_id: [64]u8,
    created: bool,
};

pub const Loaded = struct {
    arena: std.heap.ArenaAllocator,
    observation_id: [64]u8,
    active: ActiveIdentity,
    observation: journal_mod.RunBinding,
    interval_sha256: [64]u8,
    stop_reason: []const u8,
    snapshot: impact.Snapshot,
    record_bytes: usize,

    pub fn deinit(self: *Loaded) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

const WireRun = struct {
    session_id: []const u8,
    run_id: []const u8,
    first_sequence: u64,
    last_sequence: u64,
    interval_sha256: []const u8,
    stop_reason: []const u8,
};

const WireBody = struct {
    schema_version: []const u8 = SCHEMA_VERSION,
    project_sha256: []const u8,
    bundle_sha256: []const u8,
    bundle_revision: u64,
    observation: WireRun,
    operational_snapshot: impact.Snapshot,
    semantic_outcome_authenticated: bool = false,
    usage_authenticated: bool = false,
    promotion_evidence: bool = false,
};

const WireRecord = struct {
    observation_id: []const u8,
    body: WireBody,
};

/// Derive, persist, reopen and rederive one observer artifact. Returning only
/// after the second derivation makes `RunControl.finishRun` a real fail-closed
/// publication boundary rather than a best-effort logger.
pub fn persist(input: Input) !PersistResult {
    try validateActive(input.active);
    var run = try journal_mod.loadRunDispatches(
        std.heap.c_allocator,
        input.session_dir,
        input.observation,
    );
    defer run.deinit();
    try validateRunIdentity(&run, input.active);
    var snapshot = try impact.derive(std.heap.c_allocator, &run, .{});
    defer snapshot.deinit(std.heap.c_allocator);
    try validateOperationalSnapshot(snapshot, run.interval_sha256);
    const body = WireBody{
        .project_sha256 = input.active.project_sha256[0..],
        .bundle_sha256 = input.active.bundle_sha256[0..],
        .bundle_revision = input.active.bundle_revision,
        .observation = .{
            .session_id = input.observation.session_id.asSlice(),
            .run_id = input.observation.run_id.asSlice(),
            .first_sequence = input.observation.first_sequence,
            .last_sequence = input.observation.last_sequence,
            .interval_sha256 = run.interval_sha256[0..],
            .stop_reason = run.stop_reason,
        },
        .operational_snapshot = snapshot,
    };
    const result = try persistBody(input.session_dir, body);
    var reopened = try loadBound(
        std.heap.c_allocator,
        input.session_dir,
        result.observation_id,
        input.active,
    );
    reopened.deinit();
    return result;
}

/// Reopen the content-addressed artifact and its exact Run, then compare the
/// stored operational fold to a fresh deterministic fold. This rejects file
/// tamper, stale run binding and journal-to-receipt semantic drift.
pub fn loadBound(
    allocator: std.mem.Allocator,
    session_dir: []const u8,
    observation_id: [64]u8,
    expected_active: ActiveIdentity,
) !Loaded {
    try validateActive(expected_active);
    var loaded = try load(allocator, session_dir, observation_id);
    errdefer loaded.deinit();
    if (!std.meta.eql(loaded.active, expected_active)) return error.ActiveIdentityMismatch;

    var run = try journal_mod.loadRunDispatches(allocator, session_dir, loaded.observation);
    defer run.deinit();
    try validateRunIdentity(&run, loaded.active);
    if (!std.mem.eql(u8, &run.interval_sha256, &loaded.interval_sha256) or
        !std.mem.eql(u8, run.stop_reason, loaded.stop_reason))
        return error.ObservationIntervalMismatch;
    var derived = try impact.derive(allocator, &run, .{});
    defer derived.deinit(allocator);
    try validateOperationalSnapshot(derived, run.interval_sha256);
    const stored_json = try impact.render(allocator, loaded.snapshot);
    defer allocator.free(stored_json);
    const derived_json = try impact.render(allocator, derived);
    defer allocator.free(derived_json);
    if (!std.mem.eql(u8, stored_json, derived_json)) return error.OperationalSnapshotMismatch;
    return loaded;
}

/// Promotion and ontology-to-rule generation must not consume this artifact as
/// authenticated RuleImpact. This conversion is useful only as a Lean/runtime
/// observer: all labels and evidence bindings remain explicitly unknown.
pub fn deriveOperationalSnapshot(
    allocator: std.mem.Allocator,
    session_dir: []const u8,
    observation_id: [64]u8,
    expected_active: ActiveIdentity,
) !impact.Snapshot {
    var loaded = try loadBound(allocator, session_dir, observation_id, expected_active);
    defer loaded.deinit();
    const rules = try allocator.dupe(impact.RuleStats, loaded.snapshot.rules);
    return .{
        .source_interval_sha256 = loaded.snapshot.source_interval_sha256,
        .formal_decisions = loaded.snapshot.formal_decisions,
        .formal_faults = loaded.snapshot.formal_faults,
        .exact_edit_recovery_directions = loaded.snapshot.exact_edit_recovery_directions,
        .exact_edit_recovery_pre_admits = loaded.snapshot.exact_edit_recovery_pre_admits,
        .exact_edit_recovery_pre_blocks = loaded.snapshot.exact_edit_recovery_pre_blocks,
        .exact_edit_recovery_post_admits = loaded.snapshot.exact_edit_recovery_post_admits,
        .exact_edit_recovery_post_blocks = loaded.snapshot.exact_edit_recovery_post_blocks,
        .physical_checker_calls = loaded.snapshot.physical_checker_calls,
        .checker_elapsed_ns = loaded.snapshot.checker_elapsed_ns,
        .authoritative_dispatches = loaded.snapshot.authoritative_dispatches,
        .authoritative_successes = loaded.snapshot.authoritative_successes,
        .authoritative_non_successes = loaded.snapshot.authoritative_non_successes,
        .speculative_dispatches = loaded.snapshot.speculative_dispatches,
        .realized_file_changes = loaded.snapshot.realized_file_changes,
        .invalid_effects = loaded.snapshot.invalid_effects,
        .reobservation_failures = loaded.snapshot.reobservation_failures,
        .enforced_pre_blocks_before_dispatch = loaded.snapshot.enforced_pre_blocks_before_dispatch,
        .enforced_pre_faults_before_dispatch = loaded.snapshot.enforced_pre_faults_before_dispatch,
        .shadow_pre_blocks_followed_by_dispatch = loaded.snapshot.shadow_pre_blocks_followed_by_dispatch,
        .shadow_pre_faults_followed_by_dispatch = loaded.snapshot.shadow_pre_faults_followed_by_dispatch,
        .subsequent_authoritative_successes = loaded.snapshot.subsequent_authoritative_successes,
        .labels = .{},
        .evidence = .{},
        .rules = rules,
    };
}

fn load(
    allocator: std.mem.Allocator,
    session_dir: []const u8,
    observation_id: [64]u8,
) !Loaded {
    if (!validNonzeroLowerHex64(observation_id)) return error.InvalidObservationId;
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    const path = try std.fmt.allocPrint(a, "{s}/{s}{s}.json", .{
        session_dir, FILE_PREFIX, observation_id[0..],
    });
    const raw = try readBounded(a, path, MAX_RECORD_BYTES);
    if (raw.len < 2 or raw[raw.len - 1] != '\n') return error.InvalidObservation;
    const record = std.json.parseFromSliceLeaky(WireRecord, a, raw[0 .. raw.len - 1], .{
        .ignore_unknown_fields = false,
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidObservation,
    };
    const parsed_id = parseLowerHex64(record.observation_id) orelse
        return error.InvalidObservation;
    const active = ActiveIdentity{
        .project_sha256 = parseLowerHex64(record.body.project_sha256) orelse
            return error.InvalidObservation,
        .bundle_sha256 = parseLowerHex64(record.body.bundle_sha256) orelse
            return error.InvalidObservation,
        .bundle_revision = record.body.bundle_revision,
    };
    const interval = parseLowerHex64(record.body.observation.interval_sha256) orelse
        return error.InvalidObservation;
    const session_id = session_id_mod.SessionId.fromSlice(record.body.observation.session_id) orelse
        return error.InvalidObservation;
    const run_id = session_id_mod.SessionId.fromSlice(record.body.observation.run_id) orelse
        return error.InvalidObservation;
    if (!std.mem.eql(u8, &parsed_id, &observation_id) or
        !std.mem.eql(u8, record.body.schema_version, SCHEMA_VERSION) or
        record.body.semantic_outcome_authenticated or record.body.usage_authenticated or
        record.body.promotion_evidence or
        record.body.observation.first_sequence > record.body.observation.last_sequence or
        record.body.observation.stop_reason.len == 0)
        return error.InvalidObservation;
    try validateActive(active);
    try validateOperationalSnapshot(record.body.operational_snapshot, interval);
    const body_json = try std.json.Stringify.valueAlloc(a, record.body, .{});
    if (!std.mem.eql(u8, &observation.sha256Hex(body_json), &observation_id))
        return error.ObservationHashMismatch;
    return .{
        .arena = arena,
        .observation_id = observation_id,
        .active = active,
        .observation = .{
            .session_id = session_id,
            .run_id = run_id,
            .first_sequence = record.body.observation.first_sequence,
            .last_sequence = record.body.observation.last_sequence,
        },
        .interval_sha256 = interval,
        .stop_reason = record.body.observation.stop_reason,
        .snapshot = record.body.operational_snapshot,
        .record_bytes = raw.len,
    };
}

fn persistBody(session_dir: []const u8, body: WireBody) !PersistResult {
    const body_json = try std.json.Stringify.valueAlloc(std.heap.c_allocator, body, .{});
    defer std.heap.c_allocator.free(body_json);
    const observation_id = observation.sha256Hex(body_json);
    const record_json = try std.json.Stringify.valueAlloc(std.heap.c_allocator, WireRecord{
        .observation_id = observation_id[0..],
        .body = body,
    }, .{});
    defer std.heap.c_allocator.free(record_json);
    if (record_json.len + 1 > MAX_RECORD_BYTES) return error.RecordTooLarge;
    var path_buffer: [std.fs.max_path_bytes + 1]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}/{s}{s}.json\x00", .{
        session_dir, FILE_PREFIX, observation_id[0..],
    });
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
        return .{ .observation_id = observation_id, .created = true };
    }
    const existing = try readBounded(
        std.heap.c_allocator,
        path[0 .. path.len - 1],
        MAX_RECORD_BYTES,
    );
    defer std.heap.c_allocator.free(existing);
    if (existing.len != record_json.len + 1 or
        !std.mem.eql(u8, existing[0..record_json.len], record_json) or
        existing[record_json.len] != '\n')
        return error.ObservationCollision;
    return .{ .observation_id = observation_id, .created = false };
}

fn validateActive(active: ActiveIdentity) !void {
    if (!validNonzeroLowerHex64(active.project_sha256) or
        !validNonzeroLowerHex64(active.bundle_sha256) or active.bundle_revision == 0)
        return error.InvalidActiveIdentity;
}

fn validateRunIdentity(run: *const journal_mod.LoadedRunDispatches, active: ActiveIdentity) !void {
    for (run.formal_decisions) |decision| {
        if (!std.mem.eql(u8, &decision.project_sha256, &active.project_sha256) or
            !std.mem.eql(u8, &decision.bundle_sha256, &active.bundle_sha256) or
            decision.bundle_revision != active.bundle_revision)
            return error.FormalDecisionBundleMismatch;
    }
    for (run.rule_filters) |filter| {
        if (!std.mem.eql(u8, &filter.project_sha256, &active.project_sha256) or
            !std.mem.eql(u8, &filter.bundle_sha256, &active.bundle_sha256) or
            filter.bundle_revision != active.bundle_revision)
            return error.FormalDecisionBundleMismatch;
    }
}

fn validateOperationalSnapshot(snapshot: impact.Snapshot, interval: [64]u8) !void {
    if (!std.mem.eql(u8, snapshot.schema_version, impact.SCHEMA_VERSION) or
        !std.mem.eql(u8, &snapshot.source_interval_sha256, &interval) or
        snapshot.labels.outcome_source != .unknown or snapshot.labels.task_success != null or
        snapshot.labels.trustworthy_success != null or snapshot.labels.drift_detected != null or
        snapshot.labels.cost_microusd != null or snapshot.labels.metered_tokens != null or
        snapshot.labels.provider_requests != null or snapshot.labels.input_tokens != null or
        snapshot.labels.output_tokens != null or snapshot.labels.cache_read_tokens != null or
        snapshot.labels.cache_write_tokens != null or snapshot.labels.wall_elapsed_ns != null or
        snapshot.labels.false_interventions != null or snapshot.labels.regressions != null or
        snapshot.evidence.authenticated)
        return error.SemanticEvidencePresent;
    if (!allZero(snapshot.evidence.label_receipt_sha256) or
        !allZero(snapshot.evidence.outcome_evidence_sha256) or
        !allZero(snapshot.evidence.usage_evidence_sha256))
        return error.SemanticEvidencePresent;
}

fn readBounded(allocator: std.mem.Allocator, path: []const u8, maximum: usize) ![]u8 {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const fd = pfs.open(path_z.ptr, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true }, 0);
    if (fd < 0) return error.OpenFailed;
    defer _ = pfs.close(fd);
    const before = pfs.fileInfo(fd) catch return error.StatFailed;
    if (!before.is_regular or before.link_count != 1 or before.size == 0 or
        before.size > maximum or
        (@import("builtin").os.tag != .windows and (before.mode & 0o077) != 0))
        return error.InvalidFile;
    const bytes = try allocator.alloc(u8, @intCast(before.size));
    errdefer allocator.free(bytes);
    var offset: usize = 0;
    while (offset < bytes.len) {
        const count = pfs.read(fd, bytes[offset..]);
        if (count <= 0) return error.ReadFailed;
        offset += @intCast(count);
    }
    const after = pfs.fileInfo(fd) catch return error.StatFailed;
    if (!after.is_regular or after.link_count != 1 or after.size != before.size or
        after.device != before.device or after.inode != before.inode)
        return error.ChangedDuringRead;
    return bytes;
}

fn validNonzeroLowerHex64(value: [64]u8) bool {
    return parseLowerHex64(value[0..]) != null and !allZero(value);
}

fn parseLowerHex64(value: []const u8) ?[64]u8 {
    if (value.len != 64) return null;
    var result: [64]u8 = undefined;
    for (value, 0..) |byte, index| {
        if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return null;
        result[index] = byte;
    }
    return result;
}

fn allZero(value: [64]u8) bool {
    for (value) |byte| if (byte != '0') return false;
    return true;
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

comptime {
    // The operational observer cannot silently grow beyond the already
    // bounded active bundle. This also bounds JSON size and re-derivation work.
    std.debug.assert(bundle.MAX_RULES <= 1024);
}
