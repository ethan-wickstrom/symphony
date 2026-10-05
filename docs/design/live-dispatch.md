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
process. Before output callback entry, a signal-setup failure receives one fixed
bounded host_startup_failure record after all acquired scopes close. The reporter
preserves the original failure even if reporting fails. Once the callback has
entered, or the sink has failed, no second writer or reporting retry is created.
No synchronous stderr fallback can hold the scheduling domain.

Records expose service start/readiness, dispatch, selected session/turn progress,
hooks, workflow/tracker/attempt faults, shutdown and joined worker closure.
Issue fields are issue_id and issue_identifier. Worker/session/turn records also
carry run_id. Hook identifiers come from their checked workspace reference.
Worker closure uses the previous immutable projection only when both issue and
run match. It retains the last observed session_id with session_state=started;
an attempt without a session reports session_state=not_started and no session_id.
Session IDs include thread and turn; continuation on the same thread changes the
ID at turn notices.
Paired secondary context likewise requires an exact generation. Unknown Worker/
Retry generations retain checked opaque issue_id and generation with
context=unavailable, without invented identifier/session fields. This exceptional
host-port boundary is not a full-conformance claim. Runner notices are ordered and acknowledged;
the projection's session guard is not a generic sequence-acceptance proof.
Whitespace, equals, backslash and non-ASCII bytes escape as `\xhh`.
Raw agent messages/stderr and arbitrary provider payloads never enter records.

## Evidence and limits

The native host suite tests actual POSIX signals, restored handlers/descriptors,
first-signal coalescing, cancellation and bounded output with controlled sinks.
The CLI harness executes the built binary against a local TLS Linear fixture and
an actual JSONL peer process. Requests are validated semantically; process/cwd,
prompt, environment, hooks and reap gates produce retained receipts. Normal and
optimized Python runs have independent manifests, input hashes and runtime IDs.
Linux/macOS CI runs the same harness and archives its evidence even on failure.

The harness now has 25 cases. Controlled descriptor exhaustion first proves
doctor startup succeeds with the same workflow and FD budget, then requires the
service's fixed pre-output failure record and nonzero exit without service_started.
Strict context checks cover issue_identifier, last-session closure and the
no-session shell failure. Both defects failed before correction; targeted controls
pass in _build/live-dispatch-review-green.log. All 25 scenarios pass normally and
optimized in _build/service-cli-JWgykX; its independent-verification.json checks
50 bounded logs, 30 peer-mode receipts, current inputs/binary and causal controls.
Configured local coverage is complete through the combined full-check dependency
run, corrected executable run and remaining check body. Exact replacement-head
hosted evidence remains pending. Earlier 24-case receipts are historical evidence.
The replacement run corrected a test oracle that considered only session_started
and missed the continuation's new session ID; production closure was correct.

These fixtures establish executable assembly behavior, not authenticated Codex
compatibility, provider sandbox enforcement or real-process 1000-session capacity.
HTTP status/API, live provider acceptance and clean-host/static release
qualification remain separate checkpoints.
