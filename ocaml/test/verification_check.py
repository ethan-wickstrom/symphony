"""Check verification gates reject corrupted fixtures in both Python modes."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


SNAPSHOT = Path("protocol") / "0.159.2"


def run(root: Path) -> None:
    with tempfile.TemporaryDirectory(prefix="symphony-verification-") as directory:
        temporary = Path(directory)

        def fake(name: str, body: str) -> Path:
            path = temporary / name
            path.write_text(f"#!{sys.executable}\n{body}\n")
            path.chmod(0o755)
            return path

        wrong = fake("wrong-cli", 'print("wrong CLI behavior")')
        leak = fake("leaking-cli", 'import os\nprint(os.environ["LINEAR_API_KEY"])')

        def snapshot(name: str) -> Path:
            path = temporary / name
            shutil.copytree(root / SNAPSHOT, path / SNAPSHOT)
            source = path / "lib" / "workflow"
            source.mkdir(parents=True)
            shutil.copyfile(root / "lib" / "workflow" / "policy_schema.ml", source / "policy_schema.ml")
            return path

        semantic = snapshot("semantic")
        policies = semantic / SNAPSHOT / "policies.json"
        data = json.loads(policies.read_text())
        key = sorted(data["definitions"])[0]
        data["definitions"][key]["x-verification-control"] = True
        policies.write_text(json.dumps(data))
        manifest = policies.with_name("manifest.json")
        hashes = json.loads(manifest.read_text())
        hashes["sha256"][policies.name] = hashlib.sha256(policies.read_bytes()).hexdigest()
        manifest.write_text(json.dumps(hashes))

        changed_hash = snapshot("hash")
        manifest = changed_hash / SNAPSHOT / "manifest.json"
        hashes = json.loads(manifest.read_text())
        hashes["sha256"]["ThreadStartParams.json"] = hashlib.sha256(
            b"verification-corrupted-schema").hexdigest()
        manifest.write_text(json.dumps(hashes))

        missing_hash = snapshot("missing-hash")
        manifest = missing_hash / SNAPSHOT / "manifest.json"
        hashes = json.loads(manifest.read_text())
        del hashes["sha256"]["ThreadStartParams.json"]
        manifest.write_text(json.dumps(hashes))

        extra_hash = snapshot("extra-hash")
        manifest = extra_hash / SNAPSHOT / "manifest.json"
        extra = manifest.with_name("unexpected.json")
        extra.write_text("{}")
        hashes = json.loads(manifest.read_text())
        hashes["sha256"][extra.name] = hashlib.sha256(extra.read_bytes()).hexdigest()
        manifest.write_text(json.dumps(hashes))

        controls = [
            ("wrong CLI", root / "test" / "cli_check.py", wrong, "workflow-relative root"),
            ("credential leak", root / "test" / "cli_check.py", leak, "fixture credential leaked"),
            ("schema mismatch", root / "tools" / "check_protocol.py", semantic, "policies.json differs"),
            ("hash mismatch", root / "tools" / "check_protocol.py", changed_hash, "hash mismatch"),
            ("missing digest", root / "tools" / "check_protocol.py", missing_hash, "sha256 keys"),
            ("extra digest", root / "tools" / "check_protocol.py", extra_hash, "sha256 keys"),
        ]
        for name, value in [("non-hex digest", "z" * 64), ("non-text digest", None)]:
            invalid = snapshot(name)
            manifest = invalid / SNAPSHOT / "manifest.json"
            hashes = json.loads(manifest.read_text())
            hashes["sha256"]["policies.json"] = value
            manifest.write_text(json.dumps(hashes))
            controls.append((name, root / "tools" / "check_protocol.py", invalid, "invalid SHA-256"))
        failures = []
        for mode in ["0", "1"]:
            for name, script, fixture, diagnostic in controls:
                result = subprocess.run(
                    [sys.executable, str(script), str(fixture)],
                    env=dict(os.environ, PYTHONOPTIMIZE=mode),
                    text=True, capture_output=True, timeout=30,
                )
                if result.returncode == 0:
                    failures.append(f"{name} passed with PYTHONOPTIMIZE={mode}")
                elif diagnostic not in result.stderr:
                    failures.append(f"{name} failed for the wrong reason with PYTHONOPTIMIZE={mode}")
        if failures:
            raise SystemExit("Verification control: " + "; ".join(failures))

    print(f"Verification controls: {len(controls) * 2} corrupted fixtures rejected")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path)
    run(parser.parse_args().root.resolve())
