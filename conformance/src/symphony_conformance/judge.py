"""Replay a retained lifecycle bundle without launching or probing anything."""

import base64
import binascii
import hashlib
from http import HTTPStatus
import os
import re
import stat
from pathlib import Path, PurePosixPath
from signal import SIGKILL
from graphql import GraphQLError

from .assets import decode, digest, load, resource
from .report import build
from .schema import Schema
from .linear import select


SCHEMA_VERSION = 1
CORPUS_ID = "core-lifecycle-v1"
MANIFEST = "manifest.json"
JOURNAL = "events.jsonl"
PLAN = "plan.json"
MAX_FILE_BYTES = 64 * 1024 * 1024
MAX_BUNDLE_BYTES = 256 * 1024 * 1024
MAX_MANIFEST_BYTES = 1024 * 1024
MAX_ENTRIES = 2048
MAX_PATH_DEPTH = 64
MANIFEST_FIELDS = frozenset(
    {"schema_version", "profile_id", "corpus_id", "completed", "harness_errors", "files", "identities"}
)
EVENT_FIELDS = frozenset({"seq", "at_ns", "origin", "kind", "data"})
REQUIRED_FILES = frozenset({JOURNAL, PLAN, "stdout.bin", "stderr.bin"})
PROFILE_IDS = frozenset({"ocaml", "scripted"})
SHA256 = re.compile(r"[0-9a-f]{64}\Z")
METHOD_INITIALIZE = "initialize"
METHOD_INITIALIZED = "initialized"
METHOD_THREAD = "thread/start"
METHOD_TURN = "turn/start"
METHOD_COMPLETED = "turn/completed"
METHOD_INTERRUPT = "turn/interrupt"
METHOD_USAGE = "thread/tokenUsage/updated"
TOKEN_FIELDS = {"input_tokens": "inputTokens", "output_tokens": "outputTokens", "total_tokens": "totalTokens"}
WAIT_PHASES = ("observe", "join", "reap")
STREAMS = ("stdout", "stderr")
CONTENT_LENGTH = "content-length"
CONTENT_TYPE = "content-type"
CONNECTION = "connection"
TRANSFER_ENCODING = "transfer-encoding"
JSON_MEDIA_TYPE = "application/json"
CONNECTION_CLOSE = "close"

# Coverage is deliberately partial: one happy lifecycle cannot prove every variant.
COVERAGE = {
    "peer.unique": ["D18.1.single-authority"],
    "workspace.contained": ["C17.2.create", "C17.2.path-safety", "C17.2.agent-cwd", "C17.5.launch", "D18.1.workspace"],
    "secret.quarantined": ["E17.5.provider-tools-secrets"],
    "protocol.schema": ["C17.5.identity-capabilities", "C17.5.framing", "D18.1.app-server"],
    "protocol.startup": ["C17.5.policy", "C17.5.startup", "D18.1.app-server"],
    "turn.same_thread": ["C17.5.startup", "D18.1.app-server"],
    "turn.completion": ["C17.5.startup", "D18.1.app-server"],
    "tracker.terminal_refresh": ["C17.3.opaque-refresh", "C17.4.terminal-stop", "D18.1.tracker-reads", "D18.1.reconcile"],
    "interrupt.completed": ["C17.4.terminal-stop", "D18.1.reconcile"],
    "hooks.order": ["C17.2.after-create", "C17.2.before-run", "C17.2.after-run", "C17.2.before-remove", "D18.1.hooks"],
    "workspace.removed": ["C17.4.terminal-stop", "D18.1.terminal-cleanup"],
    "shutdown.joined": ["C17.7.normal-exit"],
    "telemetry.absolute": ["C17.5.telemetry", "C17.6.telemetry-aggregation"],
}


def _hash(raw):
    return hashlib.sha256(raw).hexdigest()


def _integer(value):
    return type(value) is int and value >= 0


def _relative(name):
    if not isinstance(name, str) or not name or "\\" in name:
        raise ValueError("invalid evidence path")
    path = PurePosixPath(name)
    if path.is_absolute() or str(path) != name or any(part in {".", ".."} for part in path.parts):
        raise ValueError("evidence path is not canonical and relative")
    return path


def _inventory(bundle):
    if bundle.is_symlink() or not bundle.is_dir():
        raise ValueError("bundle must be a regular directory")
    paths = {}
    pending = [bundle]
    entries = 0
    while pending:
        directory = pending.pop()
        with os.scandir(directory) as children:
            for child in children:
                entries += 1
                if entries > MAX_ENTRIES:
                    raise ValueError("evidence inventory exceeds its entry bound")
                path = Path(directory) / child.name
                relative = path.relative_to(bundle).as_posix()
                if len(_relative(relative).parts) > MAX_PATH_DEPTH:
                    raise ValueError("evidence inventory exceeds its depth bound")
                mode = child.stat(follow_symlinks=False).st_mode
                if stat.S_ISDIR(mode):
                    pending.append(path)
                    continue
                if not stat.S_ISREG(mode):
                    raise ValueError("non-regular file or symlink in evidence inventory")
                paths[relative] = path
    return paths


