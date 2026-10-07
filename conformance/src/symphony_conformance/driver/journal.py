"""Serialize bounded evidence at one collector clock and sequence."""

import base64
import hashlib
import json
import os
import stat
import threading
import time
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler

from ..assets import decode
from .errors import Failures
from .server import Server

MAX_EVENTS = 8192
MAX_EVENT_BYTES = 1024 * 1024
MAX_JOURNAL_BYTES = 16 * 1024 * 1024
SOCKET_TIMEOUT = 5
JOIN_TIMEOUT = 5
MAX_FILE_BYTES = 8 * 1024 * 1024
MAX_BUNDLE_BYTES = 64 * 1024 * 1024
MAX_ENTRIES = 2048
HASH_CHUNK = 64 * 1024
MAX_ABORT_PREFIX = 64 * 1024


class Journal:
    def __init__(self, root):
        self._path = root / "events.jsonl"
        self._file = self._path.open("xb")
        self._start = time.monotonic_ns()
        self._rows = []
        self._bytes = 0
        self._lock = threading.Condition()
        self._errors = Failures()
        self._server = None
        self._thread = None
        self._closed = False

    def emit(self, kind, data, origin="executor"):
        with self._lock:
            if self._closed:
                raise ValueError("Journal admission is closed")
            row = {"seq": len(self._rows) + 1,
                   "at_ns": time.monotonic_ns() - self._start,
                   "origin": origin, "kind": kind, "data": data}
            raw = json.dumps(row, separators=(",", ":"), allow_nan=False).encode() + b"\n"
            if len(raw) > MAX_EVENT_BYTES or len(self._rows) >= MAX_EVENTS:
                raise ValueError("Evidence event budget exceeded")
            if len(raw) > MAX_JOURNAL_BYTES - self._bytes:
                raise ValueError("Evidence journal budget exceeded")
            self._file.write(raw)
            self._file.flush()
            self._bytes += len(raw)
            self._rows.append(decode(raw))
            self._lock.notify_all()
            return row["seq"]

    def rows(self, kind=None):
        with self._lock:
            return [decode(json.dumps(row)) for row in self._rows
                    if kind is None or row["kind"] == kind]

    def wait(self, predicate, timeout):
        deadline = time.monotonic() + timeout
        with self._lock:
            while not predicate():
                if self._errors.samples():
                    raise RuntimeError("Evidence collector failed: " + str(self._errors.samples()))
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise TimeoutError("Evidence observation deadline expired")
                self._lock.wait(min(remaining, 0.1))

    def start(self):
        owner = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def setup(self):
                super().setup()
                self.connection.settimeout(SOCKET_TIMEOUT)

            def log_message(self, *_args):
                return

            def do_POST(self):
                self.close_connection = True
                if owner._server.aborted(self.connection):
                    owner._aborted_body(b"")
                    return
                raw = b""
                try:
                    lengths = self.headers.get_all("Content-Length", [])
                    if self.path != "/event" or len(lengths) != 1:
                        raise ValueError("Invalid collector request")
                    size = int(lengths[0])
                    if not 0 < size <= MAX_EVENT_BYTES:
                        raise ValueError("Collector request budget exceeded")
                    raw = self.rfile.read(size)
                    if len(raw) != size:
                        if owner._server.aborted(self.connection):
                            owner._aborted_body(raw)
                            return
                        raise ValueError("Truncated collector request")
                except (OSError, ValueError, TypeError) as failure:
                    if isinstance(failure, OSError) and owner._server.aborted(self.connection):
                        return
                    owner._failure("collector request", failure)
                    status = HTTPStatus.BAD_REQUEST
                else:
                    try:
                        row = decode(raw)
                        if set(row) != {"origin", "kind", "data"}:
                            raise ValueError("Invalid collector event shape")
                        owner.emit(row["kind"], row["data"], origin=row["origin"])
                        status = HTTPStatus.NO_CONTENT
                    except Exception as failure:
                        owner._failure("collector event", failure)
                        status = HTTPStatus.BAD_REQUEST
                if owner._server.aborted(self.connection):
                    return
                try:
                    self.send_response(status)
                    self.send_header("Content-Length", "0")
                    self.send_header("Connection", "close")
                    self.end_headers()
                except OSError as failure:
                    if not owner._server.aborted(self.connection):
                        owner._failure("collector response", failure)

        # One collector thread bounds admission and serializes child witnesses.
        self._server = Server(("127.0.0.1", 0), Handler, SOCKET_TIMEOUT, self._failure)
        self._thread = threading.Thread(target=self._server.serve_forever,
                                        name="conformance-evidence")
        try:
            self._thread.start()
        except BaseException:
            self._server.server_close()
            self._server = self._thread = None
            raise
        port = self._server.server_address[1]
        self.emit("collector.started", {"host": "127.0.0.1", "port": port})
        return f"http://127.0.0.1:{port}/event"

    def _aborted_body(self, raw):
        try:
            self.emit("collector.request_aborted", {
                "body_bytes": len(raw), "body_sha256": hashlib.sha256(raw).hexdigest(),
                "prefix_b64": base64.b64encode(raw[:MAX_ABORT_PREFIX]).decode("ascii"),
                "prefix_bytes": min(len(raw), MAX_ABORT_PREFIX)}, "collector")
        except Exception as error:
            self._failure("collector abort receipt", error)

    def _failure(self, stage, error):
        with self._lock:
            self._errors.record(stage + ": " + type(error).__name__)
            self._lock.notify_all()

    def close(self):
        if self._closed:
            return
        primary = None

        def attempt(label, action):
            nonlocal primary
            try:
                action()
            except BaseException as error:
                self._errors.record(label + ": " + type(error).__name__)
                if primary is None:
                    primary = error

        if self._server is not None:
            attempt("collector server", self._server.close)
            attempt("collector join", lambda: self._thread.join(JOIN_TIMEOUT))
            if self._thread.is_alive():
                self._errors.record("Evidence collector thread did not join")
        attempt("collector receipt", lambda: self.emit("collector.closed", {"errors": self._errors.samples()}))
        with self._lock:
            self._closed = True
            attempt("journal file", self._file.close)
        if primary is not None:
            raise primary

    def errors(self):
        with self._lock:
            return self._errors.samples()


