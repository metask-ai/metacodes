//! L2: the server rejects a request as too large → the loop learns the wall
//! from the body, compacts once with a real summary request, retries the same
//! turn, and the next session's threshold sits inside the wall from turn one.
//!
//! Mirrors the 2026-09-22 incident on the Metask glm-5.3-flash route, where the
//! catalog-derived threshold (917,504) sat above the real wall (≈883K): the old
//! recovery trimmed two messages per rejection and never compacted.

const std = @import("std");
const cc = @import("cc");
const harness = @import("harness");

const Conversation = cc.conversation.Conversation;
const context_caps = cc.core_context_caps;

// Anthropic wording with the numbers the loop must read. The limit is deliberately
// far below the 200K catalog default so the learned cap is visibly the one in charge.
const REJECT_BODY =
    "{\"type\":\"error\",\"error\":{\"type\":\"invalid_request_error\",\"message\":\"prompt is too long: 150200 tokens > 150000 maximum\"}}";

fn textSse(comptime text: []const u8) []const u8 {
    return "data: {\"type\":\"message_start\",\"message\":{\"id\":\"m\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":7,\"output_tokens\":1}}}\n\n" ++
        "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
        "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"" ++ text ++ "\"}}\n\n" ++
        "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
        "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":4}}\n\n" ++
        "data: {\"type\":\"message_stop\"}\n\n";
}

const SUMMARY_SSE = textSse("SUMMARY_OF_THE_DROPPED_PREFIX");
const FINAL_SSE = textSse("done");

const Capture = struct {
    auto_compacts: u32 = 0,
    last_cause: []const u8 = "",
    text: std.ArrayList(u8) = .empty,
    allocator: std.mem.Allocator,
    fn emit(ctx: *anyopaque, _: cc.session_id.SessionId, ev: cc.ui_backend.CoreEvent) void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        switch (ev) {
            .auto_compact => |c| {
                self.auto_compacts += 1;
                self.last_cause = c.cause;
            },
            .text_chunk => |t| self.text.appendSlice(self.allocator, t) catch {},
            else => {},
        }
    }
    fn poll(_: *anyopaque, _: cc.session_id.SessionId) ?cc.ui_event.UiEvent {
        return null;
    }
};

test "L2 context recovery: HTTP overflow with numbers → learned cap, one summary request, same-turn retry" {
    context_caps.resetForTest();
    defer context_caps.resetForTest();
    const a = std.testing.allocator;

    const bodies = [_][]const u8{ REJECT_BODY, SUMMARY_SSE, FINAL_SSE };
    const statuses = [_][]const u8{ "HTTP/1.1 400 Bad Request", "HTTP/1.1 200 OK", "HTTP/1.1 200 OK" };
    var srv = try harness.MockServer.startHttpCassette(&bodies, &statuses);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    var io_runtime = std.Io.Threaded.init(a, .{});
    defer io_runtime.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(a, io_runtime.io(), "test-key", "test-model", url);
    defer client.deinit();

    var conv = Conversation.init(a);
    defer conv.deinit();
    // Bulk so the 5% savings gate is comfortably met after the summary is added back.
    const filler = "f" ** 60_000;
    try conv.appendText(.user, "ORIGINAL_TASK: score the workbuddy safety set " ++ filler);
    try conv.appendText(.assistant, "ASSISTANT_FILLER_ONE " ++ filler);
    try conv.appendText(.user, "follow-up " ++ filler);
    try conv.appendText(.assistant, "ASSISTANT_FILLER_TWO " ++ filler);
    try conv.appendText(.user, "current request");

    var cap = Capture{ .allocator = a };
    defer cap.text.deinit(a);
    const backend = cc.ui_backend.UiBackend{ .ctx = @ptrCast(&cap), .emit = Capture.emit, .poll = Capture.poll };
    const perm = cc.permission.createContext(.bypass_permissions, a);
    const result = try cc.agent_loop.run(
        &conv,
        client.provider(),
        &.{},
        &perm,
        .{ .max_turns = 2, .colorize = false, .auto_compact_keep_recent = 1 },
        &backend,
        a,
    );
    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, result.stop_reason);
    try std.testing.expectEqualStrings("done", cap.text.items);

    // Exactly three requests: rejected sampling, summary, retried sampling.
    try std.testing.expectEqual(@as(usize, 3), srv.requestCount());
    const summary_req = srv.requestAt(1) orelse return error.NoRequestCaptured;
    try std.testing.expect(std.mem.indexOf(u8, summary_req.body(), "Summarize this conversation") != null);
    const retry_req = srv.requestAt(2) orelse return error.NoRequestCaptured;
    const retry_body = retry_req.body();
    try std.testing.expect(std.mem.indexOf(u8, retry_body, "SUMMARY_OF_THE_DROPPED_PREFIX") != null);
    try std.testing.expect(std.mem.indexOf(u8, retry_body, "ASSISTANT_FILLER_ONE") == null);
    // The first user request travels verbatim inside the summary.
    try std.testing.expect(std.mem.indexOf(u8, retry_body, "[1] ORIGINAL_TASK: score the workbuddy safety set") != null);
    try std.testing.expect(std.mem.indexOf(u8, retry_body, "current request") != null);
    // User requests travel verbatim within the 20K-token budget (the 60K-byte
    // follow-up fits; the first request is cut to its 4K-token head); the
    // assistant bulk does not.
    try std.testing.expect(std.mem.indexOf(u8, retry_body, "[3] follow-up ") != null);
    try std.testing.expect(std.mem.indexOf(u8, retry_body, "ASSISTANT_FILLER_TWO") == null);
    // Three 60K messages left the request; one user message (60K) and a 12K head came back.
    const first_req = srv.requestAt(0) orelse return error.NoRequestCaptured;
    try std.testing.expect(retry_body.len < 100_000);
    try std.testing.expect(first_req.body().len > 200_000);

    try std.testing.expectEqual(@as(u32, 1), cap.auto_compacts);
    try std.testing.expectEqualStrings("context_window_exceeded_recovery", cap.last_cause);

    // The wall was learned for this endpoint from the server's own number.
    const learned = context_caps.lookup(url, "test-model") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u64, 150_000), learned.input_cap);
    try std.testing.expectEqual(context_caps.Source.server_message, learned.source);
    // ...and the pressure model now triggers below it instead of at the catalog's 155K.
    const p = cc.core_context_pressure.ContextPressure.fromModelWithCap(200_000, 32_000, null, 0, 150_000);
    try std.testing.expect(p.auto_compact_threshold < 150_000);
}

