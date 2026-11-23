"""Receipt corruption and report controls run without candidate execution."""

import base64
import copy
import hashlib
from http import HTTPStatus
import json
import shutil
import tempfile
import unittest
from unittest import mock
from pathlib import Path

from symphony_conformance.assets import digest, load, resource
from symphony_conformance.judge import _interrupt_check, _inventory, _shutdown_check, _turn_checks, _workspace_check, judge
from symphony_conformance.report import build
from symphony_conformance.schema import Schema

CAPTURE_BOUND = 1024 * 1024


def event(kind, data):
    return {"origin": "control-test", "kind": kind, "data": data}


def cleanup():
    return [
        event("candidate.wait", {"operation": "observe", "status": 0, "reaped": False}),
        event("candidate.wait", {"operation": "join", "status": 0, "reaped": False}),
        event("capture.closed", {"stage": "eof", "stream": "stdout", "status": "ok"}),
        event("capture.closed", {"stage": "eof", "stream": "stderr", "status": "ok"}),
        event("provider.closed", {"status": "ok"}),
        event("group.cleanup", {"stage": "signal", "signal": 9, "status": "ok", "forced": False}),
        event("candidate.wait", {"operation": "reap", "status": 0, "reaped": True}),
        event("capture.closed", {"stage": "owner-close", "status": "ok"}),
    ]


