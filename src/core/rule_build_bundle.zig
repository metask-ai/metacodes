//! Host verifier for the offline Lean candidate-build bundle.
//!
//! Python is only an isolated evidence producer. This module reopens every
//! published artifact, checks the manifest and authoritative RuleCandidate,
//! compares the actual toolchain/SDK files, and only then persists the build
//! and axiom lifecycle receipts. Candidate `.olean` is evidence and is never
//! loaded as runtime authority.

const std = @import("std");
const pfs = @import("platform").fs;
const observation = @import("../tools/observation.zig");
const candidate_mod = @import("rule_candidate.zig");
const lifecycle = @import("rule_lifecycle.zig");
const project_rule_spec = @import("project_rule_spec.zig");

pub const MANIFEST_SCHEMA = "metacodes-project-rule-build-v1";
pub const AXIOM_POLICY = "metacodes-project-rule-axiom-policy-empty-v1";
/// A verified manifest hash is also the durable build-bundle identity.  The
/// individual files are persisted under this prefix before lifecycle receipts
/// are created, so promotion can reopen the exact evidence across processes.
pub const EVIDENCE_PREFIX = "project-rule-build-evidence-";
pub const MAX_MANIFEST_BYTES: usize = 256 * 1024;
pub const MAX_FILE_BYTES: usize = 16 * 1024 * 1024;

pub const FileRecord = struct {
    name: []const u8,
    bytes: usize,
    sha256: []const u8,
};

pub const Manifest = struct {
    schema_version: []const u8,
    candidate_id: []const u8,
    project_sha256: []const u8,
    lean_source_sha256: []const u8,
    rule_spec_sha256: []const u8,
    compiled_artifact_sha256: []const u8,
    compiled_artifact_bytes: usize,
    toolchain_sha256: []const u8,
    toolchain_bytes: usize,
    sdk_sha256: []const u8,
    sdk_bytes: usize,
    sdk_olean_sha256: []const u8,
    sdk_olean_bytes: usize,
    axiom_policy: []const u8,
    forbidden_declaration_count: u32,
    unexpected_axiom_count: u32,
    network_disabled: bool,
    secrets_absent: bool,
    source_bounded: bool,
    output_bounded: bool,
    isolation_backend: []const u8,
    compile_elapsed_ns: u64,
    export_elapsed_ns: u64,
    axiom_elapsed_ns: u64,
    files: []const FileRecord,
    completion_marker: bool,
};

pub const ARTIFACT_NAMES = [_][]const u8{
    "candidate.json",
    "rule-spec.json",
    "candidate.olean",
    "compile.stdout",
    "compile.stderr",
    "export.stdout",
    "export.stderr",
    "axiom.stdout",
    "axiom.stderr",
};

pub const TrustedFiles = struct {
    toolchain_path: []const u8,
    sdk_source_path: []const u8,
    sdk_olean_path: []const u8,
};

pub const Actors = struct {
    builder_sha256: [64]u8,
    build_checker_sha256: [64]u8,
    auditor_sha256: [64]u8,
    axiom_checker_sha256: [64]u8,
};

pub const Verified = struct {
    manifest_sha256: [64]u8,
    lean_source_sha256: [64]u8,
    rule_spec_sha256: [64]u8,
    compiled_artifact_sha256: [64]u8,
    toolchain_sha256: [64]u8,
    sdk_sha256: [64]u8,
    sdk_olean_sha256: [64]u8,
    build_log_sha256: [64]u8,
    audit_sha256: [64]u8,
    policy_sha256: [64]u8,
};

pub const Recorded = struct {
    verified: Verified,
    build_receipt_id: [64]u8,
    axiom_receipt_id: [64]u8,
};

