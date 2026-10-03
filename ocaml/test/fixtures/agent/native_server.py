#!/usr/bin/env python3
"""Owned JSONL peer; its after-run hook verifies process closure."""

import argparse
import errno
import json
import os
import sys
from enum import Enum
from pathlib import Path


class Mode(str, Enum):
    NORMAL = "normal"
    INPUT = "user-input"
    MALFORMED = "malformed"
    TRUNCATED = "truncated"
    RESPONSE_TIMEOUT = "response-timeout"
    FAILED = "failed"
    STALL = "stall"
    CANCEL = "cancel"


class Phase(Enum):
    INITIALIZE = 1
    INITIALIZED = 2
    THREAD = 3
    NAME = 4
    TURNS = 5


class ProtocolError(Exception):
    pass


class EndServer(Exception):
    pass


FRAME_BYTES = 1_048_576
LOG_BYTES = 1_048_576
FRAGMENT_BYTES = 1
STDERR_CHUNK_BYTES = 65_536
STDERR_CHUNKS = 3
THREAD_ID = "native-thread"
TITLE = "SYM-native: Native acceptance"
FIRST_PROMPT = "NATIVE-TASK " + TITLE
INPUT_ID = "native-input-1"
LARGE_INPUT = 9_007_199_254_740_993
PID_FILE = Path("agent.pid")
WIRE_FILE = Path("agent-wire.jsonl")
ERROR_FILE = Path("protocol-errors.txt")
AFTER_FILE = Path("after-run")
STDERR_FILE = Path("stderr-complete")


def require(condition, message):
    if not condition:
        raise ProtocolError(message)


