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
Frozen references, the strict ownership codec and pure hook policy pass their
independent model/fake suite. Ownership now includes opaque issue IDs to reject
historical identifier reuse. No physical acquisition/ownership claim yet.

## Verified locally

- macOS arm64; OCaml 5.5.0, Dune 3.24.0, ocamlformat 0.28.1.
- `just check` passed: build, fatal enabled warnings, formatting and all checks below.
- Current application gate: 96 Alcotest cases, 63 examples and 33 properties,
  29,500 generated model/law cases. Log: `/private/tmp/symphony-owner-check-final.log`.
- 19 CLI scenarios: workflow paths/default/anchoring, strict rendering/attempts,
  literal issue text, metadata, actionable errors, redaction and bounded file reads.
- Generated policy snapshot/digest check passed.
- Compiler-AST source gate checked 120 application source/interface files;
  all 34 positive/negative controls passed.
- Crowbar seed `20260930`: 15 groups × 10,000 = 150,000 invocations passed,
  including ownership JSON and combined issue-fixture parsing/rendering.
  Log: `/private/tmp/symphony-owner-fuzz.log`. These are random/curated cases,
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

Finish the Eio group custody gate before live directory/hook implementation.
The blocking WNOWAIT observer removed the sampled SIGCHLD hang and passed repeated
5,000-scenario campaigns plus deterministic queued-producer revocation. Review then
reproduced Eio thread-creation failure escaping the suspended fiber's finalizers.
An isolated scheduler correction resumes that continuation with its original error
and preserves cleanup. Reserve one producer before fork, retain it through exit
observation and sole reap, and fence cancellation during launch. This removes the
post-fork thread-allocation failure class. Revised host stress/review is pending.
Preserve uncertain Darwin EPERM as a result; retain the final group KILL sweep.
No user decision is pending. The source patch is not installed or claimed green.

Review the full Algebra-Driven Design manuscript at source commit
`118aa81a48fb46255dfe4503cbcdee6d893098c9`. The main prose manuscript has been read:
introduction, both design/implementation examples, good-algebras, QuickCheck,
QuickSpec, common-algebras and glossary. The review corrected observation/carrier
overclaims and unused Issue sharing; coverage is in docs/design/book-review.md.
Do not equate a delivered termination request with a closed OS process group.

## Slice 2 evidence

- Key construction follows its interface and independent byte-list policy model.
  Thirteen separately generated Python SHA-256 whole-output vectors match.
- The current complete check/fuzz counts are recorded above. Keys include exact
  changed/unchanged length boundaries; owner tests cover record/escaped-encoding
  bounds, canonical int64 bits, strict fields/version and changed issue identity.
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

The user supplied the full Algebra-Driven Design GitHub manuscript. It replaces
the sample-only source and its unavailable-site note, without changing the active
workspace slice or the approved build order.

The manuscript audit removed unused Issue sharing, equated the required Path.t
brand, and made path access checked. The 57-interface assembly witness passed on
OCaml 5.5 after temporary blueprint doc normalization. The identity review added
opaque issue IDs to references and ownership records; it does not restore unused
Issue module sharing. Fake/model tests establish policy and codec observations,
not real filesystem/process safety. The latest acceptance continues the approved
build order without another approval gate.
