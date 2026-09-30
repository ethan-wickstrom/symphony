(** Checked opaque identity. Implementations preserve bytes; reject empty,
    whitespace-only, NUL-containing, or invalid UTF-8 input. *)

module type S = sig
  type t

  val parse : string -> (t, string) result
  (** [parse (text x) = Ok x]. A parse error explains the rejected field. *)

  val text : t -> string

  val equal : t -> t -> bool
  (** Equality is an equivalence relation; [equal a b = (compare a b = 0)]. *)

  val compare : t -> t -> int
  (** Total byte order: reflexive, sign-antisymmetric, transitive, total. *)

  module Order : Map.OrderedType with type t = t
  module Map : Map.S with type key = t
  module Set : Set.S with type elt = t
end

module Make () : S
(** Generative instances prevent mixing identities from distinct domains. *)
