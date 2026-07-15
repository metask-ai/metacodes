//! Thin C ABI v1 facade over AgentRuntime and AgentSession.

const std = @import("std");
const wire = @import("metacodes_agentcore_types");
const core = @import("metacodes-core");
const ui_request = core.protocol.ui_request;

const allocator = std.heap.c_allocator;

const AbiHostTool = struct {
    ctx: ?*anyopaque,
    execute_fn: wire.HostExecuteFnV1,
    release_fn: wire.HostReleaseFnV1,

    fn execute(raw: *anyopaque, session_id: []const u8, args: []const u8) core.agent_session.HostToolError!core.agent_session.HostToolResult {
        const self: *AbiHostTool = @ptrCast(@alignCast(raw));
        var out = wire.OwnedBytesV1{ .ptr = null, .len = 0 };
        const status = self.execute_fn(self.ctx, view(session_id), view(args), &out);
        if (status != wire.HOST_OK) {
            if (out.ptr != null or out.len != 0) self.release_fn(self.ctx, &out);
            return switch (status) {
                wire.HOST_REJECTED => error.HostToolRejected,
                wire.HOST_FAILED => error.HostToolFailed,
                else => error.HostToolFailed,
            };
        }
        const bytes = ownedSlice(out) catch {
            self.release_fn(self.ctx, &out);
            return error.HostToolFailed;
        };
        return .{ .bytes = bytes, .release_ctx = self, .releaseFn = release };
    }

    fn release(raw: *anyopaque, bytes: []const u8) void {
        const self: *AbiHostTool = @ptrCast(@alignCast(raw));
        var out = wire.OwnedBytesV1{ .ptr = if (bytes.len == 0) null else @constCast(bytes.ptr), .len = bytes.len };
        self.release_fn(self.ctx, &out);
    }
};

const AbiRuntime = struct {
    core_runtime: *core.agent_session.AgentRuntime,
    host_tools: []AbiHostTool,

    fn handle(self: *AbiRuntime) *wire.RuntimeHandle {
        return @ptrCast(self);
    }
};

const AbiSession = struct {
    callbacks: wire.SessionCallbacksV1,
    core_session: *core.agent_session.AgentSession,

    fn handle(self: *AbiSession) *wire.SessionHandle {
        return @ptrCast(self);
    }

    fn emit(raw: *anyopaque, _: core.session_id.SessionId, run_id: u64, event: core.protocol.ui_event.CoreEvent) bool {
        const self: *AbiSession = @ptrCast(@alignCast(raw));
        const callback = self.callbacks.on_event orelse return true;
        const json = std.json.Stringify.valueAlloc(allocator, event, .{}) catch return false;
        defer allocator.free(json);
        return callback(self.callbacks.ctx, self.handle(), run_id, view(json)) == wire.CALLBACK_CONTINUE;
    }

    fn requestUi(raw: *anyopaque, _: core.session_id.SessionId, response_allocator: std.mem.Allocator, req: *const ui_request.UiRequest, out: *ui_request.UiResponse) anyerror!ui_request.RequestOutcome {
        const self: *AbiSession = @ptrCast(@alignCast(raw));
        const callback = self.callbacks.on_ui_request orelse return .unavailable;
        const release_fn = self.callbacks.release_response orelse return error.HostUiFailed;
        const request_json = try ui_request.serializeUiRequest(response_allocator, req);
        defer response_allocator.free(request_json);
        var response = wire.OwnedBytesV1{ .ptr = null, .len = 0 };
        const status = callback(self.callbacks.ctx, self.handle(), view(request_json), &response);
        const must_release = status == wire.UI_ANSWERED or response.ptr != null or response.len != 0;
        defer if (must_release) release_fn(self.callbacks.ctx, &response);
        return switch (status) {
            wire.UI_UNAVAILABLE => .unavailable,
            wire.UI_ANSWERED => blk: {
                const bytes = try ownedSlice(response);
                try parseUiResponse(response_allocator, req, bytes, out);
                break :blk .answered;
            },
            else => error.HostUiFailed,
        };
    }
};

