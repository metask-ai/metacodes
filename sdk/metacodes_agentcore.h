#ifndef METACODES_AGENTCORE_H
#define METACODES_AGENTCORE_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#define MC_AGENTCORE_ABI_V1 1u

#define MC_STATUS_OK 0u
#define MC_STATUS_INVALID_ARGUMENT 1u
#define MC_STATUS_OUT_OF_MEMORY 2u
#define MC_STATUS_BUSY 3u
#define MC_STATUS_STALE_RUN 4u
#define MC_STATUS_TOO_LATE 5u
#define MC_STATUS_INVALID_STATE 6u
#define MC_STATUS_CORE_ERROR 7u
#define MC_STATUS_CALLBACK_FAILED 8u
#define MC_STATUS_INTERNAL_ERROR 9u

#define MC_PROVIDER_ANTHROPIC 1u
#define MC_PROVIDER_OPENAI 2u
#define MC_PROVIDER_GEMINI 3u
#define MC_PERMISSION_DEFAULT 1u
#define MC_PERMISSION_ACCEPT_EDITS 2u
#define MC_PERMISSION_PLAN 3u
#define MC_PERMISSION_AUTO 4u
#define MC_PERMISSION_DONT_ASK 5u
#define MC_PERMISSION_BYPASS 6u
#define MC_SHELL_DISABLED 1u
#define MC_SHELL_SANDBOXED 2u
#define MC_SHELL_UNRESTRICTED 3u
#define MC_ABORT_USER_REQUEST 1u
#define MC_ABORT_TIMEOUT 2u

#define MC_STOP_INVALID 0u
#define MC_STOP_END_TURN 1u
#define MC_STOP_MAX_TURNS 2u
#define MC_STOP_ABORTED 3u
#define MC_STOP_TOOL_ERROR 4u
#define MC_STOP_API_ERROR 5u
#define MC_STOP_TOOL_LOOP 6u
#define MC_STOP_SUSPENDED 7u
#define MC_STOP_BACKGROUNDED 8u
#define MC_STOP_BUDGET 9u

#define MC_CALLBACK_CONTINUE 0u
#define MC_CALLBACK_FATAL 1u
#define MC_UI_ANSWERED 0u
#define MC_UI_UNAVAILABLE 1u
#define MC_UI_FATAL 2u
#define MC_HOST_OK 0u
#define MC_HOST_FAILED 1u
#define MC_HOST_REJECTED 2u

#define MC_CAP_RUNTIME (UINT64_C(1) << 0)
#define MC_CAP_BUILTIN_TOOLS (UINT64_C(1) << 1)
#define MC_CAP_HOST_SYNC_TOOLS (UINT64_C(1) << 2)
#define MC_CAP_HOST_UI (UINT64_C(1) << 3)
#define MC_CAP_CORE_EVENTS_JSON (UINT64_C(1) << 4)
#define MC_CAP_ABORT (UINT64_C(1) << 5)

typedef struct mc_runtime mc_runtime;
typedef struct mc_session mc_session;

typedef struct {
    const uint8_t *ptr;
    uint64_t len;
} mc_bytes_view_v1;

typedef struct {
    uint8_t *ptr;
    uint64_t len;
} mc_owned_bytes_v1;

/* Canonical empty owned buffers are {NULL, 0}. A non-NULL pointer with zero
 * length is invalid because the ABI must preserve the exact release token. */

/* Host tool inputs are borrowed for the callback. On MC_HOST_OK, out_result
 * remains Host-owned until release_result is called exactly once. */
typedef uint32_t (*mc_host_execute_fn_v1)(void *, mc_bytes_view_v1, mc_bytes_view_v1, mc_owned_bytes_v1 *);
typedef void (*mc_host_release_fn_v1)(void *, mc_owned_bytes_v1 *);

typedef struct {
    uint32_t struct_size;
    uint32_t reserved0;
    void *ctx;
    mc_bytes_view_v1 name;
    mc_bytes_view_v1 description;
    mc_bytes_view_v1 input_schema_json;
    mc_host_execute_fn_v1 execute;
    mc_host_release_fn_v1 release_result;
    uint64_t reserved[2];
} mc_host_tool_v1;

typedef struct {
    uint32_t struct_size;
    uint32_t reserved0;
    const mc_bytes_view_v1 *builtin_tools;
    uint64_t builtin_tool_count;
    const mc_host_tool_v1 *host_tools;
    uint64_t host_tool_count;
    uint64_t reserved[4];
} mc_runtime_config_v1;

/* event_json is the existing tagged CoreEvent JSON and is borrowed only for
 * this synchronous callback. MC_CALLBACK_FATAL poisons the Session. */
typedef uint32_t (*mc_on_event_fn_v1)(void *, mc_session *, uint64_t, mc_bytes_view_v1);
/* UI requests are synchronous in ABI v1. The Host returns one JSON response:
 * {"answers":[...]}, {"permission":"allow_once"},
 * {"plan_approval":"approve_default"}, or {"custom":"..."}.
 * An MC_UI_ANSWERED response is released exactly once via release_response. */
typedef uint32_t (*mc_on_ui_request_fn_v1)(void *, mc_session *, mc_bytes_view_v1, mc_owned_bytes_v1 *);
typedef void (*mc_release_response_fn_v1)(void *, mc_owned_bytes_v1 *);

