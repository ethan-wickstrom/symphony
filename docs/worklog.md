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

Branch ethan/live-dispatch composes existing service, tracker, workspace host and
closed runner into `symphony [WORKFLOW]`, defaulting to ./WORKFLOW.md. Inspection
commands remain. One named clock, registry, HTTP runtime and startup environment
serve initial configuration and reloads; admitted attempts keep frozen authority.

The reference audit found malformed prompt syntax could replace last-good
configuration. Two regressions reproduced the defect; Config.resolve now checks
prompt syntax before accepting initial/reloaded settings. Both targeted cases pass
(_build/live-dispatch-prompt-{red,green}.log).

Shutdown uses a scoped first-signal self-pipe. SIGINT/SIGTERM stop admission and
join Service, control producers, workers, hooks, leases and the signal reader before
restoring handlers/closing descriptors, including duplicate signals during held
final output drainage. Bounded nonsuspending log publication feeds one owned
asynchronous writer; live tracker warnings use it too. Callback primaries and first
output failures retain precedence. Failed callbacks attempt bounded diagnostic
drainage. All 28 native lifecycle cases pass.

- [x] Audit reference CLI behavior and existing composition contracts.
- [x] Reproduce/fix configuration validation before adding dispatch.
- [x] Add runnable native assembly and direct/default workflow command syntax.
- [x] Verify native signal/output boundaries; 28 native cases pass.
- [x] Complete 24 executable TLS/JSONL cases in both Python modes.
- [x] Run local gates and independent review.
- [ ] Publish/audit hosted evidence and merge the reviewed green checkpoint.

All 24 executable scenarios pass normally and optimized. Receipts:
_build/service-cli-Q5fOU0/{normal,optimized}; inputs remain unchanged and child
Python modes propagate. Gates cover accepted reload while an active attempt
retains authority/env/hooks/command/prompt; next retry adoption; held startup/active
tracker reads; same-size/mtime-preserved rewrite; path spaces; repeated shutdown
signals and exact escaped omission context. A projection oracle was corrected for
Diagnostic.render's additional escape layer; no production change was needed.

Meaningful RED/GREEN regressions cover prompt validation, false cancellation
cleanup reports, first output failure precedence, queued failure-log drainage and
watchdog target closure. Native: 28 actual lifecycle cases; watchdog: 11 controls
in both modes. Configured just check passes: 391 source files/39 source controls,
17 rejected clients, two valid assemblies, 73 unchanged CMIs; existing native,
service/model, codec, 1/10/100/1000 fake capacity and release-tool gates pass.
Pinned Elixir reference: 302 tests, zero failures/six skips; make all passed.
Independent review found no remaining production/assembly/harness blocker.

Seeded parser campaign passes. Current focus: PR publication, exact-head hosted
evidence audit and reviewed green merge. Local receipts include live-dispatch-{host-green,
full-check,reference,watchdog-green,watchdog-green-optimized}.log.

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