fn runtimeFrom(handle: *wire.RuntimeHandle) *AbiRuntime {
    return @ptrCast(@alignCast(handle));
}
fn sessionFrom(handle: *wire.SessionHandle) *AbiSession {
    return @ptrCast(@alignCast(handle));
}

fn view(bytes: []const u8) wire.BytesViewV1 {
    return .{ .ptr = if (bytes.len == 0) null else bytes.ptr, .len = bytes.len };
}

fn borrowed(v: wire.BytesViewV1) error{ InvalidArgument, Overflow }![]const u8 {
    const len = std.math.cast(usize, v.len) orelse return error.Overflow;
    if (len == 0) return "";
    return (v.ptr orelse return error.InvalidArgument)[0..len];
}

fn text(v: wire.BytesViewV1) ![]const u8 {
    const bytes = try borrowed(v);
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8;
    return bytes;
}

fn ownedSlice(v: wire.OwnedBytesV1) error{ InvalidArgument, Overflow }![]const u8 {
    return borrowed(.{ .ptr = v.ptr, .len = v.len });
}

fn allZero(values: anytype) bool {
    for (values) |value| if (value != 0) return false;
    return true;
}

fn emptyError(out_error: ?*wire.OwnedBytesV1) void {
    if (out_error) |out| out.* = .{ .ptr = null, .len = 0 };
}

fn fail(status: u32, message: []const u8, out_error: ?*wire.OwnedBytesV1) u32 {
    const out = out_error orelse return status;
    const copy = allocator.dupe(u8, message) catch return wire.STATUS_OUT_OF_MEMORY;
    out.* = .{ .ptr = copy.ptr, .len = copy.len };
    return status;
}

fn failError(status: u32, err: anyerror, out_error: ?*wire.OwnedBytesV1) u32 {
    var buf: [192]u8 = undefined;
    const message = std.fmt.bufPrint(&buf, "{s}: {s}", .{ statusText(status), @errorName(err) }) catch "AgentCore operation failed";
    return fail(status, message, out_error);
}

fn statusText(status: u32) []const u8 {
    return switch (status) {
        wire.STATUS_INVALID_ARGUMENT => "invalid argument",
        wire.STATUS_OUT_OF_MEMORY => "out of memory",
        wire.STATUS_BUSY => "busy",
        wire.STATUS_STALE_RUN => "stale run",
        wire.STATUS_TOO_LATE => "abort too late",
        wire.STATUS_INVALID_STATE => "invalid state",
        wire.STATUS_CALLBACK_FAILED => "callback failed",
        else => "AgentCore error",
    };
}

fn inputErrorStatus(err: anyerror) u32 {
    return if (err == error.OutOfMemory) wire.STATUS_OUT_OF_MEMORY else wire.STATUS_INVALID_ARGUMENT;
}

fn provider(code: u32) ?core.types.ProviderKind {
    return switch (code) {
        wire.PROVIDER_ANTHROPIC => .anthropic,
        wire.PROVIDER_OPENAI => .openai,
        wire.PROVIDER_GEMINI => .gemini,
        else => null,
    };
}

fn permissionMode(code: u32) ?core.types.PermissionMode {
    return switch (code) {
        wire.PERMISSION_DEFAULT => .default,
        wire.PERMISSION_ACCEPT_EDITS => .accept_edits,
        wire.PERMISSION_PLAN => .plan,
        wire.PERMISSION_AUTO => .auto,
        wire.PERMISSION_DONT_ASK => .dont_ask,
        wire.PERMISSION_BYPASS => .bypass_permissions,
        else => null,
    };
}

