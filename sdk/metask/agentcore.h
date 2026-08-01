#ifndef METASK_AGENTCORE_H
#define METASK_AGENTCORE_H

#include <stdint.h>
#include <stddef.h>

#if !defined(UINTPTR_MAX) || !defined(UINT64_MAX) || UINTPTR_MAX != UINT64_MAX
#error "AgentCore ABI v1 revision 5 requires a 64-bit pointer ABI"
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
#define METASK_AGENTCORE_ABI_V1 1u
#define METASK_AGENTCORE_ABI_REVISION 5u

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

#define METASK_AGENTCORE_PROVIDER_ANTHROPIC 1u
#define METASK_AGENTCORE_PROVIDER_OPENAI 2u
#define METASK_AGENTCORE_PROVIDER_GEMINI 3u
#define METASK_AGENTCORE_PERMISSION_DEFAULT 1u
#define METASK_AGENTCORE_PERMISSION_ACCEPT_EDITS 2u
#define METASK_AGENTCORE_PERMISSION_AUTO 3u
#define METASK_AGENTCORE_PERMISSION_DONT_ASK 4u
#define METASK_AGENTCORE_PERMISSION_BYPASS 5u
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
#define METASK_AGENTCORE_MAX_SKILL_ARGUMENT_VALUES_V1 64ULL
#define METASK_AGENTCORE_MAX_SKILL_ARGUMENT_JSON_BYTES_V1 1048576ULL
#define METASK_AGENTCORE_MAX_PERMISSION_RULES_V1 1024ULL
#define METASK_AGENTCORE_MAX_PERMISSION_RULE_BYTES_V1 65536ULL
#define METASK_AGENTCORE_MAX_PERMISSION_RULE_TOTAL_BYTES_V1 1048576ULL
#define METASK_AGENTCORE_MAX_TURNS_V1 1000u

#define METASK_AGENTCORE_RUN_INPUT_TEXT 1u
#define METASK_AGENTCORE_RUN_INPUT_SKILL 2u
#define METASK_AGENTCORE_SKILL_SELECTION_DISABLED 1u
#define METASK_AGENTCORE_SKILL_SELECTION_ENABLED 2u
#define METASK_AGENTCORE_COMPACT_COMPACTED 1u
#define METASK_AGENTCORE_COMPACT_NO_CHANGE 2u
#define METASK_AGENTCORE_COMPACT_DEGRADED 3u
#define METASK_AGENTCORE_COMPACT_ABORTED 4u

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
#define METASK_AGENTCORE_REQUIRED_CAPABILITIES_V1 \
    (METASK_AGENTCORE_CAP_RUNTIME | METASK_AGENTCORE_CAP_BUILTIN_TOOLS | METASK_AGENTCORE_CAP_HOST_SYNC_TOOLS | \
     METASK_AGENTCORE_CAP_HOST_UI | METASK_AGENTCORE_CAP_CORE_EVENTS_JSON | METASK_AGENTCORE_CAP_ABORT | \
     METASK_AGENTCORE_CAP_SKILL_CATALOG | METASK_AGENTCORE_CAP_TYPED_RUN_INPUT | \
     METASK_AGENTCORE_CAP_SESSION_MODEL_MUTATION | METASK_AGENTCORE_CAP_MANUAL_COMPACT | \
     METASK_AGENTCORE_CAP_SKILL_SELECTION | METASK_AGENTCORE_CAP_HOST_PERMISSION_RULES)

/* Every revision-5 struct_size must equal sizeof(the exact type), and all
 * reserved fields must be zero. Consumers pin ABI version, revision, table
 * size, and capabilities together. V1 remains experimental and later
 * revisions may intentionally be breaking. */

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

/* The context and session_id bytes are borrowed for one callback. session is
 * the original public handle and run_id is the admitted Run. session_id is
 * non-empty, at most METASK_AGENTCORE_MAX_SESSION_ID_BYTES_V1 bytes, stable for the Session,
 * and distinct across live Sessions. Retaining it requires a deep copy; Hosts
 * must not infer pointer identity across callbacks. */

/* Canonical empty owned buffers are {NULL, 0}. A non-NULL pointer with zero
 * length is invalid because the ABI must preserve the exact release token.
 * Host callback outputs use one ownership rule independent of status:
 * {NULL, 0} is never released; every other descriptor is passed to its paired
 * Host release callback exactly once. */

