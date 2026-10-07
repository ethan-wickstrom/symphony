"""Independent scripted calibration candidate, not a conforming Symphony port."""

import argparse
from contextlib import ExitStack
from enum import Enum
from http import HTTPStatus
import json
import os
from pathlib import Path
import shutil
import signal
import ssl
import sys
import threading
import time
import urllib.request

from .assets import decode
from .driver.observer import Observer
from .driver.process import Custody, Process, Stdin
from .profiles import command
from .schema import Schema

OUTPUT_LIMIT = 1024 * 1024
STDIN_LIMIT = 1024 * 1024
TRACKER_BODY_LIMIT = 512 * 1024
PAGE_SIZE = 2
TRACKER_SECRET_NAME = "LINEAR_API_KEY"
FAULT_APPROVAL_POLICY = "on-request"
FAULT_THREAD_SUFFIX = "-other"
TOKEN_FIELDS = {
    "input_tokens": "inputTokens",
    "output_tokens": "outputTokens",
    "total_tokens": "totalTokens",
}
SELECTION = "id identifier title state { name }"
CANDIDATES_QUERY = (
    "query PortableRoster($scope: IssueFilter!, $pageWindow: Int!) "
    "{ chosen: issues(filter: $scope, first: $pageWindow) { nodes { "
    + SELECTION + " } } }"
)
IDS_QUERY = (
    "query PortableReconcile($opaqueKeys: [ID!]!, $pageWindow: Int!) "
    "{ chosen: issues(filter: {id: {in: $opaqueKeys}}, first: $pageWindow) "
    "{ nodes { " + SELECTION + " } } }"
)
QUIET_CHILD = "import os, time\nfor fd in (0, 1, 2):\n    os.close(fd)\ntime.sleep({lifetime})\n"


class Fault(Enum):
    DUPLICATE_DISPATCH = "duplicate-dispatch"
    SECRET_LEAK = "secret-leak"
    NEW_THREAD = "new-thread"
    MISSING_CLEANUP = "missing-cleanup"
    EARLY_HOOK = "hook-before-closure"
    DOUBLE_USAGE = "double-usage"
    ACK_ONLY = "ack-only"
    WRONG_HANDSHAKE = "wrong-handshake"
    LEAKED_CHILD = "leaked-child"


def _require(condition, message):
    if not condition:
        raise ValueError(message)


def _publish(event, **data):
    print(json.dumps({"event": event, **data}, separators=(",", ":"), allow_nan=False), flush=True)


def _environment(plan):
    profile = plan["profile"]
    names = [*profile["ambient_environment"], "HOME", "TMPDIR"]
    fake = plan["corpus"]["fake_secret"]
    return {name: os.environ[name] for name in names
            if name in os.environ and name != TRACKER_SECRET_NAME and fake not in os.environ[name]}


class Rpc:
    def __init__(self, plan, plan_path, workspace, deadline, observer):
        self._plan = plan
        self._fault = Fault(plan["fault"]) if plan.get("fault") is not None else None
        self._schema = Schema()
        self._methods = {}
        self._frames = []
        self._pending = bytearray()
        self._offset = 0
        self._identity = 0
        self._usage = {name: 0 for name in TOKEN_FIELDS}
        env = _environment(plan)
        if self._fault is Fault.SECRET_LEAK:
            env[TRACKER_SECRET_NAME] = plan["corpus"]["fake_secret"]
        self._process = Process(
            command("peer", plan_path), cwd=workspace, env=env,
            output_limit=OUTPUT_LIMIT, deadline=deadline,
            emit=lambda kind, data: observer.emit("control.peer." + kind, data),
            stdin=Stdin.PIPE, stdin_limit=STDIN_LIMIT, custody=Custody.CHILD,
        )

    def _record_usage(self, frame):
        total = frame["params"]["tokenUsage"]["total"]
        for name, field in TOKEN_FIELDS.items():
            if self._fault is Fault.DOUBLE_USAGE:
                self._usage[name] += total[field]
            else:
                self._usage[name] = max(self._usage[name], total[field])
        _publish("usage", **self._usage)

    def _collect(self):
        raw = self._process.snapshot()["stdout"]
        self._pending.extend(raw[self._offset:])
        self._offset = len(raw)
        while b"\n" in self._pending:
            line, _, remainder = self._pending.partition(b"\n")
            self._pending = bytearray(remainder)
            frame = decode(line)
            method = self._methods.get(frame.get("id"))
            if "method" not in frame and method is None:
                raise ValueError("Peer replied to an unknown request")
            self._schema.validate(frame, "server", method=method)
            self._frames.append(frame)
            if frame.get("method") == "thread/tokenUsage/updated":
                self._record_usage(frame)

    def _wait(self, predicate):
        def ready():
            self._collect()
            return any(predicate(frame) for frame in self._frames)

        self._process.wait_for(ready, self._plan["corpus"]["deadline_seconds"])
        return next(frame for frame in self._frames if predicate(frame))

    def _write(self, frame):
        self._schema.validate(frame, "client")
        self._process.write((json.dumps(frame, separators=(",", ":"), allow_nan=False) + "\n").encode())

    def request(self, method, params):
        self._identity += 1
        identity = self._identity
        self._methods[identity] = method
        self._write({"id": identity, "method": method, "params": params})
        response = self._wait(lambda frame: "method" not in frame and frame.get("id") == identity)
        _require("result" in response, "Peer returned an RPC error")
        return response["result"]

    def notify(self, method):
        self._write({"method": method})

    def observe(self):
        self._process.pump(0)
        self._collect()

    def terminal(self, thread, turn, status):
        response = self._wait(lambda frame: frame.get("method") == "turn/completed"
                              and frame["params"]["threadId"] == thread
                              and frame["params"]["turn"]["id"] == turn)
        _require(response["params"]["turn"]["status"] == status, "Unexpected terminal status")

    def close(self):
        self._process.close()

    def finish(self):
        self._process.close_stdin()
        status = self._process.join(self._plan["corpus"]["deadline_seconds"])
        self._collect()
        _require(not self._pending, "Peer output ended in a partial frame")
        self._process.close()
        _require(status == 0, "Peer exited unsuccessfully")


