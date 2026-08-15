//! L2 组件测试:大工具结果落盘(批1C,对齐 cc toolResultStorage)。

const std = @import("std");
const cc = @import("cc");
const harness = @import("harness");
const pfs = @import("platform").fs; // 可移植文件 IO(std.c.open 的 O 在 Windows 是 void)

const storage = cc.tool_result_storage;

test "L2 落盘: 小结果不落盘(返 null)" {
    const a = std.testing.allocator;
    const r = try storage.maybePersist(a, "Grep", "small output", "/tmp/cc-trs-home");
    try std.testing.expect(r == null);
}

test "L2 落盘: 超阈值落盘 → preview+path,文件含全量" {
    const a = std.testing.allocator;
    _ = std.c.mkdir("/tmp/cc-trs-home", 0o755);
    // 造一个 > 50000 字符的结果
    const big = try a.alloc(u8, 60_000);
    defer a.free(big);
    @memset(big, 'X');
    @memcpy(big[0..6], "HEADER");

    const r = (try storage.maybePersist(a, "Grep", big, "/tmp/cc-trs-home")) orelse return error.ShouldPersist;
    defer a.free(r);
    try std.testing.expect(std.mem.indexOf(u8, r, "\"persisted\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, r, "\"original_bytes\":60000") != null);
    try std.testing.expect(std.mem.indexOf(u8, r, "HEADER") != null); // preview 含开头
    try std.testing.expect(std.mem.indexOf(u8, r, "/tmp/cc-trs-home/.metacodes/tool-results/") != null);

    // 落盘文件确实含全量(解析出 path,读回比对长度)
    const key = "\"path\":\"";
    const i = std.mem.indexOf(u8, r, key).? + key.len;
    const j = std.mem.indexOfScalarPos(u8, r, i, '"').?;
    const path = try a.dupeZ(u8, r[i..j]);
    defer a.free(path);
    const fd = pfs.open(path.ptr, .{ .ACCMODE = .RDONLY }, 0);
    try std.testing.expect(fd >= 0);
    defer pfs.close(fd);
    var total: usize = 0;
    var buf: [8192]u8 = undefined;
    while (true) {
        const n = pfs.read(fd, &buf);
        if (n <= 0) break;
        total += @intCast(n);
    }
    try std.testing.expectEqual(@as(usize, 60_000), total);
    _ = std.c.unlink(path.ptr);
}

test "L2 落盘: home_dir 空 → 降级 inline 截断(不崩)" {
    const a = std.testing.allocator;
    const big = try a.alloc(u8, 60_000);
    defer a.free(big);
    @memset(big, 'Y');
    const r = (try storage.maybePersist(a, "Grep", big, "")) orelse return error.ShouldTruncate;
    defer a.free(r);
    try std.testing.expect(std.mem.indexOf(u8, r, "\"truncated\":true") != null);
    try std.testing.expect(r.len < 60_000); // 截断了
}

test "L2 落盘: Read 工具不落盘(自限,maxResultChars=max)" {
    try std.testing.expectEqual(std.math.maxInt(usize), storage.maxResultChars("Read"));
    try std.testing.expectEqual(storage.DEFAULT_MAX_RESULT_CHARS, storage.maxResultChars("Grep"));
}

