//! Thin C ABI v1 facade over AgentRuntime and AgentSession.

const std = @import("std");
const builtin = @import("builtin");
const sync = @import("platform").sync;
const wire = @import("metask_agentcore_types");
const core = @import("metacodes-core");
const ui_request = core.protocol.ui_request;
pub const protocol_v1 = @import("protocol_v1.zig");
pub const skill_catalog = @import("skill_catalog.zig");
const sandbox_admission = @import("sandbox_admission.zig");

const allocator = std.heap.c_allocator;

comptime {
    if (wire.MAX_TOOL_ERROR_PAYLOAD_BYTES_V1 != @as(u64, core.tool_exec.MAX_TOOL_ERROR_PAYLOAD_BYTES_V1))
        @compileError("AgentCore wire and core encoded Host-error limits must match");
}

/// AgentCore owns session-scoped permission memory. Public "session" choices
/// must never reach the product-managed core persistence branch.
const HostPermissionRules = struct {
    const Decision = enum { allow, deny };

    mutex: sync.Mutex = .{},
    allowed: std.ArrayList([]u8) = .empty,
    denied: std.ArrayList([]u8) = .empty,

    fn deinit(self: *HostPermissionRules) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.allowed.items) |name| allocator.free(name);
        for (self.denied.items) |name| allocator.free(name);
        self.allowed.deinit(allocator);
        self.denied.deinit(allocator);
    }

    fn lookup(self: *HostPermissionRules, name: []const u8) ?Decision {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (contains(self.denied.items, name)) return .deny;
        if (contains(self.allowed.items, name)) return .allow;
        return null;
    }

    fn remember(self: *HostPermissionRules, decision: Decision, name: []const u8) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const list = if (decision == .allow) &self.allowed else &self.denied;
        if (contains(list.items, name)) return;
        const owned = try allocator.dupe(u8, name);
        errdefer allocator.free(owned);
        try list.append(allocator, owned);
    }

    fn contains(names: []const []u8, needle: []const u8) bool {
        for (names) |name| if (std.mem.eql(u8, name, needle)) return true;
        return false;
    }
};

