# OCaml implementation worklog

## Goal

Readable OCaml 5/Eio Symphony: a static Linux musl release, macOS deployment,
Section 17 conformance, portable black-box harness, immutable orchestrator checked
against an independent model, replayable simulation, parser fuzzing and measured
1,000-session capacity. Operator API, doctor/dry-run and module laws are deliverables.

## Constraints

- Approved P01–P08/D01–D14, signatures, policies and vertical-slice build order.
- Linear first; spec RFC 2119 requirements; generated Codex schema wins wire details.
- One scheduling owner; explicit Eio capabilities; checked identifiers and shared Path brand.
- Every application `.ml` has an `.mli`; fatal enabled warnings; no objects/Lwt/Async/casts.
- Tracker/repository data is untrusted. Only trusted configuration enters Bash.
- Develop/publish only to `ethan-wickstrom/symphony`; browser means in-app Browser.
- Finish, review and merge each green slice before starting the next.

## Completed

- Read the full spec at `be10a1b79df723d6d7612b5651c8522704dafb2e`, READMEs,
  authoritative OCaml sources and the full Algebra-Driven Design manuscript.
- Regenerated/audited Codex 0.159.2 stable and experimental schemas (754 JSON files);
  retained selected definitions, provenance/digests and normal/optimized drift controls.
- Slice 1 merged as PR #1 at `f56a66c906925f050edd055d09226d29c8e2ed91`.
  Workflow/config/template/reload and offline commands passed hosted Linux/macOS gates.
- Slice 2 merged as PR #2 at `92f7ac670bb90fae2c21ab1a4a1523a1edde5112`.
  Native ownership, scoped hooks/processes and inspection passed both host workflows.
