(** Nonnegative bounded configuration duration. Distinct from seconds. *)

type t

val parse : string -> (t, string) result
(** [parse (decimal x) = Ok x]; rejects negative values and overflow. *)

val decimal : t -> string

val nanoseconds : t -> Count.t
(** Exact unit conversion: [nanoseconds ms = ms * 1_000_000]. Preserves zero and
    representable sums; its unbounded result never overflows. *)

val zero : t
val compare : t -> t -> int

val add : t -> t -> (t, string) result
(** Agrees with integer addition when representable; reports overflow. This
    result-valued operation is not advertised as an unbounded monoid. *)
