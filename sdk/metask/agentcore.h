#ifndef METASK_AGENTCORE_H
#define METASK_AGENTCORE_H

#include <stddef.h>
#include <stdint.h>

#if !defined(UINTPTR_MAX) || !defined(UINT64_MAX) || UINTPTR_MAX != UINT64_MAX
#error "AgentCore ABI v1 revision 7 requires a 64-bit pointer ABI"
#endif

#ifdef __cplusplus
extern "C" {
#endif

/* sdk/zig/types.zig is the normative fixed-layout schema. This header is its
 * Revision 7 C projection; sdk/rust/src/raw.rs is generated from this file.
 * AgentCore ABI v1 remains experimental. Consumers pin an exact bundle and
 * must validate version, revision, table size, and capabilities together. */
#define METASK_AGENTCORE_ABI_V1 1u
#define METASK_AGENTCORE_ABI_REVISION 7u

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
#define METASK_AGENTCORE_MAX_TURNS_V1 1000u

#define METASK_AGENTCORE_RUN_INPUT_TEXT 1u
#define METASK_AGENTCORE_RUN_INPUT_SKILL 2u
#define METASK_AGENTCORE_SKILL_SELECTION_DISABLED 1u
#define METASK_AGENTCORE_SKILL_SELECTION_ENABLED 2u
#define METASK_AGENTCORE_COMPACT_COMPACTED 1u
#define METASK_AGENTCORE_COMPACT_NO_CHANGE 2u
#define METASK_AGENTCORE_COMPACT_DEGRADED 3u
#define METASK_AGENTCORE_COMPACT_ABORTED 4u
#define METASK_AGENTCORE_RUN_CHECKPOINT_NONE 0u
#define METASK_AGENTCORE_RUN_CHECKPOINT_BUDGET_REQUIRED 1u
#define METASK_AGENTCORE_RUN_CHECKPOINT_BUDGET_EXHAUSTED 2u
#define METASK_AGENTCORE_RUN_CHECKPOINT_RESOURCE_LIMIT 3u
#define METASK_AGENTCORE_RUN_RESULT_COMPACTION_RECOMMENDED (1u << 0)

#define METASK_AGENTCORE_MCP_TRANSPORT_STDIO 1u
#define METASK_AGENTCORE_MCP_TRANSPORT_STREAMABLE_HTTP 2u
#define METASK_AGENTCORE_MCP_NEGOTIATION_AUTO 1u
#define METASK_AGENTCORE_MCP_NEGOTIATION_MODERN_ONLY 2u
#define METASK_AGENTCORE_MCP_NEGOTIATION_LEGACY_ONLY 3u
#define METASK_AGENTCORE_MCP_NEGOTIATION_LEGACY_2025_06_ONLY 4u
#define METASK_AGENTCORE_MCP_ERA_2026_07_28 1u
#define METASK_AGENTCORE_MCP_ERA_2025_11_25 2u
#define METASK_AGENTCORE_MCP_ERA_2025_06_18 3u
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
#define METASK_AGENTCORE_MCP_NOTIFY_TIMEOUT 1u
#define METASK_AGENTCORE_MCP_NOTIFY_NETWORK_ERROR 2u
#define METASK_AGENTCORE_MCP_NOTIFY_AUTH_ERROR 3u
#define METASK_AGENTCORE_MCP_NOTIFY_SERVER_ERROR 4u
#define METASK_AGENTCORE_MCP_NOTIFY_CHILD_EXIT 5u
#define METASK_AGENTCORE_MCP_NOTIFY_CANCELLED 6u
#define METASK_AGENTCORE_MCP_NOTIFY_FATAL 7u
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

#define METASK_AGENTCORE_CAP_RUNTIME (1ULL << 0)
#define METASK_AGENTCORE_CAP_BUILTIN_TOOLS (1ULL << 1)
#define METASK_AGENTCORE_CAP_HOST_SYNC_TOOLS (1ULL << 2)
#define METASK_AGENTCORE_CAP_HOST_UI (1ULL << 3)
#define METASK_AGENTCORE_CAP_CORE_EVENTS_JSON (1ULL << 4)
#define METASK_AGENTCORE_CAP_ABORT (1ULL << 5)
#define METASK_AGENTCORE_CAP_SKILL_CATALOG (1ULL << 6)
#define METASK_AGENTCORE_CAP_TYPED_RUN_INPUT (1ULL << 7)
#define METASK_AGENTCORE_CAP_SESSION_MODEL_MUTATION (1ULL << 8)
#define METASK_AGENTCORE_CAP_MANUAL_COMPACT (1ULL << 9)
#define METASK_AGENTCORE_CAP_SKILL_SELECTION (1ULL << 10)
#define METASK_AGENTCORE_CAP_HOST_PERMISSION_RULES (1ULL << 11)
#define METASK_AGENTCORE_CAP_SESSION_CHECKPOINT (1ULL << 12)
#define METASK_AGENTCORE_CAP_SESSION_RESTORE (1ULL << 13)
#define METASK_AGENTCORE_CAP_SESSION_DESCRIBE (1ULL << 14)
#define METASK_AGENTCORE_CAP_MCP_RUNTIME_CATALOG (1ULL << 15)
#define METASK_AGENTCORE_CAP_MCP_SESSION_SELECTION (1ULL << 16)
#define METASK_AGENTCORE_CAP_DURABLE_BUDGET (1ULL << 17)
#define METASK_AGENTCORE_CAP_SESSION_PERMISSION_AUTHORITY (1ULL << 18)
#define METASK_AGENTCORE_REQUIRED_CAPABILITIES_V1 ((1ULL << 19) - 1ULL)

typedef struct metask_agentcore_runtime metask_agentcore_runtime;
typedef struct metask_agentcore_session metask_agentcore_session;
typedef struct metask_agentcore_skill_catalog metask_agentcore_skill_catalog;

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

typedef uint32_t (*metask_agentcore_mcp_is_cancelled_fn_v1)(const void *);
typedef struct {
    uint32_t struct_size;
    uint32_t reserved0;
    const void *ctx;
    metask_agentcore_mcp_is_cancelled_fn_v1 is_cancelled;
    uint64_t reserved[2];
} metask_agentcore_mcp_cancellation_v1;

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
    metask_agentcore_owned_bytes_v1 *);
