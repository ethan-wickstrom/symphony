#!/usr/bin/env python3
"""Check real materialization, immutable hashes and rejected input paths."""

import hashlib
import copy
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


RELEASE = Path(__file__).resolve().parent.parent / "release"
sys.dont_write_bytecode = True
SPEC = importlib.util.spec_from_file_location("materialize", RELEASE / "materialize.py")
MATERIALIZE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MATERIALIZE)
RUN_TIMEOUT = 60


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
            [sys.executable, str(RELEASE / "materialize.py"), "--output", str(output)],
            capture_output=True, text=True, timeout=RUN_TIMEOUT,
        )

    def test_fresh_inputs(self):
        result = self.run_materializer(self.output)
        self.assertEqual(result.returncode, 0, result.stderr)
        receipt = json.loads((self.output / "materialization.json").read_text())
        self.assertEqual(len(receipt["recipes"]), 13)
        self.assertEqual(len(receipt["vendor_archives"]), 4)
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
        shutil.copytree(RELEASE, copied)
        template = copied / "templates/package-pins/zarith.opam.in"
        template.write_text(template.read_text().replace("-cclib", "-ccopt", 1))
        with self.assertRaisesRegex(ValueError, "template hash mismatch"):
            MATERIALIZE.prepare(copied, self.output)
        self.assertFalse(self.output.exists())

    def test_token_inventory(self):
        copied = self.base / "release"
        shutil.copytree(RELEASE, copied)
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
        shutil.copytree(RELEASE, copied)
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
        shutil.copytree(RELEASE, copied)
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
        shutil.copytree(RELEASE, copied, dirs_exist_ok=True)
        result = subprocess.run(
            [sys.executable, str(copied / "materialize.py"), "--output", str(self.output)],
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
                shutil.copytree(RELEASE, copied)
                (checkout / ".git").symlink_to(RELEASE.parent.parent / ".git", target_is_directory=True)
                (copied / MATERIALIZE.PROFILE).write_text(json.dumps(value))
                output = self.base / f"out-{name}"
                result = subprocess.run(
                    [sys.executable, str(copied / "materialize.py"), "--output", str(output)],
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
                shutil.copytree(RELEASE, copied)
                (copied / MATERIALIZE.PROFILE).write_bytes(data)
                output = self.base / f"out-{name}"
                result = subprocess.run(
                    [sys.executable, str(copied / "materialize.py"), "--output", str(output)],
                    capture_output=True, text=True, timeout=RUN_TIMEOUT,
                )
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertIn(MATERIALIZE.PROFILE, result.stderr)
                self.assertNotIn("Traceback", result.stderr)
                self.assertFalse(output.exists())

    def test_read_bounds(self):
        copied = self.base / "release"
        shutil.copytree(RELEASE, copied)
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
