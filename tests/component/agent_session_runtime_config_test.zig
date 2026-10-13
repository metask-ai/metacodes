//! L2: Session-level runtime configuration an embedding Host changes while
//! the Session is idle, proven at the request and the file system.
//!
//! - `WorkspaceConfig.additional_dirs` / `setAdditionalDirectories`: the
//!   working directory set behind `accept_edits` auto-approval. A Write inside
//!   an additional directory goes through without a prompt, a Write outside
//!   asks, and after the set is replaced the old directory asks again.
//! - `SessionConfig.reasoning_effort` / `setReasoningEffort`: the effort the
//!   provider request carries, kept across `setModel` (a replacement provider
//!   starts at its default) and cleared by null.
//!
//! Cross-module: agent_session + workspace_policy + permission decision +
//! Write tool; agent_session + provider factory + Anthropic request assembly.

const std = @import("std");
const pfs = @import("platform").fs;
const harness = @import("harness");
const cc = @import("cc");

const FINAL_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_final\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"done\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

fn writeToolSse(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "data: {{\"type\":\"message_start\",\"message\":{{\"id\":\"msg_w\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{{\"input_tokens\":1,\"output_tokens\":1}}}}}}\n\n" ++
        "data: {{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{{\"type\":\"tool_use\",\"id\":\"tu_w\",\"name\":\"Write\",\"input\":{{}}}}}}\n\n" ++
        "data: {{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{{\"type\":\"input_json_delta\",\"partial_json\":\"{{\\\"file_path\\\":\\\"{s}\\\",\\\"content\\\":\\\"cfg\\\"}}\"}}}}\n\n" ++
        "data: {{\"type\":\"content_block_stop\",\"index\":0}}\n\n" ++
        "data: {{\"type\":\"message_delta\",\"delta\":{{\"stop_reason\":\"tool_use\"}},\"usage\":{{\"output_tokens\":1}}}}\n\n" ++
        "data: {{\"type\":\"message_stop\"}}\n\n", .{path});
}

/// Denies every permission prompt and counts them.
const DenyAll = struct {
    prompts: usize = 0,

    fn request(
        raw: *anyopaque,
        _: cc.session_id.SessionId,
        _: std.mem.Allocator,
        req: *const cc.ui_request.UiRequest,
        out: *cc.ui_request.UiResponse,
    ) anyerror!cc.ui_request.RequestOutcome {
        const self: *DenyAll = @ptrCast(@alignCast(raw));
        switch (req.*) {
            .permission => {
                self.prompts += 1;
                out.* = .{ .permission = .deny_once };
                return .answered;
            },
            else => return error.UnexpectedUiRequest,
        }
    }

    fn requester(self: *DenyAll) cc.agent_session.UiRequester {
        return .{ .ctx = self, .requestFn = request };
    }
};

const Sink = struct {
    fn emit(_: *anyopaque, _: cc.session_id.SessionId, _: u64, _: cc.ui_event.CoreEvent) bool {
        return true;
    }
};

fn subdir(tmp: *std.testing.TmpDir, name: []const u8, buffer: []u8) ![]const u8 {
    try tmp.dir.createDirPath(std.testing.io, name);
    var sub = try tmp.dir.openDir(std.testing.io, name, .{});
    defer sub.close(std.testing.io);
    const len = try sub.realPath(std.testing.io, buffer);
    for (buffer[0..len]) |*c| {
        if (c.* == '\\') c.* = '/';
    }
    return buffer[0..len];
}

fn exists(dir: []const u8, name: []const u8) !bool {
    var buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&buf, "{s}/{s}", .{ dir, name });
    return pfs.exists(path.ptr);
}

