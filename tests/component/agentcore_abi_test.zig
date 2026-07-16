const std = @import("std");
const harness = @import("harness");
const abi = @import("agentcore-abi");
const sdk = @import("agentcore-sdk");
const wire = sdk.types;

const FINAL_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_3\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"done\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const ASK_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_1\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"tu_ask\",\"name\":\"AskUserQuestion\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"questions\\\":[{\\\"question\\\":\\\"Continue?\\\",\\\"header\\\":\\\"Choice\\\",\\\"options\\\":[{\\\"label\\\":\\\"Yes\\\",\\\"description\\\":\\\"Proceed\\\"},{\\\"label\\\":\\\"No\\\",\\\"description\\\":\\\"Stop\\\"}]}]}\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const HOST_SSE =
    "data: {\"type\":\"message_start\",\"message\":{\"id\":\"msg_2\",\"role\":\"assistant\",\"model\":\"x\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\n\n" ++
    "data: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"tool_use\",\"id\":\"tu_host\",\"name\":\"HostEcho\",\"input\":{}}}\n\n" ++
    "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"text\\\":\\\"hello\\\"}\"}}\n\n" ++
    "data: {\"type\":\"content_block_stop\",\"index\":0}\n\n" ++
    "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"},\"usage\":{\"output_tokens\":1}}\n\n" ++
    "data: {\"type\":\"message_stop\"}\n\n";

const Probe = struct {
    ui_calls: usize = 0,
    ui_releases: usize = 0,
    host_calls: usize = 0,
    host_releases: usize = 0,
    saw_tool_start: bool = false,
    saw_tool_result: bool = false,

    fn event(raw: ?*anyopaque, _: ?*wire.SessionHandle, _: u64, event_json: wire.BytesViewV1) callconv(.c) u32 {
        const self: *Probe = @ptrCast(@alignCast(raw orelse return wire.CALLBACK_FATAL));
        const bytes = sdk.borrowedBytes(event_json) catch return wire.CALLBACK_FATAL;
        if (std.mem.indexOf(u8, bytes, "tool_start") != null) self.saw_tool_start = true;
        if (std.mem.indexOf(u8, bytes, "tool_result") != null) self.saw_tool_result = true;
        return wire.CALLBACK_CONTINUE;
    }

    fn ui(raw: ?*anyopaque, _: ?*wire.SessionHandle, request_json: wire.BytesViewV1, out: ?*wire.OwnedBytesV1) callconv(.c) u32 {
        const self: *Probe = @ptrCast(@alignCast(raw orelse return wire.UI_FATAL));
        const bytes = sdk.borrowedBytes(request_json) catch return wire.UI_FATAL;
        if (std.mem.indexOf(u8, bytes, "ask_question") == null) return wire.UI_FATAL;
        self.ui_calls += 1;
        const response = "{\"answers\":[\"Yes\"]}";
        (out orelse return wire.UI_FATAL).* = .{ .ptr = @constCast(response.ptr), .len = response.len };
        return wire.UI_ANSWERED;
    }

    fn uiRelease(raw: ?*anyopaque, out: ?*wire.OwnedBytesV1) callconv(.c) void {
        const self: *Probe = @ptrCast(@alignCast(raw orelse return));
        self.ui_releases += 1;
        if (out) |value| value.* = .{ .ptr = null, .len = 0 };
    }

    fn host(raw: ?*anyopaque, session_id: wire.BytesViewV1, args: wire.BytesViewV1, out: ?*wire.OwnedBytesV1) callconv(.c) u32 {
        const self: *Probe = @ptrCast(@alignCast(raw orelse return wire.HOST_FAILED));
        if ((sdk.borrowedBytes(session_id) catch return wire.HOST_FAILED).len != 24) return wire.HOST_FAILED;
        if (std.mem.indexOf(u8, sdk.borrowedBytes(args) catch return wire.HOST_FAILED, "hello") == null) return wire.HOST_FAILED;
        self.host_calls += 1;
        const result = "host-ok";
        (out orelse return wire.HOST_FAILED).* = .{ .ptr = @constCast(result.ptr), .len = result.len };
        return wire.HOST_OK;
    }

    fn hostRelease(raw: ?*anyopaque, out: ?*wire.OwnedBytesV1) callconv(.c) void {
        const self: *Probe = @ptrCast(@alignCast(raw orelse return));
        self.host_releases += 1;
        if (out) |value| value.* = .{ .ptr = null, .len = 0 };
    }
};