typedef uint32_t (*metask_agentcore_mcp_notify_fn_v1)(
    void *, void *, metask_agentcore_bytes_view_v1, uint32_t,
    const metask_agentcore_mcp_cancellation_v1 *);
typedef void (*metask_agentcore_mcp_close_fn_v1)(void *, void *);
typedef void (*metask_agentcore_mcp_release_response_fn_v1)(
    void *, void *, metask_agentcore_owned_bytes_v1 *);

/* Host owns connector ctx, credentials, and live connection contexts. Every
 * successful open is closed exactly once. Every non-empty response descriptor
 * is released exactly once, independent of request status. AgentCore copies
 * successful response bytes before release. */
typedef struct {
    uint32_t struct_size;
    uint32_t reserved0;
    void *ctx;
    metask_agentcore_mcp_open_fn_v1 open;
    metask_agentcore_mcp_request_fn_v1 request;
    metask_agentcore_mcp_notify_fn_v1 notify;
    metask_agentcore_mcp_close_fn_v1 close;
    metask_agentcore_mcp_release_response_fn_v1 release_response;
    uint64_t reserved[3];
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
    uint64_t reserved[4];
} metask_agentcore_mcp_server_v1;

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

typedef struct {
    uint32_t struct_size;
    uint32_t default_state_code;
    const metask_agentcore_bytes_view_v1 *exception_skill_ids;
    uint64_t exception_skill_id_count;
    uint64_t reserved[4];
} metask_agentcore_skill_selection_v1;

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
    const metask_agentcore_skill_selection_v1 *skill_selection;
    const metask_agentcore_permission_rule_set_v1 *permission_rules;
    const metask_agentcore_mcp_selection_v1 *mcp_selection;
    const metask_agentcore_durable_budget_profile_v1 *durable_budget;
    uint64_t reserved[4];
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
    uint32_t reserved0;
    metask_agentcore_bytes_view_v1 workspace_root;
    metask_agentcore_bytes_view_v1 workspace_home;
    metask_agentcore_bytes_view_v1 workspace_epoch;
    uint64_t reserved[3];
} metask_agentcore_skill_catalog_query_v1;

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
    const metask_agentcore_runtime_config_v1 *, metask_agentcore_runtime **,
    metask_agentcore_owned_bytes_v1 *);
