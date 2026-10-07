"""A schema-bound app-server fixture whose observations contain the wire bytes."""

import argparse
import base64
from enum import Enum
import json
import os
from pathlib import Path
import selectors
import signal
import sys
import tempfile
import time

from .assets import decode
from .driver.observer import Observer
from .schema import Schema

FRAME_LIMIT = 512 * 1024
READ_BYTES = 4096
CONTROL_INTERVAL = 0.05
PROTOCOL_VERSION = "0.159.2"
TRACKER_SECRET_NAME = "LINEAR_API_KEY"


class Phase(Enum):
    INITIALIZE = "initialize"
    INITIALIZED = "initialized"
    THREAD = "thread"
    NAME = "name"
    TURN = "turn"
    ACTIVE = "active"


class Fault(Enum):
    ACK_ONLY = "ack-only"


def _require(condition, message):
    if not condition:
        raise ValueError(message)


def _env(plan):
    # Only named ambient fields and the known fake secret enter evidence.
    names = plan["profile"]["ambient_environment"]
    result = {name: os.environ[name] for name in names if name in os.environ}
    fake = plan["corpus"]["fake_secret"]
    result.update({name: value for name, value in os.environ.items() if value == fake})
    if TRACKER_SECRET_NAME in os.environ:
        result[TRACKER_SECRET_NAME] = (
            fake if os.environ[TRACKER_SECRET_NAME] == fake else "<redacted>"
        )
    return result


def _marker(path, data):
    file = tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=path.parent,
                                       prefix=path.name + ".", suffix=".tmp", delete=False)
    temporary = Path(file.name)
    try:
        with file:
            json.dump(data, file, allow_nan=False)
        temporary.replace(path)
    finally:
        temporary.unlink(missing_ok=True)


