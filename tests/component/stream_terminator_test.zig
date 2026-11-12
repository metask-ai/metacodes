//! Issue #269: a provider stream that ends before it reports how it stopped is
//! not a finished answer, on any wire.
//!
//! Each wire has its own stop report: Anthropic's `message_delta.stop_reason`,
//! OpenAI chat's `finish_reason`, the Responses terminal event
//! (`response.completed` / `response.incomplete`), and Gemini's
//! `finishReason`. Before the fix, a clean EOF (or a bare `[DONE]`) without it
//! was normalized to `end_turn`: when the lost bytes were the ones carrying a
//! `max_tokens`/`length` stop, a truncated answer read as complete and the
//! continuation safety net never fired. These tests drive the real clients and
//! the real agent loop against a cassette server and prove input → result:
//! an unterminated stream is discarded and re-issued (same-turn retry), and
//! with no retry left the Run ends in `api_error`, never `end_turn`.

const std = @import("std");
const harness = @import("harness");
const cc = @import("cc");

const agent_loop = cc.agent_loop;

const Wire = enum { anthropic, openai_chat, openai_responses, gemini };

// ── cassettes: one complete and one unterminated stream per wire ─────────────

const ANTHROPIC_COMPLETE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"m2\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"complete answer\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":2}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

/// Every content event arrived; message_delta (the stop report) and
/// message_stop did not, and the connection closed cleanly.
const ANTHROPIC_UNTERMINATED =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"m1\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"looks finished\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n";

const CHAT_COMPLETE =
    "data: {\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"complete answer\"},\"finish_reason\":null}]}\n\n" ++
    "data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n" ++
    "data: [DONE]\n\n";

/// The issue's chat shape: every content chunk and `[DONE]`, but not the final
/// chunk carrying finish_reason.
const CHAT_UNTERMINATED =
    "data: {\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"looks finished\"},\"finish_reason\":null}]}\n\n" ++
    "data: [DONE]\n\n";

const RESPONSES_COMPLETE =
    "event: response.output_text.delta\n" ++
    "data: {\"type\":\"response.output_text.delta\",\"item_id\":\"msg_2\",\"output_index\":0,\"delta\":\"complete answer\"}\n\n" ++
    "event: response.completed\n" ++
    "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_2\",\"status\":\"completed\",\"usage\":{\"input_tokens\":1,\"input_tokens_details\":{\"cached_tokens\":0},\"output_tokens\":2}}}\n\n";

/// The full event sequence except `response.completed`.
const RESPONSES_UNTERMINATED =
    "event: response.created\n" ++
    "data: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_1\"}}\n\n" ++
    "event: response.output_text.delta\n" ++
    "data: {\"type\":\"response.output_text.delta\",\"item_id\":\"msg_1\",\"output_index\":0,\"delta\":\"looks finished\"}\n\n" ++
    "event: response.output_text.done\n" ++
    "data: {\"type\":\"response.output_text.done\",\"item_id\":\"msg_1\",\"output_index\":0,\"text\":\"looks finished\"}\n\n";

const GEMINI_COMPLETE =
    "data: {\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"text\":\"complete answer\"}]},\"finishReason\":\"STOP\"}],\"usageMetadata\":{\"promptTokenCount\":1,\"candidatesTokenCount\":2}}\n\n";

/// Gemini has no frame tail: the chunk with finishReason is the terminator.
const GEMINI_UNTERMINATED =
    "data: {\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"text\":\"looks finished\"}]}}]}\n\n";

fn complete(wire: Wire) []const u8 {
    return switch (wire) {
        .anthropic => ANTHROPIC_COMPLETE,
        .openai_chat => CHAT_COMPLETE,
        .openai_responses => RESPONSES_COMPLETE,
        .gemini => GEMINI_COMPLETE,
    };
}

fn unterminated(wire: Wire) []const u8 {
    return switch (wire) {
        .anthropic => ANTHROPIC_UNTERMINATED,
        .openai_chat => CHAT_UNTERMINATED,
        .openai_responses => RESPONSES_UNTERMINATED,
        .gemini => GEMINI_UNTERMINATED,
    };
}

// ── driver ───────────────────────────────────────────────────────────────────

const Outcome = struct {
    result: agent_loop.RunResult,
    requests: usize,
    /// Committed assistant text, in order (owned).
    text: []u8,

    fn deinit(self: *Outcome, a: std.mem.Allocator) void {
        a.free(self.text);
    }
};

