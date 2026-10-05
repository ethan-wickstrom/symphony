"""Physical loopback status API acceptance over the existing local service fixtures."""

import argparse
import hashlib
import http.client
import importlib.util
import json
import signal
import socket
import sys
import tempfile
import time
from enum import Enum
from pathlib import Path


FIXTURE_PATH = Path(__file__).resolve().with_name("service_cli_check.py")
SPEC = importlib.util.spec_from_file_location("symphony_status_service_fixture", FIXTURE_PATH)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError("Cannot load the declared service acceptance fixture")
SERVICE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SERVICE)

HTTP_TIMEOUT = 6
RESPONSE_LIMIT = 8 * 1024 * 1024
HEADER_LIMIT = 16 * 1024
POLL_INTERVAL_MS = 30000
OK = 200
ACCEPTED = 202
BAD_REQUEST = 400
NOT_FOUND = 404
METHOD_NOT_ALLOWED = 405
PAYLOAD_TOO_LARGE = 413
UNAVAILABLE = 503
require = SERVICE.require


class Port_case(Enum):
    WORKFLOW = "workflow"
    CLI_OVERRIDE = "cli_override"


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def persist(path, value):
    path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")


def query(port, method, path, body=b""):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=HTTP_TIMEOUT)
    try:
        connection.request(method, path, body=body, headers={"Connection": "close"})
        response = connection.getresponse()
        headers = {name.lower(): value for name, value in response.getheaders()}
        require(sum(len(name) + len(value) for name, value in headers.items()) <= HEADER_LIMIT,
                "status response headers exceed bound")
        data = response.read(RESPONSE_LIMIT + 1)
        require(len(data) <= RESPONSE_LIMIT, "status response exceeds bound")
        require(all(token.encode() not in data for token in (SERVICE.TOKEN, SERVICE.NEXT_TOKEN)),
                "credential appeared in HTTP response")
        require(b"fixture-stderr-never-render" not in data, "raw agent stderr appeared in HTTP response")
        return {"method": method, "path": path, "status": response.status,
                "headers": headers, "bytes": len(data), "sha256": hashlib.sha256(data).hexdigest(),
                "body": data.decode("utf-8")}
    finally:
        connection.close()


def value(response, expected):
    require(response["status"] == expected,
            f"{response['method']} {response['path']}: expected {expected}, got {response['status']}")
    require(response["headers"].get("content-type", "").startswith("application/json"),
            "API response lacks JSON content type")
    decoded = json.loads(response["body"])
    require(isinstance(decoded, dict), "API response is not an object")
    return decoded


def error(response, expected, code=None):
    decoded = value(response, expected)
    require(isinstance(decoded.get("error"), dict) and
            isinstance(decoded["error"].get("code"), str) and
            isinstance(decoded["error"].get("message"), str), "missing nested error envelope")
    if code is not None:
        require(decoded["error"]["code"] == code, "wrong API error code")


def ready(process):
    process.wait(lambda: bool(process.event("status_listening")), "HTTP listener readiness")
    events = process.event("status_listening")
    require(len(events) == 1 and set(events[0]) == {"event", "port"}, "listener log is not port-only")
    port = int(events[0]["port"])
    require(0 < port <= 65535, "invalid bound listener port")
    process.wait(lambda: bool(process.event("service_ready")), "owner status readiness")
    return port


def workflow(root, provider_port, configured=None, hook_gate="open"):
    text = SERVICE.source(root, provider_port, hook_gate=hook_gate)
    text = text.replace("interval_ms: 100", f"interval_ms: {POLL_INTERVAL_MS}")
    if configured is not None:
        text = text.replace("polling:\n", f"server:\n  port: {configured}\npolling:\n", 1)
    path = root / "WORKFLOW.md"
    SERVICE.replace(path, text)
    return path


def create(base, name):
    root = base / name
    root.mkdir()
    (root / "control").mkdir()
    return root


def args(path, port=None):
    values = SERVICE.arguments(path, "direct")
    if port is not None:
        values.extend(("--port", str(port)))
    return values


def closed(port):
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=1):
            pass
    except ConnectionRefusedError:
        return
    raise SERVICE.AcceptanceError("HTTP listener survived joined service shutdown")


