(** Private arbitration of host failures; request errors remain reducer data. *)

type 'a outcome = Returned of 'a | Raised of exn * Printexc.raw_backtrace

val capture : (unit -> 'a) -> 'a outcome

val restore : 'a outcome -> 'a
(** [restore (capture f)] preserves the result or exception identity and saved
    backtrace of [f]. Neither operation translates a defect into a domain error.
*)

val flatten : 'a outcome outcome -> 'a outcome
(** [flatten (Returned x) = x]; [flatten (Raised e) = Raised e]. Normalize at
    the producer boundary so a nested restore cannot bypass failure selection.
*)

type 'key secondary

val secondary : 'key -> primary:exn list -> exn -> 'key secondary list
(** Flatten Eio's cleanup aggregation, removing cancellation wrappers and exact
    primary exception identities. Distribution over an aggregate preserves its
    order. Raw exceptions stay private until their constructor names are
    rendered. *)

type 'key t

val create : unit -> 'key t

val record : 'key t -> 'key -> (unit, Diagnostic.t) result outcome -> unit
(** First fatal observation wins; successful observations are identity. The
    primary projection is a left-biased optional value: associative, idempotent
    and noncommutative, with absence as identity. Recording a later distinct
    exception retains a secondary, never replaces the primary. Record and
    selection do not suspend. The reference model is the first unsuccessful
    observation in a list. *)

val prefer :
  'key t ->
  (unit, Diagnostic.t) result outcome ->
  (unit, Diagnostic.t) result outcome
(** Empty selection returns its argument. Once selected, every preference
    returns the same original error or exception/backtrace. *)

val check : 'key t -> (unit, Diagnostic.t) result
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
    Reporter failure cannot replace the primary or recursively report itself.
    Repeated flush without new observations is identity. *)
