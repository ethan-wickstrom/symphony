(** Exact positive naturals; retry attempt zero has no representation. *)

type t

val parse : string -> (t, string) result
val first : t
val next : t -> t

val count : t -> Count.t
(** [count first = 1]; [count (next x) = Count.add (count x) 1]. Reference
    model: positive mathematical integers. No predecessor of first. *)
