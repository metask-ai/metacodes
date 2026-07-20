const std = @import("std");
const harness = @import("harness");
const abi = @import("agentcore-abi");
const sdk = @import("agentcore-sdk");
const core = @import("metacodes-core");
const sync = @import("platform").sync;
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

/// Test Host registry implementing the consumer-side §4 contract. The binding
/// is keyed by opaque Session handle, deep-copies session_id, and performs the
/// first bind and every comparison under the same per-registry mutex.
const HostIdentityRegistry = struct {
    const Entry = struct {
        session: ?*wire.SessionHandle = null,
        len: u8 = 0,
        bytes: [wire.MAX_SESSION_ID_BYTES_V1]u8 = undefined,
    };

    mutex: sync.Mutex = .{},
    entries: [2]Entry = .{ .{}, .{} },

    fn accept(self: *HostIdentityRegistry, session: *wire.SessionHandle, session_id: []const u8) bool {
        if (session_id.len == 0 or session_id.len > wire.MAX_SESSION_ID_BYTES_V1) return false;
        self.mutex.lock();
        defer self.mutex.unlock();
        for (&self.entries) |*entry| {
            if (entry.session == session) {
                return entry.len == session_id.len and std.mem.eql(u8, entry.bytes[0..entry.len], session_id);
            }
        }
        for (&self.entries) |*entry| {
            if (entry.session == null) {
                entry.session = session;
                entry.len = @intCast(session_id.len);
                @memcpy(entry.bytes[0..session_id.len], session_id);
                return true;
            }
        }
        return false;
    }
};

