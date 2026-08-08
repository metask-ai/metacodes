//! Immutable, content-addressed proposals for project-specific formal rules.
//!
//! A proposal is evidence, never authority. This module deliberately exposes
//! no promotion or runtime-load API: those transitions must be admitted by the
//! independent Lean checker plus replay/shadow evidence. Persisting a proposal
//! cannot change permissions, tool dispatch, or the provider-visible prompt.

const std = @import("std");
const pfs = @import("platform").fs;
const observation = @import("../tools/observation.zig");
const observation_journal = @import("tool_observation_journal.zig");

pub const SCHEMA_VERSION = "metacodes-rule-candidate-v1";
pub const FILE_PREFIX = "rule-candidate-";
pub const MAX_INVARIANT_BYTES: usize = 8 * 1024;
pub const MAX_FALSIFIER_BYTES: usize = 8 * 1024;
pub const MAX_LEAN_SOURCE_BYTES: usize = 32 * 1024;
pub const MAX_RECORD_BYTES: usize = 64 * 1024;

pub const UserCorrection = struct {
    correction_sha256: [64]u8,
    authority_sha256: [64]u8,
};

pub const AgentReflection = struct {
    observation: observation_journal.RunBinding,
    reflector_sha256: [64]u8,
    /// A concrete condition or replay case that would reject this hypothesis.
    falsifier: []const u8,
};

pub const RuntimeCounterexample = struct {
    observation: observation_journal.RunBinding,
    verdict_sha256: [64]u8,
};

pub const Source = union(enum) {
    user_correction: UserCorrection,
    agent_reflection: AgentReflection,
    runtime_counterexample: RuntimeCounterexample,
};

pub const ProposalInput = struct {
    project_sha256: [64]u8,
    proposer_sha256: [64]u8,
    invariant: []const u8,
    /// Untrusted candidate source. It is persisted for isolated build and
    /// axiom audit, but never compiled or loaded by this module.
    lean_source: []const u8,
    source: Source,
};

pub const PersistResult = struct {
    candidate_id: [64]u8,
    created: bool,
    observation_interval_sha256: ?[64]u8,
};

const WireRun = struct {
    session_id: []const u8,
    run_id: []const u8,
    first_sequence: u64,
    last_sequence: u64,
    interval_sha256: []const u8,
};

const WireSource = union(enum) {
    user_correction: struct {
        correction_sha256: []const u8,
        authority_sha256: []const u8,
    },
    agent_reflection: struct {
        observation: WireRun,
        reflector_sha256: []const u8,
        falsifier: []const u8,
    },
    runtime_counterexample: struct {
        observation: WireRun,
        verdict_sha256: []const u8,
    },
};

const BoundSource = union(enum) {
    user_correction: UserCorrection,
    agent_reflection: struct {
        source: AgentReflection,
        interval_sha256: [64]u8,
    },
    runtime_counterexample: struct {
        source: RuntimeCounterexample,
        interval_sha256: [64]u8,
    },
};

const CandidateBody = struct {
    schema_version: []const u8 = SCHEMA_VERSION,
    project_sha256: []const u8,
    proposer_sha256: []const u8,
    invariant: []const u8,
    lean_source: []const u8,
    source: WireSource,
};

const CandidateRecord = struct {
    candidate_id: []const u8,
    state: []const u8 = "proposed",
    body: CandidateBody,
};

/// Persist one immutable proposal directly beside the session transcript.
/// The content-addressed final name plus O_EXCL makes concurrent duplicates
/// idempotent without a mutable candidate-state ledger. A partial crash file is
/// never repaired or overwritten; a later attempt fails closed on byte drift.
pub fn persist(
    session_dir: []const u8,
    input: ProposalInput,
) !PersistResult {
    try validateInput(input);
    const bound_source = try bindSource(session_dir, input.source);
    const source = wireSource(&bound_source);
    const body = CandidateBody{
        .project_sha256 = input.project_sha256[0..],
        .proposer_sha256 = input.proposer_sha256[0..],
        .invariant = input.invariant,
        .lean_source = input.lean_source,
        .source = source,
    };

    const body_json = try std.json.Stringify.valueAlloc(std.heap.c_allocator, body, .{});
    defer std.heap.c_allocator.free(body_json);
    const candidate_id = observation.sha256Hex(body_json);
    const record = CandidateRecord{ .candidate_id = candidate_id[0..], .body = body };
    const record_json = try std.json.Stringify.valueAlloc(std.heap.c_allocator, record, .{});
    defer std.heap.c_allocator.free(record_json);
    if (record_json.len + 1 > MAX_RECORD_BYTES) return error.RecordTooLarge;

    var path_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const path = try std.fmt.bufPrint(
        &path_buf,
        "{s}/{s}{s}.json\x00",
        .{ session_dir, FILE_PREFIX, candidate_id[0..] },
    );
    const fd = pfs.open(
        @ptrCast(path.ptr),
        .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .NOFOLLOW = true },
        @as(std.c.mode_t, 0o600),
    );
    if (fd >= 0) {
        errdefer _ = pfs.close(fd);
        try pfs.makeCloseOnExec(fd);
        try writeAll(fd, record_json);
        try writeAll(fd, "\n");
        try pfs.fsyncChecked(fd);
        _ = pfs.close(fd);
        return .{
            .candidate_id = candidate_id,
            .created = true,
            .observation_interval_sha256 = intervalDigest(bound_source),
        };
    }

    // Exact duplicate proposals are safe idempotent replays. Any other create
    // failure or partial/corrupt same-id file remains a hard failure.
    const existing = try readExisting(@ptrCast(path.ptr));
    defer std.heap.c_allocator.free(existing);
    if (existing.len != record_json.len + 1 or
        !std.mem.eql(u8, existing[0..record_json.len], record_json) or
        existing[record_json.len] != '\n')
        return error.CandidateCollision;
    return .{
        .candidate_id = candidate_id,
        .created = false,
        .observation_interval_sha256 = intervalDigest(bound_source),
    };
}

