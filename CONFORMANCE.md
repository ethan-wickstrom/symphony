# OCaml conformance

Status: slice 1 is merged. Slice 2 implements native owned workspaces, four hooks,
scoped process custody and non-creating inspection. Complete macOS native gates
pass normally and optimized; current-head hosted Linux/macOS gates are pending. The full service
remains pending.
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
| State-list and ID-refresh tracker reads | 3 | — | Pending |
| Sanitized collision-resistant workspaces | 2 | `workspace_key.ml`, `workspace_reference.ml`, `workspace_owner.ml`, `native/workspace_directory.ml`, `workspace_store_posix.ml`; key/owner models, hash vectors, parser fuzzing, `native_directory_test.ml`, `native_store_test.ml` | Local descriptor/lock/identity/replacement/rollback cases passed; hosted gate pending |
| Four workspace lifecycle hooks | 2 | `workspace_manager.ml`, `workspace_hooks.ml`; policy models, fake-port hook tests and `native_host_test.ml` frozen lifecycle/cancellation/rollback cases | Local fake and live cases passed; hosted gate pending |
| Configurable hook timeouts | 1, 2 | `workspace_settings.ml`, `workspace_hooks.ml`, `clock_posix.ml`; config and monotonic-clock models, independent stream faults, noisy output, native hook timeout | Local config/interpreter/subprocess cases passed; hosted gate pending |
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

Current local application gate: 122 example/property tests, 41,500 model/law cases,
178 source/interface files, 27 CLI scenarios, 34 source-gate controls, and 150,000
Crowbar invocations at seed `20260930` pass.
Build, formatting, interface pairing and protocol snapshot checks pass, normally
and optimized, with 16 corrupted-fixture controls.

The policy also checks 100 explicit fault/cancellation scenarios, a full rollback
trace and persistent-driver operation sequences. Separate native tests exercise
physical locks, filesystem identities, exact-source ownership/retirement and
actual hook subprocesses through the public host: 47 kernel and seven Host cases
pass under the watchdog in both modes. The lifetime gate checks 1,000
seeded real Eio mock scenarios, including rejected callbacks and release/reporter
defects; this is not yet the whole-service simulator. Retained frozen process
custody passes on Linux/glibc and macOS. Musl/static linkage remains unverified.

Real integration results will be reported independently as passed, failed, or skipped.
