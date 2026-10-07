"""Execute a fixed corpus, seal raw evidence, then hand it to an offline judge."""

import base64
import json
import os
import shutil
import signal
import subprocess
import time
from pathlib import Path

from .assets import decode, digest, load, resource
from .driver.capture import OutputLimit, SignalScope
from .driver.errors import Failures
from .driver.journal import Journal, seal
from .driver.process import Process
from .driver.tracker import Tracker
from . import profiles

OUTPUT_LIMIT = 1024 * 1024


def run(output, profile_id, candidate=None, fault=None):
    scope = SignalScope()
    primary = None
    notes = Failures()
    result = None

    def retain(stage, error):
        nonlocal primary
        # Host cancellation survives later cleanup defects with its identity.
        if primary is None:
            primary = (stage, error, error.__traceback__)
            return
        if not isinstance(error, Exception) and isinstance(primary[1], Exception):
            previous, primary = primary, (stage, error, error.__traceback__)
            notes.record(previous[0] + ": " + type(previous[1]).__name__ + ": " + str(previous[1]))
            return
        if error is not primary[1]:
            notes.record(stage + ": " + type(error).__name__ + ": " + str(error))

    try:
        scope.open()
        result = _execute(output, profile_id, candidate, fault, scope)
    except BaseException as error:
        retain("execution", error)

    # Evidence is sealed before the last cancellation collector is released.
    try:
        scope.check()
    except BaseException as error:
        retain("host cancellation", error)
    try:
        for stage, _, error, _ in scope.close():
            retain(stage, error)
    except BaseException as error:
        retain("signal close", error)
    if primary is None or isinstance(primary[1], Exception):
        try:
            scope.check()
        except BaseException as error:
            retain("host cancellation", error)
    if primary is not None:
        _, error, trace = primary
        for message in notes.samples():
            BaseException.add_note(error, message)
        raise error.with_traceback(trace)
    return result


