"""Actual Symphony binary against a scripted HTTPS Linear provider."""

import argparse
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import ssl
import subprocess
import tempfile
import threading


TOKEN = "fixture-linear-key-never-print"
PROVIDER_SECRET = "provider-description-or-error-never-log"
ENDPOINT_SECRET = "endpoint-query-never-log"
PAGE_SIZE = 50
SERVER_TIMEOUT_SECONDS = 5
FIXTURES = Path(__file__).resolve().parent / "fixtures" / "tls"


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"Tracker CLI: {message}")


def connection(nodes: list, cursor: str | None = None) -> dict:
    return {"nodes": nodes, "pageInfo": {
        "hasNextPage": cursor is not None, "endCursor": cursor,
    }}


def issue(name: str, state: str = "Todo") -> dict:
    return {
        "id": f"opaque:{name}", "identifier": f"LIN-{name}",
        "title": f"Issue {name}", "description": None, "priority": 1.0,
        "state": {"name": state}, "project": {"id": "project-id", "slugId": "fixture"},
        "labels": connection([]), "inverseRelations": connection([]),
    }


def wire(data: dict, status: int = 200) -> bytes:
    body = json.dumps(data, separators=(",", ":")).encode()
    return (f"HTTP/1.1 {status} Fixture\r\nContent-Type: application/json\r\n"
            f"Content-Length: {len(body)}\r\nConnection: close\r\n\r\n").encode() + body


def public_config_cases(binary: Path, root: Path, env: dict) -> int:
    """Credential quarantine must hold through the real config/doctor path."""
    numeric_key = "617283"
    path_key = str(root / "quarantined-root")
    cases = [
        ("kind bootstrap", "linear", ""),
        ("kind alias bootstrap", "linear", "", "fixture", "[Done]",
         "$LINEAR_API_KEY", "$KIND_ALIAS"),
        ("workspace source", TOKEN, "workspace:\n  root: $LINEAR_API_KEY\n"),
        ("workspace alias", TOKEN, "workspace:\n  root: $KEY_ALIAS\n"),
        ("workspace custom source", TOKEN, "workspace:\n  root: $CUSTOM_API_KEY\n",
         "fixture", "[Done]", "$CUSTOM_API_KEY"),
        ("workspace literal", TOKEN, f"workspace:\n  root: {TOKEN}\n"),
        ("workspace canonical", path_key, "workspace:\n  root: ./quarantined-root\n"),
        ("project source", TOKEN, "", "$LINEAR_API_KEY"),
        ("project alias", TOKEN, "", "$KEY_ALIAS"),
        ("project literal", TOKEN, "", TOKEN),
        ("missing reference name", "MISSING_QUARANTINED_ENV_NAME", "",
         "$MISSING_QUARANTINED_ENV_NAME"),
        ("polling source", numeric_key, "polling:\n  interval_ms: $LINEAR_API_KEY\n"),
        ("polling canonical", numeric_key, "polling:\n  interval_ms: 0x96b43\n"),
        ("terminal canonical", "done", "", "fixture", "[DONE]"),
        ("per-state key", TOKEN,
         f"agent:\n  max_concurrent_agents_by_state:\n    {TOKEN}: 1\n"),
        ("protocol JSON", path_key,
         "codex:\n  turn_sandbox_policy:\n    type: workspaceWrite\n"
         f"    writableRoots: [{json.dumps(path_key)}]\n"),
    ]
    workflow = root / "PUBLIC.md"
    for label, key, extra, *selection in cases:
        project = selection[0] if selection else "fixture"
        terminal = selection[1] if len(selection) > 1 else "[Done]"
        credential = f"    api_key: {selection[2]}\n" if len(selection) > 2 else ""
        kind = selection[3] if len(selection) > 3 else "linear"
        workflow.write_text(
            f"---\ntracker:\n  kind: {kind}\n  active_states: [Todo]\n"
            f"  terminal_states: {terminal}\n  provider:\n    project_slug: {project}\n"
            f"{credential}{extra}---\n{{{{ issue.identifier }}}}\n"
        )
        result = subprocess.run([str(binary), "doctor", str(workflow)], cwd=root,
                                env=dict(env, LINEAR_API_KEY=key, KEY_ALIAS=key,
                                         CUSTOM_API_KEY=key, KIND_ALIAS="linear"),
                                capture_output=True, text=True, timeout=15)
        output = result.stdout + result.stderr
        require(result.returncode != 0 and not result.stdout,
                f"{label} accepted credential material")
        require(key not in output and "credential" in result.stderr,
                f"{label} lacked redacted quarantine diagnostic")

    workflow.write_text(
        "---\ntracker:\n  kind: linear\n  active_states: [Todo]\n"
        "  terminal_states: [Done]\n  provider:\n    project_slug: $PUBLIC_PROJECT\n"
        "    endpoint: $PUBLIC_ENDPOINT\nworkspace:\n  root: $PUBLIC_ROOT\n---\n"
    )
    result = subprocess.run(
        [str(binary), "doctor", str(workflow)], cwd=root,
        env=dict(env, PUBLIC_PROJECT="fixture", PUBLIC_ENDPOINT="https://example.test/graphql",
                 PUBLIC_ROOT="./public-root"), capture_output=True, text=True, timeout=15,
    )
    require(result.returncode == 0 and str(root / "public-root") in result.stdout,
            f"nonsecret expansion rejected: {result.stderr}")
    return len(cases) + 1


