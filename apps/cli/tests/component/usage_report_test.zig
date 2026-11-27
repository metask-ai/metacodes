//! L2: provider usage reports are running totals, so the usage a host sees adds
//! up to what the provider reported for each response — not to the sum of its
//! reports.
//!
//! Anthropic's streaming documentation states that `message_delta.usage` is
//! cumulative, after a `message_start` that already counted part of the same
//! response; OpenAI-compatible servers may repeat the usage object on several
//! chunks and Gemini repeats `usageMetadata`; Bedrock Converse reports the
//! response's total in a `metadata` event. Each test drives the real agent
//! loop over one provider's client against a scripted server and reads the
//! totals where `/cost`, `--json` and the cost budget read them
//! (`WriterBackend` → `UsageTotals`) and where a goal budget is charged.

const std = @import("std");
const harness = @import("harness");
const cc = @import("cc");

const Totals = cc.app_module.UsageTotals;

const Charged = struct {
    totals: Totals = .{},
    goal_tokens: u64 = 0,
    context_tokens: usize = 0,
};

fn runLoop(a: std.mem.Allocator, provider: anytype) !Charged {
    var state = cc.core_goal.State.init(a);
    defer state.deinit();
    try state.setNew("count the usage", null);
    var meter = cc.core_goal.Meter.init(&state);

    var conv = cc.conversation.Conversation.init(a);
    defer conv.deinit();
    try conv.appendText(.user, "count the usage");
    var perm = cc.permission.createContext(.bypass_permissions, a);
    perm.no_interactive_prompt = true;

    var charged = Charged{};
    var writer = cc.writer_backend.WriterBackend.initNullWithUsage(&charged.totals);
    const be = writer.backend();
    const result = try cc.agent_loop.run(&conv, provider, &.{}, &perm, .{
        .max_turns = 4,
        .goal_meter = &meter,
    }, &be, a);
    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, result.stop_reason);
    charged.goal_tokens = state.current.?.tokens_used;
    charged.context_tokens = if (conv.usageAnchor()) |anchor| anchor.context_tokens else 0;
    return charged;
}

fn runAnthropic(a: std.mem.Allocator, bodies: []const []const u8) !Charged {
    var srv = try harness.MockServer.startCassette(bodies, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);
    var io_rt = @import("platform").signal.threadedIo(a, .{});
    defer io_rt.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(a, io_rt.io(), "key", "model", url);
    defer client.deinit();
    return runLoop(a, client.provider());
}

fn expectTotals(charged: Charged, input: u64, output: u64, cache_read: u64) !void {
    try std.testing.expectEqual(input, charged.totals.input_tokens);
    try std.testing.expectEqual(output, charged.totals.output_tokens);
    try std.testing.expectEqual(cache_read, charged.totals.cache_read_input_tokens);
    // The goal is charged non-cached input plus output, from the same events.
    try std.testing.expectEqual(input + output, charged.goal_tokens);
}

// The official documentation's shape: message_start counts the prompt and the
// first output token, message_delta repeats the output count as a total.
const OFFICIAL_TOOL_TURN =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"m1\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":40,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"t1\",\"name\":\"NoSuchTool\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{}\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":9}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const OFFICIAL_FINAL_TURN =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"m2\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":3,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"done\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":2}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

test "L2 usage: Anthropic message_delta totals do not count message_start's output twice" {
    const a = std.testing.allocator;
    const charged = try runAnthropic(a, &.{ OFFICIAL_TOOL_TURN, OFFICIAL_FINAL_TURN });
    // Response 1 used 40 in / 9 out, response 2 used 3 in / 2 out.
    try expectTotals(charged, 43, 11, 0);
}

// With a server tool the final message_delta also carries cumulative input and
// cache counters (the documentation's web-search example).
const SERVER_TOOL_TURN =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"m3\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":2679,\"cache_creation_input_tokens\":0,\"cache_read_input_tokens\":120,\"output_tokens\":3}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"sunny\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":null},\"usage\":{\"output_tokens\":200}}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"input_tokens\":10682,\"cache_creation_input_tokens\":0,\"cache_read_input_tokens\":120,\"output_tokens\":510}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

test "L2 usage: cumulative input and cache counters in message_delta are counted once" {
    const a = std.testing.allocator;
    const charged = try runAnthropic(a, &.{SERVER_TOOL_TURN});
    try expectTotals(charged, 10682, 510, 120);
}

// The other side: gateways that send a zero placeholder in message_start and the
// whole response in message_delta must keep every token.
const PLACEHOLDER_TURN =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"m4\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":0,\"output_tokens\":0}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"ok\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"input_tokens\":1200,\"output_tokens\":80,\"cache_read_input_tokens\":9000}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

test "L2 usage: a zero message_start placeholder followed by a full message_delta loses nothing" {
    const a = std.testing.allocator;
    const charged = try runAnthropic(a, &.{PLACEHOLDER_TURN});
    try expectTotals(charged, 1200, 80, 9000);
}

