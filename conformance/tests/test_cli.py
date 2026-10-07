"""Check public configuration rejection and host cancellation."""

from contextlib import redirect_stderr, redirect_stdout
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
