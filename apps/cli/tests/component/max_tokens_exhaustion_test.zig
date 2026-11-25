//! Issue #394: once the max-token continuation allowance is spent, a last turn
//! that still ends on the wire's max-token terminal leaves the Run incomplete,
//! whether or not it streamed visible text.
//!
//! Each wire reports the cut its own way: Chat Completions'
//! `finish_reason=length`, Responses' `response.incomplete` with
//! `incomplete_details.reason=max_output_tokens`, Anthropic's
//! `stop_reason=max_tokens` and Gemini's `finishReason=MAX_TOKENS`. Before the
//! fix only a cut turn with no text reached `max_tokens_exhausted`; one that
//! carried text fell through to the common tail and closed as the final
//! answer: `end_turn`, `text_kind=final`, exit 0, and a timeline of
//! `continued → continued → continued → final`.
//!
//! These tests drive the real clients and the real agent loop against a
//! loopback cassette server, then project the Run through the pieces headless
//! `-p --json --stream-json` uses: the stream-json backend for the timeline,
//! `projectRunText` and `buildResultLine` for the result line, and
//! `exitCodeFor` for the exit code. The controls keep the neighbouring
//! contracts in place: a continuation that ends cleanly is still one final
//! answer, and a complete tool_use on the last cut turn still runs.

const std = @import("std");
const harness = @import("harness");
const cc = @import("cc");

const agent_loop = cc.agent_loop;
const headless = cc.repl_headless;
const Disposition = cc.output_semantics.Disposition;

const Wire = enum { anthropic, openai_chat, openai_responses, gemini };

/// How a provider response ends.
const Ending = enum {
    /// The wire's max-token terminal.
    cut,
    /// A normal end of turn.
    complete,
};

/// One provider response with `text` (none when empty). The texts used here
/// are plain ASCII, so they go into the JSON string literals unescaped.
fn textBody(a: std.mem.Allocator, wire: Wire, text: []const u8, ending: Ending) ![]u8 {
    return switch (wire) {
        .anthropic => std.fmt.allocPrint(a, "{s}{s}" ++
            "data: {{\"type\":\"message_delta\",\"delta\":{{\"stop_reason\":\"{s}\"}},\"usage\":{{\"output_tokens\":2}}}}\n\n" ++
            "data: {{\"type\":\"message_stop\"}}\n\n", .{
            "data: {\"type\":\"message_start\",\"message\":{\"id\":\"m1\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n",
            if (text.len == 0) "" else try std.fmt.allocPrint(a, "data: {{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{{\"type\":\"text\",\"text\":\"\"}}}}\n\n" ++
                "data: {{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{{\"type\":\"text_delta\",\"text\":\"{s}\"}}}}\n\n" ++
                "data: {{\"type\":\"content_block_stop\",\"index\":0}}\n\n", .{text}),
            switch (ending) {
                .cut => "max_tokens",
                .complete => "end_turn",
            },
        }),
        .openai_chat => std.fmt.allocPrint(a, "data: {{\"choices\":[{{\"index\":0,\"delta\":{{\"role\":\"assistant\",\"content\":\"{s}\"}},\"finish_reason\":null}}]}}\n\n" ++
            "data: {{\"choices\":[{{\"index\":0,\"delta\":{{}},\"finish_reason\":\"{s}\"}}]}}\n\n" ++
            "data: [DONE]\n\n", .{ text, switch (ending) {
            .cut => "length",
            .complete => "stop",
        } }),
        .openai_responses => std.fmt.allocPrint(a, "event: response.created\n" ++
            "data: {{\"type\":\"response.created\",\"response\":{{\"id\":\"resp_1\"}}}}\n\n" ++
            "{s}{s}", .{
            if (text.len == 0) "" else try std.fmt.allocPrint(a, "event: response.output_text.delta\n" ++
                "data: {{\"type\":\"response.output_text.delta\",\"item_id\":\"msg_1\",\"output_index\":0,\"delta\":\"{s}\"}}\n\n", .{text}),
            switch (ending) {
                .cut => "event: response.incomplete\n" ++
                    "data: {\"type\":\"response.incomplete\",\"response\":{\"id\":\"resp_1\",\"status\":\"incomplete\",\"incomplete_details\":{\"reason\":\"max_output_tokens\"},\"usage\":{\"input_tokens\":1,\"input_tokens_details\":{\"cached_tokens\":0},\"output_tokens\":2}}}\n\n",
                .complete => "event: response.completed\n" ++
                    "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_1\",\"status\":\"completed\",\"usage\":{\"input_tokens\":1,\"input_tokens_details\":{\"cached_tokens\":0},\"output_tokens\":2}}}\n\n",
            },
        }),
        .gemini => std.fmt.allocPrint(a, "data: {{\"candidates\":[{{\"content\":{{\"role\":\"model\",\"parts\":[{{\"text\":\"{s}\"}}]}},\"finishReason\":\"{s}\"}}],\"usageMetadata\":{{\"promptTokenCount\":1,\"candidatesTokenCount\":2}}}}\n\n", .{ text, switch (ending) {
            .cut => "MAX_TOKENS",
            .complete => "STOP",
        } }),
    };
}

