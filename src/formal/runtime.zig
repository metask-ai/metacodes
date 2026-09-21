//! Fail-closed process boundary for the precompiled Lean governance kernel.
//!
//! This module verifies the exact checker artifact before every invocation,
//! bounds all I/O, executes without inheriting the ambient environment, and
//! validates both the verdict schema and its binding to the proposal/snapshot.
//! It deliberately does not duplicate Lean's governance rules.

const std = @import("std");
const builtin = @import("builtin");
const pfs = @import("platform").fs;
const process = @import("platform").process;
const time = @import("../util/time.zig");
const AbortSignal = @import("../util/abort.zig").AbortSignal;
const toolchain = @import("../util/toolchain.zig");
const build_options = @import("project_harness_build_options");
const test_paths = @import("platform").paths;

pub const REQUEST_SCHEMA = "metacodes-formal-request-v1";
pub const MEMORY_REQUEST_SCHEMA = "metacodes-memory-migration-request-v1";
pub const ARTIFACT_REQUEST_SCHEMA = "metacodes-artifact-verification-request-v1";
pub const VERDICT_SCHEMA = "metacodes-formal-verdict-v2";
pub const CHECKER_VERSION = "metacodes-formal-kernel-v2";
pub const MAX_REQUEST_BYTES: usize = 64 * 1024;
pub const MAX_OUTPUT_BYTES: usize = 64 * 1024;
pub const MAX_CHECKER_BYTES: u64 = 128 * 1024 * 1024;

pub const Config = struct {
    checker_path: []const u8,
    expected_sha256: [64]u8,
    timeout_ms: u64 = 5_000,
    source: Source = .env,
};

pub const Source = enum { env, adjacent };

pub const ConfigLoad = union(enum) {
    configured: Config,
    missing,
    invalid,
};

pub const Bindings = struct {
    operation: []const u8,
    request_id: [64]u8,
    proposal_sha256: [64]u8,
    snapshot_sha256: [64]u8,
    snapshot_revision: [64]u8,
    next_snapshot_revision: ?[64]u8 = null,
    expected_next_phase: ?[]const u8 = null,
};

pub const FailureKind = enum {
    none,
    config_invalid,
    request_oversize,
    checker_open_failed,
    checker_not_regular,
    checker_size_invalid,
    checker_read_failed,
    checker_changed_during_hash,
    checker_changed_after_execution,
    checker_hash_mismatch,
    spawn_failed,
    pipe_failed,
    read_failed,
    timeout,
    aborted,
    output_capped,
    checker_nonzero,
    checker_stderr,
    malformed_verdict,
    verdict_schema_mismatch,
    checker_version_mismatch,
    verdict_binding_mismatch,
    inconsistent_verdict,
};

pub const ReasonCode = enum {
    unsupported_snapshot_schema,
    snapshot_unbounded,
    snapshot_truncated,
    lifecycle_count_mismatch,
    claim_without_owner,
    recovery_path_missing,
    terminal_evidence_missing,
    invalid_reference,
    proposal_not_bound,
    tasks_not_preserved,
    evidence_not_preserved,
    recovery_not_preserved,
    schema_not_preserved,
    contradiction_promoted,
    proposal_not_reversible,
    unsupported_memory_effect,
    stale_memory_generation,
    migration_evidence_invalid,
    replacement_excluded,
    artifact_request_binding_invalid,
    artifact_state_invalid,
    artifact_revision_not_bound,
    artifact_provider_not_authorized,
    artifact_repair_budget_exhausted,
    artifact_reverification_required,
    artifact_not_advanced,
    artifact_transition_illegal,
};

pub const TaskAuditChecks = struct {
    counts_consistent: bool,
    claims_owned: bool,
    hierarchy_recoverable: bool,
    terminal_evidence_preserved: bool,
    references_valid: bool,
    preservation_obligations: bool,

    pub fn all(self: TaskAuditChecks) bool {
        return self.counts_consistent and self.claims_owned and
            self.hierarchy_recoverable and self.terminal_evidence_preserved and
            self.references_valid and self.preservation_obligations;
    }
};

