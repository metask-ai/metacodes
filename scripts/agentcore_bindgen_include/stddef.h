#ifndef METASK_AGENTCORE_BINDGEN_STDDEF_H
#define METASK_AGENTCORE_BINDGEN_STDDEF_H

/* Generator-only definitions backed by the fixed Clang target's builtin types. */
typedef __SIZE_TYPE__ size_t;

#define offsetof(type, member) __builtin_offsetof(type, member)

#endif
