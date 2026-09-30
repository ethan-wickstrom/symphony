"""Check consumed policy definitions against retained generated Codex schemas."""

import argparse
import hashlib
import json
from pathlib import Path
import re


def check(root: Path) -> None:
    directory = root / "protocol" / "0.159.2"
    selected = json.loads((directory / "policies.json").read_text())["definitions"]
    definitions = {}
    for name in ["ThreadStartParams", "TurnStartParams"]:
        data = (directory / f"{name}.json").read_bytes()
        generated = json.loads(data)["definitions"]
        for key in selected:
            if key in generated:
                if key in definitions and definitions[key] != generated[key]:
                    raise SystemExit(f"Protocol snapshot: conflicting generated definition {key} in {name}.json")
                definitions[key] = generated[key]
    if selected != definitions:
        raise SystemExit("Protocol snapshot: policies.json differs from generated definitions")
    source = (root / "lib" / "workflow" / "policy_schema.ml").read_text()
    match = re.search(r"\{schema\|(.*?)\|schema\}", source, re.S)
    if not match or json.loads(match.group(1)) != {"definitions": definitions}:
        raise SystemExit("Protocol snapshot: policy_schema.ml differs from generated definitions")
    manifest = json.loads((directory / "manifest.json").read_text())
    for name, expected in manifest["sha256"].items():
        if hashlib.sha256((directory / name).read_bytes()).hexdigest() != expected:
            raise SystemExit(f"Protocol snapshot: hash mismatch for {name}; regenerate the snapshot")
    print("Protocol snapshot: generated definitions and hashes match")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path)
    check(parser.parse_args().root)
