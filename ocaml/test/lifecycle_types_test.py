"""Compile public clients; lifecycle phases and Service brands stay distinct."""

import argparse
import hashlib
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


BUILD_ROOT = Path(__file__).resolve().parents[1] / "_build/default"
WARNINGS = "+a"
COMPILER_TIMEOUT_S = 15
LIBRARIES = (
    ("domain", "symphony_domain"),
    ("io", "symphony_io"),
    ("workflow", "symphony_workflow"),
    ("workspace", "symphony_workspace"),
    ("orchestration", "symphony_orchestration"),
    ("service", "symphony_service"),
)
PREFIX = "module L = Lifecycle_fixture.Lifecycle\nlet () = ignore ("

VALID = """module F = Lifecycle_fixture
module L = Issue_lifecycle.Make
  (Tracker_registry.Contract) (Clock.Pure) (F.Workspace) (F.Agent) (F.Plan)
let () = ignore (fun (x : L.starting L.run) -> L.activate x)
let () = ignore (fun (x : L.waiting L.retry) -> L.refresh x)
let () = ignore (fun (x : L.refreshing L.retry) -> L.settled x)
let () = ignore (fun (x : L.refreshed L.retry) -> L.park x)
let () = ignore (fun (x : L.parked L.retry) -> L.reread x)
let () = ignore (fun (x : L.retryable L.finished) token due ->
  L.retry x ~retry_id:token ~due)
let () = ignore (fun (x : L.cleanable L.finished) request_id ->
  L.clean_run x ~request_id)
let () = ignore (fun (x : L.releasable L.finished) -> L.release_run x)
"""

# These clients are deliberately ill-typed, not runtime transition tests.
INVALID = (
    ("activate_active", "fun (x : L.active L.run) -> L.activate x", ("active", "starting")),
    ("stop_active_as_starting", "fun (x : L.active L.run) -> L.stop_starting x", ("active", "starting")),
    ("finish_starting_as_active", "fun (x : L.starting L.run) -> L.finish_active x", ("starting", "active")),
    ("retry_cleanup", "fun (x : L.cleanable L.finished) -> L.retry x", ("cleanable", "retryable")),
    ("retry_release", "fun (x : L.releasable L.finished) -> L.retry x", ("releasable", "retryable")),
    ("cleanup_retry", "fun (x : L.retryable L.finished) -> L.clean_run x", ("retryable", "cleanable")),
    ("release_retry", "fun (x : L.retryable L.finished) -> L.release_run x", ("retryable", "releasable")),
    ("resume_waiting", "fun (x : L.waiting L.retry) -> L.resume x", ("waiting", "refreshed")),
    ("due_refreshing", "fun (x : L.refreshing L.retry) -> L.due x", ("refreshing", "waiting")),
    ("due_parked", "fun (x : L.parked L.retry) -> L.due x", ("parked", "waiting")),
    ("refresh_parked", "fun (x : L.parked L.retry) -> L.refresh x", ("parked", "waiting")),
    ("settle_waiting", "fun (x : L.waiting L.retry) -> L.settled x", ("waiting", "refreshing")),
    ("park_refreshing", "fun (x : L.refreshing L.retry) -> L.park x", ("refreshing", "refreshed")),
    ("own_released", "fun (x : L.released) -> L.Starting x", ("released", "starting")),
)

SERVICE_VALID = """module F = Lifecycle_fixture
module Check
    (C : Clock.S)
    (W : Workspace_manager.S)
    (A : Service.CLOSED_RUNNER
      with module Issue = Tracker_registry.Contract.Issue
       and module Path = W.Contract.Path
       and type workspace = W.Contract.reference
       and type clock = C.t
       and type workspace_manager = W.t)
    (B : Agent_runner.PURE
      with module Issue = Tracker_registry.Contract.Issue
       and module Path = W.Contract.Path
       and type workspace = W.Contract.reference
       and type request = A.request)
    (Load : Service.WORKFLOW_LOAD with type config = F.Config.t) = struct
  module Host = Service.Make (Tracker_registry) (C) (W) (A) (F.Config) (Load)
  let () = ignore (fun (x : B.request) -> (x : Host.Core.agent_request))
end
module _ = Check
"""

