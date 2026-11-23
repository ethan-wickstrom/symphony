"""Read fixed package data without repository-relative paths."""

import hashlib
import json
import math
from importlib.resources import files

MAX_JSON_DEPTH = 128


def encode(value):
    return json.dumps(value, separators=(",", ":"), allow_nan=False).encode() + b"\n"


def pairs(values):
    result = {}
    for key, value in values:
        if key in result:
            raise ValueError("Duplicate JSON field: " + key)
        result[key] = value
    return result


def decode(raw):
    def invalid(value):
        raise ValueError("Nonfinite JSON number: " + value)

    def finite(value):
        number = float(value)
        if not math.isfinite(number):
            invalid(value)
        return number

    try:
        result = json.loads(raw, object_pairs_hook=pairs, parse_constant=invalid,
                            parse_float=finite)
    except RecursionError as error:
        raise ValueError("JSON nesting exceeds decoder capacity") from error

    # Bound nesting before later validators or encoders traverse this value.
    pending = [(iter((result,)), 0)]
    while pending:
        values, depth = pending[-1]
        try:
            value = next(values)
        except StopIteration:
            pending.pop()
            continue
        if not isinstance(value, (dict, list)):
            continue
        if depth >= MAX_JSON_DEPTH:
            raise ValueError("JSON nesting budget exceeded")
        children = value.values() if isinstance(value, dict) else value
        pending.append((iter(children), depth + 1))
    return result


def resource(name):
    if name.startswith("/") or ".." in name.split("/"):
        raise ValueError("Invalid package resource")
    return files("symphony_conformance").joinpath("assets", *name.split("/"))


def load(name):
    return decode(resource(name).read_bytes())


def digest(name):
    return hashlib.sha256(resource(name).read_bytes()).hexdigest()
