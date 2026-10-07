"""Cancellation reaches a live scripted peer before the service exits."""

import base64
from contextlib import ExitStack
import errno
import json
import os
from pathlib import Path
import signal
import sys
import tempfile
import time
import unittest

from symphony_conformance.assets import decode, load, resource
from symphony_conformance.driver.journal import Journal
from symphony_conformance.driver.process import Process
from symphony_conformance.driver.tracker import Tracker
from symphony_conformance.profiles import command, environment

PROCESS_BUDGET = 5
OUTPUT_LIMIT = 1024 * 1024
DIAGNOSTIC_BYTES = 8192


class ControlTest(unittest.TestCase):
    def test_cancel_active_peer(self):
        with tempfile.TemporaryDirectory(prefix="symphony-control-cancel-") as directory:
            with ExitStack() as owned:
                root = Path(directory).resolve()
                run_root = root / "run"
                run_root.mkdir()
                control_root = run_root / "control"
                control_root.mkdir()
                corpus = load("corpus/lifecycle.json")
                profile = load("profiles/scripted.json")
                journal = Journal(root)
                owned.callback(journal.close)
                collector = journal.start()
                tracker = Tracker(corpus, journal, str(resource("tls/server.pem")),
                                  str(resource("tls/server.key")))
                owned.callback(tracker.close)
                plan = {
                    "schema_version": 1, "profile_id": profile["id"],
                    "profile": profile, "corpus": corpus, "collector_url": collector,
                    "endpoint": tracker.endpoint, "ca": str(resource("tls/ca.pem")),
                    "control_root": str(control_root),
                    "workspace_root": str(run_root / "workspaces"),
                    "bundle": str(root), "fault": None,
                }
                plan_path = root / "plan.json"
                plan_path.write_text(json.dumps(plan), encoding="utf-8")

                def second_turn():
                    frames = [decode(base64.b64decode(row["data"]["frame"], validate=True))
                              for row in journal.rows("peer.client")]
                    return sum(frame.get("method") == "turn/start" for frame in frames) == len(corpus["turn_ids"])

                candidate = None
                try:
                    with Process(command("control", plan_path), cwd=run_root,
                                 env=environment(profile, run_root, corpus),
                                 output_limit=OUTPUT_LIMIT,
                                 deadline=time.monotonic() + PROCESS_BUDGET,
                                 emit=lambda kind, data: journal.emit(kind, data)) as candidate:
                        candidate.wait_for(second_turn, PROCESS_BUDGET)
                        self.assertFalse(journal.rows("control.terminal"))
                        candidate.signal(signal.SIGTERM)
                        self.assertEqual(candidate.join(PROCESS_BUDGET), 0)

                        peers = journal.rows("peer.started")
                        closed = journal.rows("peer.closed")
                        reaped = [row for row in journal.rows("control.peer.candidate.wait")
                                  if row["data"].get("operation") == "reap"
                                  and row["data"].get("reaped") is True]
                        exited = [row for row in journal.rows("candidate.wait")
                                  if row["data"].get("operation") == "observe"]
                        self.assertEqual(len(peers), 1)
                        self.assertEqual(len(closed), 1)
                        self.assertEqual(len(reaped), 1)
                        self.assertEqual(len(exited), 1)
                        self.assertEqual(reaped[0]["data"]["pid"], peers[0]["data"]["pid"])
                        self.assertLess(closed[0]["seq"], reaped[0]["seq"])
                        self.assertLess(reaped[0]["seq"], exited[0]["seq"])
                        try:
                            os.kill(peers[0]["data"]["pid"], 0)
                        except OSError as error:
                            self.assertEqual(error.errno, errno.ESRCH)
                        else:
                            self.fail("The service exited while its peer remained live")
                except BaseException as error:
                    # Retain admitted identities if the regression exposes lost custody.
                    identities = [row["data"] for row in journal.rows("control.peer.candidate.wait")
                                  if row["data"].get("operation") == "guard-admission"]
                    started = [row["data"] for row in journal.rows("peer.started")]
                    snapshot = candidate.snapshot() if candidate is not None else getattr(error, "_process_snapshot", {})
                    streams = {name: snapshot.get(name, b"")[-DIAGNOSTIC_BYTES:].decode("utf-8", errors="replace")
                               for name in ("stdout", "stderr")}
                    print(json.dumps({"admitted_peer_groups": identities, "peers": started, **streams}), file=sys.stderr)
                    raise


if __name__ == "__main__":
    unittest.main()
