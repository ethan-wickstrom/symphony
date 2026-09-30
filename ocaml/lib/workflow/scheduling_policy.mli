type t

module Names : Set.S with type elt = string

type stall = Disabled | Silence_limit of Milliseconds.t

val parse :
  env:Environment.t ->
  Config_value.t ->
  (t, Diagnostic.t Nonempty_list.t) result
(** Applies spec defaults, except accepted D01 requires explicit active/terminal
    lists. Names are normalized; the two sets are disjoint. Limits are positive.
*)

val active : t -> Names.t
val terminal : t -> Names.t
val required_labels : t -> Names.t
val poll_interval : t -> Milliseconds.t
val global_limit : t -> int
val state_limit : t -> string -> int
val max_retry_delay : t -> Milliseconds.t
val stall : t -> stall
val equal : t -> t -> bool

type state_class = Active | Terminal | Inactive

val classify : t -> Issue.t -> state_class
(** Pure observation of normalized state membership. Terminal and active are
    disjoint. *)
