//! Host-issued, content-addressed labels for one completed RuleImpact window.
//!
//! The tool-observation journal remains the operational source of truth. This
//! receipt binds semantic outcome and provider-usage observations to the exact
//! completed Run interval and to separately persisted evidence artifacts. It
//! grants no promotion authority; the fixed Lean governance kernel consumes the
//! resulting authenticated Snapshot before any lifecycle transition.

const std = @import("std");
const pfs = @import("platform").fs;
const observation = @import("../tools/observation.zig");
const journal_mod = @import("tool_observation_journal.zig");
const impact = @import("rule_impact_stats.zig");
const evidence = @import("rule_impact_evidence.zig");
const session_id_mod = @import("session_id.zig");

pub const SCHEMA_VERSION = "metacodes-rule-impact-label-receipt-v1";
pub const FILE_PREFIX = "rule-impact-label-receipt-";
pub const MAX_RECORD_BYTES: usize = 64 * 1024;
pub const OutcomeSource = evidence.OutcomeSource;

pub const Input = struct {
    project_sha256: [64]u8,
    issuer_sha256: [64]u8,
    observation: journal_mod.RunBinding,
    outcome_evidence_name: []const u8,
    usage_evidence_name: []const u8,
};

pub const PersistResult = struct {
    receipt_id: [64]u8,
    created: bool,
};

