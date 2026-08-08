//! Fail-closed native boundary for the fixed Lean project-harness kernel.
//!
//! Candidate Lean code is build evidence only. Production decisions pass the
//! candidate's bounded `RuleSpec` as data to this hash-pinned executable. The
//! host verifies the binary before and after each call and binds the verdict to
//! the exact project, bundle, candidate, revision, operation, and request id.

const std = @import("std");
const pfs = @import("platform").fs;
const process = @import("platform").process;
const time = @import("../util/time.zig");
const observation = @import("../tools/observation.zig");
const spec_mod = @import("../core/project_rule_spec.zig");
const AbortSignal = @import("../util/abort.zig").AbortSignal;

pub const REQUEST_SCHEMA = "metacodes-project-harness-request-v1";
pub const VERDICT_SCHEMA = "metacodes-project-harness-verdict-v1";
pub const CHECKER_VERSION = "metacodes-project-harness-kernel-v1";
pub const MAX_REQUEST_BYTES: usize = 128 * 1024;
pub const MAX_OUTPUT_BYTES: usize = 128 * 1024;
pub const MAX_CHECKER_BYTES: u64 = 128 * 1024 * 1024;

pub const Config = struct {
    checker_path: []const u8,
    expected_sha256: [64]u8,
    timeout_ms: u64 = 5_000,
};

pub const ConfigLoad = union(enum) { missing, invalid, configured: Config };

pub fn loadConfigFromEnv() ConfigLoad {
    const raw_path = std.c.getenv("METACODES_PROJECT_KERNEL_PATH");
    const raw_hash = std.c.getenv("METACODES_PROJECT_KERNEL_SHA256");
    if (raw_path == null and raw_hash == null) return .missing;
    if (raw_path == null or raw_hash == null) return .invalid;
    const path = std.mem.span(raw_path.?);
    const expected = parseLowerHex64(std.mem.span(raw_hash.?)) orelse return .invalid;
    if (!std.fs.path.isAbsolute(path)) return .invalid;
    var timeout_ms: u64 = 5_000;
    if (std.c.getenv("METACODES_PROJECT_KERNEL_TIMEOUT_MS")) |raw_timeout| {
        timeout_ms = std.fmt.parseInt(u64, std.mem.span(raw_timeout), 10) catch return .invalid;
        if (timeout_ms < 100 or timeout_ms > 30_000) return .invalid;
    }
    return .{ .configured = .{
        .checker_path = path,
        .expected_sha256 = expected,
        .timeout_ms = timeout_ms,
    } };
}

pub const Operation = enum { promote, pre_decision, post_decision };
pub const SourceKind = enum { user_correction, agent_reflection, runtime_counterexample };

pub const PromotionFacts = struct {
    source_kind: SourceKind,
    source_receipt_bound: bool,
    proposer: []const u8,
    builder: []const u8,
    auditor: []const u8,
    replay_evaluator: []const u8,
    shadow_evaluator: []const u8,
    promoter: []const u8,
    replay_checker: []const u8,
    shadow_checker: []const u8,
    build_receipt: []const u8,
    axiom_predecessor: []const u8,
    axiom_receipt: []const u8,
    replay_predecessor: []const u8,
    replay_receipt: []const u8,
    shadow_predecessor: []const u8,
    build_manifest: []const u8,
    rule_spec_sha256: []const u8,
    sdk_olean: []const u8,
    build_completed: bool,
    axiom_completed: bool,
    forbidden_declaration_count: u32,
    unexpected_axiom_count: u32,
    replay_completed: bool,
    replay_positive_cases: u32,
    replay_negative_cases: u32,
    replay_false_positive_count: u32,
    replay_false_negative_count: u32,
    shadow_completed: bool,
    shadow_observed_decisions: u32,
    shadow_divergence_count: u32,
    shadow_side_effect_count: u32,
    previous_revision: u64,
    previous_bundle_sha256: []const u8,
    previous_rule_count: u32,
    bundle_rule_count: u32,
    candidate_occurrences: u32,
};

pub const Payload = union(enum) {
    promotion: PromotionFacts,
    pre: spec_mod.PreSignal,
    post: spec_mod.PostSignal,
};

