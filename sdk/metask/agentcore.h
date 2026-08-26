#ifndef METASK_AGENTCORE_H
#define METASK_AGENTCORE_H

#include <stddef.h>
#include <stdint.h>

#if !defined(UINTPTR_MAX) || !defined(UINT64_MAX) || UINTPTR_MAX != UINT64_MAX
#error "AgentCore ABI v1 revision 14 requires a 64-bit pointer ABI"
#endif

#ifdef __cplusplus
extern "C" {
#endif

/* sdk/zig/types.zig is the normative fixed-layout schema. This header is its
 * Revision 14 C projection; sdk/rust/src/raw.rs is generated from this file.
 * AgentCore ABI v1 remains experimental. Consumers pin an exact bundle and
 * must validate the exact root and mandatory child-table layouts together. */
#define METASK_AGENTCORE_ABI_V1 1u
#define METASK_AGENTCORE_ABI_REVISION 14u

#define METASK_AGENTCORE_STATUS_OK 0u
#define METASK_AGENTCORE_STATUS_INVALID_ARGUMENT 1u
#define METASK_AGENTCORE_STATUS_OUT_OF_MEMORY 2u
#define METASK_AGENTCORE_STATUS_BUSY 3u
#define METASK_AGENTCORE_STATUS_STALE_RUN 4u
#define METASK_AGENTCORE_STATUS_TOO_LATE 5u
#define METASK_AGENTCORE_STATUS_INVALID_STATE 6u
#define METASK_AGENTCORE_STATUS_CORE_ERROR 7u
#define METASK_AGENTCORE_STATUS_CALLBACK_FAILED 8u
#define METASK_AGENTCORE_STATUS_INTERNAL_ERROR 9u
#define METASK_AGENTCORE_STATUS_RESOURCE_LIMIT 10u
#define METASK_AGENTCORE_STATUS_SKILL_CATALOG_INVALID 11u
#define METASK_AGENTCORE_STATUS_STALE_CATALOG 12u
#define METASK_AGENTCORE_STATUS_SKILL_NOT_FOUND 13u
#define METASK_AGENTCORE_STATUS_INVALID_SKILL_ARGUMENTS 14u
#define METASK_AGENTCORE_STATUS_SKILL_POLICY_VIOLATION 15u
#define METASK_AGENTCORE_STATUS_SKILL_UNAVAILABLE 16u
#define METASK_AGENTCORE_STATUS_STALE_COMPACT 17u
#define METASK_AGENTCORE_STATUS_CHECKPOINT_BUDGET_REQUIRED 18u
#define METASK_AGENTCORE_STATUS_CHECKPOINT_CORRUPT 19u
#define METASK_AGENTCORE_STATUS_CHECKPOINT_UNSUPPORTED 20u
#define METASK_AGENTCORE_STATUS_CHECKPOINT_INCOMPATIBLE 21u
#define METASK_AGENTCORE_STATUS_CHECKPOINT_IO 22u
#define METASK_AGENTCORE_STATUS_LOGICAL_SESSION_CONFLICT 23u
#define METASK_AGENTCORE_STATUS_MCP_NOT_REFRESHED 24u
#define METASK_AGENTCORE_STATUS_INVALID_MCP_SELECTION 25u
#define METASK_AGENTCORE_STATUS_COMPLETION_UNSUPPORTED_RESPONSE 26u
#define METASK_AGENTCORE_STATUS_SKILL_CATALOG_INCOMPLETE 27u

#define METASK_AGENTCORE_PROVIDER_ANTHROPIC 1u
#define METASK_AGENTCORE_PROVIDER_OPENAI 2u
#define METASK_AGENTCORE_PROVIDER_GEMINI 3u
#define METASK_AGENTCORE_PERMISSION_DEFAULT 1u
#define METASK_AGENTCORE_PERMISSION_ACCEPT_EDITS 2u
#define METASK_AGENTCORE_PERMISSION_AUTO 3u
#define METASK_AGENTCORE_PERMISSION_DONT_ASK 4u
#define METASK_AGENTCORE_PERMISSION_FULL_ACCESS 5u
#define METASK_AGENTCORE_SHELL_DISABLED 1u
#define METASK_AGENTCORE_SHELL_SANDBOXED 2u
#define METASK_AGENTCORE_SHELL_UNRESTRICTED 3u
/* Run journal mode is Session-stable. Durable records never enter model
 * Conversation/request bytes and do not imply automatic active-Run replay. */
#define METASK_AGENTCORE_RUN_JOURNAL_EPHEMERAL 0u
#define METASK_AGENTCORE_RUN_JOURNAL_DURABLE_WORKSPACE 1u
#define METASK_AGENTCORE_ABORT_USER_REQUEST 1u
#define METASK_AGENTCORE_ABORT_TIMEOUT 2u

#define METASK_AGENTCORE_STOP_END_TURN 1u
#define METASK_AGENTCORE_STOP_MAX_TURNS 2u
#define METASK_AGENTCORE_STOP_ABORTED 3u
#define METASK_AGENTCORE_STOP_TOOL_ERROR 4u
#define METASK_AGENTCORE_STOP_API_ERROR 5u
#define METASK_AGENTCORE_STOP_TOOL_LOOP 6u
#define METASK_AGENTCORE_STOP_CHECKPOINT_BUDGET_EXHAUSTED 7u
#define METASK_AGENTCORE_STOP_CHECKPOINT_RESOURCE_LIMIT 8u

#define METASK_AGENTCORE_MAX_TOOL_COUNT_V1 1024ULL
#define METASK_AGENTCORE_MAX_TOOL_SCHEMA_BYTES_V1 1048576ULL
#define METASK_AGENTCORE_MAX_TOOL_SCHEMA_DEPTH_V1 32u
#define METASK_AGENTCORE_MAX_TOOL_SCHEMA_PROPERTIES_V1 1024ULL
#define METASK_AGENTCORE_MAX_UI_RESPONSE_BYTES_V1 1048576ULL
#define METASK_AGENTCORE_MAX_HOST_TOOL_RESULT_BYTES_V1 16777216ULL
#define METASK_AGENTCORE_MAX_HOST_STREAM_ARTIFACT_BYTES_V1 134217728ULL
#define METASK_AGENTCORE_MAX_MCP_TOOL_RESPONSE_BYTES_V1 135266304ULL
#define METASK_AGENTCORE_MAX_TOOL_ERROR_PAYLOAD_BYTES_V1 1048576ULL
#define METASK_AGENTCORE_MAX_SESSION_ID_BYTES_V1 64ULL
#define METASK_AGENTCORE_MAX_METADATA_STRING_BYTES_V1 1048576ULL
#define METASK_AGENTCORE_MAX_RUNTIME_METADATA_BYTES_V1 16777216ULL
#define METASK_AGENTCORE_MAX_SESSION_METADATA_BYTES_V1 4194304ULL
#define METASK_AGENTCORE_MAX_PROMPT_BYTES_V1 16777216ULL
#define METASK_AGENTCORE_MAX_SKILL_CATALOG_SKILLS_V1 1024ULL
#define METASK_AGENTCORE_MAX_SKILL_CATALOG_DESCRIPTOR_BYTES_V1 4194304ULL
#define METASK_AGENTCORE_MAX_SKILL_FILE_CONTENT_BYTES_V1 16777216ULL
#define METASK_AGENTCORE_MAX_SKILL_CONTENT_BYTES_V1 33554432ULL
#define METASK_AGENTCORE_MAX_SKILL_FILES_V1 1024ULL
#define METASK_AGENTCORE_MAX_SKILL_ENTRIES_V1 4096ULL
#define METASK_AGENTCORE_MAX_SKILL_DIRECTORY_DEPTH_V1 64ULL
#define METASK_AGENTCORE_MAX_SKILL_RELATIVE_PATH_BYTES_V1 4096ULL
#define METASK_AGENTCORE_MAX_SKILL_CATALOG_CONTENT_BYTES_V1 67108864ULL
#define METASK_AGENTCORE_MAX_SKILL_CATALOG_FILES_V1 16384ULL
#define METASK_AGENTCORE_MAX_SKILL_CATALOG_TRAVERSAL_ENTRIES_V1 65536ULL
#define METASK_AGENTCORE_MAX_SKILL_RUNTIME_RETAINED_SNAPSHOT_BYTES_V1 268435456ULL
#define METASK_AGENTCORE_MAX_SKILL_ARGUMENT_VALUES_V1 64ULL
#define METASK_AGENTCORE_MAX_SKILL_ARGUMENT_JSON_BYTES_V1 1048576ULL
#define METASK_AGENTCORE_MAX_PERMISSION_RULES_V1 1024ULL
#define METASK_AGENTCORE_MAX_PERMISSION_RULE_BYTES_V1 65536ULL
#define METASK_AGENTCORE_MAX_PERMISSION_RULE_TOTAL_BYTES_V1 1048576ULL
#define METASK_AGENTCORE_MAX_PERMISSION_ARGUMENT_JSON_BYTES_V1 1048576ULL
#define METASK_AGENTCORE_MAX_MCP_SERVERS_V1 64ULL
#define METASK_AGENTCORE_MAX_MCP_NAMESPACE_BYTES_V1 24ULL
#define METASK_AGENTCORE_MAX_MCP_CATALOG_ISSUES_V1 4096ULL
#define METASK_AGENTCORE_MAX_MCP_FRAME_BYTES_V1 8388608ULL
#define METASK_AGENTCORE_MAX_MCP_TOOLS_V1 1024ULL
#define METASK_AGENTCORE_MAX_MCP_TOOL_NAME_BYTES_V1 256ULL
#define METASK_AGENTCORE_MAX_MCP_TEXT_BYTES_V1 65536ULL
#define METASK_AGENTCORE_MAX_MCP_SCHEMA_BYTES_V1 1048576ULL
#define METASK_AGENTCORE_MAX_MCP_CURSOR_BYTES_V1 16384ULL
#define METASK_AGENTCORE_MAX_MCP_PROTOCOL_VERSIONS_V1 16ULL
#define METASK_AGENTCORE_MAX_CHECKPOINT_BYTES_V1 1073741824ULL
#define METASK_AGENTCORE_MAX_CHECKPOINT_CHUNK_BYTES_V1 1048576u
#define METASK_AGENTCORE_MAX_DESCRIPTION_JSON_BYTES_V1 16777216ULL
#define METASK_AGENTCORE_MAX_COMPLETION_CONFIG_BYTES_V1 1048576ULL
#define METASK_AGENTCORE_MAX_COMPLETION_MESSAGES_V1 4096ULL
#define METASK_AGENTCORE_MAX_COMPLETION_REQUEST_BYTES_V1 16777216ULL
#define METASK_AGENTCORE_MAX_COMPLETION_RESULT_BYTES_V1 16777216ULL
#define METASK_AGENTCORE_MAX_SKILL_SOURCES_V1 64ULL
#define METASK_AGENTCORE_MAX_SKILL_SOURCE_ID_BYTES_V1 128ULL
#define METASK_AGENTCORE_MAX_PROCESS_PLUGIN_SOURCES_V1 64ULL
#define METASK_AGENTCORE_MAX_TURNS_V1 1000u

#define METASK_AGENTCORE_PLUGIN_LAYER_BUILTIN 1u
#define METASK_AGENTCORE_PLUGIN_LAYER_PERSONAL 2u
#define METASK_AGENTCORE_PLUGIN_LAYER_PROJECT 3u
#define METASK_AGENTCORE_PLUGIN_LAYER_SESSION 4u
#define METASK_AGENTCORE_PLUGIN_LAYER_MANAGED 5u

#define METASK_AGENTCORE_RUN_INPUT_TEXT 1u
#define METASK_AGENTCORE_RUN_INPUT_SKILL 2u
#define METASK_AGENTCORE_SKILL_SOURCE_USER 1u
#define METASK_AGENTCORE_SKILL_SOURCE_WORKSPACE 2u
#define METASK_AGENTCORE_COMPACT_COMPACTED 1u
#define METASK_AGENTCORE_COMPACT_NO_CHANGE 2u
#define METASK_AGENTCORE_COMPACT_DEGRADED 3u
#define METASK_AGENTCORE_COMPACT_ABORTED 4u
#define METASK_AGENTCORE_RUN_CHECKPOINT_NONE 0u
#define METASK_AGENTCORE_RUN_CHECKPOINT_BUDGET_REQUIRED 1u
#define METASK_AGENTCORE_RUN_CHECKPOINT_BUDGET_EXHAUSTED 2u
#define METASK_AGENTCORE_RUN_CHECKPOINT_RESOURCE_LIMIT 3u
#define METASK_AGENTCORE_RUN_RESULT_COMPACTION_RECOMMENDED (1u << 0)

#define METASK_AGENTCORE_COMPLETION_ROLE_USER 1u
#define METASK_AGENTCORE_COMPLETION_ROLE_ASSISTANT 2u
#define METASK_AGENTCORE_COMPLETION_STOP_UNKNOWN 0u
#define METASK_AGENTCORE_COMPLETION_STOP_END_TURN 1u
#define METASK_AGENTCORE_COMPLETION_STOP_MAX_TOKENS 2u
#define METASK_AGENTCORE_COMPLETION_STOP_STOP_SEQUENCE 3u
#define METASK_AGENTCORE_COMPLETION_STOP_PAUSE_TURN 4u
#define METASK_AGENTCORE_COMPLETION_STOP_REFUSAL 5u
#define METASK_AGENTCORE_COMPLETION_STOP_ABORTED 6u
#define METASK_AGENTCORE_COMPLETION_EVENT_TEXT 1u
#define METASK_AGENTCORE_COMPLETION_EVENT_THINKING 2u
#define METASK_AGENTCORE_COMPLETION_EVENT_USAGE 3u
#define METASK_AGENTCORE_COMPLETION_EVENT_DONE 4u

#define METASK_AGENTCORE_MCP_TRANSPORT_STDIO 1u
#define METASK_AGENTCORE_MCP_TRANSPORT_STREAMABLE_HTTP 2u
#define METASK_AGENTCORE_MCP_NEGOTIATION_AUTO 1u
#define METASK_AGENTCORE_MCP_NEGOTIATION_MODERN_ONLY 2u
#define METASK_AGENTCORE_MCP_NEGOTIATION_LEGACY_ONLY 3u
#define METASK_AGENTCORE_MCP_NEGOTIATION_LEGACY_2025_06_ONLY 4u
#define METASK_AGENTCORE_MCP_ERA_2026_07_28 1u
#define METASK_AGENTCORE_MCP_ERA_2025_11_25 2u
#define METASK_AGENTCORE_MCP_ERA_2025_06_18 3u
#define METASK_AGENTCORE_MCP_APPLY_APPLIED 1u
#define METASK_AGENTCORE_MCP_APPLY_SUPERSEDED 2u
#define METASK_AGENTCORE_MCP_APPLY_REJECTED 3u
#define METASK_AGENTCORE_MCP_CONNECTION_DISPOSABLE_PROBE 1u
#define METASK_AGENTCORE_MCP_CONNECTION_ACTUAL 2u
#define METASK_AGENTCORE_MCP_OPEN_OK 0u
#define METASK_AGENTCORE_MCP_OPEN_TIMEOUT 1u
#define METASK_AGENTCORE_MCP_OPEN_NETWORK_ERROR 2u
#define METASK_AGENTCORE_MCP_OPEN_AUTH_ERROR 3u
#define METASK_AGENTCORE_MCP_OPEN_SERVER_ERROR 4u
#define METASK_AGENTCORE_MCP_OPEN_CHILD_EXIT 5u
#define METASK_AGENTCORE_MCP_OPEN_FATAL 6u
#define METASK_AGENTCORE_MCP_EXCHANGE_RESPONSE 0u
#define METASK_AGENTCORE_MCP_EXCHANGE_TIMEOUT 1u
#define METASK_AGENTCORE_MCP_EXCHANGE_NETWORK_ERROR 2u
#define METASK_AGENTCORE_MCP_EXCHANGE_AUTH_ERROR 3u
#define METASK_AGENTCORE_MCP_EXCHANGE_SERVER_ERROR 4u
#define METASK_AGENTCORE_MCP_EXCHANGE_CHILD_EXIT 5u
#define METASK_AGENTCORE_MCP_EXCHANGE_CANCELLED 6u
#define METASK_AGENTCORE_MCP_EXCHANGE_INDETERMINATE 7u
#define METASK_AGENTCORE_MCP_EXCHANGE_FATAL 8u
#define METASK_AGENTCORE_MCP_NOTIFY_OK 0u
#define METASK_AGENTCORE_MCP_NOTIFY_FAILED 1u
#define METASK_AGENTCORE_CHECKPOINT_IO_OK 0u
#define METASK_AGENTCORE_CHECKPOINT_IO_FAILED 1u
#define METASK_AGENTCORE_CHECKPOINT_IO_FATAL 2u

#define METASK_AGENTCORE_EVENT_CONTINUE 0u
#define METASK_AGENTCORE_EVENT_FATAL 1u
#define METASK_AGENTCORE_UI_ANSWERED 0u
#define METASK_AGENTCORE_UI_UNAVAILABLE 1u
#define METASK_AGENTCORE_UI_FATAL 2u
#define METASK_AGENTCORE_UI_CANCELLED 3u
#define METASK_AGENTCORE_HOST_OK 0u
#define METASK_AGENTCORE_HOST_FAILED 1u
#define METASK_AGENTCORE_HOST_REJECTED 2u
#define METASK_AGENTCORE_HOST_FATAL 3u
#define METASK_AGENTCORE_HOST_STREAM_MEDIA_TEXT_UTF8 1u
#define METASK_AGENTCORE_HOST_STREAM_MEDIA_JSON 2u
#define METASK_AGENTCORE_HOST_STREAM_MEDIA_BINARY 3u
#define METASK_AGENTCORE_HOST_SINK_OK 0u
#define METASK_AGENTCORE_HOST_SINK_ABORTED 1u
#define METASK_AGENTCORE_HOST_SINK_TOO_LARGE 2u
#define METASK_AGENTCORE_HOST_SINK_FAILED 3u
#define METASK_AGENTCORE_HOST_SINK_CLOSED 4u

typedef struct metask_agentcore_runtime metask_agentcore_runtime;
typedef struct metask_agentcore_session metask_agentcore_session;
typedef struct metask_agentcore_skill_catalog metask_agentcore_skill_catalog;
typedef struct metask_agentcore_completion metask_agentcore_completion;
typedef struct metask_agentcore_completion_stream metask_agentcore_completion_stream;

typedef struct {
    const uint8_t *ptr;
    uint64_t len;
} metask_agentcore_bytes_view_v1;

typedef struct {
    uint8_t *ptr;
    uint64_t len;
} metask_agentcore_owned_bytes_v1;

typedef struct {
    uint32_t struct_size;
    uint32_t reserved0;
    metask_agentcore_session *session;
    uint64_t run_id;
    metask_agentcore_bytes_view_v1 session_id;
    uint64_t reserved[2];
} metask_agentcore_run_context_v1;

typedef uint32_t (*metask_agentcore_host_execute_fn_v1)(
    void *, const metask_agentcore_run_context_v1 *,
    metask_agentcore_bytes_view_v1, metask_agentcore_owned_bytes_v1 *);
typedef void (*metask_agentcore_host_release_fn_v1)(
    void *, metask_agentcore_owned_bytes_v1 *);

typedef struct {
    uint32_t struct_size;
    uint32_t reserved0;
    void *ctx;
    metask_agentcore_bytes_view_v1 name;
    metask_agentcore_bytes_view_v1 description;
    metask_agentcore_bytes_view_v1 input_schema_json;
    metask_agentcore_host_execute_fn_v1 execute;
    metask_agentcore_host_release_fn_v1 release_result;
    uint64_t reserved[2];
} metask_agentcore_host_tool_v1;

typedef uint32_t (*metask_agentcore_host_result_write_fn_v1)(
    void *, metask_agentcore_bytes_view_v1);

/* Borrowed for one synchronous callback. The Host must not retain this sink;
 * AgentCore alone commits or rolls back the streamed artifact. */
typedef struct {
    uint32_t struct_size;
    uint32_t reserved0;
    void *ctx;
    metask_agentcore_host_result_write_fn_v1 write;
    uint64_t max_bytes;
    uint64_t reserved[3];
} metask_agentcore_host_result_sink_v1;

typedef uint32_t (*metask_agentcore_host_stream_execute_fn_v1)(
    void *, const metask_agentcore_run_context_v1 *,
    metask_agentcore_bytes_view_v1,
    const metask_agentcore_host_result_sink_v1 *, uint32_t *,
    metask_agentcore_owned_bytes_v1 *);

typedef struct {
    uint32_t struct_size;
    uint32_t reserved0;
    void *ctx;
    metask_agentcore_bytes_view_v1 name;
    metask_agentcore_bytes_view_v1 description;
    metask_agentcore_bytes_view_v1 input_schema_json;
    metask_agentcore_host_stream_execute_fn_v1 execute_stream;
    metask_agentcore_host_release_fn_v1 release_detail;
    uint64_t reserved[2];
} metask_agentcore_host_stream_tool_v1;

typedef uint32_t (*metask_agentcore_mcp_is_cancelled_fn_v1)(const void *);
/* The cancellation descriptor, its ctx, and callback are borrowed only for
 * the synchronous request/notify invocation. The Host MUST NOT retain or poll
 * them after that callback returns. */
typedef struct {
    uint32_t struct_size;
    uint32_t reserved0;
    const void *ctx;
    metask_agentcore_mcp_is_cancelled_fn_v1 is_cancelled;
    uint64_t reserved[2];
} metask_agentcore_mcp_cancellation_v1;

typedef struct {
    uint32_t struct_size;
    uint32_t http_status;
    metask_agentcore_owned_bytes_v1 body;
    uint64_t reserved[2];
} metask_agentcore_mcp_response_v1;

/* Each successful open binds its opaque connection context permanently to
 * purpose_code and requested_era_code. For Streamable HTTP, the Host owns
 * HTTP protocol state: after a successful exact-era initialization it MUST
 * send MCP-Protocol-Version with that era on subsequent requests and MUST
 * retain and send any MCP-Session-Id returned by the server. Probe and actual
 * connections, and connections reopened for a different era, MUST NOT share
 * session identifiers or mutable protocol state. AgentCore closes a
 * mismatched connection and opens a new exact-era connection; the Host MUST
 * NOT switch the era of an existing connection context. */
typedef uint32_t (*metask_agentcore_mcp_open_fn_v1)(
    void *, uint32_t, uint32_t, uint32_t, void **);
typedef uint32_t (*metask_agentcore_mcp_request_fn_v1)(
    void *, void *, metask_agentcore_bytes_view_v1, uint32_t,
    const metask_agentcore_mcp_cancellation_v1 *,
    metask_agentcore_mcp_response_v1 *);
typedef uint32_t (*metask_agentcore_mcp_request_tool_stream_fn_v1)(
    void *, void *, metask_agentcore_bytes_view_v1, uint32_t,
    const metask_agentcore_mcp_cancellation_v1 *,
    const metask_agentcore_host_result_sink_v1 *);
/* Notifications have one committed-success outcome. Any transport, protocol,
 * cancellation, or Host failure returns MCP_NOTIFY_FAILED. */
typedef uint32_t (*metask_agentcore_mcp_notify_fn_v1)(
    void *, void *, metask_agentcore_bytes_view_v1, uint32_t,
    const metask_agentcore_mcp_cancellation_v1 *);
typedef void (*metask_agentcore_mcp_close_fn_v1)(void *, void *);
typedef void (*metask_agentcore_mcp_release_response_fn_v1)(
    void *, void *, metask_agentcore_owned_bytes_v1 *);
typedef void (*metask_agentcore_mcp_retain_connector_fn_v1)(void *);
typedef void (*metask_agentcore_mcp_release_connector_fn_v1)(void *);

/* Host owns connector ctx, credentials, and live connection contexts.
 * retain_connector and release_connector are mandatory and must be thread-safe;
 * they keep ctx alive across Runtime calls. Every successful open is closed
 * exactly once. For a completed Streamable HTTP response, request returns
 * MCP_EXCHANGE_RESPONSE and reports its status and body through
 * metask_agentcore_mcp_response_v1. Stdio responses use http_status == 0.
 * Non-response outcomes use http_status == 0 and an empty body. Every
 * non-canonical-empty body token is released exactly once by passing
 * &response.body to release_response, independent of status. This includes an
 * invalid { ptr != NULL, len == 0 } token. AgentCore copies valid response
 * bytes before release. `request` is only for bounded MCP control frames.
 * `request_tool_stream` is mandatory for tools/call and must write the
 * complete JSON-RPC response from byte zero to the borrowed kernel sink. */
typedef struct {
    uint32_t struct_size;
    uint32_t reserved0;
    void *ctx;
    metask_agentcore_mcp_open_fn_v1 open;
    metask_agentcore_mcp_request_fn_v1 request;
    metask_agentcore_mcp_request_tool_stream_fn_v1 request_tool_stream;
    metask_agentcore_mcp_notify_fn_v1 notify;
    metask_agentcore_mcp_close_fn_v1 close;
    metask_agentcore_mcp_release_response_fn_v1 release_response;
    metask_agentcore_mcp_retain_connector_fn_v1 retain_connector;
    metask_agentcore_mcp_release_connector_fn_v1 release_connector;
    uint64_t reserved[1];
} metask_agentcore_mcp_connector_v1;

typedef struct {
    uint32_t struct_size;
    uint32_t reserved0;
    uint64_t max_frame_bytes;
    uint64_t max_tools;
    uint64_t max_tool_name_bytes;
    uint64_t max_text_bytes;
    uint64_t max_schema_bytes;
    uint64_t max_json_depth;
    uint64_t max_json_nodes;
    uint64_t max_cursor_bytes;
    uint64_t max_versions;
    uint64_t reserved[2];
} metask_agentcore_mcp_protocol_limits_v1;

typedef struct {
    uint32_t struct_size;
    uint32_t transport_code;
    uint32_t negotiation_policy_code;
    uint32_t reserved0;
    uint8_t server_binding_identity[32];
    /* `namespace` is a C++ keyword; this field is named namespace_ without
     * changing the fixed offset or wire meaning. */
    metask_agentcore_bytes_view_v1 namespace_;
    metask_agentcore_bytes_view_v1 client_name;
    metask_agentcore_bytes_view_v1 client_version;
    uint32_t timeout_ms;
    uint32_t reserved1;
    metask_agentcore_mcp_connector_v1 connector;
    const metask_agentcore_mcp_protocol_limits_v1 *protocol_limits;
    /* Nonzero stable, non-secret identity of connection-relevant configuration. */
    uint8_t configuration_fingerprint[32];
} metask_agentcore_mcp_server_v1;

typedef struct {
    uint32_t struct_size;
    uint32_t reserved0;
    uint64_t desired_revision;
    const metask_agentcore_mcp_server_v1 *servers;
    uint64_t server_count;
    uint64_t reserved[4];
} metask_agentcore_mcp_configuration_v1;

typedef struct {
    uint32_t struct_size;
    uint32_t disposition_code;
    uint64_t desired_revision;
    uint64_t active_revision;
    uint64_t catalog_generation;
    uint64_t reserved[4];
} metask_agentcore_mcp_apply_report_v1;

typedef struct {
    uint32_t struct_size;
    uint32_t reserved0;
    uint64_t max_servers;
    uint64_t max_namespace_bytes;
    uint64_t max_issues;
    uint64_t reserved[4];
} metask_agentcore_mcp_catalog_limits_v1;

typedef struct {
    uint32_t struct_size;
    uint32_t reserved0;
    const metask_agentcore_bytes_view_v1 *builtin_tools;
    uint64_t builtin_tool_count;
    const metask_agentcore_host_tool_v1 *host_tools;
    uint64_t host_tool_count;
    const metask_agentcore_mcp_server_v1 *mcp_servers;
    uint64_t mcp_server_count;
    const metask_agentcore_mcp_catalog_limits_v1 *mcp_catalog_limits;
    uint64_t reserved[4];
} metask_agentcore_runtime_config_v1;

/* Explicit executable authority. root is an absolute package directory with
 * strict plugin.json/process.json metadata. AgentCore copies retained state
 * before RuntimeApiV1.create returns. */
typedef struct {
    uint32_t struct_size;
    uint32_t layer_code;
    metask_agentcore_bytes_view_v1 root;
    uint64_t reserved[3];
} metask_agentcore_process_plugin_source_v1;

/* Kept separate from runtime_config_v1 so executable extensions never
 * reinterpret fields that an earlier revision required to be zero. */
typedef struct {
    uint32_t struct_size;
    uint32_t reserved0;
    const metask_agentcore_process_plugin_source_v1 *process_plugins;
    uint64_t process_plugin_count;
    const metask_agentcore_host_stream_tool_v1 *host_stream_tools;
    uint64_t host_stream_tool_count;
    uint64_t reserved[4];
} metask_agentcore_runtime_plugin_config_v1;

typedef uint32_t (*metask_agentcore_on_event_fn_v1)(
    void *, const metask_agentcore_run_context_v1 *, metask_agentcore_bytes_view_v1);
typedef uint32_t (*metask_agentcore_on_ui_request_fn_v1)(
    void *, const metask_agentcore_run_context_v1 *,
    metask_agentcore_bytes_view_v1, metask_agentcore_owned_bytes_v1 *);
typedef void (*metask_agentcore_release_response_fn_v1)(
    void *, metask_agentcore_owned_bytes_v1 *);

/* Permission UI requests are the exact flat agentcore Permission v1 JSON
 * shape. Responses echo request_id and policy_generation; Session choices
 * additionally echo candidate.rule_id. CoreEvent permission_provenance carries
 * identities and digests but never raw Tool arguments or credentials. */
typedef struct {
    uint32_t struct_size;
    uint32_t reserved0;
    void *ctx;
    metask_agentcore_on_event_fn_v1 on_event;
    metask_agentcore_on_ui_request_fn_v1 on_ui_request;
    metask_agentcore_release_response_fn_v1 release_response;
    uint64_t reserved[4];
} metask_agentcore_session_callbacks_v1;

/* Default-deny authorization over concrete skill_id values from exactly one
 * complete catalog descriptor. Empty grants deny every Skill. */
typedef struct {
    uint32_t struct_size;
    uint32_t reserved0;
    const metask_agentcore_bytes_view_v1 *granted_skill_ids;
    uint64_t granted_skill_id_count;
    uint64_t reserved[4];
} metask_agentcore_skill_policy_v1;

typedef struct {
    uint32_t struct_size;
    uint32_t reserved0;
    const metask_agentcore_bytes_view_v1 *allow;
    uint64_t allow_count;
    const metask_agentcore_bytes_view_v1 *ask;
    uint64_t ask_count;
    const metask_agentcore_bytes_view_v1 *deny;
    uint64_t deny_count;
    uint64_t reserved[4];
} metask_agentcore_permission_rule_set_v1;

typedef struct {
    uint32_t struct_size;
    uint32_t reserved0;
    uint8_t server_binding_identity[32];
    metask_agentcore_bytes_view_v1 tool_name;
    uint64_t reserved[3];
} metask_agentcore_mcp_selector_v1;

typedef struct {
    uint32_t struct_size;
    uint32_t reserved0;
    const metask_agentcore_mcp_selector_v1 *selectors;
    uint64_t selector_count;
    uint64_t reserved[4];
} metask_agentcore_mcp_selection_v1;

typedef struct {
    uint32_t struct_size;
    uint32_t reserved0;
    uint64_t hard_bytes;
    uint64_t soft_bytes;
    uint64_t input_cap_bytes;
    uint64_t provider_request_cap_bytes;
    uint64_t provider_result_cap_bytes;
    uint64_t tool_result_cap_bytes;
    uint64_t mcp_result_cap_bytes;
    uint64_t audit_reserve_bytes;
    uint64_t terminal_reserve_bytes;
    uint64_t reserved[4];
} metask_agentcore_durable_budget_profile_v1;

/* Current Host authority is shared by fresh creation and restore. Restore
 * intersects this authority with checkpoint state; it never accepts a Host
 * supplied logical Session ID and never widens historical authority. */
typedef struct {
    uint32_t struct_size;
    uint32_t provider_kind_code;
    uint32_t permission_mode_code;
    uint32_t shell_policy_code;
    metask_agentcore_bytes_view_v1 api_key;
    metask_agentcore_bytes_view_v1 base_url;
    metask_agentcore_bytes_view_v1 workspace_root;
    metask_agentcore_bytes_view_v1 workspace_home;
    const metask_agentcore_bytes_view_v1 *allowed_tools;
    uint64_t allowed_tool_count;
    metask_agentcore_skill_catalog *skill_catalog;
    const metask_agentcore_skill_policy_v1 *skill_policy;
    const metask_agentcore_permission_rule_set_v1 *permission_rules;
    const metask_agentcore_mcp_selection_v1 *mcp_selection;
    const metask_agentcore_durable_budget_profile_v1 *durable_budget;
    /* One METASK_AGENTCORE_RUN_JOURNAL_* value. Durable mode writes the
     * unified provider/tool intent-result journal below workspace_home. */
    uint32_t run_journal_mode_code;
    uint32_t reserved0;
    uint64_t reserved[3];
} metask_agentcore_session_host_config_v1;

typedef struct {
    uint32_t struct_size;
    uint32_t reserved0;
    const metask_agentcore_session_host_config_v1 *host;
    metask_agentcore_bytes_view_v1 model;
    uint64_t reserved[4];
} metask_agentcore_session_create_config_v1;

typedef struct {
    uint32_t struct_size;
    uint32_t scope_code;
    metask_agentcore_bytes_view_v1 root;
    metask_agentcore_bytes_view_v1 source_instance_id;
    uint64_t reserved[3];
} metask_agentcore_skill_source_v1;

/* Resolves one complete Workspace authority. The raw function-table slot keeps
 * its historical name; SDKs expose this as resolveWorkspaceSkillCatalog. */
typedef struct {
    uint32_t struct_size;
    uint32_t reserved0;
    metask_agentcore_bytes_view_v1 workspace_root;
    metask_agentcore_bytes_view_v1 workspace_home;
    metask_agentcore_bytes_view_v1 workspace_epoch;
    const metask_agentcore_skill_source_v1 *additional_sources;
    uint64_t additional_source_count;
    uint64_t reserved[1];
} metask_agentcore_skill_catalog_query_v1;

typedef struct {
    uint32_t struct_size;
    uint32_t provider_kind_code;
    metask_agentcore_bytes_view_v1 api_key;
    metask_agentcore_bytes_view_v1 base_url;
    metask_agentcore_bytes_view_v1 model;
    uint64_t reserved[4];
} metask_agentcore_completion_config_v1;

typedef struct {
    uint32_t struct_size;
    uint32_t role_code;
    metask_agentcore_bytes_view_v1 text;
    uint64_t reserved[2];
} metask_agentcore_completion_message_v1;

typedef struct {
    uint32_t struct_size;
    uint32_t reserved0;
    const metask_agentcore_completion_message_v1 *messages;
    uint64_t message_count;
    metask_agentcore_bytes_view_v1 system;
    uint64_t reserved[4];
} metask_agentcore_completion_request_v1;

typedef struct {
    uint32_t struct_size;
    uint32_t stop_reason_code;
    metask_agentcore_owned_bytes_v1 text;
    uint64_t input_tokens;
    uint64_t output_tokens;
    uint64_t cache_read_input_tokens;
    uint64_t cache_creation_input_tokens;
    uint64_t reserved[2];
} metask_agentcore_completion_result_v1;

typedef struct {
    uint32_t struct_size;
    uint32_t provider_kind_code;
    metask_agentcore_owned_bytes_v1 model;
    uint64_t reserved[3];
} metask_agentcore_completion_info_v1;

typedef struct {
    uint32_t struct_size;
    uint32_t kind_code;
    metask_agentcore_owned_bytes_v1 payload;
    uint64_t input_tokens;
    uint64_t output_tokens;
    uint64_t cache_read_input_tokens;
    uint64_t cache_creation_input_tokens;
    uint32_t stop_reason_code;
    uint32_t reserved0;
    uint64_t reserved[2];
} metask_agentcore_completion_event_v1;

typedef struct {
    uint32_t struct_size;
    uint32_t kind_code;
    metask_agentcore_bytes_view_v1 text;
    metask_agentcore_bytes_view_v1 skill_id;
    metask_agentcore_bytes_view_v1 catalog_revision;
    metask_agentcore_bytes_view_v1 arguments_json;
    uint64_t reserved[4];
} metask_agentcore_run_input_v1;

typedef struct {
    uint32_t struct_size;
    uint32_t max_turns;
    uint64_t reserved[4];
} metask_agentcore_run_options_v1;

typedef struct {
    uint32_t struct_size;
    uint32_t stop_reason_code;
    uint32_t turns;
    uint32_t tool_calls;
    uint32_t checkpoint_outcome_code;
    uint32_t result_flags;
    uint64_t durable_usage_bytes;
    uint64_t required_checkpoint_bytes;
    uint64_t reserved[4];
} metask_agentcore_run_result_v1;

typedef struct {
    uint32_t struct_size;
    uint32_t outcome_code;
    uint64_t before_context_tokens;
    uint64_t after_context_tokens;
    uint64_t input_tokens;
    uint64_t output_tokens;
    uint64_t cache_read_input_tokens;
    uint64_t cache_creation_input_tokens;
    uint64_t reserved[4];
} metask_agentcore_compact_result_v1;

typedef struct {
    uint32_t struct_size;
    uint32_t reserved0;
    uint64_t hard_bytes;
    uint64_t max_section_bytes;
    uint64_t max_string_bytes;
    uint64_t max_messages;
    uint64_t max_blocks_per_message;
    uint32_t chunk_bytes;
    uint32_t reserved1;
    uint64_t reserved[4];
} metask_agentcore_checkpoint_limits_v1;

typedef uint32_t (*metask_agentcore_checkpoint_write_fn_v1)(
    void *, metask_agentcore_bytes_view_v1);
typedef struct {
    uint32_t struct_size;
    uint32_t reserved0;
    void *ctx;
    metask_agentcore_checkpoint_write_fn_v1 write;
    uint64_t reserved[4];
} metask_agentcore_checkpoint_sink_v1;

typedef uint32_t (*metask_agentcore_checkpoint_read_fn_v1)(
    void *, uint8_t *, uint64_t, uint64_t *);
typedef struct {
    uint32_t struct_size;
    uint32_t reserved0;
    void *ctx;
    metask_agentcore_checkpoint_read_fn_v1 read;
    uint64_t reserved[4];
} metask_agentcore_checkpoint_source_v1;

typedef struct {
    uint32_t struct_size;
    uint32_t reserved0;
    const metask_agentcore_checkpoint_limits_v1 *limits;
    const metask_agentcore_checkpoint_sink_v1 *sink;
    uint64_t reserved[4];
} metask_agentcore_checkpoint_export_config_v1;

typedef struct {
    uint32_t struct_size;
    uint32_t reserved0;
    uint64_t checkpoint_generation;
    uint64_t total_bytes;
    uint64_t chunk_count;
    uint8_t digest[32];
    uint64_t reserved[4];
} metask_agentcore_checkpoint_export_result_v1;

typedef struct {
    uint32_t struct_size;
    uint32_t reserved0;
    const metask_agentcore_session_host_config_v1 *host;
    const metask_agentcore_checkpoint_source_v1 *source;
    const metask_agentcore_checkpoint_limits_v1 *limits;
    uint64_t reserved[4];
} metask_agentcore_session_restore_config_v1;

typedef uint32_t (*metask_agentcore_runtime_create_fn_v1)(
    const metask_agentcore_runtime_config_v1 *,
    const metask_agentcore_runtime_plugin_config_v1 *,
    metask_agentcore_runtime **, metask_agentcore_owned_bytes_v1 *);
typedef uint32_t (*metask_agentcore_runtime_destroy_fn_v1)(
    metask_agentcore_runtime *, metask_agentcore_owned_bytes_v1 *);
typedef uint32_t (*metask_agentcore_runtime_query_skill_catalog_fn_v1)(
    metask_agentcore_runtime *, const metask_agentcore_skill_catalog_query_v1 *,
    metask_agentcore_skill_catalog **, metask_agentcore_owned_bytes_v1 *,
    metask_agentcore_owned_bytes_v1 *);
typedef uint32_t (*metask_agentcore_skill_catalog_release_fn_v1)(
    metask_agentcore_skill_catalog *, metask_agentcore_owned_bytes_v1 *);
typedef uint32_t (*metask_agentcore_completion_create_fn_v1)(
    const metask_agentcore_completion_config_v1 *, metask_agentcore_completion **,
    metask_agentcore_owned_bytes_v1 *);
typedef uint32_t (*metask_agentcore_completion_destroy_fn_v1)(
    metask_agentcore_completion *, metask_agentcore_owned_bytes_v1 *);
typedef uint32_t (*metask_agentcore_completion_describe_fn_v1)(
    metask_agentcore_completion *, metask_agentcore_completion_info_v1 *,
    metask_agentcore_owned_bytes_v1 *);
typedef uint32_t (*metask_agentcore_completion_complete_fn_v1)(
    metask_agentcore_completion *, const metask_agentcore_completion_request_v1 *,
    metask_agentcore_completion_result_v1 *, metask_agentcore_owned_bytes_v1 *);
typedef uint32_t (*metask_agentcore_completion_stream_start_fn_v1)(
    metask_agentcore_completion *, const metask_agentcore_completion_request_v1 *,
    metask_agentcore_completion_stream **, metask_agentcore_owned_bytes_v1 *);
typedef uint32_t (*metask_agentcore_completion_stream_next_fn_v1)(
    metask_agentcore_completion_stream *, metask_agentcore_completion_event_v1 *,
    metask_agentcore_owned_bytes_v1 *);
typedef uint32_t (*metask_agentcore_completion_stream_abort_fn_v1)(
    metask_agentcore_completion_stream *, uint32_t,
    metask_agentcore_owned_bytes_v1 *);
typedef uint32_t (*metask_agentcore_completion_stream_destroy_fn_v1)(
    metask_agentcore_completion_stream *, metask_agentcore_owned_bytes_v1 *);
typedef uint32_t (*metask_agentcore_runtime_refresh_mcp_fn_v1)(
    metask_agentcore_runtime *, uint64_t *, metask_agentcore_owned_bytes_v1 *);
typedef uint32_t (*metask_agentcore_runtime_describe_mcp_fn_v1)(
    metask_agentcore_runtime *, metask_agentcore_owned_bytes_v1 *,
    metask_agentcore_owned_bytes_v1 *);
typedef uint32_t (*metask_agentcore_runtime_apply_mcp_configuration_fn_v1)(
    metask_agentcore_runtime *, const metask_agentcore_mcp_configuration_v1 *,
    metask_agentcore_mcp_apply_report_v1 *, metask_agentcore_owned_bytes_v1 *);
typedef uint32_t (*metask_agentcore_session_create_fn_v1)(
    metask_agentcore_runtime *, const metask_agentcore_session_create_config_v1 *,
    const metask_agentcore_session_callbacks_v1 *, metask_agentcore_session **,
    metask_agentcore_owned_bytes_v1 *);
typedef uint32_t (*metask_agentcore_session_restore_fn_v1)(
    metask_agentcore_runtime *, const metask_agentcore_session_restore_config_v1 *,
    const metask_agentcore_session_callbacks_v1 *, metask_agentcore_session **,
    metask_agentcore_owned_bytes_v1 *, metask_agentcore_owned_bytes_v1 *);
typedef uint32_t (*metask_agentcore_session_destroy_fn_v1)(
    metask_agentcore_session *, metask_agentcore_owned_bytes_v1 *);
typedef uint32_t (*metask_agentcore_session_describe_fn_v1)(
    metask_agentcore_session *, metask_agentcore_owned_bytes_v1 *,
    metask_agentcore_owned_bytes_v1 *);
typedef uint32_t (*metask_agentcore_session_set_model_fn_v1)(
    metask_agentcore_session *, metask_agentcore_bytes_view_v1,
    metask_agentcore_owned_bytes_v1 *);
/* The Skill table exposes this atomic Catalog + Policy transaction as
 * bind_policy. */
typedef uint32_t (*metask_agentcore_session_bind_skills_fn_v1)(
    metask_agentcore_session *, metask_agentcore_skill_catalog *,
    const metask_agentcore_skill_policy_v1 *, metask_agentcore_owned_bytes_v1 *);
typedef uint32_t (*metask_agentcore_session_update_permission_rules_fn_v1)(
    metask_agentcore_session *, const metask_agentcore_permission_rule_set_v1 *,
    metask_agentcore_owned_bytes_v1 *);
typedef uint32_t (*metask_agentcore_session_update_mcp_fn_v1)(
    metask_agentcore_session *, const metask_agentcore_mcp_selection_v1 *,
    metask_agentcore_owned_bytes_v1 *);
typedef uint32_t (*metask_agentcore_session_run_input_fn_v1)(
    metask_agentcore_session *, uint64_t, const metask_agentcore_run_input_v1 *,
    const metask_agentcore_run_options_v1 *, metask_agentcore_run_result_v1 *,
    metask_agentcore_owned_bytes_v1 *);
typedef uint32_t (*metask_agentcore_session_abort_fn_v1)(
    metask_agentcore_session *, uint64_t, uint32_t,
    metask_agentcore_owned_bytes_v1 *);
typedef uint32_t (*metask_agentcore_session_compact_fn_v1)(
    metask_agentcore_session *, uint64_t, metask_agentcore_compact_result_v1 *,
    metask_agentcore_owned_bytes_v1 *);
typedef uint32_t (*metask_agentcore_session_abort_compact_fn_v1)(
    metask_agentcore_session *, uint64_t, metask_agentcore_owned_bytes_v1 *);
typedef uint32_t (*metask_agentcore_session_export_checkpoint_fn_v1)(
    metask_agentcore_session *, const metask_agentcore_checkpoint_export_config_v1 *,
    metask_agentcore_checkpoint_export_result_v1 *, metask_agentcore_owned_bytes_v1 *);
typedef void (*metask_agentcore_buffer_release_fn_v1)(
    metask_agentcore_owned_bytes_v1 *);

/* Function-table order is fixed within Revision 14. No earlier revision layout
 * is accepted, probed, aliased, or dispatched. */
typedef struct metask_agentcore_runtime_api_v1 {
    uint32_t struct_size;
    uint32_t reserved0;
    metask_agentcore_runtime_create_fn_v1 create;
    metask_agentcore_runtime_destroy_fn_v1 destroy;
} metask_agentcore_runtime_api_v1;

typedef struct metask_agentcore_session_api_v1 {
    uint32_t struct_size;
    uint32_t reserved0;
    metask_agentcore_session_create_fn_v1 create;
    metask_agentcore_session_destroy_fn_v1 destroy;
    metask_agentcore_session_run_input_fn_v1 run_input;
    metask_agentcore_session_abort_fn_v1 abort;
} metask_agentcore_session_api_v1;

typedef struct metask_agentcore_session_control_api_v1 {
    uint32_t struct_size;
    uint32_t reserved0;
    metask_agentcore_session_restore_fn_v1 restore;
    metask_agentcore_session_describe_fn_v1 describe;
    metask_agentcore_session_set_model_fn_v1 set_model;
    metask_agentcore_session_update_permission_rules_fn_v1 update_permission_rules;
    metask_agentcore_session_compact_fn_v1 compact;
    metask_agentcore_session_abort_compact_fn_v1 abort_compact;
    metask_agentcore_session_export_checkpoint_fn_v1 export_checkpoint;
} metask_agentcore_session_control_api_v1;

typedef struct metask_agentcore_skill_api_v1 {
    uint32_t struct_size;
    uint32_t reserved0;
    metask_agentcore_runtime_query_skill_catalog_fn_v1 resolve_catalog;
    metask_agentcore_skill_catalog_release_fn_v1 release_catalog;
    metask_agentcore_session_bind_skills_fn_v1 bind_policy;
} metask_agentcore_skill_api_v1;

typedef struct metask_agentcore_mcp_api_v1 {
    uint32_t struct_size;
    uint32_t reserved0;
    metask_agentcore_runtime_apply_mcp_configuration_fn_v1 apply_configuration;
    metask_agentcore_runtime_refresh_mcp_fn_v1 refresh;
    metask_agentcore_runtime_describe_mcp_fn_v1 describe;
    metask_agentcore_session_update_mcp_fn_v1 update_selection;
} metask_agentcore_mcp_api_v1;

typedef struct metask_agentcore_api_v1 {
    uint32_t struct_size;
    uint32_t abi_version;
    uint32_t abi_revision;
    uint32_t reserved0;
    metask_agentcore_buffer_release_fn_v1 buffer_release;
    const metask_agentcore_runtime_api_v1 *runtime;
    const metask_agentcore_session_api_v1 *session;
    const metask_agentcore_session_control_api_v1 *session_control;
    const metask_agentcore_skill_api_v1 *skill;
    const metask_agentcore_mcp_api_v1 *mcp;
} metask_agentcore_api_v1;

/* The final owned-bytes output of AgentCore calls is optional and write-only.
 * Release it before reusing the variable. MCP/tool/UI callback buffers use
 * their paired Host release functions and must never use api->buffer_release. */
const void *metask_agentcore_get_api(uint32_t requested_abi);

static inline metask_agentcore_bytes_view_v1
metask_agentcore_bytes_view_v1_from(const void *ptr, uint64_t len) {
    metask_agentcore_bytes_view_v1 value;
    value.ptr = (const uint8_t *)ptr;
    value.len = len;
    return value;
}

static inline metask_agentcore_owned_bytes_v1
metask_agentcore_owned_bytes_v1_empty(void) {
    metask_agentcore_owned_bytes_v1 value;
    value.ptr = (uint8_t *)0;
    value.len = 0;
    return value;
}

static inline int
metask_agentcore_api_v1_is_compatible(const metask_agentcore_api_v1 *api) {
    return api != (const metask_agentcore_api_v1 *)0 &&
           ((uintptr_t)api % sizeof(void *)) == 0 &&
           api->struct_size == sizeof(*api) &&
           api->abi_version == METASK_AGENTCORE_ABI_V1 &&
           api->abi_revision == METASK_AGENTCORE_ABI_REVISION &&
           api->reserved0 == 0 &&
           api->buffer_release != (metask_agentcore_buffer_release_fn_v1)0 &&
           api->runtime != (const metask_agentcore_runtime_api_v1 *)0 &&
           ((uintptr_t)api->runtime % sizeof(void *)) == 0 &&
           api->runtime->struct_size == sizeof(*api->runtime) &&
           api->runtime->reserved0 == 0 &&
           api->runtime->create != (metask_agentcore_runtime_create_fn_v1)0 &&
           api->runtime->destroy != (metask_agentcore_runtime_destroy_fn_v1)0 &&
           api->session != (const metask_agentcore_session_api_v1 *)0 &&
           ((uintptr_t)api->session % sizeof(void *)) == 0 &&
           api->session->struct_size == sizeof(*api->session) &&
           api->session->reserved0 == 0 &&
           api->session->create != (metask_agentcore_session_create_fn_v1)0 &&
           api->session->destroy != (metask_agentcore_session_destroy_fn_v1)0 &&
           api->session->run_input != (metask_agentcore_session_run_input_fn_v1)0 &&
           api->session->abort != (metask_agentcore_session_abort_fn_v1)0 &&
           api->session_control !=
               (const metask_agentcore_session_control_api_v1 *)0 &&
           ((uintptr_t)api->session_control % sizeof(void *)) == 0 &&
           api->session_control->struct_size == sizeof(*api->session_control) &&
           api->session_control->reserved0 == 0 &&
           api->session_control->restore !=
               (metask_agentcore_session_restore_fn_v1)0 &&
           api->session_control->describe !=
               (metask_agentcore_session_describe_fn_v1)0 &&
           api->session_control->set_model !=
               (metask_agentcore_session_set_model_fn_v1)0 &&
           api->session_control->update_permission_rules !=
               (metask_agentcore_session_update_permission_rules_fn_v1)0 &&
           api->session_control->compact !=
               (metask_agentcore_session_compact_fn_v1)0 &&
           api->session_control->abort_compact !=
               (metask_agentcore_session_abort_compact_fn_v1)0 &&
           api->session_control->export_checkpoint !=
               (metask_agentcore_session_export_checkpoint_fn_v1)0 &&
           api->skill != (const metask_agentcore_skill_api_v1 *)0 &&
           ((uintptr_t)api->skill % sizeof(void *)) == 0 &&
           api->skill->struct_size == sizeof(*api->skill) &&
           api->skill->reserved0 == 0 &&
           api->skill->resolve_catalog !=
               (metask_agentcore_runtime_query_skill_catalog_fn_v1)0 &&
           api->skill->release_catalog !=
               (metask_agentcore_skill_catalog_release_fn_v1)0 &&
           api->skill->bind_policy !=
               (metask_agentcore_session_bind_skills_fn_v1)0 &&
           api->mcp != (const metask_agentcore_mcp_api_v1 *)0 &&
           ((uintptr_t)api->mcp % sizeof(void *)) == 0 &&
           api->mcp->struct_size == sizeof(*api->mcp) &&
           api->mcp->reserved0 == 0 &&
           api->mcp->apply_configuration !=
               (metask_agentcore_runtime_apply_mcp_configuration_fn_v1)0 &&
           api->mcp->refresh != (metask_agentcore_runtime_refresh_mcp_fn_v1)0 &&
           api->mcp->describe != (metask_agentcore_runtime_describe_mcp_fn_v1)0 &&
           api->mcp->update_selection !=
               (metask_agentcore_session_update_mcp_fn_v1)0;
}

static inline const metask_agentcore_api_v1 *
metask_agentcore_api_v1_discover(void) {
    const metask_agentcore_api_v1 *api =
        (const metask_agentcore_api_v1 *)metask_agentcore_get_api(
            METASK_AGENTCORE_ABI_V1);
    return metask_agentcore_api_v1_is_compatible(api) ? api : (const metask_agentcore_api_v1 *)0;
}

static inline void
metask_agentcore_owned_bytes_v1_release(
    const metask_agentcore_api_v1 *api,
    metask_agentcore_owned_bytes_v1 *value) {
    if (api != (const metask_agentcore_api_v1 *)0 &&
        api->buffer_release != (metask_agentcore_buffer_release_fn_v1)0 &&
        value != (metask_agentcore_owned_bytes_v1 *)0) {
        api->buffer_release(value);
    }
}

#if defined(__cplusplus) && __cplusplus >= 201103L
#define METASK_AGENTCORE_STATIC_ASSERT(condition, message) static_assert((condition), message)
#elif defined(__STDC_VERSION__) && __STDC_VERSION__ >= 201112L
#define METASK_AGENTCORE_STATIC_ASSERT(condition, message) _Static_assert((condition), message)
#else
#define METASK_AGENTCORE_STATIC_ASSERT(condition, message)
#endif

#define METASK_AGENTCORE_ASSERT_SIZE(type, size) \
    METASK_AGENTCORE_STATIC_ASSERT(sizeof(type) == (size), #type " layout")
#define METASK_AGENTCORE_ASSERT_OFFSET(type, field, offset) \
    METASK_AGENTCORE_STATIC_ASSERT(offsetof(type, field) == (offset), #type "." #field " offset")

METASK_AGENTCORE_STATIC_ASSERT(METASK_AGENTCORE_ABI_REVISION == 14u,
                               "AgentCore revision 14");
METASK_AGENTCORE_STATIC_ASSERT(METASK_AGENTCORE_MCP_NEGOTIATION_AUTO == 1u,
                               "MCP auto code");
METASK_AGENTCORE_STATIC_ASSERT(METASK_AGENTCORE_MCP_NEGOTIATION_MODERN_ONLY == 2u,
                               "MCP modern-only code");
METASK_AGENTCORE_STATIC_ASSERT(METASK_AGENTCORE_MCP_NEGOTIATION_LEGACY_ONLY == 3u,
                               "MCP legacy-only code");
METASK_AGENTCORE_STATIC_ASSERT(METASK_AGENTCORE_MCP_NEGOTIATION_LEGACY_2025_06_ONLY == 4u,
                               "MCP 2025-06-only code");
METASK_AGENTCORE_STATIC_ASSERT(METASK_AGENTCORE_MCP_ERA_2026_07_28 == 1u &&
                                   METASK_AGENTCORE_MCP_ERA_2025_11_25 == 2u &&
                                   METASK_AGENTCORE_MCP_ERA_2025_06_18 == 3u,
                               "MCP era codes");
METASK_AGENTCORE_STATIC_ASSERT(METASK_AGENTCORE_MCP_APPLY_APPLIED == 1u &&
                                   METASK_AGENTCORE_MCP_APPLY_SUPERSEDED == 2u &&
                                   METASK_AGENTCORE_MCP_APPLY_REJECTED == 3u,
                               "MCP apply disposition codes");

METASK_AGENTCORE_ASSERT_SIZE(metask_agentcore_bytes_view_v1, 16);
METASK_AGENTCORE_ASSERT_SIZE(metask_agentcore_owned_bytes_v1, 16);
METASK_AGENTCORE_ASSERT_SIZE(metask_agentcore_run_context_v1, 56);
METASK_AGENTCORE_ASSERT_SIZE(metask_agentcore_host_tool_v1, 96);
METASK_AGENTCORE_ASSERT_SIZE(metask_agentcore_host_result_sink_v1, 56);
METASK_AGENTCORE_ASSERT_SIZE(metask_agentcore_host_stream_tool_v1, 96);
METASK_AGENTCORE_ASSERT_SIZE(metask_agentcore_mcp_cancellation_v1, 40);
METASK_AGENTCORE_ASSERT_SIZE(metask_agentcore_mcp_response_v1, 40);
METASK_AGENTCORE_ASSERT_SIZE(metask_agentcore_mcp_connector_v1, 88);
METASK_AGENTCORE_ASSERT_SIZE(metask_agentcore_mcp_protocol_limits_v1, 96);
METASK_AGENTCORE_ASSERT_SIZE(metask_agentcore_mcp_server_v1, 232);
METASK_AGENTCORE_ASSERT_SIZE(metask_agentcore_mcp_configuration_v1, 64);
METASK_AGENTCORE_ASSERT_SIZE(metask_agentcore_mcp_apply_report_v1, 64);
METASK_AGENTCORE_ASSERT_SIZE(metask_agentcore_mcp_catalog_limits_v1, 64);
METASK_AGENTCORE_ASSERT_SIZE(metask_agentcore_runtime_config_v1, 96);
METASK_AGENTCORE_ASSERT_SIZE(metask_agentcore_process_plugin_source_v1, 48);
METASK_AGENTCORE_ASSERT_SIZE(metask_agentcore_runtime_plugin_config_v1, 72);
METASK_AGENTCORE_ASSERT_SIZE(metask_agentcore_session_callbacks_v1, 72);
METASK_AGENTCORE_ASSERT_SIZE(metask_agentcore_skill_policy_v1, 56);
METASK_AGENTCORE_ASSERT_SIZE(metask_agentcore_permission_rule_set_v1, 88);
METASK_AGENTCORE_ASSERT_SIZE(metask_agentcore_mcp_selector_v1, 80);
METASK_AGENTCORE_ASSERT_SIZE(metask_agentcore_mcp_selection_v1, 56);
METASK_AGENTCORE_ASSERT_SIZE(metask_agentcore_durable_budget_profile_v1, 112);
METASK_AGENTCORE_ASSERT_SIZE(metask_agentcore_session_host_config_v1, 168);
METASK_AGENTCORE_ASSERT_SIZE(metask_agentcore_session_create_config_v1, 64);
METASK_AGENTCORE_ASSERT_SIZE(metask_agentcore_skill_source_v1, 64);
METASK_AGENTCORE_ASSERT_SIZE(metask_agentcore_skill_catalog_query_v1, 80);
METASK_AGENTCORE_ASSERT_SIZE(metask_agentcore_completion_config_v1, 88);
METASK_AGENTCORE_ASSERT_SIZE(metask_agentcore_completion_message_v1, 40);
METASK_AGENTCORE_ASSERT_SIZE(metask_agentcore_completion_request_v1, 72);
METASK_AGENTCORE_ASSERT_SIZE(metask_agentcore_completion_result_v1, 72);
METASK_AGENTCORE_ASSERT_SIZE(metask_agentcore_completion_info_v1, 48);
METASK_AGENTCORE_ASSERT_SIZE(metask_agentcore_completion_event_v1, 80);
METASK_AGENTCORE_ASSERT_SIZE(metask_agentcore_run_input_v1, 104);
METASK_AGENTCORE_ASSERT_SIZE(metask_agentcore_run_options_v1, 40);
METASK_AGENTCORE_ASSERT_SIZE(metask_agentcore_run_result_v1, 72);
METASK_AGENTCORE_ASSERT_SIZE(metask_agentcore_compact_result_v1, 88);
METASK_AGENTCORE_ASSERT_SIZE(metask_agentcore_checkpoint_limits_v1, 88);
METASK_AGENTCORE_ASSERT_SIZE(metask_agentcore_checkpoint_sink_v1, 56);
METASK_AGENTCORE_ASSERT_SIZE(metask_agentcore_checkpoint_source_v1, 56);
METASK_AGENTCORE_ASSERT_SIZE(metask_agentcore_checkpoint_export_config_v1, 56);
METASK_AGENTCORE_ASSERT_SIZE(metask_agentcore_checkpoint_export_result_v1, 96);
METASK_AGENTCORE_ASSERT_SIZE(metask_agentcore_session_restore_config_v1, 64);
METASK_AGENTCORE_ASSERT_SIZE(metask_agentcore_runtime_api_v1, 24);
METASK_AGENTCORE_ASSERT_SIZE(metask_agentcore_session_api_v1, 40);
METASK_AGENTCORE_ASSERT_SIZE(metask_agentcore_session_control_api_v1, 64);
METASK_AGENTCORE_ASSERT_SIZE(metask_agentcore_skill_api_v1, 32);
METASK_AGENTCORE_ASSERT_SIZE(metask_agentcore_mcp_api_v1, 40);
METASK_AGENTCORE_ASSERT_SIZE(metask_agentcore_api_v1, 64);

METASK_AGENTCORE_ASSERT_OFFSET(metask_agentcore_run_context_v1, session, 8);
METASK_AGENTCORE_ASSERT_OFFSET(metask_agentcore_run_context_v1, run_id, 16);
METASK_AGENTCORE_ASSERT_OFFSET(metask_agentcore_run_context_v1, session_id, 24);
METASK_AGENTCORE_ASSERT_OFFSET(metask_agentcore_host_tool_v1, ctx, 8);
METASK_AGENTCORE_ASSERT_OFFSET(metask_agentcore_host_result_sink_v1, ctx, 8);
METASK_AGENTCORE_ASSERT_OFFSET(metask_agentcore_host_stream_tool_v1, ctx, 8);
METASK_AGENTCORE_ASSERT_OFFSET(metask_agentcore_mcp_connector_v1, ctx, 8);
METASK_AGENTCORE_ASSERT_OFFSET(metask_agentcore_mcp_response_v1, body, 8);
METASK_AGENTCORE_ASSERT_OFFSET(metask_agentcore_mcp_response_v1, reserved, 24);
METASK_AGENTCORE_ASSERT_OFFSET(metask_agentcore_mcp_server_v1, connector, 104);
METASK_AGENTCORE_ASSERT_OFFSET(metask_agentcore_mcp_server_v1, protocol_limits, 192);
METASK_AGENTCORE_ASSERT_OFFSET(metask_agentcore_mcp_server_v1, configuration_fingerprint, 200);
METASK_AGENTCORE_ASSERT_OFFSET(metask_agentcore_runtime_config_v1, mcp_servers, 40);
METASK_AGENTCORE_ASSERT_OFFSET(metask_agentcore_runtime_config_v1, mcp_catalog_limits, 56);
METASK_AGENTCORE_ASSERT_OFFSET(metask_agentcore_process_plugin_source_v1, root, 8);
METASK_AGENTCORE_ASSERT_OFFSET(metask_agentcore_runtime_plugin_config_v1, process_plugins, 8);
METASK_AGENTCORE_ASSERT_OFFSET(metask_agentcore_runtime_plugin_config_v1, host_stream_tools, 24);
METASK_AGENTCORE_ASSERT_OFFSET(metask_agentcore_session_host_config_v1, api_key, 16);
METASK_AGENTCORE_ASSERT_OFFSET(metask_agentcore_session_host_config_v1, allowed_tools, 80);
METASK_AGENTCORE_ASSERT_OFFSET(metask_agentcore_session_host_config_v1, skill_catalog, 96);
METASK_AGENTCORE_ASSERT_OFFSET(metask_agentcore_session_host_config_v1, skill_policy, 104);
METASK_AGENTCORE_ASSERT_OFFSET(metask_agentcore_session_host_config_v1, permission_rules, 112);
METASK_AGENTCORE_ASSERT_OFFSET(metask_agentcore_session_host_config_v1, mcp_selection, 120);
METASK_AGENTCORE_ASSERT_OFFSET(metask_agentcore_session_host_config_v1, durable_budget, 128);
METASK_AGENTCORE_ASSERT_OFFSET(metask_agentcore_session_host_config_v1, run_journal_mode_code, 136);
METASK_AGENTCORE_ASSERT_OFFSET(metask_agentcore_session_host_config_v1, reserved0, 140);
METASK_AGENTCORE_ASSERT_OFFSET(metask_agentcore_session_host_config_v1, reserved, 144);
METASK_AGENTCORE_ASSERT_OFFSET(metask_agentcore_session_create_config_v1, host, 8);
METASK_AGENTCORE_ASSERT_OFFSET(metask_agentcore_session_create_config_v1, model, 16);
METASK_AGENTCORE_ASSERT_OFFSET(metask_agentcore_skill_catalog_query_v1, additional_sources, 56);
METASK_AGENTCORE_ASSERT_OFFSET(metask_agentcore_skill_catalog_query_v1, additional_source_count, 64);
METASK_AGENTCORE_ASSERT_OFFSET(metask_agentcore_mcp_selector_v1, tool_name, 40);
METASK_AGENTCORE_ASSERT_OFFSET(metask_agentcore_run_result_v1, durable_usage_bytes, 24);
METASK_AGENTCORE_ASSERT_OFFSET(metask_agentcore_run_result_v1, required_checkpoint_bytes, 32);
METASK_AGENTCORE_ASSERT_OFFSET(metask_agentcore_checkpoint_export_result_v1, digest, 32);
METASK_AGENTCORE_ASSERT_OFFSET(metask_agentcore_api_v1, buffer_release, 16);
METASK_AGENTCORE_ASSERT_OFFSET(metask_agentcore_api_v1, runtime, 24);
METASK_AGENTCORE_ASSERT_OFFSET(metask_agentcore_api_v1, session, 32);
METASK_AGENTCORE_ASSERT_OFFSET(metask_agentcore_api_v1, session_control, 40);
METASK_AGENTCORE_ASSERT_OFFSET(metask_agentcore_api_v1, skill, 48);
METASK_AGENTCORE_ASSERT_OFFSET(metask_agentcore_api_v1, mcp, 56);

#undef METASK_AGENTCORE_ASSERT_OFFSET
#undef METASK_AGENTCORE_ASSERT_SIZE
#undef METASK_AGENTCORE_STATIC_ASSERT

#ifdef __cplusplus
}
#endif

#endif
