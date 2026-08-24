//! L2 组件测试：统一 Tool Result CAS 投影、恢复、resume 与 prompt-cache 稳定性。

const std = @import("std");
const cc = @import("cc");
const harness = @import("harness");
const pfs = @import("platform").fs;

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

fn expectJsonFieldEqual(
    allocator: std.mem.Allocator,
    first_bytes: []const u8,
    second_bytes: []const u8,
    field: []const u8,
) !void {
    var first = try std.json.parseFromSlice(std.json.Value, allocator, first_bytes, .{});
    defer first.deinit();
    var second = try std.json.parseFromSlice(std.json.Value, allocator, second_bytes, .{});
    defer second.deinit();
    const first_field = first.value.object.get(field) orelse return error.MissingCacheField;
    const second_field = second.value.object.get(field) orelse return error.MissingCacheField;
    const first_encoded = try std.json.Stringify.valueAlloc(allocator, first_field, .{});
    defer allocator.free(first_encoded);
    const second_encoded = try std.json.Stringify.valueAlloc(allocator, second_field, .{});
    defer allocator.free(second_encoded);
    try std.testing.expectEqualStrings(first_encoded, second_encoded);
}

/// Raw request JSON cannot be a literal prefix because a later request must
/// close and reopen its messages array. The provider-visible cache contract is
/// the ordered sequence inside that array: every previously emitted element
/// must remain byte-identical and new elements may appear only at the tail.
fn expectJsonArrayPrefix(
    allocator: std.mem.Allocator,
    first_bytes: []const u8,
    second_bytes: []const u8,
    field: []const u8,
) !void {
    var first = try std.json.parseFromSlice(std.json.Value, allocator, first_bytes, .{});
    defer first.deinit();
    var second = try std.json.parseFromSlice(std.json.Value, allocator, second_bytes, .{});
    defer second.deinit();
    const first_array = first.value.object.get(field) orelse return error.MissingCacheField;
    const second_array = second.value.object.get(field) orelse return error.MissingCacheField;
    if (first_array != .array or second_array != .array) return error.InvalidCacheField;
    try std.testing.expect(first_array.array.items.len <= second_array.array.items.len);
    for (first_array.array.items, 0..) |value, index| {
        const left = try std.json.Stringify.valueAlloc(allocator, value, .{});
        defer allocator.free(left);
        const right = try std.json.Stringify.valueAlloc(
            allocator,
            second_array.array.items[index],
            .{},
        );
        defer allocator.free(right);
        try std.testing.expectEqualStrings(left, right);
    }
}

