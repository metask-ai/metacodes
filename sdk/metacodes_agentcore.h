#ifndef METACODES_AGENTCORE_H
#define METACODES_AGENTCORE_H

#include <stdint.h>
#include <stddef.h>

#if !defined(UINTPTR_MAX) || !defined(UINT64_MAX) || UINTPTR_MAX != UINT64_MAX
#error "AgentCore ABI v1 revision 2 requires a 64-bit pointer ABI"
#endif

#ifdef __cplusplus
extern "C" {
#endif

/* ABI v1 is experimental; the 2026-07-17 freeze was retracted (see
 * doc/AGENTCORE_BINARY_ABI.md Status). Re-freezing is gated on the open items
 * in doc/AGENTCORE_V1_EXPERIMENTAL_LEDGER.md plus a reference-closure audit
 * and a real-consumer gate. No stability promise: layouts and semantics may
 * change incompatibly between commits. Pin an exact bundle; its manifest
 * records the commit. */
#define MC_AGENTCORE_ABI_V1 1u
#define MC_AGENTCORE_ABI_REVISION 2u

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
#define MC_STATUS_RESOURCE_LIMIT 10u

#define MC_PROVIDER_ANTHROPIC 1u
#define MC_PROVIDER_OPENAI 2u
#define MC_PROVIDER_GEMINI 3u
#define MC_PERMISSION_DEFAULT 1u
#define MC_PERMISSION_ACCEPT_EDITS 2u
#define MC_PERMISSION_AUTO 3u
#define MC_PERMISSION_DONT_ASK 4u
#define MC_PERMISSION_BYPASS 5u
#define MC_SHELL_DISABLED 1u
#define MC_SHELL_SANDBOXED 2u
#define MC_SHELL_UNRESTRICTED 3u
#define MC_ABORT_USER_REQUEST 1u
#define MC_ABORT_TIMEOUT 2u

#define MC_STOP_END_TURN 1u
#define MC_STOP_MAX_TURNS 2u
#define MC_STOP_ABORTED 3u
#define MC_STOP_TOOL_ERROR 4u
#define MC_STOP_API_ERROR 5u
#define MC_STOP_TOOL_LOOP 6u

#define MC_MAX_TOOL_COUNT_V1 UINT64_C(1024)
#define MC_MAX_TOOL_SCHEMA_BYTES_V1 UINT64_C(1048576)
#define MC_MAX_TOOL_SCHEMA_DEPTH_V1 32u
#define MC_MAX_TOOL_SCHEMA_PROPERTIES_V1 UINT64_C(1024)
#define MC_MAX_UI_RESPONSE_BYTES_V1 UINT64_C(1048576)
#define MC_MAX_HOST_TOOL_RESULT_BYTES_V1 UINT64_C(16777216)
#define MC_MAX_TOOL_ERROR_PAYLOAD_BYTES_V1 UINT64_C(1048576)
#define MC_MAX_SESSION_ID_BYTES_V1 UINT64_C(64)
#define MC_MAX_METADATA_STRING_BYTES_V1 UINT64_C(1048576)
#define MC_MAX_RUNTIME_METADATA_BYTES_V1 UINT64_C(16777216)
#define MC_MAX_SESSION_METADATA_BYTES_V1 UINT64_C(4194304)
#define MC_MAX_TURNS_V1 1000u

#define MC_EVENT_CONTINUE 0u
#define MC_EVENT_FATAL 1u
#define MC_UI_ANSWERED 0u
#define MC_UI_UNAVAILABLE 1u
#define MC_UI_FATAL 2u
#define MC_HOST_OK 0u
#define MC_HOST_FAILED 1u
#define MC_HOST_REJECTED 2u
#define MC_HOST_FATAL 3u

#define MC_CAP_RUNTIME (UINT64_C(1) << 0)
#define MC_CAP_BUILTIN_TOOLS (UINT64_C(1) << 1)
#define MC_CAP_HOST_SYNC_TOOLS (UINT64_C(1) << 2)
#define MC_CAP_HOST_UI (UINT64_C(1) << 3)
#define MC_CAP_CORE_EVENTS_JSON (UINT64_C(1) << 4)
#define MC_CAP_ABORT (UINT64_C(1) << 5)
#define MC_REQUIRED_CAPABILITIES_V1 \
    (MC_CAP_RUNTIME | MC_CAP_BUILTIN_TOOLS | MC_CAP_HOST_SYNC_TOOLS | \
     MC_CAP_HOST_UI | MC_CAP_CORE_EVENTS_JSON | MC_CAP_ABORT)

/* Every v1 struct_size must equal sizeof(the exact v1 type), and all reserved
 * fields must be zero. V1 is a rigid ABI: layout/table extensions use a new
 * discovery version. capabilities describes this library table, not
 * per-Runtime or per-Session feature negotiation. */

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

typedef struct {
    uint32_t struct_size;
    uint32_t reserved0;
    mc_session *session;
    uint64_t run_id;
    mc_bytes_view_v1 session_id;
    uint64_t reserved[2];
} mc_run_context_v1;

/* The context and session_id bytes are borrowed for one callback. session is
 * the original public handle and run_id is the admitted Run. session_id is
 * non-empty, at most MC_MAX_SESSION_ID_BYTES_V1 bytes, stable for the Session,
 * and distinct across live Sessions. Retaining it requires a deep copy; Hosts
 * must not infer pointer identity across callbacks. */

/* Canonical empty owned buffers are {NULL, 0}. A non-NULL pointer with zero
 * length is invalid because the ABI must preserve the exact release token.
 * Host callback outputs use one ownership rule independent of status:
 * {NULL, 0} is never released; every other descriptor is passed to its paired
 * Host release callback exactly once. */

/* Host owns host_ctx and keeps it valid until runtime_destroy succeeds. run,
 * run->session_id, and arguments_json are borrowed for this callback only;
 * arguments_json is the provider-produced tool-input JSON. MC_HOST_OK consumes
 * up to MC_MAX_HOST_TOOL_RESULT_BYTES_V1 of UTF-8 result text. MC_HOST_FAILED
 * and MC_HOST_REJECTED may provide the same raw amount of UTF-8 detail; after
 * JSON serialization AgentCore limits the encoded tool-error payload to
 * MC_MAX_TOOL_ERROR_PAYLOAD_BYTES_V1. Invalid or over-cap encoded detail
 * degrades to a bounded generic business failure; an
 * invalid MC_HOST_OK descriptor is fatal, while invalid success payload text
 * is treated as Host failure. MC_HOST_FATAL and unknown status codes are
 * fatal. */
typedef uint32_t (*mc_host_execute_fn_v1)(
    void *host_ctx,
    const mc_run_context_v1 *run,
    mc_bytes_view_v1 arguments_json,
    mc_owned_bytes_v1 *out_result);
typedef void (*mc_host_release_fn_v1)(
    void *host_ctx,
    mc_owned_bytes_v1 *result);

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
    /* Names/descriptions/schemas share MC_MAX_RUNTIME_METADATA_BYTES_V1;
     * each text field is at most MC_MAX_METADATA_STRING_BYTES_V1. */
    const mc_bytes_view_v1 *builtin_tools;
    uint64_t builtin_tool_count;
    const mc_host_tool_v1 *host_tools;
    uint64_t host_tool_count;
    uint64_t reserved[4];
} mc_runtime_config_v1;

