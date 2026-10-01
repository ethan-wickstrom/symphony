"""Observable CLI/file-boundary tests; inputs contain only fixture credentials."""

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
import workspace_cli_check


def require(condition: bool, message: str) -> None:
    if not condition:
        raise SystemExit(f"CLI integration: {message}")


def run(binary: Path) -> None:
    with tempfile.TemporaryDirectory(prefix="symphony-cli-") as directory:
        root = Path(directory)
        source = root / "definition"
        source.mkdir()
        workflow = source / "WORKFLOW.md"
        fixture = root / "issue.json"
        credential = "fixture-secret-that-must-not-be-printed"
        env = dict(os.environ, LINEAR_API_KEY=credential, TMPDIR=directory)
        config = (
            "tracker:\n  kind: linear\n  active_states: [Todo]\n"
            "  terminal_states: [Done]\n  provider:\n    project_slug: fixture\n"
            "workspace:\n  root: ./workspaces\n"
        )

        def write(prompt: str, settings: str = config) -> None:
            workflow.write_text(f"---\n{settings}---\n{prompt}\n")

        def invoke(*args: str) -> subprocess.CompletedProcess[str]:
            result = subprocess.run(
                [str(binary), *args], cwd=root, env=env,
                text=True, capture_output=True, timeout=10,
            )
            require(credential not in result.stdout + result.stderr, "fixture credential leaked")
            return result

        issue = {
            "id": "opaque-local-id", "identifier": "TEST-1",
            "title": "{{ missing }}", "state": "Todo", "labels": ["A"],
            "assignee_id": "opaque-assignee", "dispatchable": True,
            "blocked_by": [{"id": "blocker-id", "identifier": "TEST-0", "state": "Done"}],
        }
        fixture.write_text(json.dumps(issue))
        write("{{ issue.identifier }} {{ issue.title }} {{ issue.labels }} "
              "{{ issue.blocked_by[0].identifier }} {% if attempt %}retry {{ attempt }}{% endif %}")
        valid = invoke("doctor", str(workflow))
        require(valid.returncode == 0, "doctor rejected valid workflow")
        require(str(source / "workspaces") in valid.stdout, "doctor lost workflow-relative root")
        default = root / "WORKFLOW.md"
        default.write_text(workflow.read_text())
        implicit = invoke("doctor")
        require(implicit.returncode == 0 and str(root / "workspaces") in implicit.stdout,
                "doctor did not resolve default workflow")
        prompt = invoke("dry-run", str(workflow), "--issue", str(fixture))
        require(prompt.returncode == 0, "dry-run rejected valid issue fixture")
        require('TEST-1 {{ missing }} ["a"] TEST-0' in prompt.stdout,
                "dry-run lost normalized issue values")
        require("retry" not in prompt.stdout, "dry-run invented an initial retry attempt")
        retry = invoke("dry-run", str(workflow), "--issue", str(fixture), "--attempt", "2")
        require(retry.returncode == 0 and "retry 2" in retry.stdout, "dry-run lost retry attempt")

        write("{{ issue.assignee_id }}|{{ issue.dispatchable }}")
        assigned = invoke("dry-run", str(workflow), "--issue", str(fixture))
        require(assigned.returncode == 0 and assigned.stdout.strip() == "opaque-assignee|true",
                "dry-run lost assignee or explicit eligibility")
        issue["assignee_id"] = None
        fixture.write_text(json.dumps(issue))
        unassigned = invoke("dry-run", str(workflow), "--issue", str(fixture))
        require(unassigned.returncode == 0 and unassigned.stdout.strip() == "|true",
                "dry-run treated null assignee as missing")
        issue["dispatchable"] = False
        fixture.write_text(json.dumps(issue))
        ineligible = invoke("dry-run", str(workflow), "--issue", str(fixture))
        require(ineligible.returncode == 0 and ineligible.stdout.strip() == "|false",
                "dry-run discarded false eligibility")
        del issue["dispatchable"]
        fixture.write_text(json.dumps(issue))
        absent_eligibility = invoke("dry-run", str(workflow), "--issue", str(fixture))
        require(absent_eligibility.returncode != 0 and not absent_eligibility.stdout
                and "dispatchable" in absent_eligibility.stderr,
                "dry-run accepted missing eligibility")
        issue["dispatchable"] = "true"
        fixture.write_text(json.dumps(issue))
        bad_eligibility = invoke("dry-run", str(workflow), "--issue", str(fixture))
        require(bad_eligibility.returncode != 0 and not bad_eligibility.stdout
                and "dispatchable" in bad_eligibility.stderr,
                "dry-run accepted malformed eligibility")
        issue["dispatchable"] = True
        fixture.write_text(json.dumps(issue))

        bad_attempt = invoke("dry-run", str(workflow), "--issue", str(fixture), "--attempt", "0")
        require(bad_attempt.returncode != 0 and not bad_attempt.stdout, "dry-run accepted attempt zero")
        require("--attempt" in bad_attempt.stderr and "positive" in bad_attempt.stderr,
                "attempt diagnostic omitted option or remedy")
        require(";" in bad_attempt.stderr, "attempt diagnostic omitted remedy separator")
        write("ok", config.replace("kind: linear", "kind: $LINEAR_API_KEY"))
        hidden = invoke("doctor", str(workflow))
        require(hidden.returncode != 0 and "tracker.kind" in hidden.stderr,
                "doctor accepted secret tracker kind or omitted its key")
        write("ok", config.replace("project_slug: fixture", "endpoint: https://host:bad/graphql\n    project_slug: fixture"))
        endpoint = invoke("doctor", str(workflow))
        require(endpoint.returncode != 0 and "tracker.provider.endpoint" in endpoint.stderr,
                "doctor accepted malformed endpoint or omitted its key")

        write("{{ issue.missing }}")
        missing = invoke("dry-run", str(workflow), "--issue", str(fixture))
        require(missing.returncode != 0 and not missing.stdout, "dry-run accepted missing template field")
        require(str(workflow) in missing.stderr and "missing" in missing.stderr,
                "missing-field diagnostic omitted workflow or key")
        write("ok", config + "polling:\n  interval_ms: 0\n")
        bad = invoke("doctor", str(workflow))
        require(bad.returncode != 0 and not bad.stdout, "doctor accepted zero polling interval")
        require("polling.interval_ms" in bad.stderr and str(workflow) in bad.stderr,
                "polling diagnostic omitted workflow or key")
        workflow.write_text("---\n- not-a-map\n---\nok\n")
        require(invoke("doctor", str(workflow)).returncode != 0, "doctor accepted non-map front matter")
        workflow.write_text("---\ntracker: {}\ntracker: " + credential + "\n---\nok\n")
        require(invoke("doctor", str(workflow)).returncode != 0, "doctor accepted duplicate YAML key")
        workflow.unlink()
        absent = invoke("doctor", str(workflow))
        require(absent.returncode != 0 and str(workflow) in absent.stderr,
                "doctor accepted missing workflow or omitted its path")
        workflow.write_text("x" * (1_048_576 + 1))
        oversized = invoke("doctor", str(workflow))
        require(oversized.returncode != 0 and "limit" in oversized.stderr,
                "doctor accepted oversized workflow or omitted limit diagnostic")

    print("CLI integration: 19 scenarios passed")
    workspace_cli_check.run(binary)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    args = parser.parse_args()
    run(args.binary.resolve())
