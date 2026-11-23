# Symphony in OCaml

Checked workflow loading, configuration, strict prompt rendering, last-good reload
and native owned workspaces/hooks are implemented. `doctor`, `dry-run`, `workspace`
and authenticated Linear `tracker` inspection work locally. Pure scheduling and
typed lifecycle transitions and the scoped Eio owner are implemented. Native
fake-session capacity is measured. The executable composes authenticated Linear
polling, native workspaces and closed Codex app-server attempts. Local acceptance
uses actual TLS and subprocesses with fake providers; authenticated Codex
acceptance remains pending. The optional status API passed local and Linux/macOS
hosted verification and merged in PR #13.

## Build

Install opam, a C compiler, pkg-config and GMP development files. From this directory:

```sh
opam switch create . ocaml-base-compiler.5.5.0 --no-install --yes
opam pin add yaml.3.2.0 ../vendor/yaml --no-action --yes
opam pin add crowbar.0.2.2 ../vendor/crowbar --no-action --yes
opam pin add eio.1.6 ../vendor/eio --no-action --yes
opam pin add eio_posix.1.6 ../vendor/eio --no-action --yes
opam pin add h1.1.1.1 ../vendor/h1 --no-action --yes
opam install . --deps-only --locked --with-test --with-dev-setup --yes
opam exec --switch . -- dune build @all
```

All five pins are mandatory: YAML releases native parser/events and preserves
embedded NUL bytes; Crowbar fixes a random-input refill hang. Eio resumes callers
when worker acquisition fails; Eio POSIX retains child identity through cleanup.
H1 rejects malformed chunk lengths/status and exposes pending errors before EOF.
The executable uses the POSIX backend on both target platforms.
[YAML provenance](../vendor/yaml/PATCHES.md),
[Crowbar provenance](../vendor/crowbar/PATCHES.md),
[Eio provenance](../vendor/eio/PATCHES.md),
[H1 provenance](../vendor/h1/SYMPHONY_PATCHES.md). The lock records exact
transitive versions and excludes machine-specific local URLs. Pin these sources
before installing. The current macOS development binary requires Homebrew GMP
and macOS 26.0. A clean-host macOS binary and a fully static Linux musl binary
remain release gates; see the [release plan](../docs/design/static-release-plan.md).
The historical macOS profile produced an executable importing only libSystem.
Its [archived recipes](release/README.md) contain affected Crypto 1.2.0 and require
explicit historical replay. Development locks the four Mirage packages at 2.4.1;
fresh static/clean-host qualification of that graph remains pending.

## Inspect a workflow

For the bundled offline examples, use a fixture credential:

```sh
LINEAR_API_KEY=fixture _build/default/bin/main.exe doctor examples/WORKFLOW.md
LINEAR_API_KEY=fixture _build/default/bin/main.exe dry-run examples/WORKFLOW.md --issue examples/issue.json
LINEAR_API_KEY=fixture _build/default/bin/main.exe workspace examples/WORKFLOW.md --issue examples/issue.json
```

For a real configuration, supply the Linear credential through the explicit
`$LINEAR_API_KEY` reference and set the project slug/state lists in the workflow.
`dry-run` reads normalized issue JSON from a local file; `--attempt 2` renders a
retry. Fixtures require an explicit `dispatchable` boolean. Nullable `assignee_id`
is preserved for templates; unusable optional metadata becomes null.
Relative workspace paths anchor to the selected workflow directory.
The command and hook strings remain verbatim trusted configuration.

`workspace` validates ownership under the persistent key lock and reports an
informational label or absence. It never creates directories or runs hooks. A busy,
foreign, unowned or displaced directory returns an actionable error. The label
grants no launch authority; only scoped acquired paths can launch native processes.

## Inspect Linear

Set the workflow's project slug and explicit state lists, then supply your key
through the captured environment and fetch normalized issues:

