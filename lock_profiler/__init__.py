"""
The lock_profiler modula for doing line-by-line profiling of functions
"""
__submodules__ = [
    'lock_profiler'
]

__autogen__ = """
mkinit ./lock_profiler/__init__.py --relative
mkinit ./lock_profiler/__init__.py --relative -w
"""


from .lock_profiler import __version__

from .lock_profiler import (LockProfiler,
                            load_stats, main,
                            show_func, show_text,)

__all__ = ['LockProfiler', 'lock_profiler',
           'load_stats', 'main', 'show_func',
           'show_text', '__version__']