const FatalUiProbe = struct {
    calls: usize = 0,

    fn ui(raw: ?*anyopaque, _: ?*wire.SessionHandle, _: wire.BytesViewV1, _: ?*wire.OwnedBytesV1) callconv(.c) u32 {
        const self: *FatalUiProbe = @ptrCast(@alignCast(raw orelse return wire.UI_FATAL));
        self.calls += 1;
        return wire.UI_FATAL;
    }

    fn release(_: ?*anyopaque, _: ?*wire.OwnedBytesV1) callconv(.c) void {}
};

fn rootPath(tmp: *std.testing.TmpDir, buffer: []u8) ![]const u8 {
    const len = try tmp.dir.realPath(std.testing.io, buffer);
    return buffer[0..len];
}

test "L2 opaque ABI routes Host UI, Host tools and CoreEvent JSON through AgentSession" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buf);
    const bodies = [_][]const u8{ ASK_SSE, HOST_SSE, FINAL_SSE };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);

    const raw_api = abi.metacodes_agentcore_get_api(wire.ABI_VERSION_V1) orelse return error.MissingApi;
    const api = try sdk.Api.validate(@ptrCast(@alignCast(raw_api)));
    var probe = Probe{};
    const builtins = [_]wire.BytesViewV1{sdk.bytesView("AskUserQuestion")};
    var host = wire.HostToolV1{
        .struct_size = @sizeOf(wire.HostToolV1),
        .reserved0 = 0,
        .ctx = &probe,
        .name = sdk.bytesView("HostEcho"),
        .description = sdk.bytesView("Host echo"),
        .input_schema_json = sdk.bytesView("{\"type\":\"object\",\"properties\":{\"text\":{\"type\":\"string\"}},\"required\":[\"text\"]}"),
        .execute = Probe.host,
        .release_result = Probe.hostRelease,
        .reserved = [_]u64{0} ** 2,
    };
    var runtime_config = wire.RuntimeConfigV1{
        .struct_size = @sizeOf(wire.RuntimeConfigV1),
        .reserved0 = 0,
        .builtin_tools = &builtins,
        .builtin_tool_count = builtins.len,
        .host_tools = @ptrCast(&host),
        .host_tool_count = 1,
        .reserved = [_]u64{0} ** 4,
    };
    var diagnostic = wire.OwnedBytesV1{ .ptr = null, .len = 0 };
    defer api.bufferRelease()(&diagnostic);
    var runtime: ?*wire.RuntimeHandle = null;
    try std.testing.expectEqual(wire.STATUS_OK, api.runtimeCreate()(&runtime_config, &runtime, &diagnostic));
    defer {
        if (runtime) |handle| _ = api.runtimeDestroy()(handle, &diagnostic);
    }

    const allowed = [_]wire.BytesViewV1{ sdk.bytesView("AskUserQuestion"), sdk.bytesView("HostEcho") };
    var session_config = wire.SessionConfigV1{
        .struct_size = @sizeOf(wire.SessionConfigV1),
        .provider_kind_code = wire.PROVIDER_ANTHROPIC,
        .permission_mode_code = wire.PERMISSION_BYPASS,
        .shell_policy_code = wire.SHELL_DISABLED,
        .api_key = sdk.bytesView("test-key"),
        .model = sdk.bytesView("test-model"),
        .base_url = sdk.bytesView(url),
        .workspace_root = sdk.bytesView(root),
        .workspace_home = sdk.bytesView(root),
        .allowed_tools = &allowed,
        .allowed_tool_count = allowed.len,
        .reserved = [_]u64{0} ** 4,
    };
    var callbacks = wire.SessionCallbacksV1{
        .struct_size = @sizeOf(wire.SessionCallbacksV1),
        .reserved0 = 0,
        .ctx = &probe,
        .on_event = Probe.event,
        .on_ui_request = Probe.ui,
        .release_response = Probe.uiRelease,
        .reserved = [_]u64{0} ** 4,
    };
    var session: ?*wire.SessionHandle = null;
    try std.testing.expectEqual(wire.STATUS_OK, api.sessionCreate()(runtime, &session_config, &callbacks, &session, &diagnostic));
    defer {
        if (session) |handle| _ = api.sessionDestroy()(handle, &diagnostic);
    }
    try std.testing.expectEqual(wire.STATUS_BUSY, api.runtimeDestroy()(runtime, &diagnostic));
    api.bufferRelease()(&diagnostic);

    var options = wire.RunOptionsV1{ .struct_size = @sizeOf(wire.RunOptionsV1), .max_turns = 5, .reserved = [_]u64{0} ** 4 };
    var result: wire.RunResultV1 = undefined;
    try std.testing.expectEqual(wire.STATUS_OK, api.sessionRun()(session, 1, sdk.bytesView("exercise ABI"), &options, &result, &diagnostic));
    try std.testing.expectEqual(wire.STOP_END_TURN, result.stop_reason_code);
    try std.testing.expectEqual(@as(usize, 1), probe.ui_calls);
    try std.testing.expectEqual(@as(usize, 1), probe.ui_releases);
    try std.testing.expectEqual(@as(usize, 1), probe.host_calls);
    try std.testing.expectEqual(@as(usize, 1), probe.host_releases);
    try std.testing.expect(probe.saw_tool_start and probe.saw_tool_result);
    const body = (server.lastRequest() orelse return error.NoRequestCaptured).body();
    try std.testing.expect(std.mem.indexOf(u8, body, "Yes") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "host-ok") != null);
    try std.testing.expectEqual(wire.STATUS_TOO_LATE, api.sessionAbort()(session, 1, wire.ABORT_USER_REQUEST, &diagnostic));
    api.bufferRelease()(&diagnostic);
    try std.testing.expectEqual(wire.STATUS_OK, api.sessionDestroy()(session, &diagnostic));
    session = null;
    try std.testing.expectEqual(wire.STATUS_OK, api.runtimeDestroy()(runtime, &diagnostic));
    runtime = null;
}