def record(manifest, base, name, check, receipt=None):
    started = time.monotonic()
    entry = {"name": name, "status": "running", "receipts": receipt or name}
    manifest["cases"].append(entry)
    persist(base / "manifest.json", manifest)
    try:
        result = check()
        if result is not None:
            entry["observation"] = result
    except BaseException as failure:
        entry.update(status="failed", error=type(failure).__name__, elapsed=time.monotonic() - started)
        try:
            persist(base / "manifest.json", manifest)
        except OSError as secondary:
            failure.add_note("status evidence write failed: " + type(secondary).__name__)
        raise
    entry.update(status="passed", elapsed=time.monotonic() - started)
    persist(base / "manifest.json", manifest)


def check_off(binary, base):
    root = create(base, "disabled")
    with SERVICE.provider(root) as (state, provider_port):
        path = workflow(root, provider_port)
        with SERVICE.running(binary, root, args(path)) as process:
            process.wait(lambda: bool(process.event("service_ready")), "idle owner readiness")
            require(not process.event("status_listening"), "omitted HTTP port enabled listener")
            process.stop(signal.SIGTERM)
        require(not state.defects, "provider fixture defect")


def check_port(binary, base, name, selected):
    root = create(base, name)
    with socket.socket() as occupied:
        occupied.bind(("127.0.0.1", 0))
        occupied.listen(1)
        with SERVICE.provider(root) as (state, provider_port):
            configured = occupied.getsockname()[1] if selected is Port_case.CLI_OVERRIDE else 0
            path = workflow(root, provider_port, configured)
            override = 0 if selected is Port_case.CLI_OVERRIDE else None
            with SERVICE.running(binary, root, args(path, override)) as process:
                bound = ready(process)
                response = query(bound, "GET", "/api/v1/state")
                decoded = value(response, OK)
                require(decoded["counts"]["running"] == 0 and decoded["counts"]["retrying"] == 0,
                        "idle owner snapshot is not empty")
                persist(root / "http.json", response)
                process.stop(signal.SIGTERM)
                closed(bound)
            require(not state.defects, "provider fixture defect")


def check_bind(binary, base):
    root = create(base, "occupied-cli-port")
    with socket.socket() as occupied:
        occupied.bind(("127.0.0.1", 0))
        occupied.listen(1)
        with SERVICE.provider(root) as (state, provider_port):
            path = workflow(root, provider_port)
            with SERVICE.running(binary, root, args(path, occupied.getsockname()[1])) as process:
                require(process.joined() != 0, "occupied listener did not fail startup")
                require(not process.event("service_started") and not process.event("status_listening"),
                        "bind failure entered service owner")
                require(not SERVICE.records(root / "control") and not state.receipts,
                        "bind failure acquired agent/tracker effects")


