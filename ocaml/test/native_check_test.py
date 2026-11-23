"""Real-process controls for the native watchdog's retained group identity."""

import os
from enum import Enum
import hashlib
import json
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest

sys.dont_write_bytecode = True
import native_check

FIXTURE_LIFETIME = 20
READY_TIMEOUT = 5
INTERRUPT_TIMEOUT = 8
GATE_TIMEOUT = 1
GATE_OUTER_TIMEOUT = 12
AGENT_UNITS = (
    "app_server", "codex_runner", "protocol_codec", "protocol_envelope",
    "protocol_frame", "protocol_id",
)
ORCHESTRATION_UNITS = (
    "agent_observation", "agent_plan", "agent_runner", "backoff", "dispatch_order",
    "issue_lifecycle", "orchestrator", "ownership", "run_plan", "snapshot",
    "status_source", "status_surface", "stop_reason", "usage",
)
LIFECYCLE_UNITS = (
    "native_shutdown_test", "native_output_test", "native_status_test",
    "native_scope_test", "host_lifecycle_main",
)
NATIVE_ENV_NAMES = (native_check.PYTHON_ENV, native_check.SERVER_ENV, native_check.TLS_ENV)


class Stage(Enum):
    ADMISSION = "admission"
    HELD = "held"


def running(pid):
    probe = subprocess.run(
        ["ps", "-p", str(pid), "-o", "stat="],
        capture_output=True,
        text=True,
        timeout=2,
        check=False,
    )
    if probe.returncode not in (0, 1):
        raise RuntimeError(f"process-state probe failed: {probe.stderr}")
    state = probe.stdout.strip()
    return bool(state) and not state.startswith("Z")


def group_fixture(base, finish, *, admission):
    helper = base / "helper"
    receipt = base / "group.pid"
    helper.write_text(
        f"#!{sys.executable}\n"
        "import os, signal, time\n"
        "from pathlib import Path\n"
        f"receipt = Path({str(receipt)!r})\n"
        f"ready = Path({str(base / 'ready')!r})\n"
        "signal.signal(signal.SIGTERM, lambda *_: os._exit(0))\n"
        f"time.sleep({admission})\n"
        "child = os.fork()\n"
        "if child == 0:\n"
        "    signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
        "    for fd in (0, 1, 2): os.close(fd)\n"
        "    ready.write_text('ready')\n"
        f"    time.sleep({FIXTURE_LIFETIME})\n"
        "    os._exit(0)\n"
        f"deadline = time.monotonic() + {READY_TIMEOUT}\n"
        "while not ready.exists():\n"
        "    if time.monotonic() >= deadline:\n"
        "        os._exit(2)\n"
        "    time.sleep(0.01)\n"
        "pending = receipt.with_suffix('.pending')\n"
        "pending.write_text(f'{os.getpid()} {child}')\n"
        "pending.replace(receipt)\n"
        f"{finish}\n"
    )
    helper.chmod(0o700)
    return helper, receipt


def await_fixtures(receipt):
    # A receipt permits observation, never signaling after its owner has reaped.
    # Failed controls leave only finite helpers; waiting cannot mask the failure.
    if not receipt.is_file():
        return
    try:
        pids = [int(text) for text in receipt.read_text().split()]
        deadline = time.monotonic() + FIXTURE_LIFETIME + READY_TIMEOUT
        while time.monotonic() < deadline and any(running(pid) for pid in pids):
            time.sleep(0.01)
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError):
        return


def exit_target(base, name):
    directory = base / name
    directory.mkdir()
    helper = directory / "target"
    helper.write_text(
        f"#!{sys.executable}\n"
        "from pathlib import Path\n"
        "import json, os, sys\n"
        f"names = {NATIVE_ENV_NAMES!r}\n"
        "Path('environment.json').write_text(json.dumps({name: os.environ.get(name) for name in names}))\n"
        "sys.exit(0 if Path.cwd() == Path(__file__).parent else 2)\n"
    )
    helper.chmod(0o700)
    return helper


