//! Stable declarations for the source-free AgentCore binary ABI v1.

pub const ABI_VERSION_V1: u32 = 1;

pub const Status = enum(u32) {
    ok = 0,
    invalid_argument = 1,
    out_of_memory = 2,
    busy = 3,
    stale_run = 4,
    too_late = 5,
    invalid_state = 6,
    core_error = 7,
    callback_failed = 8,
    internal_error = 9,

    pub fn fromCode(code: u32) error{UnknownStatus}!Status {
        return switch (code) {
            @intFromEnum(Status.ok) => .ok,
            @intFromEnum(Status.invalid_argument) => .invalid_argument,
            @intFromEnum(Status.out_of_memory) => .out_of_memory,
            @intFromEnum(Status.busy) => .busy,
            @intFromEnum(Status.stale_run) => .stale_run,
            @intFromEnum(Status.too_late) => .too_late,
            @intFromEnum(Status.invalid_state) => .invalid_state,
            @intFromEnum(Status.core_error) => .core_error,
            @intFromEnum(Status.callback_failed) => .callback_failed,
            @intFromEnum(Status.internal_error) => .internal_error,
            else => error.UnknownStatus,
        };
    }
};

pub const STATUS_OK: u32 = @intFromEnum(Status.ok);
pub const STATUS_INVALID_ARGUMENT: u32 = @intFromEnum(Status.invalid_argument);
pub const STATUS_OUT_OF_MEMORY: u32 = @intFromEnum(Status.out_of_memory);
pub const STATUS_BUSY: u32 = @intFromEnum(Status.busy);
pub const STATUS_STALE_RUN: u32 = @intFromEnum(Status.stale_run);
pub const STATUS_TOO_LATE: u32 = @intFromEnum(Status.too_late);
pub const STATUS_INVALID_STATE: u32 = @intFromEnum(Status.invalid_state);
pub const STATUS_CORE_ERROR: u32 = @intFromEnum(Status.core_error);
pub const STATUS_CALLBACK_FAILED: u32 = @intFromEnum(Status.callback_failed);
pub const STATUS_INTERNAL_ERROR: u32 = @intFromEnum(Status.internal_error);

pub const PROVIDER_ANTHROPIC: u32 = 1;
pub const PROVIDER_OPENAI: u32 = 2;
pub const PROVIDER_GEMINI: u32 = 3;

pub const PERMISSION_DEFAULT: u32 = 1;
pub const PERMISSION_ACCEPT_EDITS: u32 = 2;
pub const PERMISSION_PLAN: u32 = 3;
pub const PERMISSION_AUTO: u32 = 4;
pub const PERMISSION_DONT_ASK: u32 = 5;
pub const PERMISSION_BYPASS: u32 = 6;

pub const SHELL_DISABLED: u32 = 1;
pub const SHELL_SANDBOXED: u32 = 2;
pub const SHELL_UNRESTRICTED: u32 = 3;

pub const ABORT_USER_REQUEST: u32 = 1;
pub const ABORT_TIMEOUT: u32 = 2;

pub const StopReason = enum(u32) {
    invalid = 0,
    end_turn = 1,
    max_turns = 2,
    aborted = 3,
    tool_error = 4,
    api_error = 5,
    tool_loop = 6,
    suspended = 7,
    backgrounded = 8,
    budget = 9,

    pub fn fromCode(code: u32) error{UnknownStopReason}!StopReason {
        return switch (code) {
            @intFromEnum(StopReason.invalid) => .invalid,
            @intFromEnum(StopReason.end_turn) => .end_turn,
            @intFromEnum(StopReason.max_turns) => .max_turns,
            @intFromEnum(StopReason.aborted) => .aborted,
            @intFromEnum(StopReason.tool_error) => .tool_error,
            @intFromEnum(StopReason.api_error) => .api_error,
            @intFromEnum(StopReason.tool_loop) => .tool_loop,
            @intFromEnum(StopReason.suspended) => .suspended,
            @intFromEnum(StopReason.backgrounded) => .backgrounded,
            @intFromEnum(StopReason.budget) => .budget,
            else => error.UnknownStopReason,
        };
    }
};

