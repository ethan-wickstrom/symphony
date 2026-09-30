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
                assert key not in definitions or definitions[key] == generated[key]
                definitions[key] = generated[key]
    assert selected == definitions
    source = (root / "lib" / "workflow" / "policy_schema.ml").read_text()
    match = re.search(r"\{schema\|(.*?)\|schema\}", source, re.S)
    assert match and json.loads(match.group(1)) == {"definitions": definitions}
    manifest = json.loads((directory / "manifest.json").read_text())
    for name, expected in manifest["sha256"].items():
        assert hashlib.sha256((directory / name).read_bytes()).hexdigest() == expected
    print("Protocol snapshot: generated definitions and hashes match")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("root", type=Path)
    check(parser.parse_args().root)
