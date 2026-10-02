(** Checked, immutable launch inputs. No path acquisition, prompt rendering or
    IO. The runner later acquires a live Path from the original workspace
    reference. *)

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
  (** Accept only matching opaque issue ID and original identifier. A successful
      request preserves every input under its observer. It contains no tracker
      credentials or acquired cwd. Scheduling policy remains with the owner. *)

  val run_id : request -> Run_id.t

  val issue : request -> Issue.t
  (** Historical launch snapshot, distinct from the owner's current issue. *)

  val workspace : request -> workspace
  val agent : request -> Agent_settings.t
  val prompt_file : request -> Workflow_path.t
  val prompt_source : request -> string
  val attempt : request -> Template.attempt
end

module Make (Workspace : Workspace_manager.PURE) :
  S
    with module Issue = Issue
     and module Path = Workspace.Path
     and type workspace = Workspace.reference
