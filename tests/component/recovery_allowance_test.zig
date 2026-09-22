//! L2: the per-turn recovery allowance for exempt `ReadArtifact` reads (#40).
//!
//! A real agent-loop turn against a cassette provider, a persisted artifact and
//! the kernel's own `ReadArtifact` tool. What the model sees - served
//! envelopes, `recovery_allowance_exhausted` bodies, `policy_decision` events -
//! is read back from the provider request bodies and the UI event stream, the
//! same way `tool_result_storage_test.zig` observes projection.

const std = @import("std");
const cc = @import("cc");
const harness = @import("harness");

const ARTIFACT_BYTES: usize = 100_000;
const STRIDE: usize = 10_000;
/// One read is charged its upper bound; on the 200K window the harness model
/// maps to, that is 25,000 bytes against a 102,400-byte allowance: four fit.
const SERVED_PER_TURN: usize = 4;
const ALLOWANCE_ON_200K: i64 = 102_400;
const CHARGED_WHEN_FULL: i64 = 100_000;

const FINAL_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"done\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"done\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

/// One assistant message carrying one `ReadArtifact` call per slot in
/// `slots`, with id `<prefix><slot>` and offset `slot * STRIDE`. Parallel calls
/// are what the allowance exists for: nothing caps how many `tool_use` blocks
/// one message carries.
fn readCallsSse(allocator: std.mem.Allocator, prefix: []const u8, artifact_id: []const u8, slots: []const usize) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const w = &out.writer;
    try w.writeAll("data: {\"type\":\"message_start\",\"message\":{\"id\":\"tool\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n");
    for (slots, 0..) |slot, index| {
        const input = try std.fmt.allocPrint(allocator, "{{\"artifact_id\":\"{s}\",\"offset\":{d}}}", .{ artifact_id, slot * STRIDE });
        defer allocator.free(input);
        const encoded_input = try std.json.Stringify.valueAlloc(allocator, input, .{});
        defer allocator.free(encoded_input);
        try w.print(
            "data: {{\"type\":\"content_block_start\",\"index\":{d},\"content_block\":{{\"type\":\"tool_use\",\"id\":\"{s}{d}\",\"name\":\"ReadArtifact\",\"input\":{{}}}}}}\n\n" ++
                "data: {{\"type\":\"content_block_delta\",\"index\":{d},\"delta\":{{\"type\":\"input_json_delta\",\"partial_json\":{s}}}}}\n\n" ++
                "data: {{\"type\":\"content_block_stop\",\"index\":{d}}}\n\n",
            .{ index, prefix, slot, index, encoded_input, index },
        );
    }
    try w.writeAll("data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":1}}\n\n");
    try w.writeAll("data: {\"type\":\"message_stop\"}\n\n");
    return out.toOwnedSlice();
}

/// The kernel's real recovery tool behind a Host dispatcher. Prefetch is off so
/// `artifact_recovery_calls` counts exactly the reads the loop chose to run.
const Dispatcher = struct {
    fn dispatch(_: *const anyopaque, ctx: *const cc.tool_context.ToolContext, name: []const u8, args: []const u8) anyerror!cc.tool_context.ToolDispatchOutcome {
        if (std.mem.eql(u8, name, "ReadArtifact"))
            return .{ .ok = cc.tools.ToolResultBody.initInline(try cc.read_artifact.execute(ctx, args)) };
        return .{ .host_rejected = null };
    }
    fn metadata(_: *const anyopaque, _: []const u8) ?cc.tool_context.ToolMeta {
        return .{ .kind = .host, .category = .execute, .replay = .never, .prefetch_safe = false };
    }
    fn nameAt(_: *const anyopaque, index: usize) ?[]const u8 {
        return if (index == 0) "ReadArtifact" else null;
    }
    fn asDispatcher(self: *const @This()) cc.tool_context.ToolDispatcher {
        return .{ .ctx = @ptrCast(self), .dispatchFn = dispatch, .metadataFn = metadata, .nameAtFn = nameAt };
    }
};

