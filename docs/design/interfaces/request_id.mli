type t

val equal : t -> t -> bool
val compare : t -> t -> int
val text : t -> string

module Order : Map.OrderedType with type t = t
module Map : Map.S with type key = t

module Set : Set.S with type elt = t
(** Exact token order; map/set identity never uses dispatch order. *)

module Allocator : sig
  type token = t
  type t

  val empty : t

  val fresh : t -> token * t
  (** Distinct from run/retry tokens; allocated once per owner-side request. *)
end
