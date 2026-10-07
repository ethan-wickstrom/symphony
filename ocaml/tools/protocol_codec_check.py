"""Validate actual codec JSONL output against retained stable Codex schemas."""

import argparse
import copy
import hashlib
from importlib.metadata import version
import json
from pathlib import Path
import platform
import re
import sys

from symphony_conformance.assets import decode, load, resource
from symphony_conformance.schema import Schema, formats


PROTOCOL_VERSION = "0.159.2"
JSONSCHEMA_VERSION = "4.26.0"
DRAFT7 = "http://json-schema.org/draft-07/schema#"
MAX_LINE_BYTES = 1024 * 1024
FIXTURE_MANIFEST = Path(__file__).resolve().parents[1] / "protocol" / PROTOCOL_VERSION / "codec" / "manifest.json"
RECORD_KEYS = frozenset({"name", "schema", "value"})
EXPECTED_FIXTURES = 67
EXPECTED_CONTROLS = 42
NATIVE_WORD_BITS = 64
MAX_FIXTURE_BYTES = MAX_LINE_BYTES * EXPECTED_FIXTURES
STATUS_PASSED = "passed"
STATUS_FAILED = "failed"
CHECKER = Path(__file__).resolve()
REQUIREMENTS = CHECKER.parents[2] / "conformance" / "requirements.lock"
SCHEMA_RECORD_FORMAT = "sorted filename, NUL, raw-file SHA-256 hex, newline"
ARTIFACT_NAMES = {
    "fixtures": "fixtures.jsonl",
    "log": "validator.log",
    "receipt": "receipt.json",
    "manifest": "manifest.json",
}


class Rejected(ValueError):
    pass


def parse(raw):
    try:
        return decode(raw)
    except ValueError as error:
        raise Rejected(str(error)) from error


def identity(path):
    resolved = path.resolve()
    with resolved.open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
    return {"path": str(path), "resolved": str(resolved), "sha256": digest}


def evidence_paths(arguments):
    directory = arguments.evidence_dir.resolve()
    paths = {key: directory / name for key, name in ARTIFACT_NAMES.items()}
    protected = {CHECKER, REQUIREMENTS, arguments.exporter.resolve()}
    protected.add(FIXTURE_MANIFEST)
    protected.add(Path(str(resource("protocol/manifest.json"))).resolve())
    protected.update(Path(str(resource("protocol/schemas/" + name))).resolve()
                     for name in load("protocol/manifest.json")["files"])
    if arguments.fixtures != "-":
        protected.add(Path(arguments.fixtures).resolve())
    if any(path.resolve() in protected for path in paths.values()):
        raise Rejected("Evidence artifacts would overwrite a checker input")
    directory.mkdir(parents=True, exist_ok=True)
    # A failed rerun cannot leave an earlier success receipt or manifest.
    for key in ("manifest", "receipt", "fixtures", "log"):
        paths[key].unlink(missing_ok=True)
    return paths


def receipt(paths, status, message, counts=None):
    paths["log"].write_text(message + "\n", encoding="utf-8")
    value = {
        "status": status,
        "optimize": sys.flags.optimize,
        "message": message,
        "fixture_boundary": "Oversized rejected input retains a bounded prefix",
        "counts": counts,
        "artifacts": {
            key: identity(paths[key]) for key in ("fixtures", "log")
            if paths[key].is_file()
        },
    }
    paths["receipt"].write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")


def retain_fixtures(arguments, target):
    def copy(stream):
        size = 0
        with target.open("wb") as retained:
            while raw := stream.read(MAX_LINE_BYTES):
                remaining = MAX_FIXTURE_BYTES - size
                retained.write(raw[:remaining + 1])
                size += len(raw)
                if size > MAX_FIXTURE_BYTES:
                    raise Rejected("Codec fixture stream exceeded its byte bound")
    if arguments.fixtures == "-":
        copy(sys.stdin.buffer)
        return
    with Path(arguments.fixtures).open("rb") as stream:
        copy(stream)


def manifest(paths, arguments, consumed, counts, inputs):
    interpreter = identity(Path(sys.executable))
    interpreter.update({
        "version": platform.python_version(),
        "implementation": sys.implementation.name,
        "cache_tag": sys.implementation.cache_tag,
        "optimize": sys.flags.optimize,
        "isolated": sys.flags.isolated,
    })
    value = {
        "status": STATUS_PASSED,
        "counts": counts,
        "python": interpreter,
        **inputs,
        "schema": consumed,
        "fixture_input": arguments.fixtures,
        "artifacts": {
            key: identity(paths[key]) for key in ("fixtures", "log", "receipt")
        },
        "provenance": (
            "Identities record retained fixtures, checker, requirements lock, "
            "caller-supplied exporter binary, Python and consumed schemas; "
            "no source-to-binary or exporter-to-fixture attestation"
        ),
    }
    paths["manifest"].write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")