pub fn verifyAndRecord(
    allocator: std.mem.Allocator,
    session_dir: []const u8,
    bundle_dir: []const u8,
    candidate_id: [64]u8,
    project_sha256: [64]u8,
    trusted: TrustedFiles,
    actors: Actors,
) !Recorded {
    const source_verified = try verify(
        allocator,
        session_dir,
        bundle_dir,
        candidate_id,
        project_sha256,
        trusted,
    );
    try persistVerifiedArtifacts(
        allocator,
        session_dir,
        bundle_dir,
        source_verified.manifest_sha256,
    );
    // Do not create a lifecycle receipt from the first read.  Reopen the
    // durable, content-addressed copy and make that copy the authoritative
    // build/axiom evidence consumed by promotion.
    const verified = try verifyStored(
        allocator,
        session_dir,
        source_verified.manifest_sha256,
        candidate_id,
        project_sha256,
        trusted,
    );
    if (!verifiedEqual(source_verified, verified))
        return error.BuildEvidenceChangedBeforePersistence;
    const built = try lifecycle.persist(session_dir, .{
        .candidate_id = candidate_id,
        .project_sha256 = project_sha256,
        .actor_sha256 = actors.builder_sha256,
        .checker_sha256 = actors.build_checker_sha256,
        .predecessor_receipt_id = null,
        .evidence = .{ .built = .{
            .manifest_sha256 = verified.manifest_sha256,
            .lean_source_sha256 = verified.lean_source_sha256,
            .rule_spec_sha256 = verified.rule_spec_sha256,
            .compiled_artifact_sha256 = verified.compiled_artifact_sha256,
            .toolchain_sha256 = verified.toolchain_sha256,
            .sdk_sha256 = verified.sdk_sha256,
            .sdk_olean_sha256 = verified.sdk_olean_sha256,
            .build_log_sha256 = verified.build_log_sha256,
            .network_disabled = true,
            .secrets_absent = true,
            .source_bounded = true,
            .output_bounded = true,
            .completed = true,
        } },
    });
    const audited = try lifecycle.persist(session_dir, .{
        .candidate_id = candidate_id,
        .project_sha256 = project_sha256,
        .actor_sha256 = actors.auditor_sha256,
        .checker_sha256 = actors.axiom_checker_sha256,
        .predecessor_receipt_id = built.receipt_id,
        .evidence = .{ .axiom_audited = .{
            .audit_sha256 = verified.audit_sha256,
            .policy_sha256 = verified.policy_sha256,
            .forbidden_declaration_count = 0,
            .unexpected_axiom_count = 0,
            .completed = true,
        } },
    });
    return .{
        .verified = verified,
        .build_receipt_id = built.receipt_id,
        .axiom_receipt_id = audited.receipt_id,
    };
}

pub fn verify(
    allocator: std.mem.Allocator,
    session_dir: []const u8,
    bundle_dir: []const u8,
    candidate_id: [64]u8,
    project_sha256: [64]u8,
    trusted: TrustedFiles,
) !Verified {
    return verifySource(
        allocator,
        session_dir,
        .{ .directory = bundle_dir },
        candidate_id,
        project_sha256,
        trusted,
    );
}

/// Reopen a durable build bundle by the manifest identity carried in the
/// `built` lifecycle receipt.  No caller-selected build directory participates
/// in promotion.
pub fn verifyStored(
    allocator: std.mem.Allocator,
    session_dir: []const u8,
    manifest_sha256: [64]u8,
    candidate_id: [64]u8,
    project_sha256: [64]u8,
    trusted: TrustedFiles,
) !Verified {
    const verified = try verifySource(
        allocator,
        session_dir,
        .{ .stored = .{ .directory = session_dir, .manifest_sha256 = manifest_sha256 } },
        candidate_id,
        project_sha256,
        trusted,
    );
    if (!std.mem.eql(u8, &verified.manifest_sha256, &manifest_sha256))
        return error.BuildManifestIdentityMismatch;
    return verified;
}

const BundleSource = union(enum) {
    directory: []const u8,
    stored: struct {
        directory: []const u8,
        manifest_sha256: [64]u8,
    },
};

