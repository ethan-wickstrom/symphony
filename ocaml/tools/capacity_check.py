"""Measure one finite native capacity producer with owned, bounded cleanup."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import selectors
import signal
import subprocess
import sys
import time

import bounded_process


SCHEMA = 1
PHASES = ("baseline", "plateau", "steady", "joined")
SESSION_COUNTS = (1, 10, 100, 1000)
MEMORY_KEYS = frozenset(("live_heap_bytes", "fiber_stack_bytes",
                         "reserved_heap_bytes", "allocated_bytes"))
SESSION_KEYS = ("acquired", "released", "owner_started", "owner_completed", "peak_running")
POPULATIONS = ("startup_reducer_step", "steady_reducer_step", "poll_cycle")
QUANTILES = ("p50_ns", "p95_ns", "p99_ns", "max_ns")
SUMMARY_KEYS = frozenset((*SESSION_KEYS, *POPULATIONS, "registered", "retired",
                          "warmup_cycles", "measured_cycles", "events", "event_budget",
                          "pending", "service_first_entry_ns", "service_all_entries_ns"))
WARMUP_CYCLES = 5
MEASURED_CYCLES = 100
IDENTITY = {"workload": "held-doing-v1", "ocaml_version": "5.5.0", "word_size": 64,
            "global_cap": 1000, "state_cap": 1000, "poll_interval_ms": 10}
GC_KEYS = frozenset(("minor_heap_size", "space_overhead", "stack_limit", "custom_major_ratio",
                     "custom_minor_ratio", "custom_minor_max_size", "verbose",
                     "small_heap_limit", "mark_stack_prune_factor"))
MAX_LINE_BYTES = 64 * 1024
MAX_STDOUT_BYTES = len(PHASES) * (MAX_LINE_BYTES + 1)
MAX_STDERR_BYTES = 64 * 1024
MAX_RSS_BYTES = 64 * 1024
MAX_BINARY_BYTES = 256 * 1024 * 1024
RSS_CEILING_BYTES = 128 * 1024 * 1024
READ_CHUNK = 16 * 1024
REAP_TIMEOUT = 5
RSS_TIMEOUT = 2
DEFAULT_TIMEOUT = 60
MAX_TIMEOUT = 60
POLL_INTERVAL = 0.01
HANDLED_SIGNALS = (signal.SIGINT, signal.SIGTERM)
SIGNAL_EXIT_BASE = 128
BYTES_PER_KIB = 1024
LINUX_RSS = (
    "import sys; "
    "source = open('/proc/' + sys.argv[1] + '/smaps_rollup', 'rb'); "
    f"data = source.read({MAX_RSS_BYTES + 1}); "
    "source.close(); sys.stdout.buffer.write(data)"
)
LAUNCHER = r"""
import os
import signal
import sys

# A live same-UID guard makes the final group signal meaningful on macOS,
# where a group containing only zombies returns EPERM.
previous = {signum: signal.signal(signum, signal.SIG_IGN)
            for signum in (signal.SIGINT, signal.SIGTERM)}
ready = b'guard-ready'
reader, writer = os.pipe()
if os.fork() == 0:
    try:
        os.close(reader)
        for fd in (0, 1, 2):
            os.close(fd)
        os.write(writer, ready)
        os.close(writer)
        while True:
            signal.pause()
    except BaseException:
        os._exit(1)

os.close(writer)
try:
    if os.read(reader, len(ready)) != ready:
        raise RuntimeError('capacity group guard failed before producer exec')
finally:
    os.close(reader)

for signum, handler in previous.items():
    signal.signal(signum, handler)
for name in ('SIGPIPE', 'SIGXFZ', 'SIGXFSZ'):
    signum = getattr(signal, name, None)
    if signum is not None:
        signal.signal(signum, signal.SIG_DFL)
