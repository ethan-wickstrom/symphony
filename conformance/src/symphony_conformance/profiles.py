"""Public launch and observation translations; profiles do not supply verdicts."""

import os
import shlex
import sys
from pathlib import Path

from .assets import decode


def command(module, plan, *extra):
    # Keep the venv executable path: resolving its symlink loses site-packages.
    optimize = ["-OO" if sys.flags.optimize > 1 else "-O"] if sys.flags.optimize else []
    return [sys.executable, *optimize, "-m", "symphony_conformance." + module, "--plan", str(plan), *extra]


def environment(profile, root, corpus):
    result = {name: os.environ[name] for name in profile["ambient_environment"] if name in os.environ}
    for name in ("home", "tmp"):
        (root / name).mkdir()
    result.update(HOME=str(root / "home"), TMPDIR=str(root / "tmp"),
                  LINEAR_API_KEY=corpus["fake_secret"],
                  HTTPS_PROXY="http://127.0.0.1:1", SSL_CERT_FILE=str(root / "absent.pem"))
    return result


def workflow(path, plan_path, endpoint, corpus, workspace):
    import json

    hooks = []
    for name in corpus["hook_names"]:
        value = shlex.join(command("hooks", plan_path, "--name", name))
        hooks.append("  " + name + ": " + json.dumps(value))
    peer = "exec " + shlex.join(command("peer", plan_path))
    lines = ["---", "tracker:", "  kind: linear",
             "  active_states: [" + corpus["active_state"] + "]",
             "  terminal_states: [" + corpus["terminal_state"] + "]",
             "  provider:", "    project_slug: " + corpus["project"],
             "    endpoint: " + endpoint,
             "polling:", "  interval_ms: " + str(corpus["candidate_poll_ms"]),
             "agent:", "  max_concurrent_agents: 1", "  max_turns: 2",
             "workspace:", "  root: " + json.dumps(str(workspace)),
             "hooks:", *hooks, "  timeout_ms: " + str(corpus["candidate_hook_timeout_ms"]),
             "codex:", "  command: " + json.dumps(peer),
             "  approval_policy: " + corpus["approval_policy"],
             "  thread_sandbox: " + corpus["sandbox"],
             "  read_timeout_ms: " + str(corpus["candidate_read_timeout_ms"]),
             "  turn_timeout_ms: " + str(corpus["candidate_turn_timeout_ms"]),
             "---", "Fixture {{ issue.identifier }}: {{ issue.title }}", ""]
    path.write_text("\n".join(lines))


def launch(profile, candidate, workflow_path, ca, plan_path):
    if profile["id"] == "scripted":
        return command("control", plan_path)
    if profile["id"] == "ocaml":
        binary = Path(candidate).resolve(strict=True)
        if not binary.is_file():
            raise ValueError("Candidate is not a regular file")
        return [str(binary), str(workflow_path), "--ca-bundle", str(ca)]
    raise ValueError("Unknown profile")


def field(value):
    result = bytearray()
    index = 0
    while index < len(value):
        if value[index] != ord("\\"):
            result.append(value[index])
            index += 1
            continue
        escape = value[index:index + 4]
        if len(escape) != 4 or escape[:2] != b"\\x" or any(b not in b"0123456789abcdef" for b in escape[2:]):
            raise ValueError("Malformed public log escape")
        result.append(int(escape[2:], 16))
        index += 4
    return result.decode("utf-8")


def observation(profile, line):
    if profile["id"] == "scripted":
        value = decode(line)
        if not isinstance(value, dict) or not isinstance(value.get("event"), str):
            raise ValueError("Malformed scripted public observation")
        return value
    if not line.startswith(b"event="):
        return None
    result = {}
    for part in line.split(b" "):
        key, separator, value = part.partition(b"=")
        name = key.decode("ascii")
        if not separator or not name or name in result:
            raise ValueError("Malformed public log field")
        result[name] = field(value)
    return result
