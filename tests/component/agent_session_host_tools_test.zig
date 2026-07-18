//! AgentCore Host sync tool vertical slice: Runtime registration -> Session
//! selection -> provider advertisement -> callback -> owned result release.

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

const HOST_TOOL_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"tu_host\",\"name\":\"HostEcho\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"text\\\":\\\"hello\\\"}\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const Probe = struct {
    mode: enum { ok, fatal } = .ok,
    calls: usize = 0,
    releases: usize = 0,
    abort_session: ?*cc.agent_session.AgentSession = null,
    abort_run_id: u64 = 0,
    last_session_id: cc.session_id.SessionId = cc.session_id.SessionId.single,
    last_run_id: u64 = 0,
    last_host_ctx: ?*anyopaque = null,

    fn execute(raw: *anyopaque, identity: cc.agent_session.HostRunIdentity, _: []const u8) error{OutOfMemory}!cc.agent_session.HostToolOutcome {
        const self: *Probe = @ptrCast(@alignCast(raw));
        self.calls += 1;
        self.last_session_id = identity.identity.session_id;
        self.last_run_id = identity.identity.run_id;
        self.last_host_ctx = identity.host_session_ctx;
        if (self.mode == .fatal) return .fatal;
        if (self.abort_session) |session| session.abort(self.abort_run_id, .user_interrupt) catch return .fatal;
        return .{ .ok = .{ .bytes = "host-sync-ok", .release_ctx = raw, .releaseFn = release } };
    }

    fn release(raw: *anyopaque, _: []const u8) void {
        const self: *Probe = @ptrCast(@alignCast(raw));
        self.releases += 1;
    }

    fn tool(self: *Probe) cc.agent_session.HostSyncTool {
        return .{
            .definition = .{
                .name = "HostEcho",
                .description = "Echo through the embedding Host",
                .input_schema = .{
                    .type = "object",
                    .prop_specs = &.{.{ .name = "text", .type = "string" }},
                    .required = &.{"text"},
                },
            },
            .ctx = self,
            .execute = execute,
        };
    }
};

const Sink = struct {
    fn emit(_: *anyopaque, _: cc.session_id.SessionId, _: u64, _: cc.ui_event.CoreEvent) bool {
        return true;
    }
};

fn rootPath(tmp: *std.testing.TmpDir, buffer: []u8) ![]const u8 {
    const len = try tmp.dir.realPath(std.testing.io, buffer);
    return buffer[0..len];
}

test "L2 selected Host sync tool is advertised, executed and released exactly once" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buf);
    const bodies = [_][]const u8{ HOST_TOOL_SSE, FINAL_SSE };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);

    var probe = Probe{};
    const runtime = try cc.agent_session.AgentRuntime.create(a, .{ .builtin_tools = &.{}, .host_sync_tools = &.{probe.tool()} });
    defer runtime.destroy() catch unreachable;
    const session = try runtime.createSession(.{
        .provider_kind = .anthropic,
        .api_key = "test-key",
        .model = "test-model",
        .base_url = url,
        .permission_mode = .bypass_permissions,
        .workspace = .{ .root = root },
        .allowed_tools = &.{"HostEcho"},
        .host_identity_ctx = &probe,
    });
    defer session.destroy() catch unreachable;

    var sink_state: u8 = 0;
    const result = try session.runText(1, "call the host", 4, .{ .ctx = &sink_state, .emit = Sink.emit });
    try std.testing.expectEqual(cc.agent_loop.StopReason.end_turn, result.stop_reason);
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expectEqual(@as(usize, 1), probe.releases);
    try std.testing.expectEqualStrings(session.session_id.asSlice(), probe.last_session_id.asSlice());
    try std.testing.expectEqual(@as(u64, 1), probe.last_run_id);
    try std.testing.expectEqual(@as(?*anyopaque, @ptrCast(&probe)), probe.last_host_ctx);
    const body = (server.lastRequest() orelse return error.NoRequestCaptured).body();
    try std.testing.expect(std.mem.indexOf(u8, body, "HostEcho") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "host-sync-ok") != null);
}