fn shellPolicy(code: u32) ?core.agent_session.ShellPolicy {
    return switch (code) {
        wire.SHELL_DISABLED => .disabled,
        wire.SHELL_SANDBOXED => .sandboxed,
        wire.SHELL_UNRESTRICTED => .unrestricted,
        else => null,
    };
}

fn stopReason(reason: core.agent_loop.StopReason) u32 {
    return switch (reason) {
        .end_turn => wire.STOP_END_TURN,
        .max_turns => wire.STOP_MAX_TURNS,
        .aborted => wire.STOP_ABORTED,
        .tool_error => wire.STOP_TOOL_ERROR,
        .api_error => wire.STOP_API_ERROR,
        .tool_loop => wire.STOP_TOOL_LOOP,
        .suspended => wire.STOP_SUSPENDED,
        .backgrounded => wire.STOP_BACKGROUNDED,
        .budget => wire.STOP_BUDGET,
    };
}

fn borrowedViews(arena: std.mem.Allocator, ptr: ?[*]const wire.BytesViewV1, count64: u64) ![]const []const u8 {
    const count = std.math.cast(usize, count64) orelse return error.Overflow;
    if (count == 0) return &.{};
    const values = (ptr orelse return error.InvalidArgument)[0..count];
    const out = try arena.alloc([]const u8, count);
    for (values, 0..) |value, i| out[i] = try text(value);
    return out;
}

fn parseSchema(arena: std.mem.Allocator, encoded: []const u8) !core.json.InputSchema {
    const root = try std.json.parseFromSliceLeaky(std.json.Value, arena, encoded, .{});
    if (root != .object) return error.InvalidSchema;
    const type_value = root.object.get("type") orelse return error.InvalidSchema;
    if (type_value != .string or !std.mem.eql(u8, type_value.string, "object")) return error.InvalidSchema;
    var schema = core.json.InputSchema{ .type = type_value.string };
    if (root.object.get("properties")) |properties| {
        if (properties != .object) return error.InvalidSchema;
        schema.properties = properties.object;
    }
    if (root.object.get("required")) |required| {
        if (required != .array) return error.InvalidSchema;
        const names = try arena.alloc([]const u8, required.array.items.len);
        for (required.array.items, 0..) |item, i| {
            if (item != .string) return error.InvalidSchema;
            names[i] = item.string;
        }
        schema.required = names;
    }
    return schema;
}

fn parseUiResponse(a: std.mem.Allocator, req: *const ui_request.UiRequest, encoded: []const u8, out: *ui_request.UiResponse) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, a, encoded, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidUiResponse;
    switch (req.*) {
        .ask_question => |questions| {
            const value = parsed.value.object.get("answers") orelse return error.InvalidUiResponse;
            if (value != .array or value.array.items.len != questions.len) return error.InvalidUiResponse;
            const answers = try a.alloc([]const u8, value.array.items.len);
            var copied: usize = 0;
            errdefer {
                for (answers[0..copied]) |answer| a.free(@constCast(answer));
                a.free(answers);
            }
            for (value.array.items, 0..) |item, i| {
                if (item != .string) return error.InvalidUiResponse;
                answers[i] = try a.dupe(u8, item.string);
                copied += 1;
            }
            out.* = .{ .answers = answers };
        },
        .permission => {
            const value = parsed.value.object.get("permission") orelse return error.InvalidUiResponse;
            if (value != .string) return error.InvalidUiResponse;
            out.* = .{ .permission = if (std.mem.eql(u8, value.string, "allow_once")) .allow_once else if (std.mem.eql(u8, value.string, "allow_always")) .allow_always else if (std.mem.eql(u8, value.string, "deny_once")) .deny_once else if (std.mem.eql(u8, value.string, "deny_tool_session")) .deny_tool_session else return error.InvalidUiResponse };
        },
        .plan_approval => {
            const value = parsed.value.object.get("plan_approval") orelse return error.InvalidUiResponse;
            if (value != .string) return error.InvalidUiResponse;
            out.* = .{ .plan_approval = if (std.mem.eql(u8, value.string, "approve_default")) .approve_default else if (std.mem.eql(u8, value.string, "approve_accept_edits")) .approve_accept_edits else if (std.mem.eql(u8, value.string, "reject")) .reject else return error.InvalidUiResponse };
        },
        .custom => {
            const value = parsed.value.object.get("custom") orelse return error.InvalidUiResponse;
            if (value != .string) return error.InvalidUiResponse;
            out.* = .{ .custom = try a.dupe(u8, value.string) };
        },
    }
}