def _read_bundle(bundle):
    paths = _inventory(bundle)
    if MANIFEST not in paths:
        raise ValueError("missing evidence manifest")
    if paths[MANIFEST].stat().st_size > MAX_MANIFEST_BYTES:
        raise ValueError("evidence manifest exceeds its bound")
    manifest = decode(paths[MANIFEST].read_bytes())
    if not isinstance(manifest, dict) or set(manifest) != MANIFEST_FIELDS:
        raise ValueError("invalid evidence manifest fields")
    if type(manifest["schema_version"]) is not int or manifest["schema_version"] != SCHEMA_VERSION:
        raise ValueError("unknown evidence schema version")
    if manifest["profile_id"] not in PROFILE_IDS or manifest["corpus_id"] != CORPUS_ID:
        raise ValueError("unknown profile or corpus ID")
    if type(manifest["completed"]) is not bool or not isinstance(manifest["harness_errors"], list):
        raise ValueError("invalid completion or harness health record")
    if any(not isinstance(error, str) for error in manifest["harness_errors"]):
        raise ValueError("invalid harness error")
    files = manifest["files"]
    if not isinstance(files, dict) or not REQUIRED_FILES <= set(files):
        raise ValueError("missing required evidence file")
    if set(paths) - {MANIFEST} != set(files):
        raise ValueError("missing or extra evidence file")

    retained = {}
    total = 0
    for name, expected in files.items():
        _relative(name)
        if not isinstance(expected, dict) or set(expected) != {"sha256", "bytes"}:
            raise ValueError("invalid evidence file metadata")
        if not isinstance(expected["sha256"], str) or SHA256.fullmatch(expected["sha256"]) is None:
            raise ValueError("invalid evidence digest")
        size = expected["bytes"]
        if not _integer(size) or size > MAX_FILE_BYTES or paths[name].stat().st_size != size:
            raise ValueError("evidence byte count or bound mismatch")
        total += size
        if total > MAX_BUNDLE_BYTES:
            raise ValueError("evidence bundle exceeds its bound")
        raw = paths[name].read_bytes()
        if len(raw) != size or _hash(raw) != expected["sha256"]:
            raise ValueError("evidence digest mismatch")
        retained[name] = raw
    return manifest, retained


def _package_files():
    pending = [("", resource("."))]
    result = {}
    while pending:
        prefix, directory = pending.pop()
        for item in directory.iterdir():
            name = prefix + item.name
            if item.is_dir():
                pending.append((name + "/", item))
            elif item.is_file():
                result["assets/" + name] = item.read_bytes()
            else:
                raise ValueError("canonical package contains a nonregular asset")
    return result


def _canonical(manifest, retained):
    names = {
        "catalog": "catalog.json",
        "corpus": "corpus/lifecycle.json",
        "protocol": "protocol/manifest.json",
        "profile": f"profiles/{manifest['profile_id']}.json",
    }
    identities = manifest["identities"]
    if not isinstance(identities, dict) or set(identities) != set(names):
        raise ValueError("missing or extra canonical identity")
    if any(identities[name] != digest(path) for name, path in names.items()):
        raise ValueError("canonical package identity mismatch")
    expected = _package_files()
    actual = {name: raw for name, raw in retained.items()
              if name == "assets" or name.startswith("assets/")}
    if set(actual) != set(expected):
        raise ValueError("missing or extra retained canonical asset")
    if any(actual[name] != raw for name, raw in expected.items()):
        raise ValueError("retained asset differs from the canonical package")
    data = {name: load(path) for name, path in names.items()}
    if data["corpus"]["id"] != manifest["corpus_id"] or data["profile"]["id"] != manifest["profile_id"]:
        raise ValueError("canonical corpus or profile ID mismatch")
    for field in ("adapter", "protocol", "policy"):
        if data["corpus"][field] != data["profile"][field]:
            raise ValueError("profile cannot change corpus policy identities")
    for field in ("approval_policy", "sandbox"):
        if data["corpus"][field] != data["profile"][field]:
            raise ValueError("profile cannot change fixed policy expectations")

    # Validate all retained schema bytes, including schemas unused by this scenario.
    schemas = data["protocol"]["files"]
    for name, expected in schemas.items():
        _relative(name)
        raw = resource("protocol/schemas/" + name).read_bytes()
        if _hash(raw) != expected:
            raise ValueError("pinned protocol schema digest mismatch")
        pending = [decode(raw)]
        while pending:
            item = pending.pop()
            if isinstance(item, dict):
                ref = item.get("$ref")
                if ref is not None and (not isinstance(ref, str) or not ref.startswith("#")):
                    raise ValueError("offline schemas cannot reference external resources")
                pending.extend(item.values())
            elif isinstance(item, list):
                pending.extend(item)
    return data


