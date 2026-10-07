"""Watchdog and retained evidence for actual native workspace boundaries."""

import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import platform
import signal
import subprocess
import sys
import time
from symphony_conformance.driver import capture, process
from symphony_conformance.driver.process import Process
from symphony_conformance import assets


SIGNAL_EXIT_BASE = 128
OUTPUT_LIMIT = 16 * 1024 * 1024
WATCHDOG = Path(__file__).resolve()
SENTINEL = process.SENTINEL
AGENT_FIXTURE = WATCHDOG.parent / "fixtures/agent/native_server.py"
PYTHON_ENV = "SYMPHONY_TEST_PYTHON"
SERVER_ENV = "SYMPHONY_TEST_AGENT_SERVER"
TLS_ENV = "SYMPHONY_TEST_TLS_DIRECTORY"
TLS_DIRECTORY = str(assets.resource("tls"))
TLS_FILES = ("manifest.json", "ca.pem", "server.pem", "server.key")


class Terminated(SystemExit):
    """A graceful SIGTERM unwinds owned resources before exiting."""


def _persist_receipt(log, receipt):
    if receipt is None:
        raise RuntimeError("native watchdog lacks a terminal ownership receipt")
    retained = {key: value for key, value in receipt.items() if key not in ("stdout", "stderr")}
    retained.update({name + "_sha256": hashlib.sha256(receipt[name]).hexdigest()
                     for name in ("stdout", "stderr")})
    path = log.with_suffix(".ownership.json")
    rendered = (json.dumps(retained, indent=2, allow_nan=False) + "\n").encode()
    if path.write_bytes(rendered) != len(rendered):
        raise OSError("native ownership receipt write was incomplete")
    return {"path": path.name, "sha256": hashlib.sha256(rendered).hexdigest(),
            "reaped": receipt["reaped"], "failure_count": len(receipt["failures"])}


def execute(binary, log, timeout, *, env=None):
    binary = binary.resolve()
    started = time.monotonic()
    owner = None
    receipt = None
    errors = []
    output = log.open("wb")

    def record(kind, fields):
        if kind in ("capture.stdout", "capture.stderr"):
            data = base64.b64decode(fields["data_b64"], validate=True)
            if output.write(data) != len(data):
                raise OSError("native capture file write was incomplete")

    def attempt(stage, action):
        try:
            return action()
        except BaseException as error:
            errors.append((stage, error, error.__traceback__))
            return None

    try:
        with Process([str(binary), "--color=never"], binary.parent,
                     {**os.environ, TLS_ENV: TLS_DIRECTORY, **(env or {})}, OUTPUT_LIMIT,
                     started + timeout, record) as owner:
            status = owner.join(timeout)
    except subprocess.TimeoutExpired as error:
        receipt = error._process_snapshot
        status = "timeout"
    except SystemExit as error:
        if error.code != SIGNAL_EXIT_BASE + signal.SIGTERM:
            raise
        terminated = Terminated(error.code)
        for note in getattr(error, "__notes__", ()):
            terminated.add_note(note)
        terminated._process_snapshot = getattr(error, "_process_snapshot", None)
        raise terminated from error
    finally:
        primary = sys.exc_info()[1]
        receipt = receipt or getattr(primary, "_process_snapshot", None)
        if owner is not None:
            current = attempt("ownership-snapshot", owner.snapshot)
            if current is not None:
                receipt = current
        # Persist after owner and log closure, including failed admission receipts.
        attempt("capture-log-close", output.close)
        ownership = attempt("ownership-receipt", lambda: _persist_receipt(log, receipt))
        failure = primary or (errors[0][1] if errors else None)
        if failure is not None:
            if receipt is not None:
                failure._process_snapshot = receipt
            for stage, error, _ in errors:
                failure.add_note(f"Native evidence failed: stage={stage} class={type(error).__name__}")
            if primary is None:
                raise failure.with_traceback(errors[0][2])

    return {"status": status, "seconds": time.monotonic() - started,
            "ownership": ownership}


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
    for unit in ("native_shutdown_test", "native_output_test", "native_status_test",
                 "native_scope_test", "host_lifecycle_main"):
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
    lock = root.parent / "conformance/requirements.lock"
    hashes["conformance/requirements.lock"] = hashlib.sha256(lock.read_bytes()).hexdigest()
    for name in TLS_FILES:
        resource = "tls/" + name
        hashes["package/" + resource] = assets.digest(resource)
    hashes["package/protocol/manifest.json"] = assets.digest("protocol/manifest.json")
    for name in assets.load("protocol/manifest.json")["files"]:
        resource = "protocol/schemas/" + name
        hashes["package/" + resource] = assets.digest(resource)
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
        env = {TLS_ENV: TLS_DIRECTORY}
        if name == "agent":
            env.update(agent_env)
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
        "driver": {"sources": {path.name: hashlib.sha256(path.read_bytes()).hexdigest()
                                for path in (Path(capture.__file__), Path(process.__file__), SENTINEL)}},
        "watchdog": watchdog,
        "agent_fixture": agent_fixture,
        "results": results,
        "provenance": (
            "Hashes record current source files, binaries, Python interpreter and "
            "agent fixture and installed protocol/TLS assets before launch; binary environments record explicit "
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
