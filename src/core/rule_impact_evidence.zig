//! Strict, run-bound evidence artifacts for RuleImpact labels.
//!
//! These artifacts are inputs from trusted host sensors (grader/audit and
//! provider usage), not model claims.  Each canonical JSON record binds every
//! label to the same completed observation-journal interval.  Callers cannot
//! supply a metric separately from the artifact that is hashed into the label
//! receipt.

const std = @import("std");
const pfs = @import("platform").fs;
const observation = @import("../tools/observation.zig");
const journal_mod = @import("tool_observation_journal.zig");
const session_id_mod = @import("session_id.zig");

pub const OUTCOME_SCHEMA_VERSION = "metacodes-rule-impact-outcome-evidence-v1";
pub const USAGE_SCHEMA_VERSION = "metacodes-rule-impact-usage-evidence-v1";
pub const MAX_EVIDENCE_BYTES: usize = 64 * 1024;
pub const MAX_EVIDENCE_NAME_BYTES: usize = 255;

pub const OutcomeSource = enum { grader, user_feedback, task_audit };

pub const Binding = struct {
    project_sha256: [64]u8,
    issuer_sha256: [64]u8,
    observation: journal_mod.RunBinding,
    interval_sha256: [64]u8,
};

pub const OutcomeInput = struct {
    binding: Binding,
    outcome_source: OutcomeSource,
    task_success: bool,
    trustworthy_success: bool,
    drift_detected: bool,
    false_interventions: u64,
    regressions: u64,
};

pub const UsageInput = struct {
    binding: Binding,
    provider_requests: u64,
    input_tokens: u64,
    output_tokens: u64,
    cache_read_tokens: u64,
    cache_write_tokens: u64,
    cost_microusd: u64,
    wall_elapsed_ns: u64,
};

pub const Outcome = struct {
    sha256: [64]u8,
    outcome_source: OutcomeSource,
    task_success: bool,
    trustworthy_success: bool,
    drift_detected: bool,
    false_interventions: u64,
    regressions: u64,
};

pub const Usage = struct {
    sha256: [64]u8,
    provider_requests: u64,
    input_tokens: u64,
    output_tokens: u64,
    cache_read_tokens: u64,
    cache_write_tokens: u64,
    metered_tokens: u64,
    cost_microusd: u64,
    wall_elapsed_ns: u64,
};

const WireRun = struct {
    session_id: []const u8,
    run_id: []const u8,
    first_sequence: u64,
    last_sequence: u64,
    interval_sha256: []const u8,
};

const OutcomeArtifact = struct {
    schema_version: []const u8 = OUTCOME_SCHEMA_VERSION,
    project_sha256: []const u8,
    issuer_sha256: []const u8,
    observation: WireRun,
    outcome_source: OutcomeSource,
    task_success: bool,
    trustworthy_success: bool,
    drift_detected: bool,
    false_interventions: u64,
    regressions: u64,
};

const UsageArtifact = struct {
    schema_version: []const u8 = USAGE_SCHEMA_VERSION,
    project_sha256: []const u8,
    issuer_sha256: []const u8,
    observation: WireRun,
    provider_requests: u64,
    input_tokens: u64,
    output_tokens: u64,
    cache_read_tokens: u64,
    cache_write_tokens: u64,
    metered_tokens: u64,
    cost_microusd: u64,
    wall_elapsed_ns: u64,
};

pub fn renderOutcome(allocator: std.mem.Allocator, input: OutcomeInput) ![]u8 {
    try validateBinding(input.binding);
    if (input.trustworthy_success and !input.task_success) return error.InvalidOutcome;
    return renderCanonical(allocator, OutcomeArtifact{
        .project_sha256 = &input.binding.project_sha256,
        .issuer_sha256 = &input.binding.issuer_sha256,
        .observation = wireRun(input.binding),
        .outcome_source = input.outcome_source,
        .task_success = input.task_success,
        .trustworthy_success = input.trustworthy_success,
        .drift_detected = input.drift_detected,
        .false_interventions = input.false_interventions,
        .regressions = input.regressions,
    });
}