```sh
_build/default/bin/main.exe tracker /path/to/WORKFLOW.md
_build/default/bin/main.exe tracker /path/to/WORKFLOW.md --ca-bundle /path/to/anchors.pem
```

The default trust file is `/etc/ssl/cert.pem` on macOS and
`/etc/ssl/certs/ca-certificates.crt` on Linux, selected by the compiler target.
Results are an ordered JSON array emitted only after every page succeeds.
Missing required records produce
bounded warnings on stderr; malformed envelopes, pagination, TLS or limits fail
the read. No workflow/workspace inspection triggers networking. See the published
[Linear profile](../docs/adapters/linear.md) for scope, eligibility, errors and bounds.

## Run the service

Configure the workflow's Linear project, states, credential reference, workspace
root, hooks and Codex command, then run:

```sh
_build/default/bin/main.exe /path/to/WORKFLOW.md
_build/default/bin/main.exe
_build/default/bin/main.exe run /path/to/WORKFLOW.md --ca-bundle /path/to/anchors.pem
```

The default workflow is `./WORKFLOW.md`. Relative workspaces anchor to the
workflow directory. Use `run` or a `./` prefix for a workflow filename that
matches `doctor`, `dry-run`, `workspace` or `tracker`.

Startup validates settings and prompt syntax before polling. Invalid startup
returns nonzero with a diagnostic. Early signal-setup failure reports the fixed
host_startup_failure record after closing acquired resources and preserves the
original failure; reporting is not retried after output callback entry or sink
failure. The owner reloads workflow contents before
polling and admission; a malformed update keeps last-good settings for existing
work and blocks new admission until repaired. Each admitted attempt retains its
original configuration, tracker authority, child environment and hooks.

SIGINT or SIGTERM stops admission and joins workers, process groups, hooks,
workspace leases and control producers. Normal shutdown returns zero. Operator
records go to stderr as `event=name key=value` ASCII lines; values escape spaces,
controls, equals signs, backslashes and UTF-8 bytes as `\xhh`. Records include
issue_id/issue_identifier and run/session context. Worker closure retains its last
observed session_id, or explicitly reports session_state=not_started. Hooks use
their checked reference identifier. Unknown Worker/Retry generations retain their
checked opaque issue ID and generation with context=unavailable; identifier/session
fields are not fabricated. This exceptional host-port path does not establish full
log-context conformance.
Raw agent output and provider
payloads are excluded. A blocked or failed output sink fails the host after
resource closure; see the [lifecycle contract](../docs/design/live-dispatch.md).

## Status API

Local and Linux/macOS hosted acceptance passed 23 scenarios per mode in PR #13.
Enable the loopback listener with a CLI port:

```sh
_build/default/bin/main.exe run /path/to/WORKFLOW.md --port 8080
xh -I GET http://127.0.0.1:8080/api/v1/state
xh -I POST http://127.0.0.1:8080/api/v1/refresh
```

Alternatively set `server.port` in workflow front matter. `--port` overrides the
checked configured value; zero requests an ephemeral port. Listener changes
require restart; listener-only edits do not affect dispatch. Requests require the
bound loopback Host and, when supplied, matching Origin and same-origin metadata.
Rejected requests return 403 before reaching the handler. Open `/` for escaped
HTML; `/api/v1/<issue_identifier>` shows a
current running/retry/cleanup owner. Released issues return 404; unavailable
queries return 503. Reads ask the owner for a fresh paired clock sample and never
reload settings or change scheduling. Refresh queues the existing coalesced
poll/reconciliation trigger; its body must be empty/whitespace or `{}`. Other
bodies return 400, and unsupported methods return 405 with the route's `Allow`.
Session/path data appears only after actual
acquisition, and unrepresentable wall projections remain null. Counts, tokens and
runtime use exact values. [Contract, limits and evidence](../docs/design/status-api.md).

## Check

