//! L2: `Message.origin` from the agent loop to a resumed session's replay.
//!
//! A user-role text the runtime writes itself (here the max-token
//! continuation request) is marked `host` by the real `agent_loop.run`, still
//! reaches the model as a user turn, survives the transcript, and the replay
//! of the resumed conversation leaves it out while keeping the turns around
//! it (apps/cli/src/repl/replay.zig).

const std = @import("std");
const harness = @import("harness");
const cc = @import("cc");

const Origin = cc.message.Message.Origin;
const CONTINUATION_PREFIX = "Your previous response was cut off by the token limit.";

fn textSseAlloc(allocator: std.mem.Allocator, id: []const u8, text: []const u8, stop_reason: []const u8) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "data: {{\"type\":\"message_start\",\"message\":{{\"id\":\"{s}\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{{\"input_tokens\":1,\"output_tokens\":1}}}}}}\n\n" ++
            "data: {{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{{\"type\":\"text\",\"text\":\"\"}}}}\n\n" ++
            "data: {{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{{\"type\":\"text_delta\",\"text\":\"{s}\"}}}}\n\n" ++
            "data: {{\"type\":\"content_block_stop\",\"index\":0}}\n\n" ++
            "data: {{\"type\":\"message_delta\",\"delta\":{{\"stop_reason\":\"{s}\"}},\"usage\":{{\"output_tokens\":1}}}}\n\n" ++
            "data: {{\"type\":\"message_stop\"}}\n\n",
        .{ id, text, stop_reason },
    );
}

const Silent = struct {
    fn backend(self: *Silent) cc.ui_backend.UiBackend {
        return .{ .ctx = @ptrCast(self), .emit = emit, .poll = poll };
    }
    fn emit(_: *anyopaque, _: cc.session_id.SessionId, _: cc.ui_event.CoreEvent) void {}
    fn poll(_: *anyopaque, _: cc.session_id.SessionId) ?cc.ui_event.UiEvent {
        return null;
    }
};

test "L2 message origin: a max-token continuation request is the host's, reaches the model, persists, and is not replayed" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = harness.normalizeSlashes(root_buf[0..try tmp.dir.realPath(std.testing.io, &root_buf)]);

    const cut = try textSseAlloc(a, "m1", "first half ", "max_tokens");
    defer a.free(cut);
    const rest = try textSseAlloc(a, "m2", "second half", "end_turn");
    defer a.free(rest);
    var server = try harness.MockServer.startCassette(&.{ cut, rest }, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);

    var io_runtime = @import("platform").signal.threadedIo(a, .{});
    defer io_runtime.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(a, io_runtime.io(), "key", "model", url);
    defer client.deinit();

    var conversation = cc.conversation.Conversation.init(a);
    defer conversation.deinit();
    try conversation.appendText(.user, "do the work");
    var permission = cc.permission.createContext(.bypass_permissions, a);
    permission.no_interactive_prompt = true;
    var silent = Silent{};
    const backend = silent.backend();
    const result = try cc.agent_loop.run(&conversation, client.provider(), &.{}, &permission, .{
        .max_turns = 4,
        .cwd_abs = root,
        .home_dir = root,
        .auto_compact_threshold = std.math.maxInt(usize),
    }, &backend, a);
    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, result.stop_reason);

    // The loop wrote the continuation request as the host's own turn.
    const live = conversation.messages.items;
    try std.testing.expectEqual(@as(usize, 4), live.len);
    try std.testing.expectEqual(Origin.participant, live[0].origin);
    try std.testing.expectEqual(Origin.participant, live[1].origin);
    try std.testing.expectEqual(cc.message.Role.user, live[2].role);
    try std.testing.expectEqual(Origin.host, live[2].origin);
    try std.testing.expect(std.mem.startsWith(u8, live[2].blocks[0].text, CONTINUATION_PREFIX));
    try std.testing.expectEqual(Origin.participant, live[3].origin);

    // The model still reads it as a user turn: the flag never reaches the wire.
    try std.testing.expectEqual(@as(usize, 2), server.requestCount());
    const second = server.requestAt(1).?;
    try std.testing.expect(std.mem.indexOf(u8, second.body(), CONTINUATION_PREFIX) != null);
    try std.testing.expect(std.mem.indexOf(u8, second.body(), "origin") == null);

    // It survives the transcript...
    var writer = try cc.transcript.Writer.init(a, root, .{ .path = root }, "model", cc.session_id.gen());
    defer writer.deinit();
    writer.flush(&conversation);
    var resumed = cc.conversation.Conversation.init(a);
    defer resumed.deinit();
    try cc.transcript.loadTranscript(&resumed, writer.dir, a);
    try std.testing.expectEqual(@as(usize, 4), resumed.len());
    try std.testing.expectEqual(Origin.host, resumed.messages.items[2].origin);

    // ...and the resumed session's replay shows the prompt and both halves
    // of the answer, never the host's request in the user's voice.
    const steps = try cc.repl_replay.plan(a, resumed.messages.items);
    defer a.free(steps);
    try std.testing.expectEqual(@as(usize, 3), steps.len);
    try std.testing.expectEqualStrings("do the work", steps[0].prompt[0].text);
    try std.testing.expectEqualStrings("first half ", steps[1].stream[0].text);
    try std.testing.expectEqualStrings("second half", steps[2].stream[0].text);
}
