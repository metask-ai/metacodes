//! L2: the progress-update obligation (#114). A run whose tool rounds stay
//! silent — no visible assistant text before the tool calls, round after round
//! — receives a bounded nudge at the turn boundary asking for a short progress
//! note; a narrated round resets the stretch; a short task never sees it; the
//! reply is ordinary commentary and the final answer is untouched. Every
//! assertion is on the real provider request bytes and the real
//! output-segment protocol, through the shared agent loop, with no provider
//! model involved.

const std = @import("std");
const harness = @import("harness");
const cc = @import("cc");

const progress = cc.progress_updates;
const Disposition = cc.output_semantics.Disposition;

fn encodeJson(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var escaped: std.Io.Writer.Allocating = .init(allocator);
    defer escaped.deinit();
    try std.json.Stringify.encodeJsonString(text, .{}, &escaped.writer);
    return escaped.toOwnedSlice();
}

/// A tool round with no visible text: the shape that leaves the user in the dark.
fn silentToolSse(allocator: std.mem.Allocator, id: []const u8, tool_input: []const u8) ![]u8 {
    const input_encoded = try encodeJson(allocator, tool_input);
    defer allocator.free(input_encoded);
    return std.fmt.allocPrint(
        allocator,
        "data: {{\"type\":\"message_start\",\"message\":{{\"id\":\"{s}\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{{\"input_tokens\":1,\"output_tokens\":1}}}}}}\n\n" ++
            "data: {{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{{\"type\":\"tool_use\",\"id\":\"{s}_tu\",\"name\":\"Glob\",\"input\":{{}}}}}}\n\n" ++
            "data: {{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{{\"type\":\"input_json_delta\",\"partial_json\":{s}}}}}\n\n" ++
            "data: {{\"type\":\"content_block_stop\",\"index\":0}}\n\n" ++
            "data: {{\"type\":\"message_delta\",\"delta\":{{\"stop_reason\":\"tool_use\"}},\"usage\":{{\"output_tokens\":1}}}}\n\n" ++
            "data: {{\"type\":\"message_stop\"}}\n\n",
        .{ id, id, input_encoded },
    );
}

