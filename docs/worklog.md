# OCaml implementation worklog

## Goal and success criteria

Readable OCaml 5/Eio Symphony: one Linux musl static binary, macOS deployment,
Section 17 conformance, portable black-box harness, independent event model,
replayable service simulation, fuzzed boundaries and measured 1000-session
capacity. Operator API, doctor/dry-run, module laws and adapter profiles ship.

## Active constraints

- Accepted policies/signatures and vertical slices; Linear first.
- Spec RFC 2119 requirements; generated Codex schema wins protocol details.
- One scheduling owner; immutable state; explicit Eio capabilities/type equalities.
- Every application .ml has an .mli; fatal warnings; no objects/Lwt/Async/casts.
- Untrusted tracker/repository input; only trusted configuration enters Bash.
- Develop/publish only to ethan-wickstrom/symphony; in-app Browser only.
- Each checkpoint is reviewed, green and merged before the next implementation.
- Root serializes native/Dune/opam/Elixir gates; agents own independent work.

## Completed checkpoints

- Spec, reference intent, OCaml sources and complete Algebra-Driven Design book
  read. Codex 0.159.2 schemas regenerated/audited: 754 JSON definitions.
- PRs #1–#5: workflow/config/template/reload, native owned workspaces/hooks,
  authenticated Linear HTTPS inspection, release foundation and crypto refresh.
- PRs #6–#8: exact scheduling algebra, original-binding issue lifecycle and pure
  reducer with independent event model. PR #8 merged as 5c892db.
