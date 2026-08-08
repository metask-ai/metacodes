//! Host-grounded source receipts for project-specific rule candidates.
//!
//! A source label is not authority.  `user_correction` is admitted only after
//! the host re-reads the exact durable user transcript line; a runtime
//! counterexample is admitted only after the host re-validates the completed
//! observation interval and a blocked formal verdict.  Receipts are immutable,
//! content-addressed evidence.  They grant no permission and expose no
//! promotion API.

const std = @import("std");
const pfs = @import("platform").fs;
const observation = @import("../tools/observation.zig");
const observation_journal = @import("tool_observation_journal.zig");
const session_id_mod = @import("session_id.zig");
const util_fs = @import("../util/fs.zig");
const project_runtime = @import("../formal/project_harness_runtime.zig");

pub const SCHEMA_VERSION = "metacodes-rule-source-receipt-v1";
pub const FILE_PREFIX = "rule-source-receipt-";
pub const MAX_RECORD_BYTES: usize = 128 * 1024;
const MAX_TRANSCRIPT_BYTES: usize = 64 * 1024 * 1024;
const MAX_CORRECTION_BYTES: usize = 32 * 1024;
const MAX_VERDICT_BYTES: usize = 64 * 1024;

pub const UserCorrectionInput = struct {
    project_sha256: [64]u8,
    issuer_sha256: [64]u8,
    session_id: session_id_mod.SessionId,
    transcript_line_index: u64,
    correction: []const u8,
};

pub const RuntimeCounterexampleInput = struct {
    project_sha256: [64]u8,
    issuer_sha256: [64]u8,
    observation: observation_journal.RunBinding,
    checker_sha256: [64]u8,
    /// Exact single-line JSON emitted by the formal runtime.  It must be a
    /// blocked verdict and is committed by hash, not copied into the receipt.
    verdict_payload: []const u8,
};

pub const PersistResult = struct {
    receipt_id: [64]u8,
    created: bool,
};

pub const Kind = enum {
    user_correction,
    runtime_counterexample,
};

pub const Loaded = struct {
    arena: std.heap.ArenaAllocator,
    receipt_id: [64]u8,
    project_sha256: [64]u8,
    issuer_sha256: [64]u8,
    kind: Kind,
    subject_sha256: [64]u8,
    observation_interval_sha256: ?[64]u8,

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
};

const WireEvidence = union(enum) {
    user_correction: struct {
        session_id: []const u8,
        transcript_line_index: u64,
        transcript_line_sha256: []const u8,
        transcript_prefix_sha256: []const u8,
        correction_sha256: []const u8,
    },
    runtime_counterexample: struct {
        observation: WireRun,
        checker_sha256: []const u8,
        verdict_sha256: []const u8,
    },
};

const WireBody = struct {
    schema_version: []const u8 = SCHEMA_VERSION,
    project_sha256: []const u8,
    issuer_sha256: []const u8,
    issued_by_host: bool = true,
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
        project_sha256: []const u8,
        issuer_sha256: []const u8,
        issued_by_host: bool,
        evidence: union(enum) {
            user_correction: struct {
                session_id: []const u8,
                transcript_line_index: u64,
                transcript_line_sha256: []const u8,
                transcript_prefix_sha256: []const u8,
                correction_sha256: []const u8,
            },
            runtime_counterexample: struct {
                observation: struct {
                    session_id: []const u8,
                    run_id: []const u8,
                    first_sequence: u64,
                    last_sequence: u64,
                    interval_sha256: []const u8,
                },
                checker_sha256: []const u8,
                verdict_sha256: []const u8,
            },
        },
    },
};

