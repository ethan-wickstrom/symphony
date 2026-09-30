(** Parsed RFC 3339 instant, backed by Ptime. Never a scheduling clock. *)

type t

val parse : string -> (t, string) result

val rfc3339 : t -> string
(** [parse (rfc3339 x) = Ok x] at the supported precision. *)

val compare : t -> t -> int
(** Total chronological order. Invalid best-effort tracker timestamps become
    null. *)
