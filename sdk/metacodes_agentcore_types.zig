//! Declarations for the source-free AgentCore binary ABI v1 (experimental).

/// ABI v1 is experimental; the 2026-07-17 freeze was retracted (see
/// doc/AGENTCORE_BINARY_ABI.md, Status). No stability promise: layouts and
/// semantics may change incompatibly between commits. Pin an exact bundle.
pub const ABI_VERSION_V1: u32 = 1;
pub const ABI_REVISION: u32 = 2;

comptime {
    if (@sizeOf(usize) != 8)
        @compileError("AgentCore ABI v1 revision 2 requires a 64-bit pointer ABI");
}

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
    resource_limit = 10,

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
            @intFromEnum(Status.resource_limit) => .resource_limit,
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
pub const STATUS_RESOURCE_LIMIT: u32 = @intFromEnum(Status.resource_limit);

pub const PROVIDER_ANTHROPIC: u32 = 1;
pub const PROVIDER_OPENAI: u32 = 2;
pub const PROVIDER_GEMINI: u32 = 3;

pub const PERMISSION_DEFAULT: u32 = 1;
pub const PERMISSION_ACCEPT_EDITS: u32 = 2;
pub const PERMISSION_AUTO: u32 = 3;
pub const PERMISSION_DONT_ASK: u32 = 4;
pub const PERMISSION_BYPASS: u32 = 5;

pub const SHELL_DISABLED: u32 = 1;
pub const SHELL_SANDBOXED: u32 = 2;
pub const SHELL_UNRESTRICTED: u32 = 3;

pub const ABORT_USER_REQUEST: u32 = 1;
pub const ABORT_TIMEOUT: u32 = 2;

pub const StopReason = enum(u32) {
    end_turn = 1,
    max_turns = 2,
    aborted = 3,
    tool_error = 4,
    api_error = 5,
    tool_loop = 6,

    pub fn fromCode(code: u32) error{UnknownStopReason}!StopReason {
        return switch (code) {
            @intFromEnum(StopReason.end_turn) => .end_turn,
            @intFromEnum(StopReason.max_turns) => .max_turns,
            @intFromEnum(StopReason.aborted) => .aborted,
            @intFromEnum(StopReason.tool_error) => .tool_error,
            @intFromEnum(StopReason.api_error) => .api_error,
            @intFromEnum(StopReason.tool_loop) => .tool_loop,
            else => error.UnknownStopReason,
        };
    }
};

pub const STOP_END_TURN: u32 = @intFromEnum(StopReason.end_turn);
pub const STOP_MAX_TURNS: u32 = @intFromEnum(StopReason.max_turns);
pub const STOP_ABORTED: u32 = @intFromEnum(StopReason.aborted);
pub const STOP_TOOL_ERROR: u32 = @intFromEnum(StopReason.tool_error);
pub const STOP_API_ERROR: u32 = @intFromEnum(StopReason.api_error);
pub const STOP_TOOL_LOOP: u32 = @intFromEnum(StopReason.tool_loop);

/// V1 resource limits guard allocation-amplifying Host inputs. They are part
/// of the public contract, not a claim that the same-process Host is untrusted.
pub const MAX_TOOL_COUNT_V1: u64 = 1024;
pub const MAX_TOOL_SCHEMA_BYTES_V1: u64 = 1024 * 1024;
pub const MAX_TOOL_SCHEMA_DEPTH_V1: u32 = 32;
pub const MAX_TOOL_SCHEMA_PROPERTIES_V1: u64 = 1024;
pub const MAX_UI_RESPONSE_BYTES_V1: u64 = 1024 * 1024;
pub const MAX_HOST_TOOL_RESULT_BYTES_V1: u64 = 16 * 1024 * 1024;
pub const MAX_TOOL_ERROR_PAYLOAD_BYTES_V1: u64 = 1024 * 1024;
pub const MAX_SESSION_ID_BYTES_V1: u64 = 64;
pub const MAX_METADATA_STRING_BYTES_V1: u64 = 1024 * 1024;
pub const MAX_RUNTIME_METADATA_BYTES_V1: u64 = 16 * 1024 * 1024;
pub const MAX_SESSION_METADATA_BYTES_V1: u64 = 4 * 1024 * 1024;
pub const MAX_TURNS_V1: u32 = 1000;