pub const Request = struct {
    schema_version: []const u8 = REQUEST_SCHEMA,
    request_id: []const u8,
    operation: Operation,
    expected_checker_version: []const u8 = CHECKER_VERSION,
    kernel_sha256: []const u8,
    candidate_id: []const u8,
    project_sha256: []const u8,
    bundle_sha256: []const u8,
    bundle_revision: u64,
    rule_spec: spec_mod.Wire,
    payload: Payload,
};

pub const Bindings = struct {
    request_id: [64]u8,
    operation: Operation,
    kernel_sha256: [64]u8,
    candidate_id: [64]u8,
    project_sha256: [64]u8,
    bundle_sha256: [64]u8,
    bundle_revision: u64,
};

pub const Checks = struct {
    request_valid: bool,
    rule_valid: bool,
    lifecycle_valid: bool,
    decision_valid: bool,

    pub fn all(self: Checks) bool {
        return self.request_valid and self.rule_valid and
            self.lifecycle_valid and self.decision_valid;
    }
};

pub const FailureKind = enum {
    none,
    request_oversize,
    config_invalid,
    checker_open_failed,
    checker_not_regular,
    checker_size_invalid,
    checker_read_failed,
    checker_changed_during_hash,
    checker_hash_mismatch,
    spawn_failed,
    pipe_failed,
    read_failed,
    timeout,
    aborted,
    output_capped,
    checker_nonzero,
    checker_stderr,
    checker_changed_after_execution,
    malformed_verdict,
    verdict_schema_mismatch,
    checker_version_mismatch,
    verdict_binding_mismatch,
    inconsistent_verdict,
};

pub const Verdict = struct {
    admitted: bool,
    checks: Checks,
};

pub const Invocation = struct {
    /// Exact bindings supplied to the native verifier.  Keeping them beside
    /// the verdict prevents a caller from reusing an admitted pre/post
    /// invocation as promotion evidence for another candidate or revision.
    bindings: ?Bindings = null,
    failure: FailureKind = .none,
    actual_checker_sha256: [64]u8 = [_]u8{'0'} ** 64,
    request_sha256: [64]u8 = [_]u8{'0'} ** 64,
    verdict_sha256: ?[64]u8 = null,
    checker_bytes: u64 = 0,
    checker_elapsed_ns: u64 = 0,
    stdout: ?[]u8 = null,
    stderr: ?[]u8 = null,
    verdict_payload: ?[]const u8 = null,
    verdict: ?Verdict = null,

    pub fn deinit(self: *Invocation, allocator: std.mem.Allocator) void {
        if (self.stdout) |bytes| allocator.free(bytes);
        if (self.stderr) |bytes| allocator.free(bytes);
        self.* = undefined;
    }

    pub fn checkerAdmitted(self: *const Invocation) bool {
        return self.failure == .none and self.verdict != null and
            self.verdict.?.admitted;
    }
};

const RawVerdict = struct {
    schema_version: []const u8,
    checker_version: []const u8,
    request_id: []const u8,
    operation: Operation,
    kernel_sha256: []const u8,
    candidate_id: []const u8,
    project_sha256: []const u8,
    bundle_sha256: []const u8,
    bundle_revision: u64,
    decision: []const u8,
    admitted: bool,
    reason_codes: [][]const u8,
    checks: Checks,
};

pub fn requestId(
    operation: Operation,
    candidate_id: [64]u8,
    bundle_sha256: [64]u8,
    revision: u64,
    signal_json: []const u8,
) [64]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("metacodes-project-harness-request-id-v1\x00");
    hasher.update(@tagName(operation));
    hasher.update("\x00");
    hasher.update(&candidate_id);
    hasher.update(&bundle_sha256);
    var revision_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &revision_bytes, revision, .big);
    hasher.update(&revision_bytes);
    hasher.update(signal_json);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

pub fn renderRequest(allocator: std.mem.Allocator, request: Request) ![]u8 {
    return std.json.Stringify.valueAlloc(allocator, request, .{});
}

