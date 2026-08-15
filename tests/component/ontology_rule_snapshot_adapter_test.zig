//! L2 for the production read-only TinyKG ontology snapshot adapter.
//!
//! The fake transport models one consistent TinyKG snapshot command. No provider is
//! constructed or called; the real current vendored TinyKG negative test uses
//! only a private temporary store.

const std = @import("std");
const builtin = @import("builtin");
const cc = @import("cc");

const adapter = cc.kg_ontology_rule_snapshot_adapter;
const projection = cc.ontology_rule_projection;
const rule_author = cc.rule_author;
const observation = cc.tools.tool_observation;

const PROJECT = [_]u8{'a'} ** 64;
const REVISION = [_]u8{'b'} ** 64;
const BUILD = [_]u8{'c'} ** 64;
const PROVENANCE_EVIDENCE = [_]u8{'d'} ** 64;
const GENERATION_MEMBER = [_]u8{'e'} ** 64;
const HELD_OUT_MEMBER = [_]u8{'f'} ** 64;
const HELD_OUT_SUITE = [_]u8{'1'} ** 64;
const ZERO = [_]u8{'0'} ** 64;
const PROJECT_KEY = "metacodes:/private/ontology-adapter-l2";
const CORRECTION = "Ontology context cannot authorize its own promotion.";

const Fake = struct {
    allocator: std.mem.Allocator,
    snapshot_calls: usize = 0,
    drift: bool = false,
    build_drift: bool = false,
    malformed: bool = false,
    snapshot_bytes: ?[]u8 = null,

    fn deinit(self: *Fake) void {
        if (self.snapshot_bytes) |bytes| self.allocator.free(bytes);
    }

    fn transport(self: *Fake) adapter.ReadTransport {
        return .{
            .ptr = self,
            .build_sha256_fn = buildSha256,
            .snapshot_fn = snapshot,
        };
    }

    fn cast(ptr: *anyopaque) *Fake {
        return @ptrCast(@alignCast(ptr));
    }

    fn buildSha256(ptr: *anyopaque) ![64]u8 {
        const self = cast(ptr);
        return if (self.build_drift and self.snapshot_calls >= 2) .{'9'} ** 64 else BUILD;
    }

    fn snapshot(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        project_node_id: u64,
        project_sha256: [64]u8,
        project_key: []const u8,
    ) ![]u8 {
        const self = cast(ptr);
        self.snapshot_calls += 1;
        if (self.malformed) return allocator.dupe(u8, "{\"not\":\"the protocol\"}");
        const bytes = self.snapshot_bytes orelse return error.MissingFixture;
        if (project_node_id != 7 or !std.mem.eql(u8, &project_sha256, &PROJECT) or
            !std.mem.eql(u8, project_key, PROJECT_KEY))
            return error.RequestBindingLost;
        if (self.drift and self.snapshot_calls == 2) {
            const drifted = try std.mem.replaceOwned(u8, allocator, bytes, REVISION[0..8], "88888888");
            return drifted;
        }
        return allocator.dupe(u8, bytes);
    }
};

const SourceItem = struct {
    node_id: u64,
    kind: projection.OntologyKind,
    scope: []const u8,
    authority: projection.Authority,
    summary: []const u8,
    summary_sha256: []const u8,
    provenance: []const adapter.ProvenanceRef,
    provenance_sha256: []const u8,
    falsifier: []const u8,
    falsifier_sha256: []const u8,
    contradicted: bool,
    deprecated: bool,
    retrieval_excluded: bool,
};

const SourceBody = struct {
    schema_version: []const u8 = adapter.SOURCE_SCHEMA,
    capability: []const u8 = adapter.CAPABILITY,
    tinykg_build_id: []const u8,
    project_node_id: u64 = 7,
    project_sha256: []const u8 = PROJECT[0..],
    project_key: []const u8 = PROJECT_KEY,
    revision: []const u8 = REVISION[0..],
    bounded: bool = true,
    truncated: bool = false,
    max_items: u64 = projection.MAX_ONTOLOGY_ITEMS,
    max_chars: u64 = 200_000,
    used_chars: u64,
    ontology: []const SourceItem,
};

const SourceRecord = struct {
    schema_version: []const u8,
    capability: []const u8,
    tinykg_build_id: []const u8,
    project_node_id: u64,
    project_sha256: []const u8,
    project_key: []const u8,
    revision: []const u8,
    bounded: bool,
    truncated: bool,
    max_items: u64,
    max_chars: u64,
    used_chars: u64,
    ontology: []const SourceItem,
    snapshot_sha256: []const u8,
};

