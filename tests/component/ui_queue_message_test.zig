//! L2: `UiEvent` reaches the real execution path (#115). A `queue_message`
//! returned by `UiBackend.poll` at a turn boundary is appended to the
//! Conversation as a user message and rides the very next provider request of
//! the same Run; an `interrupt` returned there ends the Run as aborted before
//! another request is sent; a blank message is dropped; the boundary right
//! after a max_tokens truncation is not polled at all (the continuation must
//! stay one answer). Nothing here involves a provider model: the evidence is
//! the captured request bytes and the backend's poll count.

const std = @import("std");
const harness = @import("harness");
const cc = @import("cc");

const UiEvent = cc.ui_event.UiEvent;
const CoreEvent = cc.ui_event.CoreEvent;
const SessionId = cc.session_id.SessionId;

fn encodeJson(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var escaped: std.Io.Writer.Allocating = .init(allocator);
    defer escaped.deinit();
    try std.json.Stringify.encodeJsonString(text, .{}, &escaped.writer);
    return escaped.toOwnedSlice();
}

/// Visible text, then a Glob call: the model is mid-task after this stream.
fn textThenToolSse(allocator: std.mem.Allocator, id: []const u8, text: []const u8, tool_input: []const u8) ![]u8 {
    const text_encoded = try encodeJson(allocator, text);
    defer allocator.free(text_encoded);
    const input_encoded = try encodeJson(allocator, tool_input);
    defer allocator.free(input_encoded);
    return std.fmt.allocPrint(
        allocator,
        "data: {{\"type\":\"message_start\",\"message\":{{\"id\":\"{s}\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{{\"input_tokens\":1,\"output_tokens\":1}}}}}}\n\n" ++
            "data: {{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{{\"type\":\"text\",\"text\":\"\"}}}}\n\n" ++
            "data: {{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{{\"type\":\"text_delta\",\"text\":{s}}}}}\n\n" ++
            "data: {{\"type\":\"content_block_stop\",\"index\":0}}\n\n" ++
            "data: {{\"type\":\"content_block_start\",\"index\":1,\"content_block\":{{\"type\":\"tool_use\",\"id\":\"{s}_tu\",\"name\":\"Glob\",\"input\":{{}}}}}}\n\n" ++
            "data: {{\"type\":\"content_block_delta\",\"index\":1,\"delta\":{{\"type\":\"input_json_delta\",\"partial_json\":{s}}}}}\n\n" ++
            "data: {{\"type\":\"content_block_stop\",\"index\":1}}\n\n" ++
            "data: {{\"type\":\"message_delta\",\"delta\":{{\"stop_reason\":\"tool_use\"}},\"usage\":{{\"output_tokens\":1}}}}\n\n" ++
            "data: {{\"type\":\"message_stop\"}}\n\n",
        .{ id, text_encoded, id, input_encoded },
    );
}

/// Visible text cut off by the output token limit: the loop appends its
/// continuation prompt and sends the next request of the same Run.
fn truncatedSse(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const text_encoded = try encodeJson(allocator, text);
    defer allocator.free(text_encoded);
    return std.fmt.allocPrint(
        allocator,
        "data: {{\"type\":\"message_start\",\"message\":{{\"id\":\"cut\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{{\"input_tokens\":1,\"output_tokens\":1}}}}}}\n\n" ++
            "data: {{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{{\"type\":\"text\",\"text\":\"\"}}}}\n\n" ++
            "data: {{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{{\"type\":\"text_delta\",\"text\":{s}}}}}\n\n" ++
            "data: {{\"type\":\"content_block_stop\",\"index\":0}}\n\n" ++
            "data: {{\"type\":\"message_delta\",\"delta\":{{\"stop_reason\":\"max_tokens\"}},\"usage\":{{\"output_tokens\":1}}}}\n\n" ++
            "data: {{\"type\":\"message_stop\"}}\n\n",
        .{text_encoded},
    );
}

fn finalSse(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const text_encoded = try encodeJson(allocator, text);
    defer allocator.free(text_encoded);
    return std.fmt.allocPrint(
        allocator,
        "data: {{\"type\":\"message_start\",\"message\":{{\"id\":\"final\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{{\"input_tokens\":1,\"output_tokens\":1}}}}}}\n\n" ++
            "data: {{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{{\"type\":\"text\",\"text\":\"\"}}}}\n\n" ++
            "data: {{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{{\"type\":\"text_delta\",\"text\":{s}}}}}\n\n" ++
            "data: {{\"type\":\"content_block_stop\",\"index\":0}}\n\n" ++
            "data: {{\"type\":\"message_delta\",\"delta\":{{\"stop_reason\":\"end_turn\"}},\"usage\":{{\"output_tokens\":1}}}}\n\n" ++
            "data: {{\"type\":\"message_stop\"}}\n\n",
        .{text_encoded},
    );
}

