/*
 * Wraps <stdlib.h> for the QuickJS translation units, which all include it
 * first (this directory is only on the code_runtime include path).
 *
 * - <stddef.h>, so cutils.h sees the compiler's offsetof. Without it (MinGW's
 *   <stdlib.h> does not pull it in) cutils.h falls back to
 *   `&((type *)0)->field`, which UBSan traps as a null member access in every
 *   list_entry.
 * - QuickJS calls alloca without including a header for it; Windows/MSVC
 *   declares it only in <malloc.h>.
 */
#include_next <stdlib.h>

#ifndef METACODES_COMPAT_STDLIB_H
#define METACODES_COMPAT_STDLIB_H
#include <stddef.h>
#if defined(_WIN32) && !defined(__MINGW32__)
#include <malloc.h>
#ifndef alloca
#define alloca _alloca
#endif
#endif
#endif
