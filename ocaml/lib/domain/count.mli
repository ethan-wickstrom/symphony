(** Exact nonnegative integers. Reference model: mathematical naturals. *)

type t

val parse : string -> (t, string) result
(** Decimal digits only; [parse (decimal n) = Ok n]. *)

val decimal : t -> string

val decimal_bounded : max_bytes:int -> t -> (string, string) result
(** Preflights bit length before conversion; temporary decimal allocation is at
    most twice the byte budget. Accepted output never exceeds the byte budget.
*)

val zero : t
val one : t

val add : t -> t -> t
(** Commutative monoid: [add zero x = x], associativity, commutativity. No
    saturation or machine-integer overflow. No inverses or absorption. *)

val compare : t -> t -> int

val max : t -> t -> t
(** Join semilattice: associative, commutative, idempotent; zero is bottom. *)

val delta : previous:t -> current:t -> t
(** [delta p c = max(0,c-p)]. Not additive in isolation; telescopes along
    nondecreasing counters. Counter resets require a new run/thread identity. *)