pub fn fileName(candidate_id: [64]u8, buffer: *[96]u8) ![]const u8 {
    return std.fmt.bufPrint(buffer, "{s}{s}.json", .{ FILE_PREFIX, candidate_id[0..] });
}

fn validateInput(input: ProposalInput) !void {
    if (!validLowerHex64(input.project_sha256) or
        !validLowerHex64(input.proposer_sha256))
        return error.InvalidIdentity;
    if (!validText(input.invariant, MAX_INVARIANT_BYTES))
        return error.InvalidInvariant;
    if (!validText(input.lean_source, MAX_LEAN_SOURCE_BYTES))
        return error.InvalidLeanSource;
    switch (input.source) {
        .user_correction => |source| {
            if (!validLowerHex64(source.correction_sha256) or
                !validLowerHex64(source.authority_sha256))
                return error.InvalidSourceEvidence;
        },
        .agent_reflection => |source| {
            if (!validLowerHex64(source.reflector_sha256))
                return error.InvalidSourceEvidence;
            if (!validText(source.falsifier, MAX_FALSIFIER_BYTES))
                return error.InvalidFalsifier;
        },
        .runtime_counterexample => |source| {
            if (!validLowerHex64(source.verdict_sha256))
                return error.InvalidSourceEvidence;
        },
    }
}

fn bindSource(
    session_dir: []const u8,
    source: Source,
) !BoundSource {
    return switch (source) {
        .user_correction => |value| .{ .user_correction = value },
        .agent_reflection => |value| blk: {
            const validation = try observation_journal.validateRunBinding(
                session_dir,
                value.observation,
            );
            if (!validation.summary.complete) return error.ObservationJournalIncomplete;
            break :blk .{ .agent_reflection = .{
                .source = value,
                .interval_sha256 = validation.interval_sha256,
            } };
        },
        .runtime_counterexample => |value| blk: {
            const validation = try observation_journal.validateRunBinding(
                session_dir,
                value.observation,
            );
            if (!validation.summary.complete) return error.ObservationJournalIncomplete;
            break :blk .{ .runtime_counterexample = .{
                .source = value,
                .interval_sha256 = validation.interval_sha256,
            } };
        },
    };
}

fn wireSource(source: *const BoundSource) WireSource {
    return switch (source.*) {
        .user_correction => |*value| .{ .user_correction = .{
            .correction_sha256 = value.correction_sha256[0..],
            .authority_sha256 = value.authority_sha256[0..],
        } },
        .agent_reflection => |*value| .{ .agent_reflection = .{
            .observation = wireRun(&value.source.observation, &value.interval_sha256),
            .reflector_sha256 = value.source.reflector_sha256[0..],
            .falsifier = value.source.falsifier,
        } },
        .runtime_counterexample => |*value| .{ .runtime_counterexample = .{
            .observation = wireRun(&value.source.observation, &value.interval_sha256),
            .verdict_sha256 = value.source.verdict_sha256[0..],
        } },
    };
}

fn wireRun(binding: *const observation_journal.RunBinding, digest: *const [64]u8) WireRun {
    return .{
        .session_id = binding.session_id.asSlice(),
        .run_id = binding.run_id.asSlice(),
        .first_sequence = binding.first_sequence,
        .last_sequence = binding.last_sequence,
        .interval_sha256 = digest[0..],
    };
}

fn intervalDigest(source: BoundSource) ?[64]u8 {
    return switch (source) {
        .user_correction => null,
        .agent_reflection => |value| value.interval_sha256,
        .runtime_counterexample => |value| value.interval_sha256,
    };
}

fn validLowerHex64(value: [64]u8) bool {
    for (value) |char| {
        if (!((char >= '0' and char <= '9') or (char >= 'a' and char <= 'f')))
            return false;
    }
    return true;
}

