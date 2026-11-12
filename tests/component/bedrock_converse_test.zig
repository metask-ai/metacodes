//! L2 evidence for the Bedrock Converse transport (`bedrock_converse` wire):
//! the request a Bedrock route sends — path, auth header, body, thinking
//! fields, cache points, sampling — and how the AWS event stream that comes
//! back becomes neutral stream events; the signed reasoning of a tool turn
//! reaching the next request through the conversation (a fresh client too);
//! exception frames failing the stream with their category; a frame cut by a
//! closed connection retried as an incomplete stream; and every way a Bedrock
//! route is configured reaching a real request: the built-in profile (its
//! channels, its alias, its environment variable), a `provider_catalogs`
//! entry of `"kind": "bedrock"`, a custom provider on the `bedrock_converse`
//! wire, and `model_tiers.bedrock`.
//!
//! Mock transport only: the MockServer writes AWS event-stream frames built
//! by the same encoder the decoder is tested against. No provider-backed
//! calls.

const std = @import("std");
const harness = @import("harness");
const cc = @import("cc");

const es = cc.api_aws_event_stream;
const ppaths = @import("platform").paths;

const EnvGuard = struct {
    name: [*:0]const u8,
    previous: ?[:0]u8,
    allocator: std.mem.Allocator,

    fn set(allocator: std.mem.Allocator, name: [*:0]const u8, value: [*:0]const u8) !EnvGuard {
        const previous = if (std.c.getenv(name)) |raw| try allocator.dupeZ(u8, std.mem.span(raw)) else null;
        ppaths.setEnv(name, value);
        return .{ .name = name, .previous = previous, .allocator = allocator };
    }

    fn restore(self: *EnvGuard) void {
        if (self.previous) |previous| ppaths.setEnv(self.name, previous.ptr) else ppaths.unsetEnv(self.name);
    }
};
const MODEL = "us.anthropic.claude-sonnet-4-6";

/// Frames of one Converse response, concatenated.
fn responseBytes(a: std.mem.Allocator, events: []const [2][]const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    for (events) |event| {
        const frame = try es.encodeEvent(a, event[0], event[1]);
        defer a.free(frame);
        try out.appendSlice(a, frame);
    }
    return out.toOwnedSlice(a);
}

/// Reasoning with a signature, a sentence, and one Glob call.
fn toolTurn(a: std.mem.Allocator) ![]u8 {
    return responseBytes(a, &.{
        .{ "messageStart", "{\"role\":\"assistant\"}" },
        .{ "contentBlockDelta", "{\"contentBlockIndex\":0,\"delta\":{\"reasoningContent\":{\"text\":\"look first\"}},\"p\":\"abc\"}" },
        .{ "contentBlockDelta", "{\"contentBlockIndex\":0,\"delta\":{\"reasoningContent\":{\"signature\":\"SIG-1\"}}}" },
        .{ "contentBlockStop", "{\"contentBlockIndex\":0}" },
        .{ "contentBlockDelta", "{\"contentBlockIndex\":1,\"delta\":{\"text\":\"Listing.\"}}" },
        .{ "contentBlockStop", "{\"contentBlockIndex\":1}" },
        .{ "contentBlockStart", "{\"contentBlockIndex\":2,\"start\":{\"toolUse\":{\"toolUseId\":\"tooluse_1\",\"name\":\"Glob\"}}}" },
        .{ "contentBlockDelta", "{\"contentBlockIndex\":2,\"delta\":{\"toolUse\":{\"input\":\"{\\\"pattern\\\":\"}}}" },
        .{ "contentBlockDelta", "{\"contentBlockIndex\":2,\"delta\":{\"toolUse\":{\"input\":\"\\\"*.txt\\\"}\"}}}" },
        .{ "contentBlockStop", "{\"contentBlockIndex\":2}" },
        .{ "messageStop", "{\"stopReason\":\"tool_use\"}" },
        .{ "metadata", "{\"usage\":{\"inputTokens\":11,\"outputTokens\":7,\"cacheReadInputTokens\":5,\"cacheWriteInputTokens\":2,\"totalTokens\":25},\"metrics\":{\"latencyMs\":9}}" },
    });
}

fn endTurn(a: std.mem.Allocator) ![]u8 {
    return responseBytes(a, &.{
        .{ "messageStart", "{\"role\":\"assistant\"}" },
        .{ "contentBlockDelta", "{\"contentBlockIndex\":0,\"delta\":{\"text\":\"done\"}}" },
        .{ "contentBlockStop", "{\"contentBlockIndex\":0}" },
        .{ "messageStop", "{\"stopReason\":\"end_turn\"}" },
        .{ "metadata", "{\"usage\":{\"inputTokens\":3,\"outputTokens\":1}}" },
    });
}

fn origin(url: []const u8) []const u8 {
    return url[0 .. url.len - "/v1/messages".len];
}

fn requestLine(captured: harness.CapturedRequest) []const u8 {
    const end = std.mem.indexOf(u8, captured.raw, "\r\n") orelse captured.raw.len;
    return captured.raw[0..end];
}

