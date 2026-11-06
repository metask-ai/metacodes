//! L2 evidence for the Bedrock Converse transport (`bedrock_converse` wire):
//! the request a Bedrock route sends — path, auth header, body, thinking
//! fields — and how the AWS event stream that comes back becomes neutral
//! stream events; the signed reasoning of a tool turn reaching the next
//! request; an exception frame failing the stream; and the built-in
//! `bedrock` profile's startup route driving an App.
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

test "L2 bedrock: request shape, and an event stream becomes neutral events" {
    const a = std.testing.allocator;
    const body = try toolTurn(a);
    defer a.free(body);
    var server = try harness.MockServer.startCassette(&.{body}, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);

    var owned = try cc.api_provider_factory.makeProviderWithOptions(a, .bedrock, .{ .fixed = "brk-key" }, MODEL, origin(url), .chat_completions, .builtin(), .{});
    defer owned.deinit();
    try owned.provider().setReasoningEffort(.high);

    var handle = try owned.provider().sendStream(&HI, "be brief", null, null, null, null, "");
    defer handle.deinit();
    var thinking: std.ArrayList(u8) = .empty;
    defer thinking.deinit(a);
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(a);
    var tool_id: ?[]u8 = null;
    var tool_input: ?[]u8 = null;
    defer if (tool_id) |v| a.free(v);
    defer if (tool_input) |v| a.free(v);
    var usage: ?cc.api_stream.UsageDelta = null;
    while (try handle.next()) |event| switch (event) {
        .thinking => |bytes| {
            try thinking.appendSlice(a, bytes);
            a.free(bytes);
        },
        .text => |bytes| {
            try text.appendSlice(a, bytes);
            a.free(bytes);
        },
        .tool_use_start => |tu| {
            try std.testing.expectEqualStrings("Glob", tu.name);
            a.free(tu.name);
            tool_id = @constCast(tu.id);
            tool_input = @constCast(tu.input_json);
        },
        .usage => |u| usage = u,
        else => {},
    };
    try std.testing.expectEqualStrings("look first", thinking.items);
    try std.testing.expectEqualStrings("Listing.", text.items);
    try std.testing.expectEqualStrings("tooluse_1", tool_id.?);
    try std.testing.expectEqualStrings("{\"pattern\":\"*.txt\"}", tool_input.?);
    try std.testing.expectEqual(cc.api_stream.StopReason.tool_use, handle.stopReason());
    try std.testing.expectEqual(@as(u64, 11), usage.?.input_tokens);
    try std.testing.expectEqual(@as(u64, 5), usage.?.cache_read_input_tokens);

    const captured = server.lastRequest() orelse return error.NoRequestCaptured;
    try std.testing.expect(std.mem.startsWith(u8, requestLine(captured), "POST /model/us.anthropic.claude-sonnet-4-6/converse-stream "));
    try std.testing.expectEqualStrings("Bearer brk-key", headerValue(captured, "authorization").?);
    try std.testing.expectEqualStrings("application/vnd.amazon.eventstream", headerValue(captured, "accept").?);
    const sent = captured.body();
    try std.testing.expect(std.mem.indexOf(u8, sent, "\"messages\":[{\"role\":\"user\",\"content\":[{\"text\":\"list the text files\"}]}]") != null);
    try std.testing.expect(std.mem.indexOf(u8, sent, "\"system\":[{\"text\":\"be brief\"},{\"cachePoint\":{\"type\":\"default\"}}]") != null);
    try std.testing.expect(std.mem.indexOf(u8, sent, "\"additionalModelRequestFields\":{\"thinking\":{\"type\":\"adaptive\"},\"output_config\":{\"effort\":\"high\"}}") != null);
}

test "L2 bedrock: the signed reasoning of a tool turn goes back with the next request" {
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
    var server = try harness.MockServer.startCassette(&.{ first, second }, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);

    var owned = try cc.api_provider_factory.makeProviderWithOptions(a, .bedrock, .{ .fixed = "brk-key" }, MODEL, origin(url), .chat_completions, .builtin(), .{});
    defer owned.deinit();

    var conv = cc.conversation.Conversation.init(a);
    defer conv.deinit();
    try conv.appendText(.user, "list the text files");
    var perm = cc.permission.createContext(.bypass_permissions, a);
    perm.no_interactive_prompt = true;
    const defs = try cc.tools.toToolDefinitions(a);
    defer a.free(defs);
    var render = cc.writer_backend.WriterBackend.initNull();
    const be = render.backend();
    const result = try cc.agent_loop.run(&conv, owned.provider(), defs, &perm, .{
        .max_turns = 3,
        .cwd_abs = root,
        .home_dir = root,
        .artifact_root = root,
        .auto_compact_threshold = std.math.maxInt(usize),
    }, &be, a);
    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, result.stop_reason);
    try std.testing.expectEqual(@as(usize, 2), server.requestCount());

    const followup = (server.lastRequest() orelse return error.NoRequestCaptured).body();
    // The reasoning block, signature intact, leads the assistant tool turn.
    try std.testing.expect(std.mem.indexOf(u8, followup, "{\"role\":\"assistant\",\"content\":[{\"reasoningContent\":{\"reasoningText\":{\"text\":\"look first\",\"signature\":\"SIG-1\"}}},{\"text\":\"Listing.\"},{\"toolUse\":{\"toolUseId\":\"tooluse_1\",\"name\":\"Glob\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, followup, "{\"toolResult\":{\"toolUseId\":\"tooluse_1\"") != null);
}

test "L2 bedrock: an exception frame fails the stream instead of ending it quietly" {
    const a = std.testing.allocator;
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(a);
    const start = try es.encodeEvent(a, "messageStart", "{\"role\":\"assistant\"}");
    defer a.free(start);
    try body.appendSlice(a, start);
    const failure = try es.encode(a, &.{
        .{ ":message-type", "exception" },
        .{ ":exception-type", "throttlingException" },
        .{ ":content-type", "application/json" },
    }, "{\"message\":\"Too many tokens, please wait before trying again.\"}");
    defer a.free(failure);
    try body.appendSlice(a, failure);

    var server = try harness.MockServer.startCassette(&.{body.items}, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);
    var owned = try cc.api_provider_factory.makeProviderWithOptions(a, .bedrock, .{ .fixed = "brk-key" }, MODEL, origin(url), .chat_completions, .builtin(), .{});
    defer owned.deinit();
    var handle = try owned.provider().sendStream(&HI, null, null, null, null, null, "");
    defer handle.deinit();
    try std.testing.expectError(error.ApiError, handle.next());
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
