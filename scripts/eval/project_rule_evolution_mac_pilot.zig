//! Zero-paid Mac host pilot for the governed ontology -> project-rule path.
//!
//! The parent process owns two loopback services: a TinyKG daemon that
//! implements the not-yet-released `ontology-rule-snapshot` atomic command,
//! and a scripted rule-author provider.  This child deliberately starts at
//! the production `KgClient` configuration boundary; no in-memory snapshot
//! adapter is injected.

const std = @import("std");
const cc = @import("metacodes-core");

const MODEL = "mac-pilot-rule-author";
const CORRECTION = "Ontology context may guide a candidate but cannot authorize its promotion.";
const GENERATION_MEMBER = [_]u8{'e'} ** 64;
const HELD_OUT_MEMBER = [_]u8{'f'} ** 64;
const HELD_OUT_SUITE = [_]u8{'1'} ** 64;

const Output = struct {
    schema_version: []const u8 = "metacodes-project-rule-evolution-mac-pilot-v1",
    quality_evidence: bool = false,
    tinykg_backend: []const u8 = "mock-atomic-command",
    tinykg_transport: []const u8 = "authenticated-loopback-daemon-http",
    provider_backend: []const u8 = "scripted-loopback-rule-author",
    actor_context_shared: bool = false,
    candidate_created: bool,
    candidate_binding_verified: bool,
    author_receipt_id: []const u8,
    candidate_id: ?[]const u8,
    ontology_revision: []const u8,
    ontology_snapshot_sha256: []const u8,
    input_tokens: u64,
    output_tokens: u64,
    cache_read_input_tokens: u64,
    cache_creation_input_tokens: u64,
    provider_elapsed_ns: u64,
};

const FailureOutput = struct {
    schema_version: []const u8 = "metacodes-project-rule-evolution-mac-pilot-failure-v1",
    quality_evidence: bool = false,
    error_code: []const u8,
};

pub fn main(init: std.process.Init) void {
    run(init) catch |err| {
        var buffer: [1024]u8 = undefined;
        var file_writer: std.Io.File.Writer = .init(.stderr(), init.io, &buffer);
        const writer = &file_writer.interface;
        std.json.Stringify.value(FailureOutput{ .error_code = @errorName(err) }, .{}, writer) catch {};
        writer.writeByte('\n') catch {};
        writer.flush() catch {};
        std.process.exit(1);
    };
}

