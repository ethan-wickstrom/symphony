"""Real Appleclang/Mach-O release controls; no text fixture proves acceptance."""

import importlib.util
import itertools
import json
from pathlib import Path
import random
import struct
import subprocess
import sys
import tempfile
import unittest


CHECK = Path(__file__).resolve().parents[1] / "tools/check_release.py"
SPEC = importlib.util.spec_from_file_location("check_release", CHECK)
GATE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GATE)
BUILD_TIMEOUT = 30
CLI_TIMEOUT = 10
WRONG_MINIMUM = "15.0"
WRONG_SDK = "26.4"
PARSER_SEED = 0x53594D50484F4E59
PARSER_MUTATIONS = 10000


def command(argv):
    result = subprocess.run(argv, capture_output=True, text=True, timeout=BUILD_TIMEOUT,
                            env={"PATH": "/usr/bin:/bin", "LC_ALL": "C"})
    if result.returncode:
        raise RuntimeError(f"Fixture command failed ({result.returncode}): {argv}\n{result.stderr}")
    return result.stdout.strip()


class PortableReleaseTest(unittest.TestCase):
    def test_dependency_law(self):
        # Independent set oracle; approval is downward closed under subset.
        invalid = ["@rpath/foreign.dylib", "/opt/foreign.dylib", "libSystem.B.dylib"]
        for count in range(4):
            for dependencies in itertools.product([GATE.SYSTEM_LIB, *invalid], repeat=count):
                expected = set(dependencies) <= {GATE.SYSTEM_LIB}
                try:
                    GATE.check_dependencies(list(dependencies))
                    accepted = True
                except GATE.Rejected:
                    accepted = False
                self.assertEqual(accepted, expected, dependencies)
                if not expected:
                    with self.assertRaises(GATE.Rejected):
                        GATE.check_dependencies([*dependencies, GATE.SYSTEM_LIB])

    def test_cli_invalid_arguments(self):
        flags = [] if not sys.flags.optimize else ["-" + "O" * sys.flags.optimize]
        for arguments in ([], ["unused-artifact", "--profile", "linux"]):
            result = subprocess.run([sys.executable, *flags, str(CHECK), *arguments],
                                    capture_output=True, text=True, timeout=CLI_TIMEOUT)
            self.assertEqual(result.returncode, 2, result.stderr + result.stdout)
            self.assertEqual(result.stderr, "")
            self.assertEqual(json.loads(result.stdout)["diagnostic"]["code"], "arguments")


