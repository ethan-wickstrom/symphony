(** Parsed RFC 3339 instant, backed by Ptime. Never a scheduling clock. *)

type t

val parse : string -> (t, string) result

val of_unix_seconds : float -> (t, string) result
(** Check a wall-clock boundary once. Reject nonfinite values and timestamps
    outside years 0000 through 9999. Retain Ptime's picosecond precision. *)

val rfc3339 : t -> string
(** [parse (rfc3339 x) = Ok x] at the supported precision. *)

val compare : t -> t -> int
(** Total chronological order. Invalid best-effort tracker timestamps become
    null. *)

type direction = Earlier | Later

val shift : t -> direction -> Seconds.t -> t option
(** Exact POSIX nanosecond action. Zero preserves the instant; same-direction
    shifts compose when representable, and opposite shifts are partial inverses.
    None means the result lies outside the supported RFC 3339 range. Cost is
    bounded by that range even for an arbitrarily large checked duration. *)