pub const EVENT_CONTINUE: u32 = 0;
pub const EVENT_FATAL: u32 = 1;
pub const UI_ANSWERED: u32 = 0;
pub const UI_UNAVAILABLE: u32 = 1;
pub const UI_FATAL: u32 = 2;
pub const HOST_OK: u32 = 0;
pub const HOST_FAILED: u32 = 1;
pub const HOST_REJECTED: u32 = 2;
pub const HOST_FATAL: u32 = 3;

pub const CAP_RUNTIME: u64 = 1 << 0;
pub const CAP_BUILTIN_TOOLS: u64 = 1 << 1;
pub const CAP_HOST_SYNC_TOOLS: u64 = 1 << 2;
pub const CAP_HOST_UI: u64 = 1 << 3;
pub const CAP_CORE_EVENTS_JSON: u64 = 1 << 4;
pub const CAP_ABORT: u64 = 1 << 5;
pub const REQUIRED_CAPABILITIES_V1: u64 = CAP_RUNTIME | CAP_BUILTIN_TOOLS | CAP_HOST_SYNC_TOOLS | CAP_HOST_UI | CAP_CORE_EVENTS_JSON | CAP_ABORT;

/// V1 is a rigid ABI: every struct_size is exact and every reserved field is
/// zero. capabilities describes the returned library table, not per-instance
/// negotiation. Layout or table extensions require a new discovery version.
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

/// Borrowed identity tuple for one admitted Run. A fresh stack-local value may
/// be used for each callback; consumers compare fields, never pointer identity.
pub const RunContextV1 = extern struct {
    struct_size: u32,
    reserved0: u32,
    session: ?*SessionHandle,
    run_id: u64,
    session_id: BytesViewV1,
    reserved: [2]u64,
};

/// Canonical empty has no release token. Every other Host callback descriptor
/// is passed to its paired release function exactly once, independent of the
/// callback status. Host owns `host_ctx` through successful Runtime destroy;
/// `run`, its `session_id`, and provider-produced `arguments_json` are borrowed
/// for the callback. HOST_OK carries result text; HOST_FAILED/HOST_REJECTED may
/// carry up to MAX_HOST_TOOL_RESULT_BYTES_V1 of raw error detail, which is
/// subject to MAX_TOOL_ERROR_PAYLOAD_BYTES_V1 after serialization. HOST_FATAL
/// and unknown codes are fatal.
pub const HostExecuteFnV1 = *const fn (
    host_ctx: ?*anyopaque,
    run: ?*const RunContextV1,
    arguments_json: BytesViewV1,
    out_result: ?*OwnedBytesV1,
) callconv(.c) u32;
pub const HostReleaseFnV1 = *const fn (
    host_ctx: ?*anyopaque,
    result: ?*OwnedBytesV1,
) callconv(.c) void;

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
/// Different Sessions may call the same function concurrently.
pub const OnEventFnV1 = *const fn (
    session_ctx: ?*anyopaque,
    run: ?*const RunContextV1,
    event_json: BytesViewV1,
) callconv(.c) u32;
/// ABI v1 UI requests are synchronous. Only UI_ANSWERED consumes the JSON;
/// descriptor ownership follows the same status-independent rule above.
pub const OnUiRequestFnV1 = *const fn (
    session_ctx: ?*anyopaque,
    run: ?*const RunContextV1,
    request_json: BytesViewV1,
    out_response: ?*OwnedBytesV1,
) callconv(.c) u32;
pub const ReleaseResponseFnV1 = *const fn (
    session_ctx: ?*anyopaque,
    response: ?*OwnedBytesV1,
) callconv(.c) void;

/// Host owns `ctx` through successful Session destroy. AgentCore copies this
/// descriptor during Session creation but never frees `ctx`.
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

/// Terminal Run summary. Fields are defined only when `session_run` returns
/// `STATUS_OK`; on any other status they are unspecified and must not be read.
pub const RunResultV1 = extern struct {
    struct_size: u32,
    stop_reason_code: u32,
    turns: u32,
    tool_calls: u32,
    reserved: [4]u64,
};