const AbiHostTool = struct {
    ctx: ?*anyopaque,
    execute_fn: wire.HostExecuteFnV1,
    release_fn: wire.HostReleaseFnV1,

    /// HOST_FATAL and unknown statuses are infrastructure-fatal. FAILED and
    /// REJECTED may carry bounded UTF-8 detail; malformed detail degrades to a
    /// null-detail business failure. An invalid HOST_OK descriptor is fatal.
    fn execute(raw: *anyopaque, identity: core.agent_session.HostRunIdentity, args: []const u8) error{OutOfMemory}!core.agent_session.HostToolOutcome {
        const self: *AbiHostTool = @ptrCast(@alignCast(raw));
        const session: *wire.SessionHandle = @ptrCast(identity.host_session_ctx);
        const run = makeRunContext(session, &identity.identity);
        var out = wire.OwnedBytesV1{ .ptr = null, .len = 0 };
        const status = self.execute_fn(self.ctx, &run, view(args), &out);
        if (status == wire.HOST_FATAL or
            (status != wire.HOST_OK and status != wire.HOST_FAILED and status != wire.HOST_REJECTED))
        {
            if (hasReleaseToken(out)) self.release_fn(self.ctx, &out);
            return .fatal;
        }
        if (!canonicalOwned(out)) {
            if (hasReleaseToken(out)) self.release_fn(self.ctx, &out);
            return outcomeWithoutDetail(status);
        }
        if (out.len == 0) {
            if (status == wire.HOST_OK) {
                return .{ .ok = .{ .bytes = "", .release_ctx = self, .releaseFn = release } };
            }
            return outcomeWithoutDetail(status);
        }

        // The wire descriptor has one raw-text limit for every business
        // status. FAILED/REJECTED detail is later serialized under the smaller
        // encoded-payload cap; applying that cap here would reject valid raw
        // detail before escaping is measured.
        if (out.len > wire.MAX_HOST_TOOL_RESULT_BYTES_V1) {
            if (hasReleaseToken(out)) self.release_fn(self.ctx, &out);
            return outcomeWithInvalidPayload(status);
        }
        const bytes = ownedSlice(out) catch {
            if (hasReleaseToken(out)) self.release_fn(self.ctx, &out);
            return outcomeWithInvalidPayload(status);
        };
        if (!std.unicode.utf8ValidateSlice(bytes)) {
            if (hasReleaseToken(out)) self.release_fn(self.ctx, &out);
            return outcomeWithInvalidPayload(status);
        }
        const result = core.agent_session.HostToolResult{ .bytes = bytes, .release_ctx = self, .releaseFn = release };
        return switch (status) {
            wire.HOST_OK => .{ .ok = result },
            wire.HOST_FAILED => .{ .failed = result },
            wire.HOST_REJECTED => .{ .rejected = result },
            else => unreachable,
        };
    }

    fn outcomeWithoutDetail(status: u32) core.agent_session.HostToolOutcome {
        return switch (status) {
            wire.HOST_OK => .fatal,
            wire.HOST_FAILED => .{ .failed = null },
            wire.HOST_REJECTED => .{ .rejected = null },
            else => .fatal,
        };
    }

    fn outcomeWithInvalidPayload(status: u32) core.agent_session.HostToolOutcome {
        return switch (status) {
            wire.HOST_OK, wire.HOST_FAILED => .{ .failed = null },
            wire.HOST_REJECTED => .{ .rejected = null },
            else => .fatal,
        };
    }

    fn release(raw: *anyopaque, bytes: []const u8) void {
        if (bytes.len == 0) return;
        const self: *AbiHostTool = @ptrCast(@alignCast(raw));
        var out = wire.OwnedBytesV1{ .ptr = @constCast(bytes.ptr), .len = bytes.len };
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
    const CallState = enum { idle, running, destroying };

    callbacks: wire.SessionCallbacksV1,
    callback_status: std.atomic.Value(u32),
    facade_poisoned: std.atomic.Value(bool),
    core_session: *core.agent_session.AgentSession,
    host_permission_rules: HostPermissionRules = .{},
    call_mutex: sync.Mutex = .{},
    call_state: CallState = .idle,

    fn handle(self: *AbiSession) *wire.SessionHandle {
        return @ptrCast(self);
    }

    fn runContext(self: *AbiSession, identity: *const core.agent_session.RunIdentity) wire.RunContextV1 {
        return makeRunContext(self.handle(), identity);
    }

    fn emit(raw: *anyopaque, session_id: core.session_id.SessionId, run_id: u64, event: core.protocol.ui_event.CoreEvent) bool {
        const self: *AbiSession = @ptrCast(@alignCast(raw));
        const callback = self.callbacks.on_event orelse return true;
        const public_event = protocol_v1.event(event) orelse return true;
        const json = std.json.Stringify.valueAlloc(allocator, public_event, .{}) catch {
            self.recordCallbackStatus(wire.STATUS_OUT_OF_MEMORY);
            return false;
        };
        defer allocator.free(json);
        const identity = core.agent_session.RunIdentity{ .session_id = session_id, .run_id = run_id };
        const run = self.runContext(&identity);
        const accepted = callback(self.callbacks.ctx, &run, view(json)) == wire.EVENT_CONTINUE;
        if (!accepted) self.recordCallbackStatus(wire.STATUS_CALLBACK_FAILED);
        return accepted;
    }

    fn requestUi(raw: *anyopaque, identity: core.agent_session.RunIdentity, response_allocator: std.mem.Allocator, req: *const ui_request.UiRequest, out: *ui_request.UiResponse) anyerror!ui_request.RequestOutcome {
        const self: *AbiSession = @ptrCast(@alignCast(raw));

        if (rememberedPermission(self, req)) |choice| {
            out.* = .{ .permission = choice };
            return .answered;
        }
        const callback = self.callbacks.on_ui_request orelse return switch (req.*) {
            .permission => blk: {
                out.* = .{ .permission = .deny_once };
                break :blk .answered;
            },
            else => .unavailable,
        };
        const release_fn = self.callbacks.release_response orelse return error.HostUiFailed;
        const request_json = protocol_v1.encodeUiRequest(response_allocator, req) catch |err| {
            self.recordCallbackStatus(if (err == error.OutOfMemory) wire.STATUS_OUT_OF_MEMORY else wire.STATUS_INTERNAL_ERROR);
            return err;
        };
        defer response_allocator.free(request_json);
        var response = wire.OwnedBytesV1{ .ptr = null, .len = 0 };
        const run = self.runContext(&identity);
        const status = callback(self.callbacks.ctx, &run, view(request_json), &response);
        defer if (hasReleaseToken(response)) release_fn(self.callbacks.ctx, &response);
        if (!canonicalOwned(response)) {
            self.recordCallbackStatus(wire.STATUS_CALLBACK_FAILED);
            return error.HostUiFailed;
        }
        return switch (status) {
            wire.UI_UNAVAILABLE => switch (req.*) {
                .permission => blk: {
                    out.* = .{ .permission = .deny_once };
                    break :blk .answered;
                },
                else => .unavailable,
            },
            wire.UI_CANCELLED => switch (req.*) {
                .permission => blk: {
                    out.* = .{ .permission = .deny_once };
                    break :blk .answered;
                },
                .ask_question => return error.UiCancelled,
                else => unreachable,
            },
            wire.UI_ANSWERED => blk: {
                if (response.len > wire.MAX_UI_RESPONSE_BYTES_V1) {
                    self.recordCallbackStatus(wire.STATUS_CALLBACK_FAILED);
                    return error.HostUiFailed;
                }
                const bytes = ownedSlice(response) catch |err| {
                    self.recordCallbackStatus(wire.STATUS_CALLBACK_FAILED);
                    return err;
                };
                protocol_v1.decodeUiResponse(response_allocator, req, bytes, out) catch |err| {
                    self.recordCallbackStatus(if (err == error.OutOfMemory) wire.STATUS_OUT_OF_MEMORY else wire.STATUS_CALLBACK_FAILED);
                    return err;
                };
                self.captureSessionPermission(req, out) catch |err| {
                    self.recordCallbackStatus(wire.STATUS_OUT_OF_MEMORY);
                    return err;
                };
                break :blk .answered;
            },
            else => {
                self.recordCallbackStatus(wire.STATUS_CALLBACK_FAILED);
                return error.HostUiFailed;
            },
        };
    }

    fn rememberedPermission(self: *AbiSession, req: *const ui_request.UiRequest) ?core.protocol.PermissionChoice {
        const permission = switch (req.*) {
            .permission => |value| value,
            else => return null,
        };
        return switch (self.host_permission_rules.lookup(permission.tool) orelse return null) {
            .allow => .allow_once,
            .deny => .deny_once,
        };
    }

    fn captureSessionPermission(self: *AbiSession, req: *const ui_request.UiRequest, out: *ui_request.UiResponse) !void {
        const permission = switch (req.*) {
            .permission => |value| value,
            else => return,
        };
        switch (out.*) {
            .permission => |choice| switch (choice) {
                .allow_always => {
                    try self.host_permission_rules.remember(.allow, permission.tool);
                    out.* = .{ .permission = .allow_once };
                },
                .deny_tool_session => {
                    try self.host_permission_rules.remember(.deny, permission.tool);
                    out.* = .{ .permission = .deny_once };
                },
                .allow_once, .deny_once => {},
            },
            else => {},
        }
    }

    fn recordCallbackStatus(self: *AbiSession, status: u32) void {
        _ = self.callback_status.cmpxchgStrong(wire.STATUS_OK, status, .release, .monotonic);
    }

    fn callbackFailureStatus(self: *const AbiSession) u32 {
        const status = self.callback_status.load(.acquire);
        return if (status == wire.STATUS_OK) wire.STATUS_CALLBACK_FAILED else status;
    }

    fn tryBeginRun(self: *AbiSession) bool {
        self.call_mutex.lock();
        defer self.call_mutex.unlock();
        if (self.call_state != .idle) return false;
        self.call_state = .running;
        return true;
    }

    fn finishRun(self: *AbiSession) void {
        self.call_mutex.lock();
        defer self.call_mutex.unlock();
        std.debug.assert(self.call_state == .running);
        self.call_state = .idle;
    }

    fn tryBeginDestroy(self: *AbiSession) bool {
        self.call_mutex.lock();
        defer self.call_mutex.unlock();
        if (self.call_state != .idle) return false;
        self.call_state = .destroying;
        return true;
    }

    fn cancelDestroy(self: *AbiSession) void {
        self.call_mutex.lock();
        defer self.call_mutex.unlock();
        std.debug.assert(self.call_state == .destroying);
        self.call_state = .idle;
    }
};

pub const TestEpilogueHook = struct {
    ctx: *anyopaque,
    runFn: *const fn (ctx: *anyopaque, run_id: u64) void,
};

var test_epilogue_hook: if (builtin.is_test) ?TestEpilogueHook else void = if (builtin.is_test) null else {};

pub fn setTestEpilogueHook(hook: ?TestEpilogueHook) void {
    if (comptime !builtin.is_test) @compileError("test epilogue hooks are unavailable in production builds");
    test_epilogue_hook = hook;
}

fn invokeTestEpilogueHook(run_id: u64) void {
    if (comptime builtin.is_test) {
        if (test_epilogue_hook) |hook| hook.runFn(hook.ctx, run_id);
    }
}

fn makeRunContext(session: *wire.SessionHandle, identity: *const core.agent_session.RunIdentity) wire.RunContextV1 {
    return .{
        .struct_size = @sizeOf(wire.RunContextV1),
        .reserved0 = 0,
        .session = session,
        .run_id = identity.run_id,
        .session_id = view(identity.session_id.asSlice()),
        .reserved = [_]u64{0} ** 2,
    };
}

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

fn canonicalOwned(v: wire.OwnedBytesV1) bool {
    return (v.len == 0) == (v.ptr == null);
}

fn hasReleaseToken(v: wire.OwnedBytesV1) bool {
    return v.ptr != null or v.len != 0;
}

fn allZero(values: anytype) bool {
    for (values) |value| if (value != 0) return false;
    return true;
}

fn emptyError(out_error: ?*wire.OwnedBytesV1) void {
    if (out_error) |out| out.* = .{ .ptr = null, .len = 0 };
}

fn writeDiagnostic(diagnostic_allocator: std.mem.Allocator, message: []const u8, out_error: ?*wire.OwnedBytesV1) void {
    const out = out_error orelse return;
    // Diagnostics are best-effort side output. Failure to allocate human-readable
    // text must never replace the machine-readable status of the operation.
    out.* = .{ .ptr = null, .len = 0 };
    const copy = diagnostic_allocator.dupe(u8, message) catch return;
    out.* = .{ .ptr = copy.ptr, .len = copy.len };
}

fn fail(status: u32, message: []const u8, out_error: ?*wire.OwnedBytesV1) u32 {
    writeDiagnostic(allocator, message, out_error);
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
        wire.STATUS_RESOURCE_LIMIT => "resource limit",
        else => "AgentCore error",
    };
}

fn inputErrorStatus(err: anyerror) u32 {
    return if (err == error.OutOfMemory)
        wire.STATUS_OUT_OF_MEMORY
    else if (err == error.ResourceLimit)
        wire.STATUS_RESOURCE_LIMIT
    else
        wire.STATUS_INVALID_ARGUMENT;
}

fn runtimeErrorStatus(err: anyerror) u32 {
    return if (err == error.OutOfMemory)
        wire.STATUS_OUT_OF_MEMORY
    else if (err == error.UnknownBuiltinTool or err == error.UnsupportedBuiltinTool or
        err == error.DuplicateToolName or err == error.InvalidHostTool)
        wire.STATUS_INVALID_ARGUMENT
    else
        wire.STATUS_CORE_ERROR;
}

fn sessionCreateErrorStatus(err: anyerror) u32 {
    return switch (err) {
        error.OutOfMemory => wire.STATUS_OUT_OF_MEMORY,
        error.InvalidWorkspaceRoot,
        error.InvalidWorkspaceHome,
        error.ToolNotInRuntime,
        error.DuplicateToolName,
        error.ShellToolDisabled,
        => wire.STATUS_INVALID_ARGUMENT,
        error.RuntimeUnavailable => wire.STATUS_INVALID_STATE,
        else => wire.STATUS_CORE_ERROR,
    };
}