fn sourceSnapshot(allocator: std.mem.Allocator) ![]u8 {
    return sourceSnapshotWithProvenance(allocator, &.{.{
        .kind = .user_correction,
        .node_id = 17,
        .evidence_sha256 = PROVENANCE_EVIDENCE[0..],
    }});
}

fn sourceSnapshotWithProvenance(
    allocator: std.mem.Allocator,
    provenance_refs: []const adapter.ProvenanceRef,
) ![]u8 {
    const summary = "A governed ontology is context, not promotion authority.";
    const falsifier = "A held-out replay observes context self-authorizing a rule.";
    const summary_sha = observation.sha256Hex(summary);
    const falsifier_sha = observation.sha256Hex(falsifier);
    const provenance_json = try std.json.Stringify.valueAlloc(allocator, .{
        .schema_version = "tinykg-ontology-provenance-v1",
        .refs = provenance_refs,
    }, .{});
    defer allocator.free(provenance_json);
    const provenance_sha = observation.sha256Hex(provenance_json);
    const item = SourceItem{
        .node_id = 42,
        .kind = .concept,
        .scope = "project:metacodes/control-plane",
        .authority = .agent_hypothesis,
        .summary = summary,
        .summary_sha256 = summary_sha[0..],
        .provenance = provenance_refs,
        .provenance_sha256 = provenance_sha[0..],
        .falsifier = falsifier,
        .falsifier_sha256 = falsifier_sha[0..],
        .contradicted = false,
        .deprecated = false,
        .retrieval_excluded = false,
    };
    const build_id = "sha256:" ++ BUILD;
    const body = SourceBody{
        .tinykg_build_id = build_id,
        .used_chars = summary.len + falsifier.len,
        .ontology = &.{item},
    };
    const body_json = try std.json.Stringify.valueAlloc(allocator, body, .{});
    defer allocator.free(body_json);
    const digest = observation.sha256Hex(body_json);
    return std.json.Stringify.valueAlloc(allocator, SourceRecord{
        .schema_version = body.schema_version,
        .capability = body.capability,
        .tinykg_build_id = body.tinykg_build_id,
        .project_node_id = body.project_node_id,
        .project_sha256 = body.project_sha256,
        .project_key = body.project_key,
        .revision = body.revision,
        .bounded = body.bounded,
        .truncated = body.truncated,
        .max_items = body.max_items,
        .max_chars = body.max_chars,
        .used_chars = body.used_chars,
        .ontology = body.ontology,
        .snapshot_sha256 = digest[0..],
    }, .{});
}

fn rebindSourceSnapshot(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var parsed = try std.json.parseFromSlice(SourceRecord, allocator, raw, .{
        .ignore_unknown_fields = false,
        .allocate = .alloc_always,
        .duplicate_field_behavior = .@"error",
    });
    defer parsed.deinit();
    const value = parsed.value;
    const body_json = try std.json.Stringify.valueAlloc(allocator, SourceBody{
        .tinykg_build_id = value.tinykg_build_id,
        .project_node_id = value.project_node_id,
        .project_sha256 = value.project_sha256,
        .project_key = value.project_key,
        .revision = value.revision,
        .bounded = value.bounded,
        .truncated = value.truncated,
        .max_items = value.max_items,
        .max_chars = value.max_chars,
        .used_chars = value.used_chars,
        .ontology = value.ontology,
    }, .{});
    defer allocator.free(body_json);
    const digest = observation.sha256Hex(body_json);
    return std.json.Stringify.valueAlloc(allocator, SourceRecord{
        .schema_version = value.schema_version,
        .capability = value.capability,
        .tinykg_build_id = value.tinykg_build_id,
        .project_node_id = value.project_node_id,
        .project_sha256 = value.project_sha256,
        .project_key = value.project_key,
        .revision = value.revision,
        .bounded = value.bounded,
        .truncated = value.truncated,
        .max_items = value.max_items,
        .max_chars = value.max_chars,
        .used_chars = value.used_chars,
        .ontology = value.ontology,
        .snapshot_sha256 = digest[0..],
    }, .{});
}

fn replacedAndRebound(
    allocator: std.mem.Allocator,
    raw: []const u8,
    needle: []const u8,
    replacement: []const u8,
) ![]u8 {
    const changed = try std.mem.replaceOwned(u8, allocator, raw, needle, replacement);
    defer allocator.free(changed);
    return rebindSourceSnapshot(allocator, changed);
}

