# OCaml implementation worklog

## Goal and success criteria

Readable OCaml 5/Eio Symphony: one Linux musl static binary, macOS deployment,
Section 17 conformance, portable black-box harness, independent event model,
replayable whole-service simulation, fuzzed boundaries and measured 1000-session
capacity. Operator API, doctor/dry-run, module laws and adapter profiles ship.

## Active constraints

- Accepted policies/signatures and vertical slices; Linear first.
- Spec RFC 2119 requirements; generated Codex schema wins protocol details.
- One scheduling owner; immutable state; explicit Eio capabilities and type equalities.
- Every application .ml has an .mli; fatal warnings; no objects/Lwt/Async/casts.
- Untrusted tracker/repository input; only trusted configuration enters Bash.
- Develop/publish only to ethan-wickstrom/symphony; in-app Browser only.
- Each checkpoint is reviewed, green and merged before the next implementation.
- Root serializes native/Dune/opam/Elixir gates; independent agents own disjoint work.

## Completed checkpoints

- Full spec, reference intent, OCaml sources and complete Algebra-Driven Design
  manuscript read. Codex 0.159.2 schemas regenerated/audited: 754 JSON definitions
  with provenance/digests and normal/optimized drift controls.
- Slices 1–3: workflow/config/template/reload, native owned workspaces/hooks and
  authenticated Linear HTTPS inspection. PRs #1–#3 merged and hosted gates pass.
