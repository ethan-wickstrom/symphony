(** Closed attempt over the original workspace and one owned app-server thread.
*)

module Make
    (Workspace : Workspace_manager.S)
    (Process : Agent_process.S with module Path = Workspace.Contract.Path)
    (Clock : Clock.S) : sig
  include
    Agent_runner.PURE
      with module Issue = Issue
       and module Path = Workspace.Contract.Path
       and type workspace = Workspace.Contract.reference

  type t
  type clock = Clock.t
  type workspace_manager = Workspace.t

  val create : process:Process.t -> version:string -> t
  (** Capture the lower process driver and application version only. *)

  val run :
    t ->
    clock:clock ->
    workspace:workspace_manager ->
    interrupt:Agent_runner.interrupt Eio.Promise.t ->
    emit:(progress -> unit) ->
    refresh:
      (turn:Turn_id.t -> (Agent_runner.continuation, Tracker_error.t) result) ->
    request ->
    completed
  (** Preparing/workspace/render/start/protocol facts have one causal sequence.
      After every successful turn, emit its success barrier and request the
      owner's fenced refresh. Continue with guidance on the same thread up to
      the frozen turn cap. Recheck interruption after callbacks. Construct
      completed only after process, after_run and workspace lease scopes close.
      Requested cancellation/stall is an outcome; unrelated cancellation and
      defects drain then propagate. A resolved interruption before invocation
      acquires no workspace, process or hook. *)
end
