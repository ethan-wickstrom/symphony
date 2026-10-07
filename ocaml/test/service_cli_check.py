#!/usr/bin/env python3
"""Physical local CLI acceptance: fake Linear HTTPS, JSONL peer, joined signals."""

import argparse
from contextlib import contextmanager
import hashlib
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import shlex
import signal
import subprocess
import sys
import tempfile
import threading
import time

from symphony_conformance.driver.process import Process as OwnedProcess
from symphony_conformance.driver import capture as capture_driver, process as process_driver
from symphony_conformance.assets import resource

TOKEN = "service-fixture-linear-key-never-print"
NEXT_TOKEN = "service-fixture-allowed-user"
OUTPUT_LIMIT = 1_048_576
REQUEST_LIMIT = 1_048_576
WAIT_SECONDS = 15
JOIN_SECONDS = 10
SERVICE_BUDGET_SECONDS = 120
FD_HEADROOM_MAX = 16
SESSION_EVENTS = frozenset(("session_started", "turn_started", "turn_completed"))
ISSUE_EVENTS = frozenset(("dispatch", "session_started", "turn_started", "turn_completed",
                          "hook", "worker_closed"))
FIXTURES = Path(__file__).resolve().parent / "fixtures"
PEER = FIXTURES / "agent" / "service_server.py"
TLS = Path(str(resource("tls")))
CA = TLS / "ca.pem"
TLS_FILES = ("ca.pem", "server.pem", "server.key", "manifest.json")
DRIVER_INPUTS = {
    "package-code/driver/capture.py": Path(capture_driver.__file__).resolve(),
    "package-code/driver/process.py": Path(process_driver.__file__).resolve(),
    "package-code/driver/sentinel.py": process_driver.SENTINEL.resolve(),
}
PYTHON = [sys.executable, "-B", "-I"]
if sys.flags.optimize:
    PYTHON.append("-OO" if sys.flags.optimize > 1 else "-O")


class AcceptanceError(Exception):
    pass


def input_path(relative):
    if relative.startswith("package-code/"):
        return DRIVER_INPUTS[relative]
    if relative.startswith("package/"):
        return Path(str(resource(relative.removeprefix("package/"))))
    return Path(__file__).resolve().parents[1] / relative


def require(condition, message):
    if not condition:
        raise AcceptanceError(message)


def connection(nodes):
    return {"nodes": nodes, "pageInfo": {"hasNextPage": False, "endCursor": None}}


def issue(identifier="LIN-A"):
    return {
        "id": "opaque:service-A", "identifier": identifier, "title": "Local service task",
        "description": None, "priority": 1, "state": {"name": "Doing"},
        "project": {"id": "fixture-project", "slugId": "fixture"},
        "labels": connection([]), "inverseRelations": connection([]),
        "createdAt": "2026-01-01T00:00:00Z", "updatedAt": None,
    }


class Provider:
    def __init__(self):
        self.changed = threading.Condition()
        self.nodes = []
        self.receipts = []
        self.defects = []
        self.dispositions = []
        self.gates = {}

    def hold(self, kind):
        require(kind not in self.gates, "duplicate provider gate")
        gate = threading.Event()
        self.gates[kind] = gate
        return gate

    def release(self):
        for gate in self.gates.values():
            gate.set()

    def set_issues(self, values):
        with self.changed:
            self.nodes = values

    def respond(self, path, authorization, body):
        require(path == "/graphql" and authorization in (TOKEN, NEXT_TOKEN), "wrong local tracker authority")
        require(body.get("operationName") == "SymphonyIssues", "unexpected GraphQL operation")
        variables = body.get("variables", {})
        require(variables.get("pageSize") == 50 and variables.get("after") is None,
                "fixture received unexpected pagination")
        selector = variables.get("filter", {})
        require(selector.get("project") == {"slugId": {"eq": "fixture"}}, "wrong project filter")
        if "id" in selector:
            ids = selector["id"].get("in")
            require(isinstance(ids, list) and all(isinstance(value, str) for value in ids),
                    "invalid opaque-ID filter")
            names = None
            kind = "ids"
        else:
            clauses = selector.get("or")
            require(isinstance(clauses, list) and clauses, "missing state selection")
            names = [value["state"]["name"]["eqIgnoreCase"] for value in clauses]
            require(all(isinstance(value, str) for value in names), "invalid state filter")
            ids = None
            kind = "terminal" if set(names) == {"done"} else "candidates"
            require(kind == "terminal" or set(names) == {"doing"}, "unexpected states")
        with self.changed:
            selected = [value for value in self.nodes if
                        (value["id"] in ids if ids is not None else
                         value["state"]["name"].lower() in names)]
            gate = self.gates.get(kind)
            self.receipts.append({"kind": kind, "ids": ids, "states": names,
                                  "authorization": "V1" if authorization == TOKEN else "V2",
                                  "response": "held" if gate is not None else "open",
                                  "returned": [value["id"] for value in selected]})
            require(len(self.receipts) <= 1000, "provider operation budget exhausted")
            self.changed.notify_all()
        if gate is not None:
            require(gate.wait(WAIT_SECONDS), "provider fixture gate expired")
        return {"data": {"issues": connection(selected)}}

    def wait(self, predicate, label):
        deadline = time.monotonic() + WAIT_SECONDS
        with self.changed:
            while not predicate(self.receipts):
                require(not self.defects, f"provider defect while waiting for {label}: {self.defects}")
                remaining = deadline - time.monotonic()
                require(remaining > 0, f"provider gate timed out: {label}")
                self.changed.wait(min(remaining, 0.1))


