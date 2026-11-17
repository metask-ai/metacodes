/* Node-API bridge to the AgentCore C ABI (sdk/metask/agentcore.h).
 *
 * The addon loads libmetask_agentcore at run time (dlopen), validates the
 * exact ABI revision with the header's own compatibility check, and exposes
 * a small set of functions that index.js wraps into the public API.
 *
 * Threading: a Run executes on a dedicated thread (never the libuv pool, which
 * a long agent Run would starve). AgentCore callbacks arrive on AgentCore
 * threads and are forwarded to JavaScript through one thread-safe function per
 * Session (events, UI requests, Run completion: one queue, so every event of a
 * Run reaches JavaScript before its completion) and one per Runtime (host tool
 * calls). Tool calls and UI requests block their AgentCore thread until
 * JavaScript answers through completeCall(); the JavaScript thread itself never
 * blocks on a Run.
 *
 * POSIX only for now (dlopen, pthreads); Windows is not supported yet. */

#define NAPI_VERSION 8
#include <node_api.h>

#include <metask/agentcore.h>

#include <dlfcn.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const metask_agentcore_api_v1 *g_api = NULL;

/* ---------- small helpers ---------- */

static const char *status_name(uint32_t status) {
    switch (status) {
    case METASK_AGENTCORE_STATUS_OK: return "OK";
    case METASK_AGENTCORE_STATUS_INVALID_ARGUMENT: return "INVALID_ARGUMENT";
    case METASK_AGENTCORE_STATUS_OUT_OF_MEMORY: return "OUT_OF_MEMORY";
    case METASK_AGENTCORE_STATUS_BUSY: return "BUSY";
    case METASK_AGENTCORE_STATUS_STALE_RUN: return "STALE_RUN";
    case METASK_AGENTCORE_STATUS_TOO_LATE: return "TOO_LATE";
    case METASK_AGENTCORE_STATUS_INVALID_STATE: return "INVALID_STATE";
    case METASK_AGENTCORE_STATUS_CORE_ERROR: return "CORE_ERROR";
    case METASK_AGENTCORE_STATUS_CALLBACK_FAILED: return "CALLBACK_FAILED";
    case METASK_AGENTCORE_STATUS_INTERNAL_ERROR: return "INTERNAL_ERROR";
    case METASK_AGENTCORE_STATUS_RESOURCE_LIMIT: return "RESOURCE_LIMIT";
    case METASK_AGENTCORE_STATUS_SKILL_CATALOG_INVALID: return "SKILL_CATALOG_INVALID";
    case METASK_AGENTCORE_STATUS_STALE_CATALOG: return "STALE_CATALOG";
    case METASK_AGENTCORE_STATUS_SKILL_NOT_FOUND: return "SKILL_NOT_FOUND";
    case METASK_AGENTCORE_STATUS_INVALID_SKILL_ARGUMENTS: return "INVALID_SKILL_ARGUMENTS";
    case METASK_AGENTCORE_STATUS_SKILL_POLICY_VIOLATION: return "SKILL_POLICY_VIOLATION";
    case METASK_AGENTCORE_STATUS_SKILL_UNAVAILABLE: return "SKILL_UNAVAILABLE";
    case METASK_AGENTCORE_STATUS_STALE_COMPACT: return "STALE_COMPACT";
    case METASK_AGENTCORE_STATUS_CHECKPOINT_BUDGET_REQUIRED: return "CHECKPOINT_BUDGET_REQUIRED";
    case METASK_AGENTCORE_STATUS_CHECKPOINT_CORRUPT: return "CHECKPOINT_CORRUPT";
    case METASK_AGENTCORE_STATUS_CHECKPOINT_UNSUPPORTED: return "CHECKPOINT_UNSUPPORTED";
    case METASK_AGENTCORE_STATUS_CHECKPOINT_INCOMPATIBLE: return "CHECKPOINT_INCOMPATIBLE";
    case METASK_AGENTCORE_STATUS_CHECKPOINT_IO: return "CHECKPOINT_IO";
    case METASK_AGENTCORE_STATUS_LOGICAL_SESSION_CONFLICT: return "LOGICAL_SESSION_CONFLICT";
    case METASK_AGENTCORE_STATUS_MCP_NOT_REFRESHED: return "MCP_NOT_REFRESHED";
    case METASK_AGENTCORE_STATUS_INVALID_MCP_SELECTION: return "INVALID_MCP_SELECTION";
    case METASK_AGENTCORE_STATUS_SKILL_CATALOG_INCOMPLETE: return "SKILL_CATALOG_INCOMPLETE";
    case METASK_AGENTCORE_STATUS_IMAGE_INPUT_UNSUPPORTED: return "IMAGE_INPUT_UNSUPPORTED";
    case METASK_AGENTCORE_STATUS_IMAGE_INPUT_CAPABILITY_UNKNOWN: return "IMAGE_INPUT_CAPABILITY_UNKNOWN";
    case METASK_AGENTCORE_STATUS_GOAL_CONFLICT: return "GOAL_CONFLICT";
    case METASK_AGENTCORE_STATUS_MESSAGE_POSITION_OUT_OF_RANGE: return "MESSAGE_POSITION_OUT_OF_RANGE";
    case METASK_AGENTCORE_STATUS_NOT_USER_MESSAGE: return "NOT_USER_MESSAGE";
    case METASK_AGENTCORE_STATUS_MESSAGE_POSITION_COMPACTED: return "MESSAGE_POSITION_COMPACTED";
    default: return "STATUS_ERROR";
    }
}

typedef struct {
    uint8_t *ptr;
    size_t len;
} owned_t;

static owned_t copy_bytes(const void *ptr, size_t len) {
    owned_t out = {NULL, 0};
    if (ptr == NULL || len == 0) return out;
    out.ptr = (uint8_t *)malloc(len);
    if (out.ptr == NULL) return out;
    memcpy(out.ptr, ptr, len);
    out.len = len;
    return out;
}

