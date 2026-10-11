//! L2: the stall gate (StallGate.lean, doc/STALL_GATE_DESIGN.md). Tool rounds
//! that keep returning nothing new end the run with `StopReason.stalled`.
//! That covers the same call answered with the same bytes (repeat tier), and
//! answers the model has already seen (stale tier). The round's results are
//! committed first and nothing is injected. A run that keeps getting something
//! new back is never stopped, however repetitive its other calls are. Observe
//! mode records the stop point and changes nothing. Off by default.
//!
//! Every assertion is on the real provider request count, the real
//! conversation, the RunResult the host renders and the terminal observation
//! record, through the shared agent loop and real tools on a temp directory.
//! The traces are synthetic, and no provider model is involved.

const std = @import("std");
const harness = @import("harness");
const cc = @import("cc");

const stall = cc.stall_gate;

fn encodeJson(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var escaped: std.Io.Writer.Allocating = .init(allocator);
    defer escaped.deinit();
    try std.json.Stringify.encodeJsonString(text, .{}, &escaped.writer);
    return escaped.toOwnedSlice();
}

const Call = struct { name: []const u8, input: []const u8 };

/// One assistant response with no text: the tool calls in order, or (no calls)
/// a final answer.
fn turnSse(allocator: std.mem.Allocator, id: []const u8, calls: []const Call, final_text: ?[]const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const w = &out.writer;
    try w.print("data: {{\"type\":\"message_start\",\"message\":{{\"id\":\"{s}\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{{\"input_tokens\":1,\"output_tokens\":1}}}}}}\n\n", .{id});
    var index: usize = 0;
    if (final_text) |text| {
        const encoded = try encodeJson(allocator, text);
        defer allocator.free(encoded);
        try w.print("data: {{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{{\"type\":\"text\",\"text\":\"\"}}}}\n\n", .{});
        try w.print("data: {{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{{\"type\":\"text_delta\",\"text\":{s}}}}}\n\n", .{encoded});
        try w.print("data: {{\"type\":\"content_block_stop\",\"index\":0}}\n\n", .{});
        index += 1;
    }
    for (calls, 0..) |call, i| {
        const encoded = try encodeJson(allocator, call.input);
        defer allocator.free(encoded);
        try w.print("data: {{\"type\":\"content_block_start\",\"index\":{d},\"content_block\":{{\"type\":\"tool_use\",\"id\":\"{s}_tu{d}\",\"name\":\"{s}\",\"input\":{{}}}}}}\n\n", .{ index, id, i, call.name });
        try w.print("data: {{\"type\":\"content_block_delta\",\"index\":{d},\"delta\":{{\"type\":\"input_json_delta\",\"partial_json\":{s}}}}}\n\n", .{ index, encoded });
        try w.print("data: {{\"type\":\"content_block_stop\",\"index\":{d}}}\n\n", .{index});
        index += 1;
    }
    const stop_reason: []const u8 = if (calls.len > 0) "tool_use" else "end_turn";
    try w.print("data: {{\"type\":\"message_delta\",\"delta\":{{\"stop_reason\":\"{s}\"}},\"usage\":{{\"output_tokens\":1}}}}\n\n", .{stop_reason});
    try w.writeAll("data: {\"type\":\"message_stop\"}\n\n");
    return out.toOwnedSlice();
}

/// The terminal observation record, as the eval trace parser reads it.
const RecordSink = struct {
    records: usize = 0,
    record: ?@FieldType(cc.tools.tool_observation.Event, "stall_gate") = null,

    fn emit(raw: *anyopaque, event: cc.tools.tool_observation.Event) bool {
        const self: *@This() = @ptrCast(@alignCast(raw));
        switch (event) {
            .stall_gate => |record| {
                self.records += 1;
                self.record = record;
            },
            else => {},
        }
        return true;
    }

    fn sink(self: *@This()) cc.tools.tool_observation.Sink {
        return .{ .ctx = @ptrCast(self), .emitFn = emit };
    }
};