const Probe = struct {
    registry: HostIdentityRegistry = .{},
    expected_session: ?*wire.SessionHandle = null,
    expected_run_id: u64 = 1,
    ui_calls: usize = 0,
    ui_releases: usize = 0,
    host_calls: usize = 0,
    host_releases: usize = 0,
    saw_tool_start: bool = false,
    saw_tool_result: bool = false,

    fn context(self: *Probe, run_ptr: ?*const wire.RunContextV1) ?sdk.RunContext {
        const run = sdk.validateRunContext(run_ptr) catch return null;
        if (run.session != self.expected_session or run.run_id != self.expected_run_id or run.session_id.len != 24)
            return null;
        if (!self.registry.accept(run.session, run.session_id)) return null;
        return run;
    }

    fn event(raw: ?*anyopaque, run_ptr: ?*const wire.RunContextV1, event_json: wire.BytesViewV1) callconv(.c) u32 {
        const self: *Probe = @ptrCast(@alignCast(raw orelse return wire.EVENT_FATAL));
        _ = self.context(run_ptr) orelse return wire.EVENT_FATAL;
        const bytes = sdk.borrowedBytes(event_json) catch return wire.EVENT_FATAL;
        const parsed = sdk.decodeCoreEvent(std.heap.c_allocator, bytes) catch return wire.EVENT_FATAL;
        defer parsed.deinit();
        switch (parsed.value) {
            .known => |known_event| switch (known_event) {
                .tool_start => self.saw_tool_start = true,
                .tool_result => self.saw_tool_result = true,
                else => {},
            },
            .unknown => {},
        }
        return wire.EVENT_CONTINUE;
    }

    fn ui(raw: ?*anyopaque, run_ptr: ?*const wire.RunContextV1, request_json: wire.BytesViewV1, out: ?*wire.OwnedBytesV1) callconv(.c) u32 {
        const self: *Probe = @ptrCast(@alignCast(raw orelse return wire.UI_FATAL));
        _ = self.context(run_ptr) orelse return wire.UI_FATAL;
        const bytes = sdk.borrowedBytes(request_json) catch return wire.UI_FATAL;
        const parsed = sdk.decodeUiRequest(std.heap.c_allocator, bytes) catch return wire.UI_FATAL;
        defer parsed.deinit();
        if (parsed.value != .ask_question) return wire.UI_FATAL;
        self.ui_calls += 1;
        const answers = [_][]const u8{"Yes"};
        const response = sdk.encodeUiResponse(std.heap.c_allocator, parsed.value, .{ .answers = &answers }) catch return wire.UI_FATAL;
        (out orelse {
            std.heap.c_allocator.free(response);
            return wire.UI_FATAL;
        }).* = .{ .ptr = response.ptr, .len = response.len };
        return wire.UI_ANSWERED;
    }

    fn uiRelease(raw: ?*anyopaque, out: ?*wire.OwnedBytesV1) callconv(.c) void {
        const self: *Probe = @ptrCast(@alignCast(raw orelse return));
        self.ui_releases += 1;
        if (out) |value| {
            if (value.ptr) |ptr| std.heap.c_allocator.free(ptr[0..@intCast(value.len)]);
            value.* = .{ .ptr = null, .len = 0 };
        }
    }

    fn host(raw: ?*anyopaque, run_ptr: ?*const wire.RunContextV1, args: wire.BytesViewV1, out: ?*wire.OwnedBytesV1) callconv(.c) u32 {
        const self: *Probe = @ptrCast(@alignCast(raw orelse return wire.HOST_FAILED));
        _ = self.context(run_ptr) orelse return wire.HOST_FATAL;
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

const UiFailureMode = enum {
    fatal,
    oversized,
    unavailable,
    unknown,
    abort_twice,
};

const UiFailureProbe = struct {
    mode: UiFailureMode,
    api: ?sdk.Api = null,
    calls: usize = 0,
    releases: usize = 0,
    byte: u8 = 0,
    nested_run_status: u32 = std.math.maxInt(u32),
    nested_destroy_status: u32 = std.math.maxInt(u32),
    first_abort_status: u32 = std.math.maxInt(u32),
    second_abort_status: u32 = std.math.maxInt(u32),

    fn ui(raw: ?*anyopaque, run_ptr: ?*const wire.RunContextV1, _: wire.BytesViewV1, out: ?*wire.OwnedBytesV1) callconv(.c) u32 {
        const self: *UiFailureProbe = @ptrCast(@alignCast(raw orelse return wire.UI_FATAL));
        self.calls += 1;
        return switch (self.mode) {
            .fatal => wire.UI_FATAL,
            .oversized => blk: {
                (out orelse return wire.UI_FATAL).* = .{
                    .ptr = @ptrCast(&self.byte),
                    .len = wire.MAX_UI_RESPONSE_BYTES_V1 + 1,
                };
                break :blk wire.UI_ANSWERED;
            },
            .unavailable => wire.UI_UNAVAILABLE,
            .unknown => std.math.maxInt(u32),
            .abort_twice => blk: {
                const api = self.api orelse return wire.UI_FATAL;
                const run = sdk.validateRunContext(run_ptr) catch return wire.UI_FATAL;
                var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
                defer api.bufferRelease()(&diagnostic);
                self.nested_run_status = api.sessionRun()(
                    run.session,
                    run.run_id + 1,
                    sdk.bytesView("nested callback run"),
                    null,
                    null,
                    &diagnostic,
                );
                api.bufferRelease()(&diagnostic);
                self.nested_destroy_status = api.sessionDestroy()(run.session, &diagnostic);
                api.bufferRelease()(&diagnostic);
                self.first_abort_status = api.sessionAbort()(run.session, run.run_id, wire.ABORT_USER_REQUEST, &diagnostic);
                api.bufferRelease()(&diagnostic);
                self.second_abort_status = api.sessionAbort()(run.session, run.run_id, wire.ABORT_USER_REQUEST, &diagnostic);
                break :blk wire.UI_UNAVAILABLE;
            },
        };
    }

    fn release(raw: ?*anyopaque, out: ?*wire.OwnedBytesV1) callconv(.c) void {
        const self: *UiFailureProbe = @ptrCast(@alignCast(raw orelse return));
        self.releases += 1;
        if (out) |value| value.* = .{ .ptr = null, .len = 0 };
    }
};

const FatalEventProbe = struct {
    calls: usize = 0,

    fn event(raw: ?*anyopaque, _: ?*const wire.RunContextV1, _: wire.BytesViewV1) callconv(.c) u32 {
        const self: *FatalEventProbe = @ptrCast(@alignCast(raw orelse return wire.EVENT_FATAL));
        self.calls += 1;
        return wire.EVENT_FATAL;
    }
};

const AbortEventProbe = struct {
    api: sdk.Api,
    calls: usize = 0,
    stale_abort_status: u32 = std.math.maxInt(u32),
    abort_status: u32 = std.math.maxInt(u32),

    fn event(raw: ?*anyopaque, run_ptr: ?*const wire.RunContextV1, _: wire.BytesViewV1) callconv(.c) u32 {
        const self: *AbortEventProbe = @ptrCast(@alignCast(raw orelse return wire.EVENT_FATAL));
        const run = sdk.validateRunContext(run_ptr) catch return wire.EVENT_FATAL;
        self.calls += 1;
        if (self.calls == 1) {
            var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
            const wrong_run_id: u64 = 2;
            self.stale_abort_status = self.api.sessionAbort()(run.session, wrong_run_id, wire.ABORT_USER_REQUEST, &diagnostic);
            self.api.bufferRelease()(&diagnostic);
            self.abort_status = self.api.sessionAbort()(run.session, run.run_id, wire.ABORT_USER_REQUEST, &diagnostic);
            self.api.bufferRelease()(&diagnostic);
        }
        return wire.EVENT_CONTINUE;
    }
};

fn rootPath(tmp: *std.testing.TmpDir, buffer: []u8) ![]const u8 {
    const len = try tmp.dir.realPath(std.testing.io, buffer);
    return buffer[0..len];
}

fn expectInvalidSessionConfig(
    api: sdk.Api,
    runtime: *wire.RuntimeHandle,
    config: *const wire.SessionConfigV1,
    callbacks: *const wire.SessionCallbacksV1,
    diagnostic: *wire.OwnedBytesV1,
) !void {
    var session: ?*wire.SessionHandle = null;
    try std.testing.expectEqual(
        wire.STATUS_INVALID_ARGUMENT,
        api.sessionCreate()(runtime, config, callbacks, &session, diagnostic),
    );
    try std.testing.expect(session == null);
    try std.testing.expect(diagnostic.ptr != null and diagnostic.len != 0);
    const diagnostic_bytes = try sdk.borrowedBytes(.{ .ptr = diagnostic.ptr, .len = diagnostic.len });
    const api_key = try sdk.borrowedBytes(config.api_key);
    if (api_key.len != 0) try std.testing.expect(std.mem.indexOf(u8, diagnostic_bytes, api_key) == null);
    api.bufferRelease()(diagnostic);
    try std.testing.expect(diagnostic.ptr == null and diagnostic.len == 0);
}

test "L2 SDK rejects API tables that violate rigid v1 discovery" {
    const raw_api = abi.metask_agentcore_get_api(wire.ABI_VERSION_V1) orelse return error.MissingApi;
    const actual: *const wire.ApiV1 = @ptrCast(@alignCast(raw_api));
    _ = try sdk.Api.validate(actual);

    var nonzero_reserved = actual.*;
    nonzero_reserved.reserved[0] = 1;
    try std.testing.expectError(error.UnsupportedAbi, sdk.Api.validate(&nonzero_reserved));

    var wrong_revision = actual.*;
    wrong_revision.abi_revision = wire.ABI_REVISION - 1;
    try std.testing.expectError(error.UnsupportedAbi, sdk.Api.validate(&wrong_revision));

    var nonzero_header_reserved = actual.*;
    nonzero_header_reserved.reserved0 = 1;
    try std.testing.expectError(error.UnsupportedAbi, sdk.Api.validate(&nonzero_header_reserved));

    inline for (.{
        wire.CAP_RUNTIME,
        wire.CAP_BUILTIN_TOOLS,
        wire.CAP_HOST_SYNC_TOOLS,
        wire.CAP_HOST_UI,
        wire.CAP_CORE_EVENTS_JSON,
        wire.CAP_ABORT,
    }) |capability| {
        var missing_capability = actual.*;
        missing_capability.capabilities &= ~capability;
        try std.testing.expectError(error.UnsupportedAbi, sdk.Api.validate(&missing_capability));
    }
}

test "L2 invalid Session configuration publishes no handle and diagnostics never leak credentials" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buf);

    const raw_api = abi.metask_agentcore_get_api(wire.ABI_VERSION_V1) orelse return error.MissingApi;
    const api = try sdk.Api.validate(@ptrCast(@alignCast(raw_api)));
    const builtins = [_]wire.BytesViewV1{ sdk.bytesView("Read"), sdk.bytesView("Bash") };
    var runtime_config = std.mem.zeroes(wire.RuntimeConfigV1);
    runtime_config.struct_size = @sizeOf(wire.RuntimeConfigV1);
    runtime_config.builtin_tools = &builtins;
    runtime_config.builtin_tool_count = builtins.len;
    var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
    defer api.bufferRelease()(&diagnostic);
    var runtime: ?*wire.RuntimeHandle = null;

    var excessive_runtime_config = std.mem.zeroes(wire.RuntimeConfigV1);
    excessive_runtime_config.struct_size = @sizeOf(wire.RuntimeConfigV1);
    excessive_runtime_config.builtin_tool_count = wire.MAX_TOOL_COUNT_V1 + 1;
    try std.testing.expectEqual(
        wire.STATUS_RESOURCE_LIMIT,
        api.runtimeCreate()(&excessive_runtime_config, &runtime, &diagnostic),
    );
    try std.testing.expect(runtime == null);
    api.bufferRelease()(&diagnostic);

    try std.testing.expectEqual(wire.STATUS_OK, api.runtimeCreate()(&runtime_config, &runtime, &diagnostic));
    defer if (runtime) |handle| {
        _ = api.runtimeDestroy()(handle, &diagnostic);
    };

    var callbacks = std.mem.zeroes(wire.SessionCallbacksV1);
    callbacks.struct_size = @sizeOf(wire.SessionCallbacksV1);
    const read_only = [_]wire.BytesViewV1{sdk.bytesView("Read")};
    var config = std.mem.zeroes(wire.SessionConfigV1);
    config.struct_size = @sizeOf(wire.SessionConfigV1);
    config.provider_kind_code = wire.PROVIDER_ANTHROPIC;
    config.permission_mode_code = wire.PERMISSION_BYPASS;
    config.shell_policy_code = wire.SHELL_DISABLED;
    config.api_key = sdk.bytesView("test-key");
    config.model = sdk.bytesView("test-model");
    config.workspace_root = sdk.bytesView(root);
    config.workspace_home = sdk.bytesView(root);
    config.allowed_tools = &read_only;
    config.allowed_tool_count = read_only.len;

    var metadata_byte: u8 = 'x';
    const valid_model = config.model;
    config.model = .{ .ptr = @ptrCast(&metadata_byte), .len = wire.MAX_METADATA_STRING_BYTES_V1 + 1 };
    var metadata_limited_session: ?*wire.SessionHandle = null;
    try std.testing.expectEqual(
        wire.STATUS_RESOURCE_LIMIT,
        api.sessionCreate()(runtime, &config, &callbacks, &metadata_limited_session, &diagnostic),
    );
    try std.testing.expect(metadata_limited_session == null);
    api.bufferRelease()(&diagnostic);
    config.model = valid_model;

    config.workspace_root = sdk.bytesView(".");
    try expectInvalidSessionConfig(api, runtime.?, &config, &callbacks, &diagnostic);
    config.workspace_root = sdk.bytesView(root);

    config.workspace_home = sdk.bytesView(".");
    try expectInvalidSessionConfig(api, runtime.?, &config, &callbacks, &diagnostic);
    config.workspace_home = sdk.bytesView(root);

    const missing = [_]wire.BytesViewV1{sdk.bytesView("Grep")};
    config.allowed_tools = &missing;
    config.allowed_tool_count = missing.len;
    try expectInvalidSessionConfig(api, runtime.?, &config, &callbacks, &diagnostic);

    const duplicate = [_]wire.BytesViewV1{ sdk.bytesView("Read"), sdk.bytesView("Read") };
    config.allowed_tools = &duplicate;
    config.allowed_tool_count = duplicate.len;
    try expectInvalidSessionConfig(api, runtime.?, &config, &callbacks, &diagnostic);

    const disabled_shell = [_]wire.BytesViewV1{sdk.bytesView("Bash")};
    config.allowed_tools = &disabled_shell;
    config.allowed_tool_count = disabled_shell.len;
    try expectInvalidSessionConfig(api, runtime.?, &config, &callbacks, &diagnostic);

    config.allowed_tools = null;
    config.allowed_tool_count = wire.MAX_TOOL_COUNT_V1 + 1;
    var limited_session: ?*wire.SessionHandle = null;
    try std.testing.expectEqual(
        wire.STATUS_RESOURCE_LIMIT,
        api.sessionCreate()(runtime, &config, &callbacks, &limited_session, &diagnostic),
    );
    try std.testing.expect(limited_session == null);
    api.bufferRelease()(&diagnostic);

    try std.testing.expectEqual(wire.STATUS_OK, api.runtimeDestroy()(runtime, &diagnostic));
    runtime = null;
}

