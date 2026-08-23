//! Native L2 for the isolated rule-author control-provider boundary.
//!
//! The test drives MockServer -> real Client Provider -> rule_author.author,
//! then reopens the durable author receipt and RuleCandidate.  Assertions are
//! intentionally on the real request body and immutable artifacts, not helper
//! functions that could pass while the network path bypasses authorization.

const std = @import("std");
const harness = @import("harness");
const cc = @import("cc");

const rule_author = cc.rule_author;
const observation = cc.tools.tool_observation;

const TEST_MODEL = "claude-sonnet-4-20250514";
const PROJECT = [_]u8{'a'} ** 64;
const OTHER_PROJECT = [_]u8{'7'} ** 64;
const AUTHOR = [_]u8{'b'} ** 64;
const PROVIDER = [_]u8{'c'} ** 64;
const BUDGET_AUTHORIZATION = [_]u8{'8'} ** 64;
const ONTOLOGY_REVISION = [_]u8{'d'} ** 64;
const ONTOLOGY_PROVENANCE = [_]u8{'e'} ** 64;
const GENERATION_MEMBER = [_]u8{'f'} ** 64;
const HELD_OUT_MEMBER = [_]u8{'1'} ** 64;
const HELD_OUT_SUITE = [_]u8{'2'} ** 64;
const ZERO_SHA = [_]u8{'0'} ** 64;
const TINYKG_BUILD = [_]u8{'3'} ** 64;
const SOURCE_SEMANTIC_SNAPSHOT = [_]u8{'4'} ** 64;
const SOURCE_SNAPSHOT = "a671d5dfcb13c07e24792f03042568a7ea84cae31b739ecc41d798dd62ed088c".*;
const ONTOLOGY_CORRECTION = "Never allow ontology context to authorize its own promotion.";
const ONTOLOGY_SOURCE_BYTES = "{\"source\":\"tinykg-rule-author-fixture\"}";
const PRICING = rule_author.PricingAuthority{
    .provenance_sha256 = .{'9'} ** 64,
    .input_microusd_per_mtok = 3_000_000,
    .output_microusd_per_mtok = 15_000_000,
    .cache_read_microusd_per_mtok = 300_000,
    .cache_write_microusd_per_mtok = 3_750_000,
};