pub fn invoke(
    allocator: std.mem.Allocator,
    config: Config,
    request: Request,
    bindings: Bindings,
    abort: ?*const AbortSignal,
) error{OutOfMemory}!Invocation {
    var result = Invocation{ .bindings = bindings };
    errdefer result.deinit(allocator);
    const input = renderRequest(allocator, request) catch return error.OutOfMemory;
    defer allocator.free(input);
    result.request_sha256 = observation.sha256Hex(input);
    if (input.len == 0 or input.len > MAX_REQUEST_BYTES) {
        result.failure = .request_oversize;
        return result;
    }
    if (!std.fs.path.isAbsolute(config.checker_path) or
        parseLowerHex64(&config.expected_sha256) == null or
        config.timeout_ms < 100 or config.timeout_ms > 30_000)
    {
        result.failure = .config_invalid;
        return result;
    }

    const digest = hashChecker(allocator, config.checker_path) catch |err| {
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
    result.actual_checker_sha256 = digest.sha256;
    result.checker_bytes = digest.bytes;
    if (!std.mem.eql(u8, &digest.sha256, &config.expected_sha256)) {
        result.failure = .checker_hash_mismatch;
        return result;
    }

    const checker_z = allocator.dupeZ(u8, config.checker_path) catch return error.OutOfMemory;
    defer allocator.free(checker_z);
    const argv = [_]?[*:0]const u8{ checker_z.ptr, null };
    const started = time.nowNs();
    const captured = process.capture(&argv, allocator, .{
        .timeout_ms = config.timeout_ms,
        .max_bytes = MAX_OUTPUT_BYTES,
        .want_stderr = true,
        .stdin_data = input,
        .inherit_env = false,
        .abort_ctx = if (abort) |signal| @ptrCast(signal) else null,
        .abort_poll = if (abort != null) abortPoll else null,
    }) catch |err| {
        result.checker_elapsed_ns = elapsedNs(started);
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
    result.checker_elapsed_ns = elapsedNs(started);
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

    const post_digest = hashChecker(allocator, config.checker_path) catch {
        result.failure = .checker_changed_after_execution;
        return result;
    };
    if (post_digest.bytes != digest.bytes or
        !std.mem.eql(u8, &post_digest.sha256, &digest.sha256) or
        !std.mem.eql(u8, &post_digest.sha256, &config.expected_sha256))
    {
        result.failure = .checker_changed_after_execution;
        return result;
    }

    const payload = verdictPayload(captured.stdout) orelse {
        result.failure = .malformed_verdict;
        return result;
    };
    result.verdict_payload = payload;
    result.verdict_sha256 = observation.sha256Hex(payload);
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

const ParseError = error{ OutOfMemory, InvalidJson, SchemaMismatch, VersionMismatch, BindingMismatch, Inconsistent };

fn parseVerdict(allocator: std.mem.Allocator, payload: []const u8, bindings: Bindings) ParseError!Verdict {
    var parsed = std.json.parseFromSlice(RawVerdict, allocator, payload, .{
        .ignore_unknown_fields = false,
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidJson,
    };
    defer parsed.deinit();
    const raw = parsed.value;
    if (!std.mem.eql(u8, raw.schema_version, VERDICT_SCHEMA)) return error.SchemaMismatch;
    if (!std.mem.eql(u8, raw.checker_version, CHECKER_VERSION)) return error.VersionMismatch;
    if (!equalHex(raw.request_id, bindings.request_id) or
        raw.operation != bindings.operation or
        !equalHex(raw.kernel_sha256, bindings.kernel_sha256) or
        !equalHex(raw.candidate_id, bindings.candidate_id) or
        !equalHex(raw.project_sha256, bindings.project_sha256) or
        !equalHex(raw.bundle_sha256, bindings.bundle_sha256) or
        raw.bundle_revision != bindings.bundle_revision)
        return error.BindingMismatch;
    if ((!std.mem.eql(u8, raw.decision, "admit") and
        !std.mem.eql(u8, raw.decision, "block")) or
        raw.admitted != std.mem.eql(u8, raw.decision, "admit") or
        !raw.checks.decision_valid or (raw.admitted and !raw.checks.all()))
        return error.Inconsistent;
    return .{ .admitted = raw.admitted, .checks = raw.checks };
}

const HashError = error{ OutOfMemory, OpenFailed, NotRegular, SizeInvalid, ReadFailed, ChangedDuringHash };
const FileDigest = struct { sha256: [64]u8, bytes: u64 };

fn hashChecker(allocator: std.mem.Allocator, path: []const u8) HashError!FileDigest {
    const path_z = allocator.dupeZ(u8, path) catch return error.OutOfMemory;
    defer allocator.free(path_z);
    const fd = pfs.open(path_z.ptr, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true }, 0);
    if (fd < 0) return error.OpenFailed;
    defer _ = pfs.close(fd);
    const before = pfs.fileInfo(fd) catch return error.OpenFailed;
    if (!before.is_regular) return error.NotRegular;
    if (before.size == 0 or before.size > MAX_CHECKER_BYTES) return error.SizeInvalid;
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var total: u64 = 0;
    var buffer: [64 * 1024]u8 = undefined;
    while (true) {
        const count = pfs.readZ(fd, &buffer) catch return error.ReadFailed;
        if (count == 0) break;
        total = std.math.add(u64, total, count) catch return error.SizeInvalid;
        if (total > MAX_CHECKER_BYTES) return error.SizeInvalid;
        hasher.update(buffer[0..count]);
    }
    const after = pfs.fileInfo(fd) catch return error.ChangedDuringHash;
    if (!after.is_regular or after.size != before.size or total != before.size)
        return error.ChangedDuringHash;
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return .{ .sha256 = std.fmt.bytesToHex(digest, .lower), .bytes = total };
}

fn verdictPayload(stdout: []const u8) ?[]const u8 {
    if (stdout.len < 2 or stdout[stdout.len - 1] != '\n') return null;
    const payload = stdout[0 .. stdout.len - 1];
    if (payload.len == 0 or std.mem.indexOfAny(u8, payload, "\r\n") != null) return null;
    return payload;
}

fn abortPoll(raw: ?*const anyopaque) bool {
    const signal: *const AbortSignal = @ptrCast(@alignCast(raw orelse return false));
    return signal.isAborted();
}

fn parseLowerHex64(raw: []const u8) ?[64]u8 {
    if (raw.len != 64) return null;
    var result: [64]u8 = undefined;
    for (raw, 0..) |byte, index| {
        if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return null;
        result[index] = byte;
    }
    return result;
}

fn equalHex(raw: []const u8, expected: [64]u8) bool {
    const parsed = parseLowerHex64(raw) orelse return false;
    return std.mem.eql(u8, &parsed, &expected);
}

fn elapsedNs(start: i128) u64 {
    const elapsed = time.nowNs() - start;
    return if (elapsed <= 0) 0 else @intCast(@min(elapsed, std.math.maxInt(u64)));
}

test "project harness request rendering is byte-stable and identity-bound" {
    const signal = spec_mod.PreSignal{
        .tool = "Write",
        .input_bytes = 12,
        .agent_depth = 0,
        .authoritative = true,
    };
    const signal_json = try std.json.Stringify.valueAlloc(std.testing.allocator, signal, .{});
    defer std.testing.allocator.free(signal_json);
    const candidate = [_]u8{'a'} ** 64;
    const bundle = [_]u8{'b'} ** 64;
    const id = requestId(.pre_decision, candidate, bundle, 1, signal_json);
    const request = Request{
        .request_id = id[0..],
        .operation = .pre_decision,
        .kernel_sha256 = (&([_]u8{'d'} ** 64))[0..],
        .candidate_id = candidate[0..],
        .project_sha256 = (&([_]u8{'c'} ** 64))[0..],
        .bundle_sha256 = bundle[0..],
        .bundle_revision = 1,
        .rule_spec = spec_mod.toWire(.{
            .target_tool = "Write",
            .deny_target = true,
            .max_input_bytes = 8192,
            .max_agent_depth = 4,
            .authoritative_only = true,
            .effect_requirement = .none,
        }),
        .payload = .{ .pre = signal },
    };
    const first = try renderRequest(std.testing.allocator, request);
    defer std.testing.allocator.free(first);
    const second = try renderRequest(std.testing.allocator, request);
    defer std.testing.allocator.free(second);
    try std.testing.expectEqualSlices(u8, first, second);
    try std.testing.expect(std.mem.indexOf(u8, first, "\"operation\":\"pre_decision\"") != null);
}