/* Host owns host_ctx and keeps it valid until runtime_destroy succeeds. run,
 * run->session_id, and arguments_json are borrowed for this callback only;
 * arguments_json is the provider-produced tool-input JSON. METASK_AGENTCORE_HOST_OK consumes
 * up to METASK_AGENTCORE_MAX_HOST_TOOL_RESULT_BYTES_V1 of UTF-8 result text. METASK_AGENTCORE_HOST_FAILED
 * and METASK_AGENTCORE_HOST_REJECTED may provide the same raw amount of UTF-8 detail; after
 * JSON serialization AgentCore limits the encoded tool-error payload to
 * METASK_AGENTCORE_MAX_TOOL_ERROR_PAYLOAD_BYTES_V1. Invalid or over-cap encoded detail
 * degrades to a bounded generic business failure; an
 * invalid METASK_AGENTCORE_HOST_OK descriptor is fatal, while invalid success payload text
 * is treated as Host failure. METASK_AGENTCORE_HOST_FATAL and unknown status codes are
 * fatal. */
typedef uint32_t (*metask_agentcore_host_execute_fn_v1)(
    void *host_ctx,
    const metask_agentcore_run_context_v1 *run,
    metask_agentcore_bytes_view_v1 arguments_json,
    metask_agentcore_owned_bytes_v1 *out_result);
typedef void (*metask_agentcore_host_release_fn_v1)(
    void *host_ctx,
    metask_agentcore_owned_bytes_v1 *result);

typedef struct {
    uint32_t struct_size;
    uint32_t reserved0;
    void *ctx;
    /* "Skill" is reserved for AgentCore's Run-local projection of a bound
     * catalog and is rejected as a Host tool name. */
    metask_agentcore_bytes_view_v1 name;
    metask_agentcore_bytes_view_v1 description;
    metask_agentcore_bytes_view_v1 input_schema_json;
    metask_agentcore_host_execute_fn_v1 execute;
    metask_agentcore_host_release_fn_v1 release_result;
    uint64_t reserved[2];
} metask_agentcore_host_tool_v1;

typedef struct {
    uint32_t struct_size;
    uint32_t reserved0;
    /* Names/descriptions/schemas share METASK_AGENTCORE_MAX_RUNTIME_METADATA_BYTES_V1;
     * each text field is at most METASK_AGENTCORE_MAX_METADATA_STRING_BYTES_V1. */
    const metask_agentcore_bytes_view_v1 *builtin_tools;
    uint64_t builtin_tool_count;
    const metask_agentcore_host_tool_v1 *host_tools;
    uint64_t host_tool_count;
    uint64_t reserved[4];
} metask_agentcore_runtime_config_v1;

/* event_json is tagged CoreEvent JSON and is borrowed only for this
 * synchronous callback. Unknown observation tags may be ignored.
 * METASK_AGENTCORE_EVENT_FATAL poisons the Session. Different Sessions may invoke the
 * same callback concurrently. */
typedef uint32_t (*metask_agentcore_on_event_fn_v1)(
    void *session_ctx,
    const metask_agentcore_run_context_v1 *run,
    metask_agentcore_bytes_view_v1 event_json);
/* UI requests are synchronous in ABI v1. The Host returns one JSON response:
 * {"answers":[{"values":[...]}]} or {"permission":"allow_once"}.
 * Only METASK_AGENTCORE_UI_ANSWERED consumes the response. METASK_AGENTCORE_UI_UNAVAILABLE is an ordinary
 * reusable outcome; fatal/unknown status poisons the Session.
 * Responses over METASK_AGENTCORE_MAX_UI_RESPONSE_BYTES_V1 are callback failures and poison
 * the Session. */
typedef uint32_t (*metask_agentcore_on_ui_request_fn_v1)(
    void *session_ctx,
    const metask_agentcore_run_context_v1 *run,
    metask_agentcore_bytes_view_v1 request_json,
    metask_agentcore_owned_bytes_v1 *out_response);
typedef void (*metask_agentcore_release_response_fn_v1)(
    void *session_ctx,
    metask_agentcore_owned_bytes_v1 *response);

/* Host owns ctx and keeps it valid until session_destroy succeeds. AgentCore
 * copies this descriptor during session_create but never frees ctx. */
