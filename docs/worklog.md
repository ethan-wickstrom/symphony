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

Slice 1 is published as PR #1 on `ethan/ocaml-workflow`. Hosted Linux/macOS builds,
models, CLI/source/format gates, seeded fuzzing and Elixir passed at `c7cc6ff`.
The second review fixes pass locally, including a fresh 130,000-case campaign;
the final head must pass hosted checks and merge before slice 2.

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

Hosted CI and merge precede slice 2. Its scope is collision-resistant workspace
keys, checked filesystem containment, scoped ownership/locks and hooks with
independent filesystem/process models. No user decision is pending.

## Steering and superseded instructions

The initial before-code approval gates were explicit. The CLI update requested a
new protocol audit; 0.159.2 supersedes 0.153.4 evidence. Acceptance selected all
recommendations, Linear and the macOS/Linux targets. "Proceed. I accept all
recommendations" approved the complete signature/design package and authorized
implementation. No slice 1 approval gate remains.
