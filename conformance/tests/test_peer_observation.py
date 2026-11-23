import base64
from enum import Enum
import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

from symphony_conformance import runner
from symphony_conformance.driver.process import Process
from symphony_conformance.judge import judge


class Stage(Enum):
    INITIAL = "initial"
    SECOND_TURN = "second-turn"


class PeerObservationTest(unittest.TestCase):
    def test_malformed_peer_json(self):
        self._run(b"{\n")

    def test_nonobject_peer_frame(self):
        self._run(b"[]\n")

    def test_missing_turn_id(self):
        self._run(b'{"method":"turn/start"}\n', Stage.SECOND_TURN)

    def _run(self, raw_frame, stage=Stage.INITIAL):
        processes = []
        script = """
from pathlib import Path
import sys
from symphony_conformance import control
from symphony_conformance.assets import decode

class InvalidRpc(control.Rpc):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self._turns = 0

    def _write(self, _frame):
        if sys.argv[3] == "second-turn":
            if _frame.get("method") != "turn/start":
                return super()._write(_frame)
            self._turns += 1
            if self._turns != 2:
                return super()._write(_frame)
        # Send candidate bytes through the real peer's stdin and observer.
        self._process.write(Path(sys.argv[2]).read_bytes())

control.Rpc = InvalidRpc
path = Path(sys.argv[1])
control.Control(decode(path.read_bytes()), path).run()
"""

        def process(*args, **kwargs):
            value = Process(*args, **kwargs)
            processes.append(value)
            return value

        with tempfile.TemporaryDirectory() as directory:
            bundle = Path(directory) / "evidence"
            frame_path = Path(directory) / "frame.bin"
            frame_path.write_bytes(raw_frame)

            def launch(_profile, _candidate, _workflow, _ca, plan):
                optimization = ["-" + "O" * sys.flags.optimize] if sys.flags.optimize else []
                return [sys.executable, *optimization, "-c", script, str(plan), str(frame_path), stage.value]

            with patch.object(runner.profiles, "launch", side_effect=launch), \
                    patch.object(runner, "Process", side_effect=process):
                runner.run(bundle, "scripted")

            manifest = json.loads((bundle / "manifest.json").read_text())
            receipt = json.loads((bundle / "process.json").read_text())
            rows = [json.loads(line) for line in (bundle / "events.jsonl").read_text().splitlines()]
            snapshot = processes[0].snapshot()
            report = judge(bundle)

            # The invalid frame remains candidate evidence, with real peer closure.
            clients = [row for row in rows if row["kind"] == "peer.client"]
            invalid = [row for row in clients
                       if base64.b64decode(row["data"]["frame"], validate=True) == raw_frame]
            self.assertEqual(len(invalid), 1)
            self.assertEqual(clients[-1], invalid[0])
            self.assertEqual(len(clients), 1 if stage is Stage.INITIAL else 6)
            peers = [row for row in rows if row["kind"] == "peer.started"]
            self.assertEqual(len(peers), 1)
            self.assertEqual(sum(row["kind"] == "peer.error" for row in rows), 1)
            self.assertEqual(sum(row["kind"] == "peer.closed" for row in rows), 1)
            self.assertTrue(snapshot["closed"])
            self.assertTrue(snapshot["reaped"])
            self.assertTrue(receipt["closed"])
            self.assertTrue(receipt["reaped"])
            self.assertNotEqual(snapshot["returncode"], 0)
            self.assertEqual(snapshot["eof"], ("stderr", "stdout"))
            self.assertEqual(snapshot["failures"], ())
            for pid in (snapshot["pid"], snapshot["guard_pid"], peers[0]["data"]["pid"]):
                with self.assertRaises(ProcessLookupError):
                    os.kill(pid, 0)
            closures = [row["data"] for row in rows if row["kind"] == "capture.closed"]
            self.assertEqual(len(closures), 3)
            self.assertTrue(all(value["status"] == "ok" for value in closures))

            for stream in ("stdout", "stderr"):
                raw = (bundle / (stream + ".bin")).read_bytes()
                chunks = [base64.b64decode(row["data"]["data_b64"], validate=True)
                          for row in rows if row["kind"] == "capture." + stream]
                self.assertEqual(b"".join(chunks), raw)
                self.assertEqual(snapshot[stream], raw)
                self.assertEqual(manifest["files"][stream + ".bin"],
                                 {"bytes": len(raw), "sha256": hashlib.sha256(raw).hexdigest()})

            protocol = next(item for item in report["case"]["assertions"]
                            if item["id"] == "protocol.schema")
            self.assertEqual(protocol["status"], "fail")
            self.assertIn(invalid[0]["seq"], protocol["evidence_seq"])
            self.assertEqual(report["case"]["status"], "fail")
            self.assertEqual(report["harness"], {"status": "pass", "errors": []})
            self.assertTrue(manifest["completed"])
            self.assertEqual(manifest["harness_errors"], [])
            failures = [row for row in rows if row["kind"] == "candidate.execution_failure"]
            self.assertEqual(len(failures), 1)
            self.assertEqual(failures[0]["data"]["error_type"], "CalledProcessError")
            self.assertEqual(failures[0]["data"]["returncode"], snapshot["returncode"])
            for operation in ("observe", "join", "reap"):
                waits = [row for row in rows if row["kind"] == "candidate.wait"
                         and row["data"].get("operation") == operation]
                self.assertEqual(len(waits), 1)
                self.assertEqual(waits[0]["data"]["status"], snapshot["returncode"])


if __name__ == "__main__":
    unittest.main()
