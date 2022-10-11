#!/usr/bin/env python
import pickle
import functools
import inspect
import linecache
import tempfile
import os
import sys
from argparse import ArgumentError, ArgumentParser
import typing
from dataclasses import dataclass
import json
from collections import defaultdict

try:
    from ._lock_profiler import LockProfiler as CLockProfiler
    from ._lock_profiler import LockTime
except ImportError as ex:
    raise ImportError(
        'The lock_profiler._lock_profiler c-extension is not importable. '
        f'Has it been compiled? Underlying error is ex={ex!r}'
    )

__version__ = '4.0.0'



def is_coroutine(f):
    return inspect.iscoroutinefunction(f)


CO_GENERATOR = 0x0020


def is_generator(f):
    """ Return True if a function is a generator.
    """
    isgen = (f.__code__.co_flags & CO_GENERATOR) != 0
    return isgen


class LockProfiler(CLockProfiler):
    """ A profiler that records the execution times of individual lines.
    """

    _inst: typing.Optional['LockProfiler'] = None

    @staticmethod
    def inst() -> 'LockProfiler':
        if not LockProfiler._inst:
            LockProfiler._inst = LockProfiler()
        return LockProfiler._inst

    def __call__(self, func):
        """ Decorate a function to start the profiler on function entry and stop
        it on function exit.
        """
        self.add_function(func)
        if is_coroutine(func):
            wrapper = self.wrap_coroutine(func)
        elif is_generator(func):
            wrapper = self.wrap_generator(func)
        else:
            wrapper = self.wrap_function(func)
        return wrapper

    def wrap_coroutine(self, func):
        """
        Wrap a Python 3.5 coroutine to profile it.
        """

        @functools.wraps(func)
        async def wrapper(*args, **kwds):
            self.enable_by_count()
            try:
                result = await func(*args, **kwds)
            finally:
                self.disable_by_count()
            return result

        return wrapper

    def wrap_generator(self, func):
        """ Wrap a generator to profile it.
        """
        @functools.wraps(func)
        def wrapper(*args, **kwds):
            g = func(*args, **kwds)
            # The first iterate will not be a .send()
            self.enable_by_count()
            try:
                item = next(g)
            except StopIteration:
                return
            finally:
                self.disable_by_count()
            input_ = (yield item)
            # But any following one might be.
            while True:
                self.enable_by_count()
                try:
                    item = g.send(input_)
                except StopIteration:
                    return
                finally:
                    self.disable_by_count()
                input_ = (yield item)
        return wrapper

    def wrap_function(self, func):
        """ Wrap a function to profile it.
        """
        @functools.wraps(func)
        def wrapper(*args, **kwds):
            self.enable_by_count()
            try:
                result = func(*args, **kwds)
            finally:
                self.disable_by_count()
            return result
        return wrapper

    def dump_stats(self, filename):
        stats = self.get_stats()

        with open(filename, "w"):
            json.dumps(stats)

    def generate_html(self, filename):
        @dataclass
        class Style:
            style: dict
            selector: str = ""

            def as_html(self):
                return "; ".join(f"{k}: {v}" for k, v in self.style.items())

            def as_css(self):
                content = ";\n".join(f"    {k}: {v}" for k, v in self.style.items())
                return f"{self.selector} {{\n{content}\n}}\n"

        @dataclass
        class Div:
            cls: typing.List[str]
            style: Style = Style({})
            children: typing.List[typing.Union['Div', str]] = ()

            def as_html(self, nesting=0):
                d = {
                    "class": ' '.join(self.cls),
                    "style": self.style.as_html()
                }

                content = " ".join(f'{k}="{v}"' for k, v in d.items())
                children = "".join(child.as_html(nesting+1) if isinstance(child, Div) else child for child in self.children)
                if children:
                    children = "\n" + children
                return f"{'    ' * nesting}<div {content}>{children}</div>\n{'    ' * nesting}"

        def lock_class(lock_hash):
            return f"lock_{lock_hash}"

        def thread_class(tid):
            return f"thread_{tid}"

        def get_x(timestamp):
            # timestamp in nanoseconds. Make one second = 100 px
            # return timestamp / 10000000
            return timestamp / 10000000

        def as_px(val):
            return f"{val:.0f}px"

        EVENT_CLS = "event"

        ALIVE_CLS = "alive"
        HELD_CLS = "held"
        ACQUIRE_CLS = "acquire"

        SWIMLANE_CLS = "swimlane"
        THREAD_LABEL_CLS = "thread_label"

        ALIVE_Z = "0"
        HELD_Z = "1"
        ACQUIRE_Z = "2"
        THREAD_LABEL_Z = "3"

        THREAD_SPACING = 7
        THREAD_HEIGHT = 30
        X_OFFSET = 200

        stats = self.get_stats()
        lock_strs = stats.lock_hashes
        stacks = stats.stack_hashes
        events = stats.lock_list

        # events is a list of `CLockTime` events, unsorted. The events of each thread are guaranteed to be sorted by
        #  timestamp, increasing.
        # Event types:
        #  acquire: includes start timestamp, duration, tid, lock hash, stack hash
        #  release: includes timestamp, tid, lock hash. duration = -1

        # Each thread is a separate swimlane row in the html. The x-axis of the html corresponds to time passed
        # The swimlane contains colored divs indicating the state of the thread for that duration of time. If multiple
        # state are active at the same time, states with lower z-index will be hidden by other states:
        #  Thread alive: green (z=0 background)
        #  One or more locks taken: blue (z=1)
        #  Lock being acquired: red (z=2)

        # Each div may contain several classes which are used to style it:
        #  .alive: Used to color alive threads
        #  .held: Used to color when a lock is held
        #  .acquire: Used to color when a lock is being acquired
        #  .lock_`lock_hash`: Used to highlight all instances of the same lock

        styles: typing.List[Style] = [
            Style({
                "background": "#EEE",
                "font-size": as_px(THREAD_HEIGHT),
            }, f"body"),
            Style({
                "position": "absolute",
                "opacity": "50%",
            }, f".{EVENT_CLS}"),
            Style({
                "background": "green",
            }, f".{ALIVE_CLS}"),
            Style({
                "background": "blue",
            }, f".{HELD_CLS}"),
            Style({
                "background": "red",
            }, f".{ACQUIRE_CLS}"),
            Style({
                "position": "fixed",
                "width": "100%",
                "left": "0",
                "border": "1px solid black",
                "margin": "-1px",
            }, f".{SWIMLANE_CLS}"),
            Style({
                "position": "fixed",
                # "width": "100%",
                "left": "0",
                "background": "#FFFD",
                "pointer-events": "none",
                "z-index": THREAD_LABEL_Z,
                "text-align": "center",
                "line-height": as_px(THREAD_HEIGHT),
                "padding": f"0 1em",
            }, f".{THREAD_LABEL_CLS}"),
            Style({
                "visibility": "hidden",
                "display": "none",
                "z-index": "-1",
            }, f".{THREAD_LABEL_CLS}:hover"),
        ]

        thread_positions: typing.Dict[int, int] = {}
        lock_divs: typing.DefaultDict[int, typing.List[Div]] = defaultdict(lambda: [])
        thread_narrow: typing.Dict[int, Div] = {}

        # timelines: typing.Dict[int: typing.List[LockTime]] = defaultdict(lambda: [])

        # Scratchpad to hold acquire events while waiting for a release event
        # {tid: {lock_hash: [first acquire, next acquire, ...]}}
        held: typing.DefaultDict[int, typing.DefaultDict[int, typing.List[LockTime]]] = defaultdict(lambda: defaultdict(lambda: []))
        # divs: typing.List[Div] = []

        # TODO can we remove this loop? Timestamp of the first event may not be the earliest
        t_off = min(e.timestamp for e in events)

        for e in events:
            e.timestamp -= t_off

            if e.tid not in thread_positions:
                thread_positions[e.tid] = THREAD_SPACING + (len(thread_positions) * (THREAD_HEIGHT + THREAD_SPACING))

            # timelines[e.tid].append(e)
            # y = thread_positions[e.tid]
            # h = THREAD_HEIGHT

            classes = [EVENT_CLS, lock_class(e.lock_hash), thread_class(e.tid)]

            if e.duration >= 0:
                # Acquires are easy to generate; they're contained within one event
                x = get_x(e.timestamp)
                w = get_x(e.duration)
                z = ACQUIRE_Z
                # # TODO this is probably actually ok since using RLock, but we'll need a different way to handle storing held locks
                # assert e.lock_hash not in held[e.tid], "Lock acquired while already held!"
                held[e.tid][e.lock_hash].append(e)
                classes.append(ACQUIRE_CLS)

            else:
                # Held relies on the position of the matching acquire event

                # find the matching acquire event
                assert e.lock_hash in held[e.tid] and len(held[e.tid][e.lock_hash]), "No acquire event found for release event!"
                acquire = held[e.tid][e.lock_hash].pop()
                # # remove the acquire event
                # del held[e.tid][e.lock_hash]
                # Start at the end of the acquire
                start = acquire.timestamp + acquire.duration
                x = get_x(start)
                w = get_x(e.timestamp - start)
                z = HELD_Z
                classes.append(HELD_CLS)

            # thread_x[e.tid] = x+w
            #

            narrow = False
            if as_px(w) == as_px(0):
                w = 1
                narrow = True

            style = Style({
                "left": as_px(x + X_OFFSET),
                "width": as_px(w),
                # "top": as_px(y),
                # "height": as_px(h),
                "z-index": z,
            })

            div = Div(classes, style)

            if narrow:
                if e.tid in thread_narrow and thread_narrow[e.tid].style.style["left"] != div.style.style["left"]:
                    # The new div is starting at a later pixel, draw this narrow div
                    lock_divs[e.lock_hash].append(thread_narrow[e.tid])
                    # And remove it
                    del thread_narrow[e.tid]

                else:
                    # no narrow div yet, or the new div is on the same pixel: make it the new narrow div
                    thread_narrow[e.tid] = div

            else:
                lock_divs[e.lock_hash].append(div)

            # thread_divs[e.tid].append(div)

        # Widen the last 0px div before gap


        # TODO add 'alive' events in the blank spaces. But we don't actually know when the thread started or stopped...

        # NOTE this is probably fine. May happen if the profiler was turned off too early
        # assert all(len(v) == 0 for v in held.values()), "Not all locks released!"

        styles.extend(
            Style({
                    "opacity": "100%"
                }, f".{lock_class(lock_hash)}:hover .{lock_class(lock_hash)}")
            for lock_hash in lock_strs
        )

        styles.extend(
            Style({
                "visibility": "visible"
            }, f".{lock_class(lock_hash)}:hover ~ .{lock_class(lock_hash)}_tooltip")
            for lock_hash in lock_strs
        )

        styles.extend(
            Style({
                "visibility": "hidden",
                "position": "fixed",
                "bottom": as_px(THREAD_HEIGHT),
                "left": "0",
                "background": "#FFF",
                "z-index": THREAD_LABEL_Z,
                "text-align": "center",
                "line-height": as_px(THREAD_HEIGHT),
                "padding": f"0 1em",
            }, f".{lock_class(lock_hash)}_tooltip")
            for lock_hash in lock_strs
        )

        styles.extend(
            Style({
                "top": as_px(y),
                "height": as_px(THREAD_HEIGHT),
            }, f".{thread_class(tid)}")
            for tid, y in thread_positions.items()
        )

        div_str = ''.join(Div(
            [SWIMLANE_CLS, thread_class(tid)],
        ).as_html(1) for tid, y in thread_positions.items())
        div_str += ''.join(Div(
            [THREAD_LABEL_CLS, thread_class(tid)],
            children=[f"{tid}"]
        ).as_html(1) for tid, y in thread_positions.items())

        div_str += ''.join(Div(
            [lock_class(lock_hash)],
            Style({}),
            divs
        ).as_html(1) for lock_hash, divs in lock_divs.items())

        div_str += ''.join(Div(
            [f"{lock_class(lock_hash)}_tooltip"],
            Style({}),
            [f"{lock_strs[lock_hash]}"]
        ).as_html(1) for lock_hash in lock_divs)

        html = f"""<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <title>Lock Profiler</title>
    <style>
    {''.join(style.as_css() for style in styles)}
    </style>
</head>
<body>
    {div_str}
</body>
</html>
"""
        with open(filename, "w") as f:
            f.write(html)

        return html
