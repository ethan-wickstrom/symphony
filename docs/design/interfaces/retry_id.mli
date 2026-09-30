type t
val equal : t -> t -> bool
val text : t -> string
module Allocator : sig
  type token = t
  type t
  val empty : t
  val fresh : t -> token * t
  (** Functional allocation; tokens fence stale timers and refresh responses. *)

end
