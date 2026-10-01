(** Checked request-time normalization policy, separate from frozen credentials.
*)

type t

val of_scheduling : Scheduling_policy.t -> t
(** Share the immutable checked terminal set. No parsing or cached copy. *)

val terminal : t -> string list
(** Canonical terminal-set projection. Repeated observation agrees. *)

val equal : t -> t -> bool
(** Equivalence over terminal membership. For policies [a] and [b],
    [equal (of_scheduling a) (of_scheduling b)] iff their terminal sets agree.
    Active-state/concurrency changes alone leave this projection unchanged. *)