pub const Loaded = struct {
    arena: std.heap.ArenaAllocator,
    receipt_id: [64]u8,
    project_sha256: [64]u8,
    issuer_sha256: [64]u8,
    observation: journal_mod.RunBinding,
    interval_sha256: [64]u8,
    outcome_evidence_name: []const u8,
    outcome_evidence_sha256: [64]u8,
    usage_evidence_name: []const u8,
    usage_evidence_sha256: [64]u8,
    labels: impact.RunLabels,

    pub fn deinit(self: *Loaded) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const AuthenticatedSnapshot = struct {
    snapshot: impact.Snapshot,
    project_sha256: [64]u8,
    issuer_sha256: [64]u8,
    observation: journal_mod.RunBinding,

    pub fn deinit(self: *AuthenticatedSnapshot, allocator: std.mem.Allocator) void {
        self.snapshot.deinit(allocator);
        self.* = undefined;
    }
};

const WireRun = struct {
    session_id: []const u8,
    run_id: []const u8,
    first_sequence: u64,
    last_sequence: u64,
    interval_sha256: []const u8,
};

const WireBody = struct {
    schema_version: []const u8 = SCHEMA_VERSION,
    project_sha256: []const u8,
    issuer_sha256: []const u8,
    issued_by_host: bool = true,
    observation: WireRun,
    outcome_source: OutcomeSource,
    task_success: bool,
    trustworthy_success: bool,
    drift_detected: bool,
    false_interventions: u64,
    regressions: u64,
    outcome_evidence_name: []const u8,
    outcome_evidence_sha256: []const u8,
    usage_evidence_name: []const u8,
    usage_evidence_sha256: []const u8,
    provider_requests: u64,
    input_tokens: u64,
    output_tokens: u64,
    cache_read_tokens: u64,
    cache_write_tokens: u64,
    metered_tokens: u64,
    cost_microusd: u64,
    wall_elapsed_ns: u64,
};

const WireRecord = struct {
    receipt_id: []const u8,
    body: WireBody,
};

const RawRecord = struct {
    receipt_id: []const u8,
    body: WireBody,
};

pub fn persist(session_dir: []const u8, input: Input) !PersistResult {
    if (!validNonzeroLowerHex64(input.project_sha256) or
        !validNonzeroLowerHex64(input.issuer_sha256))
        return error.InvalidIdentity;
    try evidence.validateEvidenceName(input.outcome_evidence_name);
    try evidence.validateEvidenceName(input.usage_evidence_name);
    if (std.mem.eql(u8, input.outcome_evidence_name, input.usage_evidence_name))
        return error.EvidenceAliasing;

    const validated = try journal_mod.validateRunBinding(session_dir, input.observation);
    if (!validated.summary.complete) return error.ObservationJournalIncomplete;
    const expected = evidence.Binding{
        .project_sha256 = input.project_sha256,
        .issuer_sha256 = input.issuer_sha256,
        .observation = input.observation,
        .interval_sha256 = validated.interval_sha256,
    };
    const outcome = try evidence.loadOutcome(
        std.heap.c_allocator,
        session_dir,
        input.outcome_evidence_name,
        expected,
    );
    const usage = try evidence.loadUsage(
        std.heap.c_allocator,
        session_dir,
        input.usage_evidence_name,
        expected,
    );
    const body = WireBody{
        .project_sha256 = input.project_sha256[0..],
        .issuer_sha256 = input.issuer_sha256[0..],
        .observation = .{
            .session_id = input.observation.session_id.asSlice(),
            .run_id = input.observation.run_id.asSlice(),
            .first_sequence = input.observation.first_sequence,
            .last_sequence = input.observation.last_sequence,
            .interval_sha256 = validated.interval_sha256[0..],
        },
        .outcome_source = outcome.outcome_source,
        .task_success = outcome.task_success,
        .trustworthy_success = outcome.trustworthy_success,
        .drift_detected = outcome.drift_detected,
        .false_interventions = outcome.false_interventions,
        .regressions = outcome.regressions,
        .outcome_evidence_name = input.outcome_evidence_name,
        .outcome_evidence_sha256 = &outcome.sha256,
        .usage_evidence_name = input.usage_evidence_name,
        .usage_evidence_sha256 = &usage.sha256,
        .provider_requests = usage.provider_requests,
        .input_tokens = usage.input_tokens,
        .output_tokens = usage.output_tokens,
        .cache_read_tokens = usage.cache_read_tokens,
        .cache_write_tokens = usage.cache_write_tokens,
        .metered_tokens = usage.metered_tokens,
        .cost_microusd = usage.cost_microusd,
        .wall_elapsed_ns = usage.wall_elapsed_ns,
    };
    return persistBody(session_dir, body);
}

/// Reopen the receipt, completed journal interval, and both evidence artifacts.
/// A caller-supplied receipt id alone is never accepted as authenticated input.
pub fn loadBound(
    allocator: std.mem.Allocator,
    session_dir: []const u8,
    receipt_id: [64]u8,
) !Loaded {
    var loaded = try load(allocator, session_dir, receipt_id);
    errdefer loaded.deinit();
    const validated = try journal_mod.validateRunBinding(session_dir, loaded.observation);
    if (!validated.summary.complete or
        !std.mem.eql(u8, &validated.interval_sha256, &loaded.interval_sha256))
        return error.ObservationIntervalMismatch;
    const expected = evidence.Binding{
        .project_sha256 = loaded.project_sha256,
        .issuer_sha256 = loaded.issuer_sha256,
        .observation = loaded.observation,
        .interval_sha256 = loaded.interval_sha256,
    };
    const outcome = try evidence.loadOutcome(
        allocator,
        session_dir,
        loaded.outcome_evidence_name,
        expected,
    );
    const usage = try evidence.loadUsage(
        allocator,
        session_dir,
        loaded.usage_evidence_name,
        expected,
    );
    if (!std.mem.eql(u8, &outcome.sha256, &loaded.outcome_evidence_sha256) or
        !std.mem.eql(u8, &usage.sha256, &loaded.usage_evidence_sha256) or
        !labelsMatchEvidence(loaded.labels, outcome, usage))
        return error.EvidenceChanged;
    return loaded;
}

pub fn deriveImpact(
    allocator: std.mem.Allocator,
    session_dir: []const u8,
    receipt_id: [64]u8,
) !AuthenticatedSnapshot {
    var receipt = try loadBound(allocator, session_dir, receipt_id);
    defer receipt.deinit();
    var run = try journal_mod.loadRunDispatches(allocator, session_dir, receipt.observation);
    defer run.deinit();
    if (!std.mem.eql(u8, &run.interval_sha256, &receipt.interval_sha256))
        return error.ObservationIntervalMismatch;
    const snapshot = try impact.deriveBound(allocator, &run, receipt.labels, .{
        .authenticated = true,
        .label_receipt_sha256 = receipt.receipt_id,
        .outcome_evidence_sha256 = receipt.outcome_evidence_sha256,
        .usage_evidence_sha256 = receipt.usage_evidence_sha256,
    });
    return .{
        .snapshot = snapshot,
        .project_sha256 = receipt.project_sha256,
        .issuer_sha256 = receipt.issuer_sha256,
        .observation = receipt.observation,
    };
}

fn load(allocator: std.mem.Allocator, session_dir: []const u8, receipt_id: [64]u8) !Loaded {
    if (!validNonzeroLowerHex64(receipt_id)) return error.InvalidReceiptId;
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    const path = try std.fmt.allocPrint(a, "{s}/{s}{s}.json", .{
        session_dir, FILE_PREFIX, receipt_id[0..],
    });
    const raw = try readBounded(a, path, MAX_RECORD_BYTES);
    if (raw.len < 2 or raw[raw.len - 1] != '\n') return error.InvalidReceipt;
    const record = std.json.parseFromSliceLeaky(RawRecord, a, raw[0 .. raw.len - 1], .{
        .ignore_unknown_fields = false,
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidReceipt,
    };
    const parsed_id = parseLowerHex64(record.receipt_id) orelse return error.InvalidReceipt;
    const project = parseLowerHex64(record.body.project_sha256) orelse return error.InvalidReceipt;
    const issuer = parseLowerHex64(record.body.issuer_sha256) orelse return error.InvalidReceipt;
    const interval = parseLowerHex64(record.body.observation.interval_sha256) orelse
        return error.InvalidReceipt;
    const outcome_sha = parseLowerHex64(record.body.outcome_evidence_sha256) orelse
        return error.InvalidReceipt;
    const usage_sha = parseLowerHex64(record.body.usage_evidence_sha256) orelse
        return error.InvalidReceipt;
    const sid = session_id_mod.SessionId.fromSlice(record.body.observation.session_id) orelse
        return error.InvalidReceipt;
    const run_id = session_id_mod.SessionId.fromSlice(record.body.observation.run_id) orelse
        return error.InvalidReceipt;
    try evidence.validateEvidenceName(record.body.outcome_evidence_name);
    try evidence.validateEvidenceName(record.body.usage_evidence_name);
    if (!std.mem.eql(u8, record.body.schema_version, SCHEMA_VERSION) or
        !record.body.issued_by_host or !std.mem.eql(u8, &parsed_id, &receipt_id) or
        isZeroHex(project) or isZeroHex(issuer) or isZeroHex(interval) or
        isZeroHex(outcome_sha) or isZeroHex(usage_sha) or
        std.mem.eql(u8, record.body.outcome_evidence_name, record.body.usage_evidence_name) or
        record.body.observation.first_sequence > record.body.observation.last_sequence or
        record.body.wall_elapsed_ns == 0 or
        (record.body.trustworthy_success and !record.body.task_success))
        return error.InvalidReceipt;
    const metered = std.math.add(u64, record.body.input_tokens, record.body.output_tokens) catch
        return error.InvalidReceipt;
    const with_read = std.math.add(u64, metered, record.body.cache_read_tokens) catch
        return error.InvalidReceipt;
    const expected_metered = std.math.add(u64, with_read, record.body.cache_write_tokens) catch
        return error.InvalidReceipt;
    if (expected_metered != record.body.metered_tokens) return error.InvalidReceipt;
    const body_json = try std.json.Stringify.valueAlloc(a, record.body, .{});
    if (!std.mem.eql(u8, &observation.sha256Hex(body_json), &receipt_id))
        return error.ReceiptHashMismatch;
    const outcome_source: impact.OutcomeSource = switch (record.body.outcome_source) {
        .grader => .grader,
        .user_feedback => .user_feedback,
        .task_audit => .task_audit,
    };
    const labels = impact.RunLabels{
        .outcome_source = outcome_source,
        .task_success = record.body.task_success,
        .trustworthy_success = record.body.trustworthy_success,
        .drift_detected = record.body.drift_detected,
        .cost_microusd = record.body.cost_microusd,
        .metered_tokens = record.body.metered_tokens,
        .provider_requests = record.body.provider_requests,
        .input_tokens = record.body.input_tokens,
        .output_tokens = record.body.output_tokens,
        .cache_read_tokens = record.body.cache_read_tokens,
        .cache_write_tokens = record.body.cache_write_tokens,
        .wall_elapsed_ns = record.body.wall_elapsed_ns,
        .false_interventions = record.body.false_interventions,
        .regressions = record.body.regressions,
    };
    if (!labels.valid()) return error.InvalidReceipt;
    return .{
        .arena = arena,
        .receipt_id = receipt_id,
        .project_sha256 = project,
        .issuer_sha256 = issuer,
        .observation = .{
            .session_id = sid,
            .run_id = run_id,
            .first_sequence = record.body.observation.first_sequence,
            .last_sequence = record.body.observation.last_sequence,
        },
        .interval_sha256 = interval,
        .outcome_evidence_name = record.body.outcome_evidence_name,
        .outcome_evidence_sha256 = outcome_sha,
        .usage_evidence_name = record.body.usage_evidence_name,
        .usage_evidence_sha256 = usage_sha,
        .labels = labels,
    };
}

fn persistBody(session_dir: []const u8, body: WireBody) !PersistResult {
    const body_json = try std.json.Stringify.valueAlloc(std.heap.c_allocator, body, .{});
    defer std.heap.c_allocator.free(body_json);
    const receipt_id = observation.sha256Hex(body_json);
    const record_json = try std.json.Stringify.valueAlloc(std.heap.c_allocator, WireRecord{
        .receipt_id = receipt_id[0..],
        .body = body,
    }, .{});
    defer std.heap.c_allocator.free(record_json);
    if (record_json.len + 1 > MAX_RECORD_BYTES) return error.RecordTooLarge;
    var path_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}{s}.json\x00", .{
        session_dir, FILE_PREFIX, receipt_id[0..],
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
        return .{ .receipt_id = receipt_id, .created = true };
    }
    const existing = try readBounded(std.heap.c_allocator, path[0 .. path.len - 1], MAX_RECORD_BYTES);
    defer std.heap.c_allocator.free(existing);
    if (existing.len != record_json.len + 1 or
        !std.mem.eql(u8, existing[0..record_json.len], record_json) or
        existing[record_json.len] != '\n') return error.ReceiptCollision;
    return .{ .receipt_id = receipt_id, .created = false };
}

