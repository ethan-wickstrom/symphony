"""Reject invalid calibration configuration before evidence admission."""

from contextlib import redirect_stderr, redirect_stdout
import io
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

from symphony_conformance import cli


class CliTest(unittest.TestCase):
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