`just check` runs builds, examples/model properties, CLI integration, formatting,
source gates, protocol snapshots and watchdog-bounded native ownership/hook suites.
The native suites include 1,000 seeded lifetime scenarios with replay via
`SYMPHONY_LIFETIME_SEED`. Retained logs/manifests are in `_build/native-evidence`;
optimized Python checks have a separate directory. `just service-cli` runs the
executable acceptance in both Python modes and retains per-case receipts under a
fresh `_build/service-cli-*` directory. The suite has 25 cases, including controlled
descriptor startup failure and strict issue/session context. All 25 pass in both
modes in `_build/service-cli-JWgykX`; its independent receipt audit verifies actual
child modes, input/runtime context hashes and causal controls. These digests are
not build attestation. Configured local coverage
passes through the combined retained runs; exact replacement-head hosted evidence
passed before PR #12 merged as `40d6b63`. Earlier 24-case receipts remain historical. `just fuzz` runs the seeded Crowbar
campaign. Without `just`, use the commands in [justfile](justfile).

The [native capacity gate](../docs/design/service-capacity.md) runs the same
service with 1000 held fake scopes, native timings, sampled producer RSS and joined
shutdown. It measures service/runtime overhead; real Codex processes remain
outside this workload.
`just release-tools` checks the immutable input materializer and physical binary
verifier and installs their locked harness dependency. Direct invocations require
the [release bootstrap](release/README.md). Native verifier controls explicitly
skip hosts without the selected macOS/SDK profile locally; macOS CI requires it
and fails on missing coverage.
Portable controls still run on Linux. AFL has a separate bounded
[Mach-O parser harness](fuzz/release_macho.py), with campaign limits in
[release evidence](../docs/design/release-evidence.md).

The source gate parses OCaml ASTs, checks interface pairs and rejects prohibited
APIs/object syntax. It is not a proof of exception-freedom or resource safety.
Third-party dependencies are outside its scope. All enabled compiler warnings are
fatal; warning 42 alone is disabled because it asks for pre-4.01 compatibility.

The [design](../docs/design/README.md), [decisions](../docs/decisions.md),
[validation](../docs/slice-1.md) and [conformance map](../CONFORMANCE.md) distinguish
working behavior from future release requirements.

The pure scheduler is in `lib/orchestration`: dispatch ordering, bounded backoff,
absolute token watermarks, one persistent owner PSQ, frozen launch plans, typed
lifecycle transitions and a `state -> event -> state * command list` reducer.
It schedules startup cleanup, binding-group reconciliation, workflow preflight,
candidate admission, retries, reload, scope drain and shutdown. Claimed IDs and
running counts derive from canonical ownership; issue-scoped fault commands
retain the checked current issue after release.

Its separate `test/orchestration.exe` compares independent mathematical, list and
event models with seed `20261001`, including 200,000 owner operations. Examples
check label/routing eligibility, dispatch order, caps, retry growth, stale tokens
and closure barriers. Test-port completions represent closed fake scopes. Eio
command execution and deterministic service simulation pass the independent
event model. Native capacity holds 1000 scoped fake sessions through measured
polling and joined shutdown. The executable now uses the same owner with the
closed native runner; live Codex provider acceptance remains separate.

## Portable lifecycle evidence

The [installed conformance package](../conformance/README.md) owns shared capture,
process custody, fake TLS and generated schemas. `just conformance` runs normal
and optimized controls, the public CLI lifecycle and a scripted calibration
profile from an external cwd, retaining sealed evidence and independent reports.
Native watchdog evidence retains each raw stream with its exact length and hash.
Combined logs use stdout then stderr; signal custody lasts through all writes.

The fixed catalog retains all 106 requirements and 12 supplemental clauses.
The first lifecycle is partial evidence. Numeric usage is unobservable in the
public OCaml log; full core conformance remains incomplete. Fake peers and
retained hashes do not establish authenticated provider or release acceptance.