test "L2 unadvertised Host tool is rejected without invoking callback" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buf);
    const bodies = [_][]const u8{ HOST_TOOL_SSE, FINAL_SSE };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);

    var probe = Probe{};
    const runtime = try cc.agent_session.AgentRuntime.create(a, .{ .builtin_tools = &.{}, .host_sync_tools = &.{probe.tool()} });
    defer runtime.destroy() catch unreachable;
    const session = try runtime.createSession(.{
        .provider_kind = .anthropic,
        .api_key = "test-key",
        .model = "test-model",
        .base_url = url,
        .permission_mode = .bypass_permissions,
        .workspace = .{ .root = root },
        .allowed_tools = &.{},
    });
    defer session.destroy() catch unreachable;

    var sink_state: u8 = 0;
    _ = try session.runText(1, "do not trust provider output", 4, .{ .ctx = &sink_state, .emit = Sink.emit });
    try std.testing.expectEqual(@as(usize, 0), probe.calls);
    try std.testing.expectEqual(@as(usize, 0), probe.releases);
    const body = (server.lastRequest() orelse return error.NoRequestCaptured).body();
    try std.testing.expect(std.mem.indexOf(u8, body, "unknown_tool") != null);
}

test "L2 Host sync callback may reenter abort without lifecycle deadlock" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buf);
    const bodies = [_][]const u8{HOST_TOOL_SSE};
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);

    var probe = Probe{ .abort_run_id = 7 };
    const runtime = try cc.agent_session.AgentRuntime.create(a, .{ .builtin_tools = &.{}, .host_sync_tools = &.{probe.tool()} });
    defer runtime.destroy() catch unreachable;
    const session = try runtime.createSession(.{
        .provider_kind = .anthropic,
        .api_key = "test-key",
        .model = "test-model",
        .base_url = url,
        .permission_mode = .bypass_permissions,
        .workspace = .{ .root = root },
        .allowed_tools = &.{"HostEcho"},
        .host_identity_ctx = &probe,
    });
    defer session.destroy() catch unreachable;
    probe.abort_session = session;

    var sink_state: u8 = 0;
    const result = try session.runText(7, "abort from callback", 4, .{ .ctx = &sink_state, .emit = Sink.emit });
    try std.testing.expectEqual(cc.agent_loop.StopReason.aborted, result.stop_reason);
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expectEqual(@as(usize, 1), probe.releases);
}

test "L2 Host fatal poisons the Session and maps to CallbackFailed without a tool result turn" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buf);
    var server = try harness.MockServer.start(HOST_TOOL_SSE, 0);
    defer server.stop();
    const url = try server.urlOwned(allocator);
    defer allocator.free(url);

    var probe = Probe{ .mode = .fatal };
    const runtime = try cc.agent_session.AgentRuntime.create(allocator, .{ .builtin_tools = &.{}, .host_sync_tools = &.{probe.tool()} });
    defer runtime.destroy() catch unreachable;
    const session = try runtime.createSession(.{
        .provider_kind = .anthropic,
        .api_key = "test-key",
        .model = "test-model",
        .base_url = url,
        .permission_mode = .bypass_permissions,
        .workspace = .{ .root = root },
        .allowed_tools = &.{"HostEcho"},
        .host_identity_ctx = &probe,
    });
    defer session.destroy() catch unreachable;

    var sink_state: u8 = 0;
    try std.testing.expectError(
        error.CallbackFailed,
        session.runText(11, "fatal host callback", 4, .{ .ctx = &sink_state, .emit = Sink.emit }),
    );
    try std.testing.expect(session.isPoisoned());
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expectEqual(@as(usize, 0), probe.releases);
    try std.testing.expectError(
        error.InvalidSessionState,
        session.runText(12, "must stay poisoned", 1, .{ .ctx = &sink_state, .emit = Sink.emit }),
    );
}
