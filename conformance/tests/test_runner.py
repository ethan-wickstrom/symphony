import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

from symphony_conformance import runner
from symphony_conformance.driver.journal import Journal
from symphony_conformance.driver.process import Process
from symphony_conformance.driver.tracker import Tracker


class RunnerTest(unittest.TestCase):
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
