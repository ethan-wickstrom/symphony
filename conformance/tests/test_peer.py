"""Peer receipts observe inherited environment and owned marker publication."""

from concurrent.futures import ThreadPoolExecutor
import json
import os
from pathlib import Path
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch

from symphony_conformance import runner
from symphony_conformance.assets import load
from symphony_conformance.judge import judge
from symphony_conformance.peer import _marker

JOIN_TIMEOUT = 5
TRACKER_SECRET_NAME = "LINEAR_API_KEY"
PREFIX_ENV = "SYMPHONY_FIXTURE_SECRET_PREFIX"
SUFFIX_ENV = "SYMPHONY_FIXTURE_SECRET_SUFFIX"
PRIVATE_ENV = "SYMPHONY_FIXTURE_PRIVATE_VALUE"
PRIVATE_VALUE = "unrelated-fixture-value-never-record"


class PeerTest(unittest.TestCase):
    def test_embedded_secret_receipt(self):
        fake = load("corpus/lifecycle.json")["fake_secret"]
        values = {TRACKER_SECRET_NAME: "Bearer " + fake,
                  PREFIX_ENV: "fixture-prefix:" + fake,
                  SUFFIX_ENV: fake + ":fixture-suffix", PRIVATE_ENV: PRIVATE_VALUE}
        receipt, _ = self._receipt(values)
        for name in (TRACKER_SECRET_NAME, PREFIX_ENV, SUFFIX_ENV):
            with self.subTest(name=name):
                self.assertEqual(receipt.get(name), fake)
        self.assertNotIn(PRIVATE_ENV, receipt)
        self.assertNotIn(PRIVATE_VALUE, json.dumps(receipt))

    def test_embedded_secret_verdict(self):
        fake = load("corpus/lifecycle.json")["fake_secret"]
        values = {TRACKER_SECRET_NAME: "Bearer " + fake,
                  PREFIX_ENV: "fixture-prefix:" + fake, SUFFIX_ENV: fake + ":fixture-suffix"}
        _, report = self._receipt(values)
        quarantine = next(row for row in report["case"]["assertions"] if row["id"] == "secret.quarantined")
        self.assertEqual(quarantine["status"], "fail")
        self.assertEqual(report["case"]["status"], "fail")

    def test_private_environment_redacted(self):
        receipt, report = self._receipt({TRACKER_SECRET_NAME: PRIVATE_VALUE, PRIVATE_ENV: PRIVATE_VALUE})
        self.assertEqual(receipt[TRACKER_SECRET_NAME], "<redacted>")
        self.assertNotIn(PRIVATE_ENV, receipt)
        self.assertNotIn(PRIVATE_VALUE, json.dumps(receipt))
        quarantine = next(row for row in report["case"]["assertions"] if row["id"] == "secret.quarantined")
        self.assertEqual(quarantine["status"], "pass")
        self.assertEqual(report["case"]["status"], "pass")

    def _receipt(self, values):
        script = '''
import json
import sys
from symphony_conformance import control

plan_path, raw = sys.argv[1:]
original = control._environment

def environment(plan):
    result = original(plan)
    # Mutate actual peer inheritance while preserving the public lifecycle.
    result.update(json.loads(raw))
    return result

control._environment = environment
sys.argv = ['symphony-conformance-control', '--plan', plan_path]
control.main()
'''
        flags = ["-" + "O" * min(sys.flags.optimize, 2)] if sys.flags.optimize else []

        def launch(_profile, _candidate, _workflow, _ca, plan_path):
            return [sys.executable, *flags, "-c", script, str(plan_path), json.dumps(values)]

        with tempfile.TemporaryDirectory() as directory:
            bundle = Path(directory) / "evidence"
            with patch.object(runner.profiles, "launch", side_effect=launch):
                runner.run(bundle, "scripted")
            rows = [json.loads(line) for line in (bundle / "events.jsonl").read_text().splitlines()]
            peers = [row for row in rows if row["kind"] == "peer.started"]
            self.assertEqual(len(peers), 1)
            self.assertEqual(sum(row["kind"] == "peer.closed" for row in rows), 1)
            owner = json.loads((bundle / "process.json").read_text())
            self.assertTrue(owner["closed"])
            self.assertTrue(owner["reaped"])
            for pid in (owner["pid"], owner["guard_pid"], peers[0]["data"]["pid"]):
                with self.assertRaises(ProcessLookupError):
                    os.kill(pid, 0)
            report = judge(bundle)
            self.assertEqual(report["harness"], {"status": "pass", "errors": []})
            return peers[0]["data"]["env"], report

    def test_concurrent_markers(self):
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / "peer.json"
            identities = [{"peer_id": "first", "pid": 1}, {"peer_id": "second", "pid": 2}]
            ready = threading.Barrier(len(identities))
            original = Path.replace

            def replace(pending, destination):
                # Both writes finish before either publisher renames its owned file.
                ready.wait(JOIN_TIMEOUT)
                return original(pending, destination)

            with patch.object(Path, "replace", replace), ThreadPoolExecutor(max_workers=len(identities)) as workers:
                writes = [workers.submit(_marker, marker, identity) for identity in identities]
                for write in writes:
                    write.result(JOIN_TIMEOUT)
            self.assertIn(json.loads(marker.read_text()), identities)
            self.assertEqual(list(marker.parent.iterdir()), [marker])

    def test_failed_marker_cleanup(self):
        with tempfile.TemporaryDirectory() as directory:
            marker = Path(directory) / "peer.json"
            with patch.object(Path, "replace", side_effect=OSError("injected rename failure")):
                with self.assertRaisesRegex(OSError, "injected rename failure"):
                    _marker(marker, {"peer_id": "first", "pid": 1})
            self.assertEqual(list(marker.parent.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