fn headerValue(captured: harness.CapturedRequest, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, captured.raw, "\r\n");
    while (lines.next()) |line| {
        if (line.len == 0) break;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " "), name)) continue;
        return std.mem.trim(u8, line[colon + 1 ..], " ");
    }
    return null;
}

const HI = [_]cc.types_mod.ApiMessage{
    .{ .role = .user, .content = &[_]cc.types_mod.ApiContent{.{ .text = "list the text files" }} },
};

const SIGNED_REASONING = "{\"reasoningContent\":{\"reasoningText\":{\"text\":\"look first\",\"signature\":\"SIG-1\"}}}";

/// Everything one stream produced, owned.
const Drained = struct {
    text: std.ArrayList(u8) = .empty,
    thinking: std.ArrayList(u8) = .empty,
    reasoning_items: std.ArrayList([]u8) = .empty,
    tool_id: ?[]u8 = null,
    tool_name: ?[]u8 = null,
    tool_input: ?[]u8 = null,
    usage: ?cc.api_stream.UsageDelta = null,

    fn deinit(self: *Drained, a: std.mem.Allocator) void {
        self.text.deinit(a);
        self.thinking.deinit(a);
        for (self.reasoning_items.items) |item| a.free(item);
        self.reasoning_items.deinit(a);
        if (self.tool_id) |v| a.free(v);
        if (self.tool_name) |v| a.free(v);
        if (self.tool_input) |v| a.free(v);
    }
};

fn drain(a: std.mem.Allocator, handle: cc.api_stream.StreamHandle) !Drained {
    var d: Drained = .{};
    errdefer d.deinit(a);
    while (try handle.next()) |event| switch (event) {
        .thinking => |bytes| {
            defer a.free(bytes);
            try d.thinking.appendSlice(a, bytes);
        },
        .text => |bytes| {
            defer a.free(bytes);
            try d.text.appendSlice(a, bytes);
        },
        .reasoning_item => |bytes| {
            errdefer a.free(bytes);
            try d.reasoning_items.append(a, bytes);
        },
        .tool_use_start => |tu| {
            d.tool_id = @constCast(tu.id);
            d.tool_name = @constCast(tu.name);
            d.tool_input = @constCast(tu.input_json);
        },
        .usage => |u| d.usage = u,
        else => {},
    };
    return d;
}

fn bedrockProvider(a: std.mem.Allocator, key: []const u8, model: []const u8, base: []const u8) !cc.api_provider_factory.OwnedProvider {
    return cc.api_provider_factory.makeProviderWithOptions(a, .bedrock, .{ .fixed = key }, model, base, .chat_completions, .builtin(), .{});
}

fn has(haystack: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, haystack, needle) != null;
}

test "L2 bedrock: request shape, and an event stream becomes neutral events" {
    const a = std.testing.allocator;
    const body = try toolTurn(a);
    defer a.free(body);
    var server = try harness.MockServer.startCassette(&.{body}, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);

    var owned = try bedrockProvider(a, "brk-key", MODEL, origin(url));
    defer owned.deinit();
    try owned.provider().setReasoningEffort(.high);

    var handle = try owned.provider().sendStream(&HI, "be brief", null, null, null, null, "");
    defer handle.deinit();
    var got = try drain(a, handle);
    defer got.deinit(a);
    try std.testing.expectEqualStrings("look first", got.thinking.items);
    try std.testing.expectEqualStrings("Listing.", got.text.items);
    try std.testing.expectEqualStrings("tooluse_1", got.tool_id.?);
    try std.testing.expectEqualStrings("Glob", got.tool_name.?);
    try std.testing.expectEqualStrings("{\"pattern\":\"*.txt\"}", got.tool_input.?);
    // The signed block, in its Converse request form, for the conversation to keep.
    try std.testing.expectEqual(@as(usize, 1), got.reasoning_items.items.len);
    try std.testing.expectEqualStrings(SIGNED_REASONING, got.reasoning_items.items[0]);
    try std.testing.expectEqual(cc.api_stream.StopReason.tool_use, handle.stopReason());
    try std.testing.expectEqual(@as(u64, 11), got.usage.?.input_tokens);
    try std.testing.expectEqual(@as(u64, 5), got.usage.?.cache_read_input_tokens);

    const captured = server.lastRequest() orelse return error.NoRequestCaptured;
    try std.testing.expect(std.mem.startsWith(u8, requestLine(captured), "POST /model/us.anthropic.claude-sonnet-4-6/converse-stream "));
    try std.testing.expectEqualStrings("Bearer brk-key", headerValue(captured, "authorization").?);
    try std.testing.expectEqualStrings("application/vnd.amazon.eventstream", headerValue(captured, "accept").?);
    const sent = captured.body();
    // The conversation's cache point closes the last message.
    try std.testing.expect(has(sent, "\"messages\":[{\"role\":\"user\",\"content\":[{\"text\":\"list the text files\"},{\"cachePoint\":{\"type\":\"default\"}}]}]"));
    try std.testing.expect(has(sent, "\"system\":[{\"text\":\"be brief\"},{\"cachePoint\":{\"type\":\"default\"}}]"));
    try std.testing.expect(has(sent, "\"additionalModelRequestFields\":{\"thinking\":{\"type\":\"adaptive\"},\"output_config\":{\"effort\":\"high\"}}"));
}

