//! Issue #452: same-turn re-issues a host can take back
//! (`agent_loop.Options.retractable_stream_retries`, AgentCore
//! `RunOptionsV1.stream_retry_budget`).
//!
//! A reasoning model streams thinking first, so a stream that drops almost
//! always drops after visible output, where the silent floor
//! (`SILENT_STREAM_RETRY_FLOOR`) does not apply and the Run ends. With a
//! retractable budget the loop re-issues the identical request instead, but
//! only for a connection that gave no answer (`isSilentRetryFailure`), and it
//! says so: the attempt's segment closes `discarded`, its thinking is
//! withdrawn with `thinking_discarded`, and a `retry_notice` precedes the next
//! attempt. These tests drive the real clients and the real loop against a
//! cassette server and read the events the way a host does.

const std = @import("std");
const harness = @import("harness");
const cc = @import("cc");

const agent_loop = cc.agent_loop;

const Wire = enum { anthropic, openai_chat, openai_responses, gemini };

// ── cassettes ────────────────────────────────────────────────────────────────

const ANTHROPIC_START = "data: {\"type\":\"message_start\",\"message\":{\"id\":\"m\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n";

/// The issue's reproduction: a thinking delta, then a clean end of body, with
/// no stop report.
const ANTHROPIC_THINKING_THEN_EOF = ANTHROPIC_START ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"thinking\",\"thinking\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"thinking_delta\",\"thinking\":\"private reasoning\"}}\n\n";

/// Thinking and text, then a clean end of body.
const ANTHROPIC_THINKING_TEXT_THEN_EOF = ANTHROPIC_THINKING_THEN_EOF ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"text_delta\",\"text\":\"half an answer\"}}\n\n";

/// Text, then the server's own statement of failure inside the stream.
const ANTHROPIC_TEXT_THEN_ERROR = ANTHROPIC_START ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"looks finished\"}}\n\n" ++
    "event: error\ndata: {\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"Overloaded\"}}\n\n";

const ANTHROPIC_COMPLETE = ANTHROPIC_START ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"complete answer\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":2}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

/// Every content event, then a clean end of body without the stop report.
const ANTHROPIC_TEXT_THEN_EOF = ANTHROPIC_START ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"looks finished\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n";

/// Only invisible bytes, then a clean end of body: the floor's case.
const ANTHROPIC_SILENT_EOF = ANTHROPIC_START;

const CHAT_COMPLETE =
    "data: {\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"complete answer\"},\"finish_reason\":null}]}\n\n" ++
    "data: {\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n" ++
    "data: [DONE]\n\n";
const CHAT_TEXT_THEN_EOF =
    "data: {\"choices\":[{\"index\":0,\"delta\":{\"role\":\"assistant\",\"content\":\"looks finished\"},\"finish_reason\":null}]}\n\n" ++
    "data: [DONE]\n\n";

const RESPONSES_COMPLETE =
    "event: response.output_text.delta\n" ++
    "data: {\"type\":\"response.output_text.delta\",\"item_id\":\"msg_2\",\"output_index\":0,\"delta\":\"complete answer\"}\n\n" ++
    "event: response.completed\n" ++
    "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_2\",\"status\":\"completed\",\"usage\":{\"input_tokens\":1,\"input_tokens_details\":{\"cached_tokens\":0},\"output_tokens\":2}}}\n\n";
const RESPONSES_TEXT_THEN_EOF =
    "event: response.output_text.delta\n" ++
    "data: {\"type\":\"response.output_text.delta\",\"item_id\":\"msg_1\",\"output_index\":0,\"delta\":\"looks finished\"}\n\n";

const GEMINI_COMPLETE =
    "data: {\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"text\":\"complete answer\"}]},\"finishReason\":\"STOP\"}],\"usageMetadata\":{\"promptTokenCount\":1,\"candidatesTokenCount\":2}}\n\n";
const GEMINI_TEXT_THEN_EOF =
    "data: {\"candidates\":[{\"content\":{\"role\":\"model\",\"parts\":[{\"text\":\"looks finished\"}]}}]}\n\n";

