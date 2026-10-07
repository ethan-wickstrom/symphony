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
from symphony_conformance.assets import MAX_JSON_DEPTH, decode
from symphony_conformance.driver import capture
from symphony_conformance.driver.journal import MAX_EVENTS, MAX_EVENT_BYTES
from symphony_conformance.driver.process import Process
from symphony_conformance.judge import judge


BAD_LINE_BYTES = 900 * 1024
FLOOD_LINES = MAX_EVENTS + 1
UNICODE_BYTES = 400 * 1024
FRAGMENT_BYTES = 64 * 1024


class Outcome(Enum):
    PASS = "pass"
    FAIL = "fail"


class Fragment(Enum):
    NORMAL = "normal"
    BYTE = "byte"


class ObservationTest(unittest.TestCase):
    def test_large_bad_observation(self):
        # An invalid record fits capture but its base64 copy exceeds admission.
        bad_line = b'"' + b"X" * (BAD_LINE_BYTES - 3) + b'"\n'
        self.assertLess(len(bad_line), runner.OUTPUT_LIMIT)
        self.assertGreater(len(base64.b64encode(bad_line[:-1])), MAX_EVENT_BYTES)
        rows, _, _ = self._run(bad_line, Outcome.PASS)
        errors = [row for row in rows if row["kind"] == "candidate.observation_error"]
        self.assertEqual(len(errors), 1)
        self.assertEqual(errors[0]["data"], {"stream": "stdout", "error_type": "ValueError"})
        self.assertLess(len(json.dumps(errors[0]).encode()), MAX_EVENT_BYTES)
        self.assertFalse(any(row["kind"] == "candidate.observation_limit" for row in rows))

    def test_byte_fragments(self):
        rows, _, _ = self._run(b"\xff" * FRAGMENT_BYTES + b"\n", Outcome.PASS, Fragment.BYTE)
        errors = [row for row in rows if row["kind"] == "candidate.observation_error"]
        self.assertEqual(len(errors), 1)
        self.assertEqual(errors[0]["data"], {"stream": "stdout", "error_type": "UnicodeDecodeError"})
        self.assertFalse(any(row["kind"] == "candidate.observation_limit" for row in rows))

    def test_bad_observation_flood(self):
        rows, report, _ = self._run(b"x\n" * FLOOD_LINES, Outcome.FAIL)
        summary, errors = self._budget(rows, report)
        self.assertEqual(summary["malformed"], FLOOD_LINES)
        self.assertEqual(summary["omitted_invalid"], FLOOD_LINES - len(errors))
        self.assertEqual(summary["omitted_valid"], 0)
        self.assertGreater(len(errors), 0)
        self.assertLess(len(errors), FLOOD_LINES)
        self.assertTrue(all(row["data"] == {"stream": "stdout", "error_type": "JSONDecodeError"}
                            for row in errors))

    def test_valid_observation_flood(self):
        rows, report, baseline = self._run(b'{"event":"ready"}\n' * FLOOD_LINES, Outcome.FAIL)
        summary, errors = self._budget(rows, report)
        baseline_ready = sum(value.get("event") == "ready" for value in baseline)
        retained_ready = sum(row["kind"] == "candidate.observation" and row["data"].get("event") == "ready"
                             for row in rows) - baseline_ready
        self.assertGreaterEqual(retained_ready, 0)
        self.assertLess(retained_ready, FLOOD_LINES)
        self.assertEqual(retained_ready + summary["omitted_valid"], FLOOD_LINES)
        self.assertEqual(summary["malformed"], 0)
        self.assertEqual(summary["omitted_invalid"], 0)
        self.assertEqual(errors, [])

    def test_unicode_observation(self):
        text = "é" * (UNICODE_BYTES // len("é".encode()))
        value = {"event": "fixture_padding", "message": text}
        tail = json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode() + b"\n"
        self.assertLess(len(tail), runner.OUTPUT_LIMIT)
        self.assertGreater(len(json.dumps(value, separators=(",", ":")).encode()), MAX_EVENT_BYTES)
        rows, report, _ = self._run(tail, Outcome.FAIL)
        summary, errors = self._budget(rows, report)
        self.assertEqual(summary["malformed"], 0)
        self.assertEqual(summary["omitted_invalid"], 0)
        self.assertEqual(summary["omitted_valid"], 1)
        self.assertEqual(errors, [])
        self.assertFalse(any(row["kind"] == "candidate.observation"
                             and row["data"].get("event") == "fixture_padding" for row in rows))

    def test_deep_observation(self):
        nested = None
        for _ in range(MAX_JSON_DEPTH - 1):
            nested = [nested]
        value = {"event": "fixture_padding", "padding": nested}
        tail = json.dumps(value, separators=(",", ":")).encode() + b"\n"
        self.assertEqual(decode(tail)["event"], "fixture_padding")
        # A raw record can fit its depth bound while its evidence envelope cannot.
        with self.assertRaises(ValueError):
            decode(json.dumps({"data": value}).encode())
        rows, report, _ = self._run(tail, Outcome.FAIL)
        summary, errors = self._budget(rows, report)
        self.assertEqual(summary["malformed"], 0)
        self.assertEqual(summary["omitted_invalid"], 0)
        self.assertEqual(summary["omitted_valid"], 1)
        self.assertEqual(errors, [])
        self.assertFalse(any(row["kind"] == "candidate.observation"
                             and row["data"].get("event") == "fixture_padding" for row in rows))

    def test_reserved_answer_fields(self):
        fields = {"passed": True, "verdict": "pass", "requirement_id": "fixture-requirement"}
        for name, value in fields.items():
            with self.subTest(field=name):
                tail = json.dumps({"event": "ready", name: value}, separators=(",", ":")).encode() + b"\n"
                rows, report, baseline = self._run(tail, Outcome.FAIL)
                summary, errors = self._budget(rows, report)
                self.assertEqual(summary["malformed"], 0)
                self.assertEqual(summary["omitted_invalid"], 0)
                self.assertEqual(summary["omitted_valid"], 1)
                self.assertEqual(errors, [])
                self.assertTrue(all(fields.keys().isdisjoint(row["data"]) for row in rows))
                observations = [row["data"] for row in rows if row["kind"] == "candidate.observation"]
                self.assertEqual(observations, baseline)

    def _budget(self, rows, report):
        limits = [row for row in rows if row["kind"] == "candidate.observation_limit"]
        summaries = [row for row in rows if row["kind"] == "candidate.observation_summary"]
        errors = [row for row in rows if row["kind"] == "candidate.observation_error"]
        self.assertEqual(len(limits), 1)
        self.assertEqual(len(summaries), 1)
        summary = summaries[0]["data"]
        self.assertEqual(summary["stream"], "stdout")
        for name in ("malformed", "omitted_invalid", "omitted_valid"):
            self.assertIs(type(summary[name]), int)
            self.assertGreaterEqual(summary[name], 0)
        self.assertEqual(len(errors) + summary["omitted_invalid"], summary["malformed"])
        self.assertGreater(summary["omitted_invalid"] + summary["omitted_valid"], 0)
        for row in (*limits, *summaries, *errors):
            self.assertLess(len(json.dumps(row).encode()), MAX_EVENT_BYTES)
            self.assertNotIn("line_b64", row["data"])
            self.assertNotIn("data_b64", row["data"])
            self.assertTrue(all(type(value) in (str, int) for value in row["data"].values()))
        for row in errors:
            self.assertEqual(set(row["data"]), {"stream", "error_type"})
        eof = [row for row in rows if row["kind"] == "capture.closed"
               and row["data"].get("stream") == "stdout" and row["data"].get("stage") == "eof"]
        self.assertEqual(len(eof), 1)
        self.assertLess(limits[0]["seq"], eof[0]["seq"])
        self.assertGreater(summaries[0]["seq"], eof[0]["seq"])
        failures = [assertion for assertion in report["case"]["assertions"] if assertion["status"] == "fail"]
        self.assertTrue(any(limits[0]["seq"] in assertion["evidence_seq"] for assertion in failures), failures)
        return summary, errors

    def _run(self, tail, outcome, fragment=Fragment.NORMAL):
        self.assertLess(len(tail), runner.OUTPUT_LIMIT)
        processes = []
        stdout_callbacks = 0
        script = """
import os
from pathlib import Path
import sys
from symphony_conformance.assets import decode
from symphony_conformance.control import Control

path = Path(sys.argv[1])
Control(decode(path.read_bytes()), path).run()
payload = Path(sys.argv[2]).read_bytes()
while payload:
    payload = payload[os.write(sys.stdout.fileno(), payload):]
"""

        class ObservedProcess(Process):
            def __init__(self, *args, **kwargs):
                super().__init__(*args, **kwargs)
                processes.append(self)

            def _record(self, kind, fields):
                nonlocal stdout_callbacks
                if kind == "capture.stdout":
                    stdout_callbacks += 1
                return super()._record(kind, fields)

        with tempfile.TemporaryDirectory() as directory:
            bundle = Path(directory) / "evidence"
            tail_path = Path(directory) / "tail.bin"
            tail_path.write_bytes(tail)

            def launch(_profile, _candidate, _workflow, _ca, plan):
                optimization = ["-" + "O" * sys.flags.optimize] if sys.flags.optimize else []
                return [sys.executable, *optimization, "-c", script, str(plan), str(tail_path)]

            size = 1 if fragment is Fragment.BYTE else capture.READ_CHUNK
            with patch.object(capture, "READ_CHUNK", size), patch.object(runner.profiles, "launch", side_effect=launch), \
                    patch.object(runner, "Process", ObservedProcess):
                runner.run(bundle, "scripted")

            manifest = json.loads((bundle / "manifest.json").read_text())
            receipt = json.loads((bundle / "process.json").read_text())
            rows = [json.loads(line) for line in (bundle / "events.jsonl").read_text().splitlines()]
            snapshot = processes[0].snapshot()
            report = judge(bundle)
            self.assertEqual(report["harness"], {"status": "pass", "errors": []})
            self.assertEqual(report["case"]["status"], outcome.value)
            if fragment is Fragment.BYTE:
                self.assertGreater(stdout_callbacks, MAX_EVENTS)
                self.assertLessEqual((bundle / "process.json").stat().st_size, MAX_EVENT_BYTES)
                self.assertFalse(any(row["kind"] in {"capture.stdout", "capture.stderr"}
                                     for row in receipt["lifecycle"]))
            self.assertTrue(manifest["completed"])
            self.assertEqual(manifest["harness_errors"], [])

            self.assertFalse(any(row["kind"] in {"capture.overflow", "candidate.execution_failure"} for row in rows))

            # The diagnostic references retained capture rather than copying it.
            stdout = (bundle / "stdout.bin").read_bytes()
            self.assertTrue(stdout.endswith(tail))
            self.assertLess(len(stdout), runner.OUTPUT_LIMIT)
            observations = [row["data"] for row in rows if row["kind"] == "candidate.observation"]
            baseline = [json.loads(line) for line in stdout[:-len(tail)].splitlines()]
            self.assertEqual(observations[:len(baseline)], baseline)
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
            self.assertLessEqual(len(rows), MAX_EVENTS)
            return rows, report, baseline


if __name__ == "__main__":
    unittest.main()
