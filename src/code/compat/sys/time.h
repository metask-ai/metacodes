/*
 * QuickJS includes <sys/time.h> for gettimeofday. Windows/MSVC's UCRT has
 * neither, so supply the one call QuickJS makes (Date.now, Math.random seed)
 * from timespec_get. Every other target uses its own header.
 */
#if defined(_WIN32) && !defined(__MINGW32__)
#ifndef METACODES_COMPAT_SYS_TIME_H
#define METACODES_COMPAT_SYS_TIME_H
#include <time.h>

#ifndef _TIMEVAL_DEFINED
#define _TIMEVAL_DEFINED
struct timeval {
    long tv_sec;
    long tv_usec;
};
#endif

static inline int gettimeofday(struct timeval *tv, void *tz) {
    struct timespec ts;
    (void)tz;
    if (timespec_get(&ts, TIME_UTC) != TIME_UTC) return -1;
    tv->tv_sec = (long)ts.tv_sec;
    tv->tv_usec = (long)(ts.tv_nsec / 1000);
    return 0;
}
#endif
#else
#include_next <sys/time.h>
#endif
