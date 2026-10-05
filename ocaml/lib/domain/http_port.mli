(** Checked TCP listener port. Zero asks the operating system for a port. *)

type t

val parse : string -> (t, string) result
val number : t -> int
