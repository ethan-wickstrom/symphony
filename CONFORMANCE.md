# OCaml conformance

Status: slices 1 and 2 are merged. Slice 2 implements native owned workspaces, four hooks,
scoped process custody and non-creating inspection. Native gates pass normally
and optimized on macOS and Linux/glibc at `98e9d6a`; hosted artifacts match the
committed source hashes. The full service
remains pending. Slice 3's Linear adapter and native HTTPS inspection now pass local
gates; hosted validation and merge are pending.
The upstream Elixir implementation is reference material, not evidence for this port.
Requirements refer to SPEC.md at `be10a1b79df723d6d7612b5651c8522704dafb2e`.
Current protocol fixture: Codex 0.159.2. Stable core and experimental tool
profiles must record schema digests, generator flags, and initialization capabilities;
schema generation is not a passing client test. See [protocol audit](docs/protocol-audit.md).

## Section 18.1 checklist

| Requirement | Planned slice | Implementation/test evidence | Status |
| --- | --- | --- | --- |
| Explicit workflow path and cwd default | 1, 7 | `ocaml/bin/cli.ml`; `ocaml/test/cli_check.py` explicit/default/anchoring cases | Inspection CLI passed; daemon pending |
| YAML front matter and prompt split | 1 | `workflow_document.ml`, `config_value.ml`; `workflow_parser_test.ml` workflow/YAML examples and tree/line models | Passed locally |
| Typed defaults and `$` resolution | 1 | `config_layer.ml`, settings modules; `config_test.ml` defaults, env/path/numeric/state cases | Passed locally |
| Dynamic workflow reload/re-apply | 1, 4 | `Config_layer.Make.apply`; `config_model.ml`, `config_test.ml` reload histories | Pure laws passed; watch/owner application pending |
| Single-authority polling orchestrator | 4 | — | Pending |
| State-list and ID-refresh tracker reads | 3 | `linear_tracker.ml`, `linear_pager.ml`, `linear_record.ml`, `tracker_registry.ml`; independent boundary/pagination/binding models, `linear_tracker_test.ml`, `native_http_test.ml`, real `tracker_cli_check.py` | Local reads, frozen auth/current policy, atomic failures and verified HTTPS passed; hosted gate pending |
| Sanitized collision-resistant workspaces | 2 | `workspace_key.ml`, `workspace_reference.ml`, `workspace_owner.ml`, `native/workspace_directory.ml`, `workspace_store_posix.ml`; key/owner models, hash vectors, parser fuzzing, `native_directory_test.ml`, `native_store_test.ml` | Descriptor/lock/identity/replacement/rollback cases passed locally and on both CI hosts |
| Four workspace lifecycle hooks | 2 | `workspace_manager.ml`, `workspace_hooks.ml`; policy models, fake-port hook tests and `native_host_test.ml` frozen lifecycle/cancellation/rollback cases | Fake and live cases passed locally and on both CI hosts |
| Configurable hook timeouts | 1, 2 | `workspace_settings.ml`, `workspace_hooks.ml`, `clock_posix.ml`; config and monotonic-clock models, independent stream faults, noisy output, native hook timeout | Config/interpreter/subprocess cases passed locally and on both CI hosts |
| App-server subprocess transport/framing | 5 | — | Pending |
| Configurable Codex launch command | 1, 5 | `agent_settings.ml`; `config_test.ml` verbatim/empty/NUL validation | Config passed; launch pending |
| Strict issue/attempt prompt rendering | 1 | `template.ml`; `template_test.ml` strictness/scope/limits, independent AST and rational models; CLI fixture rendering | Passed locally for documented strict Jinja profile |
| Failure backoff and continuation retries | 4 | — | Pending |
| Configurable retry cap | 1, 4 | `scheduling_policy.ml`; `config_test.ml` defaults/positive coercion | Config passed; retry scheduling pending |
| Terminal/non-active reconciliation | 4 | — | Pending |
| Terminal startup/transition cleanup | 2, 4 | — | Pending |
| Required structured log context | 6 | — | Pending |
| Operator-visible observability | 1–7 | `diagnostic.ml`, `ocaml/bin/cli.ml`, `workspace_cli.ml`; `cli_check.py`, `workspace_cli_check.py` file/key/remedy/redaction, missing/owned/busy/foreign/symlink inspection | Workflow and workspace CLI passed; service snapshots/logs pending |

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
Seeded whole-service Eio simulation, orchestrator model agreement, static release,
1,000-session benchmarks, HTTP API and portable harness remain pending their slices.
Crowbar random campaigns are distinct from instrumented AFL coverage.

Current local application gate: 241 example/property tests (61 properties),
232 source/interface files, 62 CLI scenarios, 39 source-gate controls, and 220,000
Crowbar invocations in 22 groups at seed `20260930` pass.
Build, formatting, interface pairing and protocol snapshot checks pass, normally
and optimized, with 16 corrupted-fixture controls.

The policy also checks 100 explicit fault/cancellation scenarios, a full rollback
trace and persistent-driver operation sequences. Separate native tests exercise
physical locks, filesystem identities, exact-source ownership/retirement and
actual hook subprocesses through the public host: 50 kernel, seven Host and 17 HTTPS cases
pass under the watchdog in both modes. The lifetime gate checks 1,000
seeded real Eio mock scenarios, including rejected callbacks and release/reporter
defects; this is not yet the whole-service simulator. Retained frozen process
custody passes on Linux/glibc and macOS. Musl/static linkage remains unverified.
The macOS development binary currently loads Homebrew GMP; a release must link
that archive statically and pass a clean-host dependency check before claiming
a single-file deployment.
Hook-result regressions preserve timeout, exit and stream failures across cleanup
errors; native cases check semantic identity, mapper suppression and conversion
only after reap. The caller's error type passes directly through both brackets.

Real integration results will be reported independently as passed, failed, or skipped.

Hosted slice-two evidence: [PR run 36844689498](https://github.com/ethan-wickstrom/symphony/actions/runs/36844689498)
and [push run 36844682548](https://github.com/ethan-wickstrom/symphony/actions/runs/36844682548)
passed at `98e9d6a9438568fc0a8fb6eb0450bb522712bf65`, merged as `92f7ac6`.
Four normal/optimized native
manifests match 56 selected source hashes plus the watchdog/sentinel; both custody
manifests match all nine frozen Eio hashes. Binary hashes identify executed artifacts
without asserting build attestation. Devin analysis is unavailable because its
diff-size limit excludes this import; independent native reviews completed.
Each custody campaign passes 5,000 scenarios. Linux records 2,000 successful closes;
macOS records 1,999 successes plus one conservative EPERM cleanup error preserved
by the frozen contract, with 73 repeated-signal errors also visible.
