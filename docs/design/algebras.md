# Domain algebras and reference models

Status: laws for the proposed interfaces, not proved implementation properties.
Equations use named observations of checked values. Operations with different input
and output types are not falsely classified as associative binary operations.
Expected failure remains `result`; absence remains `option`.

## Structures and law classification

`A` associativity; `I` identity; `C` commutativity; `D` idempotence; `Inv` inverses;
`Abs` absorbing element. A dash means the property is inapplicable, not an omitted
obligation. “No” means the structure does not have that law. Distributivity requires
naming two operations on a shared carrier; it is not a generic checkbox.

| Carrier / operation | A | I | C | D | Inv | Abs | Model / distribution |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Count, Seconds, Usage / add | Yes | zero | Yes | No | No | No | Naturals, nanosecond naturals, product of naturals. |
| Count, Usage / componentwise max | Yes | zero | Yes | Yes | No | No finite top | Join semilattice. Addition distributes over max: `a + max(b,c) = max(a+b,a+c)`. |
| Nonempty_list / append | Yes | None | No | No | No | No | Nonempty list semigroup. |
| command/log trace / append | Yes | [] | No | No | No | No | Free list monoid. |
| finite ID set / union | Yes | empty | Yes | Yes | No | No | Stdlib Set; intersection distributes over union and conversely. The unbounded ID universe is outside the carrier. |
| raw retry-entry Set / union | Yes | empty | Yes | Yes | No | No | Generic Set law only. Domain retry queues do not export union; differing due times for one ID would violate ownership. |
| comparator / then_by | Yes, by sign | always-equal | No | Yes, by sign | No | No general two-sided absorber | Lexicographic composition of total preorders; canonical signs. |
| owner map / last-write put | — | — | Different IDs only | Same value/key | — | — | Finite function. Conflicting writes do not commute. |
| reload / apply | — | — | No | Same valid load | — | — | Last-good settings plus latest validity. An invalid load is not identity on readiness. |
| template AST / sequence | Yes structurally | empty AST | No | No | No | No | Sequence monoid; interpretation laws need common sufficient budgets. |
| backoff / failure | — | — | — | — | — | — | Bounded monotone function of positive attempt and cap. |
| clock / after | Action law | zero duration | — | — | No nonnegative inverse | — | Exact time action; configuration sums must be representable. |

Use `Map.Make`, `Set.Make`, `List.map/fold_left/concat`, and named comparator modules.
OCaml Stdlib has no general monoid instance/typeclass: small domain operations and
list folds are sufficient. Do not invent a framework to claim reuse of a nonexistent
instance. Hash tables are unnecessary in the persistent core; any runtime table uses
an explicit named equality/hasher when introduced.

## Boundary values

[Checked IDs](interfaces/checked_id.mli) preserve bytes and round-trip through text;
equality agrees with the named byte comparator. Distinct ID modules are intentionally
not interchangeable. Opaque tracker IDs are never decoded as ticket identifiers.
JSON and positioned YAML have independent typed-tree models. Parse/render round trips
apply to supported checked values, preserving exact numeric value and scalar kind.
Duplicate keys fail. A quoted scalar never becomes an unquoted boolean/number.

Workflow parsing is a line splitter followed by one complete YAML parse, not arbitrary
Markdown parsing. Source identity is the selected absolute `Workflow_path.t`.
Environment lookup is an association-list function with unique names. Child names
are a subset of `allow \ deny`; duplicates have no effect and denial dominates.
Commands and URI strings are not filesystem expansion targets.

[Issue](interfaces/issue.mli) has one adapter-only smart constructor. The reference
normalizer produces all required fields, lowercase unique labels and null/empty optional
metadata; applying normalization twice changes nothing. `native_ref` is opaque,
provider-attested nonsecret data. Generic parsing cannot discover every provider secret.
No core operation rechecks normalized issue strings.

[Workspace_key](interfaces/workspace_key.mli) is a deterministic transformation, not
an injective mapping. Unchanged safe identifiers retain their bytes; changed keys use
the accepted suffix. Key construction rejects dot/dot-dot; acquisition rejects aliases.
Live containment is a resource
invariant, not a string-algebra theorem. [Workspace_path](interfaces/workspace_path.mli)
has no parser or public constructor.

## Totals and absolute reports

[Count](interfaces/count.mli) models exact naturals, [Seconds](interfaces/seconds.mli)
exact nanosecond naturals, and [Usage](interfaces/usage.mli) their product:

```text
0 + x = x = x + 0
(x + y) + z = x + (y + z)
x + y = y + x
join(x,x) = x
join(x,y) = join(y,x)
join(join(x,y),z) = join(x,join(y,z))
next = join(previous, report)
delta = next - previous
sum(accepted deltas) = final watermark - initial watermark
```

