"""Bounded byte capture; run() owns a direct child, not a process group."""

import base64
import math
import os
import re
import selectors
import signal
import subprocess
import sys
import threading
import time

READ_CHUNK = 64 * 1024
REAP_TIMEOUT = 5
POLL_INTERVAL = 0.01
HANDLED_SIGNALS = (signal.SIGINT, signal.SIGTERM)
SIGNAL_EXIT_BASE = 128
_NOTE = re.compile(
    r"Direct subprocess cleanup failed: stage=[a-z-]+ pid=[0-9]+ class=[A-Za-z_][A-Za-z_0-9]*"
)


class OutputLimit(ValueError):
    """A stream exceeded its independent byte budget."""


class SignalScope:
    """Share cancellation collectors across main-thread owners."""

    _active = []
    _previous = {}

    def __init__(self):
        self.pending = None
        self._baseline = {}

    def open(self):
        if threading.current_thread() is not threading.main_thread():
            raise RuntimeError("process ownership requires the main thread")
        if self in self._active:
            raise RuntimeError("cancellation scope is already open")
        first = not self._active
        self._active.append(self)
        try:
            if first:
                for number in HANDLED_SIGNALS:
                    self._previous[number] = signal.signal(number, self._collect)
        finally:
            self._baseline = dict(self._previous)

    @classmethod
    def _collect(cls, number, _frame):
        for owner in tuple(cls._active):
            if owner.pending is None:
                owner.pending = number

    def check(self):
        number = self.pending
        if number is None:
            return
        if number in self._baseline:
            handler = self._baseline[number]
        else:
            handler = self._previous.get(number, signal.getsignal(number))
        if handler == signal.SIG_IGN or (callable(handler) and handler is not signal.default_int_handler):
            # Deliver application cancellation only after process admission.
            # One shared delivery lets its collector govern every active owner.
            for owner in (*self._active, self):
                if owner.pending == number:
                    owner.pending = None
            if callable(handler):
                handler(number, None)
            return
        if number == signal.SIGINT:
            raise KeyboardInterrupt
        raise SystemExit(SIGNAL_EXIT_BASE + number)

    def close(self):
        failures = []
        if self not in self._active:
            return failures
        if len(self._active) > 1:
            self._active.remove(self)
            return failures
        # The last owner receives cancellation until restoration finishes.
        try:
            for number, handler in dict(self._previous).items():
                try:
                    signal.signal(number, handler)
                except BaseException:
                    failures.append(("signal-restore", *sys.exc_info()))
        finally:
            self._active.remove(self)
            self._previous.clear()
        return failures


class Capture:
    """Drain two nonblocking pipes under independent bounds and one owner."""

    def __init__(self, stdout, stderr, limits, emit=None):
        self._pipes = {"stdout": stdout, "stderr": stderr}
        self._limits = dict(limits)
        self._buffers = {name: bytearray() for name in self._pipes}
        self._eof = set()
        self._selector = None
        self._emit = emit

    def open(self):
        self._selector = selectors.DefaultSelector()
        for name, pipe in self._pipes.items():
            os.set_blocking(pipe.fileno(), False)
            self._selector.register(pipe, selectors.EVENT_READ, name)

    def active(self):
        return self._selector is not None and bool(self._selector.get_map())

    def snapshot(self):
        return {name: bytes(value) for name, value in self._buffers.items()}

    def eof(self):
        return tuple(sorted(self._eof))

    def pump(self, timeout):
        if not self.active():
            return
        for key, _ in self._selector.select(timeout):
            name = key.data
            buffer = self._buffers[name]
            available = self._limits[name] - len(buffer)
            try:
                data = os.read(key.fd, min(READ_CHUNK, available + 1))
            except BlockingIOError:
                continue
            if not data:
                self._selector.unregister(key.fileobj)
                self._eof.add(name)
                self._record("capture.closed", {"stream": name, "stage": "eof", "status": "ok"})
                continue

            # A one-byte probe separates exact-bound EOF from overflow.
            accepted = data[:available]
            if accepted:
                buffer.extend(accepted)
                self._record("capture." + name, {
                    "data_b64": base64.b64encode(accepted).decode("ascii"),
                    "bytes": len(accepted),
                })
            if len(data) > available:
                self._record("capture.closed", {"stream": name, "stage": "overflow", "result": "failed",
                                                 "status": "error", "limit": self._limits[name]})
                raise OutputLimit(f"{name} exceeds {self._limits[name]}-byte bound")

    def _record(self, kind, fields):
        if self._emit is not None:
            self._emit(kind, fields)

    def close(self):
        operations = [(name + "-close", pipe.close) for name, pipe in self._pipes.items()]
        if self._selector is not None:
            selector, self._selector = self._selector, None
            operations.append(("selector-close", selector.close))
        failures = []
        for stage, operation in operations:
            try:
                operation()
            except BaseException:
                failures.append((stage, *sys.exc_info()))
        return failures