fn runErrorStatus(self: *const AbiSession, err: anyerror) u32 {
    return switch (err) {
        error.OutOfMemory => wire.STATUS_OUT_OF_MEMORY,
        error.SessionBusy => wire.STATUS_BUSY,
        error.StaleRun => wire.STATUS_STALE_RUN,
        error.InvalidSessionState => wire.STATUS_INVALID_STATE,
        error.CallbackFailed => self.callbackFailureStatus(),
        else => wire.STATUS_CORE_ERROR,
    };
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

fn stopReason(self: *AbiSession, reason: core.agent_loop.StopReason) error{UnsupportedStopReason}!u32 {
    return switch (reason) {
        .end_turn => wire.STOP_END_TURN,
        .max_turns => wire.STOP_MAX_TURNS,
        .aborted => wire.STOP_ABORTED,
        .tool_error => wire.STOP_TOOL_ERROR,
        .api_error => wire.STOP_API_ERROR,
        .tool_loop => wire.STOP_TOOL_LOOP,
        .suspended, .backgrounded, .budget => {
            // The stateful Run has already committed Conversation changes.
            // Returning an error while leaving the facade reusable would make
            // a Host retry ambiguous and could repeat side effects.
            self.facade_poisoned.store(true, .release);
            return error.UnsupportedStopReason;
        },
    };
}

fn addMetadata(total: *u64, len: u64, total_limit: u64) error{ResourceLimit}!void {
    if (len > wire.MAX_METADATA_STRING_BYTES_V1) return error.ResourceLimit;
    total.* = std.math.add(u64, total.*, len) catch return error.ResourceLimit;
    if (total.* > total_limit) return error.ResourceLimit;
}

fn borrowedViews(
    arena: std.mem.Allocator,
    ptr: ?[*]const wire.BytesViewV1,
    count64: u64,
    metadata_total: *u64,
    metadata_limit: u64,
) ![]const []const u8 {
    if (count64 > wire.MAX_TOOL_COUNT_V1) return error.ResourceLimit;
    const count = std.math.cast(usize, count64) orelse return error.Overflow;
    if (count == 0) return &.{};
    const values = (ptr orelse return error.InvalidArgument)[0..count];
    const out = try arena.alloc([]const u8, count);
    for (values, 0..) |value, i| {
        try addMetadata(metadata_total, value.len, metadata_limit);
        out[i] = try text(value);
    }
    return out;
}

fn parseSchema(arena: std.mem.Allocator, encoded: []const u8) !core.json.InputSchema {
    if (encoded.len > wire.MAX_TOOL_SCHEMA_BYTES_V1) return error.ResourceLimit;
    const root = try std.json.parseFromSliceLeaky(std.json.Value, arena, encoded, .{
        .duplicate_field_behavior = .@"error",
    });
    try validateSchemaDepth(root, 1);
    if (root != .object) return error.InvalidSchema;
    var fields = root.object.iterator();
    while (fields.next()) |field| {
        if (!std.mem.eql(u8, field.key_ptr.*, "type") and
            !std.mem.eql(u8, field.key_ptr.*, "properties") and
            !std.mem.eql(u8, field.key_ptr.*, "required"))
            return error.InvalidSchema;
    }
    const type_value = root.object.get("type") orelse return error.InvalidSchema;
    if (type_value != .string or !std.mem.eql(u8, type_value.string, "object")) return error.InvalidSchema;
    var schema = core.json.InputSchema{ .type = type_value.string };
    if (root.object.get("properties")) |properties| {
        if (properties != .object) return error.InvalidSchema;
        if (properties.object.count() > wire.MAX_TOOL_SCHEMA_PROPERTIES_V1) return error.ResourceLimit;
        schema.properties = properties.object;
    }
    if (root.object.get("required")) |required| {
        if (required != .array) return error.InvalidSchema;
        if (required.array.items.len > wire.MAX_TOOL_SCHEMA_PROPERTIES_V1) return error.ResourceLimit;
        const names = try arena.alloc([]const u8, required.array.items.len);
        for (required.array.items, 0..) |item, i| {
            if (item != .string) return error.InvalidSchema;
            if (schema.properties == null or schema.properties.?.get(item.string) == null)
                return error.InvalidSchema;
            for (names[0..i]) |existing| {
                if (std.mem.eql(u8, existing, item.string)) return error.InvalidSchema;
            }
            names[i] = item.string;
        }
        schema.required = names;
    }
    return schema;
}

fn validateSchemaDepth(value: std.json.Value, depth: u32) !void {
    if (depth > wire.MAX_TOOL_SCHEMA_DEPTH_V1) return error.ResourceLimit;
    switch (value) {
        .array => |array| for (array.items) |child| try validateSchemaDepth(child, depth + 1),
        .object => |object| {
            var iterator = object.iterator();
            while (iterator.next()) |entry| try validateSchemaDepth(entry.value_ptr.*, depth + 1);
        },
        else => {},
    }
}

fn validToolName(name: []const u8) bool {
    if (name.len == 0 or name.len > 64) return false;
    const first = name[0];
    if (!std.ascii.isAlphabetic(first) and first != '_') return false;
    for (name[1..]) |byte| {
        if (!std.ascii.isAlphanumeric(byte) and byte != '_' and byte != '-') return false;
    }
    return true;
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
    var runtime_metadata: u64 = 0;
    const builtin_names = borrowedViews(
        a,
        config.builtin_tools,
        config.builtin_tool_count,
        &runtime_metadata,
        wire.MAX_RUNTIME_METADATA_BYTES_V1,
    ) catch |err|
        return failError(inputErrorStatus(err), err, out_error);
    for (builtin_names) |name| {
        if (!validToolName(name)) return fail(wire.STATUS_INVALID_ARGUMENT, "invalid builtin tool name", out_error);
    }
    if (config.host_tool_count > wire.MAX_TOOL_COUNT_V1 or
        config.builtin_tool_count > wire.MAX_TOOL_COUNT_V1 - config.host_tool_count)
        return fail(wire.STATUS_RESOURCE_LIMIT, "Runtime tool count exceeds AgentCore ABI v1 limit", out_error);
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
        if (descriptor.input_schema_json.len > wire.MAX_TOOL_SCHEMA_BYTES_V1)
            return fail(wire.STATUS_RESOURCE_LIMIT, "Host tool schema exceeds AgentCore ABI v1 limit", out_error);
        addMetadata(&runtime_metadata, descriptor.name.len, wire.MAX_RUNTIME_METADATA_BYTES_V1) catch |err|
            return failError(inputErrorStatus(err), err, out_error);
        addMetadata(&runtime_metadata, descriptor.description.len, wire.MAX_RUNTIME_METADATA_BYTES_V1) catch |err|
            return failError(inputErrorStatus(err), err, out_error);
        addMetadata(&runtime_metadata, descriptor.input_schema_json.len, wire.MAX_RUNTIME_METADATA_BYTES_V1) catch |err|
            return failError(inputErrorStatus(err), err, out_error);
        const name = text(descriptor.name) catch |err| return failError(wire.STATUS_INVALID_ARGUMENT, err, out_error);
        if (!validToolName(name)) return fail(wire.STATUS_INVALID_ARGUMENT, "invalid Host tool name", out_error);
        const description = text(descriptor.description) catch |err| return failError(wire.STATUS_INVALID_ARGUMENT, err, out_error);
        const schema_json = text(descriptor.input_schema_json) catch |err| return failError(wire.STATUS_INVALID_ARGUMENT, err, out_error);
        const schema = parseSchema(a, schema_json) catch |err| return failError(inputErrorStatus(err), err, out_error);
        self.host_tools[i] = .{ .ctx = descriptor.ctx, .execute_fn = descriptor.execute.?, .release_fn = descriptor.release_result.? };
        native_tools[i] = .{ .definition = .{ .name = name, .description = description, .input_schema = schema }, .ctx = &self.host_tools[i], .execute = AbiHostTool.execute };
    }
    self.core_runtime = core.agent_session.AgentRuntime.create(allocator, .{ .builtin_tools = builtin_names, .host_sync_tools = native_tools }) catch |err| {
        return failError(runtimeErrorStatus(err), err, out_error);
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
    if (config.struct_size != @sizeOf(wire.SessionConfigV1) or !allZero(config.reserved) or
        callbacks.struct_size != @sizeOf(wire.SessionCallbacksV1) or callbacks.reserved0 != 0 or
        !allZero(callbacks.reserved) or callbacks.on_event == null or
        (callbacks.on_ui_request != null and callbacks.release_response == null))
        return fail(wire.STATUS_INVALID_ARGUMENT, "invalid SessionConfigV1 or SessionCallbacksV1", out_error);
    const kind = provider(config.provider_kind_code) orelse return fail(wire.STATUS_INVALID_ARGUMENT, "unknown provider", out_error);
    const mode = permissionMode(config.permission_mode_code) orelse return fail(wire.STATUS_INVALID_ARGUMENT, "unknown permission mode", out_error);
    const shell = shellPolicy(config.shell_policy_code) orelse return fail(wire.STATUS_INVALID_ARGUMENT, "unknown shell policy", out_error);
    var session_metadata: u64 = 0;
    for ([_]wire.BytesViewV1{
        config.api_key,
        config.model,
        config.base_url,
        config.workspace_root,
        config.workspace_home,
    }) |value| {
        addMetadata(&session_metadata, value.len, wire.MAX_SESSION_METADATA_BYTES_V1) catch |err|
            return failError(inputErrorStatus(err), err, out_error);
    }
    const api_key = text(config.api_key) catch |err| return failError(wire.STATUS_INVALID_ARGUMENT, err, out_error);
    const model = text(config.model) catch |err| return failError(wire.STATUS_INVALID_ARGUMENT, err, out_error);
    const base_url = text(config.base_url) catch |err| return failError(wire.STATUS_INVALID_ARGUMENT, err, out_error);
    const root = text(config.workspace_root) catch |err| return failError(wire.STATUS_INVALID_ARGUMENT, err, out_error);
    const home = text(config.workspace_home) catch |err| return failError(wire.STATUS_INVALID_ARGUMENT, err, out_error);
    if (api_key.len == 0 or model.len == 0 or root.len == 0) return fail(wire.STATUS_INVALID_ARGUMENT, "api_key, model and workspace_root are required", out_error);
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const allowed = borrowedViews(
        scratch.allocator(),
        config.allowed_tools,
        config.allowed_tool_count,
        &session_metadata,
        wire.MAX_SESSION_METADATA_BYTES_V1,
    ) catch |err|
        return failError(inputErrorStatus(err), err, out_error);
    if (shell == .sandboxed) {
        sandbox_admission.validate(allocator) catch |err| return failError(
            if (err == error.OutOfMemory) wire.STATUS_OUT_OF_MEMORY else wire.STATUS_INVALID_ARGUMENT,
            err,
            out_error,
        );
    }

    const self = allocator.create(AbiSession) catch return fail(wire.STATUS_OUT_OF_MEMORY, "allocating Session failed", out_error);
    self.callbacks = callbacks.*;
    self.callback_status = .init(wire.STATUS_OK);
    self.facade_poisoned = .init(false);
    self.host_permission_rules = .{};
    self.call_mutex = .{};
    self.call_state = .idle;
    self.core_session = runtime.core_runtime.createSession(.{
        .provider_kind = kind,
        .api_key = api_key,
        .model = model,
        .base_url = if (base_url.len == 0) null else base_url,
        .permission_mode = mode,
        .workspace = .{ .root = root, .home = home, .shell = shell },
        .allowed_tools = allowed,
        .run_ui_requester = if (callbacks.on_ui_request != null) .{ .ctx = self, .requestFn = AbiSession.requestUi } else null,
        // Host tool 身份锚点 = 本 AbiSession;仅 AbiHostTool 适配层可解释此指针。
        .host_identity_ctx = self,
    }) catch |err| {
        allocator.destroy(self);
        return failError(sessionCreateErrorStatus(err), err, out_error);
    };
    out.* = self.handle();
    return wire.STATUS_OK;
}

fn sessionDestroy(handle: ?*wire.SessionHandle, out_error: ?*wire.OwnedBytesV1) callconv(.c) u32 {
    emptyError(out_error);
    const self = sessionFrom(handle orelse return fail(wire.STATUS_INVALID_ARGUMENT, "session is required", out_error));
    if (!self.tryBeginDestroy()) return fail(wire.STATUS_BUSY, "Session has an active facade call", out_error);
    self.core_session.destroy() catch |err| {
        self.cancelDestroy();
        return failError(if (err == error.SessionBusy) wire.STATUS_BUSY else wire.STATUS_INVALID_STATE, err, out_error);
    };
    self.host_permission_rules.deinit();
    allocator.destroy(self);
    return wire.STATUS_OK;
}

fn sessionRun(handle: ?*wire.SessionHandle, run_id: u64, prompt_view: wire.BytesViewV1, options_ptr: ?*const wire.RunOptionsV1, out_result: ?*wire.RunResultV1, out_error: ?*wire.OwnedBytesV1) callconv(.c) u32 {
    // Defensive hygiene only. ABI v1 defines RunResult fields only on OK.
    if (out_result) |out| out.* = std.mem.zeroes(wire.RunResultV1);
    emptyError(out_error);
    const self = sessionFrom(handle orelse return fail(wire.STATUS_INVALID_ARGUMENT, "session is required", out_error));
    if (!self.tryBeginRun()) return fail(wire.STATUS_BUSY, "Session has an active facade call", out_error);
    // This defer is the facade completion linearization point. Everything that
    // reads AbiSession or publishes RunResult/diagnostics happens before it;
    // after it releases the gate, sessionDestroy may immediately free `self`.
    defer self.finishRun();
    if (self.facade_poisoned.load(.acquire))
        return fail(wire.STATUS_INVALID_STATE, "Session is poisoned by a previous admitted Run failure", out_error);
    const options = options_ptr orelse return fail(wire.STATUS_INVALID_ARGUMENT, "run options are required", out_error);
    const out = out_result orelse return fail(wire.STATUS_INVALID_ARGUMENT, "out_result is required", out_error);
    if (run_id == 0 or options.struct_size != @sizeOf(wire.RunOptionsV1) or options.max_turns == 0 or !allZero(options.reserved))
        return fail(wire.STATUS_INVALID_ARGUMENT, "invalid run id or RunOptionsV1", out_error);
    if (options.max_turns > wire.MAX_TURNS_V1)
        return fail(wire.STATUS_RESOURCE_LIMIT, "max_turns exceeds AgentCore ABI v1 limit", out_error);
    if (prompt_view.len > wire.MAX_PROMPT_BYTES_V1)
        return fail(wire.STATUS_RESOURCE_LIMIT, "prompt exceeds AgentCore ABI v1 limit", out_error);
    const prompt = text(prompt_view) catch |err| return failError(wire.STATUS_INVALID_ARGUMENT, err, out_error);
    const result = self.core_session.runText(run_id, prompt, options.max_turns, .{ .ctx = self, .emit = AbiSession.emit }) catch |err| {
        const status = runErrorStatus(self, err);
        if (self.core_session.isPoisoned()) self.facade_poisoned.store(true, .release);
        return failError(status, err, out_error);
    };
    defer if (result.suspend_info) |suspend_info| suspend_info.deinit();
    invokeTestEpilogueHook(run_id);
    const stop_code = stopReason(self, result.stop_reason) catch
        return fail(wire.STATUS_INTERNAL_ERROR, "core returned a stop reason unsupported by AgentCore ABI v1", out_error);
    out.* = .{ .struct_size = @sizeOf(wire.RunResultV1), .stop_reason_code = stop_code, .turns = result.turns, .tool_calls = result.tool_calls, .reserved = [_]u64{0} ** 4 };
    return wire.STATUS_OK;
}

fn sessionAbort(handle: ?*wire.SessionHandle, run_id: u64, reason_code: u32, out_error: ?*wire.OwnedBytesV1) callconv(.c) u32 {
    emptyError(out_error);
    const self = sessionFrom(handle orelse return fail(wire.STATUS_INVALID_ARGUMENT, "session is required", out_error));
    if (self.facade_poisoned.load(.acquire))
        return fail(wire.STATUS_INVALID_STATE, "Session is poisoned by a previous admitted Run failure", out_error);
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
    .abi_revision = wire.ABI_REVISION,
    .reserved0 = 0,
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

pub export fn metask_agentcore_get_api(requested_abi: u32) callconv(.c) ?*const anyopaque {
    if (requested_abi != wire.ABI_VERSION_V1) return null;
    return @ptrCast(&api_v1);
}

test "ABI discovery is versioned" {
    try std.testing.expect(metask_agentcore_get_api(0) == null);
    const raw = metask_agentcore_get_api(wire.ABI_VERSION_V1) orelse return error.MissingApi;
    const api: *const wire.ApiV1 = @ptrCast(@alignCast(raw));
    try std.testing.expectEqual(wire.REQUIRED_CAPABILITIES_V1, api.capabilities);
}

test "UI response parser owns AskUserQuestion answers" {
    const questions = [_]core.tool_context.AskQuestion{.{ .question = "continue?", .header = "choice", .multi = false, .options = &.{.{ .label = "yes", .description = "continue" }} }};
    const req = ui_request.UiRequest{ .ask_question = &questions };
    var out: ui_request.UiResponse = undefined;
    try protocol_v1.decodeUiResponse(std.testing.allocator, &req, "{\"answers\":[{\"values\":[\"yes\"]}]}", &out);
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
    const questions = [_]core.tool_context.AskQuestion{.{ .question = "continue?", .header = "choice", .multi = false, .options = &.{.{ .label = "yes", .description = "continue" }} }};
    const req = ui_request.UiRequest{ .ask_question = &questions };
    var out: ui_request.UiResponse = undefined;
    try std.testing.expectError(error.InvalidUiResponse, protocol_v1.decodeUiResponse(std.testing.allocator, &req, "{\"answers\":[]}", &out));
}

fn testHostIdent(anchor: *anyopaque) core.agent_session.HostRunIdentity {
    return .{
        .identity = .{ .session_id = core.session_id.SessionId.single, .run_id = 1 },
        .host_session_ctx = anchor,
    };
}

test "Host zero-length result must use a null pointer and preserves release descriptor on rejection" {
    const Probe = struct {
        var byte: u8 = 0;
        var releases: usize = 0;
        var released_ptr: ?[*]u8 = null;

        fn execute(_: ?*anyopaque, _: ?*const wire.RunContextV1, _: wire.BytesViewV1, out: ?*wire.OwnedBytesV1) callconv(.c) u32 {
            (out orelse return wire.HOST_FAILED).* = .{ .ptr = @ptrCast(&byte), .len = 0 };
            return wire.HOST_OK;
        }

        fn release(_: ?*anyopaque, out: ?*wire.OwnedBytesV1) callconv(.c) void {
            releases += 1;
            released_ptr = (out orelse return).ptr;
        }
    };
    Probe.releases = 0;
    Probe.released_ptr = null;
    var host = AbiHostTool{ .ctx = null, .execute_fn = Probe.execute, .release_fn = Probe.release };
    const outcome = try AbiHostTool.execute(&host, testHostIdent(@ptrCast(&host)), "{}");
    try std.testing.expect(outcome == .fatal);
    try std.testing.expectEqual(@as(usize, 1), Probe.releases);
    try std.testing.expect(Probe.released_ptr == @as(?[*]u8, @ptrCast(&Probe.byte)));
}

test "canonical empty Host tool results never call release" {
    const Probe = struct {
        var status: u32 = wire.HOST_OK;
        var releases: usize = 0;

        fn execute(_: ?*anyopaque, _: ?*const wire.RunContextV1, _: wire.BytesViewV1, out: ?*wire.OwnedBytesV1) callconv(.c) u32 {
            (out orelse return wire.HOST_FAILED).* = .{ .ptr = null, .len = 0 };
            return status;
        }

        fn release(_: ?*anyopaque, _: ?*wire.OwnedBytesV1) callconv(.c) void {
            releases += 1;
        }
    };
    var host = AbiHostTool{ .ctx = null, .execute_fn = Probe.execute, .release_fn = Probe.release };

    Probe.status = wire.HOST_OK;
    Probe.releases = 0;
    const outcome = try AbiHostTool.execute(&host, testHostIdent(@ptrCast(&host)), "{}");
    const result = outcome.ok;
    try std.testing.expectEqual(@as(usize, 0), result.bytes.len);
    result.release();
    try std.testing.expectEqual(@as(usize, 0), Probe.releases);

    inline for (.{ wire.HOST_FAILED, wire.HOST_REJECTED, wire.HOST_FATAL, @as(u32, 0xffff_ffff) }) |status| {
        Probe.status = status;
        Probe.releases = 0;
        const o = try AbiHostTool.execute(&host, testHostIdent(@ptrCast(&host)), "{}");
        if (status == wire.HOST_REJECTED) {
            try std.testing.expect(o == .rejected and o.rejected == null);
        } else if (status == wire.HOST_FAILED) {
            try std.testing.expect(o == .failed and o.failed == null);
        } else {
            try std.testing.expect(o == .fatal);
        }
        try std.testing.expectEqual(@as(usize, 0), Probe.releases);
    }
}

test "Host failure detail is transferred while fatal buffers release immediately" {
    const Probe = struct {
        var status: u32 = wire.HOST_FAILED;
        var bytes = [_]u8{ 'n', 'o', 't', ' ', 'a', ' ', 'r', 'e', 's', 'u', 'l', 't' };
        var releases: usize = 0;
        var released_ptr: ?[*]u8 = null;
        var released_len: u64 = 0;

        fn execute(_: ?*anyopaque, _: ?*const wire.RunContextV1, _: wire.BytesViewV1, out: ?*wire.OwnedBytesV1) callconv(.c) u32 {
            (out orelse return wire.HOST_FAILED).* = .{ .ptr = &bytes, .len = bytes.len };
            return status;
        }

        fn release(_: ?*anyopaque, out: ?*wire.OwnedBytesV1) callconv(.c) void {
            const value = out orelse return;
            releases += 1;
            released_ptr = value.ptr;
            released_len = value.len;
        }
    };
    const OutcomeTag = std.meta.Tag(core.agent_session.HostToolOutcome);
    const cases = [_]struct {
        status: u32,
        expected: OutcomeTag,
    }{
        .{ .status = wire.HOST_FAILED, .expected = .failed },
        .{ .status = wire.HOST_REJECTED, .expected = .rejected },
        .{ .status = wire.HOST_FATAL, .expected = .fatal },
        .{ .status = 0xffff_ffff, .expected = .fatal },
    };
    var host = AbiHostTool{ .ctx = null, .execute_fn = Probe.execute, .release_fn = Probe.release };
    for (cases) |case| {
        Probe.status = case.status;
        Probe.releases = 0;
        Probe.released_ptr = null;
        Probe.released_len = 0;
        const o = try AbiHostTool.execute(&host, testHostIdent(@ptrCast(&host)), "{}");
        try std.testing.expectEqual(case.expected, std.meta.activeTag(o));
        switch (o) {
            .failed => |maybe| if (maybe) |result| {
                try std.testing.expectEqualStrings(&Probe.bytes, result.bytes);
                result.release();
            },
            .rejected => |maybe| if (maybe) |result| {
                try std.testing.expectEqualStrings(&Probe.bytes, result.bytes);
                result.release();
            },
            else => {},
        }
        try std.testing.expectEqual(@as(usize, 1), Probe.releases);
        try std.testing.expect(Probe.released_ptr == @as(?[*]u8, @ptrCast(&Probe.bytes)));
        try std.testing.expectEqual(@as(u64, Probe.bytes.len), Probe.released_len);
    }
}

test "Host failure raw detail is not capped by the encoded error payload limit" {
    const a = std.testing.allocator;
    const bytes = try a.alloc(u8, wire.MAX_TOOL_ERROR_PAYLOAD_BYTES_V1 + 1);
    defer a.free(bytes);
    @memset(bytes, 'x');
    const Probe = struct {
        var payload: []u8 = &.{};
        var releases: usize = 0;

        fn execute(_: ?*anyopaque, _: ?*const wire.RunContextV1, _: wire.BytesViewV1, out: ?*wire.OwnedBytesV1) callconv(.c) u32 {
            (out orelse return wire.HOST_FATAL).* = .{ .ptr = payload.ptr, .len = payload.len };
            return wire.HOST_FAILED;
        }

        fn release(_: ?*anyopaque, _: ?*wire.OwnedBytesV1) callconv(.c) void {
            releases += 1;
        }
    };
    Probe.payload = bytes;
    Probe.releases = 0;
    var host = AbiHostTool{ .ctx = null, .execute_fn = Probe.execute, .release_fn = Probe.release };
    const outcome = try AbiHostTool.execute(&host, testHostIdent(@ptrCast(&host)), "{}");
    try std.testing.expect(outcome == .failed and outcome.failed != null);
    try std.testing.expectEqual(bytes.len, outcome.failed.?.bytes.len);
    outcome.failed.?.release();
    try std.testing.expectEqual(@as(usize, 1), Probe.releases);
}

test "Host UI descriptor ownership is independent of callback status" {
    const Probe = struct {
        var status: u32 = wire.UI_ANSWERED;
        var with_buffer: bool = false;
        var releases: usize = 0;
        const response_json = "{\"answers\":[{\"values\":[\"yes\"]}]}";

        fn request(_: ?*anyopaque, _: ?*const wire.RunContextV1, _: wire.BytesViewV1, out: ?*wire.OwnedBytesV1) callconv(.c) u32 {
            const result = out orelse return wire.UI_FATAL;
            result.* = if (with_buffer)
                .{ .ptr = @constCast(response_json.ptr), .len = response_json.len }
            else
                .{ .ptr = null, .len = 0 };
            return status;
        }

        fn release(_: ?*anyopaque, _: ?*wire.OwnedBytesV1) callconv(.c) void {
            releases += 1;
        }
    };
    const questions = [_]core.tool_context.AskQuestion{.{ .question = "continue?", .header = "choice", .multi = false, .options = &.{.{ .label = "yes", .description = "continue" }} }};
    const request = ui_request.UiRequest{ .ask_question = &questions };
    var response: ui_request.UiResponse = undefined;
    var fake = AbiSession{
        .callbacks = .{
            .struct_size = @sizeOf(wire.SessionCallbacksV1),
            .reserved0 = 0,
            .ctx = null,
            .on_event = null,
            .on_ui_request = Probe.request,
            .release_response = Probe.release,
            .reserved = [_]u64{0} ** 4,
        },
        .callback_status = .init(wire.STATUS_OK),
        .facade_poisoned = .init(false),
        .core_session = undefined,
    };

    Probe.status = wire.UI_ANSWERED;
    Probe.with_buffer = false;
    Probe.releases = 0;
    try std.testing.expectError(
        error.MalformedJson,
        AbiSession.requestUi(&fake, .{ .session_id = .single, .run_id = 1 }, std.testing.allocator, &request, &response),
    );
    try std.testing.expectEqual(@as(usize, 0), Probe.releases);

    Probe.status = wire.UI_UNAVAILABLE;
    Probe.with_buffer = false;
    Probe.releases = 0;
    try std.testing.expectEqual(
        ui_request.RequestOutcome.unavailable,
        try AbiSession.requestUi(&fake, .{ .session_id = .single, .run_id = 1 }, std.testing.allocator, &request, &response),
    );
    try std.testing.expectEqual(@as(usize, 0), Probe.releases);

    fake.callback_status.store(wire.STATUS_OK, .release);
    Probe.status = wire.UI_CANCELLED;
    Probe.with_buffer = true;
    Probe.releases = 0;
    try std.testing.expectError(
        error.UiCancelled,
        AbiSession.requestUi(&fake, .{ .session_id = .single, .run_id = 1 }, std.testing.allocator, &request, &response),
    );
    try std.testing.expectEqual(@as(usize, 1), Probe.releases);
    try std.testing.expectEqual(wire.STATUS_OK, fake.callback_status.load(.acquire));

    Probe.status = wire.UI_ANSWERED;
    Probe.with_buffer = true;
    Probe.releases = 0;
    try std.testing.expectEqual(
        ui_request.RequestOutcome.answered,
        try AbiSession.requestUi(&fake, .{ .session_id = .single, .run_id = 1 }, std.testing.allocator, &request, &response),
    );
    try std.testing.expectEqual(@as(usize, 1), Probe.releases);
    switch (response) {
        .answers => |answers| {
            for (answers) |answer| std.testing.allocator.free(@constCast(answer));
            std.testing.allocator.free(@constCast(answers));
        },
        else => unreachable,
    }

    inline for (.{ wire.UI_UNAVAILABLE, wire.UI_FATAL, @as(u32, 0xffff_ffff) }) |status| {
        Probe.status = status;
        Probe.with_buffer = true;
        Probe.releases = 0;
        if (status == wire.UI_UNAVAILABLE) {
            try std.testing.expectEqual(
                ui_request.RequestOutcome.unavailable,
                try AbiSession.requestUi(&fake, .{ .session_id = .single, .run_id = 1 }, std.testing.allocator, &request, &response),
            );
        } else {
            try std.testing.expectError(
                error.HostUiFailed,
                AbiSession.requestUi(&fake, .{ .session_id = .single, .run_id = 1 }, std.testing.allocator, &request, &response),
            );
        }
        try std.testing.expectEqual(@as(usize, 1), Probe.releases);
    }
}

test "AgentCore permission session choices stay in facade memory and unavailable denies once" {
    const Probe = struct {
        var status: u32 = wire.UI_ANSWERED;
        var response_json: []const u8 = "{\"permission\":\"allow_session\"}";
        var calls: usize = 0;
        var releases: usize = 0;

        fn request(_: ?*anyopaque, _: ?*const wire.RunContextV1, _: wire.BytesViewV1, out: ?*wire.OwnedBytesV1) callconv(.c) u32 {
            calls += 1;
            const result = out orelse return wire.UI_FATAL;
            result.* = if (response_json.len == 0)
                .{ .ptr = null, .len = 0 }
            else
                .{ .ptr = @constCast(response_json.ptr), .len = response_json.len };
            return status;
        }

        fn release(_: ?*anyopaque, _: ?*wire.OwnedBytesV1) callconv(.c) void {
            releases += 1;
        }
    };
    const request = ui_request.UiRequest{ .permission = .{ .tool = "Bash", .args = "{}" } };
    var response: ui_request.UiResponse = undefined;
    var fake = AbiSession{
        .callbacks = .{
            .struct_size = @sizeOf(wire.SessionCallbacksV1),
            .reserved0 = 0,
            .ctx = null,
            .on_event = null,
            .on_ui_request = Probe.request,
            .release_response = Probe.release,
            .reserved = [_]u64{0} ** 4,
        },
        .callback_status = .init(wire.STATUS_OK),
        .facade_poisoned = .init(false),
        .core_session = undefined,
    };
    defer fake.host_permission_rules.deinit();

    Probe.status = wire.UI_ANSWERED;
    Probe.response_json = "{\"permission\":\"allow_session\"}";
    Probe.calls = 0;
    Probe.releases = 0;
    try std.testing.expectEqual(
        ui_request.RequestOutcome.answered,
        try AbiSession.requestUi(&fake, .{ .session_id = .single, .run_id = 1 }, std.testing.allocator, &request, &response),
    );
    try std.testing.expect(response == .permission and response.permission == .allow_once);
    try std.testing.expectEqual(@as(usize, 1), Probe.calls);
    try std.testing.expectEqual(@as(usize, 1), Probe.releases);

    // The second request is answered from AgentCore-owned memory. The product
    // callback is not invoked and the core only sees an allow-once projection,
    // so its disk-persistence branch is unreachable.
    try std.testing.expectEqual(
        ui_request.RequestOutcome.answered,
        try AbiSession.requestUi(&fake, .{ .session_id = .single, .run_id = 2 }, std.testing.allocator, &request, &response),
    );
    try std.testing.expect(response == .permission and response.permission == .allow_once);
    try std.testing.expectEqual(@as(usize, 1), Probe.calls);
    try std.testing.expectEqual(@as(usize, 1), Probe.releases);

    var denied = AbiSession{
        .callbacks = fake.callbacks,
        .callback_status = .init(wire.STATUS_OK),
        .facade_poisoned = .init(false),
        .core_session = undefined,
    };
    defer denied.host_permission_rules.deinit();
    const write_request = ui_request.UiRequest{ .permission = .{ .tool = "Write", .args = "{}" } };
    Probe.status = wire.UI_ANSWERED;
    Probe.response_json = "{\"permission\":\"deny_session\"}";
    Probe.calls = 0;
    Probe.releases = 0;
    try std.testing.expectEqual(
        ui_request.RequestOutcome.answered,
        try AbiSession.requestUi(&denied, .{ .session_id = .single, .run_id = 1 }, std.testing.allocator, &write_request, &response),
    );
    try std.testing.expect(response == .permission and response.permission == .deny_once);
    try std.testing.expectEqual(
        ui_request.RequestOutcome.answered,
        try AbiSession.requestUi(&denied, .{ .session_id = .single, .run_id = 2 }, std.testing.allocator, &write_request, &response),
    );
    try std.testing.expect(response == .permission and response.permission == .deny_once);
    try std.testing.expectEqual(@as(usize, 1), Probe.calls);
    try std.testing.expectEqual(@as(usize, 1), Probe.releases);

    var unavailable = AbiSession{
        .callbacks = fake.callbacks,
        .callback_status = .init(wire.STATUS_OK),
        .facade_poisoned = .init(false),
        .core_session = undefined,
    };
    defer unavailable.host_permission_rules.deinit();
    Probe.status = wire.UI_UNAVAILABLE;
    Probe.response_json = "";
    try std.testing.expectEqual(
        ui_request.RequestOutcome.answered,
        try AbiSession.requestUi(&unavailable, .{ .session_id = .single, .run_id = 3 }, std.testing.allocator, &request, &response),
    );
    try std.testing.expect(response == .permission and response.permission == .deny_once);
    try std.testing.expectEqual(wire.STATUS_OK, unavailable.callback_status.load(.acquire));
}

test "oversized Host tool results are released exactly once" {
    const Probe = struct {
        var byte: u8 = 0;
        var releases: usize = 0;
        var released_len: u64 = 0;

        fn execute(_: ?*anyopaque, _: ?*const wire.RunContextV1, _: wire.BytesViewV1, out: ?*wire.OwnedBytesV1) callconv(.c) u32 {
            (out orelse return wire.HOST_FAILED).* = .{
                .ptr = @ptrCast(&byte),
                .len = wire.MAX_HOST_TOOL_RESULT_BYTES_V1 + 1,
            };
            return wire.HOST_OK;
        }

        fn release(_: ?*anyopaque, out: ?*wire.OwnedBytesV1) callconv(.c) void {
            releases += 1;
            released_len = (out orelse return).len;
        }
    };
    Probe.releases = 0;
    Probe.released_len = 0;
    var host = AbiHostTool{ .ctx = null, .execute_fn = Probe.execute, .release_fn = Probe.release };
    const o = try AbiHostTool.execute(&host, testHostIdent(@ptrCast(&host)), "{}");
    try std.testing.expect(o == .failed and o.failed == null);
    try std.testing.expectEqual(@as(usize, 1), Probe.releases);
    try std.testing.expectEqual(wire.MAX_HOST_TOOL_RESULT_BYTES_V1 + 1, Probe.released_len);
}

test "invalid UTF-8 Host tool results are released exactly once" {
    const Probe = struct {
        var bytes = [_]u8{0xff};
        var releases: usize = 0;

        fn execute(_: ?*anyopaque, _: ?*const wire.RunContextV1, _: wire.BytesViewV1, out: ?*wire.OwnedBytesV1) callconv(.c) u32 {
            (out orelse return wire.HOST_FAILED).* = .{ .ptr = &bytes, .len = bytes.len };
            return wire.HOST_OK;
        }

        fn release(_: ?*anyopaque, _: ?*wire.OwnedBytesV1) callconv(.c) void {
            releases += 1;
        }
    };
    Probe.releases = 0;
    var host = AbiHostTool{ .ctx = null, .execute_fn = Probe.execute, .release_fn = Probe.release };
    const o = try AbiHostTool.execute(&host, testHostIdent(@ptrCast(&host)), "{}");
    try std.testing.expect(o == .failed and o.failed == null);
    try std.testing.expectEqual(@as(usize, 1), Probe.releases);
}

test "oversized Host UI responses are released and classified as callback failures" {
    const Probe = struct {
        var byte: u8 = 0;
        var releases: usize = 0;

        fn request(_: ?*anyopaque, _: ?*const wire.RunContextV1, _: wire.BytesViewV1, out: ?*wire.OwnedBytesV1) callconv(.c) u32 {
            (out orelse return wire.UI_FATAL).* = .{
                .ptr = @ptrCast(&byte),
                .len = wire.MAX_UI_RESPONSE_BYTES_V1 + 1,
            };
            return wire.UI_ANSWERED;
        }

        fn release(_: ?*anyopaque, _: ?*wire.OwnedBytesV1) callconv(.c) void {
            releases += 1;
        }
    };
    Probe.releases = 0;
    const questions = [_]core.tool_context.AskQuestion{.{ .question = "continue?", .header = "choice", .multi = false, .options = &.{.{ .label = "yes", .description = "continue" }} }};
    const request = ui_request.UiRequest{ .ask_question = &questions };
    var response: ui_request.UiResponse = undefined;
    var fake = AbiSession{
        .callbacks = .{
            .struct_size = @sizeOf(wire.SessionCallbacksV1),
            .reserved0 = 0,
            .ctx = null,
            .on_event = null,
            .on_ui_request = Probe.request,
            .release_response = Probe.release,
            .reserved = [_]u64{0} ** 4,
        },
        .callback_status = .init(wire.STATUS_OK),
        .facade_poisoned = .init(false),
        .core_session = undefined,
    };
    try std.testing.expectError(
        error.HostUiFailed,
        AbiSession.requestUi(&fake, .{ .session_id = .single, .run_id = 1 }, std.testing.allocator, &request, &response),
    );
    try std.testing.expectEqual(@as(usize, 1), Probe.releases);
    try std.testing.expectEqual(wire.STATUS_CALLBACK_FAILED, fake.callback_status.load(.acquire));
}

test "Host schema limits reject excessive size and nesting" {
    const too_large = try std.testing.allocator.alloc(u8, @as(usize, @intCast(wire.MAX_TOOL_SCHEMA_BYTES_V1)) + 1);
    defer std.testing.allocator.free(too_large);
    @memset(too_large, ' ');
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.ResourceLimit, parseSchema(arena.allocator(), too_large));

    var nested = std.ArrayList(u8).empty;
    defer nested.deinit(std.testing.allocator);
    try nested.appendSlice(std.testing.allocator, "{\"type\":\"object\",\"properties\":{\"x\":");
    for (0..wire.MAX_TOOL_SCHEMA_DEPTH_V1 + 1) |_| try nested.appendSlice(std.testing.allocator, "{\"x\":");
    try nested.appendSlice(std.testing.allocator, "{}");
    for (0..wire.MAX_TOOL_SCHEMA_DEPTH_V1 + 1) |_| try nested.append(std.testing.allocator, '}');
    try nested.appendSlice(std.testing.allocator, "}}");
    try std.testing.expectError(error.ResourceLimit, parseSchema(arena.allocator(), nested.items));
}

test "Host schema admission rejects ambiguous object contracts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try std.testing.expectError(
        error.InvalidSchema,
        parseSchema(a, "{\"type\":\"object\",\"additionalProperties\":false}"),
    );
    try std.testing.expectError(
        error.InvalidSchema,
        parseSchema(a, "{\"type\":\"object\",\"required\":[\"missing\"]}"),
    );
    try std.testing.expectError(
        error.InvalidSchema,
        parseSchema(a, "{\"type\":\"object\",\"properties\":{\"x\":{\"type\":\"string\"}},\"required\":[\"x\",\"x\"]}"),
    );
    try std.testing.expectError(
        error.DuplicateField,
        parseSchema(a, "{\"type\":\"object\",\"type\":\"object\"}"),
    );
}