fn runtimeCreate(config_ptr: ?*const wire.RuntimeConfigV1, out_runtime: ?*?*wire.RuntimeHandle, out_error: ?*wire.OwnedBytesV1) callconv(.c) u32 {
    if (out_runtime) |out| out.* = null;
    emptyError(out_error);
    const config = config_ptr orelse return fail(wire.STATUS_INVALID_ARGUMENT, "runtime config is required", out_error);
    const out = out_runtime orelse return fail(wire.STATUS_INVALID_ARGUMENT, "out_runtime is required", out_error);
    if (config.struct_size != @sizeOf(wire.RuntimeConfigV1) or config.reserved0 != 0 or !allZero(config.reserved))
        return fail(wire.STATUS_INVALID_ARGUMENT, "invalid RuntimeConfigV1", out_error);

    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const a = scratch.allocator();
    const builtin_names = borrowedViews(a, config.builtin_tools, config.builtin_tool_count) catch |err|
        return failError(inputErrorStatus(err), err, out_error);
    const host_count = std.math.cast(usize, config.host_tool_count) orelse
        return fail(wire.STATUS_INVALID_ARGUMENT, "host tool count overflow", out_error);
    const host_descriptors = if (host_count == 0) &.{} else (config.host_tools orelse
        return fail(wire.STATUS_INVALID_ARGUMENT, "host_tools is required", out_error))[0..host_count];

    const self = allocator.create(AbiRuntime) catch return fail(wire.STATUS_OUT_OF_MEMORY, "allocating Runtime failed", out_error);
    var keep_self = false;
    defer if (!keep_self) allocator.destroy(self);
    self.host_tools = allocator.alloc(AbiHostTool, host_count) catch return fail(wire.STATUS_OUT_OF_MEMORY, "allocating Host tools failed", out_error);
    var keep_host_tools = false;
    defer if (!keep_host_tools) allocator.free(self.host_tools);
    const native_tools = a.alloc(core.agent_session.HostSyncTool, host_count) catch return fail(wire.STATUS_OUT_OF_MEMORY, "allocating Host definitions failed", out_error);
    for (host_descriptors, 0..) |descriptor, i| {
        if (descriptor.struct_size != @sizeOf(wire.HostToolV1) or descriptor.reserved0 != 0 or !allZero(descriptor.reserved) or descriptor.execute == null or descriptor.release_result == null)
            return fail(wire.STATUS_INVALID_ARGUMENT, "invalid HostToolV1", out_error);
        const name = text(descriptor.name) catch |err| return failError(wire.STATUS_INVALID_ARGUMENT, err, out_error);
        const description = text(descriptor.description) catch |err| return failError(wire.STATUS_INVALID_ARGUMENT, err, out_error);
        const schema_json = text(descriptor.input_schema_json) catch |err| return failError(wire.STATUS_INVALID_ARGUMENT, err, out_error);
        const schema = parseSchema(a, schema_json) catch |err| return failError(inputErrorStatus(err), err, out_error);
        self.host_tools[i] = .{ .ctx = descriptor.ctx, .execute_fn = descriptor.execute.?, .release_fn = descriptor.release_result.? };
        native_tools[i] = .{ .definition = .{ .name = name, .description = description, .input_schema = schema }, .ctx = &self.host_tools[i], .execute = AbiHostTool.execute };
    }
    self.core_runtime = core.agent_session.AgentRuntime.create(allocator, .{ .builtin_tools = builtin_names, .host_sync_tools = native_tools }) catch |err| {
        return failError(if (err == error.OutOfMemory) wire.STATUS_OUT_OF_MEMORY else wire.STATUS_CORE_ERROR, err, out_error);
    };
    out.* = self.handle();
    keep_host_tools = true;
    keep_self = true;
    return wire.STATUS_OK;
}

