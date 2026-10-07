# OCaml conformance

Status: workflow/workspace/Linear slices, pure scheduling, scoped Eio service,
physical fake-session capacity, the closed runner, live executable and optional
status API are merged through [PR #13](https://github.com/ethan-wickstrom/symphony/pull/13)
(`806bbc8`). Local and exact-head Linux/macOS push/PR gates passed. Reviewed
c73a037 and merged main have identical trees; retained audits and review
resolution are recorded in [the worklog](docs/worklog.md).
The historical macOS release profile passed physical closure/link checks with
Crypto1.2.0. Current2.4.1 requires fresh release qualification. Clean-host
macOS deployment, Linux musl and authenticated Codex acceptance remain pending.
The upstream Elixir implementation is reference material, not evidence for this port.
Requirements refer to SPEC.md at `be10a1b79df723d6d7612b5651c8522704dafb2e`.
Current protocol fixture: Codex 0.159.2. Stable core and experimental tool
profiles must record schema digests, generator flags, and initialization capabilities;
schema generation is not a passing client test. See [protocol audit](docs/protocol-audit.md).

## Section 18.1 checklist

| Requirement | Planned slice | Implementation/test evidence | Status |
| --- | --- | --- | --- |
| Explicit workflow path and cwd default | 1, 7 | `ocaml/bin/cli.ml`; `ocaml/test/cli_check.py` explicit/default/anchoring cases | Direct/default/run service syntax implemented; local executable cases pass |
| YAML front matter and prompt split | 1 | `workflow_document.ml`, `config_value.ml`; `workflow_parser_test.ml` workflow/YAML examples and tree/line models | Passed locally |
| Typed defaults and `$` resolution | 1 | `config_layer.ml`, settings modules; `config_test.ml` defaults, env/path/numeric/state cases | Passed locally |
| Dynamic workflow reload/re-apply | 1, 4 | `Config_layer.Make.apply`, `orchestrator.ml`; config and event models/tests cover last-good settings, epoch fencing, per-cycle preflight and scope drain | Poll/preflight reload implemented in executable; invalid-template initial/reload regressions pass |
| Single-authority polling orchestrator | 4 | `ownership.ml`, `agent_plan.ml`, `run_plan.ml`, `issue_lifecycle.ml`, `orchestrator.ml`; independent owner/lifecycle/event models and `core_test.ml`, `core_property_test.ml`, `core_coverage_test.ml` | Pure/Eio owner passes actual-event model simulation; executable dispatch passes local fixtures |
| State-list and ID-refresh tracker reads | 3 | `linear_tracker.ml`, `linear_pager.ml`, `linear_record.ml`, `tracker_registry.ml`; independent boundary/pagination/binding models, `linear_tracker_test.ml`, `native_http_test.ml`, real `tracker_cli_check.py` | Reads, frozen auth/current policy, atomic failures and verified HTTPS passed locally and on both CI hosts |
| Sanitized collision-resistant workspaces | 2 | `workspace_key.ml`, `workspace_reference.ml`, `workspace_owner.ml`, `native/workspace_directory.ml`, `workspace_store_posix.ml`; key/owner models, hash vectors, parser fuzzing, `native_directory_test.ml`, `native_store_test.ml` | Descriptor/lock/identity/replacement/rollback cases passed locally and on both CI hosts |
| Four workspace lifecycle hooks | 2 | `workspace_manager.ml`, `workspace_hooks.ml`; policy models, fake-port hook tests and `native_host_test.ml` frozen lifecycle/cancellation/rollback cases | Fake and live cases passed locally and on both CI hosts |
| Configurable hook timeouts | 1, 2 | `workspace_settings.ml`, `workspace_hooks.ml`, `clock_posix.ml`; config and monotonic-clock models, independent stream faults, noisy output, native hook timeout | Config/interpreter/subprocess cases passed locally and on both CI hosts |
| App-server subprocess transport/framing | 5 | `protocol_frame.ml`, `protocol_envelope.ml`, `protocol_codec.ml`, `app_server.ml`; independent framing model, schema-validated actual codecs, fake byte peers and `native_agent_test.ml` | Protocol/native gates pass locally and hosted on Linux/macOS through PR #11 |
| Configurable Codex launch command | 1, 5 | `agent_settings.ml`, `codex_runner.ml`; config validation and native acquired-cwd/allowlisted-env launch | Local config and native launch pass; live Codex authentication/sandbox pending |
| Strict issue/attempt prompt rendering | 1 | `template.ml`; `template_test.ml` strictness/scope/limits, independent AST and rational models; CLI fixture rendering | Passed locally for documented strict Jinja profile |
| Failure backoff and continuation retries | 4, 5 | `backoff.ml`, `issue_lifecycle.ml`, `orchestrator.ml`, `codex_runner.ml`; independent models, parked reads, stale timers and same-thread continuation cases | Service models, native fake-server and executable same-thread continuation pass locally |
| Configurable retry cap | 1, 4 | `scheduling_policy.ml`, `backoff.ml`; config/algebra models and `core_coverage_test.ml` exponential growth, current cap and more than 16 retries | Pure policy and Eio mock timers pass; native service pending |
| Terminal/non-active reconciliation | 4, 5 | `orchestrator.ml`; binding-group reads, closed barrier, refreshed issue, stop disposition and stale completion cases in core/service models | Fenced service decisions, closed runner interruptions and executable preflight pass locally |
| Terminal startup/transition cleanup | 2, 4 | `issue_lifecycle.ml`, `orchestrator.ml`; epoch-fenced startup, cleanup closure, original reference and absorbing Cleanup examples/models | Eio startup/cleanup barriers pass fake-port simulation; native service pending |
| Required structured log context | 4, 6 | `Orchestrator.fault` retains checked current issue after release; `service_cli.ml` uses exact previous issue/run/session closure context and checked hook references; `service_cli_check.py` checks issue_identifier and started/not_started closure | Canonical records pass the 25-case local/hosted suite; unknown-generation host-port faults retain explicit partial context |
| Operator-visible observability | 1–7 | `diagnostic.ml`, inspection CLIs, `snapshot.ml`, `status_surface.ml`, `service_query.ml`, `native_status.ml`; inspection, status/model/query and executable route tests | Fresh status/API passed local and Linux/macOS hosted normal/optimized acceptance in PR #13 |

## Status API checkpoint

`Core.snapshot` projects one fresh paired sample without changing scheduling.
Checked immutable `Snapshot.t` retains current issue, exact runtime/usage, acquired
session/workspace facts, retries and cleanup. `Status_source.S` returns four typed
unavailability causes; query or projection failure cannot kill the owner.
`Status_surface` renders baseline state/detail/refresh routes and escaped HTML;
400/404/405/503 are distinct; 405 carries exact route methods, malformed refresh
bodies queue nothing, and JSON composition/HTML output remain bounded values.
The scoped loopback listener has explicit client/header/body/wire/deadline limits,
and listener settings require restart. Host/Origin/Fetch Metadata checks precede
handler authority; listener-only reloads cannot affect scheduling configuration.
[Design and limits](docs/design/status-api.md).

`status_test.ml` covers list-model ownership, exact numbers, nullable wall times,
route authority, cleanup, escaped health fields, response overflow and 1,000
checked rows. The complete configured gate passes in
_build/status-review-full-check.log: 47 service cases, 83 orchestration cases,
272 boundary cases, 58 native lifecycle cases, 417 sources/39 controls, 17
rejected clients and 80 unchanged CMIs per mode. Both modes pass 25 service and
23 status CLI scenarios; native manifests record 274 source hashes. Codec67/42,
capacity1/10/100/1000 and release checks pass. Seeded parser10000 passed before
the review fixes. The status native corpus executes 256 public-loopback inputs.
Receipts are in _build/status-cli-AE0HA4, service-cli-62XYqI,
native-evidence{,-optimized} and capacity-S4lqUJ. Browser authority and listener
reload regressions failed before their fixes, then passed the complete gate.
Hosted gates and current-head browser inspection completed before PR #13 merged.
The retry arithmetic suggestion was declined against SPEC and lifecycle evidence.
Binary hashes are execution context, not attestation; fake peers do not prove
authenticated Codex acceptance.

## Design evidence

[The approved interface/design](docs/design/README.md) covers all eight components,
intentional equalities, algebras, independent models, build order and test targets.
The original 55 interfaces and assembly witness type-checked on OCaml 5.5/5.3 with warnings fatal.
That is interface evidence, not an implementation or conformance pass.
[Per-slice test plans](docs/design/testing.md) identify matching Section 17 examples.
Concrete implementation/test paths replace the pending cells as each slice lands.

## Additional requested gates

Slice-one models, strict boundary tests, native inspection CLI, interface/source
gates, and seeded Crowbar targets are implemented. See [slice-one evidence](docs/slice-1.md).
The pure reducer has an independent list-based event model, strict ordered-command
comparisons and deterministic examples for startup, grouped reconciliation,
preflight, sorted/capped admission, retries, reload, scope drain and shutdown.
The local targeted suite passes 45 Alcotest examples and 27 QCheck groups at seed
`20261001`, including fault context after release and exact-once shutdown closure.
The event campaign compares 200 programs of 500–600 events with no discards,
then a forced shutdown and finite closure tail for each. Seven regression groups
pin eleven closure-order/prior-validation programs. Source/compiler gates cover
297 source files and 14 rejected/one valid type clients at the merged core checkpoint.
Claimed IDs and running counts derive from its one canonical ownership queue;
operator projections derive from reducer state.
Fake closed-completion witnesses test the reducer contract; they do not prove native
resource closure.

The Eio interpreter (`ocaml/lib/service/service.ml`) runs the same core over
scoped loader/tracker/workspace/runner/clock ports. `service_sim_test.ml` feeds
actual delivered envelopes through `core_bridge.ml`; 29 Alcotest examples and
three actual QCheck groups pass at seed `20261002`. The groups run 300 Inbox
programs, 1000 failure-and-report list-model programs and 1000 causal service programs
of 50–60 gates plus joined shutdown tails. These sample three issue IDs; they do
not demonstrate 1000 distinct seeds or 1000 simultaneous sessions. Resource
receipts verify acquired/closing/released order and no premature redispatch.
Actor-failure deadlock, failure precedence and pre-entry cancellation regressions
failed before fixes. Independent effects retain reports even when sharing one
exception value; three regressions and the list model reject the previous code.
`Service_failure` owns fatal arbitration and redaction;
`Scenario.run` owns test-gate closure before joins. Replay one script with
`dune exec test/service_replay.exe -- --seed N --prefix N` from `ocaml/`.
The full local OCaml gate passes with 325 source files, 17 rejected type clients,
two valid assemblies and 72 unchanged input CMIs in both compiler-client modes.
PR #9 merged as d88f0df; exact-head Linux/macOS PR and push logs pass these
counts. Native capacity now holds 1/10/100/1000 actual scoped fake workers under
the host clock, checks independent acquisition/owner-entry facts, measures 100
poll cycles and joins complete shutdown. All four local macOS cases pass;
1000 releases/completions match, 1427 handles retire and no call remains pending.
See [physical capacity evidence](docs/design/service-capacity.md) for the measured
units and limits. Linux/macOS PR and push capacity gates pass at implementation
head f4cb776; all 16 archived manifests and four raw boundary logs were checked.
The current source gate covers 335 files; 12 measurement examples/laws and 23
parent controls in both Python modes pass. These are scoped fake workers.
Authenticated app-server acceptance, static release, latency regression baselines, HTTP API and the
portable conformance harness remain pending.
Crowbar random campaigns are distinct from instrumented AFL coverage.

The closed runner uses the pinned stable Codex 0.159.2 JSONL protocol under the
existing native process/workspace brackets. Targeted local evidence passes
146 protocol/session/runner cases, 65 core examples and 29 core property groups,
36 service examples and nine actual owned fake-server subprocess cases.
The schema gate validates 67 actual encoded fixtures and rejects 42 controls in
normal and optimized Python modes. Native cases check three turns on one thread,
one-byte pipe writes, stderr backpressure, exact usage above 2^53, interruption,
malformed/truncated frames, separate response/silence deadlines and child reaping
before after_run and lease release. The full local gate checks 379 source files
and 73 unchanged CMIs; Linux/macOS hosted receipts were audited before merge. These results do not
establish live Codex authentication, model
behavior or sandbox enforcement. Closed fake runners and the native fake server
remain separate evidence from executable assembly acceptance and live provider acceptance.
Codec receipts retain actual messages, validator logs, schema provenance and
exporter/checker/lock/Python identities without claiming binary attestation.
Review regressions cover retained stall cadence during tracker reads and repeated
refreshes, both worker/read closure orders, terminal cleanup during shutdown,
preparation/protocol receipt interruption, and accounting-only completed-turn
usage. Initialization, input and continuation handoffs settle accepted batches
before returning; active and continuation input cleanup retain typed write,
protocol and drain failures. Replay records and bytes retire together at the
validated next-turn boundary; identical same-turn requests replay the recorded reply
without another progress fact, and conflicting payloads fail. All ordered
pending/active terminal pairs reject conflicting outcomes
and preserve identical replays. Closing checks buffered conflicts/malformed
suffixes under the original cancellation/stall cause and deadline.
Reader cancellation/join defects preserve the original callback error or
exception/backtrace; a successful callback still exposes its closing defect.
Whole-cycle capacity timing
follows Idle completion; a held scoped read/finalizer cannot be replaced by a
timer-rearming sample.

Merged crypto refresh [PR #5](https://github.com/ethan-wickstrom/symphony/pull/5)
at `c97cff2`: exact-head Linux/macOS PR/push CI and independent receipts pass.
Local crypto refresh gate: 256 example/property tests (61 properties),
239 source/interface files, 63 CLI scenarios, 39 source-gate controls and 260,000
Crowbar invocations in 26 groups at seed `20260930` pass.
`crypto_boundary_test.ml/.mli` states RSA and NIST rejection laws; bounded crypto
fuzz targets preserve checked errors. RSA-signed loopback controls verify exact TLS
diagnostics, no credential disclosure and bounded peer termination (FIN or RST).
The close observer rejects unrelated errors and preserves defects. Old-version failures precede
the dependency refresh; see [security evidence](docs/design/crypto-security-plan.md).
Build, formatting, interface pairing and protocol snapshot checks pass, normally
and optimized, with 16 corrupted-fixture controls.

The policy also checks 100 explicit fault/cancellation scenarios, a full rollback
trace and persistent-driver operation sequences. Separate native tests exercise
physical locks, filesystem identities, exact-source ownership/retirement and
actual hook subprocesses through the public host: 51 kernel, seven Host and 27 HTTPS/registry cases
pass under the watchdog in both modes. The lifetime gate checks 1,000
seeded real Eio mock scenarios, including rejected callbacks and release/reporter
defects; this is not yet the whole-service simulator. Retained frozen process
custody passes on Linux/glibc and macOS. Musl/static linkage remains unverified.
The macOS development binary currently loads Homebrew GMP; a release must link
that archive statically and pass a clean-host dependency check before claiming
a single-file deployment.
An isolated macOS arm64 release-profile build now passes 241 core cases,
63 copied-executable CLI scenarios and 78 native cases per Python mode.
Its 12889176-byte evidence executable imports only libSystem; the actual
link/map selects the owned static GMP archive after Zarith and before runtime.
Physical verifier/control evidence is documented in
[release evidence](docs/design/release-evidence.md). These local observations
do not certify a clean macOS26.0 host, a reproducible build, Linux musl or a
complete service release.
Compiler-target trust defaults and one shared deferred crypto runtime pass real
CLI and overlapping registry controls. A delayed-start watchdog control separates
bounded fixture readiness from the unchanged run timeout and retains actual PID
probes after TERM/KILL cleanup.
Hook-result regressions preserve timeout, exit and stream failures across cleanup
errors; native cases check semantic identity, mapper suppression and conversion
only after reap. The caller's error type passes directly through both brackets.

Real integration results will be reported independently as passed, failed, or skipped.

Hosted slice-three evidence: [PR run 36883354256](https://github.com/ethan-wickstrom/symphony/actions/runs/36883354256)
and [push run 36883346701](https://github.com/ethan-wickstrom/symphony/actions/runs/36883346701)
passed at `06ce6c577c48142b7fb89cf8223c3c35acdf0184`.
[PR #3](https://github.com/ethan-wickstrom/symphony/pull/3) merged at
`98833b39c59a2def4257ac5ac9e405e1010554ca` on `2026-10-01T15:36:13Z`.
Four native normal/optimized manifests match all 156 selected committed source
hashes plus the watchdog/sentinel and pass 78 cases each (50 kernel, seven Host,
21 HTTPS). Both custody manifests match all nine frozen Eio hashes and 5,000
scenarios per host. Linux records 2,000 normal closes and zero cleanup/repeated-signal
EPERM values. macOS records 1,999 normal closes, one conservative cleanup EPERM
and 31 repeated-signal EPERM values; both retain 2,000 stable explicit close outcomes.
Focused custody and normal/optimized admission controls pass.
`/private/tmp/symphony-hosted-06ce6c5/verification.json` and
`/private/tmp/symphony-hosted-06ce6c5/local-source-verification.json` report zero
hosted/local source mismatches.
Recorded binary hashes are context only: retained archives exclude executables,
and no source-to-binary attestation is claimed.

Previous slice-two evidence: [PR run 36844689498](https://github.com/ethan-wickstrom/symphony/actions/runs/36844689498)
and [push run 36844682548](https://github.com/ethan-wickstrom/symphony/actions/runs/36844682548)
passed at `98e9d6a9438568fc0a8fb6eb0450bb522712bf65`, merged as `92f7ac6`.
Four normal/optimized native
manifests match 56 selected source hashes plus the watchdog/sentinel; both custody
manifests match all nine frozen Eio hashes. Devin analysis was unavailable because its
diff-size limit excludes this import; independent native reviews completed.
Each custody campaign passes 5,000 scenarios. Linux records 2,000 successful closes;
macOS records 1,999 successes plus one conservative EPERM cleanup error preserved
by the frozen contract, with 73 repeated-signal errors also visible.

## Live executable assembly

`ocaml/bin/service_cli.ml` composes one captured registry, environment, HTTP
bootstrap, native clock, workspace host and closed runner under the existing
Service scheduling owner. Direct/default/run CLI syntax, initial validation,
invalid workflow reload blocking/recovery, fresh issue preflight, same-thread
continuation, active SIGINT/SIGTERM, hook/worker closure and escaped diagnostics
passed the earlier 24 local scenarios in both modes. That historical gate covered
391 source files/39 controls, 17 rejected clients, two valid assemblies and 73
unchanged CMIs, plus 28 native lifecycle cases. Hosted review then reproduced
missing signal-setup reporting and incomplete issue/session log context in
_build/live-dispatch-{startup-fd-red,context-red}.log. Targeted corrections pass
_build/live-dispatch-review-green.log, with receipts in
_build/live-dispatch-review-green-xurkg4d2. All 25 replacement scenarios now pass
in both modes (_build/service-cli-JWgykX). Its independent-verification.json
checks all 50 bounded operator logs, 30 actual peer acquisitions, five current
input hashes, runtime digest, FD equivalence and causal controls. Both FD cases
record limit64/headroom3, successful doctor then service123 with fixed early output.
Configured local coverage is complete through live-dispatch-review-{full-check,
service-cli,remaining-check}.log and formatting: passed native dependencies were
not repeated after the oracle stopped the first full-check. The exact-head hosted
audit passed for Linux/macOS push and PR runs: 200 CLI cases, 120 peer acquisitions,
224 lifecycle checks and 16 capacity manifests. PR #12 merged as 40d6b63 on
2026-10-05 with an identical tree to reviewed 2b58097; receipts are retained in
_build/live-dispatch-hosted-audit.json and live-dispatch-merge-receipt.json.
The replacement run exposed a last-session oracle error: continuation turn notices
change the thread/turn session ID. The oracle now follows all same-issue/run
session/turn notices; no production correction was required. Failure receipts
remain in _build/service-cli-Uqfwqm/normal.

Issue records use issue_identifier. Worker closure selects only the exact previous
issue/run/session, or reports not_started; hooks carry their checked reference
identifier. Paired secondary lookup requires the exact generation and marks
unknown Worker/Retry context unavailable while retaining checked opaque issue_id
and generation. Identifier/session fields are not invented, and that exceptional
host-port path is not a full-conformance claim. Ordered acknowledged native runner notices
are the boundary; the projection session guard alone does not prove general
sequence acceptance. The early setup reporter runs after full closure, is bounded
and preserves the original failure. It never retries after output callback entry
or sink failure.

`native_shutdown.ml` owns scoped signal/self-pipe custody through output closure.
`native_output.ml` publishes bounded non-suspending records to an owned writer.
Meaningful regressions reproduced false cancellation cleanup reports and recorded
output failure being superseded by a later clock defect. See
[live-dispatch contract](docs/design/live-dispatch.md) for arbitration, limits and
fixture/provider evidence boundaries.

## Portable harness checkpoint

The [standalone package](conformance/README.md) owns process/capture mechanisms,
shared TLS fixtures, all 314 generated stable schemas, the fixed corpus and an
offline judge. Profiles translate public launch/workflow/log behavior. Sealed
wire, lifecycle and capture evidence replays without executing a candidate.
All 106 SPEC checklist rows and 12 supplemental clauses remain in each report.

The first public OCaml lifecycle completed with twelve assertions passing and
numeric usage unobservable in the public log. The independent scripted profile
passed thirteen assertions. This is partial scope: complete core conformance
remains incomplete. All 129 controls and nine fault calibrations pass in normal
and optimized Python. The external wheel passes every case in both modes; 97
receipt-reader corruption controls pass per mode. Hosted review remains before
merge. Trusted fixture instrumentation
and execution-account authority are explicit; hashes do not attest a malicious
same-account candidate or inventory unknown quiet descendants.