test "L2 bedrock: reasoning that follows text is shown but never handed on for replay" {
    const a = std.testing.allocator;
    const body = try responseBytes(a, &.{
        .{ "messageStart", "{\"role\":\"assistant\"}" },
        .{ "contentBlockDelta", "{\"contentBlockIndex\":0,\"delta\":{\"text\":\"First.\"}}" },
        .{ "contentBlockStop", "{\"contentBlockIndex\":0}" },
        .{ "contentBlockDelta", "{\"contentBlockIndex\":1,\"delta\":{\"reasoningContent\":{\"text\":\"late\"}}}" },
        .{ "contentBlockDelta", "{\"contentBlockIndex\":1,\"delta\":{\"reasoningContent\":{\"signature\":\"SIG-LATE\"}}}" },
        .{ "contentBlockStop", "{\"contentBlockIndex\":1}" },
        .{ "messageStop", "{\"stopReason\":\"end_turn\"}" },
    });
    defer a.free(body);
    var server = try harness.MockServer.startCassette(&.{body}, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);
    var owned = try bedrockProvider(a, "brk-key", MODEL, origin(url));
    defer owned.deinit();
    var handle = try owned.provider().sendStream(&HI, null, null, null, null, null, "");
    defer handle.deinit();
    var got = try drain(a, handle);
    defer got.deinit(a);
    try std.testing.expectEqualStrings("late", got.thinking.items);
    // Moving it in front of the text would reorder the model's blocks.
    try std.testing.expectEqual(@as(usize, 0), got.reasoning_items.items.len);
}

fn runLoop(a: std.mem.Allocator, conv: *cc.conversation.Conversation, provider: cc.api_provider.Provider, root: []const u8) !cc.agent_loop.RunResult {
    var perm = cc.permission.createContext(.bypass_permissions, a);
    perm.no_interactive_prompt = true;
    const defs = try cc.tools.toToolDefinitions(a);
    defer a.free(defs);
    var render = cc.writer_backend.WriterBackend.initNull();
    const be = render.backend();
    return cc.agent_loop.run(conv, provider, defs, &perm, .{
        .max_turns = 3,
        .cwd_abs = root,
        .home_dir = root,
        .artifact_root = root,
        .auto_compact_threshold = std.math.maxInt(usize),
    }, &be, a);
}

test "L2 bedrock: the signed reasoning of a tool turn travels in the conversation, to a fresh client too" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = harness.normalizeSlashes(root_buf[0..try tmp.dir.realPath(std.testing.io, &root_buf)]);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "a.txt", .data = "x" });

    const first = try toolTurn(a);
    defer a.free(first);
    const second = try endTurn(a);
    defer a.free(second);
    var server = try harness.MockServer.startCassette(&.{ first, second, second }, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);

    var conv = cc.conversation.Conversation.init(a);
    defer conv.deinit();
    try conv.appendText(.user, "list the text files");
    {
        var owned = try bedrockProvider(a, "brk-key", MODEL, origin(url));
        defer owned.deinit();
        const result = try runLoop(a, &conv, owned.provider(), root);
        try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, result.stop_reason);
    }
    try std.testing.expectEqual(@as(usize, 2), server.requestCount());
    const turn_message = "{\"role\":\"assistant\",\"content\":[" ++ SIGNED_REASONING ++ ",{\"text\":\"Listing.\"},{\"toolUse\":{\"toolUseId\":\"tooluse_1\",\"name\":\"Glob\"";
    const followup = (server.requestAt(1) orelse return error.NoRequestCaptured).body();
    // The reasoning block, signature intact, leads the assistant tool turn.
    try std.testing.expect(has(followup, turn_message));
    try std.testing.expect(has(followup, "{\"toolResult\":{\"toolUseId\":\"tooluse_1\""));

    // A new client — another process, as far as Bedrock can tell — continues
    // the same conversation: the signature comes from the conversation, the
    // same bytes at the same place, so the cached prefix still matches.
    try conv.appendText(.user, "and the markdown files?");
    {
        var owned = try bedrockProvider(a, "brk-key", MODEL, origin(url));
        defer owned.deinit();
        _ = try runLoop(a, &conv, owned.provider(), root);
    }
    try std.testing.expectEqual(@as(usize, 3), server.requestCount());
    const resumed = (server.requestAt(2) orelse return error.NoRequestCaptured).body();
    try std.testing.expect(has(resumed, turn_message));
    // Everything up to the first request's end is a byte prefix of the second.
    const prefix_end = std.mem.indexOf(u8, followup, ",{\"cachePoint\"") orelse return error.CachePointMissing;
    try std.testing.expect(std.mem.startsWith(u8, resumed, followup[0..prefix_end]));
}