fn runWire(a: std.mem.Allocator, wire: Wire, bodies: []const []const u8, retries: u8) !Outcome {
    var srv = try harness.MockServer.startCassette(bodies, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    var io_rt = @import("platform").signal.threadedIo(a, .{});
    defer io_rt.deinit();
    const io = io_rt.io();

    var conv = cc.conversation.Conversation.init(a);
    defer conv.deinit();
    try conv.appendText(.user, "write the report");

    const result = switch (wire) {
        .anthropic => blk: {
            var client = cc.client_mod.Client.initWithBaseUrl(a, io, "key", "model", url);
            defer client.deinit();
            break :blk try runLoop(a, &conv, client.provider(), retries);
        },
        .openai_chat, .openai_responses => blk: {
            var client = cc.api_openai.OpenAIClient.init(a, io, "key", "model", url);
            defer client.deinit();
            if (wire == .openai_responses) client.protocol = .responses;
            break :blk try runLoop(a, &conv, client.provider(), retries);
        },
        .gemini => blk: {
            var client = cc.api_gemini.GeminiClient.init(a, io, "key", "gemini-2.5-flash", url);
            defer client.deinit();
            break :blk try runLoop(a, &conv, client.provider(), retries);
        },
    };

    var text: std.ArrayList(u8) = .empty;
    errdefer text.deinit(a);
    for (conv.messages.items) |m| {
        if (m.role != .assistant) continue;
        for (m.blocks) |b| switch (b) {
            .text => |t| try text.appendSlice(a, t),
            else => {},
        };
    }
    return .{ .result = result, .requests = srv.requestCount(), .text = try text.toOwnedSlice(a) };
}

fn runLoop(a: std.mem.Allocator, conv: *cc.conversation.Conversation, provider: cc.api_provider.Provider, retries: u8) !agent_loop.RunResult {
    var perm = cc.permission.createContext(.bypass_permissions, a);
    perm.no_interactive_prompt = true;
    const no_tools: []const cc.json_mod.ToolDefinition = &.{};
    var render = cc.writer_backend.WriterBackend.initNull();
    const be = render.backend();
    return agent_loop.run(conv, provider, no_tools, &perm, .{
        .max_turns = 4,
        .max_stream_turn_retries = retries,
    }, &be, a);
}

// ── tests ────────────────────────────────────────────────────────────────────

test "issue #269: an unterminated stream is discarded and re-issued on every wire" {
    const a = std.testing.allocator;
    for (std.enums.values(Wire)) |wire| {
        errdefer std.debug.print("wire={s}\n", .{@tagName(wire)});
        var out = try runWire(a, wire, &.{ unterminated(wire), complete(wire) }, 1);
        defer out.deinit(a);
        try std.testing.expectEqual(agent_loop.StopReason.end_turn, out.result.stop_reason);
        // The re-issue really happened, and the unterminated text never
        // entered the Conversation (it would be fed back as context).
        try std.testing.expectEqual(@as(usize, 2), out.requests);
        try std.testing.expectEqualStrings("complete answer", out.text);
        try std.testing.expectEqual(@as(u32, 0), out.result.continuations);
    }
}

test "issue #269: with no retry left an unterminated stream ends the Run in api_error, not end_turn" {
    const a = std.testing.allocator;
    for (std.enums.values(Wire)) |wire| {
        errdefer std.debug.print("wire={s}\n", .{@tagName(wire)});
        // The cassette repeats its body, so the request's own re-issue (#461)
        // is unterminated too and nothing is left after it.
        var out = try runWire(a, wire, &.{unterminated(wire)}, 0);
        defer out.deinit(a);
        try std.testing.expectEqual(agent_loop.StopReason.api_error, out.result.stop_reason);
        try std.testing.expectEqual(@as(usize, 2), out.requests);
        try std.testing.expectEqualStrings("", out.text);
    }
}

test "issue #269: a reported max_tokens survives a lost message_stop and the continuation fires" {
    // Only the frame tail is lost; the stop report the continuation net needs
    // arrived, so the answer is continued rather than retried or accepted.
    const a = std.testing.allocator;
    const cut_without_message_stop =
        "data: {\"type\":\"message_start\",\"message\":{\"id\":\"m1\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
        "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"first half \"}}\n\n" ++
        "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
        "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"max_tokens\"},\"usage\":{\"output_tokens\":2}}\n\n";
    var out = try runWire(a, .anthropic, &.{ cut_without_message_stop, ANTHROPIC_COMPLETE }, 0);
    defer out.deinit(a);
    try std.testing.expectEqual(agent_loop.StopReason.end_turn, out.result.stop_reason);
    try std.testing.expectEqual(@as(u32, 1), out.result.continuations);
    try std.testing.expectEqual(@as(usize, 2), out.requests);
    try std.testing.expectEqualStrings("first half complete answer", out.text);
}

test "issue #269: chat finish_reason=length without [DONE] still continues" {
    const a = std.testing.allocator;
    const cut_without_done =
        "data: {\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"first half \"},\"finish_reason\":null}]}\n\n" ++
        "data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"length\"}]}\n\n";
    var out = try runWire(a, .openai_chat, &.{ cut_without_done, CHAT_COMPLETE }, 0);
    defer out.deinit(a);
    try std.testing.expectEqual(agent_loop.StopReason.end_turn, out.result.stop_reason);
    try std.testing.expectEqual(@as(u32, 1), out.result.continuations);
    try std.testing.expectEqualStrings("first half complete answer", out.text);
}