The watermark key is `(Run_id, Thread_id)`; changing a turn/session display ID does
not reset it. Repeated or decreasing reports contribute no previously charged tokens.
`totalTokens` is independent of input/output, with no invented sum equation. Retired
runs fold once into aggregate totals; late events cannot reintroduce their watermarks.
The independent model tracks an association list of absolute reports and its maxima.

Bounded configuration milliseconds use result-valued addition, not a saturating
“monoid”. Saturation would hide overflow and change the intended algebra. Positive
retry attempts have `first` and `next`; zero is unconstructible. Large backoff attempts
compare to the cap before exponentiation; the model uses the mathematical formula.

## Workflow/config/template

[Reload](interfaces/config_layer.mli) is a total function over last-good settings and
load validity:

```text
effective(apply(r, Error e)) = effective(r)
readiness(apply(r, Error e)) = Blocked e
effective(apply(r, Ok c)) = c
readiness(apply(r, Ok c)) = Ready
apply(apply(r, Ok c), Ok c) = apply(r, Ok c)
```

Errors are observations as well as dispatch gates. Invalid config never supplies a
fallback or new settings. Empty prompt selection is a separate config operation.
Core fences loads by request generation before applying these equations.

[Template](interfaces/template.mli) uses bounded strict Jinja. The reference is an
association-list AST evaluator. `map id = id` and composition apply to nonempty list
contexts; sequence interpretation agrees with byte concatenation under the same
sufficient fuel/output budget. Source concatenation has no such law because tokens
can cross its boundary. Missing differs from known null. Issue text is never reparsed
as template source. Rendering is deterministic and has no IO authority. Fuel/limit
failures are modeled explicitly, rather than excluded from all testing.

## Tracker and workspace effects

Tracker states/IDs return complete results or a categorized error. Empty input is the
identity read: empty map, zero provider calls. Successful pages are concatenated then
normalized; partial success cannot masquerade as an atomic ID refresh. The same
remote data/settings produce the same normalization; repeated network calls need not
produce the same remote data. The fake HTTP driver models page/error traces.

