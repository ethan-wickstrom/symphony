(** Section 3.1 component. A pure Mealy machine over immutable state. No IO,
    ambient clock, Eio capabilities, exception-driven expected failures, or locks. *)

type stop_reason = Stop_reason.t =
  | Reconcile_terminal
  | Reconcile_inactive
  | Reconcile_missing
  | Reconcile_unroutable
  | Scope_changed
  | Stall_detected
  | Shutdown_requested

module type S = sig
  type config
  type clock_sample
  type instant
  type tracker_request
  type tracker_reply
  type agent_request
  type agent_progress
  type agent_completed
  type workspace_cleanup
  type log_entry
  type state
  type event

  type input =
    | Poll_due of Request_id.t
    | Refresh_requested
    | Workflow_changed
    | Workflow_loaded of Request_id.t * (config, Config_layer.error) result
    | Tracker_completed of Request_id.t * tracker_reply
    | Worker_progress of Run_id.t * agent_progress
    | Worker_finished of agent_completed
    | Continuation_requested of Run_id.t * Turn_id.t
    | Request_canceled of Request_id.t
    | Retry_due of Retry_id.t
    | Workspace_removed of Request_id.t * (unit, Workspace_manager.error) result
    | Shutdown

  type command =
    | Load_workflow of { id : Request_id.t; file : Workflow_path.t }
    | Read_tracker of tracker_request
    | Start_worker of agent_request
    | Stop_worker of Run_id.t * stop_reason
    | Remove_workspace of workspace_cleanup
    | Continuation_reply of Run_id.t * Turn_id.t *
        (Agent_runner.continuation, Tracker_error.t) result
    | Cancel_request of Request_id.t
    | Arm_poll of Request_id.t * instant
    | Arm_retry of Retry_id.t * instant
    | Cancel_poll of Request_id.t
    | Cancel_retry of Retry_id.t
    | Log of log_entry

  val create : now:clock_sample -> config -> state * command list
  (** Starts terminal cleanup and polling under the validated startup config.
      Cleanup read failure warns and proceeds; startup config failure never reaches create. *)

  val event : now:clock_sample -> input -> event
  val step : state -> event -> state * command list
  (** Deterministic. Duplicate completions, request replies and timer IDs are observational no-ops.
      Progress is fenced by run/sequence; turn starts by turn ID. Absolute usage
      joins by run/thread. Only the latest load request can change readiness.
      One owner per issue. Claim precedes Start_worker; stopping and refreshing keep
      ownership. Retry/release follows resource completion. Invalid reload preserves
      last good config and gates EVERY new launch, while reconciliation remains active.
      Reconciliation precedes candidate dispatch; overlapping ticks coalesce.
      Admission obeys current caps, even if earlier workers now exceed reduced caps.
      A due retry under invalid config retains ownership and is awakened by a valid
      reload or rearmed timer. Continuation refreshes are serialized with reconciliation
      for each issue, retain the original binding and update the canonical issue before
      replying. Duplicate continuation requests cannot start a second turn. *)

  val snapshot : now:clock_sample -> state -> Snapshot.t
  (** Fresh issue fields, claimed union, counts, slots, runtime computed at read time.
      A scope change drains old owners before admission under the new scope. *)

  val quiescent : state -> bool
  (** True after Shutdown iff no worker, required cleanup, or pending request remains.
      Request cancellation requires a post-drain acknowledgement; forgetting its ID
      cannot establish quiescence. Watcher/timer scope drainage belongs to Service. *)

end

module Make
    (Tracker : Tracker.PURE with type Issue.t = Issue.t)
    (Clock : Clock.PURE)
    (Workspace : Workspace_manager.PURE with module Issue = Tracker.Issue)
    (Agent : Agent_runner.PURE
       with module Issue = Tracker.Issue
        and module Path = Workspace.Path
        and type workspace = Workspace.reference)
    (Log : Logging.PURE)
    (Config : Config_layer.PURE with type tracker = Tracker.binding) :
  S with type config = Config.t
     and type clock_sample = Clock.sample
     and type instant = Clock.instant
     and type tracker_request = Tracker.request
     and type tracker_reply = Tracker.reply
     and type agent_request = Agent.request
     and type agent_progress = Agent.progress
     and type agent_completed = Agent.completed
     and type workspace_cleanup = Workspace.cleanup
     and type log_entry = Log.entry