test "L2 opaque ABI routes Host callbacks and enforces Run admission identifiers" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buf);
    const bodies = [_][]const u8{ ASK_SSE, HOST_SSE, FINAL_SSE, FINAL_SSE, FINAL_SSE, FINAL_SSE, FINAL_SSE };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);

    const raw_api = abi.metask_agentcore_get_api(wire.ABI_VERSION_V1) orelse return error.MissingApi;
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
    probe.expected_session = session;
    defer {
        if (session) |handle| _ = api.sessionDestroy()(handle, &diagnostic);
    }
    try std.testing.expectEqual(wire.STATUS_BUSY, api.runtimeDestroy()(runtime, &diagnostic));
    api.bufferRelease()(&diagnostic);

    var options = wire.RunOptionsV1{ .struct_size = @sizeOf(wire.RunOptionsV1), .max_turns = 5, .reserved = [_]u64{0} ** 4 };
    var result: wire.RunResultV1 = undefined;
    try std.testing.expectEqual(wire.STATUS_INVALID_ARGUMENT, api.sessionAbort()(session, 0, wire.ABORT_USER_REQUEST, &diagnostic));
    api.bufferRelease()(&diagnostic);
    try std.testing.expectEqual(
        wire.STATUS_INVALID_ARGUMENT,
        api.sessionRun()(session, 0, sdk.bytesView("zero is not a Run identifier"), &options, &result, &diagnostic),
    );
    api.bufferRelease()(&diagnostic);
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
    options.max_turns = wire.MAX_TURNS_V1 + 1;
    try std.testing.expectEqual(
        wire.STATUS_RESOURCE_LIMIT,
        api.sessionRun()(session, 2, sdk.bytesView("must not start"), &options, &result, &diagnostic),
    );
    api.bufferRelease()(&diagnostic);
    options.max_turns = 5;
    probe.expected_run_id = 2;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.sessionRun()(session, 2, sdk.bytesView("run after pre-admission rejection"), &options, &result, &diagnostic),
    );
    try std.testing.expectEqual(wire.STOP_END_TURN, result.stop_reason_code);
    try std.testing.expectEqual(wire.STATUS_TOO_LATE, api.sessionAbort()(session, 2, wire.ABORT_USER_REQUEST, &diagnostic));
    api.bufferRelease()(&diagnostic);
    try std.testing.expectEqual(wire.STATUS_STALE_RUN, api.sessionAbort()(session, 1, wire.ABORT_USER_REQUEST, &diagnostic));
    api.bufferRelease()(&diagnostic);

    try std.testing.expectEqual(
        wire.STATUS_STALE_RUN,
        api.sessionRun()(session, 2, sdk.bytesView("accepted identifiers cannot be reused"), &options, &result, &diagnostic),
    );
    api.bufferRelease()(&diagnostic);
    try std.testing.expectEqual(
        wire.STATUS_STALE_RUN,
        api.sessionRun()(session, 1, sdk.bytesView("accepted identifiers cannot move backwards"), &options, &result, &diagnostic),
    );
    api.bufferRelease()(&diagnostic);

    probe.expected_run_id = 20;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.sessionRun()(session, 20, sdk.bytesView("Run identifiers may skip"), &options, &result, &diagnostic),
    );
    try std.testing.expectEqual(wire.STOP_END_TURN, result.stop_reason_code);
    const max_run_id = std.math.maxInt(u64);
    probe.expected_run_id = max_run_id;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.sessionRun()(session, max_run_id, sdk.bytesView("consume the final Run identifier"), &options, &result, &diagnostic),
    );
    try std.testing.expectEqual(
        wire.STATUS_STALE_RUN,
        api.sessionRun()(session, max_run_id, sdk.bytesView("UINT64_MAX cannot repeat"), &options, &result, &diagnostic),
    );
    api.bufferRelease()(&diagnostic);
    try std.testing.expectEqual(
        wire.STATUS_STALE_RUN,
        api.sessionRun()(session, 1, sdk.bytesView("UINT64_MAX cannot wrap to a low identifier"), &options, &result, &diagnostic),
    );
    api.bufferRelease()(&diagnostic);

    var second_session: ?*wire.SessionHandle = null;
    try std.testing.expectEqual(wire.STATUS_OK, api.sessionCreate()(runtime, &session_config, &callbacks, &second_session, &diagnostic));
    defer if (second_session) |handle| {
        _ = api.sessionDestroy()(handle, &diagnostic);
    };
    probe.expected_session = second_session;
    probe.expected_run_id = max_run_id;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.sessionRun()(second_session, max_run_id, sdk.bytesView("Run identifiers are scoped to a Session"), &options, &result, &diagnostic),
    );
    try std.testing.expectEqual(wire.STATUS_OK, api.sessionDestroy()(second_session, &diagnostic));
    second_session = null;

    try std.testing.expectEqual(wire.STATUS_OK, api.sessionDestroy()(session, &diagnostic));
    session = null;
    try std.testing.expectEqual(wire.STATUS_OK, api.runtimeDestroy()(runtime, &diagnostic));
    runtime = null;
}

