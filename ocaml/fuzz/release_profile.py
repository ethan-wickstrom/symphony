"""Bounded AFL file harness for profile parsing; never prepare or publish inputs."""

import argparse
import importlib.util
import os
from pathlib import Path
import sys


MAX_INPUT = 64 * 1024
VALIDATOR = Path(__file__).resolve().parents[1] / "release/materialize.py"

# Keep fuzz runs from writing bytecode beside the checked source.
sys.dont_write_bytecode = True
SPEC = importlib.util.spec_from_file_location("release_profile_validator", VALIDATOR)
GATE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GATE)


def check(data):
    try:
        try:
            value = GATE.decode_profile(data)
        except ValueError as error:
            if str(error).startswith(f"{GATE.PROFILE}: "):
                return
            raise

        try:
            GATE.check_profile(value)
        except ValueError as error:
            if str(error).startswith(f"{GATE.PROFILE}: "):
                return
            raise
    except Exception as error:
        print(f"Unexpected profile exception: {type(error).__name__}", file=sys.stderr, flush=True)
        os.abort()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path)
    arguments = parser.parse_args()
    with arguments.input.open("rb") as input_file:
        data = input_file.read(MAX_INPUT + 1)
    if len(data) > MAX_INPUT:
        parser.error(f"input exceeds the {MAX_INPUT}-byte fuzz bound")
    check(data)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