const PROVISIONAL_ESTIMATE_TURN =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"m5\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":8607,\"output_tokens\":0,\"cache_read_input_tokens\":0,\"cache_creation_input_tokens\":0}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"ok\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"input_tokens\":1434,\"output_tokens\":65,\"cache_read_input_tokens\":16000,\"cache_creation_input_tokens\":0}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

test "L2 usage: Anthropic message_delta revising input_tokens down replaces message_start estimate" {
    const a = std.testing.allocator;
    const charged = try runAnthropic(a, &.{PROVISIONAL_ESTIMATE_TURN});
    try expectTotals(charged, 1434, 65, 16000);
    try std.testing.expectEqual(@as(usize, 17434), charged.context_tokens);
}

const OPENAI_REPEATED_USAGE =
    "data: {\"choices\":[{\"delta\":{\"role\":\"assistant\",\"content\":\"hel\"}}],\"usage\":{\"prompt_tokens\":10000,\"completion_tokens\":1,\"total_tokens\":10001}}\n\n" ++
    "data: {\"choices\":[{\"delta\":{\"content\":\"lo\"}}],\"usage\":{\"prompt_tokens\":10000,\"completion_tokens\":2,\"total_tokens\":10002,\"prompt_tokens_details\":{\"cached_tokens\":9000}}}\n\n" ++
    "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}],\"usage\":{\"prompt_tokens\":10000,\"completion_tokens\":3,\"total_tokens\":10003,\"prompt_tokens_details\":{\"cached_tokens\":9000}}}\n\n" ++
    "data: [DONE]\n\n";

test "L2 usage: an OpenAI-compatible usage object repeated on every chunk settles to final cache split" {
    const a = std.testing.allocator;
    var srv = try harness.MockServer.startCassette(&.{OPENAI_REPEATED_USAGE}, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);
    var io_rt = @import("platform").signal.threadedIo(a, .{});
    defer io_rt.deinit();
    var client = cc.api_openai.OpenAIClient.init(a, io_rt.io(), "key", "gpt-4o", url);
    defer client.deinit();
    try expectTotals(try runLoop(a, client.provider()), 1000, 3, 9000);
}

const GEMINI_REPEATED_USAGE =
    "data: {\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"text\":\"hel\"}]}}],\"usageMetadata\":{\"promptTokenCount\":10000,\"candidatesTokenCount\":1,\"totalTokenCount\":10001}}\n\n" ++
    "data: {\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"text\":\"lo\"}]},\"finishReason\":\"STOP\"}],\"usageMetadata\":{\"promptTokenCount\":10000,\"candidatesTokenCount\":4,\"cachedContentTokenCount\":9000,\"totalTokenCount\":10004}}\n\n";

test "L2 usage: Gemini usageMetadata repeated on several chunks settles to final cache split" {
    const a = std.testing.allocator;
    var srv = try harness.MockServer.startCassette(&.{GEMINI_REPEATED_USAGE}, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);
    var io_rt = @import("platform").signal.threadedIo(a, .{});
    defer io_rt.deinit();
    var client = cc.api_gemini.GeminiClient.init(a, io_rt.io(), "key", "gemini-2.5-flash", url);
    defer client.deinit();
    try expectTotals(try runLoop(a, client.provider()), 1000, 4, 9000);
}

test "L2 usage: a Bedrock Converse metadata report revised in one response settles to final report" {
    const a = std.testing.allocator;
    const es = cc.api_aws_event_stream;
    const events = [_][2][]const u8{
        .{ "messageStart", "{\"role\":\"assistant\"}" },
        .{ "contentBlockDelta", "{\"contentBlockIndex\":0,\"delta\":{\"text\":\"done\"}}" },
        .{ "contentBlockStop", "{\"contentBlockIndex\":0}" },
        .{ "messageStop", "{\"stopReason\":\"end_turn\"}" },
        .{ "metadata", "{\"usage\":{\"inputTokens\":16,\"outputTokens\":7,\"cacheReadInputTokens\":0,\"totalTokens\":23}}" },
        .{ "metadata", "{\"usage\":{\"inputTokens\":11,\"outputTokens\":7,\"cacheReadInputTokens\":5,\"totalTokens\":23}}" },
    };
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(a);
    for (events) |event| {
        const frame = try es.encodeEvent(a, event[0], event[1]);
        defer a.free(frame);
        try body.appendSlice(a, frame);
    }
    var srv = try harness.MockServer.startCassette(&.{body.items}, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);
    var owned = try cc.api_provider_factory.makeProviderWithOptions(
        a,
        .bedrock,
        .{ .fixed = "brk-key" },
        "us.anthropic.claude-sonnet-4-6",
        url[0 .. url.len - "/v1/messages".len],
        .chat_completions,
        .builtin(),
        .{},
    );
    defer owned.deinit();
    try expectTotals(try runLoop(a, owned.provider()), 11, 7, 5);
}