def _events(raw):
    if not raw or not raw.endswith(b"\n"):
        raise ValueError("empty or truncated evidence journal")
    events = []
    previous = 0
    for sequence, line in enumerate(raw.splitlines(), start=1):
        event = decode(line)
        if not isinstance(event, dict) or set(event) != EVENT_FIELDS:
            raise ValueError("invalid journal event fields")
        if type(event["seq"]) is not int or event["seq"] != sequence:
            raise ValueError("journal sequence is missing or duplicated")
        time = event["at_ns"]
        if not _integer(time) or time < previous:
            raise ValueError("collector ingestion clock is not nondecreasing")
        if any(not isinstance(event[field], str) or not event[field] for field in ("origin", "kind")):
            raise ValueError("invalid observation origin or kind")
        if not isinstance(event["data"], dict):
            raise ValueError("invalid observation payload")
        if "requirement_id" in event["data"] or "verdict" in event["data"] or "passed" in event["data"]:
            raise ValueError("observations cannot supply requirement answers")
        previous = time
        events.append(event)
    return events


def _base64(value):
    if not isinstance(value, str):
        raise ValueError("missing raw base64 evidence")
    try:
        return base64.b64decode(value, validate=True)
    except (ValueError, binascii.Error) as error:
        raise ValueError("invalid raw base64 evidence") from error


def _of(events, kind):
    return [event for event in events if event["kind"] == kind]


def _result(name, status, reason, evidence):
    return {"id": name, "status": status, "reason": reason,
            "evidence_seq": sorted({event["seq"] for event in evidence})}


def _check(name, stages, failures):
    evidence = [event for stage in stages for event in stage]
    if failures:
        return _result(name, "fail", "; ".join(failures), evidence)
    if any(not stage for stage in stages):
        return _result(name, "incomplete", "required observation stage missing", evidence)
    return _result(name, "pass", "fixed lifecycle assertion satisfied", evidence)


def _frames(events, corpus):
    schema = Schema()
    frames = []
    requests = {"client": {}, "server": {}}
    failures = []
    for event in events:
        if event["kind"] not in {"peer.client", "peer.server"}:
            continue
        direction = event["kind"].split(".")[1]
        raw = _base64(event["data"].get("frame"))
        if not isinstance(event["data"].get("peer_id"), str):
            raise ValueError("raw frame lacks a peer identity")
        try:
            if len(raw) > corpus["peer_frame_limit"]:
                raise ValueError("protocol frame exceeds the fixed corpus bound")
            if not raw.endswith(b"\n") or raw.count(b"\n") != 1:
                raise ValueError("frame is not one terminated JSONL record")
            frame = decode(raw)
            if not isinstance(frame, dict):
                raise ValueError("frame is not an object")
            method = frame.get("method")
            request_seq = None
            if "id" in frame:
                key = (event["data"]["peer_id"], type(frame["id"]).__name__, str(frame["id"]))
                if method is not None:
                    if key in requests[direction]:
                        raise ValueError("duplicate outstanding request ID")
                    requests[direction][key] = {"method": method, "seq": event["seq"]}
                else:
                    opposite = "server" if direction == "client" else "client"
                    request = requests[opposite].pop(key, None)
                    if request is None:
                        raise ValueError("response has no matching request")
                    method = request["method"]
                    request_seq = request["seq"]
            schema.validate(frame, direction, method)
        except Exception as error:
            if direction == "server":
                raise ValueError("fixture emitted invalid protocol evidence: " + str(error)) from error
            failures.append(f"client frame {event['seq']}: {error}")
            continue
        frames.append({"event": event, "direction": direction, "frame": frame,
                       "method": method, "request_seq": request_seq})
    return frames, failures


def _rpc(frames, direction, method):
    return [item for item in frames if item["direction"] == direction and item["frame"].get("method") == method]


def _replies(frames, request):
    # Match one outstanding occurrence; a completed ID can be reused later.
    return [item for item in frames if item["direction"] == "server" and "method" not in item["frame"]
            and item["request_seq"] == request["event"]["seq"]]


def _wire(items):
    return [item["event"] for item in items]