pub fn persistUserCorrection(
    session_dir: []const u8,
    input: UserCorrectionInput,
) !PersistResult {
    if (!validLowerHex64(input.project_sha256) or
        !validLowerHex64(input.issuer_sha256))
        return error.InvalidIdentity;
    if (!validText(input.correction, MAX_CORRECTION_BYTES))
        return error.InvalidCorrection;
    if (!std.mem.eql(u8, std.fs.path.basename(session_dir), input.session_id.asSlice()))
        return error.SessionIdentityMismatch;

    const transcript = try readTranscript(session_dir);
    defer std.heap.c_allocator.free(transcript);
    const line = try transcriptLine(transcript, input.transcript_line_index);
    try validateUserLine(line.bytes, input.correction);
    const correction_sha256 = observation.sha256Hex(input.correction);
    const line_sha256 = observation.sha256Hex(line.bytes);
    const prefix_sha256 = observation.sha256Hex(transcript[0..line.prefix_end]);
    return persistBody(session_dir, .{
        .project_sha256 = input.project_sha256[0..],
        .issuer_sha256 = input.issuer_sha256[0..],
        .evidence = .{ .user_correction = .{
            .session_id = input.session_id.asSlice(),
            .transcript_line_index = input.transcript_line_index,
            .transcript_line_sha256 = line_sha256[0..],
            .transcript_prefix_sha256 = prefix_sha256[0..],
            .correction_sha256 = correction_sha256[0..],
        } },
    });
}

pub fn persistRuntimeCounterexample(
    session_dir: []const u8,
    input: RuntimeCounterexampleInput,
) !PersistResult {
    if (!validLowerHex64(input.project_sha256) or
        !validLowerHex64(input.issuer_sha256) or
        !validLowerHex64(input.checker_sha256))
        return error.InvalidIdentity;
    const verdict_binding = try validateBlockedVerdict(
        input.verdict_payload,
        input.checker_sha256,
        input.project_sha256,
    );
    const binding = try observation_journal.validateRunBinding(session_dir, input.observation);
    if (!binding.summary.complete) return error.ObservationJournalIncomplete;
    const verdict_sha256 = observation.sha256Hex(input.verdict_payload);
    if (!try observation_journal.runContainsBlockedVerdict(
        std.heap.c_allocator,
        session_dir,
        input.observation,
        input.checker_sha256,
        verdict_sha256,
        input.project_sha256,
        verdict_binding,
    )) return error.VerdictNotInObservationRun;
    const run = WireRun{
        .session_id = input.observation.session_id.asSlice(),
        .run_id = input.observation.run_id.asSlice(),
        .first_sequence = input.observation.first_sequence,
        .last_sequence = input.observation.last_sequence,
        .interval_sha256 = binding.interval_sha256[0..],
    };
    return persistBody(session_dir, .{
        .project_sha256 = input.project_sha256[0..],
        .issuer_sha256 = input.issuer_sha256[0..],
        .evidence = .{ .runtime_counterexample = .{
            .observation = run,
            .checker_sha256 = input.checker_sha256[0..],
            .verdict_sha256 = verdict_sha256[0..],
        } },
    });
}

