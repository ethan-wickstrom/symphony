"""Real-process controls for the native watchdog's retained group identity."""

import os
from enum import Enum
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


def group_fixture(base, finish):
    helper = base / "helper"
    receipt = base / "group.pid"
    helper.write_text(
        f"#!{sys.executable}\n"
        "import os, signal, time\n"
        "from pathlib import Path\n"
        f"receipt = Path({str(receipt)!r})\n"
        f"ready = Path({str(base / 'ready')!r})\n"
        "signal.signal(signal.SIGTERM, lambda *_: os._exit(0))\n"
        "child = os.fork()\n"
        "if child == 0:\n"
        "    signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
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


class NativeWatchdogTest(unittest.TestCase):
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

    def test_normal_closes_group(self):
        with tempfile.TemporaryDirectory(prefix="symphony-watchdog-normal-") as base:
            base = Path(base)
            helper, receipt = group_fixture(base, "os._exit(0)")
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
            helper, receipt = group_fixture(base, f"time.sleep({FIXTURE_LIFETIME})")
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
            child_file = base / "child.pid"
            helper = base / "helper"
            helper.write_text(
                f"#!{sys.executable}\n"
                "import os, signal, time\n"
                "from pathlib import Path\n"
                f"receipt = Path({str(child_file)!r})\n"
                "signal.signal(signal.SIGTERM, lambda *_: os._exit(0))\n"
                "child = os.fork()\n"
                "if child == 0:\n"
                "    signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
                "    receipt.write_text(str(os.getpid()))\n"
                "    time.sleep(20)\n"
                "    os._exit(0)\n"
                "time.sleep(20)\n"
            )
            helper.chmod(0o700)
            child = None
            try:
                outcome = native_check.execute(helper, base / "run.log", 1)
                self.assertEqual("timeout", outcome["status"])
                self.assertTrue(child_file.is_file(), "helper did not publish its child")
                child = int(child_file.read_text())
                self.assertFalse(
                    running(child),
                    "TERM exited the leader but watchdog left its ignoring child alive",
                )
            finally:
                await_fixtures(child_file)


if __name__ == "__main__":
    unittest.main()