typedef struct {
    uint32_t struct_size;
    uint32_t reserved0;
    void *ctx;
    metask_agentcore_on_event_fn_v1 on_event;
    metask_agentcore_on_ui_request_fn_v1 on_ui_request;
    metask_agentcore_release_response_fn_v1 release_response;
    uint64_t reserved[4];
} metask_agentcore_session_callbacks_v1;

/* Query is Session-independent so a consumer can render a Skill menu before
 * creating its first Task/Session. workspace_epoch is an opaque Host-supplied
 * byte token: canonical empty means no external generation; otherwise it is
 * interpreted only by byte equality within one canonical Workspace scope.
 * It need not be parseable, monotonic, or comparable across Hosts. Change it
 * when the Host's external Workspace binding generation changes. It enters
 * catalog_revision, so changing it can make input prepared for another bound
 * revision return METASK_AGENTCORE_STATUS_STALE_CATALOG. Default discovery is
 * limited to workspace_home/.agents/skills and
 * workspace_root/.agents/skills; product-specific roots are not scanned. */
typedef struct {
    uint32_t struct_size;
    uint32_t reserved0;
    metask_agentcore_bytes_view_v1 workspace_root;
    metask_agentcore_bytes_view_v1 workspace_home;
    metask_agentcore_bytes_view_v1 workspace_epoch;
    uint64_t reserved[3];
} metask_agentcore_skill_catalog_query_v1;

/* New Skills use default_state_code. Each listed catalog Skill ID uses the
 * opposite state. The borrowed list must not contain duplicate or foreign
 * IDs and is copied before session_create/session_update_skills returns. */
typedef struct {
    uint32_t struct_size;
    uint32_t default_state_code;
    const metask_agentcore_bytes_view_v1 *exception_skill_ids;
    uint64_t exception_skill_id_count;
    uint64_t reserved[4];
} metask_agentcore_skill_selection_v1;

/* Canonical Tool(specifier) rules are borrowed for one call. AgentCore
 * validates, copies, and compiles the complete replacement atomically. */
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
     * METASK_AGENTCORE_MAX_SESSION_METADATA_BYTES_V1; each is at most
     * METASK_AGENTCORE_MAX_METADATA_STRING_BYTES_V1. */
    metask_agentcore_bytes_view_v1 api_key;
    /* This is the fixed provider model for the Session and all AgentCore Skill
     * fork children. A Skill model other than empty/"inherit" is unavailable
     * and cannot override this binding. */
    metask_agentcore_bytes_view_v1 model;
    metask_agentcore_bytes_view_v1 base_url;
    metask_agentcore_bytes_view_v1 workspace_root;
    metask_agentcore_bytes_view_v1 workspace_home;
    const metask_agentcore_bytes_view_v1 *allowed_tools;
    uint64_t allowed_tool_count;
    /* skill_catalog and skill_selection must both be NULL or both non-NULL.
     * A catalog must belong to this Runtime and canonical Workspace binding.
     * The selection is validated against that exact catalog. */
    metask_agentcore_skill_catalog *skill_catalog;
    const metask_agentcore_skill_selection_v1 *skill_selection;
    /* NULL means no imported rules. A non-NULL empty set has the same effective
     * meaning and is useful for sharing construction code with updates. */
    const metask_agentcore_permission_rule_set_v1 *permission_rules;
    uint64_t reserved[4];
} metask_agentcore_session_config_v1;

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
    /* 1..METASK_AGENTCORE_MAX_TURNS_V1 */
    uint32_t max_turns;
    uint64_t reserved[4];
} metask_agentcore_run_options_v1;

typedef struct {
    uint32_t struct_size;
    uint32_t stop_reason_code;
    uint32_t turns;
    uint32_t tool_calls;
    uint64_t reserved[4];
} metask_agentcore_run_result_v1;
/* metask_agentcore_run_result_v1 fields are defined only when session_run_input returns
 * METASK_AGENTCORE_STATUS_OK. stop_reason_code is then one of METASK_AGENTCORE_STOP_END_TURN through
 * METASK_AGENTCORE_STOP_TOOL_LOOP. */

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
/* Fields are defined only when session_compact returns
 * METASK_AGENTCORE_STATUS_OK. An accepted cancellation returns OK with
 * METASK_AGENTCORE_COMPACT_ABORTED and does not commit Conversation changes.
 * before_context_tokens and after_context_tokens are context-size estimates,
 * not provider billing values. The four usage fields are separate provider
 * usage deltas. Revision 5 exposes no structured degraded reason. */