def check_active(binary, base, manifest):
    root = create(base, "active")
    receipts = []
    with SERVICE.provider(root) as (state, provider_port):
        issue = SERVICE.issue()
        issue["title"] = '<script>alert("fixture")</script>&'
        state.set_issues([issue])
        path = workflow(root, provider_port)
        with SERVICE.running(binary, root, args(path, 0)) as process:
            bound = ready(process)
            process.wait(lambda: len(SERVICE.turns(root / "control")) == 1, "held active turn")
            process.wait(lambda: bool(process.event("session_started")), "canonical first session observation")
            session = process.event("session_started")[-1]["session_id"]

            def observe(method, target, body=b""):
                response = query(bound, method, target, body)
                receipts.append(response)
                persist(root / "http.json", receipts)
                return response

            def state_check():
                decoded = value(observe("GET", "/api/v1/state"), OK)
                require(decoded["counts"]["running"] == 1 and len(decoded["running"]) == 1,
                        "active snapshot lost ownership")
                row = decoded["running"][0]
                require(row["issue_id"] == issue["id"] and row["issue_identifier"] == issue["identifier"] and
                        row["session_id"] == session and row["turn_count"] == 1,
                        "active snapshot lost canonical issue/session")
                require(isinstance(decoded["generated_at"], str) and
                        all(name in decoded for name in ("retrying", "codex_totals", "rate_limits")),
                        "missing baseline state fields")
                return {"session_id": session, "issue_id": row["issue_id"]}

            def detail_check():
                decoded = value(observe("GET", "/api/v1/LIN-A"), OK)
                require(decoded["issue_id"] == issue["id"] and decoded["status"] == "running" and
                        decoded["running"]["session_id"] == session, "detail lost active session")
                require(Path(decoded["workspace"]["path"]).is_dir(), "detail lacks acquired workspace")

            def html_check():
                response = observe("GET", "/")
                require(response["status"] == OK and
                        response["headers"].get("content-type", "").startswith("text/html"),
                        "dashboard is not HTML")
                require("<script>" not in response["body"] and
                        "&lt;script&gt;" in response["body"] and "&amp;" in response["body"] and
                        session in response["body"], "dashboard failed text escaping/canonical session")

            record(manifest, base, "active-state-owner-query", state_check, "active")
            record(manifest, base, "active-issue-detail", detail_check, "active")
            record(manifest, base, "escaped-dashboard", html_check, "active")
            for target, method, allow in (("/", "POST", "GET"), ("/api/v1/state", "POST", "GET"),
                                          ("/api/v1/LIN-A", "POST", "GET"),
                                          ("/api/v1/refresh", "GET", "POST")):
                def method_check(target=target, method=method, allow=allow):
                    response = observe(method, target)
                    error(response, METHOD_NOT_ALLOWED, "method_not_allowed")
                    require(response["headers"].get("allow") == allow, "405 lacks exact Allow header")
                record(manifest, base, "method-" + target.replace("/", "_").strip("_"), method_check, "active")
            for target, code in (("/unknown/route", "not_found"), ("/api/v1/UNKNOWN", "issue_not_found")):
                record(manifest, base, "missing-" + code,
                       lambda target=target, code=code: error(observe("GET", target), NOT_FOUND, code), "active")

            def path_check():
                for target in ("/api/v1/%", "/api/v1/%GG", "/api/v1/%2f", "/api/v1/%00",
                               "/api/v1/%0a", "/api/v1/%ff", "/api/v1/state?x=1", "/api/v1/state#x"):
                    error(observe("GET", target), BAD_REQUEST, "bad_request")
                error(observe("GET", "/api/v1/UNKNOWN%252f"), NOT_FOUND, "issue_not_found")
            record(manifest, base, "strict-single-path-decode", path_check, "active")

            # Reject bodies before any accepted refresh can leave an in-flight poll.
            def bad_body():
                before = sum(row["kind"] == "candidates" for row in state.receipts)
                for payload in (b"[broken", b"[]", b'{"unexpected":true}'):
                    error(observe("POST", "/api/v1/refresh", payload), BAD_REQUEST)
                require(sum(row["kind"] == "candidates" for row in state.receipts) == before,
                        "rejected refresh body reached tracker poll")
            record(manifest, base, "refresh-invalid-body-no-effects", bad_body, "active")

            for name, payload in (("refresh-empty", b""), ("refresh-object", b"{}")):
                def refresh_check(payload=payload):
                    before = sum(row["kind"] == "candidates" for row in state.receipts)
                    decoded = value(observe("POST", "/api/v1/refresh", payload), ACCEPTED)
                    require(decoded.get("queued") is True and type(decoded.get("coalesced")) is bool and
                            set(decoded.get("operations", [])) == {"poll", "reconcile"},
                            "refresh admission receipt is incomplete")
                    state.wait(lambda rows: sum(row["kind"] == "candidates" for row in rows) > before,
                               "refresh caused immediate tracker poll")
                record(manifest, base, name, refresh_check, "active")

            def oversized():
                error(observe("POST", "/api/v1/refresh", b"x" * (64 * 1024 + 1)),
                      PAYLOAD_TOO_LARGE, "payload_too_large")
                value(observe("GET", "/api/v1/state"), OK)
            record(manifest, base, "body-limit-client-local", oversized, "active")

            def burst():
                gate = state.hold("candidates")
                try:
                    value(observe("POST", "/api/v1/refresh"), ACCEPTED)
                    state.wait(lambda rows: any(row["kind"] == "candidates" and row["response"] == "held"
                                               for row in rows), "refresh provider read is held")
                    replies = [value(observe("POST", "/api/v1/refresh"), ACCEPTED) for _ in range(8)]
                    require(all(row.get("queued") is True for row in replies) and
                            any(row.get("coalesced") is True for row in replies), "held refresh burst did not coalesce")
                finally:
                    gate.set()
            record(manifest, base, "refresh-coalesces-held-provider", burst, "active")
            process.stop(signal.SIGTERM)
            SERVICE.assert_closed(root, process)
            closed(bound)
        require(not state.defects, "provider fixture defect")