@contextmanager
def provider(responses: list[bytes], certificate: str = "server"):
    requests = []
    defects = []

    class Handler(BaseHTTPRequestHandler):
        def setup(self):
            self.request.settimeout(SERVER_TIMEOUT_SECONDS)
            super().setup()

        def log_message(self, *args):
            pass

        def do_POST(self):
            # Keep fixture validation out of logs; credentials are never rendered.
            try:
                length = int(self.headers.get("Content-Length", "0"))
                if not 0 < length <= 1_048_576:
                    raise ValueError("invalid request size")
                body = json.loads(self.rfile.read(length))
                requests.append((self.path, self.headers.get("Authorization"), body))
                position = len(requests) - 1
                if position >= len(responses):
                    raise ValueError("unexpected extra request")
                self.connection.sendall(responses[position])
                self.close_connection = True
            except (OSError, ValueError, json.JSONDecodeError) as error:
                defects.append(type(error).__name__)
                self.close_connection = True

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = False
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    context.load_cert_chain(FIXTURES / f"{certificate}.pem", FIXTURES / f"{certificate}.key")
    server.socket = context.wrap_socket(server.socket, server_side=True,
                                       do_handshake_on_connect=False)
    thread = threading.Thread(target=server.serve_forever, kwargs={"poll_interval": 0.01})
    thread.start()
    try:
        yield server.server_address[1], requests, defects
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)
        require(not thread.is_alive(), "fake provider did not join")


