#!/usr/bin/env python3
"""Instantiate the qualified release inputs; never install or build them."""

import argparse
from datetime import date
import gzip
import hashlib
import importlib.util
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
HISTORICAL_PURPOSE = "historical-replay"
ARCHIVAL_NOTICE = (
    "Security-affected Mirage Crypto 1.2.0 archival inputs; "
    "not current release qualification."
)
TOKEN = re.compile(r"@([A-Z_]+)@")
SAFE_PATH = re.compile(r"/[A-Za-z0-9_./+\-]+")
GIT_TIMEOUT = 30
MAX_ARCHIVE = 4 * 1024 * 1024
MAX_PROFILE = 64 * 1024
MAX_TEMPLATE = 32 * 1024
MAX_GIT_STDERR = 64 * 1024
CPU_BASELINE = "Apple M1; GMP and pkgconf use generic Armv8-A"
GENERIC_CPU = "generic Armv8-A"
_PROCESS_PATH = Path(__file__).resolve().parent.parent / "tools/bounded_process.py"
_PROCESS_SPEC = importlib.util.spec_from_file_location("release_bounded_process", _PROCESS_PATH)
_PROCESS = importlib.util.module_from_spec(_PROCESS_SPEC)
_PROCESS_SPEC.loader.exec_module(_PROCESS)
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
PROFILE_FIELDS = frozenset([
    "schema", "name", "qualification_date", "target", "source_commit", "bindings",
    "sources", "operations", "templates", "vendors", "boundaries",
])
TARGET_FIELDS = frozenset([
    "os", "arch", "minimum_os", "sdk_version", "sdk_build", "cpu_baseline",
    "xcode_version", "xcode_build", "clang_version", "clang_sha256", "sdk", "toolchain",
])
SOURCE_FIELDS = {
    "opam": {"url", "sha256", "path"},
    "ocaml": {"url", "sha256", "via"},
    "gmp": {"url", "sha256", "path", "signature_url", "signature_sha256", "historical_signer"},
    "pkgconf": {"url", "sha256", "path", "digest_authority"},
    "pkgconf_recipe": {"url", "sha256", "git_blob", "path"},
    "zarith": {"url", "sha256", "via"},
    "conf_gmp_probe": {"url", "sha256", "via"},
    "conf_powm_probe": {"url", "sha256", "via"},
}
OPERATION_FIELDS = {
    "gmp": {"abi", "cpu_baseline", "build_directory", "prefix", "configure_argv",
            "environment", "make_argv", "check_argv", "install_argv"},
    "pkgconf": {"cpu_baseline", "source", "build_directory", "prefix", "environment",
                "header_argv", "build_argv", "check_argv", "build_note", "install", "install_note"},
    "compiler_install": {"argv", "env"},
    "dependencies_install": {"argv", "env"},
}
ENVIRONMENT_FIELDS = {
    "gmp": {"PATH", "CC", "CFLAGS", "CPPFLAGS", "LDFLAGS", "LIBS", "AR", "RANLIB",
            "NM", "STRIP", "M4", "CC_FOR_BUILD", "SDKROOT", "MACOSX_DEPLOYMENT_TARGET",
            "DEVELOPER_DIR", "LANG", "LC_ALL", "TMPDIR", "ZERO_AR_DATE", "ABI"},
    "pkgconf": {"PATH", "CC", "CFLAGS", "CPPFLAGS", "LDFLAGS", "LIBS", "STRIP",
                "SDKROOT", "MACOSX_DEPLOYMENT_TARGET", "DEVELOPER_DIR", "LANG", "LC_ALL",
                "TMPDIR", "ZERO_AR_DATE"},
    "compiler_install": {"LANG", "PATH", "MACOSX_DEPLOYMENT_TARGET", "SDKROOT"},
    "dependencies_install": {"LANG", "PATH", "CC", "MACOSX_DEPLOYMENT_TARGET",
                             "SDKROOT", "PKG_CONFIG_LIBDIR", "PKG_CONFIG_PATH", "PKG_CONFIG"},
}
PKGCONF_INSTALL = [
    {"operation": "mkdir", "path": "@TARGET@/tools/bin"},
    {"operation": "copyfile", "source": "@TARGET@/pkgconf-build/pkgconf",
     "destination": "@TARGET@/tools/bin/pkgconf"},
    {"operation": "chmod", "path": "@TARGET@/tools/bin/pkgconf", "mode": "0755"},
    {"operation": "symlink", "path": "@TARGET@/tools/bin/pkg-config", "target": "pkgconf"},
]