static metask_agentcore_bytes_view_v1 view_of(const owned_t *bytes) {
    metask_agentcore_bytes_view_v1 view = {NULL, 0};
    if (bytes != NULL && bytes->ptr != NULL && bytes->len != 0) {
        view.ptr = bytes->ptr;
        view.len = bytes->len;
    }
    return view;
}

/* Throws a JS Error whose `code` is the status name and whose message carries
 * the library diagnostic, then releases the diagnostic. */
static void throw_status(napi_env env, const char *operation, uint32_t status,
                         metask_agentcore_owned_bytes_v1 *diagnostic) {
    char message[1024];
    int used = snprintf(message, sizeof(message), "%s failed: %s", operation, status_name(status));
    if (diagnostic != NULL && diagnostic->ptr != NULL && diagnostic->len != 0 && used > 0 &&
        (size_t)used < sizeof(message) - 3) {
        size_t room = sizeof(message) - (size_t)used - 3;
        size_t take = diagnostic->len < room ? (size_t)diagnostic->len : room;
        memcpy(message + used, ": ", 2);
        memcpy(message + used + 2, diagnostic->ptr, take);
        message[used + 2 + take] = '\0';
    }
    if (diagnostic != NULL) g_api->buffer_release(diagnostic);
    napi_throw_error(env, status_name(status), message);
}

static int get_string(napi_env env, napi_value value, owned_t *out) {
    size_t len = 0;
    out->ptr = NULL;
    out->len = 0;
    napi_valuetype type;
    if (napi_typeof(env, value, &type) != napi_ok) return 0;
    if (type == napi_undefined || type == napi_null) return 1;
    if (type != napi_string) {
        napi_throw_type_error(env, NULL, "expected a string");
        return 0;
    }
    if (napi_get_value_string_utf8(env, value, NULL, 0, &len) != napi_ok) return 0;
    if (len == 0) return 1;
    out->ptr = (uint8_t *)malloc(len + 1);
    if (out->ptr == NULL) {
        napi_throw_error(env, NULL, "out of memory");
        return 0;
    }
    if (napi_get_value_string_utf8(env, value, (char *)out->ptr, len + 1, &len) != napi_ok) {
        free(out->ptr);
        out->ptr = NULL;
        return 0;
    }
    out->len = len;
    return 1;
}

static int get_property_string(napi_env env, napi_value object, const char *name, owned_t *out) {
    napi_value value;
    if (napi_get_named_property(env, object, name, &value) != napi_ok) return 0;
    return get_string(env, value, out);
}

static int get_property_u32(napi_env env, napi_value object, const char *name, uint32_t *out) {
    napi_value value;
    napi_valuetype type;
    *out = 0;
    if (napi_get_named_property(env, object, name, &value) != napi_ok) return 0;
    if (napi_typeof(env, value, &type) != napi_ok) return 0;
    if (type == napi_undefined || type == napi_null) return 1;
    return napi_get_value_uint32(env, value, out) == napi_ok;
}

/* A list of strings kept alive together with the views that borrow them. */
typedef struct {
    owned_t *items;
    metask_agentcore_bytes_view_v1 *views;
    uint32_t count;
} string_list_t;

static void free_list(string_list_t *list) {
    for (uint32_t i = 0; i < list->count; i++) free(list->items[i].ptr);
    free(list->items);
    free(list->views);
    memset(list, 0, sizeof(*list));
}

static int get_string_list(napi_env env, napi_value object, const char *name, string_list_t *out) {
    napi_value array;
    napi_valuetype type;
    bool is_array = false;
    memset(out, 0, sizeof(*out));
    if (napi_get_named_property(env, object, name, &array) != napi_ok) return 0;
    if (napi_typeof(env, array, &type) != napi_ok) return 0;
    if (type == napi_undefined || type == napi_null) return 1;
    if (napi_is_array(env, array, &is_array) != napi_ok || !is_array) {
        napi_throw_type_error(env, NULL, "expected an array of strings");
        return 0;
    }
    uint32_t count = 0;
    if (napi_get_array_length(env, array, &count) != napi_ok) return 0;
    if (count == 0) return 1;
    out->items = (owned_t *)calloc(count, sizeof(owned_t));
    out->views = (metask_agentcore_bytes_view_v1 *)calloc(count, sizeof(metask_agentcore_bytes_view_v1));
    if (out->items == NULL || out->views == NULL) {
        free_list(out);
        napi_throw_error(env, NULL, "out of memory");
        return 0;
    }
    for (uint32_t i = 0; i < count; i++) {
        napi_value element;
        if (napi_get_element(env, array, i, &element) != napi_ok ||
            !get_string(env, element, &out->items[i])) {
            out->count = i;
            free_list(out);
            return 0;
        }
        out->views[i] = view_of(&out->items[i]);
        out->count = i + 1;
    }
    return 1;
}

/* ---------- blocking calls into JavaScript (tool calls, UI requests) ---------- */

typedef struct {
    pthread_mutex_t mutex;
    pthread_cond_t cond;
    int done;
    uint32_t status;
    owned_t result;
} pending_t;

static void pending_init(pending_t *pending) {
    pthread_mutex_init(&pending->mutex, NULL);
    pthread_cond_init(&pending->cond, NULL);
    pending->done = 0;
    pending->status = 0;
    pending->result.ptr = NULL;
    pending->result.len = 0;
}

static void pending_finish(pending_t *pending, uint32_t status, owned_t result) {
    pthread_mutex_lock(&pending->mutex);
    if (!pending->done) {
        pending->status = status;
        pending->result = result;
        pending->done = 1;
        result.ptr = NULL;
    }
    pthread_cond_signal(&pending->cond);
    pthread_mutex_unlock(&pending->mutex);
    free(result.ptr);
}

