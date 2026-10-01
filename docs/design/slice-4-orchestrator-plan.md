# Slice 4: orchestrator, owner and deterministic simulation

Approved planning scope only. Audit of the interfaces against the implemented slice 1–3
ports and SPEC §§6.2–6.3, 7–8, 13.3–13.7, 16 and 17.4. This is a refinement
proposal, not implemented orchestration or evidence of conformance.

## Equalities before representations

Use the existing parent contracts. No new independently instantiated Issue,
workspace-reference or Path domain belongs inside the core.

```ocaml
module Make
    (Tracker : Tracker.S)
    (Clock : Clock.S)
    (Workspace : Workspace_manager.S)
    (Agent : Agent_runner.S
       with module Contract.Issue = Tracker.Contract.Issue
        and module Contract.Path = Workspace.Contract.Path
        and type Contract.workspace = Workspace.Contract.reference)
    (Log : Logging.S)
    (Config : Config_layer.S
       with type tracker = Tracker.Contract.binding) : sig
  module Core : Orchestrator.S
    with type config = Config.t
     and type clock_sample = Clock.Pure.sample
     and type instant = Clock.Pure.instant
     and type tracker_request = Tracker.Contract.request
     and type tracker_reply = Tracker.Contract.reply
     and type agent_request = Agent.Contract.request
     and type agent_progress = Agent.Contract.progress
     and type agent_completed = Agent.Contract.completed
     and type workspace_cleanup = Workspace.Contract.cleanup
     and type log_entry = Log.Contract.entry
end
```

Instantiate Core with `Tracker.Contract`, `Clock.Pure`, `Workspace.Contract`,
`Agent.Contract`, `Log.Contract` and `Config`. Instantiate Issue_lifecycle with
those SAME pure modules; Ownership's instant equals Clock.Pure.instant. The
Owner adapter is a projection of Lifecycle.owned, not a second owner datatype
with copied issue fields. Its `issue` and `role` supply Ownership.Make.

Tracker.Contract.Issue.t already equals the shared Issue.t through Issue.S.
The agent/Path equalities must remain module equalities, not late structural
casts. Simulator instantiation changes port instances; it shares its own Path
brand consistently through workspace and agent. Live Path values never cross
into a simulator contract.

## Small immutable state

One persistent priority search queue owns Starting, Active, Stopping, Waiting,
Refreshing and Cleaning values, keyed by issue ID. Complete and Released are
transition witnesses; reduce them to the next owned phase within the same step.
Retain no completed-ID history, separate owner map or waiting-priority index.

Other independent state facts are the last-good reload value and latest load
fence, service mode, current poll cycle, pending effects awaiting terminal
acknowledgement, fresh token supplies, finished-runtime/token aggregates and
latest bounded rate-limit observation. Do not cache counts, claims or views.

Service mode is `Startup | Serving | Draining_scope | Shutting_down`.
Poll cycle is `Idle | Reconciling request | Validating request | Candidates request`.
These are closed phases, not independent busy/pending flags. Startup terminal
fetch and its cleanup jobs finish before the first dispatch cycle; failures warn
and advance. This preserves the ordering in §§8.1 and 16.1 without racing a stale
startup cleanup against a newly admitted worker.

A failed startup read advances under §8.6's explicit warning-and-continue rule.
A cleanup failure is different: its owner, original reference and cleanup reason
survive until Workspace_removed acknowledges the closed job, including an Error
result. Sending cancellation or observing a failed inner operation cannot release
that claim. After an acknowledged failure, report it and release the reservation;
§8.6 prescribes no cleanup retry policy. This is best-effort deletion, not a claim
that an Error means the directory vanished. The startup barrier waits for those
acknowledgements before admission. A missing workspace is successful identity.

Internal `Ownership.running_ids` includes cleanup reservations by the approved
interface. Thus claimed = running_ids union retry_ids, with empty intersection.
Public running rows/counts and occupied slots project ONLY Worker roles:
Starting, Active and Stopping. Cleaning retains a claim but consumes no slot.