fn completedFailureRun(session_dir: []const u8) !cc.tool_observation_journal.RunBinding {
    const sid = cc.session_id.SessionId.fromSlice("0123456789abcdef01234567").?;
    var journal = try cc.tool_observation_journal.Journal.init(session_dir, sid);
    errdefer journal.deinit();
    const ids = [_][]const u8{ "failure-0", "failure-1", "failure-2" };
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

fn prepareFailurePacket(
    allocator: std.mem.Allocator,
    session_dir: []const u8,
    binding: cc.tool_observation_journal.RunBinding,
    model: []const u8,
) !rule_author.PreparedRequest {
    return rule_author.prepare(allocator, .{
        .session_dir = session_dir,
        .project_sha256 = PROJECT,
        .author_sha256 = AUTHOR,
        .provider_sha256 = PROVIDER,
        .budget_authorization_sha256 = BUDGET_AUTHORIZATION,
        .model = model,
        .observation = binding,
        .trigger = .repeated_typed_failure,
        .evidence = &.{},
        .caps = .{
            .max_cost_microusd = 1_000_000,
            .max_input_tokens = 100_000,
            .max_output_tokens = 256,
        },
        .pricing = PRICING,
    });
}

fn prepareFailurePacketV2(
    allocator: std.mem.Allocator,
    session_dir: []const u8,
    binding: cc.tool_observation_journal.RunBinding,
    authority: rule_author.OntologyProjectionAuthority,
) !rule_author.PreparedRequest {
    return prepareFailurePacketV2ForProject(
        allocator,
        session_dir,
        binding,
        PROJECT,
        authority,
    );
}

fn prepareFailurePacketV2ForProject(
    allocator: std.mem.Allocator,
    session_dir: []const u8,
    binding: cc.tool_observation_journal.RunBinding,
    project_sha256: [64]u8,
    authority: rule_author.OntologyProjectionAuthority,
) !rule_author.PreparedRequest {
    return rule_author.prepare(allocator, .{
        .session_dir = session_dir,
        .project_sha256 = project_sha256,
        .author_sha256 = AUTHOR,
        .provider_sha256 = PROVIDER,
        .budget_authorization_sha256 = BUDGET_AUTHORIZATION,
        .model = TEST_MODEL,
        .observation = binding,
        .trigger = .repeated_typed_failure,
        .evidence = &.{},
        .caps = .{
            .max_cost_microusd = 1_000_000,
            .max_input_tokens = 100_000,
            .max_output_tokens = 256,
        },
        .pricing = PRICING,
        .ontology_projection = authority,
    });
}

const OntologyFixture = struct {
    authority: rule_author.OntologyProjectionAuthority,
    transcript_path: []u8,

    fn deinit(self: *OntologyFixture, allocator: std.mem.Allocator) void {
        allocator.free(self.transcript_path);
        self.* = undefined;
    }
};

fn persistOntologyProjection(
    allocator: std.mem.Allocator,
    session_dir: []const u8,
) !OntologyFixture {
    const sid = cc.session_id.SessionId.fromSlice("0123456789abcdef01234567").?;
    const transcript_path = try std.fmt.allocPrint(allocator, "{s}/transcript.jsonl", .{session_dir});
    errdefer allocator.free(transcript_path);
    const transcript = try std.fmt.allocPrint(
        allocator,
        "{{\"role\":\"user\",\"blocks\":[{{\"type\":\"text\",\"text\":{f}}}]}}\n",
        .{std.json.fmt(ONTOLOGY_CORRECTION, .{})},
    );
    defer allocator.free(transcript);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = transcript_path,
        .data = transcript,
    });
    const source = try cc.rule_source_receipt.persistUserCorrection(session_dir, .{
        .project_sha256 = PROJECT,
        .issuer_sha256 = AUTHOR,
        .session_id = sid,
        .transcript_line_index = 0,
        .correction = ONTOLOGY_CORRECTION,
    });
    var generation = try cc.ontology_rule_projection.deriveGenerationEvidence(
        allocator,
        session_dir,
        PROJECT,
        source.receipt_id,
        .user_correction,
        GENERATION_MEMBER,
    );
    defer generation.deinit();
    const ontology_summary = "Ontology context is non-authorizing and provenance is not truth.";
    const ontology_summary_sha = observation.sha256Hex(ontology_summary);
    const ontology_falsifier = "A held-out replay observes self-authorization or scope leakage.";
    const ontology_falsifier_sha = observation.sha256Hex(ontology_falsifier);
    const ontology = [1]cc.ontology_rule_projection.OntologyItem{.{
        .node_id = 42,
        .kind = .concept,
        .scope = "project:metacodes/control-plane",
        .authority = .agent_hypothesis,
        .summary = ontology_summary,
        .summary_sha256 = ontology_summary_sha[0..],
        .provenance_sha256 = ONTOLOGY_PROVENANCE[0..],
        .falsifier = ontology_falsifier,
        .falsifier_sha256 = ontology_falsifier_sha[0..],
        .contradicted = false,
        .deprecated = false,
        .retrieval_excluded = false,
    }};
    const held_members = [1][]const u8{HELD_OUT_MEMBER[0..]};
    const commitment = try cc.ontology_rule_projection.heldOutCommitmentSha256(
        allocator,
        HELD_OUT_SUITE,
        &held_members,
    );
    const held = [1]cc.ontology_rule_projection.HeldOutCommitment{.{
        .commitment_sha256 = commitment[0..],
        .suite_sha256 = HELD_OUT_SUITE[0..],
        .case_count = 1,
        .member_sha256 = &held_members,
        .sealed = true,
    }};
    const generation_evidence = [1]cc.ontology_rule_projection.GenerationEvidence{generation.value};
    const snapshot_input = cc.ontology_rule_projection.SnapshotInput{
        .project_sha256 = PROJECT,
        .project_key = "metacodes:/private/rule-author-l2",
        .revision = ONTOLOGY_REVISION,
        .source = .{
            .tinykg_build_id = "sha256:" ++ TINYKG_BUILD,
            .semantic_snapshot_sha256 = SOURCE_SEMANTIC_SNAPSHOT[0..],
            .artifact_sha256 = SOURCE_SNAPSHOT[0..],
        },
        .active_bundle_revision = 0,
        .active_bundle_sha256 = ZERO_SHA,
        .ontology = &ontology,
        .generation_evidence = &generation_evidence,
        .held_out_commitments = &held,
    };
    const rendered = try cc.ontology_rule_projection.renderSnapshot(allocator, &snapshot_input);
    defer allocator.free(rendered.bytes);
    var projected = try cc.ontology_rule_projection.project(
        allocator,
        rendered.bytes,
        PROJECT,
        ONTOLOGY_REVISION,
        rendered.snapshot_sha256,
        0,
        ZERO_SHA,
        TINYKG_BUILD,
        SOURCE_SEMANTIC_SNAPSHOT,
        SOURCE_SNAPSHOT,
    );
    defer projected.deinit();
    const persisted = try cc.ontology_rule_projection.persist(
        allocator,
        session_dir,
        ONTOLOGY_SOURCE_BYTES,
        rendered.bytes,
        &projected,
    );
    return .{
        .authority = .{
            .receipt_id = persisted.receipt_id,
            .ontology_revision = ONTOLOGY_REVISION,
            .ontology_snapshot_sha256 = rendered.snapshot_sha256,
            .active_bundle_revision = 0,
            .active_bundle_sha256 = ZERO_SHA,
        },
        .transcript_path = transcript_path,
    };
}

fn permitFor(prepared: *const rule_author.PreparedRequest) !rule_author.Permit {
    return rule_author.authorize(prepared, .{
        .enabled = true,
        .now_ns = 1_000_000,
        .last_authorized_ns = 0,
        .cooldown_ns = 100,
        .remaining_requests = 1,
        .remaining_cost_microusd = 1_000_000,
        .remaining_input_tokens = 100_000,
        .remaining_output_tokens = 256,
    });
}