def gate_command():
    optimize = ["-O"] * sys.flags.optimize
    return [sys.executable, *optimize, str(Path(native_check.__file__))]


class NativeWatchdogTest(unittest.TestCase):
    def agent_evidence(self, evidence):
        expected_env = {
            native_check.PYTHON_ENV: sys.executable,
            native_check.SERVER_ENV: str(native_check.AGENT_FIXTURE),
            native_check.TLS_ENV: native_check.TLS_DIRECTORY,
        }
        self.assertEqual({"kernel", "host", "http", "agent", "lifecycle"}, set(evidence["results"]))
        self.assertEqual(set(evidence["results"]), set(evidence["binaries"]))
        self.assertEqual(expected_env, evidence["binaries"]["agent"]["environment"])
        for name in ("kernel", "host", "http", "lifecycle"):
            self.assertEqual({native_check.TLS_ENV: native_check.TLS_DIRECTORY},
                             evidence["binaries"][name]["environment"])
        self.assertEqual(len(evidence["sources"]), evidence["source_count"])
        for area, units in (("agent", AGENT_UNITS), ("orchestration", ORCHESTRATION_UNITS)):
            expected = {f"lib/{area}/{unit}{suffix}" for unit in units for suffix in (".ml", ".mli")}
            expected.add(f"lib/{area}/dune")
            actual = {name for name in evidence["sources"] if name.startswith(f"lib/{area}/")}
            self.assertEqual(expected, actual, f"incomplete {area} source evidence")
        root = Path(native_check.__file__).resolve().parents[1]
        required = (
            "dune", "dune-project", "test/dune", "test/native_agent_test.ml",
            "test/native_agent_test.mli", "test/fixtures/agent/native_server.py",
            "protocol/0.159.2/policies.json", "protocol/0.159.2/manifest.json",
            "protocol/0.159.2/codec/manifest.json",
        )
        for name in required:
            expected = hashlib.sha256((root / name).read_bytes()).hexdigest()
            self.assertEqual(expected, evidence["sources"].get(name), f"missing or stale hash: {name}")
        lock = root.parent / "conformance/requirements.lock"
        self.assertEqual(hashlib.sha256(lock.read_bytes()).hexdigest(),
                         evidence["sources"].get("conformance/requirements.lock"))
        for name in native_check.TLS_FILES:
            resource = "tls/" + name
            self.assertEqual(native_check.assets.digest(resource),
                             evidence["sources"].get("package/" + resource))
        self.assertEqual(native_check.assets.digest("protocol/manifest.json"),
                         evidence["sources"].get("package/protocol/manifest.json"))
        schemas = native_check.assets.load("protocol/manifest.json")["files"]
        expected_schemas = {"package/protocol/schemas/" + name: digest for name, digest in schemas.items()}
        actual_schemas = {name: digest for name, digest in evidence["sources"].items()
                          if name.startswith("package/protocol/schemas/")}
        self.assertEqual(expected_schemas, actual_schemas)
        for unit in LIFECYCLE_UNITS:
            for suffix in (".ml", ".mli"):
                name = f"test/{unit}{suffix}"
                expected = hashlib.sha256((root / name).read_bytes()).hexdigest()
                self.assertEqual(expected, evidence["sources"].get(name),
                                 f"missing or stale lifecycle hash: {name}")
        interpreter = Path(sys.executable).resolve()
        self.assertEqual(sys.executable, evidence["python"]["executable"])
        self.assertEqual(str(interpreter), evidence["python"]["resolved"])
        self.assertEqual(hashlib.sha256(interpreter.read_bytes()).hexdigest(), evidence["python"]["sha256"])
        self.assertEqual(sys.implementation.name, evidence["python"]["implementation"])
        self.assertEqual(sys.implementation.cache_tag, evidence["python"]["cache_tag"])
        self.assertEqual(sys.flags.optimize, evidence["python"]["optimize"])
        self.assertEqual(sys.flags.optimize, evidence["watchdog"]["optimize"])
        self.assertEqual(min(sys.flags.optimize, 2), evidence["helper"]["optimize"])
        for source in (Path(native_check.capture.__file__), Path(native_check.process.__file__),
                       native_check.SENTINEL):
            self.assertEqual(hashlib.sha256(source.read_bytes()).hexdigest(),
                             evidence["driver"]["sources"][source.name])
        self.assertEqual(str(native_check.AGENT_FIXTURE), evidence["agent_fixture"]["path"])
        self.assertEqual(evidence["sources"]["test/fixtures/agent/native_server.py"],
                         evidence["agent_fixture"]["sha256"])

    def test_http_hang_bounded(self):
        # No service clock participates in this hung target. The watchdog is
        # its independent owner and must finish after TERM/kill/sole reap.
        with tempfile.TemporaryDirectory(prefix="symphony-http-hang-") as base:
            base = Path(base)
            helper, receipt = group_fixture(base, f"time.sleep({FIXTURE_LIFETIME})", admission=0)
            try:
                outcome = native_check.execute(helper, base / "run.log", GATE_TIMEOUT)
                self.assertEqual("timeout", outcome["status"])
                self.assertTrue(receipt.is_file(), "hung target never became ready")
                for text in receipt.read_text().split():
                    self.assertFalse(running(int(text)), "hung target leaked its group")
            finally:
                await_fixtures(receipt)

    def test_http_gate_manifest(self):
        with tempfile.TemporaryDirectory(prefix="symphony-http-gate-") as base:
            base = Path(base)
            targets = {}
            for name in ("kernel", "host", "agent", "lifecycle"):
                targets[name] = exit_target(base, name)
            directory = base / "http"
            directory.mkdir()
            helper, receipt = group_fixture(directory, f"time.sleep({FIXTURE_LIFETIME})", admission=0)
            out = base / "evidence"
            try:
                probe = subprocess.run(
                    [*gate_command(),
                     "--kernel", str(targets["kernel"]),
                     "--host", str(targets["host"]), "--http", str(helper),
                     "--agent", str(targets["agent"]),
                     "--lifecycle", str(targets["lifecycle"]),
                     "--out", str(out), "--timeout", str(GATE_TIMEOUT)],
                    capture_output=True, text=True, check=False,
                    timeout=GATE_OUTER_TIMEOUT,
                )
                self.assertNotEqual(0, probe.returncode, "hung HTTP gate passed")
                manifest = out / "manifest.json"
                self.assertTrue(manifest.is_file(), probe.stdout + probe.stderr)
                evidence = json.loads(manifest.read_text())
                self.agent_evidence(evidence)
                self.assertEqual(0, evidence["results"]["kernel"]["status"])
                self.assertEqual(0, evidence["results"]["host"]["status"])
                self.assertEqual("timeout", evidence["results"]["http"]["status"])
                self.assertEqual(0, evidence["results"]["agent"]["status"])
                self.assertEqual(0, evidence["results"]["lifecycle"]["status"])
                self.assertIn("test/native_http_test.ml", evidence["sources"])
                self.assertIn("test/native_http_test.mli", evidence["sources"])
                self.assertIn("package/tls/ca.pem", evidence["sources"])
                self.assertIn("package/tls/server.key", evidence["sources"])
                self.assertTrue(receipt.is_file(), "HTTP target never became ready")
                for text in receipt.read_text().split():
                    self.assertFalse(running(int(text)), "HTTP gate leaked its group")
            finally:
                await_fixtures(receipt)

    def test_agent_gate_hang(self):
        # Independent wall time owns a hung agent target and its ignoring child.
        with tempfile.TemporaryDirectory(prefix="symphony-agent-gate-") as base:
            base = Path(base)
            targets = {name: exit_target(base, name)
                       for name in ("kernel", "host", "http", "lifecycle")}
            directory = base / "agent"
            directory.mkdir()
            environment = directory / "environment.json"
            finish = (
                "import json\n"
                f"Path({str(environment)!r}).write_text(json.dumps("
                f"{{name: os.environ.get(name) for name in {NATIVE_ENV_NAMES!r}}}))\n"
                f"time.sleep({FIXTURE_LIFETIME})"
            )
            helper, receipt = group_fixture(directory, finish, admission=0)
            out = base / "evidence"
            try:
                probe = subprocess.run(
                    [*gate_command(),
                     "--kernel", str(targets["kernel"]), "--host", str(targets["host"]),
                     "--http", str(targets["http"]), "--agent", str(helper),
                     "--lifecycle", str(targets["lifecycle"]),
                     "--out", str(out), "--timeout", str(GATE_TIMEOUT)],
                    capture_output=True, text=True, check=False, timeout=GATE_OUTER_TIMEOUT,
                )
                self.assertNotEqual(0, probe.returncode, "hung agent gate passed")
                manifest = out / "manifest.json"
                self.assertTrue(manifest.is_file(), probe.stdout + probe.stderr)
                evidence = json.loads(manifest.read_text())
                self.agent_evidence(evidence)
                for name in ("kernel", "host", "http", "lifecycle"):
                    self.assertEqual(0, evidence["results"][name]["status"])
                self.assertEqual("timeout", evidence["results"]["agent"]["status"])
                self.assertLess(evidence["results"]["agent"]["seconds"], GATE_OUTER_TIMEOUT)
                self.assertTrue(environment.is_file(), "agent never observed its native fixture bindings")
                self.assertEqual(evidence["binaries"]["agent"]["environment"],
                                 json.loads(environment.read_text()))
                self.assertTrue(receipt.is_file(), "agent target never became ready")
                pids = [int(text) for text in receipt.read_text().split()]
                self.assertEqual(2, len(pids))
                with self.assertRaises(ProcessLookupError, msg="agent root was not reaped"):
                    os.kill(pids[0], 0)
                for pid in pids:
                    self.assertFalse(running(pid), "agent gate leaked its group")
            finally:
                await_fixtures(receipt)

    def test_lifecycle_gate_hang(self):
        # The process-edge tests need wall-time custody independent of their clocks.
        with tempfile.TemporaryDirectory(prefix="symphony-lifecycle-gate-") as base:
            base = Path(base)
            targets = {name: exit_target(base, name)
                       for name in ("kernel", "host", "http", "agent")}
            directory = base / "lifecycle"
            directory.mkdir()
            helper, receipt = group_fixture(
                directory, f"time.sleep({FIXTURE_LIFETIME})", admission=0
            )
            out = base / "evidence"
            try:
                probe = subprocess.run(
                    [*gate_command(), "--kernel", str(targets["kernel"]),
                     "--host", str(targets["host"]), "--http", str(targets["http"]),
                     "--agent", str(targets["agent"]), "--lifecycle", str(helper),
                     "--out", str(out), "--timeout", str(GATE_TIMEOUT)],
                    capture_output=True, text=True, check=False, timeout=GATE_OUTER_TIMEOUT,
                )
                self.assertNotEqual(0, probe.returncode, "hung lifecycle gate passed")
                manifest = out / "manifest.json"
                self.assertTrue(manifest.is_file(), probe.stdout + probe.stderr)
                evidence = json.loads(manifest.read_text())
                self.agent_evidence(evidence)
                for name in ("kernel", "host", "http", "agent"):
                    self.assertEqual(0, evidence["results"][name]["status"])
                self.assertEqual("timeout", evidence["results"]["lifecycle"]["status"])
                self.assertLess(evidence["results"]["lifecycle"]["seconds"], GATE_OUTER_TIMEOUT)
                self.assertTrue(receipt.is_file(), "lifecycle target never became ready")
                pids = [int(text) for text in receipt.read_text().split()]
                self.assertEqual(2, len(pids))
                with self.assertRaises(ProcessLookupError, msg="lifecycle root was not reaped"):
                    os.kill(pids[0], 0)
                for pid in pids:
                    self.assertFalse(running(pid), "lifecycle gate leaked its group")
            finally:
                await_fixtures(receipt)

    def test_required_targets(self):
        for missing in ("agent", "lifecycle"):
            with self.subTest(target=missing), tempfile.TemporaryDirectory(
                prefix="symphony-required-target-"
            ) as base:
                base = Path(base)
                command = gate_command()
                for name in ("kernel", "host", "http", "agent", "lifecycle"):
                    if name != missing:
                        command.extend(["--" + name, "missing"])
                probe = subprocess.run(
                    [*command, "--out", str(base)],
                    capture_output=True, text=True, check=False, timeout=READY_TIMEOUT,
                )
                self.assertEqual(2, probe.returncode)
                self.assertTrue(probe.stderr.splitlines()[-1].endswith(": --" + missing),
                                probe.stderr)
                self.assertFalse((base / "manifest.json").exists(),
                                 "incomplete target set produced evidence")

    def test_exec_signals(self):
        with tempfile.TemporaryDirectory(prefix="symphony-watchdog-signals-") as base:
            base = Path(base)
            source = base / "signals.c"
            helper = base / "signals"
            source.write_text(
                "#include <signal.h>\n"
                "int main(void) {\n"
                "    int signals[] = { SIGPIPE,\n"
                "#ifdef SIGXFZ\n"
                "        SIGXFZ,\n"
                "#endif\n"
                "#ifdef SIGXFSZ\n"
                "        SIGXFSZ,\n"
                "#endif\n"
                "    };\n"
                "    for (unsigned i = 0; i < sizeof(signals)/sizeof(signals[0]); ++i) {\n"
                "        struct sigaction action;\n"
                "        if (sigaction(signals[i], 0, &action) != 0) return 1;\n"
                "        if (action.sa_handler != SIG_DFL) return 2;\n"
                "    }\n"
                "    return 0;\n"
                "}\n"
            )
            subprocess.run(["cc", str(source), "-o", str(helper)], check=True,
                           capture_output=True, timeout=READY_TIMEOUT)
            outcome = native_check.execute(helper, base / "run.log", READY_TIMEOUT)
            self.assertEqual(0, outcome["status"],
                             "bootstrap changed the native target's signal defaults")

    def test_normal_no_children(self):
        with tempfile.TemporaryDirectory(prefix="symphony-watchdog-empty-") as base:
            base = Path(base)
            helper = base / "helper"
            helper.write_text(f"#!{sys.executable}\n")
            helper.chmod(0o700)
            outcome = native_check.execute(helper, base / "run.log", READY_TIMEOUT)
            self.assertEqual(0, outcome["status"])

    def test_retained_streams(self):
        with tempfile.TemporaryDirectory(prefix="symphony-watchdog-streams-") as base:
            base = Path(base)
            helper = base / "helper"
            first = b"stdout-first\x00\xff\n"
            last = b"stdout-last\x00\xfe\n"
            stderr = b"stderr-middle\x00\xfd\n"
            stdout = first + last
            helper.write_text(
                f"#!{sys.executable}\n"
                "import sys\n"
                f"sys.stdout.buffer.write({first!r})\n"
                "sys.stdout.buffer.flush()\n"
                f"sys.stderr.buffer.write({stderr!r})\n"
                "sys.stderr.buffer.flush()\n"
                f"sys.stdout.buffer.write({last!r})\n"
                "sys.stdout.buffer.flush()\n"
            )
            helper.chmod(0o700)
            log = base / "target.log"
            outcome = native_check.execute(helper, log, READY_TIMEOUT)
            self.assertEqual(0, outcome["status"])
            path = log.with_suffix(".ownership.json")
            ownership = json.loads(path.read_text())
            self.assertTrue(ownership["reaped"])
            self.assertTrue(ownership["closed"])
            self.assertEqual([], ownership["failures"])
            for stream, expected in (("stdout", stdout), ("stderr", stderr)):
                with self.subTest(stream=stream):
                    retained = log.with_suffix(f".{stream}.bin")
                    self.assertEqual(retained.name, ownership[stream + "_file"])
                    self.assertEqual(len(expected), ownership[stream + "_bytes"])
                    self.assertEqual(hashlib.sha256(expected).hexdigest(),
                                     ownership[stream + "_sha256"])
                    self.assertEqual(expected, retained.read_bytes())
            self.assertEqual(stdout + stderr, log.read_bytes(),
                             "combined log must be deterministic stdout then stderr")
            self.assertEqual(path.name, outcome["ownership"]["path"])
            self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(),
                             outcome["ownership"]["sha256"])

    def test_late_retention_signal(self):
        with tempfile.TemporaryDirectory(prefix="symphony-watchdog-retention-") as base:
            base = Path(base)
            helper = base / "helper"
            pid_file = base / "leader.pid"
            stdout = b"retained-stdout\x00\xff\n"
            stderr = b"retained-stderr\x00\xfe\n"
            helper.write_text(
                f"#!{sys.executable}\n"
                "import os, sys\n"
                "from pathlib import Path\n"
                f"Path({str(pid_file)!r}).write_text(str(os.getpid()))\n"
                f"sys.stdout.buffer.write({stdout!r})\n"
                "sys.stdout.buffer.flush()\n"
                f"sys.stderr.buffer.write({stderr!r})\n"
                "sys.stderr.buffer.flush()\n"
            )
            helper.chmod(0o700)
            log = base / "target.log"
            runner_file = base / "runner.py"
            runner_file.write_text(
                "import os, signal, sys\n"
                "from pathlib import Path\n"
                "sys.dont_write_bytecode = True\n"
                f"sys.path.insert(0, {str(Path(native_check.__file__).parent)!r})\n"
                "import native_check\n"
                "write = native_check._write_bytes\n"
                "sent = False\n"
                "def retain(path, data):\n"
                "    global sent\n"
                "    write(path, data)\n"
                "    if path.name == 'target.stdout.bin' and not sent:\n"
                "        sent = True\n"
                "        print('retention-signal', flush=True)\n"
                "        os.kill(os.getpid(), signal.SIGTERM)\n"
                "native_check._write_bytes = retain\n"
                "try:\n"
                f"    native_check.execute(Path({str(helper)!r}), "
                f"Path({str(log)!r}), {READY_TIMEOUT})\n"
                "except SystemExit as error:\n"
                "    print(f'retention-exit:{error.code}', flush=True)\n"
                "    raise\n"
            )
            optimize = ["-" + "O" * sys.flags.optimize] if sys.flags.optimize else []
            with native_check.Process(
                    [sys.executable, *optimize, str(runner_file)], base, dict(os.environ),
                    native_check.OUTPUT_LIMIT, time.monotonic() + INTERRUPT_TIMEOUT, None) as owner:
                status = owner.join(INTERRUPT_TIMEOUT)
            captured = owner.snapshot()
            self.assertIn(b"retention-signal\n", captured["stdout"])
            self.assertFalse(running(int(pid_file.read_text())), "native leader remains alive")
            with self.subTest(phase="exit"):
                exit_code = native_check.SIGNAL_EXIT_BASE + signal.SIGTERM
                self.assertEqual(exit_code, status, captured["stderr"][-2048:])
                self.assertIn(f"retention-exit:{exit_code}\n".encode(), captured["stdout"])
                self.assertEqual(b"", captured["stderr"])
            for stream, expected in (("stdout", stdout), ("stderr", stderr)):
                with self.subTest(stream=stream):
                    retained = log.with_suffix(f".{stream}.bin")
                    self.assertTrue(retained.is_file(), "signal interrupted stream retention")
                    self.assertEqual(expected, retained.read_bytes())
            with self.subTest(phase="combined"):
                self.assertTrue(log.is_file(), "signal interrupted combined log retention")
                self.assertEqual(stdout + stderr, log.read_bytes())
            with self.subTest(phase="ownership"):
                path = log.with_suffix(".ownership.json")
                self.assertTrue(path.is_file(), "signal interrupted ownership retention")
                ownership = json.loads(path.read_text())
                self.assertTrue(ownership["reaped"])
                self.assertTrue(ownership["closed"])
                self.assertEqual(["stderr", "stdout"], ownership["eof"])
                self.assertEqual(0, ownership["returncode"])
                self.assertEqual([], ownership["failures"])
                self.assertFalse(running(ownership["pid"]))
                self.assertFalse(running(ownership["guard_pid"]))
                for stream, expected in (("stdout", stdout), ("stderr", stderr)):
                    self.assertEqual(log.with_suffix(f".{stream}.bin").name,
                                     ownership[stream + "_file"])
                    self.assertEqual(len(expected), ownership[stream + "_bytes"])
                    self.assertEqual(hashlib.sha256(expected).hexdigest(),
                                     ownership[stream + "_sha256"])

    def test_normal_closes_group(self):
        with tempfile.TemporaryDirectory(prefix="symphony-watchdog-normal-") as base:
            base = Path(base)
            helper, receipt = group_fixture(base, "os._exit(0)", admission=0)
            try:
                outcome = native_check.execute(helper, base / "run.log", READY_TIMEOUT)
                self.assertEqual(0, outcome["status"])
                self.assertTrue(receipt.is_file(), "helper never became ready")
                for text in receipt.read_text().split():
                    self.assertFalse(running(int(text)),
                                     "normal leader exit left an owned descendant alive")
            finally:
                await_fixtures(receipt)

    def interrupt_group(self, requested, stage):
        with tempfile.TemporaryDirectory(prefix="symphony-watchdog-interrupt-") as base:
            base = Path(base)
            helper, receipt = group_fixture(base, f"time.sleep({FIXTURE_LIFETIME})", admission=0)
            runner_file = base / "runner.py"
            admission = base / "admission"
            release = base / "release"
            signals = base / "signals.jsonl"
            audit = ""
            if stage is Stage.ADMISSION:
                # Public audit observation pauses real Popen before OS launch.
                # It does not inject the post-fork/pre-return instruction window.
                audit = (
                    "import json, time\n"
                    "def audit(event, args):\n"
                    "    if event == 'subprocess.Popen':\n"
                    f"        Path({str(admission)!r}).write_text('admitting')\n"
                    f"        deadline = time.monotonic() + {READY_TIMEOUT}\n"
                    f"        while not Path({str(release)!r}).is_file():\n"
                    "            if time.monotonic() >= deadline:\n"
                    "                raise RuntimeError('admission gate timed out')\n"
                    "            time.sleep(0.01)\n"
                    "    elif event == 'os.killpg':\n"
                    f"        with Path({str(signals)!r}).open('a') as output:\n"
                    "            output.write(json.dumps(list(args)) + '\\n')\n"
                    "sys.addaudithook(audit)\n"
                )
            runner_file.write_text(
                "import sys\n"
                "from pathlib import Path\n"
                "sys.dont_write_bytecode = True\n"
                f"sys.path.insert(0, {str(Path(native_check.__file__).parent)!r})\n"
                "import native_check\n"
                f"{audit}"
                "try:\n"
                f"    native_check.execute(Path({str(helper)!r}), "
                f"Path({str(base / 'run.log')!r}), {FIXTURE_LIFETIME})\n"
                "except native_check.Terminated:\n"
                "    print('Terminated', file=sys.stderr)\n"
                "    raise\n"
            )
            runner = subprocess.Popen(
                [sys.executable, str(runner_file)],
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                start_new_session=True,
            )
            try:
                ready = admission if stage is Stage.ADMISSION else receipt
                deadline = time.monotonic() + READY_TIMEOUT
                while not ready.is_file() and time.monotonic() < deadline:
                    time.sleep(0.01)
                self.assertTrue(ready.is_file(), "fixture never reached its selected stage")
                os.kill(runner.pid, requested)
                if stage is Stage.ADMISSION:
                    release.write_text("continue")
                stdout, stderr = runner.communicate(timeout=INTERRUPT_TIMEOUT)
                self.assertNotEqual(0, runner.returncode)
                primary = "KeyboardInterrupt" if requested == signal.SIGINT else "Terminated"
                self.assertIn(primary, stdout + stderr,
                              "runner lost its primary interruption")
                ownership_path = (base / "run.log").with_suffix(".ownership.json")
                self.assertTrue(ownership_path.is_file(),
                                "interruption lost the persisted ownership receipt")
                ownership = json.loads(ownership_path.read_text())
                self.assertTrue(ownership["reaped"], "persisted receipt lacks leader reap")
                self.assertTrue(ownership["closed"], "persisted receipt lacks owner closure")
                for stream in ("stdout", "stderr"):
                    retained = (base / "run.log").with_suffix(f".{stream}.bin")
                    self.assertEqual(retained.name, ownership[stream + "_file"])
                    self.assertEqual(0, ownership[stream + "_bytes"])
                    self.assertEqual(hashlib.sha256(b"").hexdigest(),
                                     ownership[stream + "_sha256"])
                    self.assertEqual(b"", retained.read_bytes())
                self.assertEqual(b"", (base / "run.log").read_bytes())
                if stage is Stage.ADMISSION:
                    self.assertTrue(signals.is_file(), "pending signal skipped admitted cleanup")
                    trace = [json.loads(line) for line in signals.read_text().splitlines()]
                    self.assertEqual(2, len(trace))
                    self.assertEqual([signal.SIGTERM, signal.SIGKILL],
                                     [requested for _, requested in trace])
                    self.assertEqual(trace[0][0], trace[1][0])
                    self.assertFalse(running(trace[0][0]), "admitted root was not reaped")
                else:
                    for text in receipt.read_text().split():
                        self.assertFalse(running(int(text)),
                                         "handled signal left the watchdog's owned group alive")
            finally:
                if runner.poll() is None:
                    runner.kill()
                runner.communicate(timeout=INTERRUPT_TIMEOUT)
                await_fixtures(receipt)

    def test_signals_close_group(self):
        for requested in (signal.SIGINT, signal.SIGTERM):
            with self.subTest(signal=requested):
                self.interrupt_group(requested, Stage.HELD)

    def test_admission_signal(self):
        for requested in (signal.SIGINT, signal.SIGTERM):
            with self.subTest(signal=requested):
                self.interrupt_group(requested, Stage.ADMISSION)

    def test_term_leader_child(self):
        with tempfile.TemporaryDirectory(prefix="symphony-watchdog-") as base:
            base = Path(base)
            helper, receipt = group_fixture(
                base, f"time.sleep({FIXTURE_LIFETIME})", admission=0
            )
            try:
                outcome = native_check.execute(helper, base / "run.log", GATE_TIMEOUT)
                self.assertEqual("timeout", outcome["status"])
                self.assertTrue(receipt.is_file(), "helper did not publish its child")
                for text in receipt.read_text().split():
                    self.assertFalse(
                        running(int(text)),
                        "TERM exited the leader but watchdog left its ignoring child alive",
                    )
            finally:
                await_fixtures(receipt)


if __name__ == "__main__":
    unittest.main()
