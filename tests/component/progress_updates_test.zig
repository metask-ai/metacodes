//! L2: the progress-update obligation (#114). A run whose tool rounds stay
//! silent — no visible model text, round after round, for longer than the
//! time floor — receives a bounded nudge at the turn boundary asking for a
//! short progress note; any visible text resets the stretch (also text the
//! loop continued past, and text cut off by max_tokens); whitespace is not
//! text; a short task never sees it; the reply is ordinary commentary and the
//! final answer is untouched; observe mode records the decisions without
//! injecting; a run nobody reads is never nudged. Every assertion is on the
//! real provider request bytes, the real output-segment protocol and the
//! terminal observation record, through the shared agent loop, with no
//! provider model involved.

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

const Stop = enum { end_turn, max_tokens };

/// One assistant response: optional visible text, then an optional Glob call.
/// `tool_input == null` ends the turn (`stop`); otherwise the model is mid-task.
fn responseSse(allocator: std.mem.Allocator, id: []const u8, text: ?[]const u8, tool_input: ?[]const u8, stop: Stop) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const w = &out.writer;
    try w.print("data: {{\"type\":\"message_start\",\"message\":{{\"id\":\"{s}\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{{\"input_tokens\":1,\"output_tokens\":1}}}}}}\n\n", .{id});
    var index: usize = 0;
    if (text) |t| {
        const encoded = try encodeJson(allocator, t);
        defer allocator.free(encoded);
        try w.print("data: {{\"type\":\"content_block_start\",\"index\":{d},\"content_block\":{{\"type\":\"text\",\"text\":\"\"}}}}\n\n", .{index});
        try w.print("data: {{\"type\":\"content_block_delta\",\"index\":{d},\"delta\":{{\"type\":\"text_delta\",\"text\":{s}}}}}\n\n", .{ index, encoded });
        try w.print("data: {{\"type\":\"content_block_stop\",\"index\":{d}}}\n\n", .{index});
        index += 1;
    }
    if (tool_input) |input| {
        const encoded = try encodeJson(allocator, input);
        defer allocator.free(encoded);
        try w.print("data: {{\"type\":\"content_block_start\",\"index\":{d},\"content_block\":{{\"type\":\"tool_use\",\"id\":\"{s}_tu\",\"name\":\"Glob\",\"input\":{{}}}}}}\n\n", .{ index, id });
        try w.print("data: {{\"type\":\"content_block_delta\",\"index\":{d},\"delta\":{{\"type\":\"input_json_delta\",\"partial_json\":{s}}}}}\n\n", .{ index, encoded });
        try w.print("data: {{\"type\":\"content_block_stop\",\"index\":{d}}}\n\n", .{index});
    }
    const stop_reason: []const u8 = if (tool_input != null) "tool_use" else switch (stop) {
        .end_turn => "end_turn",
        .max_tokens => "max_tokens",
    };
    try w.print("data: {{\"type\":\"message_delta\",\"delta\":{{\"stop_reason\":\"{s}\"}},\"usage\":{{\"output_tokens\":1}}}}\n\n", .{stop_reason});
    try w.writeAll("data: {\"type\":\"message_stop\"}\n\n");
    return out.toOwnedSlice();
}