test "provider-facing tool names use the Revision 4 intersection grammar" {
    try std.testing.expect(validToolName("_"));
    try std.testing.expect(validToolName("A_9-name"));
    const max_name = "A" ++ ("x" ** 63);
    try std.testing.expectEqual(@as(usize, 64), max_name.len);
    try std.testing.expect(validToolName(max_name));

    try std.testing.expect(!validToolName(""));
    try std.testing.expect(!validToolName("1bad"));
    try std.testing.expect(!validToolName("bad:name"));
    try std.testing.expect(!validToolName("bad.name"));
    try std.testing.expect(!validToolName("A" ++ ("x" ** 64)));
}

test "Run OutOfMemory maps to the public OOM status" {
    var fake = AbiSession{
        .callbacks = std.mem.zeroes(wire.SessionCallbacksV1),
        .callback_status = .init(wire.STATUS_OK),
        .facade_poisoned = .init(false),
        .core_session = undefined,
    };
    try std.testing.expectEqual(wire.STATUS_OUT_OF_MEMORY, runErrorStatus(&fake, error.OutOfMemory));
}

test "diagnostic allocation failure leaves canonical empty output" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var sentinel: u8 = 0;
    var diagnostic = wire.OwnedBytesV1{ .ptr = @ptrCast(&sentinel), .len = 1 };
    writeDiagnostic(failing.allocator(), "invalid input", &diagnostic);
    try std.testing.expect(diagnostic.ptr == null);
    try std.testing.expectEqual(@as(u64, 0), diagnostic.len);
}