@contextmanager
def provider(evidence):
    state = Provider()

    class Handler(BaseHTTPRequestHandler):
        def setup(self):
            self.request.settimeout(5)
            super().setup()

        def log_message(self, *_args):
            pass

        def do_POST(self):
            try:
                length = int(self.headers.get("Content-Length", "0"))
                require(0 < length <= REQUEST_LIMIT, "provider request exceeds bound")
                raw = self.rfile.read(length)
                require(len(raw) == length, "truncated provider request")
                answer = state.respond(self.path, self.headers.get("Authorization"), json.loads(raw))
                data = json.dumps(answer, separators=(",", ":")).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.send_header("Connection", "close")
                self.end_headers()
                self.wfile.write(data)
                self.close_connection = True
            except (BrokenPipeError, ConnectionResetError, ssl.SSLEOFError) as error:
                # Shutdown may close an already-issued read before its response.
                with state.changed:
                    state.dispositions.append(type(error).__name__)
                    state.changed.notify_all()
                self.close_connection = True
            except (AcceptanceError, ValueError, KeyError, OSError) as error:
                with state.changed:
                    state.defects.append(type(error).__name__ + ":" + str(error))
                    state.changed.notify_all()
                self.close_connection = True

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = False
    import ssl
    tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    tls.load_cert_chain(TLS / "server.pem", TLS / "server.key")
    server.socket = tls.wrap_socket(server.socket, server_side=True, do_handshake_on_connect=False)
    thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.01})
    thread.start()
    primary = None
    try:
        yield state, server.server_address[1]
    except BaseException as error:
        primary = error
        raise
    finally:
        try:
            state.release()
            server.shutdown()
            server.server_close()
            thread.join(JOIN_SECONDS)
            require(not thread.is_alive(), "provider thread did not join")
            (evidence / "provider.json").write_text(json.dumps({
                "operations": state.receipts, "defects": state.defects,
                "closed_connections": state.dispositions,
            }, indent=2) + "\n")
        except BaseException as cleanup:
            if primary is None:
                raise
            primary.add_note("provider cleanup failed: " + type(cleanup).__name__)


def environment(root):
    allowed = ("PATH", "LANG", "LC_ALL", "USER", "LOGNAME")
    values = {name: os.environ[name] for name in allowed if name in os.environ}
    values.update(HOME=str(root), TMPDIR=str(root), LINEAR_API_KEY=TOKEN,
                  USER=NEXT_TOKEN, SERVICE_NEXT_KEY=NEXT_TOKEN,
                  SERVICE_SECRET_ALIAS=TOKEN, HTTPS_PROXY="http://127.0.0.1:1",
                  SSL_CERT_FILE="/missing/ambient.pem")
    return values


def source(root, port, version="V1", mode="hold", command=None, tag=None,
           credential=None, hook_gate="open"):
    extra = [] if tag is None else ["--version", tag]
    peer_command = shlex.join([*PYTHON, str(PEER), "--root", str(root / "control"), "--mode", mode, *extra])
    hook = shlex.join([*PYTHON, str(PEER), "--after-run", *extra, "--root",
                      str(root / "control"), "--hook-gate", hook_gate])
    key = "" if credential is None else f"    api_key: {json.dumps(credential)}\n"
    hook_timeout = WAIT_SECONDS * 1000 if hook_gate == "held" else 5000
    return (
        "---\ntracker:\n  kind: linear\n  active_states: [Doing]\n"
        "  terminal_states: [Done]\n  provider:\n    project_slug: fixture\n"
        f"{key}"
        f"    endpoint: https://127.0.0.1:{port}/graphql\n"
        "polling:\n  interval_ms: 100\nagent:\n  max_concurrent_agents: 1\n"
        f"  max_turns: {2 if mode == 'continue' else 1}\n"
        f"workspace:\n  root: ./workspaces\nhooks:\n  timeout_ms: {hook_timeout}\n"
        f"  after_run: {json.dumps(hook if command is None else 'printf closed > service-after-bad-shell')}\n"
        f"codex:\n  command: {json.dumps('exec ' + peer_command if command is None else command)}\n"
        "  read_timeout_ms: 5000\n  turn_timeout_ms: 30000\n---\n"
        f"CLI {version} {{{{ issue.identifier }}}}: {{{{ issue.title }}}}\n"
    )