/// Counts the allowance's `policy_decision` events and remembers which call
/// ids they named (ids end in the slot digit). The permission chain emits its
/// own `policy_decision` per slot; those carry another source and are ignored.
const Capture = struct {
    deferred_events: usize = 0,
    deferred_slots: [10]u8 = [_]u8{0} ** 10,
    malformed: usize = 0,

    fn emit(raw: *anyopaque, _: cc.session_id.SessionId, event: cc.ui_event.CoreEvent) void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        switch (event) {
            .policy_decision => |decision| {
                if (!std.mem.eql(u8, decision.source, "recovery_allowance")) return;
                self.deferred_events += 1;
                if (!std.mem.eql(u8, decision.decision, "deferred") or decision.allowed) self.malformed += 1;
                const digit = decision.id[decision.id.len - 1];
                if (digit >= '0' and digit <= '9') self.deferred_slots[digit - '0'] += 1;
            },
            else => {},
        }
    }
    fn poll(_: *anyopaque, _: cc.session_id.SessionId) ?cc.ui_event.UiEvent {
        return null;
    }
};

const ToolResultView = struct {
    tool_use_id: []const u8,
    content: []const u8,
    is_error: bool,
};

/// The `tool_result` blocks of the last message of one captured request, in
/// the order the loop committed them.
fn toolResultsOfLastMessage(parsed: std.json.Value, out: []ToolResultView) ![]ToolResultView {
    const messages = parsed.object.get("messages") orelse return error.MissingMessages;
    const last = messages.array.items[messages.array.items.len - 1];
    const content = last.object.get("content") orelse return error.MissingContent;
    var n: usize = 0;
    for (content.array.items) |block| {
        const kind = block.object.get("type") orelse continue;
        if (!std.mem.eql(u8, kind.string, "tool_result")) continue;
        if (n == out.len) return error.TooManyToolResults;
        const is_error = if (block.object.get("is_error")) |flag| flag == .bool and flag.bool else false;
        out[n] = .{
            .tool_use_id = block.object.get("tool_use_id").?.string,
            .content = block.object.get("content").?.string,
            .is_error = is_error,
        };
        n += 1;
    }
    return out[0..n];
}

fn expectToolUseId(allocator: std.mem.Allocator, view: ToolResultView, prefix: []const u8, slot: usize) !void {
    const id = try std.fmt.allocPrint(allocator, "{s}{d}", .{ prefix, slot });
    defer allocator.free(id);
    try std.testing.expectEqualStrings(id, view.tool_use_id);
}

fn expectServedEnvelope(allocator: std.mem.Allocator, view: ToolResultView, slot: usize) !void {
    try std.testing.expect(!view.is_error);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, view.content, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings("metacodes.read-artifact.v1", parsed.value.object.get("schema_version").?.string);
    try std.testing.expectEqual(@as(i64, @intCast(slot * STRIDE)), parsed.value.object.get("offset").?.integer);
    try std.testing.expect(parsed.value.object.get("data").?.string.len > 0);
}

fn expectDeferredBody(allocator: std.mem.Allocator, view: ToolResultView, artifact_id: []const u8, slot: usize) !void {
    try std.testing.expect(view.is_error);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, view.content, .{});
    defer parsed.deinit();
    const body = parsed.value.object;
    try std.testing.expectEqualStrings("recovery_allowance_exhausted", body.get("error").?.string);
    try std.testing.expectEqualStrings(artifact_id, body.get("artifact_id").?.string);
    try std.testing.expectEqual(@as(i64, @intCast(slot * STRIDE)), body.get("offset").?.integer);
    try std.testing.expectEqual(ALLOWANCE_ON_200K, body.get("allowance_bytes").?.integer);
    try std.testing.expectEqual(CHARGED_WHEN_FULL, body.get("charged_bytes").?.integer);
    try std.testing.expect(body.get("hint").?.string.len > 0);
}

const Fixture = struct {
    tmp: std.testing.TmpDir,
    root_buffer: [std.fs.max_path_bytes]u8 = undefined,
    root_len: usize = 0,
    artifact_id: []u8,
    payload: []u8,

    /// The session root; a method rather than a stored slice so the fixture
    /// can be returned by value without leaving a pointer into a dead copy.
    fn root(self: *const Fixture) []const u8 {
        return self.root_buffer[0..self.root_len];
    }

    fn init(allocator: std.mem.Allocator) !Fixture {
        var self = Fixture{ .tmp = std.testing.tmpDir(.{}), .artifact_id = &.{}, .payload = &.{} };
        errdefer self.tmp.cleanup();
        self.root_len = try self.tmp.dir.realPath(std.testing.io, &self.root_buffer);
        self.payload = try allocator.alloc(u8, ARTIFACT_BYTES);
        errdefer allocator.free(self.payload);
        @memset(self.payload, 'x');
        const receipt = try cc.tool_result_artifact.persist(allocator, self.root(), self.payload);
        self.artifact_id = try allocator.dupe(u8, receipt.id());
        return self;
    }

    fn deinit(self: *Fixture, allocator: std.mem.Allocator) void {
        allocator.free(self.artifact_id);
        allocator.free(self.payload);
        self.tmp.cleanup();
    }
};