typedef struct {
    uint32_t struct_size;
    uint32_t reserved0;
    void *ctx;
    mc_on_event_fn_v1 on_event;
    mc_on_ui_request_fn_v1 on_ui_request;
    mc_release_response_fn_v1 release_response;
    uint64_t reserved[4];
} mc_session_callbacks_v1;

/* workspace_root is the execution base for relative paths used by the
 * supported built-in file tools and shell commands. It is not a filesystem
 * containment boundary: absolute paths remain valid unless the Host applies
 * a separate sandbox/policy. workspace_root must identify an existing
 * absolute path; workspace_home must be absolute. */
typedef struct {
    uint32_t struct_size;
    uint32_t provider_kind_code;
    uint32_t permission_mode_code;
    uint32_t shell_policy_code;
    mc_bytes_view_v1 api_key;
    mc_bytes_view_v1 model;
    mc_bytes_view_v1 base_url;
    mc_bytes_view_v1 workspace_root;
    mc_bytes_view_v1 workspace_home;
    const mc_bytes_view_v1 *allowed_tools;
    uint64_t allowed_tool_count;
    uint64_t reserved[4];
} mc_session_config_v1;

typedef struct {
    uint32_t struct_size;
    uint32_t max_turns;
    uint64_t reserved[4];
} mc_run_options_v1;

typedef struct {
    uint32_t struct_size;
    uint32_t stop_reason_code;
    uint32_t turns;
    uint32_t tool_calls;
    uint64_t reserved[4];
} mc_run_result_v1;

typedef uint32_t (*mc_runtime_create_fn_v1)(const mc_runtime_config_v1 *, mc_runtime **, mc_owned_bytes_v1 *);
typedef uint32_t (*mc_runtime_destroy_fn_v1)(mc_runtime *, mc_owned_bytes_v1 *);
typedef uint32_t (*mc_session_create_fn_v1)(mc_runtime *, const mc_session_config_v1 *, const mc_session_callbacks_v1 *, mc_session **, mc_owned_bytes_v1 *);
typedef uint32_t (*mc_session_destroy_fn_v1)(mc_session *, mc_owned_bytes_v1 *);
typedef uint32_t (*mc_session_run_fn_v1)(mc_session *, uint64_t, mc_bytes_view_v1, const mc_run_options_v1 *, mc_run_result_v1 *, mc_owned_bytes_v1 *);
typedef uint32_t (*mc_session_abort_fn_v1)(mc_session *, uint64_t, uint32_t, mc_owned_bytes_v1 *);
typedef void (*mc_buffer_release_fn_v1)(mc_owned_bytes_v1 *);

typedef struct {
    uint32_t struct_size;
    uint32_t abi_version;
    uint64_t capabilities;
    mc_runtime_create_fn_v1 runtime_create;
    mc_runtime_destroy_fn_v1 runtime_destroy;
    mc_session_create_fn_v1 session_create;
    mc_session_destroy_fn_v1 session_destroy;
    mc_session_run_fn_v1 session_run;
    mc_session_abort_fn_v1 session_abort;
    mc_buffer_release_fn_v1 buffer_release;
    uint64_t reserved[4];
} mc_agentcore_api_v1;

/* Runtime outlives its Sessions. Runs are synchronous and one-at-a-time per
 * Session; callbacks may request abort but must not re-enter run or destroy. */
const void *metacodes_agentcore_get_api(uint32_t requested_abi);

#if defined(__STDC_VERSION__) && __STDC_VERSION__ >= 201112L
_Static_assert(sizeof(mc_bytes_view_v1) == 16, "mc_bytes_view_v1 layout");
_Static_assert(sizeof(mc_owned_bytes_v1) == 16, "mc_owned_bytes_v1 layout");
_Static_assert(sizeof(mc_host_tool_v1) == 96, "mc_host_tool_v1 layout");
_Static_assert(sizeof(mc_runtime_config_v1) == 72, "mc_runtime_config_v1 layout");
_Static_assert(sizeof(mc_session_callbacks_v1) == 72, "mc_session_callbacks_v1 layout");
_Static_assert(sizeof(mc_session_config_v1) == 144, "mc_session_config_v1 layout");
_Static_assert(sizeof(mc_run_options_v1) == 40, "mc_run_options_v1 layout");
_Static_assert(sizeof(mc_run_result_v1) == 48, "mc_run_result_v1 layout");
_Static_assert(sizeof(mc_agentcore_api_v1) == 104, "mc_agentcore_api_v1 layout");
_Static_assert(offsetof(mc_host_tool_v1, ctx) == 8, "mc_host_tool_v1.ctx offset");
_Static_assert(offsetof(mc_session_config_v1, api_key) == 16, "mc_session_config_v1.api_key offset");
_Static_assert(offsetof(mc_session_config_v1, allowed_tools) == 96, "mc_session_config_v1.allowed_tools offset");
_Static_assert(offsetof(mc_agentcore_api_v1, runtime_create) == 16, "mc_agentcore_api_v1.runtime_create offset");
_Static_assert(offsetof(mc_agentcore_api_v1, session_run) == 48, "mc_agentcore_api_v1.session_run offset");
#endif

#ifdef __cplusplus
}
#endif

#endif
