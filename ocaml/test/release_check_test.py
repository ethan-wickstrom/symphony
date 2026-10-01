"""Real Appleclang/Mach-O release controls; no text fixture proves acceptance."""

import errno
import importlib.util
import itertools
import json
import os
from pathlib import Path
import random
import struct
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


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
# Selected SDK mach-o/loader.h layout and mach/vm_prot.h permissions.
LC_SEGMENT_64 = 0x19
LC_MAIN = 0x80000028
FILEOFF_OFFSET = 40
FILESIZE_OFFSET = 48
ENTRYOFF_OFFSET = 8
MAXPROT_OFFSET = 56
INITPROT_OFFSET = 60
VM_PROT_READ = 0x01
VM_PROT_WRITE = 0x02
VM_PROT_EXECUTE = 0x04
VM_PROT_IS_MASK = 0x40


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

    def test_required_native_available(self):
        # Inject availability only; this oracle does not replace native compilation.
        for platform, sdk in (("linux", "26.4"), ("darwin", "26.4")):
            fixture = type("UnavailableNative", (ReleaseCheckTest,), {})
            with self.subTest(platform=platform, sdk=sdk):
                try:
                    with mock.patch.object(sys, "platform", platform), \
                         mock.patch.dict(os.environ, {"SYMPHONY_REQUIRE_NATIVE": "1"}), \
                         mock.patch(__name__ + ".command", side_effect=["/unused-sdk", sdk]):
                        try:
                            with self.assertRaisesRegex(RuntimeError, "required"):
                                fixture.setUpClass()
                        except unittest.SkipTest as error:
                            self.fail(f"Required native controls silently skipped: {error}")
                finally:
                    fixture.doClassCleanups()

    def test_tool_output_live_bound(self):
        # Small injected budgets exercise actual pipe ownership before child exit.
        for descriptor in (1, 2):
            with self.subTest(descriptor=descriptor):
                source = f"import os,time; os.write({descriptor}, b'x'*33); time.sleep(5)"
                with mock.patch.object(GATE, "MAX_TOOL_OUTPUT", 32), \
                     mock.patch.object(GATE, "TOOL_TIMEOUT", 0.5):
                    with self.assertRaises(GATE.Rejected) as caught:
                        GATE.tool_output([sys.executable, "-I", "-c", source], Path("/unused"))
                self.assertEqual(caught.exception.diagnostic["code"], "tool")
                self.assertIn("exceeds", caught.exception.diagnostic["detail"])

    def test_tool_cleanup_notes(self):
        note = "Direct subprocess cleanup failed: stage=reap pid=42 class=TimeoutExpired"
        failures = [GATE.CAPTURE.OutputLimit("private inspection detail"),
                    subprocess.TimeoutExpired(["private inspection argv"], 1)]
        for failure in failures:
            with self.subTest(failure=type(failure).__name__):
                failure.add_note(note)
                failure.add_note("private inspection note")
                with mock.patch.object(GATE.CAPTURE, "run", side_effect=failure):
                    with self.assertRaises(GATE.Rejected) as caught:
                        GATE.tool_output(["/usr/bin/otool", "-l"], Path("/unused"))
                diagnostic = json.loads(json.dumps(caught.exception.diagnostic))
                self.assertEqual(diagnostic["code"], "tool")
                self.assertEqual(diagnostic.get("cleanup_notes"), [note])
                self.assertNotIn("private inspection", json.dumps(diagnostic))


class ReleaseCheckTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        required = os.environ.get("SYMPHONY_REQUIRE_NATIVE") == "1"
        if sys.platform != "darwin":
            if required:
                raise RuntimeError("Native release controls are required, but macOS is unavailable")
            raise unittest.SkipTest("Real controls require macOS and SDK 26.5")
        cls.temporary = tempfile.TemporaryDirectory(prefix="symphony-release-controls-")
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.base = Path(cls.temporary.name)
        sdk = command(["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-path"])
        sdk_version = command(["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-version"])
        if sdk_version != "26.5":
            if required:
                raise RuntimeError(f"Native release controls are required with SDK 26.5, found {sdk_version}")
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

    def text_offset(self, data):
        count = struct.unpack_from("<I", data, 16)[0]
        offset = GATE.HEADER_SIZE
        for _ in range(count):
            command_id, size = struct.unpack_from("<II", data, offset)
            if command_id == LC_SEGMENT_64 and data[offset + 8:offset + 24].rstrip(b"\0") == b"__TEXT":
                return offset
            offset += size
        self.fail("Appleclang fixture has no __TEXT segment")

    def command_offset(self, data, wanted):
        count = struct.unpack_from("<I", data, 16)[0]
        offset = GATE.HEADER_SIZE
        for _ in range(count):
            command_id, size = struct.unpack_from("<II", data, offset)
            if command_id == wanted:
                return offset
            offset += size
        self.fail(f"Appleclang fixture has no load command {wanted:#x}")

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

    def test_text_needs_execute(self):
        data = bytearray(self.good.read_bytes())
        offset = self.text_offset(data) + INITPROT_OFFSET
        initial = struct.unpack_from("<i", data, offset)[0]
        self.assertTrue(initial & VM_PROT_EXECUTE)
        struct.pack_into("<i", data, offset, initial & ~VM_PROT_EXECUTE)
        path = self.write_artifact("text-without-execute", data)
        self.require_status(path, "rejected", "permissions")

    def test_init_within_max(self):
        data = bytearray(self.good.read_bytes())
        offset = self.text_offset(data)
        struct.pack_into("<i", data, offset + MAXPROT_OFFSET, VM_PROT_READ | VM_PROT_EXECUTE)
        struct.pack_into("<i", data, offset + INITPROT_OFFSET,
                         VM_PROT_READ | VM_PROT_WRITE | VM_PROT_EXECUTE)
        path = self.write_artifact("initial-exceeds-maximum", data)
        self.require_status(path, "rejected", "permissions")

    def test_unsupported_permissions(self):
        for name, permissions in (("permission-modifier", VM_PROT_READ | VM_PROT_EXECUTE | VM_PROT_IS_MASK),
                                  ("negative-permissions", -1)):
            with self.subTest(name=name):
                data = bytearray(self.good.read_bytes())
                offset = self.text_offset(data)
                struct.pack_into("<i", data, offset + MAXPROT_OFFSET, permissions)
                struct.pack_into("<i", data, offset + INITPROT_OFFSET, permissions)
                path = self.write_artifact(name, data)
                self.require_status(path, "rejected", "permissions")

    def test_entry_needs_execute_range(self):
        original = self.good.read_bytes()
        text = self.text_offset(original)
        fileoff, filesize = struct.unpack_from("<QQ", original, text + FILEOFF_OFFSET)
        main = self.command_offset(original, LC_MAIN)
        for name, entry in (("entry-at-text-end", fileoff + filesize),
                            ("entry-in-linkedit", len(original) - 1)):
            with self.subTest(name=name):
                self.assertLess(entry, len(original))
                data = bytearray(original)
                struct.pack_into("<Q", data, main + ENTRYOFF_OFFSET, entry)
                path = self.write_artifact(name, data)
                self.require_status(path, "rejected", "entrypoint")

    def test_receipt_preserves_existing(self):
        flags = [] if not sys.flags.optimize else ["-" + "O" * sys.flags.optimize]
        original = self.good.read_bytes()
        for kind in ("artifact", "hardlink", "symlink", "existing"):
            with self.subTest(kind=kind):
                artifact = self.write_artifact("receipt-artifact-" + kind, original)
                receipt = self.base / ("receipt-target-" + kind)
                expected = original
                if kind == "artifact":
                    receipt = artifact
                elif kind == "hardlink":
                    os.link(artifact, receipt)
                elif kind == "symlink":
                    receipt.symlink_to(artifact)
                else:
                    expected = b"operator receipt\n"
                    receipt.write_bytes(expected)
                result = subprocess.run([sys.executable, *flags, str(CHECK), str(artifact),
                                         "--receipt", str(receipt)], capture_output=True, text=True,
                                        timeout=CLI_TIMEOUT)
                self.assertEqual(artifact.read_bytes(), original, "Receipt modified artifact")
                self.assertEqual(receipt.read_bytes(), expected, "Receipt overwrote existing data")
                self.assertEqual(result.returncode, 1, result.stderr + result.stdout)
                self.assertEqual(json.loads(result.stdout)["diagnostic"]["code"], "receipt")

    def test_io_cleanup_notes_visible(self):
        original = GATE.CAPTURE.subprocess.Popen
        processes = []

        def launch(*args, **kwargs):
            process = original(*args, **kwargs)
            close = process.stdout.close

            def fail_close():
                close()
                failure = OSError(errno.EIO, "controlled stdout cleanup")
                failure.add_note("private inspection note")
                raise failure

            process.stdout.close = fail_close
            processes.append(process)
            return process

        with mock.patch.object(GATE.CAPTURE.subprocess, "Popen", side_effect=launch):
            receipt = GATE.verify(self.good)
        self.assertEqual(len(processes), 1)
        process = processes[0]
        self.assertEqual(process.returncode, 0)
        self.assertTrue(process.stdout.closed)
        self.assertTrue(process.stderr.closed)
        self.assertEqual(receipt["status"], "rejected")
        diagnostic = receipt["diagnostic"]
        self.assertEqual(diagnostic["code"], "io")
        self.assertIn("Artifact/inspection I/O failed:", diagnostic["detail"])
        note = f"Direct subprocess cleanup failed: stage=stdout-close pid={process.pid} class=OSError"
        self.assertEqual(diagnostic.get("cleanup_notes"), [note])
        self.assertNotIn("private inspection note", json.dumps(diagnostic))

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
