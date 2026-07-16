//! AgentSession reuses the existing synchronous UiRequester contract for both
//! AskUserQuestion and permission prompts. No AgentLoop or permission semantic
//! changes are needed for a Host-owned UI.

const std = @import("std");
const harness = @import("harness");
const cc = @import("cc");

const FINAL_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_2\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"done\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const ASK_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"tu_ask\",\"name\":\"AskUserQuestion\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"questions\\\":[{\\\"question\\\":\\\"Ship now?\\\",\\\"header\\\":\\\"Decision\\\",\\\"options\\\":[{\\\"label\\\":\\\"Yes\\\",\\\"description\\\":\\\"Proceed\\\"},{\\\"label\\\":\\\"No\\\",\\\"description\\\":\\\"Stop\\\"}],\\\"multiSelect\\\":false}]}\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

fn writeToolSse(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "data: {{\"type\":\"message_start\",\"message\":{{\"id\":\"msg_1\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{{\"input_tokens\":1,\"output_tokens\":1}}}}}}\n\n" ++
        "data: {{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{{\"type\":\"tool_use\",\"id\":\"tu_write\",\"name\":\"Write\",\"input\":{{}}}}}}\n\n" ++
        "data: {{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{{\"type\":\"input_json_delta\",\"partial_json\":\"{{\\\"file_path\\\":\\\"{s}\\\",\\\"content\\\":\\\"ui-permission-ok\\\"}}\"}}}}\n\n" ++
        "data: {{\"type\":\"content_block_stop\",\"index\":0}}\n\n" ++
        "data: {{\"type\":\"message_delta\",\"delta\":{{\"stop_reason\":\"tool_use\"}},\"usage\":{{\"output_tokens\":1}}}}\n\n" ++
        "data: {{\"type\":\"message_stop\"}}\n\n", .{path});
}

const UiProbe = struct {
    asks: usize = 0,
    permissions: usize = 0,
    session_id: cc.session_id.SessionId = .single,

    fn request(
        raw: *anyopaque,
        session_id: cc.session_id.SessionId,
        allocator: std.mem.Allocator,
        req: *const cc.ui_request.UiRequest,
        out: *cc.ui_request.UiResponse,
    ) anyerror!cc.ui_request.RequestOutcome {
        const self: *UiProbe = @ptrCast(@alignCast(raw));
        self.session_id = session_id;
        switch (req.*) {
            .ask_question => |questions| {
                self.asks += 1;
                try std.testing.expectEqual(@as(usize, 1), questions.len);
                try std.testing.expectEqualStrings("Ship now?", questions[0].question);
                const answers = try allocator.alloc([]const u8, 1);
                errdefer allocator.free(answers);
                answers[0] = try allocator.dupe(u8, "Yes");
                out.* = .{ .answers = answers };
            },
            .permission => |prompt| {
                self.permissions += 1;
                try std.testing.expectEqualStrings("Write", prompt.tool);
                out.* = .{ .permission = .allow_once };
            },
            else => return error.UnexpectedUiRequest,
        }
        return .answered;
    }

    fn requester(self: *UiProbe) cc.agent_session.UiRequester {
        return .{ .ctx = self, .requestFn = request };
    }
};

const Sink = struct {
    fn emit(_: *anyopaque, _: cc.session_id.SessionId, _: u64, _: cc.ui_event.CoreEvent) bool {
        return true;
    }
};

fn rootPath(tmp: *std.testing.TmpDir, buffer: []u8) ![]const u8 {
    const len = try tmp.dir.realPath(std.testing.io, buffer);
    // 归一正斜杠:此路径会拼进 SSE JSON 字符串字面量,Windows 反斜杠在 JSON 里是
    // 非法转义(\p 等)→ 工具拿到坏路径。CRT/工具层两种分隔符都认,统一 '/'。
    for (buffer[0..len]) |*c| {
        if (c.* == '\\') c.* = '/';
    }
    return buffer[0..len];
}

test "L2 AgentSession routes AskUserQuestion through the Host UiRequester" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buf);
    const bodies = [_][]const u8{ ASK_SSE, FINAL_SSE };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);

    var ui = UiProbe{};
    const runtime = try cc.agent_session.AgentRuntime.create(a, .{ .builtin_tools = &.{"AskUserQuestion"} });
    defer runtime.destroy() catch unreachable;
    const session = try runtime.createSession(.{
        .provider_kind = .anthropic,
        .api_key = "test-key",
        .model = "test-model",
        .base_url = url,
        .permission_mode = .bypass_permissions,
        .workspace = .{ .root = root },
        .allowed_tools = &.{"AskUserQuestion"},
        .ui_requester = ui.requester(),
    });
    defer session.destroy() catch unreachable;

    var sink_state: u8 = 0;
    const result = try session.runText(1, "ask me", 4, .{ .ctx = &sink_state, .emit = Sink.emit });
    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, result.stop_reason);
    try std.testing.expectEqual(@as(usize, 1), ui.asks);
    try std.testing.expectEqualSlices(u8, session.session_id.asSlice(), ui.session_id.asSlice());
    const body = (server.lastRequest() orelse return error.NoRequestCaptured).body();
    try std.testing.expect(std.mem.indexOf(u8, body, "Yes") != null);
}

test "L2 AgentSession routes permission prompts through the same Host UiRequester" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buf);
    const file_path = try std.fmt.allocPrintSentinel(a, "{s}/ui-write.txt", .{root}, 0);
    defer a.free(file_path);
    const tool_sse = try writeToolSse(a, file_path);
    defer a.free(tool_sse);
    const bodies = [_][]const u8{ tool_sse, FINAL_SSE };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);

    var ui = UiProbe{};
    const runtime = try cc.agent_session.AgentRuntime.create(a, .{ .builtin_tools = &.{"Write"} });
    defer runtime.destroy() catch unreachable;
    const session = try runtime.createSession(.{
        .provider_kind = .anthropic,
        .api_key = "test-key",
        .model = "test-model",
        .base_url = url,
        .permission_mode = .default,
        .workspace = .{ .root = root },
        .allowed_tools = &.{"Write"},
        .ui_requester = ui.requester(),
    });
    defer session.destroy() catch unreachable;

    var sink_state: u8 = 0;
    const result = try session.runText(1, "use host write", 4, .{ .ctx = &sink_state, .emit = Sink.emit });
    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, result.stop_reason);
    try std.testing.expectEqual(@as(usize, 1), ui.permissions);
    try std.testing.expect(std.c.access(file_path.ptr, std.c.F_OK) == 0);
}