const LocalFixture = struct {
    session_dir: []u8,
    evidence: projection.DerivedGenerationEvidence,
    held: [1]projection.HeldOutCommitment,
    held_members: [1][]const u8,
    held_commitment: [64]u8,

    fn deinit(self: *LocalFixture, allocator: std.mem.Allocator) void {
        self.evidence.deinit();
        allocator.free(self.session_dir);
        self.* = undefined;
    }
};

fn localFixture(
    allocator: std.mem.Allocator,
    tmp: *std.testing.TmpDir,
    root_buffer: []u8,
) !LocalFixture {
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
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = transcript_path, .data = transcript });
    const receipt = try cc.rule_source_receipt.persistUserCorrection(session_dir, .{
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
        receipt.receipt_id,
        .user_correction,
        GENERATION_MEMBER,
    );
    errdefer evidence.deinit();
    const members = [1][]const u8{HELD_OUT_MEMBER[0..]};
    const commitment = try projection.heldOutCommitmentSha256(allocator, HELD_OUT_SUITE, &members);
    return .{
        .session_dir = session_dir,
        .evidence = evidence,
        .held = .{.{
            .commitment_sha256 = undefined,
            .suite_sha256 = HELD_OUT_SUITE[0..],
            .case_count = 1,
            .member_sha256 = undefined,
            .sealed = true,
        }},
        .held_members = members,
        .held_commitment = commitment,
    };
}

fn request(value: *LocalFixture) adapter.Request {
    return requestFor(value, 7);
}

fn requestFor(value: *LocalFixture, project_node_id: u64) adapter.Request {
    value.held[0].member_sha256 = &value.held_members;
    value.held[0].commitment_sha256 = value.held_commitment[0..];
    return .{
        .project_node_id = project_node_id,
        .project_sha256 = PROJECT,
        .project_key = PROJECT_KEY,
        .active_rules = .{ .bundle_revision = 0, .bundle_sha256 = ZERO },
        .generation_evidence = &.{value.evidence.value},
        .held_out_commitments = &value.held,
    };
}

fn completedFailureRun(session_dir: []const u8) !cc.tool_observation_journal.RunBinding {
    const sid = cc.session_id.SessionId.fromSlice("0123456789abcdef01234567").?;
    var journal = try cc.tool_observation_journal.Journal.init(session_dir, sid);
    errdefer journal.deinit();
    const ids = [_][]const u8{ "ontology-failure-0", "ontology-failure-1", "ontology-failure-2" };
    for (ids) |id| {
        try std.testing.expect(journal.sink().emit(.{ .dispatch_started = .{
            .id = id,
            .requested_name = "Write",
            .dispatched_name = "Write",
            .origin = .authoritative,
            .agent_depth = 0,
            .input_bytes = 2,
            .input_sha256 = observation.sha256Hex("{}"),
        } }));
        try std.testing.expect(journal.sink().emit(.{ .dispatch_finished = .{
            .id = id,
            .requested_name = "Write",
            .dispatched_name = "Write",
            .origin = .authoritative,
            .agent_depth = 0,
            .outcome = .tool_error,
            .error_code = "TypedFailure",
            .elapsed_ms = 1,
            .result_present = true,
            .result_bytes = 2,
            .result_sha256 = observation.sha256Hex("{}"),
            .effect = null,
            .effect_valid = true,
        } }));
    }
    try journal.finishRun("end_turn");
    const binding = try journal.runBinding();
    journal.deinit();
    return binding;
}

fn findVendoredTinyKg(allocator: std.mem.Allocator) ?[]u8 {
    if (builtin.os.tag == .windows) return null;
    const cwd = cc.util_fs.getCwd(allocator) catch return null;
    defer allocator.free(cwd);
    const local = std.fmt.allocPrint(
        allocator,
        "{s}/zig-out/vendor/tinykg/tinykg",
        .{cwd},
    ) catch return null;
    if (isExecutable(allocator, local)) return local;
    allocator.free(local);

    if (std.c.getenv("METACODES_TEST_TINYKG_BIN")) |configured_c| {
        const configured = allocator.dupe(u8, std.mem.span(configured_c)) catch return null;
        if (isExecutable(allocator, configured)) return configured;
        allocator.free(configured);
    }

    const home_c = std.c.getenv("HOME") orelse return null;
    const home = std.mem.span(home_c);
    const fallbacks = [_][]const u8{
        "prj/tinykg/zig-out/bin/tinykg",
        "prj/cc-t2z/metacodes/zig-out/vendor/tinykg/tinykg",
    };
    for (fallbacks) |relative| {
        const path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ home, relative }) catch continue;
        if (isExecutable(allocator, path)) return path;
        allocator.free(path);
    }
    return null;
}

