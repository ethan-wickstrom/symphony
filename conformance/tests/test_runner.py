import base64
import hashlib
import json
from enum import Enum
import os
from pathlib import Path
import sys
import tempfile
import threading
import unittest
from unittest.mock import patch

from symphony_conformance import runner
from symphony_conformance.assets import load
from symphony_conformance.driver.journal import Journal
from symphony_conformance.driver.process import Process, Stdin
from symphony_conformance.driver.tracker import Tracker
from symphony_conformance.judge import judge

TERMINAL_PROBE_SECONDS = 1


class Cleanup(Enum):
    CLEAN = "clean"
    FAIL = "fail"


class Stage(Enum):
    EXECUTE = "execute"
    CLOSE = "close"


class Barrier(Enum):
    ACK = "ack"
    READINESS = "readiness"


class Output(Enum):
    STDOUT = ("stdout",)
    STDERR = ("stderr",)
    BOTH = ("stdout", "stderr")


class RunnerTest(unittest.TestCase):
    def test_stdout_overflow(self):
        self._overflow(Output.STDOUT)

    def test_stderr_overflow(self):
        self._overflow(Output.STDERR)

    def test_both_streams_overflow(self):
        self._overflow(Output.BOTH)

    def _overflow(self, output):
        ready = b'{"event":"ready"}\n'
        processes = []
        script = """
import os
import signal
import sys
import threading

stopping = threading.Event()

def stop(_number, _frame):
    stopping.set()

signal.signal(signal.SIGTERM, stop)
os.write(sys.stdout.fileno(), sys.argv[3].encode())
if os.read(sys.stdin.fileno(), 1) != b"!":
    raise RuntimeError("Overflow release was not delivered")
for stream in sys.argv[1].split(","):
    descriptor = getattr(sys, stream).fileno()
    payload = b"X" * int(sys.argv[2])
    while payload:
        payload = payload[os.write(descriptor, payload):]
stopping.wait()
"""

        class OverflowProcess(Process):
            def __init__(self, *args, **kwargs):
                super().__init__(*args, **kwargs, stdin=Stdin.PIPE, stdin_limit=1)
                self._released = False
                processes.append(self)

            def wait_for(self, predicate, timeout):
                result = super().wait_for(predicate, timeout)
                if not self._released:
                    # Admission and public readiness precede the real child flood.
                    self._released = True
                    self.write(b"!")
                return result

        optimization = ["-" + "O" * sys.flags.optimize] if sys.flags.optimize else []
        argv = [sys.executable, "-I", *optimization, "-c", script, ",".join(output.value),
                str(runner.OUTPUT_LIMIT + 1), ready.decode()]
        with tempfile.TemporaryDirectory() as directory:
            bundle = Path(directory) / "evidence"
            with patch.object(runner.profiles, "launch", return_value=argv), patch.object(runner, "Process", OverflowProcess):
                runner.run(bundle, "scripted")

            manifest = json.loads((bundle / "manifest.json").read_text())
            snapshot = processes[0].snapshot()
            receipt = json.loads((bundle / "process.json").read_text())
            rows = [json.loads(line) for line in (bundle / "events.jsonl").read_text().splitlines()]
            self.assertTrue(snapshot["closed"])
            self.assertTrue(snapshot["reaped"])
            self.assertTrue(receipt["closed"])
            self.assertTrue(receipt["reaped"])
            for pid in (snapshot["pid"], snapshot["guard_pid"]):
                with self.assertRaises(ProcessLookupError):
                    os.kill(pid, 0)

            for stream in ("stdout", "stderr"):
                initial = ready if stream == "stdout" else b""
                expected = (initial + b"X" * (runner.OUTPUT_LIMIT - len(initial))
                            if stream in output.value else initial)
                retained = (bundle / (stream + ".bin")).read_bytes()
                with self.subTest(stream=stream):
                    self.assertEqual(retained, expected)
                    self.assertEqual(snapshot[stream], retained)
                    self.assertEqual(manifest["files"][stream + ".bin"],
                                     {"bytes": len(retained), "sha256": hashlib.sha256(retained).hexdigest()})
                    chunks = [base64.b64decode(row["data"]["data_b64"], validate=True)
                              for row in rows if row["kind"] == "capture." + stream]
                    self.assertEqual(b"".join(chunks), retained)

            failures = [row["data"] for row in rows if row["kind"] == "candidate.execution_failure"]
            self.assertEqual([value["error_type"] for value in failures], ["OutputLimit"])
            overflows = [row["data"] for row in rows if row["kind"] == "capture.overflow"]
            self.assertEqual(sorted(value["stream"] for value in overflows), sorted(output.value))
            self.assertTrue(all(value["limit"] == runner.OUTPUT_LIMIT for value in overflows))
            self.assertEqual(snapshot["eof"], ("stderr", "stdout"))
            self.assertEqual(snapshot["failures"], ())
            for operation in ("observe", "join", "reap"):
                self.assertEqual(sum(row["kind"] == "candidate.wait"
                                     and row["data"].get("operation") == operation for row in rows), 1)
            closures = [row["data"] for row in rows if row["kind"] == "capture.closed"]
            self.assertEqual(len(closures), 3)
            self.assertTrue(all(value["status"] == "ok" for value in closures))
            self.assertTrue(manifest["completed"])
            self.assertEqual(manifest["harness_errors"], [])
            report = judge(bundle)
            self.assertEqual(report["harness"], {"status": "pass", "errors": []})
            self.assertNotEqual(report["case"]["status"], "pass")
            self.assertFalse(report["core_summary"]["complete"])

    def test_terminal_waits_for_ack(self):
        self._terminal_barrier(Barrier.ACK)

    def test_terminal_waits_for_ready(self):
        self._terminal_barrier(Barrier.READINESS)

    def _terminal_barrier(self, barrier):
        corpus = load("corpus/lifecycle.json")
        arrival = threading.Event()
        release = threading.Event()
        terminal = threading.Event()
        acknowledged = threading.Event()
        accepted = threading.Event()
        processes = []
        trackers = []
        journals = []
        errors = []
        observed = {}

        def ready(data):
            turn = corpus["turn_ids"][1]
            return (data.get("event") == "turn_started" and data.get("turn_id") == turn
                    and data.get("session_id") == corpus["thread_id"] + "-" + turn)

        class ClosingJournal(Journal):
            def __init__(self, *args, **kwargs):
                super().__init__(*args, **kwargs)
                self._turns = 0
                self._second = None
                journals.append(self)

            def emit(self, kind, data, origin="executor"):
                sequence = super().emit(kind, data, origin)
                if kind == "candidate.observation" and ready(data):
                    accepted.set()
                if kind == "peer.server" and self._second is not None:
                    request_sequence, peer_id, identity = self._second
                    reply = json.loads(base64.b64decode(data["frame"], validate=True))
                    if (sequence > request_sequence and data["peer_id"] == peer_id
                            and "method" not in reply
                            and type(reply.get("id")) is type(identity) and reply.get("id") == identity
                            and reply.get("result", {}).get("turn", {}).get("id") == corpus["turn_ids"][1]):
                        acknowledged.set()
                if barrier is Barrier.READINESS and acknowledged.is_set() and accepted.is_set():
                    arrival.set()
                if kind != "peer.client":
                    return sequence
                frame = json.loads(base64.b64decode(data["frame"], validate=True))
                if frame.get("method") != "turn/start":
                    return sequence
                self._turns += 1
                if self._turns != 2:
                    return sequence
                self._second = (sequence, data["peer_id"], frame["id"])
                if barrier is Barrier.ACK:
                    # Record the request before withholding its collector receipt and peer ACK.
                    arrival.set()
                    if not release.wait(corpus["deadline_seconds"]):
                        raise TimeoutError("Peer request release deadline expired")
                return sequence

            def rows(self, kind=None):
                result = super().rows(kind)
                if barrier is not Barrier.READINESS or release.is_set() or kind != "candidate.observation":
                    return result
                # Delay consumer visibility without changing the retained public log or its row.
                return [row for row in result if not ready(row["data"])]

        class ClosingTracker(Tracker):
            def __init__(self, *args, **kwargs):
                super().__init__(*args, **kwargs)
                trackers.append(self)

            def terminal(self):
                super().terminal()
                terminal.set()

        def process(*args, **kwargs):
            value = Process(*args, **kwargs)
            processes.append(value)
            return value

        with tempfile.TemporaryDirectory() as directory:
            bundle = Path(directory) / "evidence"

            def release_peer():
                try:
                    observed["arrived"] = arrival.wait(corpus["deadline_seconds"])
                    observed["premature"] = (terminal.wait(TERMINAL_PROBE_SECONDS)
                                              if observed["arrived"] else False)
                except BaseException as error:
                    errors.append(error)
                finally:
                    release.set()

            with patch.object(runner, "Journal", ClosingJournal), patch.object(runner, "Tracker", ClosingTracker), patch.object(runner, "Process", process):
                worker = threading.Thread(target=release_peer, name="runner-barrier-test")
                worker.start()
                try:
                    runner.run(bundle, "scripted")
                except BaseException as error:
                    errors.append(error)
                finally:
                    release.set()
                    worker.join(corpus["deadline_seconds"] + TERMINAL_PROBE_SECONDS)
                self.assertFalse(worker.is_alive(), "Peer release helper did not join")

            self.assertTrue(observed.get("arrived"), "Second-turn barrier was not observed")
            self.assertEqual(errors, [])
            manifest = json.loads((bundle / "manifest.json").read_text())
            self.assertTrue(manifest["completed"])
            self.assertEqual(manifest["harness_errors"], [])
            self.assertTrue(processes[0].snapshot()["closed"])
            self.assertTrue(processes[0].snapshot()["reaped"])
            self.assertEqual(trackers[0].errors(), [])
            self.assertTrue(trackers[0]._closed)
            self.assertFalse(trackers[0]._thread.is_alive())
            self.assertEqual(journals[0].errors(), [])
            self.assertTrue(journals[0]._file.closed)
            self.assertFalse(journals[0]._thread.is_alive())

            rows = [json.loads(line) for line in (bundle / "events.jsonl").read_text().splitlines()]
            self.assertEqual(sum(row["kind"] == "provider.closed" for row in rows), 1)
            self.assertEqual(sum(row["kind"] == "collector.closed" for row in rows), 1)
            self.assertEqual(sum(row["kind"] == "peer.closed" for row in rows), 1)
            frames = [(row, json.loads(base64.b64decode(row["data"]["frame"], validate=True)))
                      for row in rows if row["kind"] in {"peer.client", "peer.server"}]
            requests = [(row, frame) for row, frame in frames
                        if row["kind"] == "peer.client" and frame.get("method") == "turn/start"]
            self.assertEqual(len(requests), 2)
            request, frame = requests[1]
            replies = [(row, value) for row, value in frames
                       if row["kind"] == "peer.server" and "method" not in value
                       and row["data"]["peer_id"] == request["data"]["peer_id"]
                       and value.get("id") == frame["id"]]
            self.assertEqual(len(replies), 1)
            reply, value = replies[0]
            self.assertEqual(value["result"]["turn"]["id"], corpus["turn_ids"][1])
            transitions = [row for row in rows if row["kind"] == "control.terminal"]
            self.assertEqual(len(transitions), 1)
            boundary = ("Tracker transitioned before the peer could acknowledge turn/start"
                        if barrier is Barrier.ACK else "Tracker transitioned before accepted readiness was visible")
            self.assertFalse(observed["premature"], boundary)
            self.assertLess(request["seq"], reply["seq"])
            self.assertLess(reply["seq"], transitions[0]["seq"])
            if barrier is Barrier.READINESS:
                readiness = [row for row in rows if row["kind"] == "candidate.observation" and ready(row["data"])]
                self.assertEqual(len(readiness), 1)
                public = [json.loads(line) for line in (bundle / "stdout.bin").read_bytes().splitlines()]
                self.assertEqual([value for value in public if ready(value)], [readiness[0]["data"]])
                self.assertLess(readiness[0]["seq"], transitions[0]["seq"])

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