/// Records the closed visible segments exactly as a streaming consumer would,
/// and whether every segment that opened was closed (a nudge injected between
/// a segment's open and close would show up here as `unbalanced`).
const SegmentCapture = struct {
    allocator: std.mem.Allocator,
    buffer: std.ArrayList(u8) = .empty,
    closed: std.ArrayList(Closed) = .empty,
    open: bool = false,
    unbalanced: bool = false,

    const Closed = struct { turn: u32, disposition: Disposition, text: []u8 };

    fn deinit(self: *SegmentCapture) void {
        self.buffer.deinit(self.allocator);
        for (self.closed.items) |c| self.allocator.free(c.text);
        self.closed.deinit(self.allocator);
    }

    fn emit(ctx: *anyopaque, _: cc.session_id.SessionId, ev: cc.ui_event.CoreEvent) void {
        const self: *SegmentCapture = @ptrCast(@alignCast(ctx));
        switch (ev) {
            .output_segment_begin => {
                if (self.open) self.unbalanced = true;
                self.open = true;
                self.buffer.clearRetainingCapacity();
            },
            .text_chunk => |t| self.buffer.appendSlice(self.allocator, t) catch {},
            .output_segment_end => |e| {
                if (!self.open) self.unbalanced = true;
                self.open = false;
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

/// The terminal observation record, as the eval trace parser reads it.
const RecordSink = struct {
    records: usize = 0,
    enforced: bool = false,
    silent_rounds_threshold: u32 = 0,
    min_silent_ms: u64 = 1,
    max_silent_rounds: u32 = 255,
    decisions: u8 = 255,
    nudges: u8 = 255,
    max_nudges: u8 = 0,

    fn emit(raw: *anyopaque, event: cc.tools.tool_observation.Event) bool {
        const self: *@This() = @ptrCast(@alignCast(raw));
        switch (event) {
            .progress_updates => |record| {
                self.records += 1;
                self.enforced = record.enforced;
                self.silent_rounds_threshold = record.silent_rounds_threshold;
                self.min_silent_ms = record.min_silent_ms;
                self.max_silent_rounds = record.max_silent_rounds;
                self.decisions = record.decisions;
                self.nudges = record.nudges;
                self.max_nudges = record.max_nudges;
            },
            else => {},
        }
        return true;
    }

    fn sink(self: *@This()) cc.tools.tool_observation.Sink {
        return .{ .ctx = @ptrCast(self), .emitFn = emit };
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
    record: RecordSink,

    fn deinit(self: *Scenario) void {
        self.capture.deinit();
        self.ledger.deinit();
    }

    fn expectMarkers(self: *const Scenario, expected: []const usize) !void {
        try std.testing.expectEqual(expected.len, self.requests);
        for (expected, 0..) |count, index| try std.testing.expectEqual(count, self.markers[index]);
    }
};

const Mode = enum { off, enforced, observe };

const Config = struct {
    mode: Mode = .enforced,
    rounds: u32 = 3,
    /// 0 by default: the component test proves the round logic in
    /// milliseconds; the time floor has its own scenario.
    min_silent_ms: u64 = 0,
    agent_depth: u8 = 0,
};

/// Temp root + the Glob input every tool round uses; the same bytes each
/// round, so the ids are the only thing the fixtures vary.
const Fixture = struct {
    tmp: std.testing.TmpDir,
    root_buf: [std.fs.max_path_bytes]u8 = undefined,
    root: []const u8 = "",
    input: []u8 = "",

    fn init(self: *Fixture, allocator: std.mem.Allocator) !void {
        self.tmp = std.testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        self.root = harness.normalizeSlashes(self.root_buf[0..try self.tmp.dir.realPath(std.testing.io, &self.root_buf)]);
        self.input = try std.fmt.allocPrint(allocator, "{{\"pattern\":\"*.none\",\"path\":\"{s}\"}}", .{self.root});
    }

    fn deinit(self: *Fixture, allocator: std.mem.Allocator) void {
        allocator.free(self.input);
        self.tmp.cleanup();
    }

    /// A tool round with no visible text: the shape that leaves the user in the dark.
    fn silent(self: *const Fixture, allocator: std.mem.Allocator, id: []const u8) ![]u8 {
        return responseSse(allocator, id, null, self.input, .end_turn);
    }

    /// A narrated tool round: visible text, then the tool call.
    fn narrated(self: *const Fixture, allocator: std.mem.Allocator, id: []const u8, text: []const u8) ![]u8 {
        return responseSse(allocator, id, text, self.input, .end_turn);
    }
};

fn finalSse(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    return responseSse(allocator, "final", text, null, .end_turn);
}

fn runScenario(allocator: std.mem.Allocator, fixture: *const Fixture, responses: []const []const u8, config: Config) !Scenario {
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
    var record = RecordSink{};
    const backend = capture.backend();
    const result = try cc.agent_loop.run(
        &conversation,
        client.provider(),
        defs,
        &permission,
        .{
            .max_turns = 12,
            .system_prompt = "STABLE-PREFIX",
            .progress_updates = config.mode == .enforced,
            .progress_updates_observe = config.mode == .observe,
            .progress_update_thresholds = .{ .rounds = config.rounds, .min_silent_ms = config.min_silent_ms },
            .agent_depth = config.agent_depth,
            .tool_observer = record.sink(),
            .output_ledger = &ledger,
            .cwd_abs = fixture.root,
            .home_dir = fixture.root,
            .auto_compact_threshold = std.math.maxInt(usize),
        },
        &backend,
        allocator,
    );
    // Every scenario ends with an end_turn answer; a max_turns stop would make
    // the marker rows below meaningless.
    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, result.stop_reason);
    try std.testing.expect(!capture.unbalanced);
    var out = Scenario{ .requests = server.requestCount(), .capture = capture, .ledger = ledger, .record = record };
    var index: usize = 0;
    while (server.requestAt(index)) |request| : (index += 1) {
        if (index < MAX_REQUESTS) out.markers[index] = std.mem.count(u8, request.body(), progress.MARKER);
    }
    return out;
}

test "L2 progress updates: three silent tool rounds earn one nudge; the reply is commentary, the answer is untouched, the record says so" {
    const a = std.testing.allocator;
    var fx: Fixture = undefined;
    try fx.init(a);
    defer fx.deinit(a);
    const rounds = [_][]u8{ try fx.silent(a, "m1"), try fx.silent(a, "m2"), try fx.silent(a, "m3") };
    defer for (rounds) |r| a.free(r);
    const reply = try fx.narrated(a, "m4", "Scanned the tree; nothing matched yet, checking sources next.");
    defer a.free(reply);
    const done = try finalSse(a, "Nothing to report.");
    defer a.free(done);

    var scenario = try runScenario(a, &fx, &.{ rounds[0], rounds[1], rounds[2], reply, done }, .{});
    defer scenario.deinit();
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

    // Terminal record: enforced, one decision = one nudge, the longest stretch
    // was the three rounds, thresholds as configured.
    try std.testing.expectEqual(@as(usize, 1), scenario.record.records);
    try std.testing.expect(scenario.record.enforced);
    try std.testing.expectEqual(@as(u8, 1), scenario.record.decisions);
    try std.testing.expectEqual(@as(u8, 1), scenario.record.nudges);
    try std.testing.expectEqual(@as(u8, 2), scenario.record.max_nudges);
    try std.testing.expectEqual(@as(u32, 3), scenario.record.max_silent_rounds);
    try std.testing.expectEqual(@as(u32, 3), scenario.record.silent_rounds_threshold);
    try std.testing.expectEqual(@as(u64, 0), scenario.record.min_silent_ms);
}

test "L2 progress updates: any visible text resets the stretch — a narrated round, and text the loop continued past" {
    const a = std.testing.allocator;
    var fx: Fixture = undefined;
    try fx.init(a);
    defer fx.deinit(a);
    const s1 = try fx.silent(a, "m1");
    defer a.free(s1);
    const s2 = try fx.silent(a, "m2");
    defer a.free(s2);
    const narrated = try fx.narrated(a, "m3", "Two passes done, widening the search.");
    defer a.free(narrated);
    const s4 = try fx.silent(a, "m4");
    defer a.free(s4);
    const s5 = try fx.silent(a, "m5");
    defer a.free(s5);
    const done = try finalSse(a, "done");
    defer a.free(done);

    {
        // Silent, silent, narrated, silent, silent: the longest silent stretch is
        // 2, below 3, so the model that keeps the user informed is never nudged.
        var scenario = try runScenario(a, &fx, &.{ s1, s2, narrated, s4, s5, done }, .{});
        defer scenario.deinit();
        try scenario.expectMarkers(&.{ 0, 0, 0, 0, 0, 0 });
        try std.testing.expectEqual(@as(u8, 0), scenario.record.decisions);
        try std.testing.expectEqual(@as(u32, 2), scenario.record.max_silent_rounds);
    }
    {
        // Silent, silent, then visible text cut off by max_tokens (no tool call;
        // the loop appends its continuation prompt and goes on), then a silent
        // round: the user read text one round ago, so the stretch is 1, not 3.
        const cut = try responseSse(a, "cut", "Here is what I found so far:", null, .max_tokens);
        defer a.free(cut);
        var scenario = try runScenario(a, &fx, &.{ s1, s2, cut, s4, done }, .{});
        defer scenario.deinit();
        try scenario.expectMarkers(&.{ 0, 0, 0, 0, 0 });
        try std.testing.expectEqual(@as(u32, 2), scenario.record.max_silent_rounds);
    }
}

test "L2 progress updates: whitespace-only text is not narration" {
    const a = std.testing.allocator;
    var fx: Fixture = undefined;
    try fx.init(a);
    defer fx.deinit(a);
    // A chat-template artefact some OpenAI-compatible endpoints emit before
    // every tool call: a lone newline. Counting it as narration would disarm
    // the gate for exactly the models that never narrate.
    const rounds = [_][]u8{ try fx.narrated(a, "m1", "\n"), try fx.narrated(a, "m2", " \n"), try fx.narrated(a, "m3", "\n") };
    defer for (rounds) |r| a.free(r);
    const done = try finalSse(a, "done");
    defer a.free(done);

    var scenario = try runScenario(a, &fx, &.{ rounds[0], rounds[1], rounds[2], done }, .{});
    defer scenario.deinit();
    try scenario.expectMarkers(&.{ 0, 0, 0, 1 });
    try std.testing.expectEqual(@as(u32, 3), scenario.record.max_silent_rounds);
}

test "L2 progress updates: bounded to MAX_PROGRESS_NUDGES however long the silence" {
    const a = std.testing.allocator;
    var fx: Fixture = undefined;
    try fx.init(a);
    defer fx.deinit(a);
    var rounds: [4][]u8 = undefined;
    var ids: [4][8]u8 = undefined;
    for (&rounds, 0..) |*round, i| round.* = try fx.silent(a, try std.fmt.bufPrint(&ids[i], "m{d}", .{i}));
    defer for (rounds) |round| a.free(round);
    const done = try finalSse(a, "done");
    defer a.free(done);

    // Threshold 1 (non-default, proves the option is wired): nudges after rounds
    // 1 and 2, then the bound holds — requests 4 and 5 carry exactly two markers.
    var scenario = try runScenario(a, &fx, &.{ rounds[0], rounds[1], rounds[2], rounds[3], done }, .{ .rounds = 1 });
    defer scenario.deinit();
    try scenario.expectMarkers(&.{ 0, 1, 2, 2, 2 });
    try std.testing.expectEqual(progress.MAX_PROGRESS_NUDGES, scenario.record.decisions);
    try std.testing.expectEqual(progress.MAX_PROGRESS_NUDGES, scenario.record.nudges);
}

test "L2 progress updates: the time floor holds back quick rounds" {
    const a = std.testing.allocator;
    var fx: Fixture = undefined;
    try fx.init(a);
    defer fx.deinit(a);
    var rounds: [4][]u8 = undefined;
    var ids: [4][8]u8 = undefined;
    for (&rounds, 0..) |*round, i| round.* = try fx.silent(a, try std.fmt.bufPrint(&ids[i], "m{d}", .{i}));
    defer for (rounds) |round| a.free(round);
    const done = try finalSse(a, "done");
    defer a.free(done);

    // Four silent rounds against a one-hour floor: the rounds are there, the
    // silence is not — three sub-second lookups are not "a few seconds".
    var scenario = try runScenario(a, &fx, &.{ rounds[0], rounds[1], rounds[2], rounds[3], done }, .{ .rounds = 1, .min_silent_ms = 3_600_000 });
    defer scenario.deinit();
    try scenario.expectMarkers(&.{ 0, 0, 0, 0, 0 });
    try std.testing.expectEqual(@as(u64, 3_600_000), scenario.record.min_silent_ms);
    try std.testing.expectEqual(@as(u32, 4), scenario.record.max_silent_rounds);
}

test "L2 progress updates: observe mode records the decisions without injecting; off records nothing; a subagent is never nudged" {
    const a = std.testing.allocator;
    var fx: Fixture = undefined;
    try fx.init(a);
    defer fx.deinit(a);
    var rounds: [4][]u8 = undefined;
    var ids: [4][8]u8 = undefined;
    for (&rounds, 0..) |*round, i| round.* = try fx.silent(a, try std.fmt.bufPrint(&ids[i], "m{d}", .{i}));
    defer for (rounds) |round| a.free(round);
    const done = try finalSse(a, "done");
    defer a.free(done);
    const responses = [_][]const u8{ rounds[0], rounds[1], rounds[2], rounds[3], done };

    {
        // Control arm: the same crossings are counted, no request byte changes.
        var scenario = try runScenario(a, &fx, &responses, .{ .mode = .observe, .rounds = 1 });
        defer scenario.deinit();
        try scenario.expectMarkers(&.{ 0, 0, 0, 0, 0 });
        try std.testing.expectEqual(@as(usize, 1), scenario.record.records);
        try std.testing.expect(!scenario.record.enforced);
        try std.testing.expectEqual(progress.MAX_PROGRESS_NUDGES, scenario.record.decisions);
        try std.testing.expectEqual(@as(u8, 0), scenario.record.nudges);
    }
    {
        // Off (the Options default, what canonical buildRunOptions hands every
        // macro run): nothing injected, nothing recorded.
        var scenario = try runScenario(a, &fx, &responses, .{ .mode = .off, .rounds = 1 });
        defer scenario.deinit();
        try scenario.expectMarkers(&.{ 0, 0, 0, 0, 0 });
        try std.testing.expectEqual(@as(usize, 0), scenario.record.records);
        try std.testing.expectEqualStrings("done", scenario.ledger.finalText().?);
    }
    {
        // A subagent's narration is its parent's tool result, not user-visible:
        // enforced but at depth 1 the gate never decides.
        var scenario = try runScenario(a, &fx, &responses, .{ .rounds = 1, .agent_depth = 1 });
        defer scenario.deinit();
        try scenario.expectMarkers(&.{ 0, 0, 0, 0, 0 });
        try std.testing.expectEqual(@as(u8, 0), scenario.record.decisions);
    }
}

test "L2 progress updates: a short task never reaches the threshold" {
    const a = std.testing.allocator;
    var fx: Fixture = undefined;
    try fx.init(a);
    defer fx.deinit(a);
    const s1 = try fx.silent(a, "m1");
    defer a.free(s1);
    const done = try finalSse(a, "done");
    defer a.free(done);

    // One silent lookup then the answer: simple tasks are not forced to narrate.
    var scenario = try runScenario(a, &fx, &.{ s1, done }, .{});
    defer scenario.deinit();
    try scenario.expectMarkers(&.{ 0, 0 });
    try std.testing.expectEqualStrings("done", scenario.ledger.finalText().?);
}
