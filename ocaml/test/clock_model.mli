(** Independent mathematical oracle: exact nanosecond coordinates and a single
    POSIX picosecond coordinate for wall projection. *)

val unsigned : int64 -> Z.t
val after : Z.t -> int64 -> Z.t
val elapsed : since:Z.t -> until:Z.t -> Z.t
val wall_at : wall:string -> monotonic:Z.t -> Z.t -> string option