typedef uint32_t (*metask_agentcore_runtime_destroy_fn_v1)(
    metask_agentcore_runtime *, metask_agentcore_owned_bytes_v1 *);
typedef uint32_t (*metask_agentcore_runtime_query_skill_catalog_fn_v1)(
    metask_agentcore_runtime *, const metask_agentcore_skill_catalog_query_v1 *,
    metask_agentcore_skill_catalog **, metask_agentcore_owned_bytes_v1 *,
    metask_agentcore_owned_bytes_v1 *);
typedef uint32_t (*metask_agentcore_skill_catalog_release_fn_v1)(
    metask_agentcore_skill_catalog *, metask_agentcore_owned_bytes_v1 *);
typedef uint32_t (*metask_agentcore_runtime_refresh_mcp_fn_v1)(
    metask_agentcore_runtime *, uint64_t *, metask_agentcore_owned_bytes_v1 *);
typedef uint32_t (*metask_agentcore_runtime_describe_mcp_fn_v1)(
    metask_agentcore_runtime *, metask_agentcore_owned_bytes_v1 *,
    metask_agentcore_owned_bytes_v1 *);
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
typedef uint32_t (*metask_agentcore_session_update_skills_fn_v1)(
    metask_agentcore_session *, metask_agentcore_skill_catalog *,
    const metask_agentcore_skill_selection_v1 *, metask_agentcore_owned_bytes_v1 *);
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

/* Function-table order is fixed within Revision 7. No earlier revision layout
 * is accepted, probed, aliased, or dispatched. */
