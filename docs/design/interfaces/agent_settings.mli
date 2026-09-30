(** Checked launch settings and protocol policies; shell script is trusted config. *)

type t
val parse : env:Environment.t -> Config_value.t -> (t, Diagnostic.t Nonempty_list.t) result
val command : t -> string
(** Nonempty trusted command, preserved verbatim. Only the shell driver executes it. *)

val read_timeout : t -> Milliseconds.t
val turn_timeout : t -> Milliseconds.t
val max_turns : t -> int
val thread_policy : t -> Json.t
(** Schema-valid 0.159.2 approval/thread-sandbox settings. *)

module Bind (Path : Workspace_path.S) : sig
  val turn_policy : t -> Path.t -> Json.t
  (** Bind the current checked workspace on every turn, including continuations. *)

end