`running[issue_id].issue` is the canonical current snapshot. Agent.request.issue
is the immutable launch snapshot, a different historical fact; never read it for
current state, labels, identifier or status. Frozen workspace identity is likewise
the original ownership fact, not the current tracker identifier.

### One owner collection

Use the installed, lock-pinned Psq 0.2.1 through Ownership.Make. Psq has no separate
payload parameter: its binding is key to priority value. Store Lifecycle.owned
itself as that value; derive its scheduling rank without storing another due time
or issue snapshot. The intentional equalities are:

```ocaml
module Priority : sig
  type t = Owner.t
  val compare : t -> t -> int
end
module Queue : Psq.S
  with type k = Issue_id.t
   and type p = Owner.t
(* Queue = Psq.Make (Issue_id.Order) (Priority)
   Owner.instant = Clock.Pure.instant
   Owner.t = Lifecycle.owned *)
```

The named Priority comparator puts Retry_waiting before every other role, orders
two waiting owners by Clock.Pure.compare on due instants, and compares inactive
roles equally. Psq breaks equal priorities by Issue_id.Order, so next_retry selects
the smallest `(due, issue_id)` waiting binding; an inactive minimum means no retry
is scheduled. Dispatch_order is a separate comparator with a separate purpose.

This is a total preorder over complete owner payloads and a total order over
scheduling-rank classes. Psq's interface calls its priority comparison a total
order; do not claim comparison equality identifies an owner. The reviewed
implementation's required operations use priority order plus key tie-breaking,
and add replaces a same-key payload even when its scheduling rank compares equal.
Restrict the hidden Queue use to add, find, remove, min and fold. Do not use its
min-wins merge, bulk constructors or pop operation for owner transitions.

The observable algebra remains Ownership's existing signature. Write put(o, q)
with key id(o). For id(a) = id(b), put(b, put(a, q)) = put(b, q); puts at different
keys commute. Thus put(o, put(o, q)) = put(o, q). Removal is idempotent and commutes
at distinct keys; remove(id, empty) = empty.
find(id(o), put(o, q)) = Some o, including equal-rank replacements. Every other
lookup is unchanged. The reference model is a last-write list keyed by issue ID;
next_retry filters Waiting and sorts by `(due, issue_id)`. Fold-derived running,
retry and claimed sets agree with that list; claimed has no independent storage.

Waiting -> Refreshing is a same-key replacement with an inactive priority.
The issue remains claimed throughout the asynchronous ID read. Requeue replaces
that owner with a fresh retry token and due time; resume replaces it with a worker.
Removal is the lifecycle's release step; owners with pending effects await the
closed-scope acknowledgement first. A stale token cannot replace or remove the
current owner. These are Core/lifecycle laws, beyond the queue algebra.

Local mechanism evidence: a paired temporary OCaml probe against installed Psq
passed 100 replayable seeds of 2,000 operations against an independent list model,
checking keyed payloads, lookups, minimum and size after every operation. Controls
covered equal-rank payload replacement, retained ownership on refresh and due/ID
ties. This is sampled library evidence, not a proof or orchestration conformance.
The actual Ownership instance still needs comparator laws and QCheck/model tests
over its checked types. Declare Psq directly when implementing this slice; it is
already installed and pinned transitively, so no new package choice is needed.