fn expectOpenAiSystemEqual(
    allocator: std.mem.Allocator,
    first_bytes: []const u8,
    second_bytes: []const u8,
) !void {
    var first = try std.json.parseFromSlice(std.json.Value, allocator, first_bytes, .{});
    defer first.deinit();
    var second = try std.json.parseFromSlice(std.json.Value, allocator, second_bytes, .{});
    defer second.deinit();
    const first_system = first.value.object.get("messages").?.array.items[0];
    const second_system = second.value.object.get("messages").?.array.items[0];
    const first_encoded = try std.json.Stringify.valueAlloc(allocator, first_system, .{});
    defer allocator.free(first_encoded);
    const second_encoded = try std.json.Stringify.valueAlloc(allocator, second_system, .{});
    defer allocator.free(second_encoded);
    try std.testing.expectEqualStrings(first_encoded, second_encoded);
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
                return .{ .ok = cc.tools.ToolResultBody.initInline(try ctx.allocator.dupe(u8, self.payload)) };
            if (std.mem.eql(u8, name, "ReadArtifact"))
                return .{ .ok = cc.tools.ToolResultBody.initInline(try cc.read_artifact.execute(ctx, args)) };
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

    const first_request = (server.requestAt(0) orelse return error.MissingInitialRequest).body();
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
    var first_json = try std.json.parseFromSlice(std.json.Value, allocator, first_request, .{});
    defer first_json.deinit();
    var follow_json = try std.json.parseFromSlice(std.json.Value, allocator, follow_up, .{});
    defer follow_json.deinit();
    var final_json = try std.json.parseFromSlice(std.json.Value, allocator, final_request, .{});
    defer final_json.deinit();
    try std.testing.expectEqualStrings(
        requestToolResultContent(follow_json.value, "big-1") orelse return error.MissingProjectedResult,
        requestToolResultContent(final_json.value, "big-1") orelse return error.MissingStableProjectedResult,
    );
    try expectJsonArrayPrefix(allocator, first_request, follow_up, "messages");
    try expectJsonArrayPrefix(allocator, follow_up, final_request, "messages");
    // Artifact paging adds Conversation messages only. The Session's system
    // prefix and complete tool schema were frozen before request one, so the
    // provider cache prefix remains byte-identical across spill and recovery.
    const first_tools = try std.json.Stringify.valueAlloc(allocator, first_json.value.object.get("tools").?, .{});
    defer allocator.free(first_tools);
    const follow_tools = try std.json.Stringify.valueAlloc(allocator, follow_json.value.object.get("tools").?, .{});
    defer allocator.free(follow_tools);
    const final_tools = try std.json.Stringify.valueAlloc(allocator, final_json.value.object.get("tools").?, .{});
    defer allocator.free(final_tools);
    try std.testing.expectEqualStrings(first_tools, follow_tools);
    try std.testing.expectEqualStrings(first_tools, final_tools);
    const first_system_value = first_json.value.object.get("system");
    const follow_system_value = follow_json.value.object.get("system");
    const final_system_value = final_json.value.object.get("system");
    try std.testing.expect((first_system_value == null) == (follow_system_value == null));
    try std.testing.expect((first_system_value == null) == (final_system_value == null));
    if (first_system_value) |value| {
        const first_system = try std.json.Stringify.valueAlloc(allocator, value, .{});
        defer allocator.free(first_system);
        const follow_system = try std.json.Stringify.valueAlloc(allocator, follow_system_value.?, .{});
        defer allocator.free(follow_system);
        const final_system = try std.json.Stringify.valueAlloc(allocator, final_system_value.?, .{});
        defer allocator.free(final_system);
        try std.testing.expectEqualStrings(first_system, follow_system);
        try std.testing.expectEqualStrings(first_system, final_system);
    }

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

test "L2 dynamic registry preserves every ToolResultBody tag and the legacy bytes adapter" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    const Callbacks = struct {
        fn legacy(ctx: *const cc.tool_context.ToolContext, _: []const u8, _: ?*anyopaque) anyerror![]u8 {
            return ctx.allocator.dupe(u8, "legacy-inline");
        }

        fn inlineBody(ctx: *const cc.tool_context.ToolContext, _: []const u8, _: ?*anyopaque) anyerror!cc.tool_result.ToolResultBody {
            return cc.tool_result.ToolResultBody.initInline(try ctx.allocator.dupe(u8, "typed-inline"));
        }

        fn artifactBody(ctx: *const cc.tool_context.ToolContext, _: []const u8, _: ?*anyopaque) anyerror!cc.tool_result.ToolResultBody {
            var spool = try cc.tool_result_artifact.Spool.begin(ctx.allocator, ctx.artifact_root);
            defer spool.deinit();
            try spool.write("dynamic-artifact-head-");
            try spool.write(&([_]u8{'d'} ** (80 * 1024)));
            try spool.write("-dynamic-artifact-tail");
            return cc.tool_result.ToolResultBody.fromCompletedSpool(
                try spool.finish(),
                .text_utf8,
            );
        }

        fn structuredError(ctx: *const cc.tool_context.ToolContext, _: []const u8, _: ?*anyopaque) anyerror!cc.tool_result.ToolResultBody {
            return cc.tool_result.ToolResultBody.initStructuredError(
                ctx.allocator,
                "{\"error\":{\"code\":\"dynamic_fixture\",\"recoverable\":true}}",
            );
        }
    };

    var registry = cc.tools_dynamic.DynRegistry.init(allocator);
    defer registry.deinit();
    try registry.register("LegacyDynamic", "legacy adapter", &.{}, Callbacks.legacy, null, false);
    try registry.registerBody("InlineDynamic", "typed inline", &.{}, Callbacks.inlineBody, null, false);
    try registry.registerBody("ArtifactDynamic", "typed artifact", &.{}, Callbacks.artifactBody, null, false);
    try registry.registerBody("ErrorDynamic", "typed error", &.{}, Callbacks.structuredError, null, false);
    var ctx = cc.tool_context.ToolContext.simple(allocator);
    ctx.dyn_registry = &registry;
    ctx.artifact_root = root;

    var legacy = try cc.tools.dispatch(&ctx, "LegacyDynamic", "{}");
    defer legacy.deinit(allocator);
    try std.testing.expect(legacy == .ok and legacy.ok == .@"inline");
    try std.testing.expectEqualStrings("legacy-inline", legacy.ok.@"inline".bytes);

    var inline_result = try cc.tools.dispatch(&ctx, "InlineDynamic", "{}");
    defer inline_result.deinit(allocator);
    try std.testing.expect(inline_result == .ok and inline_result.ok == .@"inline");
    try std.testing.expectEqualStrings("typed-inline", inline_result.ok.@"inline".bytes);

    var structured = try cc.tools.dispatch(&ctx, "ErrorDynamic", "{}");
    defer structured.deinit(allocator);
    try std.testing.expect(structured == .ok and structured.ok == .structured_error);
    var structured_rendered = try structured.ok.render(allocator);
    defer structured_rendered.deinit(allocator);
    try std.testing.expect(structured_rendered.is_error);
    try std.testing.expect(std.mem.indexOf(u8, structured_rendered.bytes, "dynamic_fixture") != null);

    var artifact_result = try cc.tools.dispatch(&ctx, "ArtifactDynamic", "{}");
    defer artifact_result.deinit(allocator);
    try std.testing.expect(artifact_result == .ok and artifact_result.ok == .artifact);
    try std.testing.expect(artifact_result.ok.artifact.stored.bytes > 80 * 1024);
    var rendered = try artifact_result.ok.render(allocator);
    defer rendered.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, rendered.bytes, "ReadArtifact") != null);
    var recovered = try cc.tool_result_artifact.readChunk(
        allocator,
        root,
        artifact_result.ok.artifact.stored.id(),
        artifact_result.ok.artifact.stored.bytes - 32,
        32,
    );
    defer recovered.deinit();
    try std.testing.expect(std.mem.indexOf(u8, recovered.bytes, "dynamic-artifact-tail") != null);
}

