"""Bound capture from one owned, trusted direct subprocess; never use a shell."""

import os
import re
import selectors
import subprocess
import sys
import time


READ_CHUNK = 64 * 1024
REAP_TIMEOUT = 5
_NOTE = re.compile(
    r"Direct subprocess cleanup failed: stage=(kill|reap|stdout-close|stderr-close|selector-close) "
    r"pid=[0-9]+ class=[A-Za-z_][A-Za-z_0-9]*"
)


class OutputLimit(ValueError):
    """A stream exceeded its independent byte budget before capture completed."""


def _release(process, selector):
    failures = []
    operations = []
    if process.returncode is None:
        operations.extend([("kill", process.kill), ("reap", lambda: process.wait(timeout=REAP_TIMEOUT))])
    operations.extend([("stdout-close", process.stdout.close), ("stderr-close", process.stderr.close)])
    if selector is not None:
        operations.append(("selector-close", selector.close))

    for stage, operation in operations:
        try:
            operation()
        except BaseException:
            failures.append((stage, *sys.exc_info()))
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
    """Expose only redacted owning PID, cleanup stage and exception class."""
    return tuple(note for note in getattr(error, "__notes__", ())
                 if type(note) is str and _NOTE.fullmatch(note) is not None)


def run(argv, *, timeout, stdout_limit, stderr_limit, cwd=None, env=None):
    """Return CompletedProcess[bytes], leaving exit/warning policy to the caller.

    Each accepted stream has at most its declared budget. A one-byte probe
    distinguishes exact-bound EOF from overflow; the rejected byte is never
    retained. Both streams drain concurrently without temporary files. One
    monotonic deadline covers drain and normal direct-child reap.

    OutputLimit and TimeoutExpired are expected failures. Other exceptions
    retain their identity and traceback after every cleanup obligation is
    attempted. On failure, KILL precedes a separately bounded cleanup reap;
    OS kill/reap failure becomes a secondary note, never a false success.
    This owns the direct child only, not a descendant process group.
    """
    if timeout <= 0 or stdout_limit < 0 or stderr_limit < 0:
        raise ValueError("subprocess requires a positive timeout and nonnegative byte budgets")

    deadline = time.monotonic() + timeout
    selector = None
    output, errors = bytearray(), bytearray()
    process = subprocess.Popen(
        argv, cwd=cwd, env=env, stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0,
    )
    try:
        selector = selectors.DefaultSelector()
        for pipe, name, limit, buffer in [
            (process.stdout, "stdout", stdout_limit, output),
            (process.stderr, "stderr", stderr_limit, errors),
        ]:
            os.set_blocking(pipe.fileno(), False)
            selector.register(pipe, selectors.EVENT_READ, (name, limit, buffer))

        while selector.get_map():
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise subprocess.TimeoutExpired(argv, timeout)
            for key, _ in selector.select(remaining):
                name, limit, buffer = key.data
                available = limit - len(buffer)
                chunk = os.read(key.fd, min(READ_CHUNK, available + 1))
                if not chunk:
                    selector.unregister(key.fileobj)
                    continue
                if len(chunk) > available:
                    raise OutputLimit(f"{argv[0]}: {name} exceeds {limit}-byte bound")
                buffer.extend(chunk)

        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise subprocess.TimeoutExpired(argv, timeout)
        status = process.wait(timeout=remaining)
        result = subprocess.CompletedProcess(argv, status, bytes(output), bytes(errors))
    except BaseException as error:
        _notes(error, _release(process, selector), process.pid)
        raise

    failures = _release(process, selector)
    if failures:
        _, _, error, traceback = failures[0]
        _notes(error, failures, process.pid)
        raise error.with_traceback(traceback)
    return result