class _DuplicateKey(ValueError):
    pass


def _unique_pairs(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise _DuplicateKey(key)
        result[key] = value
    return result


def decode_profile(data):
    """Decode bounded UTF-8 JSON, rejecting duplicate keys at every depth.

    Expected JSON failures are named ValueError failures. Validation is a
    separate operation, so its defects never become decoder rejections.
    """
    shape(type(data) is bytes, "JSON", "expected UTF-8 bytes")
    shape(len(data) <= MAX_PROFILE, "JSON", "profile exceeds byte bound")
    try:
        return json.loads(data.decode("utf-8"), object_pairs_hook=_unique_pairs)
    except _DuplicateKey as error:
        raise ValueError(f"{PROFILE}: JSON: duplicate key {error.args[0]!r}; restore the checked-in profile") from error
    except (ValueError, RecursionError) as error:
        raise ValueError(f"{PROFILE}: invalid JSON; restore the checked-in profile") from error


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


def inventory(value, keys, where):
    shape(type(value) is dict, where, "expected object")
    shape(set(value) == set(keys), where, "field inventory mismatch")


def checked_text(value, where):
    shape(type(value) is str, where, "expected string")
    shape("\0" not in value, where, "NUL is forbidden")
    try:
        value.encode("utf-8")
    except UnicodeEncodeError:
        shape(False, where, "expected UTF-8 text")
    shape(set(TOKEN.findall(value)) <= {"INPUTS", "TARGET"}, where, "unknown binding token")
    shape("@" not in TOKEN.sub("", value), where, "invalid binding token")
    return value


def text_field(value, key, where):
    text = checked_text(field(value, key, str, where), f"{where}.{key}")
    shape(bool(text), f"{where}.{key}", "expected nonempty string")
    return text


def checked_path(value, where):
    text = checked_text(value, where)
    resolved = text.replace("@INPUTS@", "/inputs").replace("@TARGET@", "/target")
    path = PurePosixPath(resolved)
    shape(SAFE_PATH.fullmatch(resolved) is not None and ".." not in path.parts
          and str(path) == resolved, where, "expected canonical absolute path")


def checked_argv(value, where):
    shape(type(value) is list and bool(value), where, "expected nonempty argument array")
    for index, item in enumerate(value):
        text = checked_text(item, f"{where}[{index}]")
        shape(bool(text), f"{where}[{index}]", "empty argument")
    checked_path(value[0], f"{where}[0]")


def check_metadata(profile):
    shape(text_field(profile, "name", "$") == PROFILE.removesuffix(".json"), "name", "wrong profile")
    when = text_field(profile, "qualification_date", "$")
    try:
        valid_date = date.fromisoformat(when).isoformat() == when
    except ValueError:
        valid_date = False
    shape(valid_date, "qualification_date", "expected ISO calendar date")

    target = field(profile, "target", dict, "$")
    inventory(target, TARGET_FIELDS, "target")
    for key in TARGET_FIELDS:
        text_field(target, key, "target")
    for key, expected in {"os": "macos", "arch": "arm64", "minimum_os": "26.0", "sdk_version": "26.5"}.items():
        shape(target[key] == expected, f"target.{key}", "wrong selected target")
    shape(target["cpu_baseline"] == CPU_BASELINE, "target.cpu_baseline", "wrong selected CPU baseline")
    hex_field(target, "clang_sha256", 64, "target")
    for key in ["sdk", "toolchain"]:
        checked_path(target[key], f"target.{key}")

    sources = field(profile, "sources", dict, "$")
    inventory(sources, SOURCE_FIELDS, "sources")
    for name, keys in SOURCE_FIELDS.items():
        source = field(sources, name, dict, "sources")
        where = f"sources.{name}"
        inventory(source, keys, where)
        for key in keys:
            text = text_field(source, key, where)
            if key.endswith("sha256"):
                hex_field(source, key, 64, where)
            elif key in {"url", "signature_url", "digest_authority"}:
                shape(re.fullmatch(r"https://[A-Za-z0-9.-]+/[A-Za-z0-9_./+%\-]+", text) is not None,
                      f"{where}.{key}", "expected absolute HTTPS source URL")
            elif key == "path":
                checked_path(text, f"{where}.{key}")
            elif key == "via":
                shape(text in RECIPES, f"{where}.{key}", "unknown package recipe")
            elif key == "git_blob":
                hex_field(source, key, 40, where)
            elif key == "historical_signer":
                shape(re.fullmatch(r"[0-9A-F]{40}", text) is not None, f"{where}.{key}", "invalid signer fingerprint")

    operations = field(profile, "operations", dict, "$")
    inventory(operations, OPERATION_FIELDS, "operations")
    for name, keys in OPERATION_FIELDS.items():
        operation = field(operations, name, dict, "operations")
        where = f"operations.{name}"
        inventory(operation, keys, where)
        if name in {"gmp", "pkgconf"}:
            shape(operation["cpu_baseline"] == GENERIC_CPU, f"{where}.cpu_baseline", "wrong selected CPU baseline")
        if name == "gmp":
            shape(operation["abi"] == "64", f"{where}.abi", "expected 64-bit GMP ABI")
        for key in keys:
            item = operation[key]
            location = f"{where}.{key}"
            if key == "argv" or key.endswith("_argv"):
                checked_argv(item, location)
            elif key in {"env", "environment"}:
                inventory(item, ENVIRONMENT_FIELDS[name], location)
                for variable, text in item.items():
                    checked_text(text, f"{location}.{variable}")
            elif key == "install":
                shape(type(item) is list and item == PKGCONF_INSTALL, location, "pkgconf installation inventory mismatch")
            else:
                text_field(operation, key, where)
                if key in {"source", "build_directory", "prefix"}:
                    checked_path(item, location)

    boundaries = field(profile, "boundaries", list, "$")
    shape(bool(boundaries), "boundaries", "expected nonempty claim boundaries")
    for index, boundary in enumerate(boundaries):
        where = f"boundaries[{index}]"
        shape(bool(checked_text(boundary, where)), where, "empty claim boundary")


def check_profile(profile):
    """Validate all published fields before paths, Git or publication are available."""
    shape(type(profile) is dict, "$", "expected object")
    inventory(profile, PROFILE_FIELDS, "$")
    shape(field(profile, "schema", int, "$") == 1, "schema", "unsupported version")
    check_metadata(profile)
    bindings = field(profile, "bindings", dict, "$")
    shape(bindings == {"INPUTS": "inputs", "TARGET": "target"}, "bindings", "binding inventory mismatch")
    hex_field(profile, "source_commit", 40, "$")

    templates = field(profile, "templates", dict, "$")
    shape(set(templates) == RECIPES, "templates", "recipe inventory mismatch")
    for name, entry in templates.items():
        where = f"templates.{name}"
        shape(type(entry) is dict, where, "expected object")
        inventory(entry, {"template", "sha256", "qualified_sha256", "tokens"}, where)
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
        inventory(vendor, {"name", "archive", "tree", "sha256", "tar_sha256", "tar_bytes", "files"}, where)
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
    result = _PROCESS.run(
        ["git", *args], cwd=repo, timeout=GIT_TIMEOUT,
        stdout_limit=MAX_ARCHIVE, stderr_limit=MAX_GIT_STDERR,
    )
    result.check_returncode()
    return result.stdout


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
    decoded = decode_profile(profile_bytes)
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

    # Only the checked value is published; JSON escaping cannot hide binding tokens.
    resolved = substitute(json.dumps(profile, indent=2) + "\n", bindings).encode()
    files["profile.json"] = resolved
    receipt = {
        "purpose": HISTORICAL_PURPOSE,
        "security_notice": ARCHIVAL_NOTICE,
        "profile_sha256": sha256(profile_bytes),
        "materializer_sha256": sha256(Path(__file__).read_bytes()),
        "bounded_process_sha256": sha256(_PROCESS_PATH.read_bytes()),
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
    parser = argparse.ArgumentParser(
        description=ARCHIVAL_NOTICE, formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--purpose", required=True, choices=[HISTORICAL_PURPOSE],
                        help="explicit intent to reproduce historical inputs")
    parser.add_argument("--output", required=True, help="absent, canonical absolute output prefix")
    args = parser.parse_args()
    try:
        output = output_path(args.output)
        materialize(output)
    except (OSError, ValueError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        print(f"release materialization failed: {error}", file=sys.stderr)
        for note in _PROCESS.cleanup_notes(error):
            print(note, file=sys.stderr)
        return 2
    print(ARCHIVAL_NOTICE)
    print(output / "materialization.json")
    return 0


if __name__ == "__main__":
    sys.exit(main())
