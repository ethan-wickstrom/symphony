"""Control the parent capacity protocol, physical sampler and owned watchdog."""

import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import textwrap
import threading
import time
import unittest
from unittest.mock import patch


TOOLS = Path(__file__).resolve().parents[1] / "tools"
sys.path.insert(0, str(TOOLS))
SPEC = importlib.util.spec_from_file_location("capacity_check", TOOLS / "capacity_check.py")
GATE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GATE)
GATE_TIMEOUT = 2
OUTER_TIMEOUT = 10
FIXTURE_LIFETIME = 10
SESSION_COUNT = 10
RSS_BYTES = 1024 * 1024
MEMORY = {key: 1024 for key in GATE.MEMORY_KEYS}
IDENTITY = {**GATE.IDENTITY, "gc": {key: 1024 for key in GATE.GC_KEYS}}
SUMMARY = {**{key: SESSION_COUNT for key in GATE.SESSION_KEYS},
           "registered": SESSION_COUNT + 1, "retired": SESSION_COUNT + 1,
           "warmup_cycles": GATE.WARMUP_CYCLES, "measured_cycles": GATE.MEASURED_CYCLES,
           "events": 500, "event_budget": 600, "pending": 0,
           "service_first_entry_ns": 1, "service_all_entries_ns": 2,
           **{key: {"count": GATE.MEASURED_CYCLES, "p50_ns": 1, "p95_ns": 2,
                    "p99_ns": 3, "max_ns": 4} for key in GATE.POPULATIONS}}


def record(phase):
    value = {"schema": GATE.SCHEMA, "phase": phase, "sessions": SESSION_COUNT,
             "memory": dict(MEMORY)}
    if phase == "baseline":
        value["identity"] = IDENTITY
    if phase == "joined":
        value["summary"] = SUMMARY
    return value


def encoded(phase):
    return json.dumps(record(phase)).encode("utf-8")