/// A complete tool call that the wire still reports as cut at the token limit.
fn toolBody(wire: Wire) []const u8 {
    return switch (wire) {
        .anthropic => "data: {\"type\":\"message_start\",\"message\":{\"id\":\"m1\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
            "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"tu_final\",\"name\":\"DefinitelyUnknown\",\"input\":{}}}\n\n" ++
            "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{}\"}}\n\n" ++
            "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
            "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"max_tokens\"},\"usage\":{\"output_tokens\":2}}\n\n" ++
            "data: {\"type\":\"message_stop\"}\n\n",
        .openai_chat => "data: {\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"tool_calls\":[{\"index\":0,\"id\":\"call_final\",\"type\":\"function\",\"function\":{\"name\":\"DefinitelyUnknown\",\"arguments\":\"{}\"}}]},\"finish_reason\":null}]}\n\n" ++
            "data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"length\"}]}\n\n" ++
            "data: [DONE]\n\n",
        .openai_responses => "event: response.output_item.added\n" ++
            "data: {\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{\"type\":\"function_call\",\"id\":\"fc_1\",\"call_id\":\"call_final\",\"name\":\"DefinitelyUnknown\",\"arguments\":\"\"}}\n\n" ++
            "event: response.function_call_arguments.done\n" ++
            "data: {\"type\":\"response.function_call_arguments.done\",\"item_id\":\"fc_1\",\"output_index\":0,\"arguments\":\"{}\"}\n\n" ++
            "event: response.incomplete\n" ++
            "data: {\"type\":\"response.incomplete\",\"response\":{\"id\":\"resp_1\",\"status\":\"incomplete\",\"incomplete_details\":{\"reason\":\"max_output_tokens\"},\"usage\":{\"input_tokens\":1,\"input_tokens_details\":{\"cached_tokens\":0},\"output_tokens\":2}}}\n\n",
        .gemini => "data: {\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"functionCall\":{\"name\":\"DefinitelyUnknown\",\"args\":{}}}]},\"finishReason\":\"MAX_TOKENS\"}],\"usageMetadata\":{\"promptTokenCount\":1,\"candidatesTokenCount\":2}}\n\n",
    };
}

