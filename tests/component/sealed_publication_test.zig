//! L2: a native tool's large result is sealed during execution and published
//! only when the batch commits (#45).
//!
//! Before this change `result_spool.finishCaptureAsBody` published into the
//! session CAS while the tool ran; a later host tool in the same batch
//! returning fatal left a durable, unreferenced blob behind. Now the tool layer
//! hands the agent loop a sealed handle, `executeSlots` completing without a
//! fatal is the commit boundary, and everything before it discards.

const std = @import("std");
const cc = @import("cc");
const harness = @import("harness");
const pfs = @import("platform").fs;
const pdir = @import("platform").dir;

/// Above `per_result_bytes` on the 200K window the harness model maps to
/// (25,000), so the tool layer seals instead of inlining; below the 64 KiB
/// ceiling `retainInlineAfterFailedPublish` allows when publication fails.
const SEALED_BYTES: usize = 40_000;
const TAIL_SENTINEL = "SEALED_TAIL_SENTINEL";

const FINAL_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"done\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"done\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

/// One assistant message carrying the named tool calls, all with `{}` input.
fn toolCallsSse(allocator: std.mem.Allocator, names: []const []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const w = &out.writer;
    try w.writeAll("data: {\"type\":\"message_start\",\"message\":{\"id\":\"tool\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n");
    for (names, 0..) |name, index| {
        try w.print(
            "data: {{\"type\":\"content_block_start\",\"index\":{d},\"content_block\":{{\"type\":\"tool_use\",\"id\":\"tu-{d}\",\"name\":\"{s}\",\"input\":{{}}}}}}\n\n" ++
                "data: {{\"type\":\"content_block_delta\",\"index\":{d},\"delta\":{{\"type\":\"input_json_delta\",\"partial_json\":\"{{}}\"}}}}\n\n" ++
                "data: {{\"type\":\"content_block_stop\",\"index\":{d}}}\n\n",
            .{ index, index, name, index, index },
        );
    }
    try w.writeAll("data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":1}}\n\n");
    try w.writeAll("data: {\"type\":\"message_stop\"}\n\n");
    return out.toOwnedSlice();
}

/// `SealedTool` finishes a capture the way native tools do (sealed above the
/// budget); `FatalTool` is a Host tool that returns fatal.
const Dispatcher = struct {
    fn dispatch(_: *const anyopaque, ctx: *const cc.tool_context.ToolContext, name: []const u8, _: []const u8) anyerror!cc.tool_context.ToolDispatchOutcome {
        if (std.mem.eql(u8, name, "FatalTool")) return .host_fatal;
        if (!std.mem.eql(u8, name, "SealedTool")) return .{ .host_rejected = null };
        var capture = try cc.tool_result_artifact.Capture.begin(ctx.allocator, ctx.artifact_root, cc.tool_result_artifact.MAX_ARTIFACT_BYTES);
        defer capture.deinit();
        const payload = try ctx.allocator.alloc(u8, SEALED_BYTES);
        defer ctx.allocator.free(payload);
        @memset(payload, 'x');
        @memcpy(payload[SEALED_BYTES - TAIL_SENTINEL.len ..], TAIL_SENTINEL);
        try capture.write(payload);
        try capture.seal();
        return .{ .ok = try cc.result_spool.finishCaptureAsBody(ctx.allocator, ctx.artifact_root, &capture, .text_utf8, true, ctx.result_budget) };
    }
    fn metadata(_: *const anyopaque, _: []const u8) ?cc.tool_context.ToolMeta {
        return .{ .kind = .host, .category = .execute, .replay = .never, .prefetch_safe = false };
    }
    fn nameAt(_: *const anyopaque, index: usize) ?[]const u8 {
        return switch (index) {
            0 => "SealedTool",
            1 => "FatalTool",
            else => null,
        };
    }
    fn asDispatcher(self: *const @This()) cc.tool_context.ToolDispatcher {
        return .{ .ctx = @ptrCast(self), .dispatchFn = dispatch, .metadataFn = metadata, .nameAtFn = nameAt };
    }
};

const Sink = struct {
    fn emit(_: *anyopaque, _: cc.session_id.SessionId, _: cc.ui_event.CoreEvent) void {}
    fn poll(_: *anyopaque, _: cc.session_id.SessionId) ?cc.ui_event.UiEvent {
        return null;
    }
};

/// Entries in `directory` other than `.`/`..`; a missing directory is empty.
fn countEntries(allocator: std.mem.Allocator, directory: []const u8) !usize {
    const directory_z = try allocator.dupeZ(u8, directory);
    defer allocator.free(directory_z);
    var iterator = pdir.open(directory_z.ptr) orelse return 0;
    defer pdir.close(&iterator);
    var count: usize = 0;
    while (pdir.next(&iterator)) |entry| {
        if (std.mem.eql(u8, entry.name, ".") or std.mem.eql(u8, entry.name, "..")) continue;
        count += 1;
    }
    return count;
}

