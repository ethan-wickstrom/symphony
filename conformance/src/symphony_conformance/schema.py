"""Validate both JSONL directions against the pinned generated schemas."""

import hashlib
import sys

from jsonschema import Draft7Validator, FormatChecker

from .assets import decode, load, resource

RESULTS = {
    "initialize": "v1/InitializeResponse.json",
    "thread/start": "v2/ThreadStartResponse.json",
    "thread/name/set": "v2/ThreadSetNameResponse.json",
    "turn/start": "v2/TurnStartResponse.json",
    "turn/interrupt": "v2/TurnInterruptResponse.json",
}
INTEGER_FORMATS = {"int32": (-(2**31), 2**31 - 1), "int64": (-(2**63), 2**63 - 1),
                   "uint": (0, 2**64 - 1),
                   "uint16": (0, 2**16 - 1), "uint32": (0, 2**32 - 1),
                   "uint64": (0, 2**64 - 1)}
DOUBLE_MAX = sys.float_info.max


def formats():
    """Use one numeric-format policy for wire and codec validation."""
    checker = FormatChecker()
    for name, (lower, upper) in INTEGER_FORMATS.items():
        def check(value, lower=lower, upper=upper):
            # The schema type decides whether a generated nullable field permits null.
            return value is None or type(value) is int and lower <= value <= upper

        checker.checks(name)(check)

    @checker.checks("double")
    def check_double(value):
        # Direct comparison avoids converting oversized JSON integers to floats.
        return value is None or type(value) in (int, float) and -DOUBLE_MAX <= value <= DOUBLE_MAX

    return checker, dict(INTEGER_FORMATS)


class Schema:
    def __init__(self):
        self._validators = {}
        self._manifest = load("protocol/manifest.json")
        self._formats, _ = formats()

    def _validator(self, name):
        if name in self._validators:
            return self._validators[name]
        expected = self._manifest["files"].get(name)
        if expected is None:
            raise ValueError("Schema is outside the pinned inventory: " + name)
        raw = resource("protocol/schemas/" + name).read_bytes()
        if hashlib.sha256(raw).hexdigest() != expected:
            raise ValueError("Schema digest mismatch: " + name)
        schema = decode(raw)
        pending = [schema]
        while pending:
            item = pending.pop()
            if isinstance(item, dict):
                format_name = item.get("format")
                if isinstance(format_name, str) and format_name not in self._formats.checkers:
                    raise ValueError("Unsupported schema format: " + format_name)
                ref = item.get("$ref")
                if ref is not None and (not isinstance(ref, str) or not ref.startswith("#")):
                    raise ValueError("Offline schemas cannot reference external resources")
                pending.extend(item.values())
            elif isinstance(item, list):
                pending.extend(item)
        Draft7Validator.check_schema(schema)
        validator = Draft7Validator(schema, format_checker=self._formats)
        self._validators[name] = validator
        return validator

    def validator(self, name):
        """Return a validator from the immutable generated schema inventory."""
        return self._validator(name)

    def validate(self, frame, direction, method=None):
        if type(frame) is not dict or direction not in ("client", "server"):
            raise ValueError("Invalid frame direction or envelope")
        if "method" in frame:
            prefix = "Client" if direction == "client" else "Server"
            kind = "Request" if "id" in frame else "Notification"
            self._validator(prefix + kind + ".json").validate(frame)
            return
        envelope = "JSONRPCError.json" if "error" in frame else "JSONRPCResponse.json"
        self._validator(envelope).validate(frame)
        if direction == "server" and "result" in frame:
            if method not in RESULTS:
                raise ValueError("No selected response schema for method: " + str(method))
            self._validator(RESULTS[method]).validate(frame["result"])