static void pending_wait(pending_t *pending) {
    pthread_mutex_lock(&pending->mutex);
    while (!pending->done) pthread_cond_wait(&pending->cond, &pending->mutex);
    pthread_mutex_unlock(&pending->mutex);
    pthread_mutex_destroy(&pending->mutex);
    pthread_cond_destroy(&pending->cond);
}

enum message_kind { MSG_EVENT = 1, MSG_UI = 2, MSG_DONE = 3, MSG_TOOL = 4 };

typedef struct {
    enum message_kind kind;
    owned_t data;           /* event JSON, UI request JSON, tool arguments */
    pending_t *pending;     /* MSG_UI, MSG_TOOL */
    uint32_t tool_index;    /* MSG_TOOL */
    uint32_t status;        /* MSG_DONE */
    metask_agentcore_run_result_v1 result; /* MSG_DONE */
} message_t;

static napi_value make_external_pending(napi_env env, pending_t *pending) {
    napi_value external = NULL;
    napi_create_external(env, pending, NULL, NULL, &external);
    return external;
}

static napi_value make_string(napi_env env, const owned_t *bytes) {
    napi_value value = NULL;
    napi_create_string_utf8(env, bytes->ptr ? (const char *)bytes->ptr : "", bytes->len, &value);
    return value;
}

/* ---------- Runtime ---------- */

struct runtime_s;

typedef struct {
    struct runtime_s *runtime;
    uint32_t index;
} tool_ctx_t;

typedef struct runtime_s {
    metask_agentcore_runtime *handle;
    napi_threadsafe_function tsfn;
    tool_ctx_t *tool_contexts;
    owned_t *tool_strings; /* 3 per tool: name, description, schema */
    uint32_t tool_count;
    int destroyed;
} runtime_t;

static uint32_t host_execute(void *ctx, const metask_agentcore_run_context_v1 *run,
                             metask_agentcore_bytes_view_v1 arguments,
                             metask_agentcore_owned_bytes_v1 *out) {
    (void)run;
    tool_ctx_t *tool = (tool_ctx_t *)ctx;
    out->ptr = NULL;
    out->len = 0;
    pending_t pending;
    pending_init(&pending);
    message_t *message = (message_t *)calloc(1, sizeof(message_t));
    if (message == NULL) return METASK_AGENTCORE_HOST_FAILED;
    message->kind = MSG_TOOL;
    message->data = copy_bytes(arguments.ptr, (size_t)arguments.len);
    message->pending = &pending;
    message->tool_index = tool->index;
    if (napi_call_threadsafe_function(tool->runtime->tsfn, message, napi_tsfn_blocking) != napi_ok) {
        free(message->data.ptr);
        free(message);
        pending_finish(&pending, METASK_AGENTCORE_HOST_FAILED, copy_bytes("runtime is closing", 18));
    }
    pending_wait(&pending);
    out->ptr = pending.result.ptr;
    out->len = pending.result.len;
    return pending.status;
}

static void host_release(void *ctx, metask_agentcore_owned_bytes_v1 *owned) {
    (void)ctx;
    free(owned->ptr);
    owned->ptr = NULL;
    owned->len = 0;
}

static void runtime_call_js(napi_env env, napi_value callback, void *context, void *data) {
    (void)context;
    message_t *message = (message_t *)data;
    if (env == NULL) {
        if (message->pending) pending_finish(message->pending, METASK_AGENTCORE_HOST_FAILED, copy_bytes("runtime closed", 14));
        free(message->data.ptr);
        free(message);
        return;
    }
    napi_value argv[4];
    napi_value undefined;
    napi_get_undefined(env, &undefined);
    napi_create_string_utf8(env, "tool", NAPI_AUTO_LENGTH, &argv[0]);
    argv[1] = make_external_pending(env, message->pending);
    napi_create_uint32(env, message->tool_index, &argv[2]);
    argv[3] = make_string(env, &message->data);
    if (napi_call_function(env, undefined, callback, 4, argv, NULL) != napi_ok) {
        /* The JS wrapper never throws synchronously; if it does, fail the call. */
        napi_value ignored;
        napi_get_and_clear_last_exception(env, &ignored);
        pending_finish(message->pending, METASK_AGENTCORE_HOST_FAILED, copy_bytes("tool dispatch failed", 20));
    }
    free(message->data.ptr);
    free(message);
}

static void runtime_finalize(napi_env env, void *data, void *hint) {
    (void)env;
    (void)hint;
    runtime_t *runtime = (runtime_t *)data;
    if (!runtime->destroyed) return; /* still referenced by native state; leaked by design */
    free(runtime);
}

static runtime_t *get_runtime(napi_env env, napi_value value) {
    void *data = NULL;
    if (napi_get_value_external(env, value, &data) != napi_ok || data == NULL) {
        napi_throw_type_error(env, NULL, "expected a runtime handle");
        return NULL;
    }
    runtime_t *runtime = (runtime_t *)data;
    if (runtime->destroyed) {
        napi_throw_error(env, "INVALID_STATE", "runtime is closed");
        return NULL;
    }
    return runtime;
}