/// A complete tool call with call id `id`, ending either at the token limit
/// (`cut`) or normally (`complete`: the wire's tool-call stop).
fn toolCallBody(a: std.mem.Allocator, wire: Wire, id: []const u8, ending: Ending) ![]u8 {
    return switch (wire) {
        .anthropic => std.fmt.allocPrint(a, "data: {{\"type\":\"message_start\",\"message\":{{\"id\":\"m1\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{{\"input_tokens\":1,\"output_tokens\":1}}}}}}\n\n" ++
            "data: {{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{{\"type\":\"tool_use\",\"id\":\"{s}\",\"name\":\"DefinitelyUnknown\",\"input\":{{}}}}}}\n\n" ++
            "data: {{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{{\"type\":\"input_json_delta\",\"partial_json\":\"{{}}\"}}}}\n\n" ++
            "data: {{\"type\":\"content_block_stop\",\"index\":0}}\n\n" ++
            "data: {{\"type\":\"message_delta\",\"delta\":{{\"stop_reason\":\"{s}\"}},\"usage\":{{\"output_tokens\":2}}}}\n\n" ++
            "data: {{\"type\":\"message_stop\"}}\n\n", .{ id, switch (ending) {
            .cut => "max_tokens",
            .complete => "tool_use",
        } }),
        .openai_chat => std.fmt.allocPrint(a, "data: {{\"choices\":[{{\"index\":0,\"delta\":{{\"role\":\"assistant\",\"tool_calls\":[{{\"index\":0,\"id\":\"{s}\",\"type\":\"function\",\"function\":{{\"name\":\"DefinitelyUnknown\",\"arguments\":\"{{}}\"}}}}]}},\"finish_reason\":null}}]}}\n\n" ++
            "data: {{\"choices\":[{{\"index\":0,\"delta\":{{}},\"finish_reason\":\"{s}\"}}]}}\n\n" ++
            "data: [DONE]\n\n", .{ id, switch (ending) {
            .cut => "length",
            .complete => "tool_calls",
        } }),
        .openai_responses => std.fmt.allocPrint(a, "event: response.output_item.added\n" ++
            "data: {{\"type\":\"response.output_item.added\",\"output_index\":0,\"item\":{{\"type\":\"function_call\",\"id\":\"fc_{s}\",\"call_id\":\"{s}\",\"name\":\"DefinitelyUnknown\",\"arguments\":\"\"}}}}\n\n" ++
            "event: response.function_call_arguments.done\n" ++
            "data: {{\"type\":\"response.function_call_arguments.done\",\"item_id\":\"fc_{s}\",\"output_index\":0,\"arguments\":\"{{}}\"}}\n\n" ++
            "{s}", .{ id, id, id, switch (ending) {
            .cut => "event: response.incomplete\n" ++
                "data: {\"type\":\"response.incomplete\",\"response\":{\"id\":\"resp_1\",\"status\":\"incomplete\",\"incomplete_details\":{\"reason\":\"max_output_tokens\"},\"usage\":{\"input_tokens\":1,\"input_tokens_details\":{\"cached_tokens\":0},\"output_tokens\":2}}}\n\n",
            .complete => "event: response.completed\n" ++
                "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_1\",\"status\":\"completed\",\"usage\":{\"input_tokens\":1,\"input_tokens_details\":{\"cached_tokens\":0},\"output_tokens\":2}}}\n\n",
        } }),
        .gemini => std.fmt.allocPrint(a, "data: {{\"candidates\":[{{\"content\":{{\"role\":\"model\",\"parts\":[{{\"functionCall\":{{\"name\":\"DefinitelyUnknown\",\"args\":{{}}}}}}]}},\"finishReason\":\"{s}\"}}],\"usageMetadata\":{{\"promptTokenCount\":1,\"candidatesTokenCount\":2}}}}\n\n", .{switch (ending) {
            .cut => "MAX_TOKENS",
            .complete => "STOP",
        }}),
    };
}

// ── driver ───────────────────────────────────────────────────────────────────

/// The `--stream-json` lines, as headless writes them to stdout.
const Lines = struct {
    allocator: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,

    fn write(ctx: *anyopaque, line: []const u8) void {
        const self: *Lines = @ptrCast(@alignCast(ctx));
        self.bytes.appendSlice(self.allocator, line) catch {};
    }

    /// The `disposition` of every `output_segment_end` line, in order.
    fn dispositions(self: *const Lines, a: std.mem.Allocator) ![]Disposition {
        var out: std.ArrayList(Disposition) = .empty;
        errdefer out.deinit(a);
        var it = std.mem.tokenizeScalar(u8, self.bytes.items, '\n');
        while (it.next()) |line| {
            const parsed = try std.json.parseFromSlice(std.json.Value, a, line, .{});
            defer parsed.deinit();
            const obj = parsed.value.object;
            if (!std.mem.eql(u8, obj.get("type").?.string, "output_segment_end")) continue;
            try out.append(a, std.meta.stringToEnum(Disposition, obj.get("disposition").?.string).?);
        }
        return out.toOwnedSlice(a);
    }

    /// The `stop_reason` of the `run_end` line.
    fn runEndStop(self: *const Lines, a: std.mem.Allocator) ![]u8 {
        var it = std.mem.tokenizeScalar(u8, self.bytes.items, '\n');
        while (it.next()) |line| {
            const parsed = try std.json.parseFromSlice(std.json.Value, a, line, .{});
            defer parsed.deinit();
            const obj = parsed.value.object;
            if (std.mem.eql(u8, obj.get("type").?.string, "run_end")) return a.dupe(u8, obj.get("stop_reason").?.string);
        }
        return error.NoRunEnd;
    }
};

const Outcome = struct {
    result: agent_loop.RunResult,
    requests: usize,
    /// Assistant text committed to the Conversation, in order (owned).
    committed: []u8,
    /// Output-segment dispositions from the `--stream-json` timeline (owned).
    timeline: []Disposition,
    /// `run_end.stop_reason` from the timeline (owned).
    run_end_stop: []u8,
    /// The headless `--json` result line, parsed.
    result_line: std.json.Parsed(std.json.Value),
    exit_code: u8,

    fn deinit(self: *Outcome, a: std.mem.Allocator) void {
        a.free(self.committed);
        a.free(self.timeline);
        a.free(self.run_end_stop);
        self.result_line.deinit();
    }

    fn field(self: *const Outcome, name: []const u8) std.json.Value {
        return self.result_line.value.object.get(name).?;
    }
};

