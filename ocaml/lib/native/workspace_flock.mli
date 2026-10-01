(** Fixed-operation advisory lock on a scope-owned file description. *)

type status = Acquired | Busy

val acquire : Eio_unix.Fd.t -> (status, Unix.error) result
(** Acquired remains exclusive until the final descriptor close. Repeating it on
    one description is idempotent; separate opens of the same inode contend.
    Busy grants no authority. Expected Eio.Io admission errors propagate to
    Directory's operation boundary. Cancellation and worker defects propagate
    unchanged; no private Eio reason or diagnostic string is inspected. *)
