"""Verify the pinned H1 source and exercise corrupted-source controls."""

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import tempfile


MANIFEST = "SYMPHONY_SOURCE.json"
NOTES = "SYMPHONY_PATCHES.md"
MANIFEST_SHA = "efe4dad1bbab3dbd07b5c637d657201d5056fdd15601d27699c686026c9f03e6"


def verify(root: Path) -> None:
    manifest = root / MANIFEST
    if manifest.is_symlink() or hashlib.sha256(manifest.read_bytes()).hexdigest() != MANIFEST_SHA:
        raise ValueError("H1 provenance manifest changed")
    data = json.loads(manifest.read_text())
    expected = data["upstream_sha256"] | data["patched_sha256"]
    expected_names = set(expected) | {MANIFEST, NOTES}
    observed = set()
    for path in root.rglob("*"):
        if path.is_symlink():
            raise ValueError("H1 source contains a symbolic link")
        if not path.is_file():
            continue
        name = path.relative_to(root).as_posix()
        observed.add(name)
        if name in expected and hashlib.sha256(path.read_bytes()).hexdigest() != expected[name]:
            raise ValueError(f"H1 source digest changed: {name}")
    if observed != expected_names:
        raise ValueError("H1 source inventory changed")


def controls(source: Path) -> None:
    mutations = [
        lambda root: (root / "lib/parse.ml").write_bytes(b"unreviewed parser\n"),
        lambda root: (root / "lib/h1.mli").write_bytes(b"unreviewed interface\n"),
        lambda root: (root / "lib/body.ml").unlink(),
        lambda root: (root / "unreviewed.ml").write_bytes(b"new source\n"),
        lambda root: (root / MANIFEST).write_bytes(b"{}\n"),
        lambda root: (root / "linked-source").symlink_to(source / "lib/parse.ml"),
    ]
    with tempfile.TemporaryDirectory(prefix="symphony-h1-custody-") as temporary:
        parent = Path(temporary)
        for index, mutate in enumerate(mutations):
            root = parent / str(index)
            shutil.copytree(source, root)
            mutate(root)
            try:
                verify(root)
            except (OSError, ValueError):
                continue
            raise ValueError(f"H1 corruption control accepted: {index}")
    print(f"H1 custody: {len(mutations)} corruption controls rejected")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    arguments = parser.parse_args()
    source = arguments.source.resolve()
    try:
        verify(source)
        controls(source)
    except (OSError, ValueError) as error:
        raise SystemExit(f"H1 custody: {error}") from error
    print("H1 custody: all upstream/patched files match frozen provenance")
