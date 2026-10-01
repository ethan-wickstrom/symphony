#!/usr/bin/env python3
"""Exercise the real fuzz harness crash, rejection, bound and effect contracts."""

import hashlib
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import unittest


OCAML = Path(__file__).resolve().parent.parent
MACHO = OCAML / "fuzz/release_macho.py"
PROFILE = OCAML / "fuzz/release_profile.py"
PROFILE_INPUT = OCAML / "release/macos-arm64-26.0.json"
INPUT_BOUND = 64 * 1024
CHILD_TIMEOUT = 10

# Core limits apply before either trusted harness is loaded. Candidate bytes are data.
ENTRY = """
import resource, runpy, sys
resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
sys.dont_write_bytecode = True
target = sys.argv[1]
sys.argv = sys.argv[1:]
runpy.run_path(target, run_name='__main__')
"""

PROBE = """
import builtins, importlib.util, resource, sys
from pathlib import Path
resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('fuzz_control', sys.argv[1])
harness = importlib.util.module_from_spec(spec)
spec.loader.exec_module(harness)
mode, error_name = sys.argv[2:4]

def defect(*args, **kwargs):
    raise getattr(builtins, error_name)('injected unnamed defect')

if mode == 'macho-defect':
    harness.GATE.parse_macho = defect
    harness.check(b'not a Mach-O image')
elif mode == 'profile-defect':
    harness.GATE.check_profile = defect
    harness.check(b'{}')
elif mode == 'decoder-defect':
    harness.GATE.json.loads = defect
    harness.check(b'{}')
elif mode == 'profile-decoder-defect':
    harness.GATE.decode_profile = defect
    harness.check(b'{}')
elif mode == 'named-rejection':
    def rejected(value):
        raise ValueError(f'{harness.GATE.PROFILE}: injected checked rejection')
    harness.GATE.check_profile = rejected
    harness.check(b'{}')
elif mode == 'profile-effects':
    data = Path(sys.argv[4]).read_bytes()
    harness.GATE._PROCESS.run = defect
    for name in ('git', 'archive', 'prepare', 'materialize', 'read_bound'):
        setattr(harness.GATE, name, defect)
    harness.GATE.subprocess.run = defect
    harness.GATE.os.open = defect
    Path.open = defect
    builtins.open = defect
    harness.check(data)
elif mode == 'macho-effects':
    harness.GATE.CAPTURE.run = defect
    for name in ('verify', 'snapshot', 'inspect_tools', 'tool_output'):
        setattr(harness.GATE, name, defect)
    harness.GATE.subprocess.run = defect
    harness.check(b'not a Mach-O image')
else:
    raise RuntimeError('unknown control mode')
"""


class FuzzContracts(unittest.TestCase):
    def setUp(self):
        parent = Path(tempfile.gettempdir()).resolve()
        self.temp = tempfile.TemporaryDirectory(prefix="symphony-fuzz-contract-", dir=parent)
        self.base = Path(self.temp.name)

    def tearDown(self):
        self.temp.cleanup()

    def child(self, source, *args):
        optimize = ["-" + "O" * sys.flags.optimize] if sys.flags.optimize else []
        return subprocess.run(
            [sys.executable, "-B", *optimize, "-c", source, *map(str, args)],
            cwd=self.base, capture_output=True, timeout=CHILD_TIMEOUT,
        )

    def invoke(self, harness, data):
        candidate = self.base / "candidate"
        candidate.write_bytes(data)
        return self.child(ENTRY, harness, candidate)

    def test_child_mode(self):
        probe = """
import resource, sys
resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
print(sys.flags.optimize)
"""
        result = self.child(probe)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), str(sys.flags.optimize).encode())

    def test_expected_rejections(self):
        for harness, data in ((MACHO, b"invalid"), (PROFILE, b"{"), (PROFILE, b"[]")):
            with self.subTest(harness=harness.name, data=data):
                result = self.invoke(harness, data)
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_input_bounds(self):
        for harness in (MACHO, PROFILE):
            with self.subTest(harness=harness.name):
                exact = self.invoke(harness, b"\x00" * INPUT_BOUND)
                self.assertEqual(exact.returncode, 0, exact.stderr)
                extra = self.invoke(harness, b"\x00" * (INPUT_BOUND + 1))
                self.assertEqual(extra.returncode, 2, extra.stderr)
                self.assertIn(b"fuzz bound", extra.stderr)

    def test_unexpected_errors_abort(self):
        cases = (
            (MACHO, "macho-defect", "RuntimeError"),
            (MACHO, "macho-defect", "ValueError"),
            (PROFILE, "profile-defect", "RuntimeError"),
            (PROFILE, "profile-defect", "ValueError"),
            (PROFILE, "profile-defect", "RecursionError"),
            (PROFILE, "decoder-defect", "RuntimeError"),
            (PROFILE, "profile-decoder-defect", "RuntimeError"),
        )
        for harness, mode, error in cases:
            with self.subTest(mode=mode, error=error):
                result = self.child(PROBE, harness, mode, error)
                self.assertEqual(result.returncode, -signal.SIGABRT, result.stderr)
                self.assertIn(error.encode(), result.stderr)
                self.assertEqual(list(self.base.iterdir()), [], "unexpected child artifact")

    def test_expected_errors_stay_normal(self):
        for mode, error in (
            ("decoder-defect", "ValueError"), ("decoder-defect", "RecursionError"),
            ("named-rejection", "ValueError"),
        ):
            with self.subTest(mode=mode, error=error):
                result = self.child(PROBE, PROFILE, mode, error)
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_effect_guards(self):
        sources = (MACHO, PROFILE, PROFILE_INPUT)
        before = {path: hashlib.sha256(path.read_bytes()).hexdigest() for path in sources}
        for harness, mode in ((PROFILE, "profile-effects"), (MACHO, "macho-effects")):
            with self.subTest(mode=mode):
                result = self.child(PROBE, harness, mode, "RuntimeError", PROFILE_INPUT)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(list(self.base.iterdir()), [], "unexpected effect output")
        after = {path: hashlib.sha256(path.read_bytes()).hexdigest() for path in sources}
        self.assertEqual(after, before)


if __name__ == "__main__":
    unittest.main()