test "L2 facade gate covers the core-idle epilogue until sessionRun returns" {
    const Barrier = struct {
        entered: std.atomic.Value(bool) = .init(false),
        release: std.atomic.Value(bool) = .init(false),
        seen_run_id: std.atomic.Value(u64) = .init(0),

        fn hook(raw: *anyopaque, run_id: u64) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            self.seen_run_id.store(run_id, .release);
            self.entered.store(true, .release);
            while (!self.release.load(.acquire)) std.Thread.yield() catch {};
        }

        fn wait(self: *@This()) !void {
            for (0..1_000_000) |_| {
                if (self.entered.load(.acquire)) return;
                std.Thread.yield() catch {};
            }
            return error.EpilogueHookTimeout;
        }
    };
    const RunWorker = struct {
        api: sdk.Api,
        session: *wire.SessionHandle,
        status: u32 = std.math.maxInt(u32),
        result: wire.RunResultV1 = undefined,
        diagnostic: wire.OwnedBytesV1 = .{ .ptr = null, .len = 0 },

        fn run(self: *@This()) void {
            var options = wire.RunOptionsV1{ .struct_size = @sizeOf(wire.RunOptionsV1), .max_turns = 1, .reserved = [_]u64{0} ** 4 };
            self.status = self.api.sessionRun()(self.session, 1, sdk.bytesView("pause in facade epilogue"), &options, &self.result, &self.diagnostic);
        }
    };

    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buf);
    var server = try harness.MockServer.start(FINAL_SSE, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);

    const raw_api = abi.metask_agentcore_get_api(wire.ABI_VERSION_V1) orelse return error.MissingApi;
    const api = try sdk.Api.validate(@ptrCast(@alignCast(raw_api)));
    var runtime_config = std.mem.zeroes(wire.RuntimeConfigV1);
    runtime_config.struct_size = @sizeOf(wire.RuntimeConfigV1);
    var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
    defer api.bufferRelease()(&diagnostic);
    var runtime: ?*wire.RuntimeHandle = null;
    try std.testing.expectEqual(wire.STATUS_OK, api.runtimeCreate()(&runtime_config, &runtime, &diagnostic));
    defer if (runtime) |handle| {
        _ = api.runtimeDestroy()(handle, &diagnostic);
    };

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
    var callbacks = std.mem.zeroes(wire.SessionCallbacksV1);
    callbacks.struct_size = @sizeOf(wire.SessionCallbacksV1);
    var session: ?*wire.SessionHandle = null;
    try std.testing.expectEqual(wire.STATUS_OK, api.sessionCreate()(runtime, &session_config, &callbacks, &session, &diagnostic));
    defer if (session) |handle| {
        _ = api.sessionDestroy()(handle, &diagnostic);
    };

    var barrier = Barrier{};
    abi.setTestEpilogueHook(.{ .ctx = &barrier, .runFn = Barrier.hook });
    defer abi.setTestEpilogueHook(null);
    var worker = RunWorker{ .api = api, .session = session.? };
    const run_thread = try std.Thread.spawn(.{}, RunWorker.run, .{&worker});
    var joined = false;
    defer if (!joined) {
        barrier.release.store(true, .release);
        run_thread.join();
    };
    try barrier.wait();
    try std.testing.expectEqual(@as(u64, 1), barrier.seen_run_id.load(.acquire));

    var competing_result: wire.RunResultV1 = undefined;
    var options = wire.RunOptionsV1{ .struct_size = @sizeOf(wire.RunOptionsV1), .max_turns = 1, .reserved = [_]u64{0} ** 4 };
    try std.testing.expectEqual(
        wire.STATUS_BUSY,
        api.sessionRun()(session, 2, sdk.bytesView("must not enter during epilogue"), &options, &competing_result, &diagnostic),
    );
    api.bufferRelease()(&diagnostic);
    try std.testing.expectEqual(wire.STATUS_BUSY, api.sessionDestroy()(session, &diagnostic));
    api.bufferRelease()(&diagnostic);
    try std.testing.expectEqual(wire.STATUS_TOO_LATE, api.sessionAbort()(session, 1, wire.ABORT_USER_REQUEST, &diagnostic));
    api.bufferRelease()(&diagnostic);

    barrier.release.store(true, .release);
    run_thread.join();
    joined = true;
    defer api.bufferRelease()(&worker.diagnostic);
    try std.testing.expectEqual(wire.STATUS_OK, worker.status);
    try std.testing.expectEqual(wire.STOP_END_TURN, worker.result.stop_reason_code);
    try std.testing.expectEqual(wire.STATUS_OK, api.sessionDestroy()(session, &diagnostic));
    session = null;
    try std.testing.expectEqual(wire.STATUS_OK, api.runtimeDestroy()(runtime, &diagnostic));
    runtime = null;
}

