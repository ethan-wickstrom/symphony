import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

from jsonschema import Draft7Validator, ValidationError

from symphony_conformance import schema as schema_module
from symphony_conformance.assets import decode, load, resource
from symphony_conformance.schema import Schema, formats

INTEGER_BOUNDS = {
    "int32": (-(2**31), 2**31 - 1),
    "int64": (-(2**63), 2**63 - 1),
    "uint": (0, 2**64 - 1),
    "uint16": (0, 2**16 - 1),
    "uint32": (0, 2**32 - 1),
    "uint64": (0, 2**64 - 1),
}
DOUBLE_MAX = sys.float_info.max
UNKNOWN_FORMAT = "int128"


class SchemaTest(unittest.TestCase):
    def test_process_exit_code(self):
        validator = Schema()
        lower, upper = INTEGER_BOUNDS["int32"]
        params = {"processHandle": "fixture", "stderr": "", "stdout": "",
                  "stderrCapReached": False, "stdoutCapReached": False}
        for value in (lower, 0, upper):
            with self.subTest(value=value):
                validator.validate({"method": "process/exited", "params": {**params, "exitCode": value}}, "server")
        for value in (lower - 1, upper + 1, 2**40, -(2**40), True, False, 0.0, "0", None):
            with self.subTest(value=value):
                with self.assertRaises(ValidationError):
                    validator.validate({"method": "process/exited", "params": {**params, "exitCode": value}}, "server")

    def test_integer_formats(self):
        checker, _ = formats()
        for name, (lower, upper) in INTEGER_BOUNDS.items():
            validator = Draft7Validator({"type": ["integer", "null"], "format": name}, format_checker=checker)
            for value in (None, lower, 0, upper):
                with self.subTest(format=name, accepted=value):
                    validator.validate(value)
            for value in (lower - 1, upper + 1, True, False, 0.0, "0", [], {}):
                with self.subTest(format=name, rejected=value):
                    with self.assertRaises(ValidationError):
                        validator.validate(value)

    def test_double_format(self):
        checker, _ = formats()
        validator = Draft7Validator({"type": ["number", "null"], "format": "double"}, format_checker=checker)
        for value in (None, -DOUBLE_MAX, DOUBLE_MAX, 0, 1, 0.25):
            with self.subTest(accepted=value):
                validator.validate(value)
        for value in (True, False, "0", [], {}, float("inf"), -float("inf"), float("nan"), 2**1024, -(2**1024)):
            with self.subTest(rejected=value):
                with self.assertRaises(ValidationError):
                    validator.validate(value)

    def test_pinned_formats(self):
        manifest = load("protocol/manifest.json")
        pending = [decode(resource("protocol/schemas/" + name).read_bytes()) for name in manifest["files"]]
        declared = set()
        while pending:
            item = pending.pop()
            if isinstance(item, dict):
                if isinstance(item.get("format"), str):
                    declared.add(item["format"])
                pending.extend(item.values())
            elif isinstance(item, list):
                pending.extend(item)
        self.assertEqual(declared, set(INTEGER_BOUNDS) | {"double"})
        checker, _ = formats()
        self.assertTrue(declared <= checker.checkers.keys(),
                        "Pinned formats lack validators: " + repr(sorted(declared - checker.checkers.keys())))

    def test_unknown_format(self):
        # A future generated format must fail admission despite a valid asset digest.
        raw = json.dumps({"type": "integer", "format": UNKNOWN_FORMAT}).encode()
        manifest = {"files": {"Future.json": hashlib.sha256(raw).hexdigest()}}
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "Future.json"
            path.write_bytes(raw)
            with patch.object(schema_module, "load", return_value=manifest), patch.object(schema_module, "resource", return_value=path):
                with self.assertRaisesRegex(ValueError, UNKNOWN_FORMAT):
                    Schema().validator("Future.json")

    def test_nullable_integer(self):
        count = {"inputTokens": 0, "outputTokens": 0, "totalTokens": 0,
                 "cachedInputTokens": 0, "reasoningOutputTokens": 0}
        frame = {"method": "thread/tokenUsage/updated", "params": {
            "threadId": "fixture", "turnId": "turn", "tokenUsage": {
                "total": count, "last": count, "modelContextWindow": None}}}
        Schema().validate(frame, "server")


if __name__ == "__main__":
    unittest.main()