fn exceptionBody(a: std.mem.Allocator, exception_type: []const u8, payload: []const u8) ![]u8 {
    var body: std.ArrayList(u8) = .empty;
    errdefer body.deinit(a);
    const start = try es.encodeEvent(a, "messageStart", "{\"role\":\"assistant\"}");
    defer a.free(start);
    try body.appendSlice(a, start);
    const failure = try es.encode(a, &.{
        .{ ":message-type", "exception" },
        .{ ":exception-type", exception_type },
        .{ ":content-type", "application/json" },
    }, payload);
    defer a.free(failure);
    try body.appendSlice(a, failure);
    return body.toOwnedSlice(a);
}

test "L2 bedrock: an exception frame fails the stream with its category and message" {
    const a = std.testing.allocator;
    const throttled = try exceptionBody(a, "throttlingException", "{\"message\":\"Too many tokens, please wait before trying again.\"}");
    defer a.free(throttled);
    const odd = try exceptionBody(a, "weird\"Exception", "{\"message\":\"quote \\\" inside\"}");
    defer a.free(odd);
    const overflow = try exceptionBody(a, "validationException", "{\"message\":\"prompt is too long: 250000 tokens > 200000 maximum\"}");
    defer a.free(overflow);
    var server = try harness.MockServer.startCassette(&.{ throttled, odd, overflow }, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);
    var owned = try bedrockProvider(a, "brk-key", MODEL, origin(url));
    defer owned.deinit();

    var capture: cc.api_model_error.Capture = .{};
    const scope = cc.api_model_error.Scope.enter(&capture);
    defer scope.exit();
    var detail: cc.api_model_error.Detail = .{};

    {
        var handle = try owned.provider().sendStream(&HI, null, null, null, null, null, "");
        defer handle.deinit();
        try std.testing.expectError(error.ApiError, handle.next());
        capture.finish(&detail);
        const view = detail.view();
        try std.testing.expectEqual(cc.api_model_error.Category.rate_limited, view.category);
        try std.testing.expectEqual(cc.api_model_error.Retry.retryable, view.retry);
        try std.testing.expectEqualStrings("throttlingException", view.type.?);
        try std.testing.expectEqualStrings("Too many tokens, please wait before trying again.", view.message);
    }
    {
        // A type with a quote in it is escaped, not spliced: the frame still parses.
        var handle = try owned.provider().sendStream(&HI, null, null, null, null, null, "");
        defer handle.deinit();
        try std.testing.expectError(error.ApiError, handle.next());
        capture.finish(&detail);
        try std.testing.expectEqualStrings("weird\"Exception", detail.view().type.?);
        try std.testing.expectEqualStrings("quote \" inside", detail.view().message);
    }
    {
        var handle = try owned.provider().sendStream(&HI, null, null, null, null, null, "");
        defer handle.deinit();
        try std.testing.expectError(error.ContextWindowExceeded, handle.next());
        try std.testing.expectEqual(@as(?u64, 250_000), handle.contextWindowNumbers().input_actual);
        capture.finish(&detail);
        try std.testing.expectEqual(cc.api_model_error.Category.context_window, detail.view().category);
    }
}

test "L2 bedrock: a frame cut by a closed connection is an incomplete stream, and the loop sends the turn again" {
    const a = std.testing.allocator;
    const whole = try endTurn(a);
    defer a.free(whole);
    // The connection closes in the middle of the first frame (messageStart).
    const cut = whole[0..20];

    {
        var server = try harness.MockServer.startCassette(&.{cut}, 0);
        defer server.stop();
        const url = try server.urlOwned(a);
        defer a.free(url);
        var owned = try bedrockProvider(a, "brk-key", MODEL, origin(url));
        defer owned.deinit();
        var handle = try owned.provider().sendStream(&HI, null, null, null, null, null, "");
        defer handle.deinit();
        try std.testing.expectError(error.StreamIncomplete, handle.next());
    }

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = harness.normalizeSlashes(root_buf[0..try tmp.dir.realPath(std.testing.io, &root_buf)]);
    var server = try harness.MockServer.startCassette(&.{ cut, whole }, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);
    var owned = try bedrockProvider(a, "brk-key", MODEL, origin(url));
    defer owned.deinit();
    var conv = cc.conversation.Conversation.init(a);
    defer conv.deinit();
    try conv.appendText(.user, "hi");
    const result = try runLoop(a, &conv, owned.provider(), root);
    // Nothing was shown before the cut: the turn goes again and completes.
    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, result.stop_reason);
    try std.testing.expectEqual(@as(usize, 2), server.requestCount());
}