def _execute(output, profile_id, candidate, fault, scope):
    root = Path(output).absolute()
    root.mkdir(parents=True, exist_ok=False)
    root = root.resolve(strict=True)
    corpus = load("corpus/lifecycle.json")
    profile = load("profiles/" + profile_id + ".json")
    asset_root = root / "assets"
    shutil.copytree(str(resource(".")), asset_root)
    run_root = root / "run"
    run_root.mkdir()
    control_root = run_root / "control"
    control_root.mkdir()
    workspace_root = run_root / "workspaces"
    workspace = workspace_root / corpus["issue_identifier"]
    journal = Journal(root)
    process = None
    failed_snapshot = None
    tracker = None
    errors = []
    cancellation = None
    cleanup_errors = Failures()
    completed = False
    pending = {"stdout": bytearray(), "stderr": bytearray()}
    seen_workspace = False

    def failure(label, error):
        nonlocal cancellation
        message = label + ": " + type(error).__name__ + ": " + str(error)
        errors.append(message)
        cleanup_errors.record(message)
        if not isinstance(error, Exception) and cancellation is None:
            cancellation = error

    def observe(kind, data):
        journal.emit(kind, data)
        if kind not in {"capture.stdout", "capture.stderr"}:
            return
        stream = kind.split(".")[1]
        if stream != profile["observation_stream"]:
            return
        pending[stream].extend(base64.b64decode(data["data_b64"], validate=True))
        while b"\n" in pending[stream]:
            line, _, rest = pending[stream].partition(b"\n")
            pending[stream] = bytearray(rest)
            try:
                value = profiles.observation(profile, line)
            except (UnicodeError, ValueError, TypeError) as error:
                journal.emit("candidate.observation_error", {"stream": stream,
                             "error_type": type(error).__name__, "line_b64": base64.b64encode(line).decode("ascii")})
                continue
            if value is not None:
                journal.emit("candidate.observation", value, "profile:" + profile_id)

    def rows(kind):
        return journal.rows(kind)

    def workspace_state():
        nonlocal seen_workspace
        if workspace.is_dir() and not seen_workspace:
            journal.emit("workspace.created", {"path": str(workspace)})
            seen_workspace = True
        if seen_workspace and not workspace.exists() and not rows("workspace.removed"):
            journal.emit("workspace.removed", {"path": str(workspace)})

    def frames(kind):
        return [(row, decode(base64.b64decode(row["data"]["frame"], validate=True)))
                for row in rows(kind)]

    try:
        collector = journal.start()
        tracker = Tracker(corpus, journal, asset_root / "tls/server.pem", asset_root / "tls/server.key")
        plan_path = root / "plan.json"
        plan = {"schema_version": 1, "profile_id": profile_id, "profile": profile,
                "corpus": corpus, "collector_url": collector, "endpoint": tracker.endpoint,
                "ca": str(asset_root / "tls/ca.pem"), "control_root": str(control_root),
                "workspace_root": str(workspace_root), "bundle": str(root), "fault": fault}
        plan_path.write_text(json.dumps(plan, indent=2) + "\n")
        workflow_path = run_root / "WORKFLOW.md"
        profiles.workflow(workflow_path, plan_path, tracker.endpoint, corpus, workspace_root)
        argv = profiles.launch(profile, candidate, workflow_path, asset_root / "tls/ca.pem", plan_path)
        env = profiles.environment(profile, run_root, corpus)
        journal.emit("control.launch", {"argv": argv, "environment": env})
        scope.check()
        process = Process(argv, cwd=run_root, env=env, output_limit=OUTPUT_LIMIT,
                          deadline=time.monotonic() + corpus["run_budget_seconds"], emit=observe)
        process.wait_for(lambda: any(item["data"].get("event") in {"service_ready", "ready"}
                                     for item in rows("candidate.observation")), corpus["deadline_seconds"])

        def second_turn():
            workspace_state()
            starts = [(row, frame) for row, frame in frames("peer.client")
                      if frame.get("method") == "turn/start"]
            if len(starts) < 2:
                return False
            request, frame = starts[1]
            turn = corpus["turn_ids"][1]
            acknowledged = any(
                row["data"]["peer_id"] == request["data"]["peer_id"]
                and row["seq"] > request["seq"] and "method" not in reply
                and type(reply.get("id")) is type(frame["id"]) and reply.get("id") == frame["id"]
                and reply.get("result", {}).get("turn", {}).get("id") == turn
                for row, reply in frames("peer.server"))
            # A written reply does not prove the candidate accepted the turn.
            accepted = any(row["data"].get("event") == "turn_started"
                           and row["data"].get("turn_id") == turn
                           and row["data"].get("session_id") == corpus["thread_id"] + "-" + turn
                           for row in rows("candidate.observation"))
            return acknowledged and accepted

        process.wait_for(second_turn, corpus["deadline_seconds"])
        tracker.terminal()

        def removed():
            workspace_state()
            retained = any(row["data"].get("event") == "workspace_retained"
                           for row in rows("candidate.observation"))
            return bool(rows("workspace.removed")) or retained

        process.wait_for(removed, corpus["deadline_seconds"])
        process.signal(signal.SIGTERM)
        status = process.join(corpus["deadline_seconds"])
        if status != 0:
            raise subprocess.CalledProcessError(status, argv)
        completed = True
    except BaseException as error:
        failed_snapshot = getattr(error, "_process_snapshot", None)
        if not isinstance(error, Exception):
            cancellation = error
        if process is not None and isinstance(error, (subprocess.CalledProcessError, subprocess.TimeoutExpired, OutputLimit)):
            # A candidate verdict is separate from ownership and recorder health.
            try:
                journal.emit("candidate.execution_failure", {"error_type": type(error).__name__,
                              "returncode": process.snapshot()["returncode"]})
                if process.snapshot()["returncode"] is None:
                    process.signal(signal.SIGTERM)
                if not any(row["data"].get("operation") == "join" for row in rows("candidate.wait")):
                    process.join(corpus["deadline_seconds"])
                completed = True
            except BaseException as cleanup:
                failure("candidate failure cleanup", cleanup)
        else:
            errors.append(type(error).__name__ + ": " + str(error))
    finally:
        def attempt(label, action):
            try:
                return action()
            except BaseException as error:
                failure(label, error)
                return None

        if attempt("workspace lookup", workspace.exists):
            attempt("retained workspace receipt", lambda: journal.emit("workspace.retained", {"path": str(workspace)}))
        if tracker is not None:
            attempt("provider", tracker.close)
        for declaration in attempt("descendant declarations", lambda: rows("control.descendant.started")) or ():
            def probe(declaration=declaration):
                pid = declaration["data"].get("pid")
                if type(pid) is not int or pid <= 0 or process is None:
                    raise ValueError("Invalid fixture descendant declaration")
                alive = True
                group = None
                try:
                    group = os.getpgid(pid)
                    os.kill(pid, 0)
                except ProcessLookupError:
                    alive = False
                journal.emit("descendant.observed", {"pid": pid, "pgid": group, "alive": alive})
                if alive and group != process.snapshot()["pid"]:
                    raise ValueError("Fixture descendant escaped harness custody")
            attempt("descendant probe", probe)
        for label, close in (("process", process.close if process else None),):
            if close is None:
                continue
            attempt(label, close)
        snapshot = attempt("process snapshot", process.snapshot) if process is not None else failed_snapshot
        if snapshot is not None:
            for stream in ("stdout", "stderr"):
                attempt("capture " + stream, lambda stream=stream: (root / (stream + ".bin")).write_bytes(snapshot[stream]))
            failures = attempt("process failures", lambda: snapshot["failures"]) or ()
            errors.extend("process: " + str(value) for value in failures)
            receipt = attempt("process receipt fields", lambda: {
                key: value for key, value in snapshot.items() if key not in {"stdout", "stderr"}})
            attempt("process receipt", lambda: (root / "process.json").write_text(json.dumps(receipt, indent=2) + "\n"))
        if tracker is not None:
            errors.extend(attempt("provider errors", tracker.errors) or ())
        attempt("journal", journal.close)
        errors.extend(attempt("journal errors", journal.errors) or ())
        identities = attempt("asset identities", lambda: {
            "catalog": digest("catalog.json"), "corpus": digest("corpus/lifecycle.json"),
            "protocol": digest("protocol/manifest.json"), "profile": digest("profiles/" + profile_id + ".json")})
        try:
            seal(root, {"profile_id": profile_id, "corpus_id": corpus["id"],
                        "completed": completed, "harness_errors": errors, "identities": identities})
        except BaseException as error:
            if cancellation is None:
                raise
            failure("seal", error)
    # Host control flow resumes after custody release and evidence retention.
    if cancellation is not None:
        for message in cleanup_errors.samples():
            BaseException.add_note(cancellation, message)
        raise cancellation
    return root
