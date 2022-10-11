#cython: language_level=3
from .python25 cimport PyFrameObject, PyObject, PyStringObject
from sys import byteorder
cimport cython
from cpython.version cimport PY_VERSION_HEX
from libc.stdint cimport int64_t

from libcpp.unordered_map cimport unordered_map
from libcpp.vector cimport vector
import threading
import typing
from dataclasses import dataclass

# long long int is at least 64 bytes assuming c99
ctypedef unsigned long long int uint64
ctypedef long long int int64

# FIXME: there might be something special we have to do here for Python 3.11
cdef extern from "frameobject.h":
    """
    inline PyObject* get_frame_code(PyFrameObject* frame) {
        #if PY_VERSION_HEX < 0x030B0000
            Py_INCREF(frame->f_code->co_code);
            return frame->f_code->co_code;
        #else
            PyCodeObject* code = PyFrame_GetCode(frame);
            PyObject* ret = PyCode_GetCode(code);
            Py_DECREF(code);
            return ret;
        #endif
    }
    """
    cdef object get_frame_code(PyFrameObject* frame)
    ctypedef int (*Py_tracefunc)(object self, PyFrameObject *py_frame, int what, PyObject *arg)

cdef extern from "Python.h":
    """
    // CPython 3.11 broke some stuff by moving PyFrameObject :(
    #if PY_VERSION_HEX >= 0x030b00a6
      #ifndef Py_BUILD_CORE
        #define Py_BUILD_CORE 1
      #endif
      #include "internal/pycore_frame.h"
      #include "cpython/code.h"
      #include "pyframe.h"
    #endif
    """
    
    ctypedef struct PyFrameObject
    ctypedef struct PyCodeObject
    ctypedef long long PY_LONG_LONG
    cdef bint PyCFunction_Check(object obj)
    cdef int PyCode_Addr2Line(PyCodeObject *co, int byte_offset)

    cdef void PyEval_SetProfile(Py_tracefunc func, object arg)

    ctypedef object (*PyCFunction)(object self, object args)

    ctypedef struct PyMethodDef:
        char *ml_name
        PyCFunction ml_meth
        int ml_flags
        char *ml_doc

    ctypedef struct PyCFunctionObject:
        PyMethodDef *m_ml
        PyObject *m_self
        PyObject *m_module

    # They're actually #defines, but whatever.
    cdef int PyTrace_CALL
    cdef int PyTrace_EXCEPTION
    cdef int PyTrace_LINE
    cdef int PyTrace_RETURN
    cdef int PyTrace_C_CALL
    cdef int PyTrace_C_EXCEPTION
    cdef int PyTrace_C_RETURN

lut = {
    PyTrace_CALL:        "CALL",
    PyTrace_EXCEPTION:   "EXCEPTION",
    PyTrace_LINE:        "LINE",
    PyTrace_RETURN:      "RETURN",
    PyTrace_C_CALL:      "C_CALL",
    PyTrace_C_EXCEPTION: "C_EXCEPTION",
    PyTrace_C_RETURN:    "C_RETURN",
}

cdef extern from "timers.c":
    PY_LONG_LONG hpTimer()
    double hpTimerUnit()

cdef extern from "unset_trace.c":
    void unset_trace()


cdef struct CLockTime:
    # When acquire was called
    PY_LONG_LONG timestamp
    # Which thread called it
    int64_t tid
    # Which lock it was called on
    int64 lock_hash
    # Hash of the call stack
    int64_t stack_hash
    # How long acquire took
    PY_LONG_LONG duration

@dataclass
class LockTime:
    timestamp: float
    tid: int
    lock_hash: int
    stack_hash: int
    duration: float

# Keeps track of one lock acquisition
cdef struct LockInfo:
    # Set when acquire is called
    PY_LONG_LONG timestamp
    # Hash of the call stack
    int64_t stack_hash