test "L2 bedrock: a stream cut while a tool call's input streams is sent once; one cut after text is sent again (#461)" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = harness.normalizeSlashes(root_buf[0..try tmp.dir.realPath(std.testing.io, &root_buf)]);
    const whole = try endTurn(a);
    defer a.free(whole);
    // Text shown, then the connection ends before messageStop.
    const text_cut = try responseBytes(a, &.{
        .{ "messageStart", "{\"role\":\"assistant\"}" },
        .{ "contentBlockDelta", "{\"contentBlockIndex\":0,\"delta\":{\"text\":\"half an answer\"}}" },
    });
    defer a.free(text_cut);
    // A toolUse block whose input is still streaming when the connection ends.
    const tool_cut = try responseBytes(a, &.{
        .{ "messageStart", "{\"role\":\"assistant\"}" },
        .{ "contentBlockStart", "{\"contentBlockIndex\":0,\"start\":{\"toolUse\":{\"toolUseId\":\"tooluse_cut\",\"name\":\"Glob\"}}}" },
        .{ "contentBlockDelta", "{\"contentBlockIndex\":0,\"delta\":{\"toolUse\":{\"input\":\"{\\\"pattern\\\":\"}}}" },
    });
    defer a.free(tool_cut);

    {
        // The handle reports the started call though no event carried it.
        var server = try harness.MockServer.startCassette(&.{tool_cut}, 0);
        defer server.stop();
        const url = try server.urlOwned(a);
        defer a.free(url);
        var owned = try bedrockProvider(a, "brk-key", MODEL, origin(url));
        defer owned.deinit();
        var handle = try owned.provider().sendStream(&HI, null, null, null, null, null, "");
        defer handle.deinit();
        try std.testing.expect(!handle.toolCallStarted());
        try std.testing.expectError(error.StreamIncomplete, drain(a, handle));
        try std.testing.expect(handle.toolCallStarted());
    }
    for ([_]struct { cut: []const u8, requests: usize, stop: cc.agent_loop.StopReason }{
        .{ .cut = tool_cut, .requests = 1, .stop = .api_error },
        .{ .cut = text_cut, .requests = 2, .stop = .end_turn },
    }) |case| {
        var server = try harness.MockServer.startCassette(&.{ case.cut, whole }, 0);
        defer server.stop();
        const url = try server.urlOwned(a);
        defer a.free(url);
        var owned = try bedrockProvider(a, "brk-key", MODEL, origin(url));
        defer owned.deinit();
        var conv = cc.conversation.Conversation.init(a);
        defer conv.deinit();
        try conv.appendText(.user, "hi");
        const result = try runLoop(a, &conv, owned.provider(), root);
        try std.testing.expectEqual(case.stop, result.stop_reason);
        try std.testing.expectEqual(case.requests, server.requestCount());
    }
}

test "L2 bedrock: temperature and topP reach inferenceConfig unless the model always thinks" {
    const a = std.testing.allocator;
    const body = try endTurn(a);
    defer a.free(body);
    var server = try harness.MockServer.startCassette(&.{body}, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);

    {
        var owned = try bedrockProvider(a, "brk-key", MODEL, origin(url));
        defer owned.deinit();
        try owned.provider().setRequestOverrides(.{ .temperature = 0.25, .top_p = 0.5 });
        var handle = try owned.provider().sendStream(&HI, null, null, null, null, null, "");
        defer handle.deinit();
        var got = try drain(a, handle);
        got.deinit(a);
        const sent = (server.lastRequest() orelse return error.NoRequestCaptured).body();
        try std.testing.expect(has(sent, "\"inferenceConfig\":{\"maxTokens\":"));
        try std.testing.expect(has(sent, ",\"temperature\":0.25,\"topP\":0.5}"));
        try std.testing.expect(!has(sent, "additionalModelRequestFields"));
    }
    {
        // Opus 5.5 thinks whatever is sent; AWS: thinking takes no temperature or top_p.
        var owned = try bedrockProvider(a, "brk-key", "us.anthropic.claude-opus-5-5", origin(url));
        defer owned.deinit();
        try owned.provider().setRequestOverrides(.{ .temperature = 0.25, .top_p = 0.5, .reasoning_effort = .high });
        var handle = try owned.provider().sendStream(&HI, null, null, null, null, null, "");
        defer handle.deinit();
        var got = try drain(a, handle);
        got.deinit(a);
        const sent = (server.lastRequest() orelse return error.NoRequestCaptured).body();
        try std.testing.expect(!has(sent, "temperature"));
        try std.testing.expect(!has(sent, "topP"));
        try std.testing.expect(has(sent, "\"thinking\":{\"type\":\"adaptive\"},\"output_config\":{\"effort\":\"high\"}"));
    }
}

const Env = struct {
    pairs: []const [2][]const u8,
    fn get(ctx: *anyopaque, name: []const u8) ?[]const u8 {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        for (self.pairs) |pair| if (std.mem.eql(u8, pair[0], name)) return pair[1];
        return null;
    }
};

/// One request through a binding's transport, model, dialect, auth and
/// secret, sent to `base` instead of AWS.
fn sendThroughBinding(a: std.mem.Allocator, binding: cc.provider_runtime_binding.RuntimeBinding, base: []const u8, effort: ?cc.types_mod.ReasoningEffort) !void {
    var owned = try cc.api_provider_factory.makeProviderWithOptions(a, binding.transport, .{ .fixed = binding.secret }, binding.request_model_id, base, binding.openai_protocol, .builtin(), .{
        .auth_scheme = binding.auth_scheme,
        .dialect = binding.dialect,
    });
    defer owned.deinit();
    if (effort) |e| try owned.provider().setReasoningEffort(e);
    var handle = try owned.provider().sendStream(&HI, "be brief", null, null, null, null, "");
    defer handle.deinit();
    var got = try drain(a, handle);
    got.deinit(a);
}