/* runtimeCreate(tools: string[], hostTools: {name, description, schema}[], dispatch) */
static napi_value runtime_create(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value argv[3];
    napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
    if (g_api == NULL) {
        napi_throw_error(env, "INVALID_STATE", "load() the AgentCore library first");
        return NULL;
    }
    napi_value holder;
    napi_create_object(env, &holder);
    napi_set_named_property(env, holder, "tools", argv[0]);
    string_list_t builtin;
    if (!get_string_list(env, holder, "tools", &builtin)) return NULL;

    uint32_t host_count = 0;
    napi_get_array_length(env, argv[1], &host_count);
    runtime_t *runtime = (runtime_t *)calloc(1, sizeof(runtime_t));
    metask_agentcore_host_tool_v1 *host_tools = NULL;
    if (runtime == NULL) {
        free_list(&builtin);
        napi_throw_error(env, NULL, "out of memory");
        return NULL;
    }
    if (host_count > 0) {
        runtime->tool_contexts = (tool_ctx_t *)calloc(host_count, sizeof(tool_ctx_t));
        runtime->tool_strings = (owned_t *)calloc((size_t)host_count * 3, sizeof(owned_t));
        host_tools = (metask_agentcore_host_tool_v1 *)calloc(host_count, sizeof(metask_agentcore_host_tool_v1));
        if (runtime->tool_contexts == NULL || runtime->tool_strings == NULL || host_tools == NULL) {
            napi_throw_error(env, NULL, "out of memory");
            goto fail;
        }
    }
    for (uint32_t i = 0; i < host_count; i++) {
        napi_value spec;
        napi_get_element(env, argv[1], i, &spec);
        if (!get_property_string(env, spec, "name", &runtime->tool_strings[i * 3]) ||
            !get_property_string(env, spec, "description", &runtime->tool_strings[i * 3 + 1]) ||
            !get_property_string(env, spec, "schema", &runtime->tool_strings[i * 3 + 2]))
            goto fail;
        runtime->tool_count = i + 1;
        runtime->tool_contexts[i].runtime = runtime;
        runtime->tool_contexts[i].index = i;
        host_tools[i].struct_size = (uint32_t)sizeof(host_tools[i]);
        host_tools[i].ctx = &runtime->tool_contexts[i];
        host_tools[i].name = view_of(&runtime->tool_strings[i * 3]);
        host_tools[i].description = view_of(&runtime->tool_strings[i * 3 + 1]);
        host_tools[i].input_schema_json = view_of(&runtime->tool_strings[i * 3 + 2]);
        host_tools[i].execute = host_execute;
        host_tools[i].release_result = host_release;
    }

    napi_value resource_name;
    napi_create_string_utf8(env, "metacodes.runtime", NAPI_AUTO_LENGTH, &resource_name);
    if (napi_create_threadsafe_function(env, argv[2], NULL, resource_name, 0, 1, NULL, NULL,
                                        runtime, runtime_call_js, &runtime->tsfn) != napi_ok) {
        napi_throw_error(env, NULL, "cannot create the tool dispatcher");
        goto fail;
    }
    napi_unref_threadsafe_function(env, runtime->tsfn);

    metask_agentcore_runtime_config_v1 config;
    memset(&config, 0, sizeof(config));
    config.struct_size = (uint32_t)sizeof(config);
    config.builtin_tools = builtin.views;
    config.builtin_tool_count = builtin.count;
    config.host_tools = host_tools;
    config.host_tool_count = host_count;
    metask_agentcore_owned_bytes_v1 diagnostic = {NULL, 0};
    uint32_t status = g_api->runtime->create(&config, NULL, &runtime->handle, &diagnostic);
    free_list(&builtin);
    free(host_tools);
    host_tools = NULL;
    if (status != METASK_AGENTCORE_STATUS_OK) {
        napi_release_threadsafe_function(runtime->tsfn, napi_tsfn_abort);
        runtime->tsfn = NULL;
        throw_status(env, "runtime.create", status, &diagnostic);
        goto fail_after_list;
    }
    g_api->buffer_release(&diagnostic);
    napi_value external;
    napi_create_external(env, runtime, runtime_finalize, NULL, &external);
    return external;

fail:
    free_list(&builtin);
fail_after_list:
    free(host_tools);
    for (uint32_t i = 0; i < runtime->tool_count * 3; i++) free(runtime->tool_strings[i].ptr);
    free(runtime->tool_strings);
    free(runtime->tool_contexts);
    free(runtime);
    return NULL;
}

static napi_value runtime_destroy(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1];
    napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
    runtime_t *runtime = get_runtime(env, argv[0]);
    if (runtime == NULL) return NULL;
    metask_agentcore_owned_bytes_v1 diagnostic = {NULL, 0};
    uint32_t status = g_api->runtime->destroy(runtime->handle, &diagnostic);
    if (status != METASK_AGENTCORE_STATUS_OK) {
        throw_status(env, "runtime.destroy", status, &diagnostic);
        return NULL;
    }
    g_api->buffer_release(&diagnostic);
    runtime->destroyed = 1;
    runtime->handle = NULL;
    napi_release_threadsafe_function(runtime->tsfn, napi_tsfn_release);
    for (uint32_t i = 0; i < runtime->tool_count * 3; i++) free(runtime->tool_strings[i].ptr);
    free(runtime->tool_strings);
    free(runtime->tool_contexts);
    runtime->tool_strings = NULL;
    runtime->tool_contexts = NULL;
    return NULL;
}

/* ---------- Session ---------- */

typedef struct {
    metask_agentcore_session *handle;
    napi_threadsafe_function tsfn;
    int destroyed;
    int running;
    uint64_t run_id;
    owned_t text;
    uint32_t max_turns;
    uint32_t stream_retry_budget;
} session_t;

static uint32_t session_on_event(void *ctx, const metask_agentcore_run_context_v1 *run,
                                 metask_agentcore_bytes_view_v1 event_json) {
    (void)run;
    session_t *session = (session_t *)ctx;
    message_t *message = (message_t *)calloc(1, sizeof(message_t));
    if (message == NULL) return METASK_AGENTCORE_EVENT_CONTINUE; /* observation only */
    message->kind = MSG_EVENT;
    message->data = copy_bytes(event_json.ptr, (size_t)event_json.len);
    if (napi_call_threadsafe_function(session->tsfn, message, napi_tsfn_blocking) != napi_ok) {
        free(message->data.ptr);
        free(message);
    }
    return METASK_AGENTCORE_EVENT_CONTINUE;
}

