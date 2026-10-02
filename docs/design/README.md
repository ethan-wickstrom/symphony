# OCaml design

Approved on 2026-09-30: policies P01–P08/D01–D13, all component interfaces,
dependencies and test plans; Linear first, macOS operation/development and Linux
musl static release. [Slice 1](../slice-1.md) implements the workflow boundaries.
Remaining interfaces describe later slices. Implemented `.mli` files under
`ocaml/lib/` are authoritative for their current contracts.

## Eight component interfaces

| SPEC §3.1 component | Interface | Responsibility |
| --- | --- | --- |
| Workflow Loader | [workflow_loader.mli](interfaces/workflow_loader.mli) | Bounded source read; expected failure values; parse once. |
| Configuration Layer | [config_layer.mli](interfaces/config_layer.mli) | Checked effective settings, original adapter binding, last-good reload and dispatch readiness. |
| Issue Tracker Client | [tracker_adapter.mli](interfaces/tracker_adapter.mli), [tracker.mli](interfaces/tracker.mli) | Provider contract plus portable states/IDs read kernel; no generic writes. |
| Orchestrator | [orchestrator.mli](interfaces/orchestrator.mli) | Pure `state -> event -> state * command list`; immutable ownership and admission. |
| Workspace Manager | [workspace_manager.mli](interfaces/workspace_manager.mli) | Frozen workspace references; scoped live directories, hooks and owned cleanup. |
| Agent Runner | [agent_runner.mli](interfaces/agent_runner.mli) | Typed phases; turns and owner-mediated continuation; resource-completion witness. |
| Status Surface | [status_surface.mli](interfaces/status_surface.mli) | Fresh owner query, JSON API and escaped HTML; coalesced refresh. |
| Logging | [logging.mli](interfaces/logging.mli) | Bounded escaped/redacted entries; sink failure cannot change scheduling. |