test "L2 bedrock: the built-in profile by its alias, each channel's origin and model, the key from AWS_BEARER_TOKEN_BEDROCK" {
    const a = std.testing.allocator;
    const body = try endTurn(a);
    defer a.free(body);
    var server = try harness.MockServer.startCassette(&.{body}, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);

    var registry = try cc.provider_registry.ProviderRegistry.initWithBuiltins(a);
    defer registry.deinit();
    // `aws-bedrock` names the built-in profile; Tokyo is its own origin, and
    // its Sonnet goes through the Japan inference profile.
    {
        const outcome = try cc.provider_startup.resolve(a, &registry, .{ .provider = "aws-bedrock", .channel = "ap-northeast-1" });
        try std.testing.expect(outcome == .route);
        var route = outcome.route;
        defer route.deinit();
        try std.testing.expectEqual(cc.types_mod.ProviderKind.bedrock, route.transport);
        try std.testing.expectEqualStrings("https://bedrock-runtime.ap-northeast-1.amazonaws.com", route.endpoint_url);
        try std.testing.expectEqualStrings("jp.anthropic.claude-sonnet-4-6", route.request_model_id);
    }
    {
        const outcome = try cc.provider_startup.resolve(a, &registry, .{ .provider = "aws-bedrock", .channel = "eu-central-1" });
        try std.testing.expect(outcome == .route);
        var route = outcome.route;
        defer route.deinit();
        try std.testing.expectEqualStrings("https://bedrock-runtime.eu-central-1.amazonaws.com", route.endpoint_url);
        try std.testing.expectEqualStrings("eu.anthropic.claude-sonnet-4-6", route.request_model_id);
    }

    // The key comes from the profile's environment variable, and with the
    // Tokyo Opus offer the request names the global inference profile.
    var catalog = try registry.buildCatalog(a, .{ .only_provider = cc.provider_ids.Slug.lit("bedrock") });
    defer catalog.deinit();
    const offer = for (catalog.items()) |*item| {
        if (std.mem.eql(u8, item.request_model_id, "global.anthropic.claude-opus-4-6-v1")) break item;
    } else return error.TokyoOpusOfferMissing;
    var reference_buffer: [cc.provider_ids.MAX_SLUG_LEN]u8 = undefined;
    var env = Env{ .pairs = &.{.{ "AWS_BEARER_TOKEN_BEDROCK", "env-brk-key" }} };
    const binding = try cc.provider_runtime_binding.bindOffer(&registry, offer, .{ .env = .{ .ctx = @ptrCast(&env), .getFn = Env.get } }, &reference_buffer, false);
    try std.testing.expectEqualStrings("env-brk-key", binding.secret);
    try std.testing.expectEqual(cc.types_mod.ProviderKind.bedrock, binding.transport);
    try std.testing.expectEqualStrings("https://bedrock-runtime.ap-northeast-1.amazonaws.com", binding.endpoint_url);

    try sendThroughBinding(a, binding, origin(url), .high);
    const captured = server.lastRequest() orelse return error.NoRequestCaptured;
    try std.testing.expect(std.mem.startsWith(u8, requestLine(captured), "POST /model/global.anthropic.claude-opus-4-6-v1/converse-stream "));
    try std.testing.expectEqualStrings("Bearer env-brk-key", headerValue(captured, "authorization").?);
    // Opus 4.6 has no xhigh and takes adaptive thinking.
    try std.testing.expect(has(captured.body(), "\"thinking\":{\"type\":\"adaptive\"},\"output_config\":{\"effort\":\"high\"}"));
}

const CATALOG_MODELS =
    \\{"modelSummaries":[
    \\ {"modelId":"anthropic.claude-sonnet-4-6","modelArn":"arn:aws:bedrock:us-west-2::foundation-model/anthropic.claude-sonnet-4-6",
    \\  "modelName":"Claude Sonnet 4.6","providerName":"Anthropic","inputModalities":["TEXT","IMAGE"],"outputModalities":["TEXT"],
    \\  "responseStreamingSupported":true,"inferenceTypesSupported":["INFERENCE_PROFILE"],"modelLifecycle":{"status":"ACTIVE"}}
    \\]}
;

/// An application inference profile: its id names no vendor, so only the
/// catalog's `providerName` can say it is Claude.
const APP_PROFILE = "arn:aws:bedrock:us-west-2:123456789012:application-inference-profile/team-a";
const CATALOG_PROFILES =
    \\{"inferenceProfileSummaries":[
    \\ {"inferenceProfileId":"arn:aws:bedrock:us-west-2:123456789012:application-inference-profile/team-a",
    \\  "inferenceProfileName":"Team A Sonnet","status":"ACTIVE","type":"APPLICATION",
    \\  "models":[{"modelArn":"arn:aws:bedrock:us-west-2::foundation-model/anthropic.claude-sonnet-4-6"}]}
    \\]}