def replace(path, text):
    pending = path.with_name(".workflow-pending")
    pending.write_text(text, encoding="utf-8")
    pending.replace(path)


def rewrite(path, text):
    before = path.stat()
    old = path.read_bytes()
    data = text.encode()
    require(len(data) == len(old) and data != old, "rewrite is not an equal-size change")
    with path.open("r+b") as output:
        require(output.write(data) == len(data), "short workflow fixture write")
    os.utime(path, ns=(before.st_atime_ns, before.st_mtime_ns))
    after = path.stat()
    require((before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns) ==
            (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns), "rewrite changed cache metadata")
    (path.parent / "rewrite.json").write_text(json.dumps({
        "before_sha256": hashlib.sha256(old).hexdigest(), "after_sha256": hashlib.sha256(data).hexdigest(),
        "device": after.st_dev, "inode": after.st_ino, "bytes": after.st_size,
        "mtime_ns": after.st_mtime_ns,
    }, indent=2) + "\n")


def records(control):
    values = []
    for path in sorted(control.glob("peer-*.jsonl")):
        raw = path.read_bytes()
        require(len(raw) <= OUTPUT_LIMIT, "peer receipt exceeds bound")
        # Poll only completed records; the writer may still own a partial tail.
        complete, _, _pending = raw.rpartition(b"\n")
        for line in complete.splitlines():
            values.append(json.loads(line))
    return values


def turns(control):
    return [value["message"] for value in records(control) if
            value.get("kind") == "rpc" and value["message"].get("method") == "turn/start"]


def started(control):
    return [value for value in records(control) if value.get("kind") == "started"]


def field(value):
    decoded = bytearray()
    at = 0
    while at < len(value):
        if value[at] != ord("\\"):
            decoded.append(value[at])
            at += 1
            continue
        escape = value[at:at + 4]
        require(len(escape) == 4 and escape[:2] == b"\\x" and
                all(byte in b"0123456789abcdef" for byte in escape[2:]), "invalid log field escape")
        decoded.append(int(escape[2:], 16))
        at += 4
    return decoded.decode("utf-8")


class Process:
    def __init__(self, binary, root, arguments, fd_headroom=None):
        self.root = root
        command = [str(binary), *arguments]
        if fd_headroom is not None:
            command = [*PYTHON, str(PEER), "--fd-headroom", str(fd_headroom),
                       "--fd-receipt", str(root / "fd.json"), "--", *command]
        self._owner = OwnedProcess(command, cwd=root, env=environment(root),
                                   output_limit=OUTPUT_LIMIT,
                                   deadline=time.monotonic() + SERVICE_BUDGET_SECONDS)

    @property
    def output(self):
        value = self._owner.snapshot()
        return {name: value[name] for name in ("stdout", "stderr")}

    def logs(self):
        return self.output["stderr"].decode("utf-8")

    def events(self):
        result = []
        complete, _, _pending = self.output["stderr"].rpartition(b"\n")
        for line in complete.splitlines():
            if not line.startswith(b"event="):
                continue
            fields = {}
            for part in line.split(b" "):
                name, separator, value = part.partition(b"=")
                require(separator and name and name.decode("ascii") not in fields,
                        "malformed structured log")
                fields[name.decode("ascii")] = field(value)
            result.append(fields)
        return result

    def wait(self, predicate, label):
        try:
            self._owner.wait_for(predicate, WAIT_SECONDS)
        except (subprocess.TimeoutExpired, subprocess.CalledProcessError) as error:
            raise AcceptanceError(f"service gate failed: {label}; {self.logs()}") from error

    def event(self, name):
        return [value for value in self.events() if value.get("event") == name]

    def joined(self):
        status = self._owner.join(JOIN_SECONDS)
        require(all(token not in self.logs() and token.encode() not in self.output["stdout"]
                    for token in (TOKEN, NEXT_TOKEN)),
                "tracker credential leaked to CLI output")
        check_context(self.events())
        return status

    def signal(self, selected):
        self._owner.signal(selected)

    def stop(self, selected):
        self.signal(selected)
        self.stopped(selected)

    def stopped(self, selected):
        require(self.joined() == 0, "normal signal shutdown exited nonzero")
        require(len(self.event("service_stopped")) == 1, "missing/duplicate service_stopped")
        values = self.event("shutdown_requested")
        require(len(values) == 1 and values[0].get("signal") == selected.name,
                "shutdown log lost actual signal")
        require(not self.output["stdout"], "service wrote unexpected stdout")

    def cleanup(self):
        primary = None
        for action in ((self.root / "control" / "abort").touch,
                       (self.root / "control" / "release-after-run").touch,
                       self._owner.close):
            try:
                action()
            except BaseException as error:
                if primary is None:
                    primary = error
                else:
                    primary.add_note("secondary cleanup failure: " + type(error).__name__)
        value = self._owner.snapshot()
        try:
            (self.root / "ownership.json").write_text(json.dumps({
                "pid": value["pid"], "guard_pid": value["guard_pid"],
                "returncode": value["returncode"], "reaped": value["reaped"],
                "closed": value["closed"], "lifecycle": value["lifecycle"],
                "failures": value["failures"],
            }, indent=2) + "\n")
        except BaseException as error:
            if primary is None:
                primary = error
            else:
                primary.add_note("receipt failure: " + type(error).__name__)
        if primary is not None:
            raise primary


