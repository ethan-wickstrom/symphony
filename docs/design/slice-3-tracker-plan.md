# Slice 3: Linear reads through HTTPS

Slice 2 is merged at `92f7ac6`. Refine the approved contracts here before each
implementation; keep the existing workflow/workspace commands green throughout.

The first usable outcome is an explicit tracker-inspection command reading the
configured active states through the actual Linear adapter and verified HTTPS.
The same binary and transport run against a loopback fake Linear server with an
explicit test CA. No provider tools or writes; no automatic network request from
ordinary workflow inspection.

## Contract refinements

### Settings and runtime assembly

Construct Linear once over the selected HTTP module. Keep its credential-bearing
settings representation inside that functor; expose only the existing CONFIG
projection. Do not add a raw token getter to `Linear_settings`.

```ocaml
module Make (Http : Http_transport.S) (Clock : Clock.S) : sig
  module Config : Tracker_adapter.CONFIG
  type settings = Config.settings
  type io

  val io :
    http:(unit -> (Http.t, Diagnostic.t) result) ->
    clock:Clock.t ->
    omitted:(Linear_omission.t -> (unit, Diagnostic.t) result) -> io

  include Tracker_adapter.S
    with type settings := settings
     and type io := io
end
```

`S.states` below gains an ordered batch result. The omission sink receives a closed
reason and bounded identity projection; an expected sink error does not alter the read result.
Cancellation and defects retain their original identity/backtrace.

The runtime registry includes CONFIG and execution in one assembly. Its private
package has the shape:

```ocaml
type entry = Entry :
  (module Tracker_adapter.S
     with type settings = 's and type io = 'i) * 'i -> entry

type binding = Binding :
  (module Tracker_adapter.S
     with type settings = 's and type io = 'i)
  * 's Type.Id.t * 's * 'i -> binding
```

Allocate the existing registry identity witness once per adapter entry. Execute
through the binding's package, never by selecting the current kind again. The
configuration projection and live registry share these equalities from assembly:

```text
Linear.Config.settings = Linear.settings
Config.tracker = Tracker.Contract.binding
Config.registry = Tracker.t
Agent.Contract.Issue = Tracker.Contract.Issue = Issue
```

The pure core still sees only abstract binding, normalized Issue.t and categorized
replies. Reload cannot send an old ID through new credentials or a new scope.
Preserve D01's explicit state lists and D10's scope drainage. Authentication,
endpoint, project and IO stay frozen in the binding. Each request carries a
`Tracker_read_policy.t` derived from current checked scheduling settings; terminal
membership changes therefore affect future blocker decisions without rotating an
existing run's authentication. Fence stale replies by request/config identity in
the scheduling owner. Configuration and credential sealing perform no network,
trust-file, clock or RNG operation.

Resolve the selected adapter's credential before any public core or routing field.
The adapter returns its frozen settings together with `Environment.public`, which
denies declared credential sources, their values, selected literal credentials
and value-equal aliases. Public field parsers accept only that capability; check
canonical numeric/name/path and JSON outputs too. Build child environments from
the same restricted capability. Shell commands/hooks keep trusted literal bytes
and perform no environment interpolation in the parser. This is exact-value
quarantine, not substring taint tracking of scripts or arbitrary provider text.

### Ordered snapshots

The approved map-only state result loses the order required by §17.3 and the
pagination model. Introduce one small abstract domain batch, not a generic queue:

```ocaml
module Issue_batch : sig
  type t
  type error = Duplicate_id of Issue_id.t | Duplicate_identifier of Issue_identifier.t
  val empty : t
  val of_list : Issue.t list -> (t, error) result
  val ordered : t -> Issue.t list
  val by_id : t -> Issue.t Issue_id.Map.t
end
```

Store the ordered checked issues once; derive the map. Its constructor rejects
duplicate dispatch IDs and identifiers. `states` returns this batch; `ids` retains
its map result and set input. Tracker.execute converts the state batch to the core's
existing map reply. Inspection consumes the ordered boundary projection.

For successful `of_list xs = Ok b`, `ordered b = xs`; map keys equal the IDs in xs;
each map lookup yields its unique issue. Empty is valid. Page accumulation uses
Stdlib list concatenation, with associativity and empty identity; failure absorbs
the entire operation. Duplicate IDs across pages are pagination errors; conflicting
identifiers are response errors. Never resolve either by overwriting a map entry.

