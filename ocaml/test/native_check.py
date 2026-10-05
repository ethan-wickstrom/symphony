"""Watchdog and retained evidence for actual native workspace boundaries."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import signal
import subprocess
import sys
import time


TERM_GRACE = 2
POLL_INTERVAL = 0.01
HANDLED_SIGNALS = (signal.SIGINT, signal.SIGTERM)
SIGNAL_EXIT_BASE = 128
WATCHDOG = Path(__file__).resolve()
SENTINEL = WATCHDOG.with_name("native_sentinel.py")
AGENT_FIXTURE = WATCHDOG.parent / "fixtures/agent/native_server.py"
PYTHON_ENV = "SYMPHONY_TEST_PYTHON"
SERVER_ENV = "SYMPHONY_TEST_AGENT_SERVER"


class Terminated(SystemExit):
    """A graceful SIGTERM unwinds owned resources before exiting."""


def require_waitid():
    flags = ("P_PID", "WEXITED", "WNOHANG", "WNOWAIT")
    if not callable(getattr(os, "waitid", None)) or any(
        not hasattr(os, name) for name in flags
    ):
        raise RuntimeError("native watchdog requires POSIX waitid with WNOWAIT")


def signal_group(child, requested):
    try:
        os.killpg(child.pid, requested)
    except ProcessLookupError:
        pass


def term_grace(child):
    deadline = time.monotonic() + TERM_GRACE
    while time.monotonic() < deadline:
        # Observe exit without reaping: PID reservation fences the final kill.
        exited = os.waitid(
            os.P_PID, child.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT
        )
        remaining = max(0, deadline - time.monotonic())
        if exited is not None:
            time.sleep(remaining)
            return
        time.sleep(min(POLL_INTERVAL, remaining))


def wait_exit(child, timeout, observe):
    deadline = time.monotonic() + timeout
    while True:
        observe()
        exited = os.waitid(os.P_PID, child.pid,
                           os.WEXITED | os.WNOHANG | os.WNOWAIT)
        if exited is not None:
            return
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise subprocess.TimeoutExpired(child.args, timeout)
        time.sleep(min(POLL_INTERVAL, remaining))


def interrupted(signum, _frame):
    if signum == signal.SIGINT:
        raise KeyboardInterrupt
    raise Terminated(SIGNAL_EXIT_BASE + signal.SIGTERM)


def stop_group(child):
    signal_group(child, signal.SIGTERM)
    term_grace(child)


def close_group(child, before):
    previous = {
        signum: signal.signal(signum, signal.SIG_IGN)
        for signum in HANDLED_SIGNALS
    }
    try:
        try:
            before()
        finally:
            # Retain the root PID until the last signal to its group.
            try:
                signal_group(child, signal.SIGKILL)
            finally:
                status = child.wait()
        return status
    finally:
        for signum, handler in previous.items():
            signal.signal(signum, handler)


def execute(binary, log, timeout, *, env=None):
    require_waitid()
    binary = binary.resolve()
    flags = ["-I"]
    if sys.flags.optimize:
        flags.append("-O" if sys.flags.optimize == 1 else "-OO")
    started = time.monotonic()
    with log.open("wb") as output:
        pending = None

        def collect(signum, _frame):
            nonlocal pending
            if pending is None:
                pending = signum

        def observe():
            if pending is not None:
                interrupted(pending, None)

        previous = {
            signum: signal.signal(signum, collect)
            for signum in HANDLED_SIGNALS
        }
        try:
            # Main-thread handlers only collect signals, including through
            # Popen admission and mask setup. Delivery uses owned safe points.
            child = subprocess.Popen(
                [sys.executable, *flags, str(SENTINEL), str(binary)], stdout=output,
                stderr=subprocess.STDOUT, start_new_session=True, cwd=binary.parent,
                env=None if env is None else {**os.environ, **env},
            )
            try:
                wait_exit(child, timeout, observe)
            except subprocess.TimeoutExpired:
                close_group(child, lambda: stop_group(child))
                return {"status": "timeout", "seconds": time.monotonic() - started}
            except BaseException:
                try:
                    close_group(child, lambda: stop_group(child))
                except BaseException:
                    # A secondary cleanup defect cannot replace the primary.
                    pass
                raise
            else:
                status = close_group(child, lambda: None)
                observe()
                return {"status": status, "seconds": time.monotonic() - started}
        finally:
            for signum, handler in previous.items():
                signal.signal(signum, handler)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--kernel", type=Path, required=True)
    parser.add_argument("--host", type=Path, required=True)
    parser.add_argument("--http", type=Path, required=True)
    parser.add_argument("--agent", type=Path, required=True)
    parser.add_argument("--lifecycle", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--timeout", type=float, default=90)
    args = parser.parse_args()
    if not (0 < args.timeout <= 300):
        parser.error("timeout must be between 0 and 300 seconds")

    root = Path(__file__).resolve().parents[1]
    sources = sorted((root / "lib/native").glob("*"))
    for area in ("domain", "io", "workflow", "core", "service", "agent", "orchestration"):
        sources += [
            path for path in sorted((root / "lib" / area).glob("*"))
            if path.suffix in (".ml", ".mli") or path.name == "dune"
        ]
    sources += sorted((root / "lib/workspace").glob("*.ml*"))
    sources += sorted((root / "test/native_kernel").glob("*.ml*"))
    sources += sorted((root / "test/native_host").glob("*.ml*"))
    sources += sorted((root / "test").glob("native_http_test.ml*"))
    sources += sorted((root / "test").glob("native_agent_test.ml*"))
    for unit in ("native_shutdown_test", "native_output_test", "host_lifecycle_main"):
        sources += sorted((root / "test").glob(unit + ".ml*"))
    sources += sorted((root / "test").glob("tracker_runtime_test.ml*"))
    sources += sorted((root / "bin").glob("tracker_runtime.ml*"))
    sources += sorted((root / "test/fixtures/tls").glob("*"))
    sources += sorted((root / "protocol/0.159.2").rglob("*"))
    sources += [root / "dune", root / "dune-project", root / "test/dune",
                root / "lib/workspace/dune", AGENT_FIXTURE]
    hashes = {
        str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest()
        for path in sources
        if path.is_file()
    }
    helper = {
        "path": str(SENTINEL),
        "sha256": hashlib.sha256(SENTINEL.read_bytes()).hexdigest(),
        "optimize": min(sys.flags.optimize, 2),
    }
    watchdog = {
        "path": str(WATCHDOG),
        "sha256": hashlib.sha256(WATCHDOG.read_bytes()).hexdigest(),
        "optimize": sys.flags.optimize,
    }
    interpreter = Path(sys.executable).resolve()
    python = {
        "executable": sys.executable,
        "resolved": str(interpreter),
        "sha256": hashlib.sha256(interpreter.read_bytes()).hexdigest(),
        "version": platform.python_version(),
        "implementation": sys.implementation.name,
        "cache_tag": sys.implementation.cache_tag,
        "optimize": sys.flags.optimize,
        "isolated": sys.flags.isolated,
    }
    if not AGENT_FIXTURE.is_file():
        parser.error(f"agent server fixture is missing: {AGENT_FIXTURE}")
    agent_fixture = {
        "path": str(AGENT_FIXTURE),
        "sha256": hashlib.sha256(AGENT_FIXTURE.read_bytes()).hexdigest(),
    }
    agent_env = {PYTHON_ENV: sys.executable, SERVER_ENV: str(AGENT_FIXTURE)}
    args.out.mkdir(parents=True, exist_ok=True)
    results = {}
    binaries = {}
    targets = [("kernel", args.kernel), ("host", args.host), ("http", args.http),
               ("agent", args.agent), ("lifecycle", args.lifecycle)]
    for name, binary in targets:
        binary = binary.resolve()
        if not binary.is_file():
            parser.error(f"{name} binary is missing: {binary}")
        binaries[name] = {
            "path": str(binary),
            "sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
        }
        env = agent_env if name == "agent" else None
        if env is not None:
            binaries[name]["environment"] = env
        results[name] = execute(binary, args.out / f"{name}.log", args.timeout, env=env)

    manifest = {
        "host": platform.platform(),
        "machine": platform.machine(),
        "python": python,
        "sources": hashes,
        "source_count": len(hashes),
        "binaries": binaries,
        "helper": helper,
        "watchdog": watchdog,
        "agent_fixture": agent_fixture,
        "results": results,
        "provenance": (
            "Hashes record current source files, binaries, Python interpreter and "
            "agent fixture before launch; agent environment records explicit "
            "overrides of inherited watchdog bindings; "
            "no source-to-binary attestation"
        ),
        "boundary": (
            "POSIX descriptors and advisory locks; watchdog owns its root process "
            "group, not separate groups or sessions; controlled test binaries must "
            "preserve its sentinel, group and credentials; no mount or VM isolation claim"
        ),
    }
    (args.out / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(json.dumps(results))
    return 0 if all(result["status"] == 0 for result in results.values()) else 1


if __name__ == "__main__":
    sys.exit(main())