/// Re-open and fully validate a receipt.  Candidate admission calls this; an
/// unverified caller-supplied hash never becomes source authority.
pub fn load(
    allocator: std.mem.Allocator,
    session_dir: []const u8,
    receipt_id: [64]u8,
) !Loaded {
    if (!validLowerHex64(receipt_id)) return error.InvalidReceiptId;
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();
    const path = try std.fmt.allocPrint(
        a,
        "{s}/{s}{s}.json",
        .{ session_dir, FILE_PREFIX, receipt_id[0..] },
    );
    const raw = try readBounded(a, path, MAX_RECORD_BYTES);
    if (raw.len < 2 or raw[raw.len - 1] != '\n') return error.InvalidReceipt;
    var parsed = std.json.parseFromSliceLeaky(RawRecord, a, raw[0 .. raw.len - 1], .{
        .ignore_unknown_fields = false,
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidReceipt,
    };
    _ = &parsed;
    const record = parsed;
    const parsed_id = parseLowerHex64(record.receipt_id) orelse return error.InvalidReceipt;
    const project = parseLowerHex64(record.body.project_sha256) orelse return error.InvalidReceipt;
    const issuer = parseLowerHex64(record.body.issuer_sha256) orelse return error.InvalidReceipt;
    if (!std.mem.eql(u8, record.body.schema_version, SCHEMA_VERSION) or
        !record.body.issued_by_host or
        !std.mem.eql(u8, &parsed_id, &receipt_id))
        return error.InvalidReceipt;

    // The receipt id commits the body only, so it remains stable when stored
    // in the outer self-identifying record.
    const body_json = try std.json.Stringify.valueAlloc(a, record.body, .{});
    const expected_id = observation.sha256Hex(body_json);
    if (!std.mem.eql(u8, &expected_id, &receipt_id)) return error.ReceiptHashMismatch;

    var subject: [64]u8 = undefined;
    var interval: ?[64]u8 = null;
    const kind: Kind = switch (record.body.evidence) {
        .user_correction => |evidence| blk: {
            if (session_id_mod.SessionId.fromSlice(evidence.session_id) == null or
                parseLowerHex64(evidence.transcript_line_sha256) == null or
                parseLowerHex64(evidence.transcript_prefix_sha256) == null)
                return error.InvalidReceipt;
            subject = parseLowerHex64(evidence.correction_sha256) orelse return error.InvalidReceipt;
            break :blk .user_correction;
        },
        .runtime_counterexample => |evidence| blk: {
            if (session_id_mod.SessionId.fromSlice(evidence.observation.session_id) == null or
                session_id_mod.SessionId.fromSlice(evidence.observation.run_id) == null or
                parseLowerHex64(evidence.observation.interval_sha256) == null or
                parseLowerHex64(evidence.checker_sha256) == null)
                return error.InvalidReceipt;
            subject = parseLowerHex64(evidence.verdict_sha256) orelse return error.InvalidReceipt;
            interval = parseLowerHex64(evidence.observation.interval_sha256).?;
            break :blk .runtime_counterexample;
        },
    };
    return .{
        .arena = arena,
        .receipt_id = receipt_id,
        .project_sha256 = project,
        .issuer_sha256 = issuer,
        .kind = kind,
        .subject_sha256 = subject,
        .observation_interval_sha256 = interval,
    };
}

fn persistBody(session_dir: []const u8, body: WireBody) !PersistResult {
    const body_json = try std.json.Stringify.valueAlloc(std.heap.c_allocator, body, .{});
    defer std.heap.c_allocator.free(body_json);
    const receipt_id = observation.sha256Hex(body_json);
    const record = WireRecord{ .receipt_id = receipt_id[0..], .body = body };
    const record_json = try std.json.Stringify.valueAlloc(std.heap.c_allocator, record, .{});
    defer std.heap.c_allocator.free(record_json);
    if (record_json.len + 1 > MAX_RECORD_BYTES) return error.RecordTooLarge;

    var path_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const path = try std.fmt.bufPrint(
        &path_buf,
        "{s}/{s}{s}.json\x00",
        .{ session_dir, FILE_PREFIX, receipt_id[0..] },
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
        return .{ .receipt_id = receipt_id, .created = true };
    }
    const existing = try readBounded(std.heap.c_allocator, path[0 .. path.len - 1], MAX_RECORD_BYTES);
    defer std.heap.c_allocator.free(existing);
    if (existing.len != record_json.len + 1 or
        !std.mem.eql(u8, existing[0..record_json.len], record_json) or
        existing[record_json.len] != '\n')
        return error.ReceiptCollision;
    return .{ .receipt_id = receipt_id, .created = false };
}

const TranscriptLine = struct {
    bytes: []const u8,
    prefix_end: usize,
};

fn transcriptLine(transcript: []const u8, wanted: u64) !TranscriptLine {
    var index: u64 = 0;
    var start: usize = 0;
    while (start < transcript.len) {
        const relative_end = std.mem.indexOfScalar(u8, transcript[start..], '\n') orelse
            return error.PartialTranscript;
        const end = start + relative_end;
        if (index == wanted) return .{ .bytes = transcript[start..end], .prefix_end = end + 1 };
        index += 1;
        start = end + 1;
    }
    return error.TranscriptLineMissing;
}

fn validateUserLine(line: []const u8, correction: []const u8) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, std.heap.c_allocator, line, .{
        .duplicate_field_behavior = .@"error",
    }) catch return error.InvalidTranscriptLine;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidTranscriptLine;
    const role = parsed.value.object.get("role") orelse return error.InvalidTranscriptLine;
    const blocks = parsed.value.object.get("blocks") orelse return error.InvalidTranscriptLine;
    if (role != .string or !std.mem.eql(u8, role.string, "user") or blocks != .array)
        return error.NotUserCorrection;
    for (blocks.array.items) |block| {
        if (block != .object) continue;
        const kind = block.object.get("type") orelse continue;
        const text = block.object.get("text") orelse continue;
        if (kind == .string and text == .string and
            std.mem.eql(u8, kind.string, "text") and
            std.mem.eql(u8, text.string, correction)) return;
    }
    return error.CorrectionNotInTranscript;
}