def check_between(binary, base):
    root = create(base, "between-turns")
    with SERVICE.provider(root) as (state, provider_port):
        state.set_issues([SERVICE.issue()])
        path = workflow(root, provider_port, hook_gate="held")
        with SERVICE.running(binary, root, args(path, 0)) as process:
            bound = ready(process)
            process.wait(lambda: bool(process.event("session_started")), "held active session")
            session = process.event("session_started")[-1]["session_id"]
            peers = SERVICE.started(root / "control")
            require(len(peers) == 1, "between-turns fixture requires one app-server")
            (root / "control" / f"finish-{peers[0]['pid']}-1").touch()
            process.wait((root / "control" / "hook-entered.json").is_file,
                         "completed turn reaped before held after_run")
            response = query(bound, "GET", "/api/v1/LIN-A")
            decoded = value(response, OK)
            require(decoded["running"]["phase"] == "between_turns" and
                    decoded["running"]["session_id"] == session,
                    "completed turn fabricated an active turn or lost its last session")
            snapshot = value(query(bound, "GET", "/api/v1/state"), OK)
            require(snapshot["counts"]["running"] == 1 and
                    snapshot["running"][0]["session_id"] == session,
                    "held after_run lost canonical owner/session")
            persist(root / "between-http.json", response)
            (root / "control" / "release-after-run").touch()
            process.stop(signal.SIGTERM)
            SERVICE.assert_closed(root, process)
            closed(bound)
        require(not state.defects, "provider fixture defect")


def check_stopping(binary, base):
    root = create(base, "reconciliation-stopping")
    with SERVICE.provider(root) as (state, provider_port):
        issue = SERVICE.issue()
        state.set_issues([issue])
        path = workflow(root, provider_port, hook_gate="held")
        with SERVICE.running(binary, root, args(path, 0)) as process:
            bound = ready(process)
            process.wait(lambda: bool(process.event("session_started")), "held active session")
            session = process.event("session_started")[-1]["session_id"]
            terminal = dict(issue, state={"name": "Done"})
            state.set_issues([terminal])
            value(query(bound, "POST", "/api/v1/refresh"), ACCEPTED)
            process.wait((root / "control" / "hook-entered.json").is_file,
                         "reconciliation joined agent before held after_run")
            response = query(bound, "GET", "/api/v1/LIN-A")
            decoded = value(response, OK)
            require(decoded["running"]["phase"] == "stopping" and
                    decoded["running"]["session_id"] == session,
                    "stopping scope lost canonical session while Source remains active")
            persist(root / "stopping-http.json", response)
            process.child.send_signal(signal.SIGTERM)
            process.wait(lambda: bool(process.event("shutdown_requested")), "host shutdown accepted")
            deadline = time.monotonic() + SERVICE.WAIT_SECONDS
            while True:
                unavailable = query(bound, "GET", "/api/v1/state")
                if unavailable["status"] == UNAVAILABLE:
                    break
                require(time.monotonic() < deadline, "owner did not close status admission on shutdown")
                time.sleep(0.02)
            error(unavailable, UNAVAILABLE, "snapshot_unavailable")
            persist(root / "shutdown-http.json", unavailable)
            (root / "control" / "release-after-run").touch()
            process.stopped(signal.SIGTERM)
            # Terminal reconciliation removes the workspace and its local receipt.
            # The retained hook gate already proved peer reap before hook execution.
            peers = SERVICE.started(root / "control")
            require(len(peers) == 1 and peers[0]["optimize"] == sys.flags.optimize,
                    "terminal cleanup changed peer acquisition/mode")
            marker = json.loads((root / "control" / "hook-entered.json").read_text())
            require(marker == {"pid": peers[0]["pid"], "closed": True},
                    "terminal hook preceded joined peer closure")
            SERVICE.reaped(peers[0]["pid"])
            hooks = [row for row in process.event("hook") if row.get("hook") == "after_run"]
            require(sum(row.get("phase") == "finished" and row.get("outcome") == "succeeded"
                        for row in hooks) == 1 and len(process.event("worker_closed")) == 1,
                    "terminal scope did not close its held hook exactly once")
            require(not [row for row in SERVICE.records(root / "control") if row.get("kind") == "defect"],
                    "terminal peer protocol defect")
            require(not Path(peers[0]["cwd"]).exists(), "terminal workspace cleanup did not finish")
            require("fixture-stderr-never-render" not in process.logs(), "untrusted peer stderr escaped")
            closed(bound)
        require(not state.defects, "provider fixture defect")


