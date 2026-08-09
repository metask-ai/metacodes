//! One-shot GLM feasibility probe for the isolated rule-author adapter.
//!
//! A parent budget runner must durably authorize the paid transaction before
//! launching this process and pass only the authorization receipt hash in argv.
//! The provider credential arrives through METACODES_API_KEY_FD; it is never
//! written to argv, environment values, receipts, or stdout.

const std = @import("std");
const cc = @import("metacodes-core");

const MODEL = "glm-5.2";
const PROVIDER_IDENTITY = "napi.metask-ai.com/anthropic-protocol/rule-author";
const CAPS = cc.rule_author.CallCaps{
    .max_cost_microusd = 200_000,
    .max_input_tokens = 32_000,
    .max_output_tokens = 1024,
};
fn pricing() cc.rule_author.PricingAuthority {
    return .{
        .provenance_sha256 = cc.tools.tool_observation.sha256Hex(
            "glm-5.2-sonnet4-conservative-guardrail-2026-08-07",
        ),
        .input_microusd_per_mtok = 3_000_000,
        .output_microusd_per_mtok = 15_000_000,
        .cache_read_microusd_per_mtok = 300_000,
        .cache_write_microusd_per_mtok = 3_750_000,
    };
}

const Output = struct {
    schema_version: []const u8 = "metacodes-rule-author-feasibility-v1",
    quality_evidence: bool = false,
    model: []const u8 = MODEL,
    decision: cc.rule_author.Decision,
    receipt_id: []const u8,
    candidate_id: ?[]const u8,
    candidate_binding_verified: bool,
    input_tokens: u64,
    output_tokens: u64,
    cache_read_input_tokens: u64,
    cache_creation_input_tokens: u64,
    metered_tokens: u64,
    cost_microusd: u64,
    provider_elapsed_ns: u64,
};

pub fn main(init: std.process.Init) !void {
    const allocator = std.heap.c_allocator;
    var args = std.process.Args.iterateAllocator(init.minimal.args, allocator) catch
        return error.InvalidArguments;
    defer args.deinit();
    _ = args.next();
    const session_dir = args.next() orelse return printUsage();
    const budget_text = args.next() orelse return printUsage();
    if (args.next() != null) return printUsage();
    const budget_authorization = parseHex(budget_text) orelse return error.InvalidBudgetAuthorization;
    const price_authority = pricing();

    const binding = try completedFailureRun(session_dir);
    var prepared = try cc.rule_author.prepare(allocator, .{
        .session_dir = session_dir,
        .project_sha256 = cc.tools.tool_observation.sha256Hex("metacodes-project"),
        .author_sha256 = cc.rule_author.systemPromptSha256(),
        .provider_sha256 = cc.tools.tool_observation.sha256Hex(PROVIDER_IDENTITY),
        .budget_authorization_sha256 = budget_authorization,
        .model = MODEL,
        .observation = binding,
        .trigger = .repeated_typed_failure,
        .evidence = &.{},
        .caps = CAPS,
        .pricing = price_authority,
    });
    defer prepared.deinit();
    const permit = try cc.rule_author.authorize(&prepared, .{
        .enabled = true,
        .now_ns = cc.util_time.nowNs(),
        .last_authorized_ns = null,
        .cooldown_ns = 300 * std.time.ns_per_s,
        .remaining_requests = 1,
        .remaining_cost_microusd = CAPS.max_cost_microusd,
        .remaining_input_tokens = CAPS.max_input_tokens,
        .remaining_output_tokens = CAPS.max_output_tokens,
    });

    var credential = try cc.auth.resolveRuntimeCredential(
        allocator,
        null,
        .api_key_first,
    );
    defer credential.deinit(allocator);
    var io_runtime = std.Io.Threaded.init(allocator, .{});
    defer io_runtime.deinit();
    var client = cc.client.Client.init(
        allocator,
        io_runtime.io(),
        credential.bearer_token,
        MODEL,
    );
    defer client.deinit();
    client.setMaxTokensOverride(@intCast(CAPS.max_output_tokens));

    var authored = try cc.rule_author.author(allocator, session_dir, .{
        .provider = client.provider(),
        .provider_sha256 = prepared.provider_sha256,
    }, &prepared, permit, null);
    defer authored.deinit();
    var candidate_id: ?[64]u8 = null;
    var candidate_binding_verified = false;
    if (authored.proposal != null) {
        const persisted = try cc.rule_author.persistCandidate(
            allocator,
            session_dir,
            &authored,
        );
        candidate_id = persisted.candidate_id;
        candidate_binding_verified = try cc.rule_author.verifyCandidateBinding(
            allocator,
            session_dir,
            authored.receipt_id,
            persisted.candidate_id,
        );
        if (!candidate_binding_verified) return error.CandidateBindingMismatch;
    }
    const metered_tokens = try meteredTokens(authored.usage);
    const cost_microusd = try cc.rule_author.actualCost(authored.usage, price_authority);
    const candidate_slice: ?[]const u8 = if (candidate_id) |*value| value[0..] else null;
    const output = Output{
        .decision = authored.decision,
        .receipt_id = authored.receipt_id[0..],
        .candidate_id = candidate_slice,
        .candidate_binding_verified = candidate_binding_verified,
        .input_tokens = authored.usage.input_tokens,
        .output_tokens = authored.usage.output_tokens,
        .cache_read_input_tokens = authored.usage.cache_read_input_tokens,
        .cache_creation_input_tokens = authored.usage.cache_creation_input_tokens,
        .metered_tokens = metered_tokens,
        .cost_microusd = cost_microusd,
        .provider_elapsed_ns = authored.provider_elapsed_ns,
    };
    const json = try std.json.Stringify.valueAlloc(allocator, output, .{});
    defer allocator.free(json);
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), init.io, &stdout_buffer);
    const stdout = &stdout_file_writer.interface;
    try stdout.writeAll(json);
    try stdout.writeByte('\n');
    try stdout.flush();
}

fn completedFailureRun(session_dir: []const u8) !cc.tool_observation_journal.RunBinding {
    const sid = cc.session_id.SessionId.fromSlice("89abcdef0123456789abcdef").?;
    var journal = try cc.tool_observation_journal.Journal.init(session_dir, sid);
    errdefer journal.deinit();
    const ids = [_][]const u8{ "author-failure-0", "author-failure-1", "author-failure-2" };
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

fn meteredTokens(observed: cc.rule_author.Usage) !u64 {
    var total = observed.input_tokens;
    total = std.math.add(u64, total, observed.output_tokens) catch return error.UsageOverflow;
    total = std.math.add(u64, total, observed.cache_read_input_tokens) catch return error.UsageOverflow;
    total = std.math.add(u64, total, observed.cache_creation_input_tokens) catch return error.UsageOverflow;
    return total;
}

fn parseHex(value: []const u8) ?[64]u8 {
    if (value.len != 64) return null;
    var result: [64]u8 = undefined;
    for (value, 0..) |byte, index| {
        if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return null;
        result[index] = byte;
    }
    return result;
}

fn printUsage() error{InvalidArguments} {
    std.debug.print(
        "usage: rule-author-feasibility <isolated-session-dir> <budget-authorization-sha256>\n",
        .{},
    );
    return error.InvalidArguments;
}
