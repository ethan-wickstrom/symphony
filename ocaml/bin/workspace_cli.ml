module Host = Workspace_host_posix.Make (Clock_posix)

let inspect ~fs ~clock ~settings ~env ~scope ~issue =
  let host =
    Host.create ~fs ~clock ~emit:(fun _ _ _ -> ()) ~report:(fun _ -> ())
  in
  Result.bind
    (Host.Contract.reference ~settings ~env ~scope ~issue_id:(Issue.id issue)
       ~identifier:(Issue.identifier issue))
    (Host.Workspace.inspect (Host.workspace host))

let error = function
  | Workspace_manager.Invalid_key diagnostic
  | Workspace_manager.Unsafe_path diagnostic
  | Workspace_manager.Ownership_conflict diagnostic
  | Workspace_manager.Filesystem_error diagnostic
  | Workspace_manager.Hook_failed diagnostic
  | Workspace_manager.Hook_timeout diagnostic -> Diagnostic.render diagnostic