pub const STOP_INVALID: u32 = @intFromEnum(StopReason.invalid);
pub const STOP_END_TURN: u32 = @intFromEnum(StopReason.end_turn);
pub const STOP_MAX_TURNS: u32 = @intFromEnum(StopReason.max_turns);
pub const STOP_ABORTED: u32 = @intFromEnum(StopReason.aborted);
pub const STOP_TOOL_ERROR: u32 = @intFromEnum(StopReason.tool_error);
pub const STOP_API_ERROR: u32 = @intFromEnum(StopReason.api_error);
pub const STOP_TOOL_LOOP: u32 = @intFromEnum(StopReason.tool_loop);
pub const STOP_SUSPENDED: u32 = @intFromEnum(StopReason.suspended);
pub const STOP_BACKGROUNDED: u32 = @intFromEnum(StopReason.backgrounded);
pub const STOP_BUDGET: u32 = @intFromEnum(StopReason.budget);

pub const CALLBACK_CONTINUE: u32 = 0;
pub const CALLBACK_FATAL: u32 = 1;
pub const UI_ANSWERED: u32 = 0;
pub const UI_UNAVAILABLE: u32 = 1;
pub const UI_FATAL: u32 = 2;
pub const HOST_OK: u32 = 0;
pub const HOST_FAILED: u32 = 1;
pub const HOST_REJECTED: u32 = 2;

pub const CAP_RUNTIME: u64 = 1 << 0;
pub const CAP_BUILTIN_TOOLS: u64 = 1 << 1;
pub const CAP_HOST_SYNC_TOOLS: u64 = 1 << 2;
pub const CAP_HOST_UI: u64 = 1 << 3;
pub const CAP_CORE_EVENTS_JSON: u64 = 1 << 4;
pub const CAP_ABORT: u64 = 1 << 5;
pub const REQUIRED_CAPABILITIES_V1: u64 = CAP_RUNTIME | CAP_BUILTIN_TOOLS | CAP_HOST_SYNC_TOOLS | CAP_HOST_UI | CAP_CORE_EVENTS_JSON | CAP_ABORT;

pub const RuntimeHandle = opaque {};
pub const SessionHandle = opaque {};

pub const BytesViewV1 = extern struct {
    ptr: ?[*]const u8,
    len: u64,
};

pub const OwnedBytesV1 = extern struct {
    ptr: ?[*]u8,
    len: u64,
};

/// Inputs are borrowed. A HOST_OK result stays Host-owned until release_result.
pub const HostExecuteFnV1 = *const fn (?*anyopaque, BytesViewV1, BytesViewV1, ?*OwnedBytesV1) callconv(.c) u32;
pub const HostReleaseFnV1 = *const fn (?*anyopaque, ?*OwnedBytesV1) callconv(.c) void;

pub const HostToolV1 = extern struct {
    struct_size: u32,
    reserved0: u32,
    ctx: ?*anyopaque,
    name: BytesViewV1,
    description: BytesViewV1,
    input_schema_json: BytesViewV1,
    execute: ?HostExecuteFnV1,
    release_result: ?HostReleaseFnV1,
    reserved: [2]u64,
};

pub const RuntimeConfigV1 = extern struct {
    struct_size: u32,
    reserved0: u32,
    builtin_tools: ?[*]const BytesViewV1,
    builtin_tool_count: u64,
    host_tools: ?[*]const HostToolV1,
    host_tool_count: u64,
    reserved: [4]u64,
};

/// Tagged CoreEvent JSON is borrowed for this synchronous callback only.
pub const OnEventFnV1 = *const fn (?*anyopaque, ?*SessionHandle, u64, BytesViewV1) callconv(.c) u32;
/// ABI v1 UI requests are synchronous; an answered JSON buffer is released
/// exactly once through ReleaseResponseFnV1.
pub const OnUiRequestFnV1 = *const fn (?*anyopaque, ?*SessionHandle, BytesViewV1, ?*OwnedBytesV1) callconv(.c) u32;
pub const ReleaseResponseFnV1 = *const fn (?*anyopaque, ?*OwnedBytesV1) callconv(.c) void;

pub const SessionCallbacksV1 = extern struct {
    struct_size: u32,
    reserved0: u32,
    ctx: ?*anyopaque,
    on_event: ?OnEventFnV1,
    on_ui_request: ?OnUiRequestFnV1,
    release_response: ?ReleaseResponseFnV1,
    reserved: [4]u64,
};