pub const MemorySupersedeChecks = struct {
    snapshot_usable: bool,
    proposal_well_formed: bool,
    references_valid: bool,
    tasks_preserved: bool,
    evidence_preserved: bool,
    recovery_preserved: bool,
    schema_preserved: bool,
    contradiction_safe: bool,
    reversible: bool,

    pub fn all(self: MemorySupersedeChecks) bool {
        return self.snapshot_usable and self.proposal_well_formed and
            self.references_valid and self.tasks_preserved and
            self.evidence_preserved and self.recovery_preserved and
            self.schema_preserved and self.contradiction_safe and self.reversible;
    }
};

pub const ArtifactTransitionChecks = struct {
    bindings_valid: bool,
    state_well_formed: bool,
    revision_advances: bool,
    provider_authorized: bool,
    repair_budget_preserved: bool,
    reverification_required: bool,
    artifact_advanced: bool,
    event_legal: bool,

    pub fn all(self: ArtifactTransitionChecks) bool {
        return self.bindings_valid and self.state_well_formed and
            self.revision_advances and self.provider_authorized and
            self.repair_budget_preserved and self.reverification_required and
            self.artifact_advanced and self.event_legal;
    }
};

pub const Checks = union(enum) {
    task_audit: TaskAuditChecks,
    memory_supersede_existing: MemorySupersedeChecks,
    artifact_transition: ArtifactTransitionChecks,

    pub fn all(self: Checks) bool {
        return switch (self) {
            inline else => |checks| checks.all(),
        };
    }
};

pub const Verdict = struct {
    admitted: bool,
    reasons: []ReasonCode,
    checks: Checks,
};

pub const Invocation = struct {
    failure: FailureKind = .none,
    actual_checker_sha256: [64]u8 = [_]u8{0} ** 64,
    checker_bytes: u64 = 0,
    hash_elapsed_ns: u64 = 0,
    post_hash_elapsed_ns: u64 = 0,
    checker_elapsed_ns: u64 = 0,
    input_bytes: usize = 0,
    stdout_bytes: usize = 0,
    stderr_bytes: usize = 0,
    exit_code: ?i32 = null,
    /// Exact bounded process output.  The audit layer persists these bytes in
    /// the immutable research bundle before `deinit`; they are evidence, not
    /// merely diagnostics.  Optionals distinguish "process never started"
    /// from a successful empty stream.
    stdout: ?[]u8 = null,
    stderr: ?[]u8 = null,
    /// Slice into `stdout` after the one permitted line ending is removed.
    /// It is populated before semantic parsing so rejected/forged verdicts
    /// remain available as negative evidence.
    verdict_payload: ?[]const u8 = null,
    verdict_sha256: ?[64]u8 = null,
    verdict: ?Verdict = null,

    pub fn deinit(self: *Invocation, allocator: std.mem.Allocator) void {
        if (self.verdict) |verdict| allocator.free(verdict.reasons);
        if (self.stdout) |bytes| allocator.free(bytes);
        if (self.stderr) |bytes| allocator.free(bytes);
        self.* = undefined;
    }

    pub fn checkerAdmitted(self: *const Invocation) bool {
        return self.failure == .none and self.verdict != null and self.verdict.?.admitted;
    }
};

pub fn loadConfigFromEnv() ConfigLoad {
    const raw_path = std.c.getenv("METACODES_FORMAL_KERNEL_PATH");
    const raw_hash = std.c.getenv("METACODES_FORMAL_KERNEL_SHA256");
    if (raw_path == null and raw_hash == null) return .missing;
    if (raw_path == null or raw_hash == null) return .invalid;
    const path = std.mem.span(raw_path.?);
    const hash = std.mem.span(raw_hash.?);
    if (!std.fs.path.isAbsolute(path) or path.len == 0) return .invalid;
    const expected = parseLowerHex64(hash) orelse return .invalid;

    const timeout_ms = timeoutMsFromEnv() orelse return .invalid;
    return .{ .configured = .{
        .checker_path = path,
        .expected_sha256 = expected,
        .timeout_ms = timeout_ms,
        .source = .env,
    } };
}