test "L2 落盘: persistForced 无视阈值强制落盘小结果" {
    const a = std.testing.allocator;
    _ = std.c.mkdir("/tmp/cc-trs-home", 0o755);
    // 小结果(< 阈值),maybePersist 不落盘,但 persistForced 强制落盘
    try std.testing.expect((try storage.maybePersist(a, "Grep", "tiny", "/tmp/cc-trs-home")) == null);
    const r = (try storage.persistForced(a, "Grep", "tiny but forced", "/tmp/cc-trs-home")) orelse return error.ShouldPersist;
    defer a.free(r);
    try std.testing.expect(std.mem.indexOf(u8, r, "\"persisted\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, r, "tiny but forced") != null);
}

const FINAL_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"done\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"done\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

fn toolUseSse(allocator: std.mem.Allocator, id: []const u8, name: []const u8, input: []const u8) ![]u8 {
    const encoded_input = try std.json.Stringify.valueAlloc(allocator, input, .{});
    defer allocator.free(encoded_input);
    return std.fmt.allocPrint(
        allocator,
        "data: {{\"type\":\"message_start\",\"message\":{{\"id\":\"tool\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{{\"input_tokens\":1,\"output_tokens\":1}}}}}}\n\n" ++
            "data: {{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{{\"type\":\"tool_use\",\"id\":\"{s}\",\"name\":\"{s}\",\"input\":{{}}}}}}\n\n" ++
            "data: {{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{{\"type\":\"input_json_delta\",\"partial_json\":{s}}}}}\n\n" ++
            "data: {{\"type\":\"content_block_stop\",\"index\":0}}\n\n" ++
            "data: {{\"type\":\"message_delta\",\"delta\":{{\"stop_reason\":\"tool_use\"}},\"usage\":{{\"output_tokens\":1}}}}\n\n" ++
            "data: {{\"type\":\"message_stop\"}}\n\n",
        .{ id, name, encoded_input },
    );
}

fn toolResultMessage(allocator: std.mem.Allocator, content: []const u8) !cc.core_message.Message {
    const blocks = try allocator.alloc(cc.core_message.Block, 1);
    errdefer allocator.free(blocks);
    const tool_use_id = try allocator.dupe(u8, "resume-tool-1");
    errdefer allocator.free(tool_use_id);
    blocks[0] = .{ .tool_result = .{ .tool_use_id = tool_use_id, .content = content, .is_error = false } };
    return .{ .role = .user, .blocks = blocks };
}

fn requestToolResultContent(root: std.json.Value, tool_use_id: []const u8) ?[]const u8 {
    if (root != .object) return null;
    const messages = root.object.get("messages") orelse return null;
    if (messages != .array) return null;
    for (messages.array.items) |message| {
        if (message != .object) continue;
        const content = message.object.get("content") orelse continue;
        if (content != .array) continue;
        for (content.array.items) |block| {
            if (block != .object) continue;
            const kind = block.object.get("type") orelse continue;
            const id = block.object.get("tool_use_id") orelse continue;
            const body = block.object.get("content") orelse continue;
            if (kind == .string and id == .string and body == .string and
                std.mem.eql(u8, kind.string, "tool_result") and
                std.mem.eql(u8, id.string, tool_use_id)) return body.string;
        }
    }
    return null;
}

test "L2 runner projects after raw UI observation and recovers artifact on the next tool turn" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];

    const padding = try allocator.alloc(u8, 70_000);
    defer allocator.free(padding);
    @memset(padding, 'x');
    const payload = try std.fmt.allocPrint(
        allocator,
        "{{\"rows\":[1,2,3],\"padding\":\"{s}\",\"tail\":\"TAIL_SENTINEL\"}}",
        .{padding},
    );
    defer allocator.free(payload);
    const digest = cc.tool_result_artifact.sha256Hex(payload);
    const artifact_id = try std.fmt.allocPrint(allocator, "sha256:{s}", .{digest[0..]});
    defer allocator.free(artifact_id);
    const read_input = try std.fmt.allocPrint(
        allocator,
        "{{\"artifact_id\":\"{s}\",\"offset\":{d},\"limit\":128}}",
        .{ artifact_id, payload.len - 128 },
    );
    defer allocator.free(read_input);
    const first_sse = try toolUseSse(allocator, "big-1", "BigStructured", "{}");
    defer allocator.free(first_sse);
    const second_sse = try toolUseSse(allocator, "read-1", "ReadArtifact", read_input);
    defer allocator.free(second_sse);
    const responses = [_][]const u8{ first_sse, second_sse, FINAL_SSE };
    var server = try harness.MockServer.startCassette(&responses, 0);
    defer server.stop();
    const url = try server.urlOwned(allocator);
    defer allocator.free(url);

    const Dispatcher = struct {
        payload: []const u8,

        fn dispatch(raw: *const anyopaque, ctx: *const cc.tool_context.ToolContext, name: []const u8, args: []const u8) anyerror!cc.tool_context.ToolDispatchOutcome {
            const self: *const @This() = @ptrCast(@alignCast(raw));
            if (std.mem.eql(u8, name, "BigStructured"))
                return .{ .ok = try ctx.allocator.dupe(u8, self.payload) };
            if (std.mem.eql(u8, name, "ReadArtifact"))
                return .{ .ok = try cc.read_artifact.execute(ctx, args) };
            return .{ .host_rejected = null };
        }
        fn prefetchSafe(_: *const anyopaque, name: []const u8) bool {
            return std.mem.eql(u8, name, "ReadArtifact");
        }
        fn nameAt(_: *const anyopaque, index: usize) ?[]const u8 {
            return switch (index) {
                0 => "BigStructured",
                1 => "ReadArtifact",
                else => null,
            };
        }
        fn hostSync(_: *const anyopaque, _: []const u8) bool {
            return true;
        }
        fn asDispatcher(self: *const @This()) cc.tool_context.ToolDispatcher {
            return .{
                .ctx = @ptrCast(self),
                .dispatchFn = dispatch,
                .prefetchSafeFn = prefetchSafe,
                .nameAtFn = nameAt,
                .hostSyncFn = hostSync,
            };
        }
    };
    const Capture = struct {
        raw_big_bytes: usize = 0,
        raw_tail_seen: bool = false,
        fn emit(raw: *anyopaque, _: cc.session_id.SessionId, event: cc.ui_event.CoreEvent) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            switch (event) {
                .tool_result => |result| if (std.mem.eql(u8, result.name, "BigStructured")) {
                    self.raw_big_bytes = result.content.len;
                    self.raw_tail_seen = std.mem.indexOf(u8, result.content, "TAIL_SENTINEL") != null;
                },
                else => {},
            }
        }
        fn poll(_: *anyopaque, _: cc.session_id.SessionId) ?cc.ui_event.UiEvent {
            return null;
        }
    };

    var io_runtime = std.Io.Threaded.init(allocator, .{});
    defer io_runtime.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(allocator, io_runtime.io(), "test-key", "claude-sonnet-4-20250514", url);
    defer client.deinit();
    var conversation = cc.conversation.Conversation.init(allocator);
    defer conversation.deinit();
    try conversation.appendText(.user, "produce and recover the structured result");
    const permission = cc.permission.createContext(.bypass_permissions, allocator);
    const definitions = [_]cc.json_mod.ToolDefinition{
        .{ .name = "BigStructured", .description = "return a large structured fixture", .input_schema = .{} },
        .{ .name = "ReadArtifact", .description = "read a bounded artifact range", .input_schema = .{ .prop_specs = &.{.{ .name = "artifact_id", .type = "string" }}, .required = &.{"artifact_id"} } },
    };
    var dispatcher = Dispatcher{ .payload = payload };
    var capture = Capture{};
    var metrics = cc.tool_result_metrics.Metrics{};
    const backend = cc.ui_backend.UiBackend{ .ctx = @ptrCast(&capture), .emit = Capture.emit, .poll = Capture.poll };
    const result = try cc.agent_loop.run(
        &conversation,
        client.provider(),
        &definitions,
        &permission,
        .{
            .max_turns = 5,
            .tool_dispatcher = dispatcher.asDispatcher(),
            .artifact_root = root,
            .tool_result_metrics = &metrics,
            .emit_tool_cards = true,
            .colorize = false,
        },
        &backend,
        allocator,
    );
    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, result.stop_reason);
    try std.testing.expectEqual(@as(usize, 3), server.requestCount());
    try std.testing.expectEqual(payload.len, capture.raw_big_bytes);
    try std.testing.expect(capture.raw_tail_seen);
    const observed = metrics.snapshot();
    try std.testing.expectEqual(@as(u64, 1), observed.artifact_spill_count);
    try std.testing.expectEqual(@as(u64, 1), observed.artifact_recovery_calls);
    try std.testing.expect(observed.raw_bytes >= payload.len);

    const follow_up = (server.requestAt(1) orelse return error.MissingFollowUpRequest).body();
    try std.testing.expect(std.mem.indexOf(u8, follow_up, cc.result_projection.SCHEMA) != null);
    try std.testing.expect(std.mem.indexOf(u8, follow_up, artifact_id) != null);
    try std.testing.expect(std.mem.indexOf(u8, follow_up, root) == null);
    // The bounded projection carries both ends; exact middle bytes remain
    // recoverable only through ReadArtifact.
    try std.testing.expect(std.mem.indexOf(u8, follow_up, "TAIL_SENTINEL") != null);

    const final_request = (server.requestAt(2) orelse return error.MissingFinalRequest).body();
    try std.testing.expect(std.mem.indexOf(u8, final_request, "metacodes.read-artifact.v1") != null);
    try std.testing.expect(std.mem.indexOf(u8, final_request, "TAIL_SENTINEL") != null);
    var follow_json = try std.json.parseFromSlice(std.json.Value, allocator, follow_up, .{});
    defer follow_json.deinit();
    var final_json = try std.json.parseFromSlice(std.json.Value, allocator, final_request, .{});
    defer final_json.deinit();
    try std.testing.expectEqualStrings(
        requestToolResultContent(follow_json.value, "big-1") orelse return error.MissingProjectedResult,
        requestToolResultContent(final_json.value, "big-1") orelse return error.MissingStableProjectedResult,
    );

    const projected = conversation.messages.items[2].blocks[0].tool_result.content;
    try std.testing.expect(cc.result_projection.isRecoverableEnvelope(projected));
    var envelope = try std.json.parseFromSlice(std.json.Value, allocator, projected, .{});
    defer envelope.deinit();
    try std.testing.expect(envelope.value.object.get("recoverable").?.bool);
    var recovered = try cc.tool_result_artifact.readChunk(allocator, root, artifact_id, 0, 32 * 1024);
    defer recovered.deinit();
    try std.testing.expect(std.mem.startsWith(u8, recovered.bytes, "{\"rows\""));
}