test "internal continuation states poison the ABI facade" {
    var fake = AbiSession{
        .callbacks = std.mem.zeroes(wire.SessionCallbacksV1),
        .callback_status = .init(wire.STATUS_OK),
        .facade_poisoned = .init(false),
        .core_session = undefined,
    };
    try std.testing.expectError(error.UnsupportedStopReason, stopReason(&fake, .suspended));
    try std.testing.expect(fake.facade_poisoned.load(.acquire));
    fake.facade_poisoned.store(false, .release);
    try std.testing.expectError(error.UnsupportedStopReason, stopReason(&fake, .backgrounded));
    try std.testing.expect(fake.facade_poisoned.load(.acquire));
    fake.facade_poisoned.store(false, .release);
    try std.testing.expectError(error.UnsupportedStopReason, stopReason(&fake, .budget));
    try std.testing.expect(fake.facade_poisoned.load(.acquire));
}

test "metadata limits enforce per-field and aggregate budgets" {
    var total: u64 = 0;
    try addMetadata(&total, wire.MAX_METADATA_STRING_BYTES_V1, wire.MAX_RUNTIME_METADATA_BYTES_V1);
    try std.testing.expectEqual(wire.MAX_METADATA_STRING_BYTES_V1, total);
    try std.testing.expectError(
        error.ResourceLimit,
        addMetadata(&total, wire.MAX_METADATA_STRING_BYTES_V1 + 1, wire.MAX_RUNTIME_METADATA_BYTES_V1),
    );
    total = wire.MAX_SESSION_METADATA_BYTES_V1;
    try std.testing.expectError(
        error.ResourceLimit,
        addMetadata(&total, 1, wire.MAX_SESSION_METADATA_BYTES_V1),
    );
}