@contextmanager
def running(binary, root, arguments, fd_headroom=None):
    process = Process(binary, root, arguments, fd_headroom)
    primary = None
    try:
        yield process
    except BaseException as error:
        primary = error
        raise
    finally:
        cleanup_error = None
        actions = [process.cleanup,
                   lambda: (root / "stdout.log").write_bytes(process.output["stdout"]),
                   lambda: (root / "stderr.log").write_bytes(process.output["stderr"]),
                   lambda: (root / "peer.json").write_text(json.dumps(records(root / "control"), indent=2) + "\n")]
        for action in actions:
            try:
                action()
            except BaseException as cleanup:
                if primary is not None:
                    primary.add_note("owned process cleanup failed: " + type(cleanup).__name__)
                elif cleanup_error is None:
                    cleanup_error = cleanup
                else:
                    cleanup_error.add_note("secondary cleanup failure: " + type(cleanup).__name__)
        if primary is None and cleanup_error is not None:
            raise cleanup_error


def arguments(workflow, style):
    leading = ["run"] if style == "run" else []
    return [*leading, *([] if style == "default" else [str(workflow)]), "--ca-bundle", str(CA)]


def check_context(events):
    # Closure context is derived from the actual preceding run's session events.
    for index, event in enumerate(events):
        if event["event"] not in ISSUE_EVENTS:
            continue
        require(event.get("issue_id") and event.get("issue_identifier"),
                "issue event lacks spec identity: " + event["event"])
        require("identifier" not in event, "obsolete issue context field")
        if event["event"] == "hook":
            continue
        require(event.get("run_id"), "worker event lacks generation: " + event["event"])
        dispatches = [value for value in events[:index + 1] if value["event"] == "dispatch"
                      and value.get("run_id") == event["run_id"]]
        require(len(dispatches) == 1 and all(event[key] == dispatches[0][key]
                                           for key in ("issue_id", "issue_identifier")),
                "issue event lost dispatched context: " + event["event"])
        if event["event"] in SESSION_EVENTS:
            require(event.get("session_id"), "session event lacks checked session identity")
        if event["event"] != "worker_closed":
            continue
        sessions = [value for value in events[:index] if
                    (value["event"] in SESSION_EVENTS or value["event"] == "unsupported_tool")
                    and value.get("session_id") and value.get("issue_id") == event["issue_id"]
                    and value.get("run_id") == event["run_id"]]
        if sessions:
            require(event.get("session_state") == "started" and
                    event.get("session_id") == sessions[-1]["session_id"],
                    "closed worker lost last observed session")
        else:
            require(event.get("session_state") == "not_started" and "session_id" not in event,
                    "closed worker fabricated/missed unstarted session state")