static uint32_t session_on_ui_request(void *ctx, const metask_agentcore_run_context_v1 *run,
                                      metask_agentcore_bytes_view_v1 request_json,
                                      metask_agentcore_owned_bytes_v1 *out) {
    (void)run;
    session_t *session = (session_t *)ctx;
    out->ptr = NULL;
    out->len = 0;
    pending_t pending;
    pending_init(&pending);
    message_t *message = (message_t *)calloc(1, sizeof(message_t));
    if (message == NULL) return METASK_AGENTCORE_UI_UNAVAILABLE;
    message->kind = MSG_UI;
    message->data = copy_bytes(request_json.ptr, (size_t)request_json.len);
    message->pending = &pending;
    if (napi_call_threadsafe_function(session->tsfn, message, napi_tsfn_blocking) != napi_ok) {
        free(message->data.ptr);
        free(message);
        owned_t none = {NULL, 0};
        pending_finish(&pending, METASK_AGENTCORE_UI_UNAVAILABLE, none);
    }
    pending_wait(&pending);
    out->ptr = pending.result.ptr;
    out->len = pending.result.len;
    return pending.status;
}

static void session_release_response(void *ctx, metask_agentcore_owned_bytes_v1 *owned) {
    (void)ctx;
    free(owned->ptr);
    owned->ptr = NULL;
    owned->len = 0;
}

static void session_call_js(napi_env env, napi_value callback, void *context, void *data) {
    session_t *session = (session_t *)context;
    message_t *message = (message_t *)data;
    if (env == NULL) {
        if (message->pending) {
            owned_t none = {NULL, 0};
            pending_finish(message->pending, METASK_AGENTCORE_UI_UNAVAILABLE, none);
        }
        free(message->data.ptr);
        free(message);
        return;
    }
    napi_value undefined;
    napi_get_undefined(env, &undefined);
    napi_value argv[3];
    size_t argc = 0;
    if (message->kind == MSG_EVENT) {
        napi_create_string_utf8(env, "event", NAPI_AUTO_LENGTH, &argv[0]);
        argv[1] = make_string(env, &message->data);
        argc = 2;
    } else if (message->kind == MSG_UI) {
        napi_create_string_utf8(env, "ui", NAPI_AUTO_LENGTH, &argv[0]);
        argv[1] = make_external_pending(env, message->pending);
        argv[2] = make_string(env, &message->data);
        argc = 3;
    } else {
        session->running = 0;
        napi_unref_threadsafe_function(env, session->tsfn);
        free(session->text.ptr);
        session->text.ptr = NULL;
        session->text.len = 0;
        napi_value result, value;
        napi_create_object(env, &result);
        napi_create_uint32(env, message->status, &value);
        napi_set_named_property(env, result, "status", value);
        napi_create_string_utf8(env, status_name(message->status), NAPI_AUTO_LENGTH, &value);
        napi_set_named_property(env, result, "statusName", value);
        napi_create_uint32(env, message->result.stop_reason_code, &value);
        napi_set_named_property(env, result, "stopReasonCode", value);
        napi_create_uint32(env, message->result.turns, &value);
        napi_set_named_property(env, result, "turns", value);
        napi_create_uint32(env, message->result.tool_calls, &value);
        napi_set_named_property(env, result, "toolCalls", value);
        napi_create_uint32(env, message->result.input_accepted_count, &value);
        napi_set_named_property(env, result, "inputAccepted", value);
        napi_create_uint32(env, message->result.input_adopted_count, &value);
        napi_set_named_property(env, result, "inputAdopted", value);
        napi_set_named_property(env, result, "diagnostic", make_string(env, &message->data));
        napi_create_string_utf8(env, "done", NAPI_AUTO_LENGTH, &argv[0]);
        argv[1] = result;
        argc = 2;
    }
    if (napi_call_function(env, undefined, callback, argc, argv, NULL) != napi_ok) {
        napi_value ignored;
        napi_get_and_clear_last_exception(env, &ignored);
        if (message->kind == MSG_UI) {
            owned_t none = {NULL, 0};
            pending_finish(message->pending, METASK_AGENTCORE_UI_UNAVAILABLE, none);
        }
    }
    free(message->data.ptr);
    free(message);
}

static void session_finalize(napi_env env, void *data, void *hint) {
    (void)env;
    (void)hint;
    session_t *session = (session_t *)data;
    if (!session->destroyed) return; /* an open Session is owned by AgentCore; leak rather than free */
    free(session);
}

static session_t *get_session(napi_env env, napi_value value) {
    void *data = NULL;
    if (napi_get_value_external(env, value, &data) != napi_ok || data == NULL) {
        napi_throw_type_error(env, NULL, "expected a session handle");
        return NULL;
    }
    session_t *session = (session_t *)data;
    if (session->destroyed) {
        napi_throw_error(env, "INVALID_STATE", "session is closed");
        return NULL;
    }
    return session;
}