def schemas():
    manifest = parse(FIXTURE_MANIFEST.read_bytes())
    if not isinstance(manifest, dict):
        raise Rejected("Consumed schema manifest must be an object")
    if manifest.get("version") != "codex-cli " + PROTOCOL_VERSION:
        raise Rejected("Consumed schema manifest has the wrong Codex version")
    if manifest.get("profile") != "stable (no --experimental)":
        raise Rejected("Consumed schema manifest has the wrong protocol profile")
    if manifest.get("native_word_bits") != NATIVE_WORD_BITS:
        raise Rejected("Consumed schema manifest has the wrong native integer width")
    validator = manifest.get("validator")
    if not isinstance(validator, dict) or validator.get("version") != JSONSCHEMA_VERSION:
        raise Rejected("Consumed schema manifest has the wrong validator version")
    hashes = manifest.get("sha256")
    expected = manifest.get("fixtures")
    if not isinstance(hashes, dict) or not hashes or not isinstance(expected, dict) or not expected:
        raise Rejected("Consumed schema manifest lacks hashes or fixture inventory")
    if any(not isinstance(entry, dict) or not isinstance(entry.get("schema"), str)
           for entry in expected.values()):
        raise Rejected("Consumed schema manifest has an invalid fixture inventory")
    if set(hashes) != {entry["schema"] for entry in expected.values()}:
        raise Rejected("Consumed schema inventory disagrees with fixture inventory")
    if len(expected) != EXPECTED_FIXTURES:
        raise Rejected("Consumed schema manifest has the wrong fixture count")
    canonical = load("protocol/manifest.json")
    oracle = Schema()
    # Verify the entire generated corpus, including schemas unused by the OCaml codec.
    for name in canonical["files"]:
        oracle.validator(name)
    bundle_records = "".join(name + "\0" + canonical["files"][name] + "\n"
                             for name in sorted(canonical["files"]))
    if hashlib.sha256(bundle_records.encode()).hexdigest() != canonical["bundle_sha256"]:
        raise Rejected("Canonical protocol bundle aggregate mismatch")

    validators = {}
    for name, digest in hashes.items():
        if Path(name).name != name or not isinstance(digest, str) or not re.fullmatch(r"[0-9a-f]{64}", digest):
            raise Rejected("Consumed schema manifest has an invalid filename or digest")
        if canonical["files"].get(name) != digest:
            raise Rejected("Consumed schema hash mismatch: " + name)
        validator = oracle.validator(name)
        if validator.schema.get("$schema") != DRAFT7:
            raise Rejected("Consumed schema uses an unexpected draft: " + name)
        validators[name] = validator
    records = "".join(name + "\0" + hashes[name] + "\n" for name in sorted(hashes))
    consumed = {
        "directory": str(resource("protocol/schemas")),
        "manifest": identity(Path(str(resource("protocol/manifest.json")))),
        "fixture_manifest": identity(FIXTURE_MANIFEST),
        "files": hashes,
        "sha256": hashlib.sha256(records.encode("utf-8")).hexdigest(),
        "record_format": SCHEMA_RECORD_FORMAT,
        "bundle": canonical,
        "provenance": {
            key: manifest.get(key)
            for key in ("version", "profile", "generator", "source", "validator", "bundle")
        },
        "boundary": "All canonical generated schema bytes and their aggregate are verified; fixture expectations remain OCaml-specific",
    }
    return expected, validators, consumed


def fixtures(stream, expected, validators):
    observed = {}
    while raw := stream.readline(MAX_LINE_BYTES + 1):
        if len(raw) > MAX_LINE_BYTES:
            raise Rejected("Codec fixture exceeded its byte bound")
        record = parse(raw)
        if not isinstance(record, dict) or record.keys() != RECORD_KEYS:
            raise Rejected("Codec fixture has an invalid record shape")
        name, schema_name, value = record["name"], record["schema"], record["value"]
        if not isinstance(name, str) or not isinstance(schema_name, str) or not isinstance(value, dict):
            raise Rejected("Codec fixture has an invalid name, schema, or payload shape")
        if name not in expected or name in observed:
            raise Rejected("Codec fixture is unknown or duplicated")
        entry = expected[name]
        if schema_name != entry["schema"]:
            raise Rejected("Codec fixture has the wrong schema: " + name)
        if entry.get("method") is not None and value.get("method") != entry["method"]:
            raise Rejected("Codec fixture has the wrong method: " + name)
        identity = entry.get("id")
        if identity is not None:
            actual = value.get("id")
            if type(actual) is not type(identity) or actual != identity:
                raise Rejected("Codec fixture lost its exact wire identity: " + name)
        error = next(validators[schema_name].iter_errors(value), None)
        if error is not None:
            raise Rejected("Codec fixture does not match " + schema_name + ": " + name)
        observed[name] = record
    if observed.keys() != expected.keys():
        raise Rejected("Codec fixture inventory is incomplete")
    return observed


