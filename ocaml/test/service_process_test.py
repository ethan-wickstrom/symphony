"""Actual-child controls for service wrapper cleanup failure receipts."""

import json
import os
from pathlib import Path
import sys
import tempfile
import unittest

import service_cli_check as SERVICE

FIXTURE_LIFETIME = 30
STDOUT = b"retained stdout\n"
STDERR = b"retained stderr\n"


class PrimaryFault(Exception):
    pass


class CleanupReceipt(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="symphony-service-owner-")
        self.root = Path(self.temporary.name)
        self.binary = self.root / "helper"
        self.binary.write_text(
            f"#!{sys.executable}\n"
            "import os, signal, time\n"
            "from pathlib import Path\n"
            "signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
            "Path('leader.pid').write_text(str(os.getpid()))\n"
            f"os.write(1, {STDOUT!r})\n"
            f"os.write(2, {STDERR!r})\n"
            f"time.sleep({FIXTURE_LIFETIME})\n"
        )
        self.binary.chmod(0o700)

    def tearDown(self):
        self.temporary.cleanup()

    def ready(self, process):
        process.wait(lambda: process.output == {"stdout": STDOUT, "stderr": STDERR},
                     "both fixture capture streams")
        return int((self.root / "leader.pid").read_text())

    def receipt(self, pid):
        observed = json.loads((self.root / "ownership.json").read_text())
        self.assertEqual(observed["pid"], pid)
        self.assertTrue(observed["closed"] and observed["reaped"])
        self.assertEqual(observed["failures"], [])
        with self.assertRaises(ProcessLookupError):
            os.kill(pid, 0)
        self.assertEqual((self.root / "stdout.log").read_bytes(), STDOUT)
        self.assertEqual((self.root / "stderr.log").read_bytes(), STDERR)
        self.assertTrue(any(row["kind"] == "candidate.wait" and row.get("operation") == "reap"
                            for row in observed["lifecycle"]))

    def test_missing_marker_path(self):
        # The absent control directory fails marker writes before owner cleanup.
        with self.assertRaises(FileNotFoundError):
            with SERVICE.running(self.binary, self.root, []) as process:
                pid = self.ready(process)
        self.receipt(pid)

    def test_primary_survives_marker(self):
        primary = PrimaryFault("scenario failed")
        with self.assertRaises(PrimaryFault) as raised:
            with SERVICE.running(self.binary, self.root, []) as process:
                pid = self.ready(process)
                raise primary
        self.assertIs(raised.exception, primary)
        self.assertTrue(any("FileNotFoundError" in note for note in primary.__notes__))
        self.receipt(pid)


if __name__ == "__main__":
    unittest.main()