/// `METACODES_FORMAL_KERNEL_TIMEOUT_MS` as the runtime applies it: the default
/// when unset, null when set to anything but an integer in 100..30_000. Every
/// configuration path (environment pair or adjacent pin) fails closed on null,
/// and `app/doctor.zig` reports that refusal the same way.
pub fn timeoutMsFromEnv() ?u64 {
    const raw = std.c.getenv("METACODES_FORMAL_KERNEL_TIMEOUT_MS") orelse return 5_000;
    const parsed = std.fmt.parseInt(u64, std.mem.span(raw), 10) catch return null;
    if (parsed < 100 or parsed > 30_000) return null;
    return parsed;
}

pub fn loadConfig() ConfigLoad {
    const path_set = std.c.getenv("METACODES_FORMAL_KERNEL_PATH") != null;
    const hash_set = std.c.getenv("METACODES_FORMAL_KERNEL_SHA256") != null;
    if (path_set or hash_set) return loadConfigFromEnv();
    const expected_raw = build_options.formal_kernel_expected_sha256 orelse return .missing;
    const path = toolchain.kernelAdjacentPath(.formal) orelse return .missing;
    const expected = parseLowerHex64(expected_raw) orelse return .missing;
    const timeout_ms = timeoutMsFromEnv() orelse return .invalid;
    return .{ .configured = .{
        .checker_path = path,
        .expected_sha256 = expected,
        .timeout_ms = timeout_ms,
        .source = .adjacent,
    } };
}