fn run(init: std.process.Init) !void {
    const allocator = std.heap.c_allocator;
    var args = std.process.Args.iterateAllocator(init.minimal.args, allocator) catch
        return error.InvalidArguments;
    defer args.deinit();
    _ = args.next();
    const provider_url = args.next() orelse return error.InvalidArguments;
    const workspace_root = args.next() orelse return error.InvalidArguments;
    if (args.next() != null or !std.fs.path.isAbsolute(workspace_root))
        return error.InvalidArguments;

    const home = try std.fmt.allocPrint(allocator, "{s}/home", .{workspace_root});
    defer allocator.free(home);
    const project_root = try std.fmt.allocPrint(allocator, "{s}/project", .{workspace_root});
    defer allocator.free(project_root);
    const rules_dir = try std.fmt.allocPrint(allocator, "{s}/rules", .{project_root});
    defer allocator.free(rules_dir);
    const sessions_root = try std.fmt.allocPrint(allocator, "{s}/sessions", .{workspace_root});
    defer allocator.free(sessions_root);
    const session_dir = try std.fmt.allocPrint(
        allocator,
        "{s}/sessions/0123456789abcdef01234567",
        .{workspace_root},
    );
    defer allocator.free(session_dir);
    std.Io.Dir.createDirAbsolute(init.io, home, .default_dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    try std.Io.Dir.createDirAbsolute(init.io, project_root, .default_dir);
    try std.Io.Dir.createDirAbsolute(init.io, rules_dir, .default_dir);
    try std.Io.Dir.createDirAbsolute(init.io, sessions_root, .default_dir);
    try std.Io.Dir.createDirAbsolute(init.io, session_dir, .default_dir);

    const project_key = try std.fmt.allocPrint(allocator, "metacodes:{s}", .{project_root});
    defer allocator.free(project_key);
    const project_sha256 = cc.project_rule_bundle.projectIdentity(project_root);
    const sid = cc.session_id.SessionId.fromSlice("0123456789abcdef01234567").?;
    const transcript_path = try std.fmt.allocPrint(allocator, "{s}/transcript.jsonl", .{session_dir});
    defer allocator.free(transcript_path);
    const transcript = try std.fmt.allocPrint(
        allocator,
        "{{\"role\":\"user\",\"blocks\":[{{\"type\":\"text\",\"text\":{f}}}]}}\n",
        .{std.json.fmt(CORRECTION, .{})},
    );
    defer allocator.free(transcript);
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = transcript_path, .data = transcript });
    const source_receipt = try cc.rule_source_receipt.persistUserCorrection(session_dir, .{
        .project_sha256 = project_sha256,
        .issuer_sha256 = cc.tools.tool_observation.sha256Hex("mac-pilot-host-user-correction"),
        .session_id = sid,
        .transcript_line_index = 0,
        .correction = CORRECTION,
    });
    var generation = try cc.ontology_rule_projection.deriveGenerationEvidence(
        allocator,
        session_dir,
        project_sha256,
        source_receipt.receipt_id,
        .user_correction,
        GENERATION_MEMBER,
    );
    defer generation.deinit();
    const held_members = [_][]const u8{HELD_OUT_MEMBER[0..]};
    const held_commitment = try cc.ontology_rule_projection.heldOutCommitmentSha256(
        allocator,
        HELD_OUT_SUITE,
        &held_members,
    );
    const held = [_]cc.ontology_rule_projection.HeldOutCommitment{.{
        .commitment_sha256 = held_commitment[0..],
        .suite_sha256 = HELD_OUT_SUITE[0..],
        .case_count = held_members.len,
        .member_sha256 = &held_members,
        .sealed = true,
    }};
    const run_binding = try completedFailureRun(session_dir);

    var io_runtime = std.Io.Threaded.init(allocator, .{});
    defer io_runtime.deinit();
    var kg = try cc.kg_client.KgClient.init(allocator, .{
        .home = home,
        .domain = project_key,
        .io = io_runtime.io(),
    });
    defer kg.deinit();
    kg.ensureReady();
    if (!kg.ready) return error.TinyKgDaemonNotReady;
    var kg_source = cc.project_rule_evolution.KgClientSource.init(&kg);

    const provider_sha256 = cc.tools.tool_observation.sha256Hex(
        "mac-pilot/scripted-independent-rule-author",
    );
    var prepared = try cc.project_rule_evolution.prepare(allocator, .{
        .session_dir = session_dir,
        .project_root = project_root,
        .project_rules_dir = rules_dir,
        .ontology_source = kg_source.source(),
        .kernel_config = null,
        .author_sha256 = cc.rule_author.systemPromptSha256(),
        .actor_provider_sha256 = cc.tools.tool_observation.sha256Hex(
            "mac-pilot/actor-provider-not-instantiated",
        ),
        .provider_sha256 = provider_sha256,
        .budget_authorization_sha256 = cc.tools.tool_observation.sha256Hex(
            "mac-pilot/zero-paid-scripted-authorization",
        ),
        .model = MODEL,
        .observation = run_binding,
        .trigger = .repeated_typed_failure,
        .evidence = &.{},
        .caps = .{
            .max_cost_microusd = 1_000_000,
            .max_input_tokens = 100_000,
            .max_output_tokens = 256,
        },
        .pricing = .{
            .provenance_sha256 = cc.tools.tool_observation.sha256Hex("mac-pilot/scripted-zero-price-authority"),
            .input_microusd_per_mtok = 3_000_000,
            .output_microusd_per_mtok = 15_000_000,
            .cache_read_microusd_per_mtok = 300_000,
            .cache_write_microusd_per_mtok = 3_750_000,
        },
        .generation_evidence = &.{generation.value},
        .held_out_commitments = &held,
    });
    defer prepared.deinit();
    const permit = try prepared.authorize(.{
        .enabled = true,
        .now_ns = cc.util_time.nowNs(),
        .last_authorized_ns = null,
        .cooldown_ns = 0,
        .remaining_requests = 1,
        .remaining_cost_microusd = 1_000_000,
        .remaining_input_tokens = 100_000,
        .remaining_output_tokens = 256,
    });

    var provider_client = cc.client.Client.initWithBaseUrl(
        allocator,
        io_runtime.io(),
        "mac-pilot-non-secret",
        MODEL,
        provider_url,
    );
    defer provider_client.deinit();
    provider_client.setMaxTokensOverride(256);
    const outcome = try cc.project_rule_evolution.authorOnce(
        &prepared,
        .{ .provider = provider_client.provider(), .provider_sha256 = provider_sha256 },
        permit,
        null,
    );
    const candidate_id = outcome.candidate_id orelse return error.RuleCandidateMissing;
    const verified = try cc.rule_author.verifyCandidateBinding(
        allocator,
        session_dir,
        outcome.author_receipt_id,
        candidate_id,
    );
    if (!verified) return error.CandidateBindingMismatch;

    const output = Output{
        .candidate_created = outcome.candidate_created,
        .candidate_binding_verified = verified,
        .author_receipt_id = outcome.author_receipt_id[0..],
        .candidate_id = candidate_id[0..],
        .ontology_revision = prepared.ontology.projected.ontology_revision[0..],
        .ontology_snapshot_sha256 = prepared.ontology.projected.ontology_snapshot_sha256[0..],
        .input_tokens = outcome.usage.input_tokens,
        .output_tokens = outcome.usage.output_tokens,
        .cache_read_input_tokens = outcome.usage.cache_read_input_tokens,
        .cache_creation_input_tokens = outcome.usage.cache_creation_input_tokens,
        .provider_elapsed_ns = outcome.provider_elapsed_ns,
    };
    var buffer: [8192]u8 = undefined;
    var file_writer: std.Io.File.Writer = .init(.stdout(), init.io, &buffer);
    const writer = &file_writer.interface;
    try std.json.Stringify.value(output, .{}, writer);
    try writer.writeByte('\n');
    try writer.flush();
}

fn completedFailureRun(session_dir: []const u8) !cc.tool_observation_journal.RunBinding {
    const sid = cc.session_id.SessionId.fromSlice("0123456789abcdef01234567").?;
    var journal = try cc.tool_observation_journal.Journal.init(session_dir, sid);
    errdefer journal.deinit();
    const ids = [_][]const u8{ "pilot-failure-0", "pilot-failure-1", "pilot-failure-2" };
    for (ids) |id| {
        if (!journal.sink().emit(.{ .dispatch_started = .{
            .id = id,
            .requested_name = "Write",
            .dispatched_name = "Write",
            .origin = .authoritative,
            .agent_depth = 0,
            .input_bytes = 2,
            .input_sha256 = cc.tools.tool_observation.sha256Hex("{}"),
        } })) return error.ObservationRejected;
        if (!journal.sink().emit(.{ .dispatch_finished = .{
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
            .result_sha256 = cc.tools.tool_observation.sha256Hex("{}"),
            .effect = null,
            .effect_valid = true,
        } })) return error.ObservationRejected;
    }
    try journal.finishRun("end_turn");
    const binding = try journal.runBinding();
    journal.deinit();
    return binding;
}