pub const SessionConfigV1 = extern struct {
    struct_size: u32,
    provider_kind_code: u32,
    permission_mode_code: u32,
    shell_policy_code: u32,
    api_key: BytesViewV1,
    model: BytesViewV1,
    base_url: BytesViewV1,
    workspace_root: BytesViewV1,
    workspace_home: BytesViewV1,
    allowed_tools: ?[*]const BytesViewV1,
    allowed_tool_count: u64,
    reserved: [4]u64,
};

pub const RunOptionsV1 = extern struct {
    struct_size: u32,
    max_turns: u32,
    reserved: [4]u64,
};

pub const RunResultV1 = extern struct {
    struct_size: u32,
    stop_reason_code: u32,
    turns: u32,
    tool_calls: u32,
    reserved: [4]u64,
};

pub const RuntimeCreateFnV1 = *const fn (?*const RuntimeConfigV1, ?*?*RuntimeHandle, ?*OwnedBytesV1) callconv(.c) u32;
pub const RuntimeDestroyFnV1 = *const fn (?*RuntimeHandle, ?*OwnedBytesV1) callconv(.c) u32;
pub const SessionCreateFnV1 = *const fn (?*RuntimeHandle, ?*const SessionConfigV1, ?*const SessionCallbacksV1, ?*?*SessionHandle, ?*OwnedBytesV1) callconv(.c) u32;
pub const SessionDestroyFnV1 = *const fn (?*SessionHandle, ?*OwnedBytesV1) callconv(.c) u32;
pub const SessionRunFnV1 = *const fn (?*SessionHandle, u64, BytesViewV1, ?*const RunOptionsV1, ?*RunResultV1, ?*OwnedBytesV1) callconv(.c) u32;
pub const SessionAbortFnV1 = *const fn (?*SessionHandle, u64, u32, ?*OwnedBytesV1) callconv(.c) u32;
pub const BufferReleaseFnV1 = *const fn (?*OwnedBytesV1) callconv(.c) void;

pub const ApiV1 = extern struct {
    struct_size: u32,
    abi_version: u32,
    capabilities: u64,
    runtime_create: ?RuntimeCreateFnV1,
    runtime_destroy: ?RuntimeDestroyFnV1,
    session_create: ?SessionCreateFnV1,
    session_destroy: ?SessionDestroyFnV1,
    session_run: ?SessionRunFnV1,
    session_abort: ?SessionAbortFnV1,
    buffer_release: ?BufferReleaseFnV1,
    reserved: [4]u64,
};

test "ABI v1 public layouts are fixed on supported 64-bit targets" {
    const std = @import("std");
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(BytesViewV1));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(OwnedBytesV1));
    try std.testing.expectEqual(@as(usize, 96), @sizeOf(HostToolV1));
    try std.testing.expectEqual(@as(usize, 72), @sizeOf(RuntimeConfigV1));
    try std.testing.expectEqual(@as(usize, 72), @sizeOf(SessionCallbacksV1));
    try std.testing.expectEqual(@as(usize, 144), @sizeOf(SessionConfigV1));
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(RunOptionsV1));
    try std.testing.expectEqual(@as(usize, 48), @sizeOf(RunResultV1));
    try std.testing.expectEqual(@as(usize, 104), @sizeOf(ApiV1));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(HostToolV1, "ctx"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(SessionConfigV1, "api_key"));
    try std.testing.expectEqual(@as(usize, 96), @offsetOf(SessionConfigV1, "allowed_tools"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(ApiV1, "runtime_create"));
    try std.testing.expectEqual(@as(usize, 48), @offsetOf(ApiV1, "session_run"));
}

test "typed status and stop reason validate every public code" {
    const std = @import("std");
    inline for (std.meta.fields(Status)) |field| {
        const value: Status = @enumFromInt(field.value);
        try std.testing.expectEqual(value, try Status.fromCode(field.value));
    }
    inline for (std.meta.fields(StopReason)) |field| {
        const value: StopReason = @enumFromInt(field.value);
        try std.testing.expectEqual(value, try StopReason.fromCode(field.value));
    }
    try std.testing.expectError(error.UnknownStatus, Status.fromCode(10));
    try std.testing.expectError(error.UnknownStatus, Status.fromCode(std.math.maxInt(u32)));
    try std.testing.expectError(error.UnknownStopReason, StopReason.fromCode(10));
    try std.testing.expectError(error.UnknownStopReason, StopReason.fromCode(std.math.maxInt(u32)));
}