test "L2 context recovery: SSE overflow frame carries the numbers too" {
    context_caps.resetForTest();
    defer context_caps.resetForTest();
    const a = std.testing.allocator;

    const ERROR_SSE =
        "data: {\"type\":\"message_start\",\"message\":{\"id\":\"m\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
        "data: {\"type\":\"error\",\"error\":{\"type\":\"invalid_request_error\",\"message\":\"Requested token count exceeds the model's maximum context length of 262144 tokens. You requested a total of 262758 tokens: 198758 tokens from the input messages and 64000 tokens for the completion.\"}}\n\n";
    const bodies = [_][]const u8{ ERROR_SSE, SUMMARY_SSE, FINAL_SSE };
    var srv = try harness.MockServer.startCassette(&bodies, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    var io_runtime = std.Io.Threaded.init(a, .{});
    defer io_runtime.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(a, io_runtime.io(), "test-key", "test-model", url);
    defer client.deinit();

    var conv = Conversation.init(a);
    defer conv.deinit();
    const filler = "f" ** 60_000;
    try conv.appendText(.user, "task " ++ filler);
    try conv.appendText(.assistant, "reply " ++ filler);
    try conv.appendText(.user, "current request");

    var cap = Capture{ .allocator = a };
    defer cap.text.deinit(a);
    const backend = cc.ui_backend.UiBackend{ .ctx = @ptrCast(&cap), .emit = Capture.emit, .poll = Capture.poll };
    const perm = cc.permission.createContext(.bypass_permissions, a);
    const result = try cc.agent_loop.run(
        &conv,
        client.provider(),
        &.{},
        &perm,
        .{ .max_turns = 2, .colorize = false, .auto_compact_keep_recent = 1 },
        &backend,
        a,
    );
    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, result.stop_reason);
    try std.testing.expectEqual(@as(usize, 3), srv.requestCount());
    try std.testing.expectEqualStrings("context_window_exceeded_recovery", cap.last_cause);
    const learned = context_caps.lookup(url, "test-model") orelse return error.TestUnexpectedResult;
    // total 262144 − completion 64000 = the prompt cap.
    try std.testing.expectEqual(@as(u64, 198_144), learned.input_cap);
    try std.testing.expectEqual(context_caps.Source.server_message, learned.source);
}
