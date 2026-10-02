(** Owner-allocated run identity. Distinct from requests and retry timers. *)

type t

val equal : t -> t -> bool
(** Equivalence relation; [equal a b = (compare a b = 0)]. *)

val compare : t -> t -> int
(** Total allocation order, independent of decimal byte order. *)

val text : t -> string
(** Exact positive decimal allocation number; never wraps. *)

module Order : Map.OrderedType with type t = t
module Map : Map.S with type key = t
module Set : Set.S with type elt = t

module Allocator : sig
  type token = t
  type t

  val empty : t

  val fresh : t -> token * t
  (** Functional natural-number successor. A chain beginning at [empty] yields
      texts ["1"], ["2"], ... and pairwise distinct tokens. Separate allocator
      branches do not promise global uniqueness. *)
end