test "Host registry first identity binding is atomic under concurrent callbacks" {
    const Worker = struct {
        registry: *HostIdentityRegistry,
        session: *wire.SessionHandle,
        session_id: []const u8,
        ready: *std.atomic.Value(u32),
        start: *std.atomic.Value(bool),
        accepted: bool = false,

        fn run(self: *@This()) void {
            _ = self.ready.fetchAdd(1, .acq_rel);
            while (!self.start.load(.acquire)) std.Thread.yield() catch {};
            self.accepted = self.registry.accept(self.session, self.session_id);
        }
    };
    const Race = struct {
        fn run(first_id: []const u8, second_id: []const u8) ![2]bool {
            var session_storage: u8 = 0;
            const session: *wire.SessionHandle = @ptrCast(&session_storage);
            var registry = HostIdentityRegistry{};
            var ready = std.atomic.Value(u32).init(0);
            var start = std.atomic.Value(bool).init(false);
            var first = Worker{ .registry = &registry, .session = session, .session_id = first_id, .ready = &ready, .start = &start };
            var second = Worker{ .registry = &registry, .session = session, .session_id = second_id, .ready = &ready, .start = &start };
            const first_thread = try std.Thread.spawn(.{}, Worker.run, .{&first});
            errdefer {
                start.store(true, .release);
                first_thread.join();
            }
            const second_thread = try std.Thread.spawn(.{}, Worker.run, .{&second});
            while (ready.load(.acquire) != 2) std.Thread.yield() catch {};
            start.store(true, .release);
            first_thread.join();
            second_thread.join();
            return .{ first.accepted, second.accepted };
        }
    };

    const id_a = "000000000000000000000001";
    const id_b = "000000000000000000000002";
    for (0..64) |_| {
        const same = try Race.run(id_a, id_a);
        try std.testing.expect(same[0] and same[1]);
        const competing = try Race.run(id_a, id_b);
        try std.testing.expect(competing[0] != competing[1]);
    }
}

test "L2 invalid UTF-8 Host tool result is released and does not poison Session" {
    const FailureProbe = struct {
        calls: usize = 0,
        releases: usize = 0,
        invalid_utf8: [1]u8 = .{0xff},

        fn host(raw: ?*anyopaque, _: ?*const wire.RunContextV1, _: wire.BytesViewV1, out: ?*wire.OwnedBytesV1) callconv(.c) u32 {
            const self: *@This() = @ptrCast(@alignCast(raw orelse return wire.HOST_FAILED));
            self.calls += 1;
            (out orelse return wire.HOST_FAILED).* = .{ .ptr = &self.invalid_utf8, .len = self.invalid_utf8.len };
            return wire.HOST_OK;
        }

        fn release(raw: ?*anyopaque, out: ?*wire.OwnedBytesV1) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(raw orelse return));
            self.releases += 1;
            if (out) |value| value.* = .{ .ptr = null, .len = 0 };
        }
    };

    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buf);
    const bodies = [_][]const u8{ HOST_SSE, FINAL_SSE, FINAL_SSE };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);

    const raw_api = abi.metask_agentcore_get_api(wire.ABI_VERSION_V1) orelse return error.MissingApi;
    const api = try sdk.Api.validate(@ptrCast(@alignCast(raw_api)));
    var probe = FailureProbe{};
    var host = wire.HostToolV1{
        .struct_size = @sizeOf(wire.HostToolV1),
        .reserved0 = 0,
        .ctx = &probe,
        .name = sdk.bytesView("HostEcho"),
        .description = sdk.bytesView("Always fail"),
        .input_schema_json = sdk.bytesView("{\"type\":\"object\",\"properties\":{\"text\":{\"type\":\"string\"}},\"required\":[\"text\"]}"),
        .execute = FailureProbe.host,
        .release_result = FailureProbe.release,
        .reserved = [_]u64{0} ** 2,
    };
    var runtime_config = std.mem.zeroes(wire.RuntimeConfigV1);
    runtime_config.struct_size = @sizeOf(wire.RuntimeConfigV1);
    runtime_config.host_tools = @ptrCast(&host);
    runtime_config.host_tool_count = 1;
    var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
    defer api.bufferRelease()(&diagnostic);
    var runtime: ?*wire.RuntimeHandle = null;
    try std.testing.expectEqual(wire.STATUS_OK, api.runtimeCreate()(&runtime_config, &runtime, &diagnostic));
    defer {
        if (runtime) |handle| _ = api.runtimeDestroy()(handle, &diagnostic);
    }

    const allowed = [_]wire.BytesViewV1{sdk.bytesView("HostEcho")};
    var session_config = std.mem.zeroes(wire.SessionConfigV1);
    session_config.struct_size = @sizeOf(wire.SessionConfigV1);
    session_config.provider_kind_code = wire.PROVIDER_ANTHROPIC;
    session_config.permission_mode_code = wire.PERMISSION_BYPASS;
    session_config.shell_policy_code = wire.SHELL_DISABLED;
    session_config.api_key = sdk.bytesView("failure-test-key");
    session_config.model = sdk.bytesView("failure-test-model");
    session_config.base_url = sdk.bytesView(url);
    session_config.workspace_root = sdk.bytesView(root);
    session_config.workspace_home = sdk.bytesView(root);
    session_config.allowed_tools = &allowed;
    session_config.allowed_tool_count = allowed.len;
    var callbacks = std.mem.zeroes(wire.SessionCallbacksV1);
    callbacks.struct_size = @sizeOf(wire.SessionCallbacksV1);
    var session: ?*wire.SessionHandle = null;
    try std.testing.expectEqual(wire.STATUS_OK, api.sessionCreate()(runtime, &session_config, &callbacks, &session, &diagnostic));
    defer {
        if (session) |handle| _ = api.sessionDestroy()(handle, &diagnostic);
    }

    var options = wire.RunOptionsV1{ .struct_size = @sizeOf(wire.RunOptionsV1), .max_turns = 4, .reserved = [_]u64{0} ** 4 };
    var result: wire.RunResultV1 = undefined;
    try std.testing.expectEqual(wire.STATUS_OK, api.sessionRun()(session, 1, sdk.bytesView("invoke failing host"), &options, &result, &diagnostic));
    try std.testing.expectEqual(wire.STOP_END_TURN, result.stop_reason_code);
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expectEqual(@as(usize, 1), probe.releases);

    try std.testing.expectEqual(wire.STATUS_OK, api.sessionRun()(session, 2, sdk.bytesView("run again"), &options, &result, &diagnostic));
    try std.testing.expectEqual(wire.STOP_END_TURN, result.stop_reason_code);
    try std.testing.expectEqual(wire.STATUS_OK, api.sessionDestroy()(session, &diagnostic));
    session = null;
    try std.testing.expectEqual(wire.STATUS_OK, api.runtimeDestroy()(runtime, &diagnostic));
    runtime = null;
}