def check_fd_startup(binary, base):
    root = base / "startup-fd-exhaustion"
    root.mkdir()
    workflow = root / "WORKFLOW.md"
    replace(workflow, source(root, 1))
    attempts = []
    selected = None
    for headroom in range(1, FD_HEADROOM_MAX + 1):
        probe = root / f"doctor-{headroom}"
        (probe / "control").mkdir(parents=True)
        with running(binary, probe, ["doctor", str(workflow)], headroom) as process:
            status = process.joined()
            receipt = json.loads((probe / "fd.json").read_text())
            require(receipt["free"] == headroom and receipt["optimize"] == sys.flags.optimize,
                    "FD launcher did not establish requested budget/mode")
            attempts.append({"headroom": headroom, "doctor_status": status,
                             "receipt": str(probe.relative_to(root) / "fd.json")})
            if status == 0:
                selected = headroom
                break
    require(selected is not None, "no doctor startup within bounded descriptor calibration")
    service = root / "service"
    (service / "control").mkdir(parents=True)
    with running(binary, service, arguments(workflow, "direct"), selected) as process:
        status = process.joined()
        receipt = json.loads((service / "fd.json").read_text())
        require(receipt["free"] == selected, "doctor/service descriptor budget differs")
        observed = process.events()
        require(status != 0 and not process.output["stdout"], "exhausted service reported successful startup")
        require(observed == [{"event": "host_startup_failure", "reason": "signal_setup"}],
                "signal setup failure lacks fixed pre-output startup record")
        require(bytes(process.output["stderr"]) == b"event=host_startup_failure reason=signal_setup\n",
                "startup failure exposed raw error payload")
    (root / "budget.json").write_text(json.dumps({
        "attempts": attempts, "selected_headroom": selected,
        "doctor_status": 0, "service_status": status,
        "boundary": "controlled inherited fillers in isolated exec; doctor shares workflow and FD budget",
    }, indent=2) + "\n")
    for name in ("stdout.log", "stderr.log", "peer.json"):
        (root / name).write_bytes((service / name).read_bytes())


def assert_closed(root, process):
    peer_records = records(root / "control")
    require(not [value for value in peer_records if value.get("kind") == "defect"], "peer protocol defect")
    started = [value for value in peer_records if value.get("kind") == "started"]
    require(len(started) == 1, "expected exactly one app-server acquisition")
    require(started[0]["optimize"] == sys.flags.optimize, "fixture child did not use requested optimization mode")
    marker = Path(started[0]["cwd"]) / "service-after-run.jsonl"
    require(marker.is_file(), "after_run did not follow joined app-server closure")
    completed = [json.loads(line) for line in marker.read_text().splitlines()]
    require(completed == [{"pid": started[0]["pid"], "closed": True}], "wrong/duplicate after_run receipt")
    reaped(started[0]["pid"])
    require("fixture-stderr-never-render" not in process.logs(), "untrusted agent stderr escaped")
    require(process.event("worker_closed"), "closed worker outcome was not visible")
    hooks = [value for value in process.event("hook") if value.get("hook") == "after_run"]
    require(any(value.get("phase") == "finished" and value.get("outcome") == "succeeded"
                for value in hooks), "after_run success not visible")