test "formal Kernel loadConfig preserves an environment pair" {
    test_paths.unsetEnv("METACODES_FORMAL_KERNEL_PATH");
    test_paths.unsetEnv("METACODES_FORMAL_KERNEL_SHA256");
    test_paths.unsetEnv("METACODES_FORMAL_KERNEL_TIMEOUT_MS");
    defer test_paths.unsetEnv("METACODES_FORMAL_KERNEL_PATH");
    defer test_paths.unsetEnv("METACODES_FORMAL_KERNEL_SHA256");
    defer test_paths.unsetEnv("METACODES_FORMAL_KERNEL_TIMEOUT_MS");
    test_paths.setEnv("METACODES_FORMAL_KERNEL_PATH", "/tmp/formal-kernel-test");
    test_paths.setEnv("METACODES_FORMAL_KERNEL_SHA256", "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
    switch (loadConfig()) {
        .configured => |config| {
            try std.testing.expectEqualStrings("/tmp/formal-kernel-test", config.checker_path);
            try std.testing.expectEqual(Source.env, config.source);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "formal Kernel loadConfig stays missing without compiled digest" {
    test_paths.unsetEnv("METACODES_FORMAL_KERNEL_PATH");
    test_paths.unsetEnv("METACODES_FORMAL_KERNEL_SHA256");
    // The test build intentionally exports no formal digest, so adjacency is
    // fail-closed even if a file happens to exist beside the test executable.
    try std.testing.expectEqual(ConfigLoad.missing, loadConfig());
}

pub fn invoke(
    allocator: std.mem.Allocator,
    config: Config,
    input: []const u8,
    bindings: Bindings,
    abort: ?*const AbortSignal,
) error{OutOfMemory}!Invocation {
    var result = Invocation{ .input_bytes = input.len };
    errdefer result.deinit(allocator);
    if (input.len == 0 or input.len > MAX_REQUEST_BYTES) {
        result.failure = .request_oversize;
        return result;
    }
    if (!std.fs.path.isAbsolute(config.checker_path) or
        parseLowerHex64(config.expected_sha256[0..]) == null or
        config.timeout_ms < 100 or config.timeout_ms > 30_000)
    {
        result.failure = .config_invalid;
        return result;
    }

    const hash_started = time.nowNs();
    const digest = hashChecker(allocator, config.checker_path) catch |err| {
        result.hash_elapsed_ns = elapsedNs(hash_started);
        result.failure = switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.OpenFailed => .checker_open_failed,
            error.NotRegular => .checker_not_regular,
            error.SizeInvalid => .checker_size_invalid,
            error.ReadFailed => .checker_read_failed,
            error.ChangedDuringHash => .checker_changed_during_hash,
        };
        return result;
    };
    result.hash_elapsed_ns = elapsedNs(hash_started);
    result.actual_checker_sha256 = digest.sha256;
    result.checker_bytes = digest.bytes;
    if (!std.mem.eql(u8, digest.sha256[0..], config.expected_sha256[0..])) {
        result.failure = .checker_hash_mismatch;
        return result;
    }

    const checker_z = allocator.dupeZ(u8, config.checker_path) catch return error.OutOfMemory;
    defer allocator.free(checker_z);
    const argv = [_]?[*:0]const u8{ checker_z.ptr, null };
    const checker_started = time.nowNs();
    const captured = process.capture(&argv, allocator, .{
        .timeout_ms = config.timeout_ms,
        .max_bytes = MAX_OUTPUT_BYTES,
        .want_stderr = true,
        .stdin_data = input,
        .inherit_env = false,
        .abort_ctx = if (abort) |signal| @ptrCast(signal) else null,
        .abort_poll = if (abort != null) abortPoll else null,
    }) catch |err| {
        result.checker_elapsed_ns = elapsedNs(checker_started);
        result.failure = switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.SpawnFailed => .spawn_failed,
            error.PipeFailed => .pipe_failed,
            error.ReadError => .read_failed,
            error.Timeout => .timeout,
            error.Aborted => .aborted,
        };
        return result;
    };
    result.stdout = captured.stdout;
    result.stderr = captured.stderr;
    result.checker_elapsed_ns = elapsedNs(checker_started);
    result.stdout_bytes = captured.stdout.len;
    result.stderr_bytes = captured.stderr.len;
    result.exit_code = captured.exit_code;

    // platform.process intentionally returns a capped partial result as Ok.
    // A formal verdict must never interpret that truncation as a full message.
    if (captured.stdout.len >= MAX_OUTPUT_BYTES or captured.stderr.len >= MAX_OUTPUT_BYTES) {
        result.failure = .output_capped;
        return result;
    }
    if (captured.exit_code != 0) {
        result.failure = .checker_nonzero;
        return result;
    }
    if (captured.stderr.len != 0) {
        result.failure = .checker_stderr;
        return result;
    }

    // Detect replacement/modification between pre-exec verification and the
    // end of execution.  This makes canonical commits fail closed after a
    // race.  It does not claim to sandbox a malicious same-user process; the
    // deployment directory must still be protected by ordinary OS ownership.
    const post_hash_started = time.nowNs();
    const post_digest = hashChecker(allocator, config.checker_path) catch {
        result.post_hash_elapsed_ns = elapsedNs(post_hash_started);
        result.failure = .checker_changed_after_execution;
        return result;
    };
    result.post_hash_elapsed_ns = elapsedNs(post_hash_started);
    if (post_digest.bytes != digest.bytes or
        !std.mem.eql(u8, post_digest.sha256[0..], digest.sha256[0..]) or
        !std.mem.eql(u8, post_digest.sha256[0..], config.expected_sha256[0..]))
    {
        result.failure = .checker_changed_after_execution;
        return result;
    }

    const payload = verdictPayload(captured.stdout) orelse {
        result.failure = .malformed_verdict;
        return result;
    };
    result.verdict_payload = payload;
    result.verdict_sha256 = hashHex(payload);
    result.verdict = parseVerdict(allocator, payload, bindings) catch |err| {
        result.failure = switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidJson => .malformed_verdict,
            error.SchemaMismatch => .verdict_schema_mismatch,
            error.VersionMismatch => .checker_version_mismatch,
            error.BindingMismatch => .verdict_binding_mismatch,
            error.Inconsistent => .inconsistent_verdict,
        };
        return result;
    };
    return result;
}

const HashError = error{ OutOfMemory, OpenFailed, NotRegular, SizeInvalid, ReadFailed, ChangedDuringHash };
const FileDigest = struct { sha256: [64]u8, bytes: u64 };

fn hashChecker(allocator: std.mem.Allocator, path: []const u8) HashError!FileDigest {
    const path_z = allocator.dupeZ(u8, path) catch return error.OutOfMemory;
    defer allocator.free(path_z);
    const fd = pfs.open(path_z.ptr, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true }, @as(std.c.mode_t, 0));
    if (fd < 0) return error.OpenFailed;
    defer _ = pfs.close(fd);
    const before = pfs.fileInfo(fd) catch return error.OpenFailed;
    if (!before.is_regular) return error.NotRegular;
    if (before.size == 0 or before.size > MAX_CHECKER_BYTES) return error.SizeInvalid;

    var sha = std.crypto.hash.sha2.Sha256.init(.{});
    var total: u64 = 0;
    var buffer: [64 * 1024]u8 = undefined;
    while (true) {
        const read_count = pfs.readZ(fd, &buffer) catch return error.ReadFailed;
        if (read_count == 0) break;
        total = std.math.add(u64, total, read_count) catch return error.SizeInvalid;
        if (total > MAX_CHECKER_BYTES) return error.SizeInvalid;
        sha.update(buffer[0..read_count]);
    }
    const after = pfs.fileInfo(fd) catch return error.ChangedDuringHash;
    if (!after.is_regular or before.size != after.size or total != before.size)
        return error.ChangedDuringHash;
    var raw: [32]u8 = undefined;
    sha.final(&raw);
    return .{ .sha256 = std.fmt.bytesToHex(raw, .lower), .bytes = total };
}

