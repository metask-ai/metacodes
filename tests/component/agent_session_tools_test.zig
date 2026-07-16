//! AgentCore library vertical slice: Runtime catalog -> Session selection ->
//! provider advertisement -> admission -> built-in execution -> next request.

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

const GLOB_TOOL_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_glob\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"tu_glob\",\"name\":\"Glob\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"pattern\\\":\\\"*.workspace-probe\\\"}\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

fn readToolSse(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "data: {{\"type\":\"message_start\",\"message\":{{\"id\":\"msg_1\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{{\"input_tokens\":1,\"output_tokens\":1}}}}}}\n\n" ++
        "data: {{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{{\"type\":\"tool_use\",\"id\":\"tu_read\",\"name\":\"Read\",\"input\":{{}}}}}}\n\n" ++
        "data: {{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{{\"type\":\"input_json_delta\",\"partial_json\":\"{{\\\"file_path\\\":\\\"{s}\\\"}}\"}}}}\n\n" ++
        "data: {{\"type\":\"content_block_stop\",\"index\":0}}\n\n" ++
        "data: {{\"type\":\"message_delta\",\"delta\":{{\"stop_reason\":\"tool_use\"}},\"usage\":{{\"output_tokens\":1}}}}\n\n" ++
        "data: {{\"type\":\"message_stop\"}}\n\n", .{path});
}

fn bashToolSse(allocator: std.mem.Allocator, command: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "data: {{\"type\":\"message_start\",\"message\":{{\"id\":\"msg_1\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{{\"input_tokens\":1,\"output_tokens\":1}}}}}}\n\n" ++
        "data: {{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{{\"type\":\"tool_use\",\"id\":\"tu_bash\",\"name\":\"Bash\",\"input\":{{}}}}}}\n\n" ++
        "data: {{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{{\"type\":\"input_json_delta\",\"partial_json\":\"{{\\\"command\\\":\\\"{s}\\\"}}\"}}}}\n\n" ++
        "data: {{\"type\":\"content_block_stop\",\"index\":0}}\n\n" ++
        "data: {{\"type\":\"message_delta\",\"delta\":{{\"stop_reason\":\"tool_use\"}},\"usage\":{{\"output_tokens\":1}}}}\n\n" ++
        "data: {{\"type\":\"message_stop\"}}\n\n", .{command});
}

fn writeFile(path: [*:0]const u8, content: []const u8) !void {
    const fd = std.c.open(path, std.c.O{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o600));
    if (fd < 0) return error.OpenFailed;
    defer _ = std.c.close(fd);
    var written: usize = 0;
    while (written < content.len) {
        const n = std.c.write(fd, content.ptr + written, content.len - written);
        if (n <= 0) return error.WriteFailed;
        written += @intCast(n);
    }
}

const Sink = struct {
    fn emit(_: *anyopaque, _: cc.session_id.SessionId, _: u64, _: cc.ui_event.CoreEvent) bool {
        return true;
    }
};

test "L2 AgentSession resolves selected built-in file tools against its workspace" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buf);
    const root = root_buf[0..root_len];
    const file_path = try std.fmt.allocPrintSentinel(a, "{s}/sample.txt", .{root}, 0);
    defer a.free(file_path);
    try writeFile(file_path.ptr, "agentcore-tool-ok\n");
    const glob_probe_name = "agentcore-workspace-only-7f6e8ad1.workspace-probe";
    const glob_probe_path = try std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ root, glob_probe_name }, 0);
    defer a.free(glob_probe_path);
    try writeFile(glob_probe_path.ptr, "glob-workspace-ok\n");

    // The provider intentionally emits a relative path while the test process
    // runs outside `root`. AgentSession must bind it to the Host workspace.
    const tool_sse = try readToolSse(a, "sample.txt");
    defer a.free(tool_sse);
    const bodies = [_][]const u8{ tool_sse, GLOB_TOOL_SSE, FINAL_SSE };
    var srv = try harness.MockServer.startCassette(&bodies, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    const Runtime = cc.agent_session.AgentRuntime;
    const runtime = try Runtime.create(a, .{ .builtin_tools = &.{ "Read", "Glob", "Bash" } });
    defer runtime.destroy() catch unreachable;
    const session = try runtime.createSession(.{
        .provider_kind = .anthropic,
        .api_key = "test-key",
        .model = "test-model",
        .base_url = url,
        .permission_mode = .bypass_permissions,
        .workspace = .{ .root = root, .shell = .disabled },
        .allowed_tools = &.{ "Read", "Glob" },
    });
    defer session.destroy() catch unreachable;

    var sink_state: u8 = 0;
    const result = try session.runText(1, "read the file", 4, .{ .ctx = &sink_state, .emit = Sink.emit });
    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, result.stop_reason);
    try std.testing.expectEqual(@as(u32, 2), result.tool_calls);

    const request = srv.lastRequest() orelse return error.NoRequestCaptured;
    const body = request.body();
    // The final request carries both the relative Read result and the Glob
    // result produced with its omitted path defaulting to workspace-root ".".
    // Runtime's Bash entry never crosses the Session ceiling.
    try std.testing.expect(std.mem.indexOf(u8, body, "\\\"name\\\":\\\"Read\\\"") != null or std.mem.indexOf(u8, body, "\"name\":\"Read\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\\\"name\\\":\\\"Glob\\\"") != null or std.mem.indexOf(u8, body, "\"name\":\"Glob\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "agentcore-tool-ok") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, glob_probe_name) != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\\\"name\\\":\\\"Bash\\\"") == null and std.mem.indexOf(u8, body, "\"name\":\"Bash\"") == null);
}

test "L2 AgentSession rejects an unadvertised Runtime tool before prefetch or dispatch" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buf);
    const root = root_buf[0..root_len];
    const marker = try std.fmt.allocPrintSentinel(a, "{s}/must-not-exist", .{root}, 0);
    defer a.free(marker);
    const command = try std.fmt.allocPrint(a, "touch {s}", .{marker});
    defer a.free(command);
    const tool_sse = try bashToolSse(a, command);
    defer a.free(tool_sse);

    const bodies = [_][]const u8{ tool_sse, FINAL_SSE };
    var srv = try harness.MockServer.startCassette(&bodies, 0);
    defer srv.stop();
    const url = try srv.urlOwned(a);
    defer a.free(url);

    const runtime = try cc.agent_session.AgentRuntime.create(a, .{ .builtin_tools = &.{ "Read", "Bash" } });
    defer runtime.destroy() catch unreachable;
    const session = try runtime.createSession(.{
        .provider_kind = .anthropic,
        .api_key = "test-key",
        .model = "test-model",
        .base_url = url,
        .permission_mode = .bypass_permissions,
        .workspace = .{ .root = root, .shell = .disabled },
        .allowed_tools = &.{"Read"},
    });
    defer session.destroy() catch unreachable;

    var sink_state: u8 = 0;
    const result = try session.runText(1, "do not trust the provider", 4, .{ .ctx = &sink_state, .emit = Sink.emit });
    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, result.stop_reason);
    try std.testing.expect(std.c.access(marker.ptr, std.c.F_OK) != 0);
    const body = (srv.lastRequest() orelse return error.NoRequestCaptured).body();
    try std.testing.expect(std.mem.indexOf(u8, body, "unknown_tool") != null);
}