const VerdictProbe = struct {
    schema_version: []const u8,
    checker_version: []const u8,
    request_id: []const u8,
    operation: []const u8,
    kernel_sha256: ?[]const u8 = null,
    candidate_id: ?[]const u8 = null,
    project_sha256: ?[]const u8 = null,
    bundle_sha256: ?[]const u8 = null,
    bundle_revision: ?u64 = null,
    decision: []const u8,
    admitted: bool,
};

fn validateBlockedVerdict(
    payload: []const u8,
    checker_sha256: [64]u8,
    project_sha256: [64]u8,
) !?observation_journal.BlockedVerdictBinding {
    if (payload.len == 0 or payload.len > MAX_VERDICT_BYTES or
        std.mem.indexOfAny(u8, payload, "\r\n") != null)
        return error.InvalidVerdict;
    var parsed = std.json.parseFromSlice(VerdictProbe, std.heap.c_allocator, payload, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    }) catch return error.InvalidVerdict;
    defer parsed.deinit();
    const legacy = std.mem.eql(u8, parsed.value.schema_version, "metacodes-formal-verdict-v2") and
        std.mem.eql(u8, parsed.value.checker_version, "metacodes-formal-kernel-v2");
    const project = std.mem.eql(u8, parsed.value.schema_version, project_runtime.VERDICT_SCHEMA) and
        std.mem.eql(u8, parsed.value.checker_version, project_runtime.CHECKER_VERSION) and
        (std.mem.eql(u8, parsed.value.operation, "pre_decision") or
            std.mem.eql(u8, parsed.value.operation, "post_decision")) and
        parsed.value.kernel_sha256 != null and
        std.mem.eql(u8, parsed.value.kernel_sha256.?, &checker_sha256) and
        parsed.value.candidate_id != null and
        parsed.value.project_sha256 != null and
        parsed.value.bundle_sha256 != null and
        parsed.value.bundle_revision != null and
        parsed.value.bundle_revision.? > 0;
    if ((!legacy and !project) or parseLowerHex64(parsed.value.request_id) == null or
        !validText(parsed.value.operation, 128) or
        parsed.value.admitted or
        !std.mem.eql(u8, parsed.value.decision, "block"))
        return error.NotCounterexample;
    if (!project) return null;
    const candidate = parseLowerHex64(parsed.value.candidate_id.?) orelse return error.InvalidVerdict;
    const verdict_project = parseLowerHex64(parsed.value.project_sha256.?) orelse return error.InvalidVerdict;
    const bundle = parseLowerHex64(parsed.value.bundle_sha256.?) orelse return error.InvalidVerdict;
    if (!std.mem.eql(u8, &verdict_project, &project_sha256)) return error.ProjectIdentityMismatch;
    return .{
        .candidate_id = candidate,
        .project_sha256 = verdict_project,
        .bundle_sha256 = bundle,
        .bundle_revision = parsed.value.bundle_revision.?,
    };
}

fn readTranscript(session_dir: []const u8) ![]u8 {
    var path_buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "{s}/transcript.jsonl", .{session_dir});
    return readBounded(std.heap.c_allocator, path, MAX_TRANSCRIPT_BYTES);
}

fn readBounded(allocator: std.mem.Allocator, path: []const u8, max: usize) ![]u8 {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const fd = pfs.open(path_z.ptr, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true }, 0);
    if (fd < 0) return error.OpenFailed;
    defer _ = pfs.close(fd);
    const before = pfs.fileInfo(fd) catch return error.StatFailed;
    if (!before.is_regular or before.link_count != 1 or before.size == 0 or before.size > max)
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
    if (!after.is_regular or after.link_count != 1 or after.size != before.size)
        return error.ChangedDuringRead;
    return bytes;
}