fn runWire(a: std.mem.Allocator, wire: Wire, bodies: []const []const u8) !Outcome {
    return runWireTurns(a, wire, bodies, 4);
}

fn runWireTurns(a: std.mem.Allocator, wire: Wire, bodies: []const []const u8, max_turns: u32) !Outcome {
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

    var lines = Lines{ .allocator = a };
    defer lines.bytes.deinit(a);
    var stream = cc.repl_stream_json.StreamJsonBackend.init(a, .{ .ctx = @ptrCast(&lines), .writeFn = Lines.write });
    const be = stream.backend();
    var ledger = cc.output_semantics.Ledger.init(a);
    defer ledger.deinit();

    const result = switch (wire) {
        .anthropic => blk: {
            var client = cc.client_mod.Client.initWithBaseUrl(a, io, "key", "model", url);
            defer client.deinit();
            break :blk try runLoop(a, &conv, client.provider(), &be, &ledger, max_turns);
        },
        .openai_chat, .openai_responses => blk: {
            var client = cc.api_openai.OpenAIClient.init(a, io, "key", "model", url);
            defer client.deinit();
            if (wire == .openai_responses) client.protocol = .responses;
            break :blk try runLoop(a, &conv, client.provider(), &be, &ledger, max_turns);
        },
        .gemini => blk: {
            var client = cc.api_gemini.GeminiClient.init(a, io, "key", "gemini-2.5-flash", url);
            defer client.deinit();
            break :blk try runLoop(a, &conv, client.provider(), &be, &ledger, max_turns);
        },
    };
    stream.flush();

    var committed: std.ArrayList(u8) = .empty;
    errdefer committed.deinit(a);
    for (conv.messages.items) |m| {
        if (m.role != .assistant) continue;
        for (m.blocks) |b| switch (b) {
            .text => |t| try committed.appendSlice(a, t),
            else => {},
        };
    }

    const timeline = try lines.dispositions(a);
    errdefer a.free(timeline);
    const run_end_stop = try lines.runEndStop(a);
    errdefer a.free(run_end_stop);

    // The tail of headless `run`: the ledger decides text and text_kind.
    const projected = headless.projectRunText(&ledger);
    const usage = cc.app_module.UsageTotals{};
    const line = try headless.buildResultLine(a, projected.text orelse "", projected.kind, null, null, &.{}, result, &usage, "model");
    defer a.free(line);
    const result_line = try std.json.parseFromSlice(std.json.Value, a, std.mem.trimEnd(u8, line, "\n"), .{});

    return .{
        .result = result,
        .requests = srv.requestCount(),
        .committed = try committed.toOwnedSlice(a),
        .timeline = timeline,
        .run_end_stop = run_end_stop,
        .result_line = result_line,
        .exit_code = headless.exitCodeFor(result.stop_reason),
    };
}

fn runLoop(
    a: std.mem.Allocator,
    conv: *cc.conversation.Conversation,
    provider: cc.api_provider.Provider,
    be: *const cc.ui_backend.UiBackend,
    ledger: *cc.output_semantics.Ledger,
    max_turns: u32,
) !agent_loop.RunResult {
    var perm = cc.permission.createContext(.bypass_permissions, a);
    perm.no_interactive_prompt = true;
    const no_tools: []const cc.json_mod.ToolDefinition = &.{};
    return agent_loop.run(conv, provider, no_tools, &perm, .{
        .max_turns = max_turns,
        .max_stream_turn_retries = 0,
        .output_ledger = ledger,
    }, be, a);
}

/// The initial request and the three continuations the allowance permits.
const SEGMENTS = [_][]const u8{ "alpha-visible ", "beta ", "gamma ", "delta-still-truncated" };

// ── tests ────────────────────────────────────────────────────────────────────

