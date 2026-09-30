"""Observable CLI/file-boundary tests; inputs contain only fixture credentials."""

import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile


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
            assert credential not in result.stdout + result.stderr
            return result

        fixture.write_text(json.dumps({
            "id": "opaque-local-id", "identifier": "TEST-1",
            "title": "{{ missing }}", "state": "Todo", "labels": ["A"],
            "blocked_by": [{"id": "blocker-id", "identifier": "TEST-0", "state": "Done"}],
        }))
        write("{{ issue.identifier }} {{ issue.title }} {{ issue.labels }} "
              "{{ issue.blocked_by[0].identifier }} {% if attempt %}retry {{ attempt }}{% endif %}")
        valid = invoke("doctor", str(workflow))
        assert valid.returncode == 0, valid.stderr
        assert str(source / "workspaces") in valid.stdout
        default = root / "WORKFLOW.md"
        default.write_text(workflow.read_text())
        implicit = invoke("doctor")
        assert implicit.returncode == 0 and str(root / "workspaces") in implicit.stdout
        prompt = invoke("dry-run", str(workflow), "--issue", str(fixture))
        assert prompt.returncode == 0, prompt.stderr
        assert 'TEST-1 {{ missing }} ["a"] TEST-0' in prompt.stdout
        assert "retry" not in prompt.stdout
        retry = invoke("dry-run", str(workflow), "--issue", str(fixture), "--attempt", "2")
        assert retry.returncode == 0 and "retry 2" in retry.stdout

        bad_attempt = invoke("dry-run", str(workflow), "--issue", str(fixture), "--attempt", "0")
        assert bad_attempt.returncode != 0 and not bad_attempt.stdout
        assert "--attempt" in bad_attempt.stderr and "positive" in bad_attempt.stderr
        assert ";" in bad_attempt.stderr
        write("ok", config.replace("kind: linear", "kind: $LINEAR_API_KEY"))
        hidden = invoke("doctor", str(workflow))
        assert hidden.returncode != 0 and "tracker.kind" in hidden.stderr
        write("ok", config.replace("project_slug: fixture", "endpoint: https://host:bad/graphql\n    project_slug: fixture"))
        endpoint = invoke("doctor", str(workflow))
        assert endpoint.returncode != 0 and "tracker.provider.endpoint" in endpoint.stderr

        write("{{ issue.missing }}")
        missing = invoke("dry-run", str(workflow), "--issue", str(fixture))
        assert missing.returncode != 0 and not missing.stdout
        assert str(workflow) in missing.stderr and "missing" in missing.stderr
        write("ok", config + "polling:\n  interval_ms: 0\n")
        bad = invoke("doctor", str(workflow))
        assert bad.returncode != 0 and not bad.stdout
        assert "polling.interval_ms" in bad.stderr and str(workflow) in bad.stderr
        workflow.write_text("---\n- not-a-map\n---\nok\n")
        assert invoke("doctor", str(workflow)).returncode != 0
        workflow.write_text("---\ntracker: {}\ntracker: " + credential + "\n---\nok\n")
        assert invoke("doctor", str(workflow)).returncode != 0
        workflow.unlink()
        absent = invoke("doctor", str(workflow))
        assert absent.returncode != 0 and str(workflow) in absent.stderr
        workflow.write_text("x" * (1_048_576 + 1))
        oversized = invoke("doctor", str(workflow))
        assert oversized.returncode != 0 and "limit" in oversized.stderr

    print("CLI integration: 14 scenarios passed")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    args = parser.parse_args()
    run(args.binary.resolve())