fn textSse(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const quoted = try std.json.Stringify.valueAlloc(allocator, text, .{});
    defer allocator.free(quoted);
    return std.fmt.allocPrint(
        allocator,
        "data: {{\"type\":\"message_start\",\"message\":{{\"id\":\"msg_author\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{{\"input_tokens\":10,\"output_tokens\":0}}}}}}\n\n" ++
            "data: {{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{{\"type\":\"thinking_delta\",\"thinking\":\"private author reasoning must not enter the proposal\"}}}}\n\n" ++
            "data: {{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{{\"type\":\"text\",\"text\":\"\"}}}}\n\n" ++
            "data: {{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{{\"type\":\"text_delta\",\"text\":{s}}}}}\n\n" ++
            "data: {{\"type\":\"content_block_stop\",\"index\":0}}\n\n" ++
            "data: {{\"type\":\"message_delta\",\"delta\":{{\"stop_reason\":\"end_turn\"}},\"usage\":{{\"output_tokens\":80}}}}\n\n" ++
            "data: {{\"type\":\"message_stop\"}}\n\n",
        .{quoted},
    );
}

fn proposalJson(allocator: std.mem.Allocator) ![]u8 {
    const spec = cc.project_rule_spec.Spec{
        .target = .{ .tool = "Write" },
        .target_scope = .existing_file,
        .deny_target = true,
        .max_input_bytes = 8192,
        .max_agent_depth = 4,
        .authoritative_only = true,
        .effect_requirement = .none,
    };
    const lean = try rule_author.renderCanonicalLean(allocator, spec);
    defer allocator.free(lean);
    return std.json.Stringify.valueAlloc(allocator, .{
        .schema_version = rule_author.RESPONSE_SCHEMA_VERSION,
        .decision = rule_author.Decision.propose,
        .reason = "Repeated typed failures justify a narrow existing-file Write guard.",
        .invariant = "An authoritative Write must not replace an existing regular file in this project.",
        .falsifier = "Replay admits an authoritative Write whose host signal is regular_existing.",
        .rule_spec = cc.project_rule_spec.toWire(spec),
        .lean_source = lean,
    }, .{});
}

test "L2 rule author: admitted no-tools provider call persists a receipt-bound candidate" {
    const a = std.heap.page_allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    const binding = try completedFailureRun(root);
    var prepared = try prepareFailurePacket(a, root, binding, TEST_MODEL);
    defer prepared.deinit();
    const permit = try permitFor(&prepared);

    const response_json = try proposalJson(a);
    defer a.free(response_json);
    const sse = try textSse(a, response_json);
    defer a.free(sse);
    var server = try harness.MockServer.start(sse, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);
    var io_runtime = std.Io.Threaded.init(a, .{});
    defer io_runtime.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(a, io_runtime.io(), "author-test-key", TEST_MODEL, url);
    defer client.deinit();
    client.setMaxTokensOverride(256);

    var authored = try rule_author.author(a, root, .{
        .provider = client.provider(),
        .provider_sha256 = PROVIDER,
    }, &prepared, permit, null);
    defer authored.deinit();
    try std.testing.expectEqual(rule_author.Decision.propose, authored.decision);
    try std.testing.expectEqual(@as(usize, 1), server.requestCount());

    const captured = server.lastRequest() orelse return error.NoRequestCaptured;
    const body = captured.body();
    try std.testing.expect(std.mem.indexOf(u8, body, "isolated rule-author control model") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, rule_author.PACKET_SCHEMA_VERSION) != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "typed_failure_summary") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "ACTOR_SECRET") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"tools\"") == null);
    var parsed_request = try std.json.parseFromSlice(std.json.Value, a, body, .{
        .duplicate_field_behavior = .@"error",
    });
    defer parsed_request.deinit();
    const messages = parsed_request.value.object.get("messages") orelse return error.MessagesMissing;
    try std.testing.expectEqual(@as(usize, 1), messages.array.items.len);

    var receipt = try rule_author.loadReceipt(a, root, authored.receipt_id);
    defer receipt.deinit();
    try std.testing.expectEqual(rule_author.Decision.propose, receipt.decision);
    try std.testing.expect(std.meta.activeTag(receipt.protocol) == .v1);
    try std.testing.expectEqual(@as(u64, 10), receipt.usage.input_tokens);
    try std.testing.expectEqual(@as(u64, 80), receipt.usage.output_tokens);
    const candidate = try rule_author.persistCandidate(a, root, &authored);
    try std.testing.expect(try rule_author.verifyCandidateBinding(
        a,
        root,
        authored.receipt_id,
        candidate.candidate_id,
    ));

    // A caller can persist a proposal artifact directly, but reusing the
    // author receipt while changing the invariant must not satisfy the binding.
    const proposal = authored.proposal.?;
    const drifted = try cc.rule_candidate.persist(root, .{
        .project_sha256 = PROJECT,
        .proposer_sha256 = authored.receipt_id,
        .invariant = "A different invariant that the author response never emitted.",
        .rule_spec = proposal.rule_spec,
        .lean_source = proposal.lean_source,
        .source = .{ .agent_reflection = .{
            .observation = binding,
            .reflector_sha256 = authored.receipt_id,
            .falsifier = proposal.falsifier,
        } },
    });
    try std.testing.expect(!try rule_author.verifyCandidateBinding(
        a,
        root,
        authored.receipt_id,
        drifted.candidate_id,
    ));

    const receipt_path = try std.fmt.allocPrint(
        a,
        "{s}/{s}{s}.json",
        .{ root, rule_author.RECEIPT_FILE_PREFIX, authored.receipt_id[0..] },
    );
    defer a.free(receipt_path);
    const receipt_bytes = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        receipt_path,
        a,
        .limited(rule_author.MAX_RECEIPT_BYTES),
    );
    defer a.free(receipt_bytes);
    try std.testing.expect(std.mem.indexOf(u8, receipt_bytes, rule_author.RECEIPT_SCHEMA_VERSION) != null);
    try std.testing.expect(std.mem.indexOf(u8, receipt_bytes, "ontology_projection") == null);
}