/* sessionCreate(runtime, config, dispatch) */
static napi_value session_create(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value argv[3];
    napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
    runtime_t *runtime = get_runtime(env, argv[0]);
    if (runtime == NULL) return NULL;
    napi_value cfg = argv[1];

    owned_t api_key = {0}, base_url = {0}, workspace_root = {0}, workspace_home = {0}, model = {0};
    string_list_t tools = {0}, allow = {0}, ask = {0}, deny = {0};
    metask_agentcore_session_host_config_v1 host;
    memset(&host, 0, sizeof(host));
    host.struct_size = (uint32_t)sizeof(host);
    session_t *session = NULL;
    napi_value external = NULL;

    if (!get_property_u32(env, cfg, "provider", &host.provider_kind_code) ||
        !get_property_u32(env, cfg, "protocol", &host.protocol_kind_code) ||
        !get_property_u32(env, cfg, "permissionMode", &host.permission_mode_code) ||
        !get_property_u32(env, cfg, "shell", &host.shell_policy_code) ||
        !get_property_string(env, cfg, "apiKey", &api_key) ||
        !get_property_string(env, cfg, "baseUrl", &base_url) ||
        !get_property_string(env, cfg, "workspaceRoot", &workspace_root) ||
        !get_property_string(env, cfg, "workspaceHome", &workspace_home) ||
        !get_property_string(env, cfg, "model", &model) ||
        !get_string_list(env, cfg, "tools", &tools) ||
        !get_string_list(env, cfg, "allow", &allow) ||
        !get_string_list(env, cfg, "ask", &ask) ||
        !get_string_list(env, cfg, "deny", &deny))
        goto done;

    host.api_key = view_of(&api_key);
    host.base_url = view_of(&base_url);
    host.workspace_root = view_of(&workspace_root);
    host.workspace_home = view_of(&workspace_home);
    host.allowed_tools = tools.views;
    host.allowed_tool_count = tools.count;
    metask_agentcore_permission_rule_set_v1 rules;
    memset(&rules, 0, sizeof(rules));
    if (allow.count || ask.count || deny.count) {
        rules.struct_size = (uint32_t)sizeof(rules);
        rules.allow = allow.views;
        rules.allow_count = allow.count;
        rules.ask = ask.views;
        rules.ask_count = ask.count;
        rules.deny = deny.views;
        rules.deny_count = deny.count;
        host.permission_rules = &rules;
    }
    metask_agentcore_session_create_config_v1 config;
    memset(&config, 0, sizeof(config));
    config.struct_size = (uint32_t)sizeof(config);
    config.host = &host;
    config.model = view_of(&model);

    session = (session_t *)calloc(1, sizeof(session_t));
    if (session == NULL) {
        napi_throw_error(env, NULL, "out of memory");
        goto done;
    }
    napi_value resource_name;
    napi_create_string_utf8(env, "metacodes.session", NAPI_AUTO_LENGTH, &resource_name);
    if (napi_create_threadsafe_function(env, argv[2], NULL, resource_name, 0, 1, NULL, NULL,
                                        session, session_call_js, &session->tsfn) != napi_ok) {
        napi_throw_error(env, NULL, "cannot create the event dispatcher");
        free(session);
        session = NULL;
        goto done;
    }
    napi_unref_threadsafe_function(env, session->tsfn);

    metask_agentcore_session_callbacks_v1 callbacks;
    memset(&callbacks, 0, sizeof(callbacks));
    callbacks.struct_size = (uint32_t)sizeof(callbacks);
    callbacks.ctx = session;
    callbacks.on_event = session_on_event;
    callbacks.on_ui_request = session_on_ui_request;
    callbacks.release_response = session_release_response;
    metask_agentcore_owned_bytes_v1 diagnostic = {NULL, 0};
    uint32_t status = g_api->session->create(runtime->handle, &config, &callbacks, &session->handle, &diagnostic);
    if (status != METASK_AGENTCORE_STATUS_OK) {
        napi_release_threadsafe_function(session->tsfn, napi_tsfn_abort);
        free(session);
        session = NULL;
        throw_status(env, "session.create", status, &diagnostic);
        goto done;
    }
    g_api->buffer_release(&diagnostic);
    napi_create_external(env, session, session_finalize, NULL, &external);

done:
    free(api_key.ptr);
    free(base_url.ptr);
    free(workspace_root.ptr);
    free(workspace_home.ptr);
    free(model.ptr);
    free_list(&tools);
    free_list(&allow);
    free_list(&ask);
    free_list(&deny);
    return external;
}

static void *run_thread(void *arg) {
    session_t *session = (session_t *)arg;
    metask_agentcore_run_input_v1 input;
    memset(&input, 0, sizeof(input));
    input.struct_size = (uint32_t)sizeof(input);
    input.kind_code = METASK_AGENTCORE_RUN_INPUT_TEXT;
    input.text = view_of(&session->text);
    metask_agentcore_run_options_v1 options;
    memset(&options, 0, sizeof(options));
    options.struct_size = (uint32_t)sizeof(options);
    options.max_turns = session->max_turns;
    options.stream_retry_budget = session->stream_retry_budget;
    message_t *message = (message_t *)calloc(1, sizeof(message_t));
    metask_agentcore_run_result_v1 local_result;
    metask_agentcore_run_result_v1 *result = message ? &message->result : &local_result;
    memset(result, 0, sizeof(*result));
    result->struct_size = (uint32_t)sizeof(*result);
    metask_agentcore_owned_bytes_v1 diagnostic = {NULL, 0};
    uint32_t status = g_api->session->run_input(session->handle, session->run_id, &input, &options, result, &diagnostic);
    if (message == NULL) {
        g_api->buffer_release(&diagnostic);
        return NULL; /* out of memory: the Promise cannot be settled */
    }
    message->kind = MSG_DONE;
    message->status = status;
    message->data = copy_bytes(diagnostic.ptr, (size_t)diagnostic.len);
    g_api->buffer_release(&diagnostic);
    if (napi_call_threadsafe_function(session->tsfn, message, napi_tsfn_blocking) != napi_ok) {
        free(message->data.ptr);
        free(message);
    }
    return NULL;
}

/* sessionRun(session, runId, text, maxTurns, streamRetryBudget): starts the Run;
 * completion is a "done" dispatch. */
