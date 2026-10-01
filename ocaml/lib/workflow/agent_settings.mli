(** Checked launch settings and protocol policies; shell script is trusted
    config. *)

type t

val parse :
  env:Environment.public ->
  Config_value.t ->
  (t, Diagnostic.t Nonempty_list.t) result

val command : t -> string
(** Nonempty trusted command, preserved verbatim. Only the shell driver executes
    it. *)

val read_timeout : t -> Milliseconds.t
val turn_timeout : t -> Milliseconds.t
val max_turns : t -> int
val equal : t -> t -> bool

val thread_policy : t -> Json.t
(** Schema-valid 0.159.2 approval/thread-sandbox settings. *)

module Bind (Path : Workspace_path.S) : sig
  val turn_policy : t -> Path.t -> (Json.t, Diagnostic.t) result
  (** The default policy binds the current checked workspace on every turn,
      including continuations. Explicit operator policies are returned
      unchanged; their modes and writable roots may grant broader access.
      Generated JSON is guarded by the retained immutable quarantine rules,
      including the current workspace's canonical path. Rejection names
      [codex.turn_sandbox_policy] without exposing credential bytes.
      @raise Invalid_argument
        only if the supplied Path instance violates its checked UTF-8/path-size
        contract (a defect, not a workflow failure). *)
end
