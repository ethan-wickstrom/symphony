"""Owned HTTPS fixture; retain wire observations without candidate verdicts."""

import base64
import json
import ssl
import threading
from enum import Enum
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler
from graphql import GraphQLError

from ..linear import matches, select
from ..assets import encode
from .errors import Failures
from .journal import MAX_EVENTS, MAX_EVENT_BYTES, MAX_JOURNAL_BYTES
from .server import Server

MAX_BODY = 512 * 1024
MAX_REQUESTS = 256
SOCKET_TIMEOUT = 5
TLS_HANDSHAKE_TIMEOUT = 1
JOIN_TIMEOUT = 6
PROVIDER_SHARE = 4
MAX_PROVIDER_BYTES = MAX_JOURNAL_BYTES // PROVIDER_SHARE
MAX_PROVIDER_EVENTS = MAX_EVENTS // PROVIDER_SHARE
ENVELOPE_RESERVE_BYTES = 1024
FINAL_RECEIPT_BYTES = 64 * 1024
FINAL_RECEIPT_EVENTS = 3
_PEER_CLOSURES = (BrokenPipeError, ConnectionResetError, ssl.SSLEOFError)


class _Limit(Enum):
    BODY = "body_bytes"
    REQUESTS = "requests"
    RECORD = "record_bytes"
    BYTES = "evidence_bytes"
    EVENTS = "evidence_events"
    RESPONSE = "response_bytes"


class _Admission(Enum):
    OMIT = "omit"
    RETAIN = "retain"


def _record_bytes(kind, data):
    # Reserve fixed collector fields while charging exact encoded wire data.
    return len(encode({"kind": kind, "origin": "provider", "data": data})) + ENVELOPE_RESERVE_BYTES


def connection(nodes):
    return {"nodes": nodes, "pageInfo": {"hasNextPage": False, "endCursor": None}}


