import os
import http.client
import json
import ssl
from enum import Enum
from http import HTTPStatus
from pathlib import Path
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

from symphony_conformance.driver.process import Process
from symphony_conformance.assets import load, resource
from symphony_conformance.driver.journal import Journal
from symphony_conformance.driver.tracker import Tracker

CHILD_BUDGET = 6
EXPIRY_BUDGET = 10
FLOOD_REQUESTS = 64
DIAGNOSTIC_LIMIT = 16 * 1024
DIAGNOSTIC_TAIL = 2 * 1024
DIAGNOSTIC_PHASES = 8
DIAGNOSTIC_SCALAR = 128
FILTER_QUERY = "query Pick($filter: IssueFilter!) { issues(first: 1, filter: $filter) { nodes { id } } }"


class Input(Enum):
    HEADERS = "headers"
    BODY = "body"


class Action(Enum):
    CLOSE = "close"
    EXPIRE = "expire"


class TrackerTest(unittest.TestCase):
    def test_bad_logical_values(self):
        filters = [
            {"or": [None]}, {"and": [[]]}, {"or": [5]}, {"and": ["bad"]},
            {"and": [False]}, {"or": [{"and": [None]}]},
            {"and": [{"or": [["bad"]]}]},
        ]
        self.filter_requests(filters, HTTPStatus.BAD_REQUEST)

    def test_hidden_filter_errors(self):
        corpus = load("corpus/lifecycle.json")
        hit = {"id": {"eq": corpus["issue_id"]}}
        missing_id = corpus["issue_id"] + "-missing"
        miss = {"id": {"eq": missing_id}}
        invalid = [
            {"id": {"guess": "bad"}}, {"or": [None]},
            {"project": {"name": None}}, {"state": {"name": {"eq": None}}},
            {"project": {"guess": {"eq": "bad"}}},
        ]
        filters = [{"or": [hit, value]} for value in invalid]
        filters.extend({"and": [miss, value]} for value in invalid)
        filters.extend([
            {"id": {"eq": missing_id, "guess": "bad"}},
            {"id": {"eq": missing_id, "in": [None]}},
            {"id": {"eq": missing_id, "eqIgnoreCase": None}},
            {"id": {"eq": missing_id}, "guess": {}},
            {"state": {"name": {"eq": "missing-state"}, "guess": {"eq": "bad"}}},
        ])
        self.filter_requests(filters, HTTPStatus.BAD_REQUEST)

    def test_bad_comparison_values(self):
        filters = [{"id": {operator: value}} for operator, value in (
            ("eq", None), ("eq", 5), ("eq", False), ("eq", []), ("eq", {}),
            ("eqIgnoreCase", None), ("eqIgnoreCase", 5),
            ("in", None), ("in", "bad"), ("in", ["valid", None]),
        )]
        filters.extend([{"id": {}}, {"project": {"name": {}}}])
        self.filter_requests(filters, HTTPStatus.BAD_REQUEST)

    def test_valid_logical_filters(self):
        corpus = load("corpus/lifecycle.json")
        hit = {"id": {"eq": corpus["issue_id"]}}
        miss = {"id": {"eq": corpus["issue_id"] + "-missing"}}
        payloads = self.filter_requests([
            {"or": [hit, miss]}, {"and": [miss, hit]},
            {"and": [hit, {}]}, {"id": {"in": []}},
            {}, {"project": {}}, {"state": {}},
        ], HTTPStatus.OK)
        self.assertEqual([[node["id"] for node in value["data"]["issues"]["nodes"]]
                          for value in payloads], [[corpus["issue_id"]], [], [corpus["issue_id"]], [],
                              [corpus["issue_id"]], [corpus["issue_id"]], [corpus["issue_id"]]])

    def filter_requests(self, filters, status):
        with tempfile.TemporaryDirectory() as directory:
            corpus = load("corpus/lifecycle.json")
            journal = Journal(Path(directory))
            tracker = Tracker(corpus, journal, str(resource("tls/server.pem")),
                              str(resource("tls/server.key")))
            authority = tracker.endpoint.split("/")[2]
            context = ssl.create_default_context(cafile=str(resource("tls/ca.pem")))
            payloads = []
            try:
                # Reject malformed predicates even when issue evaluation could skip them.
                for query in filters:
                    with self.subTest(filter=query):
                        client = http.client.HTTPSConnection(authority, timeout=2, context=context)
                        try:
                            body = json.dumps({"query": FILTER_QUERY, "variables": {"filter": query}})
                            client.request("POST", "/graphql", body,
                                           {"Authorization": corpus["fake_secret"], "Content-Type": "application/json"})
                            response = client.getresponse()
                            payload = json.loads(response.read())
                            payloads.append(payload)
                            self.assertEqual(response.status, status)
                            if status == HTTPStatus.BAD_REQUEST:
                                self.assertTrue(payload.get("errors"))
                        finally:
                            client.close()
                with self.subTest(stage="fixture-health"):
                    self.assertEqual(tracker.errors(), [])
            finally:
                tracker.close()
                journal.close()
            with self.subTest(stage="fixture-closure"):
                self.assertEqual(journal.rows("provider.closed")[0]["data"]["status"], "ok")
            self.assertEqual(len(journal.rows("provider.request")), len(filters))
            self.assertEqual(len(journal.rows("provider.response")), len(filters))
            return payloads

    def test_bounded_rejections(self):
        with tempfile.TemporaryDirectory() as directory:
            corpus = load("corpus/lifecycle.json")
            journal = Journal(Path(directory))
            tracker = Tracker(corpus, journal, str(resource("tls/server.pem")),
                              str(resource("tls/server.key")))
            authority = tracker.endpoint.split("/")[2]
            context = ssl.create_default_context(cafile=str(resource("tls/ca.pem")))
            body = json.dumps({"query": "?" + "x" * 8192})
            try:
                for _ in range(FLOOD_REQUESTS):
                    client = http.client.HTTPSConnection(authority, timeout=2, context=context)
                    client.request("POST", "/graphql", body,
                                   {"Authorization": corpus["fake_secret"]})
                    response = client.getresponse()
                    self.assertEqual(response.status, HTTPStatus.BAD_REQUEST)
                    response.read()
                    client.close()
                valid = json.dumps({"query": "{issues{nodes{id}}}"})
                cases = (("POST", "/wrong", corpus["fake_secret"]),
                         ("POST", "/graphql", "wrong-fake-credential"),
                         ("GET", "/graphql", corpus["fake_secret"]))
                for method, target, credential in cases:
                    client = http.client.HTTPSConnection(authority, timeout=2, context=context)
                    client.request(method, target, valid, {"Authorization": credential})
                    response = client.getresponse()
                    self.assertEqual(response.status, HTTPStatus.BAD_REQUEST)
                    response.read()
                    client.close()
                self.assertEqual(tracker.errors(), [])
            finally:
                tracker.close()
                journal.close()
            self.assertEqual(len(journal.rows("provider.request")), FLOOD_REQUESTS + len(cases))
            self.assertEqual(journal.rows("provider.closed")[0]["data"]["status"], "ok")

    def test_bounded_recorder_errors(self):
        with tempfile.TemporaryDirectory() as directory:
            corpus = load("corpus/lifecycle.json")
            journal = Journal(Path(directory))
            tracker = Tracker(corpus, journal, str(resource("tls/server.pem")),
                              str(resource("tls/server.key")))
            authority = tracker.endpoint.split("/")[2]
            context = ssl.create_default_context(cafile=str(resource("tls/ca.pem")))
            emit = journal.emit

            def broken(kind, *args):
                if kind == "provider.request":
                    raise RuntimeError("recorder failed: " + "x" * 8192)
                return emit(kind, *args)

            try:
                with patch.object(journal, "emit", broken):
                    for _ in range(FLOOD_REQUESTS):
                        client = http.client.HTTPSConnection(authority, timeout=2, context=context)
                        client.request("POST", "/graphql", '{}',
                                       {"Authorization": corpus["fake_secret"]})
                        response = client.getresponse()
                        self.assertEqual(response.status, HTTPStatus.BAD_REQUEST)
                        response.read()
                        client.close()
                self.assertLess(len(json.dumps(tracker.errors())), DIAGNOSTIC_LIMIT)
                self.assertTrue(tracker.errors())
            finally:
                tracker.close()
                journal.close()
            self.assertEqual(journal.rows("provider.closed")[0]["data"]["status"], "error")

    def _child_note(self, error, phase, snapshot):
        try:
            value = snapshot()
            if not isinstance(value, dict):
                return

            def select(row, keys):
                return {key: row[key][:DIAGNOSTIC_SCALAR] if isinstance(row[key], str) else row[key]
                        for key in keys if key in row and type(row[key]) in (str, int, bool, type(None))}

            note = {"phase": phase, **select(value, ("pid", "guard_pid", "returncode", "closed", "reaped"))}
            note["eof"] = [name for name in ("stderr", "stdout") if name in value.get("eof", ())]
            note["failures"] = [select(row, ("stage", "class"))
                                for row in value.get("failures", ())[-DIAGNOSTIC_PHASES:]]
            note["lifecycle"] = [select(row, ("kind", "operation", "stage", "status", "forced"))
                                 for row in value.get("lifecycle", ())[-DIAGNOSTIC_PHASES:]]
            for stream in ("stdout", "stderr"):
                raw = value.get(stream, b"")
                if type(raw) is bytes:
                    note[stream + "_tail"] = raw[-DIAGNOSTIC_TAIL:].decode("utf-8", errors="replace")
            BaseException.add_note(error, "Fixture child: " + json.dumps(note, ensure_ascii=False)[:DIAGNOSTIC_LIMIT])
        except BaseException:
            # Diagnostics must preserve the original join or cleanup failure.
            pass

    def child(self, body, budget=CHILD_BUDGET):
        flags = ["-" + "O" * min(sys.flags.optimize, 2)] if sys.flags.optimize else []
        with tempfile.TemporaryDirectory() as directory:
            try:
                with Process([sys.executable, *flags, "-c", body], cwd=Path(directory),
                             env=dict(os.environ), output_limit=65536,
                             deadline=time.monotonic() + budget) as child:
                    try:
                        status = child.join(budget - 1)
                    except BaseException as error:
                        self._child_note(error, "pre-cleanup", child.snapshot)
                        raise
                    self.assertEqual(status, 0, child.snapshot()["stderr"].decode("utf-8", errors="replace"))
                    self.assertEqual(child.snapshot()["stderr"], b"")
            except BaseException as error:
                self._child_note(error, "post-cleanup", lambda: getattr(error, "_process_snapshot", None))
                raise

    def test_idle_tls_admission(self):
        self.child('''
import socket
from pathlib import Path
from symphony_conformance.assets import load, resource
from symphony_conformance.driver.journal import Journal
from symphony_conformance.driver.tracker import Tracker
journal = Journal(Path.cwd())
tracker = Tracker(load('corpus/lifecycle.json'), journal, str(resource('tls/server.pem')), str(resource('tls/server.key')))
client = socket.create_connection(('127.0.0.1', int(tracker.endpoint.split(':')[2].split('/')[0])), timeout=1)
client.sendall(b'\\x16')
tracker.close()
client.close()
journal.close()
''')

    def test_drip_close(self):
        self.drip_close(Input.BODY)

    def test_header_close(self):
        self.drip_close(Input.HEADERS)

    def test_body_expiry(self):
        self.drip_close(Input.BODY, Action.EXPIRE)

    def test_header_expiry(self):
        self.drip_close(Input.HEADERS, Action.EXPIRE)

    def drip_close(self, stage, action=Action.CLOSE):
        self.child('''
import http.client
import json
import socket
import ssl
import threading
import time
from http import HTTPStatus
from pathlib import Path
from symphony_conformance.assets import load, resource
from symphony_conformance.driver.journal import Journal
from symphony_conformance.driver import tracker as driver

CLOSE_BUDGET = 1
JOIN_BUDGET = 2
DRIP_INTERVAL = 0.05
stage = STAGE_VALUE
action = ACTION_VALUE
corpus = load('corpus/lifecycle.json')
journal = Journal(Path.cwd())
tracker = driver.Tracker(corpus, journal, str(resource('tls/server.pem')), str(resource('tls/server.key')))
admitted = threading.Event()
admitted_at = [None]
stop = threading.Event()
if stage == 'body':
    original = tracker._request
    def request(handler):
        admitted_at[0] = time.monotonic()
        admitted.set()
        original(handler)
    tracker._request = request
else:
    original = tracker._server.get_request
    def request():
        connection = original()
        admitted_at[0] = time.monotonic()
        admitted.set()
        return connection
    tracker._server.get_request = request
port = int(tracker.endpoint.split(':')[2].split('/')[0])
context = ssl.create_default_context(cafile=str(resource('tls/ca.pem')))
client = context.wrap_socket(socket.create_connection(('127.0.0.1', port), timeout=1), server_hostname='127.0.0.1')
if stage == 'body':
    client.sendall(('POST /graphql HTTP/1.1\\r\\nHost: 127.0.0.1\\r\\nAuthorization: '
                    + corpus['fake_secret'] + '\\r\\nContent-Length: ' + str(driver.MAX_BODY)
                    + '\\r\\nConnection: close\\r\\n\\r\\n{').encode())
else:
    client.sendall(b'POST /graphql HTTP/1.1\\r\\nHost: 127.0.0.1\\r\\nX-Drip: ')

def drip():
    while not stop.wait(DRIP_INTERVAL):
        try:
            client.sendall(b' ')
        except OSError:
            return

failures = []

def close():
    try:
        tracker.close()
    except BaseException as error:
        failures.append(type(error).__name__)

writer = threading.Thread(target=drip, daemon=True)
closer = threading.Thread(target=close, daemon=True)
try:
    if not admitted.wait(CLOSE_BUDGET):
        raise RuntimeError('HTTP connection was not admitted')
    if action == 'close':
        writer.start()
        closer.start()
        closer.join(CLOSE_BUDGET)
        if closer.is_alive():
            raise RuntimeError('Tracker.close did not stop an admitted drip connection within its budget')
    else:
        end = admitted_at[0] + driver.SOCKET_TIMEOUT + CLOSE_BUDGET
        client.settimeout(DRIP_INTERVAL)
        expired = None
        while time.monotonic() < end:
            try:
                # One owner alternates TLS writes and reads; each read paces the drip.
                client.sendall(b' ')
                data = client.recv(4096)
                if data:
                    raise RuntimeError('Tracker answered an incomplete request: ' + repr(data))
                expired = 'EOF'
            except socket.timeout:
                continue
            except (ConnectionResetError, ConnectionAbortedError, BrokenPipeError,
                    ssl.SSLEOFError, ssl.SSLZeroReturnError) as error:
                expired = repr(error)
            break
        elapsed = time.monotonic() - admitted_at[0]
        if expired is None:
            raise RuntimeError('Tracker drip traffic renewed the total connection deadline after '
                               + str(elapsed) + ' s')
        # Admission follows TLS negotiation; allow its existing bounded budget.
        if elapsed < driver.SOCKET_TIMEOUT - CLOSE_BUDGET:
            raise RuntimeError('Tracker disconnected before its deadline after '
                               + str(elapsed) + ' s: ' + expired)
        fresh = http.client.HTTPSConnection('127.0.0.1', port, context=context, timeout=CLOSE_BUDGET)
        try:
            fresh.request('POST', '/graphql', json.dumps({'query': '{issues(first:1,filter:{}){nodes{id}}}'}),
                          {'Authorization': corpus['fake_secret']})
            response = fresh.getresponse()
            response.read()
            if response.status != HTTPStatus.OK:
                raise RuntimeError('Tracker did not admit a healthy request after expiry')
        except Exception as error:
            raise RuntimeError('Tracker healthy probe failed after expiry at '
                               + str(elapsed) + ' s: ' + expired) from error
        finally:
            fresh.close()
finally:
    # Release the old blocking handler even when the bounded assertion fails.
    stop.set()
    try:
        client.shutdown(socket.SHUT_RDWR)
    except OSError:
        pass
    client.close()
    if writer.ident is not None:
        writer.join(CLOSE_BUDGET)
    if closer.ident is not None:
        closer.join(JOIN_BUDGET)
    else:
        tracker.close()
    journal.close()

if closer.is_alive() or writer.is_alive():
    raise RuntimeError('Tracker regression cleanup did not join its threads')
if failures or tracker.errors():
    raise RuntimeError('Owner cancellation became a fixture failure: ' + str(failures + tracker.errors()))
if journal.rows('provider.closed')[0]['data']['status'] != 'ok':
    raise RuntimeError('Owner cancellation emitted an error closure receipt')
'''.replace('STAGE_VALUE', repr(stage.value)).replace('ACTION_VALUE', repr(action.value)),
                   CHILD_BUDGET if action is Action.CLOSE else EXPIRY_BUDGET)

    def test_failed_admission_recorder(self):
        self.child('''
import threading
from symphony_conformance.assets import load, resource
from symphony_conformance.driver.tracker import Tracker
class Recorder:
    def emit(self, *args):
        raise RuntimeError('recorder failure')
try:
    Tracker(load('corpus/lifecycle.json'), Recorder(), str(resource('tls/server.pem')), str(resource('tls/server.key')))
except RuntimeError:
    pass
else:
    raise RuntimeError('lost recorder failure')
if any(thread.name == 'fixture-tracker' for thread in threading.enumerate()):
    raise RuntimeError('tracker thread escaped constructor')
''')


if __name__ == "__main__":
    unittest.main()