fn isExecutable(allocator: std.mem.Allocator, path: []const u8) bool {
    const path_z = allocator.dupeZ(u8, path) catch return false;
    defer allocator.free(path_z);
    return std.c.access(path_z.ptr, std.c.X_OK) == 0;
}

fn writeExecutable(allocator: std.mem.Allocator, path: []const u8, bytes: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{ .sub_path = path, .data = bytes });
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    if (std.c.chmod(path_z.ptr, 0o700) != 0) return error.SkipZigTest;
}

test "L2 consistent TinyKG source becomes bound projection receipt for rule-author v2" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var local = try localFixture(a, &tmp, &root_buffer);
    defer local.deinit(a);
    var fake = Fake{ .allocator = a, .snapshot_bytes = try sourceSnapshot(a) };
    defer fake.deinit();

    var prepared = try adapter.prepare(a, fake.transport(), request(&local));
    defer prepared.deinit();
    try std.testing.expectEqual(@as(usize, 2), fake.snapshot_calls);
    try std.testing.expect(std.mem.indexOf(u8, prepared.projected.packet, CORRECTION) != null);
    try std.testing.expect(std.mem.indexOf(u8, prepared.projected.packet, "ontology_context_is_authority\":false") != null);
    const result = try adapter.persist(a, local.session_dir, &prepared);
    try std.testing.expect(result.created);
    try std.testing.expectEqualSlices(u8, &BUILD, &result.tinykg_build_sha256);
    try std.testing.expectEqualSlices(u8, &REVISION, &result.ontology_revision);
    var loaded = try projection.loadBound(a, local.session_dir, result.receipt_id);
    defer loaded.deinit();
    try std.testing.expectEqualSlices(u8, &result.source_semantic_snapshot_sha256, &loaded.projection.source_semantic_snapshot_sha256);
    try std.testing.expectEqualSlices(u8, &result.source_artifact_sha256, &loaded.projection.source_artifact_sha256);

    const run = try completedFailureRun(local.session_dir);
    var authored = try rule_author.prepare(a, .{
        .session_dir = local.session_dir,
        .project_sha256 = PROJECT,
        .author_sha256 = .{'2'} ** 64,
        .provider_sha256 = .{'3'} ** 64,
        .budget_authorization_sha256 = .{'4'} ** 64,
        .model = "ontology-adapter-l2-control-provider",
        .observation = run,
        .trigger = .repeated_typed_failure,
        .evidence = &.{},
        .caps = .{
            .max_cost_microusd = 1_000_000,
            .max_input_tokens = 100_000,
            .max_output_tokens = 256,
        },
        .pricing = .{
            .provenance_sha256 = .{'5'} ** 64,
            .input_microusd_per_mtok = 3_000_000,
            .output_microusd_per_mtok = 15_000_000,
            .cache_read_microusd_per_mtok = 300_000,
            .cache_write_microusd_per_mtok = 3_750_000,
        },
        .ontology_projection = .{
            .receipt_id = result.receipt_id,
            .ontology_revision = result.ontology_revision,
            .ontology_snapshot_sha256 = result.ontology_snapshot_sha256,
            .active_bundle_revision = 0,
            .active_bundle_sha256 = ZERO,
        },
    });
    defer authored.deinit();
    const binding = switch (authored.protocol) {
        .v1 => return error.ExpectedRuleAuthorV2,
        .v2 => |value| value,
    };
    try std.testing.expectEqualSlices(u8, &result.receipt_id, &binding.receipt_id);
    try std.testing.expectEqualSlices(u8, &result.packet_sha256, &binding.packet_sha256);
    // The source identities are committed by the content-addressed projection
    // receipt/packet. Keep rule-author v2's outer binding backward compatible.
    try std.testing.expect(std.mem.indexOf(u8, authored.packet, result.source_artifact_sha256[0..]) != null);
    try std.testing.expect(std.mem.indexOf(u8, authored.packet, CORRECTION) != null);
    try std.testing.expect(std.mem.indexOf(u8, authored.packet, PROVENANCE_EVIDENCE[0..]) == null);
}

test "L2 ontology source rejects drift malformed wire and build replacement before persistence" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var local = try localFixture(a, &tmp, &root_buffer);
    defer local.deinit(a);

    var drift = Fake{ .allocator = a, .snapshot_bytes = try sourceSnapshot(a), .drift = true };
    defer drift.deinit();
    try std.testing.expectError(
        error.OntologySourceDrift,
        adapter.execute(a, local.session_dir, drift.transport(), request(&local)),
    );
    var build_drift = Fake{ .allocator = a, .snapshot_bytes = try sourceSnapshot(a), .build_drift = true };
    defer build_drift.deinit();
    try std.testing.expectError(
        error.TinyKgBuildDrift,
        adapter.execute(a, local.session_dir, build_drift.transport(), request(&local)),
    );
    var malformed = Fake{ .allocator = a, .malformed = true };
    defer malformed.deinit();
    try std.testing.expectError(
        error.InvalidOntologySource,
        adapter.execute(a, local.session_dir, malformed.transport(), request(&local)),
    );
}

