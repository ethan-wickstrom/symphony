type t
type hook = After_create | Before_run | After_run | Before_remove

val parse :
  env:Environment.public ->
  workflow_file:Workflow_path.t ->
  Config_value.t ->
  (t, Diagnostic.t Nonempty_list.t) result

val root : t -> Absolute_path.t
(** Lexically absolute config path; physical acquisition belongs to workspace
    IO. *)

val script : t -> hook -> string option
(** Trusted shell configuration only; never interpolate issue data. *)

val timeout : t -> Milliseconds.t
val equal : t -> t -> bool