class ProtocolTest(unittest.TestCase):
    def test_exact_schema(self):
        for phase in GATE.PHASES:
            self.assertEqual(record(phase), GATE.read_record(
                encoded(phase), phase=phase, sessions=SESSION_COUNT))

    def test_invalid_protocol(self):
        cases = []
        for field, value in (("schema", True), ("schema", 2), ("sessions", True),
                             ("sessions", 100), ("phase", "steady"), ("extra", 0)):
            changed = record("baseline")
            changed[field] = value
            cases.append(json.dumps(changed).encode())
        for value in (True, -1, 1.0, None, "1"):
            changed = record("baseline")
            changed["memory"]["live_heap_bytes"] = value
            cases.append(json.dumps(changed).encode())
        cases += [b'{}', b'[]', b'null', b'\xff', b'{', b'']
        for raw in cases:
            with self.subTest(raw=raw), self.assertRaises(GATE.Rejected):
                GATE.read_record(raw, phase="baseline", sessions=SESSION_COUNT)

    def test_duplicate_and_nonfinite(self):
        raw = encoded("baseline")
        for rejected in (raw.replace(b'"schema": 1', b'"schema": 1, "schema": 1'),
                         raw.replace(b'1024', b'NaN', 1), raw.replace(b'1024', b'Infinity', 1)):
            with self.subTest(raw=rejected), self.assertRaises(GATE.Rejected):
                GATE.read_record(rejected, phase="baseline", sessions=SESSION_COUNT)

    def test_line_bound(self):
        raw = encoded("baseline")
        exact = raw + b' ' * (GATE.MAX_LINE_BYTES - len(raw))
        self.assertEqual(record("baseline"), GATE.read_record(
            exact, phase="baseline", sessions=SESSION_COUNT))
        with self.assertRaises(GATE.Rejected):
            GATE.read_record(exact + b' ', phase="baseline", sessions=SESSION_COUNT)

    def test_rss_units_and_rejections(self):
        self.assertEqual(123 * 1024, GATE.parse_rss(b"Rss: 123 kB\nPss: 10 kB\n", "linux"))
        self.assertEqual(123 * 1024, GATE.parse_rss(b" 123\n", "darwin"))
        cases = ((b"", "linux"), (b"Rss: 1 B\n", "linux"),
                 (b"Rss: 1 kB\nRss: 2 kB\n", "linux"), (b"Rss: 0 kB\n", "linux"),
                 (b"1\n2\n", "darwin"), (b"-1\n", "darwin"),
                 (b"0\n", "darwin"), (b"1\xff\n", "darwin"), (b"1\n", "unknown"))
        for raw, platform in cases:
            with self.subTest(raw=raw, platform=platform), self.assertRaises(GATE.Rejected):
                GATE.parse_rss(raw, platform)

    def test_incomplete_summary(self):
        for key, value in (("acquired", 9), ("released", 9), ("owner_started", 9),
                           ("owner_completed", 9), ("peak_running", 9), ("retired", 10),
                           ("events", 0), ("event_budget", 499), ("pending", 1),
                           ("warmup_cycles", 4), ("measured_cycles", 99),
                           ("service_first_entry_ns", 0), ("service_all_entries_ns", 0)):
            value_record = json.loads(encoded("joined"))
            value_record["summary"][key] = value
            with self.subTest(key=key), self.assertRaises(GATE.Rejected):
                GATE.read_record(json.dumps(value_record).encode(), phase="joined", sessions=SESSION_COUNT)
        for population in GATE.POPULATIONS:
            for key, value in (("count", 0), ("count", True), ("count", 501),
                               ("p95_ns", 0), ("p99_ns", 5), ("max_ns", 1.0)):
                value_record = json.loads(encoded("joined"))
                value_record["summary"][population][key] = value
                with self.subTest(population=population, key=key), self.assertRaises(GATE.Rejected):
                    GATE.read_record(json.dumps(value_record).encode(), phase="joined", sessions=SESSION_COUNT)
        value_record = json.loads(encoded("joined"))
        value_record["summary"]["poll_cycle"]["count"] = 99
        with self.assertRaises(GATE.Rejected):
            GATE.read_record(json.dumps(value_record).encode(), phase="joined", sessions=SESSION_COUNT)
        for population, count in (("startup_reducer_step", SESSION_COUNT),
                                  ("steady_reducer_step", GATE.MEASURED_CYCLES - 1)):
            value_record = json.loads(encoded("joined"))
            value_record["summary"][population]["count"] = count
            with self.subTest(population=population), self.assertRaises(GATE.Rejected):
                GATE.read_record(json.dumps(value_record).encode(), phase="joined", sessions=SESSION_COUNT)
        value_record = json.loads(encoded("joined"))
        value_record["summary"].update(registered=1, retired=1)
        with self.assertRaises(GATE.Rejected):
            GATE.read_record(json.dumps(value_record).encode(), phase="joined", sessions=SESSION_COUNT)

    def test_invalid_identity(self):
        for key, value in (("workload", "other"), ("ocaml_version", "5.4.0"),
                           ("word_size", True), ("global_cap", 10), ("state_cap", 10),
                           ("poll_interval_ms", 100), ("gc", {})):
            value_record = json.loads(encoded("baseline"))
            value_record["identity"][key] = value
            with self.subTest(key=key), self.assertRaises(GATE.Rejected):
                GATE.read_record(json.dumps(value_record).encode(), phase="baseline", sessions=SESSION_COUNT)
        for value in (-1, True, 1.0):
            value_record = json.loads(encoded("baseline"))
            value_record["identity"]["gc"]["minor_heap_size"] = value
            with self.subTest(value=value), self.assertRaises(GATE.Rejected):
                GATE.read_record(json.dumps(value_record).encode(), phase="baseline", sessions=SESSION_COUNT)

    def test_sampler_failures(self):
        failures = (subprocess.TimeoutExpired(["sample"], 1),
                    GATE.bounded_process.OutputLimit("overflow"), OSError("missing"))
        for platform in ("linux", "darwin"):
            for error in failures:
                with patch.object(GATE.sys, "platform", platform), \
                        patch.object(GATE.bounded_process, "run", side_effect=error), \
                        self.subTest(platform=platform, error=type(error).__name__), \
                        self.assertRaises(GATE.Rejected):
                    GATE.rss(123, GATE.RSS_TIMEOUT)

            for result in (subprocess.CompletedProcess(["sample"], 0, b"", b""),
                           subprocess.CompletedProcess(["sample"], 1, b"1\n", b""),
                           subprocess.CompletedProcess(["sample"], 0, b"1\n", b"warning")):
                with patch.object(GATE.sys, "platform", platform), \
                        patch.object(GATE.bounded_process, "run", return_value=result), \
                        self.assertRaises(GATE.Rejected):
                    GATE.rss(123, GATE.RSS_TIMEOUT)

    def test_rss_ceiling(self):
        GATE.check_rss(GATE.RSS_CEILING_BYTES)
        with self.assertRaises(GATE.Rejected):
            GATE.check_rss(GATE.RSS_CEILING_BYTES + 1)


class ParentTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="symphony-capacity-parent-")
        self.base = Path(self.temporary.name)
        self.children = []

    def tearDown(self):
        for child in self.children:
            self.assertIsNotNone(child.returncode, "parent did not reap its producer")
            with self.assertRaises(ChildProcessError):
                os.waitpid(child.pid, os.WNOHANG)
        self.temporary.cleanup()

    def producer(self, mode="done"):
        binary = self.base / "producer"
        binary.write_text(
            f"#!{sys.executable}\n"
            "import json, os, signal, sys, time\n"
            f"phases = {GATE.PHASES!r}\n"
            f"memory = {MEMORY!r}\n"
            f"summary = {SUMMARY!r}\n"
            f"identity = {IDENTITY!r}\n"
            f"sessions = {SESSION_COUNT}\n"
            f"mode = {mode!r}\n"
            f"lifetime = {FIXTURE_LIFETIME}\n"
            f"pidfile = {str(self.base / 'descendant.pid')!r}\n"
            f"readyfile = {str(self.base / 'ready')!r}\n"
            f"line_bound = {GATE.MAX_LINE_BYTES}\n"
            f"stderr_bound = {GATE.MAX_STDERR_BYTES}\n"
            + textwrap.dedent(r"""
            open(readyfile, 'w').write(str(os.getpid()))
            if mode == 'before_ready':
                time.sleep(lifetime)
            if mode == 'slow':
                time.sleep(0.05)
            if mode == 'descendant':
                pid = os.fork()
                if pid == 0:
                    for fd in (0, 1, 2):
                        os.close(fd)
                    time.sleep(lifetime)
                    os._exit(0)
                open(pidfile, 'w').write(str(pid))
            for phase in phases:
                if mode == 'allocation_reverse' and phase == 'plateau':
                    memory = dict(memory)
                    memory['allocated_bytes'] -= 1
                value = {'schema': 1, 'phase': phase, 'sessions': sessions, 'memory': memory}
                if phase == 'baseline':
                    value['identity'] = identity
                if phase == 'joined':
                    value['summary'] = summary
                if mode == 'wrong_phase' and phase == 'plateau':
                    value['phase'] = 'baseline'
                if mode == 'line_flood':
                    sys.stdout.write('X' * (line_bound + 1))
                    sys.stdout.flush()
                    time.sleep(lifetime)
                if mode == 'stderr_flood':
                    sys.stderr.write('X' * (stderr_bound + 1))
                    sys.stderr.flush()
                    time.sleep(lifetime)
                sys.stdout.write(json.dumps(value) + '\n')
                if mode == 'eager':
                    sys.stdout.write('{}\n')
                sys.stdout.flush()
                ack = sys.stdin.readline()
                if ack != 'ACK ' + phase + '\n':
                    sys.exit(9)
                if mode == 'hung':
                    time.sleep(lifetime)
            if mode == 'closed_hang':
                os.close(1)
                os.close(2)
                time.sleep(lifetime)
            if mode == 'extra':
                sys.stdout.write('{}\n')
                sys.stdout.flush()
            if mode == 'stderr':
                sys.stderr.write('warning\n')
                sys.stderr.flush()
            sys.exit(7 if mode == 'failed' else 0)
            """)
        )
        if mode == "bad_exec":
            binary.write_text("#!/missing/symphony-capacity-interpreter\n")
        binary.chmod(0o700)
        return binary

    def run_producer(self, mode="done", sample=None):
        if sample is None:
            sample = lambda _pid, _timeout: RSS_BYTES
        popen = subprocess.Popen

        def own(*args, **kwargs):
            child = popen(*args, **kwargs)
            self.children.append(child)
            return child

        with patch.object(GATE.subprocess, "Popen", own):
            return GATE.execute(self.producer(mode), SESSION_COUNT,
                                timeout=GATE_TIMEOUT, sample=sample)

    def test_acknowledged_samples(self):
        pids = []

        def sample(pid, timeout):
            pids.append(pid)
            self.assertGreater(timeout, 0)
            self.assertLessEqual(timeout, GATE_TIMEOUT)
            return RSS_BYTES + len(pids) * 1024

        result = self.run_producer(sample=sample)
        self.assertEqual("passed", result["status"])
        self.assertEqual([self.children[0].pid] * len(GATE.PHASES), pids)
        self.assertEqual(list(GATE.PHASES), [row["phase"] for row in result["checkpoints"]])
        self.assertEqual({"numerator": 1024, "denominator": SESSION_COUNT}, result["rss_per_session"])
        self.assertGreater(result["process_ready_ns"], 0)

    def test_slow_ready(self):
        result = self.run_producer("slow")
        self.assertGreaterEqual(result["process_ready_ns"], 50_000_000)
        self.assertEqual("passed", result["status"])

    def test_hung_and_closed_pipes(self):
        for mode in ("hung", "closed_hang", "before_ready"):
            with self.subTest(mode=mode), self.assertRaises(subprocess.TimeoutExpired):
                self.run_producer(mode)

    def test_invalid_outputs(self):
        for mode in ("wrong_phase", "line_flood", "stderr_flood", "extra", "stderr", "failed", "eager", "allocation_reverse"):
            with self.subTest(mode=mode), self.assertRaises(GATE.Rejected):
                self.run_producer(mode)

    def test_missing_rss(self):
        for sample in (lambda _pid, _timeout: 0, lambda _pid, _timeout: True):
            with self.assertRaises(GATE.Rejected):
                self.run_producer(sample=sample)
        values = iter((RSS_BYTES, RSS_BYTES - 1))
        with self.assertRaises(GATE.Rejected):
            self.run_producer(sample=lambda _pid, _timeout: next(values))
        missing = GATE.Rejected("rss", "missing")

        def fail(_pid, _timeout):
            raise missing

        with self.assertRaises(GATE.Rejected) as raised:
            self.run_producer(sample=fail)
        self.assertIs(missing, raised.exception)

    def test_rss_ceiling(self):
        result = self.run_producer(sample=lambda _pid, _timeout: GATE.RSS_CEILING_BYTES)
        self.assertEqual(GATE.RSS_CEILING_BYTES, result["rss_ceiling_bytes"])
        self.assertEqual(GATE.RSS_CEILING_BYTES, result["max_sampled_rss_bytes"])
        with self.assertRaises(GATE.Rejected) as raised:
            self.run_producer(sample=lambda _pid, _timeout: GATE.RSS_CEILING_BYTES + 1)
        self.assertEqual(GATE.RSS_CEILING_BYTES + 1,
                         raised.exception._capacity_evidence["max_sampled_rss_bytes"])

    def test_primary_survives_cleanup(self):
        primary = RuntimeError("sample failed")
        secondary = RuntimeError("close failed")
        release = GATE.release

        def fail(_pid, _timeout):
            raise primary

        def close(child, selector):
            return release(child, selector) + [("selector-close", RuntimeError, secondary, None)]

        with patch.object(GATE, "release", close), self.assertRaises(RuntimeError) as raised:
            self.run_producer(sample=fail)
        self.assertIs(primary, raised.exception)
        self.assertEqual(1, len(raised.exception.__notes__))
        self.assertIn("stage=selector-close", raised.exception.__notes__[0])

    def test_launch_failure(self):
        with self.assertRaises(GATE.Rejected) as raised:
            self.run_producer("bad_exec")
        evidence = raised.exception._capacity_evidence
        self.assertTrue(evidence["producer_reaped"])
        self.assertIn(b"FileNotFoundError", evidence["stderr"])

    def test_normal_closes_group(self):
        self.assertEqual("passed", self.run_producer("descendant")["status"])
        pid = int((self.base / "descendant.pid").read_text())
        result = subprocess.run(["/bin/ps", "-o", "stat=", "-p", str(pid)],
                                capture_output=True, timeout=GATE_TIMEOUT, check=False)
        self.assertIn(result.returncode, (0, 1))
        self.assertFalse(result.stdout.strip() and not result.stdout.strip().startswith(b"Z"),
                         "normal producer exit left an owned descendant alive")

    def test_native_rss(self):
        pids = []

        def sample(pid, timeout):
            self.assertGreater(GATE.rss(pid, timeout), 0)
            pids.append(pid)
            return RSS_BYTES

        self.assertEqual("passed", self.run_producer(sample=sample)["status"])
        self.assertEqual([self.children[0].pid] * len(GATE.PHASES), pids)

    def test_idle_signal(self):
        timers = []

        def sample(_pid, _timeout):
            timer = threading.Timer(0.05, os.kill, (os.getpid(), signal.SIGTERM))
            timers.append(timer)
            timer.start()
            return RSS_BYTES

        started = time.monotonic()
        try:
            with self.assertRaises(SystemExit) as raised:
                self.run_producer("hung", sample=sample)
            self.assertEqual(GATE.SIGNAL_EXIT_BASE + signal.SIGTERM, raised.exception.code)
            self.assertLess(time.monotonic() - started, GATE_TIMEOUT / 2,
                            "signal did not wake the idle watchdog before its deadline")
        finally:
            for timer in timers:
                timer.cancel()
                timer.join()

    def test_admission_signal(self):
        popen = subprocess.Popen

        def admit(*args, **kwargs):
            child = popen(*args, **kwargs)
            self.children.append(child)
            os.kill(os.getpid(), signal.SIGTERM)
            return child

        with patch.object(GATE.subprocess, "Popen", admit), self.assertRaises(SystemExit) as raised:
            GATE.execute(self.producer(), SESSION_COUNT, timeout=GATE_TIMEOUT,
                         sample=lambda _pid, _timeout: RSS_BYTES)
        self.assertEqual(GATE.SIGNAL_EXIT_BASE + signal.SIGTERM, raised.exception.code)

    def test_signal_receipts(self):
        for requested in (signal.SIGINT, signal.SIGTERM):
            with self.subTest(signal=requested):
                binary = self.producer("before_ready")
                ready = self.base / "ready"
                ready.unlink(missing_ok=True)
                output = self.base / f"signal-{requested}"
                flags = ["-B", "-O"] if sys.flags.optimize else ["-B"]
                child = subprocess.Popen(
                    [sys.executable, *flags, str(TOOLS / "capacity_check.py"), "--binary", str(binary),
                     "--sessions", str(SESSION_COUNT), "--out", str(output), "--timeout", str(GATE_TIMEOUT)],
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                )
                self.children.append(child)
                try:
                    deadline = time.monotonic() + GATE_TIMEOUT
                    while not ready.exists():
                        if time.monotonic() >= deadline:
                            self.fail("signal fixture did not acquire its owned producer")
                        time.sleep(GATE.POLL_INTERVAL)
                    child.send_signal(requested)
                    stdout, stderr = child.communicate(timeout=OUTER_TIMEOUT)
                finally:
                    if child.returncode is None:
                        child.kill()
                        child.communicate(timeout=OUTER_TIMEOUT)
                self.assertEqual(GATE.SIGNAL_EXIT_BASE + requested, child.returncode, stdout + stderr)
                manifest = json.loads((output / "manifest.json").read_text())
                self.assertEqual("failed", manifest["status"])
                self.assertTrue(manifest["producer_reaped"])
                self.assertEqual(-signal.SIGKILL, manifest["producer_status"])
                self.assertEqual(int(ready.read_text()), manifest["producer_pid"])
                self.assertTrue((output / "stdout.log").is_file())
                self.assertTrue((output / "stderr.log").is_file())

    def test_cli_failure_receipt(self):
        binary = self.producer("before_ready")
        output = self.base / "evidence"
        flags = ["-B", "-O"] if sys.flags.optimize else ["-B"]
        result = subprocess.run(
            [sys.executable, *flags, str(TOOLS / "capacity_check.py"), "--binary", str(binary),
             "--sessions", str(SESSION_COUNT), "--out", str(output), "--timeout", str(GATE_TIMEOUT)],
            capture_output=True, timeout=OUTER_TIMEOUT, check=False,
        )
        self.assertEqual(1, result.returncode, result.stderr)
        manifest = json.loads((output / "manifest.json").read_text())
        self.assertEqual("failed", manifest["status"])
        self.assertEqual("TimeoutExpired", manifest["failure"]["class"])
        self.assertEqual(b"", (output / "stdout.log").read_bytes())
        self.assertEqual(b"", (output / "stderr.log").read_bytes())


if __name__ == "__main__":
    unittest.main()