const RawTaskVerdict = struct {
    schema_version: []const u8,
    checker_version: []const u8,
    request_id: []const u8,
    operation: []const u8,
    proposal_sha256: []const u8,
    snapshot_sha256: []const u8,
    snapshot_revision: []const u8,
    decision: []const u8,
    admitted: bool,
    reason_codes: [][]const u8,
    checks: TaskAuditChecks,
};

const RawMemoryVerdict = struct {
    schema_version: []const u8,
    checker_version: []const u8,
    request_id: []const u8,
    operation: []const u8,
    proposal_sha256: []const u8,
    snapshot_sha256: []const u8,
    snapshot_revision: []const u8,
    decision: []const u8,
    admitted: bool,
    reason_codes: [][]const u8,
    checks: MemorySupersedeChecks,
};

const RawArtifactVerdict = struct {
    schema_version: []const u8,
    checker_version: []const u8,
    request_id: []const u8,
    operation: []const u8,
    proposal_sha256: []const u8,
    snapshot_sha256: []const u8,
    snapshot_revision: []const u8,
    decision: []const u8,
    admitted: bool,
    next_phase: []const u8,
    next_snapshot_revision: []const u8,
    reason_codes: [][]const u8,
    checks: ArtifactTransitionChecks,
};

const OperationProbe = struct { operation: []const u8 };

const VerdictError = error{ OutOfMemory, InvalidJson, SchemaMismatch, VersionMismatch, BindingMismatch, Inconsistent };

