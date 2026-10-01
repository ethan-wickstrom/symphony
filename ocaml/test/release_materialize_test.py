#!/usr/bin/env python3
"""Check real materialization, immutable hashes and rejected input paths."""

import hashlib
import copy
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


RELEASE = Path(__file__).resolve().parent.parent / "release"
sys.dont_write_bytecode = True
SPEC = importlib.util.spec_from_file_location("materialize", RELEASE / "materialize.py")
MATERIALIZE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MATERIALIZE)
RUN_TIMEOUT = 60
GIT_STDERR_BOUND = 64 * 1024


class Materialization(unittest.TestCase):
    def setUp(self):
        parent = Path(tempfile.gettempdir()).resolve()
        self.temp = tempfile.TemporaryDirectory(prefix="symphony-recipes-", dir=parent)
        self.base = Path(self.temp.name)
        self.output = self.base / "fresh"

    def tearDown(self):
        self.temp.cleanup()

    def run_materializer(self, output):
        return subprocess.run(
            [sys.executable, str(RELEASE / "materialize.py"), "--purpose", "historical-replay", "--output", str(output)],
            capture_output=True, text=True, timeout=RUN_TIMEOUT,
        )

    def copy_release(self, destination):
        shutil.copytree(RELEASE, destination, dirs_exist_ok=True)
        tools = destination.parent / "tools"
        tools.mkdir(exist_ok=True)
        shutil.copyfile(RELEASE.parent / "tools/bounded_process.py", tools / "bounded_process.py")

    def test_archival_intent_required(self):
        for purpose in ([], ["--purpose", "current-release"]):
            output = self.base / ("missing" if not purpose else "invalid")
            with self.subTest(purpose=purpose):
                result = subprocess.run(
                    [sys.executable, str(RELEASE / "materialize.py"),
                     "--output", str(output), *purpose],
                    capture_output=True, text=True, timeout=RUN_TIMEOUT,
                )
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn("--purpose", result.stderr)
                self.assertFalse(output.exists())

    def test_archival_labels(self):
        help_result = subprocess.run(
            [sys.executable, str(RELEASE / "materialize.py"), "--help"],
            capture_output=True, text=True, timeout=RUN_TIMEOUT,
        )
        self.assertEqual(help_result.returncode, 0, help_result.stderr)
        result = self.run_materializer(self.output)
        self.assertEqual(result.returncode, 0, result.stderr)
        receipt = json.loads((self.output / "materialization.json").read_text())
        self.assertEqual(receipt.get("purpose"), "historical-replay")
        for output in (help_result.stdout, result.stdout, receipt.get("security_notice", "")):
            with self.subTest(output=output):
                self.assertIn("Security-affected Mirage Crypto 1.2.0 archival inputs", output)
                self.assertIn("not current release qualification", output)

    def test_fresh_inputs(self):
        result = self.run_materializer(self.output)
        self.assertEqual(result.returncode, 0, result.stderr)
        receipt = json.loads((self.output / "materialization.json").read_text())
        self.assertEqual(len(receipt["recipes"]), 13)
        self.assertEqual(len(receipt["vendor_archives"]), 4)
        self.assertEqual(receipt["bounded_process_sha256"], hashlib.sha256(
            (RELEASE.parent / "tools/bounded_process.py").read_bytes()).hexdigest())
        for name, digest in receipt["files"].items():
            actual = hashlib.sha256((self.output / name).read_bytes()).hexdigest()
            self.assertEqual(actual, digest, name)
        for name in ("eio", "eio_posix", "yaml", "h1", "crowbar"):
            recipe = (self.output / "inputs/package-pins" / f"{name}.opam").read_text()
            vendor = "eio" if name == "eio_posix" else name
            self.assertIn(f'checksum: "sha256={receipt["vendor_archives"][vendor]}"', recipe)
            self.assertNotIn("@INPUTS@", recipe)
            self.assertNotIn("@TARGET@", recipe)

    def test_qualified_substitution(self):
        profile = json.loads((RELEASE / MATERIALIZE.PROFILE).read_text())
        original = {
            "INPUTS": "/private/tmp/symphony-release-inputs-djwlgpqp",
            "TARGET": "/private/tmp/symphony-release-target/mac-arm64-26.0",
        }
        for name, entry in profile["templates"].items():
            template = (RELEASE / entry["template"]).read_text()
            restored = MATERIALIZE.substitute(template, original).encode()
            self.assertEqual(hashlib.sha256(restored).hexdigest(), entry["qualified_sha256"], name)

    def test_git_output_bound(self):
        tools = self.base / "bin"
        tools.mkdir()
        producer = tools / "git"
        producer.write_text(
            f"#!{sys.executable}\n"
            "import os, sys\n"
            "fd = 1 if sys.argv[1] == 'stdout' else 2\n"
            "remaining = int(sys.argv[2])\n"
            "while remaining:\n"
            "    remaining -= os.write(fd, b'x' * min(remaining, 16384))\n"
        )
        producer.chmod(0o700)
        with mock.patch.dict(os.environ, {"PATH": str(tools)}):
            for stream, limit in [("stdout", MATERIALIZE.MAX_ARCHIVE), ("stderr", GIT_STDERR_BOUND)]:
                with self.subTest(stream=stream):
                    with self.assertRaisesRegex(ValueError, f"{stream} exceeds"):
                        MATERIALIZE.git(self.base, stream, str(limit + 1))

    def test_git_before_publication(self):
        actual_git = shutil.which("git")
        self.assertIsNotNone(actual_git)
        tools = self.base / "bin"
        tools.mkdir()
        producer = tools / "git"
        producer.write_text(
            f"#!{sys.executable}\n"
            "import os, sys\n"
            "if sys.argv[1] != 'archive':\n"
            f"    os.execv({actual_git!r}, [{actual_git!r}, *sys.argv[1:]])\n"
            f"remaining = {MATERIALIZE.MAX_ARCHIVE + 1}\n"
            "while remaining:\n"
            "    remaining -= os.write(1, b'x' * min(remaining, 16384))\n"
        )
        producer.chmod(0o700)
        with mock.patch.dict(os.environ, {"PATH": str(tools)}):
            result = self.run_materializer(self.output)
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("stdout exceeds", result.stderr)
        self.assertFalse(self.output.exists())

    def test_cleanup_note_visible(self):
        actual_git = shutil.which("git")
        self.assertIsNotNone(actual_git)
        tools = self.base / "bin"
        tools.mkdir()
        producer = tools / "git"
        producer.write_text(
            f"#!{sys.executable}\n"
            "import os, sys, time\n"
            "if sys.argv[1] != 'archive':\n"
            f"    os.execv({actual_git!r}, [{actual_git!r}, *sys.argv[1:]])\n"
            f"remaining = {MATERIALIZE.MAX_ARCHIVE + 1}\n"
            "while remaining:\n"
            "    remaining -= os.write(1, b'x' * min(remaining, 16384))\n"
            "time.sleep(3)\n"
        )
        producer.chmod(0o700)
        real_popen = subprocess.Popen
        processes = []

        def spawn(*args, **kwargs):
            process = real_popen(*args, **kwargs)
            processes.append((process, process.kill))
            if args[0][1] == "archive":
                kill = process.kill
                def failed_kill():
                    kill()
                    raise RuntimeError("synthetic secret cleanup payload")
                process.kill = failed_kill
            return process

        output = io.StringIO()
        try:
            with mock.patch.dict(os.environ, {"PATH": str(tools)}):
                with mock.patch.object(MATERIALIZE._PROCESS.subprocess, "Popen", side_effect=spawn):
                    with mock.patch.object(sys, "argv", ["materialize.py", "--purpose", "historical-replay",
                                                         "--output", str(self.output)]):
                        with contextlib.redirect_stderr(output):
                            status = MATERIALIZE.main()
            self.assertEqual(status, 2)
            self.assertIn("stdout exceeds", output.getvalue())
            self.assertIn(f"stage=kill pid={processes[-1][0].pid} class=RuntimeError", output.getvalue())
            self.assertNotIn("synthetic secret cleanup payload", output.getvalue())
            self.assertFalse(self.output.exists())
            for process, _ in processes:
                self.assertIsNotNone(process.returncode)
                with self.assertRaises(ChildProcessError):
                    os.waitpid(process.pid, os.WNOHANG)
                self.assertTrue(process.stdout.closed)
                self.assertTrue(process.stderr.closed)
        finally:
            for process, kill in processes:
                if process.returncode is None:
                    kill()
                    process.wait(timeout=MATERIALIZE._PROCESS.REAP_TIMEOUT)

    def test_published_profile_shapes(self):
        original = json.loads((RELEASE / MATERIALIZE.PROFILE).read_text())
        cases = [
            (["name"], False),
            (["qualification_date"], "2026-02-31"),
            (["target"], False),
            (["target", "arch"], "x86_64"),
            (["target", "minimum_os"], "25.0"),
            (["target", "clang_sha256"], True),
            (["target", "cpu_baseline"], "native"),
            (["sources"], False),
            (["sources", "opam"], None),
            (["sources", "ocaml", "url"], False),
            (["sources", "gmp", "signature_sha256"], False),
            (["sources", "gmp", "path"], "@TARGET@/../../outside"),
            (["sources", "zarith", "via"], "unknown.opam"),
            (["operations"], False),
            (["operations", "compiler_install"], None),
            (["operations", "compiler_install", "argv"], []),
            (["operations", "dependencies_install", "argv"], [True]),
            (["operations", "gmp", "configure_argv"], ["/bin/sh", "bad\0argument"]),
            (["operations", "gmp", "environment"], False),
            (["operations", "gmp", "environment", "CC"], True),
            (["operations", "gmp", "abi"], "32"),
            (["operations", "gmp", "cpu_baseline"], "native"),
            (["operations", "pkgconf", "cpu_baseline"], "native"),
            (["boundaries"], False),
            (["boundaries"], []),
            (["boundaries"], [""]),
        ]
        for index, (path, value) in enumerate(cases):
            with self.subTest(field=".".join(path)):
                checkout = self.base / f"metadata-{index}"
                copied = checkout / "ocaml/release"
                self.copy_release(copied)
                (checkout / ".git").symlink_to(RELEASE.parent.parent / ".git", target_is_directory=True)
                profile = copy.deepcopy(original)
                parent = profile
                for key in path[:-1]:
                    parent = parent[key]
                parent[path[-1]] = value
                (copied / MATERIALIZE.PROFILE).write_text(json.dumps(profile))
                output = self.base / f"published-{index}"
                result = subprocess.run(
                    [sys.executable, str(copied / "materialize.py"), "--purpose", "historical-replay", "--output", str(output)],
                    capture_output=True, text=True, timeout=RUN_TIMEOUT,
                )
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn(MATERIALIZE.PROFILE, result.stderr)
                self.assertIn(path[0], result.stderr)
                self.assertNotIn("Traceback", result.stderr)
                self.assertFalse(output.exists())

    def test_duplicate_profile_keys(self):
        checkout = self.base / "checkout"
        copied = checkout / "ocaml/release"
        self.copy_release(copied)
        (checkout / ".git").symlink_to(RELEASE.parent.parent / ".git", target_is_directory=True)
        profile_path = copied / MATERIALIZE.PROFILE
        text = profile_path.read_text().replace(
            '"install": [',
            '"install": [{"operation":"unlink","path":"/outside"}], "install": [',
            1,
        )
        profile_path.write_text(text)
        result = subprocess.run(
            [sys.executable, str(copied / "materialize.py"), "--purpose", "historical-replay", "--output", str(self.output)],
            capture_output=True, text=True, timeout=RUN_TIMEOUT,
        )
        self.assertEqual(result.returncode, 2, result.stderr)
        self.assertIn("duplicate", result.stderr)
        self.assertIn("install", result.stderr)
        self.assertNotIn("Traceback", result.stderr)
        self.assertFalse(self.output.exists())

    def test_escaped_profile_tokens(self):
        checkout = self.base / "checkout"
        copied = checkout / "ocaml/release"
        self.copy_release(copied)
        (checkout / ".git").symlink_to(RELEASE.parent.parent / ".git", target_is_directory=True)
        profile_path = copied / MATERIALIZE.PROFILE
        text = profile_path.read_text().replace("@INPUTS@", r"\u0040INPUTS\u0040")
        text = text.replace("@TARGET@", r"\u0040TARGET\u0040")
        profile_path.write_text(text)
        result = subprocess.run(
            [sys.executable, str(copied / "materialize.py"), "--purpose", "historical-replay", "--output", str(self.output)],
            capture_output=True, text=True, timeout=RUN_TIMEOUT,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        emitted = json.loads((self.output / "profile.json").read_text())
        self.assertEqual(emitted["operations"]["compiler_install"]["argv"][0],
                         str(self.output / "inputs/opam-2.5.2-arm64-macos"))
        self.assertNotIn("@INPUTS@", json.dumps(emitted))
        self.assertNotIn("@TARGET@", json.dumps(emitted))

    def test_pkgconf_install_recipe(self):
        profile = json.loads((RELEASE / MATERIALIZE.PROFILE).read_text())
        operation = profile["operations"]["pkgconf"]
        self.assertIn("install", operation)
        target = self.base / "target"
        source = target / "pkgconf-build/pkgconf"
        source.parent.mkdir(parents=True)
        source.write_bytes(b"safe fixture bytes; never execute this candidate")
        for step in operation["install"]:
            resolved = {key: MATERIALIZE.substitute(value, {"TARGET": str(target)})
                        for key, value in step.items()}
            kind = resolved["operation"]
            if kind == "mkdir":
                Path(resolved["path"]).mkdir(parents=True)
            elif kind == "copyfile":
                shutil.copyfile(resolved["source"], resolved["destination"])
            elif kind == "chmod":
                Path(resolved["path"]).chmod(int(resolved["mode"], 8))
            elif kind == "symlink":
                Path(resolved["path"]).symlink_to(resolved["target"])
            else:
                self.fail(f"unsupported install operation: {kind}")
        binary = target / "tools/bin/pkgconf"
        alias = target / "tools/bin/pkg-config"
        self.assertEqual(binary.read_bytes(), source.read_bytes())
        self.assertEqual(binary.stat().st_mode & 0o777, 0o755)
        self.assertEqual(os.readlink(alias), "pkgconf")
        self.assertEqual(alias.stat().st_ino, binary.stat().st_ino)

    def test_existing_prefix(self):
        self.output.mkdir()
        sentinel = self.output / "operator-file"
        sentinel.write_text("preserve")
        result = self.run_materializer(self.output)
        self.assertEqual(result.returncode, 2)
        self.assertIn("already exists", result.stderr)
        self.assertEqual(sentinel.read_text(), "preserve")
        self.assertEqual(list(self.output.iterdir()), [sentinel])

    def test_unsafe_paths(self):
        for value in ("relative", str(self.base / "with space"), str(self.base / "bad$path")):
            with self.subTest(value=value):
                result = self.run_materializer(value)
                self.assertEqual(result.returncode, 2)
                self.assertIn("absolute safe path", result.stderr)
        alias = self.base / "alias"
        alias.symlink_to(self.base, target_is_directory=True)
        result = self.run_materializer(alias / "fresh")
        self.assertEqual(result.returncode, 2)
        self.assertIn("canonical", result.stderr)
        self.assertFalse(self.output.exists())

    def test_template_tampering(self):
        copied = self.base / "release"
        self.copy_release(copied)
        template = copied / "templates/package-pins/zarith.opam.in"
        template.write_text(template.read_text().replace("-cclib", "-ccopt", 1))
        with self.assertRaisesRegex(ValueError, "template hash mismatch"):
            MATERIALIZE.prepare(copied, self.output)
        self.assertFalse(self.output.exists())

    def test_token_inventory(self):
        copied = self.base / "release"
        self.copy_release(copied)
        profile_path = copied / MATERIALIZE.PROFILE
        profile = json.loads(profile_path.read_text())
        entry = profile["templates"]["package-pins/zarith.opam"]
        template = copied / entry["template"]
        data = template.read_bytes().replace(b"@TARGET@", b"@UNKNOWN@", 1)
        template.write_bytes(data)
        entry["sha256"] = hashlib.sha256(data).hexdigest()
        profile_path.write_text(json.dumps(profile))
        with self.assertRaisesRegex(ValueError, "token inventory mismatch"):
            MATERIALIZE.prepare(copied, self.output)
        self.assertFalse(self.output.exists())

    def test_binding_escape(self):
        copied = self.base / "release"
        self.copy_release(copied)
        profile_path = copied / MATERIALIZE.PROFILE
        profile = json.loads(profile_path.read_text())
        profile["bindings"]["TARGET"] = "../outside"
        profile_path.write_text(json.dumps(profile))
        with self.assertRaisesRegex(ValueError, "binding inventory"):
            MATERIALIZE.prepare(copied, self.output)
        self.assertFalse(self.output.exists())

    def test_vendor_tree_change(self):
        checkout = self.base / "checkout"
        copied = checkout / "ocaml/release"
        self.copy_release(copied)
        # Read the actual immutable objects through a fixture checkout; do not alter Git.
        (checkout / ".git").symlink_to(RELEASE.parent.parent / ".git", target_is_directory=True)
        profile_path = copied / MATERIALIZE.PROFILE
        profile = json.loads(profile_path.read_text())
        profile["vendors"][0]["tree"] = profile["vendors"][1]["tree"]
        profile_path.write_text(json.dumps(profile))
        with self.assertRaisesRegex(ValueError, "vendor HEAD/tree mismatch"):
            MATERIALIZE.prepare(copied, self.output)
        self.assertFalse(self.output.exists())

    def test_shallow_checkout(self):
        repo = RELEASE.parent.parent
        first = self.base / "first"
        shallow = self.base / "shallow"

        def git(cwd, *args):
            return subprocess.run(
                ["git", *args], cwd=cwd, check=True, capture_output=True,
                timeout=RUN_TIMEOUT,
            )

        git(self.base, "clone", "--quiet", "--depth=1", "--no-local", repo.as_uri(), str(first))
        (first / "materialization-control").write_text("non-vendor fixture commit\n")
        git(first, "add", "materialization-control")
        git(
            first, "-c", "user.name=Recipe control", "-c", "user.email=recipe@invalid",
            "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null",
            "commit", "--quiet", "-m", "Add non-vendor fixture receipt",
        )
        git(self.base, "clone", "--quiet", "--depth=1", "--no-local", first.as_uri(), str(shallow))
        profile = json.loads((RELEASE / MATERIALIZE.PROFILE).read_text())
        old_lookup = subprocess.run(
            ["git", "rev-parse", f"{profile['source_commit']}:vendor/eio"],
            cwd=shallow, capture_output=True, timeout=RUN_TIMEOUT,
        )
        self.assertNotEqual(old_lookup.returncode, 0, "qualification ancestor unexpectedly present")
        self.assertEqual(git(shallow, "rev-list", "--count", "HEAD").stdout.strip(), b"1")
        copied = shallow / "ocaml/release"
        self.copy_release(copied)
        result = subprocess.run(
            [sys.executable, str(copied / "materialize.py"), "--purpose", "historical-replay", "--output", str(self.output)],
            capture_output=True, text=True, timeout=RUN_TIMEOUT,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        receipt = json.loads((self.output / "materialization.json").read_text())
        self.assertEqual(receipt["source_commit"], profile["source_commit"])
        self.assertEqual(receipt["vendor_archives"], {
            entry["name"]: entry["sha256"] for entry in profile["vendors"]
        })

    def test_profile_shapes(self):
        profile = json.loads((RELEASE / MATERIALIZE.PROFILE).read_text())
        wrong_schema = copy.deepcopy(profile)
        wrong_schema["schema"] = True
        wrong_vendor = copy.deepcopy(profile)
        wrong_vendor["vendors"] = [False]
        wrong_count = copy.deepcopy(profile)
        wrong_count["vendors"][0]["tar_bytes"] = True
        wrong_entry = copy.deepcopy(profile)
        wrong_entry["templates"]["package-pins/zarith.opam"] = False
        wrong_path = copy.deepcopy(profile)
        outside = self.base / "outside"
        outside.write_text("not a release recipe\n")
        wrong_path["templates"]["package-pins/zarith.opam"]["template"] = str(outside)
        wrong_archive = copy.deepcopy(profile)
        wrong_archive["vendors"][0]["archive"] = "../outside.tar.gz"
        wrong_hash = copy.deepcopy(profile)
        wrong_hash["vendors"][0]["sha256"] = None
        wrong_tokens = copy.deepcopy(profile)
        wrong_tokens["templates"]["package-pins/zarith.opam"]["tokens"] = False
        wrong_bindings = copy.deepcopy(profile)
        wrong_bindings["bindings"] = False
        cases = {
            "root": [], "missing": {"schema": 1}, "boolean": wrong_schema,
            "vendor": wrong_vendor, "count": wrong_count, "entry": wrong_entry,
            "path": wrong_path, "archive": wrong_archive, "hash": wrong_hash,
            "tokens": wrong_tokens, "bindings": wrong_bindings,
        }
        for name, value in cases.items():
            with self.subTest(name=name):
                checkout = self.base / name
                copied = checkout / "ocaml/release"
                self.copy_release(copied)
                (checkout / ".git").symlink_to(RELEASE.parent.parent / ".git", target_is_directory=True)
                (copied / MATERIALIZE.PROFILE).write_text(json.dumps(value))
                output = self.base / f"out-{name}"
                result = subprocess.run(
                    [sys.executable, str(copied / "materialize.py"), "--purpose", "historical-replay", "--output", str(output)],
                    capture_output=True, text=True, timeout=RUN_TIMEOUT,
                )
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn(MATERIALIZE.PROFILE, result.stderr)
                self.assertNotIn("Traceback", result.stderr)
                self.assertFalse(output.exists())

    def test_json_boundary(self):
        for name, data in {
            "syntax": b"{", "encoding": b"\xff", "depth": b"[" * 2000 + b"]" * 2000,
        }.items():
            with self.subTest(name=name):
                copied = self.base / name / "ocaml/release"
                self.copy_release(copied)
                (copied / MATERIALIZE.PROFILE).write_bytes(data)
                output = self.base / f"out-{name}"
                result = subprocess.run(
                    [sys.executable, str(copied / "materialize.py"), "--purpose", "historical-replay", "--output", str(output)],
                    capture_output=True, text=True, timeout=RUN_TIMEOUT,
                )
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn(MATERIALIZE.PROFILE, result.stderr)
                self.assertNotIn("Traceback", result.stderr)
                self.assertFalse(output.exists())

    def test_read_bounds(self):
        copied = self.base / "release"
        self.copy_release(copied)
        profile_path = copied / MATERIALIZE.PROFILE
        profile_path.write_bytes(profile_path.read_bytes() + b" " * MATERIALIZE.MAX_PROFILE)
        with self.assertRaisesRegex(ValueError, "byte bound"):
            MATERIALIZE.prepare(copied, self.output)
        self.assertFalse(self.output.exists())

        shutil.copyfile(RELEASE / MATERIALIZE.PROFILE, profile_path)
        profile = json.loads(profile_path.read_text())
        entry = profile["templates"]["package-pins/zarith.opam"]
        template = copied / entry["template"]
        data = b" " * (MATERIALIZE.MAX_TEMPLATE + 1)
        template.write_bytes(data)
        entry["sha256"] = hashlib.sha256(data).hexdigest()
        profile_path.write_text(json.dumps(profile))
        with self.assertRaisesRegex(ValueError, "byte bound"):
            MATERIALIZE.prepare(copied, self.output)
        self.assertFalse(self.output.exists())

    def test_reader_file_types(self):
        target = self.base / "target"
        target.write_bytes(b"do not read through an alias")
        alias = self.base / "alias"
        alias.symlink_to(target)
        with self.assertRaises((OSError, ValueError)):
            MATERIALIZE.read_bound(alias, MATERIALIZE.MAX_TEMPLATE)

        fifo = self.base / "fifo"
        os.mkfifo(fifo)
        probe = """
import importlib.util, sys
from pathlib import Path
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('reader', sys.argv[1])
reader = importlib.util.module_from_spec(spec)
spec.loader.exec_module(reader)
try:
    reader.read_bound(Path(sys.argv[2]), reader.MAX_TEMPLATE)
except (OSError, ValueError):
    raise SystemExit(0)
raise SystemExit(1)
"""
        result = subprocess.run(
            [sys.executable, "-c", probe, str(RELEASE / "materialize.py"), str(fifo)],
            capture_output=True, timeout=5,
        )
        self.assertEqual(result.returncode, 0, result.stderr)

if __name__ == "__main__":
    unittest.main()