static napi_value session_run(napi_env env, napi_callback_info info) {
    size_t argc = 5;
    napi_value argv[5];
    napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
    session_t *session = get_session(env, argv[0]);
    if (session == NULL) return NULL;
    if (session->running) {
        napi_throw_error(env, "BUSY", "a Run is already active on this session");
        return NULL;
    }
    int64_t run_id = 0;
    uint32_t max_turns = 0;
    uint32_t stream_retry_budget = 0;
    owned_t text;
    if (argc < 5 || napi_get_value_int64(env, argv[1], &run_id) != napi_ok || run_id <= 0 ||
        napi_get_value_uint32(env, argv[3], &max_turns) != napi_ok ||
        napi_get_value_uint32(env, argv[4], &stream_retry_budget) != napi_ok || !get_string(env, argv[2], &text)) {
        bool pending = false;
        napi_is_exception_pending(env, &pending);
        if (!pending) napi_throw_type_error(env, NULL, "invalid Run arguments");
        return NULL;
    }
    session->run_id = (uint64_t)run_id;
    session->text = text;
    session->max_turns = max_turns;
    session->stream_retry_budget = stream_retry_budget;
    session->running = 1;
    napi_ref_threadsafe_function(env, session->tsfn);
    pthread_t thread;
    pthread_attr_t attributes;
    pthread_attr_init(&attributes);
    pthread_attr_setdetachstate(&attributes, PTHREAD_CREATE_DETACHED);
    pthread_attr_setstacksize(&attributes, 8 * 1024 * 1024);
    int failed = pthread_create(&thread, &attributes, run_thread, session);
    pthread_attr_destroy(&attributes);
    if (failed) {
        session->running = 0;
        napi_unref_threadsafe_function(env, session->tsfn);
        free(session->text.ptr);
        session->text.ptr = NULL;
        napi_throw_error(env, NULL, "cannot start the Run thread");
    }
    return NULL;
}

static napi_value session_abort(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value argv[2];
    napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
    session_t *session = get_session(env, argv[0]);
    if (session == NULL) return NULL;
    int64_t run_id = 0;
    napi_get_value_int64(env, argv[1], &run_id);
    metask_agentcore_owned_bytes_v1 diagnostic = {NULL, 0};
    uint32_t status = g_api->session->abort(session->handle, (uint64_t)run_id, METASK_AGENTCORE_ABORT_USER_REQUEST, &diagnostic);
    g_api->buffer_release(&diagnostic);
    napi_value value;
    napi_create_uint32(env, status, &value);
    return value;
}

/* sessionSubmit(session, runId, inputId, text) -> receipt sequence */
static napi_value session_submit(napi_env env, napi_callback_info info) {
    size_t argc = 4;
    napi_value argv[4];
    napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
    session_t *session = get_session(env, argv[0]);
    if (session == NULL) return NULL;
    int64_t run_id = 0, input_id = 0;
    owned_t text;
    napi_get_value_int64(env, argv[1], &run_id);
    napi_get_value_int64(env, argv[2], &input_id);
    if (!get_string(env, argv[3], &text)) return NULL;
    metask_agentcore_submitted_input_v1 input;
    memset(&input, 0, sizeof(input));
    input.struct_size = (uint32_t)sizeof(input);
    input.input_id = (uint64_t)input_id;
    input.text = view_of(&text);
    metask_agentcore_input_receipt_v1 receipt;
    memset(&receipt, 0, sizeof(receipt));
    receipt.struct_size = (uint32_t)sizeof(receipt);
    metask_agentcore_owned_bytes_v1 diagnostic = {NULL, 0};
    uint32_t status = g_api->session->submit_input(session->handle, (uint64_t)run_id, &input, &receipt, &diagnostic);
    free(text.ptr);
    if (status != METASK_AGENTCORE_STATUS_OK) {
        throw_status(env, "session.submit_input", status, &diagnostic);
        return NULL;
    }
    g_api->buffer_release(&diagnostic);
    napi_value value;
    napi_create_uint32(env, receipt.sequence, &value);
    return value;
}

/* Zero a secret copy through volatile stores, which the compiler may not
 * drop as dead before free, then release it. */
static void erase_and_free(owned_t *bytes) {
    volatile uint8_t *cursor = bytes->ptr;
    for (size_t i = 0; cursor != NULL && i < bytes->len; i++) cursor[i] = 0;
    free(bytes->ptr);
    bytes->ptr = NULL;
    bytes->len = 0;
}

/* sessionUpdateCredential(session, apiKey): Revision 25. Runs on the JS
 * thread, which also owns destroy, so an update never races the release. */
static napi_value session_update_credential(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value argv[2];
    napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
    session_t *session = get_session(env, argv[0]);
    if (session == NULL) return NULL;
    owned_t credential;
    if (!get_string(env, argv[1], &credential)) return NULL;
    metask_agentcore_owned_bytes_v1 diagnostic = {NULL, 0};
    uint32_t status = g_api->session->update_credential(session->handle, view_of(&credential), &diagnostic);
    erase_and_free(&credential);
    if (status != METASK_AGENTCORE_STATUS_OK) {
        throw_status(env, "session.update_credential", status, &diagnostic);
        return NULL;
    }
    g_api->buffer_release(&diagnostic);
    return NULL;
}

static napi_value session_describe(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1];
    napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
    session_t *session = get_session(env, argv[0]);
    if (session == NULL) return NULL;
    metask_agentcore_owned_bytes_v1 output = {NULL, 0}, diagnostic = {NULL, 0};
    uint32_t status = g_api->session_control->describe(session->handle, &output, &diagnostic);
    if (status != METASK_AGENTCORE_STATUS_OK) {
        g_api->buffer_release(&output);
        throw_status(env, "session.describe", status, &diagnostic);
        return NULL;
    }
    g_api->buffer_release(&diagnostic);
    napi_value value;
    napi_create_string_utf8(env, output.ptr ? (const char *)output.ptr : "", (size_t)output.len, &value);
    g_api->buffer_release(&output);
    return value;
}

static napi_value session_set_model(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value argv[2];
    napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
    session_t *session = get_session(env, argv[0]);
    if (session == NULL) return NULL;
    owned_t model;
    if (!get_string(env, argv[1], &model)) return NULL;
    metask_agentcore_owned_bytes_v1 diagnostic = {NULL, 0};
    uint32_t status = g_api->session_control->set_model(session->handle, view_of(&model), &diagnostic);
    free(model.ptr);
    if (status != METASK_AGENTCORE_STATUS_OK) {
        throw_status(env, "session.set_model", status, &diagnostic);
        return NULL;
    }
    g_api->buffer_release(&diagnostic);
    return NULL;
}

