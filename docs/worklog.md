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

- [PR #9](https://github.com/ethan-wickstrom/symphony/pull/9) merged as d88f0df.
  Reviewed tree equals main; 14 checks pass. Sourcery skipped the oversized diff.
  Four raw Linux/macOS PR/push boundary logs confirm all service/model/type counts.
  Receipts: _build/eio-ci-audit.json and eio-merge-receipt.json.
- Service: 29 examples; three property groups at seed 20261002: 300 Inbox,
  1000 failure/report model and 1000 causal service programs plus joined tails.
  Actual observations share the independent Core_bridge. Pure core: 45 examples
  and 27 groups at seed 20261001; 200 programs of 500–600 events plus closure tails.
- Scoped Scenario.run releases actor gates before joining. Canonical failure
  arbitration preserves original identity/backtrace and distinct repeated reports.
  Regression examples/models failed before each correction. No public unscoped
  constructor remains; exact clock/workspace instances reach the closed runner.
- Current capacity gate: 1/10/100/1000 held native-clock fake scopes, five warmup
  and 100 measured polls each. Acquisitions/starts/releases/completions match;
  at 1000 all 1427 handles retire, pending calls are zero and the producer is reaped.
  23 watchdog/protocol controls pass normally and optimized. Seven measurement
  examples and five independent 500-case laws cover exact ranks and GC arithmetic.
- Full local just check passes 335 source files, 39 source controls, 17 rejected
  type clients/two valid assemblies and 72 unchanged CMIs in both modes.
  The source policy first rejected List.nth; checked lookup fixes it without
  changing the quantile law. Receipt: _build/capacity-full-check-final.log.
- Local final 1000-session sample: entry 184.97 ms, step p95 1.876 ms, poll p95
  8.12 ms; baseline/plateau/steady RSS 17.34/29.13/33.70 MiB. RSS plateau delta
  12354 B/session; managed heap 5586 B and stack/cache 3879 B/session.
  Latency varies between runs; these are initial samples, not regression budgets.
  Receipts: ocaml/_build/capacity-cSwJrp/{1,10,100,1000}/manifest.json.

## Current focus and next action

PR #10 merged as 5853f91 on 2026-10-03. Its tree equals reviewed head 24f49b8;
13 checks pass and Sourcery skipped after quota exhaustion. All 16 final-head
capacity manifests match emitted JSON, log digests, lifecycle counts and reaped
producers. Four raw boundary logs confirm test/type/source counts. Receipts:
_build/capacity-ci-final-audit.json and capacity-merge-receipt.json.
Pinned Elixir 1.19.5/OTP 28: 302 tests, zero failures, six skips;
formatting/lint/coverage/Dialyzer pass (_build/capacity-reference-full.log).

Branch ethan/codex-runner implements the stable JSONL session and closed runner
over the existing Agent_process bracket. Progress is acknowledged by the owner;
continuation reads are fenced by issue/run/turn/epoch; typed stalls retain worker
custody until closure. Late usage updates accounting without refreshing activity.
Targeted local gates pass 139 protocol/runner cases, 65 core examples/29 properties,
36 service examples, 67 schema fixtures/42 controls in both modes and nine native
agent cases. Workspace/runner cleanup regressions failed before their corrections;
the mandatory workspace mapper preserves caller errors through lease closure.
Continuation replies retain accepted read failures after competing operations join.
Codec fixtures, validator receipts and identity manifests are retained in CI.
CI selects Python 3.14 for macOS waitid/WNOWAIT, added in
[Python 3.13](https://docs.python.org/3/library/os.html#os.waitid).
At 80bc18b all PR/push Linux/macOS gates pass; 16 capacity receipts match emitted
JSON and independent schema/source/log audits. Receipt:
_build/runner-ci-80bc18b-audit.json. The final changed head needs fresh hosted
checks, artifact audits and review before merge.

Regression evidence covers live stall cadence during reads/refreshes, deferred
terminal reconciliation in both closure orders, accounting-only late usage, and
whole-cycle capacity timing after held read/finalizer closure. Pending/active
terminal pairs reject conflicts and retain identical outcomes. Closing settles
accepted suffixes under its original cause and deadline without future reads.
All preparation/protocol receipts check synchronous interruption before proceeding.
Initialization, input and continuation handoffs validate buffered suffixes;
input cleanup propagates typed errors. Reader cancellation/join retains the
captured body's original error or exception/backtrace and exposes closing defects
after success. The latest 23 regressions failed before correction and now pass
alongside seven controls; all 139 agent cases pass.
Pinned integer/int32 schemas and official app-server source resolved the
fractional rate-limit finding.

The final OCaml gate passes 379 source files, 39 source controls, 17 rejected type
clients, two valid assemblies and 73 unchanged CMIs in both modes. Pinned Elixir
passes 302 tests, zero failures and six skips
plus formatting/lint/coverage/Dialyzer. Latest receipts:
_build/runner-preparation-{red,green}.log,
runner-input-receipt-{red,green}.log, runner-handoff-{red,green}.log,
runner-daemon-close-{red,green}.log, runner-daemon-close-full-check.log and
runner-receipt-reference.log. Fresh final-head hosted evidence and review are next.

- [x] Record current schema provenance and consumed codecs/framing contracts.
- [x] Add causal progress/continuation/stall to the existing owner/service boundary.
- [x] Implement the owned protocol session and closed workspace/process/hook runner.
- [x] Verify schema fixtures, independent models, native fake-server behavior and closure.
- [x] Run relevant local gates and independent review.
- [ ] Publish and audit hosted evidence.
- [ ] Merge the reviewed green checkpoint.

No live dispatch CLI before progress/continuation/stall contracts pass.

## Boundaries and references

The executable supports inspection and cannot dispatch a real agent yet. Fake
completion witnesses prove no native scope closure. Sampled algebra/model laws are
not proofs. Live Codex acceptance, HTTP API, portable harness, benchmarks,
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
superseded the immediate benchmark expansion until the service was closed and
reviewed. Service and capacity checkpoints are complete. The 2026-10-03 steer
accepts recommendations and continues the next boundary: the closed Codex runner.
No user decision is pending.

The complete book repository supersedes sample-only research. GitHub detachment
was verified; origin is solely ethan-wickstrom/symphony. Upstream links retain spec
provenance. Release-host qualification remains a release gate and no longer blocks
orchestrator development. In-app Browser supersedes Chrome use.
