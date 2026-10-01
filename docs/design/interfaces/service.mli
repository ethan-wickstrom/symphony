(** Eio shell: one fiber owns Core.state. All children send identity-fenced events.
    Port contexts are constructed outside and supplied explicitly; no ambient authority. *)

module Make
    (Tracker : Tracker.S)
    (Clock : Clock.S)
    (Workspace : Workspace_manager.S)
    (Agent : Agent_runner.S
       with module Contract.Issue = Tracker.Contract.Issue
        and module Contract.Path = Workspace.Contract.Path
        and type Contract.workspace = Workspace.Contract.reference)
    (Log : Logging.S)
    (Config : Config_layer.S with type tracker = Tracker.Contract.binding) : sig
  module Core : Orchestrator.S
    with type config = Config.t
     and type clock_sample = Clock.Pure.sample
     and type instant = Clock.Pure.instant
     and type tracker_request = Tracker.Contract.request
     and type tracker_reply = Tracker.Contract.reply
     and type agent_request = Agent.Contract.request
     and type agent_progress = Agent.Contract.progress
     and type agent_completed = Agent.Contract.completed
     and type workspace_cleanup = Workspace.Contract.cleanup
     and type log_entry = Log.Contract.entry

  type timer = Poll of Request_id.t | Retry of Retry_id.t
  type message =
    | Event of Core.input
    | Snapshot_query of ((Snapshot.t, Status_surface.unavailable) result -> unit)
  (** Reply capability is confined to the effectful mailbox, outside pure core data. *)

  module type HOST = sig
    type t
    val load : t -> Request_id.t -> file:Workflow_path.t ->
      (Config.t, Config_layer.error) result
    val job : t -> Request_id.t -> (unit -> unit) -> unit
    val cancel_job : t -> Request_id.t -> unit
    (** Nonblocking launch under a child switch, keyed registry. Cancellation closes
        the child before emitting Request_canceled; completion/cancel races fence once. *)

    val worker : t -> Run_id.t ->
      (refresh:(turn:Turn_id.t -> (Agent_runner.continuation, Tracker_error.t) result) ->
       interrupted:(unit -> Agent_runner.interrupt option) -> Agent.Contract.completed) ->
      unit
    (** Nonblocking scoped launch; emits Worker_finished only after run returns its
        completion witness. Register a continuation waiter before sending the owner
        request. Stopping records the interrupt reason before canceling the child. *)

    val stop : t -> Run_id.t -> Orchestrator.stop_reason -> unit
    val continue : t -> Run_id.t -> Turn_id.t ->
      (Agent_runner.continuation, Tracker_error.t) result -> unit
    val timer : t -> timer -> at:Clock.Pure.instant -> Core.input -> unit
    val cancel_timer : t -> timer -> unit
    (** Nonblocking scope-bound scheduling; one child per typed token. Cancellation
        is idempotent and releases the child, even if its late event is harmless. *)

    val watch : t -> file:Workflow_path.t -> unit
    val send : t -> Core.input -> unit
    val receive : t -> message
    (** Owner is the only receiver. Bounded queue; preserve completion replies and
        query cancellation. Coalesce redundant refresh/change signals, never terminals. *)

    val snapshot : t -> (Snapshot.t, Status_surface.unavailable) result
    val refresh : t -> (Status_surface.refresh, Status_surface.unavailable) result
    (** Query/reply through the mailbox; bound waits and reject calls during shutdown. *)

    val drain : t -> unit
    (** Cancel/drain watcher, timer, job, worker and listener registries under the
        enclosing switch. Normal return proves child closure, unlike Core.quiescent. *)

  end

  module Run (Host : HOST) : sig
    module Source : Status_surface.SOURCE with type t = Host.t
    val run : Host.t -> tracker:Tracker.t -> clock:Clock.t ->
      workspace:Workspace.t -> agent:Agent.t -> log:Log.t -> Config.t -> unit
    (** Same command interpreter for live and fake lower drivers. Scope encloses owner,
        tracker jobs, watcher, timers, workers and API. Serve Snapshot_query by Core.snapshot
        with a new clock sample. Normal return requires Core.quiescent and Host.drain. *)

  end
end
