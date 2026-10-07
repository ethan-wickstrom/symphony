"""Installed executor and independent offline replay entry points."""

import argparse
import json
from pathlib import Path

from .control import Fault
from .judge import judge
from .runner import run


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    execute = commands.add_parser("run", help="Run the fixed portable lifecycle corpus")
    execute.add_argument("--profile", choices=("ocaml", "scripted"), required=True)
    execute.add_argument("--candidate", help="Public CLI binary for the OCaml profile")
    execute.add_argument("--output", type=Path, required=True, help="New evidence directory")
    execute.add_argument("--fault", choices=tuple(fault.value for fault in Fault),
                         help="Scripted calibration fault")
    replay = commands.add_parser("judge", help="Replay sealed evidence without executing a candidate")
    replay.add_argument("bundle", type=Path)
    replay.add_argument("--report", type=Path, required=True, help="Report outside immutable evidence")
    args = parser.parse_args()
    if args.command == "run":
        if args.profile == "ocaml" and not args.candidate:
            parser.error("--candidate is required for the OCaml profile")
        if args.fault is not None and args.profile != "scripted":
            parser.error("--fault requires --profile scripted")
        bundle = run(args.output, args.profile, args.candidate, args.fault)
        print(str(bundle))
        return
    if args.bundle.resolve() == args.report.resolve() or args.bundle.resolve() in args.report.resolve().parents:
        parser.error("--report must be outside the evidence directory")
    result = judge(args.bundle)
    args.report.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({"case": result["case"]["status"], "harness": result["harness"]["status"],
                      "core_complete": result["core_summary"]["complete"]}))


if __name__ == "__main__":
    main()
