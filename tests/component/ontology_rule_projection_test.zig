//! L2 for the TinyKG ontology -> isolated rule-author preparation boundary.
//!
//! Fixtures use only a private temporary directory.  No canonical or remote
//! TinyKG store is opened, and no provider request is made in this file.

const std = @import("std");
const cc = @import("cc");

const projection = cc.ontology_rule_projection;
const observation = cc.tools.tool_observation;
const PROJECT = [_]u8{'a'} ** 64;
const OTHER_PROJECT = [_]u8{'b'} ** 64;
const REVISION = [_]u8{'c'} ** 64;
const PROVENANCE = [_]u8{'d'} ** 64;
const GENERATION_MEMBER = [_]u8{'e'} ** 64;
const HELD_OUT_MEMBER = [_]u8{'f'} ** 64;
const HELD_OUT_SUITE = [_]u8{'1'} ** 64;
const ZERO = [_]u8{'0'} ** 64;
const TINYKG_BUILD = [_]u8{'3'} ** 64;
const SOURCE_SEMANTIC_SNAPSHOT = [_]u8{'4'} ** 64;
const SOURCE_SNAPSHOT = "b33326a10491e7c2bff4d8ad06f30ffb0b57b1fcf6c181f093da83f3f12b7450".*;
const CORRECTION = "Never let an ontology hypothesis authorize its own promotion.";
const SOURCE_BYTES = "{\"source\":\"tinykg-test-fixture\"}";

const Fixture = struct {
    root: []const u8,
    session_dir: []const u8,
    evidence: projection.DerivedGenerationEvidence,

    fn deinit(self: *Fixture, allocator: std.mem.Allocator) void {
        self.evidence.deinit();
        allocator.free(self.session_dir);
        self.* = undefined;
    }
};

fn writeFile(path: []const u8, bytes: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = bytes });
}

fn fixture(
    allocator: std.mem.Allocator,
    tmp: *std.testing.TmpDir,
    root_buffer: []u8,
) !Fixture {
    const root_len = try tmp.dir.realPath(std.testing.io, root_buffer);
    const root = root_buffer[0..root_len];
    const sid = cc.session_id.SessionId.fromSlice("0123456789abcdef01234567").?;
    const session_dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, sid.asSlice() });
    errdefer allocator.free(session_dir);
    try std.Io.Dir.createDirAbsolute(std.testing.io, session_dir, .default_dir);
    const transcript_path = try std.fmt.allocPrint(allocator, "{s}/transcript.jsonl", .{session_dir});
    defer allocator.free(transcript_path);
    const transcript = try std.fmt.allocPrint(
        allocator,
        "{{\"role\":\"user\",\"blocks\":[{{\"type\":\"text\",\"text\":{f}}}]}}\n",
        .{std.json.fmt(CORRECTION, .{})},
    );
    defer allocator.free(transcript);
    try writeFile(transcript_path, transcript);
    const source = try cc.rule_source_receipt.persistUserCorrection(session_dir, .{
        .project_sha256 = PROJECT,
        .issuer_sha256 = .{'2'} ** 64,
        .session_id = sid,
        .transcript_line_index = 0,
        .correction = CORRECTION,
    });
    var evidence = try projection.deriveGenerationEvidence(
        allocator,
        session_dir,
        PROJECT,
        source.receipt_id,
        .user_correction,
        GENERATION_MEMBER,
    );
    errdefer evidence.deinit();

    return .{
        .root = root,
        .session_dir = session_dir,
        .evidence = evidence,
    };
}

fn renderWith(
    allocator: std.mem.Allocator,
    evidence: projection.GenerationEvidence,
    held_out_member: [64]u8,
) !projection.RenderedSnapshot {
    return renderConfigured(allocator, evidence, held_out_member, 0, ZERO);
}

