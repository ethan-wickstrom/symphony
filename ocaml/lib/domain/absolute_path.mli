(** Lexically absolute filesystem names. This proves syntax, not physical
    containment. *)

type t

val parse : string -> (t, string) result

val display : t -> string
(** [parse (display p) = Ok p], modulo lexical normalization. No IO. *)