def reaped(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        pass
    else:
        raise AcceptanceError("app-server PID remains after service_stopped")


def check_startup(binary, base, case, content, style="direct", expected=()):
    root = base / case
    root.mkdir()
    (root / "control").mkdir()
    workflow = root / "WORKFLOW.md"
    if content is not None:
        workflow.write_text(content(root) if callable(content) else content)
    with running(binary, root, arguments(workflow, style)) as process:
        require(process.joined() != 0, "invalid startup exited successfully")
        require(process.logs() and "WORKFLOW.md" in process.logs(), "startup error lacks file context")
        require(all(value in process.logs().lower() for value in expected),
                "startup failed outside the intended boundary: " + process.logs())
        require(not process.event("service_started"), "invalid startup activated service")


def check_service(binary, base, case, style="direct", mode="hold", selected=signal.SIGTERM,
                  reload=None, escaped=False, fresh=False, bad_shell=False, idle=False,
                  workflow_name="WORKFLOW.md", edit="replace", provider_case="regular"):
    root = base / case
    root.mkdir()
    control = root / "control"
    control.mkdir()
    workflow = root / workflow_name
    with provider(root) as (state, port):
        version = "V1"
        text = source(root, port, version, mode,
                      "exec /fixture-no-such-codex" if bad_shell else None)
        replace(workflow, text)
        if not (idle or reload or fresh):
            nodes = [issue("LIN-A\nevent=forged" if escaped else "LIN-A")]
            if provider_case == "omission":
                malformed = issue("LIN-OMITTED\nevent=forged")
                malformed.update(id="opaque:omitted", title=None)
                nodes.append(malformed)
            state.set_issues(nodes)
        with running(binary, root, arguments(workflow, style)) as process:
            process.wait(lambda: bool(process.event("service_started")), "service startup")
            state.wait(lambda values: any(value["kind"] == "candidates" for value in values),
                       "first candidate cycle")
            if idle:
                process.wait(lambda: bool(process.event("service_ready")), "initial startup cleanup barrier")
                state.wait(lambda values: sum(value["kind"] == "candidates" for value in values) >= 2,
                           "second healthy idle cycle")
                require(not turns(control) and not process.event("dispatch"), "idle service dispatched")
                require(len(process.event("service_started")) == 1 and
                        len(process.event("service_ready")) == 1 and
                        len(process.logs().splitlines()) == 2, "healthy idle cycle produced noise")
            else:
                if reload:
                    invalid = {
                        "yaml": "---\n[broken\n---\ninvalid\n",
                        "settings": text.replace("interval_ms: 100", "interval_ms: 0"),
                        "template": text.rsplit("---\n", 1)[0] + "---\n{% if %}\n",
                    }[reload]
                    replace(workflow, invalid)
                    process.wait(lambda: bool(process.event("workflow_invalid")), "invalid reload observed")
                    seen = len(process.event("workflow_invalid"))
                    state.set_issues([issue()])
                    process.wait(lambda: len(process.event("workflow_invalid")) > seen,
                                 "another invalid preflight gates new work")
                    require(not turns(control) and not process.event("dispatch"), "invalid reload admitted work")
                if reload or fresh:
                    version = "V2"
                    edited = source(root, port, version, mode)
                    if edit == "same-size":
                        rewrite(workflow, edited)
                    else:
                        require(edit == "replace", "unknown workflow edit fixture")
                        replace(workflow, edited)
                    state.set_issues([issue()])
                if bad_shell:
                    process.wait(lambda: bool(process.event("worker_closed")), "failed shell attempt closes")
                    require(any(value.get("outcome") == "failed" for value in process.event("worker_closed")),
                            "shell launch failure was silent")
                else:
                    process.wait(lambda: len(turns(control)) >= (2 if mode == "continue" else 1),
                                 "actual app-server turn admission")
                    rpc = turns(control)
                    expected_id = "LIN-A\nevent=forged" if escaped else "LIN-A"
                    require(rpc[0]["params"]["input"][0]["text"] ==
                            f"CLI {version} {expected_id}: Local service task", "launch used stale prompt/config")
                    require(len({value["params"]["threadId"] for value in rpc}) == 1,
                            "in-process continuation started a fresh thread")
                    if mode == "continue":
                        require("CLI V1" not in rpc[1]["params"]["input"][0]["text"],
                                "continuation resent full task")
                    dispatches = process.event("dispatch")
                    require(len(dispatches) == 1 and dispatches[0].get("issue_id") == "opaque:service-A"
                            and dispatches[0].get("issue_identifier") == expected_id
                            and dispatches[0].get("run_id"), "dispatch lacks canonical identity/generation")
                    require(not process.event("forged"), "identifier forged an additional log record")
                    if provider_case == "omission":
                        diagnostics = [value.get("diagnostic", "") for value in process.event("tracker_omission")]
                        # Diagnostic.render doubles the %S projection's backslash.
                        expected = ('tracker=linear issue_id="opaque:omitted" '
                                    r'issue_identifier="LIN-OMITTED\\nevent=forged": '
                                    'Linear issue omitted: title must be a string; '
                                    'Supply a nonempty string for title in the issue record')
                        require(expected in diagnostics,
                                "malformed node omission lost checked identity/reason context")
            process.stop(selected)
            if not (idle or bad_shell):
                assert_closed(root, process)
                closed = process.event("worker_closed")
                require(any(value.get("outcome") == "canceled" and value.get("reason") == "host_shutdown"
                            for value in closed), "signal did not close active worker by host shutdown")
            require(not state.defects, f"provider defects: {state.defects}")


def check_frozen(binary, base):
    root = base / "frozen-attempt-reload"
    root.mkdir()
    control = root / "control"
    control.mkdir()
    workflow = root / "WORKFLOW.md"
    with provider(root) as (state, port):
        state.set_issues([issue()])
        replace(workflow, source(root, port, tag="V1"))
        with running(binary, root, arguments(workflow, "direct")) as process:
            process.wait(lambda: len(turns(control)) == 1, "original frozen turn")
            original = started(control)[0]
            require(original["version"] == "V1" and original["user"] == NEXT_TOKEN,
                    "original public environment did not reach owned agent")
            before = len(state.receipts)
            updated = source(root, port, version="V2", tag="V2", credential="$SERVICE_NEXT_KEY")
            updated = updated.replace("read_timeout_ms: 5000", "read_timeout_ms: 6000")
            replace(workflow, updated.replace("max_concurrent_agents: 1", "max_concurrent_agents: 2"))
            # Two following read cycles contain a fresh preflight between them.
            state.wait(lambda values: sum(value["kind"] == "ids" and value["authorization"] == "V1"
                                         for value in values[before:]) >= 2,
                       "active run retains original tracker authority across reload")
            state.wait(lambda values: any(value["kind"] == "candidates" and value["authorization"] == "V2"
                                         for value in values[before:]),
                       "new policy accepted while original attempt remains active")
            require(len(started(control)) == 1 and len(turns(control)) == 1,
                    "valid reload replaced the live run")
            (control / f"finish-{original['pid']}-1").touch()
            process.wait(lambda: len(started(control)) == 2 and len(turns(control)) == 2,
                         "next attempt admits current valid launch settings")
            next_peer = [value for value in started(control) if value["pid"] != original["pid"]][0]
            require(next_peer["version"] == "V2" and next_peer["user"] is None,
                    "next attempt retained old command or exposed new credential alias")
            rpc = {value["params"]["threadId"]: value["params"]["input"][0]["text"]
                   for value in turns(control)}
            require(rpc[f"service-thread-{original['pid']}"] == "CLI V1 LIN-A: Local service task" and
                    rpc[f"service-thread-{next_peer['pid']}"] == "CLI V2 LIN-A: Local service task",
                    "old/new attempts did not use their respective frozen prompts")
            require(any(value["kind"] == "ids" and value["authorization"] == "V2"
                        for value in state.receipts), "retry refresh reused obsolete tracker authority")
            process.stop(signal.SIGTERM)
            require(original["cwd"] == next_peer["cwd"], "same-scope reload moved workspace")
            marker = Path(original["cwd"]) / "service-after-run.jsonl"
            rows = [json.loads(line) for line in marker.read_text().splitlines()]
            require(rows == [
                {"pid": original["pid"], "closed": True, "version": "V1", "user": NEXT_TOKEN},
                {"pid": next_peer["pid"], "closed": True, "version": "V2", "user": None},
            ], "after_run did not retain original hook/environment then adopt new settings")
            for value in started(control):
                reaped(value["pid"])
                require(value["optimize"] == sys.flags.optimize, "wrong child optimization")
            dispatches = process.event("dispatch")
            require(len(dispatches) == 2 and len({value["run_id"] for value in dispatches}) == 2,
                    "next attempt reused a run generation")
            require([value.get("outcome") for value in process.event("worker_closed")] ==
                    ["succeeded", "canceled"], "reload attempt terminal outcomes are wrong")
            require(not state.defects, f"provider defects: {state.defects}")


def check_held_read(binary, base, kind):
    case = "shutdown-held-" + kind + "-read"
    root = base / case
    root.mkdir()
    control = root / "control"
    control.mkdir()
    workflow = root / "WORKFLOW.md"
    with provider(root) as (state, port):
        gate = state.hold(kind)
        if kind == "ids":
            state.set_issues([issue()])
        replace(workflow, source(root, port))
        with running(binary, root, arguments(workflow, "direct")) as process:
            process.wait(lambda: bool(process.event("service_started")), "signal scope installed")
            if kind == "ids":
                process.wait(lambda: len(turns(control)) == 1, "active turn before reconciliation hold")
            state.wait(lambda values: any(value["kind"] == kind and value["response"] == "held"
                                         for value in values), "tracker response remains externally gated")
            process.stop(signal.SIGTERM)
            require(not gate.is_set(), "provider gate opened before service join")
            if kind == "ids":
                assert_closed(root, process)
            else:
                require(not started(control) and not process.event("dispatch"), "startup read hold admitted work")
            state.release()
            require(not state.defects, f"provider defects: {state.defects}")


def check_burst(binary, base):
    root = base / "signal-burst-during-after-run"
    root.mkdir()
    control = root / "control"
    control.mkdir()
    workflow = root / "WORKFLOW.md"
    with provider(root) as (state, port):
        state.set_issues([issue()])
        replace(workflow, source(root, port, hook_gate="held"))
        with running(binary, root, arguments(workflow, "direct")) as process:
            process.wait(lambda: len(turns(control)) == 1, "active turn before first signal")
            process.signal(signal.SIGTERM)
            marker = control / "hook-entered.json"
            process.wait(marker.is_file, "after_run entered after agent reap")
            process.wait(lambda: bool(process.event("shutdown_requested")), "first signal delivered")
            entered = json.loads(marker.read_text())
            require(entered["closed"] is True, "burst gate preceded agent closure")
            reaped(entered["pid"])
            burst = (signal.SIGINT, signal.SIGTERM, signal.SIGINT)
            for selected in burst:
                process.signal(selected)
            (control / "release-after-run").touch()
            process.stopped(signal.SIGTERM)
            assert_closed(root, process)
            (root / "signals.json").write_text(json.dumps({
                "sent": ["SIGTERM", *(value.name for value in burst)],
                "burst_after_agent_reap": entered,
            }, indent=2) + "\n")
            require(not state.defects, f"provider defects: {state.defects}")


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def source_hashes(paths):
    root = Path(__file__).resolve().parents[1]
    return {
        **{str(path.relative_to(root)): digest(path) for path in paths},
        **{"package/tls/" + name: digest(TLS / name) for name in TLS_FILES},
        **{name: digest(path) for name, path in DRIVER_INPUTS.items()},
    }


def run(binary, base):
    cases = []
    observed = {
        "schema": 1, "binary": {"path": str(binary), "sha256": digest(binary)},
        "python": {"executable": sys.executable, "resolved": str(Path(sys.executable).resolve()),
                   "optimize": sys.flags.optimize, "peer_argv": PYTHON},
        "sources": source_hashes((Path(__file__).resolve(), PEER)),
        "cases": cases,
        "boundary": "local HTTPS/JSONL executable observations; binary hash is context, not build attestation",
    }

    def persist():
        (base / "manifest.json").write_text(json.dumps(observed, indent=2) + "\n")

    persist()

    def record(name, check):
        started = time.monotonic()
        result = {"name": name, "status": "running", "receipts": name}
        cases.append(result)
        persist()
        try:
            check()
        except BaseException as error:
            result.update(status="failed", error=type(error).__name__, elapsed=time.monotonic() - started)
            try:
                persist()
            except OSError as secondary:
                error.add_note("evidence write failed: " + type(secondary).__name__)
            raise
        result.update(status="passed", elapsed=time.monotonic() - started)
        persist()

    record("missing-explicit", lambda: check_startup(binary, base, "missing-explicit", None))
    record("missing-default", lambda: check_startup(binary, base, "missing-default", None, "default"))
    record("startup-fd-exhaustion", lambda: check_fd_startup(binary, base))
    for name, content, expected in (
            ("bad-yaml-startup", "---\n[broken\n---\nx\n", ()),
            ("bad-template-startup", lambda root: source(root, 1).rsplit("---\n", 1)[0] + "---\n{% if %}\n",
             ("prompt",)),
            ("credential-public-startup", lambda root: source(root, 1).replace("root: ./workspaces", "root: $LINEAR_API_KEY"),
             ("workspace.root", "credential"))):
        record(name, lambda name=name, content=content, expected=expected:
               check_startup(binary, base, name, content, expected=expected))
    for style, selected in (("direct", signal.SIGINT), ("default", signal.SIGTERM), ("run", signal.SIGTERM)):
        name = "idle-" + style
        record(name, lambda style=style, selected=selected, name=name:
               check_service(binary, base, name, style=style, selected=selected, idle=True))
    for selected in (signal.SIGINT, signal.SIGTERM):
        name = "active-" + selected.name
        record(name, lambda selected=selected, name=name: check_service(binary, base, name, selected=selected))
    record("same-thread-continuation", lambda: check_service(binary, base, "same-thread-continuation", mode="continue"))
    record("fresh-preflight", lambda: check_service(binary, base, "fresh-preflight", fresh=True))
    for kind in ("yaml", "settings", "template"):
        name = "reload-" + kind
        record(name, lambda kind=kind, name=name: check_service(binary, base, name, reload=kind))
    record("shell-failure-visible", lambda: check_service(binary, base, "shell-failure-visible", bad_shell=True))
    record("escaped-untrusted-logs", lambda: check_service(binary, base, "escaped-untrusted-logs", escaped=True))
    record("frozen-attempt-reload", lambda: check_frozen(binary, base))
    for kind in ("terminal", "ids"):
        name = "shutdown-held-" + kind + "-read"
        record(name, lambda kind=kind: check_held_read(binary, base, kind))
    record("workflow-path-spaces", lambda: check_service(
        binary, base, "workflow-path-spaces", workflow_name="Workflow With Spaces.md"))
    record("same-size-preserved-mtime", lambda: check_service(
        binary, base, "same-size-preserved-mtime", fresh=True, edit="same-size"))
    record("signal-burst-during-after-run", lambda: check_burst(binary, base))
    record("tracker-omission-visible", lambda: check_service(
        binary, base, "tracker-omission-visible", provider_case="omission"))
    require(digest(binary) == observed["binary"]["sha256"], "runtime binary changed during acceptance")
    for relative, before in observed["sources"].items():
        require(digest(input_path(relative)) == before,
                "acceptance input changed during run: " + relative)
    observed["inputs_unchanged"] = True
    persist()
    print(f"Service CLI: {len(cases)} physical local scenarios passed")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("--out", type=Path, help="retain bounded logs and SHA-bound observation manifest in a fresh directory")
    values = parser.parse_args()
    binary = values.binary.resolve(strict=True)
    try:
        if values.out is not None:
            values.out.mkdir(parents=True, exist_ok=False)
            run(binary, values.out.resolve())
        else:
            with tempfile.TemporaryDirectory(prefix="symphony-service-cli-") as temporary:
                run(binary, Path(temporary))
    except (AcceptanceError, subprocess.TimeoutExpired) as error:
        print("Service CLI: " + str(error), file=sys.stderr)
        raise SystemExit(1) from error


if __name__ == "__main__":
    main()