;

test "L2 bedrock: a provider_catalogs entry of kind bedrock becomes an offer whose requests carry the catalog's dialect" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "models.json", .data = CATALOG_MODELS });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "profiles.json", .data = CATALOG_PROFILES });
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = harness.normalizeSlashes(root_buf[0..try tmp.dir.realPath(std.testing.io, &root_buf)]);
    const config = try std.fmt.allocPrint(a,
        \\{{"provider_catalogs":{{"bedrock-team":{{"kind":"bedrock","region":"us-west-2",
        \\  "foundation_models_file":"{s}/models.json","inference_profiles_file":"{s}/profiles.json"}}}}}}
    , .{ root, root });
    defer a.free(config);

    const host = try cc.provider_host.Host.create(a);
    defer host.destroy();
    try host.ingestConfiguredCatalogs(config);
    const offer = for (host.kernel.catalogSnapshot().items()) |*item| {
        if (item.provider_id.eqlText("bedrock-team") and std.mem.eql(u8, item.request_model_id, APP_PROFILE)) break item;
    } else return error.CatalogOfferMissing;
    try std.testing.expectEqualStrings("https://bedrock-runtime.us-west-2.amazonaws.com", offer.endpoint_ref);
    try std.testing.expectEqual(cc.api_dialect.Vendor.claude, offer.dialect.model.?);

    var reference_buffer: [cc.provider_ids.MAX_SLUG_LEN]u8 = undefined;
    var env = Env{ .pairs = &.{.{ "AWS_BEARER_TOKEN_BEDROCK", "catalog-key" }} };
    const binding = try cc.provider_runtime_binding.bindOffer(&host.registry, offer, .{ .env = .{ .ctx = @ptrCast(&env), .getFn = Env.get } }, &reference_buffer, false);
    try std.testing.expectEqual(cc.types_mod.ProviderKind.bedrock, binding.transport);

    const body = try endTurn(a);
    defer a.free(body);
    var server = try harness.MockServer.startCassette(&.{body}, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);
    try sendThroughBinding(a, binding, origin(url), null);
    const captured = server.lastRequest() orelse return error.NoRequestCaptured;
    try std.testing.expect(std.mem.startsWith(u8, requestLine(captured), "POST /model/arn%3Aaws%3Abedrock%3Aus-west-2%3A123456789012%3Aapplication-inference-profile%2Fteam-a/converse-stream "));
    try std.testing.expectEqualStrings("Bearer catalog-key", headerValue(captured, "authorization").?);
    // Cache points are a Claude feature: only the catalog's declaration knows
    // this id is Claude.
    try std.testing.expect(has(captured.body(), "\"system\":[{\"text\":\"be brief\"},{\"cachePoint\":{\"type\":\"default\"}}]"));
}

test "L2 bedrock: a custom provider on the bedrock_converse wire reaches the Converse path" {
    const a = std.testing.allocator;
    const body = try endTurn(a);
    defer a.free(body);
    var server = try harness.MockServer.startCassette(&.{body}, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);

    const definition = try std.fmt.allocPrint(a,
        \\{{"custom_providers": {{"house-bedrock": {{
        \\  "display_name": "House Bedrock gateway",
        \\  "auth": {{"kind": "bearer"}},
        \\  "env_aliases": [{{"name": "HOUSE_BEDROCK_KEY", "kind": "api_key", "canonical": true}}],
        \\  "channels": [{{"id": "primary", "base_url": "{s}", "protocol": "bedrock_converse", "dialect": "claude"}}],
        \\  "models": [{{"request_model_id": "house-sonnet", "display_name": "House Sonnet"}}]}}}}}}
    , .{origin(url)});
    defer a.free(definition);
    var definitions = try cc.provider_custom.parse(a, definition);
    defer definitions.deinit();
    var registry = try cc.provider_registry.ProviderRegistry.initWithBuiltins(a);
    defer registry.deinit();
    for (definitions.profiles()) |built| try registry.register(built);

    const outcome = try cc.provider_startup.resolve(a, &registry, .{ .provider = "house-bedrock" });
    try std.testing.expect(outcome == .route);
    var route = outcome.route;
    defer route.deinit();
    try std.testing.expectEqual(cc.types_mod.ProviderKind.bedrock, route.transport);
    try std.testing.expectEqual(cc.api_dialect.Vendor.claude, route.dialect.route.?);

    var owned = try cc.api_provider_factory.makeProviderWithOptions(a, route.transport, .{ .fixed = "house-key" }, route.request_model_id, route.endpoint_url, route.openai_protocol, .builtin(), .{
        .auth_scheme = route.auth_scheme,
        .dialect = route.dialect,
    });
    defer owned.deinit();
    var handle = try owned.provider().sendStream(&HI, "be brief", null, null, null, null, "");
    defer handle.deinit();
    var got = try drain(a, handle);
    got.deinit(a);
    const captured = server.lastRequest() orelse return error.NoRequestCaptured;
    try std.testing.expect(std.mem.startsWith(u8, requestLine(captured), "POST /model/house-sonnet/converse-stream "));
    try std.testing.expectEqualStrings("Bearer house-key", headerValue(captured, "authorization").?);
    // The channel's declared dialect, not the name, decided the cache points.
    try std.testing.expect(has(captured.body(), "{\"cachePoint\":{\"type\":\"default\"}}"));
}