def _contained(path, root):
    if not isinstance(path, str) or not isinstance(root, str):
        return False
    current, parent = PurePosixPath(path), PurePosixPath(root)
    if not current.is_absolute() or not parent.is_absolute() or ".." in current.parts or ".." in parent.parts:
        return False
    try:
        relative = current.relative_to(parent)
        return bool(relative.parts)
    except ValueError:
        return False


def _peer_checks(events, plan, corpus):
    peers = _of(events, "peer.started")
    unique = _check("peer.unique", [peers], ["more than one peer launched"] if len(peers) > 1 else [])
    paths = [event["data"].get("cwd") for event in peers]
    failures = ["peer cwd is outside the declared workspace root"] if any(not _contained(path, plan.get("workspace_root")) for path in paths) else []
    expected = str(PurePosixPath(plan["workspace_root"]) / corpus["issue_identifier"])
    if any(path != expected for path in paths):
        failures.append("peer did not use this issue's deterministic workspace")
    identities = [event["data"].get("peer_id") for event in peers]
    if any(not isinstance(item, str) for item in identities):
        raise ValueError("peer startup lacks an identity")
    if peers and any(event["data"].get("peer_id") not in identities
                     for event in events if event["kind"] in {"peer.client", "peer.server", "peer.closed"}):
        failures.append("wire or closure observation belongs to an unknown peer")
    contained = _check("workspace.contained", [peers], failures)
    secrets = []
    for peer in peers:
        env = peer["data"].get("env")
        if not isinstance(env, dict) or any(not isinstance(key, str) or not isinstance(value, str) for key, value in env.items()):
            raise ValueError("peer environment observation is missing or invalid")
        if any(corpus["fake_secret"] in value for value in env.values()):
            secrets.append("fake tracker secret reached the agent environment")
    quarantine = _check("secret.quarantined", [peers], secrets)
    return [unique, contained, quarantine]


def _protocol_checks(events, frames, failures, corpus):
    client = _of(events, "peer.client")
    server = _of(events, "peer.server")
    schema = _check("protocol.schema", [client, server], failures)
    policy = _rpc(frames, "client", METHOD_THREAD)
    wrong = []
    for item in policy:
        params = item["frame"].get("params", {})
        if params.get("approvalPolicy") != corpus["approval_policy"] or params.get("sandbox") != corpus["sandbox"]:
            wrong.append("thread policy differs from the selected corpus policy")
    initialize = _rpc(frames, "client", METHOD_INITIALIZE)
    initialized = _rpc(frames, "client", METHOD_INITIALIZED)
    replies = _replies(frames, initialize[0]) if initialize else []
    if any(len(stage) > 1 for stage in (initialize, replies, initialized)):
        wrong.append("startup messages are duplicated")
    if initialize and replies and initialized and policy:
        order = [initialize[0]["event"]["seq"], replies[0]["event"]["seq"], initialized[0]["event"]["seq"], policy[0]["event"]["seq"]]
        if order != sorted(set(order)):
            wrong.append("initialize reply must precede initialized and thread startup")
    startup = _check("protocol.startup", [_wire(initialize), _wire(replies), _wire(initialized), _wire(policy)], wrong)
    return [schema, startup]


def _turn_checks(frames, corpus):
    threads = _rpc(frames, "client", METHOD_THREAD)
    turns = _rpc(frames, "client", METHOD_TURN)
    replies = [_replies(frames, item) for item in turns]
    thread_replies = _replies(frames, threads[0]) if threads else []
    wrong = []
    if len(threads) > 1:
        wrong.append("continuation opened a new thread")
    if len(turns) > len(corpus["turn_ids"]):
        wrong.append("unexpected extra turn")
    scoped = []
    for item in frames:
        if item["direction"] != "server":
            continue
        params = item["frame"].get("params", {})
        if "threadId" in params:
            scoped.append(item)
            if params["threadId"] != corpus["thread_id"]:
                wrong.append("server notification used a different thread identity")
        if "turnId" in params and params["turnId"] not in corpus["turn_ids"]:
            wrong.append("server notification used an unknown turn identity")
        turn = params.get("turn")
        if isinstance(turn, dict) and "id" in turn and turn["id"] not in corpus["turn_ids"]:
            wrong.append("server notification supplied an unknown turn identity")
    if thread_replies and thread_replies[0]["frame"].get("result", {}).get("thread", {}).get("id") != corpus["thread_id"]:
        wrong.append("thread reply identity differs from the fixed fixture")
    for index, item in enumerate(turns):
        if item["frame"].get("params", {}).get("threadId") != corpus["thread_id"]:
            wrong.append("turn used the wrong thread identity")
        if index < len(corpus["turn_ids"]) and replies[index]:
            actual = replies[index][0]["frame"].get("result", {}).get("turn", {}).get("id")
            if actual != corpus["turn_ids"][index]:
                wrong.append("turn reply identity differs from the fixed fixture")
    stages = [_wire(threads), _wire(thread_replies), _wire(turns[:1]), _wire(turns[1:2])]
    stages.extend(_wire(stage) for stage in replies)
    same = _check("turn.same_thread", stages, wrong)
    same["evidence_seq"] = sorted(set(same["evidence_seq"]) | {item["event"]["seq"] for item in scoped})
    completed = [item for item in _rpc(frames, "server", METHOD_COMPLETED)
                 if item["frame"].get("params", {}).get("turn", {}).get("id") == corpus["turn_ids"][0]]
    failures = []
    if len(turns) > 1 and not completed:
        failures.append("continuation began without first-turn completion")
    if completed and completed[0]["frame"].get("params", {}).get("turn", {}).get("status") != "completed":
        failures.append("first turn did not complete normally")
    if completed and len(turns) > 1 and completed[0]["event"]["seq"] >= turns[1]["event"]["seq"]:
        failures.append("continuation began before first-turn completion")
    finish = _check("turn.completion", [_wire(completed), _wire(turns[1:2])], failures)
    return [same, finish]


