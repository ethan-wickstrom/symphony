(** Unicode boundary operations with pinned Uucp case tables; no locale state.
*)

val valid_utf8 : string -> bool
val lower : string -> string
val upper : string -> string

val normalize : string -> string
(** [normalize (normalize s) = normalize s]; trimming uses ASCII whitespace.
    Inputs must have passed UTF-8 validation; invalid bytes are preserved by
    case mapping. *)

val escape : string -> string
(** Escapes controls for one-line diagnostic output. *)