fn complete(wire: Wire) []const u8 {
    return switch (wire) {
        .anthropic => ANTHROPIC_COMPLETE,
        .openai_chat => CHAT_COMPLETE,
        .openai_responses => RESPONSES_COMPLETE,
        .gemini => GEMINI_COMPLETE,
    };
}

fn textThenEof(wire: Wire) []const u8 {
    return switch (wire) {
        .anthropic => ANTHROPIC_TEXT_THEN_EOF,
        .openai_chat => CHAT_TEXT_THEN_EOF,
        .openai_responses => RESPONSES_TEXT_THEN_EOF,
        .gemini => GEMINI_TEXT_THEN_EOF,
    };
}

// ── a host's view of the events ──────────────────────────────────────────────

/// One line per event a host would act on, in arrival order.
const EventLog = struct {
    allocator: std.mem.Allocator,
    text: std.ArrayList(u8) = .empty,

    fn deinit(self: *EventLog) void {
        self.text.deinit(self.allocator);
    }

    fn line(self: *EventLog, comptime fmt: []const u8, args: anytype) void {
        self.text.print(self.allocator, fmt ++ "\n", args) catch {};
    }

    fn emit(ctx: *anyopaque, _: cc.session_id.SessionId, ev: cc.ui_event.CoreEvent) void {
        const self: *EventLog = @ptrCast(@alignCast(ctx));
        switch (ev) {
            .output_segment_begin => |b| self.line("begin {d}", .{b.index}),
            .text_chunk => |t| self.line("text {d}", .{t.len}),
            .thinking_chunk => |t| self.line("thinking {d}", .{t.len}),
            .output_segment_end => |e| self.line("end {d} turn {d} group {d} {s} {d}", .{ e.index, e.turn, e.group, @tagName(e.disposition), e.bytes }),
            .thinking_discarded => |d| self.line("thinking_discarded {d} turn {d} group {d} {d}", .{ d.index, d.turn, d.group, d.bytes }),
            .retry_notice => |r| self.line("retry {d}/{d} after {d}", .{ r.attempt, r.max, r.delay_ms }),
            else => {},
        }
    }

    fn poll(_: *anyopaque, _: cc.session_id.SessionId) ?cc.ui_event.UiEvent {
        return null;
    }

    fn backend(self: *EventLog) cc.ui_backend.UiBackend {
        return .{ .ctx = @ptrCast(self), .emit = emit, .poll = poll };
    }

    fn count(self: *const EventLog, needle: []const u8) usize {
        return std.mem.count(u8, self.text.items, needle);
    }
};

const Outcome = struct {
    result: agent_loop.RunResult,
    requests: usize,
    /// Every request body the server received, in order.
    bodies: std.ArrayList([]u8),
    events: EventLog,
    /// The assistant text the Conversation kept.
    answer: []u8,

    fn deinit(self: *Outcome, a: std.mem.Allocator) void {
        for (self.bodies.items) |body| a.free(body);
        self.bodies.deinit(a);
        self.events.deinit();
        a.free(self.answer);
    }

    fn expectIdenticalRequests(self: *const Outcome) !void {
        try std.testing.expect(self.bodies.items.len >= 2);
        for (self.bodies.items[1..]) |body| try std.testing.expectEqualStrings(self.bodies.items[0], body);
    }
};

