#ifndef METACODES_CODE_BRIDGE_H
#define METACODES_CODE_BRIDGE_H
#include <stddef.h>

typedef struct metacodes_js metacodes_js;
typedef int (*metacodes_js_interrupt)(void *);
/* All returned strings are borrowed until end/free. Input buffers are copied.
 * A runtime belongs to one session and one executing thread at a time. */
metacodes_js *metacodes_js_new(const char *bootstrap, size_t len);
void metacodes_js_free(metacodes_js *vm);
int metacodes_js_begin(metacodes_js *vm, const char *source, size_t len,
                metacodes_js_interrupt interrupt, void *opaque);
/* 0: finished, 1: next host request, -1: JS exception, -2: unresolved promise. */
int metacodes_js_poll(metacodes_js *vm);
const char *metacodes_js_name(metacodes_js *vm);
const char *metacodes_js_args(metacodes_js *vm);
int metacodes_js_complete(metacodes_js *vm, const char *bytes, size_t len, int is_error);
const char *metacodes_js_result(metacodes_js *vm);
const char *metacodes_js_error(metacodes_js *vm);
void metacodes_js_end(metacodes_js *vm);
#endif
