"""Bounded AFL file harness for Mach-O parsing; never execute the candidate."""

import argparse
import importlib.util
import os
from pathlib import Path
import sys


MAX_INPUT = 65536
CHECKER = Path(__file__).resolve().parents[1] / "tools/check_release.py"

# Keep fuzz runs from writing bytecode beside the checked source.
sys.dont_write_bytecode = True
SPEC = importlib.util.spec_from_file_location("release_macho_checker", CHECKER)
GATE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GATE)


def check(data):
    try:
        GATE.parse_macho(data)
    except GATE.Rejected:
        return
    except Exception as error:
        print(f"Unexpected parser exception: {type(error).__name__}", file=sys.stderr, flush=True)
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