/// A narrated tool round: visible text, then the tool call.
fn narratedToolSse(allocator: std.mem.Allocator, id: []const u8, text: []const u8, tool_input: []const u8) ![]u8 {
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

/// Records the closed visible segments exactly as a streaming consumer would.
const SegmentCapture = struct {
    allocator: std.mem.Allocator,
    buffer: std.ArrayList(u8) = .empty,
    closed: std.ArrayList(Closed) = .empty,

    const Closed = struct { turn: u32, disposition: Disposition, text: []u8 };

    fn deinit(self: *SegmentCapture) void {
        self.buffer.deinit(self.allocator);
        for (self.closed.items) |c| self.allocator.free(c.text);
        self.closed.deinit(self.allocator);
    }

    fn emit(ctx: *anyopaque, _: cc.session_id.SessionId, ev: cc.ui_event.CoreEvent) void {
        const self: *SegmentCapture = @ptrCast(@alignCast(ctx));
        switch (ev) {
            .output_segment_begin => self.buffer.clearRetainingCapacity(),
            .text_chunk => |t| self.buffer.appendSlice(self.allocator, t) catch {},
            .output_segment_end => |e| {
                const text = self.allocator.dupe(u8, self.buffer.items) catch return;
                self.closed.append(self.allocator, .{ .turn = e.turn, .disposition = e.disposition, .text = text }) catch self.allocator.free(text);
                self.buffer.clearRetainingCapacity();
            },
            else => {},
        }
    }

    fn poll(_: *anyopaque, _: cc.session_id.SessionId) ?cc.ui_event.UiEvent {
        return null;
    }

    fn backend(self: *SegmentCapture) cc.ui_backend.UiBackend {
        return .{ .ctx = @ptrCast(self), .emit = emit, .poll = poll };
    }
};

const MAX_REQUESTS = 12;

const Scenario = struct {
    requests: usize,
    /// `MARKER` occurrences per request body (0-based). An injected nudge stays
    /// in the conversation, so every later request carries it too: the count
    /// on request N is the number of nudges injected before request N.
    markers: [MAX_REQUESTS]usize = [_]usize{0} ** MAX_REQUESTS,
    capture: SegmentCapture,
    ledger: cc.output_semantics.Ledger,
    result: cc.agent_loop.RunResult,

    fn deinit(self: *Scenario) void {
        self.capture.deinit();
        self.ledger.deinit();
    }

    fn expectMarkers(self: *const Scenario, expected: []const usize) !void {
        try std.testing.expectEqual(expected.len, self.requests);
        for (expected, 0..) |count, index| try std.testing.expectEqual(count, self.markers[index]);
    }
};

const Config = struct {
    enabled: bool = true,
    silent_rounds: u32 = progress.DEFAULT_SILENT_ROUNDS,
};

fn runScenario(allocator: std.mem.Allocator, root: []const u8, responses: []const []const u8, config: Config) !Scenario {
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
    try conversation.appendText(.user, "survey the repository and report");
    var permission = cc.permission.createContext(.bypass_permissions, allocator);
    permission.no_interactive_prompt = true;
    const defs = try cc.tools.toToolDefinitions(allocator);
    defer allocator.free(defs);

    var capture = SegmentCapture{ .allocator = allocator };
    errdefer capture.deinit();
    var ledger = cc.output_semantics.Ledger.init(allocator);
    errdefer ledger.deinit();
    const backend = capture.backend();
    const result = try cc.agent_loop.run(
        &conversation,
        client.provider(),
        defs,
        &permission,
        .{
            .max_turns = 12,
            .system_prompt = "STABLE-PREFIX",
            .progress_updates = config.enabled,
            .progress_update_silent_rounds = config.silent_rounds,
            .output_ledger = &ledger,
            .cwd_abs = root,
            .home_dir = root,
            .auto_compact_threshold = std.math.maxInt(usize),
        },
        &backend,
        allocator,
    );
    var out = Scenario{ .requests = server.requestCount(), .capture = capture, .ledger = ledger, .result = result };
    var index: usize = 0;
    while (server.requestAt(index)) |request| : (index += 1) {
        if (index < MAX_REQUESTS) out.markers[index] = std.mem.count(u8, request.body(), progress.MARKER);
    }
    return out;
}

fn tmpRoot(tmp: *std.testing.TmpDir, buf: *[std.fs.max_path_bytes]u8) ![]const u8 {
    return harness.normalizeSlashes(buf[0..try tmp.dir.realPath(std.testing.io, buf)]);
}

fn globInput(allocator: std.mem.Allocator, root: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{{\"pattern\":\"*.none\",\"path\":\"{s}\"}}", .{root});
}

test "L2 progress updates: three silent tool rounds earn one nudge; the reply is commentary and the answer is untouched" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(&tmp, &root_buf);
    const input = try globInput(a, root);
    defer a.free(input);

    const s1 = try silentToolSse(a, "m1", input);
    defer a.free(s1);
    const s2 = try silentToolSse(a, "m2", input);
    defer a.free(s2);
    const s3 = try silentToolSse(a, "m3", input);
    defer a.free(s3);
    const reply = try narratedToolSse(a, "m4", "Scanned the tree; nothing matched yet, checking sources next.", input);
    defer a.free(reply);
    const done = try finalSse(a, "Nothing to report.");
    defer a.free(done);

    var scenario = try runScenario(a, root, &.{ s1, s2, s3, reply, done }, .{});
    defer scenario.deinit();
    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, scenario.result.stop_reason);
    // Requests 1-3 are the silent rounds (first request byte-stable: no marker);
    // the nudge rides request 4 — the boundary after the third silent round —
    // and stays in the history of request 5.
    try scenario.expectMarkers(&.{ 0, 0, 0, 1, 1 });

    // The model's progress note is commentary (it was followed by a tool call),
    // never the answer; the final segment is exactly the end_turn text.
    var commentary_seen = false;
    for (scenario.capture.closed.items) |seg| {
        if (seg.disposition == .commentary and std.mem.indexOf(u8, seg.text, "Scanned the tree") != null) commentary_seen = true;
        if (seg.disposition == .final) try std.testing.expectEqualStrings("Nothing to report.", seg.text);
    }
    try std.testing.expect(commentary_seen);
    try std.testing.expectEqualStrings("Nothing to report.", scenario.ledger.finalText().?);
    try std.testing.expect(scenario.ledger.partialText() == null);
}

