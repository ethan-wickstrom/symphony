(** Protocol counters are independent: total need not equal input plus output. *)

type t
val make : input:Count.t -> output:Count.t -> total:Count.t -> t
val zero : t
val add : t -> t -> t
(** Product commutative monoid; exact componentwise addition. *)

val join : t -> t -> t
(** Componentwise-max join semilattice: associative, commutative, idempotent. *)

val difference : previous:t -> current:t -> t
(** Componentwise nonnegative difference. [difference x (join x x) = zero]. *)

val input : t -> Count.t
val output : t -> Count.t
val total : t -> Count.t

type watermark
val initial : run:Run_id.t -> thread:Thread_id.t -> watermark
val observe : watermark -> run:Run_id.t -> thread:Thread_id.t -> absolute:t ->
  (watermark * t, string) result
(** For the same run/thread: next=join(previous,report), delta=next-previous.
    Duplicate/reordered reports contribute nothing already seen. Sum of deltas
    telescopes to the final watermark. Continuation turns retain it; another
    run/thread requires a fresh watermark. Session_id changes on each turn. *)