def _head_values(headers, name):
    return [value for key, value in headers if key.lower() == name]


def _framing(headers, raw):
    failures = []
    lengths = _head_values(headers, CONTENT_LENGTH)
    value = lengths[0].strip(" \t") if len(lengths) == 1 else ""
    if not value.isascii() or not value.isdigit() or (value.lstrip("0") or "0") != str(len(raw)):
        failures.append("Content-Length differs from the retained raw bytes")
    types = _head_values(headers, CONTENT_TYPE)
    if len(types) != 1 or types[0].split(";", 1)[0].strip(" \t").lower() != JSON_MEDIA_TYPE:
        failures.append("HTTP message lacks a JSON content type")
    if _head_values(headers, TRANSFER_ENCODING):
        failures.append("fixed provider framing does not use transfer encoding")
    return failures


def _provider(events):
    requests = {}
    responses = {}
    for event in events:
        if event["kind"] not in {"provider.request", "provider.response"}:
            continue
        data = event["data"]
        item = data.get("request_id")
        if not isinstance(item, (str, int)) or isinstance(item, bool):
            raise ValueError("provider traffic lacks a request identity")
        raw = _base64(data.get("body"))
        collection = requests if event["kind"] == "provider.request" else responses
        if item in collection:
            raise ValueError("duplicate provider request or response identity")
        headers = data.get("headers")
        if not isinstance(headers, list) or any(not isinstance(pair, list) or len(pair) != 2
                or any(not isinstance(value, str) for value in pair) for pair in headers):
            raise ValueError("invalid raw provider header pairs")
        if event["kind"] == "provider.request":
            if not isinstance(data.get("target"), str) or not isinstance(data.get("method"), str):
                raise ValueError("missing raw provider method or target")
            # Candidate input remains raw until the assertion evaluates it.
            collection[item] = (event, raw)
            continue
        status = data.get("status")
        if type(status) is not int or status not in (HTTPStatus.OK, HTTPStatus.BAD_REQUEST):
            raise ValueError("invalid fixed provider response status")
        framing = _framing(headers, raw)
        if framing:
            raise ValueError("invalid fixture HTTP framing: " + "; ".join(framing))
        connections = [value.strip(" \t").lower() for value in _head_values(headers, CONNECTION)]
        if connections != [CONNECTION_CLOSE]:
            raise ValueError("fixture response does not declare connection closure")
        body = decode(raw)
        if not isinstance(body, dict):
            raise ValueError("fixture provider payload is not an object")
        if status == HTTPStatus.BAD_REQUEST:
            errors = body.get("errors")
            if not isinstance(errors, list) or not errors or any(not isinstance(error, dict)
                    or not isinstance(error.get("message"), str) for error in errors):
                raise ValueError("invalid fixture request rejection payload")
        elif not isinstance(body.get("data"), dict):
            raise ValueError("invalid fixture provider data payload")
        collection[item] = (event, body)
    if set(responses) - set(requests):
        raise ValueError("provider response has no admitted request")
    if any(event["seq"] <= requests[item][0]["seq"] for item, (event, _) in responses.items()):
        raise ValueError("provider response precedes its admitted request")
    return requests, responses