fn validLowerHex64(value: [64]u8) bool {
    return parseLowerHex64(value[0..]) != null;
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

fn validText(value: []const u8, max: usize) bool {
    return value.len > 0 and value.len <= max and
        std.unicode.utf8ValidateSlice(value) and
        std.mem.trim(u8, value, " \t\r\n").len > 0;
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

test "user correction receipt is grounded in an exact durable user transcript line" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const base_len = try tmp.dir.realPath(std.testing.io, &root_buf);
    const sid = session_id_mod.SessionId.fromSlice("0123456789abcdef01234567").?;
    const session_dir = try std.fmt.allocPrint(std.testing.allocator, "{s}/{s}", .{ root_buf[0..base_len], sid.asSlice() });
    defer std.testing.allocator.free(session_dir);
    try util_fs.mkdirParents(session_dir);
    const transcript_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/transcript.jsonl", .{session_dir});
    defer std.testing.allocator.free(transcript_path);
    try writeTestFile(transcript_path, "{\"role\":\"assistant\",\"blocks\":[{\"type\":\"text\",\"text\":\"prior\"}]}\n" ++
        "{\"role\":\"user\",\"blocks\":[{\"type\":\"text\",\"text\":\"never self-promote\"}]}\n");
    const result = try persistUserCorrection(session_dir, .{
        .project_sha256 = .{'a'} ** 64,
        .issuer_sha256 = .{'b'} ** 64,
        .session_id = sid,
        .transcript_line_index = 1,
        .correction = "never self-promote",
    });
    var loaded = try load(std.testing.allocator, session_dir, result.receipt_id);
    defer loaded.deinit();
    try std.testing.expectEqual(Kind.user_correction, loaded.kind);
    try std.testing.expectEqualSlices(u8, &loaded.project_sha256, &([_]u8{'a'} ** 64));
    try std.testing.expectError(error.CorrectionNotInTranscript, persistUserCorrection(session_dir, .{
        .project_sha256 = .{'a'} ** 64,
        .issuer_sha256 = .{'b'} ** 64,
        .session_id = sid,
        .transcript_line_index = 1,
        .correction = "forged correction",
    }));
}

test "runtime counterexample receipt requires blocked verdict and completed run" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buf);
    const root = root_buf[0..root_len];
    const sid = session_id_mod.SessionId.fromSlice("0123456789abcdef01234567").?;
    const blocked = "{\"schema_version\":\"metacodes-formal-verdict-v2\",\"checker_version\":\"metacodes-formal-kernel-v2\",\"request_id\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"operation\":\"task_audit\",\"decision\":\"block\",\"admitted\":false}";
    var journal = try observation_journal.Journal.init(root, sid);
    try std.testing.expect(journal.sink().emit(.{ .formal_decision = .{
        .dispatch_id = "blocked-before-dispatch",
        .phase = .pre,
        .result = .block,
        .candidate_id = .{'1'} ** 64,
        .project_sha256 = .{'b'} ** 64,
        .bundle_sha256 = .{'2'} ** 64,
        .bundle_revision = 1,
        .kernel_sha256 = .{'d'} ** 64,
        .request_sha256 = .{'a'} ** 64,
        .verdict_sha256 = observation.sha256Hex(blocked),
        .checker_failure = null,
        .checker_elapsed_ns = 1,
        .checker_bytes = 1,
    } }));
    try journal.finishRun("end_turn");
    const binding = try journal.runBinding();
    journal.deinit();
    const result = try persistRuntimeCounterexample(root, .{
        .project_sha256 = .{'b'} ** 64,
        .issuer_sha256 = .{'c'} ** 64,
        .observation = binding,
        .checker_sha256 = .{'d'} ** 64,
        .verdict_payload = blocked,
    });
    var loaded = try load(std.testing.allocator, root, result.receipt_id);
    defer loaded.deinit();
    try std.testing.expectEqual(Kind.runtime_counterexample, loaded.kind);
    try std.testing.expect(loaded.observation_interval_sha256 != null);

    // A shadow verdict is counterfactual evaluation evidence, not proof that
    // the runtime actually blocked the operation.  It must not be laundered
    // into an enforced runtime-counterexample source receipt.
    var shadow_journal = try observation_journal.Journal.init(root, sid);
    try std.testing.expect(shadow_journal.sink().emit(.{ .formal_decision = .{
        .dispatch_id = "shadow-blocked-before-dispatch",
        .phase = .pre,
        .actuation = .shadow,
        .result = .block,
        .candidate_id = .{'1'} ** 64,
        .project_sha256 = .{'b'} ** 64,
        .bundle_sha256 = .{'2'} ** 64,
        .bundle_revision = 1,
        .kernel_sha256 = .{'d'} ** 64,
        .request_sha256 = .{'a'} ** 64,
        .verdict_sha256 = observation.sha256Hex(blocked),
        .checker_failure = null,
        .checker_elapsed_ns = 1,
        .checker_bytes = 1,
    } }));
    try std.testing.expect(shadow_journal.sink().emit(.{ .dispatch_started = .{
        .id = "shadow-blocked-before-dispatch",
        .requested_name = "Write",
        .dispatched_name = "Write",
        .origin = .authoritative,
        .agent_depth = 0,
        .input_bytes = 2,
        .input_sha256 = observation.sha256Hex("{}"),
    } }));
    try std.testing.expect(shadow_journal.sink().emit(.{ .formal_decision = .{
        .dispatch_id = "shadow-blocked-before-dispatch",
        .phase = .post,
        .actuation = .shadow,
        .result = .block,
        .candidate_id = .{'1'} ** 64,
        .project_sha256 = .{'b'} ** 64,
        .bundle_sha256 = .{'2'} ** 64,
        .bundle_revision = 1,
        .kernel_sha256 = .{'d'} ** 64,
        .request_sha256 = .{'e'} ** 64,
        .verdict_sha256 = .{'f'} ** 64,
        .checker_failure = null,
        .checker_elapsed_ns = 1,
        .checker_bytes = 1,
    } }));
    try std.testing.expect(shadow_journal.sink().emit(.{ .dispatch_finished = .{
        .id = "shadow-blocked-before-dispatch",
        .requested_name = "Write",
        .dispatched_name = "Write",
        .origin = .authoritative,
        .agent_depth = 0,
        .outcome = .succeeded,
        .error_code = null,
        .elapsed_ms = 1,
        .result_present = true,
        .result_bytes = 2,
        .result_sha256 = observation.sha256Hex("ok"),
        .effect = null,
        .effect_valid = true,
    } }));
    try shadow_journal.finishRun("end_turn");
    const shadow_binding = try shadow_journal.runBinding();
    shadow_journal.deinit();
    try std.testing.expectError(
        error.VerdictNotInObservationRun,
        persistRuntimeCounterexample(root, .{
            .project_sha256 = .{'b'} ** 64,
            .issuer_sha256 = .{'c'} ** 64,
            .observation = shadow_binding,
            .checker_sha256 = .{'d'} ** 64,
            .verdict_payload = blocked,
        }),
    );
    const admitted = "{\"schema_version\":\"x\",\"checker_version\":\"y\",\"request_id\":\"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\",\"operation\":\"z\",\"decision\":\"admit\",\"admitted\":true}";
    try std.testing.expectError(error.NotCounterexample, persistRuntimeCounterexample(root, .{
        .project_sha256 = .{'b'} ** 64,
        .issuer_sha256 = .{'c'} ** 64,
        .observation = binding,
        .checker_sha256 = .{'d'} ** 64,
        .verdict_payload = admitted,
    }));
}

fn writeTestFile(path: []const u8, bytes: []const u8) !void {
    const path_z = try std.testing.allocator.dupeZ(u8, path);
    defer std.testing.allocator.free(path_z);
    const fd = pfs.open(path_z.ptr, .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .TRUNC = true,
        .NOFOLLOW = true,
    }, @as(std.c.mode_t, 0o600));
    if (fd < 0) return error.TestFileOpenFailed;
    defer _ = pfs.close(fd);
    try writeAll(fd, bytes);
    try pfs.fsyncChecked(fd);
}
