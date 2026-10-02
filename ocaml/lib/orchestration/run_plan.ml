module type S = sig
  type config
  type binding
  type request
  type workspace
  type t
  type rejection
  type target = Unnamed of Tracker_scope.t | Named of workspace

  val create :
    config ->
    run:Run_id.t ->
    issue:Issue.t ->
    attempt:Template.attempt ->
    (t, rejection) result

  val binding : t -> binding
  val request : t -> request
  val rejected_issue : rejection -> Issue.t
  val rejected_attempt : rejection -> Template.attempt
  val rejected_target : rejection -> target
  val rejected_error : rejection -> Workspace_manager.error
end

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
  type config = Config.t
  type binding = Tracker.binding
  type request = Agent.request
  type workspace = Workspace.reference
  type t = { binding : binding; request : request }
  type target = Unnamed of Tracker_scope.t | Named of workspace

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
