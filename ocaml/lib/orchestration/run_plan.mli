(** Planning is total over checked configuration and issues. Rejection occurs
    before resources exist; it must not fabricate a closed-worker witness. *)

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
  (** Construct the reference before the request from this config's binding,
      root, hooks and sanitized child environment. Reference failure yields
      Unnamed; request failure yields Named. Neither acquires a directory or
      starts an agent. Same inputs preserve the same observable facts. *)

  val binding : t -> binding

  val request : t -> request
  (** Binding and request are stored once. A later config change cannot change
      original authority or launch inputs. Scope is derived from binding; issue,
      workspace and attempt are derived from request. *)

  val rejected_issue : rejection -> Issue.t
  val rejected_attempt : rejection -> Template.attempt
  val rejected_target : rejection -> target

  val rejected_error : rejection -> Workspace_manager.error
  (** The error names the failed boundary. An Unnamed target cannot authorize
      cleanup. Failed resume retains the previous attempt's original reference
      rather than this newly planned target. *)
end

module Make
    (Tracker : Tracker.PURE with type Issue.t = Issue.t)
    (Workspace : Workspace_manager.PURE)
    (Agent :
      Agent_plan.S
        with module Issue = Tracker.Issue
         and module Path = Workspace.Path
         and type workspace = Workspace.reference)
    (Config : Config_layer.PURE with type tracker = Tracker.binding) :
  S
    with type config = Config.t
     and type binding = Tracker.binding
     and type request = Agent.request
     and type workspace = Workspace.reference
