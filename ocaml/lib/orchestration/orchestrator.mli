(** First scheduling operation language. One pure owner reduces timestamped
    inputs and emits ordered commands. Protocol progress, turn continuation and
    stall detection are absent. *)

module type S = sig
  type config
  type instant
  type tracker_request
  type tracker_reply
  type agent_request
  type agent_progress
  type agent_completed
  type workspace_cleanup
  type state
  type event

  type input =
    | Poll_due of Request_id.t
    | Refresh_requested
    | Workflow_changed
    | Workflow_loaded of Request_id.t * (config, Config_layer.error) result
    | Tracker_completed of Request_id.t * tracker_reply
    | Worker_started of Issue_id.t * Run_id.t
    | Worker_progress of {
        issue : Issue_id.t;
        run : Run_id.t;
        progress : agent_progress;
        emitted_at : instant;
      }
    | Worker_continue of Issue_id.t * Run_id.t * Turn_id.t
    | Worker_finished of agent_completed
    | Request_canceled of Request_id.t
    | Retry_due of Issue_id.t * Retry_id.t
    | Workspace_removed of Request_id.t * (unit, Workspace_manager.error) result
    | Shutdown
        (** Worker_started attests registered Host child callback entry, not
            protocol readiness. Before-entry failure closes Starting directly.
            Every tracker, load, removal or cancellation terminal is published
            after its job scope closes; Worker_finished is published after its
            worker scope closes. *)

  type fault =
    | Config_failure of Config_layer.error
    | Tracker_failure of Tracker_error.t
    | Issue_tracker_failure of Issue.t * Tracker_error.t
    | Attempt_failure of Issue.t * Agent_runner.failure
    | Attempt_timeout of Issue.t * Agent_runner.timeout
    | Attempt_stalled of Issue.t
    | Attempt_cancel_error of Issue.t * Diagnostic.t
    | Planning_failure of Issue.t * Workspace_manager.error
    | Cleanup_failure of Issue.t * Workspace_manager.error
    | Lifecycle_failure of Issue.t * Diagnostic.t
        (** Issue-scoped faults retain the checked canonical current issue at
            emission, including after the same transition releases its owner.
            Log edges derive ID/identifier from this ephemeral command value; no
            cached context, original launch snapshot or session map is needed.
            Tracker_failure is reserved for startup/batched reads. *)

  type command =
    | Load_workflow of { id : Request_id.t; file : Workflow_path.t }
    | Read_tracker of tracker_request
    | Start_worker of agent_request
    | Stop_worker of Issue_id.t * Run_id.t * Agent_runner.interrupt
    | Continue_worker of
        Issue_id.t
        * Run_id.t
        * Turn_id.t
        * (Agent_runner.continuation, Tracker_error.t) result
    | Remove_workspace of workspace_cleanup
    | Cancel_request of Request_id.t
    | Arm_poll of Request_id.t * instant
    | Cancel_poll of Request_id.t
    | Arm_retry of Issue_id.t * Retry_id.t * instant
    | Cancel_retry of Issue_id.t * Retry_id.t
    | Report of fault
        (** Commands carry checked requests, frozen authority and keyed
            generations. Continuation replies fence the completed turn; stop
            retains ownership until closed completion. Faults remain typed. *)

  val create : now:instant -> config -> state * command list
  (** Reserve the startup terminal-read obligation. No launch precedes closure
      of the epoch-fenced startup read and every admitted cleanup job. Chosen
      bootstrap ordering joins every outstanding job, including superseded
      workflow loaders, before repeating terminal reads or entering Serving.
      This additional ordering is an implementation policy. *)

  val event : now:instant -> input -> event

  val step : state -> event -> state * command list
  (** Deterministic and total over checked inputs. The producer supplies
      nondecreasing monotonic instants. Missing/stale/crossed issue-generation
      envelopes and duplicate closed terminals change no scheduling projection
      and emit no effects. Accepted completions retire their obligation once.
      Reserve Starting/Waiting/Cleaning before the corresponding effect command.
      Stop or cancel alone never releases resource custody or a worker slot.
      Reconciliation groups by original binding and closes every group before
      latest preflight and current-epoch candidate admission. Invalid reload
      preserves last good settings and blocks every new launch. Expected
      dependency failures are fault values. Defects from a dependency instance
      that violates its contract propagate and are never converted to retries.
  *)

  type mode = Startup | Serving | Draining_scope | Shutting_down
  type readiness = Ready | Loading | Invalid
  type worker_phase = Starting | Active | Stopping
  type retry_phase = Waiting of instant | Refreshing | Parked
  type cycle_status = Idle | Busy

  type worker = {
    issue : Issue.t;
    run : Run_id.t;
    phase : worker_phase;
    attempt : Template.attempt;
    seconds_running : Seconds.t;
    agent_phase : Agent_observation.phase;
    session : Session_id.t option;
    turn_count : Count.t;
    last_event : string option;
    last_message : string option;
    last_activity : instant option;
    usage : Usage.t;
    rate_limits : Json.t option;
  }

  type retry = {
    issue : Issue.t;
    retry : Retry_id.t;
    phase : retry_phase;
    attempt : Positive_count.t;
  }

  type owner = Worker of worker | Retry of retry | Cleaning of Issue.t

  type projection = {
    mode : mode;
    readiness : readiness;
    cycle : cycle_status;
    owners : owner list;
    running : int;
    available_slots : int;
    total_runtime : Seconds.t;
    total_usage : Usage.t;
    latest_rate_limits : Json.t option;
  }

  val project : now:instant -> state -> projection
  (** Operator/conformance read side, derived once per read. Rows are ordered by
      Issue_id.compare and use canonical current issues. Starting, Active and
      Stopping count as running; Cleaning consumes a claim but no slot. Total
      runtime joins one ended aggregate with current worker intervals. Busy
      lasts through reconciliation, preflight and candidate resource closure. No
      binding, reference, pending ledger, epoch or acquired Path escapes.
      Reading changes no state; equal states/time yield equal observations. *)

  val quiescent : state -> bool
  (** Exactly Shutting_down with no owner or pending resource obligation.
      Timer/watcher/interpreter switch drainage remains a separate Host law. *)
end

(** Inside Make, instantiate Run_plan.Make once, then pass that exact Plan to
    Issue_lifecycle.Make: Plan.config = Config.t, Plan.binding =
    Tracker.binding, Plan.request = Agent.request, Plan.workspace =
    Workspace.reference. *)
module Make
    (Tracker : Tracker.PURE with type Issue.t = Issue.t)
    (Clock : Clock.PURE)
    (Workspace : Workspace_manager.PURE)
    (Agent :
      Agent_runner.PURE
        with module Issue = Tracker.Issue
         and module Path = Workspace.Path
         and type workspace = Workspace.reference)
    (Config : Config_layer.PURE with type tracker = Tracker.binding) :
  S
    with type config = Config.t
     and type instant = Clock.instant
     and type tracker_request = Tracker.request
     and type tracker_reply = Tracker.reply
     and type agent_request = Agent.request
     and type agent_progress = Agent.progress
     and type agent_completed = Agent.completed
     and type workspace_cleanup = Workspace.cleanup