def controls(observed, validators, Draft7Validator, checker, bounds):
    count = 0
    for raw in (b'{"x":1,"x":2}', b'{"x":NaN}', b'{"x":Infinity}'):
        try:
            parse(raw)
        except Rejected:
            count += 1
            continue
        raise Rejected("Strict JSON parsing negative control passed")
    for name, (minimum, maximum) in bounds.items():
        validator = Draft7Validator({"type": ["integer", "null"], "format": name},
                                    format_checker=checker)
        if not all(validator.is_valid(value) for value in (minimum, maximum, None)):
            raise Rejected("Integer format rejected a valid boundary: " + name)
        for value in (minimum - 1, maximum + 1, True, 1.0):
            if validator.is_valid(value):
                raise Rejected("Integer format negative control passed: " + name)
            count += 1

    def rejected(name, change):
        nonlocal count
        record = observed[name]
        value = copy.deepcopy(record["value"])
        change(value)
        if validators[record["schema"]].is_valid(value):
            raise Rejected("Schema negative control passed: " + name)
        count += 1

    rejected("initialize", lambda value: value["params"]["clientInfo"].pop("version"))
    rejected("thread-start", lambda value: value["params"].update(cwd=0))
    rejected("turn-start", lambda value: value["params"].pop("threadId"))
    rejected("turn-start", lambda value: value["params"]["input"][0].update(type="inputText"))
    rejected("interrupt", lambda value: value["params"].update(turnId=0))
    rejected("command-result", lambda value: value.update(decision="approved"))
    rejected("legacy-exec-result", lambda value: value.update(decision="decline"))
    rejected("legacy-patch-result", lambda value: value.update(decision="decline"))
    rejected("tool-result", lambda value: value.pop("contentItems"))
    rejected("tool-result", lambda value: value["contentItems"][0].update(type="text"))
    rejected("permissions-result", lambda value: value.update(scope="forever"))
    rejected("elicitation-result", lambda value: value.update(action="cancelled"))
    rejected("initialize-id-max", lambda value: value.update(id=1 << 63))
    rejected("initialize-id-min", lambda value: value.update(id=-(1 << 63) - 1))
    rejected("command-id-max-envelope", lambda value: value.update(id=1 << 63))
    rejected("command-id-min-envelope", lambda value: value.update(id=-(1 << 63) - 1))
    rejected("auth-id-max", lambda value: value.update(id=1 << 63))
    rejected("initialize", lambda value: value.update(id=1.0))
    rejected("initialize", lambda value: value.update(id=True))
    return count


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("fixtures", help="Codec exporter JSONL file, or - for stdin")
    parser.add_argument("--evidence-dir", type=Path, required=True)
    parser.add_argument("--exporter", type=Path, required=True)
    arguments = parser.parse_args()
    paths = None
    try:
        if sys.version_info < (3, 11):
            raise Rejected("Protocol codec schema checking requires Python >=3.11")
        paths = evidence_paths(arguments)
        retain_fixtures(arguments, paths["fixtures"])
        from jsonschema import Draft7Validator

        if version("jsonschema") != JSONSCHEMA_VERSION:
            raise Rejected("Use the pinned protocol codec requirements environment")
        inputs = {
            "checker": identity(CHECKER),
            "requirements": identity(REQUIREMENTS),
            "exporter": identity(arguments.exporter),
        }
        checker, bounds = formats()
        expected, validators, consumed = schemas()
        with paths["fixtures"].open("rb") as stream:
            observed = fixtures(stream, expected, validators)
        negative_count = controls(observed, validators, Draft7Validator, checker, bounds)
        if negative_count != EXPECTED_CONTROLS:
            raise Rejected("Protocol codec schema check has the wrong negative-control count")
    except ModuleNotFoundError:
        message = "Install conformance/requirements.lock and the conformance package in an isolated environment."
        if paths is not None:
            receipt(paths, STATUS_FAILED, message)
        parser.exit(1, message + "\n")
    except (Rejected, OSError, ValueError, KeyError, TypeError) as error:
        message = "Protocol codec schema check: " + str(error)
        if paths is not None:
            receipt(paths, STATUS_FAILED, message)
        parser.exit(1, message + "\n")
    except BaseException as error:
        if paths is not None:
            receipt(paths, STATUS_FAILED,
                    "Protocol codec checker interrupted: " + type(error).__name__)
        raise
    message = (f"Protocol codec schema check: {len(observed)} actual fixtures, "
               f"{negative_count} negative controls, retained hashes match")
    counts = {"fixtures": len(observed), "negative_controls": negative_count}
    receipt(paths, STATUS_PASSED, message, counts)
    manifest(paths, arguments, consumed, counts, inputs)
    print(message)


if __name__ == "__main__":
    main()