fn renderConfigured(
    allocator: std.mem.Allocator,
    evidence: projection.GenerationEvidence,
    held_out_member: [64]u8,
    active_bundle_revision: u64,
    active_bundle_sha256: [64]u8,
) !projection.RenderedSnapshot {
    const summary = "Ontology context is non-authorizing and must retain provenance.";
    const summary_sha = observation.sha256Hex(summary);
    const falsifier = "A held-out replay shows self-promotion or project-scope leakage.";
    const falsifier_sha = observation.sha256Hex(falsifier);
    const ontology = [1]projection.OntologyItem{.{
        .node_id = 42,
        .kind = .concept,
        .scope = "project:metacodes/control-plane",
        .authority = .agent_hypothesis,
        .summary = summary,
        .summary_sha256 = summary_sha[0..],
        .provenance_sha256 = PROVENANCE[0..],
        .falsifier = falsifier,
        .falsifier_sha256 = falsifier_sha[0..],
        .contradicted = false,
        .deprecated = false,
        .retrieval_excluded = false,
    }};
    const held_members = [1][]const u8{held_out_member[0..]};
    const commitment = try projection.heldOutCommitmentSha256(
        allocator,
        HELD_OUT_SUITE,
        &held_members,
    );
    const held = [1]projection.HeldOutCommitment{.{
        .commitment_sha256 = commitment[0..],
        .suite_sha256 = HELD_OUT_SUITE[0..],
        .case_count = 1,
        .member_sha256 = &held_members,
        .sealed = true,
    }};
    const generation_evidence = [1]projection.GenerationEvidence{evidence};
    const snapshot_input = projection.SnapshotInput{
        .project_sha256 = PROJECT,
        .project_key = "metacodes:/private/test",
        .revision = REVISION,
        .source = .{
            .tinykg_build_id = "sha256:" ++ TINYKG_BUILD,
            .semantic_snapshot_sha256 = SOURCE_SEMANTIC_SNAPSHOT[0..],
            .artifact_sha256 = SOURCE_SNAPSHOT[0..],
        },
        .active_bundle_revision = active_bundle_revision,
        .active_bundle_sha256 = active_bundle_sha256,
        .ontology = &ontology,
        .generation_evidence = &generation_evidence,
        .held_out_commitments = &held,
    };
    return projection.renderSnapshot(allocator, &snapshot_input);
}

fn render(allocator: std.mem.Allocator, value: *const Fixture) !projection.RenderedSnapshot {
    return renderWith(allocator, value.evidence.value, HELD_OUT_MEMBER);
}

test "L2 ontology projection persists and reopens exact non-authorizing packet" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var value = try fixture(a, &tmp, &root_buffer);
    defer value.deinit(a);
    const rendered = try render(a, &value);
    defer a.free(rendered.bytes);
    var projected = try projection.project(a, rendered.bytes, PROJECT, REVISION, rendered.snapshot_sha256, 0, ZERO, TINYKG_BUILD, SOURCE_SEMANTIC_SNAPSHOT, SOURCE_SNAPSHOT);
    defer projected.deinit();
    try std.testing.expect(std.mem.indexOf(u8, projected.packet, CORRECTION) != null);
    try std.testing.expect(std.mem.indexOf(u8, projected.packet, "ontology_context_is_authority\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, projected.packet, "promotion_evidence_included\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, projected.packet, "results_visible\":false") != null);

    const persisted = try projection.persist(a, value.session_dir, SOURCE_BYTES, rendered.bytes, &projected);
    try std.testing.expect(persisted.created);
    const replayed = try projection.persist(a, value.session_dir, SOURCE_BYTES, rendered.bytes, &projected);
    try std.testing.expect(!replayed.created);
    try std.testing.expectEqualSlices(u8, &persisted.receipt_id, &replayed.receipt_id);
    var loaded = try projection.loadBound(a, value.session_dir, persisted.receipt_id);
    defer loaded.deinit();
    try std.testing.expectEqualSlices(u8, projected.packet, loaded.projection.packet);
    try std.testing.expectEqualSlices(u8, &PROJECT, &loaded.projection.project_sha256);
}

