module Make (Path : Workspace_path.S) = struct
  module Path = Path

  type reference = {
    settings : Workspace_settings.t;
    environment : Environment.child;
    scope : Tracker_scope.t;
    identifier : Issue_identifier.t;
    key : Workspace_key.t;
  }

  let reference ~settings ~env ~scope ~identifier =
    match Workspace_key.of_identifier identifier with
    | Ok key -> Ok { settings; environment = env; scope; identifier; key }
    | Error message ->
        let site =
          Diagnostic.Host
            ("workspace_identifier="
            ^ Issue_identifier.text identifier
            ^ " workspace.root="
            ^ Absolute_path.display (Workspace_settings.root settings))
        in
        Error
          (Workspace_manager.Invalid_key
             (Diagnostic.make ~site ~message
                ~remedy:"Fix the tracker issue identifier."))

  let identifier reference = reference.identifier
  let scope reference = reference.scope
  let environment reference = reference.environment
  let key reference = reference.key
  let settings reference = reference.settings

  type cleanup = { request_id : Request_id.t; workspace : reference }
end