const NullBackend = struct {
    fn emit(_: *anyopaque, _: cc.session_id.SessionId, _: cc.ui_event.CoreEvent) void {}
    fn poll(_: *anyopaque, _: cc.session_id.SessionId) ?cc.ui_event.UiEvent {
        return null;
    }
    fn backend(self: *NullBackend) cc.ui_backend.UiBackend {
        return .{ .ctx = @ptrCast(self), .emit = emit, .poll = poll };
    }
};

const FILES = 12;

/// Temp root with `FILES` small files of distinct content, and the inputs the
/// traces use: one Glob that always finds nothing, and one Read per file.
const Fixture = struct {
    tmp: std.testing.TmpDir,
    root_buf: [std.fs.max_path_bytes]u8 = undefined,
    root: []const u8 = "",
    poll: []u8 = "",
    reads: [FILES][]u8 = undefined,

    fn init(self: *Fixture, allocator: std.mem.Allocator) !void {
        self.tmp = std.testing.tmpDir(.{});
        errdefer self.tmp.cleanup();
        self.root = harness.normalizeSlashes(self.root_buf[0..try self.tmp.dir.realPath(std.testing.io, &self.root_buf)]);
        self.poll = try std.fmt.allocPrint(allocator, "{{\"pattern\":\"*.none\",\"path\":\"{s}\"}}", .{self.root});
        for (0..FILES) |i| {
            var name_buf: [16]u8 = undefined;
            var body_buf: [32]u8 = undefined;
            const name = try std.fmt.bufPrint(&name_buf, "f{d}.txt", .{i});
            const body = try std.fmt.bufPrint(&body_buf, "finding number {d}\n", .{i});
            try self.tmp.dir.writeFile(std.testing.io, .{ .sub_path = name, .data = body });
            self.reads[i] = try std.fmt.allocPrint(allocator, "{{\"file_path\":\"{s}/{s}\"}}", .{ self.root, name });
        }
    }

    fn deinit(self: *Fixture, allocator: std.mem.Allocator) void {
        allocator.free(self.poll);
        for (self.reads) |r| allocator.free(r);
        self.tmp.cleanup();
    }
};

const Outcome = struct {
    result: cc.agent_loop.RunResult,
    requests: usize,
    record: RecordSink,
    /// The last message is the user message carrying tool results: the round
    /// that tripped the gate was committed before the run stopped.
    ends_with_tool_results: bool,
};

fn runTrace(allocator: std.mem.Allocator, fixture: *const Fixture, responses: []const []const u8, mode: ?stall.Mode) !Outcome {
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
    try conversation.appendText(.user, "wait for the job and report");
    var permission = cc.permission.createContext(.bypass_permissions, allocator);
    permission.no_interactive_prompt = true;
    const defs = try cc.tools.toToolDefinitions(allocator);
    defer allocator.free(defs);

    var null_backend = NullBackend{};
    const backend = null_backend.backend();
    var record = RecordSink{};
    const result = try cc.agent_loop.run(
        &conversation,
        client.provider(),
        defs,
        &permission,
        .{
            .max_turns = 30,
            .system_prompt = "STABLE-PREFIX",
            .stall_gate = mode,
            .tool_observer = record.sink(),
            .cwd_abs = fixture.root,
            .home_dir = fixture.root,
            .auto_compact_threshold = std.math.maxInt(usize),
        },
        &backend,
        allocator,
    );
    const last = conversation.messages.items[conversation.messages.items.len - 1];
    const ends_with_results = last.role == .user and last.blocks.len > 0 and last.blocks[0] == .tool_result;
    return .{ .result = result, .requests = server.requestCount(), .record = record, .ends_with_tool_results = ends_with_results };
}