pub fn renderUsage(allocator: std.mem.Allocator, input: UsageInput) ![]u8 {
    try validateBinding(input.binding);
    if (input.wall_elapsed_ns == 0) return error.InvalidUsage;
    const metered_tokens = try sumTokens(
        input.input_tokens,
        input.output_tokens,
        input.cache_read_tokens,
        input.cache_write_tokens,
    );
    return renderCanonical(allocator, UsageArtifact{
        .project_sha256 = &input.binding.project_sha256,
        .issuer_sha256 = &input.binding.issuer_sha256,
        .observation = wireRun(input.binding),
        .provider_requests = input.provider_requests,
        .input_tokens = input.input_tokens,
        .output_tokens = input.output_tokens,
        .cache_read_tokens = input.cache_read_tokens,
        .cache_write_tokens = input.cache_write_tokens,
        .metered_tokens = metered_tokens,
        .cost_microusd = input.cost_microusd,
        .wall_elapsed_ns = input.wall_elapsed_ns,
    });
}

pub fn loadOutcome(
    allocator: std.mem.Allocator,
    session_dir: []const u8,
    name: []const u8,
    expected: Binding,
) !Outcome {
    try validateBinding(expected);
    const raw = try readEvidence(allocator, session_dir, name);
    defer allocator.free(raw);
    const content = canonicalContent(raw) orelse return error.InvalidEvidence;
    var parsed = std.json.parseFromSlice(OutcomeArtifact, allocator, content, .{
        .ignore_unknown_fields = false,
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidEvidence,
    };
    defer parsed.deinit();
    try requireCanonical(allocator, parsed.value, content);
    if (!std.mem.eql(u8, parsed.value.schema_version, OUTCOME_SCHEMA_VERSION) or
        !matchesBinding(parsed.value.project_sha256, parsed.value.issuer_sha256, parsed.value.observation, expected) or
        (parsed.value.trustworthy_success and !parsed.value.task_success))
        return error.EvidenceBindingMismatch;
    return .{
        .sha256 = observation.sha256Hex(raw),
        .outcome_source = parsed.value.outcome_source,
        .task_success = parsed.value.task_success,
        .trustworthy_success = parsed.value.trustworthy_success,
        .drift_detected = parsed.value.drift_detected,
        .false_interventions = parsed.value.false_interventions,
        .regressions = parsed.value.regressions,
    };
}

pub fn loadUsage(
    allocator: std.mem.Allocator,
    session_dir: []const u8,
    name: []const u8,
    expected: Binding,
) !Usage {
    try validateBinding(expected);
    const raw = try readEvidence(allocator, session_dir, name);
    defer allocator.free(raw);
    const content = canonicalContent(raw) orelse return error.InvalidEvidence;
    var parsed = std.json.parseFromSlice(UsageArtifact, allocator, content, .{
        .ignore_unknown_fields = false,
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidEvidence,
    };
    defer parsed.deinit();
    try requireCanonical(allocator, parsed.value, content);
    if (!std.mem.eql(u8, parsed.value.schema_version, USAGE_SCHEMA_VERSION) or
        !matchesBinding(parsed.value.project_sha256, parsed.value.issuer_sha256, parsed.value.observation, expected) or parsed.value.wall_elapsed_ns == 0)
        return error.EvidenceBindingMismatch;
    const metered = sumTokens(
        parsed.value.input_tokens,
        parsed.value.output_tokens,
        parsed.value.cache_read_tokens,
        parsed.value.cache_write_tokens,
    ) catch return error.InvalidEvidence;
    if (metered != parsed.value.metered_tokens) return error.InvalidEvidence;
    return .{
        .sha256 = observation.sha256Hex(raw),
        .provider_requests = parsed.value.provider_requests,
        .input_tokens = parsed.value.input_tokens,
        .output_tokens = parsed.value.output_tokens,
        .cache_read_tokens = parsed.value.cache_read_tokens,
        .cache_write_tokens = parsed.value.cache_write_tokens,
        .metered_tokens = metered,
        .cost_microusd = parsed.value.cost_microusd,
        .wall_elapsed_ns = parsed.value.wall_elapsed_ns,
    };
}

pub fn validateEvidenceName(name: []const u8) !void {
    if (name.len == 0 or name.len > MAX_EVIDENCE_NAME_BYTES or
        std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..") or
        std.fs.path.basename(name).len != name.len or
        std.mem.indexOfAny(u8, name, "/\\\x00") != null)
        return error.InvalidEvidenceName;
}

fn wireRun(binding: Binding) WireRun {
    return .{
        .session_id = binding.observation.session_id.asSlice(),
        .run_id = binding.observation.run_id.asSlice(),
        .first_sequence = binding.observation.first_sequence,
        .last_sequence = binding.observation.last_sequence,
        .interval_sha256 = &binding.interval_sha256,
    };
}

fn validateBinding(binding: Binding) !void {
    if (!validNonzeroLowerHex64(binding.project_sha256) or
        !validNonzeroLowerHex64(binding.issuer_sha256) or
        !validNonzeroLowerHex64(binding.interval_sha256) or
        binding.observation.first_sequence > binding.observation.last_sequence)
        return error.InvalidBinding;
}

fn matchesBinding(
    project: []const u8,
    issuer: []const u8,
    run: WireRun,
    expected: Binding,
) bool {
    const session_id = session_id_mod.SessionId.fromSlice(run.session_id) orelse return false;
    const run_id = session_id_mod.SessionId.fromSlice(run.run_id) orelse return false;
    return std.mem.eql(u8, project, &expected.project_sha256) and
        std.mem.eql(u8, issuer, &expected.issuer_sha256) and
        std.mem.eql(u8, session_id.asSlice(), expected.observation.session_id.asSlice()) and
        std.mem.eql(u8, run_id.asSlice(), expected.observation.run_id.asSlice()) and
        run.first_sequence == expected.observation.first_sequence and
        run.last_sequence == expected.observation.last_sequence and
        std.mem.eql(u8, run.interval_sha256, &expected.interval_sha256);
}

fn sumTokens(input: u64, output: u64, cache_read: u64, cache_write: u64) !u64 {
    var total = std.math.add(u64, input, output) catch return error.UsageOverflow;
    total = std.math.add(u64, total, cache_read) catch return error.UsageOverflow;
    return std.math.add(u64, total, cache_write) catch error.UsageOverflow;
}

fn renderCanonical(allocator: std.mem.Allocator, value: anytype) ![]u8 {
    const json = try std.json.Stringify.valueAlloc(allocator, value, .{});
    defer allocator.free(json);
    const result = try allocator.alloc(u8, json.len + 1);
    @memcpy(result[0..json.len], json);
    result[json.len] = '\n';
    return result;
}

fn requireCanonical(allocator: std.mem.Allocator, value: anytype, content: []const u8) !void {
    const canonical = try std.json.Stringify.valueAlloc(allocator, value, .{});
    defer allocator.free(canonical);
    if (!std.mem.eql(u8, canonical, content)) return error.NonCanonicalEvidence;
}

fn canonicalContent(raw: []const u8) ?[]const u8 {
    if (raw.len < 2 or raw[raw.len - 1] != '\n') return null;
    return raw[0 .. raw.len - 1];
}

fn readEvidence(
    allocator: std.mem.Allocator,
    session_dir: []const u8,
    name: []const u8,
) ![]u8 {
    try validateEvidenceName(name);
    var path_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "{s}/{s}", .{ session_dir, name });
    const fd = pfs.open(path, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true }, 0);
    if (fd < 0) return error.EvidenceOpenFailed;
    defer _ = pfs.close(fd);
    const before = pfs.fileInfo(fd) catch return error.EvidenceStatFailed;
    if (!before.is_regular or before.link_count != 1 or before.size < 2 or
        before.size > MAX_EVIDENCE_BYTES) return error.InvalidEvidenceFile;
    const bytes = try allocator.alloc(u8, @intCast(before.size));
    errdefer allocator.free(bytes);
    var offset: usize = 0;
    while (offset < bytes.len) {
        const count = pfs.read(fd, bytes[offset..]);
        if (count <= 0) return error.EvidenceReadFailed;
        offset += @intCast(count);
    }
    // A stable size alone does not detect an in-place rewrite. Re-read the
    // already-open descriptor and compare every byte before accepting a hash.
    // Atomic-rename replacement is harmless because this fd keeps the original
    // inode; mutation of that inode during the read fails closed.
    if (pfs.lseek(fd, 0, .set) != 0) return error.EvidenceSeekFailed;
    var verified: usize = 0;
    var verify_buffer: [4096]u8 = undefined;
    while (verified < bytes.len) {
        const wanted = @min(verify_buffer.len, bytes.len - verified);
        const count = pfs.read(fd, verify_buffer[0..wanted]);
        if (count <= 0) return error.EvidenceReadFailed;
        const got: usize = @intCast(count);
        if (!std.mem.eql(u8, bytes[verified .. verified + got], verify_buffer[0..got]))
            return error.EvidenceChanged;
        verified += got;
    }
    const after = pfs.fileInfo(fd) catch return error.EvidenceStatFailed;
    if (!after.is_regular or after.link_count != 1 or after.size != before.size)
        return error.EvidenceChanged;
    return bytes;
}

fn validNonzeroLowerHex64(value: [64]u8) bool {
    var nonzero = false;
    for (value) |byte| {
        if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return false;
        nonzero = nonzero or byte != '0';
    }
    return nonzero;
}
