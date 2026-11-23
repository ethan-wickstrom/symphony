"""Check consumed policy definitions against retained generated Codex schemas."""

import argparse
import hashlib
import json
from pathlib import Path
import re

from symphony_conformance.assets import decode, load, resource

SNAPSHOT_FILES = frozenset({"ThreadStartParams.json", "TurnStartParams.json", "policies.json"})


def check(root: Path) -> None:
    directory = root / "protocol" / "0.159.2"
    selected = decode((directory / "policies.json").read_bytes())["definitions"]
    canonical = load("protocol/manifest.json")
    definitions = {}
    for name in ["ThreadStartParams", "TurnStartParams"]:
        data = resource(f"protocol/schemas/v2/{name}.json").read_bytes()
        if hashlib.sha256(data).hexdigest() != canonical["files"][f"v2/{name}.json"]:
            raise SystemExit(f"Protocol snapshot: canonical hash mismatch for {name}.json")
        generated = decode(data)["definitions"]
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
    manifest = decode((directory / "manifest.json").read_bytes())
    hashes = manifest.get("sha256") if isinstance(manifest, dict) else None
    if not isinstance(hashes, dict) or hashes.keys() != SNAPSHOT_FILES:
        raise SystemExit("Protocol snapshot: manifest.json sha256 keys must be "
                         + ", ".join(sorted(SNAPSHOT_FILES)))
    for name in sorted(SNAPSHOT_FILES):
        expected = hashes[name]
        if not isinstance(expected, str) or not re.fullmatch(r"[0-9a-f]{64}", expected):
            raise SystemExit(f"Protocol snapshot: manifest.json has invalid SHA-256 for {name}; "
                             "use 64 lowercase hexadecimal digits")
        raw = ((directory / name).read_bytes() if name == "policies.json"
               else resource("protocol/schemas/v2/" + name).read_bytes())
        if hashlib.sha256(raw).hexdigest() != expected:
            raise SystemExit(f"Protocol snapshot: hash mismatch for {name}; regenerate the snapshot")
    print("Protocol snapshot: generated definitions and hashes match")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path)
    check(parser.parse_args().root)