test "L2 progress updates: a narrated round resets the silent stretch" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(&tmp, &root_buf);
    const input = try globInput(a, root);
    defer a.free(input);

    const s1 = try silentToolSse(a, "m1", input);
    defer a.free(s1);
    const s2 = try silentToolSse(a, "m2", input);
    defer a.free(s2);
    const narrated = try narratedToolSse(a, "m3", "Two passes done, widening the search.", input);
    defer a.free(narrated);
    const s4 = try silentToolSse(a, "m4", input);
    defer a.free(s4);
    const s5 = try silentToolSse(a, "m5", input);
    defer a.free(s5);
    const done = try finalSse(a, "done");
    defer a.free(done);

    // Silent, silent, narrated, silent, silent: the longest silent stretch is 2,
    // below the default of 3, so the model that keeps the user informed on its
    // own is never nudged.
    var scenario = try runScenario(a, root, &.{ s1, s2, narrated, s4, s5, done }, .{});
    defer scenario.deinit();
    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, scenario.result.stop_reason);
    try scenario.expectMarkers(&.{ 0, 0, 0, 0, 0, 0 });
}

test "L2 progress updates: bounded to MAX_PROGRESS_NUDGES however long the silence" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(&tmp, &root_buf);
    const input = try globInput(a, root);
    defer a.free(input);

    var rounds: [6][]u8 = undefined;
    var ids: [6][8]u8 = undefined;
    for (&rounds, 0..) |*round, i| {
        const id = try std.fmt.bufPrint(&ids[i], "m{d}", .{i});
        round.* = try silentToolSse(a, id, input);
    }
    defer for (rounds) |round| a.free(round);
    const done = try finalSse(a, "done");
    defer a.free(done);

    // Threshold 1 (non-default, proves the option is wired): nudges after rounds
    // 1 and 2, then the bound holds — requests 4..7 carry exactly two markers.
    var scenario = try runScenario(a, root, &.{ rounds[0], rounds[1], rounds[2], rounds[3], rounds[4], rounds[5], done }, .{ .silent_rounds = 1 });
    defer scenario.deinit();
    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, scenario.result.stop_reason);
    try scenario.expectMarkers(&.{ 0, 1, 2, 2, 2, 2, 2 });
    try std.testing.expectEqual(@as(usize, 2), @as(usize, progress.MAX_PROGRESS_NUDGES));
}

test "L2 progress updates: a disabled gate never injects, and a short task never reaches the threshold" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try tmpRoot(&tmp, &root_buf);
    const input = try globInput(a, root);
    defer a.free(input);

    const s1 = try silentToolSse(a, "m1", input);
    defer a.free(s1);
    const s2 = try silentToolSse(a, "m2", input);
    defer a.free(s2);
    const s3 = try silentToolSse(a, "m3", input);
    defer a.free(s3);
    const s4 = try silentToolSse(a, "m4", input);
    defer a.free(s4);
    const done = try finalSse(a, "done");
    defer a.free(done);

    {
        var scenario = try runScenario(a, root, &.{ s1, s2, s3, s4, done }, .{ .enabled = false });
        defer scenario.deinit();
        try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, scenario.result.stop_reason);
        try scenario.expectMarkers(&.{ 0, 0, 0, 0, 0 });
    }
    {
        // One silent lookup then the answer: simple tasks are not forced to narrate.
        var scenario = try runScenario(a, root, &.{ s1, done }, .{});
        defer scenario.deinit();
        try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, scenario.result.stop_reason);
        try scenario.expectMarkers(&.{ 0, 0 });
        try std.testing.expectEqualStrings("done", scenario.ledger.finalText().?);
    }
}
