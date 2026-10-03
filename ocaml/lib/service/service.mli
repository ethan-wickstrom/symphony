(** Scoped effect interpreter over the implemented scheduling reducer. *)

module type WORKFLOW_LOAD = sig
  type config
  type t
  type request = { id : Request_id.t; file : Workflow_path.t }

  val load : t -> request -> (config, Config_layer.error) result
  (** Bounded scoped read/parse/resolve through captured registry/environment.
      The request ID supplies causal identity, not scheduling authority.
      Expected failures are values; cancellation and defects propagate. *)
end

module type CLOSED_RUNNER = sig
  include Agent_runner.PURE

  type t
  type clock
  type workspace_manager

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
  (** Use exactly the supplied clock and workspace instance. Return only after
      this invocation's workspace/process/hook scopes close. A previously
      resolved interruption promise reaches the runner, which must discharge it
      with a matching Canceled/Stalled completion and no workspace/process/hook
      acquisition, after its empty invocation scope closes. Only the runner
      constructs its opaque completion. Unrequested cancellation and defects
      drain then propagate with the supplied exception identity/backtrace.
      Progress publication is acknowledged or interrupted before the next
      publication. Refresh registers its turn-fenced waiter before owner
      delivery. Each completed turn permits one refresh callback; repeating it
      is a port defect rejected before publication. Recheck interruption after
      either callback before acquiring more resources or starting another turn.
      Callbacks never run from protected finalizers. *)
end

module Make
    (Tracker : Tracker.S)
    (Clock : Clock.S)
    (Workspace : Workspace_manager.S)
    (Agent :
      CLOSED_RUNNER
        with module Issue = Tracker.Contract.Issue
         and module Path = Workspace.Contract.Path
         and type workspace = Workspace.Contract.reference
         and type clock = Clock.t
         and type workspace_manager = Workspace.t)
    (Config : Config_layer.PURE with type tracker = Tracker.Contract.binding)
    (Load : WORKFLOW_LOAD with type config = Config.t) : sig
  module Core :
    Orchestrator.S
      with type config = Config.t
       and type instant = Clock.Pure.instant
       and type tracker_request = Tracker.Contract.request
       and type tracker_reply = Tracker.Contract.reply
       and type agent_request = Agent.request
       and type agent_progress = Agent.progress
       and type agent_completed = Agent.completed
       and type workspace_cleanup = Workspace.Contract.cleanup

  type t
  type control = Refresh | Shutdown

  type transition = {
    now : Clock.Pure.instant;
    input : Core.input;
    projection : Core.projection;
    commands : Core.command list;
    elapsed : Seconds.t;
  }

  type effect_key =
    | Owner
    | Controls
    | Workflow of Request_id.t
    | Tracker of Request_id.t
    | Cleanup of Request_id.t
    | Worker of Issue_id.t * Run_id.t
    | Poll of Request_id.t
    | Retry of Issue_id.t * Retry_id.t

  type host_fault =
    | Secondary_defect of { key : effect_key; diagnostic : Diagnostic.t }
        (** Cleanup/losing-branch defects accompanying an already captured
            primary. Diagnostics contain the constructor class and effect
            context, never raw exception payloads. Primary exception
            identity/backtrace remain private. *)

  type delivery = Entry | Terminal | Private_close

  type effect_event =
    | Registered of effect_key
    | Child_entered of effect_key
    | Outer_closed of effect_key
    | Delivered of effect_key * delivery
    | Retired of effect_key

  type initial = {
    now : Clock.Pure.instant;
    projection : Core.projection;
    commands : Core.command list;
    elapsed : Seconds.t;
  }

  type observation =
    | Initial of initial
    | Transition of transition
    | Effect of effect_event

  val create :
    clock:Clock.t ->
    workspace:Workspace.t ->
    agent:Agent.t ->
    load:Load.t ->
    report:(Core.fault -> unit) ->
    report_host:(host_fault -> unit) ->
    observe:(observation -> unit) ->
    t
  (** Pure capability capture. Instantiate Core/Plan/Life once. Observations
      expose generation keys and read-only reducer facts, never handles,
      registry state or new authority. Delivered means owner receipt, not the
      instant a producer finishes enqueueing. Expected sink failures are handled
      by the sink; without an earlier primary, sink defects fail the service
      after drainage. Sinks must not block, suspend or change scheduler facts.
      The host fault sink observes secondary cleanup failures after closure. Its
      own failure cannot replace a captured primary or skip remaining drainage;
      do not recursively report a failed reporter through itself. *)

  val run :
    sw:Eio.Switch.t ->
    t ->
    controls:control Eio.Stream.t ->
    Config.t ->
    (unit, Diagnostic.t) result
  (** One domain and one fiber own reducer state and the effect registry.
      Register before callback entry; entry/closed slots commit without waiting.
      A terminal slot is committed only after the fresh outer scope closes.
      Private canceled-timer closure is delivered/retired without a Core input.
      The owner steps each actual scheduling input once, observes its projection
      and ordered commands, then interprets those commands. Clock reads measure
      only reducer step/projection, never virtual performance evidence.

      Graceful Shutdown returns Ok only after Core.quiescent, registry drainage
      and control-forwarder closure. Expected clock failure drains and returns
      Error; unexpected cancellation/defects drain and re-raise the first
      primary with its backtrace. One canonical failure is committed by the
      owner or caller without suspension; first means their observation order,
      not exception chronology inside an unpublished child scope. Fatal drainage
      consumes only committed private facts, without Clock/Core stepping or user
      sinks; it never fabricates completed values or a timestamp. Ordinary
      secondary diagnostics follow their owning effect's closure. Fatal drainage
      retains them until every obligation closes, preserving the primary if that
      reporter fails. Observer traces may end at a fatal fault. The caller owns
      the supplied control stream and its producers.

      Publication is bounded by outstanding admitted effects, not a fixed global
      memory promise. Resource teardown is structured but native reap has no
      finite-duration guarantee. No watcher is part of this first interpreter.
  *)
end