test "L2 ontology source rejects governance identity ordering and content binding drift" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var local = try localFixture(a, &tmp, &root_buffer);
    defer local.deinit(a);
    const valid = try sourceSnapshot(a);
    defer a.free(valid);

    const bounded = try std.mem.replaceOwned(u8, a, valid, "\"bounded\":true", "\"bounded\":false");
    var bounded_fake = Fake{ .allocator = a, .snapshot_bytes = bounded };
    defer bounded_fake.deinit();
    try std.testing.expectError(
        error.InvalidOntologySource,
        adapter.prepare(a, bounded_fake.transport(), request(&local)),
    );

    const truncated = try std.mem.replaceOwned(u8, a, valid, "\"truncated\":false", "\"truncated\":true");
    var truncated_fake = Fake{ .allocator = a, .snapshot_bytes = truncated };
    defer truncated_fake.deinit();
    try std.testing.expectError(
        error.InvalidOntologySource,
        adapter.prepare(a, truncated_fake.transport(), request(&local)),
    );

    const wrong_capability = try std.mem.replaceOwned(u8, a, valid, adapter.CAPABILITY, "tinykg-ontology-rule-snapshot-v2");
    var capability_fake = Fake{ .allocator = a, .snapshot_bytes = wrong_capability };
    defer capability_fake.deinit();
    try std.testing.expectError(
        error.InvalidOntologySource,
        adapter.prepare(a, capability_fake.transport(), request(&local)),
    );

    const zero_node = try replacedAndRebound(a, valid, "\"node_id\":42", "\"node_id\":0");
    var node_fake = Fake{ .allocator = a, .snapshot_bytes = zero_node };
    defer node_fake.deinit();
    try std.testing.expectError(
        error.InvalidOntologySource,
        adapter.prepare(a, node_fake.transport(), request(&local)),
    );

    const summary = try replacedAndRebound(
        a,
        valid,
        "A governed ontology is context, not promotion authority.",
        "A governed ontology is authority, not merely context.",
    );
    var summary_fake = Fake{ .allocator = a, .snapshot_bytes = summary };
    defer summary_fake.deinit();
    try std.testing.expectError(
        error.OntologyItemBindingMismatch,
        adapter.prepare(a, summary_fake.transport(), request(&local)),
    );

    const provenance = try replacedAndRebound(
        a,
        valid,
        PROVENANCE_EVIDENCE[0..],
        GENERATION_MEMBER[0..],
    );
    var provenance_fake = Fake{ .allocator = a, .snapshot_bytes = provenance };
    defer provenance_fake.deinit();
    try std.testing.expectError(
        error.OntologyProvenanceHashMismatch,
        adapter.prepare(a, provenance_fake.transport(), request(&local)),
    );

    const noncanonical = try std.fmt.allocPrint(a, "{s}\n", .{valid});
    var canonical_fake = Fake{ .allocator = a, .snapshot_bytes = noncanonical };
    defer canonical_fake.deinit();
    try std.testing.expectError(
        error.NonCanonicalOntologySource,
        adapter.prepare(a, canonical_fake.transport(), request(&local)),
    );
}

test "L2 source artifact tamper invalidates projection receipt" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var local = try localFixture(a, &tmp, &root_buffer);
    defer local.deinit(a);
    var fake = Fake{ .allocator = a, .snapshot_bytes = try sourceSnapshot(a) };
    defer fake.deinit();
    const result = try adapter.execute(a, local.session_dir, fake.transport(), request(&local));
    const source_path = try std.fmt.allocPrint(
        a,
        "{s}/{s}{s}.json",
        .{ local.session_dir, projection.SOURCE_FILE_PREFIX, result.source_artifact_sha256[0..] },
    );
    defer a.free(source_path);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = source_path,
        .data = "{\"tampered\":true}",
    });
    try std.testing.expectError(
        error.SourceArtifactChanged,
        projection.loadBound(a, local.session_dir, result.receipt_id),
    );
}

