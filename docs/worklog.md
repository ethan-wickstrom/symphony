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

- [PR #12](https://github.com/ethan-wickstrom/symphony/pull/12) merged as
  40d6b63 on 2026-10-05. Reviewed 2b58097 and merged main have identical trees.
  Fifteen checks completed; Sourcery skipped the oversized diff. All review
  threads resolved; fresh Codex review found no major issues.
- Independent Linux/macOS push and PR audits passed 200 executable cases,
  120 peer acquisitions, 224 lifecycle checks and 16 capacity manifests.
  Receipts: ocaml/_build/live-dispatch-hosted-audit.json and
  live-dispatch-merge-receipt.json. Native manifests match 252 source hashes.
- Local configured coverage passed through combined native/full-check,
  corrected 25-case normal/optimized CLI and remaining-check logs. Formatting,
  391 source files/39 controls, 17 rejected clients, two assemblies, 73 CMIs
  per mode and codec67/42 pass. Pinned Elixir: 302 tests, zero failures, six skips;
  formatting/lint/coverage/Dialyzer pass.
- Controlled FD exhaustion and incomplete issue/session context failed before
  correction. Early reporting is bounded after closure and preserves the first
  failure. Canonical issue_identifier and exact previous generation supply
  closure context. The corrected continuation oracle follows turn session IDs.
- Fake provider fixtures verify protocol/lifecycle behavior. Binary digests are
  execution context, not attestation. Capacity RSS is sampled; raw latency arrays
  are not retained. Archived PID/inode metadata cannot independently prove
  historical physical identity or reap.

## Current focus and next action

Branch ethan/status-api adds fresh owner queries, checked immutable snapshots,
JSON/HTML routes and an optional scoped loopback HTTP server. Status reads must
not reload configuration, mutate scheduling state or reconnect to another run.
Each new run has a single-use scoped source. Request cancellation retires only
its own waiter; shutdown closes sources before physical drainage.

- [x] Merge the reviewed live-dispatch checkpoint and verify tree identity.
- [x] Audit reference routes and the missing owner-query boundary.
- [x] Implement checked snapshots and one-sample owner projection.
- [x] Implement bounded per-run query/refresh lifecycle and migrate callers.
- [x] Implement pure JSON/HTML routes and joined native HTTP transport.
- [x] Compose optional port/configuration into the actual CLI.
- [x] Verify lifecycle, real HTTP behavior, formatting and configured gates.
- [ ] Review, publish, audit exact-head hosted evidence and merge.

The complete configured gate passes in status-review-full-check.log:
47 service/83 orchestration/272 boundary cases, 58 native lifecycle cases, 417 sources/39
controls, 17 rejected clients/80 CMIs per mode, codec67/42, capacity1/10/100/1000,
release checks. Parser10000 passed before the review fixes. Both modes pass
service25 and status23 scenarios; native source inventory274. Fresh pinned
Elixir302/0/6 passes in status-review-elixir-all.log. Status CLI receipts
are in _build/status-cli-AE0HA4. Bounded regressions failed before owner cancellation,
unsolicited cancellation, failure precedence, diagnostic UTF-8 and malformed-body
authority fixes. Review regressions first failed for browser authority and
valid/invalid listener reloads. The corrected executable dispatches through
listener-only edits while preserving the original listener; rejected browser
requests grant zero handler authority. Native framing corpus256 passes.
PR13 is published; corrected-head review and Linux/macOS push/PR audit are next.

Root owns Core projection/composition and serializes executable gates. Independent
agents own pure rendering, owner queries and native HTTP transport. Native Codex
acceptance and release qualification remain separate boundaries. In-app Browser
control restoration was rejected by automatic approval review under the browser
restriction; browser inspection remains unverified pending authorization.

## Remaining boundaries

Authenticated Codex acceptance, hosted HTTP acceptance, portable conformance harness, regression
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
publication and green merges. The latest steer accepts all recommendations and continues with the status API
after the merged live-dispatch checkpoint. Architectural debt,
module boundaries and risky failure modes remain ahead of polish. No decision is
pending for implementation. Devin's hidden security finding requires its text or
authorized in-app Browser inspection before merge; real provider trials require
their own fixture scope.

Only origin ethan-wickstrom/symphony is configured. Upstream links retain spec
provenance. In-app Browser supersedes Chrome use. Release-host qualification is a
release gate and does not block orchestrator development.
