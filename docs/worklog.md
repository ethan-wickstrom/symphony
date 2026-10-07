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

[PR #13](https://github.com/ethan-wickstrom/symphony/pull/13) merged as
806bbc8 on 2026-10-07 UTC. The reviewed c73a037 and merge have identical trees.
The scoped status service, browser authority checks and startup listener settings
passed local and Linux/macOS hosted gates. Fresh Codex review had no findings.
Devin's retry arithmetic suggestion was declined against SPEC 1553–1569 and the
retry lifecycle: these fields describe the current retry series, not historical
worker launches. Browser inspection is complete. Receipts:
`ocaml/_build/status-api-merge-receipt.json` and hosted audit evidence.

Branch `ethan/conformance-harness` builds the accepted portable black-box layer.
Its first case must use the public CLI, fake HTTPS tracker and schema-valid
stdio peer through same-thread continuation, terminal reconciliation, all four
hooks, workspace removal and joined shutdown. Sealed raw observations must replay
without executing a candidate. Profiles translate public operations and logs;
the fixed corpus and independent judge own expected behavior.

- [x] Prepare all 106 spec rows plus 12 supplemental rows; no portable pass claims.
- [x] Regenerate and hash all 314 stable Codex 0.159.2 schema files.
- [x] Extract canonical bounded process/capture ownership; initial nine controls
  pass in normal and optimized Python.
- [x] Implement offline inventory, protocol, lifecycle and report controls.
- [x] Verify the public CLI lifecycle: twelve assertions pass; numeric usage is
  unobservable. Scripted calibration passes all thirteen.
- [x] Correct reproduced TLS admission, recorder closure, cancellation, nullable
  schema formats, retained asset custody and quiet descendant verdict defects.
  Final 90 controls pass normally and with assertions disabled, including
  request/fixture grading, wire integrity, bounded inventory and marker races.
- [x] Transfer shared schemas/TLS/lock and native/capacity/service ownership.
- [x] Complete all nine independent fault calibrations in both Python modes.
  Public lifecycle and scripted calibration replay identically from sealed bytes.
- [x] Complete current receipt-reader controls and final wheel qualification.
  Both modes reject 97 corrupted receipts, including raw unit-log corruption.
  The final external wheel passes all eleven lifecycle/calibration cases per mode.
- [x] Correct final review defects: absolute HTTP connection custody/deadlines
  for tracker and collector; correlate replies by outstanding request occurrence.
  All 90 controls and eleven cases per mode pass in conformance-dkmsfl.
  The single-owner TLS probe rejects the old fixture after continued drip input.
  Pinned Elixir and native custody/admission gates pass. Configured native,
  capacity, codec, lifecycle, source, verification, release and seeded fuzz gates
  pass through combined logs; the original full-check command stopped at defects
  subsequently reproduced and corrected.
- [x] Verify installed-wheel execution outside the checkout in both modes.
  All eleven lifecycle/calibration cases per mode pass from the external env.
- [x] Publish PR #14 and address five Codex/Copilot findings. Full predicate
  validation rejects malformed hidden branches as candidate requests; codec
  evidence cannot replace the canonical manifest; release docs require the
  locked installed harness; host cancellation survives cleanup and sealing.
  Regressions failed before fixes, including actual CLI SIGTERM returning zero.
  The corrected CLI returns 143. Local `just check` passed with 101 portable
  controls and eleven cases in each Python mode, plus configured native,
  capacity, codec, lifecycle, source, verification and release gates.
- [x] Remove the inherited reverse-DNS lookup from numeric fixture binding.
  A deterministic regression failed in normal/optimized Python before the fix;
  real HTTP response, metadata and joined listener closure now pass in both.
  Failed child joins retain bounded capture and lifecycle notes before/after
  cleanup. Budgets remain unchanged.
  The affected installed package now passes all 102 controls in both modes.
- [x] Verify numeric binding against exact-head macOS fixture subprocess timeouts.
  Both push/PR portable steps pass at e46928cf7318; the PR matrix is green.
- [x] Correct the scenario's premature terminal transition. Push Linux recorded
  the second request before its ACK, then canceled the pending start. A delayed
  ACK regression reproduces that ordering in both modes. Wait for the matching
  ACK and the candidate's accepted public turn observation; keep verdicts strict.
  Both delayed barriers fail before the fix and pass after it in both modes.
- [x] Retain host signal custody through final sealing. The fresh review found
  default SIGTERM handling restored after child closure. Both regression modes
  reproduce an absent manifest and OS exit -15 during sealing. Restoration
  failures also reproduce lost cancellation in the runner and generic drivers.
  The fixed paths return 143, retain bounded notes and preserve sealed evidence.
  All 108 controls and eleven lifecycle/calibration cases pass in both modes.
  Full configured checks, external-wheel cases and 97 receipt-reader corruption
  controls per mode also pass on the final source.
- [ ] Review, publish, audit exact-head Linux/macOS evidence and merge.

Missing or unobservable evidence blocks complete core conformance. The public
OCaml event log omits numeric usage totals; the baseline cannot require the
optional HTTP extension. Native provider acceptance, release qualification and
historical physical identity remain separate evidence boundaries. Root serializes
all executable gates; independent agents own source-only modules and reviews.

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
publication and green merges. The latest "Continue" resumes final portable
harness qualification and publication. The next accepted slice exposes exact
numeric usage in public CLI logs; implementation waits for this checkpoint merge.
Architectural debt,
module boundaries and risky failure modes remain ahead of polish. No decision is
pending for implementation. PR13 review is complete; real provider trials require
their own fixture scope.

Only origin ethan-wickstrom/symphony is configured. Upstream links retain spec
provenance. In-app Browser supersedes Chrome use. Release-host qualification is a
release gate and does not block orchestrator development.
