# Verification plan

Status: approved acceptance plans. Completed evidence is recorded in
[the worklog](../worklog.md) and [conformance map](../../CONFORMANCE.md).
P01–P08, D01–D13 and the component signatures are accepted.
The first adapter is Linear. Development and deployment target macOS; the static
release target is Linux with musl.

The [pinned Symphony spec](https://github.com/openai/symphony/blob/be10a1b79df723d6d7612b5651c8522704dafb2e/SPEC.md)
defines conformance. The generated Codex 0.159.2 bundles and
[protocol audit](../protocol-audit.md) define the selected wire profile. Stable and
experimental fixtures remain separate; the accepted client negotiates the stable
profile. Schema validity does not establish sandbox enforcement or unattended auth.

## What each kind of evidence establishes

| Evidence | Establishes | Does not establish |
| --- | --- | --- |
| Abstract types and explicit module equalities | Checked identifiers cannot be interchanged; callers cannot construct workspace capabilities from wire cwd strings; lifecycle operations require their source phase. | Parser correctness, physical containment after OS mutation, resource linearity, or correctness of a module implementing the signature. |
| Pure laws and executable models | A tested implementation agrees with independent models on sampled/generated cases; minimized failures are reproducible. | A proof over every input or every concurrent OS execution. |
| Seeded Eio simulation | Service wiring and mechanisms handle controlled schedules, faults, cancellation, and time progression. | Real filesystem, kernel, process-tree, TLS, sandbox, or authentication behavior. |
| Target-host integration tests | The tested executable and host satisfy the exercised filesystem/process/protocol behavior. | Protection against an actor outside the documented host trust boundary. |
| Optional Rocq/Lean proof | A stated theorem for the formal model and its assumptions. | Correspondence to executable OCaml unless that correspondence is separately established. |

Every law names its reference model and assumptions. No test report is called a
proof. Laws whose validity remains doubtful after model tests are raised for a
decision about machine checking.

## 1. Deterministic whole-service simulation

Use [Eio 1.6](https://github.com/ocaml-multicore/eio/releases/tag/v1.6)'s mock backend
in one domain. Its backend performs no real IO, supports
neither system threads nor multiple domains, and advances virtual time when idle.
It supplies clocks/debug/backend identity, not ready-made filesystem, process, or
watcher capabilities. The mock library provides flows, networking, clocks, and
handler actions. [Backend](https://ocaml-multicore.github.io/eio/eio/Eio_mock/Backend/index.html),
[mock resources](https://ocaml-multicore.github.io/eio/eio/Eio_mock/index.html)

Use the `eio.mock` library from the `eio` package; it needs no separate mock opam
package. The mock and live runs share explicit capability interfaces.

Instantiate the same loader, workspace mechanism, agent protocol client, command
interpreter, and orchestrator over fake lower drivers. A canned fake agent outcome
is useful for core tests but does not satisfy this target. Fake filesystem state
models entries, identities, ownership records, locks, symlinks, and injected errors;
fake processes expose byte streams, exits, and cancellation. The fake tracker
serves real adapter payloads, pagination, and transport errors.

Seed scenario generation and event-delivery choices; do not claim a seeded Eio
scheduler. Generate same-deadline completions, reordered tracker replies, duplicate
worker exits, obsolete timers, partial streams, workflow replacements, clock jumps,
and cancellation during every acquisition/cleanup phase. Use explicit wall and
monotonic clocks: the default linked mock clocks alone cannot test independent
wall-clock jumps. [Mock clock](https://ocaml-multicore.github.io/eio/eio/Eio_mock/Clock/index.html)

Each run has an event budget and virtual-time horizon, then requests shutdown and
asserts quiescence. An intentionally long-running service must not run forever as
idle time advances. Failure artifacts contain the seed, canonical scenario,
generator version, compiler/dependency lock, trace, and minimized scenario. Seed
alone is insufficient for replay after generator changes.

CI runs thousands of registered seeds, sharded across separate processes; a larger
scheduled campaign expands the corpus. The first working simulator measures the
cost per seed and records the PR/nightly budgets before its slice is accepted.

## 2. Model-based orchestrator testing

Compare each pure transition with a small executable model. Use association lists
for owners and a list sorted by due time/ID for retries; do not reuse the production
map, priority queue, dispatch comparator, or transition helpers as the oracle.
Generate inputs together with the outstanding request/run/timer identities so
valid completions and deliberately stale completions are both exercised.

After every step assert:

- Running and retry-queued issue IDs are disjoint; claimed IDs are their union.
- Every claimed issue has exactly one owner. Stopping workers retain ownership
  until cleanup/reaping completes; obsolete completions cannot release a new owner.
- Every admission obeys the current global and state caps. D11 permits existing
  workers to exceed newly reduced caps; no new admission enters a saturated bucket.
- Reconciliation refreshes the owned issue; dispatch and snapshots use that value.
- Invalid reload keeps the last good configuration, exposes its error, and gates
  every new launch. Scope changes drain old owners before admitting new-scope work.
- Duplicate terminal/request/timer identities and obsolete inputs are observational
  no-ops. Progress has per-run sequences; usage joins absolute counters.

Check command traces as well as resulting state. Shrink the event stream while
preserving required identities and retain a regression example for each failure.
Add Section 17.4 examples and mutation controls: duplicate dispatch, missing
generation fencing, a stale issue snapshot, an ungated retry, and early release
must each be detected by at least one test.

Domain properties have separate oracles: exact natural-number sums for usage and
runtime, per-run/thread absolute-counter high-water marks for idempotent token deltas,
last-good-config plus latest load validity for reload, and sorted lists for retries
and dispatch. Test associativity/identity/idempotence where applicable, comparator
order laws, and agreement with each oracle. Retired run/thread watermarks fold into totals and
drop their live accounting state; generation fencing rejects late reports.

Use QCheck2 from the small `qcheck-core` package, with Alcotest for named examples.
Integrated shrinking fits generated event streams; a separate state-machine test
framework is unnecessary for the pure fold. [QCheck](https://github.com/c-cube/qcheck)

## 3. Portable conformance package

Publish a separate harness package with a fake tracker endpoint, fake Codex
app-server executable over JSONL stdio, fixtures, and a runner. It launches the
implementation as an external process in a fresh temporary root. An implementation
profile supplies launch arguments, tracker settings, selected implementation-defined
policies, and available status/test surfaces. Core workflow and protocol fixtures
remain fixed by the spec/schema; the profile cannot rewrite them or supply expected
answers.

Map every Section 17.1–17.7 case and every Section 18.1 item to its fixture, probe,
and observable evidence in `CONFORMANCE.md`. Observe tracker requests, agent launches,
cwd/environment, protocol traffic, workspace effects, shutdown, and status/log
output. Use fake credentials in a constructed environment; never run harness
probes with the operator's real token.

Report pass, fail, or unobservable per item. An unobservable required item is not a
pass. Optional extensions and recommended real integrations have separate results.
For state invariants lacking portable external observation, document the gap and
propose a test-control extension; do not silently require an OCaml-only API for
baseline conformance. Fast deterministic time control belongs to a declared test
profile. Baseline black-box timing checks use configured durations and measured
windows, not guessed exact scheduling.

Run the harness against the OCaml binary in CI. Validate the harness with broken
fake implementations that violate handshake order, double-dispatch, ignore input
requests, omit cleanup, or miscount absolute usage. Later language ports run the
same package and retain their own adapter/release profiles.

## 4. Fuzz every parsing boundary

Maintain a parser inventory as each slice lands: workflow frontmatter/YAML, template
syntax and rendering, environment/config values, identifiers/keys/paths, timestamps
and duration/count lexemes, tracker JSON, app-server JSON and framing, and any
introduced CLI, HTTP, ownership-file, or hook-output parser. A new parser without a
fuzz entry fails the slice review. Output truncation/escaping is tested even when
hook output is not interpreted as a language.

Crowbar targets consume raw bytes and structured adversarial generators. Expected
rejection returns `Error`; an escaped exception, crash, hang, or resource-limit breach
is a failure. Do not hide defects behind a harness-wide exception catch. Bound
input size, nesting, render steps/output, and frame buffers at the boundary before
unbounded allocation or work. Fuzz duplicate keys, aliases, malformed UTF-8,
CRLF/BOM, truncated delimiters, numeric overflow, unknown variables/filters, and
deeply nested values. [Crowbar](https://github.com/stedolan/crowbar)

Framing targets vary bytes, chunk boundaries, EOF location, and interleaved request
IDs. The law is that chunking the same valid byte stream produces the same frames;
invalid streams produce a bounded error without corrupting later request ownership.
Round-trip laws apply to checked values, not arbitrary malformed bytes.

PR CI runs native Crowbar random tests plus the saved minimized corpus. Scheduled
Linux runs use persistent AFL with native `-afl-instrument` instrumentation and
explicit time/RSS budgets. Verify that the selected compiler/build actually emits
coverage instrumentation before reporting coverage-guided fuzzing. OCaml 5.5's
manual documents this support; its required AFL `-m none` disables AFL's default
virtual-memory limit, so a separate OS resource budget remains necessary.
[OCaml AFL manual](https://ocaml.org/manual/5.5/afl-fuzz.html)

## 5. Safety by construction and host limits

Compile the core against abstract domain types and checked boundary values. Every
module has an interface; explicit equalities connect adapter issues, workspace
paths, requests, and clock instants. Enable an explicit warning set including
partial, fragile, and unused matches/values, and make every enabled warning fatal.
CI inventories module/interface pairs and rejects project uses of `Obj.magic`,
application objects, Lwt/Async concurrency, forbidden partial functions, and
ambient authority in the core. Use the compiler parser/typed tree for source gates
when the installed structural-search tool cannot parse OCaml; text searches alone
do not establish absence of aliased unsafe calls.

Workspace safety uses a physically acquired root and abstract live directory
leases. Eio's `open_subtree` confines subsequent Eio operations. `Path.native` is
display/interoperability data, not a confinement proof, and can become stale after
rename. The high-level directory opener has no atomic no-symlink option; the small
OS driver owns atomic acquisition and identity checks. POSIX exposes directory and
nofollow flags; Linux also exposes `openat2` resolution controls.
[Path](https://ocaml-multicore.github.io/eio/eio/Eio/Path/index.html),
[POSIX flags](https://ocaml-multicore.github.io/eio/eio_posix/Eio_posix/Low_level/Open_flags/index.html),
[Linux driver](https://ocaml-multicore.github.io/eio/eio_linux/Eio_linux/Low_level/index.html)

OCaml does not express linear OS-resource lifetimes or prevent an external rename.
Bracket leases in a caller-owned scope, reject released handles, and revalidate
identity at launch/removal in the one driver hiding the representation. Root and
ownership metadata must be protected from agents and other untrusted writers.
Directory capabilities constrain Symphony's IO; they do not sandbox a spawned
shell. Codex's selected sandbox needs separate real-host validation. Trusted login
initialization must not restore excluded environment secrets.

Eio ties a child to a switch and signals that child on release. Explicit process
groups, bounded TERM/KILL grace periods and stream draining, direct-child reap,
and cancellation tests are needed. POSIX gives no finite actual reap duration.
A descendant that leaves its group is outside that guarantee.
Reliable hostile process-tree containment belongs to later platform isolation.
Cleanup hooks and drains run in a fresh scope with named time bounds; release handlers
cannot attach new resources
to the released switch. Cancellation must survive cleanup rather than become a
retry failure. [Process](https://ocaml-multicore.github.io/eio/eio/Eio/Process/index.html),
[Unix process control](https://ocaml-multicore.github.io/eio/eio/Eio_unix/Process/index.html),
[switch cleanup](https://ocaml-multicore.github.io/eio/eio/Eio/Switch/index.html)

Run real macOS and Linux tests for symlink/rename races, case-folding aliases,
ownership collisions, non-directory entries, hooks replacing a workspace, reused
workspaces, inherited streams, hanging descendants, cancellation during acquisition,
and shutdown during cleanup. Simulation supplements these tests; it cannot replace
them. A static binary proves neither physical containment nor sandbox enforcement.

### Minimal lower process and byte-stream capabilities

Keep OS details under one driver. Its scoped spawn operation accepts a nonempty
argument vector, a live directory capability, explicit sanitized child environment,
and stream wiring; it returns only abstract child/stream handles to a callback.
Only the trusted shell module converts configured scripts into `bash -lc` arguments.
Issue data never participates in shell construction.

Monotonic instants and accumulated runtime use exact integer nanosecond counts.
The live clock adapts long deadlines using representable native sleeps and rechecks;
it never overflows a native clock conversion or accumulates floating-point deltas.
Wall-time projection is display-only and returns absence outside its supported range.

Byte streams need bounded read-to-chunk-or-EOF, ordered write-all, and idempotent
close, with explicit failures and caller cancellation. Child control needs stable
awaited exit status, bounded stop grace/drain, and switch-owned direct-child reap
without a finite kernel completion guarantee. Expose no raw PID, descriptor,
unchecked cwd constructor, raw environment, or global clock. POSIX process groups
and backend-specific directory operations stay inside the driver. The protocol
client composes these ports with its injected clock; simulator drivers implement
the same ports. Release/failure/EOF semantics are laws tested against a simple
stream/process model. The live directory and child remain runtime capabilities,
not facts stored in the pure orchestrator state.

## 6. Scale and performance gates

The required target is 1,000 concurrent simulated sessions with bounded memory;
it does not assert capacity for 1,000 live Codex processes. Use the same service
interpreter and real protocol parsing with simulated streams. Include steady load,
bursts, token notifications, retries, reloads, snapshots, and completion churn.

Measure with a physical monotonic clock outside the simulator's virtual clock:

- Startup: process entry to validated configuration/first poll readiness, with
  cold and warm runs reported separately.
- Pure transition time, full tick time, and owner-mailbox lag: p50/p95/p99/max.
- Idle RSS, RSS at session plateaus, incremental bytes per session, retained OCaml
  heap, allocations, descriptors, fibers/timers, and bounded log/frame buffers.
- Resource return after repeated start/finish/retry cycles; completed historical
  sessions must not retain live handles or grow memory indefinitely.

Measure several session counts up to 1,000 and report the memory slope rather than
dividing total process RSS by session count. Warm up deliberately and document GC
settings. Snapshot cost and event backpressure have their own measurements so a
fast tick cannot hide a growing queue.

Keep raw JSON results with OS, architecture, CPU, backend, compiler, lock digest,
scenario, and sampling method. macOS native and Linux musl have separate baselines.
Before accepting the benchmark slice, repeated runs on a pinned runner establish
noise and recorded regression tolerances. Thereafter CI fails budget/resource
violations and regressions beyond those tolerances. Hosted-runner timing alone
cannot justify tight gates; deterministic work/allocation limits and pinned-runner
measurements provide the gate. Baseline changes require an explained review.

## 7. Operator and release quality

Exercise all Section 13.7 API routes, unknown issue/route errors, 405 responses,
coalesced refresh requests, exact numeric serialization, and the minimal HTML view.
API reads request fresh snapshots from the owner fiber; they do not copy mutable
state. Test escaping with adversarial tracker text and verify that neither API nor
logs reveals fake secret markers.

Doctor reports the file/key/issue and corrective action for invalid workflow,
adapter settings, workspace permissions/identity, executable/auth availability,
and supported protocol/sandbox configuration. Dry run loads and validates settings,
reads candidates, and explains dispatch eligibility without creating workspaces,
running hooks, or launching the agent. Tests assert those absent effects. Real
authentication probes are explicit; automated tests use fake credentials.

Run CLI startup, signal shutdown, invalid reload, and resource-draining tests on
both targets. Select the pinned Eio POSIX backend explicitly on Linux and macOS:
descriptor launch/custody uses its low-level effects. Record that backend in
diagnostic metadata; unused Linux/Eio_main paths provide no coverage evidence.

The macOS deliverable is one native executable using platform system libraries.
Each published Linux musl artifact must have no ELF interpreter or dynamic-library
requirements, and must execute in a clean Linux image on its declared architecture.
Exercise DNS/TLS tracker access, process launch, cancellation, hooks, and HTTP there;
link flags or a successful build alone are insufficient. Bash and Codex remain
documented external executables, and unattended auth is provisioned outside runs.

## 8. Documentation as a tested deliverable

Every slice ships its signatures/laws, independent reference model, properties,
matching Section 17 examples, and updated `CONFORMANCE.md` before implementation is
accepted. Record implementation-defined choices and dependencies in the decision
log. Publish the Linear profile with scope/state semantics, pagination, blocker
quality, secret names, and failure mapping; fake and conformance profiles state
their own capabilities and limits.

Keep algebra write-ups next to the interfaces and a short clone-to-first-dispatch
README. Test that walkthrough in a clean target environment using a fake tracker
and fake agent, then keep recommended real-integration results separately. Publish
reproduction commands, minimized failures, benchmark methodology, and target-host
assumptions. Documentation coverage, parser inventory, profile completeness, and
broken local links are CI checks; prose alone never marks conformance complete.