static napi_value session_set_permission_mode(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value argv[2];
    napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
    session_t *session = get_session(env, argv[0]);
    if (session == NULL) return NULL;
    uint32_t mode = 0;
    napi_get_value_uint32(env, argv[1], &mode);
    metask_agentcore_owned_bytes_v1 diagnostic = {NULL, 0};
    uint32_t status = g_api->session_control->update_permission_mode(session->handle, mode, &diagnostic);
    if (status != METASK_AGENTCORE_STATUS_OK) {
        throw_status(env, "session.update_permission_mode", status, &diagnostic);
        return NULL;
    }
    g_api->buffer_release(&diagnostic);
    return NULL;
}

/* sessionRewindToUserMessage(session, position): index.js has checked that
 * position is a safe integer >= 1. */
static napi_value session_rewind_to_user_message(napi_env env, napi_callback_info info) {
    size_t argc = 2;
    napi_value argv[2];
    napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
    session_t *session = get_session(env, argv[0]);
    if (session == NULL) return NULL;
    int64_t position = 0;
    if (napi_get_value_int64(env, argv[1], &position) != napi_ok || position < 1) {
        napi_throw_type_error(env, NULL, "position must be a positive integer");
        return NULL;
    }
    metask_agentcore_owned_bytes_v1 diagnostic = {NULL, 0};
    uint32_t status = g_api->session_control->rewind_to_user_message(session->handle, (uint64_t)position, &diagnostic);
    if (status != METASK_AGENTCORE_STATUS_OK) {
        throw_status(env, "session.rewind_to_user_message", status, &diagnostic);
        return NULL;
    }
    g_api->buffer_release(&diagnostic);
    return NULL;
}

static napi_value session_destroy(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1];
    napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
    session_t *session = get_session(env, argv[0]);
    if (session == NULL) return NULL;
    if (session->running) {
        napi_throw_error(env, "BUSY", "cannot close a session while a Run is active");
        return NULL;
    }
    metask_agentcore_owned_bytes_v1 diagnostic = {NULL, 0};
    uint32_t status = g_api->session->destroy(session->handle, &diagnostic);
    if (status != METASK_AGENTCORE_STATUS_OK) {
        throw_status(env, "session.destroy", status, &diagnostic);
        return NULL;
    }
    g_api->buffer_release(&diagnostic);
    session->destroyed = 1;
    session->handle = NULL;
    napi_release_threadsafe_function(session->tsfn, napi_tsfn_release);
    return NULL;
}

/* completeCall(pendingExternal, status, text?) answers a tool call or UI request. */
static napi_value complete_call(napi_env env, napi_callback_info info) {
    size_t argc = 3;
    napi_value argv[3];
    napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
    void *data = NULL;
    uint32_t status = 0;
    owned_t text;
    if (napi_get_value_external(env, argv[0], &data) != napi_ok || data == NULL ||
        napi_get_value_uint32(env, argv[1], &status) != napi_ok || !get_string(env, argv[2], &text)) {
        napi_throw_type_error(env, NULL, "invalid completion");
        return NULL;
    }
    pending_finish((pending_t *)data, status, text);
    return NULL;
}

/* load(path) -> ABI revision */
static napi_value load_library(napi_env env, napi_callback_info info) {
    size_t argc = 1;
    napi_value argv[1];
    napi_get_cb_info(env, info, &argc, argv, NULL, NULL);
    if (g_api == NULL) {
        owned_t path;
        if (!get_string(env, argv[0], &path)) return NULL;
        if (path.ptr == NULL) {
            napi_throw_type_error(env, NULL, "library path required");
            return NULL;
        }
        void *library = dlopen((const char *)path.ptr, RTLD_NOW | RTLD_LOCAL);
        free(path.ptr);
        if (library == NULL) {
            napi_throw_error(env, "LOAD_FAILED", dlerror());
            return NULL;
        }
        const void *(*get_api)(uint32_t) = (const void *(*)(uint32_t))dlsym(library, "metask_agentcore_get_api");
        if (get_api == NULL) {
            dlclose(library);
            napi_throw_error(env, "LOAD_FAILED", "metask_agentcore_get_api not exported");
            return NULL;
        }
        const metask_agentcore_api_v1 *api = (const metask_agentcore_api_v1 *)get_api(METASK_AGENTCORE_ABI_V1);
        if (!metask_agentcore_api_v1_is_compatible(api)) {
            dlclose(library);
            napi_throw_error(env, "ABI_MISMATCH",
                             "library does not provide AgentCore ABI v1 revision " "28" " with the expected layout");
            return NULL;
        }
        g_api = api; /* the library stays loaded for the life of the process */
    }
    napi_value value;
    napi_create_uint32(env, g_api->abi_revision, &value);
    return value;
}

#define EXPORT(name, function)                                              \
    do {                                                                    \
        napi_value fn;                                                      \
        napi_create_function(env, name, NAPI_AUTO_LENGTH, function, NULL, &fn); \
        napi_set_named_property(env, exports, name, fn);                    \
    } while (0)

NAPI_MODULE_INIT() {
    EXPORT("load", load_library);
    EXPORT("runtimeCreate", runtime_create);
    EXPORT("runtimeDestroy", runtime_destroy);
    EXPORT("sessionCreate", session_create);
    EXPORT("sessionRun", session_run);
    EXPORT("sessionAbort", session_abort);
    EXPORT("sessionSubmit", session_submit);
    EXPORT("sessionUpdateCredential", session_update_credential);
    EXPORT("sessionDescribe", session_describe);
    EXPORT("sessionSetModel", session_set_model);
    EXPORT("sessionSetPermissionMode", session_set_permission_mode);
    EXPORT("sessionRewindToUserMessage", session_rewind_to_user_message);
    EXPORT("sessionDestroy", session_destroy);
    EXPORT("completeCall", complete_call);
    napi_value revision;
    napi_create_uint32(env, METASK_AGENTCORE_ABI_REVISION, &revision);
    napi_set_named_property(env, exports, "abiRevision", revision);
    return exports;
}
