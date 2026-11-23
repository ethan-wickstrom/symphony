# Historical macOS inputs

These archived recipes contain security-affected Mirage Crypto 1.2.0. They
preserve historical observations and must not qualify a current release. The
development dependency refresh to 2.4.1 requires a fresh release qualification.

This profile preserves the locally qualified macOS arm64 recipes: minimum OS
26.0, SDK 26.5, Xcode 26.6, OCaml 5.5.0 and an Apple M1 CPU baseline. GMP and
pkgconf use the generic Armv8-A subset. It is separate from the development
switch and from the pending Linux musl profile.

Release tools require the installed [portable harness](../../conformance/README.md).
From the repository root, bootstrap a dedicated environment (Python 3.13 or newer
on macOS):

```sh
python3 -m venv conformance/.venv
conformance/.venv/bin/python -m pip install --require-hashes --only-binary=:all: -r conformance/requirements.lock
conformance/.venv/bin/python -m pip install --no-build-isolation --no-deps ./conformance
conformance/.venv/bin/python ocaml/release/materialize.py --help
conformance/.venv/bin/python ocaml/release/materialize.py --purpose historical-replay --output /private/tmp/symphony-release-fresh
```

The output must be absent and its parent must exist. Paths are canonical absolute
paths using letters, digits, `_`, `.`, `+`, `-` and `/`; whitespace and shell
metacharacters are rejected because the upstream recipes contain shell command
strings. The committed vendor trees at HEAD must match the manifest's tree IDs;
shallow checkouts work. The source commit records qualification provenance.

The materializer verifies every template hash and token inventory, reads the four
immutable vendor trees, and reproduces the exact reviewed TAR/gzip hashes. It
emits 13 opam recipes, four vendor archives, a resolved `profile.json` with the
qualified argv/environment records, and `materialization.json` with output
hashes. Eio and Eio_posix share one archive; YAML, H1 and Crowbar have their own.
It ignores uncommitted vendor changes, never overwrites a prefix, and performs no
download, opam operation or build. All checks precede prefix creation.
Profile input is capped at 64 KiB and templates at 32 KiB. Recursive duplicate
JSON keys are rejected. A closed schema checks every published field before
path use; publication serializes the checked value before token substitution,
so JSON escapes cannot preserve unresolved tokens. Descriptor reads reject
symlinks and nonregular files without blocking. Git stdout/stderr have independent
live caps of 4 MiB/64 KiB and a 30 s drain/reap deadline.
The inputs are an owned checkout, with concurrent same-user mutation outside this
receipt's custody claim.

The manifest records upstream URLs and SHA256 for OCaml, GMP, pkgconf, the
supplemental upstream `Makefile.lite`, opam, Zarith and the two unchanged conf-GMP
probe sources. Downloaded sources must match these hashes. The release tarball
omits `Makefile.lite`; use the pinned release-commit recipe. GMP's historical
signature was cryptographically valid, with an expired-key warning in the retained
verification. pkgconf's archive hash matched its official release-asset digest;
no detached-signature verification is claimed.

For a historical replay, use the resolved profile as the build input:
build/check/install GMP in its owned
prefix, build/check pkgconf with its header target first, install the standalone
binary as `target/tools/bin/pkgconf` and a `pkg-config` alias, then use the explicit
compiler and package pins in the fresh opam root. Compiler cloning is disabled;
compression is disabled. Keep `--no-depexts` and `--require-checksums`, and supply
the recorded child environments rather than exporting global flags.
The pkgconf install record specifies directory creation, binary copy, mode 0755
and the relative `pkg-config -> pkgconf` symlink. These steps reconstruct the
qualified filesystem result; the historical copy command was not retained.

The persisted compiler, GMP, pkgconf and Zarith flags are unchanged from the
qualified recipes. The package-local Zarith make command records the exact static
GMP archive for both native metadata and its shared-stub link; the conf packages
probe that same archive. Do not edit installed metadata, change the `gmp.pc` library
shape or reuse development archives. Verify tool/SDK identity, runtime/archive
metadata, actual link order and executable closure before accepting a new build.

This is a recipe deliverable. It does not fetch or snapshot the remaining opam
repository metadata, orchestrate a fresh end-to-end rebuild, certify two-build
reproducibility, verify the installed SDK, or establish execution on a clean
macOS 26.0 host. The copied package versions remain pinned in
`inputs/symphony-release.opam`. Physical release and clean-host gates are described
in [the release plan](../../docs/design/static-release-plan.md).

Run the bounded materialization controls with:

```sh
conformance/.venv/bin/python ocaml/test/release_materialize_test.py
conformance/.venv/bin/python -O ocaml/test/release_materialize_test.py
```

The content laws are checked against independent hash/inventory oracles:

- Checked profile decoding preserves the value and is idempotent; invalid shapes
  and duplicate keys return named failures before effects. Boolean schema
  versions are invalid. Binding substitution is invariant under JSON escaping.
- Fixed tree IDs, templates and bindings produce identical archive/recipe bytes.
- A fresh prefix publishes one checked input set; an existing prefix is preserved.
- Template/tree/hash drift rejects the input set before publication.

These laws have example, tamper and seeded mutation evidence, not a proof.
Receipts identify both materializer and bounded-capture source hashes as context;
these hashes do not attest execution or establish source-to-binary provenance.
