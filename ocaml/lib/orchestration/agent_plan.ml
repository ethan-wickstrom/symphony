module type S = sig
  module Issue : Issue.S
  module Path : Workspace_path.S

  type workspace
  type request

  val request :
    run_id:Run_id.t ->
    issue:Issue.t ->
    workspace:workspace ->
    agent:Agent_settings.t ->
    prompt_file:Workflow_path.t ->
    prompt_source:string ->
    attempt:Template.attempt ->
    (request, Workspace_manager.error) result

  val run_id : request -> Run_id.t
  val issue : request -> Issue.t
  val workspace : request -> workspace
  val agent : request -> Agent_settings.t
  val prompt_file : request -> Workflow_path.t
  val prompt_source : request -> string
  val attempt : request -> Template.attempt
end

module Make (Workspace : Workspace_manager.PURE) = struct
  module Issue = Issue
  module Path = Workspace.Path

  type workspace = Workspace.reference

  type request = {
    run_id : Run_id.t;
    issue : Issue.t;
    workspace : workspace;
    agent : Agent_settings.t;
    prompt_file : Workflow_path.t;
    prompt_source : string;
    attempt : Template.attempt;
  }

  let request ~run_id ~issue ~workspace ~agent ~prompt_file ~prompt_source
      ~attempt =
    (* Runtime identities cannot be encoded as OCaml type equalities. Check once
       before an immutable request can reach the worker. *)
    if
      Issue_id.equal (Issue.id issue) (Workspace.issue_id workspace)
      && Issue_identifier.equal (Issue.identifier issue)
           (Workspace.identifier workspace)
    then
      Ok
        { run_id; issue; workspace; agent; prompt_file; prompt_source; attempt }
    else
      Error
        (Workspace_manager.Ownership_conflict
           (Diagnostic.make
              ~site:
                (Diagnostic.Issue
                   { id = Issue.id issue; identifier = Issue.identifier issue })
              ~message:"Agent launch reference belongs to a different issue"
              ~remedy:
                "Build the launch reference from this issue's ID and identifier"))

  let run_id request = request.run_id
  let issue request = request.issue
  let workspace request = request.workspace
  let agent request = request.agent
  let prompt_file request = request.prompt_file
  let prompt_source request = request.prompt_source
  let attempt request = request.attempt
end