test "L2 ontology projection drives isolated v2 rule author without actor context drift" {
    const a = std.heap.page_allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    const session_dir = try std.fmt.allocPrint(a, "{s}/0123456789abcdef01234567", .{root});
    defer a.free(session_dir);
    try std.Io.Dir.createDirAbsolute(std.testing.io, session_dir, .default_dir);
    const binding = try completedFailureRun(session_dir);
    var ontology = try persistOntologyProjection(a, session_dir);
    defer ontology.deinit(a);
    var prepared = try prepareFailurePacketV2(a, session_dir, binding, ontology.authority);
    defer prepared.deinit();
    try std.testing.expect(std.meta.activeTag(prepared.protocol) == .v2);
    const permit = try permitFor(&prepared);

    const actor_context_before = "ACTOR_SECRET_CACHE_PREFIX_MUST_REMAIN_BYTE_IDENTICAL";
    const actor_context = try a.dupe(u8, actor_context_before);
    defer a.free(actor_context);
    const response_json = try proposalJson(a);
    defer a.free(response_json);
    const sse = try textSse(a, response_json);
    defer a.free(sse);
    var server = try harness.MockServer.start(sse, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);
    var io_runtime = std.Io.Threaded.init(a, .{});
    defer io_runtime.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(a, io_runtime.io(), "author-v2-test-key", TEST_MODEL, url);
    defer client.deinit();
    client.setMaxTokensOverride(256);

    var authored = try rule_author.author(a, session_dir, .{
        .provider = client.provider(),
        .provider_sha256 = PROVIDER,
    }, &prepared, permit, null);
    defer authored.deinit();
    try std.testing.expectEqual(@as(usize, 1), server.requestCount());
    try std.testing.expect(std.meta.activeTag(authored.protocol) == .v2);
    const body = (server.lastRequest() orelse return error.NoRequestCaptured).body();
    try std.testing.expect(std.mem.indexOf(u8, body, rule_author.PACKET_SCHEMA_VERSION_V2) != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "ontology-informed rule-author") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, ONTOLOGY_CORRECTION) != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "ontology_context_is_authority\\\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "results_visible\\\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "HELD_OUT_RESULT_SECRET") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, actor_context_before) == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"tools\"") == null);
    try std.testing.expectEqualStrings(actor_context_before, actor_context);
    var parsed_request = try std.json.parseFromSlice(std.json.Value, a, body, .{
        .duplicate_field_behavior = .@"error",
    });
    defer parsed_request.deinit();
    const messages = parsed_request.value.object.get("messages") orelse return error.MessagesMissing;
    try std.testing.expectEqual(@as(usize, 1), messages.array.items.len);

    var receipt = try rule_author.loadReceipt(a, session_dir, authored.receipt_id);
    defer receipt.deinit();
    try std.testing.expect(std.meta.activeTag(receipt.protocol) == .v2);
    const candidate = try rule_author.persistCandidate(a, session_dir, &authored);
    try std.testing.expect(try rule_author.verifyCandidateBinding(
        a,
        session_dir,
        authored.receipt_id,
        candidate.candidate_id,
    ));
    var loaded_candidate = try cc.rule_candidate.load(a, session_dir, candidate.candidate_id);
    defer loaded_candidate.deinit();
    try std.testing.expectEqual(cc.rule_candidate.SourceKind.rule_author, loaded_candidate.source_kind);

    // The candidate remains non-authorizing: persistence exposes no build,
    // promotion, bundle mutation, or TinyKG mutation operation.
    try std.testing.expectEqualSlices(u8, &AUTHOR, &loaded_candidate.proposer_sha256);

    // Candidate verification is not a one-time copy check. It reopens the
    // v2 author receipt, which reopens the projection and its source receipt.
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = ontology.transcript_path,
        .data = "{\"role\":\"user\",\"blocks\":[{\"type\":\"text\",\"text\":\"changed after candidate\"}]}\n",
    });
    try std.testing.expectError(error.SourceArtifactChanged, rule_author.verifyCandidateBinding(
        a,
        session_dir,
        authored.receipt_id,
        candidate.candidate_id,
    ));
}