fn runTinyKg(a: std.mem.Allocator, bin: []const u8, args: []const []const u8) !void {
    var argv: std.ArrayList(?[*:0]const u8) = .empty;
    defer {
        for (argv.items) |it| if (it) |s| a.free(std.mem.span(s));
        argv.deinit(a);
    }
    try argv.append(a, (try a.dupeZ(u8, bin)).ptr);
    for (args) |arg| try argv.append(a, (try a.dupeZ(u8, arg)).ptr);
    try argv.append(a, null);
    const common = cc.tools_common;
    const out = try common.spawnCaptureWithStderrTimed(
        argv.items,
        a,
        null,
        30_000,
        null,
        common.MAX_SPAWN_CAPTURE_BYTES,
        null,
    );
    defer a.free(out.stdout);
    defer a.free(out.stderr);
    if (out.exit_code != 0) return error.TinyKgSeedFailed;
}

test "L2 real TinyKG scratch store snapshot binds through prepare persist and rule-author v2" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const bin = findVendoredTinyKg(a) orelse return error.SkipZigTest;
    defer a.free(bin);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var local = try localFixture(a, &tmp, &root_buffer);
    defer local.deinit(a);
    var store_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &store_buf);
    const root = store_buf[0..root_len];
    const store = try std.fmt.allocPrint(a, "{s}/scratch.kg", .{root});
    defer a.free(store);

    // Seed one governed project scope through the real CLI write surface:
    // project identity, one current proposition, two provenance evidence
    // nodes, and the authority/falsifier/provenance properties the exporter
    // documents as its storage contract. Provenance refs deliberately span
    // two kinds in canonical declaration order
    // (user_correction < host_observation).
    try runTinyKg(a, bin, &.{ "init", store });
    try runTinyKg(a, bin, &.{ "add-node", store, "project", "governed scratch project" }); // 1
    try runTinyKg(a, bin, &.{ "set-property", store, "node", "1", "project_sha256", PROJECT[0..] });
    try runTinyKg(a, bin, &.{ "set-property", store, "node", "1", "project_key", PROJECT_KEY });
    try runTinyKg(a, bin, &.{
        "add-node",
        store,
        "concept",
        "Edit, not Write, is required for existing files.",
        "--schema-type",
        "proposition",
    }); // 2
    try runTinyKg(a, bin, &.{ "add-node", store, "observation", "user correction evidence" }); // 3
    try runTinyKg(a, bin, &.{ "add-node", store, "observation", "host observation evidence" }); // 4
    try runTinyKg(a, bin, &.{ "relate", store, "1", "contain", "2" });
    try runTinyKg(a, bin, &.{ "relate", store, "1", "contain", "3" });
    try runTinyKg(a, bin, &.{ "relate", store, "1", "contain", "4" });
    try runTinyKg(a, bin, &.{ "set-property", store, "node", "2", "ontology_authority", "user" });
    try runTinyKg(a, bin, &.{
        "set-property",
        store,
        "node",
        "2",
        "ontology_falsifier",
        "A replay observes Write dispatched onto an existing file.",
    });
    const provenance = "{\"schema_version\":\"tinykg-ontology-provenance-v1\",\"refs\":[" ++
        "{\"kind\":\"user_correction\",\"node_id\":3,\"evidence_sha256\":\"" ++ PROVENANCE_EVIDENCE ++ "\"}," ++
        "{\"kind\":\"host_observation\",\"node_id\":4,\"evidence_sha256\":\"" ++ PROVENANCE_EVIDENCE ++ "\"}]}";
    try runTinyKg(a, bin, &.{ "set-property", store, "node", "2", "ontology_provenance", provenance });

    var client = try cc.kg_client.KgClient.init(a, .{
        .home = root,
        .domain = "ontology-scratch-l2",
        .config_bin = bin,
        .config_store = store,
        .env_bin = "",
        .env_store = "",
    });
    defer client.deinit();
    client.ensureReady();
    try std.testing.expect(client.ready);
    var transport = adapter.KgClientTransport{ .client = &client };

    // Identity negatives first, while the session dir is still artifact-free:
    // a non-project node and an absent node both fail typed before any
    // persistence side effect.
    try std.testing.expectError(
        cc.kg_client.KgError.Data,
        adapter.prepare(a, transport.transport(), requestFor(&local, 2)),
    );
    try std.testing.expectError(
        cc.kg_client.KgError.Data,
        adapter.prepare(a, transport.transport(), requestFor(&local, 999)),
    );
    var artifacts = try std.Io.Dir.openDirAbsolute(std.testing.io, local.session_dir, .{ .iterate = true });
    defer artifacts.close(std.testing.io);
    var iterator = artifacts.iterate();
    while (try iterator.next(std.testing.io)) |entry| {
        try std.testing.expect(!std.mem.startsWith(u8, entry.name, projection.SNAPSHOT_FILE_PREFIX));
        try std.testing.expect(!std.mem.startsWith(u8, entry.name, projection.SOURCE_FILE_PREFIX));
        try std.testing.expect(!std.mem.startsWith(u8, entry.name, projection.RECEIPT_FILE_PREFIX));
    }

    // Real positive vertical slice: one atomic CLI snapshot -> strict parse ->
    // re-observation -> content-addressed receipt -> rule-author v2 binding.
    var prepared = try adapter.prepare(a, transport.transport(), requestFor(&local, 1));
    defer prepared.deinit();
    try std.testing.expect(std.mem.indexOf(u8, prepared.projected.packet, CORRECTION) != null);
    try std.testing.expect(std.mem.indexOf(u8, prepared.projected.packet, "ontology_context_is_authority\":false") != null);
    const result = try adapter.persist(a, local.session_dir, &prepared);
    try std.testing.expect(result.created);
    const expected_build = try client.binarySha256();
    try std.testing.expectEqualSlices(u8, &expected_build, &result.tinykg_build_sha256);
    var loaded = try projection.loadBound(a, local.session_dir, result.receipt_id);
    defer loaded.deinit();
    try std.testing.expectEqualSlices(u8, &result.source_semantic_snapshot_sha256, &loaded.projection.source_semantic_snapshot_sha256);
    try std.testing.expectEqualSlices(u8, &result.source_artifact_sha256, &loaded.projection.source_artifact_sha256);

    const run = try completedFailureRun(local.session_dir);
    var authored = try rule_author.prepare(a, .{
        .session_dir = local.session_dir,
        .project_sha256 = PROJECT,
        .author_sha256 = .{'2'} ** 64,
        .provider_sha256 = .{'3'} ** 64,
        .budget_authorization_sha256 = .{'4'} ** 64,
        .model = "ontology-scratch-l2-control-provider",
        .observation = run,
        .trigger = .repeated_typed_failure,
        .evidence = &.{},
        .caps = .{
            .max_cost_microusd = 1_000_000,
            .max_input_tokens = 100_000,
            .max_output_tokens = 256,
        },
        .pricing = .{
            .provenance_sha256 = .{'5'} ** 64,
            .input_microusd_per_mtok = 3_000_000,
            .output_microusd_per_mtok = 15_000_000,
            .cache_read_microusd_per_mtok = 300_000,
            .cache_write_microusd_per_mtok = 3_750_000,
        },
        .ontology_projection = .{
            .receipt_id = result.receipt_id,
            .ontology_revision = result.ontology_revision,
            .ontology_snapshot_sha256 = result.ontology_snapshot_sha256,
            .active_bundle_revision = 0,
            .active_bundle_sha256 = ZERO,
        },
    });
    defer authored.deinit();
    const binding = switch (authored.protocol) {
        .v1 => return error.ExpectedRuleAuthorV2,
        .v2 => |value| value,
    };
    try std.testing.expectEqualSlices(u8, &result.receipt_id, &binding.receipt_id);
    try std.testing.expectEqualSlices(u8, &result.packet_sha256, &binding.packet_sha256);
    try std.testing.expect(std.mem.indexOf(u8, authored.packet, result.source_artifact_sha256[0..]) != null);
    // Raw provenance evidence hashes stay in the source artifact only; the
    // provider packet must not leak them into the actor-facing context.
    try std.testing.expect(std.mem.indexOf(u8, authored.packet, PROVENANCE_EVIDENCE[0..]) == null);
}

