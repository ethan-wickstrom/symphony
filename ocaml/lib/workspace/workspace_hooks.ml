type outcome = Completed of (unit, Workspace_manager.error) result | Cancelled
type event = Started | Finished of outcome

module type S = sig
  module Contract : Workspace_manager.PURE

  type t

  val run :
    t ->
    workspace:Contract.reference ->
    cwd:Contract.Path.t ->
    Workspace_settings.hook ->
    (unit, Workspace_manager.error) result
end