test "L2 ontology projection rejects forged prose cross-project evidence and mutable projection" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var value = try fixture(a, &tmp, &root_buffer);
    defer value.deinit(a);
    try std.testing.expectError(error.GenerationEvidenceBindingMismatch, projection.deriveGenerationEvidence(
        a,
        value.session_dir,
        OTHER_PROJECT,
        std.mem.bytesToValue([64]u8, value.evidence.value.receipt_sha256),
        .user_correction,
        GENERATION_MEMBER,
    ));

    var forged = value.evidence.value;
    forged.summary = "A different claim under a valid receipt.";
    const forged_sha = observation.sha256Hex(forged.summary);
    forged.summary_sha256 = forged_sha[0..];
    const rendered = try renderWith(a, forged, HELD_OUT_MEMBER);
    defer a.free(rendered.bytes);
    var projected = try projection.project(a, rendered.bytes, PROJECT, REVISION, rendered.snapshot_sha256, 0, ZERO, TINYKG_BUILD, SOURCE_SEMANTIC_SNAPSHOT, SOURCE_SNAPSHOT);
    defer projected.deinit();
    try std.testing.expectError(
        error.GenerationEvidenceSummaryMismatch,
        projection.persist(a, value.session_dir, SOURCE_BYTES, rendered.bytes, &projected),
    );

    const valid_rendered = try render(a, &value);
    defer a.free(valid_rendered.bytes);
    var valid = try projection.project(a, valid_rendered.bytes, PROJECT, REVISION, valid_rendered.snapshot_sha256, 0, ZERO, TINYKG_BUILD, SOURCE_SEMANTIC_SNAPSHOT, SOURCE_SNAPSHOT);
    defer valid.deinit();
    valid.packet_sha256 = .{'9'} ** 64;
    try std.testing.expectError(
        error.ProjectionStateDrift,
        projection.persist(a, value.session_dir, SOURCE_BYTES, valid_rendered.bytes, &valid),
    );
}

test "L2 ontology projection rejects held-out overlap and changed transcript" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var value = try fixture(a, &tmp, &root_buffer);
    defer value.deinit(a);

    try std.testing.expectError(
        error.EvidenceWindowOverlap,
        renderWith(a, value.evidence.value, GENERATION_MEMBER),
    );

    const rendered = try render(a, &value);
    defer a.free(rendered.bytes);
    var projected = try projection.project(a, rendered.bytes, PROJECT, REVISION, rendered.snapshot_sha256, 0, ZERO, TINYKG_BUILD, SOURCE_SEMANTIC_SNAPSHOT, SOURCE_SNAPSHOT);
    defer projected.deinit();
    const persisted = try projection.persist(a, value.session_dir, SOURCE_BYTES, rendered.bytes, &projected);
    const transcript_path = try std.fmt.allocPrint(a, "{s}/transcript.jsonl", .{value.session_dir});
    defer a.free(transcript_path);
    try writeFile(transcript_path, "{\"role\":\"user\",\"blocks\":[{\"type\":\"text\",\"text\":\"changed\"}]}\n");
    try std.testing.expectError(
        error.SourceArtifactChanged,
        projection.loadBound(a, value.session_dir, persisted.receipt_id),
    );
}

