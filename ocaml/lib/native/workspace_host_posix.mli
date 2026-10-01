(** Sealed native assembly. One acquired Path brand connects ownership, hooks
    and every later agent launch; no raw filesystem/process authority escapes.
*)
module Make (Clock : Clock.S) : sig
  module Path : Workspace_path.S
  module Contract : Workspace_manager.PURE with module Path = Path
  module Process : Agent_process.S with module Path = Path
  module Workspace : Workspace_manager.S with module Contract = Contract

  type t

  val create :
    fs:Eio.Fs.dir_ty Eio.Path.t ->
    clock:Clock.t ->
    emit:
      (Contract.reference ->
      Workspace_settings.hook ->
      Workspace_hooks.event ->
      unit) ->
    report:(Workspace_manager.error -> unit) ->
    t
  (** Capture explicit host capabilities without IO. Reporters must handle their
      expected sink failures; defects cannot skip child closure or lease
      release. Ancestor aliases in the trusted root are permitted; retained
      directory identities, nofollow traversal and protected metadata govern
      authority. *)

  val process : t -> Process.t

  val workspace : t -> Workspace.t
  (** Raw lease/remove operations remain private. A callback receives only Path,
      so it cannot close and join its own admitted child scope. Concurrent
      cleanup acquires a separate lease and returns Busy while this owner runs.
  *)
end
