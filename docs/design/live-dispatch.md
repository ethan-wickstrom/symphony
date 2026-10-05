# Live dispatch executable

`symphony [WORKFLOW]` defaults to `./WORKFLOW.md`. The explicit `run` command
shares the same service assembly. Cmdliner owns parsing, help and exit codes.
Inspection commands retain their offline/read-only capabilities.

## Composition

```text
CLI -> Service_cli -> Service_assembly -> Service -> Orchestrator
                      |                 |         state + commands
                      |                 + owned attempts
                      + Tracker_runtime / Workspace_host / Codex_runner
                        workflow / HTTPS / process / clock drivers
```

The executable captures one startup environment, HTTP bootstrap and named native
clock. Service_cli creates one tracker registry inside the operator-output scope;
its warning callback publishes without suspending. The same registry resolves
initial settings and every reload. Service_assembly retains exact clock,
workspace, tracker binding and runner completion type equalities. No alternative
scheduler, mutable configuration authority or direct controller socket client is
introduced.

Config.resolve compiles prompt syntax before accepting a document. Invalid
startup is visible and nonzero. Reload retains the last valid configuration for
ongoing work while blocking all admission; actual file contents are reread by
existing poll/dispatch preflight. An admitted attempt retains its launch settings,
credential binding, child environment, prompt and hooks until closed.

## Resource and output custody

The outer signal bridge installs scoped SIGINT/SIGTERM handlers. A handler only
latches the first signal and writes one byte to a nonblocking self-pipe. Its
joined Eio reader resolves a promise; an owned control producer forwards Shutdown
to Service. Repeated signals coalesce while workers, hooks and output close.
Signal handlers and descriptors are restored only after that closure.

Service owns admission and physical attempt custody. Worker completion is
published only after the process/session, after_run hook and workspace lease
close. The caller joins the control producer. Every independently acquired
signal release is attempted; callback failures retain their identity and
backtrace over secondary cleanup defects.

Operator publication is bounded and non-suspending. One owned asynchronous
writer serializes FIFO ASCII records to the caller's stderr sink. The sink remains
caller-owned. Records are limited to 4096 encoded bytes and outstanding output to
1048576 bytes, including the writer's current record. Invalid records, overflow
or output failure fail the scope; records are never silently dropped/truncated.
Closure attempts a flush with the same clock at a fixed 1000 ms deadline and
joins the writer. Sink operations must support Eio cancellation; arbitrary
protected finalizers have no finite-duration guarantee.

Original callback diagnostics/exceptions win secondary output/cleanup faults.
Otherwise the first recorded output failure wins later defects. Known output I/O
failures use fixed redacted diagnostics; unknown original defects retain their
identity/backtrace. A failed sink cannot guarantee delivery of secondary records.
Signal teardown occurs after the output scope closes; secondary bridge diagnostics
cannot be delivered through that writer, but primary teardown defects fail the
process. No synchronous stderr fallback can hold the scheduling domain.

Records expose service start/readiness, dispatch, selected session/turn progress,
hooks, workflow/tracker/attempt faults, shutdown and joined worker closure.
Issue fields carry canonical checked IDs; run/session fields come from the actual
observation. Whitespace, equals, backslash and non-ASCII bytes escape as `\xhh`.
Raw agent messages/stderr and arbitrary provider payloads never enter records.

## Evidence and limits

The native host suite tests actual POSIX signals, restored handlers/descriptors,
first-signal coalescing, cancellation and bounded output with controlled sinks.
The CLI harness executes the built binary against a local TLS Linear fixture and
an actual JSONL peer process. Requests are validated semantically; process/cwd,
prompt, environment, hooks and reap gates produce retained receipts. Normal and
optimized Python runs have independent manifests, input hashes and runtime IDs.
Linux/macOS CI runs the same harness and archives its evidence even on failure.

These fixtures establish executable assembly behavior, not authenticated Codex
compatibility, provider sandbox enforcement or real-process 1000-session capacity.
HTTP status/API, live provider acceptance and clean-host/static release
qualification remain separate checkpoints.