test "L2 native Grep spools 17MiB from byte zero and keeps the cached tool prefix stable" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];
    const path = try std.fmt.allocPrintSentinel(allocator, "{s}/native-grep-17m.txt", .{root}, 0);
    defer allocator.free(path);

    const fd = pfs.open(path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true }, 0o600);
    if (fd < 0) return error.OpenFailed;
    defer _ = pfs.close(fd);
    var line: [1024]u8 = [_]u8{'x'} ** 1024;
    const marker = "NATIVE_BYTE_ZERO";
    @memcpy(line[0..marker.len], marker);
    line[line.len - 1] = '\n';
    var row: usize = 0;
    while (row < 17 * 1024) : (row += 1) {
        var written: usize = 0;
        while (written < line.len) {
            const count = pfs.write(fd, line[written..]);
            if (count <= 0) return error.WriteFailed;
            written += @intCast(count);
        }
    }

    const input = try std.fmt.allocPrint(
        allocator,
        "{{\"pattern\":\"NATIVE_BYTE_ZERO\",\"path\":\"{s}\",\"output_mode\":\"content\",\"head_limit\":0}}",
        .{path[0..path.len]},
    );
    defer allocator.free(input);
    const first_sse = try toolUseSse(allocator, "native-grep-1", "Grep", input);
    defer allocator.free(first_sse);
    const responses = [_][]const u8{ first_sse, FINAL_SSE };
    var server = try harness.MockServer.startCassette(&responses, 0);
    defer server.stop();
    const url = try server.urlOwned(allocator);
    defer allocator.free(url);

    var io_runtime = std.Io.Threaded.init(allocator, .{});
    defer io_runtime.deinit();
    var client = cc.client_mod.Client.initWithBaseUrl(allocator, io_runtime.io(), "test-key", "claude-sonnet-4-20250514", url);
    defer client.deinit();
    var conversation = cc.conversation.Conversation.init(allocator);
    defer conversation.deinit();
    try conversation.appendText(.user, "stream the native grep result");
    const permission = cc.permission.createContext(.bypass_permissions, allocator);
    const definitions = try cc.tools.toToolDefinitions(allocator);
    defer allocator.free(definitions);
    const Backend = struct {
        fn emit(_: *anyopaque, _: cc.session_id.SessionId, _: cc.ui_event.CoreEvent) void {}
        fn poll(_: *anyopaque, _: cc.session_id.SessionId) ?cc.ui_event.UiEvent {
            return null;
        }
    };
    var backend_ctx: u8 = 0;
    const backend = cc.ui_backend.UiBackend{ .ctx = @ptrCast(&backend_ctx), .emit = Backend.emit, .poll = Backend.poll };
    const result = try cc.agent_loop.run(
        &conversation,
        client.provider(),
        definitions,
        &permission,
        .{
            .max_turns = 3,
            .artifact_root = root,
            .colorize = false,
        },
        &backend,
        allocator,
    );
    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, result.stop_reason);
    try std.testing.expectEqual(@as(usize, 2), server.requestCount());

    var envelope_bytes: ?[]const u8 = null;
    for (conversation.messages.items) |message| {
        for (message.blocks) |block| switch (block) {
            .tool_result => |tool_result| {
                if (std.mem.eql(u8, tool_result.tool_use_id, "native-grep-1"))
                    envelope_bytes = tool_result.content;
            },
            else => {},
        };
    }
    const envelope_text = envelope_bytes orelse return error.MissingProjectedResult;
    try std.testing.expect(cc.result_projection.isRecoverableEnvelope(envelope_text));
    try std.testing.expect(envelope_text.len < 8 * 1024);
    var envelope = try std.json.parseFromSlice(std.json.Value, allocator, envelope_text, .{});
    defer envelope.deinit();
    const artifact_id = envelope.value.object.get("artifact_id").?.string;
    try std.testing.expect(envelope.value.object.get("original_bytes").?.integer > 17 * 1024 * 1024);
    try std.testing.expect(envelope.value.object.get("capture_complete").?.bool);
    var recovered = try cc.tool_result_artifact.readChunk(allocator, root, artifact_id, 0, 4096);
    defer recovered.deinit();
    try std.testing.expect(std.mem.indexOf(u8, recovered.bytes, "NATIVE_BYTE_ZERO") != null);

    var initial = try std.json.parseFromSlice(std.json.Value, allocator, (server.requestAt(0) orelse return error.MissingInitialRequest).body(), .{});
    defer initial.deinit();
    var follow = try std.json.parseFromSlice(std.json.Value, allocator, (server.requestAt(1) orelse return error.MissingFollowUpRequest).body(), .{});
    defer follow.deinit();
    const initial_tools = try std.json.Stringify.valueAlloc(allocator, initial.value.object.get("tools").?, .{});
    defer allocator.free(initial_tools);
    const follow_tools = try std.json.Stringify.valueAlloc(allocator, follow.value.object.get("tools").?, .{});
    defer allocator.free(follow_tools);
    try std.testing.expectEqualStrings(initial_tools, follow_tools);
}