test "L2 Event callback fatal aborts the Run and poisons the ABI Session" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buf);
    const bodies = [_][]const u8{FINAL_SSE};
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);

    const raw_api = abi.metask_agentcore_get_api(wire.ABI_VERSION_V1) orelse return error.MissingApi;
    const api = try sdk.Api.validate(@ptrCast(@alignCast(raw_api)));
    var runtime_config = std.mem.zeroes(wire.RuntimeConfigV1);
    runtime_config.struct_size = @sizeOf(wire.RuntimeConfigV1);
    var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
    defer api.bufferRelease()(&diagnostic);
    var runtime: ?*wire.RuntimeHandle = null;
    try std.testing.expectEqual(wire.STATUS_OK, api.runtimeCreate()(&runtime_config, &runtime, &diagnostic));
    defer {
        if (runtime) |handle| _ = api.runtimeDestroy()(handle, &diagnostic);
    }

    var session_config = std.mem.zeroes(wire.SessionConfigV1);
    session_config.struct_size = @sizeOf(wire.SessionConfigV1);
    session_config.provider_kind_code = wire.PROVIDER_ANTHROPIC;
    session_config.permission_mode_code = wire.PERMISSION_BYPASS;
    session_config.shell_policy_code = wire.SHELL_DISABLED;
    session_config.api_key = sdk.bytesView("event-fatal-key");
    session_config.model = sdk.bytesView("event-fatal-model");
    session_config.base_url = sdk.bytesView(url);
    session_config.workspace_root = sdk.bytesView(root);
    session_config.workspace_home = sdk.bytesView(root);
    var probe = FatalEventProbe{};
    var callbacks = std.mem.zeroes(wire.SessionCallbacksV1);
    callbacks.struct_size = @sizeOf(wire.SessionCallbacksV1);
    callbacks.ctx = &probe;
    callbacks.on_event = FatalEventProbe.event;
    var session: ?*wire.SessionHandle = null;
    try std.testing.expectEqual(wire.STATUS_OK, api.sessionCreate()(runtime, &session_config, &callbacks, &session, &diagnostic));
    defer {
        if (session) |handle| _ = api.sessionDestroy()(handle, &diagnostic);
    }

    var options = wire.RunOptionsV1{ .struct_size = @sizeOf(wire.RunOptionsV1), .max_turns = 2, .reserved = [_]u64{0} ** 4 };
    var result: wire.RunResultV1 = undefined;
    try std.testing.expectEqual(
        wire.STATUS_CALLBACK_FAILED,
        api.sessionRun()(session, 1, sdk.bytesView("fail event delivery"), &options, &result, &diagnostic),
    );
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    api.bufferRelease()(&diagnostic);
    try std.testing.expectEqual(wire.STATUS_INVALID_STATE, api.sessionAbort()(session, 0, wire.ABORT_USER_REQUEST, &diagnostic));
    api.bufferRelease()(&diagnostic);
    try std.testing.expectEqual(
        wire.STATUS_INVALID_STATE,
        api.sessionRun()(session, 2, sdk.bytesView("must stay poisoned"), &options, &result, &diagnostic),
    );
    api.bufferRelease()(&diagnostic);
    try std.testing.expectEqual(wire.STATUS_OK, api.sessionDestroy()(session, &diagnostic));
    session = null;
    try std.testing.expectEqual(wire.STATUS_OK, api.runtimeDestroy()(runtime, &diagnostic));
    runtime = null;
}