def _tracker_check(events, corpus):
    requests, responses = _provider(events)
    terminal = _of(events, "control.terminal")
    refresh = []
    result = []
    failures = []
    for item, (event, body) in requests.items():
        data = event["data"]
        before = len(failures)
        failures.extend(_framing(data["headers"], body))
        if data.get("method") != corpus["tracker_method"] or data["target"] != corpus["tracker_target"]:
            failures.append("provider request differs from the fixed method or target")
        authorization = [value for name, value in data["headers"]
                         if name.lower() == corpus["tracker_auth_header"].lower()]
        if authorization != [corpus["fake_secret"]]:
            failures.append("provider request has missing, duplicate, or incorrect fake auth")
        try:
            query = select(body)
        except (ValueError, TypeError, GraphQLError, RecursionError):
            failures.append("provider request has invalid JSON or GraphQL")
            continue
        selector = query["filter"].get("id", {})
        if not isinstance(selector, dict):
            failures.append("provider request has an invalid issue ID filter")
            continue
        ids = selector.get("in")
        if item in responses and responses[item][0]["data"]["status"] == HTTPStatus.BAD_REQUEST:
            if len(failures) == before:
                raise ValueError("fixture rejected a request without an observed candidate defect")
            continue
        if ids != [corpus["issue_id"]] or not terminal or event["seq"] <= terminal[0]["seq"]:
            continue
        refresh.append(event)
        if item not in responses:
            continue
        response, payload = responses[item]
        projection = payload["data"].get(query["response_key"])
        if not isinstance(projection, dict) or not isinstance(projection.get("nodes"), list):
            raise ValueError("fixture response lacks the selected issue nodes")
        nodes = projection["nodes"]
        if any(not isinstance(node, dict) or not isinstance(node.get("id"), str)
               or not isinstance(node.get("state"), dict) or not isinstance(node["state"].get("name"), str) for node in nodes):
            raise ValueError("fixture emitted malformed issue nodes")
        matches = [node for node in nodes if isinstance(node, dict) and node.get("id") == corpus["issue_id"]]
        if any(node.get("state", {}).get("name") == corpus["terminal_state"] for node in matches):
            result.append(response)
    if any(event["data"].get("issue_id") != corpus["issue_id"] for event in terminal):
        failures.append("terminal control changed the wrong issue")
    return _check("tracker.terminal_refresh", [terminal, refresh, result], failures)


def _interrupt_check(events, frames, corpus):
    requests = _rpc(frames, "client", METHOD_INTERRUPT)
    replies = _replies(frames, requests[0]) if requests else []
    completed = [item for item in _rpc(frames, "server", METHOD_COMPLETED)
                 if item["frame"].get("params", {}).get("turn", {}).get("id") == corpus["turn_ids"][1]]
    closed = _of(events, "peer.closed")
    terminal = _of(events, "control.terminal")
    wrong = []
    for item in requests:
        params = item["frame"].get("params", {})
        if params.get("threadId") != corpus["thread_id"] or params.get("turnId") != corpus["turn_ids"][1]:
            wrong.append("interrupt targeted the wrong active turn")
    if completed and completed[0]["frame"].get("params", {}).get("turn", {}).get("status") != "interrupted":
        wrong.append("active turn did not report interruption completion")
    if requests and replies and closed and not completed:
        wrong.append("peer closed after interrupt ACK without interruption completion")
    if terminal and requests and replies and completed and closed:
        order = [terminal[0]["seq"], requests[0]["event"]["seq"], replies[0]["event"]["seq"], completed[0]["event"]["seq"], closed[0]["seq"]]
        if order != sorted(set(order)):
            wrong.append("interrupt ACK, completion, and peer closure are out of order")
    return _check("interrupt.completed", [terminal, _wire(requests), _wire(replies), _wire(completed), closed], wrong)


def _hook_check(events, corpus):
    enter = _of(events, "hook.enter")
    exits = _of(events, "hook.exit")
    closed = _of(events, "peer.closed")
    peers = _of(events, "peer.started")
    stages = []
    wrong = []
    order = []
    for name in corpus["hook_names"]:
        starts = [event for event in enter if event["data"].get("name") == name]
        ends = [event for event in exits if event["data"].get("name") == name]
        stages.extend([starts, ends])
        if len(starts) > 1 or len(ends) > 1:
            wrong.append("hook ran more than once in this attempt")
        if ends and ends[0]["data"].get("outcome") != "ok":
            wrong.append("hook did not exit successfully")
        if starts and ends:
            order.extend([starts[0]["seq"], ends[0]["seq"]])
        if name == "before_run" and ends and peers and ends[0]["seq"] >= peers[0]["seq"]:
            wrong.append("agent launched before before_run completed")
        if name == "after_run" and starts:
            if closed and closed[0]["seq"] >= starts[0]["seq"]:
                wrong.append("after_run entered before peer closure")
            if "peer_alive" not in starts[0]["data"]:
                stages.append([])
            elif starts[0]["data"]["peer_alive"] is not False:
                wrong.append("after_run did not independently observe a closed peer")
    if order != sorted(set(order)):
        wrong.append("hook entry/exit order differs from the lifecycle")
    known = set(corpus["hook_names"])
    if any(event["data"].get("name") not in known for event in enter + exits):
        wrong.append("unknown lifecycle hook")
    stages.extend([closed, peers])
    return _check("hooks.order", stages, wrong)