## First Linear profile

Retain `kind=linear`, `endpoint` defaulting to `https://api.linear.app/graphql`,
required `project_slug`, and `api_key` with the existing `LINEAR_API_KEY` fallback
and explicit `$VAR` source tracking. Declare all credential environment names.
Reject CR/LF, NUL and other unusable header bytes when sealing the credential.
Personal keys use the unprefixed Authorization value; OAuth is deferred rather
than inferred from token text. [Authentication](https://linear.app/developers/graphql).

Use constant GraphQL documents and JSON variables. Apply project scope and state
filters provider-side, then verify returned membership. Use case-insensitive state
comparisons consistently. ID reads apply scope and requested IDs, not active-state
filters; moved/archived/invisible issues are omitted according to the documented
visibility policy. IDs are Linear's opaque issue IDs; `native_ref` is a constructed
allowlist of non-secret identifiers, never the provider payload. Preserve the full
normalized snapshot. [Filtering](https://linear.app/developers/filtering).

Suggested first routing policy: no assignee restriction; a normalized Todo issue
is dispatchable only when its complete incoming blocks evidence establishes that
every blocker is terminal. Other scoped states have no blocker restriction. The
scheduler still owns states, labels, claims and capacity. Publish this policy before
dispatch, including unknown blocker handling; it is a provider profile, not a core
assumption.

Incoming `blocks` relations use `relation.issue` as the blocker and `relatedIssue`
as the target. Validate the target against the current issue. Labels and
inverseRelations are paginated connections too. Keep private `Complete | Incomplete`
eligibility evidence independently of optional `blocked_by` projection. An unusable
blocker entry may be omitted from that projection but cannot prove eligibility.
Do not assume the relation graph is a proven partial order or introduce a
topological scheduler. Linear's priority field is Float: exact integral JSON numbers
such as 1.0 and 1e0 become integer priorities; fractions/out-of-range values become
null. [Official current schema](https://raw.githubusercontent.com/linear/linear/master/packages/sdk/src/schema.graphql).

Page every required connection, with explicit `first` (initially the documented
default 50), validated pageInfo and cursor progress. Chunk large ID sets. Freeze
named request, cumulative page/node/byte and deadline bounds in the final profile;
exceeding a bound fails the whole read, never truncates it. No per-issue refresh
request loop. Successful paging is complete delivery, not a remote database
transaction. [Pagination](https://linear.app/developers/pagination).

State reads omit malformed required records with a warning. ID reads fail the
entire call for malformed requested records; a record with no usable ID cannot be
safely classified as an unrelated omission. Optional null/empty fallback alone is
not malformed. Parse envelopes/errors before accepting data, including HTTP 200
partial errors and HTTP 400 RATELIMITED. HTTP 429 also maps to rate limiting. Other
non-success statuses remain status errors. Map all §11.4 categories with actionable,
redacted messages; no arbitrary exception catch. Retry/cooldown headers are optional
and need a typed response extension only if used. Initially return the categorized
error without hidden retries. [GraphQL errors](https://linear.app/developers/graphql),
[rate limiting](https://linear.app/developers/rate-limiting).

## HTTPS mechanism and fake trust

Reuse installed Eio/Uri/JSON/UTC modules. The audited stack is H1 1.1.1,
tls-eio/tls2.1.3, X5091.2.0 and Mirage Crypto RNG1.2.0. Cohttp's convenience client
has unbounded headers, ambient proxy selection and raw wire logging; its transfer
decoder can accept truncated bodies. Its lower codec does not remove those framing
defects. Use maintained H1's public incremental codec over the TLS flow, with explicit
budgets. Seven independent framing controls reproduced H1 parser defects; narrow
fixes for overflow/negative chunks, status validation and closed-reader failure
ordering pass eleven examples and1,000 samples. Preserve upstream and patch
provenance in `vendor/h1`. Tls_eio accepts
the peer hostname or IP; X509's chain_of_trust accepts supplied time and anchors.
Give the host driver explicit net, filesystem, monotonic/wall clock, trust and crypto
runtime capabilities. Read bounded PEM trust material through the supplied filesystem;
missing time/trust fails closed. Preserve HTTPS-only endpoint validation. Reject all
redirects initially. Each request owns a switch, bounded body consumption and closure;
no detached flow or initial connection pool. Credentials remain destination-bound.
[H1 public codec](https://github.com/robur-coop/ocaml-h1/blob/d5fff216c28fe379c3abaa355b679ffb35d98d07/lib/h1.mli),
[TLS Eio 2.1.3](https://raw.githubusercontent.com/mirleft/ocaml-tls/v2.1.3/eio/tls_eio.mli),
[X509 interface](https://raw.githubusercontent.com/mirleft/ocaml-x509/v1.1.1/lib/x509.mli).

TLS Eio requires an installed library RNG; its client configuration does not offer
a per-client RNG argument. Confine that library-global initialization to the explicit
host crypto-runtime bracket and document the limitation. Do not claim per-client
RNG isolation or move initialization into pure adapter parsing. Use the supported
stateless Getentropy generator once at host activation; it owns no background fiber
or descriptor. A runtime witness records initialization, not protection from another
library changing the global.
[TLS client configuration](https://raw.githubusercontent.com/mirleft/ocaml-tls/v2.1.3/lib/config.mli).

The portable fake serves HTTPS on loopback, with a test certificate for the declared
hostname/IP and an explicit CA bundle supplied through the driver manifest and host
trust capability. It uses the same adapter and TLS validation path as production.
No trust-all authenticator, HTTP fallback or production embedded test CA. Expose an
explicit trust-bundle input for inspection/harness use; choose host defaults in the
target profile. Real credentialed smoke tests remain opt-in and separately reported.

## Models, properties and slice gates

| Boundary | Independent model and observable checks |
| --- | --- |
| Record parser | Small fixture-field normalizer, not Issue.parse reused as oracle. Required failures; optional fallback; complete output keys; opaque IDs; exact priority/UTC; labels idempotent; native_ref allowlist. |
| Pages/chunks | List of provider pages plus cursor/request trace. Ordered concatenation, partition independence for equivalent data, zero calls for empty input, failure absorption, duplicate/cycle/bound failures, nested page completion. |
| ID refresh | Finite scoped issue relation: requested set intersection with visible records. Unique output subset; full snapshots; missing versus malformed distinction; no active-state restriction. |
| Routing | Truth table over state, terminal set and Complete/Incomplete blocker evidence. Dropping metadata cannot change false/unknown eligibility to true. Test both relation directions and self/cyclic input. |
| Registry/transport | Original binding/settings/IO retained after reload; fresh checked read policy updates blocker routing. No kind redispatch. Destination/Authorization checks; trust, identity and validity failures; request/body deadlines; cancellation and physical defect preservation; redacted diagnostics. |
| Public environment | Named sources, value-equal aliases and exact credential literals cannot enter routing/core/protocol fields or child environment. Permitted nonsecret expansion remains unchanged; restrictions are order/duplicate independent. |

Use QCheck with replayable seeds and Alcotest's matching §17.3 examples. Fuzz the
actual envelope, record, pageInfo, relation and config/credential boundary parsers
with Crowbar/AFL: duplicate keys, invalid UTF-8, truncated payloads, exact-number
extremes and budget limits. A crash, escaped expected exception or secret disclosure
is a bug. Report random corpus checks separately from instrumented coverage.

Keep two purposeful fakes: lower fake HTTP exercises the actual Linear parser and
query protocol; the normalized fake Tracker supplies the same Issue.t contract for
core model tests. The portable HTTPS fake tests the actual binary's requests,
ordered output, warnings and error categories. Include negative controls for lost
later pages, reversed blockers, ignored GraphQL errors and disabled TLS validation.

Build order: profile/signature review; pure parser plus models/fuzz; atomic paging
over fake HTTP; registry assembly; real HTTPS driver and fake TLS endpoint; explicit
inspection CLI, clean-host walkthrough and §17.3/CONFORMANCE.md evidence. Every new
module has an .mli with its laws.

## Suggested specification wording

For §11.3: “If provider-specific eligibility depends on a collection, missing,
malformed or incomplete evidence MUST NOT establish eligibility. The adapter MUST
either return dispatchable=false or fail the read, and MUST document that choice.
Dropping best-effort blocked_by entries alone MUST NOT establish dispatchability.”

For the conformance profile: “An HTTPS fake provider MUST supply trust material and
expected peer identity through its driver manifest. The implementation MUST use
its normal authenticated transport. Mandatory adapter tests MUST NOT require
disabled TLS validation or support for unencrypted HTTP.”
