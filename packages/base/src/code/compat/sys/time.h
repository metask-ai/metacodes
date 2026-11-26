#ifndef METACODES_COMPAT_SYS_TIME_H
#define METACODES_COMPAT_SYS_TIME_H
/* Fallback for C runtimes without <sys/time.h> (Windows MSVC). It sits on the
 * after-include path, so a libc that has the header keeps its own. QuickJS only
 * reads the wall clock through gettimeofday. */
#include <time.h>

#ifndef _TIMEVAL_DEFINED
#define _TIMEVAL_DEFINED
struct timeval {
    long long tv_sec;
    long tv_usec;
};
#endif

static inline int gettimeofday(struct timeval *tv, void *tz) {
    struct timespec ts;
    (void)tz;
    if (timespec_get(&ts, TIME_UTC) != TIME_UTC) return -1;
    tv->tv_sec = (long long)ts.tv_sec;
    tv->tv_usec = (long)(ts.tv_nsec / 1000);
    return 0;
}

#endif