fn labelsMatchEvidence(
    labels: impact.RunLabels,
    outcome: evidence.Outcome,
    usage: evidence.Usage,
) bool {
    const source: impact.OutcomeSource = switch (outcome.outcome_source) {
        .grader => .grader,
        .user_feedback => .user_feedback,
        .task_audit => .task_audit,
    };
    return labels.outcome_source == source and
        labels.task_success == outcome.task_success and
        labels.trustworthy_success == outcome.trustworthy_success and
        labels.drift_detected == outcome.drift_detected and
        labels.false_interventions == outcome.false_interventions and
        labels.regressions == outcome.regressions and
        labels.provider_requests == usage.provider_requests and
        labels.input_tokens == usage.input_tokens and
        labels.output_tokens == usage.output_tokens and
        labels.cache_read_tokens == usage.cache_read_tokens and
        labels.cache_write_tokens == usage.cache_write_tokens and
        labels.metered_tokens == usage.metered_tokens and
        labels.cost_microusd == usage.cost_microusd and
        labels.wall_elapsed_ns == usage.wall_elapsed_ns;
}

fn readBounded(allocator: std.mem.Allocator, path: []const u8, max: usize) ![]u8 {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const fd = pfs.open(path_z.ptr, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true }, 0);
    if (fd < 0) return error.OpenFailed;
    defer _ = pfs.close(fd);
    const before = pfs.fileInfo(fd) catch return error.StatFailed;
    if (!before.is_regular or before.link_count != 1 or before.size == 0 or
        before.size > max) return error.InvalidFile;
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

fn validNonzeroLowerHex64(value: [64]u8) bool {
    return parseLowerHex64(value[0..]) != null and !isZeroHex(value);
}

fn isZeroHex(value: [64]u8) bool {
    for (value) |byte| if (byte != '0') return false;
    return true;
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
