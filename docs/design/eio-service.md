# Eio owner and replay layer

The pure core is merged as `5c892db`. This layer interprets its existing commands;
it adds no agent progress, continuation or stall observations before the real
runner supplies them.

## Shared capabilities

Service.Make shares the actual Tracker/Clock/Workspace/Agent/Config contracts.
Agent.clock = Clock.t and Agent.workspace_manager = Workspace.t, and run receives
the service's exact instances. Agent.Issue = Tracker.Contract.Issue,
Agent.Path = Workspace.Contract.Path and Agent.workspace = Workspace.reference.
Workflow_load.config = Config.t; the common parent shares registry = Tracker.t.
One Core instance creates its Plan/Life assembly once.

Four proposed interfaces compiled with fatal warnings against 82 unchanged
application CMIs. This proves signature compatibility, not resource behavior.
The secondary host-error sink subsequently gained explicit Owner/Controls scope
keys. The production Service/loader/assembly compile with fatal warnings after
that refinement; _build/eio-service-second-build.log records the successful build.

## Nonblocking notification algebra

Service_inbox reserves an owner slot and a publication-only producer. Each
reservation admits at most one immutable `(slot, payload)` FIFO entry. The slot
keeps only Available, Sealed or Revoked state; consuming its message leaves the
Sealed tombstone. Published and consumed slots have identical future behavior.

- Empty consume is identity. Successful publication order is consumption order.
- First publication wins. Duplicate publication changes neither payload nor queue.
- Retraction is idempotent and can revoke only an unpublished reservation.
- A revoked producer cannot enqueue. A published entry cannot be retracted.
- Fresh reservations have distinct identities; same is an equivalence relation.
- Pending messages are bounded by reserved slots, not an absolute memory limit.

Queue insertion, sealing and Condition.broadcast form one non-suspending step.
The owner checks readiness and calls await_no_mutex without an intervening yield.
All producers are scoped fibers on that same domain. OCaml does not express
domain-local closure ownership; the service hides these capabilities from native
threads and additional domains.

The independent model uses integer reservations, conceptual lifecycle statuses
and a list of first successful payloads. Seven examples and 300 programs of
0–300 actions pass at seed 20261002, including spurious-wake rechecks and 1024
protected finalizer publications after owner failure without consumption.
Standalone compilation/linking used the actual Inbox source and pinned libraries.
The same campaign passes through Dune; _build/eio-service-inbox-dune.log records
seven examples and one property group. Whole-service closure controls also pass;
see the campaign evidence below.

## Admission and closure

Switch.check, handle registration and fork must not suspend between one another.
The child's initial yield belongs inside its captured-outcome wrapper. A failure
before entry rolls back only its unstarted registration. These rules prevent
Eio's off-switch silent fork from orphaning an admitted handle.

Each effect has entry and closed slots. Commit a
terminal only after the outer job scope closes. A closed slot waiting for owner
receipt retains its handle. Cancellation requests retain resource obligations;
canceled timers retire through private closure facts without a fabricated Core
event. Control forwarding coalesces refresh signals and retains Shutdown, so
external producers cannot flood the internal FIFO with control notifications.

## Fatal drainage and primary errors

The rejected bounded-mailbox design admitted this trace: worker A fills the
mailbox; worker B blocks publishing entry inside its open scope; the owner's
clock/observer fails; owner stops consuming and joins; B never reaches the runner
that would receive cancellation. Reserved publication slots remove that blocking
edge. The full Service control retains two acquired workers while a caller-owned
control producer is blocked, then verifies fatal drainage completes independently.

Fatal drainage cancels actual handles, receives committed private closure facts,
then joins. It calls no Clock/Core or user sinks and does not fabricate terminals
for an undispatched command tail. Core quiescence is a graceful-success condition,
not a condition for propagating an owner defect after physical drainage.

Capture expected primary outcomes before Fiber.first/Switch cleanup aggregation.
Commit service-fatal outcomes when received, before observer callbacks. The
owner and caller share one first-failure carrier: selecting twice keeps the
first value. This left-biased operation is associative and idempotent, with an
empty identity; its operand order matters. Request-level errors remain Core data.
Secondary cleanup defects use a typed host diagnostic sink and safe context;
never fabricate Core.fault or expose raw exception payloads. A secondary reporter
failure cannot replace the primary or skip releases. Preserve original exception
identity/backtrace privately. Complete observer traces are unavailable after an
observer failure; independent fake finalizer receipts must check fatal drainage.

Shutdown liveness assumes cooperative cancellation, finite finalizers and fair
receipt. Structured teardown cannot impose a safe finite native reap duration.

## Simulator and next gates

Run the same Service and Core with resource-owning fake ports. The controller owns
Random.State and a manually driven mock monotonic clock; backend determinism alone
does not define a seed. Record causal gates, actual owner events, initial output,
ordered commands, projections and closure receipts. Prefix shrinking retains
generation history. The independent event model consumes actual owner events.

The controls cover fatal entry/drain, pre-entry cancellation, cancellation/result
races, finalizer defects, canceled timer retirement, reused-issue admission and
test-actor failure. Nineteen examples and three property groups pass locally:
300 Inbox programs, 1000 first-failure list-model programs, and 1000 causal service
programs with 50–60 gates plus joined shutdown tails, seed 20261002. Programs
sample three issue IDs; seed uniqueness and 1000-session capacity are not claimed.
Replay uses `dune exec test/service_replay.exe -- --seed N --prefix N`.

`Scenario.run` opens finalizer permissions on every actor exit, before the child
switch joins. The actor-failure identity test failed before that scope replacement.
`Service_failure` owns the host primary and private secondary exceptions; the
parent receives one normalized outcome. See [the retrospective](service-retrospective.md).

The next checkpoint supplies a declared 1000-session fixture. Measure physical speed
separately under Eio_posix; virtual zero-duration ticks are not performance data.
No successful fake runner enters the live CLI.

The physical capacity checkpoint will inject Clock_posix.t into the same fake
ports, with manual clock ownership outside those ports for simulation. A separate
checked workload holds 1000 acquired workers through warmup and measured poll
cycles, then checks all closures and joins. Native step latency, poll-cycle
latency, startup, managed heap/stack bytes and resident bytes have separate units
and populations. Per-session memory retains baseline and plateau readings and
includes fake-port overhead. Paired accepted/candidate binaries run on the same
runner; numerical regression limits follow measured baselines. No physical
capacity or latency result exists yet.

## Testing references

[Eio's determinism design](https://github.com/ocaml-multicore/eio#design-note-determinism)
states that same-domain scheduling is deterministic given deterministic
capabilities. The controller therefore varies causal IO releases and explicit
clock advances, rather than treating a fixed backend schedule as seed coverage.

[Probabilistic concurrency testing](https://www.microsoft.com/en-us/research/publication/a-randomized-scheduler-with-probabilistic-guarantees-of-finding-bugs/)
motivates targeting short ordering constraints as well as broad randomized runs.
Our causal-action generator does not implement that paper's scheduler, so its
probability bound does not apply. The fixed first-failure controls cover explicit
ordering constraints; generated programs supply additional sampled coverage.