fn parseVerdict(allocator: std.mem.Allocator, payload: []const u8, bindings: Bindings) VerdictError!Verdict {
    var probe = std.json.parseFromSlice(OperationProbe, allocator, payload, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidJson,
    };
    defer probe.deinit();
    if (!std.mem.eql(u8, probe.value.operation, bindings.operation)) return error.BindingMismatch;
    if (std.mem.eql(u8, bindings.operation, "task_audit")) {
        var parsed = try parseRawVerdict(RawTaskVerdict, allocator, payload);
        defer parsed.deinit();
        return finishVerdict(allocator, parsed.value, bindings, .{ .task_audit = parsed.value.checks });
    }
    if (std.mem.eql(u8, bindings.operation, "memory_supersede_existing")) {
        var parsed = try parseRawVerdict(RawMemoryVerdict, allocator, payload);
        defer parsed.deinit();
        return finishVerdict(allocator, parsed.value, bindings, .{ .memory_supersede_existing = parsed.value.checks });
    }
    if (std.mem.eql(u8, bindings.operation, "artifact_transition")) {
        var parsed = try parseRawVerdict(RawArtifactVerdict, allocator, payload);
        defer parsed.deinit();
        const next_revision = bindings.next_snapshot_revision orelse return error.BindingMismatch;
        const next_phase = bindings.expected_next_phase orelse return error.BindingMismatch;
        if (!std.mem.eql(u8, parsed.value.next_snapshot_revision, next_revision[0..]) or
            !std.mem.eql(u8, parsed.value.next_phase, next_phase))
            return error.BindingMismatch;
        return finishVerdict(allocator, parsed.value, bindings, .{ .artifact_transition = parsed.value.checks });
    }
    return error.BindingMismatch;
}

