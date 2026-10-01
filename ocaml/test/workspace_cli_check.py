"""Read-only workspace CLI checks against independent on-disk ownership fixtures."""

import argparse
import fcntl
import json
import os
from pathlib import Path
import stat
import subprocess
import tempfile


OWNER_VERSION = 1
UINT64_MASK = (1 << 64) - 1


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"Workspace CLI: {message}")


def projection(root: Path) -> dict:
    """Compare entries, identities, permissions and bytes; ignore access times."""
    if not root.exists():
        return {}

    entries = [root]
    for directory, folders, files in os.walk(root, followlinks=False):
        entries.extend(Path(directory) / name for name in folders + files)

    result = {}
    for entry in entries:
        status = entry.lstat()
        payload = None
        if stat.S_ISREG(status.st_mode):
            payload = entry.read_bytes()
        elif stat.S_ISLNK(status.st_mode):
            payload = os.readlink(entry)
        result[str(entry.relative_to(root))] = (
            status.st_dev, status.st_ino, status.st_mode, payload,
        )
    return result


def owned(root: Path, issue: dict, endpoint: str, project: str) -> Path:
    """Publish the documented owner format independently of OCaml serializers."""
    key = issue["identifier"]
    workspace = root / key
    workspace.mkdir(mode=0o700)
    (workspace / "keep.txt").write_text("preserved workspace contents\n")
    metadata = root / "@symphony" / key
    metadata.mkdir(mode=0o700, parents=True)
    (root / "@symphony").chmod(0o700)
    metadata.chmod(0o700)
    lock = metadata / "lock"
    lock.touch(mode=0o600)
    status = workspace.stat()
    owner = {
        "version": OWNER_VERSION,
        "scope": f"{len(endpoint.encode('utf-8'))}:{endpoint}{project}",
        "issue_id": issue["id"],
        "identifier": issue["identifier"],
        "device": f"{status.st_dev & UINT64_MASK:016x}",
        "inode": f"{status.st_ino & UINT64_MASK:016x}",
    }
    record = metadata / "owner"
    record.write_text(json.dumps(owner, separators=(",", ":")))
    record.chmod(0o600)
    return workspace


def run(binary: Path) -> None:
    with tempfile.TemporaryDirectory(prefix="symphony-workspace-cli-") as directory:
        base = Path(directory).resolve()
        source = base / "definition"
        source.mkdir(mode=0o700)
        home = base / "home"
        home.mkdir(mode=0o700)
        (home / ".bash_profile").write_text("")
        workflow = source / "WORKFLOW.md"
        fixture = base / "issue.json"
        root = source / "workspaces"
        marker = base / "hook-marker"
        endpoint = "https://tracker.example.test/graphql"
        project = "fixture"
        credential = "fixture-workspace-secret-must-not-print"
        env = dict(os.environ, LINEAR_API_KEY=credential, TMPDIR=str(base),
                   HOME=str(home), PATH="/usr/bin:/bin", TERM="dumb")
        issue = {
            "id": "opaque-local-id", "identifier": "TEST-1",
            "title": "untrusted $(touch INJECTED)", "state": "Todo",
            "labels": ["A"], "dispatchable": True,
        }

        def write(project_name: str = project) -> None:
            script = ': > "$TMPDIR/hook-marker"'
            settings = (
                "tracker:\n  kind: linear\n  active_states: [Todo]\n"
                "  terminal_states: [Done]\n  provider:\n"
                f"    endpoint: {endpoint}\n    project_slug: {project_name}\n"
                "workspace:\n  root: ./workspaces\nhooks:\n"
            )
            for phase in ("after_create", "before_run", "after_run", "before_remove"):
                settings += f"  {phase}: {json.dumps(script)}\n"
            workflow.write_text(f"---\n{settings}---\n{{{{ issue.identifier }}}}\n")
            fixture.write_text(json.dumps(issue))

        def invoke() -> subprocess.CompletedProcess[str]:
            result = subprocess.run(
                [str(binary), "workspace", str(workflow), "--issue", str(fixture)],
                cwd=base, env=env, text=True, capture_output=True, timeout=10,
            )
            require(credential not in result.stdout + result.stderr, "credential leaked")
            require(not marker.exists(), "inspection ran a hook")
            require(not (base / "INJECTED").exists(), "inspection executed issue text")
            return result

        def unchanged(before: dict) -> None:
            require(projection(root) == before, "inspection changed workspace filesystem")

        def rejected(result: subprocess.CompletedProcess[str]) -> None:
            require(result.returncode != 0 and not result.stdout,
                    "unsafe/busy ownership inspection succeeded or emitted a label")
            require(str(workflow) in result.stderr and "issue TEST-1" in result.stderr,
                    "inspection error omitted workflow or issue context")
            require(";" in result.stderr, "inspection error omitted a remedy")

        write()
        missing = invoke()
        require(missing.returncode == 0 and missing.stdout == "Workspace missing: TEST-1\n",
                "missing root did not report absence")
        require(not root.exists(), "missing inspection created the root")

        root.mkdir(mode=0o700)
        empty = projection(root)
        require(invoke().returncode == 0, "missing key inspection failed")
        unchanged(empty)

        workspace = owned(root, issue, endpoint, project)
        before = projection(root)
        for _ in range(2):
            existing = invoke()
            require(existing.returncode == 0
                    and existing.stdout == f"Workspace: {workspace}\n",
                    "owned workspace inspection lost its checked display label")
            unchanged(before)

        lock = root / "@symphony" / issue["identifier"] / "lock"
        with lock.open("rb") as held:
            fcntl.flock(held.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
            rejected(invoke())
        unchanged(before)

        issue["id"] = "different-opaque-id"
        write()
        rejected(invoke())
        unchanged(before)
        issue["id"] = "opaque-local-id"

        write("another-project")
        rejected(invoke())
        unchanged(before)
        write()

        outside = base / "outside"
        outside.mkdir(mode=0o700)
        (outside / "keep.txt").write_text("outside contents\n")
        workspace.rename(root / "owned-backup")
        workspace.symlink_to(outside, target_is_directory=True)
        replaced = projection(root)
        outside_before = projection(outside)
        rejected(invoke())
        unchanged(replaced)
        require(projection(outside) == outside_before, "inspection touched a symlink target")

        issue["identifier"] = "CONTROL-\n\x1b[31m"
        write()
        controls = invoke()
        require(controls.returncode == 0 and controls.stdout.count("\n") == 1
                and "\x1b" not in controls.stdout + controls.stderr
                and "\\n" in controls.stdout,
                "inspection emitted raw terminal controls from an issue identifier")
        unchanged(replaced)

    print("Workspace CLI: 8 scenarios passed")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    args = parser.parse_args()
    run(args.binary.resolve())