typedef uint32_t (*metask_agentcore_runtime_create_fn_v1)(const metask_agentcore_runtime_config_v1 *, metask_agentcore_runtime **, metask_agentcore_owned_bytes_v1 *);
typedef uint32_t (*metask_agentcore_runtime_destroy_fn_v1)(metask_agentcore_runtime *, metask_agentcore_owned_bytes_v1 *);
typedef uint32_t (*metask_agentcore_runtime_query_skill_catalog_fn_v1)(
    metask_agentcore_runtime *,
    const metask_agentcore_skill_catalog_query_v1 *,
    metask_agentcore_skill_catalog **,
    metask_agentcore_owned_bytes_v1 *,
    metask_agentcore_owned_bytes_v1 *);
/* On success, the descriptor uses metask.skill-catalog/v1. Each valid Skill
 * has argument_schema {schema:"metask.skill-arguments/v1", max_values:64,
 * names:[...]}. names are ordered positional UI labels, not required arity;
 * arguments_json.values[i] corresponds to names[i]. */
typedef uint32_t (*metask_agentcore_skill_catalog_release_fn_v1)(
    metask_agentcore_skill_catalog *,
    metask_agentcore_owned_bytes_v1 *);
typedef uint32_t (*metask_agentcore_session_create_fn_v1)(metask_agentcore_runtime *, const metask_agentcore_session_config_v1 *, const metask_agentcore_session_callbacks_v1 *, metask_agentcore_session **, metask_agentcore_owned_bytes_v1 *);
/* The Host must wait for every session_abort/session_abort_compact call to
 * return before issuing any subsequent call on the same handle, including
 * destroy. STATUS_OK invalidates the handle; any later call with that pointer
 * is invalid Host behavior. */
typedef uint32_t (*metask_agentcore_session_destroy_fn_v1)(metask_agentcore_session *, metask_agentcore_owned_bytes_v1 *);
typedef uint32_t (*metask_agentcore_session_set_model_fn_v1)(
    metask_agentcore_session *,
    metask_agentcore_bytes_view_v1,
    metask_agentcore_owned_bytes_v1 *);
typedef uint32_t (*metask_agentcore_session_update_skills_fn_v1)(
    metask_agentcore_session *,
    metask_agentcore_skill_catalog *optional_catalog,
    const metask_agentcore_skill_selection_v1 *,
    metask_agentcore_owned_bytes_v1 *);
typedef uint32_t (*metask_agentcore_session_update_permission_rules_fn_v1)(
    metask_agentcore_session *,
    const metask_agentcore_permission_rule_set_v1 *,
    metask_agentcore_owned_bytes_v1 *);
/* session_set_model performs no remote probe. STATUS_OK means only that the
 * owned local model/provider state was replaced; the next Run reports an
 * unavailable model as METASK_AGENTCORE_STOP_API_ERROR without poisoning the
 * Session. update_skills requires a selection. A NULL optional_catalog keeps
 * the current catalog without discovery; it is INVALID_STATE if none is bound.
 * All three mutations require an idle, usable Session and commit atomically. */

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
typedef uint32_t (*metask_agentcore_session_run_input_fn_v1)(
    metask_agentcore_session *session,
    uint64_t run_id,
    const metask_agentcore_run_input_v1 *input,
    const metask_agentcore_run_options_v1 *options,
    metask_agentcore_run_result_v1 *out_result,
    metask_agentcore_owned_bytes_v1 *out_diagnostic);

/* On a usable Session, zero is INVALID_ARGUMENT and abort requests must
 * identify the active Run. A different active run_id is STALE_RUN. When idle,
 * the last admitted run_id is TOO_LATE and every other value is STALE_RUN.
 * Poisoned Sessions return INVALID_STATE regardless of the supplied ID. */
typedef uint32_t (*metask_agentcore_session_abort_fn_v1)(
    metask_agentcore_session *session,
    uint64_t run_id,
    uint32_t reason_code,
    metask_agentcore_owned_bytes_v1 *out_diagnostic);

/* operation_id is Host-assigned, non-zero, and strictly increasing in the
 * Session compact ID space. Zero is INVALID_ARGUMENT and an ID not greater
 * than the last admitted compact is STALE_COMPACT. Pre-admission rejection
 * does not consume the ID; every admitted terminal path does. Revision 5 runs
 * a canonical default best-effort policy: it accepts no target token budget
 * and does not guarantee that the result fits any model context window. */