test "L2 governed rule author preserves actor independence and lifecycle reopens ontology source" {
    const a = std.heap.page_allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    const session_dir = try std.fmt.allocPrint(a, "{s}/0123456789abcdef01234567", .{root});
    defer a.free(session_dir);
    try std.Io.Dir.createDirAbsolute(std.testing.io, session_dir, .default_dir);
    const binding = try completedFailureRun(session_dir);
    var ontology = try persistOntologyProjection(a, session_dir);
    defer ontology.deinit(a);
    var prepared = try prepareFailurePacketV2(a, session_dir, binding, ontology.authority);
    defer prepared.deinit();
    const permit = try permitFor(&prepared);
    const response_json = try proposalJson(a);
    defer a.free(response_json);
    const sse = try textSse(a, response_json);
    defer a.free(sse);
    var server = try harness.MockServer.start(sse, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);
    var io_runtime = std.Io.Threaded.init(a, .{});
    defer io_runtime.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(
        a,
        io_runtime.io(),
        "author-lifecycle-test-key",
        TEST_MODEL,
        url,
    );
    defer client.deinit();
    client.setMaxTokensOverride(256);
    var authored = try rule_author.author(a, session_dir, .{
        .provider = client.provider(),
        .provider_sha256 = PROVIDER,
    }, &prepared, permit, null);
    defer authored.deinit();
    const candidate = try rule_author.persistCandidate(a, session_dir, &authored);
    var loaded_candidate = try cc.rule_candidate.load(a, session_dir, candidate.candidate_id);
    defer loaded_candidate.deinit();
    try std.testing.expectEqual(cc.rule_candidate.SourceKind.rule_author, loaded_candidate.source_kind);
    try std.testing.expectEqualSlices(u8, &AUTHOR, &loaded_candidate.proposer_sha256);
    const canonical_spec = try cc.project_rule_spec.renderCanonical(a, loaded_candidate.rule_spec);
    defer a.free(canonical_spec);

    const build_evidence = cc.rule_lifecycle.BuildEvidence{
        .manifest_sha256 = .{'1'} ** 64,
        .lean_source_sha256 = loaded_candidate.lean_source_sha256,
        .rule_spec_sha256 = observation.sha256Hex(canonical_spec),
        .compiled_artifact_sha256 = .{'2'} ** 64,
        .toolchain_sha256 = .{'3'} ** 64,
        .sdk_sha256 = .{'4'} ** 64,
        .sdk_olean_sha256 = .{'5'} ** 64,
        .build_log_sha256 = .{'6'} ** 64,
        .network_disabled = true,
        .secrets_absent = true,
        .source_bounded = true,
        .output_bounded = true,
        .completed = true,
    };
    // The receipt id is not the actor. A same-author builder must now be
    // rejected even though its actor hash differs from the author receipt.
    try std.testing.expectError(error.BuilderNotIndependent, cc.rule_lifecycle.persist(
        session_dir,
        .{
            .candidate_id = candidate.candidate_id,
            .project_sha256 = PROJECT,
            .actor_sha256 = AUTHOR,
            .checker_sha256 = .{'7'} ** 64,
            .predecessor_receipt_id = null,
            .evidence = .{ .built = build_evidence },
        },
    ));
    const built = try cc.rule_lifecycle.persist(session_dir, .{
        .candidate_id = candidate.candidate_id,
        .project_sha256 = PROJECT,
        .actor_sha256 = .{'3'} ** 64,
        .checker_sha256 = .{'7'} ** 64,
        .predecessor_receipt_id = null,
        .evidence = .{ .built = build_evidence },
    });
    const axiom = try cc.rule_lifecycle.persist(session_dir, .{
        .candidate_id = candidate.candidate_id,
        .project_sha256 = PROJECT,
        .actor_sha256 = .{'4'} ** 64,
        .checker_sha256 = .{'8'} ** 64,
        .predecessor_receipt_id = built.receipt_id,
        .evidence = .{ .axiom_audited = .{
            .audit_sha256 = .{'a'} ** 64,
            .policy_sha256 = .{'b'} ** 64,
            .forbidden_declaration_count = 0,
            .unexpected_axiom_count = 0,
            .completed = true,
        } },
    });
    const replay = try cc.rule_lifecycle.persist(session_dir, .{
        .candidate_id = candidate.candidate_id,
        .project_sha256 = PROJECT,
        .actor_sha256 = .{'5'} ** 64,
        .checker_sha256 = .{'9'} ** 64,
        .predecessor_receipt_id = axiom.receipt_id,
        .evidence = .{ .replay_passed = .{
            .corpus_sha256 = .{'c'} ** 64,
            .results_sha256 = .{'d'} ** 64,
            .positive_cases = 1,
            .negative_cases = 1,
            .false_positive_count = 0,
            .false_negative_count = 0,
            .completed = true,
        } },
    });
    const shadow = try cc.rule_lifecycle.persist(session_dir, .{
        .candidate_id = candidate.candidate_id,
        .project_sha256 = PROJECT,
        .actor_sha256 = .{'6'} ** 64,
        .checker_sha256 = .{'9'} ** 64,
        .predecessor_receipt_id = replay.receipt_id,
        .evidence = .{ .shadow_passed = .{
            .interval_sha256 = .{'e'} ** 64,
            .results_sha256 = .{'f'} ** 64,
            .observed_decisions = 1,
            .divergence_count = 0,
            .side_effect_count = 0,
            .completed = true,
        } },
    });

    const promotion_evidence = cc.rule_lifecycle.PromotionEvidence{
        .lifecycle_request_sha256 = .{'7'} ** 64,
        .lifecycle_verdict_sha256 = .{'8'} ** 64,
        .runtime_kernel_sha256 = .{'9'} ** 64,
        .bundle_sha256 = .{'a'} ** 64,
        .previous_bundle_sha256 = ZERO_SHA,
        .bundle_revision = 1,
        .checker_admitted = true,
        .checker_elapsed_ns = 1,
        .checker_bytes = 1,
    };
    const invocation = cc.project_harness_runtime.Invocation{
        .bindings = .{
            .request_id = .{'1'} ** 64,
            .operation = .promote,
            .kernel_sha256 = promotion_evidence.runtime_kernel_sha256,
            .candidate_id = candidate.candidate_id,
            .project_sha256 = PROJECT,
            .bundle_sha256 = promotion_evidence.bundle_sha256,
            .bundle_revision = 1,
        },
        .actual_checker_sha256 = promotion_evidence.runtime_kernel_sha256,
        .request_sha256 = promotion_evidence.lifecycle_request_sha256,
        .verdict_sha256 = promotion_evidence.lifecycle_verdict_sha256,
        .checker_bytes = 1,
        .checker_elapsed_ns = 1,
        .verdict = .{ .admitted = true, .checks = .{
            .request_valid = true,
            .rule_valid = true,
            .lifecycle_valid = true,
            .decision_valid = true,
        } },
    };
    const original_transcript = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        ontology.transcript_path,
        a,
        .limited(64 * 1024),
    );
    defer a.free(original_transcript);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = ontology.transcript_path,
        .data = "{\"role\":\"user\",\"blocks\":[{\"type\":\"text\",\"text\":\"drifted\"}]}\n",
    });
    const unopened_rules_dir = try std.fmt.allocPrint(a, "{s}/project-rules", .{root});
    defer a.free(unopened_rules_dir);
    try std.testing.expectError(error.SourceArtifactChanged, cc.project_rule_bundle.promote(a, .{
        .evidence_dir = session_dir,
        .project_rules_dir = unopened_rules_dir,
        .candidate_id = candidate.candidate_id,
        .project_sha256 = PROJECT,
        // These deliberately invalid downstream bindings prove source
        // reopening precedes lifecycle/build/checker work at the real entry.
        .shadow_receipt_id = ZERO_SHA,
        .promoter_sha256 = .{'7'} ** 64,
        .trusted_build_files = .{
            .toolchain_path = "/unreachable/toolchain",
            .sdk_source_path = "/unreachable/sdk",
            .sdk_olean_path = "/unreachable/sdk.olean",
        },
        .config = .{
            .checker_path = "/unreachable/checker",
            .expected_sha256 = .{'9'} ** 64,
        },
    }));
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.openDirAbsolute(
        std.testing.io,
        unopened_rules_dir,
        .{},
    ));
    try std.testing.expectError(error.SourceArtifactChanged, cc.rule_lifecycle.persistPromotion(
        session_dir,
        .{
            .candidate_id = candidate.candidate_id,
            .project_sha256 = PROJECT,
            .actor_sha256 = .{'7'} ** 64,
            .checker_sha256 = promotion_evidence.runtime_kernel_sha256,
            .predecessor_receipt_id = shadow.receipt_id,
            .evidence = .{ .promoted = promotion_evidence },
        },
        &invocation,
    ));
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = ontology.transcript_path,
        .data = original_transcript,
    });
    const promoted = try cc.rule_lifecycle.persistPromotion(session_dir, .{
        .candidate_id = candidate.candidate_id,
        .project_sha256 = PROJECT,
        .actor_sha256 = .{'7'} ** 64,
        .checker_sha256 = promotion_evidence.runtime_kernel_sha256,
        .predecessor_receipt_id = shadow.receipt_id,
        .evidence = .{ .promoted = promotion_evidence },
    }, &invocation);
    var loaded_promotion = try cc.rule_lifecycle.load(a, session_dir, promoted.receipt_id);
    defer loaded_promotion.deinit();
    try std.testing.expectEqual(cc.rule_lifecycle.Stage.promoted, loaded_promotion.stage);
    try std.testing.expectEqual(@as(usize, 1), server.requestCount());
}