class Control:
    def __init__(self, plan, plan_path):
        self._plan = plan
        self._fault = Fault(plan["fault"]) if plan.get("fault") is not None else None
        self._plan_path = plan_path
        self._corpus = plan["corpus"]
        self._deadline = time.monotonic() + self._corpus["run_budget_seconds"]
        self._observer = Observer(plan["collector_url"], "control")
        self._workspace = Path(plan["workspace_root"]) / self._corpus["issue_identifier"]
        self._stop = threading.Event()
        context = ssl.create_default_context(cafile=plan["ca"])
        self._opener = urllib.request.build_opener(
            urllib.request.ProxyHandler({}), urllib.request.HTTPSHandler(context=context),
        )

    def _signal(self, _number, _frame):
        self._stop.set()

    def _query(self, query, operation, variables):
        raw = json.dumps({"query": query, "operationName": operation, "variables": variables},
                         separators=(",", ":"), allow_nan=False).encode()
        request = urllib.request.Request(
            self._plan["endpoint"], data=raw, method="POST",
            headers={"Authorization": os.environ[TRACKER_SECRET_NAME], "Content-Type": "application/json"},
        )
        timeout = min(self._corpus["candidate_read_timeout_ms"] / 1000,
                      self._deadline - time.monotonic())
        _require(timeout > 0, "Control budget expired")
        with self._opener.open(request, timeout=timeout) as response:
            _require(response.status == HTTPStatus.OK, "Tracker response was unsuccessful")
            body = response.read(TRACKER_BODY_LIMIT + 1)
        _require(len(body) <= TRACKER_BODY_LIMIT, "Tracker response exceeded budget")
        payload = decode(body)
        _require("errors" not in payload, "Tracker returned GraphQL errors")
        nodes = payload["data"]["chosen"]["nodes"]
        _require(type(nodes) is list, "Tracker nodes are not a list")
        return nodes

    def _refresh(self):
        nodes = self._query(IDS_QUERY, "PortableReconcile", {
            "opaqueKeys": [self._corpus["issue_id"]], "pageWindow": PAGE_SIZE,
        })
        _require(len(nodes) == 1 and nodes[0]["id"] == self._corpus["issue_id"],
                 "Opaque-ID refresh did not return the claimed issue")
        return nodes[0]

    def _hook(self, name):
        with Process(
            command("hooks", self._plan_path, "--name", name), cwd=self._workspace,
            env=_environment(self._plan), output_limit=OUTPUT_LIMIT,
            deadline=min(self._deadline, time.monotonic() + self._corpus["candidate_hook_timeout_ms"] / 1000),
            emit=lambda kind, data: self._observer.emit("control.hook." + kind, data),
            custody=Custody.CHILD,
        ) as hook:
            status = hook.join(self._corpus["candidate_hook_timeout_ms"] / 1000)
            _require(status == 0, "Hook exited unsuccessfully")

    def _start(self, peer):
        peer.request("initialize", {"clientInfo": {"name": "portable-calibration", "version": "1"}})
        peer.notify("initialized")
        approval = self._plan["profile"]["approval_policy"]
        if self._fault is Fault.WRONG_HANDSHAKE:
            approval = FAULT_APPROVAL_POLICY
        result = peer.request("thread/start", {
            "cwd": str(self._workspace), "approvalPolicy": approval,
            "sandbox": self._plan["profile"]["sandbox"], "ephemeral": True,
        })
        thread = result["thread"]["id"]
        peer.request("thread/name/set", {"threadId": thread, "name": self._corpus["issue_identifier"]})
        return thread

    def _turn(self, peer, thread, text):
        result = peer.request("turn/start", {
            "threadId": thread, "cwd": str(self._workspace),
            "approvalPolicy": self._plan["profile"]["approval_policy"],
            "input": [{"type": "text", "text": text}],
        })
        return result["turn"]["id"]

    def _wait_terminal(self, peer):
        while time.monotonic() < self._deadline:
            # Deliver owned-process cancellation before issuing another tracker read.
            peer.observe()
            if self._stop.is_set():
                return
            issue = self._refresh()
            if issue["state"]["name"] == self._corpus["terminal_state"]:
                return
            time.sleep(self._corpus["candidate_poll_ms"] / 1000)
        raise TimeoutError("Terminal reconciliation budget expired")

    def _leak_child(self):
        child = Process(
            [sys.executable, "-c", QUIET_CHILD.format(lifetime=self._corpus["run_budget_seconds"])],
            cwd=self._workspace, env=_environment(self._plan), output_limit=OUTPUT_LIMIT,
            deadline=self._deadline, custody=Custody.CHILD,
            emit=lambda kind, data: self._observer.emit("control.descendant." + kind, data),
        )
        pid = child.snapshot()["pid"]
        self._observer.emit("control.descendant.started", {"pid": pid, "pgid": os.getpgid(pid)})
        return child

    def _idle(self, child):
        while not self._stop.is_set():
            if child is not None:
                child.pump(0)
            remaining = self._deadline - time.monotonic()
            _require(remaining > 0, "Service shutdown budget expired")
            self._stop.wait(min(remaining, self._corpus["candidate_poll_ms"] / 1000))

    def run(self):
        peers = []
        with ExitStack() as owned:
            for number in (signal.SIGTERM, signal.SIGINT):
                previous = signal.signal(number, self._signal)
                owned.callback(signal.signal, number, previous)
            _publish("ready")
            nodes = self._query(CANDIDATES_QUERY, "PortableRoster", {
                "scope": {"project": {"slugId": {"eq": self._corpus["project"]}},
                          "state": {"name": {"in": [self._corpus["active_state"]]}}},
                "pageWindow": PAGE_SIZE,
            })
            _require(len(nodes) == 1, "Candidate roster did not contain one issue")
            issue = nodes[0]
            _require(issue["id"] == self._corpus["issue_id"], "Candidate identity changed")
            self._workspace.mkdir(parents=True)
            self._hook("after_create")
            self._hook("before_run")
            peer = Rpc(self._plan, self._plan_path, self._workspace, self._deadline, self._observer)
            peers.append(peer)
            owned.callback(peer.close)
            if self._fault is Fault.DUPLICATE_DISPATCH:
                duplicate = Rpc(self._plan, self._plan_path, self._workspace, self._deadline, self._observer)
                peers.append(duplicate)
                owned.callback(duplicate.close)
            thread = self._start(peer)
            turn = self._turn(peer, thread, issue["title"])
            peer.terminal(thread, turn, "completed")
            refreshed = self._refresh()
            _require(refreshed["state"]["name"] == self._corpus["active_state"], "Issue stopped before continuation")
            continued_thread = thread + FAULT_THREAD_SUFFIX if self._fault is Fault.NEW_THREAD else thread
            turn = self._turn(peer, continued_thread, "Continue the same issue.")
            self._wait_terminal(peer)
            peer.request("turn/interrupt", {"threadId": thread, "turnId": turn})
            if self._fault is not Fault.ACK_ONLY:
                peer.terminal(thread, turn, "interrupted")
            early_hook = self._fault is Fault.EARLY_HOOK
            if early_hook:
                self._hook("after_run")
            for child in peers:
                child.finish()
            if not early_hook:
                self._hook("after_run")
            self._hook("before_remove")
            # This calibration fault deliberately leaves a quiet child for outer custody.
            leaked = self._leak_child() if self._fault is Fault.LEAKED_CHILD else None
            if self._fault is not Fault.MISSING_CLEANUP:
                shutil.rmtree(self._workspace)
            else:
                _publish("workspace_retained")
            # The harness observes workspace removal before requesting shutdown.
            self._idle(leaked)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plan", type=Path, required=True)
    args = parser.parse_args()
    Control(decode(args.plan.read_bytes()), args.plan).run()


if __name__ == "__main__":
    main()