fn verifySource(
    allocator: std.mem.Allocator,
    session_dir: []const u8,
    source: BundleSource,
    candidate_id: [64]u8,
    project_sha256: [64]u8,
    trusted: TrustedFiles,
) !Verified {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var candidate = try candidate_mod.load(a, session_dir, candidate_id);
    defer candidate.deinit();
    if (!std.mem.eql(u8, &candidate.project_sha256, &project_sha256))
        return error.ProjectIdentityMismatch;

    const manifest_raw = try readBundleNamed(a, source, "manifest.json", MAX_MANIFEST_BYTES, false);
    var parsed = std.json.parseFromSlice(Manifest, a, manifest_raw, .{
        .ignore_unknown_fields = false,
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    }) catch return error.InvalidBuildManifest;
    defer parsed.deinit();
    const manifest = parsed.value;
    const canonical_manifest = try std.json.Stringify.valueAlloc(a, manifest, .{});
    if (!std.mem.eql(u8, manifest_raw, canonical_manifest))
        return error.NonCanonicalBuildManifest;
    if (!manifest.completion_marker or
        !std.mem.eql(u8, manifest.schema_version, MANIFEST_SCHEMA) or
        !std.mem.eql(u8, manifest.candidate_id, &candidate_id) or
        !std.mem.eql(u8, manifest.project_sha256, &project_sha256) or
        !std.mem.eql(u8, manifest.axiom_policy, "empty") or
        manifest.forbidden_declaration_count != 0 or
        manifest.unexpected_axiom_count != 0 or
        !manifest.network_disabled or !manifest.secrets_absent or
        !manifest.source_bounded or !manifest.output_bounded or
        !validIsolationBackend(manifest.isolation_backend))
        return error.IncompleteBuildEvidence;

    var contents: [ARTIFACT_NAMES.len][]const u8 = undefined;
    for (ARTIFACT_NAMES, 0..) |name, index| {
        contents[index] = try readBundleNamed(a, source, name, MAX_FILE_BYTES, true);
    }
    if (manifest.files.len != ARTIFACT_NAMES.len) return error.InvalidFileManifest;
    var seen = [_]bool{false} ** ARTIFACT_NAMES.len;
    for (manifest.files) |record| {
        const index = expectedIndex(record.name) orelse return error.InvalidFileManifest;
        if (seen[index]) return error.InvalidFileManifest;
        seen[index] = true;
        if (record.bytes != contents[index].len or
            !equalHex(record.sha256, observation.sha256Hex(contents[index])))
            return error.BuildArtifactHashMismatch;
    }

    const authoritative_path = try std.fmt.allocPrint(
        a,
        "{s}/{s}{s}.json",
        .{ session_dir, candidate_mod.FILE_PREFIX, candidate_id[0..] },
    );
    const authoritative_candidate = try readPath(a, authoritative_path, candidate_mod.MAX_RECORD_BYTES, false);
    if (!std.mem.eql(u8, contents[0], authoritative_candidate))
        return error.CandidateArtifactMismatch;
    const canonical_spec = try project_rule_spec.renderCanonical(a, candidate.rule_spec);
    if (!std.mem.eql(u8, contents[1], canonical_spec))
        return error.RuleSpecArtifactMismatch;
    if (!equalHex(manifest.lean_source_sha256, candidate.lean_source_sha256) or
        !equalHex(manifest.rule_spec_sha256, observation.sha256Hex(canonical_spec)) or
        !equalHex(manifest.compiled_artifact_sha256, observation.sha256Hex(contents[2])) or
        manifest.compiled_artifact_bytes != contents[2].len)
        return error.BuildIdentityMismatch;

    if (contents[3].len != 0 or contents[4].len != 0 or contents[6].len != 0 or
        contents[8].len != 0 or
        !std.mem.eql(u8, contents[7], "'CandidateRule.spec_valid' does not depend on any axioms\n"))
        return error.BuildDiagnosticsMismatch;
    // Export stdout is the canonical spec plus one newline.
    if (contents[5].len != canonical_spec.len + 1 or contents[5][canonical_spec.len] != '\n' or
        !std.mem.eql(u8, contents[5][0..canonical_spec.len], canonical_spec))
        return error.BuildDiagnosticsMismatch;

    const toolchain = try hashPath(a, trusted.toolchain_path);
    const sdk = try hashPath(a, trusted.sdk_source_path);
    const sdk_olean = try hashPath(a, trusted.sdk_olean_path);
    if (!equalHex(manifest.toolchain_sha256, toolchain.sha256) or
        manifest.toolchain_bytes != toolchain.bytes or
        !equalHex(manifest.sdk_sha256, sdk.sha256) or manifest.sdk_bytes != sdk.bytes or
        !equalHex(manifest.sdk_olean_sha256, sdk_olean.sha256) or
        manifest.sdk_olean_bytes != sdk_olean.bytes)
        return error.TrustedBuildInputMismatch;

    return .{
        .manifest_sha256 = observation.sha256Hex(manifest_raw),
        .lean_source_sha256 = candidate.lean_source_sha256,
        .rule_spec_sha256 = observation.sha256Hex(canonical_spec),
        .compiled_artifact_sha256 = observation.sha256Hex(contents[2]),
        .toolchain_sha256 = toolchain.sha256,
        .sdk_sha256 = sdk.sha256,
        .sdk_olean_sha256 = sdk_olean.sha256,
        .build_log_sha256 = hashLogs(contents[3..7]),
        .audit_sha256 = observation.sha256Hex(contents[7]),
        .policy_sha256 = observation.sha256Hex(AXIOM_POLICY),
    };
}