def _workspace_check(events):
    created = _of(events, "workspace.created")
    removed = _of(events, "workspace.removed")
    retained = _of(events, "workspace.retained")
    hooks = [event for event in _of(events, "hook.exit") if event["data"].get("name") == "before_remove"]
    wrong = []
    if retained:
        wrong.append("workspace remained after terminal cleanup")
    if created and removed:
        if created[0]["data"].get("path") != removed[0]["data"].get("path"):
            wrong.append("cleanup removed a different workspace")
        if created[0]["seq"] >= removed[0]["seq"]:
            wrong.append("workspace removal preceded creation")
    if hooks and removed and hooks[0]["seq"] >= removed[0]["seq"]:
        wrong.append("workspace removal preceded before_remove completion")
    return _check("workspace.removed", [created, hooks, removed, retained] if retained else [created, hooks, removed], wrong)


def _shutdown_check(events):
    waits = [event for event in _of(events, "candidate.wait") if event["data"].get("operation") == "join"]
    reaped = [event for event in _of(events, "candidate.wait") if event["data"].get("operation") == "reap"]
    capture = [event for event in _of(events, "capture.closed") if event["data"].get("stage") == "eof"]
    owner = [event for event in _of(events, "capture.closed") if event["data"].get("stage") == "owner-close"]
    provider = _of(events, "provider.closed")
    group = [event for event in _of(events, "group.cleanup")
             if event["data"].get("stage") == "signal" and event["data"].get("signal") == int(SIGKILL)]
    peer = _of(events, "peer.closed")
    descendants = _of(events, "descendant.observed")
    admitted = _of(events, "control.descendant.started")
    wrong = []
    if any(event["data"].get("status") != 0 for event in waits + reaped):
        wrong.append("candidate did not exit successfully")
    for collection in (capture, owner, provider, group):
        if any(event["data"].get("status") != "ok" for event in collection):
            wrong.append("an owned capture, fixture, or group failed cleanup")
    if any(event["data"].get("forced") is not False for event in _of(events, "group.cleanup")):
        wrong.append("live candidate descendants needed forced cleanup")
    if any(event["data"].get("alive") is True for event in descendants):
        wrong.append("an admitted candidate descendant survived natural closure")
    if any(type(event["data"].get("alive")) is not bool for event in descendants):
        wrong.append("descendant closure observation has no boolean outcome")
    if group and any(stage and stage[-1]["seq"] >= group[0]["seq"] for stage in (waits, capture, provider, peer)):
        wrong.append("group custody released before owned resources completed")
    if group and reaped and owner and not group[0]["seq"] < reaped[0]["seq"] < owner[0]["seq"]:
        wrong.append("final guard signal, leader reap, and owner closure are out of order")
    streams = [[event for event in capture if event["data"].get("stream") == stream] for stream in STREAMS]
    stages = [waits, *streams, provider, group, peer, reaped, owner]
    for declaration in admitted:
        pid = declaration["data"].get("pid")
        observations = [event for event in descendants if event["data"].get("pid") == pid]
        stages.append(observations)
        if len(observations) > 1 or not _integer(pid) or pid == 0:
            wrong.append("admitted descendant has ambiguous identity or observations")
        if group and any(not declaration["seq"] < event["seq"] < group[0]["seq"] for event in observations):
            wrong.append("descendant closure was observed outside the natural closure interval")
    return _check("shutdown.joined", stages, wrong)


def _usage_check(events, frames, corpus):
    observations = [event for event in _of(events, "candidate.observation")
                    if event["data"].get("event") == "usage"]
    wire = _rpc(frames, "server", METHOD_USAGE)
    updates = []
    for item in wire:
        params = item["frame"]["params"]
        if params["threadId"] != corpus["thread_id"] or params["turnId"] not in corpus["turn_ids"]:
            raise ValueError("fixture usage update has the wrong session identity")
        total = params["tokenUsage"]["total"]
        updates.append({name: total[field] for name, field in TOKEN_FIELDS.items()})
    if updates and updates != corpus["usage_updates"]:
        raise ValueError("fixture usage stimulus differs from the fixed corpus")
    if not observations:
        return _result("telemetry.absolute", "unobservable", "profile has no numeric usage observation", _wire(wire))
    expected = corpus["usage"]
    actual = {key: observations[-1]["data"].get(key) for key in expected}
    failures = []
    if any(not _integer(value) for value in actual.values()) or actual != expected:
        failures.append("repeated absolute usage differs from the fixed high-water totals")
    for observation in observations:
        if any(not _integer(observation["data"].get(key)) or observation["data"][key] > limit for key, limit in expected.items()):
            failures.append("an observed usage total exceeded the fixed absolute high-water mark")
            break
    return _check("telemetry.absolute", [_wire(wire), observations], failures)