fn run(a: std.mem.Allocator, wire: Wire, bodies: []const []const u8, retractable: u8, max_turns: u32) !Outcome {
    var srv = try harness.MockServer.startCassette(bodies, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    var io_rt = @import("platform").signal.threadedIo(a, .{});
    defer io_rt.deinit();
    const io = io_rt.io();

    var conv = cc.conversation.Conversation.init(a);
    defer conv.deinit();
    try conv.appendText(.user, "answer me");

    var events = EventLog{ .allocator = a };
    errdefer events.deinit();
    const result = switch (wire) {
        .anthropic => blk: {
            var client = cc.client_mod.Client.initWithBaseUrl(a, io, "key", "model", url);
            defer client.deinit();
            break :blk try runLoop(a, &conv, client.provider(), retractable, max_turns, &events);
        },
        .openai_chat, .openai_responses => blk: {
            var client = cc.api_openai.OpenAIClient.init(a, io, "key", "model", url);
            defer client.deinit();
            if (wire == .openai_responses) client.protocol = .responses;
            break :blk try runLoop(a, &conv, client.provider(), retractable, max_turns, &events);
        },
        .gemini => blk: {
            var client = cc.api_gemini.GeminiClient.init(a, io, "key", "gemini-2.5-flash", url);
            defer client.deinit();
            break :blk try runLoop(a, &conv, client.provider(), retractable, max_turns, &events);
        },
    };

    var captured: std.ArrayList([]u8) = .empty;
    errdefer {
        for (captured.items) |body| a.free(body);
        captured.deinit(a);
    }
    for (0..srv.requestCount()) |index| {
        const request = srv.requestAt(index) orelse return error.MissingRequest;
        try captured.append(a, try a.dupe(u8, request.body()));
    }

    var answer: std.ArrayList(u8) = .empty;
    errdefer answer.deinit(a);
    for (conv.messages.items) |m| {
        if (m.role != .assistant) continue;
        for (m.blocks) |b| switch (b) {
            .text => |t| try answer.appendSlice(a, t),
            .thinking => |t| {
                try answer.appendSlice(a, "[thinking:");
                try answer.appendSlice(a, t);
                try answer.appendSlice(a, "]");
            },
            else => {},
        };
    }
    return .{
        .result = result,
        .requests = srv.requestCount(),
        .bodies = captured,
        .events = events,
        .answer = try answer.toOwnedSlice(a),
    };
}

fn runLoop(
    a: std.mem.Allocator,
    conv: *cc.conversation.Conversation,
    provider: cc.api_provider.Provider,
    retractable: u8,
    max_turns: u32,
    events: *EventLog,
) !agent_loop.RunResult {
    var perm = cc.permission.createContext(.bypass_permissions, a);
    perm.no_interactive_prompt = true;
    const no_tools: []const cc.json_mod.ToolDefinition = &.{};
    const be = events.backend();
    return agent_loop.run(conv, provider, no_tools, &perm, .{
        .max_turns = max_turns,
        .retractable_stream_retries = retractable,
    }, &be, a);
}

// ── tests ────────────────────────────────────────────────────────────────────

test "issue #452: thinking then a clean end of body is re-issued, and the host is told to take both back" {
    const a = std.testing.allocator;
    var out = try run(a, .anthropic, &.{ ANTHROPIC_THINKING_THEN_EOF, ANTHROPIC_COMPLETE }, 1, 4);
    defer out.deinit(a);
    try std.testing.expectEqual(agent_loop.StopReason.end_turn, out.result.stop_reason);
    try std.testing.expectEqual(@as(usize, 2), out.requests);
    // The same request went out again, byte for byte.
    try out.expectIdenticalRequests();
    try std.testing.expectEqualStrings(
        "begin 0\n" ++
            "thinking 17\n" ++
            // The attempt's segment: no text, rolled back.
            "end 0 turn 1 group 0 discarded 0\n" ++
            // Its thinking, under the same segment identity.
            "thinking_discarded 0 turn 1 group 0 17\n" ++
            // One failed stream of at most two, the next at once.
            "retry 1/2 after 0\n" ++
            "begin 1\n" ++
            "text 15\n" ++
            "end 1 turn 1 group 0 final 15\n",
        out.events.text.items,
    );
    // The discarded thinking never entered the Conversation.
    try std.testing.expectEqualStrings("complete answer", out.answer);
}

test "issue #452: thinking and text from a dropped attempt are both withdrawn" {
    const a = std.testing.allocator;
    var out = try run(a, .anthropic, &.{ ANTHROPIC_THINKING_TEXT_THEN_EOF, ANTHROPIC_COMPLETE }, 2, 4);
    defer out.deinit(a);
    try std.testing.expectEqual(agent_loop.StopReason.end_turn, out.result.stop_reason);
    try std.testing.expectEqual(@as(usize, 2), out.requests);
    try out.expectIdenticalRequests();
    try std.testing.expectEqualStrings(
        "begin 0\n" ++
            "thinking 17\n" ++
            "text 14\n" ++
            "end 0 turn 1 group 0 discarded 14\n" ++
            "thinking_discarded 0 turn 1 group 0 17\n" ++
            "retry 1/3 after 0\n" ++
            "begin 1\n" ++
            "text 15\n" ++
            "end 1 turn 1 group 0 final 15\n",
        out.events.text.items,
    );
    try std.testing.expectEqualStrings("complete answer", out.answer);
}

test "issue #452: with no retractable budget the reproduction still ends after one attempt, as before" {
    const a = std.testing.allocator;
    var out = try run(a, .anthropic, &.{ ANTHROPIC_THINKING_THEN_EOF, ANTHROPIC_COMPLETE }, 0, 4);
    defer out.deinit(a);
    try std.testing.expectEqual(agent_loop.StopReason.api_error, out.result.stop_reason);
    try std.testing.expectEqual(@as(usize, 1), out.requests);
    try std.testing.expectEqualStrings(
        "begin 0\n" ++
            "thinking 17\n" ++
            "end 0 turn 1 group 0 discarded 0\n",
        out.events.text.items,
    );
    try std.testing.expectEqualStrings("", out.answer);
}

test "issue #452: visible text cut before its stop report is re-issued on every wire" {
    const a = std.testing.allocator;
    for (std.enums.values(Wire)) |wire| {
        errdefer std.debug.print("wire={s}\n", .{@tagName(wire)});
        {
            var out = try run(a, wire, &.{ textThenEof(wire), complete(wire) }, 1, 4);
            defer out.deinit(a);
            try std.testing.expectEqual(agent_loop.StopReason.end_turn, out.result.stop_reason);
            try std.testing.expectEqual(@as(usize, 2), out.requests);
            try out.expectIdenticalRequests();
            try std.testing.expectEqualStrings(
                "begin 0\n" ++
                    "text 14\n" ++
                    "end 0 turn 1 group 0 discarded 14\n" ++
                    // No thinking was shown, so none is withdrawn.
                    "retry 1/2 after 0\n" ++
                    "begin 1\n" ++
                    "text 15\n" ++
                    "end 1 turn 1 group 0 final 15\n",
                out.events.text.items,
            );
            try std.testing.expectEqualStrings("complete answer", out.answer);
        }
        {
            // The default: unchanged, one attempt and api_error.
            var out = try run(a, wire, &.{ textThenEof(wire), complete(wire) }, 0, 4);
            defer out.deinit(a);
            try std.testing.expectEqual(agent_loop.StopReason.api_error, out.result.stop_reason);
            try std.testing.expectEqual(@as(usize, 1), out.requests);
            try std.testing.expectEqual(@as(usize, 0), out.events.count("retry "));
        }
    }
}

test "issue #452: a server-declared error after visible output is not re-issued under the budget" {
    const a = std.testing.allocator;
    var out = try run(a, .anthropic, &.{ ANTHROPIC_TEXT_THEN_ERROR, ANTHROPIC_COMPLETE }, 3, 4);
    defer out.deinit(a);
    try std.testing.expectEqual(agent_loop.StopReason.api_error, out.result.stop_reason);
    try std.testing.expectEqual(@as(usize, 1), out.requests);
    try std.testing.expectEqualStrings(
        "begin 0\n" ++
            "text 14\n" ++
            "end 0 turn 1 group 0 discarded 14\n",
        out.events.text.items,
    );
}

test "issue #452: a local decode failure after visible output is not re-issued under the budget" {
    const a = std.testing.allocator;
    // Visible text, then one data line past the 16 MiB line cap: StreamTooLong,
    // which a resend would hit again.
    const prefix = ANTHROPIC_START ++
        "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"looks finished\"}}\n\n" ++
        "data: ";
    const line_len = cc.api_stream.MAX_SSE_LINE_BYTES + 2;
    const huge = try a.alloc(u8, prefix.len + line_len + 2);
    defer a.free(huge);
    @memcpy(huge[0..prefix.len], prefix);
    @memset(huge[prefix.len..][0..line_len], 'x');
    @memcpy(huge[huge.len - 2 ..], "\n\n");

    var out = try run(a, .anthropic, &.{ huge, ANTHROPIC_COMPLETE }, 3, 4);
    defer out.deinit(a);
    try std.testing.expectEqual(agent_loop.StopReason.api_error, out.result.stop_reason);
    try std.testing.expectEqual(@as(usize, 1), out.requests);
    try std.testing.expectEqual(@as(usize, 0), out.events.count("retry "));
    try std.testing.expectEqual(@as(usize, 1), out.events.count(" discarded "));
}

test "issue #452: the budget bounds the re-issues; the last failure ends the Run" {
    const a = std.testing.allocator;
    // The cassette repeats its last body, so every attempt fails the same way.
    var out = try run(a, .anthropic, &.{ANTHROPIC_THINKING_TEXT_THEN_EOF}, 2, 4);
    defer out.deinit(a);
    try std.testing.expectEqual(agent_loop.StopReason.api_error, out.result.stop_reason);
    try std.testing.expectEqual(@as(usize, 3), out.requests);
    try out.expectIdenticalRequests();
    try std.testing.expectEqual(@as(usize, 2), out.events.count("thinking_discarded "));
    try std.testing.expectEqual(@as(usize, 1), out.events.count("retry 1/3 after 0\n"));
    try std.testing.expectEqual(@as(usize, 1), out.events.count("retry 2/3 after 0\n"));
    // The third attempt's segment still closes discarded; no notice follows it.
    try std.testing.expectEqual(@as(usize, 3), out.events.count(" discarded 14\n"));
    try std.testing.expect(std.mem.endsWith(u8, out.events.text.items, "end 2 turn 1 group 0 discarded 14\n"));
    try std.testing.expectEqualStrings("", out.answer);
}

test "issue #452: an attempt that showed nothing is still re-issued silently, and the budget raises that limit too" {
    const a = std.testing.allocator;
    {
        // Two silent failures: the floor alone allows one re-issue.
        var out = try run(a, .anthropic, &.{ ANTHROPIC_SILENT_EOF, ANTHROPIC_SILENT_EOF, ANTHROPIC_COMPLETE }, 0, 4);
        defer out.deinit(a);
        try std.testing.expectEqual(agent_loop.StopReason.api_error, out.result.stop_reason);
        try std.testing.expectEqual(@as(usize, 2), out.requests);
    }
    {
        // A budget of two covers both, and nothing shown means nothing to
        // withdraw or announce.
        var out = try run(a, .anthropic, &.{ ANTHROPIC_SILENT_EOF, ANTHROPIC_SILENT_EOF, ANTHROPIC_COMPLETE }, 2, 4);
        defer out.deinit(a);
        try std.testing.expectEqual(agent_loop.StopReason.end_turn, out.result.stop_reason);
        try std.testing.expectEqual(@as(usize, 3), out.requests);
        try out.expectIdenticalRequests();
        try std.testing.expectEqual(@as(usize, 0), out.events.count("retry "));
        try std.testing.expectEqual(@as(usize, 0), out.events.count("thinking_discarded "));
        try std.testing.expectEqualStrings("complete answer", out.answer);
    }
}

test "issue #452: the budget is the Run's, shared with the floor's re-issue" {
    const a = std.testing.allocator;
    // A silent re-issue uses the one re-issue a budget of one allows, so the
    // visible failure after it ends the Run.
    var out = try run(a, .anthropic, &.{ ANTHROPIC_SILENT_EOF, ANTHROPIC_THINKING_THEN_EOF, ANTHROPIC_COMPLETE }, 1, 4);
    defer out.deinit(a);
    try std.testing.expectEqual(agent_loop.StopReason.api_error, out.result.stop_reason);
    try std.testing.expectEqual(@as(usize, 2), out.requests);
    try std.testing.expectEqual(@as(usize, 0), out.events.count("retry "));
    try std.testing.expectEqual(@as(usize, 0), out.events.count("thinking_discarded "));
}

/// One Glob call `toolu_1` over `root`, closed; `stop` ends the stream with
/// `tool_use`, otherwise the body ends without a stop report.
fn globCallSse(a: std.mem.Allocator, root: []const u8, stop: bool) ![]u8 {
    var input: std.Io.Writer.Allocating = .init(a);
    defer input.deinit();
    try input.writer.print("{{\"pattern\":\"*.md\",\"path\":", .{});
    try std.json.Stringify.encodeJsonString(root, .{}, &input.writer);
    try input.writer.writeAll("}");
    var encoded: std.Io.Writer.Allocating = .init(a);
    defer encoded.deinit();
    try std.json.Stringify.encodeJsonString(input.written(), .{}, &encoded.writer);
    return std.fmt.allocPrint(a, "{s}" ++
        "data: {{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{{\"type\":\"tool_use\",\"id\":\"toolu_1\",\"name\":\"Glob\",\"input\":{{}}}}}}\n\n" ++
        "data: {{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{{\"type\":\"input_json_delta\",\"partial_json\":{s}}}}}\n\n" ++
        "data: {{\"type\":\"content_block_stop\",\"index\":0}}\n\n" ++
        "{s}", .{
        ANTHROPIC_START,
        encoded.written(),
        if (stop)
            "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":2}}\n\ndata: {\"type\":\"message_stop\"}\n\n"
        else
            "",
    });
}