const FileHash = struct { sha256: [64]u8, bytes: usize };

fn hashPath(allocator: std.mem.Allocator, path: []const u8) !FileHash {
    const bytes = try readPath(allocator, path, MAX_FILE_BYTES, false);
    return .{ .sha256 = observation.sha256Hex(bytes), .bytes = bytes.len };
}

fn hashLogs(logs: []const []const u8) [64]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("metacodes-project-rule-build-logs-v1\x00");
    for (logs) |bytes| {
        const digest = observation.sha256Hex(bytes);
        hasher.update(&digest);
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return std.fmt.bytesToHex(digest, .lower);
}

fn expectedIndex(name: []const u8) ?usize {
    for (ARTIFACT_NAMES, 0..) |expected, index| {
        if (std.mem.eql(u8, name, expected)) return index;
    }
    return null;
}

fn validIsolationBackend(value: []const u8) bool {
    return std.mem.eql(u8, value, "macos-seatbelt-v1") or
        std.mem.eql(u8, value, "linux-bwrap-v1");
}

fn equalHex(value: []const u8, expected: [64]u8) bool {
    if (value.len != expected.len) return false;
    for (value) |byte| {
        if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return false;
    }
    return std.mem.eql(u8, value, &expected);
}

fn readNamedDirectory(
    allocator: std.mem.Allocator,
    directory: []const u8,
    name: []const u8,
    maximum: usize,
    allow_empty: bool,
) ![]u8 {
    if (expectedIndex(name) == null and !std.mem.eql(u8, name, "manifest.json"))
        return error.InvalidArtifactName;
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ directory, name });
    defer allocator.free(path);
    return readPath(allocator, path, maximum, allow_empty);
}

fn readBundleNamed(
    allocator: std.mem.Allocator,
    source: BundleSource,
    name: []const u8,
    maximum: usize,
    allow_empty: bool,
) ![]u8 {
    return switch (source) {
        .directory => |directory| readNamedDirectory(allocator, directory, name, maximum, allow_empty),
        .stored => |stored| blk: {
            const path = try storedArtifactPath(
                allocator,
                stored.directory,
                stored.manifest_sha256,
                name,
            );
            defer allocator.free(path);
            break :blk readPath(allocator, path, maximum, allow_empty);
        },
    };
}

/// Allocator-owned path for auditing and fault-injection tests.  `name` is
/// restricted to the fixed build-bundle vocabulary; untrusted path fragments
/// never enter this namespace.
pub fn storedArtifactPath(
    allocator: std.mem.Allocator,
    directory: []const u8,
    manifest_sha256: [64]u8,
    name: []const u8,
) ![]u8 {
    if (expectedIndex(name) == null and !std.mem.eql(u8, name, "manifest.json"))
        return error.InvalidArtifactName;
    return std.fmt.allocPrint(
        allocator,
        "{s}/{s}{s}-{s}",
        .{ directory, EVIDENCE_PREFIX, manifest_sha256[0..], name },
    );
}

