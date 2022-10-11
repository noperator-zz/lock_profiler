#include "Python.h"

/* The following timer code comes from Python 2.5.2's _lsprof.c */

#if !defined(HAVE_LONG_LONG)
#error "This module requires long longs!"
#endif

/*** Selection of a high-precision timer ***/

#ifdef MS_WINDOWS

#include <windows.h>

PY_LONG_LONG
hpTimerUnit(void)
{
        static PY_LONG_LONG unit = 0;
        if (unit == 0) {
            LARGE_INTEGER li;
            unit = 1000000000 /
             (QueryPerformanceFrequency(&li) ? li.QuadPart :  1000000);
        }
        return unit;
}

PY_LONG_LONG
hpTimer(void)
{
        LARGE_INTEGER li;
        QueryPerformanceCounter(&li);
        return li.QuadPart * hpTimerUnit();
}

#elif (defined(PYOS_OS2) && defined(PYCC_GCC))

#include <sys/time.h>

PY_LONG_LONG
hpTimer(void)
{
        struct timeval tv;
        PY_LONG_LONG ret;
        gettimeofday(&tv, (struct timezone *)NULL);
        ret = tv.tv_sec;
        ret = ret * 1000000 + tv.tv_usec;
        return ret;
}

double
hpTimerUnit(void)
{
        return 0.000001;
}

#else

#include <sys/resource.h>
#include <sys/times.h>

PY_LONG_LONG
hpTimer(void)
{
        struct timespec ts;
        PY_LONG_LONG ret;
        clock_gettime(CLOCK_MONOTONIC, &ts);
        ret = ts.tv_sec * 1000000000 + ts.tv_nsec;
        return ret;
}

double
hpTimerUnit(void)
{
        return 0.000000001;
}

#endif