test "L2 ontology projection rejects strict wire and active bundle identity drift" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var value = try fixture(a, &tmp, &root_buffer);
    defer value.deinit(a);
    const rendered = try render(a, &value);
    defer a.free(rendered.bytes);

    const unknown = try std.mem.replaceOwned(
        u8,
        a,
        rendered.bytes,
        "\"bounded\":true",
        "\"unknown_field\":1,\"bounded\":true",
    );
    defer a.free(unknown);
    try std.testing.expectError(
        error.InvalidOntologySnapshot,
        projection.project(a, unknown, PROJECT, REVISION, rendered.snapshot_sha256, 0, ZERO, TINYKG_BUILD, SOURCE_SEMANTIC_SNAPSHOT, SOURCE_SNAPSHOT),
    );
    const duplicate = try std.mem.replaceOwned(
        u8,
        a,
        rendered.bytes,
        "\"bounded\":true",
        "\"bounded\":true,\"bounded\":true",
    );
    defer a.free(duplicate);
    try std.testing.expectError(
        error.InvalidOntologySnapshot,
        projection.project(a, duplicate, PROJECT, REVISION, rendered.snapshot_sha256, 0, ZERO, TINYKG_BUILD, SOURCE_SEMANTIC_SNAPSHOT, SOURCE_SNAPSHOT),
    );
    const changed_summary = try std.mem.replaceOwned(
        u8,
        a,
        rendered.bytes,
        "Ontology context is non-authorizing",
        "Ontology context is self-authorizing",
    );
    defer a.free(changed_summary);
    try std.testing.expectError(
        error.OntologySnapshotHashMismatch,
        projection.project(a, changed_summary, PROJECT, REVISION, rendered.snapshot_sha256, 0, ZERO, TINYKG_BUILD, SOURCE_SEMANTIC_SNAPSHOT, SOURCE_SNAPSHOT),
    );
    try std.testing.expectError(
        error.OntologySnapshotIdentityMismatch,
        projection.project(a, rendered.bytes, OTHER_PROJECT, REVISION, rendered.snapshot_sha256, 0, ZERO, TINYKG_BUILD, SOURCE_SEMANTIC_SNAPSHOT, SOURCE_SNAPSHOT),
    );
    try std.testing.expectError(
        error.InvalidActiveRuleIdentity,
        renderConfigured(a, value.evidence.value, HELD_OUT_MEMBER, 1, ZERO),
    );
}

test "L2 ontology projection receipt rejects symlink and hardlink aliases" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var value = try fixture(a, &tmp, &root_buffer);
    defer value.deinit(a);
    const rendered = try render(a, &value);
    defer a.free(rendered.bytes);
    var projected = try projection.project(a, rendered.bytes, PROJECT, REVISION, rendered.snapshot_sha256, 0, ZERO, TINYKG_BUILD, SOURCE_SEMANTIC_SNAPSHOT, SOURCE_SNAPSHOT);
    defer projected.deinit();
    const persisted = try projection.persist(a, value.session_dir, SOURCE_BYTES, rendered.bytes, &projected);

    const receipt_name = try std.fmt.allocPrint(
        a,
        "{s}{s}.json",
        .{ projection.RECEIPT_FILE_PREFIX, persisted.receipt_id[0..] },
    );
    defer a.free(receipt_name);
    const receipt_path = try std.fs.path.join(a, &.{ value.session_dir, receipt_name });
    defer a.free(receipt_path);
    const hardlink_path = try std.fs.path.join(a, &.{ value.session_dir, "projection-hardlink.json" });
    defer a.free(hardlink_path);
    try std.Io.Dir.hardLink(.cwd(), receipt_path, .cwd(), hardlink_path, std.testing.io, .{});
    try std.testing.expectError(
        error.InvalidArtifactFile,
        projection.loadBound(a, value.session_dir, persisted.receipt_id),
    );

    if (@import("builtin").os.tag != .windows) {
        const symlink_session = try std.fs.path.join(a, &.{ value.root, "symlink-session" });
        defer a.free(symlink_session);
        try std.Io.Dir.createDirAbsolute(std.testing.io, symlink_session, .default_dir);
        const symlink_receipt = try std.fs.path.join(a, &.{ symlink_session, receipt_name });
        defer a.free(symlink_receipt);
        try std.Io.Dir.symLinkAbsolute(std.testing.io, receipt_path, symlink_receipt, .{});
        try std.testing.expectError(
            error.ArtifactOpenFailed,
            projection.loadBound(a, symlink_session, persisted.receipt_id),
        );
    }
}