# Each client changes one intentional equality in the valid Service assembly.
SERVICE_INVALID = (
    (
        "service_clock",
        SERVICE_VALID.replace("and type clock = C.t", "and type clock = unit"),
        ("clock", "unit", "C.t"),
    ),
    (
        "service_workspace",
        SERVICE_VALID.replace(
            "and type workspace_manager = W.t", "and type workspace_manager = unit"
        ),
        ("workspace_manager", "unit", "W.t"),
    ),
    (
        "service_request",
        SERVICE_VALID.replace("\n       and type request = A.request", ""),
        ("B.request", "A.request"),
    ),
)


def fingerprints(paths):
    return {str(path): hashlib.sha256(path.read_bytes()).hexdigest() for path in paths}


class LifecycleTypes(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        directories = [
            BUILD_ROOT / f"lib/{area}/.{library}.objs/byte"
            for area, library in LIBRARIES
        ]
        cls.inputs = [path for directory in directories for path in directory.glob("*.cmi")]
        cls.inputs.append(
            BUILD_ROOT / "test/.scheduling_test_support.objs/byte/lifecycle_fixture.cmi"
        )
        missing = [str(path) for path in directories if not path.is_dir()]
        missing.extend(str(path) for path in cls.inputs if not path.is_file())
        if missing:
            raise RuntimeError(f"Run dune build @all first; missing public CMIs: {missing}")

        cls.before = fingerprints(cls.inputs)
        cls.scratch = tempfile.TemporaryDirectory(prefix="symphony-lifecycle-types-")
        cls.root = Path(cls.scratch.name)
        cls.imports = cls.root / "imports"
        cls.imports.mkdir()
        for path in cls.inputs:
            target = cls.imports / path.name
            if target.exists():
                raise RuntimeError(f"Ambiguous module CMI: {path.name}")
            shutil.copyfile(path, target)

    @classmethod
    def tearDownClass(cls):
        try:
            if cls.before != fingerprints(cls.inputs):
                raise RuntimeError("Compiled library CMIs changed during compile-only checks")
            print(f"Unchanged compile inputs: {len(cls.inputs)} CMIs", flush=True)
        finally:
            cls.scratch.cleanup()

    def compile(self, name, source):
        case = self.root / name
        case.mkdir()
        (case / "client.mli").write_text("")
        (case / "client.ml").write_text(source)
        command = [
            "ocamlc", "-color", "never", "-error-style", "short",
            "-w", WARNINGS, "-warn-error", WARNINGS,
            "-I", str(self.imports), "-c",
        ]
        interface = subprocess.run(
            command + ["client.mli"], cwd=case, capture_output=True,
            text=True, timeout=COMPILER_TIMEOUT_S, check=False,
        )
        self.assertEqual(interface.returncode, 0, interface.stderr)
        return subprocess.run(
            command + ["client.ml"], cwd=case, capture_output=True,
            text=True, timeout=COMPILER_TIMEOUT_S, check=False,
        )

    def test_valid_sources(self):
        result = self.compile("valid", VALID)
        self.assertEqual(result.returncode, 0, result.stderr)
        print("Valid lifecycle assembly: compiled", flush=True)

    def test_invalid_sources(self):
        rejected = 0
        for name, body, expected in INVALID:
            with self.subTest(client=name):
                result = self.compile(name, PREFIX + body + ")\n")
                self.assertNotEqual(result.returncode, 0, f"Invalid client compiled: {name}")
                self.assertIn("Error:", result.stderr)
                self.assertNotIn("Unbound", result.stderr)
                self.assertRegex(result.stderr, r"(?:This expression|The value x) has type")
                for fragment in expected:
                    self.assertIn(fragment, result.stderr)
                rejected += 1
        print(f"Rejected lifecycle clients: {rejected}/{len(INVALID)}", flush=True)

    def test_service_sources(self):
        valid = self.compile("service_valid", SERVICE_VALID)
        self.assertEqual(valid.returncode, 0, valid.stderr)

        rejected = 0
        for name, source, expected in SERVICE_INVALID:
            with self.subTest(client=name):
                result = self.compile(name, source)
                self.assertNotEqual(result.returncode, 0, f"Invalid client compiled: {name}")
                self.assertIn("Error:", result.stderr)
                self.assertNotIn("Unbound", result.stderr)
                self.assertRegex(result.stderr, r"(?:is not included|has type)")
                for fragment in expected:
                    self.assertIn(fragment, result.stderr)
                rejected += 1
        print(f"Rejected Service clients: {rejected}/{len(SERVICE_INVALID)}", flush=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-root", type=Path, default=BUILD_ROOT)
    options, remaining = parser.parse_known_args()
    BUILD_ROOT = options.build_root.resolve()
    unittest.main(argv=[__file__, *remaining], verbosity=2)