/* event_json is tagged CoreEvent JSON and is borrowed only for this
 * synchronous callback. Unknown observation tags may be ignored.
 * MC_EVENT_FATAL poisons the Session. Different Sessions may invoke the
 * same callback concurrently. */
typedef uint32_t (*mc_on_event_fn_v1)(
    void *session_ctx,
    const mc_run_context_v1 *run,
    mc_bytes_view_v1 event_json);
/* UI requests are synchronous in ABI v1. The Host returns one JSON response:
 * {"answers":[...]} or {"permission":"allow_once"}.
 * Only MC_UI_ANSWERED consumes the response. MC_UI_UNAVAILABLE is an ordinary
 * reusable outcome; fatal/unknown status poisons the Session.
 * Responses over MC_MAX_UI_RESPONSE_BYTES_V1 are callback failures and poison
 * the Session. */
typedef uint32_t (*mc_on_ui_request_fn_v1)(
    void *session_ctx,
    const mc_run_context_v1 *run,
    mc_bytes_view_v1 request_json,
    mc_owned_bytes_v1 *out_response);
typedef void (*mc_release_response_fn_v1)(
    void *session_ctx,
    mc_owned_bytes_v1 *response);

/* Host owns ctx and keeps it valid until session_destroy succeeds. AgentCore
 * copies this descriptor during session_create but never frees ctx. */
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
 * absolute path. workspace_home may be empty to use workspace_root; otherwise
 * it must be absolute. Provider credentials never
 * appear in event or diagnostic buffers. Prompts, model/tool/UI payloads may
 * contain sensitive data, so the Host owns logging and redaction. */