typedef uint32_t (*metask_agentcore_session_compact_fn_v1)(
    metask_agentcore_session *session,
    uint64_t operation_id,
    metask_agentcore_compact_result_v1 *out_result,
    metask_agentcore_owned_bytes_v1 *out_diagnostic);
/* For an active compact: equal requests cancellation, lower is STALE_COMPACT,
 * higher is INVALID_ARGUMENT. When idle: the last terminal ID is TOO_LATE,
 * lower is STALE_COMPACT, and every other ID is INVALID_ARGUMENT. Cancellation
 * is propagated to in-flight provider I/O and does not wait for its response. */
typedef uint32_t (*metask_agentcore_session_abort_compact_fn_v1)(
    metask_agentcore_session *session,
    uint64_t operation_id,
    metask_agentcore_owned_bytes_v1 *out_diagnostic);

/* session_run_input failures before admission (invalid input, resource limit,
 * busy, stale run id, or an unavailable Skill model override) do not consume
 * run_id. Skill materialization failures after admission consume run_id but
 * leave the Session reusable after cleanup.
 * Once Conversation/provider/tool execution begins, OUT_OF_MEMORY, CORE_ERROR,
 * CALLBACK_FAILED, or INTERNAL_ERROR poisons the Session; subsequent run/abort
 * calls return INVALID_STATE and destroy remains valid. STATUS_OK, including
 * STOP_ABORTED, returns the Session to idle. TOO_LATE from abort also leaves an
 * idle Session reusable. Given a valid Session handle, poisoned state takes
 * precedence over remaining run or abort argument validation. V1 has no
 * recovery or Conversation/history import for a poisoned Session; the Host
 * must destroy it and create a new Session. */

/* The final metask_agentcore_owned_bytes_v1 * parameter on AgentCore API calls is an
 * optional, write-only diagnostic output. The library never reads or releases
 * its previous value, so the caller must release a previously returned
 * diagnostic before reusing the variable. Calls return canonical empty on
 * success; non-empty diagnostics are library-owned and must be released with
 * buffer_release. buffer_release must not be used for Host-owned tool or UI
 * callback buffers, which use their paired Host release callback. Diagnostic
 * allocation is best-effort and never changes the operation's primary status.
 * Diagnostic text is human-readable, non-normative, and unstable; consumers
 * must not parse it or branch on its wording. */
typedef void (*metask_agentcore_buffer_release_fn_v1)(metask_agentcore_owned_bytes_v1 *);

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
    metask_agentcore_session_create_fn_v1 session_create;
    metask_agentcore_session_destroy_fn_v1 session_destroy;
    metask_agentcore_session_set_model_fn_v1 session_set_model;
    metask_agentcore_session_update_skills_fn_v1 session_update_skills;
    metask_agentcore_session_update_permission_rules_fn_v1 session_update_permission_rules;
    metask_agentcore_session_run_input_fn_v1 session_run_input;
    metask_agentcore_session_abort_fn_v1 session_abort;
    metask_agentcore_session_compact_fn_v1 session_compact;
    metask_agentcore_session_abort_compact_fn_v1 session_abort_compact;
    metask_agentcore_buffer_release_fn_v1 buffer_release;
    uint64_t reserved[4];
} metask_agentcore_api_v1;

/* Runtime outlives its Sessions. Run, compact, model mutation, Skill mutation,
 * permission-rule mutation, and destroy are mutually exclusive per Session.
 * Different Sessions may run and invoke shared callbacks concurrently.
 * A Host tool may also be invoked concurrently within one Session. Callbacks
 * may request matching abort; matching abort may overlap only its corresponding
 * active Run or compact. The Host must wait for abort to return before any
 * subsequent call on the same handle. Re-entered run or destroy returns BUSY.
 * A callback must not wait or spin for that operation.
 * C++ exceptions, longjmp, and all other
 * non-local control transfers must not cross callback or release-callback
 * boundaries. No callback or release callback has thread affinity. */
/* requested_abi selects the major table shape. Consumers must additionally
 * require struct_size == sizeof(metask_agentcore_api_v1), abi_version ==
 * METASK_AGENTCORE_ABI_V1, and abi_revision == METASK_AGENTCORE_ABI_REVISION before
 * using any function pointer. */
const void *metask_agentcore_get_api(uint32_t requested_abi);

