type t

val equal : t -> t -> bool
val text : t -> string

module Allocator : sig
  type token = t
  type t

  val empty : t

  val fresh : t -> token * t
  (** Distinct from run/retry tokens; allocated once per owner-side request. *)
end