@unittest.skipUnless(sys.platform == "darwin", "Real controls require macOS and SDK 26.5")
class ReleaseCheckTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix="symphony-release-controls-")
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.base = Path(cls.temporary.name)
        sdk = command(["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-path"])
        sdk_version = command(["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-version"])
        if sdk_version != "26.5":
            raise unittest.SkipTest(f"Native release controls require SDK 26.5, found {sdk_version}")
        cls.clang = command(["/usr/bin/xcrun", "--find", "clang"])
        cls.flags = ["-arch", "arm64", "-isysroot", sdk, "-mmacosx-version-min=26.0"]
        cls.source = cls.base / "main.c"
        cls.source.write_text("int main(void) { return 0; }\n")
        cls.good = cls.base / "system-only"
        command([cls.clang, *cls.flags, str(cls.source), "-o", str(cls.good)])

        cls.wrong_min = cls.base / "wrong-minimum"
        flags = [*cls.flags[:-1], f"-mmacosx-version-min={WRONG_MINIMUM}"]
        command([cls.clang, *flags, str(cls.source), "-o", str(cls.wrong_min)])
        cls.wrong_sdk = cls.base / "wrong-sdk"
        command(["/usr/bin/vtool", "-set-build-version", "macos", "26.0", WRONG_SDK,
                 "-replace", "-output", str(cls.wrong_sdk), str(cls.good)])
        cls.wrong_sdk.chmod(0o700)

        foreign_source = cls.base / "foreign.c"
        foreign_source.write_text("int foreign(void) { return 0; }\n")
        foreign_lib = cls.base / "foreign.dylib"
        command([cls.clang, *cls.flags, "-dynamiclib", str(foreign_source), "-install_name",
                 str(foreign_lib), "-o", str(foreign_lib)])
        linked_source = cls.base / "linked.c"
        linked_source.write_text("extern int foreign(void); int main(void) { return foreign(); }\n")
        cls.foreign = cls.base / "foreign-import"
        command([cls.clang, *cls.flags, str(linked_source), str(foreign_lib),
                 "-o", str(cls.foreign)])
        cls.weak = cls.base / "weak-import"
        command([cls.clang, *cls.flags, str(linked_source), "-weak_library", str(foreign_lib),
                 "-o", str(cls.weak)])
        cls.rpath = cls.base / "runpath"
        command([cls.clang, *cls.flags, str(cls.source), "-Wl,-rpath,@executable_path",
                 "-o", str(cls.rpath)])

    def require_status(self, path, status, code=None):
        receipt = GATE.verify(path)
        self.assertEqual(receipt["status"], status, receipt)
        if code is not None:
            self.assertEqual(receipt["diagnostic"]["code"], code, receipt)
        return receipt

    def write_artifact(self, name, data):
        path = self.base / name
        path.write_bytes(data)
        path.chmod(0o700)
        return path

    def test_system_and_repeat(self):
        first = self.require_status(self.good, "accepted")
        second = self.require_status(self.good, "accepted")
        for key in ("status", "artifact", "binary"):
            self.assertEqual(first[key], second[key])
        self.assertEqual(first["artifact"]["sha256"], GATE.digest(self.good.read_bytes()))
        self.assertEqual(first["artifact"]["size"], self.good.stat().st_size)
        self.assertEqual(first["binary"]["dependencies"], [GATE.SYSTEM_LIB])
        self.assertEqual(len(first["observations"]), 4)
        self.assertEqual(command([str(self.good)]), "")

    def test_foreign_import(self):
        self.require_status(self.foreign, "rejected", "dependency")

    def test_wrong_minimum(self):
        self.require_status(self.wrong_min, "rejected", "deployment")

    def test_wrong_sdk(self):
        self.require_status(self.wrong_sdk, "rejected", "deployment")

    def test_weak_and_rpath(self):
        self.require_status(self.weak, "rejected", "command")
        self.require_status(self.rpath, "rejected", "command")

    def test_malformed_and_truncated(self):
        malformed = self.write_artifact("malformed", b"not a Mach-O executable\n")
        self.require_status(malformed, "rejected", "malformed")
        truncated = self.write_artifact("truncated", self.good.read_bytes()[:-1])
        self.require_status(truncated, "rejected", "malformed")

    def test_unknown_and_bad_shape(self):
        data = bytearray(self.good.read_bytes())
        struct.pack_into("<I", data, GATE.HEADER_SIZE, 0x7FFFFFFF)
        unknown = self.write_artifact("unknown-command", data)
        self.require_status(unknown, "rejected", "command")
        data = bytearray(self.good.read_bytes())
        struct.pack_into("<I", data, GATE.HEADER_SIZE + 4, 9)
        bad_shape = self.write_artifact("bad-command-size", data)
        self.require_status(bad_shape, "rejected", "malformed")

    def test_parser_checked_failures(self):
        data = bytearray(self.good.read_bytes())
        data[GATE.HEADER_SIZE + 8] = 255
        with self.assertRaises(GATE.Rejected) as caught:
            GATE.parse_macho(data)
        self.assertEqual(caught.exception.diagnostic["code"], "malformed")

    def test_seeded_parser_mutations(self):
        rng = random.Random(PARSER_SEED)
        original = self.good.read_bytes()
        command_bytes = struct.unpack_from("<I", original, 20)[0]
        for case in range(PARSER_MUTATIONS):
            data = bytearray(original)
            for _ in range(rng.randint(1, 4)):
                offset = rng.randrange(GATE.HEADER_SIZE + command_bytes)
                data[offset] = rng.randrange(256)
            if case % 4 == 0:
                del data[rng.randrange(len(data)):]
            try:
                GATE.parse_macho(data)
            except GATE.Rejected:
                continue
            except Exception as error:
                self.fail(f"seed={PARSER_SEED} case={case}: escaped {type(error).__name__}: {error}")

    def test_missing_build_command(self):
        data = bytearray(self.good.read_bytes())
        count, total = struct.unpack_from("<II", data, 16)
        offset, kept = GATE.HEADER_SIZE, []
        for _ in range(count):
            kind, size = struct.unpack_from("<II", data, offset)
            if kind != 0x32:
                kept.append(bytes(data[offset:offset + size]))
            offset += size
        commands = b"".join(kept)
        struct.pack_into("<II", data, 16, len(kept), len(commands))
        data[GATE.HEADER_SIZE:GATE.HEADER_SIZE + total] = commands.ljust(total, b"\0")
        missing = self.write_artifact("missing-build", data)
        self.require_status(missing, "rejected", "malformed")

    def test_symlink_and_nonexec(self):
        linked = self.base / "symbolic-link"
        linked.symlink_to(self.good)
        self.require_status(linked, "rejected", "io")
        nonexec = self.write_artifact("nonexecutable", self.good.read_bytes())
        nonexec.chmod(0o600)
        self.require_status(nonexec, "rejected", "artifact")
        self.require_status(self.base / "missing", "rejected", "io")

    def test_cli_receipt_and_failure(self):
        flags = [] if not sys.flags.optimize else ["-" + "O" * sys.flags.optimize]
        saved = self.base / "receipt.json"
        result = subprocess.run([sys.executable, *flags, str(CHECK), str(self.good),
                                 "--receipt", str(saved)], capture_output=True, text=True,
                                timeout=CLI_TIMEOUT)
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertEqual(json.loads(result.stdout), json.loads(saved.read_text()))
        self.assertEqual(json.loads(result.stdout)["status"], "accepted")
        result = subprocess.run([sys.executable, *flags, str(CHECK), str(self.foreign)],
                                capture_output=True, text=True, timeout=CLI_TIMEOUT)
        self.assertEqual(result.returncode, 1, result.stderr + result.stdout)
        self.assertEqual(json.loads(result.stdout)["diagnostic"]["code"], "dependency")
        result = subprocess.run([sys.executable, *flags, str(CHECK), str(self.good),
                                 "--receipt", str(self.base)], capture_output=True, text=True,
                                timeout=CLI_TIMEOUT)
        self.assertEqual(result.returncode, 1, result.stderr + result.stdout)
        self.assertEqual(json.loads(result.stdout)["diagnostic"]["code"], "receipt")


if __name__ == "__main__":
    unittest.main()