The component signatures have small supporting modules rather than one large public
record. [Algebras](algebras.md) gives their models/equations;
[testing](testing.md) gives each slice's independent oracle and examples;
[verification](verification.md) plans all eight ambitious targets;
[protocol](protocol.md) records the generated-schema client profile.
Dependencies and targets are justified in [decisions](../decisions.md#toolchain-and-dependencies).

## Assembly and intentional equalities

```text
                    CLI / Eio host capabilities
                              |
                         Service.Make
                    mailbox + command interpreter
                      /                    \
       Orchestrator.Make                 IO mechanisms
         pure owner state        loader / tracker / workspace / agent / log
                |                            |
     checked domain + policy      filesystem / HTTP / process / clock drivers

HTTP -> Status_surface -> owner query -> Core.snapshot
workers / timers / tracker replies -> owner mailbox -> Core.step -> commands
```

The owner is the only reader/writer of scheduling state. The effectful mailbox adds
snapshot reply capabilities outside pure core events. Effects never call back into
mutable state. Listener, workers, jobs, watcher and timers belong to the service switch;
normal shutdown requires both core quiescence and runtime resource drainage.

[service.mli](interfaces/service.mli) assembles the same modules as the pure functor:

```ocaml
Agent.Contract.Issue = Tracker.Contract.Issue
Agent.Contract.Path = Workspace.Contract.Path
Agent.Contract.workspace = Workspace.Contract.reference
Config.tracker = Tracker.Contract.binding
Core.instant = Clock.Pure.instant
Core.clock_sample = Clock.Pure.sample
```

These are declared in the functor parameters/results, before implementations.
Workspace references use checked identifiers, not Issue.t; the workspace contract
has no Issue module. Its reference functor equates the input/output Path.t capability
types without exporting a driver's private constructors or extra operations.
`Issue.S.t` is the one normalized `Issue.t`. Workspace launch authority remains
abstract in `Path.t`; a wire cwd is never equal to it. Milliseconds, seconds, UTC,
monotonic instants, issue IDs/identifiers, run/retry/request IDs and protocol IDs are
distinct. Each allocator is functional and owned by its corresponding state machine.

Agent has no tracker credential or provider capability. Its continuation callback
asks the owner to read the original binding, update the canonical issue, and reply.
The launch request freezes its workspace reference and child environment; later root
or credential changes cannot redirect cleanup or affect an existing attempt.
Future provider tools require a separate authorized capability, after core conformance.

[tracker_registry.mli](interfaces/tracker_registry.mli) packages an adapter with its
matching IO context existentially. Runtime `tracker.kind` selects this first-class
module. It never creates provider branches in Core. [linear_tracker.mli](interfaces/linear_tracker.mli)
instantiates that contract over [http_transport.mli](interfaces/http_transport.mli).
Credentials are abstract, destination-bound and printed only as redacted text.

[app_server.mli](interfaces/app_server.mli) composes the actual protocol mechanism
with a process driver and clock. Simulations retain that client and substitute lower
byte/process/HTTP/filesystem drivers, rather than replacing a turn with canned success.
No objects or polymorphic variants are needed in the project interfaces.

## Ownership and terminal states

[issue_lifecycle.mli](interfaces/issue_lifecycle.mli) distinguishes starting, active,
stopping runs; waiting, refreshing and parked retries; and cleanup.
Closed completion witnesses have separate retryable, releasable and cleanable
types. Only a retryable completion can queue; only a post-read Refreshed witness
can resume. These transition witnesses cannot be stored in the owner collection.
`Agent.completed` has no public constructor. A turn-completed notification is insufficient.
Runtime ID equality and OS lifetime cannot be dependent/linear OCaml types; the
hidden lifecycle/driver boundaries enforce those checks once and test their laws.

[ownership.mli](interfaces/ownership.mli) owns one persistent priority search queue
keyed by `Issue_id`, with the canonical owner as its payload. Waiting rank derives
from its due instant; every other role is inactive. There is no separate map,
heap or stale-entry history. Projection laws check the independent list model.
`claimed` is derived as running-ownership IDs
union retry IDs. Stopping/draining runs retain their worker slot until resource completion;
cleanup keeps ownership while holding no worker slot.
Status presents cleanup separately. Released IDs and finished watermarks are discarded.

Per-run observation sequences fence duplicate progress; run, retry and request tokens
fence late completions. Absolute thread totals join against one `(Run_id, Thread_id)`
watermark across turns. Poll/reconciliation/continuation reads are serialized per issue;
an older reply cannot replace a newer accepted issue. A consumed retry timer under a
blocked workflow keeps its owner and gets a valid-reload wakeup or replacement timer.

D11 is an admission law. Existing workers may exceed a lowered cap or new state bucket;
new launches must satisfy the current global and state capacities. All launch paths,
including retries, consult readiness. Invalid loads preserve effective settings and
publish the error. Only the latest accepted load request changes readiness.

## Layout

```text
ocaml/
  lib/
    domain/       checked IDs, units, issue, JSON, diagnostics, usage
    workflow/     YAML tree, document, loader, strict template, settings/reload
    ports/        tracker, workspace, agent, clock, log contracts
    tracker/      registry, Linear adapter, injected HTTP driver
    workspace/    reference/lease mechanism, hooks, POSIX directory driver
    orchestration/ lifecycle, canonical owner PSQ, ordering, backoff, event core
    agent/        JSONL framer, selected codec, app-server client, runner
    runtime/      Eio clock, process groups, mailbox, command interpreter, watcher
    status/       snapshot projection, route formatter, HTTP listener
  bin/            Symphony CLI, doctor and dry run
  test/           Section 17 examples, independent models and QCheck properties
  sim/            lower fakes, seeded scenarios, trace/replay/shrinking
  fuzz/           one bounded target for every parser
  bench/          physical-clock startup/resource/tick measurements
conformance/      separately published executable/package, drivers and fixtures
protocol/         retained schema manifest and consumed fixture/schema definitions
docs/             decisions, algebra/design, adapter/release profiles, reproductions
CONFORMANCE.md    every §18.1 item mapped to its implementation and passing test
```

Each implementation file has an `.mli`; interfaces move from this flat review folder
into their owning library when a slice starts. Libraries enforce the dependency DAG;
Core links only pure domain, policy and port contracts. Drivers implement immediate
lower ports; API cannot reach a tracker, filesystem or process directly. No speculative
provider-helper extraction. The conformance package cannot import Core.

## Build order and slice gates

| Slice | Small working outcome before the next slice |
| --- | --- |
| 1 | Workflow inspection command: load/resolve/render/reload, explicit source and env; models, §17.1 examples, parser fuzz targets. |
| 2 | Workspace preparation/hook inspection using checked paths, ownership and fake process; §17.2 and real host path tests. |
| 3 | Linear candidate/read inspection and fake endpoint; published §11.2 profile, §17.3 fixtures and pagination/error models. |
| 4 | Owner dispatch against fake agents, full retry/reconciliation loop, Eio command shell and seeded simulator; §17.4/model agreement. |
| 5 | Actual schema-targeted app-server launch/handshake/turns/continuation/accounting over the same service; §17.5 and real process tests. |
| 6 | Production log sink, fresh snapshot/API/minimal HTML; §17.6 and §13.7 route/escaping/availability tests. |
| 7 | Operator CLI, lifecycle, doctor/dry run, target packaging; §17.7 and clean host walkthrough. |
| 8 | Published portable harness and calibrated resource/performance gates; every §18.1 item has concrete evidence. |

Use a minimal diagnostic sink from slice 1 to keep errors observable; enrich the
structured sink in slice 6. Each slice begins with its signatures, model and
properties for review, then implementation, examples/fuzz targets and relevant checks.
Keep each merged slice usable; no pending production placeholders. Design sketches
here do not require creating every module at once. Changes to an intentional equality
require reworking the signature, not a late constraint to patch compilation.

## Validation

The original signatures and assembly witness type-checked with every warning fatal on OCaml
5.5.0 and 5.3.0. The latter is the unrelated existing `ortac-tools` switch; it was not
modified. Compiled artifacts stay in `/private/tmp/symphony-signature-check/`.
Installed ast-grep has no OCaml grammar; compiler parsing/dependency/type checks were
used after that limitation was found. This is not an ast-grep success report.

Slice 1 now compiles against its actual interfaces in an isolated OCaml 5.5.0 switch.
Its independent models, CLI checks and boundary gates are recorded in
[the worklog](../worklog.md). The settings contract was refined into pure
`Tracker.CONFIG`, extended by live `Tracker.S`; their shared settings types are
declared before either implementation. No approval gate remains for this slice.
Whole-service simulation, performance, static linking and live Codex verification
remain later gates.
