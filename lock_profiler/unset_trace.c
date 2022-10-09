/* Hack to hide an <object>NULL from Cython. */

#include "Python.h"

void unset_trace() {
    PyEval_SetProfile(NULL, NULL);
//    PyEval_SetTrace(NULL, NULL);
}
