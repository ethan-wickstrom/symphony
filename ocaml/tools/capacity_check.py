"""Measure one finite native capacity producer with owned, bounded cleanup."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import signal
import subprocess
import sys
import time

from symphony_conformance.driver import capture
from symphony_conformance.driver import process
from symphony_conformance.driver.process import Cleanup, Process, Stdin


SCHEMA = 1
PHASES = ("baseline", "plateau", "steady", "joined")
MAX_ACK_BYTES = sum(len(f"ACK {phase}\n".encode("ascii")) for phase in PHASES)
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
HASH_CHUNK_BYTES = 64 * 1024
RSS_CEILING_BYTES = 128 * 1024 * 1024
RSS_TIMEOUT = 2
DEFAULT_TIMEOUT = 60
MAX_TIMEOUT = 60
POLL_INTERVAL = 0.01
SIGNAL_EXIT_BASE = 128
BYTES_PER_KIB = 1024
LINUX_RSS = (
    "import sys; "
    "source = open('/proc/' + sys.argv[1] + '/smaps_rollup', 'rb'); "
    f"data = source.read({MAX_RSS_BYTES + 1}); "
    "source.close(); sys.stdout.buffer.write(data)"
)


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
        result = capture.run(
            argv, timeout=min(RSS_TIMEOUT, timeout), stdout_limit=MAX_RSS_BYTES,
            stderr_limit=MAX_RSS_BYTES, env={"PATH": "/usr/bin:/bin", "LC_ALL": "C"},
        )
    except (subprocess.SubprocessError, capture.OutputLimit, OSError) as error:
        rejection = Rejected("rss", "Required resident-memory sampler failed.")
        for note in capture.cleanup_notes(error):
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










def execute(binary, sessions, *, timeout=DEFAULT_TIMEOUT, sample=rss):
    """Keep checkpoint/RSS policy above canonical process ownership."""
    if type(sessions) is not int or sessions not in SESSION_COUNTS or not 0 < timeout <= MAX_TIMEOUT:
        raise ValueError("capacity requires a supported session count and a timeout in (0, 60]")
    binary = Path(binary)
    if not binary.is_absolute() or not binary.is_file() or not os.access(binary, os.X_OK):
        reject("binary", "Capacity producer must be an absolute executable file.")

    started = time.monotonic_ns()
    deadline = time.monotonic() + timeout
    checkpoints, sampled_rss = [], []
    ready = None
    owner = None
    retained = None

    def remaining():
        if owner is not None and not owner.snapshot()["closed"]:
            return owner.remaining()
        value = deadline - time.monotonic()
        if value <= 0:
            raise subprocess.TimeoutExpired([str(binary), "--sessions", str(sessions)], timeout)
        return value

    def evidence():
        observed = owner.snapshot() if owner is not None else retained
        observed = observed or {}
        return {"schema": SCHEMA, "sessions": sessions, "checkpoints": checkpoints,
                "process_ready_ns": ready, "stdout": observed.get("stdout", b""),
                "stderr": observed.get("stderr", b""),
                "producer_pid": observed.get("pid"), "producer_status": observed.get("returncode"),
                "producer_reaped": observed.get("reaped", False),
                "process_lifecycle": observed.get("lifecycle", ()),
                "process_failures": observed.get("failures", ()),
                "rss_ceiling_bytes": RSS_CEILING_BYTES,
                "max_sampled_rss_bytes": max(sampled_rss, default=None)}

    try:
        with Process([str(binary), "--sessions", str(sessions)], binary.parent,
                     dict(os.environ), {"stdout": MAX_STDOUT_BYTES, "stderr": MAX_STDERR_BYTES},
                     deadline, stdin=Stdin.PIPE, stdin_limit=MAX_ACK_BYTES, cleanup=Cleanup.KILL) as owner:
            cursor = 0
            for phase in PHASES:
                while True:
                    observed = owner.pump(min(POLL_INTERVAL, remaining()))
                    line = observed["stdout"][cursor:]
                    if b"\n" in line:
                        break
                    if len(line) > MAX_LINE_BYTES:
                        reject("protocol", "Producer checkpoint line exceeds its byte bound.")
                    if "stdout" in observed["eof"]:
                        reject("protocol", "Producer closed stdout before four complete checkpoints.")
                    if observed["returncode"] is not None:
                        reject("producer", "Producer exited before its RSS checkpoint was acknowledged.")
                raw, _, tail = line.partition(b"\n")
                if tail:
                    reject("protocol", "Producer pipelined bytes beyond an unacknowledged checkpoint.")
                cursor = len(observed["stdout"])
                record = read_record(raw, phase=phase, sessions=sessions)
                if checkpoints and record["memory"]["allocated_bytes"] < checkpoints[-1]["memory"]["allocated_bytes"]:
                    reject("memory", "Lifetime allocation bytes reversed across checkpoints.")
                if ready is None:
                    ready = time.monotonic_ns() - started
                if observed["returncode"] is not None:
                    reject("producer", "Producer exited before its RSS checkpoint was acknowledged.")
                resident = sample(observed["pid"], remaining())
                if integer(resident) and resident > 0:
                    sampled_rss.append(resident)
                check_rss(resident)
                if phase in ("plateau", "steady") and resident < checkpoints[0]["rss_bytes"]:
                    reject("rss", "Active RSS is below the preallocated-workload baseline.")

                observed = owner.pump()
                if len(observed["stdout"]) != cursor or "stdout" in observed["eof"]:
                    reject("protocol", "Producer advanced or closed stdout before its acknowledgement.")
                if observed["returncode"] is not None:
                    reject("producer", "Producer exited before its RSS checkpoint was acknowledged.")
                checkpoints.append({**record, "rss_bytes": resident})
                owner.write(f"ACK {phase}\n".encode("ascii"))

            status = owner.join(remaining())
            observed = owner.snapshot()
            if len(observed["stdout"]) != cursor:
                reject("protocol", "Producer emitted stdout after the joined checkpoint.")
            if observed["stderr"]:
                reject("producer", "Producer emitted stderr.")
            if status != 0:
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
        retained = getattr(error, "_process_snapshot", None)
        if isinstance(error, capture.OutputLimit):
            rejected = Rejected("output", "Producer exceeded its independent byte bound.")
            for note in getattr(error, "__notes__", ()):
                rejected.add_note(note)
            rejected._capacity_evidence = evidence()
            raise rejected from error
        error._capacity_evidence = evidence()
        raise



def digest_file(path):
    digest = hashlib.sha256()
    total = 0
    with path.open("rb") as source:
        while True:
            chunk = source.read(HASH_CHUNK_BYTES)
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
    result["rss_capture_sha256"] = digest_file(Path(capture.__file__))
    result["process_sources"] = {path.name: digest_file(path) for path in
                                 (Path(capture.__file__), Path(process.__file__), process.SENTINEL)}
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
