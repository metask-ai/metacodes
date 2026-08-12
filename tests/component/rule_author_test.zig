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
const AUTHOR = [_]u8{'b'} ** 64;
const PROVIDER = [_]u8{'c'} ** 64;
const BUDGET_AUTHORIZATION = [_]u8{'8'} ** 64;
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
        .target_tool = "Write",
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