test "L2 AgentSession additional directories widen accept_edits and are replaced at idle" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var workspace_buf: [std.fs.max_path_bytes]u8 = undefined;
    const workspace = try subdir(&tmp, "workspace", &workspace_buf);
    var extra_buf: [std.fs.max_path_bytes]u8 = undefined;
    const extra = try subdir(&tmp, "extra", &extra_buf);
    var outside_buf: [std.fs.max_path_bytes]u8 = undefined;
    const outside = try subdir(&tmp, "outside", &outside_buf);

    const in_extra = try std.fmt.allocPrint(a, "{s}/granted.txt", .{extra});
    defer a.free(in_extra);
    const in_outside = try std.fmt.allocPrint(a, "{s}/never.txt", .{outside});
    defer a.free(in_outside);
    const after_reset = try std.fmt.allocPrint(a, "{s}/revoked.txt", .{extra});
    defer a.free(after_reset);
    const newly_granted = try std.fmt.allocPrint(a, "{s}/now.txt", .{outside});
    defer a.free(newly_granted);
    const sse_extra = try writeToolSse(a, in_extra);
    defer a.free(sse_extra);
    const sse_outside = try writeToolSse(a, in_outside);
    defer a.free(sse_outside);
    const sse_reset = try writeToolSse(a, after_reset);
    defer a.free(sse_reset);
    const sse_granted = try writeToolSse(a, newly_granted);
    defer a.free(sse_granted);
    const bodies = [_][]const u8{ sse_extra, FINAL_SSE, sse_outside, FINAL_SSE, sse_reset, FINAL_SSE, sse_granted, FINAL_SSE };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);

    const runtime = try cc.agent_session.AgentRuntime.create(a, .{ .builtin_tools = &.{"Write"} });
    defer runtime.destroy() catch unreachable;
    var ui = DenyAll{};
    const session = try runtime.createSession(.{
        .provider_kind = .anthropic,
        .api_key = "test-key",
        .model = "test-model",
        .base_url = url,
        .permission_mode = .accept_edits,
        .workspace = .{ .root = workspace, .additional_dirs = &.{extra} },
        .allowed_tools = &.{"Write"},
        .ui_requester = ui.requester(),
    });
    defer session.destroy() catch unreachable;
    var sink_state: u8 = 0;
    const sink: cc.agent_session.EventSink = .{ .ctx = &sink_state, .emit = Sink.emit };

    // Inside the additional directory: auto-approved like the root.
    _ = try session.runText(1, "write into extra", 4, sink);
    try std.testing.expectEqual(@as(usize, 0), ui.prompts);
    try std.testing.expect(try exists(extra, "granted.txt"));

    // Outside every working directory: asked, denied, not written.
    _ = try session.runText(2, "write outside", 4, sink);
    try std.testing.expectEqual(@as(usize, 1), ui.prompts);
    try std.testing.expect(!try exists(outside, "never.txt"));

    // An invalid replacement changes nothing; a valid one takes effect for
    // the next Run in both directions: the old directory asks again and the
    // new one goes through.
    try std.testing.expectError(error.InvalidAdditionalDirectory, session.setAdditionalDirectories(&.{"relative/dir"}));
    try std.testing.expectEqual(@as(usize, 1), session.workspace.additional_dirs.len);
    try session.setAdditionalDirectories(&.{outside});
    _ = try session.runText(3, "write into the former extra", 4, sink);
    try std.testing.expectEqual(@as(usize, 2), ui.prompts);
    try std.testing.expect(!try exists(extra, "revoked.txt"));
    _ = try session.runText(4, "write into the new extra", 4, sink);
    try std.testing.expectEqual(@as(usize, 2), ui.prompts);
    try std.testing.expect(try exists(outside, "now.txt"));
}

fn lastBody(server: *harness.MockServer) ![]const u8 {
    return (server.lastRequest() orelse return error.NoRequestCaptured).body();
}

test "L2 AgentSession reasoning effort reaches the request, survives setModel and clears" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var workspace_buf: [std.fs.max_path_bytes]u8 = undefined;
    const workspace = try subdir(&tmp, "workspace", &workspace_buf);

    const bodies = [_][]const u8{ FINAL_SSE, FINAL_SSE, FINAL_SSE, FINAL_SSE };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);

    const runtime = try cc.agent_session.AgentRuntime.create(a, .{ .builtin_tools = &.{} });
    defer runtime.destroy() catch unreachable;
    const session = try runtime.createSession(.{
        .provider_kind = .anthropic,
        .api_key = "test-key",
        .model = "test-model",
        .base_url = url,
        .workspace = .{ .root = workspace },
        .allowed_tools = &.{},
        .reasoning_effort = .high,
    });
    defer session.destroy() catch unreachable;
    var sink_state: u8 = 0;
    const sink: cc.agent_session.EventSink = .{ .ctx = &sink_state, .emit = Sink.emit };

    _ = try session.runText(1, "one", 4, sink);
    try std.testing.expect(std.mem.indexOf(u8, try lastBody(server), "\"output_config\":{\"effort\":\"high\"}") != null);

    // A model switch replaces the provider; the effort comes along.
    try session.setModel("other-model");
    _ = try session.runText(2, "two", 4, sink);
    const after_switch = try lastBody(server);
    try std.testing.expect(std.mem.indexOf(u8, after_switch, "\"model\":\"other-model\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, after_switch, "\"output_config\":{\"effort\":\"high\"}") != null);

    try session.setReasoningEffort(.low);
    _ = try session.runText(3, "three", 4, sink);
    try std.testing.expect(std.mem.indexOf(u8, try lastBody(server), "\"output_config\":{\"effort\":\"low\"}") != null);

    try session.setReasoningEffort(null);
    _ = try session.runText(4, "four", 4, sink);
    try std.testing.expect(std.mem.indexOf(u8, try lastBody(server), "output_config") == null);
}

