import os
import http.client
import json
from enum import Enum
from http import HTTPStatus
from pathlib import Path
import tempfile
import sys
import time
import unittest
from unittest.mock import patch

from symphony_conformance.driver.journal import Journal, seal
from symphony_conformance.driver.process import Process

CHILD_BUDGET = 6
EXPIRY_BUDGET = 10
FLOOD_REQUESTS = 64
DIAGNOSTIC_LIMIT = 16 * 1024


class Input(Enum):
    HEADERS = "headers"
    BODY = "body"


class Action(Enum):
    CLOSE = "close"
    EXPIRE = "expire"


class JournalTest(unittest.TestCase):
    def test_drip_close(self):
        self.drip_close(Input.BODY)

    def test_header_close(self):
        self.drip_close(Input.HEADERS)

    def test_body_expiry(self):
        self.drip_close(Input.BODY, Action.EXPIRE)

    def test_header_expiry(self):
        self.drip_close(Input.HEADERS, Action.EXPIRE)

    def drip_close(self, stage, action=Action.CLOSE):
        script = '''
import http.client
import json
import socket
import threading
import time
from http import HTTPStatus
from pathlib import Path
from symphony_conformance.driver import journal as driver

CLOSE_BUDGET = 1
JOIN_BUDGET = 2
DRIP_INTERVAL = 0.05
stage = STAGE_VALUE
action = ACTION_VALUE
journal = driver.Journal(Path.cwd())
url = journal.start()
admitted = threading.Event()
admitted_at = [None]
stop = threading.Event()
if stage == 'body':
    handler = journal._server.RequestHandlerClass
    original = handler.do_POST
    def request(self):
        admitted_at[0] = time.monotonic()
        admitted.set()
        original(self)
    handler.do_POST = request
else:
    original = journal._server.get_request
    def request():
        connection = original()
        admitted_at[0] = time.monotonic()
        admitted.set()
        return connection
    journal._server.get_request = request

port = int(url.split(':')[2].split('/')[0])
client = socket.create_connection(('127.0.0.1', port), timeout=1)
if stage == 'body':
    client.sendall(('POST /event HTTP/1.1\\r\\nHost: 127.0.0.1\\r\\nContent-Length: '
                    + str(driver.MAX_EVENT_BYTES) + '\\r\\nConnection: close\\r\\n\\r\\n{').encode())
else:
    client.sendall(b'POST /event HTTP/1.1\\r\\nHost: 127.0.0.1\\r\\nX-Drip: ')

def drip():
    while not stop.wait(DRIP_INTERVAL):
        try:
            client.sendall(b' ')
        except OSError:
            return

failures = []
def close():
    try:
        journal.close()
    except BaseException as error:
        failures.append(type(error).__name__)

writer = threading.Thread(target=drip, daemon=True)
closer = threading.Thread(target=close, daemon=True)
try:
    if not admitted.wait(CLOSE_BUDGET):
        raise RuntimeError('Collector HTTP connection was not admitted')
    if action == 'close':
        writer.start()
        closer.start()
        closer.join(CLOSE_BUDGET)
        if closer.is_alive():
            raise RuntimeError('Journal.close did not stop an admitted drip connection within its budget')
    else:
        end = admitted_at[0] + driver.SOCKET_TIMEOUT + CLOSE_BUDGET
        client.settimeout(DRIP_INTERVAL)
        expired = None
        while time.monotonic() < end:
            try:
                # Keep writes and reads on one owner; each read paces the drip.
                client.sendall(b' ')
                data = client.recv(4096)
                if data:
                    raise RuntimeError('Collector answered an incomplete request: ' + repr(data))
                expired = 'EOF'
            except socket.timeout:
                continue
            except (ConnectionResetError, ConnectionAbortedError, BrokenPipeError) as error:
                expired = repr(error)
            break
        elapsed = time.monotonic() - admitted_at[0]
        if expired is None:
            raise RuntimeError('Collector drip traffic renewed the total connection deadline after '
                               + str(elapsed) + ' s')
        if elapsed < driver.SOCKET_TIMEOUT - CLOSE_BUDGET:
            raise RuntimeError('Collector disconnected before its deadline after '
                               + str(elapsed) + ' s: ' + expired)
        fresh = http.client.HTTPConnection('127.0.0.1', port, timeout=CLOSE_BUDGET)
        try:
            fresh.request('POST', '/event', json.dumps({'origin': 'fixture', 'kind': 'expiry.probe', 'data': {}}))
            response = fresh.getresponse()
            response.read()
            if response.status != HTTPStatus.NO_CONTENT:
                raise RuntimeError('Collector did not admit a healthy event after expiry')
        except Exception as error:
            raise RuntimeError('Collector healthy probe failed after expiry at '
                               + str(elapsed) + ' s: ' + expired) from error
        finally:
            fresh.close()
finally:
    # Release the old blocking handler; outer Process custody bounds all threads.
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
        journal.close()

if closer.is_alive() or writer.is_alive():
    raise RuntimeError('Collector regression cleanup did not join its threads')
if failures or journal.errors():
    raise RuntimeError('Owner cancellation became a collector failure: ' + str(failures + journal.errors()))
if not journal._file.closed or journal.rows('collector.closed')[0]['data']['errors']:
    raise RuntimeError('Collector cancellation did not retain a clean closed receipt')
'''.replace('STAGE_VALUE', repr(stage.value)).replace('ACTION_VALUE', repr(action.value))
        budget = CHILD_BUDGET if action is Action.CLOSE else EXPIRY_BUDGET
        flags = ["-" + "O" * min(sys.flags.optimize, 2)] if sys.flags.optimize else []
        with tempfile.TemporaryDirectory() as directory:
            with Process([sys.executable, *flags, "-c", script], cwd=Path(directory),
                         env=dict(os.environ), output_limit=65536,
                         deadline=time.monotonic() + budget) as child:
                status = child.join(budget - 1)
                self.assertEqual(status, 0, child.snapshot()["stderr"].decode("utf-8", errors="replace"))
                self.assertEqual(child.snapshot()["stderr"], b"")

    def test_bounded_rejections(self):
        with tempfile.TemporaryDirectory() as directory:
            journal = Journal(Path(directory))
            endpoint = journal.start()
            authority = endpoint.split("/")[2]
            key = "x" * 8192
            body = json.dumps({key: 1})[:-1] + "," + json.dumps(key) + ":2}"
            try:
                for _ in range(FLOOD_REQUESTS):
                    client = http.client.HTTPConnection(authority, timeout=2)
                    client.request("POST", "/event", body)
                    response = client.getresponse()
                    self.assertEqual(response.status, HTTPStatus.BAD_REQUEST)
                    response.read()
                    client.close()
                self.assertLess(len(json.dumps(journal.errors())), DIAGNOSTIC_LIMIT)
                self.assertTrue(journal.errors())
            finally:
                journal.close()

    def test_full_recorder_closes_file(self):
        with tempfile.TemporaryDirectory() as directory:
            opened = []
            original = Path.open

            def tracked(path, *args, **kwargs):
                file = original(path, *args, **kwargs)
                opened.append(file.fileno())
                return file

            with patch.object(Path, "open", tracked):
                journal = Journal(Path(directory))
            with patch("symphony_conformance.driver.journal.MAX_EVENTS", 1):
                journal.emit("control.fixture", {})
                with self.assertRaises(Exception):
                    journal.close()
            with self.assertRaises(OSError):
                os.fstat(opened[0])

    def test_sparse_file_budget(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with (root / "retained.bin").open("wb") as file:
                file.truncate(9 * 1024 * 1024)
            with self.assertRaises(ValueError):
                seal(root, {})


if __name__ == "__main__":
    unittest.main()
