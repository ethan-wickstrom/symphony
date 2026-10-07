"""Execute ownership controls; candidate verdicts belong to the judge."""

import base64
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

from symphony_conformance.driver import capture
from symphony_conformance.driver.process import Custody, Process, Stdin

PROCESS_BUDGET = 8
WAIT_BUDGET = 3
STREAM_BOUND = 128 * 1024
FIXTURE_LIFETIME = 30
ENVIRONMENT = {"PATH": "/usr/bin:/bin", "LC_ALL": "C"}


class PrimaryFault(Exception):
    pass


class CleanupFault(Exception):
    pass


def alive(pid):
    result = capture.run(["/bin/ps", "-o", "stat=", "-p", str(pid)], timeout=WAIT_BUDGET,
                         stdout_limit=1024, stderr_limit=1024, env=ENVIRONMENT)
    if result.returncode not in (0, 1) or result.stderr:
        raise RuntimeError("process-state control failed")
    return bool(result.stdout.strip()) and not result.stdout.strip().startswith(b"Z")


class Ownership(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="symphony-process-control-")
        self.base = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def start(self, text, limit=STREAM_BOUND, emit=None):
        return Process([sys.executable, "-I", "-c", text], self.base, ENVIRONMENT,
                       limit, time.monotonic() + PROCESS_BUDGET, emit)

    def exited(self, owner):
        owner.join(WAIT_BUDGET)

    def _late_cancel(self, number, primary, recorder_error=None):
        source = (
            "import signal, time\n"
            "signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
            "print('ready', flush=True)\n"
            f"time.sleep({FIXTURE_LIFETIME})\n"
        )
        delivered = []

        def cancel(kind, fields):
            if (kind == "group.cleanup" and fields.get("stage") == "signal"
                    and fields.get("signal") == signal.SIGTERM and fields.get("result") == "sent"):
                delivered.append(number)
                os.kill(os.getpid(), number)
                if recorder_error is not None:
                    raise recorder_error

        handler = signal.default_int_handler if number == signal.SIGINT else signal.SIG_DFL
        baseline = signal.signal(number, handler)
        error = None
        try:
            try:
                with self.start(source, emit=cancel) as owner:
                    owner.wait_for(lambda: owner.snapshot()["stdout"] == b"ready\n", WAIT_BUDGET)
                    raise primary
            except BaseException as caught:
                error = caught
        finally:
            signal.signal(number, baseline)

        observed = owner.snapshot()
        self.assertEqual(delivered, [number])
        self.assertTrue(observed["closed"] and observed["reaped"])
        self.assertEqual(observed["eof"], ("stderr", "stdout"))
        self.assertEqual(observed["returncode"], -signal.SIGKILL)
        self.assertEqual(observed["stdout"], b"ready\n")
        self.assertEqual(observed["stderr"], b"")
        kills = [row for row in observed["lifecycle"] if row["kind"] == "group.cleanup"
                 and row.get("stage") == "signal" and row.get("signal") == signal.SIGKILL]
        self.assertEqual(len(kills), 1)
        self.assertEqual(kills[0]["result"], "sent")
        self.assertFalse(alive(observed["pid"]))
        self.assertFalse(alive(observed["guard_pid"]))
        with self.assertRaises(ChildProcessError):
            os.waitpid(observed["pid"], os.WNOHANG)
        self.assertIsNotNone(error)
        self.assertEqual(error._process_snapshot, observed)
        return error

    def test_cleanup_sigterm(self):
        error = self._late_cancel(signal.SIGTERM, PrimaryFault("body details must stay private"))
        self.assertIsInstance(error, SystemExit)
        self.assertEqual(error.code, capture.SIGNAL_EXIT_BASE + signal.SIGTERM)
        notes = getattr(error, "__notes__", ())
        self.assertIn("Process cleanup failed: stage=body class=PrimaryFault", notes)
        self.assertFalse(any("body details" in note for note in notes))

    def test_cleanup_sigint(self):
        error = self._late_cancel(signal.SIGINT, PrimaryFault("body details must stay private"))
        self.assertIsInstance(error, KeyboardInterrupt)
        notes = getattr(error, "__notes__", ())
        self.assertIn("Process cleanup failed: stage=body class=PrimaryFault", notes)
        self.assertFalse(any("body details" in note for note in notes))

    def test_primary_cancel_identity(self):
        primary = KeyboardInterrupt("body cancellation")
        error = self._late_cancel(signal.SIGTERM, primary)
        self.assertIs(error, primary)
        self.assertIn("Process cleanup failed: stage=signal-check class=SystemExit", getattr(error, "__notes__", ()))

    def test_cleanup_cancel_identity(self):
        cancellation = KeyboardInterrupt("recorder cancellation")
        error = self._late_cancel(signal.SIGTERM, PrimaryFault("body details must stay private"), cancellation)
        self.assertIs(error, cancellation)
        notes = getattr(error, "__notes__", ())
        self.assertIn("Process cleanup failed: stage=body class=PrimaryFault", notes)
        self.assertIn("Process cleanup failed: stage=signal-check class=SystemExit", notes)
        failures = error._process_snapshot["failures"]
        self.assertEqual(failures, ({"stage": "term", "class": "KeyboardInterrupt"},))
        recorder = [row for row in error._process_snapshot["lifecycle"]
                    if row["kind"] == "capture.closed" and row.get("stage") == "recorder"]
        self.assertEqual(len(recorder), 1)
        self.assertEqual(recorder[0]["class"], "KeyboardInterrupt")
        self.assertEqual(recorder[0]["result"], "failed")
        self.assertEqual(recorder[0]["status"], "error")
        self.assertFalse(any("body details" in note for note in notes))

    def test_streams_and_journal(self):
        events = []
        source = f"import os; os.write(1, b'O' * {STREAM_BOUND}); os.write(2, b'E' * {STREAM_BOUND})"
        with self.start(source, emit=lambda kind, fields: events.append((kind, fields))) as owner:
            self.exited(owner)
        observed = owner.snapshot()
        self.assertTrue(observed["closed"] and observed["reaped"])
        self.assertEqual(observed["failures"], ())
        self.assertEqual(observed["returncode"], 0)
        for name, expected in (("stdout", b"O"), ("stderr", b"E")):
            chunks = [base64.b64decode(fields["data_b64"]) for kind, fields in events
                      if kind == "capture." + name]
            self.assertEqual(b"".join(chunks), expected * STREAM_BOUND)
            self.assertEqual(observed[name], expected * STREAM_BOUND)
        natural = [fields for kind, fields in events if kind == "candidate.wait"
                   and fields.get("operation") == "observe"]
        self.assertEqual(len(natural), 1)
        self.assertEqual(natural[0]["status"], 0)
        self.assertFalse(natural[0]["reaped"])
        self.assertFalse(any(fields.get("forced") for kind, fields in events if kind == "group.cleanup"))
        self.assertLess(next(index for index, row in enumerate(events)
                             if row[0] == "candidate.wait" and row[1].get("operation") == "observe"),
                        next(index for index, row in enumerate(events) if row[0] == "group.cleanup"))

    def test_normal_exit_closes_group(self):
        receipt = self.base / "child.pid"
        source = (
            "import os, signal, time\n"
            "child = os.fork()\n"
            "if child == 0:\n"
            "    signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
            "    os.close(1); os.close(2)\n"
            f"    time.sleep({FIXTURE_LIFETIME})\n"
            "    os._exit(0)\n"
            f"with open({str(receipt)!r}, 'w') as output: output.write(str(child))\n"
            "os._exit(0)\n"
        )
        with self.start(source) as owner:
            self.exited(owner)
        self.assertFalse(alive(int(receipt.read_text())))
        self.assertFalse(alive(owner.snapshot()["guard_pid"]))
        self.assertEqual(owner.snapshot()["failures"], ())

    def test_join_requires_pipe_eof(self):
        receipt = self.base / "pipe-child.pid"
        source = (
            "import os, time\n"
            "child = os.fork()\n"
            "if child == 0:\n"
            f"    time.sleep({FIXTURE_LIFETIME})\n"
            "    os._exit(0)\n"
            f"with open({str(receipt)!r}, 'w') as output: output.write(str(child))\n"
            "os._exit(0)\n"
        )
        owner = self.start(source)
        try:
            with self.assertRaises(subprocess.TimeoutExpired):
                owner.join(0.2)
            observed = owner.snapshot()
            self.assertEqual(observed["returncode"], 0)
            self.assertFalse(observed["reaped"])
            self.assertFalse(any(row["kind"] == "group.cleanup" for row in observed["lifecycle"]))
            self.assertTrue(alive(int(receipt.read_text())))
        finally:
            owner.close()
        observed = owner.snapshot()
        self.assertTrue(observed["reaped"])
        self.assertFalse(alive(int(receipt.read_text())))
        self.assertTrue(any(row.get("reason") == "open-capture" and row.get("forced")
                            for row in observed["lifecycle"]))

    def test_stdin_eof_and_join(self):
        data = b"first\nsecond\n"
        source = "import os, sys; os.write(1, sys.stdin.buffer.read())"
        with Process([sys.executable, "-I", "-c", source], self.base, ENVIRONMENT,
                     STREAM_BOUND, time.monotonic() + PROCESS_BUDGET,
                     stdin=Stdin.PIPE, stdin_limit=len(data)) as owner:
            owner.write(data)
            owner.close_stdin()
            self.assertEqual(owner.join(WAIT_BUDGET), 0)
            observed = owner.snapshot()
            self.assertEqual(observed["stdout"], data)
            self.assertEqual(observed["eof"], ("stderr", "stdout"))
            self.assertFalse(observed["reaped"])
            self.assertTrue(observed["stdin_closed"])
        self.assertTrue(owner.snapshot()["reaped"])

    def test_nonlifo_cancellation(self):
        baseline = signal.getsignal(signal.SIGTERM)
        source = f"import time; time.sleep({FIXTURE_LIFETIME})"
        first = self.start(source)
        second = self.start(source)
        try:
            first.close()
            self.assertNotEqual(signal.getsignal(signal.SIGTERM), baseline)
            try:
                os.kill(os.getpid(), signal.SIGTERM)
                second.remaining()
            except SystemExit as error:
                second.close()
                self.assertEqual(error.code, capture.SIGNAL_EXIT_BASE + signal.SIGTERM)
            else:
                self.fail("closing the earlier owner lost cancellation of the active owner")
        finally:
            first.close()
            if not second.snapshot()["closed"]:
                second.close()
        self.assertEqual(signal.getsignal(signal.SIGTERM), baseline)

    def test_deferred_handler(self):
        delivered = []
        baseline = signal.signal(signal.SIGTERM, lambda number, _frame: delivered.append(number))
        try:
            with self.start(f"import time; time.sleep({FIXTURE_LIFETIME})") as owner:
                os.kill(os.getpid(), signal.SIGTERM)
                self.assertEqual(delivered, [])
                owner.pump()
                self.assertEqual(delivered, [signal.SIGTERM])
                owner.remaining()
                self.assertEqual(delivered, [signal.SIGTERM])
        finally:
            signal.signal(signal.SIGTERM, baseline)
        self.assertTrue(owner.snapshot()["reaped"])

    def test_child_custody(self):
        source = f"import os, time; print(os.getpgrp(), flush=True); time.sleep({FIXTURE_LIFETIME})"
        with Process([sys.executable, "-I", "-c", source], self.base, ENVIRONMENT,
                     STREAM_BOUND, time.monotonic() + PROCESS_BUDGET,
                     custody=Custody.CHILD) as owner:
            owner.wait_for(lambda: b"\n" in owner.snapshot()["stdout"], WAIT_BUDGET)
            self.assertEqual(int(owner.snapshot()["stdout"]), os.getpgrp())
            self.assertIsNone(owner.snapshot()["guard_pid"])
        observed = owner.snapshot()
        self.assertTrue(observed["reaped"])
        self.assertEqual(observed["custody"], Custody.CHILD.value)
        self.assertFalse(any(row.get("target") == "group" for row in observed["lifecycle"]))

    def test_outer_kills_nested_peer(self):
        peer = f"import signal, time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep({FIXTURE_LIFETIME})"
        source = (
            "import os, signal, sys, time\n"
            "from symphony_conformance.driver.process import Custody, Process\n"
            "signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
            f"with Process([sys.executable, '-I', '-c', {peer!r}], {str(self.base)!r}, dict(os.environ), "
            f"{STREAM_BOUND}, time.monotonic() + {FIXTURE_LIFETIME}, custody=Custody.CHILD) as peer:\n"
            "    pid = peer.snapshot()['pid']\n"
            "    print(pid, os.getpgid(pid), flush=True)\n"
            f"    peer.join({FIXTURE_LIFETIME})\n"
        )
        with self.start(source) as owner:
            owner.wait_for(lambda: b"\n" in owner.snapshot()["stdout"], WAIT_BUDGET)
            nested, group = map(int, owner.snapshot()["stdout"].split())
            self.assertEqual(group, owner.snapshot()["pid"])
            self.assertTrue(alive(nested))
        self.assertFalse(alive(nested))
        self.assertTrue(owner.snapshot()["reaped"])

    def test_independent_budgets(self):
        bound = 1024
        source = f"import os, time; os.write(2, b'E' * {bound + 1}); time.sleep({FIXTURE_LIFETIME})"
        with self.assertRaises(capture.OutputLimit) as raised:
            with Process([sys.executable, "-I", "-c", source], self.base, ENVIRONMENT,
                         {"stdout": STREAM_BOUND, "stderr": bound},
                         time.monotonic() + PROCESS_BUDGET) as owner:
                owner.wait_for(lambda: False, WAIT_BUDGET)
        self.assertTrue(raised.exception._process_snapshot["reaped"])
        self.assertLessEqual(len(raised.exception._process_snapshot["stderr"]), bound)

    def test_signal_targets_leader(self):
        receipt = self.base / "child.pid"
        child_signal = self.base / "child-signaled"
        source = (
            "import os, signal, time\n"
            "reader, writer = os.pipe()\n"
            "child = os.fork()\n"
            "if child == 0:\n"
            "    os.close(reader)\n"
            f"    def received(*_): open({str(child_signal)!r}, 'w').close()\n"
            "    signal.signal(signal.SIGTERM, received)\n"
            "    os.close(1); os.close(2)\n"
            "    os.write(writer, b'R'); os.close(writer)\n"
            f"    time.sleep({FIXTURE_LIFETIME})\n"
            "    os._exit(0)\n"
            "os.close(writer); os.read(reader, 1); os.close(reader)\n"
            f"with open({str(receipt)!r}, 'w') as output: output.write(str(child))\n"
            "def received(*_):\n"
            "    os.write(2, b'leader-term\\n')\n"
            "    os._exit(0)\n"
            "signal.signal(signal.SIGTERM, received)\n"
            "os.write(2, b'ready\\n')\n"
            f"time.sleep({FIXTURE_LIFETIME})\n"
        )
        with self.start(source) as owner:
            owner.wait_for(lambda: b"ready\n" in owner.snapshot()["stderr"], WAIT_BUDGET)
            owner.signal(signal.SIGTERM)
            self.exited(owner)
            self.assertFalse(child_signal.exists())
            self.assertTrue(alive(int(receipt.read_text())))
        self.assertFalse(child_signal.exists())
        self.assertFalse(alive(int(receipt.read_text())))
        sent = [row for row in owner.snapshot()["lifecycle"] if row["kind"] == "candidate.signal"]
        self.assertEqual([row["target"] for row in sent], ["leader"])

    def test_overflow_cleanup(self):
        bound = 1024
        with self.assertRaises(capture.OutputLimit) as raised:
            with self.start(f"import os, time; os.write(2, b'E' * {bound + 1}); time.sleep({FIXTURE_LIFETIME})",
                            limit=bound) as owner:
                owner.wait_for(lambda: False, WAIT_BUDGET)
        observed = raised.exception._process_snapshot
        self.assertTrue(observed["closed"] and observed["reaped"])
        self.assertLessEqual(len(observed["stderr"]), bound)
        self.assertTrue(any(row.get("stage") == "overflow" for row in observed["lifecycle"]))

    def test_closed_pipe_deadline(self):
        source = f"import os, time; os.close(1); os.close(2); time.sleep({FIXTURE_LIFETIME})"
        with self.assertRaises(subprocess.TimeoutExpired) as raised:
            with self.start(source) as owner:
                owner.wait_for(lambda: False, 0.1)
        observed = raised.exception._process_snapshot
        self.assertTrue(observed["closed"] and observed["reaped"])
        self.assertEqual(observed["failures"], ())

    def test_admission_cancellation(self):
        popen = subprocess.Popen

        def admitted(*args, **kwargs):
            child = popen(*args, **kwargs)
            os.kill(os.getpid(), signal.SIGTERM)
            return child

        with patch("symphony_conformance.driver.process.subprocess.Popen", admitted):
            with self.assertRaises(SystemExit) as raised:
                self.start(f"import time; time.sleep({FIXTURE_LIFETIME})")
        self.assertEqual(raised.exception.code, capture.SIGNAL_EXIT_BASE + signal.SIGTERM)
        observed = raised.exception._process_snapshot
        self.assertTrue(observed["closed"] and observed["reaped"])

    def test_record_cleanup_faults(self):
        primary, secondary = PrimaryFault("record failed"), CleanupFault("close failed")
        close = capture.Capture.close

        def broken_record(kind, _fields):
            if kind == "capture.stderr":
                raise primary

        def broken_close(reader):
            return close(reader) + [("selector-close", CleanupFault, secondary, None)]

        with patch.object(capture.Capture, "close", broken_close):
            with self.assertRaises(PrimaryFault) as raised:
                with self.start(f"import os, time; os.write(2, b'R'); time.sleep({FIXTURE_LIFETIME})",
                                emit=broken_record) as owner:
                    owner.wait_for(lambda: False, WAIT_BUDGET)
        self.assertIs(raised.exception, primary)
        observed = primary._process_snapshot
        self.assertTrue(observed["closed"] and observed["reaped"])
        self.assertEqual(observed["stderr"], b"R")
        self.assertTrue(any(row["stage"] == "selector-close" for row in observed["failures"]))
        self.assertTrue(any(row["stage"] == "recorder" for row in observed["failures"]))
        self.assertTrue(any("selector-close" in note for note in primary.__notes__))

    def test_cleanup_defect(self):
        secondary = CleanupFault("close failed")
        close = capture.Capture.close

        def broken_close(reader):
            return close(reader) + [("selector-close", CleanupFault, secondary, None)]

        with patch.object(capture.Capture, "close", broken_close):
            with self.assertRaises(CleanupFault) as raised:
                with self.start("pass") as owner:
                    self.exited(owner)
        self.assertIs(raised.exception, secondary)
        self.assertTrue(secondary._process_snapshot["reaped"])

    def test_direct_admission_cancel(self):
        popen = subprocess.Popen
        children = []

        def admitted(*args, **kwargs):
            child = popen(*args, **kwargs)
            children.append(child)
            os.kill(os.getpid(), signal.SIGTERM)
            return child

        with patch.object(capture.subprocess, "Popen", admitted):
            with self.assertRaises(SystemExit):
                capture.run([sys.executable, "-I", "-c", f"import time; time.sleep({FIXTURE_LIFETIME})"],
                            timeout=WAIT_BUDGET, stdout_limit=1024, stderr_limit=1024, env=ENVIRONMENT)
        self.assertEqual(len(children), 1)
        self.assertIsNotNone(children[0].returncode)
        with self.assertRaises(ChildProcessError):
            os.waitpid(children[0].pid, os.WNOHANG)


if __name__ == "__main__":
    unittest.main()