test "L2 native WebFetch streams download transform and JSON into one typed artifact" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_len];

    const padding = try allocator.alloc(u8, 96 * 1024);
    defer allocator.free(padding);
    @memset(padding, 'w');
    const page = try std.fmt.allocPrint(allocator, "<html><body><h1>WEBFETCH_STREAM_HEAD</h1><p>{s}</p><footer>WEBFETCH_STREAM_TAIL</footer></body></html>", .{padding});
    defer allocator.free(page);
    var server = try harness.MockServer.start(page, 0);
    defer server.stop();
    const url = try server.urlOwned(allocator);
    defer allocator.free(url);
    const args = try std.fmt.allocPrint(allocator, "{{\"url\":\"{s}\"}}", .{url});
    defer allocator.free(args);

    var ctx = cc.tool_context.ToolContext.simple(allocator);
    ctx.artifact_root = root;
    var outcome = try cc.tools.dispatch(&ctx, "WebFetch", args);
    defer outcome.deinit(allocator);
    try std.testing.expect(outcome == .ok);
    try std.testing.expect(outcome.ok == .artifact);
    try std.testing.expect(outcome.ok.artifact.stored.bytes > 96 * 1024);
    try std.testing.expect(outcome.ok.artifact.stored.capture_complete);
    var head = try cc.tool_result_artifact.readChunk(
        allocator,
        root,
        outcome.ok.artifact.stored.id(),
        0,
        4096,
    );
    defer head.deinit();
    try std.testing.expect(std.mem.startsWith(u8, head.bytes, "{\"url\":"));
    try std.testing.expect(std.mem.indexOf(u8, head.bytes, "WEBFETCH_STREAM_HEAD") != null);
    var tail = try cc.tool_result_artifact.readChunk(
        allocator,
        root,
        outcome.ok.artifact.stored.id(),
        outcome.ok.artifact.stored.bytes - 4096,
        4096,
    );
    defer tail.deinit();
    try std.testing.expect(std.mem.indexOf(u8, tail.bytes, "WEBFETCH_STREAM_TAIL") != null);
}

