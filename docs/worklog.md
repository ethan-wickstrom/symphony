# OCaml implementation worklog

## Goal

Readable OCaml 5/Eio Symphony: a static Linux musl release, macOS deployment,
Section 17 conformance, portable black-box harness, immutable orchestrator checked
against an independent model, replayable simulation, parser fuzzing and measured
1,000-session capacity. Operator API, doctor/dry-run and module laws are deliverables.

## Constraints

- Approved P01–P08/D01–D13, signatures, policies and vertical-slice build order.
- Linear first; spec RFC 2119 requirements; generated Codex schema wins wire details.
- One scheduling owner; explicit Eio capabilities; checked identifiers and shared Path brand.
- Every `.ml` has an `.mli`; fatal enabled warnings; no objects/Lwt/Async/casts.
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

Branch `ethan/ocaml-workspaces`; open PR #2 is attached (currently not a draft). Main remains `f56a66c`.
Published delivery head is `b30263e`; commits include
`77073ae` (cleanup ownership), `daf839c` (clock/hook policy), `a6d7118` (native
ownership) and `48770fb` (inspection CLI). All owned workflows pass on the delivery
head; a fresh Copilot review is pending. No user decision or approval is pending.

Independent review is complete for native Directory/Path/Gate/Store/Process/Host.
Remaining work: publish hosted evidence, finish current-code review, then merge
slice 2. Do not begin the tracker adapter before that. Devin analysis is unavailable
because the diff exceeds its size limit; regeneration confirmed that cause.

## Current local evidence

- macOS arm64; OCaml 5.5.0, Dune 3.24.0, ocamlformat 0.28.1.
- Build and formatting pass; core: 122 cases, 39 properties and 41,500 samples.
- 27 real CLI scenarios pass normally and optimized, including workspace ownership,
  absence, contention, scope/ID conflicts, symlinks, redaction and terminal escaping.
- Source gate: 178 source/interface files; 34 positive/negative controls pass.
- Protocol snapshot/digests pass normally and optimized; 16 corrupted controls reject.
- Crowbar seed `20260930`: 15 groups × 10,000 = 150,000 invocations pass.
  This is a random/curated campaign, not an instrumented AFL coverage result.
- Focused native gates: Directory 17, Store 11, Process 8, lifetime 7, IO classifier 4,
  public Host 7. Lifetime checks 1,000 Eio mock seeds and explicit seed619 replay.
  Complete watchdog runs pass normally and optimized (47 kernel + seven Host).
  Eight timeout/INT/TERM/admission/normal-exit/signal controls pass on both hosts.
- Full `just check` passes; final isolated-bootstrap changes passed both native
  runners and complete watchdog controls again in both optimization modes.
- Pinned Elixir 1.19.5/OTP28 gate: 302 tests, six skipped, measured100% coverage,
  formatting, lint and Dialyzer pass. No unrelated compiler/library upgrade.
- mtime/cstruct are direct imports already present through Eio. Lock regenerated;
  no global opam switch changed and no machine-specific URLs entered the lock.
- PR run 36840015440 and push run 36840011609 passed at `b30263e` on Linux/glibc
  and macOS. Downloaded artifacts match 56 selected native sources, watchdog/helper
  and all nine frozen Eio hashes. Modes 0/1 each pass 47+7 native cases. Each custody
  run passed 5,000 scenarios and 2,000 normal closures with zero cleanup EPERM.

## Retained evidence

- `/private/tmp/symphony-workspace-pure-check.log`
- `/private/tmp/symphony-workspace-{build,source,fuzz}-final.log`
- `/private/tmp/symphony-store-close-defect-{red,green}.log`
- `/private/tmp/symphony-native-io-sys-error-{red,green}.log`
- `/private/tmp/symphony-native-process-lifetime-{red,green}.log`
- `/private/tmp/symphony-owner-filter-all.log`
- `/private/tmp/symphony-native-delivery-normal-6ycsgo62/manifest.json`
- `/private/tmp/symphony-native-delivery-optimized-js58hbqy/manifest.json`
- `/private/tmp/symphony-workspace-check-final.log`
- `/private/tmp/symphony-watchdog-controls-delivery-{normal,optimized}.log`
- `/private/tmp/symphony-hosted-b30263e/verification.json`
- `/private/tmp/symphony-pr2-review-size-limit.jpg`
- Frozen process evidence/provenance: `vendor/eio/PATCHES.md`.

## Boundaries

Sampled laws are not proofs. The seeded lifetime test is not yet whole-service
simulation. Descriptor APIs and protected metadata assume a cooperating host;
POSIX final unlink/rmdir cannot condition on inode, and same-device bind mounts
need host policy. Escaped process groups/credentials require stronger isolation.
POSIX provides no finite kernel reap bound. Eio1.6 release-hook backtraces may be
empty; primary exception traces are preserved. Static linkage, live tracker/agent,
HTTP API, orchestrator simulation, benchmarks and portable harness remain unverified.

## Steering

Repeated acceptance approved recommendations, signatures and implementation.
CLI0.159.2 supersedes the previous0.153.4 audit. The full book repository supersedes
sample-only research. GitHub detachment is verified (`isFork=false`, `parent=null`);
only origin/default repository `ethan-wickstrom/symphony` remains. Specification
links retain provenance. Latest autonomy instruction authorizes architectural
repairs and rapid iteration, superseding needless permission stops while preserving
safety boundaries, verification and green vertical-slice delivery.