test "L2 KgClient requires exactly one LF of CLI framing and rejects any other suffix" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    const a = std.testing.allocator;
    const real_bin = findVendoredTinyKg(a) orelse return error.SkipZigTest;
    defer a.free(real_bin);
    if (std.mem.indexOfScalar(u8, real_bin, '\'') != null) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    const canonical = try sourceSnapshot(a);
    defer a.free(canonical);

    const Case = struct {
        name: []const u8,
        suffix: []const u8,
        accept: bool,
        detail: []const u8,
    };
    const cases = [_]Case{
        // TinyKG's mandatory CLI line framing: canonical artifact + one LF.
        .{ .name = "one-lf", .suffix = "\\n", .accept = true, .detail = "" },
        // A missing frame means the upstream is not this CLI contract.
        .{ .name = "no-lf", .suffix = "", .accept = false, .detail = "缺少 CLI LF 框架" },
        // Anything else is preserved and rejected, never normalized away.
        .{ .name = "two-lf", .suffix = "\\n\\n", .accept = false, .detail = "非 JSON object" },
        .{ .name = "space-lf", .suffix = " \\n", .accept = false, .detail = "非 JSON object" },
    };
    for (cases) |case| {
        const store = try std.fmt.allocPrint(a, "{s}/wire-{s}.kg", .{ root, case.name });
        defer a.free(store);
        const wrapper = try std.fmt.allocPrint(a, "{s}/tinykg-wire-{s}", .{ root, case.name });
        defer a.free(wrapper);
        // Both snapshot transports share the same framing contract; the
        // wrapper serves the same suffixed payload to each.
        const script = try std.fmt.allocPrint(
            a,
            "#!/bin/sh\ncase \"$1\" in ontology-rule-snapshot|task-snapshot) printf '%s{s}' '{s}'; exit 0;; esac\nexec '{s}' \"$@\"\n",
            .{ case.suffix, canonical, real_bin },
        );
        defer a.free(script);
        try writeExecutable(a, wrapper, script);
        var client = try cc.kg_client.KgClient.init(a, .{
            .home = root,
            .domain = "ontology-wire-l2",
            .config_bin = wrapper,
            .config_store = store,
            .env_bin = "",
            .env_store = "",
        });
        defer client.deinit();
        client.ensureReady();
        if (!client.ready) return error.SkipZigTest;
        if (case.accept) {
            const artifact = try client.ontologyRuleSnapshot(7, PROJECT, PROJECT_KEY);
            defer client.allocator.free(artifact);
            try std.testing.expectEqualStrings(canonical, artifact);
            const task_artifact = try client.taskSnapshot(7);
            defer client.allocator.free(task_artifact);
            try std.testing.expectEqualStrings(canonical, task_artifact);
        } else {
            try std.testing.expectError(
                cc.kg_client.KgError.Data,
                client.ontologyRuleSnapshot(7, PROJECT, PROJECT_KEY),
            );
            try std.testing.expect(std.mem.indexOf(u8, client.detail(), case.detail) != null);
            try std.testing.expectError(
                cc.kg_client.KgError.Data,
                client.taskSnapshot(7),
            );
            try std.testing.expect(std.mem.indexOf(u8, client.detail(), case.detail) != null);
        }
    }
}