test "L2 transcript resume preserves artifact capability without embedding the raw body" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];

    const padding = try allocator.alloc(u8, 70_000);
    defer allocator.free(padding);
    @memset(padding, 'r');
    const payload = try std.fmt.allocPrint(allocator, "{{\"rows\":[1],\"padding\":\"{s}\",\"tail\":\"RESUME_TAIL\"}}", .{padding});
    defer allocator.free(payload);
    const digest = cc.tool_result_artifact.sha256Hex(payload);
    const artifact_id = try std.fmt.allocPrint(allocator, "sha256:{s}", .{digest[0..]});
    defer allocator.free(artifact_id);

    var projected: []const u8 = try allocator.dupe(u8, payload);
    var projected_owned = true;
    defer if (projected_owned) allocator.free(@constCast(projected));
    var items = [_]cc.result_projection.Item{.{ .tool_name = "KgContext", .content = &projected, .is_error = false }};
    const stats = try cc.result_projection.project(allocator, &items, .{
        .session_root = root,
        .per_result_bytes = 8 * 1024,
        .per_turn_bytes = 32 * 1024,
    });
    try std.testing.expectEqual(@as(usize, 1), stats.artifact_spill_count);

    var conversation = cc.conversation.Conversation.init(allocator);
    defer conversation.deinit();
    const message = try toolResultMessage(allocator, projected);
    conversation.append(message) catch |err| {
        message.deinit(allocator);
        projected_owned = false;
        return err;
    };
    projected_owned = false;

    var writer = cc.transcript.Writer.openExisting(allocator, try allocator.dupe(u8, root), "fixture", 0);
    writer.flush(&conversation);
    writer.deinit();

    var resumed = cc.conversation.Conversation.init(allocator);
    defer resumed.deinit();
    try cc.transcript.loadTranscript(&resumed, root, allocator);
    const resumed_content = resumed.messages.items[0].blocks[0].tool_result.content;
    try std.testing.expect(cc.result_projection.isRecoverableEnvelope(resumed_content));
    try std.testing.expect(std.mem.indexOf(u8, resumed_content, "RESUME_TAIL") != null);
    try std.testing.expect(resumed_content.len < payload.len);
    try std.testing.expect(resumed_content.len < 8 * 1024);

    var tail = try cc.tool_result_artifact.readChunk(allocator, root, artifact_id, payload.len - 64, 64);
    defer tail.deinit();
    try std.testing.expect(std.mem.indexOf(u8, tail.bytes, "RESUME_TAIL") != null);
}