def _release(process, capture):
    operations = []
    if process.returncode is None:
        operations.extend([
            ("kill", process.kill),
            ("reap", lambda: process.wait(timeout=REAP_TIMEOUT)),
        ])
    failures = []
    for stage, operation in operations:
        try:
            operation()
        except BaseException:
            failures.append((stage, *sys.exc_info()))
    if capture is not None:
        failures.extend(capture.close())
    else:
        for name in ("stdout", "stderr"):
            try:
                getattr(process, name).close()
            except BaseException:
                failures.append((name + "-close", *sys.exc_info()))
    return failures


def _notes(error, failures, pid):
    for stage, _, secondary, _ in failures:
        try:
            name = type(secondary).__name__
            if re.fullmatch(r"[A-Za-z_][A-Za-z_0-9]*", name) is None:
                name = "BaseException"
            error.add_note(f"Direct subprocess cleanup failed: stage={stage} pid={pid} class={name}")
        except BaseException:
            pass


def cleanup_notes(error):
    """Return redacted owning PID, cleanup stage and exception class."""
    return tuple(note for note in getattr(error, "__notes__", ())
                 if type(note) is str and _NOTE.fullmatch(note) is not None)


def run(argv, *, timeout, stdout_limit, stderr_limit, cwd=None, env=None):
    """Capture one direct child, leaving exit and warning policy to callers.

    Admission, both drains and normal reap share one monotonic deadline.
    Failure cleanup uses a separate bounded reap. Every cleanup obligation
    is attempted; a secondary defect never replaces the primary exception.
    """
    if (not isinstance(timeout, (int, float)) or isinstance(timeout, bool)
            or not math.isfinite(timeout) or timeout <= 0
            or any(type(limit) is not int or limit < 0 for limit in (stdout_limit, stderr_limit))):
        raise ValueError("subprocess requires a positive timeout and nonnegative byte budgets")

    deadline = time.monotonic() + timeout
    process = capture = None
    cancellation = SignalScope()
    failures = []
    try:
        cancellation.open()
        cancellation.check()
        process = subprocess.Popen(
            argv, cwd=cwd, env=env, stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0,
        )
        cancellation.check()
        capture = Capture(process.stdout, process.stderr,
                          {"stdout": stdout_limit, "stderr": stderr_limit})
        capture.open()
        while capture.active():
            cancellation.check()
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise subprocess.TimeoutExpired(argv, timeout)
            capture.pump(min(POLL_INTERVAL, remaining))
        while process.poll() is None:
            cancellation.check()
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise subprocess.TimeoutExpired(argv, timeout)
            time.sleep(min(POLL_INTERVAL, remaining))
        cancellation.check()
        if time.monotonic() >= deadline:
            raise subprocess.TimeoutExpired(argv, timeout)
        streams = capture.snapshot()
        result = subprocess.CompletedProcess(argv, process.returncode, streams["stdout"], streams["stderr"])
    except BaseException as error:
        if process is not None:
            failures.extend(_release(process, capture))
        failures.extend(cancellation.close())
        if process is not None:
            _notes(error, failures, process.pid)
        raise

    failures.extend(_release(process, capture))
    failures.extend(cancellation.close())
    try:
        cancellation.check()
    except BaseException:
        failures.append(("signal-check", *sys.exc_info()))
    if failures:
        # Cancellation keeps its control-flow identity ahead of cleanup defects.
        _, _, error, traceback = next(
            (failure for failure in failures if not isinstance(failure[2], Exception)), failures[0])
        _notes(error, [failure for failure in failures
                       if failure[0] != "signal-check" or failure[2] is not error], process.pid)
        raise error.with_traceback(traceback)
    return result