const Run = struct {
    io_runtime: std.Io.Threaded,
    client: cc.client_mod.Client,
    conversation: cc.conversation.Conversation,
    capture: Capture = .{},
    metrics: cc.tool_result_metrics.Metrics = .{},
    result: cc.agent_loop.RunResult = undefined,

    fn deinit(self: *Run) void {
        self.conversation.deinit();
        self.client.deinit();
        self.io_runtime.deinit();
    }
};

/// Drive the loop over the cassette behind `url` against `fixture.root()`; the
/// harness model maps to the 200K window (`Budget.fromModel(200_000)`:
/// per_result 25,000, per_turn 204,800, allowance 102,400).
fn runTurns(allocator: std.mem.Allocator, fixture: *const Fixture, url: []const u8, run: *Run, max_turns: u32) !void {
    run.io_runtime = std.Io.Threaded.init(allocator, .{});
    run.client = cc.client_mod.Client.initWithBaseUrl(allocator, run.io_runtime.io(), "test-key", "claude-sonnet-4-20250514", url);
    run.conversation = cc.conversation.Conversation.init(allocator);
    try run.conversation.appendText(.user, "recover the artifact in parallel");
    const permission = cc.permission.createContext(.bypass_permissions, allocator);
    const definitions = [_]cc.json_mod.ToolDefinition{
        .{ .name = "ReadArtifact", .description = "read a bounded artifact range", .input_schema = .{ .prop_specs = &.{.{ .name = "artifact_id", .type = "string" }}, .required = &.{"artifact_id"} } },
    };
    var dispatcher = Dispatcher{};
    const backend = cc.ui_backend.UiBackend{ .ctx = @ptrCast(&run.capture), .emit = Capture.emit, .poll = Capture.poll };
    run.result = try cc.agent_loop.run(
        &run.conversation,
        run.client.provider(),
        &definitions,
        &permission,
        .{
            .max_turns = max_turns,
            .tool_dispatcher = dispatcher.asDispatcher(),
            .artifact_root = fixture.root(),
            .tool_result_metrics = &run.metrics,
            .emit_tool_cards = true,
            .colorize = false,
        },
        &backend,
        allocator,
    );
}

test "L2 recovery allowance: nine parallel ReadArtifact calls on a 200K window serve four and defer five, in slot order" {
    // Mutations this must catch: a changed divisor (counts), deferral in
    // reverse slot order (offsets of the served results), deferred slots
    // executed anyway (data instead of the error body), events not emitted.
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init(allocator);
    defer fixture.deinit(allocator);

    const calls = try readCallsSse(allocator, "ra-", fixture.artifact_id, &.{ 0, 1, 2, 3, 4, 5, 6, 7, 8 });
    defer allocator.free(calls);
    const bodies = [_][]const u8{ calls, FINAL_SSE };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(allocator);
    defer allocator.free(url);

    var run: Run = undefined;
    run.capture = .{};
    run.metrics = .{};
    try runTurns(allocator, &fixture, url, &run, 5);
    defer run.deinit();
    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, run.result.stop_reason);
    try std.testing.expectEqual(@as(usize, 2), server.requestCount());

    const follow_up = (server.requestAt(1) orelse return error.MissingFollowUpRequest).body();
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, follow_up, .{});
    defer parsed.deinit();
    var views: [9]ToolResultView = undefined;
    const results = try toolResultsOfLastMessage(parsed.value, &views);
    try std.testing.expectEqual(@as(usize, 9), results.len);
    for (results, 0..) |view, slot| {
        try expectToolUseId(allocator, view, "ra-", slot);
        if (slot < SERVED_PER_TURN) {
            try expectServedEnvelope(allocator, view, slot);
        } else {
            try expectDeferredBody(allocator, view, fixture.artifact_id, slot);
        }
    }

    try std.testing.expectEqual(@as(usize, 5), run.capture.deferred_events);
    try std.testing.expectEqual(@as(usize, 0), run.capture.malformed);
    for (0..9) |slot| try std.testing.expectEqual(@as(u8, if (slot < SERVED_PER_TURN) 0 else 1), run.capture.deferred_slots[slot]);

    const observed = run.metrics.snapshot();
    try std.testing.expectEqual(@as(u64, SERVED_PER_TURN), observed.artifact_recovery_calls);
    try std.testing.expectEqual(@as(u64, 0), observed.budget_exhausted_count);
}

