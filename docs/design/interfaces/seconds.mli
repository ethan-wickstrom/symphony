(** Exact accumulated runtime, represented as nonnegative nanosecond ticks. *)

type t
val zero : t
val add : t -> t -> t
(** Commutative monoid, with zero identity. Addition uses exact integer ticks. *)

val of_nanoseconds : Count.t -> t
val nanoseconds : t -> Count.t
(** [nanoseconds (of_nanoseconds n) = n]. *)

val decimal : t -> string
(** Exact decimal seconds for JSON, without a floating-point accumulation. *)