test "L2 Event callback may cooperatively abort without poisoning the ABI Session" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buf);
    const bodies = [_][]const u8{ FINAL_SSE, FINAL_SSE };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);

    const raw_api = abi.metask_agentcore_get_api(wire.ABI_VERSION_V1) orelse return error.MissingApi;
    const api = try sdk.Api.validate(@ptrCast(@alignCast(raw_api)));
    var runtime_config = std.mem.zeroes(wire.RuntimeConfigV1);
    runtime_config.struct_size = @sizeOf(wire.RuntimeConfigV1);
    var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
    defer api.bufferRelease()(&diagnostic);
    var runtime: ?*wire.RuntimeHandle = null;
    try std.testing.expectEqual(wire.STATUS_OK, api.runtimeCreate()(&runtime_config, &runtime, &diagnostic));
    defer {
        if (runtime) |handle| _ = api.runtimeDestroy()(handle, &diagnostic);
    }

    var session_config = std.mem.zeroes(wire.SessionConfigV1);
    session_config.struct_size = @sizeOf(wire.SessionConfigV1);
    session_config.provider_kind_code = wire.PROVIDER_ANTHROPIC;
    session_config.permission_mode_code = wire.PERMISSION_BYPASS;
    session_config.shell_policy_code = wire.SHELL_DISABLED;
    session_config.api_key = sdk.bytesView("event-abort-key");
    session_config.model = sdk.bytesView("event-abort-model");
    session_config.base_url = sdk.bytesView(url);
    session_config.workspace_root = sdk.bytesView(root);
    session_config.workspace_home = sdk.bytesView(root);
    var probe = AbortEventProbe{ .api = api };
    var callbacks = std.mem.zeroes(wire.SessionCallbacksV1);
    callbacks.struct_size = @sizeOf(wire.SessionCallbacksV1);
    callbacks.ctx = &probe;
    callbacks.on_event = AbortEventProbe.event;
    var session: ?*wire.SessionHandle = null;
    try std.testing.expectEqual(wire.STATUS_OK, api.sessionCreate()(runtime, &session_config, &callbacks, &session, &diagnostic));
    defer {
        if (session) |handle| _ = api.sessionDestroy()(handle, &diagnostic);
    }

    var options = wire.RunOptionsV1{ .struct_size = @sizeOf(wire.RunOptionsV1), .max_turns = 2, .reserved = [_]u64{0} ** 4 };
    var result: wire.RunResultV1 = undefined;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.sessionRun()(session, 1, sdk.bytesView("abort from callback"), &options, &result, &diagnostic),
    );
    try std.testing.expectEqual(wire.STATUS_STALE_RUN, probe.stale_abort_status);
    try std.testing.expectEqual(wire.STATUS_OK, probe.abort_status);
    try std.testing.expectEqual(wire.STOP_ABORTED, result.stop_reason_code);

    probe.calls = 1;
    try std.testing.expectEqual(
        wire.STATUS_OK,
        api.sessionRun()(session, 2, sdk.bytesView("run after abort"), &options, &result, &diagnostic),
    );
    try std.testing.expectEqual(wire.STOP_END_TURN, result.stop_reason_code);
    try std.testing.expectEqual(wire.STATUS_STALE_RUN, api.sessionAbort()(session, 1, wire.ABORT_USER_REQUEST, &diagnostic));
    api.bufferRelease()(&diagnostic);
    try std.testing.expectEqual(wire.STATUS_TOO_LATE, api.sessionAbort()(session, 2, wire.ABORT_USER_REQUEST, &diagnostic));
    api.bufferRelease()(&diagnostic);
    try std.testing.expectEqual(wire.STATUS_OK, api.sessionDestroy()(session, &diagnostic));
    session = null;
    try std.testing.expectEqual(wire.STATUS_OK, api.runtimeDestroy()(runtime, &diagnostic));
    runtime = null;
}

fn expectUiOutcome(mode: UiFailureMode, expected_releases: usize, expected_status: u32, expected_stop: u32) !void {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = try rootPath(&tmp, &root_buf);
    const bodies = [_][]const u8{ ASK_SSE, FINAL_SSE, FINAL_SSE };
    var server = try harness.MockServer.startCassette(&bodies, 0);
    defer server.stop();
    const url = try server.urlOwned(a);
    defer a.free(url);

    const raw_api = abi.metask_agentcore_get_api(wire.ABI_VERSION_V1) orelse return error.MissingApi;
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
    var probe = UiFailureProbe{ .mode = mode, .api = api };
    var callbacks = std.mem.zeroes(wire.SessionCallbacksV1);
    callbacks.struct_size = @sizeOf(wire.SessionCallbacksV1);
    callbacks.ctx = &probe;
    callbacks.on_ui_request = UiFailureProbe.ui;
    callbacks.release_response = UiFailureProbe.release;
    var session: ?*wire.SessionHandle = null;
    try std.testing.expectEqual(wire.STATUS_OK, api.sessionCreate()(runtime, &session_config, &callbacks, &session, &diagnostic));
    defer {
        if (session) |handle| _ = api.sessionDestroy()(handle, &diagnostic);
    }

    var options = wire.RunOptionsV1{ .struct_size = @sizeOf(wire.RunOptionsV1), .max_turns = 2, .reserved = [_]u64{0} ** 4 };
    var result: wire.RunResultV1 = undefined;
    try std.testing.expectEqual(expected_status, api.sessionRun()(session, 1, sdk.bytesView("ask through Host UI"), &options, &result, &diagnostic));
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expectEqual(expected_releases, probe.releases);
    api.bufferRelease()(&diagnostic);
    if (expected_status == wire.STATUS_CALLBACK_FAILED) {
        try std.testing.expectEqual(wire.STATUS_INVALID_STATE, api.sessionRun()(session, 2, sdk.bytesView("must stay poisoned"), &options, &result, &diagnostic));
        api.bufferRelease()(&diagnostic);
    } else {
        try std.testing.expectEqual(expected_stop, result.stop_reason_code);
        if (mode == .abort_twice) {
            try std.testing.expectEqual(wire.STATUS_BUSY, probe.nested_run_status);
            try std.testing.expectEqual(wire.STATUS_BUSY, probe.nested_destroy_status);
            try std.testing.expectEqual(wire.STATUS_OK, probe.first_abort_status);
            try std.testing.expectEqual(wire.STATUS_OK, probe.second_abort_status);
        }
        try std.testing.expectEqual(wire.STATUS_OK, api.sessionRun()(session, 2, sdk.bytesView("Session remains reusable"), &options, &result, &diagnostic));
        try std.testing.expectEqual(wire.STOP_END_TURN, result.stop_reason_code);
    }
    try std.testing.expectEqual(wire.STATUS_OK, api.sessionDestroy()(session, &diagnostic));
    session = null;
    try std.testing.expectEqual(wire.STATUS_OK, api.runtimeDestroy()(runtime, &diagnostic));
    runtime = null;
}

test "L2 Host UI fatal aborts the Run and poisons the ABI Session" {
    try expectUiOutcome(.fatal, 0, wire.STATUS_CALLBACK_FAILED, 0);
}

test "L2 oversized Host UI response is released and poisons the ABI Session" {
    try expectUiOutcome(.oversized, 1, wire.STATUS_CALLBACK_FAILED, 0);
}

test "L2 unknown Host UI status poisons the ABI Session" {
    try expectUiOutcome(.unknown, 0, wire.STATUS_CALLBACK_FAILED, 0);
}

test "L2 unavailable Host UI is a reusable business outcome" {
    try expectUiOutcome(.unavailable, 0, wire.STATUS_OK, wire.STOP_END_TURN);
}

