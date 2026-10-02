(** Private arbitration of host failures; request errors remain reducer data. *)

type 'a outcome = Returned of 'a | Raised of exn * Printexc.raw_backtrace

val capture : (unit -> 'a) -> 'a outcome

val restore : 'a outcome -> 'a
(** [restore (capture f)] preserves the result or exception identity and saved
    backtrace of [f]. Neither operation translates a defect into a domain error.
*)

type 'key secondary

val secondary : 'key -> primary:exn list -> exn -> 'key secondary list
(** Flatten Eio's cleanup aggregation, removing cancellation wrappers and exact
    primary occurrences. Normalized IO uses retained error/context identities;
    one primary occurrence removes at most one matching leaf, preserving later
    failures within that same aggregate with the same IO fields. Only subtract a
    primary captured from the scope that produced this aggregate; never an
    unrelated register's primary. For each non-cancellation identity,
    [count(result) = max 0 (count(leaves) - count(primary))]. Distribution over
    an aggregate preserves observation order. Raw exceptions stay private until
    their constructor names are rendered. *)

type 'key t

val create : unit -> 'key t

val record : 'key t -> 'key -> (unit, Diagnostic.t) result outcome -> unit
(** First fatal observation wins; successful observations are identity. The
    primary projection is a left-biased optional value: associative, idempotent
    and noncommutative, with absence as identity. Each call records an
    independent observation. Every later non-cancellation exception retains a
    secondary, even when it reuses an earlier exception value. Do not record a
    selected outcome again during propagation. Record and selection do not
    suspend. The reference model is the first unsuccessful observation in a
    list. *)

val prefer :
  'key t ->
  (unit, Diagnostic.t) result outcome ->
  (unit, Diagnostic.t) result outcome
(** Empty selection returns its argument. Once selected, every preference
    returns the same original error or exception/backtrace. *)

val finish : 'key t -> (unit, Diagnostic.t) result
(** Restore the selected outcome after the owner and its children have joined.
    This is the only transfer of a registered exception to the caller. *)

val failed : 'key t -> bool

val retain : 'key t -> 'key secondary list -> unit
(** Append secondary observations in order. Empty is identity and appending is
    associative; it does not change the primary. *)

val flush :
  'key t ->
  describe:('key -> string) ->
  report:('key -> Diagnostic.t -> unit) ->
  unit
(** Drain retained secondaries once, in observation order. Only constructor
    names and the supplied context are visible; exception payloads stay private.
    The first reporter defect becomes primary when none exists; all remaining
    reports are still attempted. It cannot replace an existing primary or
    recursively report itself. Repeated flush without new observations is
    identity. *)
