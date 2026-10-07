"""Serial HTTP connection custody with one absolute admission deadline."""

from enum import Enum
from http.server import HTTPServer
import math
import socket
import sys
import threading

TIMER_JOIN_TIMEOUT = 1


class _Abort(Enum):
    CLOSE = "owner-close"
    DEADLINE = "deadline"


class _Connection:
    def __init__(self, stream):
        self.stream = stream
        self.timer = None
        self.abort = None


class Server(HTTPServer):
    def __init__(self, address, handler, timeout, failed, *, context=None, handshake_timeout=None):
        if not math.isfinite(timeout) or timeout <= 0:
            raise ValueError("HTTP ownership requires a positive finite deadline")
        if context is not None and (handshake_timeout is None or not math.isfinite(handshake_timeout)
                                    or handshake_timeout <= 0):
            raise ValueError("TLS admission requires a positive finite deadline")
        if not callable(failed):
            raise ValueError("HTTP ownership requires an error recorder")
        self._timeout = timeout
        self._context = context
        self._handshake_timeout = handshake_timeout
        self._failed = failed
        self._lock = threading.Lock()
        self._active = None
        self._closing = False
        super().__init__(address, handler)

    def _abort(self, connection, reason):
        if connection.abort is None:
            connection.abort = reason
        # makefile() retains the descriptor; shutdown wakes its blocked reads.
        try:
            connection.stream.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        try:
            connection.stream.close()
        except OSError as error:
            self._failed("connection close", error)

    def _expire(self, connection):
        with self._lock:
            if self._active is connection:
                self._abort(connection, _Abort.DEADLINE)

    def _stop_timer(self, connection):
        timer = connection.timer
        if timer is None:
            return
        timer.cancel()
        if timer.ident is not None:
            timer.join(TIMER_JOIN_TIMEOUT)
            if timer.is_alive():
                raise RuntimeError("HTTP connection deadline thread did not join")

    def _finish(self, connection):
        self._stop_timer(connection)
        with self._lock:
            if self._active is connection:
                self._active = None

    def get_request(self):
        raw, address = self.socket.accept()
        connection = _Connection(raw)
        try:
            with self._lock:
                if self._closing:
                    raise OSError("HTTP admission is closed")
                if self._active is not None:
                    raise RuntimeError("Prior HTTP connection custody was not released")
                self._active = connection
                connection.timer = threading.Timer(self._timeout, self._expire, (connection,))
                connection.timer.start()
                raw.settimeout(self._timeout)
                if self._context is not None:
                    connection.stream = self._context.wrap_socket(raw, server_side=True,
                                                                 do_handshake_on_connect=False)
                    connection.stream.settimeout(min(self._timeout, self._handshake_timeout))
            if self._context is not None:
                connection.stream.do_handshake()
                connection.stream.settimeout(self._timeout)
            return connection.stream, address
        except BaseException as primary:
            if not isinstance(primary, OSError):
                self._failed("HTTP admission", primary)
            for stage, action in (("admission socket", connection.stream.close),
                                  ("admission deadline", lambda: self._finish(connection))):
                try:
                    action()
                except BaseException as error:
                    self._failed(stage, error)
                    primary.add_note("HTTP admission cleanup failed: " + stage + ": " + type(error).__name__)
            raise

    def aborted(self, stream):
        with self._lock:
            return (self._active is not None and self._active.stream is stream
                    and self._active.abort is not None)

    def handle_error(self, request, _address):
        error = sys.exc_info()[1]
        if not isinstance(error, OSError) or not self.aborted(request):
            self._failed("HTTP handler", error)

    def shutdown_request(self, request):
        with self._lock:
            connection = self._active if self._active is not None and self._active.stream is request else None
        try:
            super().shutdown_request(request)
        finally:
            if connection is not None:
                self._finish(connection)

    def close(self):
        primary = None

        def attempt(stage, action):
            nonlocal primary
            try:
                action()
            except BaseException as error:
                self._failed(stage, error)
                if primary is None:
                    primary = error

        with self._lock:
            self._closing = True
            connection = self._active
            if connection is not None:
                self._abort(connection, _Abort.CLOSE)
        if connection is not None:
            attempt("deadline join", lambda: self._stop_timer(connection))
        attempt("HTTP shutdown", self.shutdown)
        attempt("HTTP listener", self.server_close)
        if primary is not None:
            raise primary
