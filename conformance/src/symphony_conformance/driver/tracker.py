"""Owned HTTPS fixture; retain wire observations without candidate verdicts."""

import base64
import json
import ssl
import threading
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler
from graphql import GraphQLError

from ..linear import matches, select
from .errors import Failures
from .server import Server

MAX_BODY = 512 * 1024
MAX_REQUESTS = 256
SOCKET_TIMEOUT = 5
TLS_HANDSHAKE_TIMEOUT = 1
JOIN_TIMEOUT = 6


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

    def _request(self, handler):
        handler.close_connection = True
        with self._lock:
            self._requests += 1
            request_id = self._requests
        try:
            raw = b""
            rejected = False
            try:
                lengths = handler.headers.get_all("Content-Length", [])
                if len(lengths) != 1 or not lengths[0].isdigit():
                    raise ValueError("Invalid fixture body framing")
                size = int(lengths[0])
                if size > MAX_BODY or request_id > MAX_REQUESTS:
                    raise ValueError("Fixture budget exceeded")
                raw = handler.rfile.read(size)
                if len(raw) != size:
                    raise ValueError("Truncated fixture request")
            except (ValueError, OSError):
                rejected = True

            # Retain admitted wire bytes even when the candidate request fails.
            self._journal.emit("provider.request", {
                "request_id": request_id, "method": handler.command,
                "target": handler.path, "headers": list(handler.headers.raw_items()),
                "body": base64.b64encode(raw).decode("ascii")}, "provider")
            if self._server.aborted(handler.connection):
                return
            try:
                if rejected or handler.command != "POST" or handler.path != "/graphql":
                    raise ValueError("Invalid fixture request")
                if handler.headers.get("Authorization") != self._corpus["fake_secret"]:
                    raise ValueError("Invalid fake tracker credential")
                query = select(raw)
                with self._lock:
                    issue = self._issue()
                    nodes = [issue] if matches(issue, query["filter"]) else []
                payload = {"data": {query["response_key"]: connection(nodes)}}
                status = HTTPStatus.OK
            except (ValueError, TypeError, GraphQLError):
                payload = {"errors": [{"message": "Fixture request rejected"}]}
                status = HTTPStatus.BAD_REQUEST
        except Exception as error:
            with self._lock:
                self._errors.record(type(error).__name__ + ": " + str(error))
            payload = {"errors": [{"message": "Fixture request rejected"}]}
            status = HTTPStatus.BAD_REQUEST

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
        except Exception as error:
            if not isinstance(error, OSError) or not self._server.aborted(handler.connection):
                self._failure("response write", error)
            return
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