- [PR #9](https://github.com/ethan-wickstrom/symphony/pull/9), d88f0df:
  scoped Eio service, one-shot publication, joined physical custody and canonical
  primary failure. Actual service observations drive the independent model.
- [PR #10](https://github.com/ethan-wickstrom/symphony/pull/10), 5853f91:
  physical 1/10/100/1000 native-clock fake-session capacity and receipt auditing.
- [PR #11](https://github.com/ethan-wickstrom/symphony/pull/11), 5490eb3,
  merged 2026-10-04: owned stable JSONL session and closed Codex runner. Causal
  progress, fenced continuation, live stall cadence, accounting-only late usage
  and original-reference cleanup retain the worker slot until actual closure.

## Current evidence

- PR #11 reviewed head 2cbd893 and merged main have identical trees. Twelve
  checks pass; Sourcery skipped the oversized diff. Four raw Linux/macOS PR/push
  boundary logs and all 16 capacity manifests passed independent audits.
  Receipts: ocaml/_build/runner-ci-2cbd893-audit.json and runner-merge-receipt.json.
- Agent: 146 examples; native fake-server cases run normally and optimized.
  Core: 65 examples/29 property groups; service: 36 examples/three groups
  (300 Inbox, 1000 failure-model and 1000 causal service programs with joined tails).
- Final gate: 379 source files/39 source controls; 17 rejected type clients,
  two valid assemblies and 73 unchanged CMIs in both modes. Codec: 67 fixtures
  and 42 validator controls. Pinned Elixir 1.19.5/OTP 28: 302 tests, no failures,
  six skips; formatting/lint/coverage/Dialyzer pass.
- Runner regressions failed before correction, including accepted suffixes at
  initialization/input/continuation handoffs, preparation interruption, reader
  join identity, typed input cleanup and bounded replay across turns. Receipts:
  runner-turn-boundary-{red,green}.log, runner-turn-boundary-full-check.log and
  runner-receipt-reference.log. Earlier receipts remain in Git history.
- Capacity samples measure the service/runtime with held fake scopes, not real
  Codex processes. RSS has four checkpoints, not a peak; raw latency arrays are
  not retained. Reported quantiles are not independently recomputable from a
  manifest. Binary/runtime digests are declarations, not build attestation.

## Current focus and next action

Branch ethan/live-dispatch composes the existing owner, tracker, workspace host
and closed runner into `symphony [WORKFLOW]`, defaulting to ./WORKFLOW.md.
Admitted attempts retain frozen authority through joined shutdown.

Hosted review found missing early signal-setup reporting and incomplete issue/session
log context. Actual failures are retained in
_build/live-dispatch-{startup-fd-red,context-red}.log. Corrections pass the targeted
startup-FD, active-context and no-session shell-closure controls:
_build/live-dispatch-review-green.log and
_build/live-dispatch-review-green-xurkg4d2. All 25 cases now pass in both modes;
exact replacement-head hosted evidence remains pending.

The replacement run then exposed an oracle error: continuation turn notices
change the thread/turn session ID. The last-session check now consumes every
same-issue/run session/turn notice, not only session_started. Production closure
was correct; retained failure: _build/service-cli-Uqfwqm/normal. The corrected
suite passes in _build/service-cli-JWgykX/{normal,optimized}; independent audit:
_build/service-cli-JWgykX/independent-verification.json. All 50 logs, 30 peer-mode
receipts, five input hashes and the current binary match. Both controlled FD
cases prove doctor0 then service123 with limit64/headroom3 and fixed early output.

Issue records use issue_identifier. Closure context comes from the exact previous
issue/run/session projection, or explicit not_started; hooks use the checked
reference identifier. Paired secondary context requires the exact generation.
An unknown Worker/Retry generation retains its checked opaque issue ID and
generation with context=unavailable, without invented identifier/session fields;
this exceptional host-port path is not a full-conformance claim.
Ordered acknowledged runner notices remain
the causal boundary; a projection session guard alone does not prove sequence
acceptance. Early setup reporting is bounded, occurs after full closure and
preserves the original failure. It never retries after output callback entry or
a failed sink.

- [x] Audit reference CLI behavior and existing composition contracts.
- [x] Reproduce/fix configuration validation before adding dispatch.
- [x] Add runnable native assembly and direct/default workflow command syntax.
- [x] Verify native signal/output boundaries; 28 native cases pass.
- [x] Complete the earlier 24 executable cases and local gates (historical evidence).
- [x] Reproduce hosted-review defects and pass targeted corrections.
- [x] Run/audit all 25 cases in both modes and complete configured local coverage.
- [x] Complete the fresh pinned Elixir reference gate.
- [ ] Publish/audit hosted evidence and merge the reviewed green checkpoint.

Historical pre-review evidence: 24 cases passed in both modes, with unchanged
inputs and propagated child modes (_build/service-cli-Q5fOU0/{normal,optimized}).
The earlier full gate passed 391 source files/39 controls, 17 rejected clients,
two valid assemblies, 73 unchanged CMIs, 28 native lifecycle cases and 11 watchdog
controls per mode. Parser, capacity and release-tool gates passed; pinned Elixir
passed 302 tests/zero failures/six skips. Hosted review supersedes that checkpoint's
no-blocker assessment. Historical receipts include live-dispatch-{host-green,
full-check,reference,watchdog-green,watchdog-green-optimized}.log.

Configured local coverage passes through combined logs: the dependency/native/
inspection/HTTPS run passed before the old oracle stopped full-check; the corrected
25-case run and remaining check body then passed, plus formatting. Receipts:
live-dispatch-review-{full-check,service-cli,remaining-check}.log. Counts remain
391 source files/39 controls, 17 rejected clients, two assemblies, 73 unchanged
CMIs per mode and codec67/42. Passed native gates were not repeated.
Fresh pinned Elixir also passes 302 tests/zero failures/six skips plus
formatting/lint/coverage/Dialyzer (_build/live-dispatch-review-reference.log).

Next: publish and verify the exact new head before merge. Local executable
evidence uses fake providers; binary digests are
context, not build attestation.

## Remaining boundaries

Authenticated Codex acceptance, HTTP API, portable conformance harness, regression
budgets, Linux musl and clean-host macOS deployment remain pending. Fake completion
witnesses cannot prove native closure; sampled laws/models are not proofs.

Historical macOS qualification imported only libSystem with Crypto 1.2.0. It does
not qualify the current graph or a clean/minimum host. Development still loads
Homebrew GMP. POSIX unlink/rmdir cannot condition on inode; non-cooperating hosts,
escaped process groups and finite kernel reap bounds need stronger isolation.

See CONFORMANCE.md, docs/decisions.md and docs/design/{live-dispatch,eio-service,
service-retrospective,release-evidence,static-release-plan}.md.

## Steering and open questions

Repeated acceptance authorizes recommendations, signatures, implementation,
publication and green merges. The latest steer continues with runnable live
dispatch after the service, capacity and runner checkpoints. Architectural debt,
module boundaries and risky failure modes remain ahead of polish. No decision is
pending for this checkpoint; real provider trials require their own fixture scope.

Only origin ethan-wickstrom/symphony is configured. Upstream links retain spec
provenance. In-app Browser supersedes Chrome use. Release-host qualification is a
release gate and does not block orchestrator development.
