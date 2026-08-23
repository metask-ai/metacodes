//! Declarations for the source-free AgentCore binary ABI v1 (experimental).

/// ABI v1 is experimental; the 2026-07-17 freeze was retracted (see
/// doc/AGENTCORE_BINARY_ABI.md, Status). No stability promise: layouts and
/// semantics may change incompatibly between commits. Pin an exact bundle.
pub const ABI_VERSION_V1: u32 = 1;
pub const ABI_REVISION: u32 = 12;

comptime {
    if (@sizeOf(usize) != 8)
        @compileError("AgentCore ABI v1 revision 12 requires a 64-bit pointer ABI");
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
    skill_catalog_invalid = 11,
    stale_catalog = 12,
    skill_not_found = 13,
    invalid_skill_arguments = 14,
    skill_policy_violation = 15,
    skill_unavailable = 16,
    stale_compact = 17,
    checkpoint_budget_required = 18,
    checkpoint_corrupt = 19,
    checkpoint_unsupported = 20,
    checkpoint_incompatible = 21,
    checkpoint_io = 22,
    logical_session_conflict = 23,
    mcp_not_refreshed = 24,
    invalid_mcp_selection = 25,
    completion_unsupported_response = 26,
    skill_catalog_incomplete = 27,

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
            @intFromEnum(Status.skill_catalog_invalid) => .skill_catalog_invalid,
            @intFromEnum(Status.stale_catalog) => .stale_catalog,
            @intFromEnum(Status.skill_not_found) => .skill_not_found,
            @intFromEnum(Status.invalid_skill_arguments) => .invalid_skill_arguments,
            @intFromEnum(Status.skill_policy_violation) => .skill_policy_violation,
            @intFromEnum(Status.skill_unavailable) => .skill_unavailable,
            @intFromEnum(Status.stale_compact) => .stale_compact,
            @intFromEnum(Status.checkpoint_budget_required) => .checkpoint_budget_required,
            @intFromEnum(Status.checkpoint_corrupt) => .checkpoint_corrupt,
            @intFromEnum(Status.checkpoint_unsupported) => .checkpoint_unsupported,
            @intFromEnum(Status.checkpoint_incompatible) => .checkpoint_incompatible,
            @intFromEnum(Status.checkpoint_io) => .checkpoint_io,
            @intFromEnum(Status.logical_session_conflict) => .logical_session_conflict,
            @intFromEnum(Status.mcp_not_refreshed) => .mcp_not_refreshed,
            @intFromEnum(Status.invalid_mcp_selection) => .invalid_mcp_selection,
            @intFromEnum(Status.completion_unsupported_response) => .completion_unsupported_response,
            @intFromEnum(Status.skill_catalog_incomplete) => .skill_catalog_incomplete,
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
pub const STATUS_SKILL_CATALOG_INVALID: u32 = @intFromEnum(Status.skill_catalog_invalid);
pub const STATUS_STALE_CATALOG: u32 = @intFromEnum(Status.stale_catalog);
pub const STATUS_SKILL_NOT_FOUND: u32 = @intFromEnum(Status.skill_not_found);
pub const STATUS_INVALID_SKILL_ARGUMENTS: u32 = @intFromEnum(Status.invalid_skill_arguments);
pub const STATUS_SKILL_POLICY_VIOLATION: u32 = @intFromEnum(Status.skill_policy_violation);
pub const STATUS_SKILL_UNAVAILABLE: u32 = @intFromEnum(Status.skill_unavailable);
pub const STATUS_STALE_COMPACT: u32 = @intFromEnum(Status.stale_compact);
pub const STATUS_CHECKPOINT_BUDGET_REQUIRED: u32 = @intFromEnum(Status.checkpoint_budget_required);
pub const STATUS_CHECKPOINT_CORRUPT: u32 = @intFromEnum(Status.checkpoint_corrupt);
pub const STATUS_CHECKPOINT_UNSUPPORTED: u32 = @intFromEnum(Status.checkpoint_unsupported);
pub const STATUS_CHECKPOINT_INCOMPATIBLE: u32 = @intFromEnum(Status.checkpoint_incompatible);
pub const STATUS_CHECKPOINT_IO: u32 = @intFromEnum(Status.checkpoint_io);
pub const STATUS_LOGICAL_SESSION_CONFLICT: u32 = @intFromEnum(Status.logical_session_conflict);
pub const STATUS_MCP_NOT_REFRESHED: u32 = @intFromEnum(Status.mcp_not_refreshed);
pub const STATUS_INVALID_MCP_SELECTION: u32 = @intFromEnum(Status.invalid_mcp_selection);
pub const STATUS_COMPLETION_UNSUPPORTED_RESPONSE: u32 = @intFromEnum(Status.completion_unsupported_response);
pub const STATUS_SKILL_CATALOG_INCOMPLETE: u32 = @intFromEnum(Status.skill_catalog_incomplete);

pub const PROVIDER_ANTHROPIC: u32 = 1;
pub const PROVIDER_OPENAI: u32 = 2;
pub const PROVIDER_GEMINI: u32 = 3;

pub const PERMISSION_DEFAULT: u32 = 1;
pub const PERMISSION_ACCEPT_EDITS: u32 = 2;
pub const PERMISSION_AUTO: u32 = 3;
pub const PERMISSION_DONT_ASK: u32 = 4;
pub const PERMISSION_FULL_ACCESS: u32 = 5;

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
    checkpoint_budget_exhausted = 7,
    checkpoint_resource_limit = 8,

    pub fn fromCode(code: u32) error{UnknownStopReason}!StopReason {
        return switch (code) {
            @intFromEnum(StopReason.end_turn) => .end_turn,
            @intFromEnum(StopReason.max_turns) => .max_turns,
            @intFromEnum(StopReason.aborted) => .aborted,
            @intFromEnum(StopReason.tool_error) => .tool_error,
            @intFromEnum(StopReason.api_error) => .api_error,
            @intFromEnum(StopReason.tool_loop) => .tool_loop,
            @intFromEnum(StopReason.checkpoint_budget_exhausted) => .checkpoint_budget_exhausted,
            @intFromEnum(StopReason.checkpoint_resource_limit) => .checkpoint_resource_limit,
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
pub const STOP_CHECKPOINT_BUDGET_EXHAUSTED: u32 = @intFromEnum(StopReason.checkpoint_budget_exhausted);
pub const STOP_CHECKPOINT_RESOURCE_LIMIT: u32 = @intFromEnum(StopReason.checkpoint_resource_limit);

/// V1 resource limits guard allocation-amplifying Host inputs. They are part
/// of the public contract, not a claim that the same-process Host is untrusted.
pub const MAX_TOOL_COUNT_V1: u64 = 1024;
pub const MAX_TOOL_SCHEMA_BYTES_V1: u64 = 1024 * 1024;
pub const MAX_TOOL_SCHEMA_DEPTH_V1: u32 = 32;
pub const MAX_TOOL_SCHEMA_PROPERTIES_V1: u64 = 1024;
pub const MAX_UI_RESPONSE_BYTES_V1: u64 = 1024 * 1024;
pub const MAX_HOST_TOOL_RESULT_BYTES_V1: u64 = 16 * 1024 * 1024;
pub const MAX_HOST_STREAM_ARTIFACT_BYTES_V1: u64 = 128 * 1024 * 1024;
pub const MAX_MCP_TOOL_RESPONSE_BYTES_V1: u64 = 129 * 1024 * 1024;
pub const MAX_TOOL_ERROR_PAYLOAD_BYTES_V1: u64 = 1024 * 1024;
pub const MAX_SESSION_ID_BYTES_V1: u64 = 64;
pub const MAX_METADATA_STRING_BYTES_V1: u64 = 1024 * 1024;
pub const MAX_RUNTIME_METADATA_BYTES_V1: u64 = 16 * 1024 * 1024;
pub const MAX_SESSION_METADATA_BYTES_V1: u64 = 4 * 1024 * 1024;
pub const MAX_PROMPT_BYTES_V1: u64 = 16 * 1024 * 1024;
pub const MAX_SKILL_CATALOG_SKILLS_V1: u64 = 1024;
pub const MAX_SKILL_CATALOG_DESCRIPTOR_BYTES_V1: u64 = 4 * 1024 * 1024;
pub const MAX_SKILL_FILE_CONTENT_BYTES_V1: u64 = 16 * 1024 * 1024;
pub const MAX_SKILL_CONTENT_BYTES_V1: u64 = 32 * 1024 * 1024;
pub const MAX_SKILL_FILES_V1: u64 = 1024;
pub const MAX_SKILL_ENTRIES_V1: u64 = 4096;
pub const MAX_SKILL_DIRECTORY_DEPTH_V1: u64 = 64;
pub const MAX_SKILL_RELATIVE_PATH_BYTES_V1: u64 = 4096;
pub const MAX_SKILL_CATALOG_CONTENT_BYTES_V1: u64 = 64 * 1024 * 1024;
pub const MAX_SKILL_CATALOG_FILES_V1: u64 = 16384;
pub const MAX_SKILL_CATALOG_TRAVERSAL_ENTRIES_V1: u64 = 65536;
pub const MAX_SKILL_RUNTIME_RETAINED_SNAPSHOT_BYTES_V1: u64 = 256 * 1024 * 1024;
pub const MAX_SKILL_ARGUMENT_VALUES_V1: u64 = 64;
pub const MAX_SKILL_ARGUMENT_JSON_BYTES_V1: u64 = 1024 * 1024;
pub const MAX_PERMISSION_RULES_V1: u64 = 1024;
pub const MAX_PERMISSION_RULE_BYTES_V1: u64 = 64 * 1024;
pub const MAX_PERMISSION_RULE_TOTAL_BYTES_V1: u64 = 1024 * 1024;
pub const MAX_PERMISSION_ARGUMENT_JSON_BYTES_V1: u64 = 1024 * 1024;
pub const MAX_MCP_SERVERS_V1: u64 = 64;
pub const MAX_MCP_NAMESPACE_BYTES_V1: u64 = 24;
pub const MAX_MCP_CATALOG_ISSUES_V1: u64 = 4096;
pub const MAX_MCP_FRAME_BYTES_V1: u64 = 8 * 1024 * 1024;
pub const MAX_MCP_TOOLS_V1: u64 = 1024;
pub const MAX_MCP_TOOL_NAME_BYTES_V1: u64 = 256;
pub const MAX_MCP_TEXT_BYTES_V1: u64 = 64 * 1024;
pub const MAX_MCP_SCHEMA_BYTES_V1: u64 = 1024 * 1024;
pub const MAX_MCP_CURSOR_BYTES_V1: u64 = 16 * 1024;
pub const MAX_MCP_PROTOCOL_VERSIONS_V1: u64 = 16;
pub const MAX_CHECKPOINT_BYTES_V1: u64 = 1024 * 1024 * 1024;
pub const MAX_CHECKPOINT_CHUNK_BYTES_V1: u32 = 1024 * 1024;
pub const MAX_DESCRIPTION_JSON_BYTES_V1: u64 = 16 * 1024 * 1024;
pub const MAX_COMPLETION_CONFIG_BYTES_V1: u64 = 1024 * 1024;
pub const MAX_COMPLETION_MESSAGES_V1: u64 = 4096;
pub const MAX_COMPLETION_REQUEST_BYTES_V1: u64 = 16 * 1024 * 1024;
pub const MAX_COMPLETION_RESULT_BYTES_V1: u64 = 16 * 1024 * 1024;
pub const MAX_SKILL_SOURCES_V1: u64 = 64;
pub const MAX_SKILL_SOURCE_ID_BYTES_V1: u64 = 128;
pub const MAX_PROCESS_PLUGIN_SOURCES_V1: u64 = 64;
pub const MAX_TURNS_V1: u32 = 1000;

pub const PLUGIN_LAYER_BUILTIN: u32 = 1;
pub const PLUGIN_LAYER_PERSONAL: u32 = 2;
pub const PLUGIN_LAYER_PROJECT: u32 = 3;
pub const PLUGIN_LAYER_SESSION: u32 = 4;
pub const PLUGIN_LAYER_MANAGED: u32 = 5;

pub const RUN_INPUT_TEXT: u32 = 1;
pub const RUN_INPUT_SKILL: u32 = 2;

pub const SKILL_SOURCE_USER: u32 = 1;
pub const SKILL_SOURCE_WORKSPACE: u32 = 2;

pub const COMPACT_COMPACTED: u32 = 1;
pub const COMPACT_NO_CHANGE: u32 = 2;
pub const COMPACT_DEGRADED: u32 = 3;
pub const COMPACT_ABORTED: u32 = 4;

pub const RUN_CHECKPOINT_NONE: u32 = 0;
pub const RUN_CHECKPOINT_BUDGET_REQUIRED: u32 = 1;
pub const RUN_CHECKPOINT_BUDGET_EXHAUSTED: u32 = 2;
pub const RUN_CHECKPOINT_RESOURCE_LIMIT: u32 = 3;
pub const RUN_RESULT_COMPACTION_RECOMMENDED: u32 = 1 << 0;

pub const COMPLETION_ROLE_USER: u32 = 1;
pub const COMPLETION_ROLE_ASSISTANT: u32 = 2;

pub const CompletionStopReason = enum(u32) {
    unknown = 0,
    end_turn = 1,
    max_tokens = 2,
    stop_sequence = 3,
    pause_turn = 4,
    refusal = 5,
    aborted = 6,

    pub fn fromCode(code: u32) error{UnknownCompletionStopReason}!CompletionStopReason {
        return switch (code) {
            0 => .unknown,
            1 => .end_turn,
            2 => .max_tokens,
            3 => .stop_sequence,
            4 => .pause_turn,
            5 => .refusal,
            6 => .aborted,
            else => error.UnknownCompletionStopReason,
        };
    }
};

pub const COMPLETION_STOP_UNKNOWN: u32 = @intFromEnum(CompletionStopReason.unknown);
pub const COMPLETION_STOP_END_TURN: u32 = @intFromEnum(CompletionStopReason.end_turn);
pub const COMPLETION_STOP_MAX_TOKENS: u32 = @intFromEnum(CompletionStopReason.max_tokens);
pub const COMPLETION_STOP_STOP_SEQUENCE: u32 = @intFromEnum(CompletionStopReason.stop_sequence);
pub const COMPLETION_STOP_PAUSE_TURN: u32 = @intFromEnum(CompletionStopReason.pause_turn);
pub const COMPLETION_STOP_REFUSAL: u32 = @intFromEnum(CompletionStopReason.refusal);
pub const COMPLETION_STOP_ABORTED: u32 = @intFromEnum(CompletionStopReason.aborted);

pub const CompletionEventKind = enum(u32) {
    text = 1,
    thinking = 2,
    usage = 3,
    done = 4,
};

pub const COMPLETION_EVENT_TEXT: u32 = @intFromEnum(CompletionEventKind.text);
pub const COMPLETION_EVENT_THINKING: u32 = @intFromEnum(CompletionEventKind.thinking);
pub const COMPLETION_EVENT_USAGE: u32 = @intFromEnum(CompletionEventKind.usage);
pub const COMPLETION_EVENT_DONE: u32 = @intFromEnum(CompletionEventKind.done);

pub const MCP_TRANSPORT_STDIO: u32 = 1;
pub const MCP_TRANSPORT_STREAMABLE_HTTP: u32 = 2;
pub const MCP_NEGOTIATION_AUTO: u32 = 1;
pub const MCP_NEGOTIATION_MODERN_ONLY: u32 = 2;
pub const MCP_NEGOTIATION_LEGACY_ONLY: u32 = 3;
pub const MCP_NEGOTIATION_LEGACY_2025_06_ONLY: u32 = 4;
pub const MCP_ERA_2026_07_28: u32 = 1;
pub const MCP_ERA_2025_11_25: u32 = 2;
pub const MCP_ERA_2025_06_18: u32 = 3;
pub const MCP_APPLY_APPLIED: u32 = 1;
pub const MCP_APPLY_SUPERSEDED: u32 = 2;
pub const MCP_APPLY_REJECTED: u32 = 3;
pub const MCP_CONNECTION_DISPOSABLE_PROBE: u32 = 1;
pub const MCP_CONNECTION_ACTUAL: u32 = 2;
pub const MCP_OPEN_OK: u32 = 0;
pub const MCP_OPEN_TIMEOUT: u32 = 1;
pub const MCP_OPEN_NETWORK_ERROR: u32 = 2;
pub const MCP_OPEN_AUTH_ERROR: u32 = 3;
pub const MCP_OPEN_SERVER_ERROR: u32 = 4;
pub const MCP_OPEN_CHILD_EXIT: u32 = 5;
pub const MCP_OPEN_FATAL: u32 = 6;
pub const MCP_EXCHANGE_RESPONSE: u32 = 0;
pub const MCP_EXCHANGE_TIMEOUT: u32 = 1;
pub const MCP_EXCHANGE_NETWORK_ERROR: u32 = 2;
pub const MCP_EXCHANGE_AUTH_ERROR: u32 = 3;
pub const MCP_EXCHANGE_SERVER_ERROR: u32 = 4;
pub const MCP_EXCHANGE_CHILD_EXIT: u32 = 5;
pub const MCP_EXCHANGE_CANCELLED: u32 = 6;
pub const MCP_EXCHANGE_INDETERMINATE: u32 = 7;
pub const MCP_EXCHANGE_FATAL: u32 = 8;
pub const MCP_NOTIFY_OK: u32 = 0;
pub const MCP_NOTIFY_TIMEOUT: u32 = 1;
pub const MCP_NOTIFY_NETWORK_ERROR: u32 = 2;
pub const MCP_NOTIFY_AUTH_ERROR: u32 = 3;
pub const MCP_NOTIFY_SERVER_ERROR: u32 = 4;
pub const MCP_NOTIFY_CHILD_EXIT: u32 = 5;
pub const MCP_NOTIFY_CANCELLED: u32 = 6;
pub const MCP_NOTIFY_FATAL: u32 = 7;

pub const CHECKPOINT_IO_OK: u32 = 0;
pub const CHECKPOINT_IO_FAILED: u32 = 1;
pub const CHECKPOINT_IO_FATAL: u32 = 2;

pub const EVENT_CONTINUE: u32 = 0;
pub const EVENT_FATAL: u32 = 1;
pub const UI_ANSWERED: u32 = 0;
pub const UI_UNAVAILABLE: u32 = 1;
pub const UI_FATAL: u32 = 2;
pub const UI_CANCELLED: u32 = 3;
pub const HOST_OK: u32 = 0;
pub const HOST_FAILED: u32 = 1;
pub const HOST_REJECTED: u32 = 2;
pub const HOST_FATAL: u32 = 3;
pub const HOST_STREAM_MEDIA_TEXT_UTF8: u32 = 1;
pub const HOST_STREAM_MEDIA_JSON: u32 = 2;
pub const HOST_STREAM_MEDIA_BINARY: u32 = 3;
pub const HOST_SINK_OK: u32 = 0;
pub const HOST_SINK_ABORTED: u32 = 1;
pub const HOST_SINK_TOO_LARGE: u32 = 2;
pub const HOST_SINK_FAILED: u32 = 3;
pub const HOST_SINK_CLOSED: u32 = 4;

pub const CAP_RUNTIME: u64 = 1 << 0;
pub const CAP_BUILTIN_TOOLS: u64 = 1 << 1;
pub const CAP_HOST_SYNC_TOOLS: u64 = 1 << 2;
pub const CAP_HOST_UI: u64 = 1 << 3;
pub const CAP_CORE_EVENTS_JSON: u64 = 1 << 4;
pub const CAP_ABORT: u64 = 1 << 5;
pub const CAP_SKILL_CATALOG: u64 = 1 << 6;
pub const CAP_TYPED_RUN_INPUT: u64 = 1 << 7;
pub const CAP_SESSION_MODEL_MUTATION: u64 = 1 << 8;
pub const CAP_MANUAL_COMPACT: u64 = 1 << 9;
pub const CAP_SKILL_POLICY: u64 = 1 << 10;
pub const CAP_HOST_PERMISSION_RULES: u64 = 1 << 11;
pub const CAP_SESSION_CHECKPOINT: u64 = 1 << 12;
pub const CAP_SESSION_RESTORE: u64 = 1 << 13;
pub const CAP_SESSION_DESCRIBE: u64 = 1 << 14;
pub const CAP_MCP_RUNTIME_CATALOG: u64 = 1 << 15;
pub const CAP_MCP_SESSION_SELECTION: u64 = 1 << 16;
pub const CAP_DURABLE_BUDGET: u64 = 1 << 17;
pub const CAP_SESSION_PERMISSION_AUTHORITY: u64 = 1 << 18;
pub const CAP_RUN_STATE_OBSERVATION: u64 = 1 << 19;
pub const CAP_WORKSPACE_SKILL_CATALOG: u64 = 1 << 20;
pub const CAP_TEXT_COMPLETION: u64 = 1 << 21;
pub const CAP_PROCESS_PLUGIN_TOOLS: u64 = 1 << 22;
pub const CAP_HOST_STREAM_TOOLS: u64 = 1 << 23;
pub const CAP_MCP_TOOL_STREAM: u64 = 1 << 24;
pub const REQUIRED_CAPABILITIES_V1: u64 = CAP_RUNTIME | CAP_BUILTIN_TOOLS | CAP_HOST_SYNC_TOOLS | CAP_HOST_UI | CAP_CORE_EVENTS_JSON | CAP_ABORT | CAP_SKILL_CATALOG | CAP_TYPED_RUN_INPUT | CAP_SESSION_MODEL_MUTATION | CAP_MANUAL_COMPACT | CAP_SKILL_POLICY | CAP_HOST_PERMISSION_RULES | CAP_SESSION_CHECKPOINT | CAP_SESSION_RESTORE | CAP_SESSION_DESCRIBE | CAP_MCP_RUNTIME_CATALOG | CAP_MCP_SESSION_SELECTION | CAP_DURABLE_BUDGET | CAP_SESSION_PERMISSION_AUTHORITY | CAP_RUN_STATE_OBSERVATION | CAP_WORKSPACE_SKILL_CATALOG | CAP_TEXT_COMPLETION | CAP_PROCESS_PLUGIN_TOOLS | CAP_HOST_STREAM_TOOLS | CAP_MCP_TOOL_STREAM;

/// Each published v1 revision is rigid: every struct_size is exact and every
/// reserved field is zero. A Host pins version, revision, table size, and
/// capabilities together; revisions may intentionally be breaking while v1
/// remains experimental.
pub const RuntimeHandle = opaque {};
pub const SessionHandle = opaque {};
pub const SkillCatalogHandle = opaque {};
pub const CompletionHandle = opaque {};
pub const CompletionStreamHandle = opaque {};

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

/// Borrowed write-only sink for one synchronous Host stream callback. The
/// callback must not retain it. AgentCore alone commits or discards the CAS
/// object after the callback returns.
pub const HostResultWriteFnV1 = *const fn (
    sink_ctx: ?*anyopaque,
    bytes: BytesViewV1,
) callconv(.c) u32;

pub const HostResultSinkV1 = extern struct {
    struct_size: u32,
    reserved0: u32,
    ctx: ?*anyopaque,
    write: ?HostResultWriteFnV1,
    max_bytes: u64,
    reserved: [3]u64,
};

/// HOST_OK requires a valid media code and canonical-empty detail. FAILED and
/// REJECTED require media code zero and may return bounded UTF-8 detail through
/// the paired release callback. Partial sink bytes never become visible on a
/// non-OK outcome.
pub const HostStreamExecuteFnV1 = *const fn (
    host_ctx: ?*anyopaque,
    run: ?*const RunContextV1,
    arguments_json: BytesViewV1,
    sink: ?*const HostResultSinkV1,
    out_media_code: ?*u32,
    out_detail: ?*OwnedBytesV1,
) callconv(.c) u32;

pub const HostStreamToolV1 = extern struct {
    struct_size: u32,
    reserved0: u32,
    ctx: ?*anyopaque,
    name: BytesViewV1,
    description: BytesViewV1,
    input_schema_json: BytesViewV1,
    execute_stream: ?HostStreamExecuteFnV1,
    release_detail: ?HostReleaseFnV1,
    reserved: [2]u64,
};

/// MCP transport callbacks are Host-owned. AgentCore passes only borrowed
/// request bytes and copies every successful response before the callback
/// returns. A successful open produces one opaque connection context that is
/// permanently bound to its purpose and requested exact era; its close
/// callback is invoked exactly once. For Streamable HTTP, the Host must attach
/// that era as `MCP-Protocol-Version` after initialization and retain any
/// `MCP-Session-Id` in this connection context. Probe, actual, and reopened
/// exact-era connections must not share session identifiers or mutable
/// protocol state. Credentials and transport handles never enter AgentCore
/// checkpoints.
pub const McpIsCancelledFnV1 = *const fn (
    cancellation_ctx: ?*const anyopaque,
) callconv(.c) u32;

pub const McpCancellationV1 = extern struct {
    struct_size: u32,
    reserved0: u32,
    ctx: ?*const anyopaque,
    is_cancelled: ?McpIsCancelledFnV1,
    reserved: [2]u64,
};

pub const McpOpenFnV1 = *const fn (
    connector_ctx: ?*anyopaque,
    purpose_code: u32,
    requested_era_code: u32,
    timeout_ms: u32,
    out_connection_ctx: ?*?*anyopaque,
) callconv(.c) u32;
pub const McpRequestFnV1 = *const fn (
    connector_ctx: ?*anyopaque,
    connection_ctx: ?*anyopaque,
    request_json: BytesViewV1,
    timeout_ms: u32,
    cancellation: ?*const McpCancellationV1,
    out_response_json: ?*OwnedBytesV1,
) callconv(.c) u32;
/// Streaming `tools/call` exchange. The sink is borrowed for the duration of
/// this callback and must receive the complete JSON-RPC response frame from
/// byte zero. Returning MCP_EXCHANGE_RESPONSE authorizes AgentCore to seal and
/// validate the capture; every other status rolls it back.
pub const McpRequestToolStreamFnV1 = *const fn (
    connector_ctx: ?*anyopaque,
    connection_ctx: ?*anyopaque,
    request_json: BytesViewV1,
    timeout_ms: u32,
    cancellation: ?*const McpCancellationV1,
    response_sink: ?*const HostResultSinkV1,
) callconv(.c) u32;
pub const McpNotifyFnV1 = *const fn (
    connector_ctx: ?*anyopaque,
    connection_ctx: ?*anyopaque,
    notification_json: BytesViewV1,
    timeout_ms: u32,
    cancellation: ?*const McpCancellationV1,
) callconv(.c) u32;
pub const McpCloseFnV1 = *const fn (
    connector_ctx: ?*anyopaque,
    connection_ctx: ?*anyopaque,
) callconv(.c) void;
pub const McpReleaseResponseFnV1 = *const fn (
    connector_ctx: ?*anyopaque,
    connection_ctx: ?*anyopaque,
    response_json: ?*OwnedBytesV1,
) callconv(.c) void;
/// AgentCore retains the opaque connector context before an operation returns
/// and releases it after every configured definition and live connection has
/// stopped using it. Both callbacks are mandatory and must be thread-safe.
pub const McpRetainConnectorFnV1 = *const fn (connector_ctx: ?*anyopaque) callconv(.c) void;
pub const McpReleaseConnectorFnV1 = *const fn (connector_ctx: ?*anyopaque) callconv(.c) void;

pub const McpConnectorV1 = extern struct {
    struct_size: u32,
    reserved0: u32,
    ctx: ?*anyopaque,
    open: ?McpOpenFnV1,
    request: ?McpRequestFnV1,
    request_tool_stream: ?McpRequestToolStreamFnV1,
    notify: ?McpNotifyFnV1,
    close: ?McpCloseFnV1,
    release_response: ?McpReleaseResponseFnV1,
    retain_connector: ?McpRetainConnectorFnV1,
    release_connector: ?McpReleaseConnectorFnV1,
    reserved: [1]u64,
};

pub const McpProtocolLimitsV1 = extern struct {
    struct_size: u32,
    reserved0: u32,
    max_frame_bytes: u64,
    max_tools: u64,
    max_tool_name_bytes: u64,
    max_text_bytes: u64,
    max_schema_bytes: u64,
    max_json_depth: u64,
    max_json_nodes: u64,
    max_cursor_bytes: u64,
    max_versions: u64,
    reserved: [2]u64,
};

pub const McpServerV1 = extern struct {
    struct_size: u32,
    transport_code: u32,
    negotiation_policy_code: u32,
    reserved0: u32,
    server_binding_identity: [32]u8,
    namespace: BytesViewV1,
    client_name: BytesViewV1,
    client_version: BytesViewV1,
    timeout_ms: u32,
    reserved1: u32,
    connector: McpConnectorV1,
    protocol_limits: ?*const McpProtocolLimitsV1,
    /// Stable, non-secret identity of every connection-relevant input. A
    /// changed value replaces the ServerInstance; secret bytes and
    /// secret-derived digests must never be supplied here. The value must not
    /// be all zero.
    configuration_fingerprint: [32]u8,
};

/// One complete desired MCP server set. Apply is declarative: omitted servers
/// are removed, and `desired_revision` is non-zero and monotonic per Runtime.
pub const McpConfigurationV1 = extern struct {
    struct_size: u32,
    reserved0: u32,
    desired_revision: u64,
    servers: ?[*]const McpServerV1,
    server_count: u64,
    reserved: [4]u64,
};

pub const McpApplyReportV1 = extern struct {
    struct_size: u32,
    disposition_code: u32,
    desired_revision: u64,
    active_revision: u64,
    catalog_generation: u64,
    reserved: [4]u64,
};

pub const McpCatalogLimitsV1 = extern struct {
    struct_size: u32,
    reserved0: u32,
    max_servers: u64,
    max_namespace_bytes: u64,
    max_issues: u64,
    reserved: [4]u64,
};

pub const RuntimeConfigV1 = extern struct {
    struct_size: u32,
    reserved0: u32,
    builtin_tools: ?[*]const BytesViewV1,
    builtin_tool_count: u64,
    host_tools: ?[*]const HostToolV1,
    host_tool_count: u64,
    mcp_servers: ?[*]const McpServerV1,
    mcp_server_count: u64,
    mcp_catalog_limits: ?*const McpCatalogLimitsV1,
    reserved: [4]u64,
};

/// Explicit executable authority supplied by the embedding Host. `root` is an
/// absolute package directory containing the strict plugin/process manifests;
/// AgentCore copies all retained state before the create call returns.
pub const ProcessPluginSourceV1 = extern struct {
    struct_size: u32,
    layer_code: u32,
    root: BytesViewV1,
    reserved: [3]u64,
};

/// Optional executable contribution set for `runtime_create_with_plugins`.
/// RuntimeConfigV1 remains byte-for-byte unchanged so executable authority
/// cannot be smuggled through a field that revision 9 required to be zero.
pub const RuntimePluginConfigV1 = extern struct {
    struct_size: u32,
    reserved0: u32,
    process_plugins: ?[*]const ProcessPluginSourceV1,
    process_plugin_count: u64,
    host_stream_tools: ?[*]const HostStreamToolV1,
    host_stream_tool_count: u64,
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

/// Complete default-deny authorization policy for one exact Catalog. Every
/// listed ID is a concrete source+content `skill_id` from that Catalog. The
/// list is borrowed for the synchronous call and must be unique.
pub const SkillPolicyV1 = extern struct {
    struct_size: u32,
    reserved0: u32,
    granted_skill_ids: ?[*]const BytesViewV1,
    granted_skill_id_count: u64,
    reserved: [4]u64,
};

/// Borrowed canonical Tool(specifier) rules. AgentCore validates, copies, and
/// compiles the complete replacement before publishing it.
pub const PermissionRuleSetV1 = extern struct {
    struct_size: u32,
    reserved0: u32,
    allow: ?[*]const BytesViewV1,
    allow_count: u64,
    ask: ?[*]const BytesViewV1,
    ask_count: u64,
    deny: ?[*]const BytesViewV1,
    deny_count: u64,
    reserved: [4]u64,
};

pub const McpSelectorV1 = extern struct {
    struct_size: u32,
    reserved0: u32,
    server_binding_identity: [32]u8,
    tool_name: BytesViewV1,
    reserved: [3]u64,
};

/// A complete replacement for one Session's MCP authority view. Null in a
/// create config means an empty view. During restore this is the current Host
/// ceiling and is intersected with the historical checkpoint selection; a
/// wider current list can never add authority absent from the checkpoint.
pub const McpSelectionV1 = extern struct {
    struct_size: u32,
    reserved0: u32,
    selectors: ?[*]const McpSelectorV1,
    selector_count: u64,
    reserved: [4]u64,
};

pub const DurableBudgetProfileV1 = extern struct {
    struct_size: u32,
    reserved0: u32,
    hard_bytes: u64,
    soft_bytes: u64,
    input_cap_bytes: u64,
    provider_request_cap_bytes: u64,
    provider_result_cap_bytes: u64,
    tool_result_cap_bytes: u64,
    mcp_result_cap_bytes: u64,
    audit_reserve_bytes: u64,
    terminal_reserve_bytes: u64,
    reserved: [4]u64,
};

/// Current Host-owned authority and ephemeral execution configuration shared
/// by fresh creation and restore. No logical Session identity is accepted from
/// the Host. All borrowed data is copied during the synchronous call.
pub const SessionHostConfigV1 = extern struct {
    struct_size: u32,
    provider_kind_code: u32,
    permission_mode_code: u32,
    shell_policy_code: u32,
    api_key: BytesViewV1,
    base_url: BytesViewV1,
    workspace_root: BytesViewV1,
    workspace_home: BytesViewV1,
    allowed_tools: ?[*]const BytesViewV1,
    allowed_tool_count: u64,
    skill_catalog: ?*SkillCatalogHandle,
    skill_policy: ?*const SkillPolicyV1,
    permission_rules: ?*const PermissionRuleSetV1,
    mcp_selection: ?*const McpSelectionV1,
    durable_budget: ?*const DurableBudgetProfileV1,
    reserved: [4]u64,
};

pub const SessionCreateConfigV1 = extern struct {
    struct_size: u32,
    reserved0: u32,
    host: ?*const SessionHostConfigV1,
    model: BytesViewV1,
    reserved: [4]u64,
};

/// One additional directory using the canonical Agent Skill format. Registering
/// a path does not install a `.claude`/`.codex` format adapter.
pub const SkillSourceV1 = extern struct {
    struct_size: u32,
    scope_code: u32,
    root: BytesViewV1,
    source_instance_id: BytesViewV1,
    reserved: [3]u64,
};

/// Resolves the complete effective Catalog for one Workspace authority.
/// Default discovery is limited to user/workspace `.agents/skills`; optional
/// sources add directories in the same canonical format. `reserved0` is zero.
pub const SkillCatalogQueryV1 = extern struct {
    struct_size: u32,
    reserved0: u32,
    workspace_root: BytesViewV1,
    workspace_home: BytesViewV1,
    workspace_epoch: BytesViewV1,
    additional_sources: ?[*]const SkillSourceV1,
    additional_source_count: u64,
    reserved: [1]u64,
};

pub const CompletionConfigV1 = extern struct {
    struct_size: u32,
    provider_kind_code: u32,
    api_key: BytesViewV1,
    base_url: BytesViewV1,
    model: BytesViewV1,
    reserved: [4]u64,
};

pub const CompletionMessageV1 = extern struct {
    struct_size: u32,
    role_code: u32,
    text: BytesViewV1,
    reserved: [2]u64,
};

pub const CompletionRequestV1 = extern struct {
    struct_size: u32,
    reserved0: u32,
    messages: ?[*]const CompletionMessageV1,
    message_count: u64,
    system: BytesViewV1,
    reserved: [4]u64,
};

pub const CompletionResultV1 = extern struct {
    struct_size: u32,
    stop_reason_code: u32,
    text: OwnedBytesV1,
    input_tokens: u64,
    output_tokens: u64,
    cache_read_input_tokens: u64,
    cache_creation_input_tokens: u64,
    reserved: [2]u64,
};

pub const CompletionInfoV1 = extern struct {
    struct_size: u32,
    provider_kind_code: u32,
    model: OwnedBytesV1,
    reserved: [3]u64,
};

pub const CompletionEventV1 = extern struct {
    struct_size: u32,
    kind_code: u32,
    payload: OwnedBytesV1,
    input_tokens: u64,
    output_tokens: u64,
    cache_read_input_tokens: u64,
    cache_creation_input_tokens: u64,
    stop_reason_code: u32,
    reserved0: u32,
    reserved: [2]u64,
};

pub const RunInputV1 = extern struct {
    struct_size: u32,
    kind_code: u32,
    text: BytesViewV1,
    skill_id: BytesViewV1,
    catalog_revision: BytesViewV1,
    arguments_json: BytesViewV1,
    reserved: [4]u64,
};

pub const RunOptionsV1 = extern struct {
    struct_size: u32,
    max_turns: u32,
    reserved: [4]u64,
};

/// Terminal Run summary. All fields are defined on STATUS_OK. On
/// STATUS_CHECKPOINT_BUDGET_REQUIRED, only struct_size,
/// checkpoint_outcome_code, result_flags, durable_usage_bytes and
/// required_checkpoint_bytes are defined; the Run was not admitted and its ID
/// remains reusable. Fields are unspecified on every other status.
pub const RunResultV1 = extern struct {
    struct_size: u32,
    stop_reason_code: u32,
    turns: u32,
    tool_calls: u32,
    checkpoint_outcome_code: u32,
    result_flags: u32,
    durable_usage_bytes: u64,
    required_checkpoint_bytes: u64,
    reserved: [4]u64,
};

/// Terminal manual-compact summary. Fields are defined only when
/// `session_compact` returns STATUS_OK. The before/after values are context-size
/// estimates, not provider billing values; the four usage fields are separate
/// provider usage deltas.
pub const CompactResultV1 = extern struct {
    struct_size: u32,
    outcome_code: u32,
    before_context_tokens: u64,
    after_context_tokens: u64,
    input_tokens: u64,
    output_tokens: u64,
    cache_read_input_tokens: u64,
    cache_creation_input_tokens: u64,
    reserved: [4]u64,
};

pub const CheckpointLimitsV1 = extern struct {
    struct_size: u32,
    reserved0: u32,
    hard_bytes: u64,
    max_section_bytes: u64,
    max_string_bytes: u64,
    max_messages: u64,
    max_blocks_per_message: u64,
    chunk_bytes: u32,
    reserved1: u32,
    reserved: [4]u64,
};

pub const CheckpointWriteFnV1 = *const fn (
    sink_ctx: ?*anyopaque,
    chunk: BytesViewV1,
) callconv(.c) u32;
pub const CheckpointSinkV1 = extern struct {
    struct_size: u32,
    reserved0: u32,
    ctx: ?*anyopaque,
    write: ?CheckpointWriteFnV1,
    reserved: [4]u64,
};

pub const CheckpointReadFnV1 = *const fn (
    source_ctx: ?*anyopaque,
    destination: ?[*]u8,
    capacity: u64,
    out_len: ?*u64,
) callconv(.c) u32;
pub const CheckpointSourceV1 = extern struct {
    struct_size: u32,
    reserved0: u32,
    ctx: ?*anyopaque,
    read: ?CheckpointReadFnV1,
    reserved: [4]u64,
};

pub const CheckpointExportConfigV1 = extern struct {
    struct_size: u32,
    reserved0: u32,
    limits: ?*const CheckpointLimitsV1,
    sink: ?*const CheckpointSinkV1,
    reserved: [4]u64,
};

pub const CheckpointExportResultV1 = extern struct {
    struct_size: u32,
    reserved0: u32,
    checkpoint_generation: u64,
    total_bytes: u64,
    chunk_count: u64,
    digest: [32]u8,
    reserved: [4]u64,
};

pub const SessionRestoreConfigV1 = extern struct {
    struct_size: u32,
    reserved0: u32,
    host: ?*const SessionHostConfigV1,
    source: ?*const CheckpointSourceV1,
    limits: ?*const CheckpointLimitsV1,
    reserved: [4]u64,
};

/// The final OwnedBytesV1 pointer on each AgentCore operation is an optional,
/// write-only diagnostic output. Release a prior diagnostic before reusing
/// its variable. Diagnostic allocation is best-effort and never changes the
/// operation's primary status. Text is human-readable, non-normative, and
/// unstable; consumers must not parse it or branch on its wording.
pub const RuntimeCreateFnV1 = *const fn (?*const RuntimeConfigV1, ?*?*RuntimeHandle, ?*OwnedBytesV1) callconv(.c) u32;
pub const RuntimeCreateWithPluginsFnV1 = *const fn (
    config: ?*const RuntimeConfigV1,
    plugins: ?*const RuntimePluginConfigV1,
    out_runtime: ?*?*RuntimeHandle,
    out_diagnostic: ?*OwnedBytesV1,
) callconv(.c) u32;
pub const RuntimeDestroyFnV1 = *const fn (?*RuntimeHandle, ?*OwnedBytesV1) callconv(.c) u32;
pub const RuntimeQuerySkillCatalogFnV1 = *const fn (
    runtime: ?*RuntimeHandle,
    query: ?*const SkillCatalogQueryV1,
    out_catalog: ?*?*SkillCatalogHandle,
    out_descriptor_json: ?*OwnedBytesV1,
    out_diagnostic: ?*OwnedBytesV1,
) callconv(.c) u32;
pub const SkillCatalogReleaseFnV1 = *const fn (?*SkillCatalogHandle, ?*OwnedBytesV1) callconv(.c) u32;
pub const CompletionCreateFnV1 = *const fn (
    config: ?*const CompletionConfigV1,
    out_completion: ?*?*CompletionHandle,
    out_diagnostic: ?*OwnedBytesV1,
) callconv(.c) u32;
pub const CompletionDestroyFnV1 = *const fn (
    completion: ?*CompletionHandle,
    out_diagnostic: ?*OwnedBytesV1,
) callconv(.c) u32;
pub const CompletionDescribeFnV1 = *const fn (
    completion: ?*CompletionHandle,
    out_info: ?*CompletionInfoV1,
    out_diagnostic: ?*OwnedBytesV1,
) callconv(.c) u32;
pub const CompletionCompleteFnV1 = *const fn (
    completion: ?*CompletionHandle,
    request: ?*const CompletionRequestV1,
    out_result: ?*CompletionResultV1,
    out_diagnostic: ?*OwnedBytesV1,
) callconv(.c) u32;
pub const CompletionStreamStartFnV1 = *const fn (
    completion: ?*CompletionHandle,
    request: ?*const CompletionRequestV1,
    out_stream: ?*?*CompletionStreamHandle,
    out_diagnostic: ?*OwnedBytesV1,
) callconv(.c) u32;
pub const CompletionStreamNextFnV1 = *const fn (
    stream: ?*CompletionStreamHandle,
    out_event: ?*CompletionEventV1,
    out_diagnostic: ?*OwnedBytesV1,
) callconv(.c) u32;
pub const CompletionStreamAbortFnV1 = *const fn (
    stream: ?*CompletionStreamHandle,
    reason_code: u32,
    out_diagnostic: ?*OwnedBytesV1,
) callconv(.c) u32;
pub const CompletionStreamDestroyFnV1 = *const fn (
    stream: ?*CompletionStreamHandle,
    out_diagnostic: ?*OwnedBytesV1,
) callconv(.c) u32;
pub const RuntimeRefreshMcpFnV1 = *const fn (
    runtime: ?*RuntimeHandle,
    out_catalog_generation: ?*u64,
    out_diagnostic: ?*OwnedBytesV1,
) callconv(.c) u32;
pub const RuntimeDescribeMcpFnV1 = *const fn (
    runtime: ?*RuntimeHandle,
    out_description_json: ?*OwnedBytesV1,
    out_diagnostic: ?*OwnedBytesV1,
) callconv(.c) u32;
pub const RuntimeApplyMcpConfigurationFnV1 = *const fn (
    runtime: ?*RuntimeHandle,
    configuration: ?*const McpConfigurationV1,
    out_report: ?*McpApplyReportV1,
    out_diagnostic: ?*OwnedBytesV1,
) callconv(.c) u32;
pub const SessionCreateFnV1 = *const fn (?*RuntimeHandle, ?*const SessionCreateConfigV1, ?*const SessionCallbacksV1, ?*?*SessionHandle, ?*OwnedBytesV1) callconv(.c) u32;
pub const SessionRestoreFnV1 = *const fn (
    runtime: ?*RuntimeHandle,
    config: ?*const SessionRestoreConfigV1,
    callbacks: ?*const SessionCallbacksV1,
    out_session: ?*?*SessionHandle,
    out_restore_report_json: ?*OwnedBytesV1,
    out_diagnostic: ?*OwnedBytesV1,
) callconv(.c) u32;
/// Wait for every Session abort call to return before any subsequent call on
/// the same handle, including destroy. STATUS_OK invalidates the handle; any
/// later call with that pointer is invalid.
pub const SessionDestroyFnV1 = *const fn (?*SessionHandle, ?*OwnedBytesV1) callconv(.c) u32;
pub const SessionDescribeFnV1 = *const fn (
    session: ?*SessionHandle,
    out_description_json: ?*OwnedBytesV1,
    out_diagnostic: ?*OwnedBytesV1,
) callconv(.c) u32;
pub const SessionSetModelFnV1 = *const fn (?*SessionHandle, BytesViewV1, ?*OwnedBytesV1) callconv(.c) u32;
pub const SessionBindSkillsFnV1 = *const fn (
    session: ?*SessionHandle,
    optional_catalog: ?*SkillCatalogHandle,
    policy: ?*const SkillPolicyV1,
    out_diagnostic: ?*OwnedBytesV1,
) callconv(.c) u32;
pub const SessionUpdatePermissionRulesFnV1 = *const fn (
    session: ?*SessionHandle,
    rules: ?*const PermissionRuleSetV1,
    out_diagnostic: ?*OwnedBytesV1,
) callconv(.c) u32;
pub const SessionUpdateMcpFnV1 = *const fn (
    session: ?*SessionHandle,
    selection: ?*const McpSelectionV1,
    out_diagnostic: ?*OwnedBytesV1,
) callconv(.c) u32;
/// Pre-admission validation, resource-limit, busy, and stale-run failures do
/// not consume `run_id`. Post-admission Skill materialization failure consumes
/// it but leaves the Session reusable after cleanup. Once Conversation or
/// execution begins, OOM/core/callback/internal failure poisons the Session;
/// successful completion, including STOP_ABORTED, returns it idle.
/// Given a valid handle, poisoned state precedes remaining argument validation.
/// V1 cannot recover or import Conversation/history into a poisoned Session.
/// `run_id` is Host-assigned, non-zero, and scoped to one Session. Each
/// admitted Run must use a value strictly greater than the Session's previous
/// admitted value. Pre-admission rejection never advances that value, so an
/// otherwise valid greater ID remains available for retry; zero and stale IDs
/// do not. After admitting `maxInt(u64)`, the Host must create a new Session.
pub const SessionRunInputFnV1 = *const fn (
    session: ?*SessionHandle,
    run_id: u64,
    input: ?*const RunInputV1,
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
/// Runs the canonical default best-effort compact policy. Revision 12 accepts
/// no target token budget and does not guarantee fit for a model context.
pub const SessionCompactFnV1 = *const fn (
    session: ?*SessionHandle,
    operation_id: u64,
    out_result: ?*CompactResultV1,
    out_diagnostic: ?*OwnedBytesV1,
) callconv(.c) u32;
pub const SessionAbortCompactFnV1 = *const fn (
    session: ?*SessionHandle,
    operation_id: u64,
    out_diagnostic: ?*OwnedBytesV1,
) callconv(.c) u32;
pub const SessionExportCheckpointFnV1 = *const fn (
    session: ?*SessionHandle,
    config: ?*const CheckpointExportConfigV1,
    out_result: ?*CheckpointExportResultV1,
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
    runtime_query_skill_catalog: ?RuntimeQuerySkillCatalogFnV1,
    skill_catalog_release: ?SkillCatalogReleaseFnV1,
    runtime_refresh_mcp: ?RuntimeRefreshMcpFnV1,
    runtime_describe_mcp: ?RuntimeDescribeMcpFnV1,
    session_create: ?SessionCreateFnV1,
    session_restore: ?SessionRestoreFnV1,
    session_destroy: ?SessionDestroyFnV1,
    session_describe: ?SessionDescribeFnV1,
    session_set_model: ?SessionSetModelFnV1,
    session_update_skills: ?SessionBindSkillsFnV1,
    session_update_permission_rules: ?SessionUpdatePermissionRulesFnV1,
    session_update_mcp: ?SessionUpdateMcpFnV1,
    session_run_input: ?SessionRunInputFnV1,
    session_abort: ?SessionAbortFnV1,
    session_compact: ?SessionCompactFnV1,
    session_abort_compact: ?SessionAbortCompactFnV1,
    session_export_checkpoint: ?SessionExportCheckpointFnV1,
    buffer_release: ?BufferReleaseFnV1,
    runtime_apply_mcp_configuration: ?RuntimeApplyMcpConfigurationFnV1,
    completion_create: ?CompletionCreateFnV1,
    completion_destroy: ?CompletionDestroyFnV1,
    completion_describe: ?CompletionDescribeFnV1,
    completion_complete: ?CompletionCompleteFnV1,
    completion_stream_start: ?CompletionStreamStartFnV1,
    completion_stream_next: ?CompletionStreamNextFnV1,
    completion_stream_abort: ?CompletionStreamAbortFnV1,
    completion_stream_destroy: ?CompletionStreamDestroyFnV1,
    runtime_create_with_plugins: ?RuntimeCreateWithPluginsFnV1,
    reserved: [2]u64,
};

test "ABI v1 public layouts are fixed on supported 64-bit targets" {
    const std = @import("std");
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(BytesViewV1));
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(OwnedBytesV1));
    try std.testing.expectEqual(@as(usize, 56), @sizeOf(RunContextV1));
    try std.testing.expectEqual(@as(usize, 96), @sizeOf(HostToolV1));
    try std.testing.expectEqual(@as(usize, 56), @sizeOf(HostResultSinkV1));
    try std.testing.expectEqual(@as(usize, 96), @sizeOf(HostStreamToolV1));
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(McpCancellationV1));
    try std.testing.expectEqual(@as(usize, 88), @sizeOf(McpConnectorV1));
    try std.testing.expectEqual(@as(usize, 96), @sizeOf(McpProtocolLimitsV1));
    try std.testing.expectEqual(@as(usize, 232), @sizeOf(McpServerV1));
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(McpConfigurationV1));
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(McpApplyReportV1));
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(McpCatalogLimitsV1));
    try std.testing.expectEqual(@as(usize, 96), @sizeOf(RuntimeConfigV1));
    try std.testing.expectEqual(@as(usize, 48), @sizeOf(ProcessPluginSourceV1));
    try std.testing.expectEqual(@as(usize, 72), @sizeOf(RuntimePluginConfigV1));
    try std.testing.expectEqual(@as(usize, 72), @sizeOf(SessionCallbacksV1));
    try std.testing.expectEqual(@as(usize, 56), @sizeOf(SkillPolicyV1));
    try std.testing.expectEqual(@as(usize, 88), @sizeOf(PermissionRuleSetV1));
    try std.testing.expectEqual(@as(usize, 80), @sizeOf(McpSelectorV1));
    try std.testing.expectEqual(@as(usize, 56), @sizeOf(McpSelectionV1));
    try std.testing.expectEqual(@as(usize, 112), @sizeOf(DurableBudgetProfileV1));
    try std.testing.expectEqual(@as(usize, 168), @sizeOf(SessionHostConfigV1));
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(SessionCreateConfigV1));
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(SkillSourceV1));
    try std.testing.expectEqual(@as(usize, 80), @sizeOf(SkillCatalogQueryV1));
    try std.testing.expectEqual(@as(usize, 88), @sizeOf(CompletionConfigV1));
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(CompletionMessageV1));
    try std.testing.expectEqual(@as(usize, 72), @sizeOf(CompletionRequestV1));
    try std.testing.expectEqual(@as(usize, 72), @sizeOf(CompletionResultV1));
    try std.testing.expectEqual(@as(usize, 48), @sizeOf(CompletionInfoV1));
    try std.testing.expectEqual(@as(usize, 80), @sizeOf(CompletionEventV1));
    try std.testing.expectEqual(@as(usize, 104), @sizeOf(RunInputV1));
    try std.testing.expectEqual(@as(usize, 40), @sizeOf(RunOptionsV1));
    try std.testing.expectEqual(@as(usize, 72), @sizeOf(RunResultV1));
    try std.testing.expectEqual(@as(usize, 88), @sizeOf(CompactResultV1));
    try std.testing.expectEqual(@as(usize, 88), @sizeOf(CheckpointLimitsV1));
    try std.testing.expectEqual(@as(usize, 56), @sizeOf(CheckpointSinkV1));
    try std.testing.expectEqual(@as(usize, 56), @sizeOf(CheckpointSourceV1));
    try std.testing.expectEqual(@as(usize, 56), @sizeOf(CheckpointExportConfigV1));
    try std.testing.expectEqual(@as(usize, 96), @sizeOf(CheckpointExportResultV1));
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(SessionRestoreConfigV1));
    try std.testing.expectEqual(@as(usize, 280), @sizeOf(ApiV1));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(RunContextV1, "session"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(RunContextV1, "run_id"));
    try std.testing.expectEqual(@as(usize, 24), @offsetOf(RunContextV1, "session_id"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(HostToolV1, "ctx"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(HostResultSinkV1, "ctx"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(HostStreamToolV1, "ctx"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(McpConnectorV1, "ctx"));
    try std.testing.expectEqual(@as(usize, 104), @offsetOf(McpServerV1, "connector"));
    try std.testing.expectEqual(@as(usize, 192), @offsetOf(McpServerV1, "protocol_limits"));
    try std.testing.expectEqual(@as(usize, 200), @offsetOf(McpServerV1, "configuration_fingerprint"));
    try std.testing.expectEqual(@as(usize, 40), @offsetOf(RuntimeConfigV1, "mcp_servers"));
    try std.testing.expectEqual(@as(usize, 56), @offsetOf(RuntimeConfigV1, "mcp_catalog_limits"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(ProcessPluginSourceV1, "root"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(RuntimePluginConfigV1, "process_plugins"));
    try std.testing.expectEqual(@as(usize, 24), @offsetOf(RuntimePluginConfigV1, "host_stream_tools"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(SessionHostConfigV1, "api_key"));
    try std.testing.expectEqual(@as(usize, 80), @offsetOf(SessionHostConfigV1, "allowed_tools"));
    try std.testing.expectEqual(@as(usize, 96), @offsetOf(SessionHostConfigV1, "skill_catalog"));
    try std.testing.expectEqual(@as(usize, 104), @offsetOf(SessionHostConfigV1, "skill_policy"));
    try std.testing.expectEqual(@as(usize, 112), @offsetOf(SessionHostConfigV1, "permission_rules"));
    try std.testing.expectEqual(@as(usize, 120), @offsetOf(SessionHostConfigV1, "mcp_selection"));
    try std.testing.expectEqual(@as(usize, 128), @offsetOf(SessionHostConfigV1, "durable_budget"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(SessionCreateConfigV1, "host"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(SessionCreateConfigV1, "model"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(SkillPolicyV1, "granted_skill_ids"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(PermissionRuleSetV1, "allow"));
    try std.testing.expectEqual(@as(usize, 24), @offsetOf(PermissionRuleSetV1, "ask"));
    try std.testing.expectEqual(@as(usize, 40), @offsetOf(PermissionRuleSetV1, "deny"));
    try std.testing.expectEqual(@as(usize, 40), @offsetOf(McpSelectorV1, "tool_name"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(CompactResultV1, "before_context_tokens"));
    try std.testing.expectEqual(@as(usize, 24), @offsetOf(CompactResultV1, "input_tokens"));
    try std.testing.expectEqual(@as(usize, 24), @offsetOf(RunResultV1, "durable_usage_bytes"));
    try std.testing.expectEqual(@as(usize, 32), @offsetOf(RunResultV1, "required_checkpoint_bytes"));
    try std.testing.expectEqual(@as(usize, 32), @offsetOf(CheckpointExportResultV1, "digest"));
    try std.testing.expectEqual(@as(usize, 40), @offsetOf(SkillCatalogQueryV1, "workspace_epoch"));
    try std.testing.expectEqual(@as(usize, 56), @offsetOf(SkillCatalogQueryV1, "additional_sources"));
    try std.testing.expectEqual(@as(usize, 64), @offsetOf(SkillCatalogQueryV1, "additional_source_count"));
    try std.testing.expectEqual(@as(usize, 40), @offsetOf(CompletionConfigV1, "model"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(CompletionMessageV1, "text"));
    try std.testing.expectEqual(@as(usize, 24), @offsetOf(CompletionRequestV1, "system"));
    try std.testing.expectEqual(@as(usize, 24), @offsetOf(CompletionResultV1, "input_tokens"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(CompletionInfoV1, "model"));
    try std.testing.expectEqual(@as(usize, 56), @offsetOf(CompletionEventV1, "stop_reason_code"));
    try std.testing.expectEqual(@as(usize, 56), @offsetOf(RunInputV1, "arguments_json"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(ApiV1, "abi_revision"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(ApiV1, "capabilities"));
    try std.testing.expectEqual(@as(usize, 24), @offsetOf(ApiV1, "runtime_create"));
    try std.testing.expectEqual(@as(usize, 40), @offsetOf(ApiV1, "runtime_query_skill_catalog"));
    try std.testing.expectEqual(@as(usize, 56), @offsetOf(ApiV1, "runtime_refresh_mcp"));
    try std.testing.expectEqual(@as(usize, 72), @offsetOf(ApiV1, "session_create"));
    try std.testing.expectEqual(@as(usize, 80), @offsetOf(ApiV1, "session_restore"));
    try std.testing.expectEqual(@as(usize, 104), @offsetOf(ApiV1, "session_set_model"));
    try std.testing.expectEqual(@as(usize, 112), @offsetOf(ApiV1, "session_update_skills"));
    try std.testing.expectEqual(@as(usize, 120), @offsetOf(ApiV1, "session_update_permission_rules"));
    try std.testing.expectEqual(@as(usize, 128), @offsetOf(ApiV1, "session_update_mcp"));
    try std.testing.expectEqual(@as(usize, 136), @offsetOf(ApiV1, "session_run_input"));
    try std.testing.expectEqual(@as(usize, 152), @offsetOf(ApiV1, "session_compact"));
    try std.testing.expectEqual(@as(usize, 160), @offsetOf(ApiV1, "session_abort_compact"));
    try std.testing.expectEqual(@as(usize, 168), @offsetOf(ApiV1, "session_export_checkpoint"));
    try std.testing.expectEqual(@as(usize, 176), @offsetOf(ApiV1, "buffer_release"));
    try std.testing.expectEqual(@as(usize, 184), @offsetOf(ApiV1, "runtime_apply_mcp_configuration"));
    try std.testing.expectEqual(@as(usize, 192), @offsetOf(ApiV1, "completion_create"));
    try std.testing.expectEqual(@as(usize, 248), @offsetOf(ApiV1, "completion_stream_destroy"));
    try std.testing.expectEqual(@as(usize, 256), @offsetOf(ApiV1, "runtime_create_with_plugins"));
    try std.testing.expectEqual(@as(usize, 264), @offsetOf(ApiV1, "reserved"));
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
    try std.testing.expectEqual(Status.skill_catalog_invalid, try Status.fromCode(11));
    try std.testing.expectEqual(Status.skill_unavailable, try Status.fromCode(16));
    try std.testing.expectEqual(Status.stale_compact, try Status.fromCode(17));
    try std.testing.expectEqual(Status.invalid_mcp_selection, try Status.fromCode(25));
    try std.testing.expectEqual(Status.completion_unsupported_response, try Status.fromCode(26));
    try std.testing.expectEqual(Status.skill_catalog_incomplete, try Status.fromCode(27));
    try std.testing.expectError(error.UnknownStatus, Status.fromCode(28));
    try std.testing.expectError(error.UnknownStatus, Status.fromCode(std.math.maxInt(u32)));
    try std.testing.expectError(error.UnknownStopReason, StopReason.fromCode(0));
    try std.testing.expectEqual(StopReason.checkpoint_resource_limit, try StopReason.fromCode(8));
    try std.testing.expectError(error.UnknownStopReason, StopReason.fromCode(9));
    try std.testing.expectError(error.UnknownStopReason, StopReason.fromCode(std.math.maxInt(u32)));
    inline for (std.meta.fields(CompletionStopReason)) |field| {
        const value: CompletionStopReason = @enumFromInt(field.value);
        try std.testing.expectEqual(value, try CompletionStopReason.fromCode(field.value));
    }
    try std.testing.expectError(
        error.UnknownCompletionStopReason,
        CompletionStopReason.fromCode(7),
    );
}

test "Revision 12 capabilities add Host and MCP byte-zero streaming without weakening prior surfaces" {
    const std = @import("std");
    try std.testing.expectEqual(@as(u32, 12), ABI_REVISION);
    try std.testing.expectEqual(@as(u64, 1 << 20), CAP_WORKSPACE_SKILL_CATALOG);
    try std.testing.expectEqual(@as(u64, 1 << 21), CAP_TEXT_COMPLETION);
    try std.testing.expectEqual(@as(u64, 1 << 22), CAP_PROCESS_PLUGIN_TOOLS);
    try std.testing.expectEqual(@as(u64, 1 << 23), CAP_HOST_STREAM_TOOLS);
    try std.testing.expectEqual(@as(u64, 1 << 24), CAP_MCP_TOOL_STREAM);
    try std.testing.expectEqual(@as(u32, 1), MCP_NEGOTIATION_AUTO);
    try std.testing.expectEqual(@as(u32, 2), MCP_NEGOTIATION_MODERN_ONLY);
    try std.testing.expectEqual(@as(u32, 3), MCP_NEGOTIATION_LEGACY_ONLY);
    try std.testing.expectEqual(@as(u32, 4), MCP_NEGOTIATION_LEGACY_2025_06_ONLY);
    try std.testing.expectEqual(@as(u32, 1), MCP_ERA_2026_07_28);
    try std.testing.expectEqual(@as(u32, 2), MCP_ERA_2025_11_25);
    try std.testing.expectEqual(@as(u32, 3), MCP_ERA_2025_06_18);
    try std.testing.expectEqual(@as(u32, 1), MCP_APPLY_APPLIED);
    try std.testing.expectEqual(@as(u32, 2), MCP_APPLY_SUPERSEDED);
    try std.testing.expectEqual(@as(u32, 3), MCP_APPLY_REJECTED);
}