/// The mock quota exhaustion the MCP e2e suite uses: one sparse file the size
/// of the whole session allowance inside the CAS directory.
fn fillSessionArtifactQuota(allocator: std.mem.Allocator, root: []const u8) !void {
    _ = try cc.tool_result_artifact.persist(allocator, root, "seed");
    const filler = try std.fmt.allocPrintSentinel(allocator, "{s}/tool-results/sha256/quota-fixture.blob", .{root}, 0);
    defer allocator.free(filler);
    const fd = pfs.open(filler.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .NOFOLLOW = true }, 0o600);
    if (fd < 0) return error.QuotaFixtureOpenFailed;
    defer _ = pfs.close(fd);
    try pfs.setSize(fd, cc.tool_result_artifact.MAX_SESSION_BYTES);
}

const Fixture = struct {
    tmp: std.testing.TmpDir,
    root_buffer: [std.fs.max_path_bytes]u8 = undefined,
    root_len: usize = 0,
    cas_dir: []u8,
    spool_dir: []u8,

    fn init(allocator: std.mem.Allocator) !Fixture {
        var self = Fixture{ .tmp = std.testing.tmpDir(.{}), .cas_dir = &.{}, .spool_dir = &.{} };
        errdefer self.tmp.cleanup();
        self.root_len = try self.tmp.dir.realPath(std.testing.io, &self.root_buffer);
        self.cas_dir = try std.fmt.allocPrint(allocator, "{s}/tool-results/sha256", .{self.root()});
        errdefer allocator.free(self.cas_dir);
        self.spool_dir = try std.fmt.allocPrint(allocator, "{s}/tool-results/spool", .{self.root()});
        return self;
    }

    fn root(self: *const Fixture) []const u8 {
        return self.root_buffer[0..self.root_len];
    }

    fn deinit(self: *Fixture, allocator: std.mem.Allocator) void {
        allocator.free(self.cas_dir);
        allocator.free(self.spool_dir);
        self.tmp.cleanup();
    }
};

const Run = struct {
    io_runtime: std.Io.Threaded,
    client: cc.client_mod.Client,
    conversation: cc.conversation.Conversation,
    metrics: cc.tool_result_metrics.Metrics = .{},
    sink_state: u8 = 0,

    fn deinit(self: *Run) void {
        self.conversation.deinit();
        self.client.deinit();
        self.io_runtime.deinit();
    }
};

fn runLoop(allocator: std.mem.Allocator, fixture: *const Fixture, url: []const u8, run: *Run) !cc.agent_loop.RunResult {
    run.io_runtime = std.Io.Threaded.init(allocator, .{});
    run.client = cc.client_mod.Client.initWithBaseUrl(allocator, run.io_runtime.io(), "test-key", "claude-sonnet-4-20250514", url);
    run.conversation = cc.conversation.Conversation.init(allocator);
    try run.conversation.appendText(.user, "produce a large result");
    const permission = cc.permission.createContext(.bypass_permissions, allocator);
    const definitions = [_]cc.json_mod.ToolDefinition{
        .{ .name = "SealedTool", .description = "returns a large native result", .input_schema = .{} },
        .{ .name = "FatalTool", .description = "a host tool that fails fatally", .input_schema = .{} },
    };
    var dispatcher = Dispatcher{};
    const backend = cc.ui_backend.UiBackend{ .ctx = @ptrCast(&run.sink_state), .emit = Sink.emit, .poll = Sink.poll };
    return cc.agent_loop.run(
        &run.conversation,
        run.client.provider(),
        &definitions,
        &permission,
        .{
            .max_turns = 5,
            .tool_dispatcher = dispatcher.asDispatcher(),
            .artifact_root = fixture.root(),
            .tool_result_metrics = &run.metrics,
            .emit_tool_cards = false,
            .colorize = false,
        },
        &backend,
        allocator,
    );
}

fn lastUserContent(allocator: std.mem.Allocator, body: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, allocator, body, .{});
}

/// The single `tool_result` block of the last message of a request.
const ToolResultView = struct { content: []const u8, is_error: bool };

fn onlyToolResult(parsed: std.json.Value) !ToolResultView {
    const messages = parsed.object.get("messages") orelse return error.MissingMessages;
    const last = messages.array.items[messages.array.items.len - 1];
    const content = last.object.get("content") orelse return error.MissingContent;
    var found: ?ToolResultView = null;
    for (content.array.items) |block| {
        const kind = block.object.get("type") orelse continue;
        if (!std.mem.eql(u8, kind.string, "tool_result")) continue;
        if (found != null) return error.MoreThanOneToolResult;
        const is_error = if (block.object.get("is_error")) |flag| flag == .bool and flag.bool else false;
        found = .{ .content = block.object.get("content").?.string, .is_error = is_error };
    }
    return found orelse error.NoToolResult;
}