fn parseRawVerdict(comptime T: type, allocator: std.mem.Allocator, payload: []const u8) VerdictError!std.json.Parsed(T) {
    return std.json.parseFromSlice(T, allocator, payload, .{
        .ignore_unknown_fields = false,
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidJson,
    };
}

fn finishVerdict(
    allocator: std.mem.Allocator,
    raw: anytype,
    bindings: Bindings,
    checks: Checks,
) VerdictError!Verdict {
    if (!std.mem.eql(u8, raw.schema_version, VERDICT_SCHEMA)) return error.SchemaMismatch;
    if (!std.mem.eql(u8, raw.checker_version, CHECKER_VERSION)) return error.VersionMismatch;
    if (!std.mem.eql(u8, raw.operation, bindings.operation) or
        !std.mem.eql(u8, raw.request_id, bindings.request_id[0..]) or
        !std.mem.eql(u8, raw.proposal_sha256, bindings.proposal_sha256[0..]) or
        !std.mem.eql(u8, raw.snapshot_sha256, bindings.snapshot_sha256[0..]) or
        !std.mem.eql(u8, raw.snapshot_revision, bindings.snapshot_revision[0..]))
        return error.BindingMismatch;
    if ((raw.admitted and !std.mem.eql(u8, raw.decision, "admit")) or
        (!raw.admitted and !std.mem.eql(u8, raw.decision, "block")))
        return error.Inconsistent;
    if (raw.reason_codes.len > @typeInfo(ReasonCode).@"enum".fields.len) return error.Inconsistent;

    const reasons = allocator.alloc(ReasonCode, raw.reason_codes.len) catch return error.OutOfMemory;
    errdefer allocator.free(reasons);
    for (raw.reason_codes, 0..) |name, index| {
        const reason = std.meta.stringToEnum(ReasonCode, name) orelse return error.Inconsistent;
        for (reasons[0..index]) |prior| if (prior == reason) return error.Inconsistent;
        reasons[index] = reason;
    }
    if ((raw.admitted and (reasons.len != 0 or !checks.all())) or
        (!raw.admitted and reasons.len == 0))
        return error.Inconsistent;
    return .{ .admitted = raw.admitted, .reasons = reasons, .checks = checks };
}

fn verdictPayload(stdout: []const u8) ?[]const u8 {
    if (stdout.len < 3 or stdout[stdout.len - 1] != '\n') return null;
    var payload = stdout[0 .. stdout.len - 1];
    if (payload.len > 0 and payload[payload.len - 1] == '\r') payload = payload[0 .. payload.len - 1];
    if (payload.len < 2 or payload[0] != '{' or payload[payload.len - 1] != '}') return null;
    if (std.mem.indexOfAny(u8, payload, "\r\n") != null) return null;
    return payload;
}

fn abortPoll(raw: ?*const anyopaque) bool {
    const signal: *const AbortSignal = @ptrCast(@alignCast(raw.?));
    return signal.isAborted();
}

fn parseLowerHex64(raw: []const u8) ?[64]u8 {
    if (raw.len != 64) return null;
    var out: [64]u8 = undefined;
    for (raw, 0..) |byte, index| {
        if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return null;
        out[index] = byte;
    }
    return out;
}

fn elapsedNs(start: i128) u64 {
    const finish = time.nowNs();
    if (start <= 0 or finish <= start) return 0;
    const delta = finish - start;
    return @intCast(@min(delta, std.math.maxInt(u64)));
}

fn hashHex(bytes: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

test "strict verdict payload permits exactly one platform line ending" {
    try std.testing.expectEqualStrings("{}", verdictPayload("{}\n").?);
    try std.testing.expectEqualStrings("{}", verdictPayload("{}\r\n").?);
    try std.testing.expect(verdictPayload("{}") == null);
    try std.testing.expect(verdictPayload("{}\n\n") == null);
    try std.testing.expect(verdictPayload("{\n}\n") == null);
}

test "formal expected hashes are lowercase and exact width" {
    const valid = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    try std.testing.expect(parseLowerHex64(valid) != null);
    try std.testing.expect(parseLowerHex64(valid[0..63]) == null);
    try std.testing.expect(parseLowerHex64("ABCDEF6789abcdef0123456789abcdef0123456789abcdef0123456789abcdef") == null);
}

test "formal runtime rejects missing and hash-mismatched checker before execution" {
    const bindings = testBindings();
    var missing = try invoke(std.testing.allocator, .{
        .checker_path = "/definitely/missing/metacodes-formal-kernel",
        .expected_sha256 = bindings.request_id,
    }, "{}", bindings, null);
    defer missing.deinit(std.testing.allocator);
    try std.testing.expectEqual(FailureKind.checker_open_failed, missing.failure);

    if (builtin.os.tag == .windows) return error.SkipZigTest else {
        const echo_digest = try hashChecker(std.testing.allocator, "/bin/echo");
        var wrong = echo_digest.sha256;
        wrong[0] = if (wrong[0] == '0') '1' else '0';
        var mismatch = try invoke(std.testing.allocator, .{
            .checker_path = "/bin/echo",
            .expected_sha256 = wrong,
        }, "{}", bindings, null);
        defer mismatch.deinit(std.testing.allocator);
        try std.testing.expectEqual(FailureKind.checker_hash_mismatch, mismatch.failure);
        try std.testing.expect(mismatch.exit_code == null);
    }
}

test "formal runtime times out and rejects a verdict bound to another request" {
    if (builtin.os.tag == .windows) return error.SkipZigTest else {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
        const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
        const root = root_buffer[0..root_len];
        const sleepy_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/sleepy-checker", .{root});
        defer std.testing.allocator.free(sleepy_path);
        try writeTestExecutable(std.testing.allocator, sleepy_path, "#!/bin/sh\nsleep 5\n");
        const sleepy_digest = try hashChecker(std.testing.allocator, sleepy_path);
        const bindings = testBindings();
        var timed = try invoke(std.testing.allocator, .{
            .checker_path = sleepy_path,
            .expected_sha256 = sleepy_digest.sha256,
            .timeout_ms = 100,
        }, "{}", bindings, null);
        defer timed.deinit(std.testing.allocator);
        try std.testing.expectEqual(FailureKind.timeout, timed.failure);

        const liar_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/liar-checker", .{root});
        defer std.testing.allocator.free(liar_path);
        const liar =
            "#!/bin/sh\n" ++
            "printf '%s\\n' '{\"schema_version\":\"metacodes-formal-verdict-v2\",\"checker_version\":\"metacodes-formal-kernel-v2\",\"request_id\":\"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee\",\"operation\":\"task_audit\",\"proposal_sha256\":\"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\"snapshot_sha256\":\"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc\",\"snapshot_revision\":\"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd\",\"decision\":\"admit\",\"admitted\":true,\"reason_codes\":[],\"checks\":{\"counts_consistent\":true,\"claims_owned\":true,\"hierarchy_recoverable\":true,\"terminal_evidence_preserved\":true,\"references_valid\":true,\"preservation_obligations\":true}}'\n";
        try writeTestExecutable(std.testing.allocator, liar_path, liar);
        const liar_digest = try hashChecker(std.testing.allocator, liar_path);
        var lied = try invoke(std.testing.allocator, .{
            .checker_path = liar_path,
            .expected_sha256 = liar_digest.sha256,
        }, "{}", bindings, null);
        defer lied.deinit(std.testing.allocator);
        try std.testing.expectEqual(FailureKind.verdict_binding_mismatch, lied.failure);
        try std.testing.expect(lied.verdict == null);
    }
}

test "formal runtime binds artifact verdict to next revision and phase" {
    const payload =
        "{\"schema_version\":\"metacodes-formal-verdict-v2\",\"checker_version\":\"metacodes-formal-kernel-v2\",\"request_id\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"operation\":\"artifact_transition\",\"proposal_sha256\":\"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\",\"snapshot_sha256\":\"cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc\",\"snapshot_revision\":\"dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd\",\"decision\":\"admit\",\"admitted\":true,\"next_phase\":\"verification_requested\",\"next_snapshot_revision\":\"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee\",\"reason_codes\":[],\"checks\":{\"bindings_valid\":true,\"state_well_formed\":true,\"revision_advances\":true,\"provider_authorized\":true,\"repair_budget_preserved\":true,\"reverification_required\":true,\"artifact_advanced\":true,\"event_legal\":true}}";
    const bindings = artifactTestBindings();
    const verdict = try parseVerdict(std.testing.allocator, payload, bindings);
    defer std.testing.allocator.free(verdict.reasons);
    try std.testing.expect(verdict.admitted);
    switch (verdict.checks) {
        .artifact_transition => |checks| try std.testing.expect(checks.all()),
        else => return error.UnexpectedVerdictChecks,
    }

    var forged_revision = bindings;
    forged_revision.next_snapshot_revision =
        ("ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff").*;
    try std.testing.expectError(
        error.BindingMismatch,
        parseVerdict(std.testing.allocator, payload, forged_revision),
    );

    var forged_phase = bindings;
    forged_phase.expected_next_phase = "verified";
    try std.testing.expectError(
        error.BindingMismatch,
        parseVerdict(std.testing.allocator, payload, forged_phase),
    );
}

fn testBindings() Bindings {
    return .{
        .operation = "task_audit",
        .request_id = ("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa").*,
        .proposal_sha256 = ("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb").*,
        .snapshot_sha256 = ("cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc").*,
        .snapshot_revision = ("dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd").*,
    };
}

fn artifactTestBindings() Bindings {
    return .{
        .operation = "artifact_transition",
        .request_id = ("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa").*,
        .proposal_sha256 = ("bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb").*,
        .snapshot_sha256 = ("cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc").*,
        .snapshot_revision = ("dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd").*,
        .next_snapshot_revision = ("eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee").*,
        .expected_next_phase = "verification_requested",
    };
}

fn writeTestExecutable(allocator: std.mem.Allocator, path: []const u8, content: []const u8) !void {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const fd = pfs.open(
        path_z.ptr,
        .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .NOFOLLOW = true },
        @as(std.c.mode_t, 0o700),
    );
    if (fd < 0) return error.TestExecutableOpenFailed;
    defer _ = pfs.close(fd);
    const wrote = pfs.write(fd, content);
    if (wrote != @as(isize, @intCast(content.len))) return error.TestExecutableWriteFailed;
}