- [PR #4](https://github.com/ethan-wickstrom/symphony/pull/4): native release
  foundation. [PR #5](https://github.com/ethan-wickstrom/symphony/pull/5): crypto
  refresh to Mirage 2.4.1; old decoder/TLS failures preceded fixes.
- [PR #6](https://github.com/ethan-wickstrom/symphony/pull/6): exact tokens,
  dispatch preorder, backoff, usage watermark, canonical owner PSQ and launch plans.
- [PR #7](https://github.com/ethan-wickstrom/symphony/pull/7): source-specific
  lifecycle transitions and original-reference cleanup; 24 examples/19 properties.
- [PR #8](https://github.com/ethan-wickstrom/symphony/pull/8): pure scheduling
  reducer and independent event model. Merged 2026-10-02T05:25:59Z as
  5c892db2db23a72bf69cfd1e6179814ec862c045 from b13aa73.
  Startup cleanup, grouped original-binding reconciliation, per-cycle preflight,
  sorted admission, retries, scope drain and shutdown retain closed-resource custody.
  One owner PSQ and one request map store facts; counts/runtime/status are derived.
  Issue-scoped faults retain the current checked issue after owner release.

## Current evidence

- Local orchestration: 45 examples and 27 actual property groups, seed 20261001.
  200 programs of 500–600 events, no discards, then forced shutdown and finite
  closure tails checked against a separate effect ledger. Prefix shrinking replays
  generation history. Seven regression groups pin eleven oracle programs.
- A real watcher/preflight defect and seven oracle defects were reproduced before
  fixes. Required labels, routing, timestamps and growing/capped retries prevent
  vacuous coverage. The oracle has no arbitrary attempt-16 ceiling.
- Local OCaml gate components, normal/optimized native/CLI suites, both opam lints,
  formatting, protocol/source controls and 26 × 10000 Crowbar inputs pass.
  The combined gate first stopped on runner formatting; remaining components pass
  after formatting. Ledger warning 4 failed before explicit phase coverage.
- Type clients: 14 rejected/one valid, normally and optimized; 66 unchanged CMIs.
  Source gate: 297 files. Required pinned Elixir: 302 tests, zero failures, six skips;
  formatting/lint/coverage/Dialyzer pass.
- PR/push Linux/macOS workflows pass at b13aa73. All four raw boundary logs contain
  45 examples, seed 20261001, 27 actual property groups, both type-client modes and
  297 sources. Receipt: _build/slice4-core-ci-audit.json.
- Two independent source reviews found no blocker. Codex completed with a
  no-findings reaction; Copilot/Devin report none. Sourcery skipped the oversized
  diff and supplied no review. GitHub API and in-app Browser confirm the merge.

## Current focus and next action

Branch ethan/eio-service starts at merged 5c892db. The poll-only Eio interpreter,
workflow loader and common-parent assembly are implemented. Exact clock/workspace
instances reach the runner; one owner interprets actual reducer commands.

- Reserved one-shot notifications remove the bounded-stream deadlock edge.
  Seven Inbox examples and 300 list-model programs pass; a control publishes
  1024 protected-finalizer notifications without any consumer.
- Actual Service Initial/Transition observations drive the same independent
  Core_bridge used by the pure suite. The 45-example/27-property baseline passes.
- Four Service failures preceded fixes: orphan canceled fake acquisition;
  observer replacing delivered timer failure; later caller cancellation replacing
  earlier owner/clock failure. Pre-resolved runner acquisition failed separately.
- One canonical failure register retains original exceptions/backtraces and
  redacts secondary payloads after closure. Finalizer/observer/caller orderings,
  blocked external producers, and reused issue generations pass.
- Latest architecture review reproduced actor failure losing its identity when
  its finalizer gates remained closed. The scoped Scenario.run constructor now
  releases gate permissions before joining children. No public unscoped creator
  remains. RED/GREEN: _build/eio-actor-{red,green}.log.
- Service_failure privately owns arbitration. The owner joins without rethrowing
  its recorded failure; the caller restores it once afterward. Independent
  observations retain reports even when they reuse the same exception value.
- Refactored Service: 29 examples and 1000 causal programs pass (seed 20261002);
  50–60 selected gates plus a joined shutdown tail. This is sampled three-issue
  coverage, not 1000 distinct seeds or simultaneous sessions.
- Separate example/property/replay executables remove test-runner coupling.
  Direct replay: dune exec test/service_replay.exe -- --seed N --prefix N.
  The 1000-program failure-and-report list model and full just check
  gate pass. Help invokes no properties; replay at prefix zero passes, and a
  negative seed returns exit 2. Receipt: _build/eio-full-check.log.
- Self-review strengthened the failure property with distinct error/exception
  identities. A deliberate same-kind last-wins mutation fails and shrinks to
  `error,error`; restoring production code passes all three property groups.
  Logs: _build/eio-same-kind-mutant.log and eio-distinct-failure-final.log.
- Current type gate: 14 lifecycle/three Service clients rejected, two valid
  assemblies accepted, 72 input CMIs unchanged, normal and optimized. Source
  pairing/policy checks 325 files. Formatting, native, CLI and release-tool gates
  pass. Pinned Elixir reference gate also passes. Hosted publication is next.

Review fixes reproduced four failures before correction: exception aggregate
order, the native helper's existing IO order, missing IO leaves, and swallowed
host-reporter failure. `Eio_failure` now supplies one decoder to native and service
code. Multiple is reverse order; Multiple_io is forward order. A fifth regression
showed set filtering erasing distinct same-kind IO errors; ordered occurrence
subtraction retains them within one aggregate. Further review exposed its misuse
across effects: exception identity cannot identify an observation. The owner no
longer rethrows registered failures, eliminating that deduplication requirement.
Three examples and the strengthened report model fail against the prior code;
all 29 examples/three groups pass after the redesign. Logs:
_build/eio-prior-observation-{examples,properties}.log and
_build/eio-independent-{ports,campaign}.log. The final full gate passes 325
sources and both 72-CMI modes: _build/eio-observation-full-check-replay.log.
An unchanged watchdog manifest test first exceeded its one-second fake-target
deadline; isolated replay and both normal/optimized full-gate runs passed.
No timeout or assertion was changed.

Execution correction: commit 3706dd4 was pushed before inspecting a repeated
reference gate failure. The unchanged real-clock timer test missed its margin by
267 ms. Its isolated replay and the complete gate passed at seed 989296: 302
tests, zero failures, six skips, all lint/format/coverage/Dialyzer steps passed.
No reference source or assertion was changed. Receipt:
_build/eio-reference-full-seed.log. Read each gate result before publication.

Next: finish exact-head hosted checks/review for PR #9 and merge this checkpoint.
Then physical capacity measurement and the real closed Codex runner;
no live dispatch CLI before its progress/continuation/stall contract is tested.

## Boundaries and references

The executable supports inspection and cannot dispatch a real agent yet. Fake
completion witnesses prove no native scope closure. Sampled algebra/model laws are
not proofs. Native-agent simulation, HTTP API, portable harness, benchmarks,
Linux musl and clean-host macOS deployment remain pending.

Historical macOS release qualification imported only libSystem, but used Crypto
1.2.0. It does not qualify the current graph or a clean/minimum host. Development
still loads Homebrew GMP. POSIX final unlink/rmdir cannot condition on inode;
non-cooperating hosts, escaped process groups and finite kernel reap bounds require
stronger isolation. Preserve explicit expected errors and primary backtraces.

See CONFORMANCE.md, docs/design/slice-4-core-plan.md,
docs/design/slice-4-orchestrator-plan.md, docs/design/release-evidence.md and
docs/design/static-release-plan.md. Earlier worklog receipts remain in Git history.

## Steering and open questions

Repeated acceptance authorizes recommendations, signatures, implementation,
publication and green merges. The latest steer prioritizes architectural debt,
module boundaries and risky failure modes before more features or polish. It
supersedes the immediate benchmark expansion. No user decision is pending.

The complete book repository supersedes sample-only research. GitHub detachment
was verified; origin is solely ethan-wickstrom/symphony. Upstream links retain spec
provenance. Release-host qualification remains a release gate and no longer blocks
orchestrator development. In-app Browser supersedes Chrome use.