test "L2 artifact paging preserves system and tool cache prefixes for every provider family" {
    const allocator = std.testing.allocator;
    const definitions = try cc.tools.toToolDefinitions(allocator);
    defer allocator.free(definitions);
    var has_read_artifact = false;
    for (definitions) |definition| if (std.mem.eql(u8, definition.name, "ReadArtifact")) {
        has_read_artifact = true;
        break;
    };
    try std.testing.expect(has_read_artifact);

    const initial = [_]cc.types_mod.ApiMessage{.{
        .role = .user,
        .content = &.{.{ .text = "inspect a large result" }},
    }};
    const after_spill = [_]cc.types_mod.ApiMessage{
        initial[0],
        .{
            .role = .user,
            .content = &.{.{ .text = "{\"projection\":\"artifact\",\"read\":{\"tool\":\"ReadArtifact\"}}" }},
        },
    };
    const system = "stable metacodes kernel prompt";

    const anthropic_first = try cc.api_request.serializeMessagesRequest(.{
        .model = "claude-sonnet-4",
        .messages = &initial,
        .system = system,
        .tools = definitions,
    }, allocator);
    defer allocator.free(anthropic_first);
    const anthropic_follow = try cc.api_request.serializeMessagesRequest(.{
        .model = "claude-sonnet-4",
        .messages = &after_spill,
        .system = system,
        .tools = definitions,
    }, allocator);
    defer allocator.free(anthropic_follow);
    try expectJsonFieldEqual(allocator, anthropic_first, anthropic_follow, "system");
    try expectJsonFieldEqual(allocator, anthropic_first, anthropic_follow, "tools");
    try expectJsonArrayPrefix(allocator, anthropic_first, anthropic_follow, "messages");

    const openai_first = try cc.api_openai.serializeOpenAIRequest(
        allocator,
        "deepseek-chat",
        &initial,
        system,
        definitions,
        null,
        null,
    );
    defer allocator.free(openai_first);
    const openai_follow = try cc.api_openai.serializeOpenAIRequest(
        allocator,
        "deepseek-chat",
        &after_spill,
        system,
        definitions,
        null,
        null,
    );
    defer allocator.free(openai_follow);
    try expectOpenAiSystemEqual(allocator, openai_first, openai_follow);
    try expectJsonFieldEqual(allocator, openai_first, openai_follow, "tools");
    try expectJsonArrayPrefix(allocator, openai_first, openai_follow, "messages");

    const gemini_first = try cc.api_gemini.serializeGeminiRequest(
        allocator,
        &initial,
        system,
        definitions,
        null,
        "gemini-2.5-pro",
        null,
        null,
    );
    defer allocator.free(gemini_first);
    const gemini_follow = try cc.api_gemini.serializeGeminiRequest(
        allocator,
        &after_spill,
        system,
        definitions,
        null,
        "gemini-2.5-pro",
        null,
        null,
    );
    defer allocator.free(gemini_follow);
    try expectJsonFieldEqual(allocator, gemini_first, gemini_follow, "systemInstruction");
    try expectJsonFieldEqual(allocator, gemini_first, gemini_follow, "tools");
    try expectJsonArrayPrefix(allocator, gemini_first, gemini_follow, "contents");
}

test "L2 BashOutput paging schema fields drive bounded registry dispatch" {
    if (@import("builtin").os.tag == .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const definition = cc.tools.getTool("BashOutput") orelse return error.MissingBashOutput;
    const specs = definition.input_schema.prop_specs orelse return error.MissingBashOutputSchema;
    const expected = [_][]const u8{
        "stdout",
        "stderr",
        "stdout_since_byte",
        "stderr_since_byte",
        "max_bytes",
    };
    for (expected) |name| {
        var found = false;
        for (specs) |spec| if (std.mem.eql(u8, spec.name, name)) {
            found = true;
            break;
        };
        try std.testing.expect(found);
    }

    var jobs = try cc.job_registry.JobRegistry.init(allocator);
    defer jobs.deinit();
    const job = try jobs.spawnBackground("printf 'ABCDEFGHIJ'; exit 0", null);
    cc.util_time.sleepMs(200);
    var ctx = cc.tools.ToolContext{ .allocator = allocator, .jobs = &jobs };
    var input_buffer: [256]u8 = undefined;
    const input = try std.fmt.bufPrint(
        &input_buffer,
        "{{\"job_id\":\"{s}\",\"stdout_since_byte\":3,\"stderr\":false,\"max_bytes\":3}}",
        .{job.id[0..]},
    );
    var outcome = try cc.tools.dispatch(&ctx, "BashOutput", input);
    defer outcome.deinit(allocator);
    const body = switch (outcome) {
        .ok => |value| value,
        else => return error.UnexpectedBashOutputOutcome,
    };
    const encoded = switch (body) {
        .@"inline" => |result| result.bytes,
        else => return error.UnexpectedBashOutputBody,
    };
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"stdout\":\"DEF\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"stdout_truncated\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "\"stderr\":") == null);

    const invalid = try std.fmt.bufPrint(
        &input_buffer,
        "{{\"job_id\":\"{s}\",\"max_bytes\":262145}}",
        .{job.id[0..]},
    );
    try std.testing.expectError(error.InvalidMaxBytes, cc.tools.dispatch(&ctx, "BashOutput", invalid));
}
