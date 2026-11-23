"""Check public configuration rejection and host cancellation."""

from contextlib import redirect_stderr, redirect_stdout
import base64
import hashlib
import io
import json
import os
from pathlib import Path
import signal
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

from symphony_conformance import cli, runner
from symphony_conformance.driver.process import Custody, Process

CLI_BUDGET = 8
ADMISSION_BUDGET = 2
JOIN_BUDGET = 6
ADMITTED = "candidate-admitted"
SEALING = "sealing-after-close"
RESTORING = "restoring-after-seal"
RESTORE_FAILURE = "injected signal restore failure"
NOTE_LIMIT = 16 * 1024
SIGNAL_EXIT_BASE = 128


class CliTest(unittest.TestCase):
    def test_sigterm_exit_status(self):
        script = '''
import sys
from symphony_conformance import cli, runner
from symphony_conformance.driver.process import Custody, Process

output, marker = sys.argv[1:]

def launch(*args, **kwargs):
    # The test's outer GROUP owns the CLI and every nested fixture process.
    owner = Process(*args, **kwargs, custody=Custody.CHILD)
    print(marker, flush=True)
    return owner

runner.Process = launch
sys.argv = ['symphony-conformance', 'run', '--profile', 'scripted', '--output', output]
cli.main()
'''
        flags = ["-" + "O" * min(sys.flags.optimize, 2)] if sys.flags.optimize else []
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            output = root / "evidence"
            with Process([sys.executable, *flags, "-c", script, str(output), ADMITTED],
                         cwd=root, env=dict(os.environ), output_limit=65536,
                         deadline=time.monotonic() + CLI_BUDGET) as command:
                command.wait_for(lambda: (ADMITTED + "\n").encode() in command.snapshot()["stdout"],
                                 ADMISSION_BUDGET)
                command.signal(signal.SIGTERM)
                status = command.join(JOIN_BUDGET)
                captured = command.snapshot()
                self.assertEqual(status, SIGNAL_EXIT_BASE + signal.SIGTERM,
                                 repr(captured["stdout"]) + "\n"
                                 + captured["stderr"].decode("utf-8", errors="replace"))
                self.assertEqual(captured["stdout"], (ADMITTED + "\n").encode())
            manifest = json.loads((output / "manifest.json").read_text())
            self.assertFalse(manifest["completed"])
            self.assertTrue(any("SystemExit" in error for error in manifest["harness_errors"]))
            receipt = json.loads((output / "process.json").read_text())
            self.assertEqual(receipt["custody"], Custody.CHILD.value)
            self.assertTrue(receipt["closed"])
            self.assertTrue(receipt["reaped"])
            self.assertTrue((output / "stdout.bin").is_file())
            self.assertTrue((output / "stderr.bin").is_file())

    def test_sigterm_during_seal(self):
        script = '''
import os
import signal
import sys
from symphony_conformance import cli, runner
from symphony_conformance.driver.process import Custody, Process

output, marker = sys.argv[1:]
owners = []
real_seal = runner.seal

def launch(*args, **kwargs):
    owner = Process(*args, **kwargs, custody=Custody.CHILD)
    owners.append(owner)
    return owner

def seal(*args, **kwargs):
    state = owners[0].snapshot()
    if not state['closed'] or not state['reaped']:
        raise RuntimeError('sealing began before candidate closure')
    # Deliver cancellation after candidate closure, before evidence sealing.
    print(marker, flush=True)
    os.kill(os.getpid(), signal.SIGTERM)
    return real_seal(*args, **kwargs)

runner.Process = launch
runner.seal = seal
sys.argv = ['symphony-conformance', 'run', '--profile', 'scripted', '--output', output]
cli.main()
'''
        flags = ["-" + "O" * min(sys.flags.optimize, 2)] if sys.flags.optimize else []
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            output = root / "evidence"
            with Process([sys.executable, *flags, "-c", script, str(output), SEALING],
                         cwd=root, env=dict(os.environ), output_limit=65536,
                         deadline=time.monotonic() + CLI_BUDGET) as command:
                status = command.join(CLI_BUDGET)
                captured = command.snapshot()
            self.assertEqual(captured["stdout"], (SEALING + "\n").encode(),
                             captured["stderr"][-2048:].decode("utf-8", errors="replace"))
            self.assertTrue((output / "manifest.json").is_file(),
                            "SIGTERM during sealing lost cleanup evidence; status=" + str(status))
            self.assertEqual(status, SIGNAL_EXIT_BASE + signal.SIGTERM)
            self._sealed(output)

    def test_sigterm_restore_failure(self):
        script = '''
import json
import os
from pathlib import Path
import signal
import sys
from symphony_conformance import cli, runner
from symphony_conformance.driver import capture
from symphony_conformance.driver.process import Custody, Process

output, marker, failure = sys.argv[1:]
owners = []
real_signal = capture.signal.signal

def launch(*args, **kwargs):
    owner = Process(*args, **kwargs, custody=Custody.CHILD)
    owners.append(owner)
    return owner

def restore(number, handler):
    current = signal.getsignal(number)
    if number == signal.SIGTERM and handler == signal.SIG_DFL and current == capture.SignalScope._collect:
        state = owners[0].snapshot()
        if not state['closed'] or not state['reaped'] or not (Path(output) / 'manifest.json').is_file():
            raise RuntimeError('restoration began before sealing and candidate closure')
        # Interrupt the final restore while its collector is still installed.
        print(marker, flush=True)
        os.kill(os.getpid(), signal.SIGTERM)
        raise RuntimeError(failure + ': ' + 'x' * (64 * 1024))
    return real_signal(number, handler)

runner.Process = launch
capture.signal.signal = restore
sys.argv = ['symphony-conformance', 'run', '--profile', 'scripted', '--output', output]
try:
    cli.main()
except BaseException as error:
    print(json.dumps({'type': type(error).__name__, 'code': getattr(error, 'code', None),
                      'notes': getattr(error, '__notes__', [])}), file=sys.stderr, flush=True)
    raise
'''
        flags = ["-" + "O" * min(sys.flags.optimize, 2)] if sys.flags.optimize else []
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            output = root / "evidence"
            with Process([sys.executable, *flags, "-c", script, str(output), RESTORING, RESTORE_FAILURE],
                         cwd=root, env=dict(os.environ), output_limit=128 * 1024,
                         deadline=time.monotonic() + CLI_BUDGET) as command:
                status = command.join(CLI_BUDGET)
                captured = command.snapshot()
            self.assertEqual(captured["stdout"], (RESTORING + "\n").encode(),
                             captured["stderr"][-2048:].decode("utf-8", errors="replace"))
            self._sealed(output)
            self.assertEqual(status, SIGNAL_EXIT_BASE + signal.SIGTERM,
                             captured["stderr"][-2048:].decode("utf-8", errors="replace"))
            self.assertLess(len(captured["stderr"]), NOTE_LIMIT)
            diagnostic = json.loads(captured["stderr"])
            self.assertEqual(diagnostic["type"], "SystemExit")
            self.assertEqual(diagnostic["code"], SIGNAL_EXIT_BASE + signal.SIGTERM)
            self.assertTrue(any(RESTORE_FAILURE in note for note in diagnostic["notes"]))
            self.assertLess(len("\n".join(diagnostic["notes"])), NOTE_LIMIT)

    def _sealed(self, output):
        manifest = json.loads((output / "manifest.json").read_text())
        self.assertTrue(manifest["completed"])
        self.assertEqual(manifest["harness_errors"], [])
        receipt = json.loads((output / "process.json").read_text())
        self.assertEqual(receipt["custody"], Custody.CHILD.value)
        self.assertTrue(receipt["closed"])
        self.assertTrue(receipt["reaped"])
        self.assertEqual(receipt["failures"], [])
        self.assertEqual(set(receipt["eof"]), {"stdout", "stderr"})
        rows = [json.loads(line) for line in (output / "events.jsonl").read_text().splitlines()]
        self.assertEqual(sum(row["kind"] == "provider.closed" for row in rows), 1)
        self.assertEqual(sum(row["kind"] == "collector.closed" for row in rows), 1)
        for stream in ("stdout", "stderr"):
            name = stream + ".bin"
            raw = (output / name).read_bytes()
            chunks = [base64.b64decode(row["data"]["data_b64"], validate=True)
                      for row in rows if row["kind"] == "capture." + stream]
            self.assertEqual(raw, b"".join(chunks))
            self.assertEqual(manifest["files"][name]["bytes"], len(raw))
            self.assertEqual(manifest["files"][name]["sha256"], hashlib.sha256(raw).hexdigest())

    def test_keyboard_interrupt(self):
        self._cancel(KeyboardInterrupt("host interrupted"))

    def test_system_exit(self):
        self._cancel(SystemExit(17))

    def _cancel(self, cancellation):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "evidence"
            argv = ["symphony-conformance", "run", "--profile", "scripted", "--output", str(output)]
            stdout = io.StringIO()
            with patch.object(sys, "argv", argv), patch.object(runner.Process, "wait_for", side_effect=cancellation):
                with redirect_stdout(stdout), redirect_stderr(io.StringIO()):
                    with self.assertRaises(type(cancellation)) as stopped:
                        cli.main()
            self.assertIs(stopped.exception, cancellation)
            if isinstance(cancellation, SystemExit):
                self.assertEqual(stopped.exception.code, 17)
            self.assertEqual(stdout.getvalue(), "")
            manifest = json.loads((output / "manifest.json").read_text())
            self.assertFalse(manifest["completed"])
            receipt = json.loads((output / "process.json").read_text())
            self.assertTrue(receipt["closed"])
            self.assertTrue(receipt["reaped"])
            self.assertTrue((output / "stdout.bin").is_file())
            self.assertTrue((output / "stderr.bin").is_file())

    def _reject(self, arguments):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "evidence"
            argv = ["symphony-conformance", "run", "--output", str(output), *arguments]
            with patch.object(sys, "argv", argv), patch.object(cli, "run", return_value=output) as execute:
                with redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
                    with self.assertRaises(SystemExit) as rejection:
                        cli.main()
                self.assertEqual(rejection.exception.code, 2)
                execute.assert_not_called()
            self.assertFalse(output.exists())

    def test_unknown_fault(self):
        self._reject(["--profile", "scripted", "--fault", "not-a-calibration"])

    def test_ocaml_fault(self):
        self._reject(["--profile", "ocaml", "--candidate", "/unused/candidate",
                      "--fault", "new-thread"])


if __name__ == "__main__":
    unittest.main()