# @dataclass
# class StackFrame:
#     filename: str
#     funcname: str
#     lineno: int
# cdef struct StackFrame:
#     char* filename
#     char* funcname
#     int lineno

# StackType = typing.Tuple[typing.Tuple[str, str, int], ...]
# cdef struct StackInfo:
#     str stack

# Note: this is a regular Python class to allow easy pickling.
@dataclass
class LockStats:
    lock_hashes: typing.Dict[int, str]
    stack_hashes: typing.Dict[int, typing.Any]
    lock_list: typing.List[LockTime]


# Mapping between thread-id and LockInfo
cdef unordered_map[int64, LockInfo] _c_lock_map
# List of all acquire events
cdef vector[CLockTime] _c_lock_list

# Mapping between call stack hash and call stack
# cdef unordered_map[int64, vector[StackFrame]] _c_stack_map
_stack_map = {}
_lock_strs = {}

cdef class LockProfiler:

    def __init__(self):
        pass

    @staticmethod
    def enable(obj):
        h = hash(obj._lock)
        if h not in _lock_strs:
            _lock_strs[h] = str(obj)
        # TODO maybe compute stack here. This way the callback is as short as possible. But we don't have py_frame here

        # _c_lock_map[threading.get_ident()]
        PyEval_SetProfile(python_trace_callback, obj._lock)
        # trace_callback(obj._lock, PyTrace_C_CALL)

    @staticmethod
    def disable():
        # trace_callback(obj._lock, PyTrace_C_RETURN)
        unset_trace()

    @staticmethod
    def notify_release(obj):
        # When duration is negative, this is a release
        # stack, stack_hash = get_stack()

        _c_lock_list.push_back(CLockTime(
            hpTimer(),
            threading.get_ident(),
            hash(obj._lock),
            0,#stack_hash,
            -1,
        ))

    def get_stats(self) -> LockStats:
        """ Return a LineStats object containing the timings.
        """
        cdef dict cmap

        # offset = _c_lock_list[0].timestamp if len(_c_lock_list) else 0
        # lock_list = _c_lock_list[:]
        # for t in lock_list:
        #     t.timestamp -= offset

        output = LockStats(
            _lock_strs,
            # # Remove frames in Lockable.py
            # {k:
            #      tuple(frame for frame in v if not frame[0].endswith("Lockable.py"))
            #  for k, v in _stack_map.items()},
            # _c_stack_map,
            _stack_map,
            [LockTime(*a.values()) for a in _c_lock_list],
            # tuple(CLockTime(t[0] - offset, *t[1:]) for t in _c_lock_list),
        )
        return output


import sys
# def get_stack(skip=2):
#     # f = sys._getframe()
#     #
#     # while skip and f:
#     #     skip -= 1
#     #     f = f.f_back
#     #
#     # s = []
#     # while f is not None:
#     #     funcname = f.f_code.co_name
#     #     filename = f.f_code.co_filename
#     #     # if not filename.endswith("Lockable.py"):
#     #     s.append((filename, funcname, f.f_lineno))
#     #     f = f.f_back
#     # s = tuple(s)
#
#     s = (('C:\\development\\python\\packages\\test_jig_util\\tests\\lock_profiler_test.py', '<module>', 25), ('C:\\Users\\Ivan\\AppData\\Roaming\\JetBrains\\IntelliJIdea2022.2\\plugins\\python\\helpers\\pydev\\_pydev_imps\\_pydev_execfile.py', 'execfile', 18), ('C:/Users/Ivan/AppData/Roaming/JetBrains/IntelliJIdea2022.2/plugins/python/helpers/pydev/pydevd.py', '_exec', 1496), ('C:/Users/Ivan/AppData/Roaming/JetBrains/IntelliJIdea2022.2/plugins/python/helpers/pydev/pydevd.py', 'run', 1489), ('C:/Users/Ivan/AppData/Roaming/JetBrains/IntelliJIdea2022.2/plugins/python/helpers/pydev/pydevd.py', 'main', 2177), ('C:/Users/Ivan/AppData/Roaming/JetBrains/IntelliJIdea2022.2/plugins/python/helpers/pydev/pydevd.py', '<module>', 2195))
#
#     stack_hash = hash(s)
#     if stack_hash not in _stack_map:
#         _stack_map[stack_hash] = s
#
#     return s, stack_hash


