# OCaml implementation worklog

## Goal and success criteria

Readable OCaml 5 Symphony: one static Linux release binary, Section 17 core
conformance, a portable black-box conformance package, and a pure orchestrator
checked against an executable model, seeded Eio simulation and parser fuzzers.
Deliver the operator API, doctor/dry-run, module laws and a 1,000-session benchmark.

## Active constraints

- Spec RFC 2119 requirements; generated Codex schema wins wire details.
- Approved P01–P08/D01–D13, component contracts, laws, dependency choices and build order.
- Linear first; macOS development/deployment and Linux musl static release.
- Immutable pure core, one state owner, Eio capabilities/structured concurrency at edges.
- Every application `.ml` has an `.mli`; fatal enabled warnings, no objects/Lwt/Async/casts.
- Untrusted tracker/repository data; trusted verbatim hook/agent command configuration.
- Small green slices, independent models, matching Section 17 examples and conformance map.

## Completed

- Read all 2,312 specification lines at upstream commit
  `be10a1b79df723d6d7612b5651c8522704dafb2e`, both READMEs and authoritative design sources.
- Audited every implementation-defined occurrence and recorded accepted policies/gaps.
- Regenerated Codex 0.159.2 stable/experimental schemas after the user's update;
  inspected all 754 JSON files/references and the complete delta from 0.153.4.
  Retained selected policy schemas, hashes and a drift check in the repository.
- Original 55 interfaces and assembly witness type-checked on OCaml 5.5/5.3.
- Created an isolated OCaml 5.5.0 project switch, installed the slice 1 dependency stack,
  generated the transitive opam lock and pinned ocamlformat 0.28.1.
- Implemented bounded YAML/workflow loading, typed configuration/environment/path
  resolution, strict bounded templates, pure last-good reload and offline CLI.
- Refined pure `Tracker.CONFIG` before implementation; live `Tracker.S` extends it.
  Typed registry equality preserves credentials without exposing or reparsing them.
- Patched native YAML scope/NUL defects with retained source provenance/regressions.
- Added independent parser/config/template/numeric/registry models, examples,
  actual CLI/file IO checks, fuzz targets and Linux/macOS CI definitions.
- Independent review found failing path/coercion/policy/diagnostic cases before fixes.
  Corrected the mistaken YAML underscore oracle against the YAML 1.2 core schema.

## Current focus

Slice 1 merged as PR #1 at `f56a66c906925f050edd055d09226d29c8e2ed91`.
Final head `b35370e` passed hosted Linux/macOS builds, models, CLI/source/format
gates, seeded fuzzing and Elixir. Every review thread is resolved; the final
Codex review found no major issues. Slice 2 starts on `ethan/ocaml-workspaces`.
Checked keys are implemented and independently reviewed. Live directory ownership,
hooks and workspace inspection remain pending. The Eio group-custody source patch
is under host testing and is not yet installed into the application switch.

## Verified locally

- macOS arm64; OCaml 5.5.0, Dune 3.24.0, ocamlformat 0.28.1.
- `just check` passed: build, fatal enabled warnings, formatting and all checks below.
- 70 Alcotest cases: 48 examples and 22 properties, 16,500 generated model/law cases.
- 19 CLI scenarios: workflow paths/default/anchoring, strict rendering/attempts,
  literal issue text, metadata, actionable errors, redaction and bounded file reads.
- Generated policy snapshot/digest check passed.
- Compiler-AST source gate checked 96 application source/interface files;
  all 34 positive/negative controls passed.
- Crowbar seed `20260930`: 13 groups × 10,000 = 130,000 invocations passed
  after all production fixes, including combined issue-fixture parsing/rendering.
  A separate 12 × 1,000 smoke campaign passed. These are random/curated cases,
  not an instrumented AFL coverage result.
- Locked dependency installation with both source pins completed with no changes.
- Final independent review fixed malformed URI acceptance, substituted credential
  leakage in tracker-kind errors, missing attempt diagnostics and oversized JSON
  composition allocation. Each had a failing regression before its fix.
- ast-grep has no OCaml grammar; the compiler parses/type-checks OCaml source.
- PR review reproduced Python optimization bypasses in both verification scripts
  and a delimiter-prefix parsing failure before fixes. Real CLI/schema checks now
  run normally and optimized; 16 broken fixtures verify the gates still reject,
  including missing/extra manifest entries and malformed digests.
  Signed radix strings remain strings under YAML 1.2 Core, with explicit cases.
- Assigned/unassigned metadata roundtrips and renders through the actual CLI.
  All 15 normalized issue fields are covered; missing/malformed fixture eligibility
  fails instead of inventing dispatchability. Both defects failed before correction.
- The live PR badge validates only with one ordered complete marker pair; orphan,
  reversed and repeated markers fail. The Elixir gauntlet
  passed with Elixir 1.19.5/OTP 28: 301 tests, six skipped, 100% coverage and no
  lint/type errors. An unchanged retry-timing test failed once, then passed on rerun.

Sampled laws are evidence, not machine-checked proofs. Native YAML scope tests do
not prove native leak freedom. AFL coverage, static linkage, live tracker/agent
integration, simulation and benchmarks remain unverified. Hosted
Linux/macOS checks passed at `c7cc6ff`; the Ubuntu setup action disabled its own
opam build sandbox after bwrap failed, so this is no build-isolation claim.

## Next action

Refine slice 2 signatures before implementation: created/reused acquisition,
non-creating cleanup lookup, deletion under the acquired lease, and observed
process exit. Preserve Workspace/Agent/Transport path and reference equalities.
Keys, ownership and hooks use independent filesystem/process models.

Installed Eio immediately reaps process leaders. A raw group signal after an
exit-status check races with identifier reuse; it cannot implement the promised
safe group lifetime. Evaluate a minimal scoped Eio group capability that observes
exit without reaping until group cleanup. No user decision is pending.

## Slice 2 evidence

- Key construction follows its interface and independent byte-list policy model.
  Thirteen separately generated Python SHA-256 whole-output vectors match.
- The combined check passes: 77 tests, 21,500 model/law cases, 19 CLI scenarios
  normally/optimized, 102 paired source files, 34 source and 16 corruption controls.
- Crowbar seed `20260930`: 14 × 10,000 = 140,000 invocations pass, including
  exact changed/unchanged key length boundaries. Formatting and locked install pass.
- Refined 56 component/support sketches plus assembly witness type-check on 5.5.
  Temporary copies normalize pre-existing blueprint doc attachment; live source
  interfaces pass the normal fatal-warning/format gate without that normalization.
- The old process API's early-leader-exit/remaining-descendant failure was reproduced
  on macOS before patching. A zombie-only group exposes a Darwin EPERM edge case;
  replacement behavior and Linux portability remain under verification.

These are key and interface results, not workspace containment or hook conformance.

## Steering and superseded instructions

The initial before-code approval gates were explicit. The CLI update requested a
new protocol audit; 0.159.2 supersedes 0.153.4 evidence. Acceptance selected all
recommendations, Linear and the macOS/Linux targets. "Proceed. I accept all
recommendations" approved the complete signature/design package and authorized
implementation. No slice 1 approval gate remains.