test "Session create maps caller configuration errors to invalid argument" {
    inline for (.{
        error.InvalidWorkspaceRoot,
        error.InvalidWorkspaceHome,
        error.ToolNotInRuntime,
        error.DuplicateToolName,
        error.ShellToolDisabled,
    }) |err| {
        try std.testing.expectEqual(wire.STATUS_INVALID_ARGUMENT, sessionCreateErrorStatus(err));
    }
    try std.testing.expectEqual(wire.STATUS_OUT_OF_MEMORY, sessionCreateErrorStatus(error.OutOfMemory));
    try std.testing.expectEqual(wire.STATUS_INVALID_STATE, sessionCreateErrorStatus(error.RuntimeUnavailable));
    try std.testing.expectEqual(wire.STATUS_CORE_ERROR, sessionCreateErrorStatus(error.Unexpected));
}

test "ABI Runtime rejects process-only built-ins as invalid input" {
    const names = [_]wire.BytesViewV1{view("TaskCreate")};
    var config = std.mem.zeroes(wire.RuntimeConfigV1);
    config.struct_size = @sizeOf(wire.RuntimeConfigV1);
    config.builtin_tools = &names;
    config.builtin_tool_count = names.len;
    var runtime: ?*wire.RuntimeHandle = null;
    var diagnostic = wire.OwnedBytesV1{ .ptr = null, .len = 0 };
    defer bufferRelease(&diagnostic);
    try std.testing.expectEqual(wire.STATUS_INVALID_ARGUMENT, runtimeCreate(&config, &runtime, &diagnostic));
    try std.testing.expect(runtime == null);
}

