module Make
    (Tracker : Tracker.PURE with type Issue.t = Issue.t)
    (Workspace : Workspace_manager.PURE)
    (Agent :
      Agent_plan.S
        with module Issue = Tracker.Issue
         and module Path = Workspace.Path
         and type workspace = Workspace.reference)
    (Config : Config_layer.PURE with type tracker = Tracker.binding) =
struct
  type t = { binding : Tracker.binding; request : Agent.request }
  type target = Unnamed of Tracker_scope.t | Named of Workspace.reference

  type rejection = {
    issue : Issue.t;
    attempt : Template.attempt;
    target : target;
    error : Workspace_manager.error;
  }

  let create config ~run ~issue ~attempt =
    let binding = Config.tracker config in
    let scope = Tracker.scope binding in
    match
      Workspace.reference ~settings:(Config.workspace config)
        ~env:(Config.child_env config) ~scope ~issue_id:(Issue.id issue)
        ~identifier:(Issue.identifier issue)
    with
    | Error error -> Error { issue; attempt; target = Unnamed scope; error }
    | Ok workspace -> (
        match
          Agent.request ~run_id:run ~issue ~workspace
            ~agent:(Config.agent config) ~prompt_file:(Config.file config)
            ~prompt_source:(Config.prompt_source config)
            ~attempt
        with
        | Error error ->
            Error { issue; attempt; target = Named workspace; error }
        | Ok request -> Ok { binding; request })

  let binding plan = plan.binding
  let request plan = plan.request
  let rejected_issue rejected = rejected.issue
  let rejected_attempt rejected = rejected.attempt
  let rejected_target rejected = rejected.target
  let rejected_error rejected = rejected.error
end
