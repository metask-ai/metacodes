const std = @import("std");
const cc = @import("cc");
const harness = @import("harness");

const Conversation = cc.conversation.Conversation;
const context_caps = cc.core_context_caps;

const METASK_GATEWAY_MODELS_2026_11_23 =
    \\{"object":"list","has_more":false,"data":[
    \\{"id":"kimi-k3.1-pro","type":"model","max_input_tokens":1048576,"max_tokens":1048576,"capabilities":{"context_management":{"supported":true,"compact_20260112":{"supported":true},"clear_thinking_20251015":{"supported":false}},"effort":{"low":{"supported":false},"max":{"supported":false},"high":{"supported":false},"medium":{"supported":false},"supported":false},"endpoints":{"messages":{"supported":true},"chat_completions":{"supported":true}},"limits":{"context_window":1048576,"max_input_tokens":1048576,"max_output_tokens":1048576},"reasoning":{"disable":{"supported":true},"supported":true,"translated":true},"thinking":{"types":{"enabled":{"supported":true},"adaptive":{"supported":false}},"supported":true}}},
    \\{"id":"DeepSeek-V4.1-Flash-1017","type":"model","max_input_tokens":1000000,"max_tokens":384000,"capabilities":{"context_management":{"supported":true,"compact_20260112":{"supported":true},"clear_thinking_20251015":{"supported":false}},"effort":{"low":{"supported":false},"max":{"supported":false},"high":{"supported":false},"medium":{"supported":false},"supported":false},"endpoints":{"messages":{"supported":true},"chat_completions":{"supported":true}},"limits":{"context_window":1000000,"max_input_tokens":1000000,"max_output_tokens":384000},"reasoning":{"disable":{"supported":true},"supported":true,"translated":true},"thinking":{"types":{"enabled":{"supported":true},"adaptive":{"supported":false}},"supported":true}}},
    \\{"id":"glm-5.3","type":"model","max_input_tokens":1000000,"max_tokens":131072,"capabilities":{"context_management":{"supported":true,"compact_20260112":{"supported":true},"clear_thinking_20251015":{"supported":false}},"effort":{"low":{"supported":false},"max":{"supported":false},"high":{"supported":false},"medium":{"supported":false},"supported":false},"endpoints":{"messages":{"supported":true},"chat_completions":{"supported":true}},"limits":{"context_window":1000000,"max_input_tokens":1000000,"max_output_tokens":131072},"reasoning":{"disable":{"supported":false},"efforts":["low","medium","high","max"],"supported":true,"translated":true},"thinking":{"types":{"enabled":{"supported":true},"adaptive":{"supported":false}},"supported":true}}}
    \\]}
;

const END_TURN_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"m\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":7,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"OK\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const Capture = struct {
    text: std.ArrayList(u8) = .empty,
    allocator: std.mem.Allocator,
    fn emit(ctx: *anyopaque, _: cc.session_id.SessionId, ev: cc.ui_backend.CoreEvent) void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        switch (ev) {
            .text_chunk => |t| self.text.appendSlice(self.allocator, t) catch {},
            else => {},
        }
    }
    fn poll(_: *anyopaque, _: cc.session_id.SessionId) ?cc.ui_event.UiEvent {
        return null;
    }
};

fn requestLine(captured: harness.CapturedRequest) []const u8 {
    const end = std.mem.indexOf(u8, captured.raw, "\r\n") orelse captured.raw.len;
    return captured.raw[0..end];
}

const Turn = struct {
    stop_reason: cc.agent_loop.StopReason,
    text: []u8,
};

fn runOneTurn(a: std.mem.Allocator, client: *cc.client_mod.Client) !Turn {
    var conv = Conversation.init(a);
    defer conv.deinit();
    try conv.appendText(.user, "hi");
    var cap = Capture{ .allocator = a };
    errdefer cap.text.deinit(a);
    const backend = cc.ui_backend.UiBackend{ .ctx = @ptrCast(&cap), .emit = Capture.emit, .poll = Capture.poll };
    const perm = cc.permission.createContext(.bypass_permissions, a);
    const result = try cc.agent_loop.run(&conv, client.provider(), &.{}, &perm, .{ .max_turns = 1, .colorize = false }, &backend, a);
    return .{ .stop_reason = result.stop_reason, .text = try cap.text.toOwnedSlice(a) };
}

const LISTING_THEN_ONE_TURN = [_][]const u8{ METASK_GATEWAY_MODELS_2026_11_23, END_TURN_SSE };
const LISTING_THEN_THREE_TURNS = [_][]const u8{ METASK_GATEWAY_MODELS_2026_11_23, END_TURN_SSE, END_TURN_SSE, END_TURN_SSE };

fn loadGatewayCatalog(srv: *harness.MockServer, client: *cc.client_mod.Client) !void {
    client.probeModels();
    try std.testing.expectEqualStrings("GET /v1/models HTTP/1.1", requestLine(srv.requestAt(0).?));
    try std.testing.expectEqual(@as(usize, 3), client.catalog.entries.items.len);
}

test "L2 a model whose output limit is its whole window: the turn is sent, asking for half the window" {
    context_caps.resetForTest();
    defer context_caps.resetForTest();
    const a = std.testing.allocator;
    var srv = try harness.MockServer.startCassette(&LISTING_THEN_ONE_TURN, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);
    var io_runtime = @import("platform").signal.threadedIo(a, .{});
    defer io_runtime.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(a, io_runtime.io(), "test-key", "kimi-k3.1-pro", url);
    defer client.deinit();
    try loadGatewayCatalog(srv, &client);
    try std.testing.expectEqual(@as(?u32, 1_048_576), client.catalog.entries.items[0].max_tokens);

    const turn = try runOneTurn(a, &client);
    defer a.free(turn.text);
    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, turn.stop_reason);
    try std.testing.expectEqualStrings("OK", turn.text);

    try std.testing.expectEqual(@as(usize, 2), srv.requestCount());
    const sent = srv.requestAt(1).?;
    try std.testing.expect(std.mem.startsWith(u8, requestLine(sent), "POST /v1/messages "));
    try std.testing.expectEqualStrings("\"kimi-k3.1-pro\"", sent.jsonField("model").?);
    try std.testing.expectEqualStrings("524288", sent.jsonField("max_tokens").?);
}

test "L2 a model whose output limit fits in half its window is asked for that limit, as before" {
    context_caps.resetForTest();
    defer context_caps.resetForTest();
    const a = std.testing.allocator;
    var srv = try harness.MockServer.startCassette(&LISTING_THEN_ONE_TURN, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);
    var io_runtime = @import("platform").signal.threadedIo(a, .{});
    defer io_runtime.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(a, io_runtime.io(), "test-key", "DeepSeek-V4.1-Flash-1017", url);
    defer client.deinit();
    try loadGatewayCatalog(srv, &client);

    const turn = try runOneTurn(a, &client);
    defer a.free(turn.text);
    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, turn.stop_reason);
    try std.testing.expectEqualStrings("384000", srv.requestAt(1).?.jsonField("max_tokens").?);
}