test "ABI Runtime applies tool-name grammar to built-ins and Host tools" {
    const Probe = struct {
        fn execute(_: ?*anyopaque, _: ?*const wire.RunContextV1, _: wire.BytesViewV1, _: ?*wire.OwnedBytesV1) callconv(.c) u32 {
            return wire.HOST_FAILED;
        }

        fn release(_: ?*anyopaque, _: ?*wire.OwnedBytesV1) callconv(.c) void {}
    };
    var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
    defer bufferRelease(&diagnostic);
    var runtime: ?*wire.RuntimeHandle = null;

    const invalid_builtin_names = [_]wire.BytesViewV1{view("1bad")};
    var runtime_config = std.mem.zeroes(wire.RuntimeConfigV1);
    runtime_config.struct_size = @sizeOf(wire.RuntimeConfigV1);
    runtime_config.builtin_tools = &invalid_builtin_names;
    runtime_config.builtin_tool_count = invalid_builtin_names.len;
    try std.testing.expectEqual(
        wire.STATUS_INVALID_ARGUMENT,
        runtimeCreate(&runtime_config, &runtime, &diagnostic),
    );
    try std.testing.expect(runtime == null);
    bufferRelease(&diagnostic);

    var host = std.mem.zeroes(wire.HostToolV1);
    host.struct_size = @sizeOf(wire.HostToolV1);
    host.name = view("bad:name");
    host.description = view("test");
    host.input_schema_json = view("{\"type\":\"object\"}");
    host.execute = Probe.execute;
    host.release_result = Probe.release;
    runtime_config = std.mem.zeroes(wire.RuntimeConfigV1);
    runtime_config.struct_size = @sizeOf(wire.RuntimeConfigV1);
    runtime_config.host_tools = @ptrCast(&host);
    runtime_config.host_tool_count = 1;
    try std.testing.expectEqual(
        wire.STATUS_INVALID_ARGUMENT,
        runtimeCreate(&runtime_config, &runtime, &diagnostic),
    );
    try std.testing.expect(runtime == null);
}

