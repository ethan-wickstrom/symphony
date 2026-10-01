val inspect :
  fs:Eio.Fs.dir_ty Eio.Path.t ->
  clock:Clock_posix.t ->
  settings:Workspace_settings.t ->
  env:Environment.child ->
  scope:Tracker_scope.t ->
  issue:Issue.t ->
  (string option, Workspace_manager.error) result
(** Inspect a frozen reference through the public native host. Missing is
    non-creating; existing yields only an informational label. Inspection never
    launches a hook or an agent. The caller supplies its adapter binding's scope
    and sanitized environment from the same resolved workflow. Cancellation and
    defects propagate after lease release. *)

val error : Workspace_manager.error -> string
(** Render a redacted operator diagnostic, including its named input and remedy.
*)