/// A UI backend the way an out-of-process frontend would behave: it hands the
/// loop a queued user message (or an interrupt) once the first provider stream
/// has ended, i.e. while the Run is still active and about to send its next
/// request. Ownership contract: the message is allocated with the Run's
/// allocator and freed by the loop (`std.testing.allocator` would report a leak
/// or a double free otherwise).
const QueueBackend = struct {
    allocator: std.mem.Allocator,
    message: ?[]const u8 = null,
    interrupt: bool = false,
    deliver_after_streams: u32 = 1,
    streams_done: u32 = 0,
    delivered: bool = false,
    polls: u32 = 0,

    fn emit(ctx: *anyopaque, _: SessionId, ev: CoreEvent) void {
        const self: *QueueBackend = @ptrCast(@alignCast(ctx));
        if (ev == .stream_done) self.streams_done += 1;
    }

    fn poll(ctx: *anyopaque, _: SessionId) ?UiEvent {
        const self: *QueueBackend = @ptrCast(@alignCast(ctx));
        self.polls += 1;
        if (self.streams_done < self.deliver_after_streams or self.delivered) return null;
        self.delivered = true;
        if (self.interrupt) return .{ .interrupt = .user_interrupt };
        const text = self.message orelse return null;
        const owned = self.allocator.dupe(u8, text) catch return null;
        return .{ .queue_message = owned };
    }

    fn backend(self: *QueueBackend) cc.ui_backend.UiBackend {
        return .{ .ctx = @ptrCast(self), .emit = emit, .poll = poll };
    }
};

const Outcome = struct {
    result: cc.agent_loop.RunResult,
    requests: usize,
    polls: u32,
    first_body: []u8,
    second_body: ?[]u8,

    fn deinit(self: *Outcome, allocator: std.mem.Allocator) void {
        allocator.free(self.first_body);
        if (self.second_body) |b| allocator.free(b);
    }
};

fn runWith(allocator: std.mem.Allocator, root: []const u8, ui: *QueueBackend, responses: []const []const u8) !Outcome {
    var server = try harness.MockServer.startCassette(responses, 0);
    defer server.stop();
    const url = try server.urlOwned(allocator);
    defer allocator.free(url);
    var io_runtime = std.Io.Threaded.init(allocator, .{});
    defer io_runtime.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(allocator, io_runtime.io(), "key", "model", url);
    defer client.deinit();
    var conversation = cc.conversation.Conversation.init(allocator);
    defer conversation.deinit();
    try conversation.appendText(.user, "look around");
    var permission = cc.permission.createContext(.bypass_permissions, allocator);
    permission.no_interactive_prompt = true;
    const defs = try cc.tools.toToolDefinitions(allocator);
    defer allocator.free(defs);
    const backend = ui.backend();
    const result = try cc.agent_loop.run(
        &conversation,
        client.provider(),
        defs,
        &permission,
        .{
            .max_turns = 6,
            .system_prompt = "STABLE-PREFIX",
            .cwd_abs = root,
            .home_dir = root,
            .auto_compact_threshold = std.math.maxInt(usize),
        },
        &backend,
        allocator,
    );
    const first = server.requestAt(0) orelse return error.TestUnexpectedResult;
    const first_body = try allocator.dupe(u8, first.body());
    errdefer allocator.free(first_body);
    const second_body: ?[]u8 = if (server.requestAt(1)) |second| try allocator.dupe(u8, second.body()) else null;
    return .{ .result = result, .requests = server.requestCount(), .polls = ui.polls, .first_body = first_body, .second_body = second_body };
}

fn tmpRoot(tmp: *std.testing.TmpDir, buf: *[std.fs.max_path_bytes]u8) ![]const u8 {
    return harness.normalizeSlashes(buf[0..try tmp.dir.realPath(std.testing.io, buf)]);
}