fn runtimeDestroy(handle: ?*wire.RuntimeHandle, out_error: ?*wire.OwnedBytesV1) callconv(.c) u32 {
    emptyError(out_error);
    const self = runtimeFrom(handle orelse return fail(wire.STATUS_INVALID_ARGUMENT, "runtime is required", out_error));
    self.core_runtime.destroy() catch |err| return failError(if (err == error.RuntimeBusy) wire.STATUS_BUSY else wire.STATUS_INVALID_STATE, err, out_error);
    allocator.free(self.host_tools);
    allocator.destroy(self);
    return wire.STATUS_OK;
}

fn sessionCreate(runtime_handle: ?*wire.RuntimeHandle, config_ptr: ?*const wire.SessionConfigV1, callbacks_ptr: ?*const wire.SessionCallbacksV1, out_session: ?*?*wire.SessionHandle, out_error: ?*wire.OwnedBytesV1) callconv(.c) u32 {
    if (out_session) |out| out.* = null;
    emptyError(out_error);
    const runtime = runtimeFrom(runtime_handle orelse return fail(wire.STATUS_INVALID_ARGUMENT, "runtime is required", out_error));
    const config = config_ptr orelse return fail(wire.STATUS_INVALID_ARGUMENT, "session config is required", out_error);
    const callbacks = callbacks_ptr orelse return fail(wire.STATUS_INVALID_ARGUMENT, "session callbacks are required", out_error);
    const out = out_session orelse return fail(wire.STATUS_INVALID_ARGUMENT, "out_session is required", out_error);
    if (config.struct_size != @sizeOf(wire.SessionConfigV1) or !allZero(config.reserved) or callbacks.struct_size != @sizeOf(wire.SessionCallbacksV1) or callbacks.reserved0 != 0 or !allZero(callbacks.reserved) or (callbacks.on_ui_request != null and callbacks.release_response == null))
        return fail(wire.STATUS_INVALID_ARGUMENT, "invalid SessionConfigV1 or SessionCallbacksV1", out_error);
    const kind = provider(config.provider_kind_code) orelse return fail(wire.STATUS_INVALID_ARGUMENT, "unknown provider", out_error);
    const mode = permissionMode(config.permission_mode_code) orelse return fail(wire.STATUS_INVALID_ARGUMENT, "unknown permission mode", out_error);
    const shell = shellPolicy(config.shell_policy_code) orelse return fail(wire.STATUS_INVALID_ARGUMENT, "unknown shell policy", out_error);
    const api_key = text(config.api_key) catch |err| return failError(wire.STATUS_INVALID_ARGUMENT, err, out_error);
    const model = text(config.model) catch |err| return failError(wire.STATUS_INVALID_ARGUMENT, err, out_error);
    const base_url = text(config.base_url) catch |err| return failError(wire.STATUS_INVALID_ARGUMENT, err, out_error);
    const root = text(config.workspace_root) catch |err| return failError(wire.STATUS_INVALID_ARGUMENT, err, out_error);
    const home = text(config.workspace_home) catch |err| return failError(wire.STATUS_INVALID_ARGUMENT, err, out_error);
    if (api_key.len == 0 or model.len == 0 or root.len == 0) return fail(wire.STATUS_INVALID_ARGUMENT, "api_key, model and workspace_root are required", out_error);
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const allowed = borrowedViews(scratch.allocator(), config.allowed_tools, config.allowed_tool_count) catch |err|
        return failError(inputErrorStatus(err), err, out_error);

    const self = allocator.create(AbiSession) catch return fail(wire.STATUS_OUT_OF_MEMORY, "allocating Session failed", out_error);
    self.callbacks = callbacks.*;
    self.core_session = runtime.core_runtime.createSession(.{
        .provider_kind = kind,
        .api_key = api_key,
        .model = model,
        .base_url = if (base_url.len == 0) null else base_url,
        .permission_mode = mode,
        .workspace = .{ .root = root, .home = home, .shell = shell },
        .allowed_tools = allowed,
        .ui_requester = if (callbacks.on_ui_request != null) .{ .ctx = self, .requestFn = AbiSession.requestUi } else null,
    }) catch |err| {
        allocator.destroy(self);
        return failError(if (err == error.OutOfMemory) wire.STATUS_OUT_OF_MEMORY else wire.STATUS_CORE_ERROR, err, out_error);
    };
    out.* = self.handle();
    return wire.STATUS_OK;
}

