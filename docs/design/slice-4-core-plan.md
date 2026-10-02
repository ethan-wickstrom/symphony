# Pure scheduling loop

The first executable operation language is
[`orchestrator.mli`](../../ocaml/lib/orchestration/orchestrator.mli).
The reducer and independent model pass 45 examples and 27 seeded property
groups locally. Whole-service execution remains the next layer.

## Shared types

`Make` shares Tracker.Issue with Issue, Agent.Issue with Tracker.Issue,
Agent.Path with Workspace.Path, Agent.workspace with Workspace.reference and
Config.tracker with Tracker.binding. It instantiates Run_plan once and passes
that exact module to Issue_lifecycle. Every instant belongs to the supplied Clock.

The kernel has no ambient effects. `step state event` returns immutable state
and ordered commands. One Ownership PSQ holds canonical lifecycle owners; one
Request_id.Map holds outstanding effect custody. Counts, claims, projections and
group-barrier completion are derived. No second pending-ID set, owner index or
cached status exists.

## Operation algebra

- Closed trace reduction is a monoid action: reducing `[]` preserves state;
  reducing `a @ b` equals reducing `a` then `b`, preserving command order.
- A retired or crossed generation changes no scheduling projection and emits
  no command. Matching closed terminals retire custody exactly once.
- Stop/cancel requests retain ownership and occupied slots. Only post-scope
  terminals can discharge them. Repeated shutdown is idempotent.
- Invalid workflow loads preserve last-good settings and block admission.
  Equal valid loads repair readiness without advancing the effective epoch.
- Same-ID issue refresh is last-write and preserves the original checked plan
  and cleanup authority. Cleanup disposition absorbs release disposition.
- Admission reserves Starting before Start_worker. It checks active state,
  routing, required labels, claims and current caps at each reservation. A reduced
  cap may leave existing workers above capacity; it permits no new admission.
- Runtime forms an exact addition monoid: ended intervals counted once plus
  current worker intervals. Duplicate completion contributes zero.
- Issue-scoped faults carry the checked canonical issue at the failing
  transition, even when that transition releases its owner. Logging derives
  ID and identifier from this immutable command value; it needs no history
  cache or original launch snapshot. Batched tracker failures remain global;
  a retry read failure retains its single known issue.

## Closure and authority

Startup reads terminal issues and waits for all admitted cleanup jobs to close.
An obsolete startup payload cannot construct references under a later root.
Bootstrap also joins superseded workflow loaders before repeating its terminal
read or entering Serving. This uniform all-job barrier is an implementation
choice, stronger than the specification's cleanup ordering requirement.
Reconciliation groups by original binding equality, including credential context,
and waits for every group's closed result before workflow preflight and candidates.
A failed group preserves its workers; successful groups refresh their issues.

Preflight reloads before each poll dispatch cycle, satisfying Sections 6.2–6.3.
Once reconciliation closes, a watcher replacement fulfills that same cycle's
preflight. The latest selected load and every superseded preflight loader must
close before candidates; their closure order makes no difference. Watcher
invalidation of candidate and retry reads remains independent of load purpose.
An invalid replacement ends a discarded candidate cycle and arms the normal
poll interval, rather than immediately starting another validation. Closing a
canceled selected loader restores the preceding Ready or Invalid validation.
Retry ID reads use current Ready settings and an effective-config epoch fence.
A superseded read retains Refreshing custody until closure, then parks without
changing its retry identity or attempt. Repair rereads with current authority.
Loading/invalid workflows never spin a past-due retry timer.
A matching canceled retry-read closure rereads only its own issue. Unrelated
waiting retries wake on their keyed due event or an accepted readiness repair.

Scope change drains original workers, reads and cleanups before starting the
latest scope. Shutdown absorbs restart. Requesting cancellation proves nothing
about closure; Host must publish results after the child scope closes. The pure
fixture completion factory certifies only an empty fixture scope.

## Verification and next layer

The independent oracle uses owner/job lists, tagged integer generations, integer
milliseconds and declared finite config/planner truth tables. It calls no kernel,
lifecycle, owner queue, planner, comparator, backoff or reload implementation.
Compare public projections and ordered commands after each generated event.
Token bijections and command history check frozen authority without widening the
kernel's interface for test access.

The test edge separately records emitted requests, workers and timers. A forced
shutdown tail closes outstanding resources once, including cleanup admitted after
a worker closes. Cancellation retains request/worker custody until that terminal;
timer cancellation retires its handle. Every tail step is compared, and both cores
must become quiescent with an empty edge ledger. Its decreasing measure gives a
finite drain without an arbitrary retry budget. This checks the command contract;
fixture completion certifies no live subprocess scope.

The oracle's declared state/label corpus is ASCII. Production normalization uses
the pinned Unicode tables. Independent integer and Zarith models check exact time
and exponential backoff; sampled laws remain numerical evidence, not proofs.
The campaign compares 200 programs of 500–600 main events without discards,
plus shutdown and finite closure tails. Seven regression groups pin eleven
closure-order/prior-validation programs. Each failure prints its symbolic event
program; stable-prefix shrinking preserves issued generation history.

Examples anchor startup/reload authority, mixed credentials, delayed closure,
planning rejection before successful admission, exact retry due, parked repair,
scope ID reuse and shutdown custody. Generated schedules include duplicate,
crossed, obsolete and canceled-but-produced replies, with replayable seeds.

The next layer interprets these commands under Eio switches and runs fake
tracker/worker resources in a deterministic mock backend. Protocol progress,
turn continuation and stall detection require real causal observations before
they enter the operation language. This kernel alone cannot run a real agent.