def _cleanup_health(events):
    errors = []
    stages = {"provider.closed": _of(events, "provider.closed")}
    for phase in WAIT_PHASES:
        stages["candidate.wait." + phase] = [event for event in _of(events, "candidate.wait")
                                             if event["data"].get("operation") == phase]
    for stream in STREAMS:
        stages["capture.eof." + stream] = [event for event in _of(events, "capture.closed")
                                           if event["data"].get("stage") == "eof" and event["data"].get("stream") == stream]
    stages["capture.owner-close"] = [event for event in _of(events, "capture.closed")
                                      if event["data"].get("stage") == "owner-close"]
    stages["group.final-guard"] = [event for event in _of(events, "group.cleanup")
                                   if event["data"].get("stage") == "signal" and event["data"].get("signal") == int(SIGKILL)]
    for name, collection in stages.items():
        if len(collection) != 1:
            errors.append("missing or duplicate owned cleanup stage: " + name)
    for kind in ("capture.closed", "provider.closed", "group.cleanup"):
        collection = _of(events, kind)
        if any(event["data"].get("status") != "ok" for event in collection):
            errors.append("owned cleanup failed: " + kind)
    return errors


def _capture_bytes(events, files):
    for stream in STREAMS:
        chunks = []
        for event in _of(events, "capture." + stream):
            raw = _base64(event["data"].get("data_b64"))
            if not _integer(event["data"].get("bytes")) or len(raw) != event["data"]["bytes"]:
                raise ValueError("capture chunk byte count mismatch")
            chunks.append(raw)
        if b"".join(chunks) != files[stream + ".bin"]:
            raise ValueError("capture chunks differ from retained raw " + stream)


def _features(profile):
    extensions = profile["extensions"]
    return {
        "provider_native_agent_tools": "present" if extensions["provider_native_tools"] else "absent",
        "snapshot_api": "present" if extensions["http"] else "unknown",
        "human_readable_status": "present" if extensions["http"] else "unknown",
    }


def _case(events, plan, canonical):
    corpus, profile = canonical["corpus"], canonical["profile"]
    frames, failures = _frames(events, corpus)
    assertions = _peer_checks(events, plan, corpus)
    assertions.extend(_protocol_checks(events, frames, failures, corpus))
    assertions.extend(_turn_checks(frames, corpus))
    assertions.extend([
        _tracker_check(events, corpus), _interrupt_check(events, frames, corpus),
        _hook_check(events, corpus), _workspace_check(events),
        _shutdown_check(events), _usage_check(events, frames, corpus),
    ])
    states = {item["status"] for item in assertions}
    status = next((state for state in ("fail", "incomplete", "unobservable") if state in states), "pass")
    coverage = {}
    for assertion, requirements in COVERAGE.items():
        for requirement in requirements:
            entry = coverage.setdefault(requirement, {"case_id": CORPUS_ID, "complete": False, "assertion_ids": []})
            entry["assertion_ids"].append(assertion)
    return {"id": CORPUS_ID, "status": status, "assertions": assertions,
            "features": _features(profile), "coverage": coverage, "scope": corpus["scope"]}


def judge(bundle: Path) -> dict:
    """Return independent assertion results and a complete requirement inventory."""
    catalog = load("catalog.json")
    identities = {}
    case = {"id": CORPUS_ID, "status": "incomplete", "assertions": [], "coverage": {}, "features": {}}
    errors = []
    try:
        manifest, files = _read_bundle(Path(bundle))
        canonical = _canonical(manifest, files)
        identities = dict(manifest["identities"])
        identities.update({"profile_id": manifest["profile_id"], "corpus_id": manifest["corpus_id"]})
        identities["evidence_files"] = manifest["files"]
        errors.extend(manifest["harness_errors"])
        if not manifest["completed"]:
            errors.append("bundle never completed candidate and fixture cleanup")
        events = _events(files[JOURNAL])
        _capture_bytes(events, files)
        errors.extend(_cleanup_health(events))
        plan = decode(files[PLAN])
        if not isinstance(plan, dict) or not isinstance(plan.get("workspace_root"), str):
            raise ValueError("missing declared workspace run context")
        case = _case(events, plan, canonical)
    except (OSError, ValueError, TypeError, KeyError, AttributeError) as error:
        errors.append(str(error))
    harness = {"status": "harness_error" if errors else "pass", "errors": errors}
    return build(catalog, case, harness, identities)