test "L2 ontology drift after prepare blocks v2 author before provider request" {
    const a = std.heap.page_allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    const session_dir = try std.fmt.allocPrint(a, "{s}/0123456789abcdef01234567", .{root});
    defer a.free(session_dir);
    try std.Io.Dir.createDirAbsolute(std.testing.io, session_dir, .default_dir);
    const binding = try completedFailureRun(session_dir);
    var ontology = try persistOntologyProjection(a, session_dir);
    defer ontology.deinit(a);
    var prepared = try prepareFailurePacketV2(a, session_dir, binding, ontology.authority);
    defer prepared.deinit();
    const permit = try permitFor(&prepared);
    try std.Io.Dir.cwd().writeFile(std.testing.io, .{
        .sub_path = ontology.transcript_path,
        .data = "{\"role\":\"user\",\"blocks\":[{\"type\":\"text\",\"text\":\"changed after prepare\"}]}\n",
    });

    const response_json = try proposalJson(a);
    defer a.free(response_json);
    const sse = try textSse(a, response_json);
    defer a.free(sse);
    var server = try harness.MockServer.start(sse, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);
    var io_runtime = std.Io.Threaded.init(a, .{});
    defer io_runtime.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(a, io_runtime.io(), "author-v2-test-key", TEST_MODEL, url);
    defer client.deinit();
    client.setMaxTokensOverride(256);
    try std.testing.expectError(error.SourceArtifactChanged, rule_author.author(
        a,
        session_dir,
        .{ .provider = client.provider(), .provider_sha256 = PROVIDER },
        &prepared,
        permit,
        null,
    ));
    try std.testing.expectEqual(@as(usize, 0), server.requestCount());
}