test "L2 Host UI fatal aborts the Run and poisons the ABI Session" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buf);
    const bodies = [_][]const u8{ASK_SSE};
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);

    const raw_api = abi.metacodes_agentcore_get_api(wire.ABI_VERSION_V1) orelse return error.MissingApi;
    const api = try sdk.Api.validate(@ptrCast(@alignCast(raw_api)));
    const builtins = [_]wire.BytesViewV1{sdk.bytesView("AskUserQuestion")};
    var runtime_config = std.mem.zeroes(wire.RuntimeConfigV1);
    runtime_config.struct_size = @sizeOf(wire.RuntimeConfigV1);
    runtime_config.builtin_tools = &builtins;
    runtime_config.builtin_tool_count = builtins.len;
    var diagnostic = wire.OwnedBytesV1{ .ptr = null, .len = 0 };
    defer api.bufferRelease()(&diagnostic);
    var runtime: ?*wire.RuntimeHandle = null;
    try std.testing.expectEqual(wire.STATUS_OK, api.runtimeCreate()(&runtime_config, &runtime, &diagnostic));
    defer {
        if (runtime) |handle| _ = api.runtimeDestroy()(handle, &diagnostic);
    }

    const allowed = [_]wire.BytesViewV1{sdk.bytesView("AskUserQuestion")};
    var session_config = std.mem.zeroes(wire.SessionConfigV1);
    session_config.struct_size = @sizeOf(wire.SessionConfigV1);
    session_config.provider_kind_code = wire.PROVIDER_ANTHROPIC;
    session_config.permission_mode_code = wire.PERMISSION_BYPASS;
    session_config.shell_policy_code = wire.SHELL_DISABLED;
    session_config.api_key = sdk.bytesView("test-key");
    session_config.model = sdk.bytesView("test-model");
    session_config.base_url = sdk.bytesView(url);
    session_config.workspace_root = sdk.bytesView(root);
    session_config.workspace_home = sdk.bytesView(root);
    session_config.allowed_tools = &allowed;
    session_config.allowed_tool_count = allowed.len;
    var probe = FatalUiProbe{};
    var callbacks = std.mem.zeroes(wire.SessionCallbacksV1);
    callbacks.struct_size = @sizeOf(wire.SessionCallbacksV1);
    callbacks.ctx = &probe;
    callbacks.on_ui_request = FatalUiProbe.ui;
    callbacks.release_response = FatalUiProbe.release;
    var session: ?*wire.SessionHandle = null;
    try std.testing.expectEqual(wire.STATUS_OK, api.sessionCreate()(runtime, &session_config, &callbacks, &session, &diagnostic));
    defer {
        if (session) |handle| _ = api.sessionDestroy()(handle, &diagnostic);
    }

    var options = wire.RunOptionsV1{ .struct_size = @sizeOf(wire.RunOptionsV1), .max_turns = 2, .reserved = [_]u64{0} ** 4 };
    var result: wire.RunResultV1 = undefined;
    try std.testing.expectEqual(wire.STATUS_CALLBACK_FAILED, api.sessionRun()(session, 1, sdk.bytesView("ask through broken UI"), &options, &result, &diagnostic));
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    api.bufferRelease()(&diagnostic);
    try std.testing.expectEqual(wire.STATUS_INVALID_STATE, api.sessionRun()(session, 2, sdk.bytesView("must stay poisoned"), &options, &result, &diagnostic));
    api.bufferRelease()(&diagnostic);
    try std.testing.expectEqual(wire.STATUS_OK, api.sessionDestroy()(session, &diagnostic));
    session = null;
    try std.testing.expectEqual(wire.STATUS_OK, api.runtimeDestroy()(runtime, &diagnostic));
    runtime = null;
}