typedef struct {
    uint32_t struct_size;
    uint32_t abi_version;
    uint32_t abi_revision;
    uint32_t reserved0;
    uint64_t capabilities;
    metask_agentcore_runtime_create_fn_v1 runtime_create;
    metask_agentcore_runtime_destroy_fn_v1 runtime_destroy;
    metask_agentcore_runtime_query_skill_catalog_fn_v1 runtime_query_skill_catalog;
    metask_agentcore_skill_catalog_release_fn_v1 skill_catalog_release;
    metask_agentcore_runtime_refresh_mcp_fn_v1 runtime_refresh_mcp;
    metask_agentcore_runtime_describe_mcp_fn_v1 runtime_describe_mcp;
    metask_agentcore_session_create_fn_v1 session_create;
    metask_agentcore_session_restore_fn_v1 session_restore;
    metask_agentcore_session_destroy_fn_v1 session_destroy;
    metask_agentcore_session_describe_fn_v1 session_describe;
    metask_agentcore_session_set_model_fn_v1 session_set_model;
    metask_agentcore_session_update_skills_fn_v1 session_update_skills;
    metask_agentcore_session_update_permission_rules_fn_v1 session_update_permission_rules;
    metask_agentcore_session_update_mcp_fn_v1 session_update_mcp;
    metask_agentcore_session_run_input_fn_v1 session_run_input;
    metask_agentcore_session_abort_fn_v1 session_abort;
    metask_agentcore_session_compact_fn_v1 session_compact;
    metask_agentcore_session_abort_compact_fn_v1 session_abort_compact;
    metask_agentcore_session_export_checkpoint_fn_v1 session_export_checkpoint;
    metask_agentcore_buffer_release_fn_v1 buffer_release;
    uint64_t reserved[4];
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
    return api != (const metask_agentcore_api_v1 *)0 && api->struct_size == sizeof(*api) &&
           api->abi_version == METASK_AGENTCORE_ABI_V1 &&
           api->abi_revision == METASK_AGENTCORE_ABI_REVISION &&
           api->reserved0 == 0 &&
           api->capabilities == METASK_AGENTCORE_REQUIRED_CAPABILITIES_V1 &&
           api->runtime_create != (metask_agentcore_runtime_create_fn_v1)0 &&
           api->runtime_destroy != (metask_agentcore_runtime_destroy_fn_v1)0 &&
           api->runtime_query_skill_catalog !=
               (metask_agentcore_runtime_query_skill_catalog_fn_v1)0 &&
           api->skill_catalog_release !=
               (metask_agentcore_skill_catalog_release_fn_v1)0 &&
           api->runtime_refresh_mcp !=
               (metask_agentcore_runtime_refresh_mcp_fn_v1)0 &&
           api->runtime_describe_mcp !=
               (metask_agentcore_runtime_describe_mcp_fn_v1)0 &&
           api->session_create != (metask_agentcore_session_create_fn_v1)0 &&
           api->session_restore != (metask_agentcore_session_restore_fn_v1)0 &&
           api->session_destroy != (metask_agentcore_session_destroy_fn_v1)0 &&
           api->session_describe != (metask_agentcore_session_describe_fn_v1)0 &&
           api->session_set_model != (metask_agentcore_session_set_model_fn_v1)0 &&
           api->session_update_skills !=
               (metask_agentcore_session_update_skills_fn_v1)0 &&
           api->session_update_permission_rules !=
               (metask_agentcore_session_update_permission_rules_fn_v1)0 &&
           api->session_update_mcp !=
               (metask_agentcore_session_update_mcp_fn_v1)0 &&
           api->session_run_input != (metask_agentcore_session_run_input_fn_v1)0 &&
           api->session_abort != (metask_agentcore_session_abort_fn_v1)0 &&
           api->session_compact != (metask_agentcore_session_compact_fn_v1)0 &&
           api->session_abort_compact !=
               (metask_agentcore_session_abort_compact_fn_v1)0 &&
           api->session_export_checkpoint !=
               (metask_agentcore_session_export_checkpoint_fn_v1)0 &&
           api->buffer_release != (metask_agentcore_buffer_release_fn_v1)0 &&
           api->reserved[0] == 0 && api->reserved[1] == 0 &&
           api->reserved[2] == 0 && api->reserved[3] == 0;
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

METASK_AGENTCORE_STATIC_ASSERT(METASK_AGENTCORE_ABI_REVISION == 7u,
                               "AgentCore revision 7");
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

METASK_AGENTCORE_ASSERT_SIZE(metask_agentcore_bytes_view_v1, 16);
METASK_AGENTCORE_ASSERT_SIZE(metask_agentcore_owned_bytes_v1, 16);
METASK_AGENTCORE_ASSERT_SIZE(metask_agentcore_run_context_v1, 56);
METASK_AGENTCORE_ASSERT_SIZE(metask_agentcore_host_tool_v1, 96);
METASK_AGENTCORE_ASSERT_SIZE(metask_agentcore_mcp_cancellation_v1, 40);
METASK_AGENTCORE_ASSERT_SIZE(metask_agentcore_mcp_connector_v1, 80);
METASK_AGENTCORE_ASSERT_SIZE(metask_agentcore_mcp_protocol_limits_v1, 96);
METASK_AGENTCORE_ASSERT_SIZE(metask_agentcore_mcp_server_v1, 224);
METASK_AGENTCORE_ASSERT_SIZE(metask_agentcore_mcp_catalog_limits_v1, 64);
METASK_AGENTCORE_ASSERT_SIZE(metask_agentcore_runtime_config_v1, 96);
METASK_AGENTCORE_ASSERT_SIZE(metask_agentcore_session_callbacks_v1, 72);
METASK_AGENTCORE_ASSERT_SIZE(metask_agentcore_skill_selection_v1, 56);
METASK_AGENTCORE_ASSERT_SIZE(metask_agentcore_permission_rule_set_v1, 88);
METASK_AGENTCORE_ASSERT_SIZE(metask_agentcore_mcp_selector_v1, 80);
METASK_AGENTCORE_ASSERT_SIZE(metask_agentcore_mcp_selection_v1, 56);
METASK_AGENTCORE_ASSERT_SIZE(metask_agentcore_durable_budget_profile_v1, 112);
METASK_AGENTCORE_ASSERT_SIZE(metask_agentcore_session_host_config_v1, 168);
METASK_AGENTCORE_ASSERT_SIZE(metask_agentcore_session_create_config_v1, 64);
METASK_AGENTCORE_ASSERT_SIZE(metask_agentcore_skill_catalog_query_v1, 80);
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
METASK_AGENTCORE_ASSERT_SIZE(metask_agentcore_api_v1, 216);

METASK_AGENTCORE_ASSERT_OFFSET(metask_agentcore_run_context_v1, session, 8);
METASK_AGENTCORE_ASSERT_OFFSET(metask_agentcore_run_context_v1, run_id, 16);
METASK_AGENTCORE_ASSERT_OFFSET(metask_agentcore_run_context_v1, session_id, 24);
METASK_AGENTCORE_ASSERT_OFFSET(metask_agentcore_host_tool_v1, ctx, 8);
METASK_AGENTCORE_ASSERT_OFFSET(metask_agentcore_mcp_connector_v1, ctx, 8);
METASK_AGENTCORE_ASSERT_OFFSET(metask_agentcore_mcp_server_v1, connector, 104);
METASK_AGENTCORE_ASSERT_OFFSET(metask_agentcore_mcp_server_v1, protocol_limits, 184);
METASK_AGENTCORE_ASSERT_OFFSET(metask_agentcore_runtime_config_v1, mcp_servers, 40);
METASK_AGENTCORE_ASSERT_OFFSET(metask_agentcore_runtime_config_v1, mcp_catalog_limits, 56);
METASK_AGENTCORE_ASSERT_OFFSET(metask_agentcore_session_host_config_v1, api_key, 16);
METASK_AGENTCORE_ASSERT_OFFSET(metask_agentcore_session_host_config_v1, allowed_tools, 80);
METASK_AGENTCORE_ASSERT_OFFSET(metask_agentcore_session_host_config_v1, skill_catalog, 96);
METASK_AGENTCORE_ASSERT_OFFSET(metask_agentcore_session_host_config_v1, skill_selection, 104);
METASK_AGENTCORE_ASSERT_OFFSET(metask_agentcore_session_host_config_v1, permission_rules, 112);
METASK_AGENTCORE_ASSERT_OFFSET(metask_agentcore_session_host_config_v1, mcp_selection, 120);
METASK_AGENTCORE_ASSERT_OFFSET(metask_agentcore_session_host_config_v1, durable_budget, 128);
METASK_AGENTCORE_ASSERT_OFFSET(metask_agentcore_session_create_config_v1, host, 8);
METASK_AGENTCORE_ASSERT_OFFSET(metask_agentcore_session_create_config_v1, model, 16);
METASK_AGENTCORE_ASSERT_OFFSET(metask_agentcore_mcp_selector_v1, tool_name, 40);
METASK_AGENTCORE_ASSERT_OFFSET(metask_agentcore_run_result_v1, durable_usage_bytes, 24);
METASK_AGENTCORE_ASSERT_OFFSET(metask_agentcore_run_result_v1, required_checkpoint_bytes, 32);
METASK_AGENTCORE_ASSERT_OFFSET(metask_agentcore_checkpoint_export_result_v1, digest, 32);
METASK_AGENTCORE_ASSERT_OFFSET(metask_agentcore_api_v1, runtime_refresh_mcp, 56);
METASK_AGENTCORE_ASSERT_OFFSET(metask_agentcore_api_v1, session_create, 72);
METASK_AGENTCORE_ASSERT_OFFSET(metask_agentcore_api_v1, session_restore, 80);
METASK_AGENTCORE_ASSERT_OFFSET(metask_agentcore_api_v1, session_set_model, 104);
METASK_AGENTCORE_ASSERT_OFFSET(metask_agentcore_api_v1, session_update_mcp, 128);
METASK_AGENTCORE_ASSERT_OFFSET(metask_agentcore_api_v1, session_run_input, 136);
METASK_AGENTCORE_ASSERT_OFFSET(metask_agentcore_api_v1, session_export_checkpoint, 168);
METASK_AGENTCORE_ASSERT_OFFSET(metask_agentcore_api_v1, buffer_release, 176);
METASK_AGENTCORE_ASSERT_OFFSET(metask_agentcore_api_v1, reserved, 184);

#undef METASK_AGENTCORE_ASSERT_OFFSET
#undef METASK_AGENTCORE_ASSERT_SIZE
#undef METASK_AGENTCORE_STATIC_ASSERT

#ifdef __cplusplus
}
#endif

#endif