const Responses = struct {
    items: std.ArrayList([]u8) = .empty,

    fn deinit(self: *Responses, allocator: std.mem.Allocator) void {
        for (self.items.items) |r| allocator.free(r);
        self.items.deinit(allocator);
    }

    fn round(self: *Responses, allocator: std.mem.Allocator, calls: []const Call) !void {
        var id_buf: [16]u8 = undefined;
        const id = try std.fmt.bufPrint(&id_buf, "m{d}", .{self.items.items.len});
        try self.items.append(allocator, try turnSse(allocator, id, calls, null));
    }

    fn final(self: *Responses, allocator: std.mem.Allocator) !void {
        try self.items.append(allocator, try turnSse(allocator, "final", &.{}, "done"));
    }
};

/// The same poll, round after round, then an answer the run should never get to.
fn pollingTrace(allocator: std.mem.Allocator, fx: *const Fixture, rounds: usize) !Responses {
    var out = Responses{};
    errdefer out.deinit(allocator);
    for (0..rounds) |_| try out.round(allocator, &.{.{ .name = "Glob", .input = fx.poll }});
    try out.final(allocator);
    return out;
}

test "L2 stall gate: the same call answered with the same bytes stops the run after the fifth round, evidence committed, nothing injected" {
    const a = std.testing.allocator;
    var fx: Fixture = undefined;
    try fx.init(a);
    defer fx.deinit(a);
    var trace = try pollingTrace(a, &fx, 10);
    defer trace.deinit(a);

    const out = try runTrace(a, &fx, trace.items.items, .enforce);
    // Round 1 is new; rounds 2-5 return the same answer to the same call: the
    // repeat tier (4 stale rounds, 4 identical calls) stops the run there, so
    // the provider never sees a sixth request.
    try std.testing.expectEqual(cc.agent_loop.StopReason.stalled, out.result.stop_reason);
    try std.testing.expectEqual(@as(usize, 5), out.requests);
    try std.testing.expectEqual(@as(u32, 5), out.result.turns);
    try std.testing.expect(out.ends_with_tool_results);
    const report = out.result.stall.?;
    try std.testing.expectEqual(stall.Cause.repeating, report.cause);
    try std.testing.expectEqualStrings("Glob", report.tool.slice());
    try std.testing.expectEqual(@as(u32, 4), report.repeats);
    try std.testing.expectEqual(@as(u32, 4), report.stale_rounds);
    // What the REPL prints names the tool, the count and how to continue.
    const notice = try stall.renderStopNotice(a, report);
    defer a.free(notice);
    try std.testing.expect(std.mem.indexOf(u8, notice, "Glob") != null);
    try std.testing.expect(std.mem.indexOf(u8, notice, "续接") != null);

    try std.testing.expectEqual(@as(usize, 1), out.record.records);
    const record = out.record.record.?;
    try std.testing.expect(record.enforced);
    try std.testing.expectEqual(@as(u8, 1), record.decisions);
    try std.testing.expectEqual(stall.MAX_STALL_DECISIONS, record.max_decisions);
    try std.testing.expectEqual(cc.tools.tool_observation.StallCause.repeating, record.cause);
    try std.testing.expectEqual(@as(u32, 5), record.decided_round);
    try std.testing.expectEqual(@as(u32, 5), record.rounds);
    try std.testing.expectEqual(@as(u32, 1), record.progress_rounds);
    try std.testing.expectEqual(@as(u32, 4), record.max_stale_rounds);
    try std.testing.expectEqual(@as(u32, 4), record.max_repeats);
    try std.testing.expectEqual(stall.DEFAULT_REPEAT_ROUNDS, record.repeat_rounds_threshold);
    try std.testing.expectEqual(stall.DEFAULT_REPEAT_CALLS, record.repeat_calls_threshold);
    try std.testing.expectEqual(stall.DEFAULT_STALE_ROUNDS, record.stale_rounds_threshold);
}

