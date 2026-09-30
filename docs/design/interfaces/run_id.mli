type t
val equal : t -> t -> bool
val text : t -> string
module Allocator : sig
  type token = t
  type t
  val empty : t
  val fresh : t -> token * t
  (** Functional fresh counter: every allocation in a chain has a distinct token. *)

end