fn persistVerifiedArtifacts(
    allocator: std.mem.Allocator,
    evidence_dir: []const u8,
    source_dir: []const u8,
    manifest_sha256: [64]u8,
) !void {
    // Persist the manifest last.  A crash may leave harmless addressed files,
    // but can never leave a completion marker followed by missing members.
    for (ARTIFACT_NAMES) |name| {
        const bytes = try readNamedDirectory(allocator, source_dir, name, MAX_FILE_BYTES, true);
        defer allocator.free(bytes);
        try persistStoredArtifact(allocator, evidence_dir, manifest_sha256, name, bytes);
    }
    const manifest = try readNamedDirectory(
        allocator,
        source_dir,
        "manifest.json",
        MAX_MANIFEST_BYTES,
        false,
    );
    defer allocator.free(manifest);
    if (!std.mem.eql(u8, &observation.sha256Hex(manifest), &manifest_sha256))
        return error.BuildManifestIdentityMismatch;
    try persistStoredArtifact(
        allocator,
        evidence_dir,
        manifest_sha256,
        "manifest.json",
        manifest,
    );
    try fsyncDirectory(evidence_dir);
}

fn persistStoredArtifact(
    allocator: std.mem.Allocator,
    directory: []const u8,
    manifest_sha256: [64]u8,
    name: []const u8,
    bytes: []const u8,
) !void {
    const path = try storedArtifactPath(allocator, directory, manifest_sha256, name);
    defer allocator.free(path);
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const fd = pfs.open(path_z.ptr, .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .EXCL = true,
        .NOFOLLOW = true,
    }, @as(std.c.mode_t, 0o600));
    if (fd >= 0) {
        var closed = false;
        errdefer {
            if (!closed) _ = pfs.close(fd);
        }
        try pfs.makeCloseOnExec(fd);
        try writeAll(fd, bytes);
        try pfs.fsyncChecked(fd);
        _ = pfs.close(fd);
        closed = true;
        return;
    }
    const existing = try readPath(allocator, path, MAX_FILE_BYTES, true);
    defer allocator.free(existing);
    if (!std.mem.eql(u8, existing, bytes)) return error.BuildEvidenceCollision;
}

fn verifiedEqual(a: Verified, b: Verified) bool {
    inline for (std.meta.fields(Verified)) |field| {
        if (!std.mem.eql(u8, &@field(a, field.name), &@field(b, field.name))) return false;
    }
    return true;
}

fn writeAll(fd: pfs.Fd, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const count = pfs.write(fd, bytes[offset..]);
        if (count <= 0) return error.ArtifactWriteFailed;
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

fn readPath(
    allocator: std.mem.Allocator,
    path: []const u8,
    maximum: usize,
    allow_empty: bool,
) ![]u8 {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const fd = pfs.open(path_z.ptr, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true }, 0);
    if (fd < 0) return error.ArtifactOpenFailed;
    defer _ = pfs.close(fd);
    const before = pfs.fileInfo(fd) catch return error.ArtifactStatFailed;
    if (!before.is_regular or before.link_count != 1 or before.size > maximum or (!allow_empty and before.size == 0))
        return error.InvalidArtifact;
    const bytes = try allocator.alloc(u8, @intCast(before.size));
    errdefer allocator.free(bytes);
    var offset: usize = 0;
    while (offset < bytes.len) {
        const count = pfs.read(fd, bytes[offset..]);
        if (count <= 0) return error.ArtifactReadFailed;
        offset += @intCast(count);
    }
    const after = pfs.fileInfo(fd) catch return error.ArtifactStatFailed;
    if (!after.is_regular or after.link_count != 1 or after.size != before.size)
        return error.ArtifactChangedDuringRead;
    return bytes;
}