- Slice 3 merged as [PR #3](https://github.com/ethan-wickstrom/symphony/pull/3)
  at `98833b39c59a2def4257ac5ac9e405e1010554ca` on `2026-10-01T15:36:13Z`.
  Linear reads and native HTTPS inspection passed local and hosted Linux/macOS gates.
- Slice 2 keys, frozen references, opaque issue-ID ownership and strict bounded
  owner codec; independent models, hash vectors and parser fuzz targets.
- Frozen Eio custody/admission extension and worker controls passed local macOS and
  hosted Linux/glibc/macOS. All nine hosted source hashes matched the frozen manifest.
- Native anchored Directory, permanent flock, exact owner fencing and bounded
  removal. Fresh directory authority enables safe failed-publication rollback.
- One lifetime gate revokes, cancels and joins workspace loans/process operations.
  Captured primary outcomes stay outside Eio's IO exception aggregation.
- Native Process, four hooks and the public Host. Host hides raw lease/remove
  authority, eliminating public self-join. Store retirement attempts safe removal
  after join defects; physical outcome is cached before reporting/propagation.
- Shared native IO classifier preserves worker defects and original backtraces.
- `workspace` CLI validates existing ownership without creation or hook execution.
- Cleanup PR ownership now verifies repository/owner as well as branch name.

## Current focus

Branch `ethan/static-release` starts from merged `98833b3`.
The isolated macOS arm64 build now passes physical closure, observed link,
copied-artifact CLI and native process/HTTPS checks: minimum 26.0/SDK 26.5,
only libSystem imported, exact static GMP archive.
Reviewed input decoder/materializer controls are green. Next: publish and merge
the foundation. Clean-host execution and Linux musl remain release gates.
Plans: `docs/design/static-release-plan.md`, then
`docs/design/slice-4-orchestrator-plan.md`.
No user approval is pending under the accepted recommendations/autonomy instruction.

## Current release foundation evidence

- Fresh opam 2.5.2 root, OCaml 5.5.0 source build with compiler cloning disabled,
  no compression, and explicit target flags in the compiler's saved C driver.
  No development CMIs, native archives or Dune cache are reused.
- GMP 6.3.0 source/hash verified; static PIC archive built for generic armv8-a,
  all 525 members target 26.0; upstream 177 tests pass and one skips.
  Whole compiler/application CPU baseline is Apple M1.
- Release-local pkgconf-lite 3.0.7 passes 253 tests with 11 declared skips.
  Zarith 1.14 records the owned GMP archive; conf probes have no ambient fallback.
- All locked dependencies build. Five vendor pins use immutable checksum archives;
  all 540 archived files/modes match committed Git blobs. All nine frozen Eio
  hashes match both source and build trees.
- Dune release build passes. Original executable SHA256:
  `590f89dcb80fcbe69964699de020dec067524d697ea0e88f6c0eec84eb74b5f7`.
  Evidence link uses a fresh output because Dune's successful output is readonly;
  only output/evidence flags change. Both executables pass physical closure.
- Evidence executable:12889176 bytes, SHA256
  `0d5695083fd61430b31d4e892fe15eacd07b59ec1615f005acf1c9531b020d17`.
  Actual C link orders Zarith/GMP/runtime at argv 140/141/142; map selects 239 GMP
  objects. All 818 recorded files matched the qualification commit at that
  observed build/link boundary; later tool/docs changes are separate.
- Copied sole evidence executable passes 63 CLI scenarios normally/optimized with
  empty HOME and child PATH excluding Homebrew/opam. Existing macOS 26.5.1 host;
  this is not clean-host or minimum-host evidence.
- Fresh profile passes 241 core cases and 78 native cases per mode; both manifests
  bind 156 selected source hashes. Native process/cancellation/HTTPS are green.
- A real malformed-name decoder escape went red before the checked parser fix.
  Verifier 14 controls pass normally/optimized, including two portable controls.
  Actual AFL++ 4.35c blind mutation: 1549 executions in 90 s, zero crashes/hangs;
  injected unexpected defect aborts. Initial sandbox shmat failure is retained.
  No instrumented coverage or persistent-forkserver claim.
- Receipts and actual link map:
  `/private/tmp/symphony-release-target/mac-arm64-26.0/`.
  Native inputs, qualified requests and complete ten-recipe hashes:
  `/private/tmp/symphony-release-inputs-djwlgpqp/`.
- Copied executable receipt: `/private/tmp/symphony-release-cli-_0a52kqh/runtime.json`.
  AFL receipt: `/private/tmp/symphony-release-afl-3izjc7np/receipt.json`.
- Preserved 13 exact recipes and four vendor archives. Materializer 13 controls
  pass normally/optimized; real shallow-checkout, malformed-profile/boolean-schema
  and symlink controls went red before fixes. A pure 10,000-case validator campaign
  has zero escapes or model disagreements. Final descriptor/FIFO audit is green.
  `just release-tools` passes; required pinned Elixir `make all` also passes.
- The profile boundary also passes actual AFL blind mutation:698 executions/45 s,
  no crashes/hangs, with injected defects and effect guards checked.
  Receipt: `/private/tmp/symphony-release-profile-afl-35ahyeeu/receipt.json`.
- Six portable harness tests drive 19 real child scenarios per mode, including
  six unexpected-error aborts, exact byte bounds and effect guards. Core dumps
  are disabled. Both modes pass; Linux/macOS CI runs these controls.

## Last merged slice evidence

Slice 3 provides explicit Linear inspection over verified HTTPS, tested through
the actual adapter against a loopback HTTPS fake with an explicit CA.

Implemented ordered issue batches, frozen registry bindings, Linear envelope/record/
page parsing and atomic pagination. Independent list/query models cover these paths.
A generic exact deadline joins losing work before converting its outcome.
Native HTTPS passes 21 controls; the real inspection binary passes 19 loopback HTTPS
scenarios, including peer verification, pagination, redaction and atomic failures.
The existing 27 workflow/workspace CLI scenarios remain green. Four independent
pagination budgets now have precise boundary controls. H1's narrow framing repairs
pass eleven examples and 1,000 property samples; its frozen-source gate passes.
Configuration and IO capture remain pure; explicit reads activate network/trust/crypto.
Every registry shares one deferred host crypto witness. Overlapping paginated
reads no longer replace the process RNG. Compiler-target CA defaults select the
macOS or Linux system bundle; explicit overrides retain their precedence.
Both review repairs have real failing controls before their fixes.

An abstract public environment now eliminates exact credential reuse through
ordinary config fields, JSON assembly, diagnostics and child aliases. Deferred
agent policies retain only opaque quarantine rules and return checked failures.
Fresh checked read policy is separate from frozen provider/auth settings; terminal
reloads update blocker decisions without rotating an existing run's credentials.
Independent review found no remaining blocker in these contracts.

Final serial gates pass: 241 core cases (61 properties), 63 CLI scenarios,
78 native cases per mode, 235 source/interface files, 39 source controls,
16 protocol corruption controls and 22 Crowbar groups × 10,000 invocations.
Both final local native manifests bind 156 selected source hashes and the runner/sentinel.
An overlapping gate run failed child publication and an Elixir response timeout;
its cause remains unproven. A deliberate startup delay reproduced the watchdog
fixture race. Bounded READY admission fixes that control without changing the
production timeout or PID probes. Normal/optimized full controls now pass.
Pinned Elixir passes alone: 302 tests, six skips, coverage/lint/Dialyzer green.
The sandbox blocks PID-specific `ps` probes, so native validation runs outside it.
Framing provenance passes six corruption controls in both Python modes.
Final review found that the first native manifests predated the source-inventory
expansion. Both native modes were rerun successfully with the final runner;
the new evidence binds the expanded domain/IO/workflow source inventory.

Final [PR run 36883354256](https://github.com/ethan-wickstrom/symphony/actions/runs/36883354256)
and [push run 36883346701](https://github.com/ethan-wickstrom/symphony/actions/runs/36883346701)
passed on Linux/glibc and macOS at
`06ce6c577c48142b7fb89cf8223c3c35acdf0184`, the exact merged PR head.
Four hosted native manifests match all 156 selected committed Git blobs,
watchdog/sentinel hashes and modes 0/1, with status 0 and 50+7+21 cases each.
Both frozen custody manifests match all nine Eio hashes and 5,000 scenarios per
host. Linux records 2,000 normal closes, zero cleanup EPERM and zero repeated-signal
EPERM values; macOS records 1,999 normal closes, one conservative cleanup EPERM
and 31 repeated-signal EPERM values. Both retain 2,000 stable explicit close outcomes.
Focused custody/admission controls pass. Binary hashes are recorded context only;
archives exclude executables and provide no source-to-binary attestation.
Hosted verification and both final local source receipts have zero mismatches.
Plan: `docs/design/slice-3-tracker-plan.md`.

## Previous slice-two evidence

Slice 2's final hook repair (`98e9d6a`) carries caller errors directly through Process
and Path. Four hook controls went red/green; three native controls check identity,
mapper suppression and conversion after reap. Independent review and current-head
Copilot found no remaining finding; all three review threads are resolved. Devin
analysis was unavailable at its diff-size limit; Sourcery exceeded its file limit.

- macOS arm64; OCaml 5.5.0, Dune 3.24.0, ocamlformat 0.28.1.
- Build and formatting pass; core: 126 cases, 39 properties and 41,500 samples.
- 27 real CLI scenarios pass normally and optimized, including workspace ownership,
  absence, contention, scope/ID conflicts, symlinks, redaction and terminal escaping.
- Source gate: 178 source/interface files; 34 positive/negative controls pass.
- Protocol snapshot/digests pass normally and optimized; 16 corrupted controls reject.
- Crowbar seed `20260930`: 15 groups × 10,000 = 150,000 invocations pass.
  This is a random/curated campaign, not an instrumented AFL coverage result.
- Focused native gates: Directory 17, Store 11, Process 11, lifetime 7, IO classifier 4,
  public Host 7. Lifetime checks 1,000 Eio mock seeds and explicit seed619 replay.
  Complete watchdog runs pass normally and optimized (50 kernel + seven Host).
  Eight timeout/INT/TERM/admission/normal-exit/signal controls pass on both hosts.
- Full `just check` passes; final isolated-bootstrap changes passed both native
  runners and complete watchdog controls again in both optimization modes.
- Pinned Elixir 1.19.5/OTP28 gate: 302 tests, six skipped, measured100% coverage,
  formatting, lint and Dialyzer pass. No unrelated compiler/library upgrade.
- mtime/cstruct are direct imports already present through Eio. Lock regenerated;
  no global opam switch changed and no machine-specific URLs entered the lock.
- Final PR run 36844689498 and push run 36844682548 passed at `98e9d6a` on
  Linux/glibc and macOS. Four artifacts match 56 selected native sources and both
  runner hashes; modes 0/1 each pass 50+7 cases. Both frozen manifests match nine
  Eio hashes and 5,000 scenarios. Linux has 2,000 successful close outcomes;
  macOS has 1,999 successes plus one conservative EPERM error. The frozen contract
  preserves that error; 73 repeated-signal permission errors also remain visible.

## Retained evidence

- `/private/tmp/symphony-workspace-pure-check.log`
- `/private/tmp/symphony-workspace-{build,source,fuzz}-final.log`
- `/private/tmp/symphony-store-close-defect-{red,green}.log`
- `/private/tmp/symphony-native-io-sys-error-{red,green}.log`
- `/private/tmp/symphony-native-process-lifetime-{red,green}.log`
- `/private/tmp/symphony-hooks-cleanup-{red,green}.log`
- `/private/tmp/symphony-hooks-precedence-check-unconfined.log`
- `/private/tmp/symphony-native-generic-green/manifest.json`
- `/private/tmp/symphony-owner-filter-all.log`
- `/private/tmp/symphony-native-delivery-normal-6ycsgo62/manifest.json`
- `/private/tmp/symphony-native-delivery-optimized-js58hbqy/manifest.json`
- `/private/tmp/symphony-workspace-check-final.log`
- `/private/tmp/symphony-watchdog-controls-delivery-{normal,optimized}.log`
- `/private/tmp/symphony-hosted-b30263e/verification.json`
- `/private/tmp/symphony-hosted-98e9d6a/verification.json`
- `/private/tmp/symphony-pr2-review-size-limit.jpg`
- `/private/tmp/symphony-pr2-merged.jpg`
- Frozen process evidence/provenance: `vendor/eio/PATCHES.md`.
- `/private/tmp/symphony-slice3-full-check-unconfined.log`
- `/private/tmp/symphony-slice3-fuzz-final.log`
- `/private/tmp/symphony-public-config-json-{red,green}.log`
- `/private/tmp/symphony-public-tracker-cli-green-2.log`
- `/private/tmp/symphony-cli-secret-quarantine-red.log`
- `/private/tmp/symphony-source-scope-{red,green}.log`
- `/private/tmp/symphony-native-http-wire-{red,green}.log`
- `/private/tmp/symphony-slice3-elixir-pinned-gate.log`
- `/private/tmp/symphony-slice3-final-native/manifest.json`
- `/private/tmp/symphony-slice3-final-native-optimized/manifest.json`
- `/private/tmp/symphony-slice3-reviewed-serial-check.log`
- `/private/tmp/symphony-slice3-reviewed-fuzz.log`
- `/private/tmp/symphony-slice3-reviewed-elixir-isolated.log`
- `/private/tmp/symphony-slice3-reviewed-native/manifest.json`
- `/private/tmp/symphony-slice3-reviewed-native-optimized/manifest.json`
- `/private/tmp/symphony-hosted-06ce6c5/verification.json`
- `/private/tmp/symphony-hosted-06ce6c5/local-source-verification.json`
- `/private/tmp/symphony-watchdog-admission-red-receipt.json`
- `/private/tmp/symphony-watchdog-admission-green-optimized.log`
- `/private/tmp/symphony-ca-default-linux-red.log`
- `/private/tmp/symphony-registry-crypto-red.log`

## Boundaries

Sampled laws are not proofs. The seeded lifetime test is not yet whole-service
simulation. Descriptor APIs and protected metadata assume a cooperating host;
POSIX final unlink/rmdir cannot condition on inode, and same-device bind mounts
need host policy. Escaped process groups/credentials require stronger isolation.
POSIX provides no finite kernel reap bound. Eio1.6 release-hook backtraces may be
empty; primary exception traces are preserved. Linux static linkage, clean-host
deployment, live tracker/agent, HTTP API, orchestrator simulation, benchmarks and
portable harness remain unverified.

## Steering

Repeated acceptance approved recommendations, signatures and implementation.
CLI0.159.2 supersedes the previous0.153.4 audit. The full book repository supersedes
sample-only research. GitHub detachment is verified (`isFork=false`, `parent=null`);
only origin/default repository `ethan-wickstrom/symphony` remains. Specification
links retain provenance. Latest autonomy instruction authorizes architectural
repairs and rapid iteration, superseding needless permission stops while preserving
safety boundaries, verification and green vertical-slice delivery.