test "L2 Host UI callback may repeat abort while nested run and destroy stay busy" {
    try expectUiOutcome(.abort_twice, 0, wire.STATUS_OK, wire.STOP_ABORTED);
}

fn expectMappedEventEquals(event: core.protocol.ui_event.CoreEvent, expected: sdk.CoreEvent) !void {
    const mapped = abi.protocol_v1.event(event) orelse return error.UnexpectedInternalOnlyEvent;
    try std.testing.expectEqualDeep(expected, mapped);
    const encoded = try std.json.Stringify.valueAlloc(std.testing.allocator, mapped, .{});
    defer std.testing.allocator.free(encoded);
    const parsed = try sdk.decodeCoreEvent(std.testing.allocator, encoded);
    defer parsed.deinit();
    switch (parsed.value) {
        .known => |actual| try std.testing.expectEqualDeep(expected, actual),
        .unknown => return error.UnexpectedUnknownEvent,
    }
}

test "L2 every public AgentCoreEventV1 mapping preserves its complete payload" {
    try expectMappedEventEquals(.{ .text_chunk = "text-sentinel" }, .{ .text_chunk = "text-sentinel" });
    try expectMappedEventEquals(
        .{ .tool_start = .{ .id = "tool-id", .name = "ToolName", .input = "input-json" } },
        .{ .tool_start = .{ .id = "tool-id", .name = "ToolName", .input = "input-json" } },
    );
    try expectMappedEventEquals(
        .{ .tool_progress = .{ .id = "progress-id", .text = "progress-text" } },
        .{ .tool_progress = .{ .id = "progress-id", .text = "progress-text" } },
    );
    try expectMappedEventEquals(
        .{ .progress = .{ .turn = 11, .tool_name = "ProgressTool", .tool_input = "progress-input", .tool_calls = 22 } },
        .{ .progress = .{ .turn = 11, .tool_name = "ProgressTool", .tool_input = "progress-input", .tool_calls = 22 } },
    );
    try expectMappedEventEquals(
        .{ .tool_result = .{
            .id = "result-id",
            .name = "ResultTool",
            .input = "result-input",
            .content = "result-content",
            .is_error = true,
            .elapsed_ms = 33,
        } },
        .{ .tool_result = .{
            .id = "result-id",
            .name = "ResultTool",
            .input = "result-input",
            .content = "result-content",
            .is_error = true,
            .elapsed_ms = 33,
        } },
    );
    try expectMappedEventEquals(
        .{ .usage = .{
            .input_tokens = 101,
            .output_tokens = 202,
            .cache_read_input_tokens = 303,
            .cache_creation_input_tokens = 404,
        } },
        .{ .usage = .{
            .input_tokens = 101,
            .output_tokens = 202,
            .cache_read_input_tokens = 303,
            .cache_creation_input_tokens = 404,
        } },
    );
    try expectMappedEventEquals(
        .{ .context_warning = .{
            .current_tokens = 1001,
            .warning_threshold = 2002,
            .auto_compact_threshold = 3003,
            .blocking_limit = 4004,
            .level = "warning-level",
        } },
        .{ .context_warning = .{
            .current_tokens = 1001,
            .warning_threshold = 2002,
            .auto_compact_threshold = 3003,
            .blocking_limit = 4004,
            .level = "warning-level",
        } },
    );
    try expectMappedEventEquals(
        .{ .auto_compact = .{
            .dropped = 12,
            .kept = 23,
            .before_tokens = 3400,
            .after_tokens = 4500,
            .cause = "compact-cause",
        } },
        .{ .auto_compact = .{
            .dropped = 12,
            .kept = 23,
            .before_tokens = 3400,
            .after_tokens = 4500,
            .cause = "compact-cause",
        } },
    );
    try expectMappedEventEquals(
        .{ .retry_notice = .{ .attempt = 13, .max = 24, .delay_ms = 3500 } },
        .{ .retry_notice = .{ .attempt = 13, .max = 24, .delay_ms = 3500 } },
    );
    try expectMappedEventEquals(.stream_done, .stream_done);
}

fn expectMappedUiRequestEquals(request: *const core.protocol.ui_request.UiRequest, expected: sdk.UiRequest) !void {
    const encoded = try abi.protocol_v1.encodeUiRequest(std.testing.allocator, request);
    defer std.testing.allocator.free(encoded);
    const parsed = try sdk.decodeUiRequest(std.testing.allocator, encoded);
    defer parsed.deinit();
    try std.testing.expectEqualDeep(expected, parsed.value);
}

test "L2 every UiRequestV1 mapping preserves its complete payload" {
    const options = [_]core.tool_context.AskOption{
        .{ .label = "Yes", .description = "Proceed", .preview = "preview" },
        .{ .label = "No", .description = "Stop" },
    };
    const questions = [_]core.tool_context.AskQuestion{.{
        .question = "Continue?",
        .header = "Choice",
        .multi = false,
        .options = &options,
    }};
    const ask = core.protocol.ui_request.UiRequest{ .ask_question = &questions };
    const permission = core.protocol.ui_request.UiRequest{ .permission = .{ .tool = "Bash", .args = "{}" } };
    const plan = core.protocol.ui_request.UiRequest{ .plan_approval = .{ .plan_md = "Do it", .kg_step_count = 2 } };
    const custom = core.protocol.ui_request.UiRequest{ .custom = .{ .kind = "video_timeline", .payload_json = "{\"clips\":[]}" } };
    const public_options = [_]sdk.protocol.AskOption{
        .{ .label = "Yes", .description = "Proceed", .preview = "preview" },
        .{ .label = "No", .description = "Stop", .preview = "" },
    };
    const public_questions = [_]sdk.protocol.AskQuestion{.{
        .question = "Continue?",
        .header = "Choice",
        .multi = false,
        .options = &public_options,
    }};
    try expectMappedUiRequestEquals(&ask, .{ .ask_question = &public_questions });
    try expectMappedUiRequestEquals(&permission, .{ .permission = .{ .tool = "Bash", .args = "{}" } });
    try std.testing.expectError(
        error.UnsupportedUiRequest,
        abi.protocol_v1.encodeUiRequest(std.testing.allocator, &plan),
    );
    try std.testing.expectError(
        error.UnsupportedUiRequest,
        abi.protocol_v1.encodeUiRequest(std.testing.allocator, &custom),
    );
}