def check_partial(binary, base):
    root = create(base, "partial-client-shutdown")
    with SERVICE.provider(root) as (_state, provider_port):
        path = workflow(root, provider_port)
        with SERVICE.running(binary, root, args(path, 0)) as process:
            bound = ready(process)
            with socket.create_connection(("127.0.0.1", bound), timeout=HTTP_TIMEOUT) as peer:
                peer.sendall(b"POST /api/v1/refresh HTTP/1.1\r\nHost: localhost\r\nContent-Length: 1\r\n\r\n")
                process.stop(signal.SIGTERM)
                try:
                    require(peer.recv(1) == b"", "held partial HTTP client remained open after join")
                except ConnectionResetError:
                    pass
            closed(bound)


def run(binary, base):
    inputs = (Path(__file__).resolve(), FIXTURE_PATH, SERVICE.PEER, SERVICE.CA,
              SERVICE.FIXTURES / "tls" / "server.pem", SERVICE.FIXTURES / "tls" / "server.key")
    manifest = {
        "schema": 1, "binary": {"path": str(binary), "sha256": digest(binary)},
        "python": {"executable": str(Path(sys.executable).resolve()), "optimize": sys.flags.optimize,
                   "peer_argv": SERVICE.PYTHON},
        "sources": {str(path.relative_to(Path(__file__).resolve().parents[1])): digest(path) for path in inputs},
        "cases": [], "boundary": "physical loopback HTTP over local HTTPS/JSONL fixtures; binary hashes are context, not build attestation",
    }
    persist(base / "manifest.json", manifest)
    record(manifest, base, "disabled", lambda: check_off(binary, base))
    record(manifest, base, "configured-port-zero", lambda: check_port(binary, base, "configured-port-zero", Port_case.WORKFLOW))
    record(manifest, base, "cli-port-overrides-occupied-config", lambda: check_port(binary, base, "cli-port-overrides-occupied-config", Port_case.CLI_OVERRIDE))
    record(manifest, base, "occupied-cli-port", lambda: check_bind(binary, base))
    check_active(binary, base, manifest)
    record(manifest, base, "between-turns-last-session", lambda: check_between(binary, base), "between-turns")
    record(manifest, base, "reconciliation-stopping", lambda: check_stopping(binary, base))
    record(manifest, base, "partial-client-shutdown", lambda: check_partial(binary, base))
    require(digest(binary) == manifest["binary"]["sha256"], "runtime binary changed during status acceptance")
    for relative, before in manifest["sources"].items():
        require(digest(Path(__file__).resolve().parents[1] / relative) == before,
                "status acceptance input changed: " + relative)
    manifest["inputs_unchanged"] = True
    persist(base / "manifest.json", manifest)
    print(f"Status CLI: {len(manifest['cases'])} physical local scenarios passed")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("--out", type=Path, help="retain bounded logs and SHA-bound receipts in a fresh directory")
    values = parser.parse_args()
    binary = values.binary.resolve(strict=True)
    try:
        if values.out is not None:
            values.out.mkdir(parents=True, exist_ok=False)
            run(binary, values.out.resolve())
        else:
            with tempfile.TemporaryDirectory(prefix="symphony-status-cli-") as temporary:
                run(binary, Path(temporary))
    except (SERVICE.AcceptanceError, OSError, ValueError, http.client.HTTPException) as error_:
        print("Status CLI: " + str(error_), file=sys.stderr)
        raise SystemExit(1) from error_


if __name__ == "__main__":
    main()