class Peer:
    def __init__(self, plan):
        self._plan = plan
        self._corpus = plan["corpus"]
        self._profile = plan["profile"]
        self._observer = Observer(plan["collector_url"], "peer")
        self._schema = Schema()
        self._pid = os.getpid()
        self._peer_id = "peer-" + str(self._pid)
        self._cwd = os.getcwd()
        self._control = Path(plan["control_root"])
        self._thread = self._corpus["thread_id"]
        self._turn = None
        self._turns = 0
        self._phase = Phase.INITIALIZE
        self._signal = None

    def _emit(self, kind, data):
        self._observer.emit(kind, {"peer_id": self._peer_id, **data})

    def _send(self, frame, method=None):
        self._schema.validate(frame, "server", method=method)
        raw = (json.dumps(frame, separators=(",", ":"), allow_nan=False) + "\n").encode()
        sys.stdout.buffer.write(raw)
        sys.stdout.buffer.flush()
        self._emit("peer.server", {"frame": base64.b64encode(raw).decode("ascii")})

    def _reply(self, request, result):
        self._send({"id": request["id"], "result": result}, request["method"])

    def _terminal(self, status):
        self._send({"method": "turn/completed", "params": {
            "threadId": self._thread,
            "turn": {"id": self._turn, "items": [], "status": status, "error": None},
        }})
        self._phase = Phase.TURN

    def _usage(self):
        for value in self._corpus["usage_updates"]:
            totals = {
                "inputTokens": value["input_tokens"],
                "outputTokens": value["output_tokens"],
                "totalTokens": value["total_tokens"],
                "cachedInputTokens": 0,
                "reasoningOutputTokens": 0,
            }
            self._send({"method": "thread/tokenUsage/updated", "params": {
                "threadId": self._thread,
                "turnId": self._turn,
                "tokenUsage": {"total": totals, "last": totals},
            }})

    def _thread_result(self):
        _require(self._profile["sandbox"] == "workspace-write", "Unsupported fixture sandbox")
        return {
            "thread": {
                "id": self._thread, "sessionId": self._peer_id,
                "cliVersion": PROTOCOL_VERSION, "createdAt": 0, "updatedAt": 0,
                "cwd": self._cwd, "ephemeral": True, "modelProvider": "openai",
                "preview": "", "projectId": None, "source": "appServer",
                "status": {"type": "idle"}, "turns": [],
            },
            "cwd": self._cwd, "model": "fixture", "modelProvider": "openai",
            "approvalPolicy": self._profile["approval_policy"], "approvalsReviewer": "user",
            "sandbox": {"type": "workspaceWrite", "writableRoots": [self._cwd],
                        "networkAccess": False, "excludeTmpdirEnvVar": False,
                        "excludeSlashTmp": False},
        }

    def _start_turn(self, request):
        params = request["params"]
        _require(self._phase == Phase.TURN, "Turn started outside handshake order")
        _require(params.get("threadId") == self._thread, "Turn changed thread")
        _require(params.get("cwd") == self._cwd, "Turn changed workspace")
        _require(params.get("approvalPolicy") == self._profile["approval_policy"], "Turn changed policy")
        _require(self._turns < len(self._corpus["turn_ids"]), "Unexpected additional turn")
        self._turn = self._corpus["turn_ids"][self._turns]
        self._turns += 1
        self._phase = Phase.ACTIVE
        self._reply(request, {"turn": {
            "id": self._turn, "items": [], "status": "inProgress", "error": None,
        }})
        if self._turns != 1:
            return
        self._usage()
        self._terminal("completed")

    def _handle(self, frame):
        method = frame.get("method")
        if method == "initialized":
            _require(self._phase == Phase.INITIALIZED, "Initialized arrived outside handshake order")
            self._phase = Phase.THREAD
            return
        params = frame.get("params", {})
        if method == "initialize":
            _require(self._phase == Phase.INITIALIZE, "Duplicate initialize")
            self._reply(frame, {"userAgent": "symphony-conformance-fixture", "codexHome": self._cwd,
                                "platformFamily": "unix", "platformOs":
                                "macos" if sys.platform == "darwin" else "linux"})
            self._phase = Phase.INITIALIZED
            return
        if method == "thread/start":
            _require(self._phase == Phase.THREAD, "Thread started outside handshake order")
            _require(params.get("cwd") == self._cwd, "Thread changed workspace")
            _require(params.get("approvalPolicy") == self._profile["approval_policy"], "Thread changed policy")
            _require(params.get("sandbox") == self._profile["sandbox"], "Thread changed sandbox")
            self._reply(frame, self._thread_result())
            self._phase = Phase.NAME
            return
        if method == "thread/name/set":
            _require(self._phase == Phase.NAME, "Thread named outside handshake order")
            _require(params.get("threadId") == self._thread, "Naming changed thread")
            self._reply(frame, {})
            self._phase = Phase.TURN
            return
        if method == "turn/start":
            self._start_turn(frame)
            return
        if method == "turn/interrupt":
            _require(self._phase == Phase.ACTIVE, "Interrupt has no active turn")
            _require(params.get("threadId") == self._thread, "Interrupt changed thread")
            _require(params.get("turnId") == self._turn, "Interrupt changed turn")
            self._reply(frame, {})
            if self._plan.get("fault") == Fault.ACK_ONLY.value:
                return
            self._terminal("interrupted")
            return
        raise ValueError("Unexpected client method")

    def _stop(self, number, _frame):
        self._signal = number

    def _receive(self, raw):
        _require(len(raw) <= FRAME_LIMIT, "Client frame exceeds fixture budget")
        self._emit("peer.client", {"frame": base64.b64encode(raw).decode("ascii")})
        frame = decode(raw)
        self._schema.validate(frame, "client")
        self._handle(frame)

    def run(self):
        identity = {"peer_id": self._peer_id, "pid": self._pid, "pgid": os.getpgrp()}
        _marker(self._control / "peer.json", identity)
        self._emit("peer.started", {**identity, "cwd": self._cwd, "env": _env(self._plan)})
        previous = {number: signal.signal(number, self._stop) for number in (signal.SIGTERM, signal.SIGINT)}
        outcome = "error"
        buffer = bytearray()
        deadline = time.monotonic() + self._corpus["run_budget_seconds"]
        try:
            with selectors.DefaultSelector() as selector:
                selector.register(sys.stdin.fileno(), selectors.EVENT_READ)
                while self._signal is None:
                    _require(time.monotonic() < deadline, "Peer fixture budget expired")
                    for _key, _mask in selector.select(CONTROL_INTERVAL):
                        block = os.read(sys.stdin.fileno(), READ_BYTES)
                        if not block:
                            _require(not buffer, "Truncated client frame")
                            outcome = "eof"
                            return
                        buffer.extend(block)
                        while b"\n" in buffer:
                            raw, _, remainder = buffer.partition(b"\n")
                            buffer = bytearray(remainder)
                            self._receive(bytes(raw) + b"\n")
                        _require(len(buffer) <= FRAME_LIMIT, "Client frame exceeds fixture budget")
                outcome = "signal"
        except Exception as error:
            self._emit("peer.error", {"error_type": type(error).__name__})
            raise
        finally:
            _marker(self._control / "peer-closed.json", identity)
            self._emit("peer.closed", {"outcome": outcome, "signal": self._signal})
            for number, handler in previous.items():
                signal.signal(number, handler)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plan", type=Path, required=True)
    args = parser.parse_args()
    Peer(decode(args.plan.read_bytes())).run()


if __name__ == "__main__":
    main()