test "ABI Runtime reports oversized Host schemas as resource limits" {
    const Probe = struct {
        var byte: u8 = 0;

        fn execute(_: ?*anyopaque, _: ?*const wire.RunContextV1, _: wire.BytesViewV1, _: ?*wire.OwnedBytesV1) callconv(.c) u32 {
            return wire.HOST_FAILED;
        }

        fn release(_: ?*anyopaque, _: ?*wire.OwnedBytesV1) callconv(.c) void {}
    };
    var host = std.mem.zeroes(wire.HostToolV1);
    host.struct_size = @sizeOf(wire.HostToolV1);
    host.name = view("OversizedSchema");
    host.description = view("test");
    host.input_schema_json = .{
        .ptr = @ptrCast(&Probe.byte),
        .len = wire.MAX_TOOL_SCHEMA_BYTES_V1 + 1,
    };
    host.execute = Probe.execute;
    host.release_result = Probe.release;
    var config = std.mem.zeroes(wire.RuntimeConfigV1);
    config.struct_size = @sizeOf(wire.RuntimeConfigV1);
    config.host_tools = @ptrCast(&host);
    config.host_tool_count = 1;
    var runtime: ?*wire.RuntimeHandle = null;
    var diagnostic = std.mem.zeroes(wire.OwnedBytesV1);
    defer bufferRelease(&diagnostic);
    try std.testing.expectEqual(wire.STATUS_RESOURCE_LIMIT, runtimeCreate(&config, &runtime, &diagnostic));
    try std.testing.expect(runtime == null);
}