test "issue #452: a re-issued attempt that repeats a withdrawn tool call's id runs the call, not the withdrawn prefetch" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = harness.normalizeSlashes(root_buf[0..try tmp.dir.realPath(std.testing.io, &root_buf)]);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "marker-452.md", .data = "x" });

    // The withdrawn attempt's Glob is prefetched while it streams; the
    // re-issued attempt names the same call id, as a gateway with sequential
    // ids does.
    const cut = try globCallSse(a, root, false);
    defer a.free(cut);
    const again = try globCallSse(a, root, true);
    defer a.free(again);
    var srv = try harness.MockServer.startCassette(&.{ cut, again, ANTHROPIC_COMPLETE }, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    var io_rt = @import("platform").signal.threadedIo(a, .{});
    defer io_rt.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(a, io_rt.io(), "key", "model", url);
    defer client.deinit();
    var conv = cc.conversation.Conversation.init(a);
    defer conv.deinit();
    try conv.appendText(.user, "list the markdown files");
    var perm = cc.permission.createContext(.bypass_permissions, a);
    perm.no_interactive_prompt = true;
    const defs = try cc.tools.toToolDefinitions(a);
    defer a.free(defs);
    var events = EventLog{ .allocator = a };
    defer events.deinit();
    const be = events.backend();
    const result = try agent_loop.run(&conv, client.provider(), defs, &perm, .{
        .max_turns = 4,
        .retractable_stream_retries = 1,
        .cwd_abs = root,
        .home_dir = root,
        .auto_compact_threshold = std.math.maxInt(usize),
    }, &be, a);

    try std.testing.expectEqual(agent_loop.StopReason.end_turn, result.stop_reason);
    try std.testing.expectEqual(@as(usize, 3), srv.requestCount());
    try std.testing.expectEqual(@as(usize, 1), events.count("retry 1/2 after 0\n"));
    try std.testing.expectEqual(@as(u32, 1), result.tool_calls);
    // The call's real result reached the model.
    const third = (srv.requestAt(2) orelse return error.MissingRequest).body();
    try std.testing.expect(std.mem.indexOf(u8, third, "\"tool_use_id\":\"toolu_1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, third, "marker-452.md") != null);
}