fn globInput(allocator: std.mem.Allocator, root: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{{\"pattern\":\"*.none\",\"path\":\"{s}\"}}", .{root});
}

test "L2 queue_message: a message polled at the turn boundary rides the next provider request of the same Run" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(&tmp, &root_buf);
    const input = try globInput(a, root);
    defer a.free(input);
    const turn1 = try textThenToolSse(a, "m1", "Looking.", input);
    defer a.free(turn1);
    const turn2 = try finalSse(a, "Done, and I also checked the docs.");
    defer a.free(turn2);

    const steer = "Also check the docs directory before you answer.";
    var ui = QueueBackend{ .allocator = a, .message = steer };
    var outcome = try runWith(a, root, &ui, &.{ turn1, turn2 });
    defer outcome.deinit(a);

    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, outcome.result.stop_reason);
    try std.testing.expectEqual(@as(usize, 2), outcome.requests);
    try std.testing.expect(outcome.polls > 0);
    // Not in the first request (it was queued during the first stream) …
    try std.testing.expect(std.mem.indexOf(u8, outcome.first_body, steer) == null);
    // … but in the second, after the tool_result and before the model's next turn:
    // the queued instruction reached the provider inside the active Run.
    const second = outcome.second_body orelse return error.TestUnexpectedResult;
    const steer_at = std.mem.indexOf(u8, second, steer) orelse return error.TestUnexpectedResult;
    const tool_result_at = std.mem.indexOf(u8, second, "tool_result") orelse return error.TestUnexpectedResult;
    try std.testing.expect(tool_result_at < steer_at);
    try std.testing.expect(std.mem.indexOf(u8, second, "\"role\":\"user\"") != null);
}

test "L2 queue_message: an interrupt polled at the turn boundary ends the Run as aborted before the next request" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(&tmp, &root_buf);
    const input = try globInput(a, root);
    defer a.free(input);
    const turn1 = try textThenToolSse(a, "m1", "Looking.", input);
    defer a.free(turn1);
    const turn2 = try finalSse(a, "never sent");
    defer a.free(turn2);

    var ui = QueueBackend{ .allocator = a, .interrupt = true };
    var outcome = try runWith(a, root, &ui, &.{ turn1, turn2 });
    defer outcome.deinit(a);

    try std.testing.expectEqual(cc.agent_loop.StopReason.aborted, outcome.result.stop_reason);
    try std.testing.expectEqual(@as(usize, 1), outcome.requests);
    try std.testing.expect(outcome.second_body == null);
}

test "L2 queue_message: a blank message is dropped and changes nothing" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(&tmp, &root_buf);
    const input = try globInput(a, root);
    defer a.free(input);
    const turn1 = try textThenToolSse(a, "m1", "Looking.", input);
    defer a.free(turn1);
    const turn2 = try finalSse(a, "done");
    defer a.free(turn2);

    var ui = QueueBackend{ .allocator = a, .message = " \n\t " };
    var outcome = try runWith(a, root, &ui, &.{ turn1, turn2 });
    defer outcome.deinit(a);

    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, outcome.result.stop_reason);
    try std.testing.expectEqual(@as(usize, 2), outcome.requests);
    // The backend really handed the whitespace over at the boundary (otherwise
    // the count below would hold for the wrong reason).
    try std.testing.expect(ui.delivered);
    try std.testing.expect(outcome.polls > 0);
    const second = outcome.second_body orelse return error.TestUnexpectedResult;
    // Exactly the original prompt and the tool_result carry role user; no third
    // user record was appended for whitespace.
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, second, "\"role\":\"user\""));
}

test "L2 queue_message: the boundary after a max_tokens truncation is not polled, the continuation stays one answer" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(&tmp, &root_buf);
    const cut = try truncatedSse(a, "The answer is the first half of");
    defer a.free(cut);
    const rest = try finalSse(a, " a long explanation.");
    defer a.free(rest);

    const steer = "Actually, switch to the other topic.";
    var ui = QueueBackend{ .allocator = a, .message = steer };
    var outcome = try runWith(a, root, &ui, &.{ cut, rest });
    defer outcome.deinit(a);

    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, outcome.result.stop_reason);
    try std.testing.expectEqual(@as(usize, 2), outcome.requests);
    // Polled once, before the first request; the continuation boundary was
    // skipped, so the queued steer never entered this Run …
    try std.testing.expectEqual(@as(u32, 1), outcome.polls);
    try std.testing.expect(!ui.delivered);
    const second = outcome.second_body orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, second, steer) == null);
    // … and the second request carries the continuation prompt right after the
    // truncated assistant text, as before #115.
    try std.testing.expect(std.mem.indexOf(u8, second, "Continue exactly where you left off") != null);
}