/// Every response cut, with visible text and without (the no-text contrast,
/// which already ended this way before #394).
fn expectExhausted(wire: Wire) !void {
    const a = std.testing.allocator;
    for ([_]bool{ true, false }) |visible| {
        errdefer std.debug.print("wire={s} visible={}\n", .{ @tagName(wire), visible });
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        var bodies: [SEGMENTS.len][]const u8 = undefined;
        for (&bodies, SEGMENTS) |*body, text|
            body.* = try textBody(arena.allocator(), wire, if (visible) text else "", .cut);
        const expected: []const u8 = if (visible) "alpha-visible beta gamma delta-still-truncated" else "";

        var out = try runWire(a, wire, &bodies);
        defer out.deinit(a);

        // Four provider requests, every one cut, and no fifth.
        try std.testing.expectEqual(@as(usize, 4), out.requests);
        try std.testing.expectEqual(agent_loop.StopReason.max_tokens_exhausted, out.result.stop_reason);
        try std.testing.expectEqual(@as(u32, 4), out.result.turns);
        try std.testing.expectEqual(@as(u32, 3), out.result.continuations);
        // The timeline closes the cut group as partial, never final.
        try std.testing.expectEqualSlices(Disposition, &.{ .continued, .continued, .continued, .partial }, out.timeline);
        try std.testing.expectEqualStrings("max_tokens_exhausted", out.run_end_stop);
        // The result line: an explicit failure, with the visible text
        // delivered and marked partial rather than dropped.
        try std.testing.expectEqualStrings("max_tokens_exhausted", out.field("stop_reason").string);
        try std.testing.expectEqualStrings("partial", out.field("text_kind").string);
        try std.testing.expectEqualStrings(expected, out.field("text").string);
        try std.testing.expectEqual(@as(i64, 3), out.field("continuations").integer);
        try std.testing.expectEqual(@as(u8, 1), out.exit_code);
        try std.testing.expectEqualStrings(expected, out.committed);
    }
}

test "issue #394: Chat Completions finish_reason=length after the allowance ends the Run as max_tokens_exhausted" {
    try expectExhausted(.openai_chat);
}

test "issue #394: Responses response.incomplete max_output_tokens after the allowance ends the Run as max_tokens_exhausted" {
    try expectExhausted(.openai_responses);
}

test "issue #394: Anthropic stop_reason=max_tokens after the allowance ends the Run as max_tokens_exhausted" {
    try expectExhausted(.anthropic);
}

test "issue #394: Gemini finishReason=MAX_TOKENS after the allowance ends the Run as max_tokens_exhausted" {
    try expectExhausted(.gemini);
}

test "issue #394 control: a continuation that ends cleanly is still one final answer on every wire" {
    const a = std.testing.allocator;
    for (std.enums.values(Wire)) |wire| {
        errdefer std.debug.print("wire={s}\n", .{@tagName(wire)});
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        var bodies: [SEGMENTS.len][]const u8 = undefined;
        for (&bodies, SEGMENTS, 0..) |*body, text, i|
            body.* = try textBody(arena.allocator(), wire, text, if (i + 1 < SEGMENTS.len) .cut else .complete);

        var out = try runWire(a, wire, &bodies);
        defer out.deinit(a);

        try std.testing.expectEqual(@as(usize, 4), out.requests);
        try std.testing.expectEqual(agent_loop.StopReason.end_turn, out.result.stop_reason);
        try std.testing.expectEqual(@as(u32, 3), out.result.continuations);
        try std.testing.expectEqualSlices(Disposition, &.{ .continued, .continued, .continued, .final }, out.timeline);
        try std.testing.expectEqualStrings("end_turn", out.run_end_stop);
        try std.testing.expectEqualStrings("end_turn", out.field("stop_reason").string);
        try std.testing.expectEqualStrings("final", out.field("text_kind").string);
        try std.testing.expectEqualStrings("alpha-visible beta gamma delta-still-truncated", out.field("text").string);
        try std.testing.expectEqual(@as(u8, 0), out.exit_code);
    }
}

test "issue #394 control: a complete tool_use on the last cut turn still runs instead of exhausting, on every wire" {
    const a = std.testing.allocator;
    for (std.enums.values(Wire)) |wire| {
        errdefer std.debug.print("wire={s}\n", .{@tagName(wire)});
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        var bodies: [SEGMENTS.len][]const u8 = undefined;
        for (bodies[0 .. SEGMENTS.len - 1], SEGMENTS[0 .. SEGMENTS.len - 1]) |*body, text|
            body.* = try textBody(arena.allocator(), wire, text, .cut);
        bodies[SEGMENTS.len - 1] = toolBody(wire);

        var out = try runWire(a, wire, &bodies);
        defer out.deinit(a);

        // The tool call ran; the Run then met its turn cap, as before.
        try std.testing.expectEqual(@as(usize, 4), out.requests);
        try std.testing.expectEqual(agent_loop.StopReason.max_turns, out.result.stop_reason);
        try std.testing.expectEqual(@as(u32, 1), out.result.tool_calls);
        try std.testing.expectEqual(@as(u32, 3), out.result.continuations);
        try std.testing.expectEqualSlices(Disposition, &.{ .continued, .continued, .continued, .commentary }, out.timeline);
        try std.testing.expectEqualStrings("max_turns", out.field("stop_reason").string);
        try std.testing.expectEqual(@as(u8, 0), out.exit_code);
    }
}