Primary sources: [versioned public interface](https://github.com/pqwy/psq/blob/v0.2.1/src/psq.mli),
[versioned implementation](https://github.com/pqwy/psq/blob/v0.2.1/src/psq.ml),
and [published package](https://opam.ocaml.org/packages/psq/psq.0.2.1/).
The interface specifies keyed access and constant-time minimum; the implementation
confirms key tie-breaking and same-key replacement. No performance baseline has
been measured for Symphony's owner values.

## Frozen launch, current policy

A run plan stores Agent.request and its original Tracker.binding once. The agent
request already freezes workspace reference, child environment, agent settings,
prompt source and attempt. Scope is derived from the binding/reference; no copied
scope or credential printer belongs in the owner.

Running continuation/reconciliation uses original adapter/auth/io with CURRENT
checked tracker-read policy. A retry has no live agent auth obligation: for a
same-scope retry refresh use the current valid binding. Keep the last closed
attempt's original workspace reference only for terminal cleanup. A resumed run
constructs a NEW reference from current root/hooks/environment/prompt/agent
settings. Scope change releases retries and drains old runs before new admission.

The read contract separates Tracker_read_policy.t from frozen provider/auth
binding. Its checked constructor is `of_scheduling`; terminal states are its only
current field. Both States and Ids capture it at request creation. Before this
separation, a same-scope reload could preserve obsolete blocker semantics in an
otherwise correctly retained binding. Required behavior: changing terminal={Done}
to {Done,Closed} makes a Todo issue with a Closed blocker routable while the
existing run still reads with its original credential A. Core never repairs
adapter routing by inspecting native_ref. A reply calculated under obsolete
policy cannot authorize a launch or continuation after the policy epoch changes.

Invalid reload preserves last good config AND blocks every new run. A changed
file/load-in-progress also suspends admission until the latest load settles;
reconciliation still uses last good settings. Superseded load replies can only
discharge pending effects. A semantically equal valid reload clears gating without
replacing unchanged effective facts.

Admission readiness gates a new run/resume. It does not by itself terminate an
already admitted session or reject its continuation: current last-good state/
routing policy still decides those checks. In-flight prompt/agent settings remain
the frozen launch values.

Keep a monotonically allocated config epoch for effective changes. Candidate and
continuation read jobs capture their epoch/read policy. A stale-policy result
cannot authorize a turn or launch; repeat that read under the current policy.
Do not retry the whole worker merely because its continuation read was superseded.

## Fences and effect custody

All request/run/retry tokens come from the owner's immutable allocator chains;
never reset an allocator within a Core instance. Add named Order/Map/Set exports
for these token modules before choosing request/host containers. Existing token
interfaces expose only equal/text, unlike Checked_id.S. A map needs an explicit
total comparator; never use dispatch ordering or polymorphic compare.

Pending requests form a closed sum: Workflow_load, Startup_terminal_read,
Reconcile_read, Candidate_read, Retry_read, Continuation_read and Workspace_cleanup.
Retain only request ID, purpose, target identity fences, epoch and custody phase.
The effect command/host closure owns its request and captured binding/policy;
the pending ledger does not copy those objects, issue snapshots or derived counts.
Reconciliation targets are `(issue_id, run_id)` pairs; a reply cannot update a new
run just because that issue ID was reused. Retry reads additionally fence retry_id;
continuation reads fence run_id AND the completed turn_id. No copied issue cache.

Canceling is a pending-effect state, not absence. It rejects result semantics but
retains the obligation until normal completion OR Request_canceled proves the
child scope has closed. Duplicate terminals are no-ops. An ID disappearing from
the logical map does not prove resource closure.

Small HOST correction:

```ocaml
val job : t -> Request_id.t -> (unit -> Core.input) -> unit
```

The host runs the callback in its child switch, captures the returned event, closes
the switch, THEN emits it. Cancellation emits Request_canceled only after closure.
This covers a normal-result/cancel race without another acknowledgement message.
Do not send Tracker_completed from inside the still-open callback. Preserve the
primary exception/backtrace and drain before propagating defects.

Each timer has one typed token. Retiring/replacing a retry invalidates the old
token before Cancel_retry/Arm_retry commands. A late due event cannot find a new
owner with its token. Waiting -> Refreshing replaces the same owned binding with
an inactive priority; ownership survives the asynchronous fetch. Park a due retry
while validation is blocked; a valid load awakens it. Do not spin a past-due timer
while blocked.

Workers send sequenced progress and a completed witness after process, hooks and
workspace lease close. Stop is idempotent; stopping retains its slot/claim until
that witness arrives. A raw turn terminal is not Worker_finished. Spawn failure
must produce one completed failed-attempt witness after its empty resource scope
closes, rather than bypassing the Starting reservation.

Checked but causally invalid progress cannot regress a phase, replace a different
thread/turn, add tokens from an unknown thread or extend activity via a stale
sequence. Retired tokens are quiet no-ops; malformed observations for a current
token produce a bounded diagnostic and preserve the valid owner. Parse failures
are already adapter/agent result variants, not unchecked JSON inside Core. The
step function is total over its typed inputs; resource completion witnesses cannot
be forged by the stream-message parser.

Serialize reconciliation and continuation refresh for each run. Batched
reconciliation may exclude a run already awaiting a continuation read, but the
cycle must wait for that authoritative read to settle before candidate admission.
Remember the answered turn fence until a new Turn_started event advances it;
duplicates before that event must not enqueue another read/reply. A fresh terminal
observation during a stall stop must lead to terminal cleanup after closure,
rather than a failure retry. Keep termination cause distinct from the closed
finish disposition (Retry, Release or Cleanup) if one cannot derive both without
losing that race. Lifecycle transitions must cover this same-phase refinement.

Shutdown/scope drain suppress new reads, launches and retries; previously admitted
cleanup obligations drain. Old worker progress/replies may discharge resources
but never resurrect ownership or cross into the new scope. Scope transition waits
for old owners and old request acknowledgements; timer/watcher/listener custody
still belongs to Host.drain.

Actual Tracker.S.execute accepts only its captured request. Remove obsolete
`tracker:Tracker.t` from proposed Service.Run.run. Registry authority belongs to
workflow resolution, not request execution.

## Time and snapshot gap

The actual Clock.S.now is independent of wall time, but Orchestrator.event and
Issue_lifecycle.start currently require Clock.sample. A failed wall sample would
therefore prevent ordinary reconciliation/retry events from reaching Core.

Required focused signature corrections, retaining Snapshot's existing shape:

```ocaml
(* Orchestrator.S *)
val create : now:instant -> config -> state * command list
(** Every timer target is [Clock.after now checked_delay]. No wall read. *)
val event : now:instant -> input -> event
(** Caller stamps events with nondecreasing observations from the supplied
    monotonic clock. Expected wall failure does not suppress an input. *)
val snapshot : now:clock_sample -> state -> (Snapshot.t, Diagnostic.t) result
(** Same state/sample gives the same result. UTC projection failure changes
    neither ownership, timers, runtime nor dispatch readiness. *)
(* Issue_lifecycle: both start/resume take Clock.instant; started returns it. *)
(* Status_surface.unavailable gains a bounded projection/source diagnostic. *)
(* Service.Run *)
val run : Host.t -> clock:Clock.t -> workspace:Workspace.t ->
  agent:Agent.t -> log:Log.t -> Config.t -> (unit, Diagnostic.t) result
```

Require a fresh checked Clock.sample only for a requested display projection.
Project runtime/stalls/retries from exact monotonic instants. A nonrepresentable
UTC projection is an explicit unavailable result, preserving Snapshot's required
UTC fields; do not fabricate a timestamp or widen every phase record. Due_at keeps
its already approved optional form. Historical display times follow the declared
Clock.wall_at affine projection; they are not a second scheduling clock.

Expected wall failure returns an operator-visible unavailable status while
scheduling continues. Expected monotonic-source failure stops and drains the
service with a diagnostic; no fabricated now, unbounded sleep or implicit retry.
Service.run should return its expected host failure as a result. Normal return
requires Core.quiescent and Host.drain; an emergency error return still requires
Host.drain. Unexpected defects/cancellation preserve exception identity after
resource drainage.

For asynchronous timer failure, the effectful mailbox needs one
`Host_failed of Diagnostic.t` case. Clock.sleep_until Error sends that diagnostic
after the timer scope closes; it never raises an expected failure or sends a false
due event. Eio cancellation closes the timer without a due event. Keep this host
failure outside the timed pure-event constructor so shutdown does not require a
working clock. No timer exception is translated into an unbounded sleep.

Snapshot is read-time projection, with no I/O: current issue fields, worker/retry/
cleaning rows, slots, per-state counts, ended runtime plus current elapsed runtime,
aggregate usage and latest rate limits. A snapshot must never control scheduling.

## Independent executable model representation

Use a LIST of owners and a LIST of pending requests, integer/tag tokens and bounded
integer simulation ticks. Do not instantiate Ownership, Lifecycle, Backoff,
Dispatch_order or Core inside the oracle. Adapter fixtures are parsed once into
Issue.t; an explicit projection gives the oracle the fields it needs.

The following representation/projections are executable OCaml, intentionally
simpler than a priority search queue:

```ocaml
module Model = struct
  type issue = { id : string; state : string; routable : bool }
  type run = { token : int; issue : issue; stopped : stop }
  and stop = Live | Retry_after_close | Release_after_close | Clean_after_close
  type retry = { token : int; issue : issue; attempt : int; due : int }
  type owner =
    | Run of run
    | Wait of retry
    | Refresh of retry * int
    | Clean of issue * int
  type state = { owners : owner list }

  let issue = function
    | Run r -> r.issue
    | Wait r | Refresh (r, _) -> r.issue
    | Clean (i, _) -> i

  let claimed s = List.map (fun o -> (issue o).id) s.owners
  let workers s =
    List.filter_map (function Run r -> Some r | _ -> None) s.owners
  let put owner s =
    let id = (issue owner).id in
    { owners = owner :: List.filter (fun o -> (issue o).id <> id) s.owners }
  let release id s =
    { owners = List.filter (fun o -> (issue o).id <> id) s.owners }
  let next_retry s =
    let waiting =
      List.filter_map (function Wait r -> Some r | _ -> None) s.owners
    in
    let compare a b =
      match Int.compare a.due b.due with
      | 0 -> String.compare a.issue.id b.issue.id
      | n -> n
    in
    match List.sort compare waiting with [] -> None | r :: _ -> Some r
end
```

Complete the oracle's explicit event transition table BEFORE Core implementation:
latest workflow result, completed tick read, candidate admission, worker progress,
worker closed, retry due/read, cleanup closed and shutdown. Its request list stores
captured epoch/binding tags and target tokens. Responses are whole checked fixture
lists. No model parser duplicates the production boundary. The comparison adapter calls
public constructors once and projects checked fields explicitly. Integer bounds are a
generator precondition; separate exact Count/Clock/Backoff properties cover huge
values. Do not present the above projection kernel as a finished state machine.

Compare observable snapshots and command traces after EVERY step. Normalize freshly
allocated model/implementation tokens through an explicit bijection, without
normalizing away binding/epoch/turn differences. Test owner uniqueness/disjoint
roles, claim ownership, no duplicate launch, no obsolete result mutation, no
early capacity release, no new admission above current caps, monotone joined usage
and resource-closed-only completion. Do not assert current caps after a reduction
or state move: accepted D11 permits existing overcapacity.

Generate valid AND stale event streams: repeated exits, retired timers, reordered
progress, duplicate turns, superseded loads/read replies, same-scope auth/policy
changes, scope drains, delayed cancellation acknowledgements, terminal arrival
during stopping and continuation, reduced caps, state moves, no-slot retries,
invalid then repaired workflow, missing issues and read failure. Shrink the event
list and payload choices while preserving clock monotonicity and checked fixtures.

Independent comparator oracle uses the tuple `(priority_bucket, optional_time,
identifier_bytes)`, with null times last. Check sign associativity/identity/
idempotence of then_by plus preorder laws; do not confuse preorder equality with
issue identity. Backoff oracle is mathematical min(cap,10000*2^(attempt-1)); usage
oracle retains a simple list of absolute reports and takes componentwise maxima.

## Whole-service deterministic simulator

Installed Eio 1.6 has `Eio_mock.Backend.run_full`; its mono clock automatically
advances when the runnable queue empties and it raises Deadlock_detected if nothing
can wake the unfinished root. `env#mono_clock` is exact Mtime ticks; wall is linked
to it. Use Clock_posix.create with those explicit capabilities for ordinary seeded
runs, and an injected Clock.S instance for independent wall faults. No domains,
systhreads, OS sleep, sockets, filesystem or subprocesses in the simulator.

Run the SAME Service command interpreter, owner stream, Host job/worker/timer
registries, switches and cancellation logic against scripted fake lower ports.
Fake workspace uses checked reference identities plus an in-memory filesystem;
fake agent issues its completion witness only after its simulated process/hook/
lease scopes close. A separately instantiated fake Agent.Contract is legitimate;
its Path brand must equal that simulator's Workspace.Contract.Path.

Place this assembly in a separate simulator/test executable, with no fake/stub
production daemon command. The existing inspection CLI stays usable throughout
slice 4; the live `run` command arrives only with real ports and the agent-client
slice. Simulator constructors and completion factories stay private to that
target's port instances.

A seeded controller chooses tracker mutations, latencies, faults, worker event
scripts and ordering of simultaneous promise resolutions. Eio's scheduler remains
unchanged and deterministic. The seed samples ENVIRONMENTAL delivery schedules;
it is not a claim to enumerate every possible fiber interleaving. Cancellation
must interrupt pending fake reads/sleeps and acknowledge after closure. Retain late
already-produced events to exercise fences. Deadlock is a failing seed.

Replay artifact: seed, generated input program, event/command trace, scenario
version and tree/toolchain identifiers. Run thousands of bounded seeds in CI;
keep discovered failures as minimized deterministic cases. Bound steps, messages,
fake sessions and pending operations so a bad scenario cannot hang the suite.
Exercise both same-instant event permutations explicitly in addition to sampling.

Build the 1,000-session fixture on this simulator. Report allocation/live-heap per
session, real startup duration and tick latency outside the simulated time domain.
Set CI regression thresholds only after measured Linux/macOS baselines; this audit
does not establish performance numbers.

## Small vertical slices and required interface gates

1. Token comparators; comparator/backoff/usage algebras and independent models.
   First vertical capability: one startup cleanup barrier, one poll read and one
   claimed fake worker, observable through the owner projection. No retries or
   live agent client until that path is green.
2. Shared request-time tracker policy and the old-auth/new-policy regression.
3. Monotonic Core/lifecycle stamps and unavailable snapshot/Service failure shape.
4. Lifecycle/Owner/request phases plus source-state and cancellation laws.
5. Reference event model and examples from §17.4, then pure Core step.
6. Real Eio Host/Service interpreter with fake ports, post-drain acknowledgements.
7. Seeded Eio_mock simulator, shrinking/replay artifacts and resource controls.
8. Production Agent port after its separate app-server schema/client slice; the
   simulator can validate scheduling before that client exists.

Existing documented spec gaps remain: §7.3 candidate retry vs §8.4 ID retry;
§16.6 omitted terminal cleanup; §16.4 spawn-before-claim; §16.6 pop-before-read;
caps after reload; and best-effort blockers are not necessarily a partial order.
Use §8.4, reserve before effects, retain refresh owners and accepted D11. No core
topological sorting of best-effort blockers. Newly exposed gap is reload policy
versus frozen binding; separate policy from captured authority rather than inspect
provider data or silently choose old/new credentials.
