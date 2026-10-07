import base64
import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

from symphony_conformance import runner
from symphony_conformance.driver.journal import MAX_EVENT_BYTES
from symphony_conformance.driver.process import Process
from symphony_conformance.judge import judge


BAD_LINE_BYTES = 900 * 1024


class ObservationTest(unittest.TestCase):
    def test_large_bad_observation(self):
        # An invalid record fits capture but its base64 copy exceeds admission.
        bad_line = b'"' + b"X" * (BAD_LINE_BYTES - 3) + b'"\n'
        self.assertLess(len(bad_line), runner.OUTPUT_LIMIT)
        self.assertGreater(len(base64.b64encode(bad_line[:-1])), MAX_EVENT_BYTES)
        processes = []
        script = """
import os
from pathlib import Path
import sys
from symphony_conformance.assets import decode
from symphony_conformance.control import Control

path = Path(sys.argv[1])
Control(decode(path.read_bytes()), path).run()
payload = b'"' + b"X" * (int(sys.argv[2]) - 3) + b'"\\n'
while payload:
    payload = payload[os.write(sys.stdout.fileno(), payload):]
"""

        def launch(_profile, _candidate, _workflow, _ca, plan):
            optimization = ["-" + "O" * sys.flags.optimize] if sys.flags.optimize else []
            return [sys.executable, *optimization, "-c", script, str(plan), str(BAD_LINE_BYTES)]

        class ObservedProcess(Process):
            def __init__(self, *args, **kwargs):
                super().__init__(*args, **kwargs)
                processes.append(self)

        with tempfile.TemporaryDirectory() as directory:
            bundle = Path(directory) / "evidence"
            with patch.object(runner.profiles, "launch", side_effect=launch), patch.object(runner, "Process", ObservedProcess):
                runner.run(bundle, "scripted")

            manifest = json.loads((bundle / "manifest.json").read_text())
            receipt = json.loads((bundle / "process.json").read_text())
            rows = [json.loads(line) for line in (bundle / "events.jsonl").read_text().splitlines()]
            snapshot = processes[0].snapshot()
            report = judge(bundle)
            self.assertEqual(report["harness"], {"status": "pass", "errors": []})
            self.assertEqual(report["case"]["status"], "pass")
            self.assertTrue(manifest["completed"])
            self.assertEqual(manifest["harness_errors"], [])

            errors = [row for row in rows if row["kind"] == "candidate.observation_error"]
            self.assertEqual(len(errors), 1)
            self.assertEqual(errors[0]["data"], {"stream": "stdout", "error_type": "ValueError"})
            self.assertLess(len(json.dumps(errors[0]).encode()), MAX_EVENT_BYTES)
            self.assertFalse(any(row["kind"] in {"capture.overflow", "candidate.execution_failure"} for row in rows))

            # The diagnostic references retained capture rather than copying it.
            stdout = (bundle / "stdout.bin").read_bytes()
            self.assertTrue(stdout.endswith(bad_line))
            self.assertLess(len(stdout), runner.OUTPUT_LIMIT)
            observations = [row["data"] for row in rows if row["kind"] == "candidate.observation"]
            self.assertEqual([json.loads(line) for line in stdout[:-len(bad_line)].splitlines()], observations)
            for stream in ("stdout", "stderr"):
                raw = (bundle / (stream + ".bin")).read_bytes()
                chunks = [base64.b64decode(row["data"]["data_b64"], validate=True)
                          for row in rows if row["kind"] == "capture." + stream]
                self.assertEqual(b"".join(chunks), raw)
                self.assertEqual(snapshot[stream], raw)
                self.assertEqual(manifest["files"][stream + ".bin"],
                                 {"bytes": len(raw), "sha256": hashlib.sha256(raw).hexdigest()})

            self.assertTrue(snapshot["closed"])
            self.assertTrue(snapshot["reaped"])
            self.assertTrue(receipt["closed"])
            self.assertTrue(receipt["reaped"])
            self.assertEqual(snapshot["returncode"], 0)
            self.assertEqual(snapshot["eof"], ("stderr", "stdout"))
            self.assertEqual(snapshot["failures"], ())
            for pid in (snapshot["pid"], snapshot["guard_pid"]):
                with self.assertRaises(ProcessLookupError):
                    os.kill(pid, 0)
            for operation in ("observe", "join", "reap"):
                waits = [row for row in rows if row["kind"] == "candidate.wait"
                         and row["data"].get("operation") == operation]
                self.assertEqual(len(waits), 1)
                self.assertEqual(waits[0]["data"]["status"], 0)
            closures = [row["data"] for row in rows if row["kind"] == "capture.closed"]
            self.assertEqual(len(closures), 3)
            self.assertTrue(all(value["status"] == "ok" for value in closures))
            self.assertEqual(sum(row["kind"] == "provider.closed" for row in rows), 1)


if __name__ == "__main__":
    unittest.main()