def encode(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8")


def same_json(actual, expected):
    return json.dumps(actual, sort_keys=True) == json.dumps(expected, sort_keys=True)


def write_all(fd, data):
    rest = memoryview(data)
    while rest:
        written = os.write(fd, rest)
        require(written > 0, "zero-progress fixture write")
        rest = rest[written:]


def duplicate_pairs(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "duplicate client JSON object key")
        result[key] = value
    return result


def reject_constant(_value):
    raise ProtocolError("non-JSON client number")


def failure(message):
    ERROR_FILE.write_text(message + "\n", encoding="utf-8")
    write_all(sys.stderr.fileno(), ("native peer: " + message + "\n").encode("utf-8"))


def after_run():
    require("SYMPHONY_SECRET" not in os.environ, "denied environment reached hook")
    value = PID_FILE.read_text(encoding="ascii").strip()
    require(value.isdecimal() and len(value) <= 20, "invalid fixture PID")
    pid = int(value)
    require(pid > 0, "invalid fixture PID")
    try:
        os.kill(pid, 0)
    except OSError as error:
        require(error.errno == errno.ESRCH, "fixture PID check failed")
    else:
        raise ProtocolError("after-run began before fixture process closed")
    AFTER_FILE.write_text("process closed before after-run\n", encoding="ascii")


class Server:
    def __init__(self, mode):
        self.mode = mode
        self.phase = Phase.INITIALIZE
        self.cwd = os.getcwd()
        self.turns = 0
        self.current = None
        self.input_id = None
        self.logged = 0

    def output(self, data):
        if self.mode != Mode.NORMAL:
            write_all(sys.stdout.fileno(), data)
            return
        # Each write can split UTF-8 or a JSON token; native reads may coalesce it.
        for offset in range(0, len(data), FRAGMENT_BYTES):
            write_all(sys.stdout.fileno(), data[offset:offset + FRAGMENT_BYTES])

    def batch(self, values):
        self.output(b"".join(encode(value) + b"\n" for value in values))

    def reply(self, call, result):
        return {"id": call["id"], "result": result}

    def notice(self, method, params):
        return {"method": method, "params": params}

    def turn(self, status, error=None):
        return {"id": self.current, "items": [], "status": status, "error": error}

    def terminal(self, status, error=None):
        return self.notice("turn/completed", {
            "threadId": THREAD_ID,
            "turn": self.turn(status, error),
        })

    def thread_result(self):
        return {
            "thread": {
                "id": THREAD_ID,
                "sessionId": "native-session",
                "cliVersion": "0.159.2",
                "createdAt": 0,
                "updatedAt": 0,
                "cwd": self.cwd,
                "ephemeral": True,
                "modelProvider": "openai",
                "preview": "",
                "projectId": None,
                "source": "appServer",
                "status": {"type": "idle"},
                "turns": [],
            },
            "cwd": self.cwd,
            "model": "native-fixture",
            "modelProvider": "openai",
            "approvalPolicy": "never",
            "approvalsReviewer": "user",
            "sandbox": {
                "type": "workspaceWrite",
                "writableRoots": [self.cwd],
                "networkAccess": False,
                "excludeTmpdirEnvVar": False,
                "excludeSlashTmp": False,
            },
        }

    def usage(self):
        absolute = {
            "inputTokens": LARGE_INPUT + self.turns,
            "cachedInputTokens": 0,
            "outputTokens": 3 + self.turns,
            "reasoningOutputTokens": 0,
            "totalTokens": LARGE_INPUT + 3 + 2 * self.turns,
        }
        return self.notice("thread/tokenUsage/updated", {
            "threadId": THREAD_ID,
            "turnId": self.current,
            "tokenUsage": {
                "total": absolute,
                "last": {
                    "inputTokens": 1,
                    "cachedInputTokens": 0,
                    "outputTokens": 1,
                    "reasoningOutputTokens": 0,
                    "totalTokens": 2,
                },
            },
        })

    def check_turn(self, params):
        require(params.get("threadId") == THREAD_ID, "turn changed thread")
        require(params.get("cwd") == self.cwd, "turn changed acquired cwd")
        require(params.get("approvalPolicy") == "never", "turn changed approval policy")
        require(params.get("approvalsReviewer") == "user", "turn changed approval reviewer")
        require(same_json(params.get("sandboxPolicy"), {
            "type": "workspaceWrite",
            "writableRoots": [self.cwd],
            "networkAccess": False,
            "excludeTmpdirEnvVar": True,
            "excludeSlashTmp": True,
        }), "turn omitted or changed its explicit sandbox policy")
        inputs = params.get("input")
        require(isinstance(inputs, list) and len(inputs) == 1, "turn requires one input")
        item = inputs[0]
        require(isinstance(item, dict) and item.get("type") == "text", "turn input is not text")
        text = item.get("text")
        require(isinstance(text, str) and text, "turn input is empty")
        if self.turns == 1:
            require(text == FIRST_PROMPT, "initial turn changed full task prompt")
        else:
            require("NATIVE-TASK" not in text, "continuation resent the full task")

    def start_turn(self, call, params):
        self.turns += 1
        require(self.turns <= 3, "runner exceeded frozen turn cap")
        require(self.turns == 1 or self.mode == Mode.NORMAL, "terminal mode started a continuation")
        self.current = "native-turn-" + str(self.turns)
        self.check_turn(params)
        ack = self.reply(call, {"turn": self.turn("inProgress")})
        if self.mode == Mode.NORMAL:
            # Correlated observations precede the synchronous start response.
            self.batch([
                self.notice("turn/started", {"threadId": THREAD_ID, "turn": self.turn("inProgress")}),
                self.usage(),
                self.notice("fixture/nativeOutput", {
                    "threadId": THREAD_ID,
                    "turnId": self.current,
                    "text": "fragmented λ\r\ncontinuation",
                }),
                self.terminal("completed"),
                ack,
            ])
        elif self.mode == Mode.INPUT:
            self.input_id = INPUT_ID
            self.batch([
                {"id": INPUT_ID, "method": "item/tool/requestUserInput", "params": {
                    "threadId": THREAD_ID,
                    "turnId": self.current,
                    "itemId": "native-input-item",
                    "isBlocking": True,
                    "questions": [{"id": "choice", "header": "Choice", "question": "Continue?"}],
                }},
                ack,
            ])
        elif self.mode == Mode.FAILED:
            self.batch([ack, self.terminal("failed", {
                "message": "native fixture turn failure",
                "codexErrorInfo": "sandboxError",
                "additionalDetails": None,
            })])
        elif self.mode == Mode.MALFORMED:
            self.batch([ack, self.notice("fixture/acceptedPrefix", {
                "threadId": THREAD_ID, "turnId": self.current,
            })])
            self.output(b"{broken}\n")
        elif self.mode == Mode.TRUNCATED:
            self.batch([ack])
            self.output(b'{"method":"turn/completed"')
            raise EndServer()
        else:
            self.batch([ack])

    def interrupt(self, call, params):
        require(self.phase == Phase.TURNS, "interruption preceded a named thread")
        require(params.get("threadId") == THREAD_ID, "interrupt changed thread")
        require(params.get("turnId") == self.current, "interrupt changed active turn")
        frames = [self.reply(call, {})]
        if self.input_id is not None:
            frames.append(self.notice("serverRequest/resolved", {
                "threadId": THREAD_ID, "requestId": self.input_id,
            }))
            self.input_id = None
        frames.append(self.terminal("interrupted"))
        self.batch(frames)

    def handle(self, call):
        require(isinstance(call, dict), "client envelope is not an object")
        method = call.get("method")
        require(isinstance(method, str), "client invented a server-request answer")
        if method == "initialized":
            require(self.phase == Phase.INITIALIZED, "initialized is out of order")
            require("id" not in call and "params" not in call, "initialized must omit id and params")
            self.phase = Phase.THREAD
            return
        identity = call.get("id")
        require(isinstance(identity, (str, int)) and not isinstance(identity, bool), "invalid client RPC identity")
        params = call.get("params")
        require(isinstance(params, dict), "client RPC omitted object params")
        if method == "initialize":
            require(self.phase == Phase.INITIALIZE, "initialize is out of order")
            info = params.get("clientInfo")
            require(isinstance(info, dict) and info.get("name") == "symphony", "wrong client identity")
            require(isinstance(info.get("version"), str) and info["version"], "client version is missing")
            require(same_json(params.get("capabilities"), {
                "experimentalApi": False,
                "explicitGatewayOauth": True,
                "requestAttestation": False,
            }), "initialize capabilities are not explicit")
            if self.mode == Mode.RESPONSE_TIMEOUT:
                return
            self.phase = Phase.INITIALIZED
            self.batch([self.reply(call, {
                "userAgent": "native-fixture",
                "codexHome": self.cwd,
                "platformFamily": "unix",
                "platformOs": "macos" if sys.platform == "darwin" else "linux",
            })])
        elif method == "thread/start":
            require(self.phase == Phase.THREAD, "thread/start is out of order")
            require(params.get("cwd") == self.cwd, "thread changed acquired cwd")
            require(params.get("approvalPolicy") == "never", "thread changed approval policy")
            require(params.get("sandbox") == "workspace-write", "thread changed sandbox shorthand")
            require(params.get("approvalsReviewer") == "user", "thread changed approval reviewer")
            self.phase = Phase.NAME
            self.batch([self.reply(call, self.thread_result())])
        elif method == "thread/name/set":
            require(self.phase == Phase.NAME, "thread/name/set is out of order")
            require(params.get("threadId") == THREAD_ID and params.get("name") == TITLE, "wrong thread name")
            self.phase = Phase.TURNS
            self.batch([self.reply(call, {})])
        elif method == "turn/start":
            require(self.phase == Phase.TURNS, "turn/start preceded thread naming")
            self.start_turn(call, params)
        elif method == "turn/interrupt":
            self.interrupt(call, params)
        else:
            raise ProtocolError("unexpected client method")

    def run(self):
        for marker in (AFTER_FILE, STDERR_FILE, ERROR_FILE):
            marker.unlink(missing_ok=True)
        PID_FILE.write_text(str(os.getpid()) + "\n", encoding="ascii")
        require(os.environ.get("SYMPHONY_AGENT_MODE") == self.mode.value, "invocation mode environment differs")
        require("SYMPHONY_SECRET" not in os.environ, "denied environment reached peer")
        if self.mode == Mode.NORMAL:
            for _index in range(STDERR_CHUNKS):
                write_all(sys.stderr.fileno(), b"e" * STDERR_CHUNK_BYTES)
            STDERR_FILE.write_text("stderr burst completed\n", encoding="ascii")
        with WIRE_FILE.open("wb") as wire:
            while True:
                raw = sys.stdin.buffer.readline(FRAME_BYTES + 2)
                if not raw:
                    return
                require(raw.endswith(b"\n") and len(raw) - 1 <= FRAME_BYTES, "client record exceeds JSONL frame bound")
                require(self.logged + len(raw) <= LOG_BYTES, "client wire exceeds fixture log bound")
                wire.write(raw)
                wire.flush()
                self.logged += len(raw)
                try:
                    call = json.loads(raw, object_pairs_hook=duplicate_pairs, parse_constant=reject_constant)
                except (ValueError, UnicodeError) as error:
                    raise ProtocolError("invalid client JSON") from error
                self.handle(call)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    selected = parser.add_mutually_exclusive_group()
    selected.add_argument("--mode", choices=[mode.value for mode in Mode], default=Mode.NORMAL.value)
    selected.add_argument("--after-run", action="store_true", help="verify server PID has been reaped")
    args = parser.parse_args()
    try:
        if args.after_run:
            after_run()
        else:
            Server(Mode(args.mode)).run()
    except EndServer:
        return 0
    except BrokenPipeError:
        return 0
    except (ProtocolError, OSError) as error:
        failure(str(error))
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
