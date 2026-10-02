(** Independent exact protocol counters: total need not equal input + output. *)

type t

val make : input:Count.t -> output:Count.t -> total:Count.t -> t
val zero : t

val add : t -> t -> t
(** Product commutative monoid: exact componentwise addition, with [zero] as
    identity. No saturation, inverses or absorbing element. *)

val join : t -> t -> t
(** Componentwise maximum: associative, commutative and idempotent; [zero] is
    bottom. *)

val difference : previous:t -> current:t -> t
(** Componentwise [max(0, current - previous)]. In particular,
    [difference ~previous:x ~current:(join x x) = zero]. Differences telescope
    along nondecreasing totals; arbitrary differences are not additive. *)

val input : t -> Count.t
val output : t -> Count.t
val total : t -> Count.t

type watermark

val initial : run:Run_id.t -> thread:Thread_id.t -> watermark
(** [absolute (initial ~run ~thread) = zero]. *)

val absolute : watermark -> t
(** Accepted absolute totals, derived from this watermark alone. *)

val observe :
  watermark ->
  run:Run_id.t ->
  thread:Thread_id.t ->
  absolute:t ->
  (watermark * t, string) result
(** For the same run/thread, [next = join(previous, report)] and
    [delta = difference ~previous ~current:next]. Duplicate or reordered reports
    never recount accepted tokens, and summed deltas telescope to
    [absolute next]. Continuation turns retain this watermark. A different run
    or thread returns [Error] and requires [initial]; the original watermark
    remains usable. *)
