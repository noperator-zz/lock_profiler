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

import sys

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



cdef struct CLockEvent:
    PY_LONG_LONG timestamp
    int64_t flag
    # Which thread called it
    int64_t tid
    # Which lock it was called on
    int64 lock_hash
    # Hash of the call stack
    int64_t stack_hash

class LockEvent(typing.NamedTuple):
    timestamp: int
    flag: int
    # idx: int
    # current_depth: int
    # wait_duration: int
    # hold_duration: int
    # # block_duration: int
    tid: int
    lock_hash: int
    stack_hash: int

class StackFrame(typing.NamedTuple):
    file: str
    functionName: str
    lineNo: int

# StackType = typing.List[StackFrame]
# cdef struct StackInfo:
#     str stack

# Note: this is a regular Python class to allow easy pickling.
@dataclass
class LockStats:
    lock_hashes: typing.Dict[int, str]
    stack_hashes: typing.Dict[int, typing.List[StackFrame]]
    lock_list: typing.List[LockEvent]


# # Mapping between tid and (mapping between lock hash and (vector of info about each nested acquisition))
# cdef unordered_map[int64, unordered_map[int64_t, vector[CLockInfo]]] _c_lock_map
# List of all acquire events
cdef vector[CLockEvent] _c_lock_list
# Mapping between lock hash and which thread is holding it
# cdef unordered_map[int64, int64_t] _c_held_map
# Mapping between tid and the stack hash recorede in `pre_acquire`
cdef unordered_map[int64, int64_t] _c_current_stack_map

cdef int64_t _idx = 0

cdef int64_t E_WAIT =    0
cdef int64_t E_ACQUIRE = 1
cdef int64_t E_RELEASE = 2
PY_E_WAIT = E_WAIT
PY_E_ACQUIRE = E_ACQUIRE
PY_E_RELEASE = E_RELEASE
# cdef int64_t F_BLOCKED = 1 << 8


# Mapping between call stack hash and call stack
# cdef unordered_map[int64, vector[StackFrame]] _c_stack_map
_stack_map = {}
_lock_strs = {}

cdef class LockProfiler:
    def __init__(self):
        raise NotImplementedError()

    @staticmethod
    @cython.boundscheck(False)
    @cython.wraparound(False)
    def pre_acquire(obj):
        global _idx
        h = hash(obj._lock)
        if h not in _lock_strs:
            _lock_strs[h] = str(obj)

        tid = threading.get_ident()

        # lock acquire called
        if 1:
            f = sys._getframe()
            # f = <object>py_frame
            skip = 0
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

            # stack = (('C:\\development\\python\\packages\\test_jig_util\\tests\\lock_profiler_test.py', '<module>', 25), ('C:\\Users\\Ivan\\AppData\\Roaming\\JetBrains\\IntelliJIdea2022.2\\plugins\\python\\helpers\\pydev\\_pydev_imps\\_pydev_execfile.py', 'execfile', 18), ('C:/Users/Ivan/AppData/Roaming/JetBrains/IntelliJIdea2022.2/plugins/python/helpers/pydev/pydevd.py', '_exec', 1496), ('C:/Users/Ivan/AppData/Roaming/JetBrains/IntelliJIdea2022.2/plugins/python/helpers/pydev/pydevd.py', 'run', 1489), ('C:/Users/Ivan/AppData/Roaming/JetBrains/IntelliJIdea2022.2/plugins/python/helpers/pydev/pydevd.py', 'main', 2177), ('C:/Users/Ivan/AppData/Roaming/JetBrains/IntelliJIdea2022.2/plugins/python/helpers/pydev/pydevd.py', '<module>', 2195))
            stack_hash = hash(tuple(stack))
        else:
            stack = ""
            stack_hash = 1

        if stack_hash not in _stack_map:
            # if not _c_stack_map.count(stack_hash):
            _stack_map[stack_hash] = stack

        # _c_current_stack_map[tid] = stack_hash
        _c_lock_list.push_back(CLockEvent(
            hpTimer(), # TODO may want to do this last to ignore overhead from this functions
            E_WAIT,
            tid,
            h,
            stack_hash,
        ))

        # blocked = 0
        # if _c_held_map.count(h):
        #     if _c_held_map[h] != tid:
        #         # Another thread is holding this lock; we're blocked
        #         # _c_wait_map[h] = tid
        #         blocked = 1
        # else:
        #     _c_held_map[h] = tid
        #
        # size = _c_lock_map[tid][h].size()
        # _c_lock_map[tid][h].push_back(CLockInfo(
        #     hpTimer(), # TODO may want to do this last to ignore overhead from this functions
        #     _idx,
        #     size,
        #     # # temporarily using `acquire_duration` as a flag to say if this thread is blocked or not
        #     # blocked,
        #     0,
        #
        #     0,
        #     tid,
        #     h,
        #     stack_hash,
        # ))
        #
        # _idx += 1

    @staticmethod
    @cython.boundscheck(False)
    @cython.wraparound(False)
    def post_acquire(obj):
        t = hpTimer()
        h = hash(obj._lock)
        tid = threading.get_ident()

        _c_lock_list.push_back(CLockEvent(
            hpTimer(),
            E_ACQUIRE,
            tid,
            h,
            0,
        ))


        # # info = _c_lock_map[tid][h].back()
        # # was_blocked = _c_lock_map[tid][h].back().wait_duration
        # _c_lock_map[tid][h].back().wait_duration = t - _c_lock_map[tid][h].back().timestamp
        #
        # # # TODO maybe record the wait duration even if it wasn't blocked (it will only show the Python overhead and any OS overhead in this case)
        # # if was_blocked:
        # #     info.wait_duration = wait_duration
        #
        # # if _c_held_map.count(h):
        # #     assert _c_held_map[h].tid == tid
        # # else:
        # #     _c_held_map[h] = LockDepth(t, tid, 0)
        # #
        # # _c_held_map[h].depth += 1


    @staticmethod
    def pre_release(obj):
        t = hpTimer()
        h = hash(obj._lock)
        tid = threading.get_ident()

        _c_lock_list.push_back(CLockEvent(
            hpTimer(),
            E_RELEASE,
            tid,
            h,
            0,
        ))

        # info = _c_lock_map[tid][h].back()
        # _c_lock_map[tid][h].pop_back()
        # hold_duration = t - (info.timestamp + info.wait_duration)
        #
        # info.hold_duration = hold_duration
        # _c_lock_list.push_back(info)
        #
        # if not _c_lock_map[tid][h].size():
        #     _c_lock_map[tid].erase(h)
        #     assert _c_held_map[h] == tid
        #     _c_held_map.erase(h)
        #
        #     # if _c_wait_map.count(h):
        #     #     # Another thread is waiting for this lock; they're unblocked now

    @staticmethod
    def get_stats() -> LockStats:
        """ Return a LineStats object containing the timings.
        """

        output = LockStats(
            _lock_strs,
            # # Remove frames in Lockable.py
            # {k:
            #      tuple(frame for frame in v if not frame[0].endswith("Lockable.py"))
            #  for k, v in _stack_map.items()},
            # _c_stack_map,
            _stack_map,
            [LockEvent(
                a.timestamp,
                a.flag,
                # a.idx,
                # a.current_depth,
                # a.wait_duration,
                # a.hold_duration,
                a.tid,
                a.lock_hash,
                a.stack_hash,
            ) for a in _c_lock_list],
            # tuple(CLockTime(t[0] - offset, *t[1:]) for t in _c_lock_list),
        )
        return output