A workspace reference freezes root, hooks, opaque issue ID, identifier, scope and
sanitized environment.
Its acquisition bracket has a resource-ledger model: each acquired lease releases once
on success, error or cancellation. If removal succeeds and no directory is recreated,
another cleanup returns success and preserves the resulting filesystem projection.
The hook/log traces differ; this is not equality of whole executions. A failed operation
need not be idempotent. Preparation distinguishes new and reused
directories. Cleanup cannot reconstruct its target from current reload settings.
OS mutation and non-linear lifetimes require the hidden driver checks documented in
[verification](verification.md#5-safety-by-construction-and-host-limits).

The protected ownership record models a five-component tuple: scope, opaque ID,
original identifier, device and inode. Equality is the conjunction of component
equalities, hence an equivalence relation. Its canonical codec satisfies
`parse(encode(owner)) = Ok owner`; canonicalization is idempotent. Versioned
records have exact fields and bounded encodings. Record equality grants no live
directory authority; acquisition must compare it under the key lock.

Process exit observation and process custody are separate axes. Observing a terminal
leader does not release its reserved identifier or certify group emptiness. Cleanup
collects signal/reap errors while proceeding through every stage; only the owner of
the Held-to-Reaping transition may reap. Stable completion is an observable result,
including expected OS failure. Repeated observation is stable; repeating a signal
syscall can produce a different result and is not an unconditional idempotence law.

The process bracket is polymorphic in its caller's error algebra. Its mapper
translates only mechanism failures; semantic callback errors retain their type and
value. For expected outcomes, `finish(Error e, cleanup) = Error e`,
`finish(Ok x, Ok ()) = Ok x`, and `finish(Ok x, Error d) = Error(map d)`.
Cleanup and reporting still finish before observing that result. A shadowed
cleanup error invokes no mapper. This eliminates the nested `Ok(Error e)` carrier
that could misclassify a hook timeout as successful work during cleanup.

## Ownership, order and orchestration

The owner model is a finite function from issue ID to a closed lifecycle variant:

```text
find(put(owner,m), id(owner)) = Some owner
put(a, put(b,m)) = put(a,m)                      when id(a)=id(b)
put(a, put(b,m)) = put(b, put(a,m))              when id(a)<>id(b)
remove(i, remove(i,m)) = remove(i,m)
claimed(m) = running_ids(m) union retry_ids(m)
running_ids(m) intersect retry_ids(m) = empty
retry_rank(m) = waiting_retry_projection(m)
```

The queue model is the waiting-retry projection, sorted by exact due time then issue ID.
Peek does not remove an owner; refreshing removes its due rank while retaining
ownership. One hidden persistent Psq stores each complete owner once, keyed by
issue ID. Its priority comparator projects waiting due times; all other roles
rank after waiting. Equal priorities break by the named issue-ID order. No second
map, stale heap entry or claim history exists. Equal-rank replacement still replaces
the complete payload, including its current issue snapshot and retry token.

The compiled foundation is in `ocaml/lib/orchestration/`. Independent list and
mathematical models check the container, comparator composition, bounded backoff
and absolute-report joins. Production usage retains one watermark; its model
retains reports and computes the componentwise supremum. Summed accepted deltas
telescope to that supremum, even with duplicate/reordered reports.

`Run_plan.Make` shares Tracker.Issue and the workspace/agent Path module before
choosing representations. Success stores the original binding and immutable
Agent_plan request once. A failed reference construction returns Unnamed scope;
a failed request returns Named reference. Neither acquires a resource or fabricates
a completion witness. Lifecycle will preserve the preceding retry's cleanup target
if resumed planning fails. This last transition is still pending implementation.

[Dispatch_order](interfaces/dispatch_order.mli) lexicographically composes priority
bucket, null-last creation time and identifier. Its reference model computes a tuple
rank. Check reflexivity, sign antisymmetry, transitivity and totality plus composition
preservation. Equivalent ranks can belong to different issue IDs; the comparator is
never the uniqueness order for `Issue_id.Map`.

Blocker metadata is best effort and may be cyclic, absent or stale. It does not form
a proven partial order. Linear computes `dispatchable` under its published profile;
no generic topological dependency scheduler is added. A future reliable DAG adapter
would own cycle detection/topological sorting and its model.

[Lifecycle](interfaces/issue_lifecycle.mli) laws are source/terminal invariants:
starting cannot release/retry; waiting cannot resume; terminal values cannot continue;
completion identity must match its owner. [Core](interfaces/orchestrator.mli) is the
Mealy transition and its trace fold. Determinism and fold concatenation hold; individual
events generally do not commute or have inverses. Duplicate completed/request/timer
identities are observational no-ops. Progress uses its sequence and turn identity;
absolute usage uses join. Shutdown/stop and worker completion may arrive in either
order, but cannot dispatch twice or release live resources.

Admit only when current global/per-state capacity and valid readiness permit it.
Reload lowering caps is not an automatic cancellation rule. Scope changes drain old
owners. Reconciliation updates the same issue fact; snapshots derive state counts,
slots, claims and monotonic durations at read time. No second state/title cache exists.
The independent list model checks state and command observations after every event.

## Protocol, service and presentation

[Framing](interfaces/protocol_frame.mli) is a stream action: chunk partitioning does
not change frames/error category. It preserves order and bounds residual bytes; EOF
with an unfinished frame is an error. Method codecs round-trip emitted messages
against the selected schema. RPC IDs preserve numeric/string distinctions.

The runner's pure phase terminal values are separate from effectful completion witnesses.
The transport normalizes wire events; only closed outcomes can finish a turn. Service
resource ledgers model timers, requests, watcher, workers, flows and process groups.
Cancellation followed by successful closure is idempotent; a stale-event check alone
cannot prove a timer fiber was released. The owner projects snapshots on request with a
fresh sample; callbacks stay outside the pure core.

Snapshot observers agree with their projection: counts equal row lengths and cleanup
owners remain findable. JSON/HTML serialize the same facts, deterministically; HTML
escapes data, JSON retains exact numeric lexemes. Logs are ordered traces with bounded
escaping/redaction. Changing/failing the sink never changes scheduling commands.
Every diagnostic states location and remedy. These observations are functions rather
than forced binary monoids.

## Proof boundary

Properties sample these laws; they do not prove them universally. Type checking proves
the declared sharing/transition relationships, not that an implementation respects
hidden invariants. If model tests leave a named algebra or ownership theorem in doubt,
record that uncertainty and propose a Rocq/Lean model/correspondence obligation for
approval. No proof dependency or generated abstraction is added preemptively.

Design references: [OCaml 5.5 modules](https://ocaml.org/manual/5.5/moduleexamples.html)
and [functor tutorial](https://ocaml.org/docs/functors); Sandy Maguire's
[Algebra-Driven Design full manuscript source](https://github.com/isovector/algebra-driven-design/tree/118aa81a48fb46255dfe4503cbcdee6d893098c9/prose).
The user's source correction supersedes the earlier sample-only reference.
The main prose manuscript has been reviewed. [Coverage and resulting changes](book-review.md)
distinguish that reading from compiling the book or its companion code.
