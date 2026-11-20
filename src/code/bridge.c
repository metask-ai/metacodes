#include "bridge.h"
#include "quickjs.h"
#include <stdlib.h>
#include <string.h>

#define MAX_CALLS 128
#define MAX_ARGS (256 * 1024)
#define MAX_OUTPUT (64 * 1024)
#define MAX_JOBS 100000

typedef struct {
    const char *name;
    const char *args;
    JSValue resolve, reject;
} request;

struct metacodes_js {
    JSRuntime *rt;
    JSContext *ctx;
    JSValue promise, logs;
    request requests[MAX_CALLS];
    unsigned count, cursor, jobs;
    size_t log_bytes;
    int active;
    metacodes_js_interrupt interrupt;
    void *opaque;
    const char *result, *error;
};

static int interrupt_vm(JSRuntime *rt, void *opaque) {
    (void)rt;
    metacodes_js *vm = opaque;
    return vm->interrupt && vm->interrupt(vm->opaque);
}

static int capture_error(metacodes_js *vm, JSValue error) {
    if (vm->error) JS_FreeCString(vm->ctx, vm->error);
    vm->error = JS_ToCString(vm->ctx, error);
    JS_FreeValue(vm->ctx, error);
    return -1;
}

static int capture_exception(metacodes_js *vm) {
    return capture_error(vm, JS_GetException(vm->ctx));
}

static JSValue request_tool(JSContext *ctx, JSValueConst this_val,
                            int argc, JSValueConst *argv) {
    (void)this_val;
    metacodes_js *vm = JS_GetContextOpaque(ctx);
    if (!vm->active || argc != 2 || !JS_IsString(argv[0]))
        return JS_ThrowTypeError(ctx, "invalid tool request");
    if (vm->count >= MAX_CALLS)
        return JS_ThrowRangeError(ctx, "ExecuteCode allows at most 128 tool calls");
    size_t name_len, args_len;
    const char *name = JS_ToCStringLen(ctx, &name_len, argv[0]);
    if (!name) return JS_EXCEPTION;
    if (!name_len || name_len > 256 || memchr(name, 0, name_len)) {
        JS_FreeCString(ctx, name);
        return JS_ThrowTypeError(ctx, "invalid tool name");
    }
    JSValue json = JS_JSONStringify(ctx, argv[1], JS_UNDEFINED, JS_UNDEFINED);
    if (JS_IsException(json) || JS_IsUndefined(json)) {
        JS_FreeCString(ctx, name);
        if (JS_IsUndefined(json)) return JS_ThrowTypeError(ctx, "tool args must be JSON");
        return json;
    }
    const char *args = JS_ToCStringLen(ctx, &args_len, json);
    JS_FreeValue(ctx, json);
    if (!args) { JS_FreeCString(ctx, name); return JS_EXCEPTION; }
    if (args_len > MAX_ARGS) {
        JS_FreeCString(ctx, name); JS_FreeCString(ctx, args);
        return JS_ThrowRangeError(ctx, "tool arguments exceed 256 KiB");
    }
    /* JSON.stringify can reenter through toJSON/getters and enqueue requests. */
    if (vm->count >= MAX_CALLS) {
        JS_FreeCString(ctx, name); JS_FreeCString(ctx, args);
        return JS_ThrowRangeError(ctx, "ExecuteCode allows at most 128 tool calls");
    }
    JSValue funcs[2];
    JSValue promise = JS_NewPromiseCapability(ctx, funcs);
    if (JS_IsException(promise)) {
        JS_FreeCString(ctx, name); JS_FreeCString(ctx, args);
        return promise;
    }
    vm->requests[vm->count++] = (request){name, args, funcs[0], funcs[1]};
    return promise;
}