test "L2 recovery allowance: the allowance resets per turn, so deferred calls are served when re-issued" {
    // Turn 1 defers slots 4..8. Turn 2 re-issues those five: four fit again and
    // slot 8 is deferred once more (the allowance is per turn, not per
    // artifact). Turn 3 re-issues slot 8 alone and it is served.
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init(allocator);
    defer fixture.deinit(allocator);

    const first = try readCallsSse(allocator, "ra-", fixture.artifact_id, &.{ 0, 1, 2, 3, 4, 5, 6, 7, 8 });
    defer allocator.free(first);
    const second = try readCallsSse(allocator, "rb-", fixture.artifact_id, &.{ 4, 5, 6, 7, 8 });
    defer allocator.free(second);
    const third = try readCallsSse(allocator, "rc-", fixture.artifact_id, &.{8});
    defer allocator.free(third);
    const bodies = [_][]const u8{ first, second, third, FINAL_SSE };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(allocator);
    defer allocator.free(url);

    var run: Run = undefined;
    run.capture = .{};
    run.metrics = .{};
    try runTurns(allocator, &fixture, url, &run, 8);
    defer run.deinit();
    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, run.result.stop_reason);
    try std.testing.expectEqual(@as(usize, 4), server.requestCount());

    {
        const request = (server.requestAt(2) orelse return error.MissingSecondTurnRequest).body();
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, request, .{});
        defer parsed.deinit();
        var views: [9]ToolResultView = undefined;
        const results = try toolResultsOfLastMessage(parsed.value, &views);
        try std.testing.expectEqual(@as(usize, 5), results.len);
        for (results, 4..) |view, slot| {
            try expectToolUseId(allocator, view, "rb-", slot);
            if (slot < 4 + SERVED_PER_TURN) {
                try expectServedEnvelope(allocator, view, slot);
            } else {
                try expectDeferredBody(allocator, view, fixture.artifact_id, slot);
            }
        }
    }
    {
        const request = (server.requestAt(3) orelse return error.MissingThirdTurnRequest).body();
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, request, .{});
        defer parsed.deinit();
        var views: [9]ToolResultView = undefined;
        const results = try toolResultsOfLastMessage(parsed.value, &views);
        try std.testing.expectEqual(@as(usize, 1), results.len);
        try expectToolUseId(allocator, results[0], "rc-", 8);
        try expectServedEnvelope(allocator, results[0], 8);
    }

    // Five deferrals in turn 1, one in turn 2, none in turn 3.
    try std.testing.expectEqual(@as(usize, 6), run.capture.deferred_events);
    try std.testing.expectEqual(@as(u8, 2), run.capture.deferred_slots[8]);
    try std.testing.expectEqual(@as(u64, 4 + 4 + 1), run.metrics.snapshot().artifact_recovery_calls);
}

test "L2 recovery allowance: four calls fit and nothing is deferred" {
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init(allocator);
    defer fixture.deinit(allocator);

    const calls = try readCallsSse(allocator, "ra-", fixture.artifact_id, &.{ 0, 1, 2, 3 });
    defer allocator.free(calls);
    const bodies = [_][]const u8{ calls, FINAL_SSE };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(allocator);
    defer allocator.free(url);

    var run: Run = undefined;
    run.capture = .{};
    run.metrics = .{};
    try runTurns(allocator, &fixture, url, &run, 5);
    defer run.deinit();
    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, run.result.stop_reason);

    const follow_up = (server.requestAt(1) orelse return error.MissingFollowUpRequest).body();
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, follow_up, .{});
    defer parsed.deinit();
    var views: [9]ToolResultView = undefined;
    const results = try toolResultsOfLastMessage(parsed.value, &views);
    try std.testing.expectEqual(SERVED_PER_TURN, results.len);
    for (results, 0..) |view, slot| try expectServedEnvelope(allocator, view, slot);
    try std.testing.expectEqual(@as(usize, 0), run.capture.deferred_events);
    try std.testing.expectEqual(@as(u64, SERVED_PER_TURN), run.metrics.snapshot().artifact_recovery_calls);
}