test "build bundle verifier re-reads real artifacts before lifecycle receipts" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    const project = [_]u8{'a'} ** 64;
    const proposer = [_]u8{'b'} ** 64;
    const sid = @import("session_id.zig").SessionId.fromSlice("0123456789abcdef01234567").?;
    var journal = try @import("tool_observation_journal.zig").Journal.init(root, sid);
    try journal.finishRun("end_turn");
    const binding = try journal.runBinding();
    journal.deinit();
    const candidate_result = try candidate_mod.persist(root, .{
        .project_sha256 = project,
        .proposer_sha256 = proposer,
        .invariant = "Successful Write effects are re-observed.",
        .rule_spec = .{
            .target_tool = "Write",
            .deny_target = false,
            .max_input_bytes = 8192,
            .max_agent_depth = 4,
            .authoritative_only = true,
            .effect_requirement = .file_mutation_v1_reobserved,
        },
        .lean_source = "def spec : RuleSpec := { targetTool := \"Write\", denyTarget := false, maxInputBytes := 8192, maxAgentDepth := 4, authoritativeOnly := true, effectRequirement := .fileMutationV1Reobserved }; theorem spec_valid : valid spec = true := by rfl",
        .source = .{ .agent_reflection = .{
            .observation = binding,
            .reflector_sha256 = proposer,
            .falsifier = "A successful Write has no matching host re-read.",
        } },
    });
    var candidate = try candidate_mod.load(std.testing.allocator, root, candidate_result.candidate_id);
    defer candidate.deinit();
    const spec = try project_rule_spec.renderCanonical(std.testing.allocator, candidate.rule_spec);
    defer std.testing.allocator.free(spec);
    const export_output = try std.fmt.allocPrint(std.testing.allocator, "{s}\n", .{spec});
    defer std.testing.allocator.free(export_output);
    const audit = "'CandidateRule.spec_valid' does not depend on any axioms\n";

    const trusted_names = [_][]const u8{ "test-lake", "test-sdk.lean", "test-sdk.olean" };
    const trusted_contents = [_][]const u8{ "lake-binary", "sdk-source", "sdk-olean" };
    var trusted_paths = [_][]u8{""} ** 3;
    defer {
        for (trusted_paths) |path| if (path.len != 0) std.testing.allocator.free(path);
    }
    for (trusted_names, trusted_contents, 0..) |name, bytes, index| {
        trusted_paths[index] = try std.fmt.allocPrint(std.testing.allocator, "{s}/{s}", .{ root, name });
        try testWrite(trusted_paths[index], bytes);
    }

    const authoritative_path = try std.fmt.allocPrint(
        std.testing.allocator,
        "{s}/{s}{s}.json",
        .{ root, candidate_mod.FILE_PREFIX, candidate_result.candidate_id[0..] },
    );
    defer std.testing.allocator.free(authoritative_path);
    const authoritative = try readPath(std.testing.allocator, authoritative_path, candidate_mod.MAX_RECORD_BYTES, false);
    defer std.testing.allocator.free(authoritative);
    const artifact_contents = [_][]const u8{
        authoritative,
        spec,
        "olean-evidence",
        "",
        "",
        export_output,
        "",
        audit,
        "",
    };
    var artifact_hashes: [ARTIFACT_NAMES.len][64]u8 = undefined;
    var records: [ARTIFACT_NAMES.len]FileRecord = undefined;
    for (ARTIFACT_NAMES, artifact_contents, 0..) |name, bytes, index| {
        const path = try std.fmt.allocPrint(std.testing.allocator, "{s}/{s}", .{ root, name });
        defer std.testing.allocator.free(path);
        try testWrite(path, bytes);
        artifact_hashes[index] = observation.sha256Hex(bytes);
        records[index] = .{ .name = name, .bytes = bytes.len, .sha256 = artifact_hashes[index][0..] };
    }
    const toolchain_sha = observation.sha256Hex(trusted_contents[0]);
    const sdk_sha = observation.sha256Hex(trusted_contents[1]);
    const sdk_olean_sha = observation.sha256Hex(trusted_contents[2]);
    const source_sha = candidate.lean_source_sha256;
    const spec_sha = observation.sha256Hex(spec);
    const compiled_sha = observation.sha256Hex(artifact_contents[2]);
    const manifest = Manifest{
        .schema_version = MANIFEST_SCHEMA,
        .candidate_id = candidate_result.candidate_id[0..],
        .project_sha256 = project[0..],
        .lean_source_sha256 = source_sha[0..],
        .rule_spec_sha256 = spec_sha[0..],
        .compiled_artifact_sha256 = compiled_sha[0..],
        .compiled_artifact_bytes = artifact_contents[2].len,
        .toolchain_sha256 = toolchain_sha[0..],
        .toolchain_bytes = trusted_contents[0].len,
        .sdk_sha256 = sdk_sha[0..],
        .sdk_bytes = trusted_contents[1].len,
        .sdk_olean_sha256 = sdk_olean_sha[0..],
        .sdk_olean_bytes = trusted_contents[2].len,
        .axiom_policy = "empty",
        .forbidden_declaration_count = 0,
        .unexpected_axiom_count = 0,
        .network_disabled = true,
        .secrets_absent = true,
        .source_bounded = true,
        .output_bounded = true,
        .isolation_backend = "macos-seatbelt-v1",
        .compile_elapsed_ns = 1,
        .export_elapsed_ns = 1,
        .axiom_elapsed_ns = 1,
        .files = &records,
        .completion_marker = true,
    };
    const manifest_bytes = try std.json.Stringify.valueAlloc(std.testing.allocator, manifest, .{});
    defer std.testing.allocator.free(manifest_bytes);
    const manifest_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/manifest.json", .{root});
    defer std.testing.allocator.free(manifest_path);
    try testWrite(manifest_path, manifest_bytes);

    const recorded = try verifyAndRecord(
        std.testing.allocator,
        root,
        root,
        candidate_result.candidate_id,
        project,
        .{
            .toolchain_path = trusted_paths[0],
            .sdk_source_path = trusted_paths[1],
            .sdk_olean_path = trusted_paths[2],
        },
        .{
            .builder_sha256 = .{'c'} ** 64,
            .build_checker_sha256 = .{'d'} ** 64,
            .auditor_sha256 = .{'e'} ** 64,
            .axiom_checker_sha256 = .{'f'} ** 64,
        },
    );
    var loaded = try lifecycle.load(std.testing.allocator, root, recorded.axiom_receipt_id);
    defer loaded.deinit();
    try std.testing.expectEqual(lifecycle.Stage.axiom_audited, loaded.stage);
    _ = try verifyStored(
        std.testing.allocator,
        root,
        recorded.verified.manifest_sha256,
        candidate_result.candidate_id,
        project,
        .{
            .toolchain_path = trusted_paths[0],
            .sdk_source_path = trusted_paths[1],
            .sdk_olean_path = trusted_paths[2],
        },
    );

    const olean_path = try std.fmt.allocPrint(std.testing.allocator, "{s}/candidate.olean", .{root});
    defer std.testing.allocator.free(olean_path);
    try testWrite(olean_path, "tampered");
    try std.testing.expectError(error.BuildArtifactHashMismatch, verify(
        std.testing.allocator,
        root,
        root,
        candidate_result.candidate_id,
        project,
        .{
            .toolchain_path = trusted_paths[0],
            .sdk_source_path = trusted_paths[1],
            .sdk_olean_path = trusted_paths[2],
        },
    ));
    // The source bundle is no longer authoritative once receipts exist.
    _ = try verifyStored(
        std.testing.allocator,
        root,
        recorded.verified.manifest_sha256,
        candidate_result.candidate_id,
        project,
        .{
            .toolchain_path = trusted_paths[0],
            .sdk_source_path = trusted_paths[1],
            .sdk_olean_path = trusted_paths[2],
        },
    );
    const stored_olean = try storedArtifactPath(
        std.testing.allocator,
        root,
        recorded.verified.manifest_sha256,
        "candidate.olean",
    );
    defer std.testing.allocator.free(stored_olean);
    try testWrite(stored_olean, "tampered");
    try std.testing.expectError(error.BuildArtifactHashMismatch, verifyStored(
        std.testing.allocator,
        root,
        recorded.verified.manifest_sha256,
        candidate_result.candidate_id,
        project,
        .{
            .toolchain_path = trusted_paths[0],
            .sdk_source_path = trusted_paths[1],
            .sdk_olean_path = trusted_paths[2],
        },
    ));
}

fn testWrite(path: []const u8, bytes: []const u8) !void {
    const path_z = try std.testing.allocator.dupeZ(u8, path);
    defer std.testing.allocator.free(path_z);
    const fd = pfs.open(path_z.ptr, .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .TRUNC = true,
        .NOFOLLOW = true,
    }, @as(std.c.mode_t, 0o600));
    if (fd < 0) return error.TestWriteFailed;
    defer _ = pfs.close(fd);
    var offset: usize = 0;
    while (offset < bytes.len) {
        const count = pfs.write(fd, bytes[offset..]);
        if (count <= 0) return error.TestWriteFailed;
        offset += @intCast(count);
    }
}