static JSValue log_values(JSContext *ctx, JSValueConst this_val,
                          int argc, JSValueConst *argv) {
    (void)this_val;
    metacodes_js *vm = JS_GetContextOpaque(ctx);
    if (!vm->active) return JS_ThrowTypeError(ctx, "console.log outside evaluation");
    if (vm->log_bytes >= MAX_OUTPUT)
        return JS_ThrowRangeError(ctx, "ExecuteCode console output exceeds 64 KiB");
    char line[MAX_OUTPUT + 1];
    size_t used = 0;
    for (int i = 0; i < argc; i++) {
        size_t len;
        const char *str = JS_ToCStringLen(ctx, &len, argv[i]);
        if (!str) return JS_EXCEPTION;
        if (used + len + (i != 0) > MAX_OUTPUT - vm->log_bytes) {
            JS_FreeCString(ctx, str);
            return JS_ThrowRangeError(ctx, "ExecuteCode console output exceeds 64 KiB");
        }
        if (i) line[used++] = ' ';
        memcpy(line + used, str, len); used += len;
        JS_FreeCString(ctx, str);
    }
    if (used + 1 > MAX_OUTPUT - vm->log_bytes)
        return JS_ThrowRangeError(ctx, "ExecuteCode console output exceeds 64 KiB");
    vm->log_bytes += used + 1;
    JSValue len_val = JS_GetPropertyStr(ctx, vm->logs, "length");
    uint32_t index = 0;
    int rc = JS_ToUint32(ctx, &index, len_val);
    JS_FreeValue(ctx, len_val);
    if (rc) return JS_EXCEPTION;
    JSValue text = JS_NewStringLen(ctx, line, used);
    if (JS_IsException(text)) return text;
    if (JS_SetPropertyUint32(ctx, vm->logs, index, text) < 0) return JS_EXCEPTION;
    return JS_UNDEFINED;
}

metacodes_js *metacodes_js_new(const char *bootstrap, size_t len) {
    metacodes_js *vm = calloc(1, sizeof(*vm));
    if (!vm) return NULL;
    vm->promise = vm->logs = JS_UNDEFINED;
    vm->rt = JS_NewRuntime();
    if (!vm->rt) { free(vm); return NULL; }
    JS_SetMemoryLimit(vm->rt, 64 * 1024 * 1024);
    JS_SetMaxStackSize(vm->rt, 512 * 1024);
    vm->ctx = JS_NewContext(vm->rt);
    if (!vm->ctx) { JS_FreeRuntime(vm->rt); free(vm); return NULL; }
    JS_SetContextOpaque(vm->ctx, vm);
    JS_SetInterruptHandler(vm->rt, interrupt_vm, vm);
    JSValue global = JS_GetGlobalObject(vm->ctx);
    if (JS_SetPropertyStr(vm->ctx, global, "__mc_request", JS_NewCFunction(vm->ctx, request_tool, "request", 2)) < 0 ||
        JS_SetPropertyStr(vm->ctx, global, "__mc_log", JS_NewCFunction(vm->ctx, log_values, "log", 0)) < 0) {
        JS_FreeValue(vm->ctx, global); metacodes_js_free(vm); return NULL;
    }
    JS_FreeValue(vm->ctx, global);
    JSValue ret = JS_Eval(vm->ctx, bootstrap, len, "<tools>", JS_EVAL_TYPE_GLOBAL);
    if (JS_IsException(ret)) { JS_FreeValue(vm->ctx, ret); metacodes_js_free(vm); return NULL; }
    JS_FreeValue(vm->ctx, ret);
    return vm;
}

void metacodes_js_end(metacodes_js *vm) {
    for (unsigned i = 0; i < vm->count; i++) {
        request *req = &vm->requests[i];
        JS_FreeCString(vm->ctx, req->name); JS_FreeCString(vm->ctx, req->args);
        JS_FreeValue(vm->ctx, req->resolve); JS_FreeValue(vm->ctx, req->reject);
    }
    vm->count = vm->cursor = vm->jobs = 0;
    JS_FreeValue(vm->ctx, vm->promise); JS_FreeValue(vm->ctx, vm->logs);
    vm->promise = vm->logs = JS_UNDEFINED;
    if (vm->result) JS_FreeCString(vm->ctx, vm->result);
    if (vm->error) JS_FreeCString(vm->ctx, vm->error);
    vm->result = vm->error = NULL;
    vm->interrupt = NULL; vm->opaque = NULL; vm->active = 0; vm->log_bytes = 0;
}

void metacodes_js_free(metacodes_js *vm) {
    if (!vm) return;
    metacodes_js_end(vm);
    JS_FreeContext(vm->ctx); JS_FreeRuntime(vm->rt); free(vm);
}

int metacodes_js_begin(metacodes_js *vm, const char *source, size_t len,
                metacodes_js_interrupt interrupt, void *opaque) {
    vm->interrupt = interrupt; vm->opaque = opaque; vm->active = 1;
    JS_UpdateStackTop(vm->rt);
    vm->logs = JS_NewArray(vm->ctx);
    if (JS_IsException(vm->logs)) return capture_exception(vm);
    vm->promise = JS_Eval(vm->ctx, source, len, "<ExecuteCode>", JS_EVAL_FLAG_ASYNC);
    if (JS_IsException(vm->promise)) return capture_exception(vm);
    return 0;
}

