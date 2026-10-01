#!/usr/bin/env python3
"""Instantiate the qualified release inputs; never install or build them."""

import argparse
import gzip
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import stat
import subprocess
import sys
import tarfile


PROFILE = "macos-arm64-26.0.json"
TOKEN = re.compile(r"@([A-Z_]+)@")
SAFE_PATH = re.compile(r"/[A-Za-z0-9_./+\-]+")
GIT_TIMEOUT = 30
MAX_ARCHIVE = 4 * 1024 * 1024
MAX_PROFILE = 64 * 1024
MAX_TEMPLATE = 32 * 1024
RECIPES = frozenset([
    "compiler-pin/ocaml-compiler.opam", "compiler-pin/compiler-cloning.opam",
    "compiler-pin/ocaml-variants.opam", "compiler-pin/ocaml-option-no-compression.opam",
    "symphony-release.opam", "package-pins/conf-gmp.opam",
    "package-pins/conf-gmp-powm-sec.opam", "package-pins/zarith.opam",
    "package-pins/crowbar.opam", "package-pins/eio.opam",
    "package-pins/eio_posix.opam", "package-pins/h1.opam", "package-pins/yaml.opam",
])
VENDORS = {
    "yaml": "yaml-3.2.0.tar.gz", "crowbar": "crowbar-0.2.2.tar.gz",
    "eio": "eio-1.6.tar.gz", "h1": "h1-1.1.1.tar.gz",
}


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def require(condition, message):
    if not condition:
        raise ValueError(message)


def shape(condition, key, reason):
    require(condition, f"{PROFILE}: {key}: {reason}; restore the checked-in profile")


def field(value, key, kind, where):
    shape(type(value) is dict and key in value, f"{where}.{key}", "missing key")
    result = value[key]
    shape(type(result) is kind, f"{where}.{key}", f"expected {kind.__name__}")
    return result


def hex_field(value, key, length, where):
    result = field(value, key, str, where)
    shape(re.fullmatch(f"[0-9a-f]{{{length}}}", result) is not None, f"{where}.{key}", "invalid digest")


def check_profile(profile):
    """Validate every consumed field before paths, Git or publication are available."""
    shape(type(profile) is dict, "$", "expected object")
    shape(field(profile, "schema", int, "$") == 1, "schema", "unsupported version")
    bindings = field(profile, "bindings", dict, "$")
    shape(bindings == {"INPUTS": "inputs", "TARGET": "target"}, "bindings", "binding inventory mismatch")
    hex_field(profile, "source_commit", 40, "$")

    templates = field(profile, "templates", dict, "$")
    shape(set(templates) == RECIPES, "templates", "recipe inventory mismatch")
    for name, entry in templates.items():
        where = f"templates.{name}"
        shape(type(entry) is dict, where, "expected object")
        path = field(entry, "template", str, where)
        shape(path == f"templates/{name}.in", f"{where}.template", "unsafe template path")
        hex_field(entry, "sha256", 64, where)
        hex_field(entry, "qualified_sha256", 64, where)
        tokens = field(entry, "tokens", list, where)
        shape(all(type(token) is str for token in tokens), f"{where}.tokens", "expected string tokens")
        shape(set(tokens) <= set(bindings) and len(tokens) == len(set(tokens)), f"{where}.tokens", "invalid token inventory")

    vendors = field(profile, "vendors", list, "$")
    shape(len(vendors) == len(VENDORS), "vendors", "vendor inventory mismatch")
    names = set()
    for index, vendor in enumerate(vendors):
        where = f"vendors[{index}]"
        shape(type(vendor) is dict, where, "expected object")
        name = field(vendor, "name", str, where)
        shape(name in VENDORS and name not in names, f"{where}.name", "unknown or duplicate vendor")
        names.add(name)
        path = field(vendor, "archive", str, where)
        shape(path == VENDORS[name], f"{where}.archive", "unsafe archive path")
        hex_field(vendor, "tree", 40, where)
        hex_field(vendor, "sha256", 64, where)
        hex_field(vendor, "tar_sha256", 64, where)
        size = field(vendor, "tar_bytes", int, where)
        shape(0 < size <= MAX_ARCHIVE, f"{where}.tar_bytes", "invalid archive bound")
        count = field(vendor, "files", int, where)
        shape(0 < count <= MAX_ARCHIVE, f"{where}.files", "invalid file count")
    return profile


def read_bound(path, limit):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        require(stat.S_ISREG(os.fstat(fd).st_mode), f"{path.name}: expected regular file")
        with os.fdopen(fd, "rb", closefd=False) as source:
            data = source.read(limit + 1)
    finally:
        os.close(fd)
    require(len(data) <= limit, f"{path.name}: input exceeds {limit}-byte bound")
    return data


def git(repo, *args):
    return subprocess.run(
        ["git", *args], cwd=repo, check=True, capture_output=True,
        timeout=GIT_TIMEOUT,
    ).stdout


def output_path(value):
    path = Path(value)
    require(SAFE_PATH.fullmatch(value) is not None, "output needs an absolute safe path")
    require(str(path.resolve()) == value, "output path must be canonical")
    require(path.parent.is_dir(), "output parent directory must exist")
    require(not path.exists(), "output already exists; choose a fresh prefix")
    return path


def substitute(text, bindings):
    require(set(TOKEN.findall(text)) <= set(bindings), "unknown substitution token")
    return TOKEN.sub(lambda match: bindings[match.group(1)], text)


