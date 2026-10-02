# Typed lifecycle

Implemented foundation: `Run_plan.S` shares config, binding, request and workspace
types. Lifecycle takes that exact Plan module beside Tracker, Clock, Workspace and
Agent. Agent includes `Agent_plan.S`; its Issue and Path modules equal the tracker
and workspace modules. One run stores one Plan, its current issue and start instant.

The lifecycle implementation and independent model are the current sub-slice.
The scheduling event loop and Eio interpreter follow. No production agent runner
or dispatch command is supplied by the port contract alone.

## States and transitions

```text
Unclaimed -> Starting -> Active
                \         /
                 Stopping
                    |
        resource-closed completion
                    |
          transient disposition
          /         |          \
      Waiting    Released     Cleaning
         |                       |
     Refreshing               Released
         |
   post-close Refreshed
    /       |       \
Starting  Waiting  Parked -> Refreshing
```

The public owner sum contains Starting, Active, Stopping, Waiting, Refreshing,
Parked and Cleaning. Complete, Refreshed and Released are transition witnesses;
they cannot accumulate in the canonical owner collection. A Waiting retry has a
due instant. Refreshing and Parked have no due value; Parked has no live read.

Functions accept their source type. Only a retryable closed completion can enter
retry; cleanable and releasable completions have distinct types. Closed agent
witnesses expose checked issue/run IDs without a public constructor. The fake
test instance acquires no resources; its completion factory cannot certify native
resource closure. The future Host must emit completion after its worker switch
closes, and read/cleanup results after their job switches close.

## Laws

After-close disposition is a three-element join semilattice:

```text
Retry < Release < Cleanup
join(a,a) = a
join(a,b) = join(b,a)
join(join(a,b),c) = join(a,join(b,c))
join(Retry,a) = a
join(Cleanup,a) = Cleanup
```

Stop records the first cause. Refinement joins only its disposition. Terminal
reconciliation can upgrade an existing stall stop to Cleanup; shutdown/scope
drain can upgrade Retry to Release but cannot erase required Cleanup. Repeating
or reordering those refinements preserves both the disposition and first cause.

Same-ID issue replacement is last-write and idempotent. It preserves phase,
generations, original Plan and cleanup authority. Runtime identity/attempt/scope
equalities are checked at source transitions: OCaml type equality cannot prove
equality of two parsed IDs or scopes.

Clean success produces continuation attempt 1. Failure advances First to 1 and
Follow_up n to n+1. Read failure, slot exhaustion and resumed planning rejection
increment the positive attempt. Park/reread preserve attempt, retry ID, cause and
target; superseded policy is not a failed attempt. These are typed transition
equations, not homogeneous associative binary operations.

Initial planning rejection retains its checked Named reference or Unnamed scope.
Resumed rejection retains the preceding retry's target. Terminal cleanup uses
that original Named reference; Unnamed can only release. Cleanup acknowledgement
releases ownership even on Error, which is reported without claiming deletion.

## Model and checks

The independent model uses tags and small records for phase, identity, attempt,
cause, original reference and disposition. It does not call Lifecycle, Ownership,
Run_plan or Backoff. Check each valid generated transition against its public
observations; invalid identities return diagnostics and preserve the input.

Examples cover all outcomes and source phases, crossed issue/run IDs, same-ID
renames, initial/resumed planning rejection, attempt reset/increment, monotone stop
refinement, parked rereads and original-reference cleanup. Compile-only negative
clients check that wrong source phases and completion dispositions are rejected.
Local gate: 24 examples and 19 property groups at seed 20261001, including 100
lifecycle streams of 500–600 operations. Shrinking permits short prefixes and
prints failing programs. One valid public assembly and 14 invalid source/disposition
clients are checked normally and optimized in local and Linux/macOS CI gates.
Input CMI hashes remain unchanged; a syntax-error control rejects false type
evidence. Nine proposed interfaces compile with fatal warnings against current
contracts. Sampled laws and compiler rejection do not prove whole-service orchestration.

## Next event core

Use issue ID plus generation in event envelopes, avoiding another owner index.
Reconciliation groups workers by their original Plan binding and waits for every
group before preflight/candidates. Replies carry policy epochs and owner fences.
A canceled job remains owned until a post-close terminal arrives.

Startup is an epoch-fenced cleanup barrier. A stale terminal read cannot construct
references from a newer root or policy. Already-admitted cleanup drains, then the
latest last-good epoch repeats the startup read before Serving. Scope changes
drain old owners/jobs and restart that barrier; Shutdown supersedes restart.

The event reference model uses lists, tagged integer tokens and bounded ticks,
with a token bijection for observable command comparison. It covers mixed auth,
partial read failure, delayed closure, superseded reads, invalid/repaired config,
parked retries, reduced caps and issue-ID reuse after scope drainage. Core and
whole-service Eio simulation remain separate implementation gates.
