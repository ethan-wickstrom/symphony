(** Exact nonnegative integers. Reference model: mathematical naturals. *)

type t

val parse : string -> (t, string) result
(** Decimal digits only; [parse (decimal n) = Ok n]. *)

val decimal : t -> string
val zero : t
val add : t -> t -> t
(** Commutative monoid: [add zero x = x], associativity, commutativity.
    No saturation or machine-integer overflow. No inverses or absorption. *)

val compare : t -> t -> int
val max : t -> t -> t
(** Join semilattice: associative, commutative, idempotent; zero is bottom. *)

val delta : previous:t -> current:t -> t
(** [delta p c = max(0,c-p)]. Not additive in isolation; telescopes along
    nondecreasing counters. Counter resets require a new run/thread identity. *)
