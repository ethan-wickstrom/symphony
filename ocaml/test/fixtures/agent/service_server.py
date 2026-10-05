#!/usr/bin/env python3
"""Local Codex0.159.2 JSONL peer with independently controlled turn completion."""

import argparse
import errno
import fcntl
import json
import os
from pathlib import Path
import selectors
import resource
import sys
import time

FRAME_LIMIT = 1_048_576
LOG_LIMIT = 1_048_576
CONTROL_INTERVAL = 0.02
HOOK_GATE_SECONDS = 15
STDERR_SENTINEL = "fixture-stderr-never-render\r\nevent=service_stopped forged=yes\n"
TOKEN = "service-fixture-linear-key-never-print"
FD_LIMIT = 64


def require(condition, message):
    if not condition:
        raise ValueError(message)


def pairs(values):
    result = {}
    for key, value in values:
        require(key not in result, "duplicate RPC key")
        result[key] = value
    return result


def write(fd, data):
    remaining = memoryview(data)
    while remaining:
        count = os.write(fd, remaining)
        require(count > 0, "zero-progress fixture write")
        remaining = remaining[count:]


def fd_exec(arguments):
    require(arguments.fd_receipt is not None and arguments.command,
            "missing descriptor launch receipt/command")
    command = arguments.command[1:] if arguments.command[0] == "--" else arguments.command
    require(command and Path(command[0]).is_absolute(), "descriptor launch requires absolute executable")
    require(0 < arguments.fd_headroom < FD_LIMIT - 3, "invalid descriptor headroom")
    _soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
    require(hard >= FD_LIMIT, "fixture descriptor hard limit below controlled budget")
    resource.setrlimit(resource.RLIMIT_NOFILE, (FD_LIMIT, hard))
    receipt_fd = os.open(arguments.fd_receipt, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    owned = []
    while True:
        try:
            fd = os.open(os.devnull, os.O_RDONLY)
        except OSError as error:
            require(error.errno == errno.EMFILE, "unexpected descriptor fixture acquisition failure")
            break
        os.set_inheritable(fd, True)
        owned.append(fd)
    # Closing the receipt itself accounts for the last free descriptor.
    for _ in range(arguments.fd_headroom - 1):
        os.close(owned.pop())
    live = []
    for fd in range(FD_LIMIT):
        if fd == receipt_fd:
            continue
        try:
            fcntl.fcntl(fd, fcntl.F_GETFD)
        except OSError as error:
            require(error.errno == errno.EBADF, "descriptor fixture inventory failed")
        else:
            live.append(fd)
    require(len(live) + arguments.fd_headroom == FD_LIMIT, "descriptor inventory does not match headroom")
    write(receipt_fd, (json.dumps({"limit": FD_LIMIT, "free": arguments.fd_headroom,
                                  "inherited": live, "fillers": owned,
                                  "optimize": sys.flags.optimize, "command": command}) + "\n").encode())
    os.close(receipt_fd)
    os.execve(command[0], command, os.environ)


def after_run(arguments):
    require(TOKEN not in os.environ.values(), "credential reached hook")
    path = Path("service-agent.pid")
    value = path.read_text(encoding="ascii").strip()
    require(value.isdecimal() and 0 < len(value) <= 20, "invalid peer PID")
    try:
        os.kill(int(value), 0)
    except OSError as error:
        require(error.errno == errno.ESRCH, "peer liveness probe failed")
    else:
        raise ValueError("after_run preceded app-server process reap")
    receipt = {"pid": int(value), "closed": True}
    if arguments.version is not None:
        receipt.update(version=arguments.version, user=os.environ.get("USER"))
    if arguments.hook_gate == "held":
        require(arguments.root is not None, "missing hook gate root")
        pending = arguments.root / ".hook-entered.tmp"
        pending.write_text(json.dumps(receipt) + "\n")
        pending.replace(arguments.root / "hook-entered.json")
        deadline = time.monotonic() + HOOK_GATE_SECONDS
        while not (arguments.root / "release-after-run").exists():
            require(time.monotonic() < deadline, "after_run fixture gate expired")
            time.sleep(CONTROL_INTERVAL)
    with Path("service-after-run.jsonl").open("a", encoding="utf-8") as output:
        output.write(json.dumps(receipt) + "\n")


class Peer:
    def __init__(self, root, mode, version):
        self.root = root
        self.mode = mode
        self.version = version
        self.pid = os.getpid()
        self.cwd = os.getcwd()
        self.thread = f"service-thread-{self.pid}"
        self.turn = None
        self.turns = 0
        self.phase = "initialize"
        self.active = False
        self.logged = 0
        self.log = root / f"peer-{self.pid}.jsonl"

    def record(self, value):
        data = (json.dumps(value, ensure_ascii=False) + "\n").encode()
        self.logged += len(data)
        require(self.logged <= LOG_LIMIT, "peer receipt exceeds limit")
        with self.log.open("ab") as output:
            output.write(data)

    def send(self, value):
        write(sys.stdout.fileno(), json.dumps(value, separators=(",", ":")).encode() + b"\n")

    def reply(self, call, result):
        self.send({"id": call["id"], "result": result})

    def terminal(self, status):
        self.active = False
        self.send({"method": "turn/completed", "params": {
            "threadId": self.thread,
            "turn": {"id": self.turn, "items": [], "status": status, "error": None},
        }})

    def thread_result(self):
        return {
            "thread": {
                "id": self.thread, "sessionId": f"service-session-{self.pid}",
                "cliVersion": "0.159.2", "createdAt": 0, "updatedAt": 0,
                "cwd": self.cwd, "ephemeral": True, "modelProvider": "openai",
                "preview": "", "projectId": None, "source": "appServer",
                "status": {"type": "idle"}, "turns": [],
            },
            "cwd": self.cwd, "model": "fixture", "modelProvider": "openai",
            "approvalPolicy": "never", "approvalsReviewer": "user",
            "sandbox": {"type": "workspaceWrite", "writableRoots": [self.cwd],
                        "networkAccess": False, "excludeTmpdirEnvVar": False,
                        "excludeSlashTmp": False},
        }

    def handle(self, call):
        require(isinstance(call, dict), "RPC envelope is not object")
        method = call.get("method")
        self.record({"kind": "rpc", "message": call})
        if method == "initialized":
            require(self.phase == "initialized" and "id" not in call,
                    "initialized sequence invalid")
            self.phase = "thread"
            return
        require(type(call.get("id")) in (int, str), "missing RPC identity")
        params = call.get("params")
        require(isinstance(params, dict), "RPC params missing")
        if method == "initialize":
            require(self.phase == "initialize", "duplicate initialize")
            require(params.get("clientInfo", {}).get("name") == "symphony",
                    "wrong client identity")
            self.reply(call, {"userAgent": "service-fixture", "codexHome": self.cwd,
                              "platformFamily": "unix", "platformOs":
                              "macos" if sys.platform == "darwin" else "linux"})
            self.phase = "initialized"
        elif method == "thread/start":
            require(self.phase == "thread" and params.get("cwd") == self.cwd,
                    "thread changed acquired cwd or order")
            require(params.get("approvalPolicy") == "never" and
                    params.get("sandbox") == "workspace-write", "unsafe policy")
            self.reply(call, self.thread_result())
            self.phase = "name"
        elif method == "thread/name/set":
            require(self.phase == "name" and params.get("threadId") == self.thread,
                    "thread naming changed thread")
            require(isinstance(params.get("name"), str) and params["name"], "empty name")
            self.reply(call, {})
            self.phase = "turn"
        elif method == "turn/start":
            require(self.phase == "turn" and params.get("threadId") == self.thread,
                    "continuation changed thread or order")
            require(params.get("cwd") == self.cwd, "turn changed workspace")
            require(params.get("approvalPolicy") == "never", "turn changed approval")
            inputs = params.get("input")
            require(isinstance(inputs, list) and len(inputs) == 1 and
                    inputs[0].get("type") == "text" and inputs[0].get("text"),
                    "turn requires nonempty text")
            self.turns += 1
            self.turn = f"service-turn-{self.turns}"
            self.active = True
            self.reply(call, {"turn": {"id": self.turn, "items": [],
                                       "status": "inProgress", "error": None}})
            if self.mode == "continue" and self.turns == 1:
                self.terminal("completed")
        elif method == "turn/interrupt":
            require(params.get("threadId") == self.thread and
                    params.get("turnId") == self.turn, "interrupt changed live turn")
            self.reply(call, {})
            if self.active:
                self.terminal("interrupted")
        else:
            raise ValueError("unexpected RPC method")

    def run(self):
        require(TOKEN not in os.environ.values() and "LINEAR_API_KEY" not in os.environ,
                "tracker credential reached app-server")
        Path("service-agent.pid").write_text(str(self.pid), encoding="ascii")
        receipt = {"kind": "started", "pid": self.pid, "cwd": self.cwd,
                   "optimize": sys.flags.optimize}
        if self.version is not None:
            receipt.update(version=self.version, user=os.environ.get("USER"))
        self.record(receipt)
        write(sys.stderr.fileno(), STDERR_SENTINEL.encode())
        buffer = bytearray()
        with selectors.DefaultSelector() as selector:
            selector.register(sys.stdin.fileno(), selectors.EVENT_READ)
            while not (self.root / "abort").exists():
                if self.active and (self.root / f"finish-{self.pid}-{self.turns}").exists():
                    self.terminal("completed")
                for _key, _mask in selector.select(CONTROL_INTERVAL):
                    block = os.read(sys.stdin.fileno(), 4096)
                    if not block:
                        require(not buffer, "truncated client frame")
                        return
                    buffer.extend(block)
                    require(len(buffer) <= FRAME_LIMIT, "oversized client frame")
                    while b"\n" in buffer:
                        raw, _, rest = buffer.partition(b"\n")
                        buffer = bytearray(rest)
                        self.handle(json.loads(raw, object_pairs_hook=pairs))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path)
    parser.add_argument("--mode", choices=("hold", "continue"), default="hold")
    parser.add_argument("--version", choices=("V1", "V2"))
    parser.add_argument("--hook-gate", choices=("open", "held"), default="open")
    parser.add_argument("--after-run", action="store_true")
    parser.add_argument("--fd-headroom", type=int)
    parser.add_argument("--fd-receipt", type=Path)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    arguments = parser.parse_args()
    if arguments.fd_headroom is not None:
        fd_exec(arguments)
        return
    if arguments.after_run:
        after_run(arguments)
        return
    require(arguments.root is not None and arguments.root.is_dir(), "missing owned control root")
    peer = Peer(arguments.root, arguments.mode, arguments.version)
    try:
        peer.run()
    except (ValueError, OSError) as error:
        peer.record({"kind": "defect", "class": type(error).__name__, "message": str(error)})
        raise


if __name__ == "__main__":
    main()
