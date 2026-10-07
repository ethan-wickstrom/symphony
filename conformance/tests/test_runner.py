import json
from enum import Enum
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from symphony_conformance import runner
from symphony_conformance.driver.journal import Journal
from symphony_conformance.driver.process import Process
from symphony_conformance.driver.tracker import Tracker


class Cleanup(Enum):
    CLEAN = "clean"
    FAIL = "fail"


class Stage(Enum):
    EXECUTE = "execute"
    CLOSE = "close"


class RunnerTest(unittest.TestCase):
    def test_keyboard_interrupt(self):
        self._cancel(KeyboardInterrupt("host interrupted"))

    def test_exit_cleanup_failures(self):
        self._cancel(SystemExit(17), Cleanup.FAIL)

    def test_cleanup_keyboard_interrupt(self):
        self._cancel(KeyboardInterrupt("cleanup interrupted"), stage=Stage.CLOSE)

    def _cancel(self, cancellation, cleanup=Cleanup.CLEAN, stage=Stage.EXECUTE):
        processes = []
        trackers = []
        journals = []
        real_seal = runner.seal

        class CancelProcess(Process):
            def __init__(self, *args, **kwargs):
                super().__init__(*args, **kwargs)
                processes.append(self)

            def wait_for(self, predicate, timeout):
                if stage is Stage.CLOSE:
                    raise RuntimeError("injected execution failure")
                raise cancellation

            def close(self):
                super().close()
                if stage is Stage.CLOSE:
                    raise cancellation
                if cleanup is Cleanup.FAIL:
                    raise RuntimeError("injected process close failure")

        class ClosingTracker(Tracker):
            def __init__(self, *args, **kwargs):
                super().__init__(*args, **kwargs)
                trackers.append(self)

            def close(self):
                super().close()
                if cleanup is Cleanup.FAIL:
                    raise RuntimeError("injected provider close failure")

        class ClosingJournal(Journal):
            def __init__(self, *args, **kwargs):
                super().__init__(*args, **kwargs)
                journals.append(self)

            def close(self):
                super().close()
                if cleanup is Cleanup.FAIL:
                    raise RuntimeError("injected journal close failure")

        def seal(*args, **kwargs):
            value = real_seal(*args, **kwargs)
            if cleanup is Cleanup.FAIL:
                raise RuntimeError("injected seal failure: " + "x" * (64 * 1024))
            return value

        with tempfile.TemporaryDirectory() as directory:
            bundle = Path(directory) / "evidence"
            with patch.object(runner, "Process", CancelProcess), patch.object(runner, "Tracker", ClosingTracker), patch.object(runner, "Journal", ClosingJournal), patch.object(runner, "seal", seal):
                with self.assertRaises(type(cancellation)) as stopped:
                    runner.run(bundle, "scripted")
            self.assertIs(stopped.exception, cancellation)
            if isinstance(cancellation, SystemExit):
                self.assertEqual(stopped.exception.code, 17)
            manifest = json.loads((bundle / "manifest.json").read_text())
            self.assertFalse(manifest["completed"])
            self.assertTrue(any(type(cancellation).__name__ in error for error in manifest["harness_errors"]))
            if stage is Stage.CLOSE:
                self.assertTrue(any("injected execution failure" in error for error in manifest["harness_errors"]))
            self.assertTrue(processes[0].snapshot()["closed"])
            self.assertTrue(processes[0].snapshot()["reaped"])
            receipt = json.loads((bundle / "process.json").read_text())
            self.assertTrue(receipt["closed"])
            self.assertTrue(receipt["reaped"])
            self.assertEqual((bundle / "stdout.bin").read_bytes(), processes[0].snapshot()["stdout"])
            self.assertEqual((bundle / "stderr.bin").read_bytes(), processes[0].snapshot()["stderr"])
            rows = [json.loads(line) for line in (bundle / "events.jsonl").read_text().splitlines()]
            self.assertEqual(sum(row["kind"] == "provider.closed" for row in rows), 1)
            self.assertEqual(sum(row["kind"] == "collector.closed" for row in rows), 1)
            self.assertEqual(trackers[0].errors(), [])
            self.assertTrue(journals[0]._file.closed)
            if cleanup is Cleanup.FAIL:
                for stage in ("process", "provider", "journal"):
                    self.assertTrue(any("injected " + stage + " close failure" in error
                                        for error in manifest["harness_errors"]))
                notes = getattr(cancellation, "__notes__", ())
                self.assertTrue(any("injected seal failure" in note for note in notes))
                self.assertLess(len("\n".join(notes)), 16 * 1024)

    def test_retained_receipt_cleanup(self):
        processes = []
        trackers = []

        class BrokenReceipt(Journal):
            def emit(self, kind, data, origin="executor"):
                if kind == "workspace.retained":
                    raise RuntimeError("injected recorder failure")
                return super().emit(kind, data, origin)

        def process(*args, **kwargs):
            value = Process(*args, **kwargs)
            processes.append(value)
            return value

        def tracker(*args, **kwargs):
            value = Tracker(*args, **kwargs)
            trackers.append(value)
            return value

        with tempfile.TemporaryDirectory() as directory:
            with patch.object(runner, "Journal", BrokenReceipt), patch.object(runner, "Process", process), patch.object(runner, "Tracker", tracker):
                bundle = runner.run(Path(directory) / "evidence", "scripted", fault="missing-cleanup")
            manifest = json.loads((bundle / "manifest.json").read_text())
            self.assertTrue(any("injected recorder failure" in value for value in manifest["harness_errors"]))
            self.assertTrue(processes[0].snapshot()["closed"])
            self.assertTrue(processes[0].snapshot()["reaped"])
            rows = [json.loads(line) for line in (bundle / "events.jsonl").read_text().splitlines()]
            self.assertEqual(len([row for row in rows if row["kind"] == "provider.closed"]), 1)
            self.assertEqual(len([row for row in rows if row["kind"] == "collector.closed"]), 1)
            self.assertEqual(trackers[0].errors(), [])


if __name__ == "__main__":
    unittest.main()