#if defined(__cplusplus) && __cplusplus >= 201103L
#define METASK_AGENTCORE_STATIC_ASSERT(condition, message) static_assert((condition), message)
#elif defined(__STDC_VERSION__) && __STDC_VERSION__ >= 201112L
#define METASK_AGENTCORE_STATIC_ASSERT(condition, message) _Static_assert((condition), message)
#else
#define METASK_AGENTCORE_STATIC_ASSERT(condition, message)
#endif

METASK_AGENTCORE_STATIC_ASSERT(sizeof(metask_agentcore_bytes_view_v1) == 16, "metask_agentcore_bytes_view_v1 layout");
METASK_AGENTCORE_STATIC_ASSERT(sizeof(metask_agentcore_owned_bytes_v1) == 16, "metask_agentcore_owned_bytes_v1 layout");
METASK_AGENTCORE_STATIC_ASSERT(sizeof(metask_agentcore_run_context_v1) == 56, "metask_agentcore_run_context_v1 layout");
METASK_AGENTCORE_STATIC_ASSERT(sizeof(metask_agentcore_host_tool_v1) == 96, "metask_agentcore_host_tool_v1 layout");
METASK_AGENTCORE_STATIC_ASSERT(sizeof(metask_agentcore_runtime_config_v1) == 72, "metask_agentcore_runtime_config_v1 layout");
METASK_AGENTCORE_STATIC_ASSERT(sizeof(metask_agentcore_session_callbacks_v1) == 72, "metask_agentcore_session_callbacks_v1 layout");
METASK_AGENTCORE_STATIC_ASSERT(sizeof(metask_agentcore_skill_catalog_query_v1) == 80, "metask_agentcore_skill_catalog_query_v1 layout");
METASK_AGENTCORE_STATIC_ASSERT(sizeof(metask_agentcore_skill_selection_v1) == 56, "metask_agentcore_skill_selection_v1 layout");
METASK_AGENTCORE_STATIC_ASSERT(sizeof(metask_agentcore_permission_rule_set_v1) == 88, "metask_agentcore_permission_rule_set_v1 layout");
METASK_AGENTCORE_STATIC_ASSERT(sizeof(metask_agentcore_run_input_v1) == 104, "metask_agentcore_run_input_v1 layout");
METASK_AGENTCORE_STATIC_ASSERT(sizeof(metask_agentcore_session_config_v1) == 168, "metask_agentcore_session_config_v1 layout");
METASK_AGENTCORE_STATIC_ASSERT(sizeof(metask_agentcore_run_options_v1) == 40, "metask_agentcore_run_options_v1 layout");
METASK_AGENTCORE_STATIC_ASSERT(sizeof(metask_agentcore_run_result_v1) == 48, "metask_agentcore_run_result_v1 layout");
METASK_AGENTCORE_STATIC_ASSERT(sizeof(metask_agentcore_compact_result_v1) == 88, "metask_agentcore_compact_result_v1 layout");
METASK_AGENTCORE_STATIC_ASSERT(sizeof(metask_agentcore_api_v1) == 168, "metask_agentcore_api_v1 layout");
METASK_AGENTCORE_STATIC_ASSERT(offsetof(metask_agentcore_run_context_v1, session) == 8, "metask_agentcore_run_context_v1.session offset");
METASK_AGENTCORE_STATIC_ASSERT(offsetof(metask_agentcore_run_context_v1, run_id) == 16, "metask_agentcore_run_context_v1.run_id offset");
METASK_AGENTCORE_STATIC_ASSERT(offsetof(metask_agentcore_run_context_v1, session_id) == 24, "metask_agentcore_run_context_v1.session_id offset");
METASK_AGENTCORE_STATIC_ASSERT(offsetof(metask_agentcore_host_tool_v1, ctx) == 8, "metask_agentcore_host_tool_v1.ctx offset");
METASK_AGENTCORE_STATIC_ASSERT(offsetof(metask_agentcore_session_config_v1, api_key) == 16, "metask_agentcore_session_config_v1.api_key offset");
METASK_AGENTCORE_STATIC_ASSERT(offsetof(metask_agentcore_session_config_v1, allowed_tools) == 96, "metask_agentcore_session_config_v1.allowed_tools offset");
METASK_AGENTCORE_STATIC_ASSERT(offsetof(metask_agentcore_session_config_v1, skill_catalog) == 112, "metask_agentcore_session_config_v1.skill_catalog offset");
METASK_AGENTCORE_STATIC_ASSERT(offsetof(metask_agentcore_session_config_v1, skill_selection) == 120, "metask_agentcore_session_config_v1.skill_selection offset");
METASK_AGENTCORE_STATIC_ASSERT(offsetof(metask_agentcore_session_config_v1, permission_rules) == 128, "metask_agentcore_session_config_v1.permission_rules offset");
METASK_AGENTCORE_STATIC_ASSERT(offsetof(metask_agentcore_skill_selection_v1, exception_skill_ids) == 8, "metask_agentcore_skill_selection_v1.exception_skill_ids offset");
METASK_AGENTCORE_STATIC_ASSERT(offsetof(metask_agentcore_permission_rule_set_v1, allow) == 8, "metask_agentcore_permission_rule_set_v1.allow offset");
METASK_AGENTCORE_STATIC_ASSERT(offsetof(metask_agentcore_permission_rule_set_v1, ask) == 24, "metask_agentcore_permission_rule_set_v1.ask offset");
METASK_AGENTCORE_STATIC_ASSERT(offsetof(metask_agentcore_permission_rule_set_v1, deny) == 40, "metask_agentcore_permission_rule_set_v1.deny offset");
METASK_AGENTCORE_STATIC_ASSERT(offsetof(metask_agentcore_compact_result_v1, before_context_tokens) == 8, "metask_agentcore_compact_result_v1.before_context_tokens offset");
METASK_AGENTCORE_STATIC_ASSERT(offsetof(metask_agentcore_compact_result_v1, input_tokens) == 24, "metask_agentcore_compact_result_v1.input_tokens offset");
METASK_AGENTCORE_STATIC_ASSERT(offsetof(metask_agentcore_skill_catalog_query_v1, workspace_epoch) == 40, "metask_agentcore_skill_catalog_query_v1.workspace_epoch offset");
METASK_AGENTCORE_STATIC_ASSERT(offsetof(metask_agentcore_run_input_v1, arguments_json) == 56, "metask_agentcore_run_input_v1.arguments_json offset");
METASK_AGENTCORE_STATIC_ASSERT(offsetof(metask_agentcore_api_v1, abi_revision) == 8, "metask_agentcore_api_v1.abi_revision offset");
METASK_AGENTCORE_STATIC_ASSERT(offsetof(metask_agentcore_api_v1, capabilities) == 16, "metask_agentcore_api_v1.capabilities offset");
METASK_AGENTCORE_STATIC_ASSERT(offsetof(metask_agentcore_api_v1, runtime_create) == 24, "metask_agentcore_api_v1.runtime_create offset");
METASK_AGENTCORE_STATIC_ASSERT(offsetof(metask_agentcore_api_v1, runtime_query_skill_catalog) == 40, "metask_agentcore_api_v1.runtime_query_skill_catalog offset");
METASK_AGENTCORE_STATIC_ASSERT(offsetof(metask_agentcore_api_v1, session_set_model) == 72, "metask_agentcore_api_v1.session_set_model offset");
METASK_AGENTCORE_STATIC_ASSERT(offsetof(metask_agentcore_api_v1, session_update_skills) == 80, "metask_agentcore_api_v1.session_update_skills offset");
METASK_AGENTCORE_STATIC_ASSERT(offsetof(metask_agentcore_api_v1, session_update_permission_rules) == 88, "metask_agentcore_api_v1.session_update_permission_rules offset");
METASK_AGENTCORE_STATIC_ASSERT(offsetof(metask_agentcore_api_v1, session_run_input) == 96, "metask_agentcore_api_v1.session_run_input offset");
METASK_AGENTCORE_STATIC_ASSERT(offsetof(metask_agentcore_api_v1, session_compact) == 112, "metask_agentcore_api_v1.session_compact offset");
METASK_AGENTCORE_STATIC_ASSERT(offsetof(metask_agentcore_api_v1, session_abort_compact) == 120, "metask_agentcore_api_v1.session_abort_compact offset");
METASK_AGENTCORE_STATIC_ASSERT(offsetof(metask_agentcore_api_v1, buffer_release) == 128, "metask_agentcore_api_v1.buffer_release offset");
METASK_AGENTCORE_STATIC_ASSERT(offsetof(metask_agentcore_api_v1, reserved) == 136, "metask_agentcore_api_v1.reserved offset");

#undef METASK_AGENTCORE_STATIC_ASSERT

#ifdef __cplusplus
}
#endif

#endif
