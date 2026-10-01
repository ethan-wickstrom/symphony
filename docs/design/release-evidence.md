# Physical release evidence

`ocaml/tools/check_release.py ARTIFACT --receipt RECEIPT.json` checks one profile:
`macos-arm64-26.0-sdk26.5`. Exit 0 means accepted, 1 means artifact/tool/receipt
rejection, and 2 means invalid CLI arguments. Failures identify the failed gate
and a remedy in JSON. `--help` prints usage. Linux verification is not implemented.

The gate opens a regular executable without following its final symlink, copies
bounded bytes into a private snapshot, and rejects changes observed during the
copy. SHA-256 and size identify the inspected snapshot. Every inspector reads
that copy; its hash is checked again afterward. The original pathname is a
label, not continuing authority over bytes at that name.

The binary must be thin arm64, `MH_EXECUTE`, with checked Mach-O load-command
framing, executable segments, entry point, symbol metadata, and exactly one
macOS build-version command specifying minimum 26.0 and SDK 26.5. The loader is
`/usr/lib/dyld`. Ordinary imports form a subset of
`{/usr/lib/libSystem.B.dylib}`. Unknown commands, RPATH, weak/reexport/upward/lazy
loads, missing commands, malformed lengths, and truncated referenced file ranges
are rejected. The admitted modern command layouts come from Apple's selected
SDK `mach-o/loader.h`; the list is deliberately closed.
Segment protections use ordinary read/write/execute bits, with initial access a
subset of maximum access. `__TEXT` initially permits execution; `LC_MAIN` lies in
a file-backed segment with initial execute access. File bytes fit the segment's
virtual size; virtual extents and the entry address cannot overflow. The entry
address derives from `__TEXT` plus `entryoff` and agrees with the selected
file-to-VM mapping, including `SG_HIGHVM` placement.
[Apple dyld entry validation](https://github.com/apple-oss-distributions/dyld/blob/main/common/MachOAnalyzer.cpp#L566-L593)

Apple's `/usr/bin/file`, `/usr/bin/lipo`, and `/usr/bin/otool -l/-L` must agree
with the checked bytes. Tool warnings, failures, timeouts, excess output, and
unrecognized dependency output fail the gate. The receipt records normalized
argv and hashes of the actual tool output. Tool-output hashes can differ because
the snapshot pathname differs; acceptance and the artifact identity remain
stable.

Bounds are explicit constants: artifact 256 MiB, load commands 1 MiB/4096
commands, each tool output 8 MiB, each tool deadline 30 s. Inspection never
executes the candidate.
Git and Apple inspector output use one shared live capture mechanism, with
independent stdout/stderr caps and one drain/reap deadline. Overflow kills the
owned direct producer before bounded cleanup. OS cleanup failure remains visible
as a secondary note on the primary error. No temporary disk capture is used.
Receipt bytes are closed in a private directory beside the destination, then
published by an atomic hard link without replacement. Existing files and artifact
aliases are never overwritten. Failed writes leave the final path absent and
preserve the primary error through close/staging cleanup failures. If publication
completes before staging cleanup fails, exit 1 reports `receipt_publication` as
`published`; the complete physical receipt remains intact. No power-loss durability
or concurrent same-user staging mutation claim is made.

## Laws and reference models

- Acceptance is idempotent for fixed artifact bytes, profile, and inspection
  tools. Rechecking produces the same decision and artifact hash.
- The import policy is the set predicate `D ⊆ {libSystem}`. If it rejects `D`,
  it rejects every superset of `D`. An empty import set satisfies this policy;
  executable structural obligations are separate.
- Changing inspected bytes changes the hash identity, subject to SHA-256's
  collision assumption. Reusing a pathname does not reuse a receipt's authority.
- The framing model is a bounded sequence of commands whose lengths sum exactly
  to the header's command-byte count. Every interpreted file range must lie
  within the observed snapshot.
- Receipt publication preserves an existing destination. Before publication,
  write/close failure leaves the destination absent; after publication, cleanup
  failure preserves the complete bytes and reports the published outcome.

## Native controls

`python3 ocaml/test/release_check_test.py -v` and the same command with `-O`
compile physical fixtures with selected Appleclang and SDK 26.5. The system-only
fixture must pass and execute successfully. Actual foreign and weak dylib
imports, RPATH, a minimum-15.0 build, a `vtool`-changed SDK-26.4 executable, and
malformed/truncated/unknown-command artifacts must fail. The independent set
oracle checks the import law. CLI controls check JSON receipts and errors.
The parser also runs 10,000 reproducible byte/truncation mutations with seed
`0x53594d50484f4e59`, plus a curated non-ASCII name regression. This is seeded
coverage, not instrumented AFL/Crowbar fuzzing or an exhaustive malformed-input
proof.
Native controls explicitly require macOS and SDK 26.5; skipping them elsewhere
is not native release evidence.
The macOS CI job sets `SYMPHONY_REQUIRE_NATIVE=1`, making missing SDK/tool
availability a failure. Local unsupported hosts and Linux retain explicit skips.

`ocaml/fuzz/release_macho.py INPUT` is a separate bounded AFL file harness.
It accepts at most 64 KiB, parses only bytes, treats checked `Rejected` values as
normal, and aborts on an unexpected parser exception. It never launches the
candidate or an inspection tool. The input cap is narrower than the release
artifact cap. Run AFL with `-G 65536` to respect this harness contract.

On 2026-10-01, actual AFL++ 4.35c `-n` campaigns completed 45 s each: 807 executions
with mixed seeds, 742 with a valid Mach-O seed alone; zero crashes/hangs. The
mixed campaign selected a truncated-header seed after dry-run, so the second
campaign exercised mutation from the valid framing. An injected defect produced
SIGABRT in both Python modes. This is blind mutation without coverage
instrumentation or a persistent forkserver. The initial sandbox run failed
`shmat` before fuzzing; successful scoped runs used unconfined execution without
OS or tool safety-check changes.

The existing development Symphony executable was rejected before a positive
fixture claim: it imported
`/opt/homebrew/opt/gmp/lib/libgmp.10.dylib`. Its minimum/SDK were already 26.0/26.5.

The new release profile boundary has its own pure harness,
`ocaml/fuzz/release_profile.py INPUT`, with the same 64 KiB bound. It decodes JSON
and validates all published profile fields; it never calls Git, prepares files or
publishes inputs. Actual AFL++ 4.35c blind mutation from the real profile seed
completed 45 s/698 executions with zero crashes/hangs. Injected unnamed errors
and defects abort; checked JSON/profile failures are normal outcomes. A separate
10,000-case directed validator campaign checks malformed shapes and valid order
permutations against its input model, without invoking effects.

Six portable harness controls drive 20 real child scenarios per Python mode.
They observe child optimization directly, require SIGABRT for unexpected errors,
check exact/+1-byte bounds, bind the production decoder, and trap forbidden
effects. Core dumps are disabled.

## Review repair evidence

The revised gate passes 26 physical-verifier, 20 materializer, nine live capture
and six fuzz-harness controls per Python mode. The macOS run requires native
SDK availability. Actual failing controls preceded fixes for segment permissions,
entry mapping, destructive receipt aliases, unbounded producer output,
unchecked profile fields, duplicate keys, unresolved escaped tokens and missing
pkgconf installation steps, virtual mapping and atomic receipt publication.
Successful materialization publishes the validated value, eliminating disagreement
between checked and emitted JSON.

The revised native process control accepts only the frozen driver's exact
documented Darwin cleanup result. It verifies timer wake before KILL, direct-child
reap and workspace lease release. Production code is unchanged. A fresh isolated
release-profile rebuild passes 51 kernel, seven Host and 21 HTTPS cases per mode;
this supersedes the earlier 78-case native observation below.

After the entry/permission repairs, the Mach-O harness completed another 45 s
campaign with 767 executions and zero crashes/hangs. The receipt binds the sources
used at that phase; later diagnostic-only changes are tested separately.
The complete profile decoder/validator and its production-bound harness completed
a fresh 45 s campaign with 724 executions and zero crashes/hangs. Its receipt
binds the final decoder, shared helper, profile, harness and harness-control bytes.
The final mapped Mach-O parser completed 431 executions in another 45 s, without
crashes/hangs. That phase also checked the unchanged application artifact.
All campaigns use blind mutation.

The temporary qualification tree, application binary and local receipts later
disappeared; the cause is unknown. The committed hashes and observations above
remain historical evidence, not currently available artifacts. Fresh final-source
controls are retained under the ignored `_build/release-evidence/` directory:
26 verifier controls per mode and a new native toy fixture, plus 798 Mach-O and
824 profile blind AFL executions in 45 s each without crashes/hangs. Forty profile
classification/effect controls pass across normal and optimized children.
The application was not rebuilt or
revalidated in this replacement phase. Hosted native artifacts remain separately
downloadable from their recorded GitHub Actions runs.

## Observed Symphony build

This observation used Mirage Crypto1.2.0, now covered by OSEC-2026-14/15/17.
It is historical evidence and cannot qualify the current2.4.1 dependency graph.
The archived materializer requires explicit historical replay and labels affected
inputs. See the [security refresh](crypto-security-plan.md).

The isolated arm64 build uses fresh OCaml 5.5.0, GMP 6.3.0 and locked application
dependencies. Its compiler saves minimum 26.0/SDK 26.5 flags in the C driver;
compiler cloning and compression are disabled. Every vendor archive reproduces
committed Git bytes. The development switch and installed packages are unchanged.
See [preserved inputs](../../ocaml/release/README.md).

Both the original Dune executable and an evidence link pass physical closure:

| Artifact | Bytes | SHA256 |
| --- | ---: | --- |
| Dune output |12889176| `590f89dcb80fcbe69964699de020dec067524d697ea0e88f6c0eec84eb74b5f7` |
| Evidence link |12889176| `0d5695083fd61430b31d4e892fe15eacd07b59ec1615f005acf1c9531b020d17` |

The evidence link changes only output and evidence flags; Dune's successful
output is readonly and is preserved. The actual C argv orders `-lzarith`, the
exact GMP archive, and the runtime at positions 140/141/142. The link map selects
239 objects from that GMP archive, whose SHA256 is
`ecb8610cb3256de009b910acc6b75f53ecfc0c1dd70335b172fb49a1fa0cf016`.
At the observed build/link boundary, all 818 recorded files matched
`4e2d6ac2b7d6bb84a02e32254e74218d49e646a6`. Later release-tool/documentation
changes are tested separately; this binary is not an attestation of those files.

The fresh profile passes 241 core cases. A copied sole evidence executable passes
63 CLI scenarios normally and optimized with an empty HOME and child PATH
`/usr/bin:/bin`; its Python test controller uses the existing Homebrew Python.
The release-profile native binaries pass 50 kernel, seven Host and 21 HTTPS cases
in each mode. These tests ran on the existing macOS 26.5.1 host, not a clean
macOS 26.0 host. They do not certify minimum-host execution, byte reproducibility,
Linux musl or a complete service release.

The [machine-readable observation](release-observation.json) records artifact
identity, selected archive, link-map hash, tests and explicit pending gates.

Retained receipts: `/private/tmp/symphony-release-target/mac-arm64-26.0/`,
`/private/tmp/symphony-release-cli-_0a52kqh/runtime.json`, and
`/private/tmp/symphony-release-afl-3izjc7np/receipt.json`.

## Claim boundary

This is physical binary-closure evidence. It does not prove compiler source,
compiler configuration, selected GMP archive, link argv/map, source tree,
runtime correctness, code-signature validity, or a library's runtime `dlopen`
behavior. Build and link provenance belong in a separate, independently checked
receipt. libSystem/dyld remain operating-system dependencies. Same-user mutation
of verifier code, tools, or private snapshots is outside this custody boundary.
