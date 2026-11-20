#ifndef METACODES_QUICKJS_PORT_H
#define METACODES_QUICKJS_PORT_H
/* Forced ahead of every QuickJS translation unit (-include) so vendor/quickjs
 * stays byte-for-byte upstream. */

/* cutils.h falls back to a null-pointer offsetof unless a libc header already
 * defined it; mingw's headers do not, and Debug UBSan rejects that form. */
#include <stddef.h>

#if defined(_WIN32) && !defined(__MINGW32__)
/* The UCRT declares _msize and _alloca only in <malloc.h>, which QuickJS
 * includes for Linux alone. */
#include <malloc.h>
#ifndef alloca
#define alloca _alloca
#endif
#endif

#endif