test "L2 bedrock: model_tiers.bedrock picks the model a subagent's request names" {
    const a = std.testing.allocator;
    const body = try endTurn(a);
    defer a.free(body);
    var server = try harness.MockServer.startCassette(&.{body}, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);

    var table = (try cc.model_tiers.parseTableFromConfig(a,
        \\{"model_tiers":{"bedrock":{"low":{"model":"us.anthropic.claude-haiku-4-5-20251001-v1:0"}}}}
    )).?;
    defer table.deinit();

    var owned = try bedrockProvider(a, "brk-key", MODEL, origin(url));
    defer owned.deinit();
    var agents = cc.agents_set.AgentSet.init(a);
    defer agents.deinit();
    const def = try cc.agents_def.parseAgentMd(a, "---\nname: quick\nmodel: haiku\n---\nAnswer briefly.", "/test/agent.md", .project);
    {
        errdefer def.deinit(a);
        try agents.agents.append(a, def);
    }
    const perm = cc.permission.createContext(.bypass_permissions, a);
    var ctx = cc.tool_context.ToolContext{
        .allocator = a,
        .provider = owned.provider(),
        .tool_defs = &.{},
        .permission_ctx = @constCast(&perm),
        .agents = &agents,
        .parent_model = MODEL,
    };
    ctx.model_tiers = table.forKind(.bedrock);
    const out = try cc.agent_tool.execute(&ctx, "{\"subagent_type\":\"quick\",\"prompt\":\"go\"}");
    a.free(out);
    const captured = server.lastRequest() orelse return error.NoRequestCaptured;
    try std.testing.expect(std.mem.startsWith(u8, requestLine(captured), "POST /model/us.anthropic.claude-haiku-4-5-20251001-v1%3A0/converse-stream "));
}

test "L2 bedrock: the built-in profile's startup route drives an App to the Converse path" {
    const a = std.testing.allocator;
    const body = try endTurn(a);
    defer a.free(body);
    var server = try harness.MockServer.startCassette(&.{body}, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);

    var registry = try cc.provider_registry.ProviderRegistry.initWithBuiltins(a);
    defer registry.deinit();
    const outcome = try cc.provider_startup.resolve(a, &registry, .{ .provider = "bedrock", .base_url = origin(url) });
    try std.testing.expect(outcome == .route);
    var route = outcome.route;
    defer route.deinit();
    try std.testing.expectEqual(cc.types_mod.ProviderKind.bedrock, route.transport);
    try std.testing.expectEqualStrings(MODEL, route.request_model_id);
    try std.testing.expectEqual(cc.api_dialect.Vendor.claude, route.dialect.bound().?);

    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const argv = [_][*:0]const u8{"metacodes"};
    var config = cc.parseArgsForTest(&argv, arena.allocator());
    config.provider_kind = route.transport;
    config.base_url = route.endpoint_url;
    config.model = route.request_model_id;
    config.model_explicit = true;
    config.auth_scheme = route.auth_scheme;
    config.dialect = route.dialect;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    config.state_root = root_buf[0..try tmp.dir.realPath(std.testing.io, &root_buf)];
    // A scratch HOME, no catalog probe, no TinyKG daemon.
    var guards: [3]EnvGuard = undefined;
    guards[0] = try EnvGuard.set(arena.allocator(), "HOME", (try arena.allocator().dupeZ(u8, config.state_root)).ptr);
    defer guards[0].restore();
    guards[1] = try EnvGuard.set(arena.allocator(), "METACODES_NO_PROBE", "1");
    defer guards[1].restore();
    guards[2] = try EnvGuard.set(arena.allocator(), "METACODES_KG_AUTOSTART", "0");
    defer guards[2].restore();
    var io_runtime = @import("platform").signal.threadedIo(a, .{});
    defer io_runtime.deinit();
    const app = try cc.app_module.App.init(a, io_runtime.io(), config, "brk-key");
    defer app.deinit();

    var handle = try app.provider().sendStream(&HI, null, null, null, null, null, "");
    defer handle.deinit();
    while (try handle.next()) |event| switch (event) {
        .text => |bytes| a.free(bytes),
        else => {},
    };
    const captured = server.lastRequest() orelse return error.NoRequestCaptured;
    try std.testing.expect(std.mem.startsWith(u8, requestLine(captured), "POST /model/us.anthropic.claude-sonnet-4-6/converse-stream "));
    try std.testing.expectEqualStrings("Bearer brk-key", headerValue(captured, "authorization").?);
    try std.testing.expectEqualStrings(MODEL, app.activeModel());
}