test "L2 sealed publication: a fatal sibling in the same batch leaves no blob and no temp file" {
    // Mutation this must catch: publishing at execution time again (the blob
    // would exist), or a Slot.deinit that forgets the handle (temp file left).
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init(allocator);
    defer fixture.deinit(allocator);
    const calls = try toolCallsSse(allocator, &.{ "SealedTool", "FatalTool" });
    defer allocator.free(calls);
    const bodies = [_][]const u8{ calls, FINAL_SSE };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(allocator);
    defer allocator.free(url);

    var run: Run = undefined;
    run.metrics = .{};
    run.sink_state = 0;
    const outcome = runLoop(allocator, &fixture, url, &run);
    defer run.deinit();
    try std.testing.expectError(error.HostToolFatal, outcome);

    try std.testing.expectEqual(@as(usize, 0), try countEntries(allocator, fixture.cas_dir));
    try std.testing.expectEqual(@as(usize, 0), try countEntries(allocator, fixture.spool_dir));
    // The provider never saw a second request: the turn ended at the fatal.
    try std.testing.expectEqual(@as(usize, 1), server.requestCount());
}

test "L2 sealed publication: a batch that commits publishes the blob the envelope names" {
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init(allocator);
    defer fixture.deinit(allocator);
    const calls = try toolCallsSse(allocator, &.{"SealedTool"});
    defer allocator.free(calls);
    const bodies = [_][]const u8{ calls, FINAL_SSE };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(allocator);
    defer allocator.free(url);

    var run: Run = undefined;
    run.metrics = .{};
    run.sink_state = 0;
    const result = try runLoop(allocator, &fixture, url, &run);
    defer run.deinit();
    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, result.stop_reason);

    // Exactly one blob, no temp file, and the next request carries an
    // artifact envelope whose id resolves to that blob.
    try std.testing.expectEqual(@as(usize, 1), try countEntries(allocator, fixture.cas_dir));
    try std.testing.expectEqual(@as(usize, 0), try countEntries(allocator, fixture.spool_dir));
    const follow_up = (server.requestAt(1) orelse return error.MissingFollowUpRequest).body();
    var parsed = try lastUserContent(allocator, follow_up);
    defer parsed.deinit();
    const tool_result = try onlyToolResult(parsed.value);
    try std.testing.expect(!tool_result.is_error);
    var envelope = try std.json.parseFromSlice(std.json.Value, allocator, tool_result.content, .{});
    defer envelope.deinit();
    try std.testing.expectEqualStrings("artifact", envelope.value.object.get("projection").?.string);
    const artifact_id = envelope.value.object.get("artifact_id").?.string;
    var chunk = try cc.tool_result_artifact.readChunk(allocator, fixture.root(), artifact_id, SEALED_BYTES - TAIL_SENTINEL.len, TAIL_SENTINEL.len);
    defer chunk.deinit();
    try std.testing.expectEqualStrings(TAIL_SENTINEL, chunk.bytes);
    try std.testing.expectEqual(@as(u64, SEALED_BYTES), chunk.total_bytes);
}

test "L2 sealed publication: a publication that fails at commit degrades like the tool layer used to, and leaves no temp file" {
    // Quota is full before the turn: the commit-boundary publish fails, the
    // bytes fall back inline under the 64 KiB ceiling (the same policy the
    // tool layer applied at execution time), projection then does what it
    // does with an over-budget inline result, and nothing durable is added.
    const allocator = std.testing.allocator;
    var fixture = try Fixture.init(allocator);
    defer fixture.deinit(allocator);
    try fillSessionArtifactQuota(allocator, fixture.root());
    const before = try countEntries(allocator, fixture.cas_dir);
    const calls = try toolCallsSse(allocator, &.{"SealedTool"});
    defer allocator.free(calls);
    const bodies = [_][]const u8{ calls, FINAL_SSE };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(allocator);
    defer allocator.free(url);

    var run: Run = undefined;
    run.metrics = .{};
    run.sink_state = 0;
    const result = try runLoop(allocator, &fixture, url, &run);
    defer run.deinit();
    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, result.stop_reason);

    try std.testing.expectEqual(before, try countEntries(allocator, fixture.cas_dir));
    try std.testing.expectEqual(@as(usize, 0), try countEntries(allocator, fixture.spool_dir));
    const follow_up = (server.requestAt(1) orelse return error.MissingFollowUpRequest).body();
    var parsed = try lastUserContent(allocator, follow_up);
    defer parsed.deinit();
    const tool_result = try onlyToolResult(parsed.value);
    // Not a tool error: the result was retained and projected, not lost.
    try std.testing.expect(!tool_result.is_error);
}
