type t
val of_identifier : Issue_identifier.t -> (t, string) result
(** Allowed alphabet [A-Za-z0-9._-]. Unchanged safe keys preserve bytes.
    Changed keys append 128 SHA-256 bits over original identifier bytes.
    Reject dot/dot-dot, empty or overlong components; collisions fail at acquisition.
    Deterministic, but not injective: ownership checking remains mandatory. *)

val text : t -> string
val compare : t -> t -> int