test "L2 ontology provenance kind order follows declaration order not tag spelling" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    var local = try localFixture(a, &tmp, &root_buffer);
    defer local.deinit(a);

    // Declaration order (user_correction < host_observation < derived_claim)
    // is canonical; node_id ordering restarts inside each kind.
    const ordered = try sourceSnapshotWithProvenance(a, &.{
        .{ .kind = .user_correction, .node_id = 17, .evidence_sha256 = PROVENANCE_EVIDENCE[0..] },
        .{ .kind = .host_observation, .node_id = 3, .evidence_sha256 = PROVENANCE_EVIDENCE[0..] },
        .{ .kind = .derived_claim, .node_id = 5, .evidence_sha256 = PROVENANCE_EVIDENCE[0..] },
    });
    var ordered_fake = Fake{ .allocator = a, .snapshot_bytes = ordered };
    defer ordered_fake.deinit();
    var prepared = try adapter.prepare(a, ordered_fake.transport(), request(&local));
    prepared.deinit();

    // Ascending tag spelling that violates declaration order must fail
    // (the wire contract is not lexicographic).
    const lex = try sourceSnapshotWithProvenance(a, &.{
        .{ .kind = .derived_claim, .node_id = 17, .evidence_sha256 = PROVENANCE_EVIDENCE[0..] },
        .{ .kind = .user_correction, .node_id = 18, .evidence_sha256 = PROVENANCE_EVIDENCE[0..] },
    });
    var lex_fake = Fake{ .allocator = a, .snapshot_bytes = lex };
    defer lex_fake.deinit();
    try std.testing.expectError(
        error.InvalidOntologyProvenance,
        adapter.prepare(a, lex_fake.transport(), request(&local)),
    );

    // Duplicate (kind, node_id) must fail.
    const dup = try sourceSnapshotWithProvenance(a, &.{
        .{ .kind = .host_observation, .node_id = 9, .evidence_sha256 = PROVENANCE_EVIDENCE[0..] },
        .{ .kind = .host_observation, .node_id = 9, .evidence_sha256 = PROVENANCE_EVIDENCE[0..] },
    });
    var dup_fake = Fake{ .allocator = a, .snapshot_bytes = dup };
    defer dup_fake.deinit();
    try std.testing.expectError(
        error.InvalidOntologyProvenance,
        adapter.prepare(a, dup_fake.transport(), request(&local)),
    );
}