fn sessionDestroy(handle: ?*wire.SessionHandle, out_error: ?*wire.OwnedBytesV1) callconv(.c) u32 {
    emptyError(out_error);
    const self = sessionFrom(handle orelse return fail(wire.STATUS_INVALID_ARGUMENT, "session is required", out_error));
    self.core_session.destroy() catch |err| return failError(if (err == error.SessionBusy) wire.STATUS_BUSY else wire.STATUS_INVALID_STATE, err, out_error);
    allocator.destroy(self);
    return wire.STATUS_OK;
}

fn sessionRun(handle: ?*wire.SessionHandle, run_id: u64, prompt_view: wire.BytesViewV1, options_ptr: ?*const wire.RunOptionsV1, out_result: ?*wire.RunResultV1, out_error: ?*wire.OwnedBytesV1) callconv(.c) u32 {
    if (out_result) |out| out.* = std.mem.zeroes(wire.RunResultV1);
    emptyError(out_error);
    const self = sessionFrom(handle orelse return fail(wire.STATUS_INVALID_ARGUMENT, "session is required", out_error));
    const options = options_ptr orelse return fail(wire.STATUS_INVALID_ARGUMENT, "run options are required", out_error);
    const out = out_result orelse return fail(wire.STATUS_INVALID_ARGUMENT, "out_result is required", out_error);
    if (run_id == 0 or options.struct_size != @sizeOf(wire.RunOptionsV1) or options.max_turns == 0 or !allZero(options.reserved))
        return fail(wire.STATUS_INVALID_ARGUMENT, "invalid run id or RunOptionsV1", out_error);
    const prompt = text(prompt_view) catch |err| return failError(wire.STATUS_INVALID_ARGUMENT, err, out_error);
    const result = self.core_session.runText(run_id, prompt, options.max_turns, .{ .ctx = self, .emit = AbiSession.emit }) catch |err| {
        const status: u32 = switch (err) {
            error.SessionBusy => wire.STATUS_BUSY,
            error.StaleRun => wire.STATUS_STALE_RUN,
            error.InvalidSessionState => wire.STATUS_INVALID_STATE,
            error.CallbackFailed => wire.STATUS_CALLBACK_FAILED,
            else => wire.STATUS_CORE_ERROR,
        };
        return failError(status, err, out_error);
    };
    defer if (result.suspend_info) |suspend_info| suspend_info.deinit();
    out.* = .{ .struct_size = @sizeOf(wire.RunResultV1), .stop_reason_code = stopReason(result.stop_reason), .turns = result.turns, .tool_calls = result.tool_calls, .reserved = [_]u64{0} ** 4 };
    return wire.STATUS_OK;
}

