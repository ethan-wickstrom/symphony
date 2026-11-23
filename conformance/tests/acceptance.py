"""Installed-package acceptance, retaining every case and independent replay."""

import argparse
import json
import os
from pathlib import Path

from symphony_conformance.judge import judge
from symphony_conformance.runner import run

FAULTS = {
    "wrong-handshake": "protocol.startup",
    "new-thread": "turn.same_thread",
    "ack-only": "interrupt.completed",
    "missing-cleanup": "workspace.removed",
    "hook-before-closure": "hooks.order",
    "secret-leak": "secret.quarantined",
    "duplicate-dispatch": "peer.unique",
    "double-usage": "telemetry.absolute",
    "leaked-child": "shutdown.joined",
}


def require(value, message):
    if not value:
        raise RuntimeError(message)


def evaluate(root, profile, candidate=None, fault=None):
    bundle = run(root / "evidence", profile, candidate, fault)
    report = judge(bundle)
    (root / "report.json").write_text(json.dumps(report, indent=2) + "\n")
    replay = judge(bundle)
    require(replay == report, "Offline replay changed its result")
    require(report["harness"]["status"] == "pass", "Harness health failed: " + str(report["harness"]))
    require(report["core_summary"]["complete"] is False, "One case claimed complete core conformance")
    require(len(report["requirements"]) == 106 and len(report["supplemental_requirements"]) == 12,
            "Requirement rows disappeared")
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--candidate", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    root = args.out.absolute()
    root.mkdir(parents=True, exist_ok=False)
    candidate = args.candidate.resolve(strict=True)
    # Execute with no checkout cwd or import path; installed resources supply fixtures.
    os.chdir(root)
    good = evaluate(root / "scripted", "scripted")
    require(good["case"]["status"] == "pass", "Scripted calibration did not pass")
    native = evaluate(root / "ocaml", "ocaml", str(candidate))
    assertions = {row["id"]: row["status"] for row in native["case"]["assertions"]}
    require(assertions.get("telemetry.absolute") == "unobservable", "OCaml public telemetry boundary changed")
    require(all(status == "pass" for key, status in assertions.items() if key != "telemetry.absolute"),
            "OCaml lifecycle assertion failed: " + str(assertions))
    for fault, assertion in FAULTS.items():
        result = evaluate(root / fault, "scripted", fault=fault)
        failures = {row["id"] for row in result["case"]["assertions"] if row["status"] == "fail"}
        require(assertion in failures, "Fault missed its fixed assertion: " + fault + ": " + str(failures))
    print("Portable lifecycle: OCaml12/pass+usage/unobservable; scripted13/pass; nine calibrated faults; core incomplete")


if __name__ == "__main__":
    main()