test "L2 AgentSession refuses a reasoning effort its provider cannot carry" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var workspace_buf: [std.fs.max_path_bytes]u8 = undefined;
    const workspace = try subdir(&tmp, "workspace", &workspace_buf);

    const runtime = try cc.agent_session.AgentRuntime.create(a, .{ .builtin_tools = &.{} });
    defer runtime.destroy() catch unreachable;
    try std.testing.expectError(error.AgentEffortUnsupportedProvider, runtime.createSession(.{
        .provider_kind = .gemini,
        .api_key = "test-key",
        .model = "gemini-test",
        .base_url = "http://127.0.0.1:9",
        .workspace = .{ .root = workspace },
        .allowed_tools = &.{},
        .reasoning_effort = .high,
    }));
}

fn bashToolSse(allocator: std.mem.Allocator, command: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "data: {{\"type\":\"message_start\",\"message\":{{\"id\":\"msg_b\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{{\"input_tokens\":1,\"output_tokens\":1}}}}}}\n\n" ++
        "data: {{\"type\":\"content_block_start\",\"index\":0,\"content_block\":{{\"type\":\"tool_use\",\"id\":\"tu_b\",\"name\":\"Bash\",\"input\":{{}}}}}}\n\n" ++
        "data: {{\"type\":\"content_block_delta\",\"index\":0,\"delta\":{{\"type\":\"input_json_delta\",\"partial_json\":\"{{\\\"command\\\":\\\"{s}\\\"}}\"}}}}\n\n" ++
        "data: {{\"type\":\"content_block_stop\",\"index\":0}}\n\n" ++
        "data: {{\"type\":\"message_delta\",\"delta\":{{\"stop_reason\":\"tool_use\"}},\"usage\":{{\"output_tokens\":1}}}}\n\n" ++
        "data: {{\"type\":\"message_stop\"}}\n\n", .{command});
}

test "L2 AgentSession sandboxed shell may write in an additional directory and nowhere beside it" {
    if (!cc.sandbox_exec.hostSupported()) return error.SkipZigTest; // needs a real sandbox
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var workspace_buf: [std.fs.max_path_bytes]u8 = undefined;
    const workspace = try subdir(&tmp, "workspace", &workspace_buf);
    var extra_buf: [std.fs.max_path_bytes]u8 = undefined;
    const extra = try subdir(&tmp, "extra", &extra_buf);
    var outside_buf: [std.fs.max_path_bytes]u8 = undefined;
    const outside = try subdir(&tmp, "outside", &outside_buf);

    const touch_extra = try std.fmt.allocPrint(a, "touch {s}/in.txt", .{extra});
    defer a.free(touch_extra);
    const touch_outside = try std.fmt.allocPrint(a, "touch {s}/out.txt", .{outside});
    defer a.free(touch_outside);
    const sse_extra = try bashToolSse(a, touch_extra);
    defer a.free(sse_extra);
    const sse_outside = try bashToolSse(a, touch_outside);
    defer a.free(sse_outside);
    const bodies = [_][]const u8{ sse_extra, sse_outside, FINAL_SSE };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);

    const runtime = try cc.agent_session.AgentRuntime.create(a, .{ .builtin_tools = &.{"Bash"} });
    defer runtime.destroy() catch unreachable;
    const session = try runtime.createSession(.{
        .provider_kind = .anthropic,
        .api_key = "test-key",
        .model = "test-model",
        .base_url = url,
        .permission_mode = .bypass_permissions,
        .workspace = .{ .root = workspace, .shell = .sandboxed, .additional_dirs = &.{extra} },
        .allowed_tools = &.{"Bash"},
    });
    defer session.destroy() catch unreachable;
    var sink_state: u8 = 0;
    _ = try session.runText(1, "touch both", 6, .{ .ctx = &sink_state, .emit = Sink.emit });

    try std.testing.expect(try exists(extra, "in.txt"));
    // The sandbox is real: the sibling directory stayed read-only.
    try std.testing.expect(!try exists(outside, "out.txt"));
}