test "L2 stall gate: a run whose rounds each bring something new is never stopped, however often it repeats the poll" {
    const a = std.testing.allocator;
    var fx: Fixture = undefined;
    try fx.init(a);
    defer fx.deinit(a);
    var trace = Responses{};
    defer trace.deinit(a);
    // Every round repeats the same stale poll and reads one file not read
    // before: twelve rounds, twelve identical poll calls, no stop.
    for (0..FILES) |i| try trace.round(a, &.{ .{ .name = "Glob", .input = fx.poll }, .{ .name = "Read", .input = fx.reads[i] } });
    try trace.final(a);

    const out = try runTrace(a, &fx, trace.items.items, .enforce);
    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, out.result.stop_reason);
    try std.testing.expectEqual(@as(usize, FILES + 1), out.requests);
    try std.testing.expect(out.result.stall == null);
    const record = out.record.record.?;
    try std.testing.expectEqual(@as(u8, 0), record.decisions);
    try std.testing.expectEqual(cc.tools.tool_observation.StallCause.none, record.cause);
    try std.testing.expectEqual(@as(u32, 0), record.decided_round);
    try std.testing.expectEqual(@as(u32, FILES), record.rounds);
    try std.testing.expectEqual(@as(u32, FILES), record.progress_rounds);
    try std.testing.expectEqual(@as(u32, 0), record.max_stale_rounds);
}

test "L2 stall gate: re-reading answers already seen, call after varied call, stops on the stale tier" {
    const a = std.testing.allocator;
    var fx: Fixture = undefined;
    try fx.init(a);
    defer fx.deinit(a);
    var trace = Responses{};
    defer trace.deinit(a);
    // Three files read in turn: rounds 1-3 are new, then every answer is one
    // already seen and no single call repeats four times before the eighth
    // stale round (round 11).
    for (0..14) |i| try trace.round(a, &.{.{ .name = "Read", .input = fx.reads[i % 3] }});
    try trace.final(a);

    const out = try runTrace(a, &fx, trace.items.items, .enforce);
    try std.testing.expectEqual(cc.agent_loop.StopReason.stalled, out.result.stop_reason);
    try std.testing.expectEqual(@as(usize, 11), out.requests);
    const report = out.result.stall.?;
    try std.testing.expectEqual(stall.Cause.stale, report.cause);
    try std.testing.expectEqual(stall.DEFAULT_STALE_ROUNDS, report.stale_rounds);
    try std.testing.expectEqual(cc.tools.tool_observation.StallCause.stale, out.record.record.?.cause);
    try std.testing.expectEqual(@as(u32, 11), out.record.record.?.decided_round);
}

test "L2 stall gate: observe mode records where it would have stopped and changes nothing; off emits no record" {
    const a = std.testing.allocator;
    var fx: Fixture = undefined;
    try fx.init(a);
    defer fx.deinit(a);
    var trace = try pollingTrace(a, &fx, 8);
    defer trace.deinit(a);

    {
        const out = try runTrace(a, &fx, trace.items.items, .observe);
        try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, out.result.stop_reason);
        try std.testing.expectEqual(@as(usize, 9), out.requests);
        try std.testing.expect(out.result.stall == null);
        const record = out.record.record.?;
        try std.testing.expect(!record.enforced);
        try std.testing.expectEqual(@as(u8, 1), record.decisions);
        try std.testing.expectEqual(cc.tools.tool_observation.StallCause.repeating, record.cause);
        try std.testing.expectEqual(@as(u32, 5), record.decided_round);
        try std.testing.expectEqual(@as(u32, 8), record.rounds);
    }
    {
        // Host-contract field: unset, the gate does not exist for this run.
        const out = try runTrace(a, &fx, trace.items.items, null);
        try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, out.result.stop_reason);
        try std.testing.expectEqual(@as(usize, 9), out.requests);
        try std.testing.expectEqual(@as(usize, 0), out.record.records);
    }
}