def archive(repo, vendor):
    """Normalize the same public Git archive format used by the qualification."""
    tree = vendor["tree"]
    require(re.fullmatch(r"[0-9a-f]{40}", tree) is not None, "invalid vendor tree ID")
    require(git(repo, "cat-file", "-t", tree).strip() == b"tree", "missing vendor tree")
    prefix = vendor["archive"].removesuffix(".tar.gz")
    raw = git(repo, "archive", "--format=tar", f"--prefix={prefix}/", tree)
    require(len(raw) <= MAX_ARCHIVE, f"{prefix}: archive exceeds bound")

    output = io.BytesIO()
    count = 0
    seen = set()
    with tarfile.open(fileobj=io.BytesIO(raw), mode="r:") as source:
        with tarfile.open(fileobj=output, mode="w", format=tarfile.PAX_FORMAT) as dest:
            for member in source:
                path = PurePosixPath(member.name)
                require(
                    not path.is_absolute() and ".." not in path.parts
                    and path.parts[0] == prefix and member.name not in seen,
                    f"{prefix}: unsafe or duplicate entry",
                )
                require(member.isfile() or member.isdir(), f"{prefix}: unsupported entry")
                seen.add(member.name)
                member.mtime = member.uid = member.gid = 0
                member.uname = member.gname = ""
                member.pax_headers = {}
                body = source.extractfile(member) if member.isfile() else None
                dest.addfile(member, body)
                count += int(member.isfile())

    normalized = output.getvalue()
    require(count == vendor["files"], f"{prefix}: file inventory mismatch")
    require(len(normalized) == vendor["tar_bytes"], f"{prefix}: tar size mismatch")
    require(sha256(normalized) == vendor["tar_sha256"], f"{prefix}: tar hash mismatch")

    compressed = io.BytesIO()
    with gzip.GzipFile(filename="", fileobj=compressed, mode="wb", mtime=0) as dest:
        dest.write(normalized)
    result = compressed.getvalue()
    require(sha256(result) == vendor["sha256"], f"{prefix}: gzip hash mismatch")
    return result


def prepare(release, output):
    profile_bytes = read_bound(release / PROFILE, MAX_PROFILE)
    try:
        decoded = json.loads(profile_bytes)
    except (json.JSONDecodeError, UnicodeDecodeError, RecursionError) as error:
        raise ValueError(f"{PROFILE}: invalid JSON; restore the checked-in profile") from error
    profile = check_profile(decoded)
    bindings = {name: str(output / path) for name, path in profile["bindings"].items()}
    files = {}
    recipe_hashes = {}

    for name, entry in profile["templates"].items():
        relative = PurePosixPath(name)
        require(not relative.is_absolute() and ".." not in relative.parts, "unsafe recipe path")
        template_path = release / entry["template"]
        require(template_path.resolve().is_relative_to(release.resolve()), f"{name}: template escaped release directory")
        template = read_bound(template_path, MAX_TEMPLATE)
        require(sha256(template) == entry["sha256"], f"{name}: template hash mismatch")
        text = template.decode("utf-8")
        require(set(TOKEN.findall(text)) == set(entry["tokens"]), f"{name}: token inventory mismatch")
        rendered = substitute(text, bindings).encode()
        files[f"inputs/{name}"] = rendered
        recipe_hashes[name] = sha256(rendered)

    repo = release.parent.parent
    vendor_hashes = {}
    for vendor in profile["vendors"]:
        # The immutable subtree, rather than the caller's worktree, supplies every byte.
        current = git(repo, "rev-parse", f"HEAD:vendor/{vendor['name']}")
        require(current.decode().strip() == vendor["tree"], "vendor HEAD/tree mismatch")
        data = archive(repo, vendor)
        name = f"inputs/vendor-archives/{vendor['archive']}"
        files[name] = data
        vendor_hashes[vendor["name"]] = sha256(data)

    resolved = substitute(profile_bytes.decode(), bindings).encode()
    files["profile.json"] = resolved
    receipt = {
        "profile_sha256": sha256(profile_bytes),
        "materializer_sha256": sha256(Path(__file__).read_bytes()),
        "source_commit": profile["source_commit"],
        "bindings": bindings,
        "recipes": recipe_hashes,
        "vendor_archives": vendor_hashes,
        "files": {name: sha256(data) for name, data in files.items()},
        "claims": "Exact input materialization only; no download, build, replay, or host test.",
    }
    files["materialization.json"] = (json.dumps(receipt, indent=2) + "\n").encode()
    return files


def materialize(output):
    release = Path(__file__).resolve().parent
    files = prepare(release, output)
    # Exclusive creation owns this prefix. All content checks happen before any write.
    output.mkdir()
    try:
        for name, data in files.items():
            path = output / name
            path.parent.mkdir(parents=True, exist_ok=True)
            with path.open("xb") as handle:
                handle.write(data)
    except BaseException:
        try:
            shutil.rmtree(output)
        except BaseException:
            try:
                print("release prefix cleanup failed; primary failure preserved", file=sys.stderr)
            except BaseException:
                pass
        raise


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, help="absent, canonical absolute output prefix")
    args = parser.parse_args()
    try:
        output = output_path(args.output)
        materialize(output)
    except (OSError, ValueError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        print(f"release materialization failed: {error}", file=sys.stderr)
        return 2
    print(output / "materialization.json")
    return 0


if __name__ == "__main__":
    sys.exit(main())