def seal(root, metadata):
    """Hash retained bytes only after every resource has closed."""
    inventory = {}
    total = 0
    entries = 0
    directories = [root]
    while directories:
        directory = directories.pop()
        with os.scandir(directory) as paths:
            for entry in paths:
                entries += 1
                if entries > MAX_ENTRIES:
                    raise ValueError("Evidence entry budget exceeded")
                if entry.is_symlink():
                    raise ValueError("Symlink in evidence bundle")
                path = directory / entry.name
                if entry.is_dir(follow_symlinks=False):
                    directories.append(path)
                    continue
                if path == root / "manifest.json":
                    continue
                info = entry.stat(follow_symlinks=False)
                if not stat.S_ISREG(info.st_mode):
                    raise ValueError("Nonregular evidence file")
                if info.st_size > MAX_FILE_BYTES or info.st_size > MAX_BUNDLE_BYTES - total:
                    raise ValueError("Evidence byte budget exceeded")
                count = 0
                digest = hashlib.sha256()
                with path.open("rb") as file:
                    while block := file.read(HASH_CHUNK):
                        count += len(block)
                        if count > MAX_FILE_BYTES or count > MAX_BUNDLE_BYTES - total:
                            raise ValueError("Evidence grew beyond byte budget")
                        digest.update(block)
                if count != info.st_size:
                    raise ValueError("Evidence changed while sealing")
                total += count
                inventory[str(path.relative_to(root))] = {"bytes": count, "sha256": digest.hexdigest()}
    value = {**metadata, "schema_version": 1, "files": inventory}
    (root / "manifest.json").write_text(json.dumps(value, indent=2, sort_keys=True, allow_nan=False) + "\n")
    return value