def run(binary: Path) -> None:
    scenarios = 0
    with tempfile.TemporaryDirectory(prefix="symphony-tracker-") as temporary:
        root = Path(temporary)
        workflow = root / "WORKFLOW.md"
        env = dict(os.environ, LINEAR_API_KEY=TOKEN, TMPDIR=temporary,
                   HTTPS_PROXY="http://127.0.0.1:1", SSL_CERT_FILE="/missing/ambient-ca.pem")
        public_cases = public_config_cases(binary, root, env)

        def invoke(port: int, ca: str = "ca.pem", command: str = "tracker"):
            endpoint = f"https://127.0.0.1:{port}/graphql?private={ENDPOINT_SECRET}"
            workflow.write_text(
                "---\ntracker:\n  kind: linear\n  active_states: [Todo, Doing]\n"
                "  terminal_states: [Done]\n  provider:\n    project_slug: fixture\n"
                f"    endpoint: {endpoint}\nworkspace:\n  root: ./workspaces\n---\n"
                "{{ issue.identifier }}\n"
            )
            arguments = [str(binary), command, str(workflow)]
            if command == "tracker":
                arguments += ["--ca-bundle", str(FIXTURES / ca)]
            result = subprocess.run(arguments, cwd=root, env=env, capture_output=True,
                                    text=True, timeout=15)
            require(TOKEN not in result.stdout + result.stderr, "credential leaked")
            require(PROVIDER_SECRET not in result.stderr, "raw provider text leaked")
            require(ENDPOINT_SECRET not in result.stdout + result.stderr, "endpoint query leaked")
            return result

        first = issue("A")
        first["labels"] = connection([{"name": " Urgent "}], "labels-next")
        first["inverseRelations"] = connection([], None)
        second = issue("B", "Doing")
        second["inverseRelations"] = connection([{
            "type": "blocks", "issue": {"id": "opaque:blocker", "state": {"name": "Todo"}},
            "relatedIssue": {"id": second["id"]},
        }])
        malformed = issue("bad")
        malformed["title"] = PROVIDER_SECRET
        del malformed["state"]
        answers = [
            wire({"data": {"issues": connection([first], "outer-next")}}),
            wire({"data": {"issue": {"id": first["id"], "project": {"slugId": "fixture"},
                                     "labels": connection([{"name": "BUG"}])}}}),
            wire({"data": {"issues": connection([second, malformed])}}),
        ]
        with provider(answers) as (port, requests, defects):
            result = invoke(port)
            require(result.returncode == 0, f"ordered read failed: {result.stderr}")
            output = json.loads(result.stdout)
            require([node["id"] for node in output] == [first["id"], second["id"]],
                    "provider order or omission changed")
            require(output[0]["labels"] == ["bug", "urgent"] and output[0]["priority"] == 1,
                    "nested labels or exact priority lost")
            require(output[0]["dispatchable"] and output[1]["dispatchable"],
                    "routing differed from profile")
            require("state" in result.stderr and "LIN-bad" in result.stderr,
                    "omission warning lacks bounded identity/key")
            require(len(requests) == 3 and not defects, "request sequence incomplete")
            require([r[2]["operationName"] for r in requests] ==
                    ["SymphonyIssues", "SymphonyLabels", "SymphonyIssues"], "wrong operations")
            for path, token, request in requests:
                require(path == f"/graphql?private={ENDPOINT_SECRET}" and token == TOKEN,
                        "destination-bound authorization or request target lost")
                require(request["variables"]["pageSize"] == PAGE_SIZE, "page size differs")
                require(ENDPOINT_SECRET not in request["query"], "configuration interpolated into query")
            require(requests[0][2]["variables"]["after"] is None and
                    requests[1][2]["variables"]["after"] == "labels-next" and
                    requests[2][2]["variables"]["after"] == "outer-next", "cursor variables wrong")
        scenarios += 1

        rejected = [
            ("partial GraphQL errors", wire({"data": {"issues": connection([first])},
                                             "errors": [{"message": PROVIDER_SECRET}]})),
            ("HTTP429", wire({"message": PROVIDER_SECRET}, 429)),
            ("HTTP401", wire({"message": PROVIDER_SECRET}, 401)),
            ("HTTP500", wire({"message": PROVIDER_SECRET}, 500)),
            ("duplicate IDs", wire({"data": {"issues": connection([second, second])}})),
            ("foreign project", wire({"data": {"issues": connection([
                dict(second, project={"slugId": "foreign"})])}})),
            ("empty advancing page", wire({"data": {"issues": connection([], "next")}})),
            ("truncated fixed body", b"HTTP/1.1 200 OK\r\nContent-Length: 100\r\n\r\n{}"),
            ("truncated chunk", b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n10\r\n{}"),
            ("oversized header", b"HTTP/1.1 200 OK\r\nX-Fill: " + b"x" * 16_384 + b"\r\n\r\n"),
            ("oversized body", b"HTTP/1.1 200 OK\r\nContent-Length: 1048577\r\n\r\n"),
            ("redirect", b"HTTP/1.1 302 Found\r\nLocation: https://unrelated.example.test/\r\nContent-Length: 0\r\n\r\n"),
        ]
        for label, response in rejected:
            with provider([response]) as (port, requests, defects):
                result = invoke(port)
                require(result.returncode != 0 and result.stdout == "" and result.stderr,
                        f"{label} delivered partial/success output")
                require(len(requests) == 1 and not defects, f"{label} retried or failed fixture")
            scenarios += 1

        with provider([answers[0], wire({"errors": [{"message": PROVIDER_SECRET}]})]) as (port, requests, defects):
            result = invoke(port)
            require(result.returncode != 0 and not result.stdout and len(requests) == 2 and not defects,
                    "later nested failure delivered an earlier page")
        scenarios += 1

        for certificate, ca in [("server", "other-ca.pem"), ("wrong-host", "ca.pem")]:
            with provider([] , certificate) as (port, requests, defects):
                result = invoke(port, ca)
                require(result.returncode != 0 and not result.stdout and not requests and not defects,
                        "TLS rejected trust/identity only after sending authorization")
            scenarios += 1

        with provider([]) as (port, requests, defects):
            result = invoke(port, command="doctor")
            require(result.returncode == 0 and not requests and not defects,
                    "offline doctor activated HTTPS")
            result = invoke(port, ca="missing.pem")
            require(result.returncode != 0 and not result.stdout and not requests and
                    "missing.pem" in result.stderr and "--ca-bundle" in result.stderr,
                    f"missing explicit trust lacks its remedy: {result.stderr!r}")
        scenarios += 2

    print(f"Tracker CLI: {scenarios} HTTPS scenarios passed")
    print(f"Tracker CLI: {public_cases} public-config scenarios passed")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    arguments = parser.parse_args()
    run(arguments.binary.resolve())