/// The final OwnedBytesV1 pointer on each AgentCore operation is an optional,
/// write-only diagnostic output. Release a prior diagnostic before reusing
/// its variable. Diagnostic allocation is best-effort and never changes the
/// operation's primary status.
pub const RuntimeCreateFnV1 = *const fn (?*const RuntimeConfigV1, ?*?*RuntimeHandle, ?*OwnedBytesV1) callconv(.c) u32;
pub const RuntimeDestroyFnV1 = *const fn (?*RuntimeHandle, ?*OwnedBytesV1) callconv(.c) u32;
pub const SessionCreateFnV1 = *const fn (?*RuntimeHandle, ?*const SessionConfigV1, ?*const SessionCallbacksV1, ?*?*SessionHandle, ?*OwnedBytesV1) callconv(.c) u32;
pub const SessionDestroyFnV1 = *const fn (?*SessionHandle, ?*OwnedBytesV1) callconv(.c) u32;
/// Pre-admission validation, resource-limit, busy, and stale-run failures leave
/// the Session reusable. Once admitted, OOM/core/callback/internal failure
/// poisons it; successful completion, including STOP_ABORTED, returns it idle.
/// Given a valid handle, poisoned state precedes remaining argument validation.
/// V1 cannot recover or import Conversation/history into a poisoned Session.
/// `run_id` is Host-assigned, non-zero, and scoped to one Session. Each
/// admitted Run must use a value strictly greater than the Session's previous
/// admitted value. Pre-admission rejection never advances that value, so an
/// otherwise valid greater ID remains available for retry; zero and stale IDs
/// do not. After admitting `maxInt(u64)`, the Host must create a new Session.
pub const SessionRunFnV1 = *const fn (
    session: ?*SessionHandle,
    run_id: u64,
    prompt: BytesViewV1,
    options: ?*const RunOptionsV1,
    out_result: ?*RunResultV1,
    out_diagnostic: ?*OwnedBytesV1,
) callconv(.c) u32;

/// On a usable Session, zero is invalid. The matching active `run_id` requests
/// cooperative abort; another active ID is stale. While idle, the last admitted
/// ID is too late and every other ID is stale. A poisoned Session returns
/// invalid state regardless of the supplied ID.
pub const SessionAbortFnV1 = *const fn (
    session: ?*SessionHandle,
    run_id: u64,
    reason_code: u32,
    out_diagnostic: ?*OwnedBytesV1,
) callconv(.c) u32;
/// Releases only library-owned diagnostics, never Host-owned tool or UI
/// callback buffers.
pub const BufferReleaseFnV1 = *const fn (?*OwnedBytesV1) callconv(.c) void;

pub const ApiV1 = extern struct {
    struct_size: u32,
    abi_version: u32,
    abi_revision: u32,
    reserved0: u32,
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
    try std.testing.expectEqual(@as(usize, 56), @sizeOf(RunContextV1));
    try std.testing.expectEqual(@as(usize, 96), @sizeOf(HostToolV1));
    try std.testing.expectEqual(@as(usize, 72), @sizeOf(RuntimeConfigV1));
    try std.testing.expectEqual(@as(usize, 72), @sizeOf(SessionCallbacksV1));
    try std.testing.expectEqual(@as(usize, 144), @sizeOf(SessionConfigV1));
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(RunOptionsV1));
    try std.testing.expectEqual(@as(usize, 48), @sizeOf(RunResultV1));
    try std.testing.expectEqual(@as(usize, 112), @sizeOf(ApiV1));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(RunContextV1, "session"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(RunContextV1, "run_id"));
    try std.testing.expectEqual(@as(usize, 24), @offsetOf(RunContextV1, "session_id"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(HostToolV1, "ctx"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(SessionConfigV1, "api_key"));
    try std.testing.expectEqual(@as(usize, 96), @offsetOf(SessionConfigV1, "allowed_tools"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(ApiV1, "abi_revision"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(ApiV1, "capabilities"));
    try std.testing.expectEqual(@as(usize, 24), @offsetOf(ApiV1, "runtime_create"));
    try std.testing.expectEqual(@as(usize, 56), @offsetOf(ApiV1, "session_run"));
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
    try std.testing.expectError(error.UnknownStatus, Status.fromCode(11));
    try std.testing.expectError(error.UnknownStatus, Status.fromCode(std.math.maxInt(u32)));
    try std.testing.expectError(error.UnknownStopReason, StopReason.fromCode(0));
    try std.testing.expectError(error.UnknownStopReason, StopReason.fromCode(7));
    try std.testing.expectError(error.UnknownStopReason, StopReason.fromCode(std.math.maxInt(u32)));
}