fn sessionAbort(handle: ?*wire.SessionHandle, run_id: u64, reason_code: u32, out_error: ?*wire.OwnedBytesV1) callconv(.c) u32 {
    emptyError(out_error);
    const self = sessionFrom(handle orelse return fail(wire.STATUS_INVALID_ARGUMENT, "session is required", out_error));
    const reason: core.agent_session.AbortReason = switch (reason_code) {
        wire.ABORT_USER_REQUEST => .user_interrupt,
        wire.ABORT_TIMEOUT => .timeout,
        else => return fail(wire.STATUS_INVALID_ARGUMENT, "unknown abort reason", out_error),
    };
    if (run_id == 0) return fail(wire.STATUS_INVALID_ARGUMENT, "run_id must be nonzero", out_error);
    self.core_session.abort(run_id, reason) catch |err| return failError(switch (err) {
        error.StaleRun => wire.STATUS_STALE_RUN,
        error.AbortTooLate => wire.STATUS_TOO_LATE,
        error.InvalidSessionState => wire.STATUS_INVALID_STATE,
        else => wire.STATUS_INTERNAL_ERROR,
    }, err, out_error);
    return wire.STATUS_OK;
}

fn bufferRelease(buffer: ?*wire.OwnedBytesV1) callconv(.c) void {
    const out = buffer orelse return;
    const len = std.math.cast(usize, out.len) orelse {
        out.* = .{ .ptr = null, .len = 0 };
        return;
    };
    if (len != 0) if (out.ptr) |ptr| allocator.free(ptr[0..len]);
    out.* = .{ .ptr = null, .len = 0 };
}

const api_v1 = wire.ApiV1{
    .struct_size = @sizeOf(wire.ApiV1),
    .abi_version = wire.ABI_VERSION_V1,
    .capabilities = wire.REQUIRED_CAPABILITIES_V1,
    .runtime_create = runtimeCreate,
    .runtime_destroy = runtimeDestroy,
    .session_create = sessionCreate,
    .session_destroy = sessionDestroy,
    .session_run = sessionRun,
    .session_abort = sessionAbort,
    .buffer_release = bufferRelease,
    .reserved = [_]u64{0} ** 4,
};

pub export fn metacodes_agentcore_get_api(requested_abi: u32) callconv(.c) ?*const anyopaque {
    if (requested_abi != wire.ABI_VERSION_V1) return null;
    return @ptrCast(&api_v1);
}

test "ABI discovery is versioned" {
    try std.testing.expect(metacodes_agentcore_get_api(0) == null);
    const raw = metacodes_agentcore_get_api(wire.ABI_VERSION_V1) orelse return error.MissingApi;
    const api: *const wire.ApiV1 = @ptrCast(@alignCast(raw));
    try std.testing.expectEqual(wire.REQUIRED_CAPABILITIES_V1, api.capabilities);
}

test "UI response parser owns AskUserQuestion answers" {
    const questions = [_]core.tool_context.AskQuestion{.{ .question = "continue?", .header = "choice", .multi = false, .options = &.{} }};
    const req = ui_request.UiRequest{ .ask_question = &questions };
    var out: ui_request.UiResponse = undefined;
    try parseUiResponse(std.testing.allocator, &req, "{\"answers\":[\"yes\"]}", &out);
    switch (out) {
        .answers => |answers| {
            defer std.testing.allocator.free(answers);
            defer for (answers) |answer| std.testing.allocator.free(@constCast(answer));
            try std.testing.expectEqualStrings("yes", answers[0]);
        },
        else => return error.UnexpectedResponse,
    }
}

test "UI response parser rejects an answer count mismatch" {
    const questions = [_]core.tool_context.AskQuestion{.{ .question = "continue?", .header = "choice", .multi = false, .options = &.{} }};
    const req = ui_request.UiRequest{ .ask_question = &questions };
    var out: ui_request.UiResponse = undefined;
    try std.testing.expectError(error.InvalidUiResponse, parseUiResponse(std.testing.allocator, &req, "{\"answers\":[]}", &out));
}