// ── the allowance bounds consecutive cuts, not the Run ─────────────────────────
//
// A long agentic Run can hit the output-token limit on a handful of turns that
// are far apart, recovering after each continuation with a tool call. The
// allowance used to be counted over the whole Run, so the fourth cut anywhere
// ended it as max_tokens_exhausted even though no answer had been cut more
// than once in a row (WorkBuddy: 24 Clover runs, longest streak 3).

test "continuation allowance resets after the model recovers with a tool call, on every wire" {
    const a = std.testing.allocator;
    for (std.enums.values(Wire)) |wire| {
        for ([_]Ending{ .complete, .cut }) |tool_ending| {
            errdefer std.debug.print("wire={s} tool_ending={s}\n", .{ @tagName(wire), @tagName(tool_ending) });
            var arena = std.heap.ArenaAllocator.init(a);
            defer arena.deinit();
            const ar = arena.allocator();
            // cut, cut, cut, tool call (recovery), cut, cut, cut, clean end:
            // six continuations in the Run, never more than three in a row.
            const bodies = [_][]const u8{
                try textBody(ar, wire, "one ", .cut),
                try textBody(ar, wire, "two ", .cut),
                try textBody(ar, wire, "three ", .cut),
                try toolCallBody(ar, wire, "call_recover", tool_ending),
                try textBody(ar, wire, "four ", .cut),
                try textBody(ar, wire, "five ", .cut),
                try textBody(ar, wire, "six ", .cut),
                try textBody(ar, wire, "done", .complete),
            };

            var out = try runWireTurns(a, wire, &bodies, 10);
            defer out.deinit(a);

            try std.testing.expectEqual(@as(usize, bodies.len), out.requests);
            try std.testing.expectEqual(agent_loop.StopReason.end_turn, out.result.stop_reason);
            try std.testing.expectEqual(@as(u32, 1), out.result.tool_calls);
            // The run total still counts every continuation (#269).
            try std.testing.expectEqual(@as(u32, 6), out.result.continuations);
            try std.testing.expectEqual(@as(i64, 6), out.field("continuations").integer);
            try std.testing.expectEqualStrings("end_turn", out.run_end_stop);
            try std.testing.expectEqualStrings("final", out.field("text_kind").string);
            try std.testing.expectEqualStrings("four five six done", out.field("text").string);
            try std.testing.expectEqual(@as(u8, 0), out.exit_code);
        }
    }
}

test "four consecutive cuts after a recovery still exhaust the allowance, on every wire" {
    const a = std.testing.allocator;
    for (std.enums.values(Wire)) |wire| {
        errdefer std.debug.print("wire={s}\n", .{@tagName(wire)});
        var arena = std.heap.ArenaAllocator.init(a);
        defer arena.deinit();
        const ar = arena.allocator();
        const bodies = [_][]const u8{
            try textBody(ar, wire, "one ", .cut),
            try toolCallBody(ar, wire, "call_recover", .complete),
            try textBody(ar, wire, "a ", .cut),
            try textBody(ar, wire, "b ", .cut),
            try textBody(ar, wire, "c ", .cut),
            try textBody(ar, wire, "d", .cut),
        };

        var out = try runWireTurns(a, wire, &bodies, 10);
        defer out.deinit(a);

        try std.testing.expectEqual(@as(usize, bodies.len), out.requests);
        try std.testing.expectEqual(agent_loop.StopReason.max_tokens_exhausted, out.result.stop_reason);
        try std.testing.expectEqual(@as(u32, 1), out.result.tool_calls);
        try std.testing.expectEqual(@as(u32, 4), out.result.continuations);
        try std.testing.expectEqualStrings("max_tokens_exhausted", out.run_end_stop);
        try std.testing.expectEqualStrings("partial", out.field("text_kind").string);
        try std.testing.expectEqualStrings("a b c d", out.field("text").string);
        try std.testing.expectEqual(@as(u8, 1), out.exit_code);
    }
}