binary, sessions = sys.argv[1:]
os.execv(binary, [binary, '--sessions', sessions])
"""


class Rejected(ValueError):
    """A required protocol, measurement or producer gate failed."""

    def __init__(self, code, detail):
        super().__init__(detail)
        self.code = code
        self.detail = detail


def reject(code, detail):
    raise Rejected(code, detail)


def distinct(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            reject("protocol", "Duplicate JSON object key.")
        result[key] = value
    return result


def integer(value):
    return type(value) is int and value >= 0


def constant(_value):
    reject("protocol", "Nonfinite JSON numbers are forbidden.")


def read_summary(summary, sessions):
    if type(summary) is not dict or set(summary) != SUMMARY_KEYS:
        reject("protocol", "Joined summary fields do not match schema 1.")
    for key in SUMMARY_KEYS.difference(POPULATIONS):
        if not integer(summary[key]):
            reject("protocol", "Summary counts and durations must be nonnegative exact integers.")
    if any(summary[key] != sessions for key in SESSION_KEYS):
        reject("capacity", "Worker acquisition, delivery, closure or plateau counts differ from sessions.")
    if not sessions <= summary["registered"] == summary["retired"] <= summary["events"]:
        reject("capacity", "Effect registration and retirement are incomplete.")
    if not 0 < summary["events"] <= summary["event_budget"]:
        reject("capacity", "Observed events are empty or exceed the declared budget.")
    if (summary["pending"] != 0 or summary["warmup_cycles"] != WARMUP_CYCLES
            or summary["measured_cycles"] != MEASURED_CYCLES):
        reject("capacity", "Workload cycles or shutdown obligations are incomplete.")
    if not 0 < summary["service_first_entry_ns"] <= summary["service_all_entries_ns"]:
        reject("capacity", "Native acquisition durations are missing or unordered.")
    for key in POPULATIONS:
        population = summary[key]
        if type(population) is not dict or set(population) != {"count", *QUANTILES}:
            reject("protocol", "Numeric population fields do not match schema 1.")
        if any(not integer(value) for value in population.values()):
            reject("protocol", "Population counts and durations must be nonnegative exact integers.")
        if not 0 < population["count"] <= summary["events"]:
            reject("capacity", "Numeric population is empty or exceeds observed events.")
        values = [population[name] for name in QUANTILES]
        if values != sorted(values):
            reject("capacity", "Numeric population quantiles are unordered.")
    if summary["poll_cycle"]["count"] != MEASURED_CYCLES:
        reject("capacity", "Measured poll-cycle sample count differs from the fixed workload.")
    if summary["startup_reducer_step"]["count"] < sessions + 1:
        reject("capacity", "Startup population omits Initial or worker-entry reductions.")
    if summary["steady_reducer_step"]["count"] < MEASURED_CYCLES:
        reject("capacity", "Steady population omits measured poll-cycle reductions.")


def read_identity(identity):
    if type(identity) is not dict or set(identity) != {*IDENTITY, "gc"}:
        reject("protocol", "Baseline identity fields do not match schema 1.")
    if any(type(identity[key]) is not type(value) or identity[key] != value
           for key, value in IDENTITY.items()):
        reject("capacity", "Baseline identity differs from the fixed workload and compiler.")
    gc = identity["gc"]
    if type(gc) is not dict or set(gc) != GC_KEYS or any(not integer(value) for value in gc.values()):
        reject("protocol", "Baseline GC controls must be exact nonnegative integers.")


def read_record(raw, *, phase, sessions):
    if not raw or len(raw) > MAX_LINE_BYTES:
        reject("protocol", "Checkpoint line is empty or exceeds its byte bound.")
    try:
        record = json.loads(raw.decode("utf-8"), object_pairs_hook=distinct, parse_constant=constant)
    except Rejected:
        raise
    except (UnicodeDecodeError, ValueError, RecursionError) as error:
        raise Rejected("protocol", "Checkpoint is not bounded UTF-8 JSON.") from error

    expected = {"schema", "phase", "sessions", "memory"}
    if phase == "baseline":
        expected.add("identity")
    if phase == "joined":
        expected.add("summary")
    if type(record) is not dict or set(record) != expected:
        reject("protocol", "Checkpoint fields do not match schema 1.")
    if type(record["schema"]) is not int or record["schema"] != SCHEMA:
        reject("protocol", "Unsupported checkpoint schema.")
    if record["phase"] != phase:
        reject("protocol", "Checkpoint phase is missing, repeated or out of order.")
    if type(record["sessions"]) is not int or record["sessions"] != sessions:
        reject("protocol", "Checkpoint session count differs from the requested workload.")
    memory = record["memory"]
    if type(memory) is not dict or set(memory) != MEMORY_KEYS:
        reject("protocol", "Checkpoint memory fields do not match schema 1.")
    if any(not integer(value) for value in memory.values()):
        reject("protocol", "Memory bytes must be nonnegative exact integers.")
    if phase == "baseline":
        read_identity(record["identity"])
    if phase == "joined":
        read_summary(record["summary"], sessions)
    return record


def parse_rss(raw, platform):
    if not raw or len(raw) > MAX_RSS_BYTES:
        reject("rss", "Resident-memory output is empty or exceeds its byte bound.")
    try:
        text = raw.decode("ascii")
    except UnicodeDecodeError as error:
        raise Rejected("rss", "Resident-memory output is not ASCII.") from error
    if platform == "linux":
        matches = re.findall(r"^Rss:[ \t]+([0-9]+)[ \t]+kB[ \t]*$", text, re.MULTILINE)
        if len(matches) != 1:
            reject("rss", "smaps_rollup has no unique Rss field with kB units.")
        amount = matches[0]
    elif platform == "darwin":
        match = re.fullmatch(r"[ \t]*([0-9]+)[ \t]*\n?", text)
        if match is None:
            reject("rss", "ps has no single RSS value.")
        amount = match[1]
    else:
        reject("rss", "Resident-memory measurement requires Linux or macOS.")
    try:
        value = int(amount) * BYTES_PER_KIB
    except ValueError as error:
        raise Rejected("rss", "Resident-memory integer exceeds the decoder bound.") from error
    if value <= 0:
        reject("rss", "A live producer must have a positive RSS measurement.")
    return value


def rss(pid, timeout):
    if sys.platform == "linux":
        argv = [sys.executable, "-I", "-c", LINUX_RSS, str(pid)]
    elif sys.platform == "darwin":
        argv = ["/bin/ps", "-o", "rss=", "-p", str(pid)]
    else:
        reject("rss", "Resident-memory measurement requires Linux or macOS.")
    try:
        result = bounded_process.run(
            argv, timeout=min(RSS_TIMEOUT, timeout), stdout_limit=MAX_RSS_BYTES,
            stderr_limit=MAX_RSS_BYTES, env={"PATH": "/usr/bin:/bin", "LC_ALL": "C"},
        )
    except (subprocess.SubprocessError, bounded_process.OutputLimit, OSError) as error:
        rejection = Rejected("rss", "Required resident-memory sampler failed.")
        for note in bounded_process.cleanup_notes(error):
            rejection.add_note(note)
        raise rejection from error
    if result.returncode != 0 or result.stderr:
        reject("rss", "Required resident-memory sampler failed or warned.")
    return parse_rss(result.stdout, sys.platform)


def check_rss(value):
    if not integer(value) or value == 0:
        reject("rss", "Required resident-memory sample is not a positive exact integer.")
    if value > RSS_CEILING_BYTES:
        reject("rss", "Resident-memory sample exceeds the calibrated absolute ceiling.")


def require_waitid():
    names = ("P_PID", "WEXITED", "WNOHANG", "WNOWAIT")
    if not callable(getattr(os, "waitid", None)) or any(not hasattr(os, name) for name in names):
        reject("cleanup", "Capacity watchdog requires POSIX waitid with WNOWAIT.")


def exited(child):
    # Observe without reaping: the owned leader reserves the group ID.
    return os.waitid(os.P_PID, child.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT) is not None


def release(child, selector):
    failures = []

    def kill():
        try:
            os.killpg(child.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass

    operations = [("kill", kill), ("reap", lambda: child.wait(timeout=REAP_TIMEOUT))]
    operations += [(name, pipe.close) for name, pipe in (
        ("stdin-close", child.stdin), ("stdout-close", child.stdout), ("stderr-close", child.stderr)
    )]
    if selector is not None:
        operations.append(("selector-close", selector.close))
    for stage, operation in operations:
        try:
            operation()
        except BaseException:
            failures.append((stage, *sys.exc_info()))
    return failures


def add_notes(error, failures, pid):
    for stage, _, secondary, _ in failures:
        error.add_note(f"Capacity cleanup failed: stage={stage} pid={pid} class={type(secondary).__name__}")


def execute(binary, sessions, *, timeout=DEFAULT_TIMEOUT, sample=rss):
    """Sample four acknowledged checkpoints; no service clock owns the watchdog.

    The sole deadline covers admission, protocol, RSS subprocesses, drain and
    normal exit. Failure cleanup has a separate bounded reap. Final group KILL
    precedes the sole reap on success too, closing any owned descendants.
    """
    if type(sessions) is not int or sessions not in SESSION_COUNTS or not 0 < timeout <= MAX_TIMEOUT:
        raise ValueError("capacity requires a supported session count and a timeout in (0, 60]")
    require_waitid()
    binary = Path(binary)
    if not binary.is_absolute() or not binary.is_file() or not os.access(binary, os.X_OK):
        reject("binary", "Capacity producer must be an absolute executable file.")

    started = time.monotonic_ns()
    deadline = time.monotonic() + timeout
    output, errors, line = bytearray(), bytearray(), bytearray()
    checkpoints = []
    sampled_rss = []
    ready = None
    selector = None
    child = None
    cleanup = None
    pending = None

    def collect(signum, _frame):
        nonlocal pending
        if pending is None:
            pending = signum

    def remaining():
        if pending == signal.SIGINT:
            raise KeyboardInterrupt
        if pending is not None:
            raise SystemExit(SIGNAL_EXIT_BASE + pending)
        value = deadline - time.monotonic()
        if value <= 0:
            raise subprocess.TimeoutExpired([str(binary), "--sessions", str(sessions)], timeout)
        return value

    def evidence():
        return {"schema": SCHEMA, "sessions": sessions, "checkpoints": checkpoints,
                "process_ready_ns": ready, "stdout": bytes(output), "stderr": bytes(errors),
                "producer_pid": child.pid if child is not None else None,
                "producer_status": child.returncode if child is not None else None,
                "producer_reaped": child is not None and child.returncode is not None,
                "rss_ceiling_bytes": RSS_CEILING_BYTES,
                "max_sampled_rss_bytes": max(sampled_rss, default=None)}

    previous = {signum: signal.signal(signum, collect) for signum in HANDLED_SIGNALS}
    try:
        remaining()
        child = subprocess.Popen(
            [sys.executable, "-I", "-c", LAUNCHER, str(binary), str(sessions)], cwd=binary.parent,
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            bufsize=0, start_new_session=True,
        )
        selector = selectors.DefaultSelector()
        os.set_blocking(child.stdin.fileno(), False)
        for pipe, name, limit, buffer in (
            (child.stdout, "stdout", MAX_STDOUT_BYTES, output),
            (child.stderr, "stderr", MAX_STDERR_BYTES, errors),
        ):
            os.set_blocking(pipe.fileno(), False)
            selector.register(pipe, selectors.EVENT_READ, (name, limit, buffer))

        while selector.get_map():
            for key, _ in selector.select(min(POLL_INTERVAL, remaining())):
                name, limit, buffer = key.data
                available = limit - len(buffer)
                chunk = os.read(key.fd, min(READ_CHUNK, available + 1))
                if len(chunk) > available:
                    reject("output", f"Producer {name} exceeds its byte bound.")
                if not chunk:
                    selector.unregister(key.fileobj)
                    if name == "stdout" and (line or len(checkpoints) != len(PHASES)):
                        reject("protocol", "Producer closed stdout before four complete checkpoints.")
                    continue
                buffer.extend(chunk)
                if name == "stderr":
                    continue
                line.extend(chunk)
                while b"\n" in line:
                    raw, _, tail = line.partition(b"\n")
                    if tail:
                        reject("protocol", "Producer pipelined bytes beyond an unacknowledged checkpoint.")
                    line = bytearray(tail)
                    if len(checkpoints) == len(PHASES):
                        reject("protocol", "Producer emitted stdout after the joined checkpoint.")
                    phase = PHASES[len(checkpoints)]
                    record = read_record(raw, phase=phase, sessions=sessions)
                    if checkpoints and record["memory"]["allocated_bytes"] < checkpoints[-1]["memory"]["allocated_bytes"]:
                        reject("memory", "Lifetime allocation bytes reversed across checkpoints.")
                    if ready is None:
                        ready = time.monotonic_ns() - started
                    if exited(child):
                        reject("producer", "Producer exited before its RSS checkpoint was acknowledged.")
                    resident = sample(child.pid, remaining())
                    if integer(resident) and resident > 0:
                        sampled_rss.append(resident)
                    check_rss(resident)
                    if phase in ("plateau", "steady") and resident < checkpoints[0]["rss_bytes"]:
                        reject("rss", "Active RSS is below the preallocated-workload baseline.")
                    remaining()
                    try:
                        early = os.read(child.stdout.fileno(), 1)
                    except BlockingIOError:
                        early = None
                    if early is not None:
                        reject("protocol", "Producer advanced or closed stdout before its acknowledgement.")
                    checkpoints.append({**record, "rss_bytes": resident})
                    ack = f"ACK {phase}\n".encode("ascii")
                    if os.write(child.stdin.fileno(), ack) != len(ack):
                        reject("protocol", "Producer acknowledgement was incomplete.")
                if len(line) > MAX_LINE_BYTES:
                    reject("protocol", "Producer checkpoint line exceeds its byte bound.")

        while not exited(child):
            time.sleep(min(POLL_INTERVAL, remaining()))
        remaining()
        if errors:
            reject("producer", "Producer emitted stderr.")
        cleanup = release(child, selector)
        selector = None
        if cleanup:
            _, _, error, traceback = cleanup[0]
            add_notes(error, cleanup, child.pid)
            raise error.with_traceback(traceback)
        if child.returncode != 0:
            reject("producer", "Producer exited with a nonzero status.")
        remaining()
        result = evidence()
        result["rss_per_session"] = {
            "numerator": checkpoints[1]["rss_bytes"] - checkpoints[0]["rss_bytes"],
            "denominator": sessions,
        }
        result["memory_per_session"] = {
            key: {"baseline": checkpoints[0]["memory"][key],
                  "plateau": checkpoints[1]["memory"][key],
                  "numerator": checkpoints[1]["memory"][key] - checkpoints[0]["memory"][key],
                  "denominator": sessions,
                  "status": ("valid" if checkpoints[1]["memory"][key] >= checkpoints[0]["memory"][key]
                             else "invalid")}
            for key in MEMORY_KEYS.difference({"allocated_bytes"})
        }
        result["status"] = "passed"
        return result
    except BaseException as error:
        if child is not None and cleanup is None:
            add_notes(error, release(child, selector), child.pid)
        error._capacity_evidence = evidence()
        raise
    finally:
        for signum, handler in previous.items():
            signal.signal(signum, handler)


def digest_file(path):
    digest = hashlib.sha256()
    total = 0
    with path.open("rb") as source:
        while True:
            chunk = source.read(READ_CHUNK)
            if not chunk:
                return digest.hexdigest()
            total += len(chunk)
            if total > MAX_BINARY_BYTES:
                reject("provenance", "Producer or harness bytes exceed the identity bound.")
            digest.update(chunk)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binary", type=Path, required=True)
    parser.add_argument("--sessions", type=int, choices=SESSION_COUNTS, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--timeout", type=float, default=DEFAULT_TIMEOUT)
    args = parser.parse_args()
    if not 0 < args.timeout <= MAX_TIMEOUT:
        parser.error("timeout must be between 0 and 60 seconds")
    try:
        args.out.mkdir(parents=True, exist_ok=False)
    except OSError:
        parser.error("out must name a new evidence directory")

    status = 0
    producer_digest = None
    result = {"schema": SCHEMA, "sessions": args.sessions}
    try:
        producer_digest = digest_file(args.binary)
        result = execute(args.binary, args.sessions, timeout=args.timeout)
        if producer_digest != digest_file(args.binary):
            reject("provenance", "Producer bytes changed during measurement.")
    except BaseException as error:
        if isinstance(error, KeyboardInterrupt):
            status = SIGNAL_EXIT_BASE + signal.SIGINT
        elif isinstance(error, SystemExit) and type(error.code) is int:
            status = error.code if error.code > 0 else 1
        else:
            status = 1
        result = getattr(error, "_capacity_evidence", result)
        result["status"] = "failed"
        result["failure"] = {"code": getattr(error, "code", "watchdog"),
                             "class": type(error).__name__}
        if isinstance(error, Rejected):
            result["failure"]["detail"] = error.detail
        result["cleanup_notes"] = list(getattr(error, "__notes__", ()))
    for name in ("stdout", "stderr"):
        data = result.pop(name, b"")
        (args.out / f"{name}.log").write_bytes(data)
        result[f"{name}_sha256"] = hashlib.sha256(data).hexdigest()
    result["watchdog_sha256"] = digest_file(Path(__file__))
    result["rss_capture_sha256"] = digest_file(Path(bounded_process.__file__))
    result["launcher_sha256"] = hashlib.sha256(LAUNCHER.encode("utf-8")).hexdigest()
    result["producer_sha256"] = producer_digest
    result["platform"] = {"sys_platform": sys.platform, "platform": platform.platform(),
                          "machine": platform.machine(), "processor": platform.processor(),
                          "python_version": platform.python_version()}
    rendered = json.dumps(result, indent=2, sort_keys=True) + "\n"
    (args.out / "manifest.json").write_text(rendered)
    print(rendered, end="")
    return status


if __name__ == "__main__":
    raise SystemExit(main())