int metacodes_js_poll(metacodes_js *vm) {
    JSContext *job_ctx;
    while (JS_IsJobPending(vm->rt)) {
        if (++vm->jobs > MAX_JOBS || interrupt_vm(vm->rt, vm)) {
            JS_ThrowRangeError(vm->ctx, "ExecuteCode interrupted or microtask limit exceeded");
            return capture_exception(vm);
        }
        int rc = JS_ExecutePendingJob(vm->rt, &job_ctx);
        if (rc < 0) return capture_exception(vm);
    }
    JSPromiseStateEnum state = JS_PromiseState(vm->ctx, vm->promise);
    if (state == JS_PROMISE_REJECTED)
        return capture_error(vm, JS_PromiseResult(vm->ctx, vm->promise));
    if (state == JS_PROMISE_FULFILLED) {
        if (vm->cursor != vm->count) {
            JS_ThrowTypeError(vm->ctx, "await every tool call before finishing ExecuteCode");
            return capture_exception(vm);
        }
        JSValue obj = JS_PromiseResult(vm->ctx, vm->promise);
        if (JS_SetPropertyStr(vm->ctx, obj, "logs", JS_DupValue(vm->ctx, vm->logs)) < 0 ||
            JS_SetPropertyStr(vm->ctx, obj, "tool_calls", JS_NewUint32(vm->ctx, vm->count)) < 0) {
            JS_FreeValue(vm->ctx, obj); return capture_exception(vm);
        }
        JSValue json = JS_JSONStringify(vm->ctx, obj, JS_UNDEFINED, JS_UNDEFINED);
        JS_FreeValue(vm->ctx, obj);
        if (JS_IsException(json)) return capture_exception(vm);
        if (vm->cursor != vm->count || JS_IsJobPending(vm->rt)) {
            JS_FreeValue(vm->ctx, json);
            JS_ThrowTypeError(vm->ctx, "result serialization must not start asynchronous work");
            return capture_exception(vm);
        }
        size_t len;
        vm->result = JS_ToCStringLen(vm->ctx, &len, json);
        JS_FreeValue(vm->ctx, json);
        if (!vm->result) return capture_exception(vm);
        if (len > MAX_OUTPUT) {
            JS_ThrowRangeError(vm->ctx, "ExecuteCode result exceeds 64 KiB; select a smaller value");
            return capture_exception(vm);
        }
        return 0;
    }
    return vm->cursor < vm->count ? 1 : -2;
}

const char *metacodes_js_name(metacodes_js *vm) { return vm->requests[vm->cursor].name; }
const char *metacodes_js_args(metacodes_js *vm) { return vm->requests[vm->cursor].args; }

int metacodes_js_complete(metacodes_js *vm, const char *bytes, size_t len, int is_error) {
    /* Like JS_Eval, QuickJS's lexer requires a zero beyond input_len. */
    char *terminated = js_malloc(vm->ctx, len + 1);
    if (!terminated) return capture_exception(vm);
    memcpy(terminated, bytes, len); terminated[len] = 0;
    JSValue value = JS_ParseJSON(vm->ctx, terminated, len, "<tool-result>");
    js_free(vm->ctx, terminated);
    if (JS_IsException(value)) {
        JS_FreeValue(vm->ctx, JS_GetException(vm->ctx));
        value = JS_NewStringLen(vm->ctx, bytes, len);
    }
    if (JS_IsException(value)) return capture_exception(vm);
    if (is_error) {
        JSValue error = JS_NewError(vm->ctx);
        if (JS_IsException(error)) {
            JS_FreeValue(vm->ctx, value); return capture_exception(vm);
        }
        JSValue message = JS_NewStringLen(vm->ctx, bytes, len);
        if (JS_IsException(message)) {
            JS_FreeValue(vm->ctx, error); JS_FreeValue(vm->ctx, value); return capture_exception(vm);
        }
        if (JS_SetPropertyStr(vm->ctx, error, "message", message) < 0) {
            JS_FreeValue(vm->ctx, error); JS_FreeValue(vm->ctx, value); return capture_exception(vm);
        }
        if (JS_SetPropertyStr(vm->ctx, error, "result", value) < 0) {
            JS_FreeValue(vm->ctx, error); return capture_exception(vm);
        }
        value = error;
    }
    request *req = &vm->requests[vm->cursor++];
    JSValue ret = JS_Call(vm->ctx, is_error ? req->reject : req->resolve, JS_UNDEFINED, 1, &value);
    JS_FreeValue(vm->ctx, value);
    if (JS_IsException(ret)) return capture_exception(vm);
    JS_FreeValue(vm->ctx, ret);
    return 0;
}

const char *metacodes_js_result(metacodes_js *vm) { return vm->result; }
const char *metacodes_js_error(metacodes_js *vm) { return vm->error ? vm->error : "JavaScript execution failed"; }