fn validText(value: []const u8, max_bytes: usize) bool {
    return value.len > 0 and value.len <= max_bytes and
        std.unicode.utf8ValidateSlice(value) and
        std.mem.trim(u8, value, " \t\r\n").len > 0;
}

fn writeAll(fd: pfs.Fd, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const n = pfs.write(fd, bytes[offset..]);
        if (n <= 0) return error.WriteFailed;
        offset += @intCast(n);
    }
}

fn readExisting(path: [*:0]const u8) ![]u8 {
    const fd = pfs.open(
        path,
        .{ .ACCMODE = .RDONLY, .NOFOLLOW = true },
        @as(std.c.mode_t, 0),
    );
    if (fd < 0) return error.CreateFailed;
    defer _ = pfs.close(fd);
    const info = pfs.fileInfo(fd) catch return error.StatFailed;
    if (!info.is_regular or info.size == 0 or info.size > MAX_RECORD_BYTES)
        return error.InvalidExistingCandidate;
    const bytes = try std.heap.c_allocator.alloc(u8, @intCast(info.size));
    errdefer std.heap.c_allocator.free(bytes);
    var offset: usize = 0;
    while (offset < bytes.len) {
        const n = pfs.read(fd, bytes[offset..]);
        if (n <= 0) return error.ReadFailed;
        offset += @intCast(n);
    }
    return bytes;
}

test "agent reflection candidate binds a completed observation interval and is idempotent" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    const sid = @import("session_id.zig").SessionId.fromSlice(
        "0123456789abcdef01234567",
    ).?;

    var journal = try observation_journal.Journal.init(root, sid);
    try journal.finishRun("end_turn");
    const binding = try journal.runBinding();
    journal.deinit();

    const hex_a = [_]u8{'a'} ** 64;
    const hex_b = [_]u8{'b'} ** 64;
    const input = ProposalInput{
        .project_sha256 = hex_a,
        .proposer_sha256 = hex_b,
        .invariant = "A completed tool effect must retain its terminal observation.",
        .lean_source = "def preservesTerminalObservation : Bool := true",
        .source = .{ .agent_reflection = .{
            .observation = binding,
            .reflector_sha256 = hex_b,
            .falsifier = "Replay finds a completed effect without a terminal observation.",
        } },
    };
    const created = try persist(root, input);
    try std.testing.expect(created.created);
    try std.testing.expect(created.observation_interval_sha256 != null);
    const replayed = try persist(root, input);
    try std.testing.expect(!replayed.created);
    try std.testing.expectEqualSlices(u8, &created.candidate_id, &replayed.candidate_id);
    var name_buffer: [96]u8 = undefined;
    const name = try fileName(created.candidate_id, &name_buffer);
    var path_buffer: [std.fs.max_path_bytes + 1]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buffer, "{s}/{s}", .{ root, name });
    const artifact = try readExisting(path.ptr);
    defer std.heap.c_allocator.free(artifact);
    try std.testing.expect(std.mem.indexOf(u8, artifact, "\"agent_reflection\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact, "\"state\":\"proposed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact, hex_a[0..]) != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact, binding.run_id.asSlice()) != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact, input.invariant) != null);
    try std.testing.expect(std.mem.indexOf(u8, artifact, input.lean_source) != null);

    var bad_binding = binding;
    bad_binding.last_sequence += 1;
    var bad_input = input;
    bad_input.source = .{ .agent_reflection = .{
        .observation = bad_binding,
        .reflector_sha256 = hex_b,
        .falsifier = "A falsifier remains mandatory.",
    } };
    try std.testing.expectError(error.InvalidRunBinding, persist(root, bad_input));

    bad_input.source = .{ .agent_reflection = .{
        .observation = binding,
        .reflector_sha256 = hex_b,
        .falsifier = "   ",
    } };
    try std.testing.expectError(error.InvalidFalsifier, persist(root, bad_input));
}

test "user correction source remains distinct and requires authority evidence" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    const hex_a = [_]u8{'a'} ** 64;
    const hex_b = [_]u8{'b'} ** 64;
    const hex_c = [_]u8{'c'} ** 64;
    const input = ProposalInput{
        .project_sha256 = hex_a,
        .proposer_sha256 = hex_b,
        .invariant = "Never promote a rule in the incident that proposed it.",
        .lean_source = "def independentPromotion : Bool := true",
        .source = .{ .user_correction = .{
            .correction_sha256 = hex_c,
            .authority_sha256 = hex_a,
        } },
    };
    const result = try persist(root, input);
    try std.testing.expect(result.created);
    try std.testing.expect(result.observation_interval_sha256 == null);

    var invalid = input;
    invalid.source = .{ .user_correction = .{
        .correction_sha256 = [_]u8{'z'} ** 64,
        .authority_sha256 = hex_a,
    } };
    try std.testing.expectError(error.InvalidSourceEvidence, persist(root, invalid));
}