@cython.boundscheck(False)
@cython.wraparound(False)
cdef int python_trace_callback(object lock_, PyFrameObject *py_frame, int what, PyObject *arg):
# cdef int trace_callback(object lock_, int what):
    """ The PyEval_SetTrace() callback.
    """
    cdef PY_LONG_LONG time
    cdef PY_LONG_LONG duration
    cdef int64 stack_hash
    cdef int64 tid
    # cdef vector[(PyObject *, PyObject *, int)] stack

    # In Lockable.py, Profiling is enable just before calling `RLock.acquire`, and disabled right after.
    #  Therefore, this callback should only receive two events:
    #   A PyTrace_C_CALL when the acquisition starts
    #   A PyTrace_C_RETURN when the acquisition completes
    #  The time between these is how long the lock was blocked for
    # In addition, we can use the thread ident and the call stack to determine the exact callee


    # print(f"{threading.get_ident()} {lut[what]}")
    tid = threading.get_ident()

    if what == PyTrace_C_CALL:
        # lock acquire called
        # f = sys._getframe()
        f = <object>py_frame
        skip = 2
        while skip and f:
            skip -= 1
            f = f.f_back

        stack = []
        stack_hash = 0
        while f is not None:
            # if not filename.endswith("Lockable.py"):
            frame = (
                f.f_code.co_filename,
                f.f_code.co_name,
                f.f_lineno
            )
            stack.append(frame)
            # stack_hash ^= hash(frame)
            f = f.f_back
        # stack = tuple(stack)

        # s = (('C:\\development\\python\\packages\\test_jig_util\\tests\\lock_profiler_test.py', '<module>', 25), ('C:\\Users\\Ivan\\AppData\\Roaming\\JetBrains\\IntelliJIdea2022.2\\plugins\\python\\helpers\\pydev\\_pydev_imps\\_pydev_execfile.py', 'execfile', 18), ('C:/Users/Ivan/AppData/Roaming/JetBrains/IntelliJIdea2022.2/plugins/python/helpers/pydev/pydevd.py', '_exec', 1496), ('C:/Users/Ivan/AppData/Roaming/JetBrains/IntelliJIdea2022.2/plugins/python/helpers/pydev/pydevd.py', 'run', 1489), ('C:/Users/Ivan/AppData/Roaming/JetBrains/IntelliJIdea2022.2/plugins/python/helpers/pydev/pydevd.py', 'main', 2177), ('C:/Users/Ivan/AppData/Roaming/JetBrains/IntelliJIdea2022.2/plugins/python/helpers/pydev/pydevd.py', '<module>', 2195))

        # stack_hash = 1
        stack_hash = hash(tuple(stack))
        if stack_hash not in _stack_map:
        # if not _c_stack_map.count(stack_hash):
            _stack_map[stack_hash] = stack

        # return s, stack_hash


        # stack, stack_hash = get_stack()
        # stack_hash = 1

        _c_lock_map[tid].stack_hash = stack_hash
        _c_lock_map[tid].timestamp = hpTimer() # TODO may want to do this last to ignore overhead from this functions

    elif what == PyTrace_C_RETURN:
        # acquire returned
        duration = hpTimer() - _c_lock_map[tid].timestamp
        _c_lock_list.push_back(CLockTime(
            _c_lock_map[tid].timestamp,
            tid,
            hash(lock_),
            _c_lock_map[tid].stack_hash,
            duration
        ))

    else:
        print("ERR")

    return 0
