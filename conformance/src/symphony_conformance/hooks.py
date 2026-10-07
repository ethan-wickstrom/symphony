"""Observe lifecycle hooks without substituting fixture claims for OS liveness."""

import argparse
import errno
import os
from pathlib import Path

from .assets import decode
from .driver.observer import Observer

HOOK_NAMES = ("after_create", "before_run", "after_run", "before_remove")
TRACKER_SECRET_NAME = "LINEAR_API_KEY"


def _env(plan):
    # Evidence may contain the injected fake secret, never arbitrary credentials.
    names = plan["profile"]["ambient_environment"]
    result = {name: os.environ[name] for name in names if name in os.environ}
    fake = plan["corpus"]["fake_secret"]
    result.update({name: value for name, value in os.environ.items() if value == fake})
    if TRACKER_SECRET_NAME in os.environ:
        result[TRACKER_SECRET_NAME] = (
            fake if os.environ[TRACKER_SECRET_NAME] == fake else "<redacted>"
        )
    return result


def _peer_state(control):
    path = control / "peer.json"
    if not path.exists():
        return {"peer_id": None, "peer_pid": None, "peer_alive": None,
                "peer_closed": False, "probe_error": "missing-peer"}
    identity = decode(path.read_bytes())
    pid = identity["pid"]
    if type(pid) is not int or pid <= 0:
        raise ValueError("Invalid owned peer PID")
    closed_path = control / "peer-closed.json"
    closed = closed_path.exists() and decode(closed_path.read_bytes()) == identity
    result = {"peer_id": identity["peer_id"], "peer_pid": pid,
              "peer_alive": None, "peer_closed": closed, "probe_error": None}
    try:
        os.kill(pid, 0)
        result["peer_alive"] = True
    except OSError as error:
        if error.errno == errno.ESRCH:
            result["peer_alive"] = False
        elif error.errno == errno.EPERM:
            result["peer_alive"] = True
            result["probe_error"] = "permission"
        else:
            result["probe_error"] = "os-error-" + str(error.errno)
    return result


def run(plan, name):
    observer = Observer(plan["collector_url"], "hook:" + name)
    data = {"name": name, "cwd": os.getcwd(), "pid": os.getpid(), "env": _env(plan)}
    try:
        if name == "after_run":
            data.update(_peer_state(Path(plan["control_root"])))
    except Exception as error:
        observer.emit("hook.enter", data)
        observer.emit("hook.exit", {**data, "outcome": "error", "error_type": type(error).__name__})
        raise
    observer.emit("hook.enter", data)
    # This fixture owns no candidate workspace effects; the service owns cleanup.
    observer.emit("hook.exit", {**data, "outcome": "ok"})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plan", type=Path, required=True)
    parser.add_argument("--name", choices=HOOK_NAMES, required=True)
    args = parser.parse_args()
    run(decode(args.plan.read_bytes()), args.name)


if __name__ == "__main__":
    main()
