"""Observed POSIX group ownership, separate from candidate correctness."""

import base64
import copy
from enum import Enum
import math
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

from .capture import Capture, SignalScope
from .sentinel import GUARD_PREFIX

POLL_INTERVAL = 0.01
TERM_GRACE = 2
CLEANUP_TIMEOUT = 5
ADMISSION_LIMIT = 128
CLOSURE_SCOPE = "leader-and-capture"
SENTINEL = Path(__file__).with_name("sentinel.py")


class Stdin(Enum):
    CLOSED = "closed"
    PIPE = "pipe"


class Cleanup(Enum):
    GRACEFUL = "graceful"
    KILL = "kill"


class Custody(Enum):
    GROUP = "process-group"
    CHILD = "direct-child"


def _require_waitid():
    names = ("P_PID", "WEXITED", "WNOHANG", "WNOWAIT")
    if not callable(getattr(os, "waitid", None)) or any(not hasattr(os, name) for name in names):
        raise RuntimeError("group ownership requires POSIX waitid with WNOWAIT")


class Process:
    """Own a child or its unchanged process group, with bounded capture.

    Scenario signals target the leader. Cleanup targets the declared custody.
    Child custody retains the parent's group for an enclosing harness owner.
    Escaping groups/sessions and changed credentials are outside this scope.
    The main thread owns cancellation handlers and must close this scope.
    """

    def __init__(self, argv, cwd, env, output_limit, deadline, emit=None, *,
                 stdin=Stdin.CLOSED, stdin_limit=0, cleanup=Cleanup.GRACEFUL,
                 custody=Custody.GROUP):
        _require_waitid()
        limits = {name: output_limit for name in ("stdout", "stderr")} if type(output_limit) is int else output_limit
        if (not argv or type(limits) is not dict or set(limits) != {"stdout", "stderr"}
                or any(type(value) is not int or value < 0 for value in limits.values())):
            raise ValueError("process requires argv and nonnegative stream byte budgets")
        if not isinstance(stdin, Stdin) or not isinstance(cleanup, Cleanup) or not isinstance(custody, Custody):
            raise ValueError("process requires explicit stdin, cleanup, and custody policies")
        if type(stdin_limit) is not int or stdin_limit < 0:
            raise ValueError("process requires a nonnegative stdin byte budget")
        if not math.isfinite(deadline) or deadline <= time.monotonic():
            raise ValueError("process requires a future finite monotonic deadline")
        if env is None:
            raise ValueError("process requires an explicit environment")

        self._argv = tuple(str(value) for value in argv)
        self._deadline = deadline
        self._timeout = deadline - time.monotonic()
        self._stdin = stdin
        self._stdin_closed = stdin is Stdin.CLOSED
        self._stdin_limit = stdin_limit
        self._written = 0
        self._cleanup = cleanup
        self._custody = custody
        self._emit = emit
        self._recorder_error = None
        self._lifecycle = []
        self._failures = []
        self._capture = self._child = None
        self._observed = None
        self._guard = None
        self._closed = False
        self._admission = self._writer = None
        self._cancellation = SignalScope()
        try:
            self._cancellation.open()
            self._check()
            command = self._argv
            descriptors = ()
            if custody is Custody.GROUP:
                self._admission, self._writer = os.pipe()
                os.set_blocking(self._admission, False)
                flags = ["-I"]
                if sys.flags.optimize:
                    flags.append("-" + "O" * min(sys.flags.optimize, 2))
                command = [sys.executable, *flags, str(SENTINEL), str(self._writer), *self._argv]
                descriptors = (self._writer,)
            self._child = subprocess.Popen(
                command,
                cwd=cwd, env=dict(env), stdin=subprocess.PIPE if stdin is Stdin.PIPE else subprocess.DEVNULL,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0,
                start_new_session=custody is Custody.GROUP, pass_fds=descriptors,
            )
            self._record("candidate.spawn", {"pid": self._child.pid, "argv": list(self._argv),
                                              "scope": custody.value})
            if self._writer is not None:
                os.close(self._writer)
                self._writer = None
            if stdin is Stdin.PIPE:
                os.set_blocking(self._child.stdin.fileno(), False)
            self._capture = Capture(self._child.stdout, self._child.stderr, limits, self._record)
            self._capture.open()
            if custody is Custody.GROUP:
                self._admit()
            self._check()
        except BaseException as error:
            self.close()
            error._process_snapshot = self.snapshot()
            raise

    def __enter__(self):
        return self

    def __exit__(self, _kind, error, _traceback):
        self.close()
        if error is not None:
            error._process_snapshot = self.snapshot()
        return False

    def _record(self, kind, fields):
        value = {"kind": kind, "time_ns": time.monotonic_ns(), **copy.deepcopy(fields)}
        self._lifecycle.append(value)
        if self._emit is None or self._recorder_error is not None:
            return
        try:
            self._emit(kind, copy.deepcopy(value))
        except BaseException as error:
            self._recorder_error = error
            self._lifecycle.append({"kind": "capture.closed", "time_ns": time.monotonic_ns(),
                                    "stage": "recorder", "result": "failed", "status": "error",
                                    "class": type(error).__name__})
            raise

    def _check(self):
        self._cancellation.check()
        if self._recorder_error is not None:
            raise self._recorder_error
        if time.monotonic() >= self._deadline:
            raise subprocess.TimeoutExpired(self._argv, self._timeout)

    def _admit(self):
        data = bytearray()
        while True:
            self._check()
            try:
                part = os.read(self._admission, ADMISSION_LIMIT + 1 - len(data))
            except BlockingIOError:
                part = None
            if part == b"":
                raise RuntimeError("group guard closed admission without an acknowledgement")
            if part is not None:
                data.extend(part)
                if len(data) > ADMISSION_LIMIT:
                    raise RuntimeError("group guard acknowledgement exceeds its bound")
                if b"\n" in data:
                    prefix = bytes(data)
                    pid = prefix[len(GUARD_PREFIX):-1]
                    if not prefix.startswith(GUARD_PREFIX) or not prefix.endswith(b"\n") or not pid.isdigit():
                        raise RuntimeError("group guard acknowledgement is malformed")
                    self._guard = int(pid)
                    if self._guard <= 0:
                        raise RuntimeError("group guard PID is invalid")
                    self._record("candidate.wait", {"operation": "guard-admission", "result": "acknowledged",
                                                     "guard_pid": self._guard, "reaped": False})
                    os.close(self._admission)
                    self._admission = None
                    return
            self._capture.pump(max(0, min(POLL_INTERVAL, self._deadline - time.monotonic())))

    def _observe(self):
        if self._child is None or self._observed is not None or self._child.returncode is not None:
            return
        value = os.waitid(os.P_PID, self._child.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT)
        if value is None:
            return
        self._observed = value.si_status if value.si_code == os.CLD_EXITED else -value.si_status
        self._record("candidate.wait", {"operation": "observe", "status": self._observed,
                                         "reaped": False, "pid": self._child.pid})

    def wait_for(self, predicate, timeout):
        if self._closed or not math.isfinite(timeout) or timeout <= 0:
            raise ValueError("wait requires an open process and a positive finite timeout")
        end = min(self._deadline, time.monotonic() + timeout)
        while True:
            self._check()
            self._capture.pump(0)
            self._observe()
            if predicate():
                return
            if self._observed is not None:
                raise subprocess.CalledProcessError(self._observed, self._argv)
            remaining = end - time.monotonic()
            if remaining <= 0:
                raise subprocess.TimeoutExpired(self._argv, timeout)
            self._capture.pump(min(POLL_INTERVAL, remaining))
            if not self._capture.active():
                time.sleep(min(POLL_INTERVAL, remaining))

    def signal(self, number):
        if self._closed:
            raise ValueError("cannot signal a closed process")
        self._check()
        self._observe()
        if self._observed is not None:
            raise ProcessLookupError("candidate leader has exited")
        # Keep scenario interruption distinct from harness group cleanup.
        os.kill(self._child.pid, number)
        self._record("candidate.signal", {"pid": self._child.pid, "signal": int(number), "target": "leader"})

    def join(self, timeout):
        """Wait for natural leader exit and both EOFs, retaining custody."""
        if self._closed or not math.isfinite(timeout) or timeout <= 0:
            raise ValueError("join requires an open process and a positive finite timeout")
        end = min(self._deadline, time.monotonic() + timeout)
        while True:
            self._check()
            self._capture.pump(0)
            self._observe()
            if self._observed is not None and self._capture.eof() == ("stderr", "stdout"):
                break
            remaining = end - time.monotonic()
            if remaining <= 0:
                raise subprocess.TimeoutExpired(self._argv, timeout)
            self._capture.pump(min(POLL_INTERVAL, remaining))
            if not self._capture.active():
                time.sleep(min(POLL_INTERVAL, remaining))
        self._record("candidate.wait", {"operation": "join", "status": self._observed,
                                         "pid": self._child.pid, "reaped": False,
                                         "closure_scope": CLOSURE_SCOPE})
        return self._observed

    def pump(self, timeout=0):
        """Advance raw observations without deciding candidate validity."""
        if self._closed or not math.isfinite(timeout) or timeout < 0:
            raise ValueError("pump requires an open process and a finite nonnegative timeout")
        self._check()
        span = min(timeout, self._deadline - time.monotonic())
        if self._capture.active():
            self._capture.pump(max(0, span))
        elif span > 0:
            time.sleep(min(POLL_INTERVAL, span))
        self._observe()
        self._check()
        return self.snapshot()

    def remaining(self):
        if self._closed:
            raise ValueError("closed process has no remaining runtime budget")
        self._check()
        return self._deadline - time.monotonic()

    def write(self, data):
        """Write bounded control bytes under the same process deadline."""
        if self._closed or self._stdin is not Stdin.PIPE or self._stdin_closed or type(data) is not bytes:
            raise ValueError("stdin write requires an open pipe and bytes")
        if len(data) > self._stdin_limit - self._written:
            raise ValueError("stdin exceeds its declared byte budget")
        offset = 0
        while offset < len(data):
            self._check()
            try:
                count = os.write(self._child.stdin.fileno(), data[offset:])
            except BlockingIOError:
                self.pump(min(POLL_INTERVAL, self.remaining()))
                continue
            if count <= 0:
                raise BrokenPipeError("stdin write made no progress")
            self._written += count
            self._record("capture.stdin", {
                "data_b64": base64.b64encode(data[offset:offset + count]).decode("ascii"),
                "bytes": count,
            })
            offset += count
        self._check()

    def close_stdin(self):
        """Deliver control-channel EOF without releasing process custody."""
        if self._closed or self._stdin is not Stdin.PIPE:
            raise ValueError("stdin close requires an open pipe owner")
        if self._stdin_closed:
            return
        try:
            self._child.stdin.close()
        except BaseException as error:
            self._failure("stdin-close", error)
            raise
        self._stdin_closed = True
        self._record("capture.closed", {"stream": "stdin", "stage": "owner-input-close", "status": "ok"})

    def snapshot(self):
        streams = self._capture.snapshot() if self._capture is not None else {"stdout": b"", "stderr": b""}
        status = self._child.returncode if self._child is not None else None
        return {**streams, "lifecycle": tuple(copy.deepcopy(self._lifecycle)),
                "pid": self._child.pid if self._child is not None else None,
                "guard_pid": self._guard, "returncode": status if status is not None else self._observed,
                "custody": self._custody.value,
                "closure_scope": CLOSURE_SCOPE,
                "reaped": status is not None, "closed": self._closed,
                "eof": self._capture.eof() if self._capture is not None else (),
                "stdin_bytes": self._written,
                "stdin_closed": self._stdin_closed,
                "failures": tuple(copy.deepcopy(self._failures))}

    def _failure(self, stage, error):
        value = {"stage": stage, "class": type(error).__name__}
        self._failures.append(value)
        try:
            self._record("group.cleanup", {"result": "failed", "status": "error", **value})
        except BaseException:
            # _record retains recorder defects locally for the final receipt.
            pass

    def _attempt(self, stage, operation, errors):
        try:
            return operation()
        except BaseException:
            error = sys.exc_info()
            errors.append((stage, *error))
            self._failure(stage, error[1])
            return None

    def _cleanup_signal(self, number):
        target = "group" if self._custody is Custody.GROUP else "child"
        complete = self._capture is not None and self._capture.eof() == ("stderr", "stdout")
        reason = "leader-alive" if self._observed is None else "open-capture" if not complete else "custody-release"
        if self._custody is Custody.CHILD and self._observed is not None:
            self._record("group.cleanup", {"stage": "release", "pid": self._child.pid,
                                            "result": "retained-for-reap", "status": "ok",
                                            "target": target, "forced": False, "reason": reason,
                                            "closure_scope": CLOSURE_SCOPE})
            return
        try:
            if self._custody is Custody.GROUP:
                os.killpg(self._child.pid, number)
            else:
                os.kill(self._child.pid, number)
            result = "sent"
        except ProcessLookupError:
            result = "absent"
        self._record("group.cleanup", {"stage": "signal", "signal": int(number),
                                        "pid": self._child.pid, "result": result, "status": "ok",
                                        "target": target, "forced": reason != "custody-release",
                                        "reason": reason, "closure_scope": CLOSURE_SCOPE})

    def _grace(self):
        end = time.monotonic() + TERM_GRACE
        while time.monotonic() < end:
            self._observe()
            if self._observed is not None:
                return
            self._capture.pump(max(0, min(POLL_INTERVAL, end - time.monotonic())))
            if not self._capture.active():
                time.sleep(POLL_INTERVAL)

    def _drain(self, end):
        while self._capture.active():
            remaining = end - time.monotonic()
            if remaining <= 0:
                raise subprocess.TimeoutExpired(self._argv, CLEANUP_TIMEOUT)
            self._capture.pump(min(POLL_INTERVAL, remaining))

    def close(self):
        if self._closed:
            return
        primary = sys.exc_info()[1]
        errors = []
        if self._child is not None:
            self._attempt("observe", self._observe, errors)
            if self._observed is None and self._cleanup is Cleanup.GRACEFUL:
                self._attempt("term", lambda: self._cleanup_signal(signal.SIGTERM), errors)
                if self._capture is not None:
                    self._attempt("term-grace", self._grace, errors)
            # Reap after cleanup: the group leader and guard reserve GROUP
            # identity; CHILD custody never signals unrelated group members.
            self._attempt("kill", lambda: self._cleanup_signal(signal.SIGKILL), errors)
            end = time.monotonic() + CLEANUP_TIMEOUT
            status = self._attempt("reap", lambda: self._child.wait(timeout=CLEANUP_TIMEOUT), errors)
            if status is not None:
                self._attempt("reap-record", lambda: self._record("candidate.wait", {
                    "operation": "reap", "status": status, "reaped": True, "pid": self._child.pid,
                }), errors)
            if self._capture is not None:
                self._attempt("drain", lambda: self._drain(end), errors)
                for stage, kind, error, traceback in self._capture.close():
                    errors.append((stage, kind, error, traceback))
                    self._failure(stage, error)
            else:
                for name in ("stdout", "stderr"):
                    self._attempt(name + "-close", getattr(self._child, name).close, errors)
            if self._child.stdin is not None:
                self._attempt("stdin-close", self._child.stdin.close, errors)
                self._stdin_closed = self._child.stdin.closed

        for name in ("_admission", "_writer"):
            descriptor = getattr(self, name)
            if descriptor is not None:
                self._attempt("admission-close", lambda fd=descriptor: os.close(fd), errors)
                setattr(self, name, None)
        for stage, kind, error, traceback in self._cancellation.close():
            errors.append((stage, kind, error, traceback))
            self._failure(stage, error)
        self._closed = True
        self._attempt("close-record", lambda: self._record("capture.closed", {
            "stage": "owner-close", "result": "failed" if errors or self._failures or self._recorder_error is not None else "closed",
            "status": "error" if errors or self._failures or self._recorder_error is not None else "ok",
            "closure_scope": CLOSURE_SCOPE,
        }), errors)
        if self._recorder_error is not None and not any(error is self._recorder_error for _, _, error, _ in errors):
            errors.append(("recorder", type(self._recorder_error), self._recorder_error, self._recorder_error.__traceback__))
            self._failure("recorder", self._recorder_error)

        if primary is not None:
            for stage, _, error, _ in errors:
                primary.add_note(f"Process cleanup failed: stage={stage} class={type(error).__name__}")
            primary._process_snapshot = self.snapshot()
            return
        try:
            self._cancellation.check()
        except BaseException:
            errors.append(("signal-check", *sys.exc_info()))
        if errors:
            # Without a caller primary, the first cancellation wins cleanup defects.
            _, _, error, traceback = next(
                (failure for failure in errors if not isinstance(failure[2], Exception)), errors[0])
            for stage, _, secondary, _ in errors:
                if secondary is not error:
                    BaseException.add_note(error, f"Process cleanup failed: stage={stage} class={type(secondary).__name__}")
            error._process_snapshot = self.snapshot()
            raise error.with_traceback(traceback)