class JudgeTest(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.bundle = Path(self.temporary.name)
        self.write(cleanup())

    def write(self, observations):
        records = []
        for sequence, observation in enumerate(observations, start=1):
            records.append({"seq": sequence, "at_ns": sequence, **observation})
        files = {
            "events.jsonl": b"".join(json.dumps(item).encode() + b"\n" for item in records),
            "plan.json": json.dumps({"workspace_root": "/fixture/root"}).encode(),
            "stdout.bin": b"",
            "stderr.bin": b"",
        }
        retained = self.bundle / "assets"
        shutil.copytree(str(resource(".")), retained, dirs_exist_ok=True)
        for path in retained.rglob("*"):
            if path.is_file():
                files[path.relative_to(self.bundle).as_posix()] = path.read_bytes()
        for name, raw in files.items():
            (self.bundle / name).write_bytes(raw)
        manifest = {
            "schema_version": 1,
            "profile_id": "scripted",
            "corpus_id": "core-lifecycle-v1",
            "completed": True,
            "harness_errors": [],
            "files": {name: {"sha256": hashlib.sha256(raw).hexdigest(), "bytes": len(raw)}
                      for name, raw in files.items()},
            "identities": {
                "catalog": digest("catalog.json"),
                "corpus": digest("corpus/lifecycle.json"),
                "protocol": digest("protocol/manifest.json"),
                "profile": digest("profiles/scripted.json"),
            },
        }
        (self.bundle / "manifest.json").write_text(json.dumps(manifest))

    def alter_manifest(self, change):
        path = self.bundle / "manifest.json"
        manifest = json.loads(path.read_text())
        change(manifest)
        path.write_text(json.dumps(manifest))

    def assert_bad_bundle(self):
        report = judge(self.bundle)
        self.assertEqual(report["harness"]["status"], "harness_error")
        self.assertFalse(report["core_summary"]["complete"])
        self.assertEqual(len(report["requirements"]), 106)
        self.assertEqual(len(report["supplemental_requirements"]), 12)
        return report

    def test_partial_trace_keeps_rows(self):
        report = judge(self.bundle)
        self.assertEqual(report["harness"]["status"], "pass")
        self.assertEqual(report["case"]["status"], "incomplete")
        self.assertFalse(report["core_summary"]["complete"])
        self.assertEqual(len(report["requirements"]), 106)
        self.assertEqual(len(report["supplemental_requirements"]), 12)
        self.assertFalse(any(item["verdict"] == "pass" for item in report["requirements"]))

    def test_digest_change(self):
        (self.bundle / "stdout.bin").write_bytes(b"unrecorded")
        self.assert_bad_bundle()

    def test_missing_file(self):
        (self.bundle / "stderr.bin").unlink()
        self.assert_bad_bundle()

    def test_extra_file(self):
        (self.bundle / "unlisted.bin").write_bytes(b"extra")
        self.assert_bad_bundle()

    def test_symlink_file(self):
        (self.bundle / "stderr.bin").unlink()
        (self.bundle / "stderr.bin").symlink_to(self.bundle / "stdout.bin")
        self.assert_bad_bundle()

    def test_dir_entry_bound(self):
        storm = self.bundle / "entry-storm"
        storm.mkdir()
        limit = 4
        for index in range(limit + 1):
            (storm / str(index)).mkdir()
        with mock.patch("symphony_conformance.judge.MAX_ENTRIES", limit, create=True):
            with self.assertRaisesRegex(ValueError, "entry bound"):
                _inventory(storm)

    def test_mixed_entry_bound(self):
        storm = self.bundle / "entry-storm"
        storm.mkdir()
        for index in range(3):
            (storm / ("directory-" + str(index))).mkdir()
        for index in range(2):
            (storm / ("file-" + str(index))).write_bytes(b"")
        with mock.patch("symphony_conformance.judge.MAX_ENTRIES", 4, create=True):
            with self.assertRaisesRegex(ValueError, "entry bound"):
                _inventory(storm)

    def test_inventory_depth(self):
        storm = self.bundle / "entry-storm"
        (storm / "one" / "two" / "three").mkdir(parents=True)
        with mock.patch("symphony_conformance.judge.MAX_PATH_DEPTH", 2, create=True):
            with self.assertRaisesRegex(ValueError, "depth bound"):
                _inventory(storm)

    def test_duplicate_manifest_field(self):
        path = self.bundle / "manifest.json"
        path.write_bytes(path.read_bytes().replace(b'"completed": true', b'"completed": true, "completed": true'))
        self.assert_bad_bundle()

    def test_unknown_profile(self):
        self.alter_manifest(lambda manifest: manifest.update(profile_id="unknown"))
        self.assert_bad_bundle()

    def test_unknown_corpus(self):
        self.alter_manifest(lambda manifest: manifest.update(corpus_id="unknown"))
        self.assert_bad_bundle()

    def test_altered_identity(self):
        self.alter_manifest(lambda manifest: manifest["identities"].update(corpus="0" * 64))
        self.assert_bad_bundle()

    def test_altered_retained_asset(self):
        retained = self.bundle / "assets"
        target = retained / "profiles" / "scripted.json"
        profile = json.loads(target.read_bytes())
        profile["approval_policy"] = "changed"
        target.write_text(json.dumps(profile))

        def inventory(manifest):
            for path in retained.rglob("*"):
                if path.is_file():
                    raw = path.read_bytes()
                    manifest["files"][path.relative_to(self.bundle).as_posix()] = {
                        "sha256": hashlib.sha256(raw).hexdigest(), "bytes": len(raw)}

        self.alter_manifest(inventory)
        self.assert_bad_bundle()

    def test_live_quiet_descendant(self):
        observations = [event("control.descendant.started", {"pid": 987654, "pgid": 987654}),
                        event("peer.closed", {"peer_id": "peer"}), *cleanup()]
        guard = next(index for index, item in enumerate(observations) if item["kind"] == "group.cleanup")
        observations.insert(guard, event("descendant.observed", {"pid": 987654, "alive": True}))
        records = [{"seq": index, "at_ns": index, **item}
                   for index, item in enumerate(observations, start=1)]
        self.assertEqual(_shutdown_check(records)["status"], "fail")

    def test_incomplete_run(self):
        self.alter_manifest(lambda manifest: manifest.update(completed=False))
        self.assert_bad_bundle()

    def test_cleanup_failure(self):
        observations = cleanup()
        observations[-1]["data"]["status"] = "failed"
        self.write(observations)
        self.assert_bad_bundle()

    def test_execution_failure_verdict(self):
        observations = cleanup()
        observations.insert(5, event("peer.closed", {"peer_id": "fixture-peer"}))
        self.write(observations)
        baseline = judge(self.bundle)
        check = next(row for row in baseline["case"]["assertions"] if row["id"] == "shutdown.joined")
        self.assertEqual(check["status"], "pass")

        observations.insert(0, event("candidate.execution_failure", {"error_type": "OutputLimit", "returncode": 0}))
        self.write(observations)
        report = judge(self.bundle)
        self.assertEqual(report["harness"]["status"], "pass")
        self.assertEqual(report["case"]["status"], "fail")
        check = next(row for row in report["case"]["assertions"] if row["id"] == "shutdown.joined")
        self.assertEqual(check["status"], "fail")
        self.assertIn(1, check["evidence_seq"])

    def test_overflow_verdict(self):
        raw = b"x" * CAPTURE_BOUND
        observations = cleanup()
        observations.insert(5, event("peer.closed", {"peer_id": "fixture-peer"}))
        observations[:0] = [
            event("capture.stdout", {"bytes": len(raw), "data_b64": base64.b64encode(raw).decode("ascii")}),
            event("capture.overflow", {"stream": "stdout", "limit": CAPTURE_BOUND}),
        ]
        self.write(observations)
        (self.bundle / "stdout.bin").write_bytes(raw)
        self.alter_manifest(lambda manifest: manifest["files"].update({
            "stdout.bin": {"sha256": hashlib.sha256(raw).hexdigest(), "bytes": len(raw)}}))
        report = judge(self.bundle)
        self.assertEqual(report["harness"]["status"], "pass")
        self.assertEqual(report["case"]["status"], "fail")
        check = next(row for row in report["case"]["assertions"] if row["id"] == "shutdown.joined")
        self.assertEqual(check["status"], "fail")
        self.assertIn(2, check["evidence_seq"])

    def test_missing_cleanup(self):
        self.write(cleanup()[:-1])
        self.assert_bad_bundle()

    def test_dup_journal_seq(self):
        raw = (self.bundle / "events.jsonl").read_bytes().replace(b'"seq": 2', b'"seq": 1')
        self.replace_journal(raw)
        self.assert_bad_bundle()

    def test_reversed_ingestion_clock(self):
        raw = (self.bundle / "events.jsonl").read_bytes().replace(b'"at_ns": 2', b'"at_ns": 0')
        self.replace_journal(raw)
        self.assert_bad_bundle()

    def test_truncated_journal(self):
        self.replace_journal((self.bundle / "events.jsonl").read_bytes().rstrip(b"\n"))
        self.assert_bad_bundle()

    def replace_journal(self, raw):
        (self.bundle / "events.jsonl").write_bytes(raw)
        self.alter_manifest(lambda manifest: manifest["files"].update(
            {"events.jsonl": {"sha256": hashlib.sha256(raw).hexdigest(), "bytes": len(raw)}}))

    def test_raw_frame_corruption(self):
        self.write([event("peer.client", {"peer_id": "fixture-peer", "frame": "%%%"})] + cleanup())
        self.assert_bad_bundle()

    def test_client_failure(self):
        raw = json.dumps({"method": "initialize", "id": True}).encode() + b"\n"
        self.write([event("peer.client", {"peer_id": "fixture-peer", "frame": base64.b64encode(raw).decode()})] + cleanup())
        report = judge(self.bundle)
        self.assertEqual(report["harness"]["status"], "pass")
        selected = next(item for item in report["case"]["assertions"] if item["id"] == "protocol.schema")
        self.assertEqual(selected["status"], "fail")

    def test_missing_report_row(self):
        catalog = copy.deepcopy(load("catalog.json"))
        catalog["requirements"].pop()
        with self.assertRaises(ValueError):
            build(catalog, {"id": "core-lifecycle-v1", "assertions": []}, {"status": "pass", "errors": []}, {})

    def test_duplicate_report_row(self):
        catalog = copy.deepcopy(load("catalog.json"))
        catalog["requirements"][-1] = catalog["requirements"][0]
        with self.assertRaises(ValueError):
            build(catalog, {"id": "core-lifecycle-v1", "assertions": []}, {"status": "pass", "errors": []}, {})

    def test_unknown_coverage_row(self):
        case = {
            "id": "core-lifecycle-v1",
            "assertions": [{"id": "test", "status": "pass"}],
            "coverage": {"unknown": {"case_id": "core-lifecycle-v1", "complete": False, "assertion_ids": ["test"]}},
        }
        with self.assertRaises(ValueError):
            build(load("catalog.json"), case, {"status": "pass", "errors": []}, {})

    def test_interrupt_no_completion(self):
        corpus = load("corpus/lifecycle.json")
        terminal = {"seq": 1, **event("control.terminal", {"issue_id": corpus["issue_id"]})}
        closed = {"seq": 4, **event("peer.closed", {"peer_id": "fixture-peer"})}
        request = self.rpc(2, "client", {"id": 1, "method": "turn/interrupt", "params": {
            "threadId": corpus["thread_id"], "turnId": corpus["turn_ids"][1]}})
        reply = self.rpc(3, "server", {"id": 1, "result": {}}, request_sequence=2)
        result = _interrupt_check([terminal, closed], [request, reply], corpus)
        self.assertEqual(result["status"], "fail")

    def test_turn_no_completion(self):
        corpus = load("corpus/lifecycle.json")
        frames = [
            self.rpc(1, "client", {"id": 1, "method": "thread/start", "params": {}}),
            self.rpc(2, "server", {"id": 1, "result": {"thread": {"id": corpus["thread_id"]}}}, request_sequence=1),
            self.rpc(3, "client", {"id": 2, "method": "turn/start", "params": {"threadId": corpus["thread_id"]}}),
            self.rpc(4, "server", {"id": 2, "result": {"turn": {"id": corpus["turn_ids"][0]}}}, request_sequence=3),
            self.rpc(5, "client", {"id": 3, "method": "turn/start", "params": {"threadId": corpus["thread_id"]}}),
            self.rpc(6, "server", {"id": 3, "result": {"turn": {"id": corpus["turn_ids"][1]}}}, request_sequence=5),
        ]
        result = next(item for item in _turn_checks(frames, corpus) if item["id"] == "turn.completion")
        self.assertEqual(result["status"], "fail")

    def test_workspace_retained(self):
        observations = [
            {"seq": 1, **event("workspace.created", {"path": "/fixture/root/HARNESS-1"})},
            {"seq": 2, **event("hook.exit", {"name": "before_remove", "outcome": "ok"})},
            {"seq": 3, **event("workspace.retained", {"path": "/fixture/root/HARNESS-1"})},
        ]
        self.assertEqual(_workspace_check(observations)["status"], "fail")

    def test_wrong_server_thread(self):
        corpus = load("corpus/lifecycle.json")
        frames = self.turn_frames(corpus)
        frames.append(self.rpc(8, "server", {"method": "turn/started", "params": {
            "threadId": corpus["thread_id"] + "-other", "turn": {"id": corpus["turn_ids"][1]}}}))
        self.assertEqual(_turn_checks(frames, corpus)[0]["status"], "fail")

    def test_wrong_server_turn(self):
        corpus = load("corpus/lifecycle.json")
        frames = self.turn_frames(corpus)
        frames.append(self.rpc(8, "server", {"method": "turn/started", "params": {
            "threadId": corpus["thread_id"], "turn": {"id": "unknown-turn"}}}))
        self.assertEqual(_turn_checks(frames, corpus)[0]["status"], "fail")

    def test_valid_wrong_policy(self):
        corpus = load("corpus/lifecycle.json")
        messages = [
            ("client", {"id": 1, "method": "initialize", "params": {
                "clientInfo": {"name": "fixture", "version": "1"}}}),
            ("server", {"id": 1, "result": {"userAgent": "fixture", "codexHome": "/fixture/root",
                "platformFamily": "unix", "platformOs": "macos"}}),
            ("client", {"method": "initialized"}),
            ("client", {"id": 2, "method": "thread/start", "params": {
                "approvalPolicy": "on-request", "sandbox": corpus["sandbox"]}}),
        ]
        observations = [event("peer." + direction, {"peer_id": "fixture-peer",
            "frame": base64.b64encode(json.dumps(frame).encode() + b"\n").decode()})
            for direction, frame in messages]
        self.write([*observations, event("peer.closed", {"peer_id": "fixture-peer"}), *cleanup()])
        report = judge(self.bundle)
        self.assertEqual(report["harness"]["status"], "pass")
        checks = {row["id"]: row for row in report["case"]["assertions"]}
        self.assertEqual(checks["protocol.startup"]["status"], "fail")
        self.assertEqual(checks["protocol.schema"]["status"], "pass")
        policy = next(row for row in report["requirements"] if row["requirement_id"] == "C17.5.policy")
        self.assertEqual(policy["verdict"], "fail")

    def test_reused_request_id(self):
        corpus = load("corpus/lifecycle.json")
        request_id = 1
        cwd = "/fixture/root/" + corpus["issue_identifier"]
        thread = {
            "id": corpus["thread_id"], "sessionId": "fixture-peer",
            "cliVersion": "0.159.2", "createdAt": 0, "updatedAt": 0,
            "cwd": cwd, "ephemeral": True, "modelProvider": "openai",
            "preview": "", "projectId": None, "source": "appServer",
            "status": {"type": "idle"}, "turns": [],
        }
        messages = [
            ("client", {"id": request_id, "method": "initialize", "params": {
                "clientInfo": {"name": "fixture", "version": "1"}}}),
            ("server", {"id": request_id, "result": {"userAgent": "fixture", "codexHome": cwd,
                "platformFamily": "unix", "platformOs": "macos"}}),
            ("client", {"method": "initialized"}),
            ("client", {"id": request_id, "method": "thread/start", "params": {
                "cwd": cwd, "approvalPolicy": corpus["approval_policy"], "sandbox": corpus["sandbox"]}}),
            ("server", {"id": request_id, "result": {
                "thread": thread, "cwd": cwd, "model": "fixture", "modelProvider": "openai",
                "approvalPolicy": corpus["approval_policy"], "approvalsReviewer": "user",
                "sandbox": {"type": "workspaceWrite", "writableRoots": [cwd],
                    "networkAccess": False, "excludeTmpdirEnvVar": False, "excludeSlashTmp": False}}}),
        ]
        for index, turn_id in enumerate(corpus["turn_ids"]):
            messages.extend([
                ("client", {"id": request_id, "method": "turn/start", "params": {
                    "threadId": corpus["thread_id"], "cwd": cwd,
                    "approvalPolicy": corpus["approval_policy"],
                    "input": [{"type": "text", "text": "fixture"}]}}),
                ("server", {"id": request_id, "result": {"turn": {
                    "id": turn_id, "items": [], "status": "inProgress", "error": None}}}),
            ])
            if index == 0:
                messages.append(("server", {"method": "turn/completed", "params": {
                    "threadId": corpus["thread_id"], "turn": {
                        "id": turn_id, "items": [], "status": "completed", "error": None}}}))
        messages.extend([
            ("client", {"id": request_id, "method": "turn/interrupt", "params": {
                "threadId": corpus["thread_id"], "turnId": corpus["turn_ids"][1]}}),
            ("server", {"id": request_id, "result": {}}),
            ("server", {"method": "turn/completed", "params": {
                "threadId": corpus["thread_id"], "turn": {
                    "id": corpus["turn_ids"][1], "items": [], "status": "interrupted", "error": None}}}),
        ])

        # Every reuse follows its own reply; the generated schemas remain valid.
        schema = Schema()
        pending = {}
        observations = []
        for direction, frame in messages:
            method = frame.get("method")
            if "id" in frame:
                if method is None:
                    method = pending.pop(frame["id"])
                else:
                    self.assertNotIn(frame["id"], pending)
                    pending[frame["id"]] = method
            schema.validate(frame, direction, method)
            if frame.get("method") == "turn/interrupt":
                observations.append(event("control.terminal", {"issue_id": corpus["issue_id"]}))
            observations.append(event("peer." + direction, {"peer_id": "fixture-peer",
                "frame": base64.b64encode(json.dumps(frame).encode() + b"\n").decode()}))
        self.assertFalse(pending)
        self.write([*observations, event("peer.closed", {"peer_id": "fixture-peer"}), *cleanup()])

        report = judge(self.bundle)
        self.assertEqual(report["harness"]["status"], "pass")
        checks = {row["id"]: row for row in report["case"]["assertions"]}
        self.assertEqual(checks["protocol.schema"]["status"], "pass")
        for name in ("protocol.startup", "turn.same_thread", "interrupt.completed"):
            with self.subTest(assertion=name):
                self.assertEqual(checks[name]["status"], "pass")

    def test_overlapping_request_id(self):
        result = {"userAgent": "fixture", "codexHome": "/fixture/root",
            "platformFamily": "unix", "platformOs": "macos"}
        for second_id, expected in ((1, "fail"), ("1", "pass")):
            with self.subTest(second_id=second_id):
                messages = [
                    ("client", {"id": 1, "method": "initialize", "params": {
                        "clientInfo": {"name": "fixture", "version": "1"}}}),
                    ("client", {"id": second_id, "method": "initialize", "params": {
                        "clientInfo": {"name": "fixture", "version": "1"}}}),
                    ("server", {"id": 1, "result": result}),
                ]
                if second_id != 1:
                    messages.append(("server", {"id": second_id, "result": result}))
                observations = [event("peer." + direction, {"peer_id": "fixture-peer",
                    "frame": base64.b64encode(json.dumps(frame).encode() + b"\n").decode()})
                    for direction, frame in messages]
                self.write([*observations, event("peer.closed", {"peer_id": "fixture-peer"}), *cleanup()])
                report = judge(self.bundle)
                self.assertEqual(report["harness"]["status"], "pass")
                schema = next(row for row in report["case"]["assertions"] if row["id"] == "protocol.schema")
                self.assertEqual(schema["status"], expected)
                if expected == "fail":
                    self.assertIn("duplicate outstanding request ID", schema["reason"])

    def tracker_trace(self, body=None):
        corpus = load("corpus/lifecycle.json")
        if body is None:
            body = json.dumps({"query": "query Fixture($filter: IssueFilter!) { issues(first: 1, filter: $filter) { nodes { id identifier title state { name } } } }",
                "variables": {"filter": {"id": {"in": [corpus["issue_id"]]}}}}).encode()
        request = {"request_id": "raw-request-1", "method": corpus["tracker_method"],
            "target": corpus["tracker_target"], "headers": [[corpus["tracker_auth_header"], corpus["fake_secret"]],
                ["Content-Type", "application/json"], ["Content-Length", str(len(body))]],
            "body": base64.b64encode(body).decode()}
        payload = json.dumps({"data": {"issues": {"nodes": [{"id": corpus["issue_id"],
            "identifier": corpus["issue_identifier"], "title": corpus["issue_title"],
            "state": {"name": corpus["terminal_state"]}}]}}}).encode()
        response = {"request_id": request["request_id"], "status": HTTPStatus.OK,
            "headers": [["Content-Type", "application/json"], ["Content-Length", str(len(payload))],
                ["Connection", "close"]], "body": base64.b64encode(payload).decode()}
        return [event("control.terminal", {"issue_id": corpus["issue_id"]}),
                event("provider.request", request), event("provider.response", response), *cleanup()]

    def rejected_request(self, observations):
        payload = json.dumps({"errors": [{"message": "Rejected candidate request"}]}).encode()
        observations[2]["data"].update(status=HTTPStatus.BAD_REQUEST, body=base64.b64encode(payload).decode(),
            headers=[["Content-Type", "application/json"], ["Content-Length", str(len(payload))], ["Connection", "close"]])
        self.write(observations)
        report = judge(self.bundle)
        self.assertEqual(report["harness"]["status"], "pass")
        check = next(row for row in report["case"]["assertions"] if row["id"] == "tracker.terminal_refresh")
        self.assertEqual(check["status"], "fail")

    def test_valid_tracker_refresh(self):
        self.write(self.tracker_trace())
        report = judge(self.bundle)
        self.assertEqual(report["harness"]["status"], "pass")
        check = next(row for row in report["case"]["assertions"] if row["id"] == "tracker.terminal_refresh")
        self.assertEqual(check["status"], "pass")

    def test_bad_request_json(self):
        self.rejected_request(self.tracker_trace(b'{"query":'))

    def test_bad_request_graphql(self):
        for query in ("query {", "query { viewer { id } }"):
            with self.subTest(query=query):
                self.rejected_request(self.tracker_trace(json.dumps({"query": query}).encode()))

    def test_nonobject_request(self):
        self.rejected_request(self.tracker_trace(b"[]"))

    def test_wrong_request_metadata(self):
        for field, value in (("method", "GET"), ("target", "/wrong"), ("auth", "wrong-key")):
            with self.subTest(field=field):
                observations = self.tracker_trace()
                if field == "auth":
                    observations[1]["data"]["headers"][0][1] = value
                else:
                    observations[1]["data"][field] = value
                self.rejected_request(observations)

    def test_corrupt_response_body(self):
        observations = self.tracker_trace()
        raw = b'{"data":'
        response = observations[2]["data"]
        response["body"] = base64.b64encode(raw).decode()
        next(pair for pair in response["headers"] if pair[0] == "Content-Length")[1] = str(len(raw))
        self.write(observations)
        self.assert_bad_bundle()

    def test_bad_response_metadata(self):
        for field, value in (("status", "not-a-status"), ("headers", "not-header-pairs")):
            with self.subTest(field=field):
                observations = self.tracker_trace()
                observations[2]["data"][field] = value
                self.write(observations)
                self.assert_bad_bundle()

    def test_response_before_request(self):
        observations = self.tracker_trace()
        observations[1], observations[2] = observations[2], observations[1]
        self.write(observations)
        self.assert_bad_bundle()

    def test_response_header_contract(self):
        for name, value in (("Content-Length", "0"), ("Content-Type", "text/plain"), ("Connection", "keep-alive")):
            with self.subTest(header=name):
                observations = self.tracker_trace()
                headers = observations[2]["data"]["headers"]
                next(pair for pair in headers if pair[0] == name)[1] = value
                self.write(observations)
                self.assert_bad_bundle()

    def test_request_length_mismatch(self):
        observations = self.tracker_trace()
        request = observations[1]["data"]
        header = next(pair for pair in request["headers"] if pair[0] == "Content-Length")
        header[1] = str(len(base64.b64decode(request["body"])) + 1)
        self.rejected_request(observations)

    def turn_frames(self, corpus):
        return [
            self.rpc(1, "client", {"id": 1, "method": "thread/start", "params": {}}),
            self.rpc(2, "server", {"id": 1, "result": {"thread": {"id": corpus["thread_id"]}}}, request_sequence=1),
            self.rpc(3, "client", {"id": 2, "method": "turn/start", "params": {"threadId": corpus["thread_id"]}}),
            self.rpc(4, "server", {"id": 2, "result": {"turn": {"id": corpus["turn_ids"][0]}}}, request_sequence=3),
            self.rpc(5, "server", {"method": "turn/completed", "params": {
                "threadId": corpus["thread_id"], "turn": {"id": corpus["turn_ids"][0], "status": "completed"}}}),
            self.rpc(6, "client", {"id": 3, "method": "turn/start", "params": {"threadId": corpus["thread_id"]}}),
            self.rpc(7, "server", {"id": 3, "result": {"turn": {"id": corpus["turn_ids"][1]}}}, request_sequence=6),
        ]

    def rpc(self, sequence, direction, frame, request_sequence=None):
        return {"direction": direction, "frame": frame, "method": frame.get("method"),
                "request_seq": request_sequence,
                "event": {"seq": sequence, **event("peer." + direction, {"peer_id": "fixture-peer"})}}


if __name__ == "__main__":
    unittest.main()