typedef struct {
    uint32_t struct_size;
    uint32_t provider_kind_code;
    uint32_t permission_mode_code;
    uint32_t shell_policy_code;
    /* These strings and allowed tool names share
     * MC_MAX_SESSION_METADATA_BYTES_V1; each is at most
     * MC_MAX_METADATA_STRING_BYTES_V1. */
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
    /* 1..MC_MAX_TURNS_V1 */
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
/* mc_run_result_v1 fields are defined only when session_run returns
 * MC_STATUS_OK. stop_reason_code is then one of MC_STOP_END_TURN through
 * MC_STOP_TOOL_LOOP. */

typedef uint32_t (*mc_runtime_create_fn_v1)(const mc_runtime_config_v1 *, mc_runtime **, mc_owned_bytes_v1 *);
typedef uint32_t (*mc_runtime_destroy_fn_v1)(mc_runtime *, mc_owned_bytes_v1 *);
typedef uint32_t (*mc_session_create_fn_v1)(mc_runtime *, const mc_session_config_v1 *, const mc_session_callbacks_v1 *, mc_session **, mc_owned_bytes_v1 *);
typedef uint32_t (*mc_session_destroy_fn_v1)(mc_session *, mc_owned_bytes_v1 *);

/* run_id is Host-assigned, non-zero, and scoped to one Session. Each admitted
 * Run must use a value strictly greater than that Session's previously
 * admitted run_id. Values may skip. Pre-admission rejection never advances the
 * last admitted ID, so an otherwise valid greater value remains available for
 * retry; zero and stale values do not. Admitted values must not be reused or
 * wrapped. After admitting UINT64_MAX, the Host must create a new Session.
 * Return is a quiescence boundary: callbacks and paired releases for this Run
 * have completed. The facade gate remains held through result/diagnostic
 * publication; overlapping run/destroy returns BUSY, while matching abort may
 * proceed. */
typedef uint32_t (*mc_session_run_fn_v1)(
    mc_session *session,
    uint64_t run_id,
    mc_bytes_view_v1 prompt,
    const mc_run_options_v1 *options,
    mc_run_result_v1 *out_result,
    mc_owned_bytes_v1 *out_diagnostic);

/* On a usable Session, zero is INVALID_ARGUMENT and abort requests must
 * identify the active Run. A different active run_id is STALE_RUN. When idle,
 * the last admitted run_id is TOO_LATE and every other value is STALE_RUN.
 * Poisoned Sessions return INVALID_STATE regardless of the supplied ID. */
typedef uint32_t (*mc_session_abort_fn_v1)(
    mc_session *session,
    uint64_t run_id,
    uint32_t reason_code,
    mc_owned_bytes_v1 *out_diagnostic);

/* session_run failures before admission (invalid input, resource limit, busy,
 * or stale run id) leave the Session reusable. Once a Run is admitted, an
 * OUT_OF_MEMORY, CORE_ERROR, CALLBACK_FAILED, or INTERNAL_ERROR result poisons
 * the Session; subsequent run/abort calls return INVALID_STATE and destroy
 * remains valid. STATUS_OK, including STOP_ABORTED, returns the Session to
 * idle. TOO_LATE from abort also leaves an idle Session reusable. Given a
 * valid Session handle, poisoned state takes precedence over remaining run or
 * abort argument validation. V1 has no recovery or Conversation/history import
 * for a poisoned Session; the Host must destroy it and create a new Session. */

/* The final mc_owned_bytes_v1 * parameter on AgentCore API calls is an
 * optional, write-only diagnostic output. The library never reads or releases
 * its previous value, so the caller must release a previously returned
 * diagnostic before reusing the variable. Calls return canonical empty on
 * success; non-empty diagnostics are library-owned and must be released with
 * buffer_release. buffer_release must not be used for Host-owned tool or UI
 * callback buffers, which use their paired Host release callback. Diagnostic
 * allocation is best-effort and never changes the operation's primary status. */
typedef void (*mc_buffer_release_fn_v1)(mc_owned_bytes_v1 *);

typedef struct {
    uint32_t struct_size;
    uint32_t abi_version;
    uint32_t abi_revision;
    uint32_t reserved0;
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
 * Session. Different Sessions may run and invoke shared callbacks concurrently.
 * A Host tool may also be invoked concurrently within one Session. Callbacks
 * may request abort; re-entered run or destroy returns BUSY. A callback must
 * not wait or spin for that operation. C++ exceptions, longjmp, and all other
 * non-local control transfers must not cross callback or release-callback
 * boundaries. No callback or release callback has thread affinity. */
/* requested_abi selects the major table shape. Consumers must additionally
 * require struct_size == sizeof(mc_agentcore_api_v1), abi_version ==
 * MC_AGENTCORE_ABI_V1, and abi_revision == MC_AGENTCORE_ABI_REVISION before
 * using any function pointer. */
const void *metacodes_agentcore_get_api(uint32_t requested_abi);

#if defined(__cplusplus) && __cplusplus >= 201103L
#define MC_AGENTCORE_STATIC_ASSERT(condition, message) static_assert((condition), message)
#elif defined(__STDC_VERSION__) && __STDC_VERSION__ >= 201112L
#define MC_AGENTCORE_STATIC_ASSERT(condition, message) _Static_assert((condition), message)
#else
#define MC_AGENTCORE_STATIC_ASSERT(condition, message)
#endif

MC_AGENTCORE_STATIC_ASSERT(sizeof(mc_bytes_view_v1) == 16, "mc_bytes_view_v1 layout");
MC_AGENTCORE_STATIC_ASSERT(sizeof(mc_owned_bytes_v1) == 16, "mc_owned_bytes_v1 layout");
MC_AGENTCORE_STATIC_ASSERT(sizeof(mc_run_context_v1) == 56, "mc_run_context_v1 layout");
MC_AGENTCORE_STATIC_ASSERT(sizeof(mc_host_tool_v1) == 96, "mc_host_tool_v1 layout");
MC_AGENTCORE_STATIC_ASSERT(sizeof(mc_runtime_config_v1) == 72, "mc_runtime_config_v1 layout");
MC_AGENTCORE_STATIC_ASSERT(sizeof(mc_session_callbacks_v1) == 72, "mc_session_callbacks_v1 layout");
MC_AGENTCORE_STATIC_ASSERT(sizeof(mc_session_config_v1) == 144, "mc_session_config_v1 layout");
MC_AGENTCORE_STATIC_ASSERT(sizeof(mc_run_options_v1) == 40, "mc_run_options_v1 layout");
MC_AGENTCORE_STATIC_ASSERT(sizeof(mc_run_result_v1) == 48, "mc_run_result_v1 layout");
MC_AGENTCORE_STATIC_ASSERT(sizeof(mc_agentcore_api_v1) == 112, "mc_agentcore_api_v1 layout");
MC_AGENTCORE_STATIC_ASSERT(offsetof(mc_run_context_v1, session) == 8, "mc_run_context_v1.session offset");
MC_AGENTCORE_STATIC_ASSERT(offsetof(mc_run_context_v1, run_id) == 16, "mc_run_context_v1.run_id offset");
MC_AGENTCORE_STATIC_ASSERT(offsetof(mc_run_context_v1, session_id) == 24, "mc_run_context_v1.session_id offset");
MC_AGENTCORE_STATIC_ASSERT(offsetof(mc_host_tool_v1, ctx) == 8, "mc_host_tool_v1.ctx offset");
MC_AGENTCORE_STATIC_ASSERT(offsetof(mc_session_config_v1, api_key) == 16, "mc_session_config_v1.api_key offset");
MC_AGENTCORE_STATIC_ASSERT(offsetof(mc_session_config_v1, allowed_tools) == 96, "mc_session_config_v1.allowed_tools offset");
MC_AGENTCORE_STATIC_ASSERT(offsetof(mc_agentcore_api_v1, abi_revision) == 8, "mc_agentcore_api_v1.abi_revision offset");
MC_AGENTCORE_STATIC_ASSERT(offsetof(mc_agentcore_api_v1, capabilities) == 16, "mc_agentcore_api_v1.capabilities offset");
MC_AGENTCORE_STATIC_ASSERT(offsetof(mc_agentcore_api_v1, runtime_create) == 24, "mc_agentcore_api_v1.runtime_create offset");
MC_AGENTCORE_STATIC_ASSERT(offsetof(mc_agentcore_api_v1, session_run) == 56, "mc_agentcore_api_v1.session_run offset");

#undef MC_AGENTCORE_STATIC_ASSERT

#ifdef __cplusplus
}
#endif

#endif