test "L2 ontology authority identity mismatch fails before provider request" {
    const a = std.heap.page_allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    const session_dir = try std.fmt.allocPrint(a, "{s}/0123456789abcdef01234567", .{root});
    defer a.free(session_dir);
    try std.Io.Dir.createDirAbsolute(std.testing.io, session_dir, .default_dir);
    const binding = try completedFailureRun(session_dir);
    var ontology = try persistOntologyProjection(a, session_dir);
    defer ontology.deinit(a);

    const response_json = try proposalJson(a);
    defer a.free(response_json);
    const sse = try textSse(a, response_json);
    defer a.free(sse);
    var server = try harness.MockServer.start(sse, 0);
    defer server.stop();

    var bad_revision = ontology.authority;
    bad_revision.ontology_revision = .{'3'} ** 64;
    try std.testing.expectError(
        error.OntologyProjectionIdentityMismatch,
        prepareFailurePacketV2(a, session_dir, binding, bad_revision),
    );
    var bad_snapshot = ontology.authority;
    bad_snapshot.ontology_snapshot_sha256 = .{'4'} ** 64;
    try std.testing.expectError(
        error.OntologyProjectionIdentityMismatch,
        prepareFailurePacketV2(a, session_dir, binding, bad_snapshot),
    );
    var bad_bundle = ontology.authority;
    bad_bundle.active_bundle_revision = 1;
    bad_bundle.active_bundle_sha256 = .{'5'} ** 64;
    try std.testing.expectError(
        error.OntologyProjectionIdentityMismatch,
        prepareFailurePacketV2(a, session_dir, binding, bad_bundle),
    );
    try std.testing.expectError(
        error.OntologyProjectionIdentityMismatch,
        prepareFailurePacketV2ForProject(
            a,
            session_dir,
            binding,
            OTHER_PROJECT,
            ontology.authority,
        ),
    );

    const receipt_name = try std.fmt.allocPrint(
        a,
        "{s}{s}.json",
        .{ cc.ontology_rule_projection.RECEIPT_FILE_PREFIX, ontology.authority.receipt_id[0..] },
    );
    defer a.free(receipt_name);
    const receipt_path = try std.fs.path.join(a, &.{ session_dir, receipt_name });
    defer a.free(receipt_path);
    const hardlink_path = try std.fs.path.join(a, &.{ session_dir, "projection-author-hardlink.json" });
    defer a.free(hardlink_path);
    try std.Io.Dir.hardLink(.cwd(), receipt_path, .cwd(), hardlink_path, std.testing.io, .{});
    try std.testing.expectError(
        error.InvalidArtifactFile,
        prepareFailurePacketV2(a, session_dir, binding, ontology.authority),
    );
    try std.testing.expectEqual(@as(usize, 0), server.requestCount());
}