class Tracker:
    def __init__(self, corpus, journal, certificate, key):
        self._corpus = corpus
        self._journal = journal
        self._state = corpus["active_state"]
        self._lock = threading.Lock()
        self._errors = Failures()
        self._requests = 0
        self._admitted = 0
        self._omitted = 0
        self._rejected = 0
        self._bytes = 0
        self._events = 0
        self._limited = False
        self._closed = False
        owner = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, *args):
                return

            def setup(self):
                super().setup()
                self.connection.settimeout(SOCKET_TIMEOUT)

            def do_POST(self):
                owner._request(self)

            def do_GET(self):
                owner._request(self)

        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(certificate, key)
        self._server = Server(("127.0.0.1", 0), Handler, SOCKET_TIMEOUT, self._failure,
                              context=context, handshake_timeout=TLS_HANDSHAKE_TIMEOUT)
        self._thread = threading.Thread(target=self._server.serve_forever, name="fixture-tracker")
        self.endpoint = "https://127.0.0.1:%d/graphql" % self._server.server_port
        try:
            journal.emit("provider.started", {"endpoint": self.endpoint}, "provider")
            self._thread.start()
        except BaseException:
            self._server.server_close()
            raise

    def _failure(self, stage, error):
        with self._lock:
            self._errors.record(stage + ": " + type(error).__name__)

    def _issue(self):
        c = self._corpus
        return {"id": c["issue_id"], "identifier": c["issue_identifier"],
                "title": c["issue_title"], "description": None, "priority": 1,
                "state": {"name": self._state},
                "project": {"id": "fixture-project", "slugId": c["project"]},
                "labels": connection([]), "inverseRelations": connection([]),
                "createdAt": "2026-01-01T00:00:00Z", "updatedAt": None}

    def _limit(self, request_id, reason, size, admission):
        self._rejected += 1
        if admission is _Admission.OMIT:
            self._omitted += 1
        if self._limited:
            return
        self._limited = True
        self._journal.emit("provider.evidence_limit", {
            "request_id": request_id, "reason": reason.value, "body_bytes_lower_bound": size,
            "max_body_bytes": MAX_BODY, "max_requests": MAX_REQUESTS,
            "max_record_bytes": MAX_EVENT_BYTES, "max_evidence_bytes": MAX_PROVIDER_BYTES,
            "max_evidence_events": MAX_PROVIDER_EVENTS}, "provider")

    def _budget(self, request_id, data, size):
        if self._limited:
            return _Limit.BYTES
        if request_id > MAX_REQUESTS:
            return _Limit.REQUESTS
        if size > MAX_BODY:
            return _Limit.BODY
        amount = _record_bytes("provider.request", data) + 4 * ((size + 2) // 3)
        if amount > MAX_EVENT_BYTES:
            return _Limit.RECORD
        if self._events + 2 > MAX_PROVIDER_EVENTS - FINAL_RECEIPT_EVENTS:
            return _Limit.EVENTS
        # Reserve one maximal response before reading any candidate body.
        if amount + MAX_EVENT_BYTES > MAX_PROVIDER_BYTES - FINAL_RECEIPT_BYTES - self._bytes:
            return _Limit.BYTES
        return None

    def _request(self, handler):
        handler.close_connection = True
        with self._lock:
            self._requests += 1
            request_id = self._requests
        try:
            raw = b""
            rejected = False
            retained = False
            size = 0
            data = {"request_id": request_id, "method": handler.command,
                    "target": handler.path, "headers": list(handler.headers.raw_items()), "body": ""}
            try:
                lengths = handler.headers.get_all("Content-Length", [])
                if len(lengths) != 1 or not lengths[0].isascii() or not lengths[0].isdigit():
                    raise ValueError("Invalid fixture body framing")
                # Avoid converting an unbounded decimal header to an integer.
                digits = lengths[0].lstrip("0") or "0"
                size = MAX_BODY + 1 if len(digits) > len(str(MAX_BODY)) else int(digits)
            except (ValueError, OSError):
                rejected = True

            limit = self._budget(request_id, data, size)
            if limit is not None:
                self._limit(request_id, limit, size, _Admission.OMIT)
                rejected = True
            else:
                if not rejected:
                    try:
                        raw = handler.rfile.read(size)
                        if len(raw) != size:
                            raise ValueError("Truncated fixture request")
                    except (ValueError, OSError):
                        rejected = True
                data["body"] = base64.b64encode(raw).decode("ascii")
                retained = True
                # Admitted request bytes survive later timeout or projection faults.
                self._bytes += _record_bytes("provider.request", data)
                self._events += 1
                self._journal.emit("provider.request", data, "provider")
                self._admitted += 1
            if self._server.aborted(handler.connection):
                return
            try:
                if rejected or handler.command != "POST" or handler.path != "/graphql":
                    raise ValueError("Invalid fixture request")
                if handler.headers.get("Authorization") != self._corpus["fake_secret"]:
                    raise ValueError("Invalid fake tracker credential")
                try:
                    query = select(raw)
                except RecursionError as error:
                    raise ValueError("Fixture query exceeds parser recursion") from error
                with self._lock:
                    issue = self._issue()
                    nodes = [issue] if matches(issue, query["filter"]) else []
                payload = query["project"](connection(nodes))
                status = HTTPStatus.OK
            except (ValueError, TypeError, GraphQLError):
                payload = {"errors": [{"message": "Fixture request rejected"}]}
                status = HTTPStatus.BAD_REQUEST

            body = json.dumps(payload, separators=(",", ":"), allow_nan=False).encode()
            headers = [("Content-Type", "application/json"), ("Content-Length", str(len(body))),
                       ("Connection", "close")]
            response = {"request_id": request_id, "status": status.value, "headers": headers,
                        "body": base64.b64encode(body).decode("ascii")}
            if retained:
                if _record_bytes("provider.response", response) > MAX_EVENT_BYTES:
                    self._limit(request_id, _Limit.RESPONSE, size, _Admission.RETAIN)
                    payload = {"errors": [{"message": "Fixture request rejected"}]}
                    status = HTTPStatus.BAD_REQUEST
                    body = json.dumps(payload, separators=(",", ":"), allow_nan=False).encode()
                    headers[1] = ("Content-Length", str(len(body)))
                    response = {"request_id": request_id, "status": status.value, "headers": headers,
                                "body": base64.b64encode(body).decode("ascii")}
                self._bytes += _record_bytes("provider.response", response)
                self._events += 1
        except Exception as error:
            with self._lock:
                self._errors.record(type(error).__name__ + ": " + str(error))
            payload = {"errors": [{"message": "Fixture request rejected"}]}
            status = HTTPStatus.BAD_REQUEST
            retained = False

        if self._server.aborted(handler.connection):
            return
        body = json.dumps(payload, separators=(",", ":"), allow_nan=False).encode()
        headers = [("Content-Type", "application/json"), ("Content-Length", str(len(body))),
                   ("Connection", "close")]
        try:
            handler.send_response_only(status)
            for name, value in headers:
                handler.send_header(name, value)
            handler.end_headers()
            handler.wfile.write(body)
            handler.wfile.flush()
        except _PEER_CLOSURES as error:
            # Peer closure consumes the reserved response receipt, not fixture health.
            if retained:
                try:
                    self._journal.emit("provider.disconnect", {
                        "request_id": request_id, "error_type": type(error).__name__}, "provider")
                except Exception as receipt_error:
                    self._failure("disconnect receipt", receipt_error)
            return
        except Exception as error:
            if not isinstance(error, OSError) or not self._server.aborted(handler.connection):
                self._failure("response write", error)
            return
        if retained:
            try:
                self._journal.emit("provider.response", {"request_id": request_id,
                                   "status": status.value, "headers": headers,
                                   "body": base64.b64encode(body).decode("ascii")}, "provider")
            except Exception as error:
                self._failure("response receipt", error)

    def terminal(self):
        with self._lock:
            self._state = self._corpus["terminal_state"]
            self._journal.emit("control.terminal", {"issue_id": self._corpus["issue_id"]})

    def close(self):
        if self._closed:
            return
        self._closed = True
        primary = None
        for stage, action in (("provider server", self._server.close),
                              ("provider join", lambda: self._thread.join(JOIN_TIMEOUT))):
            try:
                action()
            except BaseException as error:
                self._failure(stage, error)
                if primary is None:
                    primary = error
        with self._lock:
            if self._thread.is_alive():
                self._errors.record("Fixture thread did not join")
        if self._limited:
            try:
                self._journal.emit("provider.evidence_summary", {
                    "requests": self._requests, "admitted_requests": self._admitted,
                    "omitted_requests": self._omitted, "rejected_requests": self._rejected}, "provider")
            except BaseException as error:
                self._failure("provider summary receipt", error)
                if primary is None:
                    primary = error
                else:
                    primary.add_note("Provider summary receipt failed: " + type(error).__name__)
        with self._lock:
            errors = self._errors.samples()
        try:
            self._journal.emit("provider.closed", {"status": "error" if errors else "ok",
                                                   "errors": errors}, "provider")
        except BaseException as error:
            self._failure("provider closure receipt", error)
            if primary is None:
                primary = error
            else:
                primary.add_note("Provider closure receipt failed: " + type(error).__name__)
        if primary is not None:
            raise primary

    def errors(self):
        with self._lock:
            return self._errors.samples()