test "L2 rule author: permit packet provider and model drift fail before network" {
    const a = std.heap.page_allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    const binding = try completedFailureRun(root);
    var prepared = try prepareFailurePacket(a, root, binding, TEST_MODEL);
    defer prepared.deinit();
    const valid_permit = try permitFor(&prepared);
    const response_json = try proposalJson(a);
    defer a.free(response_json);
    const sse = try textSse(a, response_json);
    defer a.free(sse);
    var server = try harness.MockServer.start(sse, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);
    var io_runtime = std.Io.Threaded.init(a, .{});
    defer io_runtime.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(a, io_runtime.io(), "author-test-key", TEST_MODEL, url);
    defer client.deinit();
    client.setMaxTokensOverride(256);
    const bound = rule_author.BoundProvider{ .provider = client.provider(), .provider_sha256 = PROVIDER };

    var bad_permit = valid_permit;
    bad_permit.authorization_sha256 = .{'e'} ** 64;
    try std.testing.expectError(error.PermitIdentityMismatch, rule_author.author(
        a,
        root,
        bound,
        &prepared,
        bad_permit,
        null,
    ));
    try std.testing.expectEqual(@as(usize, 0), server.requestCount());

    const saved_packet_sha = prepared.packet_sha256;
    prepared.packet_sha256 = .{'f'} ** 64;
    try std.testing.expectError(error.PreparedRequestDrift, rule_author.author(
        a,
        root,
        bound,
        &prepared,
        valid_permit,
        null,
    ));
    prepared.packet_sha256 = saved_packet_sha;
    try std.testing.expectEqual(@as(usize, 0), server.requestCount());

    try std.testing.expectError(error.ProviderIdentityMismatch, rule_author.author(
        a,
        root,
        .{ .provider = client.provider(), .provider_sha256 = .{'1'} ** 64 },
        &prepared,
        valid_permit,
        null,
    ));
    try std.testing.expectEqual(@as(usize, 0), server.requestCount());

    var wrong_model = try prepareFailurePacket(a, root, binding, "different-author-model");
    defer wrong_model.deinit();
    const wrong_model_permit = try permitFor(&wrong_model);
    try std.testing.expectError(error.ProviderModelMismatch, rule_author.author(
        a,
        root,
        bound,
        &wrong_model,
        wrong_model_permit,
        null,
    ));
    try std.testing.expectEqual(@as(usize, 0), server.requestCount());
}

test "L2 rule author: malformed response and tool events fail closed" {
    const a = std.heap.page_allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    const binding = try completedFailureRun(root);
    var prepared = try prepareFailurePacket(a, root, binding, TEST_MODEL);
    defer prepared.deinit();
    const permit = try permitFor(&prepared);

    const malformed_sse = try textSse(a, "{\"schema_version\":\"wrong\"}");
    defer a.free(malformed_sse);
    var malformed_server = try harness.MockServer.start(malformed_sse, 0);
    defer malformed_server.stop();
    const malformed_url = try malformed_server.urlOwned(a);
    defer a.free(malformed_url);
    var io_runtime = std.Io.Threaded.init(a, .{});
    defer io_runtime.deinit();
    var malformed_client = cc.client_mod.Client.initWithBaseUrl(a, io_runtime.io(), "key", TEST_MODEL, malformed_url);
    defer malformed_client.deinit();
    malformed_client.setMaxTokensOverride(256);
    try std.testing.expectError(error.InvalidAuthorResponse, rule_author.author(
        a,
        root,
        .{ .provider = malformed_client.provider(), .provider_sha256 = PROVIDER },
        &prepared,
        permit,
        null,
    ));
    try std.testing.expectEqual(@as(usize, 1), malformed_server.requestCount());

    const tool_sse =
        "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_tool\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":0}}}\n\n" ++
        "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"tool_1\",\"name\":\"Read\",\"input\":{}}}\n\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{}\"}}\n\n" ++
        "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
        "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
        "data: {\"type\":\"message_stop\"}\n\n";
    var tool_server = try harness.MockServer.start(tool_sse, 0);
    defer tool_server.stop();
    const tool_url = try tool_server.urlOwned(a);
    defer a.free(tool_url);
    var tool_client = cc.client_mod.Client.initWithBaseUrl(a, io_runtime.io(), "key", TEST_MODEL, tool_url);
    defer tool_client.deinit();
    tool_client.setMaxTokensOverride(256);
    try std.testing.expectError(error.AuthorToolEventForbidden, rule_author.author(
        a,
        root,
        .{ .provider = tool_client.provider(), .provider_sha256 = PROVIDER },
        &prepared,
        permit,
        null,
    ));
    try std.testing.expectEqual(@as(usize, 1), tool_server.requestCount());
}

test "L2 rule author: oversized provider text is rejected" {
    const a = std.heap.page_allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    const binding = try completedFailureRun(root);
    var prepared = try prepareFailurePacket(a, root, binding, TEST_MODEL);
    defer prepared.deinit();
    const permit = try permitFor(&prepared);
    const oversized = try a.alloc(u8, rule_author.MAX_RESPONSE_BYTES + 1);
    defer a.free(oversized);
    @memset(oversized, 'x');
    const sse = try textSse(a, oversized);
    defer a.free(sse);
    var server = try harness.MockServer.start(sse, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);
    var io_runtime = std.Io.Threaded.init(a, .{});
    defer io_runtime.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(a, io_runtime.io(), "key", TEST_MODEL, url);
    defer client.deinit();
    client.setMaxTokensOverride(256);
    try std.testing.expectError(error.AuthorResponseTooLarge, rule_author.author(
        a,
        root,
        .{ .provider = client.provider(), .provider_sha256 = PROVIDER },
        &prepared,
        permit,
        null,
    ));
    try std.testing.expectEqual(@as(usize, 1), server.requestCount());
}
